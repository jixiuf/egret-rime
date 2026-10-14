#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成**混打（五笔+拼音）整句评测集**：把固定的全拼评测集句子改写成真实混打输入。

背景（docs/PROGRESS.md §4.87）：
    长句评测一直是**纯拼音**的（160 句），而用户实际大量用的是「前几个词五笔、
    后面拼音」的混打（如 `qdynwqcegandeshang` = 五笔 希望你能 + 拼音 赶得上）。
    纯拼音测不到混打的退化：混打里跨"五笔/拼音"边界的多字词（希望你能|赶得上 之间）
    因为词条只有纯五笔或纯拼音拼写而命不中，退化单字后同音字被 grammar 带偏。
    ⇒ 需要一个**固定、可复现**的混打整句集，作为评分/回归门。

做法：
    1. 以固定的 `data/corpus/eval/sentences_v2.tsv`（160 句）为唯一来源；
    2. jieba 分词；按若干**真实混打模式**把部分词的拼音替换成五笔码
       （多字词用词码，如 希望=qdyn；单字用短码）；
    3. 输出固定文件 `data/corpus/eval/mixed.tsv`（**生成一次即冻结**，
       与句子集同规矩：语料变了也不许悄悄换题）。

混打模式（都来自真实习惯，不是构造出来的怪输入）：
    head1  首词五笔 + 其余拼音          （打完第一个词后切拼音）
    head2  前两个词五笔 + 其余拼音      （用户报的 qdynwqcegandeshang 就是这种）
    tail1  其余拼音 + 末词五笔          （想到哪个词才切形码）
    alt    词级交替（五笔/拼音/五笔…）  （§4.83 ililfbyihaole 那种分散混打）

用法:
  python3 scripts/gen_mixed_eval.py                 # 生成（已存在则不动）
  python3 scripts/gen_mixed_eval.py --force         # 强制重生成
  EVAL_MIXED_FILE=... python3 scripts/gen_mixed_eval.py
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "corpus"))
import rime_paths  # noqa: E402

ROOT = rime_paths.REPO
DICTS = rime_paths.DICTS
EVAL_DIR = os.path.join(rime_paths.DATA, "corpus", "eval")
SENT = os.path.join(EVAL_DIR, "sentences_v2.tsv")
# 输出**入 git**（data/ 全被 gitignore）：评测集要跨机一致，否则两台机不同题、
# 分数不可比（句子集 sentences_v2.tsv 是本地生成，这里不再重蹈覆辙）
OUT = os.environ.get("EVAL_MIXED_FILE") or os.path.join(HERE, "eval_sets", "mixed.tsv")

CJK = lambda ch: "\u4e00" <= ch <= "\u9fff"


def dict_rows(path):
    started = False
    for line in open(path, encoding="utf-8"):
        if not started:
            if line.rstrip() == "...":
                started = True
            continue
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3 and p[2].isdigit():
            yield p[0], p[1].lower()


def load_char_codes():
    """单字 -> 最短五笔码（一级/二级简码优先，真实用户就这么敲）。"""
    best = {}
    for word, code in dict_rows(os.path.join(DICTS, "egret_wubi_chars.dict.yaml")):
        if len(word) == 1 and code.isalpha() and 1 <= len(code) <= 4:
            if word not in best or len(code) < len(best[word]):
                best[word] = code
    return best


def load_word_codes():
    """多字词 -> 词码（86 造词码；无词码时用单字短码拼接）。"""
    best = {}
    for fname in ("egret_wubi_words_wb86_full.dict.yaml",
                  "egret_wubi_words_wb86_base.dict.yaml"):
        path = os.path.join(DICTS, fname)
        if not os.path.exists(path):
            continue
        for word, code in dict_rows(path):
            if len(word) >= 2 and code.isalpha() and 2 <= len(code) <= 12:
                if word not in best or len(code) < len(best[word]):
                    best[word] = code
    return best


def make_code(words, indices, char_code, word_code):
    """把 words 里 indices 那些词换成五笔码，其余换拼音；任一词无码则返回 None。"""
    out = []
    for i, w in enumerate(words):
        if i in indices:
            code = word_code.get(w)
            if not code:
                cc = []
                for ch in w:
                    if ch not in char_code:
                        return None
                    cc.append(char_code[ch])
                code = "".join(cc)
            out.append(code)
        else:
            try:
                from pypinyin import lazy_pinyin
            except ImportError:
                sys.exit("需要 pypinyin（third-party/venv 里有）")
            out.append("".join(lazy_pinyin(w)))
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true", help="已存在也重生成")
    a = ap.parse_args()

    if os.path.exists(OUT) and not a.force:
        n = sum(1 for _ in open(OUT, encoding="utf-8")) - 1
        print(f"评测集已存在，未改动: {OUT}（{n} 条；--force 可重生成）")
        return 0
    if not os.path.exists(SENT):
        sys.exit(f"缺少固定句子集: {SENT}")

    import jieba
    jieba.setLogLevel(60)

    char_code = load_char_codes()
    word_code = load_word_codes()
    print(f"码表: 单字 {len(char_code):,} / 多字词 {len(word_code):,}")

    sentences = []
    for line in open(SENT, encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 2:
            sentences.append((p[1], p[2] if len(p) > 2 else ""))

    rows = []          # (input, expect, pattern, source)
    stat = {}
    for text, src in sentences:
        if not all(CJK(c) for c in text):
            continue
        words = [w for w in jieba.cut(text) if w.strip()]
        if len(words) < 2:
            continue
        patterns = {}
        patterns["head1"] = {0}
        patterns["head2"] = {0, 1}
        patterns["tail1"] = {len(words) - 1}
        patterns["alt"] = {i for i in range(len(words)) if i % 2 == 0}
        for name, idx in patterns.items():
            code = make_code(words, idx, char_code, word_code)
            if not code or code.isdigit():
                continue
            rows.append((code, text, name, src))
            stat[name] = stat.get(name, 0) + 1

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    os.makedirs(EVAL_DIR, exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# 混打整句评测集（由 scripts/gen_mixed_eval.py 生成，冻结勿手改）\n")
        f.write("# 列: 输入码\t期望整句\t混打模式\t来源\n")
        for r in rows:
            f.write("\t".join(r) + "\n")
    os.replace(tmp, OUT)
    print(f"写出 {OUT}: {len(rows)} 条  " +
          " ".join(f"{k}={v}" for k, v in sorted(stat.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
