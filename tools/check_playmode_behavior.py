#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
"""Real null-sink & loopback Mock UPnP playback: prove advancement across all modes."""
import argparse
import http.server
import json
import socketserver
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('url')
p.add_argument('state_dir', type=Path)
a = p.parse_args()
results = []

def api(route, body=None):
    data = None if body is None else urllib.parse.urlencode(body).encode()
    request = urllib.request.Request(a.url.rstrip('/') + route, data=data)
    with urllib.request.urlopen(request, timeout=10) as r:
        return json.load(r)

def check(ok, what, detail):
    results.append({'ok': bool(ok), 'what': what, 'detail': detail})
    print(('PASS ' if ok else 'FAIL ') + what + ': ' + str(detail))

kv = api('/api/settings').get('kv', {})
if kv.get('backend') != 'null':
    raise SystemExit('ABORT: isolated test must use backend=null')
files = sorted((a.state_dir / 'music').glob('*.wav'))
if len(files) < 3:
    raise SystemExit('ABORT: need three isolated WAV fixtures')
log = a.state_dir / 'rlplayer-playback.log'
try:
    for mode in range(4):
        api('/api/stop', {})
        api('/api/clear', {})
        api('/api/playmode?mode=0', {})
        for f in files:
            assert api('/api/add', {'file': str(f)})['ok']
        api('/api/playmode?mode=' + str(mode), {})
        offset = log.stat().st_size if log.exists() else 0
        order = api('/api/queue')['items']
        api('/api/play', {'file': order[0], 'backend': 'null', 'volume': '-60',
                          'rate': 'follow', 'filter': '', 'shaper': 'none'})
        deadline = time.monotonic() + 5
        names = []
        while time.monotonic() < deadline:
            text = log.read_bytes()[offset:].decode('utf-8', 'replace')
            names = [ln.split('START file=', 1)[1].split(' cue=', 1)[0].strip()
                     for ln in text.splitlines() if 'START file=' in ln]
            if (mode == 0 and len(names) >= 3 and not api('/api/status').get('playing')) or (mode != 0 and len(names) >= 4):
                break
            time.sleep(.08)
        api('/api/stop', {})
        if mode == 0:
            check(names == order, 'sequential plays once then stops', names)
        elif mode == 1:
            check(len(names) >= 4 and names[:4] == order + [order[0]], 'list repeat wraps to first', names)
        elif mode == 2:
            check(len(names) >= 4 and all(n == order[0] for n in names), 'single repeat stays on same item', names)
        else:
            check(len(names) >= 4 and all(x != y for x, y in zip(names, names[1:])), 'random never immediately repeats current', names)
        check(not api('/api/status').get('error'), f'mode {mode} has no playback error', api('/api/status').get('error'))

    # 2) Mid-playback mode switch (0 -> 3 -> 0) must keep queue.index on current track and continue playing
    api('/api/stop', {})
    api('/api/clear', {})
    api('/api/playmode?mode=0', {})
    for f in files:
        assert api('/api/add', {'file': str(f)})['ok']
    base_order = api('/api/queue')['items']
    api('/api/play', {'file': base_order[0], 'backend': 'null', 'volume': '-60',
                      'rate': 'follow', 'filter': '', 'shaper': 'none'})
    api('/api/pause?on=1', {})
    index_kept = True
    for _ in range(15):
        api('/api/playmode?mode=3', {})
        q3 = api('/api/queue')
        if q3['items'][q3['index']] != base_order[0]:
            index_kept = False
        if q3['index'] != 0:
            break
        api('/api/playmode?mode=0', {})
    api('/api/playmode?mode=0', {})
    q0 = api('/api/queue')
    check(index_kept and q0['items'] == base_order and q0['index'] == 0,
          'mid-playback shuffle/unshuffle preserves current track index', q0)
    offset = log.stat().st_size if log.exists() else 0
    api('/api/pause?on=0', {})
    deadline = time.monotonic() + 5
    rest = []
    while time.monotonic() < deadline:
        text = log.read_bytes()[offset:].decode('utf-8', 'replace')
        rest = [ln.split('START file=', 1)[1].split(' cue=', 1)[0].strip()
                for ln in text.splitlines() if 'START file=' in ln]
        if len(rest) >= len(base_order) - 1 and not api('/api/status').get('playing'):
            break
        time.sleep(.08)
    check(rest == base_order[1:], 'mid-playback 0->3->0 continues remaining tracks in order', rest)

    # 3) Loopback Mock UPnP Renderer: prove UPnP auto-advances across all 4 modes
    upnp_lock = threading.Lock()
    upnp_cfg = {'state': 'STOPPED', 'uri': '', 'title': '', 'play_at': 0.0, 'played': []}

    class _Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
        daemon_threads = True

    class _Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            body = (
                '<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
                '<friendlyName>CheckPlaymodeMock</friendlyName><modelName>Mock</modelName>'
                '<UDN>uuid:check-playmode-mock</UDN><serviceList><service>'
                '<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
                '<controlURL>/upnp/control/AVTransport1</controlURL>'
                '</service></serviceList></device></root>'
            ).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/xml')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            n = int(self.headers.get('Content-Length', '0'))
            req = self.rfile.read(n).decode('utf-8', 'replace')
            sa = self.headers.get('SOAPAction', '')
            if 'SetAVTransportURI' in sa or 'SetAVTransportURI' in req:
                s = req.find('<CurrentURI>')
                e = req.find('</CurrentURI>')
                uri = req[s + 12:e] if s >= 0 and e > s else ''
                title = ''
                for m1, m2 in (('&lt;dc:title&gt;', '&lt;/dc:title&gt;'), ('<dc:title>', '</dc:title>')):
                    if m1 in req:
                        i1 = req.find(m1) + len(m1)
                        i2 = req.find(m2, i1)
                        if i2 > i1:
                            title = req[i1:i2]
                            break
                with upnp_lock:
                    upnp_cfg['uri'] = uri
                    upnp_cfg['title'] = title
                resp = "<u:SetAVTransportURIResponse xmlns:u='urn:schemas-upnp-org:service:AVTransport:1'/>"
            elif '"Play"' in sa or '<u:Play' in req:
                with upnp_lock:
                    uri = upnp_cfg['uri']
                    title = upnp_cfg['title']
                if uri:
                    try:
                        urllib.request.urlopen(uri, timeout=2).read()
                    except Exception:
                        pass
                with upnp_lock:
                    upnp_cfg['state'] = 'PLAYING'
                    upnp_cfg['play_at'] = time.monotonic()
                    upnp_cfg['played'].append(title)
                resp = "<u:PlayResponse xmlns:u='urn:schemas-upnp-org:service:AVTransport:1'/>"
            elif 'GetTransportInfo' in sa or 'GetTransportInfo' in req:
                with upnp_lock:
                    if upnp_cfg['state'] == 'PLAYING' and (time.monotonic() - upnp_cfg['play_at']) >= 0.35:
                        upnp_cfg['state'] = 'STOPPED'
                    st = upnp_cfg['state']
                resp = (
                    "<u:GetTransportInfoResponse xmlns:u='urn:schemas-upnp-org:service:AVTransport:1'>"
                    f'<CurrentTransportState>{st}</CurrentTransportState>'
                    '<CurrentTransportStatus>OK</CurrentTransportStatus>'
                    '<CurrentSpeed>1</CurrentSpeed></u:GetTransportInfoResponse>'
                )
            elif 'GetPositionInfo' in sa or 'GetPositionInfo' in req:
                resp = (
                    "<u:GetPositionInfoResponse xmlns:u='urn:schemas-upnp-org:service:AVTransport:1'>"
                    '<TrackDuration>00:00:01</TrackDuration><RelTime>00:00:00</RelTime>'
                    '</u:GetPositionInfoResponse>'
                )
            elif 'GetMediaInfo' in sa or 'GetMediaInfo' in req:
                resp = "<u:GetMediaInfoResponse xmlns:u='urn:schemas-upnp-org:service:AVTransport:1'><NrTracks>1</NrTracks></u:GetMediaInfoResponse>"
            else:
                with upnp_lock:
                    upnp_cfg['state'] = 'STOPPED'
                resp = "<u:StopResponse xmlns:u='urn:schemas-upnp-org:service:AVTransport:1'/>"
            xml = (
                "<?xml version='1.0'?><s:Envelope xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'>"
                f'<s:Body>{resp}</s:Body></s:Envelope>'
            ).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/xml')
            self.send_header('Content-Length', str(len(xml)))
            self.end_headers()
            self.wfile.write(xml)

    httpd = _Server(('127.0.0.1', 0), _Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    upnp_url = f'http://127.0.0.1:{httpd.server_address[1]}/desc.xml'
    try:
        for mode in range(4):
            api('/api/stop', {})
            api('/api/clear', {})
            api('/api/playmode?mode=0', {})
            for f in files[:3]:
                assert api('/api/add', {'file': str(f)})['ok']
            api('/api/playmode?mode=' + str(mode), {})
            order = api('/api/queue')['items']
            order_names = [Path(x).name for x in order]
            with upnp_lock:
                upnp_cfg['played'].clear()
            api('/api/play', {'file': order[0], 'backend': 'upnp', 'upnpdev': upnp_url, 'volume': '-60'})
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                with upnp_lock:
                    cnt = len(upnp_cfg['played'])
                if (mode == 0 and cnt >= 3 and not api('/api/status').get('playing')) or (mode != 0 and cnt >= 4):
                    break
                time.sleep(.08)
            api('/api/stop', {})
            with upnp_lock:
                u_names = list(upnp_cfg['played'])
            if mode == 0:
                check(u_names == order_names, 'UPnP sequential plays once then stops', u_names)
            elif mode == 1:
                check(len(u_names) >= 4 and u_names[:4] == order_names + [order_names[0]], 'UPnP list repeat wraps to first', u_names)
            elif mode == 2:
                check(len(u_names) >= 4 and all(n == order_names[0] for n in u_names), 'UPnP single repeat stays on same item', u_names)
            else:
                check(len(u_names) >= 4 and set(u_names[:3]) == set(order_names) and all(x != y for x, y in zip(u_names, u_names[1:])),
                      'UPnP random plays deck and never immediately repeats current', u_names)
    finally:
        api('/api/settings', {'backend': 'null', 'upnpdev': ''})
        httpd.shutdown()
finally:
    api('/api/stop', {})
    api('/api/playmode?mode=0', {})
    (a.state_dir / 'behavior-result.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(r['ok'] for r in results) else 1)
