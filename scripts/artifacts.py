#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""最终产物清单：一条命令看清「这个项目产出了什么」。

refresh.sh 的 artifacts 阶段调用；也可单独跑:
  python3 scripts/artifacts.py
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "corpus"))
import rime_paths  # noqa: E402

OUT = rime_paths.DICTS
GRAM = rime_paths.GRAM_DIR
TIERS = ("core", "base", "full")
TIER_DESC = {"core": "≈2万词  日常九成", "base": "≈6.3万词 默认",
             "full": "≈78万词 尽量全"}
KINDS = [("words", "五笔词(万象码)"), ("wubi_words", "五笔词(86造词码)"),
         ("pinyin_words", "拼音词(无调)")]


def count_entries(path):
    n = 0
    started = False
    if not os.path.exists(path):
        return 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not started:
                if line.rstrip() == "...":
                    started = True
                continue
            if "\t" in line:
                n += 1
    return n


def mb(path):
    try:
        return os.path.getsize(path) / 2 ** 20
    except OSError:
        return 0.0


def main():
    print("═" * 78)
    print("最终产物清单")
    print("═" * 78)

    # 1. 词库
    print("\n【1】词库  dicts/  （每档同时含五笔码与拼音码）")
    active = ""
    for w in ("egret_wubi_py.dict.yaml", "egret_wubi.dict.yaml"):
        p = os.path.join(REPO, w)
        if os.path.exists(p):
            m = re.search(r"egret_wubi_py_(?:words|wubi_words|pinyin_words)_(core|base|full)",
                          open(p, encoding="utf-8").read())
            if m:
                active = m.group(1)
                break
    print(f"  当前档位: \033[1m{active or '(未分档)'}\033[0m"
          f"   （切换: bash scripts/refresh.sh --tier core|base|full）\n")
    print(f"  {'档位':<6} {'说明':<18} " +
          "  ".join(f"{d:>16}" for _, d in KINDS) + "   体积")
    for t in TIERS:
        row, tot = [], 0.0
        for kind, _ in KINDS:
            p = os.path.join(OUT, f"egret_wubi_py_{kind}_{t}.dict.yaml")
            row.append(f"{count_entries(p):>16,}")
            tot += mb(p)
        mark = "→" if t == active else " "
        print(f" {mark}{t:<6} {TIER_DESC[t]:<18} " + "  ".join(row) +
              f"  {tot:>5.1f}M")
    print("\n  字表（不随档位变）:")
    for f in ("egret_wubi_py_chars.dict.yaml", "egret_wubi_py_pinyin_8105.dict.yaml"):
        p = os.path.join(OUT, f)
        print(f"    {f:<40} {count_entries(p):>8,} 条  {mb(p):>5.1f}M")

    # 2. 语言模型
    print("\n【2】语言模型  data/gram/")
    for p in sorted(glob.glob(os.path.join(GRAM, "*.gram"))):
        tag = " ← 自训" if "egret" in os.path.basename(p) else ""
        print(f"    {os.path.basename(p):<34} {mb(p):>7.1f} MB{tag}")

    # 3. 语料账本
    print("\n【3】语料账本  data/")
    for name, path in (("抽取产物 extract/", os.path.join(rime_paths.DATA, "corpus", "extract")),
                       ("清洗产物 clean/", os.path.join(rime_paths.DATA, "corpus", "clean")),
                       ("开源语料 input/open/", os.path.join(rime_paths.DATA, "input", "open"))):
        tot = 0
        for dp, _d, fs in os.walk(path):
            for f in fs:
                try:
                    tot += os.path.getsize(os.path.join(dp, f))
                except OSError:
                    pass
        print(f"    {name:<24} {tot / 2**30:>7.2f} GB")
    wf = os.path.join(rime_paths.DATA, "corpus", "freq", "recount_full.txt")
    if os.path.exists(wf):
        n = sum(1 for _ in open(wf, encoding="utf-8"))
        print(f"    {'词频重扫 recount':<24} {n:>9,} 词条")

    print("\n" + "═" * 78)
    print("使用：bash scripts/refresh.sh --deploy    # 重新生成并部署到输入法")
    print("═" * 78)


if __name__ == "__main__":
    main()
