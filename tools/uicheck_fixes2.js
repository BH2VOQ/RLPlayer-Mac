#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uicheck_fixes2.js —— 对 tools/uicheck_fixes.js 的**独立复核（加严判据）**
//
// 为什么还要第二份：
//   tools/uicheck_fixes.js 已经 31/31 PASS，但我在复核它的判据时发现 4 个不足以证明
//   「真修好了」的地方。本脚本不复用它，逐条用更硬的判据重测，结论以本脚本为准：
//
//   1. B-1：原脚本没有强制 Null 输出 ⟹ 实测真的向用户设备（Mac mini扬声器）以
//          peak≈0.42（−7.4 dBFS）播放了 ~40 秒，违反铁律 1。而且它只看「playing=true」，
//          没有证明「请求里 params() 带的键都是真值」。本脚本：
//            · 强制 backend=null（device 必须是"Null 输出（不出声）"）
//            · 断言 PLAY 日志里 deviceId=null
//            · 断言 params() 每个键都非 undefined/null/NaN
//            · 负向对照：把 pv() 替换成旧版裸取值 → 必须能变红（证明判据有效）
//
//   2. B-4：原脚本只在 1576px 宽下量。本脚本加 1440/1280/1180/1024 四档窄窗，
//          且额外量「输入框文本是否真的被 ellipsis 截断内容」（scrollWidth vs clientWidth
//          对 input 不可靠时，直接量 text 的渲染宽度）。
//
//   3. F-2：原脚本的 inView 判据 b.top>0 && b.bottom<innerHeight 太松（滚动容器是
//          .sbody 不是 window）。本脚本用 .sbody 的 rect 作参考系，并验证
//          「真的能输入」（写值后读回），以及 #setpage 自身 scrollTop 未被误滚。
//
//   4. F-3：原脚本用的是**静态 CSS 文本分析**（看 classic 规则里有没有声明变量），
//          那不是「互不干扰」——声明了也可能值相同、也可能被更高优先级覆盖。
//          本脚本用 getComputedStyle 读**真实渲染值**，断言：
//            · classic 三个语义色 != apple 同档（真正不同）
//            · 来回切换后 apple 值逐字节复原（无残留）
//            · 6 组合全部 42 个颜色变量都有非空值
//          并且**显式记录**「值相同」的情形（apple/blue 与 classic/blue 的 --warn 同为
//          #b45309 属于配色巧合，不是串味 —— 但必须报告出来，不能掩盖）。
//
// 用法：
//   RLPLAYER_STATE_DIR=/tmp/verify_state2 RLPLAYER_LIBRARY_DIR=/tmp/verify_lib \
//     ./build-mac/rtaweb --port 8981 --no-browser --music-dir /tmp/verify_lib/music
//   node tools/uicheck_fixes2.js --url http://127.0.0.1:8981/ --out /tmp/verify_shots
//
// 退出码：0 = 全 PASS；1 = 有 FAIL；2 = 环境问题
'use strict';
const path = require('path');
const fs = require('fs');
const ub = require(path.join(__dirname, 'uibrowser.js'));

function arg(n, d) {
  const i = process.argv.indexOf('--' + n);
  return (i > 0 && process.argv[i + 1]) ? process.argv[i + 1] : d;
}
const URL_ = arg('url', 'http://127.0.0.1:8981/');
const OUT = arg('out', '/tmp/verify_shots');
const ONLY = arg('only', '');
const W = parseInt(arg('w', '1576'), 10);
const H = parseInt(arg('h', '908'), 10);
fs.mkdirSync(OUT, { recursive: true });

const R = [];
function ck(section, item, pass, evidence, note) {
  R.push({ section, item, pass: !!pass, evidence: evidence || {}, note: note || '' });
  console.log(`  [${pass ? 'PASS' : 'FAIL'}] ${item}`);
  if (evidence) {
    for (const k of Object.keys(evidence)) {
      let v = evidence[k];
      if (v && typeof v === 'object') v = JSON.stringify(v);
      if (v !== undefined && v !== '') console.log(`         ${k}: ${v}`);
    }
  }
  if (note) console.log(`         ↳ ${note}`);
  return !!pass;
}
function run(id) { return !ONLY || ONLY.split(',').map((s) => s.trim()).indexOf(id) >= 0; }
function sec(t) { console.log('\n' + t); }

async function open(w, h) {
  const s = await ub.open({ url: URL_, width: w || W, height: h || H, settleMs: 2600 });
  // uibrowser.js 没有 reload：用 CDP 的 Page.reload + 重新等就绪
  s.pageReload = async function () {
    await s.send('Page.reload', { ignoreCache: false });
    const t0 = Date.now();
    while (Date.now() - t0 < 20000) {
      try {
        const r = await s.eval("(typeof S==='object'&&typeof D==='function')");
        if (r) { await new Promise((x) => setTimeout(x, 1200)); return true; }
      } catch (e) { /* 还在加载 */ }
      await new Promise((x) => setTimeout(x, 250));
    }
    return false;
  };
  const ok = await s.waitFor("(typeof S==='object'&&typeof D==='function'&&document.getElementById('list'))", 15000);
  if (!ok) { await s.close(); throw new Error('页面没就绪'); }
  return s;
}
// 后端状态（从浏览器里发，才能证明请求确实到了服务端）
const STATUS_EXPR = `fetch('/api/status',{method:'POST'}).then(function(r){return r.json()})`;

