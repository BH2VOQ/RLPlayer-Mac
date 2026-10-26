// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_worker.mjs — 本地验证 feedback-worker.js 的判据（不需要部署、不需要网络）
//
// 跑法：node worker/test_worker.mjs
//
// 为什么要有这条测试（铁律 3）：Worker 是唯一接收用户反馈的入口，
// 它错一个分支的后果是「用户以为发出去了，开发者什么都没收到」——
// 那比功能不存在更糟。所以每条闸门都必须被真正撞一遍。
//
// 覆盖：
//   ① 非 POST ⟹ 405
//   ② 非 JSON Content-Type ⟹ 415
//   ③ 空正文 ⟹ 400
//   ④ 超长正文 ⟹ 413
//   ⑤ 非法 base64 诊断包 ⟹ 400
//   ⑥ 诊断包不是 ZIP ⟹ 400
//   ⑦ 超大诊断包 ⟹ 413
//   ⑧ 未配置 token ⟹ 500（不假装成功）
//   ⑨ 正常请求 ⟹ 200 + 工单号，且 issue 请求体里的标题/正文正确
//   ⑩ 正文里的 markdown 围栏注入被中和（不破坏 issue 排版）
//   ⑪ 限流：同一 IP 连续超过阈值 ⟹ 429

import worker from './feedback-worker.js';

let fail = 0;
function ck(cond, what, detail = '') {
  console.log(`  [${cond ? 'PASS' : 'FAIL'}] ${what}${detail ? '  ⟶ ' + detail : ''}`);
  if (!cond) fail++;
}

// ---- 假的 fetch：记录调用、按需返回 ----
let calls = [];
let issueStatus = 201;
function installFetch() {
  calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const u = String(url);
    if (u.includes('/issues') && !u.includes('/comments')) {
      if (issueStatus !== 201) {
        return new Response('{"message":"bad"}', { status: issueStatus });
      }
      return new Response(JSON.stringify({ number: 42 }), { status: 201 });
    }
    return new Response('{}', { status: 201 });
  };
}

// ---- 假 cache：内存 Map，模拟 Cache API 的 60 秒窗口 ----
const store = new Map();
globalThis.caches = {
  default: {
    async match(url) {
      const v = store.get(String(url));
      return v === undefined ? undefined : new Response(String(v));
    },
    async put(url, res) {
      store.set(String(url), await res.text());
    },
  },
};

// base64 helpers
const b64 = (bytes) => Buffer.from(bytes).toString('base64');
const zipBytes = (n = 64) => {
  const a = new Uint8Array(n);
  a[0] = 0x50; a[1] = 0x4B; a[2] = 0x03; a[3] = 0x04;
  return a;
};

const ENV = {
  GITHUB_TOKEN: 'fake-token',
  REPO_OWNER: 'BH2VOQ',
  REPO_NAME: 'RLPlayer-Feedback',
  SHARED_SALT: 'test-salt',
};

function req(body, opts = {}) {
  const method = opts.method || 'POST';
  const ct = opts.contentType === undefined ? 'application/json' : opts.contentType;
  const headers = new Headers();
  if (ct) headers.set('Content-Type', ct);
  headers.set('CF-Connecting-IP', opts.ip || '1.2.3.4');
  if (opts.contentLength) headers.set('Content-Length', String(opts.contentLength));
  return new Request('https://worker.example/', {
    method,
    headers,
    body: method === 'GET' ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
  });
}

