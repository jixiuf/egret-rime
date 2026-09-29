# 项目进度与交接（活文档）

> **用途**：pi session 会变得很大或过期。任何新 session（或换人）读这一份即可无缝接手，
> 不必回滚历史对话。
>
> **维护约定**：每完成一个里程碑、每启动/结束一个后台任务、每产生一个决策，
> **立即更新本文**（至少更新 §1 当前状态、§3 后台任务、§5 待办）。
>
> 最后更新：2026-09-27 01:00 ｜ 更新者：pi（egret-rime session）

---

## 1. 当前状态（一句话）

**一条命令出产物 + 可复现**已成立：`bash scripts/refresh.sh`（参数固化在脚本顶部，
实测 `--from dict` 前后产物 md5 完全一致）；环境自包含（`make test` 20/20）；
语料 135G（clean）；词典三档（五笔+拼音同步）；**LM 只重排不参与分词（纯 Lua）**，
在多来源整句评测上把完全命中从 **13%（原配置）提到 26%**、字符准确率 53.4%→59.0%。
**混流已修复（§4.19）**：简码拼写不在组句空间里是总根源，补 641 条简码进混合库后
`qchifanle→我吃饭了`、`qktnqnr→我吃饭` 全通，且黄金 20/20、评测 26% 零回归。
此前建的统一码表搜索器（§4.15，独立验证全对）仍**送不进引擎**（四条路被封）；
已用「整句词库」（§4.16，6 万条）走数据路线交付高频句；权重不可轻改（§4.17，四次失败）。

**产品目标**：**通用**输入法 → 词典尽量全、可选小词典（core/base/full）、可选简体或繁体；
**五笔与拼音同步覆盖**；**一个脚本跑所有**且**所有改动可由 refresh.sh 复现**。


## 2. 新 session 接手步骤

```bash
cd /export/ebook/egret-rime
sed -n '1,80p' AGENTS.md            # 目录与路径约定（必读）
sed -n '1,60p' docs/PROGRESS.md     # 本文
make corpus-status                  # 语料账本（抽取阶段）
bash scripts/setup_env.sh check     # 环境自检
ps aux | grep -E "[c]url|[c]argo|[c]lean"   # §3 后台任务是否还在跑
make test                           # 黄金用例（20 条），确认引擎仍正常
```

后台任务日志都在 `data/corpus/log/`。

## 3. 后台任务（可另开终端接管）

| 任务 | 启动方式 | 日志 | 结果落点 |
|---|---|---|---|
| gram 全量训练 | `MINCOUNTS=50:30:15:8:4 bash scripts/corpus/gram.sh` | `log/gram.log` | `data/gram/zh-hans-egret.gram` |

> 一键刷新可代替逐个阶段：`bash scripts/refresh.sh`（增量，可反复重跑）。
> 下载器写 `.part` 再改名——**抽取器只见完整文件**，避免半成品污染增量索引。
> 注意：**清洗/词频/gram 必须用 `third-party/venv/bin/python`**（系统 python 无 C++ OpenCC / jieba）。

## 4. 已完成（均带验证）

### 4.1 环境自包含（RHEL8/Rocky8）
- 7 个第三方仓库 pin commit，**三通道交叉校验**（直连 GitHub API / socks 代理 /
  gh-proxy 三方 SHA 一致）后落 `third-party/`；`make setup` 一键重建。
- 构建链：glog 0.6.0（自建）→ librime 1.17.0 + plugins {octagram, lua} → kenlm
  → Rust 工具（1.98.1，装在 `third-party/rust/`）。
- 工具链：gcc-toolset-12、boost1.78（EPEL）、Rust 1.98.1。
- **验证**：`make test` → 20/20。

### 4.2 阶段 A 语料抽取（验收完成）
- 单一入口 `extract.py` + 按文件类型自动分派 `formats.py`
  （epub / markdown / html / 纯文本 / jsonl，gzip 感知，全部流式）。
- 增量：key 取 同步清单 `oss_key`（内容寻址 md5，免读几十 GB）或 sha256；
  索引 append-only；产物丢失自动重抽。限流 `nice 15 + ioprio BE/7`。
- **实测**：epub 4,287 本（10.7 亿汉字）+ 文稿 56,157 篇（1.8 亿汉字）
  = 60,458 篇 / 12.5 亿汉字 / 4.1 GB；epub 1.4 min、文稿 14 s。

### 4.3 阶段 B 清洗（全量完成）
- `clean.py`：样板行剔除 / 中文占比过滤 / 繁简可选 / 白名单可选 / 断句 /
  全局去重。输出 `clean/para/<格式>.txt`（整段）与 `clean/short/<格式>.txt`（纯汉字短句）。
- 并行架构：worker 写分片（本地去重）→ merge 层全局去重；分片 append-only 可增量。
- **实测**：para 4.6G/1517 万行，short 3.2G/3803 万行（共 6.8G，含 3 套台账）。

### 4.4 阶段 freq 词频（实现完成）
- `freq.py`：jieba 分词（HMM=False 确定性）+ 纯汉字词过滤（长 1~8）+
  按来源计数 + 合并 + log-norm 权重；指纹驱动增量（未变的来源跳过）。
- 产物：`freq/by_source/<格式>.tsv`、`freq/word_freq.tsv`（word/count/weight/sources）。

### 4.5 词典分档（已实现并验证）
- `gen_dict_tiers.py`：同源按权重切 core(≥571)/base(≥451)/full(>0)，
  **五笔码（万象码+86 造词码）与拼音码同步分层**。
- `set_tier.py`：改写两个包装 dict 的 import_tables（自动归一历史直引）。
- `make tier TIER=core|base|full` 一条命令切档。
- **验证：三档均 20/20 黄金用例通过**；体积 core 1.2M / base 3.7M / full 26M。
- 字表与拼音字表**不随档位变**（字是基础，简码属肌肉记忆层）。

### 4.6 一键刷新 + gram 管线
- `scripts/refresh.sh`：阶段 fetch/extract/clean/freq/dict/gram/verify，
  支持 `--from/--only/--full/--list`，全部增量可重跑。
- `scripts/corpus/gram.sh`：clean/short → 字符 2-6gram 计数 → build_grammar →
  `data/gram/<language>.gram`；指纹驱动、支持 `--sample` 冒烟与 `--restart`。

### 4.7 环境严重 bug 修复：LM 之前一直没生效（❗）
**现象**：切换 `grammar/language` 到不存在的名字，结果与真 gram **完全一致**。
**根因**：librime 运行时 `user_data_dir` 与 `shared_data_dir` 默认都是 `.`，
而 `make env-test` 把 `default.yaml/symbols.yaml/essay.txt` 放在了 `data/rime-shared/`，
用户目录里没有 → `default:key_binder` 解析失败 →
`error building config: egret_wubi_py.schema` → **grammar 段整体未加载**。
**修复**：env-test 同时把这 3 个文件链进用户目录（`data/rime-test/`）。
**验证**：`ckwan` 无 gram→台万、essay-bgc/自训→台湾；无 key_binder 报错。
**影响**：此前所有回归都是"无 LM"跑的（20/20 仍成立，但 LM 类结论不可信）。

### 4.8 LM 评测（新工具 + 首批数据）
新增 `scripts/eval_gram.py`：黄金用例 + 混合拼写 + **句子级（全拼还原）**。

**关键发现：混合拼写用例测不出 LM 差异**——它们被词库决定（传统词组置顶），
实测"不存在的 gram"与真 gram 结果逐条相同。真正能判别 LM 的是
**全拼长句还原**（必须组句）。

句子级对比（同词库，100 条语料句转全拼，首候选==原句）:

| gram | 体积 | 黄金 | 句子还原 |
|---|---:|---:|---:|
| essay-bgc（现役） | 27.7 MB | 20/20 | 13/100 |
| 自训 t100 | 18.3 MB | 20/20 | 14/100 |
| 自训 t30 | 58.8 MB | 20/20 | **16/100** |
| 自训 full | 236.9 MB | 20/20 | 16/100 |

结论：
1. **t30（59MB）与 full（237MB）效果持平** → 237MB 是无谓的，已重出为 59MB。
2. 自训 gram 均优于 essay-bgc（+2~3 条）。
3. 两套 gram 在 **42/100** 条上结果不同 → LM 确实在影响输出。
4. 绝对准确率低（16%）→ **全拼路径本身弱**（词库以五笔为主），
   这是下一阶段（词典权重/拼音覆盖 C2–C6）要攻的主目标。

新增 `scripts/corpus/gram_retune.sh`：聚合 TSV → 阈值过滤 → build_grammar，
**秒级切换体积**（不必重算计数 85G）；`--stats` 给阈值→体积映射表。

### 4.9 全拼路径：LM 为何是净负作用（根因已定位）

**评测集必须固定**：早先从 clean/short 采样生成——语料一变采样就变，两次评测是两套题
（已踩：16/100 vs 12/100 完全不可比）。已修为固定文件
`data/corpus/eval/sentences.tsv`（200 句），`--regen-sentences` 才重建。

**同题对比（200 句全拼还原，首候选==原句）**：

| 配置 | 黄金 | 句子还原 |
|---|---:|---:|
| **无 gram** | 18/20 | **47/200 (24%)** |
| 原配置（-10/-12/-24/-30）+ essay-bgc | 20/20 | 36/200 (18%) |
| 原配置 + 自训 gram | 20/20 | 33/200 (16%) |

**根因（读源码得出，`src/rime/gear/grammar.h`）**：

```cpp
const double kPenalty = -13.8155;              // log(1e-6)
return entry_weight + (grammar ? grammar->Query(context, text, is_rear) : kPenalty);
```

