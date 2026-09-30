# Rime tag→translator 路由调研 + lua_segmentor 原型验证

环境: /export/ebook/egret-rime，librime pin 1.17.0 + librime-lua(ad1e4a6)。
实验目录: /tmp/rime-tag-proto（未改动仓库任何文件）。复现: `bash /tmp/rime-tag-proto/run.sh`

## 结论摘要
1. **引擎不做 tag 路由**：`TranslateSegments` 对每个 segment 调用**所有** translator 的 `Query`（engine.cc:215）；是否处理由 **translator 自己**看 `segment.HasTag()` 决定。
2. 内建 `table_translator`/`script_translator` 用 `segment.HasAnyTagIn(tags_)` 自检；`tags_` 来自 `TranslatorOptions`，配置键 `<name_space>/tag` 与 `<name_space>/tags`，默认 `{"abc"}`（translator_commons.cc:141-153）。
3. **`lua_translator` 没有任何 tag 支持**（lua_gears.h:65 `class LuaTranslator : public Translator`，无 TagMatching），`Query` 直接调 lua func（lua_gears.cc:177），配置里的 `tag:`/`tags:` 被**静默忽略** —— 这正是你的 probe_translator 不出候选的原因。必须在 lua func 里自己 `seg:has_tag(...)`。
4. `LuaSegmentor::Proceed` 返回值：**true=继续调用后面的 segmentor；false=终止本轮 segmentor 链**（engine.cc:180-182）。出错时返回 **true**（lua_gears.cc:209-211），即"继续"而非"接管跳过"——你笔记 #3 的括号语义是反的；错误其实不会跳过 abc_segmentor。
5. 自定义 tag 要生效必须走 `add_segment` 的**等长合并**规则（segmentation.cc:98-107）：新建 `Segment(j,k)`（与 abc 段完全同起止）+ `ns.tags = { [tag]=true }`（**set 形式**，数组形式 `{tag}` 会 lua 报错 `invalid key to 'next'`）。

## A. tag→translator 路由机制 (file:line)
- `engine.cc:203-231 ConcreteEngine::TranslateSegments`：遍历**每个** translator，无条件调用 `translator->Query(input, segment)`（`engine.cc:215`）；无任何 tag 判断/分派。
- 各 translator 自检：
  - `table_translator.cc:246` `if (!segment.HasAnyTagIn(tags_)) return nullptr;`
  - `script_translator.cc:211` 同上
  - `reverse_lookup_translator.cc:145` `if (!segment.HasTag(tag_)) return nullptr;`
  - `history_translator.cc:34` 同上
  - `Segment::HasTag/HasAnyTagIn`：`segmentation.h:50-53`
- `tags_` 来源：`translator_commons.cc:115-153 TranslatorOptions`；默认 `translator_commons.h:174 vector<string> tags_{"abc"}`。
- 结论：**translator 声明 tag（内建），不是引擎按 tag 选**；`lua_translator` 连声明都不支持。

## B. 各 translator 的 tag 配置键与默认值
| 组件 | 配置键 | 语义 | 默认 |
|---|---|---|---|
| `table_translator` | `<ns>/tag` | 覆盖 tags_[0] | `abc` |
| `table_translator` | `<ns>/tags` (list) | 追加多个 | — |
| `script_translator` | 同上 | 同上 | `abc` |
| `reverse_lookup_translator` | `<ns>/tag` | 单一 tag | `abc`（但用 recognizer 自动打 tag） |
| `history_translator` | `<ns>/tag` | 单一 tag | `abc` |
| `lua_translator` | **无** | 不支持，忽略 `tag:`/`tags:` | — |
| `lua_filter` | `<ns>/tags` (经 TagMatching) | 只允许这些 tag 的段调用；空=全匹配 | 全匹配 |
| `lua_filter` | lua 里 `tags_match(seg, env)` 函数 | 覆盖 TagsMatch | — |
（`ns` = `组件@别名` 中 `@` 后的别名；`lua_filter@*foo` 的 ns 含 `*`，TagMatching 读的是 `*foo/tags`，注意）
证据：translator_commons.cc:141/148/153；filter_commons.cc:14-37；lua_gears.h:35+43-58。

