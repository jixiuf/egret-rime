-- lua/mix_segmentor.lua
-- 混流多读法切分器：用统一码表搜索器（py_composer）解析输入，把它的**分段边界**
-- 变成 rime 的段，每段按读法打 tag（wubi / py）。
--
-- 为什么：五笔码与拼音音节共享字母表，塞在同一套 prism 里时引擎只能靠权重裁决，
-- 而裁决不可控（长句失败的 100% 都是它）。切分器把"读法"变成显式信息，
-- 后续 translator 各自只看自己那段，不再赌权重。
--
-- 配方要点（子代理带 file:line 验证，见 docs/schema-components.md §6.1）：
--   · 必须排在 abc_segmentor **之后**：先 pop_back() 掉它给整段打的 abc 段，再补自己的段
--   · add_segment 的段必须与"当前 start"对齐；下一段前先 forward()
--   · 段对象用 Segment(s, e) 构造，tags 必须 **set 形式**（{[tag]=true}，数组会报错）
--   · 出错会中断方案（一个候选都没有），所以全程 pcall 兜底；正常返回 true
local M = {}

function M.init(env)
    local cfg = env.engine.schema.config
    M.enabled = cfg:get_bool("mix_segmentor/enabled")
    M.debug = cfg:get_bool("mix_segmentor/debug")
    M.min_len = cfg:get_int("mix_segmentor/min_len") or 4
    if not M.enabled then return end
    local ok1, lm = pcall(require, "lm_rerank")
    local ok2, cp = pcall(require, "py_composer")
    if ok1 and ok2 then
        M.lm, M.composer = lm, cp
        local dir = rime_api.get_user_data_dir()
        local okload, info = cp.load(dir)
        if M.debug then log.error("[MIXSEG] 码表: " .. tostring(info)) end
        for line in io.lines(dir .. "/py_meta.txt") do
            local t = line:match("^total_tokens=(%d+)$")
            if t then cp.set_total_tokens(tonumber(t)) end
        end
    end
end

function M.func(seg, env)
    if not M.enabled or not M.composer or not M.lm then return true end
    local ok = pcall(function()
        local inp = seg.input
        local s = seg:get_current_start_position()
        local e = seg:get_current_end_position()
        if M.debug then
            log.error(string.format("[MIXSEG] enter inp=%s s=%s e=%s", tostring(inp), tostring(s), tostring(e)))
        end
        if not inp or e - s < M.min_len or not inp:match("^[a-z]+$") then return end
        local res = M.composer.compose(inp, M.lm, 8, 1)
        local best = res and res[1]
        if not best or not best.pieces or #best.pieces == 0 then return end
        -- 结论（实测）：rime 里**段就是组字/上屏的单位**，段与段是顺序确认的，
        -- 不会合并成一句话 —— 所以"把输入切成多段"会直接碎掉（nihaoma -> 吗）。
        -- 正确用法：**不切段**，只在"整串被判为五笔读法"时，用等长 add_segment
        -- 给整段**补一个 wubi tag**（与 abc 段取并集）→ 绑 wubi 的 translator
        -- 就能在同一候选表里加入五笔读法的候选（其 initial_quality 高，会置顶）。
        -- 判断整串的读法：全五笔 -> 补 wubi；全拼音 -> 补 py（对称）
        local all_wubi, all_py = true, true
        for _, p in ipairs(best.pieces) do
            if p.kind ~= "wubi" then all_wubi = false end
            if p.kind ~= "pinyin" then all_py = false end
        end
        local tag = all_wubi and "wubi" or (all_py and "py") or nil
        if not tag or #best.pieces < 2 then return end
        if M.debug then
            log.error(string.format("[MIXSEG] %s -> %s | 整串 %s，补 %s tag", inp, best.text, tag, tag))
        end
        local ns = Segment(s, e)
        ns.tags = { [tag] = true }
        seg:add_segment(ns)          -- 等长 → tags 并集 {abc, wubi}
        return
    end)
    if not ok then log.error("[MIXSEG] 切分失败（已忽略，不影响原逻辑）") end
    return true
end

return M
