#!/usr/bin/env bash
# ============================================================================
# 阶段 gram：字符 2-6gram → kenlm → librime octagram .gram
# ============================================================================
# 输入: data/corpus/clean/short/*.txt（纯汉字短句，LM 用）
# 输出: data/gram/<language>.gram
#
# 链路：rime-char-gram-builder（Rust，字符 2-6gram 计数 + 分片 checkpoint）
#        → build_grammar（librime-octagram 工具，counts → .gram）
#
# 增量: 计数分片（--work-dir）可复用；语料变化时用 --restart 重算。
#       脚本用短句语料指纹判断是否需要重跑。
#
# 用法:
#   bash scripts/corpus/gram.sh                 # 全量训练
#   bash scripts/corpus/gram.sh --sample 200000 # 冒烟测试（只取前 N 行）
#   bash scripts/corpus/gram.sh --restart       # 丢弃 checkpoint 重算
#   bash scripts/corpus/gram.sh --min-count 300:200:150:80:40
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLEAN="$ROOT/data/corpus/clean/short"
WORK="$ROOT/data/corpus/ngram"
OUT="$ROOT/data/gram"
LOG="$ROOT/data/corpus/log"
BUILDER="$ROOT/third-party/rime-corpus-processing/rime-gram/target/release/rime-char-gram-builder"
BUILD_GRAMMAR="$ROOT/third-party/librime/build/bin/build_grammar"
LANGUAGE="${LANGUAGE:-zh-hans-egret}"
THREADS="${THREADS:-8}"
SAMPLE=""
RESTART=""
# 默认阈值经实测调优: 平阈值 30 得到 ~59MB/1000 万条 n-gram,
# 与 237MB 版本效果持平(句子还原 16/100)，见 docs/PROGRESS.md
MINCOUNTS="${MINCOUNTS:-30:30:30:30:30}"

while [ $# -gt 0 ]; do
  case "$1" in
    --sample) SAMPLE="$2"; shift 2 ;;
    --restart) RESTART="--restart"; shift ;;
    --min-count) MINCOUNTS="$2"; shift 2 ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

IFS=':' read -r M2 M3 M4 M5 M6 <<<"$MINCOUNTS"

mkdir -p "$WORK" "$OUT" "$LOG"
[ -x "$BUILDER" ] || { echo "缺少 gram 构建器: ${BUILDER}（先 make setup-build）"; exit 1; }
[ -x "$BUILD_GRAMMAR" ] || { echo "缺少 build_grammar: $BUILD_GRAMMAR"; exit 1; }

if [ -n "$SAMPLE" ]; then
  WORK="$WORK/sample-$SAMPLE"        # 独立 work-dir，避免样本 checkpoint 污染全量
  mkdir -p "$WORK"
  CORPUS="$WORK/short_sample.txt"
  if [ ! -s "$CORPUS" ]; then
    echo "==> 生成冒烟样本（前 $SAMPLE 行）"
    cat "$CLEAN"/*.txt 2>/dev/null | head -n "$SAMPLE" > "$CORPUS"
  fi
else
  CORPUS="$WORK/short_all.txt"
  # 语料指纹：分片大小 + 修改时间，用于判断是否需要重跑
  FP="$(stat -c '%s-%Y' "$CLEAN"/*.txt 2>/dev/null | tr '\n' ' ')"
  FP_FILE="$WORK/.corpus_fingerprint"
  if [ -f "$FP_FILE" ] && [ "$(cat "$FP_FILE")" = "$FP" ] \
     && [ -s "$OUT/$LANGUAGE.gram" ]; then
    echo "==> 语料未变化且 $LANGUAGE.gram 已存在，跳过"
    echo "    （要强制重训: bash scripts/corpus/gram.sh --restart）"
    exit 0
  fi
  echo "==> 合并短句语料"
  cat "$CLEAN"/*.txt > "$CORPUS"
  echo "$FP" > "$FP_FILE"
fi

echo "==> 字符 2-6gram 计数（threads=$THREADS, min-count=${MINCOUNTS}）"
nice -n 15 "$BUILDER" \
  --corpus "$CORPUS" \
  --work-dir "$WORK" \
  --output-dir "$OUT" \
  --language "$LANGUAGE" \
  --min-count-2 "$M2" --min-count-3 "$M3" --min-count-4 "$M4" \
  --min-count-5 "$M5" --min-count-6 "$M6" \
  --threads "$THREADS" \
  --build-grammar "$BUILD_GRAMMAR" \
  $RESTART 2>&1 | tail -20

if [ -s "$OUT/$LANGUAGE.gram" ]; then
  echo "==> 产出: $OUT/$LANGUAGE.gram ($(du -h "$OUT/$LANGUAGE.gram" | cut -f1))"
  echo "    启用: egret.common.yaml 的 grammar/language: ${LANGUAGE}（并确保 .gram 在用户目录 build/）"
else
  echo "==> 失败：未生成 $OUT/$LANGUAGE.gram"
  exit 1
fi
