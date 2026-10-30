// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
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
//   4. 进程严格归属与安全治理（2026-10-30）：
//      - 启动前端口空闲核验：若目标 CDP 端口已存在监听者，绝对禁止向其发送任何 HTTP/探测，
//        直接抛错退出，杜绝误操作他方服务。
//      - 启动后真实监听归属核验：使用 lsof 校验监听该端口的 PID 必须严格等于我们 spawn 的
//        child.pid，并通过 ps 核验 uid/ppid/comm 真实有效。
//      - 独立临时 profile：每次 open 生成全新临时 userDataDir，成功 close 时清理；若失败
//        或非正常退出，仅保留 profile 供排查，绝不强杀。
//      - 退出仅走核验后的 SIGTERM，禁止 kill -9 / force-kill 进程树。
//      - CDP 所有协议请求均带有超时机制，防止对端挂起造成测试脚本悬挂。
//
// 用法：
//   const ub = require('./uibrowser');
//   const s = await ub.open({ url, width, height });   // 返回会话
//   await s.eval(expr); await s.shot(path); await s.close();
'use strict';
const { spawn, execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function getPortListeners(port) {
  const lsofBin = fs.existsSync('/usr/sbin/lsof') ? '/usr/sbin/lsof' : 'lsof';
  const res = spawnSync(lsofBin, ['-nP', '-a', `-iTCP:${port}`, '-sTCP:LISTEN', '-Fp'], { encoding: 'utf8' });
  if (res.status === 1 && !res.stdout && !res.stderr) return [];
  if (res.status !== 0) throw new Error('lsof failed checking port ' + port + ': ' + res.stderr);
  return (res.stdout || '').split('\n')
    .map((l) => l.trim())
    .filter((l) => l.startsWith('p') && /^\d+$/.test(l.slice(1)))
    .map((l) => parseInt(l.slice(1), 10));
}

function verifyChildIdentity(child) {
  if (!child || child.pid === undefined) return false;
  if (child.exitCode !== null || child.signalCode !== null) return false;
  try {
    if (process.platform === 'darwin') {
      const owner = execFileSync('ps', ['-p', String(child.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
      const m = owner.match(/^(\d+)\s+(\d+)\s+(.+)$/);
      if (!m) return false;
      const [uid, ppid, comm] = [+m[1], +m[2], m[3]];
      if (uid !== process.getuid()) return false;
      if (ppid !== process.pid) return false;
      const expectedComm = path.basename(child.spawnfile);
      if (path.basename(comm) !== expectedComm) return false;
      return true;
    }
    return true;
  } catch (e) {
    return false;
  }
}

// Only terminate the isolated browser process that this helper spawned. Never
// force-kill a process tree; retain its profile if graceful termination fails.
async function stopOwnedBrowser(child, ms = 5000) {
  if (!child || child.pid === undefined) return true;
  if (child.exitCode !== null || child.signalCode !== null) return true;
  return new Promise((resolve) => {
    const onExit = () => { clearTimeout(timer); resolve(true); };
    const timer = setTimeout(() => {
      child.removeListener('exit', onExit);
      resolve(false);
    }, ms);
    child.once('exit', onExit);
    try {
      if (!verifyChildIdentity(child)) {
        throw new Error('isolated browser identity changed or not owned; no signal sent');
      }
      child.kill('SIGTERM');
    } catch (e) {
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

async function waitTargets(port, expectedPid, tries = 80) {
  for (let i = 0; i < tries; i++) {
    // 每次探测前先校验端口 listeners：如果有监听者，必须严格且唯一是 expectedPid
    const list = getPortListeners(port);
    if (list.length > 0) {
      if (list.length !== 1 || list[0] !== expectedPid) {
        throw new Error(`Port ${port} has unexpected listener(s): ${JSON.stringify(list)}, expected child pid ${expectedPid}`);
      }
      try {
        const r = await fetch('http://127.0.0.1:' + port + '/json/list');
        const j = await r.json();
        const pages = j.filter((t) => t.type === 'page');
        if (pages.length) return pages;
      } catch (e) { /* 还没完全就绪 */ }
    }
    await sleep(150);
  }
  return null;
}

/**
 * 打开一个 headless 会话。
 * @param {{url?:string,width?:number,height?:number,port?:number,verbose?:boolean,settleMs?:number,cdpTimeoutMs?:number}} opt
 */
async function open(opt = {}) {
  const width = opt.width || 1576;
  const height = opt.height || 908;
  const cdpTimeoutMs = opt.cdpTimeoutMs || 10000;
  const EDGE = findEdge();
  if (!EDGE) {
    throw new Error('找不到 Edge（已试：' + EDGE_CANDIDATES.join(' | ') + '）；可用 EDGE_PATH 环境变量指定');
  }
  const port = opt.port || (9500 + Math.floor(Math.random() * 400));

  // 1. 启动前端口空闲核验：绝对不向已有端口发任何 HTTP / 探针
  const existingListeners = getPortListeners(port);
  if (existingListeners.length > 0) {
    throw new Error(`Port ${port} is already in use by PID(s): ${JSON.stringify(existingListeners)}; refusing to spawn or send HTTP`);
  }

  const udd = path.join(os.tmpdir(), 'rta_ub_' + process.pid + '_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8));
  let child = null;
  let ws = null;
  let exited = false;

  try {
    child = spawn(EDGE, edgeArgs({ port, userDataDir: udd, width, height }), {
      stdio: opt.verbose ? 'inherit' : 'ignore',
    });
    child.on('exit', () => { exited = true; });

    // 2. 轮询等待目标就绪，并严格核验监听该端口的 PID 必须为 child.pid
    const pages = await waitTargets(port, child.pid);
    if (!pages) {
      throw new Error('DevTools 端口没起来（port=' + port + '）');
    }

    // 二次确认 child 身份对应
    if (!verifyChildIdentity(child)) {
      throw new Error(`Child process identity verification failed after port listen: pid=${child.pid}`);
    }

    ws = new WebSocket(pages[0].webSocketDebuggerUrl);
    await new Promise((res, rej) => {
      const openTimer = setTimeout(() => rej(new Error('WebSocket 连接超时（10s）')), 10000);
      ws.addEventListener('open', () => { clearTimeout(openTimer); res(); }, { once: true });
      ws.addEventListener('error', (err) => {
        clearTimeout(openTimer);
        rej(new Error('WebSocket 连接失败（Edge 拒绝握手？检查 --remote-allow-origins）: ' + (err.message || '')));
      }, { once: true });
    });

    let msgId = 0;
    const pending = new Map();
    const errors = [];
    ws.addEventListener('message', (ev) => {
      let m;
      try { m = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data)); } catch (e) { return; }
      if (m.id && pending.has(m.id)) {
        const p = pending.get(m.id); pending.delete(m.id);
        clearTimeout(p.timer);
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

    function send(method, params, timeout = cdpTimeoutMs) {
      return new Promise((res, rej) => {
        const id = ++msgId;
        const timer = setTimeout(() => {
          if (pending.has(id)) {
            pending.delete(id);
            rej(new Error(`CDP command timeout (${timeout}ms): ${method}`));
          }
        }, timeout);
        pending.set(id, { res, rej, timer });
        try {
          ws.send(JSON.stringify({ id, method, params: params || {} }));
        } catch (err) {
          clearTimeout(timer);
          pending.delete(id);
          rej(err);
        }
      });
    }

    const session = {
      errors,
      send,
      userDataDir: udd,
      pid: child.pid,
      async eval(expr, timeout = cdpTimeoutMs) {
        const r = await send('Runtime.evaluate', {
          expression: expr, awaitPromise: true, returnByValue: true,
        }, timeout);
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
          try { if (await session.eval('!!(' + expr + ')', 3000)) return true; } catch (e) { /* 页面还在加载 */ }
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
        if (ws) {
          try { ws.close(); } catch (e) { }
          ws = null;
        }
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
  } catch (err) {
    if (ws) {
      try { ws.close(); } catch (e) { }
    }
    if (child) {
      const stopped = await stopOwnedBrowser(child);
      if (stopped) {
        try { fs.rmSync(udd, { recursive: true, force: true }); } catch (e) { }
      }
    }
    throw err;
  }
}

module.exports = { open, findEdge, sleep, EDGE_CANDIDATES, getPortListeners, verifyChildIdentity, stopOwnedBrowser };
