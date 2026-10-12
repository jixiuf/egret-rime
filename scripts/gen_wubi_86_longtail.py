#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「五笔 86 词组码」的长尾词表（H11/A 项，§4.60）。

背景：
  · 传统库（table_translator@egret_wubi）用的 `egret_wubi_words_wb86_*` 只有 6.3 万词
    （**base 与 full 内容相同**，86 造词码家族没有长尾）；
  · 78 万词的万象长尾只存在于 `egret_wubi_words_wangxiang_*`，而那是 script_translator
    的逗号码式（`mf,kd fp,bl`），table_translator 用不了；
  ⇒ 结果是五笔用户打罕见词**根本打不出来**（实测长尾词 top8 只有 7%）。

做法（码规则经全量回验）：
  · 「字 → 86 两码」从 `egret_wubi_words_wb86_base` 的二字词**自举**（前 2 + 后 2，多数票）
    —— 回验：59,502 个二字词的码 **100% 一致**；
  · 二字词码 = 两字两码相接（与 wb86 表语义完全一致）；
  · 权重沿用万象权重（同一尺度：如 你好=749），只取 base 档没有的词（避免重复候选，§4.58）。

词长：**二字词 + 三字词**（三字词用标准 1+1+2，§4.62 已把生成逻辑改对）。
三字词的缺失很可见：`计算机/大学生/图书馆/办公室/互联网/中国人/研究生/火车站`…
这些日常词本仓库全都没有（万象权重 350~443，正落在 300~450 这个桶里）。
权重 <300 的 58 万条三字词多为碎片，**不引入**（可用 --weight-min 自行调）。

用法:
  python3 scripts/gen_wubi_86_longtail.py                      # 默认权重 300~450，二字词
  python3 scripts/gen_wubi_86_longtail.py --weight-min 451     # 只补更高权重的（不存在，自检用）
"""

import argparse
import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402
from keyname_priority import caps as keyname_caps, cap_weight  # noqa: E402

DICTS = rime_paths.DICTS
SRC_WX = os.path.join(DICTS, "egret_wubi_words_wangxiang_full.dict.yaml")
SRC_WB = os.path.join(DICTS, "egret_wubi_words_wb86_base.dict.yaml")
OUT_NAME = "egret_wubi_words_wb86_longtail"


def load(path):
    rows, started = [], False
    for line in open(path, encoding="utf-8"):
        if not started:
            if line.rstrip() == "...":
                started = True
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 3 and f[2].isdigit():
            rows.append((f[0].strip(), f[1], int(f[2])))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lens", default="2,3", help="处理哪些词长，逗号分隔（默认 2,3）")
    ap.add_argument("--weight-min", type=int, default=300)
    ap.add_argument("--weight-max", type=int, default=450)
    ap.add_argument("--out", default=OUT_NAME)
    ap.add_argument("--weight-scale", type=float, default=1.0,
                    help="长尾词权重折扣（<1 让它始终排在 base 词之后；A/B 用）")
    args = ap.parse_args()

    wb = load(SRC_WB)
    votes = collections.defaultdict(collections.Counter)
    for w, c, _wt in wb:
        if len(w) == 2 and len(c) == 4 and " " not in c:
            votes[w[0]][c[:2]] += 1
            votes[w[1]][c[2:]] += 1
    c2 = {ch: cnt.most_common(1)[0][0] for ch, cnt in votes.items()}
    base_words = {w for w, _c, _wt in wb}

    rows, skipped = [], 0
    lens = {int(x) for x in args.lens.split(",") if x.strip()}
    for w, c, wt in load(SRC_WX):
        if len(w) not in lens or not (args.weight_min <= wt <= args.weight_max):
            continue
        if w in base_words:
            continue
        # 字的两码：优先自举表；缺则退回该词万象码的「每字第一组」（同为 2 字母，尺度一致）
        per = [g.split(",")[0] for g in c.split()]
        if len(per) != len(w) or any(len(p) < 2 for p in per):
            skipped += 1
            continue
        cs = [c2.get(ch) or per[i] for i, ch in enumerate(w)]
        if any(len(x) < 2 for x in cs):
            skipped += 1
            continue
        # 标准五笔词组码（§4.61/§4.62）：2 字=2+2；3 字=1+1+2
        code = cs[0] + cs[1] if len(w) == 2 else cs[0][:1] + cs[1][:1] + cs[2]
        rows.append((w, code, max(1, int(wt * args.weight_scale))))

    # 键名字优先：同码词压到键名字之下（如 tttt 的 笔笔/竹笙 不能压住 禾，§4.76）
    kcaps = keyname_caps(DICTS)
    capped = 0
    fixed = []
    for w, c, wt in rows:
        new_wt, was_capped = cap_weight(c, wt, kcaps)
        capped += 1 if was_capped else 0
        fixed.append((w, c, new_wt))
    rows = fixed
    if capped:
        print(f"  键名字优先：压权重 {capped} 条")

    rows.sort(key=lambda r: -r[2])
    path = os.path.join(DICTS, args.out + ".dict.yaml")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        f.write("# RIME dictionary\n# 由 scripts/gen_wubi_86_longtail.py 生成，请勿手改\n")
        f.write(f"# 五笔 86 词组码长尾（二字词，权重 {args.weight_min}~{args.weight_max}，"
                f"已排除 base 已有词）\n")
        f.write("# 码规则：字→86 两码自举自 wb86_base（回验 100%）；权重沿用万象\n")
        f.write(f"name: {args.out}\nversion: \"2026.10\"\nsort: by_weight\n")
        f.write("use_preset_vocabulary: false\ncolumns:\n  - text\n  - code\n  - weight\n...\n")
        for w, c, wt in rows:
            f.write(f"{w}\t{c}\t{wt}\n")
    os.replace(path + ".tmp", path)
    print(f"写出 {path}：{len(rows):,} 词（跳过无字码 {skipped}）")


if __name__ == "__main__":
    main()
