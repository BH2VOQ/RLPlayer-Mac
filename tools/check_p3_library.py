#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# check_p3_library.py — Q-5 / Q-6 / Q-7 / Q-8 真实端点可复跑判据
#
# 判据来源：
#   - Q-5: 整列起播（/api/queue/set POST 原子替换支持 path\tcs\tce）
#   - Q-6: 我的最爱（/api/fav/list?meta=1 返回元数据对象）
#   - Q-7: 具名保存队列（/api/sq/list, /api/sq/info, /api/sq/save, /api/sq/rename, /api/sq/delete, /api/sq/play）
#          包含目录穿越防御、名字消毒、索引越界校验、CUE区间保留
#   - Q-8: 队列排序（/api/qorder, /api/qsort?by=default）
#   - /api/pl: 播放列表保留 CUE 区间与完整管理端点
#
# 用法：python3 tools/check_p3_library.py <port>
# 退出码：0 = 全绿；1 = 有红；2 = 环境/连接失败

import json
import sys
import urllib.parse
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19091
BASE = 'http://127.0.0.1:%d' % PORT
results = []


def ck(ok, what, detail=''):
    results.append((ok, what, detail))
    print(('  [PASS] ' if ok else '  [FAIL] ') + what + (('  — ' + detail) if detail else ''))


def call(path, body=None, raw_body=None):
    if raw_body is not None:
        data = raw_body.encode('utf-8')
    elif body is not None:
        data = urllib.parse.urlencode(body).encode('utf-8')
    else:
        data = None
    # 保证 path 里的中文 query 经过 quote
    if '?' in path:
        base_p, qs = path.split('?', 1)
        # quote non-ascii in query string while preserving =, &, %, /, etc.
        qs_quoted = urllib.parse.quote(qs, safe='=&%/:;,+?@<>*~-._')
        full_url = BASE + base_p + '?' + qs_quoted
    else:
        full_url = BASE + path
    req = urllib.request.Request(full_url, data=data,
                                 method='POST' if (body is not None or raw_body is not None) else 'GET')
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read().decode('utf-8', 'replace')
            code = r.getcode()
    except urllib.error.HTTPError as e:
        raw = e.read().decode('utf-8', 'replace')
        code = e.code
    except Exception as e:
        return {'_err': str(e), '_raw': ''}
    try:
        j = json.loads(raw)
        j['_http'] = code
        return j
    except Exception:
        return {'_http': code, '_raw': raw}


print('=== RLPlayer P3 Library Test (Target: %s) ===' % BASE)

# 0) 基础连通性探针
probe = call('/api/ping')
if '_err' in probe:
    print('  [FATAL] 服务未就绪或无法连接: %s' % probe['_err'])
    sys.exit(2)

print('  服务正常响应: version=%s' % probe.get('version', 'unknown'))

# =========================================================================
# 1) Q-5: /api/queue/set POST 原子替换支持 path\tcs\tce
# =========================================================================
print('\n--- 1. Q-5 整列替换 /api/queue/set ---')
# 1.1 端点存在性（baseline 会落入 /api/queue 或 not found）
qset_test = call('/api/queue/set', {'files': '/tmp/test_single.flac'})
ck(qset_test.get('ok') is True and qset_test.get('count') == 1,
   'Q-5 /api/queue/set 成功写入 1 首曲目',
   'count=%s res=%s' % (qset_test.get('count'), str(qset_test)[:60]))

qset_empty = call('/api/queue/set', {'files': ''})
ck(qset_empty.get('ok') is False,
   'Q-5 /api/queue/set 空列表被拒绝',
   qset_empty.get('error', ''))

# 1.2 支持原子替换多行：普通曲目 + CUE 分轨（带 cs/ce）
lines = [
    '/tmp/test_track1.flac',
    '/tmp/test_cue.flac\t10.500000\t75.250000',
    '/tmp/test_cue.flac\t75.250000\t140.000000',
    '/tmp/test_track2.wav'
]
files_body = '\n'.join(lines)
qset_res = call('/api/queue/set', {'files': files_body})
ck(qset_res.get('ok') is True and qset_res.get('count') == 4,
   'Q-5 /api/queue/set 成功写入 4 首曲目（含 CUE 区间）',
   'count=%s' % qset_res.get('count'))

