#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August Hu <BH2VOQ@163.com>
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# check_e1.py — E-1（HTTP 头字段名大小写敏感）的可复跑判据
#
# 判据来源：debug/20261027-01-上游改动与BUG清单.md §1 E-1 / E-1b
#   E-1 : 小写 `content-length` 时 body 判 0 字节、参数静默丢失
#   E-1b: 小写 `host:` 在 --lan 下被误判 403
#
# 为什么用裸 socket 而不是 curl：
#   curl 会自己补/归一化头部，且在 http/1.1 下常用 chunked 或自算 Content-Length，
#   拿不到"我发的是全小写头名"这个前提。裸 socket 才能逐字节控制。
#
# 判据（三条，全部要绿）：
#   A) POST /api/upload 带 body，头名用 `content-length:`
#      绿 = 服务端报告 size == 实际字节数，且落盘文件字节数一致
#      红 = size == 0 / 400「请求体不完整」/ 落盘 0 字节
#   B) 同上但头名用规范大小写 `Content-Length:`（对照组，必须一直绿）
#   C) POST /api/upload 带头名 `host:`（全小写），--lan 模式下
#      绿 = 200
#      红 = 403（Host 未被识别 ⟹ req.host 空 ⟹ webui_host_allowed_impl 返回 false）
#
# 用法：python3 tools/check_e1.py <port> [--lan]
# 退出码：0 = 全绿；1 = 有红

import socket
import sys
import os
import json

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8971
LAN = '--lan' in sys.argv
HOST = '127.0.0.1'


def raw_post(path, headers, body, timeout=8.0):
    """发一条手工构造的 HTTP/1.1 POST，返回 (状态码, 原始响应)。"""
    head = 'POST ' + path + ' HTTP/1.1\r\n'
    for k, v in headers:
        head += k + ': ' + v + '\r\n'
    head += '\r\n'
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    try:
        s.settimeout(timeout)
        s.sendall(head.encode('utf-8') + body)
        chunks = []
        while True:
            try:
                b = s.recv(65536)
            except socket.timeout:
                break
            if not b:
                break
            chunks.append(b)
            # 本脚本只关心小响应：拿到完整 JSON 就停
            blob = b''.join(chunks)
            if b'}' in blob.split(b'\r\n\r\n', 1)[-1]:
                break
    finally:
        s.close()
    blob = b''.join(chunks)
    parts = blob.split(b'\r\n\r\n', 1)
    head_txt = parts[0].decode('utf-8', 'replace')
    body_txt = parts[1].decode('utf-8', 'replace') if len(parts) > 1 else ''
    status = 0
    first = head_txt.split('\r\n', 1)[0]
    for tok in first.split():
        if tok.isdigit():
            status = int(tok)
            break
    return status, body_txt


results = []


def ck(ok, what, detail=''):
    results.append((ok, what, detail))
    print(('  [PASS] ' if ok else '  [FAIL] ') + what + (('  — ' + detail) if detail else ''))


# 128 KB 的非零字节：足够超过任何"正好是头部长度"的巧合，且不像真音频那样敏感
PAYLOAD = bytes([(i * 7 + 3) & 0xFF for i in range(128 * 1024)])

print('  目标 http://%s:%d/  (--lan=%s)' % (HOST, PORT, LAN))

# ---------- A) 全小写 content-length ----------
st_a, body_a = raw_post('/api/upload?name=e1_lower.bin',
                        [('host', '%s:%d' % (HOST, PORT)),
                         ('content-length', str(len(PAYLOAD))),
                         ('content-type', 'application/octet-stream')],
                        PAYLOAD)
print('  A) 小写 content-length → HTTP %d %s' % (st_a, body_a.strip()[:160]))
try:
    ja = json.loads(body_a.strip()) if body_a.strip().startswith('{') else {}
except Exception:
    ja = {}
size_a = ja.get('size', -1)
ck(ja.get('ok') is True and size_a == len(PAYLOAD),
   'E-1  小写 content-length：body 完整送达（%d 字节）' % len(PAYLOAD),
   '服务端报告 size=%s，ok=%s' % (size_a, ja.get('ok')))

# 落盘字节数独立核对：不信任服务端自己的报告
disk_a = -1
if isinstance(ja.get('path'), str) and os.path.exists(ja['path']):
    disk_a = os.path.getsize(ja['path'])
ck(disk_a == len(PAYLOAD), 'E-1  小写 content-length：落盘字节数一致',
   '磁盘 %s 字节（%s）' % (disk_a, ja.get('path', '?')))

# ---------- B) 规范大小写 Content-Length（对照组） ----------
st_b, body_b = raw_post('/api/upload?name=e1_upper.bin',
                        [('Host', '%s:%d' % (HOST, PORT)),
                         ('Content-Length', str(len(PAYLOAD))),
                         ('Content-Type', 'application/octet-stream')],
                        PAYLOAD)
print('  B) 规范 Content-Length → HTTP %d %s' % (st_b, body_b.strip()[:160]))
try:
    jb = json.loads(body_b.strip()) if body_b.strip().startswith('{') else {}
except Exception:
    jb = {}
ck(jb.get('ok') is True and jb.get('size') == len(PAYLOAD),
   'E-1  规范 Content-Length：body 完整送达（对照组，必须一直绿）',
   'size=%s' % jb.get('size'))

# ---------- C) 全小写 host（仅 --lan 模式下有判别力） ----------
if LAN:
    st_c, body_c = raw_post('/api/status', [('host', '%s:%d' % (HOST, PORT))], b'')
    ck(st_c == 200, 'E-1b 小写 host: 在 --lan 下被接受（200 而非 403）',
       'HTTP %d' % st_c)
    st_c2, _ = raw_post('/api/status', [('Host', '%s:%d' % (HOST, PORT))], b'')
    ck(st_c2 == 200, 'E-1b 规范 Host: 在 --lan 下被接受（对照组）', 'HTTP %d' % st_c2)
else:
    print('  C) 跳过 --lan 分组（本实例是 loopback-only，Host 校验不生效）')

bad = [r for r in results if not r[0]]
print('\n  合计 %d/%d 通过%s' % (len(results) - len(bad), len(results),
                              '，%d 条红' % len(bad) if bad else ''))
sys.exit(1 if bad else 0)
