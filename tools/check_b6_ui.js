// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_b6_ui.js — 1.1.4-beta6「单曲页侧栏可完全隐藏 + AI 面板精简内容 + 弹窗风格」UI 判据
//
// ============================ 这个测试在证明什么 ============================
// 全部驱动生产页面里的真实函数（npPanelsSet / npPanelsApply / npDataRenderTabs /
// npRailPreview / npDrawerOpen / openNowPlaying），不是在测试里另写一份"和产品一样的逻辑"。
//
//   B1 左右侧栏开关存在：右上角 #npAnalToggle / #npRailToggle + 面板头部 #npAnalHide / #npRailHide；
//      默认都显示（aria-pressed=true），localStorage 无值时不隐藏。
//   B2 点开关 → 对应竖栏 display:none（**完全隐藏**，不是缩成 0 宽/半透明），
//      aria-pressed 同步为 false；再点恢复显示。
//   B3 只隐藏左栏 / 只隐藏右栏时：歌词中心仍严格等于 .npbody 中心（沿用 beta4 用户硬约束）；
//      两侧都隐藏时：.npbody 单列、歌词占满整行、中心仍等于容器中心。
//   B4 隐藏状态写 localStorage（rta-np-anal / rta-np-rail），重载后由 npPanelsApply 恢复。
//   B5 AI 右栏每栏显示精简内容：注入 fields 后 npDataRenderTabs 产出的 chip 文本包含
//      「已缓存/已整理」状态与字段值（演唱/作曲/歌曲风格…），且**没有一栏是空的**。
//   B6 AI 数据缺失时回落本地事实：无 fields 时 chip 仍显示艺术家/专辑/格式/时长等本地信息
//      （用户「内容太空」的反向判据：允许"点开查看"，但不允许整栏空白）。
//   B7 资料浮层风格与 App 弹窗同源：18px 圆角、有阴影、四边留 14px、宽度 ≤44vw，
//      打开时 visibility:visible/opacity:1，关闭后 visibility:hidden（不残留可点区域）。
//   B8 无歌词时不再把歌词列 display:none（旧 .nolyric 会在页面正中留一大块空白）；
//      歌词列可见并显示「暂无歌词」类提示。
//   B9 单曲页几何（1024x640 / 1280x800 / 1576x908）：两侧都显示时三列互不重叠、
//      控制区完整在视口内、#npPage 无横向溢出（scrollWidth ≤ 视口宽 + 1）。
//   B10 Esc 层级：单曲页里打开弹窗时按 Esc 先关弹窗，不关整页。
//
// 用法：node tools/check_b6_ui.js http://127.0.0.1:19114/
// 🔴 全程 headless，不播放任何音频（不调 /api/play），不触碰 8899。
'use strict';
const ub = require('./uibrowser');

