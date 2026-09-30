-- LM 表读端契约测试：TSV（参考实现）vs bin（运行时实现）逐键比对。
--
-- 为什么需要：2026-09 发现 bin 读端有 off-by-one，**从引入起就坏了**（190 万条里
-- 190 万条查不到），而症状只是黄金从 32 掉到 29（只有 3 条依赖 LM），极难定位。
-- 这个测试能在一秒内直接指出"读端坏了"，不必等行为回归。
--
-- 阈值：允许"查不到"，因为写端有意丢弃含 4 字节字符（扩展 B 汉字）和 ASCII
-- 句界标记($) 的键（我们的候选文本是纯汉字，永不查询它们）；**不允许数值不同**。
local ROOT = os.getenv("EGRET_ROOT") or "/export/ebook/egret-rime"
local dir = ROOT .. "/data/gram"
rime_api = { get_user_data_dir = function() return dir end }
log = { warning = function() end, error = function() end }
package.path = package.path .. ";" .. ROOT .. "/lua/?.lua"
local M = require("lm_rerank")

local ref, nref = {}, 0
for line in io.lines(dir .. "/lm_rerank.tsv") do
    local k, v = line:match("^(.-)\t(%d+)$")
    if k then ref[k] = tonumber(v); nref = nref + 1 end
end
local got = M.load("lm_rerank.tsv")           -- 同目录下优先用 .bin
if type(got) ~= "table" then
    print("  ✗ LM 表加载失败（返回 " .. tostring(got) .. "）"); os.exit(1)
end
local miss, diff, checked = 0, 0, 0
for k, v in pairs(ref) do
    checked = checked + 1
    local g = got[k]
    if g == nil then miss = miss + 1
    elseif g ~= v then diff = diff + 1; if diff <= 5 then print("  ✗ 数值不同: " .. k .. " tsv=" .. v .. " bin=" .. g) end end
end
local miss_pct = 100 * miss / checked
print(string.format("  LM 表: 比对 %d 条，数值不同 %d，查不到 %d (%.1f%%)",
                    checked, diff, miss, miss_pct))
if diff > 0 then print("  ✗ 读端与写端不一致"); os.exit(1) end
if miss_pct > 6 then print("  ✗ 查不到的条目过多（写端是否过滤过宽？）"); os.exit(1) end
print("  ✓ 读端契约通过")
