// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_b10_logic.js — 1.1.4-beta10 四条反馈里**纯逻辑**部分的判据（不需要浏览器）
//
// ============================ 为什么有这个文件 ============================
// 本机规则（2026-11-08 用户钦定）：**禁止自起无头浏览器**，需要浏览器时只走 DSH 侧边栏。
// 于是 "几何量测"（按钮位置、圆形尺寸）这类判据不能再由脚本自动跑 —— 它们改为
// 用户在侧边栏里目视验收（清单见 docs/beta10-acceptance.md）。
// 但四条反馈里有一大半是**纯函数**，完全不需要浏览器就能证明对错；把能证明的先证明，
// 不让"没有浏览器"变成"什么都不验"。判据：
//
//   L1 npSplitArtists：括号内不拆（成员表/译名）、& 与 、 与 ; 与 feat. 拆、
//      重复名去重、单个名字原样、格式垃圾括号剔除、"音楽：" 前缀剥离。
//   L2 npAlbumArtists：空/缺失署名 → 「未知艺术家」，不抛异常。
//   L3 npRailBio：fields['简介'] 优先 → sections 首段兜底 → 空则返回名字；
//      who 非空时名字进正文；简介已以名字开头时不重复；超长按 40 字截断并补省略号。
//   L4 npRailPreview('person')：首行是「名字：简介」，**任何分支都不出现「国籍 X」**。
//   L5 首页艺术家归属：同一张合作专辑同时计入每位参与者，不再产出「A & B」合成艺术家，
//      且个人专辑与合作专辑合并计数（纯数据层，用生产 loadArtists 的同一段归并逻辑）。
//
// 🔴 铁律 1/2：全程无浏览器、无音频设备；只读源码 + 在 vm 沙箱里跑生产 JS。
//
// 用法：node tools/check_b10_logic.js
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
const J = (o) => JSON.stringify(o);

/* ---------- 最小 DOM 沙箱：只够加载 ui_script.h 并调用纯函数 ---------- */
function mkEl(id) {
  const cls = new Set();
  return {
    id: id || '', value: '', textContent: '', innerHTML: '', title: '', checked: false, disabled: false,
    tagName: 'DIV', style: {}, dataset: {}, children: [], options: [],
    classList: { add: (c) => cls.add(c), remove: (c) => cls.delete(c), contains: (c) => cls.has(c),
      toggle(c, f) { if (f === undefined) { cls.has(c) ? cls.delete(c) : cls.add(c); } else { f ? cls.add(c) : cls.delete(c); } } },
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
    closest() { return null; }, remove() {}, focus() {},
    getBoundingClientRect() { return { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 }; }
  };
}
function createEnv() {
  const els = {};
  const getEl = (id) => (els[id] || (els[id] = mkEl(id)));
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {},
    Date, Math, parseInt, parseFloat, String, Number, Boolean, Array, Object, RegExp, JSON, Promise, Set, Map,
    encodeURIComponent, decodeURIComponent, isFinite, NaN, Infinity,
    addEventListener() {}, removeEventListener() {},
    requestAnimationFrame: (f) => { try { f(); } catch (e) {} return 1; },
    MutationObserver: class { observe() {} disconnect() {} },
    IntersectionObserver: class { observe() {} disconnect() {} unobserve() {} },
    ResizeObserver: class { observe() {} disconnect() {} },
    Event: class { constructor(t) { this.type = t; } },
    fetch: () => Promise.resolve({ ok: true, json: () => Promise.resolve({}) }),
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
    innerWidth: 1280, innerHeight: 800, devicePixelRatio: 1
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  const ctx = vm.createContext(sandbox);
  vm.runInContext(prodJs, ctx);
  return sandbox;
}

let env;
try { env = createEnv(); }
catch (e) { console.log('FATAL: 生产 JS 加载失败: ' + e.message); process.exit(2); }

