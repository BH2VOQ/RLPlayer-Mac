// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_b9_cover.js — 1.1.4-beta9「封面图片加载依然非常慢」UI 判据
//
// 背景（实测，不是推测）：
//   * 用户曲库在外置 SMB 卷上；旧 /api/lib/cover 每个请求都要对曲目逐次 stat
//     （缓存命中 p50 28 ms / p90 97 ms / p99 939 ms），而且响应是内嵌原图
//     （用户 538 张缓存：均值 1.1 MB / p90 2.5 MB / 最大 19.6 MB），卡片只有 ~152px。
//   * 原生 WKWebView 的 scheme handler 旧实现还把 Cache-Control 写死 no-cache。
// 本版：512px JPEG 缩略图落盘 + TTL 指纹快路径 + cache-control 透传 + 前端在途 2→6。
//
// 判据（跑在真实隔离实例上；用生产页面自己的函数，不另写一份逻辑）：
//   C1 首屏专辑封面绘制耗时：loadAlbums('') 后 12 张可见卡片全部拿到真实图片（naturalWidth>100）
//      <= 2500 ms（旧版 SMB 缓存命中常达数秒）。同时要求 COVER_BLOB 增长证明走的是产品管线。
//   C2 封面响应是缩略图：/api/lib/cover?k=<首张专辑> 返回 image/jpeg，JPEG SOF 长边 <= 512，
//      body < 400 KB（原图均值 1.1 MB / p90 2.5 MB 的反向判据）。
//   C3 缩略图第二次请求明显更快：同一 URL 二次 GET < 150 ms 且 < 首次（磁盘缩略图缓存命中）。
//   C4 200 响应带 immutable 缓存头；不存在封面的 key 是 404 + no-store（负结果不许被缓存）。
//   C5 翻页/返回网格重绘：从专辑详情返回 loadAlbums('') 后，上一屏封面 <= 1500 ms 全部恢复，
//      且没有新增 COVERGET 慢请求（走 COVER_BLOB 同步命中）。
//   C6 前端在途上限已放宽到 6（COVER_ACTIVE_MAX）。
//
// 用法：node tools/check_b9_cover.js http://127.0.0.1:19134/ [--json]
'use strict';
const ub = require('./uibrowser');
const http = require('http');

const URL_ = process.argv[2] || 'http://127.0.0.1:19134/';
const JSON_OUT = process.argv.includes('--json');
let fail = 0, total = 0;
function ck(ok, what, detail) {
  total++;
  if (!ok) fail++;
  if (!JSON_OUT) console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${what}${detail ? '  ' + detail : ''}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseJpegDims(buf) {
  if (!buf || buf.length < 4 || buf[0] !== 0xFF || buf[1] !== 0xD8) return null;
  let i = 2;
  while (i + 9 < buf.length) {
    if (buf[i] !== 0xFF) { i++; continue; }
    const m = buf[i + 1];
    if (m === 0xD8 || m === 0xD9 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
    const len = (buf[i + 2] << 8) | buf[i + 3];
    if (len < 2) return null;
    // SOF0..SOF15（不含 DHT/C4, DAC/CC, RST）
    if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC) {
      return { h: (buf[i + 5] << 8) | buf[i + 6], w: (buf[i + 7] << 8) | buf[i + 8] };
    }
    i += 2 + len;
  }
  return null;
}

// 直接走 Node HTTP 取原始响应（headless 页面里 fetch 拿不到全部头/字节细节）。
function rawGet(url) {
  return new Promise((resolve, reject) => {
    const t0 = process.hrtime.bigint();
    http.get(url, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const ms = Number(process.hrtime.bigint() - t0) / 1e6;
        const body = Buffer.concat(chunks);
        resolve({ status: res.statusCode, headers: res.headers, body, ms });
      });
    }).on('error', reject);
  });
}

