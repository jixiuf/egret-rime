# egret-rime

白鹭五笔·拼音混流输入方案（egret_wubi_py）的独立仓库。

在一句话里同时打五笔（形码）和拼音（音节），由 script_translator +
octagram 语法模型（gram）混流组句。传统结构五笔库保证简码/全码确定性
首候选，混合库负责五笔/拼音混流与 LM 组句。

## 架构

```
engine.translators (dynamic_translator lua 调度):
  first  table_translator@egret_wubi_py_wubi   传统库: 简码/全码/词组显式码, 确定性
  then   table_translator@custom_phrase        用户词组
  then   script_translator@translator          混合库: 五笔字词 + 拼音音节 + gram 组句
  last   type=completion 补全候选(沉底)
```

词库由 `scripts/gen_wubi_py_unified_dicts.py` 生成：

```
wubi86(简码表) + wb86_wangxiang(词源) + 知频8105 + 万象8105
  → dicts/egret_wubi_py/*.dict.yaml (传统库字/词 + 混合库字/词 + 拼音字/词)
```

权重统一 log-norm 0-1000 刻度；字表 ×0.35 缩放让位拼音/词，膝点 600
以上恢复真值。gram 用字级 `zh-hans-t-essay-bgc.gram`（已入库）；
wanxiang-lts 词级 gram 可切换，见 README 下文下载说明。

## 环境搭建（Linux 自包含）

所有外部依赖与数据都在仓库内（`third-party/`、`data/`），均不入 git，
一条命令重建：

```
make setup            # 克隆锁定 commit 的依赖 + 编译 librime/kenlm + venv + gram
make env-test         # 建仓库内测试环境 data/rime-test
make test             # 跑回归（默认测 data/rime-test）
```

第三方仓库 commit 经**三通道交叉校验**（直连 GitHub API / socks 代理 /
gh-proxy 三方 SHA 一致），pin 在 `scripts/setup_env.sh`，clone 后逐一比对。
RHEL/Rocky 8 需要 gcc-toolset-12、boost1.78（EPEL）与自建 glog 0.6.0
（原因见脚本内注释与 AGENTS.md）。

路径统一由 `scripts/rime_paths.py` 解析（以仓库根为基准，不依赖 cwd）：

```
third-party/  外部依赖源码与构建产物      data/  语料/词频/测试环境/gram
dicts/        词库源与产物（入 git）      scripts/  生成与测试脚本
```

## 部署

macOS（Squirrel）:

```
make deploy        # 软链 yaml/lua/opencc/dicts/gram 到 ~/Library/Rime
```

Linux 按输入法覆盖 TARGET（默认 fcitx5 的 `~/.local/share/fcitx5/rime`）：

```
make deploy TARGET=~/.config/ibus/rime/
```

首次部署后需要 wanxiang-lts 词级 gram 时（默认不需要，当前用 essay-bgc）:

```
wget -c https://github.com/amzxyz/RIME-LMDG/releases/download/v2n3/wanxiang-lts-zh-hans.gram
```

gram 默认存放在 `data/gram/`（`make setup-gram` 下载），部署时软链到
Rime 用户目录（部署不复制 gram）。

## 词库再生成

```
python3 scripts/gen_wubi_py_unified_dicts.py
```

数据源都在 dicts/ 下（wb86_wangxiang_cn_dicts 只入了 gen 用到的
base/base.small/chars 三个文件）。

## 回归测试

```
make test              # 回归（默认测 <仓库>/data/rime-test）
make test-rebuild      # 清 build + 用户词典后重新部署再跑
python3 scripts/regression_test.py --dir ~/Library/Rime   # 测其他环境（macOS）
```

默认测仓库内 `data/rime-test`（由 `make env-test` 生成，等价于旧 macOS 的
`~/rime-test`）。librime 工具按 `LIBRIME_BIN` > `third-party/librime` >
`~/repos/librime` 依次查找。改词库/gen 脚本/schema 后必跑；
新增修复时把用例加进 CASES 表。

设计调研与取舍分析见 `docs/design-weights-jianma-grammar.md`。
Rime 知识库（引擎/词库/gram/lua/调试）见 `docs/README.md` 索引。
