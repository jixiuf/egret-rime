# egret-rime 项目说明（给 agent 的工作入口）

本仓库是 egret_wubi_py（五笔拼音混流）方案的独立验证仓库，从
~/vmacs/rime 拆出（原仓库保留迁移时的副本，两边目前不同步）。

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
判 failure 前先与黄金环境(~/rime-test)交叉验证。
jintiandetianqizenmeyang→今天的天气怎么样

## 工具依赖

- ~/repos/librime (fork 1.17.0, build/librime-octagram 插件):
  build/bin/rime_api_console 与 rime_deployer。
- librime 实验补丁 translator/always_make_sentences 已在本仓库
  librime 工作区（默认关，config 门控）。

## 已知陷阱（完整清单见 ~/vmacs/rime/docs/deployment-debugging.md）

- console 运行会改写 user.yaml 的 previously_selected_schema，
  测前重置（regression_test.py 已自动处理）。
- rm -rf build 后首次 console 有维护竞态，跑两次再采信。
- 软链目录内 ln -sf 会自引用覆盖源文件。
- translator 配置块键必须与 @name_space 完全一致，dictionary 不支持
  子目录路径（import_tables 支持）。
- 传统库与混合库对"字全码 vs 2+2 词码冲突"的处理语义相反
  （传统库不过滤靠权重，混合库过滤为 LM 分段保洁），
  改 gen 脚本时不要混同。

## 设计文档

docs/design-weights-jianma-grammar.md：词库权重/gram 配合/简码/
成语/简拼的调研与取舍（基于本方案词库实测数据）。
