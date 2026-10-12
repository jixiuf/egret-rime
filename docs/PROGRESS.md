# 项目进度与交接（活文档）

> ⭐ **先读 [`HANDOFF.md`](HANDOFF.md)**（一页纸的当前状态 / 被推翻的旧结论 / API 硬事实 / 待办），
> 再回到本文查细节。
>
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
6. **认证：`ssh-add -l` 成功 ≠ 能签名**，而且**本机根本没有能签 host-mac 的 agent**
   （2026-10-09 查清并改为**纯 agent**，下列结论都是实测）：
   - 8092 那条隧道会话（本机 sshd 子进程 `sshd: admin`，无 tty）**没带 `-A`**：本机
     没有 `/tmp/ssh-*/agent.<该 sshd pid>`。同一机器上 `-A` 本身是通的（本机 sshd
     `AllowAgentForwarding yes`；现存 `/tmp/ssh-arbsXpy5A2/agent.3279782` 就是一次带
     `-A` 的转发，只是那次的 agent 没装钥匙：“The agent has no identities.”）。
   - `/run/user/1000/gnupg/S.gpg-agent.ssh`（gpgconf 认定的标准路径）**是失效端点**：
     socket 文件在，`ssh-add -l` 报 `Connection refused`。
   - 本机那个活着的 gpg-agent（`--homedir /export/ebook/tools/gnupg`）**homedir 已被删**
     → 退到 `d.<hash>/S.gpg-agent*`，报 `agent refused operation` / `invalid format`，是空壳；
     而 Mac 侧 authorized_keys 认的是 **openpgp 钥匙**（`3072 SHA256:S/+8/2y04…`），
     只有 gpg-agent 能签 —— 它在 Mac 上，从没被转发进来。
   - `~/.ssh/config` 里 `Host host-mac` 那两条 `RemoteForward` **方向恰好反了**：
     `RemoteForward <远端 socket> <本地 socket>`，写的是「远端=/Users/...（Mac）,
     本地=/run/user/1000/...（本机）」= 把本机 agent 推给 Mac；我们要的是反向。
   - 脚本现在**纯 agent**：候选 = `$SSH_AUTH_SOCK` → `gpgconf --list-dir agent-ssh-socket`
     → `/run/user/<uid>/gnupg/S.gpg-agent.ssh` → 各 `/tmp/ssh-*/agent.*`（去重、标来源），
     每个都用**真实握手**（`ssh ... true`）判定；全失败则打印诊断 + Mac 侧修法后 exit 1。
     **不再读任何私钥文件**（用户要求：不碰 `/export/vmacs/dots/ssh/`），也不再自起 ssh-agent
     （旧版本 `eval $(ssh-agent -s)` 会泄漏常驻进程——2026-10-09 清掉 6 个）。
   - 要让它能跑，须在 Mac 上重连隧道时带上 agent：
     `export SSH_AUTH_SOCK=$(gpgconf --list-dir agent-ssh-socket)` 后
     `ssh -N -A -R 8092:localhost:22 admin@<本机>`；或反向转发 socket：
     `ssh -N -R 8092:localhost:22 -R /run/user/1000/gnupg/S.gpg-agent.ssh:<Mac 的 gpg-agent.ssh> admin@<本机>`
     （本机 sshd 已 `StreamLocalBindUnlink yes`，会顶掉失效 socket）。
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

### 4.33 部署坑：rime_deployer 重建会把「Lua 运行时读的表」移进 trash/

**现象**：`bash scripts/deploy_host-linux_direct.sh` 部署到 host-linux（Gentoo）后自检结果变形
（`今天的天气怎么仰卧`、`今天没有空`），且目标机缺 `lm_rerank.bin`。

**根因**：部署流程是「覆盖文件 → rime_deployer 重建」。**重建那一步把这几个文件移进了
`<rime>/trash/`** —— 时间戳与重建同一分钟（15:17），而它们是 **Lua 在运行时才读**的，
schema 配置里没有任何引用，deployer 清理时就当无主文件处理。
（`lm_rerank.tsv` 也一样，只是我们已经不部署它。）
=> 缺表 → dynamic_translator 把原生 grammar 关掉是指望这张表重排的 → **等于没有 LM**
   → 长句出垃圾（自检那两条就是这个症状）。

**修复**：`scripts/deploy_host-linux_direct.sh` 在 `rime_deployer --build` **之后**补回
`lm_rerank.bin` / `lm_rerank.meta`。以后任何"运行时才读、schema 不引用"的文件都要这样处理。

**目标机当前状态**：手工 scp 后 bin 已就位（15:18，重建之后，未被再移走），`fcitx5 -r` 即可测。
另注意：`~/.local/share/fcitx5/rime` 实际是软链到 `$HOME/vmacs/linux/local/share:fcitx5/rime`。

### 4.34b 部署自检的假故障：硬编码 preload librime 1.16.1

部署脚本的自检里写着 `LD_PRELOAD=/usr/lib64/librime.so.1.16.1`，而系统装的是 **1.17.0**。
按项目自己的结论：**librime < 1.17 时长句只出 1 个候选，LM 重排无从下手** ——
所以自检报「今天的天气怎么养」是**假故障**，真实运行时（1.17）结果是「怎么样」✓。
已改为自动挑系统最高版本并打印出来，找不到才回退 console 自带。

**另**：自检还必须在**带 shared data**（`/usr/share/rime-data`）的前提下跑，否则
`error building config: ...schema` + `failed to include section default:key_binder`
（§4.7 陷阱），grammar/LM 会静默失效、结果同样不可信。

**部署到 host-linux 的实际结果（用系统 1.17 + shared data 手测）**：
`ronghe->融合`、`qktnqnr->我吃饭`、`jintiandetianqizenmeyang->今天的天气怎么样`、
`wojintianmeiyoukong->我今天没有空` —— 全部正确 ✓，LM 表在 `dicts/`（20.2MB）✓。

### 4.34 ✅ 已解决：LM 表位置 + bin 加载器 off-by-one

**两个独立的 bug 叠在一起**：

