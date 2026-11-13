#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
"""
parity_scan.py -- native vs web parity table generator.

Both sides' facts are EXTRACTED from source, never hand-copied.
Output: docs/native-ui/parity.tsv

Only two things are maintained by hand, both under docs/native-ui/:
  parity_map.tsv : kind, web_id, native_id, evidence, note   (naming disambiguation)
  parity_na.tsv  : kind, web_id, reason                      (confirmed "not applicable")

A naming difference would otherwise manufacture a fake gap, which is why the
map exists. Conversely, an 'na' line is only accepted when it carries a
concrete reason -- an empty reason aborts the run.

Extraction sources
------------------
web:
  src/net/ui_script.h : setView('x') literals + S.view = 'x'      -> view
                        id=sp_xxx / sel('sp_xxx', ...)            -> ctrl
                        data-g=xxx                                -> tab
  src/net/ui_page.h   : data-v=xxx (left nav)                     -> view
  tools/rtaweb.cpp    : "/api/..." literals + rq.path.rfind(...)  -> api
native:
  tools/native_ui/*.mm: identifier = @"..."                       -> ctrl identity
                        @"/api/..." / stringWithFormat:@"/api/.."  -> api

Acceptance: missing == 0, every na has a reason.

Usage:
  python3 tools/native_ui/parity_scan.py           # write parity.tsv
  python3 tools/native_ui/parity_scan.py --check    # validate only, exit 1 on missing
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


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_js_comments(src):
    """Drop // and /* */ comments, keep string literals intact.

    Motive (real incident): ui_script.h comments mention setView('eq') as a view
    that no longer exists. Without stripping, the view list gains a phantom
    'eq' and a fake gap lives in parity forever.

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


def line_of(src, pos):
    return src.count(NL, 0, pos) + 1


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
    # web 的数值字段有两种调用形态：num('sp_x', …) 与 num({ id: 'sp_x', label: … }, …)。
    # 只抓前一种会漏掉 10 个真实控件（atten/buffer/inbuf/inseconds/modcut/moddith/
    # ramp/scanthreads/taps/transition）—— 这批会永远显示成 missing，是假缺口。
    for m in re.finditer(r"\bnum\(\s*\{\s*id\s*:\s*['\"](sp_[A-Za-z0-9_]+)['\"]", script):
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


def scan_native():
    identifiers, apis = {}, {}
    for name in sorted(os.listdir(NATIVE_DIR)):
        if not name.endswith(".mm"):
            continue
        src = strip_c_comments(read(os.path.join(NATIVE_DIR, name)))
        for m in re.finditer(r'identifier\s*=\s*@"([^"]*)"', src):
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
        # 模板 id：web 逐项生成 sp_meta_<id> / sp_metasrcrow_<id> / sp_metamvup_<id> 等，
        # 原生同样按模板生成（@"sp_meta_" + sid）。字面前缀 + 动态后缀是真实实现，
        # 把前缀本身登记为模板锚点。
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
    return {"ident": identifiers, "api": apis}


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
    """parity_na.tsv columns: kind, web_id, reason (reason must be concrete)."""
    na = {}
    for cols in _load_tsv(NA_PATH):
        kind, web_id = cols[0], cols[1]
        reason = " ".join(cols[2:]).strip()
        na[(kind, web_id)] = reason
    return na


