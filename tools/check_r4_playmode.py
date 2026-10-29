#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# check_r4_playmode.py — R-4（四态播放模式）的可复跑判据
#
# 判据来源：debug/20261027-00-BUG与新增功能总清单.md §3 R-4
#   "本地 /api/repeat（0/1/2）与 /api/shuffle（on/off）是**两套独立真相源**"
#
# 红（基线）：/api/playmode → not found；mode 只能 0/1/2，没有随机态；
#            repeat 与 shuffle 各自存储 ⟹ 可以同时 repeat=1 + shuffle=true（语义未定义）
# 绿：mode ∈ {0,1,2,3} 单一真相源；两个旧端点仍可用且**派生**自 mode
#
# 用法：python3 tools/check_r4_playmode.py <port>
# 退出码：0 = 全绿；1 = 有红

import json
import sys
import urllib.parse
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8998
BASE = 'http://127.0.0.1:%d' % PORT
results = []


def ck(ok, what, detail=''):
    results.append((ok, what, detail))
    print(('  [PASS] ' if ok else '  [FAIL] ') + what + (('  — ' + detail) if detail else ''))


def call(path, body=None):
    data = urllib.parse.urlencode(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 method='POST' if body is not None else 'GET')
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        raw = e.read().decode('utf-8', 'replace')
        return {'_http': e.code, '_raw': raw}
    try:
        return json.loads(raw)
    except Exception:
        return {'_raw': raw}


print('  目标 %s' % BASE)

# ---------- 1) 端点存在性（红侧这里会 not found）----------
r = call('/api/playmode')
print('  GET /api/playmode → ' + json.dumps(r, ensure_ascii=False)[:120])
ck(r.get('ok') is True and 'mode' in r, 'R-4 /api/playmode 存在且返回 mode',
   json.dumps(r, ensure_ascii=False)[:80])
if r.get('ok') is not True:
    print('\n  中止：端点不存在（红侧基线），后续判据无意义。')
    bad = [x for x in results if not x[0]]
    print('\n  合计 %d/%d 通过%s' % (len(results) - len(bad), len(results), '，%d 条红' % len(bad) if bad else ''))
    sys.exit(1)

# ---------- 2) 四态可写可读 ----------
names = {}
for m in (0, 1, 2, 3):
    w = call('/api/playmode?mode=%d' % m, {})
    g = call('/api/playmode')
    names[m] = g.get('name', '')
    ck(w.get('mode') == m and g.get('mode') == m,
       'R-4 mode=%d 可写可读一致' % m,
       '写后读=%s name=%s' % (g.get('mode'), g.get('name')))

ck(len(set(names.values())) == 4, 'R-4 四种模式名称互不相同（图标/文案能区分）',
   json.dumps(names, ensure_ascii=False))

# ---------- 3) 向后兼容：旧端点必须派生自 mode ----------
call('/api/playmode?mode=0', {})
w = call('/api/repeat', {'rate': '2'})
g = call('/api/playmode')
ck(w.get('repeat') == 2 and g.get('mode') == 2,
   'R-4 兼容：POST /api/repeat rate=2 ⟹ mode=2（派生写入口）',
   'repeat=%s mode=%s' % (w.get('repeat'), g.get('mode')))

call('/api/playmode?mode=0', {})
w = call('/api/shuffle?on=1', {})
g = call('/api/playmode')
ck(w.get('shuffle') is True and g.get('mode') == 3,
   'R-4 兼容：POST /api/shuffle?on=1 ⟹ mode=3',
   'shuffle=%s mode=%s' % (w.get('shuffle'), g.get('mode')))

w = call('/api/shuffle?on=0', {})
g = call('/api/playmode')
ck(w.get('shuffle') is False and g.get('mode') == 0,
   'R-4 兼容：POST /api/shuffle?on=0 ⟹ mode=0（回到顺序）',
   'shuffle=%s mode=%s' % (w.get('shuffle'), g.get('mode')))

# ---------- 4) 关键：单一真相源 —— 不可能出现"两套打架" ----------
# 旧实现里 repeat=1 与 shuffle=true 可以同时成立（两个独立字段）。
# 新实现里 mode 只有一个值，任何写入都必须让另一侧跟着变。
call('/api/playmode?mode=1', {})          # 列表循环
q = call('/api/queue')
ck(q.get('repeat') == 1 and q.get('shuffle') is False,
   'R-4 单一真相源：mode=1 时 queue 报 repeat=1 且 shuffle=false（不会同时为真）',
   'repeat=%s shuffle=%s mode=%s' % (q.get('repeat'), q.get('shuffle'), q.get('mode')))

call('/api/playmode?mode=3', {})          # 随机
q = call('/api/queue')
ck(q.get('mode') == 3 and q.get('shuffle') is True and q.get('repeat') == 0,
   'R-4 单一真相源：mode=3 时 queue 报 shuffle=true 且 repeat=0',
   'repeat=%s shuffle=%s mode=%s' % (q.get('repeat'), q.get('shuffle'), q.get('mode')))

# ---------- 5) 越界防御 ----------
w = call('/api/playmode?mode=99', {})
ck(w.get('mode') == 0, 'R-4 越界 mode=99 被钳到 0（不崩、不留下非法状态）',
   'mode=%s' % w.get('mode'))

call('/api/playmode?mode=0', {})
bad = [x for x in results if not x[0]]
print('\n  合计 %d/%d 通过%s' % (len(results) - len(bad), len(results),
                              '，%d 条红' % len(bad) if bad else ''))
if bad:
    print('\n  红项清单：')
    for _, w, _ in bad:
        print('    - ' + w)
sys.exit(1 if bad else 0)
