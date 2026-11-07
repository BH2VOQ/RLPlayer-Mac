// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_llm_ui.js — 1.1.3 LLM Models UI Contract（1.1.4-beta3 扩：AI 接入 OpenAI 兼容 + 数据源排序）
// 纯 Node.js 逻辑断言与回归测试；全部离线 mock，零真实网络。
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
    confirm() { return true; },
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
  console.log('=== RLPlayer 1.1.3/1.1.4 LLM 接入与数据源排序 UI Contract 逻辑与回归测试 ===\n');

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

  // ==========================================================================
  // 以下为 1.1.4-beta3 新增：AI 接入（OpenAI 兼容）与数据源手动排序
  // 全部离线 mock，零真实网络。
  // ==========================================================================

  // Test 6: 接口预设 → API 地址（预设只填地址不落盘；custom 不覆盖已填内容）
  {
    console.log('\n-- Test 6: 接口预设写地址 / 不自动保存 / custom 不覆盖 --');
    const posts = [];
    const env = createEnvironment((url, opt) => {
      if (url === '/api/llm' && opt && opt.method === 'POST') { posts.push(opt.body); return { ok: true }; }
      if (url === '/api/llm') return { ok: true, configured: false, masked: '', model: 'deepseek-chat', baseUrl: '' };
      if (url.startsWith('/api/llm/models')) return { ok: true, models: [] };
    });
    env.renderSettingsPage();
    await new Promise(r => setImmediate(r));

    const ids = env.LLM_PROVIDERS.map(p => p.id).join(',');
    check('预设表为 deepseek/openai/openrouter/siliconflow/ollama/custom',
          ids === 'deepseek,openai,openrouter,siliconflow,ollama,custom', ids);

    const sel = env._getEl('sp_llmprovider');
    const base = env._getEl('sp_llmbase');
    sel.value = 'openai';
    sel.dispatchEvent({ type: 'change' });
    check('选 openai 预设 → 地址框写成 https://api.openai.com/v1',
          base.value === 'https://api.openai.com/v1', base.value);
    check('选预设不会自动落盘（没有 POST /api/llm）', posts.length === 0, posts);

    sel.value = 'ollama';
    sel.dispatchEvent({ type: 'change' });
    check('选 ollama 预设 → 地址框写成 http://127.0.0.1:11434/v1',
          base.value === 'http://127.0.0.1:11434/v1', base.value);

    base.value = 'https://my-gw.example.com/v1';
    sel.value = 'custom';
    sel.dispatchEvent({ type: 'change' });
    check('选 custom 预设不覆盖用户已填的地址',
          base.value === 'https://my-gw.example.com/v1', base.value);

    // 端点提示：deepseek 不显示，换别家显示「说明」而非「警告」
    sel.value = 'deepseek';
    sel.dispatchEvent({ type: 'change' });
    const note = env._getEl('sp_llmcapnote');
    check('端点是 deepseek 时不显示联网检索说明', note.style.display === 'none', note.style.display);
    sel.value = 'openrouter';
    sel.dispatchEvent({ type: 'change' });
    check('端点不是 deepseek 时显示联网检索说明', note.style.display !== 'none', note.style.display);
    check('该说明是普通说明（没有 --warn 红色样式）', note.innerHTML.indexOf('var(--warn') < 0, note.innerHTML);
    // 说明文案本身在设置页 HTML 里（mock 不解析 innerHTML ⟹ 直接查渲染出来的页面文本）
    const page = env._getEl('setpage').innerHTML;
    check('设置页 HTML 含接口预设下拉 / API 地址框 / 保存并连接按钮',
          page.indexOf('id=sp_llmprovider') >= 0 && page.indexOf('id=sp_llmbase') >= 0 &&
          page.indexOf('保存并连接') >= 0);
    check('卡片标题已改成「AI 接入（OpenAI 兼容）」', page.indexOf('AI 接入（OpenAI 兼容）') >= 0);
    check('「AI 增强」开关文案已改成 OpenAI 兼容', page.indexOf('AI 增强（OpenAI 兼容）') >= 0);
    check('旧的「DeepSeek 接入」标题已不再出现', page.indexOf('DeepSeek 接入') < 0);
    check('非 DeepSeek 说明是独立一行（不是拼进状态行）',
          page.indexOf('id=sp_llmcapnote') >= 0 && page.indexOf('id=sp_llmmsg') >= 0);
    check('该说明提到 search / fetch 与 Wikipedia / Discogs',
          page.indexOf('联网检索（search / fetch）是 DeepSeek 专有能力') >= 0 &&
          page.indexOf('Wikipedia / Discogs') >= 0);
  }

  // Test 7: 「保存并连接」—— POST body 契约 + 成功后自动刷新模型清单 + 自动连接测试
  {
    console.log('\n-- Test 7: 保存并连接（body 编码 / 自动重拉 / 自动测试 / 状态行） --');
    const posts = [];
    const modelsUrls = [];
    const testCalls = [];
    const env = createEnvironment((url, opt) => {
      if (url === '/api/llm' && opt && opt.method === 'POST') {
        posts.push(opt.body);
        return { ok: true, configured: true, masked: 'sk-****abcd',
                 model: 'gpt-4o-mini', baseUrl: 'https://api.openai.com/v1' };
      }
      if (url.startsWith('/api/llm/models')) {
        modelsUrls.push(url);
        return { ok: true, models: [{ id: 'gpt-4o-mini' }], current: 'gpt-4o-mini', currentInList: true, count: 1 };
      }
      if (url === '/api/llm/test') {
        testCalls.push(url);
        return { ok: true, model: 'gpt-4o-mini', latencyMs: 42 };
      }
      if (url === '/api/llm') return { ok: true };
    });
    env.renderSettingsPage();
    await new Promise(r => setImmediate(r));
    check('页面打开即自动拉一次模型清单（且不带 refresh=1）',
          modelsUrls.length === 1 && modelsUrls[0].indexOf('refresh=1') < 0, modelsUrls);

    const base = env._getEl('sp_llmbase');
    const key = env._getEl('sp_llmkey');

    // ① base_url + key 都必须 URL 编码后进 body
    const rawBase = 'https://api.openai.com/v1?x=1&y=2';
    const rawKey = 'sk-a/b+c=d';
    base.value = rawBase;
    key.value = rawKey;
    const modelsBefore = modelsUrls.length;
    const testBefore = testCalls.length;
    await env.llmSave();

    check('保存只发了一次 POST /api/llm', posts.length === 1, posts);
    check('body 里 base_url 已 URL 编码',
          posts[0].indexOf('base_url=' + encodeURIComponent(rawBase)) >= 0, posts[0]);
    check('body 里 key 已 URL 编码',
          posts[0].indexOf('key=' + encodeURIComponent(rawKey)) >= 0, posts[0]);
    check('保存成功后立刻清空 key 输入框（明文不留在 DOM）', key.value === '', key.value);
    check('保存成功后自动强制重拉模型清单（refresh=1）',
          modelsUrls.length === modelsBefore + 1 &&
          modelsUrls[modelsUrls.length - 1].indexOf('refresh=1') >= 0, modelsUrls);
    check('保存成功后自动跑了一次连接测试',
          testCalls.length === testBefore + 1, testCalls);

    const msg = env._getEl('sp_llmmsg');
    check('状态行同时说清掩码 / 当前模型 / 当前端点 host',
          msg.textContent.indexOf('sk-****abcd') >= 0 &&
          msg.textContent.indexOf('gpt-4o-mini') >= 0 &&
          msg.textContent.indexOf('api.openai.com') >= 0, msg.textContent);

    // ② key 为空 ⟹ 只 POST base_url，绝不带 key 字段
    key.value = '';
    base.value = 'https://openrouter.ai/api/v1';
    await env.llmSave();
    check('key 为空时 body 里没有 key 字段',
          posts.length === 2 && posts[1].indexOf('key=') < 0, posts[1]);
    check('key 为空时仍然 POST 了 base_url',
          posts[1].indexOf('base_url=' + encodeURIComponent('https://openrouter.ai/api/v1')) >= 0, posts[1]);

    // ③ 两项都空 ⟹ 不发请求（避免把配置写坏）
    base.value = '';
    key.value = '';
    await env.llmSave();
    check('地址与 key 都为空时不发 POST', posts.length === 2, posts.length);
  }

  // Test 8: 数据源排序 —— 渲染顺序 / 序号 / 上下移 / 越界按钮 disabled
  {
    console.log('\n-- Test 8: 数据源排序（渲染顺序 / 序号 / 上下移 / 越界禁用） --');
    const env = createEnvironment((url) => {
      if (url === '/api/llm') return { ok: true };
      if (url.startsWith('/api/llm/models')) return { ok: true, models: [] };
    });
    env.renderSettingsPage();
    await new Promise(r => setImmediate(r));

    env.META_PROVIDERS = [
      { id: 'dizzylab', name: 'dizzylab', on: true, canSearch: true, canLyric: false },
      { id: 'netease', name: '网易云音乐', on: true, canSearch: true, canLyric: true },
      { id: 'qq', name: 'QQ音乐', on: false, canSearch: true, canLyric: true },
      { id: 'itunes', name: 'iTunes', on: true, canSearch: true, canLyric: false }
    ];
    env.META_SRC = { dizzylab: 1, netease: 1, qq: 0, itunes: 1 };
    env.META_ORDER = ['qq', 'netease', 'dizzylab', 'itunes'];
    env.renderMetaSrcRows();

    const html = env._getEl('sp_metasrc').innerHTML;
    const order = [];
    const re = /data-id="([^"]+)"/g;
    let mm;
    while ((mm = re.exec(html)) !== null) order.push(mm[1]);
    check('渲染出的行顺序与 META_ORDER 一致',
          order.join(',') === 'qq,netease,dizzylab,itunes', order);

    const rows = html.split('<div class=metasrcrow').slice(1);
    check('渲染出 4 行', rows.length === 4, rows.length);
    check('每行序号 = 位置 + 1',
          rows.every((r, i) => new RegExp('class=metaidx[^>]*>' + (i + 1) + '<').test(r)),
          rows.map(r => r.slice(0, 80)));
    check('行容器带 draggable=true', rows.every(r => /draggable=true/.test(r)));
    check('行容器带 data-id', rows.every(r => /data-id="/.test(r)));
    check('第一行的上移按钮 disabled', /id=sp_metamvup_qq[^>]*disabled/.test(rows[0]), rows[0].slice(0, 220));
    check('最后一行的下移按钮 disabled', /id=sp_metamvdn_itunes[^>]*disabled/.test(rows[3]), rows[3].slice(0, 220));
    check('第一行下移 / 最后一行上移可用',
          !/id=sp_metamvdn_qq[^>]*disabled/.test(rows[0]) &&
          !/id=sp_metamvup_itunes[^>]*disabled/.test(rows[3]));

    // 上移：第二行（netease）→ 第 1
    env._getEl('sp_metamvup_netease').onclick();
    check('点上移后 META_ORDER 变为 netease,qq,dizzylab,itunes',
          env.META_ORDER.join(',') === 'netease,qq,dizzylab,itunes', env.META_ORDER);
    check('重排后弹出「顺序已保存」toast',
          env._toasts.some(x => x.indexOf('顺序已保存：') === 0), env._toasts);

    // 越界：现在 netease 在第一行，再点上移必须无效
    env._getEl('sp_metamvup_netease').onclick();
    check('第一行再点上移不改变顺序（越界无效）',
          env.META_ORDER.join(',') === 'netease,qq,dizzylab,itunes', env.META_ORDER);

    // 下移：第一行（netease）→ 第 2
    env._getEl('sp_metamvdn_netease').onclick();
    check('点下移后 META_ORDER 变为 qq,netease,dizzylab,itunes',
          env.META_ORDER.join(',') === 'qq,netease,dizzylab,itunes', env.META_ORDER);

    // 越界：现在 itunes 在最后一行，点下移必须无效
    env._getEl('sp_metamvdn_itunes').onclick();
    check('最后一行再点下移不改变顺序（越界无效）',
          env.META_ORDER.join(',') === 'qq,netease,dizzylab,itunes', env.META_ORDER);

    // 拖拽路径：dragstart 写行号，dragover 必须 preventDefault，drop 里按行号重排
    //（与播放队列同一套 dataTransfer 用法 —— mock DOM 不派发真拖拽，这里直接调 handler）
    let dragged = null;
    env._getEl('sp_metasrcrow_qq').ondragstart({
      dataTransfer: { setData: (k, v) => { dragged = { k, v }; }, effectAllowed: '' }
    });
    check('dragstart 往 dataTransfer 写 text/plain=行号',
          !!dragged && dragged.k === 'text/plain' && dragged.v === '0', dragged);

    let prevented = 0;
    env._getEl('sp_metasrcrow_itunes').ondragover({
      preventDefault: () => { prevented++; }, dataTransfer: {}
    });
    check('dragover 调用了 preventDefault（否则收不到 drop）', prevented === 1, prevented);

    env._getEl('sp_metasrcrow_itunes').ondrop({
      preventDefault() {}, stopPropagation() {},
      dataTransfer: { getData: () => '0' }     // 把第 0 行（qq）拖到最后一行
    });
    check('drop 后把 qq 移到 itunes 之后（拖拽与按钮走同一套重排）',
          env.META_ORDER.join(',') === 'netease,dizzylab,itunes,qq', env.META_ORDER);

    // 关掉某个源不改变顺序
    const cb = env._getEl('sp_meta_qq');
    const orderBeforeToggle = env.META_ORDER.join(',');
    cb.checked = true;
    cb.onchange();
    check('勾选/关闭数据源不改变 META_ORDER',
          env.META_ORDER.join(',') === orderBeforeToggle && env.META_SRC.qq === 1,
          { order: env.META_ORDER, src: env.META_SRC });
  }

  // Test 9: saveSettings 的 body 里 metasrcorder 与 META_ORDER 逐字一致
  {
    console.log('\n-- Test 9: saveSettings 落盘 metasrcorder --');
    const settingBodies = [];
    const env = createEnvironment((url, opt) => {
      if (url === '/api/settings' && opt && opt.method === 'POST') {
        settingBodies.push(opt.body);
        return { ok: true };
      }
      if (url === '/api/llm') return { ok: true };
      if (url.startsWith('/api/llm/models')) return { ok: true, models: [] };
    });
    env.renderSettingsPage();
    await new Promise(r => setImmediate(r));

    env.META_PROVIDERS = [
      { id: 'dizzylab', name: 'dizzylab', on: true, canSearch: true, canLyric: false },
      { id: 'netease', name: '网易云音乐', on: true, canSearch: true, canLyric: true },
      { id: 'qq', name: 'QQ音乐', on: true, canSearch: true, canLyric: true },
      { id: 'itunes', name: 'iTunes', on: true, canSearch: true, canLyric: false }
    ];
    env.META_SRC = { dizzylab: 1, netease: 1, qq: 0, itunes: 1 };
    env.META_ORDER = ['qq', 'netease', 'dizzylab', 'itunes'];
    env.saveSettings(true);

    const body = settingBodies[settingBodies.length - 1] || '';
    check('body 里 metasrcorder 与 META_ORDER.join(,) 逐字一致',
          body.indexOf('&metasrcorder=' + env.META_ORDER.join(',')) >= 0, body);
    check('顺序与逐源开关在同一次请求里',
          body.indexOf('&metasrc_qq=') >= 0 && body.indexOf('&metasrcorder=') >= 0, body);

    env.META_ORDER = [];
    env.saveSettings(true);
    const body2 = settingBodies[settingBodies.length - 1] || '';
    check('META_ORDER 为空时不下发 metasrcorder（避免覆盖成空串）',
          body2.indexOf('metasrcorder=') < 0, body2);
  }

  // Test 10: /api/providers 的 order 原样使用；缺 order 回落 items；缺项补到尾部
  {
    console.log('\n-- Test 10: /api/providers order 的使用与兜底 --');
    const mk = (payload) => createEnvironment((url) => {
      if (url === '/api/providers') return payload;
      if (url === '/api/llm') return { ok: true };
      if (url.startsWith('/api/llm/models')) return { ok: true, models: [] };
    });

    const items = [
      { id: 'dizzylab', name: 'dizzylab', on: true, canSearch: true, canLyric: false },
      { id: 'lrclib', name: 'lrclib', on: true, canSearch: false, canLyric: true },
      { id: 'netease', name: '网易云音乐', on: false, canSearch: true, canLyric: true },
      { id: 'qq', name: 'QQ音乐', on: true, canSearch: true, canLyric: true }
    ];

    // ① 有 order ⟹ 原样使用，不被 items 顺序覆盖（前端不重排）
    const withOrder = mk({ ok: true, items, order: 'qq,netease,dizzylab,lrclib' });
    withOrder.renderSettingsPage();
    withOrder.fillMetaProviders();
    await new Promise(r => setImmediate(r));
    check('有 order 时 META_ORDER 与 order 逐字一致（不被 items 顺序改写）',
          withOrder.META_ORDER.join(',') === 'qq,netease,dizzylab,lrclib', withOrder.META_ORDER);

    // ② 没有 order 字段（老后端）⟹ 回落 items 顺序，不崩
    const noOrder = mk({ ok: true, items });
    noOrder.renderSettingsPage();
    noOrder.fillMetaProviders();
    await new Promise(r => setImmediate(r));
    check('没有 order 字段时 META_ORDER 回落 items 顺序',
          noOrder.META_ORDER.join(',') === 'dizzylab,lrclib,netease,qq', noOrder.META_ORDER);
    check('META_SRC 仍按 items.on 初始化',
          noOrder.META_SRC.dizzylab === 1 && noOrder.META_SRC.netease === 0, noOrder.META_SRC);

    // ③ order 缺项（损坏/旧数据）⟹ 缺的 id 追加到尾部，仍是完整排列
    const partial = mk({ ok: true, items, order: 'netease' });
    partial.renderSettingsPage();
    partial.fillMetaProviders();
    await new Promise(r => setImmediate(r));
    check('order 缺项时缺的 id 追加到尾部',
          partial.META_ORDER.join(',') === 'netease,dizzylab,lrclib,qq', partial.META_ORDER);

    // ④ 恢复默认把顺序复位成后端给的默认顺序
    const reset = mk({ ok: true, items, order: 'qq,netease,dizzylab,lrclib' });
    reset.renderSettingsPage();
    reset.fillMetaProviders();
    await new Promise(r => setImmediate(r));
    reset.META_ORDER = ['lrclib', 'qq', 'netease', 'dizzylab'];
    reset.metaOrderReset();
    check('恢复默认后 META_ORDER 复位成后端默认顺序',
          reset.META_ORDER.join(',') === 'qq,netease,dizzylab,lrclib', reset.META_ORDER);
  }

  // Test 11: 「恢复默认」把顺序复位成后端给的默认顺序（端到端走 _resetAllSettings）
  {
    console.log('\n-- Test 11: 恢复默认复位数据源顺序 --');
    const items = [
      { id: 'dizzylab', name: 'dizzylab', on: true, canSearch: true, canLyric: false },
      { id: 'lrclib', name: 'lrclib', on: false, canSearch: false, canLyric: true },
      { id: 'netease', name: '网易云', on: false, canSearch: true, canLyric: true },
      { id: 'qq', name: 'QQ音乐', on: false, canSearch: true, canLyric: true }
    ];
    const env = createEnvironment((url) => {
      if (url === '/api/providers') return { ok: true, items, order: 'qq,netease,dizzylab,lrclib' };
      if (url === '/api/llm') return { ok: true };
      if (url.startsWith('/api/llm/models')) return { ok: true, models: [] };
    });
    env.renderSettingsPage();
    env.fillMetaProviders();
    await new Promise(r => setImmediate(r));
    check('到达 /api/providers 后 META_ORDER = order',
          env.META_ORDER.join(',') === 'qq,netease,dizzylab,lrclib', env.META_ORDER);

    // 用户手动调乱顺序，然后点「恢复默认」
    env.META_ORDER = ['lrclib', 'qq', 'netease', 'dizzylab'];
    check('可调用 _resetAllSettings（confirm 已 stub 成 true）', typeof env._resetAllSettings === 'function');
    env._resetAllSettings();
    check('恢复默认后 META_ORDER 回到后端给的默认顺序',
          env.META_ORDER.join(',') === 'qq,netease,dizzylab,lrclib', env.META_ORDER);
    check('恢复默认后逐源开关全部打开',
          env.META_SRC.qq === 1 && env.META_SRC.netease === 1 && env.META_SRC.lrclib === 1,
          env.META_SRC);
  }

  console.log(`\n==============================================`);
  console.log(`总断言: ${totalTests} | 通过: ${passedTests} | 失败: ${failedTests}`);
  console.log(`==============================================\n`);

  process.exit(failedTests === 0 ? 0 : 1);
}

runTests();
