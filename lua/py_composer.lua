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

function M.load(dir)
    -- 统一码表：text <TAB> code <TAB> weight(log 词频) <TAB> kind
    -- code 既可能是五笔短码（q/ktn/qnr/trwu）也可能是拼音串（ni/shuo/chifan）
    local f2 = io.open(dir .. "/compose_table.tsv", "rb")
    if not f2 then return false, "compose_table.tsv 缺失" end
    local n = 0
    for line in f2:lines() do
        local text, code, wt = line:match("^(.-)	(.-)	(%d+)	")
        if text and #code >= 1 then
            local key = #code >= 2 and code:sub(1, 2) or code
            local list = by_key[key]
            if not list then list = {}; by_key[key] = list end
            list[#list + 1] = { text = text, code = code,
                                weight = tonumber(wt) or 0 }
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
        out[i] = { text = fin[i].text, score = fin[i].score }
    end
    return out
end

return M
