// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// tipcheck.js — 设置页 (?) 提示气泡的浏览器回归：几何 + 真实输入 + 证据截图
//
// ── 要证明什么（先写判据，再写实现）──────────────────────────────────────────
// 产品里 `.tip` 的说明气泡是 **CSS 伪元素** `.tip::after{content:attr(data-tip)}`，
// 默认 `opacity:0;visibility:hidden`，只在 `:hover` / `:focus` 时可见。
// 因此「气泡没被裁掉」这件事**不能**靠查 class / 查 data-tip 存在来证明（铁律 3）：
//   1. 必须先把气泡真正显示出来 —— 用 **真实 CDP 鼠标移动**（Input.dispatchMouseEvent）
//      和 **真实 Tab 按键**（Input.dispatchKeyEvent）触发，再看 computed opacity/visibility；
//   2. 必须算出 `.tip::after` **实际渲染矩形**（不是 .tip 自己的矩形）：
//      computed width/height 按 box-sizing 换算 border box，锚点由 computed left/right 或 top/bottom
//      （含 calc(百分比 + Npx)）解析，再按 transform-origin + DOMMatrix 变换四角；
//   3. 必须把该矩形与 **viewport** 以及 **每一个 overflow 裁剪祖先的 padding box** 求交，
//      四边都不许溢出（`.sbody{overflow-y:auto;overflow-x:hidden}` 是主要裁剪者）；
//   4. 每一页、每一个宽度都要留**可肉眼审查**的截图。
//
// ── 本文件不做什么 ──────────────────────────────────────────────────────────
//   · 不启动 rtaweb、不构建、不写产品文件、不改产品样式/DOM（唯一例外：
//     .tip::after 的 computed 尺寸拿不到时才用一次性克隆测量，见 measureClone，
//     并且会在 JSON 里标 measureMode='clone'）；
//   · 不 force-kill：浏览器由 tools/uibrowser.js 用 SIGTERM 收尾（那是它自己的隔离实例）；
//   · 不碰 8899（用户正在用的实例）与 19092（别人的 rtaweb）：默认拒绝，需 --allow-live 才放行。
//
// ── 用法 ────────────────────────────────────────────────────────────────────
//   node tools/tipcheck.js --url http://127.0.0.1:19093 --out /tmp/tipcheck-19093
//   node tools/tipcheck.js --url http://127.0.0.1:19093 --widths 1576,1200,998 --shots all
//   node tools/tipcheck.js --url http://127.0.0.1:19093 --baseline /tmp/tipcheck-19093/baseline.json
//   node tools/tipcheck.js --selftest          # 只自检"探针本身"，不碰产品
//
//   选项：
//     --url <u>             必填（--selftest 除外）
//     --port <n>            CDP 端口，默认 19094
//     --out <dir>           JSON + 截图目录，默认 ./tipcheck-<时间戳>
//     --widths <a,b,c>      视口宽度，默认 1576,1200,998（1200 命中 min-width 边界）
//     --height <n>          视口高度，默认 908
//     --panes <g,g,...>     只测这些页签（in,out,pcm,sdm,adv,eq,cal,meta,stream,diag）
//     --shots <fail|pane|all>  截图粒度，默认 pane（每页 top+首个 hover+失败用例）
//     --baseline <file>     不存在＝记录旧版已知失败（exit 0，证据全留）；
//                           已存在＝比对，只有"新增失败"才 exit 1
//     --tab-sweep           所有页签都用真实 Tab 走一遍（默认只对「元数据」做）
//     --expand-collapsed    额外点开「高级选项 ▾」，覆盖折叠区里的 3 个 tip
//     --adversarial         附加对抗用例（最长文/右边界/底部滚动 + 合成用例，合成永不判定成败）
//     --settle <ms>         每页切换后的稳定等待，默认 900
//     --verbose             打印每个用例
//
// ── 退出码 ──────────────────────────────────────────────────────────────────
//   0 = 全部通过（或 --baseline 记录模式）；1 = 有用例失败/相对 baseline 新增失败；
//   2 = 环境或前置条件不满足（无 Edge、页面打不开、拒绝的端口）。
//   注意：只看退出码不够，report.json 里的 coverage / warnings 也要看（铁律 3）。
'use strict';

const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');
const sleep = ub.sleep;

// ─────────────────────────────────────────────────────────────────────────────
// 0. 参数
// ─────────────────────────────────────────────────────────────────────────────
const BOOL = new Set(['selftest', 'help', 'verbose', 'tab-sweep', 'expand-collapsed', 'adversarial', 'allow-live', 'keep-wide']);

function parseArgs(argv) {
  const o = {
    url: '', port: 19094, out: '', widths: [1576, 1200, 998], height: 908,
    panes: null, shots: 'pane', baseline: null, settle: 900, verbose: false,
    selftest: false, help: false, tabSweep: false, expandCollapsed: false,
    adversarial: false, allowLive: false, keepWide: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const eq = a.indexOf('=');
    const k = (eq >= 0 ? a.slice(2, eq) : a.slice(2));
    let v = eq >= 0 ? a.slice(eq + 1) : null;
    if (v == null && !BOOL.has(k) && i + 1 < argv.length && !argv[i + 1].startsWith('--')) v = argv[++i];
    switch (k) {
      case 'url': o.url = v || ''; break;
      case 'port': o.port = parseInt(v, 10) || 19094; break;
      case 'out': o.out = v || ''; break;
      case 'widths': o.widths = String(v || '').split(',').map((x) => parseInt(x, 10)).filter((x) => x > 100); break;
      case 'height': o.height = parseInt(v, 10) || 908; break;
      case 'panes': o.panes = String(v || '').split(',').map((s) => s.trim()).filter(Boolean); break;
      case 'shots': o.shots = (v || 'pane'); break;
      case 'baseline': o.baseline = v || '__AUTO__'; break;
      case 'settle': o.settle = parseInt(v, 10) || 900; break;
      case 'verbose': o.verbose = true; break;
      case 'tab-sweep': o.tabSweep = true; break;
      case 'expand-collapsed': o.expandCollapsed = true; break;
      case 'adversarial': o.adversarial = true; break;
      case 'allow-live': o.allowLive = true; break;
      case 'keep-wide': o.keepWide = true; break;
      case 'selftest': o.selftest = true; o.selftestMode = v || 'basic'; break;
      case 'help': o.help = true; break;
      default: break;
    }
  }
  if (!o.out) o.out = path.join(require('os').tmpdir(), 'tipcheck-' + stamp());
  else o.out = path.resolve(o.out);
  if (o.baseline === '__AUTO__') o.baseline = path.join(o.out, 'baseline.json');
  if (!['fail', 'pane', 'all'].includes(o.shots)) o.shots = 'pane';
  return o;
}

function stamp() {
  const d = new Date();
  const p = (n, w) => String(n).padStart(w || 2, '0');
  return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
}

// 设置页页签：顺序与 ui_script.h renderSettingsPage() 的 .stabs 完全一致。
// label 用来核对页签文案（页签被改名/被换掉时立刻暴露，而不是静默少测一页）。
const PANES = [
  { g: 'in', label: '输入' },
  { g: 'out', label: '输出' },
  { g: 'pcm', label: 'PCM' },
  { g: 'sdm', label: 'SDM' },
  { g: 'adv', label: '高级' },
  { g: 'eq', label: 'EQ' },
  { g: 'cal', label: '声音校准' },
  { g: 'meta', label: '元数据' },
  { g: 'stream', label: '流媒体' },
  { g: 'diag', label: '诊断' },
];

// 绝不碰的端口：8899 = 用户的实时实例；19092 = 别人的 rtaweb（用户明确要求不动）
const LIVE_PORTS = [8899, 19092];

