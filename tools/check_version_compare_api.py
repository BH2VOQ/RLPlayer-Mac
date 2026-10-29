#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
"""F-8 functional endpoint test with generated, isolated version fixtures."""
import json
import math
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import wave
from pathlib import Path

url = sys.argv[1].rstrip('/')
out = Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
files = []
for name, gain in [('原版.wav', 1.0), ('另一版本.wav', .7)]:
    f = out / name
    with wave.open(str(f), 'wb') as w:
        w.setparams((2, 2, 24000, 0, 'NONE', 'not compressed'))
        data = bytearray()
        for i in range(96000):
            t = i / 24000
            amp = .0007 * (0.6 + .3 * math.sin(t*4.7) + .1*math.cos(t*13.1))
            v = int(32767*gain*amp*(math.sin(t*2*math.pi*437)+.2*math.sin(t*2*math.pi*983)))
            data += struct.pack('<hh', v, v)
        w.writeframes(data)
    files.append(str(f))

def request(method, payload):
    body = None if payload is None else urllib.parse.urlencode(payload, doseq=True).encode()
    req = urllib.request.Request(url+'/api/compare', data=body, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)

results = []
def ck(ok, what, detail):
    results.append({'ok':bool(ok), 'what':what, 'detail':detail})
    print(('PASS ' if ok else 'FAIL ') + what + ': ' + json.dumps(detail,ensure_ascii=False))

st, data = request('POST', [('file', f) for f in files])
ck(st == 200 and data.get('ok') is True, 'two versions reach production comparison', {'status':st,'response':data if not data.get('ok') else 'ok'})
ck(len(data.get('versions',[])) == 2 and len(data.get('rows',[])) > 5, 'alignment and metric rows are populated', {'versions':len(data.get('versions',[])), 'rows':len(data.get('rows',[]))})
ck(len(data.get('ranking',[])) == 2 and bool(data.get('explanation')), 'scoring is invoked, not an empty comparison shell', {'ranking':data.get('ranking'), 'explanation':data.get('explanation')})
ck(data.get('sameTrack') is True and data.get('windowSec', 0) > 3, 'same-track alignment uses common interval', {'sameTrack':data.get('sameTrack'), 'windowSec':data.get('windowSec')})
for payload, label in [([('file',files[0])], 'one file rejected'), ([('file',files[0])]*9,'over eight rejected'), ([('file',files[0]),('file',str(out/'missing.wav'))], 'missing file rejected')]:
    _, bad = request('POST', payload)
    ck(bad.get('ok') is False and bool(bad.get('error')), label, bad)
st, data = request('GET', None)
ck(st == 405, 'GET cannot launch CPU-intensive comparison', {'status':st,'body':data})
(out/'api-result.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
raise SystemExit(0 if all(r['ok'] for r in results) else 1)
