#!/usr/bin/env bash
# ============================================================================
# 打一个自包含的「运行时部署包」，拷到目标机器后一条命令装好
# ============================================================================
# 为什么需要：开发机（Linux）与使用机（如 macOS host-linux）之间可能没有直连，
# 不可能 rsync/scp；打成一个 tar.gz 后走微信/网盘/U 盘都行。
#
# 用法（开发机）:
#   bash scripts/deploy_bundle.sh                 # 产出 dist/egret-rime-runtime-<日期>.tar.gz
#   bash scripts/deploy_bundle.sh --with-gram     # 额外带上 librime 的 .gram（默认不带）
#
# 用法（目标机，解开后）:
#   tar xzf egret-rime-runtime-*.tar.gz && cd egret-rime-runtime-*
#   bash install.sh                # macOS 默认装到 ~/Library/Rime
#   bash install.sh <目录>          # 或指定 Rime 用户目录
#   bash install.sh --link <目录>   # 软链而非拷贝（便于后续更新）
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
STAMP="$(date +%Y%m%d)"
NAME="egret-rime-runtime-$STAMP"
STAGE="$DIST/$NAME"
WITH_GRAM=0
[ "${1:-}" = "--with-gram" ] && WITH_GRAM=1
LIST_ONLY=0
[ "${1:-}" = "--list" ] && LIST_ONLY=1

