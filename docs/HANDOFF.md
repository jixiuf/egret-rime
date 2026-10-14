# 会话交接（重启 pi session 先读这份）

> 最后更新：2026-10-01 ｜ 覆盖 2026-09-27 ~ 2026-10-01 那一轮的全部结论。
> 详细过程、原始数据、失败路径见 `docs/PROGRESS.md`（§4.15–§4.47 是本轮全部改动）。
> **读这份 + `AGENTS.md` 即可接手，不必回滚历史对话。**

---

## 0. 一分钟交接

```bash
cd /export/ebook/egret-rime
make test                                  # 黄金 43 条 + 4 条结构断言 + 契约测试（必须全过）
make lint                                  # 命名/路径/契约/运行时文件一致性
bash scripts/probe.sh qktnqnr gdrnthtcsu ronghe   # 混流短码 / 整串五笔 / 自动上屏
make eval                                  # 160 句整句评测（并行 6，当前 74/160 = 46%）
make deploy && make reload                 # 目标机部署（先 git pull --ff-only，§4.77）
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

- ⚠ **搜索器只影响 tag、不进候选排名**（`compose_filter`/`dynamic_translator` 两侧都关）：
  所以「给它换个更好的打分」不可能修长句准确率（§4.49 已证否 H1）。

- **引擎 LM = 万象词级 gram**（`wanxiang-lts-zh-hans.gram`，~400MB，原生 octagram 直接读）
- **Lua 侧重排已关**（`dynamic_translator/lm_rerank: false`、`lm_compose: false`）；
  Lua 的 `lm_rerank.{bin,meta}` 只剩**搜索器自己打分**用
- **搜索器** = `lua/py_composer.lua` + `data/gram/compose_table.bin`（27 万条统一码表：五笔+拼音）；
  beam 状态**按输入前缀增量缓存**（§4.50）：每键 O(1 个位置)，判定不变（52 字母单例 60s→11.9s）
- 命名规则：内容同时含五笔与拼音 → `egret_wubi_py_*`；只五笔 → `egret_wubi_*`；只拼音 → `egret_py_*`
- **长句页尾留「字 + 词」（先字修正）**：`lua/tail_word_filter.lua`（§4.76）——首候选是
  ≥4 字整句时，**每页倒数第 2 位放一个字、最后 1 位放一个词**（字优先取**首句的第一个字**，
  如 jintiandetianqize… → 今；词取最高权前缀词，如 今天）。两者选中都只上屏前缀、余下输入
  继续组句 ⇒ 长句首字/首词不合意时先修正开头，不必退格重打。短码/全码/词组路径一行不动。
- **键名字优先**：`scripts/keyname_priority.py`（§4.76）——25 个键名字四连击码
  （口 kkkk / 禾 tttt / 大 dddd …）把**同码词压到其下**，保字第 1（口 544 > 串串 543），
  不改正字表权重；`make lint` 有契约守卫（任一词表漏接生成器即报错）。
- 三个库/方案（F4 可切，`default.custom.yaml` 的 schema_list 三者都在）：
  `egret_wubi_py`（混流主方案）/ `egret_wubi`（**纯五笔**，86 造词码 + 长尾 + 四字词，§4.71）/
  `egret_py`（**纯全拼**，也是 `+拼音 反查的词典来源）

## 2. 关键数字（改动前后对照）

| 指标 | 值 |
|---|---|
| 黄金用例 | **42/42**（38 用例 + 4 结构断言，`make test`） |
| 整句(全拼) 160 句 | **73/160 (46%)**（2026-10-14 实测） ← 万象词级 gram + 长尾拼音词 + 词组感知注音（§4.55/§4.56）|
| 整句(全拼) 200 句（另一套，留出集） | **84/200 (42%)**（本轮起点 69/200）|
| 长尾拼音词接入前 | 66/160 (41%)；旧 Lua 字级重排只有 43/160 (27%)|
| 长句三态（8 句，最难的 epub 子集） | 纯拼音 0/8、纯五笔 2/8、混打 0/8（切分器 ON/OFF 对照过） |
| **五笔打词（H11）** | 二字 base **100%** ｜ 二字长尾 top8 **94%**（接长尾前 7%）｜ 三字 base top1 94%/top8 100% ｜ 三字长尾 top8 98%（之前词不存在）｜ **四字（语料挖掘）top1 86% / top8 100%**（之前 0%）|
| 混流短码 | `qktnqnr→我吃饭`、`qchifanle→我吃饭了`、`uwycuklf→冷部署`、`gdrnthtcsu→天气怎么样` |
| 峰值 RSS | 万象 gram 128MB ／ Lua 字级表 141MB |
| 评测可复现性 | §4.52 后**逐句 160/160 一致**（此前 ±2 句波动全来自 GC 活锁超时假失败）|
| 评测提速 | `eval_gram.py --jobs 6`（每例仍独立 console 进程） |

> 本轮改动的**价值账**（同机 A/B、留出验证、代价、被否方案、复现命令）：见 `docs/PROGRESS.md §4.66`。

## 3. ⚠️ 被本会话推翻的旧结论（不要再看旧的）

1. ❌「原生 grammar 接不了班（11%）」→ **是模型问题**（essay/字级），换万象词级 = **41%**
2. ❌「新增候选会让引擎中途提交」→ 误判；filter 里 `Candidate(type,s,e,text,"")` + `yield` **可行**
3. ❌「把输入切成多段实现多读法」→ **结构上错**：rime 里**段=组字/上屏单位**，切段必碎句
4. ❌「`charset_filter` 用来隐藏 CJK 扩展字」→ 它在本构建里一直是 **no-op**（只刷 ERROR）；
   真正管用的是**字表分层**（扩展区字不在默认 prism 里）