**(1) fcitx 每次重启都会把 `lm_rerank.bin` 移进 trash/**
fcitx5-rime 启动时跑一遍部署，deployer 把用户目录**根下**它不认识的 `.bin` 当无主文件清理
（这张表是 Lua 运行时读的，schema 无引用关系）。缺表 ⇒ dynamic_translator 关掉原生 grammar
后没有 LM ⇒ 长句出垃圾。
**修复**：表改放 `dicts/`（deployer 视其为词典源目录，不清理）；`lm_rerank.lua` 依次找
`dicts/*.bin` → 根 `*.bin` → 旧 `*.tsv`；meta 必须取**同一位置**的（它给 total_chars，
是重排归一化基线，取错会静默回退兜底值）。

**(2) bin 加载器从引入起就是坏的（off-by-one）**
头部是 8B magic + 4B + 6×u32 计数 = 36B，Lua 里字符串是 1-based，计数应从**第 13 字节**开始，
我写成了 12 → 整个索引错位一字节 → **190 万条里 190 万条都查不到** ✗（差分测试：
TSV 哈希 vs bin 二分，逐键比对才查出来）。症状是 golden 32→29（只有 3 条依赖 LM），
极难察觉。
**修复**：`i = 13 + (L-1)*4`。修后差分测试：数值不同 0，查不到 84,033 —— 全是被有意
丢弃的「含 4 字节字符/ASCII 句界标记($)」的键，候选文本是纯汉字，永不查询，无害。
另：二分比较改用逐字节 `byte_lt`（Lua 的 `<` 走 strcoll，受 locale 影响，与文件的字节序
排序假设不一致）。

**验证**：表只在 `dicts/` → 黄金 **32/32**；表在根目录（老布局）→ 也 32/32（向后兼容）。

**(3) 部署自检本身有三处不可靠（全部修掉）**
- **硬编码 preload 了旧 librime**：`LD_PRELOAD=/usr/lib64/librime.so.1.16.1`，
  而系统是 1.17.0；librime < 1.17 时长句只出 1 个候选、LM 重排无从下手
  → 自检报「今天的天气怎么养」把人带偏很久。改为自动挑系统最高版本并打印出来。
- **一次喂多条输入**：后一条的按键落进前一条尚未提交的组字里 → 输出中途候选，
  看着像"结果错"。改为每条输入单独跑一次 console。
- **没考虑冷启动竞态**：重建后首跑不可信（§4.18）→ 改为跑两轮取第二轮。

**最终在目标机（host-linux / Gentoo, librime 1.17.0）实测**：
```
ronghe                     -> 融合] gkwg
qktnqnr                    -> 我吃饭
jintiandetianqizenmeyang   -> 今天的天气怎么样
wojintianmeiyoukong        -> 我今天没有空
```
自检：`结果: 今天的天气怎么样  我今天没有空（第 2 轮）` ✓


用户指出（关键）：**不只是部署时**，`lm_rerank.bin` 在 **fcitx 每次重启**都会被移进
`<rime>/trash/` —— 因为 fcitx5-rime 启动时会跑一次部署，而 deployer 会把用户目录根下
**它不认识的 `.bin`** 当无主文件清理（这张表是 Lua 运行时读的，schema 里没有引用关系）。

**症状**：表没了 ⇒ dynamic_translator 关掉原生 grammar 后没有 LM ⇒ 长句出垃圾
（自检「今天的天气怎么仰卧 / 今天没有空」）。

**已做（不够）**：部署脚本在 `rime_deployer --build` 之后补回（commit 7b0b0a4）。
但这挡不住"fcitx 重启触发的部署"。

**下一轮要做的（两条路，都需在真机验证）**：
1. **换位置 + Lua 多路径查找**：把表放 `dicts/`（deployer 当它是词典源、不清理），
   `lm_rerank.lua` 依次找 `dicts/lm_rerank.bin` → 根 `lm_rerank.bin` → 旧 tsv。
   *注意：我试过一版，回退顺序写错（回退成 `.tsv` 而不是根目录的 `.bin`），
   本地黄金掉到 29/32，已回滚 —— 下轮要连本地 `make test` 一起验。*
2. **改扩展名**：`.bin` 可能正是被当成构建产物的原因，换成如 `lm_rerank.pack` 试试。
3. 或者接受现状：把"重启 fcitx 后重跑一次部署脚本"写进使用说明。

**当前仓库状态**：已回滚到绿色（黄金 32/32），trash 问题未解决。

### 4.35 LM 表读端契约测试（补上"抓 bug 的工具"本身）

bin 读端的 off-by-one（§4.34）当初是靠一个写在 `/tmp` 的差分测试抓到的，但那个工具
**没进仓库** —— 等于"会抓 bug 的测试"本身没有防回归。

新增 `scripts/check_lm_table.lua`（已接进 `make lint` → `make test`）：
用 TSV 哈希作参考实现，与 bin 二分读端**逐键比对全部 190 万条**。
- **不允许数值不同**（读端 != 写端即失败）
- 允许查不到，但总量有上限（写端有意丢弃含 4 字节字符/ASCII 句界标记的键）；
  超限说明写端过滤过宽

实测：比对 1,906,397 条，数值不同 **0**，查不到 84,033（4.4%，即被有意丢弃的那批）→ 通过。
一秒内出结果，比"等黄金从 32 掉到 29"快得多。

### 4.36 lint 抓出评测工具坏了（扁平化的漏网之鱼）

补 LM 契约测试后顺手跑 160 句评测，**评测脚本直接跑不起来**：
`eval_gram.py:41` 写的是 `os.path.join(DICTS, "egret_wubi_py", "egret_py_chars.dict.yaml")`
—— **三参数拼接**，2026-09 的 `dicts/` 扁平化 sweep 只覆盖了两参数形式，漏了它。

顺带暴露 `check_consistency.py` 的两个缺陷，一并修好：
- 正则没加词边界 → `wangxiang_cn_dicts/8105.dict.yaml` 被误判成 `dicts/8105`（误报）
- 代码/注释/三引号文档串不分 → docstring 里的"输出路径"被当成引用（误报）

现在 lint 会检查**所有脚本与 wrapper 里出现的 dicts/X.dict.yaml 是否存在**，
并跳过注释与文档串。教训：**改路径类的东西，lint 要覆盖"拼接形式"**，
否则字符串 sweep 永远会漏（这轮已经因为拼接漏了 6 处）。

### 4.37 ⭐⭐ 失败归因：100% 是"字词都在、引擎选错切法"，词库不是瓶颈

新增 `scripts/diagnose_failures.py`（解析评测日志的失败行，按三类归因）。

**160 句基线更新为 43/160（27%）**（LM 修复后比原来的 41 高 2 条）。
失败 117 句归因：

| 类别 | 条数 | 占比 |
|---|---|---|
| ① 字缺失（字表里没有） | 0 | 0% |
| ② 词缺失（切不出词/只剩单字） | 0 | 0% |
| ③ **分段裁决**（字、词都在词表，引擎选了别的切法） | **117** | **100%** |

样例（都是同音词错配）：
`画上小天使们用笨拙的舞姿… → 画上小天师门用笨拙有位滋味…`、
`周勃兄弟 → 州博兄弟`、`美利坚是个吃纸大国 → 美丽件事个迟滞大国`。

**结论（对后续方向影响很大）**：
- **词库不是瓶颈**：拼音长句失败与"缺字/缺词"无关 →
  数据层补词条（成语/整句那类）只能解决"整个短语打不出来"，**对组句选错同音词无效**。
- 问题是**引擎在"生成"阶段就选了错词**（它的打分决定生成哪 ≤100 条句子，
  正确句往往不在其中）→ 而生成在 C++ 里，改不了（§4.24 已证否改引擎）。
- 因此能真正提高长句命中率的只剩：
  1. **多读法并行组句**（挂多个翻译器、给引擎不同"读法假设"，合并候选再 LM 裁决）
     —— 这是目前唯一不改引擎、又能改变"生成集合"的手段；
  2. 自建统一码表搜索器（算得对，卡在交付 §4.15）。

### 4.38 否定结论：同音词选错**不是字权重问题**

顺着 §4.37（100% 失败是同音词错配）试了"按语料频率重标字表权重"
（`scripts/reweight_chars_by_corpus.py`，只改字表内部次序、映射回原值域）：

```
使 631 -> 850   师 183 -> 828     ← 次序与原来一致
勃 114 -> 675   博 165 -> 757     ← 一致
利 169 -> 851   丽 141 -> 751     ← 一致
```

**万象的字权重与我们的语料次序本来就一致** → 重标不改变同音字的相对次序，
同一个错配还会发生。而且该映射把所有字压进高带（675~918），会破坏"词高于字"
的层间平衡（§4.17 四次失败的原因）→ **不做，产物已删**。

**由此得到的战略结论**：长句命中率（27%）的天花板来自**引擎生成阶段的路径打分**
（C++，改不了）——字权重、词权重、拼写空间、max_homophones、原生 grammar 都已验证过
不是杠杆。剩下的只有两条：
1. **自建统一码表搜索器**（算得对，卡在交付 → 需要自建完整翻译链路）；
2. 接受现状，把精力放在**别的场景**（混流短码、成语、简码、体验层纠错/学习）。

### 4.39 ⭐ 修好拼音侧的用户词典自学习（原为只读 tabledb）

> ⚠️ **2026-10 更正（见 §4.48）**：本条把根因写成“tabledb 只读”是**错的** ——
> 只读的是 `stabledb`；`tabledb` 走 `TextDb::Open()`，可写，调频/自学习实测生效。
> 当时观测到的“选第 3 候选后再打次序不变”未能复现，根因登记有误。
> 本条的**处置结果**（独立名 `egret_wubi_py_script.user.dict`）仍然保留。

**问题**：schema 里混合库（script 翻译器）写的是 `db_class: tabledb`，当时认为 **tabledb 只读**
（注释却写着"拼音侧自学习调频"）；且它的 `user_dict` 与 `custom_phrase` **同名**，
db_pool 共享后实际类由先创建的 tabledb 决定。

**实测（修前）**：打 `nihaoma` 有「你好吗/你好/你号码/你」，选第 3 个（你号码）后再打，
次序**完全不变** ✗（后于 §4.48 未能复现）。
**实测（修后）**：
```
按 3 选中「你号码」-> commit: 你号码
再打 nihaoma -> 1.[你号码] 2.你好 3.你 4.尼     ← 从第 3 位升到第 1
userdb 写入 egret_wubi_py_script.user.dict.userdb（新 .ldb）
```
**修复**：混合库改 `db_class: userdb` + 换独立名 `egret_wubi_py_script.user.dict`
（避免与 custom_phrase 共库）；黄金测试的 USERDB_DIRS 同步补上这个目录，
避免学习状态泄漏进回归。
**价值**：这是"越用越顺手"的基础，之前拼音侧一直没生效。

### 4.48 ⭐⭐ 用户词典全部改用 tabledb + 更正「tabledb 只读」

**缘起**：用户要求「use tabledb」。先做实控验证（`data/rime-test`，librime 1.17.0）。

**实测（先破谣）**：把混合库 translator 改成 `tabledb` 后，
- 清库后打 `nihaoma` → 选第 3（你好嘛）+ 回车 → **新进程**重打 → `1.[你好嘛]` ✓（从第 3 升首位）
- **同进程**内选完再打也升位 ✓；甚至**同名共库**（tabledb + `egret_wubi_py.user.dict`）也一样生效 ✓
- 传统库 `tabledb`：`tffu` 选第 2（徒增）→ 重打升首位 ✓；
  两段组句造词（`trwu` 我们 + `gdrn` 天气 + 回车）→ 写出
  `我们天气\t^?enc^_qwgr\t0` 到 `egret_wubi.user.dict.txt` ✓

**结论**：`tabledb` **可写**（`text_db.cc TextDb::Open` 置 `readonly_=false`，
`Update/Erase/MetaUpdate` 仅看 `readonly()`，`Close()` 会 `SaveToFile()`）；
真只读的只有 `stabledb`（`table_db.h StableDb::Open() → TableDb::OpenReadOnly()`）。
§4.39 的「只读」是把社区 custom_phrase 配方的 `stabledb` 混成了 `tabledb`。

**决策**：三个 user_dict 全部 `tabledb`（用户指令 + 纯文本/可 git/可直改的优点）：

| 块 | user_dict | 落点 |
|---|---|---|
| `egret_wubi`（传统库，造词/调频） | `egret_wubi.user.dict` | `<用户目录>/egret_wubi.user.dict.txt` |
| `translator`（script，自学习） | `egret_wubi_py_script.user.dict` | `<用户目录>/egret_wubi_py_script.user.dict.txt` |
| `custom_phrase`（人工短语表） | `egret_wubi_py.user.dict` | `<用户目录>/egret_wubi_py.user.dict.txt` |

**已知代价（接受）**：
1. 同名共库时学习条目会写进人工库（实测被追加 `你好嘛`/`好嘛`/`你`）→ 故 translator
   继续用**独立名**；`custom_phrase` 的 txt 保持人工内容（回归 `--clean` **不清**它）。
2. `TextDb::Close()` **全量重写**整张表；无事务/无 `.old` 备份/无 `userdb_recovery_task`。
3. `rime_dict_manager` 快照/导出按 userdb 布局工作，tabledb 不再适用；
   旧的 `build/*.userdb/` 目录切换后不再被读取，可删（或先导出）。
4. 副作用：名字不同 → db 实例不共享，script 组句看不到其它 translator 的学习条目
   （§7 里靠同名共享让 `ckwan` 出「台湾」的那条路不再成立）。

**验证**：`make lint` ✓；`python3 scripts/regression_test.py --clean --rebuild` → **黄金 33/33** ✓；
`rime_deployer --build` 重跑后三个 `*.user.dict.txt` 仍在（只把未知 `.bin` 移进 `trash/`）✓。
工具同步：`scripts/regression_test.py` 的 `USERDICT_PATHS`（含旧 userdb 路径兼容）、
`Makefile clean-test`；文档更正见 dict-reference.md §3/§6/§7、deployment-debugging.md #4/#5、
HANDOFF.md §4 表、librime-source-map.md、schema-config-reference.md。

**追加修复（同日，用户反馈“`egret_wubi_py.userdb` / `egret_wubi.userdb` 还是会产生”）**：
根因在**两个多读法路由块**——`wubi_route` / `py_route` 没写 `user_dict`，
`UserDictionaryComponent::Create(ticket)` 会按 `dictionary` 名派生
（`Language::get_language_component` → `egret_wubi` / `egret_wubi_py`），而
`enable_user_dict` **默认 true**，且**建组件（即加载方案）时就把 LevelDB 目录建出来**
（与是否触发 tag 无关，所以每次启动都会重建）。
处置（用户选“复用主词典”）：两块补 `db_class: tabledb` + 复用主翻译器的 user_dict
（`egret_wubi.user.dict` / `egret_wubi_py_script.user.dict`）——同名 → db_pool 共享，
学习互通、零新增文件（语义也一致：py_route 与 translator 同为 script_translator + 同 prism；
wubi_route 与 egret_wubi 同为 table_translator + 同 dictionary）。
实测：连跑两轮不再产生 `*.userdb` ✓；黄金 **33/33** ✓；三条学习链路
（自学习/调频/造词）仍全部生效 ✓。曾试过的另一种做法是两块 `enable_user_dict: false`
（也 33/33、也不建目录），但那样路由不参与学习；二选一已问过用户，选了复用。

### 4.40 ⭐⭐ 交付路线其实通的！§4.15 的"新增候选会被中途提交"是误判

**重新验证**（这是本轮最重要的发现）：
`Candidate` 是 librime-lua **注入的全局**（在 filter 里可用；我早先拿独立 lua 跑、看到它是 nil，
误以为不可用）。用它新造候选：
```lua
local nc = Candidate("sentence", c0.start, c0._end, composed, "")   -- 构造出来是 SimpleCandidate
table.insert(cands, 1, nc)
yield(nc)
```
**实测有效**：`gdrnthtcsu`（引擎只给「天气怎么素/天气自私素…」）
→ 注入后首候选变成 **天气怎么样** ✓✓✓，且**没有**出现 §4.15 说的"输入中途提交/截断"。

→ **§4.15 那四条"封死"的路径里，至少 filter 注入这条是通的**；
   当时的"中途提交"很可能是构造函数用错（或与 auto_select/max_code_length 混淆，后者已于 §4.32 修掉）。

**但当前仍默认关闭**（`lm_compose: false`），原因是**搜索器准确率只有 ~26%**：
- 无条件注入会压掉引擎本来正确的答案（实测黄金 32→30）：
  `wojintianmeiyoukong` 搜索器给「我今天没有中断一」、`yijuliangde` 给「依据量的」、`tgtj` 给「重复」；
- 想用"同一把 LM 打分"做闸门也不行：实测这个平均分**分辨不出**错案
  （「我今天没有中断一」反而分更高）；
- 而且 §4.30 已证明：**正确句只要被引擎生成出来就已是首候选** → 单纯的"重排"永不带来收益，
  只会偶尔把搜索器算错的句子顶上去（`tgtj→重复` 就是这么来的）。

**结论**：交付机制**已就绪**（`lm_compose: true` + `lm_compose_inject: true` 可开），
剩下的唯一障碍是**搜索器本身的准确率**（26%）。把搜索器准确率提上来（模型/码表/beam），
这条通路就能直接变成收益。这是目前最有价值的方向。

### 4.41 ⭐⭐ 混流多读法落地：用「整段补 tag」让五笔读法在整句中胜出（默认开启）

**先纠一个结构性误解**（本轮踩出来的）：rime 里**段就是「组字/上屏的单位」**，
段与段是**顺序确认**的，**不会合并成一句话** → 所以"把输入切成多段"必然碎句
（实测 `nihaoma -> 吗`、`trwuchifan -> 我们`）。同理 `seg:forward()` 会把前面的段
标记为已确认（候选只剩最后一段），**切段这条路本身是错的** ✗。

**正确的用法**：不切段，只**给整段补一个 tag** —— `add_segment` 对**等长**段是
**tags 取并集**（`segmentation.cc:98-107`），所以：

```lua
local ns = Segment(s, e)                 -- 与 abc 段等长
ns.tags = { ["wubi"] = true }            -- 必须 set 形式
seg:add_segment(ns)                      -- → tags = {abc, wubi}
```
再由**绑定该 tag 的内建 translator** 处理：
```yaml
wubi_route:
  tag: wubi
  dictionary: egret_wubi       # 传统 86 库（会按五笔读法组句）
  enable_sentence: true
  enable_completion: true
  initial_quality: 1000        # ★ 关键：高于混合库(1)
```
**机制（两处独立因果验证）**：`LuaSegmentor` 用我们的统一码表搜索器（`py_composer`，
现在会返回**每段的读法 kind**：五笔/拼音）判断"整串是五笔读法" → 补 tag →
`wubi_route` 用 86 库组出五笔读法 → 其 `initial_quality: 1000` 压过混合库(1) → 胜出。
- 验证 A：**移除** `wubi_route` → `gdrnthtcsu` 回落 `天气怎么素` ✗
- 验证 B：把它的 `initial_quality` 降到 1 → 同样回落 ✗
（即 §4.18 记的那条质量差，现在被刻意利用。）

**实测（全部指标，开/关对照）**：
| 指标 | 关 | 开 |
|---|---|---|
| 黄金 make test | 32/32 | **32/32** |
| 黄金 评测子集 | 20/20 | 20/20 |
| 混合拼写 20 条 | 6/20 | 6/20 |
| 整句 160 条 | 43/160 | 43/160 |
| `gdrnthtcsu` | 天气怎么素 | **天气怎么样** ✓ |
| 每次 console 耗时 | 3.641s | 3.670s |

**纯收益、零回归**，故默认开启（`mix_segmentor.enabled: true`）。

**踩过的坑（都验证过，别再犯）**：
1. 段**必须互不重叠且顺序推进**；`forward()` = 确认段，不能用来"拼段"；
2. 段的 `tags` 必须 **set 形式**（`{[tag]=true}`；数组会 lua 报错）；
3. 内建 table/script translator **只认 abc** → 自定义 tag 的段必须**同时带 abc**，
   否则原有链路（拼音组句等）被跳过；
4. `lua_translator` **完全不支持 tag 配置**（`lua_gears.h:65`），必须在 lua 里
   `seg:has_tag()` 自检；
5. `lua_segmentor` 必须排在 `abc_segmentor` 之后、`fallback_segmentor` **之前**
   （fallback 会终止分段链）；
6. rime 的 **translation 是单次迭代流**：filter 里 `input:iter()` 只能遍历一遍，
   否则候选全丢（曾导致方案 0 候选）。

### 4.42 码表二进制包 + 对称读法标签 + 长句三态验证

**(1) 统一码表改二进制包**（`gen_compose_table.py` 输出 `compose_table.bin`，4.7MB）：
偏移索引 + 变长记录（按 code 升序）→ Lua 侧二分查前缀；`py_composer` 用**元表代理**
接住 `by_key[key]`，搜索器循环代码一行未改；优先读 `dicts/compose_table.bin`（同
lm_rerank 的教训：根下的 .bin 会被 deployer 清进 trash）。
**契约测试 `scripts/check_compose_table.lua`**（已进 `make lint`）：TSV 参考实现 vs
包读端，逐前缀比对全部 **270,186 条 → 不一致 0** ✓。
**它当场抓到两个 bug**：① 我把桶语义写成了真前缀（`b` 返回 7585 条 vs 参考 1 条）；
② `A and B or C` 优先级导致兜底分支恒定生效（过滤失效）。
另修 `write_pack` 里的 O(n²) 偏移累加（改成滚动偏移，否则 27 万条卡死）。

**(2) 读法标签对称化**：切分器现在按搜索器判定的读法补 tag —— 整串五笔 → `wubi`，
整串拼音 → `py`；各绑一个 `initial_quality: 1000` 的内建 translator
（`table_translator@wubi_route` / `script_translator@py_route`）。

**(3) 长句三态验证**（`scripts/probe_long_sentences.py`，同一批 8 句 A/B）：
| 类别 | 切分器 OFF | ON |
|---|---|---|
| 纯拼音 | 0/8 | 0/8 |
| 纯五笔 | 1/8 | **2/8** |
| 混打 | 0/8 | 0/8 |
样本是 eval 集前 8 句（epub 子集，最难的一批，对应整句评测里 ~15% 的那一档）。
**失败样例全是近音错字**（`花上小天师门` vs `画上小天使们`）→ 与 §4.37 一致：
长句主导错误是**同音/近音字选择**，不是拼写或词库缺失。要再进一步得靠
**词级 LM**（我们搜索器现在只有词的一元 + 字符级上下文增益）。

**接入**：`refresh.sh` gram 阶段现在会跑 `gen_compose_table.py`（此前未接入）；
`make lint` 加码表契约测试；部署清单与"重建后补回"列表都带上 `compose_table.bin`。

### 4.43 词级 LM 调研：证据在表里，问题在**打分的混合方式**

**先验证现状**（不猜）：搜索器 `py_composer` 的打分是
```lua
sc = path.score + (w.weight - LOG_N) + lm.score_segment(path.ctx, w.text)
--   ↑ 词的一元 LM(log P(w))         ↑ 字符级上下文增益（PMI 形式）
```
而 `lm_rerank` 里其实**已有句级打分 `M.score(text)`**（就是评测出 26% 的那个）——搜索器没用它。

**把上下文增益从 4-gram 提到 6-gram**（用满表里的阶数）：已改、黄金 33/33 不变，
但长句三态探针**结果不变** ✗（0/8、2/8、0/8）→ 说明这些错不由 5/6-gram 决定。

**于是直接查表验证（关键）**：
| 对照 | 语料统计 |
|---|---|
| 画上 8642 vs 花上 8025 | **偏好期望** ✓ |
| 周勃 7751 vs 周波 **表里无** | 错误读法缺失 ✓ |
| 天使们 5451 vs 天师门 **表里无** | ✓ |
| 有卫星 5525 vs 尤为行 **表里无** | ✓ |
| 杰克森 8546 vs 皆可森 **表里无** | ✓ |

→ **搜索器手里有足够证据选对**（错误读法基本不在表里，本该吃 `MISS_PENALTY`），
**却选了错的** ⇒ 问题在**打分的混合方式**，不是"缺词级模型"。

**已定位的具体缺陷**（`lm_rerank.score_segment`）：
上下文增益要求 `tab[tail..ch]` 与 `tab[tail]` **同时存在**才计入；
而表是按频次 top-K 截断的 → 大量情况下增益直接为 **0** → 决策退化成
"词的一元"（画 vs 花 谁更常见）→ 近音错字。

**下一步（有界实验，按性价比）**：
1. 让增益在 `tab[tail]` 缺失时**退回低阶**（而不是整条丢弃）——改 `score_segment`；
2. 或直接在 beam 里用 `M.score(text)`（已验证的句级打分）替代当前混合；
3. 真要"词级 LM"（词 bigram）需要**词共现数据**，那要对语料做一遍**按词典切分**的统计
   （就是之前放弃的 Rust 路线，见 §4.31）——成本高，先做 1/2。

### 4.44 ⭐⭐⭐ 词级 gram（万象 LMDG）**推翻 §4.24**，成为默认 LM

**用户建议**：「用万象的词 gram 试效果」。实测结果决定性：

| 配置（同一批 40 句 epub 子集） | 完全命中 | 峰值 RSS |
|---|---|---|
| 字级 Lua 重排（`lm_rerank`，原默认） | 4/40 (10%) | 141 MB |
| **万象词级 gram（400MB，原生 grammar）** | **14/40 (35%)** | **128 MB** |

**2.5 倍提升，且更省内存、整层去掉 Lua 重排。**

**这一条推翻了 §4.24 的结论**：当时我判定"原生 grammar 接不了班"（11%），
其实**是模型问题**（essay / 字级），不是引擎或罚分问题 —— 换成**词级现代语料模型**后
原生 grammar 直接给出 35%。

**混打不受影响**（用户特别问的）：两种模式下逐条一致 ——
`wqhao -> 你好`、`wqhaoma -> 你好吗`、`trwuchifan -> 我们吃饭`、`qchifanle -> 我吃饭了`、
`qktnqnr -> 我吃饭`、`gdrnthtcsu -> 天气怎么样`。原因：混打由**词库/组句**解决，
grammar 只负责重排；正确候选本来就在。

**已改为默认**：
- `egret.common.yaml: grammar/language = wanxiang-lts-zh-hans`（词级模型，来源 amzxyz/RIME-LMDG，
  见 docs/reference-projects.md）
- `egret_wubi_py.schema.yaml: dynamic_translator/lm_rerank = false`（引擎 LM 交给原生 grammar）
- Lua 的 `lm_rerank` 表**只为搜索器/切分器内部打分保留**（切分器 init 里显式 `lm.load`）
- 部署清单：`wanxiang-lts-zh-hans.gram` 列为**必需**运行时文件；部署脚本"重建后补回"也带上它

**160 句完整评测（闭环确认）**：
| 配置 | 黄金 | 句子(全拼) 160 句 |
|---|---|---|
| `lm_rerank`（字级 Lua 重排，原默认） | 19/20 | **43/160 (27%)** |
| **万象词级 gram（原生 grammar，新默认）** | **20/20** | **66/160 (41%)** |
→ **相对提升 +53%**，黄金满过。

**评测提速**：400MB gram 在测试环境每个用例都要重新加载 → 串行跑 160 句要几十分钟。
已给 `eval_gram.py` 加 `--jobs N`（默认 6）：**每个用例仍是一个独立 console 进程**
（语义不变），只是并行执行 → 几分钟出结果。40 句串行/并行结果一致（14/40），交叉验证过。

### 4.45 「lm_rerank.bin/.meta 还用不用」——用实验回答：**仍必需**（且暴露了可修缺陷）

用户质疑我前后说法矛盾（"引擎侧不用了" vs "仍然需要"）。用实验验证：

**① 移除文件测试**（把 bin/meta/tsv 从 `dicts/` 与根目录都移走）：`gdrnthtcsu`、
`jintiandetianqizenmeyang` 结果**都不变** ✗ —— 但这**不能证明未被使用**，只说明这两个
输入的裁决不受它影响。

**② 代码路径探针**（`scripts/check_lm_signal.lua`）：
```
lm.load  -> 已载入 1,822,364 条 n-gram       # 表确实加载（走 .bin）
score_segment(ctx=画, text=上) = 1049.6      # 强信号，偏"画上"
score_segment(ctx=花, text=上) =   80.6      # 13 倍差距
score_segment(ctx=周, text=勃) = 4400.6
score_segment(ctx=周, text=波) =    0.0      # 错误读法直接 0
```
⇒ **表被 `mix_segmentor`（默认开）的搜索器打分实际使用** ✓。
「引擎侧不用了」指的是**引擎的 LM 通路**（dynamic_translator 重排 + compose_filter 都已关），
搜索器是另一个使用者 —— 两者不矛盾。

**③ 顺带发现可修缺陷**：搜索器打分 = 词一元(权重差) + 上下文增益；
上面的增益有 13 倍差距，但**词一元项量级更大**，会把正确信号压过去（§4.43 诊断的混合失衡）。
而**句级打分 `M.score` 已经判对**：
```
score('画上小天使们') = -30646    score('花上小天师门') = -35748   # 差 5102 分
```
⇒ 把搜索器 beam 的打分换成 `M.score`（§4.43 的选项 2）应能直接修掉这类近音错字。

### 4.46 部署漏文件根治：py_meta.txt + 「运行时文件 vs 部署清单」自动检查

**用户报的错**（真实部署机上）：
```
Lua Compoment of initialize error: (module: *mix_segmentor ...):
mix_segmentor.lua:30: bad argument #1 to 'lines' (py_meta.txt: 没有那个文件或目录)
```
根因：搜索器要读 `py_meta.txt`（`total_tokens` → 一元归一化常数 `LOG_N`），
但**它不在部署清单里** ✗。本地 `make env-test` 会带上它，所以**只有真实部署才暴露**。

**修了三层**：
1. **代码健壮化**（`mix_segmentor.lua` / `compose_filter.lua`）：抽一个
   `read_py_total(dir)`，先找 `dicts/py_meta.txt` 再找根目录，**缺文件不再抛错**
   （回退默认 `LOG_N`）。实测：删掉该文件后 segmentor 正常初始化、`gdrnthtcsu`
   仍出「天气怎么样」；恢复后黄金 33/33。
2. **清单补上**：`deploy_bundle.sh` 加 `data/gram/py_meta.txt|dicts/py_meta.txt`；
   部署脚本"重建后补回"列表也加它。（放 `dicts/` 同前两个，免得被 deployer 清进 trash。）
3. **根治**：`check_consistency.py` 新增检查 —— **lua 运行时读的数据文件
   （*.txt/*.meta/*.bin）必须在 `deploy_bundle.sh --list` 里**。
   这类漏文件已犯三次（lm_rerank.bin / compose_table.bin / py_meta.txt），
   本地环境测不出来，必须自动拦。**正反两向都验证过**：
   - 正向：当前清单 ✓ 通过
   - 反向：临时删掉 py_meta.txt 那行 → lint 报 4 处错误 ✓

**顺带修掉**：`deploy_bundle.sh --list` 里残留的 `WITH_GRAM: 未绑定的变量`（我早前改清单时的残线）。

### 4.47 删掉冗余的 charset_filter（它一直是 no-op，还每次按键刷 ERROR）

**用户报**：每输入一个字符就刷
`charset_filter.cc:108] charset parameter is unsupported by basic charset_filter`。

**源码看穿**（`charset_filter.cc:103-110`）：
```cpp
if (name_space_.empty() && !context()->get_option("extended_charset"))
    return New<CharsetFilterTranslation>(...);          // 真正过滤
if (!name_space_.empty())
    LOG(ERROR) << "charset parameter is unsupported..."; // 噪声
return translation;                                      // 不过滤！
```
即：**只要这次引用带 namespace（librime 给组件默认都带），它既不生效、还每次按键打一条 ERROR**。
实测本机同样 7 次/句 → 说明它**一直是 no-op** ✗（此前 §4.23 记的"靠它隐藏 CJK 扩展字"
其实不对 —— 真正起作用的是**字表分层**：扩展区字根本不在默认 prism 里）。

**处置**：删掉 `egret_wubi_py.schema.yaml` 里的 `charset_filter`（并在原位留注释说明原因）。
实测：日志 **7 → 0**、黄金 33/33、各用例不变。

### 4.49 ⭐⭐ H1（搜索器 beam 改用 `M.score`）**证否** —— 而且暴露出「搜索器根本不在决策路径上」

**背景**：§4.43/§4.45 提出「把搜索器 `py_composer` 的打分从『词一元 + 上下文增益』换成
句级 `lm_rerank.score`」（待办 H1），理由是句级打分能判对「画上小天使们 > 花上小天师门」。
改动很小（`docs/experiments/h1-mscore-in-beam.patch` 存档），实测结果：

| 配置 | 黄金 20 | 160 句全拼 | 首候选 None（120s 超时） | 整轮耗时 |
|---|---|---|---|---|
| 基线（HEAD 打分） | 20/20 | **65/160 (41%)** | 3 | ~15 min |
| **H1（`M.score` 进 beam）** | 20/20 | **52/160 (32%)** | **50** | ~34 min |

逐句比对：**变好 0 句，变差 13 句，且 13 句全部是 `None`（超时）**。

**① 关键事实（读代码 + 开关确认）：生产配置里 `py_composer.compose` 只有一个消费者**

| 调用点 | 开关 | 现值 |
|---|---|---|
| `compose_filter.lua`（注入/共识重排候选） | `dynamic_translator/lm_compose` | **false** |
| `dynamic_translator.lua`（翻译器侧置顶） | `dynamic_translator/lm_compose_translator` | **false** |
| **`mix_segmentor.lua`（给整段补 `wubi`/`py` tag）** | `mix_segmentor/enabled` | **true** |

⇒ 搜索器的唯一产出是**一个 tag**，它的 beam 打分只影响「整串算五笔还是拼音」，**不进候选排名**。

**② 量化这条链路的贡献（关掉 `mix_segmentor`，其余不变）**：160 句 **64/160** vs 开启 **65/160**
—— 即整条「码表搜索器 + LM 打分 + tag 路由」对**全拼长句**评测的贡献 ≈ **1 句**（黄金都是 20/20）。

**②' 但它不是废件（差点误判）**：同样关掉 `mix_segmentor` 跑**黄金 33** →
`qktqn`（五笔短码序列→我吃饭）**直接 120s 超时爆炸**（保到第 20 条就断）。
⇒ 这条链路的价值在**混流短码序列**（§4.41 的 tag 机制），全拼长句评测测不到它；
「全拼评测≈0 贡献」**不支持**“删掉它”这个结论。
（另：首次跑出现 `wan` 超时，是陷阱 #2/#9 部署竞态，预热后重跑正常。）

**③ 单例验证（决定性）**：取 5 句在 H1 下「失败」的输入（如 `duzhemenyijing...lexingqu`、
`bujinkexuemiaoshu...`），**H1 与基线的 tag 判定完全相同（都是「整串 py，补 py tag」）、
首候选也完全相同且正确**。差别只在耗时：

| 每键（compose 一次） | 基线 | H1 |
|---|---|---|
| 均值 | 1091 ms | 3214 ms |
| 末键（52 字母） | 2.3 s | 9.0 s |

**结论**：
1. **H1 是纯延迟回归、零质量收益** —— 它连「变好一句」都没有；评测掉 13 句是**超时假失败**
   （判 failure 前必须区分 `None`=超时 与 真错，这是评测口径的坑）。
2. **H1 的前提不成立**：搜索器不在最终决策路径上，所以「给它换个更好的打分」不可能修长句错误。
   长句的最终裁决在 `py_route`(script_translator) 的整句候选 + 万象 grammar 那一侧。
3. 顺带记两个数字：`M.score` 在 beam 里是 O(位置×候选词×串长) 次全文 n-gram 扫描，
   成本随输入长度迅速爆炸；而基线搜索器本身也不便宜（长输入 1~2 s/键）。

### 4.50 ⭐⭐ H7：搜索器 beam 增量缓存（判定逐字节不变，单例快 2.6~5×）

**背景**：§4.49 证否 H1（换打分＝零收益＋纯延迟）后，H7 的目标改为**不改判定、只降成本**。
根因先在微基准里定位：`mix_segmentor` 对**每个前缀**都调一次 `compose`（52 字母输入 = 52 次全量 beam），
而 beam 在每个位置×每条路径都要把 `by_key[2字前缀]` 桶（平均 **406** 条、最多 4766 条）全扫一遍
——52 字母输入光搜索器就 **52 s**（每键约 1 s）。

**做法（两项，都在 `lua/py_composer.lua`）**：
1. **beam 状态增量缓存**：位置 p 的状态只由输入前 p 个字符决定、不随后续输入改变；
   输入只增长时只需补算新增位置。
   ⚠ 关键细节：候选是按当前位置的 1~2 字前缀查的（`k2 = input[pos+1..pos+2]`），
   而**旧输入末尾的 k2 是被截断的**（少查一个桶）→ 老位置里只有
   `[base+1-MAX_CODE_LEN, base-1]` 这一段会向新位置产出候选 ⇒ 回扫这段窗口、只补 `epos > base`。
   （第一版写成「回退一格重算」+清空后续格子，结果丢了老位置对新格子的贡献，`qktqn` 就能复现错判。）
2. **LM 增益记忆化**：`score_segment(ctx, text)` 是整个搜索器 ~80% 的开销（bin 表逐次二分），
   而回扫窗口的 (上下文,词) 组合在相邻按键间高度重复 ⇒ 按 `ctx.."\1"..text` 缓存。
3. **契约测试**（`scripts/check_compose_table.lua`）：码表最长码 ≤ `MAX_CODE_LEN`（现 15 ≤ 16）。
   回扫窗口宽是个**隐式上界**，错过就是静默错判 —— 必须自动拦。

**实测**：

| 场景 | HEAD | H7 后 |
|---|---|---|
| console 单例 32 字母 | 14.3 s | **5.5 s**（2.6×） |
| console 单例 52 字母 | 60 s | **11.9 s**（5×） |
| `compose` 微基准（21 输入×全前缀 371 个结果）| 196 s | **34 s**（6×，长输入单例 ~7×）|
| 160 句评测墙钟 | ~20 min | **~7 min** |

**验证**：
- **等价性（决定性）**：把 HEAD 版与新版并排加载，22 个输入 × 全部前缀 = **410 个前缀结果
  逐字节相同**（文本 / 分数 / 分段边界 / 读法）；另有 371 个前缀的「增量 vs 每次重置」对比也是 **0 差异**。
- **黄金 33/33** ✓（`--clean` 与不 clean 各一次）；`make lint` / 码表契约 ✓。
- **160 句：64、65（基线 66）** —— 差异 1~2 句**全是 120 s 超时**，与 §4.49 同理属评测噪声（compose 输出已证等价）。

**被否的更强优化（记录以免重走）**：用「**精确码二分**」替掉 by_key 前缀桶
（微基准再快 ~3×，合计 ~20×）—— 但会**触发 librime-lua 关闭期 full GC 死循环**：
```
gdb bt: main → RimeFinalize → Registry::Clear → ~LuaComponent<LuaTranslator>
        → Lua::~Lua → luaC_fullgc → singlestep   （100% CPU，RSS 恒定 111MB，永不退出）
```
可复现 **3/3**（同一输入：HEAD 14.3s / 仅增量缓存 5.5s / 缓存+精确枚举 **挂死**）。已回退。
（疑似 librime-lua 的 `LuaTranslation` 析构里回调 `lua_gc` 的已知脆弱点，与活跃对象数相关；未深究。）

**顺带踩到的坑**：`timeout` 发的 **SIGTERM 杀不掉卡住的 console**（实测残留进程 100% CPU 跑十几分钟），
直接污染后续评测 —— 评测前先 `pkill -9 -f '[r]ime_api_console'`（用 `[r]` 避免 pkill 杀掉自己，见 §7）。

**还能再快多少？（本轮试过、都被同一个 bug 卡住）**

| 变体 | 52 字母单例 | 32 字母单例 | 结果 |
|---|---|---|---|
| 已落地（缓存 + LM 记忆化） | 11.9 s | 5.5 s | ✅ 稳定 |
| + **前缀桶记忆化**（`by_key` 不再每次重建 406 条） | **7.7 s** | **挂死**（3/3） | ❌ |
| + 精确码二分枚举 | （未测全） | **挂死**（3/3） | ❌ |
| 上面 + 每键 `collectgarbage("step")` | 7.9 s | 3.3 s **但 2 次里挂 1 次** | ❌ 不可靠 |

⇒ **下一个 1.5~3× 全部卡在同一个 librime-lua 关闭期 GC 死锁上**（上面的 gdb 栈）；
它还是**概率性**的（加 GC step 后同输入 1/2 成功），说明是 GC 状态相关的活锁，不是确定性死循环。
变体已归档 `docs/experiments/h7-bucket-memo-pending-pin-bump.patch`。
**这是目前性价比最高的后续项**：拆掉它就能把搜索器再降一档（估计总共 10~20×）。

（另：`lua_segmentor` 没有 `fini` 钩子（`lua_segmentor.cc` 无 fini），所以"关闭前清缓存"这条捷径走不通。）

### 4.51 ⭐⭐⭐ H9 破案：关闭期 GC 活锁的根因是 `lua_gears.cc` 里「每 256 次析构做一次全量 GC」

§4.50 里所有更快变体都被同一个现象挡住：console 打印完候选后**不退出**（一个核 100%、RSS 恒定、
`timeout` 的 SIGTERM 也杀不掉）。本轮用 gdb 拓到根因，并修到了**上游**。

**根因（`librime-lua`，上下游 master 仍在）**：
```cpp
// src/lua_gears.cc
LuaTranslation::~LuaTranslation() {
  static std::atomic<unsigned int> counter {0};
  int c = counter.fetch_add(1, std::memory_order_relaxed);
  if (c % 256 == 0) lua_->gc();          // ← 全量 GC
  else               lua_->gc_step(32);
}
```
若这次析构发生在 **Lua 状态关闭过程中**（`Lua::~Lua` → `lua_close` → `luaC_freeallobjects` → 终结器），
GC 本已正在跑 ⇒ `lua_gc(LUA_GCCOLLECT)` 是对它的**重入**调用 ⇒ Lua 5.3 的 GC 状态机活锁。
计数器是**进程级全局**的 ⇒ 是否命中取决于「本次会话一共销毁了多少个 LuaTranslation」
—— 这就是它看起来"随机"、且**改代码快慢就会碰到/碰不到**的原因（也是为什么 §4.50 里
同一种改动有时好有时挂）。

gdb 栈与之一一对应：
```
singlestep ← luaC_fullgc ← lua_gc ← ~LuaTranslation(_M_dispose)
  ← LuaType<shared_ptr<Translation>>::gc ← GCTM ← luaC_freeallobjects ← close_state
  ← Lua::~Lua ← ~LuaComponent<LuaTranslator> ← Registry::Clear ← RimeFinalize ← main
```

**修法（12 行，无行为改变）**：`Lua` 加 `closing_` 标志（`Lua::~Lua()` 在 `lua_close` 前置位），
并让 **`Lua::gc()` / `Lua::gc_step()` 在 closing 时直接返回**。
> 初版是把守卫放在 `LuaTranslation::~LuaTranslation()`（只挡已知那一个调用点）；
> **上游作者 review 时建议把守卫下沉到 `Lua::gc/gc_step`** —— 采纳：这两个函数是插件里**唯一**
> 驱动 `lua_gc()` 的地方，按咽喉点守卫天然覆盖全部调用方，且 `lua_gears.cc` 无需改动
> （补丁从 3 文件缩到 **2 文件 +12 行**）。改完用同一组用例复验：32 字母 3/3 正常退出（3.9s）、
> 52 字母 3/3（8.9s），黄金 33/33 不变。

**实测**（librime 1.17.0 + 本地重建插件；`rime_api_console` 喂整句拼音后退出）：

| 用例 | 修复前 | 修复后 |
|---|---|---|
| 32 字母 `yiwangdeshi...` | **3/3 挂死**（>60s 被杀） | **3/3 正常，3.35 s** |
| 52 字母 `duzhe...` | 11.9 s（且偶发挂死） | 7.8 s |
| 黄金 33 | — | **33/33 ✓** |

**已提交上游**：`hchunhui/librime-lua` → **PR #435**（基于上游 `6f30968`，`+12/-0`，**2 文件**；
按作者 review 建议改为在 `Lua::gc/gc_step` 处守卫，提交 `3d54eac`）。
本地 vendored 插件保持 **pin(`ad1e4a6`) + 该补丁（未提交）**，与已构建的 `librime.so` 一致。

**后续（已解锁）**：§4.50 那两个更快变体现在能用了 —— 其中**前缀桶记忆化**已在本地验证通过
（同表：32 字母 挂死→**3.35 s**、52 字母 11.9→**7.8 s**、黄金 33/33 ✓），
但**未随包交付**：`make setup` 克隆的是 pin 的 `ad1e4a6`（不含修复），
若把记忆化写进代码而新人重建环境就会回到活锁。选择：等 #435 合并后 bump pin，
或在 `setup_env.sh` 里像 librime 那样加一条本地 patch 步骤。
补丁存档：`docs/experiments/h7-bucket-memo-pending-pin-bump.patch`。

> 另：这个活锁也会**污染评测** —— exit 挂死会被 `subprocess.run(timeout=...)` 记成 `None`，
> 而它打的候选其实是对的（stdout 里已经有 `1. [...]`）。H8 的「超时 vs 真错」应一并把这条分开。

### 4.52 ⭐⭐ H8 落地：评测从「±2 句噪声」变成**确定性度量**

**问题**（§4.49/§4.50/§4.51 都踩过）：`eval_gram.first_candidate` 在超时时直接返回 `None`，
而 `subprocess.run(timeout=...)` 会把**已产生的 stdout 一并丢弃** ⇒ 两种完全不同的情况混成一个 `None`：
- **进程不退**（librime-lua 关闭期 GC 活锁，§4.51）：候选**其实已经打出来了**，答案是对的；
- **真的慢/搜索爆炸**：根本没算出候选。

量太差⇒所有 A/B 都不可信（先前同一配置得 64/65/66，差异全在这里）。

**改法**（`scripts/eval_gram.py`）：新增 `run_console()` —— Popen + `communicate(timeout=)`，
超时后**杀整个进程组**（`start_new_session=True` + `os.killpg`，只 `p.kill()` 直系子进程的话
孙进程还持有 stdout 管道 → 第二次 `communicate()` 会永久阻塞，自测踩到过）
再把已产生的输出读回来，据「有没有打出候选」分类：

| status | 含义 |
|---|---|
| `ok` | 正常退出 |
| `hang` | 超时被 kill，但**已打出候选**（答案对、进程不退 → 就是那个 GC 活锁）|
| `slow` | 超时被 kill，且没打出候选（真慢/搜索爆炸）|
| `empty` | 正常退出但没有候选行 |

报告里逐类计数（`[hang=3 slow=1]`），失败行末尾标 `<hang>/<slow>`；
质量分仍按候选判对错（`hang` 的候选是真实的，计入分但单列异常）。
**顺手修**：`scripts/regression_test.py` 遇到 `TimeoutExpired` 不再抛异常中断整轮
（之前真的崩过），改报 `(超时/挂死)`。

**自测**：四个假 console（正常/打印后挂住/只挂住/无候选）分类 4/4 正确。

**效果（本地已带 §4.51 插件修复）**：
```
句子(全拼)  66/160 (41%)     异常 0
句子(全拼)  66/160 (41%)     异常 0     ← 第二次
两次 run 逐句一致: 160/160 不一致 0 句
```
⇒ **噪声归零、可复现**：此前同配置得 64/65/66 的波动 100% 来自「超时/挂死假失败」；
也就是说**§4.51 那个插件 bug 一直在污染评测**，而不只是让进程不退。

### 4.53 ⭐⭐ A1 词库档位实测：`make tier` 一直是**空操作**；大词库是「覆盖 vs 排序」的权衡

**起因**：§4.52 拿到可信度量后，先看失败面 —— 160 句里**拼音词库只能完全覆盖 11/160**
（字符覆盖 79.5%），而 full 档那 78 万词的文本能把覆盖抬到 45/160（90.2%）。
于是先查「换档」这条路。

**发现 1（工具 bug）：五笔侧词库的档位从来就没生效过**
`set_tier.py` 的 `TIERED` 规则写的是 `_wb86_wx` 和裸 `egret_wubi_words`，
两个都**匹配不到实际文件名** `egret_wubi_words_wangxiang_base` / `..._wb86_base`
（因为 `(_core|_base|_full)?` 后面要求 `\b`，而下一字符是 `_`）
⇒ 切档只改到拼音那一行，而拼音档 base/full **内容逐条相同**（见发现 2）
⇒ **`make tier core|base|full` 实际上是个空操作**。已修（并写入注释防再犯）。

**发现 2：拼音侧没有长尾源**
`egret_py_words_base` 与 `_full` 都是 63,177 条、**词与权重集合完全相同**
（`egret_py_words_src` 自身就是从 >450 的 base 列表注音出来的）
⇒ 换档对纯拼音路径零影响；拼音长尾必须**先生成**（原 A2）。

**发现 3：加大词库 = 覆盖率换排序**（本地已带 §4.51 插件修复 + §4.52 确定性度量）

| 档位 | 五笔词数 | table.bin | 混流 40 例 | 160 句全拼 | `mffp`→？ |
|---|---|---|---|---|---|
| **base（现役，≥451）** | 6.3 万 | 3.9 MB | **11/40** | **66/160** | 财过 ✗ |
| mid（≥165，本地临时生成） | 39.2 万 | 13.9 MB | 9/40 | 65/160 | **周勃 ✓** |
| full（>0） | 78 万 | 26.4 MB | 9/40 | 65/160 | **周勃 ✓** |

黄金 33 在三档下都是 33/33；部署耗时都在 10s 内。

**结论**：
1. 大词库**不是免费收益**：多出来的长尾词带来覆盖（`mffp→周勃`、`sodqss→杰克森`），
   但同时在混流/全拼的首候选上都轻微变差（混流 −2、全拼 −1，且 mid 就已经丢完）——
   即**排序代价在很低的阈值上就发生了**，与「长尾交给 gram」的设计注解一致。
2. 因此**当前默认 base 有数据支撑**，本次不动默认。
3. 真正缺的是一个**「五笔打词」评测集**（E1）：现有两个套件都看不出
   「这个词用户到底能不能打出来」，所以档位/长尾这类决策现在无法公平评估。
4. 想拿覆盖又不动排序，正确的路子不是把 78 万倒进去，而是**只补「语料高频但词库缺」的那批词**
   （C5 新词入库的正解）—— 先量清单再动手。

### 4.54 ⭐⭐⭐ A2 机制验证：**覆盖是主因**，但只能系统性补（附一次完整的“过拟合对照”）

背景（§4.53）：160 句里「base 缺、full 有」的词只有 **107 个**，权重全部堆在 **300~450**
（刚好被 base 的 451 阈值切掉），其中居然有 `进一步`(441)。而这些词在 full 里**只有五笔码、没拼音码**。

**实验 ①（故意的上界测试：词就从测试集里挖）**
把上面 107 词用 pypinyin 补拼音码后注入混合库：

| | base | +107 边界词 |
|---|---|---|
| 160 句全拼 | 66/160 (41%) | **75/160 (47%)，+9** |
| 混流 40 例 | 11/40 (28%) | 11/40（**零损伤**）|
| 黄金 33 | 33/33 | **33/33 ✓** |

⇒ **覆盖确实是这批失败的主因**（不是排序/LM），而且“少而准”的注入不伤其它指标。

**实验 ②（去循环）**：同样方法改从 `sentences.tsv`(200 句) 挖出 101 词，
在**完全留出**的 `sentences_v2`(160 句) 上验证：
```
句子(全拼)  66/160 (41%)      ← 与不加词完全一样
```
⇒ **手工小批补词不 transfer**（+9 是过拟合测试集）。要把分数真的推上去，
必须按**分布**把长尾整体补进去；而“每个句子集自己缺的词”都不同（v2 缺 107、200 句集缺 101），
覆盖面就是长尾本身。

**与 §4.53 的 mid/full 实测合起来看，下一歩已经指向唯一可能：**

| 做法 | 长尾词的拼音码 | 160 全拼 | 混流 40 |
|---|---|---|---|
| base | — | 66 | 11 |
| mid / full（39.2万 / 78 万字） | **没有** | 65 | 9 |
| 107 词（有拼音码） | 有 | **75** | 11 |

⇒ mid/full 反而变差的解释：那 39~78 万词全是**五笔逗号码**，
在混流库 prism 里它们也是“spelling”（会和拼音串碰撞）⇒ 纯拼音路径**付了碰撞代价、却没拿到覆盖**。

**下一手（A2 正式版，待做）**：用 `gen_pinyin_words.py` 那套（pypinyin 注音 + 沿用万象权重）
给长尾词**补上拼音码**再入库，然后 A/B 160 句 + 混流 40。
假设：同时拿到覆盖（近 100 万拼音词）且不像 mid/full 那样掉分。
**评测纪律**：本轮 ①②两个实验正好是一个完整的对照——挖词/调参只能用一套集子，
另一套留作留出验证（本项目已有 v2 与 200 句式两套、不重叠）。

### 4.55 ⭐⭐⭐ H10：给长尾词补拼音码——**+6~9 句，两套独立集合都验证过**（首个真正落在准确率上的改动）

**由来**（§4.53/§4.54）：
- base 档只收权重 ≥451 的词（6.3 万），451 以下的长尾**只有五笔码、没拼音码**；
- 纯拼音路径上那些词“只能单字硬组” → 160 句里 **79.5% 的字符覆盖率**就是这个原因；
- §4.54 用“从测试集挖词”证了覆盖是主因（+9），但去循环后为 0 → 必须**按分布整体补**。

**做法**：用现成的 `gen_pinyin_words.py`（pypinyin 词感知注音 + 沿用万象权重）
给 full 档五笔词（78 万字）补主读音拼音码，产出一张独立的长尾表，接进 `egret_wubi_py` /
`egret_py` 两个 wrapper（**放在 base 拼音词之后**）。新增 `--out-name` / `--min-weight` 两个选项；
`refresh.sh` 已接上这步（§4.55）。

**阈值扫描（都在 160 句集上；评测已是确定性度量）**：

| 长尾词（拼音码，词源权重阈值） | 条数 | table.bin | 160 句 | 混流 40 |
|---|---|---|---|---|
| 0（现状，base） | — | 3.9 MB | 66/160 (41%) | 11/40 |
| **≥300（采用）** | **17.8 万** | **6.5 MB** | **74/160 (46%)** | 11/40 |
| ≥165 | 39.2 万 | 12.1 MB | 71/160 (44%) | 11/40 |
| >0 | 78.1 万 | ~20 MB | 71/160 (44%) | — |

（该扫描用的是**逐字注音**变体；交付版改用词感知注音后为 **72/160** —— 差别只在度量口径，见“附带发现 2”。）

⇒ **有条数拐点（≥300 最优）**：再往上就把噪声带进来了（与 §4.53 “大词库掉排序”一致）。

**跨集验证（关键，避免又一次调参过拟合）**：阈值 300 定下来后在**从未参与调参**的
200 句集（`sentences.tsv`）上重测：

| 集合 | 现状 | +17.8 万长尾拼音词（逐字注音版） | 交付版（词感知注音） |
|---|---|---|---|
| v2（160 句，调参用） | 66/160 (41%) | 74/160 (46%) | **72/160 (45%)，+6** |
| sentences.tsv（200 句，留出） | 69/200 (34%) | 78/200 (39%) | **75/200 (38%)，+6** |

两套独立集增益一致（+6/+6）⇒ **真实、可泛化**。黄金 33/33、混流 40 例 11/40 均**零回归**。

**附带发现 1：多读音展开更差**。`--max-readings 2` 让表涨到 27.7 万条，160 句反而
**58/160 (36%)** —— 与 `gen_pinyin_words.py` 文档里早先记的“多读音让分段歧义变大”一致，
所以长尾也保持 `max-readings=1`。

**附带发现 2（当时记反了，§4.56 已纠正）**：词库与评测输入的注音口径不一致——
方向是**词库错**：`readings()` 逐字取首读音（`银行`→yin **xing**、`拜佛`→bai **fu**），
而评测输入 `lazy_pinyin` 是词组感知的（`yin hang` / `bai fo`）。
⇒ 错读音意味着用户按正确读音**打不出该词**，修法见 §4.56。

### 4.56 ⭐⭐ H12：词典注音改成**词组感知**（银行 yin hang / 拜佛 bai fo）—— +2 / +4 句

**缘起**：§4.55 里发现“词库与评测输入的读音对不上”，当时把方向记反了。实测看清：

| 词 | `readings()`（逐字取首读音） | `lazy_pinyin`（词组感知） |
|---|---|---|
| 银行 | yin **xing** ✗ | yin **hang** ✓ |
| 腌臜 | **yan** za ✗ | **a** za ✓ |
| 拜佛 | bai **fu** ✗ | bai **fo** ✓ |

⇒ **是词典错**：多音字只在词组里才读对，逐字取首读音会把一批词注成错码，
用户按正确读音**打不出这个词**（而评测输入本来就是词组感知生成的，两边因此对不上）。

**修法**（`gen_pinyin_words.py::readings`）：主读音改用 `pinyin(word, heteronym=False)`
（词组感知）；备选读音仍由逐字 heteronym 拼出（`max_readings` 语义不变）。
重生成基档 + 长尾表：**1324 条基档 / 3044 条长尾**的注音被纠正。

**实测**：

| | 逐字注音 | **词组感知** |
|---|---|---|
| 160 句 | 72/160 (45%) | **74/160 (46%)** |
| 200 句（留出） | 75/200 (38%) | **79/200 (40%)** |
| 混流 40 | 11/40 | 11/40（零回归）|
| 黄金 33 | 33/33 | **33/33 ✓** |

打词验证：`yinhang → 银行` ✓（旧码下打不出来）。

**会话累计**（本轮 H8→H12）：160 句 **66 → 74**（41%→46%）；200 句 **69 → 79**（34%→40%）；
两套独立集合、黄金 33/33、混流 11/40 全程零回归。

**仍存的同源问题（未做）**：`baifo` 这类**同时**能被读成拼音与五笔的短串，
会被切分器判成“整串五笔”从而走五笔路径（`baifo → 陈赫`）——
属 §4.41 的判读歧义，与注音无关，留给后续。

### 4.57 H3：目标机复验（macOS ✓；host-linux 离线待验）+ 两个自检脚本 bug

**bundle**：`bash scripts/deploy_bundle.sh` → `dist/egret-rime-runtime-20261009.tar.gz`（29M，
61 个运行时文件，清单由 `deploy_bundle.sh --list` 单一来源提供，**长尾拼音词表自动入包**）。
H2 也一并落地：包内 `install.sh` 安装后自检——必需运行时文件 + **引擎 LM 的 400MB gram
存在性**（缺时打印后果与下载命令）。

**macOS（host-mac，Squirrel）复验** ✅
```
更新 61 个文件（含长尾词表）；error 行数 0；备份 $HOME/rime-backup-20261009-155246.tar.gz（可回滚）
词库指纹 ✓（我q/冷uwyc/署lftj）
自检 9/9 ✓：tffu→等 khlg→中国 qktnqnr→我吃饭 qchifanle→我吃饭了 uwycuklf→冷部署
            trwuktnqnr→我们吃饭 + 三条拼音长句
```

**第一次复验时自检全 ✗（e→额、tffu→他仿佛、khlg→客户两个）**，而拼音长句全 ✓。
逐层排除：词表 md5 与本地**逐字节一致**；把长尾那行去掉后**同样复现** ⇒ 与本次词库改动无关。
最后定位到**自检脚本自身的两处 bug**：

| # | bug | 后果 |
|---|---|---|
| 1 | `sed 's/^previously_selected_schema: .*/…/'` —— 该行在 user.yaml 里**缩进两格**，`^` 匹配不到 | 替换从未生效 ⇒ console 一直跑上一个方案（`egret_py` 纯拼音）⇒ 五笔用例必然全错而拼音用例正常 |
| 2 | scratch 目录（`shared_data_dir="."`）缺 `default.yaml/symbols.yaml/essay.txt`（`[ -e ] \|\|` 守卫没生效） | `import_preset: default:key_binder` 取不到 ⇒ `error building config: egret_wubi_py.schema` ⇒ 引擎降级 |