const URL_ = process.argv[2] || 'http://127.0.0.1:19114/';
let fail = 0, total = 0;
function ck(ok, what, detail) {
  total++;
  if (!ok) fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${what}${detail ? '  ' + detail : ''}`);
}
const J = (o) => JSON.stringify(o);

(async () => {
  const s = await ub.open({ url: URL_, width: 1280, height: 800, settleMs: 2500 });
  try {
    const ready = await s.waitFor("typeof npPanelsApply === 'function' && typeof npDataRenderTabs === 'function' && document.getElementById('npAnal')", 15000);
    if (!ready) {
      console.log('FATAL: 页面没起来（找不到 npPanelsApply / npDataRenderTabs / #npAnal）: ' + await s.eval('location.href'));
      process.exit(2);
    }
    const ev = (x) => s.eval(x);
    // 打开单曲页：几何/浮层判据必须在页面真实可见时测量（#npPage display:none 时所有 rect 都是 0）
    await ev('(function(){ if(typeof openNowPlaying==="function") openNowPlaying(); return 1; })()');
    await ub.sleep(600);

    /* ---------------- B1：开关存在 + 默认显示 ---------------- */
    const b1 = await ev(`(function(){
      var ids=['npAnalToggle','npRailToggle','npAnalHide','npRailHide'];
      var found={}; ids.forEach(function(i){ found[i]=!!document.getElementById(i); });
      localStorage.removeItem('rta-np-anal'); localStorage.removeItem('rta-np-rail');
      npPanelsLoad(); npPanelsApply();
      var g=document.getElementById('npGrid');
      return {found:found, cls:g.className, analPressed:document.getElementById('npAnalToggle').getAttribute('aria-pressed'),
              railPressed:document.getElementById('npRailToggle').getAttribute('aria-pressed'),
              analDisp:getComputedStyle(document.getElementById('npAnal')).display,
              railDisp:getComputedStyle(document.getElementById('npRail')).display};
    })()`);
    ck(b1 && Object.values(b1.found).every(Boolean), 'B1 四个开关都在 DOM 里', J(b1 && b1.found));
    ck(b1 && b1.analPressed === 'true' && b1.railPressed === 'true' && b1.analDisp !== 'none' && b1.railDisp !== 'none',
      'B1 默认两侧都显示（aria-pressed=true，display≠none）', J(b1 && { a: b1.analPressed, r: b1.railPressed, ad: b1.analDisp, rd: b1.railDisp }));

    /* ---------------- B2：点开关 → 完全隐藏 ---------------- */
    const b2 = await ev(`(function(){
      document.getElementById('npAnalToggle').click();
      var a=document.getElementById('npAnal'), g=document.getElementById('npGrid');
      var r1={cls:g.className, disp:getComputedStyle(a).display, w:a.getBoundingClientRect().width,
              pressed:document.getElementById('npAnalToggle').getAttribute('aria-pressed'),
              ls:localStorage.getItem('rta-np-anal')};
      document.getElementById('npAnalToggle').click();
      var r2={disp:getComputedStyle(a).display, pressed:document.getElementById('npAnalToggle').getAttribute('aria-pressed')};
      document.getElementById('npRailHide').click();
      var rr={disp:getComputedStyle(document.getElementById('npRail')).display, cls:g.className,
              pressed:document.getElementById('npRailToggle').getAttribute('aria-pressed')};
      document.getElementById('npRailToggle').click();
      return {r1:r1,r2:r2,rr:rr};
    })()`);
    ck(b2 && b2.r1.cls.indexOf('noanal') >= 0 && b2.r1.disp === 'none' && b2.r1.w === 0,
      'B2 点左栏开关 → #npAnal display:none 且宽度 0（完全隐藏）', J(b2 && b2.r1));
    ck(b2 && b2.r1.pressed === 'false' && b2.r1.ls === '0', 'B2 隐藏后 aria-pressed=false 且写入 localStorage=0', J(b2 && { p: b2.r1.pressed, ls: b2.r1.ls }));
    ck(b2 && b2.r2.disp !== 'none' && b2.r2.pressed === 'true', 'B2 再点恢复显示（display≠none，aria-pressed=true）', J(b2 && b2.r2));
    ck(b2 && b2.rr.disp === 'none' && b2.rr.cls.indexOf('norail') >= 0 && b2.rr.pressed === 'false',
      'B2 面板头部隐藏键同样能完全隐藏右栏', J(b2 && b2.rr));

    /* ---------------- B3：隐藏状态下的歌词居中 ---------------- */
    const geo = await ev(`(function(){
      var g=document.getElementById('npGrid'), body=document.querySelector('.npbody');
      var lyr=document.getElementById('npLyric');
      function dx(){ var rb=body.getBoundingClientRect(), lb=lyr.getBoundingClientRect();
                     return Math.abs((lb.left+lb.width/2)-(rb.left+rb.width/2)); }
      function cols(){ return getComputedStyle(body).gridTemplateColumns; }
      npPanelsSet('anal', false); npPanelsSet('rail', true);
      var leftHidden={dx:dx(), cols:cols(), ly:getComputedStyle(lyr).display};
      npPanelsSet('anal', true); npPanelsSet('rail', false);
      var rightHidden={dx:dx(), cols:cols(), ly:getComputedStyle(lyr).display};
      npPanelsSet('anal', false); npPanelsSet('rail', false);
      var both={dx:dx(), cols:cols(), lyDisp:getComputedStyle(lyr).display,
                lyrW:lyr.getBoundingClientRect().width, bodyW:body.getBoundingClientRect().width};
      npPanelsSet('anal', true); npPanelsSet('rail', true);
      return {leftHidden:leftHidden,rightHidden:rightHidden,both:both};
    })()`);
    ck(geo && geo.leftHidden.dx <= 1.5, 'B3 只隐藏左栏：歌词中心仍等于容器中心', J(geo && geo.leftHidden));
    ck(geo && geo.rightHidden.dx <= 1.5, 'B3 只隐藏右栏：歌词中心仍等于容器中心', J(geo && geo.rightHidden));
    ck(geo && geo.both.dx <= 1.5 && geo.both.lyDisp !== 'none' && Math.abs(geo.both.lyrW - geo.both.bodyW) <= 2,
      'B3 两侧都隐藏：歌词列占满整行且中心不变', J(geo && geo.both));

    /* ---------------- B4：localStorage 持久化 ---------------- */
    const b4 = await ev(`(function(){
      npPanelsSet('anal', false); npPanelsSet('rail', false);
      npPanelsLoad(); npPanelsApply();
      var a=localStorage.getItem('rta-np-anal'), r=localStorage.getItem('rta-np-rail');
      var cls=document.getElementById('npGrid').className;
      npPanelsSet('anal', true); npPanelsSet('rail', true);
      return {a:a,r:r,cls:cls};
    })()`);
    ck(b4 && b4.a === '0' && b4.r === '0' && b4.cls.indexOf('noanal') >= 0 && b4.cls.indexOf('norail') >= 0,
      'B4 隐藏状态写入 localStorage，npPanelsLoad+Apply 后恢复为隐藏', J(b4));

    /* ---------------- B5/B6：AI 右栏精简内容 ---------------- */
    const prev = await ev(`(function(){
      // 注入一份与后端 /api/entity/summary 同形的数据（fields 契约见 renderFieldGrid）
      S.curMeta = {title:'残響散歌', artist:'Aimer', album:'Open α Door', albumArtist:'Aimer',
                   codec:'flac', sampleRate:44100, bits:16, genre:'J-Pop'};
      S.dur = 184.2;
      NP_DATA.tabs = [
        {k:'track', label:'歌曲', name:'残響散歌', artist:'Aimer'},
        {k:'release', label:'专辑', name:'Open α Door', artist:'Aimer'},
        {k:'person', label:'艺术家', name:'Aimer', artist:''}
      ];
      NP_DATA.cache = {
        track:{state:'ok', data:{ok:true, ai:true, from_cache:true, fields:{'演唱':'Aimer','作词':'aimerrhythm','作曲':'飛内将大','歌曲风格':'J-Pop / 流行摇滚','发行时间':'2022'}}},
        release:{state:'ok', data:{ok:true, ai:true, from_cache:true, fields:{'出版方':'Sacra Music','专辑类型':'录音室专辑'}}},
        person:{state:'loading'}
      };
      NP_DATA.tabSig=''; NP_PREV={};
      npDataRenderTabs();
      var el=document.getElementById('npTabs');
      var out={};
      Array.prototype.forEach.call(el.querySelectorAll('.npchip'), function(b){
        out[b.dataset.k]={text:b.innerText.replace(/\\n/g,' | '), name:(b.querySelector('.npchip-name')||{}).textContent,
                          st:(b.querySelector('.npchip-st')||{}).textContent};
      });
      // 空数据回落：清空 fields + curMeta，确认仍显示本地事实而不是空白
      NP_DATA.cache = {track:{state:'idle'}, release:{state:'idle'}, person:{state:'idle'}};
      NP_DATA.tabSig=''; NP_PREV={};
      npDataRenderTabs();
      var local={};
      Array.prototype.forEach.call(el.querySelectorAll('.npchip'), function(b){
        local[b.dataset.k]=b.innerText.replace(/\\n/g,' | ');
      });
      NP_DATA.tabs=[]; NP_DATA.tabSig=null; NP_PREV={}; npDataRenderTabs();
      var empty=el.innerText;
      return {out:out, local:local, empty:empty};
    })()`);
    const trackTxt = (prev && prev.out.track && prev.out.track.text) || '';
    ck(/已缓存/.test(trackTxt) && /演唱 Aimer/.test(trackTxt), 'B5 歌曲卡显示状态 + 精简字段（已缓存 / 演唱 Aimer）', trackTxt);
    ck(/作词|作曲|歌曲风格/.test(trackTxt), 'B5 歌曲卡含 AI 整理字段（作词/作曲/歌曲风格）', trackTxt);
    ck(/出版方 Sacra Music/.test((prev && prev.out.release && prev.out.release.text) || ''), 'B5 专辑卡显示 AI 字段（出版方 Sacra Music）',
      (prev && prev.out.release && prev.out.release.text) || '');
    ck(/整理中/.test((prev && prev.out.person && prev.out.person.text) || ''), 'B5 加载中的栏目显示「整理中…」而不是空白',
      (prev && prev.out.person && prev.out.person.text) || '');
    const localTrack = (prev && prev.local && prev.local.track) || '';
    ck(/Aimer/.test(localTrack) && /FLAC|44\.1|k|bit/i.test(localTrack), 'B6 AI 数据缺失时回落本地事实（艺术家/格式/时长）', localTrack);
    ck(prev && /播放后在右侧显示/.test(prev.empty), 'B6 无当前曲目时右栏显示说明文案而不是空卡片', (prev && prev.empty) || '');

    /* ---------------- B7：资料浮层风格 ---------------- */
    await ev(`(function(){
      NP_DATA.active='track';
      var st={state:'ok', data:{ok:true, ai:true, from_cache:true, fields:{'演唱':'Aimer','歌曲风格':'J-Pop'}}};
      NP_DATA.cache.track=st;
      NP_DATA.tabSig=null; npDataRenderTabs();
      npDataHeader('track', st);
      npDrawerOpen();
      return 1;
    })()`);
    await ub.sleep(450);   // 等滑入 + 淡入的 CSS transition 走完（260ms）
    const b7 = await ev(`(function(){
      var d=document.getElementById('npDrawer'), cs=getComputedStyle(d), r=d.getBoundingClientRect();
      var open={radius:cs.borderRadius, shadow:cs.boxShadow, opacity:cs.opacity, vis:cs.visibility,
                right:Math.round(window.innerWidth-r.right), top:Math.round(r.top), w:Math.round(r.width),
                vw:window.innerWidth};
      npDrawerClose();
      return {open:open};
    })()`);
    await ub.sleep(400);   // 等收起动画结束：visibility 是离散属性，transition 结束才变 hidden
    const b7c = await ev(`(function(){
      var d=document.getElementById('npDrawer'), cs2=getComputedStyle(d);
      return {vis:cs2.visibility, opacity:cs2.opacity};
    })()`);
    ck(b7 && b7.open.radius === '18px', 'B7 浮层与 App 弹窗同源：18px 圆角', J(b7 && b7.open.radius));
    ck(b7 && /rgba?\(/.test(b7.open.shadow) && b7.open.shadow !== 'none', 'B7 浮层有浮起阴影（.mcard 同族）', J(b7 && b7.open.shadow.slice(0, 40)));
    ck(b7 && b7.open.right === 14 && b7.open.top === 14 && b7.open.w <= Math.round(b7.open.vw * 0.44) + 1,
      'B7 浮层四周留 14px 且宽度 ≤44vw（不再贴边占半屏）', J(b7 && { right: b7.open.right, top: b7.open.top, w: b7.open.w, vw: b7.open.vw }));
    ck(b7 && b7.open.vis === 'visible' && b7.open.opacity === '1', 'B7 打开态可见（visibility/opacity）', J(b7 && { vis: b7.open.vis, op: b7.open.opacity }));
    ck(b7c && b7c.vis === 'hidden', 'B7 关闭后 visibility:hidden（不残留可点区域）', J(b7c));

    /* ---------------- B8：无歌词列不再被整列隐藏 ---------------- */
    const b8 = await ev(`(function(){
      LY.lines = [];
      renderNpLyric();
      var g=document.getElementById('npGrid'), ly=document.getElementById('npLyric');
      return {nolyric:g.classList.contains('nolyric'), disp:getComputedStyle(ly).display,
              text:ly.textContent.slice(0,60), empty:ly.classList.contains('empty')};
    })()`);
    ck(b8 && b8.disp !== 'none' && b8.empty && b8.text.length > 0,
      'B8 无歌词时歌词列仍可见并显示提示（不再留整列空白）', J(b8));

    /* ---------------- B9：单曲页几何 ---------------- */
    const vps = [[1024, 640], [1280, 800], [1576, 908]];
    let geoOk = true;
    for (const [w, h] of vps) {
      await s.setViewport(w, h);
      await ub.sleep(250);
      const g = await ev(`(function(){
        var page=document.getElementById('npPage'), body=document.querySelector('.npbody');
        var a=document.getElementById('npAnal'), l=document.getElementById('npLyric'), r=document.getElementById('npRail');
        var ctl=document.querySelector('.npctl2');
        var ar=a.getBoundingClientRect(), lr=l.getBoundingClientRect(), rr=r.getBoundingClientRect();
        var cr=ctl.getBoundingClientRect();
        var overlap = !(ar.right <= lr.left + 1.5 || lr.right <= ar.left + 1.5 || ar.bottom <= lr.top + 1.5 || lr.bottom <= ar.top + 1.5) ||
                      !(rr.left >= lr.right - 1.5 || lr.left >= rr.right - 1.5 || rr.bottom <= lr.top + 1.5 || lr.bottom <= rr.top + 1.5);
        return {overlap:overlap, ctlIn: cr.top >= -0.5 && cr.bottom <= window.innerHeight + 0.5,
                sw: page.scrollWidth, vw: window.innerWidth,
                bodyW: body.getBoundingClientRect().width, vw2: window.innerWidth};
      })()`);
      const ok = g && !g.overlap && g.ctlIn && g.sw <= g.vw + 1;
      if (!ok) geoOk = false;
      ck(ok, `B9 单曲页几何 ${w}x${h}：三列不重叠 / 控制区在视口内 / 无横向溢出`,
        J(g && { overlap: g.overlap, ctlIn: g.ctlIn, sw: g.sw, vw: g.vw }));
    }
    await s.setViewport(1280, 800);

    /* ---------------- B10：Esc 先关弹窗 ---------------- */
    const b10 = await ev(`(function(){
      openNowPlaying();
      openModal('测试弹窗', '<div class=hint>x</div>');
      document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}));
      var m1=document.getElementById('modal').classList.contains('on');
      var p1=document.getElementById('npPage').classList.contains('on');
      return {modalOpen:m1, pageOpen:p1};
    })()`);
    ck(b10 && b10.modalOpen === false && b10.pageOpen === true, 'B10 Esc 先关闭弹窗，不关单曲页', J(b10));

    /* ---------------- 收尾：恢复默认布局，避免污染下一个脚本 ---------------- */
    await ev("(function(){ npPanelsSet('anal', true); npPanelsSet('rail', true); localStorage.removeItem('rta-np-anal'); localStorage.removeItem('rta-np-rail'); return 1; })()");

    console.log(`\n== ${total - fail}/${total} passed, ${fail} failed`);
    if (s.errors && s.errors.length) console.log('console errors: ' + J(s.errors.slice(0, 5)));
    process.exit(fail ? 1 : 0);
  } finally {
    await s.close();
  }
})().catch((e) => { console.error(e); process.exit(1); });
