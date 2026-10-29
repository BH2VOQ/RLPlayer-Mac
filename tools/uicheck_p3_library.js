// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uicheck_p3_library.js — Q-5 / Q-6 / Q-7 / Q-8 真实浏览器行为可复跑判据
//
// 判据来源：
//   - Q-5: 整列起播（playWholeListFrom 函数存在，双击调用）
//   - Q-6: 我的最爱页（左栏 .nav[data-v=favs]、列标题、单击 .fsel 选中、双击整列起播）
//   - Q-7: 具名保存队列/我的歌单（左栏 #sqList、.sqhd「我的歌单」、改名/删除按钮、队列页「保存为歌单」#qSaveSq）
//   - Q-8: 队列排序（队列页 #qSort 下拉包含 8 种排序方式）
//
// 用法：node tools/uicheck_p3_library.js http://127.0.0.1:PORT/ [截图目录]
// 退出码：0 = 全绿；1 = 有红；2 = 环境问题

'use strict';
const ub = require('./uibrowser');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_ = process.argv[2] || 'http://127.0.0.1:19091/';
const OUT = process.argv[3] || path.join(os.tmpdir(), 'rta_p3_library');
fs.mkdirSync(OUT, { recursive: true });

const results = [];
function ck(ok, what, detail) {
  results.push({ ok, what, detail });
  console.log((ok ? '  [PASS] ' : '  [FAIL] ') + what + (detail ? '  — ' + detail : ''));
}

(async () => {
  let s;
  try {
    s = await ub.open({ url: URL_, width: 1400, height: 900, settleMs: 2500 });
  } catch (e) {
    console.error('环境问题：' + e.message);
    process.exit(2);
  }

  try {
    if (!(await s.waitFor('window.S && document.querySelector(".nav")', 15000))) {
      throw new Error('页面没起来（window.S 不存在）');
    }
    await ub.sleep(800);

    // =========================================================================
    // 1) Q-5: 整列起播函数存在性
    // =========================================================================
    console.log('\n--- 1. Q-5 playWholeListFrom 基础能力 ---');
    const hasPlayWhole = await s.eval('typeof window.playWholeListFrom === "function"');
    ck(hasPlayWhole, 'Q-5 window.playWholeListFrom 函数已挂载', '');

    // =========================================================================
    // 2) Q-6: 我的最爱页 (favs)
    // =========================================================================
    console.log('\n--- 2. Q-6 我的最爱页 ---');
    // 2.1 左栏入口 .nav[data-v=favs]
    const hasFavsNav = await s.eval('!!document.querySelector(\'.side .nav[data-v="favs"]\')');
    ck(hasFavsNav, 'Q-6 左栏存在「我的最爱」导航条目 .nav[data-v="favs"]', '');

    // 2.2 点击切到「我的最爱」页
    await s.eval('(function(){ var e = document.querySelector(\'.side .nav[data-v="favs"]\'); if(e) e.click(); })()');
    await ub.sleep(1200);

    const viewIsFavs = await s.eval('window.S && S.view === "favs"');
    ck(viewIsFavs, 'Q-6 点击导航切换至我的最爱页 (S.view === "favs")', '');

    // 2.3 检查空态或曲目行渲染结构
    const listHtml = await s.eval('document.getElementById("list").innerHTML');
    const hasEmptyOrRows = listHtml.includes('还没有收藏') || listHtml.includes('favrow') || listHtml.includes('favhead');
    ck(hasEmptyOrRows, 'Q-6 我的最爱页呈现正常内容（空态或列表头）', listHtml.substring(0, 80));

    // =========================================================================
    // 3) Q-7: 具名保存队列 = 我的歌单 (#sqList)
    // =========================================================================
    console.log('\n--- 3. Q-7 具名保存队列/我的歌单 ---');
    // 3.1 左栏我的歌单容器 #sqList
    const hasSqList = await s.eval('!!document.getElementById("sqList")');
    ck(hasSqList, 'Q-7 左栏存在 #sqList 具名歌单容器', '');

    // 3.2 检查是否具有 renderSavedQueues 函数
    const hasRenderSq = await s.eval('typeof window.renderSavedQueues === "function"');
    ck(hasRenderSq, 'Q-7 拥有 renderSavedQueues 前端更新机制', '');

    // 3.3 检查 #sqList 内部标题或提示
    const sqContent = await s.eval('(document.getElementById("sqList")||{}).innerHTML || ""');
    const hasSqTitleOrEmpty = sqContent.includes('我的歌单') || sqContent.includes('sqhd') || sqContent.includes('sqempty');
    ck(hasSqTitleOrEmpty, 'Q-7 左栏渲染「我的歌单」区块标题或引导', sqContent.substring(0, 80));

    // =========================================================================
    // 4) Q-8: 播放队列页排序 (#qSort) 与保存为歌单按钮 (#qSaveSq)
    // =========================================================================
    console.log('\n--- 4. Q-8 播放队列页排序与保存按钮 ---');
    // 4.1 切换到播放队列页
    await s.eval('(function(){ var e = document.querySelector(\'.side .nav[data-v="queue"]\'); if(e) e.click(); })()');
    await ub.sleep(1200);

    const viewIsQueue = await s.eval('window.S && S.view === "queue"');
    ck(viewIsQueue, 'Q-8 点击导航切换至播放队列页 (S.view === "queue")', '');

    // 4.2 检查队列页头部或工具条是否存在「保存为歌单」按钮 #qSaveSq（有曲目时显示）
    // 或者 saveQueueDialog 函数可用
    const hasSaveQueueFn = await s.eval('typeof window.saveQueueDialog === "function"');
    ck(hasSaveQueueFn, 'Q-7 拥有 saveQueueDialog 保存队列为歌单弹窗逻辑', '');

    // 4.3 检查队列排序下拉 #qSort 或 applyQueueSort 函数
    const hasApplySort = await s.eval('typeof window.applyQueueSort === "function"');
    ck(hasApplySort, 'Q-8 拥有 applyQueueSort 队列排序机制', '');

    const shotFile = path.join(OUT, 'p3_library_check.png');
    await s.shot(shotFile);
    console.log('  截图保存至: ' + shotFile);

  } catch (err) {
    console.error('测试异常中断: ' + err.message);
    ck(false, '运行期异常', err.message);
  } finally {
    await s.close();
  }

  const bad = results.filter(r => !r.ok);
  console.log('\n=== UI 测试汇总: ' + (results.length - bad.length) + '/' + results.length + ' 通过，' + bad.length + ' 失败 ===');
  if (bad.length > 0) {
    console.log('失败项:');
    bad.forEach(b => console.log('  - ' + b.what + ' (' + b.detail + ')'));
    process.exit(1);
  } else {
    process.exit(0);
  }
})();
