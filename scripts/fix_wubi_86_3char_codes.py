#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 86 造词码词表里的**三字词码**改成标准五笔口径（1+1+2）。§4.61

问题：本仓库 `dicts/egret_wubi_words_wb86_src.dict.yaml` 的三字词用的是 **2+1+1**
（如 爱可视 = 爱(ep) + 可(s) + 视(p) → `epsp`），而标准五笔三字词是 **1+1+2**
（爱(e) + 可(s) + 视(py) → `espy`）。实测：按标准码打三字词 top1 **0/50**、top8 2%
—— 用户凭肌肉记忆**打不出来**（必须先学会本仓库的非常规码）。

做法：
  · 「字 → 86 两码」从本表**二字词自举**（前 2 + 后 2，多数票；回验 59,502 词 100% 一致）；
  · 三字词码重写为 字1首码 + 字2首码 + 字3两码；
  · 幂等；查不到字码的条目**保持原样**并统计（不猜）。

该文件带 "DO NOT EDIT"（生成器依赖本仓库没有的外部源数据、跑不了），所以用本脚本做
可复现的数据修复，并由 `scripts/check_consistency.py` 的契约项守着（防止再退回去）。

用法:
  python3 scripts/fix_wubi_86_3char_codes.py --dry-run
  python3 scripts/fix_wubi_86_3char_codes.py
"""

import argparse
import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402

SRC = os.path.join(rime_paths.DICTS, "egret_wubi_words_wb86_src.dict.yaml")


def rows(path):
    """返回 (正文起始行号, [(行号, 词, 码, 权重)])"""
    lines = open(path, encoding="utf-8").read().split("\n")
    start = None
    for i, l in enumerate(lines):
        if l.rstrip() == "...":
            start = i + 1
            break
    out = []
    for i in range(start, len(lines)):
        f = lines[i].split("\t")
        if len(f) >= 3 and f[2].isdigit():
            out.append((i, f[0].strip(), f[1], int(f[2])))
    return lines, out


def char2codes(rws):
    votes = collections.defaultdict(collections.Counter)
    for _i, w, c, _wt in rws:
        if len(w) == 2 and len(c) == 4 and " " not in c:
            votes[w[0]][c[:2]] += 1
            votes[w[1]][c[2:]] += 1
    return {ch: cnt.most_common(1)[0][0] for ch, cnt in votes.items()}


def std3(word, c2):
    cs = [c2.get(ch) for ch in word]
    if any(x is None for x in cs):
        return None
    return cs[0][:1] + cs[1][:1] + cs[2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--src", default=SRC)
    args = ap.parse_args()

    lines, rws = rows(args.src)
    c2 = char2codes(rws)
    changed = already = skipped = 0
    for i, w, c, _wt in rws:
        if len(w) != 3:
            continue
        new = std3(w, c2)
        if new is None:
            skipped += 1
            continue
        if new == c:
            already += 1
            continue
        changed += 1
        if not args.dry_run:
            f = lines[i].split("\t")
            f[1] = new
            lines[i] = "\t".join(f)
    print(f"{os.path.basename(args.src)}：三字词 改码 {changed}，已经是标准码 {already}，"
          f"字缺映射跳过 {skipped}")
    if args.dry_run:
        print("（dry-run，未写入）")
        return
    if changed:
        open(args.src, "w", encoding="utf-8").write("\n".join(lines))
        print(f"已写回 {args.src}")
    print("提醒：改完要重生成分档词表 → python3 scripts/gen_dict_tiers.py")


if __name__ == "__main__":
    main()
