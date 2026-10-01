# egret-rime

白鹭五笔·拼音混流输入方案（egret_wubi_py）的独立仓库。

在一句话里同时打五笔（形码）和拼音（音节），由 script_translator +
octagram 语法模型（gram）混流组句。传统结构五笔库保证简码/全码确定性
首候选，混合库负责五笔/拼音混流与 LM 组句。

## 架构

```
engine.translators (dynamic_translator lua 调度):
  first  table_translator@egret_wubi   传统库: 简码/全码/词组显式码, 确定性
  then   table_translator@custom_phrase        用户词组
  then   script_translator@translator          混合库: 五笔字词 + 拼音音节 + gram 组句
  last   type=completion 补全候选(沉底)
```

词库由 `scripts/gen_wubi_py_unified_dicts.py` 生成：

```
wubi86(简码表) + wb86_wangxiang(词源) + 知频8105 + 万象8105
  → dicts/*.dict.yaml (传统库字/词 + 混合库字/词 + 拼音字/词)
```

权重沿用万象/86 词库原值（字表另有分层：见下）；LM **默认用万象词级 gram**
`wanxiang-lts-zh-hans.gram`（原生 octagram，约 400MB，需自行下载，见下文）。
自训的字级 `zh-hans-egret.gram` 仍可选作对照（实测词级明显更好：整句 41% vs 27%）。

## 部署到 host-linux（Gentoo + fcitx5，已验证）

```bash
bash scripts/deploy_host-linux.sh --probe    # 先看远端环境
bash scripts/deploy_host-linux.sh            # 完整部署（自动找 agent socket → 打包 → scp → 远端安装 → 重部署）
```

细节：host-linux 的 `~/.local/share/fcitx5/rime` **全部软链**到 `~/vmacs/rime`，
所以脚本更新的是 `~/vmacs/rime`（git 仓库，有 `.deploy-backup-<时间戳>/` 备份），
再为新增的根级文件补软链；实测只需传 16 个文件。详见 docs/PROGRESS.md §4.15。

## 部署到其它机器（无直连时）

开发机与使用机可能没有直连（本项目实测：开发机连不上 host-linux 的 ssh），
所以用「自包含运行时包」的方式交付：

```bash
# ① 开发机：打运行时包（含 yaml/词库/lua/opencc/搜索器码表+LM 表；**不含 gram**）
make bundle                      # 产出 dist/egret-rime-runtime-<日期>.tar.gz

# ② 把包拷到目标机（微信/网盘/U 盘 均可），然后：
tar xzf egret-rime-runtime-*.tar.gz && cd egret-rime-runtime-*
bash install.sh                  # macOS 默认 ~/Library/Rime
bash install.sh --link ~/Library/Rime   # 软链模式（以后改本包即生效）

# ③ 重新部署输入法（Squirrel 菜单栏图标 → 重新部署；fcitx5 → 托盘右键重新部署）
```

安装脚本会先把要覆盖的文件备份到 `<目标>/.egret-backup-<时间戳>/`，回滚只需拷回去。

**重要（2026-10 已改）**：交付包**不带** `.gram`（400MB，请自行下载，见下文），
但**必须有它**——引擎的语言模型就是 octagram + 万象词级 gram；
Lua 侧的重排已**关闭**（`dynamic_translator/lm_rerank: false`），Lua 表只剩搜索器自用。
librime 仍然**不需要打任何补丁**（上游 1.17.0 + 官方 octagram/lua 插件即可）。

验证：输入 `e` 应出「有」，`jintiandetianqizenmeyang` 应出「今天的天气怎么样」。

## 一条命令出产物（推荐入口）

```
make setup                    # 新机器首次：依赖 + 编译 + venv
bash scripts/refresh.sh       # 之后只跑这条：用最新语料增量出全部产物
bash scripts/refresh.sh --deploy     # 出完部署到输入法
bash scripts/refresh.sh --loop 30    # 常驻增量刷新（语料持续下载中）
bash scripts/refresh.sh --tier full  # 换档（core/base/full）
```

产物：三档词库（每档含五笔码 + 拼音码）、86 造词码词库、字级 gram。
清单：`bash scripts/refresh.sh --only artifacts`。

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

**必须**准备词级 gram（引擎 LM，缺它长句会明显变差）：

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
