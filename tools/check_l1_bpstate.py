#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August Hu <BH2VOQ@163.com>
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# check_l1_bpstate.py — L-1（预设切换后状态框不更新）的可复跑判据
#
# 判据来源：debug/20261027-02-预设切换状态不更新/分析.md §5「验收判据（红→绿）」
#   J-1 播放后切预设，/api/status.bitPerfect 应变为 ''（不再是上次播放的旧结论）
#   J-2 前端徽标文本 → 「待播放验证」（前端判据，另由 uicheck_l1_badge.js 覆盖）
#   J-5 播放后 bitPerfect 与 outRate 自洽（升频必须 no + 重采样原因）
#
# 为什么必须"先真的播一次"：
#   bpState 只在**播放启动**时被写。没播过就切预设，前后都是空串，
#   "切完还是空" 无法区分"修好了"与"从来没写过"。必须先造出非空旧结论。
#
# 铁律 1：全程 backend=null（不出声），测试音为 −60 dBFS 量级。
#   本脚本不负责生成素材；素材由 gen_tone.py 生成并由调用方传入。
#
# 用法：python3 tools/check_l1_bpstate.py <port> <test.wav> [--rate=96000]
# 退出码：0 = 全绿；1 = 有红

import json
import sys
import time
import urllib.parse
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8972
WAV = sys.argv[2]
RATE = '96000'
for a in sys.argv[3:]:
    if a.startswith('--rate='):
        RATE = a.split('=', 1)[1]

BASE = 'http://127.0.0.1:%d' % PORT
results = []


def ck(ok, what, detail=''):
    results.append((ok, what, detail))
    print(('  [PASS] ' if ok else '  [FAIL] ') + what + (('  — ' + detail) if detail else ''))


def call(path, body=None, get=False):
    """body=None 且 get=False 时发 GET；给 body 就发 POST（表单）。
    /api/preset/apply 是 GET 端点（POST 会被 405 门禁拒掉），所以必须能显式要求 GET。"""
    data = urllib.parse.urlencode(body, doseq=True).encode() if body else b''
    if get:
        req = urllib.request.Request(BASE + path, method='GET')
    else:
        req = urllib.request.Request(BASE + path,
                                     data=data if body is not None else None,
                                     method='POST' if body is not None else 'GET')
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read().decode('utf-8', 'replace')
    try:
        return json.loads(raw)
    except Exception:
        return {'_raw': raw}


def status():
    return call('/api/status')


def wait_bp_written(timeout=25.0):
    """等播放线程**真的把结论写下来**（ps.bpState 非空）。

    为什么不能只等 playing==True 就返回：
    bpState 是在播放线程启动成功后才写的（tools/rtaweb.cpp:3170 附近）。
    素材只有 2 秒，playing 很快就会变回 False；如果看到 playing=True 立刻返回，
    会与"写结论"这一步抢跑 ⟹ 偶发拿到空串，把"已修好"误判成"没写"（假红）。
    这里的判据是"结论已经落库"，它必然在写完之后成立。
    """
    t0 = time.time()
    last = {}
    while time.time() - t0 < timeout:
        st = status()
        last = st
        if st.get('bitPerfect'):
            return st
        time.sleep(0.2)
    return last


print('  目标 %s  素材=%s' % (BASE, WAV))

# 铁律 1 的硬门禁：**先证明不会出声**，再播。
# 真相源是 /api/settings 的 kv.backend（后端真正要用的值），不是 /api/status ——
# 后者只在**播放中**才填 device，播放前是空的，拿它当门禁会永远误判。
# 这个检查宁可误报也不能漏报：宁可测试跑不了，也不能真的从用户音箱里放出声。
kv = call('/api/settings').get('kv') or {}
backend = (kv.get('backend') or '').lower()
is_null = (backend == 'null')
ck(is_null, '前置：后端为 null（不出声，铁律 1）', 'backend=' + (backend or '(空)'))
if not is_null:
    print('\n  中止：backend 不是 null，拒绝播放（铁律 1）。')
    print('        请用 RLPLAYER_STATE_DIR 隔离实例 + conf 里 backend=null 启动。')
    sys.exit(1)

# ---------- 步骤 1：按 PCM 升频参数播放一次，制造一个非空的旧结论 ----------
play_body = {
    'file': WAV,
    'rate': RATE,
    'filter': 'poly-sinc-tight-lp',
    'shaper': 'auto',
    'backend': 'null',
    'volume': '-60',
}
r_play = call('/api/play', play_body)
print('  /api/play → ' + json.dumps(r_play, ensure_ascii=False)[:200])
st1 = wait_bp_written()
bp1 = st1.get('bitPerfect', '')
out1 = st1.get('outRate', 0)
print('  播放后 bitPerfect=%r outRate=%s why=%r' %
      (bp1, out1, (st1.get('bitPerfectWhy') or '')[:60]))
ck(bp1 != '', '前置：播放后 bitPerfect 已有结论（非空，才谈得上"旧结论"）', repr(bp1))

# ---------- J-5：升频必须与 bit-perfect 自洽 ----------
ck(not (bp1 == 'yes' and int(out1 or 0) != 44100 and out1),
   'J-5 升频时不会错误报告 bit-perfect',
   'bitPerfect=%r outRate=%s' % (bp1, out1))

# ---------- 步骤 2：切预设 → J-1 旧结论必须失效 ----------
# /api/preset/apply 在 kNeedPost 里（拒绝 GET），但参数从**查询串**读、body 可空
call('/api/preset/apply?profile=bitperfect', {})
time.sleep(0.8)
st2 = status()
bp2 = st2.get('bitPerfect', '')
why2 = st2.get('bitPerfectWhy', '')
print('  切 bitperfect 预设后 bitPerfect=%r why=%r' % (bp2, why2))
ck(bp2 == '', 'J-1 切预设后 bitPerfect 被清零（不再显示上次播放的旧结论）',
   '切换前 %r → 切换后 %r' % (bp1, bp2))
ck(why2 == '', 'J-1 切预设后 bitPerfectWhy 一并清零', repr(why2))

# ---------- 步骤 3：再播放一次，结论要能重新产生（不是永久空） ----------
r_play2 = call('/api/play', dict(play_body, rate='follow'))
st3 = wait_bp_written()
bp3 = st3.get('bitPerfect', '')
print('  再播放后 bitPerfect=%r outRate=%s' % (bp3, st3.get('outRate')))
ck(bp3 != '', 'J-1 副作用检查：重新播放后结论会重新产生（不是把字段焊死成空）', repr(bp3))

# ---------- 步骤 4：停止 → 结论清零 ----------
call('/api/stop', {})
time.sleep(0.8)
st4 = status()
bp4 = st4.get('bitPerfect', '')
ck(bp4 == '', 'J-1 停止播放后 bitPerfect 清零（停播后结论已无对象）', repr(bp4))

bad = [r for r in results if not r[0]]
print('\n  合计 %d/%d 通过%s' % (len(results) - len(bad), len(results),
                              '，%d 条红' % len(bad) if bad else ''))
sys.exit(1 if bad else 0)
