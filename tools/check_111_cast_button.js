// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_111_cast_button.js —— 「推送到设备」按钮的实时跟随（2026-10-30 用户实测 B2）
//
// 用户原话：「点完投送，投送到设备按钮没有实时切换到设备，而是还保持着图示状态，
//             然后退出重进才会正常。」
//
// 代码级根因（旧实现）：castPush() 里 playPath()（异步、不返回 Promise）→ toast →
//   pollCastState(true)，那一次 GET /api/cast/state 几乎必然**先于**服务端
//   CastManager::start() 到达 ⟹ 读到 running=false，而 once=true 从不重试
//   ⟹ 按钮永久停在「推送到设备」，只有离开/重进单曲页（那里的 pollCastState(true)）才被纠正。
//
// 判据（铁律 3：为什么要这样测）
//   * 用页面内的 api() 打桩把竞态**变成确定的**：前 2 次 /api/cast/state 回 running=false
//     （模拟"start() 还没跑到"），第 3 次起回 running=true（模拟会话建立）。真实网络下这个
//     先后顺序是靠运气撞出来的，桩把它固定下来，红/绿才有判别力。
//   * B2-a：点完投送后 500ms 内按钮必须变「已推送到 …」，且**最终仍是**已推送，
//     并且 /api/cast/state 被请求 ≥2 次（旧代码恒为 1 次 → 停在「推送到设备」）。
//   * B2-b（反向）：让后端一直回 phase='error'，按钮必须**退回**「推送到设备」
//     —— 证明乐观态不是永久假象。
//   * B2-c：收敛后必须停止重试（6 秒内 /api/cast/state 请求数 ≤ 20），不能把轮询打成高频。
//
// 安全：backend=null（不打开任何音频设备，铁律 1）；端口 19101 + CDP 9712，绝不碰 8899；
//       收尾：pgrep/lsof 只读核验属主后 SIGTERM，绝不 force-kill（本机沙箱禁 /bin/ps）。
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), net = require('net');
const { spawn, spawnSync, execFileSync } = require('child_process');
const ub = require('./uibrowser');

