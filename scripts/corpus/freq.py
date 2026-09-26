#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段 freq：语料分词 + 词频统计（供词典构建）。

输入: data/corpus/clean/para/<格式>.txt（整段语料，保留原字形与标点）
输出:
    data/corpus/freq/by_source/<格式>.tsv   word <TAB> count   （按来源）
    data/corpus/freq/word_freq.tsv          word <TAB> count <TAB> weight <TAB> sources
    data/corpus/meta/freq_fingerprints.json 各来源 (size,mtime) 指纹（增量用）

设计:
    - 分词用 jieba（HMM=False，确定性；可注入领域词典）。
    - 只保留纯汉字词（长度 1~8），丢掉标点/数字/拉丁，避免污染词表。
    - 词频可加量：增量运行时只重算指纹变化的来源，再与已有计数合并。
    - 权重 = log-norm 0..1000（与词库现有刻度一致，便于直接对齐）。

用法:
  python3 scripts/corpus/freq.py                    # 增量
  python3 scripts/corpus/freq.py --jobs 4 --nice 15
  python3 scripts/corpus/freq.py --force            # 全量重算
  python3 scripts/corpus/freq.py --min-count 3      # 输出时过滤低频
"""

import argparse
import collections
import concurrent.futures as cf
import glob
import json
import math
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C          # noqa: E402

FREQ_SRC = os.path.join(C.FREQ, "by_source")
WORD_FREQ = os.path.join(C.FREQ, "word_freq.tsv")
FINGERPRINTS = os.path.join(C.META, "freq_fingerprints.json")
PARA_DIR = os.path.join(C.CLEAN, "para")

CJK_WORD = re.compile(r"^[\u4e00-\u9fff\u3400-\u4dbf]{1,8}$")
CHUNK = 20000          # 每个任务的行数

_W = {}


def _init_worker():
    import jieba
    jieba.initialize()
    _W["cut"] = jieba.cut


def _count_chunk(lines):
    cut = _W["cut"]
    c = collections.Counter()
    for line in lines:
        for w in cut(line, HMM=False):
            if CJK_WORD.match(w):
                c[w] += 1
    return c


def fingerprint(path):
    st = os.stat(path)
    return [st.st_size, int(st.st_mtime)]


def load_json(path, default):
    if os.path.exists(path):
        try:
            return json.load(open(path, encoding="utf-8"))
        except ValueError:
            pass
    return default


def count_file(path, jobs):
    """并行统计单个文件，返回 (Counter, 行数)。

    手动有界提交：最多占用 jobs*4 个在途任务，边完成边聚合，
    避免一次性提交几十万个 future（内存爆）。
    """
    agg = collections.Counter()
    total = 0
    pending = collections.deque()
    with cf.ProcessPoolExecutor(max_workers=jobs,
                                initializer=_init_worker) as ex:
        buf = []
        with open(path, encoding="utf-8") as f:
            for line in f:
                buf.append(line.rstrip("\n"))
                total += 1
                if len(buf) >= CHUNK:
                    pending.append(ex.submit(_count_chunk, buf))
                    buf = []
                    while len(pending) >= jobs * 4:
                        agg.update(pending.popleft().result())
        if buf:
            pending.append(ex.submit(_count_chunk, buf))
        while pending:
            agg.update(pending.popleft().result())
    return agg, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--nice", type=int, default=15)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--min-count", type=int, default=2,
                    help="输出 word_freq.tsv 时的最低词频")
    args = ap.parse_args()

    th = C.throttle(args.nice)
    os.makedirs(FREQ_SRC, exist_ok=True)
    fps = {} if args.force else load_json(FINGERPRINTS, {})

    files = sorted(glob.glob(os.path.join(PARA_DIR, "*.txt")))
    if not files:
        sys.exit("没有 clean/para 语料，先跑阶段 clean")
    print(f"限流: {th}   并发: {args.jobs}")
    print(f"来源 {len(files)} 个")

    t0 = time.time()
    for path in files:
        fmt = os.path.basename(path)[:-4]
        fp = fingerprint(path)
        out = os.path.join(FREQ_SRC, f"{fmt}.tsv")
        if not args.force and fps.get(fmt) == fp and os.path.exists(out):
            print(f"  {fmt}: 未变化，跳过（{fp[0]/2**20:.0f} MB）")
            continue
        t1 = time.time()
        agg, total = count_file(path, args.jobs)
        tmp = out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            for w, c in agg.most_common():
                f.write(f"{w}\t{c}\n")
        os.replace(tmp, out)
        fps[fmt] = fp
        print(f"  {fmt}: {total} 行 -> {len(agg)} 词，用时 {(time.time()-t1)/60:.1f} min")
        json.dump(fps, open(FINGERPRINTS, "w", encoding="utf-8"),
                  ensure_ascii=False)

    # 合并各来源
    merged = collections.Counter()
    src_of = collections.defaultdict(set)
    for path in sorted(glob.glob(os.path.join(FREQ_SRC, "*.tsv"))):
        fmt = os.path.basename(path)[:-4]
        with open(path, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) == 2 and p[1].isdigit():
                    merged[p[0]] += int(p[1])
                    src_of[p[0]].add(fmt)
    cmax = max(merged.values()) if merged else 1
    logmax = math.log(1 + cmax)
    kept = 0
    with open(WORD_FREQ + ".tmp", "w", encoding="utf-8") as f:
        f.write("# word\tcount\tweight\tsources\n")
        for w, c in merged.most_common():
            if c < args.min_count:
                continue
            weight = max(1, int(round(1000.0 * math.log(1 + c) / logmax)))
            f.write(f"{w}\t{c}\t{weight}\t{','.join(sorted(src_of[w]))}\n")
            kept += 1
    os.replace(WORD_FREQ + ".tmp", WORD_FREQ)
    print(f"\n合并: 去重词 {len(merged)}，输出(≥{args.min_count}) {kept} 条")
    print(f"词频表: {WORD_FREQ}  ({os.path.getsize(WORD_FREQ)/2**20:.1f} MB)")
    print(f"总用时 {(time.time()-t0)/60:.1f} min")


if __name__ == "__main__":
    main()
