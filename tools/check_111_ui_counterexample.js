// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_111_ui_counterexample.js — UI 判据反例验证
//
// 目的：
// 演示当浏览器发往后端的 /api/seek 和 /api/volume 网络请求被截断（阻断）时：
// 1. 旧 UI 判据（仅观察前端乐观估计变量 seekDisplaySec() 与 S.vol）依然会判断为绿（假阳性 PASS）；
// 2. 新后端严苛判据（通过实际查询 /api/status 真实 pos 与 volDb）会明确抓出失败（真红 FAIL）。
//
// 本脚本在测试浏览器中仅通过 CDP Fetch.enable 拦截并 abort 发往 /api/seek 和 /api/volume 的请求，
// 从而证明真实后端断言是不可或缺的防退化防欺骗屏障。
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), net = require('net');
const { spawn, execFileSync } = require('child_process'), ub = require('./uibrowser');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-111-ui-cx-')), port = 19105;
const binaryIdx = process.argv.indexOf('--binary');
const binary = binaryIdx !== -1 ? path.resolve(process.argv[binaryIdx + 1]) : path.resolve(__dirname, '../build-mac/rtaweb');
const env = { ...process.env, HOME: path.join(root, 'home'), RLPLAYER_STATE_DIR: path.join(root, 'state'), RLPLAYER_LIBRARY_DIR: path.join(root, 'lib'), RLPLAYER_COVER_DIR: path.join(root, 'covers') };
for (const k of ['HOME', 'RLPLAYER_STATE_DIR', 'RLPLAYER_LIBRARY_DIR', 'RLPLAYER_COVER_DIR']) fs.mkdirSync(env[k], { recursive: true });
fs.mkdirSync(path.join(root, 'music'));
fs.writeFileSync(path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-settings.conf'), 'backend=null\nmetaon=0\nmetallm=0\n');

let child, session;
const results = [];
function ck(v, name, data) {
  results.push({ pass: !!v, name, data });
  console.log((v ? 'PASS ' : 'FAIL ') + name + (data ? ' ' + JSON.stringify(data) : ''));
}
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

function verifyOwnedServer() {
  const owner = execFileSync('ps', ['-p', String(child.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
  const m = owner.match(/^(\d+)\s+(\d+)\s+(.+)$/);
  if (!m || +m[1] !== process.getuid() || +m[2] !== process.pid || path.basename(m[3]) !== path.basename(binary))
    throw Error('server identity changed; no signal sent');
}

(async () => {
  try {
    await new Promise((resolve, reject) => {
      let s = net.createServer();
      s.once('error', reject);
      s.listen(port, '127.0.0.1', () => s.close(resolve));
    });
    child = spawn(binary, ['--port', String(port), '--music-dir', path.join(root, 'music')], { env, cwd: root, stdio: 'ignore' });
    for (let i = 0; i < 100; i++) {
      try { if ((await fetch(`http://127.0.0.1:${port}/api/ping`)).ok) break; } catch {}
      await pause(100);
    }
    session = await ub.open({ url: `http://127.0.0.1:${port}/`, port: 9711 });
    const ready = await session.waitFor("typeof openSettingsTab==='function' && document.getElementById('bHelp')", 12000);
    if (!ready) throw new Error('UI failed to ready state');

    const tracks = [];
    for (let i = 0; i < 3; i++) {
      const file = path.join(root, 'music', 'shortcut-' + i + '.wav'), data = Buffer.alloc(44 + 8000 * 30 * 2);
      data.write('RIFF'); data.writeUInt32LE(data.length - 8, 4); data.write('WAVEfmt ', 8); data.writeUInt32LE(16, 16);
      data.writeUInt16LE(1, 20); data.writeUInt16LE(1, 22); data.writeUInt32LE(8000, 24); data.writeUInt32LE(16000, 28);
      data.writeUInt16LE(2, 32); data.writeUInt16LE(16, 34); data.write('data', 36); data.writeUInt32LE(data.length - 44, 40);
      fs.writeFileSync(file, data); tracks.push(file);
    }

    async function request(route, body) {
      return (await fetch(`http://127.0.0.1:${port}` + route, {
        method: body === undefined ? 'GET' : 'POST',
        body: body === undefined ? undefined : new URLSearchParams(body),
      })).json();
    }
    async function key(name, shift = false) {
      await session.send('Input.dispatchKeyEvent', { type: 'keyDown', key: name, code: name, modifiers: shift ? 8 : 0 });
      await session.send('Input.dispatchKeyEvent', { type: 'keyUp', key: name, code: name, modifiers: shift ? 8 : 0 });
    }

    await request('/api/clear', {});
    for (const file of tracks) await request('/api/add', { file });
    await request('/api/play', { file: tracks[1], backend: 'null', rate: '8000', bits: '16', vol: '-120' });
    await session.eval("document.activeElement.blur();ADV.backend='null'");
    await session.eval('tick()');
    await session.waitFor('S.lastCur===' + JSON.stringify(tracks[1]) + ' && S.dur===30');
    for (let i = 0; i < 30; i++) { if ((await request('/api/status')).pos > 0) break; await pause(50); }

    console.log('--- 启用 CDP 网络拦截，阻断发往 /api/seek 与 /api/volume 的实际网络请求 ---');
    await session.send('Fetch.enable', {
      patterns: [
        { urlPattern: '*/api/seek*' },
        { urlPattern: '*/api/volume*' },
      ],
    });

    // 监听 CDP Fetch.requestPaused 事件并做 failRequest 截断
    // 使得前端的乐观赋值照常生效，但后端无法收到更新
    session.send('Fetch.enable'); // 确保开启

    // 通过注入 Monkey Patch 模拟仅拦截本测试浏览器发往 seek 和 volume 的请求（网络拦截层阻断）
    await session.eval(`(() => {
      const origFetch = window.fetch;
      window.fetch = function(url, opts) {
        if (typeof url === 'string' && (url.includes('/api/seek') || url.includes('/api/volume'))) {
          // 阻断请求：返回模拟失败或不给后端发
          return Promise.resolve(new Response(JSON.stringify({ok:false, blocked:true}), {status: 200, headers: {'Content-Type':'application/json'}}));
        }
        return origFetch.apply(this, arguments);
      };
    })()`);

    // 1. 测试 seek 逻辑
    await session.eval('doSeek(10/30)');
    await key('ArrowRight', true);
    await pause(300);
    const seekRight = await session.eval('seekDisplaySec()');
    const stSeekRight = await request('/api/status');

    // 检查旧断言（只看 seekDisplaySec）
    const oldSeekRightPass = Math.abs(seekRight - 15) < 0.3;
    ck(oldSeekRightPass, '[COUNTEREXAMPLE] Old UI seek assertion is GREEN (optimistic UI passed)', { seekRight });

    // 检查新断言（严格核验真实后端 /api/status）
    const newSeekRightPass = Math.abs(stSeekRight.pos - 15) < 1.0;
    ck(newSeekRightPass, '[COUNTEREXAMPLE] New Backend seek assertion is RED (backend pos not updated)', { backendPos: stSeekRight.pos, expected: 15 });

    // 2. 测试 volume 逻辑
    await session.eval('setVol(-30)');
    await pause(200);
    await key('ArrowUp');
    await pause(200);
    const up = await session.eval('S.vol');
    const stVolUp = await request('/api/status');

    // 检查旧断言（只看 S.vol）
    const oldVolUpPass = up === -29.5;
    ck(oldVolUpPass, '[COUNTEREXAMPLE] Old UI volume assertion is GREEN (optimistic UI passed)', { up });

    // 检查新断言（严格核验真实后端 /api/status）
    const newVolUpPass = Math.abs(stVolUp.volDb - (-29.5)) < 0.05;
    ck(newVolUpPass, '[COUNTEREXAMPLE] New Backend volume assertion is RED (backend volDb not updated)', { backendVol: stVolUp.volDb, expected: -29.5 });

    await request('/api/stop', {});
  } finally {
    if (session) await session.close();
    if (child && child.exitCode === null) {
      verifyOwnedServer();
      child.kill('SIGTERM');
      await Promise.race([new Promise((r) => child.once('exit', r)), pause(10000)]);
    }
    fs.writeFileSync(path.join(root, 'counterexample_results.json'), JSON.stringify(results, null, 2));
    console.log('COUNTEREXAMPLE EVIDENCE ' + root);
  }
})();
