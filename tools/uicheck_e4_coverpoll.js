// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uicheck_e4_coverpoll.js — E-4（封面抓完不重绘）的可复跑判据
//
// 判据来源：debug/20261027-01-上游改动与BUG清单.md §1 E-4「复现判据」
//   "两张以上缺图专辑。进库页触发 prefetch（第一轮启动，running:true），
//    **立刻**再次触发一次（后端回 queued:0,running:false）。
//    红判据：第二轮没有任何 /api/lib/cover/progress 请求（看 devtools 网络），
//    且第一轮抓完后网格不刷新；
//    绿判据：第一轮路径上能持续轮询到 running:false 并触发 loadAlbums()"
//
// 判据为什么必须这样组织（这一步是这条 BUG 的核心，别改成"首轮能轮询就算过"）：
//   首轮 prefetch 返回 queued=N/running=true 时，**基线代码也会轮询**（条件是
//   `ok && running && queued`）。所以"首轮能轮询"根本不是红的，测它等于什么都没测。
//   真正的缺口是**第二轮**：任务已被别处启动（上一页/上一次进库页），
//   这一次 prefetch 回 `queued:0, running:false` ⟹ 前端直接 return ⟹
//   抓完了也没人重绘，用户看到"服务端有图、界面仍占位"。
//   ⟹ 本脚本刻意构造这个顺序：先让后台跑起来，再新建页面去拿那一轮回包。
//
// 用法：node tools/uicheck_e4_coverpoll.js http://127.0.0.1:PORT/ [截图目录]
//        运行前须清空该实例的 covercache，保证"真的缺图"
// 退出码：0 = 全绿；1 = 有红；2 = 环境问题
'use strict';
const ub = require('./uibrowser');
const fs = require('fs');
const os = require('os');
const path = require('path');

const URL_ = process.argv[2] || 'http://127.0.0.1:8977/';
const OUT = process.argv[3] || path.join(os.tmpdir(), 'rta_e4_coverpoll');
fs.mkdirSync(OUT, { recursive: true });
const BASE = URL_.replace(/\/+$/, '');

const results = [];
function ck(ok, what, detail) {
  results.push({ ok, what, detail });
  console.log((ok ? '  [PASS] ' : '  [FAIL] ') + what + (detail ? '  — ' + detail : ''));
}

async function post(pathname) {
  const r = await fetch(BASE + pathname, { method: 'POST' });
  return r.json();
}

