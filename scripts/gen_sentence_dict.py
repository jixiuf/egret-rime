#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""整句词库：把语料里的高频整句做成"五笔短码 → 整句"的词条。

为什么（docs/PROGRESS.md §4.18）：自建搜索器算得对（qktqn→我吃饭），但**送不进
输入法**（新增候选会扰乱引擎、librime-lua 又无法构造 Sentence）。而**精确匹配的
词条是引擎本来就认的** —— 所以改用数据交付：把高频整句预计算成词条，
用户打对应的短码序列就直接命中整句。（墨奇 rime-wubi-sentence 也是这个思路）

短码序列：每个字取**最短可用码**（一级/二级/三级/全码里最短的那个），
这正是用户实际会敲的形式（我=q 吃=ktn 饭=qnr 了=b → qktnqnrb）。

输出: dicts/egret_wubi_sentence.dict.yaml
"""
import argparse, collections, math, os, random, re, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
sys.path.insert(0,os.path.join(HERE,"corpus"))
import rime_paths

D=rime_paths.DICTS
CJK=re.compile(r"[\u4e00-\u9fff]")
SENT=re.compile(r"[^。！？；]+[。！？]")

def rows(p):
    st=False
    for line in open(p,encoding="utf-8"):
        if not st:
            if line.rstrip()=="...": st=True
            continue
        q=line.rstrip("\n").split("\t")
        if len(q)>=3 and q[2].isdigit(): yield q[0],q[1],int(q[2])

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--windows",type=int,default=2000)
    ap.add_argument("--top",type=int,default=30000)
    ap.add_argument("--min-len",type=int,default=3)
    ap.add_argument("--max-len",type=int,default=8)
    ap.add_argument("--weight-floor",type=int,default=451)
    a=ap.parse_args()

    # 每字的**最短码**（取字符表里最短的那个五笔码）
    best={}
    for src in ("egret_wubi_chars.dict.yaml","egret_wubi_py_chars.dict.yaml"):
        for ch,code,_ in rows(os.path.join(D,src)):
            if len(ch)!=1: continue
            c=code.split(",")[0].lower()
            if len(c)<=3 and c.isalpha():          # 只用一/二级简码作"短码"
                if ch not in best or len(c)<len(best[ch]): best[ch]=c
    print(f"可短码字 {len(best):,}")

    # 随机窗口采样语料，统计高频整句
    cnt=collections.Counter()
    para=os.path.join(rime_paths.DATA,"corpus","clean","para")
    files=[os.path.join(para,f) for f in os.listdir(para) if f.endswith(".txt")]
    rnd=random.Random(20260929)
    for p in files:
        size=os.path.getsize(p)
        with open(p,"rb") as f:
            for _ in range(a.windows//max(1,len(files))):
                f.seek(rnd.randrange(0,max(1,size-(1<<20))))
                f.readline(); chunk=f.read(1<<20).decode("utf-8","ignore")
                for line in chunk.split("\n"):
                    for s in SENT.findall(line):
                        s=s.strip().rstrip("。！？").strip()
                        s2="".join(CJK.findall(s))
                        if a.min_len<=len(s2)<=a.max_len and len(s2)==len(s): cnt[s2]+=1
    print(f"候选整句 {len(cnt):,}")

    # 生成短码序列（全部字都要有短码，否则跳过）
    out=[]
    for s,c in cnt.most_common(a.top*3):
        codes=[best.get(ch) for ch in s]
        if any(x is None for x in codes): continue
        out.append(("".join(codes), s, c))
        if len(out)>=a.top: break
    # 同一码只留最高频
    seen={}; dedup=[]
    for code,s,c in out:
        if code in seen: continue
        seen[code]=1; dedup.append((code,s,c))
    cmax=max((c for _,_,c in dedup), default=1)
    name="egret_wubi_sentence"
    path=os.path.join(D,name+".dict.yaml")
    with open(path,"w",encoding="utf-8") as f:
        f.write(f"# RIME dictionary\n# 由 scripts/gen_sentence_dict.py 生成，请勿手改\n"
                f"# 高频整句 → 五笔短码序列（每字取最短码）；共 {len(dedup):,} 条\n\n"
                f"name: {name}\nversion: \"2026.09.29\"\nsort: by_weight\n"
                f"use_preset_vocabulary: false\ncolumns:\n  - text\n  - code\n  - weight\n...\n")
        for code,s,c in dedup:
            w=max(a.weight_floor, min(5000, int(500+4500*math.log(1+c)/math.log(1+cmax))))
            f.write(f"{s}\t{code}\t{w}\n")
    print(f"写出 {len(dedup):,} 条 -> {path}")
    for code,s,c in dedup[:5]: print(f"   {s}\t{code}\t({c})")

if __name__=="__main__": main()
