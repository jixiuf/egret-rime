#!/usr/bin/env bash
# ============================================================================
# egret-rime 一键出产物：一条命令，从 data/input 的最新语料到最终产物
# ============================================================================
# 这是本项目的**唯一入口**（用户要求：一个脚本跑所有，生成最终产物）。
#
# 最终产物（artifacts）：
#   1. 词库  dicts/*.dict.yaml
#      - 分三档：core(≈2万词) / base(≈6.3万词, 默认) / full(≈78万词)
#      - 每档都同时含 **五笔码**（万象逗号码 + 86 造词码）与 **拼音码**
#      - 权重已按语料词频回归到 0-1000（与 LM 同尺度）
#   2. 语言模型  data/gram/zh-hans-egret.gram（字级 2-6gram）
#   3. 部署（可选 --deploy）：软链到 Rime 用户目录，重启输入法即生效
#
# 全链路：fetch → extract → clean → freq → dict → gram → artifacts
#
# 用法:
#   bash scripts/refresh.sh                 # 增量刷新（可反复重跑，数据更新后直接再跑）
#   bash scripts/refresh.sh --deploy        # 完成后部署到输入法
#   bash scripts/refresh.sh --tier full     # 生成/切换到 full 档
#   bash scripts/refresh.sh --loop 30       # 常驻：每 30 分钟增量刷新（语料持续下载中）
#   bash scripts/refresh.sh --only gram     # 只跑某阶段
#   bash scripts/refresh.sh --from clean    # 从某阶段开始
#   bash scripts/refresh.sh --full          # 全量重建（清洗从零开始，最慢）
#   bash scripts/refresh.sh --list          # 各阶段状态
#   bash scripts/refresh.sh --jobs 6        # 并发（默认 3；负载 <12 时可用 6）
#
# 并发保护：flock 防重入；所有阶段 nice 15 + ioprio best-effort/7
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/third-party/venv/bin/python"
[ -x "$PY" ] || PY=python3
LOG="$ROOT/data/corpus/log"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUNLOG="$LOG/refresh-$STAMP.log"
mkdir -p "$LOG"

# ── 已调好的管线参数（改动请写在这里，保证 refresh.sh 可完整复现）─────────────
# TIER          词典档位: core|base|full（base=6.3万词，实测 full 无额外收益）
# LM_TOPK_*     Lua LM 表各阶条数（190 万条 2-6gram，实测比 60 万条 +5pp 完全命中）
# REWEIGHT     词权重回归: off（默认，保持万象原值）| band | log1000
#   ⚠ 实测 log1000 会打破字表/词表平衡（黄金 20/20 → 17/20），故默认 off；
#     要重做必须整链重标定 + 用 make test 标定，见 docs/PROGRESS.md
# CHAR_SHIFT    配合 log1000 的字表下移量（log*1000 尺度）
TIER="${TIER:-base}"
REWEIGHT="${REWEIGHT:-off}"
CHAR_SHIFT="${CHAR_SHIFT:-0}"
LM_TOPK_2="${LM_TOPK_2:-600000}"
LM_TOPK_3="${LM_TOPK_3:-600000}"
LM_TOPK_4="${LM_TOPK_4:-400000}"
LM_TOPK_5="${LM_TOPK_5:-200000}"
LM_TOPK_6="${LM_TOPK_6:-100000}"

JOBS="${JOBS:-3}"
NICE="${NICE:-15}"
TIER="${TIER:-base}"
FULL=0; FROM=""; ONLY=""; LIST=0; LOOP=0; DEPLOY=0

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
    --deploy) DEPLOY=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 防重入：两个 refresh 并跑会互相踩分片
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOG/.refresh.lock"
  flock -n 9 || { echo "另一个 refresh 正在运行，本次退出"; exit 0; }
fi

STAGES=(fetch extract clean freq dict gram artifacts)

