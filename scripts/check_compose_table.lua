-- 码表读端契约测试：TSV（参考实现）vs 二进制包（运行时实现）逐前缀比对。
--
-- 为什么必须有：lm_rerank 的 bin 读端曾因 off-by-one 从引入起就坏掉
-- （190 万条全查不到，症状只是黄金 32->29，极难定位，见 PROGRESS §4.34）。
-- 码表读端同样是"二进制 + 二分"，必须用同样的对照测试兜住。
local ROOT = os.getenv("EGRET_ROOT") or "/export/ebook/egret-rime"
local dir = ROOT .. "/data/gram"
rime_api = { get_user_data_dir = function() return dir end }
log = { warning = function() end, error = function() end }
package.path = package.path .. ";" .. ROOT .. "/lua/?.lua"
local cp = require("py_composer")

-- 参考实现：按老办法从 TSV 建哈希（key = 码的前 1~2 字符）
local ref, nref = {}, 0
for line in io.lines(dir .. "/compose_table.tsv") do
    local text, code, wt, kind = line:match("^(.-)\t(.-)\t(%d+)\t(.-)$")
    if text and code and #code >= 1 then
        local key = #code >= 2 and code:sub(1, 2) or code
        local list = ref[key]
        if not list then list = {}; ref[key] = list end
        list[#list + 1] = { text = text, code = code, weight = tonumber(wt) or 0, kind = kind }
        nref = nref + 1
    end
end

local ok, info = cp.load(dir)
if not ok then print("  ✗ 码表加载失败: " .. tostring(info)); os.exit(1) end
assert(info:find("码表包"), "  读端没有用上 .bin（当前: " .. tostring(info) .. "）")

local bad_key, bad_entry, checked, keys = 0, 0, 0, 0
for key, list in pairs(ref) do
    keys = keys + 1
    local got = cp.lookup(key)
    if not got then bad_key = bad_key + 1
    elseif #got ~= #list then
        bad_entry = bad_entry + 1
        if bad_entry <= 3 then
            print(string.format("  ✗ key=%s 参考 %d 条 / 读端 %d 条", key, #list, #got))
            for i = 1, math.min(#list, 3) do
                print(string.format("      ref[%d]=%s|%s", i, list[i].text, list[i].code))
            end
            for i = 1, math.min(#got, 3) do
                print(string.format("      got[%d]=%s|%s", i, got[i].text, got[i].code))
            end
        end
    else
        local seen = {}
        for _, e in ipairs(got) do seen[e.text .. "|" .. e.code .. "|" .. tostring(e.weight)] = true end
        for _, e in ipairs(list) do
            checked = checked + 1
            local k = e.text .. "|" .. e.code .. "|" .. tostring(e.weight)
            if not seen[k] then bad_entry = bad_entry + 1; break end
        end
    end
end
print(string.format("  码表: 参考 %d 条 / %d 个前缀；前缀查不到 %d，条目不一致 %d（比对 %d 条）",
                    nref, keys, bad_key, bad_entry, checked))
if bad_key > 0 or bad_entry > 0 then print("  ✗ 读端与参考实现不一致"); os.exit(1) end
print("  ✓ 码表读端契约通过")
