// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uicheck_p3_interactive.js — Q-5/Q-6/Q-7/Q-8 交互行为实测（单击选择/双击起播/排序/改名删除）

'use strict';
const ub = require('./uibrowser');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_ = process.argv[2] || 'http://127.0.0.1:19091/';
const OUT = process.argv[3] || path.join(os.tmpdir(), 'rta_p3_interactive');
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
      throw new Error('页面未就绪');
    }

    // =========================================================================
    // 1. 测试我的最爱：单击选中与双击起播
    // =========================================================================
    console.log('\n--- 1. 我的最爱页：单击选择与双击起播 ---');
    // 先加两首收藏
    await s.eval('Promise.all([' +
      'api("/api/fav?file=/tmp/fav_song1.flac&on=1"),' +
      'api("/api/fav?file=/tmp/fav_song2.flac&on=1")' +
    '])');
    await ub.sleep(500);

    // 切到我的最爱页
    await s.eval('loadFavs()');
    await s.waitFor('document.querySelectorAll(".favrow").length >= 2', 5000);

    // 1.1 单击第 1 行 -> 获得 .fsel 选中样式
    await s.eval('(function(){ var r = document.querySelectorAll(".favrow")[0]; if(r) r.click(); })()');
    await ub.sleep(200);
    const row0Selected = await s.eval('document.querySelectorAll(".favrow")[0].classList.contains("fsel")');
    ck(row0Selected, '我的最爱行单击触发选中态 (.fsel)', '');

    // 单击第 2 行 -> 第 1 行失去 .fsel，第 2 行获得 .fsel
    await s.eval('(function(){ var r = document.querySelectorAll(".favrow")[1]; if(r) r.click(); })()');
    await ub.sleep(200);
    const row1Selected = await s.eval('!document.querySelectorAll(".favrow")[0].classList.contains("fsel") && document.querySelectorAll(".favrow")[1].classList.contains("fsel")');
    ck(row1Selected, '单选排他切换（单击第 2 行时第 1 行失去 .fsel）', '');

    // 1.2 监听 playWholeListFrom 调用
    await s.eval('window.__pwCalls = []; var orig = window.playWholeListFrom;' +
      'window.playWholeListFrom = function(files, start, label){ window.__pwCalls.push({files: files, start: start, label: label}); orig(files, start, label); };');

    // 双击第 2 行 (index 1) -> 触发 playWholeListFrom
    await s.eval('(function(){ var r = document.querySelectorAll(".favrow")[1]; if(r) r.dispatchEvent(new MouseEvent("dblclick", {bubbles:true})); })()');
    await ub.sleep(500);

    const pwCalled = await s.eval('window.__pwCalls && window.__pwCalls.length > 0 && window.__pwCalls[0].start === 1');
    ck(pwCalled, '我的最爱行双击调用 playWholeListFrom 起播整列（start=1）', '');

    // =========================================================================
    // 2. 测试播放队列排序交互
    // =========================================================================
    console.log('\n--- 2. 播放队列：排序交互与撤销 ---');
    // 初始化队列：3 首带顺序
    await s.eval('api("/api/queue/set", "files=" + encodeURIComponent("/tmp/track_a.flac\\n/tmp/track_b.flac\\n/tmp/track_c.flac"))');
    await ub.sleep(400);

    await s.eval('renderQueuePage()');
    await s.waitFor('document.querySelectorAll(".qrow").length === 3', 5000);

    // 选下拉框排序：reverse
    await s.eval('(function(){ var sel = document.getElementById("qSort"); if(sel) { sel.value = "reverse"; sel.dispatchEvent(new Event("change")); } })()');
    await ub.sleep(800);

    // 检查第 1 首是否变为 track_c
    const firstTrack = await s.eval('document.querySelectorAll(".qrow .qt")[0].textContent');
    ck(firstTrack.includes('track_c'), '队列反转排序交互生效 (首首变为 track_c)', 'first=' + firstTrack);

    // 选下拉框排序：恢复默认顺序 (default)
    await s.eval('(function(){ var sel = document.getElementById("qSort"); if(sel) { sel.value = "default"; sel.dispatchEvent(new Event("change")); } })()');
    await ub.sleep(800);

    const firstTrackRestored = await s.eval('document.querySelectorAll(".qrow .qt")[0].textContent');
    ck(firstTrackRestored.includes('track_a'), '队列恢复默认顺序交互生效 (首首还原为 track_a)', 'first=' + firstTrackRestored);

    // =========================================================================
    // 3. 测试歌单保存/改名/删除交互
    // =========================================================================
    console.log('\n--- 3. 歌单：保存/改名/删除完整生命周期 ---');
    // 3.1 保存为歌单
    await s.eval('saveQueueDialog()');
    await s.waitFor('document.getElementById("modal").classList.contains("on")', 2000);

    await s.eval('document.getElementById("askIn").value = "深夜歌单"; document.getElementById("askOk").click();');
    await ub.sleep(800);

    // 检查左栏是否出现深夜歌单
    await s.waitFor('document.querySelector(".sqrow[data-sq=\'深夜歌单\']")', 3000);
    const hasNightSq = await s.eval('!!document.querySelector(".sqrow[data-sq=\'深夜歌单\']")');
    ck(hasNightSq, '通过弹窗成功保存并上屏「深夜歌单」', '');

    // 3.2 改名
    await s.eval('(function(){ var row = document.querySelector(".sqrow[data-sq=\'深夜歌单\']"); if(row) { var b = row.querySelector(".ren"); if(b) b.click(); } })()');
    await s.waitFor('document.getElementById("modal").classList.contains("on")', 2000);

    await s.eval('document.getElementById("askIn").value = "凌晨歌单"; document.getElementById("askOk").click();');
    await ub.sleep(800);

    await s.waitFor('document.querySelector(".sqrow[data-sq=\'凌晨歌单\']")', 3000);
    const hasMorningSq = await s.eval('!!document.querySelector(".sqrow[data-sq=\'凌晨歌单\']")');
    ck(hasMorningSq, '通过重命名按钮成功改名为「凌晨歌单」', '');

    // 3.3 删除
    await s.eval('(function(){ var row = document.querySelector(".sqrow[data-sq=\'凌晨歌单\']"); if(row) { var b = row.querySelector(".del"); if(b) b.click(); } })()');
    await s.waitFor('document.getElementById("modal").classList.contains("on")', 2000);

    // 点确定删除
    await s.eval('document.getElementById("cfYes").click()');
    await ub.sleep(800);

    const deletedSq = await s.eval('!document.querySelector(".sqrow[data-sq=\'凌晨歌单\']")');
    ck(deletedSq, '通过删除按钮及二次确认弹窗成功删除歌单', '');

    const shotFile = path.join(OUT, 'p3_interactive_check.png');
    await s.shot(shotFile);
    console.log('  截图保存至: ' + shotFile);

  } catch (err) {
    console.error('测试异常中断: ' + err.message);
    ck(false, '运行期异常', err.message);
  } finally {
    await s.close();
  }

  const bad = results.filter(r => !r.ok);
  console.log('\n=== 交互测试汇总: ' + (results.length - bad.length) + '/' + results.length + ' 通过，' + bad.length + ' 失败 ===');
  if (bad.length > 0) {
    console.log('失败项:');
    bad.forEach(b => console.log('  - ' + b.what + ' (' + b.detail + ')'));
    process.exit(1);
  } else {
    process.exit(0);
  }
})();
