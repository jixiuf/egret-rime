#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""词级 n-gram 表：给 Lua 搜索器（py_composer）一张**词级**语言模型。

为什么（docs/PROGRESS.md §4.89）：
    搜索器（py_composer）负责混打长句的搜索，但它原来只用「词权重 + **字级** n-gram 增益」，
    字面频率会把同音/同码词带偏 —— 实测 nnxcyiwug（已经就位）被算成「已经义务一」，
    tgynlwtyif（重启输入法）被算成「第一遍输入法」，而引擎的**词级**万象 gram 判得对。
    ⇒ 两条解码链各持一把尺子，弱的那把还能覆盖强的。本表把搜索器的尺子换成词级。

做法：
    1. 采样语料（data/corpus/clean/{short,para}/*.txt，字节预算可控），jieba 分词；
    2. 统计 1/2/3-gram；
    3. 输出**条件对数概率**（增益，×1000）：bigram = log((c(w1,w2)+1)/(c(w1)+1))，
       trigram = log((c(w1,w2,w3)+1)/(c(w1,w2)+1))；
    4. 取 top-K，写成「48-bit 哈希 + i16 值」的定长记录二进制包（键是变长的词序列，
       用哈希排序 + 二分查表，同 gen_lm_rerank 的思路；哈希在 Python/Lua 两侧同实现）。

输出：
    data/gram/lm_words.tsv      可读视图（人看/契约测试用）
    data/gram/lm_words.bin      运行时读的包
    data/gram/lm_words.meta     小元信息

用法:
  python3 scripts/gen_word_lm.py                  # 默认采样 ~200MB
  python3 scripts/gen_word_lm.py --mb 400 --top-bi 400000 --top-tri 400000
"""

import argparse
import collections
import math
import os
import pickle
import struct
import sys
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "corpus"))
import rime_paths  # noqa: E402

SEP = "\x01"
MAGIC = b"EGWL1\0\0\0"
FLOOR = -11500          # 未见 n-gram 的兜底增益（≈ log(1/1e5)*1000）


def hash48(s: bytes) -> int:
    """djb2 双通道 → 48-bit。Lua 侧同实现（纯算术，不依赖位运算版本）。"""
    h1, h2 = 5381, 52711
    for b in s:
        h1 = (h1 * 33 + b) & 0xFFFFFFFF
        h2 = (h2 * 31 + b) & 0xFFFFFFFF
    return h1 * 65536 + (h2 & 0xFFFF)


def key_of(*words):
    return SEP.join(words)


def _seg_chunk(lines):
    import jieba
    jieba.setLogLevel(60)
    out = []
    for line in lines:
        out.append([w for w in jieba.cut(line) if w.strip()])
    return out


def sample_lines(mb, files):
    if not files:
        return []
    per = (mb * 1024 * 1024) // len(files)
    docs = []
    for f in files:
        used = 0
        with open(f, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                used += len(line)
                if used > per:
                    break
                s = line.strip()
                if s:
                    docs.append(s)
    return docs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mb", type=int, default=200, help="采样字节预算（默认 200MB）")
    ap.add_argument("--top-bi", type=int, default=300_000)
    ap.add_argument("--top-tri", type=int, default=300_000)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--out", default=os.path.join(rime_paths.GRAM_DIR, "lm_words.tsv"))
    a = ap.parse_args()

    short = os.path.join(rime_paths.DATA, "corpus", "clean", "short")
    files = [os.path.join(short, f) for f in sorted(os.listdir(short))
             if f.endswith(".txt")] if os.path.isdir(short) else []
    files = [f for f in files if os.path.getsize(f) > 0]
    if not files:
        sys.exit(f"没有可用语料: {short}")

    docs = sample_lines(a.mb, files)
    print(f"采样 {len(docs):,} 行（预算 {a.mb}MB，{len(files)} 个来源）", flush=True)

    chunks = [docs[i::a.jobs] for i in range(a.jobs)]
    with Pool(a.jobs) as p:
        parts = p.map(_seg_chunk, chunks)

    uni = collections.Counter()
    bi = collections.Counter()
    tri = collections.Counter()
    for part in parts:
        for ws in part:
            for w in ws:
                uni[w] += 1
            for x, y in zip(ws, ws[1:]):
                bi[(x, y)] += 1
            for x, y, z in zip(ws, ws[1:], ws[2:]):
                tri[(x, y, z)] += 1
    N = sum(uni.values())
    print(f"词 {N:,}  词型 {len(uni):,}  bigram {len(bi):,}  trigram {len(tri):,}",
          flush=True)

    def topk(counter, k):
        return counter.most_common(k)

    rows = []       # (kind, key, value)
    for (x, y), c in topk(bi, a.top_bi):
        cp = uni.get(x, 0)
        v = int(round(math.log((c + 1) / (cp + 1)) * 1000))
        rows.append(("bi", key_of(x, y), v))
    for (x, y, z), c in topk(tri, a.top_tri):
        cp = bi.get((x, y), 0)
        v = int(round(math.log((c + 1) / (cp + 1)) * 1000))
        rows.append(("tri", key_of(x, y, z), v))

    # 可读视图
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out + ".tmp", "w", encoding="utf-8") as f:
        for kind, key, v in sorted(rows):
            f.write(f"{kind}\t{key}\t{v}\n")
    os.replace(a.out + ".tmp", a.out)

    # 二进制包：8B magic + 4B bi_count + 4B tri_count + 各自的 (48-bit hash 6B + i16 2B)
    bins = {"bi": [], "tri": []}
    for kind, key, v in rows:
        v = max(-32768, min(32767, v))
        bins[kind].append((hash48(key.encode("utf-8")), v))
    out_bin = a.out[:-4] + ".bin"
    with open(out_bin + ".tmp", "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<I", len(bins["bi"])))
        f.write(struct.pack("<I", len(bins["tri"])))
        for kind in ("bi", "tri"):
            for h, v in sorted(bins[kind]):
                f.write(h.to_bytes(6, "little"))
                f.write(struct.pack("<h", v))
    os.replace(out_bin + ".tmp", out_bin)

    meta = (f"source=clean/short sample {a.mb}MB\nwords={N} types={len(uni)} "
            f"bigrams={len(bi)} trigrams={len(tri)}\n"
            f"kept_bi={len(bins['bi'])} kept_tri={len(bins['tri'])}\n"
            f"floor={FLOOR}\n")
    with open(a.out[:-4] + ".meta", "w", encoding="utf-8") as f:
        f.write(meta)
    print(f"写出 {a.out} / {os.path.basename(out_bin)}"
          f"（bi {len(bins['bi']):,} tri {len(bins['tri']):,}，"
          f"{os.path.getsize(out_bin)/2**20:.1f}MB）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