- 无 grammar：每词固定 **-13.81**（等价于一个“倾向更少分段”的稳定先验）
- 有 grammar：换成 `Query = log(count) - 罚分`，而默认罚分只有 **-10 / -12**
  —— **高于 -13.81**，于是每个词都拿到一笔“白送奖金”，证据越多奖金越高，
  而证据最多的恰恰是**高频单字** → 系统被奖励去拆字。
- 且 `poet.cc:249`：有 grammar 走 **BeamSearch**（每位置 top-7），无 grammar 走
  **DynamicProgramming**（无损）——两套搜索算法不同。

**实验矩阵（均为同一 200 句固定评测集）**：

| 实验 | 改动 | 句子还原 |
|---|---|---:|
| 基线无 gram | bogus language | **47/200** |
| 大罚分 | -10/-60/-120/-60 | 35/200 |
| 罚分全 0 | 0/0/0/0（纯奖励） | 32/200 |
| 对齐 kPenalty | -13.8155 ×3，rear 0 | 34/200 |
| 对齐 + beam 7→64 | 改 `kMaxLineCandidates` 重编 | 34/200 |
| 统一大负值 | -100 ×3 | 34/200 |

→ **结论：罚分数值、beam 宽度都不是原因；LM 给的正向证据本身在全拼路径上
是伤害（证据越多越差）**。推测：字符级 n-gram 的证据过于泛化（如 (的, X)
无处不在），奖励的是“常用字序列”而非“正确词”。

→ gram 的价值在**混流路径**：黄金用例 20/20 vs 无 gram 18/20（ckwan→台湾 类）。

**待选方向**（需产品决策）：
1. 全拼路径不用 gram（24%），混流路径保留 gram —— 需分 translator 配置
2. 换词级 gram / 训练更干净的语料（当前 char 级证据太泛）
3. docs §6 的 `always_make_sentences` + 重排 lua：让 LM 只做候选重排、不参与分词

### 4.10 部署到 host-linux（已实装并验证）

**环境**（与开发机不同，之前误以为是 macOS）：


**环境**（不是 macOS）：Gentoo Linux + fcitx5，Rime 用户目录
`~/.local/share/fcitx5/rime`。

**❗ 关键前提：新架构需要 librime ≥ 1.17**

| librime | `max_sentences` 配置键 | `MakeSentences` 符号 | 后果 |
|---|---|---|---|
| 1.16.1（host-linux 原装） | ✗ | ✗ | 只能给出 **1 个**整句候选 → 重排无从下手，
而且 grammar 被关掉 → 退化成纯权重（`ckwan→台万`） |
| **1.17.0** | ✓ | ✓ | 20 个整句候选 → LM 重排生效（`ckwan→台湾`） |

判据：`strings <librime.so> | grep -c max_sentences`（1.16.1 为 0）。

**处理**：把 host-linux 的系统 librime 从 1.16.1 升到 1.17.0：
```bash
# 1.17.0 在 gentoo 仓库里但被 ~amd64 mask
printf 'app-i18n/librime ~amd64\napp-i18n/librime-lua ~amd64\napp-i18n/librime-octagram ~amd64\n' \
  > /etc/portage/package.accept_keywords/rime-1.17
sudo emerge -1 '=app-i18n/librime-1.17.0'     # 同时重建 lua / octagram 插件
```
注意：远端 shell 是 **zsh**，`=app-i18n/...` 会被 zsh 当成 `=cmd` 展开 →
必须用 `bash -c '... "=app-i18n/librime-1.17.0"'` 或转义。

**升级副作用**：`librime-octagram`（::local 包）编译失败（C++ 模板约束错），
但**旧的 octagram.so 仍可加载**，且我们的方案不用 grammar（Lua 里把它指向了
不存在的语言），实测 8/8 用例全过。你其它方案若依赖 grammar，可后续重建该包。

**部署方式（按用户要求：目录自包含，不软链 vmacs）**：
`scripts/deploy_host-linux_direct.sh`：
1. 整目录备份 → `~/rime-backup-<时间戳>.tar.gz`
2. 把现有软链**实体化**（`cp -aL`，保留你其它方案与用户词典；*.gram 保持软链）
3. 覆盖 16 个运行时文件
4. `rime_deployer --build <用户目录> /usr/share/rime-data <用户目录>/build`
5. 重启 fcitx5（`setsid fcitx5 -d`）

**验证（host-linux，系统 librime 1.17.0）8/8 通过**：
`e→有` / `q→我` / `yi→就` / `jintiandetianqizenmeyang→今天的天气怎么样` /
`wojintianmeiyoukong→我今天没有空` / `wokanshiqiaomai→我看是荞麦` /
`ckwan→台湾` / `taiwan→台湾`

**踩坑**：
1. `rime_deployer --build <用户目录>` 的 shared_data_dir 默认是**当前目录**，
   必须显式传 `/usr/share/rime-data`，否则 `failed to include section symbols:punctuator`
   （会连带把你其它方案一起编译失败）。
2. **失败的部署会留下半成品 build**（prism.bin 新、table.bin 旧）→ 表现是
   "输入法激活但没中文"。碰到这个先 `rm -rf build` 重跑部署。
3. ssh 命令里加 `-n` 会吞掉 heredoc 的 stdin（远端什么都不执行），
   用 heredoc 时不要加 `-n`。
4. 判定候选类型要用 `c:get_dynamic_type()`（返回 "Sentence"/"Phrase"）；
   `c.type` 在部分版本对句子返回小写 "sentence"，不可靠。

### 4.10b 部署到 host-mac（macOS + Squirrel，已实装并验证）

**环境**：macOS 15.7.4 / arm64，Squirrel（2026-09-28 升级后内置 librime **1.17.0**，
升级前是 1.16.0），ssh 走本机 agent 转发：`jixiuf@localhost:8092`
（端口是 mac 侧 RemoteForward 来的）。Rime 用户目录 `~/Library/Rime`
（原本 yaml/dicts/lua/opencc 全软链到 `~/vmacs/rime`）。

**脚本**：`scripts/deploy_host-mac.sh`（参照 host-linux_direct，按用户要求直接部署到
`~/Library/Rime`、写成实体文件）

1. 整目录备份 → `~/rime-backup-<时间戳>.tar.gz`（软链按软链存，回滚只需 `--rollback`）
2. 根级软链实体化（`cp -aL`；`*.gram` 与 `sync` 保持软链）——含 `dicts/ lua/ opencc/`
3. 覆盖 38 个运行时文件（**全部 15 个** egret_wubi_py 词库 + **全部 `lua/*.lua`**
   + lm_rerank.tsv/meta + 4 个 yaml）
4. `"$SQUIRREL/Contents/MacOS/rime_deployer" --build ~/Library/Rime \
     /Library/Input\ Methods/Squirrel.app/Contents/SharedSupport ~/Library/Rime/build`
5. **默认不重启 Squirrel**（用户要求：文件到位即可）；`--restart` 才重启
6. 自检：在 `~/.egret-check` 里跑 `~/repos/librime/build/bin/rime_api_console`（1.17），
   不动 `~/Library/Rime/build`（避免与 Squirrel 前端的 build 产物互相干扰）

**验证（Squirrel 升到 librime 1.17.0 后，1.17 console 8/8 通过）**：`e→有` / `q→我` /
`yi→就` / `tffu→等` / `khlg→中国` / `jintiandetianqizenmeyang→今天的天气怎么样` /
`wojintianmeiyoukong→我今天没有空` / `wokanshiqiaomai→我看是荞麦`；
另、`ckwan→台湾`、`taiwan→台湾`、`q→我` 单跑也过（**`ckwan→台湾` 是 1.17 才有的效果**——
1.16 时整句只 1 个候选，LM 重排无从下手，会出「台万」）。

**踩坑**：
1. **Squirrel 升级前内置 librime 1.16.0 < 1.17** → 新架构（LM 只重排）长句只有 1 个
   候选，重排不生效（与 §4.10 的 host-linux 同因）；脚本会显式告警。升到 1.17.0 后
   自动变成“可生效”，无需改方案。判据：`strings librime.1.dylib | grep -c max_sentences`。
2. **macOS 没有 GNU `timeout`**：写了个 `run_timeout`（后台 + 看门狗）。看门狗子 shell
   必须 `>/dev/null 2>&1`，否则它持有命令替换的管道写端 → `OUT=$(run_timeout ...)`
   会一直等到看门狗超时才返回（表现为“脚本卡住”，实测卡 10+ 分钟）。
   （另、macOS bash 3.2 把 `$SL（` 里的全角括号当成变量名字符 → `unbound variable`，
   变量后紧跟中文一律写成 `${SL}`。）
3. **用户目录里的 key_bindings.yaml 会遮蔽新版 Squirrel 的共享版**：新版
   `SharedSupport/default.yaml` 有 `selector: __include: key_bindings:/rotate_candidate_with_tab`，
   而 `~/Library/Rime/key_bindings.yaml`（旧副本，缺该键）优先 → `error building config: default`，
   `build/default.yaml` 停留在旧版（方案列表仍正常，但新 Squirrel 的默认改动不生效）。
   修法：用 `SharedSupport/key_bindings.yaml` 覆盖用户副本（diff 验证过旧副本无独有内容）。
4. 自检不要直接在 `~/Library/Rime` 里跑 1.17 console：会在 Squirrel 的 build 上重建，
   可能留下与 1.16 不兼容的产物。用 scratch 目录 + 软链用户文件（build 用 scratch 自己的）。
5. 首次在全新 scratch 目录里 deploy 可能报 `[deploy] failure`，再跑一次（或显式
   `rime_deployer --build`）即可；`build` 目录保留着就是热重建，别每次 `rm -rf`。
