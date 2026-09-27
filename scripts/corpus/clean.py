#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段B：清洗 + 短句切分（并行）。

输入: data/corpus/extract/<格式>/<key前2位>/<key>.txt（阶段A 产物，一行一段）
输出:
    data/corpus/clean/para/<格式>.txt    整段语料（保留标点）→ 分词/词频统计
    data/corpus/clean/short/<格式>.txt   纯汉字短句     → 字符 n-gram 训练
    data/corpus/clean/shards/…           分片中间产物（append-only，增量用）
    data/corpus/meta/clean_index.jsonl   增量索引（已处理的 extract key）

处理链（每行）：
    1. 去 URL/邮箱/控制字符，压空白
    2. 样板行剔除（Cover/版权信息/书名/ISBN/出版社授权声明…）
    3. 中文字符占比过滤（默认 <0.3 丢弃）
    4. 繁→简（OpenCC t2s；**短句默认转、整段默认不转**）
    5. 只保留汉字白名单 + 常用标点（para）；短句按标点断句并**去掉全部标点**
    6. 全局行级精确去重（在 merge 层做；并行 worker 内先各自去重）

默认口径——面向**通用**字典，不一刀切：
    --charset      默认 cjk-ext（CJK 基本区 + 扩展A，不丢人名/地名/生僻字）；
                   另有 cjk（仅基本区）、8105（最严）、none（不设白名单）
    --short-t2s    默认开：**只对 LM 短句**转简——简繁并存会把同一二元组的
                   统计量劈成两半（台湾/臺灣），转简后 n-gram 证据集中
    --para-t2s     默认关：**词库用的整段保留原字形**，要同时收录简/繁词条
    短句不限长（与 RIME-LMDG 一致：标点断句 + 只留汉字）

简繁策略：词典以简体为基准，繁体由 egret.common.yaml 的 opencc s2t.json +
switches/traditionalization 在运行时转换；词库阶段再用 OpenCC 双向补全。

性能（重要）：
    - OpenCC 必须用 **C++ 绑定**（pip 包名 `OpenCC`，1.4.2+）。纯 Python 实现
      `opencc-python-reimplemented` 慢 ~20 倍，且两者共用 `opencc` 命名空间，
      同时安装会互相破坏——本环境只保留 C++ 版。
    - 并行架构：worker 各自写分片（本地去重），最后 merge 层做全局去重。
      分片 append-only，增量运行只追加新分片。

用法:
  python3 scripts/corpus/clean.py                      # 增量（默认口径，4 并发）
  python3 scripts/corpus/clean.py --jobs 6 --nice 15
  python3 scripts/corpus/clean.py --rebuild            # 清空重来
  python3 scripts/corpus/clean.py --dry-run
  python3 scripts/corpus/clean.py --charset 8105 --no-short-t2s
  python3 scripts/corpus/clean.py --no-merge           # 只出分片，稍后合并
  python3 scripts/corpus/clean.py --merge-only         # 只做合并
