# Rime 方案支持的组件（含 Lua 扩展点）

> 来源：librime `src/rime/gear/gears_module.cc`（权威注册表）+
> librime-lua `src/modules.cc`。2026-09-30 核对。
> 用途：写方案时该用哪个组件、能不能用 Lua 自己写。

## 1. 引擎流水线（一次按键的处理顺序）

```
按键
 ├─ processors    逐个过，谁先返回 kAccepted 就停（负责"接管按键"：进输入串、翻页、切模式…）
 ├─ segmentors    把输入串切成若干段落，给每段打 tag（abc / punct / reverse_lookup …）
 ├─ translators   按 tag 选出该段的翻译器，产出候选
 └─ filters       对候选表做整形（排序、去重、注释、简繁、隐藏…）
        └─ formatters  只影响显示（preedit / comment 的呈现）
```

配置位置（schema）：

```yaml
engine:
  processors: [...]
  segmentors: [...]
  translators: [...]
  filters: [...]
```

组件引用有三种写法：
- `组件名`（用默认命名空间，如 `speller`）
- `组件名@自己的块名`（如 `table_translator@custom_phrase` → 该组件读 `custom_phrase/xxx` 的配置）
- `lua_组件类型@*模块名`（如 `lua_filter@*long_word_filter` → 加载 `lua/long_word_filter.lua`）

**@ 后面的块名 = 组件的 namespace**，组件所有配置项都从 `<namespace>/xxx` 读；
Lua 组件也一样（`env.engine.schema.config:get_bool("块名/键")`）。
这就是为什么"filter 自己的 ns 读不到 dynamic_translator 的开关"——写错了块名。

## 2. 七类组件与内置实现

### processors（接管按键）
| 名 | 作用 |
|---|---|
| `ascii_composer` | 中西文切换（Shift / CapsLock） |
| `chord_composer` | 组合键并发（如 c+h 同时按下） |
| `express_editor` / `fluid_editor`(别名 `fluency_editor`) | 编辑器：空格/回车上屏、退格、以词定字光标 |
| `key_binder` | 改键（把 `,`/`.` 改成翻页等），`import_preset: default` 引入系统预设 |
| `navigator` | 移动输入串内光标 |
| `punctuator` | 标点直接上屏（`import_preset: symbols` 引入 symbols.yaml） |
| `recognizer` | 识别特殊段落并打 tag（反查、`/` 符号、`R` 数字…），配合 `matcher` |
| `selector` | 数字选字键、翻页键 |
| `speller` | **把字母键加进输入串**；也是自动上屏/最大码长策略的所在地 |
| `shape_processor` | 字形/结构输入（未使用） |

### segmentors（切段 + 打 tag）
| 名 | 作用 |
|---|---|
| `abc_segmentor` | 常规字母段（tag `abc`），可加 `extra_tags` |
| `affix_segmentor` | 前后缀段（反查 `\`xxx'` 那类） |
| `ascii_segmentor` | 西文段（直接上屏） |
| `punct_segmentor` | 标点段 |
| `fallback_segmentor` | 兜底，保证任何输入都有段 |
| `matcher` | 按 recognizer 的 patterns 匹配并打 tag |

### translators（按 tag 产候选）
| 名 | 作用 |
|---|---|
| `table_translator` | 码表翻译器（我们传统五笔库用它）：精确码、简码、词组、可造词 |
| `script_translator`(别名 `r10n_translator`) | 拼音/音节翻译器（我们混合库用它）：在 prism 上组句，接 grammar/LM |
| `reverse_lookup_translator` | 反查（`\`+拼音`、`u`+笔画） |
| `punct_translator` | 标点候选 |
| `echo_translator` | 把原始输入当成候选显示 |
| `switch_translator` | 显示开关名（如 `简繁`） |
| `history_translator` | 重复上次上屏的内容（我们没用） |
| `schema_list_translator` | 候选里列出其它方案 |

