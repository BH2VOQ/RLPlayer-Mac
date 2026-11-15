#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
"""
behavior_scan.py -- web event bindings vs native behavior: ONE ROW PER BINDING POINT.

2026-11 upgrade (web-parity audit)
----------------------------------
The old scanner collapsed every D(id) binding to a single row per id (164 web
bindings -> 50 rows), and judged done by looking for @selector/target/action
anywhere in a +/-1800 character window around a native identifier literal. Two
things were wrong with that:

  1. the stripper used to clean ui_script.h lost its quote state inside template
     literals and passed a stale offset on -- it silently dropped 110 of the
     bound ids and reported wrong line numbers. Every binding point is now
     extracted with parity_scan's newline-preserving stripper.
  2. a 1800-char text window is not an anchor. Evidence is now either the
     identifier's own line, or the exact native wiring/dispatch line that proves
     the control reacts (same statement / same object property / same function
     body / identifier comparison branch), or a @selector wiring point.
     Two more precise forms (2026-11-16), still without any character window:
       - the nearest assignment of the SAME object variable in the same
         function body carries target:/action:/@selector (factory-built
         controls, e.g. autoPre = [NSButton buttonWithTitle:... action:...]);
       - a factory call passes both the control id literal and its @selector
         (popupForKey:/switchForKey:/primaryButton:ident:, ...).

Rows: one per unique (web id, event). Evidence columns keep both anchors:
    web_anchor      src/net/ui_script.h:<line>      (the binding itself)
    native_anchor   <view>.mm:<line>                (wiring / dispatch / selector)
                    or 无对应实现(...)              (na rows only)

States
------
  done      a native wiring or dispatch path was found at a precise anchor
  na        the control is deliberately web-only (evidence in behavior_na.tsv)
  missing   no native anchor at all, or the identifier exists but nothing reacts
            -> actionable gap

What this still is NOT: a runtime proof. Runtime evidence stays in
RLPFunctionalAudit; this table is a review queue whose claims are greppable.

Sources
-------
  web      : src/net/ui_script.h  -- D(id).on<event> = ...
              (addEventListener('event') bindings are out of this table's scope)
  native   : tools/native_ui/*.mm (RLPFunctionalAudit.mm excluded: it is an
             assertion harness, not a behavior path)
  mapping  : docs/native-ui/parity.tsv  (ctrl rows: web id -> native anchor)
             docs/native-ui/behavior_na.tsv (bind rows with no native control)

Usage:
  python3 tools/native_ui/behavior_scan.py            # write docs/native-ui/behavior.tsv
  python3 tools/native_ui/behavior_scan.py --check     # exit 1 on gaps / bad evidence
"""
import argparse
import os
import re
import sys

import parity_scan as ps

DOCS_DIR = ps.DOCS_DIR
NATIVE_DIR = ps.NATIVE_DIR
UI_SCRIPT = ps.UI_SCRIPT
PARITY = os.path.join(DOCS_DIR, "parity.tsv")
NA_PATH = os.path.join(DOCS_DIR, "behavior_na.tsv")
OUT_PATH = os.path.join(DOCS_DIR, "behavior.tsv")

# 自检 harness 只做断言（CK(...)），不接线也不分派 —— 拿它当行为证据会自我循环。
AUDIT_ONLY = "RLPFunctionalAudit.mm"

EVENTS = ("click change input keydown keyup keypress dblclick contextmenu "
          "mousedown mouseup mouseenter mouseleave mousemove wheel dragstart "
          "dragover drop focus blur submit scroll pointerdown pointerup "
          "pointercancel").split()

BIND_RE = re.compile(r"D\('([A-Za-z0-9_]+)'\)\s*\.\s*on([A-Za-z]+)\s*=")
# 一条语句里的接线：target:/action:/addTarget:/initWithTarget:，或属性式 action=。
WIRING_STMT_RE = re.compile(
    r"\b(?:target|action|addTarget|initWithTarget|setAction|doubleAction)\s*:|"
    r"\b(?:action|target|doubleAction|onClick|onTap|onCommit|onLiveChange|"
    r"onSeek|onSelect)\s*=|addGestureRecognizer")