6. **认证：`ssh-add -l` 成功 ≠ 能签名**。之前 find_agent 只看 `ssh-add -l`，会选中
   转发进来的 gpg-agent socket（socket 属主是 sshd，处于 restricted 模式 / 需远端
   pinentry 确认）→ 握手时 `signing failed: agent refused operation`，scp 直接失败。
   修法：用**一次真实握手**（`ssh ... true`）挑认证方式，顺序 agent socket → 本地
   私钥（`EGRET_SSH_KEY` → `~/.ssh/id_rsa` → `/export/vmacs/dots/ssh/id_rsa`）→
   自起 ssh-agent。本机可用私钥是 vmacs dotfiles 里的那个（与转发 agent 里的同一把，
   `3072 SHA256:S/+8/2y04…`）；`ssh -i` 直连 `localhost:8092` 通，不需要 agent。
7. **“自检全 ✗、候选为空”大多不是词库问题**，两个已踩过的原因：
   a. 部署清单漏了 lua 组件：schema 引用了 `lua_filter@*compose_filter`、
      `dynamic_translator` 又 `require("py_composer")`，而清单只同步了
      `dynamic_translator.lua`/`lm_rerank.lua` → 远端 `lua/` 缺文件。现在全量同步
      `lua/*.lua`。判断：console stderr 里 `module 'compose_filter' not found`。
   b. console 的 `shared_data_dir` 默认也是 `.`（同 `Makefile` env-test 注释），
      `~/.egret-check` 里必须同时有 `symbols.yaml/default.yaml/essay.txt`（软链到
      `~/repos/librime/build/bin/` 即可），否则 `resource could not be loaded: symbols`
      → schema config 构建失败 → 所有输入都无候选。
6. 备份体积：软链实体化后整目录 tar 约 144MB（含 dicts 副本）；`*.gram`（≈290MB）不入包。
   `--keep-links` 则不实体化，写入会穿透软链落到 `~/vmacs/rime`。

### 4.11 ⭐ LM 只重排、不参与分词（**纯 Lua 实现，不改 librime**）

**最终方案**：把 LM 从 librime 搬到 Lua 层。librime 只按词库权重分词，LM 只对整句候选重排。

实现（全部在我们自己的代码/数据里）：

```
scripts/gen_lm_rerank.py    从 3470 万条 n-gram 聚合数据抽 60 万条（含 1gram）
                            → data/gram/lm_rerank.tsv（8MB）+ .meta（总字数）
lua/lm_rerank.lua           载入表 + 条件概率打分 + 对 Sentence 候选重排
lua/dynamic_translator.lua  init: 临时把 grammar/language 改成不存在的名字，创建
                            “分词不受 LM 影响”的翻译器（创建后立即恢复）
                            func: 对整句候选按 LM 分数重排（不改变候选项分组）
egret_wubi_py.schema.yaml   dynamic_translator/lm_rerank: true
                            translator/max_sentences: 20（给多个整句候选）
```

**打分公式（关键）**：条件概率 + 阶数 backoff + unigram 底线

```
score = Σ_i max( logP(c_i | c_{i-3..i-1}) , ..., logP(c_i | c_{i-1}) , logP(c_i) )
  其中 logP = log count(ngram) − log count(ngram 前缀)，unigram 以总字数归一
```

**效果（同一 200 句固定评测集）**：

| 配置 | 黄金 | 句子还原 |
|---|---:|---:|
| 原配置（LM 参与分词） | 20/20 | 32/200 (16%) |
| 无 gram | 18/20 | 47/200 (24%) |
| librime 补丁 rerank（已废弃，见下） | 18/20 | 52/200 (26%) |
| **纯 Lua 重排（原生 librime）** | **20/20** | **55/200 (28%)** |

→ 相对原配置 **+72%**，且**黄金用例 20/20 全过**（比补丁版更好）。

**已废弃**：早先的 `scripts/patches/librime-rerank-only.patch`（改 poet.cc）已删除，
`third-party/librime` 已还原为原生（无本地改动）——方案现在不依赖任何 librime 修改。

**踩坑记录（写这个时踩的）**：
1. **`log count` 直接累加会挑错**：log count 天然偏爱高频短 n-gram，会把
   「我今天没有控/恐/孔」排在「我今天没有空」前。必须用条件概率。
2. **无证据的罚分不能比真实低频概率还高**：固定罚 -3000 比
   `logP(是|看) = -4901` 更高 → 「我看**式**荞麦」赢了「我看**是**荞麦」。
   必须 backoff 到 unigram 概率做底线。
3. **首字符要单独算**：循环从 i=2 开始会漏第一个字，导致多个候选同分并列。
4. **Lua 里候选类型要用 `cand:get_dynamic_type()`**（返回 "Sentence"/"Phrase"），
   不是 `cand.type`（那是静态串，组合句也是 phrase）。
5. **Lua 的 `return` 必须是块内最后一句**：在 `return M` 后追加函数是语法错误，
   而 `luac -p` 能报出来，值得先跑一遍。
6. `log.warning`/`log.info` 在 console 里看不到，诊断请用 `log.error`。

**调参/诊断**：
```yaml
dynamic_translator:
  lm_rerank: true          # 开关
  lm_rerank_debug: true    # 打印候选与 LM 分数（log.error 级）
```
```bash
python3 scripts/gen_lm_rerank.py --top2 300000 --top3 200000 --top4 100000
third-party/venv/bin/python scripts/eval_gram.py --cases 0 --sentences 200 \
  --gram "x=$PWD/data/gram/zh-hans-egret.gram"
```

**调参可复现命令**：
```bash
# 改罚分: egret.common.yaml 的 grammar 段 → 重跑评测
third-party/venv/bin/python scripts/eval_gram.py --cases 0 --sentences 200 \
  --gram "无gram=$PWD/data/gram/zh-hans-egret.gram|no-such-gram" \
  --gram "有gram=$PWD/data/gram/zh-hans-egret.gram"
# 改 librime 源码后重编（约 1 分钟）
export PATH=/opt/rh/gcc-toolset-12/root/usr/bin:$PATH
cd third-party/librime/build && cmake --build . -j 8 --target rime
```

### 4.12 评测口径修正 + 多来源整句评测集（重要）

用户指出"一分钟经理这类句子不通顺"，并建议用**不同类型文章的整句**做测试。修正如下：

**新评测集** `data/corpus/eval/sentences_v2.tsv`（`scripts/gen_eval_set.py`）：
- 从 `clean/para/` 切**完整句**（必须有句末标点，避免行尾碎片）
- 随机窗口采样（每源 400×1MB，多进程）→ **35 秒**完成（旧版全量扫描要 40 分钟）
- 过滤：8~20 字、全汉字∈高频字表、**语感过滤**（字符级平均 log 概率 ≥ 阈值，
  滤掉"四北仓台米"这类碎片）、去标题/编号/残句（不以「的了在和…」开头、引号配平）
- **按来源分层**：epub 书籍 / jsonl（新闻+维基+百科）/ parquet（网页文本）/ markdown（课程文稿）
- **关键：期望文本去标点**——输入是纯拼音，用户不会把逗号算进拼音；
  旧集只剥句末标点，导致"少一个逗号"被算成错，**虚低准确率**（13% → 实际 21%）

**结果（160 句，原生 librime）**：

| 配置 | 完全命中 | 字符准确率 |
|---|---:|---:|
| A 原配置（LM 参与分词） | 21/160 (13%) | 53.4% |
| B 无 gram | 28/160 (18%) | 54.3% |
| **C Lua 重排（当前）** | **34/160 (21%)** | **57.9%** |

→ Lua 重排相对原配置 **+62%**，字符准确率 +4.5pp。指标同时报告"完全命中"与
"字符准确率"（长句完全命中天然低，字符准确率更稳定可追踪）。

**已知缺口（下一步）**：
- 重排天花板：正确句只在候选里 ~50%（max_sentences=50 时 52%）
- LM 表偏小：60 万条 char 2-4gram；失败样例需要的是 `P(理|钟经)` 这类三元组
- 重排只看 LM，**丢掉了词库权重**信息 → 应加权融合

### 4.13 开源语料接入（可持续扩展）
- 参考 **RIME-LMDG**（万象 gram 工厂）：维基链路 `gensim extract_pages +
  filter_wiki + OpenCC t2s`（145 万篇）；短句化 = **标点断句 + 只留汉字**。
- 清单位于 `scripts/corpus/open_sources.tsv`（TAB 分隔：name/dataset/glob/体积/许可/用途），
  **加一行即多一个语料源**；下载器 `fetch_open.sh` 自动展开 HF 文件树、断点续传、
  `.part`+改名、zip 自动解压、`--max-gb` 分批配额（带宽是瓶颈 ~5.7MB/s，串并行一样）。
- 维基走专用管线 `wiki_pipeline.sh`（下载 + **官方 md5 校验** + wikiextractor + 投放）。

已接入 / 正在拉取：

| 源 | 体积 | 定位 |
|---|---|---|
| 电子书 epub | 13.5 亿字 | 自有：出版物级现代汉语 |
| 文稿（听书+课程） | 2.1 亿字 | 自有：通俗口语讲解 |
| zhwiki dump | 3.4G | 百科（md5 已校验） |
| THUCNews | 2.1G | 新闻 15 类 |
| 人民日报 1946- | 2.0G | 时政社论 |
| 古文语料 | 0.11G | 成语/书面语 |
| Fineweb-Edu-Chinese-V2.1 | 18G(抽 100/900) | 高质量教育网页文本 |
| 百度百科 563 万 | 15.7G | 实体/术语 |
| 中文口语对话 | 17G(抽 4/32) | **补自有语料全书面语的缺口** |
| 法律法规 / 医疗对话 | 1.0G | 垂直领域术语 |

