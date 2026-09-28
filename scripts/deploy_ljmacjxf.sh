#!/usr/bin/env bash
# ============================================================================
# 部署到 macOS（host-mac / Squirrel）：ssh -p 8092 jixiuf@localhost
# —— 直接把运行时文件写成 **实体文件**，落在 ~/Library/Rime（不依赖 vmacs 软链）
# ============================================================================
# 参照 scripts/deploy_host-linux_direct.sh，macOS 侧的差异：
#   * 目标机 host-mac（Darwin arm64），ssh 走本机 agent 转发：jixiuf@localhost:8092
#   * Rime 用户目录：~/Library/Rime（Squirrel）
#   * 共享数据：/Library/Input Methods/Squirrel.app/Contents/SharedSupport
#   * 重新部署：Squirrel 自带 rime_deployer --build（**默认不重启 Squirrel**，
#     文件到位即可；Squirrel 菜单“重新部署”或下次登录即生效；需要立即重启加 --restart）
#   * 自检：~/repos/librime/build/bin/rime_api_console（1.17）
#     在独立 scratch 目录 ~/.egret-check 里跑，**不碰** ~/Library/Rime/build
#     （避免 1.17 的 console 覆盖 Squirrel 内置 1.16 的 build 产物）
#
# 做法（保守，不丢东西）：
#   1) 先整目录备份：~/rime-backup-<时间戳>.tar.gz（软链按软链存，含回滚所需一切）
#   2) 把 ~/Library/Rime 根级软链**实体化**（*.gram / sync 除外，太大/是用户数据）
#      —— 包括 dicts/ lua/ opencc/ 这三个目录软链，之后彻底不依赖 ~/vmacs/rime
#   3) 覆盖本次要更新的 24 个运行时文件（含全部 15 个 egret_wubi_py 词库）
#   4) Squirrel 的 rime_deployer --build 重建
#   5) ~/.egret-check 里跑 rime_api_console 自检（不动 ~/Library/Rime/build）
#   可选 --restart 重启 Squirrel；默认不动它（文件到位即可）
#
# 用法:
#   bash scripts/deploy_host-mac.sh                # 完整部署（不重启 Squirrel）+ 自检
#   bash scripts/deploy_host-mac.sh --restart      # 部署完顺便重启 Squirrel
#   bash scripts/deploy_host-mac.sh --check        # 只探测远端环境（不写任何东西）
#   bash scripts/deploy_host-mac.sh --no-check     # 部署但跳过 console 自检
#   bash scripts/deploy_host-mac.sh --keep-links   # 保留软链（穿透写入 ~/vmacs/rime）
#   bash scripts/deploy_host-mac.sh --rollback ~/rime-backup-xxx.tar.gz   # 回滚
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="jixiuf@localhost"
PORT=8092
CHECK_ONLY=0
NO_CHECK=0
KEEP_LINKS=0
RESTART=0
ROLLBACK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)      CHECK_ONLY=1; shift ;;
    --no-check)   NO_CHECK=1; shift ;;
    --keep-links) KEEP_LINKS=1; shift ;;
    --restart)    RESTART=1; shift ;;
    --rollback)   ROLLBACK="${2:-}"; shift 2 ;;
    -*)           echo "未知参数: $1"; exit 1 ;;
    *)            HOST="$1"; shift ;;
  esac
done