// ─────────────────────────────────────────────────────────────────────────────
// 1. 页内探针（每次 eval 自带一份，不往 window 上挂全局，避免污染产品运行态）
// ─────────────────────────────────────────────────────────────────────────────
const PRELUDE = String.raw`
const px = function (v) { const m = /^(-?[\d.]+)px$/.exec(String(v == null ? '' : v).trim()); return m ? parseFloat(m[1]) : null; };
const describe = function (n) {
  if (!n) return 'null';
  let s = n.tagName.toLowerCase();
  if (n.id) s += '#' + n.id;
  if (n.classList && n.classList.length) s += '.' + Array.prototype.slice.call(n.classList).join('.');
  return s;
};
const paneOf = function (g) { return document.querySelector('#setpage .spane[data-g="' + g + '"]'); };
const tipList = function (g) { const p = paneOf(g); return p ? Array.prototype.slice.call(p.querySelectorAll('.tip')) : null; };
// 文本节点拼接，剔除 .tip 自己的 "?"（否则锚点里会混进一个问号，基线指纹也跟着漂）
const textExcludingTips = function (n) {
  let out = '';
  for (let i = 0; i < n.childNodes.length; i++) {
    const c = n.childNodes[i];
    if (c.nodeType === 3) out += c.nodeValue;
    else if (c.nodeType === 1 && !(c.classList && c.classList.contains('tip'))) out += textExcludingTips(c);
  }
  return out;
};
const anchorOf = function (el) {
  const lab = el.closest('label');
  if (lab) {
    const f = lab.querySelector('input,select,textarea');
    if (f && f.id) return f.id;
    const t = textExcludingTips(lab).trim().replace(/\s+/g, ' ').slice(0, 20);
    if (t) return 'label:' + t;
  }
  const fld = el.closest('.sfld');
  if (fld) { const f = fld.querySelector('input,select,textarea,button'); if (f && f.id) return f.id; }
  const head = el.closest('.sghead, .mh');
  if (head) return 'group:' + textExcludingTips(head).trim().replace(/\s+/g, ' ').slice(0, 28);
  const cell = el.closest('td,th');
  if (cell) return 'cell:' + textExcludingTips(cell).trim().replace(/\s+/g, ' ').slice(0, 28);
  return '';
};
const kindOf = function (el) {
  if (el.closest('.sghead')) return 'header';
  if (el.closest('.mh')) return 'mh';
  if (el.closest('label')) return 'label';
  if (el.closest('.sfld')) return 'inline';
  return 'other';
};
// 裁剪祖先：overflow 任一轴非 visible 即在此轴的 padding box 处裁剪（CSS 规范会把另一轴提成 auto）
const clipBox = function (n) {
  const r = n.getBoundingClientRect();
  const x = r.left + n.clientLeft, y = r.top + n.clientTop;
  return { sel: describe(n), x: x, y: y, w: n.clientWidth, h: n.clientHeight, right: x + n.clientWidth, bottom: y + n.clientHeight };
};
const clipChain = function (el) {
  const out = []; let n = el.parentElement;
  while (n && n !== document.documentElement) {
    const cs = getComputedStyle(n);
    if (cs.overflowX !== 'visible' || cs.overflowY !== 'visible') out.push(clipBox(n));
    n = n.parentElement;
  }
  return out;
};
const scrollHostOf = function (el) {
  let n = el.parentElement;
  while (n && n !== document.documentElement) {
    const cs = getComputedStyle(n);
    if (/^(auto|scroll|overlay)$/.test(cs.overflowY) && n.scrollHeight > n.clientHeight + 1) return n;
    n = n.parentElement;
  }
  return null;
};
// left/right/top/bottom 的 used 值；calc(百分比 ± Npx) 按包含块尺寸解析（产品用的正是这条）
const offVal = function (s, base) {
  const v = String(s == null ? '' : s).trim();
  if (!v || v === 'auto') return null;
  const p = px(v); if (p != null) return p;
  if (/^-?[\d.]+%$/.test(v)) return base * parseFloat(v) / 100;
  let m = /^calc\(\s*(-?[\d.]+)%\s*([+-])\s*(-?[\d.]+)px\s*\)$/.exec(v);
  if (m) { const b = base * parseFloat(m[1]) / 100, d = parseFloat(m[3]); return m[2] === '+' ? b + d : b - d; }
  m = /^calc\(\s*(-?[\d.]+)px\s*([+-])\s*(-?[\d.]+)%\s*\)$/.exec(v);
  if (m) { const b = base * parseFloat(m[3]) / 100, d = parseFloat(m[1]); return m[2] === '+' ? d + b : d - b; }
  return null;
};
// 唯一会碰 DOM 的地方：::after 的 computed width/height 拿不到 px 时，用一次性克隆量一次。
// 用宿主 div 挂在 documentElement 下（position:fixed + 屏幕外 + visibility:hidden），量完立刻移除；
// 不改产品任何节点的 class/style，也不改产品样式表。JSON 里会标 measureMode='clone'。
const measureClone = function (el, cs) {
  const host = document.createElement('div');
  host.setAttribute('data-tipcheck-measure', '1');
  host.style.cssText = 'position:fixed;left:-20000px;top:0;visibility:hidden;pointer-events:none;contain:layout style;';
  const d = document.createElement('div');
  const props = ['fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'fontVariant', 'lineHeight', 'letterSpacing',
    'wordSpacing', 'textTransform', 'textAlign', 'textIndent', 'whiteSpace', 'wordBreak', 'overflowWrap',
    'boxSizing', 'borderStyle', 'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
    'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'direction'];
  for (let i = 0; i < props.length; i++) { const p = props[i]; if (cs[p]) d.style[p] = cs[p]; }
  const mw = cs.maxWidth;
  if (mw && mw !== 'none') d.style.maxWidth = mw;
  d.style.width = 'max-content';
  d.textContent = el.getAttribute('data-tip') || '';
  host.appendChild(d);
  document.documentElement.appendChild(host);
  const r = d.getBoundingClientRect();
  const sub = (px(cs.paddingLeft) || 0) + (px(cs.paddingRight) || 0) + (px(cs.borderLeftWidth) || 0) + (px(cs.borderRightWidth) || 0);
  const subv = (px(cs.paddingTop) || 0) + (px(cs.paddingBottom) || 0) + (px(cs.borderTopWidth) || 0) + (px(cs.borderBottomWidth) || 0);
  host.remove();
  // 返回与 computed width/height 相同的 box-sizing 语义，调用方只转换一次。
  return { w: cs.boxSizing === 'border-box' ? r.width : Math.max(0, r.width - sub),
    h: cs.boxSizing === 'border-box' ? r.height : Math.max(0, r.height - subv) };
};
// .tip::after 的实际渲染矩形（视口坐标）。锚点语义：绝对定位于 .tip 的 padding box。
const pseudoGeom = function (el) {
  const cs = getComputedStyle(el, '::after');
  const r = el.getBoundingClientRect();
  const bL = px(cs.borderLeftWidth) || 0, bR = px(cs.borderRightWidth) || 0;
  const bT = px(cs.borderTopWidth) || 0, bB = px(cs.borderBottomWidth) || 0;
  const pL = px(cs.paddingLeft) || 0, pR = px(cs.paddingRight) || 0;
  const pT = px(cs.paddingTop) || 0, pB = px(cs.paddingBottom) || 0;
  let cw = px(cs.width), ch = px(cs.height), mode = 'computed';
  if (cw == null || ch == null) {
    const m = measureClone(el, cs);
    if (cw == null) cw = m.w;
    if (ch == null) ch = m.h;
    mode = 'clone';
  }
  const extraW = pL + pR + bL + bR, extraH = pT + pB + bT + bB;
  const w = cs.boxSizing === 'border-box' ? Math.max(cw, extraW) : cw + extraW;
  const h = cs.boxSizing === 'border-box' ? Math.max(ch, extraH) : ch + extraH;
  // 包含块 = .tip 的 padding box，必须读元素边框，而不是气泡自己的边框。
  const ecs = getComputedStyle(el);
  const ebL = px(ecs.borderLeftWidth) || 0, ebR = px(ecs.borderRightWidth) || 0;
  const ebT = px(ecs.borderTopWidth) || 0, ebB = px(ecs.borderBottomWidth) || 0;
  const cbX = r.left + ebL, cbY = r.top + ebT;
  const cbW = Math.max(0, r.width - ebL - ebR), cbH = Math.max(0, r.height - ebT - ebB);
  const L = offVal(cs.left, cbW), R = offVal(cs.right, cbW);
  const T = offVal(cs.top, cbH), B = offVal(cs.bottom, cbH);
  let x, y, anchorX = 'auto', anchorY = 'auto';
  if (R != null && L == null) { x = cbX + cbW - R - w; anchorX = 'right'; }
  else { x = cbX + (L || 0); anchorX = L == null ? 'none' : 'left'; }
  if (B != null && T == null) { y = cbY + cbH - B - h; anchorY = 'bottom'; }
  else { y = cbY + (T || 0); anchorY = T == null ? 'none' : 'top'; }
  // CSS transforms 作用于 border box，先绕 transform-origin 变换四角，再求视口轴对齐包围盒。
  // 不能只加 matrix.e/f：rotate/scale 与非中心 origin 同样会改变四边位置和尺寸。
  const origin = cs.transformOrigin.split(/\s+/);
  const ox = offVal(origin[0], w), oy = offVal(origin[1], h), oz = px(origin[2]) || 0;
  if (ox == null || oy == null) throw new Error('无法解析 transform-origin: ' + cs.transformOrigin);
  const matrix = cs.transform === 'none' ? new DOMMatrix() : new DOMMatrix(cs.transform);
  const corners = [[0, 0], [w, 0], [w, h], [0, h]].map(function (p) {
    const q = matrix.transformPoint(new DOMPoint(p[0] - ox, p[1] - oy, -oz));
    if (!Number.isFinite(q.w) || Math.abs(q.w) < 1e-9) throw new Error('无效 transform 投影');
    return { x: x + ox + q.x / q.w, y: y + oy + q.y / q.w };
  });
  const left = Math.min.apply(null, corners.map(function (p) { return p.x; }));
  const top = Math.min.apply(null, corners.map(function (p) { return p.y; }));
  const right = Math.max.apply(null, corners.map(function (p) { return p.x; }));
  const bottom = Math.max.apply(null, corners.map(function (p) { return p.y; }));
  return {
    x: left, y: top, w: right - left, h: bottom - top, right: right, bottom: bottom, mode: mode,
    anchorX: anchorX, anchorY: anchorY,
    contentW: Math.max(0, w - extraW), contentH: Math.max(0, h - extraH), maxWidth: cs.maxWidth,
    raw: { left: cs.left, right: cs.right, top: cs.top, bottom: cs.bottom, width: cs.width, height: cs.height,
      boxSizing: cs.boxSizing, transform: cs.transform, transformOrigin: cs.transformOrigin }
  };
};
const resolveTip = function (g, text, nth) {
  const list = tipList(g); if (!list) return null;
  let seen = 0;
  for (let i = 0; i < list.length; i++) {
    if ((list[i].getAttribute('data-tip') || '') === text) {
      if (seen === nth) return list[i];
      seen++;
    }
  }
  return null;
};
// 读数：几何 + 可见性 + 与 viewport / 每个裁剪祖先的交集判定
const snap = function (el) {
  const cs = getComputedStyle(el, '::after');
  const opacity = parseFloat(cs.opacity);
  const visibility = cs.visibility;
  const shown = (opacity >= 0.99) && visibility === 'visible';
  const g = pseudoGeom(el);
  const vp = {
    sel: 'viewport', x: 0, y: 0,
    w: document.documentElement.clientWidth, h: document.documentElement.clientHeight,
    right: document.documentElement.clientWidth, bottom: document.documentElement.clientHeight
  };
  const clips = clipChain(el);
  const boxes = [vp].concat(clips);
  const overflow = [];
  for (let i = 0; i < boxes.length; i++) {
    const b = boxes[i];
    const ov = {
      left: b.x - g.x, right: g.right - b.right, top: b.y - g.y, bottom: g.bottom - b.bottom
    };
    const worst = Math.max(ov.left, ov.right, ov.top, ov.bottom);
    if (worst > 0.5) {
      const dirs = [];
      if (ov.top > 0.5) dirs.push('top');
      if (ov.bottom > 0.5) dirs.push('bottom');
      if (ov.left > 0.5) dirs.push('left');
      if (ov.right > 0.5) dirs.push('right');
      overflow.push({ by: b.sel, dirs: dirs, px: Math.round(worst * 100) / 100, overflow: {
        top: Math.round(ov.top * 100) / 100, bottom: Math.round(ov.bottom * 100) / 100,
        left: Math.round(ov.left * 100) / 100, right: Math.round(ov.right * 100) / 100
      } });
    }
  }
  const tr = el.getBoundingClientRect();
  const host = scrollHostOf(el);
  return {
    tipRect: { x: tr.left, y: tr.top, w: tr.width, h: tr.height },
    rect: { x: g.x, y: g.y, w: g.w, h: g.h, right: g.right, bottom: g.bottom },
    measureMode: g.mode, anchor: { x: g.anchorX, y: g.anchorY },
    maxWidth: g.maxWidth, contentW: g.contentW, contentH: g.contentH, raw: g.raw,
    opacity: opacity, visibility: visibility, shown: shown,
    contentLen: (el.getAttribute('data-tip') || '').length,
    scrollTop: host ? host.scrollTop : 0,
    scrollHost: host ? describe(host) : '',
    scrollHostBox: host ? clipBox(host) : null,
    viewport: { w: vp.w, h: vp.h },
    clipAncestors: clips,
    overflow: overflow
  };
};
`;

const js = (body) => '(()=>{' + PRELUDE + '\n' + body + '\n})()';
const J = (v) => JSON.stringify(v);

// ─────────────────────────────────────────────────────────────────────────────
// 2. 真实输入（CDP Input，不用 el.click()/dispatchEvent 假冒）
// ─────────────────────────────────────────────────────────────────────────────
async function mouseMove(s, x, y) {
  await sendT(s, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x: x, y: y, button: 'none', buttons: 0, clickCount: 0 }, 8000);
}

async function mouseClick(s, x, y) {
  await mouseMove(s, x, y);
  await sendT(s, 'Input.dispatchMouseEvent', { type: 'mousePressed', x: x, y: y, button: 'left', buttons: 1, clickCount: 1 }, 8000);
  await sendT(s, 'Input.dispatchMouseEvent', { type: 'mouseReleased', x: x, y: y, button: 'left', buttons: 0, clickCount: 1 }, 8000);
}

