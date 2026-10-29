// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
'use strict';
const fs=require('fs'),os=require('os'),path=require('path'),net=require('net');
const {spawn}=require('child_process'),ub=require('./uibrowser');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'rlp-111-ui-')),port=19105;
const binary=path.resolve(process.argv[process.argv.indexOf('--binary')+1]||'build-mac/rtaweb');
const env={...process.env,HOME:path.join(root,'home'),RLPLAYER_STATE_DIR:path.join(root,'state'),RLPLAYER_LIBRARY_DIR:path.join(root,'lib'),RLPLAYER_COVER_DIR:path.join(root,'covers')};
for(const k of ['HOME','RLPLAYER_STATE_DIR','RLPLAYER_LIBRARY_DIR','RLPLAYER_COVER_DIR'])fs.mkdirSync(env[k],{recursive:true});
fs.mkdirSync(path.join(root,'music'));fs.writeFileSync(path.join(env.RLPLAYER_STATE_DIR,'rlplayer-settings.conf'),'backend=null\nmetaon=0\nmetallm=0\n');
let child,session;const results=[];function ck(v,name,data){results.push({pass:!!v,name,data});console.log((v?'PASS ':'FAIL ')+name+(data?' '+JSON.stringify(data):''));}
const pause=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{try{
 await new Promise((resolve,reject)=>{let s=net.createServer();s.once('error',reject);s.listen(port,'127.0.0.1',()=>s.close(resolve));});
 child=spawn(binary,['--port',String(port),'--music-dir',path.join(root,'music')],{env,cwd:root,stdio:'ignore'});
 for(let i=0;i<100;i++){try{if((await fetch(`http://127.0.0.1:${port}/api/ping`)).ok)break;}catch{}await pause(100);}
 session=await ub.open({url:`http://127.0.0.1:${port}/`,port:9711});
 await session.waitFor("typeof openSettingsTab==='function' && document.getElementById('bHelp')");
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
 let errors=session.errors;ck(errors.length===0,'no uncaught page exception',errors);
 await session.shot(path.join(root,'diag-ui.png'));
}finally{
 if(session)await session.close();
 if(child&&child.exitCode===null){child.kill('SIGTERM');await Promise.race([new Promise(r=>child.once('exit',r)),pause(10000)]);if(child.exitCode===null)throw Error('owned server did not exit after TERM');}
 fs.writeFileSync(path.join(root,'results.json'),JSON.stringify(results,null,2));console.log('EVIDENCE '+root);
}if(results.some(r=>!r.pass))process.exitCode=1;
})().catch(e=>{console.error(e);process.exitCode=1});
