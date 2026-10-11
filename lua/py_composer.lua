-- lua/py_composer.lua
-- 纯 Lua 的「拼音 → 句子」搜索（LM 真正参与剪枝，不是事后重排）
--
-- 为什么要自己搜（docs/PROGRESS.md §4.x）：
--   librime 的组句是"先按词库权重 beam search 剪枝 → 再重排"。实测 66% 的正确句
--   根本进不了候选（按权重的 beam 饱和），LM 再准也没用。
--   librime-lua 只能按单音节查词典（多音节 code 查不到），所以在 Lua 里自建：
--     1) 词表（word → 音节串 → 语料 log 词频权重）
--     2) 在输入串上做 beam search，打分 = 词权重 + LM（同尺度，直接相加）
--   性能（§4.50）：切分器对**每个前缀**都调一次 compose，故 beam 状态按输入前缀**增量缓存**
--   （位置 p 的状态只由前 p 个字符决定），每键从 O(位置数) 降到 O(1 个位置)。
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

-- 增量缓存（§4.50）：切分器对**每个前缀**都调一次 `compose`（52 字母输入 = 52 次），
-- 而 beam 在位置 p 的状态只由输入的前 p 个字符决定、**不随后续输入改变**
-- → 输入只增长时只需补算新增位置。判定结果与逐次重算**逐字节相同**，
-- 但每键成本从 O(位置数) 降到 O(1 个位置)。
local MAX_CODE_LEN = 16     -- 码表最长码长（实测 15: jiangshangzhang）；契约测试兜住
local cache = { beam = nil, input = "", best = nil }

-- LM 增益（score_segment）记忆化。
-- 为何有效：增量缓存每键要回扫 MAX_CODE_LEN 个位置，而相邻两次回扫的 (上下文,词)
-- 组合高度重复；score_segment 是纯查表，重复算就是白烧（它是整个搜索器 ~80% 的开销）。
-- 容量保护：超过 20 万条就直接清空（条目与词表同量级，不会无限涨）。
local gain_cache, gain_n = {}, 0

local function gain_of(lm, ctx, text)
    if not lm then return 0 end
    local key = ctx .. "\1" .. text
    local v = gain_cache[key]
    if v ~= nil then return v end
    v = lm.score_segment(ctx, text) or 0
    if gain_n > 200000 then gain_cache, gain_n = {}, 0 end
    gain_cache[key] = v
    gain_n = gain_n + 1
    return v
end

function M.reset_cache()
    cache.beam, cache.input, cache.best = nil, "", nil
    gain_cache, gain_n = {}, 0        -- LM 表可能被重新载入，增益记忆化一并失效
end

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
    -- 前缀桶**记忆化**：pack_prefix 每次调用都要做一次二分 + 为桶里每条记录新建
    -- 一张表 + 切一次码串（平均 406 条），而 compose 里每个位置×每条路径都会取一次；
    -- 桶内容对固定码表是常量 ⇒ 第一次算完就 rawset 回去。（只读使用，调用方不改它。）
    by_key = setmetatable({}, { __index = function(t, key)
        local v = pack_prefix(key)
        if v then rawset(t, key, v) end
        return v
    end })
    return true, string.format("码表包 %d 条", pack.count)
end

function M.load(dir)
    -- 统一码表：text <TAB> code <TAB> weight(log 词频) <TAB> kind
    -- code 既可能是五笔短码（q/ktn/qnr/trwu）也可能是拼音串（ni/shuo/chifan）
    -- 优先二进制包（不建哈希）；没有才退回 TSV
    local okp, infop = load_pack(dir .. "/compose_table.bin")
    local okp2, infop2 = load_pack(dir .. "/dicts/compose_table.bin")
    if okp2 then okp, infop = okp2, infop2 end
    M.reset_cache()
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

    -- 复用上一次的 beam 状态（仅当 beam 宽度相同、且新输入以上次输入为前缀）
    -- 为何不能简单地从上次长度接着算：候选是按当前位置的 1~2 字前缀查的
    -- （k2 = input[pos+1..pos+2]），而旧输入末尾处的 k2 是**截断**的（少查一个桶），
    -- 那些「跨到新字符才成立」的候选当时被 rest 长度过滤掉了。
    -- 所以：老位置里只有 [base+1-MAX_CODE_LEN, base-1] 这一段会向**新位置**产出候选
    -- → 回扫这段窗口，只补 epos > base 的候选（老位置的格子不动、不重算）。
    local base, best
    if cache.best and cache.beam == beam and #cache.input <= n
       and input:sub(1, #cache.input) == cache.input then
        base, best = #cache.input, cache.best
        for i = base + 1, n do best[i] = nil end   -- 上一轮多算的（输入变短不可能到这么）
    else
        base, best = 0, { [0] = { { score = 0, text = "", ctx = "" } } }
    end
    local from = 0
    if base > 0 then
        from = base + 1 - MAX_CODE_LEN
        if from < 0 then from = 0 end
    end
    -- 把「候选 → 新路径」的构造抽成闭包：避免在下面的双层循环里重复这段（含 UTF-8 截断）
    local function push(path, w, pos, epos)
        if epos <= base then return end          -- 老位置上一轮已经填好（不重算、不改动）
        local lms = gain_of(lm, path.ctx, w.text)
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
    for pos = from, n - 1 do
        local cur = best[pos]
        if cur then
            -- 候选枚举保持原样（by_key 前缀桶 + 前缀匹配）；改造只在「不重算已定型的位置」
            local k1 = input:sub(pos + 1, pos + 1)
            local k2 = input:sub(pos + 1, pos + 2)
            local rest = input:sub(pos + 1)
            for _, path in ipairs(cur) do
                for _, key in ipairs(k1 == k2 and { k1 } or { k2, k1 }) do
                    local blist = by_key[key]
                    if blist then
                        for _, w in ipairs(blist) do
                            if rest:sub(1, #w.code) == w.code then
                                push(path, w, pos, pos + #w.code)
                            end
                        end
                    end
                end
            end
        end
        if pos + 1 > base and best[pos + 1] and #best[pos + 1] > beam then
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
    cache.beam, cache.input, cache.best = beam, input, best
    collectgarbage("step")   -- TEST: 每键推一步 GC
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
