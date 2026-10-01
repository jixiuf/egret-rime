#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""长句三态验证：纯拼音 / 纯五笔 / 混打，看首候选是否等于期望句。

用法: python3 scripts/probe_long_sentences.py [条数] [标签]
输出: 每类命中数 + 失败样例（便于归因）
"""
import os, re, subprocess, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
sys.path.insert(0, os.path.join(HERE,"corpus"))
import rime_paths
from pypinyin import lazy_pinyin, Style

ROOT=os.path.dirname(HERE); U=os.path.join(ROOT,"data","rime-test")
CONSOLE=os.path.join(ROOT,"third-party","librime","build","bin","rime_api_console")
N=int(sys.argv[1]) if len(sys.argv)>1 else 25
LABEL=sys.argv[2] if len(sys.argv)>2 else "run"

def char_codes():
    """每字的最短五笔码（传统字表，含一/二/三级简码）。"""
    m={}
    for f in ("egret_wubi_chars_common.dict.yaml","egret_wubi_chars.dict.yaml"):
        p=os.path.join(rime_paths.DICTS,f)
        if not os.path.exists(p): continue
        st=False
        for line in open(p,encoding="utf-8"):
            if not st:
                if line.rstrip()=="...": st=True
                continue
            q=line.rstrip("\n").split("\t")
            if len(q)>=3 and len(q[0])==1 and q[1].isalpha():
                c=q[1].lower()
                if q[0] not in m or len(c)<len(m[q[0]]): m[q[0]]=c
    return m

def first_candidate(code):
    """同一输入连跑两次取第二次（冷部署首跑与热机不同，见 PROGRESS §4.18）。"""
    r=None
    for _ in range(2):
        p=subprocess.run([CONSOLE], input=code+"\n\n", capture_output=True,
                         text=True, cwd=U, timeout=120)
        r=None
        for line in p.stdout.splitlines():
            mm=re.match(r"1\. \[([^\]]*)\]", line.strip())
            if mm: r=mm.group(1); break
    return r

def main():
    codes=char_codes()
    rows=[]
    for line in open(os.path.join(rime_paths.DATA,"corpus","eval","sentences_v2.tsv"),encoding="utf-8"):
        q=line.rstrip("\n").split("\t")
        if len(q)>=2 and q[0] and q[1]: rows.append((q[0],q[1]))
        if len(rows)>=N: break
    stat={"纯拼音":[0,0],"纯五笔":[0,0],"混打":[0,0]}; fails={k:[] for k in stat}
    for py, want in rows:
        # 纯五笔：每字最短码
        wb="".join(codes.get(ch,"") for ch in want)
        # 混打：前半用五笔、后半用拼音（按字边界切）
        half=len(want)//2
        syl=lazy_pinyin(want, style=Style.NORMAL, errors="ignore")
        mix="".join(codes.get(u,"") for u in want[:half]) + "".join(syl[half:])
        for kind, code in (("纯拼音",py),("纯五笔",wb),("混打",mix)):
            if not code: continue
            stat[kind][1]+=1
            got=first_candidate(code)
            if got==want:
                stat[kind][0]+=1
            elif len(fails[kind])<3:
                fails[kind].append(f"{code[:40]} 期望 {want} 得到 {got}")
    print(f"== {LABEL} ==")
    for k,(hit,tot) in stat.items():
        print(f"  {k}: {hit}/{tot}" + (f" ({100*hit/tot:.0f}%)" if tot else ""))
    for k,v in fails.items():
        for x in v: print(f"    [{k}] ✗ {x}")

if __name__=="__main__": main()
