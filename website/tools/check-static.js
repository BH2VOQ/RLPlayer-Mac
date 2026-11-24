#!/usr/bin/env node
'use strict';

/*
 * Static checks for the RLPlayer site: no browser, no network.
 * - JS syntax via child_process (node --check)
 * - duplicate ids, internal anchors, local asset paths
 * - required release facts and measurements
 * - forbidden references to docs/images and docs/screens
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const failures = [];
const warnings = [];

function read(file) {
  return fs.readFileSync(path.join(root, file), 'utf8');
}

function fail(message) {
  failures.push(message);
}

function warn(message) {
  warnings.push(message);
}

const html = read('index.html');
const htmlText = html
  .replace(/<script[\s\S]*?<\/script>/gi, ' ')
  .replace(/<style[\s\S]*?<\/style>/gi, ' ')
  .replace(/<[^>]+>/g, ' ')
  .replace(/\s+/g, ' ');
const css = read('styles.css');
const app = read('app.js');
const motion = read('motion.js');
const art = read('art-direction.css');
const release = JSON.parse(read('latest.json'));

/* 1. JS syntax ------------------------------------------------------------ */
try {
  execFileSync(process.execPath, ['--check', path.join(root, 'app.js')], { stdio: 'pipe' });
  console.log('PASS  app.js syntax');
  execFileSync(process.execPath, ['--check', path.join(root, 'motion.js')], { stdio: 'pipe' });
  console.log('PASS  motion.js syntax');
} catch (err) {
  fail('app.js syntax error: ' + String(err.stderr || err.message).trim());
}

/* 2. CSS balance ---------------------------------------------------------- */
function checkBalance(text, open, close, label) {
  let depth = 0;
  for (const char of text) {
    if (char === open) depth += 1;
    if (char === close) depth -= 1;
    if (depth < 0) break;
  }
  if (depth !== 0) fail(label + ' braces unbalanced (depth ' + depth + ')');
  else console.log('PASS  ' + label + ' braces balanced');
}
checkBalance(css, '{', '}', 'styles.css');
checkBalance(art, '{', '}', 'art-direction.css');