5. ❌「20 条黄金用例」→ 现在 **43 条 + 4 条结构断言**
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
| translator **不写 `user_dict`** → 按 `dictionary` 名派生 `<dictionary>.userdb`，且 `enable_user_dict` 默认 true → **加载方案时就把目录建出来**（与 tag 无关） | `user_dictionary.cc:588-612` |
| `rime_deployer` 会把用户目录**根下**它不认识的 `.bin` 移进 `trash/` → 运行时表放 `dicts/` | 实测 |
| 缺 `default.yaml`/`symbols.yaml` → schema config 构建失败 → **LM 静默失效** | `PROGRESS §4.7` |
| 二进制读端极易 off-by-one：**必须配契约测试**（TSV 参考实现逐项比对） | §4.34 / §4.42 |
| macOS 自带 **bash 3.2**：脚本里 `declare -A`/`mapfile`/`$VAR`紧跟全角标点都会让 `make deploy` **静默中断** | §4.84 |
| 共享数据要**全量**软链（1.17 的 default.yaml 还引用 punctuation 等），只链三个会让目标机 deploy failure | §4.84 |
| 万象 gram 不钉版本、跟上游最新 ⇒ 各机可能不同；跨机比结论前先对 `make reload` 自检里的 sha256 | §4.84 |

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
| `make verify-wubi` | **五笔能力验收**（H11 五组 + 阈值，~1 分钟；改词库后必跑） |
| `make bench` | **输入延迟门**（三串固定输入；超基线 1.5× 失败）|
| `make verify-bundle` | **交付包验收**（解包→装到空目录→部署→8 条探针）|

## 6. 待办（按价值排序）

1. ~~搜索器 beam 打分改用 `M.score`~~ — **❌ 已证否（§4.49）**：搜索器不在决策路径上，改打分＝0 收益＋每键 ×3。
   同类工作已改为「不改判定、只降成本」：**增量缓存已落地（§4.50）**。
2. **词级 LM 之外的残余近音错误**：模型能力边界（`梅西方` vs `美西方` 之类）。
3. ~~400MB gram 的交付存在性校验~~ — **✅ 已做**：包内 `install.sh` 自检必需文件 + gram（§4.57）。
4. ~~dist/bundle 重打~~ — **✅ 2026-10-09**：`dist/egret-rime-runtime-20261009.tar.gz`（29M，61 文件）。
5. **目标机复验**：macOS（host-mac）**✅ 9/9 自检通过**；**host-linux 离线待验**
   （其部署脚本已同步修好"自检不固定方案/只测拼音"的同源风险）。
6. ~~拆掉 librime-lua 关闭期 GC 活锁~~ — **✅ 已合并并落地（§4.73）**：pin→`6da5d6c`，桶记忆化已进 `lua/py_composer.lua`，延迟 -35%。原文：**已定位根因 + 提上游 PR #435**
   （`lua_gears.cc` 每 256 次析构做一次全量 GC，在 `lua_close` 期间重入 → 活锁）。
   本地已打补丁并重建（32 字母用例 挂死→3.35s）。剩下：合并后 bump pin（或 setup 加本地 patch），
   再把前缀桶记忆化落地（已验证 52 字母 11.9→7.8s，存档 `docs/experiments/h7-bucket-memo-pending-pin-bump.patch`）。
7. **评测集分层/扩样**；评测口径先把「超时」与「真错」分开（长输入 120s 超时会把延迟记成品错误；
   也存在 **exit 挂死被记成 None** 的情况——同上 PR 修后可消）。

## 7. 环境地图

- 本机（RHEL8，仓库所在）：`third-party/librime` = 1.17.0 + 插件 octagram/lua（**零本地补丁**）
  → `build/bin/{rime_api_console, rime_deployer, build_grammar}`
- 测试用户目录 `data/rime-test`（`make env-test` 生成；会把万象 gram 拷进去）
- 部署（唯一流程，§4.77/§4.79）：目标机 `git pull --ff-only` → `make deploy` → `make reload`
  （`reload` = `rime_deployer --build` + 重启 fcitx5/Squirrel）。旧的
  `deploy_{host-linux,host-linux_direct,host-mac,remote}.sh` 已删除；离线机器走 `make bundle` + `install.sh`
- 语料：`data/input/*`（自有 epub / 听书 + 课程文稿 / 开源）→ `data/corpus/{extract,clean,freq}` → `data/gram/`

## 8. 工作纪律（本会话反复吃亏得来的）

1. **看行为下结论前，先读源码/查数据**——本轮我至少 6 次误判都是这么纠正的
   （"引擎中途提交"、"重叠段必坏"、`Proceed` 语义、`charset_filter`、"原生 grammar 不行"、bin 二分）
2. **加测试用例前先跑一遍确认期望值**（我曾凭想象写 `glhihg→画上`，当场打脸）
3. **二进制读端必须配契约测试**（同一个 off-by-one 坑踩过两次）
4. **测量要连跑两次取第二次**（冷部署首跑与热机不同，prism 非确定性）
5. **改文件名/路径类的东西，规整改动会漏**——本轮漏了 7 处拼接点，一定要跑 `make lint`
6. **别用"引擎不行"解释"模型不行"**（§4.44 的教训，代价最大的一次误判）
