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

## 部署

macOS（Squirrel）:

```
make deploy        # 软链 yaml/lua/opencc/dicts/gram 到 ~/Library/Rime
```

Linux 按输入法改 Makefile 里的 TARGET（fcitx5: ~/.local/share/fcitx5/rime）。

首次部署后需要 wanxiang-lts 词级 gram 时（默认不需要，当前用 essay-bgc）:

```
wget -c https://github.com/amzxyz/RIME-LMDG/releases/download/v2n3/wanxiang-lts-zh-hans.gram
```

gram 放 Rime 用户目录或 build/ 下均可（部署不复制 gram，软链即可）。

## 词库再生成

```
python3 scripts/gen_wubi_py_unified_dicts.py
```

数据源都在 dicts/ 下（wb86_wangxiang_cn_dicts 只入了 gen 用到的
base/base.small/chars 三个文件）。

## 回归测试

```
python3 scripts/regression_test.py --rebuild --clean   # 重新部署+清用户词典+跑用例
python3 scripts/regression_test.py --dir /tmp/xxx      # 测指定用户目录
```

默认测 ~/Library/Rime（macOS）。改词库/gen 脚本/schema 后必跑；
新增修复时把用例加进 CASES 表。

设计调研与取舍分析见 `docs/design-weights-jianma-grammar.md`。
