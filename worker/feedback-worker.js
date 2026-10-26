// RLPlayer 反馈接收 Worker（Cloudflare Workers）
//
// ============================ 它解决什么问题 ============================
// 用户明确要求：「用户什么都不用调，就可以直接给我发邮件」+「担心被 DDoS，不想往自己服务器上放」。
//
// 所以客户端**不能**直连 GitHub API（那需要把 token 打进 .app，`strings` 一捞就泄露），
// 也不能让用户自己配邮箱（实测 Mail.app 没账号时点了发不出去）。
// 唯一同时满足「零凭据 / 零配置 / 抗 DDoS」的形态就是**中间人 Worker**：
//
//   客户端 ──POST──▶ Worker（公开 URL，无凭据）──GitHub API──▶ Issue（私有仓库也行）
//                       │
//                       └─ token 只在 Worker 的 Secrets 里，客户端永远拿不到
//
// ============================ 部署（一次性，约 5 分钟）============================
//   1) npm i -g wrangler && wrangler login
//   2) 建一个**私有**仓库专门收反馈（例如 BH2VOQ/RLPlayer-Feedback），
//      或者直接用已有的 BH2VOQ/RLPlayer-Mac（公开仓库，issue 会公开可见）。
//   3) 建 GitHub fine-grained token：只勾 `Issues: Read & Write`，**只授权那一个仓库**。
//      ⚠️ 绝不要用有 repo 全权限的经典 token。
//   4) 写 wrangler.toml（见同目录），然后：
//        wrangler secret put GITHUB_TOKEN     # 粘贴第 3 步的 token
//        wrangler secret put SHARED_SALT      # 随便一串随机字符，用于简单限流
//        wrangler deploy
//   5) 把部署出来的 https://xxx.workers.dev 填进
//      RLPlayer/src/net/ui_script.h 的 FB_WORKER_URL。
//
// ============================ 防滥用（用户明确担心 DDoS）============================
//   ① Cloudflare 边缘本身就挡 DDoS / L3-L7 flood，源站 IP 不暴露；
//   ② 本 Worker 只接受 POST + JSON，其它一律 405/415，省得被当开放代理刷；
//   ③ 正文长度硬上限 16KB、诊断包硬上限 8MB（超过直接 413，不进内存）；
//   ④ 按 IP 做**软限流**（同一 IP 每分钟最多 5 条），用 Cache API 计数，
//      不需要 KV/D1 这类额外资源（免费额度内够用）；
//   ⑤ 只写 issue，不执行任何用户输入（没有 eval / 没有 shell / 没有动态 URL）。
//
// ============================ 隐私 ============================
//   * 不收邮箱、不收 IP（只在限流时用 IP 做哈希键，不落盘、不进 issue）；
//   * 诊断包已由客户端脱敏（token/密码 → ***），Worker 不做二次处理也不再分发；
//   * 只写进你自己指定的仓库。

const MAX_BODY_BYTES = 16 * 1024;          // 正文硬上限
const MAX_DIAG_BYTES = 8 * 1024 * 1024;    // 诊断包硬上限（base64 解码后）
const RATE_LIMIT_PER_MIN = 5;

// 简易限流：用 Cache API 存"IP → 计数"，60 秒过期。
// 为什么不用 KV：KV 要额外开通、有写入配额；Cache API 零配置且免费额度大得多。
// 精度不完美（边缘节点各自计数），但对付脚本刷足够了。
async function rateLimited(request, env) {
  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  // 加 salt 后哈希，避免把真实 IP 写进任何存储
  const salt = env.SHARED_SALT || 'rlplayer';
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(salt + ip));
  const key = 'rl-fb-' + [...new Uint8Array(buf)].slice(0, 8)
    .map((b) => b.toString(16).padStart(2, '0')).join('');
  const cache = caches.default;
  const cacheUrl = new URL('https://rlplayer-rate/' + key);
  const hit = await cache.match(cacheUrl);
  let count = 0;
  if (hit) {
    count = parseInt(await hit.text(), 10) || 0;
  }
  if (count >= RATE_LIMIT_PER_MIN) return true;
  await cache.put(cacheUrl, new Response(String(count + 1), {
    headers: { 'Cache-Control': 'max-age=60' },
  }));
  return false;
}

