#!/usr/bin/env bash
# 复现: lua_segmentor 自定义 tag -> 只认该 tag 的 translator 产候选
# 只读库里的 librime 二进制; 全部文件在 /tmp/rime-tag-proto 下
set -e
P=/tmp/rime-tag-proto
B=/export/ebook/egret-rime/third-party/librime/build/bin
SHARED=/export/ebook/egret-rime/data/rime-shared

# 1) 编译 schema + 词典 (顶层 translator/dictionary 触发 dict 编译)
rm -rf "$P/build"; mkdir -p "$P/build"
(cd "$P" && "$B/rime_deployer" --build . "$SHARED" ./build >/dev/null 2>&1)

# 2) 热机 (冷部署首跑与热机不同)
printf '\n' | (cd "$P" && "$B/rime_api_console" >/dev/null 2>&1)

# 3) 跑实验
for c in py wubi abcd; do
  echo "########## INPUT=$c ##########"
  printf '%s\n\n' "$c" | (cd "$P" && "$B/rime_api_console" 2>&1) \
    | grep -E "route_seg|LUA_TR|FILTER cand|FILTER\] total|^[0-9]+\. "
done