# 1.3 验证 /api/queue 正确返回 items 与 cues
q_res = call('/api/queue')
ck(q_res.get('ok') is True and len(q_res.get('items', [])) == 4,
   'Q-5 /api/queue 读取队列条数为 4',
   'len=%d' % len(q_res.get('items', [])))

cues = q_res.get('cues', [])
ck(len(cues) == 4 and abs(cues[1][0] - 10.5) < 0.01 and abs(cues[1][1] - 75.25) < 0.01,
   'Q-5 /api/queue cues 包含精确的 CUE 起止秒',
   'cues[1]=%s' % str(cues[1] if len(cues) > 1 else 'None'))

# =========================================================================
# 2) Q-7: 具名保存队列 /api/sq/*
# =========================================================================
print('\n--- 2. Q-7 具名保存队列 /api/sq/* ---')
# 2.1 GET /api/sq/list
sq_list = call('/api/sq/list')
ck(sq_list.get('ok') is True and 'queues' in sq_list,
   'Q-7 GET /api/sq/list 存在且返回 queues 列表',
   'http=%s' % sq_list.get('_http'))

# 2.2 POST /api/sq/save 保存当前队列
sq_save = call('/api/sq/save?name=我的测试歌单', {})
ck(sq_save.get('ok') is True and sq_save.get('name') == '我的测试歌单' and sq_save.get('count') == 4,
   'Q-7 POST /api/sq/save 成功保存当前队列为具名歌单',
   'name=%s count=%s' % (sq_save.get('name'), sq_save.get('count')))

# 2.3 GET /api/sq/info 查询保存的歌单详情
sq_info = call('/api/sq/info?name=我的测试歌单')
ck(sq_info.get('ok') is True and len(sq_info.get('items', [])) == 4,
   'Q-7 GET /api/sq/info 返回 4 条曲目明细',
   'len=%d' % len(sq_info.get('items', [])))
sq_items = sq_info.get('items', [])
ck(len(sq_items) >= 2 and abs(sq_items[1].get('cs', 0) - 10.5) < 0.01,
   'Q-7 /api/sq/info 保留了 CUE 分轨区间',
   'item[1]=%s' % str(sq_items[1] if len(sq_items) > 1 else ''))

# 2.4 安全防御：目录穿越与非法字符消毒
sq_trav = call('/api/sq/save?name=../../bad_path_test', {})
# 必须被消毒为 safe name 且成功保存
trav_name = sq_trav.get('name', '')
ck(sq_trav.get('ok') is True and '..' not in trav_name and '/' not in trav_name and '\\' not in trav_name,
   'Q-7 /api/sq/save 拦截/消毒目录穿越字符（.. / \\）',
   'sanitized_name=%s res=%s' % (trav_name, str(sq_trav)[:60]))

# 2.5 POST /api/sq/rename 重命名
sq_ren = call('/api/sq/rename?from=我的测试歌单&to=重命名歌单', {})
ck(sq_ren.get('ok') is True and sq_ren.get('to') == '重命名歌单',
   'Q-7 POST /api/sq/rename 成功重命名歌单',
   'from=%s to=%s' % (sq_ren.get('from'), sq_ren.get('to')))

# 2.6 重命名不存在的歌单返回错误
sq_ren_fail = call('/api/sq/rename?from=不存在的歌单&to=xxx', {})
ck(sq_ren_fail.get('ok') is False,
   'Q-7 POST /api/sq/rename 对不存在的歌单返回 ok:false',
   sq_ren_fail.get('error', ''))

# 2.7 POST /api/sq/play 载入具名队列
# 先清空当前队列
call('/api/clear', {})
q_empty = call('/api/queue')
ck(len(q_empty.get('items', [])) == 0, '当前队列已清空以备测试 sq/play')

# 载入并指定起始索引 i=1
sq_play = call('/api/sq/play?name=重命名歌单&i=1', {})
ck(sq_play.get('ok') is True and sq_play.get('count') == 4 and sq_play.get('index') == 1,
   'Q-7 POST /api/sq/play 成功装载歌单且设置起始 index=1',
   'count=%s index=%s' % (sq_play.get('count'), sq_play.get('index')))

