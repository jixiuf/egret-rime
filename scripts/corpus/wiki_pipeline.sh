#!/usr/bin/env bash
# 维基 dump 管线：下载 → 官方 md5 校验 → wikiextractor 预处理 → 投放到 input/
#
# 为什么不做成 format handler：wiki dump 是单个 3GB+ 的 XML+bz2，且 wikitext
# 清洗远超"按类型抽取"的范畴（模板/引用/表格），交给专用工具质量更好。
# 预处理产物是 JSONL，直接由 extract.py 的 jsonl 处理器接管。
#
# 用法:
#   bash scripts/corpus/wiki_pipeline.sh            # 全流程(可反复重跑)
#   bash scripts/corpus/wiki_pipeline.sh download   # 只下载+校验
#   bash scripts/corpus/wiki_pipeline.sh extract    # 只跑 wikiextractor
#   bash scripts/corpus/wiki_pipeline.sh publish    # 只把产物投放到 input/
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAW="$ROOT/data/corpus/raw"
OUT="$ROOT/data/corpus/wikiextract"
PUB="$ROOT/data/input/open/zhwiki"
LOG="$ROOT/data/corpus/log"
PY="$ROOT/third-party/venv/bin/python"
mkdir -p "$RAW" "$OUT" "$PUB" "$LOG"

BASE="https://dumps.wikimedia.org/zhwiki/latest/zhwiki-latest-pages-articles.xml.bz2"
DUMP="$RAW/zhwiki-latest-pages-articles.xml.bz2"
USE_PROXY="${USE_PROXY:-auto}"
if [ "$USE_PROXY" = "off" ] || ! command -v proxychains4 >/dev/null 2>&1; then
  NET=()
else
  NET=(proxychains4 -q)
fi

do_download() {
  # 兼容早期直接下到 input/open 的文件：搬到 raw/
  if [ -f "$ROOT/data/input/open/zhwiki-latest-pages-articles.xml.bz2" ] \
     && [ ! -f "$DUMP" ]; then
    mv "$ROOT/data/input/open/zhwiki-latest-pages-articles.xml.bz2" "$DUMP"
    echo "已把 dump 移到 $RAW"
  fi
  if [ ! -f "$DUMP.md5ok" ]; then
    want_size="$( "${NET[@]}" curl -sI "$BASE" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')"
    have_size="$(stat -c%s "$DUMP" 2>/dev/null || echo 0)"
    if [ -n "$want_size" ] && [ "$have_size" = "$want_size" ]; then
      echo "==> dump 已完整 ($have_size 字节)，跳过下载"
    else
      echo "==> 下载 zhwiki dump (断点续传; 已有 $have_size / 期望 $want_size)"
      nice -n 15 "${NET[@]}" curl -L -C - --retry 3 --retry-delay 5 -sS \
        -o "$DUMP" "$BASE" || { echo "下载中断，可重跑本脚本续传"; exit 1; }
    fi
    echo "==> 校验官方 md5"
    want="$( "${NET[@]}" curl -s "$BASE.md5" | awk '{print $1}')"
    [ -n "$want" ] || { echo "取不到官方 md5，跳过校验"; }
    got="$(md5sum "$DUMP" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      echo "  ✗ md5 不符: 官方=$want 本地=$got"; exit 1
    fi
    echo "  ✓ md5 $got"
    touch "$DUMP.md5ok"
  fi
}

do_extract() {
  echo "==> wikiextractor 预处理 (single process, nice)"
  nice -n 15 "$PY" -m wikiextractor.WikiExtractor --json --no-templates \
    -o "$OUT" "$DUMP" 2>&1 | tail -3
}

do_publish() {
  echo "==> 投放 JSONL 到 $PUB"
  n=0
  while IFS= read -r f; do
    ln -sfn "$f" "$PUB/$(basename "$(dirname "$f")")_$(basename "$f").jsonl"
    n=$((n + 1))
  done < <(find "$OUT" -type f ! -name '*.part' | sort)
  echo "  已投放 $n 个文件（软链，extract.py 按 jsonl 处理）"
}

case "${1:-all}" in
  download) do_download ;;
  extract)  do_extract ;;
  publish)  do_publish ;;
  all)      do_download && do_extract && do_publish ;;
  *) echo "未知子命令: $1"; exit 1 ;;
esac
