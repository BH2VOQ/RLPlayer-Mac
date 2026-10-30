// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_111_cast_flow.js —— UPnP 投放端到端回归：投放按钮同步（B2）+ 投放后切歌（B1）
//
// 两个已定位的真机 bug（2026-10-30 用户实测）：
//   B2 按钮不同步：点「推送到设备」→ 选设备后投放真的起来了（/api/cast/state running=true），
//      但单曲页 #npCastBtn 一直停在「推送到设备」，用户以为没投上。
//      根因形态：castPush() 里那次 pollCastState(true) 是**一次性**轮询，可能比后端
//      CastManager::start() 更早返回 running=false，而之后没有任何重试；
//      单曲页只在 track 变化 / loadMeta 回来时重绘，同一首歌不会重绘 ⟹ 状态永久滞后。
//   B1 投放后切歌：投放 A 之后从库里点 B（走 POST /api/lib/play），该入口曾经无视
//      backend=upnp 无条件启动本地管线（make_sink("upnp") = NullSink，解码但不发声），
//      而 A 的投放会话仍在跑、/api/cast/state 的 sourceFile 始终是 A ⟹ 渲染器继续放 A。
//
// 判据（铁律 3：这些指标真能证明用户看到/听到的事吗？）
//   C1 必须在**同一个页面生命周期内**采样：投放后用 CDP 里 setInterval 每 100ms 读
//      #npCastBtn.textContent，5 秒内必须出现「已推送到 …」。不 reload、不重进单曲页 ——
//      一 reload 就等于替产品把状态刷对了，什么也证明不了。
//   C2 同时看四个互相独立的口径，缺一个都可能"看起来绿"：
//      · /api/status 的 current（前端底栏/单曲页标题跟随的真相源）
//      · /api/cast/state 的 sourceFile（投放会话自己的口径）
//      · stub 渲染器最后一次 SetAVTransportURI 的 DIDL <dc:title>（**远端真的收到了什么**）
//      · #npTitle 的文本（用户眼睛看到的）
//      只断言前两个会被"本地线程空转 + 投放会话没换曲"骗过，所以必须带上远端记录。
//   C3 负向（只在"页面已认为自己在投放"时才跑）：把 stub 换成拒绝 SetAVTransportURI（SOAP Fault 714），
//      走真实 UI 的「换设备」入口再推一次 ⟹ 失败后按钮必须回到「推送到设备」。
//      守的是"乐观更新必须带回退"：修 B2 最省事的写法是点下就先改成已推送，若不回退，
//      投放失败时用户看到的就是一个假的"已投放"。
//
// 假渲染器：本地回环 HTTP + SSDP 应答（239.255.255.250:1900 收 M-SEARCH，单播回 200）。
//   为什么能收到：rtaweb 把 M-SEARCH 从物理网卡发到组播地址，本机进程 join 同组即可收到
//   （实测可行）。发现之后按 location 选中我们那台，绝不按"第一个"选 —— 局域网里可能有
//   用户真实的渲染器（本次实测就同时发现了 MR4 音响）。
//
// 安全（铁律 1/2）：backend=null 起步，全程不打开任何音频设备；WAV 是 −70 dBFS 的
//   6 秒静音级正弦；投放只发到本地 stub，绝不碰 8899；停进程先只读核验属主再 SIGTERM，
//   绝不 kill -9 / force-kill；用户真实 state 目录只读不写（全部走隔离 HOME/STATE/LIB）。
//
// 用法：node tools/check_111_cast_flow.js [--binary <rtaweb>] [--keep|--clean]
//   二进制优先级：--binary > 环境变量 RLP_RTAWEB_BIN > build-mac/rtaweb。同一份脚本可直接跑红/绿两遍：
//     红（未修复版）：RLP_RTAWEB_BIN=/tmp/rtaweb-prefix-bin node tools/check_111_cast_flow.js
//     绿（修复版）  ：node tools/check_111_cast_flow.js
//   默认保留临时目录并打印 EVIDENCE 路径（含 cast-flow.png / results.json / rtaweb.log）；--clean 删除。
// 退出码：0 = 全绿；1 = 有红；2 = 端口被占等环境问题（一条判据都没跑）。
'use strict';
const fs = require('fs'), os = require('os'), path = require('path'), http = require('http'), dgram = require('dgram');
const { spawn, spawnSync } = require('child_process');
const ub = require('./uibrowser');

const args = process.argv.slice(2);
const argOf = (n, d) => { const i = args.indexOf(n); return i !== -1 && i + 1 < args.length ? args[i + 1] : d; };
const hasArg = (n) => args.indexOf(n) !== -1;
const repoRoot = path.resolve(__dirname, '..');
// 二进制优先级：--binary <path> > 环境变量 RLP_RTAWEB_BIN > build-mac/rtaweb。
// 用途（2026-10-30 主控要求）：同一份脚本跑红/绿两遍 ——
//   红：RLP_RTAWEB_BIN=/tmp/rtaweb-prefix-bin node tools/check_111_cast_flow.js
//   绿：node tools/check_111_cast_flow.js            （重建后的 build-mac/rtaweb）
const binary = path.resolve(argOf('--binary', process.env.RLP_RTAWEB_BIN || path.join(repoRoot, 'build-mac', 'rtaweb')));

// 端口铁律：rtaweb=19105，CDP=9711，stub=19108。8899 是用户正在用的实例，任何情况下都不探测、不连接。
const PORT = 19105;
const CDP_PORT = 9711;
const STUB_PORT = 19108;
const FORBIDDEN_PORTS = [8899];
for (const p of [PORT, CDP_PORT, STUB_PORT]) {
  if (FORBIDDEN_PORTS.includes(p)) throw new Error('禁用的端口: ' + p);
}

