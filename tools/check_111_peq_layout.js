// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_111_peq_layout.js —— EQ 页「拖节点时排版跟着抖」（2026-10-30 用户实测）
//
// 用户原话：「固定好窗口，现在移动节点就会动排版，画面一抖一抖的」。
//
// 判据（铁律 3：姿势要对）
//   * 不测"看起来抖不抖"，而是**量每个关键块的几何**：拖拽期间每帧采样
//     #peqCurve（曲线容器）/ #peqRows（20 行表格）/ #peqMsg 所在工具条的 top 与 height，
//     只要任一块的 top 位移 > 2px（肉眼可辨的一次跳动就是 3px 以上），就判红。
//   * 这比"截图比对"更硬：位置是布局的**结果**，文字换行/高度变化都会污染它。
//   * 反向对照：静止 1.5s 不许有任何位移（排除"采样噪声导致假红"）。
//
// 端口：rtaweb 19106 + CDP 9714（绝不碰 8899）；backend=null 不出声；
//       收尾用 pgrep/lsof 只读核验属主后 SIGTERM，绝不 force-kill。
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), net = require('net');
const { spawn, execFileSync } = require('child_process');
const ub = require('./uibrowser');

const args = process.argv.slice(2);
const argOf = (n, d) => { const i = args.indexOf(n); return i !== -1 && i + 1 < args.length ? args[i + 1] : d; };
const binary = path.resolve(argOf('--binary', 'build-mac/rtaweb'));
const port = 19106, cdpPort = 9714;

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-peq-layout-'));
const env = { ...process.env, HOME: path.join(root, 'home'), RLPLAYER_STATE_DIR: path.join(root, 'state'),
  RLPLAYER_LIBRARY_DIR: path.join(root, 'lib'), RLPLAYER_COVER_DIR: path.join(root, 'covers') };
for (const k of ['HOME', 'RLPLAYER_STATE_DIR', 'RLPLAYER_LIBRARY_DIR', 'RLPLAYER_COVER_DIR']) fs.mkdirSync(env[k], { recursive: true });
fs.mkdirSync(path.join(root, 'music'));
fs.writeFileSync(path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-settings.conf'),
  'backend=null\nmetaon=0\nmetallm=0\nvolume=-120\ntheme=light\nuistyle=apple\nlang=zh\n');

let child, session;
const results = [];
const ck = (v, name, data) => { results.push({ pass: !!v, name, data }); console.log((v ? 'PASS ' : 'FAIL ') + name + (data === undefined ? '' : '  ' + JSON.stringify(data))); };
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

function verifyOwnedServer() {
  const lines = execFileSync('pgrep', ['-u', String(process.getuid()), '-fl', 'rtaweb'], { encoding: 'utf8' }).split('\n').filter(Boolean);
  const mine = lines.find((l) => l.startsWith(String(child.pid) + ' '));
  if (!mine || !mine.includes('--port ' + port) || !mine.includes(root)) throw Error('属主核验失败，不发信号');
  const cwd = execFileSync('lsof', ['-p', String(child.pid), '-a', '-d', 'cwd', '-Fn'], { encoding: 'utf8' });
  if (!cwd.includes(root)) throw Error('cwd 不符，不发信号');
}

// 采样器：每帧记录三块的 top/height（getBoundingClientRect 会强制布局，但这是探针，非产品路径）
const PROBE_START = `(() => {
  window.__GEO = [];
  var box = document.getElementById('peqCurve');
  var rows = document.getElementById('peqRows');
  var msg = document.getElementById('peqMsg');
  var bar = msg && msg.parentElement;
  window.__GEO_TIMER = setInterval(function () {
    var b = box && box.getBoundingClientRect();
    var r = rows && rows.getBoundingClientRect();
    var t = bar && bar.getBoundingClientRect();
    var m = msg && msg.getBoundingClientRect();
    var st = document.getElementById('peqStatTxt');
    var s2 = st && st.getBoundingClientRect();
    var pane = document.querySelector('#setpage .spane[data-g=eq]');
    window.__GEO.push({ t: Math.round(performance.now()),
      boxTop: b ? Math.round(b.top * 10) / 10 : null, boxH: b ? Math.round(b.height * 10) / 10 : null,
      rowsTop: r ? Math.round(r.top * 10) / 10 : null,
      barH: t ? Math.round(t.height * 10) / 10 : null,
      msgH: m ? Math.round(m.height * 10) / 10 : null, msgW: m ? Math.round(m.width * 10) / 10 : null,
      statH: s2 ? Math.round(s2.height * 10) / 10 : null, statW: s2 ? Math.round(s2.width * 10) / 10 : null,
      clientW: document.documentElement.clientWidth,
      paneH: pane ? Math.round(pane.scrollHeight) : null,
      scrollH: document.documentElement.scrollHeight });
  }, 16);
  return true;
})()`;
const PROBE_STOP = `(() => { clearInterval(window.__GEO_TIMER); return window.__GEO; })()`;

