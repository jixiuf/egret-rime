#!/usr/bin/env bash
# ============================================================================
# 一键部署到远程 Rime 机器（默认 host-linux: ssh -p 8093 jixiuf@localhost）
# ============================================================================
# 从本机（开发机）打包 → scp 过去 → 远端解包安装 → 探测环境并提示重新部署。
#
# 用法:
#   bash scripts/deploy_remote.sh                          # 默认 jixiuf@localhost:8093
#   bash scripts/deploy_remote.sh jixiuf@localhost 8093
#   bash scripts/deploy_remote.sh --target ~/.local/share/fcitx5/rime
#   bash scripts/deploy_remote.sh --probe                  # 只看远端环境，不部署
#
# 注意：需要你本地有可用的 ssh 认证（密钥或密码交互）。
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="jixiuf@localhost"
PORT="8093"
TARGET_ARG=""
PROBE_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --probe) PROBE_ONLY=1; shift ;;
    --target) TARGET_ARG="$2"; shift 2 ;;
    -*)
      echo "未知参数: $1"; exit 1 ;;
    *)
      if [ "$HOST" = "jixiuf@localhost" ]; then HOST="$1"; else PORT="$1"; fi
      shift ;;
  esac
done

SSH="ssh -p $PORT -o StrictHostKeyChecking=accept-new"

echo "==> 远端环境探测 ($HOST:$PORT)"
$SSH "$HOST" 'bash -s' <<'PROBE' || { echo "  ! ssh 失败（检查密钥/密码）"; exit 1; }
echo "  主机: $(hostname)  ($(uname -srm))"
[ -f /etc/os-release ] && echo "  发行版: $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "  输入法进程:"
pgrep -a fcitx5 2>/dev/null | head -2 | sed 's/^/    /'
pgrep -a ibus-daemon 2>/dev/null | head -2 | sed 's/^/    /'
pgrep -a fcitx 2>/dev/null | head -2 | sed 's/^/    /'
echo "  Rime 用户目录:"
for d in "$HOME/.local/share/fcitx5/rime" "$HOME/.config/ibus/rime" \
         "$HOME/.local/share/fcitx/rime" "$HOME/.config/fcitx/rime" "$HOME/.config/rime"; do
  [ -d "$d" ] && echo "    存在 $d  ($(ls "$d" 2>/dev/null | wc -l) 项)"
done
echo "  共享数据目录:"
for d in /usr/share/rime-data /usr/share/fcitx5/rime-data; do
  [ -d "$d" ] && echo "    存在 $d"
done
echo "  librime / 部署工具:"
command -v rime_deployer 2>/dev/null | sed 's/^/    /'
ls -d "$HOME/repos/librime/build/bin" 2>/dev/null | sed 's/^/    /'
PROBE

[ "$PROBE_ONLY" = 1 ] && exit 0

echo
echo "==> 打运行时包（本地）"
bash "$ROOT/scripts/deploy_bundle.sh" | tail -3 || exit 1
TARBALL=$(ls -t "$ROOT"/dist/egret-rime-runtime-*.tar.gz | head -1)
echo "  $TARBALL"

echo
echo "==> 传到远端 /tmp/"
scp -P "$PORT" "$TARBALL" "$HOST:/tmp/" || exit 1
BASE=$(basename "$TARBALL" .tar.gz)

echo
echo "==> 远端解包 + 安装"
$SSH "$HOST" "set -e
  cd /tmp && rm -rf $BASE && tar xzf $BASE.tar.gz && cd $BASE
  if [ -n '$TARGET_ARG' ]; then bash install.sh $TARGET_ARG; else bash install.sh; fi" || exit 1

echo
echo "==> 完成。远端重新部署 Rime 即可生效："
echo "    fcitx5: 右键托盘图标 → 重新部署（或 killall fcitx5 && fcitx5 -d）"
echo "    ibus  : ibus-daemon -drx"
echo "    Squirrel(macOS): 菜单栏图标 → 重新部署"
echo
echo "  验证: 在远端输入 e → 应出「有」；jintiandetianqizenmeyang → 应出「今天的天气怎么样」"