const STUB_NAME = 'RLP Stub Renderer';
const DESK_URL = `http://127.0.0.1:${STUB_PORT}/desc.xml`;   // 描述 URL = 设备描述地址（也是 castPush 落盘的 upnpdev）
const C1_SAMPLE_MS = 5000, C1_STEP_MS = 100;
const C2_WINDOW_MS = 5000;
const GLOBAL_DEADLINE_MS = 170000;   // 整体 ≤180s 的硬预算（留 10s 收尾）

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-cast-flow-'));
const env = {
  ...process.env,
  HOME: path.join(root, 'home'),
  RLPLAYER_STATE_DIR: path.join(root, 'state'),
  RLPLAYER_LIBRARY_DIR: path.join(root, 'lib'),
};
// ---------------- ps 兼容层 ----------------
// 事实（2026-10-30 本机实测）：/bin/ps 是 setuid root，workspace-write 沙箱会直接拒绝执行
// （bash: /bin/ps: Operation not permitted）。uibrowser.js 的进程归属核验依赖
// `ps -p <pid> -o uid=,ppid=,comm=`，没有 ps 时它会拒绝 SIGTERM 自己的浏览器（内核是对的，
// 但测试会卡在"浏览器起来了却关不掉"）。这里在 ps 不可用时装一个**只读**的等价实现：
// 用 libproc（proc_pidinfo/proc_pidpath）读内核里的真实 uid/ppid/可执行路径，
// 事实来源不同、口径完全相同，不是伪造。可用 ps 的环境一律走真 ps，装了会打印一行 INFO。
function setupPsShim() {
  const probe = spawnSync('ps', ['-p', String(process.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' });
  if (probe.status === 0 && /\S/.test(probe.stdout || '')) return { used: false };
  const bindir = path.join(root, 'bin');
  fs.mkdirSync(bindir, { recursive: true });
  const py = path.join(bindir, 'ps_shim.py');
  fs.writeFileSync(py, [
    'import ctypes, ctypes.util, os, struct, sys',
    'PROC_PIDTBSDINFO = 3',
    'lib = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")',
    'pid = None',
    'for i, a in enumerate(sys.argv):',
    '    if a == "-p" and i + 1 < len(sys.argv):',
    '        pid = int(sys.argv[i + 1])',
    'if pid is None:',
    '    sys.exit(1)',
    'buf = ctypes.create_string_buffer(4096)',
    'n = lib.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buf, ctypes.sizeof(buf))',
    'if n <= 0:',
    '    sys.exit(1)',
    'data = buf.raw[:n]',
    'ppid = struct.unpack_from("<I", data, 16)[0]',
    'uid = struct.unpack_from("<I", data, 20)[0]',
    'pb = ctypes.create_string_buffer(4096)',
    'r = lib.proc_pidpath(pid, pb, ctypes.sizeof(pb))',
    'comm = os.path.basename(pb.value.decode("utf-8", "replace")) if r > 0 else data[48:64].split(b"\\x00")[0].decode("utf-8", "replace")',
    'sys.stdout.write("%d %d %s\\n" % (uid, ppid, comm))',
  ].join('\n') + '\n');
  const sh = path.join(bindir, 'ps');
  fs.writeFileSync(sh, '#!/bin/sh\nexec python3 ' + JSON.stringify(py) + ' "$@"\n', { mode: 0o755 });
  fs.chmodSync(sh, 0o755);
  process.env.PATH = bindir + ':' + (process.env.PATH || '');
  const again = spawnSync('ps', ['-p', String(process.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' });
  return { used: true, ok: again.status === 0 && /\S/.test(again.stdout || ''), line: (again.stdout || '').trim() };
}

const results = [];
const ck = (v, name, data) => {
  results.push({ pass: !!v, name, data });
  console.log((v ? 'PASS ' : 'FAIL ') + name + (data === undefined ? '' : ('  ' + JSON.stringify(data))));
};
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const elapsed = () => ((Date.now() - t0) / 1000).toFixed(1) + 's';

// ---------------- 进程/端口只读核验 ----------------
// 事实（2026-10-30 本机实测）：/bin/ps 是 setuid root，workspace-write 沙箱会直接拒绝执行
// （bash: /bin/ps: Operation not permitted，exit 126）。所以属主核验走「pgrep + lsof」等价三件套：
//   ① pgrep -u <本人 uid> -f "port 19105"   命令行里必须真有我们的 --port 19105
//   ② lsof -p <pid> -a -d cwd               工作目录必须是本次唯一的临时目录
//   ③ lsof -a -p <pid> -iTCP:19105 -sTCP:LISTEN  监听的必须是我们的端口
// 三条同时成立才允许发 SIGTERM；任何一条不成立就拒绝发信号，留给人工。
// （ps 可用的环境仍优先用 ps 的 uid/ppid/comm —— 更直接。两条路都是只读核验。）
const REAL_PS = (() => {
  try {
    const r = spawnSync('ps', ['-p', String(process.pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' });
    return { ok: r.status === 0 && /\S/.test(r.stdout || ''), line: (r.stdout || '').trim() };
  } catch (e) { return { ok: false, line: '' }; }
})();
function psLine(pid) {
  if (!REAL_PS.ok) return null;
  try {
    const r = spawnSync('ps', ['-p', String(pid), '-o', 'uid=,ppid=,comm='], { encoding: 'utf8' });
    if (r.status === 0 && r.stdout && r.stdout.trim()) return r.stdout.trim();
    return null;
  } catch (e) { return null; }
}
function portListenerPids(port) {
  const lsofBin = fs.existsSync('/usr/sbin/lsof') ? '/usr/sbin/lsof' : 'lsof';
  const r = spawnSync(lsofBin, ['-nP', '-a', `-iTCP:${port}`, '-sTCP:LISTEN', '-Fp'], { encoding: 'utf8' });
  if (r.status === 1 && !r.stdout) return [];
  if (r.status !== 0) throw new Error('lsof 检查端口 ' + port + ' 失败: ' + r.stderr);
  return String(r.stdout || '').split('\n').map((l) => l.trim())
    .filter((l) => /^p\d+$/.test(l)).map((l) => parseInt(l.slice(1), 10));
}
function pidCwd(pid) {
  const lsofBin = fs.existsSync('/usr/sbin/lsof') ? '/usr/sbin/lsof' : 'lsof';
  const r = spawnSync(lsofBin, ['-p', String(pid), '-a', '-d', 'cwd', '-Fn'], { encoding: 'utf8' });
  const m = /^n(.+)$/m.exec(String(r.stdout || ''));
  return m ? m[1].trim() : '';
}
function pgrepOwned(pid, needle) {
  const r = spawnSync('pgrep', ['-u', String(process.getuid()), '-f', needle], { encoding: 'utf8' });
  const pids = String(r.stdout || '').split('\n').map((s) => parseInt(s, 10)).filter((n) => n > 0);
  return { pids, hit: pids.includes(pid) };
}
function alive(pid) { try { process.kill(pid, 0); return true; } catch (e) { return false; } }
// 等子进程退出（带超时且超时后清掉定时器 —— 否则残留的 10s Timer 会让脚本"跑完不退出"）
function waitExit(child, ms) {
  return new Promise((resolve) => {
    if (!child || child.exitCode !== null || child.signalCode !== null) return resolve(true);
    const onExit = () => { clearTimeout(timer); resolve(true); };
    const timer = setTimeout(() => { child.removeListener('exit', onExit); resolve(false); }, ms);
    child.once('exit', onExit);
  });
}
// 返回 {ok, how, detail}：uid/comm/ppid（ps）或 pgrep+监听端口+cwd 三件套（ps 不可用时）。
function verifyOwned(pid, expectComm, expectPort) {
  if (!alive(pid)) return { ok: false, how: 'alive', detail: 'process not alive' };
  const line = psLine(pid);
  if (line) {
    const m = line.match(/^(\d+)\s+(\d+)\s+(.+)$/);
    if (!m) return { ok: false, how: 'ps', detail: 'unparsable ps line: ' + line };
    const ok = (+m[1] === process.getuid()) && (+m[2] === process.pid) &&
               (path.basename(m[3]) === expectComm);
    return { ok, how: 'ps', detail: line };
  }
  const listeners = portListenerPids(expectPort);
  const pg = pgrepOwned(pid, 'port ' + expectPort);
  let cwd = pidCwd(pid);
  let want = root;
  try { cwd = fs.realpathSync(cwd); } catch (e) { }
  try { want = fs.realpathSync(root); } catch (e) { }
  const ok = (listeners.length === 1 && listeners[0] === pid) && pg.hit && (cwd === want);
  return { ok, how: 'pgrep+lsof', detail: 'portListener=' + JSON.stringify(listeners) +
    ' pgrepHit=' + pg.hit + ' cwd=' + JSON.stringify(cwd) + ' expected cwd=' + JSON.stringify(want) };
}

// ---------------- stub：UPnP MediaRenderer（HTTP + SSDP） ----------------
const stub = {
  actions: [],        // [{action, at}]
  setUri: [],         // [{uri, title, at}]
  ssdpSearchSeen: 0, ssdpReplies: 0,
  httpReq: 0,
  failSetUri: false,  // true = SetAVTransportURI 一律回 SOAP Fault（C3 负向判据用）
  server: null, udp: null,
  lastUri: '',
};
const xmlDeesc = (s) => String(s).replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
const xmlEsc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const descXml = () => `<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><device>
<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>${STUB_NAME}</friendlyName>
<manufacturer>RLP-Test</manufacturer>
<modelName>RLP-STUB-1</modelName>
<UDN>uuid:5f0c1a2e-1111-4b2a-9a10-0c0ffee0beef</UDN>
<serviceList>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><serviceId>urn:upnp-org:serviceId:AVTransport</serviceId><controlURL>/avt/control</controlURL><eventSubURL>/avt/event</eventSubURL><SCPDURL>/avt/scpd.xml</SCPDURL></service>
<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId><controlURL>/cm/control</controlURL><eventSubURL>/cm/event</eventSubURL><SCPDURL>/cm/scpd.xml</SCPDURL></service>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId><controlURL>/rc/control</controlURL><eventSubURL>/rc/event</eventSubURL><SCPDURL>/rc/scpd.xml</SCPDURL></service>
</serviceList></device></root>`;
function soapEnvelope(action, inner) {
  return `<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">${inner}</u:${action}Response></s:Body></s:Envelope>`;
}
function xmlTagOf(xml, tag) {
  const m = new RegExp('<' + tag + '[^>]*>([\\s\\S]*?)</' + tag + '>').exec(xml);
  return m ? m[1].trim() : '';
}
function handleSoap(req, body) {
  const raw = xmlDeesc(body);
  const sa = String(req.headers.soapaction || '').replace(/"/g, '');
  const action = sa.split('#').pop() || 'Unknown';
  stub.actions.push(action);
  const ok = (inner) => ({ code: 200, body: soapEnvelope(action, inner) });
  if (action === 'SetAVTransportURI' && stub.failSetUri) {
    // C3 负向场景：渲染器拒绝换曲（UPnPError 714 Illegal MIME-Type 是真实设备常见的拒绝码）。
    stub.setUri.push({ uri: xmlTagOf(raw, 'CurrentURI'), title: 'REJECTED', at: Date.now(), failed: true });
    return { code: 500, body: `<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>714</errorCode><errorDescription>Illegal MIME-Type</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>` };
  }
  if (action === 'SetAVTransportURI') {
    const uri = xmlTagOf(raw, 'CurrentURI');
    const meta = xmlTagOf(raw, 'CurrentURIMetaData');
    const title = /<dc:title>([\s\S]*?)<\/dc:title>/.exec(meta);
    stub.lastUri = uri;
    stub.setUri.push({ uri, title: title ? title[1].trim() : '', at: Date.now() });
    return ok('<InstanceID>0</InstanceID>');
  }
  if (action === 'Play' || action === 'Pause' || action === 'Stop' || action === 'Seek' ||
      action === 'SetVolume' || action === 'SetMute' || action === 'Next' || action === 'Previous') {
    return ok('<InstanceID>0</InstanceID>');
  }
  if (action === 'GetTransportInfo') {
    // 恒回 PLAYING：cast_service 的轮询在 transport=STOPPED 且 elapsed>2s 时会主动结束会话。
    return ok('<CurrentTransportState>PLAYING</CurrentTransportState>' +
              '<CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>');
  }
  if (action === 'GetPositionInfo') {
    return ok('<Track>1</Track><TrackDuration>00:00:06</TrackDuration>' +
              '<TrackMetaData></TrackMetaData><TrackURI>' + xmlEsc(stub.lastUri) + '</TrackURI>' +
              '<RelTime>00:00:01</RelTime><AbsTime>00:00:01</AbsTime>' +
              '<RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount>');
  }
  if (action === 'GetMediaInfo') {
    return ok('<NrTracks>1</NrTracks><MediaDuration>00:00:06</MediaDuration>' +
              '<CurrentURI>' + xmlEsc(stub.lastUri) + '</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>' +
              '<NextURI></NextURI><NextURIMetaData></NextURIMetaData>' +
              '<PlayMedium>NETWORK</PlayMedium><RecordMedium>NOT_IMPLEMENTED</RecordMedium>' +
              '<WriteStatus>NOT_IMPLEMENTED</WriteStatus>');
  }
  if (action === 'GetProtocolInfo') return ok('<Source></Source><Sink>http-get:*:audio/wav:*</Sink>');
  if (action === 'GetVolume') return ok('<CurrentVolume>50</CurrentVolume>');
  if (action === 'GetCurrentTransportActions') return ok('<Actions>Play,Pause,Stop,Seek</Actions>');
  return ok('<InstanceID>0</InstanceID>');
}
function startStub() {
  return new Promise((resolve, reject) => {
    const srv = http.createServer((req, res) => {
      stub.httpReq++;
      if (req.method === 'GET' && req.url === '/desc.xml') {
        const b = descXml();
        res.writeHead(200, { 'Content-Type': 'text/xml; charset="utf-8"', 'Content-Length': Buffer.byteLength(b) });
        res.end(b);
        return;
      }
      let body = '';
      req.on('data', (d) => { body += d; });
      req.on('end', () => {
        try {
          const r = handleSoap(req, body);
          const b = r.body;
          res.writeHead(r.code, { 'Content-Type': 'text/xml; charset="utf-8"', 'Content-Length': Buffer.byteLength(b) });
          res.end(b);
        } catch (e) {
          res.writeHead(500); res.end('stub error: ' + String(e));
        }
      });
    });
    srv.once('error', reject);
    srv.listen(STUB_PORT, '127.0.0.1', () => {
      stub.server = srv;
      // SSDP：join 239.255.255.250:1900，回单播 200。失败不致命（下面会退回页面注入设备）。
      const udp = dgram.createSocket({ type: 'udp4', reuseAddr: true });
      udp.on('message', (msg, rinfo) => {
        const s = msg.toString();
        if (s.indexOf('M-SEARCH') !== 0) return;
        stub.ssdpSearchSeen++;
        const reply = 'HTTP/1.1 200 OK\r\n' +
          'CACHE-CONTROL: max-age=1800\r\nEXT:\r\n' +
          'LOCATION: ' + DESK_URL + '\r\n' +
          'SERVER: macOS/1 UPnP/1.0 RLPStub/1\r\n' +
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n' +
          'USN: uuid:5f0c1a2e-1111-4b2a-9a10-0c0ffee0beef::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
        try { udp.send(Buffer.from(reply), rinfo.port, rinfo.address); stub.ssdpReplies++; } catch (e) { }
      });
      udp.on('error', (e) => { console.log('       [stub] SSDP socket 错误（不影响 HTTP 部分）：' + String(e)); });
      udp.bind(1900, () => {
        // 先按默认路由入组，再逐张物理网卡入组（rtaweb 是逐卡发 M-SEARCH 的，默认路由未必是那张卡）。
        // 重复入同一组会抛 EADDRINUSE，属正常，忽略即可。
        const groups = [[]];
        for (const [, addrs] of Object.entries(os.networkInterfaces())) {
          for (const a of addrs || []) {
            if (a.family === 'IPv4' && !a.internal) groups.push([a.address]);
          }
        }
        for (const g of groups) {
          try {
            if (g[0]) udp.addMembership('239.255.255.250', g[0]);
            else udp.addMembership('239.255.255.250');
          } catch (e) { }
        }
      });
      stub.udp = udp;
      resolve();
    });
  });
}
function stopStub() {
  return new Promise((resolve) => {
    let finished = false, pending = 2, timer = null;
    const finish = () => { if (finished) return; finished = true; if (timer) clearTimeout(timer); resolve(); };
    const done = () => { if (--pending <= 0) finish(); };
    timer = setTimeout(finish, 1200);
    try { if (stub.udp) stub.udp.close(done); else done(); } catch (e) { done(); }
    try {
      if (stub.server) {
        if (typeof stub.server.closeAllConnections === 'function') stub.server.closeAllConnections();
        stub.server.close(done);
      } else done();
    } catch (e) { done(); }
  });
}

// ---------------- HTTP 客户端（每个请求都有超时，绝不挂死） ----------------
function httpText(pathOrUrl, body) {
  const url = /^https?:/.test(pathOrUrl) ? pathOrUrl : ('http://127.0.0.1:' + PORT + pathOrUrl);
  const opt = body === undefined ? {} : { method: 'POST', body };
  return fetch(url, { ...opt, signal: AbortSignal.timeout(8000) }).then((r) => r.text());
}
async function apiJson(p, body) {
  const t = await httpText(p, body);
  try { return JSON.parse(t); } catch (e) { throw new Error('非 JSON 响应 ' + p + ': ' + t.slice(0, 200)); }
}

// ---------------- 场景准备 ----------------
function makeWav(file) {
  // ffmpeg-lite 没有 lavfi，用 python3 的 wave 模块手写；−70 dBFS 是为了铁律 1。
  const py = [
    'import wave,math,struct,sys',
    'w=wave.open(sys.argv[1],"wb");w.setnchannels(2);w.setsampwidth(2);w.setframerate(44100)',
    'n=44100*6;amp=int(32768*10**(-70/20.0))',
    'fr=bytearray()',
    'for i in range(n):',
    '    v=int(amp*math.sin(2*math.pi*440.0*i/44100.0))',
    '    fr+=struct.pack("<hh",v,v)',
    'w.writeframes(bytes(fr));w.close()',
  ].join('\n');
  const r = spawnSync('python3', ['-c', py, file], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error('写 WAV 失败 ' + file + ': ' + (r.stderr || r.stdout));
}

// ---------------- UI 侧脚本片段 ----------------
const SAMPLE_CAST_BTN = (ms, step) => `(() => {
  window.__CASTBTN = { t0: performance.now(), samples: [], done: false };
  var t = setInterval(function () {
    var el = document.getElementById('npCastBtn');
    window.__CASTBTN.samples.push({ t: Math.round(performance.now() - window.__CASTBTN.t0),
      text: el ? el.textContent.trim() : null });
    if (window.__CASTBTN.samples.length * ${step} >= ${ms}) {
      clearInterval(t); window.__CASTBTN.done = true;
    }
  }, ${step});
  return true;
})()`;

const READ_CAST_BTN = `(() => {
  var s = window.__CASTBTN || { samples: [] };
  var runs = [], prev = null;
  s.samples.forEach(function (x) {
    if (!runs.length || runs[runs.length - 1].text !== x.text)
      runs.push({ t: x.t, text: x.text, n: 1 });
    else runs[runs.length - 1].n++;
    prev = x.text;
  });
  var hit = null;
  s.samples.forEach(function (x) { if (hit === null && x.text && x.text.indexOf('已推送到') >= 0) hit = x.t; });
  return { done: !!s.done, n: s.samples.length, runs: runs,
           firstPushedAtMs: hit, last: prev, cast: (window.CAST && window.CAST.state) || null };
})()`;

(async () => {
  let child = null, session = null, logFd = null, aborted = 'startup', envAbort = false;
  const watchdog = setTimeout(() => {
    console.log('FAIL 全局看门狗：超过 ' + Math.round(GLOBAL_DEADLINE_MS / 1000) + 's，停在 ' + aborted + '，强制收尾');
    try {
      if (child && child.exitCode === null) {
        const v = verifyOwned(child.pid, path.basename(binary), PORT);
        console.log('       看门狗核验 pid=' + child.pid + ' → ' + v.how + ': ' + v.detail);
        if (v.ok) { child.kill('SIGTERM'); }
      }
    } catch (e) { }
    try { if (session) session.close(); } catch (e) { }
    process.exit(1);
  }, GLOBAL_DEADLINE_MS);
  watchdog.unref();

  try {
    // ---- 0. 目录与素材 ----
    for (const k of ['HOME', 'RLPLAYER_STATE_DIR', 'RLPLAYER_LIBRARY_DIR']) fs.mkdirSync(env[k], { recursive: true });
    fs.mkdirSync(path.join(root, 'music'));
    fs.writeFileSync(path.join(env.RLPLAYER_STATE_DIR, 'rlplayer-settings.conf'),
      'backend=null\nmetaon=0\nmetallm=0\nvolume=-120\ntheme=light\nuistyle=apple\nlang=zh\n');
    const dirA = path.join(env.RLPLAYER_LIBRARY_DIR, 'Album A');
    const dirB = path.join(env.RLPLAYER_LIBRARY_DIR, 'Album B');
    fs.mkdirSync(dirA, { recursive: true });
    fs.mkdirSync(dirB, { recursive: true });
    const fileA = path.join(dirA, 'A.wav'), fileB = path.join(dirB, 'B.wav');
    makeWav(fileA); makeWav(fileB);
    console.log('INFO 隔离目录 ' + root);
    console.log('INFO 素材 A=' + fileA + ' (' + fs.statSync(fileA).size + ' B), B=' + fileB + ' (' + fs.statSync(fileB).size + ' B)');
    console.log('INFO 二进制 ' + binary);
    const shim = setupPsShim();
    if (REAL_PS.ok) console.log('INFO ps 可用，属主核验走 ps（uid/ppid/comm）：' + REAL_PS.line);
    else console.log('INFO ps 不可用（沙箱拒绝执行 setuid /bin/ps）；rtaweb 属主核验改走 pgrep+lsof 三件套；' +
      'uibrowser 内部的 ps 调用用 libproc 只读等价实现兜底（install=' + JSON.stringify(shim) + '）');

    // ---- 1. 端口预检（任何一条被占都直接退出，绝不碰别人的进程） ----
    const busy = [];
    for (const [name, p] of [['rtaweb', PORT], ['CDP', CDP_PORT], ['stub', STUB_PORT]]) {
      const ls = portListenerPids(p);
      if (ls.length) busy.push(name + ':' + p + '(pid=' + ls.join(',') + ')');
    }
    if (busy.length) {
      console.log('FAIL 端口预检：' + busy.join(' ') + ' 已被占用，拒绝启动（不探测、不接管他人进程）');
      results.push({ pass: false, name: '端口预检', data: busy });
      envAbort = true;
      throw new Error('port busy');
    }
    ck(true, '端口预检：' + PORT + '/' + CDP_PORT + '/' + STUB_PORT + ' 全部空闲（8899 全程未触碰）',
      { rtaweb: PORT, cdp: CDP_PORT, stub: STUB_PORT });

    // ---- 2. 假渲染器 ----
    aborted = 'stub 启动';
    await startStub();
    ck(true, '假 MediaRenderer 已就绪（desc.xml + AVTransport/CM/RenderingControl SOAP）', { url: DESK_URL });

    // ---- 3. rtaweb ----
    aborted = 'rtaweb 启动';
    if (!fs.existsSync(binary)) throw new Error('找不到二进制 ' + binary);
    logFd = fs.openSync(path.join(root, 'rtaweb.log'), 'a');
    child = spawn(binary, ['--port', String(PORT), '--music-dir', env.RLPLAYER_LIBRARY_DIR],
      { env, cwd: root, stdio: ['ignore', logFd, logFd] });
    let up = false;
    for (let i = 0; i < 150; i++) {
      if (child.exitCode !== null) throw new Error('rtaweb 启动后立刻退出（exit=' + child.exitCode + '），见 ' + path.join(root, 'rtaweb.log'));
      try { if ((await fetch('http://127.0.0.1:' + PORT + '/api/ping', { signal: AbortSignal.timeout(1000) })).ok) { up = true; break; } } catch (e) { }
      await pause(100);
    }
    if (!up) throw new Error('rtaweb 未在 15s 内就绪，见 ' + path.join(root, 'rtaweb.log'));
    const own = verifyOwned(child.pid, path.basename(binary), PORT);
    console.log('INFO rtaweb pid=' + child.pid + ' 属主核验(' + own.how + '): ' + own.detail);
    ck(own.ok, '测试实例属主核验通过（uid/ppid/comm 或 lsof 监听归属）', own);
    console.log('INFO 设置：backend=null（绝不出声）');
    await apiJson('/api/settings', 'backend=null&metaon=0&metallm=0&volume=-120&lang=zh&theme=light');

    // ---- 4. 扫库 ----
    aborted = '扫库';
    await apiJson('/api/lib/scan', '');
    let stats = null;
    for (let i = 0; i < 100; i++) {
      stats = await apiJson('/api/lib/status');
      if (!stats.scanning) break;
      await pause(150);
    }
    console.log('INFO 扫库结果 ' + JSON.stringify({ scanning: stats.scanning, tracks: stats.tracks, albums: stats.albums, msg: stats.msg }));
    const albums = (await apiJson('/api/lib/albums')).albums || [];
    const albumOf = (name) => albums.find((a) => String(a.name || '').indexOf(name) >= 0);
    const albA = albumOf('Album A'), albB = albumOf('Album B');
    ck(!!albA && !!albB, '曲库扫出 A / B 两张专辑', { albums: albums.map((a) => ({ k: a.k, name: a.name, n: a.n })) });
    if (!albA || !albB) throw new Error('曲库未扫出两张专辑，无法继续');
    const tracksA = (await apiJson('/api/lib/album?k=' + encodeURIComponent(albA.k))).tracks || [];
    const tracksB = (await apiJson('/api/lib/album?k=' + encodeURIComponent(albB.k))).tracks || [];
    const pathA = (tracksA[0] || {}).path, pathB = (tracksB[0] || {}).path;
    ck(pathA === fileA && pathB === fileB, '专辑里的曲目路径就是 A/B 两个夹具',
      { pathA, pathB, fileA, fileB });
    if (pathA !== fileA || pathB !== fileB) throw new Error('曲目路径与夹具不一致');
    const stemA = path.basename(fileA), stemB = path.basename(fileB);

    // ---- 5. 发现：先验证 SSDP 能看到我们的 stub ----
    aborted = 'SSDP 发现';
    let devices = null;
    for (let i = 0; i < 6; i++) {
      devices = await apiJson('/api/cast/devices?scan=1');
      if ((devices.devices || []).some((d) => (d.location || '') === DESK_URL)) break;
      await pause(500);
    }
    const mine = (devices.devices || []).find((d) => (d.location || '') === DESK_URL);
    const others = (devices.devices || []).filter((d) => (d.location || '') !== DESK_URL)
      .map((d) => d.friendlyName + '@' + d.host);
    console.log('INFO /api/cast/devices → n=' + devices.n + ' diag=' + JSON.stringify(devices.diag) +
      ' 其它设备=' + JSON.stringify(others));
    const discovered = !!mine && mine.hasAVTransport === true;
    ck(discovered, 'SSDP 真发现假渲染器（带 AVTransport 控制地址）',
      mine || { ssdpSearchSeen: stub.ssdpSearchSeen, ssdpReplies: stub.ssdpReplies, devices: devices.devices });
    if (!discovered) {
      console.log('WARN SSDP 发现失败：退回「把设备注入页面发现缓存」的方式（模态框与点击仍是生产代码），' +
        '本轮不判「发现」为绿');
    }

    // ---- 6. headless Edge ----
    aborted = '浏览器启动';
    session = await ub.open({ url: 'http://127.0.0.1:' + PORT + '/', port: CDP_PORT });
    const ready = await session.waitFor("typeof playAlbum==='function' && typeof castPush==='function' && document.getElementById('bHelp')", 20000);
    if (!ready) throw new Error('页面未就绪（playAlbum/castPush/bHelp）');
    ck(true, 'headless Edge 就绪（页面同一生命周期，之后绝不 reload）', { cdp: CDP_PORT });

    // ---- 7. C1：先本地播 A（走页面自己的播放路径），再推送 ----
    aborted = 'C1 播放 A';
    await session.eval("playAlbum(" + JSON.stringify(albA.k) + ", 0)");
    // 必须等**页面自己**跟上（S.lastCur），不能只看 /api/status：castPush 读的就是 S.lastCur，
    // 页面状态轮询还没跑到时点按钮会走「当前没有可推送的曲目」空分支（实测踩到）。
    let curOk = false, curSeen = '', pageCur = '';
    for (let i = 0; i < 50; i++) {
      const st = await apiJson('/api/status');
      curSeen = st.current || '';
      pageCur = await session.eval("String(S.lastCur || '')");
      if (curSeen === fileA && pageCur === fileA) { curOk = true; break; }
      await pause(150);
    }
    ck(curOk, 'C1 前置：页面播放路径让 /api/status.current 与页面 S.lastCur 都 = A',
      { current: curSeen, pageLastCur: pageCur, expect: fileA });

    aborted = 'C1 打开单曲页';
    await session.eval("openNowPlaying()");
    const btnPre = await session.eval(
      "(() => { var b=document.getElementById('npCastBtn'); " +
      "return b ? { text: b.textContent.trim(), html: b.innerHTML.slice(0,60) } : null; })()");
    console.log('INFO 推送前 #npCastBtn = ' + JSON.stringify(btnPre));
    ck(!!btnPre && btnPre.text === '推送到设备', 'C1：单曲页按钮存在且文本是「推送到设备」', btnPre);

    // 诊断（不参与判定）：数一下页面在投放窗口内到底请求了几次 /api/cast/state。
    // 旧代码只在 castPush 里 pollCastState(true) **一次** ⟹ 1 次；修好后应 ≥2 次（轮询/重试）。
    await session.eval(`(() => {
      if (!window.__rlpFetchOrig) {
        window.__rlpFetchOrig = window.fetch;
        window.fetch = function (u, o) {
          if (String(u).indexOf('/api/cast/state') === 0) window.__castStateReqs = (window.__castStateReqs || 0) + 1;
          return window.__rlpFetchOrig.call(window, u, o);
        };
      }
      window.__castStateReqs = 0;
      return true;
    })()`);

    // 选设备：点按钮 → 等列表里出现我们的 stub → 点它（绝不点"第一台"，局域网可能有真设备）
    aborted = 'C1 打开设备选择框';
    await session.eval("document.getElementById('npCastBtn').click()");
    const rowsExpr = "Array.from(document.querySelectorAll('#mbody .castpick-row')).map(function(b){return b.textContent.trim();})";
    let rowText = null, clicked = null;
    for (let i = 0; i < 60 && !rowText; i++) {
      const rows = await session.eval(rowsExpr);
      rowText = (rows || []).find((t) => t.indexOf(STUB_NAME) >= 0);
      if (!rowText) await pause(200);
    }
    if (rowText) {
      aborted = 'C1 点击设备并采样按钮';
      clicked = await session.eval(
        "(() => { var rows=Array.from(document.querySelectorAll('#mbody .castpick-row')); " +
        "var b=rows.find(function(x){return x.textContent.indexOf(" + JSON.stringify(STUB_NAME) + ")>=0;}); " +
        "if(!b) return null; var t=b.textContent.trim(); b.click(); return t; })()");
    } else if (!discovered) {
      // SSDP 不可用时的退路：把设备塞进页面发现缓存，再重开一次选择框并当场点它
      // （模态框渲染、设备行点击、castPush 全是生产代码；只是"发现结果"由测试注入）。
      aborted = 'C1 点击设备并采样按钮（页面注入退路）';
      clicked = await session.eval(`(() => {
        var m = document.getElementById('modal'); if (m) m.classList.remove('on');
        _castDevices = [{location:${JSON.stringify(DESK_URL)},friendlyName:${JSON.stringify(STUB_NAME)},
                         model:'RLP-STUB-1',host:'127.0.0.1',port:${STUB_PORT},hasAVTransport:true}];
        castPush(S.lastCur);
        var b = Array.from(document.querySelectorAll('#mbody .castpick-row'))
          .find(function(x){ return x.textContent.indexOf(${JSON.stringify(STUB_NAME)}) >= 0; });
        if (!b) return null;
        var t = b.textContent.trim(); b.click(); return t;
      })()`);
      rowText = clicked;
    }
    ck(!!rowText, 'C1：设备选择框里出现假渲染器（' + (discovered ? 'SSDP 真发现' : '页面注入退路') + '）',
      { rowText, rows: await session.eval(rowsExpr) });
    if (!rowText) {
      const dbg = await session.eval(`(() => ({
        modalClass: (document.getElementById('modal') || {}).className,
        mbody: String((document.getElementById('mbody') || {}).innerHTML || '').slice(0, 300),
        lastCur: S.lastCur, castState: CAST.state, devices: (_castDevices || []).length,
        toast: String((document.getElementById('toast') || {}).textContent || '')
      }))()`);
      console.log('DEBUG 选择框为空：' + JSON.stringify(dbg));
      console.log('DEBUG 页面异常：' + JSON.stringify((session.errors || []).slice(-4)));
      throw new Error('设备选择框里没有假渲染器，无法继续');
    }

    aborted = 'C1 点击设备并采样按钮';
    console.log('INFO 点击设备行：' + JSON.stringify(clicked) + ' @ ' + elapsed());
    await session.eval(SAMPLE_CAST_BTN(C1_SAMPLE_MS, C1_STEP_MS));

    // 采样窗口内同时看后端口径（每 ~700ms 一次），定位用
    const castTrace = [];
    const sampleUntil = Date.now() + C1_SAMPLE_MS;
    while (Date.now() < sampleUntil) {
      try {
        const st = await apiJson('/api/cast/state');
        castTrace.push({ t: Date.now() - t0, running: st.running, phase: st.phase, src: st.sourceFile, dev: st.device, err: st.error });
      } catch (e) { castTrace.push({ err: String(e) }); }
      await pause(700);
    }
    await pause(300);
    const btnRes = await session.eval(READ_CAST_BTN);
    console.log('INFO 按钮文本时间线（合并相邻相同值）：' + JSON.stringify(btnRes.runs));
    console.log('INFO /api/cast/state 采样：' + JSON.stringify(castTrace.map((c) => (c.err ? c.err : (c.phase + '/' + (c.running ? 'running' : 'stopped'))))));
    console.log('INFO 页面 CAST.state = ' + JSON.stringify(btnRes.cast));
    const castSt = await apiJson('/api/cast/state');
    try { console.log('INFO 投放后 5s 内页面请求 /api/cast/state 次数 = ' + (await session.eval('window.__castStateReqs||0')) + '（旧代码只 poll 一次，修好后应 ≥2）'); } catch (e) { }
    console.log('INFO 采样后 /api/cast/state = ' + JSON.stringify(castSt));
    ck(btnRes.firstPushedAtMs !== null,
      'C1（B2 按钮同步）：投放后 5s 内 #npCastBtn 出现「已推送到 …」（同一页面生命周期，未 reload）',
      { firstPushedAtMs: btnRes.firstPushedAtMs, last: btnRes.last, samples: btnRes.n });
    ck(castSt.running === true && castSt.sourceFile === fileA,
      'C1 对照：后端确实在投放 A（证明判据不是"什么都没发生"）',
      { running: castSt.running, phase: castSt.phase, sourceFile: castSt.sourceFile });
    ck((stub.setUri.length > 0) && (stub.setUri[stub.setUri.length - 1].title === stemA),
      'C1 对照：假渲染器收到 SetAVTransportURI(DIDL title = A.wav)',
      stub.setUri);
    const c1Ok = results.every((r) => r.name.indexOf('C1') !== 0 || r.pass);

    // ---- 8. C2：投放中从库里切到 B（走页面 playAlbum → POST /api/lib/play） ----
    aborted = 'C2 切歌';
    const advBefore = await session.eval("JSON.stringify({backend:ADV.backend,upnpDev:ADV.upnpDev})");
    console.log('INFO C2 前页面播放参数：' + advBefore);
    const setBefore = stub.setUri.length;
    const tC2 = Date.now();
    await session.eval("playAlbum(" + JSON.stringify(albB.k) + ", 0)");
    const first = { statusB: null, castB: null, uriB: null, titleB: null };
    let last = { status: '', castSrc: '', uriTitle: '', title: '' };
    while (Date.now() - tC2 < C2_WINDOW_MS) {
      try {
        const st = await apiJson('/api/status');
        last.status = st.current || '';
        if (first.statusB === null && last.status === fileB) first.statusB = Date.now() - tC2;
      } catch (e) { }
      try {
        const cs = await apiJson('/api/cast/state');
        last.castSrc = cs.sourceFile || '';
        if (first.castB === null && last.castSrc === fileB) first.castB = Date.now() - tC2;
      } catch (e) { }
      if (stub.setUri.length > setBefore) {
        const u = stub.setUri[stub.setUri.length - 1];
        last.uriTitle = u.title;
        if (first.uriB === null && u.title === stemB) first.uriB = Date.now() - tC2;
      }
      try {
        const ttl = await session.eval("(document.getElementById('npTitle')||{}).textContent||''");
        last.title = ttl;
        if (first.titleB === null && ttl.indexOf(stemB) >= 0) first.titleB = Date.now() - tC2;
      } catch (e) { }
      if (first.statusB !== null && first.castB !== null && first.uriB !== null && first.titleB !== null) break;
      await pause(150);
    }
    const stAfter = await apiJson('/api/status');
    const csAfter = await apiJson('/api/cast/state');
    // 请求是否真的落地：页面 playAlbum 会把队列整列换成 B 并 loadQ()；请求失败时队列仍是 A。
    // 没有这条，"切歌没反应"可能只是我们没发出去 —— 那样红就证明不了 bug。
    let qAfter = { items: [], index: 0, toast: '' };
    try {
      qAfter = await session.eval(`(() => ({
        items: ((S.q && S.q.items) || []).slice(0, 3),
        index: (S.q && S.q.index) || 0,
        toast: String((document.getElementById('toast') || {}).textContent || '')
      }))()`);
    } catch (e) { }
    console.log('INFO C2 取值：页面队列=' + JSON.stringify(qAfter.items) + ' index=' + qAfter.index +
      ' toast=' + JSON.stringify(qAfter.toast));
    console.log('INFO C2 取值：A=' + fileA + '  B=' + fileB);
    console.log('INFO C2 取值：status.current=' + JSON.stringify(stAfter.current) +
      '  cast.sourceFile=' + JSON.stringify(csAfter.sourceFile) +
      '  cast.running=' + csAfter.running + ' phase=' + csAfter.phase);
    console.log('INFO C2 取值：SetAVTransportURI 次数=' + stub.setUri.length + ' 最后一次=' +
      JSON.stringify(stub.setUri[stub.setUri.length - 1] || null));
    console.log('INFO C2 取值：#npTitle=' + JSON.stringify(last.title));
    ck(first.statusB !== null, 'C2：/api/status.current 在 5s 内变成 B', { ms: first.statusB, value: stAfter.current });
    ck(first.castB !== null, 'C2：/api/cast/state.sourceFile 在 5s 内变成 B', { ms: first.castB, value: csAfter.sourceFile });
    ck(first.uriB !== null, 'C2：假渲染器最后一次 SetAVTransportURI 的 DIDL title = B.wav（远端真收到了换曲）',
      { ms: first.uriB, title: stub.setUri.length ? stub.setUri[stub.setUri.length - 1].title : null,
        all: stub.setUri.map((u) => u.title) });
    ck(first.titleB !== null, 'C2：单曲页 #npTitle 在 5s 内变成 B 的文件名', { ms: first.titleB, value: last.title });
    const qLanded = (qAfter.items || []).indexOf(fileB) >= 0 || (qAfter.toast || '').indexOf('专辑') >= 0;
    ck(qLanded, 'C2 前置：页面 playAlbum 的 /api/lib/play 请求确实发出去了（队列/提示已换成 B）',
      { items: qAfter.items, toast: qAfter.toast });
    ck(c1Ok, 'C1 全部判据为绿（C2 的"投放中切歌"前提成立）', { c1Ok });

    // ---- 8b. C3（负向）：换设备时渲染器拒绝，按钮不能永远停在乐观态 ----
    // 为什么要有这条：修 B2 最省事的写法是"点下就先把按钮改成已推送"（乐观更新）。
    // 乐观更新必须配一条回退路径，否则投放失败时用户会看到一个假的"已投放"。
    aborted = 'C3 失败回退';
    const csPre = await apiJson('/api/cast/state');
    if (!csPre.running) {
      console.log('INFO C3 跳过：当前没有在跑的投放会话（C1 未成功），负向判据无从谈起');
    } else {
      stub.failSetUri = true;   // 让下一次 SetAVTransportURI 回 SOAP Fault 714
      await session.eval("document.getElementById('npCastBtn').click()");   // → 投放控制浮层
      const hasChange = await session.waitFor("!!document.getElementById('castActChange')", 4000);
      if (!hasChange) {
        console.log('INFO C3 跳过：页面不知道自己正在投放（CAST.state 没同步），没有「换设备」入口 —— ' +
          '这与 C1 是同一个 bug，不重复判红');
      } else {
        aborted = 'C3 换设备';
        await session.eval("document.getElementById('castActChange').click()");  // → castPush → 设备选择框
        let row3 = null;
        for (let i = 0; i < 50 && !row3; i++) {
          const rows = await session.eval(rowsExpr);
          row3 = (rows || []).find((t) => t.indexOf(STUB_NAME) >= 0);
          if (!row3) await pause(200);
        }
        ck(!!row3, 'C3 前置：换设备时选择框里仍能看到假渲染器', { row3 });
        if (row3) {
          aborted = 'C3 采样按钮回退';
          await session.eval(
            "(() => { var rows=Array.from(document.querySelectorAll('#mbody .castpick-row')); " +
            "var b=rows.find(function(x){return x.textContent.indexOf(" + JSON.stringify(STUB_NAME) + ")>=0;}); " +
            "if(!b) return null; b.click(); return true; })()");
          await session.eval(SAMPLE_CAST_BTN(C1_SAMPLE_MS, C1_STEP_MS));
          await pause(C1_SAMPLE_MS + 300);   // 必须等满采样窗口，否则只看到投放刚开始的那 300ms
          const btn3 = await session.eval(READ_CAST_BTN);
          const cs3 = await apiJson('/api/cast/state');
          console.log('INFO C3 按钮时间线：' + JSON.stringify(btn3.runs));
          console.log('INFO C3 失败后 /api/cast/state = ' + JSON.stringify({ running: cs3.running, phase: cs3.phase, error: cs3.error }));
          ck(btn3.last === '推送到设备',
            'C3（负向）：投放失败后 #npCastBtn 必须回到「推送到设备」，不能停在乐观态',
            { last: btn3.last, runs: btn3.runs });
          ck(cs3.running === false && cs3.phase === 'error',
            'C3 对照：后端如实报告投放失败（running=false, phase=error）',
            { running: cs3.running, phase: cs3.phase, error: cs3.error });
        }
      }
    }

    // ---- 9. 收尾证据 ----
    aborted = '收尾';
    try { await session.shot(path.join(root, 'cast-flow.png')); } catch (e) { }
    const pageErrors = session.errors || [];
    ck(pageErrors.length === 0, '无未捕获页面异常', pageErrors);
    console.log('INFO stub 收到动作序列（前 12 个）: ' + JSON.stringify(stub.actions.slice(0, 12)));
    console.log('INFO SSDP：收到 M-SEARCH ' + stub.ssdpSearchSeen + ' 次，回 200 ' + stub.ssdpReplies + ' 次');
  } catch (e) {
    ck(false, '执行异常（停在 ' + aborted + '）', { error: String(e && e.message || e), elapsed: elapsed() });
  } finally {
    clearTimeout(watchdog);
    // 收尾顺序：浏览器 → rtaweb（核验后 TERM）→ stub → 临时目录保留并打印路径
    if (session) {
      try { await session.close(); console.log('INFO 已关闭 headless Edge（SIGTERM + 核验归属）'); }
      catch (e) { console.log('WARN 关闭浏览器失败：' + String(e)); }
    }
    if (child && child.exitCode === null) {
      const v = verifyOwned(child.pid, path.basename(binary), PORT);
      console.log('INFO 停 rtaweb 前核验 pid=' + child.pid + ' → ' + v.how + ': ' + v.detail);
      if (!v.ok) {
        console.log('FAIL 属主核验不通过，拒绝发信号（留给人工处理）');
      } else {
        child.kill('SIGTERM');
        const exitedCleanly = await waitExit(child, 10000);
        if (!exitedCleanly) console.log('WARN rtaweb 在 TERM 后 10s 未退出（不 force-kill，留人工处理）');
        else console.log('INFO rtaweb 已优雅退出（exit=' + child.exitCode + '）');
      }
    }
    await stopStub();
    if (logFd !== null) { try { fs.closeSync(logFd); } catch (e) { } }
    fs.writeFileSync(path.join(root, 'results.json'),
      JSON.stringify({ binary, ports: { rtaweb: PORT, cdp: CDP_PORT, stub: STUB_PORT }, results, stub: { setUri: stub.setUri, actions: stub.actions, ssdpSearchSeen: stub.ssdpSearchSeen, ssdpReplies: stub.ssdpReplies } }, null, 2));
    const passed = results.filter((r) => r.pass).length;
    console.log('SUMMARY ' + passed + '/' + results.length + ' PASS  (' + elapsed() + ')');
    console.log('EVIDENCE ' + root);
    if (hasArg('--clean') && !hasArg('--keep')) {
      try { fs.rmSync(root, { recursive: true, force: true }); console.log('INFO 已删除临时目录（--clean）'); } catch (e) { }
    }
  }
  const failed = results.some((r) => !r.pass);
  process.exitCode = envAbort ? 2 : (failed ? 1 : 0);
  // 兜底：收尾后若还有句柄没释放（历史踩过"脚本跑完不退出、CI 挂死"），1.2s 后强制退出。
  setTimeout(() => {
    let res = [];
    try { res = process.getActiveResourcesInfo ? process.getActiveResourcesInfo() : []; } catch (e) { }
    console.log('WARN 收尾后事件循环仍未空（剩余句柄 ' + JSON.stringify(res) + '），强制退出；不影响上面的判据结论');
    process.exit(process.exitCode || 0);
  }, 1200).unref();
})();
