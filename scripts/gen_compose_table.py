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
    egret_py_chars      拼音字（音节）
    egret_wubi_words_wb86_base  五笔词组（86 造词码，单码）
    egret_py_words_src 拼音词（音节串）
**权重用我们语料的 log 词频**（与 LM 同尺度，跨码表可比），词表只决定"哪些码能用"。

输出: data/gram/compose_table.tsv   text <TAB> code <TAB> weight <TAB> kind

用法: python3 scripts/gen_compose_table.py [--tier base]
"""
import struct
import argparse
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "corpus"))
import rime_paths  # noqa: E402

D = rime_paths.DICTS
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


def write_pack(rows, out):
    """把码表写成**定长索引 + 变长记录**的二进制包，供 Lua 二分查前缀（不建哈希）。

    格式（全部小端）：
      0   8B  magic "EGCT1\0\0\0"
      8   4B  count (u32)
      12  4B  保留
      16  4B*count  记录偏移（绝对偏移，按 code 升序）
      之后         记录：u8 codelen | code | u8 kind | u16 weight | u8 textlen | text
    kind: 0=wubi 1=pinyin。表本身已按 (code, -weight) 排序，故索引天然有序。
    """
    KIND = {"wubi": 0, "pinyin": 1}
    buf = []; offs = []; off = 16 + 4 * len(rows)   # 滚动偏移（别用 sum(buf)：那是 O(n²)，实测卡死）
    for text, code, w, kind in rows:                # 已按 code 排序
        cb = code.encode("utf-8"); tb = text.encode("utf-8")
        rec = (struct.pack("<B", len(cb)) + cb +
               struct.pack("<B", KIND.get(kind, 2)) +
               struct.pack("<H", min(int(w), 65535)) +
               struct.pack("<B", len(tb)) + tb)
        offs.append(off); off += len(rec); buf.append(rec)
    with open(out, "wb") as f:
        f.write(b"EGCT1\0\0\0" + struct.pack("<I", len(rows)) + struct.pack("<I", 0))
        for o in offs: f.write(struct.pack("<I", o))
        for b in buf: f.write(b)
    print(f"  二进制包: {out} ({os.path.getsize(out)/1048576:.1f} MB, {len(rows):,} 条)")

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
    for w, code, _ in rows(os.path.join(D, "egret_py_chars.dict.yaml")):
        add(w, code.replace(" ", ""), "pinyin")
    # 3) 五笔词（86 造词码）
    for w, code, _ in rows(os.path.join(D, f"egret_wubi_words_wb86_{args.tier}.dict.yaml")):
        add(w, code.replace(" ", ""), "wubi")
    # 4) 拼音词
    for w, code, _ in rows(os.path.join(D, f"egret_py_words_{args.tier}.dict.yaml")):
        add(w, code.replace(" ", ""), "pinyin")
    # 5) 长尾/挖掘词表：与 schema 的 import_tables 保持一致
    # 「组句空间 = 搜索器空间」：搜索器（py_composer，用于 mix_segmentor 判读法 +
    # compose_filter 混打注入）之前只读 base 档词表，而引擎组句还会用 longtail/mined4
    # ⇒ 引擎认识的词搜索器不认识，混打长句里跨字词（如「赶得上」）无法成词，回退单字后
    # 被 grammar 的同音字罚分带偏（§4.86 用 debug 版 librime 验证）。
    for fname, kind in (
        ("egret_py_words_longtail.dict.yaml", "pinyin"),
        ("egret_py_words_mined4.dict.yaml", "pinyin"),
        ("egret_wubi_words_wb86_longtail.dict.yaml", "wubi"),
        ("egret_wubi_words_wb86_mined4.dict.yaml", "wubi"),
    ):
        path = os.path.join(D, fname)
        if not os.path.exists(path):
            continue
        for w, code, _ in rows(path):
            c = code.replace(" ", "")
            # 与 py_composer 的 MAX_CODE_LEN(16) 契约一致（scripts/check_compose_table.lua
            # 会在 make lint 里断言最长码；超长的长句词条对组句也没用）
            if len(c) <= 16:
                add(w, c, kind)

    out.sort(key=lambda x: (x[1], -x[2]))
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for text, code, w, kind in out:
            f.write(f"{text}\t{code}\t{w}\t{kind}\n")
    write_pack(out, args.out[:-4] + ".bin" if args.out.endswith(".tsv") else args.out + ".bin")
    os.replace(tmp, args.out)
    n_wubi = sum(1 for x in out if x[3] == "wubi")
    n_py = len(out) - n_wubi
    print(f"统一码表 {len(out):,} 条（五笔 {n_wubi:,} / 拼音 {n_py:,}）"
          f" -> {args.out} ({os.path.getsize(args.out)/2**20:.1f} MB)")
    print("  示例:", [(t, c) for t, c, _, _ in out[:3]])


if __name__ == "__main__":
    main()
