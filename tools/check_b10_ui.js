// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_b10_ui.js — 1.1.4-beta10 三条用户反馈的 UI 判据
//
// ============================ 这个测试在证明什么 ============================
// 全部驱动生产页面里的真实函数（anlPaint / anlToggleAuto / npRailPreview / npDataRenderTabs /
// renderArtistsFrom / artistScrollSave / artistScrollRestore），不另写一份"和产品一样"的逻辑。
//
//   C1 音频分析的按钮布局分成两行：第 1 行只读（标题 + 状态），第 2 行才是操作
//      （自动 / 详细 / 分析）。判据是**几何**：三个按钮同处一行（top 差 ≤1px）、
//      全部落在面板内（不溢出、不换行），且状态文字的底边在按钮顶边之上。
//      —— 只看"有三个按钮"证明不了布局变好了，必须量位置。
//   C2 面板内「自动」开关与设置页「播放时自动分析」同一个真相源：
//      点开 → ANL.auto=1、ADV.autoanl=1、aria-pressed=true、落盘请求里 autoanl=1；
//      并且**立刻补跑一次**当前曲目（否则用户以为点了没反应）。
//      再点 → 回到 0，且此后的 anlTick 不再发分析请求。
//   C3 从设置页勾选/取消勾选，面板按钮的视觉状态同步（同一真相源，不允许两处不一致）。
//   C4 AI 整理「艺术家」卡的首行是**简介**，不是「国籍」：
//      C4a 有 fields['简介'] → 首行取简介；C4b 只有 sections 段落 → 取首段；
//      C4c 什么都没有 → 回落本地事实（艺术家名），**任何情况下都不出现「国籍 X」当主内容**。
//   C5 从艺术家列表点进资料页再返回，回到原来那位艺术家的位置（scrollTop 恢复）；
//      从别处导航进艺术家列表**不恢复**（不会有"莫名停在半路"）。
//   C6 左栏头部与右栏同一套视觉语言（用户第二张截图：「左面的这个按钮排布没有右面的和谐」）：
//      三个动作在**同一个分段控件外框**里（外框恰 1 个、三段同一父节点）、边框总数从 3 降到 1；
//      收起键与右栏 #npRailHide **同尺寸同圆角**；标题字号与右栏标题一致。
//   C7 合作署名拆分与归属：npSplitArtists 的纯函数判据（括号内不拆 / & 与 、 拆 / feat. 拆 /
//      重复去重 / 单个名字原样）+ renderArtistsFrom 里同一张合作专辑**同时**出现在每位参与者下，
//      且不再多出一位「A & B」。
//   C8 右栏「艺术家」卡的简介**带艺术家名字**（用户：「右侧栏的艺术家，简介要带上艺术家的名字」）。
//
// 🔴 铁律 1：全程 headless，不播放任何音频（不调 /api/play，settings 预置 backend=null）。
// 🔴 铁律 2：浏览器由 uibrowser 核验属主后 SIGTERM；测试服务器由调用方起好，本脚本不碰它。
//
// 用法：node tools/check_b10_ui.js http://127.0.0.1:19151/
// ⛔ 本脚本已**停用**（2026-11-08 用户钦定：禁止自起无头浏览器，需要浏览器时只走 DSH 侧边栏）。
// 它依赖 uibrowser.js 起 headless Edge —— 那会常驻上百进程并污染用户的浏览器。
// 同一批判据已迁移到两处，请用它们：
//   · 纯逻辑 → node tools/check_b10_logic.js（进 ctest 的 b10_logic 用例）
//   · 几何/点击 → 页面内自检：POST /api/selftest/request 后打开页面，结果落 <state>/selftest-last.json
// 保留本文件只为留下历史判据文本，**不要执行**。
'use strict';
const ub = require('./uibrowser');