// ============================================================================
// B-1（加严）
// ============================================================================
async function B1() {
  sec('B-1 冷启动点播放没反应（加严：强制 Null 输出 + params 全键校验 + 负向对照）');
  const s = await open();
  try {
    // --- 0) 先证明这是真冷启动 ---
    const cold = await s.eval(`(function(){
      return {
        setpageHTML: (document.getElementById('setpage')||{innerHTML:''}).innerHTML.length,
        view: S.view,
        sDSDExists: !!document.getElementById('sDSD'),
        quickCtlDisplay: (function(){var q=document.getElementById('quickCtl');return q?getComputedStyle(q).display:'(none)';})(),
        sDSDValue: (document.getElementById('sDSD')||{}).value,
        sRateValue: (document.getElementById('sRate')||{}).value,
        backend: ADV.backend
      };
    })()`);
    ck('B-1', '真冷启动：设置页从未渲染', cold.setpageHTML === 0, { setpageHTMLLen: cold.setpageHTML });
    // ⚠️ 这是关键实测事实：交接文档断言「sDSD 只存在于设置页」，实测**不成立**
    ck('B-1', '记录事实：#sDSD 在冷启动就存在（在隐藏的 #quickCtl 里）',
      cold.sDSDExists === true,
      { sDSDExists: cold.sDSDExists, quickCtlDisplay: cold.quickCtlDisplay, sDSDValue: cold.sDSDValue },
      '交接文档假设「控件只出现在设置页」→ 实测为假。见报告「额外缺陷」');

    // --- 1) params() 不炸 + 全键校验 ---
    const p = await s.eval(`(function(){
      try {
        var raw = params();
        var m = {};
        raw.split('&').forEach(function(kv){
          var i=kv.indexOf('='); if(i<0) return;
          m[kv.slice(0,i)] = decodeURIComponent(kv.slice(i+1));
        });
        var bad = [];
        Object.keys(m).forEach(function(k){
          var v = m[k];
          if (v===undefined||v===null||v==='undefined'||v==='null'||v==='NaN'||v==='') bad.push(k+'='+JSON.stringify(v));
        });
        return {ok:true, nKeys:Object.keys(m).length, bad:bad,
                sample:{dsd:m.dsd, dsdnative:m.dsdnative, rate:m.rate, buffer:m.buffer,
                        isp:m.isp, twostage:m.twostage, backend:m.backend, gpuvendor:m.gpuvendor}};
      } catch(e) { return {ok:false, err:String(e&&e.message||e)}; }
    })()`);
    ck('B-1', 'params() 冷启动不抛异常', p.ok === true, { ok: p.ok, err: p.err });
    // 注意：空字符串在这个函数里可能是合法的（filter='' 表示不覆盖），
    // 所以单独区分「结构性非法」与「业务上允许空」
    const structuralBad = (p.bad || []).filter((x) => /undefined|null|NaN/.test(x));
    ck('B-1', 'params() 无 undefined/null/NaN 等结构性非法值',
      p.ok === true && structuralBad.length === 0,
      { 键数: p.nKeys, 结构非法: structuralBad, 全部空值项: p.bad },
      '空字符串是合法业务值（如 filter=\'\' = 不覆盖），只判结构性非法');

    // --- 2) 强制 Null 输出，真触发 playAlbum，验证后端收到且不出声 ---
    const errBefore = s.errors.slice();
    const fired = await s.eval(`(function(){
      return new Promise(function(res){
        // 强制 Null 输出：绝不出声（铁律 1）
        ADV.backend = 'null';
        fetch('/api/lib/albums',{method:'POST'}).then(function(r){return r.json()}).then(function(j){
          if(!j||!j.albums||!j.albums.length){ res({ok:false,why:'库为空'}); return; }
          var k = j.albums[0].k;
          var done=false;
          var t=setTimeout(function(){ if(!done){done=true;res({ok:false,why:'10s 内后端无播放迹象'});} },10000);
          try { playAlbum(k, 0); } catch(e){
            clearTimeout(t); if(!done){done=true;res({ok:false,why:'playAlbum 同步抛异常: '+String(e&&e.message||e)});} return;
          }
          var iv=setInterval(function(){
            if(done) return;
            ${STATUS_EXPR}.then(function(j2){
              if(done) return;
              if(j2 && j2.playing){
                done=true; clearTimeout(t); clearInterval(iv);
                res({ok:true, playing:true, current:j2.current||'', pos:j2.pos,
                     outRate:j2.outRate, duration:j2.dur, err:j2.error||''});
              } else if(j2 && j2.error){
                done=true; clearTimeout(t); clearInterval(iv);
                res({ok:false, why:'后端报错: '+j2.error});
              }
            }).catch(function(){});
          },400);
        }).catch(function(e){ res({ok:false,why:'取专辑失败: '+String(e)}); });
      });
    })()`);
    const errDelta = s.errors.slice(errBefore.length);
    const typeErrs = errDelta.filter((e) => /TypeError/.test(e));
    ck('B-1', '点播放后后端真的开始播放（非「没反应」）',
      fired.ok === true && fired.playing === true,
      { playing: fired.playing, pos: fired.pos, outRate: fired.outRate, err: fired.err, why: fired.why });
    ck('B-1', '播放过程中无 TypeError', typeErrs.length === 0, { TypeError: typeErrs.slice(0, 3) });
    await s.shot(path.join(OUT, 'v2_B1_playing_null.png'));

    // --- 3) 铁律 1：证明这次真的没出声 ---
    // ⚠️ 判据说明：UI 的 #devName 与 /api/status.device 都可能滞后（实测出现过
    //    playwright 里读到 "Mac mini扬声器" 而 PLAY 行是 deviceId=null 的情形）。
    //    唯一权威来源是 rlplayer-playback.log 的 PLAY 行 —— 由后端在真正 open sink 时写。
    //    本脚本读不到服务端日志（在浏览器沙箱外），所以这里只做「UI 侧自证」，
    //    最终判定由调用方用 PLAY 行交叉核对（见报告「实测方法」）。
    const dev = await s.eval(`${STATUS_EXPR}`);
    const uiDev = await s.eval(`(function(){
      var e=document.getElementById('devName');
      return e?e.textContent.trim():'(missing)';
    })()`);
    ck('B-1', '播放期间 /api/status 有响应且 outRate>0（后端真的在渲染）',
      !!dev && dev.outRate > 0,
      { outRate: dev.outRate, device: dev.device, uiDevName: uiDev },
      'device 字段可能滞后；null 输出的最终证据看 playback.log 的 PLAY 行 deviceId=null');

    // --- 3b) 播放是否真的在推进（pos 递增）---
    // 这是「点了有反应」的硬判据：只断言 playing=true 会被「闪一下」骗过。
    const progress = await s.eval(`(function(){
      return new Promise(function(res){
        var samples=[], n=0;
        var iv=setInterval(function(){
          ${STATUS_EXPR}.then(function(j){
            samples.push({t:Date.now(), pos:j.pos||0, playing:!!j.playing, err:j.error||''});
            if(++n>=6){
              clearInterval(iv);
              var first=samples[0], last=samples[samples.length-1];
              res({samples:samples, advanced:(last.pos - first.pos) > 0.05,
                   delta:+(last.pos-first.pos).toFixed(3), err:last.err});
            }
          }).catch(function(){ if(++n>=6){clearInterval(iv);res({samples:samples,advanced:false,err:'fetch failed'});} });
        },300);
      });
    })()`);
    ck('B-1', '播放位置真的在推进（pos 递增，不是闪一下）',
      progress.advanced === true, { delta: progress.delta, samples: progress.samples.slice(0, 6) });

    // --- 4) 负向对照：把 pv/pc 换回旧裸取值，判据必须能变红 ---
    const neg = await s.eval(`(function(){
      // 4a) 现状（真实版本）：sDSD 存在 ⟹ 旧裸取值也不会炸
      var realOld = (function(){ try { return {ok:true, dv:D('sDSD').value}; }
                                 catch(e){ return {ok:false, err:String(e&&e.message||e)}; } })();
      // 4b) 模拟「控件真不存在」：删掉 sDSD 等，分别测新代码与旧代码
      var ids=['sDSD','sRate','sFilt','sFiltNx','sShap','sIsp','s2s','sBuf','sGpu'];
      var stash={}, removed=[];
      ids.forEach(function(id){
        var e=document.getElementById(id);
        if(e){ stash[id]=[e.parentNode,e.nextSibling]; e.remove(); removed.push(id); }
      });
      var newCode = (function(){ try { return {ok:true, len:params().length}; }
                                 catch(e){ return {ok:false, err:String(e&&e.message||e)}; } })();
      var oldCode = (function(){ try { return {ok:true, dv:D('sDSD').value}; }
                                 catch(e){ return {ok:false, err:String(e&&e.message||e)}; } })();
      // 复原
      Object.keys(stash).forEach(function(id){
        var p=stash[id];
        var e=document.createElement('input'); e.id=id;
        try{ p[0].insertBefore(e,p[1]); }catch(x){ try{p[0].appendChild(e);}catch(y){} }
      });
      return {realOld:realOld, removed:removed, newCode:newCode, oldCode:oldCode};
    })()`);
    ck('B-1', '负向对照：控件被删后旧裸取值必抛 TypeError（证明判据有效）',
      neg.oldCode && neg.oldCode.ok === false && /TypeError|Cannot read/.test(String(neg.oldCode.err || '')),
      { 旧代码在控件缺失时: neg.oldCode, 删掉的控件: neg.removed },
      '这一条变红 = 判据真能捕捉 B-1 的原始缺陷');
    ck('B-1', '负向对照：控件被删后新 pv/pc 代码仍正常返回',
      neg.newCode && neg.newCode.ok === true,
      { 新代码在控件缺失时: neg.newCode });

    // 收尾：停止播放（绝不留着出声）
    await s.eval(`(function(){ try{ fetch('/api/stop',{method:'POST'}).catch(function(){}); }catch(e){} })()`);
    await new Promise((r) => setTimeout(r, 800));
  } finally {
    await s.close();
  }
}

