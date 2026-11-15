#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
"""
parity_scan.py -- native vs web parity table generator.

Both sides' facts are EXTRACTED from source, never hand-copied.
Output: docs/native-ui/parity.tsv

Only two things are maintained by hand, both under docs/native-ui/:
  parity_map.tsv : kind, web_id, native_id, evidence, note   (naming disambiguation)
  parity_na.tsv  : kind, web_id, web_evidence, native_evidence, reason
                                                            (confirmed "not applicable")

A naming difference would otherwise manufacture a fake gap, which is why the
map exists. Conversely, an na line is only accepted when it carries a
concrete reason AND both sides evidence -- an empty reason / empty evidence
aborts the run.

2026-11 upgrade (web-parity audit)
----------------------------------
ctrl coverage used to be only "id=sp_xxx / sel(sp_xxx)" -- 179 rows, all in
the sp_ family. The web front-end actually binds 164 events to controls, 113
of which are NOT sp_* (bPause, npVol, qSort, ...). Those ids are now extracted
from D(id).on<event> / addEventListener / .click() and counted as ctrl.

A mapped native anchor is one of two kinds:
    pb.next            an identifier string literal in tools/native_ui/*.mm
    sel:onPlayAll:     a @selector wiring point -- a real control that has no
                       queryable identifier. Such rows get status=sel, so the
                       table never pretends the control is runtime-anchored.

Extraction sources
------------------
web:
  src/net/ui_script.h : setView(x) literals + S.view = x      -> view
                        id=sp_xxx / sel(sp_xxx, ...)          -> ctrl
                        D(x).on<event> / .click() / addEventListener -> ctrl
                        data-g=xxx                            -> tab
  src/net/ui_page.h   : data-v=xxx (left nav)                 -> view
  tools/rtaweb.cpp    : "/api/..." literals + rq.path.rfind()  -> api
native:
  tools/native_ui/*.mm: identifier = @"..." / identifier: @"..." -> ctrl identity
                        @selector(name) + wiring                -> ctrl (sel anchor)
                        @"/api/..." / stringWithFormat:@"/api/.."  -> api

Acceptance: missing == 0, every na row carries verifiable evidence,
every parity_map row names a real web item.

Usage:
  python3 tools/native_ui/parity_scan.py           # write parity.tsv
  python3 tools/native_ui/parity_scan.py --check    # validate only, exit 1 on failure
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI_SCRIPT = os.path.join(ROOT, "src/net/ui_script.h")
UI_PAGE = os.path.join(ROOT, "src/net/ui_page.h")
RTAWEB = os.path.join(ROOT, "tools/rtaweb.cpp")
NATIVE_DIR = os.path.join(ROOT, "tools/native_ui")
DOCS_DIR = os.path.join(ROOT, "docs/native-ui")
MAP_PATH = os.path.join(DOCS_DIR, "parity_map.tsv")
NA_PATH = os.path.join(DOCS_DIR, "parity_na.tsv")
# 用户明确要求删掉的界面元素（web 有、原生**故意**没有）。
# 为什么需要第三张表，而不是塞进 parity_na.tsv：
#   na = "web 没有/前端不调用，所以原生不需要"；它只对 api 行开放，且要源码复核。
#   removed = "web 有，但用户明确要求原生不要"。这是**相反**的断言，
#   复核方式也不同：要证明 web 确实有它（我们没凭空造规则），且原生确实已经没有（删除真的生效）。
#   把两者混在一起会让 na 的语义失效，也会让「删功能」这种本项目铁律①最敏感的动作失去留痕。
REMOVED_PATH = os.path.join(DOCS_DIR, "parity_removed.tsv")
OUT_PATH = os.path.join(DOCS_DIR, "parity.tsv")

NL = chr(10)

# web 事件绑定点：三种写法都是"控件在 web 侧被真正绑定过"的证据。
BIND_ON_RE = re.compile(r"D\('([^']+)'\)\s*\.\s*on[A-Za-z]+\s*=")
BIND_ADD_RE = re.compile(r"D\('([^']+)'\)\s*\.\s*addEventListener\(")
BIND_CLICK_RE = re.compile(r"D\('([^']+)'\)\s*\.\s*click\(\s*\)")
# 原生 identifier：赋值形式 identifier = @"x" 与构造器实参形式 identifier:@"x" 都算。
# 旧扫描只认前者，于是 npFavBtn / npAddSq / npCastBtn 这些 identifier:@"x" 的控件
# 被当成"原生没有"，进而把真实现报成 missing。
IDENT_RE = re.compile(r'identifier\s*(?:=|:)\s*@"([^"]*)"')
# 原生 @selector 接线点：没有可查询 identifier 的控件，用接线处作锚点。
SEL_RE = re.compile(r"@selector\(([A-Za-z0-9_:]+)\)")
SEL_WIRING_RE = re.compile(
    r"\b(?:action|target|addTarget|initWithTarget|setAction|doubleAction)\s*:|"
    r"\b(?:action|target|doubleAction|onClick|onTap|onCommit|onLiveChange|"
    r"onSeek|onSelect)\s*=|"
    r",\s*self\s*,|action:\s*[A-Za-z_][A-Za-z0-9_.\[\]]*\[")
SEL_DEF_TMPL = r"^[-+]\s*\([^\n]*\)\s*%s\s*:"


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_js_comments(src):
    """Drop // and /* */ comments, keep string literals intact.

    Motive (real incident): ui_script.h comments mention setView(eq) as a view
    that no longer exists. Without stripping, the view list gains a phantom
    eq and a fake gap lives in parity forever.

    Newlines inside block comments are preserved so reported line numbers still
    match the real file (evidence has to be grep-able).
    """
    out = []
    i, n = 0, len(src)
    quote = None
    while i < n:
        c = src[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'\x60":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != NL:
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                if src[i] == NL:
                    out.append(NL)
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_c_comments(src):
    """C/C++/ObjC comment stripper (keeps string and char literals)."""
    out = []
    i, n = 0, len(src)
    quote = None
    while i < n:
        c = src[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != NL:
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                if src[i] == NL:
                    out.append(NL)
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def mask_strings(src):
    """Blank out string/char literal CONTENTS, preserving length and line numbers.

    Why: brace matching and statement slicing must not be confused by a brace
    inside a string, and evidence line numbers must stay exact.
    Comments are expected to be stripped already.
    """
    out = []
    i, n = 0, len(src)
    quote = None
    while i < n:
        c = src[i]
        if quote:
            if c == "\\" and i + 1 < n:
                out.extend((" ", " "))
                i += 2
                continue
            if c == quote:
                quote = None
                out.append(c)
            else:
                out.append(NL if c == NL else " ")
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def line_of(src, pos):
    return src.count(NL, 0, pos) + 1


def line_start(src, pos):
    return src.rfind(NL, 0, pos) + 1


HEAD_RE = re.compile(
    r"^\s*(?:-\s*\(|\+\s*\(|static\b|void\b|BOOL\b|int\b|NSInteger\b|NSUInteger\b|"
    r"CGFloat\b|double\b|float\b|id\b|SEL\b|Class\b|NSString\b|NSArray\b|"
    r"NSDictionary\b|NSMutableArray\b|NSView\b|NSWindow\b|NSButton\b|NSImage\b|"
    r"NSTextField\b|NSTableView\b|NSPopUpButton\b|NSEvent\b|RLP[A-Za-z0-9_]+\b)")


def header_start(masked, brace_pos):
    """Start of the signature line that owns the block opening at brace_pos."""
    ls = line_start(masked, brace_pos)
    for _ in range(8):
        text = masked[ls:brace_pos]
        if HEAD_RE.match(text) and ")" in text:
            return ls
        prev = masked.rfind(NL, 0, ls - 1)
        if prev < 0:
            break
        ls = prev + 1
    return None


def body_ranges(masked):
    """[(header_start, body_end)] for file-scope function/method bodies."""
    ranges = []
    depth = 0
    open_pos = None
    for i, c in enumerate(masked):
        if c == "{":
            if depth == 0:
                open_pos = i
            depth += 1
        elif c == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and open_pos is not None:
                    hs = header_start(masked, open_pos)
                    if hs is not None:
                        ranges.append((hs, i))
                    open_pos = None
    return ranges


def enclosing_body(masked, ranges, pos):
    for hs, end in ranges:
        if hs <= pos <= end:
            return hs, end
    return None


def stmt_of(masked, pos):
    """Slice a C/ObjC statement around pos, bounded by ; { }."""
    start = max(masked.rfind(";", 0, pos), masked.rfind("{", 0, pos),
                masked.rfind("}", 0, pos)) + 1
    ends = [e for e in (masked.find(";", pos), masked.find("}", pos)) if e >= 0]
    end = min(ends) if ends else len(masked)
    return start, end


def norm_path(p):
    p = p.split("?")[0]
    p = p.replace("\\", "").strip()
    return p.rstrip("/")


def scan_web():
    script = strip_js_comments(read(UI_SCRIPT))
    page = strip_js_comments(read(UI_PAGE))
    web_c = strip_c_comments(read(RTAWEB))

    views, ctrls, tabs, apis = {}, {}, {}, {}

    def add(d, item, ev):
        d.setdefault(item, [])
        if ev not in d[item]:
            d[item].append(ev)

    for m in re.finditer(r"\bsetView\(\s*'([A-Za-z0-9_]+)'\s*\)", script):
        add(views, m.group(1), "ui_script.h:%d" % line_of(script, m.start()))
    for m in re.finditer(r"\bS\.view\s*=\s*'([A-Za-z0-9_]+)'", script):
        add(views, m.group(1), "ui_script.h:%d" % line_of(script, m.start()))
    for m in re.finditer(r"\bdata-v=([A-Za-z0-9_]+)", page + script):
        add(views, m.group(1), "ui_page.h:nav")
    for m in re.finditer(r"\bdata-g=([A-Za-z0-9_]+)", script):
        add(tabs, m.group(1), "ui_script.h:%d" % line_of(script, m.start()))
    for m in re.finditer(r"\bid=(?:[\"'])?(sp_[A-Za-z0-9_]+)", script + page):
        add(ctrls, m.group(1), "ui_script.h:id")
    for m in re.finditer(r"\b(?:sel|chk|txt|num|rng)\(\s*'(sp_[A-Za-z0-9_]+)'", script):
        add(ctrls, m.group(1), "ui_script.h:%d" % line_of(script, m.start()))
    # web 的数值字段有两种调用形态：num(sp_x, ...) 与 num({ id: sp_x, label: ... }, ...)。
    # 只抓前一种会漏掉 10 个真实控件（atten/buffer/inbuf/inseconds/modcut/moddith/
    # ramp/scanthreads/taps/transition）—— 这批会永远显示成 missing，是假缺口。
    for m in re.finditer(r"\bnum\(\s*\{\s*id\s*:\s*['\"](sp_[A-Za-z0-9_]+)['\"]", script):
        add(ctrls, m.group(1), "ui_script.h:%d" % line_of(script, m.start()))
    # 事件绑定点也是控件：web 的 164 个绑定点里有 113 个不是 sp_*，旧扫描整族漏掉。
    for rx, ev in ((BIND_ON_RE, "on()"), (BIND_ADD_RE, "addEventListener"),
                   (BIND_CLICK_RE, ".click()")):
        for m in rx.finditer(script):
            add(ctrls, m.group(1), "ui_script.h:%d" % line_of(script, m.start()))
    for m in re.finditer(r'"(/api/[A-Za-z0-9_/.?=&%\-]*)"', web_c):
        add(apis, norm_path(m.group(1)), "rtaweb.cpp:%d" % line_of(web_c, m.start()))
    for m in re.finditer(r'rq\.path\.rfind\("(/api/[A-Za-z0-9_/.?=&%\-]*)"', web_c):
        add(apis, norm_path(m.group(1)), "rtaweb.cpp:%d" % line_of(web_c, m.start()))

    # 前缀路由不是端点：rtaweb 里 rq.path.rfind("/api/lib", 0) == 0 是**分发分支**
    # （前缀匹配），真正的端点是它下面的 /api/lib/status 等。把前缀本身当端点会制造假缺口
    # —— 原生不会去请求 "/api/lib"：那不是能力，是后端的内部分发结构。
    #
    # 判据：该字面量在源码里只出现在 rfind( 的前缀位置、且下面确有更长的同族端点。
    # 反例（必须保留为真端点）：rq.path == "/api/pl" 是等值比较，那是真路由。
    prefix_only = set()
    for p in list(apis):
        if not any(q != p and q.startswith(p + "/") for q in apis):
            continue
        esc = re.escape(p)
        if re.search(r'(?:==|!=)\s*"' + esc + r'"', web_c):
            continue
        if re.search(r'\.rfind\("' + esc + r'"', web_c):
            prefix_only.add(p)
    for p in prefix_only:
        apis.pop(p, None)

    apis.pop("/api", None)

    def first(d):
        return {k: sorted(v)[0] for k, v in d.items()}

    return {"view": first(views), "ctrl": first(ctrls),
            "tab": first(tabs), "api": first(apis)}


def native_sources():
    """[(name, raw)] of every .mm in tools/native_ui."""
    out = []
    for name in sorted(os.listdir(NATIVE_DIR)):
        if not name.endswith(".mm"):
            continue
        out.append((name, read(os.path.join(NATIVE_DIR, name))))
    return out


def scan_selectors():
    """@selector wiring anchors: name -> "file:line (impl file:line)".

    Only selectors that are (a) implemented in this tree and (b) referenced at a
    wiring site count. A bare @selector literal without wiring is not evidence
    that a control reacts to clicks.
    """
    defs = {}
    occ = []
    for name, raw in native_sources():
        masked = strip_c_comments(raw)
        for m in SEL_RE.finditer(masked):
            occ.append((name, masked, m.group(1), m.start()))
    for name, masked, sel, pos in occ:
        base = sel[:-1] if sel.endswith(":") else sel
        def_re = re.compile(r"^[-+]\s*\([^\n]*\)\s*%s\s*:" % re.escape(base), re.M)
        hit = def_re.search(masked)
        if hit:
            defs.setdefault(sel, "%s:%d" % (name, line_of(masked, hit.start())))
    out = {}
    for name, masked, sel, pos in occ:
        if sel not in defs:
            continue
        s, e = stmt_of(masked, pos)
        if not SEL_WIRING_RE.search(masked[s:e]):
            body = enclosing_body(masked, body_ranges(masked), pos)
            if body is None:
                continue
            if not re.search(r"action:\s*[A-Za-z_][A-Za-z0-9_.\[\]]*\[",
                             masked[body[0]:body[1]]):
                continue
        if sel not in out:
            out[sel] = "%s:%d (impl %s)" % (name, line_of(masked, pos), defs[sel])
    return out


def scan_native():
    identifiers, apis = {}, {}
    for name, raw in native_sources():
        src = strip_c_comments(raw)
        for m in IDENT_RE.finditer(src):
            identifiers.setdefault(m.group(1), "%s:%d" % (name, line_of(src, m.start())))
        # 控件 identifier 也可能来自**字面量表**（RLPControlIdentifier 的 @{ @"sp_x": @"sp_x" }），
        # 那是真赋值（表被查、值被写进 identifier），不是注释。同样算证据。
        for m in re.finditer(r'"((?:sp_[A-Za-z0-9_]+))"\s*:\s*@"\1"', src):
            identifiers.setdefault(m.group(1), "%s:%d" % (name, line_of(src, m.start())))
        # 模板 id：web 用 sp_meta_<id> / sp_metasrcrow_<id> / sp_metamvup_<id> 等**逐项**生成的 id，
        # 原生同样按模板生成（[@"sp_meta_" stringByAppendingString:sid]）。
        # 这种「字面前缀 + 动态后缀」是真实实现，把前缀本身登记为模板锚点。
        for m in re.finditer(r'@"((?:sp_[A-Za-z0-9_]*_))"\s*stringByAppendingString', src):
            identifiers.setdefault(m.group(1), "%s:%d" % (name, line_of(src, m.start())))
        for m in re.finditer(r'@"(sp_[A-Za-z0-9_]*_)"', src):
            identifiers.setdefault(m.group(1), "%s:%d" % (name, line_of(src, m.start())))
        # 视图 / 页签根节点锚点写成字面量（page.xxx / tab.xxx）：与 identifier 赋值同等效力。
        for m in re.finditer(r'@"((?:page|tab)\.[A-Za-z0-9_.]+)"', src):
            identifiers.setdefault(m.group(1), "%s:%d" % (name, line_of(src, m.start())))
        for m in re.finditer(r'@?"(/api/[A-Za-z0-9_/.?=&%\-]*)"', src):
            apis.setdefault(norm_path(m.group(1)), "%s:%d" % (name, line_of(src, m.start())))
        for m in re.finditer(r'stringWithFormat:@?"(/api/[A-Za-z0-9_/.?=&%\-]*)', src):
            apis.setdefault(norm_path(m.group(1)), "%s:%d" % (name, line_of(src, m.start())))
    apis.pop("/api", None)
    return {"ident": identifiers, "api": apis, "sel": scan_selectors()}


def _load_tsv(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in read(path).split(NL):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 3 or cols[0].strip() == "kind":
            continue
        rows.append([c.strip() for c in cols])
    return rows


def load_map():
    """parity_map.tsv columns: kind, web_id, native_id, evidence, note"""
    mapping = {}
    for cols in _load_tsv(MAP_PATH):
        kind, web_id, native_id = cols[0], cols[1], cols[2]
        ev = cols[3] if len(cols) > 3 else ""
        note = cols[4] if len(cols) > 4 else ""
        mapping[(kind, web_id)] = {"native": native_id, "evidence": ev, "note": note}
    return mapping


def load_na():
    """parity_na.tsv columns: kind, web_id, web_evidence, native_evidence, reason."""
    na = {}
    for cols in _load_tsv(NA_PATH):
        kind, web_id = cols[0], cols[1]
        web_ev = cols[2] if len(cols) > 2 else ""
        nat_ev = cols[3] if len(cols) > 3 else ""
        reason = " ".join(cols[4:]).strip()
        na[(kind, web_id)] = {"web": web_ev, "native": nat_ev, "reason": reason}
    return na


# ---------------- evidence validation --------------------------

def _src_of(token):
    token = token.strip()
    if token in ("ui_script.h", "src/net/ui_script.h"):
        return UI_SCRIPT
    if token in ("ui_page.h", "src/net/ui_page.h"):
        return UI_PAGE
    if token in ("rtaweb.cpp", "tools/rtaweb.cpp"):
        return RTAWEB
    base = os.path.basename(token)
    if base.endswith(".mm") and os.path.exists(os.path.join(NATIVE_DIR, base)):
        return os.path.join(NATIVE_DIR, base)
    return None


def _line_text(path, lineno):
    src = read(path)
    lines = src.split(NL)
    if not (1 <= lineno <= len(lines)):
        return None
    return lines[lineno - 1]


def _token_in(text, item):
    return re.search(re.escape(item) + r"([^A-Za-z0-9_.]|$)", text) is not None


def verify_evidence(web_ev, nat_ev, item, kind):
    """Return a list of problems for one na row's two evidence cells."""
    bad = []
    wparts = [p.strip() for p in web_ev.split(";") if p.strip()]
    if not wparts:
        bad.append("web evidence is empty")
    for p in wparts:
        m0 = re.match(r"^([A-Za-z0-9_./\-]+):0refs$", p)
        if m0:
            # "该文件里 0 次引用" 也是一条可在源码里复核的断言：
            # 只接受前端源码文件，计数由 verify_na_claims 的精确词元扫描承担。
            if m0.group(1) not in ("src/net/ui_script.h", "src/net/ui_page.h",
                                   "ui_script.h", "ui_page.h"):
                bad.append("web evidence %r claims 0refs outside the web UI sources" % p)
            continue
        m = re.match(r"^([A-Za-z0-9_./\-]+):(\d+)$", p)
        if not m:
            bad.append("web evidence %r is not file:line" % p)
            continue
        path = _src_of(m.group(1))
        if path is None:
            bad.append("web evidence %r names an unknown file" % p)
            continue
        text = _line_text(path, int(m.group(2)))
        if text is None:
            bad.append("web evidence %r is out of range" % p)
            continue
        if not _token_in(text, item):
            bad.append("web evidence %r does not mention %r" % (p, item))
    nparts = [p.strip() for p in nat_ev.split(";") if p.strip()]
    if not nparts:
        bad.append("native evidence is empty")
    for p in nparts:
        if p.startswith("无对应实现"):
            if len(p) <= len("无对应实现") + 2:
                bad.append("native evidence %r needs a concrete explanation" % p)
            continue
        m = re.match(r"^([A-Za-z0-9_./\-]+):(\d+)$", p)
        if not m:
            bad.append("native evidence %r is neither file:line nor 无对应实现" % p)
            continue
        path = _src_of(m.group(1))
        if path is None:
            bad.append("native evidence %r names an unknown file" % p)
            continue
        if _line_text(path, int(m.group(2))) is None:
            bad.append("native evidence %r is out of range" % p)
    return bad


