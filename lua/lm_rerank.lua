-- lua/lm_rerank.lua
-- LM 只做重排、不参与分词（纯 Lua 实现，不改 librime）
--
-- 背景（详见 docs/PROGRESS.md §4.11/§4.12）：
--   librime 的 octagram 把 LM 分数**按段累加**进组句打分，于是 LM 参与分词决策时
--   全拼还原率反而下降（实测 16% vs 不装 LM 24%）。正确架构是：
--     分词只按词库权重（grammar 关掉）→ 得到多个按权重排序的整句候选
--     → LM 只在这些候选之间重排
--   为了不依赖 librime 补丁，LM 直接放在 Lua：读 scripts/gen_lm_rerank.py
--   生成的紧凑 n-gram 表（默认 60 万条 2~4gram，约 8MB）。
--
-- 表格式: 每行 "<ngram>\t<value>"，value = round(log(1+count)*1000)，按字节序排序。

local M = {}

local MAX_N = 6                 -- 最多用到的 n-gram 长度（与生成器一致）
local MISS_PENALTY = -20000     -- 连 unigram 都没有时的兜底罚分
local LOG_TOTAL = nil           -- log(总字数)*1000，来自 .meta；用于 unigram 概率

local tab
local tried = false

-- 二进制包（scripts/gen_lm_rerank.py 产出）：定长记录 + 二分查表，避免把 190 万条
-- n-gram 全量灌进 Lua 哈希（那份表 28.5MB，建哈希后常驻可达数百 MB）。
-- 格式见生成器 write_bin() 的注释：8B magic + 6×u32 计数 + 各档定长记录(键3L字节+u16值)。
-- 逐字节比较：Lua 里字符串的 `<` 走 strcoll（受 locale 影响），而二进制文件是按
-- 纯字节序排的 —— 直接用它比较会让二分查表偶发 miss，导致 LM 分数悄悄变差
-- （症状：golden 32 -> 29，极难定位；用 log.error 打出实际命中路径才查到）。
local function byte_lt(a, b)
    local n = math.min(#a, #b)
    for i = 1, n do
        local x, y = a:byte(i), b:byte(i)
        if x ~= y then return x < y end
    end
    return #a < #b
end

local function load_bin(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    if not data or #data < 36 or data:sub(1, 5) ~= "EGLM1" then return nil end
    -- 头部布局：8B magic + 4B 档数字节 + 6×u32 计数 = 36B；计数从**第 13 个字节**开始
    -- （Lua 字符串 1-based）。这里原来写成 12，整体错位一字节 → 二分全部查不到
    -- （症状：golden 32 -> 29，LM 静默失效，极难察觉）。
    local counts, base, off, n = {}, {}, 36, 0
    for L = 1, 6 do
        local i = 13 + (L - 1) * 4
        local c = data:byte(i) + data:byte(i + 1) * 256
                + data:byte(i + 2) * 65536 + data:byte(i + 3) * 16777216
        counts[L] = c
        base[L] = off
        off = off + c * (3 * L + 2)
        n = n + c
    end
    local proxy = setmetatable({}, { __index = function(_, k)
        local L = #k / 3
        if L ~= math.floor(L) or L < 1 or L > 6 then return nil end
        local cnt, b0, rec = counts[L], base[L], 3 * L + 2
        local lo, hi = 0, cnt - 1
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local p = b0 + mid * rec
            local key = data:sub(p + 1, p + 3 * L)
            if key == k then
                local b1, b2 = data:byte(p + 3 * L + 1, p + 3 * L + 2)
                return b1 + b2 * 256
            elseif byte_lt(key, k) then lo = mid + 1 else hi = mid - 1 end
        end
        return nil
    end })
    return proxy, n
end

function M.load(filename)
    if tried then return tab end
    tried = true
    -- 位置兼容：优先 dicts/（fcitx 每次重启都会跑一遍部署，deployer 会把用户目录
    -- **根下**它不认识的 .bin 当无主文件移进 trash/；dicts/ 是词典源目录，不清理）。
    -- 依次尝试：dicts/*.bin -> 根 *.bin -> 根 *.tsv（老部署）。
    -- meta 必须取**同一个位置**的（它给出 total_chars，是重排的归一化基线，
    -- 取错位置会静默回退到兜底值，把重排结果改坏）。
    local dir = rime_api.get_user_data_dir()
    local stem = "lm_rerank"
    local path, meta_path
    for _, cand in ipairs({
        { dir .. "/dicts/" .. stem .. ".bin", dir .. "/dicts/" .. stem .. ".meta" },
        { dir .. "/" .. stem .. ".bin",       dir .. "/" .. stem .. ".meta" },
        { dir .. "/" .. (filename or stem .. ".tsv"), dir .. "/" .. stem .. ".meta" },
    }) do
        local f0 = io.open(cand[1], "rb")
        if f0 then f0:close(); path, meta_path = cand[1], cand[2]; break end
    end
    if not path then
        log.warning("[lm_rerank] 未找到 n-gram 表（dicts/ 或根目录），跳过 LM 重排")
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        log.warning("[lm_rerank] 打不开 " .. path .. "，跳过 LM 重排")
        return nil
    end
    local t, n = load_bin(path:gsub("%.tsv$", ".bin"))
    if t then
        f:close()
    else
    local n2 = 0
    t = {}
    for line in f:lines() do
        local k, v = line:match("^(.-)\t(%d+)$")
        if k then
            t[k] = tonumber(v)
            n2 = n2 + 1
        end
    end
    f:close()
    n = n2
    end
    -- 读取总字数（用于 backoff 的 unigram 概率 P(c) = count(c)/total）
    local mf = io.open(meta_path, "rb")
    if mf then
        for line in mf:lines() do
            local v = line:match("^total_chars=(%d+)$")
            if v then
                LOG_TOTAL = math.log(tonumber(v) + 1) * 1000
            end
        end
        mf:close()
    end
    if not LOG_TOTAL then
        LOG_TOTAL = math.log(1e8) * 1000   -- 保守兜底
    end
    log.warning("[lm_rerank] 已载入 " .. n .. " 条 n-gram, log_total=" ..
                string.format("%.0f", LOG_TOTAL))
    tab = t
    return tab
end

--- 给一段文本打分：逐位置取条件概率最优的阶数（log count(ngram) - log count(前缀)）。
-- 为何不用“最长匹配的原始 log count 累加”：log count 天然偏爱高频短 n-gram
-- （实测会把「我今天没有控/恐/孔」排在正确的「我今天没有空」前面）。
-- 用条件概率 + 阶数 backoff 才是正常语言模型打分。
function M.score(text)
    if not tab or text == nil or text == "" then return 0 end
    local n = utf8.len(text)
    if not n or n == 0 then return 0 end
    local pos = {}
    for i = 1, n do pos[i] = utf8.offset(text, i) end
    pos[n + 1] = #text + 1
    local total = 0
    for i = 1, n do
        local best
        local uc = text:sub(pos[i], pos[i + 1] - 1)
        if i == 1 then
            -- 首字符没有上文，用 unigram 概率
            local u = tab[uc]
            best = u and (u - LOG_TOTAL) or nil
        end
        if i >= 2 then
        for L = MAX_N, 2, -1 do
            if i - L + 1 >= 1 then
                local g = text:sub(pos[i - L + 1], pos[i + 1] - 1)
                local v = tab[g]
                if v then
                    local pre = text:sub(pos[i - L + 1], pos[i] - 1)
                    local vp = tab[pre]
                    if vp then
                        local cond = v - vp
                        if not best or cond > best then best = cond end
                    end
                end
            end
        end
        end
        -- backoff 底线：unigram 概率（避免“无证据”优于“低频但有证据”）
        local u = tab[uc]
        if u then
            local pu = u - LOG_TOTAL
            if not best or pu > best then best = pu end
        end
        total = total + (best or MISS_PENALTY)
    end
    return total
end

--- 在候选数组里，把 type == "sentence" 的候选按 LM 分数重排（保持它们原来的位置集合）。
-- 只动句子之间的相对顺序，不影响「简码/词/句子」的整体分组语义。
function M.rerank_sentences(cands)
    local idxs, items = {}, {}
    for i, c in ipairs(cands) do
        if c:get_dynamic_type() == "Sentence" then
            idxs[#idxs + 1] = i
            items[#items + 1] = c
        end
    end
    if #items < 2 then return 0 end
    local scored = {}
    for _, c in ipairs(items) do
        scored[#scored + 1] = { c = c, s = M.score(c.text) }
    end
    table.sort(scored, function(a, b) return a.s > b.s end)
    for k, i in ipairs(idxs) do cands[i] = scored[k].c end
    return #items
end



--- 调试：打印整句候选及其 LM 分数（由 dynamic_translator 按配置开启）
--- 给一段文本按**给定上下文**打分（供 py_composer 在搜索中使用）。
function M.score_segment(context, text)
    if not tab or not text or text == "" then return 0 end
    local ctx = {}
    for _, cp in utf8.codes(context or "") do ctx[#ctx + 1] = utf8.char(cp) end
    while #ctx > 6 do table.remove(ctx, 1) end   -- 只保留最近 6 字作上下文
    local total = 0
    for _, cp in utf8.codes(text) do
        local ch = utf8.char(cp)
        local best
        -- 用满表里的阶数：2-6gram（原为 4，浪费了 5/6gram 的证据）
        for L = 6, 2, -1 do
            if #ctx >= L - 1 then
                local tail = table.concat(ctx, "", #ctx - (L - 1) + 1, #ctx)
                local v, vp = tab[tail .. ch], tab[tail]
                if v and vp then
                    local c = v - vp
                    if not best or c > best then best = c end
                end
            end
        end
        local u = tab[ch]
        local pu = u and (u - LOG_TOTAL) or MISS_PENALTY
        -- 返回"上下文增益"：条件概率相对 unigram 的提升。
        -- 这样逐字累加不会随句长单调增长，可与词的一元 LM 相加。
        local gain = best and (best - pu) or 0
        total = total + gain
        ctx[#ctx + 1] = ch
        if #ctx > 8 then table.remove(ctx, 1) end
    end
    return total
end

--- 限制“展示”的整句数量：重排后只留前 keep 个在首位，
-- 其余整句挪到候选流尾部（仍可翻页找到，但不污染首屏）。
-- 为何需要：max_sentences 开大是为了给重排足够候选，但直接展示会让
-- 一整页都是“今天的天气怎么阳/养/杨/洋/央”这类只差一字的整句变体。
function M.limit_sentences(cands, keep)
    keep = keep or 1
    local out, extra, seen = {}, {}, 0
    for _, c in ipairs(cands) do
        if c:get_dynamic_type() == "Sentence" then
            seen = seen + 1
            if seen > keep then
                extra[#extra + 1] = c
            else
                out[#out + 1] = c
            end
        else
            out[#out + 1] = c
        end
    end
    for _, c in ipairs(extra) do out[#out + 1] = c end
    for i = 1, #out do cands[i] = out[i] end
    return #extra
end

--- 调试：打印整句候选与 LM 分数（由 dynamic_translator 按配置开启）
function M.debug(cands, input)
    local n = 0
    for _, c in ipairs(cands) do
        if c:get_dynamic_type() == "Sentence" then
            n = n + 1
            if n <= 25 then
                log.error(string.format("[LMDBG] %s #%d score=%.0f %s",
                    input, n, M.score(c.text), c.text))
            end
        end
    end
end

return M
