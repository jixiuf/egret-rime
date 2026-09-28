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
SRC_DST=(
  "egret_wubi_py.schema.yaml|egret_wubi_py.schema.yaml"
  "egret_wubi_py.dict.yaml|egret_wubi_py.dict.yaml"
  "egret_wubi.schema.yaml|egret_wubi.schema.yaml"
  "egret_wubi.dict.yaml|egret_wubi.dict.yaml"
  "egret_py.schema.yaml|egret_py.schema.yaml"
  "egret_py.dict.yaml|egret_py.dict.yaml"
  "egret.common.yaml|egret.common.yaml"
  "data/gram/lm_rerank.tsv|lm_rerank.tsv"
  "data/gram/lm_rerank.meta|lm_rerank.meta"
)
# lua 组件与词库都用 glob，别再手写文件名——2026-09 整族改名时手写清单漏了，
# 拼出 egret_wubi_py_wubi_words_* 这种改名前的路径，部署直接中断。
for f in "$ROOT"/lua/*.lua; do
  [ -e "$f" ] || continue
  SRC_DST+=("lua/$(basename "$f")|lua/$(basename "$f")")
done
# 全部 egret_wubi_py 词库（字表 common/ext、强制结束符、三档词表、整句、用户短语）
for f in "$ROOT"/dicts/egret_wubi_py/*.dict.yaml; do
  [ -e "$f" ] || continue
  SRC_DST+=("dicts/egret_wubi_py/$(basename "$f")|dicts/egret_wubi_py/$(basename "$f")")
done

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

echo "  [5/5] 重启 fcitx5（分离 stdio，避免 ssh 挂住）"
pkill -x fcitx5 2>/dev/null; sleep 2
setsid fcitx5 -d </dev/null >/dev/null 2>&1
sleep 4
pgrep -x fcitx5 >/dev/null && echo "        fcitx5 已重启 (pid $(pgrep -x fcitx5))" || echo "        ! fcitx5 未起来"

echo
echo "  --- 自检（用系统 librime / 真实目录）---"
for f in /usr/share/rime-data/*; do ln -sfn "$f" "$R/$(basename "$f")"; done
cd "$R"
out=$(LD_PRELOAD=/usr/lib64/librime.so.1.16.1 timeout 180 "$C" 2>/dev/null <<< "jintiandetianqizenmeyang
wojintianmeiyoukong
" | grep -E "^1\. " | sed 's/^1\. \[//;s/\]$//' | tr '\n' ' ')
echo "        结果: $out"
for f in /usr/share/rime-data/*; do b=$(basename "$f"); [ -L "$R/$b" ] && [ "$(readlink "$R/$b")" = "$f" ] && rm -f "$R/$b"; done
REMOTE
