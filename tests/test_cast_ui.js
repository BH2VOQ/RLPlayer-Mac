// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_cast_ui.js — 1.1.2 Cast UI & State Contract 纯 Node.js 逻辑断言与回归测试
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
    type: (id === 'cast_up' || id === 'sLoud' || id === 'sp_loud' || id === 'sShuf' || id === 'sp_shuf') ? 'checkbox' : '',
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
    addEventListener(evt, fn) {
      if (!this._listeners) this._listeners = {};
      if (!this._listeners[evt]) this._listeners[evt] = [];
      this._listeners[evt].push(fn);
    },
    removeEventListener(evt, fn) {
      if (!this._listeners || !this._listeners[evt]) return;
      this._listeners[evt] = this._listeners[evt].filter(f => f !== fn);
    },
    dispatchEvent(event) {
      if (this._listeners && this._listeners[event.type]) {
        for (const fn of this._listeners[event.type]) fn(event);
      }
      if (typeof this['on' + event.type] === 'function') {
        this['on' + event.type](event);
      }
    },
    click() {
      this.dispatchEvent({ type: 'click', preventDefault() {} });
    },
    appendChild() {},
    insertBefore() {},
    removeChild() {},
    querySelector(sel) {
      if (sel === 'svg') return createMockElement('svg');
      return null;
    },
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
    requestAnimationFrame(fn) { return setTimeout(fn, 0); },
    cancelAnimationFrame(id) { clearTimeout(id); },
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
        if (sel === '#setpage .spane[data-g=out]') return getEl('spane_out');
        if (sel === '#setpage .spane[data-g=stream]') return getEl('spane_stream');
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
  console.log('=== RLPlayer 1.1.2 Cast UI & State Contract 逻辑与回归测试 ===\n');

  // Test 1: 原 BUG 复现与修复验证（connecting/decoding 阶段不提前谎报已推送到，更不显示已停止/0:00/播放图标）
  {
    console.log('-- Test 1: 原 BUG 场景验证 (Connecting/Decoding 与 Playing 隔离) --');
    let statusResponse = {
      ok: true,
      castMode: true,
      castPhase: 'connecting',
      castDevice: 'airplay://192.168.1.100:5000',
      playing: true,
      paused: false,
      current: '/Music/symphony.flac',
      dur: 300,
      pos: 0,
      outRate: 44100,
      outBits: 16,
      outMode: 'airplay',
      transport: 'airplay',
      bitPerfect: 'no',
      bitPerfectWhy: 'AirPlay 投放：重采样为 44100 Hz / 16 bit ALAC 传输，非 bit-perfect'
    };

    const env = createEnvironment((url, opt) => {
      if (url.startsWith('/api/status')) return statusResponse;
      if (url.startsWith('/api/cast/state')) {
        return {
          ok: true,
          running: true,
          phase: 'connecting',
          device: 'airplay://192.168.1.100:5000',
          sourceFile: '/Music/symphony.flac',
          positionSec: 0,
          durationSec: 300,
          transportState: 'STOPPED'
        };
      }
    });

    // 触发 connecting 状态
    await env.tick();
    const nps = env._getEl('nps');
    check('Connecting 阶段顶栏状态显示“设备连接中”，绝不显示“已停止”', nps.textContent.includes('设备连接中') && !nps.textContent.includes('已停止'), nps.textContent);

    const playIcon = env._getEl('icP');
    check('连接/推流中底栏按钮保持为暂停图标（非播放三角图标）', playIcon['d'] && playIcon['d'].includes('M7 5h4v14H7zM13 5h4v14h-4z'));

    // 测试 decoding 阶段
    statusResponse.castPhase = 'decoding';
    await env.tick();
    check('Decoding 阶段顶栏状态显示“音频解码中”，绝不显示“已停止”', nps.textContent.includes('音频解码中') && !nps.textContent.includes('已停止'), nps.textContent);

    // 测试 applyCastUi 在 connecting 状态下的按钮文案
    env.applyCastUi({
      running: true,
      phase: 'connecting',
      device: 'airplay://192.168.1.100:5000'
    });
    const npBtn = env._getEl('npCastBtn');
    check('Connecting 阶段按钮文案为“正在连接”，绝不提前标注“已推送到”', npBtn.innerHTML.includes('正在连接') && !npBtn.innerHTML.includes('已推送到'), npBtn.innerHTML);

    // 转换为 playing 阶段
    statusResponse.castPhase = 'playing';
    statusResponse.pos = 12.5;
    await env.tick();
    check('Playing 阶段顶栏状态显示“投放播放中”', nps.textContent.includes('投放播放中'), nps.textContent);

    env.applyCastUi({
      running: true,
      phase: 'playing',
      device: 'airplay://192.168.1.100:5000'
    });
    check('真正 Playing 阶段按钮文案才正式变为“已推送到”', npBtn.innerHTML.includes('已推送到'), npBtn.innerHTML);
  }

  // Test 2: 完整状态机生命周期与失败清理 (accepted -> connecting -> playing -> paused -> error/stopped -> replay)
  {
    console.log('\n-- Test 2: 完整状态机生命周期与失败清理 --');
    const devicesList = [
      { kind: 'airplay', friendlyName: 'Living Room HomePod', host: '192.168.1.55', port: 5000, location: 'airplay://192.168.1.55:5000' }
    ];

    let castStopped = false;
    const env = createEnvironment((url, opt) => {
      if (url.startsWith('/api/cast/devices')) {
        return { ok: true, devices: devicesList };
      }
      if (url.startsWith('/api/play')) {
        return { ok: true };
      }
      if (url.startsWith('/api/cast/stop')) {
        castStopped = true;
        return { ok: true, stopped: true };
      }
      if (url.startsWith('/api/cast/state')) {
        return {
          ok: true,
          running: !castStopped,
          phase: castStopped ? 'stopped' : 'playing',
          device: 'airplay://192.168.1.55:5000'
        };
      }
    });

    env.S.lastCur = '/Music/track1.flac';
    env.ADV.upnpDev = 'airplay://192.168.1.55:5000';
    env._castDevices = devicesList;

    // 1. 发起推送：模拟用户在设备选择弹窗中选中该设备
    env._toasts.length = 0;
    let pickedCb = null;
    env.npPickCastDevice = function(cb) { pickedCb = cb; };
    env.castPush('/Music/track1.flac');
    check('castPush 弹窗前不提前假装推送完成', env._toasts.length === 0);

    pickedCb('airplay://192.168.1.55:5000');
    check('选中设备发起时提示“正在推送到”，绝不虚假告知“已推送到”', env._toasts.some(t => t.includes('正在推送到')) && !env._toasts.some(t => t.includes('已推送到')), env._toasts);

    let npBtn = env._getEl('npCastBtn');
    let badge = env._getEl('castBadge');
    check('发起时按钮进入 on 状态且提示“正在连接”', npBtn.classList.contains('on') && npBtn.innerHTML.includes('正在连接'), npBtn.innerHTML);
    check('发起时徽章处于显示状态且标注为 AirPlay', badge.style.display === 'inline-flex' && badge.textContent === 'AirPlay', badge);

    // 2. 模拟失败 (error)
    env.applyCastUi({
      running: false,
      phase: 'error',
      error: 'AirPlay 连接握手失败: 453',
      device: 'airplay://192.168.1.55:5000'
    });

    check('失败时按钮重置为“推送到设备”并移除 on 类', !npBtn.classList.contains('on') && npBtn.innerHTML.includes('推送到设备'), npBtn.innerHTML);
    check('失败时徽章被干净隐藏，杜绝幽灵/残留徽标', badge.style.display === 'none', badge.style.display);

    // 3. 再次发起并成功进入 playing
    env.applyCastUi({
      running: true,
      phase: 'playing',
      device: 'airplay://192.168.1.55:5000'
    });
    check('播放中按钮点亮并显示“已推送到”', npBtn.classList.contains('on') && npBtn.innerHTML.includes('已推送到'), npBtn.innerHTML);
    check('播放中徽章显示并标注为 AirPlay', badge.style.display === 'inline-flex' && badge.textContent === 'AirPlay');

    // 4. 停止投放 (castStop)
    await env.castStop();
    check('停止投放后按钮复位', !npBtn.classList.contains('on') && npBtn.innerHTML.includes('推送到设备'), npBtn.innerHTML);
    check('停止投放后徽章隐藏', badge.style.display === 'none');
  }

  // Test 3: AirPlay 进度拖动禁止与明确提示（不谎称成功）
  {
    console.log('\n-- Test 3: AirPlay 进度拖动约束（明确提示而非伪成功） --');
    let seekCalled = false;
    const env = createEnvironment((url) => {
      if (url.startsWith('/api/seek')) {
        seekCalled = true;
        return { ok: false, error: 'AirPlay 投放暂不支持拖动进度', airplay: true };
      }
    });

    env.CAST.state = {
      running: true,
      phase: 'playing',
      device: 'airplay://192.168.1.100:5000'
    };
    env.S.dur = 240;
    env.S.pos = 30;

    env._toasts.length = 0;
    env.doSeek(0.5);

    check('AirPlay 投放中进行 doSeek 弹出明确不支持提示', env._toasts.some(t => t.includes('AirPlay 投放暂不支持拖动进度')), env._toasts);
    check('AirPlay 投放中 doSeek 不发送伪 /api/seek 请求', seekCalled === false);

    // 测试 UPnP 模式下允许正常 seek
    env.CAST.state.device = 'http://192.168.1.80:8080/description.xml';
    seekCalled = false;
    env.doSeek(0.5);
    check('UPnP 投放模式下正常调用 /api/seek', seekCalled === true);
  }

  // Test 4: 离线旧 IP / 消失设备在下拉与浮层中的处理
  {
    console.log('\n-- Test 4: 离线旧 IP / 消失设备重新选择与刷新 --');
    const devicesList = [
      { kind: 'airplay', friendlyName: 'Bedroom Speaker', host: '192.168.1.120', port: 5000, location: 'airplay://192.168.1.120:5000' }
    ];

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/cast/devices')) return { ok: true, devices: devicesList };
    });

    // 曾经保存的旧设备（DHCP 换了 IP 后的旧 IP）
    env.ADV.upnpDev = 'airplay://192.168.1.44:5000';
    env._castDevices = devicesList;
    env.populateCastDevices();

    const devSelect = env._getEl('sp_cast_dev');
    check('下拉中保存的失效旧设备标注“离线/需刷新”', devSelect.innerHTML.includes('离线/需刷新') && devSelect.innerHTML.includes('192.168.1.44'), devSelect.innerHTML);

    // 唤起浮层 npPickCastDevice
    let selectedDev = '';
    env.npPickCastDevice((d) => { selectedDev = d; });
    const modalBody = env._getEl('mbody');
    check('弹窗提示失效旧设备当前未在线，提示重新选择并刷新', modalBody.innerHTML.includes('当前未在线，点击上方已发现设备即可重新选择并刷新'), modalBody.innerHTML);
  }

  // Test 5: /api/cast/state 中的音量字段支持
  {
    console.log('\n-- Test 5: /api/cast/state 音量字段支持 --');
    const statePayload = {
      ok: true,
      running: true,
      phase: 'playing',
      device: 'airplay://192.168.1.100:5000',
      volumeSupported: true,
      currentVolume: 75,
      lastVolumeError: ''
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/cast/state')) return statePayload;
    });

    env.applyCastUi(statePayload);
    check('CAST.state 正确接收 volumeSupported 字段', env.CAST.state.volumeSupported === true);
    check('CAST.state 正确接收 currentVolume 字段 (75)', env.CAST.state.currentVolume === 75);
  }

  // Test 6: 英文语言回退与一致性
  {
    console.log('\n-- Test 6: 英文界面下 AirPlay / Cast 翻译与一致性 --');
    const env = createEnvironment();
    env.document.documentElement.dataset.lang = 'en';

    // 验证 pMap 中的各个阶段在英文环境下有回退
    const pEl = env._getEl('sp_cast_stat_phase');
    env.updateCastStateUi({ running: true, phase: 'connecting' });
    check('英文或多语言环境下 connecting 正确展示', pEl.textContent.length > 0 && pEl.textContent !== '已停止');

    env.updateCastStateUi({ running: true, phase: 'decoding' });
    check('英文或多语言环境下 decoding 正确展示', pEl.textContent.length > 0 && pEl.textContent !== '已停止');
  }

  // Test 7: 1.1.3 UPnP 投放升频信号链与徽标证据契约测试
  {
    console.log('\n-- Test 7: 1.1.3 UPnP 投放升频信号链与徽标证据契约测试 --');

    // 场景 1: 开 + 生效 (resampled=true, upsampleApplied=true)
    {
      let signalPayload = {
        ok: true,
        path: {
          src: '/Music/track1.flac',
          codec: 'flac',
          inRate: 44100,
          inBits: 16,
          inCh: 2,
          dur: 180,
          outRate: 176400,
          outBits: 24,
          outCh: 2,
          device: 'http://192.168.1.80:8080/desc.xml',
          transport: 'upnp',
          outMode: 'upnp',
          resample: true,
          upsampleApplied: true,
          servedRate: 176400,
          filter: 'poly-sinc-lp',
          castDspBypass: true
        }
      };

      // 1.1.3 集成修（审阅 D）：**不许**手填 S.bpOutRate —— 那样会掩盖生产端 tick() 里
      // 漏赋值导致的「源 44100 → undefined Hz」。这里走真实轮询路径，让字段由 /api/status 解包。
      let statusPayload = {
        ok: true, castMode: true, castPhase: 'playing', playing: true, paused: false,
        current: '/Music/track1.flac', dur: 180, pos: 10,
        outRate: 176400, outBits: 24, inRate: 44100, resampled: true, dsd: 0,
        servedRate: 176400, servedBits: 24, upsampleApplied: true, upsampleNote: '',
        transport: 'upnp', outMode: 'upnp', bitPerfect: 'no'
      };
      const env = createEnvironment((url) => {
        if (url.startsWith('/api/signal')) return signalPayload;
        if (url.startsWith('/api/status')) return statusPayload;
      });

      await env.tick();               // 字段全部由生产解包代码填，测试不写死
      env.S.bpState = 'no';

      const badge = env.bpBadgeInfo();
      check('开+生效：底栏徽标显示“PCM-PCM 升频”', badge.text === 'PCM-PCM 升频', badge.text);
      check('开+生效：底栏徽标带升频自证说明', badge.title.includes('先在本机升频再供源'), badge.title);
      check('开+生效：悬停文案带出真实两端速率（不得出现 undefined）',
            badge.title.includes('44100 → 176400') && !badge.title.includes('undefined'), badge.title);

      await env.showChain();
      const mbody = env._getEl('mbody').innerHTML;
      check('开+生效：信号链节点显示“本机升频 44100 → 176400 Hz · poly-sinc-lp（投放供源）”',
            mbody.includes('本机升频 44100 → 176400 Hz · poly-sinc-lp（投放供源）'), mbody);

      // 场景 1b（1.1.3 集成补）：用户填的滤波器名与实际用的不同（后端发生回退）时，
      // 链条必须显示**实际用的** servedFilter —— 否则界面会把一个没被用上的名字当成事实。
      signalPayload.path.filter = 'poly-sinc-mp';        // 用户在设置里填的名字
      signalPayload.path.servedFilter = 'poly-sinc-lp';  // 后端真正使用的预设（回退后）
      await env.showChain();
      const mbody2 = env._getEl('mbody').innerHTML;
      check('生效但滤波器发生回退：链条显示实际使用的 poly-sinc-lp，而不是用户填的 poly-sinc-mp',
            mbody2.includes('本机升频 44100 → 176400 Hz · poly-sinc-lp（投放供源）') &&
            !mbody2.includes('poly-sinc-mp（投放供源）'), mbody2);

      // 场景 1c（审阅 D 发现）：AirPlay 固定 44100 Hz —— 96k 源是**降采样**，
      // 旧逻辑只要 resampled=true 就报「PCM-PCM 升频」，把降质说成升频。
      statusPayload = Object.assign({}, statusPayload, {
        transport: 'airplay', outMode: 'airplay', castDevice: 'airplay://192.168.1.100:5000',
        inRate: 96000, outRate: 44100, servedRate: 44100, resampled: true
      });
      await env.tick();
      env.S.bpState = 'no';
      const badgeDown = env.bpBadgeInfo();
      check('AirPlay 降采样：绝不显示「PCM-PCM 升频」', badgeDown.text !== 'PCM-PCM 升频', badgeDown.text);
      check('AirPlay 降采样：徽标如实显示「PCM 降采样」', badgeDown.text === 'PCM 降采样', badgeDown.text);
      check('开+生效：信号链节点带“PCM-PCM 升频”徽章', mbody.includes('PCM-PCM 升频'), mbody);
    }

    // 场景 2: 被压回 (后端返回 upsampleApplied=false + note 含「被渲染器上限压到」)
    {
      let signalPayload = {
        ok: true,
        path: {
          src: '/Music/track2.flac',
          codec: 'flac',
          inRate: 44100,
          inBits: 16,
          inCh: 2,
          dur: 200,
          outRate: 44100,
          outBits: 16,
          outCh: 2,
          device: 'http://192.168.1.80:8080/desc.xml',
          transport: 'upnp',
          outMode: 'upnp',
          resample: false,
          upsampleApplied: false,
          upsampleNote: '本机升频被渲染器上限压到 96000 Hz',
          castDspBypass: true
        }
      };

      const env = createEnvironment((url) => {
        if (url.startsWith('/api/signal')) return signalPayload;
      });

      env.S.bpState = 'no';
      env.S.bpTransport = 'upnp';
      env.S.bpOutMode = 'upnp';
      env.S.bpResampled = false;

      const badge = env.bpBadgeInfo();
      check('被压回：底栏徽标为“非 bit-perfect”，绝不冒充升频', badge.text === '非 bit-perfect', badge.text);

      await env.showChain();
      const mbody = env._getEl('mbody').innerHTML;
      check('被压回：信号链节点出现 note 原文“被渲染器上限压到 96000 Hz”',
            mbody.includes('本机升频被渲染器上限压到 96000 Hz'), mbody);
      check('被压回：信号链节点徽章为“投放旁路”，绝不显示“PCM-PCM 升频”',
            mbody.includes('投放旁路') && !mbody.includes('PCM-PCM 升频'), mbody);
    }

    // 场景 3: 关闭 (负向对照：不许回归)
    {
      let signalPayload = {
        ok: true,
        path: {
          src: '/Music/track3.flac',
          codec: 'flac',
          inRate: 44100,
          inBits: 16,
          inCh: 2,
          dur: 150,
          outRate: 44100,
          outBits: 16,
          outCh: 2,
          device: 'http://192.168.1.80:8080/desc.xml',
          transport: 'upnp',
          outMode: 'upnp',
          resample: false,
          upsampleApplied: false,
          requestedRate: 'max',
          castDspBypass: true
        }
      };

      const env = createEnvironment((url) => {
        if (url.startsWith('/api/signal')) return signalPayload;
      });

      await env.showChain();
      const mbody = env._getEl('mbody').innerHTML;
      check('关闭：保持原有“投放旁路”徽章与“旁路（投放不经过本机 DSP…”文案一字不改',
            mbody.includes('投放旁路') && mbody.includes('旁路（投放不经过本机 DSP：升频/EQ/IR/音量都不参与；你的设置要求升频（最高），但投放不走这条链）'), mbody);
      check('关闭：绝不显示升频徽章', !mbody.includes('PCM-PCM 升频'), mbody);
    }
  }

  // Test 8: 设置页投放升频控件契约 (cast_up, cast_ceil, SET_KEYS)
  {
    console.log('\n-- Test 8: 设置页投放升频控件与 SET_KEYS 契约 --');
    let lastSavedBody = '';
    const env = createEnvironment((url, opt) => {
      if (url === '/api/settings' && opt && opt.body) {
        lastSavedBody = opt.body;
        return { ok: true };
      }
    });

    env.renderSettingsPage();
    const chkUp = env._getEl('cast_up');
    const selCeil = env._getEl('cast_ceil');
    check('设置页存在 cast_up 开关控件', chkUp !== null && chkUp.id === 'cast_up');
    check('设置页存在 cast_ceil 上限下拉控件', selCeil !== null && selCeil.id === 'cast_ceil');
    check('cast_up 默认状态为关闭 (checked=false)', chkUp.checked === false);
    check('cast_ceil 默认上限为 192000', selCeil.value === '192000' || selCeil.value === '');

    // 勾选 cast_up 并保存
    chkUp.checked = true;
    chkUp.dispatchEvent({ type: 'change' });
    env.saveSettings(true);
    check('勾选 cast_up 后 saveSettings 包含 cast_upsample=1', lastSavedBody.includes('cast_upsample=1'), lastSavedBody);

    // 切换 cast_ceil 为 384000
    selCeil.value = '384000';
    selCeil.dispatchEvent({ type: 'change' });
    env.saveSettings(true);
    check('切换 cast_ceil 后 saveSettings 包含 cast_upsample_ceiling=384000', lastSavedBody.includes('cast_upsample_ceiling=384000'), lastSavedBody);
  }

  console.log(`\n==============================================`);
  console.log(`总断言: ${totalTests} | 通过: ${passedTests} | 失败: ${failedTests}`);
  console.log(`==============================================\n`);

  process.exit(failedTests === 0 ? 0 : 1);
}

runTests();
