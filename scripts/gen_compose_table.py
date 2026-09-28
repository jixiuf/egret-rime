#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成统一"码 → 词"表，供 Lua 搜索器同时支持 五笔码 / 拼音 / 混流。

为什么需要（用户实测的 bug）：
    用五笔打 `qktqn`（q=我, kt=吃, qn=饭）得不到「我吃饭」。
    根因有两条，librime 的设计决定的：
      1) `qktq` 精确匹配传统词组「名称」→ script_translator 判定
         "has_reliable_phrase" → **整个输入不再组句**（docs §6 已记录）
      2) 简码歧义：kt 简码同时属于「吃/呼」，靠权重决定
    自建搜索器不走 librime 的翻译路径，两个问题都不存在。

本表把四个词典源合成一张表（词/字 + 可输入的码串 + 权重）：
    egret_wubi_py_chars            五笔码字（含一/二/三级简码与全码，逗号=简码,剩余）
    egret_wubi_py_pinyin_8105      拼音字（音节）
    egret_wubi_words_base  五笔词组（86 造词码，单码）
    egret_wubi_py_pinyin_base_small 拼音词（音节串）
**权重用我们语料的 log 词频**（与 LM 同尺度，跨码表可比），词表只决定"哪些码能用"。

输出: data/gram/compose_table.tsv   text <TAB> code <TAB> weight <TAB> kind

用法: python3 scripts/gen_compose_table.py [--tier base]
"""
import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "corpus"))
import rime_paths  # noqa: E402

D = os.path.join(rime_paths.DICTS, "egret_wubi_py")
GRAM = rime_paths.GRAM_DIR
FREQ = os.path.join(rime_paths.DATA, "corpus", "freq", "recount_full.txt")


def rows(path):
    started = False
    if not os.path.exists(path):
        return
    for line in open(path, encoding="utf-8"):
        if not started:
            if line.rstrip() == "...":
                started = True
            continue
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3 and p[2].isdigit():
            yield p[0], p[1], int(p[2])


def wubi_forms(code):
    """混合库的逗号码 'kb,sk' → 可输入形式：全码 'kbsk' 与简码前缀 'kb'。"""
    toks = code.split()
    forms = []
    # 逐字：把 'kb,sk' 拆成 ['kb','sk'] → 全码连写 kbsk；首段连写 kbsk 的简码形式 kb
    full = ""
    short = ""
    for t in toks:
        parts = t.split(",")
        full += "".join(parts)
        short += parts[0]
    forms.append(full)
    if short and short != full:
        forms.append(short)
    return forms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", default="base")
    ap.add_argument("--out", default=os.path.join(GRAM, "compose_table.tsv"))
    args = ap.parse_args()

    # 语料词频（log 尺度权重）
    freq = {}
    if os.path.exists(FREQ):
        for line in open(FREQ, encoding="utf-8"):
            q = line.rstrip("\n").split("\t")
            if len(q) >= 3 and q[2].isdigit():
                freq[q[0]] = int(q[2])
    lm = os.path.join(GRAM, "lm_rerank.tsv")
    if os.path.exists(lm):
        for line in open(lm, encoding="utf-8"):
            k, _, v = line.rstrip("\n").partition("\t")
            if len(k) == 1 and v.isdigit():
                freq["\x01" + k] = int(v)

    def weight(text):
        if len(text) == 1 and ("\x01" + text) in freq:
            return freq["\x01" + text]
        c = freq.get(text)
        return int(round(math.log(1 + c) * 1000)) if c else 0

    seen = set()
    out = []

    def add(text, code, kind):
        code = (code or "").lower()          # 词典里的五笔码是大写，输入是小写
        if not text or not code or not code.isalpha():
            return
        k = (text, code)
        if k in seen:
            return
        seen.add(k)
        out.append((text, code, weight(text), kind))

    # 1) 五笔字：传统库字表（含一级/二级简码 ownership）+ 混合库字表（三级/全码）
    for src in ("egret_wubi_chars.dict.yaml", "egret_wubi_py_chars.dict.yaml"):
        for w, code, _ in rows(os.path.join(D, src)):
            for f in wubi_forms(code):
                add(w, f, "wubi")
    # 2) 拼音字
    for w, code, _ in rows(os.path.join(D, "egret_wubi_py_pinyin_8105.dict.yaml")):
        add(w, code.replace(" ", ""), "pinyin")
    # 3) 五笔词（86 造词码）
    for w, code, _ in rows(os.path.join(D, f"egret_wubi_words_{args.tier}.dict.yaml")):
        add(w, code.replace(" ", ""), "wubi")
    # 4) 拼音词
    for w, code, _ in rows(os.path.join(D, f"egret_wubi_py_pinyin_words_{args.tier}.dict.yaml")):
        add(w, code.replace(" ", ""), "pinyin")

    out.sort(key=lambda x: (x[1], -x[2]))
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for text, code, w, kind in out:
            f.write(f"{text}\t{code}\t{w}\t{kind}\n")
    os.replace(tmp, args.out)
    n_wubi = sum(1 for x in out if x[3] == "wubi")
    n_py = len(out) - n_wubi
    print(f"统一码表 {len(out):,} 条（五笔 {n_wubi:,} / 拼音 {n_py:,}）"
          f" -> {args.out} ({os.path.getsize(args.out)/2**20:.1f} MB)")
    print("  示例:", [(t, c) for t, c, _, _ in out[:3]])


if __name__ == "__main__":
    main()
