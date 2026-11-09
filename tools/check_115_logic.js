// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_115_logic.js — 1.1.5-beta2 UI 纯逻辑判据（Node/vm 跑生产 JS，不开浏览器）
//
// ============================ 为什么有这个文件 ============================
// 沿用 check_b10_logic.js 的既有模式：从 src/net/ui_script.h 抽出 R"JS(...)JS" 里的
// **生产 JS**，放进最小 DOM 沙箱（vm）执行；mock fetch / Date.now / setTimeout，
// 断言全部调用生产函数（npSummUrl / albumTrackUrl / knowledgeOnce / openArtistProfile /
// npDataEnsure / npDataRenderBody / npRailHint …），绝不把实现复制进测试里。
// 铁律：全程无浏览器、无音频设备、无真实网络；断言失败 exit 1。
//
//   L1 URL 构造：track 带 album/file/genre 且编码正确；有/无 album 的 URL 不同；
//                专辑页预取 URL 与单曲页抽屉 URL 完全一致（同一份缓存）。
//   L2 knowledgeOnce 轮询单飞：同一 URL 连点 5 次只 1 次底层 fetch（pending → done）；
//                done 后每个回调各收到 1 次；120s 墙钟超时返回明确错误。
//   L3 切换实体后旧结果丢弃：ARTIST_KNOW 路径的 who 守卫 + npDataEnsure 的 npDataFp 指纹守卫。
//   L4 insufficient：UI 文案含「资料不足：缺少艺术家与曲名」且不触发第二次请求、不写缓存。
//
// 用法：node tools/check_115_logic.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const uiScriptPath = path.resolve(__dirname, '../src/net/ui_script.h');
assert(fs.existsSync(uiScriptPath), 'ui_script.h must exist at ' + uiScriptPath);
const raw = fs.readFileSync(uiScriptPath, 'utf8');
const m = raw.match(/return R"JS\(([\s\S]*?)\)JS";/);
assert(m && m[1], 'failed to extract JS from ui_script.h');
const prodJs = m[1];

let pass = 0, fail = 0;
function ck(cond, name, detail) {
  if (cond) { pass++; console.log('  [PASS] ' + name + (detail ? '  ' + detail : '')); }
  else { fail++; console.log('  [FAIL] ' + name + (detail ? '  ' + detail : '')); }
}
// 旧版生产 JS 里缺函数时记 FAIL 并跳过该段，让判据完整跑完（红得可复核，而不是半路崩掉）。
function need(e, name) {
  const ok = typeof e[name] === 'function';
  if (!ok) ck(false, name + ' 是生产函数（缺失则整组判据红）', 'missing');
  return ok;
}
const J = (o) => JSON.stringify(o);

/* ---------------- 最小 DOM 沙箱 ----------------
   比 check_b10_logic.js 略强一点：innerHTML 保留成字符串（L4 要读渲染出的文案），
   querySelectorAll 只在芯片绑定时需要，返回 [] 即可。定时器/时钟由环境表驱动，
   生产 JS 里的 setTimeout 全部落到可控队列，不真的等待墙钟时间。 */
