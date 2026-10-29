// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uicheck_f4_avatar.js — F-4（艺人头像）的可复跑判据
//
// 判据来源：debug/20261027-00-BUG与新增功能总清单.md §2.2 F-4
//   "本地完全没有该能力 … 真实库 245 位艺人里 106 位会永远显示首字母圆"
//
// 核心判据（"不留白圆"的唯一可信证据）：
//   艺术家页**每一位**艺人的头像元素，必须满足二者之一：
//     · 有有效 img：naturalWidth > 0（图真的解码出来了，不是 200 但空图）
//     · 有首字母文本：.ph 里有非空字符
//   **不允许两者都空** —— 那就是用户看到的白圆。
//
// 为什么不用"接口返回 200"当判据（铁律 3）：
//   200 只能证明服务端回了东西；这里要证明的是**用户眼睛看到的东西**。
//   naturalWidth 是浏览器解码后的真实尺寸，1x1 占位图会是 1 而不是 0 ——
//   所以再加一条：有效图必须 naturalWidth >= 16（排除 1x1 占位 PNG，B-1 那个坑）。
//
// 用法：node tools/uicheck_f4_avatar.js http://127.0.0.1:PORT/ [截图目录]
// 退出码：0 = 全绿；1 = 有红；2 = 环境问题
'use strict';
const ub = require('./uibrowser');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_ = process.argv[2] || 'http://127.0.0.1:8992/';
const OUT = process.argv[3] || path.join(os.tmpdir(), 'rta_f4_avatar');
fs.mkdirSync(OUT, { recursive: true });

const results = [];
function ck(ok, what, detail) {
  results.push({ ok, what, detail });
  console.log((ok ? '  [PASS] ' : '  [FAIL] ') + what + (detail ? '  — ' + detail : ''));
}

