#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
"""Real null-sink playback: prove advancement, not just the reported mode."""
import argparse
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('url')
p.add_argument('state_dir', type=Path)
a = p.parse_args()
results = []

def api(route, body=None):
    data = None if body is None else urllib.parse.urlencode(body).encode()
    request = urllib.request.Request(a.url.rstrip('/') + route, data=data)
    with urllib.request.urlopen(request, timeout=10) as r:
        return json.load(r)

def check(ok, what, detail):
    results.append({'ok': bool(ok), 'what': what, 'detail': detail})
    print(('PASS ' if ok else 'FAIL ') + what + ': ' + str(detail))

kv = api('/api/settings').get('kv', {})
if kv.get('backend') != 'null':
    raise SystemExit('ABORT: isolated test must use backend=null')
files = sorted((a.state_dir / 'music').glob('*.wav'))
if len(files) < 3:
    raise SystemExit('ABORT: need three isolated WAV fixtures')
log = a.state_dir / 'rlplayer-playback.log'
try:
    for mode in range(4):
        api('/api/stop', {})
        api('/api/clear', {})
        api('/api/playmode?mode=0', {})
        for f in files:
            assert api('/api/add', {'file': str(f)})['ok']
        api('/api/playmode?mode=' + str(mode), {})
        offset = log.stat().st_size if log.exists() else 0
        order = api('/api/queue')['items']
        api('/api/play', {'file': order[0], 'backend': 'null', 'volume': '-60',
                          'rate': 'follow', 'filter': '', 'shaper': 'none'})
        deadline = time.monotonic() + 5
        names = []
        while time.monotonic() < deadline:
            text = log.read_bytes()[offset:].decode('utf-8', 'replace')
            names = [ln.split('START file=', 1)[1].split(' cue=', 1)[0].strip()
                     for ln in text.splitlines() if 'START file=' in ln]
            if (mode == 0 and len(names) >= 3 and not api('/api/status').get('playing')) or (mode != 0 and len(names) >= 4):
                break
            time.sleep(.08)
        api('/api/stop', {})
        if mode == 0:
            check(names == order, 'sequential plays once then stops', names)
        elif mode == 1:
            check(len(names) >= 4 and names[:4] == order + [order[0]], 'list repeat wraps to first', names)
        elif mode == 2:
            check(len(names) >= 4 and all(n == order[0] for n in names), 'single repeat stays on same item', names)
        else:
            check(len(names) >= 4 and all(x != y for x, y in zip(names, names[1:])), 'random never immediately repeats current', names)
        check(not api('/api/status').get('error'), f'mode {mode} has no playback error', api('/api/status').get('error'))
finally:
    api('/api/stop', {})
    api('/api/playmode?mode=0', {})
    (a.state_dir / 'behavior-result.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(r['ok'] for r in results) else 1)