// 拖 11 号节点（1 kHz，位置居中，横向抖动最小）：先 pointerdown，再 24 次 pointermove，
// 每次间隔 ~70ms（>100ms 节流的一半，能触发多次 /api/peq 往返），最后 pointerup。
const DRAG = (n) => `(() => {
  var svg = document.querySelector('#peqCurve svg.peqsvg');
  var node = svg && svg.querySelector('.peqnode[data-i="11"]');
  if (!svg || !node) return { err: 'no svg/node' };
  var r = svg.getBoundingClientRect(), vb = svg.viewBox.baseVal;
  var cx = r.left + (+node.getAttribute('cx')) / vb.width * r.width;
  var cy = r.top + (+node.getAttribute('cy')) / vb.height * r.height;
  window.__PT = { cx: cx, y: cy };
  node.dispatchEvent(new PointerEvent('pointerdown', { clientX: cx, clientY: cy, bubbles: true, pointerId: 1, isPrimary: true }));
  var i = 0;
  window.__MOVE = setInterval(function () {
    i++;
    var y = cy - i * ${n};                     // 向上 = 加增益
    svg.dispatchEvent(new PointerEvent('pointermove', { clientX: cx + (i % 2), clientY: y, bubbles: true, pointerId: 1, isPrimary: true }));
    if (i >= 24) {
      clearInterval(window.__MOVE);
      svg.dispatchEvent(new PointerEvent('pointerup', { clientX: cx, clientY: y, bubbles: true, pointerId: 1, isPrimary: true }));
    }
  }, 70);
  return { startGain: +document.querySelector('#peqRows .peqr[data-i="11"] .peqG').value };
})()`;

function deltas(geo) {
  const out = {};
  for (const k of ['boxTop', 'boxH', 'rowsTop', 'barH', 'msgW', 'msgH', 'statW', 'statH', 'clientW', 'paneH', 'scrollH']) {
    const vals = geo.map((g) => g[k]).filter((v) => typeof v === 'number');
    if (!vals.length) continue;
    out[k] = { min: Math.min(...vals), max: Math.max(...vals), delta: Math.round((Math.max(...vals) - Math.min(...vals)) * 10) / 10 };
  }
  return out;
}