# 标识符分派：if ([sender.identifier isEqualToString:@"x"]) { ... }
DISPATCH_TMPL = r"(?:isEqualToString:|isEqual:)\s*@\"%s\""
# 同一语句里的接线强度补充：变量构造语句里的 target:/action:/@selector，
# 以及块属性 cv.onClick = ^{...}。用于「工厂建控件、identifier 隔几行才赋值」。
ASSIGN_WIRING_RE = re.compile(
    r"\b(?:action|target|addTarget|initWithTarget|setAction|doubleAction|"
    r"onClick|onTap|onCommit|onLiveChange|onSeek|onSelect)\s*[:=]"
    r"|@selector\s*\(")
FACTORY_SELECTOR_RE = re.compile(r"@selector\s*\(")
# 纯别名（self.coverView = cv）：再看别名变量在同一个函数体里的属性式接线。
ALIAS_RHS_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# 控件 identifier 的字面量映射表：@{ @"sp_x": @"sp_x" }（key -> web id）。
CTRL_ID_MAP_RE = re.compile(r'@"(sp_[A-Za-z0-9_]+)"\s*:\s*@"([^"]*)"')


def read(p):
    return ps.read(p)


def scan_bindings():
    """(web_id, event) -> [line, raw_occurrences]. One row per binding point."""
    js = ps.strip_js_comments(read(UI_SCRIPT))
    out = {}
    raw = 0
    for m in BIND_RE.finditer(js):
        wid, ev = m.group(1), m.group(2)
        raw += 1
        if ev not in EVENTS:
            raise SystemExit("unknown web event %r on %r" % (ev, wid))
        key = (wid, ev)
        if key in out:
            out[key][1] += 1
        else:
            out[key] = [ps.line_of(js, m.start()), 1]
    return out, raw


def nth_line_start(src, ln):
    """Offset of the start of 1-based line ln."""
    start = 0
    for _ in range(ln - 1):
        start = src.find("\n", start) + 1
    return start


