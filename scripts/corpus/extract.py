#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段A：语料抽取——单一入口，按文件类型自动分派处理器。

扫描 input 目录（默认 data/input），对每个文件**按内容/扩展名判定格式**，
交给对应处理器（见 formats.py：epub / markdown / html / 纯文本）抽成
「一行一段」的纯文本。不区分语料来源——来源只体现在输出路径的目录层级里。

输出: data/corpus/extract/<格式>/<key 前两位>/<key>.txt
索引: data/corpus/meta/extract_index.jsonl（append-only，中断可续）

增量：key 优先取同步清单（可选）的内容寻址 md5（免读大文件），否则 sha256。
      索引命中且产物仍在 => 跳过；产物丢失则自动重抽。

限流：默认 nice=15 + ioprio best-effort/7，进程数默认 3。

用法:
  python3 scripts/corpus/extract.py                    # 增量全量
  python3 scripts/corpus/extract.py --dry-run          # 只看待处理清单
  python3 scripts/corpus/extract.py --jobs 4 --limit 200
  python3 scripts/corpus/extract.py --input /path/a --input /path/b
  python3 scripts/corpus/extract.py --force            # 忽略索引重抽
"""

import argparse
import collections
import concurrent.futures as cf
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C          # noqa: E402
import formats as F         # noqa: E402

SKIP_DIRS = {".git", "__pycache__", "extract", "clean", "freq", "meta", "log"}


def iter_files(roots):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirs, files in os.walk(root, followlinks=True):
            dirs[:] = [d for d in dirs
                       if d not in SKIP_DIRS and not d.startswith(".")]
            for fn in sorted(files):
                if fn.startswith(".") or fn.endswith(".part"):
                    continue
                yield os.path.join(dirpath, fn)


def probe(path):
    """读文件头 + 扩展名，返回 (handler, ext, head)。"""
    ext = os.path.splitext(path)[1].lower()
    try:
        with open(path, "rb") as f:
            head = f.read(512)
    except OSError:
        head = b""
    return F.detect_handler(path, head, ext), ext, head


def extract_one(task):
    path, key, rel, fmt = task
    try:
        handler = next(h for h in F.HANDLERS if h.name == fmt)
        out = C.out_path(fmt, key)
        tmp = f"{out}.{os.getpid()}.part"
        chars = cjk = lines = 0
        # 流式落盘：大语料包(dump/百科)不会整篇进内存
        with open(tmp, "w", encoding="utf-8") as f:
            for line in handler.stream(path):
                f.write(line)
                f.write("\n")
                lines += 1
                chars += len(line)
                cjk += sum(1 for ch in line if 0x4E00 <= ord(ch) <= 0x9FFF)
        os.replace(tmp, out)
        return dict(key=key, name=rel, fmt=fmt, status="ok",
                    out=os.path.relpath(out, C.CORPUS), chars=chars,
                    cjk=cjk, lines=lines)
    except Exception as e:                            # noqa: BLE001
        return dict(key=key, name=rel, fmt=fmt, status="error",
                    err=f"{type(e).__name__}: {e}", chars=0)


def build_tasks(roots, force=False, limit=0):
    hints = C.load_sync_keys()
    idx = {} if force else C.load_index()
    tasks, unknown, skipped, dup = [], [], 0, 0
    # （dangling 在扫描时统计，见下）
    seen = set()
    dangling = 0
    for path in iter_files(roots):
        # 断链软链（例如 wikiextract 产物被删后留下的 input 链接）会让 os.stat 抛错；
        # 这类条目直接跳过：input 目录常被人手工整理，管线不该因此整轮失败
        if not os.path.exists(path):
            dangling += 1
            continue
        rel = os.path.relpath(path, os.path.commonpath(roots)
                              if len(roots) > 1 else roots[0])
        handler, ext, _head = probe(path)
        if handler is None:
            unknown.append((rel, ext))
            continue
        key = C.file_key(path, hints)
        if key in seen:
            dup += 1
            continue
        rec = idx.get(key)
        if rec and rec.get("status") == "ok":
            outp = rec.get("out") and os.path.join(C.CORPUS, rec["out"])
            if outp and os.path.exists(outp):
                skipped += 1
                continue
        seen.add(key)
        tasks.append((path, key, rel, handler.name))
        if limit and len(tasks) >= limit:
            break
    if dangling:
        print(f"  跳过 {dangling} 个断链/缺失文件（input 目录里指向已删目标的软链）")
    return tasks, unknown, skipped, dup


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", action="append", default=None,
                    help="输入目录/文件(可重复; 默认 data/input)")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--nice", type=int, default=15)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--unknown-list", action="store_true",
                    help="列出未识别格式的文件")
    args = ap.parse_args()

    roots = args.input or [C.INPUT]
    for r in roots:
        if not os.path.exists(r):
            sys.exit(f"输入路径不存在: {r}")

    th = C.throttle(args.nice)
    tasks, unknown, skipped, dup = build_tasks(roots, args.force, args.limit)
    by_fmt = collections.Counter(t[3] for t in tasks)

    print(f"输入: {', '.join(roots)}")
    print(f"限流: {th}   并发: {args.jobs}")
    print(f"待抽取: {len(tasks)}  {dict(by_fmt)}")
    print(f"已抽过(跳过): {skipped}   同内容去重: {dup}   未识别格式: {len(unknown)}")
    if args.unknown_list and unknown:
        for rel, ext in unknown[:200]:
            print(f"  ? {rel}  (ext={ext or '无'})")
    if args.dry_run or not tasks:
        return

    t0 = time.time()
    ok = err = 0
    writer = C.IndexWriter()
    try:
        with cf.ProcessPoolExecutor(max_workers=args.jobs) as ex:
            for i, rec in enumerate(ex.map(extract_one, tasks, chunksize=8), 1):
                writer.add(source=rec.get("fmt"), **rec)
                if rec["status"] == "ok":
                    ok += 1
                else:
                    err += 1
                    print(f"  ! {rec.get('name')}: {rec.get('err')}")
                if i % 500 == 0 or i == len(tasks):
                    el = time.time() - t0
                    print(f"  [{i}/{len(tasks)}] ok={ok} err={err} "
                          f"{i/el:.0f} 个/s")
    finally:
        writer.close()
    print(f"完成: ok={ok} err={err} 用时 {(time.time()-t0)/60:.1f} min")


if __name__ == "__main__":
    main()
