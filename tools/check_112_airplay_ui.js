// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_112_airplay_ui.js — 1.1.2 AirPlay 输出适配的 UI 判据（AP-1.2 / AP-1.4 / AP-1.7）
//
// ============================ 这个测试在证明什么 ============================
// 直接驱动**生产页面里的真实函数**（loadDeviceList / showChain），不是在测试里另写
// 一份"和产品一样的逻辑"—— 那只能证明两份代码都写了同一段文字。
//
// 判据：
//   U1 传输判定只认后端真值：名字里带 "AirPlay" 的 USB 设备**不能**被标成 AirPlay；
//      名字里没有 AirPlay 的 'airp' 设备**必须**被标出来。
//   U2 延迟只显示系统属性值：latencyKnown=true, latencyMs=312.5 ⟹ 出现 "313ms"；
//      整页文本**绝不能**出现写死的 "2 秒/2000ms/2s" 这类伪延迟。
//   U3 延迟未知时必须显示"未知"，不能编一个数。
//   U4 信号链：transport=airplay 时输出节点必须写明 AirPlay 共享、非 bit-perfect，
//      且 badge 为 AirPlay；共享判定不能只依赖前端自己保存的 backend 字段。
//   U5 页面不存在任何"多房间/分组"一类未被系统暴露的功能入口（AP-1.7）。
//
// 🔴 铁律 1：全程 headless，不打开音频设备、不出声；服务器用 backend=null + 隔离状态目录。
// 🔴 铁律 2：浏览器进程由 uibrowser 核验属主后 SIGTERM，绝不 force-kill。
'use strict';
const path = require('path');
const ub = require('./uibrowser');

