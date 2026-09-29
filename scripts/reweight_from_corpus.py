#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""C2：用语料词频把**词条权重**回归到与字库/LM 同一尺度的 0-1000。

问题（实测）：
    拼音词/五笔词权重 = 万象原值 451~5000（中位 525），字库 = 1~1000，
    而 octagram 的 LM 加减分只有 ±10~30。词与词相差 4500 → **LM 根本管不着**，
    组句退化为纯权重排序（实测全拼句子还原仅 16%）。

目标形态（docs/design-weights-jianma-grammar.md §2.3）：
    高频词 400~1000（词库裁决主力）／常用词 100~400（交 gram 裁决）／长尾 ~1
    字表不动（字是基础；且五笔字表 ×0.35 已让位拼音，改它会破坏简码手感）

映射：
    语料中有的词：weight = lo + (hi-lo) * cw/1000
        （cw = freq.py 输出的 log-norm 0..1000，最高频词 = 1000）
    语料中没有的词（真长尾）：用万象权重作**相对序**压进低带
        weight = ulo + (uhi-ulo) * log(1+(w-451)/100) / log(1+(5000-451)/100)

用法:
  python3 scripts/reweight_from_corpus.py --dry-run        # 只看变化幅度
  python3 scripts/reweight_from_corpus.py                  # 原地重写（有 git 可回滚）
  python3 scripts/reweight_from_corpus.py --band 100,1000 --unknown-band 100,300
