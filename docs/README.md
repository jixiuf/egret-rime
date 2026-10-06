# Rime 知识库（docs/）

> 本知识库自 `~/vmacs/rime/docs` 移植（2026-09-26），在此仓库基础上继续
> 维护与扩展（自建词库、自训 gram 等）。原仓库保留同名副本，两边目前
> 不同步，以本仓库为准。

本目录是对 librime 源码（本仓库 `third-party/librime`，pin rime/librime 1.17.0）与 Rime
输入法体系的系统性总结，供 AI agent 在修改 schema / 词库 / 语言模型时快速定位。

## 文档索引

| 文件 | 内容 |
|------|------|
| [PROGRESS.md](PROGRESS.md) | **项目进度与交接（活文档）**：当前状态/后台任务/待办/决策/踩坑——接手先读 |
| [rime-architecture.md](rime-architecture.md) | 引擎全景：按键处理管线、组件模型（Ticket/Registry）、Segment/Translation 数据流 |
| [librime-source-map.md](librime-source-map.md) | librime 源码地图：目录/文件职责、读码入口、插件（lua / octagram） |
| [schema-config-reference.md](schema-config-reference.md) | schema 配置全解：engine 各组件、translator 常用/专用选项、__include/__patch |
| [dict-reference.md](dict-reference.md) | 词库：.dict.yaml 格式、编译产物（table/prism/reverse）、import_tables、造词规则、用户词典 |
| [lm-grammar.md](lm-grammar.md) | 语言模型：octagram 插件、poet 组句算法、grammar 配置、gram 文件、训练管线 |
| [deployment-debugging.md](deployment-debugging.md) | 部署流程、build 产物、调试方法（rime_api_console 等）、本项目踩坑清单 |
| [lua-scripting.md](lua-scripting.md) | librime-lua：挂载方式、API 速查、实战范式（取自雾凇/万象/墨奇）、陷阱 |
| [reference-projects.md](reference-projects.md) | 参考项目分析（雾凇/万象/RIME-LMDG/墨奇/白霜）及词库构建、优化、评测工作流 |
| [patch方法论.md](patch方法论.md) | YAML __include/__patch 语法速查 |
| [design-weights-jianma-grammar.md](design-weights-jianma-grammar.md) | 本方案词库权重/gram 配合/简码/成语/简拼的调研与取舍（实测数据） |
| [corpus-pipeline.md](corpus-pipeline.md) | **语料管线（阶段 A~E）**：input 投放→抽取→清洗→词频→词库→gram→评测，含增量设计与限流 |

## 本机环境速查（跨机注意事项）

> 本文档可能在多台机器上使用（macOS / Linux 混用）。**本仓库已自包含**：
> 所有外部依赖源码落在仓库内 `third-party/`，语料/数据落在 `data/`
> （两者均不入 git，可用 `make setup` 或 `scripts/setup_env.sh` 重建）。
> 下文历史段落里的 `~/repos/...` 是 macOS 旧环境写法，脚本已兼容两者：
> 路径统一由 `scripts/rime_paths.py` 解析（以仓库根为基准，可用环境变量覆盖）。
> Rime 用户目录**各平台不同**（macOS `~/Library/Rime`、Linux ibus
> `~/.config/ibus/rime`、fcitx5 `~/.local/share/fcitx5/rime`，
> 详见 deployment-debugging.md §2 平台表）。

- librime 源码: `third-party/librime`（自包含；pin 1.17.0 + octagram + lua
  插件；构建脚本 `scripts/setup_env.sh build`）
- octagram 插件源码: `third-party/librime-octagram`（软链进 `librime/plugins/`）
- lua 插件源码: `third-party/librime-lua`（同上；**方案核心组件，缺它整方案不可用**）
- 训练/统计工具: `third-party/kenlm`、`third-party/rime-corpus-processing`、
  `third-party/rime-build-grammar`
- liberime (Emacs): `~/repos/liberime`
- rimel: `~/repos/rimel`
- 本方案仓库: `<本仓库>`（词库/gram 工作基点。
  原完整个人配置在 macOS `~/vmacs/rime`，含兄弟方案 egret_py/egret_wubi 等）
- Rime 用户目录/测试目录：本仓库测试环境为 `data/rime-test`
  （`make env-test` 生成）；macOS 正式环境为 `~/Library/Rime`
- 调试工具: `third-party/librime/build/bin/rime_api_console`（构建后才有，见
  deployment-debugging.md §2/§6）
- 其它仓库查找约定：见下方“相关仓库索引”——本仓库先查 `third-party/`，
  没有则用 `scripts/setup_env.sh clone` 按锁定 commit 克隆。

## 相关仓库索引（先查 third-party/，没有则 clone）

**约定**：本仓库自包含运行时，相关源码统一放在**仓库内 `third-party/`**（不入
git，pin 在 `scripts/setup_env.sh` 的 REPOS 表里，clone 后逐一比对 commit）。
下表“本地路径”为 macOS 旧环境写法，仅供对照；在本仓库一律映射到
`third-party/<名字>`：