def verify_na_claims(nat, ctrls_web):
    """每条 na 都必须能被源码复核，且两侧证据都得真的指到东西。

    为什么要有这一步：na 的全称是"不适用"，但它同样是**一种断言**。
    凭空写 na 和删测试让门禁变绿没有区别，所以这里用手指纹说话：
      · api：web 前端对该路径的精确词元出现次数必须为 0；
      · ctrl：原生不得存在同名 identifier / sel anchor，也不得已有 parity_map 映射；
      · 两侧证据单元格（web file:line / native file:line 或 无对应实现）必须可验证。
    """
    ui = strip_js_comments(read(UI_SCRIPT))
    page = strip_js_comments(read(UI_PAGE))
    js = ui + page
    mp = load_map()
    bad = []
    ok = 0
    for (kind, item), meta in sorted(load_na().items()):
        reason = meta["reason"]
        row_bad = []
        if kind == "api":
            if not reason.strip():
                row_bad.append("na without a reason")
            # 精确词元：/api/pl 不能匹配 /api/play
            pat = re.escape(item) + r"(?![A-Za-z0-9_])"
            n = len(re.findall(pat, js))
            if n > 0:
                row_bad.append("web UI references it %d time(s) -- na claim is false" % n)
        elif kind == "ctrl":
            if not reason.strip():
                row_bad.append("na without a reason")
            if item not in ctrls_web:
                row_bad.append("not a web control (no id= / sel() / bindings hit)")
            if mp.get((kind, item)):
                row_bad.append("parity_map maps it -- na claim contradicts the map")
            if nat["ident"].get(item) or nat["sel"].get(item):
                row_bad.append("native still has this anchor -- na claim is false")
        else:
            row_bad.append("na is only allowed for api/ctrl rows")
        row_bad.extend(verify_evidence(meta["web"], meta["native"], item, kind))
        if row_bad:
            bad.extend("%s %s: %s" % (kind, item, b) for b in row_bad)
        else:
            ok += 1
    return ok, bad


