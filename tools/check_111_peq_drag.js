// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_111_peq_drag.js —— PEQ 曲线「拖拽可达范围」回归（2026-10-30 用户实测 bug）
//
// 现象：用户报「EQ 的图只能上下拉 6 dB，但上限并不是 ±6」。
// 根因（旧代码）：量程按数据自适应、下限写死 ±6；而 peqCurveGainAt() 把画布内比例
// 钳在 0..1 ⟹ 拖到画布上/下边就等于量程边，永远到不了表格输入框与引擎的 ±24。
//
// 判据（铁律 3：这个指标真能证明"能拖到上限"吗？）：
//   * 不看"画布长什么样"，而是**真的把指针拖出画布上边界**，然后读该段输入框的真实值。
//   * 必须 > 6 dB（旧代码恒为 6.0），且 ≤ 24（不许超过编辑/引擎上限）。
//   * 反向同样断言（拖出下边界必须 < −6，且 ≥ −24）。
//   * 附带：拖拽期间量程必须真的扩大（PEQ_VIEW.maxDb 变大），否则"能拖到"只是数值骗人。
// 判据的判别力由「旧二进制必须红」证明（见 debug 证据里的 red 日志）。
//
// 安全：backend=null 不打开任何音频设备；端口 19105 + CDP 9711；退出前 ps 核验属主再 TERM，绝不 force kill。
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), net = require('net');
const { spawn, execFileSync } = require('child_process');
const ub = require('./uibrowser');

const args = process.argv.slice(2);
const argOf = (n, d) => { const i = args.indexOf(n); return i !== -1 && i + 1 < args.length ? args[i + 1] : d; };
const binary = path.resolve(argOf('--binary', 'build-mac/rtaweb'));
const port = 19105, cdpPort = 9711;

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-peq-drag-'));
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

let child, session;
const results = [];
const ck = (v, name, data) => { results.push({ pass: !!v, name, data }); console.log((v ? 'PASS ' : 'FAIL ') + name + (data === undefined ? '' : ' ' + JSON.stringify(data))); };
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

