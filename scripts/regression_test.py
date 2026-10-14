#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""egret_wubi_py 回归测试。

对真实环境逐条跑 rime_api_console, 校验首候选。

路径统一由 scripts/rime_paths.py 解析(以仓库根为基准, 不依赖 cwd,
可用环境变量覆盖)。

用法:
  python3 scripts/regression_test.py            # 默认测 <仓库>/data/rime-test
  python3 scripts/regression_test.py --rebuild  # 先 rm -rf build 重新部署再跑
  python3 scripts/regression_test.py --clean    # 先清用户词典(调频/自学习归零)再跑
  python3 scripts/regression_test.py --dir ~/Library/Rime   # 测其他环境(macOS)

注意(见 AGENTS.md 陷阱清单):
- user.yaml 的 previously_selected_schema 会被 console 运行改写, 每次运行前重置
- rm -rf build 后首次 console 可能有维护竞态, --rebuild 模式会先空跑一次预热
"""

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rime_paths  # noqa: E402  (同目录共享路径模块)

LIBRIME_CONSOLE = rime_paths.librime_tool("rime_api_console")
LIBRIME_DEPLOYER = rime_paths.librime_tool("rime_deployer")

# 共享数据目录按平台探测: macOS=Squirrel SharedSupport;
# Linux=ibus-rime 的 /usr/share/rime-data 或 fcitx5 的数据目录。
# 均不可用时用 --shared-dir 指定(部署时 punctuator/recognizer 的
# import_preset: symbols/default 需要 symbols.yaml/default.yaml 源文件)。
SQUIRREL_SHARED = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
LINUX_SHARED_CANDIDATES = [
    rime_paths.RIME_SHARED_DIR,
    "/usr/share/rime-data",
    "/usr/share/fcitx5/rime-data",
]

# (输入码, 期望首候选, 说明)
CASES = [
    # 一级/二级/三级简码 (传统库 first_translator, 肌肉记忆)
    ("e", "有", "一级简码"),
    ("q", "我", "一级简码"),
    ("yi", "就", "一级简码(易与拼音'以'冲突)"),
    ("yl", "为", "二级简码"),
    ("kl", "另", "二级简码"),
    ("de", "胡", "二级简码(易与拼音'的'冲突)"),
    # 字全码 (曾因 2+2 词码冲突被过滤, 根因#11)
    ("tffu", "等", "字全码>词组(等780>徒增502)"),
    # 词组 (传统库显式码)
    ("khlg", "中国", "二字词 2+2"),
    ("xciy", "经济", "二字词 2+2"),
    ("kdyc", "顺序", "二字词 2+2"),
    ("trwu", "我们", "二字词 2+2"),
    # 混流 + LM 组句
    ("trwuchifan", "我们吃饭", "五笔+拼音混流"),
    ("jfwaguangfnrt", "时代广场", "四字词 1+1+1+1"),
    ("jintiandetianqizenmeyang", "今天的天气怎么样", "纯拼音长句"),
    ("tamenlailehenduoren", "他们来了很多人", "LM 组句"),
    ("wojintianmeiyoukong", "我今天没有空", "LM 组句"),
    # 用户词组/造词
    ("tgtj", "生不逢时", "用户词组(手工维护)"),
    # 2026-09-25 实测新增: 拼音音节首候选(传统库补全污染修复后)
    ("wan", "万", "拼音单音节(曾披传统库 wan* 补全污染→佢/代收)"),
    ("taiwan", "台湾", "拼音词组直查(混合库 tai wan 词条)"),
    ("ckiy", "台湾", "传统词组 2+2"),
    # 已知行为: ck+wan 组句因 万850>湾719 权重差 > LM 贡献(~±20), 出「台万」;
    # 逐字选台选湾一次后用户词典记住 ck+wan=台湾, 之后 ckwan→台湾。不作硬性断言。

    # --- 2026-09 修复项，逐条钉住（这些 bug 当初黄金一条都没拦住）---
    ("qktqn", "我吃饭", "五笔短码序列组句(简码拼写补进混合库 §4.19)"),
    ("qktnqnr", "我吃饭", "同上(一/二级简码前缀歧义)"),
    ("qktnqnrb", "我吃饭了", "同上"),
    ("qchifanle", "我吃饭了", "五笔一级简码 + 拼音混流(用户报的例子)"),
    ("uwycuklf", "冷部署", "五笔全码补进混合库(原为 闪充部署 §4.19b)"),
    ("trwuktnqnr", "我们吃饭", "五笔词 + 短码序列"),
    ("ronghe", "融合", "speller.cc max_code_length 必须为 0，否则第 5 码自动上屏、余 e 另起一段"),
    ("b,", "了", "强制结束符 <短码>,（原 algebra 规则对本仓库词库格式无效 §4.21）"),
    ("ktn,", "吃", "强制结束符(三级码)"),
    ("ben", "本", "字表分层: 扩展区生僻字不默认加载，否则 ben->𨸐(§4.23)"),
    ("yijuliangde", "一举两得", "成语·拼音版(默认引入 §4.27)"),
    ("owfhtc", "为什么", "整句词库(五笔短码->整句 §4.16)"),
    # --- 混流多读法（§4.41）：整串五笔读法时补 wubi tag，让 86 库的组句胜出 ---
    ("gdrnthtcsu", "天气怎么样", "混流多读法: 整串五笔 -> 补 tag(§4.41)"),

    # --- 2026-10 session 里用户报的问题，逐条钉住（§4.76/§4.81）---
    ("kkkk", "口", "键名字四连击: 用户报「应是口，不是串串」(§4.76)"),
    ("aaaa", "工", "键名字四连击: 用户报「前两项都是工」——同码词压制 + 去重(§4.76)"),
    ("womenzaiyiqi", "我们在一起", "长句; 页尾留字+词的展示用例(§4.76, 结构断言见下)"),
    ("ghdqusvfryyif", "正确新建的方法", "用户报: 选 6 后页尾失效(段起点 bug, §4.76)"),
    ("ililfbyivbb", "渐渐地就好了", "纯五笔路径(用户展示例)"),
    ("wqskc", "你可以", "五笔简码序列组句被前缀补全埋没(第47名); wubi_route/sentence_over_completion(§4.85)"),
    ("qdynwqcegandeshang", "希望你能赶得上", "混打(五笔简码+拼音)选字: 搜索器码表需含长尾词「赶得上」才能成词(§4.86)"),
    ("qwuqdyn", "我们希望", "四个简码字组句: q(我)+wu(们)+qd(希)+yn(望); 用户报「单字简码组句效果不好」"),
    ("trwuqdyn", "我们希望", "五笔词 + 两个简码字"),
    ("womenxiwang", "我们希望", "纯拼音对照组"),
    ("ililfbyihaole", "渐渐地就好了", "混打：形码片段(ilil/fb) + 拼音(hao/le)；搜索器混打注入修复（§4.83）"),
]

# 混打/全拼的同句仍是模型能力边界（2026-10-13 实测）：
#   ililfbyihaole        → 渐渐地主不好了 ✗
#   jianjiandejiuhaole   → 见见得就好了   ✗
# 纯五笔 ililfbyivbb     → 渐渐地就好了   ✓（已作为用例钉住）
# 这类不写进 CASES（会红），只在 §4.81 记录；要改得从词级 LM 与混读法裁决下手。

# 已知 LM 级问题: wanxiang 官方模型=才最, 自训 jixiuf gram=都不可能。
# 切 egret.common.yaml 的 grammar/language 后期望值不同, 不作为失败项, 仅报告。
KNOWN_LM_CASES = [
    ("fqywvkwsniftjbgiskceybgazhelile",
     ["无论如何你都不可能离开这里了", "无论如何你才最不可能离开这里了"],
     "黄金句(gram 配比相关, 两个结果均记录)"),
]

# 用户词典（2026-10 起全部 db_class: tabledb → 用户目录根纯文本 <name>.txt；
# 之前是 build/<name>.userdb/ LevelDB 目录。两条路径都列，兼容旧环境。）
#
# 只清「机器会写」的两本；custom_phrase（egret_wubi_py.user.dict）**不清**：
# 它是人工维护的短语表（且历史上一直没被清过），清了会丢用户内容。
USERDICT_PATHS = [
    "egret_wubi_py_script.user.dict.userdb",   # 旧: script 翻译器（自学习，LevelDB）
    "egret_wubi_py_script.user.dict.txt",      # 新: script 翻译器（自学习，纯文本）
    "egret_wubi.user.dict.userdb",             # 旧: 传统五笔库（造词/调频，LevelDB）
    "egret_wubi.user.dict.txt",                # 新: 传统五笔库（造词/调频，纯文本）
]


def reset_selected_schema(user_dir):
    """console 运行会改写 previously_selected_schema, 测前强制重置。"""
    path = os.path.join(user_dir, "user.yaml")
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        src = f.read()
    fixed = re.sub(r"previously_selected_schema: \S+",
                   "previously_selected_schema: egret_wubi_py", src)
    if fixed != src:
        with open(path, "w", encoding="utf-8") as f:
            f.write(fixed)


def first_candidate(code, cwd):
    """返回首候选文本(如 '有')。

    连跑两次取第二次：冷部署后首跑的分段与热机不同（prism 非确定性，
    见 docs/PROGRESS.md §4.18 测量纪律），单跑结论不可信。

    超时（搜索爆炸 / librime-lua 关闭期 GC 活锁，见 §4.51）不再抛异常中断整轮，
    而是返回一个显眼的标记，让回归报告直接暴露它。
    """
    result = None
    for _ in range(2):
        try:
            p = subprocess.run([LIBRIME_CONSOLE], input=code + "\n\n",
                               capture_output=True, text=True, cwd=cwd, timeout=120)
        except subprocess.TimeoutExpired:
            return "(超时/挂死)"
        result = None
        for line in p.stdout.splitlines():
            m = re.match(r"1\. \[([^\]]*)\]", line.strip())
            if m:
                result = m.group(1)
                break
    return result


def detect_shared_dir(explicit=None):
    """按平台探测共享数据目录(需含 symbols.yaml/default.yaml 等源文件)。"""
    if explicit:
        return explicit
    import platform
    candidates = []
    if platform.system() == "Darwin":
        candidates = [SQUIRREL_SHARED]
    else:
        candidates = LINUX_SHARED_CANDIDATES
    for c in candidates:
        if os.path.isdir(c) and os.path.exists(os.path.join(c, "symbols.yaml")):
            return c
    return None


def deploy(user_dir, shared_dir):
    cmd = [LIBRIME_DEPLOYER, "--build", user_dir]
    if shared_dir:
        cmd.append(shared_dir)
    r = subprocess.run(cmd, capture_output=True)
    print("部署完成" if r.returncode == 0 else "部署异常(仍继续测试)")


def candidate_page(code, extra_key="", user_dir="."):
    """返回最后一屏候选的 (文本, 注释) 列表；连跑两次取第二次（测量纪律）。"""
    page = []
    for _ in range(2):
        p = subprocess.run([LIBRIME_CONSOLE], input=code + "\n" + extra_key + "\n\n",
                           capture_output=True, text=True, cwd=user_dir, timeout=180)
        pages, cur = [], None
        for line in p.stdout.splitlines():
            if line.startswith("page:"):
                cur = []
                pages.append(cur)
            elif cur is not None:
                m = re.match(r"^\s*\d+\.\s*(?:\[([^\]]*)\]|(\S+))\s*(.*)$", line)
                if m:
                    cur.append(((m.group(1) or m.group(2) or "").strip(),
                                (m.group(3) or "").strip()))
        if pages:
            page = pages[-1]
    return page


def struct_checks(user_dir):
    """候选表结构断言：这些是「首候选等于什么」拦不住、但用户报过的问题。

    返回 [(名称, 通过?, 说明)]。
    """
    out = []

    pg = candidate_page("aaaa", user_dir=user_dir)
    n_gong = sum(1 for t, _ in pg if t == "工")
    out.append(("aaaa 去重", n_gong == 1,
                f"首页「工」出现 {n_gong} 次（期望 1；曾出现两个，§4.76）"))

    pg = candidate_page("womenzaiyiqi", user_dir=user_dir)
    tail = [t for t, _ in pg[-2:]]
    ok = len(tail) == 2 and len(tail[0]) == 1 and len(tail[1]) >= 2
    out.append(("长句页尾=字+词", ok,
                f"页尾两项 {tail}（期望 单字 + 词，§4.76）"))

    pg = candidate_page("ghdqusvfryyif", extra_key="6", user_dir=user_dir)
    tail = [t for t, _ in pg[-2:]]
    ok = len(tail) == 2 and len(tail[0]) == 1 and len(tail[1]) >= 2
    out.append(("选掉一段后页尾仍=字+词", ok,
                f"选 6 之后页尾两项 {tail}（段起点不是 0 时的回归，§4.76）"))

    pg = candidate_page("tffu", user_dir=user_dir)
    cmt = pg[0][1] if pg else ""
    out.append(("候选带五笔编码注释", "tffu" in cmt,
                f"tffu 首候选注释 = {cmt!r}（期望含 tffu，用户要过「显示五笔编码」）"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=rime_paths.RIME_TEST_DIR,
                    help="被测用户目录 (默认 <仓库>/data/rime-test; "
                         "macOS 正式环境为 ~/Library/Rime)")
    ap.add_argument("--rebuild", action="store_true",
                    help="先删除 build 并重新部署")
    ap.add_argument("--clean", action="store_true",
                    help="先清除用户词典 userdb(调频/自学习归零)")
    ap.add_argument("--shared-dir", default=None,
                    help="共享数据目录(默认按平台探测; Linux 无 rime-data 时"
                         "可指向含 symbols.yaml/default.yaml 的自备目录)")
    args = ap.parse_args()

    user_dir = args.dir
    if not os.path.isdir(user_dir):
        sys.exit(f"用户目录不存在: {user_dir}")
    shared_dir = detect_shared_dir(args.shared_dir)

    if args.clean:
        import shutil
        for rel in USERDICT_PATHS:
            p = os.path.join(user_dir, rel)
            if os.path.isdir(p):
                shutil.rmtree(p)
                print(f"已清除 {rel}")
            elif os.path.exists(p):
                os.remove(p)
                print(f"已清除 {rel}")

    if args.rebuild:
        import shutil
        shutil.rmtree(os.path.join(user_dir, "build"),
                      ignore_errors=True)
        deploy(user_dir, shared_dir)
        print(f"共享数据目录: {shared_dir or '(未找到, 依赖已有 build 产物)'}")

    reset_selected_schema(user_dir)

    # rebuild 后首次 console 可能有维护竞态, 空跑一次预热
    if args.rebuild:
        first_candidate("khlg", user_dir)
        reset_selected_schema(user_dir)

    failed, passed = [], 0
    print(f"\n{'输入码':<28} 期望       实际       说明")
    print("-" * 78)
    for code, expect, note in CASES:
        got = first_candidate(code, user_dir)
        reset_selected_schema(user_dir)
        ok = (got == expect)
        passed += ok
        if not ok:
            failed.append((code, expect, got, note))
        print(f"{code:<28} {expect:<10} {(got or '?'):<10} "
              f"{'✓' if ok else '✗'} {note}")

    print("-" * 78)
    for code, accepts, note in KNOWN_LM_CASES:
        got = first_candidate(code, user_dir)
        reset_selected_schema(user_dir)
        tag = "✓(已知)" if got in accepts else "⚠ 新结果(记录到 AGENTS.md)"
        print(f"{code:<28} {'/'.join(accepts)[:18]:<20} {(got or '?'):<10} {tag} {note}")

    print("-" * 78)
    print("候选表结构断言:")
    struct = struct_checks(user_dir)
    for name, ok, desc in struct:
        passed += ok
        if not ok:
            failed.append((name, "", "", desc))
        print(f"  {name:<22} {'✓' if ok else '✗'} {desc}")

    total = len(CASES) + len(struct)
    print(f"\n通过 {passed}/{total}")
    if failed:
        print("失败用例:")
        for code, expect, got, note in failed:
            print(f"  {code}  期望={expect}  实际={got}  ({note})")
        sys.exit(1)
    print("全部通过 ✓")


if __name__ == "__main__":
    main()
