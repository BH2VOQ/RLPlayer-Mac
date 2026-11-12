#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
"""
theme_parity.py -- verify native theme tokens equal the web CSS values, token by token.

Why this exists: the previous round proved "an identifier exists" but never proved
"the value matches web". Native dark was #121a19 (invented moss green) while web
dark is #161618 (near black); native used Georgia serif while web is all sans.
Both passed the identifier gate. Colour/geometry must be compared mechanically.

Truth source: src/net/ui_page.h CSS custom properties.
Native side:  rlplayer_native --dump-theme <style> <theme>  (JSON of tokenDump)

Usage:
  python3 tools/native_ui/theme_parity.py --bin build-mac/rlplayer_native
  python3 tools/native_ui/theme_parity.py --bin ... --check   # exit 1 on mismatch
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI_PAGE = os.path.join(ROOT, "src/net/ui_page.h")

# tokens that live only in :root (light/classic-light do not restate them)
ROOT_ONLY = {"r-lg", "r-md", "r-sm", "sidew", "sh1", "sh2"}


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_cpp_comments(src):
    """Remove // and /* */ but keep string literals; preserve newlines."""
    out, i, n, q = [], 0, len(src), None
    while i < n:
        c = src[i]
        if q:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1]); i += 2; continue
            if c == q:
                q = None
            i += 1; continue
        if c in "\"'":
            q = c; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2; continue
        out.append(c); i += 1
    return "".join(out)


def norm_color(v):
    """'#rrggbb' | 'rgba(r,g,b,a)' | 'rgb(...)' -> 'R,G,B,A' (3dp alpha)."""
    v = v.strip()
    m = re.fullmatch(r"#([0-9a-fA-F]{6})", v)
    if m:
        h = m.group(1)
        return "%d,%d,%d,1.000" % (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    m = re.fullmatch(r"rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)", v)
    if m:
        r, g, b = (int(round(float(m.group(k)))) for k in (1, 2, 3))
        a = float(m.group(4)) if m.group(4) else 1.0
        return "%d,%d,%d,%.3f" % (r, g, b, a)
    return None


def norm_value(v):
    """Colour, linear-gradient, or px length -> canonical string."""
    v = v.strip()
    c = norm_color(v)
    if c:
        return c
    if v.startswith("linear-gradient"):
        inner = v[v.index("(") + 1: v.rindex(")")]
        parts = split_top(inner)
        deg = 180
        if parts and re.fullmatch(r"[\d.]+deg", parts[0].strip()):
            deg = int(float(parts[0].strip()[:-3])); parts = parts[1:]
        # web gradients here are 2-stop; take first/last colour stop
        stops = [re.split(r"\s+", p.strip())[0] for p in parts if p.strip()]
        cs = [norm_color(s) for s in stops]
        cs = [x for x in cs if x]
        if len(cs) >= 2:
            return "grad:%d;%s;%s" % (deg, cs[0], cs[-1])
        return None
    m = re.fullmatch(r"([\d.]+)px", v)
    if m:
        f = float(m.group(1))
        return "%g" % f
    return None


def split_top(s):
    """Split on commas not inside parentheses."""
    out, depth, cur = [], 0, []
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


def concatenated_literals(src):
    """Join adjacent C++ string literals into one CSS text.

    Why: web writes CSS as several adjacent literals per statement, e.g.
        h += ":root{color-scheme:dark;"
             "--bg:#161618;--bg2:#1e1e22;"
             "}";
    A regex over single literals only sees ":root{color-scheme:dark;" and finds
    no custom properties -- which made this gate report 43 phantom "invented"
    tokens on its first run. Concatenation is required to read the real CSS.
    """
    pieces = []
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', src):
        s = m.group(1)
        # unescape the handful of sequences the CSS uses
        s = s.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"').replace('\\\\', '\\')
        pieces.append(s)
    return "".join(pieces)


def parse_css_blocks(src):
    """selector -> {token: raw_value}; later blocks override earlier ones."""
    css = concatenated_literals(src)
    blocks = []
    for m in re.finditer(r'([^{}]+)\{([^{}]*)\}', css):
        sel, body = m.group(1).strip(), m.group(2)
        # selector must look like a selector, not stray JS/C++ text
        # The first block's selector carries the preceding markup
        # ("</script><style>:root"). Keep only the selector tail.
        if ">" in sel:
            sel = sel[sel.rindex(">") + 1:].strip()
        sel = sel.split("\n")[-1].strip()
        toks = {}
        for decl in body.split(";"):
            if ":" not in decl:
                continue
            k, _, val = decl.partition(":")
            k = k.strip()
            if k.startswith("--"):
                toks[k[2:]] = val.strip()
        if toks:
            blocks.append((sel, toks))
    return blocks


def web_tokens(style, theme):
    """Resolve the cascade the same way the browser does for our selectors."""
    src = strip_cpp_comments(read(UI_PAGE))
    blocks = parse_css_blocks(src)
    resolved = {}
    for sel, toks in blocks:
        s = sel.replace(" ", "")
        take = False
        if s == ":root":
            take = True
        elif s == "html[data-theme=light]":
            take = (theme == "light")
        elif s == "html[data-uistyle=classic]":
            take = (style == "classic")
        elif s == "html[data-uistyle=classic][data-theme=light]":
            take = (style == "classic" and theme == "light")
        if take:
            resolved.update(toks)
    out = {}
    for k, v in resolved.items():
        nv = norm_value(v)
        if nv is not None:
            out[k] = nv
    return out


def native_tokens(binary, style, theme):
    r = subprocess.run([binary, "--dump-theme", style, theme],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise SystemExit("native --dump-theme failed: " + r.stderr[:400])
    # stdout may carry unrelated log lines; take the last JSON object
    txt = r.stdout.strip()
    start = txt.find("{")
    if start < 0:
        raise SystemExit("no JSON in --dump-theme output: " + txt[:300])
    return json.loads(txt[start:])


# tokens the native side intentionally does not expose (user decision, documented)
SKIP = {
    "sh1", "sh2",              # box-shadow composites: drawn via CALayer, not a colour token
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "build-mac/rlplayer_native"))
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.bin):
        raise SystemExit("binary not found: " + args.bin)

    total_bad = 0
    for style in ("apple", "classic"):
        for theme in ("dark", "light"):
            w = web_tokens(style, theme)
            n = native_tokens(args.bin, style, theme)
            bad = []
            checked = 0
            for k in sorted(n):
                if k in SKIP:
                    continue
                if k not in w:
                    bad.append("%s: web has no such token (native invented it)" % k)
                    continue
                checked += 1
                if w[k] != n[k]:
                    bad.append("%s: web=%s native=%s" % (k, w[k], n[k]))
            total_bad += len(bad)
            print("%-8s %-6s checked=%-3d mismatch=%d" % (style, theme, checked, len(bad)))
            for b in bad:
                print("    " + b)
            if args.verbose and not bad:
                print("    all tokens equal web CSS")
    print("")
    print("theme parity: %s" % ("OK" if total_bad == 0 else "FAIL (%d mismatches)" % total_bad))
    return 1 if total_bad else 0


if __name__ == "__main__":
    sys.exit(main())
