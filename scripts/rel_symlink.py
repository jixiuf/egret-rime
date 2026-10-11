#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""创建**相对**软链（替代 `ln -sfn <绝对路径>`）。

为什么：仓库内的软链（`data/rime-test/*`、`data/rime-shared/*`）此前都指向
`/export/ebook/egret-rime/...` 这样的**绝对路径** ⇒ 仓库一旦换目录/换机器，
所有链立刻全断（且 `ls -l` 里看不出这层耦合）。相对软链让整棵树可整体搬迁。

用法:
  scripts/rel_symlink.py <link_path> <target_path>
  # 例：scripts/rel_symlink.py data/rime-test/dicts dicts
  #     → data/rime-test/dicts -> ../../dicts

行为：已存在（含坏链）则先删再建；目标不存在则报错退出（除非 --allow-missing）。

目标已是**实体目录**时默认拒绝（防误删用户数据）；加 `--backup-existing` 会把该目录
改名为 `<link>.bak-<时间戳>` 再建链（可回滚）。
"""

import argparse
import os
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("link", help="要创建的软链路径")
    ap.add_argument("target", help="指向的目标（可绝对、可相对当前目录）")
    ap.add_argument("--allow-missing", action="store_true",
                    help="目标不存在时也建（例如先占位）")
    ap.add_argument("--backup-existing", action="store_true",
                    help="目标是实体目录时，改名为 <link>.bak-<时间戳> 再建链（默认拒绝）")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    link = os.path.abspath(args.link)
    target_abs = os.path.abspath(args.target)
    if not args.allow_missing and not os.path.exists(target_abs):
        sys.exit(f"目标不存在：{target_abs}")
    rel = os.path.relpath(target_abs, os.path.dirname(link))
    # 已存在（含指向别处的软链、坏链）先删
    if os.path.lexists(link):
        if os.path.islink(link) or os.path.isfile(link):
            os.unlink(link)
        elif args.backup_existing:
            stamp = time.strftime("%Y%m%d-%H%M%S")
            bak = f"{link}.bak-{stamp}"
            n = 1
            while os.path.lexists(bak):
                bak = f"{link}.bak-{stamp}.{n}"
                n += 1
            os.rename(link, bak)
            print(f"  ⚠ {link} 是实体目录，已备份为 "
                  f"{os.path.basename(bak)}（要回滚：rm 掉软链后 mv 回来）", file=sys.stderr)
        else:
            sys.exit(f"{link} 是目录，拒绝覆盖"
                     "（确认要替换就加 --backup-existing：自动改名备份后建链）")
    os.makedirs(os.path.dirname(link), exist_ok=True)
    os.symlink(rel, link)
    if not args.quiet:
        print(f"  {os.path.relpath(link)} -> {rel}")


if __name__ == "__main__":
    main()
