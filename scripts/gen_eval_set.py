#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成"可信"的句子评测集：从**不同类型文章**里取**完整句子**做测试。

为什么要重做（教训见 docs/PROGRESS.md §4.11）：
    早先的评测集直接从 clean/short 随机采短句，混进了
      - 历史书里的生僻表达（"四北仓台米的转运方案"）
      - 碎片化片段（"一分钟经理" 这类不通顺的）
    → 打分被系统性低估，调参方向被带偏。

做法：
    1. 从 clean/para/（**保留标点**）切出**完整句**（按 。！？）
    2. **随机窗口采样**：对每个来源只随机读取若干 1MB 窗口（而不是扫完 48GB），
       多进程并行 → 几十秒完成，且样本在全文件上均匀
    3. 过滤：长度 8~20 字、全汉字、汉字都在高频字表内
    4. **语感过滤**：字符级平均对数概率 ≥ 阈值（用 lm_rerank.tsv 打分）
       → 滤掉"四北仓台米"这类不合语感的碎片
    5. **按来源分层**（epub 书籍 / 新闻+维基+百科 / 网页文本 / 课程文稿），
       这样评测反映"不同类型的真实句子"
    6. 转无调拼音（与方案音系一致）

输出: data/corpus/eval/sentences_v2.tsv   code <TAB> 原句 <TAB> 来源

用法:
  third-party/venv/bin/python scripts/gen_eval_set.py                  # 每源 30 条
  third-party/venv/bin/python scripts/gen_eval_set.py --per-source 50 --jobs 9
