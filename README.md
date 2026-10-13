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

## 部署（推荐：目标机 `git pull` → `make deploy` → `make reload`）

**开发机只 push，目标机自己拉**（仓库里已包含全部运行时文件：yaml/词库/lua/opencc/
搜索器码表 + LM 重排表；只有 400MB 的 gram 不入库、由 `make deploy` 自动下载）：

```bash
# 目标机上（fcitx5 / Squirrel 都一样）：
cd ~/repos/egret-rime && git pull --ff-only
make deploy          # 软链到输入法用户目录（Linux 默认 ~/.local/share/fcitx5/rime；macOS 默认 ~/Library/Rime）
make reload          # 重建 Rime build + 重启输入法（Linux=fcitx5 自动重启；macOS 默认只提示，加 RESTART 即 killall+open）
```

- 换输入法/换目录：`make deploy TARGET=~/.config/ibus/rime/`（`make reload` 同样认 `TARGET=`）；
- 目标目录里若是**实体** `dicts/ lua/ opencc/`（例如之前用拷贝方式装过），
  `make deploy` 会先改名备份成 `*.bak-<时间戳>` 再建链，可随时 `mv` 回滚；
- 只想重建不重启：`make reload NO_RESTART=1`；
- **必须**有词级 gram（引擎 LM，缺它长句明显变差）：

```bash
make gram-lm          # 下载万象词级 LM（~400MB，断点续传；已有则跳过）
# 或直接 make deploy —— 发现缺失会自动调它下载
```

来源：`https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram`
（`make setup-gram` 等价于 `make gram-lm`）。gram 存放在 `data/gram/`，部署时软链到 Rime
用户目录（部署不复制 gram；**不随仓库/部署包分发**）。

> 另有 `make gram-essay`（essay 字级 gram）**仅供评测 A/B**，方案运行时不再使用它。

## 离线机器（无 git / 无网）：自包含运行时包

```bash
# ① 开发机：打运行时包（含 yaml/词库/lua/opencc/搜索器码表+LM 表；**不含 gram**）
make bundle                      # 产出 dist/egret-rime-runtime-<日期>.tar.gz

# ② 把包拷到目标机（微信/网盘/U 盘 均可），然后：
tar xzf egret-rime-runtime-*.tar.gz && cd egret-rime-runtime-*
bash install.sh                  # macOS 默认 ~/Library/Rime
bash install.sh --link ~/Library/Rime   # 软链模式（以后改本包即生效）

# ③ 让输入法生效：Squirrel 菜单栏图标 →「重新部署」；fcitx5 → 托盘右键「重新部署」
```

安装脚本会先把要覆盖的文件备份到 `<目标>/.egret-backup-<时间戳>/`，回滚只需拷回去。

**重要**：交付包**不带** `.gram`（400MB，请自行下载，见上节），
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