def verify_na_claims():
    """每条 na 都必须能被源码复核：web 前端**确实不调用**这个路径。

    为什么要有这一步：na 的全称是"不适用"，但它同样是**一种断言** ——
    断言"web 没有这个东西，所以原生不需要"。凭空写 na 和删测试让门禁变绿没有区别。
    所以这里用手指纹说话：把 ui_script.h + ui_page.h（剥掉注释）里该路径的
    精确词元出现次数数出来，>0 就说明 web 用了它，该条 na 不成立。

    返回 (ok_count, [bad_reason...])。
    """
    ui = strip_js_comments(read(UI_SCRIPT))
    page = strip_js_comments(read(UI_PAGE))
    js = ui + page
    bad = []
    ok = 0
    for (kind, item), reason in sorted(load_na().items()):
        if kind != "api":
            # 非 api 的 na 目前不该出现：视图/页签/控件都必须真做
            bad.append("%s %s: na is only allowed for api rows" % (kind, item))
            continue
        # 精确词元：/api/pl 不能匹配 /api/play
        pat = re.escape(item) + r"(?![A-Za-z0-9_])"
        n = len(re.findall(pat, js))
        if n > 0:
            bad.append("%s: web UI references it %d time(s) -- na claim is false" % (item, n))
        elif not reason.strip():
            bad.append("%s: na without a reason" % item)
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
            reason = na.get((kind, item))
            if reason is not None:
                if not reason:
                    raise SystemExit("na without a reason: %s %s" % (kind, item))
                rows.append((kind, item, "--", "na", reason))
                continue
            ev = web[kind][item]
            mapped = mp.get((kind, item))
            target = item
            if mapped and mapped["native"] not in ("", "-", "--"):
                target = mapped["native"]
            if kind == "api":
                hit = nat["api"].get(target)
            elif kind == "ctrl" and target.endswith("_"):
                # web 的模板 id（sp_meta_ / sp_metasrcrow_ …）对应原生的同名前缀模板
                hit = nat["ident"].get(target)
            elif kind == "view":
                # 视图的锚点是页面根视图 identifier = "page.<key>"
                hit = nat["ident"].get(target) or nat["ident"].get("page." + target)
            elif kind == "tab":
                # 页签的锚点是页签根视图 identifier = "tab.<key>"
                hit = nat["ident"].get(target) or nat["ident"].get("tab." + target)
            elif kind == "ctrl" and target.endswith("_"):
                # web 的模板 id（sp_meta_ 等）以 "_" 结尾：原生侧只要登记了同名模板前缀就算实现
                hit = nat["ident"].get(target)
                if not hit:
                    hit = nat["ident"].get(target)
            else:
                hit = nat["ident"].get(target)
            if hit:
                rows.append((kind, item, target, "done", hit))
            else:
                rows.append((kind, item, target if target != item else "--",
                             "missing", ev))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="validate only, do not write")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    rows = build_rows()
    missing = [r for r in rows if r[3] == "missing"]
    na_ok, na_bad = verify_na_claims()
    rem_ok, rem_bad = verify_removed_claims(scan_web(), scan_native())
    nas = [r for r in rows if r[3] == "na"]
    rems = [r for r in rows if r[3] == "removed"]
    done = [r for r in rows if r[3] == "done"]

    if not args.check:
        os.makedirs(DOCS_DIR, exist_ok=True)
        with open(OUT_PATH, "w", encoding="utf-8") as f:
            f.write("# kind\tweb_item\tnative_item\tstatus\tevidence" + NL)
            f.write("# GENERATED by tools/native_ui/parity_scan.py -- do not hand-edit" + NL)
            for r in rows:
                f.write("\t".join(r) + NL)

    print("parity: total=%d done=%d missing=%d removed=%d na=%d" % (
        len(rows), len(done), len(missing), len(rems), len(nas)))
    by_kind = {}
    for r in rows:
        by_kind.setdefault(r[0], {"done": 0, "missing": 0, "na": 0, "removed": 0})
        by_kind[r[0]][r[3]] += 1
    for k in ("view", "tab", "ctrl", "api"):
        if k in by_kind:
            print("  %-5s done=%-4d missing=%-4d removed=%-3d na=%d" % (
                k, by_kind[k]["done"], by_kind[k]["missing"],
                by_kind[k]["removed"], by_kind[k]["na"]))
    print("  na verified against web front-end source: %d ok, %d bad" % (na_ok, len(na_bad)))
    print("  removed verified (web has it / native no longer does): %d ok, %d bad"
          % (rem_ok, len(rem_bad)))
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
    return 1 if (missing or na_bad or rem_bad) else 0


if __name__ == "__main__":
    sys.exit(main())
