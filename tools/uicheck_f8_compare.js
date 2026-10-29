// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');
const base = (process.argv[2] || 'http://127.0.0.1:19093').replace(/\/$/, '');
const fixture = process.argv[3] || '/tmp/rlplayer-f8-green';
const out = process.argv[4] || '/tmp/rlplayer-f8-ui';
fs.mkdirSync(out, { recursive: true });
const lines = []; let fails = 0;
function ck(ok, label, detail) {
  const line = `${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(detail)}`;
  lines.push(line); console.log(line); if (!ok) fails++;
}
(async () => {
  let s;
  try {
    s = await ub.open({url: base, width: 1400, height: 900});
    if (!await s.waitFor('window.S && typeof openCompareModal === "function"', 15000)) throw new Error('page not ready');
    const wav = path.join(fixture, '原版.wav');
    await s.eval(`openCompareModal(${JSON.stringify(wav)})`);
    const listed = await s.waitFor('document.querySelectorAll("#mbody .cmpck").length >= 2', 8000);
    const checks = await s.eval(`({
      count: document.querySelectorAll('#mbody .cmpck').length,
      firstChecked: document.querySelectorAll('#mbody .cmpck')[0].checked,
      go: !!document.getElementById('cmpGo')
    })`);
    ck(listed && checks.count >= 2 && checks.go, 'compare modal lists versions and exposes run button', checks);
    ck(checks.firstChecked === true, 'current file is preselected', checks);
    // 判据必须先真的勾上第二个版本，否则界面按设计拒绝（少于 2 个）——
    // 这一条是判据自己的缺陷，不是产品缺陷（首版漏勾导致假红，已修正）。
    await s.eval(`(function(){
      var c = document.querySelectorAll('#mbody .cmpck')[1];
      c.checked = true; c.dispatchEvent(new Event('change', {bubbles:true}));
      return c.checked;
    })()`);
    const picked = await s.eval('CMP.files.filter(function(f){return f.on;}).length');
    ck(picked === 2, 'second version checked before running', {picked:picked});
    await s.eval('document.getElementById("cmpGo").click()');
    const done = await s.waitFor('document.querySelector("#cmpOut table") || /对比失败/.test((document.getElementById("cmpMsg")||{}).textContent||"")', 30000);
    const rendered = await s.eval(`({
      hasTable: !!document.querySelector('#cmpOut table'),
      rows: document.querySelectorAll('#cmpOut tbody tr').length,
      ranking: document.querySelectorAll('#cmpOut ol li').length,
      text: (document.getElementById('cmpOut')||{}).innerText || ''
    })`);
    ck(done && rendered.hasTable && rendered.rows >= 10, 'rendered metric table from real analysis', {rows: rendered.rows, ranking: rendered.ranking});
    ck(rendered.ranking === 2, 'ranking shows both versions', {ranking: rendered.ranking});
    ck(/排序（好 → 差）/.test(rendered.text) && /分/.test(rendered.text), 'explanation and scores visible', rendered.text.slice(0, 120));
    await s.shot(path.join(out, 'compare.png'));
    ck(s.errors.length === 0, 'no renderer exceptions', s.errors);
  } catch (e) { ck(false, 'execution', String(e.stack || e)); }
  finally {
    if (s) { try { await s.close(); } catch (e) { ck(false, 'browser graceful cleanup', String(e)); } }
    fs.writeFileSync(path.join(out, 'result.txt'), lines.join('\n') + '\n');
  }
  process.exitCode = fails ? 1 : 0;
})();