⇐ 现象与"方案选错 + schema 构建失败"完全吻合，**部署本身一直是好的**。
两处已修（`d60b472`）；host-linux 脚本有同源风险（自检不固定方案、只测拼音长句），
也一并补上（`3f1032b`，离线**未验证**）。

### 4.58 用户报「候选重复」（nihao 出多个 你好）——两个独立原因

**① 长尾表把 base 已有的词又收了一份**（§4.55 引入的回归，我的锅）
`--min-weight 300` 是"权重**下限**"，而 base 档收的是 `>=451` ⇒ base 那 6.3 万词
**全部**又被收进长尾表（实测 178,159 条里正好 63,177 条与 base 重复）
⇒ 同一个词在两张表里各产出一个候选。
修法：`gen_pinyin_words.py` 新增 `--exclude <dict.yaml>`（按文本排除已有词），
长尾表重生成 → **178,159 → 114,982 条，与 base 交集 0**；`refresh.sh` 同步带上该参数
（否则重建环境会再次踩到）。

**② `uniquifier` 放在 filter 链中间 ⇒ 去不掉重复**（用户指出）
链原顺序：`… long_word_filter → reduce_emoji → traditionalize → **uniquifier** → dump_cands_filter → compose_filter`。
实测（临时把 `dump_cands_filter` 改成"重复计数+hex"诊断）在它之后仍有
**4 个字节完全相同的重复文本**（你好/拟好/泥蒿/👋，hex 一致，排除不可见字符）。
按用户建议**把它移到链尾**后，页内重复消失：
```
1. [你好] wqvb      1. [你好] wqvb
2.  拟好            2.  拟好
3.  泥蒿      →     3.  泥蒿
4.  你好            4.  你  wq
5.  拟好            5.  尼  nx
6.  泥蒿            6.  拟  rny
```
仍在 `simplifier@traditionalize` 之后（简繁合并语义不变）。