log()  { printf '\n\033[1;36m═══ [%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; printf '[%s] %s\n' "$(date +%F\ %T)" "$*" >> "$RUNLOG"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; printf '  OK %s\n' "$*" >> "$RUNLOG"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; printf '  WARN %s\n' "$*" >> "$RUNLOG"; }
die()  { printf '    \033[31m✗\033[0m %s\n' "$*" >&2; printf '  FAIL %s\n' "$*" >> "$RUNLOG"; exit 1; }

stage_status() {
  case "$1" in
    fetch)   echo "开源语料 $(find "$ROOT/data/input/open" -type f ! -name '*.part' 2>/dev/null | wc -l) 个文件" ;;
    extract) echo "已抽取 $(wc -l < "$ROOT/data/corpus/meta/extract_index.jsonl" 2>/dev/null || echo 0) 篇" ;;
    clean)   echo "已清洗 $(wc -l < "$ROOT/data/corpus/meta/clean_index.jsonl" 2>/dev/null || echo 0) 篇" ;;
    freq)    echo "重扫词频 $(du -h "$ROOT/data/corpus/freq/recount_full.txt" 2>/dev/null | cut -f1 || echo -)" ;;
    dict)    echo "档位 $(grep -ohE 'egret_wubi_py_(words|wubi_words|pinyin_words)_(core|base|full)' "$ROOT/egret_wubi_py.dict.yaml" 2>/dev/null | head -1)" ;;
    gram)    echo "gram $(ls -la "$ROOT/data/gram"/*.gram 2>/dev/null | wc -l) 个" ;;
    artifacts) echo "见 bash scripts/refresh.sh --only artifacts" ;;
  esac
}

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
      log "阶段 fetch：更新开源语料（断点续传，配额分批）"
      bash "$ROOT/scripts/corpus/fetch_open.sh" --max-gb "${FETCH_MAX_GB:-20}" >>"$RUNLOG" 2>&1 \
        && ok "开源语料已更新" || warn "下载有失败项（重跑续传）"
      if [ -s "$ROOT/data/corpus/raw/zhwiki-latest-pages-articles.xml.bz2" ] \
         || [ -d "$ROOT/data/corpus/wikiextract" ]; then
        bash "$ROOT/scripts/corpus/wiki_pipeline.sh" >>"$RUNLOG" 2>&1 \
          && ok "维基预处理完成" || warn "维基预处理未完成（可重跑）"
      fi
      ;;
    extract)
      log "阶段 extract：抽取（增量，按文件类型自动分派）"
      "$PY" "$ROOT/scripts/corpus/extract.py" --jobs "$JOBS" --nice "$NICE" >>"$RUNLOG" 2>&1 \
        || die "extract 失败（见 ${RUNLOG}）"
      ok "$("$PY" "$ROOT/scripts/corpus/status.py" 2>/dev/null | tail -1)"
      ;;
    clean)
      log "阶段 clean：清洗 + 短句切分（增量，布隆去重）"
      if [ "$FULL" = 1 ]; then
        "$PY" "$ROOT/scripts/corpus/clean.py" --rebuild --jobs "$JOBS" \
          --nice "$NICE" --dedup-capacity 2.5e9 >>"$RUNLOG" 2>&1 || die "clean 失败"
        ok "全量清洗完成"
      else
        "$PY" "$ROOT/scripts/corpus/clean.py" --jobs "$JOBS" \
          --nice "$NICE" --dedup-capacity 2.5e9 >>"$RUNLOG" 2>&1 || die "clean 失败"
        ok "增量清洗完成"
      fi
      ;;
    freq)
      log "阶段 freq：用语料重扫词频（Aho-Corasick，多路并行）"
      bash "$ROOT/scripts/corpus/recount.sh" '' recount_full "$JOBS" >>"$RUNLOG" 2>&1 \
        && ok "词频重扫完成" || warn "重扫失败（见日志；分片已保留）"
      ;;
    dict)
      log "阶段 dict：分档 + 方案词库生成（档位 ${TIER}，权重回归 REWEIGHT=${REWEIGHT}）"
      git -C "$ROOT" checkout -- dicts/ 2>/dev/null || true   # 从干净词库出发，保证可复现
      if [ "$REWEIGHT" != "off" ] && [ -s "$ROOT/data/corpus/freq/recount_full.txt" ]; then
        local extra=""
        [ "$REWEIGHT" = "log1000" ] && extra="--char-from-lm $ROOT/data/gram/lm_rerank.tsv --char-shift $CHAR_SHIFT"
        "$PY" "$ROOT/scripts/reweight_from_corpus.py" \
          --freq "$ROOT/data/corpus/freq/recount_full.txt" --scale "$REWEIGHT" $extra \
          >>"$RUNLOG" 2>&1 && ok "词权重已按语料回归（${REWEIGHT}）" || warn "权重回归失败"
      else
        ok "权重回归: 关闭（保持仓库内词库原值；实测 log1000 会破黄金用例）"
      fi
      # 拼音词表：原方案依赖缺失的万象 base.small.dict.yaml（上游已迁移），
      # 现改用 pypinyin 从仓库内五笔词表现场标注 —— 实测质量等价（同为 26%），
      # 且让整条 dict 管线可复现（见 docs/PROGRESS.md）
      # 未接入的生成器（有意）：gen_char_weights.py / gen_pinyin_chars.py（字表权重校准与
      # 生僻字拼音，已由 §4.23 的字表分层取代）；gen_compose_table.py（统一码表搜索器，
      # 只在 dynamic_translator/lm_compose: true 时用，默认关）；gen_eval_set.py（评测集工具，
      # 不是产品产物）。需要时手动跑。
      "$PY" "$ROOT/scripts/gen_pinyin_words.py" --tier "$TIER" >>"$RUNLOG" 2>&1 \
        && ok "拼音词表已生成（pypinyin 标注，可复现）" || warn "拼音词表生成失败"
      # ⭐ 把一/二级简码补进**混合库字表**：组句是混合库的 script_translator 在 prism 上做的，
      # 而「一级简码只在传统库发」会让简码层不在组句的拼写空间里 → qchifanle / qktqn
      # 这类混流输入组不出正确句子（详见 docs/PROGRESS.md §4.19）。源数据在仓库内，幂等。
      "$PY" "$ROOT/scripts/gen_jianma_spellings.py" >>"$RUNLOG" 2>&1 \
        && ok "简码拼写已补入混合库（混流组句的关键）" || warn "简码拼写补入失败"
      # 字表分层：common（语料出现过 + 有拼音的基本区字）默认 import；
      # ext（其余 10.9 万扩展区汉字，占原表 87%）不默认加载，用户一行 patch 开启。
      # 必须在 gen_jianma_spellings 之后（它会给字表补拼写）。见 docs/PROGRESS.md §4.23
      "$PY" "$ROOT/scripts/gen_char_layers.py" >>"$RUNLOG" 2>&1 \
        && ok "字表已分层（common 默认 / ext 可选）" || warn "字表分层失败"
      # 整句词库（高频整句 -> 五笔短码序列）。依赖 data/corpus（本地语料，不入 git），
      # 所以产物要入 git；语料有更新时重跑本步。
      if [ -d "$ROOT/data/corpus/clean/para" ]; then
        "$PY" "$ROOT/scripts/gen_sentence_dict.py" --top 60000 >>"$RUNLOG" 2>&1 \
          && ok "整句词库已生成" || warn "整句词库生成失败"
      else
        ok "跳过整句词库（无 data/corpus，用仓库内已有产物）"
      fi
      "$PY" "$ROOT/scripts/gen_dict_tiers.py" >>"$RUNLOG" 2>&1 \
        && ok "三档词表已生成（五笔码 + 拼音码）" || warn "分档生成失败"
      # 四字词（§4.67）：词库/仓库都没有四字词源，用**自有语料 jieba 挖掘**
      # （`社会主义/人工智能/也就是说`…）；五笔码=每字首码，权重按 log 词频映射到 300~700。
      if [ -d "$ROOT/data/corpus/clean/para" ]; then
        # 权重上界 700 是实测值（450 → 四字词 top1 68%，700 → 86%），改了要重跑 verify-wubi
        "$PY" "$ROOT/scripts/gen_wubi_86_mined_4char.py" --mine-mb 800 \
          --w-lo 300 --w-hi 700 >>"$RUNLOG" 2>&1 \
          && ok "四字词（语料挖掘）已生成" || warn "四字词挖掘失败"
      else
        ok "跳过四字词挖掘（无 data/corpus，用仓库内已有产物）"
      fi
      # 四字词的**拼音码**（同上来源；只用主读音，§4.56 的词组感知注音）
      if [ -f "$ROOT/dicts/egret_wubi_words_wb86_mined4.dict.yaml" ]; then
        "$PY" "$ROOT/scripts/gen_pinyin_words.py" \
          --src "$ROOT/dicts/egret_wubi_words_wb86_mined4.dict.yaml" \
          --out-name egret_py_words_mined4 >>"$RUNLOG" 2>&1 \
          && ok "四字词拼音码已生成" || warn "四字词拼音码生成失败"
      fi
      # 五笔长尾（§4.60）：86 造词码家族没有长尾（base==full==6.3万词），
      # 把万象长尾的二字词按自举的字码表转成 86 词组码，让五笔能打出罕见词。
      "$PY" "$ROOT/scripts/gen_wubi_86_longtail.py" >>"$RUNLOG" 2>&1 \
        && ok "五笔 86 长尾词已生成（约 8.3 万条，可复现）" || warn "五笔长尾生成失败"
      "$PY" "$ROOT/scripts/set_tier.py" "$TIER" >>"$RUNLOG" 2>&1 \
        && ok "已切到 $TIER 档" || warn "切档失败"
      # 长尾拼音词（§4.55）：base 档只收权重 >=451 的词，451 以下的长尾在纯拼音路径上
      # 「只能单字硬组」——本步给它们补拼音码。实测两套独立句子集各 +6 句，
      # 混流与黄金零回归；多读音展开反而更差，故 max-readings 保持默认 1。
      "$PY" "$ROOT/scripts/gen_pinyin_words.py" \
        --src "$ROOT/dicts/egret_wubi_words_wangxiang_full.dict.yaml" \
        --min-weight 300 --exclude "$ROOT/dicts/egret_py_words_base.dict.yaml" \
        --out-name egret_py_words_longtail >>"$RUNLOG" 2>&1 \
        && ok "长尾拼音词已生成（约 18 万条，可复现）" || warn "长尾拼音词生成失败"
      # 注意：gen_wubi_py_unified_dicts.py **不能在这里自动跑**，两个原因：
      #   ① 它需要 dicts/wangxiang_cn_dicts/base.small.dict.yaml（**拼音侧**源，本仓库没有）
      #      —— 五笔侧（本次关心的部分）其实能算，但整脚本会因此中断；
      #   ② 它会覆盖根 wrapper egret_wubi.dict.yaml，而那里现在是分档 + 五笔长尾的接线。
      # 所以它的产物按"入库源数据"处理（与下面 gen_wubi_py_unified_dicts 段落一致）；
      # 但它的**词组码式规则已修正为标准五笔**（§4.62：三字词 1+1+2、五字以上 前3首码+末首码），
      # 且契约检查（check_consistency 2.8）守着——不再需要"生成后再修"。
      # 即：字符表层的**主体**（字/拼音码/五笔全码）按"入库源数据"处理；
      # 但**简码拼写**已由 gen_jianma_spellings.py 从仓库内派生（上面那步），
      # 分档词表层由 gen_dict_tiers.py 从仓库内数据派生 —— 组句所需的部分均可复现。
      if [ "${SKIP_GEN:-1}" != 1 ]; then
        "$PY" "$ROOT/scripts/gen_wubi_py_unified_dicts.py" >>"$RUNLOG" 2>&1 \
          && ok "方案词库 gen 完成" || warn "gen 失败（缺外部源数据，属预期）"
      else
        ok "跳过 gen_wubi_py_unified_dicts（需外部源数据，字表按入库源数据）"
      fi
      ;;
    gram)
      log "阶段 gram：n-gram 统计 → Lua 重排表（LM 不参与分词）"
      bash "$ROOT/scripts/corpus/gram.sh" >>"$RUNLOG" 2>&1 \
        && ok "n-gram 统计完成" || warn "gram 失败（见日志）"
      if [ -s "$ROOT/data/gram/zh-hans-egret.2_6gram.tsv" ]; then
        "$PY" "$ROOT/scripts/gen_chengyu_dict.py" >>"$RUNLOG" 2>&1 \
          && ok "成语词典已生成" || warn "成语词典生成失败"
        "$PY" "$ROOT/scripts/gen_lm_rerank.py" \
          --top2 "$LM_TOPK_2" --top3 "$LM_TOPK_3" --top4 "$LM_TOPK_4" \
          --top5 "$LM_TOPK_5" --top6 "$LM_TOPK_6" >>"$RUNLOG" 2>&1 \
          && ok "Lua LM 表已生成（data/gram/lm_rerank.tsv）" \
          || warn "LM 表生成失败"
        "$PY" "$ROOT/scripts/gen_py_tables.py" --tier "$TIER" >>"$RUNLOG" 2>&1 \
          && ok "Lua 搜索器词表已生成（py_words/py_syllables）" \
          || warn "词表生成失败"
        # 统一码表（搜索器/切分器用）：输出 .tsv + .bin（.bin 是运行时读的）
        "$PY" "$ROOT/scripts/gen_compose_table.py" >>"$RUNLOG" 2>&1 \
          && ok "统一码表已生成（tsv + bin）" || warn "统一码表生成失败"
      fi
      ;;
    artifacts)
      log "阶段 artifacts：最终产物清单"
      "$PY" "$ROOT/scripts/artifacts.py" 2>&1 | tee -a "$RUNLOG"
      ;;
  esac
done

if [ "$DEPLOY" = 1 ]; then
  log "部署到输入法"
  ( cd "$ROOT" && make deploy ) >>"$RUNLOG" 2>&1 && ok "已部署" || warn "部署失败"
fi
}

if [ "$LIST" = 1 ]; then
  printf '%-12s %s\n' 阶段 状态
  for s in "${STAGES[@]}"; do printf '%-12s %s\n' "$s" "$(stage_status "$s")"; done
  echo; echo "日志: $RUNLOG"
  exit 0
fi

if [ "$LOOP" -gt 0 ]; then
  log "常驻模式：每 $LOOP 分钟增量刷新一轮（Ctrl-C 退出）"
  while true; do
    run_stages
    log "本轮结束，休眠 $LOOP 分钟"
    sleep $((LOOP * 60))
  done
else
  run_stages
  log "刷新结束"
  echo "    日志: $RUNLOG"
  [ "$DEPLOY" = 1 ] || echo "    部署到输入法: bash scripts/refresh.sh --deploy（或 make deploy）"
fi
