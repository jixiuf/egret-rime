#!/usr/bin/env bash
# ============================================================================
# 目标机：让 `make deploy` 落地的文件在输入法里生效（重建 Rime build + 重启输入法）
# ============================================================================
# 推荐的目标机流程（开发机只 push，目标机自己 pull）：
#
#   cd ~/repos/egret-rime && git pull --ff-only
#   make deploy        # 软链/拷贝运行时文件到输入法用户目录
#   make reload        # 本脚本：重建 build 并重启输入法
#
# 平台差异：
#   Linux + fcitx5   ：rime_deployer --build <用户目录> <共享数据> <用户目录>/build，
#                      然后重启 fcitx5（fcitx5 -r 或 kill+重启）—— 默认重启，--no-restart 可只重建
#   macOS + Squirrel ：用 Squirrel 自带的 rime_deployer + SharedSupport 重建；
#                      重启默认不做（Squirrel 菜单「重新部署」即可），--restart 才 killall+open
#
# 用法:
#   bash scripts/reload_ime.sh [用户目录] [--no-restart|--restart]
#   TARGET=~/Library/Rime make reload
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNAME="$(uname)"

# --- 参数 ---------------------------------------------------------------
TARGET=""
RESTART=""
for arg in "$@"; do
  case "$arg" in
    --no-restart) RESTART=0 ;;
    --restart)    RESTART=1 ;;
    -*)           echo "未知参数: $arg"; exit 1 ;;
    *)            TARGET="$arg" ;;
  esac
done
if [ -z "$TARGET" ]; then
  if [ -n "${TARGET_DIR:-}" ]; then
    TARGET="$TARGET_DIR"
  elif [ "$UNAME" = "Darwin" ]; then
    TARGET="$HOME/Library/Rime"
  else
    TARGET="$HOME/.local/share/fcitx5/rime"
  fi
fi
TARGET="${TARGET%/}"
[ -d "$TARGET" ] || { echo "✗ 用户目录不存在：$TARGET（先跑 make deploy）"; exit 1; }

# --- 找 rime_deployer 与共享数据 ----------------------------------------
if [ "$UNAME" = "Darwin" ]; then
  SQUIRREL="/Library/Input Methods/Squirrel.app"
  SHARED="$SQUIRREL/Contents/SharedSupport"
  DEPLOYER="$(command -v rime_deployer || true)"
  [ -x "$DEPLOYER" ] || DEPLOYER="$SQUIRREL/Contents/MacOS/rime_deployer"
  [ -z "${RESTART}" ] && RESTART=0
else
  DEPLOYER="$(command -v rime_deployer || true)"
  [ -x "$DEPLOYER" ] || DEPLOYER="$ROOT/third-party/librime/build/bin/rime_deployer"
  SHARED=""
  for d in /usr/share/rime-data /usr/share/fcitx5/rime-data "$ROOT/data/rime-shared"; do
    [ -f "$d/symbols.yaml" ] && { SHARED="$d"; break; }
  done
  [ -z "${RESTART}" ] && RESTART=1
fi

echo "==> 用户目录: $TARGET"
echo "    deployer: ${DEPLOYER:-（未找到）}"
echo "    共享数据: ${SHARED:-（未找到，按用户目录自包含处理）}"

if [ -x "$DEPLOYER" ]; then
  echo "==> rime_deployer --build"
  if [ -n "$SHARED" ]; then
    "$DEPLOYER" --build "$TARGET" "$SHARED" "$TARGET/build" 2>&1 | grep -icE "error" \
      | sed 's/^/    error 行数: /'
  else
    "$DEPLOYER" --build "$TARGET" "$TARGET/build" 2>&1 | grep -icE "error" \
      | sed 's/^/    error 行数: /'
  fi
else
  echo "    ! 没找到 rime_deployer；跳过重建（输入法自己的「重新部署」也能完成）"
fi

# --- 重建可能把「运行时才读、schema 没引用」的表挪进 trash/ --------------
# TARGET/dicts 通常软链到仓库 dicts/：deployer 若把它们挪走，动的是仓库里的实体文件
# ⇒ 这里从 trash/ 挪回来（历史上 lm_rerank.bin/.meta 中过招）。
# 名字**不再硬编码**：清单里 dicts/ 下的运行时表就是「可能被挪」的集合（清单唯一来源）。
MANIFEST_LIST="$ROOT/scripts/deploy_bundle.sh"
if [ -f "$MANIFEST_LIST" ]; then
  while IFS='|' read -r _src dst; do
    case "${dst:-}" in
      dicts/*)
        f="$(basename "$dst")"
        if [ ! -e "$TARGET/dicts/$f" ] && [ -e "$TARGET/trash/$f" ]; then
          mkdir -p "$TARGET/dicts"
          mv -f "$TARGET/trash/$f" "$TARGET/dicts/$f" && echo "    已从 trash/ 挪回 dicts/$f"
        fi ;;
    esac
  done < <(bash "$MANIFEST_LIST" --list 2>/dev/null)
fi

# --- 重启输入法 ---------------------------------------------------------
if [ "$UNAME" = "Darwin" ]; then
  if [ "$RESTART" = 1 ]; then
    echo "==> 重启 Squirrel"
    killall Squirrel 2>/dev/null; sleep 2; open -a Squirrel 2>/dev/null
    sleep 3
    pgrep -x Squirrel >/dev/null && echo "    Squirrel 已重启" || echo "    ! Squirrel 未起来，请手动打开"
  else
    echo "==> 文件已就位：Squirrel 菜单栏图标 →「重新部署」即可生效（或 --restart 立即重启）"
  fi
else
  if [ "$RESTART" = 1 ]; then
    if command -v fcitx5 >/dev/null || pgrep -x fcitx5 >/dev/null; then
      echo "==> 重启 fcitx5"
      pkill -x fcitx5 2>/dev/null; sleep 2
      setsid fcitx5 -d </dev/null >/dev/null 2>&1
      sleep 4
      pgrep -x fcitx5 >/dev/null && echo "    fcitx5 已重启 (pid $(pgrep -x fcitx5))" \
        || echo "    ! fcitx5 未起来（桌面会话里手动启动一次即可）"
    else
      echo "==> 未检测到 fcitx5 进程/命令：跳过重启（请用你的输入法「重新部署」）"
    fi
  fi
fi

echo
echo "==> 完成。建议验证：e → 有 ｜ jintiandetianqizenmeyang → 今天的天气怎么样 ｜ kkkk → 口"