"""

import argparse
import glob
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402

OUT = rime_paths.DICTS
DEFAULT_FREQ = os.path.join(rime_paths.DATA, "corpus", "freq", "word_freq.tsv")

# 目标：词表 = OUT 下所有 *words* 分档表 + 传统库词表
PATTERNS = [
    os.path.join(OUT, "egret_wubi_py_words_*.dict.yaml"),
    os.path.join(OUT, "egret_wubi_py_pinyin_words_*.dict.yaml"),
    os.path.join(OUT, "egret_wubi_words_*.dict.yaml"),
]
# 字表：默认只动拼音字表（五笔字表含一/二级简码 owner，不得整体缩放）
CHAR_DICTS = [os.path.join(OUT, "egret_py_chars.dict.yaml")]


def load_freq(path):
    """读词频。支持两种格式，自动识别：

    A) 抽取词频表 word_freq.tsv（带表头注释，列 = word/count/weight）
    B) rime-frequency 重扫输出（Rime dict yaml 或 TSV，列 = word/code/count）

    统一返回 word -> raw count（后面再按 log-norm 映射到带内）。
    """
    freq = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) < 2:
                continue
            # B 格式：最后一列是频次；A 格式：第二列是频次
            if len(p) >= 3 and p[2].isdigit() and not p[1].isdigit():
                freq[p[0]] = int(p[2])          # (word, code, count)
            elif len(p) >= 2 and p[1].isdigit():
                freq[p[0]] = int(p[1])          # (word, count[, ...])
    return freq


def log_norm(counts):
    """word -> log-norm 0..1000（最高频 = 1000）。"""
    if not counts:
        return {}
    cmax = max(counts.values())
    denom = math.log(1 + cmax) if cmax > 0 else 1.0
    return {w: int(round(1000.0 * math.log(1 + c) / denom))
            for w, c in counts.items()}


def make_log_mapper(freq, floor_count=1):
    """把权重改成与 LM 表同一尺度的 log(1+count)*1000。

    为什么这样最好（全局视角）：
      - LM 分数就是 log(count) 尺度；词典权重原来被归一化到 0-1000，
        两者量纲不同 → 无法融合、也无法比较
      - log 尺度天然满足"两个词权重差 = 它们的对数概率比"，正是组句该用的量
      - 语料没命中的词给 0（最低），不会凭空获得权重
    """
    import math

    def map_weight(word, old):
        c = freq.get(word)
        if c is None:
            return 0
        return max(0, int(round(math.log(1 + c) * 1000)))

    return map_weight


def make_mapper(freq, band, unknown_band):
    lo, hi = band
    ulo, uhi = unknown_band
    wmin, wmax = 451, 5000
    logwmax = math.log(1 + (wmax - wmin) / 100)

    def map_weight(word, old):
        cw = freq.get(word)
        if cw is not None:
            return max(1, int(round(lo + (hi - lo) * cw / 1000.0)))
        if old <= wmin:
            return ulo
        r = math.log(1 + (old - wmin) / 100) / logwmax
        return max(1, int(round(ulo + (uhi - ulo) * r)))

    return map_weight


def reweight_file(path, map_weight, dry_run=False, stats=None):
    lines = open(path, encoding="utf-8").read().split("\n")
    started = False
    out, changed, known = [], 0, 0
    for line in lines:
        if not started:
            out.append(line)
            if line.rstrip() == "...":
                started = True
            continue
        p = line.split("\t")
        if len(p) >= 3 and p[2].isdigit():
            new = map_weight(p[0], int(p[2]))
            if new != int(p[2]):
                changed += 1
            if stats is not None:
                stats.append((int(p[2]), new))
            p[2] = str(new)
            out.append("\t".join(p))
        else:
            out.append(line)
    if not dry_run:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(out))
    return changed, len(out)


def reweight_chars(path, scale, cap, dry_run=False):
    """字表缩放：weight -> max(1, min(round(w*scale), cap or inf))。

    为什么要缩放字表：poet 按**段权重求和**比较，而 log 词频天然满足
    log f(词) < log f(字1)+log f(字2) → 不压字，双字组合总是赢过词。
    拼音字表当前未做 ×0.35（五笔字表做了），是全拼组句弱的直接原因。
    """
    lines = open(path, encoding="utf-8").read().split("\n")
    started = False
    out, n = [], 0
    for line in lines:
        if not started:
            out.append(line)
            if line.rstrip() == "...":
                started = True
            continue
        p = line.split("\t")
        if len(p) >= 3 and p[2].isdigit():
            w = int(p[2])
            new = max(1, int(round(w * scale)))
            if cap:
                new = min(new, cap)
            p[2] = str(new)
            n += 1
            out.append("\t".join(p))
        else:
            out.append(line)
    if not dry_run:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(out))
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--freq", default=DEFAULT_FREQ,
                    help="词频来源：word_freq.tsv 或 rime-frequency 重扫输出")
    ap.add_argument("--band", default="100,1000",
                    help="语料命中词的权重区间（默认 100,1000）")
    ap.add_argument("--unknown-band", default="100,300",
                    help="语料未命中词（长尾）的权重区间")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--scale", choices=["band", "log1000"], default="band",
                    help="band=归一到 0-1000（旧）；log1000=log(1+count)*1000"
                         "（与 LM 同尺度，推荐）")
    ap.add_argument("--char-scale", type=float, default=1.0,
                    help="拼音字表缩放系数（默认 1.0=不动；0.35 与五笔字表一致）")
    ap.add_argument("--char-from-lm", default=None,
                    help="用 LM 表的 1gram 重标字表（log 尺度），配合 --char-shift 调平衡")
    ap.add_argument("--char-shift", type=int, default=0,
                    help="字表整体下移量（log*1000 尺度）。字频恒高于词频，需下移才能让词胜出")
    ap.add_argument("--char-cap", type=int, default=0,
                    help="字表权重上限（0=不设；用于压住超高频字碾碎词的情况）")
    ap.add_argument("--words-only", action="store_true",
                    help="只处理词表，不动字表")
    args = ap.parse_args()

    if not os.path.exists(args.freq):
        sys.exit(f"缺少词频表: {args.freq}（先跑 scripts/corpus/freq.py）")
    band = tuple(int(x) for x in args.band.split(","))
    uband = tuple(int(x) for x in args.unknown_band.split(","))

    counts = load_freq(args.freq)
    freq = log_norm(counts)
    globals()["counts"] = counts
    print(f"词频来源: {args.freq}")
    print(f"  {len(counts)} 词（最高频次 {max(counts.values()) if counts else 0}）")
    print(f"映射: 命中 {band[0]}~{band[1]}（按语料 log-norm）  "
          f"未命中 {uband[0]}~{uband[1]}（按万象权重的相对序）")
    if args.scale == "log1000":
        mapper = make_log_mapper(counts)
        print("映射: log(1+count)*1000（与 LM 表同尺度）")
    else:
        mapper = make_mapper(freq, band, uband)

    files = sorted({f for pat in PATTERNS for f in glob.glob(pat)})
    if not files:
        sys.exit("没找到词表文件")
    stats = []
    for path in files:
        changed, total = reweight_file(path, mapper, args.dry_run, stats)
        print(f"  {os.path.basename(path):<48} {changed:>7}/{total} 条改写")

    if stats:
        olds = sorted(o for o, _ in stats)
        news = sorted(n for _, n in stats)
        print(f"\n旧权重: min={olds[0]} p50={olds[len(olds)//2]} max={olds[-1]}")
        print(f"新权重: min={news[0]} p50={news[len(news)//2]} max={news[-1]}")
        hit = sum(1 for o, n in stats if n >= band[0])
        print(f"落在语料命中带(>={band[0]})的词: {hit}/{len(stats)}")
    # 整链 log 重标定：词 = log f(w)*1000，字 = log f(c)*1000 - shift
    if args.char_from_lm:
        import math
        lm = {}
        for line in open(args.char_from_lm, encoding="utf-8"):
            k, _, v = line.rstrip("\n").partition("\t")
            if len(k) == 1 and v.isdigit():
                lm[k] = int(v)
        print(f"\n字表 log 重标定（shift={args.char_shift}，unigram {len(lm)} 字）")
        for path in (CHAR_DICTS + [os.path.join(OUT, "egret_wubi_py_chars.dict.yaml")]):
            if not os.path.exists(path):
                continue
            lines = open(path, encoding="utf-8").read().split("\n")
            started, out, n = False, [], 0
            for line in lines:
                if not started:
                    out.append(line)
                    if line.rstrip() == "...":
                        started = True
                    continue
                q = line.split("\t")
                if len(q) >= 3 and q[2].isdigit() and len(q[0]) == 1:
                    u = lm.get(q[0])
                    if u:
                        q[2] = str(max(0, u - args.char_shift))
                        n += 1
                out.append("\t".join(q))
            if not args.dry_run:
                open(path, "w", encoding="utf-8").write("\n".join(out))
            print(f"  {os.path.basename(path):<46} {n:>7} 条重标")

    if args.char_scale != 1.0 or args.char_cap:
        if args.words_only:
            print("(--words-only，跳过字表)")
        else:
            print(f"\n字表缩放: x{args.char_scale}"
                  + (f" cap={args.char_cap}" if args.char_cap else ""))
            for path in CHAR_DICTS:
                if os.path.exists(path):
                    n = reweight_chars(path, args.char_scale, args.char_cap,
                                       args.dry_run)
                    print(f"  {os.path.basename(path):<48} {n:>7} 条缩放")

    if args.dry_run:
        print("\n(dry-run，未写入)")
    else:
        print("\n已写入；回滚: git checkout -- dicts/egret_wubi_py")


if __name__ == "__main__":
    main()
