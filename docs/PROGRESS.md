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

环境自包含可用（`make test` 20/20）；**阶段 A/B 完成**（抽取 60,458 篇 / 清洗产出
para 4.6G + short 3.2G）；**词典已分三档并可一键切换**（core/base/full 均 20/20）；
**一键刷新入口 `bash scripts/refresh.sh` 已就绪**（fetch→extract→clean→freq→dict→gram→verify，
全部增量可重跑）；gram 全量训练运行中。

**产品目标（用户澄清，2026-09-27）**：做**通用**输入法 →
词典要**尽量全**、**允许用户选小词典**、**允许用户选简体或繁体**，
且**五笔码与拼音码要同步覆盖**（不能有"某一档只剩五笔"的碗）。

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

### 4.9 环境严重 bug 修复：LM 之前一直没生效（❗）
**现象**：切换 `grammar/language` 到不存在的名字，结果与真 gram **完全一致**。
**根因**：librime 运行时 `user_data_dir` 与 `shared_data_dir` 默认都是 `.`，
而 `make env-test` 把 `default.yaml/symbols.yaml/essay.txt` 放在了 `data/rime-shared/`，
用户目录里没有 → `default:key_binder` 解析失败 →
`error building config: egret_wubi_py.schema` → **grammar 段整体未加载**。
**修复**：env-test 同时把这 3 个文件链进用户目录（`data/rime-test/`）。
**验证**：`ckwan` 无 gram→台万、essay-bgc/自训→台湾；无 key_binder 报错。
**影响**：此前所有回归都是"无 LM"跑的（20/20 仍成立，但 LM 类结论不可信）。

### 4.10 LM 评测（新工具 + 首批数据）
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

### 4.11 开源语料接入（可持续扩展）
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

### 4.8 格式支持
`formats.py` 注册式处理器：epub / markdown / html / 纯文本 / jsonl（gz 感知）/
**parquet**（pyarrow 流式 batch 读，内存有界）。新增格式只需加一个类。

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
| **F1** | **提升全拼路径**（当前 16%）：词典权重/拼音覆盖/短语——主战场 | C2–C6 | 待 |

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