### filters（候选表整形）
| 名 | 作用 |
|---|---|
| `simplifier` | **配置驱动的多功能滤镜**：opencc 简繁、emoji、火星文等（我们用它做简繁与 emoji） |
| `uniquifier` | 去重 |
| `charset_filter`(别名 `cjk_minifier`) | 隐藏扩展区/生僻字（我们用它默认隐藏 CJK 扩展） |
| `single_char_filter` | 只留单字 |
| `reverse_lookup_filter` | **给候选加注释**（反查另一套编码，我们的五笔码提示就是它） |
| `corrector` | 错音/错字提醒 |

### formatters（显示）
| 名 | 作用 |
|---|---|
| `shape_formatter` | 显示时做变换（preedit/comment 呈现） |

### 其它（非 engine 列表，按块配置）
`translator_commons` 的公共项（`enable_completion` / `enable_sentence` / `max_sentences` /
`max_homophones` / `initial_quality` / `spelling_hints` / `dictionary_exclude`…）对
table/script 两种 translator 都生效（注意：**不是每个键两种都读**，
例：`max_homographs` 只有 table 读，见 §4.18）。

## 3. Lua 扩展点（只有这 4 个）

librime-lua 注册的组件（`src/modules.cc`）：

```
lua_processor   lua_segmentor   lua_translator   lua_filter
```

**没有 `lua_formatter`、没有 `lua_editor`** ✗ —— 显示变换与编辑器语义改不了。

Lua 模块约定（`src/lua_gears.cc` 取 `init` / `func` / `fini` 三个字段）：

```lua
local M = {}
function M.init(env) end          -- 组件创建时一次：读配置、加载数据
function M.func(input, env) end   -- 每次交互调用
function M.fini(env) end          -- 销毁
return M
```

各类型的 `input` / 用法：

| 类型 | 配置写法 | `func` 收到什么 | 怎么做 |
|---|---|---|---|
| `lua_processor` | `lua_processor@*M` | `(key_event, env)` | 处理按键，返回 `kAccepted`/`kNoop`/`kRejected` |
| `lua_segmentor` | `lua_segmentor@*M` | `(input_string, start, end, env)` | 返回多个 `Segment`（自己决定怎么切段、打什么 tag） |
| `lua_translator` | `lua_translator@*M` | `(input, seg, env)` | `yield(Candidate(...))` 产候选 |
| `lua_filter` | `lua_filter@*M` | `(translation, env)` | `for cand in input:iter() do ... yield(cand) end` |

Lua 里可直接用的东西（由 librime-lua 注入为全局）：`Candidate`、`Phrase`、`Segment`、
`ShadowCandidate`、`Config`、`Schema`、`Translation`、`Memory`、`reverse_lookup`、
`kAccepted/kNoop/kRejected`、`log`、`rime_api`。

## 4. 本轮踩过的与组件相关的坑（都实测过）

1. **`speller/auto_select` ≠ 取消自动上屏**：`speller.cc:134` 的
   `AutoSelectAtMaxCodeLength` **只检查 `max_code_length`，不看 `auto_select`** →
   混流/全拼必须把 `speller/max_code_length` 设 0（我们已是，§4.32）。
2. **改候选文本**：`cand.text = ...` 只对 `SimpleCandidate` 生效，
   对 Sentence/Phrase **静默无效** → 要改就新造候选（见下条）。
3. **新造候选是可行的**：`Candidate("sentence", start, end, text, comment)` 返回
   `SimpleCandidate`，在 **filter 里** yield **不会**导致"输入中途提交"
   （§4.15 那结论是误判，§4.40 已纠正）。
4. **deployer 会清理"schema 不引用、运行时才读"的文件**：放到用户目录根下的 `.bin`
   每次 `rime_deployer --build`（fcitx 重启也会跑）都会被移进 `trash/` →
   LM 表要放 `dicts/`（§4.34）。
5. **config 构建失败 = LM 静默失效**：`default.yaml`/`symbols.yaml` 缺失时
   schema config 构建失败，grammar 整体不生效（§4.7、§4.34）。

## 5. 对我们方案的组件清单

