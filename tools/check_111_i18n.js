// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_111_i18n.js —— 1.1.1-beta2 中英切换的**真实浏览器**验收
//
// 判据（铁律 3：这个指标真的能证明"英文界面没有残留中文"吗？）
//   * 判据不是"表里有条目"，而是**打开真页面、逐个视图走一遍、把 DOM 里肉眼能看见的
//     中文抓出来计数**。空曲库 + 空队列让 body 上几乎只剩界面文案，所以这一条能覆盖
//     nav / 顶栏 / 播放条 / 空状态 / 设置 9 个页签 / 帮助 / 诊断页（含后端返回的中文说明）。
//   * 中文模式必须仍然有中文（否则"英文没中文"可能只是因为整个页面空了）。
//   * 每条残留中文逐条打印，方便补表，不允许"总数对了但没说是哪句"。
//
// 用法：
//   node tools/check_111_i18n.js --binary build-mac/rtaweb [--keep]
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), net = require('net');
const { spawn } = require('child_process'), ub = require('./uibrowser');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-111-i18n-'));
const port = 19106, browserPort = 9712;
const binary = path.resolve(process.argv[process.argv.indexOf('--binary') + 1] || 'build-mac/rtaweb');
const keep = process.argv.includes('--keep');

const env = {
  ...process.env,
  HOME: path.join(root, 'home'),
  RLPLAYER_STATE_DIR: path.join(root, 'state'),
  RLPLAYER_LIBRARY_DIR: path.join(root, 'lib'),
  RLPLAYER_COVER_DIR: path.join(root, 'covers'),
};
for (const k of ['HOME', 'RLPLAYER_STATE_DIR', 'RLPLAYER_LIBRARY_DIR', 'RLPLAYER_COVER_DIR']) fs.mkdirSync(env[k], { recursive: true });
fs.mkdirSync(path.join(root, 'music'));
const conf = path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-settings.conf');

let child, session;
const results = [];
function ck(v, name, data) {
  results.push({ pass: !!v, name, data });
  console.log((v ? 'PASS ' : 'FAIL ') + name + (data === undefined ? '' : ' ' + JSON.stringify(data)));
}
const pause = ms => new Promise(r => setTimeout(r, ms));

// 在页面里跑：抓出所有可见中文（文本节点 + 会被朗读的属性）
const COLLECT = `(() => {
  const CJK = /[\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff]/;
  const out = [];
  // 只算**用户当下能看见**的文字：隐藏的 DOM（display:none / visibility / 0 尺寸）不计。
  // 为什么必须过滤：设置页整块在启动时就渲染好但隐藏，不过滤会把没打开过的页签也算进来，
  // 于是"当前视图还剩多少中文"这个数就失去意义（分不清是漏译还是没显示）。
  const visCache = new Map();
  function visible(el) {
    if (!el || el.nodeType !== 1) return true;
    if (visCache.has(el)) return visCache.get(el);
    let v = true;
    if (el.closest('[hidden],[aria-hidden=true]')) v = false;
    else {
      const st = getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) === 0) v = false;
      else if (el.offsetParent === null && el.getClientRects().length === 0) v = false;
    }
    visCache.set(el, v);
    return v;
  }
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  let n;
  while ((n = walk.nextNode())) {
    const p = n.parentElement;
    if (!p) continue;
    const tag = (p.tagName || '').toLowerCase();
    if (tag === 'script' || tag === 'style' || tag === 'textarea') continue;
    if (!visible(p)) continue;
    const t = (n.nodeValue || '').trim();
    if (t && CJK.test(t)) out.push(t.slice(0, 160));
  }
  for (const el of document.body.querySelectorAll('[title],[placeholder],[aria-label],[alt]')) {
    if (!visible(el)) continue;
    for (const a of ['title', 'placeholder', 'aria-label', 'alt']) {
      const v = el.getAttribute(a);
      if (v && CJK.test(v)) out.push(a + '=' + v.slice(0, 160));
    }
  }
  return out;
})()`;

async function runLang(lang) {
  fs.writeFileSync(conf, `backend=null\nmetaon=0\nmetallm=0\nlang=${lang}\n`);
  if (!child) {
    await new Promise((resolve, reject) => {
      let s = net.createServer(); s.once('error', reject);
      s.listen(port, '127.0.0.1', () => s.close(resolve));
    });
    child = spawn(binary, ['--port', String(port), '--music-dir', path.join(root, 'music')], { env, cwd: root, stdio: 'ignore' });
    for (let i = 0; i < 150; i++) {
      try { if ((await fetch(`http://127.0.0.1:${port}/api/ping`)).ok) break; } catch { }
      await pause(100);
    }
  }
  if (session) { await session.close(); session = null; }
  session = await ub.open({ url: `http://127.0.0.1:${port}/`, port: browserPort });
  await session.waitFor("typeof openSettingsTab==='function' && document.getElementById('bHelp')");
  await pause(400);   // 让首屏异步渲染与 i18n 观察器跑完
  return session;
}

