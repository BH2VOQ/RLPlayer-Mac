// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// Real HTTP + headless Edge streaming-source regression check. No playback.
// node tools/sourcecheck.js --expect-red [--expect-version 1.1.1-beta]
// node tools/sourcecheck.js [--binary build-mac/rtaweb] [--expect-version X]
// Evidence and ALL app state stay in a new /tmp/rlplayer-stream-e2e/run-* directory.
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { spawn, spawnSync } = require('child_process');
const ub = require('./uibrowser');
const args = process.argv.slice(2);
const red = args.includes('--expect-red');
function option(name, fallback) {
  const i = args.indexOf(name);
  if (i < 0) return fallback;
  if (!args[i + 1] || args[i + 1].startsWith('--')) throw new Error(name + ' requires a value');
  return args[i + 1];
}
const binary = path.resolve(option('--binary', path.join(__dirname, '../build-mac/rtaweb')));
// 安全闸门（review 指出，必须）：rtaweb 启动时会 migrate_legacy_state_files()，
// 它把「可执行文件同目录」当成老安装目录，会把 rlplayer-sources.conf / llm.conf /
// 播放列表等**真实用户状态**复制进本脚本的 fixture 目录。本脚本承诺
// "ALL app state is synthetic"，所以只允许从 CMake 构建目录里的二进制启动
// （迁移逻辑对 /build* 与含 CMakeCache.txt 的目录会跳过）。
{
  const real = fs.realpathSync(binary);
  const dir = path.dirname(real);
  const isBuildTree = /\/build[^/]*(\/|$)/.test(real) ||
    fs.existsSync(path.join(dir, 'CMakeCache.txt'));
  if (!isBuildTree) {
    throw new Error('refusing to run a non-build-tree binary (legacy state migration would ' +
      'read real user config): ' + real);
  }
}
const expectedVersion = option('--expect-version', '');
const PORT = 19093;
const origin = 'http://127.0.0.1:' + PORT;
fs.mkdirSync('/tmp/rlplayer-stream-e2e', { recursive: true });
const root = fs.mkdtempSync('/tmp/rlplayer-stream-e2e/run-');
const report = { mode: red ? 'expect-red' : 'green', root, binary,
  binarySha256: crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex'), started: new Date().toISOString(),
  safety: { appPort: PORT, loopbackOnly: true, playbackRequests: 0, syntheticCredentialsOnly: true },
  checks: [], api: [], mock: [], processes: [], screenshots: [] };
let cli = null, browser = null, mock = null, currentState = null;
const PASS = 'synthetic-only-' + crypto.randomBytes(12).toString('hex');
const USER = 'sourcecheck-fixture';
const ARTIST = 'Sourcecheck Loopback Artist';
const TRACK = 'Sourcecheck Original Track';
const ARTIST_ID = 'fixture-artist';
const SONG_ID = 'fixture-song';
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII=', 'base64');
// Original mock bytes: never decoded or played. Download is checked directly against the owned mock.
const RAW = Buffer.from('fLaC\0Sourcecheck-original-untranscoded-bytes\0', 'utf8');
const song = { id: SONG_ID, title: TRACK, artist: ARTIST, album: 'Fixture Album', suffix: 'flac',
  isDir: false, duration: 1, size: RAW.length, contentType: 'audio/flac', coverArt: 'fixture-cover' };