# --- 选认证方式：能签名的 agent socket，或本地私钥 ---------------------------
# 注意：`ssh-add -l` 成功 ≠ 能签名。远端转发进来的 gpg-agent（socket 属主是
# sshd）通常处于 restricted 模式，或签名时要在远端 pinentry 上确认 → 握手时报
# "sign_and_send_pubkey: signing failed: agent refused operation"。
# 所以这里用一次**真实握手**（ssh ... true）来挑认证方式，顺序：
#   1) 真能签名的 agent socket（本机开着带 agent 转发的 ssh 会话时）
#   2) 本地落地私钥（EGRET_SSH_KEY → ~/.ssh/id_rsa → vmacs dots/ssh/id_rsa）
#   3) 都没有时自起一个 ssh-agent 并加载候选私钥
PORT_OPTS=(-p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
KEY_CANDIDATES=(
  "${EGRET_SSH_KEY:-}"
  "$HOME/.ssh/id_rsa"
  "/export/vmacs/dots/ssh/id_rsa"
)
SSH_ID_ARGS=()
AUTH_DESC=""

for s in /tmp/ssh-*/agent.* /run/user/"$(id -u)"/gnupg/S.gpg-agent.ssh; do
  [ -S "$s" ] || continue
  SSH_AUTH_SOCK="$s" timeout 5 ssh-add -l >/dev/null 2>&1 || continue
  if SSH_AUTH_SOCK="$s" timeout 20 ssh "${PORT_OPTS[@]}" "$HOST" true >/dev/null 2>&1; then
    export SSH_AUTH_SOCK="$s"
    AUTH_DESC="agent socket $s"
    break
  fi
done

if [ -z "$AUTH_DESC" ]; then
  for k in "${KEY_CANDIDATES[@]}"; do
    [ -f "$k" ] || continue
    if timeout 20 ssh "${PORT_OPTS[@]}" -o IdentitiesOnly=yes -i "$k" "$HOST" true >/dev/null 2>&1; then
      SSH_ID_ARGS=(-i "$k" -o IdentitiesOnly=yes)
      AUTH_DESC="本地私钥 $k"
      break
    fi
  done
fi

if [ -z "$AUTH_DESC" ]; then
  echo "==> 没有可用 agent/私钥，自起 ssh-agent 并加载候选私钥"
  eval "$(ssh-agent -s)" >/dev/null 2>&1 || true
  for k in "${KEY_CANDIDATES[@]}"; do
    [ -f "$k" ] || continue
    ssh-add "$k" >/dev/null 2>&1 || continue
    if timeout 20 ssh "${PORT_OPTS[@]}" "$HOST" true >/dev/null 2>&1; then
      AUTH_DESC="新起的 ssh-agent + $k"
      break
    fi
  done
fi

[ -n "$AUTH_DESC" ] || {
  echo "找不到可用认证方式（agent 转发/本地私钥握手都失败）：ssh $HOST"; exit 1; }
echo "==> 认证: $AUTH_DESC（已用真实握手验证）"

SSH="ssh ${PORT_OPTS[*]}${SSH_ID_ARGS[*]+ ${SSH_ID_ARGS[*]}}"
SCP="scp -P $PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new${SSH_ID_ARGS[*]+ ${SSH_ID_ARGS[*]}}"

# --- 远端只读探测 -----------------------------------------------------------
probe() {
  $SSH "$HOST" 'bash -s' <<'PROBE'
set -uo pipefail
R="$HOME/Library/Rime"
SHARED="/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
echo "  主机: $(hostname)  $(uname -srm)"
echo "  macOS: $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
echo "  Squirrel: $(plutil -p "/Library/Input Methods/Squirrel.app/Contents/Info.plist" 2>/dev/null \
  | grep -E '"(CFBundleVersion|CFBundleShortVersionString)"' | head -1 | tr -d ' ')"
if [ -f "/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib" ]; then
  echo "  Squirrel 内置 librime: $(strings "/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib" 2>/dev/null | grep -m1 -E '^1\.[0-9]+\.[0-9]+$')"
fi
echo "  Rime 用户目录: $R  ($(ls "$R" 2>/dev/null | wc -l | tr -d ' ') 项, 根级软链 $(ls "$R" | while read -r x; do [ -L "$R/$x" ] && echo x; done | wc -l | tr -d ' ') 个)"
echo "  共享数据: $SHARED $([ -d "$SHARED" ] && echo '(存在)' || echo '(缺失!)')"
echo "  部署工具: $([ -x "/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer" ] && echo 'Squirrel rime_deployer ✓' || echo '✗')"
echo "  自检工具: $([ -x "$HOME/repos/librime/build/bin/rime_api_console" ] && echo "$HOME/repos/librime/build/bin/rime_api_console ($( (cd "$HOME/repos/librime" && git describe --tags 2>/dev/null | head -1) )) ✓" || echo '✗ 缺 ~/repos/librime/build/bin/rime_api_console')"
echo "  输入法进程: $(pgrep -x Squirrel >/dev/null && echo "Squirrel pid $(pgrep -x Squirrel)" || echo '未运行')"
for d in "$HOME/vmacs/rime" "$HOME/repos/egret-rime"; do
  [ -d "$d/.git" ] && echo "  $d: $(git -C "$d" rev-parse --short HEAD 2>/dev/null) ($(git -C "$d" status --short 2>/dev/null | wc -l | tr -d ' ') 个改动)"
done
echo "  词库现状: $(ls "$R/dicts/egret_wubi_py"/ 2>/dev/null | wc -l | tr -d ' ') 个文件; lm_rerank.tsv $([ -e "$R/lm_rerank.tsv" ] && echo 有 || echo 无)"
PROBE
}

if [ -n "$ROLLBACK" ]; then
  echo "==> 回滚：$ROLLBACK → ~/Library/Rime"
  $SSH "$HOST" "bash -s" <<ROLLBACK
set -uo pipefail
R="\$HOME/Library/Rime"
tar tzf "$ROLLBACK" >/dev/null 2>&1 || { echo "  备份包不可读: $ROLLBACK"; exit 1; }
rm -rf "\$R"
tar xzf "$ROLLBACK" -C "\$HOME/Library"
echo "  已恢复 \$R（$(ls "\$R" | wc -l | tr -d ' ') 项）"
echo "  注意：~/Library/Rime/build 未包含在备份里，请手动重新部署一次"
ROLLBACK
  exit $?
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo "==> 远端环境探测 ($HOST:$PORT)（只读，不写任何东西）"
  probe
  exit 0
fi

# --- 要部署的文件：源(仓库内) | 目标(Rime 目录相对路径) ---------------------
SRC_DST=(
  "egret.common.yaml|egret.common.yaml"
  "egret_wubi_py.schema.yaml|egret_wubi_py.schema.yaml"
  "egret_wubi_py.dict.yaml|egret_wubi_py.dict.yaml"
  "egret_wubi_py_wubi.schema.yaml|egret_wubi_py_wubi.schema.yaml"
  "egret_wubi_py_wubi.dict.yaml|egret_wubi_py_wubi.dict.yaml"
  "lua/dynamic_translator.lua|lua/dynamic_translator.lua"
  "lua/lm_rerank.lua|lua/lm_rerank.lua"
  "data/gram/lm_rerank.tsv|lm_rerank.tsv"
  "data/gram/lm_rerank.meta|lm_rerank.meta"
)
# 全部 egret_wubi_py 词库（三档 × 三库 + 字表/用户词组，共 15 个）
for f in "$ROOT"/dicts/egret_wubi_py/*.dict.yaml; do
  [ -e "$f" ] || continue
  b="dicts/egret_wubi_py/$(basename "$f")"
  SRC_DST+=("$b|$b")
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
(cd "$STAGE" && tar czf egret-mac.tar.gz egret) || exit 1
echo "==> 传到 $HOST:/tmp/egret-mac.tar.gz ($(du -h "$STAGE/egret-mac.tar.gz" | cut -f1))"
$SCP "$STAGE/egret-mac.tar.gz" "$HOST:/tmp/" || { rm -rf "$STAGE"; exit 1; }
rm -rf "$STAGE"

TS="$(date +%Y%m%d-%H%M%S)"
echo "==> 远端：备份 → 实体化 → 覆盖 → 重建 → 自检"
$SSH "$HOST" "TS=$TS KEEP_LINKS=$KEEP_LINKS NO_CHECK=$NO_CHECK RESTART=$RESTART bash -s" <<'REMOTE' 2>&1 | tail -50
set -uo pipefail
R="$HOME/Library/Rime"
SHARED="/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
SQUIRREL="/Library/Input Methods/Squirrel.app"
DEPLOYER="$SQUIRREL/Contents/MacOS/rime_deployer"
CONSOLE="$HOME/repos/librime/build/bin/rime_api_console"
CHK="$HOME/.egret-check"

[ -d "$R" ] || { echo "  ! 远端不存在 $R"; exit 1; }

# 带超时的命令（macOS 没有 GNU timeout）
# 注意：看门狗子 shell 必须把 stdout/stderr 关掉，否则它持有管道写端 →
# 外层 OUT="$(run_timeout ...)" 会一直等到看门狗退出（即 timeout 秒）→ 卡住
run_timeout() {  # run_timeout <秒> <命令...>
  local t="$1"; shift
  "$@" & local p=$!
  ( sleep "$t"; kill -9 "$p" 2>/dev/null ) </dev/null >/dev/null 2>&1 & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null
  return $rc
}

echo "  [1/5] 整目录备份（软链按软链存；*.gram/*.bak/build 太大不入包）"
BAK="$HOME/rime-backup-$TS.tar.gz"
tar czf "$BAK" --exclude='Rime/build' --exclude='*.gram' --exclude='*.bak' \
    -C "$HOME/Library" Rime 2>/dev/null
echo "        $BAK ($(du -h "$BAK" | cut -f1))  ← 回滚: tar xzf $BAK -C ~/Library"

if [ "$KEEP_LINKS" = 1 ]; then
  echo "  [2/5] 跳过实体化（--keep-links：写入会穿透软链落到 ~/vmacs/rime）"
else
  echo "  [2/5] 根级软链实体化（*.gram 与 sync 保持软链）"
  n=0
  for l in "$R"/*; do
    [ -L "$l" ] || continue
    b="${l##*/}"
    case "$b" in *.gram) continue ;; esac
    [ "$b" = sync ] && continue
    tgt="$(cd "$(dirname "$l")" && python3 -c \
      'import os,sys;print(os.path.realpath(sys.argv[1]))' "$b")"
    [ -e "$tgt" ] || { echo "        ! 悬空软链 $b → $tgt"; continue; }
    case "$tgt" in "$R"/*) echo "        ! 自引用软链 $b，跳过"; continue ;; esac
    rm -f "$l"
    if [ -d "$tgt" ]; then cp -aL "$tgt" "$l"; else cp -a "$tgt" "$l"; fi
    n=$((n+1))
  done
  echo "        实体化 $n 个（剩余软链：$(ls "$R" | while read -r x; do [ -L "$R/$x" ] && echo x; done | wc -l | tr -d ' ') 个，应只剩 *.gram/sync）"
fi

echo "  [3/5] 覆盖运行时文件"
cd /tmp && rm -rf egret && tar xzf egret-mac.tar.gz
CNT=0
while IFS= read -r f; do
  f="${f#./}"
  mkdir -p "$R/$(dirname "$f")"
  cp -f "/tmp/egret/$f" "$R/$f"
  CNT=$((CNT+1))
done < <(cd /tmp/egret && find . -type f)
echo "        更新 $CNT 个文件；lm_rerank.tsv: $([ -e "$R/lm_rerank.tsv" ] && echo 有 || echo 缺)"
echo "        剩余指向 vmacs 的软链: $(ls "$R" | while read -r x; do [ -L "$R/$x" ] && readlink "$R/$x" | grep -q vmacs && echo "$x"; done | tr '\n' ' ')(预期只剩 *.gram)"

echo "  [4/5] 重建（Squirrel 自带 rime_deployer；不动 Squirrel 进程）"
if [ -x "$DEPLOYER" ]; then
  OUT="$(run_timeout 600 "$DEPLOYER" --build "$R" "$SHARED" "$R/build" 2>&1)"
  echo "        error 行数: $(printf '%s\n' "$OUT" | grep -ciE 'error|failed' | tr -d ' ')"
  printf '%s\n' "$OUT" | grep -iE 'error|failed' | head -5 | sed 's/^/        /'
else
  echo "        ! 缺 $DEPLOYER，跳过"
fi

if [ "$RESTART" = 1 ]; then
  echo "  [5/5] 重启 Squirrel（--restart）"
  pkill -x Squirrel 2>/dev/null; sleep 1
  open "$SQUIRREL" 2>/dev/null || open -a Squirrel 2>/dev/null || echo "        ! open 失败，请手动启动 Squirrel"
  sleep 3
  pgrep -x Squirrel >/dev/null && echo "        Squirrel 已重启 (pid $(pgrep -x Squirrel))" || echo "        ! Squirrel 未起来"
else
  echo "  [5/5] 不重启 Squirrel（文件已到位；菜单‘重新部署’或下次登录生效）"
  pgrep -x Squirrel >/dev/null && echo "        当前 Squirrel pid $(pgrep -x Squirrel) 仍在运行（如需立即生效：--restart 或菜单里重新部署）"
fi

# 新架构（LM 只重排）需要 librime >= 1.17：否则长句只有 1 个候选，重排无从下手
SL="$(strings "$SQUIRREL/Contents/Frameworks/librime.1.dylib" 2>/dev/null | grep -m1 -E '^1\.[0-9]+\.[0-9]+$')"
case "$SL" in
  1.0*|1.1[0-6]*|1.[0-9]|'') echo "        ! Squirrel 内置 librime ${SL:-未知} < 1.17：新架构下长句只出 1 个候选，LM 重排不生效（需升级 Squirrel/librime）" ;;
  *) [ -n "$SL" ] && echo "        Squirrel 内置 librime ${SL} (>= 1.17，LM 重排可生效)" ;;
esac

if [ "$NO_CHECK" = 1 ]; then
  echo "  [自检] 跳过（--no-check）"
else
  echo "  [自检] ~/.egret-check 里跑 1.17 console（不动 ~/Library/Rime/build）"
  if [ ! -x "$CONSOLE" ]; then
    echo "        ! 缺 $CONSOLE，跳过"
  else
    mkdir -p "$CHK"     # 保留既有 build（热重建快得多），只刷新软链
    for f in "$R"/*; do
      b="${f##*/}"
      [ "$b" = build ] && continue          # build 用 scratch 自己的
      ln -sfn "$f" "$CHK/$b"
    done
    reset_schema() {
      [ -f "$R/user.yaml" ] || return 0
      sed -i '' -e 's/^previously_selected_schema: .*/previously_selected_schema: egret_wubi_py/' \
          "$R/user.yaml" 2>/dev/null
    }
    # console 会改写 previously_selected_schema，测前先固定
    reset_schema

    # 自检放到后台跑（写日志），免役 ssh 抖动/掉线导致中途丢结果；
    # 首次在新目录里建 build 要几分钟，之后热重建很快
    CHKLOG="$HOME/.egret-check.log"
    cat > "$HOME/.egret-check.sh" <<'CHKSCRIPT'
