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
const { spawn, execFileSync } = require('child_process'), ub = require('./uibrowser');

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
function verifyOwnedServer() {
  const owner = execFileSync('ps', ['-p', String(child.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
  fs.appendFileSync(path.join(root, 'owners.log'), owner + '\n');
  const m = owner.match(/^(\d+)\s+(\d+)\s+(.+)$/);
  if (!m || +m[1] !== process.getuid() || +m[2] !== process.pid || path.basename(m[3]) !== path.basename(binary))
    throw Error('server identity changed; no signal sent');
}

// 在页面里跑：抓出所有可见中文（文本节点 + 会被朗读的属性）
//
// 两类**操作系统/用户提供的专有名词**必须原样显示，不计作漏译（翻译层无权改写身份信息）：
//   ① 真实文件名/路径：含斜杠且有扩展名的词元；
//   ② 真实音频设备名：由 CoreAudio/驱动提供（例如内置扬声器在中文系统上就叫「Mac mini扬声器」），
//      运行期从 /api/devices 取真实名字注入 COLLECT，不写死任何字符串。
// 判据因此是「除这两类专有名词外，可见文本里不得残留中文」，而不是「整页零中文」。
const COLLECT = `((preservedNames) => {
  const CJK = /[\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff]/;
  const names = (preservedNames || []).filter(Boolean).sort((a, b) => b.length - a.length);
  // 逐词剔除「含中文 + 带斜杠 + 有扩展名」的路径词元（例如 docs/GPU卷积与升频效率细查.md）。
  // 不用复杂正则：这段是嵌在 JS 模板字符串里的代码，转义层数多，逐词判断更直观也更好改。
  const stripPaths = s => s.split(/\\s+/).filter(w => {
    const isPath = w.indexOf('/') >= 0 && /\\.[A-Za-z0-9]{2,5}$/.test(w);
    return !(isPath && CJK.test(w));
  }).join(' ');
  // 先把真实设备名整段挖掉（设备名可能带空格，不能按词切）
  const stripNames = s => names.reduce((acc, nm) => acc.split(nm).join(' '), s);
  const residue = s => stripPaths(stripNames(s));
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
    if (t && CJK.test(residue(t))) out.push(t.slice(0, 160));
  }
  for (const el of document.body.querySelectorAll('[title],[placeholder],[aria-label],[alt],[data-tip]')) {
    if (!visible(el)) continue;
    for (const a of ['title', 'placeholder', 'aria-label', 'alt', 'data-tip']) {
      const v = el.getAttribute(a);
      if (v && CJK.test(residue(v))) out.push(a + '=' + v.slice(0, 160));
    }
  }
  return out;
})`;

async function runLang(lang) {
  // 每次换配置都**重启服务**：rtaweb 启动时把设置读进内存，/api/settings 返回的是内存副本。
  // 只改磁盘不重启，页面会被内存里的旧主题覆盖 —— 那是测试假象，不是产品行为（本轮踩过）。
  fs.writeFileSync(conf, `backend=null\nmetaon=0\nmetallm=0\nlang=${lang}\ntheme=light\nuistyle=apple\n`);
  if (child) {
    verifyOwnedServer();
    child.kill('SIGTERM');
    await Promise.race([new Promise(r => child.once('exit', r)), pause(10000)]);
    if (child.exitCode === null) throw Error('owned server did not exit after TERM');
    child = null;
  }
  await new Promise((resolve, reject) => {
    let s = net.createServer(); s.once('error', reject);
    s.listen(port, '127.0.0.1', () => s.close(resolve));
  });
  child = spawn(binary, ['--port', String(port), '--music-dir', path.join(root, 'music')], { env, cwd: root, stdio: 'ignore' });
  for (let i = 0; i < 150; i++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/api/ping`)).ok) break; } catch { }
    await pause(100);
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
    // 真实设备名是 OS/驱动提供的专有名词（中文系统上内置扬声器就叫「Mac mini扬声器」），
    // 必须原样显示；从生产 API 取真实名字，绝不写死，也绝不用它去豁免可翻译文案。
    const devs = await (await fetch(`http://127.0.0.1:${port}/api/devices`)).json();
    const osNames = (devs.devices || []).map((d) => d && d.name).filter((n) => typeof n === 'string' && n);
    ck(osNames.length > 0, 'production /api/devices reported real device names (OS proper nouns)', osNames);
    const collect = (extra) => session.eval(`${COLLECT}(${JSON.stringify(osNames.concat(extra || []))})`);
    const langAttr = await session.eval("document.documentElement.dataset.lang + '|' + document.documentElement.lang");
    ck(langAttr === 'en|en', 'html data-lang/lang = en|en', langAttr);

    const views = ['albums', 'artists', 'tracks', 'files', 'remote', 'queue', 'recent', 'favs', 'station'];
    const leftovers = [];
    const thin = [];
    for (const v of views) {
      await session.eval(`(function(){var n=document.querySelector('.nav[data-v=${v}]'); if(n) n.click();})()`);
      await pause(350);
      const got = await collect();
      for (const s of got) leftovers.push(`${v}: ${s}`);
      // 反空跑检查：视图必须真的渲染出文字，否则"零中文"只是因为页面是空的
      const len = await session.eval("(document.body.innerText||'').replace(/\\s+/g,' ').trim().length");
      if (len < 40) thin.push(`${v}:${len}`);
    }
    ck(thin.length === 0, 'every traversed view actually rendered text (not an empty page)', thin);
    // 设置页 9 个页签
    for (const g of ['adv', 'in', 'out', 'pcm', 'sdm', 'eq', 'cal', 'meta', 'stream', 'diag']) {
      await session.eval(`openSettingsTab('${g}')`);
      await pause(450);
      const got = await collect();
      for (const s of got) leftovers.push(`settings/${g}: ${s}`);
    }
    // 帮助浮层
    await session.eval("openSettingsTab('eq');document.getElementById('bHelp').click()");
    await pause(350);
    for (const s of await collect()) leftovers.push(`help: ${s}`);
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
    const zhCount = (await collect()).length;
    ck(zhCount > 20, 'chinese mode still has plenty of Chinese text (sanity: page is not empty)', zhCount);

    // ---------- 切换开关存在 ----------
    await session.eval("openSettingsTab('out')");
    await pause(300);
    const hasSelect = await session.eval("(()=>{var s=document.getElementById('sp_lang');return s? s.tagName+':'+s.value : 'missing'})()");
    ck(/^SELECT:(zh|en)$/.test(hasSelect), 'settings exposes a language selector #sp_lang', hasSelect);

    // ---------- 回归：配置里的语言不许被 localStorage 的旧缓存盖掉 ----------
    // 用户报的 BUG：升级客户端后界面语言变了。根因是旧实现让 localStorage 无条件覆盖
    // 服务端渲染的 data-lang（WebKit 缓存可能残留上一版的值）。判据 = 造出"配置 en / 缓存 zh"
    // 这种冲突，页面必须是英文；反过来也必须成立。
    await runLang('en');
    await session.eval("localStorage.setItem('rta-lang','zh')");
    await session.eval("location.reload()");
    await session.waitFor("document.readyState!=='loading' && document.documentElement.dataset.lang==='en' && typeof openSettingsTab==='function'", 15000);
    await pause(600);
    const confWins1 = await session.eval("document.documentElement.dataset.lang");
    ck(confWins1 === 'en', 'config lang wins over a stale localStorage cache (en vs cached zh)', confWins1);
    const navConf1 = await session.eval("document.querySelector('.nav[data-v=settings]').textContent.trim()");
    ck(navConf1 === 'Settings', 'stale cache does not flip the UI back to Chinese', navConf1);

    await runLang('zh');
    await session.eval("localStorage.setItem('rta-lang','en')");
    await session.eval("location.reload()");
    await session.waitFor("document.readyState!=='loading' && document.documentElement.dataset.lang==='zh' && typeof openSettingsTab==='function'", 15000);
    await pause(600);
    const confWins2 = await session.eval("document.documentElement.dataset.lang");
    ck(confWins2 === 'zh', 'config lang wins the other way too (zh vs cached en)', confWins2);

    // ---------- 回归：主题 / 界面风格 / 流媒体视图也必须以配置为准 ----------
    // 用户要求「所有设置都存本地配置，不跟版本走」。判据 = 造出"配置 light / 缓存 dark"的冲突，
    // 首绘必须是 light；uistyle 同理。这四项（lang/theme/uistyle/remoteview）都是持久偏好。
    await runLang('en');
    await session.eval("localStorage.setItem('rta-theme','dark');localStorage.setItem('rta-uistyle','classic')");
    await session.eval("location.reload()");
    // 必须等**重载后的新文档**真的生效：只等 dataset 存在会被旧文档立刻满足（本轮实测踩到）。
    // 判据直接等目标值本身，超时就是失败，不允许"读早了"混过去。
    await session.waitFor("document.readyState!=='loading' && document.documentElement.dataset.theme==='light' && typeof openSettingsTab==='function'", 15000);
    await pause(300);
    const themeNow = await session.eval("document.documentElement.dataset.theme + '|' + document.documentElement.dataset.themeSrc");
    ck(themeNow === 'light|conf', 'config theme wins over a stale localStorage theme', themeNow);
    const styleNow = await session.eval("document.documentElement.dataset.uistyle + '|' + document.documentElement.dataset.uistyleSrc");
    ck(styleNow === 'apple|conf', 'config UI style wins over a stale localStorage style', styleNow);

    // ---------- 真正的切换链路：改下拉 → POST 保存 → 页面重载 → 变英文 ----------
    // 用户口径：选中就切换；切换会重载，但必须**留在当前页签**，不许跳回「专辑」。
    await runLang('zh');
    await session.eval("openSettingsTab('out')");
    await pause(400);
    const beforeSwitch = await session.eval("document.documentElement.dataset.lang + '|' + document.getElementById('sp_lang').value");
    ck(beforeSwitch === 'zh|zh', 'language switch starts from a genuinely Chinese document and selector', beforeSwitch);
    await session.eval("window.__switchDocument = true;var s=document.getElementById('sp_lang');s.value='en';s.dispatchEvent(new Event('change'));");
    let switched = false;
    for (let i = 0; i < 60; i++) {
      await pause(200);
      try {
        if (await session.eval("document.documentElement.dataset.lang==='en' && !window.__switchDocument && typeof openSettingsTab==='function'")) { switched = true; break; }
      } catch { }
    }
    ck(switched, 'language selector switch reloads the page into English');
    const confText = fs.existsSync(conf) ? fs.readFileSync(conf, 'utf8') : '';
    ck(/^lang=en$/m.test(confText), 'switch persisted lang=en to rlplayer-settings.conf', confText.trim().split('\n').filter(l => l.startsWith('lang=')));
    const ls = await session.eval("localStorage.getItem('rta-lang')");
    ck(ls === 'en', 'switch remembered rta-lang in localStorage', ls);
    const zhBack = await session.eval("document.querySelector('.nav[data-v=settings]').textContent.trim()");
    ck(zhBack === 'Settings', 'after switch the nav is English without a manual reload', zhBack);
    await pause(1800);   // 等首屏异步渲染跑完，确认"回到原页签"不是只在加载瞬间成立
    const tabAfter = await session.eval("(document.querySelector('#setpage .stab.on')||{}).dataset ? document.querySelector('#setpage .stab.on').dataset.g : 'none'");
    ck(tabAfter === 'out', 'switch keeps the same settings tab instead of jumping home', tabAfter);
    const viewAfter = await session.eval("(function(){var n=document.querySelector('#setpage');return n && n.style.display!=='none' && n.offsetParent!==null;})()");
    ck(viewAfter === true, 'switch keeps the settings page open (did not fall back to Albums)', viewAfter);

    if (!keep) { try { await session.shot(path.join(root, 'i18n-en.png')); } catch { } }
  } finally {
    if (session) await session.close();
    if (child && child.exitCode === null) {
      verifyOwnedServer();
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
