// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');

const base = (process.argv[2] || 'http://127.0.0.1:19102').replace(/\/$/, '');
const out = process.argv[3] || path.join(__dirname, '..', 'debug', '20261027-04-实测反馈7条', 'b2-peq');
fs.mkdirSync(out, { recursive: true });

const lines = [];
let failures = 0;

function check(ok, label, detail) {
  const line = `${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(detail)}`;
  lines.push(line);
  console.log(line);
  if (!ok) failures++;
}

function parseColor(str) {
  if (!str) return null;
  str = str.trim();
  const mRgb = str.match(/^rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$/i);
  if (mRgb) {
    return { r: Number(mRgb[1]), g: Number(mRgb[2]), b: Number(mRgb[3]), a: 1 };
  }
  const mRgba = str.match(/^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([\d.]+)\s*\)$/i);
  if (mRgba) {
    return { r: Number(mRgba[1]), g: Number(mRgba[2]), b: Number(mRgba[3]), a: Number(mRgba[4]) };
  }
  return null;
}

(async () => {
  let s;
  try {
    s = await ub.open({ url: base + '/', width: 1576, height: 908 });
    await s.waitFor("window.S && document.getElementById('setpage')", 30000);

    // 切到 eq tab
    await s.eval("openSettingsTab('eq')");
    await s.waitFor("document.querySelectorAll('#peqRows .peqr').length === 20", 20000);

    const themes = ['dark', 'light', 'blue', 'classic-dark', 'classic-light', 'classic-blue'];
    for (const theme of themes) {
      if (theme === 'dark') {
        await s.eval("document.documentElement.removeAttribute('data-uistyle'); document.documentElement.removeAttribute('data-theme')");
      } else if (theme === 'light' || theme === 'blue') {
        await s.eval(`document.documentElement.removeAttribute('data-uistyle'); document.documentElement.setAttribute('data-theme', '${theme}')`);
      } else if (theme === 'classic-dark') {
        await s.eval("document.documentElement.setAttribute('data-uistyle', 'classic'); document.documentElement.removeAttribute('data-theme')");
      } else if (theme === 'classic-light') {
        await s.eval("document.documentElement.setAttribute('data-uistyle', 'classic'); document.documentElement.setAttribute('data-theme', 'light')");
      } else if (theme === 'classic-blue') {
        await s.eval("document.documentElement.setAttribute('data-uistyle', 'classic'); document.documentElement.setAttribute('data-theme', 'blue')");
      }
      await new Promise(r => setTimeout(r, 200));

      const styles = await s.eval(`(() => {
        const hd = document.querySelector('#setpage .peqhd');
        const rows = document.querySelectorAll('#peqRows .peqr');
        const hdBg = hd ? getComputedStyle(hd).backgroundColor : '';
        const r0Bg = rows[0] ? getComputedStyle(rows[0]).backgroundColor : '';
        const r1Bg = rows[1] ? getComputedStyle(rows[1]).backgroundColor : '';
        return {
          hdBg,
          r0Bg,
          r1Bg,
          rowCount: rows.length
        };
      })()`);

      const pHd = parseColor(styles.hdBg);
      const pR0 = parseColor(styles.r0Bg);
      const pR1 = parseColor(styles.r1Bg);

      check(pHd && pHd.a === 1, `[theme=${theme}] peqhd background alpha == 1`, { bg: styles.hdBg, parsed: pHd });
      check(pR0 && pR0.a === 1, `[theme=${theme}] peqr(even) background alpha == 1`, { bg: styles.r0Bg, parsed: pR0 });
      check(pR1 && pR1.a === 1, `[theme=${theme}] peqr(odd) background alpha == 1`, { bg: styles.r1Bg, parsed: pR1 });

      check(styles.hdBg !== styles.r0Bg, `[theme=${theme}] peqhd != peqr(even)`, { hd: styles.hdBg, r0: styles.r0Bg });
      check(styles.r0Bg !== styles.r1Bg, `[theme=${theme}] zebra pattern: peqr(even) != peqr(odd)`, { r0: styles.r0Bg, r1: styles.r1Bg });

      await s.shot(path.join(out, `peq_${theme}.png`));
    }

    // 滚动到底测试 sticky
    await s.eval(`(() => {
      const container = document.querySelector('.peqrows');
      if (container) {
        container.scrollTop = container.scrollHeight;
      }
    })()`);
    await new Promise(r => setTimeout(r, 300));

    // 验证 sticky 表头是否处于可视区域且仍在顶部
    const stickyInfo = await s.eval(`(() => {
      const container = document.querySelector('.peqrows');
      const hd = document.querySelector('#setpage .peqhd');
      const cRect = container ? container.getBoundingClientRect() : null;
      const hRect = hd ? hd.getBoundingClientRect() : null;
      const sTop = container ? container.scrollTop : 0;
      return {
        scrollTop: sTop,
        containerTop: cRect ? cRect.top : 0,
        hdTop: hRect ? hRect.top : 0,
        hdBgAlpha1: hd ? getComputedStyle(hd).backgroundColor : ''
      };
    })()`);

    const pHdSticky = parseColor(stickyInfo.hdBgAlpha1);
    check(stickyInfo.scrollTop > 100, 'peqrows scrolled to bottom', { scrollTop: stickyInfo.scrollTop });
    check(Math.abs(stickyInfo.hdTop - stickyInfo.containerTop) <= 2, 'peqhd stays sticky at container top', { hdTop: stickyInfo.hdTop, containerTop: stickyInfo.containerTop });
    check(pHdSticky && pHdSticky.a === 1, 'sticky peqhd background is opaque (alpha == 1)', { bg: stickyInfo.hdBgAlpha1, parsed: pHdSticky });

    await s.shot(path.join(out, 'peq_scrolled_bottom.png'));

  } catch (err) {
    check(false, 'script execution', { error: err.message, stack: err.stack });
  } finally {
    if (s) await s.close();
  }

  console.log(`\nTOTAL FAILURES: ${failures}`);
  process.exit(failures > 0 ? 1 : 0);
})();