let fail = 0, total = 0;
function ck(ok, what, detail) {
  total++;
  if (!ok) fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${what}${detail ? '  ' + detail : ''}`);
}

(async () => {
  const url = process.argv[2] || 'http://127.0.0.1:19108/';
  const s = await ub.open({ url, width: 1280, height: 900 });
  try {
    // ---- U1/U2/U3：真实 loadDeviceList，喂一份构造的设备表 ----
    const devJson = JSON.stringify({
      ok: true,
      devices: [
        // 名字里带 AirPlay，但传输是 USB —— 绝不能按名字判成 AirPlay
        { id: '11', name: 'AirPlay Test Dummy USB', default: false, channels: 2, mixRate: 44100,
          mixBits: 16, mixFmt: 'pcm', rates: [44100], dopCarrierRate: 0,
          transport: 'usb', transportType: 1969841184, sharedOnly: false,
          latencyKnown: true, latencyMs: 12.4, latencySource: 'CoreAudio: device: 10 frames',
          currentRate: 44100, currentChannels: 2, currentBufferFrames: 512,
          bitPerfectCapable: true, supportsHog: true, dsd: 'dop' },
        // 名字完全看不出是 AirPlay，但 transport='airp' —— 必须被标出来
        { id: '22', name: 'Living Room', default: false, channels: 2, mixRate: 44100,
          mixBits: 16, mixFmt: 'pcm', rates: [44100], dopCarrierRate: 0,
          transport: 'airplay', transportType: 1634038384, sharedOnly: true,
          latencyKnown: true, latencyMs: 312.5, latencySource: 'CoreAudio: device: 8800 frames',
          currentRate: 44100, currentChannels: 2, currentBufferFrames: 4096,
          bitPerfectCapable: false, supportsHog: false, dsd: 'none' },
        // 延迟未知的 AirPlay
        { id: '33', name: 'Bedroom', default: true, channels: 2, mixRate: 48000,
          mixBits: 16, mixFmt: 'pcm', rates: [48000], dopCarrierRate: 0,
          transport: 'airplay', transportType: 1634038384, sharedOnly: true,
          latencyKnown: false, latencyMs: 0, latencySource: 'none',
          currentRate: 48000, currentChannels: 2, currentBufferFrames: 0,
          bitPerfectCapable: false, supportsHog: false, dsd: 'none' }
      ]
    });

    // 设置页是**按需渲染**的：不先打开，sp_device 根本不在 DOM 里。
    await s.eval("(function(){ if (typeof openSettingsTab === 'function') openSettingsTab('out'); return 1; })()");
    await ub.sleep(200);

    await s.eval(`(function(){
      window.__sig = {
        ok: true,
        path: {
          src: 'x.flac', codec: 'flac', inRate: 44100, inBits: 16, inCh: 2, dur: 10,
          cueStart: -1, cueEnd: -1, fileDur: 10, note: '', outRate: 44100, outBits: 16, outCh: 2,
          device: 'Living Room', deviceId: '22', transport: 'airplay', sharedOnly: true,
          latencyKnown: true, latencyMs: 312.5, latencySource: 'CoreAudio',
          resample: false, twoStage: false, taps: 0, filter: 'Kaiser sinc', phaseCode: 'linear',
          gpuAvailable: false, phase: '线性相位', shaper: 'none', loudness: false, volume: 0,
          buffer: 100, dsd: 0, dsdRate: 0, modFamily: '', modOrder: 0, ispPeak: 0, ispOver: 0,
          preAtten: 0, atten: 0, conv: false, irGpu: false, gpuVendor: '', gpuStatus: '',
          volRamp: 0, bits: 16, srcBits: 16, eq: false, directSdm: false,
          bitPerfect: 'no', bitPerfectWhy: 'AirPlay 网络传输（系统混音 + 重封装，端到端逐位未获验证）'
        }
      };
      window.api = function(u){
        if (u && u.indexOf('/api/signal') === 0) return Promise.resolve(window.__sig);
        return Promise.resolve(${devJson});
      };
      window.loadDeviceList();
      return 1;
    })()`);
    await ub.sleep(200);
    const html = await s.eval("document.getElementById('sp_device').innerHTML");

    ck(/Living Room/.test(html) && /AirPlay/.test((html.split('Living Room')[1] || '').split('</option>')[0]),
       'U1 名字无 AirPlay 但 transport=airp 的设备被标出 AirPlay');
    const usbOpt = (html.match(/<option[^>]*>AirPlay Test Dummy USB[\s\S]*?<\/option>/) || [''])[0];
    ck(!!usbOpt && !/·\s*AirPlay/.test(usbOpt.replace('AirPlay Test Dummy USB', '')),
       'U1 名字含 AirPlay 的 USB 设备没有被误标 AirPlay', usbOpt.slice(0, 100));
    ck(/313\s*ms/.test(html), 'U2 延迟显示的是系统属性值 312.5ms → 313ms');
    ck(!/2000\s*ms|2\s*秒|2s\b/.test(html), 'U2 没有写死的 2 秒伪延迟');
    const bedOpt = (html.match(/<option[^>]*>Bedroom[\s\S]*?<\/option>/) || [''])[0];
    ck(/延迟未知/.test(bedOpt), 'U3 latencyKnown=false 时显示"延迟未知"而不是编造数值', bedOpt.slice(0, 100));

    // ---- U4：真实 showChain 在 AirPlay 信号链下的输出节点 ----
    await s.eval("(function(){ if (typeof showChain === 'function') { showChain(); } return 1; })()");
    await ub.sleep(300);
    const chain = await s.eval("(document.getElementById('mbody')||document.body).innerText");

    ck(/AirPlay/.test(chain), 'U4 信号链输出节点写明 AirPlay', (chain || '').slice(0, 140).replace(/\n/g, ' | '));
    ck(/非 Bit-Perfect|非\s*bit-perfect|未获验证/.test(chain), 'U4 明确标注非 bit-perfect / 端到端未获验证');
    ck(/313\s*ms|延迟未知/.test(chain), 'U4 信号链延迟来自系统属性或明确标未知');

    // ---- U5：不得凭空提供多房间分组入口 ----
    const body = await s.eval('document.body.innerText');
    ck(!/多房间|添加分组|group.*speaker/i.test(body), 'U5 页面没有虚构的 AirPlay 多房间/分组入口');
  } finally {
    await s.close();
  }
  console.log(`\n=== 结果：${total} 项，${fail} 失败 ===`);
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => { console.error('FATAL', e && e.stack || e); process.exit(2); });
