#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用**自有语料**挖四字词并生成 86 词组码词表（H14，§4.67）。

背景：`社会主义 / 人工智能 / 人民群众 / 一段时间 / 也就是说` 这类四字词，
词库里**没有**、仓库里也**没有源**（万象词库只收 2/3 字词）。
而四字词的五笔码 = 每字首码，用户按标准码打却出不来（实测 `pwyy(社会主义)→空方`：
被 2+2 读法赢走）⇒ 属**能力缺口**，不是排序微调。

做法：
  1. jieba 切分自有语料（`data/corpus/clean/{para,shards}`）→ 统计四字词频
     （jieba 的 4 字 token 基本都是真词/真短语，免去跨词边界噪声）；
  2. 只保留**我们词库没有**的、且计数 >= --min-count 的；
  3. 权重：按 log 词频映射到 **[300, 450]** —— **封顶在长尾带**，
     确保永远排在精编词（base 档 >=451）之后，不重演"扩档伤排序"（§4.53）；
  4. 五笔码 = 每字首码（字首码从 `egret_wubi_words_wb86_base` 的二字词**自举**，
     回验 100%，§4.60）；查不到字码的条目跳过并统计。

产物 `dicts/egret_wubi_words_wb86_mined4.dict.yaml` 由 `egret_wubi.dict.yaml` 引入；
`refresh.sh` 已接（无 data/corpus 时跳过，用仓库内已有产物）。

用法:
  python3 scripts/gen_wubi_86_mined_4char.py --mine-mb 800     # 现场挖（慢，需 jieba+语料）
  python3 scripts/gen_wubi_86_mined_4char.py --tsv /tmp/m4.tsv # 用已挖好的 (词\\t计数)
  python3 scripts/gen_wubi_86_mined_4char.py --min-count 50 --dry-run
