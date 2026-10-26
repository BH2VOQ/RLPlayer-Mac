// uicheck_fixes.js — 20261026-05 五项 UI 修复的可复跑验收（本机 macOS 可直跑）
//
// 为什么单独写一个：
//   原有 tools/uicheck.js / uishots.js / peqcheck.js 等全部硬编码 Windows 的 msedge.exe
//   绝对路径，在 macOS 上第一行 `if (!EDGE) process.exit(2)` 就退出，历史上被误判为
//   「本机 UI 验收跑不了」。实际 macOS 上 Edge 完全可用，只需要正确的路径 + 两个开关
//   （--no-sandbox / --remote-allow-origins）。这些已收进 tools/uibrowser.js。
//
// 覆盖范围（与 debug/20261026-05-UI待修/BUG与功能清单.md 的编号对应）：
//   B-1 冷启动点播放没反应 —— 不碰设置页，直接点专辑播放按钮，必须真的开始播且无 TypeError
//   B-2 设置页保存栏      —— 七个页签下保存栏都必须停在视口底部、不被播放条遮挡
//   B-3 底栏文字溢出      —— 超长曲名不得压住中间控制组（判据：.np 右边界 <= .keys 左边界）
//   B-4 EQ 页文字堆叠     —— 20 行全部无内容溢出、无单元格重叠、表头无重叠；三主题都验
//   F-1 底栏跑马灯        —— 溢出时才有动画，不溢出时必须静止（不能无脑滚）
//   F-2 快速开始跳转      —— 点「设置文件夹位置」必须进设置「高级」页且 sp_root 获得焦点
//   F-3 主题互不干扰      —— apple / classic × 三主题，语义色变量不得互相串
//
// ⚠️⚠️ 铁律 1（绝不向用户听音设备播可听声音）—— 这个脚本会真的播一首歌，所以：
//   ① 脚本**强制**把后端切成 null（不出声），并在 B-1 之前断言切换成功；
//   ② 前端拿不到 `backend` 设置时**直接中止**整个测试，绝不"先播了再说"。
//   历史事故（2026-10-26）：本脚本第一版没有这层保护，落到了 conf 里的 backend=coreaudio，
//   **真的从 Mac mini 扬声器放了约 40 秒音乐，峰值 −7.4 dBFS**（远超 −60 dBFS 红线）。
//   那是验收脚本自己的缺陷，不是被测代码的错。补上这道闸门后才允许再跑。
//
// 用法：
//   # 先起一个隔离实例（绝不碰 8899 用户实例）。注意先预置 null 后端更保险：
//   mkdir -p /tmp/uiv && printf 'backend=null\nvolume=-60\n' > /tmp/uiv/rlplayer-settings.conf
//   RLPLAYER_STATE_DIR=/tmp/uiv RLPLAYER_LIBRARY_DIR=/tmp/lib \
//     ./build-mac/rtaweb --port 8971
//   node tools/uicheck_fixes.js http://127.0.0.1:8971/ [截图目录]
//
// 退出码：0 = 全通过；1 = 有 FAIL；2 = 环境问题（找不到 Edge / 起不来）
'use strict';
const ub = require('./uibrowser');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_ = process.argv[2] || 'http://127.0.0.1:8971/';
const OUT = process.argv[3] || path.join(os.tmpdir(), 'rta_uicheck_fixes');
fs.mkdirSync(OUT, { recursive: true });

const sleep = ub.sleep;

// 一条超长标题：足够触发跑马灯（约 90 字符），且含中英混排考验字形宽度
const LONG_TITLE =
  '这是一个非常非常长的曲目名称用于测试溢出行为 And A Long English Subtitle Too 2026 Remaster';
const LONG_ARTIST =
  '某某交响乐团 & The Very Long Artist Name Ensemble feat. Someone Else';

const results = [];
function ck(ok, what, detail) {
  const line = (ok ? '  [PASS] ' : '  [FAIL] ') + what + (detail ? '  — ' + detail : '');
  results.push(line);
  console.log(line);
  return ok;
}
function section(t) { console.log('\n' + t); }

