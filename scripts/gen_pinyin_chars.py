#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给「有五笔码但没有拼音」的字补拼音（生僻字补词典）。

背景（docs/PROGRESS.md §4.22）：混合库字表 70,366 字里只有 8,136 字有拼音，
**62,232 字打拼音够不到**（其中基本区就有 13,039 字）。五笔侧已经全（万象+wubi86
的扩展 A/B 都并进来了），缺的是**读音层**。

做法：用 pypinyin（现有依赖，已在词表层用）给这些字生成无调音节，
按用户策略给**最低权重**——能打出来，但不与常用字争候选。
pypinyin 不认识的（29,002 字，多为扩展 B+）自动跳过（打五笔全码仍可出）。

输出（生成产物，不入 git）：dicts/egret_wubi_py_pinyin_extra.dict.yaml
"""
import os, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
import rime_paths
from pypinyin import lazy_pinyin, Style

D=rime_paths.DICTS
W=60          # 最低权重带（低于常用字；参见 gen_char_weights.py 的校准策略）

def chars(p):
    st=False; s=set()
    for line in open(p,encoding="utf-8"):
        if not st:
            if line.rstrip()=="...": st=True
            continue
        q=line.split("\t")
        if len(q)>=3 and len(q[0])==1: s.add(q[0])
    return s

def main():
    mix=chars(os.path.join(D,"egret_wubi_py_chars.dict.yaml")) | chars(os.path.join(D,"egret_wubi_chars.dict.yaml"))
    py=chars(os.path.join(D,"egret_wubi_py_pinyin_8105.dict.yaml"))
    todo=sorted(mix-py)
    out=[]; seen=set()
    for ch in todo:
        r=lazy_pinyin(ch, style=Style.NORMAL, errors="ignore")
        if not r: continue
        syl=r[0]
        if not (syl.isascii() and syl.isalpha()): continue
        if (ch,syl) in seen: continue
        seen.add((ch,syl)); out.append((ch,syl))
    dst=os.path.join(D,"egret_wubi_py_pinyin_extra.dict.yaml")
    with open(dst,"w",encoding="utf-8") as f:
        f.write("# RIME dictionary\n# 由 scripts/gen_pinyin_chars.py 生成，请勿手改\n"
                f"# 生僻字拼音（pypinyin 标注；只补「有五笔码但无拼音」的字），共 {len(out):,} 条\n"
                f"# 权重固定 {W}（最低带）：能打出来，不与常用字争候选\n\n"
                "name: egret_wubi_py_pinyin_extra\nversion: \"2026.09.29\"\nsort: by_weight\n"
                "use_preset_vocabulary: false\ncolumns:\n  - text\n  - code\n  - weight\n...\n")
        for ch,syl in out: f.write(f"{ch}\t{syl}\t{W}\n")
    print(f"补拼音：待补 {len(todo):,} 字，pypinyin 给出 {len(out):,} 条 -> {os.path.basename(dst)}")

if __name__=="__main__": main()