# 2.8 索引边界校验：越界索引被安全归一，不越界崩溃
sq_play_oob = call('/api/sq/play?name=重命名歌单&i=99999', {})
ck(sq_play_oob.get('ok') is True and sq_play_oob.get('index') == 0,
   'Q-7 POST /api/sq/play 越界索引 (99999) 安全重置为 0',
   'index=%s' % sq_play_oob.get('index'))

# 2.9 POST /api/sq/delete 删除歌单
sq_del = call('/api/sq/delete?name=重命名歌单', {})
ck(sq_del.get('ok') is True,
   'Q-7 POST /api/sq/delete 成功删除歌单',
   'res=%s' % str(sq_del))

# 删除后再查详情应该不存在
sq_info_del = call('/api/sq/info?name=重命名歌单')
ck(sq_info_del.get('ok') is False,
   'Q-7 已删除歌单在 info 查询时返回不存在',
   sq_info_del.get('error', ''))

# =========================================================================
# 3) Q-8: 队列排序 /api/qorder 与 /api/qsort
# =========================================================================
print('\n--- 3. Q-8 队列排序 /api/qorder 与 /api/qsort ---')
# 3.1 准备已知 3 首队列
q3 = [
    '/tmp/song_b.flac',
    '/tmp/song_a.flac',
    '/tmp/song_c.flac\t10.0\t50.0'
]
qset_init = call('/api/queue/set', {'files': '\n'.join(q3)})
ck(qset_init.get('ok') is True and qset_init.get('count') == 3,
   'Q-8 队列初始化成功 (3 首)',
   'count=%s res=%s' % (qset_init.get('count'), str(qset_init)[:60]))

# 3.2 POST /api/qorder 重排为 [song_a, song_b, song_c]
reordered = [
    '/tmp/song_a.flac',
    '/tmp/song_b.flac',
    '/tmp/song_c.flac\t10.0\t50.0'
]
qorder_res = call('/api/qorder', {'files': '\n'.join(reordered)})
ck(qorder_res.get('ok') is True and qorder_res.get('n') == 3,
   'Q-8 POST /api/qorder 成功整列重排',
   'n=%s' % qorder_res.get('n'))

# 3.4 检查重排后当前播放位置 index 自动跟随追踪！原第 0 首 (song_b) 变到了第 1 首
ck(qorder_res.get('index') == 1,
   'Q-8 POST /api/qorder 重新定位正在播的那首 (index 0 -> 1)',
   'index=%s' % qorder_res.get('index'))

# 3.5 校验硬约束：条数不一致拒绝
qorder_bad_cnt = call('/api/qorder', {'files': '/tmp/song_a.flac'})
ck(qorder_bad_cnt.get('ok') is False,
   'Q-8 POST /api/qorder 拒绝条数不一致的重排请求',
   qorder_bad_cnt.get('error', ''))

# 3.6 校验硬约束：出现队列外的曲目拒绝
qorder_bad_item = call('/api/qorder', {'files': '/tmp/song_a.flac\n/tmp/song_b.flac\n/tmp/foreign.flac'})
ck(qorder_bad_item.get('ok') is False,
   'Q-8 POST /api/qorder 拒绝包含队列外曲目的重排请求',
   qorder_bad_item.get('error', ''))

# 3.7 POST /api/qsort?by=default 撤销排序（恢复默认顺序）
qsort_restore = call('/api/qsort?by=default', {})
ck(qsort_restore.get('ok') is True,
   'Q-8 POST /api/qsort?by=default 成功恢复默认顺序',
   'res=%s' % str(qsort_restore))

# 检查当前队列是否恢复为 [song_b, song_a, song_c]，且 index 回到 0
q_restored = call('/api/queue')
r_items = q_restored.get('items', [])
ck(len(r_items) == 3 and r_items[0] == '/tmp/song_b.flac' and q_restored.get('index') == 0,
   'Q-8 恢复后曲目顺序与 index 完整还原',
   'first=%s index=%s' % (r_items[0] if r_items else '', q_restored.get('index')))

