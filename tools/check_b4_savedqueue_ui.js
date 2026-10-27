// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
'use strict';

const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');

const base = (process.argv[2] || 'http://127.0.0.1:19104').replace(/\/$/, '');
const out = process.argv[3] || '/tmp/rlw/i4/evidence';
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
    if (!settings.kv || settings.kv.backend !== 'null') throw new Error('test requires backend=null');

    // 清理测试歌单
    await api('/api/sq/delete?name=' + encodeURIComponent('UI测试歌单'), '').catch(() => {});

    s = await ub.open({ url: base, width: 1400, height: 900 });
    if (!await s.waitFor('window.S && typeof renderSavedQueues === "function"', 15000)) {
      throw new Error('page not ready');
    }

    // ---------- 判据 1：左栏 #sqNew 按钮存在 ----------
    const hasSqNew = await s.eval('!!document.getElementById("sqNew")');
    check(hasSqNew, '左栏我的歌单旁存在 #sqNew 按钮', { hasSqNew });

    // ---------- 判据 2：单曲页 #npAddSq 存在且在 #npCastBtn 右边 ----------
    // 先塞一首歌起播以激活单曲页
    const testFile1 = '/music/test1.flac';
    const testFile2 = '/music/test2.flac';
    const testFile3 = '/music/test3.flac';

    await api('/api/clear', '');
    await api('/api/add?file=' + encodeURIComponent(testFile1), '');
    await api('/api/add?file=' + encodeURIComponent(testFile2), '');
    await api('/api/add?file=' + encodeURIComponent(testFile3), '');
    await s.eval('loadQ()');
    await s.eval('openNowPlaying()');
    await ub.sleep(300);

    const npBtns = await s.eval(`(function(){
      var cast = document.getElementById('npCastBtn');
      var add = document.getElementById('npAddSq');
      if (!cast || !add) return { castExists: !!cast, addExists: !!add };
      var rCast = cast.getBoundingClientRect();
      var rAdd = add.getBoundingClientRect();
      return {
        castExists: true,
        addExists: true,
        addText: (add.textContent || '').trim(),
        castLeft: rCast.left,
        addLeft: rAdd.left,
        isRight: rAdd.left > rCast.left
      };
    })()`);
    check(npBtns.addExists && /添加到歌单/.test(npBtns.addText || '') && npBtns.isRight,
      '单曲页存在 #npAddSq（文案添加到歌单）且在 #npCastBtn 右侧', npBtns);

    // ---------- 判据 3：右键菜单项包含「保存到歌单…」----------
    // 切到队列页并触发第一行的 oncontextmenu
    await s.eval('renderQueuePage()');
    await ub.sleep(200);

    const menuCheck = await s.eval(`(function(){
      var row = document.querySelector('#list .qrow');
      if (!row) return { hasRow: false };
      var r = row.getBoundingClientRect();
      var ev = new MouseEvent('contextmenu', {
        bubbles: true, cancelable: true, clientX: r.left + 50, clientY: r.top + 10
      });
      row.dispatchEvent(ev);
      var m = document.getElementById('__tmenu') || document.querySelector('.qmenu');
      if (!m) return { hasRow: true, hasMenu: false };
      var text = m.innerText || m.textContent || '';
      return { hasRow: true, hasMenu: true, hasItem: text.indexOf('保存到歌单') !== -1, text: text };
    })()`);
    check(menuCheck.hasRow && menuCheck.hasItem,
      '队列行右键菜单包含「保存到歌单…」选项', menuCheck);

    // 关闭任何残留菜单/弹层
    await s.eval(`(function(){
      var old = document.getElementById('__tmenu') || document.querySelector('.qmenu');
      if (old) old.remove();
      var mod = document.getElementById('modal');
      if (mod) mod.classList.remove('on');
    })()`);

    // ---------- 判据 4：三个入口各跑一次真实点击，核对 /api/sq/info ----------
    // 入口 A：点击 #sqNew，弹窗输入「UI测试歌单」并确定
    await s.eval(`(function(){
      var btn = document.getElementById('sqNew');
      if (btn) btn.click();
    })()`);
    await ub.sleep(100);
    const modalA = await s.eval(`(function(){
      var inp = document.getElementById('askIn');
      var ok = document.getElementById('askOk');
      if (!inp || !ok) return false;
      inp.value = 'UI测试歌单';
      ok.click();
      return true;
    })()`);
    await ub.sleep(300);
    check(modalA, '入口A（#sqNew 新建空歌单）触发并提交', { modalA });

    // 入口 B：队列行右键 → 点击「保存到歌单…」→ 在 pickSavedQueue 里选「UI测试歌单」
    await s.eval('renderQueuePage()');
    await ub.sleep(150);
    const clickEntryB = await s.eval(`(function(){
      var row = document.querySelector('#list .qrow[data-i="0"]');
      if (!row) return { ok: false, err: 'no qrow' };
      var r = row.getBoundingClientRect();
      row.dispatchEvent(new MouseEvent('contextmenu', {
        bubbles: true, cancelable: true, clientX: r.left + 50, clientY: r.top + 10
      }));
      var m = document.getElementById('__tmenu') || document.querySelector('.qmenu');
      if (!m) return { ok: false, err: 'no menu' };
      var btn = Array.prototype.find.call(m.querySelectorAll('button, .qm'), function(b) {
        return (b.textContent || '').indexOf('保存到歌单') !== -1;
      });
      if (!btn) return { ok: false, err: 'no btn in menu' };
      btn.click();
      return { ok: true };
    })()`);
    await ub.sleep(200);

    // 在弹出的选择弹窗里点「UI测试歌单」
    const pickB = await s.eval(`(function(){
      var m = document.getElementById('mbody');
      if (!m) return { ok: false, err: 'no mbody' };
      var item = Array.prototype.find.call(m.querySelectorAll('.sqpick-item, button, .row'), function(b) {
        return (b.textContent || '').indexOf('UI测试歌单') !== -1;
      });
      if (!item) return { ok: false, err: 'no sq item in modal' };
      item.click();
      return { ok: true };
    })()`);
    await ub.sleep(300);
    check(clickEntryB.ok && pickB.ok, '入口B（右键菜单保存到歌单）触发并选中歌单', { clickEntryB, pickB });

    // 入口 C：单曲页点击 #npAddSq → 在 pickSavedQueue 里选「UI测试歌单」
    // 先切到第 2 首并开单曲页
    await s.eval('playPath(S.q.items[1])');
    await s.eval('openNowPlaying()');
    await ub.sleep(200);

    const clickEntryC = await s.eval(`(function(){
      var btn = document.getElementById('npAddSq');
      if (!btn) return { ok: false, err: 'no npAddSq' };
      btn.click();
      return { ok: true };
    })()`);
    await ub.sleep(200);

    const pickC = await s.eval(`(function(){
      var m = document.getElementById('mbody');
      if (!m) return { ok: false, err: 'no mbody' };
      var item = Array.prototype.find.call(m.querySelectorAll('.sqpick-item, button, .row'), function(b) {
        return (b.textContent || '').indexOf('UI测试歌单') !== -1;
      });
      if (!item) return { ok: false, err: 'no sq item in modal' };
      item.click();
      return { ok: true };
    })()`);
    await ub.sleep(300);
    check(clickEntryC.ok && pickC.ok, '入口C（单曲页添加到歌单）触发并选中歌单', { clickEntryC, pickC });

    // 核验后端数据：通过 A 建空歌单，B 加了第 1 首，C 加了第 2 首 ⟹ 总共 2 首
    const finalInfo = await api('/api/sq/info?name=' + encodeURIComponent('UI测试歌单'));
    const finalItems = (finalInfo && finalInfo.items) || [];
    const entriesOk = finalInfo.ok === true && finalItems.length === 2 &&
      finalItems[0].file === testFile1 && finalItems[1].file === testFile2;
    check(entriesOk, '三个入口操作后 /api/sq/info 数据完整正确（2首入库）', finalInfo);

    await s.shot(path.join(out, 'b4_savedqueue.png'));
    check(s.errors.length === 0, '无渲染端异常', s.errors);
  } catch (e) {
    check(false, 'execution', String(e.stack || e));
  } finally {
    if (s) {
      try { await s.close(); } catch (e) { check(false, 'browser cleanup', String(e)); }
    }
    await api('/api/sq/delete?name=' + encodeURIComponent('UI测试歌单'), '').catch(() => {});
    fs.writeFileSync(path.join(out, 'result_ui.txt'), lines.join('\n') + '\n');
  }
  process.exitCode = failures ? 1 : 0;
})();
