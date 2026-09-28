-- lua/dynamic_translator.lua
-- https://ksqsf.moe/posts/2023-06-01-rime-double-pinyin/

--引入 table 翻译器后，script的造词机能会有较大的问题。

-- 假设我们要造词「世间」，输入 ui jm（为了说明问题，这里不用辅助码），然后手动选择「世」字，再选择
-- 「间」字。按理来说，我们期望输入法可以造出「世间」这个词。然而不论你如何尝试，使用这种方式输入，
-- 这个词都造不出来！

-- 这里假设"世" 在script 的词典中， 而“间” 在table中
-- 这是因为当我们选择了「世」字后，输入状态只剩下了 jm，而 jm 会进入 table 翻译器，所以「间」字是
-- table 翻译器输出的。script 翻译器根本看不到我们输入了「间」字，当然也无法造出「世间」这个词了。

-- 这个问题的彻底解决可能比较复杂，目前我采用的解决办法是：当用户已经选择了部分字后，就临时禁用掉
-- table 翻译器。

-- 虽然听起来简单，但是 librime 并不能直接实现这个想法。这里我通过 librime 的 Lua 插件支持写了一个自
-- 定义的顶层翻译器实现了这个想法。顶层翻译器根据当前状态依次调用 table 和 script 翻译器。根据文档，
-- 使用 Component 实现该功能。

local dynamic = {}
-- 可以通过 指定
-- dynamic_translator
--    first_translator: table_translator@wubi_jianma2   （可选：最先查询，如传统二级简码微型库）
--    table_translator: table_translator@custom_phrase
--    script_translator: script_translator@translator

function dynamic.init(env)
    -- 创建 translator 组件，供后续调用。
    -- 注意：组件必须挂在 env 上（每个 engine 实例独立），
    -- 不能存在模块级全局变量里：rimel-regexp / liberime-search 会频繁
    -- 创建并销毁临时 session（engine），全局引用会在临时 engine 销毁后
    -- 变成悬空指针，导致默认 session 查询时 SIGSEGV。
    env.name_space = env.name_space:gsub("^*", "")
    local config = env.engine.schema.config
    local table_translator_name = config:get_string(env.name_space .. "/table_translator")
        or "table_translator@custom_phrase"
    local script_translator_name = config:get_string(env.name_space .. "/script_translator")
        or "script_translator@translator"
    -- 可选：最先查询的 translator（如拼音冲突的传统二级简码微型库）
    local first_translator_name = config:get_string(env.name_space .. "/first_translator")

    -- LM 只重排、不参与分词（纯 Lua，不改 librime）
    --   1) 临时把 grammar/language 改成一个不存在的名字 → 组句分词不再受 LM 影响
    --      （poet 这时走按词库权重的路径，并可用 max_sentences 给出多个整句候选）
    --   2) 创建完翻译器后立即恢复，不影响其它组件
    --   3) 由 lm_rerank 用紧凑 n-gram 表在 Lua 里对整句候选重排
    -- 见 docs/PROGRESS.md §4.13
    env.lm_rerank = config:get_bool(env.name_space .. "/lm_rerank")
    env.lm_debug = config:get_bool(env.name_space .. "/lm_rerank_debug")
    env.lm_keep_sentences = config:get_int(env.name_space .. "/lm_keep_sentences") or 1
    local saved_language
    if env.lm_rerank then
        saved_language = config:get_string("grammar/language")
        if saved_language and saved_language ~= "" then
            config:set_string("grammar/language", "__lm_rerank_off__")
        end
        local ok, mod = pcall(require, "lm_rerank")
        if ok and mod then
            env.lm = mod
            mod.load(config:get_string(env.name_space .. "/lm_rerank_table") or nil)
        else
            log.warning("[dynamic_translator] lm_rerank 载入失败: " .. tostring(mod))
            env.lm_rerank = false
        end
    end

    -- 纯 Lua 的拼音搜索器：让 LM 参与剪枝（而不是只做事后重排，见 lua/py_composer.lua）
    -- 注意：翻译器侧插入自建候选会被引擎在输入中途提交（实测把 jintiande 切成
    -- jinti|ande），所以默认关闭；正式路径走 lua_filter（见 lua/compose_filter.lua）
    env.lm_compose = config:get_bool(env.name_space .. "/lm_compose_translator")
    if env.lm_compose then
        local ok, cmod = pcall(require, "py_composer")
        if ok and cmod then
            local dir = rime_api.get_user_data_dir()
            local ok2, info = cmod.load(dir)
            if ok2 then
                env.composer = cmod
                log.warning("[dynamic_translator] py_composer 就绪 " .. tostring(info))
            else
                log.warning("[dynamic_translator] py_composer 载入失败: " .. tostring(info))
            end
        else
            log.warning("[dynamic_translator] py_composer 模块缺失")
        end
    end

    -- 可行性探针：验证能否按音节串查词典并拿到权重
    if config:get_bool(env.name_space .. "/lm_probe") then
        local st = Component.Translator(env.engine, "", script_translator_name)
        if st and st.dict then
            for _, code in ipairs({"taiwan", "tai wan", "wo men", "women", "ck iy", "ckiy", "ck,f0 iy,ox", "tai1wan"}) do
                local it = st.dict:lookup_words(code, true, 5)
                local n = 0
                if it then
                    for e in it:iter() do
                        n = n + 1
                        log.error(string.format("[PROBE] %-10s -> %s w=%s", code,
                            tostring(e.text), tostring(e.weight)))
                    end
                end
                if n == 0 then log.error("[PROBE] " .. code .. " -> (无)") end
            end
        else
            log.error("[PROBE] script_translator 或 dict 不可用")
        end
    end

    env.first_translator = first_translator_name
        and Component.Translator(env.engine, "", first_translator_name) or nil
    env.table_translator = Component.Translator(env.engine, "", table_translator_name)
    env.script_translator = Component.Translator(env.engine, "", script_translator_name)

    if saved_language and saved_language ~= "" then
        config:set_string("grammar/language", saved_language)
    end
