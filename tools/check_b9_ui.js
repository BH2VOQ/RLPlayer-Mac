// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_b9_ui.js — 1.1.4-beta9「单曲页左右竖栏始终贴紧窗口最左/最右」UI 判据
//
// 用户反馈（2026-11-08，附截图）：
//   「左右侧窗口在放大状态下，没有同时变换到窗口的最左侧最右侧，这两个窗口需要一直
//     贴在最左侧最右侧，无论窗口的具体大小」
//
// 判据（每条对应截图里的那条红线）：
//   D1 任一窗口宽度下，左竖栏左缘 == 窗口左缘 + 同一小边距、右竖栏右缘 == 窗口右缘 - 同一边距，
//      且该边距 0 < gut <= 24px。用户第一轮「需要一直贴在最左侧最右侧 无论窗口的具体大小」，
//      第二轮又说「不能 0px 0px 的视觉效果太差了」⟹ 贴边 + 保留一小段恒定呼吸位；
//   D2 左右竖栏始终等宽（沿用 beta4 对称硬约束），且宽度有上限（竖栏是栏，不是被拉满的版面）；
//   D3 歌词中心 == 页面中心（沿用 beta4/beta6 硬约束：侧栏贴边不影响歌词居中）；
//   D4 全档边距**完全一致**（不随窗口放大而变大）：
//      旧实现 max-width:1240 + margin:auto，实测 24→60→208→380→700（本判据在旧版必红）；
//      0px 版本因视觉太差被用户否掉，本判据同时要求 > 0，防止又退回贴死窗边；
//   D5 行1（封面/标题）与左右竖栏共用同一条左右边线（≤1.5px）——截图里封面左缘与左栏
//      左缘本来就对齐，贴边后必须保持，否则是"栏跑了、标题没跑"；
//   D6 无横向溢出（scrollWidth ≤ 视口宽 + 1）、控制区完整留在视口内；
//   D7 行3（进度/控制）**不**跟着贴边：限宽 ≤1160px 且居中于页面（261024-01 #3b 的
//      控制键居中要求，横跨两千多像素的进度条也难拖）。贴边只针对两侧竖栏。
//
// 旧版实测（改动前，本机同一实例）：
//   1280x800  npAnal.l=60   1576x908  npAnal.l=208   （应为恒定 16px）
//   1920x1080 npAnal.l=380  2560x1440 npAnal.l=700
// ⟹ D1/D4 在旧版会 FAIL，这就是本脚本的红/绿分界。
//
// 用法：node tools/check_b9_ui.js http://127.0.0.1:19114/ [/tmp/b9shots]
// 🔴 全程 headless，不播放任何音频（不调 /api/play），后端用 backend=null 的隔离实例。
'use strict';
const ub = require('./uibrowser');
const fs = require('fs');

