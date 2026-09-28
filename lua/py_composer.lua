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

local syl_set = {}
local by_first = {}
local MAX_SYL = 6
local LOG_N = 20200        -- log(语料总词数)*1000，由 py_meta.txt 覆盖

-- 载入归一化常数
function M.set_total_tokens(t)
    if t and t > 0 then LOG_N = math.log(t) * 1000 end
end

function M.load(dir)
    local f = io.open(dir .. "/py_syllables.txt", "rb")
    if not f then return false, "py_syllables.txt 缺失" end
    local ns = 0
    for line in f:lines() do
        if line ~= "" then syl_set[line] = true; ns = ns + 1 end
    end
    f:close()

    local f2 = io.open(dir .. "/py_words.tsv", "rb")
    if not f2 then return false, "py_words.tsv 缺失" end
    local nw = 0
    for line in f2:lines() do
        local w, code, wt = line:match("^(.-)\t(.-)\t(%d+)$")
        if w then
            local first = code:match("^[^ ]+")
            local concat = code:gsub(" ", "")
            local list = by_first[first]
            if not list then list = {}; by_first[first] = list end
            list[#list + 1] = { text = w, concat = concat,
                                weight = tonumber(wt) or 0 }
            nw = nw + 1
        end
    end
    f2:close()
    for _, list in pairs(by_first) do
        table.sort(list, function(a, b)
            if #a.concat ~= #b.concat then return #a.concat > #b.concat end
            return a.weight > b.weight
        end)
    end
    return true, string.format("音节 %d / 词条 %d", ns, nw)
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
            for _, path in ipairs(cur) do
                for L = math.min(MAX_SYL, n - pos), 1, -1 do
                    local syl = input:sub(pos + 1, pos + L)
                    local list = syl_set[syl] and by_first[syl]
                    if list then
                        local rest = input:sub(pos + 1)
                        for _, w in ipairs(list) do
                            if rest:sub(1, #w.concat) == w.concat then
                                local epos = pos + #w.concat
                                -- 词的一元语言模型：log P(w) = log f(w) - log N
                                -- （必须减 log N，否则"切得越碎分越高"：
                                --   Σlog f 随段数单调增大 → 今天 会输给 进+提案）
                                local lms = lm and lm.score_segment(path.ctx, w.text) or 0
                                local sc = path.score + (w.weight - LOG_N) + lms
                                local nb = best[epos]
                                if not nb then nb = {}; best[epos] = nb end
                                local ctx = path.ctx .. w.text
                                if #ctx > 6 then ctx = ctx:sub(-6) end
                                nb[#nb + 1] = { score = sc, text = path.text .. w.text,
                                                ctx = ctx }
                            end
                        end
                    end
                end
            end
        end
        local nb = best[pos + 1]
        if nb and #nb > beam then
            table.sort(nb, function(a, b) return a.score > b.score end)
            -- 同位置按文本去重，避免同一句堆满 beam
            local seen, out = {}, {}
            for _, p in ipairs(nb) do
                if not seen[p.text] then
                    seen[p.text] = true
                    out[#out + 1] = p
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
