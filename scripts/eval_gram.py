#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gram AB 评测：同一词库下对比多套语言模型的首候选命中率。

评测集：
  A) 黄金用例（scripts/regression_test.py 的 CASES，简码/全码/词组/组句）
  B) 混合拼写用例（首字五笔 2 码 + 次字拼音）——由词库自动生成，可复现：
     取 base.small 权重最高的 N 个二字词，首字取五笔二级码、次字取拼音音节。
     这是本方案的主场景（五笔+拼音混流），对 LM 最敏感。

切换 gram 的方式：在测试用户目录写 `egret_wubi_py.custom.yaml` 打 patch
（与真实用户切换方式一致），不动仓库里的 egret.common.yaml。

用法:
  python3 scripts/eval_gram.py                        # essay-bgc vs 自训
  python3 scripts/eval_gram.py --cases 40
  python3 scripts/eval_gram.py --gram "自训=data/gram/zh-hans-egret.gram"
  python3 scripts/eval_gram.py --list                 # 只看评测集
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402

DICTS = rime_paths.DICTS
CONSOLE = rime_paths.librime_tool("rime_api_console")
DEPLOYER = rime_paths.librime_tool("rime_deployer")
TEST_DIR = rime_paths.RIME_TEST_DIR
SHARED_DIR = rime_paths.RIME_SHARED_DIR

BASE_SMALL = os.path.join(DICTS, "wb86_wangxiang_cn_dicts", "base.small.dict.yaml")
PINYIN_8105 = os.path.join(DICTS, "egret_py_chars.dict.yaml")   # dicts/ 已扁平化

# 与 regression_test.py 保持一致的黄金用例（子集：对 LM 有意义的那些）
GOLDEN = [
    ("e", "有"), ("q", "我"), ("yi", "就"), ("yl", "为"), ("kl", "另"),
    ("de", "胡"), ("tffu", "等"), ("khlg", "中国"), ("xciy", "经济"),
    ("kdyc", "顺序"), ("trwu", "我们"), ("trwuchifan", "我们吃饭"),
    ("jfwaguangfnrt", "时代广场"), ("jintiandetianqizenmeyang", "今天的天气怎么样"),
    ("tamenlailehenduoren", "他们来了很多人"), ("wojintianmeiyoukong", "我今天没有空"),
    ("tgtj", "生不逢时"), ("wan", "万"), ("taiwan", "台湾"), ("ckiy", "台湾"),
]


def rows(path):
    started = False
    for line in open(path, encoding="utf-8"):
        if not started:
            if line.rstrip() == "...":
                started = True
            continue
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3 and p[2].isdigit():
            yield p


def load_pinyin():
    """字 -> 无调音节（取权重最高者；多音字只留主读音）。"""
    best = {}
    for p in rows(PINYIN_8105):
        ch, syl, w = p[0], p[1], int(p[2])
        if len(ch) != 1 or not syl:
            continue
        if ch not in best or w > best[ch][1]:
            best[ch] = (syl, w)
    return {k: v[0] for k, v in best.items()}


def build_mixed_cases(n):
    """首字五笔 2 码 + 次字拼音 的混流用例。

    - 按权重降序取高频二字词（不是文件顺序，否则拿到阿爸这类低频词）
    - 同码只留权重最高的词：同音同码时"该码应出哪个词"的公平期望就是最高频那个
    """
    pinyin = load_pinyin()
    by_code = {}
    for p in rows(BASE_SMALL):
        word, code, w = p[0], p[1], int(p[2])
        if len(word) != 2:
            continue
        toks = code.split(" ")
        if len(toks) != 2:
            continue
        c1 = toks[0].split(",")[0][:2]
        syl = pinyin.get(word[1])
        if not c1 or not syl:
            continue
        mk = c1 + syl
        if mk not in by_code or w > by_code[mk][1]:
            by_code[mk] = (word, w)
    cases = sorted(((c, w, wt) for c, (w, wt) in by_code.items()),
                   key=lambda x: -x[2])
    return cases[:n]


