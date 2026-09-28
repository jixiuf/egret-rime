#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把**完整的五笔拼写**（一/二/三级简码 + 全码）补进**混合库字表**（组句的拼写空间）。

⭐ 为什么（docs/PROGRESS.md §4.19 的总根源）：
本方案的设计是「一级简码只在传统库发」——传统库字表里 `我 q` 有，混合库字表里
`我` 只有 `trx/trxy/trnt`，**没有 `q`**。而句子组句是**混合库的 script_translator**
在 prism 上做的 → 用户实际会敲的简码层**根本不在组句的拼写空间里** ✗。
于是 `q+chifan`（五笔简码+拼音）、`q+ktn+qnr`（短码序列）都够不到「我」，
组句只能退化成「名秘饭/色步犯了」这类错误读法。

拼写空间不完整会直接导致**组句走错路径**——实测两类症状：
- 缺简码：`qktqn`→名称嗯、`qchifanle`→色步犯了（够不到「我」）
- **缺全码**：`uwycuklf`→闪充部署 ✗（`冷` 只有 uwy，没有全码 uwyc，
  于是组句只能走 闪(uw)+充(yc)+部(uk)+署(lf) 的 2+2+2+2 错误路径；应为 冷(uwyc)+部署(uklf)）

补入 641 条简码 + 约 1.5 万条全码/三级码后实测：
  qktqn/qktnqnr → 我吃饭   qktnqnrb → 我吃饭了   qchifanle → 我吃饭了
  trwuchifan → 我们吃饭    jintiande… → 今天的天气怎么样    黄金 20/20 ✓

来源：传统库字表 `egret_wubi_chars.dict.yaml`（权威简码表）
幂等：已存在的 (字, 码) 不重复追加。
"""
import os, sys
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
import rime_paths

D=os.path.join(rime_paths.DICTS,"egret_wubi_py")

def main():
    src=os.path.join(D,"egret_wubi_chars.dict.yaml")
    dst=os.path.join(D,"egret_wubi_py_chars.dict.yaml")
    st=False; jm={}
    for line in open(src,encoding="utf-8"):
        if not st:
            if line.rstrip()=="...": st=True
            continue
        q=line.rstrip("\n").split("\t")
        # 只要纯字母码（1~4 码）；跳过 ¤ § 这类非汉字条目
        if len(q)>=3 and len(q[0])==1 and 1<=len(q[1])<=4 and q[1].isalpha() \
                and q[2].isdigit() and '\u4e00' <= q[0] <= '\u9fff':
            jm[(q[0],q[1].lower())]=q[2]
    have=set(); st=False
    for line in open(dst,encoding="utf-8"):
        if not st:
            if line.rstrip()=="...": st=True
            continue
        q=line.rstrip("\n").split("\t")
        if len(q)>=3: have.add((q[0],q[1].lower()))
    add=[(c,k,w) for (c,k),w in sorted(jm.items()) if (c,k) not in have]
    if add:
        with open(dst,"a",encoding="utf-8") as f:
            for c,k,w in add: f.write(f"{c}\t{k}\t{w}\n")
    print(f"五笔拼写：权威表 {len(jm)} 条，混合库补入 {len(add)} 条")

    # 强制结束符拼写：<短码>,（上游 comment：「五笔支持长句，3码或1码时需以","结尾」）。
    # 上游靠 algebra 的 derive 从万象格式（编码里含 ,/; 分隔）派生；我们的词库是简化格式
    # （如 了=t b/bnh），没有那些形态 → 那几条 derive 从来没生效过。
    # 这里直接生成显式条目：凡是长度 1~3 的码，都补一条 "<码>,"（用户敲 b, 即强制「b 到底」）。
    tsrc=os.path.join(D,"egret_wubi_chars.dict.yaml")
    fout=os.path.join(D,"egret_wubi_force_end.dict.yaml")
    st=False; have=set(); add2=[]
    for line in open(tsrc,encoding="utf-8"):
        if not st:
            if line.rstrip()=="...": st=True
            continue
        q=line.rstrip("\n").split("\t")
        if len(q)>=3: have.add((q[0],q[1].lower()))
    for (c,k),w in sorted(jm.items()):
        if 1 <= len(k) <= 3 and (c, k+",") not in have:
            add2.append((c,k+",",w))
    # 写成独立文件（生成产物，不入 git），由 egret_wubi.dict.yaml 的 import_tables 引入
    with open(fout,"w",encoding="utf-8") as f:
        f.write("# RIME dictionary\n# 由 scripts/gen_jianma_spellings.py 生成，请勿手改\n"
                "# 强制结束符拼写：<短码>,（1~3 码字）。用户敲 b, / ktn, 即强制「该码到此为止」。\n\n"
                "name: egret_wubi_force_end\nversion: \"2026.09.29\"\nsort: by_weight\n"
                "use_preset_vocabulary: false\ncolumns:\n  - text\n  - code\n  - weight\n...\n")
        for c,k,w in add2: f.write(f"{c}\t{k}\t{w}\n")
    print(f"强制结束符 <码>, 写出 {len(add2)} 条 -> {os.path.basename(fout)}")
    return 0

if __name__=="__main__": sys.exit(main())
