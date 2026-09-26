#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按「文件格式」注册的抽取处理器。

extract.py 扫描 input 目录，对每个文件调用 detect() 判定格式，
命中即用该处理器的 paragraphs() 抽取正文。新增格式只需在此注册一个类。

格式与来源解耦：同一格式的语料无论来自哪个目录/项目，都走同一处理器，
输出统一落到 extract/<格式名>/ 下。
"""

import html
import posixpath
import re
import zipfile
from urllib.parse import unquote

# --- 通用清洗 ---------------------------------------------------------------
WS = re.compile(r"[ \t\u00a0\u3000\u2002-\u200a]+")
ZW = re.compile(r"[\u200b-\u200f\u2028\u2029\ufeff]")
HAS_WORD = re.compile(r"[\w\u4e00-\u9fff]")


def clean_lines(text):
    """按行规范化：压空白、去零宽、丢空行与纯符号/页码行。"""
    text = ZW.sub("", text)
    out = []
    for line in text.split("\n"):
        line = WS.sub(" ", line).strip()
        if not line or not HAS_WORD.search(line):
            continue
        if len(line) <= 2 and not re.search(r"[\u4e00-\u9fff]", line):
            continue
        out.append(line)
    return out


HANDLERS = []


def register(cls):
    HANDLERS.append(cls())
    return cls


class Handler:
    name = "base"

    def detect(self, path, head=b"", ext=""):
        return False

    def paragraphs(self, path):
        raise NotImplementedError


def detect_handler(path, head, ext):
    for h in HANDLERS:
        try:
            if h.detect(path, head, ext):
                return h
        except Exception:                             # noqa: BLE001
            continue
    return None


# --- epub -------------------------------------------------------------------
SCRIPT_STYLE = re.compile(r"<(script|style)\b[^>]*>.*?</\1>", re.S | re.I)
BRK = re.compile(r"</(?:p|div|h[1-6]|li|tr|td|section|article|blockquote)\s*>"
                 r"|<br\s*/?>", re.I)
TAG = re.compile(r"<[^>]+>")
ITEM = re.compile(r"<item\b[^>]*>", re.I)
ITEMREF = re.compile(r"<itemref\b[^>]*\bidref=\"([^\"]+)\"", re.I)
ATTR = re.compile(r"\b(href|media-type|properties|id)=\"([^\"]*)\"")


@register
class EpubHandler(Handler):
    """EPUB：按 OPF spine 顺序取正文文档，逐段转文本。"""

    name = "epub"

    def detect(self, path, head=b"", ext=""):
        if not head.startswith(b"PK"):
            return False
        if ext == ".epub":
            return True
        try:                                          # 无扩展名时看 mimetype
            with zipfile.ZipFile(path) as z:
                return z.read("mimetype").startswith(b"application/epub+zip")
        except Exception:                             # noqa: BLE001
            return False

    @staticmethod
    def _find_opf(z):
        try:
            c = z.read("META-INF/container.xml").decode("utf-8", "ignore")
            m = re.search(r'full-path="([^"]+)"', c)
            if m:
                return unquote(m.group(1))
        except KeyError:
            pass
        for n in z.namelist():
            if n.lower().endswith(".opf"):
                return n
        return None

    @staticmethod
    def _spine(z, opf_path):
        raw = z.read(opf_path).decode("utf-8", "ignore")
        base = posixpath.dirname(opf_path)
        manifest = {}
        for m in ITEM.finditer(raw):
            attrs = dict(ATTR.findall(m.group(0)))
            href = attrs.get("href")
            if not href:
                continue
            mt = (attrs.get("media-type") or "").lower()
            if mt and "html" not in mt and "xml" not in mt:
                continue
            p = unquote(href.split("#")[0])
            manifest[attrs.get("id")] = posixpath.normpath(
                posixpath.join(base, p))
        order = [manifest[i] for i in ITEMREF.findall(raw) if i in manifest]
        if not order:
            order = sorted(manifest.values())
        names = set(z.namelist())
        return [p for p in order if p in names]

    def paragraphs(self, path):
        with zipfile.ZipFile(path) as z:
            opf = self._find_opf(z)
            if not opf:
                raise ValueError("no opf")
            out = []
            for doc in self._spine(z, opf):
                try:
                    raw = z.read(doc).decode("utf-8", "ignore")
                except Exception:                     # noqa: BLE001
                    continue
                s = SCRIPT_STYLE.sub(" ", raw)
                s = BRK.sub("\n", s)
                s = TAG.sub("", s)
                out.extend(clean_lines(html.unescape(s)))
            return out


# --- 标记文本（Markdown 及类似）-------------------------------------------
FENCE = re.compile(r"^```.*?^```", re.S | re.M)
IMG = re.compile(r"!\[[^\]]*\]\([^)]*\)")
LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
HEAD = re.compile(r"^\s{0,3}#{1,6}\s*", re.M)
EMPH = re.compile(r"(\*\*|__|\*|_|~~)")
HTMLTAG = re.compile(r"<[^>]+>")


@register
class MarkdownHandler(Handler):
    """Markdown（含课程/讲稿类文档）：去标记保留文字。"""

    name = "markdown"

    def detect(self, path, head=b"", ext=""):
        return ext in (".md", ".markdown", ".mdown")

    def paragraphs(self, path):
        with open(path, encoding="utf-8", errors="ignore") as f:
            text = f.read()
        text = FENCE.sub("", text)
        text = IMG.sub("", text)
        text = LINK.sub(r"\1", text)
        text = HTMLTAG.sub("", text)
        text = HEAD.sub("", text)
        text = EMPH.sub("", text)
        return clean_lines(html.unescape(text))


# --- HTML -------------------------------------------------------------------
@register
class HtmlHandler(Handler):
    """独立 html/xhtml 文件（非 epub 内页）。"""

    name = "html"

    def detect(self, path, head=b"", ext=""):
        if ext in (".html", ".htm", ".xhtml"):
            return True
        h = head.lstrip()[:200].lower()
        return h.startswith(b"<!doctype html") or h.startswith(b"<html")

    def paragraphs(self, path):
        with open(path, encoding="utf-8", errors="ignore") as f:
            raw = f.read()
        s = SCRIPT_STYLE.sub(" ", raw)
        s = BRK.sub("\n", s)
        s = TAG.sub("", s)
        return clean_lines(html.unescape(s))


# --- 纯文本 -----------------------------------------------------------------
@register
class PlainTextHandler(Handler):
    """纯文本：只做规范化，不做结构假设。"""

    name = "text"

    def detect(self, path, head=b"", ext=""):
        if ext in (".txt", ".text", ".md.txt"):
            return True
        # 无扩展名或未知扩展：能按 utf-8 解码且中文占比可观，则当纯文本
        if ext:
            return False
        try:
            sample = head.decode("utf-8")
        except UnicodeDecodeError:
            return False
        return bool(re.search(r"[\u4e00-\u9fff]", sample))

    def paragraphs(self, path):
        with open(path, encoding="utf-8", errors="ignore") as f:
            return clean_lines(f.read())