**排除**网文/社交媒体（docs 记录过「才最」口味污染）。

### 4.14 格式支持
`formats.py` 注册式处理器：epub / markdown / html / 纯文本 / jsonl（gz 感知）/
**parquet**（pyarrow 流式 batch 读，内存有界）。新增格式只需加一个类。

### 4.15 统一码表搜索器（五笔+拼音+混流）+ ❗交付受阻的结论

**起因**：用户报五笔打 `qktqn` 出不了「我吃饭(了)」。
**澄清 86 编码**：`kt` 归**呼**、`qn` 归**包**（吃的三级简码 `ktn`、饭 `qnr`）；
但真问题是**分段裁决**——`qktnqnr` 被 librime 解析成「名」(`qk`)+…，
因为**一级简码 `q`=我 与二级简码 `qk`=名 有前缀歧义**（`trwuktnqnr` 无歧义所以能对）。

**产物**：`scripts/gen_compose_table.py` 把**五笔字码（含一/二级简码）+ 五笔词码 +
拼音字/词码**合成统一码表（27 万条 / 5.3MB，`data/gram/compose_table.tsv`）；
`lua/py_composer.lua` 在其上做 beam search，打分 = Σ「词的一元 LM `log f(w)−log N`」+ LM 上下文增益
→ **同一搜索器同时支持纯五笔 / 纯拼音 / 混流**。独立验证全对：
```
qktqn / qktnqnr → 我吃饭   qktnqnrb → 我吃饭了   trwuchifan/trwuktnqnr → 我们吃饭
nishuo → 你说   jintiandetianqizenmeyang → 今天的天气怎么样
xietiaotujinsigequanmianzhanlvebuju → 协调推进四个全面战略布局
```
⚠ `LOG_N` 偏大会**过度偏袒"少分段"**（23400 时 `qktnqnrb→我吃包拯`）；按字数/1.5 估算（≈17400）即可。

**❗❗ 交付受阻（重要结论，别再重走）**：自建结果**送不进输入法**，四条路都试过：
| 交付方式 | 结果 |
|---|---|
| 翻译器**新增**候选并置顶 | 引擎判"整段已消费"→**输入中途提交**（`jintiande` 被切成 `jinti|ande`，评测 0/160） |
| filter **新增**候选（区间取 `[0,#input]` 或沿用他人） | 同样中途提交 |
| filter **改写**候选文本 | librime-lua 的 `cand.text=...` **只对 `SimpleCandidate` 生效**，对 Sentence/Phrase **静默无效** |
| 构造真正 `Sentence` 候选 | librime-lua 的 Sentence 绑定**只有只读属性，无构造器** |
→ **不碰 librime 就只能自建完整翻译链路**（自带编辑器语义）；当前 `lm_compose: false`（关闭），
  码表与代码保留。（`compose_filter` 仍在 filter 链末尾，默认 `lm_compose: false` 时不生效。）

### 4.16 整句词库（数据交付路线，机制已验证）

既然"新造候选"被引擎封死，但**精确匹配的词条引擎本来就认**（墨奇 rime-wubi-sentence 同思路）
→ 把语料高频整句预计算成「五笔短码序列 → 整句」词条。
- `scripts/gen_sentence_dict.py`：随机窗口采样统计高频整句（每字取最短码：一/二/三级简码里最短），
  去重 + log 频次权重 → **6 万条 / 2.2MB** → `dicts/egret_wubi_sentence.dict.yaml`，
  并入传统库 `import_tables`
- **实测机制通**：`owfhtc → 为什么` ✓、`thftclw → 怎么办` ✓；黄金 **20/20** 不受影响
- **无副作用验证**：装载/不装载该库，eval 前 40 句同为 6/40（那 40 句是 epub 子集本就难）
- 局限：只覆盖语料**高频**句（`我吃饭了` 在书面语料里稀有 → 未入榜）

### 4.17 权重重标定：四次尝试全部失败（勿重走）

| 范围 | 结果 |
|---|---|
| 全部词权重 → log 尺度 | 黄金 15/20 |
| 拼音字表 ×0.35 | 黄金 17/20（`wan→人世`） |
| 字·词整链 log 重标定（shift 0/4000/6000/8000） | 均 17/20 |
| **只重标混合库**（传统库不动，可保住 tffu/tgtj） | 仍 17/20（`jintiande…`/`wojintianme…`/`wan` 破） |
→ **现有字表/词表权重是整体手工调好的**，任何单侧或整链改动都会破黄金。
  要重做必须**全链重标定 + 用黄金用例与整句评测联合标定**，不是改参数能了事。

### 4.18 混流机制调研（子代理三路，含 file:line 证据）+ ❗测量纪律

**⭐ 短码序列打不出整句的真正机制**（此前推测有误）：
`ScriptTranslation::Evaluate` 的 `has_reliable_phrase = has_exact_match_phrase(...)`
（`script_translator.cc:446/482`）——只要存在一条**覆盖整段输入**的精确词条（系统或用户词），
**整段直接跳过组句**（`:496-503`）。
- 实证：生僻字 **㲒** 在 `egret_wubi_py_chars.dict.yaml:1491` 有 `qkt`/`qktn`（weight 1）
  → 输入 `qktn` 命中它 → 不生成任何整句 → `qktn→㲒`、`trwuqktn→我们㲒`、`qktnqnr→㲒饭`
- 对照：`trwuktnqnr` 无整串词条 → 正常组出「我们吃饭」✓
- 热机后 `qktqn→我吃饭`、`qktnqnrb→我吃饭了` **本来就是对的**；失败的是 `qktn`/`qktnqnr`（被 㲒 短路）

**❗❗ 测量纪律（重要，推翻本文档多处旧结论的前提）**：
`data/rime-test` **冷部署首跑的分段与热机完全不同**（`qktqn` 首跑 `[qk tq n]`→名称嗯，
热机 `[q ktqn]`→我吃饭）。**任何单跑结论都不可信，必须同一 code 连跑两次取第二次**（呼应陷阱 #9 prism 非确定性）。
→ 本文档 §4.15/§4.16 里「qktqn→名称嗯」类结论**很可能来自冷态，需复核**。

**参数真相（与直觉相反，均已核到源码）**：
| 参数 | 实际 |
|---|---|
| `translator/max_sentences: 300` | **被 clamp 到 100**（`translator_commons.cc:129`），写 300 无效 |
| `translator/max_homographs: 7` | 对 script_translator **no-op**（script 不读） |
| `translator/always_make_sentences: true` | **本仓库 librime 无此实现**（strings 计数 0）→ no-op |
| `lm_rerank: true` | 它把 `grammar/language` 改成不存在的名字 → `Octagram::Query` 走兜底（`octagram.cc:110`）→ 实际是 **BeamSearch + 固定 -12/词**，**并非真 LM** |
| `grammar.h:24` 的 `kPenalty=-13.8` | 只在 **grammar 指针为 null** 时生效；本方案指针非空、db_ 为空 → 走 -12 |

