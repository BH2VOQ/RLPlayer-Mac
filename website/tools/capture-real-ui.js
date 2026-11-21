#!/usr/bin/env node
'use strict';

/* Capture real RLPlayer v1.1.4 screens for the website.
 * Execution requires the user's explicit --authorized flag.
 * NullSink is mandatory; no physical audio device is ever opened. */
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const { spawn, execFileSync } = require('child_process');
const ub = require('../../tools/uibrowser');

const args = process.argv.slice(2);
if (!args.includes('--authorized')) {
  throw new Error('Refusing UI automation without the explicit --authorized flag.');
}
function argOf(name, fallback) {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
}
const project = path.resolve(__dirname, '../..');
const website = path.resolve(__dirname, '..');
const binary = path.resolve(argOf('--binary', path.join(project, 'build-mac/rtaweb')));
const musicDir = path.resolve(argOf('--music-dir', '/Volumes/Music'));
const port = Number(argOf('--port', '19092'));
const cdpPort = Number(argOf('--cdp-port', '19720'));
const release = JSON.parse(fs.readFileSync(path.join(project, 'latest.json'), 'utf8'));
if (port < 19091 || cdpPort < 19091 || port === 8899 || cdpPort === 8899) {
  throw new Error('Both service and CDP ports must be isolated at 19091+; 8899 is forbidden.');
}
if (!fs.existsSync(binary)) throw new Error('Latest rtaweb binary not found: ' + binary);
if (!fs.existsSync(musicDir)) throw new Error('Music directory not found: ' + musicDir);

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-website-capture-'));
const env = {
  ...process.env,
  HOME: path.join(root, 'home'),
  RLPLAYER_STATE_DIR: path.join(root, 'state'),
  RLPLAYER_LIBRARY_DIR: path.join(root, 'library'),
  RLPLAYER_COVER_DIR: path.join(root, 'covers')
};
for (const key of ['HOME', 'RLPLAYER_STATE_DIR', 'RLPLAYER_LIBRARY_DIR', 'RLPLAYER_COVER_DIR']) {
  fs.mkdirSync(env[key], { recursive: true });
}
const prevRoot = '/var/folders/8n/893t2v7s75gbrzdvgb902nrc0000gn/T/rlp-website-capture-SYahFQ';
if (fs.existsSync(path.join(prevRoot, 'library'))) {
  fs.cpSync(path.join(prevRoot, 'library'), env.RLPLAYER_LIBRARY_DIR, { recursive: true });
}
if (fs.existsSync(path.join(prevRoot, 'covers'))) {
  fs.cpSync(path.join(prevRoot, 'covers'), env.RLPLAYER_COVER_DIR, { recursive: true });
}
fs.writeFileSync(path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-settings.conf'),
  'backend=null\nscanonstartup=0\nmetaon=1\nmetallm=0\nvolume=-120\ntheme=light\nuistyle=apple\nlang=zh\n');
const rawDir = path.join(root, 'raw');
fs.mkdirSync(rawDir);
const logFd = fs.openSync(path.join(root, 'rtaweb.log'), 'a');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let server = null;
let session = null;

async function request(route, body) {
  const response = await fetch('http://127.0.0.1:' + port + route, {
    method: body === undefined ? 'GET' : 'POST',
    headers: body === undefined ? undefined : { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body === undefined ? undefined : new URLSearchParams(body)
  });
  const json = await response.json();
  if (!response.ok) throw new Error(route + ' HTTP ' + response.status + ': ' + JSON.stringify(json));
  return json;
}

async function assertFreePort(number) {
  await new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once('error', reject);
    probe.listen(number, '127.0.0.1', () => probe.close(resolve));
  });
}