end

function dynamic.fini(env)
    env.first_translator = nil
    env.table_translator = nil
    env.script_translator = nil
    env.lm = nil
end

function dynamic.func(input, seg, env)
    -- 分组而非排序(关键认知):
    -- 1) dynamic_translator 是单条翻译流, Menu 不在流内按 quality 重排;
    -- 2) script 流的原生顺序自带语义(句子 > user phrase > 词 > completion),
    --    且 Sentence 的 quality 是 log 尺度, 与 phrase 的 exp 尺度不可比;
    -- 3) 传统库 enable_completion 的补全候选(如 wan 输入时 佢/代收)会整体
    --    压在拼音候选前 → 挪到流尾; 精确码(简码/全码/词组)仍最前。
    -- 4) custom_phrase(混合库 table) 的精确词不能排在 script 句子前:
    --    混流输入 sk|yi 时, 五笔词"可就"精确匹配会压住组句"可以"
    --    (配合 translator/always_make_sentences 让 grammar 裁决)。
    -- 最终顺序: first(传统简码/词组) > script(句子/用户词/词) >
    --           custom_phrase(混合库词) > 补全(first+table 的 completion)。
    -- (选字后 table 禁用, 只剩 script 继续造词, 保持原逻辑)
    local first_early, script_cands, table_early, tail = {}, {}, {}, {}
    local function collect(res, early, to_tail)
        if res == nil then return end
        for cand in res:iter() do
            if to_tail and cand.type == "completion" then
                tail[#tail + 1] = cand
            elseif early then
                early[#early + 1] = cand
            end
        end
    end

    if (env.engine.context.input == input) then
        if env.first_translator ~= nil then
            collect(env.first_translator:query(input, seg), first_early, true)
        end
    end
    collect(env.script_translator:query(input, seg), script_cands, false)

    -- 纯拼音长输入：用小 Lua 搜索器（LM 参与剪枝）的结果置顶，
    -- librime 自己的候选全部保留在后面（不影响五笔/混流路径）
    -- 只在「整段输入」时用自建搜索器：引擎会按 tag 把输入切成片段调用翻译器，
    -- 若对片段做整句搜索，候选项只覆盖片段 → 首候选全烂（实测 0/160）
    -- 先摘掉 librime 自己的整句候选：实测「我们的候选 + librime 整句候选」共存时
    -- 引擎会在中途提交（输入被切成 jinti|ande 两段），置顶也就失效
    if env.composer and env.lm_rerank and #input >= 4 and input:match("^[a-z]+$") then
        local kept = {}
        for _, c in ipairs(script_cands) do
            if c:get_dynamic_type() ~= "Sentence" then kept[#kept + 1] = c end
        end
        script_cands = kept
    end
    if env.composer and env.lm_rerank and env.engine.context.input == input
       and #input >= 4 and input:match("^[a-z]+$") then
        local ok, res = pcall(env.composer.compose, input, env.lm,
                              env.compose_beam or 8, env.compose_want or 2)
        if ok and res and #res > 0 then
            for i = #res, 1, -1 do
                if res[i].text ~= "" then
                    table.insert(script_cands, 1,
                                 Candidate("compose", seg.start, seg._end,
                                           res[i].text, ""))
                end
            end
            log.error(string.format("[LMDBG] seg=%s ctx=%s [%s,%s] compose#1=%s",
                input, tostring(env.engine.context.input),
                tostring(seg.start), tostring(seg._end), res[1].text))
        end
    end
    -- LM 只重排：把整句候选按 n-gram 表打分重排（不改变与其它候选的分组关系）
    if env.lm_rerank and env.lm then
        if env.lm_debug then env.lm.debug(script_cands, "PRE:" .. input) end
        env.lm.rerank_sentences(script_cands)
        -- 重排后只把最佳整句留在首位，其余整句挪到尾部（避免首屏全是一字之差的整句）
        env.lm.limit_sentences(script_cands, env.lm_keep_sentences or 1)
        if env.lm_debug then env.lm.debug(script_cands, input) end
    end
    if (env.engine.context.input == input) then
        collect(env.table_translator:query(input, seg), table_early, true)
    end

    for _, cand in ipairs(first_early) do yield(cand) end
    for _, cand in ipairs(script_cands) do yield(cand) end
    for _, cand in ipairs(table_early) do yield(cand) end
    for _, cand in ipairs(tail) do yield(cand) end
end

return dynamic