class NativeIndex:
    """Identifier / selector occurrences with precise wiring classification."""

    def __init__(self, targets=None):
        self.ident = {}      # token -> [(file, line, note)]
        self.factory = {}    # token -> [(file, line, note)]（工厂调用点）
        self.sel = {}        # selector -> "file:line (impl file:line)"
        self.targets = set(targets or ())   # parity.tsv 里的原生 token
        self._scan()

    @staticmethod
    def _wiring_in_file(flat, segment):
        for prop in ("action", "target", "doubleAction", "onClick", "onTap",
                     "onCommit", "onLiveChange", "onSeek", "onSelect"):
            m = re.search(r"\b%s\s*\.\s*%s\s*=" % (re.escape(segment), prop), flat)
            if m:
                return m.start()
        m = re.search(r"addTarget:\s*%s\b" % re.escape(segment), flat)
        return m.start() if m else None

    @staticmethod
    def _object_of(stmt_mask):
        m = re.search(r"([A-Za-z_][A-Za-z0-9_.]*)\s*\.identifier\s*(?:=|:)", stmt_mask)
        return m.group(1) if m else None

    @staticmethod
    def _lhs_is_var(lhs, seg):
        return re.search(r"(?:\A|[.\s*])%s\s*$" % re.escape(seg), lhs) is not None

    @staticmethod
    def _var_wiring_in_body(flat, body, seg, occurrence_line):
        """最近一次把 seg 变量/属性赋值成控件的语句，且该语句自带接线。

        identity 是「同一个函数体 + 同一个对象变量名 + 距离 identifier 赋值最近的
        那次赋值」，不是按字符/行窗口放宽：工厂调用往往把 target/action 写在构造
        语句里，identifier 隔几行（最多 6 行，实测 qSaveSq）才赋值。
        返回 (label, line) 或 None；最近的赋值没接线就不再往外找。
        """
        s, e = body
        cands = []
        for m in re.finditer(r"\b%s\s*=" % re.escape(seg), flat[s:e]):
            pos = s + m.start()
            stmt_s, stmt_e = ps.stmt_of(flat, pos)
            eq = flat.find("=", pos, stmt_e)
            if eq < 0 or not NativeIndex._lhs_is_var(
                    flat[stmt_s:eq].rstrip(), seg):
                continue
            cands.append((abs(ps.line_of(flat, pos) - occurrence_line),
                          pos, stmt_s, stmt_e))
        if not cands:
            return None
        _dist, pos, _stmt_s, stmt_e = min(cands)
        tail = flat[pos:stmt_e]
        m = ASSIGN_WIRING_RE.search(tail)
        if m:
            return "同体构造接线", ps.line_of(flat, pos + m.start())
        # 纯别名：self.coverView = cv; 再看 cv 在同一个函数体里的 onClick/action 接线
        eq = tail.find("=")
        if eq < 0:
            return None
        alias = ALIAS_RHS_RE.fullmatch(tail[eq + 1:].strip())
        if not alias:
            return None
        av = alias.group(0)
        pat = re.compile(
            r"\b%s\s*\.\s*(?:onClick|onTap|onCommit|onLiveChange|onSeek|"
            r"onSelect|action|target|doubleAction)\s*=|addTarget:\s*%s\b"
            % (re.escape(av), re.escape(av)))
        m2 = pat.search(flat, s, e)
        if m2:
            return "别名接线", ps.line_of(flat, m2.start())
        return None

    def _classify(self, name, masked, flat, ranges, token, pos):
        stmt_s, stmt_e = ps.stmt_of(flat, pos)
        stmt = flat[stmt_s:stmt_e]
        body = ps.enclosing_body(flat, ranges, pos)
        if WIRING_STMT_RE.search(stmt):
            return "同语句接线", ps.line_of(masked, pos)
        obj = self._object_of(masked[stmt_s:stmt_e])
        if obj:
            seg = obj.split(".")[-1]
            hit = self._wiring_in_file(flat, seg)
            if hit is not None:
                return "对象 %s 的接线" % obj, ps.line_of(flat, hit)
            if body is not None:
                # 同一函数体内 ±5 行、提到同一对象变量的接线
                # （构造语句赋 action、下一行才赋 identifier 的写法）
                occurrence_line = ps.line_of(masked, pos)
                first = ps.line_of(masked, body[0])
                last = ps.line_of(masked, body[1])
                for ln in range(max(first, occurrence_line - 5),
                                min(last, occurrence_line + 5) + 1):
                    start = nth_line_start(masked, ln)
                    end = masked.find("\n", start)
                    end = len(masked) if end < 0 else end
                    text = flat[start:end]
                    if seg in text and WIRING_STMT_RE.search(text):
                        return "构造处接线", ln
                hit = self._var_wiring_in_body(
                    flat, body, seg, occurrence_line)
                if hit:
                    return hit
        # 标识符分派分支：比较同一个 identifier 并继续发消息
        if re.search(DISPATCH_TMPL % re.escape(token), stmt):
            if body is not None and (
                    re.search(r"\[[A-Za-z_]", flat[body[0]:body[1]])
                    or re.search(r"\bRLP[A-Za-z0-9_]*\s*\(", flat[body[0]:body[1]])):
                return "标识符分派", ps.line_of(masked, pos)
        return None, None

    def _scan(self):
        files = []
        id_map = {}
        for name, raw in ps.native_sources():
            if name == AUDIT_ONLY:
                continue
            masked = ps.strip_c_comments(raw)
            flat = ps.mask_strings(masked)
            ranges = ps.body_ranges(flat)
            files.append((name, masked, flat, ranges))
            for m in CTRL_ID_MAP_RE.finditer(masked):
                id_map.setdefault(m.group(1), m.group(2))
        for name, masked, flat, ranges in files:
            for m in ps.IDENT_RE.finditer(masked):
                token, pos = m.group(1), m.start()
                label, anchor = self._classify(name, masked, flat, ranges, token, pos)
                if not label:
                    continue
                self.ident.setdefault(token, []).append(
                    (name, ps.line_of(masked, pos),
                     "%s（接线 %s:%d）" % (label, name, anchor)))
            # 工厂调用点：同一条语句里既给出控件 id 字面量、又给出 @selector
            # （popupForKey:/switchForKey:/primaryButton:ident: 等工厂方法把
            # target/action 收在调用里，identifier 由工厂内部按 key 赋值）。
            for m in re.finditer(r'@"([^"\n]+)"', masked):
                tok = m.group(1)
                web_tok = id_map.get(tok, tok)
                if self.targets and web_tok not in self.targets:
                    continue
                stmt_s, stmt_e = ps.stmt_of(flat, m.start())
                sel = FACTORY_SELECTOR_RE.search(masked, stmt_s, stmt_e)
                if not sel:
                    continue
                self.factory.setdefault(web_tok, []).append(
                    (name, ps.line_of(masked, sel.start()),
                     "工厂调用接线（同一次调用给出 identifier 与 @selector）"))
        self.sel = ps.scan_selectors()

    def behavior_anchor(self, token):
        """First precise wiring/dispatch anchor for an identifier, or None."""
        occ = sorted(self.ident.get(token, []), key=lambda t: t[1])
        if not occ:
            fac = sorted(self.factory.get(token, []), key=lambda t: t[1])
            if not fac:
                return None
            name, line, note = fac[0]
            return ("%s:%d" % (name, line), note)
        name, line, note = occ[0]
        return ("%s:%d" % (name, line), note)

    def has_identifier(self, token):
        return token in self.ident


