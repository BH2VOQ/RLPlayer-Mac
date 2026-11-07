// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_b7_ui.js — 1.1.4-beta7「封面不空白 / 专辑滚动位置 / AI 过期缓存先显示」UI 判据
//
// 驱动生产页面里的真实函数（loadAlbums / openAlbum / setView / coverImageObserve /
// COVER_BLOB / npStaleRefresh），不在测试里另写一份同逻辑。
//
//   C1 本地封面内存缓存生效：首屏加载后 COVER_BLOB 内有对象 URL；重绘专辑网格后
//      **60ms 内**就有 <img> 的 src 是 blob:（说明走了同步命中，不再等 fetch→blob）。
//   C2 封面端点缓存头：带封面的专辑 /api/lib/cover 200 响应含 immutable；
//      不存在的封面 404 响应是 no-store（不缓存负结果，联网后可重试）。
//   C3 专辑滚动位置：在专辑网格滚动到 scrollTop=X → 打开专辑详情 → 点左侧「专辑」返回，
//      .main.scrollTop 恢复到 X（±4px）；从其它页进「专辑」不恢复（从顶部开始）。
//   C4 AI 过期缓存先显示：模拟后端 stale-while-revalidate（summaryStale + 后台刷新），
//      过期内容先写进缓存并渲染；4s 后的静默轮询拿到新内容后原地替换（不再整段等待）。
//
// 用法：node tools/check_b7_ui.js http://127.0.0.1:19114/
'use strict';
const ub = require('./uibrowser');