**验收**：黄金 33/33；160 句 **73/160 (46%)**、200 句 **80/200 (40%)**（与去重前 74/79 等价波动）；
混流 40 例 11/40 不变；**macOS 目标机部署后自检 9/9 ✓ + `nihao` 单条复验通过**。

> 教训：给词表做"补长尾"时必须**按已有词排除**，不能只按权重阈值切——
> 阈值是"下限"语义时，高权重词会被重复收进来。

### 4.59 混流/排序再调查：真实数据 vs 合成套件 + `collocation_min_length=3`

**① 真实用户数据反证了"混流排序很差"这个印象**
把用户 Mac 上 `egret_wubi.user.dict.txt` 的 **385 条学习记录**（= 他打过并选过的词/码对）
按码去重成 90 条，用干净词库复测"首选是否=他当时选的词"：**86/90 = 96%**。
⇒ 真实使用下排序基本没问题；合成混流套件（11/40 = 28%）**高估了问题**——它的输入构造
是"首字取全码前 2 位"，而 2 码本身高度歧义（实测 `gg→五`（不是一）、`ft→才`（不是都）、
`jg→量`（不是是）…），真用户会打一级简码/更长的码。

**② 五笔侧没有长尾（结构性缺口，未度量）**
`egret_wubi_words_wb86_{base,full}` 都是 **63,186 词**（86 造词码家族没有长尾）；
78 万长尾只存在于 `egret_wubi_words_wangxiang_*`，而那是 script_translator（混流库）的码式
（万象逗号码），`table_translator` 用不了。
本轮顺手验证了"只把**传统 wrapper** 换成 wb86_full" ⇒ 160 句/混流/黄金**零变化**（因为 full==base），
但这也证明了一个重要事实：**传统库与混流库是两套独立词典，动前者不影响拼音侧**（§4.53 的
"扩档伤排序"只发生在混流库的 prism 上）。

