#!/usr/bin/env bash
# egret-rime 环境一键搭建（Linux 自包含环境）
# ============================================================================
# 所有路径以本仓库根为基准，外部依赖落在 third-party/，语料/数据落在 data/。
# 幂等：已存在且 commit 匹配的仓库会跳过；未匹配的不会覆盖（需手动处理）。
#
# 用法:
#   bash scripts/setup_env.sh              # 全量：依赖 + 克隆 + 构建 + 自检
#   bash scripts/setup_env.sh clone        # 只克隆/校验第三方仓库
#   bash scripts/setup_env.sh build        # 只构建 glog/librime/kenlm
#   bash scripts/setup_env.sh python       # 只建 python venv 与依赖
#   bash scripts/setup_env.sh gram         # 只下载 gram
#   bash scripts/setup_env.sh check        # 只跑自检
#
# 环境变量:
#   USE_PROXY=off   禁用 proxychains（GitHub 可直连时）
#   GCC_TOOLSET     工具链 bin 目录（默认 /opt/rh/gcc-toolset-12/root/usr/bin）
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD="$ROOT/third-party"
PREFIX="$THIRD/prefix"
DATA="$ROOT/data"
LOGS="$DATA/corpus/log"
VENV="$THIRD/venv"
GCC_TOOLSET="${GCC_TOOLSET:-/opt/rh/gcc-toolset-12/root/usr/bin}"
RPATH_FLAG="-Wl,-rpath,$(dirname "$GCC_TOOLSET")/lib64"

mkdir -p "$THIRD" "$DATA" "$LOGS"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '    \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }

# --- 第三方仓库清单: 目录名 | git 地址 | 锁定 commit | 说明 --------------------
# commit 为 clone 时经三通道(直连 API / socks 代理 / gh-proxy)交叉校验后的值;
# clone 后逐一比对, 不一致即失败（git 对象内容寻址, 可发现内容被篡改）。
REPOS=(
  "librime|https://github.com/rime/librime.git|33e78140250125871856cdc5b42ddc6a5fcd3cd4|tag 1.17.0"
  "librime-octagram|https://github.com/lotem/librime-octagram.git|57d18b9f58e5284bd891d559f6bdd16cf60341e9|octagram 语法/LM 插件"
  "librime-lua|https://github.com/hchunhui/librime-lua.git|ad1e4a6c98abf634dd34242a747f9b1d5d069fbe|lua 组件（方案核心）"
  "glog|https://github.com/google/glog.git|b33e3bad4c46c8a6345525fd822af355e5ef9446|v0.6.0 日志（RHEL8 自带 0.3.5 过旧）"
  "kenlm|https://github.com/kpu/kenlm.git|4cb443e60b7bf2c0ddf3c745378f76cb59e254e5|n-gram 训练"
  "rime-build-grammar|https://github.com/gaboolic/rime-build-grammar.git|fda2036f0ea7579dde63753d16c460657282caad|gram 训练管线脚本"
  "rime-corpus-processing|https://github.com/JACKCHAN000/rime-corpus-processing.git|ea937a5f47d4afb9d80a4f00baf465d8dfa98980|字符 2-6gram 统计 / 词频重扫"
)

USE_PROXY="${USE_PROXY:-auto}"
git_clone() {
  if [ "$USE_PROXY" != "off" ] && command -v proxychains4 >/dev/null 2>&1; then
    proxychains4 -q git clone "$@"
  else
    git clone "$@"
  fi
}

do_clone() {
  log "克隆/校验第三方仓库 -> $THIRD"
  for row in "${REPOS[@]}"; do
    IFS='|' read -r name url pin note <<<"$row"
    dir="$THIRD/$name"
    if [ -d "$dir/.git" ]; then
      have="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo '')"
      if [ "$have" = "$pin" ]; then ok "$name 已就位 ($have)"; continue; fi
      printf '    \033[33m!\033[0m %s 已存在但 commit 不匹配 (%s != %s)，跳过\n' "$name" "$have" "$pin"
      continue
    fi
    printf '    ... %s (%s)\n' "$name" "$note"
    if [ "$name" = "librime" ]; then
      git_clone --branch 1.17.0 --depth 1 "$url" "$dir" >"$LOGS/clone-$name.log" 2>&1 || die "$name 克隆失败(见 $LOGS/clone-$name.log)"
    else
      git_clone --depth 1 "$url" "$dir" >"$LOGS/clone-$name.log" 2>&1 || die "$name 克隆失败(见 $LOGS/clone-$name.log)"
    fi
    have="$(git -C "$dir" rev-parse HEAD)"
    [ "$have" = "$pin" ] || die "$name commit 校验失败: 期望 $pin, 实际 $have"
    ok "$name @ $have"
  done
}

do_python() {
  log "Python venv 与依赖 -> $VENV"
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  cat > "$VENV/pip.conf" <<EOF
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF
  PIP_CONFIG_FILE="$VENV/pip.conf" "$VENV/bin/pip" install -q --upgrade pip
  PIP_CONFIG_FILE="$VENV/pip.conf" "$VENV/bin/pip" install -q \
    ebooklib beautifulsoup4 lxml jieba pypinyin tqdm regex numpy \
    OpenCC 2>&1 | tail -2
  ok "venv 就绪: $VENV/bin/python"
}

