// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_favs_remote.js — 「我的最爱」里远程缓存曲目的显示名判据（2026-10-28 用户实测）
//
// 用户现象：把流媒体曲目加入最爱后，标题显示成
//   \Users\august\Library\Application Support\RLPlayer\remote-cache\Frayed sleeve.aiff
// 根因链（见 docs/流媒体启用配置-空占位与405-2026-10-28.md §11）：
//   ① rlplayer-favs.json 里的路径被 normalize_fav_path() 统一成反斜杠（历史 Windows 口径）；
//   ② /api/fav/list?meta=1 只对**曲库索引里有的文件**回 title/artist/album，
//      remote-cache 里的下载文件不在索引里 ⟹ 无 meta；
//   ③ 前端兜底用 nam(file) 取文件名，而 nam() 在 macOS 上只按 '/' 与 SEP 切，
//      反斜杠路径切不开 ⟹ 整串路径被当成标题显示。
//
// 判据（真实 DOM，不 mock 前端）：
//   * 远程缓存条目的标题 = 文件名（去掉音频扩展名），**不含**目录路径、不含反斜杠；
//   * 专辑列不再显示实现细节目录名 remote-cache；
//   * 有 meta 的本地条目仍显示曲库里的真标题（不能被这次兜底改坏）。
//
// 用法：node tools/check_favs_remote.js [--binary build-mac/rtaweb]
'use strict';
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const ub = require('./uibrowser');

const args = process.argv.slice(2);
function option(name, fallback) {
  const i = args.indexOf(name);
  if (i < 0) return fallback;
  return args[i + 1];
}
const binary = path.resolve(option('--binary', path.join(__dirname, '../build-mac/rtaweb')));
{
  const real = fs.realpathSync(binary);
  const isBuildTree = /\/build[^/]*(\/|\$)/.test(real) ||
    fs.existsSync(path.join(path.dirname(real), 'CMakeCache.txt'));
  if (!isBuildTree) throw new Error('refusing non-build-tree binary (legacy state migration): ' + real);
}

const PORT = 19097;
const origin = 'http://127.0.0.1:' + PORT;
const root = fs.mkdtempSync('/tmp/rlplayer-favs-');
const state = path.join(root, 'state');
const lib = path.join(root, 'library');
const music = path.join(root, 'music');
for (const d of [state, lib, music, path.join(root, 'home'), path.join(root, 'tmp')]) {
  fs.mkdirSync(d, { recursive: true });
}

// 关键夹具：**反斜杠**路径（与真实 rlplayer-favs.json 的存储口径一致）。
const REMOTE = '\\Users\\tester\\Library\\Application Support\\RLPlayer\\remote-cache\\Frayed sleeve.aiff';
const LOCAL = '\\Users\\tester\\Music\\Demo Album\\02 本地曲目.aiff';
fs.writeFileSync(path.join(state, 'rlplayer-favs.json'),
  JSON.stringify({ files: [REMOTE, LOCAL] }, null, 2) + '\n');
fs.writeFileSync(path.join(state, 'rlplayer-settings.conf'), 'backend=null\nmetaon=0\nupnp=0\n');

let cli = null, browser = null, failures = 0, checks = 0;
function ck(ok, name, detail) {
  ++checks;
  if (!ok) ++failures;
  console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok || !detail ? '' : '  ' + JSON.stringify(detail)));
}

async function main() {
  const r = spawnSync('/usr/sbin/lsof', ['-nP', '-iTCP:' + PORT, '-sTCP:LISTEN'], { encoding: 'utf8' });
  if (r.status === 0 && r.stdout.trim()) throw new Error('port ' + PORT + ' occupied; refusing to touch owner');

  const log = fs.openSync(path.join(root, 'rtaweb.log'), 'w');
  cli = spawn(binary, ['--port', String(PORT), '--no-browser', '--music-dir', music], {
    cwd: root,
    env: { ...process.env, HOME: path.join(root, 'home'), TMPDIR: path.join(root, 'tmp'),
      RLPLAYER_STATE_DIR: state, RLPLAYER_LIBRARY_DIR: lib,
      HTTP_PROXY: '', HTTPS_PROXY: '', http_proxy: '', https_proxy: '', NO_PROXY: '127.0.0.1', no_proxy: '127.0.0.1' },
    stdio: ['ignore', log, log],
  });
  fs.closeSync(log);
  for (let i = 0; i < 100; ++i) {
    try {
      const ping = await (await fetch(origin + '/api/ping', { signal: AbortSignal.timeout(500) })).json();
      if (ping.ok) break;
    } catch (_) { /* 等自己的进程起来 */ }
    await ub.sleep(100);
  }

  const api = await (await fetch(origin + '/api/fav/list?meta=1')).json();
  ck(api.ok === true && api.files.length === 2, 'GET /api/fav/list?meta=1 返回 2 条', api);
  ck(!api.files[0].title, '远程缓存条目后端确实没有 meta title（这就是要走前端兜底）', api.files[0]);

  browser = await ub.open({ url: origin + '/', width: 1280, height: 800 });
  if (!(await browser.waitFor('typeof setView === "function" && typeof loadFavs === "function"', 12000)))
    throw new Error('UI not ready');
  await browser.eval("setView('favs'); loadFavs(); void 0;");
  if (!(await browser.waitFor("document.querySelectorAll('#list .favrow').length === 2", 12000)))
    throw new Error('favorites rows not rendered');

  const rows = await browser.eval(`(() => Array.from(document.querySelectorAll('#list .favrow')).map(r => ({
    title: (r.querySelector('.tt') || {}).textContent || '',
    album: (r.querySelector('.du') || {}).textContent || '',
    tip: (r.querySelector('.tt') || {}).title || ''
  })))()`);

  const remote = rows[0], local = rows[1];
  ck(remote.title === 'Frayed sleeve', '远程缓存条目标题 = 文件名（去扩展名），不是整串路径', remote);
  ck(remote.title.indexOf('\\\\') < 0 && remote.title.indexOf('remote-cache') < 0,
    '标题里不含反斜杠路径与 remote-cache', remote);
  ck(remote.album !== 'remote-cache', '专辑列不再显示实现目录名 remote-cache', remote);
  ck(remote.tip.indexOf('remote-cache') >= 0, '完整路径仍保留在 title 提示里（可排查，不占版面）', remote);
  ck(local.title === '02 本地曲目', '本地条目仍显示文件名兜底（无 meta 时不回归）', local);

  await browser.shot(path.join(root, 'favs.png'));
  console.log('截图: ' + path.join(root, 'favs.png'));
}

(async () => {
  let err = null;
  try { await main(); } catch (e) { err = e; console.error(e.stack || e); }
  finally {
    try { if (browser) await browser.close(); } catch (e) { err = err || e; }
    if (cli && cli.exitCode === null && cli.signalCode === null) {
      await new Promise((res) => {
        const t = setTimeout(() => res(), 15000);
        cli.once('exit', () => { clearTimeout(t); res(); });
        cli.kill('SIGTERM');
      });
    }
    console.log('证据目录: ' + root + '（保留供核对；临时状态，可删）');
    console.log((failures ? 'FAILED' : 'PASSED') + ' — ' + checks + ' 断言, ' + failures + ' 失败');
    process.exitCode = (err || failures) ? 1 : 0;
  }
})();
