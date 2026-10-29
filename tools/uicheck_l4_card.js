// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uicheck_l4_card.js — L-4（--card 未定义 ⟹ 卡片背景透明）的可复跑判据
//
// 判据来源：debug/20261027-00-BUG与新增功能总清单.md §7.4
//   "真浏览器取 getComputedStyle(card).backgroundColor，
//    红 = rgba(0,0,0,0)；绿 = 与 --bg3 同值"
//
// 为什么必须用真浏览器而不是 grep：
//   静态 grep 只能证明"源码里 var(--card) 被引用、--card 没定义"，
//   证明不了"这条声明在计算值阶段真的作废"。
//   CSS 变量未定义且无 fallback 时，属性在计算值阶段变成 unset（不是回退到更早的竞争声明），
//   这一步只有 getComputedStyle 能给出定论。历史教训（铁律 3）：指标必须能证明要证明的事。
//
// 三套主题各测一次：--card 是主题变量，dark/light/blue 必须各自定义。
// 同时测 .model-card（OPRA 型号卡，靠临时节点）与 .preset-card（页面真实节点）。
//
// 用法：
//   node tools/uicheck_l4_card.js http://127.0.0.1:8971/ [截图目录]
// 退出码：0 = 全绿；1 = 有红；2 = 环境问题

'use strict';
const ub = require('./uibrowser');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_ = process.argv[2] || 'http://127.0.0.1:8971/';
const OUT = process.argv[3] || path.join(os.tmpdir(), 'rta_l4_card');
fs.mkdirSync(OUT, { recursive: true });

const results = [];
function ck(ok, what, detail) {
  results.push({ ok, what, detail });
  console.log((ok ? '  [PASS] ' : '  [FAIL] ') + what + (detail ? '  — ' + detail : ''));
}

// 把 rgb/rgba 归一成 [r,g,b,a]
function parseColor(s) {
  const m = /rgba?\(([^)]+)\)/.exec(String(s || ''));
  if (!m) return null;
  const p = m[1].split(',').map((x) => parseFloat(x.trim()));
  return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
}
const isTransparent = (c) => !c || c[3] === 0;

(async () => {
  let s;
  try {
    s = await ub.open({ url: URL_, width: 1500, height: 950, settleMs: 2600 });
  } catch (e) {
    console.error('环境问题：' + e.message);
    process.exit(2);
  }

  try {
    // 等应用起来
    const up = await s.waitFor('window.S && document.querySelector(".nav")', 20000);
    if (!up) throw new Error('页面没起来（window.S 不存在）');
    await ub.sleep(600);

    // ---- 先确认 --card 在当前主题下的定义情况（定位用，不作判据）----
    const rootInfo = await s.eval(
      '(function(){var cs=getComputedStyle(document.documentElement);' +
      'return {card:cs.getPropertyValue("--card").trim(), bg3:cs.getPropertyValue("--bg3").trim(), theme:document.documentElement.dataset.theme||"dark"};})()'
    );
    console.log('  基线主题=' + rootInfo.theme + '  --card="' + rootInfo.card + '"  --bg3="' + rootInfo.bg3 + '"');

    // ---- 确保 .preset-card 真实节点存在：进「快速开始」页 ----
    await s.eval(
      "(function(){var n=Array.prototype.slice.call(document.querySelectorAll('.nav')).find(function(e){return e.dataset.v==='station';}); if(n) n.click(); return !!n;})()"
    );
    const hasCard = await s.waitFor('!!document.querySelector("#presetCard")', 12000);
    ck(hasCard, '快速开始页渲染出 .preset-card 真实节点 (#presetCard)');

    // OPRA 型号卡依赖 data/opra_index.json；没有数据时用同 class 的临时节点，
    // 判的是「同一条 CSS 声明能否算出非透明背景」，与真实节点等价。
    await s.eval(
      '(function(){var d=document.createElement("div");d.className="model-card";d.id="__l4probe";' +
      'd.style.position="absolute";d.style.left="-9999px";d.textContent="probe";document.body.appendChild(d);return true;})()'
    );

    const NODES = [
      { sel: '.preset-card', label: '.preset-card（快速开始·官方推荐预设卡）' },
      { sel: '#__l4probe', label: '.model-card（OPRA 型号卡，临时同 class 节点）' },
    ];

    const THEMES = ['dark', 'light', 'blue'];
    for (const t of THEMES) {
      await s.eval('(function(){ if(typeof setTheme==="function") setTheme(' + JSON.stringify(t) + ', false); document.documentElement.dataset.theme=' + JSON.stringify(t) + '; return true;})()');
      await ub.sleep(260);
      const bg3 = await s.eval('getComputedStyle(document.documentElement).getPropertyValue("--bg3").trim()');
      const cardVar = await s.eval('getComputedStyle(document.documentElement).getPropertyValue("--card").trim()');
      console.log('  [' + t + ']  --card="' + cardVar + '"  --bg3="' + bg3 + '"');

      ck(!!cardVar, '[' + t + '] 主题定义了 --card', cardVar ? cardVar : '(未定义)');

      for (const n of NODES) {
        const c = await s.eval(
          '(function(){var e=document.querySelector(' + JSON.stringify(n.sel) + ');' +
          'if(!e) return null;var bg=getComputedStyle(e).backgroundColor;' +
          'var d=document.createElement("div");d.style.background=' + JSON.stringify(bg3) + ';' +
          'document.body.appendChild(d);var want=getComputedStyle(d).backgroundColor;d.remove();' +
          'return {bg:bg,want:want};})()'
        );
        if (!c) { ck(false, '[' + t + '] ' + n.label + ' 节点存在'); continue; }
        const got = parseColor(c.bg), want = parseColor(c.want);
        const transparent = isTransparent(got);
        const same = got && want && Math.abs(got[0] - want[0]) < 1 && Math.abs(got[1] - want[1]) < 1 &&
                     Math.abs(got[2] - want[2]) < 1 && Math.abs(got[3] - want[3]) < 0.02;
        ck(!transparent && same, '[' + t + '] ' + n.label + ' 底色不透明且等于 --bg3',
           'got=' + c.bg + '  期望≈' + c.want);
      }
      await s.shot(path.join(OUT, 'l4_' + t + '.png'));
    }

    const errs = s.errors.slice(0, 5);
    ck(errs.length === 0, '页面无 JS 异常 / console.error', errs.join(' | '));
  } catch (e) {
    console.error('执行失败：' + e.message);
    ck(false, '脚本执行完成', e.message);
  } finally {
    await s.close();
  }

  const failed = results.filter((r) => !r.ok);
  console.log('\n  合计 ' + (results.length - failed.length) + '/' + results.length + ' 通过' +
              (failed.length ? '，' + failed.length + ' 条红' : ''));
  console.log('  截图目录：' + OUT);
  if (failed.length) {
    console.log('\n  红项清单：');
    failed.forEach((f) => console.log('    - ' + f.what));
  }
  process.exit(failed.length ? 1 : 0);
})();
