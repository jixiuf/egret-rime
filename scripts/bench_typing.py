#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""输入延迟基准（性能回归门，H5）。

为什么需要：本仓库的改动经常是"往词库里加东西"（长尾/四字词/成语…），
而**词表变大直接推高每键耗时**（prism/table 变大、候选变长）。此前只能靠人肉体感，
等到"打字卡"才发现。这个脚本把**固定输入的整串重放耗时**变成可比的数字：
超过基线一定比例就报 FAIL。

口径（刻意选简单的）：
  · 输入 = `rime_api_console` 喂**整串**拼音（引擎会逐键重放，等价于用户连续键入）；
  · 取多轮的中位数（机器负载波动大，单次不可信）；
  · 报告每个输入的耗时 + 相对基线的比例；用 `--max-scale` 做门限（默认 1.5×）。
  · 另附 `--per-key` 说明：整串耗时 ÷ 键数 ≈ 每键均值（含一次性码表/词库加载）。

注意：这是**趋势门**不是精确 benchmark（同机同日对比才有意义）；
真正的每键分解（引擎 vs 搜索器）需要用 MIXSEG 调试日志，见 docs/PROGRESS.md §4.50。

用法:
  python3 scripts/bench_typing.py                       # 默认基线（见 BASELINE）
  python3 scripts/bench_typing.py --update-baseline     # 打印新基线，人工写回
  python3 scripts/bench_typing.py --max-scale 1.5       # 超 1.5x 即 exit 1
"""

import argparse
import os
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402

CONSOLE = rime_paths.librime_tool("rime_api_console")

# 固定输入（来自评测集，长/中/短各一）+ 2026-10-10 本机中位数基线（秒）
CASES = [
    ("jintiandetianqizenmeyang", 24),                                  # 短（常用输入）
    ("yiwangdeshixigongzuoshizuoshenme", 32),                          # 中
    ("duzhemenyijingduiqichehedianyingpinglunshiqulexingqu", 52),      # 长（最坏情况）
]
BASELINE = {
    "jintiandetianqizenmeyang": 3.52,
    "yiwangdeshixigongzuoshizuoshenme": 6.19,
    "duzhemenyijingduiqichehedianyingpinglunshiqulexingqu": 12.92,
}


def time_once(code, cwd, timeout):
    t0 = time.time()
    subprocess.run([CONSOLE], input=code + "\n\n", capture_output=True,
                   text=True, cwd=cwd, timeout=timeout)
    return time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=rime_paths.RIME_TEST_DIR)
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--max-scale", type=float, default=1.5,
                    help="相对基线的允许倍数（超过即 exit 1）")
    ap.add_argument("--update-baseline", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(args.dir):
        sys.exit(f"没有测试目录 {args.dir}（先 make env-test）")

    print(f"输入延迟基准（{args.rounds} 轮取中位数；目录 {args.dir}）")
    print(f"{'输入':<52}{'耗时':>9}{'每键':>9}{'基线':>9}{'倍数':>8}  判定")
    worst, fails = 0.0, 0
    new_baseline = {}
    for code, _n in CASES:
        ts = sorted(time_once(code, args.dir, args.timeout) for _ in range(args.rounds))
        med = statistics.median(ts)
        new_baseline[code] = round(med, 2)
        base = BASELINE.get(code)
        scale = med / base if base else 0
        worst = max(worst, scale)
        if args.update_baseline or not base:
            mark = "（新基线）"
        elif scale > args.max_scale:
            mark = "FAIL"
            fails += 1
        else:
            mark = "ok"
        print(f"{code[:50]:<52}{med:>8.2f}s{med / len(code) * 1000:>8.0f}ms"
              f"{(f'{base:.2f}s' if base else '—'):>9}{(f'{scale:.2f}x' if base else '—'):>8}  {mark}")
    print(f"\n最坏倍数 {worst:.2f}x（门限 {args.max_scale}x）"
          + ("  → 全部通过 ✓" if not fails else f"  → {fails} 项超门限 ✗"))
    if args.update_baseline:
        print("\n把下面这段写回脚本的 BASELINE：")
        print("BASELINE = {")
        for k, v in new_baseline.items():
            print(f'    "{k}": {v},')
        print("}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