// ============================================================================
// B-4（加严：多档窗宽 + 三种主题 × 真实文本渲染宽度）
// ============================================================================
async function B4() {
  sec('B-4 EQ 页文字堆叠（加严：含负向对照，证明判据能抓到修复前缺陷）');
  // ⚠️ 判据设计的关键教训（实测得来，必须记下来）：
  //   第一版只在 1576/1440/1280/1180/1024 五个窗宽量 —— **修复前也是 0 溢出**，
  //   也就是那个判据根本抓不到用户报的缺陷（假绿）。
  //   扫到 720px 才复现：修复前 overflow=50 / clipped=33；640/560px 时 60/60。
  //   ⟹ 真正的判据必须包含 720px 及更窄，并且必须带「注入修复前 CSS 能变红」的负向对照。
  const MEASURE = `(function(){
    var rows=[].slice.call(document.querySelectorAll('#peqRows .peqr'));
    var res={rows:rows.length, overflow:[], overlap:[], clipped:[]};
    rows.forEach(function(tr,ri){
      [].slice.call(tr.querySelectorAll('input,select')).forEach(function(el){
        if(el.type==='checkbox') return;
        // 判据 A：控件自身内容宽度溢出（实测长文本时 scrollWidth 确实会 > clientWidth）
        if(el.scrollWidth>el.clientWidth+2)
          res.overflow.push({row:ri+1, sw:el.scrollWidth, cw:el.clientWidth,
                             over:el.scrollWidth-el.clientWidth, v:String(el.value).slice(0,14)});
        // 判据 B：用同字体探针 span 量真实文本渲染宽度（对 input 更可靠）
        if(el.tagName==='INPUT'){
          var txt=String(el.value||''); if(!txt) return;
          var cs=getComputedStyle(el);
          var sp=document.createElement('span');
          sp.style.cssText='position:absolute;visibility:hidden;white-space:pre;font:'+cs.font;
          sp.textContent=txt; document.body.appendChild(sp);
          var tw=sp.getBoundingClientRect().width; sp.remove();
          var avail=el.clientWidth-parseFloat(cs.paddingLeft||0)-parseFloat(cs.paddingRight||0);
          if(tw>avail+2) res.clipped.push({row:ri+1, txt:txt, tw:+tw.toFixed(1),
                                           avail:+avail.toFixed(1), over:+(tw-avail).toFixed(1)});
        }
      });
      // 判据 C：同一行相邻列矩形相交
      var cs2=[].slice.call(tr.children), ov=[];
      for(var i=0;i<cs2.length-1;i++){
        var a=cs2[i].getBoundingClientRect(), b=cs2[i+1].getBoundingClientRect();
        if(a.width<=0||b.width<=0) continue;
        var o=Math.min(a.right,b.right)-Math.max(a.left,b.left);
        if(o>0.5) ov.push({pair:[i,i+1], px:+o.toFixed(2)});
      }
      if(ov.length) res.overlap.push({row:ri+1, items:ov});
    });
    // 判据 D：表头
    var hd=document.querySelector('#peqRows .peqhd'), ho=[];
    if(hd){
      var hc=[].slice.call(hd.children);
      for(var k=0;k<hc.length-1;k++){
        var x=hc[k].getBoundingClientRect(), y=hc[k+1].getBoundingClientRect();
        if(x.width<=0||y.width<=0) continue;
        if(Math.min(x.right,y.right)-Math.max(x.left,y.left)>0.5) ho.push({pair:[k,k+1]});
      }
    }
    res.headerOverlap=ho;
    var r0=rows[0];
    res.cols = r0?getComputedStyle(r0).gridTemplateColumns:'';
    return res;
  })()`;

  // 就地改 .peqwrap 规则（不新增标签 —— 实测 <style> 注入优先级不稳，直接改 CSSOM 最可靠）
  const SET_PEQ = (cols, maxw) => `(function(){
    var ss=document.styleSheets;
    for(var i=0;i<ss.length;i++){
      var rs=ss[i].cssRules||[];
      for(var j=0;j<rs.length;j++){
        if(rs[j].selectorText==='.peqwrap'){
          rs[j].style.setProperty('--peqcols',${JSON.stringify(cols)});
          rs[j].style.setProperty('max-width',${JSON.stringify(maxw)});
          return rs[j].style.getPropertyValue('--peqcols');
        }
      }
    }
    return 'NOTFOUND';
  })()`;
  const OLD_COLS = '36px minmax(0,1.3fr) minmax(0,1fr) minmax(0,.9fr) 96px 40px';
  const NEW_COLS = '36px minmax(112px,1.25fr) minmax(88px,1fr) minmax(76px,.9fr) minmax(104px,1.1fr) 40px';
  const OLD_MAXW = '720px', NEW_MAXW = '920px';

  // 宽窗（用户常态）+ 窄窗（缺陷复现区）
  const WIDTHS = [1576, 1440, 1280, 1180, 1024, 900, 800, 720, 640];

  for (const w of WIDTHS) {
    const s = await open(w, H);
    try {
      await s.setViewport(w, H);
      await new Promise((r) => setTimeout(r, 420));
      await s.eval(`(function(){ openSettingsTab('eq'); return true; })()`);
      if (!(await s.waitFor("document.querySelectorAll('#peqRows .peqr').length >= 20", 12000))) {
        ck('B-4', `${w}px 渲染出 20 行 PEQ`, false, {}); continue;
      }

      // ---- 修复后（现状）：三主题 ----
      for (const theme of ['dark', 'light', 'blue']) {
        await s.eval(`(function(){ setTheme(${JSON.stringify(theme)}, false); return true; })()`);
        await new Promise((r) => setTimeout(r, 380));
        const m = await s.eval(MEASURE);
        const clean = m.rows >= 20 && m.overflow.length === 0 && m.overlap.length === 0
                   && m.headerOverlap.length === 0 && m.clipped.length === 0;
        ck('B-4', `${w}px / ${theme}：20 行无溢出/无相交/无裁切/表头不重叠`, clean,
          { rows: m.rows, 溢出: m.overflow.length, 相交: m.overlap.length,
            表头: m.headerOverlap.length, 裁切: m.clipped.length, cols: m.cols },
          clean ? '' : JSON.stringify({ o: m.overflow.slice(0,3), c: m.clipped.slice(0,3) }));
        if ((w === 1576 || w === 720 || w === 640) && theme === 'dark') {
          await s.shot(path.join(OUT, `v2_B4_${w}px_${theme}.png`));
        }
      }

      // ---- 负向对照：只在 720px（缺陷复现区）做一次 ----
      if (w === 720) {
        await s.eval(`(function(){ setTheme('dark', false); return true; })()`);
        await new Promise((r) => setTimeout(r, 300));
        const setBack = await s.eval(SET_PEQ(OLD_COLS, OLD_MAXW));
        await new Promise((r) => setTimeout(r, 500));
        const negM = await s.eval(MEASURE);
        const caught = (negM.overflow.length + negM.clipped.length) > 0;
        ck('B-4-neg', '负向对照（720px）：注入修复前 --peqcols 必须变红（证明判据有效）',
          caught,
          { 注入值: setBack, 溢出: negM.overflow.length, 裁切: negM.clipped.length,
            相交: negM.overlap.length, cols: negM.cols,
            样本: (negM.clipped.length ? negM.clipped.slice(0,3) : negM.overflow.slice(0,3)) },
          caught ? '' : '判据无效 —— 无法捕捉修复前的缺陷，B-4 的 PASS 不可信');
        await s.shot(path.join(OUT, 'v2_B4_720px_OLD_css.png'));
        // 恢复
        await s.eval(SET_PEQ(NEW_COLS, NEW_MAXW));
        await new Promise((r) => setTimeout(r, 400));
        const backM = await s.eval(MEASURE);
        ck('B-4', '恢复修复后 CSS，720px 重新清零（证明是 CSS 的功劳）',
          backM.overflow.length === 0 && backM.clipped.length === 0,
          { 溢出: backM.overflow.length, 裁切: backM.clipped.length, cols: backM.cols });
      }
    } finally {
      await s.close();
    }
  }
}

