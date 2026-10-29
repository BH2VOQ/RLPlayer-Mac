// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_stream_album.js — 流媒体「点进专辑 = 本地专辑详情页那套」的**真实 DOM 断言**。
//
// 环境（全部隔离，绝不碰用户真实配置/服务器）：
//   · 真 build-mac/rtaweb（本次改动重新编译过的二进制），端口 19096（起之前用 lsof 只读确认空闲）；
//   · 假 Subsonic/Navidrome（tools/mock_subsonic_album.js）：1 艺术家 → 1 专辑 → 3 首曲目；
//   · HOME / RLPLAYER_STATE_DIR / RLPLAYER_LIBRARY_DIR / TMPDIR 全部指到 /tmp/rlplayer-stream-album-<pid>；
//   · headless Edge（tools/uibrowser.js）。
//
// 铁律 1（绝不能真的播放音频）：页面侧给 window.fetch 打补丁 —— /api/play 与 /api/add
//   **只记录、永不发出**，直接返回一个合成 {ok:true}。
//   为什么不是 abort：abort（reject）会让 api() 立刻回 _err，串行的「整张入队」链在第 1 条就停，
//   「播放整张 = 3 条 add」这条断言就永远无法成立。合成成功同样一个字节都没出浏览器，
//   请求形状照样能逐条断言；另外还补了一条**后端侧**的硬证据：跑完后真后端 /api/queue 仍为空
//   （= 没有任何 add/play 真的到达后端）。
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawn, execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');                    // 仓库根
// 2026-10-29：允许 --binary 指定任意构建目录的 rtaweb（默认仍是 build-mac）。
// 为什么改：合并到 main 后验证时，main 的 build-mac 可能是别人构建的旧二进制，
// 硬编码会让判据测到旧 UI 上（本轮实测过：A1/A2/B0 全红其实是二进制过期，不是回归）。
const ARGV = process.argv.slice(2);
function argOf(name, dflt) { const i = ARGV.indexOf(name); return (i >= 0 && ARGV[i + 1]) ? ARGV[i + 1] : dflt; }
const rtawebOverride = argOf('--binary', '');
const REPO = path.dirname(path.resolve(rtawebOverride || path.join(ROOT, 'build-mac', 'rtaweb')));
const ub = require(path.join(ROOT, 'tools/uibrowser.js'));
const mock = require(path.join(ROOT, 'tools/mock_subsonic_album.js'));

const PORT = 19096;
const EVID = path.join(REPO, 'stream-evidence', 'album');
const SANDBOX = path.join('/tmp', 'rlplayer-stream-album-' + process.pid);
const RESULTS = [];
const SHOTS = [];

function ok(name, pass, detail) {
  RESULTS.push({ name, pass: !!pass, detail });
  console.log((pass ? 'PASS  ' : 'FAIL  ') + name + (detail === undefined ? '' : '  ' + JSON.stringify(detail)));
  return !!pass;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 端口占用检查：先跑 lsof（只读），再试着自己 bind 一次（双保险）。
function lsofListeners(port) {
  try {
    const out = execFileSync('/usr/sbin/lsof', ['-nP', '-iTCP:' + port, '-sTCP:LISTEN'], { encoding: 'utf8' });
    return out.split('\n').filter((l) => l.trim()).slice(1);
  } catch (e) {
    return [];    // lsof 无匹配时退出码 1 → 视为空闲
  }
}
async function portFree(port) {
  return new Promise((resolve) => {
    const srv = http.createServer();
    srv.once('error', () => resolve(false));
    srv.once('listening', () => srv.close(() => resolve(true)));
    srv.listen(port, '127.0.0.1');
  });
}
async function waitHttp(url, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    try {
      const r = await fetch(url);
      if (r.ok) return true;
    } catch (e) { /* 还没起来 */ }
    await sleep(200);
  }
  return false;
}
function mkdirs(p) { fs.mkdirSync(p, { recursive: true }); return p; }
// 从一条记录里取参数：POST 的表单体在 body 里（/api/play、/api/add 都是 POST + 表单），
// 查询串只是兜底 —— 只读 url 会全部读成 null。
function q(req, key) {
  try {
    const b = new URLSearchParams(req.body || '').get(key);
    if (b !== null) return b;
  } catch (e) { /* 不是表单体 */ }
  try { return new URL('http://x' + req.url).searchParams.get(key); } catch (e) { return null; }
}

