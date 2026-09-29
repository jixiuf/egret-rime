#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从仓库内数据生成拼音词表（替代缺失的万象 base.small.dict.yaml）。

背景（见 docs/PROGRESS.md）：
    `gen_wubi_py_unified_dicts.py` 的 `gen_pinyin_toneless("wangxiang_cn_dicts/
    base.small.dict.yaml", ...)` 需要一个**本仓库没有**的万象文件（旧版命名，
    上游已迁移），导致整条 gen 管线跑不通、拼音词表事实上变成"入库源数据"。

本脚本把这步变成**可复现**：词表来自仓库内已有的五笔词表（base.dict.yaml，
词 + 万象权重），拼音码用 pypinyin 现场标注。同时比原方案更好：

    1. **多音字给出多个读音**（原方案只有一个读音）→ 用户按任一读音都能打出
       该词。实现上为每个词生成若干读音组合（上限 `--max-readings`），
       非首个读音给权重折扣（`--alt-discount`），避免与主读音同权。
    2. 权重沿用五笔词表（万象）不变——**不动权重平衡**（实测单侧改动会破黄金用例）

输出（**gen_dict_tiers.py 读取的规范名**，再由它派生出各档）：
    dicts/egret_py_words_src.dict.yaml

实测（见 docs/PROGRESS.md）：
    仅主读音 == 原万象表（都是 63k 条 / 26% 完全命中）→ 质量无损、依赖可移除
    多音字展开（3 读音 / 111k 条）反而差（19%）→ 默认只用主读音

用法:
  python3 scripts/gen_pinyin_words.py                 # 三档
  python3 scripts/gen_pinyin_words.py --tier base
  python3 scripts/gen_pinyin_words.py --max-readings 4 --alt-discount 0.85
"""

import argparse
import itertools
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "corpus"))
import rime_paths  # noqa: E402

DICTS = rime_paths.DICTS
OUT = DICTS
SRC = os.path.join(DICTS, "wb86_wangxiang_cn_dicts", "base.dict.yaml")
TIERS = {"core": 571, "base": 451, "full": 0}
TIER_DESC = {"core": "≈2万词", "base": "≈6.3万词 默认", "full": "≈78万词"}


def header(name, comment_lines):
    out = ["# RIME dictionary", "# 由 scripts/gen_pinyin_words.py 生成，请勿手改"]
    out += ["# " + c for c in comment_lines]
    out += ["", "name: " + name, 'version: "2026.09.28"', "sort: by_weight",
            "use_preset_vocabulary: false", "columns:", "  - text", "  - code",
            "  - weight", "..."]
    return "\n".join(out) + "\n"


def rows(path):
    started = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not started:
                if line.rstrip() == "...":
                    started = True
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) >= 3 and p[2].isdigit():
                yield p[0], int(p[2])


def readings(word, py, max_readings):
    """词的读音组合：主读音在前，其余组合去重，最多 max_readings 个。"""
    per = []
    for ch in word:
        r = py(ch, heteronym=True)
        opts = r[0] if r else [""]
        per.append(opts[:3])                      # 每个字最多取 3 个读音
    combos, seen = [], set()
    for combo in itertools.islice(itertools.product(*per), 0, 64):
        if any(not s for s in combo):
            continue
        code = " ".join(combo)
        if code in seen:
            continue
        seen.add(code)
        combos.append(code)
        if len(combos) >= max_readings:
            break
    return combos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="all",
                    choices=["all", "core", "base", "full"])
    ap.add_argument("--max-readings", type=int, default=1,
                    help="每个词最多生成几个读音。实测 1=与原万象表等价(26%%)；"
                         "3 会掉到 19%%（多读音让分段歧义变大），故默认 1")
    ap.add_argument("--alt-discount", type=float, default=0.8,
                    help="非主读音的权重折扣")
    ap.add_argument("--src", default=SRC)
    args = ap.parse_args()

    if not os.path.exists(args.src):
        sys.exit(f"缺少词源: {args.src}")
    from pypinyin import pinyin as _pinyin, Style
    py = lambda ch, heteronym: _pinyin(ch, style=Style.NORMAL,
                                       heteronym=heteronym)

    all_rows = list(rows(args.src))
    print(f"词源 {os.path.basename(args.src)}: {len(all_rows):,} 条")

    # 只产出规范名的 base 表；各档由 gen_dict_tiers.py 从它派生
    tiers = list(TIERS) if args.tier == "all" else [args.tier]
    for tier in tiers:
        minw = TIERS[tier]
        n = 0
        multi = 0
        name = ("egret_py_words_src" if tier == "base"
                else f"egret_wubi_py_pinyin_words_{tier}")
        tmp = os.path.join(OUT, name + ".dict.yaml.tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(header(name, [
                f"拼音词表（无调音节）｜档位 {tier}（{TIER_DESC[tier]}）",
                "词与权重沿用五笔词表（不动权重平衡）；",
                "拼音码由 pypinyin 标注，多音字给出多个读音",
                f"（最多 {args.max_readings} 个读音，非主读音权重 ×{args.alt_discount}）",
            ]))
            for word, weight in all_rows:
                if weight < minw:
                    continue
                rs = readings(word, py, args.max_readings)
                if not rs:
                    continue
                if len(rs) > 1:
                    multi += 1
                for i, code in enumerate(rs):
                    w = weight if i == 0 else max(1, int(weight * args.alt_discount))
                    f.write(f"{word}\t{code}\t{w}\n")
                    n += 1
        os.replace(tmp, os.path.join(OUT, name + ".dict.yaml"))
        print(f"  {tier:<5} 权重>={minw:<4} 写出 {n:>7,} 条"
              f"（含多音字词 {multi:,}）")

    print("\n注意：这是**独立**的拼音词表来源；若要同时用 gen_dict_tiers，"
          "请确认后者不再覆盖同名文件（见 docs/PROGRESS.md 生成顺序）")


if __name__ == "__main__":
    main()