## C. lua_segmentor 返回值语义 + 能力边界
- `LuaSegmentor::Proceed` = lua func 的返回值；error → `return true`（lua_gears.cc:204-214，209 行 log，211 行 return true）。
- `engine.cc:180-182`：`for (segmentor) { if (!Proceed()) break; }` → **true=继续下一个 segmentor，false=停止本轮链**。
- 可用的 Segmentation 方法（types.cc:458-530）：`add_segment(Segment)`、`forward()`、`trim()`、`pop_back()`、`back()`、`get_at(i)`、`get_segments()`、`empty()`、`has_finished_segmentation()`、`get_current_start/end_position()`、`get_current_segment_length()`、`get_confirmed_position()`；字段 `input`、`size`。
- Segment 方法/字段：`has_tag`、`active_text`、`spans`、`clear/close/reopen`；字段 `start`、`_end`、`length`、`tags`、`status`、`selected_index`（types.cc:119-205）。
- `add_segment` 不变量（segmentation.cc:84-108）：① 新段 start 必须 == 当前 start，否则**返回 false 丢弃**；② 比现有段长则**覆盖**（丢掉原 tags）；③ 等长则**并集 tags**；④ 更短则忽略。
- 结论：想给 abc 段"挂"自定义 tag = 造**等长**段。想让一段变多段 = `pop_back()` + 逐段 `add_segment` + `forward()`，段必须首尾相接、不重叠。

## D. 最小配方（可跑通）
见 `/tmp/rime-tag-proto/`：`tagprobe.schema.yaml` + `tagprobe.dict.yaml` + `lua/tagprobe.lua` + `run.sh`。
关键配置：
```yaml
engine:
  segmentors: [abc_segmentor, lua_segmentor@*tagprobe*route_seg, fallback_segmentor]
  translators:
    - table_translator@py_table      # config tag: py
    - table_translator@wubi_table    # config tag: wubi
    - lua_translator@*tagprobe*self_tag_translator  # 自检 seg:has_tag
  filters: [lua_filter@*tagprobe*dump_filter]
py_table:   { dictionary: tagprobe, tag: py,   enable_completion: false, enable_sentence: false }
wubi_table: { dictionary: tagprobe, tag: wubi, enable_completion: false, enable_sentence: false }
```
关键 lua（等长合并 tag + 自检）：
```lua
M.route_seg = { func = function(seg, env)
  local s = seg:back(); local j,k = s.start, s._end
  local text = seg.input:sub(j+1,k); local tag = (text:sub(1,1)=="p") and "py" or (text:sub(1,1)=="w") and "wubi"
  if tag then local ns = Segment(j,k); ns.tags = { [tag]=true }; seg:add_segment(ns) end
  return true  -- true=继续
end }
M.self_tag_translator = { func = function(input, seg, env)
  if seg:has_tag("py") or seg:has_tag("wubi") then
    yield(Candidate("lua", seg.start, seg._end, "LUA_TAG_OK("..input..")", "tags=..."))
  end
end }
```
命令：
```bash
cd /tmp/rime-tag-proto
B=/export/ebook/egret-rime/third-party/librime/build/bin
$B/rime_deployer --build . /export/ebook/egret-rime/data/rime-shared ./build
printf '\n' | $B/rime_api_console >/dev/null 2>&1   # 热机
printf 'py\n\n'   | $B/rime_api_console 2>&1 | grep FILTER
printf 'wubi\n\n' | $B/rime_api_console 2>&1 | grep FILTER
```
实测（节选）：
- `py`  → tags={abc,py}  → py_table 出 `拼音段命中/PY_TABLE_HIT`，wubi_table 0 个 ✔
- `wubi`→ tags={abc,wubi}→ wubi_table 出 `五笔段命中/WUBI_TABLE_HIT`，py_table 0 个 ✔
- `abcd`→ tags={abc}     → 两个 table 都 0 个；但 `[LUA_TR] Query input='abcd' tags={abc}` 仍被调用 ✔（证明 lua_translator 不看 tag 配置）
额外（分段）：`wupi` 被 lua_segmentor 切成 [0,2){wubi}+[2,4){py}，分别命中 wubi_table/py_table。

## E. 对混流场景的建议
- 每个 lua translator 内部用 `seg:has_tag("wubi")` / `seg:has_tag("py")` 自检（或改用内建 table/script_translator + `tag:` 声明）。别再指望 lua_translator 的 `tag:` 配置。
- 想在一段里混切：用 `abc_segmentor/extra_tags` 只能给**所有** abc 段加同一 tag（abc_segmentor.cc:26-29,61-63），做不到按内容分别打 tag；按内容分 tag 必须用 lua_segmentor。
- lua_segmentor 里打 tag 的三条铁律：段必须与当前段**等长**（否则覆盖/丢弃）、`tags` 用 **set 形式**、`return true`。
- 想分成多个 segment：`pop_back()` → `add_segment(s1)` → `forward()` → `add_segment(s2)` …，段首尾相接；然后各段自然被对应 tag 的 translator 处理（引擎对每段都调全部 translator）。
- 调试：用 `lua_filter` 遍历 `input:iter()` 打印整表（不受界面只显示当前段限制）。
- 未证实项：`lua_translator` 在更新版本 librime-lua 是否仍无 tag 支持——本仓库 checkout (ad1e4a6) 明确无；其他版本需另查。
