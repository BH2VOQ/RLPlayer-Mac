#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only real-library acceptance in copied, isolated state. Never plays audio.

Explicit --index/--music inputs are copied/read, never changed. Evidence stays
outside the repository. Run serially after build/tests, not during heavy IO.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from check_startup_cover_cache import Service, check, RESULTS, wait_until

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--binary', default='build-mac/rtaweb')
ap.add_argument('--index', required=True)
ap.add_argument('--music', required=True)
ap.add_argument('--out', required=True)
ap.add_argument('--port', type=int, default=19102)
ap.add_argument('--browser-port', type=int, default=9732)
a = ap.parse_args()
repo = Path(__file__).resolve().parent.parent
out = Path(a.out).resolve()
out.mkdir(parents=True, exist_ok=True)
root = out / 'isolated'
# Service creates its own root/music; real media is only referenced in config.
if root.exists():
    raise SystemExit('Use a fresh output directory to keep cold/hot evidence unambiguous.')
s = Service(root, Path(a.binary).resolve(), a.port)
s.env.pop('RLPLAYER_FFMPEG', None)
s.env.pop('RLPLAYER_FFPROBE', None)
s.env['RLPLAYER_FFMPEG'] = str(repo / 'build-mac/ffmpeg-lite/ffmpeg')
s.env['RLPLAYER_FFPROBE'] = str(repo / 'build-mac/ffmpeg-lite/ffprobe')
source = Path(a.index).resolve()
before_source = (source.stat().st_mtime_ns, source.stat().st_size)
shutil.copyfile(source, s.index)
(s.lib / f'rlplayer-library.conf.p{a.port}').write_text(str(Path(a.music).resolve()) + '\n')
s.settings.write_text('scanonstartup=0\nbackend=null\nmetaon=0\nmetallm=0\n')
# Prevent online cover enrichment from changing this local-cover experiment.
s.env['RLPLAYER_COVER_HOST'] = 'http://127.0.0.1:1'
node = r'''
const fs=require('fs'), ub=require(process.argv[1]+'/tools/uibrowser');
const [base,folder,cdp]=process.argv.slice(2);let session;
(async()=>{try{
 session=await ub.open({width:1576,height:908,port:+cdp,cdpTimeoutMs:20000});
 // Suppress automatic covers before document startup, not after cold work began.
 await session.send('Page.addScriptToEvaluateOnNewDocument',{source:`window.__coverHold=true;const realFetch=window.fetch;window.__coverRealFetch=realFetch;window.fetch=function(input,init){const p=new URL(String(input),location.href).pathname;if(p==='/api/lib/cover/prefetch')return Promise.resolve(new Response('{"ok":true,"queued":0,"running":false}',{headers:{'Content-Type':'application/json'}}));if(window.__coverHold&&p==='/api/lib/cover')return Promise.reject(new DOMException('held for proof','AbortError'));return realFetch.apply(this,arguments);};`});
 await session.send('Page.navigate',{url:base});
 if(!await session.waitFor("typeof coverImageLoad==='function' && S.albums.length>0",20000))throw Error('real albums document did not load');
 await session.eval(`(()=>{window.__coverProof={done:0,loaded:0,failed:0,statuses:[],ping:[],timings:[]};
 const p=window.__coverProof,orig=window.__coverRealFetch;
 window.fetch=function(input,init){const u=String(input),t=performance.now();return orig.apply(this,arguments).then(r=>{if(u.includes('/api/lib/cover?')){p.statuses.push(r.status);p.timings.push(performance.now()-t);}return r;});};
 p.timer=setInterval(()=>{const t=performance.now();orig('/api/ping').then(r=>r.json()).then(j=>{if(j.ok)p.ping.push(performance.now()-t);});},100);
 // Clear original lazy cards, cancel their queue, then exercise the same helper
 // with the first 60 real albums in production order (no mocked cover bytes).
 const keys=S.albums.filter(a=>a.cv).slice(0,60).map(a=>a.k);p.keys=keys;
 const box=document.getElementById('list');box.innerHTML='';box.style.display='grid';box.style.gridTemplateColumns='repeat(10,1fr)';window.__coverHold=false;
 keys.forEach(k=>{const img=document.createElement('img');img.style.cssText='width:110px;height:110px;object-fit:contain';img.onload=()=>{p.loaded++;p.done++;};img.onerror=()=>{p.failed++;p.done++;};box.appendChild(img);coverImageLoad(img,'/api/lib/cover?k='+k);});return keys.length;})()`);
 const done=await session.waitFor('window.__coverProof.done===window.__coverProof.keys.length',240000);
 await session.eval('clearInterval(window.__coverProof.timer)');
 await session.eval(`(async()=>{for(let i=0;i<5;i++){const t=performance.now();const r=await window.__coverRealFetch('/api/ping');if(r.ok)window.__coverProof.ping.push(performance.now()-t);}})()`);
 const result=await session.eval('JSON.stringify(window.__coverProof)');fs.writeFileSync(folder+'/browser.json',result);await session.shot(folder+'/covers.png');
 console.log(result);if(!done||JSON.parse(result).failed)process.exitCode=1;
 }finally{if(session)await session.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
'''

