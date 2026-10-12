#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""键名字优先（王码「25 键名字四连击」）—— 各词表生成器共用的权重上限表。

背景（用户实测报告，见 docs/PROGRESS.md §4.76）：
  键名字（王 gggg / 口 kkkk / 禾 tttt / 女 vvvv …）在五笔里用「同键四连击」输入，
  王码里它们是固定首候选。本仓库按权重排序，**同码词**权重更高时会把键名字挤到第 2：
  例：kkkk → 串串(593) 压住 口(544)；tttt → 笔笔(447) 压住 禾(361)。
  同码词包括 2 字词的 2+2 派生码与 4 字词的 1+1+1+1 码（嘀嘀咕咕 = kkkk）。

做法：**只把同码词压到键名字之下**（词仍可达，退居第 2），
      **绝不动字表权重** —— 整链字权重是手工调好的整体，重做要全链重标定（§4.17）。

用法（生成器里统一调用）：
    from keyname_priority import caps, cap_weight
    caps_map = caps(DICTS)                 # {4 码: 键名字权重 - 1}
    wt, capped = cap_weight(code, wt, caps_map)
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# 25 个键名字的四连击码（G王 F土 D大 S木 A工 / H目 J日 K口 L田 M山 /
# T禾 R白 E月 W人 Q金 / Y言 U立 I水 O火 P之 / N已 B子 V女 C又 X纟）
KEYNAME_4 = {
    "gggg": "王", "ffff": "土", "dddd": "大", "ssss": "木", "aaaa": "工",
    "hhhh": "目", "jjjj": "日", "kkkk": "口", "llll": "田", "mmmm": "山",
    "tttt": "禾", "rrrr": "白", "eeee": "月", "wwww": "人", "qqqq": "金",
    "yyyy": "言", "uuuu": "立", "iiii": "水", "oooo": "火", "pppp": "之",
    "nnnn": "已", "bbbb": "子", "vvvv": "女", "cccc": "又", "xxxx": "纟",
}

CHARS_NAME = "egret_wubi_chars.dict.yaml"    # 传统字表（git 跟踪的源）


def _rows(path):
    started = False
    for line in open(path, encoding="utf-8"):
        if not started:
            if line.rstrip() == "...":
                started = True
            continue
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3 and p[2].isdigit():
            yield p[0], p[1], int(p[2])


def caps(dicts_dir):
    """{4 码: 键名字权重 - 1}：同码词被压到它之下；字表缺失时返回空表（不改权）。"""
    path = os.path.join(dicts_dir, CHARS_NAME)
    out = {}
    if not os.path.exists(path):
        print(f"  ! 键名字优先跳过：缺 {path}")
        return out
    for text, code, weight in _rows(path):
        # 权重 1 = gen_char_weights.py 的「语料中从未出现」哨兵（如 纟）：
        # 这种键名字不参与优先，否则会把同码词压到 0、让词从档位里消失
        if code in KEYNAME_4 and text == KEYNAME_4[code] and weight > 1:
            out[code] = weight - 1
    return out


def cap_weight(code, weight, caps_map):
    """返回 (权重, 是否被压)。code 非 4 码或不在表里则原样返回。"""
    if not caps_map or len(code) != 4:
        return weight, False
    limit = caps_map.get(code)
    if limit is not None and weight > limit:
        return limit, True
    return weight, False
