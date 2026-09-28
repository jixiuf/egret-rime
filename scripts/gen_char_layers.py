#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把字表拆成「默认层」与「扩展层」——见 docs/PROGRESS.md §4.23。

数据（实测）：混合库字表 125,692 条里 **109,231 条（87%）是扩展区汉字**，
而它们在 50GB+ 语料里一次都没出现过；**基本区的「五笔码=拼音音节」碰撞为 0**，
所有碰撞都只在扩展区（如 𨸐=ben 顶掉「本」）。

所以：**能支持，但默认不加载**——
  · common 层：语料出现过的字 + 有拼音的基本区字（≈1.6 万条）→ 默认 import
  · ext   层：其余（≈10.9 万条扩展字）→ 不默认 import，用户一行 patch 即可开启
好处：词典/prism 缩小 ~87%（部署更快、内存更小），**碰撞与挤占自然消失**
（不需要任何「丢碰撞」hack），要用的用户仍可打（全码 + `,` / `,`/` 反查 / 开 ext）。

输出（生成产物；两者都是产品的一部分，按政策入 git）：
  egret_wubi_py_chars_common.dict.yaml / egret_wubi_py_chars_ext.dict.yaml
  egret_wubi_chars_common.dict.yaml    / egret_wubi_chars_ext.dict.yaml
"""
import os, re, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
import rime_paths

D=os.path.join(rime_paths.DICTS,"egret_wubi_py")

def load_known():
    lm=set()
    p=os.path.join(rime_paths.DATA,"gram","lm_rerank.tsv")
    if os.path.exists(p):
        for line in open(p,encoding="utf-8"):
            k,_,v=line.rstrip("\n").partition("\t")
            if len(k)==1 and v.isdigit(): lm.add(k)
    py=set(); st=False
    for line in open(os.path.join(D,"egret_wubi_py_pinyin_8105.dict.yaml"),encoding="utf-8"):
        if not st:
            if line.rstrip()=="...": st=True
            continue
        q=line.split("\t")
        if len(q)>=3 and len(q[0])==1: py.add(q[0])
    return lm, py

def split(src_name, base):
    src=os.path.join(D,src_name)
    st=False; common=[]; ext=[]; head=[]
    for line in open(src,encoding="utf-8"):
        if not st:
            head.append(line)
            if line.rstrip()=="...": st=True
            continue
        q=line.split("\t")
        if len(q)>=3 and len(q[0])==1:
            (common if (q[0] in LM or q[0] in PY) else ext).append(line)
        else:
            common.append(line)
    for name, rows in ((base+"_common", common), (base+"_ext", ext)):
        with open(os.path.join(D,name+".dict.yaml"),"w",encoding="utf-8") as o:
            for h in head:
                o.write(f"name: {name}\n" if re.match(r"^name:",h) else h)
            # 若原文件没有 name: 行（纯 import 包装），补一个
            if not any(re.match(r"^name:",h) for h in head):
                pass
            o.writelines(rows)
        print(f"  {name}: {len(rows):,} 条")
    return len(common), len(ext)

def main():
    global LM, PY
    LM, PY = load_known()
    print(f"语料字 {len(LM):,} / 有拼音字 {len(PY):,}")
    split("egret_wubi_py_chars.dict.yaml", "egret_wubi_py_chars")
    split("egret_wubi_chars.dict.yaml",    "egret_wubi_chars")
    return 0

if __name__=="__main__": sys.exit(main())
