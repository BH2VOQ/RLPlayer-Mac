// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
//
// check_b5b_castui.js — B-5 追加两条 UI 判据（2026-10-28 用户实测反馈）
//   ① 推送到设备的弹窗层级必须最高：单曲页（#npPage, z-index 70）打开时，弹窗也必须盖住它。
//      判据不能只看 CSS 字符串——要用 getComputedStyle 取真实 z-index 并比较，
//      再用 elementFromPoint 证明弹窗中心确实是最顶层元素（能点到弹窗而不是被单曲页吃掉）。
//   ② 点「停止投放」后不得再弹「开始播放」：该 toast 由 playPath() 无条件触发，
//      而 castStop() 内部正是调 playPath() 恢复本地播放 ⟹ 用户看到的操作结果是错的。
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');

const base = (process.argv[2] || 'http://127.0.0.1:19105').replace(/\/$/, '');
const out = process.argv[3] || path.join(__dirname, '..', 'debug', '20261027-04-实测反馈7条', 'b5-castpick');
fs.mkdirSync(out, { recursive: true });
const lines = [];
let failures = 0;
function check(ok, label, detail) {
  const line = `${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(detail)}`;
  lines.push(line); console.log(line); if (!ok) failures++;
}

(async () => {
  let s;
  try {
    s = await ub.open({ url: base, width: 1400, height: 900 });
    await s.waitFor('window.S && typeof renderNp === "function"', 20000);

    // ---------- ① 单曲页打开时，弹窗层级必须压住它 ----------
    await s.eval(`openNowPlaying(); renderNp();`);
    await ub.sleep(400);
    const z = await s.eval(`(function(){
      var np = document.getElementById('npPage');
      var m = document.getElementById('modal');
      if (!np || !m) return { npExists: !!np, mExists: !!m };
      m.classList.add('on');
      document.getElementById('mtitle').textContent = '层级探针';
      document.getElementById('mbody').innerHTML = '<div id=zprobe style="height:60px">probe</div>';
      var znp = parseInt(getComputedStyle(np).zIndex, 10) || 0;
      var zm = parseInt(getComputedStyle(m).zIndex, 10) || 0;
      var npVis = getComputedStyle(np).display !== 'none';
      // 弹窗中心的真实最顶层元素
      var card = m.querySelector('.mcard').getBoundingClientRect();
      var top = document.elementFromPoint(card.left + card.width/2, card.top + 10);
      var insideModal = !!(top && m.contains(top));
      var r = { npZ: znp, modalZ: zm, npVisible: npVis, topInsideModal: insideModal,
                topTag: top ? (top.tagName + (top.id ? '#' + top.id : '')) : null };
      m.classList.remove('on');
      return r;
    })()`);
    check(z.npVisible === true, '前置：单曲页确实处于可见状态（否则这条判据没意义）', z);
    check(z.modalZ > z.npZ, '弹窗 z-index 必须高于单曲页（modal > npPage）', { modalZ: z.modalZ, npZ: z.npZ });
    check(z.topInsideModal === true, '单曲页打开时弹窗中心点的最顶层元素属于弹窗（真能点到）', z);

    // ---------- ② 停止投放后不得弹「开始播放」 ----------
    const toastSeq = await s.eval(`(function(){
      var seen = [];
      var el = D('toast');
      var mo = new MutationObserver(function(){ if (el && el.textContent) seen.push(el.textContent); });
      if (el) mo.observe(el, {childList:true, characterData:true, subtree:true});
      window.__toastSeen = seen;
      window.__toastMo = mo;
      return true;
    })()`);
    // 走真实 castStop 路径（后端 /api/cast/stop 会返回，然后前端恢复本地播放）
    await s.eval(`(function(){
      S.lastCur = '/tmp/b5b_probe.wav';
      CAST.prevBackend = 'null';
      window.fetch = (function(orig){
        return function(url, opt){
          if (typeof url === 'string' && url.indexOf('/api/cast/stop') !== -1) {
            return Promise.resolve(new Response('{"ok":true}', {status:200, headers:{'Content-Type':'application/json'}}));
          }
          if (typeof url === 'string' && url.indexOf('/api/play') !== -1) {
            return Promise.resolve(new Response('{"ok":true}', {status:200, headers:{'Content-Type':'application/json'}}));
          }
          return orig.apply(this, arguments);
        };
      })(window.fetch);
      castStop();
    })()`);
    await ub.sleep(900);
    const seen = await s.eval(`(function(){ if (window.__toastMo) window.__toastMo.disconnect(); return window.__toastSeen || []; })()`);
    check(seen.some(t => t.indexOf('已停止投放') !== -1), '停止投放后有「已停止投放」提示', seen);
    check(!seen.some(t => t.indexOf('开始播放') !== -1), '停止投放后不再出现「开始播放」误导提示', seen);

    await s.shot(path.join(out, 'cast_ui_layer.png'));
    check(s.errors.length === 0, '无渲染端异常', s.errors);
  } catch (e) {
    check(false, 'execution', String(e.stack || e));
  } finally {
    if (s) { try { await s.close(); } catch (e) { check(false, 'browser cleanup', String(e)); } }
    fs.writeFileSync(path.join(out, 'result_b5b.txt'), lines.join('\n') + '\n');
  }
  process.exitCode = failures ? 1 : 0;
})();
