#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把评测失败句归因成三类，指导后续优化方向（见 docs/PROGRESS.md §4.30 的定性：
瓶颈在"候选生成"，不在排序）。

输入：eval_gram.py 的日志（含 `✗ 拼音 期望 X 得到 Y` 行）
输出：每类失败的条数与样例
  ① 字缺失   —— 期望句里有字不在字表（打不出来，词库问题）
  ② 词缺失   —— 期望句按我们词表最大匹配切词后，有词不在词表（数据层补词条可解）
  ③ 分段裁决 —— 字、词都在，但引擎选了别的切法（这才是"生成/裁决"问题，
                只能靠多读法并行或自建搜索器）
用法: python3 scripts/diagnose_failures.py /tmp/eval_base.log
"""
import os, re, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
sys.path.insert(0, os.path.join(HERE,"corpus"))
import rime_paths
D=rime_paths.DICTS

def load_chars():
    s=set()
    for f in ("egret_wubi_py_chars_common.dict.yaml","egret_wubi_py_chars.dict.yaml",
              "egret_wubi_chars_common.dict.yaml","egret_wubi_chars.dict.yaml"):
        p=os.path.join(D,f)
        if not os.path.exists(p): continue
        st=False
        for line in open(p,encoding="utf-8"):
            if not st:
                if line.rstrip()=="...": st=True
                continue
            q=line.split("\t")
            if len(q)>=3 and len(q[0])==1: s.add(q[0])
    return s

def load_words(maxlen=8):
    s=set()
    for f in ("egret_wubi_py_words_base.dict.yaml","egret_wubi_words_wb86_base.dict.yaml",
              "egret_wubi_py_chengyu.dict.yaml","egret_py_chengyu.dict.yaml",
              "egret_wubi_sentence.dict.yaml","egret_wubi_py_user_phrases.dict.yaml"):
        p=os.path.join(D,f)
        if not os.path.exists(p): continue
        st=False
        for line in open(p,encoding="utf-8"):
            if not st:
                if line.rstrip()=="...": st=True
                continue
            w=line.split("\t")[0]
            if 2<=len(w)<=maxlen: s.add(w)
    return s

def maxmatch(text, words):
    """最大匹配切词，返回 (词列表, 未命中的片段)"""
    out=[]; i=0; miss=[]
    while i < len(text):
        for L in range(min(8, len(text)-i), 0, -1):
            if text[i:i+L] in words:
                out.append(text[i:i+L]); i += L; break
        else:
            miss.append(text[i]); i += 1
    return out, miss

def main():
    log=sys.argv[1] if len(sys.argv)>1 else "/tmp/eval_base.log"
    pat=re.compile(r"✗\s+(\S+)\s+期望\s+(\S+)\s+得到\s+(\S+)")
    fails=[]
    for line in open(log,encoding="utf-8",errors="ignore"):
        m=pat.search(line)
        if m: fails.append((m.group(1), m.group(2), m.group(3)))
    if not fails:
        print("日志里没解析到失败行（跑完整评测再看）"); return 0
    chars, words = load_chars(), load_words()
    c1=c2=c3=0; ex={"①字缺失":[], "②词缺失":[], "③分段裁决":[]}
    for pinyin, want, got in fails:
        miss_chars=[ch for ch in want if ch not in chars]
        ws, miss_w = maxmatch(want, words)
        if miss_chars:
            c1+=1
            if len(ex["①字缺失"])<5: ex["①字缺失"].append(f"{want}（无此字: {''.join(miss_chars)}）")
        elif len(ws)<=1 or any(len(w)==1 for w in ws):
            # 几乎切不出词（说明缺词条）或只能切到单字
            c2+=1
            if len(ex["②词缺失"])<5: ex["②词缺失"].append(f"{want}（切词: {'/'.join(ws) or '无'}）")
        else:
            c3+=1
            if len(ex["③分段裁决"])<5: ex["③分段裁决"].append(f"{want} → 得到 {got}")
    n=len(fails)
    print(f"失败 {n} 句归因：")
    print(f"  ① 字缺失（字表里没有）      : {c1:3d}  ({100*c1/n:.0f}%)")
    print(f"  ② 词缺失（切不出词/只有单字）: {c2:3d}  ({100*c2/n:.0f}%)")
    print(f"  ③ 分段裁决（字词都在，选错） : {c3:3d}  ({100*c3/n:.0f}%)")
    for k,v in ex.items():
        if v: print(f"  {k} 样例: " + " | ".join(v))
    return 0

if __name__=="__main__": sys.exit(main())