**其他实测**：
- **反查不可用**：recognizer patterns + `reverse_lookup_*` 配置都在，但 engine **没有 reverse_lookup translator**，
  且 `egret_py` 依赖已剥离 → `` `wo' `` 无候选（`wubi_comment` 也被注释）✗
- **大写输入是死路**：`GTNK`/`WQ` 候选为空（既不进英文态也不强制五笔）✗
- **混流裁决偏向五笔读法**：拼音字表被 ×0.35 压低 → `qjintian→旬泌汇`、
  `wojintianmeiyoukong→伙晃发泄届膛亦咪怀`（正确句退到第 4 位）✗
- `dictionary_exclude` 排除 10.7 万 weight=1 生僻字**实测无效**（`qktn` 仍出 㲒），已撤回 ✗
- 单字母 `z` 被 `abbrev` 规则当拼音首字母（→在/这/中）：**用户决策：不做简拼**，
  故可考虑关闭 `egret.common.yaml:132-135` 的 abbrev（本轮未完成：注释 132-133 后 `z→在` 仍在，
  需继续定位，暂已还原）

**生僻字处理实验（三次，全部失败，勿重走）**：
目标是「生僻字权重低但保留输出能力」。实测：
| 做法 | 结果 |
|---|---|
| `dictionary_exclude` 排除 10.7 万 weight=1 生僻字 | `qktn` 仍出 㲒，无变化 |
| 从混合库**删除** weight<=1 生僻字 | 组句未改善，且方案整体崩（0/20）|
| 生僻字**搬到传统库**（保输出能力） | `wan→𠇘`（压掉黄金用例「万」），19/20；`qktn`/`qktnqnr` 无改善 |
根因：`qktnqnr→名秘饭` 并非（只）是短路造成，混合库自身分段就偏五笔读法；
而传统库 `initial_quality: 1000` 让搬过去的生僻字恒压一切 ✗。
→ 结论：**生僻字问题不适合在词库层解**，得回到「混流读法权重」或「共识重排交付」上（R10 / §4.15）。

**改进优先级（据调研重排）**：① 恢复候选码提示（`wubi_comment`/`super_comment`）② 关 abbrev（按用户决策）
③ 拉黑生僻字短路（换有效手段）④ 混流拼音读法权重按场景修正 ⑤ 反查补齐

### 4.19 ⭐⭐ 混流组句的总根源已定位并修复：简码拼写不在组句空间里

**总根源**（此前多轮都在别的层面打转）：
本方案的设计是「**一级简码只在传统库发**」——于是
```
传统库字表 egret_wubi_chars:  我 → q(一级简码) / trn / trnt / trxy
混合库字表 egret_wubi_py_chars:        我 → trx / trxy / trnt        ← 没有 q ✗
```
而**组句是混合库的 script_translator 在 prism（拼写空间）上做的** →
用户实际会敲的**简码层根本不在组句的拼写空间里** ✗。
所以 `q`+`chifan`（五笔简码+拼音）、`q`+`ktn`+`qnr`（短码序列）都够不到「我」，
组句只能退化到错误读法（`名秘饭` / `色步犯了`）——**这才是混流组句失败的总根源**。

**修复**：`scripts/gen_jianma_spellings.py` 把权威简码表（传统库字表）里的
**641 条一/二级简码**（25 个一级 + 616 个二级）补进**混合库字表**（幂等，源数据在仓库内，已接进 refresh.sh）。
**一行数据修复，效果如下**：

| 输入 | 修复前 | 修复后 |
|---|---|---|
| `qktqn` | 名称嗯 ✗ | **我吃饭 ✓** |
| `qktnqnr` | 名秘饭 ✗ | **我吃饭 ✓** |
| `qktnqnrb` | 名秘包拯 ✗ | **我吃饭了 ✓** |
| `qchifanle`（五笔简码+拼音，用户给的例子） | 色步犯了 ✗ | **我吃饭了 ✓** |
| `qchifan` | — | **我吃饭 ✓** |
| `trwuktnqnr` | 我们吃饭 ✓ | 我们吃饭 ✓ |
| `jintiandetianqizenmeyang` | 今天的天气怎么样 ✓ | 不变 ✓ |

**零回归验证**：黄金 **20/20** ✓；160 句整句评测 **41/160 (26%)**（与基线完全一致 ✓）。
→ **纯数据修复，不改 librime、不改权重、不破任何既有能力。**

#### 4.19b 同类症状②：混合库字表**缺大量全码** → 组句走「2+2」错误路径

用户报：`uwycuklf`（冷+部署）出 **闪充部署** ✗，而单独 `uwyc→冷` ✓、`uklf→部署` ✓。
根因：混合库字表里 **`冷` 只有 `uwy`（三级码），没有全码 `uwyc`**；
`署` 只有 `lft` 没有 `lftj`。组句够不到 `uwyc`，只能走
`闪(uw)+充(yc)+部(uk)+署(lf)` 的 2+2+2+2 路径 ✗。
→ 与简码问题是**同一类**：**混合库（组句空间）的五笔拼写不完整**。

修复：把生成器从「只补 1~2 码简码」扩到**补全所有纯字母五笔拼写**（1~4 码，仅 CJK 字，
跳过 ¤ § 等符号），共补入 **4,976 条**（`gen_jianma_spellings.py` 已改名实义为「补全五笔拼写」）。
实测：`uwycuklf → 冷部署 ✓`、`uwyuklf → 准部署 ✓`；黄金 20/20 ✓；160 句评测 41/160 (26%) **不变** ✓

**遗留**：`qktn → 㲒`（㲒 是生僻字，全码就是 qktn，由传统库精确匹配给出，
`initial_quality: 1000` 置顶）——这属"精确码优先"的设计语义；若要短码序列优先，
需 §4.15 的「共识重排」交付机制（已就绪，`lm_compose` 开关）。

**顺带建立测量工具**：`scripts/probe.sh <输入...>` —— 每个输入**连跑两次取第二次**
（`data/rime-test` 冷部署首跑与热机结果不同，见 §4.18 测量纪律）。

### 4.20 候选显示五笔编码（**原生 reverse_lookup_filter，零 Lua**）

需求：候选里显示该词的**五笔码**（学五笔 / 核对用）。

**做法**：用 librime 原生 `reverse_lookup_filter`（`reverse_lookup_filter.cc`）——
它拿候选文本去**另一本词典**反查，把命中的码写进注释 ✓ 不需要 Lua。
配置（参考 `~/vmacs/rime/old/egret_wubi_py.schema.yaml:169` 的成熟写法）：

```yaml
filters:
  - reverse_lookup_filter@wubi_comment     # 放在 simplifier@traditionalize 之前（查简体文本）
wubi_comment:
  tags: [ abc ]
  dictionary: egret_wubi   # 反查用它：字含一/二/三级简码与全码，词含标准词组码
  overwrite_comment: true          # 覆盖其它提示（如补全标记）
  comment_format:
    - "xform/[ ].*$//"             # 一个字有多个五笔码时只显示第一个 ★关键技巧
    - "xform/^/ /"                 # 与候选文本视觉分隔
```

**效果实测**（`scripts/probe.sh` / console）：
```
q         → 我 q            一级简码
trwu      → 我们 trwu         uwycuklf → 冷部署 / 冷 uwyc
nihao     → 你好 wqvb        ★ 拼音输入时显示五笔码（学五笔最有用）
jintiande → 今天的 / 今天 wygd   de → 胡 de
```
黄金 **20/20** ✓（注释不影响候选排序）。

**走过的弯路（记录）**：
1. `spelling_hints`（script_translator 原生）显示的是**输入拼写**——拼音输入时显示拼音 ✗ 不是五笔码，
   且受码长 `cand.code().size() <= spelling_hints` 限制；
2. `super_comment.lua`（万象组件）挂上直接崩（0/20），且需要一大坨自定义配置 ✗；
3. 自写 Lua filter + 反向索引（`set_comment` 对 Phrase 生效 ✓，与 `set_text` 不同）——**能用但没必要**，
   原生组件已覆盖 ✓（用户明确要求"非必要少用 Lua"）。

### 4.21 词库组织梳理 + 生成产物移出 git

**背景**：整族改名后出现 `egret_wubi_wubi_words_*`（生成器前缀笔误）等冗余；且
`dicts/` 里 30+MB 的分档词表在 git 里频繁变动、diff 噪声大。

**三个库的分工（现已清晰）**：
| 库 | 角色 | schema |
|---|---|---|
| `egret_wubi` | 形码确定性层（86 显式简码/全码/词组码，table_translator 置顶） | egret_wubi.schema.yaml（内部辅助，只为编译词库） |
| `egret_py` | 读音层（纯全拼，也是「`+拼音」反查的词典源） | egret_py.schema.yaml（白鹭全拼） |
| `egret_wubi_py` | 混流层（五笔码+拼音音节，script_translator 组句 + LM） | egret_wubi_py.schema.yaml（主方案） |

**处置**：
- **删除**：`egret_wubi_wubi_words_{core,base,full}`（改名笔误，无人引用）
- **生成器修正**：`gen_dict_tiers.py` 传统库改为 `kind=words + prefix=egret_wubi`
  → 产出 `egret_wubi_words_wb86_{tier}`（与 wrapper 的 import 一致）
- **移出 git**（`.gitignore`，工作区文件保留）：拼音词表中间产物
  `egret_py_words_src`（1.2MB，只喂给 gen_dict_tiers，不被任何 schema import）
  > ❗ **政策修正（用户指出）**：**只要是输入法实际用到的词典（被 schema/wrapper import 的）
  > 一律入 git** —— 部署与用户拿到的就是它们。所以三族分档词表 9 个 + egret_wubi_force_end
  > **全部加回 git**；只有「纯中间产物」不入 git。
- **仍入 git**（源数据）：字表层、`egret_wubi_words_wb86_src.dict.yaml`（86 造词码源）、
  `wb86_wangxiang_cn_dicts/*`、`wubi86/*`、`*_8105`、用户短语、整句词库（需语料，重建成本高）

**可复现性已验证**：删光全部 9 个分档表 → `bash scripts/refresh.sh --only dict` 全部重建
→ 黄金 20/20 ✓。Makefile 的 `env-test` 加了自愈守卫（缺失时自动跑一次 dict 阶段），
新克隆 `make test` 也能直接通过。

**新增能力（本轮）**：`egret_py` 纯全拼方案（`nihao → 你好 wqvb` 顺带显示五笔码）；
混合方案点亮「`+拼音」反查（`` `wo' `` → 我/握/沃 + 五笔码注释）；拼音方案里 ` = 反查笔画。

### 4.22 字表覆盖与生僻字处理（调研 + 两个未接入的工具）

**① 五笔侧覆盖面：已经很全 ✓（不需要再补）**
| 来源 | 基本区 | 扩展A | 扩展B+ | 合计条目 |
|---|---|---|---|---|
| **我们-混合库字表** | 40,830 | 11,242 | 73,620 | **125,692** |
| 源-万象 chars | 20,911 | 6,582 | 42,869 | 70,362 |
| 源-wubi86 | 25,588 | 6,584 | 42,711 | 74,883 |
→ 混合库字表 **70,366 个字**（= 万象 + wubi86 的并集，扩展 A/B 全在内）。
上游那两套字典的生僻字已经被并进来了，**没有"缺的五笔码"** ✓

**② 真正的缺口是「读音层」**
| | 数量 |
|---|---|
| 混合库有字 | 70,366 |
| 拼音表有字 | 8,136 |
| **有字但没拼音** | **62,232**（基本区就有 13,039） |
| pypinyin 能补上 | **33,230（53%）**（基本区 13,039 / 扩A 5,698 / 扩B+ 14,493） |
→ 打拼音够不到那 6 万字；`scripts/gen_pinyin_chars.py` 已能生成
（33,231 条，权重固定最低带 60）。**未接入**：接入前要先解决 ③。

