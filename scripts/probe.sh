#!/usr/bin/env bash
# 混流探针：每个输入**连跑两次取第二次**（data/rime-test 冷部署首跑与热机结果不同，
# 见 docs/PROGRESS.md §4.18 测量纪律）。用法: bash scripts/probe.sh qktqn trwu ...
cd "$(dirname "$0")/.."
U=data/rime-test; B="$PWD/third-party/librime/build/bin"
printf '\n' | (cd $U && $B/rime_api_console >/dev/null 2>&1)   # 热机
for c in "$@"; do
  r=$(printf '%s\n\n' "$c" | (cd $U && $B/rime_api_console 2>/dev/null) | grep -m1 '^1\. \[' | sed 's/^1\. \[//;s/\].*//')
  printf '  %-24s -> %s\n' "$c" "$r"
done