def load_removed():
    """parity_removed.tsv columns: kind, web_id, removed_on, reason.

    每一行都是一条**双向可复核**的断言：
      · web 侧确实有这个 id（否则说明我们凭空立了一条规则）；
      · 原生侧确实已经**没有**这个 identifier（否则说明"删除"没生效 / 又被加回来了）。
    两边任一不成立就报 removed_bad，门禁红。
    """
    out = {}
    for cols in _load_tsv(REMOVED_PATH):
        if len(cols) < 3:
            continue
        out[(cols[0], cols[1])] = {"removed_on": cols[2],
                                   "reason": " ".join(cols[3:]).strip()}
    return out


def verify_removed_claims(web, nat):
    removed = load_removed()
    bad = []
    ok = 0
    for (kind, item), meta in sorted(removed.items()):
        reason = meta["reason"]
        when = meta["removed_on"]
        if not reason.strip():
            bad.append("%s %s: removed without a reason" % (kind, item))
            continue
        if not when.strip():
            bad.append("%s %s: removed without a date" % (kind, item))
            continue
        if item not in web.get(kind, {}):
            bad.append("%s %s: web does not have it -- the removal claim is invented"
                       % (kind, item))
            continue
        if nat["ident"].get(item):
            bad.append("%s %s: native still has this identifier -- removal did not take effect"
                       % (kind, item))
            continue
        ok += 1
    return ok, bad


