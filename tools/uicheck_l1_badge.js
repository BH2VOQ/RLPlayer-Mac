// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uicheck_l1_badge.js — L-1（预设切换后状态框不更新）的**前端**判据
//
// 判据来源：debug/20261027-02-预设切换状态不更新/分析.md §5
//   J-2 切预设后徽标文本 → 「待播放验证」（而不是上一次播放的旧标签，也不是空白）
//   J-3 点预设后预设卡高亮（被点的那张带 .on）
//
// ⚠️ 只测"数据源 → 徽标文本"这条链，不重复测后端（后端由 check_l1_bpstate.py 覆盖）。
//    本脚本**不播放任何音频**，只调 /api/preset/apply 与直接操作 S.bpState，
//    所以不存在违反铁律 1 的风险。
//
// 用法：node tools/uicheck_l1_badge.js http://127.0.0.1:PORT/ [截图目录]
// 退出码：0 = 全绿；1 = 有红；2 = 环境问题
'use strict';
const ub = require('./uibrowser');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_ = process.argv[2] || 'http://127.0.0.1:8979/';
const OUT = process.argv[3] || path.join(os.tmpdir(), 'rta_l1_badge');
fs.mkdirSync(OUT, { recursive: true });

const results = [];
function ck(ok, what, detail) {
  results.push({ ok, what, detail });
  console.log((ok ? '  [PASS] ' : '  [FAIL] ') + what + (detail ? '  — ' + detail : ''));
}

(async () => {
  let s;
  try {
    s = await ub.open({ url: URL_, width: 1450, height: 900, settleMs: 2600 });
  } catch (e) {
    console.error('环境问题：' + e.message);
    process.exit(2);
  }

  try {
    if (!(await s.waitFor('window.S && typeof bpBadgeInfo === "function"', 20000)))
      throw new Error('页面没起来（bpBadgeInfo 不存在）');

    // ---------- J-2 空结论态：徽标必须给出诚实占位，而不是空白 ----------
    const idle = await s.eval(
      '(function(){ S.bpState=""; S.bpWhy=""; var b=bpBadgeInfo(); ' +
      'return {text:b.text, cls:b.cls, title:b.title};})()'
    );
    console.log('  空结论态 bpBadgeInfo() = ' + JSON.stringify(idle, null, 0));
    ck(idle.text === '待播放验证', 'J-2 无结论时徽标显示「待播放验证」（不是空白）',
       'text=' + JSON.stringify(idle.text));
    ck(idle.cls === 'bp-idle', 'J-2 无结论时用 bp-idle 中性样式', 'cls=' + JSON.stringify(idle.cls));
    ck(/尚未播放/.test(idle.title || ''), 'J-2 无结论时有解释性 title（说清为什么没有结论）',
       'title=' + JSON.stringify((idle.title || '').slice(0, 40) + '…'));

    // ---------- 反面对照：有结论时必须照旧显示结论，不能被占位吞掉 ----------
    const withBp = await s.eval(
      '(function(){ S.bpState="no"; S.bpWhy="重采样 44100→96000 Hz"; var b=bpBadgeInfo(); ' +
      'return {text:b.text, cls:b.cls};})()'
    );
    console.log('  有结论态 bpBadgeInfo() = ' + JSON.stringify(withBp));
    ck(withBp.text !== '待播放验证' && withBp.text !== '',
       'J-2 反面对照：有结论时照旧显示真实结论（占位不吞掉真结论）',
       'text=' + JSON.stringify(withBp.text) + ' cls=' + JSON.stringify(withBp.cls));

    // ---------- DOM 层：徽标元素真的被填了字 ----------
    // tick() 是 400ms 轮询的渲染入口；这里直接调一次再读 DOM
    await s.eval('(function(){ S.bpState=""; S.bpWhy=""; try{ if(typeof tick==="function") return true; }catch(e){} return true;})()');
    const domIdle = await s.eval(
      '(function(){ try{ tick(); }catch(e){} var e=D("bpBadge"); ' +
      'return e ? {text:e.textContent, cls:e.className, display:getComputedStyle(e).display} : null; })()'
    );
    console.log('  徽标 DOM = ' + JSON.stringify(domIdle));
    if (domIdle) {
      ck(domIdle.text === '待播放验证', 'J-2 DOM：徽标文本已渲染为「待播放验证」',
         'text=' + JSON.stringify(domIdle.text));
      ck(domIdle.display !== 'none', 'J-2 DOM：徽标可见（不是 display:none）',
         'display=' + domIdle.display);
    } else {
      // 徽标元素只在播放条存在时创建；不存在时前面两条 API 级判据已经足够
      console.log('  （本页无 #bpBadge 元素，跳过 DOM 级两条；API 级判据已覆盖）');
    }

    // ---------- J-3 预设卡高亮 ----------
    await s.eval(
      "(function(){var n=Array.prototype.slice.call(document.querySelectorAll('.nav')).find(function(e){return e.dataset.v==='station';});if(n)n.click();return !!n;})()"
    );
    await ub.sleep(1500);
    const hasCard = await s.eval('!!document.getElementById("presetCard")');
    if (hasCard) {
      // 清掉所有 .on，再点「PCM 升频」，看是否只有它被点亮
      await s.eval(
        "(function(){['presetBitPerfect','presetPcm','presetDsd'].forEach(function(i){var e=D(i);if(e)e.classList.remove('on');});return true;})()"
      );
      await s.eval("D('presetPcm').click()");
      await ub.sleep(2000);
      const onState = await s.eval(
        "(function(){var o={};['presetBitPerfect','presetPcm','presetDsd'].forEach(function(i){var e=D(i);o[i]=!!(e&&e.classList.contains('on'));});return o;})()"
      );
      console.log('  预设卡 .on 状态 = ' + JSON.stringify(onState));
      ck(onState.presetPcm === true, 'J-3 点「PCM 升频」后该卡高亮（.on）', JSON.stringify(onState));
      ck(!onState.presetBitPerfect && !onState.presetDsd,
         'J-3 高亮互斥（同时只有一张亮）', JSON.stringify(onState));

      // 高亮必须肉眼可见：背景色不能等于未点亮时
      const vis = await s.eval(
        "(function(){var p=D('presetPcm'),b=D('presetBitPerfect');" +
        "if(!p||!b) return null;" +
        "return {pBg:getComputedStyle(p).backgroundColor, bBg:getComputedStyle(b).backgroundColor," +
        "pShadow:getComputedStyle(p).boxShadow};})()"
      );
      console.log('  高亮样式对比 = ' + JSON.stringify(vis));
      ck(vis && vis.pBg !== vis.bBg, 'J-3 高亮卡片背景与未点亮卡片不同（可见）',
         'pcm=' + (vis && vis.pBg) + '  bitperfect=' + (vis && vis.bBg));
    } else {
      console.log('  （本页无 #presetCard，跳过 J-3 三条）');
    }

    await s.shot(path.join(OUT, 'l1_badge.png'));
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