function verifyOwnedServer() {
  const owner = execFileSync('ps', ['-p', String(child.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
  fs.appendFileSync(path.join(root, 'owners.log'), owner + '\n');
  const m = owner.match(/^(\d+)\s+(\d+)\s+(.+)$/);
  if (!m || +m[1] !== process.getuid() || +m[2] !== process.pid || path.basename(m[3]) !== path.basename(binary))
    throw Error('server identity changed; no signal sent');
}

// 在页面里：把第 1 段节点按下，再按给定的「垂直位移方向」把指针拖到画布外，最后读该段增益
const DRAG_TO = (dir, dist) => `(() => {
  var svg = document.querySelector('#peqCurve svg.peqsvg');
  var node = svg && svg.querySelector('.peqnode[data-i="1"]');
  var tr = document.querySelector('#peqRows .peqr[data-i="1"]');
  if (!svg || !node || !tr) return { err: 'missing svg/node/row' };
  var r = svg.getBoundingClientRect();
  var vb = svg.viewBox.baseVal;
  var cx = r.left + (+node.getAttribute('cx')) / vb.width * r.width;
  var cy = r.top + (+node.getAttribute('cy')) / vb.height * r.height;
  var before = PEQ_VIEW ? { maxDb: PEQ_VIEW.maxDb, minDb: PEQ_VIEW.minDb } : null;
  node.dispatchEvent(new PointerEvent('pointerdown', { clientX: cx, clientY: cy, bubbles: true, pointerId: 1, isPrimary: true }));
  // 拖到画布外 150px（上=加大增益，下=减小）
  var outY = cy + (${dir} < 0 ? -1 : 1) * ${dist};
  for (var step = 1; step <= 6; step++) {
    var y = cy + (outY - cy) * step / 6;
    svg.dispatchEvent(new PointerEvent('pointermove', { clientX: cx, clientY: y, bubbles: true, pointerId: 1, isPrimary: true }));
  }
  var out = { gain: +tr.querySelector('.peqG').value, before: before,
              after: PEQ_VIEW ? { maxDb: PEQ_VIEW.maxDb, minDb: PEQ_VIEW.minDb } : null };
  svg.dispatchEvent(new PointerEvent('pointerup', { clientX: cx, clientY: outY, bubbles: true, pointerId: 1, isPrimary: true }));
  return out;
})()`;

(async () => {
  try {
    await new Promise((resolve, reject) => { const s = net.createServer(); s.once('error', reject); s.listen(port, '127.0.0.1', () => s.close(resolve)); });
    child = spawn(binary, ['--port', String(port), '--music-dir', path.join(root, 'music')], { env, cwd: root, stdio: 'ignore' });
    for (let i = 0; i < 120; i++) { try { if ((await fetch(`http://127.0.0.1:${port}/api/ping`)).ok) break; } catch { } await pause(100); }

    session = await ub.open({ url: `http://127.0.0.1:${port}/`, port: cdpPort });
    const ready = await session.waitFor("typeof peqDrawCurve==='function' && document.getElementById('bHelp')", 12000);
    if (!ready) throw Error('UI not ready');
    await session.eval("openSettingsTab('eq')");
    const hasSvg = await session.waitFor("!!document.querySelector('#peqCurve svg.peqsvg .peqnode')", 8000);
    ck(hasSvg, 'PEQ 曲线与节点已渲染（真实生产 DOM）');
    await pause(300);

    // ---- 向上拖出画布：必须能超过 +6 dB，且不超过 +24 ----
    const up = await session.eval(DRAG_TO(-1, 150));
    console.log('      向上拖出画布结果:', JSON.stringify(up));
    ck(up && typeof up.gain === 'number' && up.gain > 6,
      '拖出画布上边界后增益 > +6 dB（旧代码被量程钳死在 6.0）', up);
    ck(up && up.gain <= 24, '增益不超过编辑/引擎上限 +24 dB', up && up.gain);
    ck(up && up.after && up.before && (up.after.maxDb > up.before.maxDb),
      '拖拽期间量程真的扩大了（不是只改数字骗人）', up && { before: up.before, after: up.after });

    // ---- 复位后向下拖出画布：必须能低于 −6 dB，且不低于 −24 ----
    await session.eval("peqResetBand(1)");
    await pause(400);
    const down = await session.eval(DRAG_TO(1, 150));
    console.log('      向下拖出画布结果:', JSON.stringify(down));
    ck(down && typeof down.gain === 'number' && down.gain < -6,
      '拖出画布下边界后增益 < −6 dB', down);
    ck(down && down.gain >= -24, '增益不低于编辑/引擎上限 −24 dB', down && down.gain);

    // ---- 中间值可停住：小位移拖拽必须落在开区间 (6, 24)，证明"能量到但不会一跳到底" ----
    await session.eval("peqResetBand(1)");
    await pause(400);
    const mid = await session.eval(DRAG_TO(-1, 70));
    console.log('      向上小拖 70px 结果:', JSON.stringify(mid));
    ck(mid && mid.gain > 6 && mid.gain < 23.5,
      '小位移拖拽能停在 (6, 24) 之间（不是一次跳到底）', mid && mid.gain);

    // ---- 收尾：把第 1 段复位，别把测试值留在配置里 ----
    await session.eval("peqResetBand(1)");
    await pause(300);
    const settled = await session.eval("document.querySelector('#peqRows .peqr[data-i=\"1\"] .peqG').value");
    ck(Math.abs(parseFloat(settled)) < 0.05, '收尾：第 1 段已复位到 0.0 dB', settled);

    let errors = session.errors;
    ck(errors.length === 0, '无未捕获页面异常', errors);
    await session.shot(path.join(root, 'peq-drag.png'));
  } catch (e) {
    ck(false, '执行异常', { error: String(e) });
  } finally {
    if (session) await session.close();
    if (child && child.exitCode === null) {
      verifyOwnedServer();
      child.kill('SIGTERM');
      await Promise.race([new Promise((r) => child.once('exit', r)), pause(10000)]);
      if (child.exitCode === null) throw Error('owned server did not exit after TERM');
    }
    fs.writeFileSync(path.join(root, 'results.json'), JSON.stringify({ binary, results }, null, 2));
    console.log('EVIDENCE ' + root);
  }
  if (results.some((r) => !r.pass)) process.exitCode = 1;
})();
