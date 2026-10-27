// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');

const base = (process.argv[2] || 'http://127.0.0.1:19103').replace(/\/$/, '');
const out = process.argv[3] || '/tmp/rlw/i3/evidence';
fs.mkdirSync(out, { recursive: true });

const lines = [];
let failures = 0;

function check(ok, label, detail) {
  const line = `${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(detail)}`;
  lines.push(line);
  console.log(line);
  if (!ok) failures++;
}

(async () => {
  let s;
  try {
    // 3. /api/roomcorr/layouts 仍返回 200 且是 JSON（后端没被删）
    const r = await fetch(base + '/api/roomcorr/layouts');
    check(r.status === 200, 'backend /api/roomcorr/layouts status 200', { status: r.status });
    let j = null;
    try { j = await r.json(); } catch (e) { }
    check(j && Array.isArray(j.layouts) && j.layouts.length >= 6, 'backend /api/roomcorr/layouts valid JSON layouts', j);

    s = await ub.open({ url: base, width: 1400, height: 900 });
    const ready = await s.waitFor('window.S && typeof loadQ === "function"', 15000);
    if (!ready) throw new Error('page not ready');

    // 切换到「声音校准」页签
    await s.eval(`(function(){
      if (typeof openSettingsTab === 'function') {
        openSettingsTab('cal');
      } else {
        var n = document.querySelector('.nav[data-v=settings]');
        if (n) n.click();
        var t = document.querySelector('#setpage .stab[data-g=cal]');
        if (t) t.click();
      }
    })()`);
    await ub.sleep(600);

    // 1. #bRoomWiz 不可见：offsetParent === null 或 getComputedStyle(el).display === 'none'
    const wizState = await s.eval(`(function(){
      var el = document.getElementById('bRoomWiz');
      if (!el) return { exists: false };
      var cs = window.getComputedStyle(el);
      return {
        exists: true,
        offsetParentIsNull: el.offsetParent === null,
        displayNone: cs.display === 'none',
        visibility: cs.visibility,
        computedDisplay: cs.display
      };
    })()`);
    const wizHidden = wizState.exists && (wizState.offsetParentIsNull || wizState.displayNone);
    check(wizHidden, 'wizard button #bRoomWiz is hidden', wizState);

    // 4. 提示文案存在：页面上能找到含「房间测量正在重做」的可见文本
    const hintState = await s.eval(`(function(){
      var pane = document.querySelector('.spane[data-g=cal]');
      if (!pane) return { found: false, text: '' };
      var walker = document.createTreeWalker(pane, NodeFilter.SHOW_TEXT, null, false);
      var node;
      var matches = [];
      while (node = walker.nextNode()) {
        if (node.nodeValue && node.nodeValue.indexOf('房间测量正在重做') !== -1) {
          var p = node.parentElement;
          var cs = window.getComputedStyle(p);
          matches.push({
            text: node.nodeValue.trim(),
            visible: p.offsetParent !== null && cs.display !== 'none' && cs.visibility !== 'hidden'
          });
        }
      }
      return {
        found: matches.length > 0,
        matches: matches
      };
    })()`);
    check(hintState.found && hintState.matches.some(m => m.visible), 'redo hint text visible', hintState);

    // 2. 「EQ 文件」「房间校正 IR」两块仍可见可用：
    // - #sp_eq 与 #sp_ir 两个 input 存在、offsetParent !== null、且 disabled === false
    // - 真做一次输入：往 #sp_eq 里填一个路径并触发 input/change，断言值确实进去了
    const eqIrState = await s.eval(`(function(){
      var eq = document.getElementById('sp_eq');
      var ir = document.getElementById('sp_ir');
      if (!eq || !ir) return { eqExists: !!eq, irExists: !!ir };
      var eqCs = window.getComputedStyle(eq);
      var irCs = window.getComputedStyle(ir);
      return {
        eqExists: true,
        irExists: true,
        eqVisible: eq.offsetParent !== null && eqCs.display !== 'none',
        irVisible: ir.offsetParent !== null && irCs.display !== 'none',
        eqEnabled: !eq.disabled,
        irEnabled: !ir.disabled
      };
    })()`);
    check(
      eqIrState.eqExists && eqIrState.irExists &&
      eqIrState.eqVisible && eqIrState.irVisible &&
      eqIrState.eqEnabled && eqIrState.irEnabled,
      'EQ and IR inputs visible and enabled',
      eqIrState
    );

    // 真输入验证
    const testPath = '/tmp/test_headphone_eq.txt';
    const inputResult = await s.eval(`(function(val){
      var eq = document.getElementById('sp_eq');
      if (!eq) return { success: false, val: '' };
      eq.value = val;
      eq.dispatchEvent(new Event('input', { bubbles: true }));
      eq.dispatchEvent(new Event('change', { bubbles: true }));
      return { success: eq.value === val, val: eq.value };
    })(${JSON.stringify(testPath)})`);
    check(inputResult.success && inputResult.val === testPath, 'EQ input accepts value and events', inputResult);

    // 5. 截图存档
    const shotPath = path.join(out, 'roomhide_check.png');
    await s.shot(shotPath);
    check(fs.existsSync(shotPath), 'screenshot captured', { path: shotPath });

    check(s.errors.length === 0, 'no renderer exceptions', s.errors);
  } catch (e) {
    check(false, 'execution exception', String(e.stack || e));
  } finally {
    if (s) {
      try { await s.close(); } catch (e) { check(false, 'browser cleanup', String(e)); }
    }
    fs.writeFileSync(path.join(out, 'check_result.txt'), lines.join('\n') + '\n');
  }
  process.exitCode = failures ? 1 : 0;
})();
