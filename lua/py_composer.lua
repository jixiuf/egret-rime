-- lua/py_composer.lua
-- 纯 Lua 的「拼音 → 句子」搜索（LM 真正参与剪枝，不是事后重排）
--
-- 为什么要自己搜（docs/PROGRESS.md §4.x）：
--   librime 的组句是"先按词库权重 beam search 剪枝 → 再重排"。实测 66% 的正确句
--   根本进不了候选（按权重的 beam 饱和），LM 再准也没用。
--   librime-lua 只能按单音节查词典（多音节 code 查不到），所以在 Lua 里自建：
--     1) 词表（word → 音节串 → 语料 log 词频权重）
--     2) 在输入串上做 beam search，打分 = 词权重 + LM（同尺度，直接相加）
--
-- 与 librime 搜索的关键区别：
--   - 词表只用**拼音**（不含五笔码）→ 不会被 "wan→人世(wwan)" 这类跨路串扰
--   - 权重是我们自己语料的 log 词频 → 与 LM 同尺度
--   - LM 参与剪枝 → 正确路径不会被权重剪掉
local M = {}

local by_key = {}       -- 码前缀 -> 候选条目
local LOG_N = 20200        -- log(语料总词数)*1000，由 py_meta.txt 覆盖

-- 载入归一化常数
function M.set_total_tokens(t)
    if t and t > 0 then LOG_N = math.log(t) * 1000 end
end

function M.set_log_n(v)
    if v and v > 0 then LOG_N = v end
end

function M.get_log_n() return LOG_N end

-- 单测/诊断用：按 1~2 字符前缀取条目（内部 by_key 的代理）
function M.lookup(key) return by_key[key] end

