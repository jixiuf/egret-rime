#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成成语/四字固定短语词典。

背景：我们的词表（源表 wb86_wangxiang_cn_dicts/base.dict.yaml）只做到 3 字词，
**4 字词一个都没有**（实测：2 字 166,875、3 字 613,760、4 字 0），
所以常用成语现在打不出来（除非在 user_phrases 里手工加过）。

做法（纯数据，不碰引擎、不碰权重）：
  1. 从已有的全语料**字符 4-gram 计数**（data/gram/zh-hans-egret.2_6gram.tsv）里
     取高频四字串 —— 不用重扫语料
  2. 过滤：纯汉字、不含常用虚词（的/了/是/在/和/我/你/他/这/那/也/就/都/很），
     把跨词误配挡掉
  3. 补码：五笔按 4 字规则 AaBaCaDa（每字首字母，取自字表最短码）；
     拼音用 pypinyin 逐字标注。同一条文本写两行（五笔一行、拼音一行）
  4. 权重沿用其在语料里的频次（log 尺度），与词表同量级

输出: dicts/egret_wubi_py/egret_wubi_py_chengyu.dict.yaml（运行时词典，入 git）
"""
import math, os, re, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
import rime_paths
from pypinyin import lazy_pinyin, Style

D=os.path.join(rime_paths.DICTS,"egret_wubi_py")
SRC=os.path.join(rime_paths.DICTS,"common","chengyu.dict.yaml")   # 上游 cur 好的成语表（13k 条，含五笔 4 码）
COUNTS=os.path.join(rime_paths.DATA,"gram","zh-hans-egret.2_6gram.tsv")
OUT=os.path.join(D,"egret_wubi_py_chengyu.dict.yaml")
MIN_COUNT=int(os.environ.get("MIN_COUNT","1000"))
BAD=set("的了是在和我你他她它这那也就都很个着们把被给对从到与及或但而")

def char_codes():
    """每个字的最短五笔码（取传统字表，含一/二/三级简码）。"""
    m={}
    p=os.path.join(D,"egret_wubi_chars.dict.yaml")
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

def main():
    if not os.path.exists(COUNTS):
        sys.exit(f"缺少 {COUNTS}（先跑 gram 阶段）")
    codes=char_codes()
    # 语料 4-gram 频次（有就用它定权重，没有给个中庸值）——只读一遍 603MB 的计数文件
    freq={}
    if os.path.exists(COUNTS):
        for line in open(COUNTS,encoding="utf-8"):
            w,_,c=line.rstrip("\n").partition("\t")
            if len(w)==4 and c.isdigit(): freq[w]=int(c)
    # 源：curated 成语表（比"按语料频次筛四字串"干净得多——后者会混进"如图所示/没有什么"）
    pick=[]; st=False
    for line in open(SRC,encoding="utf-8"):
        if not st:
            if line.rstrip()=="...": st=True
            continue
        q=line.rstrip("\n").split("\t")
        if len(q)<2: continue
        w,c=q[0],q[1].lower()
        if len(w)!=4 or not c.isalpha() or len(c)!=4: continue
        if any(not ('\u4e00'<=ch<='\u9fff') for ch in w): continue
        pick.append((w,c,freq.get(w,0)))
    rows=[]
    for w,wb,n in pick:
        py=lazy_pinyin(w, style=Style.NORMAL, errors="ignore")
        v=int(round(math.log(1+n)*100)) if n else 700      # 语料有频次按频次；没有给中庸值 700
        v=max(1,min(v,4000))
        rows.append((w,wb,v))
        if len(py)==4 and all(s.isascii() and s.isalpha() for s in py):
            rows.append((w,"".join(py),v))
    with open(OUT,"w",encoding="utf-8") as f:
        f.write("# RIME dictionary\n# 由 scripts/gen_chengyu_dict.py 生成，请勿手改\n"
                f"# 四字成语（源：dicts/common/chengyu.dict.yaml，五笔 4 码取自该表，拼音码由 pypinyin 标注），"
                f"共 {len(set(r[0] for r in rows)):,} 条词、{len(rows):,} 行\n\n"
                "name: egret_wubi_py_chengyu\nversion: \"2026.09.29\"\nsort: by_weight\n"
                "use_preset_vocabulary: false\ncolumns:\n  - text\n  - code\n  - weight\n...\n")
        for w,c,v in rows: f.write(f"{w}\t{c}\t{v}\n")
    print(f"成语 {len(pick):,} 条（源 {os.path.basename(SRC)}），写出 {len(rows):,} 行 -> {os.path.basename(OUT)}")
    print("  样例:", "、".join(w for w,_,_ in pick[:8]))

if __name__=="__main__": main()
