// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_111_peq_smooth.js —— PEQ 曲线拖拽「卡顿」量化测量（2026-10-30）
//
// 要证明什么（铁律 3：这个指标真能证明"卡"吗？）：
//   「拖 EQ 曲线卡」不能靠"看着卡"或平均帧率下结论。必须给出**拖拽期间**的帧时间分布、长任务、
//   以及"pointermove 到达 → 下一帧呈现"的延迟。本脚本用 CDP 真输入（Input.dispatchMouseEvent）
//   在真实生产 DOM 上按 ~120Hz（8ms/次）发 120 次 pointermove，全程用 rAF + PerformanceObserver
//   采样，输出可直接互相比较的数字。
//
// 四组测量（同一页面、同一节点、同一节奏）：
//   ① idle     不拖，纯基线（证明"卡"不是 headless/容器本身带来的）
//   ② inrange  量程内锯齿拖拽（PEQ_VIEW_HINT 为空 ⟹ 不进整块重绘分支）
//   ③ expand   拖到超出当前量程（+24 / −24）⟹ 触发 PEQ_VIEW_HINT 扩量程 + peqDrawCurve 整块重绘
//   ④ inrange2 复测 ②（看数字是否稳定，排除一次性抖动）
//   ⟹ ②③ 的差值 = "扩量程分支"的代价；③ 里再按"这一帧有没有重绘"做归因。
//
// 判据（初筛阈值；最终按实测真实数字定，绝不为了变绿而放宽）：
//   p95 帧时间 > 25ms        （≈ 丢一个 60Hz vsync，用户能看到的顿）
//   掉帧数(>25ms) > 10       （120 次拖拽里超过 10 帧掉）
//   longtask 总时长 > 100ms  （单帧主线程阻塞 >50ms 的累计）
//   pointermove 最差延迟 > 50ms（指针动了半个屏幕时间画面还没动）
//
// 安全：backend=null（不打开任何音频设备，铁律 1）；端口 rtaweb 19106 + CDP 9713，
//       8899 永不触碰；退出前 ps 核验属主再 SIGTERM，绝不 kill -9。
//
// ⚠️ 本机沙箱适配（不改 uibrowser.js）：本会话沙箱禁止执行 setuid 的 /bin/ps（EPERM），
//   而 uibrowser.js 的属主核验依赖 `ps -p PID -o uid=,ppid=,comm=`。脚本启动时先探测真 ps；
//   不可用时往 PATH 前置一个**只实现这一种调用形式**的垫片，三项事实（uid / ppid / 可执行文件
//   真实路径的 basename）全部取自 lsof ⟹ 核验语义与 ps 相同（comm 甚至更准：取真实 exec 路径）。
//   真 ps 可用时不创建任何垫片，行为与 check_111_peq_drag.js 完全一致。
//
// 用法：node tools/check_111_peq_smooth.js [--binary build-mac/rtaweb] [--keep]
// 退出码：0 = 全部判据绿；1 = 有红判据（当前代码的预期状态）或测量无效；3 = 超时。
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), net = require('net');
const { spawn, execFileSync } = require('child_process');

const args = process.argv.slice(2);
const argOf = (n, d) => { const i = args.indexOf(n); return i !== -1 && i + 1 < args.length ? args[i + 1] : d; };
const REPO = path.resolve(__dirname, '..');
const binary = path.resolve(argOf('--binary', path.join(REPO, 'build-mac', 'rtaweb')));
const PORT = 19106;          // 铁律：rtaweb 只用 19106
const CDP_PORT = 9713;       // 铁律：CDP 只用 9713 / 9714
const BUDGET_MS = 175000;    // 整体 ≤180s
const MOVES = 120;           // 拖拽事件数
const STEP_MS = 8;           // ~120Hz
const STEP_PX = 8;           // 每次 8 CSS px

let STEP = 'startup';
const step = (s) => { STEP = s; console.log('\n== ' + s + ' =='); };
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- 沙箱适配：ps 垫片
// 只覆盖 uibrowser.js / 本脚本实际使用的 `ps -p PID -o uid=,ppid=,comm=` 一种形式。
const PS_SHIM = `#!/bin/sh
# 垫片：本机沙箱禁止执行 setuid 的 /bin/ps（EPERM）。三项事实全部取自 lsof：
#   u<uid> / R<ppid> / n<可执行文件真实路径>（basename 即 comm）。
pid=""; fmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) pid="$2"; shift 2 ;;
    -o) fmt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$pid" ] || exit 1
out=$(/usr/sbin/lsof -nP -p "$pid" -a -d txt -F pRucn 2>/dev/null) || exit 1
[ -n "$out" ] || exit 1
uid=$(printf '%s\\n' "$out" | sed -n 's/^u//p' | head -1)
ppid=$(printf '%s\\n' "$out" | sed -n 's/^R//p' | head -1)
cmd=$(printf '%s\\n' "$out" | sed -n 's/^c//p' | head -1)
exe=$(printf '%s\\n' "$out" | sed -n 's/^n//p' | head -1)
[ -n "$uid" ] && [ -n "$ppid" ] || exit 1
base=$(basename "$exe" 2>/dev/null)
[ -n "$base" ] || base="$cmd"
[ -n "$base" ] || exit 1
printf '%s %s %s\\n' "$uid" "$ppid" "$base"
`;