**③ `collocation_min_length: 2 → 3`（配置注释里自己写明"词库健全时应为 3"）**
| | 2（原值） | **3（采用）** |
|---|---|---|
| 160 句（调参） | 73/160 (46%) | **74/160 (46%)** |
| 200 句（**留出验证**） | 80/200 (40%) | **83/200 (42%)** |
| 混流 40 / 黄金 33 | 11/40 · 33/33 | 11/40 · **33/33 ✓** |

两套集合同向 ⇒ 真实提升（不是过拟合）。同块还有 3 个罚分参数是可 A/B 的：
`collocation_penalty(-10)` / `non_collocation_penalty(-12)` / `rear_penalty(-30，注释里的默认是 -18)`。

### 4.60 ⭐⭐⭐ H11 五笔打词评测集 + 五笔长尾：罕见词可达性 **7% → 97%**

**① 先补尺子（H11）**：现有两套套件都答不了「五笔用户打某个词，能不能打出来、排第几」，
所以档位/长尾/字表权重这类决策一直没有公平度量。新脚本 `scripts/eval_wubi_words.py`：
- 用例 = (86 词组码, 期望词)，按权重采样可复现；判 **top1**（排序对不对）+ **topN**（能不能打出来，用户可翻页选）
- 码规则：**字 → 86 两码**从 `egret_wubi_words_wb86_base` 的二字词**自举**（前2+后2，多数票）
  → 回验：59,502 个二字词的码 **100% 一致**（三字词是另一回事，见 ③）
- 自检：base 档词 **60/60（100%）** ✓（尺子本身可信）
- 🐛 首个版本把 topN 写成了 top1：console **只给首选加方括号**，正则只认方括号行 ⇒
  修成 `^[1-9]\\.\\s+\\[?(\\S+)\\]?` 后数据才对（`mfpy` 的 `赌神` 本就在第 3 位）

**② 基线暴露的结构性缺口**：长尾词（权重 300~450、base 没有的二字词）
**top1 7% / top8 7%** —— 五笔用户打罕见词**根本打不出来**（`败走`/`钓饵`/`扶墙`/`船身`/`赌神`…）。
根因：传统库用的 `egret_wubi_words_wb86_{base,full}` **都是 6.3 万词**（86 造词码家族没有长尾）；
78 万长尾只在 `wangxiang` 家族（script_translator 的逗号码式，table_translator 用不了）。

**③ 做法**：`scripts/gen_wubi_86_longtail.py` → 把万象长尾的**二字词**用自举字码表转成 86 词组码，
权重沿用万象、排除 base 已有词（§4.58 的教训）⇒ 产出 **83,492 词**，接入 `egret_wubi.dict.yaml`；
`refresh.sh` 已接上。**只做二字词**：三字词在本仓库 wb86 数据里是 **2+1+1**（非标准五笔的 1+1+2，
99.6% 一致），长尾里 61 万条三字词多为碎片，先不引入（另记待办）。

**④ 实测**

| | 改前 | 改后 |
|---|---|---|
| H11 长尾词 top1 | 7% | **52%** |
| H11 长尾词 **top8（能打出来）** | **7%** | **97%** |
| H11 base 档 | 100% | 100% ✓ |
| 160 句全拼 | 74/160 (46%) | **74/160** ✓ 零变化 |
| 200 句（留出） | 83/200 (42%) | **83/200** ✓ 零变化 |
| 黄金 33 | 33/33 | **33/33 ✓** |
| 混流 40 例 | 11/40 | **9/40 (−2)** ⚠ |

**⑤ 混流 −2 的归因（已排到具体用例）**：只有两条，且都是**歧义输入**：
`ipxi`（`xi` 既是 习 的拼音也是 纱 的五笔码）→ `浣纱` 而非 `学习`；
`ypge`（`ge` 既是 个 的拼音也是 表 的五笔码）→ `这表` 而非 `这个`。
即"五笔词变多 ⇒ 歧义输入更常判成五笔读法"——**固有代价**，只影响歧义输入；
拼音侧（160/200 句）与黄金零影响。试过两种缓解，**均无效/有害**：
- 只让长尾走 `wubi_route`（tag=wubi）：长尾**反而不可达**（2%），且黄金掉 1 条 ⇒ 已回退
- 长尾权重打折 ×0.5：H11 与混流**都无变化**（librime 对"精确码的词条"的质量加成压过权重）

→ **取舍：保留长尾**（+90pp 真实可达性 vs −2 歧义用例）。

### 4.61 ⭐⭐ H13：三字词码式改成**标准 1+1+2**（按用户决定）—— top1 0% → 94%

**事实**：本仓库 `egret_wubi_words_wb86_src` 的三字词码用的是 **2+1+1**
（爱可视 = 爱(ep)+可(s)+视(p) → `epsp`，3,656/3,675 条 = 99.6%），而标准五笔三字词是 **1+1+2**
（爱(e)+可(s)+视(py) → `espy`）。用新尺子 H11（§4.60）量化痛点：

| 三字词口径 | top1 | top8（能打出来）|
|---|---|---|
| **标准 1+1+2**（用户肌肉记忆） | **0/50 (0%)** | 1/50 (2%) |
| 仓库旧数据 2+1+1 | 46/50 (92%) | 50/50 (100%) |

⇒ 按标准五笔打三字词**几乎全军覆没**，用户必须先学本仓库的非常规码。

**处置**（用户决定"跟标准"）：新增 `scripts/fix_wubi_86_3char_codes.py`（**幂等**）
把三字词码重写为 `字1首码 + 字2首码 + 字3两码`；字→两码仍从本表二字词自举（回验 100%），
查不到字码的 16 条**保持原样不猜**。该文件带 "DO NOT EDIT"（生成器依赖外部源、跑不了），
故用脚本做可复现的数据修复；`refresh.sh` 已接上（在 `gen_dict_tiers` **之前**，幂等）。

**实测**：

| | 改前 | 改后 |
|---|---|---|
| 三字词·标准码 top1 / top8 | 0% / 2% | **94% / 100%** |
| 三字词·旧码 top1 / top8 | 92% / 100% | 0% / 2%（口径切换，符合预期）|
| 二字词 H11 | 100% | 100% ✓ |
| 黄金 33 / 160 句 / 200 句 / 混流 40 | — | **33/33 · 74/160 · 83/200 · 9/40 全部不变** ✓ |

**契约守卫**（`check_consistency.py` 2.8）：三字词码必须符合标准 1+1+2，
不符超过 `max(3, 0.2%)` 即判失败。**正反两向都验过**：
- 反向（塞 30 条旧口径坏码）→ ✗ 报错 ✓
- 还原 → ✓ 通过
> 两次自测教训：① 阈值最初设 1% ⇒ 30/3675=0.8% 塞进去**仍通过**，阈值必须紧到能抓住回归；
> ② 第一次的"改坏"脚本其实**幂等**（`kkkb→kkkb`），根本没改坏 —— 反向测试本身也要自检。

**遗留**：长尾里 61 万条三字词（多为碎片）暂未引入；若要引入，可直接用标准规则生成。

### 4.62 用户指正：三字词码应**修生成逻辑**，而不是"生成后再修"（已完成）

§4.61 我做了"数据迁移 + 契约守卫"。用户指出正解是改**生成逻辑**——对，已照做。

**根因在生成器里，两处**（`scripts/gen_wubi_py_unified_dicts.py`）：
```python
elif L == 3:  code = fs[0][:2] + fs[1][:1] + fs[2][:1]    # ← 2+1+1（非标准）
else:         code = fs[0][:2] + fs[-2][:1] + fs[-1][:1]  # ← ≥5 字词也非标准
encoder:  - length_equal: 3          formula: "AaAbBaCa"   # ← 同样是 2+1+1
          - length_in_range: [5,10]  formula: "AaAbYaZa"   # ← 同样是 2+1+1
```
（encoder 块是写进词典头、供 librime 造词用的，两处必须同改，否则用户自造词又会出现非标准码。）

**顺手核对了 refresh.sh 里那句"跑不通"的注释——它是过期的**：
输入其实只有 `dicts/wangxiang_cn_dicts/base.small.dict.yaml`（**拼音侧**源）确实缺；
五笔侧所需源都在。所以脚本跑不完的真正原因是**两个**：① 缺那个拼音侧源；②
**它会覆盖根 wrapper `egret_wubi.dict.yaml`**，而那里现在是分档 + 五笔长尾的接线。
注释已按事实改写（并说明"码式规则已修，重跑也不会再生出非标准码"）。

**验证方式（关键）**：把 `dicts/ + scripts/` 拷到临时目录，只跑
`gen_base_small()` + `gen_wubi_traditional()`，与仓库数据全字段比对：

| | 结果 |
|---|---|
| 2 字词 | 59,502 条**码全同**（无附带损伤）✓ |
| 3 字词 | 3,659/3,675 码相同；差的 **16 条**正是"自举字码表里没有该字"而跳过的（生成器有完整字表，能算全）✓ |
| 顺序 / 权重 | **完全一致** ✓ |

⇒ 采用生成器产物（保留本仓库表头）→ 重生成分档 → 部署。**这才是权威来源**：
以后任何人重跑生成器，产出的就是标准码。

