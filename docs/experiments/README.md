# 实验原型（保留在仓库里备用）

这些目录是**实验/验证性**的产物，不是方案的一部分（schema 里没有引用）。
保留原因：它们承载了带证据的结论，而原产地常在 `/tmp`（会被清理）。

- `rime-tag-proto/` —— 验证「段的自定义 tag 如何驱动 translator」的最小原型
  （子代理 TASK-1790771653379-k09x 产出，2026-09-30）。
  结论与机制见 `docs/schema-components.md` §6.1；一键复现见该目录 `run.sh`。
  核心：`lua_translator` **不支持** tag 配置（必须自己 `seg:has_tag()`）；
  给段打 tag 要 `add_segment` 一个**等长** Segment 且 `tags = {[tag]=true}`（set 形式，
  与已有 tag 取并集）；`LuaSegmentor::Proceed` 返回 **true=继续 / false=终止**。
