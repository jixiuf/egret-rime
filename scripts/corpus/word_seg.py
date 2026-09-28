#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""jieba 分词 clean/short → clean/segged（词级 gram 的前置步骤）。

为什么需要词级 gram：librime 的 octagram 学的是**词**之间的搭配，而现有
data/gram/zh-hans-egret.gram 是从 clean/short 直接切字符做 2-6gram（见
scripts/corpus/gram.sh），语义与 octagram 并不对齐（见 docs/PROGRESS.md G11）。
本脚本产出空格分隔的词串，后续统计词 n-gram → build_grammar 得到
data/gram/zh-hans-egret-word.gram，再做 A/B。
"""
import glob, os, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,os.path.dirname(os.path.dirname(HERE)))
import rime_paths
import jieba

SRC=os.path.join(rime_paths.DATA,"corpus","clean","short")
DST=os.path.join(rime_paths.DATA,"corpus","clean","segged")

def main():
    os.makedirs(DST,exist_ok=True)
    for f in sorted(glob.glob(os.path.join(SRC,"*.txt"))):
        out=os.path.join(DST,os.path.basename(f))
        n=0
        with open(f,encoding="utf-8",errors="ignore") as fi, open(out,"w",encoding="utf-8") as fo:
            for line in fi:
                ws=[w for w in jieba.cut(line.strip(), HMM=False) if w.strip()]
                if ws: fo.write(" ".join(ws)+"\n"); n+=1
        print(f"  {os.path.basename(f)}: {n} 行 -> {out}", flush=True)

if __name__=="__main__": main()
