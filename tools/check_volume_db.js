// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_volume_db.js — 1.1.0「音量 dB 设计对齐主流播放器」的 CDP 验收（无声：backend=null）
//
// 判据（每条都要能证明它要证明的事）：
//   A 固定档位     连按 4 次 ↓（0.5 dB）⟹ 每次都恰好 −0.5，且落点都在 0.5 dB 栅格上
//   B 静音逃逸     拖到最左（静音）后按 ↑ ⟹ 直接到 −55.0 dB（最低可闻档），条子离开静音档
//   C 静音向下     静音态按 ↓ ⟹ 仍是静音（不产生"比静音更小"的无意义状态）
//   D 顶端夹紧     0 dB 按 ↑ ⟹ 仍 0 dB（不允许正向增益，>0 dB 必削波）
//   E 细档         Shift + ↓ ⟹ −0.1 dB（与标签 1 位小数同精度）
//   F 滚轮         音量条上滚轮一格 ⟹ ±0.5 dB
//   G 双击归零     任意位置双击标签 ⟹ 0 dB，且滑块在 100% 位置（bit-perfect 常用手势）
//   H 下发一致     /api/volume 实际收到的 db 与界面 S.vol 完全一致（不是只改了显示）
//   I 标签一致     #npVolLab 文本 == S.vol 的 1 位小数（静音态显示「静音」）
//   J 换算互逆     volPosToDb(volDbToPos(x)) == x 对 0 / −0.5 … −55 全档位成立
//
// 用法：node tools/check_volume_db.js [base] [outDir] [--red]
//   --red：在页面上跑**旧实现**的公式（位置步进 2.5%），必须测出"步进大小随位置漂移"的红。
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');

const base = (process.argv[2] || 'http://127.0.0.1:19099').replace(/\/$/, '');
const out = process.argv[3] || 'debug/20261028-04-音量dB/shots';
const RED = process.argv.includes('--red');
fs.mkdirSync(out, { recursive: true });

const sleep = ub.sleep;
const lines = [];
let failures = 0;
function check(ok, label, detail) {
  const line = `${ok ? 'PASS' : 'FAIL'} ${label}: ${JSON.stringify(detail)}`;
  lines.push(line);
  console.log(line);
  if (!ok) failures++;
  return ok;
}
async function api(p) { const r = await fetch(base + p); return r.json(); }

