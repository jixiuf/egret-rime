#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""jieba 分词 clean/short → clean/segged（词级 gram 的前置步骤）。

为什么需要词级 gram：librime 的 octagram 学的是**词**之间的搭配，而现有
data/gram/zh-hans-egret.gram 是从 clean/short 直接切字符做 2-6gram（见
scripts/corpus/gram.sh），语义与 octagram 并不对齐（见 docs/PROGRESS.md G11）。
本脚本产出空格分隔的词串，后续统计词 n-gram → build_grammar 得到
data/gram/zh-hans-egret-word.gram，再做 A/B。
"""
import glob, os, sys, multiprocessing as mp
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,os.path.dirname(HERE))  # scripts/ 下有 rime_paths.py
import rime_paths
import jieba

SRC=os.path.join(rime_paths.DATA,"corpus","clean","short")
DST=os.path.join(rime_paths.DATA,"corpus","clean","segged")

BATCH=200000      # 每个任务处理多少行（按行段切，便于多进程并行）

def _seg_chunk(args):
    """一个 (源文件, 起行, 终行, 输出分片) 就切一段。"""
    src, lo, hi, out = args
    n = 0
    with open(src, encoding="utf-8", errors="ignore") as fi, \
         open(out, "w", encoding="utf-8") as fo:
        for i, line in enumerate(fi):
            if i < lo: continue
            if i >= hi: break
            ws = [w for w in jieba.cut(line.strip(), HMM=False) if w.strip()]
            if ws:
                fo.write(" ".join(ws) + "\n"); n += 1
    return out, n

def main():
    os.makedirs(DST, exist_ok=True)
    jobs = []
    for f in sorted(glob.glob(os.path.join(SRC, "*.txt"))):
        base = os.path.basename(f)
        with open(f, "rb") as fh:
            total = sum(1 for _ in fh)          # 行数（一次快速扫描）
        for lo in range(0, total, BATCH):
            out = os.path.join(DST, f"{base}.part{lo // BATCH:04d}")
            jobs.append((f, lo, min(lo + BATCH, total), out))
        print(f"  {base}: {total:,} 行 -> {len(range(0, total, BATCH))} 个分片", flush=True)
    # 单进程时用 1 个 worker；否则按核数（留出余量，负载要控制在 12 以内）
    nproc = max(1, min(int(os.environ.get("JOBS", "6")), mp.cpu_count() - 2))
    with mp.Pool(nproc) as pool:
        for out, n in pool.imap_unordered(_seg_chunk, jobs):
            print(f"    {os.path.basename(out)}: {n:,} 行", flush=True)
    print(f"完成，共 {len(jobs)} 个分片 -> {DST}", flush=True)

if __name__=="__main__": main()
