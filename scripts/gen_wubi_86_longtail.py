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

只做**二字词**：三字词的码式在本仓库 wb86 数据里是 2+1+1（非标准五笔的 1+1+2，见 §4.60），
长尾里 61 万条三字词多为碎片，先不引入。

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
    for w, c, wt in load(SRC_WX):
        if len(w) != 2 or not (args.weight_min <= wt <= args.weight_max):
            continue
        if w in base_words:
            continue
        a, b = c2.get(w[0]), c2.get(w[1])
        if not a or not b:
            skipped += 1
            continue
        rows.append((w, a + b, max(1, int(wt * args.weight_scale))))

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