const URL_ = process.argv[2] || 'http://127.0.0.1:19114/';
let fail = 0, total = 0;
function ck(ok, what, detail) {
  total++;
  if (!ok) fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${what}${detail ? '  ' + detail : ''}`);
}
const J = (o) => JSON.stringify(o);

(async () => {
  const s = await ub.open({ url: URL_, width: 1280, height: 800, settleMs: 3000 });
  try {
    const ready = await s.waitFor("typeof loadAlbums === 'function' && typeof openAlbum === 'function' && typeof npStaleRefresh === 'function'", 15000);
    if (!ready) { console.log('FATAL: page not ready'); process.exit(2); }
    const ev = (x) => s.eval(x);

    /* ---------------- C1：封面内存缓存 ---------------- */
    await ev("(function(){ setView('albums'); loadAlbums(''); return 1; })()");
    // 等首屏封面真的加载进缓存（最多 8s）
    let blobN = 0;
    for (let i = 0; i < 40; i++) {
      blobN = await ev("(function(){ return COVER_BLOB ? COVER_BLOB.size : -1; })()");
      if (blobN > 0) break;
      await ub.sleep(200);
    }
    ck(blobN > 0, 'C1 首屏加载后 COVER_BLOB 内有已解码封面的对象 URL', 'size=' + blobN);

    const rerender = await ev(`(function(){
      var t0 = performance.now();
      setView('albums'); loadAlbums('');   // 走视图缓存重绘整页
      var dt = performance.now() - t0;
      return {syncMs: dt, cacheSize: COVER_BLOB.size};
    })()`);
    await ub.sleep(80);   // MutationObserver 是微任务，给一帧时间观察"同步命中已生效"
    const after = await ev(`(function(){
      var imgs = Array.prototype.slice.call(document.querySelectorAll('#list img[data-cover-src]'));
      var blob = imgs.filter(function(img){ return /^blob:/.test(img.getAttribute('src') || ''); }).length;
      var empty = imgs.filter(function(img){ return !img.getAttribute('src'); }).length;
      return {imgs: imgs.length, blob: blob, emptyNoSrc: empty};
    })()`);
    ck(rerender && rerender.cacheSize > 0 && after && after.blob > 0,
      'C1 重绘专辑网格后 80ms 内已有 <img> 直接使用 blob:（同步命中，不再空白等待）',
      J({ rerender: rerender, after: after }));

    /* ---------------- C2：封面端点缓存头 ---------------- */
    const hdr = await ev(`(function(){
      var cv = (S.albums || []).filter(function(a){ return a.cv; })[0];
      if (!cv) return Promise.resolve({skip:true});
      function one(url){ return fetch(url).then(function(r){ return {status:r.status, cc:r.headers.get('cache-control')||''}; }); }
      return Promise.all([one('/api/lib/cover?k=' + cv.k), one('/api/lib/cover?k=__definitely_missing__')])
        .then(function(a){ return {ok:a[0], miss:a[1], key:cv.k}; });
    })()`);
    ck(hdr && hdr.ok && hdr.ok.status === 200 && /immutable/.test(hdr.ok.cc),
      'C2 有封面专辑的 /api/lib/cover 200 带 immutable 缓存头', J(hdr && hdr.ok));
    ck(hdr && hdr.miss && hdr.miss.status === 404 && /no-store/.test(hdr.miss.cc),
      'C2 不存在封面的 404 带 no-store（负结果不长期缓存）', J(hdr && hdr.miss));

    /* ---------------- C3：专辑滚动位置恢复 ---------------- */
    const scroll = await ev(`(function(){
      return new Promise(function(resolve){
        setView('albums'); loadAlbums('');
        setTimeout(function(){
          var m = document.querySelector('.main');
          if (!m) return resolve({skip:true});
          m.scrollTop = 640;
          var before = m.scrollTop;
          var card = document.querySelector('#list .card');
          if (!card) return resolve({skip:true});
          card.click();                          // 打开专辑详情（保存滚动位置）
          setTimeout(function(){
            var n = document.querySelector('.nav[data-v=albums]');
            if (n) n.click();                    // 返回专辑列表
            setTimeout(function(){
              var m2 = document.querySelector('.main');
              var restored = m2 ? m2.scrollTop : -1;
              // 反向判据：从艺术家页进入专辑列表不应继承该位置
              var art = document.querySelector('.nav[data-v=artists]'); if (art) art.click();
              setTimeout(function(){
                var alb = document.querySelector('.nav[data-v=albums]'); if (alb) alb.click();
                setTimeout(function(){
                  var m3 = document.querySelector('.main');
                  resolve({before:before, restored:restored, freshTop:m3 ? m3.scrollTop : -1});
                }, 700);
              }, 700);
            }, 700);
          }, 900);
        }, 600);
      });
    })()`);
    ck(scroll && !scroll.skip && Math.abs(scroll.restored - scroll.before) <= 4,
      'C3 专辑详情返回后 .main.scrollTop 恢复（±4px）', J(scroll));
    ck(scroll && !scroll.skip && scroll.freshTop <= 4,
      'C3 从艺术家页进「专辑」不继承旧位置（从顶部开始）', J(scroll));

    /* ---------------- C4：AI 过期缓存先显示 ---------------- */
    const stale = await ev(`(function(){
      return new Promise(function(resolve){
        openNowPlaying();
        S.curMeta = {title:'__stale_test__', artist:'Tester', album:'Stale Album', albumArtist:'Tester'};
        NP_DATA.tabs = [{k:'track', label:'歌曲', name:'__stale_test__', artist:'Tester'}];
        NP_DATA.cache = { track: { state:'ok', data:{ ok:true, ai:true, summaryStale:true, summaryRefreshing:true,
                          fields:{'演唱':'旧内容'} } } };
        NP_DATA.tabSig = null; npDataRenderTabs();
        var oldText = document.getElementById('npTabs').innerText;
        var realFetch = window.fetchSummary;
        var calls = 0;
        window.fetchSummary = function(url, cb){
          calls++;
          setTimeout(function(){ cb({ ok:true, ai:true, summaryCached:true, fields:{'演唱':'新内容'} }); }, 30);
        };
        npStaleRefresh('track', NP_DATA.req, 0);
        setTimeout(function(){
          var cached = (NP_DATA.cache.track && NP_DATA.cache.track.data) || {};
          window.fetchSummary = realFetch;
          resolve({oldText:oldText, calls:calls, newFields:cached.fields, staleFlag:!!cached.summaryStale,
                   tabText:(document.getElementById('npTabs')||{}).innerText});
        }, 5200);
      });
    })()`);
    ck(stale && stale.oldText && /旧内容/.test(stale.oldText), 'C4 过期内容先渲染到面板（不等后台刷新）', J(stale && stale.oldText));
    ck(stale && stale.calls >= 1 && stale.newFields && stale.newFields['演唱'] === '新内容' && !stale.staleFlag,
      'C4 后台刷新完成后原地替换为新内容', J(stale && { calls: stale.calls, fields: stale.newFields }));
    await ev("(function(){ if(typeof closeNowPlaying==='function') closeNowPlaying(); return 1; })()");

    console.log(`\n== ${total - fail}/${total} passed, ${fail} failed`);
    if (s.errors && s.errors.length) console.log('console errors: ' + J(s.errors.slice(0, 5)));
    process.exit(fail ? 1 : 0);
  } finally {
    await s.close();
  }
})().catch((e) => { console.error(e); process.exit(1); });