(async () => {
  let s;
  try {
    s = await ub.open({ url: URL_, width: 1500, height: 950, settleMs: 2600 });
  } catch (e) {
    console.error('环境问题：' + e.message);
    process.exit(2);
  }

  try {
    if (!(await s.waitFor('window.S && document.querySelector(".nav")', 20000)))
      throw new Error('页面没起来');
    await ub.sleep(700);

    // ---------- A. 端点存在性（红侧基线这里会 404 not found） ----------
    const ep = await s.eval(
      "fetch('/api/artist/image?who=' + encodeURIComponent('蔡琴')).then(function(r){return {status:r.status, ct:r.headers.get('content-type')||''};}).catch(function(e){return {status:-1, err:String(e)};})"
    );
    console.log('  /api/artist/image 探测 = ' + JSON.stringify(ep));
    ck(ep && ep.status !== 404 || (ep && ep.ct && ep.ct.indexOf('json') >= 0),
       'F-4 头像端点已存在（红侧基线：not found）', JSON.stringify(ep));

    // ---------- B. 进艺术家页 ----------
    await s.eval(
      "(function(){var n=Array.prototype.slice.call(document.querySelectorAll('.nav')).find(function(e){return e.dataset.v==='artists';});if(n)n.click();return !!n;})()"
    );
    const hasCards = await s.waitFor("document.querySelectorAll('#list .card').length > 0", 25000);
    ck(hasCards, '艺术家列表已渲染');
    if (!hasCards) throw new Error('艺术家列表为空（测试库需要至少一位艺人）');

    // 给图片加载时间，并且**等到所有 img 都 complete** 再统计 ——
    // 固定 sleep 会与网络赛跑：实测 6 秒时仍有卡片 naturalWidth=0（图还在下），
    // 那样统计出来的"有效头像=0"是**判据自己的时序 bug**，不是产品缺陷（铁律 3）。
    // 这里改成显式等待：所有 img 的 complete 为 true，或最多等 30 秒。
    await s.waitFor(`(function(){
      var imgs = document.querySelectorAll('#list .card img');
      if (!imgs.length) return false;
      for (var i = 0; i < imgs.length; i++) { if (!imgs[i].complete) return false; }
      return true;
    })()`, 30000);
    await ub.sleep(800);   // complete 之后再给解码一帧

    // ---------- C. 核心判据：每位艺人不许白圆 ----------
    const audit = await s.eval(`(function(){
      var out = [];
      var cards = document.querySelectorAll('#list .card');
      for (var i = 0; i < cards.length; i++) {
        var c = cards[i];
        var who = c.getAttribute('data-a') || '';
        var ph = c.querySelector('.ph');
        var img = c.querySelector('img');
        var phText = ph ? (ph.textContent || '').trim() : '';
        var nw = 0, complete = false, src = '';
        if (img) { nw = img.naturalWidth || 0; complete = !!img.complete; src = img.getAttribute('src') || ''; }
        out.push({ who: who, phText: phText, hasImg: !!img, nw: nw, complete: complete,
                   hidden: img ? (img.style.display === 'none') : null, src: src.slice(0, 60) });
      }
      return out;
    })()`);

    console.log('  艺人卡片数 = ' + audit.length);
    const blank = audit.filter((a) => {
      const validImg = a.hasImg && a.nw >= 16 && !a.hidden;
      const hasChar = a.phText.length > 0;
      return !validImg && !hasChar;
    });
    const withImg = audit.filter((a) => a.hasImg && a.nw >= 16 && !a.hidden);
    const withPhOnly = audit.filter((a) => !(a.hasImg && a.nw >= 16 && !a.hidden) && a.phText.length > 0);

    console.log('  有效头像(img naturalWidth>=16) = ' + withImg.length);
    console.log('  仅首字母兜底 = ' + withPhOnly.length);
    console.log('  白圆(两者都空) = ' + blank.length);
    audit.slice(0, 8).forEach((a) => {
      console.log('    ' + JSON.stringify({ who: a.who, nw: a.nw, ph: a.phText, hidden: a.hidden }));
    });

    ck(blank.length === 0, 'F-4 没有任何一位艺人留白圆（有效 img 或首字母，二者必居其一）',
       blank.length ? ('白圆: ' + blank.map((b) => b.who).join(',')) : ('共 ' + audit.length + ' 位全部有内容'));

    // 1x1 占位图不算数（B-1 的坑）：如果有 img 但 nw 在 1..15，必须是它被隐藏 + 露首字母
    const tiny = audit.filter((a) => a.hasImg && a.nw > 0 && a.nw < 16 && !a.hidden);
    ck(tiny.length === 0, 'F-4 没有把 1x1 占位图当头像铺出来（B-1 同类坑）',
       tiny.length ? ('小图未隐藏: ' + tiny.map((t) => t.who + '/' + t.nw).join(',')) : '无');

    // ---------- D. 必须证明不是靠专辑封面冒充 ----------
    // 找一位「专辑都没封面」的艺人：他的 data-coverkey 为空，
    // 若仍然有有效头像，那就是 /api/artist/image 独立拿到的。
    const independent = await s.eval(`(function(){
      var cards = document.querySelectorAll('#list .card');
      var hit = [];
      for (var i = 0; i < cards.length; i++) {
        var img = cards[i].querySelector('img');
        if (!img) continue;
        var ck = img.getAttribute('data-coverkey') || '';
        var nw = img.naturalWidth || 0;
        if (!ck && nw >= 16 && img.style.display !== 'none') {
          hit.push({who: cards[i].getAttribute('data-a')||'', nw: nw, src: (img.getAttribute('src')||'').slice(0,50)});
        }
      }
      return hit;
    })()`);
    console.log('  无专辑封面但拿到独立头像的艺人 = ' + JSON.stringify(independent));
    ck(independent.length > 0,
       'F-4 有艺人「专辑无封面」却拿到了独立头像（证明不是拿专辑封面冒充）',
       independent.length ? (independent[0].who + ' nw=' + independent[0].nw) : '本测试库暂无此类艺人');

    await s.shot(path.join(OUT, 'f4_artists.png'));
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
