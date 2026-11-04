// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_airplay_ui.js — 1.1.2 AirPlay UI 纯 Node.js 逻辑断言测试
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

// 1. 读取生产源码 src/net/ui_script.h 并抽取生产 JS
const uiScriptPath = path.resolve(__dirname, '../src/net/ui_script.h');
assert(fs.existsSync(uiScriptPath), `ui_script.h must exist at ${uiScriptPath}`);
const scriptContent = fs.readFileSync(uiScriptPath, 'utf8');
const match = scriptContent.match(/return R"JS\(([\s\S]*?)\)JS";/);
assert(match && match[1], 'Failed to extract JS from ui_script.h');
const prodJs = match[1];

let totalTests = 0;
let passedTests = 0;
let failedTests = 0;

function check(desc, cond, extra) {
  totalTests++;
  if (cond) {
    passedTests++;
    console.log(`  [PASS] ${desc}`);
  } else {
    failedTests++;
    console.error(`  [FAIL] ${desc} ${extra ? JSON.stringify(extra) : ''}`);
  }
}

function createMockElement(id) {
  const el = {
    id: id || '',
    value: '',
    textContent: '',
    innerHTML: '',
    title: '',
    checked: false,
    disabled: false,
    tagName: 'DIV',
    style: {},
    classList: {
      _classes: new Set(),
      add(c) { this._classes.add(c); },
      remove(c) { this._classes.delete(c); },
      contains(c) { return this._classes.has(c); },
      toggle(c, force) {
        if (force === undefined) {
          if (this._classes.has(c)) this._classes.delete(c);
          else this._classes.add(c);
        } else if (force) {
          this._classes.add(c);
        } else {
          this._classes.delete(c);
        }
      }
    },
    options: [],
    setAttribute(k, v) { this[k] = v; },
    getAttribute(k) { return this[k] || null; },
    removeAttribute(k) { delete this[k]; },
    addEventListener() {},
    removeEventListener() {},
    appendChild() {},
    insertBefore() {},
    removeChild() {},
    querySelector() { return null; },
    querySelectorAll() { return []; },
    closest() { return null; }
  };
  return el;
}

class MockObserver {
  constructor() {}
  observe() {}
  disconnect() {}
  unobserve() {}
}

function createEnvironment(apiHandler) {
  const elements = {};
  function getEl(id) {
    if (!elements[id]) elements[id] = createMockElement(id);
    return elements[id];
  }

  const toasts = [];

  const sandbox = {
    console: {
      log() {},
      warn() {},
      error() {}
    },
    setTimeout(fn) { return 1; },
    clearTimeout() {},
    setInterval() { return 1; },
    clearInterval() {},
    Date,
    Math,
    parseInt,
    parseFloat,
    String,
    Number,
    Boolean,
    Array,
    Object,
    RegExp,
    JSON,
    Promise,
    encodeURIComponent,
    decodeURIComponent,
    addEventListener() {},
    removeEventListener() {},
    MutationObserver: MockObserver,
    IntersectionObserver: MockObserver,
    ResizeObserver: MockObserver,
    Event: class { constructor(type) { this.type = type; } },
    fetch(url, opt) {
      if (apiHandler) {
        const res = apiHandler(url, opt);
        if (res !== undefined) return Promise.resolve({ ok: true, json: () => Promise.resolve(res) });
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve({}) });
    },
    document: {
      getElementById: getEl,
      querySelector(sel) {
        if (sel === '#setpage .trimgrid') return getEl('trimgrid');
        return null;
      },
      querySelectorAll() { return []; },
      createElement(tag) {
        const el = createMockElement(tag);
        el.tagName = String(tag).toUpperCase();
        return el;
      },
      createTextNode(t) { return { textContent: t }; },
      addEventListener() {},
      removeEventListener() {},
      documentElement: { classList: { add() {} }, dataset: { lang: 'zh' } },
      body: { appendChild() {} },
      head: { appendChild() {} }
    },
    location: { href: 'http://localhost/', reload() {} },
    localStorage: { getItem() { return null; }, setItem() {} },
    sessionStorage: { getItem() { return null; }, setItem() {}, removeItem() {} }
  };

  sandbox.window = sandbox;

  const ctx = vm.createContext(sandbox);
  vm.runInContext(prodJs, ctx);

  // 截获 toast 便于断言
  const origToast = sandbox.toast;
  sandbox.toast = function (msg) {
    toasts.push(msg);
    if (typeof origToast === 'function') origToast(msg);
  };
  sandbox._toasts = toasts;
  sandbox._getEl = getEl;

  return sandbox;
}

