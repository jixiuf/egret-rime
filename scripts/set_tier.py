#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""切换词典档位：改写两个包装 dict 的 import_tables，指向 core/base/full 档。

涉及文件：
    egret_wubi_py.dict.yaml        混合库（读音层）：字表 + 五笔词 + 拼音字/词
    egret_wubi.dict.yaml   传统库（形码层）：字表 + 五笔词 + 用户词组

同时把历史直引（wb86_wangxiang_cn_dicts/base.small、
egret_py_words_src）归一为分档文件，之后切档只改后缀。

字表与拼音字表**不随档位变化**（字是基础，简码属肌肉记忆层）。

用法:
  python3 scripts/set_tier.py base        # 切到默认档
  python3 scripts/set_tier.py full --dry-run
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

WRAPPERS = ["egret_wubi_py.dict.yaml", "egret_wubi.dict.yaml", "egret_py.dict.yaml"]
TIERS = ("core", "base", "full")

# 历史直引 -> 分档文件（首次切档时归一）
LEGACY = {
    r"dicts/wb86_wangxiang_cn_dicts/base\.small\b":
        "dicts/egret_wubi_py_words_{tier}",
    r"dicts/egret_py_words_src\b":
        "dicts/egret_py_words_{tier}",
}
# 已分档的三种词表：把 (_core|_base|_full) 换成目标档
TIERED = [
    r"dicts/egret_wubi_py_words",
    r"dicts/egret_wubi_words",
    r"dicts/egret_py_words",
]


def convert(text, tier):
    changes = []

    def note(old, new):
        changes.append(f"  {old}  ->  {new}")

    for pat, rep in LEGACY.items():
        def sub_legacy(m):
            new = rep.format(tier=tier)
            note(m.group(0), new)
            return new
        text = re.sub(pat, sub_legacy, text)

    for base in TIERED:
        pat = base + r"(_core|_base|_full)?\b"

        def sub_tiered(m, base=base):
            new = f"{base}_{tier}"
            if m.group(0) != new:
                note(m.group(0), new)
            return new
        text = re.sub(pat, sub_tiered, text)
    return text, changes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tier", choices=list(TIERS))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    total = 0
    for w in WRAPPERS:
        path = os.path.join(REPO, w)
        if not os.path.exists(path):
            print(f"  ! 不存在: {w}")
            continue
        with open(path, encoding="utf-8") as f:
            src = f.read()
        out, changes = convert(src, args.tier)
        uniq = sorted(set(changes))
        print(f"{w}: {len(uniq)} 处改动")
        for c in uniq:
            print(c)
        if out != src and not args.dry_run:
            with open(path, "w", encoding="utf-8") as f:
                f.write(out)
            total += 1
    if args.dry_run:
        print("(dry-run，未写入)")
    else:
        print(f"已切换到档位: {args.tier}（改了 {total} 个文件）")
        print("→ 重新部署生效: make deploy / 重启输入法；本地回归: make test-rebuild")


if __name__ == "__main__":
    main()