function mkEl(id) {
  const cls = new Set();
  return {
    id: id || '', value: '', textContent: '', innerHTML: '', title: '', checked: false, disabled: false,
    tagName: 'DIV', style: {}, dataset: {}, children: [], options: [],
    classList: {
      add: (c) => cls.add(c), remove: (c) => cls.delete(c), contains: (c) => cls.has(c),
      toggle(c, f) { if (f === undefined) { cls.has(c) ? cls.delete(c) : cls.add(c); } else { f ? cls.add(c) : cls.delete(c); } return cls.has(c); }
    },
    setAttribute(k, v) { this[k] = v; },
    getAttribute(k) { return this[k] === undefined ? null : this[k]; },
    removeAttribute(k) { delete this[k]; },
    addEventListener() {}, removeEventListener() {},
    appendChild(c) { this.children.push(c); return c; },
    insertBefore(c) { this.children.push(c); return c; },
    removeChild(c) { return c; },
    hasAttribute(k) { return this[k] !== undefined; },
    cloneNode() { return mkEl(this.id); },
    querySelector() { return null; }, querySelectorAll() { return []; },
    closest() { return null; }, remove() {}, focus() {}, click() { if (this.onclick) this.onclick({ target: this, stopPropagation() {}, preventDefault() {} }); },
    getBoundingClientRect() { return { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 }; }
  };
}
function createEnv() {
  const els = {};
  const getEl = (id) => (els[id] || (els[id] = mkEl(id)));
  const ctl = {
    now: 1000000,                      // 假时钟（ms）
    seq: 0,                            // 定时器 id
    timers: [],                        // {id, at, fn}
    responses: [],                     // 每次 api/fetch 的响应（对象或函数；取完落默认 {}）
    calls: [],                         // {url, opt} 每次底层 fetch
    startup: true                      // 启动期（vm.runInContext 内）排的定时器都标记为后台轮询
  };
  const DClass = function () { this.now = ctl.now; };
  DClass.now = () => ctl.now;
  // 启动期的 pollStart()（status/queue/stats 链式轮询）会无限重排，与被测逻辑无关。
  // 只在加载生产 JS 期间把新定时器标成 background；settle 只等一次性「业务」定时器。
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    Date: DClass, Math, parseInt, parseFloat, String, Number, Boolean, Array, Object, RegExp, JSON,
    Promise, Set, Map, Error, TypeError, Symbol,
    encodeURIComponent, decodeURIComponent, isFinite, NaN, Infinity,
    setTimeout(fn, ms) {
      const t = { id: ++ctl.seq, at: ctl.now + (Number(ms) || 0), fn, background: ctl.startup };
      ctl.timers.push(t);
      return t.id;
    },
    clearTimeout(id) { ctl.timers = ctl.timers.filter((t) => t.id !== id); },
    setInterval: (fn, ms) => { const t = { id: ++ctl.seq, at: ctl.now + (Number(ms) || 0), fn, interval: true }; ctl.timers.push(t); return t.id; },
    clearInterval(id) { ctl.timers = ctl.timers.filter((t) => t.id !== id); },
    addEventListener() {}, removeEventListener() {},
    requestAnimationFrame: (f) => { try { f(); } catch (e) {} return 1; },
    MutationObserver: class { observe() {} disconnect() {} },
    IntersectionObserver: class { observe() {} disconnect() {} unobserve() {} },
    ResizeObserver: class { observe() {} disconnect() {} },
    Event: class { constructor(t) { this.type = t; } },
    XMLHttpRequest: class { open() {} setRequestHeader() {} send() {} },
    document: {
      getElementById: getEl,
      querySelector() { return null; },
      querySelectorAll() { return []; },
      createElement: (t) => mkEl(t),
      createTextNode: (t) => ({ textContent: t }),
      addEventListener() {}, removeEventListener() {},
      documentElement: { classList: { add() {}, remove() {}, toggle() {} }, dataset: { lang: 'zh' } },
      body: { appendChild() {} }, head: { appendChild() {} }
    },
    location: { href: 'http://localhost/', reload() {} },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    navigator: { clipboard: null, userAgent: 'node' },
    innerWidth: 1280, innerHeight: 800, devicePixelRatio: 1,
    // 生产 JS 的 api() 走 fetch；所有 /api 请求都在这里记录，并按 ctl.responses 出夹具。
    fetch: (u, opt) => {
      ctl.calls.push({ url: String(u), opt: opt || {} });
      const r = ctl.responses.length ? ctl.responses.shift() : (ctl.defaultResponse || {});
      const payload = (typeof r === 'function') ? r(String(u), opt) : r;
      if (payload && payload.__reject) return Promise.reject(payload.__reject);
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(payload) });
    }
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  const ctx = vm.createContext(sandbox);
  try { vm.runInContext(prodJs, ctx, { filename: 'ui_script.h:R"JS"' }); }
  catch (e) { console.log('FATAL: 生产 JS 加载失败: ' + ((e && e.stack) || e)); process.exit(2); }
  ctl.startup = false;
  return { env: sandbox, ctl, els, getEl };
}
// 跑到指定假时间：按 at 排序推进时钟，执行所有到期的一次性「业务」定时器。
// background（启动期 pollStart 的链式轮询）与 interval 永不在这里执行，避免无限重排。
function advance(ctx, to) {
  let guard = 0;
  for (;;) {
    if (++guard > 100000) throw new Error('timer loop did not settle');
    const due = ctx.ctl.timers.filter((t) => t.at <= to && !t.background && !t.interval)
      .sort((a, b) => a.at - b.at)[0];
    if (!due) break;
    ctx.ctl.timers = ctx.ctl.timers.filter((t) => t !== due);
    ctx.ctl.now = Math.max(ctx.ctl.now, due.at);
    try { due.fn(); } catch (e) { throw e; }
  }
  ctx.ctl.now = Math.max(ctx.ctl.now, to);
  return Promise.resolve().then(() => {});
}
function liveTimers(ctx) { return ctx.ctl.timers.filter((t) => !t.interval && !t.background); }
// 排空所有微任务（.then 链）+ 一次性定时器，直到稳定。间隔定时器（setInterval）永远在，忽略。
async function settle(ctx, opts) {
  const maxSteps = (opts && opts.steps) || 60;
  const jump = (opts && opts.jump) || 0;
  for (let i = 0; i < maxSteps; i++) {
    for (let k = 0; k < 8; k++) await Promise.resolve();
    await advance(ctx, ctx.ctl.now + jump);
    if (!liveTimers(ctx).length) return;
  }
  throw new Error('settle: one-shot timers still pending (' + liveTimers(ctx).length + ')');
}
async function fresh(opts) {
  const ctx = createEnv();
  await settle(ctx, opts);   // 启动期 loadAlbums/loadQ/tick 的异步链与 setInterval 桩
  ctx.ctl.calls.length = 0;  // 不计启动期请求
  return ctx;
}
const apiCalls = (ctx, prefix) => ctx.ctl.calls.filter((c) => c.url.indexOf(prefix) === 0);

