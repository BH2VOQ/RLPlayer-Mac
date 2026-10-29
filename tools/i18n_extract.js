const fs = require('fs');
const CJK = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/;
function ctx(full, phrase, pos) {
  const i = (typeof pos === 'number' && pos >= 0) ? pos : full.indexOf(phrase);
  if (i < 0) return '';
  const a = Math.max(0, i - 40), b = Math.min(full.length, i + phrase.length + 40);
  return full.slice(a, b).replace(/\s+/g, ' ').trim();
}
// 属性可能用双引号也可能用单引号（ui_page.h 大量用 '…'）——两种都要抓，否则
// title='浅色' 这类静态提示词会整批漏掉（实测漏了 100+ 条，英文模式留下中文 tooltip）。
const ATTRS = /\b(title|placeholder|aria-label|alt)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;

function harvest(s, origin, out, full, pos) {
  if (!s || !CJK.test(s)) return;
  // attribute values first (they are the exact strings the engine will see)
  let m;
  ATTRS.lastIndex = 0;
  while ((m = ATTRS.exec(s))) {
    const v = (m[2] !== undefined ? m[2] : m[3]).trim();
    if (v && CJK.test(v)) out.push([v, origin + ':attr', ctx(full, v, pos)]);
  }
  // then text: strip tags, strip attr="value", split on markup punctuation
  let t = s.replace(/<(?:"[^"]*"|'[^']*'|[^>])*>/g, '\n');
  t = t.replace(/\b[\w-]+\s*=\s*(?:"[^"]*"|'[^']*')/g, ' ');
  t = t.replace(/[<>{};]/g, '\n');
  for (const line of t.split('\n')) {
    const x = line.trim();
    if (x && CJK.test(x)) out.push([x, origin + ':text', ctx(full, x, pos)]);
  }
}

function jsStrings(src) {
  const out = []; let i = 0, n = src.length;
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (c === '/' && d === '/') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '/' && d === '*') { i += 2; while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++; i += 2; continue; }
    if (c === '"' || c === "'") {
      const q = c; let j = i + 1, s = '';
      while (j < n) {
        if (src[j] === '\\') { s += src[j]; j++; if (j < n) { s += src[j]; j++; } continue; }
        if (src[j] === q || src[j] === '\n') break;
        s += src[j]; j++;
      }
      if (CJK.test(s)) out.push({ s, pos: i });
      i = j + 1; continue;
    }
    if (c === '`') {
      let j = i + 1, s = '';
      while (j < n) {
        if (src[j] === '\\') { s += src[j]; j++; if (j < n) { s += src[j]; j++; } continue; }
        if (src[j] === '`') break;
        s += src[j]; j++;
      }
      if (CJK.test(s)) out.push({ s, pos: i });
      i = j + 1; continue;
    }
    i++;
  }
  return out;
}

const htmlPath = process.argv[2] || '/tmp/rlp_page.html';
const appPath = process.argv[3] || '/tmp/rlp_app.js';
const html = fs.readFileSync(htmlPath, 'utf8');
const app = fs.readFileSync(appPath, 'utf8');
const raw = [];
const htmlText = html.replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ');
harvest(htmlText, 'page', raw, htmlText);
for (const it of jsStrings(app)) harvest(it.s, 'app', raw, app, it.pos);

const counts = new Map();
for (const [zh, origin, context] of raw) {
  const k = zh.replace(/\s+/g, ' ').trim();
  if (!k || !CJK.test(k)) continue;
  if (k.length > 400) continue;                 // 极长段落单独人工处理
  const e = counts.get(k) || { n: 0, origin, context };
  e.n++; counts.set(k, e);
}
const rows = [...counts.entries()].map(([zh, v]) => ({ zh, n: v.n, origin: v.origin, context: v.context }))
  .sort((a, b) => b.n - a.n || b.zh.length - a.zh.length);
const outPath = process.argv[4] || '/tmp/rlp_i18n_corpus.tsv';
fs.writeFileSync(outPath, rows.map(r => `${r.zh}\t${r.n}\t${r.origin}\t${r.context}`).join('\n') + '\n');
console.log('phrases:', rows.length, 'chars:', rows.reduce((a, r) => a + r.zh.length, 0));
const bad = rows.filter(r => /[=<>]/.test(r.zh));
console.log('suspicious markup leftovers:', bad.length);
bad.slice(0, 8).forEach(r => console.log('  !', r.zh.slice(0, 90)));