**③ 关键发现：「生僻字的五笔码恰好是拼音音节」会顶掉常用字（短路机制）**
```
ben  →  1. 𨸐 (它的五笔码就是 ben，混合库 weight=1)   2. 本(858)   3. 奔(652)
```
这正是 §4.18 的「整段精确匹配 → 跳过组句、直接置顶、**不比权重**」短路
（script_translator.cc:482/496）—— 生僻字只要码碰巧等于一个拼音音节就会劫持该拼音。
→ 规则：**生僻字的「码=拼音音节」拼写不该进组句词典**（`gen_char_weights.py` 已实现，
本次统计出 105 条候选；但实测 𨸐 未被丢掉，**原因待查**：疑似 LM 字集里含它，
或 SYL 初始化时序问题）。

**④ 字表权重校准（用户提出：语料里有的按词频、没有的给最低）**
已实现 `scripts/gen_char_weights.py`（**未接入**）：
- 语料**出现**过的字 → **保持原权重**（§4.17 教训：整链权重是手工调好的整体，不动）
- 语料**未出现**的字 → 压到最低（五笔表 cap=1；拼音表 cap=60），保留输出能力
- 实测待压低的量：混合库 2,586 条 / 传统库 1,651 条 / 拼音表 1,526 条
  （现有字表里 91% 的罕见字已经是权重 1，剩下这 ~1.4k 条才是"不一致"的部分）

**⑤ 本轮踩的两个坑（重要）**
1. `gen_char_weights.py` 的字符范围判断带了 `'\u4e00'<=c<='\u9fff'`（基本区）
   → **扩展 A/B 的 4.3 万字全被跳过** ✗（所以 𨸐=ben 从未被处理）→ 已改为 `ord(c)>=0x3400`
2. **把 33k 条生僻字拼音放进「混合库」会打乱分段** ✗（`qktnqnr` 直接无候选、黄金掉到
   14/20）→ 生僻字拼音只应进**纯拼音方案** `egret_py`，**不进组句词典** ✗
   （组句词典的拼写集合每变一次，分段结果就变一次，见 §4.19 的设计）

**为什么本次未接入**：接入时我把 wrapper 的 import 行改坏了（挤掉 force_end 行 →
逗号失效 ✗），且 ③ 未解决（`ben` 仍出 𨸐）→ **已全部回滚到绿色状态**
（黄金 20/20、逗号 b,→了、混流全对），工具脚本留在仓库待后续单独验证接入。

### 4.23 ⭐ 字表分层：生僻字「支持但默认不加载」（已落地并验证）

**决定性数据**：混合库字表 125,692 条里 **109,231 条（87%）是扩展区汉字**，
而它们在 50GB+ 语料里**一次都没出现过**；且 **基本区的「五笔码=拼音音节」碰撞为 0**，
所有碰撞（如 𨸐=ben 顶掉「本」）都只在扩展区。
→ 此前所有生僻字麻烦（短路劫持、max_homophones 挤占、部署臃肿、丢碰撞的 hack）
**都是"把 4.3 万扩展字默认塞进组句词典"造成的**，不是权重问题（权重只管排序，
管不了"谁能进池"，见 §4.22）。

**做法**：`scripts/gen_char_layers.py` 把字表拆两层（已接入 refresh.sh 的 dict 阶段，
排在 gen_jianma_spellings 之后）
| 层 | 内容 | 条数 | 默认 |
|---|---|---|---|
| `*_chars_common` | 语料出现过的字 + 有拼音的基本区字 | 混合 16,462 / 传统 12,501 | **默认 import** ✓ |
| `*_chars_ext` | 其余扩展区汉字 | 混合 109,231 / 传统 63,227 | **不 import**（随包发布，一行 patch 开启） |

**效果（实测）**：
| 指标 | 前 | 后 |
|---|---|---|
| `ben` 首候选 | 𨸐 ✗ | **本 ✓** |
| build 体积 | 23 MB | **16 MB（-30%）** |
| 部署耗时 | — | 3.6 s |
| 黄金用例 | 20/20 | **20/20** ✓ |
| 混流 | qktnqnr/qchifanle/uwycuklf ✓ | 全部保持 ✓ |
| 逗号强制结束符 | b,→了 | **b,→了** ✓ |

