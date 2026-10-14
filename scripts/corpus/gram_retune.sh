#!/usr/bin/env bash
# ============================================================================
# gram 快速重建：从已聚合的 n-gram 计数直接出 .gram（不重算计数）
# ============================================================================
# 背景：rime-char-gram-builder 的 min-count 在**计数阶段**生效并被 checkpoint
#       固化，事后改阈值不会生效（会复用旧分片）。但聚合产物
#       <language>.2_6gram.tsv（本例 632MB / 3470 万条，第二列是原始 count）
#       仍在，直接按 count 阈值过滤再喂给 build_grammar，即可秒级得到不同
#       体积的 gram —— 用于快速权衡「体积 vs 效果」。
#
# 用法:
#   bash scripts/corpus/gram_retune.sh <count阈值> [新语言名] [源tsv]
#   bash scripts/corpus/gram_retune.sh 60  zh-hans-egret-t60
#   bash scripts/corpus/gram_retune.sh 150 zh-hans-egret-t150
#   bash scripts/corpus/gram_retune.sh --stats        # 看阈值->条数/体积估算
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAM="$ROOT/data/gram"
BUILD_GRAMMAR="$ROOT/third-party/librime/build/bin/build_grammar"
SRC="${3:-$GRAM/zh-hans-egret.2_6gram.tsv}"

[ -x "$BUILD_GRAMMAR" ] || { echo "缺少 build_grammar"; exit 1; }
[ -f "$SRC" ] || { echo "缺少聚合计数: ${SRC}（先跑 scripts/corpus/gram.sh）"; exit 1; }

if [ "${1:-}" = "--stats" ]; then
  echo "阈值 -> 保留条数 / 估算体积（按 ~6.8 B/条：实测 3470 万条 = 237MB）"
  for t in 10 30 60 100 150 300 600 1200; do
    n=$(awk -F'\t' -v t="$t" '$2>=t{c++} END{print c+0}' "$SRC")
    printf "  %-6s %12d 条   ~%6.0f MB\n" "$t" "$n" "$(echo "$n*6.8/1048576" | bc -l)"
  done
  exit 0
fi

T="${1:?用法: gram_retune.sh <count阈值> [新语言名]}"
LANG="${2:-zh-hans-egret-t$T}"

n=$(awk -F'\t' -v t="$T" '$2>=t{c++} END{print c+0}' "$SRC")
echo "阈值 $T -> $n 条（源 $(wc -l < "$SRC") 条）"
[ "$n" -gt 0 ] || { echo "阈值太高，没有条目"; exit 1; }

( cd "$GRAM" && awk -F'\t' -v t="$T" '$2>=t' "$SRC" | nice -n 15 "$BUILD_GRAMMAR" "$LANG" 2>&1 | tail -2 )
ls -la "$GRAM/$LANG.gram" 2>/dev/null | awk '{printf "产出: %s  %.1f MB\n", $9, $5/1048576}'
echo "评测: python3 scripts/eval_gram.py --cases 0 --sentences 100 --gram \"$LANG=$GRAM/$LANG.gram\""
