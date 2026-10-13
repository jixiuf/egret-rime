-- lua/tail_word_filter.lua —— 长句候选页尾部保留「字 + 词」候选（先字修正）
--
-- 场景（用户诉求）：打长句时首屏常被整句占满，若整句的首字/首词不合意，没有任何
-- 可点的字或词能「先修正开头」，只能退格重打。
--
-- 做法：首候选是**整句**（Sentence 且字数 ≥ min_sentence_len）时，重排候选流：
--   · 每页前 (page_size - tail 槽数) 个位置：整句（保持原有相对顺序）
--   · 每页尾部按 tail_spec 排：默认 "char,word" ⇒ 倒数第 2 位放**单字**、
--     最后 1 位放**词**（均匹配输入开头、未吃完整段 ⇒ 选中只上屏前缀，
--     余下输入继续参与组句）
-- 短输入（首候选不是整句）一律原样输出，不动简码/全码/词组的手感。
--
-- 配置（egret.common.yaml: lua_config 的 tail_word_filter 块）：
--   enabled / page_size / tail_spec / min_sentence_len / debug
-- 注意：page_size 会优先取 schema 的 menu/page_size（若方案里显式配了）。

local M = {}

local function utf8len(s)
    return utf8.len(s) or #s
end

local function first_char(s)
    if not s or s == "" then
        return nil
    end
    local nxt = utf8.offset(s, 2)   -- 第二个字符的字节位置；nil 表示只有一个字
    return nxt and s:sub(1, nxt - 1) or s
end

local function parse_spec(spec)
    local out = {}
    for cat in tostring(spec):gmatch("[^,%s]+") do
        cat = cat:lower()
        if cat == "char" or cat == "word" then
            out[#out + 1] = cat
        end
    end
    if #out == 0 then
        out = { "char", "word" }
    end
    return out
end

function M.init(env)
    local config = env.engine.schema.config
    -- 配置存在 env 上（进程内多个 engine/方案实例共享 M）
    env.tail_enabled = config:get_bool("tail_word_filter/enabled")
    if env.tail_enabled == nil then env.tail_enabled = true end
    env.tail_page_size = config:get_int("tail_word_filter/page_size") or 6
    env.tail_spec = parse_spec(config:get_string("tail_word_filter/tail_spec")
                               or "char,word")
    env.tail_min_len = config:get_int("tail_word_filter/min_sentence_len") or 4
    env.tail_dedupe = config:get_bool("tail_word_filter/dedupe")
    if env.tail_dedupe == nil then env.tail_dedupe = true end
    env.tail_debug = config:get_bool("tail_word_filter/debug")
    -- schema 自己配了 menu/page_size 时以它为准（避免与界面实际分页不一致）
    local ps = config:get_int("menu/page_size")
    if ps ~= nil and ps > 0 then
        env.tail_page_size = ps
    end
end

function M.func(input, env)
    -- 注意：input:iter() 是 C 迭代器，只能由 `for ... in` 驱动（手动 it() 会报
    -- "bad argument #2 ... Translation expected"）。所以用一趟循环 + mode 状态：
    --   pass   = 非长句：逐条惰性 yield（不缓冲，不拖累下游 filter）
    --   buffer = 长句：缓存整份候选后重排（顺便按文本去重，见下）
    local first, mode = nil, nil
    local seen, cands = {}, {}

    local function not_seen(c)
        if env.tail_dedupe and seen[c.text] then
            return false
        end
        seen[c.text] = true
        return true
    end

    for cand in input:iter() do
        if mode == nil then
            first = cand
            mode = (env.tail_enabled
                    and cand:get_dynamic_type() == "Sentence"
                    and utf8len(cand.text) >= env.tail_min_len) and "buffer" or "pass"
        end
        if mode == "pass" then
            if not_seen(cand) then
                yield(cand)
            end
        elseif not_seen(cand) then
            cands[#cands + 1] = cand
        end
    end
    if mode ~= "buffer" then
        return          -- 非长句：已惰性透传完毕
    end
    local n = #cands
    if n == 0 then
        return
    end

    -- 整段输入的覆盖范围（候选 _end 的最大值）
    local max_end = 0
    for _, cand in ipairs(cands) do
        if cand._end > max_end then max_end = cand._end end
    end

    local sents, chars, words = {}, {}, {}
    local prefix_count = { char = 0, word = 0 }
    for _, cand in ipairs(cands) do
        if cand:get_dynamic_type() == "Sentence" then
            sents[#sents + 1] = cand
        elseif cand.start == 0 and cand._end < max_end then
            -- 能「先修正」的候选：匹配输入开头且未吃完整段
            if utf8len(cand.text) == 1 then
                chars[#chars + 1] = cand
                prefix_count.char = prefix_count.char + 1
            else
                words[#words + 1] = cand
                prefix_count.word = prefix_count.word + 1
            end
        end
    end
    if #sents == 0 or (prefix_count.char == 0 and prefix_count.word == 0) then
        for _, c in ipairs(cands) do yield(c) end
        return
    end

    -- 「字」优先取**首句的第一个字**（先字修正就该修它）：
    -- 候选流里的单字按频率排序（jin → 进/金/近…），未必是句子那个字（今），
    -- 但候选里通常有 —— 找到就挪到字队列首位，找不到就用最高权单字。
    local head_char = first_char(first.text)
    if head_char and #chars > 0 and chars[1].text ~= head_char then
        for i = 2, #chars do
            if chars[i].text == head_char then
                local c = table.remove(chars, i)
                table.insert(chars, 1, c)
                break
            end
        end
    end

    local page_size, spec = env.tail_page_size, env.tail_spec
    local tail_n = #spec
    local queues = { char = chars, word = words, sent = sents }
    local idx = { char = 1, word = 1, sent = 1 }
    local other = { char = "word", word = "char" }
    local function take(cat)
        local q, i = queues[cat], idx[cat]
        if q and i <= #q then
            idx[cat] = i + 1
            return q[i]
        end
        return nil
    end

    local out = {}
    for pos = 1, n do
        local cand
        local in_page = (pos - 1) % page_size + 1
        local slot = in_page - (page_size - tail_n)   -- > 0 表示落在页尾槽位
        if slot > 0 then
            local cat = spec[slot]
            cand = take(cat) or take(other[cat]) or take("sent")
        else
            -- 前面几项：整句优先，其次词（字留给页尾，避免页首混进孤字）
            cand = take("sent") or take("word") or take("char")
        end
        if cand then out[#out + 1] = cand end
    end
    -- 兜底：没用完的候选按「整句 → 字 → 词」附在最后（正常不会剩）
    for _, cat in ipairs({ "sent", "char", "word" }) do
        local q, i = queues[cat], idx[cat]
        while i <= #q do out[#out + 1] = q[i]; i = i + 1 end
    end

    if env.tail_debug then
        log.error(string.format(
            "[TAIL] page=%d spec=%s sents=%d chars=%d words=%d",
            page_size, table.concat(spec, ","), #sents, #chars, #words))
    end
    for _, c in ipairs(out) do yield(c) end
end

return M
