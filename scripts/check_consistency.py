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

# 2.8) 五笔 86 码口径契约（§4.61）：三字词必须是**标准** 1+1+2。
#      本仓库旧数据用的是 2+1+1（如 爱可视 epsp），实测用户按标准码打三字词
#      top1 = 0/50、top8 = 2% —— 肌肉记忆直接失效。改回旧口径会让这条又静默退化。
_src = "dicts/egret_wubi_words_wb86_src.dict.yaml"
if os.path.exists(_src):
    import collections as _coll
    _rows = []
    _st = False
    for _ln in open(_src, encoding="utf-8"):
        if not _st:
            if _ln.rstrip() == "...":
                _st = True
            continue
        _f = _ln.rstrip("\n").split("\t")
        if len(_f) >= 3 and _f[2].isdigit():
            _rows.append((_f[0].strip(), _f[1]))
    _votes = _coll.defaultdict(_coll.Counter)
    for _w, _c in _rows:
        if len(_w) == 2 and len(_c) == 4 and " " not in _c:
            _votes[_w[0]][_c[:2]] += 1
            _votes[_w[1]][_c[2:]] += 1
    _c2 = {ch: v.most_common(1)[0][0] for ch, v in _votes.items()}
    _ok = _bad = 0
    for _w, _c in _rows:
        if len(_w) != 3:
            continue
        _cs = [_c2.get(ch) for ch in _w]
        if any(x is None for x in _cs):
            continue
        if _cs[0][:1] + _cs[1][:1] + _cs[2] == _c:
            _ok += 1
        else:
            _bad += 1
    # 容差只留给"极少数合法例外"（如同码冲突被人工改写）：>7 条即判失败。
    # （曾把阈值设成 1%，反向测试塞 30 条坏码仍能通过 —— 阈值必须紧到能抓住回归）
    _tol = max(3, int(0.002 * (_ok + _bad)))
    if _ok + _bad and _bad > _tol:
        print(f"  ✗ 三字词码式不是标准 1+1+2：{_bad}/{_ok + _bad} 条不符"
              f"（修法: python3 scripts/fix_wubi_86_3char_codes.py）")
        err += 1

# 2.9) 部署清单的**源文件必须入 git**（新 clone 后要能打出完整的包）。
#      踩过：清单只从 data/gram/（gitignore 的目录）取 lm_rerank.bin/compose_table.bin/
#      py_meta.txt ⇒ 本地有、新 clone 没有 ⇒ 打出的包缺运行时文件。
try:
    _mf = subprocess.run(["bash", "scripts/deploy_bundle.sh", "--list"],
                         capture_output=True, text=True).stdout
    for _ln in _mf.splitlines():
        if "|" not in _ln:
            continue
        _src = _ln.split("|")[0]
        if not os.path.exists(_src):
            print(f"  ✗ 部署清单引用的源文件不存在: {_src}")
            err += 1
            continue
        r = subprocess.run(["git", "ls-files", "--error-unmatch", _src],
                           capture_output=True)
        if r.returncode != 0:
            print(f"  ✗ 部署清单的源文件未入 git（新 clone 会缺）: {_src}")
            err += 1
except Exception as _e:
    print(f"  · 清单/git 检查跳过（{_e}）")
    warn += 1

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

# 4) 键名字优先（王码「25 键名字四连击」）：同码词不得压过键名字
# 用户实测拦住的回归（kkkk 出「串串」而非「口」），见 docs/PROGRESS.md §4.76。
# 词表是生成产物，任一生成器漏了 keyname_priority 就会在这里报出来。
try:
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    from keyname_priority import caps as _kn_caps
    _kcaps = _kn_caps(os.path.join(ROOT, "dicts"))
    _trad_tables = ["egret_wubi_words_wb86_base", "egret_wubi_words_wb86_longtail",
                    "egret_wubi_words_wb86_mined4", "egret_wubi_sentence",
                    "egret_wubi_force_end"]
    for _t in _trad_tables:
        _p = os.path.join(ROOT, "dicts", _t + ".dict.yaml")
        if not os.path.exists(_p):
            continue
        for _line in open(_p, encoding="utf-8"):
            _f = _line.rstrip("\n").split("\t")
            if len(_f) >= 3 and _f[2].isdigit() and _f[1] in _kcaps \
                    and int(_f[2]) > _kcaps[_f[1]]:
                print(f"  ✗ 键名字被压：{_f[0]} {_f[1]} 权重 {_f[2]} > 上限 {_kcaps[_f[1]]}"
                      f"（{_t}）—— 生成器漏了 keyname_priority")
                err += 1
except Exception as _e:
    print(f"  · 键名字优先检查跳过（{_e}）") ; warn += 1

# 4.5) default.custom.yaml 的 schema_list 必须是**替换**而非 `/+:` 追加
# （追加会把本方案排在共享数据的 luna_pinyin/cangjie5 之后 ⇒ 新环境启动成朙月拼音，
#   verify-bundle 探针 0/8 全繁体；见 §4.78）
_dc = os.path.join(ROOT, "default.custom.yaml")
if os.path.exists(_dc):
    _txt = open(_dc, encoding="utf-8").read()
    if re.search(r"^\s*schema_list/\+:", _txt, re.M):
        print("  ✗ default.custom.yaml 用了 `schema_list/+:`（追加）⇒ 新环境会启动成朙月拼音，"
              "必须是 `schema_list:`（替换）")
        err += 1

# 5) refresh.sh 里未提到的生成器（提示，不算错）
rs = open("scripts/refresh.sh", encoding="utf-8").read()
missing = [os.path.basename(p) for p in sorted(glob.glob("scripts/gen_*.py"))
           if os.path.basename(p) not in rs]
if missing:
    print(f"  · refresh.sh 未提到（应在注释里说明是否有意）：{', '.join(missing)}"); warn += 1

print(f"  一致性检查：{'✓ 全部通过' if err == 0 else f'✗ {err} 处错误'}"
      + (f"（{warn} 条提示）" if warn else ""))
sys.exit(1 if err else 0)
