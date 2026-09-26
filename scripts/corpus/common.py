#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语料抽取公共设施：路径、增量索引、限流（nice/ionice）。

路径一律以仓库根为基准（见 scripts/rime_paths.py），不依赖 cwd。

目录约定（均在 data/ 下，不入 git）：
    data/input/            语料投放目录（epub/md/html/纯文本/jsonl 混放，按类型自动识别）
    data/input/open/       开源语料下载目标（由 scripts/corpus/fetch_open.sh 维护）
    data/corpus/raw/       不适合直接抽取的原始包（如 wiki dump，先经专用工具预处理）
    data/corpus/extract/   抽取产物（extract/<格式>/<key 前两位>/<key>.txt）
    data/corpus/meta/      增量索引（extract_index.jsonl，append-only）
    data/corpus/log/       运行日志
    data/corpus/clean/     阶段B 清洗产物
    data/corpus/freq/      词频中间产物

增量策略：
- key 优先取 同步清单里的 oss_key（内容是内容寻址的 md5），
  这样不必为了算 hash 去读全部 epub；清单里没有的来源（手工放入/其他语料）
  才回退到 sha256(文件内容)。
- 索引 append-only，命中 key 即跳过；`--force` 可重抽。
- 每完成一条就落一行索引，中断后可续跑。
"""

import ctypes
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "scripts"))

import rime_paths  # noqa: E402

CORPUS = os.path.join(rime_paths.DATA, "corpus")
RAW = os.path.join(CORPUS, "raw")
EXTRACT = os.path.join(CORPUS, "extract")
CLEAN = os.path.join(CORPUS, "clean")
FREQ = os.path.join(CORPUS, "freq")
META = os.path.join(CORPUS, "meta")
LOG = os.path.join(CORPUS, "log")
INDEX = os.path.join(META, "extract_index.jsonl")

INPUT = rime_paths._env_dir("EGRET_INPUT_DIR", os.path.join(rime_paths.DATA, "input"))
# 同步清单（内容寻址 key 的来源）；不在仓库内，允许缺失
SYNC_MANIFEST = os.path.join(os.path.dirname(rime_paths.REPO), "_epms_state",
                             "manifest.jsonl")

for d in (INPUT, RAW, EXTRACT, CLEAN, FREQ, META, LOG):
    os.makedirs(d, exist_ok=True)


# --- 限流 -------------------------------------------------------------------
def throttle(nice_level=15, ioprio_class=2, ioprio_data=7):
    """降低 CPU 与 IO 优先级，避免影响同机其它服务。

    nice: 只降自己（子进程继承）。ioprio: class 2=BEST_EFFORT, data 0-7
    (7 最低)。任一失败都不影响运行。
    """
    done = []
    try:
        os.nice(nice_level - os.nice(0))
        done.append(f"nice={nice_level}")
    except Exception:
        pass
    try:
        # ioprio_set(IOPRIO_WHO_PROCESS=1, who=0, ioprio=(class<<13)|data)
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        if libc.ioprio_set(1, 0, (ioprio_class << 13) | ioprio_data) == 0:
            done.append(f"ioprio=be/{ioprio_data}")
    except Exception:
        pass
    return ", ".join(done) if done else "(限流不可用)"


# --- 增量索引 ---------------------------------------------------------------
def load_index(path=INDEX):
    """读回已完成条目：key -> record（后写覆盖先写）。"""
    idx = {}
    if not os.path.exists(path):
        return idx
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("key"):
                idx[rec["key"]] = rec
    return idx


class IndexWriter:
    """append-only 索引写入器，每条落盘一次，保证中断可续。"""

    def __init__(self, path=INDEX):
        self.path = path
        self.fh = open(path, "a", encoding="utf-8")

    def add(self, **rec):
        rec.setdefault("ts", time.strftime("%Y-%m-%d %H:%M:%S"))
        self.fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self.fh.flush()

    def close(self):
        self.fh.close()


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def load_epms_keys(manifest=SYNC_MANIFEST):
    """同步清单: 文件名 -> 内容寻址 key（oss_key 的 md5 段）。"""
    keys = {}
    if not os.path.exists(manifest):
        return keys
    with open(manifest, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            name = d.get("file")
            oss = d.get("oss_key") or ""
            if name and oss:
                keys[name] = os.path.basename(oss).split(".")[0]
    return keys


def out_path(source, key, ext=".txt"):
    """分片输出路径：extract/<source>/<key 前两位>/<key><ext>。"""
    d = os.path.join(EXTRACT, source, key[:2])
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, key + ext)


def cjk_count(text):
    n = 0
    for ch in text:
        o = ord(ch)
        if 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF:
            n += 1
    return n


def human(n):
    for unit in ("", "K", "M", "G"):
        if n < 1000 or unit == "G":
            return f"{n:.1f}{unit}" if unit else str(n)
        n /= 1000.0
