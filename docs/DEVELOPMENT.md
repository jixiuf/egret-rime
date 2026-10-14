# 开发文档

这份文档写给改这个仓库的人（和 agent）。用户怎么装怎么用，看根目录的
[README.md](../README.md)。

接手一个会话之前，先读 [HANDOFF.md](HANDOFF.md)：一页纸，写着当前架构、关键数字、
被推翻的旧结论、组件层面的硬事实。改动的来龙去脉在 [PROGRESS.md](PROGRESS.md)，
它是活文档，做完一件事就回写一节。

## 上手

```bash
make setup      # 新机器第一次：拉依赖（锁定 commit）、编译 librime/kenlm、建 venv
make test       # 黄金 42 条 + 4 条结构断言 + 契约测试。改任何东西之后都跑这个
make lint       # 命名、路径、语法、部署清单一致性，秒级，不跑引擎
make verify     # 契约 + 黄金 + 五笔能力 5 组 + 输入延迟门，全链验收
bash scripts/refresh.sh      # 往 data/input 丢语料后，这一条就够：增量重出全部产物
bash scripts/refresh.sh --list   # 看各阶段状态：fetch → extract → clean → freq → dict → gram → artifacts
make verify-repro   # 复现性门：重跑 dict 阶段，产物必须与仓库逐字一致
```

`refresh.sh` 是「语料进、产物出」的唯一入口，可直接反复重跑。实测耗时（135GB 语料、3 并发）：
extract 约 1 分钟（**前提是同步清单能被找到**，见下）、clean 秒级、freq 约 30 分钟（Aho-Corasick
全量重扫，不是增量的）、dict 约 15 分钟（其中四字词挖掘占 10 分钟）、gram 视需要
（它顺带重出搜索器的 `lm_rerank.*`、`compose_table.bin`、`py_words` 等表）。

两个容易踩的点。一是同步清单：`scripts/corpus/common.py` 默认去
`../_sync_state/manifest.jsonl` 找内容寻址 key，找不到就对每个输入文件算 sha256
（135GB 输入要读很久）；本机旧路径是 `_epms_state` 的话，跑之前
`export CORPUS_SYNC_MANIFEST=/export/ebook/_epms_state/manifest.jsonl`，或者把目录改名对齐。
二是 input 目录里的**断链软链**：过去会让 extract 整轮崩掉（已在扫描时跳过并打印条数）。

路径不要写死，`scripts/rime_paths.py` 是唯一入口（以仓库根为基准，可用环境变量覆盖）。
librime 的命令行工具按 `LIBRIME_BIN`、`third-party/librime`、`~/repos/librime` 的
顺序找。

## 引擎里到底挂了什么

三个方案共用一套词库和语言模型，只是组的引擎配置不同：

