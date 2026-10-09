#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""五笔打词评测（H11，§4.60）：打某词的**五笔全码**，看能不能出该词。

为什么需要：现有两套套件（160 句全拼、混流 40 例）都回答不了
「五笔用户打某个词，到底能不能打出来 / 排第几」——档位、长尾、字表权重
这类决策因此都没有公平度量。

口径：
  · 用例 = (86 词组码, 期望词)，期望词取自词表（按权重采样，可复现）
  · 判分 = 首候选是否等于期望词（top1）+ 期望词是否出现在前 N 个候选（topN）
    —— 前者衡量"排序对不对"，后者衡量"能不能打出来"（用户可翻页选择）
  · 五笔码由**已回验 100% 的规则**生成（2 字词 = 前 2 码 + 前 2 码，
    字的两码从 `egret_wubi_words_wb86_base` 自举；见 §4.60）

用法:
  python3 scripts/eval_wubi_words.py --n 100                     # 从 base 档采样
  python3 scripts/eval_wubi_words.py --src dicts/xxx.dict.yaml --n 100 --cohort 长尾
  python3 scripts/eval_wubi_words.py --n 100 --jobs 6 --dir data/rime-test
"""

import argparse
import collections
import os
import random
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402

CONSOLE = rime_paths.librime_tool("rime_api_console")
DICTS = rime_paths.DICTS


def load(path):
    """dict.yaml -> [(word, code, weight)]，只取正文行"""
    rows, started = [], False
    for line in open(path, encoding="utf-8"):
        if not started:
            if line.rstrip() == "...":
                started = True
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 3 and f[2].isdigit():
            rows.append((f[0].strip(), f[1], int(f[2])))
    return rows


def char2codes(pairs):
    """从 (词, 86码) 里自举「字 -> 两码」（二字词 4 码 = 前2 + 后2，多数票）"""
    votes = collections.defaultdict(collections.Counter)
    for w, c in pairs:
        if len(w) == 2 and len(c) == 4 and " " not in c:
            votes[w[0]][c[:2]] += 1
            votes[w[1]][c[2:]] += 1
    return {ch: cnt.most_common(1)[0][0] for ch, cnt in votes.items()}


def gen86(word, c2):
    """86 词组码（只支持 2 字词：本轮验证 100% 一致的那一类）"""
    if len(word) != 2:
        return None
    a, b = c2.get(word[0]), c2.get(word[1])
    return a + b if a and b else None


def top_candidates(code, cwd, timeout, want):
    p = subprocess.Popen([CONSOLE], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, cwd=cwd,
                         start_new_session=True)
    try:
        out, _ = p.communicate(code + "\n\n", timeout=timeout)
    except subprocess.TimeoutExpired:
        import signal
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            p.kill()
        out, _ = p.communicate()
    got = []
    for line in (out or "").splitlines():
        m = re.match(r"^[1-9]\.\s+\[?([^\]\s]+)\]?", line.strip())
        if m:
            got.append(m.group(1))
            if len(got) >= want:
                break
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(DICTS, "egret_wubi_words_wb86_base.dict.yaml"),
                    help="采样词源（默认 base 档五笔词表）")
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--want", type=int, default=8, help="看前几个候选判 topN")
    ap.add_argument("--cohort", default="", help="用例集名字（打印用）")
    ap.add_argument("--seed", type=int, default=20261009)
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--dir", default=rime_paths.RIME_TEST_DIR)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--weight-min", type=int, default=0)
    ap.add_argument("--weight-max", type=int, default=10 ** 9)
    ap.add_argument("--exclude-base", action="store_true",
                    help="排除 base 档已有的词（测「长尾缺口」时必须开，否则混入已覆盖的词）")
    args = ap.parse_args()

    ref = load(os.path.join(DICTS, "egret_wubi_words_wb86_base.dict.yaml"))
    c2 = char2codes([(w, c) for w, c, _ in ref])
    base_words = {w for w, _c, _wt in ref}
    pool = [(w, wt) for w, c, wt in load(args.src)
            if args.weight_min <= wt <= args.weight_max and len(w) == 2
            and (not args.exclude_base or w not in base_words)]
    # 按权重降序取前 3 倍，再随机采样（避免只测最高频，也避免全测碎片）
    pool.sort(key=lambda x: -x[1])
    pool = pool[: max(args.n * 3, args.n)]
    rnd = random.Random(args.seed)
    rnd.shuffle(pool)
    cases, seen = [], set()
    for w, wt in pool:
        code = gen86(w, c2)
        if code and code not in seen:
            seen.add(code)
            cases.append((code, w, wt))
        if len(cases) >= args.n:
            break

    label = args.cohort or os.path.basename(args.src)
    print(f"用例集 {label}: {len(cases)} 条（源 {os.path.basename(args.src)}，"
          f"权重 {args.weight_min}~{args.weight_max}）")

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        outs = list(ex.map(lambda c: top_candidates(c[0], args.dir, args.timeout, args.want),
                           cases))
    top1 = topn = 0
    miss = []
    for (code, want_word, wt), got in zip(cases, outs):
        if got and got[0] == want_word:
            top1 += 1
        if want_word in got:
            topn += 1
        else:
            miss.append((code, want_word, wt, got[0] if got else "(空)"))
    n = len(cases)
    print(f"  top1(首选=该词) {top1}/{n} ({top1/n*100:.0f}%)   "
          f"top{args.want}(能打出来) {topn}/{n} ({topn/n*100:.0f}%)")
    for code, w, wt, g in miss[:10]:
        print(f"    ✗ {code}  期望 {w}(w={wt})  实际 {g}")


if __name__ == "__main__":
    main()