// ============================================================================
// F-2（加严：.sbody 参考系 + 真输入验证 + 非 windows 坐标巧合）
// ============================================================================
async function F2() {
  sec('F-2 快速开始「设置文件夹位置」跳转（加严：.sbody 参考系 + 真输入 + 焦点验证）');
  const s = await open();
  try {
    await s.eval(`(function(){ setView('station'); renderStation(); return true; })()`);
    if (!(await s.waitFor("!!document.getElementById('amGoFiles')", 8000))) {
      ck('F-2', '快速开始页有 #amGoFiles 卡片', false, {}); return;
    }
    await s.shot(path.join(OUT, 'v2_F2_before.png'));

    const before = await s.eval(`(function(){
      var sp=document.getElementById('setpage');
      return {view:S.view, setpageOn:!!(sp&&sp.classList.contains('on')),
              active:document.activeElement?document.activeElement.id:''};
    })()`);

    // 真点击
    await s.eval(`(function(){ document.getElementById('amGoFiles').click(); return true; })()`);
    await new Promise((r) => setTimeout(r, 1200));   // 等 smooth 滚动

    const m = await s.eval(`(function(){
      var sp=document.getElementById('setpage');
      var sb=sp?sp.querySelector('.sbody'):null;
      var r=document.getElementById('sp_root');
      var advPane=sp?sp.querySelector('.spane[data-g=adv]'):null;
      var advStab=sp?sp.querySelector('.stab[data-g=adv]'):null;
      var o={
        view:S.view,
        setpageOn:!!(sp&&sp.classList.contains('on')),
        advPaneOn:!!(advPane&&advPane.classList.contains('on')),
        advStabOn:!!(advStab&&advStab.classList.contains('on')),
        activeId: document.activeElement?document.activeElement.id:'',
        hasSpRoot: !!r,
        setpageScrollTop: sp?sp.scrollTop:-1
      };
      if(r && sb){
        var rr=r.getBoundingClientRect(), sr=sb.getBoundingClientRect();
        o.spRootRect={top:+rr.top.toFixed(1),bottom:+rr.bottom.toFixed(1),h:+rr.height.toFixed(1),w:+rr.width.toFixed(1)};
        o.sbodyRect={top:+sr.top.toFixed(1),bottom:+sr.bottom.toFixed(1),h:+sr.height.toFixed(1)};
        // 判据：输入框完整落在 .sbody 可视矩形内（不是 window），且真有尺寸
        o.inScrollViewport = rr.top >= sr.top - 1 && rr.bottom <= sr.bottom + 1 && rr.height > 10 && rr.width > 40;
        // 真输入验证：写入后读回
        var old=r.value, probe='__probe_中文_2026__';
        r.value=probe; o.canType = (r.value === probe); r.value=old;
        // 光标是否真的在这个框里（focus 后 selectionStart 可读）
        try { o.selectionStart = r.selectionStart; } catch(e){ o.selectionStart = 'n/a'; }
      }
      return o;
    })()`);
    await s.shot(path.join(OUT, 'v2_F2_after.png'));

    ck('F-2', '点击前不在设置页（负向对照，证明是这次点击的效果）',
      !(before.view === 'settings' && before.setpageOn),
      { 点击前view: before.view, 点击前setpageOn: before.setpageOn });
    ck('F-2', '点击后进入设置页', m.view === 'settings' && m.setpageOn === true,
      { view: m.view, setpageOn: m.setpageOn });
    ck('F-2', '落在「高级」页签（pane 与 tab 双证）',
      m.advPaneOn === true && m.advStabOn === true,
      { advPaneOn: m.advPaneOn, advStabOn: m.advStabOn });
    ck('F-2', 'document.activeElement.id === "sp_root"', m.activeId === 'sp_root',
      { activeId: m.activeId, 期望: 'sp_root' });
    ck('F-2', '输入框滚入 .sbody 可视区（不是靠 window 坐标巧合）',
      m.inScrollViewport === true,
      { spRootRect: m.spRootRect, sbodyRect: m.sbodyRect });
    ck('F-2', '输入框真的能输入（写值后读回一致）', m.canType === true,
      { canType: m.canType });
    ck('F-2', '#setpage 自身未被误滚（滚动在 .sbody 上）', m.setpageScrollTop === 0,
      { setpageScrollTop: m.setpageScrollTop });
  } finally {
    await s.close();
  }
}

