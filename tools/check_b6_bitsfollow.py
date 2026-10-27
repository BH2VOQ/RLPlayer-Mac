#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August Hu <BH2VOQ@163.com>
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# check_b6_bitsfollow.py — B-6「输出位深跟随源」的可复跑判据
#
# 判据来源：debug/20261027-04-实测反馈7条-修复任务书.md 第 6 条
#   「源是 24-bit 文件时 /api/status 报的实际输出位深 = 24；源是 16-bit 时 = 16；
#     不许用同一个值应付（要真的随源变）」
#
# 为什么这样判（铁律 3）：
#   只看「下拉里有『跟随源』」证明不了行为；只看 /api/settings 的 bits=-1 也只证明存了值。
#   所以这里造两份**容器位深真的不同**的静音 WAV（16-bit / 24-bit），分别播放，
#   断言 /api/status 的 outBits 随之变化。同一个值应付不了两份不同的源。
#
# 铁律 1：全部静音（全零样本）+ backend=null，绝不打开物理音频设备。
# 用法：python3 tools/check_b6_bitsfollow.py [port]
# 退出码：0 = 全绿；1 = 有红；2 = 环境问题

import json
import sys
import tempfile
import urllib.parse
import urllib.request
import wave
from pathlib import Path

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19216
BASE = 'http://127.0.0.1:%d' % PORT
results = []


def ck(ok, what, detail=''):
    results.append((ok, what, detail))
    print(('  [PASS] ' if ok else '  [FAIL] ') + what + (('  — ' + detail) if detail else ''))


def call(path, body=None):
    data = body.encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 method='POST' if body is not None else 'GET')
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode('utf-8', 'replace'))


def make_silence(path, bits):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(bits // 8)
        w.setframerate(44100)
        w.writeframes(b'\x00' * (44100 * 2 * (bits // 8)))


print('  目标 %s' % BASE)
kv = call('/api/settings').get('kv') or {}
ck((kv.get('backend') or '').lower() == 'null', '前置：后端为 null（不出声，铁律 1）', 'backend=' + str(kv.get('backend')))
if (kv.get('backend') or '').lower() != 'null':
    print('  中止：backend 不是 null，拒绝播放。')
    sys.exit(2)

tmp = Path(tempfile.mkdtemp(prefix='rlplayer_b6_'))
paths = {}
for bits in (16, 24):
    paths[bits] = tmp / ('silence%d.wav' % bits)
    make_silence(paths[bits], bits)
    print('  素材 %d-bit: %s' % (bits, paths[bits]))

saved = call('/api/settings', 'backend=null&bits=-1&volume=-60')
ck(saved.get('ok') is True, '保存 bits=-1（跟随源）成功', json.dumps(saved, ensure_ascii=False)[:120])
kv2 = call('/api/settings').get('kv') or {}
ck(str(kv2.get('bits')) == '-1', '持久化后 kv.bits == -1（未被 0 吃掉）', 'bits=' + str(kv2.get('bits')))

for bits in (16, 24):
    f = str(paths[bits])
    play = call('/api/play', 'file=' + urllib.parse.quote(f) + '&backend=null&volume=-60&bits=-1')
    ck(play.get('ok') is True, '播放 %d-bit 静音源成功' % bits, json.dumps(play, ensure_ascii=False)[:100])
    import time
    # 必须等到「当前曲目确实是这份文件」再读 outBits —— 否则会读到上一曲的残留值
    # （实测踩过：停止后立刻播 24-bit，读到的是 16-bit 的旧状态，假红）。
    deadline = time.time() + 15
    st = {}
    while time.time() < deadline:
        st = call('/api/status')
        if st.get('current') == f and st.get('outBits'):
            break
        time.sleep(0.15)
    ck(st.get('outBits') == bits, '源 %d-bit → outBits == %d（跟随源真的生效）' % (bits, bits),
       'outBits=%s outRate=%s' % (st.get('outBits'), st.get('outRate')))
    call('/api/stop', '')

# 反向对照：显式 24 时 16-bit 源也必须输出 24（证明不是「恰好都等于源」）
f16 = str(paths[16])
call('/api/play', 'file=' + urllib.parse.quote(f16) + '&backend=null&volume=-60&bits=24')
import time as _t
deadline = _t.time() + 15
st = {}
while _t.time() < deadline:
    st = call('/api/status')
    if st.get('current') == f16 and st.get('outBits'):
        break
    _t.sleep(0.15)
ck(st.get('outBits') == 24, '反向对照：显式 24 + 16-bit 源 → outBits == 24', 'outBits=' + str(st.get('outBits')))
call('/api/stop', '')
call('/api/settings', 'bits=0')

bad = [x for x in results if not x[0]]
print('\n  合计 %d/%d 通过%s' % (len(results) - len(bad), len(results),
                              '，%d 条红' % len(bad) if bad else ''))
sys.exit(1 if bad else 0)