def build_sentence_cases(n, min_len=4, max_len=12, seed=20260927,
                         regen=False):
    """句子级 LM 判别集：语料短句 → 全拼输入 → 看能否还原原句。

    **测评集必须固定**：否则语料一变、采样就变，两次评测不同题，
    分数不可比（这一坑已踩：16/100 与 12/100 实际是两套题）。
    首次从 clean/short 采样并存到 data/corpus/eval/sentences.tsv，
    之后固定复用；--regen-sentences 可重建。
    """
    import random
    try:
        from pypinyin import lazy_pinyin
    except ImportError:
        sys.exit("句子评测需要 pypinyin（第三方 venv 里有）")

    sent_file = os.environ.get("EVAL_SENT_FILE") or next(
        (p for p in (os.path.join(rime_paths.DATA, "corpus", "eval", "sentences_v2.tsv"),
                     os.path.join(rime_paths.DATA, "corpus", "eval", "sentences.tsv"))
         if os.path.exists(p)), "")
    if os.path.exists(sent_file) and not regen:
        out = []
        with open(sent_file, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 2:
                    out.append((p[0], p[1]))
        print(f"  评测集: {sent_file}（固定 {len(out)} 句）")
        return out[:n] if n else out

    rnd = random.Random(seed)
    cands = []
    for path in sorted(glob.glob(os.path.join(rime_paths.DATA, "corpus", "clean",
                                              "short", "*.txt"))):
        with open(path, encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if min_len <= len(s) <= max_len and all(
                        "\u4e00" <= c <= "\u9fff" for c in s):
                    cands.append(s)
    rnd.shuffle(cands)
    out = []
    for s in cands:
        syl = lazy_pinyin(s)
        if any(not y.isalpha() for y in syl):
            continue
        out.append(("".join(syl), s))
        if n and len(out) >= n:
            break
    os.makedirs(os.path.dirname(sent_file), exist_ok=True)
    with open(sent_file, "w", encoding="utf-8") as f:
        for code, s in out:
            f.write(f"{code}\t{s}\n")
    print(f"  评测集: 已生成并固定到 {sent_file}（{len(out)} 句）")
    return out


def reset_schema(user_dir):
    path = os.path.join(user_dir, "user.yaml")
    if os.path.exists(path):
        s = open(path, encoding="utf-8").read()
        s2 = re.sub(r"previously_selected_schema: \S+",
                    "previously_selected_schema: egret_wubi_py", s)
        if s2 != s:
            open(path, "w", encoding="utf-8").write(s2)


def first_candidate(code, cwd, timeout=25):
    """跑一次 console 取首候选。超时/异常返回 None（计为失败，不中断评测）。

    注：gram 过大时个别长句会搜索爆炸（曾见 180s+），故需短超时容错。
    """
    try:
        p = subprocess.run([CONSOLE], input=code + "\n\n", capture_output=True,
                           text=True, cwd=cwd, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    for line in p.stdout.splitlines():
        m = re.match(r"1\. \[([^\]]*)\]", line.strip())
        if m:
            return m.group(1)
    return None


def switch_gram(user_dir, gram_path, language):
    """把 gram 放进用户目录，并用 custom patch 切换 grammar/language。"""
    dst = os.path.join(user_dir, os.path.basename(gram_path))
    if os.path.abspath(gram_path) != os.path.abspath(dst):
        shutil.copy2(gram_path, dst)
    patch = os.path.join(user_dir, "egret_wubi_py.custom.yaml")
    with open(patch, "w", encoding="utf-8") as f:
        f.write("# 由 scripts/eval_gram.py 生成（评测用，切换语言模型）\n"
                "patch:\n"
                f"  grammar/language: {language}\n")
    subprocess.run([DEPLOYER, "--build", user_dir, SHARED_DIR,
                    os.path.join(user_dir, "build")],
                   capture_output=True, timeout=600)


GLOBAL_ARGS = None

def run_suite(user_dir, cases, label):
    hits = []
    if not cases:
        return hits
    # 并行跑：每个用例一个 console 进程。串行时大 gram（400MB）每次都要重新加载，
    # 160 句会跑几十分钟；并行 6 路后几分钟就够（语义不变，仍是一例一进程）。
    jobs = max(1, getattr(GLOBAL_ARGS, "jobs", 1) or 1)
    codes = [c[0] for c in cases]
    if jobs > 1:
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            outs = list(ex.map(lambda code: first_candidate(code, user_dir, timeout=120), codes))
    else:
        outs = [first_candidate(code, user_dir) for code in codes]
    for c, code, got in zip(cases, codes, outs):
        expect = c[1]
        reset_schema(user_dir)
        hits.append((code, expect, got, got == expect))
    ok = sum(1 for h in hits if h[3])
    print(f"  {label:<28} {ok}/{len(cases)}  ({ok/len(cases)*100:.0f}%)")
    return hits


def main():
    global GLOBAL_ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=30, help="混合用例条数")
    ap.add_argument("--sentences", type=int, default=0,
                    help="句子级评测条数（>0 时用全拼还原，测真实 LM 能力）")
    ap.add_argument("--regen-sentences", action="store_true",
                    help="重建固定评测集（默认为保证可比性不重建）")
    ap.add_argument("--dir", default=TEST_DIR)
    ap.add_argument("--gram", action="append", default=None,
                    help="label=path（可重复）")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--jobs", type=int, default=6,
                    help="并行度：每个用例一个 console 进程；大 gram(400MB) 串行会极慢")
    args = ap.parse_args()
    GLOBAL_ARGS = args

    grams = []
    if args.gram:
        for g in args.gram:
            label, path = g.split("=", 1)
            # 支持 "label=path|language" 显式指定语言名（用于构造无-gram 对照：
            #   --gram "无gram=/path/any.gram|no-such-gram"
            lang = None
            if "|" in path:
                path, lang = path.split("|", 1)
            if lang is None:
                lang = os.path.splitext(os.path.basename(path))[0]
            grams.append((label, path, lang))
    else:
        for label, path in [
            ("essay-bgc(现役)", os.path.join(rime_paths.GRAM_DIR,
                                             "zh-hans-t-essay-bgc.gram")),
            ("自训 zh-hans-egret", os.path.join(rime_paths.GRAM_DIR,
                                                "zh-hans-egret.gram")),
        ]:
            if os.path.exists(path):
                grams.append((label, path,
                              os.path.splitext(os.path.basename(path))[0]))
            else:
                print(f"  ! 缺少 {path}")
    if not grams:
        sys.exit("没有可评测的 gram")

    mixed = build_mixed_cases(args.cases)
    sentences = build_sentence_cases(args.sentences,
                                     regen=args.regen_sentences) if args.sentences else []
    print(f"评测集：黄金 {len(GOLDEN)} 条 + 混合拼写 {len(mixed)} 条"
          + (f" + 句子(全拼) {len(sentences)} 条" if sentences else ""))
    if args.list:
        for c, w, wt in mixed[:args.cases]:
            print(f"  {c:<20} -> {w}  (权重 {wt})")
        for code, s in sentences[:args.sentences]:
            print(f"  {code[:40]:<40} -> {s}")
        return
    print(f"用户目录: {args.dir}\n")

    results = {}
    for label, path, lang in grams:
        print(f"== {label} ({os.path.getsize(path)/2**20:.1f} MB, language={lang})")
        switch_gram(args.dir, path, lang)
        # 预热一次（部署后首个 session 有维护竞态）
        first_candidate("khlg", args.dir)
        reset_schema(args.dir)
        results[label] = {
            "golden": run_suite(args.dir, GOLDEN, "黄金用例"),
            "mixed": run_suite(args.dir, mixed, "混合拼写(多为词库决定)"),
        }
        if sentences:
            results[label]["sent"] = run_suite(args.dir, sentences, "句子(全拼)")

    if sentences:
        print("\n句子级对比（能还原原句记为 ✓）:")
        for code, s in sentences:
            row = []
            for label in results:
                hit = next((h for h in results[label]["sent"] if h[0] == code), None)
                row.append(("✓" if hit and hit[3] else "✗") + 
                           f" {((hit[2] if hit else '') or '?')[:10]:<12}")
            print(f"  {s:<12} " + "  ".join(row))

    print(f"\n{'用例':<22} " + "  ".join(f"{k[:16]:<16}" for k in results))
    print("-" * (22 + 18 * len(results)))
    all_cases = [("golden", c, e) for c, e in GOLDEN] + \
                [("mixed", c, w) for c, w, _ in mixed]
    for kind, code, expect in all_cases:
        row = []
        for label in results:
            hit = next((h for h in results[label][kind] if h[0] == code), None)
            mark = "✓" if hit and hit[3] else ("·" if hit and hit[2] else "✗")
            row.append(f"{mark} {(hit[2] if hit and hit[2] else '?')[:12]:<14}")
        print(f"{code:<22} " + "  ".join(row))
    print()
    for label in results:
        g = sum(1 for h in results[label]["golden"] if h[3])
        m = sum(1 for h in results[label]["mixed"] if h[3])
        line = f"{label:<28} 黄金 {g}/{len(GOLDEN)}  混合 {m}/{len(mixed)}"
        if sentences:
            s = sum(1 for h in results[label]["sent"] if h[3])
            line += f"  句子 {s}/{len(sentences)} ({s/len(sentences)*100:.0f}%)"
        print(line)
        if sentences:
            for h in results[label]["sent"]:
                if not h[3]:
                    print(f"    ✗ {h[0][:36]:<36} 期望 {h[1]} 得到 {h[2]}")


if __name__ == "__main__":
    main()
