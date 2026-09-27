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
#   bash scripts/corpus/recount.sh [源词表] [输出名] [并发数]
#   bash scripts/corpus/recount.sh '' recount_full 6      # 6 路并行扫描
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLEAN="$ROOT/data/corpus/clean/para"
FREQ="$ROOT/data/corpus/freq"
LOG="$ROOT/data/corpus/log"
# 分片临时目录默认放仓库内（/tmp 在根盘，只有 ~99G，48G 分片有撑爆风险）
export TMPDIR="${TMPDIR:-$ROOT/data/corpus/tmp}"
BIN="$ROOT/third-party/rime-corpus-processing/frequency/target/release/rime-frequency"
SRC="${1:-$ROOT/dicts/egret_wubi_py/egret_wubi_py_words_full.dict.yaml}"
NAME="${2:-recount_full}"
JOBS="${3:-${RECOUNT_JOBS:-6}}"

mkdir -p "$FREQ" "$LOG"
[ -x "$BIN" ] || { echo "缺少 rime-frequency（make setup-build）"; exit 1; }
ls "$CLEAN"/*.txt >/dev/null 2>&1 || { echo "没有 clean/para 语料，先跑阶段 clean"; exit 1; }

CORPUS="$FREQ/para_all.txt"
# 旧的合并缓存（48G）已不再需要：分片直接取 clean/para/*.txt，省一份磁盘副本
if [ -f "$CORPUS" ]; then
  echo "==> 清理旧的合并缓存 $(du -h "$CORPUS" | cut -f1)"
  rm -f "$CORPUS" "$FREQ/.para_fingerprint"
fi
echo "    语料 $(du -sh "$CLEAN" | cut -f1)  源词表 $(basename "$SRC")"

echo "==> Aho-Corasick 重扫（Rust，$JOBS 路并行）"
# 分片策略：直接用 clean/para 下的源文件作为分片（不再复制一份 48G 的合并语料），
# 超过 8GB 的文件再用 split 切开。所有临时文件建在 mktemp 目录里，
# 避免多个实例共享同一路径时互相删除（曾经把分片目录删掉导致 split 失败）。
PARTS="$(mktemp -d "${TMPDIR:-/tmp}/recount-XXXXXX")"
trap 'rm -rf "$PARTS"' EXIT
idx=0
for f in "$CLEAN"/*.txt; do
  sz=$(stat -c%s "$f")
  if [ "$sz" -gt $((8 * 1024 * 1024 * 1024)) ]; then
    n=$(( (sz + 8*1024*1024*1024 - 1) / (8*1024*1024*1024) ))
    split -n l/$n -d --additional-suffix=.txt "$f" "$PARTS/part-" \
      || { echo "split 失败: $f"; exit 1; }
  else
    cp --reflink=auto "$f" "$PARTS/part-$(printf %02d $idx).txt" || cp "$f" "$PARTS/part-$(printf %02d $idx).txt"
    idx=$((idx + 1))
  fi
done
total=$(ls "$PARTS"/part-*.txt 2>/dev/null | wc -l)
echo "    分片 $total 份（源: clean/para/*.txt）"

PIDS=()
for p in "$PARTS"/part-*.txt; do
  [ -s "$p" ] || continue
  o="${p%.txt}.out"
  nice -n 15 "$BIN" --corpus "$p" --source "$SRC" \
    --output "$o" --filtered-output "$o.flt" \
    --low-frequency-threshold 1 > "$o.log" 2>&1 &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "$pid"; done
grep -h "\[done\]" "$PARTS"/*.out.log 2>/dev/null | tail -2

# 合并各分片：按 word+code 累加频次（Rime dict 格式：word<TAB>code<TAB>count）
# 注意：不能用 `if awk ... | sort` 做判断——管道的退出码是 sort 的，
# awk 失败也会当成成功（曾经因此把分片删了）。先落盘再分别判。
awk -F'\t' '
  /^#/ {next}
  NF>=3 && $3 ~ /^[0-9]+$/ { k=$1"\t"$2; s[k]+=$3 }
  END { for (k in s) print k"\t"s[k] }
' "$PARTS"/*.out > "$FREQ/$NAME.unsorted"
rc=$?
if [ "$rc" -ne 0 ] || [ ! -s "$FREQ/$NAME.unsorted" ]; then
  echo "==> 合并失败(rc=$rc)，分片保留在 $PARTS（已取消自动清理）"
  trap - EXIT
  exit 1
fi
LC_ALL=C sort "$FREQ/$NAME.unsorted" > "$FREQ/$NAME.txt"
rm -f "$FREQ/$NAME.unsorted"

ls -la "$FREQ/$NAME.txt" 2>/dev/null | awk '{printf "产出: %s  %.1f MB\n", $9, $5/1048576}'
echo "下一步: python3 scripts/reweight_from_corpus.py --freq $FREQ/$NAME.txt"
