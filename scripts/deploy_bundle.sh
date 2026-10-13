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

# 5b) 清单 + 唯一部署引擎进包：目标机用同一套逻辑安装（见 scripts/deploy_runtime.sh）
manifest > "$STAGE/runtime_manifest.txt"
cp -a "$ROOT/scripts/deploy_runtime.sh" "$STAGE/deploy_runtime.sh"
chmod +x "$STAGE/deploy_runtime.sh"

# 6) 安装脚本
cat > "$STAGE/install.sh" <<'INSTALL'
#!/usr/bin/env bash
# 在目标机器上安装 egret-rime 运行时产物
#   bash install.sh [Rime用户目录] [--link] [--download-lm]
# 实际安装逻辑在包内的 deploy_runtime.sh（与仓库 `make deploy` 共用同一份实现）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/deploy_runtime.sh" "$HERE" "$@"
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
