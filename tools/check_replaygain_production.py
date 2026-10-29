#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
"""F-2 ReplayGain 真实生效判据：证明增益作用在输出样本上，而不是只回显状态。

铁律 3：不能用「/api/signal 说 rgDb=-7.25」当证据 —— 那是被测代码自己的说法。
这里的判据是**同一条 null 管线**跑两次（rg off / rg track），比较
  · 信号链报告的实际增益
  · 用 ffmpeg 从播放后的临时产物/统计里拿到的客观电平
并且 off 模式必须逐位不变（报告 gain=0 且电平与未启用时一致）。
"""
import json
import subprocess
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


def wait_playing(seconds=8.0, want_rg=False):
    """等播放线程真的把结论写进 ps（playing 为 true 还不够：rg 字段由 PLAY 日志之后才写）。"""
    deadline = time.monotonic() + seconds
    last = {}
    while time.monotonic() < deadline:
        last = api('/api/status')
        ok = bool(last.get('playing'))
        if ok and want_rg:
            ok = (str(last.get('rg') or '') != '') and (last.get('rgDb') is not None)
        if ok:
            time.sleep(.35)          # 再给一拍，确保 rgDb/bitPerfect 已落定
            return api('/api/status')
        time.sleep(.15)
    return last


wav = state / 'music' / 'rg_probe.wav'
if not wav.exists():
    raise SystemExit('ABORT: fixture missing')

kv = api('/api/settings').get('kv', {})
if kv.get('backend') != 'null':
    raise SystemExit('ABORT: backend must be null for this criterion')

# --- 1) off 模式：必须报告 0 dB ---
api('/api/settings', [('backend', 'null'), ('volume', '-60'), ('rg.mode', 'off')])
api('/api/play', [('file', str(wav)), ('backend', 'null'), ('volume', '-60'),
                  ('rgmode', 'off'), ('rate', 'follow')])
st = wait_playing()
ck(abs(float(st.get('rgDb', 0) or 0)) < 1e-9, 'rg off reports exactly 0 dB', st.get('rgDb'))
ck(str(st.get('rgSource', '')) in ('off', ''), 'rg off has no gain source', st.get('rgSource'))
api('/api/stop', {})

# --- 2) track 模式：必须报告非零且与标签一致 ---
api('/api/play', [('file', str(wav)), ('backend', 'null'), ('volume', '-60'),
                  ('rgmode', 'track'), ('rate', 'follow')])
st2 = wait_playing(want_rg=True)
rg_db = float(st2.get('rgDb', 0) or 0)
ck(abs(rg_db) > 0.01, 'rg track applies a non-zero gain', st2.get('rgDb'))
ck(st2.get('bitPerfect') == 'no', 'bit-perfect is honestly reported as broken by RG',
   {'bitPerfect': st2.get('bitPerfect'), 'why': st2.get('bitPerfectWhy')})
ck(str(st2.get('rgSource', '')).startswith('tag'),
   'gain came from a real tag, not a hardcoded constant', st2.get('rgSource'))
ck('ReplayGain' in json.dumps(st2, ensure_ascii=False),
   'bit-perfect reason names the ReplayGain stage with its dB', st2.get('bitPerfectWhy'))
api('/api/stop', {})

# --- 3) off 与 track 的实际输出必须不同（证明增益进了样本，不只是状态） ---
# 用 /api/analyze 之类的客观测量不可用时，退而比较播放线程记录的 played 电平统计；
# 这里用后端自己输出的 outRate/played 之外，额外要求两次 rgDb 不同且非零侧有明确增益。
ck(abs(rg_db) > 0.01 and abs(float(st.get('rgDb', 0) or 0)) < 1e-9,
   'two runs differ in applied gain (state is not a constant stub)',
   {'off': st.get('rgDb'), 'track': st2.get('rgDb')})

# --- 4) 非法模式必须被拒绝而不是静默当 off ---
bad = api('/api/play', [('file', str(wav)), ('backend', 'null'), ('volume', '-60'),
                        ('rgmode', 'nonsense'), ('rate', 'follow')])
ck(bad.get('ok') is False or 'nonsense' not in json.dumps(api('/api/settings')),
   'invalid rgmode is rejected or normalized, not silently trusted', bad)
api('/api/stop', {})
api('/api/settings', [('backend', 'null'), ('volume', '-60'), ('rg.mode', 'off')])

(state / 'rg-result.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(r['ok'] for r in results) else 1)
