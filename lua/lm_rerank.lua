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

local MAX_N = 4                 -- 最多用到的 n-gram 长度
local MISS_PENALTY = -20000     -- 连 unigram 都没有时的兜底罚分
local LOG_TOTAL = nil           -- log(总字数)*1000，来自 .meta；用于 unigram 概率

local tab
local tried = false

function M.load(filename)
    if tried then return tab end
    tried = true
    local path = rime_api.get_user_data_dir() .. "/" ..
                 (filename or "lm_rerank.tsv")
    local f = io.open(path, "rb")
    if not f then
        log.warning("[lm_rerank] 未找到 " .. path .. "，跳过 LM 重排")
        return nil
    end
    local t = {}
    local n = 0
    for line in f:lines() do
        local k, v = line:match("^(.-)\t(%d+)$")
        if k then
            t[k] = tonumber(v)
            n = n + 1
        end
    end
    f:close()
    -- 读取总字数（用于 backoff 的 unigram 概率 P(c) = count(c)/total）
    local mf = io.open(path:gsub("%.tsv$", ".meta"), "rb")
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