// Tab：与 Puppeteer keyboard.press('Tab') 同一路线（rawKeyDown + keyUp，VK 9），
// 走的是浏览器真正的焦点遍历，而不是 JS 里的 el.focus()。
async function pressTab(s, shift) {
  const base = {
    modifiers: shift ? 8 : 0, windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9,
    code: 'Tab', key: 'Tab',
  };
  await sendT(s, 'Input.dispatchKeyEvent', Object.assign({ type: 'rawKeyDown' }, base), 8000);
  await sendT(s, 'Input.dispatchKeyEvent', Object.assign({ type: 'keyUp' }, base), 8000);
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. 通用小工具
// ─────────────────────────────────────────────────────────────────────────────
const failuresOf = (snapObj) => {
  const f = [];
  if (!snapObj) return [{ check: 'state', detail: 'no snapshot' }];
  if (snapObj.measureMode === 'clone') f.push({ check: 'measure-mode', detail: 'computed 尺寸不可解析，已用克隆测量（结论可信度略低）' });
  if (!(snapObj.rect.w > 1 && snapObj.rect.h > 1)) {
    f.push({ check: 'rect-resolved', detail: 'w=' + Math.round(snapObj.rect.w * 10) / 10 + ' h=' + Math.round(snapObj.rect.h * 10) / 10 });
  }
  if (snapObj.overflow && snapObj.overflow.length) {
    for (const o of snapObj.overflow) {
      f.push({ check: 'fully-visible', detail: '被 ' + o.by + ' 裁掉 ' + o.px + 'px（' + o.dirs.join('+') + '）' });
    }
  }
  return f;
};

function fpOf(c) {
  // 基线指纹刻意不含正文：文案微调不该把"已知失败"变成"新增失败"；
  // 宽度必须在里面，因为裁切与宽度强相关。
  return [c.pane, c.kind, c.anchor || '-', c.width, c.check].join('|');
}

const sha1 = (str) => require('crypto').createHash('sha1').update(String(str)).digest('hex');

function slug(text, n) {
  const s = String(text || '').replace(/[^\u4e00-\u9fa5A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, n || 24);
  return s || 'x';
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. 会话准备
// ─────────────────────────────────────────────────────────────────────────────
// 任何 CDP 调用都必须有超时：uibrowser 的 send() 在目标无响应时永不 settle，
// 一个坏页面就能让整个回归挂死（实测：导航到不存在的端口时 Runtime.enable 挂住）。
function withTimeout(p, ms, label) {
  let t = null;
  const guard = new Promise((res, rej) => {
    t = setTimeout(() => rej(new Error('CDP 超时 ' + ms + 'ms: ' + label)), ms);
  });
  return Promise.race([p, guard]).finally(() => { if (t) clearTimeout(t); });
}

let OWN_PORT = 0;   // 本次实际使用的 CDP 端口（可能因占用而自动 +1）
const sendT = (s, method, params, ms) => withTimeout(s.send(method, params), ms || 15000, method);

// 收尾兜底：ub.open 一旦卡在内部 CDP 调用上，它不会返回、也就没有人去关自己启动的浏览器，
// 而那个子进程句柄会让本进程永不退出（实测：导航到不存在的端口 → 挂死 3 分钟以上）。
// 这里按 **我们自己选的端口** 精确定位：命令行里带 --remote-debugging-port=<port> 的进程只可能是本次启动的那个
//（端口在 spawn 前已确认空闲）。只发 SIGTERM，绝不 -9、绝不杀进程树。
function killOwnBrowserByPort(port) {
  try {
    const out = require('child_process').execFileSync('pgrep', ['-f', '--', '--remote-debugging-port=' + port], { encoding: 'utf8' });
    const pids = String(out).split('\n').map((x) => parseInt(x, 10)).filter((x) => x > 1 && x !== process.pid);
    let n = 0;
    for (const pid of pids) { try { process.kill(pid, 'SIGTERM'); n++; } catch (e) { /* 已退出 */ } }
    return { pids: pids, term: n };
  } catch (e) { return { pids: [], term: 0, error: e.message }; }
}
const evalT = (s, expr, ms) => withTimeout(s.eval(expr), ms || 15000, 'Runtime.evaluate');
const shotT = (s, file, ms) => withTimeout(s.shot(file), ms || 20000, 'Page.captureScreenshot');

// 端口预检：端口上已经有 DevTools 在应答，就**绝不能**连 —— 那多半是用户正在用的浏览器，
// 连上后 Page.navigate 会改掉真人标签页（2026-10-28 实测踩到：连上了用户 Edge 的 tab 列表）。
// 改用下一个空闲端口，并把结果写进报告，绝不静默。
async function pickFreePort(start) {
  const probe = async (p) => {
    try {
      const c = new AbortController();
      const t = setTimeout(() => c.abort(), 700);
      const r = await fetch('http://127.0.0.1:' + p + '/json/version', { signal: c.signal });
      clearTimeout(t);
      if (r.ok) return true;              // 已经在应答 = 被占
      return false;
    } catch (e) { return false; }         // 连不上 = 空闲
  };
  for (let i = 0; i < 12; i++) {
    const p = start + i;
    if (!(await probe(p))) return { port: p, bumped: i > 0, from: start };
  }
  return { port: start, bumped: false, from: start };
}

async function openSession(o, url) {
  // 先占端口，再 spawn：避免 --remote-debugging-port 绑不上时"看起来连上了"其实是别人的浏览器
  const pick = await pickFreePort(o.port);
  const notes = [];
  if (pick.bumped) notes.push('CDP 端口 ' + pick.from + ' 已被占用（可能是用户正在用的浏览器），已改用 ' + pick.port);
  const s = await withTimeout(
    ub.open({ url: url, width: Math.max.apply(null, o.widths), height: o.height, port: pick.port }),
    45000, 'ub.open(' + pick.port + ')'
  );
  s.__port = pick.port;
  OWN_PORT = pick.port;
  s.__portNotes = notes;
  // 目标核验：连上的必须是我们刚导航到的那个页面，否则立刻撤退（不点、不测、不截图）
  const href = await evalT(s, 'location.href', 6000).catch(() => '');
  if (!href || href.indexOf(url.split('#')[0]) !== 0) {
    throw new Error('连到的页面不是目标 url（location.href=' + String(href).slice(0, 120) +
      '）；端口 ' + pick.port + ' 上可能是别人的浏览器，已中止，未做任何交互');
  }
  // 让页面在无真实前台焦点时也认为自己是 focused（Tab 遍历需要），纯 CDP 侧模拟，不动 DOM
  try { await sendT(s, 'Page.bringToFront', null, 5000); } catch (e) { notes.push('Page.bringToFront: ' + e.message); }
  try { await sendT(s, 'Emulation.setFocusEmulationEnabled', { enabled: true }, 5000); } catch (e) { /* 老版本没有 */ }
  const ok = await withTimeout(
    s.waitFor('window.S && typeof setView === "function" && !!document.getElementById("setpage")', 25000),
    28000, 'waitFor(app-ready)'
  ).catch(() => false);
  if (!ok) throw new Error('页面没进入可用状态（window.S / setView / #setpage 未就绪）: ' + url);
  return s;
}

async function clickSelectorReal(s, sel) {
  const box = await evalT(s, js(
    'const el = document.querySelector(' + J(sel) + ');\n' +
    'if (!el) return null;\n' +
    'const r = el.getBoundingClientRect();\n' +
    'const cx = Math.round(r.left + r.width / 2), cy = Math.round(r.top + r.height / 2);\n' +
    'const hit = document.elementFromPoint(cx, cy);\n' +
    'return {cx: cx, cy: cy, w: r.width, h: r.height, hit: describe(hit), hitSelf: !!(hit && (hit === el || el.contains(hit)))};'
  ));
  if (!box) return { ok: false, reason: 'not-found' };
  if (box.w < 1 || box.h < 1) return { ok: false, reason: 'zero-size' };
  await mouseClick(s, box.cx, box.cy);
  return { ok: true, hitSelf: box.hitSelf, hit: box.hit };
}

// 进入设置页（真实点击左侧「设置」导航），失败才退回 JS click 并留痕
async function ensureSettings(s, o) {
  const already = await evalT(s, js('const sp = document.getElementById("setpage"); return !!(sp && sp.classList.contains("on"));'));
  if (already) return { ok: true, already: true };
  const r = await clickSelectorReal(s, '.nav[data-v="settings"]');
  await sleep(300);
  let opened = await evalT(s, js('const sp = document.getElementById("setpage"); return !!(sp && sp.classList.contains("on"));'));
  if (!opened && r.ok) {
    await evalT(s, js('const n = document.querySelector(".nav[data-v=\\"settings\\"]"); if (n) n.click();'));
    await sleep(400);
    opened = await evalT(s, js('const sp = document.getElementById("setpage"); return !!(sp && sp.classList.contains("on"));'));
    return { ok: opened, fallback: true };
  }
  return { ok: opened, fallback: false };
}

// 切页签：同样优先真实鼠标点击；落到 pane 上就用真实点击，绝不只查 class
async function switchPane(s, g) {
  const before = await evalT(s, js(
    'const b = document.querySelector("#setpage .stab[data-g=\\"' + g + '\\"]");\n' +
    'if (!b) return { found: false };\n' +
    'return { found: true, text: (b.textContent || "").trim(), on: b.classList.contains("on") };'
  ));
  if (!before.found) return { ok: false, reason: 'tab-missing' };
  const r = await clickSelectorReal(s, '#setpage .stab[data-g="' + g + '"]');
  let st = await evalT(s, js(
    'const b = document.querySelector("#setpage .stab[data-g=\\"' + g + '\\"]");\n' +
    'const p = paneOf("' + g + '");\n' +
    'return { tabOn: !!(b && b.classList.contains("on")), paneOn: !!(p && p.classList.contains("on")) };'
  ));
  let fallback = false;
  if (!st.paneOn) {
    await evalT(s, js('const b = document.querySelector("#setpage .stab[data-g=\\"' + g + '\\"]"); if (b) b.click();'));
    await sleep(250);
    fallback = true;
    st = await evalT(s, js(
      'const b = document.querySelector("#setpage .stab[data-g=\\"' + g + '\\"]");\n' +
      'const p = paneOf("' + g + '");\n' +
      'return { tabOn: !!(b && b.classList.contains("on")), paneOn: !!(p && p.classList.contains("on")) };'
    ));
  }
  return { ok: !!st.paneOn, tabOn: !!st.tabOn, text: before.text, clickFallback: fallback, hit: r.hit || null };
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. 单页测试：枚举 tip → 逐个真实 hover → 几何判据
// ─────────────────────────────────────────────────────────────────────────────
async function enumerateTips(s, g) {
  return await evalT(s, js(
    'const list = tipList(' + J(g) + ');\n' +
    'if (!list) return { ok: false, reason: "pane-missing" };\n' +
    'const out = [];\n' +
    'for (let i = 0; i < list.length; i++) {\n' +
    '  const el = list[i];\n' +
    '  const rects = el.getClientRects();\n' +
    '  const vis = rects.length > 0 && rects[0].width > 0 && rects[0].height > 0;\n' +
    '  out.push({ idx: i, text: el.getAttribute("data-tip") || "", kind: kindOf(el), anchor: anchorOf(el), visible: vis });\n' +
    '}\n' +
    'return { ok: true, total: list.length, tips: out };'
  ));
}

// 让 tip 进入可视区，但**不**把它挪到中间：顶部 .tip 必须在自然滚动位置就测，
// 否则「气泡被 .sbody 的上边界裁掉」这个真 bug 会被 scrollIntoView 掩盖掉。
async function prepareHover(s, g, text, nth) {
  return await evalT(s, js(
    'const el = resolveTip(' + J(g) + ', ' + J(text) + ', ' + nth + ');\n' +
    'if (!el) return { ok: false, reason: "tip-gone" };\n' +
    'const host = scrollHostOf(el);\n' +
    'const vp = { x: 0, y: 0, right: document.documentElement.clientWidth, bottom: document.documentElement.clientHeight };\n' +
    'const box = host ? clipBox(host) : vp;\n' +
    'let r = el.getBoundingClientRect();\n' +
    'const inNow = r.top >= box.y - 0.5 && r.bottom <= box.bottom + 0.5 && r.left >= box.x - 0.5 && r.right <= box.right + 0.5;\n' +
    'if (!inNow) { el.scrollIntoView({ block: "nearest", inline: "nearest" }); r = el.getBoundingClientRect(); }\n' +
    'const cx = Math.round(r.left + r.width / 2), cy = Math.round(r.top + r.height / 2);\n' +
    'const hit = document.elementFromPoint(cx, cy);\n' +
    'const cs = getComputedStyle(el, "::after");\n' +
    'return { ok: true, cx: cx, cy: cy, scrolled: !inNow, scrollTop: host ? host.scrollTop : 0,\n' +
    '  scrollHost: host ? describe(host) : "",\n' +
    '  hit: describe(hit), hitSelf: !!(hit && (hit === el || el.contains(hit) || hit.contains(el))),\n' +
    '  idle: { opacity: parseFloat(cs.opacity), visibility: cs.visibility } };'
  ));
}

async function waitShown(s, g, text, nth, capMs) {
  const t0 = Date.now();
  let last = null;
  while (Date.now() - t0 < (capMs || 400)) {
    last = await evalT(s, js(
      'const el = resolveTip(' + J(g) + ', ' + J(text) + ', ' + nth + ');\n' +
      'if (!el) return { ok: false, reason: "tip-gone" };\n' +
      'return Object.assign({ ok: true }, snap(el));'
    ));
    if (last && last.ok && last.shown) return last;
    await sleep(40);
  }
  return last;
}

async function testTipHover(s, ctx, g, tip, seq) {
  const t0 = Date.now();
  const c = {
    id: ctx.width + '/' + g + '/#' + seq, width: ctx.width, height: ctx.height, pane: g,
    paneLabel: ctx.paneLabel, seq: seq, kind: tip.kind, anchor: tip.anchor,
    tipIndex: tip.idx, tipText: tip.text, tipTextLen: (tip.text || '').length,
    mode: 'hover', synthetic: false, advisory: false,
    failures: [], warnings: [], shot: null,
  };
  const text = tip.text || '';
  const nth = await evalT(s, js(
    'const list = tipList(' + J(g) + ') || [];\n' +
    'let n = 0; for (let i = 0; i < list.length; i++) { if ((list[i].getAttribute("data-tip") || "") === ' + J(text) + ') { if (i === ' + tip.idx + ') return n; n++; } }\n' +
    'return -1;'
  ));
  if (nth < 0) { c.failures.push({ check: 'tip-locator', detail: '按 idx 找不到对应 data-tip' }); return c; }
  c.nth = nth;

  const prep = await prepareHover(s, g, text, nth);
  c.prep = prep ? { scrolled: prep.scrolled, scrollTop: prep.scrollTop, scrollHost: prep.scrollHost, hit: prep.hit, hitSelf: prep.hitSelf } : null;
  if (!prep || !prep.ok) { c.failures.push({ check: 'tip-reachable', detail: (prep && prep.reason) || 'prepare failed' }); return c; }

  if (!(text || '').trim()) c.failures.push({ check: 'tip-has-text', detail: 'data-tip 为空' });
  // 未 hover 时必须不可见，否则说明"静态就露着"，同样是外观 bug
  if (prep.idle && !(prep.idle.opacity <= 0.01 || prep.idle.visibility === 'hidden')) {
    c.failures.push({ check: 'idle-hidden', detail: '未交互时已可见 opacity=' + prep.idle.opacity + ' visibility=' + prep.idle.visibility });
  }
  // 鼠标命中的必须就是这个 .tip，否则 hover 压根触发不到（被别的东西遮住 = 用户也悬不到）
  if (!prep.hitSelf) {
    c.failures.push({ check: 'hover-reachable', detail: '中心点被 ' + prep.hit + ' 遮住，真实鼠标悬停打不到该 tip' });
  }

  await mouseMove(s, prep.cx, prep.cy);
  const st = await waitShown(s, g, text, nth, 500);
  if (!st || !st.ok) {
    c.failures.push({ check: 'tip-state', detail: (st && st.reason) || 'no state' });
    return c;
  }
  c.state = {
    rect: st.rect, tipRect: st.tipRect, measureMode: st.measureMode, anchor: st.anchor,
    maxWidth: st.maxWidth, contentW: st.contentW, contentH: st.contentH, raw: st.raw,
    opacity: st.opacity, visibility: st.visibility,
    scrollTop: st.scrollTop, scrollHost: st.scrollHost, viewport: st.viewport,
    clipAncestors: st.clipAncestors, overflow: st.overflow,
  };
  if (!st.shown) c.failures.push({ check: 'shown-on-hover', detail: '真实 mouseMoved 后仍不可见 opacity=' + st.opacity + ' visibility=' + st.visibility });
  for (const f of failuresOf(st)) c.failures.push(f);
  c.ms = Date.now() - t0;
  if (ctx.o.verbose) {
    const tag = c.failures.length ? 'FAIL' : 'ok  ';
    console.log('    ' + tag + ' ' + c.id + ' [' + c.kind + '/' + (c.anchor || '-') + '] rect=' +
      Math.round(st.rect.w) + 'x' + Math.round(st.rect.h) + '@' + Math.round(st.rect.x) + ',' + Math.round(st.rect.y) +
      (c.failures.length ? ' :: ' + c.failures.map((f) => f.check + '(' + f.detail + ')').join('; ') : ''));
  }
  return c;
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. 焦点路径：真实 Tab 走一遍，落到目标 .tip 上再验一次几何
// ─────────────────────────────────────────────────────────────────────────────
async function activeSnapshot(s, g, targets) {
  return await evalT(s, js(
    'const a = document.activeElement;\n' +
    'const list = tipList(' + J(g) + ') || [];\n' +
    'const idx = list.indexOf(a);\n' +
    'const isTip = idx >= 0;\n' +
    'let nth = -1, text = "";\n' +
    'if (isTip) {\n' +
    '  text = a.getAttribute("data-tip") || "";\n' +
    '  nth = 0; for (let i = 0; i < idx; i++) if ((list[i].getAttribute("data-tip") || "") === text) nth++;\n' +
    '}\n' +
    'const cs = isTip ? getComputedStyle(a, "::after") : null;\n' +
    'return { tag: a ? a.tagName : "", id: a ? (a.id || "") : "", cls: a ? String(a.className || "") : "",\n' +
    '  isTip: isTip, tipText: text, tipNth: nth, tipCount: list.length,\n' +
    '  opacity: cs ? parseFloat(cs.opacity) : null, visibility: cs ? cs.visibility : null };\n'
  ));
}

async function testTipFocus(s, ctx, g, target, seq) {
  const c = {
    id: ctx.width + '/' + g + '/focus' + seq, width: ctx.width, height: ctx.height, pane: g,
    paneLabel: ctx.paneLabel, seq: seq, kind: target.kind, anchor: target.anchor,
    tipText: target.text, tipTextLen: (target.text || '').length,
    mode: 'focus', synthetic: false, advisory: false, failures: [], warnings: [], shot: null,
  };
  // 关掉 hover 干扰：把鼠标挪到左上角，焦点效果必须单独成立
  await mouseMove(s, 1, 1);
  await sleep(120);
  const st = await evalT(s, js(
    'const el = resolveTip(' + J(g) + ', ' + J(target.text) + ', ' + target.nth + ');\n' +
    'if (!el) return { ok: false, reason: "tip-gone" };\n' +
    'const active = document.activeElement;\n' +
    'return Object.assign({ ok: true, isTarget: active === el, active: describe(active) }, snap(el));'
  ));
  if (!st || !st.ok) { c.failures.push({ check: 'tip-state', detail: (st && st.reason) || 'no state' }); return c; }
  c.state = {
    rect: st.rect, tipRect: st.tipRect, measureMode: st.measureMode, anchor: st.anchor, maxWidth: st.maxWidth,
    contentW: st.contentW, contentH: st.contentH,
    opacity: st.opacity, visibility: st.visibility, scrollTop: st.scrollTop, scrollHost: st.scrollHost,
    viewport: st.viewport, clipAncestors: st.clipAncestors, overflow: st.overflow,
  };
  if (!st.isTarget) c.failures.push({ check: 'focus-active-element', detail: '当前 activeElement = ' + st.active + '，不是目标 tip' });
  if (!st.shown) c.failures.push({ check: 'shown-on-focus', detail: '真实 Tab 聚焦后仍不可见 opacity=' + st.opacity + ' visibility=' + st.visibility });
  for (const f of failuresOf(st)) c.failures.push(f);
  return c;
}

// Tab 遍历：从页签按钮开始往前走，记录每一步的 activeElement，命中目标后独立验证
async function tabSweep(s, ctx, g, targets, shotDir) {
  await mouseMove(s, 1, 1);
  await sleep(100);
  const res = { pane: g, width: ctx.width, presses: 0, seq: [], found: [], missing: [], shots: [] };
  const wanted = targets.map((t) => ({ text: t.text, nth: t.nth, kind: t.kind, anchor: t.anchor, hit: false }));
  const maxPress = Math.max(60, Math.min(160, 12 + (await evalT(s, js('return (tipList(' + J(g) + ') || []).length;'))) * 6));
  let lastSig = '';
  for (let i = 0; i < maxPress; i++) {
    await pressTab(s, false);
    res.presses = i + 1;
    const a = await activeSnapshot(s, g, targets);
    res.seq.push({ n: i + 1, tag: a.tag, id: a.id, cls: a.cls, isTip: a.isTip, tipTextLen: a.isTip ? (a.tipText || '').length : 0, op: a.opacity, vis: a.visibility });
    if (a.isTip) {
      const w = wanted.find((x) => !x.hit && x.text === a.tipText && x.nth === a.tipNth);
      if (w) {
        w.hit = true;
        const c = await testTipFocus(s, ctx, g, { text: a.tipText, nth: a.tipNth, kind: w.kind, anchor: w.anchor }, res.found.length + 1);
        // 聚焦态的截图：证明气泡是"键盘聚焦"点亮的（鼠标已在 1,1）
        if (ctx.o.shots !== 'fail' || c.failures.length) {
          c.shot = path.join(shotDir, pad2(res.found.length + 1) + '-focus-' + slug(w.anchor || 'tip') + '.png');
          try { await shotT(s, c.shot); } catch (e) { c.shot = null; }
        }
        res.shots.push(c.shot);
        res.found.push(c);
        ctx.cases.push(c);
        if (ctx.o.verbose) {
          console.log('    ' + (c.failures.length ? 'FAIL' : 'ok  ') + ' ' + c.id + ' [focus/' + (w.anchor || '-') + ']');
        }
      }
    }
    // 走到文档末尾会循环回开头：用 tag+id+class 的序列做"绕回一圈"判定，避免无限按
    const sig = a.tag + '|' + a.id + '|' + a.cls;
    if (i > 3 && sig === lastSig) break;
    lastSig = sig;
    if (wanted.length && wanted.every((x) => x.hit)) break;
  }
  for (const w of wanted) if (!w.hit) res.missing.push({ anchor: w.anchor, len: (w.text || '').length });
  return res;
}

const pad2 = (n) => String(n).padStart(2, '0');

// ─────────────────────────────────────────────────────────────────────────────
// 7. 对抗用例（真实页面 + 合成，二者严格区分；合成永不参与成败）
// ─────────────────────────────────────────────────────────────────────────────
async function adversarialForPane(s, ctx, g, tips, shotDir) {
  const out = [];
  const visible = tips.filter((t) => t.text && t.text.trim());
  if (!visible.length) return out;

  // RE1：最长文案（真实页面）—— 验证 max-width 夹住 + 换行后高度增加，而不是 nowrap 撑爆
  const longest = visible.slice().sort((a, b) => (b.text || '').length - (a.text || '').length)[0];
  {
    const c = {
      id: ctx.width + '/' + g + '/adv-longest', width: ctx.width, height: ctx.height, pane: g, paneLabel: ctx.paneLabel,
      kind: longest.kind, anchor: longest.anchor, tipTextLen: (longest.text || '').length, tipText: longest.text,
      mode: 'hover-longest', synthetic: false, advisory: false, failures: [], warnings: [], shot: null,
    };
    const st = await hoverAndSnap(s, g, longest);
    if (!st || !st.ok) c.failures.push({ check: 'tip-reachable', detail: (st && st.reason) || 'no state' });
    else {
      c.state = slim(st);
      if (!st.shown) c.failures.push({ check: 'shown-on-hover', detail: 'opacity=' + st.opacity });
      for (const f of failuresOf(st)) c.failures.push(f);
      const mw = parseFloat(st.maxWidth);
      // max-width 作用于 content box（.tip::after 是默认的 content-box），
      // rect.w 含左右 padding(10+10)+border(1+1)，直接比会永远"超宽"。
      if (!isNaN(mw) && st.contentW > mw + 1.5) {
        c.failures.push({ check: 'max-width-clamped', detail: '内容宽 ' + Math.round(st.contentW) + ' > max-width ' + mw });
      }
      if ((longest.text || '').length > 80 && st.rect.h < 24) {
        c.failures.push({ check: 'wrapped-lines', detail: '长文没有换行（h=' + Math.round(st.rect.h) + '）' });
      }
      c.shot = path.join(shotDir, 'adv-longest.png');
      try { await shotT(s, c.shot); } catch (e) { c.shot = null; }
    }
    out.push(c);
  }

  // RE2：右边界（真实页面）—— 只断言变换后的真实四边不溢出，不规定 tip-r/tip-d 实现。
  {
    const rightMost = await evalT(s, js(
      'const list = (tipList(' + J(g) + ') || []).filter(function (e) { const r = e.getClientRects(); return r.length && r[0].width > 0; });\n' +
      'if (!list.length) return null;\n' +
      'let best = null, bx = -1;\n' +
      'for (let i = 0; i < list.length; i++) { const r = list[i].getBoundingClientRect(); if (r.left > bx) { bx = r.left; best = { text: list[i].getAttribute("data-tip") || "", kind: kindOf(list[i]), anchor: anchorOf(list[i]), left: r.left }; } }\n' +
      'return best;'
    ));
    if (rightMost) {
      const c = {
        id: ctx.width + '/' + g + '/adv-right', width: ctx.width, height: ctx.height, pane: g, paneLabel: ctx.paneLabel,
        kind: rightMost.kind, anchor: rightMost.anchor, tipText: rightMost.text, mode: 'hover-right-edge',
        synthetic: false, advisory: false, failures: [], warnings: [], shot: null,
      };
      const st = await hoverAndSnap(s, g, rightMost);
      if (!st || !st.ok) c.failures.push({ check: 'tip-reachable', detail: (st && st.reason) || 'no state' });
      else {
        c.state = slim(st);
        if (!st.shown) c.failures.push({ check: 'shown-on-hover', detail: 'opacity=' + st.opacity });
        for (const f of failuresOf(st)) c.failures.push(f);
        c.shot = path.join(shotDir, 'adv-right.png');
        try { await shotT(s, c.shot); } catch (e) { c.shot = null; }
      }
      out.push(c);
    }
  }

  // RE3：底部滚动（真实页面）—— 滚到该页最底，悬停最后一个 tip，仍须完整可见
  {
    const last = await evalT(s, js(
      'const host = scrollHostOf(paneOf(' + J(g) + ') || document.body);\n' +
      'if (host) host.scrollTop = host.scrollHeight;\n' +
      'const list = (tipList(' + J(g) + ') || []).filter(function (e) { const r = e.getClientRects(); return r.length && r[0].width > 0; });\n' +
      'const el = list.length ? list[list.length - 1] : null;\n' +
      'return el ? { text: el.getAttribute("data-tip") || "", kind: kindOf(el), anchor: anchorOf(el), scrollTop: host ? host.scrollTop : 0 } : null;'
    ));
    if (last && (last.text || '').trim()) {
      const c = {
        id: ctx.width + '/' + g + '/adv-bottom', width: ctx.width, height: ctx.height, pane: g, paneLabel: ctx.paneLabel,
        kind: last.kind, anchor: last.anchor, tipText: last.text, mode: 'hover-bottom-scrolled',
        synthetic: false, advisory: false, failures: [], warnings: [], shot: null,
      };
      const st = await hoverAndSnap(s, g, last, true);
      if (!st || !st.ok) c.failures.push({ check: 'tip-reachable', detail: (st && st.reason) || 'no state' });
      else {
        c.state = slim(st);
        if (!st.shown) c.failures.push({ check: 'shown-on-hover', detail: 'opacity=' + st.opacity });
        for (const f of failuresOf(st)) c.failures.push(f);
        c.shot = path.join(shotDir, 'adv-bottom.png');
        try { await shotT(s, c.shot); } catch (e) { c.shot = null; }
      }
      out.push(c);
    }
    // 复原滚动位置，避免影响同一页后面的用例
    await evalT(s, js('const host = scrollHostOf(paneOf(' + J(g) + ') || document.body); if (host) host.scrollTop = 0;'));
  }

  // SY1：合成用例（600 字），插进该页第一个 .sgbody，测完立刻移除。
  // 目的：验证"超长文案在 max-width 下换行且不被裁剪"。合成用例 advisory=true，永不影响退出码。
  {
    const c = {
      id: ctx.width + '/' + g + '/syn-long', width: ctx.width, height: ctx.height, pane: g, paneLabel: ctx.paneLabel,
      kind: 'synthetic', anchor: 'syn-long', tipTextLen: 600, tipText: '(合成)600字长文',
      mode: 'hover-synthetic-long', synthetic: true, advisory: true, failures: [], warnings: [], shot: null,
    };
    const sy = await evalT(s, js(
      'const pane = paneOf(' + J(g) + ');\n' +
      'if (!pane) return { ok: false, reason: "pane-missing" };\n' +
      'const hostBox = pane.querySelector(".sgbody") || pane;\n' +
      'const wrap = document.createElement("div");\n' +
      'wrap.setAttribute("data-tipcheck-synthetic", "1");\n' +
      'wrap.className = "sfld wide";\n' +
      'wrap.style.cssText = "margin:6px 0";\n' +
      'const lab = document.createElement("label");\n' +
      'lab.appendChild(document.createTextNode("合成用例"));\n' +
      'const sp = document.createElement("span");\n' +
      'sp.className = "tip"; sp.setAttribute("tabindex", "0"); sp.setAttribute("role", "note");\n' +
      'const unit = "合成用例：用于验证超长提示在 max-width 下换行且四边不被裁剪。";\n' +
      'let t = ""; while (t.length < 600) t += unit;\n' +
      'sp.setAttribute("data-tip", t.slice(0, 600)); sp.textContent = "?";\n' +
      'lab.appendChild(sp); wrap.appendChild(lab); hostBox.appendChild(wrap);\n' +
      'const r = sp.getBoundingClientRect();\n' +
      'return { ok: true, cx: Math.round(r.left + r.width / 2), cy: Math.round(r.top + r.height / 2), text: sp.getAttribute("data-tip") };'
    ));
    if (!sy || !sy.ok) {
      c.warnings.push('合成用例未能插入：' + ((sy && sy.reason) || 'unknown'));
    } else {
      try {
        const prep = await evalT(s, js(
          'const sp = document.querySelector("[data-tipcheck-synthetic] .tip");\n' +
          'if (!sp) return { ok: false };\n' +
          'sp.scrollIntoView({ block: "nearest", inline: "nearest" });\n' +
          'const r = sp.getBoundingClientRect();\n' +
          'const hit = document.elementFromPoint(Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2));\n' +
          'return { ok: true, cx: Math.round(r.left + r.width / 2), cy: Math.round(r.top + r.height / 2),\n' +
          '  hitSelf: !!(hit && (hit === sp || sp.contains(hit))), hit: describe(hit) };\n'
        ));
        if (prep && prep.ok) {
          await mouseMove(s, prep.cx, prep.cy);
          const st = await evalT(s, js(
            'const sp = document.querySelector("[data-tipcheck-synthetic] .tip");\n' +
            'if (!sp) return { ok: false, reason: "gone" };\n' +
            'return Object.assign({ ok: true }, snap(sp));\n'
          ));
          if (st && st.ok) {
            c.state = slim(st);
            const mw = parseFloat(st.maxWidth);
            if (!st.shown) c.warnings.push('合成长文 hover 后不可见 opacity=' + st.opacity);
            if (!isNaN(mw) && st.contentW > mw + 1.5) c.warnings.push('合成长文未被 max-width 夹住：内容宽=' + Math.round(st.contentW) + ' > ' + mw);
            if (st.rect.h < 40) c.warnings.push('合成长文没有换行：h=' + Math.round(st.rect.h));
            for (const o of (st.overflow || [])) c.warnings.push('合成长文被 ' + o.by + ' 裁掉 ' + o.px + 'px');
            c.shot = path.join(shotDir, 'syn-long.png');
            try { await shotT(s, c.shot); } catch (e) { c.shot = null; }
          }
        }
      } finally {
        await evalT(s, js('const n = document.querySelectorAll("[data-tipcheck-synthetic]"); for (let i = 0; i < n.length; i++) n[i].remove(); return n.length;'));
      }
    }
    out.push(c);
  }
  return out;
}

const slim = (st) => ({
  rect: st.rect, tipRect: st.tipRect, measureMode: st.measureMode, anchor: st.anchor, maxWidth: st.maxWidth,
  contentW: st.contentW, contentH: st.contentH,
  opacity: st.opacity, visibility: st.visibility, scrollTop: st.scrollTop, scrollHost: st.scrollHost,
  viewport: st.viewport, clipAncestors: st.clipAncestors, overflow: st.overflow,
});

async function hoverAndSnap(s, g, tip, alreadyScrolled) {
  const text = tip.text || '';
  let nth = tip.nth;
  if (nth == null || !isFinite(nth)) {
    nth = await evalT(s, js(
      'const list = tipList(' + J(g) + ') || [];\n' +
      'let n = 0; for (let i = 0; i < list.length; i++) if ((list[i].getAttribute("data-tip") || "") === ' + J(text) + ') { n++; break; }\n' +
      'return Math.max(0, n - 1);'
    ));
  }
  if (nth == null || !isFinite(nth)) nth = 0;
  const prep = alreadyScrolled
    ? await evalT(s, js(
      'const el = resolveTip(' + J(g) + ', ' + J(text) + ', ' + Math.max(0, nth) + ');\n' +
      'if (!el) return { ok: false, reason: "tip-gone" };\n' +
      'const r = el.getBoundingClientRect();\n' +
      'const hit = document.elementFromPoint(Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2));\n' +
      'return { ok: true, cx: Math.round(r.left + r.width / 2), cy: Math.round(r.top + r.height / 2), hitSelf: !!(hit && (hit === el || el.contains(hit))), hit: describe(hit) };'
    ))
    : await prepareHover(s, g, text, Math.max(0, nth));
  if (!prep || !prep.ok) return prep || { ok: false, reason: 'prepare-failed' };
  if (prep.hitSelf === false) return Object.assign({ ok: false, reason: 'hidden-behind:' + prep.hit }, prep);
  await mouseMove(s, prep.cx, prep.cy);
  return await waitShown(s, g, text, Math.max(0, nth), 500);
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. 一个宽度的全量回归
// ─────────────────────────────────────────────────────────────────────────────
async function runWidth(s, o, width, panes, report, shotsRoot) {
  const ctx = { o: o, width: width, height: o.height, cases: [], paneLabel: '' };
  report.coverage.push({ width: width, height: o.height, panes: [] });

  await s.setViewport(width, o.height);
  await sleep(350);
  const setSt = o.__fixture ? { ok: true } : await ensureSettings(s, o);
  if (!setSt.ok) { report.setup.push('width ' + width + ': 无法进入设置页'); return ctx; }

  // 页签集合核对：数量 + 文案都要对得上，页签被改名/被删时立刻暴露
  const tabs = await evalT(s, js(
    'const bs = document.querySelectorAll("#setpage .stab");\n' +
    'return Array.prototype.map.call(bs, function (b) { return { g: b.getAttribute("data-g"), text: (b.textContent || "").trim() }; });'
  ));
  report.tabs = tabs;
  const tabIssues = [];
  for (const p of PANES) {
    const t = tabs.find((x) => x.g === p.g);
    if (!t) tabIssues.push('缺少页签 data-g=' + p.g + '（' + p.label + '）');
    else if (t.text !== p.label) tabIssues.push('页签 data-g=' + p.g + ' 文案=' + JSON.stringify(t.text) + ' 期望 ' + JSON.stringify(p.label));
  }
  if (tabIssues.length) report.warnings.push('页签核对: ' + tabIssues.join('; '));

  for (const p of panes) {
    const g = p.g;
    ctx.paneLabel = p.label;
    const shotDir = path.join(shotsRoot, 'w' + width, g);
    const cov = {
      g: g, label: p.label, switch: null, total: 0, visible: 0, hidden: 0,
      header: 0, inline: 0, tested: 0, firstInlineTested: false, firstHeaderTested: false,
      hiddenSamples: [], notes: [],
    };
    report.coverage[report.coverage.length - 1].panes.push(cov);

    const sw = await switchPane(s, g);
    cov.switch = sw;
    if (!sw.ok) {
      report.setup.push('width ' + width + ' pane ' + g + ': 页签切不过去（tabOn=' + sw.tabOn + '）');
      cov.notes.push('页签切换失败');
      continue;
    }
    if (sw.clickFallback) report.warnings.push('width ' + width + ' pane ' + g + ': 真实点击未生效，已退回 JS click');
    await sleep(o.settle);

    // 折叠区（元数据「高级选项」）默认不展开：里面的 tip 是 display:none，属于"用户看不到"的合法隐藏
    if (o.expandCollapsed) {
      const more = await evalT(s, js(
        'const b = document.getElementById("sp_metamore");\n' +
        'const adv = document.getElementById("sp_metaadv");\n' +
        'if (!b || !adv) return { ok: false };\n' +
        'if (adv.style.display === "none") { b.click(); }\n' +
        'return { ok: true, display: adv.style.display };'
      ));
      if (more && more.ok) { cov.notes.push('已展开高级选项（--expand-collapsed）'); await sleep(250); }
    }
    // 回到页顶：顶部 .tip 必须在自然滚动位置被测试
    await evalT(s, js(
      'const host = scrollHostOf(paneOf(' + J(g) + ') || document.body);\n' +
      'if (host) host.scrollTop = 0;\n' +
      'window.scrollTo(0, 0);\n' +
      'return true;'
    ));
    await sleep(120);

    const en = await enumerateTips(s, g);
    if (!en || !en.ok) { cov.notes.push('枚举失败: ' + ((en && en.reason) || 'unknown')); continue; }
    cov.total = en.total;
    const vis = en.tips.filter((t) => t.visible);
    cov.visible = vis.length;
    cov.hidden = en.total - vis.length;
    cov.hiddenSamples = en.tips.filter((t) => !t.visible).slice(0, 6).map((t) => ({ kind: t.kind, anchor: t.anchor, len: (t.text || '').length }));
    cov.header = vis.filter((t) => t.kind === 'header').length;
    cov.inline = vis.filter((t) => t.kind !== 'header').length;

    // 覆盖判据：页内至少要有一个可测 tip，否则"通过"是空的（铁律 3）
    if (!vis.length) {
      report.cases.push({
        id: width + '/' + g + '/coverage', width: width, height: o.height, pane: g, paneLabel: p.label,
        kind: 'coverage', anchor: '-', mode: 'coverage', synthetic: false, advisory: false,
        failures: [{ check: 'pane-has-tips', detail: '该页没有任何可见 .tip' }], warnings: [], shot: null,
      });
    }
    if (!cov.header) cov.notes.push('该页没有 .sghead 标题 tip（标题 tip 覆盖缺一项）');
    if (!cov.inline) cov.notes.push('该页没有行内 tip');

    // 每页一张干净图（可肉眼审查整页版式）
    const topShot = path.join(shotDir, 'top.png');
    try { await shotT(s, topShot); } catch (e) { /* 截图失败不致命，但下面会记 */ }
    cov.shotTop = topShot;

    let firstHoverShotDone = false;
    let firstInlineSeen = false, firstHeaderSeen = false;
    for (let i = 0; i < vis.length; i++) {
      const t = vis[i];
      const c = await testTipHover(s, ctx, g, t, i + 1);
      ctx.cases.push(c);
      cov.tested++;
      if (t.kind === 'header' && !firstHeaderSeen) { firstHeaderSeen = true; cov.firstHeaderTested = true; }
      if (t.kind !== 'header' && !firstInlineSeen) { firstInlineSeen = true; cov.firstInlineTested = true; }
      // 截图策略：fail=只留失败；pane=每页第一个 + 失败；all=全留
      const wantShot = (o.shots === 'all') || (o.shots === 'pane' && !firstHoverShotDone) || (c.failures.length > 0);
      if (wantShot) {
        c.shot = path.join(shotDir, pad2(i + 1) + (c.failures.length ? '-FAIL-' : '-hover-') + slug(t.anchor || t.kind) + '.png');
        try { await shotT(s, c.shot); } catch (e) { c.shot = null; }
        if (!c.failures.length) firstHoverShotDone = true;
      }
      if (o.shots === 'all') firstHoverShotDone = true;
    }
    // 还原鼠标位置，避免残留 hover 影响后面的 Tab 用例
    await mouseMove(s, 1, 1);
    await sleep(120);

    // 焦点路径：默认只对「元数据」做（用户要求：两个行内 tip 必须用真实 Tab 验）；
    // --tab-sweep 则每页都走一遍。
    const needFocus = (g === 'meta') || o.tabSweep;
    if (needFocus) {
      const targets = vis.filter((t) => (t.text || '').trim()).map((t) => ({ text: t.text, nth: 0, kind: t.kind, anchor: t.anchor }));
      // 同名文案要按出现次序给 nth
      const seen = new Map();
      for (const t of targets) {
        const k = t.text;
        if (seen.has(k)) { seen.set(k, seen.get(k) + 1); t.nth = seen.get(k); } else seen.set(k, 0);
      }
      // 从该页签按钮获得起始焦点（真实点击），再按 Tab 往前走
      await clickSelectorReal(s, '#setpage .stab[data-g="' + g + '"]');
      await sleep(150);
      const swp = await tabSweep(s, ctx, g, targets, shotDir);
      cov.focus = swp;
      if (g === 'meta') {
        const need = ['sp_metaon', 'sp_metallm'];
        for (const id of need) {
          const got = vis.some((t) => t.anchor === id);
          if (!got) {
            report.cases.push({
              id: width + '/meta/required-' + id, width: width, height: o.height, pane: g, paneLabel: p.label,
              kind: 'label', anchor: id, mode: 'coverage', synthetic: false, advisory: false,
              failures: [{ check: 'meta-required-tip', detail: '元数据页没有找到 ' + id + ' 的行内 tip' }], warnings: [], shot: null,
            });
          }
        }
        for (const m of swp.missing) {
          if (need.includes(m.anchor)) {
            report.cases.push({
              id: width + '/meta/tab-' + m.anchor, width: width, height: o.height, pane: g, paneLabel: p.label,
              kind: 'label', anchor: m.anchor, mode: 'focus', synthetic: false, advisory: false,
              failures: [{ check: 'tab-reaches-tip', detail: '真实 Tab 走了 ' + swp.presses + ' 次仍未落到 ' + m.anchor + '（tabindex=0 的 tip 应可达）' }],
              warnings: [], shot: null,
            });
          }
        }
      }
    }

    if (o.adversarial) {
      const adv = await adversarialForPane(s, ctx, g, vis, shotDir);
      for (const c of adv) report.cases.push(c);
      cov.adversarial = adv.length;
      await evalT(s, js(
        'const host = scrollHostOf(paneOf(' + J(g) + ') || document.body);\n' +
        'if (host) host.scrollTop = 0;\n' +
        'return true;'
      ));
      await mouseMove(s, 1, 1);
    }
  }
  return ctx;
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. 自检（只验探针本身，不碰产品）：给探针一份"已知红/已知绿"的合成页面
// ─────────────────────────────────────────────────────────────────────────────
const FIXTURE = [
  '<!doctype html><meta charset=utf-8><title>tipcheck selftest</title>',
  '<style>',
  ':root{--bg2:#141414;--bg3:#1e1e1e;--txt2:#ddd;--line:#333;--line2:#3a3a3a;--mut2:#888;--acc:#4d8;--shadow:#000;--bg:#0f0f0f}',
  'html,body{margin:0;height:100%;background:var(--bg);color:#eee;font:13px/1.5 -apple-system,sans-serif}',
  '#app{display:flex;height:100vh}',
  '#setpage{display:flex;flex:1;min-height:0;flex-direction:column;overflow:hidden}',
  '.stabs{display:flex;gap:4px;padding:14px 24px 12px;border-bottom:1px solid var(--line);flex:none}',
  '.sbody{flex:1;min-height:0;overflow-y:auto;overflow-x:hidden;padding:0 24px 24px}',
  '.spane{display:none}.spane.on{display:flex;flex-direction:column;min-height:100%;box-sizing:border-box}',
  '.sgroup{margin-bottom:22px;border:1px solid var(--line);border-radius:12px;background:var(--bg2);overflow:visible}',
  '.sghead{display:flex;align-items:center;gap:9px;padding:11px 16px;border-bottom:1px solid var(--line);font-weight:650;font-size:12.5px;background:var(--bg3);border-radius:11px 11px 0 0}',
  '.sgbody{padding:14px 16px;display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:14px 20px}',
  '.sfld.wide{grid-column:1/-1}',
  '.tip{display:inline-flex;align-items:center;justify-content:center;width:15px;height:15px;margin-left:5px;border-radius:50%;border:1px solid var(--line2,var(--line));color:var(--mut2);font-size:9.5px;font-weight:700;line-height:1;cursor:help;vertical-align:1px;position:relative;user-select:none;flex:none}',
  '.tip:hover,.tip:focus{border-color:var(--acc);color:var(--acc);outline:0}',
  '.tip::after{content:attr(data-tip);position:absolute;left:-10px;bottom:calc(100% + 8px);transform:none;width:max-content;max-width:290px;background:var(--bg3);color:var(--txt2);border:1px solid var(--line);border-radius:9px;padding:8px 10px;font-size:11px;line-height:1.6;font-weight:400;white-space:normal;text-align:left;box-shadow:0 10px 28px var(--shadow);opacity:0;visibility:hidden;transition:opacity .12s,transform .12s;z-index:40;pointer-events:none}',
  '.tip.tip-r::after{left:auto;right:-10px;transform:none}',
  '.tip:hover::after,.tip:focus::after{opacity:1;visibility:visible}',
  '.sghead .tip::after{bottom:auto;top:calc(100% + 8px)}',
  '@media (max-width:1200px){.tip::after{max-width:min(240px,42vw)}}',
  '.spacer{height:420px}',
  '</style>',
  '<div id=app><div id=setpage>',
  '<div class=stabs>',
  '<button class="stab on" data-g=in>输入</button>',
  '<button class=stab data-g=meta>元数据</button>',
  '</div>',
  '<div class=sbody>',
  // ── 已知红：tip 贴着 .sbody 上边界 → 气泡向上展开必被裁 ──
  '<div class="spane on" data-g=in>',
  '<div class="sfld wide" style="margin:0"><label>顶部贴边<span class="tip" tabindex=0 role=note data-tip="贴边提示：这个气泡向上展开一定会被 .sbody 的上边界裁掉，用于验证探针能抓到真实的裁切。">?</span></label></div>',
  '<div class=spacer></div>',
  '<div class=sgroup><div class=sghead>分组标题<span class=tip tabindex=0 role=note data-tip="标题提示：向下展开，正常。">?</span></div>',
  '<div class=sgbody>',
  // ── 已知绿：居中位置，气泡完整可见 ──
  '<div class=sfld><label>正常行内<span class="tip" tabindex=0 role=note data-tip="正常提示：短文案，气泡在视口内完整可见。">?</span></label></div>',
  // ── 已知绿：长文，应被 max-width 夹住并换行 ──
  '<div class="sfld wide"><label>长文案<span class="tip" tabindex=0 role=note data-tip="长文提示：用于验证 max-width 夹紧与自动换行，文案需要足够长才会折成多行，这一段故意写得比普通说明长很多很多，用来确认气泡不会被 nowrap 撑爆宽度，也不会因为多行而超出裁剪区。">?</span></label></div>',
  '</div></div>',
  '</div>',
  // ── 元数据页：两个行内 tip，用于 Tab 可达性自检 ──
  '<div class=spane data-g=meta>',
  '<div class=sgroup><div class=sghead>元数据补全<span class=tip tabindex=0 role=note data-tip="标题提示。">?</span></div>',
  '<div class=sgbody>',
  '<div class="sfld wide"><label class=chk><input type=checkbox id=sp_metaon><span id=sp_metaon_lbl>自动补全</span><span class=tip tabindex=0 role=note data-tip="第一个行内提示。">?</span></label></div>',
  '<div class="sfld wide"><label class=chk><input type=checkbox id=sp_metallm><span id=sp_metallm_lbl>AI 增强</span><span class=tip tabindex=0 role=note data-tip="第二个行内提示。">?</span></label></div>',
  '<div class=spacer></div>',
  '</div></div>',
  '</div>',
  '</div></div></div>',
  '<script>window.S={view:"settings"};function setView(v){window.S.view=v;}',
  // fixture 的页签切换：与产品 renderSettingsPage 绑定逻辑等价（.stab.on + .spane.on）
  'document.querySelectorAll("#setpage .stab").forEach(function(b){b.onclick=function(){',
  '  document.querySelectorAll("#setpage .stab").forEach(function(x){x.classList.toggle("on",x===b);});',
  '  document.querySelectorAll("#setpage .spane").forEach(function(p){p.classList.toggle("on",p.dataset.g===b.dataset.g);});',
  '};});</script>',
].join('\n');

// 自检专用：用真实 DOM 参考盒的 getBoundingClientRect 交叉核对伪元素探针。
// 不在产品页面插参考盒；不拿同一份矩阵公式当 expected，避免实现与测试一起算错。
async function selftestGeometry(s, o) {
  const checks = await evalT(s, js(`
    const host = document.createElement('div');
    host.id = 'tipcheck-geometry';
    host.style.cssText = 'position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:9999;pointer-events:none';
    const style = document.createElement('style');
    style.textContent = '#tipcheck-geometry .probe::after{content:"";position:absolute;display:block;opacity:1;visibility:visible;transition:none}';
    host.appendChild(style); document.body.appendChild(host);
    const results = [];
    const variants = [
      { name:'content-box/translate', sizing:'content-box', transform:'translate(31px,-17px)', origin:'50% 50%', right:false },
      { name:'border-box/origin/rotate-scale', sizing:'border-box', transform:'translate(-23px,19px) rotate(23deg) scale(1.2,.8)', origin:'17px 80%', right:true },
      { name:'content-box/origin/matrix3d', sizing:'content-box', transform:'translate3d(13px,-11px,0) rotate(-13deg)', origin:'75% 9px 3px', right:true }
    ];
    try {
      for (const v of variants) {
        const el = document.createElement('span');
        el.className = 'probe';
        el.style.cssText = 'position:absolute;left:400px;top:350px;width:40px;height:30px;border-style:solid;border-width:3px 5px 7px 11px;padding:2px 4px';
        const css = 'position:absolute;display:block;box-sizing:' + v.sizing + ';width:120px;height:80px;padding:5px 9px 13px 17px;border:2px solid;'
          + (v.right ? 'left:auto;right:-12px;top:auto;bottom:calc(100% + 8px);' : 'left:-10px;right:auto;top:calc(100% + 8px);bottom:auto;')
          + 'transform:' + v.transform + ';transform-origin:' + v.origin + ';';
        const rule = document.createElement('style');
        rule.textContent = '#tipcheck-geometry .probe::after{' + css + '}';
        host.appendChild(rule); host.appendChild(el);
        const ref = document.createElement('div'); ref.style.cssText = css; el.appendChild(ref);
        const actual = pseudoGeom(el), expected = ref.getBoundingClientRect();
        const delta = Math.max(Math.abs(actual.x - expected.left), Math.abs(actual.y - expected.top),
          Math.abs(actual.w - expected.width), Math.abs(actual.h - expected.height));
        const clone = measureClone(el, getComputedStyle(el, '::after'));
        const cs = getComputedStyle(el, '::after');
        // 空文案克隆只剩 padding+border：content-box 应返回0，border-box应返回30×22。
        const cloneOk = Math.abs(clone.w - (cs.boxSizing === 'border-box' ? 30 : 0)) <= .1
          && Math.abs(clone.h - (cs.boxSizing === 'border-box' ? 22 : 0)) <= .1;
        results.push({ name:v.name, ok:delta <= .1 && cloneOk, delta:delta, actual:actual,
          expected:{x:expected.left,y:expected.top,w:expected.width,h:expected.height} });
        el.remove(); rule.remove();
      }
      for (const dir of ['left', 'right', 'top', 'bottom', 'green']) {
        const clip = document.createElement('div');
        clip.style.cssText = 'position:absolute;left:300px;top:200px;width:200px;height:200px;overflow:hidden;border:3px solid';
        const el = document.createElement('span'); el.className = 'probe';
        el.style.cssText = 'position:absolute;left:80px;top:80px;width:20px;height:20px';
        const rule = document.createElement('style');
        const dx = dir === 'left' ? -100 : dir === 'right' ? 100 : 0;
        const dy = dir === 'top' ? -100 : dir === 'bottom' ? 100 : 0;
        rule.textContent = '#tipcheck-geometry .probe::after{box-sizing:border-box;width:80px;height:60px;left:0;top:0;right:auto;bottom:auto;transform:translate(' + dx + 'px,' + dy + 'px)}';
        host.appendChild(rule); host.appendChild(clip); clip.appendChild(el);
        const st = snap(el);
        const clipped = st.overflow.some(function (c) { return c.dirs.includes(dir); });
        results.push({ name:'transformed-' + dir, ok:dir === 'green' ? !st.overflow.length : clipped, state:st });
        clip.remove(); rule.remove();
      }
    } finally { host.remove(); }
    return results;
  `));
  fs.writeFileSync(path.join(o.out, 'geometry-selftest.json'), JSON.stringify(checks, null, 2));
  for (const c of checks) console.log((c.ok ? 'PASS ' : 'FAIL ') + '几何交叉自检 ' + c.name +
    (c.delta == null ? '' : ' 最大偏差=' + c.delta.toFixed(4) + 'px'));
  return checks.filter((c) => !c.ok).length;
}

// ── 编排层自检：用同一份 fixture 跑完整 runWidth（切页签/逐 tip/截图/对抗用例）
//    再用同一份 applyBaseline 走"记录 → 比对 → 人为漏一条"的往返。
//    目的只有一个：证明主控真正会跑到的那条路径（而不是只有几何函数）是通的。
async function runSelftestFull(s, o) {
  const say = (ok, msg) => { console.log((ok ? 'PASS ' : 'FAIL ') + msg); return ok; };
  let fails = 0;
  const FX = [{ g: 'in', label: '输入' }, { g: 'meta', label: '元数据' }];
  const shotsRoot = path.join(o.out, 'full', 'shots');
  const report = { coverage: [], warnings: [], setup: [], cases: [], tabs: [], limitations: [] };
  const fxOpts = Object.assign({}, o, {
    __fixture: true, verbose: false, shots: 'pane', adversarial: true, expandCollapsed: false, tabSweep: false,
  });
  const widths = o.widths;
  for (const w of widths) {
    const ctx = await runWidth(s, fxOpts, w, FX, report, shotsRoot);
    for (const c of ctx.cases) report.cases.push(c);
  }
  const hard = report.cases.filter((c) => !c.synthetic);
  const hardFails = hard.filter((c) => c.failures.length);
  const synth = report.cases.filter((c) => c.synthetic);

  // ① 覆盖：每个宽度的两个页签都要真的测到 tip
  const covBad = [];
  for (const w of report.coverage) {
    for (const g of ['in', 'meta']) {
      const cov = w.panes.find((p) => p.g === g);
      if (!cov || !cov.visible) covBad.push('w' + w.width + '/' + g);
    }
  }
  if (!say(report.coverage.length === widths.length && !covBad.length,
    '覆盖：' + report.coverage.length + '/' + widths.length + ' 个宽度、每页都有可见 tip（问题：' + (covBad.join(',') || '无') + '）')) fails++;

  // ② 红用例在每个宽度都必须被抓到（顶部贴边的气泡）
  const redByWidth = {};
  for (const w of widths) {
    redByWidth[w] = hardFails.filter((c) => c.width === w && c.anchor === 'label:顶部贴边' && c.failures.some((f) => f.check === 'fully-visible')).length;
  }
  if (!say(Object.values(redByWidth).every((n) => n > 0), '红用例在 3 个宽度都被判失败：' + JSON.stringify(redByWidth))) fails++;

  // ③ 截图：每宽度每页都有 top.png
  const missingShots = [];
  for (const w of widths) for (const g of ['in', 'meta']) {
    const f = path.join(shotsRoot, 'w' + w, g, 'top.png');
    if (!fs.existsSync(f)) missingShots.push('w' + w + '/' + g);
  }
  if (!say(!missingShots.length, '逐页截图落盘（缺：' + (missingShots.join(',') || '无') + '）')) fails++;

  // ④ 对抗用例：真实 3 类 + 合成 1 类，合成必须标 advisory
  const advReal = report.cases.filter((c) => /^hover-(longest|right-edge|bottom-scrolled)$/.test(c.mode));
  const advSyn = synth.filter((c) => c.mode === 'hover-synthetic-long');
  if (!say(advReal.length >= 3 && advSyn.length >= 1 && advSyn.every((c) => c.advisory),
    '对抗用例：真实 ' + advReal.length + ' 条、合成 ' + advSyn.length + ' 条（合成 advisory=' +
    JSON.stringify(advSyn.map((c) => c.advisory)) + '）')) fails++;
  const synWarn = advSyn.reduce((n, c) => n + (c.warnings || []).length, 0);
  console.log('     合成用例提示 ' + synWarn + ' 条：' + JSON.stringify(advSyn.map((c) => c.warnings).flat().slice(0, 4)));

  // ⑤ 焦点路径（元数据页由 runWidth 默认触发）
  const focusCases = report.cases.filter((c) => c.mode === 'focus');
  if (!say(focusCases.length >= 2 && focusCases.every((c) => !c.failures.some((f) => f.check === 'shown-on-focus')),
    '焦点路径：' + focusCases.length + ' 条（Tab 点亮气泡）')) fails++;

  // ⑥ baseline 往返：记录 → 比对（无回归）→ 人为制造一条新增失败 → 必须报 red
  const bl = path.join(o.out, 'full', 'baseline.json');
  try { fs.rmSync(bl, { force: true }); } catch (e) { }
  const r1 = { mode: 'run', warnings: [] };
  const c1 = applyBaseline({ baseline: bl }, r1, hardFails);
  const recorded = fs.existsSync(bl) ? JSON.parse(fs.readFileSync(bl, 'utf8')) : null;
  if (!say(c1 === 0 && r1.mode === 'baseline-record' && recorded && recorded.count === hardFails.length,
    'baseline 记录：mode=' + r1.mode + ' exit=' + c1 + ' count=' + (recorded && recorded.count) + '/' + hardFails.length)) fails++;

  const r2 = { mode: 'run', warnings: [] };
  const c2 = applyBaseline({ baseline: bl }, r2, hardFails);
  if (!say(c2 === 0 && r2.mode === 'baseline-compare' && r2.baseline.regressions.length === 0 && r2.baseline.fixed.length === 0,
    'baseline 比对（同一批失败）：exit=' + c2 + ' regressions=' + r2.baseline.regressions.length + ' fixed=' + r2.baseline.fixed.length)) fails++;

  const r3 = { mode: 'run', warnings: [] };
  const fake = hardFails.concat([{ pane: 'in', kind: 'label', anchor: 'label:新坏的地方', width: widths[0], failures: [{ check: 'fully-visible' }] }]);
  const c3 = applyBaseline({ baseline: bl }, r3, fake);
  if (!say(c3 === 1 && r3.baseline.regressions.length === 1,
    'baseline 比对（新增一条失败）：exit=' + c3 + ' regressions=' + JSON.stringify(r3.baseline.regressions))) fails++;

  const r4 = { mode: 'run', warnings: [] };
  const c4 = applyBaseline({ baseline: bl }, r4, []);
  if (!say(c4 === 0 && r4.baseline.fixed.length === recorded.count,
    'baseline 比对（全部修好）：exit=' + c4 + ' fixed=' + r4.baseline.fixed.length + '/' + recorded.count)) fails++;

  fs.writeFileSync(path.join(o.out, 'full', 'cases.json'), JSON.stringify({
    summary: { cases: report.cases.length, hard: hard.length, hardFails: hardFails.length, synthetic: synth.length },
    coverage: report.coverage,
  }, null, 2));
  console.log('     （证据：' + path.join(o.out, 'full') + '）');
  return fails;
}

async function runSelftest(o) {
  const say = (ok, msg) => { console.log((ok ? 'PASS ' : 'FAIL ') + msg); return ok; };
  let fails = 0;
  let s = null;
  const port = o.port === 19094 ? 19095 : o.port;
  try {
    s = await ub.open({ url: 'data:text/html;charset=utf-8,' + encodeURIComponent(FIXTURE), width: 1576, height: 908, port: port });
    await withTimeout(s.waitFor('!!document.getElementById("setpage")', 15000), 18000, 'waitFor(fixture)');
    const ctx = { o: Object.assign({}, o, { verbose: true, shots: 'fail', adversarial: false }), width: 1576, height: 908, cases: [], paneLabel: '输入' };
    const shots = path.join(o.out, 'selftest');
    fs.mkdirSync(shots, { recursive: true });

    const en = await enumerateTips(s, 'in');
    if (!say(en && en.ok && en.total === 4, '枚举：in 页应有 4 个 tip，实得 ' + (en && en.total))) fails++;

    const tips = en.tips;
    const byAnchorText = (kw) => tips.find((t) => (t.text || '').indexOf(kw) >= 0);
    const clipped = byAnchorText('贴边');
    const normal = byAnchorText('短文案');   // 用唯一子串：'正常' 会误命中标题文案「…向下展开，正常。」
    const long = byAnchorText('长文');
    say(!!clipped && !!normal && !!long, '定位三个 fixture tip');
    if (!(clipped && normal && long)) { console.log('自检无法继续'); }
    else {
      const cClip = await testTipHover(s, ctx, 'in', clipped, 1);
      const cNorm = await testTipHover(s, ctx, 'in', normal, 2);
      const cLong = await testTipHover(s, ctx, 'in', long, 3);
      // ① 底部/顶部贴边那条必须被抓出来（探针的红）
      const gotClip = cClip.failures.some((f) => f.check === 'fully-visible' && /sbody/.test(f.detail));
      if (!say(gotClip, '红用例：顶部贴边气泡应被判 fully-visible 失败，实际 ' + JSON.stringify(cClip.failures))) fails++;
      // ② 正常那条必须全绿
      if (!say(cNorm.failures.length === 0, '绿用例：正常气泡应全绿，实际 ' + JSON.stringify(cNorm.failures))) fails++;
      // ③ 长文：max-width 夹住 + 换行（h >= 2 行）
      const mw = parseFloat((cLong.state || {}).maxWidth);
      const okMw = cLong.state && (!isNaN(mw) ? cLong.state.contentW <= mw + 1.5 : true);
      const okWrap = cLong.state && cLong.state.rect.h >= 30;
      if (!say(okMw && okWrap, '长文：内容宽 ' + (cLong.state && Math.round(cLong.state.contentW)) + ' ≤ max-width ' + mw +
        '，气泡高 ' + (cLong.state && Math.round(cLong.state.rect.h)) + '（含 padding）')) fails++;
      // ④ 截图路径：红/绿各拍一张，证明证据真的落盘（不是"以为截了"）
      try {
        cClip.shot = path.join(shots, 'red-clipped.png');
        await hoverAndSnap(s, 'in', clipped);
        await shotT(s, cClip.shot);
        cNorm.shot = path.join(shots, 'green-ok.png');
        await hoverAndSnap(s, 'in', normal);
        await shotT(s, cNorm.shot);
      } catch (e) { cClip.shot = null; }
      // ⑤ 几何必须来自 computed（而不是 clone），否则说明解析路径退化
      const modes = [cClip, cNorm, cLong].map((c) => (c.state || {}).measureMode);
      if (!say(modes.every((m) => m === 'computed'), '尺寸解析走 computed 路径：' + JSON.stringify(modes))) fails++;
      // ⑥ 真实 Tab 能落到两个元数据 tip
      await evalT(s, js('const b = document.querySelector("#setpage .stab[data-g=meta]"); if (b) b.click(); return true;'));
      await sleep(200);
      await mouseMove(s, 1, 1);
      const metaTips = await enumerateTips(s, 'meta');
      const targets = metaTips.tips.filter((t) => t.visible).map((t) => ({ text: t.text, nth: 0, kind: t.kind, anchor: t.anchor }));
      const seen = new Map();
      for (const t of targets) { if (seen.has(t.text)) { seen.set(t.text, seen.get(t.text) + 1); t.nth = seen.get(t.text); } else seen.set(t.text, 0); }
      await evalT(s, js('document.querySelector("#setpage .stab[data-g=\\"meta\\"]").focus(); return true;'));
      const swp = await tabSweep(s, ctx, 'meta', targets, shots);
      const need = ['sp_metaon', 'sp_metallm'];
      const hit = need.filter((id) => swp.found.some((c) => c.anchor === id));
      if (!say(hit.length === 2, 'Tab 可达：' + JSON.stringify(hit) + '（按了 ' + swp.presses + ' 次）')) fails++;
      const focusShown = swp.found.filter((c) => !c.failures.some((f) => f.check === 'shown-on-focus'));
      if (!say(focusShown.length >= 2, 'Tab 聚焦点亮气泡：' + focusShown.length + ' 个')) fails++;
      // ⑦ 视觉产物确实落地
      const shotFiles = fs.readdirSync(shots).filter((f) => f.endsWith('.png'));
      if (!say(shotFiles.length > 0, '截图落地：' + (shotFiles.join(', ') || '（无）'))) fails++;
      fs.writeFileSync(path.join(o.out, 'selftest.json'), JSON.stringify({ cases: ctx.cases }, null, 2));
    }
    fails += await selftestGeometry(s, o);
    if (!say(s.errors.length === 0, '页面无渲染异常：' + JSON.stringify(s.errors.slice(0, 3)))) fails++;
    // 必须在 finally 之前跑：finally 会 close() 掉会话，之后再 await 任何 CDP 调用都不会 settle，
    // 事件循环空掉 → Node 静默 exit 0（实测踩到过，什么都没跑却"全绿"）。
    if (!fails && o.selftestMode === 'full') {
      console.log('\n== 编排层自检（runWidth / 截图 / 对抗 / baseline 往返）==');
      fails += await runSelftestFull(s, o);
    }
  } catch (e) {
    console.log('FAIL 自检异常: ' + (e && e.stack ? e.stack : e));
    fails++;
  } finally {
    if (s) { try { await withTimeout(s.close(), 12000, 'session.close'); } catch (e) { console.log('WARN 关闭浏览器: ' + e.message); } }
    const k = killOwnBrowserByPort(OWN_PORT || o.port);
    if (k.term) console.log('WARN 兜底 SIGTERM 了自己启动的浏览器: ' + k.pids.join(','));
  }
  console.log(fails ? ('自检失败 ' + fails + ' 项') : '自检通过（探针能抓红、能判绿、Tab 可达、截图落地' +
    (o.selftestMode === 'full' ? '、编排层与 baseline 往返通' : '') + '）');
  return fails ? 1 : 0;
}

// baseline 双语义：文件不存在＝记录旧版已知失败（exit 0，证据全留）；
// 文件存在＝比对，只有"相对基线新增的失败"才 exit 1（已修好的会列在 fixed 里）。
function applyBaseline(o, report, fails) {
  const fpp = [];
  for (const c of fails) for (const f of c.failures) {
    fpp.push(fpOf({ pane: c.pane, kind: c.kind, anchor: c.anchor, width: c.width, check: f.check }));
  }
  const uniq = Array.from(new Set(fpp)).sort();
  let base = null;
  try { if (fs.existsSync(o.baseline)) base = JSON.parse(fs.readFileSync(o.baseline, 'utf8')); } catch (e) { base = null; }
  if (base && Array.isArray(base.failures)) {
    report.mode = 'baseline-compare';
    const known = new Set(base.failures);
    const regressions = uniq.filter((x) => !known.has(x));
    const fixed = base.failures.filter((x) => !uniq.includes(x));
    report.baseline = {
      file: o.baseline, generatedAt: base.generatedAt || null, known: base.failures.length,
      regressions: regressions, fixed: fixed,
    };
    if (regressions.length) return 1;
    return 0;                       // 只剩已知失败 → 相对基线没退步
  }
  report.mode = 'baseline-record';
  report.baseline = { file: o.baseline, generatedAt: new Date().toISOString(), failures: uniq, count: uniq.length };
  fs.writeFileSync(o.baseline, JSON.stringify(report.baseline, null, 2));
  report.warnings.push('已记录 baseline（' + uniq.length + ' 条已知失败）：记录模式下一律 exit 0，' +
    '全部截图/JSON 照常保留；下次带同一个 --baseline 就会按"新增失败"判红');
  return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. 主流程
// ─────────────────────────────────────────────────────────────────────────────
async function reachable(url, ms) {
  try {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), ms || 6000);
    const r = await fetch(url, { signal: c.signal, redirect: 'manual' });
    clearTimeout(t);
    return { ok: true, status: r.status };
  } catch (e) { return { ok: false, error: e.message }; }
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  if (o.help) {
    const hdr = fs.readFileSync(__filename, 'utf8').split('\n').slice(0, 60).join('\n');
    console.log(hdr);
    return 0;
  }
  fs.mkdirSync(o.out, { recursive: true });
  if (o.selftest) return await runSelftest(o);

  if (!o.url) {
    console.error('缺少 --url（例：--url http://127.0.0.1:19093）');
    return 2;
  }
  let hostPort = 0;
  try { hostPort = parseInt(new URL(o.url).port || (/^https/.test(o.url) ? '443' : '80'), 10); } catch (e) { hostPort = 0; }
  if (LIVE_PORTS.includes(hostPort) && !o.allowLive) {
    console.error('拒绝测试端口 ' + hostPort + '：8899 是用户正在使用的实例、19092 是别人的 rtaweb。' +
      '请用隔离实例（如 http://127.0.0.1:19093）；确需只读检查请显式加 --allow-live。');
    return 2;
  }

  // 看门狗：任何一处真正卡死都要有个上限，别把 CI/主控吊住
  const budgetMs = parseInt(process.env.TIPCHECK_BUDGET_MS || '', 10) || 15 * 60 * 1000;
  const dog = setTimeout(() => {
    const a = killOwnBrowserByPort(o.port);
    const b = OWN_PORT ? killOwnBrowserByPort(OWN_PORT) : { term: 0 };
    console.error('WATCHDOG 超过 ' + Math.round(budgetMs / 1000) + 's 预算，已 SIGTERM 自己启动的浏览器（' +
      (a.term + b.term) + ' 个），退出码 3');
    process.exit(3);
  }, budgetMs);
  dog.unref();

  // 先确认页面活着，再启动浏览器：否则 ub.open 会卡在内部 CDP 调用上（会挂死整个进程）
  const rc = await reachable(o.url, 8000);
  if (!rc.ok) {
    console.error('页面不可达：' + o.url + '（' + rc.error + '）\n未启动浏览器，也没有碰任何进程。');
    return 2;
  }

  const panes = o.panes ? PANES.filter((p) => o.panes.includes(p.g)) : PANES;
  if (!panes.length) { console.error('--panes 没有匹配到任何页签'); return 2; }

  const report = {
    tool: 'tipcheck', schema: 1, startedAt: new Date().toISOString(), finishedAt: null,
    url: o.url, port: o.port, widths: o.widths, height: o.height,
    shots: o.shots, panes: panes.map((p) => p.g), flags: {
      tabSweep: o.tabSweep, expandCollapsed: o.expandCollapsed, adversarial: o.adversarial,
    },
    browser: { edge: ub.findEdge(), candidates: ub.EDGE_CANDIDATES },
    mode: 'run', baseline: null,
    setup: [], warnings: [], coverage: [], tabs: [], cases: [], consoleErrors: [],
    limitations: [
      '只验证"几何上完整可见"（viewport + 所有 overflow 裁剪祖先的 padding box）+ computed opacity/visibility；',
      '不验证 z-order 遮挡：气泡 pointer-events:none，elementFromPoint 命不中伪元素，无法证明它没有被更高层级元素盖住；',
      '滚动条宽度用 clientWidth/clientHeight 推算 padding box，非 overlay 滚动条在 998 宽度下最明显；',
      '若 computed width/height 不可解析会退回一次性克隆测量（measureMode=clone），该用例会额外记一条 measure-mode；',
      '合成用例（synthetic=true, advisory=true）只作对抗参考，永不参与退出码；',
      'Tab 用例验的是 Chromium 的焦点遍历（CDP rawKeyDown VK9），不是 OS 级键盘栈。',
    ],
  };

  let s = null;
  let code = 0;
  try {
    s = await openSession(o, o.url);
    report.portUsed = s.__port || o.port;
    for (const n of (s.__portNotes || [])) report.warnings.push(n);
    const shotsRoot = path.join(o.out, 'shots');
    fs.mkdirSync(shotsRoot, { recursive: true });
    for (const w of o.widths) {
      process.stdout.write('\n== 宽度 ' + w + ' × ' + o.height + ' ==\n');
      const ctx = await runWidth(s, o, w, panes, report, shotsRoot);
      report.cases.push(...ctx.cases); // 普通 hover/focus 同样参与最终硬判据，不只统计对抗用例。
      const fails = ctx.cases.filter((c) => !c.advisory && c.failures.length).length;
      process.stdout.write('   用例 ' + ctx.cases.length + '，失败 ' + fails + '\n');
    }
    report.consoleErrors = (s.errors || []).slice(0, 50);
    if (report.consoleErrors.length) {
      report.warnings.push('渲染层异常/console.error ' + report.consoleErrors.length + ' 条（未判失败，但请人工看）');
    }
  } catch (e) {
    report.setup.push('运行异常: ' + (e && e.message ? e.message : String(e)));
    console.error('运行异常: ' + (e && e.stack ? e.stack : e));
    code = 2;
  } finally {
    if (s) {
      try { await withTimeout(s.close(), 12000, 'session.close'); } catch (e) { report.warnings.push('浏览器收尾: ' + e.message); }
    }
    // 无论成败：把"本次端口上的那个浏览器"确认收掉（SIGTERM），并把结果写进报告
    const portUsed = (s && s.__port) || o.port;
    const k = killOwnBrowserByPort(portUsed);
    report.portCleanup = { port: portUsed, signalled: k.term, pids: k.pids };
  }

  // ── 汇总 ──
  const cases = report.cases;
  const hard = cases.filter((c) => !c.synthetic);
  const fails = hard.filter((c) => c.failures.length);
  const adv = cases.filter((c) => c.synthetic);
  const byCheck = {};
  for (const c of fails) for (const f of c.failures) byCheck[f.check] = (byCheck[f.check] || 0) + 1;
  report.summary = {
    cases: cases.length, hard: hard.length, pass: hard.length - fails.length, fail: fails.length,
    advisorySynthetic: adv.length,
    advisoryIssues: adv.filter((c) => (c.warnings || []).length || (c.failures || []).length).length,
    byCheck: byCheck,
  };
  report.finishedAt = new Date().toISOString();

  // ── baseline：不存在＝记录（exit 0，证据全留）；存在＝只对"新增失败"报错 ──
  if (o.baseline) code = applyBaseline(o, report, fails);
  else if (fails.length) code = 1;
  if (report.setup.length) code = 2;

  const jsonPath = path.join(o.out, 'report.json');
  fs.writeFileSync(jsonPath, JSON.stringify(report, null, 2));
  // 人读摘要（不动 JSON 结构）
  const lines = [];
  lines.push('tipcheck ' + report.startedAt + '  url=' + report.url + '  widths=' + report.widths.join(','));
  lines.push('模式=' + report.mode + '  用例=' + report.summary.cases + '（硬判据 ' + report.summary.hard + '，通过 ' +
    report.summary.pass + '，失败 ' + report.summary.fail + '；合成参考 ' + report.summary.advisorySynthetic + '）');
  if (Object.keys(byCheck).length) lines.push('失败分布=' + JSON.stringify(byCheck));
  for (const w of report.coverage) {
    for (const p of w.panes) {
      const f = cases.filter((c) => c.width === w.width && c.pane === p.g && !c.synthetic && c.failures.length).length;
      lines.push('  w' + w.width + ' ' + p.g.padEnd(6) + ' tips=' + String(p.visible).padStart(3) +
        '（header ' + p.header + '/inline ' + p.inline + (p.hidden ? '，隐藏 ' + p.hidden : '') + '）  失败 ' + f);
    }
  }
  for (const w of report.warnings) lines.push('WARN  ' + w);
  for (const st of report.setup) lines.push('SETUP ' + st);
  lines.push('证据：' + o.out);
  lines.push('局限：见 report.json 的 limitations');
  const txt = lines.join('\n');
  fs.writeFileSync(path.join(o.out, 'summary.txt'), txt + '\n');
  console.log('\n' + txt);

  return code;
}

// 退出策略：先让事件循环自己收尾（stdout 是管道时 process.exit 会**丢最后几行输出**，
// 实测编排层自检的 PASS 行整段消失）；4s 后仍有残留句柄（例如 ub.open 内部挂住的 CDP promise）
// 再强制退出 —— 定时器 unref，正常退出路径永远轮不到它。
function finish(code) {
  process.exitCode = code;
  const t = setTimeout(() => process.exit(code), 4000);
  t.unref();
}
// 默认 2：若因为事件循环空掉而静默退出（pending promise 不再有句柄撑着），Node 会用这个默认码
// 退出，而不是伪装成成功的 0 —— 「静默全绿」是最难查的一类假通过。
process.exitCode = 2;
main().then(finish).catch((e) => {
  console.error('致命错误: ' + (e && e.stack ? e.stack : e));
  finish(2);
});
