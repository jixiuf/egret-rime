#!/usr/bin/env bash
# 开源语料下载器：按 scripts/corpus/open_sources.tsv 拉取到 data/input/open/<name>/
#
# 特性:
#   - 断点续传(curl -C -)，可反复重跑；已完整下载的文件跳过
#   - HuggingFace 在部分网络下需走代理: 有 proxychains4 时默认经它（USE_PROXY=off 关闭）
#   - 低优先级(nice) + 单并发，避免抢占带宽/IO
#
# 用法:
#   bash scripts/corpus/fetch_open.sh                 # 拉全部（串行，断点续传）
#   bash scripts/corpus/fetch_open.sh thucnews        # 只拉指定 name
#   bash scripts/corpus/fetch_open.sh --max-gb 20     # 本次最多下载 20GB（可持续分批）
#   bash scripts/corpus/fetch_open.sh --list          # 列出清单与状态
#   USE_PROXY=off bash scripts/corpus/fetch_open.sh   # 不走代理
#
# 注: 代理带宽是瓶颈（实测串行/并行均 ~5.7MB/s），故不做并行；
#     大语料建议用 --max-gb 分批拉，避免一次跑太久。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIST="$ROOT/scripts/corpus/open_sources.tsv"
OUT="$ROOT/data/input/open"
LOG="$ROOT/data/corpus/log"
mkdir -p "$OUT" "$LOG"

USE_PROXY="${USE_PROXY:-auto}"
if [ "$USE_PROXY" = "off" ] || ! command -v proxychains4 >/dev/null 2>&1; then
  NET=()
else
  NET=(proxychains4 -q)
fi

# HF 文件树展开: dataset + glob -> 每行一个相对路径
hf_files() {
  local ds="$1" glob="$2"
  "${NET[@]}" curl -s "https://huggingface.co/api/datasets/$ds/tree/main?recursive=true" \
    | python3 -c "
import sys, json, fnmatch
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    sys.exit(0)
pats = [p.strip() for p in sys.argv[1].split(',') if p.strip()]
for f in d:
    if f.get('type') != 'file':
        continue
    p = f['path']
    if p.startswith('.'):
        continue
    if any(fnmatch.fnmatch(p, pat) for pat in pats):
        print(p, f.get('size', 0))
" "$glob"
}

url_for() {   # dataset, path -> 下载 URL
  python3 -c "
import sys, urllib.parse
print('https://huggingface.co/datasets/%s/resolve/main/%s' % (sys.argv[1], urllib.parse.quote(sys.argv[2])))" "$1" "$2"
}

list_only=0
max_gb=0
want=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) list_only=1; shift ;;
    --max-gb) max_gb="$2"; shift 2 ;;
    *) want+=("$1"); shift ;;
  esac
done
budget=$((max_gb * 1024 * 1024 * 1024))
downloaded=0

printf '%-14s %-10s %-8s %s\n' NAME FILES SIZE NOTE
while IFS=$'\t' read -r name ds glob size lic note; do
  case "$name" in \#*|""|name) continue ;; esac
  if [ ${#want[@]} -gt 0 ]; then
    hit=0; for w in "${want[@]}"; do [ "$w" = "$name" ] && hit=1; done
    [ $hit -eq 1 ] || continue
  fi
  # 不用 mapfile（bash 4 才有；macOS 自带 bash 3.2 会直接报错，见 §4.84）
  files=()
  while IFS= read -r _line; do files[${#files[@]}]="$_line"; done < <(hf_files "$ds" "$glob")
  total=0; got=0
  for row in "${files[@]}"; do
    ok=1
    sz=$(echo "$row" | awk '{print $2}')
    p=$(echo "$row" | awk '{print $1}')
    total=$((total + sz))
    if [ -s "$OUT/$name/$p" ] && [ "$(stat -c%s "$OUT/$name/$p" 2>/dev/null || echo 0)" = "$sz" ]; then
      got=$((got + 1))
    fi
  done
  printf '%-14s %-10s %-8s %s\n' "$name" "$got/${#files[@]}" "$size" "$note"
  [ $list_only -eq 1 ] && continue

  mkdir -p "$OUT/$name"
  for row in "${files[@]}"; do
    p=$(echo "$row" | awk '{print $1}'); sz=$(echo "$row" | awk '{print $2}')
    dest="$OUT/$name/$p"
    mkdir -p "$(dirname "$dest")"
    if [ -s "$dest" ] && [ "$(stat -c%s "$dest")" = "$sz" ]; then continue; fi
    if [ "$max_gb" -gt 0 ] && [ "$downloaded" -ge "$budget" ]; then
      echo "    (已达 --max-gb $max_gb 配额，本次停在这里；重跑继续)"
      break 2
    fi
    echo "  ↓ $name/$p"
    # 先写 .part 再改名: 抽取器只认完整文件, 避免半成品内容进入增量索引
    # (extract.py 会跳过 *.part)
    nice -n 15 "${NET[@]}" curl -L -C - --retry 3 --retry-delay 5 -sS \
      -o "$dest.part" "$(url_for "$ds" "$p")" && \
      [ "$(stat -c%s "$dest.part")" = "$sz" ] && mv -f "$dest.part" "$dest" \
      || { echo "    ! 未完成/大小不符: $p"; continue; }
    downloaded=$((downloaded + sz))
    # zip 包（如医疗对话数据集）自动解压，避免给抽取器加二进制格式
    case "$p" in
      *.zip)
        if command -v unzip >/dev/null 2>&1; then
          echo "    unzip -> $(dirname "$dest")/$(basename "$dest" .zip)/"
          unzip -q -o "$dest" -d "$(dirname "$dest")/$(basename "$dest" .zip)" \
            && rm -f "$dest" || echo "    ! 解压失败（保留 zip）"
        else
          echo "    ! 未安装 unzip，保留 zip（抽取器不会读它）"
        fi ;;
    esac
  done
done < "$LIST"
echo "完成（产物: $OUT）"
