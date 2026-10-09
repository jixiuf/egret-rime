#!/usr/bin/env bash
# ============================================================================
# 把 host-linux 的 Rime 用户目录做成「自包含」：直接放实体文件，不再软链到 vmacs
# ============================================================================
# 用户要求："remove all files in ~/.local/share/fcitx5/rime and copy files there,
#            don't need copy to vmacs"
#
# 做法（保守，不丢东西）：
#   1) 整目录备份到 ~/rime-backup-<时间戳>.tar.gz
#   2) 把现有**软链实体化**（cp -aL）——保留你其它方案(egret_py/egret_wubi/…)、
#      用户词典、build 等一切内容，只是不再依赖 ~/vmacs/rime
#      （体积大的 *.gram 保持软链不复制）
#   3) 覆盖本次要更新的 16 个运行时文件
#   4) rime_deployer 重建 + 重启 fcitx5（带 shared data，避免 symbols 编译失败）
#   5) 用 rime_api_console 自检
#
# 用法: bash scripts/deploy_host-linux_direct.sh [--check]
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="jixiuf@localhost"
PORT=8093
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

find_agent() {
  for s in /tmp/ssh-*/agent.*; do
    [ -S "$s" ] || continue
    SSH_AUTH_SOCK="$s" timeout 5 ssh-add -l >/dev/null 2>&1 && { echo "$s"; return 0; }
  done
  return 1
}
SOCK="$(find_agent)" || { echo "找不到可用的 ssh-agent socket（需要你本机开着带 agent 转发的会话）"; exit 1; }
export SSH_AUTH_SOCK="$SOCK"
SSH="ssh -p $PORT -o BatchMode=yes"
echo "==> agent socket: $SOCK"

# 要部署的文件：源(仓库内) | 目标(Rime 目录相对路径)
SRC_DST=()
# 运行时清单由 scripts/deploy_bundle.sh --list 提供（唯一来源）。
# 为什么不再自己 glob：曾经 glob "data/gram/*.tsv" 把 632MB 的
# zh-hans-egret.2_6gram.tsv（gram 训练中间产物）也部署出去了。
while IFS='|' read -r s d; do
  [ -n "$s" ] || continue
  SRC_DST+=("$s|$d")
done < <(bash "$ROOT/scripts/deploy_bundle.sh" --list)
for pair in "${SRC_DST[@]}"; do
  s="${pair%%|*}"
  [ -e "$ROOT/$s" ] || { echo "  ! 缺少 $ROOT/$s"; exit 1; }
done
echo "==> 待部署 ${#SRC_DST[@]} 个文件"

STAGE="$(mktemp -d)"
mkdir -p "$STAGE/egret"
for pair in "${SRC_DST[@]}"; do
  s="${pair%%|*}"; d="${pair##*|}"
  mkdir -p "$STAGE/egret/$(dirname "$d")"
  cp -a "$ROOT/$s" "$STAGE/egret/$d"
done
(cd "$STAGE" && tar czf egret.tar.gz egret)
scp -P "$PORT" "$STAGE/egret.tar.gz" "$HOST:/tmp/" || exit 1
rm -rf "$STAGE"

TS="$(date +%Y%m%d-%H%M%S)"
echo "==> 远端：备份 → 实体化 → 覆盖 → 重建 → 重启"
$SSH "$HOST" "TS=$TS CHECK=$CHECK_ONLY bash -s" <<'REMOTE' 2>&1 | tail -32
set -uo pipefail
R="$HOME/.local/share/fcitx5/rime"
C="$HOME/repos/librime/build/bin/rime_api_console"

if [ "$CHECK" = 1 ]; then
  echo "  当前目录: $(ls "$R" | wc -l) 项, 其中软链 $(find "$R" -maxdepth 1 -type l | wc -l) 个"
  echo "  指向 vmacs 的: $(find "$R" -maxdepth 1 -type l -lname '*vmacs*' | wc -l) 个"
  exit 0
fi

echo "  [1/5] 整目录备份"
BAK="$HOME/rime-backup-$TS.tar.gz"
tar czf "$BAK" -C "$HOME/.local/share/fcitx5" rime 2>/dev/null
echo "        $BAK ($(du -h "$BAK" | cut -f1))"

echo "  [2/5] 软链实体化（大文件 *.gram 保持软链）"
n=0
while IFS= read -r l; do
  tgt=$(readlink -f "$l") || continue
  case "$l" in *.gram) continue ;; esac          # 200MB 的 gram 不复制
  [ -e "$tgt" ] || continue
  rm -f "$l"
  if [ -d "$tgt" ]; then cp -aL "$tgt" "$l"; else cp -a "$tgt" "$l"; fi
  n=$((n+1))