// 页面侧补丁：/api/play 与 /api/add 只记录、不发网络；其余请求原样放行。
const PATCH_JS = `(() => {
  if (window.__RLPATCH) return true;
  window.__RLPATCH = true;
  window.__RLREQ = window.__RLREQ || [];
  var raw = window.fetch.bind(window);
  window.fetch = function (u, o) {
    var url = String(u);
    if (url.indexOf('/api/play') === 0 || url.indexOf('/api/add') === 0) {
      window.__RLREQ.push({ url: url, method: (o && o.method) || 'GET', body: (o && o.body) || '' });
      return Promise.resolve(new Response(JSON.stringify({ ok: true }),
        { status: 200, headers: { 'Content-Type': 'application/json' } }));
    }
    return raw(u, o);
  };
  return true;
})()`;

async function main() {
  mkdirs(SANDBOX); mkdirs(EVID);
  const home = mkdirs(path.join(SANDBOX, 'home'));
  const state = mkdirs(path.join(SANDBOX, 'state'));
  const lib = mkdirs(path.join(SANDBOX, 'library'));        // 空音乐库（本地库与流媒体互不干扰）
  const music = mkdirs(path.join(SANDBOX, 'empty-music'));
  const tmp = mkdirs(path.join(SANDBOX, 'tmp'));

  const listeners = lsofListeners(PORT);
  if (listeners.length) throw new Error('端口 ' + PORT + ' 已被占用，拒绝在别人的实例上做断言：\n' + listeners.join('\n'));
  if (!(await portFree(PORT))) throw new Error('端口 ' + PORT + ' bind 失败（lsof 没报但确实占着）');

  const ms = await mock.start();
  console.log('mock subsonic: http://127.0.0.1:' + ms.port);

  // 只写进隔离状态目录：v2 格式，active=1 指向 mock
  fs.writeFileSync(path.join(state, 'rlplayer-sources.conf'),
    'version=2\nnextid=2\nactive=1\n' +
    'srv1.name=MockSub\nsrv1.kind=subsonic\n' +
    'srv1.base=http://127.0.0.1:' + ms.port + '\n' +
    'srv1.user=' + mock.USER + '\nsrv1.pass=' + mock.PASS + '\n');

  const exe = path.join(REPO, 'rtaweb');
  const logPath = path.join(EVID, 'rtaweb.log');
  const logFd = fs.openSync(logPath, 'w');
  const child = spawn(exe, ['--port', String(PORT), '--no-browser', '--music-dir', music], {
    env: Object.assign({}, process.env, {
      HOME: home, RLPLAYER_STATE_DIR: state, RLPLAYER_LIBRARY_DIR: lib, TMPDIR: tmp,
    }),
    stdio: ['ignore', logFd, logFd],
  });
  let childExit = null;
  child.on('exit', (code, sig) => { childExit = { code, sig }; });
  const stopChild = async () => {
    if (childExit) return childExit;
    child.kill('SIGTERM');
    for (let i = 0; i < 100 && !childExit; i++) await sleep(100);
    return childExit;
  };

  let browser = null;
  const report = { sandbox: SANDBOX, mockPort: ms.port, port: PORT, results: RESULTS, shots: SHOTS };
  try {
    if (!(await waitHttp('http://127.0.0.1:' + PORT + '/', 30000)))
      throw new Error('rtaweb 未在 30s 内起来，见 ' + logPath);

    process.env.TMPDIR = tmp;
    browser = await ub.open({ width: 1440, height: 900 });
    const ev = (s) => browser.eval(s);
    const shot = async (n) => { const p = path.join(EVID, n); await browser.shot(p); SHOTS.push(p); return p; };
    const reqs = () => ev('window.__RLREQ || []');
    const mark = async () => (await reqs()).length;
    const since = async (m) => (await reqs()).slice(m);
    const waitReqs = (n, ms2 = 8000) => browser.waitFor('(window.__RLREQ||[]).length>=' + n, ms2);

    await browser.send('Page.navigate', { url: 'http://127.0.0.1:' + PORT + '/' });
    if (!(await browser.waitFor('typeof setView === "function" && !!document.getElementById("list")', 20000)))
      throw new Error('UI 没 ready');
    await ev(PATCH_JS);

    // 页面里的通用点击助手：按可见文字点某一层条目 / 点按钮
    await ev(`(() => {
      window.__clickEntry = function (text) {
        var list = [...document.querySelectorAll('#list [data-r]')];
        var e = list.find(function (x) { return (x.innerText || '').indexOf(text) >= 0; });
        if (!e) return false;
        e.click(); return true;
      };
      return true;
    })()`);

    // ---------- A：目录层（不能因为新增专辑页而回退） ----------
    await ev("setView('remote'); loadRemote('');");
    ok('A1 根目录仍是网格（.grid.rgrid + 1 张艺术家卡）',
      await browser.waitFor("!!document.querySelector('#list .grid.rgrid') && document.querySelectorAll('#list .card').length===1", 15000),
      await ev("({grid:!!document.querySelector('#list .grid.rgrid'),cards:document.querySelectorAll('#list .card').length})"));
    await shot('01-root-grid.png');

    await ev(`window.__clickEntry(${JSON.stringify(mock.ARTIST)})`);
    ok('A2 点艺术家卡进入艺术家层（2 张卡：专辑 + 空目录）',
      await browser.waitFor("!!document.querySelector('#list .grid.rgrid') && document.querySelectorAll('#list .card').length===2", 15000),
      await ev("({cards:document.querySelectorAll('#list .card').length,text:document.getElementById('list').innerText})"));
    const a3 = await ev("({ahead:!!document.querySelector('#list .ahead'), trows:document.querySelectorAll('#list .trow').length})");
    ok('A3 艺术家层**没有**被误判成专辑页（无 .ahead / 无 .trow）', a3.ahead === false && a3.trows === 0, a3);
    await shot('02-artist-grid.png');

    // ---------- B：进入专辑 = 本地专辑页那套详情页 ----------
    await ev(`window.__clickEntry(${JSON.stringify(mock.ALBUM)})`);
    ok('B0 点专辑卡 → 出现 .ahead（子项全是曲目 ⟹ 专辑层判定生效）',
      await browser.waitFor("!!document.querySelector('#list .ahead') && document.querySelectorAll('#list .trow').length===3", 15000),
      await ev("({ahead:!!document.querySelector('#list .ahead'),trows:document.querySelectorAll('#list .trow').length})"));

    const b1 = await ev(`(() => {
      const ah = document.querySelector('#list .ahead');
      const cv = ah.querySelector('.cv'), ph = ah.querySelector('.cv .ph'), info = ah.querySelector('.info');
      const img = ah.querySelector('.cv img');
      const r = img ? img.getBoundingClientRect() : null;
      const cvr = cv.getBoundingClientRect();
      return {
        cvBox: [Math.round(cvr.width), Math.round(cvr.height)],
        cvRadius: getComputedStyle(cv).borderRadius,
        ph: ph ? ph.innerText : null,
        imgSrc: img ? img.getAttribute('src') : null,
        imgComplete: img ? img.complete : null,
        imgNatural: img ? [img.naturalWidth, img.naturalHeight] : null,
        imgBox: r ? [Math.round(r.width), Math.round(r.height)] : null,
        imgRadius: img ? getComputedStyle(img).borderRadius : null,
        kind: (info.querySelector('.kind') || {}).innerText,
        h1: (info.querySelector('h1') || {}).innerText,
        sub: (info.querySelector('.sub') || {}).innerText,
      };
    })()`);
    ok('B1 大封面头与本地专辑页同源（.ahead .cv = 168×168、圆角 12px、首字母占位「远」）',
      b1.cvBox[0] === 168 && b1.cvBox[1] === 168 && b1.cvRadius === '12px' && b1.ph === '远',
      { box: b1.cvBox, radius: b1.cvRadius, ph: b1.ph });
    ok('B2 封面 img 指向 /api/src/cover?id=al1 且已解码（naturalWidth>0、盒子非 0）',
      /^\/api\/src\/cover\?id=al1$/.test(b1.imgSrc || '') && b1.imgComplete === true &&
      b1.imgNatural && b1.imgNatural[0] > 0 && b1.imgBox && b1.imgBox[0] > 0,
      { src: b1.imgSrc, complete: b1.imgComplete, natural: b1.imgNatural, box: b1.imgBox });
    ok('B3 h1 = 专辑名（来自导航栈里的那一项，不是曲目名）', b1.h1 === mock.ALBUM, b1.h1);
    ok('B4 头部标签是 ALBUM', b1.kind === 'ALBUM', b1.kind);
    ok('B5 .sub = 艺术家 · N 首 · 总时长（含「3 首」与 10:20）',
      b1.sub.indexOf(mock.ARTIST) >= 0 && b1.sub.indexOf('3 首') >= 0 && b1.sub.indexOf('10:20') >= 0, b1.sub);

    const b2 = await ev(`(() => {
      const head = document.querySelector('#list .trlist-head');
      const rows = [...document.querySelectorAll('#list .trow')];
      const texts = document.getElementById('list').innerText;
      return {
        headLb: head ? head.querySelector('.lb').innerText : null,
        headSum: head ? head.querySelector('.sum').innerText : null,
        n: rows.map(function (r) { return r.querySelector('.n').innerText; }),
        tt: rows.map(function (r) { return r.querySelector('.tt').innerText; }),
        ar: rows.map(function (r) { return r.querySelector('.ar').innerText; }),
        du: rows.map(function (r) { return r.querySelector('.du').innerText; }),
        addBtns: document.querySelectorAll('#list .trow .add-btn').length,
        addBtnBox: (() => { const b = document.querySelector('#list .trow .add-btn'); if (!b) return null; const r = b.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)]; })(),
        btns: {
          playAll: (document.getElementById('ralbPlayAll') || {}).innerText,
          add: (document.getElementById('ralbAdd') || {}).innerText,
          shuf: (document.getElementById('ralbShuf') || {}).innerText,
        },
        setCover: !!document.getElementById('aSetCover') || texts.indexOf('设置封面') >= 0,
        fav: document.querySelectorAll('#list .fav-btn').length,
        back: !!document.getElementById('rBackDir'),
        backText: (document.getElementById('rBackDir') || {}).innerText,
        backBox: (() => { const b = document.getElementById('rBackDir'); if (!b) return null; const r = b.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)]; })(),
        rowCols: rows.length ? getComputedStyle(rows[0]).gridTemplateColumns : null,
      };
    })()`);
    ok('B6 表头「曲目列表 / 3 首 · 总时长 10:20」', b2.headLb === '曲目列表' && b2.headSum === '3 首 · 总时长 10:20', [b2.headLb, b2.headSum]);
    ok('B7 .trow 行数 = 3，序号 1/2/3', b2.n.join(',') === '1,2,3', b2.n);
    ok('B8 每行四列内容：标题 / 艺术家 / 时长（3:20 3:00 4:00）',
      b2.tt.join('|') === mock.TRACKS.map((t) => t.title).join('|') &&
      b2.ar.every((x) => x === mock.ARTIST) &&
      b2.du.join(',') === '3:20,3:00,4:00', { tt: b2.tt, ar: b2.ar, du: b2.du });
    ok('B9 每行都有「+」入队按钮且可点（22×22）', b2.addBtns === 3 && b2.addBtnBox && b2.addBtnBox[0] > 0, { n: b2.addBtns, box: b2.addBtnBox });
    ok('B10 三个操作按钮文案 = ▶ 播放整张 / 加入队列 / 随机播放',
      b2.btns.playAll === '\u25b6 播放整张' && b2.btns.add === '加入队列' && b2.btns.shuf === '随机播放', b2.btns);
    ok('B11 本地页独有的「设置封面 / 心形收藏」没有搬过来', b2.setCover === false && b2.fav === 0, { setCover: b2.setCover, fav: b2.fav });
    ok('B12 顶部有可点的「← 返回上一级」入口', b2.back && b2.backText.indexOf('返回上一级') >= 0 && b2.backBox[0] > 0, { text: b2.backText, box: b2.backBox });
    await shot('03-album-detail.png');

    // ---------- C：点第 2 行 → 只播第 2 首 ----------
    let m0 = await mark();
    await ev("document.querySelectorAll('#list .trow')[1].click()");
    await waitReqs(m0 + 1);
    await sleep(300);
    const c1 = await since(m0);
    const c1play = c1.filter((r) => r.url.indexOf('/api/play') === 0);
    ok('C1 点第 2 行 → 恰好 1 条 /api/play，rid=s2 且带 rsuffix/rtitle',
      c1play.length === 1 && q(c1play[0], 'rid') === 's2' &&
      q(c1play[0], 'rsuffix') === 'flac' && q(c1play[0], 'rtitle') === mock.TRACKS[1].title &&
      c1play[0].method === 'POST', c1);
    ok('C2 单曲点击不发 /api/add', c1.filter((r) => r.url.indexOf('/api/add') === 0).length === 0, c1.length);
    await shot('04-row-click-play.png');

    // ---------- D：行内「+」只入队、不播放（stopPropagation + 行号映射） ----------
    // 刻意点**第 3 行**的「+」：如果 data-i / 行号映射接错，入队的会是第 1 首（或干脆不入队）。
    const dRow = await ev("(() => { const r = document.querySelectorAll('#list .trow')[2]; const b = r.querySelector('.add-btn'); return { i: b.dataset.i, n: r.querySelector('.n').innerText, tt: r.querySelector('.tt').innerText }; })()");
    m0 = await mark();
    await ev("document.querySelectorAll('#list .trow .add-btn')[2].click()");
    await waitReqs(m0 + 1);
    await sleep(400);
    const d1 = await since(m0);
    const d1add = d1.filter((r) => r.url.indexOf('/api/add') === 0);
    ok('D1 点第 3 行「+」→ 恰好 1 条 /api/add（rid=s3、rsuffix=flac、rtitle=远程曲目三）',
      dRow.i === '2' && dRow.n === '3' && d1add.length === 1 && q(d1add[0], 'rid') === 's3' &&
      q(d1add[0], 'rsuffix') === 'flac' && q(d1add[0], 'rtitle') === mock.TRACKS[2].title &&
      d1add[0].method === 'POST', { row: dRow, reqs: d1 });
    ok('D2 「+」没有冒泡成播放（0 条 /api/play）', d1.filter((r) => r.url.indexOf('/api/play') === 0).length === 0, d1);
    await shot('05-add-one.png');

    // ---------- E：播放整张 = 3 条 add（顺序）+ 1 条 play（第 1 首） ----------
    m0 = await mark();
    await ev("document.getElementById('ralbPlayAll').click()");
    await waitReqs(m0 + 4, 10000);
    await sleep(500);
    const e1 = await since(m0);
    const e1add = e1.filter((r) => r.url.indexOf('/api/add') === 0);
    const e1play = e1.filter((r) => r.url.indexOf('/api/play') === 0);
    ok('E1 「播放整张」= 3 条 /api/add，rid 顺序 s1→s2→s3，每条都带 rsuffix+rtitle',
      e1add.length === 3 &&
      e1add.map((r) => q(r, 'rid')).join(',') === 's1,s2,s3' &&
      e1add.every((r) => q(r, 'rsuffix') === 'flac') &&
      e1add.map((r) => q(r, 'rtitle')).join('|') === mock.TRACKS.map((t) => t.title).join('|'),
      e1add.map((r) => ({ rid: q(r, 'rid'), sf: q(r, 'rsuffix'), t: q(r, 'rtitle') })));
    ok('E2 之后恰好 1 条 /api/play 且指向第 1 首（s1）',
      e1play.length === 1 && q(e1play[0], 'rid') === 's1' &&
      q(e1play[0], 'rtitle') === mock.TRACKS[0].title, e1play);
    ok('E3 顺序正确：play 出现在 3 条 add 全部之后',
      e1.length === 4 && e1[3].url.indexOf('/api/play') === 0,
      e1.map((r) => r.url.split('?')[0]));
    await shot('06-play-all.png');

    // ---------- F：加入队列 = 3 条 add、0 条 play ----------
    m0 = await mark();
    await ev("document.getElementById('ralbAdd').click()");
    await waitReqs(m0 + 3, 10000);
    await sleep(500);
    const f1 = await since(m0);
    ok('F1 「加入队列」= 3 条 /api/add，0 条 /api/play',
      f1.filter((r) => r.url.indexOf('/api/add') === 0).length === 3 &&
      f1.filter((r) => r.url.indexOf('/api/play') === 0).length === 0,
      f1.map((r) => r.url.split('?')[0]));
    const f2 = await ev("document.getElementById('toast').textContent");
    ok('F2 提示「整张专辑已加入队列」', f2 === '整张专辑已加入队列', f2);
    await shot('07-enqueue-all.png');

    // ---------- G：随机播放 = 3 条 add + 1 条 play（起点在 3 首之内） ----------
    m0 = await mark();
    await ev("document.getElementById('ralbShuf').click()");
    await waitReqs(m0 + 4, 10000);
    await sleep(500);
    const g1 = await since(m0);
    const g1play = g1.filter((r) => r.url.indexOf('/api/play') === 0);
    ok('G1 「随机播放」= 3 条 /api/add + 1 条 /api/play，起点是这 3 首之一',
      g1.filter((r) => r.url.indexOf('/api/add') === 0).length === 3 && g1play.length === 1 &&
      ['s1', 's2', 's3'].indexOf(q(g1play[0], 'rid')) >= 0, g1play.map((r) => q(r, 'rid')));
    await shot('08-shuffle.png');

    // ---------- H：返回上一级 ----------
    await ev("document.getElementById('rBackDir').click()");
    ok('H1 点「返回上一级」→ 回到艺术家层网格（.rgrid + 2 张卡，.ahead 消失）',
      await browser.waitFor("!!document.querySelector('#list .grid.rgrid') && document.querySelectorAll('#list .card').length===2 && !document.querySelector('#list .ahead')", 15000),
      await ev("({grid:!!document.querySelector('#list .grid.rgrid'),cards:document.querySelectorAll('#list .card').length,ahead:!!document.querySelector('#list .ahead')})"));
    const h2 = await ev("({tog:!!document.querySelector('#remoteView'), on:(document.querySelector('#remoteView .rvbtn.on')||{dataset:{}}).dataset.rmv})");
    ok('H2 网格/列表切换控件恢复且仍是网格', h2.tog === true && h2.on === 'grid', h2);
    await shot('09-back-to-artist-grid.png');

    // 列表模式下进专辑 → 返回，显示方式不能被详情页改掉
    await ev("document.querySelector('#remoteView .rvbtn[data-rmv=list]').click()");
    ok('H3 切到列表后艺术家层是行式（2 行目录 + 返回行）',
      await browser.waitFor("!document.querySelector('#list .grid') && document.querySelectorAll('#list .rowdir').length===3", 8000),
      await ev("({rows:document.querySelectorAll('#list .row').length,rowdir:document.querySelectorAll('#list .rowdir').length})"));
    await ev(`window.__clickEntry(${JSON.stringify(mock.ALBUM)})`);
    const h3b = await browser.waitFor("!!document.querySelector('#list .ahead')", 12000);
    await ev("document.getElementById('rBackDir').click()");
    const h4ok = await browser.waitFor("!document.querySelector('#list .grid') && document.querySelectorAll('#list .rowdir').length===3", 12000);
    const h4 = await ev("({grid:!!document.querySelector('#list .grid'), rowdir:document.querySelectorAll('#list .rowdir').length, stored:localStorage.getItem('rlplayer-remote-view'), on:(document.querySelector('#remoteView .rvbtn.on')||{dataset:{}}).dataset.rmv})");
    ok('H4 列表模式下进专辑再返回，仍是列表（无 .rgrid、localStorage=rlplayer-remote-view:list）',
      h3b && h4ok && h4.stored === 'list' && h4.on === 'list', h4);
    await shot('10-list-mode-back.png');

    // 目录层的「返回上一级」行走的也是同一个 remoteGoBack（不是另一条老路径），必须一起验。
    await ev("(() => { const e = [...document.querySelectorAll('#list .rowdir')].find(x => x.innerText.indexOf('返回上一级') >= 0); e.click(); return true; })()");
    const h5ok = await browser.waitFor("document.getElementById('list').innerText.indexOf('返回上一级')<0 && document.querySelectorAll('#list .row').length===1", 12000);
    const h5 = await ev("({text:document.getElementById('list').innerText, rpath:S.rpath, stack:(S.rstack||[]).length})");
    ok('H5 目录层的「返回上一级」行同样能出栈回到根（根下无返回行）',
      h5ok && h5.rpath === '' && h5.stack === 0 && h5.text.indexOf(mock.ARTIST) >= 0, h5);

    await ev("document.querySelector('#remoteView .rvbtn[data-rmv=grid]').click()");
    await browser.waitFor("!!document.querySelector('#list .grid.rgrid')", 8000);

    // ---------- I：退化 / 空目录 / 错误提示 ----------
    await ev("loadRemote('al1')");
    const i1 = await browser.waitFor("!!document.querySelector('#list .ahead') && document.querySelectorAll('#list .trow').length===3", 12000);
    const i1d = await ev("({h1:(document.querySelector('#list .ahead h1')||{}).innerText, sub:(document.querySelector('#list .ahead .sub')||{}).innerText, stack:(S.rstack||[]).length, back:!!document.getElementById('rBackDir')})");
    ok('I1 直接 loadRemote(\'al1\')（无栈）不崩：仍是专辑页、h1 非空、返回入口在',
      i1 && !!i1d.h1 && i1d.stack === 0 && i1d.back === true, i1d);
    await shot('11-direct-entry.png');

    await ev("loadRemote('ar1')");
    await browser.waitFor("!!document.querySelector('#list .grid.rgrid')", 12000);
    await ev(`window.__clickEntry(${JSON.stringify(mock.EMPTY_DIR)})`);
    const i2 = await browser.waitFor("!!document.querySelector('#list .empty')", 12000);
    const i2d = await ev("({text:(document.querySelector('#list .empty')||{}).innerText, ahead:!!document.querySelector('#list .ahead'), back:!!document.querySelector('#list .rowdir')})");
    ok('I2 空目录保持原样：还是「此目录为空」空态，没被当成专辑页',
      i2 && i2d.text.indexOf('此目录为空') === 0 && i2d.ahead === false && i2d.back === true, i2d);
    await shot('12-empty-dir.png');

    await ms.close();
    await ev("loadRemote('')");
    const i3 = await browser.waitFor("document.getElementById('list').innerText.indexOf('还没有可浏览的流媒体服务器')>=0", 25000);
    const i3d = await ev("({goSet:!!document.getElementById('remoteGoSet'), retry:!!document.getElementById('remoteRetry'), ahead:!!document.querySelector('#list .ahead')})");
    ok('I3 服务器不可达：错误卡与两个入口保持原样', i3 && i3d.goSet && i3d.retry && i3d.ahead === false, i3d);
    await shot('13-error-card.png');

    // ---------- J：铁律 1 的**后端侧**证据 ----------
    // 页面把 /api/play 与 /api/add 全拦在浏览器里 ⟹ 真后端队列必须一首都没有。
    const qj = await (await fetch('http://127.0.0.1:' + PORT + '/api/queue')).json();
    ok('J1 真后端队列为空（= 没有任何 add/play 真的到达后端，铁律 1）',
      Array.isArray(qj.items) && qj.items.length === 0, { items: qj.items });
    ok('J2 全程无 JS 异常 / console.error', browser.errors.length === 0, browser.errors.slice(0, 5));
    report.browserErrors = browser.errors;
    report.backendQueue = qj;
  } catch (e) {
    report.fatal = String((e && e.stack) || e);
    console.log('FATAL ' + report.fatal);
  } finally {
    try { if (browser) await browser.close(); } catch (e) { report.browserCloseError = String(e); }
    report.childExit = await stopChild();
    try { await ms.close(); } catch (e) { }
    report.mockRequests = ms.log.length;
    report.mockPaths = [...new Set(ms.log.map((x) => x.path))];
    report.passed = RESULTS.filter((r) => r.pass).length;
    report.failed = RESULTS.filter((r) => !r.pass).map((r) => r.name);
    fs.writeFileSync(path.join(EVID, 'report.json'), JSON.stringify(report, null, 2));
    console.log('\n通过 ' + report.passed + ' / ' + RESULTS.length + ' 条断言');
    if (report.failed.length) console.log('失败：' + report.failed.join(' | '));
    console.log('截图：' + SHOTS.join(' '));
    console.log('报告：' + path.join(EVID, 'report.json'));
    process.exitCode = report.failed.length || report.fatal ? 1 : 0;
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