**要开扩展层**（用户想打生僻字）：
```yaml
# ~/Library/Rime/egret_wubi_py_ext.custom.yaml
patch:
  "translator/dictionary+": egret_wubi_py_chars_ext
```
（或直接用五笔全码 + `,` 强制结束符 / `` ` ``+拼音 反查，两条显式路径本就可打。）

**为什么不做**：① 不删生僻字（姓名/地名/古籍确有需求）② 不再全局调权重（§4.17 四次全破黄金）
③ 不再往组句词典加拼写（§4.19：拼写集合一变分段就变）。

### 4.24 试过用 librime 原生 grammar 取代 lua/lm_rerank.lua —— 不行

动机：`lua/lm_rerank.lua` 把 28.5MB / 190 万行的 n-gram 表整个读进 Lua 哈希再逐候选算分，
内存与初始化都重，用户希望去掉这层 Lua 重逻辑。

实测（同一批 160 句，基线 lm_rerank 开 = 41/160，26%）：
| 配置 | 黄金 | 句子 |
|---|---|---|
| lm_rerank 开（现状） | 20/20 | **41/160 (26%)** |
| 关 lm_rerank，原生 grammar（但 language 指到 essay 旧模型） | 20/20 | 18/160 (11%) |
| 关 lm_rerank，原生 grammar = 自训 zh-hans-egret（字级）+ **默认罚分** | 19/20 | 18/160 (11%) |
| 关 lm_rerank，原生 grammar = 自训 zh-hans-egret + 罚分加重(-30/-30/-40) | **17/20** | 17/160 (11%) |

四格实测完毕（默认罚分那格是最后补的），**原生 grammar 一律 ~11%，且都会掉黄金**（19/20、17/20）。
真正的差距在于**评分方式**：Lua 重排用的是正经的 n-gram 对数概率求和（§4.11），
而 librime 的 grammar 是「词 log 权重 − 罚分」，两种算法不是一回事，换模型/调罚分都补不上。

结论：**原生 grammar 目前接不了这个班** —— 即使换成自训 gram 并把
`collocation/non_collocation/weak_collocation_penalty` 从 -10/-12/-24 加重到 -30/-30/-40，
仍只有 11%，而且黄金用例掉到 17/20（罚分一重就压坏了 简码/词组那几条）。
根因仍与 §4.9 一致：有 grammar 时每个词拿的是「log 权重 − 罚分」，
而重罚分又把句子推向另一种错误；加上我们的 gram 是**字符** n-gram，
octagram 学的是**词**搭配，模型与用途不匹配。

→ 想彻底去掉 Lua 重排，需要先做对两件事（都不是小改）：
   ① 给混流/全拼分别准备**与其切分粒度一致**的 gram（混流=字级、egret_py=词级）
   ② 把罚分调到不破黄金（要联合标定，类似 §4.17 的教训）

补充验证（决定性）：把用户目录里的 `zh-hans-egret.gram` 换成**空文件**后，所有长句
候选直接变成空 —— 说明这个 gram 确实在被加载和使用（空/坏文件会直接让 schema 构建失败），
§4.24 的 11% 是它的真实成绩，不是"模型没加载"。**这条路不要再试了。**

**短期可行的改良（保留 Lua 但去重）**：
- **分桶惰性加载**：按首字分桶 + 偏移索引，运行时只载入当前输入涉及的字桶，常驻降约两个数量级
- **紧凑二进制 + 二分**：不建哈希，n-gram 按字典序存 blob + 偏移数组，常驻≈文件大小(约30MB)
- 表瘦身没用：2-6gram 里 2/3 字就占 120 万条（共 190 万），砍 4-6gram 只省约 10MB

### 4.25 ⭐ LM 重排改为二进制定长包 + 二分查表（去掉 Lua 建哈希）

动机（用户）：`lm_rerank.tsv` 28.5MB/190 万行，Lua 全量读进哈希，重且不好维护。

做法：
- `scripts/gen_lm_rerank.py` 在 TSV 之后额外输出 **`lm_rerank.bin`**：
  8B magic + 6×u32 计数 + 各档**定长**记录（键 = 3L 字节，CJK 一字 3 字节；值 = u16）。
  定长记录让二分可以纯算术定位，不需要偏移索引；键按字节序排序，与 Lua 的字符串比较一致。
- `lua/lm_rerank.lua` 优先读 `.bin`，用一个**元表代理**把 `tab[k]` 变成二分查表 ——
  **打分代码一行未改**（这是把风险压到最低的关键）。找不到 .bin 时回退旧的 TSV 路径。
- 部署清单：只带 `.bin` + `.meta`（TSV 从运行文件降级为可读的调试视图，不再部署）。

实测（同样的评测口径）：
| | 旧（Lua 哈希） | 新（bin 二分） |
|---|---|---|
| 40 句 | 6/40 | **6/40（完全一致）** |
| 黄金 | 20/20 | **20/20** |
| 常驻内存 | 190 万键的哈希，量级 100~200MB+，初始化数秒 | **≈20MB**（直接查映射进来的一段字节串），初始化几乎瞬时 |
| 部署体积 | tsv 28.5MB + meta | **bin 20.2MB** + meta |

注：bin 20.2MB 比原先估的约 4MB 大 —— 键是 CJK（一字 3 字节）且条目多，键本身就占大头；
真正省下来的是**内存与初始化**，不是文件体积（文件体积只降了约 29%）。

### 4.26 调参与工程项（本轮）

- **max_homophones 7 → 15 实测无增益**：160 句 40/160（25%） vs 基线 41/160（26%），
  40 句子集同为 6/40。说明**召回瓶颈不在每个音节的同音条目数**，已回退为 7。
  → 召回（66% 正确句进不了候选）另有原因，方向上更可能是**分段候选空间**本身
  （§4.15：引擎在 prism 上枚举的路径有限），而非取几条同音字。
- **dictionary_exclude 瘦身**：删掉那份上万字的生僻字黑名单（§4.23 字表分层后
  扩展区字已不进组句词典，名单基本冗余），改为注释说明来历与遗留问题。
- **新增 `make check`**：一条命令跑完整链 —— 从 dict 阶段重建（验可复现）→ 黄金用例
  → 混流探针（连跑两次取第二次）→ 160 句评测（基线 41/160）。

### 4.27 新增四字成语词典

**现状**：我们的词表源（万象 `base.dict.yaml`）只到 3 字词 —— 实测 2 字 166,875、3 字 613,760、
**4 字 0**，常用成语（一举两得/心花怒放/画蛇添足）一个都打不出来。

**做法**：上游 `~/vmacs/rime/dicts/chengyu.dict.yaml` 有一份 cur 好的成语表
（13,127 条，已带五笔 4 码，格式 `傲岸不群 aabq`），收进本仓库 `dicts/` 作源。
`scripts/gen_chengyu_dict.py` 补上拼音码（pypinyin 逐字）与权重（语料 4-gram 频次，
无频次的给中庸值 700），产出 `egret_py_chengyu.dict.yaml`（13,116 条 / 26,232 行），
由两个 wrapper 引入，接在 refresh.sh 的 gram 阶段（权重依赖字符 4-gram 计数）。

**为什么不按语料频次筛四字串**：先试过"从 4-gram 计数取高频四字串（count>=1000）"，
选出 11,446 条，但混进大量非成语（如图所示、没有什么、为什么要、觉得自己）——
虚词黑名单挡不住，cur 好的成语表干净得多。

**拆成两份（2026-09-29 调整）**：
| 文件 | 内容 | 默认 |
|---|---|---|
| `egret_py_chengyu.dict.yaml` | 拼音码（yijuliangde 等），13,116 行 | **引入**（混合库） |
| `egret_wubi_chengyu.dict.yaml` | 五笔 4 码（yjld 等），13,116 行 | **不引入**，用户按需 |

理由：五笔 4 字码是「每字首字母」，碰撞天然多（`yjld` 可对应多个成语），
放进默认组句空间会打扰普通五笔输入；改成让用户自己决定。
开启方式：在 `egret_wubi_py.dict.yaml` 的 import_tables 里取消那行注释即可。
传统库（纯形码层）不引 chengyu —— 拼音码不该进形码层。

**实测（默认状态）**：`yijuliangde->一举两得`、`huashetianzu->画蛇添足` ✓；
`yjld->刘因`、`hutz->户投资`（走逐字组字，成语未引入，符合设计）；
黄金 20/20；混流无回归。

### 4.28 词典命名规则定稿 + 待查项

**命名规则（内容决定前缀，来源区分同族多份）**：
| 前缀 | 含义 | 例 |
|---|---|---|
| `egret_wubi_py_*` | 内容同时含五笔与拼音 | `egret_wubi_py_chars{,_common,_ext}`、`egret_wubi_py_user_phrases` |
| `egret_wubi_*` | 只含五笔 | `egret_wubi_chars*`、`egret_wubi_force_end`、`egret_wubi_chengyu`、`egret_wubi_sentence`、`egret_wubi_words_wb86_*`（86 造词码，源 `_wb86_src`）、`egret_wubi_words_wangxiang_*`（万象逗号码） |
| `egret_py_*` | 只含拼音 | `egret_py_chars`、`egret_py_words_{core,base,full}`、`egret_py_words_src`、`egret_py_chengyu` |
| 源文件 | 第三方/人工源 | `chengyu.dict.yaml` |

**万象逗号码与 schema**：`阿爸	bs,kg wq,cb` 这种码由 `algebra_wubi_py_sentence` 处理 ——
先 `xlit/;,/%@/` 把 `,`/`;` 换成 `%`/`@`（不在输入字母表里），再用 `derive` 派生
可输入形式（`bskg` 全码、`bs` 前两码…）。所以用户正常敲字母即可，不需要敲逗号。
**纠正 §4.21 的说法**：那几条逗号 derive 不是"从来没生效"，而是**只对我们的简化格式表无效**
（86 字表/词表形如 `了 b`），对万象格式表（`_wangxiang_*`）是生效的。

**待查（下轮）**：`scripts/gen_dict_tiers.py` 里 `_wb86_` 那一档的 `name:` 推导
仍会写出双重前缀（`egret_wubi_words_wb86_wb86_{tier}`），本次是就地手工修正的；
重跑生成器会再犯，需要修生成器里 name 的构造。

### 4.29 基本区「五笔码 == 拼音音节」碰撞（用户关注的 #4）

统计：基本区里**长度 2~4 的五笔码恰好等于一个拼音音节**的条目（单字母音节噪音大，先排除）。
结果见本轮运行输出 —— 这正是 `hao -> 虚` 那一类问题的规模。处理代价说明：
把这类拼写从**组句词典（混流库）**去掉后，这些字仍可用拼音打、也能在纯五笔方案
（`egret_wubi`）里打全码；但在混流方案里就不能再用五笔全码打了。

### 4.30 ⭐ 召回诊断：正确句「只要生成出来就是第一个候选」

用 `N=60 bash /tmp/recall_probe.sh`（逐句跑 console，取候选区，判断正确句是否在候选里）：

| 指标 | 数 |
|---|---|
| 样本 | 60 句 |
| 正确句是**首候选** | 12 |
| 正确句**出现在候选里**（含首候选） | **12** |
| 完全没有候选 | 0 |

**关键：两个数字相等** ⇒ 正确句只要被生成，就**已经是第一个候选**；因此在当前配置下
**不存在「生成了但排后」的情况**，80% 的句子是**根本没生成出来**。

**结论**：瓶颈 100% 在**候选生成**（分段/候选空间），不在排序。
LM 重排在它拿到的候选上已经饱和 —— 继续调排序、权重、罚分都不会有收益
（§4.24 的四格实验也是这个结论的另一面）。
能提高准确率的方向只剩「让正确句进候选」：拼写空间（§4.19 的教训）、词库覆盖（成语/整句词库
这类数据层补词条）、以及**自建统一码表搜索器**（算得对，卡在交付，§4.15）。

### 4.32 测试加固（用户建议）

这轮改名与修复中，我多次把东西改坏（旧名残留、import 指向不存在、脚本语法被改断、
`name:` 不一致、自动上屏），而**黄金用例一条都没拦住** —— 全靠事后人工审查。

**新增两类：**
1. **`scripts/check_consistency.py` + `make lint`**（秒级，不跑引擎）：
   - 三个 wrapper 的 import_tables 全部可解析
   - 每个 dict 的 `name:` 与文件名一致（librime 要求）
   - python / lua / bash 语法
   - 列出 refresh.sh 未提到的生成器（提示，需在注释说明是否有意）
   已接进 `make test`（`test: env-test lint`）。
2. **黄金用例扩容 20 → 32**，把本轮修的每个 bug 逐条钉住：
   `qktqn/qktnqnr/qktnqnrb/qchifanle`（简码拼写补进混合库）、`uwycuklf`（全码）、
   `trwuktnqnr`、`ronghe`（max_code_length）、`b,`/`ktn,`（强制结束符）、
   `ben`（字表分层）、`yijuliangde`（成语）、`owfhtc`（整句词库）。

**顺带修一处测量纪律**：`first_candidate()` 原来是**跑一次**，冷部署首跑与热机结果
不同（§4.18）→ 改为**连跑两次取第二次**，避免偶发假失败。

## 5. 待办（按依赖排序）

| # | 任务 | 依赖 | 状态 |
|---|---|---|---|
| A3 | 人民日报/古文增量抽取；新语料（Fineweb-Edu/百科/口语/法律/医疗）抽取 | 下载中（配额分批） | 🔄 |
| A4 | zhwiki 预处理（`wiki_pipeline.sh extract && publish`）+ 增量抽取 | dump 已校验 | 待 |
| B3 | 阶段 B 验收：抽样质检 + 统计账本 | 已完成 | ✅ |
| C1 | 词频统计 `freq.py` | 已实现 | ✅ 待跑 |
| C2 | 权重重归一：`reweight_words.py` 用语料词频重写词条权重 | C1 | 待 |
| C3 | 混合拼写词条（首字五笔 2 码 + 次字拼音，修 ckwan 类盲区） | C1 | 待 |
| C4 | 成语 top-N 显式入库（语料频次 ≥3/百万） | C1 | 待 |
| C5 | 语料新词入库（现词库没有但语料高频的词） | C1 | 待 |
| C6 | 拼音 full 档补全（当前拼音词只到 6.3 万；可 pypinyin 生成长尾） | C1 | 待 |
| D1 | 字符 2-6gram 全量训练 | 已完成（59MB，见 §4.10） | ✅ |
| D2 | gram 配比 AB（自有 : 维基 : 新闻） | 开源语料抽取后 | 待 |
| E1 | 评测：`eval_gram.py` 句子级 + rime-schema-compare | 首批已完成 §4.10 | 🔄 |
| **F1** | **提升全拼路径**（当前 26%）：词典权重/拼音覆盖/短语——主战场 | C2–C6 | 待 |
| **G1** | **混合输入体验**：见 `docs/research-mixed-input.md` + §4.18 机制调研 | — | 🔄 |
| G4 | 关 abbrev（用户明确不做简拼）；`z→在` 来源仍需定位 | — | 待 |
| G5 | ~~恢复 `wubi_comment` 候选码提示~~ **已完成**（§4.20，原生 reverse_lookup_filter） | — | ✅ |
| G6 | 大写输入补支持（GTNK/WQ 当前无候选） | — | 待 |
| G7 | 反查补齐（engine 无 reverse_lookup translator） | — | 待 |
| G2 | 统一码表搜索器的交付：需自建完整翻译链路（§4.15 四条路被封） | G1 | 待 |
| G3 | 整句词库扩容（更大采样/降阈值，覆盖更多高频句） | — | 待 |
| G8 | ~~字表校准/生僻字拼音接入~~ **已被 §4.23 分层方案取代** ✅（ext 层不加载 ⇒ 碰撞与挤占自然消失） | — | ✅ |
| G9 | ~~查清 𨸐 为何未被丢弃~~ 已查清：校准脚本的字符范围判断漏了扩展区（§4.22）| — | ✅ |
| G10 | 笔画反查：`dictionary: stroke` 指 rime-data/brise 的内置 stroke 词典，本仓库与 librime 构建数据都没有 → 要启用需引入 rime-data 的 stroke.dict.yaml | — | 待 |
| G11 | 词级 gram for py：gram.sh 现在是字符 2-6gram；词级需用 jieba 分词后统计（freq.py 已有 jieba），产出 zh-hans-egret-word.gram 再 A/B。librime 的 octagram 本就是词级 collocation | — | 待 |

## 6. 关键命令速查

```bash
make setup / env-test / test / test-rebuild / gen                       # 环境与回归
make refresh / refresh-list                                             # 一键刷新全部产物
make corpus-extract / corpus-dry-run / corpus-status                    # 阶段 A
make tiers / make tier TIER=core|base|full                              # 词典分档
bash scripts/corpus/fetch_open.sh [name...] / --list                    # 开源语料下载
bash scripts/corpus/wiki_pipeline.sh [download|extract|publish]         # 维基管线
bash scripts/corpus/gram.sh [--sample N|--restart]                      # gram 训练
# 阶段 B/C（务必用 venv python）
third-party/venv/bin/python scripts/corpus/clean.py --jobs 4 --nice 15
third-party/venv/bin/python scripts/corpus/freq.py --jobs 4 --nice 15
python3 scripts/rime_paths.py                                           # 路径自检
```

## 7. 踩坑与结论（避免重复踩）

| 现象 | 结论 |
|---|---|
| GitHub 直连不通 | 用 `proxychains4`（socks5 192.0.2.1:8088）；pip 用 tuna 镜像 |
| tuna 的 crates 镜像 dl 指向被墙的 `static.crates.io` | cargo 换 **ustc** 源 |
| 系统 glog 0.3.5 缺 `IsGoogleLoggingInitialized` | 自建 glog 0.6.0 到 `third-party/prefix` |
| boost 1.66 < librime 要求 1.74 | EPEL 的 `boost1.78-devel` + `-DBoost_DIR` |
| gcc8 缺 `std::filesystem` | gcc-toolset-12 + rpath（不改系统库） |
| librime tag **无 GPG 签名** | 无密码学锚 → "三通道 SHA 一致 + git 内容寻址自证" |
| 缺 `librime-lua` 整方案不可用 | 报 `error creating translator: 'lua_translator'`；插件**必需** |
| 测试目录软链仓库 `user.yaml` | console 回写污染仓库 → 改为复制（`make test` 有断言） |
| `rm -rf build` 后首次 console 候选为空 | 维护竞态（陷阱 #2）→ 先 `rime_deployer` 部署再测 |
| `mv A B` 且 B 已存在 | 会嵌套成 `B/A`（`extract/dedao`→`markdown` 踩过） |
| `du` 远大于 `ls` 大小 | XFS 预分配，非截断；判完整性用 `ls`/md5 |
| `pkill -f "cargo build"` | 会杀掉自己（含同串）→ 用 `[c]argo` bracket 或分开执行 |
| **`opencc-python-reimplemented` 慢 ~20 倍** | 纯 Python 实现；换 **C++ 绑定 `pip install OpenCC`**（1.4.2） |
| **两个 OpenCC 包共用 `opencc` 命名空间** | 同时装/卸载会互相删文件致 `ImportError`；只保留 C++ 版 |
| 去重用 `crc32`（32 位） | 5000 万行时生日碰撞误删数十万行 → 换 **blake2b 64 位** |
| 单进程清洗 8 小时 | 改分片并行 + merge 全局去重 → 1 小时 |
| **切换 gram 无效果、结果逐条相同** | **LM 静默失效**：console 运行时 shared_data_dir="."，
`default.yaml` 不在用户目录 → `default:key_binder` 失败 → schema 构建中止。已修（见 §4.9） |
| 混合拼写用例"测不出 LM 差异" | 那类用例被词库决定（传统词组置顶）；判 LM 要用**全拼长句** |
| 237MB gram 个别句子 console 卡 180s+ | 体积过大；实测 t30(59MB) 效果持平 → 用小的 |
| 改 min-count 重跑体积不变 | min-count 在**计数阶段**生效且被 checkpoint 固化；
事后调阈值用 `gram_retune.sh`（过滤聚合 TSV 重建） |
| 后台任务没死但工具报 "Command aborted" | 工具超时不会杀子进程 → 遗留进程白吃 CPU/IO（bz2 校验那次）。事后 `ps` 核一遗 |

## 8. 产物与路径

```
egret-rime/
├─ dicts/            词库源与产物（git）
├─ scripts/corpus/   语料管线（git）：extract/formats/clean/status/common/
│                    fetch_open.sh/open_sources.tsv/wiki_pipeline.sh
├─ docs/             知识库 + 本进度文档（git）
├─ third-party/      依赖源码与构建（gitignore，make setup 重建）
└─ data/             （gitignore）
   ├─ input/{ebook,dedao-*,open}/              语料投放
   ├─ corpus/{raw,extract,clean,meta,log}/     原始包/抽取/清洗/索引/日志
   ├─ gram/  rime-test/  rime-shared/
