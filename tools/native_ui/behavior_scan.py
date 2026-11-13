#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
"""
behavior_scan.py -- web JS event bindings vs native behavior: a three-state table.

Why this exists
---------------
parity_scan.py only proves that an identifier / API endpoint EXISTS on both sides
(missing=0). It cannot tell "the control is there but clicking it does nothing" --
that is exactly the class of bug users reported ("大部分功能失灵").
This scanner therefore starts from the controls parity_scan already matched and
asks a behavior question:

    web binds an event to this control  ->  does the native implementation of
                                            that control have an action path?

States
------
  done          native control + a behavior marker near it (target/action/gesture/mouse)
  control-only  native control found, but no behavior marker around it
                (renders fine, likely does nothing)  -> actionable gap
  missing       web binds an event to an id that no native source mentions at all
                -> actionable gap

The judgment is a HEURISTIC over source text, not a runtime proof: it is a review
queue generator. Runtime evidence stays in RLPFunctionalAudit (--audit). Use both.

Sources
-------
  web      : src/net/ui_script.h  -- D('id').on<event> assignments (+ .click())
             src/net/ui_page.h    -- id=xxx markup (control exists check only)
  native   : tools/native_ui/*.mm quoted identifier literals
  mapping  : docs/native-ui/parity_map.tsv (web id -> native id) and parity.tsv
             (evidence file:line for every matched control)

Usage
-----
  python3 tools/native_ui/behavior_scan.py            # write docs/native-ui/behavior.tsv
  python3 tools/native_ui/behavior_scan.py --check     # exit 1 if actionable gaps
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NATIVE_DIR = os.path.join(ROOT, "tools/native_ui")
DOCS_DIR = os.path.join(ROOT, "docs/native-ui")
UI_SCRIPT = os.path.join(ROOT, "src/net/ui_script.h")
UI_PAGE = os.path.join(ROOT, "src/net/ui_page.h")
PARITY = os.path.join(DOCS_DIR, "parity.tsv")
MAP_PATH = os.path.join(DOCS_DIR, "parity_map.tsv")
NA_PATH = os.path.join(DOCS_DIR, "behavior_na.tsv")
OUT_PATH = os.path.join(DOCS_DIR, "behavior.tsv")

EVENTS = ("click onchange oninput onkeydown onkeyup onkeypress ondblclick "
          "oncontextmenu onmousedown onmouseup onmouseenter onmouseleave "
          "onmousemove onwheel ondragstart ondragover ondrop onfocus onblur "
          "onsubmit onscroll").split()

BIND_RE = re.compile(
    r"D\('([^']+)'\)\s*\.(on(?:%s))\s*=" % "|".join(e[2:] for e in EVENTS))
CLICK_RE = re.compile(r"D\('([^']+)'\)\s*\.\s*click\(\)")
# behavior markers in a native source window
MARKERS = re.compile(
    r"@selector\(|target\s*=|\.target\s*=|action\s*=|\.action\s*=|"
    r"addGestureRecognizer|mouseDown:|mouseUp:|keyDown:|"
    r"performClick|acceptsFirstResponder|insertNewline:|addTrackingArea")


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_c_like(src, line_comment="//", block=True):
    """Remove comments but keep string literals (so ids inside strings survive)."""
    out = []
    i, n = 0, len(src)
    in_str = None
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1]); i += 2; continue
            if c == in_str:
                in_str = None
            i += 1; continue
        if c in ('"', "'"):
            in_str = c; out.append(c); i += 1; continue
        if src.startswith(line_comment, i):
            j = src.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if block and src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c); i += 1
    return "".join(out)


def load_tsv(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            rows.append(line.split("\t"))
    return rows


def line_of(src, pos):
    return src.count("\n", 0, pos) + 1


def scan_web_bindings():
    """id -> sorted list of event names (+ click() calls)."""
    js = strip_c_like(read(UI_SCRIPT))
    binds = {}
    for m in BIND_RE.finditer(js):
        binds.setdefault(m.group(1), set()).add(m.group(2)[2:])
    for m in CLICK_RE.finditer(js):
        binds.setdefault(m.group(1), set()).add("click()")
    return {k: sorted(v) for k, v in binds.items()}


def scan_native():
    """identifier -> list of (file, line, window_text)."""
    hits = {}
    for name in sorted(os.listdir(NATIVE_DIR)):
        if not name.endswith(".mm"):
            continue
        raw = read(os.path.join(NATIVE_DIR, name))
        src = strip_c_like(raw)
        for m in re.finditer(r'@"((?:[^"\\]|\\.)+)"', src):
            ident = m.group(1)
            if not ident:
                continue
            start = max(0, m.start() - 1800)
            end = min(len(src), m.end() + 1800)
            hits.setdefault(ident, []).append(
                (name, line_of(src, m.start()), src[start:end]))
    return hits


def load_parity():
    rows = load_tsv(PARITY)
    ctrls = {}
    for cols in rows:
        if len(cols) < 4 or cols[0] != "ctrl":
            continue
        web, native, status = cols[1], cols[2], cols[3]
        if status == "done" and native not in ("--", "-", ""):
            ctrls[web] = native
    return ctrls


def load_map():
    m = {}
    for cols in load_tsv(MAP_PATH):
        if len(cols) < 3 or cols[0] != "ctrl":
            continue
        m[cols[1]] = cols[2]
    return m


def load_na():
    na = {}
    for cols in load_tsv(NA_PATH):
        if len(cols) < 2 or cols[0] != "bind":
            continue
        reason = " ".join(cols[2:]).strip()
        na[cols[1]] = reason
    return na


def has_marker(windows):
    for (_f, _l, text) in windows:
        if MARKERS.search(text):
            return True
    return False


def build_rows():
    binds = scan_web_bindings()
    native = scan_native()
    parity = load_parity()
    mapping = load_map()
    na = load_na()
    rows = []
    for web_id, events in sorted(binds.items()):
        if web_id in na:
            rows.append(("bind", web_id, ",".join(events), "--", "na", na[web_id]))
            continue
        target = parity.get(web_id) or mapping.get(web_id) or web_id
        hit = native.get(target)
        if not hit:
            rows.append(("bind", web_id, ",".join(events), "--", "missing",
                         "web 绑定 %s 但原生源码没有对应 identifier" % ",".join(events)))
            continue
        ok = has_marker(hit)
        file_line = "%s:%d" % (hit[0][0], hit[0][1])
        rows.append(("bind", web_id, ",".join(events), target,
                     "done" if ok else "control-only",
                     file_line + ("" if ok else " 无 action/target/手势邻近")))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    rows = build_rows()
    counts = {}
    for r in rows:
        counts[r[4]] = counts.get(r[4], 0) + 1
    actionable = [r for r in rows if r[4] in ("missing", "control-only")]
    if not args.check:
        with open(OUT_PATH, "w", encoding="utf-8") as f:
            f.write("# kind\tweb_item\tevents\tnative_item\tstatus\tevidence\n")
            f.write("# GENERATED by tools/native_ui/behavior_scan.py -- do not hand-edit\n")
            for r in rows:
                f.write("\t".join(r) + "\n")
        print("wrote %s" % OUT_PATH)
    for k in sorted(counts):
        print("  bind  %-12s %d" % (k, counts[k]))
    print("  total bindings=%d actionable=%d" % (len(rows), len(actionable)))
    if actionable:
        for r in actionable[:40]:
            print("  [%s] %s (%s) -> %s" % (r[4], r[1], r[2], r[5]))
    if args.check and actionable:
        return 1
    return 0


if sys.exit(main()) if __name__ == "__main__" else None:
    pass