async function run() {
  // ⚠️ 每个测试段用**独立 IP**：限流是跨请求累计的，共用 IP 会让后面的段被前面的计数影响
  //（第一版就是这样：3/4 段被 2 段的 5 次配额吃掉，报 429 假失败）。
  console.log('=== 1. 方法与 Content-Type 闸门 ===');
  {
    store.clear();
    installFetch();
    let r = await worker.fetch(req('', { method: 'GET', ip: '10.0.0.1' }), ENV);
    ck(r.status === 405, 'GET ⟹ 405', String(r.status));

    r = await worker.fetch(req({ text: 'x' }, { contentType: 'text/plain', ip: '10.0.0.2' }), ENV);
    ck(r.status === 415, 'text/plain ⟹ 415', String(r.status));

    r = await worker.fetch(req({ text: 'x' }, { contentType: '', ip: '10.0.0.3' }), ENV);
    ck(r.status === 415, '无 Content-Type ⟹ 415', String(r.status));
  }

  console.log('\n=== 1b. CORS（页面跨域 POST 必须能过）===');
  {
    store.clear();
    installFetch();
    // OPTIONS 预检必须 204 且带 CORS 头，否则浏览器不会发真正的 POST
    const optReq = new Request('https://worker.example/', { method: 'OPTIONS' });
    const optRes = await worker.fetch(optReq, ENV);
    ck(optRes.status === 204, 'OPTIONS 预检 ⟹ 204', String(optRes.status));
    ck(optRes.headers.get('Access-Control-Allow-Origin') === '*', '预检带 Allow-Origin');
    ck((optRes.headers.get('Access-Control-Allow-Headers') || '').includes('Content-Type'),
       '预检允许 Content-Type 头');

    // 正常响应也必须带 CORS 头（否则浏览器读不到 body，页面报 Failed to fetch）
    const r2 = await worker.fetch(req({ text: 'cors-test' }, { ip: '10.9.9.9' }),
      { ...ENV, SHARED_SALT: 'salt-cors' });
    ck(r2.headers.get('Access-Control-Allow-Origin') === '*', '200 响应带 Allow-Origin', String(r2.status));

    // 错误响应同样要带（否则前端连错误信息都读不到）
    const r3 = await worker.fetch(req({ text: '' }, { ip: '10.9.9.8' }), ENV);
    ck(r3.headers.get('Access-Control-Allow-Origin') === '*', '400 错误响应也带 Allow-Origin');
  }

  console.log('\n=== 2. 正文闸门 ===');
  {
    store.clear();
    installFetch();
    let r = await worker.fetch(req({ text: '' }, { ip: '10.0.1.1' }), ENV);
    ck(r.status === 400, '空正文 ⟹ 400', String(r.status));

    r = await worker.fetch(req({ text: '   \n  ' }, { ip: '10.0.1.2' }), ENV);
    ck(r.status === 400, '纯空白 ⟹ 400', String(r.status));

    r = await worker.fetch(req({ text: 'A'.repeat(17 * 1024) }, { ip: '10.0.1.3' }), ENV);
    ck(r.status === 413, '超长正文 ⟹ 413', String(r.status));
  }

  console.log('\n=== 3. 诊断包闸门 ===');
  {
    store.clear();
    installFetch();
    let r = await worker.fetch(req({ text: 'x', diag: '!!!not-base64!!!' }, { ip: '10.0.2.1' }), ENV);
    ck(r.status === 400, '非法 base64 ⟹ 400', String(r.status));

    // 合法 base64 但不是 ZIP
    r = await worker.fetch(req({ text: 'x', diag: b64(new Uint8Array(64)) }, { ip: '10.0.2.2' }), ENV);
    ck(r.status === 400, '不是 ZIP（缺 PK 头）⟹ 400', String(r.status));

    // 超大
    const huge = new Uint8Array(9 * 1024 * 1024);
    huge[0] = 0x50; huge[1] = 0x4B; huge[2] = 0x03; huge[3] = 0x04;
    r = await worker.fetch(req({ text: 'x', diag: b64(huge) }, { ip: '10.0.2.3' }), ENV);
    ck(r.status === 413, '诊断包 > 8MB ⟹ 413', String(r.status));
  }

  console.log('\n=== 4. 未配置 token 必须失败（绝不假装成功）===');
  {
    store.clear();
    installFetch();
    const badEnv = { ...ENV, GITHUB_TOKEN: '' };
    const r = await worker.fetch(req({ text: 'x' }, { ip: '10.0.3.1' }), badEnv);
    ck(r.status === 500, '无 token ⟹ 500', String(r.status));
    const j = await r.json();
    ck(j.ok === false, '响应 ok:false');
  }

  console.log('\n=== 5. 正常路径 ===');
  {
    installFetch();
    const r = await worker.fetch(req({
      text: '播放 DSD 时切歌会卡 1 秒',
      version: '1.0.7',
      os: 'macOS 27.0.1 / arm64',
    }), { ...ENV, SHARED_SALT: 'salt-normal' });
    ck(r.status === 200, '200', String(r.status));
    const j = await r.json();
    ck(j.ok === true, 'ok:true');
    ck(typeof j.id === 'string' && j.id.startsWith('FB-'), '返回工单号', j.id);
    ck(j.issue === 42, '返回 issue 号', String(j.issue));

    const issueCall = calls.find(c => c.url.includes('/issues'));
    ck(!!issueCall, '确实调用了 GitHub issues API');
    const payload = JSON.parse(issueCall.init.body);
    ck(payload.title.includes(j.id), '标题含工单号', payload.title);
    ck(payload.title.includes('1.0.7'), '标题含版本号', payload.title);
    ck(payload.body.includes('播放 DSD 时切歌会卡 1 秒'), '正文内容进了 issue');
    ck(payload.body.includes('macOS 27.0.1'), '环境信息进了 issue');
    ck(!payload.body.includes('fake-token'), 'issue 正文里**不含** token（安全）');
  }

  console.log('\n=== 6. markdown 注入被中和 ===');
  {
    installFetch();
    // 用户正文里塞闭合围栏，试图破坏 issue 排版
    const evil = '正文\n```\n</details>\n## 假标题';
    const r = await worker.fetch(req({ text: evil, version: '1.0.7' }),
      { ...ENV, SHARED_SALT: 'salt-md' });
    ck(r.status === 200, '仍然成功');
    const issueCall = calls.find(c => c.url.includes('/issues'));
    const payload = JSON.parse(issueCall.init.body);
    // 围栏必须比正文里最长的反引号还长 ⟹ 正文里的 ``` 不会提前闭合
    ck(payload.body.includes('````text'), '围栏被加长到 4 个反引号', payload.body.slice(0, 40));
  }

  console.log('\n=== 7. 限流 ===');
  {
    installFetch();
    store.clear();
    const env = { ...ENV, SHARED_SALT: 'salt-rate' };
    const results = [];
    for (let i = 0; i < 7; i++) {
      const r = await worker.fetch(req({ text: 'x' + i }, { ip: '9.9.9.9' }), env);
      results.push(r.status);
    }
    ck(results.slice(0, 5).every(s => s === 200), '前 5 条放行', results.join(','));
    ck(results[5] === 429 && results[6] === 429, '第 6/7 条被限流 429', results.join(','));
  }

  console.log('\n=== 8. GitHub 报错时如实回传（不假装成功）===');
  {
    installFetch();
    issueStatus = 401;
    const r = await worker.fetch(req({ text: 'x' }), { ...ENV, SHARED_SALT: 'salt-err' });
    ck(r.status === 502, 'GitHub 401 ⟹ 502', String(r.status));
    const j = await r.json();
    ck(j.ok === false, 'ok:false');
    ck(!JSON.stringify(j).includes('fake-token'), '错误响应里不含 token');
    issueStatus = 201;
  }

  console.log(`\n=== 汇总：${fail === 0 ? '全部通过' : fail + ' 项失败'} ===`);
  process.exit(fail === 0 ? 0 : 1);
}

run().catch(e => { console.error('测试本身出错:', e); process.exit(1); });