function psFieldMode() {
  try {
    const out = execFileSync('ps', ['-p', String(process.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
    const m = out.match(/^(\d+)\s+(\d+)\s+(.+)$/);
    if (m && +m[1] === process.getuid() && +m[2] === process.ppid) return 'ps';
  } catch (e) { /* 真 ps 不可用 */ }
  return null;
}

function installPsShim(root) {
  const dir = path.join(root, 'shim');
  fs.mkdirSync(dir, { recursive: true });
  const f = path.join(dir, 'ps');
  fs.writeFileSync(f, PS_SHIM, { mode: 0o755 });
  process.env.PATH = dir + ':' + (process.env.PATH || '');
  const out = execFileSync('ps', ['-p', String(process.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
  const m = out.match(/^(\d+)\s+(\d+)\s+(.+)$/);
  if (!m || +m[1] !== process.getuid() || +m[2] !== process.ppid) throw Error('ps 垫片自检失败: ' + JSON.stringify(out));
  return 'lsof-shim';
}

// 属主核验：uid == 我们、ppid == 我们、comm basename == 预期。任何一项不符就**不发信号**。
function ownedByUs(pid, expectComm) {
  const out = execFileSync('ps', ['-p', String(pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
  const m = out.match(/^(\d+)\s+(\d+)\s+(.+)$/);
  if (!m) return { ok: false, raw: out, why: 'ps 输出无法解析' };
  const uid = +m[1], ppid = +m[2], comm = m[3];
  const why = [];
  if (uid !== process.getuid()) why.push('uid ' + uid + ' != ' + process.getuid());
  if (ppid !== process.pid) why.push('ppid ' + ppid + ' != ' + process.pid);
  if (path.basename(comm) !== expectComm) why.push('comm ' + JSON.stringify(path.basename(comm)) + ' != ' + JSON.stringify(expectComm));
  return { ok: why.length === 0, raw: out, why: why.join(', ') };
}

function alive(pid) { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } }

// ---------------------------------------------------------------- 页面内探针
// 不改产品源码：只包装全局函数 + 加 listener，全部只在 Node 侧注入。
const PROBE_JS = `(function () {
  if (window.__PEQP && window.__PEQP.v === 1) return 'reused';
  var P = window.__PEQP = {
    v: 1, running: false, frames: [], moves: [], longtasks: [], drawLog: [], samples: [],
    sampling: false, rec: {}, inMove: false, rafId: 0, po: null, t0: 0, t1: 0,
    ltSupported: null, ltErr: null, wrapped: []
  };
  P.countersReset = function () {
    P.frames = []; P.moves = []; P.longtasks = []; P.drawLog = []; P.samples = [];
    for (var k in P.rec) { P.rec[k].n = 0; P.rec[k].total = 0; P.rec[k].max = 0; }
  };
  // 计时包装：只统计被测窗口内的 inclusive 耗时。
  // 注意 peqDrawCurve 内部会再调 peqSyncNodes ⟹ 两者会重复计数，报告里已注明。
  P.wrap = function (name) {
    var orig = window[name];
    if (typeof orig !== 'function') return false;
    var r = P.rec[name] = { n: 0, total: 0, max: 0 };
    window[name] = function () {
      if (!P.running) return orig.apply(this, arguments);
      var t0 = performance.now(), ret;
      try {
        ret = orig.apply(this, arguments);
      } finally {
        var dt = performance.now() - t0;
        r.n++; r.total += dt; if (dt > r.max) r.max = dt;
        if (name === 'peqDrawCurve') P.drawLog.push([t0, dt, P.inMove ? 'move' : 'async']);
      }
      return ret;
    };
    P.wrapped.push(name);
    return true;
  };
  P.init = function () {
    P.wrap('peqDrawCurve');
    P.wrap('peqSyncNodes');
    P.wrap('peqTipAt');
    try {
      P.po = new PerformanceObserver(function (list) {
        var es = list.getEntries();
        for (var i = 0; i < es.length; i++) P.longtasks.push([es[i].startTime, es[i].duration]);
      });
      P.po.observe({ entryTypes: ['longtask'] });
      P.ltSupported = true;
    } catch (e) { P.ltSupported = false; P.ltErr = String(e); }
    // capture + passive：只读时间戳，不干扰产品逻辑，也不会被 preventDefault 影响
    window.addEventListener('pointermove', function () {
      if (!P.running) return;
      P.moves.push(performance.now());
      // 同一个输入任务内的 peqDrawCurve 才算「拖拽同步路径」；跨任务（fetch 回调）归 async
      if (!P.inMove) { P.inMove = true; setTimeout(function () { P.inMove = false; }, 0); }
      // 放到 microtask：当前任务的 listener 全部跑完（含产品 peqSyncNodes）再读，
      // 读到的才是"这一帧准备画的样子"。在 handler 之前读会白差一步（8px）。
      if (P.sampling) queueMicrotask(function () { if (P.running) P.samples.push(P.sample()); });
    }, { capture: true, passive: true });
    return true;
  };
  P.start = function () {
    P.countersReset(); P.running = true;
    P.t0 = performance.now();
    var tick = function (t) {
      if (!P.running) return;
      P.frames.push(t);
      P.rafId = requestAnimationFrame(tick);
    };
    P.rafId = requestAnimationFrame(tick);
    return P.t0;
  };
  P.stop = function () {
    P.running = false;
    try { cancelAnimationFrame(P.rafId); } catch (e) { }
    P.rafId = 0;
    P.t1 = performance.now();
    return P.t1;
  };
  // 一个采样：节点圆位置 vs **画出来的**频响曲线在该 x 处的 y。
  // 拖拽时节点圆立刻动，但 polyline 只在 peqDrawCurve（扩量程 / 后端返回）时才重画 ⟹
  // 两者差值就是「曲线不跟手」的像素证据。
  P.sample = function () {
    var svg = document.querySelector('#peqCurve svg.peqsvg');
    if (!svg) return null;
    var c = svg.querySelector('.peqnode[data-i="1"]');
    var pl = svg.querySelector('.peqline');
    var tr = document.querySelector('#peqRows .peqr[data-i="1"] .peqG');
    var cy = c ? +c.getAttribute('cy') : null;
    var cx = c ? +c.getAttribute('cx') : null;
    var curveY = null;
    if (pl && cx !== null) {
      var pts = (pl.getAttribute('points') || '').trim().split(/\\s+/);
      for (var i = 1; i < pts.length; i++) {
        var a = pts[i - 1].split(','), b = pts[i].split(',');
        var ax = +a[0], ay = +a[1], bx = +b[0], by = +b[1];
        if (cx >= ax && cx <= bx) { curveY = (bx > ax) ? ay + (by - ay) * (cx - ax) / (bx - ax) : ay; break; }
      }
    }
    return {
      cy: cy, cx: cx, curveY: curveY === null ? null : +curveY.toFixed(2),
      lagPx: (cy === null || curveY === null) ? null : +(curveY - cy).toFixed(2),
      gain: tr ? +tr.value : null
    };
  };
  P.snap = function () {
    var tr = document.querySelector('#peqRows .peqr[data-i="1"]');
    var c = document.querySelector('#peqCurve .peqnode[data-i="1"]');
    var v = window.PEQ_VIEW, h = window.PEQ_VIEW_HINT;
    return {
      view: v ? { W: v.W, H: v.H, maxDb: v.maxDb, minDb: v.minDb } : null,
      hintOn: !!h,
      hint: h ? { maxDb: h.maxDb, minDb: h.minDb } : null,
      drag: !!window.PEQ_DRAG,
      gain: (tr && tr.querySelector('.peqG')) ? +tr.querySelector('.peqG').value : null,
      nodeCy: c ? +c.getAttribute('cy') : null,
      nodeCx: c ? +c.getAttribute('cx') : null,
      nodeCyPx: c ? +c.getBoundingClientRect().top.toFixed(2) : null
    };
  };
  P.report = function () {
    var t0 = P.t0, t1 = P.t1 || performance.now(), i, j;
    var rs = function (x) { return Math.round(x * 100) / 100; };
    var f = [];
    for (i = 0; i < P.frames.length; i++) if (P.frames[i] >= t0 - 0.5 && P.frames[i] <= t1 + 1) f.push(P.frames[i]);
    var d = [];
    for (i = 1; i < f.length; i++) d.push(f[i] - f[i - 1]);
    var stat = function (a) {
      var b = a.slice().sort(function (x, y) { return x - y; });
      var q = function (p) { if (!b.length) return 0; var k = Math.ceil(p * b.length) - 1; if (k < 0) k = 0; if (k > b.length - 1) k = b.length - 1; return b[k]; };
      var s = 0; for (var m = 0; m < b.length; m++) s += b[m];
      return { n: b.length, mean: b.length ? s / b.length : 0, p50: q(.5), p95: q(.95), p99: q(.99), max: b.length ? b[b.length - 1] : 0 };
    };
    var fd = stat(d);
    var drop25 = 0, drop33 = 0, drop50 = 0;
    for (i = 0; i < d.length; i++) { if (d[i] > 25) drop25++; if (d[i] > 33.4) drop33++; if (d[i] > 50) drop50++; }
    var lt = [];
    for (i = 0; i < P.longtasks.length; i++) if (P.longtasks[i][0] >= t0 && P.longtasks[i][0] <= t1) lt.push(P.longtasks[i]);
    var ltTotal = 0, ltMax = 0;
    for (i = 0; i < lt.length; i++) { ltTotal += lt[i][1]; if (lt[i][1] > ltMax) ltMax = lt[i][1]; }
    var mv = [];
    for (i = 0; i < P.moves.length; i++) if (P.moves[i] >= t0 - 0.5 && P.moves[i] <= t1 + 1) mv.push(P.moves[i]);
    var lat = [], gaps = [], lo = 0;
    for (i = 0; i < mv.length; i++) {
      if (i > 0) gaps.push(mv[i] - mv[i - 1]);
      while (lo < f.length && f[lo] < mv[i]) lo++;
      if (lo < f.length) lat.push(f[lo] - mv[i]);
    }
    var ls = stat(lat), gs = stat(gaps);
    // 每帧到达的 move 数：>1 说明输入在主线程排队（积压指标）
    var perFrame = [], k = 0, pfMax = 0, pfSum = 0;
    for (i = 1; i < f.length; i++) {
      var c = 0;
      while (k < mv.length && mv[k] <= f[i]) { if (mv[k] > f[i - 1]) c++; k++; }
      perFrame.push(c); pfSum += c; if (c > pfMax) pfMax = c;
    }
    var dl = [];
    for (i = 0; i < P.drawLog.length; i++) if (P.drawLog[i][0] >= t0 && P.drawLog[i][0] <= t1) dl.push(P.drawLog[i]);
    var mvDraw = [], asDraw = [];
    for (i = 0; i < dl.length; i++) (dl[i][2] === 'move' ? mvDraw : asDraw).push(dl[i][1]);
    var st2 = function (a) { var s = stat(a); return { n: s.n, mean: rs(s.mean), max: rs(s.max), sum: rs(a.reduce(function (x, y) { return x + y; }, 0)) }; };
    var withDraw = [], noDraw = [];
    for (i = 1; i < f.length; i++) {
      var has = false;
      for (j = 0; j < dl.length; j++) if (dl[j][0] > f[i - 1] && dl[j][0] <= f[i]) { has = true; break; }
      (has ? withDraw : noDraw).push(d[i - 1]);
    }
    var rec = {};
    for (var name in P.rec) {
      var r = P.rec[name];
      rec[name] = { n: r.n, mean: r.n ? rs(r.total / r.n) : 0, max: rs(r.max), total: rs(r.total) };
    }
    return {
      windowMs: rs(t1 - t0),
      frameCount: f.length,
      fps: rs(d.length ? 1000 * d.length / (t1 - t0) : 0),
      frameMean: rs(fd.mean), frameP50: rs(fd.p50), frameP95: rs(fd.p95), frameP99: rs(fd.p99), frameMax: rs(fd.max),
      drop25: drop25, drop33: drop33, drop50: drop50,
      ltSupported: P.ltSupported, ltCount: lt.length, ltTotalMs: rs(ltTotal), ltMaxMs: rs(ltMax),
      movesDelivered: mv.length, moveLatMean: rs(ls.mean), moveLatP95: rs(ls.p95), moveLatMax: rs(ls.max),
      moveGapMean: rs(gs.mean), moveGapMax: rs(gs.max),
      movesPerFrameMax: pfMax, movesPerFrameMean: rs(perFrame.length ? pfSum / perFrame.length : 0),
      redrawMoveCount: mvDraw.length, redrawMove: st2(mvDraw),
      redrawAsyncCount: asDraw.length, redrawAsync: st2(asDraw),
      frameWithRedraw: st2(withDraw), frameNoRedraw: st2(noDraw),
      samples: P.samples, rec: rec
    };
  };
  // 定义完立刻 install：计时包装、pointermove listener、longtask observer 都在 init 里
  P.init();
  return 'ok';
})()`;
// 启动/停止包装：report 前必须先 stop，否则 rAF 循环会被下一次 start 叠加成 2 个、3 个…
// （实测：不 stop 时帧序列出现两条交织的 rAF 流，fps 从 58 变成 118/178/237，均值全失真。）
const START = 'window.__PEQP.start()';
const STOP = 'window.__PEQP.stop()';

// 判别力自检（canary）：在 pointermove 上故意阻塞主线程 70ms/次（每 6 拍一次）。
// 目的不是测产品，而是**证明这套探针真能看见卡顿** —— 如果人为 70ms 阻塞都量不出来，
// 那么"量出来是绿的"就只是探针瞎了（铁律 3）。
const CANARY_JS = `(function () {
  var C = window.__PEQCANARY = { on: false, every: 6, spin: 70, n: 0, hits: 0, blocked: 0 };
  window.addEventListener('pointermove', function () {
    if (!C.on) return;
    if (++C.n % C.every !== 0) return;
    var t0 = performance.now(), t = t0;
    while (t - t0 < C.spin) { t = performance.now(); }
    C.hits++; C.blocked += t - t0;
  }, { capture: true, passive: true });
  return 'ok';
})()`;

// 兜底输入模式（CDP 输入被拒时才用）：合成 PointerEvent。target 必须是节点本身，
// 否则 peqBindCurve 的 pick() 找不到 data-i 就直接 return。
const SYN_INIT = `window.__PEQSYN = function (type, x, y) {
  var svg = document.querySelector('#peqCurve svg.peqsvg');
  if (!svg) return 'no-svg';
  var tgt = svg;
  if (type === 'pointerdown') {
    tgt = document.querySelector('#peqCurve circle.peqhit[data-i="1"]') ||
          document.querySelector('#peqCurve circle.peqnode[data-i="1"]');
    if (!tgt) return 'no-node';
  }
  tgt.dispatchEvent(new PointerEvent(type, {
    clientX: x, clientY: y, bubbles: true, cancelable: true,
    pointerId: 1, isPrimary: true, pointerType: 'mouse',
    buttons: type === 'pointerup' ? 0 : 1
  }));
  return 'ok';
}; 'ok'`;

// ---------------------------------------------------------------- 主流程
let child = null, ub = null, session = null, root = null, psMode = 'ps', hasHintPath = false;
let serverOut = '';
const results = [];
const ck = (ok, name, data) => {
  results.push({ ok: !!ok, name, data });
  console.log((ok ? '  PASS ' : '  FAIL ') + name + (data === undefined ? '' : ' ' + JSON.stringify(data)));
};

function listenPids(port) {
  const lsof = fs.existsSync('/usr/sbin/lsof') ? '/usr/sbin/lsof' : 'lsof';
  let out;
  try { out = execFileSync(lsof, ['-nP', '-a', '-iTCP:' + port, '-sTCP:LISTEN', '-Fp'], { encoding: 'utf8' }); }
  catch (e) { if (e.status === 1 && !e.stdout) return []; throw e; }
  return (out || '').split('\n').map((l) => l.trim()).filter((l) => /^p\d+$/.test(l)).map((l) => +l.slice(1));
}

function emergencyTeardown(why) {
  console.error('[EMERGENCY] ' + why + (root ? '（临时目录保留: ' + root + '）' : ''));
  try {
    if (ub && session && session.pid && alive(session.pid)) {
      const lp = listenPids(CDP_PORT);
      if (lp.length === 1 && lp[0] === session.pid) { console.error('[EMERGENCY] SIGTERM edge pid=' + session.pid); process.kill(session.pid, 'SIGTERM'); }
      else console.error('[EMERGENCY] edge 端口属主可疑，不发信号: ' + JSON.stringify(lp));
    }
  } catch (e) { console.error('[EMERGENCY] edge: ' + e.message); }
  try {
    if (child && child.exitCode === null && alive(child.pid)) {
      const v = ownedByUs(child.pid, path.basename(binary));
      if (v.ok) { console.error('[EMERGENCY] SIGTERM rtaweb pid=' + child.pid); child.kill('SIGTERM'); }
      else console.error('[EMERGENCY] rtaweb 属主可疑，不发信号: ' + v.why + ' | ' + v.raw);
    }
  } catch (e) { console.error('[EMERGENCY] rtaweb: ' + e.message); }
}

const watchdog = setTimeout(() => {
  console.error('\n[TIMEOUT] 卡在步骤「' + STEP + '」，已超过 ' + BUDGET_MS + 'ms，退出');
  emergencyTeardown('watchdog');
  process.exit(3);
}, BUDGET_MS);

async function teardown() {
  STEP = 'teardown';
  console.log('\n== teardown ==');
  const notes = [];
  if (session) {
    try { await session.close(); notes.push('Edge 已关闭（uibrowser 内部 SIGTERM + 清 profile）'); }
    catch (e) {
      notes.push('uibrowser close 抛错: ' + e.message + ' ⟹ 改用端口属主核验后自行 SIGTERM');
      try {
        const lp = listenPids(CDP_PORT);
        if (lp.length === 1 && lp[0] === session.pid) {
          process.kill(session.pid, 'SIGTERM');
          for (let i = 0; i < 50 && alive(session.pid); i++) await pause(100);
          notes.push('Edge pid=' + session.pid + ' TERM 后存活=' + alive(session.pid));
        } else notes.push('Edge 端口属主可疑，不发信号: ' + JSON.stringify(lp));
      } catch (e2) { notes.push('Edge 兜底失败: ' + e2.message); }
    }
    session = null;
  }
  if (child && child.exitCode === null) {
    try {
      const v = ownedByUs(child.pid, path.basename(binary));
      console.log('  属主核验[' + psMode + ']: ' + JSON.stringify(v.raw) + (v.ok ? '  OK' : '  MISMATCH ' + v.why));
      if (v.ok) {
        child.kill('SIGTERM');
        await Promise.race([new Promise((r) => child.once('exit', r)), pause(10000)]);
        notes.push('rtaweb pid=' + child.pid + ' TERM 后存活=' + (child.exitCode === null));
      } else notes.push('rtaweb 属主不符，绝不发信号（交用户处理）: ' + v.raw);
    } catch (e) { notes.push('rtaweb 核验/停止失败: ' + e.message); }
  }
  const leftover = [];
  for (const [label, port] of [['rtaweb', PORT], ['cdp', CDP_PORT]]) {
    try { const lp = listenPids(port); if (lp.length) leftover.push(label + ':' + port + ' -> ' + JSON.stringify(lp)); } catch (e) { }
  }
  if (session && session.pid) { /* 已置空 */ }
  notes.push(leftover.length ? '⚠️ 端口仍有监听: ' + leftover.join(' | ') : '端口 ' + PORT + '/' + CDP_PORT + ' 已无监听');
  if (child && child.exitCode !== null) notes.push('rtaweb exitCode=' + child.exitCode);
  for (const n of notes) console.log('  ' + n);
  console.log('  临时目录: ' + root);
  if (args.includes('--keep')) console.log('  （--keep：保留临时目录供排查）');
  else { try { fs.rmSync(root, { recursive: true, force: true }); console.log('  已删除临时目录'); } catch (e) { console.log('  删除失败: ' + e.message); } }
  return notes;
}

// 拖动计划：返回 [{x,y}...]（client 坐标 = CSS px，相对视口左上）
function planZigzag(cx, cy, n, ampPx) {
  const out = [];
  let y = cy;
  for (let k = 0; k < n; k++) {
    const up = Math.floor(k / 4) % 2 === 0;          // 4 步向上、4 步向下 ⟹ 净位移 0，留在量程内
    y += up ? -ampPx : ampPx;
    out.push({ x: cx, y });
  }
  return out;
}

async function dispatchRun(session, plan, mode) {
  const errors = [];
  const t0 = Date.now();
  const jobs = [];
  let due = 0;
  for (let k = 0; k < plan.length; k++) {
    due += plan[k].wait === undefined ? STEP_MS : plan[k].wait;
    const wait = t0 + due - Date.now();
    if (wait > 0) await pause(wait);
    if (mode === 'cdp') {
      jobs.push(session.send('Input.dispatchMouseEvent', {
        type: 'mouseMoved', x: plan[k].x, y: plan[k].y, button: 'left', buttons: 1,
        pointerType: 'mouse',
      }).catch((e) => errors.push('move#' + k + ': ' + e.message)));
    } else {
      jobs.push(session.eval('__PEQSYN("pointermove",' + plan[k].x + ',' + plan[k].y + ')')
        .catch((e) => errors.push('move#' + k + ': ' + e.message)));
    }
  }
  await Promise.all(jobs);
  const wall = Date.now() - t0;
  return { wall, errors };
}

async function pressPoint(session, mode, x, y) {
  if (mode === 'cdp') {
    await session.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, pointerType: 'mouse' });
    await session.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1, pointerType: 'mouse' });
  } else {
    await session.eval('__PEQSYN("pointerdown",' + x + ',' + y + ')');
  }
}

async function releasePoint(session, mode, x, y) {
  if (mode === 'cdp') {
    await session.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1, pointerType: 'mouse' });
  } else {
    await session.eval('__PEQSYN("pointerup",' + x + ',' + y + ')');
  }
}

function fmt(r) {
  return '帧 ' + r.frameCount + ' / ' + r.windowMs + 'ms（' + r.fps + ' fps）| 均值 ' + r.frameMean +
    ' p95 ' + r.frameP95 + ' p99 ' + r.frameP99 + ' 最长 ' + r.frameMax +
    ' | 掉帧>25ms ' + r.drop25 + '（>33ms ' + r.drop33 + ' / >50ms ' + r.drop50 + '）' +
    ' | longtask ' + r.ltCount + ' 条/' + r.ltTotalMs + 'ms（最长 ' + r.ltMaxMs + 'ms）' +
    ' | move→帧 均 ' + r.moveLatMean + ' p95 ' + r.moveLatP95 + ' 最差 ' + r.moveLatMax + 'ms';
}

// 判据始终作用于 inrange（量程内）与 expand（扩量程）两组
const FOLLOW_CRIT = [
  { k: 'maxAbsLagPx', v: 4, op: '>', label: '拖拽时「曲线 vs 节点」最大脱节 > 4px（> 节点半径 ⟹ 肉眼可见不跟手）' },
];

const CRIT = [
  { k: 'frameP95', v: 25, op: '>', label: 'p95 帧时间 > 25ms（丢一个 60Hz vsync）' },
  { k: 'drop25', v: 10, op: '>', label: '掉帧数（>25ms）> 10' },
  { k: 'ltTotalMs', v: 100, op: '>', label: 'longtask 总时长 > 100ms' },
  { k: 'moveLatMax', v: 50, op: '>', label: 'pointermove 最差延迟 > 50ms' },
];

(async () => {
  try {
    // ---------------------------------------------------------- 0. 预检
    step('0 预检');
    if (!fs.existsSync(binary)) throw Error('找不到 rtaweb: ' + binary);
    for (const p of [PORT, CDP_PORT]) {
      const lp = listenPids(p);
      if (lp.length) throw Error('端口 ' + p + ' 已被占用（' + JSON.stringify(lp) + '）；绝不复用他方进程');
    }
    console.log('  binary=' + binary + '  端口=' + PORT + '  CDP=' + CDP_PORT + '  node=' + process.version);

    // ---------------------------------------------------------- 1. 隔离环境
    step('1 隔离环境');
    root = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-peq-smooth-'));
    psMode = psFieldMode() || installPsShim(root);
    console.log('  属主核验通道: ' + psMode + (psMode === 'ps' ? '（真 ps）' : '（/bin/ps 被沙箱拒绝，改用 lsof 等价垫片）'));
    const env = {
      ...process.env,
      HOME: path.join(root, 'home'),
      RLPLAYER_STATE_DIR: path.join(root, 'state'),
      RLPLAYER_LIBRARY_DIR: path.join(root, 'lib'),
      RLPLAYER_COVER_DIR: path.join(root, 'covers'),
    };
    for (const k of ['HOME', 'RLPLAYER_STATE_DIR', 'RLPLAYER_LIBRARY_DIR', 'RLPLAYER_COVER_DIR']) fs.mkdirSync(env[k], { recursive: true });
    fs.mkdirSync(path.join(root, 'music'));
    fs.writeFileSync(path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-settings.conf'),
      'backend=null\nmetaon=0\nmetallm=0\nvolume=-120\ntheme=light\nuistyle=apple\nlang=zh\n');
    console.log('  临时目录 ' + root + '（backend=null ⟹ 绝不打开音频设备）');

    // ---------------------------------------------------------- 2. 起服务
    step('2 起 rtaweb（端口 ' + PORT + '）');
    child = spawn(binary, ['--port', String(PORT), '--music-dir', path.join(root, 'music')],
      { env, cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', (b) => { serverOut = (serverOut + b.toString()).slice(-4000); });
    child.stderr.on('data', (b) => { serverOut = (serverOut + b.toString()).slice(-4000); });
    let up = false;
    for (let i = 0; i < 150; i++) {
      try { const r = await fetch('http://127.0.0.1:' + PORT + '/api/ping'); if (r.ok) { up = true; break; } } catch (e) { }
      if (child.exitCode !== null) break;
      await pause(100);
    }
    if (!up) throw Error('rtaweb 没起来（exitCode=' + child.exitCode + '）\n' + serverOut.slice(-1200));
    console.log('  /api/ping OK');

    // ---------------------------------------------------------- 3. headless Edge
    step('3 headless Edge（CDP ' + CDP_PORT + '）');
    ub = require('./uibrowser');
    if (!ub.findEdge()) throw Error('找不到 Edge；可用 EDGE_PATH 指定');
    session = await ub.open({ url: 'http://127.0.0.1:' + PORT + '/', port: CDP_PORT, width: 1280, height: 900 });
    await session.waitFor("typeof peqDrawCurve==='function' && typeof PEQ_VIEW!=='undefined' && document.getElementById('bHelp')", 15000);
    await session.eval("openSettingsTab('eq')");
    if (!await session.waitFor("!!document.querySelector('#peqCurve svg.peqsvg .peqnode')", 10000))
      throw Error('PEQ 曲线没渲染出来');
    const hasHint = await session.eval("typeof PEQ_VIEW_HINT !== 'undefined'");
    hasHintPath = !!hasHint;
    ck(hasHint, '当前二进制含 PEQ_VIEW_HINT（扩量程分支存在）', hasHint);
    await pause(400);

    // ---------------------------------------------------------- 4. 注入探针
    step('4 注入性能探针');
    const inj = await session.eval(PROBE_JS);
    console.log('  probe: ' + inj);
    const canaryOk = await session.eval(CANARY_JS);
    console.log('  canary: ' + canaryOk + '（判别力自检用，默认关闭）');
    const wrappedNames = await session.eval('window.__PEQP.wrapped');
    console.log('  已计时包装: ' + JSON.stringify(wrappedNames));
    ck(wrappedNames && wrappedNames.indexOf('peqDrawCurve') !== -1, 'peqDrawCurve 已被探针包装（扩量程重绘可计数）', wrappedNames);

    // ---------------------------------------------------------- 5. 定位拖拽点
    step('5 定位节点（滚到视口内 + elementFromPoint 校验）');
    await session.eval("(function(){var s=document.querySelector('#peqCurve svg.peqsvg'); if(s) s.scrollIntoView({block:'center',inline:'center'}); return 1;})()");
    await pause(250);
    const geo = await session.eval(`(function () {
      var svg = document.querySelector('#peqCurve svg.peqsvg');
      var node = svg.querySelector('.peqhit[data-i="1"]') || svg.querySelector('.peqnode[data-i="1"]');
      var r = svg.getBoundingClientRect(), vb = svg.viewBox.baseVal;
      var cx = r.left + (+node.getAttribute('cx')) / vb.width * r.width;
      var cy = r.top + (+node.getAttribute('cy')) / vb.height * r.height;
      var el = document.elementFromPoint(cx, cy);
      return {
        rect: { left: +r.left.toFixed(1), top: +r.top.toFixed(1), w: +r.width.toFixed(1), h: +r.height.toFixed(1) },
        viewBox: { w: vb.width, h: vb.height },
        point: { x: +cx.toFixed(2), y: +cy.toFixed(2) },
        vp: { w: innerWidth, h: innerHeight },
        hitEl: el ? (el.tagName + '.' + (el.getAttribute('class') || '') + '[data-i=' + (el.dataset ? el.dataset.i : '') + ']') : 'null',
        hitOk: !!(el && el.closest && el.closest('svg.peqsvg') && (el.classList.contains('peqhit') || el.classList.contains('peqnode'))),
        snap: window.__PEQP.snap()
      };
    })()`);
    console.log('  ' + JSON.stringify(geo));
    ck(geo.hitOk, '节点中心点命中真实 SVG 节点（输入坐标有效）', geo.hitEl);
    ck(geo.snap.view && geo.snap.view.maxDb - geo.snap.view.minDb > 0, 'PEQ_VIEW 量程已建立', geo.snap.view);
    ck(geo.rect.h > 60 && geo.point.y > 20 && geo.point.y < geo.vp.h - 20, '拖拽起点在视口内', { rect: geo.rect, point: geo.point, vp: geo.vp });
    const P0 = geo.point;

    // 输入模式：先试 CDP 真输入，失败再退合成事件（并明确标注）
    let mode = 'cdp';
    step('6 输入通道自检');
    await pause(500);
    await pressPoint(session, mode, P0.x, P0.y);
    await pause(60);
    let down = await session.eval('!!(window.PEQ_DRAG)');
    if (!down) {
      await releasePoint(session, mode, P0.x, P0.y);
      console.log('  CDP mousePressed 未建立拖拽，改合成 PointerEvent 兜底');
      await session.eval(SYN_INIT);
      mode = 'synthetic';
      await pause(700);
      await pressPoint(session, mode, P0.x, P0.y);
      await pause(60);
      down = await session.eval('!!(window.PEQ_DRAG)');
    }
    ck(down, 'pointerdown 真的进入了拖拽态（PEQ_DRAG != null）', { mode });
    if (!down) throw Error('两种输入方式都没能触发拖拽；页面状态: ' + JSON.stringify(await session.eval('window.__PEQP.snap()')));
    await releasePoint(session, mode, P0.x, P0.y);
    await pause(500);

    // ---------------------------------------------------------- 7~10. 四组测量
    const runs = {};
    async function measure(tag, plan, opts) {
      const before = await session.eval('window.__PEQP.snap()');
      await session.eval(START);
      await pause(40);                       // 让首帧落下来
      await pressPoint(session, mode, P0.x, P0.y);
      await pause(30);
      const dragging = await session.eval('!!(window.PEQ_DRAG)');
      // 按下前的 hover 移动不算拖拽事件：清掉，让 delivered 与 dispatched 一一对应
      await session.eval('(window.__PEQP.moves.length = 0)');
      if (opts.canary) await session.eval('(window.__PEQCANARY.on = true, window.__PEQCANARY.n = 0, window.__PEQCANARY.hits = 0, window.__PEQCANARY.blocked = 0)');
      let disp = { wall: 0, errors: [] };
      if (plan.length) disp = await dispatchRun(session, plan, mode);
      let canaryStat = null;
      if (opts.canary) canaryStat = await session.eval('(window.__PEQCANARY.on = false, { n: __PEQCANARY.n, hits: __PEQCANARY.hits, blocked: +__PEQCANARY.blocked.toFixed(1) })');
      await pause(opts.tailMs);
      await session.eval(STOP);              // 必须先停 rAF 循环再取报告
      await pause(140);                      // 让 PerformanceObserver 把尾部 longtask 送达
      const rep = await session.eval('window.__PEQP.report()');
      const atStop = await session.eval('window.__PEQP.snap()');
      rep.dispatched = plan.length;
      rep.sendWallMs = disp.wall;
      rep.sendErrors = disp.errors.slice(0, 3);
      rep.dragging = dragging;
      rep.canary = canaryStat;
      rep.snapBefore = before;
      rep.snapAtStop = atStop;
      // 松手前记录，再松手看重绘/量程回落的视觉跳变
      await releasePoint(session, mode, P0.x, plan.length ? plan[plan.length - 1].y : P0.y);
      await pause(opts.settleMs);
      rep.snapAfter = await session.eval('window.__PEQP.snap()');
      rep.tag = tag;
      runs[tag] = rep;
      console.log('  [' + tag + '] ' + fmt(rep));
      console.log('        delivered ' + rep.movesDelivered + '/' + rep.dispatched + '  move 间隔均 ' + rep.moveGapMean +
        '/最长 ' + rep.moveGapMax + 'ms  move/帧 最多 ' + rep.movesPerFrameMax +
        '  重绘(move) ' + rep.redrawMoveCount + ' 次 均 ' + rep.redrawMove.mean + '/最长 ' + rep.redrawMove.max + 'ms' +
        '  重绘(async) ' + rep.redrawAsyncCount + ' 次');
      if (canaryStat) console.log('        canary 注入 70ms×' + canaryStat.hits + ' 次（共阻塞 ' + canaryStat.blocked + 'ms，pointermove 计数 ' + canaryStat.n + '）');
      console.log('        包装耗时/次: ' + JSON.stringify(rep.rec));
      console.log('        量程 before=' + JSON.stringify(before.view) + ' atStop=' + JSON.stringify(atStop.view) +
        ' after=' + JSON.stringify(rep.snapAfter.view));
      console.log('        增益 before=' + before.gain + ' atStop=' + atStop.gain + ' after=' + rep.snapAfter.gain +
        '  node cy: ' + before.nodeCy + ' → ' + atStop.nodeCy + ' → ' + rep.snapAfter.nodeCy);
      return rep;
    }

    step('7 ① idle 基线（不拖）');
    await session.eval(START);
    await pause(700);
    await session.eval(STOP);
    await pause(140);
    const idle = await session.eval('window.__PEQP.report()');
    runs.idle = idle;
    console.log('  [idle] ' + fmt(idle));
    ck(idle.frameCount > 20, 'idle 基线采到足够帧（rAF 正常跳动）', { frames: idle.frameCount, windowMs: idle.windowMs });

    step('8 ⓪ canary：人为在 pointermove 上阻塞 70ms（证明探针有判别力，不计入产品判据）');
    await measure('canary', planZigzag(P0.x, P0.y, MOVES, STEP_PX), { tailMs: 200, settleMs: 500, canary: true });
    await session.eval('peqResetBand(1)'); await pause(500);

    step('9 ② inrange 量程内锯齿拖拽');
    const zig = planZigzag(P0.x, P0.y, MOVES, STEP_PX);
    await measure('inrange', zig, { tailMs: 160, settleMs: 320 });
    await session.eval('peqResetBand(1)'); await pause(600);

    step('10 ③ expand 超出量程（+24 → −24，触发扩量程重绘）');
    // 40 步向上（8px/步）把增益推到 +24，再 80 步向下压到 −24；
    // 每跨一次 3dB 量化边界就触发一次 PEQ_VIEW_HINT 扩量程 + peqDrawCurve 整块重绘。
    const exp = [];
    let y = P0.y;
    for (let k = 0; k < 40; k++) { y -= STEP_PX; exp.push({ x: P0.x, y }); }
    for (let k = 0; k < 80; k++) { y += STEP_PX; exp.push({ x: P0.x, y }); }
    await measure('expand', exp, { tailMs: 160, settleMs: 480 });
    const expandJump = runs.expand && runs.expand.snapAfter && runs.expand.snapAtStop
      ? { cyBefore: runs.expand.snapAtStop.nodeCy, cyAfter: runs.expand.snapAfter.nodeCy,
          gainBefore: runs.expand.snapAtStop.gain, gainAfter: runs.expand.snapAfter.gain,
          viewBefore: runs.expand.snapAtStop.view, viewAfter: runs.expand.snapAfter.view } : null;
    console.log('  松手后量程回落/节点跳变: ' + JSON.stringify(expandJump));
    await session.eval('peqResetBand(1)'); await pause(600);

    step('11 ④ inrange2 复测（稳定性）');
    const zig2 = planZigzag(P0.x, P0.y, MOVES, STEP_PX);
    await measure('inrange2', zig2, { tailMs: 160, settleMs: 320 });
    await session.eval('peqResetBand(1)'); await pause(500);

    step('11a ⑥ paused 真人节奏拖拽（每 4 拍停 140ms ⟹ 拖拽期间真的会打后端 + 整块重绘）');
    // 连续 8ms 拖拽下 peqScheduleApply(100) 被每次 pointermove 重置 ⟹ 全程一次后端都不打
    // （实测 inrange 组重绘(async) 只有 1 次，还是松手之后）。真人拖拽必然有 >100ms 的停顿，
    // 这时才会真的走 api('/api/peq') → peqDrawCurve 整块重绘。这组就是量它的代价。
    const paused = [];
    let py = P0.y;
    for (let b = 0; b < 10; b++) {
      for (let k = 0; k < 4; k++) {
        py += (b % 2 === 0 ? -1 : 1) * STEP_PX;
        paused.push({ x: P0.x, y: py, wait: (k === 0 && b > 0) ? 140 : STEP_MS });
      }
    }
    await measure('paused', paused, { tailMs: 260, settleMs: 420 });
    await session.eval('peqResetBand(1)'); await pause(500);

    step('11b ⑤ follow 拖拽时「画出来的曲线」是否跟手（诊断项，不计入帧时间判据）');
    // 拖拽期间 peqSyncNodes() 只动节点圆，polyline 只在 peqDrawCurve 里改 ⟹ 量程内拖拽时
    // 曲线根本不会动。这里把「节点圆 cy」和「曲线在该 x 的 y」逐次采样，差值就是肉眼看到的脱节。
    await session.eval('window.__PEQP.sampling = true');
    const followPlan = planZigzag(P0.x, P0.y, 24, STEP_PX);
    await measure('follow', followPlan, { tailMs: 220, settleMs: 620 });
    await session.eval('window.__PEQP.sampling = false');
    const followAfter = await session.eval('window.__PEQP.sample()');
    console.log('  [采样样例] 前两笔: ' + await session.eval(
      'JSON.stringify((window.__PEQP.samples || []).slice(0, 2)) + " | peqline=" + (function(){var p=document.querySelector("#peqCurve polyline.peqline"); return p ? ("pointsLen=" + (p.getAttribute("points")||"").length + " first=" + ((p.getAttribute("points")||"").split(/\\s+/)[0])) : "NULL";})()'));
    const fS = (runs.follow.samples || []).filter((x) => x && x.lagPx !== null);
    const follow = {
      samples: fS.length,
      maxAbsLagPx: fS.length ? Math.max.apply(null, fS.map((x) => Math.abs(x.lagPx))) : null,
      lagAtMaxGain: fS.length ? fS.slice().sort((a, b) => Math.abs(b.gain || 0) - Math.abs(a.gain || 0))[0] : null,
      afterReleaseLagPx: followAfter ? followAfter.lagPx : null,
      afterReleaseGain: followAfter ? followAfter.gain : null,
    };
    console.log('  曲线跟手诊断: 采样 ' + follow.samples + ' 次，最大脱节 ' + follow.maxAbsLagPx + 'px；' +
      '增益最大时 ' + JSON.stringify(follow.lagAtMaxGain) + '；松手后 ' + JSON.stringify({ lagPx: follow.afterReleaseLagPx, gain: follow.afterReleaseGain }));
    await session.eval('peqResetBand(1)'); await pause(400);

    // ---------------------------------------------------------- 11. 判据
    step('12 判据（初筛阈值，按实测再定）');
    let red = false;
    const verdicts = {};
    for (const tag of ['inrange', 'expand', 'inrange2']) {
      const r = runs[tag];
      const v = { red: false, hits: [] };
      for (const c of CRIT) {
        const val = r[c.k];
        const hit = c.op === '>' ? val > c.v : val < c.v;
        if (hit) { v.red = true; v.hits.push({ key: c.k, val, thr: c.v, label: c.label }); }
        console.log('  ' + (hit ? 'RED  ' : 'green') + ' [' + tag + '] ' + c.label + '  → 实测 ' + val);
      }
      v.red && (red = true);
      verdicts[tag] = v;
    }
    const redFrame = red;
    // 曲线跟手判据（独立于帧时间）：节点半径 4.5px，脱节 > 4px 就是肉眼可见的"不跟手"
    const vFollow = { red: false, hits: [] };
    for (const c of FOLLOW_CRIT) {
      const val = follow[c.k];
      const hit = val !== null && (c.op === '>' ? val > c.v : val < c.v);
      if (hit) { vFollow.red = true; vFollow.hits.push({ key: c.k, val, thr: c.v, label: c.label }); }
      console.log('  ' + (hit ? 'RED  ' : 'green') + ' [follow] ' + c.label + '  → 实测 ' + val + 'px');
    }
    verdicts.follow = vFollow;
    const redFollow = vFollow.red;
    red = redFrame || redFollow;
    // 有效性闸门：数据不可用就不是"红"，是"无效"
    const invalid = [];
    for (const tag of ['inrange', 'expand', 'inrange2']) {
      const r = runs[tag];
      if (!r.dragging) invalid.push(tag + ': 拖拽态未建立');
      if (r.movesDelivered < MOVES * 0.9) invalid.push(tag + ': 只送达 ' + r.movesDelivered + '/' + MOVES + ' 个 pointermove');
      if (r.frameCount < 40) invalid.push(tag + ': 帧数只有 ' + r.frameCount);
    }
    if (runs.inrange.redrawMoveCount !== 0) invalid.push('inrange 组发生了 ' + runs.inrange.redrawMoveCount + ' 次拖拽内重绘（量程内不该扩量程，测量不纯）');
    if (runs.inrange2.redrawMoveCount !== 0) invalid.push('inrange2 组发生了 ' + runs.inrange2.redrawMoveCount + ' 次拖拽内重绘');
    if (!hasHintPath) invalid.push('二进制不含 PEQ_VIEW_HINT（扩量程分支不存在）⟹ ③ 组无效，需重建 build-mac/rtaweb');
    if (runs.expand.redrawMoveCount < 3) invalid.push('expand 组只触发 ' + runs.expand.redrawMoveCount + ' 次扩量程重绘（<3）⟹ 与量程内组没有可比性');
    if (runs.follow && runs.follow.samples && runs.follow.samples.length < 8) invalid.push('follow 组采样只有 ' + (runs.follow.samples || []).length + ' 次');
    // 判别力自检：人为 70ms×N 阻塞必须让四条判据里至少 3 条变红，否则探针是瞎的，绿不能当结论。
    const canaryHits = CRIT.filter((c) => (c.op === '>' ? runs.canary[c.k] > c.v : runs.canary[c.k] < c.v));
    ck(canaryHits.length >= 3, '判别力自检：人为 70ms 阻塞能让 ≥3 条判据变红（证明探针看得见卡顿）',
      { tripped: canaryHits.map((c) => c.k), canary: { p95: runs.canary.frameP95, drop25: runs.canary.drop25, ltTotalMs: runs.canary.ltTotalMs, moveLatMax: runs.canary.moveLatMax } });
    if (canaryHits.length < 3) invalid.push('canary 只让 ' + canaryHits.length + ' 条判据变红 ⟹ 探针判别力不足，本次绿结论无效');
    ck(!invalid.length, '测量有效性闸门', invalid.length ? invalid : 'all good');

    // ---------------------------------------------------------- 12. 汇总
    step('13 汇总');
    const row = (t) => {
      const r = runs[t];
      return '  ' + t.padEnd(9) + ' 帧 ' + String(r.frameCount).padStart(4) + '  ' + String(r.fps).padStart(6) + 'fps' +
        '  均 ' + String(r.frameMean).padStart(6) + 'ms  p95 ' + String(r.frameP95).padStart(6) +
        '  p99 ' + String(r.frameP99).padStart(6) + '  max ' + String(r.frameMax).padStart(7) +
        '  掉>25 ' + String(r.drop25).padStart(3) + '  LT ' + String(r.ltCount).padStart(2) + '/' + String(r.ltTotalMs).padStart(7) + 'ms' +
        '  move→帧 max ' + String(r.moveLatMax).padStart(6) + 'ms  重绘 ' + r.redrawMoveCount;
    };
    console.log(row('idle')); console.log(row('canary')); console.log(row('inrange')); console.log(row('expand')); console.log(row('inrange2')); console.log(row('paused')); console.log(row('follow'));
    const cmp = {
      canary_proves_sensitivity: canaryHits.map((c) => c.k),
      inrange_vs_idle_p95: +(runs.inrange.frameP95 - runs.idle.frameP95).toFixed(2),
      expand_vs_inrange_p95: +(runs.expand.frameP95 - runs.inrange.frameP95).toFixed(2),
      expand_vs_inrange_maxFrame: +(runs.expand.frameMax - runs.inrange.frameMax).toFixed(2),
      expand_vs_inrange_drop25: runs.expand.drop25 - runs.inrange.drop25,
      expand_vs_inrange_ltTotal: +(runs.expand.ltTotalMs - runs.inrange.ltTotalMs).toFixed(2),
      expand_frameWithRedraw: runs.expand.frameWithRedraw,
      expand_frameNoRedraw: runs.expand.frameNoRedraw,
      redrawCost: { move: runs.expand.redrawMove, async: runs.expand.redrawAsync },
      perMoveJsCost_inrange: runs.inrange.rec,
      expandJump: expandJump,
      curveFollow: follow,
      paused_vs_inrange_ltTotal: +(runs.paused.ltTotalMs - runs.inrange.ltTotalMs).toFixed(2),
      paused_vs_inrange_maxFrame: +(runs.paused.frameMax - runs.inrange.frameMax).toFixed(2),
      paused_backendCycles: runs.paused.redrawAsyncCount,
    };
    console.log('\n  量程内 vs 扩量程: ' + JSON.stringify(cmp));
    console.log('\n  RESULT ' + JSON.stringify({ red, redFrame, redFollow, verdicts, invalid, mode, psMode }));

    const out = { binary, ts: new Date().toISOString(), mode, psMode, ports: { web: PORT, cdp: CDP_PORT },
      thresholds: { frame: CRIT, curveFollow: FOLLOW_CRIT }, verdicts, red, redFrame, redFollow,
      invalid, canaryTripped: canaryHits.map((c) => c.k),
      curveFollow: follow, runs, compare: cmp, checks: results };
    fs.writeFileSync(path.join(root, 'perf.json'), JSON.stringify(out, null, 2));
    console.log('  EVIDENCE ' + root);
    if (invalid.length || red) process.exitCode = 1;
  } catch (e) {
    console.error('\n[ERROR] 步骤「' + STEP + '」失败: ' + (e && e.stack || e));
    if (serverOut) console.error('[rtaweb 输出尾部]\n' + serverOut.slice(-1500));
    process.exitCode = 1;
  } finally {
    clearTimeout(watchdog);
    try { await teardown(); } catch (e) { console.error('[teardown 失败] ' + (e && e.stack || e)); process.exitCode = 1; }
    if (child && child.exitCode === null) process.exitCode = 1;
    process.exit(process.exitCode || 0);
  }
})();
