#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语料账本：读增量索引，输出各阶段产物的规模统计。

用法:
  python3 scripts/corpus/status.py            # 抽取阶段统计
  python3 scripts/corpus/status.py --json     # 机器可读
"""

import argparse
import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C  # noqa: E402


def collect():
    recs = {}
    for line in open(C.INDEX, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if r.get("key"):
            recs[r["key"]] = r
    ok = [r for r in recs.values() if r.get("status") == "ok"]
    err = [r for r in recs.values() if r.get("status") != "ok"]
    agg = collections.defaultdict(lambda: dict(n=0, chars=0, cjk=0))
    for r in ok:
        f = r.get("fmt") or r.get("source") or "?"
        a = agg[f]
        a["n"] += 1
        a["chars"] += r.get("chars", 0)
        a["cjk"] += r.get("cjk", 0)
    return recs, ok, err, agg


def dir_size(path):
    total = 0
    for dp, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(dp, f))
            except OSError:
                pass
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    recs, ok, err, agg = collect()
    size = dir_size(C.EXTRACT)
    if args.json:
        print(json.dumps(dict(
            input=C.INPUT, index=C.INDEX, entries=len(recs), ok=len(ok),
            err=len(err), extract_bytes=size,
            by_fmt={k: v for k, v in agg.items()}), ensure_ascii=False,
            indent=1))
        return

    print(f"输入目录: {C.INPUT}")
    print(f"索引:     {C.INDEX}")
    print(f"条目 {len(recs)}  成功 {len(ok)}  失败 {len(err)}\n")
    print(f"{'格式':<10}{'篇数':>8}{'字符(亿)':>12}{'汉字(亿)':>12}")
    for f, a in sorted(agg.items(), key=lambda x: -x[1]["chars"]):
        print(f"{f:<10}{a['n']:>8}{a['chars']/1e8:>12.3f}{a['cjk']/1e8:>12.3f}")
    tc = sum(a["chars"] for a in agg.values())
    tj = sum(a["cjk"] for a in agg.values())
    print(f"{'合计':<10}{len(ok):>8}{tc/1e8:>12.3f}{tj/1e8:>12.3f}")
    print(f"\n抽取产物: {size/2**30:.2f} GB")
    if err:
        print("\n失败条目:")
        for r in err[:10]:
            print(f"  {r.get('name')}: {r.get('err')}")


if __name__ == "__main__":
    main()