(async () => {
  let s = null;
  try {
    const st = await api('/api/settings');
    if (!st.kv || st.kv.backend !== 'null') {
      throw new Error('测试实例必须是 backend=null（不出声），当前 = ' + JSON.stringify(st.kv && st.kv.backend));
    }

    s = await ub.open({ url: base, width: 1400, height: 900 });
    if (!await s.waitFor('window.S && typeof volNudge === "function" && !!D("npVol")', 20000)) {
      throw new Error('页面没就绪（volNudge / npVol 未就位）');
    }
    await sleep(500);

    // 计数桩：记录每次 /api/volume 的 db 参数（验证"界面值 = 下发值"）
    await s.eval(`(function(){
      if (window.__volCalls === undefined) {
        window.__volCalls = 0; window.__lastVolDb = null;
        var of = window.fetch;
        window.fetch = function (u, o) {
          var uu = String((u && u.url) ? u.url : u);
          var m = uu.match(/[?&]db=(-?[0-9.]+)/);
          if (uu.indexOf('/api/volume') >= 0 && m) { window.__volCalls++; window.__lastVolDb = parseFloat(m[1]); }
          return of.apply(this, arguments);
        };
      }
      return 1;
    })()`);

    const st0 = () => s.eval(`(function(){return {
      vol: S.vol, pos: parseFloat(D('vol').value), npos: parseFloat(D('npVol').value),
      lab: D('npVolLab') ? D('npVolLab').textContent : '',
      calls: window.__volCalls || 0, lastDb: window.__lastVolDb };})()`);
    const key = async (k, vk, shift) => {
      const mod = shift ? 8 : 0;
      await s.send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code: k, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers: mod });
      await s.send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code: k, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers: mod });
      await sleep(90);
    };
    const setVolExpr = (db) => s.eval('setVol(' + db + '); 1');

    // ---------- A 固定档位 ----------
    await setVolExpr(0);
    await sleep(120);
    const steps = [];
    for (let i = 0; i < 4; i++) { await key('ArrowDown', 40); steps.push((await st0()).vol); }
    const onGrid = steps.every((v) => Math.abs(v / 0.5 - Math.round(v / 0.5)) < 1e-9);
    const evenStep = steps.every((v, i) => Math.abs(v - (-0.5 * (i + 1))) < 1e-9);
    check(onGrid && evenStep, 'A 连按 4 次 ↓ 每次恰好 −0.5 dB 且都在 0.5 栅格', steps);

    // ---------- B 静音逃逸 ----------
    await setVolExpr(-120);
    await sleep(120);
    const b0 = await st0();
    await key('ArrowUp', 38);
    const b1 = await st0();
    check(Math.abs(b0.vol - (-120)) < 1e-6 && Math.abs(b1.vol - (-54.5)) < 1e-6 && b1.pos > 5,
      'B 静音态按 ↑ 直接到最低可闻档 −54.5 dB（条子离开静音区）', { before: b0.vol, after: b1.vol, pos: b1.pos });

    // ---------- K 最低可闻档真的可设（不是被 volNormalize 收回静音的空值） ----------
    const k1 = await s.eval(`(function(){ var v = volNormalize(VOL_AUDIBLE_DB);
      return { want: VOL_AUDIBLE_DB, got: v, pos: volDbToPos(VOL_AUDIBLE_DB), silentPos: VOL_SILENT_POS }; })()`);
    check(Math.abs(k1.got - k1.want) < 1e-9 && k1.pos > k1.silentPos,
      'K 最低可闻档 −54.5 dB 不在静音区（位置 > 静音阈值）', k1);

    // ---------- C 曲线底 → 静音；静音再 ↓ 仍静音 ----------
    await key('ArrowDown', 40);
    const c1 = await st0();
    await key('ArrowDown', 40);
    const c2 = await st0();
    check(Math.abs(c1.vol - (-120)) < 1e-6 && Math.abs(c2.vol - (-120)) < 1e-6,
      'C −55 再 ↓ 落静音；静音再 ↓ 仍静音（不产生"比静音更小"的状态）', { at55_down: c1.vol, mute_down: c2.vol });

    // ---------- D 顶端夹紧 ----------
    await setVolExpr(0);
    await sleep(100);
    const dBefore = (await st0()).calls;
    await key('ArrowUp', 38); await key('ArrowUp', 38); await key('ArrowUp', 38);
    const d1 = await st0();
    check(Math.abs(d1.vol) < 1e-9 && d1.calls === dBefore,
      'D 0 dB 再按 ↑ 不越界、也不发无意义请求', { vol: d1.vol, newCalls: d1.calls - dBefore });

    // ---------- E 细档 ----------
    await setVolExpr(0);
    await sleep(100);
    await key('ArrowDown', 40, true);
    const e1 = await st0();
    check(Math.abs(e1.vol - (-0.1)) < 1e-9, 'E Shift+↓ = −0.1 dB（细档）', { vol: e1.vol, lab: e1.lab });

    // ---------- F 滚轮 ----------
    await setVolExpr(-20);
    await sleep(120);
    const fr = await s.eval(`(function(){var r=D('vol').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2};})()`);
    await s.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: Math.round(fr.x), y: Math.round(fr.y), deltaX: 0, deltaY: -120, buttons: 0 });
    await sleep(150);
    const f1 = await st0();
    check(Math.abs(f1.vol - (-19.5)) < 1e-9, 'F 音量条滚轮一格 = +0.5 dB', { from: -20, to: f1.vol });

    // ---------- G 双击标签归零（标签在单曲页里，先把页面打开） ----------
    await s.eval('openNowPlaying()');
    await sleep(500);
    const lr = await s.eval(`(function(){var r=D('npVolLab').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2,w:r.width,h:r.height};})()`);
    check(lr.w > 10, 'G 前提：单曲页已打开、dB 标签可见', { w: Math.round(lr.w) });
    await s.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: Math.round(lr.x), y: Math.round(lr.y), button: 'left', buttons: 1, clickCount: 1 });
    await s.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: Math.round(lr.x), y: Math.round(lr.y), button: 'left', buttons: 0, clickCount: 1 });
    await s.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: Math.round(lr.x), y: Math.round(lr.y), button: 'left', buttons: 1, clickCount: 2 });
    await s.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: Math.round(lr.x), y: Math.round(lr.y), button: 'left', buttons: 0, clickCount: 2 });
    await sleep(220);
    const g1 = await st0();
    check(Math.abs(g1.vol) < 1e-9 && Math.round(g1.pos) === 1000,
      'G 双击 dB 标签 ⟹ 回 0 dB 且滑块到 100%', { vol: g1.vol, pos: g1.pos, lab: g1.lab });

    // ---------- H 下发一致 ----------
    await setVolExpr(-12.5);
    await sleep(350);
    const h1 = await st0();
    check(Math.abs(h1.lastDb - (-12.5)) < 1e-9 && h1.calls > 0,
      'H 后端收到的 db == 界面值（不是只改显示）', { lastDb: h1.lastDb, vol: h1.vol });

    // ---------- I 标签一致 ----------
    const labOk = Math.abs(parseFloat(String(h1.lab).replace(' dB', '')) - (-12.5)) < 1e-6;
    await setVolExpr(-120);
    await sleep(150);
    const i2 = await st0();
    check(labOk && /静音/.test(i2.lab), 'I 标签 = 1 位小数 dB；静音态显示「静音」', { at12_5: h1.lab, silent: i2.lab });

    // ---------- J 换算互逆（全档位） ----------
    const rt = await s.eval(`(function(){
      var bad = [], below = [];
      for (var db = 0; db >= VOL_AUDIBLE_DB; db -= 0.5) {
        var d = Math.round(db * 10) / 10;
        var back = volPosToDb(volDbToPos(d));
        if (Math.abs(back - d) > 0.05) bad.push([d, +back.toFixed(3)]);
      }
      for (var e = VOL_AUDIBLE_DB - 0.5; e >= -80; e -= 0.5) {
        var v = volNormalize(Math.round(e * 10) / 10);
        if (v !== -120) below.push([+e.toFixed(1), v]);
      }
      return { bad: bad.slice(0, 5), n: bad.length, below: below.slice(0, 5), nb: below.length };
    })()`);
    check(rt.n === 0 && rt.nb === 0, 'J 可闻档往返一致（0 … −54.5）；更低的档位统一收成静音', rt);

    // ---------- 红：旧实现（位置步进 2.5%）必然不满足 A/B ----------
    if (RED) {
      const red = await s.eval(`(function(){
        var out = {};
        setVol(0);
        var v0 = S.vol;
        setVol(volPosToDb(volDbToPos(S.vol) - 25));      // 旧实现：↓ 走 2.5% 行程
        out.topStep = +(S.vol - v0).toFixed(3);
        setVol(-120);
        setVol(volPosToDb(volDbToPos(S.vol) + 25));      // 旧实现：静音 ↑
        out.fromMute = +S.vol.toFixed(3);
        setVol(0);
        return out;
      })()`);
      check(!(Math.abs(red.topStep + 0.5) < 1e-6), 'RED 旧实现：顶部一步不是 −0.5 dB（判据 A 会红）', { step: red.topStep });
      check(!(Math.abs(red.fromMute + 55) < 1e-6), 'RED 旧实现：静音 ↑ 不是 −55 dB（判据 B 会红）', { fromMute: red.fromMute });
      console.log('\n' + (failures ? `RED 判据不成立 ${failures} 条` : 'RED OK：判据能区分新旧实现'));
      await s.close();
      fs.writeFileSync(path.join(out, 'report-red.txt'), lines.join('\n') + '\n');
      process.exit(failures ? 1 : 0);
    }

    await setVolExpr(-20);
    await sleep(200);
    await s.shot(path.join(out, 'volume-db.png'));
    check((s.errors || []).length === 0, '页面无 JS 异常/console.error', (s.errors || []).slice(0, 3));
  } catch (e) {
    check(false, '脚本异常', String((e && e.message) || e));
  } finally {
    if (s) { try { await s.close(); } catch (e) { console.log('关闭浏览器失败：' + e.message); } }
  }
  console.log('\n' + (failures ? `FAILED ${failures} 条` : 'ALL PASS'));
  fs.writeFileSync(path.join(out, 'report.txt'), lines.join('\n') + '\n');
  process.exit(failures ? 1 : 0);
})();
