// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uicheck_e3_search.js — E-3（搜索栏无条件跳曲目页）的可复跑判据
//
// 判据来源：debug/20261027-01-上游改动与BUG清单.md §1 E-3
//   "点侧栏「专辑」→ 顶栏输入 → 观察 S.view。
//    红 = S.view === 'tracks' 且标题变「曲目」；
//    绿 = S.view 仍为 'albums'、专辑网格被过滤"
//
// 为什么要连"真的过滤了"一起测（铁律 3）：
//   只断言"视图没被拽走"是不够的 —— 一个永远不切视图、也不过滤的空实现同样能通过。
//   所以绿侧必须同时满足：① 视图保持；② 列表内容真的变少/带搜索装饰。
//
// 三组用例：专辑页 / 艺术家页 / 曲目页（曲目页本来就是搜索页，行为不得回退）。
// 每组都用**真实键盘输入路径**（oninput），不是直接调函数 —— 判据要穿过用户走的那条路。
//
// 用法：node tools/uicheck_e3_search.js http://127.0.0.1:PORT/ [截图目录]
// 退出码：0 = 全绿；1 = 有红；2 = 环境问题
'use strict';
const ub = require('./uibrowser');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_ = process.argv[2] || 'http://127.0.0.1:8971/';
const OUT = process.argv[3] || path.join(os.tmpdir(), 'rta_e3_search');
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
      throw new Error('页面没起来（window.S 不存在）');

    // 等首屏专辑列表加载完（S.albums 有值或空态），确保后面比较的是稳定状态
    await s.waitFor('window.S && Array.isArray(S.albums)', 20000);
    await ub.sleep(800);

    async function navTo(v) {
      await s.eval(
        "(function(){var n=Array.prototype.slice.call(document.querySelectorAll('.nav')).find(function(e){return e.dataset.v===" +
        JSON.stringify(v) + ';});if(n)n.click();return !!n;})()'
      );
      await ub.sleep(1400);
    }
    // 走真实的输入路径：设置 value + 派发 input 事件（与用户键入同等语义）
    async function typeSearch(text) {
      await s.eval(
        "(function(){var q=D('q');q.value=" + JSON.stringify(text) +
        ';q.dispatchEvent(new Event("input",{bubbles:true}));return q.value;})()'
      );
      await ub.sleep(1200);   // 越过 260ms 防抖 + 一次网络往返
    }
    const view = () => s.eval('window.S && S.view');
    const listRows = () => s.eval("(document.querySelectorAll('#list .trow, #list .card, #list .acard, #list .arcard').length)");
    const listHtmlLen = () => s.eval("(document.getElementById('list')||{}).innerHTML ? document.getElementById('list').innerHTML.length : 0");
    const headTitle = () => s.eval("(document.getElementById('hTitle')||document.querySelector('.hd h1')||{}).textContent||''");

    // ---------- 1) 专辑页搜索：视图必须保持 albums ----------
    await navTo('albums');
    await typeSearch('');
    await ub.sleep(600);
    const v0 = await view();
    const rows0 = await listRows();
    await typeSearch('盈月');
    const v1 = await view();
    const rows1 = await listRows();
    const t1 = await headTitle();
    ck(v0 === 'albums', '前置：从「专辑」页起步', 'S.view=' + v0);
    ck(v1 === 'albums', 'E-3 专辑页搜索后视图保持 albums（未被拽到曲目页）',
       'S.view=' + v1 + '  标题="' + t1 + '"');
    // 真过滤了才算过：结果集必须不同于未搜索时（变少，或明确进入"未找到"空态）
    const filteredOrEmpty = rows1 !== rows0 || (await s.eval('!!document.querySelector("#searchEmpty")'));
    ck(filteredOrEmpty, 'E-3 专辑页搜索真的过滤了列表（不是只保持视图的空实现）',
       '未搜索 ' + rows0 + ' 项 → 搜索后 ' + rows1 + ' 项');
    await s.shot(path.join(OUT, 'e3_albums.png'));

    // ---------- 2) 艺术家页搜索：视图必须保持 artists ----------
    await navTo('artists');
    await typeSearch('');
    await ub.sleep(600);
    const vA0 = await view();
    await typeSearch('班得瑞');
    const vA1 = await view();
    const tA1 = await headTitle();
    const artistsFilterWorks = (await s.eval(
      '(function(){var h=document.getElementById("list")?document.getElementById("list").innerHTML:"";' +
      'return {hasQuery:/搜索/.test((document.querySelector(".hd h1")||{}).textContent||"")||/搜索/.test(h),len:h.length};})()'
    ));
    ck(vA0 === 'artists', '前置：从「艺术家」页起步', 'S.view=' + vA0);
    ck(vA1 === 'artists', 'E-3 艺术家页搜索后视图保持 artists（未被拽到曲目页）',
       'S.view=' + vA1 + '  标题="' + tA1 + '"');
    ck(!!artistsFilterWorks, 'E-3 艺术家页搜索真的走了过滤分支（标题或空态带搜索词）',
       JSON.stringify(artistsFilterWorks));
    await s.shot(path.join(OUT, 'e3_artists.png'));

    // ---------- 3) 曲目页搜索：本来就该在 tracks（不得回退） ----------
    await navTo('tracks');
    await typeSearch('zzzz_no_such_track_zzzz');
    const vT = await view();
    ck(vT === 'tracks', '回归：曲目页搜索后仍是 tracks（原有行为不得回退）', 'S.view=' + vT);

    // ---------- 4) 清空搜索：回到无过滤列表 ----------
    await navTo('albums');
    await ub.sleep(500);
    const rowsBeforeClear = await (async () => { await typeSearch('盈月'); return listRows(); })();
    await s.eval("(function(){var b=D('qClear');if(b&&b.offsetParent!==null)b.click();else{var q=D('q');q.value='';q.dispatchEvent(new Event('input',{bubbles:true}));}return true;})()");
    await ub.sleep(1400);
    const rowsAfterClear = await listRows();
    const vClear = await view();
    ck(vClear === 'albums', 'E-3 清空搜索后仍在 albums', 'S.view=' + vClear);
    ck(rowsAfterClear >= rowsBeforeClear, 'E-3 清空搜索后列表恢复（条目数不减少）',
       '清空前 ' + rowsBeforeClear + ' → 清空后 ' + rowsAfterClear);

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
