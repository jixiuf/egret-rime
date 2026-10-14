-- lua/compose_filter.lua
-- 用统一码表搜索器（py_composer，支持五笔/拼音/混流）的结果改善候选表。
--
-- 两条路径（见 docs/PROGRESS.md §4.15 / §4.40）：
--   1) 共识重排（默认，绝对安全）：搜索器算出整句后，在**既有候选**里找同一句并前移。
--      long_word_filter 早就证明"只重排不新增"是安全的。
--   2) 注入新候选（默认关，lm_compose_inject: true 才用）：找不到同句时**新造**一条。
--      2026-09 实测：这条**能跑通**（此前认为"新增候选会让引擎中途提交"是误判 ——
--      真正的原因是当时 Constructor 用错，Candidate 是 librime-lua 注入的全局，
--      构造出来是 SimpleCandidate，type 显示 "Simple"）。
--      但目前**默认关**：搜索器只有约 26% 准确率，算错时没有可靠信号能识别，
--      无条件注入会压掉引擎本来正确的答案（实测黄金 32 -> 30）。
--      要用就得先做出可靠的置信度判据（见 score_text 的注释）。
local M = {}

-- 用同一张 n-gram 表给任意文本打分（unigram/bigram/trigram 的平均 log 值）。
-- 想用"同一把尺子"比较搜索器结果与引擎首候选时用它；实测这个平均分不足以
-- 分辨 §4.40 里那两类错案（"我今天没有中断一" 反而分更高），所以只作参考。
local function score_text(lm, text)
    if not lm or not text or text == "" then return -1e9 end
    local pos, i = {}, 1
    while i <= #text do
        local b = text:byte(i) or 0
        local len = (b < 0x80) and 1 or ((b < 0xE0) and 2 or ((b < 0xF0) and 3 or 4))
        pos[#pos + 1] = text:sub(i, i + len - 1)
        i = i + len
    end
    local s, cnt = 0, 0
    for k = 1, #pos do
        local v = lm[pos[k]]
        if v then s = s + v; cnt = cnt + 1 end
        if k > 1 then
            local v2 = lm[pos[k - 1] .. pos[k]]
            if v2 then s = s + v2; cnt = cnt + 1 end
        end
        if k > 2 then
            local v3 = lm[pos[k - 2] .. pos[k - 1] .. pos[k]]
            if v3 then s = s + v3; cnt = cnt + 1 end
        end
    end
    if cnt == 0 then return -1e9 end
    return s / cnt
end

-- 音节表（py_syllables.txt，部署时就在用户目录里）：用来判「这串输入能不能当纯拼音切」。
-- 判据的来历（§4.83）：搜索器的结果在**混打**输入上明显比引擎强（ililfbyihaole →
-- 渐渐地就好了，引擎出「渐渐地一号了」），在**纯拼音**上双方互有胜负、无条件注入会伤黄金用例
-- （§4.40 的 32→30 就是这么来的）。所以只在「含形码片段」时注入。
local syllables = nil

local function load_syllables(dir)
    if syllables then return syllables end
    local set = {}
    local f = io.open((dir or ".") .. "/py_syllables.txt")
    if not f then return nil end
    for line in f:lines() do
        local s = line:match("^%s*(%S+)")
        if s then set[s] = true end
    end
    f:close()
    syllables = set
    return set
end

-- 能否被完整切成拼音音节
local function fully_pinyin(inp, set)
    if not set then return true end          -- 没有音节表就不判，退化为旧行为
    local n = #inp
    local dp = { [0] = true }
    for i = 0, n - 1 do
        if dp[i] then
            for L = 1, 6 do
                if i + L <= n and set[inp:sub(i + 1, i + L)] then dp[i + L] = true end
            end
        end
    end
    return dp[n] == true
end

-- 是否含至少一个拼音音节（用来区分「形码+拼音混打」与「纯形码词」）
local function has_syllable(inp, set)
    if not set then return false end
    for i = 1, #inp do
        for L = 1, 6 do
            if i + L - 1 <= #inp and set[inp:sub(i, i + L - 1)] then return true end
        end
    end
    return false
end

-- 值不值得注入搜索器结果（§4.83）：**形码片段 + 拼音音节并存的长输入**。
-- 为什么收紧到这三条（都拿真实数据验过）：
--   · 长度 ≥8：五笔打词（2/3/4 字词的码固定 4 字母）是精确查表，引擎最权威 ——
--     判据放宽时 verify-wubi 五组全线崩（二字 base 40→36、三字长尾 15→0）；
--   · 含拼音音节：排除纯形码串（如 khlg）；
--   · 不能整串切成拼音：排除纯拼音长句（那里搜索器与引擎互有胜负，故不注入）。
local function want_inject(inp, set)
    return set ~= nil and #inp >= 8 and has_syllable(inp, set) and not fully_pinyin(inp, set)
end

-- py_meta.txt 的读取统一在 py_composer.load_meta 里
function M.init(env)
    local config = env.engine.schema.config
    -- 开关统一由 dynamic_translator 命名空间控制（filter 自己的 ns 读不到）
    local ns = "dynamic_translator"
    M.enabled = config:get_bool(ns .. "/lm_compose")
    M.beam = config:get_int(ns .. "/compose_beam") or 8
    M.debug = config:get_bool(ns .. "/lm_rerank_debug")
    M.inject = config:get_bool(ns .. "/lm_compose_inject")   -- 无条件注入（旧开关，默认关）
    M.inject_mixed = config:get_bool(ns .. "/compose_inject_mixed")  -- 只对混打注入（§4.83）
    M.lm, M.composer = nil, nil
    if M.enabled then
        local ok1, lm = pcall(require, "lm_rerank")
        local ok2, cp = pcall(require, "py_composer")
        if ok1 and ok2 then
            M.lm = lm; M.composer = cp
            local dir = rime_api.get_user_data_dir()
            cp.load(dir)
            cp.load_meta(dir)
            load_syllables(dir)
            local ln = config:get_int(ns .. "/compose_log_n")
            if ln and ln > 0 then cp.set_log_n(ln) end
        end
    end
end

function M.func(input, env)
    local composed = nil
    local inp = env.engine.context.input
    -- 判据：只有「形码片段 + 拼音音节并存的长输入」才让搜索器插手（两条路径都受它约束）。
    -- 此前只约束注入路径、放开共识重排：结果 `kkkk`（纯形码 4 码）被搜索器的「咒骂」
    -- 前移成了首候选 ⇒ 五笔打词全线受影响（§4.83）。
    local allow = M.inject or (M.inject_mixed and want_inject(inp, syllables))
    if M.enabled and allow and M.composer and M.lm and #inp >= 4 and inp:match("^[a-z]+$") then
        local ok, res = pcall(M.composer.compose, inp, M.lm, M.beam, 1)
        if ok and res and res[1] and res[1].text ~= "" then
            composed = res[1].text
        end
    end

    local cands = {}
    for cand in input:iter() do cands[#cands + 1] = cand end

    if composed and #inp >= 4 and #cands > 0 then
        local r = nil
        for i, cand in ipairs(cands) do
            if cand.text:sub(1, #composed) == composed then r = i; break end
        end
        if r and r > 1 then
            -- 路径 1：共识重排（安全）
            local hit = table.remove(cands, r)
            table.insert(cands, 1, hit)
        elseif allow and not r and cands[1] then
            -- 路径 2：注入（默认关，见文件头注释）
            local c0 = cands[1]
            local okc, nc = pcall(function()
                return Candidate("sentence", c0.start, c0._end, composed, "")
            end)
            if okc and nc then
                table.insert(cands, 1, nc)
                if M.debug then
                    log.error("[CF] NEW cand OK: " .. composed ..
                              " type=" .. tostring(nc:get_dynamic_type()) ..
                              " score=" .. string.format("%.1f", score_text(M.lm, composed)) ..
                              " vs top=" .. string.format("%.1f", score_text(M.lm, cands[2].text)))
                end
            elseif M.debug then
                log.error("[CF] NEW cand FAILED: " .. composed .. " err=" .. tostring(nc))
            end
        end
        if M.debug then
            log.error(string.format("[CF] compose=%s hit=%s mixed=%s n=%d top=%s",
                composed, tostring(r), tostring(want_inject(inp, syllables)),
                #cands, cands[1] and cands[1].text or "-"))
        end
    end

    for _, cand in ipairs(cands) do yield(cand) end
end

return M
