#!/usr/bin/env bash
# ============================================================================
# 唯一的「运行时落地」引擎：按清单把运行时文件装进 Rime 用户目录
# ============================================================================
# 两个调用方（此前各写一套，现收敛到这里，见 docs/PROGRESS.md §4.79）：
#
#   make deploy            → 源=仓库工作区，--link（软链；git pull 后立刻生效）
#   交付包里的 install.sh  → 源=解包目录，--copy（默认，实体拷贝）或 --link
#
# 清单唯一来源：
#   · 仓库内：<src>/scripts/deploy_bundle.sh --list   （格式：仓库内路径|目标相对路径）
#   · 包内  ：<src>/runtime_manifest.txt              （打包时由 deploy_bundle.sh 生成）
#
# 本引擎负责（都是「一处实现、两条路径共用」）：
#   · 清单 → 安装（目录整目录 link / 逐文件 copy）
#   · 用户态/机器态文件不覆盖（user.yaml、default.custom.yaml、installation.yaml）
#   · 首次安装把 previously_selected_schema 指到本方案（默认方案）
#   · 400MB 语言模型：目标侧已有就不动，缺失则提示（--download-lm 则自动下）
#   · copy 模式先整目录备份（<target>/.egret-backup-<时间戳>/）
#   · 装完自检：清单里每条都能在目标目录里找到
#
# 用法:
#   bash scripts/deploy_runtime.sh <src_root> <target_dir> [--link|--copy] [--download-lm]
# TARGET 省略时按平台默认（Linux: ~/.local/share/fcitx5/rime；macOS: ~/Library/Rime）
# ============================================================================
set -uo pipefail

SRC="${1:-}"; TARGET="${2:-}"
MODE=copy; DL_LM=0
for a in "$@"; do
  case "$a" in
    --link)        MODE=link ;;
    --copy)        MODE=copy ;;
    --download-lm) DL_LM=1 ;;
  esac
done
[ -n "$SRC" ] || { echo "用法: bash deploy_runtime.sh <src_root> <target_dir> [--link|--copy]"; exit 2; }
SRC="$(cd "$SRC" && pwd)"
if [ -z "$TARGET" ]; then
  case "$(uname -s)" in
    Darwin) TARGET="$HOME/Library/Rime" ;;
    *)      TARGET="$HOME/.local/share/fcitx5/rime" ;;
  esac
fi
TARGET="${TARGET%/}"

# --- 防呆：源=目标（拷贝模式会先删后拷，把自己清空。踩过：包会自毁）----------
mkdir -p "$TARGET"
if [ "$(cd "$TARGET" && pwd)" = "$SRC" ]; then
  echo "✗ 目标目录与源目录相同（$SRC）：先删后拷会把源清空，请换目标目录。" >&2
  exit 1
fi

# --- 清单 -------------------------------------------------------------------
MANIFEST="$(mktemp)"; trap 'rm -f "$MANIFEST"' EXIT
if [ -f "$SRC/runtime_manifest.txt" ]; then
  cat "$SRC/runtime_manifest.txt" > "$MANIFEST"
elif [ -x "$SRC/scripts/deploy_bundle.sh" ] || [ -f "$SRC/scripts/deploy_bundle.sh" ]; then
  bash "$SRC/scripts/deploy_bundle.sh" --list > "$MANIFEST"
else
  echo "✗ 找不到运行时清单（$SRC/runtime_manifest.txt 或 scripts/deploy_bundle.sh）" >&2
  exit 1
fi
grep -v '^[[:space:]]*$' "$MANIFEST" > "$MANIFEST.clean" && mv "$MANIFEST.clean" "$MANIFEST"

echo "源:     $SRC"
echo "目标:   $TARGET  (模式: $MODE)"
echo "清单:   $(wc -l < "$MANIFEST") 项"

# 用户态/机器态：**绝不覆盖**（Rime 会回写；installation.yaml 是每台机器自己的）
# 缺失时补一份默认的 user.yaml / default.custom.yaml，保证方案能被选中。
USER_STATE_RE='^(user\.yaml|default\.custom\.yaml|installation\.yaml)$'

