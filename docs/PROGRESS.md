# 项目进度与交接（活文档）

> **用途**：pi session 会变得很大或过期。任何新 session（或换人）读这一份即可无缝接手，
> 不必回滚历史对话。
>
> **维护约定**：每完成一个里程碑、每启动/结束一个后台任务、每产生一个决策，
> **立即更新本文**（至少更新 §1 当前状态、§3 后台任务、§5 待办）。
>
> 最后更新：2026-09-27 00:42 ｜ 更新者：pi（egret-rime session）

---

## 1. 当前状态（一句话）

环境自包含可用（`make test` 20/20）；**阶段 A 语料抽取完成**（60,458 篇 / 12.5 亿汉字）；
开源语料下载中（THUCNews 已完成，人民日报/维基进行中）；**阶段 B 清洗脚本开始编写**。

## 2. 新 session 接手步骤

```bash
cd /export/ebook/egret-rime
sed -n '1,80p' AGENTS.md            # 目录与路径约定（必读）
sed -n '1,60p' docs/PROGRESS.md     # 本文
make corpus-status                  # 语料账本（抽取阶段）
bash scripts/setup_env.sh check     # 环境自检
ps aux | grep -E "[c]url|[c]argo"   # §3 后台任务是否还在跑
make test                           # 黄金用例（20 条），确认引擎仍正常
```

后台任务日志都在 `data/corpus/log/`。

## 3. 后台任务（可另开终端接管）

| 任务 | 启动方式 | 日志 | 结果落点 |
|---|---|---|---|
| zhwiki dump 下载 | `bash scripts/corpus/wiki_pipeline.sh download` | `log/dl-zhwiki.log` | `data/corpus/raw/*.bz2` |
| 开源语料下载（THUCNews/人民日报/古文） | `bash scripts/corpus/fetch_open.sh thucnews people-daily classical` | `log/fetch-open.log` | `data/input/open/<name>/` |

> 两者都是断点续传，直接重跑同命令即可继续。
> 下载器写 `.part` 再改名——**抽取器只见完整文件**，避免半成品污染增量索引。

## 4. 已完成（按时间倒序，均带验证）

### 4.1 环境自包含（RHEL8/Rocky8）
- 7 个第三方仓库 pin commit，**三通道交叉校验**（直连 GitHub API / socks 代理 /
  gh-proxy 三方 SHA 一致）后落 `third-party/`；`make setup` 可一键重建。
- 构建链：glog 0.6.0（自建，系统 0.3.5 过旧）→ librime 1.17.0 + plugins
  {librime-octagram, librime-lua} → kenlm → Rust 工具。
- 工具链：gcc-toolset-12（系统 gcc8 缺 std::filesystem）、boost1.78（EPEL）、
  Rust 1.98.1（`third-party/rust/`）。
- **验证**：`make test` → 20/20 通过（含 LM 级已知差异单列）。

### 4.2 阶段 A 语料抽取（验收完成）
- 单一入口 `scripts/corpus/extract.py` + 按文件类型自动分派 `scripts/corpus/formats.py`。
- 格式：epub / markdown / html / 纯文本 / jsonl（gzip 感知），流式落盘。
- 增量：key 优先取 同步清单 `oss_key`（内容寻址 md5，免读几十 GB），
  否则 sha256；索引 append-only 可续跑；产物丢失自动重抽。
- 限流：`nice=15` + `ioprio_set`(best-effort/7)，并发 3。
- **实测账本**（`make corpus-status`）：

| 格式 | 篇数 | 字符(亿) | 汉字(亿) |
|---|---:|---:|---:|
| epub（电子书） | 4,287 | 13.494 | 10.705 |
| markdown（听书+课程文稿） | 56,157 | 2.106 | 1.798 |
| text | 14 | 0.002 | 0.001 |
| **合计** | **60,458** | **15.601** | **12.504** |

抽取产物 4.10 GB；epub 全量 1.4 min、文稿 14 s。

### 4.3 开源语料接入
- 参考 **RIME-LMDG**（万象 gram 工厂）：维基链路 `gensim extract_pages +
  filter_wiki + OpenCC t2s`（145 万篇）；短句化 = **标点断句 + 只保留汉字**。
- 清单 `scripts/corpus/open_sources.tsv`，下载器 `scripts/corpus/fetch_open.sh`，
  维基专用管线 `scripts/corpus/wiki_pipeline.sh`（下载 + **官方 md5 校验** +
  wikiextractor 预处理 + 投放 input）。