(async () => {
  // ---------- 阶段 0：在**没有页面**的情况下先起一轮抓取 ----------
  // 这就是"上一轮在跑"的等价物：任务由别处启动，与即将打开的页面无关。
  const kick = await post('/api/lib/cover/prefetch');
  console.log('  阶段0 直接触发 prefetch：' + JSON.stringify(kick));
  ck(kick && kick.ok === true && kick.running === true,
     '前置：后台封面任务已启动（running=true，造出"上一轮在跑"的状态）',
     JSON.stringify(kick));

  // 立刻再打一次：后端应当回 queued=0 —— 这正是判据里的"第二轮"
  const second = await post('/api/lib/cover/prefetch');
  console.log('  阶段0 紧跟第二次 prefetch（模拟"第二轮"）：' + JSON.stringify(second));
  ck(second && second.ok === true && second.queued === 0,
     '前置：第二轮 prefetch 回 queued=0（后端语义：上一轮还在跑则不排队）',
     JSON.stringify(second));
  // 关键观察点：这一轮"真实是否还在跑" —— 判据要的正是它能不能被如实反映
  ck(second && second.running === true,
     'E-4 第二轮 prefetch 的 running 反映**真实后台活跃度**（上一轮在跑 ⟹ 应为 true）',
     'running=' + (second && second.running) + '  （基线恒为 started，故这里为 false）');

  // ---------- 阶段 1：新建一个页面去拿那一轮回包 ----------
  let s;
  try {
    s = await ub.open({ url: 'about:blank', width: 1400, height: 900 });
  } catch (e) {
    console.error('环境问题：' + e.message);
    process.exit(2);
  }

  try {
    // 先装探针再导航——用 addScriptToEvaluateOnNewDocument 让 hook 在任何页面脚本之前就位
    await s.send('Page.enable', {});
    await s.send('Page.addScriptToEvaluateOnNewDocument', {
      source: `
        (function(){
          window.__e4 = { prefetch: 0, progress: 0, albums: 0, urls: [] };
          var of = window.fetch;
          window.fetch = function(u, o) {
            try {
              var uu = String(u && u.url ? u.url : u);
              window.__e4.urls.push(uu);
              if (uu.indexOf('/api/lib/cover/prefetch') >= 0) window.__e4.prefetch++;
              else if (uu.indexOf('/api/lib/cover/progress') >= 0) window.__e4.progress++;
              else if (uu.indexOf('/api/lib/albums') >= 0) window.__e4.albums++;
            } catch (e) {}
            return of.apply(this, arguments);
          };
        })();
      `,
    });
    await s.send('Page.navigate', { url: URL_ });
    if (!(await s.waitFor('window.S && window.__e4', 25000)))
      throw new Error('页面没起来');
    ck(true, '探针在任何页面脚本前安装完成（addScriptToEvaluateOnNewDocument）');

    // 用户路径：点侧栏「专辑」→ loadAlbums → startCoverPrefetch
    await s.eval(
      "(function(){var n=Array.prototype.slice.call(document.querySelectorAll('.nav')).find(function(e){return e.dataset.v==='albums';});if(n)n.click();return !!n;})()"
    );

    // 抓取窗口：mock 源每张 2.2s；给足余量再收尾
    await ub.sleep(1200);
    const mid = await s.eval('JSON.parse(JSON.stringify(window.__e4))');
    await ub.sleep(11000);
    const end = await s.eval('JSON.parse(JSON.stringify(window.__e4))');

    console.log('  网络探针 中途 prefetch=' + mid.prefetch + ' progress=' + mid.progress + ' albums=' + mid.albums);
    console.log('  网络探针 结束 prefetch=' + end.prefetch + ' progress=' + end.progress + ' albums=' + end.albums);

    ck(end.prefetch >= 1, '进库页确实触发了 prefetch', 'prefetch=' + end.prefetch);

    // ---- 核心红判据：这一轮（回包 queued=0/running=false）有没有人轮询进度 ----
    ck(end.progress >= 1,
       'E-4 第二轮 prefetch 之后前端仍轮询 /api/lib/cover/progress',
       'progress 调用 ' + end.progress + ' 次（基线为 0）');

    // ---- 真·重绘：抓完后必须重新拉 /api/lib/albums ----
    ck(end.albums >= 2,
       'E-4 抓完后重新拉取 /api/lib/albums（真正触发网格重绘）',
       'albums=' + end.albums + '（首屏 1 + 抓完重绘 ≥1）');

    // ---- 后端侧独立核对：图确实抓到了，所以"该重绘"这件事是有对象的 ----
    const cov = await s.eval(
      "fetch('/api/lib/albums').then(function(r){return r.json();}).then(function(j){var n=0;(j.albums||[]).forEach(function(a){if(a.cv)n++;});return {total:(j.albums||[]).length,withCover:n};})"
    );
    console.log('  后端核对：' + JSON.stringify(cov));
    ck(cov && cov.withCover > 0, '服务端确实抓到了封面（重绘有意义）',
       cov.withCover + '/' + cov.total + ' 张有封面');

    await s.shot(path.join(OUT, 'e4_after.png'));
    const errs = s.errors.slice(0, 5);
    ck(errs.length === 0, '页面无 JS 异常 / console.error', errs.join(' | '));

    console.log('\n  ⚠️ 口径（铁律 4）：本判据覆盖「后台已有一轮在跑、本次 prefetch 回 queued=0」这一条；');
    console.log('     要让它可测，后端的 running 必须反映真实活跃度，否则前端根本无从判断。');
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