# --- 分类：目录（整目录处理）vs 根级文件 ------------------------------------
# 注意：macOS 自带的是 bash 3.2，**没有关联数组**（declare -A 会直接报错退出，
# 曾经导致目标机 `make deploy` 整条失败、新运行时文件从不落地 —— 见 §4.84）。
# 这里只用普通数组 + 去重函数。
DIR_LIST=""
ROOT_FILES=()
add_dir() {
  case " $DIR_LIST " in *" $1 "*) return 0 ;; esac
  DIR_LIST="$DIR_LIST $1"
}
while IFS='|' read -r src dst; do
  [ -n "${src:-}" ] || continue
  case "$dst" in
    */*) add_dir "${dst%%/*}" ;;
    *)   ROOT_FILES[${#ROOT_FILES[@]}]="$dst" ;;
  esac
done < "$MANIFEST"

# --- link 模式：相对软链（基准一律用**物理目录** realpath，父目录含软链时才不会建断链）--
rel_link() {  # rel_link <目标路径> <源路径>
  local link="$1" target="$2" base rel
  mkdir -p "$(dirname "$link")"
  if [ -L "$link" ] || [ -f "$link" ]; then
    rm -f "$link"
  elif [ -d "$link" ]; then
    # 目标是实体目录（历史部署留下的）→ 改名备份，可回滚
    local bak="$link.bak-$(date +%Y%m%d-%H%M%S)"
    while [ -e "$bak" ]; do bak="$bak.1"; done
    mv "$link" "$bak"
    echo "  ⚠ $(basename "$link") 是实体目录，已备份为 $(basename "$bak")"
  fi
  base="$(cd "$(dirname "$link")" && pwd -P)"
  if rel="$(realpath --relative-to="$base" "$target" 2>/dev/null)"; then
    ln -s "$rel" "$link"
  else
    ln -s "$target" "$link"      # 老 coreutils 不支持 --relative-to：退回绝对链
  fi
}

# --- copy 模式：先备份（整目录里受影响的那几个）-----------------------------
if [ "$MODE" = copy ]; then
  BAK="$TARGET/.egret-backup-$(date +%Y%m%d-%H%M%S)"
  need=0
  for d in $DIR_LIST; do [ -e "$TARGET/$d" ] && need=1; done
  for f in "${ROOT_FILES[@]}"; do [ -e "$TARGET/$f" ] && need=1; done
  if [ "$need" = 1 ]; then
    mkdir -p "$BAK"
    for d in $DIR_LIST; do
      [ -e "$TARGET/$d" ] && cp -a "$TARGET/$d" "$BAK/" 2>/dev/null || true
    done
    for f in "${ROOT_FILES[@]}"; do
      [ -e "$TARGET/$f" ] && { mkdir -p "$BAK/$(dirname "$f")"; cp -a "$TARGET/$f" "$BAK/$f"; } || true
    done
    echo "已备份原有文件到: $BAK"
  fi
fi

# --- 安装 -------------------------------------------------------------------
for d in $DIR_LIST; do
  if [ "$MODE" = link ]; then
    rel_link "$TARGET/$d" "$SRC/$d"
  else
    rm -rf "$TARGET/$d"; mkdir -p "$TARGET/$d"
    while IFS='|' read -r src dst; do
      case "$dst" in "$d"/*) mkdir -p "$TARGET/$(dirname "$dst")"; cp -a "$SRC/$src" "$TARGET/$dst" ;; esac
    done < "$MANIFEST"
  fi
done

for f in "${ROOT_FILES[@]}"; do
  b="$(basename "$f")"
  if [[ "$b" =~ $USER_STATE_RE ]]; then
    continue                                   # 用户态/机器态：不覆盖
  fi
  if [ "$MODE" = link ]; then
    rel_link "$TARGET/$f" "$SRC/$f"
  else
    rm -f "$TARGET/$f"; mkdir -p "$TARGET/$(dirname "$f")"; cp -a "$SRC/$f" "$TARGET/$f"
  fi
done

# 用户态文件：缺失才补（不覆盖用户已有内容）
for f in user.yaml default.custom.yaml; do
  if [ ! -e "$TARGET/$f" ] && [ -e "$SRC/$f" ]; then
    cp -a "$SRC/$f" "$TARGET/$f"; echo "  (首次安装) 补上 $f"
  fi
done

# --- 首次安装：默认方案 pin 到本方案（真实输入法按 user.yaml 恢复）----------
# 用户配置 default.custom.yaml 是「追加」语义（不动用户已有方案列表），而列表里本方案
# 排在共享数据的 luna_pinyin 之后 ⇒ 首次安装靠这一行让输入法直接进本方案（F4 可换）。
pin_schema() {
  local uy="$TARGET/user.yaml" schema="egret_wubi_py" ours="egret_wubi_py|egret_wubi|egret_py"
  if [ -e "$uy" ] && grep -qE "^[[:space:]]*previously_selected_schema:" "$uy"; then
    grep -qE "^[[:space:]]*previously_selected_schema:[[:space:]]*($ours)[[:space:]]*$" "$uy" \
      && return 0
    sed -i.egretbak -E "s/^([[:space:]]*previously_selected_schema:).*/\1 $schema/" "$uy" \
      && rm -f "$uy.egretbak" && echo "  默认方案已改成 $schema（user.yaml；F4 菜单可换）"
  elif [ -e "$uy" ] && grep -qE "^var:[[:space:]]*$" "$uy"; then
    awk -v s="  previously_selected_schema: $schema" \
      '/^var:[[:space:]]*$/{print; print s; next} {print}' "$uy" > "$uy.tmp" \
      && mv -f "$uy.tmp" "$uy" && echo "  默认方案写入 $schema（user.yaml）"
  else
    printf 'var:\n  previously_selected_schema: %s\n' "$schema" >> "$uy" \
      && echo "  默认方案写入 $schema（user.yaml）"
  fi
}
pin_schema

