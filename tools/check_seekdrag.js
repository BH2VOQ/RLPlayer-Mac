// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_seekdrag.js — 1.1.0「拖动进度条不丝滑」的 CDP 验收（无声：backend=null / volume=-60）
//
// 判据（每条都要能证明它要证明的事，不能只看"没崩"）：
//   A 按下即预览     pointerdown 落 25% → 条子立刻到 25%±1.5、#tpos≈0.25×dur±2 s（旧实现：一动不动）
//   B 1:1 跟手       pointermove 60% / 38% → 条子跟着走（旧实现：只有松手才跳一次）
//   C 拖动中零请求   __seekCalls 恒为 0（证明"每像素一次 seek"确实没有发生）
//   D 不橡皮筋       拖动中跨 ≥2 个 400 ms 轮询，条子仍停在 38%±1（旧实现：被 j.pos 拉回）
//   E 松手只发一次   __seekCalls == 1，且条子停在 38% 不回弹
//   F 真跳转         后端 pos 1.5 s 内到 38%±2 s（证明提交真生效，不是只改了 UI）
//   G 无补间         getComputedStyle(#bar).transitionDuration == 0s（根因②：0.18 s 会让它永远慢半拍）
//   H 播放中连续推进 两次采样间后端 S.pos 未变、但条子宽度在长（rAF 外推，不再 400 ms 一格）
//   I 整页同一套     #npSeek 拖动 / 提交同样成立
//   J 其它入口不回归 seekRel(5) 立刻 +5 s 且条子跟随
//
// 用法：node tools/check_seekdrag.js [base] [outDir]
//       node tools/check_seekdrag.js [base] [outDir] --red
//   --red：把**旧实现**（只有一个 onclick 的进度条）原样克隆到页面上，用同一套测量方法
//          再测一遍 A/B/C —— 必须测出"按下不预览 / 移动不跟手"。这就是判据的红：
//          它只在"新实现"上成立，不是写什么都能过（铁律 3：先跑红，再改成绿）。
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');

const base = (process.argv[2] || 'http://127.0.0.1:19099').replace(/\/$/, '');
const out = process.argv[3] || 'debug/20261028-03-进度条拖动/shots';
fs.mkdirSync(out, { recursive: true });

const sleep = ub.sleep;
const lines = [];
let failures = 0;
function check(ok, label, detail) {
  const line = `${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(detail)}`;
  lines.push(line);
  console.log(line);
  if (!ok) failures++;
  return ok;
}
async function api(p, body) {
  const r = await fetch(base + p, body === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body,
  });
  return r.json();
}