def browser(phase):
    log_offset = len(s.playback_lines())
    dest = out / phase
    dest.mkdir()
    result = subprocess.run(['node', '-e', node, str(repo), f'http://127.0.0.1:{a.port}/', str(dest), str(a.browser_port)], text=True, capture_output=True, timeout=300)
    (dest / 'browser-stdout.txt').write_text(result.stdout)
    (dest / 'browser-stderr.txt').write_text(result.stderr)
    data = json.loads((dest / 'browser.json').read_text()) if (dest / 'browser.json').exists() else {}
    check(result.returncode == 0 and data.get('loaded') == 60, phase + ' real browser loads sixty local covers', data)
    pings = sorted(data.get('ping', []))
    check(bool(pings) and pings[int((len(pings)-1)*.95)] < 50, phase + ' ping p95 below 50ms', pings[-10:])
    selected = set(data.get('keys', []))
    events = []
    for line in s.playback_lines()[log_offset:]:
        if 'COVERGET ' not in line:
            continue
        fields = dict(x.split('=', 1) for x in line.split() if '=' in x)
        if fields.get('k') in selected:
            events.append(fields)
    sources = {}
    for event in events:
        name = event.get('src', 'unknown')
        sources[name] = sources.get(name, 0) + 1
    (dest / 'coverget-sources.json').write_text(json.dumps(sources, indent=2))
    check(sources.get('none', 0) == 0 and sources.get('busy', 0) == 0, phase + ' has no none or busy cover storm', sources)
    if phase == 'hot':
        check(sources.get('embedcache') == 60 and sum(sources.values()) == 60, 'hot sixty covers all hit persistent local cache', sources)
    check(not data.get('failed') and all(code == 200 for code in data.get('statuses', [])), phase + ' cover responses are HTTP200', data.get('statuses'))
    return data

try:
    s.start()
    check(s.api('/api/lib/scan', b'').get('ok'), 'manual isolated real-library scan accepted')
    end = time.monotonic() + 600
    status = {}
    while time.monotonic() < end:
        status = s.api('/api/lib/status')
        if not status['scanning']:
            break
        time.sleep(.5)
    (out / 'scan-status.json').write_text(json.dumps(status, ensure_ascii=False, indent=2))
    check(not status.get('scanning') and status.get('complete'), 'real library scan produces clean fingerprint', status)
    browser('cold')
    s.stop()
    s.settings.write_text('scanonstartup=1\nbackend=null\nmetaon=0\nmetallm=0\n')
    index_mtime = s.index.stat().st_mtime_ns
    s.start()
    wait_until(lambda: not s.api('/api/lib/status')['scanning'], 300)
    check(s.index.stat().st_mtime_ns == index_mtime, 'SMB restart preserves index mtime')
    check('LIBSCAN startup skip reason=unchanged' in s.logs(), 'SMB startup skip logged')
    browser('hot')
    s.stop()
    text = s.logs()
    lines = [x for x in text.splitlines() if 'COVERGET ' in x]
    (out / 'coverget.txt').write_text('\n'.join(lines))
    check(before_source == (source.stat().st_mtime_ns, source.stat().st_size), 'original user index remains unchanged')
finally:
    s.stop()
    (out / 'results.json').write_text(json.dumps(RESULTS, ensure_ascii=False, indent=2))
print('EVIDENCE', out)
raise SystemExit(0 if all(x['ok'] for x in RESULTS) else 1)
