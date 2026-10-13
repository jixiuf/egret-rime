#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""交付包验收（目标机模拟）：解包 → 安装到空目录 → 部署 → 跑能力探针。

为什么需要：本仓库已犯过三次"运行时文件漏进部署清单"（lm_rerank.bin / compose_table.bin /
py_meta.txt），且**本地 env-test 永远测不出来**（本地走软链，目标机是实体拷贝）。
这个脚本把"目标机会发生的事"压缩成本机一次冒烟：与仓库无关，只测**包**。

口径：用 `dist/` 里最新的 tar.gz；安装到临时目录；400MB 语言模型与 rime 共享数据
（default/symbols/essay）用软链补上（真实用户需自行放置，见 install.sh 提示）；
固定 10 条探针（基础简码/全码/混流/长句 + 五笔长尾 + 四字词 + 拼音四字词）。

用法:
  python3 scripts/verify_bundle.py                 # 默认用最新包
  python3 scripts/verify_bundle.py --tar dist/xxx.tar.gz
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402

BIN = rime_paths.librime_tool("rime_deployer")
CONSOLE = rime_paths.librime_tool("rime_api_console")
GRAM = os.path.join(rime_paths.GRAM_DIR, "wanxiang-lts-zh-hans.gram")

PROBES = [  # (输入, 期望首候选, 说明)
    ("e", "有", "一级简码"),
    ("tffu", "等", "字全码"),
    ("khlg", "中国", "词组 2+2"),
    ("qktnqnr", "我吃饭", "混流短码序列"),
    ("jintiandetianqizenmeyang", "今天的天气怎么样", "全拼长句(需 LM)"),
    ("ytsm", "计算机", "四字词·五笔(日常词)"),
    ("mffp", "周勃", "二字长尾·五笔"),
    ("shehuizhuyi", "社会主义", "四字词·拼音"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tar", default="")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    tar = args.tar or (sorted(glob.glob(os.path.join(REPO, "dist", "egret-rime-runtime-*.tar.gz")))[-1]
                       if glob.glob(os.path.join(REPO, "dist", "egret-rime-runtime-*.tar.gz")) else "")
    if not tar or not os.path.exists(tar):
        sys.exit("找不到部署包，先跑 bash scripts/deploy_bundle.sh")
    print(f"交付包验收：{os.path.basename(tar)}")

    work = tempfile.mkdtemp(prefix="egret-bundle-")
    src, tgt = os.path.join(work, "src"), os.path.join(work, "tgt")
    os.makedirs(src); os.makedirs(tgt)
    subprocess.run(["tar", "xzf", tar, "-C", src], check=True)
    pkg = glob.glob(os.path.join(src, "*"))[0]
    r = subprocess.run(["bash", os.path.join(pkg, "install.sh"), tgt],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"install.sh 失败：{r.stdout[-500:]}")
    miss = [l for l in r.stdout.splitlines() if "缺少必需文件" in l]
    if miss:
        sys.exit("包内缺必需文件：\n" + "\n".join(miss))

    # 交付包里的 default.custom.yaml 是**用户配置**（`schema_list/+:` 追加语义，不动用户
    # 已有方案列表）；console 只看列表顺序 ⇒ 测试目录里改成替换式（只影响本目录，§4.78）
    subprocess.run([sys.executable, os.path.join(REPO, "scripts", "schema_env.py"),
                    "list-replace", tgt], capture_output=True)

    # 目标机自己准备的东西：400MB 语言模型 + rime 共享数据 + 选中本方案
    if os.path.exists(GRAM):
        os.symlink(GRAM, os.path.join(tgt, os.path.basename(GRAM)))
    for f in ("default.yaml", "symbols.yaml", "essay.txt"):
        p = os.path.join(os.path.dirname(BIN), f)
        if os.path.exists(p):
            os.symlink(p, os.path.join(tgt, f))
    with open(os.path.join(tgt, "user.yaml"), "w", encoding="utf-8") as f:
        f.write("schema_list:\n  - schema: egret_wubi_py\n"
                "previously_selected_schema: egret_wubi_py\n")
    subprocess.run([BIN, "--build", tgt, os.path.dirname(BIN), os.path.join(tgt, "build")],
                   capture_output=True, timeout=900)

    ok = 0
    for code, want, note in PROBES:
        out = subprocess.run([CONSOLE], input=code + "\n\n", capture_output=True,
                             text=True, cwd=tgt, timeout=120).stdout
        got = ""
        for line in out.splitlines():
            m = re.match(r"1\. \[([^\]]*)\]", line.strip())
            if m:
                got = m.group(1)
                break
        hit = got == want
        ok += hit
        print(f"  {code:<24} 期望 {want:<10} 实际 {got or '(空)':<10} "
              f"{'✓' if hit else '✗'}  {note}")
    print(f"\n{ok}/{len(PROBES)} 通过" + ("  → 交付包含格 ✓" if ok == len(PROBES) else "  → 有失败 ✗"))
    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"（保留现场：{work}）")
    sys.exit(0 if ok == len(PROBES) else 1)


if __name__ == "__main__":
    main()