```

## 9. 决策记录

| 日期 | 决策 | 说明 |
|---|---|---|
| 09-27 | 双产物并行（词库 + gram） | 一轮出两个产物 |
| 09-27 | 语料＝自有(epub+文稿) + 维基 + 新闻 | 排除网文/社交 |
| 09-27 | 本机全包（自建 librime） | 不依赖 macOS 环境 |
| 09-27 | 产物可开源发布 | 语料来源与许可需随产物记录 |
| 09-27 | 维基用 wikiextractor 预处理 | 而非自研流式 handler |
| 09-27 | 新闻＝THUCNews + 人民日报 | 两类都拉 |
| 09-27 | 抽取不按来源写脚本 | 单一入口 + 按类型自动分派 |
| 09-27 | 可复用脚本必须 git 管理 | third-party/data 除外 |
| 09-27 | 路径一律以仓库根为基准 | 不依赖 cwd |
| 09-27 | 限流：nice 15 + ioprio BE/7 + 并发 3~4 | 避免同机负载告警 |
| 09-27 | **目标是通用输入法：词典要全、可分层、可切简繁** | 用户澄清 |
| 09-27 | 清洗白名单默认放宽到 **CJK 基本区+扩展A** | 不丢人名/地名/生僻字 |
| 09-27 | **短句转简（LM 统计集中），整段保留原字形（词库收简繁词条）** | 简繁策略 |
| 09-27 | 简繁由运行时 OpenCC + 词库阶段双向补全 | 方案已有 s2t 开关 |
| 09-27 | **gram 默认用平阈值 30（≈59MB）** | 实测与 237MB 效果持平，体积小 4 倍 |
| 09-27 | LM 评测以**全拼句子还原**为准，混合拼写用例仅作参考 | 后者被词库决定 |
| 09-27 | ⭐ **一条命令出产物是硬契约** | `bash scripts/refresh.sh` = 唯一入口；
新增语料只需加一行 `open_sources.tsv` 或丢文件到 `data/input/`，不改代码 |
| 09-27 | 并发默认 jobs=3，负载 <12 可用 6 | 所有阶段 nice 15 + ioprio BE/7 |
| 09-27 | 分片临时目录放仓库内（`data/corpus/tmp`） | `/tmp` 在根盘仅 99G，48G 分片有撞爆风险 |

### 4.31 词级 gram：放弃 jieba，改走 Rust 词典匹配

**已终止并删除** `scripts/corpus/word_seg.py` 的 jieba 分词任务（跑 10+ 小时、产出 72GB，
`data/corpus/clean/segged/` 已删，磁盘回到 74%）。理由：
1. 单进程纯 Python（jieba 约 1-2MB/s），61GB 语料要十几小时；
2. 更根本：**分词口径不对** —— jieba 用它自己的词典，而 librime octagram 学的是
   **我们自己词表条目之间**的搭配，口径不一致的 gram 用途有限；
3. 唯一用途是喂原生 grammar，而那条路已实测 11%（§4.24）。

**下轮做法（约半天）**：仓库里已有 Rust 工具，48GB 两分钟：
- `third-party/rime-corpus-processing/frequency/`（`rime-frequency`，Aho-Corasick 按词典扫语料，
  `scripts/corpus/recount.sh` 在用）
- `third-party/rime-corpus-processing/rime-gram/`（`rime-char-gram-builder`，字符 n-gram，
  `scripts/corpus/gram.sh` 的 BUILDER）
**缺的只是一件事**：按词典切分后统计**词** n-gram（不是字符、也不是词频）。
在那个 Rust 工具里加一个模式：边扫边按词典最长匹配切词、维护词窗口，
输出 word 2-6gram 计数 → 走现成的 `build_grammar` 得到 `zh-hans-egret-word.gram`，
最后只在 `egret_py` 上做 A/B（混流那边已证否）。