**收尾**：
- `refresh.sh` **删掉**了 §4.61 加的那步"生成后再修"；
- `fix_wubi_86_3char_codes.py` 改写说明为「**一次性迁移工具**」，实测在现数据上是 **no-op（改码 0）**；
- 契约守卫（`check_consistency.py` 2.8）保留 —— 它是"生成逻辑被改回去"的唯一防线。

**复验**：H11 三字词·标准码 top1 **94%** / top8 **100%**；二字词 **100%**；
黄金 33/33；160 句 74/160；200 句 83/200；混流 40 例 9/40 —— 与 §4.61 完全一致（16 条修正对指标无可测影响，但数据口径统一了）。

### 4.63 ⭐⭐ 五笔长尾扩到三字词：日常三字词从"打不出来"到可用（+31,490 词）

**起因**：§4.62 修好生成逻辑后顺手一查，发现**日常三字词本仓库全都没有**：
`计算机 / 大学生 / 图书馆 / 办公室 / 互联网 / 中国人 / 研究生 / 火车站 / 现代化` ……
它们的万象权重是 **350~443**，正落在"我们词库缺的 300~450 桶"里（三字词 29,320 条）。

**做法**：把 `scripts/gen_wubi_86_longtail.py` 从"只做二字词"扩到**二字 + 三字词**，
三字词按**标准 1+1+2**（`字1首码+字2首码+字3前两码`，§4.61/§4.62 已把规则改对）；
字的两码优先用自举表、缺则退回该词万象码的「每字第一组」（同为 2 字母、尺度一致
⇒ 跳过数从 2,170 降到 **0**）。逐词核验：计算机=`ytsm`、图书馆=`lnqn`、办公室=`lwpg`、大学生=`ditg` ✓

**实测**

