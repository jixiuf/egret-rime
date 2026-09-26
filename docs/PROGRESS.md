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

环境自包含可用（`make test` 20/20）；**阶段 A 抽取完成**（60,458 篇 / 12.5 亿汉字）；
**阶段 B 全量清洗运行中**（4 并发 nice 15，约 1 小时）；开源语料下载接近完成
（THUCNews 完成、人民日报 65/79、维基 3.16/3.17 GB）。

**产品目标（用户澄清，2026-09-27）**：做**通用**输入法 →
词典要**尽量全**，且**允许用户选小词典**、**允许用户选简体或繁体**。
→ 清洗不做简繁一刀切、白名单放宽、词库分层（见 §9）。

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
| 阶段 B 全量清洗 | `third-party/venv/bin/python scripts/corpus/clean.py --jobs 4 --nice 15` | `log/clean.log` | `data/corpus/clean/{para,short}/` |
| 开源语料下载 | `bash scripts/corpus/fetch_open.sh thucnews people-daily classical` | `log/fetch-open.log` | `data/input/open/<name>/` |
| zhwiki dump 下载 | `bash scripts/corpus/wiki_pipeline.sh download` | `log/dl-zhwiki.log` | `data/corpus/raw/*.bz2` |

> 三者都支持断点续跑/增量（清洗按 `clean_index.jsonl` 跳过已处理 key）。
> 下载器写 `.part` 再改名——**抽取器只见完整文件**，避免半成品污染增量索引。
> 注意：**清洗必须用 `third-party/venv/bin/python`**（系统 python 没装 C++ OpenCC）。

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

### 4.3 阶段 B 清洗（实现完成，正在跑）
- `clean.py`：样板行剔除 / 中文占比过滤 / 繁简可选 / 白名单可选 / 断句 /
  全局去重。输出 `clean/para/<格式>.txt`（整段，供词频）与
  `clean/short/<格式>.txt`（纯汉字短句，供 n-gram）。
- 并行架构：worker 写分片（本地去重）→ merge 层全局去重。
- **性能**：200 篇 0.2 min（4 并发，15 篇/s）→ 全量约 1 小时。

### 4.4 开源语料接入
- 参考 **RIME-LMDG**（万象 gram 工厂）：维基链路 `gensim extract_pages +
  filter_wiki + OpenCC t2s`（145 万篇）；短句化 = **标点断句 + 只留汉字**。
- 清单 `open_sources.tsv`；下载器 `fetch_open.sh`；维基管线 `wiki_pipeline.sh`
  （下载 + **官方 md5 校验** + wikiextractor 预处理 + 投放 input）。
- **排除**网文/社交媒体（docs 记录过「才最」口味污染）；2TB 的
  ChineseWebText 只抽高质量子集 ~7G。

## 5. 待办（按依赖排序）

| # | 任务 | 依赖 | 状态 |
|---|---|---|---|
| A2 | zhwiki 预处理（`wiki_pipeline.sh extract && publish`）+ 增量抽取 | dump 下载完成 | 待 |
| A3 | 人民日报/古文增量抽取；百度百科(15.7G)、ChineseWebText2.0 抽样 7G | 下载完成 | 待 |
| B3 | 阶段 B 验收：抽样质检 + 统计账本（去重率/留存率） | 清洗跑完 | 待 |
| **C0** | **词库分层设计**：小/基础/完整 三档 + 简/繁 两版，用户可切换 | 用户确认档位边界 | 待问 |
| C1 | 词频统计：分词(jieba + 领域词典) → 词频表 → 与知频/腾讯/万象对照 | B3 | 待 |
| C2 | 权重重归一：`reweight_words.py` 用语料词频重写 base.small 权重 | C1 | 待 |
| C3 | 混合拼写词条（首字五笔 2 码 + 次字拼音，修 ckwan 类盲区） | C1 | 待 |
| C4 | 成语 top-N 显式入库（语料频次 ≥3/百万） | C1 | 待 |
| C5 | 简/繁双向补全（OpenCC s2t/t2s 生成对侧词条） | C1 | 待 |
| D1 | 字符 2-6gram 计数（`rime-char-gram-builder`，分片可加量） | B3 | 待 |
| D2 | kenlm → arpa → build_grammar → `.gram`；与 essay-bgc/wanxiang-lts AB | D1 | 待 |
| E1 | 评测：黄金用例 + 21 例混流批 + rime-schema-compare | C/D | 待 |

## 6. 关键命令速查

```bash
make setup / env-test / test / test-rebuild / gen / deploy      # 环境与回归
make corpus-extract / corpus-dry-run / corpus-status            # 阶段 A
bash scripts/corpus/fetch_open.sh [name...] / --list            # 开源语料下载
bash scripts/corpus/wiki_pipeline.sh [download|extract|publish] # 维基管线
# 阶段 B（务必用 venv python）
third-party/venv/bin/python scripts/corpus/clean.py --jobs 4 --nice 15
third-party/venv/bin/python scripts/corpus/clean.py --merge-only
python3 scripts/rime_paths.py                                   # 路径自检
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
