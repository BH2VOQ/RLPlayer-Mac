// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// check_cast_contract.js — 1.1.2 投放 UI 状态契约与状态机离线验证工具
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

// 提取生产源码 src/net/ui_script.h 中的生产 JavaScript
const uiScriptPath = path.resolve(__dirname, '../src/net/ui_script.h');
assert(fs.existsSync(uiScriptPath), `ui_script.h must exist at ${uiScriptPath}`);
const scriptContent = fs.readFileSync(uiScriptPath, 'utf8');
const match = scriptContent.match(/return R"JS\(([\s\S]*?)\)JS";/);
assert(match && match[1], 'Failed to extract JS from ui_script.h');
const prodJs = match[1];

let passed = 0;
let failed = 0;

function report(cond, name, details) {
  if (cond) {
    passed++;
    console.log(`[PASS] ${name}`);
  } else {
    failed++;
    console.error(`[FAIL] ${name} ${details ? JSON.stringify(details) : ''}`);
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
  observe() {}
  disconnect() {}
  unobserve() {}
}

function createEnv(apiHandler) {
  const elements = {};
  function getEl(id) {
    if (!elements[id]) elements[id] = createMockElement(id);
    return elements[id];
  }

  const toasts = [];

  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout(fn) { return 1; },
    clearTimeout() {},
    setInterval() { return 1; },
    clearInterval() {},
    Date, Math, parseInt, parseFloat, String, Number, Boolean, Array, Object, RegExp, JSON, Promise,
    encodeURIComponent, decodeURIComponent,
    addEventListener() {}, removeEventListener() {},
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
      addEventListener() {}, removeEventListener() {},
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

  const origToast = sandbox.toast;
  sandbox.toast = function (msg) {
    toasts.push(msg);
    if (typeof origToast === 'function') origToast(msg);
  };
  sandbox._toasts = toasts;
  sandbox._getEl = getEl;
  return sandbox;
}

async function main() {
  console.log('=== RLPlayer 1.1.2 投放 UI 状态契约离线回归验证 ===\n');

  // 1. 验证 AirPlay 投放 connecting 阶段顶栏不显示“已停止”
  {
    console.log('1. 验证 connecting 阶段状态文本');
    const env = createEnv((url) => {
      if (url.startsWith('/api/status')) {
        return {
          ok: true,
          castMode: true,
          castPhase: 'connecting',
          castDevice: 'airplay://192.168.1.88:5000',
          playing: true,
          paused: false,
          current: '/Music/test.flac',
          dur: 180,
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
    report(nps.textContent.includes('设备连接中') && !nps.textContent.includes('已停止'),
           'Connecting 阶段顶栏正确显示“设备连接中”，不显示“已停止”', nps.textContent);
  }

  // 2. 验证 AirPlay 投放 decoding 阶段状态文本
  {
    console.log('\n2. 验证 decoding 阶段状态文本');
    const env = createEnv((url) => {
      if (url.startsWith('/api/status')) {
        return {
          ok: true,
          castMode: true,
          castPhase: 'decoding',
          castDevice: 'airplay://192.168.1.88:5000',
          playing: true,
          paused: false,
          current: '/Music/test.flac',
          dur: 180,
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
    report(nps.textContent.includes('音频解码中') && !nps.textContent.includes('已停止'),
           'Decoding 阶段顶栏正确显示“音频解码中”，不显示“已停止”', nps.textContent);
  }

  // 3. 验证 AirPlay 投放 playing 阶段状态文本与暂停图标
  {
    console.log('\n3. 验证 playing 阶段状态与控件图标');
    const env = createEnv((url) => {
      if (url.startsWith('/api/status')) {
        return {
          ok: true,
          castMode: true,
          castPhase: 'playing',
          castDevice: 'airplay://192.168.1.88:5000',
          playing: true,
          paused: false,
          current: '/Music/test.flac',
          dur: 180,
          pos: 15.2,
          outRate: 44100,
          outBits: 16,
          outMode: 'airplay',
          transport: 'airplay'
        };
      }
    });
    await env.tick();
    const nps = env._getEl('nps');
    report(nps.textContent.includes('投放播放中'),
           'Playing 阶段顶栏正确显示“投放播放中”', nps.textContent);

    const playIcon = env._getEl('icP');
    report(playIcon['d'] && playIcon['d'].includes('M7 5h4v14H7zM13 5h4v14h-4z'),
           '播放中底栏播放/暂停控件展示暂停图标（非播放三角）');
  }

  // 4. 验证 AirPlay 投放 paused 阶段状态文本与播放三角图标
  {
    console.log('\n4. 验证 paused 阶段状态与控件图标');
    const env = createEnv((url) => {
      if (url.startsWith('/api/status')) {
        return {
          ok: true,
          castMode: true,
          castPhase: 'playing',
          castDevice: 'airplay://192.168.1.88:5000',
          playing: true,
          paused: true,
          current: '/Music/test.flac',
          dur: 180,
          pos: 15.2,
          outRate: 44100,
          outBits: 16,
          outMode: 'airplay',
          transport: 'airplay'
        };
      }
    });
    await env.tick();
    const nps = env._getEl('nps');
    report(nps.textContent.includes('已暂停'),
           'Paused 阶段顶栏正确显示“已暂停”', nps.textContent);

    const playIcon = env._getEl('icP');
    report(playIcon['d'] && playIcon['d'].includes('M8 5v14l11-7z'),
           '暂停时底栏控件展示播放三角图标');
  }

  // 5. 验证 castBadge 徽章展示协议而非写死 UPnP
  {
    console.log('\n5. 验证底栏徽标正确区分 AirPlay 与 UPnP');
    const env = createEnv();
    env.applyCastUi({
      running: true,
      phase: 'playing',
      device: 'airplay://192.168.1.88:5000'
    });
    const badge = env._getEl('castBadge');
    report(badge.style.display === 'inline-flex' && badge.textContent === 'AirPlay',
           'AirPlay 投放时底栏徽标展示 AirPlay', badge);

    env.applyCastUi({
      running: true,
      phase: 'playing',
      device: 'http://192.168.1.200:8080/desc.xml'
    });
    report(badge.style.display === 'inline-flex' && badge.textContent === 'UPnP',
           'UPnP 投放时底栏徽标展示 UPnP', badge);

    env.applyCastUi({
      running: false,
      phase: 'stopped'
    });
    report(badge.style.display === 'none',
           '停止投放后徽标立即隐藏', badge.style.display);
  }

  // 6. 验证 AirPlay 投放进度跳转拦截
  {
    console.log('\n6. 验证 AirPlay 投放进度跳转拦截');
    const env = createEnv();
    env.CAST.state = {
      running: true,
      phase: 'playing',
      device: 'airplay://192.168.1.88:5000'
    };
    env.S.dur = 200;
    env.S.pos = 20;

    env._toasts.length = 0;
    env.doSeek(0.4);
    report(env._toasts.some(t => t.includes('AirPlay 投放暂不支持拖动进度')),
           'AirPlay 投放进行 seek 触发明确提示');
  }

  // 7. 验证失效/离线旧 IP 下拉与弹窗刷新提示
  {
    console.log('\n7. 验证失效/离线旧 IP 刷新提示');
    const env = createEnv((url) => {
      if (url.startsWith('/api/cast/devices')) {
        return {
          ok: true,
          devices: [
            { kind: 'airplay', friendlyName: 'HomePod New IP', host: '192.168.1.99', port: 5000, location: 'airplay://192.168.1.99:5000' }
          ]
        };
      }
    });

    env.ADV.upnpDev = 'airplay://192.168.1.33:5000';
    env._castDevices = [
      { kind: 'airplay', friendlyName: 'HomePod New IP', host: '192.168.1.99', port: 5000, location: 'airplay://192.168.1.99:5000' }
    ];
    env.populateCastDevices();

    const devSelect = env._getEl('sp_cast_dev');
    report(devSelect.innerHTML.includes('离线/需刷新') && devSelect.innerHTML.includes('192.168.1.33'),
           '下拉框保留失效旧设备并清晰标明离线/需刷新', devSelect.innerHTML);

    let picked = null;
    env.npPickCastDevice(d => { picked = d; });
    const modal = env._getEl('mbody');
    report(modal.innerHTML.includes('当前未在线，点击上方已发现设备即可重新选择并刷新'),
           '设备选择浮层包含离线重选刷新提示', modal.innerHTML);
  }

  console.log(`\n======================================================`);
  console.log(`总断言: ${passed + failed} | 通过: ${passed} | 失败: ${failed}`);
  console.log(`======================================================\n`);

  process.exit(failed === 0 ? 0 : 1);
}

main().catch(err => {
  console.error('Fatal error in check_cast_contract.js:', err);
  process.exit(2);
});
