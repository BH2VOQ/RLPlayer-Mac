// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_b9_ai_refresh.js — 1.1.4-beta9「切换专辑后 AI 整理面板仍显示上一张专辑的信息」回归判据
//
// ============================ 这个测试在证明什么 ============================
// 全部驱动生产页面里的真实函数（updateNpData / npDataReset / npDataEnsure / npAutoSummary /
// npPrefetchRelease / npPrefetchPerson / npDataRenderTabs / npDataActivate），不另写一份逻辑。
//
//   R1 切专辑/切歌后世代号 NP_DATA.req 严格递增：上一实体的在途 summary 必须失效。
//      （旧实现每次切歌把它重置回 1，迟到的旧专辑结果会被当成当前世代写进新专辑的卡片。）
//   R2 上一实体迟到的 track / release / person 结果不得出现在新实体卡片上（DOM 串台判据）。
//   R3 上一实体迟到的结果不得污染 NP_DATA.cache（数据层判据，不只 DOM）。
//   R4 新实体自己的结果仍能正常写入并显示（守卫不能把正常结果一起误杀）。
//   R5 元数据两拍回来（同一首曲目、先旧 meta 后新 meta）：旧实体迟到的结果不得占位；
//      新实体必须仍能自动发起整理（旧实体的 loading 不能把新实体挡在请求之外）。
//   R6 抽屉开着切歌：抽屉收起、旧正文清空，不留上一实体的内容。
//   R7 切换瞬间卡片立即变成新实体的本地事实 + 「整理中…」，不保留旧专辑的任何信息。
//
// 🔴 铁律 1：全程 headless，**不播放任何音频**（不调 /api/play，settings 预置 backend=null）。
// 🔴 铁律 2：浏览器进程由 uibrowser 核验属主后 SIGTERM，绝不 force-kill；测试服务器只停自己 spawn 的子进程。
//
// 用法：node tools/check_b9_ai_refresh.js [--binary build-mac/rtaweb]
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const { spawn, execFileSync } = require('child_process');
const ub = require('./uibrowser');

const binaryIdx = process.argv.indexOf('--binary');
const binary = binaryIdx !== -1
  ? path.resolve(process.argv[binaryIdx + 1])
  : path.resolve(__dirname, '../build-mac/rtaweb');
const port = 19144;                       // 测试后端端口（远离用户实例 8899；CDP 端口由 uibrowser 随机分配）
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-b9-ai-'));
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
  'backend=null\nmetaon=0\nmetallm=0\nmetasummary=1\nvolume=-120\n');