// ---- /bin/ps 不可用时的只读垫片 -------------------------------------------------
// 本机沙箱禁止执行 /bin/ps（EPERM, exit 126），而 tools/uibrowser.js 的属主核验
// （verifyChildIdentity / stopOwnedBrowser）与仓库里其它脚本都调 `ps -p PID -o uid=,ppid=,comm=`。
// 这里只在真 ps 跑不通时，把三者从 lsof 里取出来（-R=PPID、-d txt=可执行文件路径），
// 临时垫一个**只实现这一种调用**的 shim 到 PATH 前面；真 ps 可用时完全不介入。
// 语义对齐：uid/ppid 与 ps 同源（内核），comm 取可执行文件 basename（比 ps 的截断名更准）。
function ensurePsShim() {
  try {
    const probe = spawnSync('ps', ['-p', String(process.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' });
    if (probe.status === 0 && /^\d+\s+\d+\s+/.test(probe.stdout || '')) return null;   // 真 ps 可用
  } catch (e) { /* 走垫片 */ }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-ps-shim-'));
  const f = path.join(dir, 'ps');
  fs.writeFileSync(f, [
    '#!/bin/bash',
    '# 只实现 ps -p PID -o uid=,ppid=,comm=（沙箱禁 /bin/ps 时的只读垫片，数据取自 lsof）',
    'pid=""',
    'while [ $# -gt 0 ]; do case "$1" in -p) pid="$2"; shift 2;; *) shift;; esac; done',
    '[ -z "$pid" ] && { echo "ps shim: only -p PID -o uid=,ppid=,comm=" >&2; exit 2; }',
    'info=$(lsof -p "$pid" -R -F pcuR 2>/dev/null) || exit 1',
    '[ -z "$info" ] && exit 1',
    'uid=$(printf "%s\\n" "$info" | awk \'/^u/{print substr($0,2); exit}\')',
    'ppid=$(printf "%s\\n" "$info" | awk \'/^R/{print substr($0,2); exit}\')',
    'exe=$(lsof -p "$pid" -a -d txt -Fn 2>/dev/null | awk \'/^n/{print substr($0,2); exit}\')',
    '[ -z "$exe" ] && exe=$(printf "%s\\n" "$info" | awk \'/^c/{print substr($0,2); exit}\')',
    'printf "%s %s %s\\n" "$uid" "$ppid" "$(basename "$exe")"',
  ].join('\n') + '\n');
  fs.chmodSync(f, 0o755);
  process.env.PATH = dir + ':' + (process.env.PATH || '');
  const chk = spawnSync('ps', ['-p', String(process.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' });
  if (chk.status !== 0) throw Error('ps 垫片不工作：' + (chk.stderr || chk.error));
  return dir;
}
const PS_SHIM_DIR = ensurePsShim();

const args = process.argv.slice(2);
const argOf = (n, d) => { const i = args.indexOf(n); return i !== -1 && i + 1 < args.length ? args[i + 1] : d; };
const binary = path.resolve(argOf('--binary', 'build-mac/rtaweb'));
const port = 19101, cdpPort = 9712;

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-cast-btn-'));
const env = {
  ...process.env,
  HOME: path.join(root, 'home'),
  RLPLAYER_STATE_DIR: path.join(root, 'state'),
  RLPLAYER_LIBRARY_DIR: path.join(root, 'lib'),
  RLPLAYER_COVER_DIR: path.join(root, 'covers'),
};
for (const k of ['HOME', 'RLPLAYER_STATE_DIR', 'RLPLAYER_LIBRARY_DIR', 'RLPLAYER_COVER_DIR']) fs.mkdirSync(env[k], { recursive: true });
fs.mkdirSync(path.join(root, 'music'));
// backend=null：任何一次真实播放都落在空设备上（不出声）
fs.writeFileSync(path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-settings.conf'),
  'backend=null\nmetaon=0\nmetallm=0\nvolume=-120\ntheme=light\nuistyle=apple\nlang=zh\n');

let child, session;
const results = [];
const ck = (v, name, data) => {
  results.push({ pass: !!v, name, data });
  console.log((v ? 'PASS ' : 'FAIL ') + name + (data === undefined ? '' : '  ' + JSON.stringify(data)));
};
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

// 本机沙箱禁 /bin/ps：只读核验属主改用 pgrep(按 uid 过滤) + lsof(cwd/监听)。
function verifyOwnedServer() {
  const lines = execFileSync('pgrep', ['-u', String(process.getuid()), '-fl', 'rtaweb'], { encoding: 'utf8' })
    .split('\n').filter(Boolean);
  const mine = lines.find((l) => l.startsWith(String(child.pid) + ' '));
  if (!mine) throw Error('找不到自己的 rtaweb 进程；不发信号');
  if (!mine.includes('--port ' + port)) throw Error('命令行端口不是我们的：' + mine);
  if (!mine.includes(root)) throw Error('命令行不是我们的临时目录：' + mine);
  const cwd = execFileSync('lsof', ['-p', String(child.pid), '-a', '-d', 'cwd', '-Fn'], { encoding: 'utf8' });
  if (!cwd.includes(root)) throw Error('cwd 不符：' + cwd);
  fs.appendFileSync(path.join(root, 'owners.log'), mine + '\n' + cwd + '\n');
}

// 页面内的桩：把「/api/play 与 /api/cast/state 的先后顺序」固定成确定序列。
const INSTALL_STUB = (plan) => `(() => {
  var calls = { cast: 0, play: 0, other: 0 };
  window.__RACE = { calls: calls, plan: '${plan}' };
  window.api = function (u, body) {
    if (u.indexOf('/api/cast/state') === 0) {
      calls.cast++;
      var n = calls.cast;
      // 前 2 次：会话还没 start（旧 bug 撞的就是这一刻）；第 3 次起：会话已建立
      var phase = (window.__RACE.plan === 'error') ? 'error' : (n <= 2 ? 'stopped' : 'serving');
      return Promise.resolve({ ok: true, running: phase === 'serving', phase: phase,
                               device: 'http://127.0.0.1:19109/desc.xml',
                               sourceFile: window.__CAST_FILE || '' });
    }
    if (u.indexOf('/api/play') === 0) {
      calls.play++;
      return new Promise(function (res) { setTimeout(function () { res({ ok: true }); }, 300); });
    }
    // /api/status 必须回一份**像真的**播放状态：tick() 的 else 分支（无 current）会把
    // #npMeta 的 innerHTML 清空 —— 那时按钮不是"没点亮"，而是整个被删掉，会污染判据。
    if (u.indexOf('/api/status') === 0) {
      return Promise.resolve({ ok: true, current: window.__CAST_FILE || '', playing: true, paused: false,
        dur: 3, pos: 0.4, outRate: 96000, outBits: 16, outMode: 'upnp', bitPerfect: 'no',
        bitPerfectWhy: 'UPnP 投放：本机 DSP 未介入', hasLlmKey: false, summaryEnabled: false,
        volDb: -20, startDb: -20, device: 'RLP-Test-Renderer', file: window.__CAST_FILE || '' });
    }
    if (u.indexOf('/api/queue') === 0) {
      return Promise.resolve({ ok: true, items: [window.__CAST_FILE || ''], cues: [[-1, -1]], index: 0,
                               mode: 0, repeat: 0, shuffle: false });
    }
    calls.other++;
    return Promise.resolve({ ok: true });
  };
  // 设备发现/选择：直接回一个假渲染器 URL（本用例只测 castPush 的内部顺序）
  window.npPickCastDevice = function (cb) { cb('http://127.0.0.1:19109/desc.xml'); };
  return true;
})()`;

const SAMPLE_START = `(() => {
  window.__SAMPLE = [];
  var t0 = performance.now();
  window.__SAMPLE_TIMER = setInterval(function () {
    var b = document.getElementById('npCastBtn');
    window.__SAMPLE.push([Math.round(performance.now() - t0), b ? b.textContent : null]);
  }, 50);
  return true;
})()`;
const SAMPLE_STOP = `(() => { clearInterval(window.__SAMPLE_TIMER); return window.__SAMPLE; })()`;

// 让单曲页出现（#npCastBtn 由 renderNp() 写进 #npMeta）
const OPEN_NP = `(() => {
  var pg = document.getElementById('npPage');
  if (pg) pg.classList.add('on');
  renderNp();
  var b = document.getElementById('npCastBtn');
  return b ? b.textContent : null;
})()`;

const DO_PUSH = (file) => `(() => {
  window.__CAST_FILE = ${JSON.stringify(file)};
  window.__T0 = performance.now();
  castPush(${JSON.stringify(file)});
  return true;
})()`;

async function scenario(name, plan, file, expectLit) {
  const base = await session.eval(INSTALL_STUB(plan));
  if (!base) throw Error('装桩失败');
  await session.eval("document.getElementById('npPage').classList.add('on'); renderNp();");
  await pause(150);
  const before = await session.eval("document.getElementById('npCastBtn').textContent");
  await session.eval(SAMPLE_START);
  await session.eval(DO_PUSH(file));
  await pause(5600);
  const samples = (await session.eval(SAMPLE_STOP)) || [];
  const calls = (await session.eval('window.__RACE.calls')) || { cast: -1, play: -1 };
  const lit = samples.find((s) => s[1] && s[1].indexOf('已推送到') === 0);
  const last = samples.length ? samples[samples.length - 1][1] : null;
  console.log(`\n[${name}] 点击前=${JSON.stringify(before)}  最终=${JSON.stringify(last)}`);
  console.log(`       首次变成「已推送」的时间=${lit ? lit[0] + 'ms' : '从未'}  ` +
              `/api/cast/state 请求数=${calls.cast}  /api/play 请求数=${calls.play}  采样=${samples.length}`);
  return { before, lit, last, calls, samples };
}

(async () => {
  let ok = true;
  try {
    // 端口预检（绝不探测 8899）
    await new Promise((resolve, reject) => {
      const s = net.createServer();
      s.once('error', reject);
      s.listen(port, '127.0.0.1', () => s.close(resolve));
    });
    child = spawn(binary, ['--port', String(port), '--music-dir', path.join(root, 'music')],
      { env, cwd: root, stdio: 'ignore' });
    let up = false;
    for (let i = 0; i < 150; i++) {
      try { if ((await fetch(`http://127.0.0.1:${port}/api/ping`)).ok) { up = true; break; } } catch (e) { }
      await pause(100);
    }
    if (!up) throw Error('rtaweb 没起来（port ' + port + '）');
    console.log('[env] rtaweb pid=' + child.pid + ' port=' + port + ' binary=' + binary);

    session = await ub.open({ url: `http://127.0.0.1:${port}/`, port: cdpPort });
    const ready = await session.waitFor("typeof castPush==='function' && typeof api==='function'", 12000);
    if (!ready) throw Error('UI 没就绪（castPush/api 不存在）');
    const btn = await session.eval(OPEN_NP);
    if (btn === null) throw Error('单曲页里没有 #npCastBtn');
    ck(btn.indexOf('推送到设备') === 0, '初始按钮 = 「推送到设备」', btn);

    // ---------- B2-a：竞态下的实时跟随 ----------
    const a = await scenario('B2-a 竞态跟随', 'normal', path.join(root, 'music', 'A.wav'), true);
    ck(a.lit && a.lit[0] <= 500, 'B2-a 点完投送后 ≤500ms 按钮变「已推送到 …」（旧代码：从未变）',
      a.lit ? a.lit[0] + 'ms' : 'never');
    ck(a.last && a.last.indexOf('已推送到') === 0, 'B2-a 5.6s 后仍是「已推送到 …」（不刷新页面）', a.last);
    ck(a.calls.cast >= 2, 'B2-a 首采样 false 之后仍继续收敛（/api/cast/state ≥2 次；旧代码恒 1 次）', a.calls.cast);
    // B2-c 口径（2026-10-30 更新）：收敛期每 300ms 重试，收敛之后转入**常规 1s 轮询**
    //（与设置页输出面板同一节奏；这是"投放失败要能在 1s 内退回"的必要条件，见 C3）。
    // 所以 6s 内的合理上限是「收敛 3 次 + 约 5 次 1s 轮询」≈ 8～10 次；关键判据是不出现
    // 亚秒级高频轮询（那会得到 20+ 次）。
    ck(a.calls.cast <= 10, 'B2-c 收敛后转入 1s 常规轮询（6s 内 /api/cast/state ≤10 次，无高频轮询）', a.calls.cast);

    // ---------- B2-b：后端报错时必须退回，不许永久乐观 ----------
    await session.eval("applyCastUi({ok:true,running:false,phase:'stopped',device:'',sourceFile:''})");
    await pause(100);
    const b = await scenario('B2-b 失败回退', 'error', path.join(root, 'music', 'B.wav'), false);
    ck(b.last && b.last.indexOf('推送到设备') === 0, 'B2-b phase=error 时按钮退回「推送到设备」（乐观态不是永久假象）', b.last);

    ok = results.every((r) => r.pass);
    console.log('\n[RESULT] ' + (ok ? 'ALL PASS' : 'HAS FAIL') +
      `  (${results.filter((r) => r.pass).length}/${results.length})`);
  } catch (e) {
    ok = false;
    console.log('[ERROR] ' + (e && e.message ? e.message : e));
  } finally {
    if (session) {
      try { await session.close(); } catch (e) { console.log('[teardown] 浏览器收尾异常: ' + e.message); }
    }
    if (child && child.pid) {
      try {
        verifyOwnedServer();
        child.kill('SIGTERM');                 // 只 TERM，绝不 force-kill
        const t0 = Date.now();
        while (Date.now() - t0 < 10000 && child.exitCode === null) await pause(100);
        console.log('[teardown] rtaweb exit=' + child.exitCode + '（ps 不可用，属主已用 pgrep+lsof 核验）');
      } catch (e) {
        console.log('[teardown] rtaweb 未发信号: ' + e.message);
      }
    }
    console.log('[teardown] 临时目录: ' + root + '  ps 垫片: ' + (PS_SHIM_DIR || '(未启用，真 ps 可用)'));
    if (PS_SHIM_DIR) { try { fs.rmSync(PS_SHIM_DIR, { recursive: true, force: true }); } catch (e) { } }
  }
  process.exit(ok ? 0 : 1);
})();
