// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
'use strict';
const fs=require('fs'),os=require('os'),path=require('path'),net=require('net');
const {spawn,execFileSync}=require('child_process'),ub=require('./uibrowser');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'rlp-111-ui-')),port=19105;
const binaryIdx=process.argv.indexOf('--binary');
const binary=binaryIdx!==-1?path.resolve(process.argv[binaryIdx+1]):path.resolve(__dirname,'../build-mac/rtaweb');
const env={...process.env,HOME:path.join(root,'home'),RLPLAYER_STATE_DIR:path.join(root,'state'),RLPLAYER_LIBRARY_DIR:path.join(root,'lib'),RLPLAYER_COVER_DIR:path.join(root,'covers')};
for(const k of ['HOME','RLPLAYER_STATE_DIR','RLPLAYER_LIBRARY_DIR','RLPLAYER_COVER_DIR'])fs.mkdirSync(env[k],{recursive:true});
fs.mkdirSync(path.join(root,'music'));fs.writeFileSync(path.join(env.RLPLAYER_STATE_DIR,'rlplayer-settings.conf'),'backend=null\nmetaon=0\nmetallm=0\n');
let child,session;const results=[];function ck(v,name,data){results.push({pass:!!v,name,data});console.log((v?'PASS ':'FAIL ')+name+(data?' '+JSON.stringify(data):''));}
const pause=ms=>new Promise(r=>setTimeout(r,ms));
function verifyOwnedServer(){
 const owner=execFileSync('ps',['-p',String(child.pid),'-o','uid=,ppid=,comm='],{encoding:'utf8'}).trim();
 fs.appendFileSync(path.join(root,'owners.log'),owner+'\n');
 const m=owner.match(/^(\d+)\s+(\d+)\s+(.+)$/);
 if(!m||+m[1]!==process.getuid()||+m[2]!==process.pid||path.basename(m[3])!==path.basename(binary))throw Error('server identity changed; no signal sent');
}
(async()=>{try{
 await new Promise((resolve,reject)=>{let s=net.createServer();s.once('error',reject);s.listen(port,'127.0.0.1',()=>s.close(resolve));});
 child=spawn(binary,['--port',String(port),'--music-dir',path.join(root,'music')],{env,cwd:root,stdio:'ignore'});
 for(let i=0;i<100;i++){try{if((await fetch(`http://127.0.0.1:${port}/api/ping`)).ok)break;}catch{}await pause(100);}
 session=await ub.open({url:`http://127.0.0.1:${port}/`,port:9711});
 const ready=await session.waitFor("typeof openSettingsTab==='function' && document.getElementById('bHelp')", 12000);
 if(!ready) throw new Error('UI failed to reach ready state with bHelp within 12s; current URL: ' + await session.eval('location.href'));
 await session.eval("document.getElementById('bHelp').click()");
 let text=await session.eval("document.getElementById('mbody').textContent");
 ck(text.includes('上一首 / 下一首')&&text.includes('Shift + ← →')&&text.includes('±0.5 dB'),'help shows actual shortcut semantics');
 await session.eval("document.getElementById('mclose').click();openSettingsTab('diag')");
 await session.waitFor("document.getElementById('sp_diagupload')");
 await session.eval("document.getElementById('sp_diagupload').click()");
 ck(await session.eval("document.activeElement.id==='sp_fbtext' && document.getElementById('sp_fbdiag').checked"),'upload action focuses real feedback and keeps diagnostic attachment');
 await session.eval("document.getElementById('sp_diagsummary').click()");
 await session.waitFor("document.getElementById('sp_diagsummarytext').textContent.includes('RLP-')");
 ck(await session.eval("document.getElementById('sp_diagsummarytext').textContent.includes('case_id: RLP-')"),'diagnostic summary uses real backend case ID');
 await session.eval("uiTrace('error','',{code:'UI_EXC',where:'app.js:42'});uiTraceFlush()");
 await pause(300);
 let ui=await (await fetch(`http://127.0.0.1:${port}/api/ui/events`)).json();
 ck(ui.events.some(e=>e.code==='ui.script_error'),'real frontend telemetry reaches disk-backed backend');
 // Reload remembered light theme; a document-start observer catches any first-frame theme flip.
 await session.eval("localStorage.setItem('rta-theme','light')");
 await session.send('Page.addScriptToEvaluateOnNewDocument',{source:"window.__themeAtLoad=[];new MutationObserver(function(){if(document.documentElement)window.__themeAtLoad.push(document.documentElement.dataset.theme)}).observe(document,{subtree:true,attributes:true,attributeFilter:['data-theme']});"});
 await session.send('Page.reload',{});await session.waitFor("document.documentElement.dataset.theme==='light' && typeof peqRowBand==='function'");
 ck(await session.eval("document.documentElement.dataset.theme==='light'"),'remembered light theme is applied on reload');
 await session.eval("openSettingsTab('eq')");await session.waitFor("document.querySelector('#peqRows .peqr')");
 let band=await session.eval("(()=>{var r=document.querySelector('#peqRows .peqr');r.querySelector('.peqG').value='18';return peqRowBand(r).gain})()");
 ck(band===18,'PEQ UI preserves imported +18 dB rather than silently reducing to +12');
 await session.eval('peqApply()');await pause(350);
 const eqState=await (await fetch(`http://127.0.0.1:${port}/api/peq`)).json();
 ck(eqState.bands&&eqState.bands[0].gain===18,'PEQ +18 dB survives production API round-trip',eqState.bands&&eqState.bands[0]);
 const eqNote=await session.eval("document.getElementById('peqMsg').textContent");
 ck(eqNote.includes('18')&&eqNote.includes('12'),'PEQ shows actual gain and the >12 dB review warning',eqNote);
 // Real key events must reach the production API; help text alone proves no behavior.
 const tracks=[];
 for(let i=0;i<3;i++){
  const file=path.join(root,'music','shortcut-'+i+'.wav'),data=Buffer.alloc(44+8000*30*2);
  data.write('RIFF');data.writeUInt32LE(data.length-8,4);data.write('WAVEfmt ',8);data.writeUInt32LE(16,16);
  data.writeUInt16LE(1,20);data.writeUInt16LE(1,22);data.writeUInt32LE(8000,24);data.writeUInt32LE(16000,28);
  data.writeUInt16LE(2,32);data.writeUInt16LE(16,34);data.write('data',36);data.writeUInt32LE(data.length-44,40);
  fs.writeFileSync(file,data);tracks.push(file);
 }
 async function request(route,body){return (await fetch(`http://127.0.0.1:${port}`+route,{method:body===undefined?'GET':'POST',body:body===undefined?undefined:new URLSearchParams(body)})).json();}
 async function key(name,shift=false){await session.send('Input.dispatchKeyEvent',{type:'keyDown',key:name,code:name,modifiers:shift?8:0});await session.send('Input.dispatchKeyEvent',{type:'keyUp',key:name,code:name,modifiers:shift?8:0});}
 async function queueIndex(index){for(let i=0;i<40;i++){const q=await request('/api/queue');if(q.index===index)return q;await pause(50);}return request('/api/queue');}
 await request('/api/clear',{});for(const file of tracks)await request('/api/add',{file});
 await request('/api/play',{file:tracks[1],backend:'null',rate:'8000',bits:'16',vol:'-120'});
 await session.eval("document.activeElement.blur();ADV.backend='null'");
 await key('ArrowRight');ck((await queueIndex(2)).index===2,'real Right key advances to the next queue item');
 await key('ArrowLeft');ck((await queueIndex(1)).index===1,'real Left key returns to the previous queue item');
 // Wait for the real status/current-track projection before testing seek; otherwise
 // the first late poll clears the preview hold as if the track had just changed.
 await session.eval('tick()');
 await session.waitFor('S.lastCur==='+JSON.stringify(tracks[1])+' && S.dur===30');
 for(let i=0;i<30;i++){if((await request('/api/status')).pos>0)break;await pause(50);}
 await session.eval('doSeek(10/30)');
 let stSeek10;for(let i=0;i<30;i++){await pause(50);stSeek10=await request('/api/status');if(Math.abs(stSeek10.pos-10)<1.0)break;}
 await key('ArrowRight',true);
 let stSeekRight,seekRight;
 for(let i=0;i<30;i++){
  await pause(50);
  seekRight=await session.eval('seekDisplaySec()');
  stSeekRight=await request('/api/status');
  if(Math.abs(stSeekRight.pos-15)<1.0)break;
 }
 ck(Math.abs(seekRight-15)<0.3&&Math.abs(stSeekRight.pos-15)<1.0,'real Shift+Right seeks by five seconds (UI display and backend /api/status)',{seekRight,backendPos:stSeekRight.pos});
 await key('ArrowLeft',true);
 let stSeekLeft,seekLeft;
 for(let i=0;i<30;i++){
  await pause(50);
  seekLeft=await session.eval('seekDisplaySec()');
  stSeekLeft=await request('/api/status');
  if(Math.abs(stSeekLeft.pos-10)<1.0)break;
 }
 ck(Math.abs(seekLeft-10)<0.3&&Math.abs(stSeekLeft.pos-10)<1.0,'real Shift+Left seeks back by five seconds (UI display and backend /api/status)',{seekLeft,backendPos:stSeekLeft.pos});
 await session.eval('setVol(-30)');await pause(200);
 await key('ArrowUp');const up=await session.eval('S.vol');
 let stVolUp;for(let i=0;i<20;i++){stVolUp=await request('/api/status');if(Math.abs(stVolUp.volDb-(-29.5))<0.05)break;await pause(50);}
 ck(up===-29.5&&Math.abs(stVolUp.volDb-(-29.5))<0.05,'real Up key steps volume by +0.5 dB (UI optimistic and backend /api/status)',{up,backendVol:stVolUp.volDb});
 await key('ArrowDown');const down=await session.eval('S.vol');
 let stVolDown;for(let i=0;i<20;i++){stVolDown=await request('/api/status');if(Math.abs(stVolDown.volDb-(-30))<0.05)break;await pause(50);}
 ck(down===-30&&Math.abs(stVolDown.volDb-(-30))<0.05,'real Down key steps volume by -0.5 dB (UI optimistic and backend /api/status)',{down,backendVol:stVolDown.volDb});
 await key('ArrowUp',true);const fineUp=await session.eval('S.vol');
 let stVolFineUp;for(let i=0;i<20;i++){stVolFineUp=await request('/api/status');if(Math.abs(stVolFineUp.volDb-(-29.9))<0.05)break;await pause(50);}
 ck(fineUp===-29.9&&Math.abs(stVolFineUp.volDb-(-29.9))<0.05,'real Shift+Up key steps volume fine by +0.1 dB (UI optimistic and backend /api/status)',{fineUp,backendVol:stVolFineUp.volDb});
 await key('ArrowDown',true);const fineDown=await session.eval('S.vol');
 let stVolFineDown;for(let i=0;i<20;i++){stVolFineDown=await request('/api/status');if(Math.abs(stVolFineDown.volDb-(-30))<0.05)break;await pause(50);}
 ck(fineDown===-30&&Math.abs(stVolFineDown.volDb-(-30))<0.05,'real Shift+Down key steps volume fine by -0.1 dB (UI optimistic and backend /api/status)',{fineDown,backendVol:stVolFineDown.volDb});
 await request('/api/stop',{});
 const bad=path.join(root,'music','invalid.wav');fs.writeFileSync(bad,'not a WAV');
 const badResponse=await request('/api/track/health?file='+encodeURIComponent(bad));
 await session.eval('openQualityModal('+JSON.stringify(bad)+')');
 await session.waitFor("document.getElementById('mbody').textContent.includes('[')");
 const failureText=await session.eval("document.getElementById('mbody').textContent");
 ck(badResponse.ok===false&&failureText.includes(badResponse.code)&&!failureText.includes('响度 (LUFS)'), 'quality error UI shows the real stable error instead of default zero metrics',failureText);
 await session.eval("document.getElementById('mclose').click()");
 let errors=session.errors;ck(errors.length===0,'no uncaught page exception',errors);
 await session.shot(path.join(root,'diag-ui.png'));
}finally{
 if(session)await session.close();
 if(child&&child.exitCode===null){verifyOwnedServer();child.kill('SIGTERM');await Promise.race([new Promise(r=>child.once('exit',r)),pause(10000)]);if(child.exitCode===null)throw Error('owned server did not exit after TERM');}
 fs.writeFileSync(path.join(root,'results.json'),JSON.stringify(results,null,2));console.log('EVIDENCE '+root);
}if(results.some(r=>!r.pass))process.exitCode=1;
})().catch(e=>{console.error(e);process.exitCode=1});