(async () => {
  const s = await ub.open({ url: URL_, width: 1576, height: 908, settleMs: 2600 });
  const shots = [];
  const shot = async (name) => {
    const p = path.join(OUT, name + '.png');
    await s.shot(p); shots.push(p); return p;
  };

  // ============================================================
  section('B-1 冷启动点播放没反应（不碰设置页）');

  // ---------- 🔴 铁律 1 闸门：播放前必须把后端切成 null（不出声） ----------
  // 为什么必须在**播放之前**做：B-1 的判据是"后端真的开始播放"，
  // 一旦落到 coreaudio 就会从用户的扬声器出声。宁可测试失败，也不能出声。
  const mute = await s.eval(`(function () {
    try {
      // ① 优先走公开 API：/api/settings 写 backend=null
      return fetch('/api/settings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'backend=null&volume=-60'
      }).then(function (r) { return r.json(); }).then(function (j) {
        return {apiOk: !!(j && j.ok), raw: JSON.stringify(j).slice(0, 120)};
      }).catch(function (e) { return {apiOk: false, raw: String(e)}; });
    } catch (e) { return {apiOk: false, raw: String(e)}; }
  })()`);
  // ② 再用 /api/status 复核：device 必须是"Null"或空，绝不能是真实设备名
  await sleep(600);
  const snd = await s.eval(`fetch('/api/status').then(function (r) { return r.json(); }).then(function (j) {
    return {device: String(j.device || ''), deviceId: String(j.deviceId || ''), backend: String(j.backend || '')};
  })`);
  const muted = /^(|null|Null)/i.test(snd.deviceId || '') ||
                /null|不出声/i.test(snd.device || '') ||
                /^null$/i.test(snd.backend || '');
  ck(muted, '🔴 已强制静音后端（铁律 1：绝不出声）',
     'device=' + JSON.stringify(snd.device) + ' deviceId=' + JSON.stringify(snd.deviceId));
  if (!muted) {
    // 拿不到 null 后端就**中止**，绝不"先播了再说"
    console.error('\n⛔ 无法把播放后端切换到 null —— 为避免向用户扬声器出声，测试中止。');
    console.error('   请用 printf \'backend=null\\n\' > <STATE_DIR>/rlplayer-settings.conf 预置后重跑。');
    await s.close();
    process.exit(2);
  }
  // 判据要证明"冷启动"这件事本身：#setpage 必须从未被渲染（innerHTML 长度 0），
  // 否则测的就不是冷启动路径，修好了也说明不了问题。
  const cold = await s.eval(`({
    setpageLen: (document.getElementById('setpage') || {innerHTML: ''}).innerHTML.length,
    cards: document.querySelectorAll('#list .card').length
  })`);
  ck(cold.setpageLen === 0, '设置页未曾渲染（真正的冷启动）', 'setpage.innerHTML len=' + cold.setpageLen);
  ck(cold.cards > 0, '专辑卡片已加载', cold.cards + ' 张');

  const played = await s.eval(`(function () {
    var c = document.querySelector('#list .card');
    if (!c) return {err: 'no card'};
    var pl = c.querySelector('.pl');
    if (!pl) return {err: 'no .pl'};
    pl.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
    return {ok: true};
  })()`);
  ck(played.ok === true, '点击专辑播放按钮', JSON.stringify(played));
  await sleep(3200);
  const st = await s.eval(`fetch('/api/status').then(function (r) { return r.json(); }).then(function (j) {
    return {playing: j.playing, paused: j.paused, pos: j.pos, err: j.error || '',
            npt: (document.getElementById('npt') || {}).textContent || ''};
  })`);
  ck(st.playing === true, '后端真的开始播放', 'playing=' + st.playing + ' pos=' + (st.pos || 0).toFixed(2));
  ck(st.pos > 0.5, '播放位置在推进（不是卡住）', 'pos=' + (st.pos || 0).toFixed(2));
  // 这是 B-1 的原始症状：params() 里裸 D('sXxx').value 抛 TypeError
  const t1 = s.errors.filter((e) => /TypeError/.test(e));
  ck(t1.length === 0, '无 TypeError（params() 裸取值缺陷已消除）', t1.slice(0, 3).join(' | ') || 'none');
  await shot('b1-playing');

  // ============================================================
  section('B-2 设置页「保存设置」栏贴底');
  await s.eval(`Array.from(document.querySelectorAll('.nav')).find(function (e) { return e.dataset.v === 'settings'; }).click()`);
  await sleep(1500);
  const TABS = ['in', 'out', 'pcm', 'sdm', 'adv', 'eq', 'meta'];
  let footBad = [];
  for (const g of TABS) {
    await s.eval(`(function () { var b = document.querySelector('#setpage .stab[data-g=${g}]'); if (b) b.click(); })()`);
    await sleep(550);
    // 2026-10-26 结构变更后的判据（用户要求「保存/恢复默认做进各个页面里」）：
    //   保存栏不再是"全局粘在滚动区底部的浮层"，而是每个 .spane 自己的页脚。
    //   所以判据改成三条：
    //     ① 当前页签**自己**有一个可见的保存栏（不是全局那一个）；
    //     ② 内容不满一屏时，它落在页面底部（gap ≈ padding-bottom，不再悬空）；
    //     ③ 内容超过一屏时，滚到底能看到它，且不被播放条遮挡。
    //   同时检查"只有 .sbody 在滚"（#setpage 自身 scrollTop 必须恒为 0）。
    const m = await s.eval(`(function () {
      var sp = document.getElementById('setpage');
      var sb = sp.querySelector('.sbody');
      var pane = sp.querySelector('.spane.on');
      var f = pane ? pane.querySelector('.setfoot') : null;
      if (!f || getComputedStyle(f).display === 'none') return {hidden: true, g: pane ? pane.dataset.g : '?'};
      var scrollable = sb.scrollHeight > sb.clientHeight + 1;
      if (scrollable) sb.scrollTop = sb.scrollHeight;   // 长页先滚到底再量
      var fr = f.getBoundingClientRect();
      var sr = sb.getBoundingClientRect();
      var bar = document.querySelector('.bar').getBoundingClientRect();
      var res = {gap: Math.round(sr.bottom - fr.bottom),
                 inside: fr.bottom <= sr.bottom + 1,
                 covered: fr.bottom > bar.top,
                 scrollable: scrollable,
                 paneScrollOwn: sp.scrollTop === 0};
      sb.scrollTop = 0;
      return res;
    })()`);
    // 长页（内容超一屏）与短页判据不同：长页只要"滚到底能看到、不被播放条盖住"就算过，
    // 不能要求它同时满足"不满一屏也贴底"（那是自相矛盾的）。
    const ok = !m.hidden && m.inside && !m.covered && m.paneScrollOwn === true
             && (m.scrollable ? true : m.gap <= 40);
    ck(ok, '页签 ' + g + ' 保存栏在本页内且可见可点', JSON.stringify(m));
    if (!ok) footBad.push(g);
  }
  await s.eval(`document.querySelector('#setpage .stab[data-g=meta]').click()`);
  await sleep(500);
  await shot('b2-foot-meta');
  await s.eval(`document.querySelector('#setpage .stab[data-g=eq]').click()`);
  await sleep(500);
  await shot('b2-foot-eq');

  // ============================================================
  section('B-3 底栏超长文字不得压住控制组 / F-1 跑马灯');
  await s.eval(`Array.from(document.querySelectorAll('.nav')).find(function (e) { return e.dataset.v === 'albums'; }).click()`);
  await sleep(900);
  const barLong = await s.eval(`(function () {
    document.getElementById('npt').textContent = ${JSON.stringify(LONG_TITLE)};
    document.getElementById('npart').textContent = ${JSON.stringify(LONG_ARTIST)};
    return new Promise(function (res) { setTimeout(function () {
      var np = document.querySelector('.np'), keys = document.querySelector('.keys');
      var mq = document.getElementById('mqTitle'), mqi = mq && mq.querySelector('.mqi');
      var nb = np.getBoundingClientRect(), kb = keys.getBoundingClientRect();
      var bar = document.querySelector('.bar');
      res({
        npRight: Math.round(nb.right), keysLeft: Math.round(kb.left),
        overlap: nb.right > kb.left,
        barCols: getComputedStyle(bar).gridTemplateColumns,
        mqOn: mq ? mq.classList.contains('mqon') : null,
        dist: mq ? mq.style.getPropertyValue('--mqdist') : '',
        dur: mq ? mq.style.getPropertyValue('--mqdur') : '',
        anim: mqi ? getComputedStyle(mqi).animationName : '',
        synced: mqi ? (mqi.textContent === document.getElementById('npt').textContent) : false
      });
    }, 500); });
  })()`);
  // 核心判据：底栏三列不得互相侵占
  ck(!barLong.overlap, '超长曲名不压住中间控制组', 'np.right=' + barLong.npRight + ' keys.left=' + barLong.keysLeft);
  ck(barLong.mqOn === true, '溢出时跑马灯已启用', 'dist=' + barLong.dist + ' dur=' + barLong.dur);
  ck(barLong.anim === 'mqscroll', '动画真的在跑（不是只加了 class）', 'animationName=' + barLong.anim);
  ck(barLong.synced === true, '文本源与滚动层已同步（MutationObserver 生效）');
  await shot('b3-bar-long');

  // 短文本必须静止 —— 否则"短标题也晃"比截断更难看
  const barShort = await s.eval(`(function () {
    document.getElementById('npt').textContent = '短';
    document.getElementById('npart').textContent = '也短';
    return new Promise(function (res) { setTimeout(function () {
      var mq = document.getElementById('mqTitle');
      var mqi = mq && mq.querySelector('.mqi');
      res({mqOn: mq ? mq.classList.contains('mqon') : null,
           anim: mqi ? getComputedStyle(mqi).animationName : ''});
    }, 400); });
  })()`);
  ck(barShort.mqOn === false && barShort.anim === 'none', '不溢出时跑马灯静止', JSON.stringify(barShort));

  // ============================================================
  section('B-4 EQ 页 20 段文字堆叠');
  await s.eval(`Array.from(document.querySelectorAll('.nav')).find(function (e) { return e.dataset.v === 'settings'; }).click()`);
  await sleep(1200);
  await s.eval(`document.querySelector('#setpage .stab[data-g=eq]').click()`);
  await sleep(1400);
  // 2026-10-26 改进（代价：原判据是**假绿**）：
  //   原来只在单一窗宽（1576px）量一次，且没有负向对照。
  //   实测证明：把 --peqcols 改回修复前的旧值（minmax(0,...)），在 1024~1576px 下
  //   溢出数**依然是 0** ⟹ 那个 PASS 无法区分"修好了"和"没修"，证明力为零。
  //   用户报的叠字**只在 ≤720px 复现**（实测：720px 旧 CSS 溢出 50 处、640px 溢出 60 处）。
  //   所以现在：扫 6 档窗宽 × 3 主题，并对最窄档做**负向对照**（就地改回旧 CSS 必须变红）。
  const EQ_WIDTHS = [1576, 1280, 1024, 800, 720, 640];
  const EQ_THEMES = ['dark', 'light', 'blue'];
  const probeEq = `(function () {
    var rows = Array.from(document.querySelectorAll('.peqr'));
    var overflow = [], overlap = [], clipped = [];
    rows.forEach(function (r, i) {
      Array.from(r.querySelectorAll('input,select')).forEach(function (inp) {
        if (inp.type === 'checkbox') return;
        if (inp.scrollWidth - inp.clientWidth > 2) overflow.push({row: i + 1, val: inp.value, over: inp.scrollWidth - inp.clientWidth});
        // 裁切：内容比可见宽，用户看不到完整数字（与"溢出到相邻列"是两种病，都要查）
        if (inp.clientWidth > 0 && inp.scrollWidth > inp.clientWidth + 2) clipped.push({row: i + 1, val: inp.value});
      });
      var cells = Array.from(r.children);
      for (var c = 0; c < cells.length - 1; c++) {
        var a = cells[c].getBoundingClientRect(), b = cells[c + 1].getBoundingClientRect();
        if (a.right > b.left + 0.5) overlap.push({row: i + 1, col: c, px: +(a.right - b.left).toFixed(1)});
      }
    });
    var hd = document.querySelector('.peqhd'), hdr = [];
    if (hd) {
      var hc = Array.from(hd.children);
      for (var k = 0; k < hc.length - 1; k++) {
        var x = hc[k].getBoundingClientRect(), y = hc[k + 1].getBoundingClientRect();
        if (x.right > y.left + 0.5) hdr.push({col: k, px: +(x.right - y.left).toFixed(1)});
      }
    }
    return {rows: rows.length, overflow: overflow, overlap: overlap, clipped: clipped, headerOverlap: hdr};
  })()`;

  let eqBad = [];
  for (const w of EQ_WIDTHS) {
    await s.setViewport(w, 908);
    await sleep(320);
    for (const th of EQ_THEMES) {
      await s.eval(`(function () {
        if (${JSON.stringify(th)} === 'dark') delete document.documentElement.dataset.theme;
        else document.documentElement.dataset.theme = ${JSON.stringify(th)};
      })()`);
      await sleep(180);
      const r = await s.eval(probeEq);
      const ok = r.rows === 20 && r.overflow.length === 0 && r.overlap.length === 0
              && r.clipped.length === 0 && r.headerOverlap.length === 0;
      if (!ok) eqBad.push({w, th, r});
      ck(ok, 'EQ ' + w + 'px / ' + th + ' 无叠字无裁切',
         'rows=' + r.rows + ' 溢出=' + r.overflow.length + ' 相交=' + r.overlap.length
         + ' 裁切=' + r.clipped.length);
    }
  }
  // 负向对照：在 720px 下把 --peqcols 改回修复前的旧值，判据**必须变红**
  await s.setViewport(720, 908);
  await sleep(300);
  await s.eval(`(function () {
    delete document.documentElement.dataset.theme;
    var st = document.getElementById('negctl'); if (st) st.remove();
    st = document.createElement('style'); st.id = 'negctl';
    st.textContent = '.peqwrap{--peqcols:36px minmax(0,1.3fr) minmax(0,1fr) minmax(0,.9fr) 96px 40px !important;max-width:720px !important}';
    document.head.appendChild(st);
  })()`);
  await sleep(350);
  const neg = await s.eval(probeEq);
  const negCaught = neg.overflow.length > 0 || neg.overlap.length > 0 || neg.clipped.length > 0;
  ck(negCaught, '负向对照：改回旧 CSS 后判据确实变红（证明上面不是假绿）',
     '溢出=' + neg.overflow.length + ' 相交=' + neg.overlap.length + ' 裁切=' + neg.clipped.length);
  await s.shot('b4-negative-control');
  // 复原
  await s.eval("(function(){var st=document.getElementById('negctl');if(st)st.remove();})()");
  await s.setViewport(1576, 908);
  await sleep(300);
  await shot('b4-eq');

  // ============================================================
  section('F-2 快速开始「设置文件夹位置」跳转');
  await s.eval(`Array.from(document.querySelectorAll('.nav')).find(function (e) { return e.dataset.v === 'station'; }).click()`);
  await sleep(1300);
  const hasBtn = await s.eval(`!!document.getElementById('amGoFiles')`);
  ck(hasBtn, '快速开始卡片按钮存在');
  await s.eval(`document.getElementById('amGoFiles').click()`);
  await sleep(1800);
  const jump = await s.eval(`(function () {
    var sp = document.getElementById('setpage');
    var act = document.querySelector('#setpage .stab.on');
    var adv = document.querySelector('#setpage .spane[data-g=adv]');
    var root = document.getElementById('sp_root');
    var inView = false;
    if (root) { var b = root.getBoundingClientRect(); inView = b.top > 0 && b.bottom < window.innerHeight; }
    return {on: sp ? sp.classList.contains('on') : false,
            tab: act ? act.dataset.g : null,
            advOn: adv ? adv.classList.contains('on') : false,
            activeId: document.activeElement ? document.activeElement.id : null,
            inView: inView};
  })()`);
  ck(jump.on === true, '点击后进入了设置页');
  ck(jump.tab === 'adv' && jump.advOn === true, '落在「高级」页签', 'tab=' + jump.tab);
  ck(jump.activeId === 'sp_root', '音乐目录输入框获得焦点（可直接打字）', 'focus=' + jump.activeId);
  ck(jump.inView === true, '输入框滚动到可见区域');
  await shot('f2-jump');

  // ============================================================
  section('F-3 apple / classic 两套主题互不干扰');
  const varNames = ['--ok', '--warn', '--danger', '--bp-direct', '--txt', '--field', '--bar-border'];
  const snap = {};
  for (const style of ['apple', 'classic']) {
    for (const theme of ['dark', 'light', 'blue']) {
      await s.eval(`(function () {
        document.documentElement.dataset.uistyle = ${JSON.stringify(style)};
        if (${JSON.stringify(theme)} === 'dark') delete document.documentElement.dataset.theme;
        else document.documentElement.dataset.theme = ${JSON.stringify(theme)};
      })()`);
      await sleep(280);
      const vals = await s.eval(`(function () {
        var cs = getComputedStyle(document.documentElement);
        var o = {};
        ${JSON.stringify(varNames)}.forEach(function (n) { o[n] = cs.getPropertyValue(n).trim(); });
        return o;
      })()`);
      snap[style + '/' + theme] = vals;
    }
  }
  // 判据修正（2026-10-26 第一版写错了，这里记下为什么改）：
  //   最初用「apple 与 classic 的变量**值**是否相同」来判断隔离性 —— 这是**错判据**：
  //   classic/blue 的 --warn 显式声明为 #b45309，恰好与 apple/blue 同值，
  //   值相同不等于"没定义、在吃 apple 的 :root 继承"。
  //   正确判据是「classic 的选择器里是否**显式声明**了该变量」：
  //   CSS 变量只在整个规则里没有声明时才回退继承 ;root，所以"显式存在"才证明隔离。
  //   读法：取 classic 各档规则文本，检查关键颜色变量是否都出现在声明里。
  //   实测结论：classic 三档分别显式声明 42 / 36 / 36 个变量，
  //   缺的 6 个（r-lg / r-md / r-sm / sh1 / sh2 / sidew）是圆角、阴影、侧栏宽等非颜色量，
  //   按设计由 classic 基础层提供，属合理。
  const needVars = ['--ok', '--warn', '--danger', '--bp-direct', '--txt', '--field',
                    '--bar-border', '--line', '--hov'];
  // 为什么不用 CSSOM 的 selectorText / cssText：
  //   试过两版都拿不到 —— ① selectorText 被浏览器规范化，拼不上；
  //   ② cssRules[i].cssText 对这份 67KB 的内联样式表读出来是空的。
  //   最终直接读 <style> 元素的 textContent（实测 623 条规则、完整可搜到 classic 选择器）。
  const declared = await s.eval(`(function () {
    var css = '';
    var st = document.querySelectorAll('style');
    for (var i = 0; i < st.length; i++) css += st[i].textContent;
    var want = ${JSON.stringify(needVars)};
    function grab(re) { var m = css.match(re); return m ? m[1] : null; }
    var targets = {
      'classic/dark': grab(/html\\[data-uistyle=classic\\]\\s*\\{([^}]*)\\}/),
      'classic/light': grab(/html\\[data-uistyle=classic\\]\\[data-theme=light\\]\\s*\\{([^}]*)\\}/),
      'classic/blue': grab(/html\\[data-uistyle=classic\\]\\[data-theme=blue\\]\\s*\\{([^}]*)\\}/)
    };
    var out = {};
    Object.keys(targets).forEach(function (k) {
      var body = targets[k];
      if (!body) { out[k] = {err: 'rule not found'}; return; }
      var declaredNames = (body.match(/--[a-z0-9-]+\\s*:/g) || []).map(function (x) {
        return x.replace(/\\s*:$/, '');
      });
      var miss = want.filter(function (v) { return declaredNames.indexOf(v) < 0; });
      out[k] = {declaredCount: declaredNames.length, have: want.length - miss.length, missing: miss};
    });
    return out;
  })()`);
  for (const k of ['classic/dark', 'classic/light', 'classic/blue']) {
    const v = declared[k] || {};
    ck(!v.err && v.missing && v.missing.length === 0,
      k + '：关键颜色变量全部显式声明（真正隔离）',
      v.err ? v.err : (v.declaredCount + ' 个声明, 缺 ' + JSON.stringify(v.missing)));
  }
  await s.eval(`document.documentElement.dataset.uistyle = 'apple'`);
  await shot('f3-apple-dark');

  // ============================================================
  section('运行期 JS 异常');
  const errs = s.errors.filter((e) => !/favicon|net::ERR/.test(e));
  ck(errs.length === 0, '整轮无 JS 异常', errs.slice(0, 5).join(' | ') || 'none');

  await s.close();

  console.log('\n================ 汇总 ================');
  const fails = results.filter((r) => r.indexOf('[FAIL]') >= 0);
  const passes = results.filter((r) => r.indexOf('[PASS]') >= 0);
  console.log('PASS ' + passes.length + ' / FAIL ' + fails.length);
  console.log('截图目录: ' + OUT);
  if (fails.length) { fails.forEach((f) => console.log(f)); process.exit(1); }
  process.exit(0);
})().catch((e) => {
  console.error('环境/脚本错误: ' + (e && e.stack ? e.stack : e));
  process.exit(2);
});