let child = null;
let session = null;
let fail = 0, total = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function ck(ok, what, detail) {
  total++;
  if (!ok) fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${what}${detail ? '  ' + detail : ''}`);
}

function stopOwnedServer() {
  if (!child || child.exitCode !== null) return;
  try {
    const own = execFileSync('ps', ['-p', String(child.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
    const m = own.match(/^(\d+)\s+(\d+)\s+(.+)$/);
    if (!m || +m[1] !== process.getuid() || +m[2] !== process.pid || path.basename(m[3]) !== path.basename(binary)) {
      console.error('cleanup: server identity changed, no signal sent');
      return;
    }
    child.kill('SIGTERM');
  } catch (e) {
    console.error('cleanup:', e.message);
  }
}

(async () => {
  try {
    await new Promise((resolve, reject) => {
      const srv = net.createServer();
      srv.once('error', reject);
      srv.listen(port, '127.0.0.1', () => srv.close(resolve));
    });
    child = spawn(binary, ['--port', String(port), '--music-dir', path.join(root, 'music')], { env, cwd: root, stdio: 'ignore' });
    let up = false;
    for (let i = 0; i < 120; i++) {
      try { if ((await fetch(`http://127.0.0.1:${port}/api/ping`)).ok) { up = true; break; } } catch (e) { /* 还没起来 */ }
      await sleep(100);
    }
    if (!up) throw new Error('后端没有起来（port=' + port + '）');

    session = await ub.open({ url: `http://127.0.0.1:${port}/`, width: 1280, height: 800, settleMs: 2000 });
    const ready = await session.waitFor(
      "typeof updateNpData==='function' && typeof npDataEnsure==='function' && typeof npAutoSummary==='function' && !!document.getElementById('npTabs')",
      15000);
    if (!ready) throw new Error('页面没起来（找不到 updateNpData/npDataEnsure/npAutoSummary/#npTabs）: ' + await session.eval('location.href'));
    const ev = (x) => session.eval(x);

    // 单曲页必须真实可见：npDataEnsure 的完成回调会检查 #npPage.on（与线上路径一致）。
    await ev('(function(){ if (typeof openNowPlaying === "function") openNowPlaying(); return 1; })()');
    await sleep(600);

    /* ---------------- 测试装置：把 summaryOnce 换成可控桩（模拟 AI 生成 10~30s 才回来） ---------------- */
    await ev(`(function(){
      window.__t = { pending: [] };
      window.summaryOnce = function (url, cb) { __t.pending.push({ url: url, cb: cb }); };
      META.summary = 1; META.hasLlmKey = true;
      NP_DATA = { key: '', active: '', tabs: [], cache: {}, inflight: {}, req: 0, bodyKey: '', tabSig: null };
      function meta(title, artist, album) {
        return { title: title, artist: artist, album: album, albumArtist: artist,
                 codec: 'flac', sampleRate: 44100, bits: 16, summaryAvailable: true };
      }
      window.__t.meta = meta;
      return 1;
    })()`);

    /* ---------------- R7 基线：专辑 A 在播，右栏是 A 的三个栏目 ---------------- */
    const a = await ev(`(function(){
      var metaA = __t.meta('A1', 'ArtistA', 'AlbumA');
      S.lastCur = '/music/A/01.flac'; S.curMeta = metaA;
      updateNpData(metaA);
      return { req: NP_DATA.req,
               tabs: NP_DATA.tabs.map(function (t) { return t.k + '=' + t.name; }),
               cards: (document.getElementById('npTabs') || {}).textContent || '',
               hint: (document.getElementById('npSummHint') || {}).textContent || '' };
    })()`);
    ck(a && a.tabs.join(',') === 'track=A1,release=AlbumA,person=ArtistA',
      'R7 基线：右栏栏目来自当前专辑 A', JSON.stringify(a && a.tabs));

    /* ---------------- 切到专辑 B：旧 A 的 summary 仍在飞 ---------------- */
    const b = await ev(`(function(){
      var before = __t.pending.length;
      var metaB = __t.meta('B1', 'ArtistB', 'AlbumB');
      S.lastCur = '/music/B/01.flac'; S.curMeta = metaB;
      updateNpData(metaB);
      return { req: NP_DATA.req, oldPending: before,
               tabs: NP_DATA.tabs.map(function (t) { return t.k + '=' + t.name; }),
               cards: (document.getElementById('npTabs') || {}).textContent || '',
               hint: (document.getElementById('npSummHint') || {}).textContent || '' };
    })()`);
    ck(a && b && b.req > a.req, 'R1 切专辑后世代号严格递增（旧在途请求失效）', 'A.req=' + (a && a.req) + ' B.req=' + (b && b.req));
    ck(b && b.tabs.join(',') === 'track=B1,release=AlbumB,person=ArtistB',
      'R7 切专辑后栏目立即换成本专辑 B 的实体', JSON.stringify(b && b.tabs));
    ck(b && /整理中/.test(b.cards) && /ArtistB/.test(b.cards) && !/ArtistA|AlbumA/.test(b.cards),
      'R7 卡片立即换成 B 的本地事实 + 整理中…，不保留 A 的信息', JSON.stringify(b && b.cards));
    ck(b && /正在后台整理歌曲资料/.test(b.hint), 'R7 状态行提示正在后台整理新专辑资料', JSON.stringify(b && b.hint));

    /* ---------------- 旧专辑 A 的结果迟到：不得串台 ---------------- */
    const stale = await ev(`(function(){
      function fieldsFor(url) {
        if (/kind=track/.test(url)) return { '演唱': 'OLD-A-SINGER', '作曲': 'OLD-A-COMPOSER' };
        if (/kind=release/.test(url)) return { '出版方': 'OLD-A-LABEL' };
        return { '国籍': 'OLD-A-COUNTRY' };
      }
      __t.pending.slice(0, ${b.oldPending}).forEach(function (p) {
        try { p.cb({ ok: true, fields: fieldsFor(p.url), summaryCached: false }); } catch (e) { }
      });
      return { cache: JSON.stringify(NP_DATA.cache) };
    })()`);
    await sleep(900);   // release 预览还要等 npLocalAlbum（本地曲库查询）异步回来
    const afterStale = await ev(`(function(){
      return { cards: (document.getElementById('npTabs') || {}).textContent || '',
               cache: JSON.stringify(NP_DATA.cache) };
    })()`);
    ck(afterStale && !/OLD-A-/.test(afterStale.cards),
      'R2 上一张专辑迟到的 track/release/person 不得出现在新专辑卡片上', JSON.stringify(afterStale && afterStale.cards));
    ck(afterStale && !/OLD-A-/.test(afterStale.cache),
      'R3 上一张专辑迟到的结果不得写进 NP_DATA.cache', JSON.stringify(String(afterStale && afterStale.cache).slice(0, 160)));

    /* ---------------- 新专辑 B 自己的结果仍要能落地 ---------------- */
    const fresh = await ev(`(function(){
      var hit = null;
      __t.pending.forEach(function (p) { if (/kind=track/.test(p.url) && /name=B1/.test(p.url)) hit = p; });
      if (!hit) return { fired: false };
      hit.cb({ ok: true, fields: { '演唱': 'B-SINGER' }, summaryCached: false });
      return { fired: true, cache: JSON.stringify(NP_DATA.cache['track'] || null),
               busy: !!(NP_DATA.inflight && Object.keys(NP_DATA.inflight).length) };
    })()`);
    const freshUi = await ev(`(function(){
      return { cards: (document.getElementById('npTabs') || {}).textContent || '' };
    })()`);
    ck(fresh && fresh.fired && /B-SINGER/.test(freshUi.cards) && /已整理/.test(freshUi.cards),
      'R4 新专辑自己的摘要结果仍会写入并显示（守卫不误杀）', JSON.stringify(freshUi && freshUi.cards));

    /* ---------------- R5 元数据两拍：同一首曲目、实体已换 ---------------- */
    const twoBeat = await ev(`(function(){
      // 第一拍：点开新专辑 C 的曲目，但 loadMeta 还没回来（curMeta 仍是 B）
      var metaB = __t.meta('B1', 'ArtistB', 'AlbumB');
      S.lastCur = '/music/C/01.flac'; S.curMeta = metaB;
      var mark = __t.pending.length;
      updateNpData(metaB);
      var first = { tabs: NP_DATA.tabs.map(function (t) { return t.k + '=' + t.name; }), mark: mark };
      // 第二拍：真正的 C 元数据回来
      var metaC = __t.meta('C1', 'ArtistC', 'AlbumC');
      S.curMeta = metaC;
      updateNpData(metaC);
      return { first: first,
               req: NP_DATA.req,
               tabs: NP_DATA.tabs.map(function (t) { return t.k + '=' + t.name; }),
               reqs: __t.pending.slice(first.mark).map(function (p) { return p.url; }) };
    })()`);
    ck(twoBeat && twoBeat.tabs.join(',') === 'track=C1,release=AlbumC,person=ArtistC',
      'R5 元数据两拍后栏目以新实体 C 为准', JSON.stringify(twoBeat && twoBeat.tabs));
    ck(twoBeat && twoBeat.reqs.some(function (u) { return /kind=track/.test(u) && /name=C1/.test(u); }),
      'R5 新实体的自动整理仍会发起（旧实体的 loading 不得挡住它）', JSON.stringify(twoBeat && twoBeat.reqs));
    const oldBeat = await ev(`(function(){
      var hit = null;
      __t.pending.forEach(function (p) { if (/kind=track/.test(p.url) && /name=B1/.test(p.url)) hit = p; });
      if (hit) hit.cb({ ok: true, fields: { '演唱': 'OLD-B-SINGER' }, summaryCached: false });
      return { fired: !!hit, cards: (document.getElementById('npTabs') || {}).textContent || '' };
    })()`);
    ck(oldBeat && oldBeat.fired && !/OLD-B-SINGER/.test(oldBeat.cards),
      'R5 旧实体（两拍前的 B1）迟到的结果不得占据 C1 的卡片', JSON.stringify(oldBeat && oldBeat.cards));
    const newBeat = await ev(`(function(){
      var hit = null;
      __t.pending.forEach(function (p) { if (/kind=track/.test(p.url) && /name=C1/.test(p.url)) hit = p; });
      if (hit) hit.cb({ ok: true, fields: { '演唱': 'C-SINGER' }, summaryCached: false });
      return { fired: !!hit, cards: (document.getElementById('npTabs') || {}).textContent || '' };
    })()`);
    ck(newBeat && newBeat.fired && /C-SINGER/.test(newBeat.cards),
      'R5 两拍场景下新实体 C1 自己的结果仍能显示', JSON.stringify(newBeat && newBeat.cards));

    /* ---------------- R6 抽屉开着切专辑：收起 + 正文清空 ---------------- */
    const drawer = await ev(`(function(){
      npDataActivate('track');
      var openBefore = !!(document.getElementById('npDrawer') && document.getElementById('npDrawer').classList.contains('on'));
      var metaD = __t.meta('D1', 'ArtistD', 'AlbumD');
      S.lastCur = '/music/D/01.flac'; S.curMeta = metaD;
      updateNpData(metaD);
      return { openBefore: openBefore,
               openAfter: !!(document.getElementById('npDrawer') && document.getElementById('npDrawer').classList.contains('on')),
               body: (document.getElementById('npDataBody') || {}).textContent || '',
               req: NP_DATA.req, cards: (document.getElementById('npTabs') || {}).textContent || '' };
    })()`);
    ck(drawer && drawer.openBefore === true && drawer.openAfter === false,
      'R6 抽屉开着切专辑：抽屉收起', JSON.stringify(drawer && { before: drawer.openBefore, after: drawer.openAfter }));
    ck(drawer && !/C-SINGER|ArtistC|AlbumC/.test(drawer.body),
      'R6 抽屉正文不残留上一实体的内容', JSON.stringify(String(drawer && drawer.body).slice(0, 120)));
    ck(drawer && /ArtistD|AlbumD/.test(drawer.cards) && !/C-SINGER/.test(drawer.cards),
      'R6 切到 D 后卡片只显示 D 的实体', JSON.stringify(drawer && drawer.cards));

    /* ---------------- R1 收尾：多次切换世代号持续递增 ---------------- */
    ck(a && b && drawer && drawer.req > twoBeat.req && twoBeat.req > b.req && b.req > a.req,
      'R1 多次切专辑世代号始终单调递增（A<B<C<D）',
      JSON.stringify({ A: a && a.req, B: b && b.req, C: twoBeat && twoBeat.req, D: drawer && drawer.req }));

    await session.close();
    session = null;
  } catch (e) {
    console.error('FATAL: ' + (e && e.stack || e));
    fail++;
  } finally {
    if (session) { try { await session.close(); } catch (e) { } }
    stopOwnedServer();
  }
  console.log(`\n${total - fail}/${total} passed`);
  process.exit(fail === 0 ? 0 : 1);
})();