"""

import argparse
import collections
import glob
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402
from keyname_priority import caps as keyname_caps, cap_weight  # noqa: E402

DICTS = rime_paths.DICTS
OUT_NAME = "egret_wubi_words_wb86_mined4"
EXCLUDE = ["egret_wubi_words_wb86_base.dict.yaml", "egret_wubi_words_wb86_longtail.dict.yaml",
           "egret_wubi_words_wb86_src.dict.yaml", "egret_py_chengyu.dict.yaml",
           "egret_py_words_base.dict.yaml", "egret_py_words_longtail.dict.yaml",
           "egret_wubi_sentence.dict.yaml", "chengyu.dict.yaml"]
CJK = re.compile(r"^[\u4e00-\u9fff]+$")


def rows(path):
    out, started = [], False
    for line in open(path, encoding="utf-8"):
        if not started:
            if line.rstrip() == "...":
                started = True
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 3 and f[2].replace(".", "").isdigit():
            out.append((f[0].strip(), f[1], int(float(f[2]))))
    return out


def mine(mb, files_glob):
    """jieba 切分语料，统计四字词频"""
    import jieba
    cnt = collections.Counter()
    limit, read = mb * 1024 * 1024, 0
    for p in files_glob:
        if read >= limit:
            break
        try:
            with open(p, encoding="utf-8", errors="ignore") as f:
                while read < limit:
                    chunk = f.read(4 << 20)
                    if not chunk:
                        break
                    read += len(chunk.encode("utf-8", "ignore"))
                    for w in jieba.cut(chunk):
                        if len(w) == 4 and CJK.match(w):
                            cnt[w] += 1
        except OSError:
            pass
    print(f"  挖掘：读 {read / 2 ** 20:.0f} MB，不同四字词 {len(cnt):,}", file=sys.stderr)
    return cnt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mine-mb", type=int, default=0, help="现场挖语料（MB）；0=不用")
    ap.add_argument("--tsv", default="", help="已挖好的 词\\t计数 文件")
    ap.add_argument("--min-count", type=int, default=50)
    ap.add_argument("--w-lo", type=int, default=300, help="长尾权重下界")
    ap.add_argument("--w-hi", type=int, default=450, help="长尾权重上界（必须 < base 阈值 451）")
    ap.add_argument("--out", default=OUT_NAME)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if args.tsv:
        cnt = collections.Counter()
        for line in open(args.tsv, encoding="utf-8"):
            w, c = line.rstrip("\n").split("\t")[:2]
            cnt[w] = int(c)
    elif args.mine_mb:
        files = sorted(glob.glob(os.path.join(rime_paths.DATA, "corpus", "clean", "para", "*.txt"))) \
            + sorted(glob.glob(os.path.join(rime_paths.DATA, "corpus", "clean", "shards", "*.txt")))
        if not files:
            sys.exit("没有 data/corpus/clean/{para,shards}，无法挖掘")
        cnt = mine(args.mine_mb, files)
    else:
        sys.exit("需要 --tsv 或 --mine-mb")

    have = set()
    for f in EXCLUDE:
        p = os.path.join(DICTS, f)
        if os.path.exists(p):
            have |= {w for w, _c, _wt in rows(p)}

    base = rows(os.path.join(DICTS, "egret_wubi_words_wb86_base.dict.yaml"))
    votes = collections.defaultdict(collections.Counter)
    for w, c, _wt in base:
        if len(w) == 2 and len(c) == 4 and " " not in c:
            votes[w[0]][c[:2]] += 1
            votes[w[1]][c[2:]] += 1
    c2 = {ch: v.most_common(1)[0][0] for ch, v in votes.items()}

    cand = [(w, c) for w, c in cnt.items() if c >= args.min_count and w not in have]
    cand.sort(key=lambda x: -x[1])
    lo, hi = args.min_count, max(c for _w, c in cand)
    llo, lhi = math.log(1 + lo), math.log(1 + hi)

    out, skipped = [], 0
    for w, c in cand:
        cs = [c2.get(ch) for ch in w]
        if any(x is None for x in cs):
            skipped += 1
            continue
        wt = args.w_lo + int((args.w_hi - args.w_lo) * (math.log(1 + c) - llo) / max(lhi - llo, 1e-9))
        out.append((w, "".join(x[:1] for x in cs), min(args.w_hi, max(args.w_lo, wt))))
    print(f"候选（计数>={args.min_count} 且词库没有）{len(cand):,}；"
          f"可生成码 {len(out):,}；字缺映射跳过 {skipped}")
    for w, code, wt in out[:6]:
        print(f"  例: {w} → {code}  w={wt}")
    if args.dry_run:
        print("（dry-run，未写入）")
        return

    # 键名字优先：四字词的 1+1+1+1 码撞上键名字时让字在前（如 恭恭敬敬 aaaa 不能压住 工，§4.76）
    kcaps = keyname_caps(DICTS)
    capped = 0
    fixed = []
    for w, code, wt in out:
        new_wt, was_capped = cap_weight(code, wt, kcaps)
        capped += 1 if was_capped else 0
        fixed.append((w, code, new_wt))
    out = fixed
    if capped:
        print(f"  键名字优先：压权重 {capped} 条")

    path = os.path.join(DICTS, args.out + ".dict.yaml")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        f.write("# RIME dictionary\n# 由 scripts/gen_wubi_86_mined_4char.py 生成，请勿手改\n")
        f.write(f"# 四字词（自有语料 jieba 挖掘，计数 >= {args.min_count}；权重 {args.w_lo}~{args.w_hi} 长尾带）\n")
        f.write("# 五笔码 = 每字首码（字首码自举自 wb86 二字词，回验 100%）；见 PROGRESS §4.67\n")
        f.write(f"name: {args.out}\nversion: \"2026.10\"\nsort: by_weight\n")
        f.write("use_preset_vocabulary: false\ncolumns:\n  - text\n  - code\n  - weight\n...\n")
        for w, code, wt in out:
            f.write(f"{w}\t{code}\t{wt}\n")
    os.replace(path + ".tmp", path)
    print(f"写出 {path}：{len(out):,} 词")


if __name__ == "__main__":
    main()
