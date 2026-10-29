// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');
const base = (process.argv[2] || 'http://127.0.0.1:19093').replace(/\/$/, '');
const out = process.argv[3] || '/tmp/rlplayer-p3-playmode';
fs.mkdirSync(out, { recursive: true });
const lines = []; let failures = 0;
function check(ok, label, detail) {
  const line = `${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(detail)}`;
  lines.push(line); console.log(line); if (!ok) failures++;
}
async function api(p, body) {
  const r = await fetch(base + p, body === undefined ? {} : {
    method: 'POST', headers: {'Content-Type':'application/x-www-form-urlencoded'}, body,
  });
  return r.json();
}
(async () => {
  let s;
  try {
    const settings = await api('/api/settings');
    if (!settings.kv || settings.kv.backend !== 'null') throw new Error('test requires backend=null');
    s = await ub.open({url: base, width: 1400, height: 900});
    if (!await s.waitFor('window.S && typeof loadQ === "function"', 15000)) throw new Error('page not ready');
    await api('/api/playmode?mode=0', '');
    await api('/api/playmode', 'mode=2');
    let state = await api('/api/playmode');
    check(state.mode === 2, 'form mode=2 reaches backend', state);
    await api('/api/playmode?mode=3', '');
    await s.eval('loadQ()');
    const random = await s.eval(`({select:D('sRep').value, label:D('bRep').getAttribute('aria-label')})`);
    check(random.select === '3' && /随机/.test(random.label || ''), 'queue polling preserves random mode', random);
    await api('/api/playmode?mode=0', ''); await s.eval('loadQ()');
    const seen = [];
    for (let i=0; i<4; i++) {
      const pt = await s.eval(`(function(){var r=D('bRep').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
      await s.send('Input.dispatchMouseEvent', {type:'mousePressed', x:pt.x, y:pt.y, button:'left',clickCount:1});
      await s.send('Input.dispatchMouseEvent', {type:'mouseReleased', x:pt.x, y:pt.y, button:'left',clickCount:1});
      await ub.sleep(150);
      await s.eval('loadQ()');
      const ui = await s.eval(`({mode:+D('sRep').value,label:D('bRep').getAttribute('aria-label'),icon:D('bRep').innerHTML})`);
      const server = await api('/api/playmode');
      seen.push(ui.mode);
      check(server.mode === (i+1)%4 && ui.mode === server.mode, `click ${i+1} survives polling`, {ui:ui.mode,server:server.mode,label:ui.label});
    }
    check(JSON.stringify(seen) === '[1,2,3,0]', 'four-state full cycle', seen);
    await s.shot(path.join(out, 'playmode.png'));
    check(s.errors.length === 0, 'no renderer exceptions', s.errors);
  } catch (e) { check(false, 'execution', String(e.stack || e)); }
  finally {
    if (s) { try { await s.close(); } catch(e) { check(false, 'browser graceful cleanup', String(e)); } }
    await api('/api/playmode?mode=0', '').catch(()=>{});
    fs.writeFileSync(path.join(out,'result.txt'), lines.join('\n')+'\n');
  }
  process.exitCode = failures ? 1 : 0;
})();