# --- 400MB 语言模型：不随仓库/包分发，但不装它长句明显变差 -------------------
GRAM="wanxiang-lts-zh-hans.gram"
GRAM_URL="https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/$GRAM"
if [ -e "$TARGET/$GRAM" ] || [ -L "$TARGET/$GRAM" ]; then
  echo "语言模型: 已就位（$GRAM）"
elif [ -f "$SRC/data/gram/$GRAM" ]; then          # 仓库里已下载过
  if [ "$MODE" = link ]; then rel_link "$TARGET/$GRAM" "$SRC/data/gram/$GRAM"
  else cp -a "$SRC/data/gram/$GRAM" "$TARGET/$GRAM"; fi
  echo "语言模型: 已安装（$GRAM）"
else
  echo "语言模型: ⚠ 缺失（约 400MB，不随仓库/包分发）——缺它长句准确率明显下降"
  echo "          获取: curl -fL -C - -o \"$TARGET/$GRAM\" $GRAM_URL"
  if [ "$DL_LM" = 1 ]; then
    echo "          --download-lm：开始下载…"
    curl -fL --retry 3 -C - -o "$TARGET/$GRAM.part" "$GRAM_URL" \
      && mv -f "$TARGET/$GRAM.part" "$TARGET/$GRAM" && echo "          已下载完成" \
      || { echo "          下载失败（网络受限可先在别处下好再拷进来）"; rm -f "$TARGET/$GRAM.part"; }
  fi
fi

# --- 自检：清单里每条都要能在目标目录找到（不再硬编码文件名）----------------
miss=0
while IFS='|' read -r src dst; do
  [ -n "${src:-}" ] || continue
  [ -e "$TARGET/$dst" ] || { echo "  ✗ 缺 $dst"; miss=1; }
done < "$MANIFEST"
[ "$miss" = 0 ] && echo "自检: 清单 $(wc -l < "$MANIFEST") 项全部就位 ✓" || echo "自检: ✗ 有缺失"

echo
echo "下一步：让改动生效（重建 Rime build + 重启输入法）"
echo "  仓库方式 : make reload        （或 make reload NO_RESTART=1 只重建）"
echo "  离线包方式: Squirrel 菜单「重新部署」；fcitx5 托盘右键「重新部署」"
echo "验证：e → 有 ｜ jintiandetianqizenmeyang → 今天的天气怎么样 ｜ kkkk → 口"
[ "$miss" = 0 ] || exit 1
