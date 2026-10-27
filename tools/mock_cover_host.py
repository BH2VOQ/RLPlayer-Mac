#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August Hu <BH2VOQ@163.com>
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# mock_cover_host.py — E-4 判据用的本地假「网易云搜索 + 封面图」服务
#
# 为什么要它：
#   E-4 的红判据是「第二轮 prefetch 返回 running=false 时，前端不再轮询 progress」。
#   要用真浏览器复现，就必须让第一轮**真的在跑**（否则后端立刻 done，测不到轮询窗口）。
#   连真实网易会让判据受网络状态支配 ⟹ 不可复跑。这里用本地服务把节奏钉死：
#     · POST /api/search/get  → 固定返回一条 picUrl 指向本服务
#     · GET  /cover.jpg       → 睡 SLEEP_MS 再回一张合法 JPEG（>2048B），把「后台在跑」的窗口拉宽
#   只服务本机，不碰外网；GET /__calls 可查调用次数（证明真的有抓取发生）。
#
# 用法：python3 tools/mock_cover_host.py <port> [sleep_ms]

import sys
import time
import json
import struct

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8920
SLEEP_MS = int(sys.argv[2]) if len(sys.argv) > 2 else 2200

calls = {'search': 0, 'cover': 0}

# 造一张"像样"的 JPEG：以 FF D8 FF 开头、以 FF D9 结尾，中间填充到 >2048 字节。
# cover_fetch.h 只校验魔数 + 最小字节数（见 kCoverMinBytes / cover_mime_of），
# 不需要能被真正解码 —— 本判据测的是"抓取完成后的重绘"，不是解码器。
_jpeg = b'\xff\xd8\xff\xe0' + b'\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00' \
        + b'\xff\xdb' + b'\x00C\x00' + bytes([16] * 64) \
        + b'\xff\xda' + b'\x00\x08\x01\x01\x00\x00?\x00' + bytes([0x5A] * 6000) + b'\xff\xd9'


def search_response():
    # rta::cover::cover_pick_pic 需要 result.albums[]，按 name/artists 做 Dice 打分。
    # 专辑名/艺术家由查询词 s= 决定，这里故意**回显查询词**，保证任何专辑都能匹配上
    # （判据不关心匹配质量，只关心"有图可抓"）。
    return {
        'code': 200,
        'result': {
            'albums': [
                {
                    'name': '__ECHO__',
                    'picUrl': 'http://127.0.0.1:%d/cover.jpg' % PORT,
                    'artists': [{'name': '__ECHO__'}],
                    'artist': {'name': '__ECHO__'},
                }
            ]
        },
    }


from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith('/__calls'):
            self._send(200, json.dumps(calls).encode(), 'application/json')
            return
        if self.path.startswith('/cover.jpg'):
            calls['cover'] += 1
            # 每次取图都慢一点：这是让"第一轮仍在跑"的窗口稳定存在的关键
            time.sleep(SLEEP_MS / 1000.0)
            self._send(200, _jpeg, 'image/jpeg')
            return
        self._send(404, b'no', 'text/plain')

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n) if n else b''
        if self.path.startswith('/api/search/get'):
            calls['search'] += 1
            q = parse_qs(raw.decode('utf-8', 'replace')).get('s', [''])[0]
            doc = search_response()
            # 回显查询词，让 cover_pick_pic 的 Dice 打分必然命中
            for k in ('name',):
                doc['result']['albums'][0][k] = q
            doc['result']['albums'][0]['artists'][0]['name'] = q
            doc['result']['albums'][0]['artist']['name'] = q
            self._send(200, json.dumps(doc, ensure_ascii=False).encode(), 'application/json')
            return
        self._send(404, b'no', 'text/plain')


srv = ThreadingHTTPServer(('127.0.0.1', PORT), H)
print('mock cover host on http://127.0.0.1:%d/  (cover delay %d ms)' % (PORT, SLEEP_MS), flush=True)
srv.serve_forever()
