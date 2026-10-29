#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# check_q10_busy.py — Q-10（超限连接静默断连）的可复跑判据
#
# 判据来源：debug/20261027-00-BUG与新增功能总清单.md §4 Q-10
#   "并发打满 65 条以上时，第 65+ 条收到 503 + JSON 而不是 RST"
#
# 为什么必须真打满连接：
#   看代码只能证明"有 if (conns.size() >= kMaxConnections) 分支"，
#   证明不了"客户端实际看到什么"。RST 与 503 的差别只有真的把连接堆到上限才暴露。
#
# 怎么造"占满"：
#   本地 SO_RCVTIMEO=500ms 让卡住的连接 0.5s 就被回收（webui.h:99），
#   所以必须**持续占着**——用「声明 Content-Length 但只发一小部分 body」的方式让
#   worker 线程卡在 recv 循环里，同时高频补新连接，把在线数压在 64 以上。
#
# 红：第 65+ 条连接被服务端直接 close，客户端拿不到任何 HTTP 响应（ConnectionResetError / 空响应）
# 绿：收到 HTTP/1.1 503 + JSON body（含 "ok":false / "error":"busy"）
#
# 用法：python3 tools/check_q10_busy.py <port> [并发数]
# 退出码：0 = 全绿；1 = 有红；2 = 环境问题

import socket
import sys
import json

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8980
TARGET = int(sys.argv[2]) if len(sys.argv) > 2 else 70
HOST = '127.0.0.1'


def open_stuck_conn():
    """开一条连接并让它占住 worker：声明大 body 但只发几个字节。"""
    s = socket.create_connection((HOST, PORT), timeout=5)
    # 注意用**规范大小写**的 Content-Length：小写形态是 E-1 的覆盖范围，
    # 这里要隔离 Q-10 这个变量，不能让它被 E-1 的行为带偏。
    req = ('POST /api/settings HTTP/1.1\r\n'
           'Host: %s:%d\r\n'
           'Content-Type: application/x-www-form-urlencoded\r\n'
           'Content-Length: 100000\r\n'
           '\r\n'
           'x=') % (HOST, PORT)
    s.sendall(req.encode())
    return s


results = []


def ck(ok, what, detail=''):
    results.append((ok, what, detail))
    print(('  [PASS] ' if ok else '  [FAIL] ') + what + (('  — ' + detail) if detail else ''))


def probe_one():
    """在"已占满"的状态下再开一条，看它是被 RST 还是收到 503。"""
    s = socket.create_connection((HOST, PORT), timeout=5)
    try:
        s.settimeout(5)
        s.sendall(('GET /api/ping HTTP/1.1\r\nHost: %s:%d\r\n\r\n' % (HOST, PORT)).encode())
        chunks = []
        while True:
            try:
                b = s.recv(65536)
            except socket.timeout:
                break
            if not b:
                break
            chunks.append(b)
            if b'\r\n\r\n' in b''.join(chunks):
                break
        blob = b''.join(chunks)
        if not blob:
            return ('reset', '')
        head = blob.split(b'\r\n\r\n', 1)[0].decode('utf-8', 'replace')
        body = blob.split(b'\r\n\r\n', 1)[1].decode('utf-8', 'replace') if b'\r\n\r\n' in blob else ''
        status = 0
        for tok in head.split('\r\n', 1)[0].split():
            if tok.isdigit():
                status = int(tok)
                break
        return (status, body)
    except ConnectionResetError:
        return ('reset', '')
    except BrokenPipeError:
        return ('reset', '')
    finally:
        s.close()


print('  目标 http://%s:%d  目标并发 %d' % (HOST, PORT, TARGET))

held = []
try:
    # 阶段 1：先堆满
    for _ in range(TARGET):
        try:
            held.append(open_stuck_conn())
        except Exception as e:
            print('  建立连接失败：%s' % e)
            break
    print('  已占住 %d 条连接' % len(held))

    # 阶段 2：在占满状态下连打若干次，统计得到 503 的次数
    outcomes = []
    for _ in range(8):
        st, body = probe_one()
        outcomes.append((st, body[:80]))
    print('  打满时的 8 次探测结果：')
    for st, body in outcomes:
        print('    status=%s  body=%s' % (st, body))

    n503 = sum(1 for st, _ in outcomes if st == 503)
    nreset = sum(1 for st, _ in outcomes if st == 'reset')
    nok = sum(1 for st, _ in outcomes if st == 200)
    print('  汇总：503=%d  200=%d  reset=%d' % (n503, nok, nreset))

    if nok == len(outcomes):
        # 没打满：本机 500ms 超时周转太快，判据没被触发
        print('\n  ⚠️ 未能触发超限（全部 200）—— 说明 500ms SO_RCVTIMEO 让槽位周转极快，')
        print('     与清单 §6 的实测观察一致。此情形下本判据**不成立**，不算通过也不算失败：')
        print('     需要让占位连接持续抢回槽位，见下方"加压"分支。')
        # 加压：一边补新连接维持占位，一边探测
        held2 = []
        n503 = nreset = nok2 = 0
        samples = []
        for _ in range(60):
            for _ in range(6):
                try:
                    held2.append(open_stuck_conn())
                except Exception:
                    pass
            st, body = probe_one()
            samples.append((st, body[:80]))
            if st == 503:
                n503 += 1
            elif st == 'reset':
                nreset += 1
            elif st == 200:
                nok2 += 1
        held.extend(held2)
        print('  加压后：503=%d  200=%d  reset=%d（共 %d 次探测）' % (n503, nok2, nreset, len(samples)))
        if n503 > 0:
            ok_body = any('busy' in b or '"ok":false' in b for st, b in samples if st == 503)
            ck(True, 'Q-10 超限时返回 HTTP 503', '503 出现 %d 次' % n503)
            ck(ok_body, 'Q-10 503 同时带 JSON body（ok:false / error:busy），客户端可读',
               ' | '.join([b for st, b in samples if st == 503][:2]))
        elif nreset > 0:
            ck(False, 'Q-10 超限时返回 HTTP 503（不是 RST）',
               '仍出现 %d 次连接重置 —— 红' % nreset)
        else:
            ck(False, 'Q-10 判据未能触发（不可判定）',
               '加压 %d 次探测全部 200，未能把在线数压到上限' % len(samples))
    else:
        ck(n503 > 0, 'Q-10 超限时返回 HTTP 503（不是静默断连）',
           '503=%d reset=%d 200=%d' % (n503, nreset, nok))
        bodies = [b for st, b in outcomes if st == 503]
        ck(any('busy' in b or '"ok":false' in b for b in bodies),
           'Q-10 503 同时带 JSON body（ok:false / error:busy）',
           ' | '.join(bodies[:2]))
finally:
    for s in held:
        try:
            s.close()
        except Exception:
            pass

bad = [r for r in results if not r[0]]
print('\n  合计 %d/%d 通过%s' % (len(results) - len(bad), len(results),
                              '，%d 条红' % len(bad) if bad else ''))
sys.exit(1 if bad else 0)
