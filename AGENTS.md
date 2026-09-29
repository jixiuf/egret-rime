# egret-rime 项目说明（给 agent 的工作入口）

> **接手项目先读 [`docs/PROGRESS.md`](docs/PROGRESS.md)**——活文档，记录当前状态、
> 后台任务、待办清单、决策记录与踩坑。session 过大/过期后靠它无缝重建上下文；
> 每完成一个里程碑或启停后台任务，**立即回写该文档**。

## ⭐ 一条命令出产物（本项目的硬契约）

```bash
make setup                      # 新机器首次：拉依赖 + 编译 + venv + gram（约 10 分钟）
bash scripts/refresh.sh         # 之后只跑这一条：用 data/input 最新语料增量出全部产物
bash scripts/refresh.sh --deploy    # 出完直接部署到输入法
bash scripts/refresh.sh --loop 30   # 常驻：每 30 分钟增量刷新（语料持续下载中）
```

**最终产物**（`bash scripts/refresh.sh --only artifacts` 可随时查看清单）：

| 产物 | 位置 | 说明 |
|---|---|---|
| 词库（三档） | `dicts/*_words_{core,base,full}.dict.yaml` | 每档**同时含五笔码与拼音码**；权重按语料词频回归到 0-1000 |
| 86 造词码词库 | `dicts/egret_wubi_words_*.dict.yaml` | 传统库（形码确定性层） |
| 语言模型 | `data/gram/zh-hans-egret.gram` | 字级 2-6gram，约 59MB |
| 方案词库包装 | `egret_wubi_py.dict.yaml` / `egret_wubi.dict.yaml` | 由 `--tier` 切换档位 |

全链路：`fetch → extract → clean → freq → dict → gram → artifacts`，
每一阶段都**增量、可中断、可重跑**；并发用 `--jobs`（负载 <12 时可用 6）。

新增一个语料源 = 在 `scripts/corpus/open_sources.tsv` 加一行（或往 `data/input/` 丢文件），
重跑 refresh.sh 即可——不需要改任何代码。

本仓库是 egret_wubi_py（五笔拼音混流）方案的独立验证仓库，从
~/vmacs/rime 拆出（原仓库保留迁移时的副本，两边目前不同步）。

## 目录与路径约定

一切路径以**仓库根为基准**，不依赖 cwd（统一入口 `scripts/rime_paths.py`）：

```
egret-rime/
├─ dicts/          词库**源数据**（入 git）+ 生成产物（不入 git，refresh.sh 重建）
│                 · **命名规则**：内容同时含五笔与拼音 -> egret_wubi_py_*；只五笔 -> egret_wubi_*；
│                   只拼音 -> egret_py_*（如 egret_wubi_py_chars / egret_wubi_chars / egret_py_words）
│                 · 入 git：字表层（chars/wubi_chars/pinyin_8105）、五笔词源（egret_wubi_words）、
│                   外部源（wb86_wangxiang_cn_dicts/*、wubi86/*、*_pinyin_base_small 的源）、用户短语
│                 · 不入 git（生成产物）：三档词表 egret_wubi_words_wx_* / egret_wubi_words_* /
│                   egret_py_words_*（拼音）、拼音词表中间产物 egret_py_words_src
├─ scripts/        生成/测试/环境脚本（入 git）
├─ docs/           Rime 知识库（入 git）
├─ third-party/    外部依赖源码与构建（不入 git，make setup 可重建）
│  ├─ librime/           pin 1.17.0 + plugins/{librime-octagram,librime-lua}
│  ├─ glog/ kenlm/ rime-corpus-processing/ rime-build-grammar/
│  ├─ prefix/            glog 等自建库安装前缀
│  └─ venv/              python 虚拟环境
└─ data/           语料/词频/测试环境（不入 git）
   ├─ ebook -> /export/ebook/ebook   （2754 本 epub，软链，持续增长）
   ├─ dedao -> /export/ebook/dedao   （听书+课程文稿，软链）
   ├─ corpus/      抽取/清洗/计数中间产物
   ├─ gram/        gram 模型文件
   ├─ rime-test/   测试用 Rime 用户目录（make env-test 生成）
   └─ rime-shared/ 共享数据（软链到 librime build/bin 的 default/symbols/essay）
```