const URL_ = process.argv[2] || 'http://127.0.0.1:19151/';
let fail = 0, total = 0;
function ck(ok, what, detail) {
  total++;
  if (!ok) fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${what}${detail ? '  ' + detail : ''}`);
}
const J = (o) => JSON.stringify(o);

(async () => {
  const s = await ub.open({ url: URL_, width: 1280, height: 900, settleMs: 2200 });
  try {
    const ready = await s.waitFor("typeof anlPaint==='function' && typeof npRailPreview==='function' && document.getElementById('npAnal')", 15000);
    if (!ready) {
      console.log('FATAL: 页面没起来（找不到 anlPaint / npRailPreview / #npAnal）: ' + await s.eval('location.href'));
      process.exit(2);
    }
    const ev = (x) => s.eval(x);
    await ev('(function(){ if(typeof openNowPlaying==="function") openNowPlaying(); return 1; })()');
    await ub.sleep(500);

    /* ---------------- 测试装置：拦住 /api/health 与 /api/settings ---------------- */
    await ev(`(function(){
      window.__b10 = {health: [], settings: [], orig: window.api};
      window.api = function(u, body){
        if (u && u.indexOf('/api/health') === 0){
          window.__b10.health.push(u);
          return Promise.resolve({ok:true, usable:true, cached:false, ms:1000, stats:{},
            health:{dr_db:14.6, lufs:-14.2, lra:8.1, peak_dbfs:-0.9, true_peak_dbtp:-0.4,
              true_peak_available:true, dr_available:true, lra_available:true, lufs_available:true,
              cutoff_hz:22040, confidence:0.92, fs:44100, channels:2, bits:16, status:'ready',
              analyzed_at_ms:1762400000000, quality:{available:true}}});
        }
        if (u && u.indexOf('/api/settings') === 0){ window.__b10.settings.push(body || ''); return Promise.resolve({ok:true}); }
        return window.__b10.orig(u, body);
      };
      return 1;
    })()`);

    /* ---------------- C1：两行布局（几何判据） ---------------- */
    const geo = async (w, h) => {
      await s.setViewport(w, h);
      await ub.sleep(220);
      return ev(`(function(){
        var panel=document.getElementById('npAnal');
        var stat=document.getElementById('npAnlStat');
        var btns=['npAnlAuto','npAnlToggle','npAnlRun'].map(function(id){ return document.getElementById(id); });
        if(!panel||!stat||btns.some(function(b){return !b;})) return {missing:true};
        var pb=panel.getBoundingClientRect();
        var sb=stat.getBoundingClientRect();
        var bs=btns.map(function(b){var r=b.getBoundingClientRect();return {t:Math.round(r.top),b:Math.round(r.bottom),l:Math.round(r.left),r:Math.round(r.right),txt:b.textContent,vis:getComputedStyle(b).display};});
        return {
          panel:{l:Math.round(pb.left),r:Math.round(pb.right),w:Math.round(pb.width)},
          stat:{t:Math.round(sb.top),b:Math.round(sb.bottom),l:Math.round(sb.left),r:Math.round(sb.right)},
          btns:bs,
          // 三个按钮同处一行：top 的最大差
          rowSpread: Math.max.apply(null, bs.map(function(x){return x.t;})) - Math.min.apply(null, bs.map(function(x){return x.t;})),
          // 按钮全部在面板内（右缘留 6px 余量 = 内边距），且不与状态文字重叠
          allInside: bs.every(function(x){ return x.r <= pb.right - 6 && x.l >= pb.left + 6; }),
          // 第 2 行在状态行下方（状态底边 <= 按钮顶边）
          stacked: bs.every(function(x){ return sb.bottom <= x.t + 0.5; })
        };
      })()`);
    };
    // 缺元素时（例如对修复前的构建跑）返回 {missing:true}，这里必须优雅降级 —— 判据要能
    // **红得清楚**，而不是让整条脚本崩在一个 undefined 上（那样就看不到后面几条的结论了）。
    const g1 = await geo(1280, 900);
    ck(g1 && !g1.missing && g1.btns.every(function (b) { return b.vis !== 'none'; }),
      'C1 面板里有 自动 / 详细 / 分析 三个按钮且都可见',
      g1 && !g1.missing ? J(g1.btns.map(function (b) { return b.txt; })) : 'missing #npAnlAuto/#npAnlToggle/#npAnlRun');
    ck(g1 && !g1.missing && g1.rowSpread <= 1, 'C1 三个按钮同处一行（top 差 ≤1px，没有换行）',
      g1 && !g1.missing ? 'spread=' + g1.rowSpread : 'missing');
    ck(g1 && !g1.missing && g1.allInside, 'C1 三个按钮全部落在面板内（不溢出右缘）',
      g1 && !g1.missing ? J({ panel: g1.panel, btns: g1.btns.map(function (b) { return [b.l, b.r]; }) }) : 'missing');
    ck(g1 && !g1.missing && g1.stacked, 'C1 按钮在状态行下方（标题/状态 一行，操作 一行）',
      g1 && !g1.missing ? 'statBottom=' + g1.stat.b + ' btnTop=' + g1.btns[0].t : 'missing');

    const g2 = await geo(1024, 640);
    ck(g2 && !g2.missing && g2.rowSpread <= 1 && g2.allInside,
      'C1 1024x640 窄窗下布局不变（三按钮仍同行且不溢出）',
      g2 && !g2.missing ? J({ spread: g2.rowSpread, inside: g2.allInside, panel: g2.panel }) : 'missing');
    await s.setViewport(1280, 900);
    await ub.sleep(200);

    /* ---------------- C2：面板内自动开关就是真相源 ---------------- */
    const FAKE = '/music/b10.flac';
    const c2off = await ev(`(function(){
      window.ANL.auto=0; window.ADV.autoanl=0; window.ANL.autoDone=''; window.ANL.cache={}; window.ANL.busy={};
      window.ANL.paintSig=''; if (typeof anlPaint === 'function') anlPaint();
      var b=document.getElementById('npAnlAuto');
      if(!b) return {missing:true};
      return {pressed:b.getAttribute('aria-pressed'), cls:b.className, txt:b.textContent};
    })()`);
    ck(c2off && !c2off.missing && c2off.pressed === 'false' && !/\bon\b/.test(c2off.cls) && c2off.txt === '自动',
      'C2 默认关闭：按钮文案「自动」、aria-pressed=false、无开启态样式', J(c2off));

    const c2on = await ev(`(function(){
      if (!document.getElementById('npAnlAuto')) return {missing:true};
      window.__b10.health.length=0; window.__b10.settings.length=0;
      window.S.lastCur=${JSON.stringify(FAKE)}; window.S.playing=true; window.S.paused=false;
      window.ANL.cur=${JSON.stringify(FAKE)};   // 已在听这首：点开开关就该补跑
      window.ANL.autoDone=''; window.ANL.cache={}; window.ANL.busy={};
      document.getElementById('npAnlAuto').click();
      var b=document.getElementById('npAnlAuto');
      return {auto:window.ANL.auto, adv:window.ADV.autoanl, pressed:b.getAttribute('aria-pressed'),
              cls:b.className, health:window.__b10.health.length,
              setReq:(window.__b10.settings[0]||'')};
    })()`);
    ck(c2on && !c2on.missing && c2on.auto === 1 && c2on.adv === 1,
      'C2 点「自动」→ ANL.auto 与 ADV.autoanl 同步为 1（内存真相源一致）', J(c2on && { auto: c2on.auto, adv: c2on.adv }));
    ck(c2on && !c2on.missing && c2on.pressed === 'true' && /\bon\b/.test(c2on.cls),
      'C2 按钮进入开启态（aria-pressed=true + .on 样式）', J(c2on && { p: c2on.pressed, cls: c2on.cls }));
    ck(c2on && !c2on.missing && c2on.health >= 1, 'C2 开启后**立刻**补跑当前曲目一次（不必等切歌）', 'health=' + (c2on && c2on.health));
    // saveSettings 是 300 ms 防抖：等它真的发出去再断言（否则判据只是在测"还没发"）
    await ub.sleep(420);
    const setReq = await ev('(window.__b10.settings || []).join(" & ")');
    ck(c2on && !c2on.missing && /autoanl=1/.test(setReq), 'C2 落盘请求里 autoanl=1（重启后仍然开着）',
      String(setReq).slice(0, 160));

    const c2again = await ev(`(function(){
      if (!document.getElementById('npAnlAuto')) return {missing:true};
      window.__b10.health.length=0;
      window.ANL.autoDone='';
      anlTick(${JSON.stringify(FAKE)}, true);
      var autoCalls=window.__b10.health.length;
      document.getElementById('npAnlAuto').click();
      window.__b10.health.length=0;
      window.ANL.autoDone='';
      anlTick(${JSON.stringify(FAKE)}, true);
      var offCalls=window.__b10.health.length;
      var b=document.getElementById('npAnlAuto');
      return {autoCalls:autoCalls, offCalls:offCalls, auto:window.ANL.auto, adv:window.ADV.autoanl,
              pressed:b.getAttribute('aria-pressed')};
    })()`);
    ck(c2again && !c2again.missing && c2again.pressed === 'false' && c2again.auto === 0 && c2again.adv === 0,
      'C2 再点一次回到关闭态（三处状态一起归零）', J(c2again && { p: c2again.pressed, a: c2again.auto, adv: c2again.adv }));
    ck(c2again && !c2again.missing && c2again.offCalls === 0,
      'C2 关闭后 anlTick 不再发分析请求（开关真的生效，不只是画个样式）', 'offCalls=' + (c2again && c2again.offCalls));

    /* ---------------- C3：设置页复选框与面板按钮同步 ---------------- */
    const c3 = await ev(`(function(){
      if (typeof openSettingsTab === 'function') openSettingsTab('adv');
      var c=document.getElementById('sp_autoanl');
      if(!c) return {missing:true};
      c.checked=true; c.onchange.call(c);
      var pa=document.getElementById('npAnlAuto');
      var onPressed=pa?pa.getAttribute('aria-pressed'):'(missing)';
      c.checked=false; c.onchange.call(c);
      var offPressed=pa?pa.getAttribute('aria-pressed'):'(missing)';
      if (typeof setView === 'function') setView('albums');
      return {onPressed:onPressed, offPressed:offPressed, auto:window.ANL.auto};
    })()`);
    ck(c3 && !c3.missing && c3.onPressed === 'true' && c3.offPressed === 'false',
      'C3 设置页勾选/取消 → 面板按钮同步开启/关闭（同一真相源）', J(c3 && { on: c3.onPressed, off: c3.offPressed }));

    /* ---------------- C4：艺术家卡首行是简介，不是国籍 ---------------- */
    const c4 = await ev(`(function(){
      window.S.curMeta = {title:'残響散歌', artist:'Aimer', album:'Open a Door', albumArtist:'Aimer'};
      var withBio = npRailPreview('person', {state:'ok', data:{ok:true, fields:{
        '国籍':'日本', '活跃年代':'2011 年至今', '风格':'J-POP', '代表作品':'残響散歌',
        '简介':'日本女性创作歌手，2011 年以单曲《六等星の夜》出道，声线偏低沉。'}}});
      var secOnly = npRailPreview('person', {state:'ok', data:{ok:true, unverified:true,
        sections:[{heading:'简介', paragraphs:[{text:'日本创作歌手，以动画主题曲闻名。'}]}]}});
      var nothing = npRailPreview('person', {state:'idle', data:null});
      // DOM 层：真正渲染一遍卡片，确认屏幕上看到的也是简介
      NP_DATA.tabs=[{k:'person', label:'艺术家', name:'Aimer', artist:''}];
      NP_DATA.cache={person:{state:'ok', data:{ok:true, fields:{'国籍':'日本','简介':'日本女性创作歌手，2011 年出道。'}}}};
      NP_DATA.tabSig=null; NP_PREV={}; npDataRenderTabs();
      var card=(document.querySelector('#npTabs .npchip')||{}).innerText || '';
      NP_DATA.tabs=[]; NP_DATA.tabSig=null; NP_PREV={}; npDataRenderTabs();
      return {withBio:withBio, secOnly:secOnly, nothing:nothing, card:card};
    })()`);
    ck(c4 && /日本女性创作歌手/.test(c4.withBio.p1) && !/国籍/.test(c4.withBio.p1),
      'C4a 有简介字段时首行显示简介（不含「国籍」）', J(c4 && c4.withBio));
    ck(c4 && /日本创作歌手/.test(c4.secOnly.p1) && !/国籍/.test(c4.secOnly.p1),
      'C4b 只有 sections 段落时首行取首段（旧缓存路径也不空白）', J(c4 && c4.secOnly));
    ck(c4 && c4.nothing.p1 === 'Aimer' && !/国籍/.test(c4.nothing.p1),
      'C4c 没有任何资料时回落艺术家名，而不是国籍', J(c4 && c4.nothing));
    ck(c4 && /日本女性创作歌手/.test(c4.card) && !/国籍\s*日本/.test(c4.card),
      'C4 渲染出的卡片文本是简介，不是「国籍 日本」', JSON.stringify(c4 && c4.card));
    await ev('(function(){ if(typeof npDataReset==="function") npDataReset(); return 1; })()');

    /* ---------------- C5：艺术家列表返回时回到原位置 ---------------- */
    const c5 = await ev(`(function(){
      var albums=[], i;
      for (i=0;i<80;i++) albums.push({k:'alb'+i, name:'Album '+i, artist:'Artist-'+String(i).padStart(2,'0'), dur:200, cv:false});
      window.viewCachePut('albums|', {albums:albums});
      window.setView('artists');
      window.loadArtists('');
      var m=document.querySelector('.main');
      var cards=document.querySelectorAll('#list .card');
      m.scrollTop=640;
      var before=m.scrollTop;
      // 点第 N 张（不在首屏，能证明恢复的是位置而不是"回到顶部"）
      var target=cards[Math.min(8, cards.length-1)];
      var who=target.dataset.a;
      target.click();
      return {cards:cards.length, before:before, who:who, view:window.S.view,
              active:!!(window.ARTIST_RET&&window.ARTIST_RET.active), saved:(window.ARTIST_RET||{}).top};
    })()`);
    ck(c5 && c5.cards >= 20 && c5.before >= 600 && c5.active === true,
      'C5 艺术家列表可滚动，点进资料页前记住 scrollTop', J(c5 && { cards: c5.cards, before: c5.before, saved: c5.saved }));
    await ub.sleep(400);
    const c5back = await ev(`(function(){
      var top=document.getElementById('bBackArtistsTop') || document.getElementById('bBackArtists');
      if (top) top.click(); else loadArtists('');
      return 1;
    })()`);
    await ub.sleep(500);
    const c5after = await ev(`(function(){
      var m=document.querySelector('.main');
      return {view:window.S.view, top:m.scrollTop, cards:document.querySelectorAll('#list .card').length,
              active:!!(window.ARTIST_RET&&window.ARTIST_RET.active)};
    })()`);
    ck(c5after && c5after.view === 'artists' && c5after.cards >= 20,
      'C5 返回后回到艺术家列表（不是别页）', J(c5after && { view: c5after.view, cards: c5after.cards }));
    ck(c5after && Math.abs(c5after.top - 640) <= 2,
      'C5 返回后滚动位置回到原处（不是第一屏）', J(c5after && { top: c5after.top, want: 640 }));

    const c5neg = await ev(`(function(){
      var m=document.querySelector('.main');
      // 先在别处把滚动位置改成另一个值，再从导航栏回到艺术家列表：
      // 若误用旧的 ARTIST_RET（640）恢复，top 会被拽回 640 —— 那才是要抓的回归。
      m.scrollTop=120;
      window.setView('albums');
      window.loadArtists('');
      return {top:document.querySelector('.main').scrollTop, active:!!(window.ARTIST_RET&&window.ARTIST_RET.active)};
    })()`);
    ck(c5neg && c5neg.active === false && Math.abs(c5neg.top - 640) > 40,
      'C5 从别处导航进艺术家列表不恢复旧位置（不会莫名停在半路）', J(c5neg));


    /* ---------------- C6：左栏头部与右栏同一套视觉语言 ---------------- */
    const c6 = await ev(`(function(){
      var seg=document.querySelector('#npAnal .anlseg');
      var kids=seg?Array.prototype.slice.call(seg.children):[];
      var ids=kids.map(function(b){return b.id;});
      var sameParent=kids.length===3 && kids.every(function(b){return b.parentElement===seg;});
      // 头部里带 1px 实线边框的元素个数（分段控件外框 = 1；旧版是三枚药丸各 1 个 = 3）
      var head=document.querySelector('#npAnal .anlhead');
      var bordered=0;
      if(head) Array.prototype.forEach.call(head.querySelectorAll('*'), function(el){
        var cs=getComputedStyle(el);
        var w=parseFloat(cs.borderTopWidth)||0;
        if(w>0 && cs.borderTopStyle!=='none' && el!==seg) bordered++;
      });
      var aHide=document.getElementById('npAnalHide'), rHide=document.getElementById('npRailHide');
      function box(el){ if(!el) return null; var r=el.getBoundingClientRect(), cs=getComputedStyle(el);
        return {w:Math.round(r.width), h:Math.round(r.height), radius:cs.borderRadius,
                border:parseFloat(cs.borderTopWidth)||0, disp:cs.display}; }
      var lab=document.querySelector('#npAnal .anllab'), cap=document.querySelector('#npRail .nprailcap');
      return {
        segCount: document.querySelectorAll('#npAnal .anlseg').length,
        kidCount: kids.length, ids: ids, sameParent: sameParent,
        bordered: bordered,
        segBorder: seg ? (parseFloat(getComputedStyle(seg).borderTopWidth)||0) : -1,
        aHide: box(aHide), rHide: box(rHide),
        labFont: lab ? getComputedStyle(lab).fontSize : '', labLs: lab ? getComputedStyle(lab).letterSpacing : '',
        capFont: cap ? getComputedStyle(cap).fontSize : '', capLs: cap ? getComputedStyle(cap).letterSpacing : ''
      };
    })()`);
    ck(c6 && c6.segCount === 1 && c6.kidCount === 3 && c6.sameParent,
      'C6 三个动作在同一个分段控件里（外框恰 1 个，三段同一父节点）',
      c6 ? J({ seg: c6.segCount, kids: c6.kidCount, same: c6.sameParent, ids: c6.ids }) : '');
    ck(c6 && c6.ids.join(',') === 'npAnlAuto,npAnlToggle,npAnlRun',
      'C6 分段顺序是 自动 → 详细 → 分析（与旧版一致，没被打乱）', c6 ? c6.ids.join(',') : '');
    ck(c6 && c6.bordered === 0 && c6.segBorder >= 1,
      'C6 头部只剩分段控件这 1 个外框（三枚各自描边的药丸已消失）',
      c6 ? J({ extraBordered: c6.bordered, segBorder: c6.segBorder }) : '');
    ck(c6 && c6.aHide && c6.rHide && Math.abs(c6.aHide.w - c6.rHide.w) <= 1 &&
       Math.abs(c6.aHide.h - c6.rHide.h) <= 1 && c6.aHide.radius === c6.rHide.radius &&
       c6.aHide.border === 0,
      'C6 收起键与右栏隐藏键同尺寸、同圆角、无边框（同一枚圆形图标键）',
      c6 && c6.aHide && c6.rHide ? J({ anl: c6.aHide, rail: c6.rHide }) : '');
    ck(c6 && c6.labFont && c6.labFont === c6.capFont && c6.labLs === c6.capLs,
      'C6 左栏标题与右栏标题同字号同字距（不再是"比正文大一档"的粗标题）',
      c6 ? J({ lab: c6.labFont + '/' + c6.labLs, cap: c6.capFont + '/' + c6.capLs }) : '');

    /* ---------------- C7：合作署名拆分与归属 ---------------- */
    const c7split = await ev(`(function(){
      var cases = [
        ['椎名林檎, 斎藤ネコ', ['椎名林檎','斎藤ネコ']],
        ['澤野 弘之 & SennaRin', ['澤野 弘之','SennaRin']],
        ['LiSA feat. PABLO', ['LiSA','PABLO']],
        ['FictionJunction featuring LiSA', ['FictionJunction','LiSA']],
        ['Lunity;Lunity;Lunity;Lunity', ['Lunity']],
        ['REIJINGSIGNAL(CV：Lynn、芹澤 優、鈴木みのり)', ['REIJINGSIGNAL(CV：Lynn、芹澤 優、鈴木みのり)']],
        ['Aimer', ['Aimer']],
        ['阿保 剛、いとうかなこ、Zwei、佐々木恵梨', ['阿保 剛','いとうかなこ','Zwei','佐々木恵梨']],
        ['アクアプラス(2ALAC+cue+log+png)', ['アクアプラス']]
      ];
      return cases.map(function(c){
        var got = npSplitArtists(c[0]);
        return {inp:c[0], got:got, want:c[1], ok: JSON.stringify(got)===JSON.stringify(c[1])};
      });
    })()`);
    const c7bad = (c7split || []).filter(function (x) { return !x.ok; });
    ck(c7bad.length === 0, 'C7 npSplitArtists：括号内不拆 / & 与 、 与 feat. 拆 / 重复去重 / 单名原样 / 标签残留剔除',
      c7bad.length ? J(c7bad) : (c7split || []).length + ' 个样例全对');
    ck(c7split && c7split.length > 0, 'C7 拆分样例集非空（防止判据空跑）', c7split ? String(c7split.length) : '');

    const c7attr = await ev(`(function(){
      var albums=[
        {k:'k1', name:'合作专辑', artist:'椎名林檎, 斎藤ネコ', dur:100, n:2, cv:false},
        {k:'k2', name:'个人专辑', artist:'椎名林檎', dur:100, n:2, cv:false},
        {k:'k3', name:'双人专辑', artist:'澤野 弘之 & SennaRin', dur:100, n:2, cv:false}
      ];
      window.viewCachePut('albums|', {albums:albums});
      window.setView('artists');
      window.loadArtists('');
      var names=[];
      Array.prototype.forEach.call(document.querySelectorAll('#list .card'), function(c){ names.push(c.dataset.a); });
      var counts={};
      Array.prototype.forEach.call(document.querySelectorAll('#list .card'), function(c){
        counts[c.dataset.a]=((c.querySelector('.ar')||{}).textContent||'');
      });
      return {names:names, counts:counts, total:names.length};
    })()`);
    ck(c7attr && c7attr.names.indexOf('椎名林檎') >= 0 && c7attr.names.indexOf('斎藤ネコ') >= 0 &&
       c7attr.names.indexOf('澤野 弘之') >= 0 && c7attr.names.indexOf('SennaRin') >= 0,
      'C7 合作专辑同时归到每位参与者名下（各位都出现了）', c7attr ? J(c7attr.names) : '');
    ck(c7attr && c7attr.names.indexOf('椎名林檎, 斎藤ネコ') < 0 && c7attr.names.indexOf('澤野 弘之 & SennaRin') < 0,
      'C7 不再新增「A & B」这种合成艺术家', c7attr ? J(c7attr.names) : '');
    ck(c7attr && /2 张专辑/.test(c7attr.counts['椎名林檎'] || ''),
      'C7 个人专辑与合作专辑合并计数（椎名林檎 = 2 张）', c7attr ? J(c7attr.counts) : '');

    // 「查看专辑」必须用同一套归属规则（否则点进合作艺术家是空列表）
    const c7subset = await ev(`(function(){
      var hit=null;
      Array.prototype.forEach.call(document.querySelectorAll('#list .card'), function(c){
        if(c.dataset.a==='斎藤ネコ') hit=c;
      });
      if(!hit) return {missing:true};
      hit.click();
      return {ok:true};
    })()`);
    await ub.sleep(900);
    const c7list = await ev(`(function(){
      return {view: window.S.view, names: (window.S.albums||[]).map(function(a){return a.name;}),
              cards: document.querySelectorAll('#list .card').length,
              head: (document.getElementById('pth')||{}).textContent};
    })()`);
    ck(c7subset && c7subset.ok && c7list && c7list.cards >= 1 && c7list.names.indexOf('合作专辑') >= 0,
      'C7 合作艺术家的「查看专辑」不是空列表（与首页同一套归属规则）', c7list ? J(c7list) : '');
    await ev("(function(){ if(typeof setView==='function') setView('albums'); return 1; })()");
    await ub.sleep(300);

    /* ---------------- C8：右栏艺术家简介带名字 ---------------- */
    const c8 = await ev(`(function(){
      window.S.curMeta = {title:'残響散歌', artist:'Aimer', album:'X', albumArtist:'Aimer'};
      NP_DATA.tabs=[{k:'person', label:'艺术家', name:'Aimer', artist:''}];
      // a) 简介不以名字开头 → 应加上「Aimer：」
      var a = npRailPreview('person', {state:'ok', data:{ok:true, fields:{
        '国籍':'日本', '简介':'日本女性创作歌手，2011 年出道。'}}});
      // b) 简介本来就以名字开头 → 不重复
      var b = npRailPreview('person', {state:'ok', data:{ok:true, fields:{
        '简介':'Aimer 日本女性创作歌手，2011 年出道。'}}});
      // c) 完全没有简介 → 至少是名字
      var c = npRailPreview('person', {state:'idle', data:null});
      return {a:a, b:b, c:c};
    })()`);
    ck(c8 && /^Aimer：日本女性创作歌手/.test(c8.a.p1),
      'C8 艺术家卡首行是「名字：简介」（简介带上艺术家名字）', c8 ? J(c8.a) : '');
    ck(c8 && /^Aimer 日本女性创作歌手/.test(c8.b.p1) && (c8.b.p1.match(/Aimer/g) || []).length === 1,
      'C8 简介本身以名字开头时不重复名字（不会出现「X：X 是……」）', c8 ? JSON.stringify(c8.b.p1) : '');
    ck(c8 && c8.c.p1 === 'Aimer', 'C8 没有简介时至少显示艺术家名字', c8 ? J(c8.c) : '');
    await ev('(function(){ if(typeof npDataReset==="function") npDataReset(); return 1; })()');

  } finally {
    await s.close();
  }
  console.log(`\n=== 结果：${total} 项，${fail} 失败 ===`);
  process.exit(fail === 0 ? 0 : 1);
})();