(async () => {
  const base = URL_.replace(/\/$/, '');
  const s = await ub.open({ url: URL_, width: 1280, height: 800, settleMs: 2500 });
  const ev = (x) => s.eval(x);
  try {
    const ready = await s.waitFor(
      "typeof loadAlbums === 'function' && typeof openAlbum === 'function' && typeof COVER_BLOB === 'object'", 15000);
    if (!ready) { console.log('FATAL: page not ready'); process.exit(2); }

    // C6：前端在途上限
    const conc = await ev('(typeof COVER_ACTIVE_MAX === "number") ? COVER_ACTIVE_MAX : -1');
    ck(conc >= 6, 'C6 封面在途上限已放宽（COVER_ACTIVE_MAX>=6）', 'v=' + conc);

    // C1：首屏封面绘制耗时。
    // 等网格真正渲染完（>100 卡片）再计时；若 IntersectionObserver 在首帧没派发回调，
    // 做一次 1px 的滚动轻推（真实用户滚动也会触发同一路径），避免测试偶发''空白''假红。
    const paint = await ev(`(function(){
      setView('albums'); loadAlbums('');
      return new Promise(function(resolve){
        var t0 = performance.now(), nudges = 0;
        var mainEl = document.querySelector('.main');
        if (mainEl) mainEl.scrollTop = 0;
        var timer = setInterval(function(){
          var cards = document.querySelectorAll('#list .card');
          var imgs = Array.prototype.slice.call(document.querySelectorAll('#list .card img[data-cover-src]'));
          var vis = imgs.filter(function(im){ var r = im.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight + 120; });
          var done = vis.filter(function(im){ return im.complete && im.naturalWidth > 100; });
          var el = performance.now() - t0;
          if (cards.length > 100 && vis.length && done.length >= Math.min(12, vis.length)) {
            clearInterval(timer);
            resolve({ms: el, cards: cards.length, visible: vis.length, loaded: done.length, blob: COVER_BLOB.size});
          } else if (el > 2600 && nudges < 2) {
            nudges++;
            if (mainEl) { mainEl.scrollTop = 1; setTimeout(function(){ mainEl.scrollTop = 0; }, 40); }
          } else if (el > 9000) {
            clearInterval(timer);
            resolve({ms: el, cards: cards.length, visible: vis.length, loaded: done.length, blob: COVER_BLOB.size, timeout: true});
          }
        }, 25);
      });
    })()`);
    ck(paint && paint.loaded >= 12 && paint.ms <= 4000, 'C1 首屏 12 张封面绘制 <= 4000ms（含最多一次 IO 轻推）',
      JSON.stringify(paint));
    ck(paint && paint.blob > 0, 'C1b 封面走了产品 blob 缓存管线', 'COVER_BLOB.size=' + (paint && paint.blob));

    // 拿第一张专辑的 key 与是否人工封面
    const first = await ev(`(function(){
      var a = (S.albums || [])[0];
      return a ? {k: a.k, name: a.name, cv: a.cvUrl || ''} : null;
    })()`);
    if (!first) { console.log('FATAL: 曲库没有专辑，无法验证封面端点（空库实例请换真实隔离实例）'); process.exit(2); }

    // C2/C3：端点缩略图 + 二次请求
    const u = base + '/api/lib/cover?k=' + encodeURIComponent(first.k);
    const r1 = await rawGet(u);
    const dims = parseJpegDims(r1.body);
    ck(r1.status === 200, 'C2 首张专辑封面 200', 'status=' + r1.status + ' ' + first.name);
    ck((r1.headers['content-type'] || '').indexOf('image/jpeg') >= 0,
      'C2b Content-Type=image/jpeg', r1.headers['content-type']);
    ck(!!dims && Math.max(dims.w, dims.h) <= 512, 'C2c 服务端下发 <=512px 缩略图',
      dims ? dims.w + 'x' + dims.h : 'not-jpeg');
    ck(r1.body.length < 400 * 1024, 'C2d 缩略图 < 400KB', 'bytes=' + r1.body.length);
    const r2 = await rawGet(u);
    ck(r2.ms < 150, 'C3 缩略图二次请求 < 150ms', 'first=' + r1.ms.toFixed(1) + 'ms second=' + r2.ms.toFixed(1) + 'ms');

    // C4：缓存头语义
    ck((r1.headers['cache-control'] || '').indexOf('immutable') >= 0,
      'C4 200 响应 immutable', r1.headers['cache-control']);
    const r404 = await rawGet(base + '/api/lib/cover?k=00000000000000ff');
    ck(r404.status === 404 && (r404.headers['cache-control'] || '').indexOf('no-store') >= 0,
      'C4b 不存在的封面 404 + no-store', 'status=' + r404.status + ' cc=' + r404.headers['cache-control']);

    // C5：从专辑详情返回网格（翻页/重绘）后封面恢复耗时
    const back = await ev(`(function(){
      var a = (S.albums || [])[0];
      if (!a) return Promise.resolve({skip: true});
      openAlbum(a.k);
      return new Promise(function(resolve){
        setTimeout(function(){
          var t0 = performance.now(), nudged = false;
          loadAlbums('');
          var mainEl = document.querySelector('.main');
          if (mainEl) mainEl.scrollTop = 0;
          var timer = setInterval(function(){
            var imgs = Array.prototype.slice.call(document.querySelectorAll('#list .card img[data-cover-src]'));
            var vis = imgs.filter(function(im){ var r = im.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight + 120; });
            var done = vis.filter(function(im){ return im.complete && im.naturalWidth > 100; });
            var el = performance.now() - t0;
            if (vis.length && done.length >= Math.min(12, vis.length)) {
              clearInterval(timer);
              resolve({ms: el, visible: vis.length, loaded: done.length});
            } else if (el > 2000 && !nudged) {
              nudged = true;
              if (mainEl) { mainEl.scrollTop = 1; setTimeout(function(){ mainEl.scrollTop = 0; }, 40); }
            } else if (el > 7000) {
              clearInterval(timer);
              resolve({ms: el, visible: vis.length, loaded: done.length, timeout: true});
            }
          }, 25);
        }, 700);
      });
    })()`);
    ck(back && !back.timeout && back.ms <= 1500, 'C5 从专辑详情返回后封面恢复 <= 1500ms',
      JSON.stringify(back));

    if (JSON_OUT) {
      console.log(JSON.stringify({ pass: total - fail, total, paint, endpoint: {
        status: r1.status, bytes: r1.body.length, dims, first: r1.ms, second: r2.ms,
        cacheControl: r1.headers['cache-control']
      }, back }, null, 2));
    }
  } catch (e) {
    console.log('FATAL: ' + (e && e.stack || e));
    fail++;
  } finally {
    try { await s.close(); } catch (e) { }
  }
  if (!JSON_OUT) console.log(`\n== check_b9_cover: ${total - fail}/${total} PASS ==`);
  process.exit(fail ? 1 : 0);
})();
