#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
"""Production rtaweb->persisted evidence->ZIP->separate rtadiag process, without audio IO."""
import argparse,json,os,pathlib,socket,struct,subprocess,tempfile,time,urllib.request,urllib.error,urllib.parse,wave,zipfile,io
ap=argparse.ArgumentParser();ap.add_argument('--binary',default='build-mac/rtaweb');ap.add_argument('--rtadiag',default='build-mac/rtadiag');a=ap.parse_args()
binary=str(pathlib.Path(a.binary).resolve());diag=str(pathlib.Path(a.rtadiag).resolve());base_root=pathlib.Path(tempfile.mkdtemp(prefix='rlp-111-production-'));port=19106
with socket.socket() as s:s.bind(('127.0.0.1',port))
results=[]
def ck(v,name):results.append({'name':name,'pass':bool(v)});print(('PASS ' if v else 'FAIL ')+name,flush=True)
for scenario in ('truncated_flac','unsupported_rate','llm_missing','room_cancel','unclean_exit'):
 root=base_root/scenario;root.mkdir();
 env=os.environ.copy()
 for key,leaf in [('HOME','home'),('RLPLAYER_STATE_DIR','state'),('RLPLAYER_LIBRARY_DIR','library'),('RLPLAYER_COVER_DIR','covers')]:
  env[key]=str(root/leaf);(root/leaf).mkdir()
 music=root/'music';music.mkdir();(root/'state'/'rlplayer-settings.conf').write_text('backend=null\nmetaon=0\nmetallm=0\n')
 wav=music/'silence.wav'
 with wave.open(str(wav),'wb') as w:w.setparams((1,2,44100,44100,'NONE','not compressed'));w.writeframes(bytes(44100*2))
 if scenario=='truncated_flac':
  # Silence compresses too well; use deterministic low-level broadband bytes instead.
  import random
  rng=random.Random(42)
  with wave.open(str(wav),'wb') as w:w.setparams((1,2,44100,44100,'NONE','not compressed'));w.writeframes(b''.join(struct.pack('<h',rng.randrange(-300,301)) for _ in range(44100)))
  ff=pathlib.Path(binary).parent/'ffmpeg-lite'/'ffmpeg'
  subprocess.run([str(ff),'-v','error','-y','-i',str(wav),str(music/'full.flac')],check=True)
  data=(music/'full.flac').read_bytes();(music/'short.flac').write_bytes(data[:len(data)//2])
 if scenario=='unclean_exit':
  # A previous isolated process deliberately abandoned its marker; no fabricated crash evidence.
  (root/'state'/'rlplayer-run.json').write_text(json.dumps({'v':1,'state':'running','sid':'isolated-previous','pid':99999999,'started_ms':1,'last_beat_ms':2,'app_version':'synthetic-previous','exit_reason':''}))
 log=open(root/'server.txt','wb');proc=subprocess.Popen([binary,'--port',str(port),'--music-dir',str(music)],env=env,cwd=root,stdout=log,stderr=log)
 def req(path,body=None):
  request=urllib.request.Request('http://127.0.0.1:'+str(port)+path,data=None if body is None else urllib.parse.urlencode(body).encode())
  try:
   with urllib.request.urlopen(request,timeout=30) as response:return response.status,response.read()
  except urllib.error.HTTPError as e:return e.code,e.read()
 try:
  for _ in range(150):
   if proc.poll() is not None:raise RuntimeError('production server exited')
   try:
    if req('/api/ping')[0]==200:break
   except OSError:pass
   time.sleep(.1)
  if scenario=='truncated_flac':
   status,body=req('/api/track/health?'+urllib.parse.urlencode({'file':str(music/'short.flac')}));j=json.loads(body)
   ck(status==422 and j.get('code')=='decode.truncated_flac','production FLAC frame mismatch is stable failure')
   expected='decode.flac_truncated'
  elif scenario=='unsupported_rate':
   # Actual CoreAudio read-only caps hard rejection precedes opening any device.
   req('/api/play',{'file':str(wav),'backend':'wasapi','rate':12345,'bits':24,'volume':-120,'hogExclusive':0})
   for _ in range(100):
    status,body=req('/api/status');state=json.loads(body)
    if state.get('error'):break
    time.sleep(.05)
   ck(bool(state.get('error')),'real caps reject unsupported rate before device IO')
   expected='negotiate.rate_unsupported'
  elif scenario=='llm_missing':req('/api/llm/test');expected='llm.config_error'
  elif scenario=='room_cancel':req('/api/roomcorr/cancel',{});expected='room.cancelled'
  else:expected='run.unclean_exit'
  _,blob=req('/api/diagzip');bundle=root/'case.zip';bundle.write_bytes(blob)
  z=zipfile.ZipFile(io.BytesIO(blob));ev=z.read('events.jsonl').decode();ck(bool(ev.strip()),scenario+' has persisted real event evidence')
  out=subprocess.run([diag,'--json','--expect',expected,'--require-real',str(bundle)],text=True,capture_output=True)
  (root/'rtadiag.json').write_text(out.stdout);(root/'rtadiag.stderr.txt').write_text(out.stderr)
  j=json.loads(out.stdout);ck(out.returncode==0 and j['conclusion']['id']==expected,scenario+' production ZIP -> rtadiag unique conclusion')
 finally:
  if proc.poll() is None:
   owner=subprocess.run(['ps','-p',str(proc.pid),'-o','uid=,ppid=,comm='],text=True,capture_output=True,check=True).stdout.strip()
   (root/'owner-before-term.txt').write_text(owner+'\n');fields=owner.split(None,2)
   if len(fields)!=3 or int(fields[0])!=os.getuid() or int(fields[1])!=os.getpid() or pathlib.Path(fields[2]).name!=pathlib.Path(binary).name:raise RuntimeError('owned server identity changed; no signal sent')
   proc.terminate();proc.wait(timeout=15)
  log.close()
(base_root/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2));print('EVIDENCE',base_root,flush=True)
raise SystemExit(0 if all(r['pass'] for r in results) else 1)