done < <(find "$R" -maxdepth 1 -type l)
echo "        实体化 $n 个软链；剩余软链 $(find "$R" -maxdepth 1 -type l | wc -l) 个"

echo "  [3/5] 覆盖运行时文件"
cd /tmp && rm -rf egret && tar xzf egret.tar.gz
( cd egret && find . -type f | sed 's|^\./||' | while IFS= read -r f; do
    mkdir -p "$R/$(dirname "$f")" && cp -f "$f" "$R/$f"
  done )
echo "        $(cd egret && find . -type f | wc -l) 个文件已更新"

echo "  [4/5] 重建（带 shared data）"
rime_deployer --build "$R" /usr/share/rime-data "$R/build" 2>&1 | grep -icE "error" | sed 's/^/        error 行数: /'

# 重建会把「schema 里没引用、运行时才读」的表挪进 $R/trash/（实测 lm_rerank.bin/.meta
# 被移走，时间戳与重建同一分钟；它们是 Lua 运行时读的，deployer 看不见引用关系）→ 补回。
for f in lm_rerank.bin lm_rerank.meta compose_table.bin py_meta.txt; do
  src="/tmp/egret/dicts/$f"
  if [ -e "$src" ]; then
    mkdir -p "$R/dicts"
    cp -f "$src" "$R/dicts/$f" && echo "        确保 $f 在 dicts/（放根目录会被 deployer 移进 trash/）"
  fi
done

echo "  [5/5] 重启 fcitx5（分离 stdio，避免 ssh 挂住）"
pkill -x fcitx5 2>/dev/null; sleep 2
setsid fcitx5 -d </dev/null >/dev/null 2>&1
sleep 4
pgrep -x fcitx5 >/dev/null && echo "        fcitx5 已重启 (pid $(pgrep -x fcitx5))" || echo "        ! fcitx5 未起来"

echo
echo "  --- 自检（用系统 librime / 真实目录）---"
for f in /usr/share/rime-data/*; do ln -sfn "$f" "$R/$(basename "$f")"; done
cd "$R"
# 用系统 librime（自动取最高版本）。**不要**像以前那样硬编码 1.16.1：
# librime < 1.17 时长句只出 1 个候选，LM 重排无从下手，自检会报假故障
# （实测：preload 1.16.1 时「今天的天气怎么养」，用系统 1.17.0 时「怎么样」）。
SYS_LIB="$(ls -1 /usr/lib64/librime.so.1.1[7-9]* /usr/lib/librime.so.1.1[7-9]* 2>/dev/null | sort -V | tail -1)"
[ -z "$SYS_LIB" ] && SYS_LIB="$(ls -1 /usr/lib64/librime.so.1.[0-9]* 2>/dev/null | sort -V | tail -1)"
echo "        librime: ${SYS_LIB:-（未找到，用 console 自带）}"
# 每条输入**单独跑一次 console**（一次喂多行会让后一行的按键落进前一条还没提交的
# 组字里，输出中途候选 → 假故障）；且跑两轮取第二轮（重建后首跑有冷启动竞态，
# 见 docs/PROGRESS.md §4.18 测量纪律）。
# 固定方案：console 按 user.yaml 的 previously_selected_schema 选方案。若不固定，
# 用户切到 egret_py 时自检会**静默地测纯拼音**（五笔用例全错的假故障，macOS 侧踩过）。
sed -i 's/^[[:space:]]*previously_selected_schema: .*/  previously_selected_schema: egret_wubi_py/' "$R/user.yaml" 2>/dev/null
out=""
for _pass in 1 2; do
  out=""
  # 加三条五笔/混流用例：只测拼音长句看不出「方案选错/五笔层坏」这类回归
  for _code in jintiandetianqizenmeyang wojintianmeiyoukong tffu khlg qktnqnr; do
    r=$(LD_PRELOAD="$SYS_LIB" timeout 180 "$C" 2>/dev/null <<< "$_code
" | grep -m1 -E "^1\. " | sed 's/^1\. \[//;s/\]$//')
    out="$out$r  "
  done
done
echo "        结果: $out（第 2 轮）"
echo "        期望: 今天的天气怎么样 我今天没有空 等 中国 我吃饭"
for f in /usr/share/rime-data/*; do b=$(basename "$f"); [ -L "$R/$b" ] && [ "$(readlink "$R/$b")" = "$f" ] && rm -f "$R/$b"; done
REMOTE