/* ---------------- L1：npSplitArtists ---------------- */
console.log('L1 npSplitArtists（合作署名拆分）');
const S = env.npSplitArtists;
ck(typeof S === 'function', 'L1 npSplitArtists 存在于生产代码中');
const cases = [
  ['椎名林檎, 斎藤ネコ', ['椎名林檎', '斎藤ネコ'], '顿号/逗号拆'],
  ['澤野 弘之 & SennaRin', ['澤野 弘之', 'SennaRin'], '& 拆'],
  ['LiSA feat. PABLO', ['LiSA', 'PABLO'], 'feat. 拆'],
  ['FictionJunction featuring LiSA', ['FictionJunction', 'LiSA'], 'featuring 拆'],
  ['阿保 剛、いとうかなこ、Zwei、佐々木恵梨', ['阿保 剛', 'いとうかなこ', 'Zwei', '佐々木恵梨'], '四位合作'],
  ['Lunity;Lunity;Lunity;Lunity', ['Lunity'], '写坏的重复标签去重'],
  ['REIJINGSIGNAL(CV：Lynn、芹澤 優、鈴木みのり)', ['REIJINGSIGNAL(CV：Lynn、芹澤 優、鈴木みのり)'], '括号内成员表不拆'],
  ['桜高軽音部(豊崎愛生, 日笠陽子, 佐藤聡美, 寿美菜子)', ['桜高軽音部(豊崎愛生, 日笠陽子, 佐藤聡美, 寿美菜子)'], '括号内逗号不拆'],
  ['Aimer', ['Aimer'], '单个名字原样'],
  ['アクアプラス(2ALAC+cue+log+png)', ['アクアプラス'], '格式垃圾括号剔除'],
  ['音楽：小林俊太郎,アクアプラス(2ALAC+cue+log+png)', ['小林俊太郎', 'アクアプラス'], '标签前缀剥离 + 多段'],
  ['AC/DC', ['AC/DC'], '含斜杠的乐队名不被切坏'],
  ['', [], '空串返回空数组']
];
for (const [inp, want, why] of cases) {
  const got = S(inp);
  ck(J(got) === J(want), 'L1 ' + why + '：' + J(inp) + ' → ' + J(want), J(got) === J(want) ? '' : 'got=' + J(got));
}

/* ---------------- L2：npAlbumArtists ---------------- */
console.log('L2 npAlbumArtists（专辑归属，空值安全）');
ck(J(env.npAlbumArtists({ artist: '' })) === J(['未知艺术家']), 'L2 空署名 → 未知艺术家');
ck(J(env.npAlbumArtists({})) === J(['未知艺术家']), 'L2 缺字段 → 未知艺术家');
ck(J(env.npAlbumArtists(null)) === J(['未知艺术家']), 'L2 null 不抛异常');

/* ---------------- L3：npRailBio ---------------- */
console.log('L3 npRailBio（简介取值与名字注入）');
const BIO = env.npRailBio;
ck(typeof BIO === 'function', 'L3 npRailBio 存在');
ck(BIO({ fields: { '简介': '日本女性创作歌手。' } }, 'Aimer') === 'Aimer：日本女性创作歌手。',
  'L3 fields 简介 + 名字前缀', BIO({ fields: { '简介': '日本女性创作歌手。' } }, 'Aimer'));
ck(BIO({ fields: { '简介': 'Aimer 日本女性创作歌手。' } }, 'Aimer') === 'Aimer 日本女性创作歌手。',
  'L3 简介已以名字开头时不重复', BIO({ fields: { '简介': 'Aimer 日本女性创作歌手。' } }, 'Aimer'));
ck(BIO({ sections: [{ paragraphs: [{ text: '某制作团队。' }] }] }, 'ZUNTATA') === 'ZUNTATA：某制作团队。',
  'L3 只有 sections 时取首段并加名字', BIO({ sections: [{ paragraphs: [{ text: '某制作团队。' }] }] }, 'ZUNTATA'));
ck(BIO(null, 'Aimer') === 'Aimer', 'L3 完全无资料 → 只留名字', BIO(null, 'Aimer'));
ck(BIO({ fields: { '简介': '国际知名脚本音乐家' } }, '') === '国际知名脚本音乐家', 'L3 who 为空时不加前缀');
const longBio = BIO({ fields: { '简介': 'x'.repeat(100) } }, 'N');
ck(longBio.length <= 42 && /…$/.test(longBio), 'L3 超长按 40 字截断并补省略号', 'len=' + longBio.length);
ck(!/国籍/.test(BIO({ fields: { '国籍': '日本' } }, 'Aimer')), 'L3 只有国籍时不会把国籍当简介', BIO({ fields: { '国籍': '日本' } }, 'Aimer'));