"""

import argparse
import collections
import math
import multiprocessing as mp
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "corpus"))
import rime_paths  # noqa: E402

PARA_DIR = os.path.join(rime_paths.DATA, "corpus", "clean", "para")
OUT = os.path.join(rime_paths.DATA, "corpus", "eval", "sentences_v2.tsv")
CJK = re.compile(r"[\u4e00-\u9fff]")
# 只取**有完整终止标点**的句子（避免行尾残片）
SENT_FULL = re.compile(r"[^。！？；;]+[。！？]")
# 以这些字开头的多是从上一句截断的碎片
BAD_HEAD = set("的了在和与及而就也都很是把被对从向因为所之其此该那些个")
# 标题/编号/列表类
BAD_HEAD_RE = re.compile(r"^[（(【\[一二三四五六七八九十0-9·•　\s]")
ALLOWED_EXTRA = set("，、；：？！…—·“”‘’（）《》〈〉")

_G = {}


def _init(lm_path):
    tab = {}
    for line in open(lm_path, encoding="utf-8"):
        k, _, v = line.rstrip("\n").partition("\t")
        if v.isdigit():
            tab[k] = int(v)
    log_total = 0.0
    meta = lm_path[:-4] + ".meta"
    if os.path.exists(meta):
        for line in open(meta, encoding="utf-8"):
            m = re.match(r"total_chars=(\d+)", line)
            if m:
                log_total = math.log(int(m.group(1)) + 1) * 1000.0
    unis = sorted(((v, k) for k, v in tab.items() if len(k) == 1), reverse=True)
    _G["tab"] = tab
    _G["log_total"] = log_total
    _G["common"] = {k for _, k in unis[:args_common]}
    return len(tab)


def plausibility(s):
    tab, log_total = _G["tab"], _G["log_total"]
    n = len(s)
    if n < 2:
        return -99.0
    tot = 0.0
    for i in range(n):
        best = None
        for L in range(4, 1, -1):
            a = i - L + 1
            if a >= 0:
                v = tab.get(s[a:i + 1])
                vp = tab.get(s[a:i])
                if v and vp:
                    c = (v - vp) / 1000.0
                    if best is None or c > best:
                        best = c
        u = tab.get(s[i])
        if u:
            pu = (u - log_total) / 1000.0
            if best is None or pu > best:
                best = pu
        tot += best if best is not None else -10.0
    return tot / n


def task(job):
    """随机窗口采样一个来源文件，返回通过语感过滤的候选句。"""
    path, windows, win_size, min_len, max_len, min_plaus = job
    size = os.path.getsize(path)
    rnd = random.Random(hash(os.path.basename(path)) & 0xFFFF)
    common = _G["common"]
    seen, good, cand = set(), [], 0
    with open(path, "rb") as f:
        for _ in range(windows):
            off = rnd.randrange(0, max(1, size - win_size))
            f.seek(off)
            f.readline()                       # 对齐到行首
            chunk = f.read(win_size).decode("utf-8", "ignore")
            if off + win_size < size:
                chunk = chunk.rsplit("\n", 1)[0]
            for line in chunk.split("\n"):
                for s in SENT_FULL.findall(line):
                    s = s.strip().rstrip("。！？").strip()
                    if not s or s[0] in BAD_HEAD or BAD_HEAD_RE.match(s):
                        continue
                    if s.count("“") != s.count("”"):
                        continue
                    if not (min_len <= len(s) <= max_len):
                        continue
                    if any(c not in ALLOWED_EXTRA and not CJK.match(c) for c in s):
                        continue
                    if not all(c in common for c in s if CJK.match(c)):
                        continue
                    if s in seen:
                        continue
                    seen.add(s)
                    cand += 1
                    if plausibility(s) >= min_plaus:
                        good.append(s)
    return os.path.basename(path)[:-4], cand, good


args_common = 4000


def main():
    global args_common
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-source", type=int, default=30)
    ap.add_argument("--min-len", type=int, default=8)
    ap.add_argument("--max-len", type=int, default=20)
    ap.add_argument("--min-plausibility", type=float, default=-6.0)
    ap.add_argument("--common-chars", type=int, default=4000)
    ap.add_argument("--windows", type=int, default=400,
                    help="每个来源随机读取的窗口数（1MB/窗）")
    ap.add_argument("--jobs", type=int, default=9)
    ap.add_argument("--lm", default=os.path.join(rime_paths.GRAM_DIR,
                                                 "lm_rerank.tsv"))
    ap.add_argument("--seed", type=int, default=20260928)
    args = ap.parse_args()
    args_common = args.common_chars

    if not os.path.exists(args.lm):
        sys.exit(f"缺少 LM 表 {args.lm}（先跑 scripts/gen_lm_rerank.py）")
    files = [os.path.join(PARA_DIR, f) for f in sorted(os.listdir(PARA_DIR))
             if f.endswith(".txt") and os.path.getsize(os.path.join(PARA_DIR, f)) > 1 << 20]
    print(f"来源 {len(files)} 个，每源读 {args.windows} × 1MB 随机窗口，"
          f"并发 {min(args.jobs, len(files))}")

    jobs = [(p, args.windows, 1 << 20, args.min_len, args.max_len,
             args.min_plausibility) for p in files]
    with mp.Pool(min(args.jobs, len(files)), initializer=_init, initargs=(args.lm,)) as pool:
        results = pool.map(task, jobs)

    rnd = random.Random(args.seed)
    out_rows = []
    print(f"\n{'来源':<14}{'候选':>9}{'过语感':>9}{'采用':>6}   语感通过率")
    for name, cand, good in results:
        rnd.shuffle(good)
        take = good[:args.per_source]
        rate = (len(good) / cand * 100) if cand else 0
        print(f"{name:<14}{cand:>9,}{len(good):>9,}{len(take):>6}   {rate:.1f}%")
        out_rows.extend((name, s) for s in take)

    from pypinyin import lazy_pinyin
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    # 重要：输入是**纯拼音**（用户不会把标点也算进拼音），所以期望文本也必须是
    # 无标点的纯汉字——否则评测会把"少一个逗号"也算成错（曾因此虚低准确率）
    pure = re.compile(r"[^\u4e00-\u9fff]")
    with open(OUT, "w", encoding="utf-8") as f:
        for src, s in out_rows:
            t = pure.sub("", s)
            if len(t) < 4:
                continue
            f.write(f"{''.join(lazy_pinyin(t))}\t{t}\t{src}\n")
    print(f"\n写出 {len(out_rows)} 条 -> {OUT}\n示例：")
    for src, s in out_rows[:8]:
        print(f"  [{src:<10}] {s}")


if __name__ == "__main__":
    main()
