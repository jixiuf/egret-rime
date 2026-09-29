#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为 Lua 版「带 LM 的搜索」生成词表与音节表。

背景（docs/PROGRESS.md §4.x）：librime 的组句是**先按词库权重剪枝再重排**，
而实测 66% 的正确句根本进不了候选（beam search 按权重饱和）→ LM 看不到正确路径。
librime-lua 只能按「单音节」查词典（多音节 code 查不到），所以在 Lua 里自建：
  1. 音节表  -> 把输入切成音节晶格
  2. 词表    -> 在晶格上做 beam search，打分 = 词权重(log) + LM
这样 LM 真正参与搜索，而不是只做事后重排。

输出:
  data/gram/py_syllables.txt   每行一个音节（升序）
  data/gram/py_words.tsv       word <TAB> 音节(空格分隔) <TAB> 权重

用法: python3 scripts/gen_py_tables.py [--tier base|full]
"""
import argparse, math, os, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
sys.path.insert(0,os.path.join(HERE,"corpus"))
import rime_paths

def rows(p):
    st=False
    for line in open(p,encoding="utf-8"):
        if not st:
            if line.rstrip()=="...": st=True
            continue
        q=line.rstrip("\n").split("\t")
        if len(q)>=3 and q[2].isdigit(): yield q[0],q[1],int(q[2])

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--tier",default="base")
    ap.add_argument("--freq",default=os.path.join(rime_paths.DATA,"corpus","freq","recount_full.txt"),
                    help="语料词频（用来把词权重换成与 LM 同尺度的 log(1+count)*1000）")
    a=ap.parse_args()
    D=rime_paths.DICTS
    words=os.path.join(D,f"egret_py_words_{a.tier}.dict.yaml")
    chars=os.path.join(D,"egret_py_chars.dict.yaml")
    # 语料词频 -> log 尺度权重（与 lm_rerank 同尺度，便于融合）
    freq={}
    if os.path.exists(a.freq):
        for line in open(a.freq,encoding="utf-8"):
            q=line.rstrip("\n").split("\t")
            if len(q)>=3 and q[2].isdigit(): freq[q[0]]=int(q[2])
    # 单字权重用 LM 表的 unigram（同 log 尺度）；重扫源是五笔词表，不含单字
    lm=os.path.join(rime_paths.GRAM_DIR,"lm_rerank.tsv")
    if os.path.exists(lm):
        for line in open(lm,encoding="utf-8"):
            k,_,v=line.rstrip("\n").partition("\t")
            if len(k)==1 and v.isdigit(): freq[k]=max(freq.get(k,0), 0)
            if len(k)==1 and v.isdigit():
                freq["\x01"+k]=int(v)      # 单字专用标记，避免与词频混淆
    print(f"语料词频 {len(freq):,} 条（含单字 unigram）")
    syls=set(); out=[]; n=0
    for src in (chars,words):
        for w,code,weight in rows(src):
            toks=code.split()
            if not toks or len(toks)!=len(w):  # 音节数必须等于字数
                continue
            if any(not t.isalpha() for t in toks):
                continue
            for t in toks: syls.add(t)
            if len(w)==1 and ("\x01"+w) in freq:
                wt=freq["\x01"+w]                      # 单字：直接用 unigram 值
            else:
                c=freq.get(w)
                wt=int(round(math.log(1+c)*1000)) if c else 0
            out.append((w," ".join(toks),wt)); n+=1
    # 总词数（用于一元语言模型归一化 log P(w)=log f(w)-log N）
    # 一元语言模型的 N = 语料总词数。注意：不能用 recount 的计数之和——它把
    # **重叠匹配**也累加了（会把 N 放大到 1.5e10，log N 偏大使"少分段"被过度偏袒：
    # 实测 qktnqnrb 会用 我吃包拯 顶掉 我吃饭了）。用字数/平均词长估算。
    total_chars=sum(v for k,v in freq.items() if k.startswith("\x01"))
    total_tokens=int(total_chars / 1.5) if total_chars else 1
    mp=os.path.join(rime_paths.GRAM_DIR,"py_meta.txt")
    with open(mp,"w",encoding="utf-8") as f:
        f.write(f"total_tokens={total_tokens}\n")
    print(f"语料总词数 {total_tokens:,} -> {mp}")
    sp=os.path.join(rime_paths.GRAM_DIR,"py_syllables.txt")
    wp=os.path.join(rime_paths.GRAM_DIR,"py_words.tsv")
    with open(sp,"w",encoding="utf-8") as f:
        for s in sorted(syls): f.write(s+"\n")
    with open(wp,"w",encoding="utf-8") as f:
        for w,c,wt in out: f.write(f"{w}\t{c}\t{wt}\n")
    print(f"音节 {len(syls)} 个 -> {sp}")
    print(f"词条 {n:,} 条 -> {wp} ({os.path.getsize(wp)/2**20:.1f} MB)")
    print(f"最长音节 {max(len(s) for s in syls)} 字符；多字词示例:",
          [w for w,c,_ in out if len(w)>1][:5])

if __name__=="__main__": main()
