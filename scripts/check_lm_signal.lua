local ROOT="/export/ebook/egret-rime"; local dir=ROOT.."/data/gram"
rime_api={get_user_data_dir=function() return dir end}
log={warning=function(...) print("  WARN:",...) end, error=function() end}
package.path=package.path..";"..ROOT.."/lua/?.lua"
local lm=require("lm_rerank")
print("load:", lm.load("lm_rerank.tsv"))
-- 搜索器就是调这个函数打分；看它是否给出非零信息
for _, c in ipairs{{"画","上"},{"花","上"},{"周","勃"},{"周","波"},{"","画"},{"","花"}} do
  print(string.format("  score_segment(ctx=%-3s, text=%s) = %8.3f", c[1], c[2], lm.score_segment(c[1], c[2])))
end
print(string.format("  score('画上小天使们')=%8.3f   score('花上小天师门')=%8.3f",
      lm.score("画上小天使们"), lm.score("花上小天师门")))
