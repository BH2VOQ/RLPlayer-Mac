// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// uibrowser.js — 跨平台 headless 浏览器 + CDP 公共层（被 uicheck/uishots/uiprobe 等复用）
//
// 为什么单独抽出来：
//   1. 原有 10 个验收脚本各自硬编码 Windows 的 msedge.exe 绝对路径 ⟹ macOS 上全部
//      在 `if (!EDGE) process.exit(2)` 直接退出，历史上被误判成「本机 UI 验收跑不了」。
//      实测 macOS 上 Edge 装在 /Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge，
//      CDP 完全可用。
//   2. macOS 上 Edge 必须加 --no-sandbox：
//      不加时 GPU 进程 "sandbox initialization failed: Operation not permitted" →
//      "GPU process isn't usable. Goodbye." → 整个 headless 实例当场退出，
//      CDP target 立刻以 1006 断开。表现是「连上了但 Runtime.enable 永不返回」，
//      极易误判成脚本 bug。（2026-10-26 实测）
//   3. WebSocket 由 Node 内置（undici）。Edge 156 需要 --remote-allow-origins=*
//      才不会拒绝握手。
//
// 用法：
//   const ub = require('./uibrowser');
//   const s = await ub.open({ url, width, height });   // 返回会话
//   await s.eval(expr); await s.shot(path); await s.close();
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Only terminate the isolated browser process that this helper spawned. Never
// force-kill a process tree; retain its profile if graceful termination fails.
async function stopOwnedBrowser(child, ms = 5000) {
  if (child.exitCode !== null || child.signalCode !== null) return true;
  return new Promise((resolve) => {
    const onExit = () => { clearTimeout(timer); resolve(true); };
    const timer = setTimeout(() => {
      child.removeListener('exit', onExit);
      resolve(false);
    }, ms);
    child.once('exit', onExit);
    try { child.kill('SIGTERM'); } catch (e) {
      clearTimeout(timer);
      child.removeListener('exit', onExit);
      resolve(child.exitCode !== null || child.signalCode !== null);
    }
  });
}

// Edge 候选路径：Windows 两种安装位置 + macOS 标准位置；另允许 EDGE_PATH 覆盖。
const EDGE_CANDIDATES = [
  process.env.EDGE_PATH,
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
].filter(Boolean);

function findEdge() {
  return EDGE_CANDIDATES.find((p) => { try { return fs.existsSync(p); } catch (e) { return false; } }) || null;
}

function edgeArgs({ port, userDataDir, width, height }) {
  const a = [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    '--remote-allow-origins=*',      // Edge 156：否则 WS 握手被拒
    // 2026-10-28（用户「一直在调用我钥匙串」）：Chromium/Edge 在 macOS 上会用 login 钥匙串里的
    // "<产品> Safe Storage" 加密 profile 的 cookie/密码库。我们每次验收都用一个全新的临时
    // --user-data-dir，等于每次都要碰一次钥匙串 —— 实测会反复弹系统授权框，而自动化测试根本
    // 不需要真钥匙串。--use-mock-keychain 让 Chromium 用内存里的假钥匙串（官方提供的测试开关），
    // --password-store=basic 再断掉对 Keychain 的密码库后端选择。两条一起加，测试再也不碰钥匙串。
    '--use-mock-keychain',
    '--password-store=basic',
    '--user-data-dir=' + userDataDir,
    '--remote-debugging-port=' + port,
    '--window-size=' + width + ',' + height,
    'about:blank',
  ];
  // 仅 macOS/Linux 需要：Chromium 的 seatbelt 沙箱在部分 macOS 环境下初始化失败，
  // 触发 GPU 进程 exit_code=6 ⟹ 浏览器自杀。详见文件头注释。
  if (process.platform !== 'win32') {
    a.splice(2, 0, '--no-sandbox', '--disable-dev-shm-usage', '--disable-breakpad');
  }
  return a;
}

async function waitTargets(port, tries = 80) {
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch('http://127.0.0.1:' + port + '/json/list');
      const j = await r.json();
      const pages = j.filter((t) => t.type === 'page');
      if (pages.length) return pages;
    } catch (e) { /* 还没起来 */ }
    await sleep(200);
  }
  return null;
}