```bash
bash scripts/setup_env.sh clone          # 按锁定 commit 克隆全部依赖
# 单个补充仓库：
git clone --depth 1 <远程URL> third-party/<名字>
```

| 仓库 | 远程 | 本地路径（查找顺序第一） | 用途 |
|------|------|--------------------------|------|
| librime | https://github.com/rime/librime | `~/repos/librime` | 核心引擎（本项目已 fork 定制，含 plugins/librime-lua、librime-octagram） |
| librime-octagram | https://github.com/lotem/librime-octagram | `~/repos/librime/plugins/librime-octagram` | 八股文语法(LM)插件 |
| librime-lua | https://github.com/rime/librime-lua | `~/repos/librime/plugins/librime-lua` | lua 脚本插件（**本机工作区为空分支，需 `git checkout master`**；API 见 lua-scripting.md） |
| rime-essay | https://github.com/rime/essay | `~/repos/rime-essay` | essay.txt 八股文词频表（preset_vocabulary） |
| rime-prelude | https://github.com/rime/prelude | `~/repos/rime-prelude` | default.yaml / punctuation.yaml / symbols.yaml 官方预设 |
| plum | https://github.com/rime/plum | `~/repos/plum` | 东风破：方案包下载管理 |
| OpenCC | https://github.com/BYVoid/OpenCC | `~/repos/librime/deps/opencc` | 繁简转换（librime deps 子模块） |
| marisa-trie | https://github.com/s-yata/marisa-trie | `~/repos/librime/deps/marisa-trie` | marisa trie（librime deps 子模块） |
| darts-clone | https://github.com/s-yata/darts-clone | `~/repos/librime/include/darts.h` | DARTS trie（prism 用，头文件已随 librime 附带） |
| squirrel | https://github.com/rime/squirrel | `~/repos/squirrel` | macOS 前端 |
| weasel | https://github.com/rime/weasel | `~/repos/weasel` | Windows 前端 |
| fcitx5-rime | https://github.com/fcitx/fcitx5-rime | `~/repos/fcitx5-rime` | Linux fcitx5 前端 |
| liberime | https://github.com/m2ym/liberime | `~/repos/liberime` | Emacs 动态模块前端 |
| emacs-rime | https://github.com/tumashu/emacs-rime | `~/repos/emacs-rime` | Emacs rime 前端（emacs 包） |
| rime-ice 雾凇拼音 | https://github.com/iDvel/rime-ice | `~/repos/rime-ice` | 拼音方案+词库分层组织范本、lua 库（分析见 reference-projects.md §4） |
| rime_wanxiang 万象拼音 | https://github.com/amzxyz/rime_wanxiang | `~/repos/rime_wanxiang` | 带声调拼音方案（LMDG 词库消费方，lua 重度工程化） |
| rime-wubi-sentence 墨奇五笔整句 | https://github.com/gaboolic/rime-wubi-sentence | `~/repos/rime-wubi-sentence` | 五笔码标注/简码自动分配脚本（reference-projects.md §3） |
| rime-frost 白霜拼音 | https://github.com/gaboolic/rime-frost | `~/repos/rime-frost` | 词库 cell 组织、essay.txt、辅助码 lua |
| RIME-LMDG | https://github.com/amzxyz/RIME-LMDG | `~/repos/RIME-LMDG` | 词库/LM 构建工厂：语料清洗、打分清洗、编码转换脚本、gram 发布（reference-projects.md §1） |
| rime-build-grammar | https://github.com/gaboolic/rime-build-grammar | `~/repos/rime-build-grammar` | 训练管线：kenlm + arpa → .gram |
| rime-schema-compare | https://github.com/gaboolic/rime-schema-compare | `~/repos/rime-schema-compare` | 方案系统评测工具（句子/文字正确率） |
| rime-corpus-processing | https://github.com/JACKCHAN000/rime-corpus-processing | `~/repos/rime-corpus-processing` | Rust 字符 2-6gram 语料统计 |
| rime-octagram-data | https://github.com/lotem/rime-octagram-data | `~/repos/rime-octagram-data` | 官方八股文语料/gram 产物 |

## 与本项目相关的关键结论（勿重复踩坑）

1. translator 的配置块键必须与 `@namespace` 完全一致，否则静默回退默认词典。
2. `translator/dictionary`、`prism` 不支持子目录路径（静默失败）；只有词库头部的
   `import_tables` 可以引用子目录下的词表。
3. 知频(0-1500万)与万象(0-1000)权重量级不可混排 → 会使 LM 组句失效。
4. 用户词典自学习会以高优先级 user phrase 调频，测试前必须清用户词典（用户目录根 `*.user.dict.txt`）。
5. prism 构建非确定性（同输入不同目录产物不同），接近的 LM 裁决可能被翻转。