async function runTests() {
  console.log('=== RLPlayer 1.1.2 AirPlay UI Node.js 生产逻辑验证 ===\n');

  // Test 1: 默认 AirPlay（正确通过 isDefault / default 识别并在默认项中展示）
  {
    console.log('-- Test 1: 默认 AirPlay --');
    const devicesResponse = {
      ok: true,
      devices: [
        {
          id: 'dev-airplay-1',
          name: 'Living Room HomePod',
          default: true,
          isDefault: true,
          channels: 2,
          mixRate: 44100,
          transport: 'airplay',
          transportType: 1634038384,
          sharedOnly: true,
          latencyKnown: true,
          latencyMs: 312.5,
          latencySource: 'CoreAudio: 8800 frames'
        },
        {
          id: 'dev-usb-1',
          name: 'DAC USB',
          default: false,
          isDefault: false,
          channels: 2,
          mixRate: 192000,
          transport: 'usb',
          transportType: 1969841184,
          sharedOnly: false,
          latencyKnown: true,
          latencyMs: 12.0
        }
      ]
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/devices')) return devicesResponse;
      if (url.startsWith('/api/rates')) return { rates: [44100] };
    });

    env.ADV.device = ''; // 选择默认设备
    await env.loadDeviceList();

    const dev = env.devMixOf('');
    check('默认设备解析到 isDefault 设备', dev && dev.id === 'dev-airplay-1', dev);
    check('默认设备 transport 为 airplay', dev && dev.transport === 'airplay', dev && dev.transport);
    check('isAirPlayDevice 判定默认设备为真', env.isAirPlayDevice(dev) === true);

    const sel = env._getEl('sp_device');
    check('设备下拉第一个默认选项包含 AirPlay 标注', sel.innerHTML.includes('默认设备  ·  AirPlay'), sel.innerHTML);
    check('默认选项包含具体属性延迟 313ms', sel.innerHTML.includes('313ms'), sel.innerHTML);
    check('默认选项不包含写死的 2000ms 或 2s', !/2000\s*ms|2\s*秒|2s\b/.test(sel.innerHTML));
  }

  // Test 2: 显式 USB
  {
    console.log('\n-- Test 2: 显式 USB --');
    const devicesResponse = {
      ok: true,
      devices: [
        {
          id: 'dev-usb-main',
          name: 'Audiophile USB DAC',
          default: false,
          channels: 2,
          mixRate: 384000,
          transport: 'usb',
          sharedOnly: false,
          latencyKnown: true,
          latencyMs: 8.5
        }
      ]
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/devices')) return devicesResponse;
      if (url.startsWith('/api/rates')) return { rates: [44100, 96000, 192000, 384000] };
    });

    env.ADV.device = 'dev-usb-main';
    await env.loadDeviceList();

    const dev = env.devMixOf('dev-usb-main');
    check('显式 USB 设备 transport 为 usb', dev && dev.transport === 'usb');
    check('isAirPlayDevice 对 USB 设备返回 false', env.isAirPlayDevice(dev) === false);

    const sel = env._getEl('sp_device');
    const optUsb = (sel.innerHTML.match(/<option[^>]*value="dev-usb-main"[^>]*>[\s\S]*?<\/option>/) || [''])[0];
    check('USB 设备选项不包含 AirPlay 标签', optUsb && !optUsb.includes('AirPlay'), optUsb);

    const hog = env._getEl('sp_hogexcl');
    check('USB 设备时严格独占 (Hog) 控件不被禁用', hog.disabled === false);
  }

  // Test 3: 同名本地非 AirPlay（名称带 AirPlay 但 transport 为 usb）
  {
    console.log('\n-- Test 3: 同名本地非 AirPlay --');
    const devicesResponse = {
      ok: true,
      devices: [
        {
          id: 'dev-fake-airplay-name',
          name: 'AirPlay USB Test Rig Audio Interface',
          default: false,
          channels: 2,
          mixRate: 96000,
          transport: 'usb',
          sharedOnly: false,
          latencyKnown: true,
          latencyMs: 15.0
        }
      ]
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/devices')) return devicesResponse;
    });

    env.ADV.device = 'dev-fake-airplay-name';
    await env.loadDeviceList();

    const dev = env.devMixOf('dev-fake-airplay-name');
    check('名字含 AirPlay 但 transport 为 usb 的设备被正确归为 usb', dev && dev.transport === 'usb');
    check('isAirPlayDevice 仅以 transport 判定，绝不按名字误判', env.isAirPlayDevice(dev) === false);

    const sel = env._getEl('sp_device');
    const opt = (sel.innerHTML.match(/<option[^>]*value="dev-fake-airplay-name"[^>]*>[\s\S]*?<\/option>/) || [''])[0];
    // 扣除名字本身后，不含 "· AirPlay" 标注
    const cleanOpt = opt.replace('AirPlay USB Test Rig Audio Interface', '');
    check('选项中未追加 · AirPlay 标签', !/·\s*AirPlay/.test(cleanOpt), opt);
  }

  // Test 4: 未知延迟
  {
    console.log('\n-- Test 4: 未知延迟 --');
    const devicesResponse = {
      ok: true,
      devices: [
        {
          id: 'dev-airplay-unk-lat',
          name: 'Apple TV Living Room',
          default: false,
          channels: 2,
          mixRate: 48000,
          transport: 'airplay',
          sharedOnly: true,
          latencyKnown: false,
          latencyMs: null,
          latencySource: ''
        }
      ]
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/devices')) return devicesResponse;
    });

    env.ADV.device = 'dev-airplay-unk-lat';
    await env.loadDeviceList();

    const sel = env._getEl('sp_device');
    check('latencyKnown 为 false 时明确标明“延迟未知”', sel.innerHTML.includes('延迟未知'), sel.innerHTML);
    check('不编造数值或 2 秒', !/2000\s*ms|2\s*秒|2s\b/.test(sel.innerHTML));

    const text = env.devMixText('dev-airplay-unk-lat');
    check('devMixText 亦标明“延迟未知”', text.includes('延迟未知'), text);
  }

  // Test 5: 已知非 2s 延迟与来源说明
  {
    console.log('\n-- Test 5: 已知非 2s 延迟与来源说明 --');
    const devicesResponse = {
      ok: true,
      devices: [
        {
          id: 'dev-airplay-known',
          name: 'HomePod Mini Stereo Pair',
          default: false,
          channels: 2,
          mixRate: 44100,
          transport: 'airplay',
          sharedOnly: true,
          latencyKnown: true,
          latencyMs: 428.4,
          latencySource: 'CoreAudio: device: 512, stream: 18400 frames'
        }
      ]
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/devices')) return devicesResponse;
    });

    env.ADV.device = 'dev-airplay-known';
    await env.loadDeviceList();

    const sel = env._getEl('sp_device');
    check('显示四舍五入系统上报延迟 428ms', sel.innerHTML.includes('428ms'), sel.innerHTML);
    check('无固定 2000ms 假数据', !/2000\s*ms|2\s*秒|2s\b/.test(sel.innerHTML));

    const text = env.devMixText('dev-airplay-known');
    check('devMixText 包含延迟毫秒与真实来源说明', text.includes('428 ms') && text.includes('CoreAudio: device: 512'), text);
  }

  // Test 6: 多声道字段完整保留与格式化
  {
    console.log('\n-- Test 6: 多声道字段 --');
    const devicesResponse = {
      ok: true,
      devices: [
        {
          id: 'dev-multich',
          name: 'Surround Setup',
          default: false,
          channels: 6,
          mixRate: 96000,
          currentChannels: 6,
          currentRate: 96000,
          transport: 'usb',
          sharedOnly: false,
          latencyKnown: true,
          latencyMs: 10.0
        }
      ]
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/devices')) return devicesResponse;
    });

    env.ADV.device = 'dev-multich';
    await env.loadDeviceList();

    const dev = env.devMixOf('dev-multich');
    check('DEVMIX 正确保存 channels = 6', dev && dev.channels === 6);
    check('DEVMIX 正确保存 mixRate = 96000', dev && dev.mixRate === 96000);

    const sel = env._getEl('sp_device');
    check('下拉选项格式化包含 6ch/96k', sel.innerHTML.includes('6ch/96k'), sel.innerHTML);

    const devText = env.devMixText('dev-multich');
    check('devMixText 包含“6 声道 · 96000 Hz”', devText.includes('6 声道') && devText.includes('96000 Hz'), devText);
  }

  // Test 7: 刷新保留消失设备且不错误回退到默认
  {
    console.log('\n-- Test 7: 刷新保留消失设备且不错误回退 --');
    let currentList = [
      {
        id: 'dev-living-room',
        name: 'Living Room AirPlay',
        default: false,
        transport: 'airplay',
        channels: 2,
        mixRate: 44100
      },
      {
        id: 'dev-builtin',
        name: 'MacBook Pro 扬声器',
        default: true,
        isDefault: true,
        transport: 'builtin',
        channels: 2,
        mixRate: 48000
      }
    ];

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/devices')) return { ok: true, devices: currentList };
    });

    // 初始加载并选择 Living Room
    await env.loadDeviceList();
    const sel = env._getEl('sp_device');
    sel.value = 'dev-living-room';
    if (sel.onchange) sel.onchange();

    check('用户初始选中 dev-living-room', env.ADV.device === 'dev-living-room');

    // 设备消失：网络断开或休眠，/api/devices 仅剩 MacBook 扬声器
    currentList = [
      {
        id: 'dev-builtin',
        name: 'MacBook Pro 扬声器',
        default: true,
        isDefault: true,
        transport: 'builtin',
        channels: 2,
        mixRate: 48000
      }
    ];

    // 触发刷新（已有刷新按钮或后端变化）
    await env.loadDeviceList(true);

    check('设备消失后 ADV.device 严禁被静默清空或改回默认设备', env.ADV.device === 'dev-living-room');
    check('sp_device 下拉保留消失设备且标记（不可用）', sel.innerHTML.includes('dev-living-room') && sel.innerHTML.includes('（不可用）'), sel.innerHTML);
    check('下拉控件 value 仍指向消失设备 ID', sel.value === 'dev-living-room');

    // 设备恢复上线
    currentList.push({
      id: 'dev-living-room',
      name: 'Living Room AirPlay',
      default: false,
      transport: 'airplay',
      channels: 2,
      mixRate: 44100
    });

    await env.loadDeviceList(true);
    check('设备上线后依然保持选中', env.ADV.device === 'dev-living-room' && sel.value === 'dev-living-room');
    check('恢复上线后（不可用）标记自动移除', !sel.innerHTML.includes('（不可用）'), sel.innerHTML);
  }

  // Test 8: 无 processing / idle 时不继承旧 AirPlay 状态
  {
    console.log('\n-- Test 8: 空闲/停止时不继承旧 AirPlay 状态 --');
    let statusResponse = {
      ok: true,
      playing: true,
      paused: false,
      current: '/Music/track.flac',
      dur: 180,
      pos: 10,
      transport: 'airplay',
      sharedOnly: true,
      bitPerfect: 'no',
      bitPerfectWhy: 'AirPlay 传输（端到端未获验证）'
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/status')) return statusResponse;
    });

    // 播放中收到 AirPlay 状态
    await env.tick();
    let bp = env.bpBadgeInfo();
    check('播放中正确反映 AirPlay 非 bit-perfect 状态', bp.cls === 'bp-no' && bp.text === '非 bit-perfect');

    // 播放结束 / 停止 / idle：无 processing，current 为空，playing 为 false
    statusResponse = {
      ok: true,
      playing: false,
      paused: false,
      current: '',
      dur: 0,
      pos: 0,
      transport: '',
      bitPerfect: '',
      bitPerfectWhy: ''
    };

    await env.tick();
    bp = env.bpBadgeInfo();
    check('空闲状态时不继承上一曲的 AirPlay 非 bit-perfect，干净回到待播放验证', bp.cls === 'bp-idle' && bp.text === '待播放验证', bp);
  }

  // Test 9: AirPlay 约束 Hog 与 DSD/DoP 输出（不偷偷覆盖用户本地设置，DSD PCM 允许，DoP/Native 拒绝）
  {
    console.log('\n-- Test 9: UI 约束与 DSD/DoP 处理规则 --');
    const env = createEnvironment((url, opt) => {
      if (url.startsWith('/api/devices')) {
        return {
          ok: true,
          devices: [
            { id: 'ap-1', name: 'HomePod', default: true, isDefault: true, transport: 'airplay', sharedOnly: true }
          ]
        };
      }
      if (url.startsWith('/api/play')) {
        return { ok: true };
      }
    });

    env.ADV.device = 'ap-1';
    env.ADV.hogExclusive = 1; // 用户本地设置开启严格独占
    await env.loadDeviceList();

    const hog = env._getEl('sp_hogexcl');
    check('AirPlay 选中时严格独占 (Hog) 控件被禁用', hog.disabled === true);
    check('用户的本地设置 ADV.hogExclusive 未被悄悄清零', env.ADV.hogExclusive === 1);

    // Case 9.1: DSD 文件 + PCM 输出模式 -> 允许播放（不因扩展名一刀切拒绝）
    env._getEl('sDSD').value = '0'; // PCM 模式
    env._toasts.length = 0;
    const playResPcm = await env.playPath('/Music/album/track.dsf');
    check('DSD 文件在 PCM 输出模式下允许开流播放', playResPcm && playResPcm.ok !== false);
    check('未触发 DoP 拒绝提示', !env._toasts.some(t => t.includes('不支持 DoP')));

    // Case 9.2: DSD 文件 + DoP 输出模式 -> 提示拒绝
    env._getEl('sDSD').value = 'dop64'; // DoP 模式
    env._toasts.length = 0;
    const playResDop = await env.playPath('/Music/album/track.dsf');
    check('DSD 文件在 DoP 模式下向 AirPlay 播放被拒绝', playResDop && playResDop.ok === false);
    check('弹出明确的 DoP 拒绝提示', env._toasts.some(t => t.includes('不支持 DoP')), env._toasts);
  }

  // Test 10: 信号链与多房间承诺边界
  {
    console.log('\n-- Test 10: 信号链与多房间边界 --');
    const env = createEnvironment((url) => {
      if (url.startsWith('/api/signal')) {
        return {
          ok: true,
          path: {
            src: 'sym.flac',
            codec: 'flac',
            inRate: 44100,
            inBits: 16,
            inCh: 2,
            outRate: 44100,
            outBits: 16,
            outCh: 2,
            device: 'Dining Room',
            transport: 'airplay',
            sharedOnly: true,
            latencyKnown: true,
            latencyMs: 250.0,
            latencySource: 'CoreAudio stream',
            bitPerfect: 'no',
            bitPerfectWhy: 'AirPlay 网络传输与缓冲重封装，端到端 bit-perfect 未获验证'
          }
        };
      }
    });

    await env.showChain();
    const mbody = env._getEl('mbody');
    check('信号链包含 AirPlay 节点徽章', mbody.innerHTML.includes('AirPlay'), mbody.innerHTML);
    check('信号链包含系统属性延迟说明', mbody.innerHTML.includes('系统属性延迟 250 ms'), mbody.innerHTML);
    check('信号链不含写死的 2000ms', !/2000\s*ms|2\s*秒|2s\b/.test(mbody.innerHTML));
    check('信号链标题声明 AirPlay 传输（端到端逐位未获验证）', mbody.innerHTML.includes('AirPlay 传输（端到端逐位未获验证）'));
  }

  // Test 11: AirPlay 投放状态与 Now Playing 状态契约
  {
    console.log('\n-- Test 11: AirPlay 投放状态契约与 seek 约束 --');
    const env = createEnvironment((url) => {
      if (url.startsWith('/api/status')) {
        return {
          ok: true,
          castMode: true,
          castPhase: 'connecting',
          castDevice: 'airplay://192.168.1.50:5000',
          playing: true,
          paused: false,
          current: '/Music/demo.flac',
          dur: 200,
          pos: 0,
          outRate: 44100,
          outBits: 16,
          outMode: 'airplay',
          transport: 'airplay'
        };
      }
    });

    await env.tick();
    const nps = env._getEl('nps');
    check('AirPlay 投放 connecting 期间顶栏显示“设备连接中”，不显示“已停止”', nps.textContent.includes('设备连接中') && !nps.textContent.includes('已停止'));

    const seekEl = env._getEl('seek');
    check('AirPlay 投放时 seek 控件 title 标明暂不支持拖动', seekEl.title.includes('AirPlay 投放暂不支持拖动进度'));

    env._toasts.length = 0;
    env.doSeek(0.2);
    check('AirPlay 投放时 doSeek 提示暂不支持拖动', env._toasts.some(t => t.includes('AirPlay 投放暂不支持拖动进度')));
  }

  console.log(`\n==============================================`);
  console.log(`总断言: ${totalTests} | 通过: ${passedTests} | 失败: ${failedTests}`);
  console.log(`==============================================\n`);

  process.exit(failedTests === 0 ? 0 : 1);
}

runTests().catch(err => {
  console.error('FATAL ERROR in test_airplay_ui:', err);
  process.exit(2);
});
