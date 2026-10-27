// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
// 验收判据：顺序播放图标（三横线+箭头）在 17px 栅格化下与列表循环、单曲循环、随机播放视觉可区分
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');

const base = (process.argv[2] || 'http://127.0.0.1:19101').replace(/\/$/, '');
const out = process.argv[3] || '/tmp/rlw/i1/evidence';
fs.mkdirSync(out, { recursive: true });

const lines = [];
let failures = 0;

function check(ok, label, detail) {
  const line = `${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(detail)}`;
  lines.push(line);
  console.log(line);
  if (!ok) failures++;
}

async function api(p, body) {
  const r = await fetch(base + p, body === undefined ? {} : {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  return r.json();
}

(async () => {
  let s;
  try {
    const settings = await api('/api/settings');
    if (!settings.kv || settings.kv.backend !== 'null') {
      throw new Error('test requires backend=null');
    }

    s = await ub.open({ url: base, width: 1400, height: 900 });
    if (!await s.waitFor('window.S && typeof loadQ === "function" && typeof REP_ICON !== "undefined"', 15000)) {
      throw new Error('page not ready');
    }

    // 1. DOM 结构检查
    const domCheck = await s.eval(`(function() {
      var d = document.createElement('div');
      d.innerHTML = '<svg>' + REP_ICON[0] + '</svg>';
      var paths = d.querySelectorAll('path');
      var pathCount = paths.length;
      var d0 = REP_ICON[0];
      var d1 = REP_ICON[1];
      return {
        pathCount: pathCount,
        notEqualToListCycle: d0 !== d1,
        rep0: d0
      };
    })()`);

    check(
      domCheck.pathCount >= 2,
      'dom_path_count_gte_2',
      { pathCount: domCheck.pathCount, rep0: domCheck.rep0 }
    );
    check(
      domCheck.notEqualToListCycle,
      'dom_not_equal_to_list_cycle',
      { notEqual: domCheck.notEqualToListCycle }
    );

    // 2. 17px 视觉可区分（核心判据）
    // 渲染方法说明：
    // - 将 #bRep 容器在页面内调整到固定的 17x17 CSS 像素容器中（背景纯黑，文字/笔画纯白 #fff）。
    // - 分别对 4 种播放模式整个按钮（svg + repOne 角标）与纯 svg 通过 CDP Page.captureScreenshot(clip) 截取 17x17 png。
    // - 载入 canvas 读取真实渲染出来的 getImageData 像素。
    // 像素比较口径说明：
    // - 非透明像素位图集合：亮度 > 30 视为前景笔画，排除背景和轻微抗锯齿底噪。
    // - 允许 1px 邻域容差：若点 (x,y) 在图 A 存在，但在图 B 对应位置及其 8 邻域（±1px）内均不存在，则记为显著结构性差异点。
    // - 计算图 A 与图 B 互为孤立点的总差异点数 diff_pixels。
    // - 断言模式 0 vs 1、0 vs 2、0 vs 3 以及纯 svg 0 vs 1 的 diff_pixels > 0。
    const setupBox = await s.eval(`(function() {
      var box = document.getElementById('__test_box_17');
      if (!box) {
        box = document.createElement('div');
        box.id = '__test_box_17';
        box.style.position = 'fixed';
        box.style.top = '10px';
        box.style.left = '10px';
        box.style.width = '17px';
        box.style.height = '17px';
        box.style.zIndex = '999999';
        box.style.background = '#000000';
        box.style.color = '#ffffff';
        box.style.overflow = 'hidden';
        box.style.display = 'flex';
        box.style.alignItems = 'center';
        box.style.justifyContent = 'center';
        document.body.appendChild(box);
      }
      var r = box.getBoundingClientRect();
      return { x: r.x, y: r.y, width: r.width, height: r.height };
    })()`);

    const shotsData = {};
    for (let v = 0; v < 4; v++) {
      // (a) 整个按钮（svg + 角标）
      await s.eval(`(function() {
        var box = document.getElementById('__test_box_17');
        var svgHtml = '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2">' + REP_ICON[${v}] + '</svg>';
        var oneSpan = (${v} === 2) ? '<span style="position:absolute;font-size:9px;font-weight:700;color:#fff;bottom:0;right:0;line-height:1;">1</span>' : '';
        box.innerHTML = '<div style="position:relative;width:17px;height:17px;display:flex;align-items:center;justify-content:center;">' + svgHtml + oneSpan + '</div>';
      })()`);
      await ub.sleep(50);
      const wholeShot = await s.send('Page.captureScreenshot', {
        format: 'png',
        clip: { x: setupBox.x, y: setupBox.y, width: setupBox.width, height: setupBox.height, scale: 1 }
      });
      shotsData[`whole_${v}`] = wholeShot.data;
      fs.writeFileSync(path.join(out, `btn_mode_${v}_17px.png`), Buffer.from(wholeShot.data, 'base64'));

      // (b) 纯 svg
      await s.eval(`(function() {
        var box = document.getElementById('__test_box_17');
        box.innerHTML = '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2">' + REP_ICON[${v}] + '</svg>';
      })()`);
      await ub.sleep(50);
      const svgShot = await s.send('Page.captureScreenshot', {
        format: 'png',
        clip: { x: setupBox.x, y: setupBox.y, width: setupBox.width, height: setupBox.height, scale: 1 }
      });
      shotsData[`svg_${v}`] = svgShot.data;
      fs.writeFileSync(path.join(out, `svg_mode_${v}_17px.png`), Buffer.from(svgShot.data, 'base64'));
    }

    // 在页面中比对像素
    const pixelDiffs = await s.eval(`(async function() {
      var shots = ${JSON.stringify(shotsData)};
      function decodeShot(b64) {
        return new Promise(function(resolve) {
          var img = new Image();
          img.onload = function() {
            var c = document.createElement('canvas');
            c.width = 17; c.height = 17;
            var ctx = c.getContext('2d');
            ctx.drawImage(img, 0, 0);
            var idata = ctx.getImageData(0, 0, 17, 17);
            var activeSet = {};
            for (var y = 0; y < 17; y++) {
              for (var x = 0; x < 17; x++) {
                var idx = (y * 17 + x) * 4;
                // 取灰度亮度
                var lum = (idata.data[idx] + idata.data[idx+1] + idata.data[idx+2]) / 3;
                if (lum > 30) {
                  activeSet[x + ',' + y] = lum;
                }
              }
            }
            resolve(activeSet);
          };
          img.src = 'data:image/png;base64,' + b64;
        });
      }

      function compareSets(setA, setB) {
        var diffA = 0;
        for (var k in setA) {
          var p = k.split(',');
          var x = parseInt(p[0], 10);
          var y = parseInt(p[1], 10);
          var match = false;
          for (var dx = -1; dx <= 1; dx++) {
            for (var dy = -1; dy <= 1; dy++) {
              if (setB[(x + dx) + ',' + (y + dy)] !== undefined) {
                match = true; break;
              }
            }
            if (match) break;
          }
          if (!match) diffA++;
        }
        var diffB = 0;
        for (var k2 in setB) {
          var p2 = k2.split(',');
          var x2 = parseInt(p2[0], 10);
          var y2 = parseInt(p2[1], 10);
          var match2 = false;
          for (var dx2 = -1; dx2 <= 1; dx2++) {
            for (var dy2 = -1; dy2 <= 1; dy2++) {
              if (setA[(x2 + dx2) + ',' + (y2 + dy2)] !== undefined) {
                match2 = true; break;
              }
            }
            if (match2) break;
          }
          if (!match2) diffB++;
        }
        return diffA + diffB;
      }

      var w0 = await decodeShot(shots['whole_0']);
      var w1 = await decodeShot(shots['whole_1']);
      var w2 = await decodeShot(shots['whole_2']);
      var w3 = await decodeShot(shots['whole_3']);
      var s0 = await decodeShot(shots['svg_0']);
      var s1 = await decodeShot(shots['svg_1']);

      return {
        diff0vs1: compareSets(w0, w1),
        diff0vs2: compareSets(w0, w2),
        diff0vs3: compareSets(w0, w3),
        diffSvg0vs1: compareSets(s0, s1),
        count0: Object.keys(w0).length,
        count1: Object.keys(w1).length
      };
    })()`);

    check(pixelDiffs.diff0vs1 > 0, '17px_distinguishable_0_vs_1', { diff: pixelDiffs.diff0vs1, count0: pixelDiffs.count0, count1: pixelDiffs.count1 });
    check(pixelDiffs.diff0vs2 > 0, '17px_distinguishable_0_vs_2', { diff: pixelDiffs.diff0vs2 });
    check(pixelDiffs.diff0vs3 > 0, '17px_distinguishable_0_vs_3', { diff: pixelDiffs.diff0vs3 });
    check(pixelDiffs.diffSvg0vs1 > 0, '17px_distinguishable_svg_only_0_vs_1', { diff: pixelDiffs.diffSvg0vs1 });

    // 清理测试 div
    await s.eval(`(function(){
      var b = document.getElementById('__test_box_17');
      if (b) b.remove();
    })()`);

    // 3. 回归测试：连点四次 #bRep
    await api('/api/playmode?mode=0', '');
    await s.eval('loadQ()');
    const seen = [];
    const arias = [];
    for (let i = 0; i < 4; i++) {
      const pt = await s.eval(`(function(){
        var r = D('bRep').getBoundingClientRect();
        return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
      })()`);
      await s.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pt.x, y: pt.y, button: 'left', clickCount: 1 });
      await s.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pt.x, y: pt.y, button: 'left', clickCount: 1 });
      await ub.sleep(150);
      await s.eval('loadQ()');
      const ui = await s.eval(`({
        mode: +D('sRep').value,
        label: D('bRep').getAttribute('aria-label')
      })`);
      const server = await api('/api/playmode');
      seen.push(ui.mode);
      arias.push(ui.label);
      check(
        server.mode === (i + 1) % 4 && ui.mode === server.mode,
        `click_${i + 1}_cycle`,
        { step: i + 1, ui: ui.mode, server: server.mode, label: ui.label }
      );
    }
    check(
      JSON.stringify(seen) === '[1,2,3,0]',
      'four_state_full_cycle',
      seen
    );

    // 验证 aria-label 随模式变化且含有相应关键字
    const expectedLabels = [
      /列表循环/, // 0 -> 1
      /单曲循环/, // 1 -> 2
      /随机/,     // 2 -> 3
      /顺序播放/  // 3 -> 0
    ];
    let ariasMatch = true;
    for (let j = 0; j < 4; j++) {
      if (!expectedLabels[j].test(arias[j])) {
        ariasMatch = false;
        break;
      }
    }
    check(ariasMatch, 'aria_labels_match_each_mode', arias);

    // 截图全页存档
    await s.shot(path.join(out, 'screenshot_playmode.png'));
    check(s.errors.length === 0, 'no_renderer_exceptions', s.errors);

  } catch (e) {
    check(false, 'execution_error', String(e.stack || e));
  } finally {
    if (s) {
      try { await s.close(); } catch (e) { check(false, 'browser_graceful_cleanup', String(e)); }
    }
    await api('/api/playmode?mode=0', '').catch(() => {});
    fs.writeFileSync(path.join(out, 'result.txt'), lines.join('\n') + '\n');
  }
  process.exitCode = failures ? 1 : 0;
})();