do_build() {
  export PATH="$GCC_TOOLSET:$PATH"
  command -v g++ >/dev/null || die "找不到 g++（设置 GCC_TOOLSET 或安装 gcc）"

  log "构建 glog -> $PREFIX"
  src="$THIRD/glog"; [ -d "$src" ] || die "缺少 $src（先跑 clone）"
  rm -rf "$src/build"; mkdir -p "$src/build"; cd "$src/build"
  cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DWITH_GFLAGS=OFF -DWITH_UNWIND=OFF -DBUILD_TESTING=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="$RPATH_FLAG" \
    -DCMAKE_EXE_LINKER_FLAGS="$RPATH_FLAG" >"$LOGS/glog-cmake.log" 2>&1 || die "glog configure 失败"
  cmake --build . -j "$(nproc)" >"$LOGS/glog-build.log" 2>&1 || die "glog 编译失败"
  cmake --install . >/dev/null 2>&1 && ok "glog 安装到 $PREFIX"

  log "构建 librime + 插件 (octagram, lua)"
  src="$THIRD/librime"
  mkdir -p "$src/plugins"
  ln -sfn ../../librime-octagram "$src/plugins/librime-octagram"
  ln -sfn ../../librime-lua "$src/plugins/librime-lua"
  rm -rf "$src/build"; mkdir -p "$src/build"; cd "$src/build"
  BOOST_DIR="$(ls -d /usr/lib64/cmake/Boost-1.7[4-9].0 /usr/lib64/cmake/Boost-1.8*.0 2>/dev/null | tail -1 || true)"
  cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_TEST=OFF -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_PREFIX_PATH="$PREFIX" ${BOOST_DIR:+-DBoost_DIR="$BOOST_DIR"} \
    -DCMAKE_SHARED_LINKER_FLAGS="$RPATH_FLAG" \
    -DCMAKE_EXE_LINKER_FLAGS="$RPATH_FLAG" \
    >"$LOGS/librime-cmake.log" 2>&1 || { tail -20 "$LOGS/librime-cmake.log"; die "librime configure 失败"; }
  grep -q "Found plugin" "$LOGS/librime-cmake.log" && grep "Found plugin" "$LOGS/librime-cmake.log" | sed 's/^/    /'
  cmake --build . -j "$(nproc)" >"$LOGS/librime-build.log" 2>&1 || { tail -20 "$LOGS/librime-build.log"; die "librime 编译失败"; }
  # 插件工具不在默认 all 目标里，需显式构建；再链到 bin/ 方便引用
  cmake --build . --target build_grammar -j "$(nproc)" >"$LOGS/librime-tools.log" 2>&1 \
    || warn "build_grammar 构建失败（gram 阶段会缺工具）"
  ln -sfn ../plugins/librime-octagram/bin/build_grammar "$src/build/bin/build_grammar"
  ok "librime 工具: $src/build/bin/{rime_api_console,rime_deployer,build_grammar}"

  log "构建 kenlm"
  src="$THIRD/kenlm"; mkdir -p "$src/build"; cd "$src/build"
  cmake .. -DCMAKE_BUILD_TYPE=Release >"$LOGS/kenlm-cmake.log" 2>&1 || die "kenlm configure 失败"
  cmake --build . -j "$(nproc)" >"$LOGS/kenlm-build.log" 2>&1 || die "kenlm 编译失败"
  ok "kenlm: $src/build/bin/{lmplz,build_binary}"

  log "构建 Rust 工具 (rime-gram / frequency)"
  if command -v cargo >/dev/null; then
    for m in rime-gram frequency; do
      d="$THIRD/rime-corpus-processing/$m"
      if cargo build --release --manifest-path "$d/Cargo.toml" >"$LOGS/rust-$m.log" 2>&1; then
        ok "$m 编译完成"
      else
        printf '    \033[33m!\033[0m %s 编译失败（多为 cargo 版本过旧，需 ≥1.85 支持 edition2024）\n' "$m"
      fi
    done
  else
    printf '    \033[33m!\033[0m 未找到 cargo，跳过 Rust 工具\n'
  fi
}

do_gram() {
  log "下载 gram -> $DATA/gram"
  mkdir -p "$DATA/gram"
  f="$DATA/gram/zh-hans-t-essay-bgc.gram"
  if [ -s "$f" ]; then ok "已存在 $f"; return; fi
  url="https://github.com/lotem/rime-octagram-data/releases/download/20260712/zh-hans-t-essay-bgc.gram"
  if [ "$USE_PROXY" != "off" ] && command -v proxychains4 >/dev/null 2>&1; then
    proxychains4 -q curl -sL -o "$f" "$url"
  else
    curl -sL -o "$f" "$url"
  fi
  [ -s "$f" ] || die "gram 下载失败"
  ok "$(ls -la "$f" | awk '{print $5}') 字节"
}

do_check() {
  log "自检"
  python3 "$ROOT/scripts/rime_paths.py" || true
  b="$THIRD/librime/build/bin"
  [ -x "$b/rime_api_console" ] && ok "rime_api_console 可执行" || printf '    \033[33m!\033[0m 尚未构建 librime\n'
  [ -x "$b/build_grammar" ] && ok "build_grammar 可执行" || true
  command -v lmplz >/dev/null || [ -x "$THIRD/kenlm/build/bin/lmplz" ] && ok "kenlm lmplz 就绪" || true
  [ -d "$DATA/rime-test" ] && ok "测试用户目录存在" || printf '    \033[33m!\033[0m 缺 data/rime-test（跑 make env 或 make test 会建）\n'
}

case "${1:-all}" in
  clone)  do_clone ;;
  python) do_python ;;
  build)  do_build ;;
  gram)   do_gram ;;
  check)  do_check ;;
  all)    do_clone; do_python; do_build; do_gram; do_check ;;
  *)      die "未知子命令: $1" ;;
esac
