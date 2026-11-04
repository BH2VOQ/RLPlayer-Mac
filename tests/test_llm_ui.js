// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_llm_ui.js — 1.1.3 LLM Models UI Contract 纯 Node.js 逻辑断言与回归测试
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
    type: '',
    value: '',
    _text: '',
    _html: '',
    get textContent() { return this._text || (this._html ? this._html.replace(/<[^>]*>/g, '') : ''); },
    set textContent(v) { this._text = v; this._html = v; },
    get innerHTML() { return this._html || this._text || ''; },
    set innerHTML(v) { this._html = v; this._text = String(v).replace(/<[^>]*>/g, ''); },
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
    querySelector() { return null; },
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
        if (res instanceof Promise) return res;
        if (res !== undefined) return Promise.resolve({ ok: true, json: () => Promise.resolve(res) });
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve({}) });
    },
    document: {
      getElementById: getEl,
      querySelector() { return null; },
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
  console.log('=== RLPlayer 1.1.3 LLM Models UI Contract 逻辑与回归测试 ===\n');

  // Test 1: 有列表且当前值在列表中 (currentInList=true)
  {
    console.log('-- Test 1: 有列表且当前值在列表中 (currentInList=true) --');
    const mockData = {
      ok: true,
      configured: true,
      current: 'deepseek-chat',
      currentInList: true,
      count: 3,
      models: [
        { id: 'deepseek-chat', ownedBy: 'deepseek' },
        { id: 'deepseek-coder', ownedBy: 'deepseek' },
        { id: 'deepseek-reasoner', ownedBy: 'deepseek' }
      ]
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/llm/models')) return mockData;
    });

    env.renderSettingsPage();
    await env.llmModelsLoad(false);

    const sel = env._getEl('sp_llmmodel');
    const txt = env._getEl('sp_llmmodeltext');
    const msg = env._getEl('sp_llmmodmsg');

    check('有列表时下拉框可见 (display 不是 none)', sel.style.display !== 'none');
    check('有列表时手填输入框隐藏 (display 为 none)', txt.style.display === 'none');
    check('下拉框渲染出全部模型 id (包含 deepseek-coder)', sel.innerHTML.includes('deepseek-coder'));
    check('当前值那项标注“（当前）”', sel.innerHTML.includes('deepseek-chat　（当前）'), sel.innerHTML);
    check('当前未选中的项不带“（当前）”标注', !sel.innerHTML.includes('deepseek-coder　（当前）'));
    check('下拉框当前选中值为当前模型 deepseek-chat', sel.value === 'deepseek-chat', sel.value);
    check('提示信息展示拉取到的模型总数 (3 个模型)', msg.textContent.includes('3 个模型'), msg.textContent);
  }

  // Test 2: 当前值不在列表中 (currentInList=false)
  {
    console.log('\n-- Test 2: 当前值不在列表中 (currentInList=false) --');
    const mockData = {
      ok: true,
      configured: true,
      current: 'custom-unlisted-model',
      currentInList: false,
      count: 2,
      models: [
        { id: 'deepseek-chat', ownedBy: 'deepseek' },
        { id: 'deepseek-reasoner', ownedBy: 'deepseek' }
      ]
    };

    const env = createEnvironment((url) => {
      if (url.startsWith('/api/llm/models')) return mockData;
    });

    env.renderSettingsPage();
    await env.llmModelsLoad(false);

    const sel = env._getEl('sp_llmmodel');
    const msg = env._getEl('sp_llmmodmsg');

    check('当前值不在列表时追加“（当前值，不在列表中）”选项',
          sel.innerHTML.includes('custom-unlisted-model　（当前值，不在列表中）'), sel.innerHTML);
    check('显示黄字建议“不在列表里 —— 建议重新选择，但不会自动改配置”',
          msg.innerHTML.includes('不在列表里') && msg.innerHTML.includes('建议重新选择，但不会自动改配置'), msg.innerHTML);
    check('提示包含警戒颜色样式 var(--warn', msg.innerHTML.includes('var(--warn'), msg.innerHTML);
    check('配置未经修改，当前模型保持不变', env.LLM.model === 'custom-unlisted-model', env.LLM.model);
  }

  // Test 3: 拉取失败优雅降级 (401 错误或网络异常)
  {
    console.log('\n-- Test 3: 拉取失败自动降级为手填框，绝不自动改配置或发起写请求 --');
    let postBodies = [];
    const env = createEnvironment((url, opt) => {
      if (url === '/api/llm' && opt && opt.method === 'POST') {
        postBodies.push(opt.body);
        return { ok: true };
      }
      if (url.startsWith('/api/llm/models')) {
        return { ok: false, error: 'HTTP 401: Unauthorized' };
      }
    });

    env.LLM.model = 'my-existing-model';
    env.renderSettingsPage();
    await env.llmModelsLoad(false);

    const sel = env._getEl('sp_llmmodel');
    const txt = env._getEl('sp_llmmodeltext');
    const msg = env._getEl('sp_llmmodmsg');

    check('拉取失败时下拉框自动隐藏 (display 为 none)', sel.style.display === 'none');
    check('拉取失败时手填输入框自动显示', txt.style.display !== 'none');
    check('手填框回填当前现有模型值 (my-existing-model)', txt.value === 'my-existing-model', txt.value);
    check('显示错误原因 HTTP 401: Unauthorized', msg.textContent.includes('HTTP 401: Unauthorized'), msg.textContent);
    check('拉取失败时绝不自动发起 POST /api/llm 写入请求', postBodies.length === 0, postBodies);
    check('当前 LLM.model 保持原样不被篡改', env.LLM.model === 'my-existing-model', env.LLM.model);

    // 针对网络抛出异常的情况
    const throwEnv = createEnvironment((url) => {
      if (url.startsWith('/api/llm/models')) {
        return Promise.reject(new Error('Network connection timeout'));
      }
    });
    throwEnv.renderSettingsPage();
    await throwEnv.llmModelsLoad(false);
    const throwTxt = throwEnv._getEl('sp_llmmodeltext');
    const throwMsg = throwEnv._getEl('sp_llmmodmsg');
    check('网络异常时降级为手填输入框', throwTxt.style.display !== 'none');
    check('网络异常时提示可见原因', throwMsg.textContent.includes('Network connection timeout') || throwMsg.textContent.includes('服务没响应'));
  }

  // Test 4: 选中下拉选项保存模型 (POST /api/llm body 包含 model=<id>)
  {
    console.log('\n-- Test 4: 选中选项发起 POST /api/llm 且 body 包含 model=<id> --');
    let postRequests = [];
    const env = createEnvironment((url, opt) => {
      if (url === '/api/llm' && opt && opt.method === 'POST') {
        postRequests.push({ url, opt });
        return { ok: true, model: 'deepseek-reasoner' };
      }
      if (url.startsWith('/api/llm/models')) {
        return {
          ok: true,
          models: [{ id: 'deepseek-chat' }, { id: 'deepseek-reasoner' }],
          current: 'deepseek-chat',
          currentInList: true
        };
      }
    });

    env.renderSettingsPage();
    await env.llmModelsLoad(false);

    await env.llmSaveModel('deepseek-reasoner');

    check('选中模型时发起了 POST /api/llm 请求', postRequests.length === 1);
    check('POST 请求体包含 model=deepseek-reasoner',
          postRequests.length > 0 && postRequests[0].opt.body === 'model=deepseek-reasoner',
          postRequests[0] ? postRequests[0].opt.body : null);
    check('弹出模型已切换提示 toast', env._toasts.some(t => t.includes('模型已切换为 deepseek-reasoner')), env._toasts);
  }

  // Test 5: 强制刷新带 refresh=1 参数
  {
    console.log('\n-- Test 5: 强制刷新 URL 参数契约 (?refresh=1) --');
    let requestedUrls = [];
    const env = createEnvironment((url) => {
      if (url.startsWith('/api/llm/models')) {
        requestedUrls.push(url);
        return { ok: true, models: [], count: 0 };
      }
    });

    env.renderSettingsPage();
    await env.llmModelsLoad(true);

    check('force=true 时请求 URL 带有 refresh=1 参数',
          requestedUrls.some(u => u.includes('refresh=1')), requestedUrls);
  }

  console.log(`\n==============================================`);
  console.log(`总断言: ${totalTests} | 通过: ${passedTests} | 失败: ${failedTests}`);
  console.log(`==============================================\n`);

  process.exit(failedTests === 0 ? 0 : 1);
}

runTests();