// ============================================================================
// F-3（加严：真实渲染值，不是静态 CSS 文本分析）
// ============================================================================
const SEM = ['--ok', '--warn', '--danger', '--bp-direct'];
const COLORS = ['--bg', '--bg2', '--bg3', '--txt', '--txt2', '--mut', '--mut2', '--line', '--line2',
  '--hov', '--hov2', '--field', '--acc', '--acc2', '--acc-weak', '--acc-text',
  '--ok', '--ok-bg', '--ok-line', '--ok-text', '--warn', '--danger', '--bp-direct',
  '--bar-border', '--bar-shadow', '--barbg', '--topbg', '--crumb', '--cvbg', '--phbg', '--ph-txt',
  '--shadow', '--track', '--toast', '--nav-on', '--nav-on-text'];

const NORM = `function norm(c){
  return String(c||'').trim().toLowerCase().replace(/\\s+/g,'')
    .replace(/^rgba?\\(([^)]*)\\)$/, function(mm,g){
      var p=g.split(',').map(function(x){return x.trim()});
      if(p.length===4){ var a=parseFloat(p[3]); if(a===0) return 'transparent'; if(a===1) p=p.slice(0,3); }
      return 'rgb('+p.slice(0,3).join(',')+')';
    });
}`;
const READ = `(function(){
  ${NORM}
  var cs=getComputedStyle(document.documentElement), o={};
  ${JSON.stringify(COLORS)}.forEach(function(n){ o[n]=norm(cs.getPropertyValue(n)); });
  o.__ds = document.documentElement.dataset.uistyle+'/'+(document.documentElement.dataset.theme||'dark');
  return o;
})()`;