| 方案 | 什么定位 |
|---|---|
| `egret_wubi_py` | 混流主方案，一句里五笔和拼音混打 |
| `egret_wubi` | 纯五笔，86 结构：简码、全码、词组显式码，另有长尾和四字词 |
| `egret_py` | 纯全拼，同时是 `` `+拼音 `` 反查的词典来源 |

segmentor 链是 `matcher → abc_segmentor → punct_segmentor →
lua_segmentor@*mix_segmentor → fallback_segmentor`。`mix_segmentor` 拿搜索器判
「这串输入算哪种读法」，然后给整段补 tag。注意它是**补 tag 而不是切段**：
rime 里一个段就是一个组字单位，切段会把句子打碎。

translator 的实际顺序是这样的，引擎不做 tag 路由，每个段都会调用所有 translator，
由 translator 自己检查 tag：

```
punct_translator
lua_translator@*date_translator / *lunar / *number_translator / *unicode
reverse_lookup_translator@reverse_lookup          # `+拼音 反查
table_translator@wubi_route    tag=wubi  dict=egret_wubi
script_translator@py_route     tag=py    dict=egret_wubi_py
lua_translator@*dynamic_translator
```

最后那个 `dynamic_translator` 是调度器，它按固定顺序问三个翻译器：
传统五笔库（`egret_wubi`，简码/全码/词组显式码，命中的话置顶）、混合库的
script 翻译器（组句的主力）、混合库 table（用户词组）。补全类候选统一沉底。

filter 链的顺序也是有讲究的：

```
simplifier@emoji → reverse_lookup_filter@wubi_comment → long_word_filter
→ reduce_emoji_filter → simplifier@traditionalize → dump_cands_filter（调试用，默认关）
→ compose_filter → tail_word_filter → uniquifier
```

两条约束别动。`uniquifier` 必须留在最外层，它靠「菜单已经产出的候选表」去重，
挪到中间就失效了。`tail_word_filter` 要重排就得把整份候选缓冲下来，
所以它必须排在 `uniquifier` **前面**，否则去重会静默失效——这个坑在 §4.76 记着。

还有一个兜底：搜索器（`py_composer`）的整句结果会在**混打输入**上进候选表。判据写在
`lua/compose_filter.lua` 的 `want_inject()`：长度 ≥8、含拼音音节、且整串切不成纯拼音
（即「形码片段 + 拼音」并存）。三条都拿真实数据验过：判据放宽到「非纯拼音」时五笔打词
五组全线崩；只放开注入不放开共识重排时 `kkkk` 被搜索器的「咒骂」前移。

语言模型分两块，别混。引擎侧是万象的词级 gram，原生 octagram 直接读；
Lua 侧的重排已经关掉（`lm_rerank: false`）。`py_composer.lua` 加上
`compose_table.bin`、`lm_rerank.{bin,meta}` 属于搜索器，只用来判读法和切分，
不参与候选排名。给它换更好的打分不会提升准确率，§4.49 试过了。

## 词库和产物

词库按权重切三档：core 是 571 以上（约 2 万词），base 是 451 以上（约 6.3 万，默认），
full 收全部权重非零的（约 78 万）。`make tier TIER=...` 换档，`make tiers` 只重生成。

命名看内容：同时有五笔码和拼音码的叫 `egret_wubi_py_*`，只有五笔的叫 `egret_wubi_*`，
只有拼音的叫 `egret_py_*`。

入 git 的东西有两类。一类是源数据：字表层、五笔词源、外部词源（`wb86_wangxiang_cn_dicts/`、
`wubi86/`）、用户短语。另一类是运行时文件（`lm_rerank.{bin,meta}`、`compose_table.bin`、
`py_meta.txt`），这样目标机 `git pull` 完就能用，不用再跑语料管线（§4.74）。

生成器都在 `scripts/gen_*.py`，由 `refresh.sh` 的 dict 阶段按顺序调用：

| 脚本 | 产物 |
|---|---|
| `gen_wubi_py_unified_dicts.py` | 混合库字表（五笔码 + 拼音音节）、传统库字表和词表 |
| `gen_dict_tiers.py` | 三档词表（86 码、万象逗号码、拼音码） |
| `gen_wubi_86_longtail.py`、`gen_wubi_86_mined_4char.py` | 五笔长尾二字词、从语料挖的四字词 |
| `gen_sentence_dict.py` | 高频整句 → 五笔短码序列 |
| `gen_lm_rerank.py` | 搜索器打分表，定长二进制，配契约测试 |
| `gen_compose_table.py`、`gen_py_tables.py` | 统一码表、拼音表和元数据 |
| `gen_char_weights.py`、`gen_char_layers.py` | 字表权重校准与分层 |
| `keyname_priority.py` | 被上面几个词表生成器 import，保证键名字压过同码词 |

权重有两个来源：字表是语料词频 log 归一化到 0~1000，词是万象的原值，两者已经是同一尺度。
不要做整体重标定，试过四次，每次都破黄金（§4.17、§4.38）。

## 部署是怎么设计的

一条链，一个引擎，一份清单：

```
make deploy   → scripts/deploy_runtime.sh <仓库> <目标目录> --link
make reload   → scripts/reload_ime.sh（rime_deployer --build + 重启 fcitx5/Squirrel）
make bundle   → scripts/deploy_bundle.sh 打 dist/*.tar.gz，包内 install.sh 是薄壳，
                目标机执行 install.sh <目录> [--link] [--download-lm]
```

清单只在一个地方定义：`bash scripts/deploy_bundle.sh --list`，打包时会落成包内的
`runtime_manifest.txt`。`make deploy`、离线包的 `install.sh`、`reload_ime.sh` 里
回补 trash 的逻辑、以及 `make lint` 的检查，全都从它派生（§4.79）。

引擎除了拷/链文件，还要管几件容易做错的事：`user.yaml`、`default.custom.yaml`、
`installation.yaml` 这些用户态和机器态文件不覆盖；首次安装把
`previously_selected_schema` 指到本方案；语言模型缺失时提示或下载；拷贝模式下先备份到
`.egret-backup-<时间戳>/`；装完按清单自检一遍。

`default.custom.yaml` 是给用户看的，里面 `schema_list/+:` 是追加写法，不删用户已有的
方案列表。代价是 librime 的 console 和部署器只看列表里第一个可用方案，
所以默认方案靠安装时写 `user.yaml` 解决；测试环境则用
`scripts/schema_env.py list-replace <目录>` 把**那个目录里**的那份改成替换写法（§4.78）。

## 测试和门禁

| 命令 | 管什么 |
|---|---|
| `make test` | `env-test` + `lint` + 黄金 42 条 + 4 条结构断言，用例表在 `scripts/regression_test.py` 的 `CASES` |
| `make lint` | 命名、路径、语法、运行时文件是否入 git 且在清单里、`schema_list` 语义、键名字优先 |
| `make verify` | 契约 + 黄金 + 五笔能力 + 延迟门，一条命令过全链 |
| `make verify-wubi` | 五笔打词的五个 cohort，各带 top1/top8 阈值 |
| `make bench` | 三串固定输入整串重放，超基线 1.5 倍算失败 |
| `make verify-bundle` | 先重打包，再解包装到空目录跑 8 条探针 |
| `make verify-repro` | 重跑 dict 阶段后 `git diff --exit-code`：产物必须与仓库一致（防「改了生成器没重出产物」） |
| `make eval` | 160 句整句评测，另有 200 句留出集 |

二进制读端有两个专门的契约测试（`check_lm_table.lua`、`check_compose_table.lua`），
用 TSV 参考实现逐键比对二进制包，抓过三次 off-by-one。

测量上有个规矩：新用例先手动跑一遍确认期望值再写进表；冷部署后的第一跑不算数
（`scripts/probe.sh` 会连跑两次取第二次）；长输入区分「超时」和「真错」（§4.52）。

## 目标机（尤其 macOS）的几个坑

`make reload` 末尾会跑一段自检，先看它：librime 版本、仓库 HEAD 与未提交改动数、
生效的 `grammar/language`、gram 的 sha256、关键运行时文件是否齐全。这四项覆盖了绝大多数
「部署了却没变」。

macOS 自带 bash 3.2，所以脚本里不能出现 `declare -A`、`mapfile`、`readarray`，也不能让
`$VAR` 紧跟着全角标点或汉字（bash 3.2 不把它当分隔符，会把标点字节并进变量名）。这两类
都会让 `make deploy` **报错中断**，文件一个都不落地 —— 表现就是「部署成功但行为没变」。
lint 里有守卫，别绕过。

共享数据要**全量**软链（`env-test` 现在会链共享目录下所有 `*.yaml` + `essay.txt`）：librime 1.17
的 `default.yaml` 还引用 `punctuation.yaml`、`key_bindings.yaml` 等，少一个就是 deploy failure、
console 出 `.default` 且没有候选。macOS 上这些文件在 Squirrel.app 的 SharedSupport 里。

语言模型（万象 gram）**不钉版本、始终跟上游最新**，而上游会替换 release 资产 ⇒ 各机器可能拿到
不同版本，同一输入的长句结果就不同。跨机对比结论前先对 `make reload` 自检里的 sha256。
`make gram-lm FORCE=1` 可强制取最新。

用户词典的学习数据会改变裁决（正常行为）。排查「两台机结果不同」时，先把 `*.user.dict.txt`
移到一边再比一次 —— 本仓库就遇到过 4436 条学习数据把「我们希望」推成「欠交态」。

## 文档地图

| 文档 | 看它想了解什么 |
|---|---|
| [HANDOFF.md](HANDOFF.md) | 会话交接：当前架构、关键数字、被推翻的结论、组件硬事实、工具清单 |
| [PROGRESS.md](PROGRESS.md) | 按 §4.x 记的决策、实验、踩坑，改动都回写这里 |
| [README.md](README.md)（docs 索引） | Rime 知识库总索引：引擎、词库、gram、lua、调试 |
| [corpus-pipeline.md](corpus-pipeline.md) | 语料管线 A~E 各阶段的设计与限流 |
| [design-weights-jianma-grammar.md](design-weights-jianma-grammar.md) | 权重、简码、成语、简拼这些取舍的实测数据 |
| [deployment-debugging.md](deployment-debugging.md) | 平台路径表、排障决策树、命令行工具用法 |
| [lm-grammar.md](lm-grammar.md)、[dict-reference.md](dict-reference.md) | gram/octagram 与 .dict.yaml 的格式、编译、造词 |
| [../AGENTS.md](../AGENTS.md) | agent 的工作入口：硬契约和已知陷阱 |

## 几条约定

改 schema、词库或生成脚本，至少跑 `make test`；动词库再加 `make verify-wubi`；
动性能相关加 `make bench`；动交付相关加 `make verify-bundle`。

做完一件事就回写 `PROGRESS.md`（新开一节 §4.x），一页纸摘要同步到 `HANDOFF.md`。

新增运行时文件要加进 `deploy_bundle.sh` 的清单，lint 会检查运行时文件是否入 git、
以及在不在清单里。

别为了测试方便去改用户配置（`default.custom.yaml`），测试改测试环境就行。

上游依赖 pin 在 `scripts/setup_env.sh` 里，三通道交叉校验过。这个项目不需要给
librime 打补丁。