# 3.8 再次撤销应该失败（无快照可恢复）
qsort_again = call('/api/qsort?by=default', {})
ck(qsort_again.get('ok') is False,
   'Q-8 再次恢复默认顺序返回 ok:false（没有可恢复的排序）',
   qsort_again.get('error', ''))

# =========================================================================
# 4) Q-6: 我的最爱 /api/fav/list?meta=1 与 /api/queue?meta=1
# =========================================================================
print('\n--- 4. Q-6 我的最爱与元数据对齐 ---')
# 4.1 加入一首收藏
call('/api/fav?file=/tmp/song_fav.flac&on=1', {})

# 4.2 普通 GET /api/fav/list 返回纯字符串数组
fav_plain = call('/api/fav/list')
ck(fav_plain.get('ok') is True and isinstance(fav_plain.get('files', [None])[0], str),
   'Q-6 GET /api/fav/list 保持旧契约（字符串数组）',
   'type=%s' % type(fav_plain.get('files', [None])[0]).__name__)

# 4.3 GET /api/fav/list?meta=1 返回包含 file 字段的对象
fav_meta = call('/api/fav/list?meta=1')
first_fav = (fav_meta.get('files') or [{}])[0]
ck(fav_meta.get('ok') is True and isinstance(first_fav, dict) and 'file' in first_fav,
   'Q-6 GET /api/fav/list?meta=1 返回对象数组（包含 file 字段）',
   'first=%s' % str(first_fav)[:60])

# 4.4 GET /api/queue?meta=1 返回与 items 对齐的 metas 数组
q_meta = call('/api/queue?meta=1')
ck(q_meta.get('ok') is True and 'metas' in q_meta and len(q_meta.get('metas', [])) == len(q_meta.get('items', [])),
   'Q-6 GET /api/queue?meta=1 返回平行 metas 数组用于前端排序',
   'metas_len=%d items_len=%d' % (len(q_meta.get('metas', [])), len(q_meta.get('items', []))))

# =========================================================================
# 5) /api/pl CUE 区间支持与管理端点测试
# =========================================================================
print('\n--- 5. /api/pl CUE 区间与管理端点 ---')
# 5.1 POST /api/pl/create
pl_create = call('/api/pl/create?name=测试播放列表', {})
ck(pl_create.get('ok') is True and pl_create.get('name') == '测试播放列表',
   '/api/pl/create 成功创建播放列表',
   'name=%s res=%s' % (pl_create.get('name'), str(pl_create)[:60]))

# 5.2 POST /api/pl/add 带 CUE 区间
pl_add = call('/api/pl/add?name=测试播放列表&file=/tmp/test_cue.flac&cue_start=15.0&cue_end=90.0', {})
ck(pl_add.get('ok') is True and pl_add.get('count') == 1,
   '/api/pl/add 成功添加带 CUE 区间的单曲',
   'count=%s' % pl_add.get('count'))

# 5.3 POST /api/pl/info 验证 CUE 区间被保留
pl_info = call('/api/pl/info?name=测试播放列表', {})
p_items = pl_info.get('items', [])
ck(pl_info.get('ok') is True and len(p_items) == 1 and abs(p_items[0].get('cs', 0) - 15.0) < 0.01,
   '/api/pl/info 正确保留并回显 CUE 起止秒',
   'item=%s' % str(p_items[0] if p_items else ''))

# 5.4 POST /api/pl/delete
pl_del = call('/api/pl/delete?name=测试播放列表', {})
ck(pl_del.get('ok') is True,
   '/api/pl/delete 成功删除播放列表',
   'res=%s' % str(pl_del))

# =========================================================================
# 总结输出
# =========================================================================
bad = [x for x in results if not x[0]]
print('\n=== 测试汇总: %d/%d 通过，%d 失败 ===' %
      (len(results) - len(bad), len(results), len(bad)))

if bad:
    print('\n失败项列表:')
    for ok, what, detail in bad:
        print('  - ' + what + ((' (' + detail + ')') if detail else ''))
    sys.exit(1)
else:
    print('\n全部判据通过！')
    sys.exit(0)