async function main() {
  /* ================= L1：URL 构造 ================= */
  console.log('L1 track URL 构造（album/file/genre/编码，预取与抽屉同一份缓存）');
  L1: {
    const ctx = await fresh();
    const e = ctx.env;
    const fns = ['npSummUrl', 'npDataTargets', 'albumTrackUrl'];
    if (fns.some((n) => !need(e, n))) { console.log('  [SKIP] L1 其余断言（生产函数缺失）'); break L1; }
    e.S.lastCur = '/Music/Aimer/六等星の夜 & 星屑.flac';
    e.S.curMeta = { title: '六等星の夜', artist: 'Aimer', album: 'Sleepless Nights', genre: 'J-POP & Anison' };
    const t = { name: '六等星の夜', artist: 'Aimer', album: 'Sleepless Nights' };
    const url = e.npSummUrl('track', t);
    ck(url.indexOf('&album=' + encodeURIComponent('Sleepless Nights')) >= 0, 'L1a track URL 带 album 且已编码', url);
    ck(url.indexOf('&file=' + encodeURIComponent('/Music/Aimer/六等星の夜 & 星屑.flac')) >= 0,
       'L1a track URL 带 file（S.lastCur）且已编码', url);
    ck(url.indexOf('&genre=' + encodeURIComponent('J-POP & Anison')) >= 0,
       'L1a track URL 带 genre（S.curMeta.genre）且已编码', url);
    ck(url.indexOf('name=' + encodeURIComponent('六等星の夜')) >= 0 &&
       url.indexOf('artist=' + encodeURIComponent('Aimer')) >= 0,
       'L1a name/artist 仍用 encodeURIComponent', url);
    // 编码正确性：& 与 / 不得裸奔（否则后端会把参数截断）
    ck(url.indexOf('&genre=J-POP & Anison') < 0 && url.indexOf('file=/Music/') < 0,
       'L1a 特殊字符没有裸奔（& / 空格 均被编码）', url);
    const noAlbum = e.npSummUrl('track', { name: '六等星の夜', artist: 'Aimer' });
    ck(url !== noAlbum && noAlbum.indexOf('&album=') < 0,
       'L1b 有 album 与无 album 的 URL 不同', J({ withAlbum: url, without: noAlbum }));
    // 非 track 保持旧形状：绝不带 album/file/genre
    const rel = e.npSummUrl('release', { name: 'Sleepless Nights', artist: 'Aimer' });
    ck(rel === '/api/entity/summary?kind=release&name=' + encodeURIComponent('Sleepless Nights') +
               '&artist=' + encodeURIComponent('Aimer') + '&lang=zh',
       'L1c 非 track 保持旧 URL 形状', rel);
    // 生产 npDataTargets：track 项必须带 album（§1.7）
    const tabs = e.npDataTargets(e.S.curMeta);
    ck(tabs.length > 0 && tabs[0].k === 'track' && tabs[0].album === 'Sleepless Nights',
       'L1d npDataTargets 的 track 项带 album', J(tabs[0]));
    // albumTrackUrl 与 npSummUrl 对同一曲逐字一致
    const alb = { name: 'Sleepless Nights', artist: 'Aimer', genre: 'J-POP & Anison' };
    const track = { title: '六等星の夜', artist: 'Aimer', path: '/Music/Aimer/六等星の夜 & 星屑.flac' };
    const prefetch = e.albumTrackUrl(track, alb);
    const drawer = e.npSummUrl('track', { name: '六等星の夜', artist: 'Aimer', album: 'Sleepless Nights',
      file: '/Music/Aimer/六等星の夜 & 星屑.flac', genre: 'J-POP & Anison' });
    // 先证明抽屉 URL 本身带齐全上下文：否则两边都退化的旧 URL 也会"完全一致"（判据假绿）。
    ck(drawer.indexOf('&album=' + encodeURIComponent('Sleepless Nights')) >= 0 &&
       drawer.indexOf('&file=' + encodeURIComponent(track.path)) >= 0 &&
       drawer.indexOf('&genre=' + encodeURIComponent('J-POP & Anison')) >= 0,
       'L1e 抽屉 URL 自身带 album/file/genre（避免两边退化的假一致）', drawer);
    ck(prefetch === drawer, 'L1e albumTrackUrl 与 npSummUrl 对同一曲完全一致（同一份缓存）',
       J({ prefetch, drawer }));
    ck(prefetch.indexOf('&album=' + encodeURIComponent('Sleepless Nights')) >= 0,
       'L1e 预取 URL 确实带 album', prefetch);
  }

  /* ================= L2：knowledgeOnce 轮询单飞 ================= */
  console.log('L2 knowledgeOnce 轮询单飞（5 连点 1 fetch / done 各回调 1 次 / 120s 超时）');
  L2: {
    const ctx = await fresh();
    const e = ctx.env, ctl = ctx.ctl;
    if (!need(e, 'knowledgeOnce')) { console.log('  [SKIP] L2 其余断言（knowledgeOnce 缺失）'); break L2; }
    const u = '/api/entity/knowledge?kind=person&name=Aimer';
    // 第 1 次响应 pending（retryAfterMs=250），第 2 次 done；之后若再 fetch 会落默认 {}。
    ctl.responses.push({ pending: true, retryAfterMs: 250 },
                       { ok: true, materials: [{ kind: 'biography', title: 'Aimer', text: '歌手' }] });
    const got = [];
    for (let i = 0; i < 5; i++) e.knowledgeOnce(u, (res) => got.push(res));
    // done 的响应排在 pending 之后；每轮只推进一个 250ms 轮询，让微任务链逐跳落地。
    await settle(ctx, { jump: 250, steps: 3 });
    await settle(ctx, { jump: 250, steps: 3 });
    await settle(ctx, { jump: 0, steps: 3 });
    const calls = apiCalls(ctx, '/api/entity/knowledge');
    ck(calls.length === 2, 'L2b 5 次连点：只 1 次首请求 + 1 次 pending 轮询（不是 5 次）',
       'calls=' + calls.length + ' ' + J(calls.map((c) => c.url)));
    ck(calls[0] && !calls[0].opt.method, 'L2b knowledge 是 GET（api() 的读端点白名单）', J(calls[0] && calls[0].opt));
    ck(calls[1] && calls[1].url === u, 'L2b 轮询的是同一个 URL（不带 refresh）', J(calls[1]));
    ck(got.length === 5 && got.every((r) => r && r.ok === true),
       'L2c done 后 5 个回调各收到 1 次完整结果', 'got=' + got.length + ' ' + J(got.map((r) => r && r.ok)));
    // done 后缓存：再调一次不产生任何新请求
    let cached = null;
    e.knowledgeOnce(u, (res) => { cached = res; });
    await settle(ctx);
    ck(cached && cached.ok === true && apiCalls(ctx, '/api/entity/knowledge').length === 2,
       'L2d done 后缓存命中：0 次新请求', 'calls=' + apiCalls(ctx, '/api/entity/knowledge').length);
    // 120s 墙钟超时：pending 永远不结束，假时钟跳过 120001ms 后必须返回明确错误
    const ctx2 = await fresh();
    const e2 = ctx2.env, c2 = ctx2.ctl;
    const u2 = '/api/entity/knowledge?kind=person&name=Timeout';
    c2.defaultResponse = { pending: true, retryAfterMs: 2000 };
    let timeoutRes = null;
    e2.knowledgeOnce(u2, (res) => { timeoutRes = res; });
    // 每次跳 2s（后端建议的 retryAfterMs 上限），直到跨过 120s 墙钟上限。
    for (let i = 0; i < 62 && !timeoutRes; i++) await settle(ctx2, { jump: 2000, steps: 3 });
    if (!timeoutRes) {
      c2.now += 120001;
      await advance(ctx2, c2.now);
      for (let i = 0; i < 8; i++) await Promise.resolve();
    }
    ck(!!timeoutRes && timeoutRes.ok === false && /超时/.test(timeoutRes.error || ''),
       'L2e 120s 墙钟超时返回明确错误', J(timeoutRes));
    ck(c2.now >= 1000000 + 120000, 'L2e 超时确实按 120s 墙钟判定（不是按轮询次数）', 'now=' + c2.now);
  }

  /* ================= L3：切换实体后旧结果丢弃 ================= */
  console.log('L3 切换实体后旧结果丢弃（who 守卫 / npDataFp 指纹守卫）');
  L3: {
    const ctx = await fresh();
    const e = ctx.env, ctl = ctx.ctl;
    // (a) 艺术家页：openArtistProfile 走 knowledgeOnce，pending 期间基础页先出（不闪空白）
    ctl.responses.push({ pending: true, retryAfterMs: 250 });   // A 的 knowledge：先 pending
    e.openArtistProfile('Aimer');
    const baseHtml = ctx.getEl('list').innerHTML;
    ck(/artistKnowCard/.test(baseHtml) && /Aimer/.test(baseHtml),
       'L3a pending 期间 artistBaseHtml 先出基础骨架（不闪空白）', baseHtml.slice(0, 120));
    // 切到 LiSA（新 URL，立刻 done），随后 A 的 pending 轮询才完成
    ctl.responses.push({ ok: true, materials: [{ kind: 'biography', title: 'LiSA', text: 'B' }] },
                       { ok: true, materials: [{ kind: 'biography', title: 'Aimer', text: 'A' }] },
                       { ok: true, fields: { '简介': 'LiSA 资料' } },
                       { ok: true, fields: { '简介': 'Aimer 资料' } });
    e.openArtistProfile('LiSA');
    await settle(ctx, { jump: 250 });
    const htmlAfter = ctx.getEl('list').innerHTML;
    ck(/LiSA/.test(htmlAfter) && !/Aimer/.test(htmlAfter),
       'L3b 切到 LiSA 后 Aimer 的迟到响应不写进新面板（who 守卫）',
       'Aimer=' + /Aimer/.test(htmlAfter) + ' LiSA=' + /LiSA/.test(htmlAfter));
    ck(e.S.artistWho === 'LiSA' && e.S.view === 'artist', 'L3b 当前实体仍是 LiSA', J({ view: e.S.view, who: e.S.artistWho }));
    // (b) 单曲页 npDataEnsure：指纹含 album，切实体后旧 summary 不得写进新 cache
    const ctx3 = await fresh();
    const e3 = ctx3.env, c3 = ctx3.ctl;
    e3.S.curMeta = { title: 'T', artist: 'A', album: 'Album One' };
    e3.S.lastCur = '/m/T.flac';
    ctx3.getEl('npPage').classList.add('on');
    e3.NP_DATA = { key: '', active: 'track', tabs: [{ k: 'track', label: '歌曲', name: 'T', artist: 'A', album: 'Album One' }],
                   cache: {}, inflight: {}, req: 7, bodyKey: '', tabSig: null };
    const fpA = e3.npDataFp('track', e3.NP_DATA.tabs[0]);
    c3.responses.push({ ok: true, fields: { '演唱': '旧实体结果' } });
    e3.npDataEnsure('track', false);
    // 不等旧响应回来就把实体换成 Album Two（同一 title/artist，仅 album 不同）
    e3.NP_DATA.tabs = [{ k: 'track', label: '歌曲', name: 'T', artist: 'A', album: 'Album Two' }];
    e3.NP_DATA.cache.track = { state: 'loading', fp: e3.npDataFp('track', e3.NP_DATA.tabs[0]) };
    await settle(ctx3);
    ck(fpA !== e3.npDataFp('track', e3.NP_DATA.tabs[0]),
       'L3c npDataFp 含 album：同名同艺术家不同专辑 = 不同实体', J({ fpA, fpB: e3.npDataFp('track', e3.NP_DATA.tabs[0]) }));
    const written = e3.NP_DATA.cache.track;
    ck(!written || !written.data || !written.data.fields || !written.data.fields['演唱'],
       'L3d 旧实体的迟到 summary 没有写进新面板（npDataFp 守卫）', J(written && written.data));
  }

  /* ================= L4：insufficient ================= */
  console.log('L4 insufficient 文案与不重试、不写缓存');
  L4: {
    const ctx = await fresh();
    const e = ctx.env, ctl = ctx.ctl;
    const TEXT = '资料不足：缺少艺术家与曲名';
    e.S.curMeta = { title: '03', artist: '', album: '' };
    e.S.lastCur = '/m/03.flac';
    ctx.getEl('npPage').classList.add('on');
    e.NP_DATA = { key: '', active: 'track', tabs: [{ k: 'track', label: '歌曲', name: '03', artist: '', album: '' }],
                  cache: {}, inflight: {}, req: 3, bodyKey: '', tabSig: null };
    ctl.responses.push({ ok: false, insufficient: true, error: TEXT });
    e.npDataEnsure('track', false);
    await settle(ctx);
    const st = e.NP_DATA.cache.track;
    ck(st && st.state === 'insufficient', 'L4a npDataEnsure 把 insufficient 记成终局态（不是 error）', J(st && st.state));
    const bodyHtml = ctx.getEl('npDataBody').innerHTML;
    const hintHtml = ctx.getEl('npSummHint').innerHTML;
    ck(bodyHtml.indexOf(TEXT) >= 0 || hintHtml.indexOf(TEXT) >= 0,
       'L4b 右栏/抽屉明确显示「' + TEXT + '」', J({ body: bodyHtml.slice(0, 200), hint: hintHtml.slice(0, 200) }));
    ck(!/npDataRetry|点击重试|重试/.test(bodyHtml),
       'L4c 不显示自动重试入口', bodyHtml.slice(0, 200));
    const summBefore = apiCalls(ctx, '/api/entity/summary').length;
    ck(summBefore === 1, 'L4d insufficient 只有 1 次请求', 'calls=' + summBefore);
    // 不写缓存：summaryOnce 对 insufficient 不留可复用 ok，再调一次会重新发请求
    const url = e.npSummUrl('track', e.NP_DATA.tabs[0]);
    ck(!Object.prototype.hasOwnProperty.call(e.SUMC.cache, url),
       'L4e SUMC 未把 insufficient 缓存成可复用结果', 'cached=' + Object.prototype.hasOwnProperty.call(e.SUMC.cache, url));
    // 自动加载（npAutoSummary）也不该对同一实体再发第二次：insufficient 是终局态
    e.META.summary = 1; e.META.hasLlmKey = true;
    e.npAutoSummary();
    await settle(ctx);
    ck(apiCalls(ctx, '/api/entity/summary').length === 1,
       'L4f npAutoSummary 对 insufficient 不再自动重试（0 次新请求）',
       'calls=' + apiCalls(ctx, '/api/entity/summary').length);
    // 专辑页预取：insufficient 计入完成、不留红字
    const ctx2 = await fresh();
    const e2 = ctx2.env, c2 = ctx2.ctl;
    e2.META.summary = 1; e2.META.hasLlmKey = true;
    c2.responses.push({ ok: false, insufficient: true, error: TEXT });
    e2.albumTrackPrefetch({ k: 'a1', name: 'A1', artist: 'X', tracks: [{ title: '03', path: '/m/03.flac' }] });
    await settle(ctx2, { jump: 3000, steps: 3 });   // 跨过 albPrefRender 的 2600ms 收尾定时器
    ck(e2.ALBPREF.done === 1 && e2.ALBPREF.active === 0,
       'L4g 专辑页预取把 insufficient 计为完成', J({ done: e2.ALBPREF.done, active: e2.ALBPREF.active }));
    const prog = ctx2.getEl('albProgWrap').innerHTML;
    ck(!/资料整理失败|重试|nprailerr/.test(prog),
       'L4h 专辑页预取不留红字/错误提示', prog.slice(0, 200));
  }

  console.log('\n=== 结果：' + (pass + fail) + ' 项，' + fail + ' 失败 ===');
  process.exit(fail === 0 ? 0 : 1);
}
main().catch((e) => {
  console.log('FATAL: ' + ((e && e.stack) || e));
  process.exit(2);
});
