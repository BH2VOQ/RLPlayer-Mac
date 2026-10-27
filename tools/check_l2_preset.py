#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August Hu <BH2VOQ@163.com>
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# check_l2_preset.py — L-2（预设切换后新设置不生效）的可复跑判据
#
# 判据来源：debug/20261027-02-预设切换状态不更新/分析.md §5
#   J-4 **不开设置页**，点 PCM 预设 → 播放，outRate 必须是预设值（红侧仍是 44100）
#   J-5 bitPerfect 与 outRate 自洽（升频必须 no + 重采样原因）
#   + 回归：conf 兜底不得污染 /api/repeat（rate 字段复用冲突，见 L-2 实现注释）
#
# 为什么"不开设置页"是核心条件：
#   前端 params() 从设置页控件取值；打开过设置页，控件被回填，缺陷就被掩盖了。
#   冷启动直接播放（或从快速开始页点预设后播放）才是真实用户路径。
#
# 铁律 1：全程 backend 由 conf 固定为 null，脚本里再断言一次，不满足就中止。
#
# 用法：python3 tools/check_l2_preset.py <port> <test.wav>
# 退出码：0 = 全绿；1 = 有红

import json
import sys
import time
import urllib.parse
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8979
WAV = sys.argv[2] if len(sys.argv) > 2 else '/tmp/tone_l1.wav'
BASE = 'http://127.0.0.1:%d' % PORT
results = []


def ck(ok, what, detail=''):
    results.append((ok, what, detail))
    print(('  [PASS] ' if ok else '  [FAIL] ') + what + (('  — ' + detail) if detail else ''))


def call(path, body=None):
    data = urllib.parse.urlencode(body, doseq=True).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 method='POST' if body is not None else 'GET')
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read().decode('utf-8', 'replace')
    try:
        return json.loads(raw)
    except Exception:
        return {'_raw': raw}


def status():
    return call('/api/status')


def wait_bp(timeout=25.0):
    t0 = time.time()
    last = {}
    while time.time() - t0 < timeout:
        last = status()
        if last.get('bitPerfect'):
            return last
        time.sleep(0.2)
    return last


print('  目标 %s  素材=%s' % (BASE, WAV))

kv = call('/api/settings').get('kv') or {}
ck((kv.get('backend') or '').lower() == 'null', '前置：后端为 null（不出声，铁律 1）',
   'backend=' + (kv.get('backend') or '(空)'))
if (kv.get('backend') or '').lower() != 'null':
    print('\n  中止：backend 不是 null，拒绝播放（铁律 1）。')
    sys.exit(1)

# ---------- 步骤 1：点 PCM 预设（等价用户操作；参数只写 conf，不进 body） ----------
r_pre = call('/api/preset/apply?profile=pcm', {})
print('  preset apply(pcm) → ' + json.dumps(r_pre, ensure_ascii=False)[:160])
applied_rate = (r_pre.get('applied') or {}).get('rate', '')
ck(r_pre.get('ok') is True, '前置：PCM 预设应用成功', str(r_pre.get('ok')))
ck(bool(applied_rate), '前置：预设把 rate 写成了具体值（写进 conf）', repr(applied_rate))

# 读 conf 确认值真的落盘了（"写盘"与"生效"是两件事，这里先证明前半段）
kv2 = call('/api/settings').get('kv') or {}
conf_rate = kv2.get('rate', '')
print('  conf 里的 rate = %r' % conf_rate)
ck(conf_rate == applied_rate, '前置：conf 里的 rate 与预设给的值一致',
   '%r vs %r' % (conf_rate, applied_rate))

# ---------- 步骤 2：J-4 —— 播放时**不带 rate**（模拟冷启动/未开设置页） ----------
# 只传 file（+ 显式 backend=null/volume，其余全靠 conf 兜底）
r_play = call('/api/play', {'file': WAV, 'backend': 'null', 'volume': '-60'})
print('  /api/play（body 不含 rate/filter）→ ' + json.dumps(r_play, ensure_ascii=False)[:120])
st = wait_bp()
out_rate = int(st.get('outRate') or 0)
bp = st.get('bitPerfect', '')
print('  播放结果 outRate=%s bitPerfect=%r why=%r' % (out_rate, bp, (st.get('bitPerfectWhy') or '')[:70]))

ck(out_rate == int(applied_rate),
   'J-4 未开设置页时不带 rate 播放，输出采样率 = 预设值（conf 兜底生效）',
   '期望 %s，实际 %s' % (applied_rate, out_rate))

# ---------- J-5：升频必须与 bit-perfect 自洽 ----------
if out_rate != 44100:
    ck(bp == 'no', 'J-5 升频时 bitPerfect 为 no（不得谎报直通）',
       'outRate=%s bitPerfect=%r' % (out_rate, bp))

# ---------- 步骤 3：回归 —— /api/repeat 不能被 conf 里的 rate 污染 ----------
# 坑的形态：/api/repeat 复用 `rate` 字段传循环模式（0/1/2）。
# 如果 conf 兜底无差别作用在 parseForm 上，conf 里的 rate=96000 会把这个端点
# 算成 96000 > 2 → 判非法 → 归 0，用户设的"循环列表/单曲"被静默清成"不循环"。
#
# ⚠️ 判据口径（铁律 3，别测错东西）：
#   /api/repeat 是**设置**端点，`call(...,{})`（空 body）在基线与修复后都会写 0 —— 那是既有语义，
#   不是本次回归。真正要证明的是：**显式传的值不会被 conf 覆盖**，且**不污染 conf**。
for want in ('1', '2', '0'):
    r = call('/api/repeat', {'rate': want})
    got = r.get('repeat')
    ck(str(got) == want,
       'L-2 回归：显式设 repeat=%s 不会被 conf 里的 rate=96000 顶掉' % want,
       'got=%r' % got)

# conf 里的播放 rate 不应被这个端点改写（两个语义不同的东西不能互相踩）
kv3 = call('/api/settings').get('kv') or {}
ck(kv3.get('rate') == applied_rate,
   'L-2 回归：/api/repeat 不会改写 conf 里的播放 rate（两个 rate 井水不犯河水）',
   'conf rate=%r 期望=%r' % (kv3.get('rate'), applied_rate))

call('/api/stop', {})
bad = [r for r in results if not r[0]]
print('\n  合计 %d/%d 通过%s' % (len(results) - len(bad), len(results),
                              '，%d 条红' % len(bad) if bad else ''))
sys.exit(1 if bad else 0)