function verifyOwnedServer() {
  if (!server || server.pid === undefined || server.exitCode !== null) throw new Error('Server is not our live child.');
  const identity = execFileSync('ps', ['-p', String(server.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
  const match = identity.match(/^(\d+)\s+(\d+)\s+(.+)$/);
  if (!match || Number(match[1]) !== process.getuid() || Number(match[2]) !== process.pid || !match[3].includes('rtaweb')) {
    throw new Error('Server ownership verification failed; no signal sent: ' + identity);
  }
  const cwd = execFileSync('/usr/sbin/lsof', ['-p', String(server.pid), '-a', '-d', 'cwd', '-Fn'], { encoding: 'utf8' });
  if (!cwd.includes(root)) throw new Error('Server cwd does not match isolated root; no signal sent.');
}

async function stopServer() {
  if (!server || server.exitCode !== null || server.signalCode !== null) return;
  verifyOwnedServer();
  server.kill('SIGTERM');
  await Promise.race([
    new Promise((resolve) => server.once('exit', resolve)),
    sleep(8000)
  ]);
  if (server.exitCode === null && server.signalCode === null) {
    throw new Error('Server did not exit after SIGTERM; leaving process untouched for inspection.');
  }
}

async function capture(name) {
  const raw = path.join(rawDir, name + '.png');
  await session.shot(raw);
  const webpShot = await session.send('Page.captureScreenshot', { format: 'webp', quality: 92 });
  const output = path.join(website, 'assets', name + '.webp');
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, Buffer.from(webpShot.data, 'base64'));
  const info = execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', output], { encoding: 'utf8' });
  console.log('CAPTURED ' + name + ' -> ' + output + '\n' + info.trim());
}

(async () => {
  let succeeded = false;
  try {
    await assertFreePort(port);
    server = spawn(binary, ['--port', String(port), '--music-dir', musicDir, '--no-browser'], {
      env, cwd: root, stdio: ['ignore', logFd, logFd]
    });
    let ping = null;
    for (let i = 0; i < 200; i += 1) {
      if (server.exitCode !== null) throw new Error('rtaweb exited during startup; see ' + path.join(root, 'rtaweb.log'));
      try {
        const candidate = await request('/api/ping');
        if (candidate.ok) { ping = candidate; break; }
      } catch (error) { /* not ready */ }
      await sleep(100);
    }
    if (!ping) throw new Error('rtaweb did not become ready on isolated port ' + port);
    if (ping.version !== release.version) {
      throw new Error('Version mismatch: binary=' + ping.version + ' latest.json=' + release.version);
    }
    console.log('VERSION VERIFIED ' + ping.version + ' pid=' + server.pid + ' port=' + port);

    const settings = await request('/api/settings');
    const configuredBackend = String((settings.kv && settings.kv.backend) || (settings.settings && settings.settings.backend) || '');
    if (configuredBackend.toLowerCase() !== 'null') {
      throw new Error('Null backend gate failed before browser launch: ' + JSON.stringify(settings).slice(0, 300));
    }
    console.log('NULL BACKEND VERIFIED (settings.backend=null)');

    session = await ub.open({ url: 'http://127.0.0.1:' + port + '/', port: cdpPort, width: 1600, height: 1000, settleMs: 1200 });
    await session.send('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 2, mobile: false });
    const ready = await session.waitFor("typeof setView==='function' && typeof openSettingsTab==='function'", 15000);
    if (!ready) throw new Error('Real application UI did not initialize.');

    let albums = [];
    for (let i = 0; i < 1200; i += 1) {
      const result = await request('/api/lib/albums');
      albums = result.albums || [];
      if (albums.length >= 3) break;
      await sleep(100);
    }
    if (!albums.length) throw new Error('No real albums were indexed; screenshots were not captured.');
    console.log('REAL LIBRARY READY albums=' + albums.length);

    // Wait for visible album covers to extract & render on the Albums grid
    await session.eval("closeNowPlaying(); setView('albums'); loadAlbums(''); window.scrollTo(0,0);");
    await session.waitFor("document.querySelectorAll('#list .card').length >= 12", 15000);
    await session.waitFor("Array.from(document.querySelectorAll('#list .card img')).slice(0, 18).filter(i => i.complete && i.naturalWidth > 0).length >= 10", 25000);
    await sleep(800);

    // Pick a 96k/24 track with verified embedded cover art (hasCover=1)
    const search = await request('/api/lib/search?q=Aimer');
    const tracks = (search && search.tracks && search.tracks.length)
      ? search.tracks
      : ((await request('/api/lib/search?q=')).tracks || []);
    let track = tracks.find((item) => /蝶々結/.test(item.path || ''))
      || tracks.find((item) => /花の唄/.test(item.path || ''))
      || tracks.find((item) => /UnChild/.test(item.path || ''))
      || tracks.find((item) => /\.flac$/i.test(item.path || ''))
      || tracks[0];
    if (!track || !track.path) throw new Error('No real track available for Now Playing capture.');
    console.log('SELECTED TRACK ' + track.path);

    // Enqueue several tracks so playback queue / bottom bar looks complete
    await request('/api/clear', {});
    for (const t of tracks.slice(0, 8)) {
      if (t && t.path) await request('/api/add', { file: t.path });
    }

    const play = await request('/api/play', { file: track.path, backend: 'null', vol: '-120' });
    if (!play.ok) throw new Error('NullSink playback initialization failed: ' + JSON.stringify(play));

    let playingStatus = null;
    let signalStatus = null;
    for (let i = 0; i < 120; i += 1) {
      playingStatus = await request('/api/status');
      signalStatus = await request('/api/signal');
      if (playingStatus.outMode === 'null' && playingStatus.dur > 10 && playingStatus.pos > 0) break;
      await sleep(100);
    }
    if (String(playingStatus.outMode || '').toLowerCase() !== 'null' && String(signalStatus.deviceId || '').toLowerCase() !== 'null') {
      await request('/api/stop', {}).catch(() => {});
      throw new Error('Playback is not on NullSink; stopped and aborted: ' + JSON.stringify({ outMode: playingStatus.outMode, sigDeviceId: signalStatus.deviceId }));
    }
    console.log('NULLSINK PLAYBACK VERIFIED outMode=' + playingStatus.outMode + ' device=' + signalStatus.device);

    await request('/api/seek', { pos: String(Math.round((playingStatus.dur || 180) * 0.34)) }).catch(() => {});
    await session.eval('doSeek(0.34); tick();');
    await session.waitFor("(() => { const cv = document.getElementById('cv'); return cv && cv.style.backgroundImage && cv.style.backgroundImage.indexOf('url(') === 0; })()", 15000);
    await session.waitFor("(window.LY && Array.isArray(LY.lines) && LY.lines.length > 3)", 12000);
    await sleep(800);
    await session.eval('tick();');

    // 1. Capture ui-library (Albums Grid with loaded covers + active bottom playback bar)
    await session.eval(`(() => {
      closeNowPlaying();
      if (window.VIEWC && VIEWC.m) delete VIEWC.m['albums|'];
      setView('albums');
      loadAlbums('');
      const sub = document.getElementById('sub');
      if (sub && window.S && Array.isArray(S.albums) && S.albums.length) {
        sub.textContent = S.albums.length + ' 张专辑';
      }
      const cp = document.getElementById('covProg');
      if (cp) cp.style.display = 'none';
    })()`);
    await sleep(1200);
    await session.eval(`(() => {
      const sub = document.getElementById('sub');
      if (sub && window.S && Array.isArray(S.albums) && S.albums.length) {
        sub.textContent = S.albums.length + ' 张专辑';
      }
      const cp = document.getElementById('covProg');
      if (cp) cp.style.display = 'none';
      // Scroll slightly to the Aimer / Ado rows where every card has high-res album art
      const cards = document.querySelectorAll('#list .card');
      if (cards.length > 8) {
        cards[8].scrollIntoView({ block: 'start' });
      }
      if (typeof tick === 'function') tick();
    })()`);
    await session.waitFor("Array.from(document.querySelectorAll('#list .card img')).slice(8, 28).filter(i => i.complete && i.naturalWidth > 0).length >= 14", 15000);
    await sleep(900);
    await capture('ui-library');

    // 2. Capture ui-dsp (20-band Parametric EQ with realistic acoustic calibration curve)
    await session.eval("closeNowPlaying(); openSettingsTab('eq'); window.scrollTo(0,0);");
    const peqReady = await session.waitFor("!!document.querySelector('#peqCurve svg.peqsvg .peqnode')", 12000);
    if (!peqReady) throw new Error('Real 20-band PEQ did not render.');
    await session.eval(`(() => {
      const gains = [2.8, 3.4, 3.0, 1.8, 0.6, -0.4, -1.1, -1.5, -1.2, -0.5, 0.2, 1.4, 2.6, 3.2, 2.1, 0.4, -1.6, -2.4, 1.2, 2.0];
      const rows = document.querySelectorAll('#peqRows .peqr');
      rows.forEach((r, idx) => {
        const g = r.querySelector('.peqG');
        if (g && idx < gains.length) g.value = String(gains[idx]);
      });
      if (typeof peqApply === 'function') peqApply();
      return rows.length;
    })()`);
    await sleep(900);
    await capture('ui-dsp');

    // 3. Capture ui-hero (Now Playing full view with high-res cover, lyrics/metadata & signal badge)
    await session.eval('openNowPlaying(); window.scrollTo(0,0);');
    await session.waitFor("document.getElementById('npPage') && document.getElementById('npPage').classList.contains('on')", 8000);
    await session.waitFor("(() => { const img = document.getElementById('npCover'); return img && img.complete && img.naturalWidth > 0; })()", 10000);
    await sleep(1200);
    await capture('ui-hero');

    await request('/api/stop', {}).catch(() => {});
    await sleep(200);
    const report = {
      version: ping.version,
      backend: 'null',
      viewport: [1600, 1000],
      deviceScaleFactor: 2,
      screenshots: ['ui-hero.webp', 'ui-dsp.webp', 'ui-library.webp'],
      capturedAt: new Date().toISOString()
    };
    fs.writeFileSync(path.join(root, 'capture-report.json'), JSON.stringify(report, null, 2));
    console.log('CAPTURE REPORT ' + path.join(root, 'capture-report.json'));
    succeeded = true;
  } catch (error) {
    console.error('[CAPTURE ERROR] ' + (error.stack || error.message || error));
    console.error('[ISOLATED ROOT] ' + root);
    process.exitCode = 1;
  } finally {
    if (session) {
      try { await session.close(); } catch (error) { console.error('[BROWSER TEARDOWN] ' + error.message); process.exitCode = 1; }
    }
    try { await stopServer(); } catch (error) { console.error('[SERVER TEARDOWN] ' + error.message); process.exitCode = 1; }
    try { fs.closeSync(logFd); } catch (error) { /* already closed */ }
    if (succeeded) console.log('DONE: three real 2x screenshots captured with backend=null.');
  }
})();
