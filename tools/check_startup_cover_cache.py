#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
"""Real isolated rtaweb restarts; no playback, builds, or user-state writes.

Run: python3 tools/check_startup_cover_cache.py --binary build-mac/rtaweb
A failing baseline exits 1, retains logs, and does not weaken expectations.
Default includes an actual 61-second offline interval. --quick omits that
case explicitly (not a substitute for full acceptance). UI uses uibrowser.js
with controlled cover HTTP responses; the rest uses real service endpoints.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zlib

REPO = Path(__file__).resolve().parent.parent
RESULTS = []


def check(ok, name, detail=""):
    RESULTS.append({"ok": bool(ok), "name": name, "detail": str(detail)})
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}", flush=True)


def wait_until(fn, timeout=25):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = fn()
        if value:
            return value
        time.sleep(0.08)
    raise RuntimeError("bounded wait expired")


def png(seed=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = b"".join(b"\0" + bytes((i * 17 + j * 29 + seed) % 256 for i in range(32 * 3)) for j in range(32))
    # Stored deflate keeps the fixture >1KB (cover/set minimum), no image tools.
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels, 0)) + chunk(b"IEND", b"")


def wav(path, image=None, title="Fixture"):
    def chunk(kind, data):
        return kind + struct.pack("<I", len(data)) + data + (b"\0" if len(data) % 2 else b"")
    def frame(kind, data):
        return kind + struct.pack(">I", len(data)) + b"\0\0" + data
    frames = frame(b"TIT2", b"\0" + title.encode())
    if image:
        frames += frame(b"APIC", b"\0image/png\0\x03Cover\0" + image)
    n = len(frames)
    tag = b"ID3\x03\0\0" + bytes((n >> 21 & 127, n >> 14 & 127, n >> 7 & 127, n & 127)) + frames
    chunks = chunk(b"fmt ", struct.pack("<HHIIHH", 1, 2, 44100, 176400, 4, 16))
    chunks += chunk(b"data", bytes(17640)) + chunk(b"id3 ", tag)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks)


def owned_listener(pid, owner):
    """A spawned probe can inherit the listening FD; verify its full parent chain."""
    seen = set()
    while pid not in seen:
        if pid == owner:
            return True
        seen.add(pid)
        r = subprocess.run(["ps", "-p", str(pid), "-o", "uid=,ppid="], capture_output=True, text=True)
        fields = r.stdout.split()
        if len(fields) != 2 or int(fields[0]) != os.getuid():
            return False
        pid = int(fields[1])
        if pid <= 1:
            return False
    return False


def listeners(port):
    r = subprocess.run(["lsof", "-nP", "-a", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"], capture_output=True, text=True)
    if r.returncode == 1 and not r.stdout and not r.stderr:
        return set()
    if r.returncode != 0:
        raise RuntimeError("lsof failed: " + r.stderr)
    return {int(x[1:]) for x in r.stdout.splitlines() if x.startswith("p")}


class Service:
    def __init__(self, root, binary, port):
        self.root, self.binary, self.port = root, binary, port
        self.proc = None
        self.serial = 0
        self.env = os.environ.copy()
        for key, leaf in (("HOME", "home"), ("RLPLAYER_STATE_DIR", "state"), ("RLPLAYER_LIBRARY_DIR", "library"), ("RLPLAYER_COVER_DIR", "covers")):
            p = root / leaf
            p.mkdir(parents=True, exist_ok=True)
            self.env[key] = str(p)
        self.music = root / "music"
        self.music.mkdir()
        self.lib = root / "library"
        self.index = self.lib / f"rlplayer-index.tsv.p{port}"
        # Persist roots once; --music-dir on restart removes existing tracks.
        (self.lib / f"rlplayer-library.conf.p{port}").write_text(str(self.music) + "\n")
        self.settings = root / "state" / "rlplayer-settings.conf"
        self.settings.write_text("scanthreads=1\nscanonstartup=1\n")
        self.count = root / "extract-count.txt"
        self.delay = root / "extract-delay.txt"
        self.delay.write_text("0")
        self.fixture = root / "fixture.png"
        self.fixture.write_bytes(png())
        fake = root / "fake-ffmpeg"
        fake.write_text(f"#!{sys.executable}\n" + '''import os, pathlib, sys, time
if '-version' in sys.argv:
    print('ffmpeg fixture counter'); sys.exit(0)
with open(os.environ['COVER_TEST_COUNT'], 'a') as f: f.write('extract\\n')
time.sleep(float(pathlib.Path(os.environ['COVER_TEST_DELAY']).read_text()))
pathlib.Path(sys.argv[-1]).write_bytes(pathlib.Path(os.environ['COVER_TEST_PNG']).read_bytes())
''')
        fake.chmod(0o755)
        self.env.update(RLPLAYER_FFMPEG=str(fake), COVER_TEST_COUNT=str(self.count), COVER_TEST_DELAY=str(self.delay), COVER_TEST_PNG=str(self.fixture), RLPLAYER_FFPROBE=str(REPO / "build-mac/ffmpeg-lite/ffprobe"))

    def start(self):
        if listeners(self.port):
            raise RuntimeError(f"port {self.port} occupied; no HTTP sent")
        self.serial += 1
        self.stdout_path = self.root / f"server-{self.serial}.log"
        self.output = self.stdout_path.open("w")
        self.proc = subprocess.Popen([str(self.binary), "--port", str(self.port), "--no-browser"], cwd=self.root, env=self.env, stdout=self.output, stderr=subprocess.STDOUT)
        print(f"START pid={self.proc.pid} parent={os.getpid()} port={self.port}", flush=True)
        def ready():
            if self.proc.poll() is not None:
                raise RuntimeError(f"service exited {self.proc.returncode}: {self.stdout_path}")
            owner = listeners(self.port)
            if owner and not all(owned_listener(pid, self.proc.pid) for pid in owner):
                raise RuntimeError(f"unexpected listener {owner}")
            if not owner:
                return False
            return self.get("/api/ping")[0] == 200
        wait_until(ready)
        # HTTP workers start slightly before CLI installs its TERM handler.
        # Let main finish startup before a tiny-fixture test immediately stops it.
        time.sleep(0.25)
        if self.proc.poll() is not None:
            raise RuntimeError(f"service exited after HTTP readiness: {self.proc.returncode}")
        return self

    def stop(self):
        if not self.proc:
            return
        p = self.proc
        if p.poll() is None:
            row = subprocess.check_output(["ps", "-p", str(p.pid), "-o", "uid=,ppid=,comm="], text=True).strip().split(None, 2)
            if int(row[0]) != os.getuid() or int(row[1]) != os.getpid() or Path(row[2]).name != self.binary.name:
                raise RuntimeError("service identity mismatch; no signal sent")
            owner = listeners(self.port)
            if owner and not all(owned_listener(pid, p.pid) for pid in owner):
                raise RuntimeError("listener identity mismatch; no signal sent")
            p.send_signal(signal.SIGTERM)
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                raise RuntimeError(f"owned pid={p.pid} did not exit after TERM; retained, no force kill")
        self.output.close()
        owners = listeners(self.port)
        print(f"STOP pid={p.pid} exit={p.returncode} port_owners={sorted(owners)}", flush=True)
        self.proc = None
        check(p.returncode == 0 and not owners, "owned service exits cleanly after TERM", f"pid={p.pid} exit={p.returncode} port_owners={sorted(owners)}")

    def get(self, path, body=None, timeout=20):
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}" + path, data=body)
        # Ignore ambient proxies for loopback, do not inherit user proxy settings.
        try:
            response = urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            response = e
        with response:
            return response.status, dict(response.headers), response.read()

    def api(self, path, body=None):
        code, _, data = self.get(path, body)
        if code != 200:
            raise RuntimeError(f"{path}: HTTP{code} {data[:160]!r}")
        return json.loads(data)

    def settled(self, tracks=None):
        def done():
            j = self.api("/api/lib/status")
            return j if not j["scanning"] and (tracks is None or j["tracks"] == tracks) else False
        return wait_until(done, 45)

    def extracts(self):
        return len(self.count.read_text().splitlines()) if self.count.exists() else 0

    def logs(self):
        return "\n".join(p.read_text(errors="replace") for p in sorted(self.root.rglob("*log*")) if p.is_file())

    def playback_lines(self):
        # Only the real playback log carries COVERGET/LIBSCAN lines; other *.log files
        # (server stdout) must never be sliced by offset: rglob order is not stable.
        p = self.root / "state" / "rlplayer-playback.log"
        return p.read_text(errors="replace").splitlines() if p.exists() else []


def scan_suite(root, binary, port, quick):
    s = Service(root / "scan", binary, port)
    try:
        wav(s.music / "Album" / "one.wav")
        s.start(); s.settled(1); s.stop()
        old = s.index.stat().st_mtime_ns
        s.start(); s.settled(1); time.sleep(0.3); s.stop()
        check(s.index.stat().st_mtime_ns == old, "immediate restart leaves index mtime unchanged")
        # Force age without mutating any music/directory fingerprint.
        aged = time.time() - 120
        os.utime(s.index, (aged, aged))
        old = s.index.stat().st_mtime_ns
        s.start(); s.settled(1); time.sleep(0.3); s.stop()
        check(s.index.stat().st_mtime_ns == old, "aged index alone does not trigger scan", f"before={old} after={s.index.stat().st_mtime_ns}")
        check("startup skip reason=unchanged" in s.logs(), "startup unchanged decision is logged")
        # Refresh index via an explicit user scan, then actually remain offline 61s.
        s.start(); s.api("/api/lib/scan", b""); s.settled(1); s.stop()
        old = s.index.stat().st_mtime_ns
        if quick:
            print("[SKIP] actual 61-second offline restart (--quick)", flush=True)
        else:
            print("WAIT actual offline interval=61 seconds", flush=True)
            t0 = time.monotonic(); time.sleep(61)
            s.start(); s.settled(1); time.sleep(0.3); s.stop()
            check(s.index.stat().st_mtime_ns == old, "actual 61-second restart leaves index unchanged", f"elapsed={time.monotonic()-t0:.2f}s before={old} after={s.index.stat().st_mtime_ns}")
        wav(s.music / "Album" / "two.wav")
        s.start()
        try:
            j = s.settled(2)
            check(True, "new file triggers startup scan", j)
        except RuntimeError:
            check(False, "new file triggers startup scan", s.api("/api/lib/status"))
        finally:
            s.stop()
        wav(s.music / "New Album" / "three.wav")
        s.start()
        try:
            check(True, "new subdirectory triggers startup scan", s.settled(3))
        except RuntimeError:
            check(False, "new subdirectory triggers startup scan", s.api("/api/lib/status"))
        finally:
            s.stop()
        # Slow real ffprobe with a wrapper; wait until a probe is observed before
        # TERM. This proves an in-progress scan, not a lucky clean shutdown.
        marker = s.root / "probe-entered"
        slow = s.root / "slow-ffprobe"
        slow.write_text(f"#!{sys.executable}\n" + "import os, pathlib, sys, time\n" + f"tool={str(REPO / 'build-mac/ffmpeg-lite/ffprobe')!r}\n" + f"marker={str(marker)!r}\n" + "if '-version' not in sys.argv:\n pathlib.Path(marker).write_text('entered')\n time.sleep(1)\nos.execv(tool,[tool]+sys.argv[1:])\n")
        slow.chmod(0o755)
        s.env.update(RLPLAYER_FFPROBE=str(slow), RLPLAYER_NATIVE_TAGS="0")
        for i in range(8):
            wav(s.music / "Interrupted" / f"new-{i}.wav")
        s.start()
        # Explicit full scan also exercises interrupt invalidation of a formerly
        # clean fingerprint; startup must never accept it as a completed scan.
        s.api("/api/lib/scan", b"full=1")
        wait_until(marker.exists)
        check(s.api("/api/lib/status")["scanning"], "interrupted fixture is actively scanning before TERM")
        s.stop()
        s.env.pop("RLPLAYER_NATIVE_TAGS", None)
        s.env["RLPLAYER_FFPROBE"] = str(REPO / "build-mac/ffmpeg-lite/ffprobe")
        s.start()
        try:
            check(True, "interrupted scan is not mistaken for clean", s.settled(11))
        except RuntimeError:
            check(False, "interrupted scan is not mistaken for clean", s.api("/api/lib/status"))
    finally:
        s.stop()


def cover_suite(root, binary, port):
    s = Service(root / "cover", binary, port)
    try:
        source = s.music / "Embedded" / "one.wav"
        wav(source, png())
        s.start(); s.settled(1)
        album = s.api("/api/lib/albums")["albums"][0]
        check(album["cv"], "APIC fixture is detected by real library scanner", album)
        route = "/api/lib/cover?k=" + album["k"]
        n = s.extracts(); code, _, first = s.get(route)
        check(code == 200 and first == png() and s.extracts() - n == 1, "cold cover extracts once and matches exact fixture bytes", f"HTTP{code} extracts={s.extracts()-n} sha256={hashlib.sha256(first).hexdigest()}")
        s.stop(); n = s.extracts(); s.start(); s.settled(1)
        code, _, second = s.get(route)
        check(code == 200 and second == first and s.extracts() == n, "new process cover uses disk cache with zero extraction", f"HTTP{code} extracts={s.extracts()-n} bytes_equal={second==first}")
        check("src=embedcache" in s.logs(), "disk cover cache hit is observable as src=embedcache")
        s.stop()
        for label, mutate in (("mtime", lambda: os.utime(source, ns=(source.stat().st_atime_ns, source.stat().st_mtime_ns + 2_000_000_000))), ("size", lambda: source.write_bytes(source.read_bytes() + b"\0\0"))):
            mutate(); n = s.extracts(); s.start(); s.settled(1)
            code, _, body = s.get(route)
            check(code == 200 and body == first and s.extracts() - n == 1, f"source {label} invalidates persisted cover", f"HTTP{code} extracts={s.extracts()-n}")
            s.stop()
        s.start(); s.settled(1)
        manual = png(37)
        saved = s.api("/api/lib/cover/set?k=" + album["k"], manual)
        check(saved.get("ok"), "manual cover upload accepted", saved)
        n = s.extracts(); code, _, body = s.get(route)
        check(code == 200 and body == manual and s.extracts() == n, "manual cover wins immediately without extraction", f"HTTP{code} manual_equal={body==manual} extracts={s.extracts()-n}")
        s.stop(); n = s.extracts(); s.start(); s.settled(1)
        code, _, body = s.get(route)
        check(code == 200 and body == manual and s.extracts() == n, "manual cover wins after process restart", f"HTTP{code} manual_equal={body==manual} extracts={s.extracts()-n}")
        code, _, _ = s.get("/api/lib/cover?k=0000000000000000")
        check(code == 404, "genuinely absent cover is HTTP404", code)
    finally:
        s.stop()


UI_TEST = r'''
const ub = require(process.argv[1]);
(async () => {
  const s = await ub.open({port:19109, url:process.argv[2], settleMs:800});
  try {
    if (process.argv[4]) await s.eval(require('fs').readFileSync(process.argv[4], 'utf8'));
    const result = await s.eval(String.raw`(async function () {
      if (typeof coverImageLoad !== 'function') return [{ok:false,name:'cover helper exists in served app.js'}];
      const rows=[], counts={}, times={}, created=[], revoked=[], loaded={}, errors={};
      let active=0,maxActive=0,aborted=0;
      const original=window.fetch, create=URL.createObjectURL, revoke=URL.revokeObjectURL;
      const blob=new Blob([Uint8Array.from(atob('${process.argv[3]}'), c=>c.charCodeAt(0))],{type:'image/png'});
      URL.createObjectURL=function(b){const u=create.call(URL,b);created.push(u);return u;};
      URL.revokeObjectURL=function(u){revoked.push(u);return revoke.call(URL,u);};
      window.fetch=function(url,opt){
        if (!String(url).startsWith('/api/lib/cover?')) return original.apply(this,arguments);
        const key=new URL(url,location.href).searchParams.get('k');
        counts[key]=(counts[key]||0)+1;(times[key]||(times[key]=[])).push(Date.now());
        ++active;maxActive=Math.max(maxActive,active);
        return new Promise((resolve,reject)=>{
          let done=false;
          const finish=()=>{
            if(done)return;done=true;--active;
            const status=key.startsWith('missing')?404:key.startsWith('forever')?503:key.startsWith('busy')&&counts[key]===1?503:200;
            resolve(new Response(status===200?(key==='bad-blob'?new Blob(['not an image'],{type:'image/png'}):blob):JSON.stringify({ok:false,busy:status===503}),{status,headers:{'Retry-After':'0.12','Content-Type':status===200?'image/png':'application/json'}}));
          };
          const timer=setTimeout(finish,key.startsWith('slow')?600:35);
          if(opt&&opt.signal)opt.signal.addEventListener('abort',()=>{if(done)return;done=true;clearTimeout(timer);--active;++aborted;reject(new DOMException('aborted','AbortError'));},{once:true});
        });
      };
      const host=document.createElement('div');document.body.appendChild(host);
      function add(key,html){
        const wrap=document.createElement('div');wrap.style.cssText='position:relative;width:80px;height:80px';
        wrap.innerHTML=html||'<img data-cover-src="/api/lib/cover?k='+key+'" style="width:80px;height:80px" onerror="this.style.display=\'none\'">';
        const img=wrap.querySelector('img');img.loading='eager';
        img.addEventListener('load',()=>loaded[key]=(loaded[key]||0)+1);
        img.addEventListener('error',()=>errors[key]=(errors[key]||0)+1);
        host.appendChild(wrap);return img;
      }
      const a=add('busy-grid',albumCardHtml({k:'busy-grid',name:'Album',artist:'Artist'},0));
      add('missing-grid',albumCardHtml({k:'missing-grid',name:'Missing',artist:'Artist'},1));
      add('forever-grid',albumCardHtml({k:'forever-grid',name:'Busy',artist:'Artist'},2));
      const artist=add('busy-artist','<img data-stage="artist" data-coverkey="busy-artist" style="width:80px;height:80px" onerror="artistAvatarFallback(this)">');
      artistAvatarFallback(artist);
      for(let i=0;i<6;i++)add('queue-'+i);
      await new Promise(r=>setTimeout(r,1400));
      rows.push({ok:counts['busy-grid']===2&&loaded['busy-grid']===1&&!errors['busy-grid'],name:'busy retries exactly once then native load',detail:{counts,loaded,errors}});
      rows.push({ok:times['busy-grid'][1]-times['busy-grid'][0]>=120,name:'busy obeys Retry-After delay',detail:times['busy-grid']});
      rows.push({ok:counts['missing-grid']===1&&errors['missing-grid']===1,name:'true404 never retries and preserves error fallback'});
      rows.push({ok:counts['forever-grid']===2&&errors['forever-grid']===1,name:'second busy stops without infinite retry'});
      rows.push({ok:counts['busy-artist']===2&&loaded['busy-artist']===1&&artist.dataset.stage==='cover',name:'artist album-cover fallback uses same helper'});
      rows.push({ok:maxActive===2,name:'cover queue never exceeds two active fetches',detail:maxActive});
      rows.push({ok:a.getBoundingClientRect().width>0&&a.style.display!=='none',name:'successful cover preserves original layout'});
      rows.push({ok:created.length>0&&created.every(u=>revoked.includes(u)),name:'decoded blob URLs are released',detail:{created:created.length,revoked:revoked.length}});
      const slow1=add('slow-one'),slow2=add('slow-two'),queued=add('removed-queued');
      await new Promise(r=>setTimeout(r,60));queued.parentNode.remove();slow1.parentNode.remove();
      await new Promise(r=>setTimeout(r,850));
      rows.push({ok:!counts['removed-queued']&&aborted>=1,name:'removed images cancel active fetch and skip queued work',detail:{counts,aborted}});
      const reuse=add('slow-replaced');await new Promise(r=>setTimeout(r,45));
      coverImageLoad(reuse,'/api/lib/cover?k=replacement');await new Promise(r=>setTimeout(r,850));
      rows.push({ok:counts.replacement===1&&loaded['slow-replaced']===1,name:'replaced image cancels stale request and loads new source'});
      const retryRemoved=add('busy-removed');await new Promise(r=>setTimeout(r,65));retryRemoved.parentNode.remove();
      await new Promise(r=>setTimeout(r,300));
      rows.push({ok:counts['busy-removed']===1,name:'removal cancels scheduled busy retry'});
      const lazy=add('lazy-offscreen');lazy.loading='lazy';lazy.parentNode.style.position='absolute';lazy.parentNode.style.top='100000px';
      // Replacement before the observer's microtask keeps the initial lazy state.
      await new Promise(r=>setTimeout(r,120));
      rows.push({ok:!counts['lazy-offscreen'],name:'offscreen lazy covers do not enter fetch queue'});
      const bad=add('decode-error');
      coverImageLoad(bad,'data:image/png;base64,AA==');
      await new Promise(r=>setTimeout(r,150));
      rows.push({ok:errors['decode-error']===1&&bad.style.display==='none'&&!counts['decode-error'],name:'nonlocal sources retain native decode error without cover fetch'});
      add('bad-blob');await new Promise(r=>setTimeout(r,150));
      rows.push({ok:counts['bad-blob']===1&&errors['bad-blob']===1&&created.every(u=>revoked.includes(u)),name:'invalid successful image body keeps decode error and releases blob'});
      host.remove();await new Promise(r=>setTimeout(r,20));
      rows.push({ok:created.every(u=>revoked.includes(u)),name:'all blob URLs released after removal'});
      window.fetch=original;URL.createObjectURL=create;URL.revokeObjectURL=revoke;
      return rows;
    })()`,15000);
    console.log(JSON.stringify(result));
  } finally { await s.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});
'''


def busy_suite(root, binary, port):
    s = Service(root / 'busy', binary, port)
    try:
        for i in range(3):
            wav(s.music / f'Busy Album {i}' / 'one.wav', png())
        s.delay.write_text('2.5')
        s.start(); s.settled(3)
        keys = [a['k'] for a in s.api('/api/lib/albums')['albums']]
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            futures = [executor.submit(s.get, '/api/lib/cover?k=' + key) for key in keys]
            responses = [f.result() for f in futures]
        busy = [(headers, data) for code, headers, data in responses if code == 503]
        check(len(busy) == 1 and sum(code == 200 for code, _, _ in responses) == 2,
              'saturated local cover gate returns busy not false404', [code for code, _, _ in responses])
        check(len(busy) == 1 and busy[0][0].get('Retry-After') == '2' and json.loads(busy[0][1]).get('busy') is True,
              'busy HTTP response carries Retry-After and explicit JSON body', busy)
    finally:
        s.stop()


def ui_suite(root, binary, port, source_helper=False):
    import base64
    s = Service(root / 'ui', binary, port)
    try:
        s.start(); s.settled(0)
        args = ['node', '-e', UI_TEST, str(REPO / 'tools/uibrowser.js'), f'http://127.0.0.1:{port}/', base64.b64encode(png()).decode()]
        if source_helper:
            # Explicit helper-only test, not evidence for a rebuilt binary.
            source = (REPO / 'src/net/ui_script.h').read_text()
            helper = source[source.index('/* ---------------- 本地专辑封面加载'):source.index('// 2026-10-26（封面在线抓取）：封面抓取要有')]
            fallback = source[source.index('function artistAvatarFallback(img)'):source.index('function artistCoverKey(who)')]
            override = s.root / 'helper-only.js'
            override.write_text(helper + '\n' + fallback)
            args.append(str(override))
            print('[INFO] source-helper mode: browser helper only, not rebuilt app validation', flush=True)
        r = subprocess.run(args, capture_output=True, text=True, timeout=55)
        (s.root / 'browser.log').write_text(r.stdout + r.stderr)
        if r.returncode:
            raise RuntimeError(f'UI browser exit={r.returncode}: {r.stderr}')
        for row in json.loads(r.stdout.strip().splitlines()[-1]):
            check(row['ok'], row['name'], row.get('detail', ''))
    finally:
        s.stop()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--binary", type=Path, default=REPO / "build-mac/rtaweb")
    p.add_argument("--port", type=int, default=19105)
    p.add_argument("--suite", choices=("scan", "cover", "busy", "ui", "all"), default="all")
    p.add_argument("--quick", action="store_true")
    p.add_argument("--source-helper", action="store_true", help="UI helper-only browser test before rebuild; not whole-app evidence")
    p.add_argument("--output", type=Path)
    args = p.parse_args()
    if not 19105 <= args.port <= 19108:
        p.error("test HTTP port must be in 19105..19108; 19109 is reserved for UI CDP")
    args.binary = args.binary.resolve(strict=True)
    root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="rlplayer-startup-cover-"))
    root.mkdir(parents=True, exist_ok=True)
    if any(root.iterdir()):
        p.error("output directory must be empty to prevent state reuse")
    print(f"ARTIFACTS {root}\nBINARY {args.binary}", flush=True)
    for suite in ("scan", "cover", "busy", "ui"):
        if args.suite not in (suite, "all"):
            continue
        try:
            if suite == "scan":
                scan_suite(root, args.binary, args.port, args.quick)
            elif suite == "cover":
                cover_suite(root, args.binary, args.port)
            elif suite == "busy":
                busy_suite(root, args.binary, args.port)
            else:
                ui_suite(root, args.binary, args.port, args.source_helper)
        except Exception as e:
            check(False, suite + " suite completed", repr(e))
    (root / "results.json").write_text(json.dumps(RESULTS, indent=2))
    failed = sum(not x["ok"] for x in RESULTS)
    print(f"SUMMARY {len(RESULTS)-failed} passed / {failed} failed; artifacts={root}", flush=True)
    return int(failed > 0)


if __name__ == "__main__":
    sys.exit(main())