"""

import argparse
import collections
import concurrent.futures as cf
import glob
import hashlib
import json
import os
import re
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C          # noqa: E402

CLEAN_INDEX = os.path.join(C.META, "clean_index.jsonl")
PARA_DIR = os.path.join(C.CLEAN, "para")
SHORT_DIR = os.path.join(C.CLEAN, "short")
SHARD_DIR = os.path.join(C.CLEAN, "shards")

URL = re.compile(r"https?://\S+|www\.\S+")
MAIL = re.compile(r"\S+@\S+\.\S+")
CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
SPACE = re.compile(r"[ \t\u00a0\u3000]+")
# 样板行：版权页/封面/出版信息等（短且命中即丢）
BOILER = re.compile(
    r"^(cover|版权信息|copyright|目录|书封|扉页|书名页|书名|isbn|字数[:：]|"
    r"出版时间|出版社|作者[:：]|译者[:：]|定价|版权所有|图书在版编目|"
    r"责任编辑|装帧|印刷|开本|印张|版次|印次|书号|声明|免责声明|"
    r"本书由.{0,30}(授权|制作|发行))", re.I)
# 汉字范围：默认 基本区 + 扩展A
CJK = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf]")
PUNCT_OK = "，。、；：？！…—·（）《》〈〉“”‘’「」『』【】～"
KEEP_PARA = re.compile(r"[^\u4e00-\u9fff\u3400-\u4dbf" + PUNCT_OK + r"]")
KEEP_SHORT = re.compile(r"[^\u4e00-\u9fff\u3400-\u4dbf]")
SENT_SPLIT = re.compile(r"[。！？；!?;…]+|\n")

# 去重用的 64 位掩码与分块行数
HASH_MASK = (1 << 64) - 1
CHUNK_LINES = 200_000


def load_charset(name):
    """白名单：cjk-ext(默认) / cjk / 8105 / none。返回 str(正则模式) 或 set。"""
    if name in ("cjk", "cjk-ext", "none"):
        return name
    if name == "8105":
        path = os.path.join(C.rime_paths.DICTS, "wb86_cn_dicts", "8105.dict.yaml")
        chars = set()
        if os.path.exists(path):
            started = False
            for line in open(path, encoding="utf-8"):
                if not started:
                    if line.rstrip() == "...":
                        started = True
                    continue
                p = line.rstrip("\n").split("\t")
                if p and p[0] and len(p[0]) == 1 and CJK.match(p[0]):
                    chars.add(p[0])
        return chars
    raise SystemExit(f"未知 charset: {name}")


def make_filters(charset):
    """返回 (para_filter, short_filter)。"""
    if isinstance(charset, str):
        if charset == "none":
            return (lambda s: s, lambda s: s)
        if charset == "cjk":
            return (lambda s: re.sub(r"[^\u4e00-\u9fff" + re.escape(PUNCT_OK)
                                     + r"]", "", s),
                    lambda s: re.sub(r"[^\u4e00-\u9fff]", "", s))
        return (lambda s: KEEP_PARA.sub("", s), lambda s: KEEP_SHORT.sub("", s))
    allow = charset | set(PUNCT_OK)
    para_re = re.compile("[^%s]" % re.escape("".join(sorted(allow))))
    short_re = re.compile("[^%s]" % re.escape("".join(sorted(charset))))
    return (lambda s: para_re.sub("", s), lambda s: short_re.sub("", s))


def load_t2s(enabled, tag=""):
    if not enabled:
        return None
    try:
        from opencc import OpenCC
        return OpenCC("t2s").convert
    except Exception as e:                            # noqa: BLE001
        print(f"  ! OpenCC 不可用({e})，{tag}跳过繁简转换")
        return None


def h64(s):
    """64 位内容哈希（blake2b）。crc32 只有 32 位，本量级会大量误判重复。

    仅用于索引/统计等需要可复现的场合；去重路径用内置 hash() 更快
    （见 Cleaner._filter 与 merge），代价是跨进程不可复现——去重不需要。
    """
    return int.from_bytes(hashlib.blake2b(s.encode("utf-8"),
                                          digest_size=8).digest(), "little")


class Cleaner:
    def __init__(self, charset, t2s_para=None, t2s_short=None,
                 dedup_capacity=250_000_000):
        self.para_f, self.short_f = make_filters(charset)
        self.t2s_para = t2s_para
        self.t2s_short = t2s_short
        # 用有界布隆过滤器而非 set：全量语料行数可达十亿级，set 会 OOM
        self.seen_para = C.BloomFilter(dedup_capacity)
        self.seen_short = C.BloomFilter(dedup_capacity)
        self.stats = collections.Counter()

    def file(self, path):
        """清洗一个文件 -> (para 行列表, short 句列表)。

        分块批处理：每 CHUNK_LINES 行做一次批量去重（布隆过滤器向量化）。
        逐条调用布隆只有 ~0.4M/s，批量后可到几千万/s；同时内存有界。
        """
        out_p, out_s = [], []
        bp, bs = [], []
        with open(path, encoding="utf-8") as f:
            for raw in f:
                self.line(raw.rstrip("\n"), bp, bs)
                if len(bp) + len(bs) >= CHUNK_LINES:
                    out_p.extend(self._filter(bp, self.seen_para))
                    out_s.extend(self._filter(bs, self.seen_short))
                    bp, bs = [], []
        out_p.extend(self._filter(bp, self.seen_para))
        out_s.extend(self._filter(bs, self.seen_short))
        return out_p, out_s

    def _filter(self, items, seen):
        """批量去重：返回其中的新条目。"""
        if not items:
            return items
        keep = seen.add_batch_if_new([hash(x) & HASH_MASK for x in items])
        n_keep = int(keep.sum())
        self.stats["dupe"] += len(items) - n_keep
        return [x for x, k in zip(items, keep) if k]

    def line(self, raw, paras, shorts):
        if not raw:
            return
        self.stats["in"] += 1
        line = SPACE.sub(" ", CTRL.sub("", MAIL.sub("", URL.sub("", raw)))).strip()
        if not line:
            return
        if len(line) < 40 and BOILER.match(line):
            self.stats["boiler"] += 1
            return
        cjk = len(CJK.findall(line))
        if not cjk or cjk < len(line) * 0.3:
            self.stats["lowcjk"] += 1
            return
        # para：保留原字形（繁体词形不能抹掉），供分词/词频
        p = self.para_f(self.t2s_para(line) if self.t2s_para else line)
        if p:
            paras.append(p)
        # short：转简后断句去标点，供字符 n-gram（统计集中）
        sline = self.t2s_short(line) if self.t2s_short else line
        for s in SENT_SPLIT.split(sline):
            s = self.short_f(s)
            if len(s) >= 2:
                shorts.append(s)

    def add(self, s, seen):
        # seen 为 BloomFilter：返回 True 表示“之前未见过”
        if not seen.add_if_new(h64(s)):
            self.stats["dupe"] += 1
            return False
        return True


# --- 并行 worker ------------------------------------------------------------
_W = {}


def _init_worker(charset, short_t2s, para_t2s, cap):
    _W["cleaner"] = Cleaner(load_charset(charset),
                            load_t2s(para_t2s, "整段"),
                            load_t2s(short_t2s, "短句"),
                            dedup_capacity=max(1_000_000, cap))


def _work(task):
    fmt, key, path = task
    cl = _W["cleaner"]
    try:
        paras, shorts = cl.file(path)
    except Exception as e:                            # noqa: BLE001
        return dict(key=key, fmt=fmt, status="error",
                    err=f"{type(e).__name__}: {e}")
    pid = os.getpid()
    for kind, rows in (("para", paras), ("short", shorts)):
        if not rows:
            continue
        d = os.path.join(SHARD_DIR, kind)
        with open(os.path.join(d, f"{fmt}.{pid}.txt"), "a", encoding="utf-8") as f:
            f.write("\n".join(rows) + "\n")
    return dict(key=key, fmt=fmt, status="ok", para=len(paras), short=len(shorts))


# --- 合并（全局去重）--------------------------------------------------------
def merge(dedup_capacity=1_000_000_000):
    print(f"==> 合并分片（全局去重，布隆容量 {dedup_capacity/1e9:.1f}e9）")
    t0 = time.time()
    for kind, outdir in (("para", PARA_DIR), ("short", SHORT_DIR)):
        sdir = os.path.join(SHARD_DIR, kind)
        if not os.path.isdir(sdir):
            continue
        fmts = sorted({os.path.basename(f).split(".")[0]
                       for f in os.listdir(sdir) if f.endswith(".txt")})
        for fmt in fmts:
            shards = sorted(glob.glob(os.path.join(sdir, f"{fmt}.*.txt")))
            out = os.path.join(outdir, f"{fmt}.txt")
            # 关键：把**已有的最终产物**也当作一个输入分片。
            # 否则增量运行时 merge 会用“仅新分片”覆盖旧产物，把历史数据丢掉。
            inputs = ([out] if os.path.exists(out) else []) + shards
            if len(inputs) <= (1 if os.path.exists(out) else 0):
                continue
            seen = C.BloomFilter(dedup_capacity)
            tmp = out + ".tmp"
            n_in = n_out = 0
            batch = []

            def flush(o):
                nonlocal n_out
                if not batch:
                    return
                keep = seen.add_batch_if_new([hash(x) & HASH_MASK
                                              for x in batch])
                for x, kp in zip(batch, keep):
                    if kp:
                        o.write(x)
                        o.write("\n")
                        n_out += 1
                batch.clear()

            with open(tmp, "w", encoding="utf-8") as o:
                for sh in inputs:
                    with open(sh, encoding="utf-8") as f:
                        for line in f:
                            line = line.rstrip("\n")
                            if not line:
                                continue
                            n_in += 1
                            batch.append(line)
                            if len(batch) >= CHUNK_LINES:
                                flush(o)
                flush(o)
            os.replace(tmp, out)
            for sh in shards:
                os.remove(sh)
            tag = "含旧产物" if inputs[0] == out else "仅分片"
            print(f"  {kind}/{fmt}: {n_in} -> {n_out} 行（去重 {n_in-n_out}, {tag}）"
                  f"  {os.path.getsize(out)/2**20:.1f} MB  布隆 {seen.mem_mb:.0f}MB")
    print(f"合并用时 {(time.time()-t0)/60:.1f} min")


# --- 索引与任务 -------------------------------------------------------------
def index_load():
    idx = {}
    if os.path.exists(CLEAN_INDEX):
        for line in open(CLEAN_INDEX, encoding="utf-8"):
            line = line.strip()
            if line:
                r = json.loads(line)
                idx[r["key"]] = r
    return idx


def extract_files():
    for fmt in sorted(os.listdir(C.EXTRACT)):
        d = os.path.join(C.EXTRACT, fmt)
        if not os.path.isdir(d):
            continue
        for sub in sorted(os.listdir(d)):
            sd = os.path.join(d, sub)
            if not os.path.isdir(sd):
                continue
            for fn in sorted(os.listdir(sd)):
                if fn.endswith(".txt"):
                    yield fmt, fn[:-4], os.path.join(sd, fn)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--charset", default="cjk-ext",
                    choices=["cjk-ext", "cjk", "8105", "none"])
    ap.add_argument("--short-t2s", dest="short_t2s", action="store_true",
                    default=True, help="LM 短句转简（默认开）")
    ap.add_argument("--no-short-t2s", dest="short_t2s", action="store_false")
    ap.add_argument("--para-t2s", dest="para_t2s", action="store_true",
                    default=False, help="词库整段转简（默认关，保留原字形）")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--nice", type=int, default=15)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-merge", action="store_true")
    ap.add_argument("--merge-only", action="store_true")
    ap.add_argument("--dedup-capacity", type=float, default=1.0e9,
                    help="布隆过滤器容量（条）；worker 按其 1/jobs 分配")
    args = ap.parse_args()

    th = C.throttle(args.nice)
    for d in (PARA_DIR, SHORT_DIR, os.path.join(SHARD_DIR, "para"),
              os.path.join(SHARD_DIR, "short")):
        if args.rebuild and os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d, exist_ok=True)
    if args.rebuild and os.path.exists(CLEAN_INDEX):
        os.remove(CLEAN_INDEX)

    if args.merge_only:
        merge(int(args.dedup_capacity))
        return

    idx = index_load()
    todo = [(fmt, key, path) for fmt, key, path in extract_files()
            if key not in idx]
    if args.limit:
        todo = todo[:args.limit]
    print(f"限流: {th}   并发: {args.jobs}")
    print(f"口径: charset={args.charset}  "
          f"para_t2s={'on' if args.para_t2s else 'off'}  "
          f"short_t2s={'on' if args.short_t2s else 'off'}")
    print(f"待清洗: {len(todo)}   已处理: {len(idx)}")
    if args.dry_run or not todo:
        if not args.no_merge:
            merge(int(args.dedup_capacity))
        return

    t0 = time.time()
    done = ok = err = 0
    writer = C.IndexWriter(CLEAN_INDEX)
    try:
        with cf.ProcessPoolExecutor(
                max_workers=args.jobs, initializer=_init_worker,
                initargs=(args.charset, args.short_t2s, args.para_t2s,
                          int(args.dedup_capacity / max(1, args.jobs)))) as ex:
            for rec in ex.map(_work, todo, chunksize=16):
                writer.add(**rec)
                done += 1
                if rec["status"] == "ok":
                    ok += 1
                else:
                    err += 1
                    print(f"  ! {rec['key']}: {rec.get('err')}")
                if done % 1000 == 0 or done == len(todo):
                    el = time.time() - t0
                    print(f"  [{done}/{len(todo)}] ok={ok} err={err} "
                          f"{done/el:.0f} 篇/s  用时 {el/60:.1f} min")
    finally:
        writer.close()
    print(f"清洗完成: ok={ok} err={err} 用时 {(time.time()-t0)/60:.1f} min")

    if not args.no_merge:
        merge(int(args.dedup_capacity))


if __name__ == "__main__":
    main()
