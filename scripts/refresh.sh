#!/usr/bin/env bash
# ============================================================================
# egret-rime 一键刷新：用 data/input 下**最新**的语料刷新全部产物
# ============================================================================
# 设计目标（用户要求）：
#   - 直接执行即可：脚本自己判断哪些数据是新的，只做增量，可反复重跑
#   - 语料持续下载中也能用：任何阶段中断，重跑即续
#   - 全链路覆盖：语料 → 抽取 → 清洗 → 词频 → 词典 → gram → 回归
#
# 用法:
#   bash scripts/refresh.sh                 # 全链路（增量）
#   bash scripts/refresh.sh --from clean    # 从某阶段开始
#   bash scripts/refresh.sh --only dict     # 只跑某阶段
#   bash scripts/refresh.sh --list          # 列出各阶段与当前状态
#   bash scripts/refresh.sh --full          # 全量重建（清中间产物，耗时最长）
#   bash scripts/refresh.sh --jobs 4 --nice 15
#   bash scripts/refresh.sh --loop 30       # 常驻：每 30 分钟增量刷新一次（语料持续下载）
#
# 并发保护: 用 flock 防止两个 refresh 同时跑（会互相踩分片）
#
# 阶段:
#   fetch    下载/更新开源语料（fetch_open + wiki dump，断点续传）
#   extract  抽取：input/ → extract/（按文件类型自动分派）
#   clean    清洗：extract/ → clean/{para,short}/
#   freq     词频：clean/para → freq/（分词统计，供词典）
#   dict     词典：分档词表 core/base/full + 方案词库 gen
#   gram     语言模型：clean/short → n-gram → kenlm → .gram
#   verify   验证：黄金用例回归 + 语料账本
#
# 环境变量:
#   TIER=core|base|full   词典档位（默认 base）
#   USE_PROXY=off         禁用 proxychains
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/third-party/venv/bin/python"
[ -x "$PY" ] || PY=python3
LOG="$ROOT/data/corpus/log"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$LOG/refresh-$STAMP.log"
mkdir -p "$LOG"

JOBS="${JOBS:-3}"
NICE="${NICE:-15}"
TIER="${TIER:-base}"
FULL=0
FROM=""
ONLY=""
LIST=0
LOOP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --nice) NICE="$2"; shift 2 ;;
    --tier) TIER="$2"; shift 2 ;;
    --loop) LOOP="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --list) LIST=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 防重入：同时在跑两个 refresh 会互相踩分片
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOG/.refresh.lock"
  flock -n 9 || { echo "另一个 refresh 正在运行，退出"; exit 0; }
fi

STAGES=(fetch extract clean freq dict gram verify)

