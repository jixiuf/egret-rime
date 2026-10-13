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
  # 引擎 LM 用的词级 gram **不打包**（400MB，用户自行下载，见下方安装提示）：
  #   data/gram/wanxiang-lts-zh-hans.gram  ->  <rime 用户目录>/wanxiang-lts-zh-hans.gram
  # 来源：amzxyz/RIME-LMDG（万象）。缺它时 grammar 加载失败 = 没有 LM，
  # 长句会明显变差（症状见 docs/PROGRESS.md §4.34）。
[ "${1:-}" = "--with-gram" ] && WITH_GRAM=1
LIST_ONLY=0
[ "${1:-}" = "--list" ] && LIST_ONLY=1

# 运行时清单：这是**唯一来源** —— `make deploy`（软链）、`install.sh`（离线包）、
# 以及 `make lint` 的「运行时文件必须入 git」检查都对齐这份清单，避免各自 glob
# 时把中间产物也打进去（曾把 632MB 的
# data/gram/zh-hans-egret.2_6gram.tsv 当运行文件部署出去）。
# 输出格式: 仓库内路径|目标相对路径
manifest() {
  for f in "$ROOT"/*.yaml; do
    b="$(basename "$f")"
    case "$b" in
      user.yaml|installation.yaml) continue ;;   # 用户态/机器态，不覆盖
    esac
    echo "$b|$b"
  done
  for f in "$ROOT"/lua/*.lua; do echo "lua/$(basename "$f")|lua/$(basename "$f")"; done
  for f in "$ROOT"/dicts/*.dict.yaml; do
    echo "dicts/$(basename "$f")|dicts/$(basename "$f")"
  done
  for f in "$ROOT"/opencc/*; do
    [ -e "$f" ] || continue
    echo "opencc/$(basename "$f")|opencc/$(basename "$f")"
  done
  # 运行时二进制/元数据：**优先取 git 跟踪的 dicts/ 副本**（新 clone 也有），
  # 没有才回退到 data/gram/（本地产物目录，不入 git）。此前只从 data/gram/ 取 ⇒
  # 新 clone 打出的包**缺这几个文件**（用户 git clone 后 `make deploy` 就不齐）。
  #   · lm_rerank.meta/.bin：LM 重排表（.tsv 只是给人看的可读视图，不部署）
  #   · compose_table.bin：统一码表搜索器
  #   · py_meta.txt：搜索器的一元归一化常数（total_tokens -> LOG_N）
  # 放 dicts/ 而不是用户目录根：fcitx 每次重启都会跑一遍部署，deployer 会把根下
  # 不认识的 .bin 当无主文件移进 trash/（实测每次重启 lm_rerank.bin 都被移走）。
  for f in lm_rerank.meta lm_rerank.bin compose_table.bin py_meta.txt; do
    if [ -f "$ROOT/dicts/$f" ]; then
      echo "dicts/$f|dicts/$f"
    elif [ -f "$ROOT/data/gram/$f" ]; then
      echo "data/gram/$f|dicts/$f"
    fi
  done
  # installation.yaml **不打**：它是每台机器自己的（install_time/installation_id），
  # librime 会在需要时自行生成；打出去反而会把各机器的 id 覆盖成同一个。
  # 用户态配置（user.yaml / *.custom.yaml 里的自定义）同理不覆盖。
  # 词级 gram（wanxiang-lts-zh-hans.gram, ~400MB）不打包：用户自行下载，
  # 放到 <rime用户目录>/ 下即可。缺它 = 没有语言模型。见 README。
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
DL_LM=0
TARGET=""
for a in "$@"; do
  case "$a" in
    --link) MODE=link ;;
    --download-lm) DL_LM=1 ;;
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
# 防呆：目标就是包目录本身 → 下面的 rm -rf 会把源删掉，再 cp 就没了（踩过：包会自毁）
if [ "$(cd "$TARGET" 2>/dev/null && pwd)" = "$SRC" ]; then
  echo "✗ 目标目录与包目录相同（$SRC）：会先删后拷把自己清空。请换个目标目录。"
  exit 1
fi
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
# ---- 自检（H2）：必需运行时文件 + 引擎 LM ----
# 400MB 的词级 gram **不随包分发**（见上方注释）；缺它 = grammar 加载失败 = 没有语言模型。
echo
miss=0
for f in egret_wubi_py.schema.yaml egret_wubi_py.dict.yaml lua/py_composer.lua \
         dicts/compose_table.bin dicts/lm_rerank.bin dicts/lm_rerank.meta dicts/py_meta.txt; do
  if [ ! -e "$TARGET/$f" ]; then echo "  x 缺必需文件: $f"; miss=1; fi
done
[ "$miss" = 0 ] && echo "  ok 必需运行时文件齐全"
GRAM="wanxiang-lts-zh-hans.gram"
if [ -e "$TARGET/$GRAM" ] || [ -L "$TARGET/$GRAM" ]; then
  echo "  ok 语言模型 $GRAM 已在目标目录"
else
  echo "  !  缺少引擎语言模型（约 400MB，本包不分发）: $TARGET/$GRAM"
  echo "     不装它的后果：grammar 加载失败 -> 没有语言模型，整句准确率明显下降"
  echo "     （实测：万象词级 gram 41~46% vs 无 LM / 字级重排 27%）"
  echo "     获取： curl -fL -C - -o \"$TARGET/$GRAM\" \\
           https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/$GRAM"
  echo "           （或重跑本脚本并加 --download-lm，我来自动下）"
  if [ "$DL_LM" = 1 ]; then
    echo "  --> --download-lm：开始下载 $GRAM（~400MB，断点续传）"
    curl -fL --retry 3 -C - -o "$TARGET/$GRAM.part" \
      "https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/$GRAM" \
      && mv -f "$TARGET/$GRAM.part" "$TARGET/$GRAM" && echo "  ok 语言模型已就位" \
      || { echo "  !  下载失败（网络受限可先在别处下好再拷进来）"; rm -f "$TARGET/$GRAM.part"; }
  fi
fi
echo
# ---- 首次安装：把 previously_selected_schema 指到本方案 ----
# 交付包里的 default.custom.yaml 是**用户配置**（`schema_list/+:` 追加语义，不动用户
# 已有方案列表），而 librime 只看列表首个可用方案（共享数据里有 luna_pinyin）⇒ 首次
# 安装要让本方案成为默认，就在 user.yaml 里 pin 一行（F4 菜单随时可换，见 §4.78）。
UY="$TARGET/user.yaml"
if [ -e "$UY" ] && grep -qE "^[[:space:]]*previously_selected_schema:" "$UY"; then
  if grep -qE "^[[:space:]]*previously_selected_schema:[[:space:]]*egret_wubi_py[[:space:]]*$" "$UY"; then
    echo "  ok 默认方案已是 egret_wubi_py（user.yaml）"
  else
    sed -i.egretbak -E "s/^([[:space:]]*previously_selected_schema:).*/\1 egret_wubi_py/" "$UY" \
      && rm -f "$UY.egretbak" && echo "  ok 默认方案已改成 egret_wubi_py（user.yaml）"
  fi
elif [ -e "$UY" ] && grep -qE "^var:[[:space:]]*$" "$UY"; then
  awk '/^var:[[:space:]]*$/{print; print "  previously_selected_schema: egret_wubi_py"; next} {print}' \
    "$UY" > "$UY.tmp" && mv -f "$UY.tmp" "$UY" \
    && echo "  ok 默认方案写入 egret_wubi_py（user.yaml）"
else
  printf 'var:\n  previously_selected_schema: egret_wubi_py\n' >> "$UY" \
    && echo "  ok 默认方案写入 egret_wubi_py（user.yaml）"
fi

echo "安装完成。接下来："
case "$(uname -s)" in
  Darwin) echo "  1) 点菜单栏 Squirrel 图标 → 重新部署（或 \"/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer\" --build \"$TARGET\"）"
          echo "  2) 若在系统里还没加过输入法：系统设置 → 键盘 → 输入法 → 添加「白鹭五笔·拼音流」" ;;
  *)      echo "  1) 重新部署 Rime（fcitx5: 右键托盘图标 → 重新部署；ibus: ibus-daemon -drx）" ;;
