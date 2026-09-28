#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按「是否在语料中出现」校准**字表权重**。

背景（docs/PROGRESS.md §4.21）：
  · 混合/传统字表各 20,914 字，其中 **14,523 (69%) 在我们 50G+ 语料里从未出现**
    （丂丄丅丆… 这类现代汉语几乎不用的字）
  · 其中 13,161 个已经是权重 1 ✓，但有 **1,362 个仍是 15~97** ✗
  · 拼音 8105 字表 7,859 字里有 1,643 (21%) 语料未出现，权重却高达 116~500 ✗
    → 会在拼音输入时和常用字抢候选

策略（用户提出）：
  · **语料中出现** → **保持原权重**（整链权重是手工调好的整体，见 §4.17 四次失败教训）
  · **语料中未出现** → 压到最低权重：既保留**输出能力**（打全码/拼音照样能出），
    又不让它参与候选竞争

输出（**生成产物，不入 git**，由 refresh.sh 的 dict 阶段产生）：
  egret_wubi_py_chars_cal.dict.yaml           混合库字表
  egret_wubi_chars_cal.dict.yaml              传统库字表
  egret_wubi_py_pinyin_8105_cal.dict.yaml     拼音字表
"""
import os, sys, re
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
import rime_paths

D=os.path.join(rime_paths.DICTS,"egret_wubi_py")
RARE_WUBI=1        # 五笔表：未出现字的权重上限（最低）
RARE_PY=60         # 拼音表：未出现字的权重上限（低于常用字的最低档 ~100+）

def load_lm():
    """语料 1-gram（自训 gram 的字频统计）→ 出现过的字集合"""
    s=set()
    p=os.path.join(rime_paths.DATA,"gram","lm_rerank.tsv")
    if not os.path.exists(p): return None
    for line in open(p,encoding="utf-8"):
        k,_,v=line.rstrip("\n").partition("\t")
        if len(k)==1 and v.isdigit(): s.add(k)
    return s

def load_syllables():
    """拼音音节表（用于识别「五笔码碰巧是拼音音节」的碰撞）"""
    p=os.path.join(rime_paths.DATA,"gram","py_syllables.txt")
    if not os.path.exists(p): return set()
    return {l.strip() for l in open(p,encoding="utf-8") if l.strip()}

def cal(src_name, dst_name, cap, drop_syllable_collision=False):
    """drop_syllable_collision: 对**语料未出现**的字，丢掉「码本身是拼音音节」的拼写。

    为什么：librime 的 script_translator 有「整段精确匹配 → 跳过组句、直接置顶」的
    短路（script_translator.cc:482/496，见 §4.18），且**不比较权重**。生僻字的五笔码
    若恰好等于一个拼音音节（如 𨸐 的码就是 ben），打 ben 时它会顶掉「本/奔」。
    这类碰撞只发生在生僻字上，丢掉即可（它们仍可在传统五笔库用全码打出）。"""
    src=os.path.join(D,src_name); dst=os.path.join(D,dst_name)
    st=False; n_cap=0; n_tot=0; n_drop=0
    with open(src,encoding="utf-8") as f, open(dst,"w",encoding="utf-8") as o:
        for line in f:
            if not st:
                if re.match(r"^name:",line): o.write(f"name: {dst_name[:-len('.dict.yaml')]}\n"); continue
                o.write(line)
                if line.rstrip()=="...": st=True
                continue
            q=line.rstrip("\n").split("\t")
            if len(q)>=3 and len(q[0])==1 and q[2].isdigit() and '\u4e00'<=q[0]<='\u9fff':
                n_tot+=1
                if q[0] not in LM:
                    if drop_syllable_collision and q[1].lower() in SYL:
                        n_drop+=1; continue          # 丢掉该拼写（详见 docstring）
                    if int(q[2])>cap:
                        q[2]=str(cap); n_cap+=1
            o.write("\t".join(q)+"\n")
    extra=f"，丢弃拼音音节碰撞 {n_drop:,} 条" if drop_syllable_collision else ""
    print(f"  {dst_name}: 共 {n_tot:,} 条，压低未出现字 {n_cap:,} 条（上限 {cap}）{extra}")

def main():
    global LM
    LM=load_lm()
    if LM is None:
        print("  ! 缺 data/gram/lm_rerank.tsv（先跑 gram 阶段）；跳过字表权重校准")
        return 0
    print(f"语料字集 {len(LM):,}")
    global SYL
    SYL=load_syllables()
    print(f"拼音音节表 {len(SYL):,}")
    # 混合库（组句词典）：额外丢弃生僻字的「五笔码=拼音音节」碰撞拼写
    cal("egret_wubi_py_chars.dict.yaml",          "egret_wubi_py_chars_cal.dict.yaml",          RARE_WUBI, True)
    cal("egret_wubi_chars.dict.yaml",             "egret_wubi_chars_cal.dict.yaml",             RARE_WUBI)
    cal("egret_wubi_py_pinyin_8105.dict.yaml",    "egret_wubi_py_pinyin_8105_cal.dict.yaml",    RARE_PY)
    return 0

if __name__=="__main__": sys.exit(main())
