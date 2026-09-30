#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按语料频率重标**字表**权重（保持原值域，只改同音字之间的相对次序）。

动机（docs/PROGRESS.md §4.37）：长句失败的 100% 是"字词都在、引擎选错切法"，
样例都是同音词错配（小天使们→小天师门、周勃→州博）。同音字谁先出，由字权重决定，
而现用的是万象权重，未必反映我们 50G+ 语料。

与 §4.17 那四次失败的差别：那几次动的是**词**权重或拼音字表整体 ×0.35（会破坏
"词高于字"的层间平衡）；这里只动**字表内部**的相对次序，并把值域映射回**原来的
min/max 区间**，不改变层间比例。

输出：dicts/<name>_cal.dict.yaml（生成产物）
"""
import math, os, re, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
import rime_paths

D=rime_paths.DICTS
CHAR_TABLES=["egret_wubi_py_chars_common","egret_wubi_chars_common","egret_py_chars"]

def load_lm():
    s={}
    p=os.path.join(rime_paths.DATA,"gram","lm_rerank.tsv")
    for line in open(p,encoding="utf-8"):
        k,_,v=line.rstrip("\n").partition("\t")
        if len(k)==1 and v.isdigit(): s[k]=int(v)
    return s

def main():
    lm=load_lm()
    for name in CHAR_TABLES:
        src=os.path.join(D,name+".dict.yaml")
        if not os.path.exists(src): print(f"  跳过 {name}（不存在）"); continue
        rows=[]; vals=[]
        for line in open(src,encoding="utf-8"):
            q=line.rstrip("\n").split("\t")
            if len(q)>=3 and q[0] and q[2].isdigit():
                rows.append([q[0],q[1],int(q[2])]); vals.append(int(q[2]))
        lo,hi=min(vals),max(vals)
        # 语料频次 -> 原值域：用 log 频率在 [lo,hi] 内线性映射；语料里没有的保持原值
        chars=[r[0] for r in rows]
        freq={c:lm.get(c,0) for c in chars}
        lmin=math.log(1+min(v for v in freq.values() if v>0)) if any(freq.values()) else 0
        lmax=math.log(1+max(freq.values())) if any(freq.values()) else 1
        n_changed=0
        for r in rows:
            f=freq[r[0]]
            if f>0 and lmax>lmin:
                w=lo+(hi-lo)*(math.log(1+f)-lmin)/(lmax-lmin)
                new=max(lo,min(hi,int(round(w))))
                if new!=r[2]: n_changed+=1
                r[2]=new
        out=os.path.join(D,name+"_cal.dict.yaml")
        with open(out,"w",encoding="utf-8") as f:
            f.write("# RIME dictionary\n# 由 scripts/reweight_chars_by_corpus.py 生成，请勿手改\n"
                    f"# 字表权重按语料频率重标（值域保持 {lo}~{hi}），只改同音字相对次序\n\n")
            for r in rows:
                f.write(f"{r[0]}\t{r[1]}\t{r[2]}\n")
        print(f"  {name}: {len(rows)} 条（语料中出现的 {sum(1 for c in chars if freq[c]>0)} 条已重标）-> {os.path.basename(out)}")
    return 0

if __name__=="__main__": sys.exit(main())
