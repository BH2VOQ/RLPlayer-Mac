// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uicheck_f5_quality.js — F-5（音质体检弹窗）的可复跑判据
//
// 判据来源：debug/20261027-00-BUG与新增功能总清单.md §2.2 F-5
//   "音质分析弹窗 UI（19 项指标可视化）… 本地 grep openQualityModal = 0"
//
// 红（基线）：openQualityModal 不存在 → 曲目右键菜单里没有「音质体检」这一项，
//            页面上任何地方都拿不到 19 项指标。
// 绿：右键曲目 → 菜单出现「音质体检…」→ 点开 → 弹窗里真实渲染出各分组指标。
//
// 为什么不用"函数存在"当判据（铁律 3）：
//   函数存在 ≠ 用户能用。这里走的是**真实鼠标路径**：右键行 → 点菜单项 → 读弹窗 DOM。
//   并且断言**具体数值**来自后端（与直连 /api/track/health 的返回逐项比对），
//   防止弹窗只是把常量画上去。
//
// 用法：node tools/uicheck_f5_quality.js http://127.0.0.1:8991/ [截图目录]
// 退出码：0 = 全绿；1 = 有红；2 = 环境问题
'use strict';
const ub = require('./uibrowser');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_ = process.argv[2] || 'http://127.0.0.1:8991/';
const OUT = process.argv[3] || path.join(os.tmpdir(), 'rta_f5_quality');
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
      throw new Error('页面没起来');
    await ub.sleep(800);

    // ---------- A. 基线对照：函数在不在 ----------
    const hasFn = await s.eval("typeof openQualityModal === 'function'");
    ck(hasFn, 'openQualityModal 已定义（红侧基线为 false）', 'typeof=' + (hasFn ? 'function' : 'undefined'));

    // ---------- B. 真实路径：进专辑页 → 右键曲目行 ----------
    await s.eval(
      "(function(){var n=Array.prototype.slice.call(document.querySelectorAll('.nav')).find(function(e){return e.dataset.v==='albums';});if(n)n.click();return !!n;})()"
    );
    await ub.sleep(1500);
    // 进第一张专辑
    const openedAlbum = await s.eval(
      "(function(){var c=document.querySelector('#list .card, #list .acard');if(!c)return false;c.click();return true;})()"
    );
    ck(openedAlbum, '打开第一张专辑（进入曲目列表）');
    const hasRow = await s.waitFor("!!document.querySelector('#list .trow')", 12000);
    ck(hasRow, '曲目行已渲染');

    // 右键曲目行（走真实 contextmenu 事件）
    const menuInfo = await s.eval(`(function(){
      var row = document.querySelector('#list .trow');
      if (!row) return {ok:false, why:'no row'};
      var r = row.getBoundingClientRect();
      row.dispatchEvent(new MouseEvent('contextmenu', {
        bubbles:true, cancelable:true, clientX: r.left+40, clientY: r.top+10
      }));
      var m = document.getElementById('__tmenu');
      if (!m) return {ok:false, why:'no menu'};
      return {ok:true, items: Array.prototype.map.call(m.querySelectorAll('button'), function(b){
        return {k:b.dataset.k, t:b.textContent.trim()};
      })};
    })()`);
    console.log('  右键菜单 = ' + JSON.stringify(menuInfo));
    ck(menuInfo.ok, '右键曲目行弹出自定义菜单（不是浏览器原生菜单）',
       menuInfo.why || '');
    if (menuInfo.ok) {
      const hasQ = menuInfo.items.some((i) => i.k === 'quality');
      const hasQueue = menuInfo.items.some((i) => i.k === 'queue');
      ck(hasQ, 'F-5 菜单里有「音质体检…」入口', JSON.stringify(menuInfo.items));
      ck(hasQueue, '回归：原「加入播放队列」仍在（老右键行为没丢）', JSON.stringify(menuInfo.items));
    }

    // ---------- C. 点开音质体检 → 读弹窗 ----------
    await s.eval("(function(){var b=document.querySelector('#__tmenu [data-k=quality]');if(b)b.click();return !!b;})()");
    const modalOn = await s.waitFor("document.getElementById('modal') && document.getElementById('modal').classList.contains('on')", 8000);
    ck(modalOn, '弹窗已打开');

    // 等分析完成（本地 WAV 很快，但给足余量）
    const gotData = await s.waitFor(
      "document.getElementById('mbody') && document.getElementById('mbody').textContent.indexOf('THD+N') >= 0", 25000);
    ck(gotData, '弹窗里渲染出了失真指标（分析已完成，不是一直转圈）');

    const body = await s.eval("document.getElementById('mbody').textContent");
    const title = await s.eval("document.getElementById('mtitle').textContent");
    console.log('  弹窗标题 = ' + JSON.stringify(title));

    // 六个分组标题必须都在
    const SECTIONS = ['响度与动态', '失真', '噪声', '频响', '削波与峰值', '立体声', '动态细化'];
    const missing = SECTIONS.filter((t) => body.indexOf(t) < 0);
    ck(missing.length === 0, 'F-5 七个分组标题齐全（19 项指标有组织地展示）',
       missing.length ? ('缺: ' + missing.join(',')) : SECTIONS.join('/'));

    // 关键指标名必须出现
    const LABELS = ['THD+N', '非谐波残留', '本底噪声', '频谱重心', '频谱倾斜', '95% 滚降点',
                    '削波样本', '峰值因子', '声道相关', 'P95−P10'];
    const missLabels = LABELS.filter((t) => body.indexOf(t) < 0);
    ck(missLabels.length === 0, 'F-5 关键指标名全部出现',
       missLabels.length ? ('缺: ' + missLabels.join(',')) : LABELS.length + ' 项');

    // ---------- D. 数值必须真来自后端（不是常量） ----------
    const api = await s.eval(`(function(){
      var row = document.querySelector('#list .trow');
      return fetch('/api/track/health?file=' + encodeURIComponent('/tmp/f5lib/music/Alpha/01.wav'))
        .then(function(r){return r.json();});
    })()`);
    const q = (api && api.health && api.health.quality) || {};
    console.log('  后端 quality.thdn_db=' + q.thdn_db + ' crest_db=' + q.crest_db + ' centroid_hz=' + q.centroid_hz);
    ck(api && api.ok === true, '后端 /api/track/health 可用', JSON.stringify(api && api.ok));

    // 用后端的值反查弹窗文案：centroid_hz 是 1002.2 这种，直接找整数部分
    const centroidStr = (typeof q.centroid_hz === 'number') ? Math.round(q.centroid_hz).toString() : null;
    ck(centroidStr !== null && body.indexOf(centroidStr) >= 0,
       'F-5 弹窗里的频谱重心数值与后端返回一致（不是画常量）',
       '后端=' + centroidStr + 'Hz');
    const crestStr = (typeof q.crest_db === 'number') ? q.crest_db.toFixed(2) : null;
    ck(crestStr !== null && body.indexOf(crestStr) >= 0,
       'F-5 弹窗里的峰值因子数值与后端返回一致',
       '后端=' + crestStr + 'dB');

    // ---------- E. 守卫：不显示 NaN / undefined ----------
    const bad = (body.match(/NaN|undefined|Infinity/g) || []);
    ck(bad.length === 0, 'F-5 数值守卫：弹窗里没有 NaN / undefined / Infinity',
       bad.length ? ('出现: ' + bad.slice(0, 5).join(',')) : '干净');

    await s.shot(path.join(OUT, 'f5_quality.png'));
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