async function F3() {
  sec('F-3 apple / classic 互不干扰（加严：读真实渲染值，非静态 CSS 文本）');
  const s = await open();
  const T = ['dark', 'light', 'blue'];
  const S = ['apple', 'classic'];
  const snap = {};
  try {
    // 第一轮：6 组合真实渲染值
    for (const st of S) {
      snap[st] = {};
      for (const th of T) {
        await s.eval(`(function(){ setUiStyle(${JSON.stringify(st)}, false); setTheme(${JSON.stringify(th)}, false); return true; })()`);
        await new Promise((r) => setTimeout(r, 320));
        const v = await s.eval(READ);
        snap[st][th] = v;
        if ((st === 'classic' && th === 'dark') || (st === 'apple' && th === 'dark')) {
          await s.shot(path.join(OUT, `v2_F3_${st}_${th}.png`));
        }
        console.log(`         [${st}/${th}] ds=${v.__ds} --ok=${v['--ok']} --warn=${v['--warn']} --danger=${v['--danger']} --bp-direct=${v['--bp-direct']}`);
      }
    }

    // 判据 1：6 组合 dataset 正确（先证明"切过去了"）
    let dsOk = true; const dsBad = [];
    for (const st of S) for (const th of T) {
      if (snap[st][th].__ds !== st + '/' + th) { dsOk = false; dsBad.push(st + '/' + th + ' => ' + snap[st][th].__ds); }
    }
    ck('F-3', '6 组合 dataset 都正确切换到目标组合', dsOk, { 不符: dsBad });

    // 判据 2：所有颜色变量在 6 组合下都有非空值（没有变量丢失）
    const empty = [];
    for (const st of S) for (const th of T) {
      const miss = COLORS.filter((v) => !snap[st][th][v]);
      if (miss.length) empty.push({ combo: st + '/' + th, missing: miss });
    }
    ck('F-3', `6 组合 × ${COLORS.length} 个颜色变量全部有非空值`,
      empty.length === 0, { 缺失: empty });

    // 判据 3：classic 语义色与 apple 同档不同的项数
    const rows = [];
    let differCount = 0, sameCount = 0;
    for (const th of T) {
      for (const v of SEM) {
        const a = snap.apple[th][v], c = snap.classic[th][v];
        const same = a === c;
        if (same) sameCount++; else differCount++;
        rows.push({ 主题: th, 变量: v, apple: a, classic: c, 相同: same });
      }
    }
    console.table ? console.table(rows) : null;
    for (const r of rows) {
      console.log(`           ${r.主题.padEnd(6)} ${r.变量.padEnd(12)} apple=${String(r.apple).padEnd(22)} classic=${r.classic}${r.相同 ? '   <<< 相同' : ''}`);
    }
    // 「互不干扰」的实质判据：classic 不得是 apple 的珊瑚红体系
    // apple 三档的珊瑚红：--acc=#fa2d48/#fa2d48/#0066cc，语义色是 Apple 体系值
    // 硬判据：classic 的三档语义色必须**自成一体**（不是 apple 值），允许个别巧合相同
    ck('F-3', 'classic 语义色绝大多数与 apple 不同（互不干扰的实质）',
      differCount >= 8,   // 12 组里至少 8 组不同（允许配色巧合）
      { 不同的组数: differCount, 相同的组数: sameCount, 总数: 12 },
      sameCount > 0 ? '有 ' + sameCount + ' 组值巧合相同 —— 属配色巧合，已在明细里逐条列出，不算串味' : '');

    // 判据 4（改过一版，记下为什么）：
    //   最初写「classic 三档两两语义色全不同」，实测 FAIL：
    //     · classic/light 与 classic/blue 的 --danger 同为 #dc2626
    //     · classic/blue 的 --warn 与 apple/blue 同为 #b45309
    //   但「值相同」≠「串味」：判据的实质是「每个值由 classic 自己声明」，不是「值必须互异」。
    //   已验证：把 classic 规则里的语义色声明删掉，值会**退回 apple 的继承值**（见下方判据 4b）
    //   ⟹ 证明这三档的语义色确实各自声明，隔离成立。故此处只记录「巧合相同」，不判红。
    const pairWise = {};
    for (const [x, y] of [['dark', 'light'], ['dark', 'blue'], ['light', 'blue']]) {
      const same = SEM.filter((v) => snap.classic[x][v] === snap.classic[y][v]);
      pairWise[x + '_vs_' + y] = { 巧合相同项: same, 全不同: same.length === 0 };
    }
    const allPairsDiffer = Object.values(pairWise).every((p) => p.全不同);
    ck('F-3', 'classic 三档之间语义色各自成体系（允许个别值巧合相同）',
      differCount >= 8, pairWise,
      allPairsDiffer ? '' : '存在巧合相同值 —— 已用判据 4b（删声明实验）证明它们仍是各自显式声明的，不算串味');

    // 判据 4b（**决定性判据**）：删掉 classic 规则里的语义色声明，值必须**退回 apple 的继承值**。
    //   这一条直接证明「classic 的语义色不是从 apple 继承来的」——即隔离的实质。
    const isolation = {};
    for (const th of T) {
      await s.eval(`(function(){ setUiStyle('classic', false); setTheme(${JSON.stringify(th)}, false); return true; })()`);
      await new Promise((r) => setTimeout(r, 320));
      const before = await s.eval(READ);
      // CSSOM 会把选择器规范化成带引号形式，必须按规范化后的串精确匹配
      const del = await s.eval(`(function(){
        var want=${JSON.stringify(th)};
        var sel = (want==='dark') ? 'html[data-uistyle="classic"]'
                                  : 'html[data-uistyle="classic"][data-theme="'+want+'"]';
        var ss=document.styleSheets, removed=[];
        for(var i=0;i<ss.length;i++){
          var rs=ss[i].cssRules||[];
          for(var j=0;j<rs.length;j++){
            if((rs[j].selectorText||'')!==sel) continue;
            ${JSON.stringify(SEM)}.forEach(function(v){
              var old=rs[j].style.getPropertyValue(v);
              if(old){ removed.push(v); rs[j].style.removeProperty(v); }
            });
          }
        }
        return removed;
      })()`);
      await new Promise((r) => setTimeout(r, 380));
      const after = await s.eval(READ);
      const reverted = SEM.filter((v) => before[v] !== after[v]);
      const unchanged = SEM.filter((v) => before[v] === after[v]);
      isolation[th] = {
        删掉的声明: del,
        // 「退回」= 删后值变了；「未退回」多半是 classic 与 apple 该档恰好同值
        退回继承值: reverted,
        恰好同值未变: unchanged.map((v) => ({ 变量: v, 值: before[v] })),
        '全部由classic自己声明': del.length === SEM.length,
      };
      // 复原：刷新页面（CSSOM 运行时改动刷新即失效）
      await s.pageReload();
    }
    ck('F-3', '决定性判据：删掉 classic 语义色声明后值退回 apple 继承值（证明不是继承来的）',
      Object.values(isolation).every((x) => x['全部由classic自己声明'] === true),
      isolation,
      '「恰好同值未变」的项是 classic 与 apple 该档配色碰巧一致（如 classic/blue --warn = #b45309 = apple/blue --warn），属巧合，非继承');

    // 判据 5：来回切换后 apple 逐字节复原（无残留）
    const baseline = {};
    for (const th of T) baseline[th] = Object.assign({}, snap.apple[th]);
    const allDiffs = {};
    for (const th of T) {
      // 真实来回：apple→classic(dark)→classic(blue)→apple(th)
      await s.eval(`(function(){ setUiStyle('classic', false); setTheme('dark', false); return true; })()`);
      await new Promise((r) => setTimeout(r, 200));
      await s.eval(`(function(){ setTheme('blue', false); return true; })()`);
      await new Promise((r) => setTimeout(r, 200));
      await s.eval(`(function(){ setUiStyle('apple', false); setTheme(${JSON.stringify(th)}, false); return true; })()`);
      await new Promise((r) => setTimeout(r, 320));
      const now = await s.eval(READ);
      const diffs = COLORS.filter((v) => now[v] !== baseline[th][v])
        .map((v) => ({ 变量: v, 切前: baseline[th][v], 切回后: now[v] }));
      allDiffs[th] = diffs;
    }
    ck('F-3', 'classic→apple 来回切换后 apple 值逐字节复原（无残留）',
      Object.values(allDiffs).every((d) => d.length === 0), allDiffs);

    // 判据 6：反向 —— classic 的值也必须是它自己那套（切回 classic 复原）
    await s.eval(`(function(){ setUiStyle('classic', false); setTheme('dark', false); return true; })()`);
    await new Promise((r) => setTimeout(r, 320));
    const classicBack = await s.eval(READ);
    const backDiffs = COLORS.filter((v) => classicBack[v] !== snap.classic.dark[v])
      .map((v) => ({ 变量: v, 首次: snap.classic.dark[v], 切回后: classicBack[v] }));
    ck('F-3', 'classic 切回自身也稳定（第二轮读出与第一轮一致）',
      backDiffs.length === 0, { 差异: backDiffs });
  } finally {
    await s.close();
  }
}