/* ---------------- L4：npRailPreview('person') ---------------- */
console.log("L4 npRailPreview('person')（艺术家卡首行）");
const P = env.npRailPreview;
env.S.curMeta = { title: 'T', artist: 'Aimer', album: 'A', albumArtist: 'Aimer' };
env.NP_DATA = { tabs: [{ k: 'person', label: '艺术家', name: 'Aimer', artist: '' }], cache: {}, active: '', req: 0 };
const pv1 = P('person', { state: 'ok', data: { ok: true, fields: { '国籍': '日本', '简介': '日本女性创作歌手，2011 年出道。', '风格': 'J-POP' } } });
ck(/^Aimer：日本女性创作歌手/.test(pv1.p1), 'L4a 首行 = 名字：简介', J(pv1.p1));
ck(!/国籍/.test(pv1.p1), 'L4a 首行不含「国籍」', J(pv1.p1));
ck(/风格/.test(pv1.p2), 'L4a 第二行保留风格等可扫读属性', J(pv1.p2));
const pv2 = P('person', { state: 'ok', data: { ok: true, fields: { '国籍': '日本', '活跃年代': '2011 年至今' } } });
ck(!/国籍/.test(pv2.p1), 'L4b 没有简介时也不用国籍占主位', J(pv2.p1));
const pv3 = P('person', { state: 'idle', data: null });
ck(pv3.p1 === 'Aimer', 'L4c 无资料时首行是艺术家名', J(pv3.p1));

/* ---------------- L5：首页艺术家归属（与 loadArtists 同一段归并逻辑） ---------------- */
console.log('L5 首页艺术家归属（合作专辑归到各位参与者）');
// 直接对生产函数 renderArtistsFrom 的归并做等价验算：用同一份 npAlbumArtists 规则统计
const albums = [
  { k: 'k1', name: '合作专辑', artist: '椎名林檎, 斎藤ネコ', dur: 100 },
  { k: 'k2', name: '个人专辑', artist: '椎名林檎', dur: 100 },
  { k: 'k3', name: '双人专辑', artist: '澤野 弘之 & SennaRin', dur: 100 }
];
const m2 = {}, order = [];
albums.forEach(function (a) {
  env.npAlbumArtists(a).forEach(function (k) {
    if (!m2[k]) { m2[k] = { n: 0, d: 0 }; order.push(k); }
    m2[k].n++;
  });
});
ck(order.indexOf('椎名林檎') >= 0 && order.indexOf('斎藤ネコ') >= 0 && order.indexOf('澤野 弘之') >= 0 && order.indexOf('SennaRin') >= 0,
  'L5 合作专辑同时归到每位参与者名下', J(order));
ck(order.indexOf('椎名林檎, 斎藤ネコ') < 0 && order.indexOf('澤野 弘之 & SennaRin') < 0,
  'L5 不再新增「A & B」合成艺术家', J(order));
ck(m2['椎名林檎'].n === 2, 'L5 个人 + 合作专辑合并计数（椎名林檎 = 2 张）', 'n=' + (m2['椎名林檎'] || {}).n);

