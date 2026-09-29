#!/usr/bin/env python3
"""用语料重扫的词频, 对数归一化后同步重写 拼音词库 与 五笔词库 的词组权重.
单字权重不动(知频权威).

路径以仓库根为基准(见 scripts/rime_paths.py), 不依赖当前工作目录。
重扫结果默认读 data/freq/pinyin_reweighted.txt, 可用环境变量 EGRET_REWEIGHTED
或命令行第一个参数覆盖。

用法:
  python3 scripts/reweight_words.py [重扫结果文件]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rime_paths  # noqa: E402  (同目录共享路径模块)

DICTS = rime_paths.DICTS
REWEIGHTED = (os.environ.get("EGRET_REWEIGHTED")
              or os.path.join(rime_paths.DATA, "freq", "pinyin_reweighted.txt"))
PINYIN_DICT = os.path.join(DICTS, "egret_wubi_py",
                           "egret_py_words_src.dict.yaml")
WUBI_DICT = os.path.join(DICTS, "egret_wubi_py",
                         "egret_wubi_words.dict.yaml")


def main(reweighted=REWEIGHTED):
    # 1) 读重扫结果: word -> new_raw_count
    new = {}
    started = False
    for line in open(reweighted, encoding="utf-8"):
        if line.startswith("..."):
            started = True
            continue
        if not started or line.startswith("#") or "\t" not in line:
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3 and parts[2].isdigit():
            new[parts[0]] = int(parts[2])
    w_max = max(new.values()) if new else 1

    def norm(cnt):
        return max(1, int(round(1000.0 * math.log(1 + cnt) / math.log(1 + w_max))))

    def reweight(path, is_word_line):
        out, n, changed = [], 0, 0
        started = False
        for line in open(path, encoding="utf-8"):
            if not started:
                out.append(line)
                if line.rstrip() == "...":
                    started = True
                continue
            if line.startswith("#") or "\t" not in line:
                out.append(line)
                continue
            parts = line.rstrip("\n").split("\t")
            word = parts[0]
            if len(parts) >= 3 and is_word_line(word) and word in new:
                parts[2] = str(norm(new[word]))
                changed += 1
            out.append("\t".join(parts) + "\n")
            n += 1
        open(path, "w", encoding="utf-8").write("".join(out))
        print(f"{os.path.basename(path)}: {changed} weights updated, {n} entries")

    # 拼音词库: 全部条目都是词
    reweight(PINYIN_DICT, lambda w: len(w) >= 2)
    # 五笔库: 只动多字词条(单字权重=知频膝点, 不动)
    reweight(WUBI_DICT, lambda w: len(w) >= 2)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else REWEIGHTED)
