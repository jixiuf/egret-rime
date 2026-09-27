#!/usr/bin/env bash
# ============================================================================
# 阶段 freq：用语料重扫词典词频（Aho-Corasick 单次扫描，Rust）
# ============================================================================
# 为什么不用 jieba 分词统计：Python 级分词在这台机器上约 2 万行/分钟，
# 3.6GB 语料要跑 1 小时以上；而 rime-frequency 用 Aho-Corasick 扫一遍
# 78 万词条只要 **2 分钟**，且口径与词库直接对齐（只统计词库里已有的词）。
#
# 输入: data/corpus/clean/para/*.txt    （整段语料；简繁都在，与词条一致）
#       dicts/ 下的词表（默认取 full 档，一次扫全，供各档复用）
# 输出: data/corpus/freq/recount_full.txt            重扫后词频（Rime dict 格式）
#       data/corpus/freq/recount_full.filtered.txt   被过滤条目
#
# 用法:
#   bash scripts/corpus/recount.sh [源词表] [输出名]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLEAN="$ROOT/data/corpus/clean/para"
FREQ="$ROOT/data/corpus/freq"
LOG="$ROOT/data/corpus/log"
BIN="$ROOT/third-party/rime-corpus-processing/frequency/target/release/rime-frequency"
SRC="${1:-$ROOT/dicts/egret_wubi_py/egret_wubi_py_words_full.dict.yaml}"
NAME="${2:-recount_full}"

mkdir -p "$FREQ" "$LOG"
[ -x "$BIN" ] || { echo "缺少 rime-frequency（make setup-build）"; exit 1; }
ls "$CLEAN"/*.txt >/dev/null 2>&1 || { echo "没有 clean/para 语料，先跑阶段 clean"; exit 1; }

CORPUS="$FREQ/para_all.txt"
# 语料变了才重新合并（指纹 = 各分片 size+mtime）
FP="$(stat -c '%s-%Y' "$CLEAN"/*.txt 2>/dev/null | tr '\n' ' ')"
FP_FILE="$FREQ/.para_fingerprint"
if [ -f "$FP_FILE" ] && [ "$(cat "$FP_FILE")" = "$FP" ] && [ -s "$CORPUS" ]; then
  echo "==> para 语料未变化，复用 $CORPUS"
else
  echo "==> 合并 para 语料"
  nice -n 15 cat "$CLEAN"/*.txt > "$CORPUS"
  echo "$FP" > "$FP_FILE"
fi
echo "    语料 $(du -h "$CORPUS" | cut -f1)  源词表 $(basename "$SRC")"

echo "==> Aho-Corasick 重扫（Rust）"
nice -n 15 "$BIN" --corpus "$CORPUS" --source "$SRC" \
  --output "$FREQ/$NAME.txt" \
  --filtered-output "$FREQ/$NAME.filtered.txt" \
  --low-frequency-threshold 1 2>&1 | tail -4

ls -la "$FREQ/$NAME.txt" 2>/dev/null | awk '{printf "产出: %s  %.1f MB\n", $9, $5/1048576}'
echo "下一步: python3 scripts/reweight_from_corpus.py --freq $FREQ/$NAME.txt"
