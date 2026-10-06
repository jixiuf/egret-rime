# 会话交接（重启 pi session 先读这份）

> 最后更新：2026-10-01 ｜ 覆盖 2026-09-27 ~ 2026-10-01 那一轮的全部结论。
> 详细过程、原始数据、失败路径见 `docs/PROGRESS.md`（§4.15–§4.47 是本轮全部改动）。
> **读这份 + `AGENTS.md` 即可接手，不必回滚历史对话。**

---

## 0. 一分钟交接

```bash
cd /export/ebook/egret-rime
make test                                  # 黄金 33 条 + 契约测试（必须全过）
make lint                                  # 命名/路径/契约/运行时文件一致性
bash scripts/probe.sh qktnqnr gdrnthtcsu ronghe   # 混流短码 / 整串五笔 / 自动上屏
make eval                                  # 160 句整句评测（并行 6，当前 66/160 = 41%）
bash scripts/refresh.sh --only dict        # 重建词库产物（可复现，秒级）
bash scripts/refresh.sh --loop 30          # 常驻增量刷新（语料在持续增长）
```

## 1. 当前架构（2026-10）

```
engine.translators (dynamic_translator 调度)
  first  table_translator@egret_wubi      传统形码库（简码/全码/词组，quality 1000 置顶）
  then   table_translator@custom_phrase   用户词组
  then   table_translator@wubi_route      ★ tag=wubi 的段（86 库按五笔读法组句）
  then   script_translator@py_route       ★ tag=py 的段
  then   script_translator@translator     混合库（五笔字词 + 拼音音节）
  last   type=completion 补全（沉底）

engine.segmentors
  … abc_segmentor → lua_segmentor@*mix_segmentor ★ → fallback_segmentor
      mix_segmentor：用统一码表搜索器判"整串是哪种读法"，给**整段补 tag**（不切段！）
```

- **引擎 LM = 万象词级 gram**（`wanxiang-lts-zh-hans.gram`，~400MB，原生 octagram 直接读）
- **Lua 侧重排已关**（`dynamic_translator/lm_rerank: false`、`lm_compose: false`）；
  Lua 的 `lm_rerank.{bin,meta}` 只剩**搜索器自己打分**用
- **搜索器** = `lua/py_composer.lua` + `data/gram/compose_table.bin`（27 万条统一码表：五笔+拼音）
- 命名规则：内容同时含五笔与拼音 → `egret_wubi_py_*`；只五笔 → `egret_wubi_*`；只拼音 → `egret_py_*`
- 三个库：`egret_wubi_py`（混流主方案）/ `egret_py`（纯全拼，F4 可切）/ `egret_wubi`（内部辅助 schema）

## 2. 关键数字（改动前后对照）

| 指标 | 值 |
|---|---|
| 黄金用例 | **33/33**（`make test`） |
| 整句(全拼) 160 句 | **66/160 (41%)** ← 万象词级 gram；旧 Lua 字级重排只有 43/160 (27%) |
| 长句三态（8 句，最难的 epub 子集） | 纯拼音 0/8、纯五笔 2/8、混打 0/8（切分器 ON/OFF 对照过） |
| 混流短码 | `qktnqnr→我吃饭`、`qchifanle→我吃饭了`、`uwycuklf→冷部署`、`gdrnthtcsu→天气怎么样` |
| 峰值 RSS | 万象 gram 128MB ／ Lua 字级表 141MB |
| 评测提速 | `eval_gram.py --jobs 6`（每例仍独立 console 进程） |

## 3. ⚠️ 被本会话推翻的旧结论（不要再看旧的）

1. ❌「原生 grammar 接不了班（11%）」→ **是模型问题**（essay/字级），换万象词级 = **41%**
2. ❌「新增候选会让引擎中途提交」→ 误判；filter 里 `Candidate(type,s,e,text,"")` + `yield` **可行**
3. ❌「把输入切成多段实现多读法」→ **结构上错**：rime 里**段=组字/上屏单位**，切段必碎句
4. ❌「`charset_filter` 用来隐藏 CJK 扩展字」→ 它在本构建里一直是 **no-op**（只刷 ERROR）；
   真正管用的是**字表分层**（扩展区字不在默认 prism 里）
5. ❌「20 条黄金用例」→ 现在 **33** 条
6. ❌「权重带宽 451-5000 需要重标」→ 四次重标定全部破黄金；现有权重是**整体手工调好的**

## 4. 组件 / API 硬事实（踩坑换来的，都是源码或实验确认过的）