(async () => {
  try {
    // ---------- 英文模式 ----------
    await runLang('en');
    const langAttr = await session.eval("document.documentElement.dataset.lang + '|' + document.documentElement.lang");
    ck(langAttr === 'en|en', 'html data-lang/lang = en|en', langAttr);

    const views = ['albums', 'artists', 'tracks', 'files', 'remote', 'queue', 'recent', 'favs', 'station'];
    const leftovers = [];
    const thin = [];
    for (const v of views) {
      await session.eval(`(function(){var n=document.querySelector('.nav[data-v=${v}]'); if(n) n.click();})()`);
      await pause(350);
      const got = await session.eval(COLLECT);
      for (const s of got) leftovers.push(`${v}: ${s}`);
      // 反空跑检查：视图必须真的渲染出文字，否则"零中文"只是因为页面是空的
      const len = await session.eval("(document.body.innerText||'').replace(/\\s+/g,' ').trim().length");
      if (len < 40) thin.push(`${v}:${len}`);
    }
    ck(thin.length === 0, 'every traversed view actually rendered text (not an empty page)', thin);
    // 设置页 9 个页签
    for (const g of ['out', 'pcm', 'sdm', 'adv', 'eq', 'cal', 'meta', 'stream', 'diag']) {
      await session.eval(`openSettingsTab('${g}')`);
      await pause(450);
      const got = await session.eval(COLLECT);
      for (const s of got) leftovers.push(`settings/${g}: ${s}`);
    }
    // 帮助浮层
    await session.eval("openSettingsTab('eq');document.getElementById('bHelp').click()");
    await pause(350);
    for (const s of await session.eval(COLLECT)) leftovers.push(`help: ${s}`);
    await session.eval("var c=document.getElementById('mclose'); if(c) c.click()");
    await pause(200);

    const navEn = await session.eval("document.querySelector('.nav[data-v=albums]').textContent.trim()+'|'+document.querySelector('.nav[data-v=settings]').textContent.trim()");
    ck(navEn === 'Albums|Settings', 'nav labels are really English', navEn);
    const uniq = [...new Set(leftovers)];
    ck(uniq.length === 0, 'english mode: no Chinese left in any traversed view', uniq.slice(0, 40));

    // ---------- 中文模式（证明翻译层没有把中文也改掉） ----------
    await runLang('zh');
    const zhAttr = await session.eval("document.documentElement.dataset.lang + '|' + document.documentElement.lang");
    ck(zhAttr === 'zh|zh', 'html data-lang/lang = zh|zh', zhAttr);
    const zhNav = await session.eval("document.querySelector('.nav[data-v=settings]').textContent.trim()");
    ck(zhNav.includes('设置'), 'chinese mode still shows Chinese nav label', zhNav);
    const zhCount = (await session.eval(COLLECT)).length;
    ck(zhCount > 20, 'chinese mode still has plenty of Chinese text (sanity: page is not empty)', zhCount);

    // ---------- 切换开关存在 ----------
    await session.eval("openSettingsTab('out')");
    await pause(300);
    const hasSelect = await session.eval("(()=>{var s=document.getElementById('sp_lang');return s? s.tagName+':'+s.value : 'missing'})()");
    ck(/^SELECT:(zh|en)$/.test(hasSelect), 'settings exposes a language selector #sp_lang', hasSelect);

    // ---------- 真正的切换链路：改下拉 → POST 保存 → 页面重载 → 变英文 ----------
    await session.eval("(()=>{var s=document.getElementById('sp_lang');s.value='en';s.dispatchEvent(new Event('change'));})()");
    let switched = false;
    for (let i = 0; i < 60; i++) {
      await pause(200);
      try {
        if (await session.eval("document.documentElement.dataset.lang==='en'")) { switched = true; break; }
      } catch { }
    }
    ck(switched, 'language selector switch reloads the page into English');
    const confText = fs.existsSync(conf) ? fs.readFileSync(conf, 'utf8') : '';
    ck(/^lang=en$/m.test(confText), 'switch persisted lang=en to rlplayer-settings.conf', confText.trim().split('\n').filter(l => l.startsWith('lang=')));
    const ls = await session.eval("localStorage.getItem('rta-lang')");
    ck(ls === 'en', 'switch remembered rta-lang in localStorage', ls);
    const zhBack = await session.eval("document.querySelector('.nav[data-v=settings]').textContent.trim()");
    ck(zhBack === 'Settings', 'after switch the nav is English without a manual reload', zhBack);

    if (!keep) { try { await session.shot(path.join(root, 'i18n-en.png')); } catch { } }
  } finally {
    if (session) await session.close();
    if (child && child.exitCode === null) {
      child.kill('SIGTERM');
      await Promise.race([new Promise(r => child.once('exit', r)), pause(10000)]);
      if (child.exitCode === null) throw Error('owned server did not exit after TERM');
    }
    fs.writeFileSync(path.join(root, 'results.json'), JSON.stringify(results, null, 2));
    console.log('EVIDENCE ' + root);
    if (!keep) { /* 保留证据目录，与其它 111 脚本一致 */ }
  }
  if (results.some(r => !r.pass)) process.exitCode = 1;
})().catch(e => { console.error(e); process.exitCode = 1; });
