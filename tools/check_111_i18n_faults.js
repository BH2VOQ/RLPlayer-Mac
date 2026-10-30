// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_111_i18n_faults.js —— 1.1.1 真实隔离进程故障验证与英文 DOM 呈现验收
//
// 验证场景：
//   1) LLM 连接拒绝/重置 (Connection reset / connection refused)
//   2) LLM HTTP 状态码故障 (401 / 404 / 429)
//   3) UPnP 协商失败 (SOAP SetAVTransportURI 拒绝，绝不播放)
//   4) 独占采样率不支持 (backend=wasapi rate=12345 真实 caps 拒绝，先于 sink.open)
//
// 铁律执行与安全约束：
//   - 隔离端口：rtaweb=19106, stub=19105, browser CDP=9713；绝不碰 8899 / 19101
//   - 隔离配置：独立临时目录作为 HOME/RLPLAYER_STATE_DIR/RLPLAYER_LIBRARY_DIR/RLPLAYER_COVER_DIR
//   - 严禁读写外部/用户 rlplayer-llm.conf，仅在独立临时 state 目录下写入合成 key
//   - Loopback HTTP stub (19105) 仅响应合成 key，不发起任何外网流量
//   - 绝不篡改 window.fetch 或伪造 API 响应；全走真实后端 /api/llm/test、/api/cast/start、/api/play
//   - UPnP 协商直接拒绝，绝不启动真实音频投放；独占率 12345 真实 caps 拒绝，绝不打开真实音频设备
//   - 进程退出前只读核验进程归属与端口，通过 SIGTERM 优雅退出，绝不 force kill
//
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const net = require('net');
const { spawn, execSync, execFileSync } = require('child_process');
const ub = require('./uibrowser');

// ---------------- 命令行参数解析 ----------------
const args = process.argv.slice(2);
function getArg(name, def) {
  const idx = args.indexOf(name);
  if (idx !== -1 && idx + 1 < args.length) return args[idx + 1];
  return def;
}

const binary = path.resolve(getArg('--binary', 'build-mac/rtaweb'));
const outDirArg = getArg('--output', '');
const keep = args.includes('--keep');
const castOnly = args.includes('--cast-only'); // source rejection only: no /api/play or hardware caps
const soapActions = [];
const safetyAudit = [];

const port = 19106;
const stubPort = 19105;
const browserPort = 9713;

const root = outDirArg
  ? path.resolve(outDirArg)
  : fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-111-i18n-faults-'));

if (!fs.existsSync(root)) fs.mkdirSync(root, { recursive: true });

const env = {
  ...process.env,
  HOME: path.join(root, 'home'),
  RLPLAYER_STATE_DIR: path.join(root, 'state'),
  RLPLAYER_LIBRARY_DIR: path.join(root, 'lib'),
  RLPLAYER_COVER_DIR: path.join(root, 'covers'),
};

for (const k of ['HOME', 'RLPLAYER_STATE_DIR', 'RLPLAYER_LIBRARY_DIR', 'RLPLAYER_COVER_DIR']) {
  fs.mkdirSync(env[k], { recursive: true });
}
const musicDir = path.join(root, 'music');
fs.mkdirSync(musicDir, { recursive: true });

// 创建 1 秒超低电平合法 PCM WAV 测试素材（不打开设备，用于真实 caps 拒绝检查）
const silenceWav = path.join(musicDir, 'silence.wav');
{
  const numSamples = 44100;
  const dataSize = numSamples * 2;
  const buf = Buffer.alloc(44 + dataSize);
  buf.write('RIFF', 0);
  buf.writeUInt32LE(36 + dataSize, 4);
  buf.write('WAVE', 8);
  buf.write('fmt ', 12);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); // PCM
  buf.writeUInt16LE(1, 22); // Mono
  buf.writeUInt32LE(44100, 24);
  buf.writeUInt32LE(88200, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36);
  buf.writeUInt32LE(dataSize, 40);
  fs.writeFileSync(silenceWav, buf);
}

