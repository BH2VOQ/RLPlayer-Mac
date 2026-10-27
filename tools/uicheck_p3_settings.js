// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
// uicheck_p3_settings.js — Q-1/Q-3/Q-4/Q-9 + 设置页覆写 conf 的复核判据
// 独立复核：Q-1/Q-3/Q-4/Q-9 + conf 不被覆写（不依赖工作树的脆弱时序）
const fs=require('fs'), path=require('path');
const ub=require('/Users/august/Downloads/DQ/RLPlayer/tools/uibrowser');
const base=process.argv[2], conf=process.argv[3];
let fail=0;
function ck(ok,l,d){console.log((ok?'PASS ':'FAIL ')+l+': '+JSON.stringify(d));if(!ok)fail++;}
(async()=>{let s;
try{
  const before=fs.readFileSync(conf,'utf8');
  s=await ub.open({url:base,width:1300,height:900});
  await s.waitFor('window.S && typeof setView==="function"',15000);
  const init=await s.eval('({b:ADV.backend,v:S.vol})');
  ck(init.b==='null','config loaded into memory on first load (not default wasapi)',init);
  await s.eval(`(function(){var n=document.querySelector('.nav[data-v=settings]');if(n)n.click();})()`);
  await ub.sleep(700);
  await s.eval(`(function(){var t=document.querySelector('#setpage .stab[data-g=eq]');if(t)t.click();})()`);
  await ub.sleep(1500);
  await s.eval(`(function(){var t=document.querySelector('#setpage .stab[data-g=cal]');if(t)t.click();})()`);
  await ub.sleep(700);
  const after=fs.readFileSync(conf,'utf8');
  const g=k=>{const m=after.match(new RegExp('^'+k+'=(.*)$','m'));return m?m[1]:'';};
  ck(g('backend')==='null' && parseFloat(g('volume'))<=-55,'conf not overwritten by visiting settings/EQ/cal tabs',{backend:g('backend'),volume:g('volume')});
  const dev=await s.eval(`fetch('/api/devices').then(r=>r.json())`);
  const d0=(dev.devices||[])[0]||{};
  ck(d0.channels!==undefined&&d0.mixRate!==undefined&&d0.mixBits!==undefined&&d0.mixFmt!==undefined,'Q-1 /api/devices exposes real CoreAudio format',d0);
  const q=await s.eval(`({u:qFmt(undefined),n:qFmt(null),nan:qFmt(NaN),inf:qFmt(Infinity),ok:qFmt(12.345,2)})`);
  ck(q.u==='-'&&q.n==='-'&&q.nan==='-'&&q.inf==='-'&&q.ok==='12.35','Q-3 qFmt guards non-finite values',q);
  const dom=await s.eval(`({
    hasCalTab: !!document.querySelector('#setpage .stab[data-g=cal]'),
    hasCalPane: !!document.querySelector('#setpage .stab[data-g=cal]') && (document.querySelector('#setpage .stab[data-g=cal]').textContent||'').indexOf('校准')>=0,
    hasRepaint: typeof repaintTrims==='function',
    hasEff: typeof effectiveChannels==='function',
    hasHint: typeof devMixText==='function' && typeof updateDevMixHint==='function',
    trimCount: document.querySelectorAll('#setpage .trimgrid input').length,
    eff: (typeof effectiveChannels==='function')?effectiveChannels():-1
  })`);
  ck(dom.hasCalTab&&dom.hasCalPane,'Q-9 calibration tab exists',dom);
  ck(dom.hasHint,'Q-1 devMixText/updateDevMixHint present',dom);
  ck(dom.hasRepaint&&dom.hasEff&&dom.trimCount===dom.eff,'Q-4 trim grid renders effectiveChannels inputs',{trimCount:dom.trimCount,eff:dom.eff});
  await s.shot('/tmp/p3settings_verify.png');
  ck(s.errors.length===0,'no renderer exceptions',s.errors);
}catch(e){ck(false,'execution',String(e).slice(0,300));}
finally{if(s){try{await s.close();}catch(e){ck(false,'cleanup',String(e));}}}
process.exitCode=fail?1:0;})();
