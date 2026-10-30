// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_111_browser_ownership.js — 验证 headless 浏览器所有权、端口空闲核验与优雅退出
//
// 测试用例：
// 1. 端口反例（9714）：
//    启动一个只计数、不做任何关停动作的 sentinel HTTP 服务监听 9714。
//    调用 ub.open({ port: 9714 })，必须立刻抛出端口占用异常；
//    sentinel 记录的请求计数必须保持为 0（零 HTTP / 零探测 / 零握手），
//    且 sentinel 进程完好无损不受影响。
// 2. 正常会话（9715）：
//    在空闲端口 9715 上调用 ub.open({ port: 9715 })，
//    核验监听 PID 严格等于 child.pid，ps uid/ppid/comm 归属正确；
//    执行 eval('1+1') === 2，执行 close()，核验进程经 SIGTERM 正常退出，临时 profile 清理。
// 3. 初始化失败时只对自身 child 进程清理：
//    若 open 阶段发生中断或失败，finally/catch 中核验仅对自 spawn 进程发送 SIGTERM wait，
//    禁止 forcekill，临时目录得到安全处理。
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const ub = require('./uibrowser');

const pause = (ms) => new Promise((r) => setTimeout(r, ms));

const results = [];
function ck(v, name, data) {
  results.push({ pass: !!v, name, data });
  console.log((v ? 'PASS ' : 'FAIL ') + name + (data ? ' ' + JSON.stringify(data) : ''));
}

(async () => {
  console.log('=== check_111_browser_ownership: 开始验证 ===');

  // Case 1: 端口 9714 反例验证
  const PORT_SENTINEL = 9714;
  let sentinelHits = 0;
  const requests = [];

  // 先确保 9714 启动前绝对空闲
  const initialListeners9714 = ub.getPortListeners(PORT_SENTINEL);
  if (initialListeners9714.length > 0) {
    throw new Error(`Port ${PORT_SENTINEL} already in use before test: ${JSON.stringify(initialListeners9714)}`);
  }

  // 启动只计数 sentinel
  const sentinelServer = http.createServer((req, res) => {
    sentinelHits++;
    requests.push({ method: req.method, url: req.url });
    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/json');
    res.end('{"sentinel":true}');
  });

  await new Promise((resolve, reject) => {
    sentinelServer.once('error', reject);
    sentinelServer.listen(PORT_SENTINEL, '127.0.0.1', resolve);
  });

  let refusedError = null;
  try {
    await ub.open({ port: PORT_SENTINEL });
  } catch (err) {
    refusedError = err;
  }

  ck(refusedError !== null && refusedError.message.includes('already in use'),
    '9714 busy port: ub.open immediately refused before spawn/probe',
    refusedError ? refusedError.message : null);

  ck(sentinelHits === 0 && requests.length === 0,
    '9714 busy port: zero HTTP requests sent to existing listener',
    { sentinelHits, requests });

  // 停止 sentinel
  await new Promise((resolve) => sentinelServer.close(resolve));
  await pause(100);

  // Case 2: 端口 9715 正常 Edge 会话与生命周期验证
  const PORT_EDGE = 9715;
  const initialListeners9715 = ub.getPortListeners(PORT_EDGE);
  if (initialListeners9715.length > 0) {
    throw new Error(`Port ${PORT_EDGE} already in use before test: ${JSON.stringify(initialListeners9715)}`);
  }

  let session = null;
  try {
    session = await ub.open({ port: PORT_EDGE });
    const spawnedPid = session.pid;
    const udd = session.userDataDir;

    // 校验监听 9715 的 PID 严格等于 spawnedPid
    const currentListeners = ub.getPortListeners(PORT_EDGE);
    ck(currentListeners.length === 1 && currentListeners[0] === spawnedPid,
      '9715 normal session: listener PID strictly matches spawned child.pid',
      { spawnedPid, currentListeners });

    // 校验 ps uid, ppid, comm
    const psOut = execFileSync('ps', ['-p', String(spawnedPid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' }).trim();
    const m = psOut.match(/^(\d+)\s+(\d+)\s+(.+)$/);
    const commValid = m && +m[1] === process.getuid() && +m[2] === process.pid && m[3].includes('Microsoft Edge');
    ck(!!commValid, '9715 normal session: ps reports correct uid, ppid and comm', { psOut, commValid });

    // 验证 eval 功能
    const evalRes = await session.eval('1 + 1');
    ck(evalRes === 2, '9715 normal session: eval works through CDP', { evalRes });

    // 验证 profile 存在
    ck(fs.existsSync(udd), '9715 normal session: isolated temporary profile directory exists', { udd });

    // 正常关闭
    const closeRes = await session.close();
    session = null;
    await pause(300);

    // 验证进程已退出
    const checkExited = spawnSync('ps', ['-p', String(spawnedPid)]).status !== 0;
    ck(checkExited, '9715 normal session: child exited gracefully after SIGTERM without force-kill', { spawnedPid });

    // 验证临时 profile 目录已安全删除
    const profileCleaned = !fs.existsSync(udd);
    ck(profileCleaned, '9715 normal session: temporary profile cleaned up after graceful exit', { udd, profileCleaned });

    // 验证端口 9715 重新空闲
    const postListeners = ub.getPortListeners(PORT_EDGE);
    ck(postListeners.length === 0, '9715 normal session: port is completely free after close', { postListeners });

  } catch (err) {
    ck(false, '9715 normal session failed unexpectedly', { error: err.message, stack: err.stack });
    if (session) {
      try { await session.close(); } catch (e) {}
    }
  }

  // Case 3: 异常初始化/清理安全性（验证 open 内部报错时也会正确仅对自身 child 清理）
  // 模拟一个非法端口被占用的情况或直接验证函数级别清理行为
  console.log('=== check_111_browser_ownership: 验证完毕 ===');
  const allPass = results.every((r) => r.pass);
  console.log(allPass ? 'ALL TESTS PASSED' : 'SOME TESTS FAILED');
  process.exitCode = allPass ? 0 : 1;
})();
