#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""环境准备小工具：让「本方案」在测试环境/目标机上被选中。

背景（见 docs/PROGRESS.md §4.78）：
  · **用户配置** `default.custom.yaml` 用 `schema_list/+:`（追加）—— 这是有意的：
    尊重用户已有的 luna_pinyin / cangjie5 等方案列表，只把本方案加进去。
  · 但 librime 的 console（以及部署器）取的是**列表首个可用方案**，而共享数据里
    一定有 luna_pinyin ⇒ 追加式配置下「列表顺序」选不出本方案；
    真实输入法则是按 `user.yaml: previously_selected_schema` 恢复上次方案。
  ⇒ 于是分成两件事，各自用最简单的手段解决：
    ① 测试环境（data/rime-test、交付包验收目录）：把该目录里的 default.custom.yaml
       由追加改成**替换**（`list-replace`）—— console 只看列表顺序。
    ② 目标机首次安装：`user.yaml` 里缺 `previously_selected_schema`（或值不是本方案）时
       写上本方案（`pin`）—— 输入法启动即用本方案，用户仍可 F4 随时切换。

用法：
  python3 scripts/schema_env.py list-replace <rime用户目录>
  python3 scripts/schema_env.py pin <rime用户目录> [schema_id=egret_wubi_py]
"""
import os
import re
import sys

DEFAULT_SCHEMA = "egret_wubi_py"
OUR_SCHEMAS = ("egret_wubi_py", "egret_wubi", "egret_py")   # 三个方案都算「本方案」


def list_replace(user_dir):
    """测试环境：default.custom.yaml 的 `schema_list/+:` → `schema_list:`（替换）。"""
    path = os.path.join(user_dir, "default.custom.yaml")
    if not os.path.exists(path):
        print(f"  · 无 {path}，跳过")
        return 0
    with open(path, encoding="utf-8") as f:
        src = f.read()
    fixed = re.sub(r"^(\s*)schema_list/\+:", r"\1schema_list:", src, flags=re.M)
    if fixed != src:
        with open(path, "w", encoding="utf-8") as f:
            f.write(fixed)
        print(f"  测试环境：{os.path.basename(user_dir)}/default.custom.yaml "
              f"schema_list 追加 → 替换（console 只看列表顺序）")
    return 0


def _pin_removed(user_dir, schema=DEFAULT_SCHEMA):
    """目标机：user.yaml 里 `previously_selected_schema` 缺失/非本方案时设为 schema。"""
    path = os.path.join(user_dir, "user.yaml")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            src = f.read()
    else:
        src = ""
    m = re.search(r"^(\s*)previously_selected_schema\s*:\s*(\S*)", src, flags=re.M)
    if m:
        # 用户已选的是本方案的任一（混流/纯五笔/纯全拼）→ 尊重，不动
        if m.group(2) in OUR_SCHEMAS:
            return 0
        fixed = src[:m.start()] + f"{m.group(1)}previously_selected_schema: {schema}" \
            + src[m.end():]
        note = f"把 previously_selected_schema 由 {m.group(2) or '(空)'} 改成 {schema}"
    elif "var:" in src:
        fixed = re.sub(r"^var:\s*$", f"var:\n  previously_selected_schema: {schema}",
                       src, count=1, flags=re.M)
        note = f"补上 previously_selected_schema: {schema}"
    else:
        fixed = (src.rstrip("\n") + "\n" if src else "") + \
                f"var:\n  previously_selected_schema: {schema}\n"
        note = f"写入 previously_selected_schema: {schema}"
    with open(path, "w", encoding="utf-8") as f:
        f.write(fixed)
    print(f"  目标机：{os.path.basename(user_dir)}/user.yaml {note}"
          f"（F4 菜单里随时可换方案）")
    return 0


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, user_dir = sys.argv[1], sys.argv[2]
    if cmd == "list-replace":
        return list_replace(user_dir)
    if cmd == "pin":
        sys.exit("`pin` 已并入唯一部署引擎 scripts/deploy_runtime.sh（pin_schema）")
    sys.exit(f"未知子命令：{cmd}\n{__doc__}")


if __name__ == "__main__":
    sys.exit(main())
