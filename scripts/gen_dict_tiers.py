#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""词典分档：同一套词源按权重切成 core / base / full 三档，**五笔码与拼音码同步分层**。

设计（见 docs/PROGRESS.md §9 决策）：

    层              是否随档位变化   理由
    字表(chars)     否              字是基础，简码/全码属肌肉记忆层
    传统库词(86码)  是(按权重过滤)   3 键/4 键词组，长尾对普通用户是噪声
    混合库词(万象码) 是(按权重过滤)   概率层，长尾交给 gram / 用户造词
    拼音词(无调)    是(按权重过滤)   与混合库同步，保证「拼音也能打全」
    拼音字表(8105)  否              字级基础

档位定义（阈值来自 base.dict.yaml 权重分布实测：p50=165 / p90=426 / p99=656）：

    core  >= 571   ≈ 2.0 万词   日常九成，体积最小
    base  >= 451   ≈ 6.3 万词   现状默认
    full  >  0     ≈ 78  万词   尽量全（叠加语料新词后还会增长）

产物（dicts/）：
    egret_wubi_words_wangxiang_{tier}.dict.yaml         混合库五笔词（万象逗号码，供 script_translator）
    egret_wubi_words_wb86_{tier}.dict.yaml       传统库五笔词（86 造词码，供 table_translator）
    egret_py_words_{tier}.dict.yaml  拼音词（无调音节）

切换：`make tier TIER=core|base|full`（改写两个包装 dict 的 import_tables）。

用法:
  python3 scripts/gen_dict_tiers.py                 # 生成三档
  python3 scripts/gen_dict_tiers.py --tier base     # 只生成某档
  python3 scripts/gen_dict_tiers.py --stats         # 只打印各档规模
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402

DICTS = rime_paths.DICTS
OUT = DICTS
SRC_WUBI = os.path.join(DICTS, "wb86_wangxiang_cn_dicts", "base.dict.yaml")
SRC_WUBI_TRAD = os.path.join(OUT, "egret_wubi_words_wb86_src.dict.yaml")
SRC_PINYIN = os.path.join(OUT, "egret_py_words_src.dict.yaml")

# tier -> 最低权重（含）。base 与现状一致：万象 base.small 用的是 > 450
TIERS = {
    "core": 571,
    "base": 451,
    "full": 0,      # 只要求 >0，滤掉权重为 0 的占位条目
}
TIER_DESC = {
    "core": "≈2.0 万词，日常九成，体积最小",
    "base": "≈6.3 万词，默认档",
    "full": "≈78 万词，尽量全（长尾交给 gram）",
}

# --- 键名字优先（王码「25 键名字四连击」规则，见 scripts/keyname_priority.py）---
# 用户实测：kkkk → 串串(593) 压住 口(544)。规则与实现细节见 §4.76。
from keyname_priority import KEYNAME_4, caps as keyname_caps, cap_weight  # noqa: E402

CAP_STATS = {}      # code -> [(词, 原权重)]，仅用于打印


def header(name, comment_lines):
    out = ["# RIME dictionary", "# 由 scripts/gen_dict_tiers.py 生成，请勿手改",
           "", "name: " + name, 'version: "2026.09.27"', "sort: by_weight",
           "use_preset_vocabulary: false", "columns:", "  - text", "  - code",
           "  - weight", "..." ]
    for c in comment_lines:
        out.insert(2, "# " + c)
    return "\n".join(out) + "\n"


def rows(path):
    """读 dict.yaml 的正文（... 之后），yield (word, code, weight)。"""
    started = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not started:
                if line.rstrip() == "...":
                    started = True
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) >= 3 and p[2].isdigit():
                yield p[0], p[1], int(p[2])


def write_tier(kind, src, tier, minw, note, prefix="egret_wubi_py", caps=None):
    """按权重过滤写出一个档位文件，返回条目数。

    caps: {码: 权重上限}，用于「键名字优先」（见 KEYNAME_4）；传 None 表示不改权重。
    """
    name = f"{prefix}_{kind}_{tier}"
    out_path = os.path.join(OUT, name + ".dict.yaml")
    n = 0
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(header(name, [f"{note}｜档位 {tier}（{TIER_DESC[tier]}）",
                              f"权重 >= {minw}（源: {os.path.relpath(src, REPO)}）"]))
        for w, code, weight in rows(src):
            if caps:
                code = code.strip()
                new_weight, capped = cap_weight(code, weight, caps)
                if capped:
                    CAP_STATS.setdefault(code, []).append((w, weight))
                    weight = new_weight
            if weight >= minw:
                f.write(f"{w}\t{code}\t{weight}\n")
                n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="all",
                    choices=["all", "core", "base", "full"])
    ap.add_argument("--stats", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(SRC_WUBI):
        sys.exit(f"缺少源文件: {SRC_WUBI}")

    jobs = [
        # (kind, 源, 说明, 文件名前缀)  前缀决定命名族：只五笔 egret_wubi_*、
        # 只拼音 egret_py_*、五笔+拼音 egret_wubi_py_*
        # 传统库（86 造词码）2016-09 改名为 egret_wubi_*（与 schema/根包装一致，对齐上游）
        ("words_wangxiang", SRC_WUBI, "混合库五笔词（万象逗号码）", "egret_wubi"),
        ("words_wb86", SRC_WUBI_TRAD, "传统库五笔词（86 造词码）", "egret_wubi"),
        # 只含拼音 -> egret_py_*（命名规则见 AGENTS.md）
        ("words", SRC_PINYIN, "拼音词（无调音节）", "egret_py"),
    ]
    tiers = list(TIERS) if args.tier == "all" else [args.tier]

    for kind, src, note, prefix in jobs:
        if not os.path.exists(src):
            print(f"  ! 跳过 {kind}: 源文件缺失 {src}")
            continue
        # 键名字优先只对**传统库词**（86 造词码，纯 4 字母）生效；混合库词是逗号
        # token（如 串串 = "kk,hk kk,hk"），码要运行时由 algebra 派生，此处不匹配。
        caps = keyname_caps(DICTS) if kind == "words_wb86" else None
        for tier in tiers:
            minw = TIERS[tier]
            n = write_tier(kind, src, tier, minw, note, prefix, caps)
            print(f"  {kind:<14} {tier:<5} >= {minw:<4} {n:>7} 条")

    if CAP_STATS and args.tier != "stats":
        tot = sum(len(v) for v in CAP_STATS.values())
        print(f"\n键名字优先（王码 25 键名字四连击）：压权重 {tot} 条条目 / "
              f"{len(CAP_STATS)} 个码")
        for code in sorted(CAP_STATS, key=lambda c: -max(w for _, w in CAP_STATS[c])):
            items = ", ".join(f"{w}({w0})" for w, w0 in
                              sorted(CAP_STATS[code], key=lambda x: -x[1])[:3])
            print(f"  {code} {KEYNAME_4.get(code, '')}: {items}")

    if args.tier == "all" or args.stats:
        print("\n档位规模合计（三套码相加）：")
        for tier in TIERS:
            tot = 0
            for kind, src, _, prefix in jobs:
                if not os.path.exists(src):
                    continue
                p = os.path.join(OUT, f"{prefix}_{kind}_{tier}.dict.yaml")
                if os.path.exists(p):
                    tot += sum(1 for _ in rows(p))
            print(f"  {tier:<5} {tot:>8} 条  （{TIER_DESC[tier]}）")


if __name__ == "__main__":
    main()
