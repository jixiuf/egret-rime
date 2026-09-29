#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""结构与命名一致性检查（不跑引擎，秒级）。

为什么需要：2026-09 这一轮改名的坑（旧名残留、name: 与文件名不一致、
import 指向不存在的文件、脚本语法被自己改坏）黄金用例**一条都拦不住**，
全靠事后人工审查才发现。这个脚本把这些硬性检查变成一键。

检查项：
  1. 三个 wrapper 的 import_tables 全部可解析（文件存在）
  2. 每个 dict 的 name: 与文件名一致（librime 要求）
  3. python / lua / bash 语法
  4. refresh.sh 是否提到所有生成器（未提到的不算错，但列出来，需在注释里说明）
退出码非 0 表示有硬性错误。
"""
import glob, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
err = warn = 0

# 1) wrapper import 可解析
for w in ("egret_wubi_py.dict.yaml", "egret_wubi.dict.yaml", "egret_py.dict.yaml"):
    if not os.path.exists(w):
        print(f"  ✗ 缺 wrapper {w}"); err += 1; continue
    for line in open(w, encoding="utf-8"):
        m = re.match(r"\s*-\s*(dicts/[\w/]+)\s*$", line)
        if m and not os.path.exists(m.group(1) + ".dict.yaml"):
            print(f"  ✗ {w} 引用了不存在的 {m.group(1)}"); err += 1

# 2) name: 与文件名一致
for p in sorted(glob.glob("dicts/*.dict.yaml")):
    b = os.path.basename(p)[:-len(".dict.yaml")]
    m = re.search(r"^name:\s*(\S+)", open(p, encoding="utf-8", errors="ignore").read(4000), re.M)
    if m and m.group(1) != b:
        print(f"  ✗ {b}: name: 是 {m.group(1)}"); err += 1

# 3) 语法
for p in glob.glob("scripts/*.py") + glob.glob("scripts/**/*.py", recursive=True):
    r = subprocess.run([sys.executable, "-c", f"import ast;ast.parse(open({p!r},encoding='utf-8').read())"],
                       capture_output=True)
    if r.returncode: print(f"  ✗ python 语法: {p}"); err += 1
if subprocess.run(["which", "luac"], capture_output=True).returncode == 0:
    for p in glob.glob("lua/*.lua"):
        if subprocess.run(["luac", "-p", p], capture_output=True).returncode:
            print(f"  ✗ lua 语法: {p}"); err += 1
for p in glob.glob("scripts/**/*.sh", recursive=True) + glob.glob("scripts/*.sh"):
    if subprocess.run(["bash", "-n", p], capture_output=True).returncode:
        print(f"  ✗ bash 语法: {p}"); err += 1

# 4) refresh.sh 里未提到的生成器（提示，不算错）
rs = open("scripts/refresh.sh", encoding="utf-8").read()
missing = [os.path.basename(p) for p in sorted(glob.glob("scripts/gen_*.py"))
           if os.path.basename(p) not in rs]
if missing:
    print(f"  · refresh.sh 未提到（应在注释里说明是否有意）：{', '.join(missing)}"); warn += 1

print(f"  一致性检查：{'✓ 全部通过' if err == 0 else f'✗ {err} 处错误'}"
      + (f"（{warn} 条提示）" if warn else ""))
sys.exit(1 if err else 0)
