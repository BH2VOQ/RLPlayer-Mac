#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
"""Real isolated HTTP regression; never opens an audio device or touches port 8899."""
import argparse, hashlib, io, json, os, pathlib, socket, subprocess, tempfile, time, urllib.request, urllib.error, urllib.parse, wave, zipfile
p=argparse.ArgumentParser();p.add_argument('--binary',default='build-mac/rtaweb');p.add_argument('--keep',action='store_true');args=p.parse_args()
binary=str(pathlib.Path(args.binary).resolve());root=pathlib.Path(tempfile.mkdtemp(prefix='rlp-111-http-'));port=19101
with socket.socket() as sock: sock.bind(('127.0.0.1',port))
env=os.environ.copy();env.update(HOME=str(root/'home'),RLPLAYER_STATE_DIR=str(root/'state'),RLPLAYER_LIBRARY_DIR=str(root/'library'),RLPLAYER_COVER_DIR=str(root/'covers'))
for key in ('HOME','RLPLAYER_STATE_DIR','RLPLAYER_LIBRARY_DIR','RLPLAYER_COVER_DIR'):pathlib.Path(env[key]).mkdir(parents=True)
(root/'music').mkdir();(root/'state'/'rlplayer-settings.conf').write_text('backend=null\nmetaon=0\nmetallm=0\nvolume=-60\n')
files=[]
for i in range(4):
 f=root/'music'/f'silence-{i}.wav'
 with wave.open(str(f),'wb') as w:w.setparams((1,2,8000,8000,'NONE','not compressed'));w.writeframes(b'\x00\x00'*8000)
 files.append(str(f))
log=open(root/'server.txt','wb');proc=None
base=f'http://127.0.0.1:{port}'
def req(path,body=None,raw=False):
 data=None if body is None else (json.dumps(body).encode() if isinstance(body,dict) else body.encode())
 r=urllib.request.Request(base+path,data=data,headers={'Content-Type':'application/json' if isinstance(body,dict) else 'application/x-www-form-urlencoded'})
 try:
  with urllib.request.urlopen(r,timeout=20) as response:b=response.read();status=response.status
 except urllib.error.HTTPError as e:b=e.read();status=e.code
 return (status,b if raw else json.loads(b))
def start():
 global proc
 proc=subprocess.Popen([binary,'--port',str(port),'--no-browser','--music-dir',str(root/'music')],env=env,cwd=root,stdout=log,stderr=log)
 for _ in range(100):
  if proc.poll() is not None:raise RuntimeError('server exited')
  try:
   if req('/api/ping')[1].get('ok'):return
  except (OSError,ValueError):pass
  time.sleep(.1)
 raise RuntimeError('server start timed out')
def stop():
 global proc
 if proc and proc.poll() is None:
  proc.terminate();proc.wait(timeout=15)
 proc=None
checks=[]
def ck(v,name):
 checks.append({'name':name,'pass':bool(v)});print(('PASS ' if v else 'FAIL ')+name,flush=True)
try:
 start()
 for f in files[:3]:ck(req('/api/add',urllib.parse.urlencode({'file':f}))[1].get('ok'),'add synthetic queue item')
 _,before=req('/api/queue');ck(before.get('count',len(before.get('items',[])))==3,'queue starts with three')
 # Null backend only, explicit in request; digital silence does not leave this process.
 _,play=req('/api/play',urllib.parse.urlencode({'file':files[3],'backend':'null','rate':8000,'bits':16,'vol':-60}))
 ck(play.get('ok') and play.get('count')==4,'outside track appends instead of replacing')
 req('/api/stop','')
 _,queue=req('/api/queue');ck(len(queue.get('items',[]))==4,'prior queue entries preserved')
 req('/api/clear','')
 for a,b in ((0,.3),(.3,.6)):
  ck(req('/api/add',urllib.parse.urlencode({'file':files[0],'cue_start':a,'cue_end':b}))[1].get('ok'),'CUE range accepted')
 _,cue=req('/api/queue');(root/'queue-before.json').write_text(json.dumps(cue))
 ck(len(cue.get('items',[]))==2,'same source different CUE intervals remain distinct')
 for file in ('',str(root/'missing.wav')):
  _,health=req('/api/track/health?'+urllib.parse.urlencode({'file':file}))
  ck(not health.get('ok') and health.get('usable') is False and health.get('health',{}).get('lufs') is None,'health failures do not expose zero metrics')
 bad=root/'bad.wav';bad.write_bytes(b'not a wave')
 status,health=req('/api/track/health?'+urllib.parse.urlencode({'file':str(bad)}));ck(status==422 and not health.get('ok'),'corrupt WAV error contract')
 secret='DO_NOT_LOG_THIS_SECRET'
 status,posted=req('/api/ui/events',{'events':[{'evt':'error','code':'UI_EXC','where':'app.js:20','msg':secret,'body':secret,'path':'/api/llm?key='+secret}]})
 ck(status==200 and posted.get('stored')==1,'UI events endpoint persists allowlisted event')
 _,ui=req('/api/ui/events');ck(len(ui.get('events',[]))==1 and secret not in json.dumps(ui),'UI event text and query excluded')
 _,diag=req('/api/diag');case=diag.get('case_id');ck(bool(case) and diag.get('events',{}).get('present'),'live diagnostic snapshot has case and real event log')
 status,blob=req('/api/diagzip',raw=True);z=zipfile.ZipFile(io.BytesIO(blob));names=z.namelist();ck(all(x in names for x in ('manifest.json','diag.json','events.jsonl','uievents.jsonl','report.txt','checksums.txt')),'v2 diagnostic payload complete')
 manifest=json.loads(z.read('manifest.json'));ck(manifest.get('case_id')==case,'snapshot and package share case ID')
 ck(all(hashlib.sha256(z.read(e['name'])).hexdigest()==e['sha256'] and len(z.read(e['name']))==e['bytes'] for e in manifest['entries']),'independent Python SHA256 checks all payload bytes')
 ck(secret.encode() not in b''.join(z.read(n) for n in names),'no telemetry secret in any ZIP member')
 ck(len(blob)<=12*1024*1024,'ZIP within 12MB budget')
 (root/'case.zip').write_bytes(blob)
 stop();start();_,after=req('/api/queue');ck(after.get('items')==cue.get('items'),'queue and CUE intervals survive restart')
 _,diag=req('/api/diag');ck(diag.get('runState',{}).get('lastExit')=='clean','normal TERM shutdown marked clean')
finally:
 stop();log.close();(root/'results.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2));print('EVIDENCE',root,flush=True)
raise SystemExit(0 if checks and all(x['pass'] for x in checks) else 1)