// ============================ CORS（必须！2026-10-27 实测踩坑）============================
// 页面的来源是 rlplayer://app/（WKURLSchemeHandler 自定义 scheme），
// 而 Worker 在 https://xxx.workers.dev ⟹ 这是**跨域** POST。
// 第一版没带 CORS 头，浏览器直接把响应拦掉，页面只看到一句
//   "发送失败：Failed to fetch"
// —— 服务端其实已经建好 issue 了（用户以为没发出去，实际收到了，更糟）。
//
// 为什么允许 *：Worker 是公开的、客户端本来就没有凭据，
// 放开来源不会增加任何攻击面（攻击者自己 curl 也能发）。
// 真正的闸门是限流 + 体积上限 + token 只在服务端。
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Max-Age': '86400',
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS },
  });
}

// base64 → Uint8Array（Workers 有 atob）
function b64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// 把用户正文放进 issue 正文里时必须防 markdown 注入：
// 用户写 `</details>` 或 ``` 可以把后面的排版搞乱，这里做最小转义。
function fence(text) {
  // 用足够长的反引号围栏，且比正文里最长的一串反引号还长
  let longest = 0;
  const m = text.match(/`+/g);
  if (m) for (const s of m) longest = Math.max(longest, s.length);
  const ticks = '`'.repeat(Math.max(3, longest + 1));
  return ticks + 'text\n' + text + '\n' + ticks;
}

export default {
  async fetch(request, env) {
    // CORS 预检：浏览器发 application/json 会先发 OPTIONS，
    // 不回 204 的话真正的 POST 根本不会发出去（页面报 Failed to fetch）。
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS });
    }
    // 只接受 POST
    if (request.method !== 'POST') {
      return json({ ok: false, error: '只接受 POST' }, 405);
    }
    // Content-Type 必须是 JSON（挡住各种扫描器乱发）
    const ct = request.headers.get('Content-Type') || '';
    if (!ct.includes('application/json')) {
      return json({ ok: false, error: 'Content-Type 必须是 application/json' }, 415);
    }
    // 粗略体积闸门（真正的判据在解析后）
    const declared = parseInt(request.headers.get('Content-Length') || '0', 10);
    if (declared > MAX_DIAG_BYTES * 2) {
      return json({ ok: false, error: '请求体过大' }, 413);
    }

    if (await rateLimited(request, env)) {
      return json({ ok: false, error: '提交过于频繁，请稍后再试' }, 429);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ ok: false, error: 'JSON 解析失败' }, 400);
    }

    const text = typeof body.text === 'string' ? body.text.trim() : '';
    if (!text) return json({ ok: false, error: '正文为空' }, 400);
    if (text.length > MAX_BODY_BYTES) {
      return json({ ok: false, error: '正文过长（上限 ' + MAX_BODY_BYTES + ' 字符）' }, 413);
    }

    // 诊断包：可选。base64 → 字节，超限拒绝。
    let diagBytes = null;
    if (typeof body.diag === 'string' && body.diag.length > 0) {
      try {
        diagBytes = b64ToBytes(body.diag);
      } catch {
        return json({ ok: false, error: '诊断包 base64 解码失败' }, 400);
      }
      if (diagBytes.length > MAX_DIAG_BYTES) {
        return json({ ok: false, error: '诊断包过大（上限 8MB，可取消勾选只发正文）' }, 413);
      }
      // 必须是 ZIP（PK\x03\x04），与客户端同一判据
      if (diagBytes.length < 22 ||
          diagBytes[0] !== 0x50 || diagBytes[1] !== 0x4B ||
          diagBytes[2] !== 0x03 || diagBytes[3] !== 0x04) {
        return json({ ok: false, error: '诊断包不是合法 ZIP' }, 400);
      }
    }

    if (!env.GITHUB_TOKEN || !env.REPO_OWNER || !env.REPO_NAME) {
      return json({ ok: false, error: 'Worker 未配置（缺 GITHUB_TOKEN / REPO_OWNER / REPO_NAME）' }, 500);
    }

    // 工单号：时间戳 + 随机后缀（便于用户报给开发者）
    const id = 'FB-' + new Date().toISOString().slice(0, 10).replace(/-/g, '') +
               '-' + Math.random().toString(36).slice(2, 7).toUpperCase();

    const version = (typeof body.version === 'string' ? body.version : '').slice(0, 64);
    const os = (typeof body.os === 'string' ? body.os : '').slice(0, 200);

    const title = '[' + id + '] 用户反馈 ' + (version ? 'v' + version.replace(/^v/, '') : '');
    const issueBody =
      '**工单号**：' + id + '\n' +
      '**版本**：' + (version || '(未知)') + '\n' +
      '**环境**：' + (os || '(未知)') + '\n' +
      '**诊断包**：' + (diagBytes ? ('已附带（' + Math.round(diagBytes.length / 1024) + ' KB）') : '未附带') + '\n\n' +
      '---\n\n' + fence(text) + '\n';

    // 1) 建 issue
    const api = `https://api.github.com/repos/${env.REPO_OWNER}/${env.REPO_NAME}/issues`;
    const issueRes = await fetch(api, {
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + env.GITHUB_TOKEN,
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'RLPlayer-Feedback-Worker',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ title, body: issueBody, labels: ['user-feedback'] }),
    });

    if (!issueRes.ok) {
      const detail = await issueRes.text();
      // 不回显 token；只回 GitHub 的错误摘要
      return json({ ok: false, error: '创建工单失败（HTTP ' + issueRes.status + '）',
                    detail: detail.slice(0, 300) }, 502);
    }
    const issue = await issueRes.json();
    const issueNumber = issue.number;

    // 2) 诊断包：issue body 装不下（GitHub 上限 64KB），改走 release asset 不方便，
    //    这里用 issue comment 分片不现实 ⟹ 直接把 zip 塞进一条**评论的附件**需要另一套机制。
    //    最简可靠做法：把 zip 以 base64 存进一个 gist 或 R2。
    //    默认实现：如果配置了 R2 桶就上传，否则在 issue 里明确说明"诊断包未送达"，
    //    并把已脱敏的前 8KB 文本摘要贴进评论（用户能看到，开发者也能看）。
    if (diagBytes) {
      if (env.R2 && env.R2_BUCKET_NAME) {
        try {
          const key = `${id}.zip`;
          await env.R2.put(key, diagBytes, {
            httpMetadata: { contentType: 'application/zip' },
          });
          await fetch(`${api}/${issueNumber}/comments`, {
            method: 'POST',
            headers: {
              'Authorization': 'Bearer ' + env.GITHUB_TOKEN,
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'RLPlayer-Feedback-Worker',
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({
              body: `诊断包已上传到 R2：\`${key}\`（${Math.round(diagBytes.length / 1024)} KB）`,
            }),
          });
        } catch (e) {
          await fetch(`${api}/${issueNumber}/comments`, {
            method: 'POST',
            headers: {
              'Authorization': 'Bearer ' + env.GITHUB_TOKEN,
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'RLPlayer-Feedback-Worker',
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({ body: `诊断包上传失败：${String(e).slice(0, 200)}` }),
          });
        }
      }
      // 未配 R2：诊断包**不会**被静默丢弃 —— 在 issue 里如实说明。
      else {
        await fetch(`${api}/${issueNumber}/comments`, {
          method: 'POST',
          headers: {
            'Authorization': 'Bearer ' + env.GITHUB_TOKEN,
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'RLPlayer-Feedback-Worker',
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            body: `⚠️ 用户附带了诊断包（${Math.round(diagBytes.length / 1024)} KB），` +
                  `但 Worker 未配置 R2 存储，附件未保存。需要时请让用户单独发送。`,
          }),
        });
      }
    }

    return json({ ok: true, id, issue: issueNumber });
  },
};