const URL_ = process.argv[2] || 'http://127.0.0.1:19114/';
const OUT = process.argv[3] || '/tmp/b9shots';
let fail = 0, total = 0;
function ck(ok, what, detail) {
  total++;
  if (!ok) fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${what}${detail ? '  ' + detail : ''}`);
}
const J = (o) => JSON.stringify(o);

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const s = await ub.open({ url: URL_, width: 1280, height: 800, settleMs: 2500 });
  try {
    const ready = await s.waitFor("typeof openNowPlaying === 'function' && document.getElementById('npGrid')", 15000);
    if (!ready) { console.log('FATAL: 页面没起来（找不到 openNowPlaying / #npGrid）'); process.exit(2); }
    const ev = (x) => s.eval(x);
    await ev("(function(){ if(typeof openNowPlaying==='function') openNowPlaying(); return 1; })()");
    await ub.sleep(700);

    const measure = async (w, h) => {
      await s.setViewport(w, h);
      await ub.sleep(260);
      const g = await ev(`(function(){
        var q=function(sel){var e=document.querySelector(sel);if(!e)return null;var b=e.getBoundingClientRect();
          return {l:Math.round(b.left),r:Math.round(b.right),t:Math.round(b.top),b:Math.round(b.bottom),w:Math.round(b.width)};};
        var cs=getComputedStyle(document.getElementById('npGrid'));
        var lyr=document.getElementById('npLyric').getBoundingClientRect();
        var page=document.getElementById('npPage');
        return {vw:innerWidth, vh:innerHeight,
                padL:parseFloat(cs.paddingLeft), padR:parseFloat(cs.paddingRight),
                anal:q('#npAnal'), rail:q('#npRail'), lyr:q('#npLyric'),
                hero:q('.nphero'), cover:q('.npcover'), ctl:q('.npctl2'),
                lyrCenter: lyr.left + lyr.width/2,
                pageCenter: innerWidth/2,
                sw: page.scrollWidth};
      })()`);
      await s.shot(`${OUT}/b9_${w}x${h}.png`);
      return g;
    };

    const rows = [];
    for (const [w, h] of [[1024, 640], [1280, 800], [1576, 908], [1920, 1080], [2560, 1440]]) {
      rows.push({ w, h, g: await measure(w, h) });
    }

    for (const { w, h, g } of rows) {
      const okBox = g && g.anal && g.rail && g.lyr && g.hero && g.cover && g.ctl;
      // D1：左栏贴窗口左缘 + 小边距、右栏贴窗口右缘 - 同一边距；边距恒定且 > 0
      const gapL = okBox ? g.anal.l : -1;
      const gapR = okBox ? (g.vw - g.rail.r) : -1;
      const gutOk = okBox && gapL === gapR && gapL > 0 && gapL <= 24;
      ck(gutOk, `D1 ${w}x${h}：左右竖栏贴住窗口最左/最右（恒定小边距，非 0px）`,
        okBox ? `gapL=${gapL} gapR=${gapR} padL=${g.padL} padR=${g.padR}` : '');
      // D2：两栏等宽，且不被窗口拉宽（上限 341px）
      const sideEq = okBox && Math.abs(g.anal.w - g.rail.w) <= 1.5;
      const sideCap = okBox && g.anal.w <= 341 && g.anal.w >= 200;
      ck(sideEq && sideCap, `D2 ${w}x${h}：左右竖栏等宽且宽度有上限`,
        okBox ? `analW=${g.anal.w} railW=${g.rail.w}` : '');
      // D3：歌词中心 == 页面中心
      ck(okBox && Math.abs(g.lyrCenter - g.pageCenter) <= 1.5,
        `D3 ${w}x${h}：歌词中心恒等于页面中心`,
        okBox ? `lyrCenter=${g.lyrCenter.toFixed(1)} pageCenter=${g.pageCenter.toFixed(1)}` : '');
      // D5：行1 封面/标题与竖栏同一条左右边线（行3 控制区按用户既有要求居中限宽，见 D7）
      const heroAligned = okBox && Math.abs(g.cover.l - g.anal.l) <= 1.5 && Math.abs(g.hero.r - g.rail.r) <= 1.5;
      ck(heroAligned, `D5 ${w}x${h}：行1 封面/标题与竖栏共用同一条左右边线`,
        okBox ? `cover.l=${g.cover.l} anal.l=${g.anal.l} hero.r=${g.hero.r} rail.r=${g.rail.r}` : '');
      // D7：控制区不跟着拉成超宽条 —— 限宽 ≤1160 且居中于页面（261024-01 #3b 控制键居中）
      const ctlCentered = okBox && Math.abs((g.ctl.l + g.ctl.r) / 2 - g.pageCenter) <= 1.5 && g.ctl.w <= 1160;
      ck(ctlCentered, `D7 ${w}x${h}：进度/控制区限宽并居中（贴边只针对两侧竖栏）`,
        okBox ? `ctl=[${g.ctl.l},${g.ctl.r}] w=${g.ctl.w} pageCenter=${g.pageCenter}` : '');
      // D6：无横向溢出 + 控制区在视口内
      ck(okBox && g.sw <= g.vw + 1 && g.ctl.b <= g.vh + 1,
        `D6 ${w}x${h}：无横向溢出、控制区完整在视口内`,
        okBox ? `scrollW=${g.sw} vw=${g.vw} ctl.b=${g.ctl.b} vh=${g.vh}` : '');
    }

    /* D4：侧栏离窗口边缘的距离不随窗口放大而增大（逐档单调不增，容差 2px）。
       注意不能直接断言"各档留白完全相同"：窄窗（≤1120px）有 @media 压缩内边距 40→24，
       那是既有的窄窗紧凑策略，不是本问题。用户报的是"放大时侧栏往里缩"，
       所以判据是**变宽不许变远**：旧版实测 24→60→208→380→700（必红），
       修好后 24→40→40→40→40（绿）。 */
    const insets = rows.map(({ g }) => (g && g.anal ? g.anal.l : null));
    const allSame = insets.length === rows.length && insets.every((v) => v !== null && v === insets[0]);
    const notFlush = insets.length === rows.length && insets.every((v) => v !== null && v > 0);
    ck(allSame && notFlush,
      'D4 全档边距完全一致（不随窗口放大而变，且不是 0px 贴死窗边）',
      `insets=${J(insets)}（窗口 ${rows.map((r) => r.w).join('→')}）`);

    console.log(`\n=== 结果：${total} 项，${fail} 失败 ===`);
    process.exit(fail === 0 ? 0 : 1);
  } finally {
    await s.close();
  }
})();