| | 改前 | 改后 |
|---|---|---|
| 长尾词表规模 | 83,492（仅二字） | **114,982**（+31,490 三字词）|
| 常见三字词探针 | 词库没有（打不出） | `ytsm`→**计算机**、`lnqn`→**图书馆**、`ditg`→**大学生**、`lwpg`→界定/**办公室** |
| H11 三字词长尾 top1 / top8 | — (0%) | **56% / 98%** |
| H11 二字词长尾 top1 / top8 | 55% / 98% | 55% / 98% ✓ |
| H11 base（二字 / 三字） | 100% / 92% | 100% / 92% ✓ |
| 黄金 33 / 160 句 / 200 句 / 混流 40 | — | **33/33 · 74/160 · 83/200 · 9/40 全部不变** ✓ |

**未引入**：权重 <300 的 **58 万条**三字词（多为碎片；`--weight-min` 可调）。
若要引入，规则与工具已就绪，只需评估排序代价。

### 4.64 顺手查到的下一个可见缺口：**四字词完全没有源**

§4.63 之后同法查了四字词：`社会主义 / 人民群众 / 经济增长 / 人工智能 / 一带一路 / 北京大学`…
**词库里没有，仓库里也没有源**——万象词库（`wb86_wangxiang_cn_dicts/base.dict.yaml` 与
`wangxiang_cn_dicts/`）**只收 2 字词（166,875）与 3 字词（613,760）**，
4 字关联词库（wrapper 里注释掉的 `wangxiang_cn_dicts/correlation.small`）不在仓库里；
整句词库（6 万条）也没有这些词。

**它是不是"能力缺口"**（实测）：4 字词的五笔码 = 每字首码，
按理可由单字组句得到，但实测全部被别的读法赢走：
```
pwyy(社会主义) → 空方      watc(人工智能) → 代么      nwwo(人民群众) → 你问我
```
（`pw`=空、`yy`=方 的 2+2 读法赢）⇒ **词条缺失 + 排序被别的读法占住，等于打不出来** ✓ 真缺口。

**可选来源**（未做）：
1. 从万象/RIME-LMDG 发行物取 4 字词表（需新增一个外部源 + 许可核对；`fetch_open.sh` 里目前没有条目）；
2. 从**我们自己的语料**挖 4 字高频串（`rime-char-gram-builder` 已能出字符 n-gram，
   但需要跨词边界过滤；或借用 `gen_sentence_dict.py` 的采样思路）；
3. 生成 86 码很简单——四字词规则 = 每字首码（`AaBaCaDa`），生成器加一档即可。

### 4.65 清理：18 个被冻结 12 天的 WikiExtractor 进程（A4 废弃）

用户问到"还有一堆 `wikiextractor.WikiExtractor` 在跑，是否没用了"——查完确认**没用**：

| 检查 | 实测 |
|---|---|
| 进程状态 | `State: T (stopped)`（TracerPid=0）—— **停止**，不是运行 |
| 已运行 / CPU | 12 天 7 小时 vs **每进程仅 ~1 分钟** CPU |
| I/O | `read_bytes` 10 秒采样 **完全不变**（345,096,192）|
| 输出 | `data/corpus/raw/` **空**、`data/corpus/wikiextract` **不存在**（0 文件）|
| 占用 | 18 个进程合计 **378 MB** RSS |

⇒ 父 shell 在等一堆 `T` 状态子进程，永远等不到（典型僵尸工作）。**已用 TERM→KILL 清理干净**（0 残留）。
`A4`（"zhwiki 抽取正在跑"）随之关闭：它从未跑完，且输入 dump 已不存在 ⇒ 无法续跑；
要重做需 `download`(~2.5GB) + `extract`(数小时) + `publish`。**当前语料已 160,682 篇 / 113GB**
（epub + 听书/课程 + 新闻），wiki 只是可选补充 ⇒ **先不做**。

### 4.66 本轮改动**价值账**（同机同日 A/B + 留出验证 + 二值能力对照）

**为什么这些数字可信**
1. 评测已是**确定性度量**（§4.52）：两次 160 句**逐句 160/160 一致** ⇒ **噪声底 = 0**，±1 句也是真实差异；
2. 两套**互不重叠**的固定句子集：v2(160) 只用于调参、`sentences.tsv`(200) **只做留出验证**；
3. 五笔侧用新尺子 H11（top1=排序 / topN=能不能打出来），其码规则经 **59,502 个二字词回验 100%**；
4. 能力类改动用**同机同分钟"摘掉/加回"对照**——"词存在 vs 不存在"是二值事实，不经统计。

**A. 准确率**

| 指标 | 改前 | 改后 | 增益 |
|---|---|---|---|
| 160 句全拼（调参集） | 66/160 (41%) | **74/160 (46%)** | +8 句 |
| 200 句全拼（**留出集**） | 69/200 (34%) | **83/200 (42%)** | **+14 句（相对 +41%）** |
| 黄金 33 | 33/33 | **33/33** | 0（零回归）|
| 混流 40 例 | 11/40 | 9/40 | **−2**（已归因，见 D/C）|

**B. 能力（二值，同机 A/B：只摘掉长尾词表）**

| 码 | 目标词 | 改前 | 改后 |
|---|---|---|---|
| `ytsm` | 计算机 | 放机/主和机… **词不存在** | **计算机 #1** |
| `lnqn` | 图书馆 | 思包/国民包… **不存在** | **图书馆 #1** |
| `ditg` | 大学生 | 地生/第生… **不存在** | **大学生 #1** |
| `mtfh` | 败走 | 几起/同等… **不存在** | **败走 #2** |
| `mffp` | 周勃 | 财过/同款这… **不存在** | **周勃 #1** |
| `qqqn` | 钓饵 | 金饰/金… **不存在** | **钓饵 #2** |
| `tffu`/`khlg` | 等/中国（base 对照） | 等 ✓ / 中国 ✓ | 等 ✓ / 中国 ✓（**不受影响**）|

H11 分层（50 例/组，可复跑）：

| 组 | top1 | top8（能打出来）| 改前 |
|---|---|---|---|
| 二字 base | 100% | 100% | 100% |
| 二字长尾（300~450） | 44% | **94%** | **7%** |
| 三字 base | 94% | 100% | 92%（且码式非标准，标准码 **0%**）|
| 三字长尾（300~450） | 56% | **98%** | **词不存在（0%）** |

真实使用侧：用户自己词库的 385 条学习记录 → 90 个不同码，干净词库下首选命中 **86/90 (96%)**（§4.59）。

**C. 代价（诚实计）**

| 项 | 改前 → 改后 |
|---|---|
| `egret_wubi.table.bin` | 4.4 → **6.16 MB**（五笔：base + 11.5 万长尾词）|
| `egret_wubi_py.table.bin` | 3.9 → **5.76 MB**（拼音：base + 11.5 万长尾词）|
| 单例 52 字母长句（整串重放，含引擎） | 11.9 → **12.7 s**（+7%；而本轮优化前是 **60 s**）|
| 部署耗时 / 包体 | <10 s / 30 MB（基本不变）|
| 混流 40 例 | **−2**（两条歧义输入：`xi`/`ge` 既是拼音音节又是别字的五笔码）|

**D. 被数据否掉的方案（说明增益不是撞出来的）**
H1（`M.score` 进 beam，0 收益+每键×3）｜确定性 DP 分类器（49/160）｜精确码二分枚举（快 ~3× 但触发
librime-lua 关闭期 GC 活锁 → 上游 PR #435）｜长尾只走 `wubi_route`（反而不可达 + 黄金 −1）｜
长尾权重 ×0.5（两指标无变化）｜整体换 mid/full 档（混流 −2、全拼 −1）｜多读音展开（58/160）｜
三字词旧码式（保留它 = 用户标准码 0%）。

**E. 价值可持续（不是一次性手改）**
生成规则修在**源头**（§4.62，含 encoder 公式）+ 契约守卫（`check_consistency` 2.8，**正反两向验证过**）；
`refresh.sh` 全链可重建（两个长尾表 + 三字词码核）; 尺子脚本化（`eval_wubi_words.py`）；
部署清单单一来源（`deploy_bundle.sh --list`，新词表自动入包）。

**F. 没做到的（不吹）**
拼音侧 86 个失败里 **31 分词 + 37 近音**基本没动（近音属模型边界）；四字词**无源**（H14）；
混流套件本身的期望值取自另一份词表（歧义构造）。

**G. 复现命令**
```bash
bash scripts/refresh.sh && make test          # 全链重建 + 黄金 33
python3 scripts/eval_gram.py --cases 40 --sentences 160 --jobs 6 --gram "wanxiang=$PWD/data/gram/wanxiang-lts-zh-hans.gram"
EVAL_SENT_FILE=$PWD/data/corpus/eval/sentences.tsv python3 scripts/eval_gram.py --cases 0 --sentences 200 --jobs 6 --gram "wanxiang=$PWD/data/gram/wanxiang-lts-zh-hans.gram"
python3 scripts/eval_wubi_words.py --src dicts/egret_wubi_words_wangxiang_full.dict.yaml --weight-min 300 --weight-max 450 --exclude-base --n 50
```

### 4.67 ⭐⭐ H14 解决：四字词用**自有语料挖掘**补上（top8 0% → 100%）

**缺口**（§4.64）：`社会主义/人工智能/人民群众/一段时间/也就是说` 这类四字词
**词库没有、仓库也没有源**（万象词库只收 2/3 字词），且 4 字词的五笔码被别的读法占住
（`pwyy→空方`）⇒ **打不出来**（实测基线 **top1 0/50、top8 0/50**）。

**做法**（不引入外部源，用自己的语料）：
1. `scripts/gen_wubi_86_mined_4char.py`：**jieba 切分** `data/corpus/clean/{para,shards}`
   （样本 809MB → 不同四字词 129,280），只留**我们词库没有**的、计数 ≥50 的 ⇒ **8,703 词**；
   jieba 的 4 字 token 基本都是真词/真短语，省掉了跨词边界噪声；
2. 权重 = log 词频映射到 **[300, 700]**（log 尺度，低频不越过精编词的 451 线）；
3. 五笔码 = **每字首码**（字首码沿用 §4.60 那套自举表，回验 100%）⇒ 逐词核验：
   `社会主义=pwyy`、`人民法院=wnib`、`解决方案=quyp` ✓
4. 产物 `dicts/egret_wubi_words_wb86_mined4.dict.yaml` 由 `egret_wubi.dict.yaml` 引入；
   `refresh.sh` 已接（无 `data/corpus` 时跳过，用仓库内产物）。

**实测（A/B：同一批词，接线前 vs 接线后）**

| 组 | top1 | top8（能打出来）| 改前 |
|---|---|---|---|
| 四字词（挖掘集，权重封顶 450） | 60% | **100%** | **0% / 0%** |
| 四字词（权重封顶 **700**，采用） | **86%** | **100%** | 0% / 0% |

**零回归**（封顶 700 时）：黄金 33/33 ✓ ｜ 160 句 74/160 ✓ ｜ **200 句（留出）83/200** ✓ ｜
混流 40 例 9/40 ✓ ｜ H11 二字 base 100% / 二字长尾 94% / 三字 base 100% / 三字长尾 98% ✓
（三字长尾 56%→54% 属采样抖动；三字词与四字词共享 4 字母码空间，实测未被挤掉）
直接探针：`pwyy → 空方 / 社会主义`、`wnib → 人民法院`、`quyp → 解决方案` ✓

**代价**：`egret_wubi.table.bin` 6.16 → **6.33 MB**（+8.7k 词）。

### 4.68 拼音侧 grammar 罚分扫描（A 项）：只有 `collocation_penalty` 有效

协议：**一次只动一个参数**，先 160 句（调参集），**只有提升才**再用留出的 200 句验证；
两套同向才保留。基线 `160 = 74/160`、`200 = 83/200`（§4.59 之后）。

| # | 改动 | 160 句 | 200 句（留出） | 结论 |
|---|---|---|---|---|
| 1 | `rear_penalty: -30 → -18`（注释里的默认） | 74 | — | 无变化 → 回退 |
| 2 | **`collocation_penalty: -10 → -12`**（默认值） | **75** | **84** | **两套同向 ⇒ 采用** |
| 3 | `collocation_penalty: -14` | 75 | — | 已到平台 → 回到 -12 |
| 4 | `non_collocation_penalty: -12 → -14` | 75 | — | 无变化 → 回退 |
| 5 | `weak_collocation_penalty: -24 → -28` | 75 | — | 无变化 → 回退 |
| 6 | `collocation_max_length: 8 → 6` | 75 | — | 无变化 → 回退 |

**定稿 grammar**：`max_length 8 · min_length 3（§4.59）· collocation_penalty -12 ·
non_collocation_penalty -12 · weak_collocation_penalty -24 · rear_penalty -30`。
采用的 -12 正好是**注释里写的万象默认值**（此前被改成 -10）⇒ 过拟合风险最低。

**最终复核**：160 句 **75/160 (47%)**、200 句（留出）**84/200 (42%)**、混流 40 例 9/40、
黄金 **33/33** ✓、H11 四字 **88% top1 / 100% top8**（五笔侧未受影响）✓

**观察**：拼音侧已进入"参数敏感度很低"的区间（6 项里只有 1 项有 +1）；剩余 54 条失败以
**分词（31）+ 近音（37）** 为主，后者是模型能力边界，靠调参榨不出更多。

### 4.69 B 项：四字词补**拼音侧**（§4.67 只补了五笔侧）

§4.67 用自有语料挖出 8,703 个四字词、只给了五笔码；拼音侧仍打不出（虽然逐字组句可能凑出，
但排不到前面）。本步复用 `gen_pinyin_words.py`（词组感知主读音，§4.56）产出
`dicts/egret_py_words_mined4.dict.yaml`（8,703 条），接入 `egret_wubi_py` 与 `egret_py`
两个 wrapper；`refresh.sh` 已接（跟在挖掘步骤之后）。

**实测**

| | 改前 | 改后 |
|---|---|---|
| 160 句全拼 | 75/160 | 75/160（不变）|
| **200 句（留出）** | 84/200 | **85/200 (42%)** |
| 混流 40 例 | 9/40 | 9/40 ✓ |
| 黄金 33 | 33/33 | **33/33 ✓** |
| **拼音能力探针**（抽 8 个挖掘四字词，打拼音看能否出来） | — | **8/8 都在第 1 位**：`weishubuduo→为数不多`、`qichuanxuxu→气喘吁吁`、`dadingzhuyi→打定主意`、`zhemeyilai→这么一来`、`jinrongjigou→金融机构`、`buguanzenyang→不管怎样`、`dixiadangyuan→地下党员`、`junshixingdong→军事行动` |

⇒ 拼音侧同样"零回归 + 能力补齐"，留出集 +1。四字词现在**五笔（每字首码）与拼音（全拼）都能打**。

### 4.70 把"性能"与"能力"都变成**可测的门**（H5 + H11 落地为一键命令）

**背景**：本轮往词库里加了大量条目（二字长尾 8.3 万 / 三字长尾 3.1 万 / 四字 8,703），
而"加词"是双刃剑——词表/prism 变大直接推高每键耗时。此前只能靠体感，等到"打字卡"才发现。
另：能力也容易**静默退化**（某次改权重/码式可能让长尾词重新打不出来）。

**① `make bench`：输入延迟基准（性能回归门）**（`scripts/bench_typing.py`）
口径：固定三串拼音喂 `rime_api_console`（整串重放 ≈ 用户连续键入），2 轮取中位数。
2026-10-10 本机基线：

| 输入 | 耗时 | 每键 | 
|---|---|---|
| 24 字母 `jintiandetianqiz...` | 3.52 s | 147 ms |
| 32 字母 `yiwangdeshixigongz...` | 6.19 s | 193 ms |
| 52 字母 `duzhemenyijingduiq...` | 12.92 s | 248 ms |

超基线 **1.5×** 即 exit 1。复测两次倍数为 1.00/1.05 ✓（门是稳的）。
> 注意这是**趋势门**（同机同日对比），不是精确 benchmark；每键分解（引擎 vs 搜索器）
> 要用 MIXSEG 调试日志，见 §4.50。作参考：本轮优化前同一条 52 字母是 **60 s**。

**② `make verify-wubi`：五笔能力验收（约 1 分钟）**（`scripts/verify_wubi.py`）
固定采样 + 阈值钉住五组能力（阈值按脚本自身固定采样标定，只拦真退化）：

| 组 | 实测 | 阈值 |
|---|---|---|
| 二字 base | 40/40 · 40/40 | top1 ≥95% · top8 ≥98% |
| 二字长尾 | 22/40 · 39/40 | ≥32% · ≥88% |
| 三字 base | 37/40 · 40/40 | ≥84% · ≥95% |
| 三字长尾 | 15/40 · 40/40 | ≥30% · ≥88% |
| 四字（挖掘） | 35/40 · 40/40 | ≥72% · ≥95% |

⇒ 以后改词库/权重/码式，`make lint && make test && make verify-wubi && make bench` 一条龙即可
既看正确性又看延迟。

**③ `make verify-bundle`：交付包验收（目标机模拟）**（`scripts/verify_bundle.py`）
本仓库已犯过三次"运行时文件漏进部署清单"（`lm_rerank.bin`/`compose_table.bin`/`py_meta.txt`），
而**本地 env-test 永远测不出来**（本地走软链、目标机是实体拷贝）。这个门把"目标机会发生的事"
压成一次本机冒烟：解包 → 装到**空目录** → 补上不分发的 400MB gram 与共享数据 → 部署 → 跑 8 条探针。

首次实测（包 `20261010`）**8/8 通过**：`e→有`、`tffu→等`、`khlg→中国`、`qktnqnr→我吃饭`、
`jintiande…→今天的天气怎么样`、`ytsm→计算机`、`mffp→周勃`、`shehuizhuyi→社会主义` ✓

> 顺带踩到并修掉一个坑：`install.sh` 的目标若是**包目录本身**（SRC==TARGET），
> 它会先 `rm -rf` 再 `cp` → **把包自己清空**（我的第一次模拟就这么自毁了）。
> 已加防呆（相同则报错退出）。

**④ 据此排除的方向**：**H15（继续降长尾阈值：三字 <300 的 58 万、四字计数 ≥20 的 ~2.4 万）
明确不做**——它是纯粹的"加词"，直接推高每键耗时（且 §4.53 已实测排序代价）；
拼音侧调参也已证进入低敏感区间（§4.68）。

### 4.71 把 `egret_py` / `egret_wubi` 补成**可独立选用的一等方案**

**现状（动手前实测）**：
- `egret_wubi.schema.yaml` 只有 **24 行**，是个占位（"internal helper schema, do not select"）：
  只写了 translator，**没有 engine/开关/反查/注释**；能打字只是因为 librime 会**继承
  `default.yaml` 的引擎**（含 script_translator）——能用但属"意外"，且名字/描述都在劝退。
- `egret_py.schema.yaml` 结构较全（110 行），但缺 `ascii_composer`（**英文态/中英切换不可用**），
  且引用了一个**仓库里根本没有的** `stroke` 词典（在较新 librime 上刷
  `Error loading table for dictionary 'stroke'` + schema 校验告警）。

**改动**：
1. **`egret_wubi` 重写为完整方案**：`speller`（五笔字母表 + `max_code_length: 0` + 无需 algebra）
   → `table_translator`（`egret_wubi` 库：字表简码/全码 + 二字/三字词 + 五笔长尾 11.5 万 +
   四字词 + 整句词库；用户词典 tabledb 自学习；completion + sentence）
   → `grammar`（万象词级 LM）→ `` `+拼音 `` 反查 → engine 全套 processors/segmentors/translators/filters
   → **候选注释显示拼音**（`reverse_lookup_filter@pinyin_comment`，认生僻字用）。
2. **`egret_py` 补齐**：加 `ascii_composer`；把惰性的笔画反查改成**注释 + 启用说明**
   （不再声明 `stroke` 依赖 ⇒ 新版 librime 不再刷那两条错误）。
3. `default.custom.yaml` 的 `schema_list` 加 `egret_wubi` ⇒ 三个方案可选（F4 切换）。

**验证**（探针会**回显实际加载的 schema**）：
| 方案 | 结果 |
|---|---|
| `egret_wubi`（白鹭五笔） | **6/6**：`khlg→中国`、`tffu→等`、`qktqn→我吃饭`、`mffp→周勃`、`ytsm→计算机`、`pwyy→社会主义` |
| `egret_py`（白鹭全拼） | **4/4**：`nihao→你好`、长句 ✓、`shehuizhuyi→社会主义`；且纯拼音行为正确（`khlg→客户两个`**不是**中国 ✓）|
| `egret_wubi_py`（主方案） | 不变 ✓ |
| 全链 | `make lint` ✓ / 黄金 **33/33** ✓ / `make verify-wubi` 全过 ✓；部署器错误 **0** |

> 踩坑：探针里 `previously_selected_schema` 必须写在 **`var:` 下**——我第一轮写成顶层，
> 被忽略后 console 一直在跑主方案，于是"验证"了三个方案其实都是同一个 ✗（已改为回显实际方案）。

### 4.72 五笔方案显示编码 + 参考 ~/vmacs/rime 的改良（采纳 3 项 / 否掉 3 项）

**① 五笔方案候选注释改为显示「五笔编码」**（用户要求）：`egret_wubi` 的注释从拼音换成
`reverse_lookup_filter@wubi_comment`（与主方案同款配置）⇒ `khlg→[中国] khlg`、`ytsm→[计算机] ytsm` ✓

**② 移植自 `~/vmacs/rime`（拆分前的老仓库）**——**采纳**：

| 项 | 价值 |
|---|---|
| `key_binder/select_first_character\|last_character` | **真缺口**：我们的 `lua/select_character.lua` 一直在读这两个键，但 `default.custom.yaml` **从未定义** ⇒ 以词定字（C-h/C-l）一直是**惰性**的 ✓ 现已生效 |
| `key_binder/bindings` | 翻页（C-,/C-.）、光标（C-p/n/b/f）、编辑（C-d/C-k）、中英切换（C-S-2）、取消（C-g/F17）——日常手感 |
| `ascii_composer`（`good_old_caps_lock` + `switch_key`）| 五笔常见偏好：Shift 不切中英（打码时避免误切）、CapsLock 原样上屏（不喜欢可删这一段）|

**③ 我们已更优（无需移植）**：`collocation_min_length` 3（他们 2）、`collocation_penalty` -12（他们 -10）、
万象词级 LM（他们 essay 字级）、lua 目录（`compose_filter`/`mix_segmentor`/`py_composer`/`lm_rerank`
都是本轮新增，他们那边没有）、以及 §4.71 刚补全的两个方案本身。

**④ 评估后不采纳**：
- **`always_make_sentences`**（他们的方案里开着）：需要给 librime **打补丁 + 加重排 lua**，
  且文档已定性——"Sentence 的 log 值与 phrase 的 exp 值不可比，属产品级决策"（
  `docs/design-weights-jianma-grammar.md` §135/§149）。记入待办，等有评测口径再说。
  ⚠ 顺带更正：`AGENTS.md` 里"该补丁已在本仓库 librime 工作区"是**迁移前的旧话**——
  当前 `third-party/librime` 是纯净 1.17.0，**没有**该补丁。
- 他们的 `wubi_sentence_speller`（四码上屏）：我们用显式码 + 保守关闭 `auto_select`；
  `egret_wubi.schema.yaml` 里已写明如何按需开启。
- 平台配置（`fcitx5.custom.yaml`/`ibus_rime.custom.yaml` 的样式/app_options）：属个人偏好，
  不宜随包覆盖用户文件（且他们那两份内容是 macOS Squirrel 的，命名与内容对不上）。

**验证**：`make lint` ✓、黄金 **33/33** ✓、三方案探针全部通过（含回显实际加载的 schema）✓

### 4.73 ✅ 上游 PR #435 已合并 → bump pin + 落地桶记忆化（**键盘延迟 -35%**）

**① pin bump**：`scripts/setup_env.sh` 的 librime-lua pin
`ad1e4a6…` → **`6da5d6c…`**（= 上游合并 PR #435 的 merge commit，含本仓库提的 `3d54eac`）。
本地 vendored 插件的**临时补丁已弃**（上游已含），`git status` 干净。

**② 全量复验新插件**（pin 一次前进 66 个 commit，含 amzxyz 那批修复 ⇒ 必须重验）：

| 指标 | 旧插件 | 新插件 |
|---|---|---|
| 黄金 33 / `verify-wubi` | ✓ | **✓** |
| 160 句 / 200 句（留出） | 75/160 · 85/200 | **75/160 · 85/200** ✓ |
| 混流 40 例 | 9/40 | 9/40 ✓ |

⇒ **行为中性**（这也说明之前那些指标不是靠插件的旧行为捡来的）。

**③ 落地"前缀桶记忆化"**（§4.50 里被活锁挡住的提速；补丁文件已删，改动直接在 `lua/py_composer.lua`）：
- 等价性：**371 个前缀结果 0 差异**（增量 vs 每次重置）；`compose` 微基准 **15×**；
- 黄金 33/33 ✓、`verify-wubi` 全过 ✓；
- **曾必挂用例 3/3 正常退出**（32 字母 3.9s、52 字母 8.9s）—— 这正是上游那条修复在起作用。

**④ 实测延迟（`make bench`，同一台机）**

| 输入 | 之前 | **现在** | 每键 | 倍数 |
|---|---|---|---|---|
| 24 字母 | 3.52 s | **2.30 s** | 96 ms | 0.65× |
| 32 字母 | 6.19 s | **4.02 s** | 126 ms | 0.65× |
| 52 字母 | 12.92 s | **9.03 s** | 174 ms | 0.70× |

⇒ 全面 **-35%**；相比本轮优化前的 52 字母 **60 s**，累计 **6.6×**。`scripts/bench_typing.py` 的
基线已同步更新（§4.70 的性能门继续守着）。

### 4.74 可维护性：仓库内一律**相对软链** + 运行时文件**必须入 git** + LM 自动下载

用户提的两件事（+ 一个答疑），逐条落地并用**新 clone 端到端**验证。

**① 仓库内软链全改相对**（此前 20 个全指向 `/export/ebook/egret-rime/...` ✗
⇒ 仓库一换目录/换机器，链全断，且 `ls -l` 看不出这层耦合）
- 新增 `scripts/rel_symlink.py`（算相对路径 + 覆盖已存在链），`make env-test` / `make deploy`
  的建链全部改用它；`data/input/*`（外部语料源）也一并改相对。
- 现况：`data/rime-test/dicts -> ../../dicts` ✓、`data/rime-test/default.yaml ->
  ../../third-party/librime/build/bin/default.yaml` ✓

**② 运行时文件必须入 git**（用户：py_meta.txt 没提交，但打包要用；clone 后所需文件应都在）
- 审计（清单源文件 × `git ls-files`）：**4 个运行时文件未入 git** ——
  `data/gram/{lm_rerank.meta,lm_rerank.bin,compose_table.bin,py_meta.txt}`。
  **根因**：清单从 **gitignore 的 `data/gram/`** 取源，而 `dicts/` 里已有被跟踪的副本却没被用
  ⇒ 本地一切正常、**新 clone 打出的包会缺这些文件** ✗。
- 处置：清单**优先取 `dicts/`**（没有再回退 `data/gram/`）；`dicts/py_meta.txt` 入 git
  （`gen_py_tables.py` 现在**双写** `dicts/` + `data/gram/`，refresh 不会让它过期）；
  `installation.yaml` **不再打包**（每台机器的 id，librime 自建）；`make env-test` 的拷贝同样优先 `dicts/`。
- **守卫**：`check_consistency.py` 新增"部署清单的每个源文件必须存在且已入 git"
  （反向验证：改回 `data/gram/` 取源 → 报 4 处错误 ✓）。

**③ `make deploy` 三处真 bug（在 clone 里测出来的）**
| bug | 后果 |
|---|---|
| 写死 `$(TARGET)dicts`（假定 TARGET 以 `/` 结尾）| 传 `TARGET=/x` → 全部铺到 `/xdicts` ✗，而脚本仍打印"已部署"（误导）|
| 残留一行 `ln -sf $(GRAM_DIR)/py_meta.txt $(TARGET)` | 与新循环重复、且是绝对链 |
| 部署的是 **essay gram**（Lua 重排时代的遗留）| 与 `grammar/language: wanxiang-lts-zh-hans` 不符 ⇒ 等于没装 LM |

**④ 语言模型自动下载**（用户：能下载就 curl 下载即可）
- 新增 `make gram-lm`（`curl -fL --retry 3 -C -` 断点续传；已有则跳过，显示体积）；
- `make deploy` 发现 LM 缺失**自动调用它**，再软链到目标目录；
- 部署包 `install.sh` 加**显式** `--download-lm`（默认不联网，只在自检里提示命令）。
- 验证用小文件冒充 LM 走完整链路：① 缺失→下载 ✓ ② 已有→跳过 ✓ ③ deploy 自动下载并链接 ✓

**⑤ `py_meta.txt` 答疑**（用户问：作用 / 是否必要 / 手工维护词典是否要更新）
- **作用**：搜索器的**词一元归一化常数** `LOG_N = log(语料总词数)*1000`
  （`total_tokens=37720811` ⇒ LOG_N≈17 440），用于每条词的惩罚项 `词权重 − LOG_N`。
- **是否必要**：**非必需**。缺失时回退硬编码 20200 并**只告警不抛错**。实测缺失：黄金 33/33、
  `verify-wubi` 全过、160 句 **75/160 不变** ⇒ 当前取值与回退值的差异不影响我们的裁决。
- **手工维护词典要不要手工更新它**：**不需要**。它是**语料统计量**（总词数），与词库增删无关；
  只有重跑语料/词频管线时由 `scripts/gen_py_tables.py` 重新生成（现在双写两处）。
- 顺带：读取逻辑从 `mix_segmentor` / `compose_filter` **各一份**收敛为
  `py_composer.load_meta` **唯一实现**（带缺失告警）。

**新 clone 端到端验证**（`git clone --depth 1 file://$PWD`，181MB）：
① 清单 63 项源文件**缺 0** ✓ ② `make deploy` 后目标**缺 0** ✓ ③ 包内含
`dicts/{py_meta.txt,lm_rerank.bin,lm_rerank.meta,compose_table.bin}` ✓；`make verify`（契约+黄金+五笔能力+延迟门）
与 `make verify-bundle`（8/8）全过 ✓

### 4.75 `make deploy` 在 host-linux 跑通：实体目录自动备份 + **父目录软链导致断链**的根因

**背景**：host-linux（Gentoo，注意 `HOME=$HOME` —— 看着像 macOS，实际是 Linux）
跑 `make deploy` 直接失败：`dicts/lua/opencc 是目录，拒绝覆盖`（该目录此前被
`deploy_host-linux_direct.sh` 做成「自包含」，三个子目录都是实体）。

**第二批坑（修完①才暴露，更隐蔽）**：`make deploy` 报成功、`ls -la` 也看得见链，
但链其实是**断的**（指向不存在的 `~/vmacs/repos/egret-rime/...`）⇒ `rime_deployer --build`
把断链当垃圾清掉 ⇒ 用户目录只剩 `build/` + 用户词典，**方案直接消失**。

**三处修复**（`scripts/rel_symlink.py` + `Makefile`）：

| # | 问题 | 修复 |
|---|---|---|
| ① | 目标是实体目录 ⇒ 直接拒绝，`make deploy` 用不了 | 新增 `--backup-existing`：改名 `<link>.bak-<时间戳>` 再建链（**默认仍拒绝**，只是错误信息给出选项）；deploy 对 dicts/lua/opencc 启用 |
| ② | **父目录是软链**时用未解析路径算相对深度 ⇒ 链少一层 ⇒ 断链 | `link_dir = os.path.realpath(dirname(link))`（内核解析相对链的基准是**物理目录**）。普通路径下 realpath==abspath，行为不变 |
| ③ | `*.yaml` 里 `user.yaml`/`default.custom.yaml`（Rime 会回写）被软链 ⇒ 写脏仓库、丢目标机原配置；`installation.yaml`（机器态）被软链成开发机那份 ⇒ 两机 sync 同一 `installation_id` | 前两者**缺失时才复制**，`installation.yaml` **完全不碰**（与 `make env-test`/`deploy_bundle.sh` 同口径） |

**验证（真实目标机 host-linux）**：
- 备份：`~/rime-backup-20261011-162544.tar.gz`（46M，排除 *.gram）+ 目标目录内
  `dicts.bak-*/lua.bak-*/opencc.bak-*`（71M/140K/276K，可 `mv` 回滚）；
- 软链 16 条**均可解析**；`rime_deployer --build` 后**不再被清**；fcitx5 重启（pid 85319）；
- scratch 自检 `~/.egret-check`：`jintiandetianqizenmeyang→今天的天气怎么样`、`tffu→等`、
  `khlg→中国`、`qktnqnr→我吃饭`，**跑两轮 4/4 一致**（含需要词级 gram 的整句）；
- 400MB gram **不重新下载**：目标机现有 419MB 文件 `ln` 硬链进 `data/gram/`（同文件系统，零拷贝）；
- host-linux 仓库 `git status` 干净 —— 用户态文件不再被软链污染（修复③的直接效果）。

**新增陷阱**（已同步 AGENTS.md）：
1. **父目录含软链时，相对软链的基准必须用 `realpath`**，否则链静默失效；`rime_deployer` 会把断链
   当垃圾清掉 ⇒ 症状是「部署成功但方案不见了」。诊断：`readlink -f <link>` 能解析到真实路径即 OK。
2. 目标机 `HOME` 未必在常规位置（host-linux 是 Gentoo 却 `HOME=$HOME`）：排查路径问题先 `readlink -f`。

### 4.76 用户两条体验反馈：① 长句页尾留字/词（先字修正） ② 键名字四连击要让字第 1

#### ② 长句页尾留「字/词」——`lua/tail_word_filter.lua`（新）

**诉求**（用户原话）：打长句时每页最后两项要是字/词，只有前面几项是长句；这样长句首字词
不合意时能先选字/词修正开头，不必退格重打。

**实现**：新增 `lua/tail_word_filter.lua`，挂在三个方案 filters **最末**（uniquifier 之后，
只重排最终表），配置在 `egret.common.yaml: lua_config.tail_word_filter`
（`page_size: 6` / `keep: 2` / `min_sentence_len: 4`）：

| 条件 | 行为 |
|---|---|
| 首候选是 Sentence 且字数 ≥ 4，且存在「匹配输入开头、未吃完整段」的非整句候选 | 每页前 `page_size-keep` 位放整句，**每页最后 `keep` 位放非整句候选**（字/词/前缀词） |
| 其余（短输入、简码/全码/词组） | 原样输出，一行不动（不碰肌肉记忆层） |

**实测**（`data/rime-test`，console）：

| 输入 | 改动前 | 改动后 |
|---|---|---|
| `womenzaiyiqi` | 6 个整句（无可选字词） | 1-4 整句，**5. 我们在 6. 我们再** |
| `jintiandetianqizenmeyang` | 1-2 整句 + 今天的/今天… | 1. 今天的天气怎么样，**5. 今天 6. 津田** |

**端到端**（先字修正真的可用）：console 送 `womenzaiyiqi` + 键 `5` ⇒ 上屏「我们在」，
余下 `yi qi` 继续组句（`status: composing 我们在[yi qi]`、候选 `1.一起 …`）——只上屏前缀，
这正是「先字修正」需要的语义。

#### ① 键名字优先（王码「25 键名字四连击」）——`scripts/keyname_priority.py`（新）

**现象**：`kkkk` 首候选是「串串」(593) 而不是「口」(544)。同类：`tttt` 笔笔(447) > 禾(361)、
`aaaa` 恭恭敬敬(487) > 工(463)、`ffff` 封堵(533) > 土(512) …。

**数据**（改前）：25 个键名字四连击码中 22 个存在同码词，**14 个被压到第 2**（其余 8 个
靠字权重本来就赢）。同类“常见字 vs 同码 2 字词”共 1638 例，其中 1537 例是词赢——
但绝大多数是“生僻字 vs 常用词”（如 𫌀(1) vs 实现(862)），那些**必须让词赢**，故只做键名字规则。

**做法**：只把**同码词**压到「键名字权重 − 1」（词仍可达，退居第 2），**不动字表权重**
（整链字权重是手工调好的整体，重做要全链重标定，见 §4.17 四次失败）。共用模块
`scripts/keyname_priority.py`，三个生成器都接上：
`gen_dict_tiers.py`（档位词表）×`gen_wubi_86_longtail.py`（二字长尾）
×`gen_wubi_86_mined_4char.py`（四字词 1+1+1+1 码）——漏一个就会漏网，
所以 `make lint`（`check_consistency.py`）加了**契约守卫**：任一词表里同码词权重 ≥ 上限即报错。

**数字**：压权 27 条/13 码（档位）+ 3 条（长尾）+ 1 条（四字词）；
全五笔表「键名字被压」残留 **0**（`kg` 脚本自检）。

**实测**：`kkkk → 1.口 2.串串`、`tttt → 1.禾`、`aaaa → 1.工`；且与**本来就字赢**的键名字
（日 jjjj / 月 eeee / 人 wwww / 又 cccc / 已 nnnn）行为一致——它们本来也是「字第 1、词第 2、
后面才是杂项」，故本改动是**把 14 个码对齐已有约定**，不是新引入的排序风格。

**已知边界**：混合库的逗号码表（`egret_wubi_words_wangxiang_*`，码形如 `kk,hk kk,hk`）
**未压**——它的 2+2 码要运行时由 algebra 派生，且混流里传统库的流在前（实测 `kkkk`
已经是「口」第 1），故不影响结果；将来若要一致处理，需在那侧同样派生 2+2 码。

**门禁**：黄金 **33/33**、`verify-wubi` 五组全过、`bench` **1.02x**（延迟门 1.5x）。

## 5. 待办（2026-10-01 复核重写 —— 旧表已过期，多项已完成或被推翻）
> 复核结论：语料账本 **160,682 篇全部抽取成功、0 失败**（424 亿字符 / 352.75 亿汉字 / 113GB）；
> 词库与 gram 产物都比源新 ✓；git 干净 ✓；方案无悬挂引用 ✓。
> **zhwiki 那条已废弃**（见 §4.65：18 个 WikiExtractor 进程被冻结 12 天、零产出、输入 dump 也已不存在）。

### 🔄 进行中
| # | 任务 | 说明 |
|---|---|---|
| A3 | 继续下载/抽取新语料 | 配额分批，`refresh.sh --loop 30` 可常驻增量 |
| ~~A4~~ | ~~zhwiki 抽取~~ | **❌ 已废弃（§4.65）**：进程被 SIGSTOP 冻结 12 天（CPU 仅 1 分钟、无 I/O、输出目录不存在），且 `data/corpus/raw/` 里的 dump 已消失 ⇒ 无法续跑。要重做得 `download`(~2.5GB)+`extract`(数小时)+`publish`；**当前语料已 160,682 篇/113GB，够用**，故先不做 |
| E1 | 评测体系：`eval_gram.py --jobs 6` 已就绪；建议评测集**分层/扩样**（现在前 40 句是 epub 子集，最难档） |

### ⏭ 下一步（按价值；本轮已把"最值钱"的做完，剩下这些）
| # | 任务 | 说明 |
|---|---|---|
| ~~H1~~ | ~~搜索器 beam 打分改用 `M.score`~~ | **❌ 已证否（§4.49）**：搜索器不在决策路径上（只由 `mix_segmentor` 用来判 tag），实测变好 0 句、变差 13 句全是超时假失败、每键耗时 ×3。改动存档 `docs/experiments/h1-mscore-in-beam.patch` |
| **H6** | **长句准确率的真正着力点** | 决策路径在 `py_route`(script_translator) 的整句候选 + grammar 侧；改动/评测都应打在这里（§4.49 的教训）。§4.54 进一步定位：**主因是词库覆盖**，不是打分 |
| ~~H10~~ | ~~给长尾词补拼音码~~ | **✅ 已落地（§4.55）**：`egret_py_words_longtail`（17.8 万条，词源权重 ≥300）接入两个 wrapper；v2 **66→74**、留出集 200 句 **69→78**，混流/黄金零回归。`refresh.sh` 已接上生成步骤 |
| ~~H12~~ | ~~注音口径不一致~~ | **✅ 已修（§4.56）**：**是词典错**（逐字取首读音：银行→yin xing）→ 主读音改词组感知；160 句 +2、200 句 +4，零回归 |
| ~~H11~~ | ~~五笔打词评测集~~ | **✅ 已建（§4.60）**：`scripts/eval_wubi_words.py`（top1/topN 两口径）+ 五笔长尾（83,492 词）→ 罕见词可达性 7%→97%。**H13 已决（§4.61）**：按标准 1+1+2 改写 3,656 条三字词码（top1 0%→94%）+ 契约守卫 |
| ~~H7~~ | ~~`mix_segmentor` + `py_composer` 提速~~ | **✅ 已落地（§4.50）**：beam 状态按输入前缀**增量缓存** + LM 增益记忆化 → 判定逐字节不变，单例 32 字 14.3s→5.5s、52 字 60s→11.9s；黄金 33/33。更强的「精确码二分」枚举已试→会触发 librime-lua 关闭期 GC 死循环，已回退 |
| ~~H14~~ | ~~四字词缺口~~ | **✅ 已解（§4.67）**：自有语料 jieba 挖掘（8,703 词，计数≥50）+ 每字首码 + 权重 300~700 ⇒ 四字词 top8 **0%→100%**、top1 86%，全指标零回归 |
| **H15** | 五笔侧权重 <300 的 58 万三字词 | §4.63 未引入（碎片多）；规则与工具已就绪，需先评估排序代价 |
| **H8** | ~~评测口径：区分「超时」与「真错」~~ | **✅ 已落地（§4.52）**：`ok/hang/slow/empty` 四态分类 + 杀进程组；修复后 160 句两次跑**逐句完全一致**（66/160、异常 0）。`regression_test.py` 遇超时不再崩 |
| ~~H9~~ | ~~拆掉 librime-lua 关闭期 GC 活锁~~ | **✅ 全部完成（§4.51 → §4.73）**：根因定位 → 上游 PR #435 **已合并** → pin bump 到 `6da5d6c` → 桶记忆化落地 ⇒ **键盘延迟 -35%**（52 字母 12.9→9.0s）|
| ~~H2~~ | ~~400MB gram 的部署校验~~ | **✅ 已做（§4.57）**：`install.sh` 自检必需运行时文件 + gram 存在性 + 下载命令 |
| ~~H3~~ | ~~dist/bundle 重打 + 目标机复验~~ | **✅ macOS 已验（§4.57）**：bundle 20261009 + 自检 9/9；**host-linux 已在线**（§4.75：`make deploy` 路径 4/4 探针通过，链路可见性已修）——`dist/bundle` 流程在 host-linux 上仍待验（脚本已同步修） |
| H4 | 扩展读法 | 现有 `wubi`/`py` 两个 tag；可再加「混合读法」等，见 `docs/schema-components.md §6` |
| H5 | 按键延迟预算 | 搜索器每键都要跑（实测约 3.6ms/键，含一次性码表加载）；多读法前先建预算 |

### 待办里的"不要做"（本轮实验已否证，别再重走）
| # | 任务 | 结论 |
|---|---|---|
| C2 | ~~权重重归一（reweight_words.py）~~ | **❌ 四次实验全部破黄金**（§4.17/§4.38）。现有字表/词表权重是**整体手工调好的**，要重做必须全链重标定 + 联合标定 |
| C3 | ~~混合拼写词条~~ | **❌ 用户明确不做** |
| G11 | ~~词级 gram for py~~ | **❌ 已被 §4.44 取代**：万象词级 gram 已是默认引擎 LM（41% vs 27%） |
| — | ~~"原生 grammar 接不了班"~~ | **❌ 误判**，是模型问题不是引擎问题（§4.44） |
| — | ~~"自建翻译链路是唯一交付路"~~ | **❌ 误判**（§4.40 已推翻；filter 注入 + tag 机制都已落地） |

### 本轮已完成（从旧表里划掉）
B3（阶段 B 验收）✅ ｜ C1（freq 已跑，`recount_full.txt`）✅ ｜ C4（成语 13k 入库，§4.27）✅ ｜
D1（字符 gram）✅ ｜ G5（候选显示五笔码，§4.20）✅ ｜ G8（字表分层取代校准，§4.23）✅ ｜
G9（𨸐 未丢弃的原因，§4.22）✅ ｜ G12（拼音侧自学习，§4.39）✅ ｜
G13（`max_code_length` 自动上屏，§4.32）✅ ｜ G14（LM 表/码表二进制化 + 契约测试，§4.34/§4.42）✅ ｜
G15（混流多读法，§4.41）✅ ｜ G16（万象词级 gram 成默认，§4.44）✅ ｜
G17（`charset_filter` 冗余删除，§4.47）✅ ｜ H1（搜索器改 `M.score`）**已证否**，§4.49 ✅ ｜ H7（搜索器增量缓存）✅ §4.50

### 仍有效的老待办
| # | 任务 |
|---|---|
| C5 | 语料新词入库（词库没有但语料高频） |
| C6 | 拼音 full 档补长尾 |
| D2 | gram 配比 AB（现在还要和万象词级 gram 对比） |
| G4 | 关 abbrev（不做简拼）；`z→在` 的来源仍需定位 |
| G6 | 大写输入补支持（GTNK/WQ 当前无候选） |
| G7 | 反查：`reverse_lookup` translator 已在 schema（§4.21）；笔画反查见 G10 |
| G10 | 笔画反查需引入 rime-data 的 `stroke.dict.yaml` |
| G3 | 整句词库扩容（更大采样/降阈值） |

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
| 10-06 | **三个 user_dict 全部用 `tabledb`**（用户指令） | 纯文本、可 git、可直改；调频/自学习/造词实测都生效（§4.48）。代价：全量重写、无事务/备份/恢复；translator 用独立名避免污染人工短语库 |

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
