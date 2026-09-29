#!/usr/bin/env bash
# ============================================================================
# 部署到 host-linux（Gentoo + fcitx5）
# ============================================================================
# host-linux 的 Rime 用户目录（~/.local/share/fcitx5/rime）**全部软链**到
# ~/vmacs/rime，所以正确做法是更新 ~/vmacs/rime（git 仓库，好回滚），
# 再为目标目录里新增的根级文件补软链。
#
# SSH: 通过本机已有的 agent 转发 socket 连 jixiuf@localhost:8093
#      （本机没有落地私钥；socket 由你的 ssh 会话 RemoteForward 提供）
#
# 用法:
#   bash scripts/deploy_host-linux.sh              # 完整部署
#   bash scripts/deploy_host-linux.sh --dry-run    # 只看要做什么
#   bash scripts/deploy_host-linux.sh --probe      # 只探远端环境
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="jixiuf@localhost"
PORT=8093
REMOTE_REPO="~/vmacs/rime"
REMOTE_RIME="~/.local/share/fcitx5/rime"
DRY=0
PROBE=0
[ "${1:-}" = "--dry-run" ] && DRY=1
[ "${1:-}" = "--probe" ] && PROBE=1

# --- 找一个可用的 agent 转发 socket -----------------------------------------
find_agent() {
  for s in /tmp/ssh-*/agent.* /run/user/$(id -u)/gnupg/S.gpg-agent.ssh; do
    [ -S "$s" ] || continue
    if SSH_AUTH_SOCK="$s" timeout 5 ssh-add -l >/dev/null 2>&1; then
      echo "$s"; return 0
    fi
  done
  return 1
}
SOCK="$(find_agent)" || {
  echo "找不到可用的 ssh-agent socket。"
  echo "请在你自己机器上开着到本机的 ssh 会话（带 agent 转发），或把公钥加到 host-linux。"
  exit 1
}
export SSH_AUTH_SOCK="$SOCK"
SSH="ssh -p $PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
echo "==> agent socket: $SOCK"

if [ "$PROBE" = 1 ]; then
  $SSH "$HOST" 'echo "  主机: $(hostname) $(uname -sr)"; echo "  Rime: $(ls ~/.local/share/fcitx5/rime | wc -l) 项"; echo "  仓库: ~/vmacs/rime $(git -C ~/vmacs/rime rev-parse --short HEAD 2>/dev/null)"'
  exit 0
fi

# --- 需要部署的文件：源(仓库内) | 目标(远端仓库根相对路径) ------------------
SRC_DST=(
  "egret_wubi_py.schema.yaml|egret_wubi_py.schema.yaml"
  "egret_wubi_py.dict.yaml|egret_wubi_py.dict.yaml"
  "egret_wubi.dict.yaml|egret_wubi.dict.yaml"
  "lua/dynamic_translator.lua|lua/dynamic_translator.lua"
  "lua/lm_rerank.lua|lua/lm_rerank.lua"
  "data/gram/lm_rerank.tsv|lm_rerank.tsv"
  "data/gram/lm_rerank.meta|lm_rerank.meta"
)
for t in core base full; do
  for k in words wubi_words pinyin_words; do
    p="dicts/egret_wubi_py_${k}_${t}.dict.yaml"
    SRC_DST+=("$p|$p")
  done
done

count=0
echo "==> 检查本地文件"
for pair in "${SRC_DST[@]}"; do
  s="${pair%%|*}"
  if [ ! -e "$ROOT/$s" ]; then echo "  ! 缺少 $s"; MISS=1; else count=$((count+1)); fi
done
[ "${MISS:-0}" = 1 ] && exit 1
echo "  $count 个文件"

if [ "$DRY" = 1 ]; then
  echo; echo "==> dry-run：会做以下事"
  echo "  1) 打包并 scp 到 $HOST:/tmp/"
  echo "  2) 远端备份现有文件到 $REMOTE_REPO/.deploy-backup-<时间戳>/"
  echo "  3) 覆盖/新增文件到 $REMOTE_REPO/"
  echo "  4) 在 $REMOTE_RIME 为 lm_rerank.tsv/.meta 补软链"
  echo "  5) rime_deployer --build + reload fcitx5"
  exit 0
fi

# --- 打包 -------------------------------------------------------------------
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/egret-deploy"
for pair in "${SRC_DST[@]}"; do
  s="${pair%%|*}"; d="${pair##*|}"
  mkdir -p "$STAGE/egret-deploy/$(dirname "$d")"
  cp -a "$ROOT/$s" "$STAGE/egret-deploy/$d"
done
(cd "$STAGE" && tar czf egret-deploy.tar.gz egret-deploy)
echo "==> 传到 $HOST:/tmp/egret-deploy.tar.gz ($(du -h "$STAGE/egret-deploy.tar.gz" | cut -f1))"
scp -P "$PORT" "$STAGE/egret-deploy.tar.gz" "$HOST:/tmp/" || exit 1

# --- 远端安装 ---------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
echo "==> 远端安装"
$SSH "$HOST" "bash -s" <<REMOTE
set -uo pipefail
V=$REMOTE_REPO
R=$REMOTE_RIME
BAK="\$V/.deploy-backup-$TS"
cd /tmp && rm -rf egret-deploy && tar xzf egret-deploy.tar.gz
cd egret-deploy

echo "  远端仓库改动前: \$(git -C \$V status --short | wc -l) 个待提交改动"
mkdir -p "\$BAK"
# 备份将被覆盖的文件
while IFS= read -r f; do
  if [ -e "\$V/\$f" ]; then
    mkdir -p "\$BAK/\$(dirname "\$f")"
    cp -a "\$V/\$f" "\$BAK/\$f"
  fi
done < <(find . -type f | sed 's|^\./||')
echo "  已备份到: \$BAK"

# 覆盖/新增
find . -type f | sed 's|^\./||' | while IFS= read -r f; do
  mkdir -p "\$V/\$(dirname "\$f")"
  cp -a "\$f" "\$V/\$f"
done

# 在 Rime 用户目录为根级新文件补软链（其余靠原有目录软链自动生效）
for f in lm_rerank.tsv lm_rerank.meta; do
  ln -sfn "\$V/\$f" "\$R/\$f"
done

echo "  覆盖文件数: \$(find . -type f | wc -l)"
echo "  远端仓库改动后: \$(git -C \$V status --short | wc -l) 个改动"
echo "  新增/修改摘要:"
git -C \$V status --short | head -15 | sed 's/^/    /'
REMOTE
rc=$?
rm -rf "$STAGE"
[ $rc -ne 0 ] && { echo "远端安装失败"; exit 1; }

echo
echo "==> 触发重新部署"
$SSH "$HOST" "rime_deployer --build $REMOTE_RIME /usr/share/rime-data $REMOTE_RIME/build 2>&1 | tail -3; echo '  ---'; fcitx5 -r >/dev/null 2>&1 || (pkill -x fcitx5; sleep 2; setsid fcitx5 -d >/dev/null 2>&1); sleep 3; pgrep -x fcitx5 >/dev/null && echo '  fcitx5 已重启'"

echo
echo "==> 完成。建议在 host-linux 上验证："
echo "    e → 有 | jintiandetianqizenmeyang → 今天的天气怎么样 | wojintianmeiyoukong → 我今天没有空"
echo "    回滚: cp -a $REMOTE_REPO/.deploy-backup-$TS/* $REMOTE_REPO/  或  git -C $REMOTE_REPO checkout ."