def load_na():
    """behavior_na.tsv columns: kind, web_item, web_anchor, native_anchor, reason."""
    out = {}
    if os.path.exists(NA_PATH):
        for line in read(NA_PATH).split(ps.NL):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) < 5 or cols[0].strip() == "kind":
                continue
            out[(cols[0].strip(), cols[1].strip())] = {
                "web": cols[2].strip(), "native": cols[3].strip(),
                "reason": " ".join(cols[4:]).strip()}
    return out


def load_parity_ctrl():
    """parity.tsv ctrl rows: web id -> (native_item, status, evidence)."""
    out = {}
    if not os.path.exists(PARITY):
        raise SystemExit("parity.tsv missing -- run parity_scan.py first")
    for line in read(PARITY).split(ps.NL):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 5 or cols[0] != "ctrl":
            continue
        out[cols[1]] = (cols[2], cols[3], cols[4])
    return out


def verify_na_anchor(item, meta):
    bad = []
    wa = meta["web"]
    m = re.match(r"(?:src/net/ui_script\.h|ui_script\.h):(\d+)$", wa)
    if not m:
        bad.append("web anchor %r is not ui_script.h:line" % wa)
    else:
        text = ps.read(UI_SCRIPT).split(ps.NL)[int(m.group(1)) - 1]
        if ("D('%s')" % item) not in text:
            bad.append("web anchor %r does not contain D('%s')" % (wa, item))
    na = meta["native"]
    if not na:
        bad.append("native anchor is empty")
    elif not na.startswith("无对应实现"):
        m2 = re.match(r"([A-Za-z0-9_./\-]+):(\d+)(?:\s.*)?$", na)
        if not m2:
            bad.append("native anchor %r is neither file:line nor 无对应实现" % na)
        else:
            path = ps._src_of(m2.group(1))
            if path is None:
                bad.append("native anchor %r names an unknown file" % na)
            elif ps._line_text(path, int(m2.group(2))) is None:
                bad.append("native anchor %r is out of range" % na)
    if not meta["reason"].strip():
        bad.append("na without a reason")
    return bad