#!/usr/bin/env bash
R="$HOME/Library/Rime"
BIN="$HOME/repos/librime/build/bin"
CHK="$HOME/.egret-check"
cd "$CHK" || exit 1
# 预热建 build（首次可能报 failure，再显式 deploy 一次）
"$BIN/rime_api_console" </dev/null >/dev/null 2>&1
"$BIN/rime_deployer" --build "$CHK" "$BIN" "$CHK/build" >/dev/null 2>&1
for c in "e=有" "q=我" "yi=就" "tffu=等" "khlg=中国" \
         "jintiandetianqizenmeyang=今天的天气怎么样" \
         "wojintianmeiyoukong=我今天没有空" \
         "wokanshiqiaomai=我看是荞麦"; do
  code="${c%%=*}"; want="${c##*=}"
  got="$(printf '%s\n\n' "$code" | "$BIN/rime_api_console" 2>/dev/null \
         | grep -m1 -E '^1\. \[' | sed 's/^1\. \[//;s/\]$//')"
  if [ "$got" = "$want" ]; then mark="✓"; else mark="✗"; fi
  printf '%-28s 期望 %-14s 实际 %-14s %s\n' "$code" "$want" "${got:-?}" "$mark"
  # console 运行会改写 previously_selected_schema，每条用例后重置
  sed -i '' -e 's/^previously_selected_schema: .*/previously_selected_schema: egret_wubi_py/' \
      "$R/user.yaml" 2>/dev/null
done
echo "EGRET-CHECK-DONE"
CHKSCRIPT
    rm -f "$CHKLOG"
    pkill -f '.egret-check.sh' 2>/dev/null   # 清掉上次残留的自检进程
    nohup bash "$HOME/.egret-check.sh" >"$CHKLOG" 2>&1 &
    i=0; finished=0
    while [ $i -lt 90 ]; do                        # 90 × 10s = 15 分钟
      if grep -q 'EGRET-CHECK-DONE' "$CHKLOG" 2>/dev/null; then finished=1; break; fi
      sleep 10; i=$((i+1))
    done
    sed 's/^/        /' "$CHKLOG" 2>/dev/null | tail -10
    [ $finished = 1 ] || echo "        ! 自检未在时限内完成，稍后看日志: $CHKLOG"
    reset_schema
  fi
fi

echo
echo "  备份: $BAK"
echo "  回滚: bash scripts/deploy_host-mac.sh --rollback ~/rime-backup-$TS.tar.gz"
REMOTE
