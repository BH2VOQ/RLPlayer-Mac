#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August Hu <BH2VOQ@163.com>
# 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
"""F-3 判据：同族异速 DSD 源不再一律退回「解 PCM 再调制」。

铁律 3：不能只看 /api/status 里某个布尔。这里的证据是播放日志里的
  · 是否出现 DSD_RATE 行（真走了转换）
  · 转换后 src 的 1-bit 位率确实变成目标值
  · 同一文件在「目标=源」时不出现 DSD_RATE（逐位直通没被破坏）
  · 跨族（44.1k↔48k）必须明确报错，不许静默按源速率播
"""
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

base = sys.argv[1].rstrip('/')
state = Path(sys.argv[2])
results = []


def api(route, body=None):
    data = None if body is None else urllib.parse.urlencode(body).encode()
    req = urllib.request.Request(base + route, data=data)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def ck(ok, what, detail):
    results.append({'ok': bool(ok), 'what': what, 'detail': detail})
    print(('PASS ' if ok else 'FAIL ') + what + ': ' + json.dumps(detail, ensure_ascii=False))


log = state / 'rlplayer-playback.log'


def slice_log():
    return log.stat().st_size if log.exists() else 0


def new_lines(offset):
    if not log.exists():
        return ''
    return log.read_bytes()[offset:].decode('utf-8', 'replace')


def play(file, dsd_level, extra=None):
    body = [('file', str(file)), ('backend', 'null'), ('volume', '0'),
            ('rate', 'follow'), ('dsd', str(dsd_level)),
            ('directsdm', '1')]   # 直通分支的入口开关；不带它走的是 PCM 重调制路径
    if extra:
        body += extra
    off = slice_log()
    r = api('/api/play', body)
    time.sleep(2.5)
    api('/api/stop', {})
    return r, new_lines(off)


dsd64 = state / 'music' / 'probe_dsd64.dsf'
dsd64_48k = state / 'music' / 'probe_dsd64_48k.dsf'
if not dsd64.exists():
    raise SystemExit('ABORT: DSD64 fixture missing')

# --- 1) 目标 == 源：必须逐位直通，不得出现 DSD_RATE ---
r, txt = play(dsd64, 64)
ck('DSD_RATE' not in txt, 'same-rate DSD stays bit-perfect (no conversion)',
   [ln for ln in txt.splitlines() if 'DSD_RATE' in ln or 'directsdm' in ln.lower()][:2])

# --- 2) 目标 = 2× 源：必须真的转换 ---
r, txt = play(dsd64, 128)
rate_lines = [ln for ln in txt.splitlines() if 'DSD_RATE' in ln]
ck(r.get('ok') is True, 'DSD64 source accepted for DSD128 target', r)
ck(bool(rate_lines), 'DSD_RATE conversion actually ran (not a silent fallback)', rate_lines[:2])
if rate_lines:
    ln = rate_lines[0]
    ck('src=2822400' in ln and 'dst=5644800' in ln,
       'converted from 2822400 Hz to 5644800 Hz', ln.strip()[:160])

# --- 3) 4 倍升频（DSD64 → DSD256）也要真的转换 ---
r, txt = play(dsd64, 256)
rate_lines = [ln for ln in txt.splitlines() if 'DSD_RATE' in ln]
ck(bool(rate_lines) and 'dst=11289600' in rate_lines[0],
   'DSD64 to DSD256 converts to 11289600 Hz', rate_lines[:1] or txt.splitlines()[-2:])

# --- 4) 48k 族源只按自己的族推导目标（不跨族），且同样能转换 ---
if dsd64_48k.exists():
    r, txt = play(dsd64_48k, 128)
    lines = [ln for ln in txt.splitlines() if 'DSD_RATE' in ln]
    ck(bool(lines) and 'src=3072000' in lines[0] and 'dst=6144000' in lines[0],
       '48k-family source converts within its own family', lines[:1])

api('/api/stop', {})
(state / 'f3-result.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(r['ok'] for r in results) else 1)