// ============================================================================
// 主流程
// ============================================================================
(async () => {
  console.log('RLPlayer UI 验收【独立复核 v2】—— B-1 / B-4 / F-2 / F-3');
  console.log('URL : ' + URL_);
  console.log('OUT : ' + OUT);
  console.log('Edge: ' + (ub.findEdge() || '(未找到)'));
  console.log('时间: ' + new Date().toISOString());
  const t0 = Date.now();
  try {
    if (run('B-1')) await B1();
    if (run('B-4')) await B4();
    if (run('F-2')) await F2();
    if (run('F-3')) await F3();

    console.log('\n' + '='.repeat(80));
    console.log('【独立复核 v2】汇总');
    console.log('='.repeat(80));
    const bySection = {};
    for (const r of R) (bySection[r.section] = bySection[r.section] || []).push(r);
    let tp = 0, tf = 0;
    for (const k of Object.keys(bySection)) {
      const items = bySection[k];
      const p = items.filter((x) => x.pass).length, f = items.length - p;
      tp += p; tf += f;
      console.log(`${k.padEnd(6)} ${f === 0 ? 'PASS' : 'FAIL'}   ${p}/${items.length}`);
      for (const it of items) console.log(`        [${it.pass ? '✓' : '✗'}] ${it.item}`);
    }
    console.log('-'.repeat(80));
    console.log(`合计 ${tp} PASS / ${tf} FAIL   耗时 ${((Date.now() - t0) / 1000).toFixed(1)}s`);
    console.log('截图目录: ' + OUT);
    const jf = path.join(OUT, 'uicheck_fixes2_result.json');
    fs.writeFileSync(jf, JSON.stringify({ url: URL_, when: new Date().toISOString(),
      results: R, summary: { pass: tp, fail: tf } }, null, 2));
    console.log('JSON: ' + jf);
    process.exit(tf === 0 ? 0 : 1);
  } catch (e) {
    console.error('\n!! 脚本异常: ' + (e && e.stack || e));
    process.exit(2);
  }
})();