- **排除**网文/社交媒体（docs 记录过「才最」口味污染）；
  2TB 的 ChineseWebText 只抽高质量子集 ~7G。

## 5. 待办（按依赖排序）

| # | 任务 | 依赖 | 状态 |
|---|---|---|---|
| B1 | 阶段 B 清洗 `scripts/corpus/clean.py`：白名单/繁简/样板段剔除/段落去重/短句切分 | 无（可与下载并行） | **进行中** |
| B2 | 阶段 B 口径确认（白名单范围/是否全转简/短句长度/语料配比） | 需用户拍板 | 待问 |
| A2 | zhwiki 预处理（`wiki_pipeline.sh extract && publish`）+ 增量抽取 | 维基下载完成 | 待 |
| A3 | 百度百科（15.7G，需流式解析）、ChineseWebText2.0 抽样 7G | 带宽 | 待定 |
| C1 | 词频统计 `freq`：分词(jieba/领域词典) → 词频表 → 与知频/腾讯对照 | B 完成 | 待 |
| C2 | 权重重归一：`reweight_words.py` 用语料词频重写 base.small 权重 | C1 | 待 |
| C3 | 混合拼写词条批量生成（首字五笔 2 码 + 次字拼音，修 ckwan 类盲区） | C1 | 待 |
| C4 | 成语 top-N 显式入库（语料频次 ≥3/百万） | C1 | 待 |
| D1 | 字符 2-6gram 计数（rime-char-gram-builder，分片可加量） | B 短句语料 | 待 |
| D2 | kenlm → arpa → build_grammar → `.gram`；与 essay-bgc / wanxiang-lts 做 AB | D1 | 待 |
| E1 | 评测：黄金用例 + 21 例混流批 + rime-schema-compare | C/D | 待 |

## 6. 关键命令速查

```bash
make setup / env-test / test / test-rebuild / gen / deploy      # 环境与回归
make corpus-extract / corpus-dry-run / corpus-status            # 阶段 A
bash scripts/corpus/fetch_open.sh [name...] / --list            # 开源语料下载
bash scripts/corpus/wiki_pipeline.sh [download|extract|publish] # 维基管线
bash scripts/setup_env.sh [clone|build|python|gram|check]       # 环境分步
python3 scripts/rime_paths.py                                   # 路径自检
```

## 7. 踩坑与结论（避免重复踩）

| 现象 | 结论 |
|---|---|
| GitHub 直连不通 | 用 `proxychains4`（socks5 192.0.2.1:8088）；pip 用 tuna 镜像 |
| tuna 的 crates 镜像 dl 指向 `static.crates.io`（被墙） | cargo 换 **ustc** 源（阿里云亦可） |
| 系统 glog 0.3.5 缺 `IsGoogleLoggingInitialized` | 自建 glog 0.6.0 到 `third-party/prefix` |
| boost 1.66 < librime 要求 1.74 | EPEL 的 `boost1.78-devel` + `-DBoost_DIR` |
| gcc8 缺 `std::filesystem` | gcc-toolset-12；rpath 指向工具链 lib64（不改系统库） |
| librime tag **无 GPG 签名** | 无密码学锚 → 用"三通道 SHA 一致 + git 内容寻址自证" |
| 缺 `librime-lua` 时整方案不可用 | 报 `error creating translator: 'lua_translator'`；插件**必需** |
| 测试目录软链仓库 `user.yaml` | console 回写污染仓库文件 → 改为复制（`make test` 有断言） |
| `rm -rf build` 后首次 console 候选为空 | 维护竞态（陷阱 #2）→ 先 `rime_deployer` 部署再测 |
| `mv A B` 且 B 已存在 | 会嵌套成 `B/A`（extract/dedao→markdown 踩过），已改按格式目录直出 |
| `du` 远大于 `ls` 大小 | XFS 预分配，非截断；判完整性用 `ls`/`stat -c%s` 或 md5 |
| `pkill -f "cargo build"` | 会杀掉自己（命令行含同串）→ 用 `[c]argo` bracket 技巧或分开执行 |

## 8. 产物与路径

```
egret-rime/
├─ dicts/            词库源与产物（git）
├─ scripts/{corpus,} 管线脚本（git）
├─ docs/             知识库 + 本进度文档（git）
├─ third-party/      依赖源码与构建（gitignore，make setup 重建）
└─ data/             （gitignore）
   ├─ input/{ebook,dedao-*,open}/   语料投放
   ├─ corpus/{raw,extract,clean,freq,meta,log}/
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
| 09-27 | 限流：nice 15 + ioprio BE/7 + 并发 3 | 避免同机负载告警 |