环境变量可覆盖（`scripts/rime_paths.py`）：LIBRIME_BIN / RIME_TEST_DIR /
RIME_SHARED_DIR / RIME_FROST_DIR / RIME_WANXIANG_DIR / EGRET_GRAM_DIR。

一键环境：`make setup`（克隆锁定 commit 的依赖 + 编译 + venv + gram）。
第三方仓库 commit 均经**三通道交叉校验**（直连 API / socks 代理 / gh-proxy
三方一致）并写在 `scripts/setup_env.sh` 的 REPOS 表；clone 后逐一比对。

## 与原仓库的差异

- 只保留混流方案链：egret.common.yaml + egret_wubi_py*.yaml。
- 剥离了 egret_py / egret_wubi 反查依赖（dependencies 与
  wubi_comment filter 已删）。
- default.custom.yaml / user.yaml 为独立最小配置。
- dicts/wb86_wangxiang_cn_dicts 只保留 gen 用到的三个文件。

## 验证基线

见 README 回归测试一节。当前基线（17 条黄金用例全过 + 已知 LM 级
差异单独报告）：

e→有 q→我 yi→就 yl→为 kl→另 de→胡 tffu→等 khlg→中国 xciy→经济
kdyc→顺序 trwu→我们 trwuchifan→我们吃饭 jfwaguangfnrt→时代广场
tgtj→生不逢时(用户词组) wan→万 taiwan→台湾 ckiy→台湾
jintiandetianqizenmeyang→今天的天气怎么样

注意: 全新目录首跑(清 userdb + 重建)可能出 wan→蛙嗯(万排第2)，
这是陷阱#9 prism 非确定性: 同输入不同目录的 prism.bin md5 不同，
贴脸的 LM 裁决会被翻转(2026-09-26 实测证实，非回归缺陷)。
判 failure 前先与黄金环境(`data/rime-test`)交叉验证。
本机复现：`make test`（默认测 data/rime-test，20/20 全过）；
`make test-rebuild` 清 build+用户词典后重跑。
jintiandetianqizenmeyang→今天的天气怎么样

## 工具依赖

- `third-party/librime`（pin 1.17.0，插件 octagram + lua 已并入构建）：
  `build/bin/{rime_api_console, rime_deployer, build_grammar}`。
  旧 macOS 环境的 `~/repos/librime` 仍可识别（脚本按优先级回退）。
- `third-party/librime-lua` 是**必需**组件：方案 engine 里的
  dynamic_translator/date_translator/select_character 等全是 lua 组件，
  缺它整方案不可用（报错 `error creating translator: 'lua_translator'`）。
- **RHEL8/ Rocky8 构建注意**：自带 glog 0.3.5 过旧（缺
  `IsGoogleLoggingInitialized`）、boost 1.66 < 要求 1.74、gcc 8 缺
  `std::filesystem`。解：自建 glog 0.6.0 到 `third-party/prefix` +
  boost1.78（EPEL）+ gcc-toolset-12（见 scripts/setup_env.sh）。
- librime 实验补丁 translator/always_make_sentences 已在本仓库
  librime 工作区（默认关，config 门控）。

## 已知陷阱（完整清单见 docs/deployment-debugging.md，知识库索引见 docs/README.md）

- console 运行会改写 user.yaml 的 previously_selected_schema，
  测前重置（regression_test.py 已自动处理）。
- rm -rf build 后首次 console 有维护竞态，跑两次再采信。
- 软链目录内 ln -sf 会自引用覆盖源文件。
- translator 配置块键必须与 @name_space 完全一致，dictionary 不支持
  子目录路径（import_tables 支持）。
- 传统库与混合库对"字全码 vs 2+2 词码冲突"的处理语义相反
  （传统库不过滤靠权重，混合库过滤为 LM 分段保洁），
  改 gen 脚本时不要混同。

## 知识库（docs/）

自 ~/vmacs/rime/docs 移植的 Rime 知识库，索引见 docs/README.md。
自建词库/自训 gram 的工作流重点看：

- docs/dict-reference.md：词库格式/编译/造词/用户词典
- docs/lm-grammar.md：octagram/poet/gram 训练管线与调优
- docs/reference-projects.md：LMDG/墨奇/万象等词库构建、清洗、评测工具链
- docs/deployment-debugging.md：部署与调试、踩坑决策树
- docs/design-weights-jianma-grammar.md：本方案词库权重/gram 配合/
  简码/成语/简拼的调研与取舍（基于本方案词库实测数据）
