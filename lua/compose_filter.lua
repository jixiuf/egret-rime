-- lua/compose_filter.lua
-- 用 Lua 搜索器的结果**改写**最终候选表里的整句候选。
-- 为什么用 filter 而不是 translator：实测把自建候选插进 translator 的输出流、
-- 且置于首位时，引擎会在输入中途提交（输入被切成 jinti|ande），置顶失效。
-- filter 拿到的是已经成型的候选表，改写它的文本不影响翻译迭代。
local M = {}

function M.init(env)
    local config = env.engine.schema.config
    -- 开关统一由 dynamic_translator 命名空间控制（filter 自己的 ns 读不到）
    local ns = "dynamic_translator"
    M.enabled = config:get_bool(ns .. "/lm_compose")
    M.beam = config:get_int(ns .. "/compose_beam") or 8
    M.debug = config:get_bool(ns .. "/lm_rerank_debug")
    M.lm, M.composer = nil, nil
    if M.enabled then
        local ok1, lm = pcall(require, "lm_rerank")
        local ok2, cp = pcall(require, "py_composer")
        if ok1 and ok2 then
            M.lm = lm; M.composer = cp
            local dir = rime_api.get_user_data_dir()
            cp.load(dir)
            for line in io.lines(dir .. "/py_meta.txt") do
                local t = line:match("^total_tokens=(%d+)$")
                if t then cp.set_total_tokens(tonumber(t)) end
            end
            local ln = config:get_int(ns .. "/compose_log_n")
            if ln and ln > 0 then cp.set_log_n(ln) end
        end
    end
end

function M.func(input, env)
    local composed = nil
    local inp = env.engine.context.input
    if M.enabled and M.composer and M.lm and #inp >= 4 and inp:match("^[a-z]+$") then
        local ok, res = pcall(M.composer.compose, inp, M.lm, M.beam, 1)
        if ok and res and res[1] and res[1].text ~= "" then
            composed = res[1].text
            if M.debug then
                log.error(string.format("[LMDBG] compose %s -> %s", inp, composed))
            end
        end
    end
    -- 关键认知（实测得来）：
    --   1) 五笔输入时传统词组精确匹配会让 librime **完全不产生整句候选**
    --      （script_translator 的 has_reliable_phrase 判断），所以必须主动出手；
    --   2) 但**新增**候选（无论区间取 [0,#input] 还是沿用别人的）都会让引擎
    --      以为整段已被消费 → 输入中途提交、首字被吞（实测 的天气怎么样）。
    --   所以正确做法是：**只改写既有候选的文本**，绝不新增。
    local cands = {}
    for cand in input:iter() do cands[#cands + 1] = cand end
    if composed and #inp >= 5 and #cands > 0 then
        -- 「共识重排」：我们的搜索器（统一码表，支持五笔/拼音/混流）给出整句后，
        -- 在既有候选里找**同一个句子**，把它移到最前。
        -- 关键：只**重排既有候选**（long_word_filter 已证明安全），
        -- 绝不新增候选、绝不改写文本——那两条路都会让引擎中途提交（见 PROGRESS §4.15）。
        local r = nil
        for i, cand in ipairs(cands) do
            if cand.text:sub(1, #composed) == composed then r = i break end
        end
        if M.debug then
            log.error(string.format("[CF] compose=%s hit=%s n=%d top=%s",
                composed, tostring(r), #cands, cands[1] and cands[1].text or "-"))
        end
        if r and r > 1 then
            local hit = table.remove(cands, r)
            table.insert(cands, 1, hit)
        end
    end
    for _, cand in ipairs(cands) do yield(cand) end
end

return M