/**
 * 打开一个 headless 会话。
 * @param {{url?:string,width?:number,height?:number,port?:number,verbose?:boolean}} opt
 */
async function open(opt = {}) {
  const width = opt.width || 1576;
  const height = opt.height || 908;
  const EDGE = findEdge();
  if (!EDGE) {
    throw new Error('找不到 Edge（已试：' + EDGE_CANDIDATES.join(' | ') + '）；可用 EDGE_PATH 环境变量指定');
  }
  const port = opt.port || (9500 + Math.floor(Math.random() * 400));
  const udd = path.join(os.tmpdir(), 'rta_ub_' + process.pid + '_' + Date.now());
  const child = spawn(EDGE, edgeArgs({ port, userDataDir: udd, width, height }), {
    stdio: opt.verbose ? 'inherit' : 'ignore',
  });
  let exited = false;
  child.on('exit', () => { exited = true; });

  const pages = await waitTargets(port);
  if (!pages) {
    const stopped = await stopOwnedBrowser(child);
    if (stopped) { try { fs.rmSync(udd, { recursive: true, force: true }); } catch (e) { } }
    throw new Error('DevTools 端口没起来（port=' + port + '）；隔离浏览器 TERM=' + stopped);
  }

  const ws = new WebSocket(pages[0].webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.addEventListener('open', res, { once: true });
    ws.addEventListener('error', () => rej(new Error('WebSocket 连接失败（Edge 拒绝握手？检查 --remote-allow-origins）')), { once: true });
  });

  let msgId = 0;
  const pending = new Map();
  const errors = [];
  ws.addEventListener('message', (ev) => {
    let m;
    try { m = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data)); } catch (e) { return; }
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
      return;
    }
    if (m.method === 'Runtime.exceptionThrown') {
      const d = m.params.exceptionDetails;
      const desc = (d.exception && (d.exception.description || d.exception.value)) || d.text || '';
      errors.push('exception: ' + desc);
    } else if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') {
      errors.push('console.error: ' + m.params.args.map((a) => a.value || a.description || '').join(' '));
    }
  });

  function send(method, params) {
    return new Promise((res, rej) => {
      const id = ++msgId;
      pending.set(id, { res, rej });
      ws.send(JSON.stringify({ id, method, params: params || {} }));
    });
  }

  const session = {
    errors,
    send,
    async eval(expr) {
      const r = await send('Runtime.evaluate', {
        expression: expr, awaitPromise: true, returnByValue: true,
      });
      if (r.exceptionDetails) {
        const d = r.exceptionDetails;
        const msg = (d.exception && (d.exception.description || d.exception.value)) || d.text || JSON.stringify(d);
        throw new Error('JS 异常: ' + msg + '\n  表达式: ' + String(expr).slice(0, 200));
      }
      return r.result && r.result.value;
    },
    async waitFor(expr, ms = 8000) {
      const t0 = Date.now();
      while (Date.now() - t0 < ms) {
        try { if (await session.eval('!!(' + expr + ')')) return true; } catch (e) { /* 页面还在加载 */ }
        await sleep(120);
      }
      return false;
    },
    async shot(file) {
      const r = await send('Page.captureScreenshot', { format: 'png' });
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, Buffer.from(r.data, 'base64'));
      return file;
    },
    async setViewport(w, h) {
      await send('Emulation.setDeviceMetricsOverride', {
        width: w, height: h, deviceScaleFactor: 1, mobile: false,
      });
    },
    async close() {
      try { ws.close(); } catch (e) { }
      const stopped = await stopOwnedBrowser(child);
      if (stopped) {
        try { fs.rmSync(udd, { recursive: true, force: true }); } catch (e) { }
      } else {
        throw new Error('隔离浏览器未在 TERM 后退出；保留测试 profile，不做强杀');
      }
      return { exited: exited || stopped };
    },
  };

  await send('Runtime.enable');
  await send('Page.enable');
  try { await send('Log.enable'); } catch (e) { /* 某些版本没有 Log */ }

  if (opt.url) {
    await send('Page.navigate', { url: opt.url });
    await sleep(opt.settleMs || 2000);
  }
  return session;
}

module.exports = { open, findEdge, sleep, EDGE_CANDIDATES };