| 事实 | 出处 |
|---|---|
| `lua_translator` **不支持 tag 配置**（`tag:`/`tags:` 被忽略）→ 必须 `seg:has_tag()` | `lua_gears.h:65` |
| 引擎**不做 tag 路由**：每个段调用**所有** translator，各自自检 | `engine.cc:215` |
| 段：`add_segment(Segment(s,e))`；`tags` 必须 **set 形式**（`{[t]=true}`，数组会报错） | `segmentation.cc:98-107` |
| 等长段 → **tags 取并集**（这是"补 tag"能生效的原因） | 同上 |
| `LuaSegmentor::Proceed` 返回 **true=继续 / false=终止**；出错返回 true | `engine.cc:180-182` |
| segmentor 要排在 `abc_segmentor` 之后、`fallback_segmentor` **之前** | 实测 |
| rime 的 translation 是**单次迭代流**（filter 里遍历两遍 → 候选全丢） | 实测 |
| `cand.text=` 只对 `SimpleCandidate` 生效；`cand.comment=` 对 Phrase 也生效 | librime-lua types.cc |
| `speller/auto_select` 管不了自动上屏 → 必须 `speller/max_code_length: 0` | `speller.cc:134` |
| `db_class: tabledb` **可写**（只读的是 `stabledb`）→ 自学习/调频/造词实测都生效；本项目三个 user_dict 全用 `tabledb`，落点 `<用户目录>/<name>.user.dict.txt` | 实测（2026-10，见 dict-reference.md §7） |
| `rime_deployer` 会把用户目录**根下**它不认识的 `.bin` 移进 `trash/` → 运行时表放 `dicts/` | 实测 |
| 缺 `default.yaml`/`symbols.yaml` → schema config 构建失败 → **LM 静默失效** | `PROGRESS §4.7` |
| 二进制读端极易 off-by-one：**必须配契约测试**（TSV 参考实现逐项比对） | §4.34 / §4.42 |

## 5. 工具清单（本轮新增）

| 工具 | 用途 |
|---|---|
| `scripts/probe.sh <输入…>` | 探针：每个输入**连跑两次取第二次**（冷部署首跑不可信） |
| `scripts/check_consistency.py`（`make lint`） | 命名/路径/契约/语法/**运行时文件是否在部署清单** |
| `scripts/check_lm_table.lua` / `check_compose_table.lua` | 二进制读端**契约测试**（防 off-by-one，抓过 3 个 bug） |
| `scripts/diagnose_failures.py <日志>` | 把评测失败归因成「字缺 / 词缺 / 分段裁决」 |
| `scripts/probe_long_sentences.py [N] [标签]` | 长句三态（纯拼音/纯五笔/混打），支持 A/B |
| `make check` | 重建 dict 阶段 → 黄金 → 混流探针 → 160 句评测（一条命令验全链） |
| `make eval` | 160 句整句评测（等价 `eval_gram.py --sentences 160 --jobs 6`） |

## 6. 待办（按价值排序）

1. **搜索器 beam 打分改用 `M.score`**：现场验证过 —— 句级打分把 `画上小天使们`(-30646) 判得比
   `花上小天师门`(-35748) 高 5102 分 ✓，而搜索器现在的"词一元 + 上下文增益"混合会被词一元压过 ✗。
   这是修**近音错字**（长句残余错误的主类）最直接的一步。
2. **词级 LM 之外的残余近音错误**：模型能力边界（`梅西方` vs `美西方` 之类）。
3. **400MB gram 的交付**：目前不随包分发（用户自行下载）；应在部署/自检里加**存在性校验 + 提示**。
4. **dist/bundle 重打**：现有 `dist/*.tar.gz` 不含本轮全部修复。
5. **目标机复验**：host-linux（Gentoo+fcitx5）/ host-mac（macOS+Squirrel）——本轮改动多，需重新部署并跑自检。
6. **评测集分层/扩样**；按键延迟预算（多读法/搜索器每键都要跑）。

## 7. 环境地图

- 本机（RHEL8，仓库所在）：`third-party/librime` = 1.17.0 + 插件 octagram/lua（**零本地补丁**）
  → `build/bin/{rime_api_console, rime_deployer, build_grammar}`
- 测试用户目录 `data/rime-test`（`make env-test` 生成；会把万象 gram 拷进去）
- 三处部署目标：本机 / `host-linux`（Gentoo + fcitx5）/ `host-mac`（macOS + Squirrel，用 `deploy_host-mac.sh`）
- 语料：`data/input/{ebook,dedao-*,open}` → `data/corpus/{extract,clean,freq}` → `data/gram/`

## 8. 工作纪律（本会话反复吃亏得来的）

1. **看行为下结论前，先读源码/查数据**——本轮我至少 6 次误判都是这么纠正的
   （"引擎中途提交"、"重叠段必坏"、`Proceed` 语义、`charset_filter`、"原生 grammar 不行"、bin 二分）
2. **加测试用例前先跑一遍确认期望值**（我曾凭想象写 `glhihg→画上`，当场打脸）
3. **二进制读端必须配契约测试**（同一个 off-by-one 坑踩过两次）
4. **测量要连跑两次取第二次**（冷部署首跑与热机不同，prism 非确定性）
5. **改文件名/路径类的东西，规整改动会漏**——本轮漏了 7 处拼接点，一定要跑 `make lint`
6. **别用"引擎不行"解释"模型不行"**（§4.44 的教训，代价最大的一次误判）