# 运行时清单：这是**唯一来源**，deploy_host-linux_direct.sh / deploy_host-mac.sh 都从
# 这里取，避免各自 glob 时把中间产物也打进去（曾把 632MB 的
# data/gram/zh-hans-egret.2_6gram.tsv 当运行文件部署出去）。
# 输出格式: 仓库内路径|目标相对路径
manifest() {
  for f in "$ROOT"/*.yaml; do
    b="$(basename "$f")"; [ "$b" = user.yaml ] && continue   # 用户态，不覆盖
    echo "$b|$b"
  done
  for f in "$ROOT"/lua/*.lua; do echo "lua/$(basename "$f")|lua/$(basename "$f")"; done
  for f in "$ROOT"/dicts/egret_wubi_py/*.dict.yaml; do
    echo "dicts/egret_wubi_py/$(basename "$f")|dicts/egret_wubi_py/$(basename "$f")"
  done
  for f in "$ROOT"/opencc/*; do
    [ -e "$f" ] || continue
    echo "opencc/$(basename "$f")|opencc/$(basename "$f")"
  done
  # LM 重排的运行时文件：.bin（二分查表用）+ .meta（总字数，backoff 归一化用）。
  # .tsv 只是同一份数据的可读视图，给人排查用，不部署。
  [ -f "$ROOT/data/gram/lm_rerank.meta" ] && echo "data/gram/lm_rerank.meta|lm_rerank.meta"
  [ -f "$ROOT/data/gram/lm_rerank.bin" ]  && echo "data/gram/lm_rerank.bin|lm_rerank.bin"
  [ "$WITH_GRAM" = 1 ] && [ -f "$ROOT/data/gram/zh-hans-egret.gram" ] \
    && echo "data/gram/zh-hans-egret.gram|zh-hans-egret.gram"
  return 0
}

if [ "$LIST_ONLY" = 1 ]; then manifest; exit 0; fi

mkdir -p "$STAGE"
rm -rf "$STAGE"/*

echo "==> 收集运行时产物（清单见 manifest()，与部署脚本共用）"
while IFS='|' read -r src dst; do
  [ -n "$src" ] || continue
  mkdir -p "$STAGE/$(dirname "$dst")"
  cp -a "$ROOT/$src" "$STAGE/$dst" || echo "  ! 拷贝失败: $src"
done < <(manifest)
[ -f "$ROOT/data/gram/lm_rerank.bin" ] || echo "  ! 缺少 data/gram/lm_rerank.bin（先跑 scripts/gen_lm_rerank.py）"

# 6) 安装脚本
cat > "$STAGE/install.sh" <<'INSTALL'
#!/usr/bin/env bash
# 在目标机器上安装 egret-rime 运行时产物
#   bash install.sh [Rime用户目录] [--link]
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=copy
TARGET=""
for a in "$@"; do
  case "$a" in
    --link) MODE=link ;;
    *) TARGET="$a" ;;
  esac
done
if [ -z "$TARGET" ]; then
  case "$(uname -s)" in
    Darwin) TARGET="$HOME/Library/Rime" ;;
    *)      TARGET="$HOME/.local/share/fcitx5/rime" ;;
  esac
fi

echo "源:   $SRC"
echo "目标: $TARGET  (模式: $MODE)"
mkdir -p "$TARGET"
BAK="$TARGET/.egret-backup-$(date +%Y%m%d-%H%M%S)"
NEED_BAK=0
# 按 $SRC 里实际有的东西遍历（包内就是完整运行时清单，别再手写文件名）
for f in "$SRC"/*; do
  b="$(basename "$f")"
  if [ -e "$TARGET/$b" ] || [ -L "$TARGET/$b" ]; then NEED_BAK=1; fi
done
if [ "$NEED_BAK" = 1 ]; then
  mkdir -p "$BAK"
  for f in "$SRC"/*; do
    b="$(basename "$f")"
    if [ -e "$TARGET/$b" ] || [ -L "$TARGET/$b" ]; then
      cp -a "$TARGET/$b" "$BAK/" 2>/dev/null || true
    fi
  done
  echo "已备份原文件到: $BAK"
  echo "  （回滚：把 $BAK/ 里的东西拷回 $TARGET/）"
fi

for f in "$SRC"/*; do
  b="$(basename "$f")"
  rm -rf "$TARGET/$b"
  if [ "$MODE" = link ]; then ln -sfn "$SRC/$b" "$TARGET/$b"
  else cp -a "$SRC/$b" "$TARGET/"; fi
done

echo
echo "安装完成。接下来："
case "$(uname -s)" in
  Darwin) echo "  1) 点菜单栏 Squirrel 图标 → 重新部署（或 \"/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer\" --build \"$TARGET\"）"
          echo "  2) 若在系统里还没加过输入法：系统设置 → 键盘 → 输入法 → 添加「白鹭五笔·拼音流」" ;;
  *)      echo "  1) 重新部署 Rime（fcitx5: 右键托盘图标 → 重新部署；ibus: ibus-daemon -drx）" ;;
esac
echo "  验证：输入 e → 应出「有」；输入 jintiandetianqizenmeyang → 应出「今天的天气怎么样」"
echo
echo "切换词库档位：编辑 $TARGET/egret_wubi_py.dict.yaml 里的 import_tables"
echo "  （core / base / full 三档，见产物包内 dicts/egret_wubi_py/*_words_*.dict.yaml）"
INSTALL
chmod +x "$STAGE/install.sh"

# 7) 附一份说明
cat > "$STAGE/README-部署.txt" <<'EOF'
egret-rime 运行时部署包
========================
内容：方案配置(*.yaml) + 词库(dicts/egret_wubi_py) + lua 脚本 + opencc + LM 重排表

安装：
  tar xzf egret-rime-runtime-*.tar.gz
  cd egret-rime-runtime-*
  bash install.sh                 # macOS 默认 ~/Library/Rime
  bash install.sh /path/to/Rime   # 指定目录
  bash install.sh --link ~/Library/Rime   # 软链模式（改本包即可生效）

说明：
- LM（语言模型）已改为「纯 Lua 重排」：librime 只按词库权重分词，
  LM 用 lm_rerank.bin（定长记录 + 二分查表）对整句候选重排。因此**不需要** librime 的 .gram，
  也不需要给 librime 打任何补丁。
- 词库三档：core(≈2万词) / base(≈6.3万词) / full(≈78万词)，
  改 egret_wubi_py.dict.yaml 的 import_tables 即可切换。
- 简繁：方案已有 switches(traditionalization) + opencc s2t，运行时切换。
- 开关：egret_wubi_py.schema.yaml 里 dynamic_translator/lm_rerank: true|false
  （false 则回到 librime 自己的 grammar，需要 .gram 文件）
EOF

cd "$DIST"
TAR="$NAME.tar.gz"
tar czf "$TAR" "$NAME"
SIZE=$(du -h "$TAR" | cut -f1)
echo
echo "==> 产出: $DIST/$TAR  ($SIZE)"
echo "    内容: $(du -sh "$STAGE" | cut -f1) 未压缩"
echo
echo "拷到目标机后："
echo "  tar xzf $TAR && cd $NAME && bash install.sh"