log()  { printf '\n\033[1;36m═══ [%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; printf '[%s] %s\n' "$(date +%F\ %T)" "$*" >> "$RUNLOG"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; printf '  OK %s\n' "$*" >> "$RUNLOG"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; printf '  WARN %s\n' "$*" >> "$RUNLOG"; }
die()  { printf '    \033[31m✗\033[0m %s\n' "$*" >&2; printf '  FAIL %s\n' "$*" >> "$RUNLOG"; exit 1; }

# 阶段状态快照（--list 用）
status_line() {
  case "$1" in
    fetch)
      local n; n=$(find "$ROOT/data/input/open" -type f ! -name '*.part' 2>/dev/null | wc -l)
      echo "开源语料文件 $n 个" ;;
    extract)
      local n; n=$(wc -l < "$ROOT/data/corpus/meta/extract_index.jsonl" 2>/dev/null || echo 0)
      echo "已抽取 $n 篇" ;;
    clean)
      local n; n=$(wc -l < "$ROOT/data/corpus/meta/clean_index.jsonl" 2>/dev/null || echo 0)
      echo "已清洗 $n 篇" ;;
    freq)
      local n=0
      [ -d "$ROOT/data/corpus/freq" ] && n=$(find "$ROOT/data/corpus/freq" -name '*.tsv' 2>/dev/null | wc -l)
      echo "词频表 $n 份" ;;
    dict)
      local t; t=$(grep -ohE 'egret_wubi_py_(words|wubi_words|pinyin_words)_(core|base|full)' \
        "$ROOT/egret_wubi_py.dict.yaml" "$ROOT/egret_wubi_py_wubi.dict.yaml" 2>/dev/null | head -1)
      echo "当前档位 ${t:-未分档}" ;;
    gram)
      local f; f=$(ls "$ROOT/data/gram"/*.gram 2>/dev/null | wc -l)
      echo "gram 文件 $f 个" ;;
    verify)
      echo "黄金用例 20 条" ;;
  esac
}

if [ "$LIST" = 1 ]; then
  printf '%-10s %s\n' 阶段 状态
  for s in "${STAGES[@]}"; do printf '%-10s %s\n' "$s" "$(status_line "$s")"; done
  echo
  echo "日志: $RUNLOG"
  exit 0
fi

# 阶段顺序过滤
run_stages() {
run_from=1
[ -n "$FROM" ] && run_from=0
for i in "${!STAGES[@]}"; do
  s="${STAGES[$i]}"
  if [ -n "$FROM" ] && [ "$s" = "$FROM" ]; then run_from=1; fi
  if [ -n "$ONLY" ] && [ "$s" != "$ONLY" ]; then continue; fi
  [ "$run_from" = 0 ] && continue
  case "$s" in
    fetch)
      log "阶段 fetch：更新开源语料"
      bash "$ROOT/scripts/corpus/fetch_open.sh" >>"$RUNLOG" 2>&1 \
        && ok "fetch_open 完成" || warn "fetch_open 有失败项（可重跑续传）"
      if [ -s "$ROOT/data/corpus/raw/zhwiki-latest-pages-articles.xml.bz2" ] \
         || [ -d "$ROOT/data/corpus/wikiextract" ]; then
        bash "$ROOT/scripts/corpus/wiki_pipeline.sh" >>"$RUNLOG" 2>&1 \
          && ok "wikiextract 完成" || warn "wiki 预处理失败（见日志）"
      else
        warn "未发现 zhwiki dump，跳过维基预处理"
      fi
      ;;
    extract)
      log "阶段 extract：抽取（增量）"
      "$PY" "$ROOT/scripts/corpus/extract.py" --jobs "$JOBS" --nice "$NICE" >>"$RUNLOG" 2>&1 \
        && ok "$("$PY" "$ROOT/scripts/corpus/status.py" 2>/dev/null | tail -1)" || die "extract 失败"
      ;;
    clean)
      log "阶段 clean：清洗（增量）"
      if [ "$FULL" = 1 ]; then
        "$PY" "$ROOT/scripts/corpus/clean.py" --rebuild --jobs "$JOBS" --nice "$NICE" >>"$RUNLOG" 2>&1 \
          && ok "全量清洗完成" || die "clean 失败"
      else
        "$PY" "$ROOT/scripts/corpus/clean.py" --jobs "$JOBS" --nice "$NICE" >>"$RUNLOG" 2>&1 \
          && ok "增量清洗完成" || die "clean 失败"
      fi
      ;;
    freq)
      log "阶段 freq：用语料重扫词频（Aho-Corasick，分钟级）"
      bash "$ROOT/scripts/corpus/recount.sh" >>"$RUNLOG" 2>&1 \
        && ok "词频重扫完成" || warn "重扫失败（见日志）"
      ;;
    dict)
      log "阶段 dict：权重回归 + 分档 + gen"
      if [ -s "$ROOT/data/corpus/freq/recount_full.txt" ]; then
        "$PY" "$ROOT/scripts/reweight_from_corpus.py" \
          --freq "$ROOT/data/corpus/freq/recount_full.txt" >>"$RUNLOG" 2>&1 \
          && ok "词权重已按语料回归" || warn "权重回归失败"
      else
        warn "无重扫词频（先跑 freq 阶段），跳过权重回归"
      fi
      "$PY" "$ROOT/scripts/gen_dict_tiers.py" >>"$RUNLOG" 2>&1 \
        && ok "分档词表已生成" || warn "分档生成失败"
      "$PY" "$ROOT/scripts/set_tier.py" "$TIER" >>"$RUNLOG" 2>&1 \
        && ok "已切到 $TIER 档" || warn "切档失败"
      if [ "${SKIP_GEN:-0}" != 1 ]; then
        "$PY" "$ROOT/scripts/gen_wubi_py_unified_dicts.py" >>"$RUNLOG" 2>&1 \
          && ok "方案词库 gen 完成" || warn "gen 失败（见日志；可能是源文件缺失）"
      fi
      ;;
    gram)
      log "阶段 gram：语言模型（n-gram → kenlm → .gram）"
      if [ -f "$ROOT/scripts/corpus/gram.sh" ]; then
        bash "$ROOT/scripts/corpus/gram.sh" >>"$RUNLOG" 2>&1 \
          && ok "gram 训练完成" || warn "gram 失败（见日志）"
      else
        warn "scripts/corpus/gram.sh 尚未实现，跳过"
      fi
      ;;
    verify)
      log "阶段 verify：回归 + 账本"
      "$PY" "$ROOT/scripts/corpus/status.py" 2>&1 | tee -a "$RUNLOG" | tail -8
      ( cd "$ROOT" && make test-rebuild ) >>"$RUNLOG" 2>&1 \
        && ok "黄金用例通过" || warn "回归有失败项（见日志）"
      ;;
  esac
done
}

if [ "$LOOP" -gt 0 ]; then
  log "常驻模式：每 $LOOP 分钟增量刷新一次（Ctrl-C 或 kill 本进程退出）"
  while true; do
    run_stages
    log "本轮结束，休眠 $LOOP 分钟"
    sleep $((LOOP * 60))
  done
else
  run_stages
fi

log "刷新结束"
echo "    日志: $RUNLOG"
echo "    重新部署到输入法: make deploy"
