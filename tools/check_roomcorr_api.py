#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
"""R-1 生产端点判据：铁律 1 的"确认前绝不发声"必须是**可测的**。

本判据只打 HTTP，**不设 confirm=1 就绝不触发测量**；因此全程不会向任何设备出声。
（需要真出声的完整测量不在自动化里跑：那要用户当面授权。）
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

base = sys.argv[1].rstrip('/')
results = []


def call(route, body=None, method=None):
    data = None if body is None else urllib.parse.urlencode(body).encode()
    req = urllib.request.Request(base + route, data=data, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        raw = e.read().decode('utf-8', 'replace')
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {'_raw': raw}


def ck(ok, what, detail):
    results.append({'ok': bool(ok), 'what': what, 'detail': detail})
    print(('PASS ' if ok else 'FAIL ') + what + ': ' + json.dumps(detail, ensure_ascii=False)[:220])


# 1) 布局列表
st, d = call('/api/roomcorr/layouts')
names = [x['name'] for x in d.get('layouts', [])]
ck(st == 200 and d.get('ok') and len(names) >= 6, 'layout list exposes 2.0~7.1.4', names)

# 2) 计划：只读，且必须披露设备/时长/电平/横幅
st, p = call('/api/roomcorr/plan?layout=2.0&sec=1')
ck(st == 200 and p.get('ok') is True, 'plan is readable without starting anything', p.get('ok'))
ck(p.get('chCount') == 2 and p.get('levelDbfs') == -20,
   'plan reports channel count and the -20 dBFS measurement level', {'ch': p.get('chCount'), 'level': p.get('levelDbfs')})
ck(bool(p.get('playDevice')) and bool(p.get('captureDevice')),
   'plan names the actual play and capture devices', {'play': p.get('playDevice'), 'cap': p.get('captureDevice')})
w = p.get('warning') or ''
ck('可听扫频' in w and 'dBFS' in w and '共享' in w,
   'warning banner states audible sweep, level, and shared mode (iron rule 1)', w[:150])
ck(p.get('needsConfirm') is True, 'plan says confirmation is required', p.get('needsConfirm'))

# 3) 关键：不带 confirm 必须被拒绝（428），且**不启动**
st, d = call('/api/roomcorr/measure?layout=2.0&sec=1', {})
ck(st == 428 and d.get('ok') is False and d.get('needsConfirm') is True,
   'measure WITHOUT confirm is refused with 428 (never makes sound)', {'status': st, 'body': d.get('error', '')[:80]})
st, s = call('/api/roomcorr/status')
ck(s.get('phase') == 'idle', 'refused request left the controller idle (nothing started)',
   {'phase': s.get('phase'), 'done': s.get('channelsDone')})

# 4) 非法参数被拒绝，而不是默默用默认值开跑
st, d = call('/api/roomcorr/plan?layout=9.9&sec=1')
ck(st == 400 and d.get('ok') is False and bool(d.get('error')),
   'unknown layout is rejected, not silently defaulted', d.get('error'))
st, d = call('/api/roomcorr/plan?layout=2.0&sec=999')
ck(st == 400 and d.get('ok') is False, 'absurd sweep length is rejected', d.get('error'))

# 5) 取消端点可用（幂等）
st, d = call('/api/roomcorr/cancel', {})
ck(st == 200 and d.get('ok') is True, 'cancel endpoint is available and idempotent', d)

# 6) 只读端点不允许用 GET 触发测量（副作用端点必须 POST）
st, d = call('/api/roomcorr/measure?layout=2.0&sec=1&confirm=1', None, method='GET')
ck(st in (405, 428) and d.get('ok') is not True,
   'GET cannot start an audible measurement', {'status': st, 'body': str(d)[:120]})

print('\n合计 %d/%d 通过' % (sum(1 for r in results if r['ok']), len(results)))
raise SystemExit(0 if all(r['ok'] for r in results) else 1)