(async () => {
  let s = null;
  try {
    // ---- 安全前提：必须是 NullSink + -60 dB，否则拒绝继续（铁律 1）----
    const st = await api('/api/settings');
    if (!st.kv || st.kv.backend !== 'null' || String(st.kv.volume) !== '-60') {
      throw new Error('测试实例必须是 backend=null / volume=-60，当前 = ' + JSON.stringify(st.kv && { backend: st.kv.backend, volume: st.kv.volume }));
    }
    // ---- 确保在播（有真实 dur 才能验证拖动）----
    const status0 = await api('/api/status');
    if (!(status0.playing && status0.dur > 0)) {
      const albums = await api('/api/lib/albums');
      const k = albums.albums && albums.albums[0] && albums.albums[0].k;
      if (!k) throw new Error('库里没有曲目，无法验证（先 --music-dir 指一个测试目录）');
      const alb = await api('/api/lib/album?k=' + encodeURIComponent(k));
      const f = alb.tracks[0].path;
      await api('/api/play', 'file=' + encodeURIComponent(f) + '&backend=null&volume=-60');
      await sleep(1500);
    }

    s = await ub.open({ url: base, width: 1576, height: 908 });
    if (!await s.waitFor('window.S && !!D("seek") && S.dur > 0 && S.playing', 20000)) {
      throw new Error('页面没就绪（S.dur/S.playing 未到位）');
    }
    await sleep(600);
    // 计数桩：只在页面内包 fetch（不改产品代码）
    await s.eval(`(function(){
      if (window.__seekCalls === undefined) {
        window.__seekCalls = 0; window.__statusCalls = 0;
        var of = window.fetch;
        window.fetch = function (u, o) {
          var uu = String((u && u.url) ? u.url : u);
          if (uu.indexOf('/api/seek') >= 0) window.__seekCalls++;
          if (uu.indexOf('/api/status') >= 0) window.__statusCalls++;
          return of.apply(this, arguments);
        };
      }
      return 1;
    })()`);

    const mouse = (type, x, y, extra) => s.send('Input.dispatchMouseEvent', Object.assign({
      type, x: Math.round(x), y: Math.round(y), button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1,
    }, extra || {}));

    // 条子几何：用**实际渲染宽度**而不是 style.width（用户看到的是几何，不是字符串）
    const geoExpr = `(function(){
      function pct(barId, trackId){
        var b = D(barId), t = D(trackId);
        if (!b || !t) return null;
        var tw = t.getBoundingClientRect().width, bw = b.getBoundingClientRect().width;
        return tw > 0 ? +(bw / tw * 100).toFixed(2) : null;
      }
      var t = D('seek').getBoundingClientRect();
      return { x: t.left, y: t.top + t.height / 2, w: t.width,
               bar: pct('bar','seek'), npBar: pct('npBar','npSeek'),
               dur: S.dur, pos: S.pos, tpos: D('tpos') ? D('tpos').textContent : '',
               npos: D('npPos') ? D('npPos').textContent : '',
               drag: SEEK.drag, seekCalls: window.__seekCalls || 0 };
    })()`;
    const geo = () => s.eval(geoExpr);
    const toSec = (txt) => { const p = String(txt).split(':').map(Number); return p.length === 3 ? p[0] * 3600 + p[1] * 60 + p[2] : (p.length === 2 ? p[0] * 60 + p[1] : Number(txt)); };

    let g = await geo();
    check(g.w > 100 && g.dur > 10, '前提：底栏进度条可点且有时长', { w: Math.round(g.w), dur: g.dur });

    // ---- --red：同一套测量方法测「旧实现」，必须测出红 ----
    if (process.argv.includes('--red')) {
      const r = await s.eval(`(function(){
        var old = document.createElement('div');
        old.className = 'track'; old.id = 'seekLegacy';
        old.style.width = '356px'; old.style.marginTop = '6px';
        var fill = document.createElement('i'); fill.id = 'barLegacy'; old.appendChild(fill);
        D('seek').parentNode.appendChild(old);
        // 旧实现：只有 onclick（mouseup 之后才触发一次），没有任何 pointer 处理
        old.onclick = function (ev) {
          if (!S.dur) return;
          var b = this.getBoundingClientRect();
          doSeek((ev.clientX - b.left) / Math.max(1, b.width));
        };
        return 1;
      })()`);
      const L = await s.eval(`(function(){
        function pct(){var b=D('barLegacy'),t=D('seekLegacy');
          return +(b.getBoundingClientRect().width / t.getBoundingClientRect().width * 100).toFixed(2);}
        var t=D('seekLegacy').getBoundingClientRect();
        return {x:t.left,y:t.top+t.height/2,w:t.width,bar:pct(),dur:S.dur,calls:window.__seekCalls||0};
      })()`);
      const before = L.calls;
      await mouse('mousePressed', L.x + L.w * 0.25, L.y);
      await sleep(90);
      const rA = await s.eval(`D('barLegacy').getBoundingClientRect().width / D('seekLegacy').getBoundingClientRect().width * 100`);
      await mouse('mouseMoved', L.x + L.w * 0.60, L.y);
      await sleep(60);
      const rB = await s.eval(`D('barLegacy').getBoundingClientRect().width / D('seekLegacy').getBoundingClientRect().width * 100`);
      const rC = await s.eval('window.__seekCalls');
      await mouse('mouseReleased', L.x + L.w * 0.60, L.y);
      await sleep(250);
      const rD = await s.eval('window.__seekCalls');
      // 红：旧实现在"按下/移动"阶段条子必须不动、且不发请求；松手才发一次
      const redA = !(Math.abs(rA - 25) <= 1.5);
      const redB = !(Math.abs(rB - 60) <= 1.5);
      const redD = (rD - before) === 1;
      check(redA, 'RED 旧实现：按下 25% 没有预览（新判据 A 在旧实现上失败）', { bar: +rA.toFixed(2) });
      check(redB, 'RED 旧实现：拖动到 60% 不跟手（新判据 B 在旧实现上失败）', { bar: +rB.toFixed(2) });
      check(rC === before, 'RED 旧实现：拖动中同样零请求（C 对两者都成立，不是区分点）', { calls: rC - before });
      check(redD, 'RED 旧实现：松手才发 1 次 seek（E 的提交语义两者一致）', { calls: rD - before });
      console.log('\n' + (failures ? `RED 判据不成立 ${failures} 条` : 'RED OK：判据能区分新旧实现'));
      if (s) { try { await s.close(); } catch (e) { } }
      fs.writeFileSync(path.join(out, 'report-red.txt'), lines.join('\n') + '\n');
      process.exit(failures ? 1 : 0);
    }

    // ---- A 按下即预览 ----
    await mouse('mousePressed', g.x + g.w * 0.25, g.y);
    await sleep(90);
    let a = await geo();
    const aWant = 0.25 * a.dur;
    check(Math.abs(a.bar - 25) <= 1.5 && a.drag === 'seek' && Math.abs(toSec(a.tpos) - aWant) <= 2,
      'A 按下 25% 立刻预览（不等松手）', { bar: a.bar, tpos: a.tpos, want: Math.round(aWant), drag: a.drag });

    // ---- B 1:1 跟手 ----
    await mouse('mouseMoved', g.x + g.w * 0.60, g.y);
    await sleep(60);
    const b60 = await geo();
    await mouse('mouseMoved', g.x + g.w * 0.38, g.y);
    await sleep(60);
    const b38 = await geo();
    check(Math.abs(b60.bar - 60) <= 1.5 && Math.abs(b38.bar - 38) <= 1.5,
      'B pointermove 60% / 38% 条子 1:1 跟手', { at60: b60.bar, at38: b38.bar });

    // ---- C 拖动中零请求 ----
    check(b38.seekCalls === 0, 'C 拖动全程不发 seek 请求', { seekCalls: b38.seekCalls });

    // ---- D 不橡皮筋：跨 ≥2 个 400 ms 轮询 ----
    const st0 = await s.eval('window.__statusCalls');
    await sleep(1100);
    const d = await geo();
    const st1 = await s.eval('window.__statusCalls');
    check(Math.abs(d.bar - 38) <= 1 && (st1 - st0) >= 2,
      'D 拖动中跨多个轮询不被回拉（无橡皮筋）', { bar: d.bar, polls: st1 - st0 });

    // ---- E 松手只提交一次 ----
    await mouse('mouseReleased', g.x + g.w * 0.38, g.y);
    await sleep(300);
    const e = await geo();
    check(e.seekCalls === 1 && e.drag === null && Math.abs(e.bar - 38) <= 1,
      'E 松手只发 1 次 seek 且条子不回弹', { seekCalls: e.seekCalls, bar: e.bar, drag: e.drag });

    // ---- F 真跳转（后端 pos 追上）----
    const want = 0.38 * e.dur;
    let f = null;
    for (let i = 0; i < 15; i++) {
      await sleep(120);
      const j = await api('/api/status');
      if (Math.abs((j.pos || 0) - want) <= 2.0) { f = { pos: +j.pos.toFixed(2), want: +want.toFixed(2) }; break; }
    }
    check(!!f, 'F 后端 pos 真的跳到 38%（不是只改了界面）', f || { want: +want.toFixed(2) });

    // ---- G CSS 无 width 补间 ----
    const gcss = await s.eval(`(function(){
      var cs = getComputedStyle(D('bar'));
      return { td: cs.transitionDuration, prop: cs.transitionProperty };
    })()`);
    check(gcss.td === '0s' || gcss.td === '0s, 0s', 'G 填充条没有 0.18 s 补间（根因②）', gcss);

    // ---- H 播放中连续推进（rAF 外推）----
    let h = null;
    for (let i = 0; i < 8; i++) {
      const p0 = await geo();
      await sleep(160);
      const p1 = await geo();
      if (Math.abs(p1.pos - p0.pos) < 1e-9 && p1.bar > p0.bar + 0.005) {
        h = { posFrozen: +p0.pos.toFixed(3), barFrom: p0.bar, barTo: p1.bar };
        break;
      }
    }
    check(!!h, 'H 后端 pos 未变的 160 ms 内条子仍在前进（60 fps 外推）', h || '没抓到静止窗口');

    // ---- I 整页进度条同一套 ----
    await s.eval('openNowPlaying()');
    await sleep(500);
    const npr = await s.eval(`(function(){var r=D('npSeek').getBoundingClientRect();return {x:r.left,y:r.top+r.height/2,w:r.width,on:D('npPage').classList.contains('on')};})()`);
    let iRes = { on: npr.on };
    if (npr.on && npr.w > 100) {
      const callsBefore = await s.eval('window.__seekCalls');
      await mouse('mousePressed', npr.x + npr.w * 0.70, npr.y);
      await sleep(90);
      const iPress = await geo();
      await mouse('mouseMoved', npr.x + npr.w * 0.66, npr.y);
      await sleep(60);
      const iMove = await geo();
      await mouse('mouseReleased', npr.x + npr.w * 0.70, npr.y);
      await sleep(320);
      const iUp = await geo();
      iRes = Object.assign(iRes, {
        barPress: iPress.npBar, barMove: iMove.npBar, barUp: iUp.npBar,
        npos: iUp.npos, calls: (iUp.seekCalls - callsBefore),
      });
      check(Math.abs(iPress.npBar - 70) <= 1.5 && Math.abs(iMove.npBar - 66) <= 1.5 &&
            Math.abs(iUp.npBar - 70) <= 1.5 && (iUp.seekCalls - callsBefore) === 1,
        'I 整页进度条：按下预览 / 跟手 / 松手只提交一次', iRes);
      await s.shot(path.join(out, 'np-seek-drag.png'));
    } else {
      check(false, 'I 整页进度条：没能打开单曲页', iRes);
    }

    // ---- J 相对跳转（键盘 ←/→ → seekRel）必须相对「屏幕上显示的位置」 ----
    //   这一条是刻意在"刚 seek 完、后端还没追上"的窗口里做的：旧实现用 S.pos（旧位置）
    //   会算出让画面倒退的目标（实测 70% 按 +5 s 退到 40%）。判据 = 落点相对**显示值**。
    const j0 = await geo();
    const callsBeforeJ = j0.seekCalls;
    await s.eval('seekRel(5)');
    await sleep(220);
    const j1 = await geo();
    const expectBar = j0.bar + 5 / j1.dur * 100;
    check((j1.seekCalls - callsBeforeJ) === 1 && Math.abs(j1.bar - expectBar) <= 2,
      'J seekRel(5) 相对显示位置 +5 s（不退回到旧 pos）', { from: j0.bar, to: j1.bar, expect: +expectBar.toFixed(2) });

    await s.eval('closeNowPlaying()');
    await s.shot(path.join(out, 'seek-bottom.png'));

    check((s.errors || []).length === 0, '页面无 JS 异常/console.error', (s.errors || []).slice(0, 3));
  } catch (e) {
    check(false, '脚本异常', String(e && e.message || e));
  } finally {
    if (s) { try { await s.close(); } catch (e) { console.log('关闭浏览器失败：' + e.message); } }
  }
  console.log('\n' + (failures ? `FAILED ${failures} 条` : 'ALL PASS'));
  fs.writeFileSync(path.join(out, 'report.txt'), lines.join('\n') + '\n');
  process.exit(failures ? 1 : 0);
})();
