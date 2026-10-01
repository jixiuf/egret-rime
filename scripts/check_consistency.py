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

# 2.5) 脚本/配置里出现的 dicts/X.dict.yaml 必须存在
#      —— 2026-09 扁平化时 eval_gram.py 漏改（os.path.join 三参数形式），评测工具
#      直接跑不起来，而当时的 lint 只看 wrapper 的 import，漏了脚本内的路径。
#      正则要带词边界（否则 wangxiang_cn_dicts/8105 会被误判成 dicts/8105），
#      并跳过注释与三引号文档串（那里写的是输出名，未必已存在）。
def _code_lines(path):
    in_doc = False
    for i, line in enumerate(open(path, encoding="utf-8", errors="ignore"), 1):
        st = line.strip()
        if in_doc:
            if TRIPLE_D in st or TRIPLE_S in st:
                in_doc = False
            continue
        if st.startswith("#"):
            continue
        if st.count(TRIPLE_D) % 2 or st.count(TRIPLE_S) % 2:
            in_doc = True
            continue
        yield i, line

TRIPLE_D = chr(34) * 3   # 三引号（避免在补丁脚本里嵌套）
TRIPLE_S = chr(39) * 3
_scan = (glob.glob("scripts/**/*.py", recursive=True) + glob.glob("scripts/**/*.sh", recursive=True)
         + ["Makefile"] + ["egret_wubi_py.dict.yaml", "egret_wubi.dict.yaml", "egret_py.dict.yaml"])
for f in _scan:
    if not os.path.exists(f):
        continue
    it = _code_lines(f) if f.endswith(".py") else enumerate(open(f, encoding="utf-8", errors="ignore"), 1)
    for ln, line in it:
        for m in re.finditer(r"(?<![\w/])(dicts/[\w/]+)\.dict\.yaml", line):
            if not os.path.exists(m.group(1) + ".dict.yaml"):
                print(f"  ✗ {f}:{ln} 引用不存在的 {m.group(1)}"); err += 1

# 2.7) lua 运行时读的数据文件，必须在部署清单（deploy_bundle.sh --list）里。
#      这类漏文件已犯三次（lm_rerank.bin / compose_table.bin / py_meta.txt）——
#      本地 env-test 会带上它们，所以**只有真实部署**才暴露，必须自动拦。
try:
    _mf = subprocess.run(["bash", "scripts/deploy_bundle.sh", "--list"],
                         capture_output=True, text=True).stdout
    _dests = {ln.split("|")[1] for ln in _mf.splitlines() if "|" in ln}
except Exception:
    _dests = set()
for _lua in glob.glob("lua/*.lua"):
    _src = open(_lua, encoding="utf-8", errors="ignore").read()
    # 注意：代码里既有裸文件名（"py_meta.txt"）也有带路径的（"/dicts/py_meta.txt"），
    # 所以取 basename 再比对（先前只匹配裸名，导致检查形同虚设）
    for _m in re.finditer(r'"([^"]+\.(?:txt|meta|bin))"', _src):
        _fn = os.path.basename(_m.group(1))
        if _fn in _dests or ("dicts/" + _fn) in _dests:
            continue
        print(f"  ✗ {_lua} 运行时读 {_fn}，但部署清单里没有"); err += 1

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