/* ---------------- L6：右栏详细/简略两档（纯逻辑） ---------------- */
console.log('L6 右栏详细/简略两档（纯逻辑）');
// 档位切换必须能在 createEnv() 的最小 DOM 沙箱里跑：mkEl() 的 querySelectorAll() 返回 []、
// setAttribute() 只存属性。这里**不给沙箱补任何 DOM**；npRailDetailSet 在沙箱里抛错就记 FAIL，
// 不掩盖。api/fetch 只做计数打桩，出段前在 finally 里把状态全部还原。
const l6Saved = {
  hadRail: Object.prototype.hasOwnProperty.call(env, 'NP_RAILDETAIL'),
  rail: env.NP_RAILDETAIL,
  data: env.NP_DATA,
  api: env.api,
  fetch: env.fetch,
  ls: env.localStorage
};
const l6Store = {};
env.localStorage = {
  getItem(k) { return Object.prototype.hasOwnProperty.call(l6Store, k) ? l6Store[k] : null; },
  setItem(k, v) { l6Store[k] = String(v); },
  removeItem(k) { delete l6Store[k]; }
};
function l6call(name, fn) {
  try { return fn(); }
  catch (e) {
    ck(false, name, 'EXCEPTION: ' + ((e && e.message) || String(e)));
    return undefined;
  }
}
const l6Has = (n) => typeof env[n] === 'function';
try {
  /* (a) npRailLimits：简略 bio=40/pick=2，详细 bio=0/pick=4，且两档取值都不同 */
  ck(l6Has('npRailLimits'), 'L6a npRailLimits 存在于生产代码中');
  ck(l6Has('npRailDetailSet'), 'L6a npRailDetailSet 存在于生产代码中');
  l6call('L6a 切到简略档 NP_RAILDETAIL=0', () => env.npRailDetailSet(0));
  const limB = l6call('L6a 简略档 npRailLimits()', () => env.npRailLimits());
  ck(!!limB && limB.bio === 40 && limB.pick === 2, 'L6a 简略档 → {bio:40,pick:2}', J(limB));
  l6call('L6a 切到详细档 NP_RAILDETAIL=1', () => env.npRailDetailSet(1));
  const limD = l6call('L6a 详细档 npRailLimits()', () => env.npRailLimits());
  ck(!!limD && limD.bio === 0 && limD.pick === 4, 'L6a 详细档 → {bio:0,pick:4}', J(limD));
  ck(!!limB && !!limD && limB.bio !== limD.bio, 'L6a 两档 bio 截断上限不同',
     'brief=' + (limB && limB.bio) + ' detail=' + (limD && limD.bio));
  ck(!!limB && !!limD && limB.pick !== limD.pick, 'L6a 两档 pick 字段数不同',
     'brief=' + (limB && limB.pick) + ' detail=' + (limD && limD.pick));

  /* (b) 长简介：简略截断补省略号，详细不截断（CSS -webkit-line-clamp 是唯一限制） */
  env.NP_DATA = { tabs: [{ k: 'person', label: '艺术家', name: 'N', artist: '' }],
                  cache: {}, active: '', req: 0, tabSig: null };
  const stLong = { state: 'ok', data: { ok: true, fields: { '简介': 'x'.repeat(300) } } };
  l6call('L6b 切到简略档', () => env.npRailDetailSet(0));
  const p1B = l6call('L6b 简略档 npRailPreview(person)', () => env.npRailPreview('person', stLong).p1);
  ck(typeof p1B === 'string' && /…$/.test(p1B) && p1B.length <= 41,
     'L6b 简略档长简介截断并补省略号（长度≤41）',
     'len=' + (p1B && p1B.length) + ' tail=' + J(typeof p1B === 'string' ? p1B.slice(-2) : p1B));
  l6call('L6b 切到详细档', () => env.npRailDetailSet(1));
  const p1D = l6call('L6b 详细档 npRailPreview(person)', () => env.npRailPreview('person', stLong).p1);
  ck(typeof p1D === 'string' && p1D.length > 200 && !/…$/.test(p1D),
     'L6b 详细档长简介不截断（>200 字且不以省略号结尾）',
     'len=' + (p1D && p1D.length) + ' tail=' + J(typeof p1D === 'string' ? p1D.slice(-2) : p1D));
  ck(typeof p1B === 'string' && typeof p1D === 'string' && p1B.length !== p1D.length,
     'L6b 两档 p1 长度不同', 'brief=' + (p1B && p1B.length) + ' detail=' + (p1D && p1D.length));

  /* (c) kind='track' 第二行字段数：简略 2 段，详细 4 段（split by ' · '） */
  const stTrack = { state: 'ok', data: { ok: true, fields: {
    '歌曲风格': 'J-POP', '发行时间': '2020', '所属专辑': 'A', '衍生作品': 'B'
  } } };
  l6call('L6c 切到简略档', () => env.npRailDetailSet(0));
  const pvB = l6call('L6c 简略档 npRailPreview(track)', () => env.npRailPreview('track', stTrack));
  const segB = pvB && typeof pvB.p2 === 'string' ? pvB.p2.split(' · ').length : -1;
  ck(segB === 2, 'L6c 简略档 p2 = 2 段', J(pvB && pvB.p2) + ' segs=' + segB);
  l6call('L6c 切到详细档', () => env.npRailDetailSet(1));
  const pvD = l6call('L6c 详细档 npRailPreview(track)', () => env.npRailPreview('track', stTrack));
  const segD = pvD && typeof pvD.p2 === 'string' ? pvD.p2.split(' · ').length : -1;
  ck(segD === 4, 'L6c 详细档 p2 = 4 段', J(pvD && pvD.p2) + ' segs=' + segD);
  ck(segB >= 0 && segD > segB, 'L6c 详细档字段数 > 简略档', 'brief=' + segB + ' detail=' + segD);

  /* (d) 切档不重新取数：api/fetch 计数 + NP_DATA.cache 严格引用不变 */
  let summaryCalls = 0;
  const origApi = l6Saved.api, origFetch = l6Saved.fetch;
  const countUrl = (u) => { if (typeof u === 'string' && u.indexOf('/api/entity/summary') === 0) summaryCalls++; };
  env.api = function (u) { countUrl(u); return origApi.apply(this, arguments); };
  env.fetch = function (u) { countUrl(u); return origFetch.apply(this, arguments); };
  const cacheRef = { track: { state: 'ok', data: { ok: true, fields: {} } } };
  env.NP_DATA = { key: '', active: '', tabs: [{ k: 'person', label: '艺术家', name: 'N', artist: '' }],
                  cache: cacheRef, inflight: {}, req: 0, bodyKey: '', tabSig: null };
  const cacheSeen = env.NP_DATA.cache;
  l6call('L6d npRailDetailSet(1) → npRailDetailSet(0)（沙箱内不得抛错）', () => {
    env.npRailDetailSet(1);
    env.npRailDetailSet(0);
  });
  ck(summaryCalls === 0, 'L6d 切档 0 次 /api/entity/summary 请求', 'calls=' + summaryCalls);
  ck(env.NP_DATA.cache === cacheSeen, 'L6d 切档不重分配 NP_DATA.cache（严格同一引用）');
} catch (e) {
  ck(false, 'L6 段内未捕获异常', 'EXCEPTION: ' + ((e && e.message) || String(e)));
} finally {
  env.api = l6Saved.api;
  env.fetch = l6Saved.fetch;
  env.localStorage = l6Saved.ls;
  env.NP_DATA = l6Saved.data;
  if (l6Saved.hadRail) env.NP_RAILDETAIL = l6Saved.rail;
  else delete env.NP_RAILDETAIL;
}

/* ---------------- L7：设置页 .setfoot 随内容滚动（非 sticky/fixed） ---------------- */
console.log('L7 设置页 .setfoot 样式契约（随页面滚动，禁止 sticky/fixed 固定吸底）');
const uiPagePath = path.resolve(__dirname, '../src/net/ui_page.h');
const rawPage = fs.readFileSync(uiPagePath, 'utf8');
const setfootRules = rawPage.match(/\.setfoot\{[^}]*\}/g) || [];
ck(setfootRules.length >= 1, 'L7a ui_page.h 存在 .setfoot 规则', J(setfootRules));
const hasStickyOrFixed = setfootRules.some((r) => /position\s*:\s*(sticky|fixed)/i.test(r));
ck(!hasStickyOrFixed, 'L7b .setfoot 不含 position:sticky 或 position:fixed', J(setfootRules));
const hasAutoMargin = setfootRules.some((r) => /margin-top\s*:\s*auto/i.test(r));
ck(hasAutoMargin, 'L7c .setfoot 保留 margin-top:auto（短页贴底、长页随内容滚）', J(setfootRules));

console.log('\n=== 结果：' + (pass + fail) + ' 项，' + fail + ' 失败 ===');
process.exit(fail === 0 ? 0 : 1);
