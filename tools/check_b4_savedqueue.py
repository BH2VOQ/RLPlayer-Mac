#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# check_b4_savedqueue.py — B-4（我的歌单新建与三种加歌入口后端能力）的复跑判据
#
# 判据要求：
# 1) /api/sq/add 新建空歌单（只传 name）→ list 里看到且 n == 0
# 2) /api/sq/add 追加 1 首带 cs/ce 的曲目 → info 回该曲目且 cs/ce 与请求一致
# 3) 重复追加同一项（同 path 同 cs/ce）→ 明确响应 duplicate:true 且 info 里仍然只有 1 条
# 4) CUE 关键判据：同一 path 但不同 cs/ce 追加 → 成功且 info 里变成 2 条（证明不是只按 path 去重）
# 5) 非法歌单名必须明确拒绝，不能静默净化后覆盖另一个合法歌单
# 6) 保留入口①行为：/api/sq/save 当前队列为空时报错，语义不改

import json
import sys
import urllib.parse
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19104
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
    except Exception as e:
        return {'_err': str(e)}
    try:
        return json.loads(raw)
    except Exception:
        return {'_raw': raw}


print('  目标 %s' % BASE)

# 0) 清理环境：删掉测试可能用到的歌单
for qn in ['test_b4_empty', 'test_b4_cue', 'evil']:
    call('/api/sq/delete?name=' + urllib.parse.quote(qn), {})

# ---------- 1) 端点存在性与新建空歌单 ----------
r_add_empty = call('/api/sq/add?name=test_b4_empty', {})
print('  POST /api/sq/add (empty) → ' + json.dumps(r_add_empty, ensure_ascii=False))
ck(r_add_empty.get('ok') is True and r_add_empty.get('name') == 'test_b4_empty',
   'B-4 /api/sq/add 支持只传 name 创建空歌单', json.dumps(r_add_empty, ensure_ascii=False))

r_list = call('/api/sq/list')
q_found = next((q for q in r_list.get('queues', []) if q.get('name') == 'test_b4_empty'), None)
ck(q_found is not None and q_found.get('n') == 0,
   'B-4 新建空歌单在 /api/sq/list 中可见且 n == 0', json.dumps(q_found, ensure_ascii=False) if q_found else '未找到')

# ---------- 2) 追加 1 首带 cs/ce 的 CUE 曲目 ----------
cue_path = '/music/album1/cdimage.flac'
r_add_track1 = call('/api/sq/add?name=test_b4_cue&file=' + urllib.parse.quote(cue_path) + '&cs=12.5&ce=180.0', {})
print('  POST /api/sq/add track1 → ' + json.dumps(r_add_track1, ensure_ascii=False))
ck(r_add_track1.get('ok') is True and r_add_track1.get('count') == 1,
   'B-4 /api/sq/add 追加单曲成功且 count==1', json.dumps(r_add_track1, ensure_ascii=False))

r_info1 = call('/api/sq/info?name=test_b4_cue')
items1 = r_info1.get('items', [])
t1_ok = (len(items1) == 1 and items1[0].get('file') == cue_path
         and abs(items1[0].get('cs', -1) - 12.5) < 0.001
         and abs(items1[0].get('ce', -1) - 180.0) < 0.001)
ck(t1_ok, 'B-4 info 返回追加曲目且 cs/ce 与请求一致', json.dumps(items1, ensure_ascii=False))

# ---------- 3) 重复追加完全同一项（同 path 同 cs/ce）----------
r_dup = call('/api/sq/add?name=test_b4_cue&file=' + urllib.parse.quote(cue_path) + '&cs=12.5&ce=180.0', {})
print('  POST /api/sq/add duplicate → ' + json.dumps(r_dup, ensure_ascii=False))
ck(r_dup.get('ok') is False and r_dup.get('duplicate') is True,
   'B-4 重复追加同一项返回 duplicate:true 且 ok:false', json.dumps(r_dup, ensure_ascii=False))

r_info_dup = call('/api/sq/info?name=test_b4_cue')
ck(len(r_info_dup.get('items', [])) == 1,
   'B-4 重复追加后歌单依然只有 1 条（不产生重复条目）', 'items count=%d' % len(r_info_dup.get('items', [])))

# ---------- 4) CUE 关键判据：同一 path 但不同 cs/ce 追加 ----------
r_add_track2 = call('/api/sq/add?name=test_b4_cue&file=' + urllib.parse.quote(cue_path) + '&cs=180.0&ce=320.0', {})
print('  POST /api/sq/add track2 (diff cue) → ' + json.dumps(r_add_track2, ensure_ascii=False))
ck(r_add_track2.get('ok') is True and r_add_track2.get('count') == 2,
   'B-4 同 path 不同 cs/ce 追加成功（CUE 独立曲目不被误杀）', json.dumps(r_add_track2, ensure_ascii=False))

r_info2 = call('/api/sq/info?name=test_b4_cue')
items2 = r_info2.get('items', [])
ck(len(items2) == 2 and abs(items2[1].get('cs', -1) - 180.0) < 0.001,
   'B-4 info 返回 2 条不同分轨', json.dumps(items2, ensure_ascii=False))

# ---------- 5) 歌单名消毒判据 ----------
r_evil = call('/api/sq/add?name=' + urllib.parse.quote('../evil/test'), {})
ck(r_evil.get('ok') is False,
   'B-4 路径穿越名字明确拒绝（不静默改名）', json.dumps(r_evil, ensure_ascii=False))
for bad_name in ['a/b', 'a\\b', 'line\nname', 'x' * 61]:
    rejected = call('/api/sq/add?name=' + urllib.parse.quote(bad_name), {})
    ck(rejected.get('ok') is False, '非法名字被拒绝: ' + repr(bad_name), json.dumps(rejected, ensure_ascii=False))
for cs, ce in [('nan', '2'), ('1junk', '2'), ('3', '2'), ('inf', '4')]:
    rejected = call('/api/sq/add?name=test_b4_cue&file=x&cs=' + cs + '&ce=' + ce, {})
    ck(rejected.get('ok') is False, '非法CUE被拒绝: ' + cs + '/' + ce, json.dumps(rejected, ensure_ascii=False))

# ---------- 6) 保留既有行为：/api/sq/save 空队列报错 ----------
call('/api/clear', {})
r_save_empty = call('/api/sq/save?name=test_empty_q', {})
ck(r_save_empty.get('ok') is False and '当前队列是空的' in r_save_empty.get('error', ''),
   'B-4 既有 /api/sq/save 保持空队列报错语义不变', json.dumps(r_save_empty, ensure_ascii=False))

# 清理
call('/api/sq/delete?name=test_b4_empty', {})
call('/api/sq/delete?name=test_b4_cue', {})

bad = [x for x in results if not x[0]]
print('\n  合计 %d/%d 通过%s' % (len(results) - len(bad), len(results),
                              '，%d 条红' % len(bad) if bad else ''))
if bad:
    print('\n  红项清单：')
    for _, w, _ in bad:
        print('    - ' + w)
sys.exit(1 if bad else 0)
