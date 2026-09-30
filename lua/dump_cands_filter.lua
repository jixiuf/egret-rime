-- lua/dump_cands_filter.lua  —— 调试用：打印整份候选表（界面只看当前段，filter 不受限）
local M = {}
function M.init(env)
    M.on = env.engine.schema.config:get_bool("dump_cands_filter/enabled")
end
function M.func(input, env)
    -- 注意：rime 的 translation 是**一次性流**，只能迭代一遍！
    -- 先收集再 yield（先前这里迭代两遍，第二遍为空 → 候选全丢，方案 0 候选）
    local cands = {}
    for cand in input:iter() do cands[#cands + 1] = cand end
    if M.on then
        for i = 1, math.min(#cands, 5) do
            local c = cands[i]
            log.error(string.format("[DUMP] #%d type=%s start=%s end=%s text=%s",
                i, tostring(c:get_dynamic_type()), tostring(c.start), tostring(c._end), c.text))
        end
        log.error(string.format("[DUMP] 共 %d 个候选", #cands))
    end
    for _, cand in ipairs(cands) do yield(cand) end
end
return M
