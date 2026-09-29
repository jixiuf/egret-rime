#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为 Lua 重排生成紧凑 n-gram 表（不依赖 librime 的 .gram 格式）。

背景（见 docs/PROGRESS.md §4.11/§4.12）：
    librime 的 octagram 把 LM 分数**按段累加**到组句打分里，导致 LM 参与分词
    决策时反而变差（全拼还原 16% vs 不装 LM 24%）。正确架构是：
    **分词只按词库权重（不装 grammar），LM 只对候选整句重排**。
    为了不依赖 librime 补丁，LM 搬到 Lua：本脚本把语料的 n-gram 统计
    压成一张紧凑表，由 lua/lm_rerank.lua 在运行时加载并打分。

输入: data/gram/<language>.2_6gram.tsv（rime-char-gram-builder 的聚合产物，
      列 = ngram<TAB>原始count；键的字符数即 n）
输出: data/gram/lm_rerank.tsv        ngram<TAB>value（value = log(1+count)*1000）
      data/gram/lm_rerank.meta      小元信息（条数/阈值/语言）

用法:
  python3 scripts/gen_lm_rerank.py                      # 默认配置
  python3 scripts/gen_lm_rerank.py --top2 300000 --top3 200000 --top4 100000
"""

import struct
import argparse
import heapq
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "corpus"))
import rime_paths  # noqa: E402


def write_bin(tsv, out):
    """把 TSV 蒸馏成**定长记录**的二进制包，供 Lua 二分查表（不建哈希）。

    格式（全部小端）：
      0   magic "EGLM1\0\0\0" (8B)
      8   档数 u8 = 6 + 3B 填充
      12  每档记录数 u32 × 6           (档 = 1..6 字)
      36  各档数据依次排列，每条记录 = 键(3L 字节，CJK 一字 3 字节) + 值 u16
    定长记录让二分可以纯算术定位，不需要偏移索引；键按字节序排序，
    与 Lua 的字符串比较（逐字节无符号）一致。
    """
    by={n:[] for n in range(1,7)}
    for line in open(tsv,encoding="utf-8"):
        k,_,v=line.rstrip("\n").partition("\t")
        if not v.isdigit(): continue
        kb=k.encode("utf-8")
        if 1<=len(k)<=6 and len(kb)==3*len(k):
            by[len(k)].append((kb,min(int(v),65535)))
    with open(out,"wb") as f:
        f.write(b"EGLM1\0\0\0"+bytes([6,0,0,0]))
        for L in range(1,7): f.write(struct.pack("<I",len(by[L])))
        for L in range(1,7):
            for kb,v in sorted(by[L]):
                f.write(kb); f.write(struct.pack("<H",v))
    print(f"  二进制包: {out} ({os.path.getsize(out)/1048576:.1f} MB, {sum(len(v) for v in by.values()):,} 条)")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(
        rime_paths.GRAM_DIR, "zh-hans-egret.2_6gram.tsv"))
    ap.add_argument("--out", default=os.path.join(
        rime_paths.GRAM_DIR, "lm_rerank.tsv"))
    # 扩容：5/6gram 是"跨词搭配"的关键证据（如 P(理|钟经) 类三元组）,
    # 而旧版只到 4gram 且总量仅 60 万条，大量格子被丢弃
    ap.add_argument("--top2", type=int, default=600_000)
    ap.add_argument("--top3", type=int, default=600_000)
    ap.add_argument("--top4", type=int, default=400_000)
    ap.add_argument("--top5", type=int, default=200_000)
    ap.add_argument("--top6", type=int, default=100_000)
    args = ap.parse_args()

    if not os.path.exists(args.src):
        sys.exit(f"缺少 n-gram 聚合数据: {args.src}\n"
                 f"先跑 scripts/corpus/gram.sh 生成")

    want = {2: args.top2, 3: args.top3, 4: args.top4,
            5: args.top5, 6: args.top6}
    heaps = {n: [] for n in want}          # 每个长度维护 top-K 小顶堆
    char_count = {}                        # 1-gram 频次（从 2gram 前缀累加）

    total = kept = 0
    with open(args.src, encoding="utf-8") as f:
        for line in f:
            k, _, v = line.rstrip("\n").partition("\t")
            if not v.isdigit():
                continue
            total += 1
            c = int(v)
            n = len(k)
            if n == 2:
                char_count[k[0]] = char_count.get(k[0], 0) + c
            h = heaps.get(n)
            if h is None:
                continue
            if len(h) < want[n]:
                heapq.heappush(h, (c, k))
            elif c > h[0][0]:
                heapq.heapreplace(h, (c, k))

    import math
    rows = []
    # 1-gram：用作条件概率的分母（value = log(1+count)*1000）
    for ch, c in char_count.items():
        rows.append((ch, int(round(math.log(1 + c) * 1000))))
    for n, h in heaps.items():
        for c, k in h:
            rows.append((k, int(round(math.log(1 + c) * 1000))))
    rows.sort(key=lambda x: x[0])
    kept = len(rows)

    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for k, v in rows:
            f.write(f"{k}\t{v}\n")
    os.replace(tmp, args.out)

    total_chars = sum(char_count.values())
    meta = args.out[:-4] + ".meta"
    with open(meta, "w", encoding="utf-8") as f:
        f.write(f"source={os.path.basename(args.src)}\n")
        f.write(f"top2={args.top2} top3={args.top3} top4={args.top4}\n")
        f.write(f"entries={kept}\n")
        f.write(f"total_chars={total_chars}\n")
    write_bin(args.out, args.out[:-4] + ".bin")   # 运行时用这个（Lua 二分查表）
    print(f"输入 {total:,} 条 → 输出 {kept:,} 条（含 1gram {len(char_count):,}）")
    for n in (2, 3, 4, 5, 6):
        got = sum(1 for k, _ in rows if len(k) == n)
        print(f"  {n}gram: {got:,}")
    print(f"表: {args.out}  {os.path.getsize(args.out)/2**20:.1f} MB")


if __name__ == "__main__":
    main()