def verify_map_claims(web):
    """parity_map 的 web_id 必须真的在 web 侧出现过（防止表里长出僵尸规则）。"""
    bad = []
    ok = 0
    for (kind, web_id), meta in sorted(load_map().items()):
        if kind not in ("view", "tab", "ctrl", "api") or web_id not in web.get(kind, {}):
            bad.append("%s %s: parity_map maps a web item that does not exist" % (kind, web_id))
        else:
            ok += 1
    return ok, bad


def build_rows():
    web = scan_web()
    nat = scan_native()
    mp = load_map()
    na = load_na()
    removed = load_removed()
    rows = []
    for kind in ("view", "tab", "ctrl", "api"):
        for item in sorted(web.get(kind, {})):
            rem = removed.get((kind, item))
            if rem is not None:
                rows.append((kind, item, "--", "removed",
                             "%s: %s" % (rem["removed_on"], rem["reason"])))
                continue
            meta = na.get((kind, item))
            if meta is not None:
                if not meta["reason"]:
                    raise SystemExit("na without a reason: %s %s" % (kind, item))
                rows.append((kind, item, "--", "na",
                             "web=%s native=%s: %s" % (
                                 meta["web"], meta["native"], meta["reason"])))
                continue
            ev = web[kind][item]
            mapped = mp.get((kind, item))
            target = item
            if mapped and mapped["native"] not in ("", "-", "--"):
                target = mapped["native"]
            status = "done"
            if kind == "api":
                hit = nat["api"].get(target)
            elif kind == "ctrl" and target.startswith("sel:"):
                hit = nat["sel"].get(target[4:])
                status = "sel" if hit else "missing"
                if hit:
                    hit = "%s（@selector 接线；无 identifier）" % hit
            elif kind == "view":
                # 视图的锚点是页面根视图 identifier = "page.<key>"
                hit = nat["ident"].get(target) or nat["ident"].get("page." + target)
            elif kind == "tab":
                # 页签的锚点是页签根视图 identifier = "tab.<key>"
                hit = nat["ident"].get(target) or nat["ident"].get("tab." + target)
            else:
                hit = nat["ident"].get(target)
            if hit:
                rows.append((kind, item, target, status, hit))
            else:
                rows.append((kind, item, target if target != item else "--",
                             "missing", ev))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="validate only, do not write")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    web = scan_web()
    nat = scan_native()
    rows = build_rows()
    missing = [r for r in rows if r[3] == "missing"]
    na_ok, na_bad = verify_na_claims(nat, web["ctrl"])
    rem_ok, rem_bad = verify_removed_claims(web, nat)
    map_ok, map_bad = verify_map_claims(web)
    nas = [r for r in rows if r[3] == "na"]
    rems = [r for r in rows if r[3] == "removed"]
    done = [r for r in rows if r[3] == "done"]
    sel = [r for r in rows if r[3] == "sel"]

    if not args.check:
        os.makedirs(DOCS_DIR, exist_ok=True)
        with open(OUT_PATH, "w", encoding="utf-8") as f:
            f.write("# kind\tweb_item\tnative_item\tstatus\tevidence" + NL)
            f.write("# GENERATED by tools/native_ui/parity_scan.py -- do not hand-edit" + NL)
            for r in rows:
                f.write("\t".join(r) + NL)

    print("parity: total=%d done=%d sel=%d missing=%d removed=%d na=%d" % (
        len(rows), len(done), len(sel), len(missing), len(rems), len(nas)))
    by_kind = {}
    for r in rows:
        by_kind.setdefault(r[0], {"done": 0, "sel": 0, "missing": 0, "na": 0, "removed": 0})
        by_kind[r[0]][r[3]] += 1
    for k in ("view", "tab", "ctrl", "api"):
        if k in by_kind:
            print("  %-5s done=%-4d sel=%-4d missing=%-4d removed=%-3d na=%d" % (
                k, by_kind[k]["done"], by_kind[k]["sel"], by_kind[k]["missing"],
                by_kind[k]["removed"], by_kind[k]["na"]))
    print("  na verified (web/native evidence + claim): %d ok, %d bad" % (na_ok, len(na_bad)))
    print("  removed verified (web has it / native no longer does): %d ok, %d bad"
          % (rem_ok, len(rem_bad)))
    print("  parity_map rows verified against web source: %d ok, %d bad" % (map_ok, len(map_bad)))
    if missing and not args.quiet:
        print("")
        print("missing detail:")
        for r in missing:
            print("  %-5s %-28s %s" % (r[0], r[1], r[4]))
    if na_bad:
        print("")
        print("na claim failures:")
        for b in na_bad:
            print("  " + b)
    if rem_bad:
        print("")
        print("removed claim failures:")
        for b in rem_bad:
            print("  " + b)
    if map_bad:
        print("")
        print("parity_map failures:")
        for b in map_bad:
            print("  " + b)
    return 1 if (missing or na_bad or rem_bad or map_bad) else 0


if __name__ == "__main__":
    sys.exit(main())