// Real malformed files reach production read_wav, before HTTP serving or SOAP Play.
const badWav = path.join(musicDir, '坏 WAV 用户路径.wav');
const truncatedWav = path.join(musicDir, '截断 WAV 用户路径.wav');
const badDsf = path.join(musicDir, '坏 DSD 用户路径.dsf');
fs.writeFileSync(badWav, Buffer.from('not a WAV: 17byte'));
const truncated = fs.readFileSync(silenceWav).subarray(0, 48);
fs.writeFileSync(truncatedWav, truncated); // declared dataLen=88200, available=4
fs.writeFileSync(badDsf, Buffer.from('invalid DSF header'));

function listenerPids(p) {
  try {
    return [...new Set(execFileSync('lsof', ['-nP', '-t', `-iTCP:${p}`, '-sTCP:LISTEN'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim().split(/\s+/).filter(Boolean).map(Number))];
  } catch (e) {
    if (e.status === 1 && !String(e.stdout || '').trim()) return [];
    throw e;
  }
}
async function preflightPort(p) {
  const owners = listenerPids(p);
  if (owners.length) throw Error(`Port ${p} occupied by ${owners}; no process started or signalled`);
  await new Promise((resolve, reject) => {
    const s = net.createServer(); s.once('error', reject);
    s.listen(p, '127.0.0.1', () => s.close(resolve));
  });
  safetyAudit.push({ event: 'preflight', port: p, owners });
}
function verifyListener(p, expectedPid) {
  const owners = listenerPids(p);
  safetyAudit.push({ event: 'listener', port: p, expectedPid, owners });
  if (owners.length !== 1 || owners[0] !== expectedPid)
    throw Error(`Listener ${p} is not owned by spawned PID ${expectedPid}: ${owners}`);
}

// ---------------- 基础设施与状态跟踪 ----------------
let rtaChild = null;
let browserSession = null;
let stubServer = null;
let stubMode = 'reset'; // 'reset' | '401' | '404' | '429' | 'upnp' | 'closed'

const results = [];
function recordResult(pass, name, details) {
  const item = { pass: !!pass, name, ...details };
  results.push(item);
  console.log((pass ? 'PASS ' : 'FAIL ') + name + (details ? ' ' + JSON.stringify(details) : ''));
}

const pause = (ms) => new Promise((r) => setTimeout(r, ms));

// CJK 字符检测正则
const CJK = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/;

function extractChinese(str) {
  if (!str || typeof str !== 'string') return [];
  // 排除真实文件路径（带 / 且有扩展名）
  const words = str.split(/\s+/).filter((w) => {
    const isPath = w.indexOf('/') >= 0 && /\.[A-Za-z0-9]{2,5}$/.test(w);
    return !isPath;
  });
  const filtered = words.join(' ');
  const matches = filtered.match(/[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+/g);
  return matches || [];
}

// ---------------- 本地 HTTP 故障 Stub (19105) ----------------
function startStubServer() {
  return new Promise((resolve, reject) => {
    stubServer = http.createServer((req, res) => {
      // 安全闸：仅接受来自 127.0.0.1 的请求
      const remote = req.socket.remoteAddress;
      if (remote !== '127.0.0.1' && remote !== '::1' && remote !== '::ffff:127.0.0.1') {
        req.socket.destroy();
        return;
      }

      if (stubMode === 'reset') {
        if (typeof req.socket.resetAndDestroy === 'function') {
          req.socket.resetAndDestroy();
        } else {
          req.socket.destroy();
        }
        return;
      }

      if (stubMode === '401') {
        const body = JSON.stringify({
          error: { message: 'Invalid API key provided', type: 'authentication_error' },
        });
        res.writeHead(401, {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        });
        res.end(body);
        return;
      }

      if (stubMode === '404') {
        const body = JSON.stringify({
          error: { message: 'The requested model or endpoint does not exist', type: 'not_found_error' },
        });
        res.writeHead(404, {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        });
        res.end(body);
        return;
      }

      if (stubMode === '429') {
        const body = JSON.stringify({
          error: { message: 'Rate limit exceeded: quota depleted', type: 'rate_limit_error' },
        });
        res.writeHead(429, {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        });
        res.end(body);
        return;
      }

      if (stubMode === 'upnp') {
        if (req.url === '/desc.xml') {
          const xml = `<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Mock Test Renderer</friendlyName>
    <modelName>RLP-Mock-101</modelName>
    <UDN>uuid:11111111-2222-3333-4444-555555555555</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/ctl/avt</controlURL>
        <eventSubURL>/evt/avt</eventSubURL>
        <SCPDURL>/scpd/avt.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>`;
          res.writeHead(200, {
            'Content-Type': 'text/xml; charset="utf-8"',
            'Content-Length': Buffer.byteLength(xml),
          });
          res.end(xml);
          return;
        }

        if (req.url === '/ctl/avt') {
          const action = String(req.headers.soapaction || '').replace(/"/g, '').split('#').pop();
          soapActions.push(action);
          // Every SOAP request is refused; even a regression cannot start playback.
          // UPnP SOAP 响应：在协商阶段返回 500 SOAP Fault，显式拒绝 SetAVTransportURI
          const soapFault = `<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <s:Fault>
      <faultcode>s:Client</faultcode>
      <faultstring>UPnPError</faultstring>
      <detail>
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
          <errorCode>714</errorCode>
          <errorDescription>Illegal MIME-Type</errorDescription>
        </UPnPError>
      </detail>
    </s:Fault>
  </s:Body>
</s:Envelope>`;
          res.writeHead(500, {
            'Content-Type': 'text/xml; charset="utf-8"',
            'Content-Length': Buffer.byteLength(soapFault),
          });
          res.end(soapFault);
          return;
        }
      }

      res.writeHead(404);
      res.end('Not Found');
    });

    stubServer.listen(stubPort, '127.0.0.1', () => resolve());
    stubServer.on('error', reject);
  });
}

// ---------------- 服务启停与环境配置 ----------------
async function stopOwnedProcesses() {
  const audit = [];

  if (browserSession) {
    try {
      await browserSession.close();
    } catch (e) {
      audit.push({ role: 'browser', error: String(e) });
    }
    browserSession = null;
  }

  if (rtaChild && rtaChild.exitCode === null) {
    const pid = rtaChild.pid;
    // 只读核验属主
    const psOut = execFileSync('ps', ['-p',String(pid),'-o','uid=,ppid=,comm='],{encoding:'utf8'}).trim();
    audit.push({role:'rtaweb',pid,ps:psOut});
    const owner = psOut.match(/^(\d+)\s+(\d+)\s+(.+)$/);
    if(!owner || +owner[1]!==process.getuid() || +owner[2]!==process.pid || path.basename(owner[3])!==path.basename(binary))
      throw Error('rtaweb identity changed; no signal sent');
    rtaChild.kill('SIGTERM');
    await Promise.race([
      new Promise((r) => rtaChild.once('exit', r)),
      pause(8000),
    ]);
    if (rtaChild.exitCode === null) {
      audit.push({ role: 'rtaweb', pid, warning: 'Did not exit on SIGTERM within 8s' });
      throw Error('owned rtaweb did not exit after TERM; no force kill');
    } else {
      audit.push({ role: 'rtaweb', pid, exitCode: rtaChild.exitCode });
    }
    rtaChild = null;
  }

  if (stubServer) {
    await new Promise((resolve) => stubServer.close(() => resolve()));
    stubServer = null;
  }

  fs.writeFileSync(path.join(root, 'shutdown-audit.json'), JSON.stringify(audit, null, 2));
  fs.writeFileSync(path.join(root, 'safety-audit.json'), JSON.stringify({ safetyAudit, soapActions }, null, 2));
}

async function startRtaweb() {
  if (rtaChild) throw Error('server already started; refusing an unverified restart');

  // 确保端口就绪
  await new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(port, '127.0.0.1', () => s.close(resolve));
  });

  rtaChild = spawn(
    binary,
    ['--port', String(port), '--music-dir', musicDir],
    { env, cwd: root, stdio: 'ignore' }
  );

  let ready = false;
  for (let i = 0; i < 150; i++) {
    if (rtaChild.exitCode !== null || rtaChild.signalCode !== null) throw Error('Spawned server exited before readiness');
    try {
      const resp = await fetch(`http://127.0.0.1:${port}/api/ping`);
      if (resp.ok) { ready = true; break; }
    } catch (e) {}
    await pause(100);
  }
  if (!ready) throw Error('Spawned server readiness timed out');
  verifyListener(port, rtaChild.pid);
}

// ---------------- 主测试逻辑 ----------------
(async () => {
  try {
    console.log('=== RLPlayer 1.1.1 英文 DOM 真实故障验证 ===');
    console.log('工作目录:', root);

    // Preflight every explicit listener before spawning anything; never probe 8899.
    for (const p of [port, stubPort, browserPort]) await preflightPort(p);
    // 0. 启动 local stub
    await startStubServer();
    verifyListener(stubPort, process.pid);

    // 1. 初始化设置：英文、禁用 AI、安全默认
    const settingsConf = path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-settings.conf');
    fs.writeFileSync(
      settingsConf,
      'backend=null\nmetaon=0\nmetallm=0\nlang=en\ntheme=light\nuistyle=apple\n'
    );

    // 写入合成 LLM 配置，指向本地 stub (19105)
    const llmConf = path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-llm.conf');
    fs.writeFileSync(
      llmConf,
      `api_key=sk-synthetic-fault-test-key-12345678\nbase_url=http://127.0.0.1:${stubPort}\nmodel=synthetic-model\n`
    );

    // 启动 rtaweb
    await startRtaweb();
    const llmLocation = await (await fetch(`http://127.0.0.1:${port}/api/llm`)).json();
    if (path.resolve(llmLocation.path) !== path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-llm.conf'))
      throw Error('LLM configuration path is not isolated');

    // 启动 headless Edge
    browserSession = await ub.open({
      url: `http://127.0.0.1:${port}/`,
      port: browserPort,
      width: 1576,
      height: 908,
    });

    const browserOwners = listenerPids(browserPort);
    const browserPs = browserOwners.length === 1 ? execFileSync('ps', ['-p', String(browserOwners[0]), '-o', 'uid=,ppid=,comm='], {encoding:'utf8'}).trim() : '';
    const browserIdentity = browserPs.match(/^(\d+)\s+(\d+)\s+(.+)$/);
    if (!browserIdentity || +browserIdentity[1] !== process.getuid() || +browserIdentity[2] !== process.pid || browserIdentity[3] !== ub.findEdge())
      throw Error('CDP listener does not belong to the browser spawned by public helper');
    safetyAudit.push({event:'browser-listener',port:browserPort,pid:browserOwners[0],ps:browserPs});
    if (!await browserSession.waitFor("typeof openSettingsTab==='function' && document.getElementById('bHelp')"))
      throw Error('Production UI did not become ready');
    await pause(500);

    const langAttr = await browserSession.eval(
      "document.documentElement.dataset.lang + '|' + document.documentElement.lang"
    );
    recordResult(langAttr === 'en|en', 'HTML data-lang/lang initialized to en|en', { langAttr });

    // ==========================================
    // 场景 1: LLM 连接重置/网络不可达 (Connection reset)
    // ==========================================
    console.log('\n--- Scenario 1: LLM Connection Reset ---');
    stubMode = 'reset';

    // 打开设置 -> 元数据页签
    await browserSession.eval("openSettingsTab('meta')");
    await pause(300);

    // 展开高级选项
    await browserSession.eval(`(function(){
      var box = document.getElementById('sp_metaadv');
      var btn = document.getElementById('sp_metamore');
      if (box && box.style.display === 'none' && btn) btn.click();
    })()`);
    await pause(300);

    // 触发真实点击 sp_llmtest 按钮
    await browserSession.eval("document.getElementById('sp_llmtest').click()");

    // 等待 sp_llmtest 恢复启用（测试结束）
    await browserSession.waitFor("!document.getElementById('sp_llmtest').disabled", 10000);
    await pause(400);

    // 采集 DOM 内容与原始 API 响应
    const rawLlmTest1 = await (await fetch(`http://127.0.0.1:${port}/api/llm/test`)).json();
    const domLlmMsg1 = await browserSession.eval("document.getElementById('sp_llmmsg').textContent.trim()");
    const shotPath1 = path.join(root, 'llm-fault-reset.png');
    await browserSession.shot(shotPath1);

    const zhLeftovers1 = extractChinese(domLlmMsg1);
    recordResult(
      rawLlmTest1.ok === false,
      'Scenario 1: /api/llm/test reports ok:false on connection reset',
      { raw: rawLlmTest1 }
    );
    recordResult(
      domLlmMsg1.length > 0 && domLlmMsg1.includes('Connection failed') && zhLeftovers1.length === 0,
      'Scenario 1: DOM #sp_llmmsg presents error non-empty and in English (no Chinese)',
      { domText: domLlmMsg1, zhResiduals: zhLeftovers1 }
    );

    // ==========================================
    // 场景 2: LLM HTTP 状态码故障 (401, 404, 429)
    // ==========================================
    const httpCodes = ['401', '404', '429'];
    for (const code of httpCodes) {
      console.log(`\n--- Scenario 2: LLM HTTP ${code} Fault ---`);
      stubMode = code;

      // 再次点击真实页面按钮
      await browserSession.eval("document.getElementById('sp_llmtest').click()");
      await browserSession.waitFor("!document.getElementById('sp_llmtest').disabled", 10000);
      await pause(400);

      const rawLlmTest = await (await fetch(`http://127.0.0.1:${port}/api/llm/test`)).json();
      const domLlmMsg = await browserSession.eval("document.getElementById('sp_llmmsg').textContent.trim()");
      const shotPath = path.join(root, `llm-fault-${code}.png`);
      await browserSession.shot(shotPath);

      const zhLeftovers = extractChinese(domLlmMsg);
      recordResult(
        rawLlmTest.ok === false && String(rawLlmTest.error || '').includes(code),
        `Scenario 2: /api/llm/test reports ok:false and mentions HTTP ${code}`,
        { raw: rawLlmTest }
      );
      recordResult(
        domLlmMsg.length > 0 && domLlmMsg.includes(code) && domLlmMsg.includes('Server error') && zhLeftovers.length === 0,
        `Scenario 2: DOM #sp_llmmsg presents HTTP ${code} in English (no Chinese)`,
        { domText: domLlmMsg, zhResiduals: zhLeftovers }
      );
    }

    // ==========================================
    // 场景 3: UPnP 协商失败 (SOAP 协商阶段显式拒绝)
    // ==========================================
    console.log('\n--- Scenario 3: UPnP Negotiation Failure ---');
    stubMode = 'upnp';

    // 切换到流媒体/输出设置页签
    await browserSession.eval("openSettingsTab('stream')");
    await pause(300);

    // 调用真实生产端点 /api/cast/start，显式指定 device 为 stub 描述地址，serve port 为 19105 (或同级)
    const castStartResp = await (
      await fetch(`http://127.0.0.1:${port}/api/cast/start`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `dev=${encodeURIComponent(`http://127.0.0.1:${stubPort}/desc.xml`)}&file=${encodeURIComponent(silenceWav)}&port=${stubPort}`,
      })
    ).json();

    // /api/cast/start 在启动 worker 线程后返回 started:true，worker 会在 SetAVTransportURI 时失败
    recordResult(
      castStartResp.ok === true && castStartResp.started === true,
      'Scenario 3: /api/cast/start successfully initiates session to stub renderer',
      { resp: castStartResp }
    );

    // 等待 CastManager worker 轮询并进入 error 状态
    let castErrState = null;
    for (let i = 0; i < 50; i++) {
      const st = await (await fetch(`http://127.0.0.1:${port}/api/cast/state`)).json();
      if (st.phase === 'error' && st.error) {
        castErrState = st;
        break;
      }
      await pause(100);
    }

    recordResult(
      castErrState !== null && castErrState.phase === 'error',
      'Scenario 3: /api/cast/state reaches phase=error on UPnP SOAP failure',
      { state: castErrState }
    );

    // 触发前端 pollCastState 刷新 UI
    await browserSession.eval('if (typeof pollCastState === "function") pollCastState(true);');
    await pause(400);

    const domCastPhase = await browserSession.eval(
      "document.getElementById('sp_cast_stat_phase') ? document.getElementById('sp_cast_stat_phase').textContent.trim() : ''"
    );
    const domCastMsg = await browserSession.eval(
      "document.getElementById('sp_cast_msg') ? document.getElementById('sp_cast_msg').textContent.trim() : ''"
    );
    const domCastErr = await browserSession.eval(
      "document.getElementById('sp_cast_stat_err') ? document.getElementById('sp_cast_stat_err').textContent.trim() : ''"
    );

    const shotPathCast = path.join(root, 'upnp-fault-negotiate.png');
    await browserSession.shot(shotPathCast);

    const zhCastPhase = extractChinese(domCastPhase);
    const zhCastMsg = extractChinese(domCastMsg);
    const zhCastErr = extractChinese(domCastErr);
    const allZhCast = [...zhCastPhase, ...zhCastMsg, ...zhCastErr];

    const castErrorText = domCastErr || domCastMsg;
    recordResult(
      domCastPhase.length > 0 && castErrorText.includes('714') && castErrorText.includes('Illegal MIME-Type'),
      'Scenario 3: UPnP DOM state displays non-empty error indicator matching SOAP fault',
      { phase: domCastPhase, msg: domCastMsg, err: domCastErr }
    );
    recordResult(
      allZhCast.length === 0 && (castErrState.errorEn || '').includes('714'),
      'Scenario 3: UPnP DOM error text has no Chinese residuals in English mode',
      { domPhase: domCastPhase, domMsg: domCastMsg, domErr: domCastErr, zhResiduals: allZhCast }
    );

    // 停止投放，恢复干净状态
    await fetch(`http://127.0.0.1:${port}/api/cast/stop`, { method: 'POST' });

    // ==========================================
    // 场景 4: 独占采样率不支持错误 (12345 Hz 真实 caps 拒绝)
    // ==========================================
    console.log('\n--- Scenario 4: Exclusive Unsupported Rate (12345 Hz) ---');
    // 使用真实 /api/play backend=wasapi rate=12345 bits=24 volume=-120 hogExclusive=0
    // 目标率 12345 绝对不在任何真实 CoreAudio caps 中，必定触发硬拒绝，且失败先于 sink.open
    const devices = await (await fetch(`http://127.0.0.1:${port}/api/devices`)).json();
    // Refuse the hardware path unless real read-only caps establish rejection.
    const rates = await (await fetch(`http://127.0.0.1:${port}/api/rates?bits=24`)).json();
    fs.writeFileSync(path.join(root, 'rate-safety-caps.json'), JSON.stringify({devices,rates}, null, 2));
    if (!Array.isArray(rates.rates) || rates.rates.length === 0 || rates.rates.includes(12345))
      throw Error('No exhaustive unsupported-rate evidence; no hardware request sent');
    const playResp = await (
      await fetch(`http://127.0.0.1:${port}/api/play`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `file=${encodeURIComponent(silenceWav)}&backend=wasapi&rate=12345&bits=24&volume=-120&hogExclusive=0`,
      })
    ).json();

    recordResult(
      playResp.ok === true,
      'Scenario 4: /api/play accepts request to start negotiation pipeline',
      { resp: playResp }
    );

    // 等待 /api/status 捕获真实的 negotiate.rate_unsupported 错误
    let statusErr = null;
    for (let i = 0; i < 60; i++) {
      const st = await (await fetch(`http://127.0.0.1:${port}/api/status`)).json();
      if (st.error) {
        statusErr = st.error;
        break;
      }
      await pause(100);
    }

    recordResult(
      statusErr !== null && statusErr.length > 0,
      'Scenario 4: /api/status reports non-empty error on unsupported rate 12345 Hz',
      { error: statusErr }
    );

    // 触发页面 tick 刷新底栏状态与错误显示
    await browserSession.eval('(typeof tick === "function" ? tick() : null)');
    await pause(500);

    const domNps = await browserSession.eval(
      "document.getElementById('nps') ? document.getElementById('nps').textContent.trim() : ''"
    );
    const shotPathRate = path.join(root, 'rate-fault-12345.png');
    await browserSession.shot(shotPathRate);

    const zhStatusRaw = extractChinese(statusErr);
    const zhDomNps = extractChinese(domNps);

    recordResult(
      zhStatusRaw.length === 0,
      'Scenario 4: /api/status error string is fully English (no Chinese residuals)',
      { statusErr, zhResiduals: zhStatusRaw }
    );
    recordResult(
      domNps.length > 0 && domNps.includes('12345') && domNps === statusErr && zhDomNps.length === 0,
      'Scenario 4: Bottom bar #nps displays unsupported rate error in English matching status',
      { domNps, zhResiduals: zhDomNps }
    );

    // ==========================================
    // 场景 5: 本地音频源文件损坏/截断投屏英文错误
    // ==========================================
    console.log('\n--- Scenario 5: Malformed and Truncated Local Audio Cast ---');
    // 5.1: 坏 WAV (badWav: "not a WAV: 17byte")
    const badWavResp = await (
      await fetch(`http://127.0.0.1:${port}/api/cast/start`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `dev=${encodeURIComponent(`http://127.0.0.1:${stubPort}/desc.xml`)}&file=${encodeURIComponent(badWav)}&port=${stubPort}`,
      })
    ).json();
    recordResult(badWavResp.ok === true, 'Scenario 5.1: /api/cast/start accepts malformed WAV task');

    let badWavState = null;
    for (let i = 0; i < 50; i++) {
      const st = await (await fetch(`http://127.0.0.1:${port}/api/cast/state`)).json();
      if (st.phase === 'error' && st.error) {
        badWavState = st;
        break;
      }
      await pause(100);
    }
    recordResult(
      badWavState !== null && badWavState.phase === 'error',
      'Scenario 5.1: /api/cast/state reaches phase=error on malformed WAV'
    );
    recordResult(
      (badWavState.errorEn || '').includes('not a valid WAV file') &&
      (badWavState.errorEn || '').includes('actual bytes=17'),
      'Scenario 5.1: cast state errorEn structures real read_wav header error in English',
      { errorEn: badWavState ? badWavState.errorEn : null }
    );

    await browserSession.eval('if (typeof pollCastState === "function") pollCastState(true);');
    await pause(400);
    const domBadWavErr = await browserSession.eval(
      "document.getElementById('sp_cast_stat_err') ? document.getElementById('sp_cast_stat_err').textContent.trim() : ''"
    );
    // 判据分层：① 真实路径必须逐字保留（含中文文件名）；② 路径之外不得残留中文。
    // 不能因为「路径里有中文」判红——那是用户文件的真实名字，翻译层本来就无权改写它。
    const badWavPathPreserved = domBadWavErr.includes(badWav);
    const zhBadWav = extractChinese(domBadWavErr.split(badWav).join('<preserved-path>'));
    recordResult(
      domBadWavErr.includes('not a valid WAV file') && badWavPathPreserved && zhBadWav.length === 0,
      'Scenario 5.1: DOM presents malformed WAV error in English without Chinese residuals (path preserved verbatim)',
      { domBadWavErr, pathPreserved: badWavPathPreserved, zhResidualsOutsidePath: zhBadWav }
    );
    await fetch(`http://127.0.0.1:${port}/api/cast/stop`, { method: 'POST' });

    // 5.2: 截断 WAV (truncatedWav: declared dataLen=88200, available=4)
    const truncWavResp = await (
      await fetch(`http://127.0.0.1:${port}/api/cast/start`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: `dev=${encodeURIComponent(`http://127.0.0.1:${stubPort}/desc.xml`)}&file=${encodeURIComponent(truncatedWav)}&port=${stubPort}`,
      })
    ).json();
    recordResult(truncWavResp.ok === true, 'Scenario 5.2: /api/cast/start accepts truncated WAV task');

    let truncWavState = null;
    for (let i = 0; i < 50; i++) {
      const st = await (await fetch(`http://127.0.0.1:${port}/api/cast/state`)).json();
      if (st.phase === 'error' && st.error) {
        truncWavState = st;
        break;
      }
      await pause(100);
    }
    recordResult(
      truncWavState !== null && truncWavState.phase === 'error',
      'Scenario 5.2: /api/cast/state reaches phase=error on truncated WAV'
    );
    recordResult(
      (truncWavState.errorEn || '').includes('data chunk truncated') &&
      (truncWavState.errorEn || '').includes('declared dataLen=88200 bytes'),
      'Scenario 5.2: cast state errorEn structures real read_wav truncation error in English',
      { errorEn: truncWavState ? truncWavState.errorEn : null }
    );

    await browserSession.eval('if (typeof pollCastState === "function") pollCastState(true);');
    await pause(400);
    const domTruncWavErr = await browserSession.eval(
      "document.getElementById('sp_cast_stat_err') ? document.getElementById('sp_cast_stat_err').textContent.trim() : ''"
    );
    const truncPathPreserved = domTruncWavErr.includes(truncatedWav);
    const zhTruncWav = extractChinese(domTruncWavErr.split(truncatedWav).join('<preserved-path>'));
    recordResult(
      domTruncWavErr.includes('data chunk truncated') && truncPathPreserved && zhTruncWav.length === 0,
      'Scenario 5.2: DOM presents truncated WAV error in English without Chinese residuals (path preserved verbatim)',
      { domTruncWavErr, pathPreserved: truncPathPreserved, zhResidualsOutsidePath: zhTruncWav }
    );
    await fetch(`http://127.0.0.1:${port}/api/cast/stop`, { method: 'POST' });

    // 5.3: 核验安全红线：整个故障过程中未向 stub 触发真实音频传输且未调用 Play
    recordResult(
      !soapActions.includes('Play'),
      'Scenario 5.3: Safety check - no SOAP Play action was sent during cast failure tests',
      { soapActions }
    );

  } catch (err) {
    console.error('Test execution error:', err);
    recordResult(false, 'Fatal exception during test execution', { error: String(err) });
  } finally {
    console.log('\nCleaning up owned processes gracefully...');
    await stopOwnedProcesses();
    const summaryFile = path.join(root, 'results.json');
    fs.writeFileSync(summaryFile, JSON.stringify(results, null, 2));
    console.log('EVIDENCE ' + root);
  }

  const anyFail = results.some((r) => !r.pass);
  process.exitCode = anyFail ? 1 : 0;
})();