(async () => {
  let ok = true;
  try {
    await new Promise((resolve, reject) => { const s = net.createServer(); s.once('error', reject); s.listen(port, '127.0.0.1', () => s.close(resolve)); });
    child = spawn(binary, ['--port', String(port), '--music-dir', path.join(root, 'music')], { env, cwd: root, stdio: 'ignore' });
    let up = false;
    for (let i = 0; i < 150; i++) { try { if ((await fetch(`http://127.0.0.1:${port}/api/ping`)).ok) { up = true; break; } } catch (e) { } await pause(100); }
    if (!up) throw Error('rtaweb 没起来');
    console.log('[env] rtaweb pid=' + child.pid + ' binary=' + binary);
    session = await ub.open({ url: `http://127.0.0.1:${port}/`, port: cdpPort });
    if (!await session.waitFor("typeof openSettingsTab==='function' && document.getElementById('bHelp')", 12000)) throw Error('UI 没就绪');
    await session.eval("openSettingsTab('eq')");
    if (!await session.waitFor("!!document.querySelector('#peqCurve svg.peqsvg .peqnode')", 10000)) throw Error('PEQ 曲线没出来');
    await pause(600);
    // 固定窗口尺寸，排除"窗口被改"这种外部因素（用户说"固定好窗口"）
    await session.setViewport(+(argOf('--vw', '1400')), +(argOf('--vh', '900')));
    await pause(400);

    // ---- 静止对照：1.5s 内不许有任何位移 ----
    await session.eval(PROBE_START);
    await pause(1500);
    const idle = await session.eval(PROBE_STOP);
    const dIdle = deltas(idle);
    ck(!dIdle.boxTop || dIdle.boxTop.delta <= 1, '静止 1.5s：曲线容器 top 不动（采样自证无假红）', dIdle.boxTop);

    // ---- 拖拽：24 次 move / ~1.7s，期间会有多次 /api/peq 往返 ----
    await session.eval(PROBE_START);
    const dragInfo = await session.eval(DRAG(+(argOf('--step', '4'))));
    console.log('       拖拽起点:', JSON.stringify(dragInfo));
    await pause(2200);
    const geo = await session.eval(PROBE_STOP);
    const d = deltas(geo);
    console.log('       采样 ' + (Array.isArray(geo) ? geo.length : 'x') + ' 帧；首帧=' + JSON.stringify((geo || [])[0] || null));
    const pick = (k) => d[k] || null;
    console.log('       几何范围:', JSON.stringify({ boxTop: pick('boxTop'), barH: pick('barH'), msgW: pick('msgW'), statH: pick('statH'), clientW: pick('clientW'), scrollH: pick('scrollH'), paneH: pick('paneH') }));
    if (session.errors && session.errors.length) console.log('       页面异常:', JSON.stringify(session.errors.slice(0, 3)));
    const shiftBox = d.boxTop ? d.boxTop.delta : 0;
    const shiftRows = d.rowsTop ? d.rowsTop.delta : 0;
    const shiftBar = d.barH ? d.barH.delta : 0;
    ck(shiftBox <= 2, '拖拽期间曲线容器 top 位移 ≤2px（排版不许被文字撑动）', d.boxTop);
    ck(shiftRows <= 2, '拖拽期间 20 行表格 top 位移 ≤2px', d.rowsTop);
    ck(shiftBar <= 2, '拖拽期间工具条高度变化 ≤2px（长文案不许换行撑高）', d.barH);
    ck(!d.scrollH || d.scrollH.delta <= 2, '拖拽期间页面 scrollHeight 变化 ≤2px（不出现滚动条抖动）', d.scrollH);

    // ---- 顺带断言：拖完增益真的变了（证明这条链路不是"什么都没发生"）----
    const gainAfter = await session.eval("+document.querySelector('#peqRows .peqr[data-i=\"11\"] .peqG').value");
    ck(gainAfter > dragInfo.startGain + 2, '拖拽确实改变了该段增益（判据有对象）', { before: dragInfo.startGain, after: gainAfter });

    // ---- 交互口径：默认只改增益；按住 Option 才横向改频率 ----
    const DRAG2 = (dx, dy, alt) => `(() => {
      var svg = document.querySelector('#peqCurve svg.peqsvg');
      var node = svg && svg.querySelector('.peqnode[data-i="11"]');
      var tr = document.querySelector('#peqRows .peqr[data-i="11"]');
      if (!svg || !node || !tr) return { err: 'missing' };
      var r = svg.getBoundingClientRect(), vb = svg.viewBox.baseVal;
      var cx = r.left + (+node.getAttribute('cx')) / vb.width * r.width;
      var cy = r.top + (+node.getAttribute('cy')) / vb.height * r.height;
      var before = { freq: tr.querySelector('.peqF').value, gain: +tr.querySelector('.peqG').value };
      node.dispatchEvent(new PointerEvent('pointerdown', { clientX: cx, clientY: cy, bubbles: true, pointerId: 1, isPrimary: true, altKey: ${alt} }));
      for (var s = 1; s <= 6; s++) {
        svg.dispatchEvent(new PointerEvent('pointermove', {
          clientX: cx + ${dx} * s / 6, clientY: cy + ${dy} * s / 6,
          bubbles: true, pointerId: 1, isPrimary: true, altKey: ${alt} }));
      }
      var after = { freq: tr.querySelector('.peqF').value, gain: +tr.querySelector('.peqG').value };
      svg.dispatchEvent(new PointerEvent('pointerup', { clientX: cx + ${dx}, clientY: cy + ${dy}, bubbles: true, pointerId: 1, isPrimary: true, altKey: ${alt} }));
      return { before: before, after: after };
    })()`;

    await session.eval("peqResetBand(11)");
    await pause(500);
    // ① 普通拖拽：故意给 +60px 横向位移（模拟手抖），频率必须一点不动
    const plain = await session.eval(DRAG2(60, -40, false));
    console.log('       普通拖拽(带横向抖动 60px):', JSON.stringify(plain));
    ck(plain && plain.after.freq === plain.before.freq, '普通拖拽不改频率（横向手抖被忽略）', plain && { before: plain.before.freq, after: plain.after.freq });
    ck(plain && Math.abs(plain.after.gain - plain.before.gain) > 1, '普通拖拽确实改了增益（判据有对象）', plain && { before: plain.before.gain, after: plain.after.gain });

    await session.eval("peqResetBand(11)");
    await pause(500);
    // ② 按住 Option 拖拽：频率必须跟着横向位移走
    const altDrag = await session.eval(DRAG2(60, -30, true));
    console.log('       Option 拖拽:', JSON.stringify(altDrag));
    ck(altDrag && altDrag.after.freq !== altDrag.before.freq, '按住 Option 才横向改频率', altDrag && { before: altDrag.before.freq, after: altDrag.after.freq });

    ok = results.every((r) => r.pass);
    console.log('\n[RESULT] ' + (ok ? 'ALL PASS' : 'HAS FAIL') + `  (${results.filter((r) => r.pass).length}/${results.length})`);
  } catch (e) {
    ok = false;
    console.log('[ERROR] ' + (e && e.message ? e.message : e));
  } finally {
    if (session) { try { await session.close(); } catch (e) { console.log('[teardown] 浏览器: ' + e.message); } }
    if (child && child.pid) {
      try {
        verifyOwnedServer();
        child.kill('SIGTERM');
        const t0 = Date.now();
        while (Date.now() - t0 < 10000 && child.exitCode === null) await pause(100);
        console.log('[teardown] rtaweb exit=' + child.exitCode);
      } catch (e) { console.log('[teardown] 未发信号: ' + e.message); }
    }
    console.log('[teardown] 临时目录: ' + root);
  }
  process.exit(ok ? 0 : 1);
})();
