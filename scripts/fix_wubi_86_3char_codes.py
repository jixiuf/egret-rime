#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""【一次性迁移工具】把 86 造词码词表里的三字词码改成标准五笔口径（1+1+2）。§4.61/§4.62

⚠ 生成逻辑已修好（`gen_wubi_py_unified_dicts.py` 的码式规则 + encoder 公式，§4.62），
   所以**正常情况下不需要再跑本脚本**（实测在已修正的数据上是 no-op：改码 0）。
   保留它只为：历史数据迁移、或有人用旧版生成器重生成后做兜底。
   注意本脚本的字→码是"从二字词自举"，对没在二字词里出现过的字**会跳过**
   （实测跳过 16 条；生成器有完整字表，能算全 —— 这也是"修生成逻辑"优于"事后修"的原因）。

问题：本仓库 `dicts/egret_wubi_words_wb86_src.dict.yaml` 的三字词用的是 **2+1+1**
（如 爱可视 = 爱(ep) + 可(s) + 视(p) → `epsp`），而标准五笔三字词是 **1+1+2**
（爱(e) + 可(s) + 视(py) → `espy`）。实测：按标准码打三字词 top1 **0/50**、top8 2%
—— 用户凭肌肉记忆**打不出来**（必须先学会本仓库的非常规码）。

做法：
  · 「字 → 86 两码」从本表**二字词自举**（前 2 + 后 2，多数票；回验 59,502 词 100% 一致）；
  · 三字词码重写为 字1首码 + 字2首码 + 字3两码；
  · 幂等；查不到字码的条目**保持原样**并统计（不猜）。

契约守卫在 `scripts/check_consistency.py` 2.8（三字词码必须是标准 1+1+2）。

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