/* strip comments from JS for a rough brace check */
checkBalance(app.replace(/\/\*[\s\S]*?\*\//g, ''), '{', '}', 'app.js');

/* 3. ids and duplicate detection ----------------------------------------- */
const idMatches = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
const ids = new Set();
const duplicates = new Set();
for (const id of idMatches) {
  if (ids.has(id)) duplicates.add(id);
  ids.add(id);
}
if (duplicates.size) fail('duplicate ids: ' + [...duplicates].join(', '));
else console.log('PASS  ' + ids.size + ' unique ids');

/* 4. anchors -------------------------------------------------------------- */
const hrefs = [...html.matchAll(/\shref="([^"]+)"/g)].map((m) => m[1]);
const missingAnchors = new Set();
for (const href of hrefs) {
  if (href.startsWith('#')) {
    const id = href.slice(1);
    if (!id || !ids.has(id)) missingAnchors.add(href);
  }
}
if (missingAnchors.size) fail('missing anchor targets: ' + [...missingAnchors].join(', '));
else console.log('PASS  internal anchors resolve');

/* 5. local resources ------------------------------------------------------ */
const assets = new Set();
for (const match of html.matchAll(/\s(?:src|href)="((?!https?:|#|mailto:)[^"]+)"/g)) {
  assets.add(match[1]);
}
const optionalShots = new Set(['assets/ui-hero.webp', 'assets/ui-dsp.webp', 'assets/ui-library.webp', 'assets/ui-album-detail.webp']);
let assetCount = 0;
for (const asset of assets) {
  if (asset.startsWith('data:') || asset.startsWith('//')) continue;
  assetCount += 1;
  const target = path.join(root, asset);
  if (fs.existsSync(target)) continue;
  if (optionalShots.has(asset)) warn('screenshot not generated yet: ' + asset);
  else fail('missing local asset: ' + asset);
}
console.log('PASS  ' + assetCount + ' local references inspected');

/* 6. external links ------------------------------------------------------- */
const external = [...new Set(hrefs.filter((h) => h.startsWith('http')))];
const allowedHosts = new Set(['github.com', 'www.gnu.org']);
for (const url of external) {
  let host;
  try { host = new URL(url).host; } catch (err) { fail('invalid URL: ' + url); continue; }
  if (!allowedHosts.has(host)) fail('unexpected external host: ' + host + ' (' + url + ')');
  if (host === 'github.com' && !url.startsWith('https://github.com/BH2VOQ/RLPlayer-Mac') && !url.startsWith('https://github.com/okhuoyanyan/RLPlayer2')) {
    fail('unexpected GitHub repo link: ' + url);
  }
}
console.log('PASS  ' + external.length + ' external links');

/* 7. release facts match latest.json ------------------------------------- */
if (!html.includes(release.version)) fail('index.html missing version ' + release.version);
if (!html.includes(release.sha256)) fail('index.html missing sha256 from latest.json');
if (!html.includes(release.download_url)) fail('index.html missing download_url from latest.json');
if (!html.includes(String(release.size).replace(/\B(?=(\d{3})+(?!\d))/g, ','))) {
  fail('index.html missing byte size from latest.json');
}
if (read('latest.json') !== fs.readFileSync(path.join(root, '..', 'latest.json'), 'utf8')) {
  warn('website/latest.json differs from repository latest.json');
}
console.log('PASS  release metadata embedded');

/* 8. required content ----------------------------------------------------- */
const required = [
  'v1.1.4',
  '−189.1',
  '52',
  '四族',
  '113.5',
  'LNS15',
  '6.1e−14',
  '20 段',
  '1,058,400',
  '6,230',
  '19 项',
  'DirectSDM',
  'CoreAudio',
  'DoP',
  'UPnP',
  'AirPlay',
  'Process Tap',
  '屏幕录制权限',
  '10 分钟 0 缓冲溢出',
  'OPRA',
  '古典',
  '五源',
  'AI',
  '零常驻端口',
  'Apple Silicon',
  'arm64',
  'UAC2',
  '无需关闭 SIP',
  'DSD512',
  'DSD1024',
  'PCM 1411.2',
  '7.1.4',
  'DSP 2.0',
  'dBTP',
  'SSE',
  '五重',
  'Gapless',
  'SHA-256',
  'xattr -cr /Applications/RLPlayer.app',
  'GPL-3.0-or-later',
  'Star on GitHub',
  'Future Vision',
  'Releases',
  'Issues',
  'RainLain',
  '猫与小行星',
  '聆听风暴',
  'Gosed',
  'Miyu',
  '正在下载99%',
  '895816505'
];
for (const term of required) {
  if (!html.includes(term) && !htmlText.includes(term)) fail('missing required copy: ' + term);
}
console.log('PASS  ' + required.length + ' required copy tokens');

/* 9. forbidden references ------------------------------------------------- */
if (/docs\/images|docs\/screens|ui-[a-z-]+\.png/.test(html)) {
  fail('forbidden screenshot reference (docs/images or docs/screens) in index.html');
} else {
  console.log('PASS  no forbidden screenshot references');
}

/* 10. reduced motion / a11y hooks ---------------------------------------- */
const mustHave = [
  ['prefers-reduced-motion', css],
  ['aria-expanded', html],
  ['skip-link', html],
  ['IntersectionObserver', app],
  ['requestAnimationFrame', app],
  ['animation-timeline', css],
  ['getPointAtLength', motion],
  ['native-bits', html],
  ['heroWave', html],
  ['prefers-reduced-motion', art],
  ['data-copy-target', html],
  ['<main id="main">', html]
];
for (const [token, source] of mustHave) {
  if (!source.includes(token)) fail('missing expected token: ' + token);
}
console.log('PASS  motion / accessibility hooks');

/* 11. screenshots are img-based ------------------------------------------ */
const shots = [...html.matchAll(/<img[^>]*\sdata-shot[^>]*>/g)].length;
if (shots < 3) fail('expected at least 3 semantic screenshot <img> elements, found ' + shots);
else console.log('PASS  ' + shots + ' semantic screenshot elements');

/* report ------------------------------------------------------------------ */
if (warnings.length) {
  console.log('');
  for (const message of warnings) console.log('WARN  ' + message);
}
if (failures.length) {
  console.log('');
  for (const message of failures) console.log('FAIL  ' + message);
  console.log('');
  console.log(failures.length + ' check(s) failed');
  process.exit(1);
}
console.log('');
console.log('All static checks passed' + (warnings.length ? ' (' + warnings.length + ' warning(s))' : ''));

/* 12. no weird disclaimers ------------------------------------------------ */
if (/Apple Inc\.|无分析脚本|不收集任何数据/.test(html)) {
  fail('weird disclaimer text remained in index.html');
} else {
  console.log('PASS  no weird disclaimers');
}
