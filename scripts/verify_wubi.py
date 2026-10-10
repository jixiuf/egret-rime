#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""五笔能力验收（H11 五组 + 阈值，性能安全的一键回归门）。

为什么需要：本轮往词库里加了大量条目（二字长尾 8.3 万 / 三字长尾 3.1 万 /
四字挖掘 8703）。**加词容易、退化难察**——某次改动可能让长尾词重新"打不出来"、
或让 base 词被挤掉。这个脚本用固定的采样 cohort + 阈值把能力**钉住**，
以后每次改词库/权重/码式，一条命令就能看出有没有退化。

阈值是"比实测低一点"（留出抖动余量），只拦真退化。用例可复现（固定 seed + 权重降序采样）。

用法:
  python3 scripts/verify_wubi.py            # 跑五组，超阈即 exit 1
  python3 scripts/verify_wubi.py --n 30     # 改每组采样数（默认 40，约 1 分钟）
"""

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PY = sys.executable

# (名称, 词源, 词长, 三字词口径, 权重下界, 权重上界, 是否排除 base, top1 下限, top8 下限)
COHORTS = [
    ("二字 base",   "dicts/egret_wubi_words_wb86_base.dict.yaml",            2, "std", 451, 10**9, False, 0.95, 0.98),
    ("二字长尾",    "dicts/egret_wubi_words_wangxiang_full.dict.yaml",       2, "std", 300, 450,   True,  0.32, 0.88),
    ("三字 base",   "dicts/egret_wubi_words_wb86_base.dict.yaml",            3, "std", 451, 10**9, False, 0.84, 0.95),
    ("三字长尾",    "dicts/egret_wubi_words_wangxiang_full.dict.yaml",       3, "std", 300, 450,   True,  0.30, 0.88),
    ("四字 挖掘",   "dicts/egret_wubi_words_wb86_mined4.dict.yaml",          4, "std", 0,   10**9, False, 0.72, 0.95),
]
ROW = re.compile(r"top1\(首选=该词\)\s+(\d+)/(\d+)\s+\((\d+)%\)\s+top8\(能打出来\)\s+(\d+)/(\d+)\s+\((\d+)%\)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--dir", default=os.path.join(REPO, "data", "rime-test"))
    args = ap.parse_args()

    print(f"五笔能力验收（每组 {args.n} 例；阈值见脚本 COHORTS）")
    print(f"{'组':<12}{'top1':>8}{'要求':>8}{'top8':>8}{'要求':>8}  判定")
    bad = 0
    for name, src, wl, rule3, wmin, wmax, excl, min1, min8 in COHORTS:
        cmd = [PY, os.path.join(HERE, "eval_wubi_words.py"), "--src", src,
               "--word-len", str(wl), "--rule3", rule3,
               "--weight-min", str(wmin), "--weight-max", str(wmax),
               "--n", str(args.n), "--dir", args.dir, "--cohort", name]
        if excl:
            cmd.append("--exclude-base")
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
        m = ROW.search(out)
        if not m:
            print(f"{name:<12}{'—':>8}{'—':>8}{'—':>8}{'—':>8}  解析失败 ✗")
            bad += 1
            continue
        t1, n1, p1, t8, n8, p8 = (int(x) for x in m.groups())
        ok = (p1 / 100 >= min1) and (p8 / 100 >= min8)
        if not ok:
            bad += 1
        print(f"{name:<12}{f'{t1}/{n1}':>8}{f'≥{min1:.0%}':>8}{f'{t8}/{n8}':>8}{f'≥{min8:.0%}':>8}  {'ok' if ok else 'FAIL ✗'}")
    print(f"\n{'全部通过 ✓' if not bad else f'{bad} 组低于阈值 ✗'}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
