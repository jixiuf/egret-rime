-- lua/tail_word_filter.lua —— 长句候选页尾部保留「字/词」候选（先字修正）
--
-- 场景（用户诉求）：打长句时首屏常被整句占满，若整句的首字词不合意，没有任何
-- 可点的字/词可以「先修正开头」，只能退格重打。
--
-- 做法：首候选是**整句**（Sentence 且字数 ≥ min_sentence_len）时，重排候选流：
--   · 每页前 (page_size - keep) 个位置：整句（保持原有相对顺序）
--   · 每页最后 keep 个位置：**非整句**候选（字/词/前缀词 —— 选中后只上屏开头，
--     余下输入继续参与组句，故可用来修正长句首字词）
-- 短输入（首候选不是整句）一律原样输出，不动简码/全码/词组的手感。
--
-- 配置（egret.common.yaml: lua_config 的 tail_word_filter 块）：
--   enabled / page_size / keep / min_sentence_len / debug
-- 注意：page_size 会优先取 schema 的 menu/page_size（若方案里显式配了）。

local M = {}

local function utf8len(s)
    return utf8.len(s) or #s
end

function M.init(env)
    local config = env.engine.schema.config
    -- 配置存在 env 上（进程内多个 engine/方案实例共享 M）
    env.tail_enabled = config:get_bool("tail_word_filter/enabled")
    if env.tail_enabled == nil then env.tail_enabled = true end
    env.tail_page_size = config:get_int("tail_word_filter/page_size") or 6
    env.tail_keep = config:get_int("tail_word_filter/keep") or 2
    env.tail_min_len = config:get_int("tail_word_filter/min_sentence_len") or 4
    env.tail_debug = config:get_bool("tail_word_filter/debug")
    -- schema 自己配了 menu/page_size 时以它为准（避免与界面实际分页不一致）
    local ps = config:get_int("menu/page_size")
    if ps ~= nil and ps > 0 then
        env.tail_page_size = ps
    end
end

local function pass(cands)
    for _, cand in ipairs(cands) do
        yield(cand)
    end
end

function M.func(input, env)
    -- rime 的 translation 是一次性流：必须先收集再 yield
    local cands = {}
    for cand in input:iter() do
        cands[#cands + 1] = cand
    end
    local n = #cands
    if not env.tail_enabled or n == 0 then
        return pass(cands)
    end

    -- 只在「长句」时启用：首候选为整句且字数足够
    local first = cands[1]
    if first:get_dynamic_type() ~= "Sentence"
        or utf8len(first.text) < env.tail_min_len then
        return pass(cands)
    end

    -- 整段输入的覆盖范围（候选 _end 的最大值）
    local max_end = 0
    for _, cand in ipairs(cands) do
        if cand._end > max_end then max_end = cand._end end
    end

    local sents, words = {}, {}
    local prefix_words = 0   -- 能「先字修正」的候选：匹配输入开头且未吃完整段
    for _, cand in ipairs(cands) do
        if cand:get_dynamic_type() == "Sentence" then
            sents[#sents + 1] = cand
        else
            words[#words + 1] = cand
            if cand.start == 0 and cand._end < max_end then
                prefix_words = prefix_words + 1
            end
        end
    end
    if #sents == 0 or prefix_words == 0 then
        return pass(cands)
    end

    local page_size, keep = env.tail_page_size, env.tail_keep
    local si, wi = 1, 1
    local out = {}
    for pos = 1, n do
        local at_tail = (pos - 1) % page_size >= page_size - keep
        local cand
        if at_tail then
            if wi <= #words then
                cand, wi = words[wi], wi + 1
            elseif si <= #sents then
                cand, si = sents[si], si + 1
            end
        else
            if si <= #sents then
                cand, si = sents[si], si + 1
            elseif wi <= #words then
                cand, wi = words[wi], wi + 1
            end
        end
        if cand then out[#out + 1] = cand end
    end
    -- 兜底：两类里没用完的候选（正常不会有）按原序附在最后
    while si <= #sents do out[#out + 1] = sents[si]; si = si + 1 end
    while wi <= #words do out[#out + 1] = words[wi]; wi = wi + 1 end

    if env.tail_debug then
        log.error(string.format(
            "[TAIL] page=%d keep=%d sents=%d words=%d(prefix %d)",
            page_size, keep, #sents, #words, prefix_words))
    end
    pass(out)
end

return M
