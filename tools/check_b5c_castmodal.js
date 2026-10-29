// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_b5c_castmodal.js — B-5 追加判据：**弹窗必须先出现，再扫描**（2026-10-28 用户实测）
//
// 用户原话：「点推送到设备也没有弹窗」「我怀疑他找设备找太久了，应该先出弹窗，然后找设备」。
//
// 为什么这样判（铁律 3）：
//   只断言「点了之后弹窗存在」是**证明不了时序**的 —— 扫描完成后才弹也能过。
//   所以这里把 /api/cast/devices 拦成一个**永不返回**的 Promise：
//     * 旧实现（先扫后弹）⟹ 弹窗永远不出现 ⟹ 这条必红；
//     * 新实现（先弹后扫）⟹ 弹窗立刻出现且显示「正在搜索」⟹ 这条必绿。
//   再把 Promise 放开（返回 2 台设备），断言列表被填进**同一个**弹窗里。
//
// 铁律 1：不开任何音频设备（纯 DOM + fetch 拦截）。
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
  lines.push(line);
  console.log(line);
  if (!ok) failures++;
}

(async () => {
  let s;
  try {
    s = await ub.open({ url: base, width: 1400, height: 900 });
    await s.waitFor('window.S && typeof npPickCastDevice === "function"', 20000);

    // 装一个可手动放行的 /api/cast/devices 桩：默认永不 resolve
    await s.eval(`(function(){
      var orig = window.fetch;
      window.__castResolve = null;
      window.__castHits = 0;
      window.fetch = function(url, opt){
        if (typeof url === 'string' && url.indexOf('/api/cast/devices') !== -1) {
          window.__castHits++;
          return new Promise(function(res){
            window.__castResolve = function(payload){
              res(new Response(JSON.stringify(payload), {status:200, headers:{'Content-Type':'application/json'}}));
            };
          });
        }
        return orig.apply(this, arguments);
      };
      return true;
    })()`);

    // 触发推送（等价用户点「推送到设备」）
    await s.eval(`(function(){ window.__picked = 'none'; npPickCastDevice(function(v){ window.__picked = v; }); })()`);
    // 只等很短的时间：此时扫描肯定还没返回
    await ub.sleep(350);

    const early = await s.eval(`(function(){
      var m = document.getElementById('modal');
      var on = !!(m && m.classList.contains('on'));
      var body = (document.getElementById('mbody') || {}).textContent || '';
      var title = (document.getElementById('mtitle') || {}).textContent || '';
      return { open: on, title: title, bodyHead: body.slice(0, 60),
               hits: window.__castHits, hasRescan: !!document.getElementById('castRescan') };
    })()`);
    check(early.hits >= 1, '确实发起了设备扫描（不是根本没调用）', early);
    check(early.open === true, '扫描未返回时弹窗**已经打开**（先弹窗、后扫描）', early);
    check(/推送到设备/.test(early.title), '弹窗标题正确', early.title);
    check(/正在搜索/.test(early.bodyHead), '弹窗内有「正在搜索」占位，不是空白', early.bodyHead);
    check(early.hasRescan === true, '弹窗内提供「重新搜索」按钮', early);

    // 放行扫描结果：2 台设备
    await s.eval(`(function(){
      if (window.__castResolve) window.__castResolve({ok:true,n:2,devices:[
        {friendlyName:'客厅音箱 A1', model:'Mock-A', host:'192.168.1.11', location:'http://192.168.1.11:49152/desc.xml'},
        {friendlyName:'书房数播 B2', model:'Mock-B', host:'192.168.1.12', location:'http://192.168.1.12:49152/desc.xml'}
      ]});
      return true;
    })()`);
    await ub.sleep(600);

    const late = await s.eval(`(function(){
      var m = document.getElementById('modal');
      var rows = [].slice.call(document.querySelectorAll('#mbody .castpick-row')).map(function(b){ return b.textContent.trim(); });
      return { stillOpen: !!(m && m.classList.contains('on')), rows: rows };
    })()`);
    check(late.stillOpen === true, '扫描返回后弹窗仍然开着（没有被关掉重开）', late);
    check(late.rows.length === 2, '两台设备被填进同一个弹窗', late.rows);

    // 点击第二台 → 回调必须拿到它（证明列表可点、回传正确）
    await s.eval(`(function(){
      var b = document.querySelectorAll('#mbody .castpick-row')[1];
      if (b) b.click();
      return true;
    })()`);
    await ub.sleep(200);
    const picked = await s.eval(`window.__picked`);
    check(/192\.168\.1\.12/.test(String(picked)), '点第二台后回调拿到的是它（不是第一台/空）', picked);

    await s.shot(path.join(out, 'cast_modal_first.png'));
    check(s.errors.length === 0, '无渲染端异常', s.errors);
  } catch (e) {
    check(false, 'execution', String(e.stack || e));
  } finally {
    if (s) { try { await s.close(); } catch (e) { check(false, 'browser cleanup', String(e)); } }
    fs.writeFileSync(path.join(out, 'result_b5c.txt'), lines.join('\n') + '\n');
  }
  process.exitCode = failures ? 1 : 0;
})();