| 位置 | 我们用的 |
|---|---|
| processors | `select_character`(lua)、`ascii_composer`、`recognizer`、`key_binder`、`speller`、`punctuator`、`selector`、`navigator`、`express_editor` |
| segmentors | `matcher`、`abc_segmentor`、`punct_segmentor`、`fallback_segmentor` |
| translators | `punct_translator`、`lua_translator@*date/lunar/number/unicode`、`reverse_lookup_translator@reverse_lookup`、**`lua_translator@*dynamic_translator`**（顶层调度：传统库 table + 混合库 script） |
| filters | `simplifier@emoji`、`lua_filter@*long_word_filter`、`lua_filter@*reduce_emoji_filter`、`charset_filter`、`simplifier@traditionalize`、`uniquifier`、`reverse_lookup_filter@wubi_comment`、`lua_filter@*compose_filter` |

## 6. 还没用、但值得考虑的扩展点

1. **`lua_segmentor`（我们完全没用）** ★ —— 已把机制与配方摸清（子代理带 file:line 验证，
   纠正了我先前两条错记）：

   **① 引擎不做 tag 路由**：对每个 segment **无脑调用所有 translator** 的 Query
   （`engine.cc:215`），是否处理由 translator **自己**看 `segment.HasTag()` 决定。
   内建 table/script 用 `HasAnyTagIn(tags_)` 自检，`tags_` 来自 `<ns>/tag`（覆盖首个）
   + `<ns>/tags`（追加），默认 `{"abc"}`（`translator_commons.cc:115-153`）。

   **② `lua_translator` 完全不支持 tag** ✗（`lua_gears.h:65` 无 TagMatching）——
   块里写 `tag:`/`tags:` 会被**静默忽略**（这就是我原型里探针候选不出现的原因）。
   必须在 lua 的 `func` 里自己 `seg:has_tag("xxx")` 自检。

   **③ `LuaSegmentor::Proceed` 的返回值语义**：**true = 继续**调用后面的 segmentor，
   **false = 终止本轮链**（`engine.cc:180-182` 的 `if (!Proceed) break`）。
   出错时返回 true（`lua_gears.cc:211`），即"继续" —— **不是**我先前记的"接管跳过" ✗。

   **④ 给段打自定义 tag 的正解**：`add_segment` 一个**与当前段等长**的 Segment，
   并把它的 `tags` 设成 **set 形式**：
   ```lua
   local ns = Segment(j, k)
   ns.tags = { [tag] = true }     -- 必须 set；写成数组 {tag} 会 lua 报错
   seg:add_segment(ns)            -- 与 abc 段等长 → tags 取并集 {abc, tag}
   return true                    -- 继续后面的 segmentor
   ```
   `add_segment` 的不变量（`segmentation.cc:84-108`）：start 必须等于当前 start（否则丢弃）；
   更长→覆盖（丢原 tags）；**等长→tags 并集**；更短→忽略。
   （我先前"加段会破坏分段不变量导致零候选"的结论是错的 ✗ —— 真因是 `tags` 用错了形式 ✗。）

   **⑤ 把一段切成多段**：`pop_back()` → `add_segment(s1)` → `forward()` →
   `add_segment(s2)` …（首尾相接、不重叠），各段自动被对应 tag 的 translator 处理。
   这正是混流"多读法"的实现方式：按「五笔码段 / 拼音段」切，分别挂对应的 translator。

   **⑥ 调试方法**：用 `lua_filter` 遍历 `input:iter()` 打印**整份候选表** ——
   界面只显示当前段的候选，filter 不受此限（我先前就是被这点卡住的 ✗）。

2. **`affix_segmentor` + `reverse_lookup_translator`**：可以给反查加更丰富的语义。
3. **`history_translator`**：重复上次上屏内容（英文输入习惯），成本极低。
4. **`single_char_filter`**：某些场景只想要单字时可用。
5. **`simplifier` 的多实例**：它靠配置驱动（opencc/emoji/…），可以再挂一个做别的转换。
6. **`corrector`**：错音/错字提醒（拼音用户的模糊音痛点），需要配好它的块再试
   —— 之前接 `super_comment`（内含 corrector 逻辑）直接崩，要用得单独配。
