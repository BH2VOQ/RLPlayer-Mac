// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
// uicheck_roomcorr.js — R-1 测量向导的铁律 1 判据（确认前绝不出声）
const fs=require('fs'); const ub=require('/Users/august/Downloads/DQ/RLPlayer/tools/uibrowser');
let fail=0; function ck(o,l,d){console.log((o?'PASS ':'FAIL ')+l+': '+JSON.stringify(d));if(!o)fail++;}
(async()=>{let s;
try{
 s=await ub.open({url:'http://127.0.0.1:19093',width:1400,height:900});
 await s.waitFor('typeof rcWizard==="function"',15000);
 await s.eval(`(function(){var n=document.querySelector('.nav[data-v=settings]');if(n)n.click();})()`);
 await ub.sleep(600);
 await s.eval(`(function(){var t=document.querySelector('#setpage .stab[data-g=cal]');if(t)t.click();})()`);
 await ub.sleep(600);
 const dom=await s.eval(`({hasLayout:!!document.getElementById('rcLayout'),hasBtn:!!document.getElementById('bRoomWiz')})`);
 ck(dom.hasLayout&&dom.hasBtn,'wizard exposes layout select and start button',dom);
 await s.eval('rcWizard()');
 const ok=await s.waitFor('document.getElementById("modal").classList.contains("on")',8000);
 const txt=await s.eval('(document.getElementById("mbody")||{}).innerText||""');
 ck(ok&&/会真的出声/.test(txt),'confirmation modal warns about audible output before starting',txt.slice(0,120));
 ck(/dBFS/.test(txt)&&/秒/.test(txt)&&/输出设备/.test(txt),'modal discloses level, duration and device',txt.slice(0,200));
 const st=await s.eval(`fetch('/api/roomcorr/status').then(r=>r.json()).then(j=>j.phase)`);
 ck(st==='idle','opening the wizard does not start any measurement',st);
 await s.shot('/tmp/roomwiz.png');
 ck(s.errors.length===0,'no renderer exceptions',s.errors);
}catch(e){ck(false,'execution',String(e).slice(0,250));}
finally{if(s){try{await s.close();}catch(e){ck(false,'cleanup',String(e));}}}
process.exitCode=fail?1:0;})();