function ensure(v, message) { if (!v) throw new Error(message); }
function check(name, pass, details, fix = false) {
  report.checks.push({ name, pass: !!pass, expected: red && fix ? 'known regression (red)' : 'pass', details });
  console.log((pass ? 'PASS ' : red && fix ? 'RED  ' : 'FAIL ') + name);
  if (!pass && !(red && fix)) throw new Error(name + ': ' + JSON.stringify(details));
}
function save(name, value) {
  // Defense in depth: synthetic secrets and auth material must not appear in diagnostic JSON.
  const text = JSON.stringify(value, null, 2).split(PASS).join('[synthetic-secret-redacted]');
  fs.writeFileSync(path.join(root, name), text + '\n');
}
async function api(route, body) {
  ensure(route.startsWith('/api/'), 'API path required');
  ensure(!/\/api\/(play|input\/start|cast\/play)/.test(route), 'Playback is forbidden');
  const r = await fetch(origin + route, { method: body === undefined ? 'GET' : 'POST',
    headers: body === undefined ? {} : { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body === undefined ? undefined : new URLSearchParams(body).toString(), signal: AbortSignal.timeout(12000) });
  const text = await r.text();
  const value = JSON.parse(text);
  report.api.push({ route, method: body === undefined ? 'GET' : 'POST', status: r.status, response: value });
  if (red && route === '/api/src/config' && body === undefined && r.status === 405) {
    check('baseline GET config unexpectedly rejected with 405', false, value, true);
    // Baseline-only observation fallback: read ONLY our own synthetic config, never modify it.
    // Default green mode requires the actual GET API to work and never takes this branch.
    const conf = path.join(currentState, 'rlplayer-sources.conf');
    const fields = fs.existsSync(conf) ? Object.fromEntries(fs.readFileSync(conf, 'utf8').trim().split('\n').filter(x => x.includes('=')).map(x => [x.slice(0, x.indexOf('=')), x.slice(x.indexOf('=') + 1)])) : {};
    const ids = [...new Set(Object.keys(fields).map(k => /^srv(\d+)\./.exec(k)).filter(Boolean).map(m => m[1]))];
    const servers = ids.map(id => ({ id, name: fields['srv' + id + '.name'], kind: fields['srv' + id + '.kind'], base: fields['srv' + id + '.base'], user: fields['srv' + id + '.user'], hasPass: !!fields['srv' + id + '.pass'], active: fields.active === id }));
    const active = servers.find(s => s.active);
    return { _baselineDiskObservation: true, active: fields.active || '', configured: !!(active && active.base && active.user), servers };
  }
  ensure(r.ok, route + ': HTTP ' + r.status);
  if (route === '/api/src/config' && body === undefined) {
    check('GET config contains no password fields or secret', !text.includes(PASS) &&
      !/(?:"pass"|"password")\s*:/.test(text), { active: value.active, count: value.servers.length });
  }
  return value;
}
async function startMock() {
  mock = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://127.0.0.1');
    const salt = u.searchParams.get('s') || '';
    const digest = crypto.createHash('md5').update(PASS + salt).digest('hex');
    const authenticated = u.searchParams.get('u') === USER && salt.length > 0 &&
      u.searchParams.get('t') === digest && !u.searchParams.has('p');
    report.mock.push({ path: u.pathname, id: u.searchParams.get('id'), authenticated,
      queryKeys: [...u.searchParams.keys()].sort() });
    const json = (payload) => { res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ 'subsonic-response': { status: 'ok', version: '1.16.1', ...payload } })); };
    if (!authenticated) {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ 'subsonic-response': { status: 'failed', error: { code: 40, message: 'fixture authentication failed' } } }));
      return;
    }
    switch (u.pathname) {
      case '/rest/ping.view': return json({});
      case '/rest/getIndexes.view': return json({ indexes: { index: [{ name: 'S', artist: [
        { id: ARTIST_ID, name: ARTIST, coverArt: 'fixture-cover' } ] }] } });
      case '/rest/getMusicDirectory.view': return json({ directory: { id: ARTIST_ID, name: ARTIST,
        child: u.searchParams.get('id') === ARTIST_ID ? [song] : [] } });
      case '/rest/search3.view': return json({ searchResult3: { song: [song] } });
      case '/rest/getCoverArt.view': res.setHeader('Content-Type', 'image/png'); return res.end(PNG);
      case '/rest/download.view':
        if (u.searchParams.has('maxBitRate') || u.searchParams.has('format')) { res.statusCode = 400; return res.end('transcoding forbidden'); }
        res.setHeader('Content-Type', 'audio/flac'); return res.end(RAW);
      default: res.statusCode = 404; return res.end('fixture endpoint not implemented');
    }
  });
  await new Promise((resolve, reject) => { mock.once('error', reject); mock.listen(0, '127.0.0.1', resolve); });
  return 'http://127.0.0.1:' + mock.address().port;
}
function stateDir(name, fixture) {
  const dir = path.join(root, name);
  for (const leaf of ['home', 'state', 'library', 'music', 'tmp']) fs.mkdirSync(path.join(dir, leaf), { recursive: true });
  fs.writeFileSync(path.join(dir, 'state/rlplayer-settings.conf'), 'backend=null\nmetaon=0\nupnp=0\n');
  if (fixture !== undefined) fs.writeFileSync(path.join(dir, 'state/rlplayer-sources.conf'), fixture);
  return dir;
}
function assertPortUnused() {
  // Read-only owner inspection BEFORE starting: never kill an existing port owner.
  const r = spawnSync('/usr/sbin/lsof', ['-nP', '-iTCP:' + PORT, '-sTCP:LISTEN'], { encoding: 'utf8' });
  report.portInspection = { status: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
  ensure(!r.error && (r.status === 0 || r.status === 1), 'Cannot inspect test port: ' + (r.error || r.stderr));
  ensure(r.status === 1 && !r.stdout.trim(), 'Port ' + PORT + ' already occupied; refusing to touch owner');
}
async function startCli(dir, label) {
  assertPortUnused();
  currentState = path.join(dir, 'state');
  const env = { ...process.env, HOME: path.join(dir, 'home'), TMPDIR: path.join(dir, 'tmp'),
    RLPLAYER_STATE_DIR: path.join(dir, 'state'), RLPLAYER_LIBRARY_DIR: path.join(dir, 'library'),
    HTTP_PROXY: '', HTTPS_PROXY: '', ALL_PROXY: '', http_proxy: '', https_proxy: '', all_proxy: '',
    NO_PROXY: '127.0.0.1,localhost', no_proxy: '127.0.0.1,localhost' };
  const out = fs.openSync(path.join(root, label + '-cli.log'), 'w');
  cli = spawn(binary, ['--port', String(PORT), '--no-browser', '--music-dir', path.join(dir, 'music')],
    { cwd: dir, env, stdio: ['ignore', out, out] });
  fs.closeSync(out);
  report.processes.push({ label, pid: cli.pid, cwd: dir, port: PORT });
  let spawnError;
  cli.once('error', e => { spawnError = e; });
  for (let i = 0; i < 100; ++i) {
    ensure(!spawnError, 'CLI spawn failed: ' + spawnError);
    ensure(cli.exitCode === null && cli.signalCode === null, 'CLI exited before readiness');
    try {
      const r = await fetch(origin + '/api/ping', { signal: AbortSignal.timeout(500) });
      const ping = await r.json();
      if (ping.ok) {
        report.processes[report.processes.length - 1].ping = ping;
        check(label + ' real /api/ping', !expectedVersion || ping.version === expectedVersion, ping);
        return;
      }
    } catch (_) { /* wait for own process to listen */ }
    await ub.sleep(100);
  }
  throw new Error('CLI readiness timed out');
}
async function stopCli() {
  if (!cli) return;
  const child = cli;
  if (child.exitCode !== null || child.signalCode !== null) { cli = null; return; }
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Owned CLI did not exit after SIGTERM; never force-killed, pid=' + child.pid)), 20000);
    child.once('exit', (code, signal) => { clearTimeout(timer); report.processes.find(p => p.pid === child.pid).exit = { code, signal }; resolve(); });
    child.kill('SIGTERM');
  });
  cli = null;
}
async function closeBrowser() {
  if (browser) { await browser.close(); browser = null; }
}
async function ui(label, wantSuccess) {
  await closeBrowser();
  // uibrowser uses os.tmpdir() for its isolated profile: keep that under our evidence root too.
  const previousHome = process.env.HOME, previousTmp = process.env.TMPDIR;
  process.env.HOME = path.dirname(currentState) + '/home';
  process.env.TMPDIR = path.dirname(currentState) + '/tmp';
  try { browser = await ub.open({ width: 1360, height: 900 }); }
  finally {
    if (previousHome === undefined) delete process.env.HOME; else process.env.HOME = previousHome;
    if (previousTmp === undefined) delete process.env.TMPDIR; else process.env.TMPDIR = previousTmp;
  }
  await browser.send('Network.enable');
  // Observe actual browser traffic from navigation onward, independently of the fetch guard.
  await browser.send('Network.setBlockedURLs', { urls: ['*://*/api/play*', '*://*/api/input/start*', '*://*/api/cast/start*'] });
  let ready = false;
  for (let attempt = 1; attempt <= 3; ++attempt) {
    await browser.send('Page.navigate', { url: origin + '/' });
    ready = await browser.waitFor('typeof setView === "function" && !!document.getElementById("list")', 15000);
    if (ready) break;
    const diagnostic = await browser.eval('({url:location.href,ready:document.readyState,text:document.body && document.body.innerText,script:typeof setView})');
    save(label + '-not-ready-' + attempt + '.json', { diagnostic, errors: browser.errors });
    await browser.shot(path.join(root, label + '-not-ready-' + attempt + '.png'));
    // Existing CLI 500ms request-header budget may reject an idle Chromium preconnect.
    // Retry ONLY this exact, observed HTTP timeout, recording it rather than hiding it.
    report.navigationRetries = report.navigationRetries || [];
    report.navigationRetries.push({ label, attempt, diagnostic });
    if (!/请求头不完整.*500ms/.test(diagnostic.text || '') || attempt === 3)
      throw new Error('UI not ready: ' + JSON.stringify(diagnostic));
  }
  ensure(ready, 'UI not ready');
  await browser.eval(`(() => { const original = window.fetch; window.fetch = function(input, init) {
    const u = new URL(typeof input === 'string' ? input : input.url, location.href);
    if (u.origin !== location.origin || /\\/api\\/(play|input\\/start|cast\\/play)/.test(u.pathname))
      throw new Error('sourcecheck safety: forbidden request');
    return original.apply(this, arguments);
  }; setView('remote'); loadRemote(''); })()`);
  ensure(await browser.waitFor('document.getElementById("list").innerText.includes(' + JSON.stringify(ARTIST) + ') || document.getElementById("list").innerText.includes("还没有可浏览")', 12000), 'Remote UI did not settle');
  const text = await browser.eval('document.getElementById("list").innerText');
  const shot = path.join(root, label + '-remote.png');
  await browser.shot(shot); report.screenshots.push(shot);
  save(label + '-ui.json', { text, errors: browser.errors });
  if (wantSuccess) {
    check(label + ' UI artist visible', text.includes(ARTIST), { text });
    // Click ONLY the directory row; never click the song (that would play).
    const clicked = await browser.eval(`(() => { const row = [...document.querySelectorAll('#list .rowdir')].find(e => e.innerText.includes(${JSON.stringify(ARTIST)})); if (!row) return false; row.click(); return true; })()`);
    ensure(clicked, 'No clickable artist directory');
    ensure(await browser.waitFor('document.getElementById("list").innerText.includes(' + JSON.stringify(TRACK) + ')', 12000), 'Artist directory click did not reveal song');
    const trackText = await browser.eval('document.getElementById("list").innerText');
    check(label + ' UI directory click reveals track (not played)', trackText.includes(TRACK), { text: trackText });
    const trackShot = path.join(root, label + '-tracks.png');
    await browser.shot(trackShot); report.screenshots.push(trackShot);
    save(label + '-tracks-ui.json', { text: trackText, errors: browser.errors });
  } else {
    check(label + ' UI reproduces URL malformat', /URL.*(?:malformat|bad\/illegal format|missing URL)/i.test(text), { text });
  }
  if (wantSuccess && !red) {
    const beforePing = report.mock.filter(x => x.path === '/rest/ping.view' && x.authenticated).length;
    await browser.eval("openSettingsTab('stream')");
    ensure(await browser.waitFor('!!document.querySelector(\'#sp_src_list .srvrow.on [data-a="test"]\')', 10000), 'Settings saved-source Test button missing');
    const buttonId = await browser.eval(`(() => { const b = document.querySelector('#sp_src_list .srvrow.on [data-a="test"]'); const id = b.closest('.srvrow').dataset.id; b.click(); return id; })()`);
    ensure(await browser.waitFor('document.getElementById("toast").innerText === "连接成功"', 10000), 'Settings saved-source Test button did not show connection success');
    const afterPing = report.mock.filter(x => x.path === '/rest/ping.view' && x.authenticated).length;
    const toast = await browser.eval('document.getElementById("toast").innerText');
    check(label + ' actual settings saved Test button reaches authenticated mock and succeeds', afterPing > beforePing && toast === '连接成功', { buttonId, beforePing, afterPing, toast });
    const settingsShot = path.join(root, label + '-settings-test.png');
    await browser.shot(settingsShot); report.screenshots.push(settingsShot);
  }
  await closeBrowser();
}
async function workingApi(label) {
  const current = await api('/api/src/config');
  const ping = await api('/api/src/ping', { id: current.active });
  check(label + ' real authenticated POST ping', ping.ok, ping);
  if (!red) {
    const readPing = await api('/api/src/ping?id=' + encodeURIComponent(current.active));
    check(label + ' real authenticated GET ping', readPing.ok, readPing);
  }
  const listing = await api('/api/src/browse?id=');
  check(label + ' browse artist', !listing.err && listing.items.some(x => x.t === ARTIST && x.dir), listing);
  const dir = await api('/api/src/browse?id=' + ARTIST_ID);
  check(label + ' browse song', !dir.err && dir.items.some(x => x.t === TRACK && !x.dir), dir);
  const search = await api('/api/src/search?q=Sourcecheck');
  check(label + ' search3 song', !search.err && search.items.some(x => x.id === SONG_ID), search);
  const cover = Buffer.from(await (await fetch(origin + '/api/src/cover?id=fixture-cover', { signal: AbortSignal.timeout(10000) })).arrayBuffer());
  check(label + ' original cover PNG bytes', cover.equals(PNG), { size: cover.length });
}
async function main() {
  ensure(process.platform === 'darwin', 'This fixture is explicitly macOS-only');
  fs.accessSync(binary, fs.constants.X_OK);
  const base = await startMock();
  report.mockBase = base;
  // Independently prove the mock rejects bad tokens and serves original bytes, without any app play request.
  const salt = 'fixture-selftest';
  const auth = new URLSearchParams({ u: USER, s: salt, t: crypto.createHash('md5').update(PASS + salt).digest('hex'), v: '1.16.1', c: 'sourcecheck', f: 'json' });
  const rejected = await (await fetch(base + '/rest/ping.view?u=' + USER + '&s=x&t=wrong')).json();
  check('mock rejects invalid MD5 token', rejected['subsonic-response'].status === 'failed');
  const raw = Buffer.from(await (await fetch(base + '/rest/download.view?' + auth + '&id=' + SONG_ID)).arrayBuffer());
  check('mock original download bytes (direct fixture only; no playback)', raw.equals(RAW));
  const cfg = 'version=2\nnextid=3\nactive=1\nsrv1.name=Empty placeholder\nsrv1.kind=subsonic\nsrv1.base=\nsrv1.user=\nsrv1.pass=\n' +
    'srv2.name=Owned loopback fixture\nsrv2.kind=subsonic\nsrv2.base=' + base + '\nsrv2.user=' + USER + '\nsrv2.pass=' + PASS + '\n';
  const dir = stateDir('persisted-placeholder', cfg);
  await startCli(dir, 'loaded');
  const loaded = await api('/api/src/config');
  const listing = await api('/api/src/browse?id=');
  const actualRed = loaded.active === '1' && /URL.*(?:malformat|bad\/illegal format|missing URL)/i.test(listing.err || '') && listing.items.length === 0;
  report.baselineRed = actualRed;
  if (red) check('baseline reproduces empty active=1 URL malformat', actualRed, { loaded, listing });
  else {
    check('loaded invalid active falls back to valid srv2', loaded.active === '2' && loaded.configured, loaded);
    check('loaded fallback browse succeeds', !listing.err && listing.items.some(x => x.t === ARTIST), listing);
  }
  await ui(red ? 'red-loaded' : 'green-loaded', !red);
  // Save the valid row exactly as UI does. Blank password must preserve the saved synthetic password.
  const update = await api('/api/src/config', { action: 'update', id: '2', kind: 'subsonic', name: 'Saved fixture', base, user: USER, pass: '' });
  check('real save API updates srv2', update.ok, update);
  let saved = await api('/api/src/config');
  check('save keeps/reselects valid srv2', saved.active === '2', saved, true);
  if (red) {
    const explicit = await api('/api/src/config', { action: 'active', id: '2' });
    check('baseline fixture control explicitly enables valid srv2', explicit.ok, explicit);
  }
  await workingApi('saved');
  await ui(red ? 'red-positive-control' : 'green-saved', true);
  const added = await api('/api/src/config', { action: 'add', kind: 'subsonic', base, user: USER, pass: PASS, name: 'Second valid fixture' });
  check('additional valid source saved', added.ok, added);
  saved = await api('/api/src/config');
  check('existing valid active is not stolen by add', saved.active === '2', saved);
  const sideGet = await fetch(origin + '/api/src/config?action=remove&id=2', { signal: AbortSignal.timeout(10000) });
  const sideGetBody = await sideGet.json();
  const afterSideGet = await api('/api/src/config');
  check('GET action=remove stays 405 and cannot mutate config', sideGet.status === 405 && JSON.stringify(saved) === JSON.stringify(afterSideGet), { status: sideGet.status, body: sideGetBody, afterSideGet });
  const invalidActive = await api('/api/src/config', { action: 'active', id: '1' });
  const afterActive = await api('/api/src/config');
  check('invalid active rejected without changing valid current', invalidActive.ok === false && afterActive.active === '2', { invalidActive, afterActive }, true);
  if (afterActive.active !== '2') await api('/api/src/config', { action: 'active', id: '2' });
  for (const bad of [{ action: 'add', kind: 'subsonic', base: '', user: USER },
    { action: 'update', id: added.id, kind: 'subsonic', base, user: '' }]) {
    const before = await api('/api/src/config');
    const result = await api('/api/src/config', bad);
    const after = await api('/api/src/config');
    check(bad.action + ' missing base/user rejected without mutation', result.ok === false && JSON.stringify(before) === JSON.stringify(after), { result, before, after }, true);
  }
  await stopCli();
  await startCli(dir, 'restart');
  const restarted = await api('/api/src/config');
  check('restart preserves valid active and secret flag', restarted.active === '2' && restarted.servers.find(x => x.id === '2').hasPass, restarted);
  await workingApi('restart');
  await ui(red ? 'red-restart-control' : 'green-restart', true);
  await stopCli();
  const fresh = stateDir('new-empty');
  await startCli(fresh, 'fresh');
  const empty = await api('/api/src/config');
  check('new empty config has no sources', empty.servers.length === 0, empty);
  const blank = await api('/api/src/config', {});
  const afterBlank = await api('/api/src/config');
  check('empty POST rejected and creates no source', blank.ok === false && afterBlank.servers.length === 0, { blank, afterBlank }, true);
  // Return to a truly empty state for independent add->browse proof even on baseline.
  for (const item of afterBlank.servers) await api('/api/src/config', { action: 'remove', id: item.id });
  const first = await api('/api/src/config', { action: 'add', kind: 'subsonic', base, user: USER, pass: PASS, name: 'Fresh fixture' });
  const freshConfig = await api('/api/src/config');
  check('new empty config add valid automatically active', first.ok && freshConfig.active === first.id && freshConfig.configured, { first, freshConfig });
  await workingApi('fresh-add');
  await ui(red ? 'red-fresh-control' : 'green-fresh-add', true);
  await stopCli();
  await startCli(fresh, 'fresh-restart');
  const freshRestart = await api('/api/src/config');
  check('fresh add survives restart', freshRestart.active === first.id && freshRestart.configured, freshRestart);
  await workingApi('fresh-restart');
  const appRequests = report.mock.filter(x => x.path !== '/rest/download.view' && !(x.path === '/rest/ping.view' && !x.authenticated));
  check('all app mock requests pass real MD5 authentication', appRequests.length > 0 && appRequests.every(x => x.authenticated), { count: appRequests.length });
  check('no mock stream/transcoding endpoint used', !report.mock.some(x => /stream\.view/.test(x.path)));
}
(async () => {
  let failure;
  try { await main(); }
  catch (e) { failure = e; report.failure = e.stack || String(e); console.error(e.stack || e); }
  finally {
    const cleanup = [];
    try { await closeBrowser(); cleanup.push('headless closed and waited'); } catch (e) { failure = failure || e; cleanup.push(String(e)); }
    try { await stopCli(); cleanup.push('owned CLI SIGTERM and exit waited'); } catch (e) { failure = failure || e; cleanup.push(String(e)); }
    if (mock) {
      try { await new Promise(resolve => { mock.close(resolve); mock.closeIdleConnections(); }); cleanup.push('owned mock closed'); }
      catch (e) { failure = failure || e; cleanup.push(String(e)); }
    }
    report.cleanup = cleanup;
    report.finished = new Date().toISOString(); report.success = !failure;
    save('report.json', report);
    console.log('Evidence: ' + root);
    console.log((failure ? 'FAILED' : red ? 'EXPECTED RED REPRODUCED' : 'GREEN PASSED') + ' — no playback was requested');
    process.exitCode = failure ? 1 : 0;
  }
})();