-- 二进制码表包读取（gen_compose_table.py 的 write_pack 产出）。
-- 设计：偏移索引 + 变长记录，按 code 升序 → 前缀查找 = 二分下界 + 顺序扫描。
-- 用元表代理接住 by_key[key]，所以搜索器的循环代码一行不用改。
-- 注意本文件里的字节比较一律用 byte_lt：Lua 的字符串 `<` 走 strcoll（受 locale 影响），
-- 而文件是按字节序排的 —— 用错会让二分偶发 miss（lm_rerank 踩过一次，见 PROGRESS §4.34）。
local function byte_lt(a, b)
    local n = math.min(#a, #b)
    for i = 1, n do
        local x, y = a:byte(i), b:byte(i)
        if x ~= y then return x < y end
    end
    return #a < #b
end

local pack            -- { data=, count=, index_base= }

local function u32(o)
    local b1, b2, b3, b4 = pack.data:byte(o, o + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function rec_at(i)
    -- i 从 0 开始；返回 code, 记录起点(1-based), kind, weight, text
    local p = u32(pack.index_base + i * 4) + 1     -- 索引里是 0-based 偏移 → 1-based
    local cl = pack.data:byte(p)
    local code = pack.data:sub(p + 1, p + cl)
    local q = p + 1 + cl
    local kind = pack.data:byte(q)
    local w1, w2 = pack.data:byte(q + 1, q + 2)
    local tl = pack.data:byte(q + 3)
    local text = pack.data:sub(q + 4, q + 3 + tl)
    return code, kind, w1 + w2 * 256, text
end

local function pack_prefix(key)
    -- 二分找第一个 code >= key 的位置，再向后收集所有以 key 开头的记录
    local lo, hi = 0, pack.count - 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local code = rec_at(mid)
        if byte_lt(code, key) then lo = mid + 1 else hi = mid - 1 end
    end
    local out = {}
    for i = lo, pack.count - 1 do
        local code, kind, w, text = rec_at(i)
        -- 与原 TSV 桶语义严格一致：key 长度为 1 时只取"码恰好等于该字符"的条目；
        -- 长度为 2 时取所有以该前缀开头的码（搜索循环还会按完整码再校验一次）。
        -- 用前缀语义会把 b/ba/bai… 全返回来（实测 7585 条），与原实现不等价。
        -- 注意别写成 `A and B or C`：Lua 里等价于 (A and B) or C，
        -- 兜底分支会恒定生效，过滤就失效了（这里踩过）。
        local ok
        if #key == 1 then ok = (code == key) else ok = (code:sub(1, #key) == key) end
        if not ok then break end
        out[#out + 1] = { text = text, code = code, weight = w,
                          kind = (kind == 0) and "wubi" or (kind == 1) and "pinyin" or nil }
    end
    return #out > 0 and out or nil
end

local function load_pack(path)
    local f = io.open(path, "rb")
    if not f then return false, "compose_table.bin 缺失" end
    local data = f:read("*a"); f:close()
    if not data or #data < 16 or data:sub(1, 5) ~= "EGCT1" then
        return false, "compose_table.bin 头部非法"
    end
    pack = { data = data, count = nil, index_base = 17 }   -- 1-based：magic8+count4+resv4 → 第 17 字节
    pack.count = (function()
        local b1, b2, b3, b4 = data:byte(9, 12)
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end)()
    by_key = setmetatable({}, { __index = function(_, key) return pack_prefix(key) end })
    return true, string.format("码表包 %d 条", pack.count)
end

function M.load(dir)
    -- 统一码表：text <TAB> code <TAB> weight(log 词频) <TAB> kind
    -- code 既可能是五笔短码（q/ktn/qnr/trwu）也可能是拼音串（ni/shuo/chifan）
    -- 优先二进制包（不建哈希）；没有才退回 TSV
    local okp, infop = load_pack(dir .. "/compose_table.bin")
    local okp2, infop2 = load_pack(dir .. "/dicts/compose_table.bin")
    if okp2 then okp, infop = okp2, infop2 end
    if okp then return true, infop end

    local f2 = io.open(dir .. "/compose_table.tsv", "rb")
    if not f2 then return false, "compose_table.tsv 缺失" end
    local n = 0
    for line in f2:lines() do
        local text, code, wt, kind = line:match("^(.-)	(.-)	(%d+)	(.-)$")
        if text and #code >= 1 then
            local key = #code >= 2 and code:sub(1, 2) or code
            local list = by_key[key]
            if not list then list = {}; by_key[key] = list end
            list[#list + 1] = { text = text, code = code,
                                weight = tonumber(wt) or 0,
                                kind = (kind and kind ~= "") and kind or nil }
            n = n + 1
        end
    end
    f2:close()
    for _, list in pairs(by_key) do
        table.sort(list, function(a, b)
            if #a.code ~= #b.code then return #a.code > #b.code end
            return a.weight > b.weight
        end)
    end
    return true, string.format("码表 %d 条", n)
end

--- 候选整句搜索。
-- @param input 纯小写字母串
-- @param lm    lm_rerank 模块（提供 score_segment(context, text)）
-- @param beam  每位置保留的路径数
-- @param want  返回的句子条数
-- @return list of {text=, score=}
function M.compose(input, lm, beam, want)
    beam = beam or 8
    want = want or 5
    local n = #input
    if n == 0 or n > 64 then return {} end

    local best = { [0] = { { score = 0, text = "", ctx = "" } } }
    for pos = 0, n - 1 do
        local cur = best[pos]
        if cur then
            local k1 = input:sub(pos + 1, pos + 1)
            local k2 = input:sub(pos + 1, pos + 2)
            for _, path in ipairs(cur) do
                for _, key in ipairs(k1 == k2 and { k1 } or { k2, k1 }) do
                    local list = by_key[key]
                    if list then
                        local rest = input:sub(pos + 1)
                        for _, w in ipairs(list) do
                            if rest:sub(1, #w.code) == w.code then
                                local epos = pos + #w.code
                                local lms = lm and lm.score_segment(path.ctx, w.text) or 0
                                -- 词的一元语言模型：log P(w) = log f(w) - log N
                                local sc = path.score + (w.weight - LOG_N) + lms
                                local nb = best[epos]
                                if not nb then nb = {}; best[epos] = nb end
                                -- 上下文按**字符**保留（按字节切会截断 UTF-8）
                                local ctx = path.ctx .. w.text
                                local nctx = utf8.len(ctx)
                                if nctx and nctx > 6 then
                                    local chars = {}
                                    for _, cp in utf8.codes(ctx) do
                                        chars[#chars + 1] = utf8.char(cp)
                                    end
                                    ctx = table.concat(chars, "", #chars - 5, #chars)
                                end
                                nb[#nb + 1] = { score = sc,
                                                text = path.text .. w.text,
                                                piece = { prev = path.piece, s = pos, e = epos,
                                                          kind = w.kind, code = w.code },
                                                ctx = ctx }
                            end
                        end
                    end
                end
            end
        end
        if best[pos + 1] and #best[pos + 1] > beam then
            local nb = best[pos + 1]
            table.sort(nb, function(a, b) return a.score > b.score end)
            local seen, out = {}, {}
            for _, pp in ipairs(nb) do
                if not seen[pp.text] then
                    seen[pp.text] = true
                    out[#out + 1] = pp
                    if #out >= beam then break end
                end
            end
            best[pos + 1] = out
        end
    end

    local fin = best[n]
    if not fin then return {} end
    table.sort(fin, function(a, b) return a.score > b.score end)
    local out = {}
    for i = 1, math.min(want, #fin) do
        local ps, pp = {}, fin[i].piece
        while pp do
            table.insert(ps, 1, { s = pp.s, e = pp.e, kind = pp.kind, code = pp.code })
            pp = pp.prev
        end
        out[i] = { text = fin[i].text, score = fin[i].score, pieces = ps }
    end
    return out
end

return M