def build_rows():
    binds, raw = scan_bindings()
    na = load_na()
    parity = load_parity_ctrl()
    targets = {p[0] for p in parity.values()
               if p[0] and p[0] != "--" and not p[0].startswith("sel:")}
    index = NativeIndex(targets)
    rows = []
    bad_na = []
    for key, (line, occurrences) in sorted(binds.items(), key=lambda kv: (kv[1][0], kv[0])):
        wid, ev = key
        wanchor = "src/net/ui_script.h:%d" % line
        meta = na.get(("bind", wid))
        if meta is not None:
            problems = verify_na_anchor(wid, meta)
            bad_na.extend("%s: %s" % (wid, p) for p in problems)
            if not problems:
                rows.append(("bind", wid, ev, wanchor, "--", "na",
                             meta["native"], meta["reason"]))
            continue
        prow = parity.get(wid)
        if prow is None:
            rows.append(("bind", wid, ev, wanchor, "--", "missing",
                         "无对应实现（parity.tsv 没有该控件的 ctrl 行）"))
            continue
        target, pstatus, _pev = prow
        if pstatus in ("missing", "removed"):
            rows.append(("bind", wid, ev, wanchor, target, "missing",
                         "无对应实现（parity status=%s）" % pstatus))
            continue
        if target.startswith("sel:"):
            sel = target[4:]
            if sel in index.sel:
                rows.append(("bind", wid, ev, wanchor, target, "done",
                             index.sel[sel], "selector 接线；原生无可查询 identifier"))
            else:
                rows.append(("bind", wid, ev, wanchor, target, "missing",
                             "无对应实现（selector %s 没有接线证据）" % sel))
            continue
        anchor = index.behavior_anchor(target)
        if anchor is None:
            rows.append(("bind", wid, ev, wanchor, target, "missing",
                         "无对应实现（identifier %s 存在但没有接线/分派）" % target))
            continue
        rows.append(("bind", wid, ev, wanchor, target, "done", anchor[0], anchor[1]))
    bound_ids = {wid for wid, _ev in binds}
    stale = [k for k in na if (not k[0] == "bind") or k[1] not in bound_ids]
    return rows, raw, bad_na, stale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    rows, raw, bad_na, stale = build_rows()
    counts = {}
    for r in rows:
        counts[r[5]] = counts.get(r[5], 0) + 1
    missing = [r for r in rows if r[5] == "missing"]
    if not args.check:
        os.makedirs(DOCS_DIR, exist_ok=True)
        with open(OUT_PATH, "w", encoding="utf-8") as f:
            f.write("# kind\tweb_item\tevent\tweb_anchor\tnative_item\tstatus\t"
                    "native_anchor\tnote" + ps.NL)
            f.write("# GENERATED by tools/native_ui/behavior_scan.py -- do not hand-edit"
                    + ps.NL)
            for r in rows:
                r = tuple(c.replace("\t", " ") for c in r)
                f.write("\t".join(r) + ps.NL)
        print("wrote %s" % OUT_PATH)
    print("behavior: bindpoints=%d (raw .on<event> hits=%d) done=%d na=%d missing=%d"
          % (len(rows), raw, counts.get("done", 0), counts.get("na", 0),
             counts.get("missing", 0)))
    if stale:
        print("  stale behavior_na entries: %s" % ", ".join(k[1] for k in stale))
    if bad_na:
        print("")
        print("na evidence failures:")
        for b in bad_na:
            print("  " + b)
    if missing:
        print("")
        print("missing detail:")
        for r in missing:
            print("  %-20s %-10s %s" % (r[1], r[2], r[6]))
    return 1 if (missing or bad_na or stale) else 0


if __name__ == "__main__":
    sys.exit(main())
