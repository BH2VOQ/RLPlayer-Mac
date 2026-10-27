// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_b5_castpick.js — 验证推送到设备弹窗选择设备能力
'use strict';
const fs = require('fs');
const path = require('path');
const ub = require('./uibrowser');

const BASE_URL = process.argv[2] || 'http://127.0.0.1:19105';
const EVIDENCE_DIR = process.argv[3] || '/tmp/rlw/i5/evidence';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function run() {
  fs.mkdirSync(EVIDENCE_DIR, { recursive: true });
  console.log('Testing against', BASE_URL);

  const s = await ub.open({ url: BASE_URL, settleMs: 2000 });
  try {
    // 桩 /api/status 保持 current 为测试曲目，避免轮询把它冲刷为未播放
    await s.eval(`
      window._origFetch = window.fetch;
      window._currentTrack = '/tmp/test_track.wav';
      window.fetch = function(url, opt) {
        if (typeof url === 'string') {
          if (url.indexOf('/api/status') !== -1) {
            return Promise.resolve(new Response(JSON.stringify({
              ok: true,
              playing: true,
              paused: false,
              current: window._currentTrack,
              dur: 180,
              pos: 10,
              outRate: 44100,
              outBits: 16
            }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
          }
          if (url.indexOf('/api/cast/devices') !== -1) {
            var devs = window._mockDevices || [];
            return Promise.resolve(new Response(JSON.stringify({ ok: true, n: devs.length, devices: devs }), {
              status: 200,
              headers: { 'Content-Type': 'application/json' }
            }));
          }
          if (url.indexOf('/api/cast/state') !== -1) {
            return Promise.resolve(new Response(JSON.stringify({
              ok: true,
              running: !!window._mockCastRunning,
              device: window._mockCastDevice || '',
              phase: window._mockCastRunning ? 'PLAYING' : 'IDLE'
            }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
          }
        }
        return window._origFetch.apply(this, arguments);
      };
      openNowPlaying();
      S.lastCur = '/tmp/test_track.wav';
      renderNp();
    `);
    await sleep(600);

    const hasBtn = await s.eval(`!!D('npCastBtn')`);
    if (!hasBtn) throw new Error('单曲页没有找到 #npCastBtn 按钮');

    // -------------------------------------------------------------
    // 用例 3：无设备时点击 -> 有 toast 提示、不崩 (s.errors.length === 0)
    // -------------------------------------------------------------
    console.log('[CASE 3] 测试无设备时点击...');
    await s.eval(`
      window._mockDevices = [];
      ADV.upnpDev = '';
      if (D('toast')) D('toast').textContent = '';
      D('npCastBtn').click();
    `);
    await sleep(600);

    const case3 = await s.eval(`({
      modalOn: D('modal') ? D('modal').classList.contains('on') : false,
      toastText: D('toast') ? D('toast').textContent : '',
      errors: (window.errors || [])
    })`);
    console.log('Case 3 result:', case3);
    if (case3.modalOn) {
      throw new Error('[CASE 3 FAILED] 无设备时不应弹出选择列表 #modal');
    }
    if (!case3.toastText || case3.toastText.indexOf('未发现') === -1) {
      throw new Error('[CASE 3 FAILED] 无设备时未给出明确 toast 提示，当前 toast: ' + case3.toastText);
    }
    if (s.errors.length > 0) {
      throw new Error('[CASE 3 FAILED] 浏览器控制台出现错误: ' + s.errors.join('; '));
    }
    console.log('Case 3 PASS: 无设备时正确提示 toast: "' + case3.toastText + '"');

    // -------------------------------------------------------------
    // 用例 1 & 2: mock UPnP 造 2 台设备，验证点击必须出现 #modal，
    // .castpick-row 数量 == devices 返回数量，且能选中第二台！
    // -------------------------------------------------------------
    console.log('[CASE 1 & 2] 测试 2 台设备选择，点击弹窗并选中第二台...');
    const dev1 = {
      name: '客厅音箱 A1',
      friendlyName: '客厅音箱 A1',
      model: 'SoundPro X1',
      host: '192.168.1.50',
      location: 'http://192.168.1.50:49152/description.xml'
    };
    const dev2 = {
      name: '书房数播 B2',
      friendlyName: '书房数播 B2',
      model: 'HiFi Player N1000',
      host: '192.168.1.80',
      location: 'http://192.168.1.80:49152/description.xml'
    };

    await s.eval(`
      window._mockDevices = [${JSON.stringify(dev1)}, ${JSON.stringify(dev2)}];
      // 模拟即使之前 ADV.upnpDev 有值，未在推送时点击也必须出弹窗让用户选择/换设备
      ADV.upnpDev = '${dev1.location}';
      CAST.state = { running: false, device: '${dev1.location}' };
      D('npCastBtn').click();
    `);
    await sleep(600);

    const case1 = await s.eval(`({
      modalOn: D('modal') ? D('modal').classList.contains('on') : false,
      mtitle: D('mtitle') ? D('mtitle').textContent : '',
      rowsCount: document.querySelectorAll('.castpick-row').length,
      rowsText: Array.from(document.querySelectorAll('.castpick-row')).map(r => r.innerText.replace(/\\s+/g, ' ')),
      activeRowText: (document.querySelector('.castpick-row.active, .castpick-row.on') || {}).innerText || ''
    })`);
    console.log('Case 1 result:', case1);

    if (!case1.modalOn) {
      throw new Error('[CASE 1 FAILED] 点击推送到设备后，#modal 未打开');
    }
    if (case1.rowsCount !== 2) {
      throw new Error(`[CASE 1 FAILED] .castpick-row 数量 (${case1.rowsCount}) != devices 数量 (2)`);
    }

    // 验证选中第二台
    console.log('正在点击第二台设备进行选中...');
    await s.eval(`
      var rows = document.querySelectorAll('.castpick-row');
      if (rows[1]) rows[1].click();
    `);
    await sleep(600);

    const case2 = await s.eval(`({
      modalOn: D('modal').classList.contains('on'),
      advUpnpDev: ADV.upnpDev,
      advBackend: ADV.backend
    })`);
    console.log('Case 2 result:', case2);

    if (case2.modalOn) {
      throw new Error('[CASE 2 FAILED] 选完设备后 #modal 未关闭');
    }
    if (case2.advUpnpDev !== dev2.location) {
      throw new Error(`[CASE 2 FAILED] 期望选中第二台 (${dev2.location})，实际选中: ${case2.advUpnpDev}`);
    }
    console.log('Case 1 & 2 PASS: 弹窗展示 2 台设备，并成功选中第二台设备:', case2.advUpnpDev);

    // -------------------------------------------------------------
    // 用例 4: 已在推送时再点 -> 能看到「停止」与「换设备」两个选项
    // -------------------------------------------------------------
    console.log('[CASE 4] 测试已在推送时再点，看到「停止 / 换设备」两选项...');
    await s.eval(`
      window._mockCastRunning = true;
      window._mockCastDevice = '${dev2.location}';
      CAST.state = { running: true, device: '${dev2.location}', phase: 'PLAYING' };
      applyCastUi();
      D('npCastBtn').click();
    `);
    await sleep(600);

    const case4 = await s.eval(`({
      modalOn: D('modal') ? D('modal').classList.contains('on') : false,
      mtitle: D('mtitle') ? D('mtitle').textContent : '',
      modalHtml: D('mbody') ? D('mbody').innerHTML : '',
      hasStopBtn: !!(document.querySelector('.cast-act-stop, [data-act=stop], #castActStop') || Array.from(document.querySelectorAll('button')).some(b => b.textContent.indexOf('停止') !== -1)),
      hasChangeBtn: !!(document.querySelector('.cast-act-change, [data-act=change], #castActChange') || Array.from(document.querySelectorAll('button')).some(b => b.textContent.indexOf('换设备') !== -1 || b.textContent.indexOf('切换') !== -1))
    })`);
    console.log('Case 4 result:', case4);

    if (!case4.modalOn) {
      throw new Error('[CASE 4 FAILED] 已在推送时再点推送到设备按钮，未弹出选择/操作弹窗');
    }
    if (!case4.hasStopBtn || !case4.hasChangeBtn) {
      throw new Error(`[CASE 4 FAILED] 弹窗内缺少停止或换设备选项。hasStop: ${case4.hasStopBtn}, hasChange: ${case4.hasChangeBtn}`);
    }
    console.log('Case 4 PASS: 正在推送时弹出操作浮层，包含停止与换设备选项');

    console.log('\nALL 4 B5 CHECKS PASSED!');
  } finally {
    await s.close();
  }
}

run().catch((err) => {
  console.error('\nCHECK FAILED:', err.message);
  process.exit(1);
});