esac
echo "  验证：输入 e → 应出「有」；输入 jintiandetianqizenmeyang → 应出「今天的天气怎么样」"
echo
echo "切换词库档位：编辑 $TARGET/egret_wubi_py.dict.yaml 里的 import_tables"
echo "  （core / base / full 三档，见产物包内 dicts/*_words_*.dict.yaml）"
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
- 语言模型：默认用 librime 原生 grammar + **万象词级 gram**
  （把 wanxiang-lts-zh-hans.gram 放到 Rime 用户目录；约 400MB，**不随包分发**，
  见文末「语言模型」）。包内另带 lm_rerank.bin（搜索器内部打分用）。
- 用户词典：三个 user_dict 均为 db_class: tabledb（纯文本），落在 Rime 用户目录根的
  egret_wubi.user.dict.txt / egret_wubi_py_script.user.dict.txt / egret_wubi_py.user.dict.txt。
  调频/自学习/造词都生效；可直接看/改/git 管理。
- 词库三档：core(≈2万词) / base(≈6.3万词) / full(≈78万词)，
  改 egret_wubi_py.dict.yaml 的 import_tables 即可切换。
- 简繁：方案已有 switches(traditionalization) + opencc s2t，运行时切换。
- 开关：egret_wubi_py.schema.yaml 里 dynamic_translator/lm_rerank（搜索器 Lua 重排，
  默认 false —— LM 走原生 grammar；lm_compose_* 为搜索器实验开关）

语言模型（必需）
----------------
把 wanxiang-lts-zh-hans.gram 放进 Rime 用户目录（与 *.yaml 同级）。
缺它 = 没有语言模型（整句准确率大幅下降）。
下载：wget -c https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram
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
