#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""仓库内路径统一入口——所有路径以本仓库根目录为基准。

设计原则：
- 一律从 __file__ 推导仓库根，不依赖当前工作目录（cwd 在任何地方结果一致）。
- 外部依赖源码统一落在 third-party/（不入 git），可用环境变量覆盖。
- 语料/中间产物/测试环境统一落在 data/（不入 git）。

约定：
    third-party/   外部仓库源码与构建产物（librime/kenlm/glog/...）
    data/          语料、词频、用户目录、gram 等本地数据
    dicts/         词库源与产物（入 git）

环境变量覆盖（均可选）：
    LIBRIME_BIN      librime build/bin 目录
    RIME_TEST_DIR    测试用 Rime 用户目录（默认 data/rime-test）
    RIME_SHARED_DIR  共享数据目录（默认 data/rime-shared）
    RIME_FROST_DIR   rime-frost 仓库（默认 third-party/rime-frost）
    RIME_WANXIANG_DIR  rime_wanxiang 仓库（默认 third-party/rime_wanxiang）
    EGRET_GRAM_DIR   gram 文件目录（默认 data/gram）
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

DICTS = os.path.join(REPO, "dicts")
DATA = os.path.join(REPO, "data")
THIRD_PARTY = os.path.join(REPO, "third-party")
SCRIPTS = os.path.join(REPO, "scripts")


def _env_dir(var, default):
    v = os.environ.get(var)
    return os.path.expanduser(v) if v else default


def third_party(name, env_var=None):
    """外部仓库目录：环境变量优先，否则 third-party/<name>。"""
    return _env_dir(env_var, os.path.join(THIRD_PARTY, name)) if env_var \
        else os.path.join(THIRD_PARTY, name)


# --- 外部仓库 ---------------------------------------------------------------
RIME_FROST_DIR = third_party("rime-frost", "RIME_FROST_DIR")
RIME_WANXIANG_DIR = third_party("rime_wanxiang", "RIME_WANXIANG_DIR")

# --- librime 工具与运行环境 -------------------------------------------------
LIBRIME_BIN = _env_dir("LIBRIME_BIN",
                       os.path.join(THIRD_PARTY, "librime", "build", "bin"))
RIME_TEST_DIR = _env_dir("RIME_TEST_DIR", os.path.join(DATA, "rime-test"))
RIME_SHARED_DIR = _env_dir("RIME_SHARED_DIR", os.path.join(DATA, "rime-shared"))
GRAM_DIR = _env_dir("EGRET_GRAM_DIR", os.path.join(DATA, "gram"))


def librime_tool(name):
    """定位 librime 工具。

    优先级：LIBRIME_BIN > 本仓库 third-party/librime > ~/repos/librime
    （末项仅为兼容旧 macOS 开发环境）。
    """
    candidates = [
        os.environ.get("LIBRIME_BIN"),
        os.path.join(THIRD_PARTY, "librime", "build", "bin"),
        os.path.expanduser("~/repos/librime/build/bin"),
    ]
    for d in candidates:
        if d and os.path.exists(os.path.join(d, name)):
            return os.path.join(d, name)
    return os.path.join(LIBRIME_BIN, name)


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    return path


if __name__ == "__main__":
    # 自检：打印解析结果与存在性
    for k, v in [
        ("REPO", REPO), ("DICTS", DICTS), ("DATA", DATA),
        ("THIRD_PARTY", THIRD_PARTY), ("LIBRIME_BIN", LIBRIME_BIN),
        ("RIME_TEST_DIR", RIME_TEST_DIR), ("RIME_SHARED_DIR", RIME_SHARED_DIR),
        ("GRAM_DIR", GRAM_DIR), ("RIME_FROST_DIR", RIME_FROST_DIR),
        ("rime_api_console", librime_tool("rime_api_console")),
        ("rime_deployer", librime_tool("rime_deployer")),
    ]:
        mark = "✓" if os.path.exists(v) else "✗"
        print(f"{mark} {k:<18} {v}")
