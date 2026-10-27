// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// ui_script.h — 界面脚本（以 C++ 原始字符串承载，零转义）
//
// 视图：专辑 / 艺术家 / 曲目 / 文件夹 / 流媒体 / 队列 / 设置
// 原则：以专辑为中心；搜索是全局的；任何一次点击都不应该让界面失去上下文。
#pragma once

namespace rta::net {

inline const char* rta_ui_script() {
    return R"JS(
var D = function (i) { return document.getElementById(i); };
var WV = (window.chrome && window.chrome.webview) ? window.chrome.webview : null;
if (WV) document.documentElement.classList.add('webview2');
// 2026-10-25（mac 控件协调）——**页面侧的 mac 原生壳判定**，不依赖宿主垫片。
//
// 为什么需要它（实测真 BUG，不是防御性冗余）：
//   tools/mac_host.mm 的 kShim 是一串相邻 @"..." 字面量，而 ObjC 拼接**不插入换行**；
//   shim 第一行是 `// …` 行注释 ⟹ 整段 shim 变成一条注释，`document.documentElement
//   .classList.add('machost')` 与 `window.chrome.webview` 垫片**都没有执行**（从运行中的
//   二进制 dump 注入串，前 1400 字符里换行数 = 0，已复现）。
//   后果：WV 为 null ⟹ 9 条宿主消息全失效；machost 永不出现 ⟹ 红绿灯安全区与隐藏重复
//   窗口按钮的 CSS 全部不命中（1180x760 实测：右上无按钮、Logo 仍在 x=16px 被红绿灯压住）。
//
// 这里的判定用 **WKWebView 独有**的 window.webkit.messageHandlers（WebView2 / 浏览器都没有），
// 所以不会把 Windows 形态误判成 mac。幂等：宿主垫片修好后 classList.add 重复调用无副作用。
// 注意：WV 仍为 null 时 wcmd() 是空操作（消息发不出去），那是宿主侧要修的事；
// 本函数只负责**让版面正确**，不假装消息能通。
var IS_MAC_HOST = !!(window.webkit && window.webkit.messageHandlers);
if (IS_MAC_HOST) document.documentElement.classList.add('machost');
function wcmd(c) { try { if (WV) WV.postMessage(c); } catch (e) { } }

/* ---------------- 原生「选择文件夹」（2026-10-25 用户要求） ----------------
   用户原话：「还需要更改一下选择目录的方法，要让用户可以通过点击文件夹来选择」。
   实现走宿主 NSOpenPanel（WKWebView 里 <input type=file webkitdirectory> 选不了空目录、
   也拿不到 macOS 原生目录体验）。协议见 platform/host_msg.h 的 HostAction::PickDir：
     页面 → 宿主：  pickdir        或  pickdir:<初始目录>
     宿主 → 页面：  pickdir:ok:<绝对路径>   或   pickdir:cancel
   宿主通过 evaluateJavaScript 调 window.chrome.webview.__emit(...)，所以这里挂 __emit。
   浏览器直开（无宿主）时 IS_MAC_HOST 为 false，调用方应隐藏按钮而不是假装能选。 */
var PICKDIR = { pending: null };
function pickDirectory(initial, onDone) {
  if (!IS_MAC_HOST) {
    // 没有宿主通道：如实告知，不假装弹了面板
    if (onDone) onDone(null);
    return false;
  }
  PICKDIR.pending = onDone || null;
  var init = String(initial || '').trim();
  wcmd(init ? ('pickdir:' + init) : 'pickdir');
  return true;
}
// 宿主回传入口（__emit 由 mac_host.mm 的 shim 提供）
(function () {
  function handleEmit(msg) {
    var m = String(msg || '');
    if (m === 'pickdir:cancel') {
      var cb0 = PICKDIR.pending; PICKDIR.pending = null;
      if (cb0) cb0(null);
      return;
    }
    if (m.indexOf('pickdir:ok:') === 0) {
      var path = m.slice('pickdir:ok:'.length);
      var cb = PICKDIR.pending; PICKDIR.pending = null;
      if (cb) cb(path);
      return;
    }
    // 2026-10-26 F-4：自动更新。宿主把所有回传统一成
    //   "update:status:<JSON>"，JSON 由 NSJSONSerialization 生成（引号/反斜杠已转义），
    //   所以这里只做一次 JSON.parse，绝不自己切字符串。
    if (m.indexOf('update:status:') === 0) {
      var payload = m.slice('update:status:'.length);
      var obj = null;
      try { obj = JSON.parse(payload); } catch (e) { return; }   // 解析失败就当没收到，绝不抛给页面
      if (obj) onUpdateStatus(obj);
      return;
    }
    // max/normal 等其它消息沿用既有处理（如果有）
    if (m === 'max' || m === 'normal') {
      try { document.documentElement.classList.toggle('zoommax', m === 'max'); } catch (e) { }
      return;
    }
    // 2026-10-26 邮件反馈：宿主回传 "feedback:status:<JSON>"（与 update:status 同一套通道）。
    // 同样只做一次 JSON.parse，绝不自己切字符串。
    if (m.indexOf('feedback:status:') === 0) {
      var fpayload = m.slice('feedback:status:'.length);
      var fobj = null;
      try { fobj = JSON.parse(fpayload); } catch (e) { return; }
      if (fobj) onFeedbackStatus(fobj);
      return;
    }
  }
  // ⚠️ 不要覆盖 WV.__emit —— 那是宿主垫片自己的派发器，覆盖会让既有的
  // max/normal 等消息全部失联。正确做法是用标准的 addEventListener('message')，
  // 垫片的 emit() 会把消息派发给所有监听器（见 mac_host.mm 的 kShim）。
  if (WV && typeof WV.addEventListener === 'function') {
    WV.addEventListener('message', function (ev) {
      handleEmit(ev && ev.data !== undefined ? ev.data : ev);
    });
  }
  // 双保险：宿主也可以直接调 window.__dshEmit（便于将来换传输层）
  window.__dshEmit = handleEmit;
})();
// 261024-02 #2：资料里的 URL 一律交给**系统浏览器**打开（绝不把 WebView 自己导航走）。
// 协议白名单只放 http/https（file: / javascript: / data: 一律拒绝，避免本机文件被页面打开）。
// 宿主（launcher）收到 'openurl:<url>' 后 ShellExecuteW 打开；浏览器直开（没有 WebView2）时 window.open 兜底。
function extUrlAllowed(u) {
  return /^https?:\/\/[^\s]+$/i.test(String(u || ''));
}
function openExternal(u) {
  u = String(u || '').trim();
  if (!extUrlAllowed(u)) { toast('不支持的链接（只允许 http / https）'); return false; }
  if (WV) { wcmd('openurl:' + u); toast('已在系统浏览器打开'); }
  else {
    try { window.open(u, '_blank', 'noopener'); toast('已在浏览器新标签打开'); }
    catch (e) { toast('打开失败：' + u); }
  }
  return true;
}
var S = {
  view: 'albums', albums: [], album: null, files: [], remote: [],
  q: { items: [], index: 0 }, cur: '', playing: false, paused: false,
  vol: 0, loud: false, lastCur: '', roots: [], scanning: false, dur: 0, pos: 0,
  volDb: 0, startDb: 0, theme: 'dark', uiStyle: 'apple', queueHidden: false,
  // 261024-04 #8：GUP 相关的两个运行时状态（gpuOn = 有 GPU；gpuUsed = 本次播放真的用了 GPU）
  gpuOn: false, gpuUsed: false
};
// 高级参数（设置页里改，params() 统一带上）。默认值与后端一致。
// 2026-10-25（task-12）：ASIO 后端已删除（macOS 用 CoreAudio，无需绕过系统音频引擎）。
// 老用户的 conf 里可能还留着 backend=asio —— 由 migrateRemovedBackend() 在加载时优雅降级。
var ADV = {
  device: '', bits: 0, taps: 0, atten: 0, transition: 0, phase: '',
  modcut: 0, moddith: -1, ir: '', irgpu: 0, ramp: 0, theme: 'dark', uiStyle: 'apple',
  eq: '', modorder: 5, modfamily: 'dsd', gpuvendor: 'auto', directsdm: 0, dsdKind: 'fir', dsdConv: 'narrow',
  updbeta: 0,
  // 输出后端与多声道
  // 261024-01 #9/#11：upnpDev = UPnP/DLNA 渲染器（设备描述 URL）；naaHost 自动发现填，
  // 手动框只是折叠兜底（用户原话：NAA 端点这个选项不应该出现，应该自动获取）。
  // 2026-10-25（默认值纠正）：NAA 已从界面移除，naaHost 不再给 127.0.0.1:43210 这种
  // 永远连不上的假默认值（macOS 无 NAA 驱动体系）。字段保留以兼容老 conf 与后端契约，
  // 默认置空 = 未选择，语义诚实。
  // 2026-10-25（方案 C）：Hog 独占开关，默认 0 = 不抢（系统音量可用）
  backend: 'wasapi', hogExclusive: 0, channels: 0, naaHost: '', upnpDev: '',
  trim0: 0, trim1: 0, trim2: 0, trim3: 0, trim4: 0, trim5: 0, trim6: 0, trim7: 0,
  // 输入
  inBackend: 'none', inDev: '', inOffset: 0, inBuf: 100, inMonitor: 0, inSeconds: 0, inOut: '',
  // SDM（DSD 输出）专用滤波器：空 = 沿用 PCM 页那一组
  sdmFilt: '', sdmFiltNx: ''
};
// 元数据补全开关（P1.5 注册表化）：总开关 metaon 与 DeepSeek metallm 固定两键；
// 数据源开关按 /api/providers（后端注册表）动态渲染，写 metasrc_<id> ——
// 后端新增数据源 = 注册一个描述符，前端零改动。缺省全开，与后端缺省一致。
// summary = 设置开关（/api/settings 的 metasummary，改动即时生效）；
// hasLlmKey / summaryEnabled = /api/status 回报的权威状态（是否配了 key、后端是否开着开关）。
// 简介板块的显示门控用这两个：没 key 又没缓存时连加载行都不显示（用户 261023-03 #5）。
var META = { on: 1, llm: 1, summary: 0, hasLlmKey: null, summaryEnabled: null };
var META_PROVIDERS = null;   // /api/providers 的 items（启动时拉取；null = 还没到）
var META_SRC = {};           // id → 0/1（源开关状态，随 /api/providers 到达而填充）
// 路径分隔符：**按运行平台判定**，不再硬编码反斜杠。
// 旧实现写死 String.fromCharCode(92)（"\"），macOS 上 join('/tmp/libtest','A') 会得到
// "/tmp/libtest\A" —— 这是个不存在的路径，于是「文件夹」视图点进去就是空白/报错，
// 右键「加入队列」拿到的是坏路径。反馈 #4 的删除目录按钮同样要靠它拼出真实路径。
var SEP = (function () {
  var p = '';
  try { p = String((navigator && (navigator.platform || navigator.userAgent)) || ''); } catch (e) { }
  return /win/i.test(p) ? String.fromCharCode(92) : '/';
})();

// 先按本地记忆应用主题与界面风格（不等 /api/settings 返回，避免启动瞬间闪一下）
(function () {
  var t = null, u = null;
  try { t = localStorage.getItem('rta-theme'); u = localStorage.getItem('rta-uistyle'); } catch (e) { }
  if (t === 'light' || t === 'blue') document.documentElement.dataset.theme = t;
  document.documentElement.dataset.uistyle = (u === 'classic') ? 'classic' : 'apple';
  S.uiStyle = document.documentElement.dataset.uistyle;
  ADV.uiStyle = S.uiStyle;
})();

function toast(m) {
  var t = D('toast'); if (!t) return;
  t.textContent = m; t.classList.add('on');
  clearTimeout(window._tt); window._tt = setTimeout(function () { t.classList.remove('on'); }, 2000);
}
// ============================================================================
// 2026-10-26 F-1 / B-3：底栏文本跑马灯（用户明确要求「用滚动文字」）
//
// 为什么用 MutationObserver 而不是改每个赋值点：
//   #npt / #npart 的 textContent 在 ui_script.h 里有 5+ 个赋值位置
//   （loadMeta 的 3 处、轮询里的"未播放"、异常分支…），逐个改成 mqSet() 既啰嗦又容易漏。
//   这里把「文本源」(#npt/#npart) 与「显示层」(.mq>.mqi) 分开：
//     · 源元素仍然被原代码正常写，只是视觉上隐藏（visibility:hidden，保留占位与测量能力）；
//     · 观察器把源文本同步到滚动内容里，再按实际溢出量决定是否启动动画。
//   这样任何既有/将来新增的赋值点都自动生效，零侵入。
//
// 判据（铁律 3：要能证明"真溢出才滚"）：
//   · 未溢出时 .mq 不带 mqon ⟹ 无 animation，静态显示；
//   · 溢出时 --mqdist = 溢出像素数（负值，向左移），duration = 距离/40px per s；
//   · hover 暂停由 CSS 负责；prefers-reduced-motion 下完全禁用。
// ============================================================================
function mqMeasure(rec) {
  var wrap = rec.wrap, inner = rec.inner;
  // 先量"内容自然宽度"与"可用宽度"。inner 是 inline-block ⟹ scrollWidth 约等于自身宽度。
  var avail = wrap.clientWidth;
  var need = inner.scrollWidth;
  if (!avail || !need) { wrap.classList.remove('mqon'); return; }
  var over = need - avail;
  if (over <= 2) {                      // +2px 容差：亚像素舍入不算溢出
    wrap.classList.remove('mqon');
    wrap.style.removeProperty('--mqdist');
    wrap.style.removeProperty('--mqdur');
    return;
  }
  wrap.classList.add('mqon');
  // 向左移 over px 后，末尾正好贴住右边缘；alternate 会自己滚回来。
  wrap.style.setProperty('--mqdist', (-over) + 'px');
  // 约 40px/s；下限 4s 避免极短溢出太快，上限 30s 避免超长标题等太久
  var dur = Math.min(30, Math.max(4, Math.abs(over) / 40));
  wrap.style.setProperty('--mqdur', dur.toFixed(2) + 's');
}
function mqSetupOne(srcId, wrapId) {
  var src = D(srcId), wrap = D(wrapId);
  if (!src || !wrap) return null;
  var inner = wrap.querySelector('.mqi');
  if (!inner) { inner = document.createElement('span'); inner.className = 'mqi'; wrap.appendChild(inner); }
  // 源元素隐藏但保留在流里（display:none 会失去测量能力，visibility:hidden 不会）
  src.style.visibility = 'hidden';
  src.style.position = 'absolute';
  src.style.pointerEvents = 'none';
  src.setAttribute('aria-hidden', 'true');
  var rec = { src: src, wrap: wrap, inner: inner };
  rec.sync = function () {
    var t = src.textContent || '';
    if (inner.textContent !== t) inner.textContent = t;
    mqMeasure(rec);
  };
  return rec;
}
function mqMount() {
  if (!D('mqTitle') || !D('mqArtist')) return;   // 页面结构不对就不启用，绝不抛异常
  var recs = [mqSetupOne('npt', 'mqTitle'), mqSetupOne('npart', 'mqArtist')];
  var live = recs.filter(function (r) { return !!r; });
  if (!live.length) return;
  live.forEach(function (rec) {
    rec.sync();
    // 文本变了 ⟹ 重算；用 characterData+childList 覆盖 textContent 赋值与直接改节点两种写法
    var mo = new MutationObserver(function () { rec.sync(); });
    mo.observe(rec.src, { childList: true, characterData: true, subtree: true });
  });
  // 窗口/侧栏尺寸变化会改变可用宽度 ⟹ 重新判定是否溢出（否则缩放窗口后跑马灯状态是旧的）
  if (!window._mqResize) {
    window._mqResize = function () {
      (window._mqRecs || []).forEach(function (rec) { mqMeasure(rec); });
    };
    window.addEventListener('resize', window._mqResize);
    // 字体加载完成后宽度会变，补一次
    if (document.fonts && document.fonts.ready && document.fonts.ready.then) {
      document.fonts.ready.then(function () { window._mqResize(); }).catch(function () { });
    }
  }
  window._mqRecs = live;
}

// ============================================================================
// 2026-10-26 F-4 自动更新（用户要求「云端发布更新 → 自动提示 → 一键更新」）
//
// 分工（这是硬边界，不是风格选择）：
//   · **页面只负责显示与发命令**：wcmd('update:check') / wcmd('update:install')。
//   · 下载、sha256 校验、挂载 dmg、替换 /Applications 里的 .app 全在原生壳
//     （tools/mac_update.mm）。网页沙箱做不了这些，也不该做。
//   · 页面**绝不传 URL / token 给宿主**：update.conf 与白名单都在壳侧，
//     否则页面里任何一段脚本都能命令宿主下载任意文件。
//
// 失败语义（用户明确要求：网络失败不许写「已是最新」）：
//   stage === 'up-to-date'  ⟹ 确实是最新（只有这一种能这么显示）
//   stage === 'available'   ⟹ 有新版本，显示版本号 + 「立即更新」
//   stage === 'failed'      ⟹ 检查失败（网络/鉴权/解析），如实说失败，绝不冒充最新
// ============================================================================
var UPD = { stage: '', info: null, busy: false };

function updMsg(t, kind) {
  var el = D('sp_updmsg');
  if (!el) return;
  el.textContent = t || '';
  // 用主题变量而不是写死颜色：三套主题 × apple/classic 都要能读
  el.style.color = kind === 'err' ? 'var(--danger)'
                 : kind === 'ok' ? 'var(--ok-text)'
                 : kind === 'warn' ? 'var(--warn)' : 'var(--mut2)';
}
function updBar(pct) {
  var bar = D('sp_updbar'), fill = D('sp_updfill');
  if (!bar || !fill) return;
  if (pct === null || pct === undefined || pct < 0) { bar.style.display = 'none'; return; }
  bar.style.display = 'block';
  fill.style.width = Math.max(0, Math.min(100, pct)) + '%';
}
function updInstallBtn(show, label) {
  var b = D('sp_updinstall');
  if (!b) return;
  b.style.display = show ? '' : 'none';
  if (label) b.textContent = label;
}
// 宿主回传的唯一入口（由 handleEmit 里 "update:status:<json>" 分支调用）
function onUpdateStatus(obj) {
  if (!obj || typeof obj !== 'object') return;
  var stage = String(obj.stage || '');
  // 进度事件：有 percent 但 stage 还是 checking/downloading 等，先刷进度条
  if (obj.percent !== undefined && obj.percent !== null) {
    updBar(Number(obj.percent));
    if (obj.message) updMsg(String(obj.message));
    return;
  }
  UPD.stage = stage;
  UPD.info = obj;
  if (stage === 'up-to-date') {
    UPD.busy = false;
    updBar(null);
    updInstallBtn(false);
    updMsg('已是最新版本' + (obj.code ? '' : ''), 'ok');
    setUpdateBadge('');
  } else if (stage === 'available') {
    UPD.busy = false;
    updBar(null);
    var v = obj.version ? ('v' + obj.version) : '新版本';
    updInstallBtn(true, '立即更新');
    updMsg('发现新版本 ' + v, 'warn');
    // 主动提示（用户要的「自动提示」）：底栏徽标 + 轻提示，不弹模态框打断听歌
    setUpdateBadge(v);
    try { toast('有新版 ' + v + '，设置 → 诊断 里可一键更新'); } catch (e) { }
  } else if (stage === 'failed') {
    UPD.busy = false;
    updBar(null);
    updInstallBtn(false);
    // ⚠️ 绝不说「已是最新」：网络/鉴权/解析失败就是失败
    updMsg('检查失败：' + (obj.message || obj.code || '未知原因'), 'err');
  } else if (stage === 'installing') {
    UPD.busy = true;
    updMsg(obj.message || '正在更新…');
  } else if (stage === 'installed') {
    UPD.busy = false;
    updBar(100);
    updInstallBtn(false);
    updMsg(obj.message || '已更新，请手动重启应用以完成', 'ok');
  } else {
    // 未知 stage（宿主升级/降级）⟹ 如实显示，不猜
    updMsg(obj.message || ('未知状态：' + stage));
  }
}
// 底栏/顶栏的「有新版」徽标。空串 = 隐藏。
function setUpdateBadge(text) {
  var b = D('updateBadge');
  if (!b) return;
  if (!text) { b.style.display = 'none'; b.textContent = ''; return; }
  b.style.display = '';
  b.textContent = text;
  b.title = '发现新版本 ' + text + '，点这里去更新';
}
function updCheck(manual) {
  if (!IS_MAC_HOST) {
    updMsg('浏览器里不支持一键更新（需要桌面客户端）', 'err');
    return false;
  }
  UPD.busy = true;
  updBar(null);
  updInstallBtn(false);
  updMsg(manual ? '正在检查…' : '启动检查更新…');
  wcmd('update:check');
  return true;
}
function updInstall() {
  if (!IS_MAC_HOST) { updMsg('浏览器里不支持一键更新（需要桌面客户端）', 'err'); return false; }
  if (UPD.stage !== 'available') { updMsg('当前没有可安装的新版本', 'err'); return false; }
  UPD.busy = true;
  updInstallBtn(false);
  updMsg('开始更新…');
  updBar(0);
  wcmd('update:install');
  return true;
}
// 绑定：设置页每次重建都会重跑，所以这里要能重复调用且不重复挂监听
function bindUpdateCard() {
  // 当前版本号：从侧栏品牌徽标的 #appVer 取（它是 C++ 侧用 RLPLAYER_VERSION 拼好的，
  // 是"单一真相源"的唯一出口）。
  // ⚠️ 这里绝不能写 RLPLAYER_VERSION —— 它是 C++ 宏，只在 C++ 字符串拼接时展开，
  //    直接写进 JS raw string 会变成未定义变量（我第一版就这么错了，
  //    实测 renderSettingsPage 抛 ReferenceError，整个设置页渲染不出来）。
  var ver = D('sp_vercur');
  if (ver) {
    var src = D('appVer');
    ver.textContent = (src && src.textContent) ? src.textContent : 'v?';
  }
  var c = D('sp_updcheck');
  if (c) c.onclick = function () { updCheck(true); };
  var i = D('sp_updinstall');
  if (i) i.onclick = function () { updInstall(); };
  var beta = D('sp_updbeta');
  if (beta) {
    beta.checked = (ADV.updbeta == 1);
    beta.onchange = function () {
      ADV.updbeta = this.checked ? 1 : 0;
      if (!ADV.updbeta && UPD.info && /-/.test(String(UPD.info.version || ''))) {
        UPD.stage = ''; UPD.info = null;
        updInstallBtn(false); setUpdateBadge('');
        updMsg('已关闭预发布更新，下次检查仅提示正式版');
      }
      saveSettings(true);
    };
  }
  var b = D('updateBadge');
  if (b) b.onclick = function () {
    // 点徽标 = 直接去「诊断」页看更新卡片（不静默装，装之前要让用户看见版本号与说明）
    try { openSettingsTab('diag'); } catch (e) { }
  };
}

// ============================================================================
// 2026-10-26 反馈通道（用户：点了按钮完全没反应 → 改走 Cloudflare Worker）
//
// 演进过程（如实记录，避免后来者重复踩坑）：
//   ① 最初设计 = 打开系统邮件客户端（NSSharingServiceNameComposeEmail），
//      用户在自己已登录的邮箱里点发送。理由是不在二进制里存任何凭据。
//      但实测暴露两个致命问题：
//        · 页面侧**一行都没接**（#sp_fbsend 没有 onclick，feedback:status 没有接收分支）
//          ⟹ 用户点按钮完全没反应。这是"壳侧写完 ≠ 能用"的典型。
//        · 即使接上了，本机 Mail.app 没有可用账号时 performWithItems 仍回传"已打开"，
//          用户点「发送」发不出去 ⟹ **谎报成功**（违反铁律 3）。
//   ② 用户决定（2026-10-26）：**别折腾邮箱了，走 Cloudflare Worker**。
//      「用户什么都不用调，直接就能发给我」才是对的体验。
//
// 现在的架构（零凭据、零配置、零用户操作）：
//
//   页面  ──POST JSON──▶  Cloudflare Worker  ──GitHub API──▶  Issue / 私有仓库
//                              （token 只在 Worker 环境变量里，客户端永远拿不到）
//
//   * 客户端**不含任何 token**：Worker URL 是公开的，被反编译也无所谓
//   * DDoS：Cloudflare 免费套餐自带，源站不暴露（用户明确担心这个）
//   * 诊断包：Worker 负责转存（>64KB 不进 issue body）
//
// 协议（见 worker/feedback-worker.js）：
//   POST <WORKER_URL>
//   Content-Type: application/json
//   { "text": "正文", "version": "1.0.7", "os": "macOS 27.0.1 / arm64",
//     "diag": "<base64 可选，诊断包 zip>" }
//   → 200 {"ok":true,"id":"<工单号>"}
//   → 4xx {"ok":false,"error":"原因"}
//
// ⚠️ WORKER_URL 留空 = 功能未启用，页面会如实说"反馈通道未配置"，绝不假装发送成功。
//    部署 Worker 后把地址填到这里（或由宿主注入）即可。
// ============================================================================
var FB = { busy: false, diagPath: '' };

// Worker 地址（部署后填入；留空则明确报未配置，不假装成功）
var FB_WORKER_URL = 'https://rlplayer-feedback.bh2voq.workers.dev';

function fbMsg(t, kind) {
  var el = D('sp_fbmsg');
  if (!el) return;
  el.textContent = t || '';
  el.style.color = kind === 'err' ? 'var(--danger)'
                 : kind === 'ok' ? 'var(--ok-text)'
                 : kind === 'warn' ? 'var(--warn)' : 'var(--mut2)';
}
function fbBusy(on) {
  FB.busy = !!on;
  var btn = D('sp_fbsend');
  if (btn) { btn.disabled = !!on; btn.textContent = on ? '正在发送…' : '发送反馈'; }
}
function fbCount() {
  var t = D('sp_fbtext'), c = D('sp_fbcount');
  if (!t || !c) return;
  var n = t.value ? t.value.length : 0;
  c.textContent = n + ' / 8000';
  // 超长要立刻让用户看见（Worker 也会截断，但提前告知比事后解释好）
  c.style.color = n > 8000 ? 'var(--warn)' : 'var(--mut2)';
}

// 宿主回传入口保留（旧邮件路径的兼容分支；Worker 路径不经过这里）
function onFeedbackStatus(obj) {
  if (!obj || typeof obj !== 'object') return;
  fbBusy(false);
  fbMsg(String(obj.message || obj.stage || '未知状态'), obj.stage === 'failed' ? 'err' : 'ok');
}

// ArrayBuffer → base64（诊断包要放进 JSON）
function fbBase64(buf) {
  var bytes = new Uint8Array(buf);
  var bin = '';
  var CHUNK = 0x8000;                    // 分块，避免 apply 参数过多爆栈
  for (var i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(bin);
}

// 发送主流程：POST 到 Cloudflare Worker。任何失败都如实显示，绝不假装"已发送"。
function fbSend() {
  if (FB.busy) return false;
  var t = D('sp_fbtext');
  var text = t ? String(t.value || '') : '';
  if (!text.trim()) { fbMsg('请先写下反馈内容再发送', 'err'); if (t) t.focus(); return false; }
  if (!FB_WORKER_URL) {
    fbMsg('反馈通道未配置（开发者尚未部署 Worker 地址）', 'err');
    return false;
  }
  var wantDiag = false;
  var cb = D('sp_fbdiag');
  if (cb) wantDiag = !!cb.checked;

  fbBusy(true);

  var payload = {
    text: text,
    version: (D('appVer') && D('appVer').textContent) ? D('appVer').textContent : '',
    os: (navigator && navigator.userAgent) ? navigator.userAgent : ''
  };

  var withDiag = function () {
    if (!wantDiag) return Promise.resolve(payload);
    fbMsg('正在打包诊断包…');
    return fetch('/api/diagzip').then(function (r) {
      if (!r.ok) throw new Error('打包失败 HTTP ' + r.status);
      return r.blob();
    }).then(function (blob) {
      if (blob.size < 22) throw new Error('诊断包太小（不是有效 ZIP）');
      return blob.arrayBuffer();
    }).then(function (buf) {
      var v = new Uint8Array(buf, 0, 4);
      if (!(v[0] === 0x50 && v[1] === 0x4B && v[2] === 0x03 && v[3] === 0x04)) {
        throw new Error('诊断包不是合法 ZIP（缺少 PK 头）');
      }
      fbMsg('正在上传（' + Math.round(buf.byteLength / 1024) + ' KB）…');
      payload.diag = fbBase64(buf);
      payload.diagName = 'rlplayer-diag.zip';
      return payload;
    });
  };

  withDiag().then(function (body) {
    fbMsg('正在发送…');
    return fetch(FB_WORKER_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
  }).then(function (r) {
    // 200 也可能带 ok:false，所以必须读 body 确认
    return r.text().then(function (txt) {
      var j = null;
      try { j = JSON.parse(txt); } catch (e) { }
      if (!j) throw new Error('服务器返回非 JSON（HTTP ' + r.status + '）');
      if (!j.ok) throw new Error(j.error || ('服务器拒绝（HTTP ' + r.status + '）'));
      return j;
    });
  }).then(function (j) {
    fbBusy(false);
    fbMsg('已发送，工单号 ' + (j.id || '(无)') + '。感谢反馈！', 'ok');
    if (t) t.value = '';
    fbCount();
  }).catch(function (e) {
    fbBusy(false);
    var m = (e && e.message) ? e.message : String(e);
    // 诊断包过大时给出可操作建议（而不是只说失败）
    var hint = (m.indexOf('过大') >= 0 || m.indexOf('413') >= 0)
      ? '（可取消勾选「附带诊断包」只发正文）' : '';
    fbMsg('发送失败：' + m + hint, 'err');
  });
  return true;
}

function bindFeedbackCard() {
  var btn = D('sp_fbsend');
  if (btn) btn.onclick = function () { fbSend(); };
  var t = D('sp_fbtext');
  if (t) {
    t.oninput = fbCount;
    fbCount();
  }
}

// 261024-02 #3：长时长格式（专辑总时长用 1:05:24，单曲用 4:24；都用本地曲库真实数据，不用 AI 猜）
function fmtDurLong(x) {
  x = Math.max(0, Math.round(x || 0));
  var h = Math.floor(x / 3600), m = Math.floor((x % 3600) / 60), s = x % 60;
  var ss = (s < 10 ? '0' : '') + s;
  if (h > 0) return h + ':' + (m < 10 ? '0' : '') + m + ':' + ss;
  return m + ':' + ss;
}
function fmt(x) {
  x = Math.max(0, Math.floor(x || 0));
  var h = Math.floor(x / 3600), m = Math.floor((x % 3600) / 60), s = x % 60;
  if (h > 0) return h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
  return m + ':' + (s < 10 ? '0' : '') + s;
}
function esc(s) {
  return String(s === undefined || s === null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function fmtDate(sec) {
  if (!sec) return '';
  var d = new Date(sec * 1000);
  if (isNaN(d.getTime())) return '';
  var y = d.getFullYear();
  var m = ('0' + (d.getMonth() + 1)).slice(-2);
  var day = ('0' + d.getDate()).slice(-2);
  return y + '-' + m + '-' + day;
}
// 从完整路径取「所在文件夹名」（队列列表用，比整条路径可读；评审 #8）
function parentFolder(p) {
  var s = String(p || '').replace(/\\\\/g, '/');
  var segs = s.split('/').filter(function (x) { return !!x; });
  return segs.length >= 2 ? segs[segs.length - 2] : '';
}
function nam(p) {
  var s = String(p || ''), i = Math.max(s.lastIndexOf('/'), s.lastIndexOf(SEP));
  return i >= 0 ? s.slice(i + 1) : s;
}
function base(p) { return String(p || '').replace(/[/\\]+$/, ''); }
function join(a, b) { return base(a) + SEP + b; }
// 261025-01 #7/#10：api() 必须自己兜住网络失败，不能把 rejection 甩给上百个调用点。
// 为什么修在这一层：全文件 api(...) 调用 99 处，绝大多数只写 .then 不写 .catch。服务端是单线程，
// 冷算曲库时（实测 12000 首的 /api/lib/albums 要 625ms，期间并发打进来的 /api/lib/stats
// 从 20ms 被拖到 594ms）fetch 会超时/连接重置 → promise reject → 没有接管者 → 界面永远停在
// 「加载中…」或一片空白。用户报的「Failed to fetch」和「切标签数据消失」是同一个根因。
// 契约：本函数**永不 reject**。成功返回后端 JSON；失败返回 {ok:false,_err,error} 兜底对象，
// 保证所有既有 .then 拿到的都是对象而不是 rejection。
// 兜底对象**故意不填** albums/tracks/items/roots 这些集合字段：填 [] 会让 loadLibStats 把
// S.roots 清空、把「曲目数」显示成 0 —— 那正是用户说的「数据消失」本身。改成由各 loader
// 用 j._err 显式分支（见 loadAlbums / loadTracks / loadLibStats / loadQ）。
var API_FAIL_TOAST_AT = 0;      // 上次「网络错误」toast 的时间戳；0 = 还没提示过（哨兵）
function apiFail(msg) {
  return { ok: false, _err: msg, error: msg };
}
function apiFailNote(msg) {
  // 节流 5 秒：tick 是 400ms 节奏的轮询，断线时每条失败都弹 toast 等于刷屏，
  // 反而盖住底栏状态。只报第一声，之后静默（恢复后自动继续）。
  // 用「0 = 还没提示过」这个显式哨兵，而不是靠 `now - 0` 恰好很大：
  // 后者在时钟起点为 0 的环境（测试注入的假时钟、或某些单调时钟起点）里会退化成每次都弹。
  var now = Date.now();
  if (API_FAIL_TOAST_AT !== 0 && now - API_FAIL_TOAST_AT < 5000) return;
  API_FAIL_TOAST_AT = now || 1;   // 时钟恰好为 0 时也要留下"已提示过"的痕迹，别退回哨兵
  toast(msg);
}
function api(u, body) {
  // 读端点（/api/settings /api/status /api/devices /api/rates /api/filters /api/providers /api/gpu /api/peq 等）
  // 在 body 为空且没有显式修改动作时必须走 GET。
  // 尤其 /api/settings：无 body 时是读取全量配置（GET），若发 POST 会被后端当成写操作而只回 {"ok":true,"merged":true} 导致 kv 丢失。
  var isApi = u.indexOf('/api/') === 0;
  var isRead = (body === undefined) && (
    u === '/api/settings' || u.indexOf('/api/settings?') === 0 ||
    u === '/api/status' || u.indexOf('/api/status?') === 0 ||
    u === '/api/devices' || u.indexOf('/api/devices?') === 0 ||
    u === '/api/rates' || u.indexOf('/api/rates?') === 0 ||
    u === '/api/filters' || u.indexOf('/api/filters?') === 0 ||
    u === '/api/providers' || u.indexOf('/api/providers?') === 0 ||
    u === '/api/gpu' || u.indexOf('/api/gpu?') === 0 ||
    u === '/api/opra/index' || u.indexOf('/api/opra/index?') === 0 ||
    u.indexOf('/api/opra/presets') === 0 ||
    u === '/api/peq' || (u.indexOf('/api/peq?') === 0 && u.indexOf('action=') < 0) ||
    u === '/api/queue' || u === '/api/recent' || u === '/api/fav/list' ||
    u.indexOf('/api/lib/albums') === 0 || u.indexOf('/api/lib/album?') === 0 ||
    u.indexOf('/api/files?') === 0 || u.indexOf('/api/meta?') === 0 ||
    u === '/api/cast/state' || u.indexOf('/api/cast/devices') === 0 ||
    u === '/api/input/devices' || u === '/api/input/state' ||
    u === '/api/src/config' || u.indexOf('/api/src/browse') === 0
  );
  var opt = (!isApi || isRead) ? {} : { method: 'POST' };
  if (body !== undefined) opt.body = body;
  // 两个阶段都可能失败：① fetch 本身（超时 / 连接重置 / 服务没起来）；
  // ② r.json()（响应被截断，或拿到的是 HTML 错误页而不是 JSON）。一次 .catch 同时覆盖两者。
  return fetch(u, opt).then(function (r) { return r.json(); }).then(function (j) {
    if (!j || typeof j !== 'object') { apiFailNote('后端响应格式异常'); return apiFail('后端响应格式异常'); }
    return j;
  }).catch(function (e) {
    // 面向用户的话**不能**带浏览器的英文原文：用户报的那串「Failed to fetch」正是它，
    // 原样回显等于把同一句抱怨还给他，而且没有任何可操作的下一步。
    // 统一成中文动作提示；原始信息只留在 _raw 里给排查用（不参与任何界面渲染）。
    var raw = (e && e.message) ? String(e.message) : '请求失败';
    apiFailNote('无法连接后端（服务正忙或已退出），稍后重试');
    var o = apiFail('无法连接后端（服务正忙或已退出），稍后重试');
    o._raw = raw;
    return o;
  });
}

/* ---------------- 视图短时缓存（261025-01 #5/#10） ----------------
   /api/lib/albums 在 12000 首库冷算要 625ms（主控实测），而 .nav 的 onclick 每次点标签都无条件
   loadAlbums('')/loadArtists()/loadTracks('')；「艺术家」页更是把同一份 /api/lib/albums 再算一遍。
   来回点两次标签 = 两次全库重算，单线程后端被自己的前端堵住，后面的请求排队超时 → 用户说的
   「切标签重复扫描」+「切标签数据消失」。
   规则：
     * 同 key 且 5 秒内重复进入 → 直接复用上次的 JSON 重渲染，不发请求；
     * 带搜索词（q 非空）的请求**永不缓存**：搜索是用户主动查询，结果必须新鲜；
     * 扫描完成（S.scanning true→false）、请求扫描、添加/移除库根 → viewCacheClear() 全部失效。
   为什么缓存 JSON 而不是缓存 HTML：S.albums / S.currentTracks 是别的视图的输入（艺术家页、
   「播放全部」、右键入队都读它们），只缓存 HTML 会让画面与状态脱节，出现"看得见却点不动"。 */
var VIEWC = { TTL: 5000, m: {} };
function viewCacheGet(k) {
  if (!k) return null;
  var e = VIEWC.m[k];
  if (!e) return null;
  if (Date.now() - e.t > VIEWC.TTL) { delete VIEWC.m[k]; return null; }
  return e.v;
}
function viewCachePut(k, v) { if (k) VIEWC.m[k] = { t: Date.now(), v: v }; }
function viewCacheClear() { VIEWC.m = {}; }

// 曲库结构变了（添加/移除库根、请求扫描）：缓存必须立刻失效 + 轮询立刻切到扫描节奏。
// 为什么合成一个入口：这些动作散在 6 个地方（快捷面板、设置页、队列页的移除按钮…），
// 历史上"两处各写一份"必然漏一处 —— 漏掉的那一处就是"新加的目录扫完了却看不见"。
function libChanged() {
  viewCacheClear();
  pollKick();
}
// 反馈 #3d：移除库根后**当前视图必须重画**。
// 旧实现只调 libChanged()（清缓存 + 重排轮询）+ loadLibStats()，这两个都不重绘 #list
// ⟹ 用户移除目录后，界面上那批歌还在，只有手动切一次标签才消失（"移除没生效"的观感）。
// 这里按当前视图重新取一次数据；视图不认识（设置页等）就什么都不做，绝不乱改页面。
function refreshCurrentView() {
  var v = S.view;
  if (v === 'albums') loadAlbums('');
  else if (v === 'artists') loadArtists();
  else if (v === 'tracks') loadTracks(S.tracksQuery || '');
  else if (v === 'files') loadFiles(S.dir || '');
  else if (v === 'recent') loadRecent();
  else if (v === 'queue') renderQueuePage();
  else if (v === 'album' && S.album && S.album.k) openAlbum(S.album.k);
}

// 统一的「取数失败」占位。比留一片空白、或把「没有匹配的曲目」当成结果顶上来更诚实
// （后者会让用户以为搜索确实没命中，实际是后端没响应），并给一个明确的重试入口。
function listErrorBox(what, retryFn) {
  var box = D('list'); if (!box) return;
  box.innerHTML = '<div class="card empty-card" style="max-width:520px;margin:clamp(24px,10vh,90px) auto 0;padding:24px 26px;background:var(--phbg);border:1px solid var(--line);border-radius:12px;text-align:center">' +
    '<div style="font-size:14px;font-weight:650;margin-bottom:6px">' + esc(what || '读取失败') + '</div>' +
    '<div style="color:var(--mut);font-size:12.5px;line-height:1.7;margin-bottom:14px">' +
    '后端没有响应或连接被重置（服务可能正在扫描 / 冷算曲库）。数据没有丢失，稍后重试即可。</div>' +
    '<button class="btn pri" id=lstRetry>重试</button></div>';
  if (D('lstRetry')) D('lstRetry').onclick = function () { if (retryFn) retryFn(); };
}
function params() {
  // 2026-10-26 BUG（用户报「刚启动软件时点播放没反应」，偶发）：
  //   下面这些控件（sDSD/sRate/sFilt/sFiltNx/sShap/sIsp/s2s/sBuf）**只存在于设置页**。
  //   冷启动后用户如果没打开过设置页就直接点专辑/曲目播放，D('sDSD') 是 null，
  //   裸写 D('sDSD').value 会抛 TypeError ⟹ params() 中途炸掉 ⟹ api() 根本没发出请求
  //   ⟹ 表现为「点了完全没反应」，且没有任何 toast（异常在 Promise 外抛出）。
  //   一旦打开过设置页，控件存在，就恢复正常 —— 所以是**偶发**。
  //   修法：统一走 pv(id, fallback) / pc(id, fallback) 取值，控件不在时回退到 ADV/默认值。
  //   （同文件 outModeOf() 早就用了 `D('sDSD') &&` 的防御写法，params() 漏了。）
  function pv(id, dflt) { var e = D(id); return (e && e.value !== undefined) ? e.value : dflt; }
  function pc(id, dflt) { var e = D(id); return e ? !!e.checked : !!dflt; }
  var dv = pv('sDSD', '0');              // 0 | dop64 | dop128 | dop256 | nat64 | nat128 | nat256
  var dsdN = 0, native = 0;
  if (dv.indexOf('nat') === 0) { native = 1; dsdN = parseInt(dv.slice(3), 10) || 0; }
  else if (dv.indexOf('dop') === 0) { dsdN = parseInt(dv.slice(3), 10) || 0; }
  else dsdN = parseInt(dv, 10) || 0;
  return 'dsd=' + dsdN + '&dsdnative=' + native +
         '&gpuvendor=' + encodeURIComponent(ADV.gpuvendor || pv('sGpu', 'auto') || 'auto') +
         '&rate=' + encodeURIComponent(pv('sRate', (ADV && ADV.rate) ? ADV.rate : 'follow')) +
         '&filter=' + encodeURIComponent(pv('sFilt', (ADV && ADV.filter) ? ADV.filter : '')) +
         '&filterNx=' + encodeURIComponent(pv('sFiltNx', (ADV && ADV.filterNx) ? ADV.filterNx : '')) +
         '&shaper=' + encodeURIComponent(pv('sShap', (ADV && ADV.shaper) ? ADV.shaper : '')) +
         '&hogexcl=' + (ADV.hogExclusive ? 1 : 0) +
         '&volume=' + S.vol +
         '&loudness=' + (S.loud ? 1 : 0) +
         '&isp=' + (pc('sIsp', ADV.isp) ? 1 : 0) +
         '&twostage=' + (pc('s2s', ADV.twostage) ? 1 : 0) +
         '&buffer=' + pv('sBuf', ADV.buffer || 100) +
         '&modorder=' + (ADV.modorder || 5) +
          '&modfamily=' + encodeURIComponent(ADV.modfamily || 'dsd') +
         '&device=' + encodeURIComponent(ADV.device || '') +
         '&bits=' + (ADV.bits || 0) +
         // 2026-10-24（261024-02 #8）：源文件真实位深（bit-perfect 判据用；解码器容器位深不可靠）
         '&srcbits=' + ((S.curMeta && S.curMeta.bits) ? S.curMeta.bits : 0) +
         '&taps=' + (ADV.taps || 0) +
         '&atten=' + (ADV.atten || 0) +
         '&transition=' + (ADV.transition || 0) +
         '&phase=' + encodeURIComponent(ADV.phase || '') +
         '&modcut=' + (ADV.modcut || 0) +
         '&moddith=' + (ADV.moddith === undefined ? -1 : ADV.moddith) +
         '&eq=' + encodeURIComponent(ADV.eq || '') +
         '&ir=' + encodeURIComponent(ADV.ir || '') +
         '&irgpu=' + (ADV.irgpu || 0) +
         '&ramp=' + (ADV.ramp || 0) +
         '&backend=' + encodeURIComponent(ADV.backend || 'wasapi') +
         '&channels=' + (ADV.channels || 0) +
         '&naahost=' + encodeURIComponent(ADV.naaHost || '') +
         '&upnpdev=' + encodeURIComponent(ADV.upnpDev || '') +
         '&trim=' + [0, 1, 2, 3, 4, 5, 6, 7].map(function (i) { return ADV['trim' + i] || 0; }).join(',') +
         '&sdmfilt=' + encodeURIComponent(ADV.sdmFilt || '') +
         '&sdmfiltnx=' + encodeURIComponent(ADV.sdmFiltNx || '') +
         '&directsdm=' + (ADV.directsdm ? 1 : 0) +
         '&dsdkind=' + (ADV.dsdKind || 'fir') + '&dsdconv=' + (ADV.dsdConv || 'narrow');
}
/* ---------------- 主题 ---------------- */
function setTheme(t, persist) {
  if (t !== 'dark' && t !== 'light' && t !== 'blue') t = 'dark';
  document.documentElement.dataset.theme = t;
  S.theme = t; ADV.theme = t;
  Array.prototype.forEach.call(document.querySelectorAll('.sw'), function (e) {
    e.classList.toggle('on', e.dataset.theme === t);
  });
  if (D('sp_theme')) D('sp_theme').value = t;   // 设置页里的下拉框跟着同步
  // 标题栏配色跟着主题走（Edge 应用窗口用 theme-color 画标题栏）
  // 2026-10-25（Apple Music 风格重构）：取值必须与 ui_page.h 的 --bg 逐字节一致 ——
  //   旧值 #0c0e13 是深色主题改版前的底色，留着会让 Windows 标题栏与页面本体出现一道色差。
  var tc = { dark: '#161618', light: '#ffffff', blue: '#f8faff' }[t] || '#161618';
  var meta = document.querySelector('meta[name=theme-color]');
  if (!meta) { meta = document.createElement('meta'); meta.setAttribute('name', 'theme-color'); document.head.appendChild(meta); }
  meta.setAttribute('content', tc);
  wcmd('theme:' + t);                 // 原生边框/圆角立即跟随，不再等 1.5 秒轮询
  try { localStorage.setItem('rta-theme', t); } catch (e) { }
  if (persist !== false) saveSettings();
}
Array.prototype.forEach.call(document.querySelectorAll('.sw'), function (e) {
  e.onclick = function () { setTheme(e.dataset.theme); };
});
function setUiStyle(u, persist) {
  u = (u === 'classic') ? 'classic' : 'apple';
  document.documentElement.dataset.uistyle = u;
  S.uiStyle = u; ADV.uiStyle = u;
  if (D('sp_uistyle')) D('sp_uistyle').value = u;
  try { localStorage.setItem('rta-uistyle', u); } catch (e) { }
  if (persist !== false) saveSettings();
  if (S.view === 'albums' && (!S.albums || !S.albums.length) && D('list')) {
    D('list').innerHTML = emptyStateHtml();
    bindEmptyState();
  }
}

// ---------- 无边框窗口：拖动 / 最小化 / 最大化 / 关闭 ----------
(function bindWindowChrome() {
  if (!WV) return;
  var ICON_MAX = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2'><rect x='6' y='6' width='12' height='12' rx='1.5'/></svg>";
  var ICON_REST = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2'><rect x='8' y='8' width='10' height='10' rx='1.5'/><path d='M5 5h10v10'/></svg>";
  function setMaxIcon(isMax) {
    var b = D('wMax'); if (!b) return;
    b.innerHTML = isMax ? ICON_REST : ICON_MAX;
    b.title = isMax ? '还原' : '最大化';
  }
  WV.addEventListener('message', function (ev) {
    if (ev.data === 'max') setMaxIcon(true);
    else if (ev.data === 'normal') setMaxIcon(false);
  });
  ['topbar', 'sideTop', 'sideBrand'].forEach(function (id) {
    var el = D(id);
    if (!el) return;
    el.addEventListener('mousedown', function (e) {
      if (e.button !== 0) return;
      if (e.target.closest('button,input,select,a,.search,.themes,.wctl')) return;
      wcmd('drag');
    });
    el.addEventListener('dblclick', function (e) {
      if (e.target.closest('button,input,select,a,.search,.themes,.wctl')) return;
      wcmd('max');
    });
  });
  // 2026-10-23 用户反馈「单曲播放页面无法拖动窗口」：npPage 是全屏覆盖层，把 topbar 的拖拽热区盖住了。
  // 这里给覆盖层自己的拖拽条（#npGrip）绑同一套行为：左键按下 → launcher 走 HTCAPTION 拖窗；双击 → 最大化切换。
  if (D('npGrip')) {
    D('npGrip').addEventListener('mousedown', function (e) {
      if (e.button !== 0) return;
      wcmd('drag');
    });
    D('npGrip').addEventListener('dblclick', function (e) {
      if (e.button !== 0) return;
      wcmd('max');
    });
  }
  if (D('wMin')) D('wMin').onclick = function () { wcmd('min'); };
  if (D('wMax')) D('wMax').onclick = function () { wcmd('max'); };
  if (D('wClose')) D('wClose').onclick = function () { wcmd('close'); };
})();

/* ---------------- 261024-04 #1：窗口边缘拉伸（页面发起 resize） ----------------
   为什么是页面发起：WebView2 的 3 个子窗口属于别的进程，宿主无法 subclass，鼠标事件全被它们吃掉，
   原生边缘 hit-test 收不到鼠标（10 轮都没修好）。所以改成：页面在窗口最外 5px 铺 8 条不可见热区，
   mousedown（左键）时 postMessage('resize:<方向>')，宿主走 WM_NCLBUTTONDOWN / HTLEFT 等。
   消息格式必须**逐字**一致（launcher.cpp 按前缀匹配）：
     resize:left | resize:right | resize:top | resize:bottom |
     resize:topleft | resize:topright | resize:bottomleft | resize:bottomright
   实现要点：
     ① 8 条 <i> 只负责光标形状与命中区域，判定统一在 document 的**捕获阶段**按坐标做——
        这样 CDP 里 dispatchEvent(new MouseEvent('mousedown',{clientX,clientY,bubbles:true}))（派给
        document，不经过元素命中）也能触发，与真实鼠标一致；
     ② 只在 html.webview2 下创建（浏览器直开时没有 chrome.webview，也不该有窗口边缘）；
     ③ 角落 10x10 优先于边（四条边各 5px），区域永远只在最外 5px ⟹ 顶栏按钮/单曲页控件不受影响；
     ④ stopPropagation：否则顶栏的拖拽处理（bindWindowChrome 的 'drag'）会跟着发一条，宿主会收到两条命令。 */
var RZ_BAND = 5;
var RZ_EDGES = [
  ['topleft', 'rz-tl'], ['topright', 'rz-tr'], ['bottomleft', 'rz-bl'], ['bottomright', 'rz-br'],
  ['left', 'rz-l'], ['right', 'rz-r'], ['top', 'rz-t'], ['bottom', 'rz-b']
];
function rzDirAt(x, y) {
  var W = window.innerWidth || document.documentElement.clientWidth || 0;
  var H = window.innerHeight || document.documentElement.clientHeight || 0;
  if (!W || !H) return '';
  var E = RZ_BAND, C = 10;                 // 边 = RZ_BAND（5px）、角落 10x10
  var CL = x <= C, CR = x >= W - C, CT = y <= C, CB = y >= H - C;
  if (CT && CL) return 'topleft';
  if (CT && CR) return 'topright';
  if (CB && CL) return 'bottomleft';
  if (CB && CR) return 'bottomright';
  if (x <= E) return 'left';
  if (x >= W - E) return 'right';
  if (y <= E) return 'top';
  if (y >= H - E) return 'bottom';
  return '';
}
(function bindResizeHotspots() {
  if (!WV) return;
  var box = document.createElement('div');
  box.id = 'rzHot';
  RZ_EDGES.forEach(function (d) {
    var i = document.createElement('i');
    i.className = d[1];
    i.setAttribute('data-rz', d[0]);
    box.appendChild(i);
  });
  document.body.appendChild(box);
  document.addEventListener('mousedown', function (e) {
    if (!e || (e.button !== 0 && e.button !== undefined && e.button !== null)) return;
    var d = rzDirAt(e.clientX, e.clientY);
    if (!d) return;
    wcmd('resize:' + d);      // ← 逐字格式，宿主按 'resize:' 前缀 + 方向解析
    e.preventDefault();       // 热区内不做拖拽 / 文本选择
    e.stopPropagation();      // 别让顶栏再发一条 'drag'
  }, true);
})();

var rzScrollers = [];
function rzScanScrollers() {
  var out = [];
  var all = document.querySelectorAll('*');
  for (var i = 0; i < all.length; i++) {
    var el = all[i];
    if (el.id === 'rzHot' || (el.parentNode && el.parentNode.id === 'rzHot')) continue;
    var oy = '';
    try { oy = getComputedStyle(el).overflowY; } catch (e) { oy = ''; }
    if (oy !== 'auto' && oy !== 'scroll') continue;
    out.push(el);
  }
  rzScrollers = out;
}
function rzApplyEdgeInset() {
  var W = window.innerWidth || 0;
  if (!W) return;
  for (var i = 0; i < rzScrollers.length; i++) {
    var el = rzScrollers[i];
    if (!el.isConnected) continue;
    var r = el.getBoundingClientRect();
    var on = el.classList.contains('rz-edge-inset');
    var atEdge = (r.right >= W - 1) && r.width > 8 && r.height > 8;
    if (atEdge && !on) el.classList.add('rz-edge-inset');
    else if (!atEdge && on) el.classList.remove('rz-edge-inset');
  }
}
(function rzBindEdgeInset() {
  if (!WV) return;
  try { document.documentElement.style.setProperty('--rzband', RZ_BAND + 'px'); } catch (e) { }
  var tmr = 0;
  function later(rescan) {
    clearTimeout(tmr);
    tmr = setTimeout(function () {
      if (rescan) rzScanScrollers();
      rzApplyEdgeInset();
    }, 160);
  }
  window.addEventListener('resize', function () { later(false); });
  document.addEventListener('click', function () { later(false); }, true);
  if (window.MutationObserver) {
    var mo = new MutationObserver(function (recs) {
      var structural = false;
      for (var i = 0; i < recs.length; i++) { if (recs[i].type !== 'attributes') { structural = true; break; } }
      later(structural);
    });
    mo.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
  }
  rzScanScrollers();
  rzApplyEdgeInset();
  setTimeout(function () { rzScanScrollers(); rzApplyEdgeInset(); }, 300);
})();

function fmtTag(sr, bits) {
  if (!sr) return '';
  return (sr % 1000 === 0 ? (sr / 1000) + 'k' : (Math.round(sr / 100) / 10) + 'k') + '/' + bits;
}

/* ---------------- 顶栏 / 工具区 ---------------- */
function head(title, subtitle, toolsHtml) {
  D('pth').textContent = title;
  D('pth').title = title;
  D('cnt').textContent = subtitle || '';
  D('cnt').title = subtitle || '';
  D('tools').innerHTML = toolsHtml || '';
}

/* ---------------- 专辑视图 ---------------- */
// 封面一律尝试加载：拿不到就让 img 自己消失，后面的首字母占位露出来。
// （早期用 cv 标记决定是否请求，结果「扫描时没识别出封面」就永远不显示了）
// 2026-10-26（封面在线抓取）：后端 /api/lib/cover 现在**找不到就 404**（不再回 1x1 占位图），
// 所以 onerror 必须是"隐藏 <img>、露出底下的首字母"，而不是让格子空着。
// cvUrl 只在「磁盘 covercache 有网图」时由后端给出；没有时回落到老路径（内嵌/同目录图）。
function albumCardHtml(a, i) {
  return '<div class=card data-i=' + i + '>' +
    '<div class=cv>' +
      '<div class=ph>' + esc((a.name || '?').slice(0, 1).toUpperCase()) + '</div>' +
      '<img src="' + (a.cvUrl || ('/api/lib/cover?k=' + a.k)) + '" loading=lazy alt="" onerror="this.style.display=\'none\'">' +
      '<div class=pl><svg width=13 height=13 viewBox="0 0 24 24" fill=#fff><path d="M8 5v14l11-7z"/></svg></div>' +
    '</div>' +
    '<div class=nm title="' + esc(a.name) + '">' + esc(a.name) + '</div>' +
    '<div class=ar title="' + esc(a.artist) + '">' + esc(a.artist || '未知艺术家') +
      (a.year ? '  \u00b7  ' + a.year : '') + (a.sr ? '  \u00b7  ' + fmtTag(a.sr, a.bits) : '') + '</div>' +
    '</div>';
}
// 2026-10-26（封面在线抓取）：封面抓取要有**看得见的进度**，并且进库页自动开跑。
// 后端：POST /api/lib/cover/prefetch（副作用）· GET /api/lib/cover/progress → {running,done,total,hit,miss,fail}
// 为什么进度必须显式：首次进库页要对上百张缺图专辑联网，没有进度用户会以为"页面又卡死了"
// —— 那正是这一轮要修的老病根。后端立即返回（网络全在后台 2 线程），前端只轮询。
var COVP = { timer: 0 };
function startCoverPrefetch() {
  api('/api/lib/cover/prefetch', '').then(function (j) {
    if (!j || !j.ok) return;
    if (j.queued) toast('正在抓取封面：共 ' + j.queued + ' 张缺图');
    // 2026-10-27（E-4）：只要**后台真的有活在跑**就轮询，不看"这一轮是不是我启动的"。
    // 后端 running 已改为真实活跃度（tools/rtaweb.cpp 的 /api/lib/cover/prefetch），
    // 所以这一行同时覆盖「本次启动成功」与「上一轮还在跑」两种情形 ——
    // 后者正是"服务端已有图、界面仍首字母占位"的直接原因（debug/20261027-01 §1 E-4）。
    // queued 只用来弹提示，不再参与"要不要轮询"的判断：它是"本次新排队张数"，
    // 后台在替别的页面干活时它天然是 0。
    if (j.running) pollCoverProgress();
  }).catch(function () { });
}
function pollCoverProgress() {
  if (COVP.timer) return;
  COVP.timer = setInterval(function () {
    api('/api/lib/cover/progress').then(function (g) {
      if (!g || !g.ok) return;
      var el = D('covProg');
      if (el) { el.style.display = 'flex'; el.textContent = '封面 ' + (g.done || 0) + '/' + (g.total || 0) + '（命中 ' + (g.hit || 0) + '）'; }
      if (!g.running) {
        clearInterval(COVP.timer); COVP.timer = 0;
        if (el && g.done > 0) setTimeout(function () { el.style.display = 'none'; }, 2500);
        // 2026-10-27（E-4 第二处根因）：抓完后必须**绕过视图缓存**重拉一次。
        // 原来直接调 loadAlbums()，而它开头的 viewCacheGet('albums|') 在 5s TTL 内会命中
        // 抓取开始时写下的那份快照（cv:false）⟹ 重绘了，但画出来的还是"没有封面"的旧数据。
        // 这就是"服务端已有图、界面仍首字母占位"的第二层原因，光改轮询条件修不掉。
        if (g.hit > 0) { toast('封面已补齐 ' + g.hit + ' 张'); delete VIEWC.m['albums|']; loadAlbums(); }
      }
    }).catch(function () { });
  }, 700);
}

function loadAlbums(q, title) {
  S.view = 'albums';
  startCoverPrefetch();     // 进库页就开跑（没有缺图时后端立即返回 queued=0）
  // 只有「不带搜索词」的整库视图才进缓存：带 q 的是用户主动查询，必须每次新鲜（261025-01 #5）。
  var ck = (q ? '' : 'albums|');
  var hit = viewCacheGet(ck);
  if (hit) { renderAlbumsFrom(hit, q, title); return; }
  head(title || '专辑', '加载中…', '');
  api('/api/lib/albums?q=' + encodeURIComponent(q || '')).then(function (j) {
    if (S.view !== 'albums') return;   // 已切走 → 丢弃，别覆写当前页面（与 loadTracks 同一类守卫）
    if (j && j._err) { head(title || '专辑', '读取失败', ''); listErrorBox('专辑列表读取失败', function () { loadAlbums(q, title); }); return; }
    if (ck) viewCachePut(ck, j);
    renderAlbumsFrom(j, q, title);
  }).catch(function (e) { listErrorBox('专辑列表读取失败', function () { loadAlbums(q, title); }); });
}

/* ---------------- 空库首页（2026-10-25 Apple Music「专属精选推荐」风格） ----------------
   用户反馈「mac 的控件在这个程序上不协调」的一部分：空库时主区只有一行灰字浮在裸背景上。
   上一版改成了一张居中卡片；本轮按 Apple Music 主页的版式重做：
     · 上方「专属精选推荐」= 三张并排大海报卡（渐变底 + 右上角技术徽标 + 中部大标题 + 底部说明 + 白色药丸 CTA）；
     · 下方「快速开始」= 四格快捷入口（图标 + 名称 + 一行说明）。
   约束（沿用上一轮，一条都没放松）：
     · 只复用已有入口 —— setView/loadFiles/loadRemote/openSettingsTab('#bScan') 全是既有函数；
     · 绝不发明后端/路由，绝不新增 API；
     · 只有在目标元素**实际存在**时才绑 onclick（bindEmptyState 里逐个判空）。
   注意：这里**不**删任何旧入口，只是把空态的版式换成海报形态。 */
/* ---------------- 音频工作站（2026-10-25 用户要求独立成导航页） ----------------
   用户原话：「这部分功能我感觉可以单做一个导航菜单」。
   原来这三张海报卡 + 四格快捷入口挤在**专辑页的空态**里，问题是：
     · 只有「曲库为空」时才看得到 —— 一旦导入音乐，这些功能入口就永远消失了；
     · 语义混乱：专辑页应该是「浏览专辑」，却塞了输出设备 / EQ / 输入采集的入口。
   现在改为左导航「音频引擎 → 音频工作站」独立一页，**任何曲库状态下都能进**。
   约束（沿用原实现，一条没放松）：
     · 只复用已有入口 —— setView / openSettingsTab 全是既有函数，不新增 API、不新增路由；
     · 绑定前逐个判空（bindWorkstation），元素不存在时静默跳过，不抛错。 */
function workstationHtml() {
  var validRoots = (S.roots || []).filter(function (r) {
    if (!r) return false;
    r = String(r).trim();
    if (SEP === '/' && /^[A-Za-z]:[\\/]/.test(r)) return false;
    return true;
  });
  var hasRoots = validRoots.length > 0;
  var rootPath = hasRoots ? String(validRoots[0] || '') : '';

  var h = '<div class=am-home>';
  // 2026-10-26（用户要求重新整理面板）：去掉「精选功能」「常用入口」两个分区标题 ——
  //   三张能力卡与四个快捷入口本身自解释，标题只占高度（760px 小窗里每行都是钱）。
  h += '<div class=am-hero-grid>';

  h += '<div class="am-card c1" id=amCardAdd>';
  h += '<div class=am-card-badge>\uf8ff Hi-Fi Library</div>';
  h += '<div class=am-card-mid><div class=am-card-title>无损音乐库</div></div>';
  h += '<div class=am-card-bottom>';
  h += '<div class=am-card-desc>' + (hasRoots
        ? '目录已就绪 · 点击重新扫描建立专辑与封面索引'
        : '支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE · 多碟盒装自动聚合') + '</div>';
  h += '<button class="am-pill-btn" id=emptyGoAdd>' + (hasRoots ? '重新扫描音乐库' : '添加音乐目录') + '</button>';
  h += '</div></div>';

  h += '<div class="am-card c2" id=amCardSet>';
  h += '<div class=am-card-badge>CoreAudio · Hog Mode</div>';
  h += '<div class=am-card-mid><div class=am-card-title>独占直通引擎</div></div>';
  h += '<div class=am-card-bottom>';
  h += '<div class=am-card-desc>Bit-Perfect 硬件独占 · 自动跟随源采样率 · DoP / SDM 调制器</div>';
  h += '<button class="am-pill-btn" id=emptyGoSet>配置输出设备</button>';
  h += '</div></div>';

  h += '<div class="am-card c3" id=amCardEq>';
  h += '<div class=am-card-badge>DSP · 64-Bit Float</div>';
  h += '<div class=am-card-mid><div class=am-card-title>20 段 PEQ 与 OPRA</div></div>';
  h += '<div class=am-card-bottom>';
  h += '<div class=am-card-desc>内置 6200+ 款耳机 OPRA 目标曲线 · 卷积房间校正 IR · 响度分析</div>';
  h += '<button class="am-pill-btn" id=emptyGoEq>打开均衡与校正</button>';
  h += '</div></div>';

  h += '</div>'; // .am-hero-grid

  // 2026-10-26（用户要求）：官方推荐预设放在「精选功能」三张卡**下边**、常用入口上边。
  // ⚠️ 上一轮已移动过一次，但被后续提交（ecadbd7 的 git add -A src/）把旧状态带回来了 ——
  //    这次改完必须验证产物里的顺序，不能只看源码。
  h += presetCardHtml();

  h += '<div class=am-quick-row>';

  h += '<div class=am-quick-item id=amGoFiles>';
  h += '<div class=am-qico><svg viewBox="0 0 24 24" fill=none stroke="currentColor" stroke-width=2><path d="M3 7.5a2 2 0 012-2h4l1.8 2H19a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg></div>';
  h += '<div class=am-qtext><div class=am-qtitle>设置文件夹位置</div></div>';
  h += '</div>';

  h += '<div class=am-quick-item id=amGoRemote>';
  h += '<div class=am-qico><svg viewBox="0 0 24 24" fill=none stroke="currentColor" stroke-width=2><path d="M7 18a4.5 4.5 0 010-9 6 6 0 0111.6 1.6A3.7 3.7 0 0118 18z"/></svg></div>';
  h += '<div class=am-qtext><div class=am-qtitle>挂载流媒体服务</div></div>';
  h += '</div>';

  h += '<div class=am-quick-item id=amGoMeta>';
  h += '<div class=am-qico><svg viewBox="0 0 24 24" fill=none stroke="currentColor" stroke-width=2><path d="M12 2v4m0 12v4M4.93 4.93l2.83 2.83m8.48 8.48l2.83 2.83M2 12h4m12 0h4M4.93 19.07l2.83-2.83m8.48-8.48l2.83-2.83"/></svg></div>';
  h += '<div class=am-qtext><div class=am-qtitle>AI 资料与封面补全</div></div>';
  h += '</div>';

  h += '<div class=am-quick-item id=amGoIn>';
  h += '<div class=am-qico><svg viewBox="0 0 24 24" fill=none stroke="currentColor" stroke-width=2><path d="M12 1a3 3 0 00-3 3v8a3 3 0 006 0V4a3 3 0 00-3-3z"/><path d="M19 10v2a7 7 0 01-14 0v-2M12 19v4M8 23h8"/></svg></div>';
  h += '<div class=am-qtext><div class=am-qtitle>音频输入采集</div></div>';
  h += '</div>';

  h += '</div>'; // .am-quick-row

  // 2026-10-26：底部「当前音乐目录」独立行已删 —— 那条信息并进「无损音乐库」卡的描述里
  //   （hasRoots 时描述本来就写「目录已就绪」），不再单独占一行高度。
  h += '</div>'; // .am-home
  return h;
}

function emptyStateHtml() {
  var validRoots = (S.roots || []).filter(function (r) {
    if (!r) return false;
    r = String(r).trim();
    if (SEP === '/' && /^[A-Za-z]:[\\/]/.test(r)) return false;
    return true;
  });
  var hasRoots = validRoots.length > 0;
  var rootPath = hasRoots ? String(validRoots[0] || '') : '';
  if (S.uiStyle === 'classic') {
    var hc = '<div class=emptystate><div class=ecard>';
    hc += '<div class=eic><svg width=22 height=22 viewBox="0 0 24 24" fill=none stroke=currentColor stroke-width=1.8>'
       + '<path d="M4 5.5h16M4 12h16M4 18.5h10"/><circle cx="19" cy="18" r="2.6"/></svg></div>';
    hc += '<div class=ettl>' + (hasRoots ? '库里还没有音乐' : '还没有添加音乐目录') + '</div>';
    hc += '<div class=ehint>' + (hasRoots
          ? '目录已经配好，但索引里还没有曲目。点下面的按钮重新扫描，或换一个目录。'
          : '添加一个包含音频文件的本地目录，RLPlayer 会建立索引并显示专辑。') + '</div>';
    hc += '<div class=eacts>'
       + '<button class="btn pri" id=emptyGoAdd>' + (hasRoots ? '重新扫描音乐库' : '添加音乐目录') + '</button>'
       + '<button class=btn id=emptyGoSet>打开设置</button></div>';
    if (hasRoots && rootPath) hc += '<div class=eroot><span title="' + esc(rootPath) + '">' + esc(rootPath) + '</span></div>';
    hc += '</div></div>';
    return hc;
  }
  // ---- 专辑页空态（2026-10-25 拆分）：只讲「曲库为空」这一件事 ----
  // 工作站那三张海报卡 + 四格快捷入口已搬到独立导航页「音频工作站」
  // （用户要求「这部分功能我感觉可以单做一个导航菜单」）。
  // 这里保留最必要的两件事：说明 + 添加/扫描入口 + 去工作站的引导。
  var h = '<div class="empty-guide-card" id=emptyGuideCard style="max-width:520px;margin:clamp(30px,8vh,70px) auto;padding:32px 28px;background:var(--card,var(--bg2));border:1px solid var(--line);border-radius:12px;text-align:center">' +
    '<div style="font-size:36px;margin-bottom:12px">&#127925;</div>' +
    '<div style="font-size:15px;font-weight:650;margin-bottom:8px">' +
    (hasRoots ? '已添加音乐目录，但未找到音频文件' : '还没有添加音乐目录') + '</div>' +
    '<div style="color:var(--mut2);font-size:12.5px;line-height:1.7;margin-bottom:20px">' +
    (hasRoots ? '当前目录中未发现可识别的音频文件，请确认音频格式或更换目录。' : 'RLPlayer 会自动为您建立高保真音乐库并整理专辑与元数据。<br>支持 FLAC、DSD (DSF/DFF)、WAV、ALAC、CUE 分轨等格式。') + '</div>' +
    '<div style="display:flex;justify-content:center;gap:12px;margin-bottom:12px">' +
    '<button class="btn pri" id=bEmptyAddRoot>&#128193; ' + (hasRoots ? '管理音乐目录' : '添加音乐目录') + '</button>' +
    '<button class="btn" id=bEmptyScan>&#128260; ' + (hasRoots ? '重新扫描' : '扫描目录') + '</button>' +
    '<button class="btn" id=emptyGoStation>打开快速开始</button>' +
    '</div>';
  if (hasRoots && rootPath) h += '<div class=eroot style="font-size:11px;color:var(--mut2);word-break:break-all"><span title="' + esc(rootPath) + '">' + esc(rootPath) + '</span></div>';
  h += '</div>';
  return h;
}
/* ---------------- 音频工作站页（2026-10-25 独立成导航页） ----------------
   渲染 + 绑定。绑定全部复用既有入口（setView / openSettingsTab / #bScan），
   不新增任何 API 或路由；每个元素判空后才绑，元素不存在时静默跳过。 */
function renderStation() {
  head('快速开始', '', '');
  var list = D('list');
  if (!list) return;
  list.innerHTML = workstationHtml();
  bindWorkstation();
  // 2026-10-26（预设卡片移入快速开始）：绑定与能力加载必须在这里也做一遍。
  // 原来只在设置页渲染时调 bindPresetCard()/loadPresetCaps()，卡片搬到快速开始后
  // 若不补这两行，三个按钮会点了没反应（元素在、onclick 没绑）。
  bindPresetCard();
  loadPresetCaps(false);
}

function bindWorkstation() {
  // 主 CTA（卡 1）：没有目录 → 进设置「高级」并聚焦目录输入框；已有目录 → 触发已有 #bScan
  var add = D('emptyGoAdd');
  if (add) add.onclick = function (ev) {
    if (ev && ev.stopPropagation) ev.stopPropagation();
    var validRoots = (S.roots || []).filter(function (r) {
      if (!r) return false;
      r = String(r).trim();
      if (SEP === '/' && /^[A-Za-z]:[\\/]/.test(r)) return false;
      return true;
    });
    if (validRoots.length > 0) {
      if (D('bScan')) D('bScan').click();
      else toast('请到设置页点「重新扫描全部」');
    } else {
      openSettingsTab('adv');
      var r = D('sp_root'); if (r) { try { r.focus(); } catch (e) { } }
    }
  };
  var c1 = D('amCardAdd');
  if (c1) c1.onclick = function (ev) {
    if (ev.target && ev.target.id === 'emptyGoAdd') return;
    var b = D('emptyGoAdd'); if (b) b.click();
  };

  // 卡 2：输出设备 = 设置「输出」页签
  var set = D('emptyGoSet');
  if (set) set.onclick = function (ev) {
    if (ev && ev.stopPropagation) ev.stopPropagation();
    openSettingsTab('out');
  };
  var c2 = D('amCardSet');
  if (c2) c2.onclick = function (ev) {
    if (ev.target && ev.target.id === 'emptyGoSet') return;
    openSettingsTab('out');
  };

  // 卡 3：均衡与校正 = 设置「EQ」页签
  var eq = D('emptyGoEq');
  if (eq) eq.onclick = function (ev) {
    if (ev && ev.stopPropagation) ev.stopPropagation();
    openSettingsTab('eq');
  };
  var c3 = D('amCardEq');
  if (c3) c3.onclick = function (ev) {
    if (ev.target && ev.target.id === 'emptyGoEq') return;
    openSettingsTab('eq');
  };

  // 快速开始四格：全部复用既有导航/设置入口
  var goFiles = D('amGoFiles');
  if (goFiles) goFiles.onclick = function () {
    // 2026-10-26（用户要求）：「设置文件夹位置」= 直接跳转到**设置里的文件夹设置区**，
    //   不要再静默弹系统选目录框。
    //   原因：用户点这个卡片时想的是「去那个地方设置」，而弹框只给了一个孤立动作，
    //   不告诉他设置在哪个页签、也不显示已有的库根列表 —— 加了新目录后找不到管理入口。
    //   mac 与 Windows 现在行为一致：openSettingsTab('adv') → 本地音乐库 → 「添加音乐目录」。
    openSettingsTab('adv');
    var r = D('sp_root');
    if (r) {
      try { r.focus({ preventScroll: true }); } catch (e) { }
      // 滚动到该字段所在的设置分组，让用户一眼看到；用 scrollIntoView 而不是
      // 手动算 offsetTop —— #setpage 现在是滚动容器（见 U-2 修复），手动算会算错容器。
      try { r.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (e) { }
    }
  };
  var goRemote = D('amGoRemote');
  if (goRemote) goRemote.onclick = function () { setView('remote'); loadRemote(''); };
  var goMeta = D('amGoMeta');
  if (goMeta) goMeta.onclick = function () { openSettingsTab('meta'); };
  var goIn = D('amGoIn');
  if (goIn) goIn.onclick = function () { openSettingsTab('in'); };
}

function bindEmptyState() {
  if (D('bEmptyAddRoot')) D('bEmptyAddRoot').onclick = function () { openSettingsTab('adv'); };
  if (D('bEmptyScan')) D('bEmptyScan').onclick = function () { if (D('bScan')) D('bScan').click(); };
  // 2026-10-25：专辑空态只留「添加/扫描」+「去音频工作站」两个入口
  var goStation = D('emptyGoStation');
  if (goStation) goStation.onclick = function (ev) {
    if (ev && ev.stopPropagation) ev.stopPropagation();
    setView('station');
    renderStation();
  };
  // 主 CTA（卡 1）：没有目录 → 直接进设置页「高级」（那里有添加目录输入框）；
  //               已有目录但索引为空 → 直接触发已有的 #bScan（重新扫描）按钮。
  var add = D('emptyGoAdd');
  if (add) add.onclick = function (ev) {
    if (ev && ev.stopPropagation) ev.stopPropagation();
    var validRoots = (S.roots || []).filter(function (r) {
      if (!r) return false;
      r = String(r).trim();
      if (SEP === '/' && /^[A-Za-z]:[\\/]/.test(r)) return false;
      return true;
    });
    if (validRoots.length > 0) {
      if (D('bScan')) D('bScan').click();
      else toast('请到设置页点「重新扫描全部」');
    } else {
      openSettingsTab('adv');
      var r = D('sp_root'); if (r) { try { r.focus(); } catch (e) { } }
    }
  };
  var c1 = D('amCardAdd');
  if (c1) c1.onclick = function (ev) {
    if (ev.target && ev.target.id === 'emptyGoAdd') return;
    var b = D('emptyGoAdd'); if (b) b.click();
  };

  // 卡 2：输出设备在设置页「输出」页签（data-g=out）
  var set = D('emptyGoSet');
  if (set) set.onclick = function (ev) {
    if (ev && ev.stopPropagation) ev.stopPropagation();
    openSettingsTab('out');
  };
  var c2 = D('amCardSet');
  if (c2) c2.onclick = function (ev) {
    if (ev.target && ev.target.id === 'emptyGoSet') return;
    openSettingsTab('out');
  };

  // 卡 3：均衡与校正 = 设置页「EQ」页签（data-g=eq）
  var eq = D('emptyGoEq');
  if (eq) eq.onclick = function (ev) {
    if (ev && ev.stopPropagation) ev.stopPropagation();
    openSettingsTab('eq');
  };
  var c3 = D('amCardEq');
  if (c3) c3.onclick = function (ev) {
    if (ev.target && ev.target.id === 'emptyGoEq') return;
    openSettingsTab('eq');
  };

  // 快速开始四格：全部复用既有导航/设置入口，不新增任何路由。
  var goFiles = D('amGoFiles') || D('amQuickFiles');
  if (goFiles) goFiles.onclick = function () { setView('files'); loadFiles(S.dir || ''); };
  var goRemote = D('amGoRemote') || D('amQuickRemote');
  if (goRemote) goRemote.onclick = function () { setView('remote'); loadRemote(''); };
  var goMeta = D('amGoMeta') || D('amQuickMeta');
  if (goMeta) goMeta.onclick = function () { openSettingsTab('meta'); };
  var goIn = D('amGoIn') || D('amQuickIn');
  if (goIn) goIn.onclick = function () { openSettingsTab('in'); };
}

function renderAlbumsFrom(j, q, title) {
  S.albums = (j && j.albums) || [];
  if (!S.albums.length) {
    head(title || '专辑', '0 张', '');
    if (q) {
      D('list').innerHTML = '<div class=empty id=searchEmpty style="padding:48px 20px;text-align:center">' +
                            '<div style="font-size:15px;font-weight:600;margin-bottom:6px">未找到与 “' + esc(q) + '” 相关的专辑</div>' +
                            '<div style="color:var(--mut2);font-size:12px;margin-bottom:16px">请尝试缩短搜索词，或检查是否有错别字</div>' +
                            '<button class="btn" id=bSearchClear>清空搜索词</button></div>';
      if (D('bSearchClear')) D('bSearchClear').onclick = function () {
        if (D('qClear')) D('qClear').click();
        else { D('q').value = ''; loadAlbums(''); }
      };
    } else {
      D('list').innerHTML = emptyStateHtml();
      bindEmptyState();
    }
    return;
  }
  head(title || '专辑', S.albums.length + ' 张专辑', '');
  // 封面预热进度条（2026-10-26）：上游 c41ce97 只写了 D('covProg') 的读取端，
  // **从来没有创建这个元素** ⟹ 进度永远不显示（等于没做）。这里补上真正的容器，
  // 并且默认 display:none —— 没有预热在跑时它不占位。
  var h = '<div id=covProg style="display:none;align-items:center;gap:8px;margin:0 22px 10px;' +
          'font-size:12px;color:var(--sub);font-variant-numeric:tabular-nums"></div>';
  h += '<div class=grid>';
  S.albums.forEach(function (a, i) {
    h += albumCardHtml(a, i);
  });
  h += '</div>';
  D('list').innerHTML = h;
  Array.prototype.forEach.call(D('list').querySelectorAll('.card'), function (e) {
    var a = S.albums[+e.dataset.i];
    e.onclick = function (ev) {
      if (ev.target.closest && ev.target.closest('.pl')) { playAlbum(a.k, 0); ev.stopPropagation(); return; }
      openAlbum(a.k);
    };
    e.oncontextmenu = function (ev) { ev.preventDefault(); enqueueAlbum(a.k); };
  });
}

/* ---------------- 收藏（心形喜好标记 / 261023-03 第5条） ---------------- */
var FAV_SET = new Set();

function initFavs() {
  api('/api/fav/list').then(function (j) {
    if (j && j.ok && Array.isArray(j.files)) {
      FAV_SET = new Set(j.files);
      updateFavUi();
    }
  }).catch(function () {});
}

function favIconHtml(filePath, isFav, extraClass) {
  var onCls = isFav ? ' on' : '';
  var extCls = extraClass ? (' ' + extraClass) : '';
  return '<button class="fav-btn' + onCls + extCls + '" data-file="' + esc(filePath) + '" title="' + (isFav ? '取消收藏' : '收藏') + '">' +
         '<svg width=14 height=14 viewBox="0 0 24 24" fill="' + (isFav ? '#e05666' : 'none') + '" stroke="' + (isFav ? '#e05666' : 'currentColor') + '" stroke-width="2">' +
         '<path d="M20.84 4.61a5.5 5.5 0 00-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 00-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 000-7.78z"/>' +
         '</svg></button>';
}

function toggleFav(filePath, ev) {
  if (ev) { ev.stopPropagation(); ev.preventDefault(); }
  if (!filePath) return;
  var isFav = FAV_SET.has(filePath);
  var nextOn = isFav ? 0 : 1;
  api('/api/fav?file=' + encodeURIComponent(filePath) + '&on=' + nextOn).then(function (j) {
    if (j && j.ok) {
      if (nextOn) {
        FAV_SET.add(filePath);
        toast('已添加到收藏');
      } else {
        FAV_SET.delete(filePath);
        toast('已取消收藏');
      }
      updateFavUi();
      if (S.view === 'tracks' && S.trackSort === 'fav') {
        renderTracksView();
      }
    }
  }).catch(function (e) {
    toast('收藏操作失败: ' + e);
  });
}

function updateFavUi() {
  Array.prototype.forEach.call(document.querySelectorAll('.fav-btn'), function (btn) {
    if (btn.id === 'npFavBtn') return;
    var f = btn.dataset.file;
    if (!f) return;
    var on = FAV_SET.has(f);
    btn.classList.toggle('on', on);
    var svg = btn.querySelector('svg');
    if (svg) {
      svg.setAttribute('fill', on ? '#e05666' : 'none');
      svg.setAttribute('stroke', on ? '#e05666' : 'currentColor');
    }
    btn.title = on ? '取消收藏' : '收藏';
  });
  // 同步单曲整页心形
  var npb = D('npFavBtn');
  if (npb) {
    if (S.lastCur) {
      npb.style.display = 'inline-flex';
      var curOn = FAV_SET.has(S.lastCur);
      npb.classList.toggle('on', curOn);
      var npsvg = npb.querySelector('svg');
      if (npsvg) {
        npsvg.setAttribute('fill', curOn ? '#e05666' : 'none');
        npsvg.setAttribute('stroke', curOn ? '#e05666' : 'currentColor');
      }
      npb.title = curOn ? '取消收藏' : '收藏';
    } else {
      npb.style.display = 'none';
    }
  }
}

/* ---- 结构化标签值网格（261024-01 #4）----
   后端契约（Lead）：/api/entity/summary 与 /api/entity/knowledge 的返回里带
     kind: 'track' | 'release' | 'person' | 'work'
     fields: { 标签: 值, ... }        // AI 只知道它能确认的；不知道的标签**根本不出现**
   前端职责：按实体类型排好序、长文本独占整行、空值一律不渲染（不占位、不写"未知"）。
   没有 fields（旧缓存/后端未升级）时自动退回 sections 段落渲染，绝不白屏。 */
// 每类实体「应该出现」的标签顺序（用户 #4 的思路 + 补全）。顺序 = 渲染顺序。
var EF_ORDER = {
  track: ['演唱', '作词', '作曲', '编曲', '歌曲风格', '发行时间', '所属专辑', '时长', '版本说明', '衍生作品', '歌词赏析'],
  person: ['简介', '国籍', '活跃年代', '风格', '代表作品', '厂牌', '合作'],
  release: ['艺术家', '发行时间', '专辑类型', '语种', '出版方', '专辑编号', '时长', '专辑介绍', '曲目列表', '制作人员', '关联'],
  work: ['作曲家', '创作年代', '体裁']
};
// 长文本标签：独占整行并保留换行（这些一定不是一格能装下的）
// 只有"一定是一整段/一整列"的标签才独占整行；代表作品/合作这类是短列表，留在网格里更紧凑（信息密度）。
var EF_WIDE = { '简介': 1, '专辑介绍': 1, '曲目列表': 1, '制作人员': 1, '歌词赏析': 1, '关联': 1, '衍生作品': 1, '版本说明': 1 };
function efValueText(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'string') return v.replace(/\s+$/, '').replace(/^\s+/, '');
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (Object.prototype.toString.call(v) === '[object Array]') {
    var out = [];
    for (var i = 0; i < v.length; ++i) { var s = efValueText(v[i]); if (s) out.push(s); }
    return out.join('\n');
  }
  try { return JSON.stringify(v); } catch (e) { return ''; }
}
// 261024-02 #3：本地曲库真实数据优先 —— opts.local = {标签: 值}（本地有就用本地的），
// opts.drop = {标签:1}（本地数据在页面上已经有专门的展示位置时，AI 那一项直接不渲染）。
// 值里的 http/https 自动变成可点链接（261024-02 #2：「关联」字段里的网址以前完全点不动）
function linkifyEscaped(v) {
  v = String(v == null ? '' : v);
  var re = /https?:\/\/[^\s<>"'）)】]+/g, out = '', last = 0, m;
  while ((m = re.exec(v))) {
    out += esc(v.slice(last, m.index));
    out += '<span class=eflink data-url="' + esc(m[0]) + '" role=link tabindex=0>' + esc(m[0]) + '</span>';
    last = m.index + m[0].length;
  }
  out += esc(v.slice(last));
  return out;
}
// 外链点击（事件委托，重绘后不需要重新绑定）
document.addEventListener('click', function (ev) {
  var t = ev.target;
  while (t && t !== document) {
    if (t.classList && t.classList.contains('eflink')) { ev.preventDefault(); openExternal(t.dataset.url); return; }
    t = t.parentNode;
  }
});
// 问号气泡左右自适应：右半屏右对齐向左展开，左半屏左对齐向右展开
['mouseover', 'focusin'].forEach(function (name) {
  document.addEventListener(name, function (e) {
    var t = e.target && e.target.closest && e.target.closest('.tip');
    if (t) {
      if (t.getBoundingClientRect().left > window.innerWidth * 0.55) t.classList.add('tip-r');
      else t.classList.remove('tip-r');
    }
  }, true);
});
function renderFieldGrid(fields, kind, opts) {
  if (!fields || typeof fields !== 'object') return '';
  var skip = {};
  var sk = (opts && opts.skip) || {}, dr = (opts && opts.drop) || {};
  Object.keys(sk).forEach(function (k) { skip[k] = 1; });
  Object.keys(dr).forEach(function (k) { skip[k] = 1; });
  var local = (opts && opts.local) || {};
  var labels = [], seen = {};
  var order = EF_ORDER[kind] || [];
  function hasVal(lb) {
    if (local[lb] !== undefined && local[lb] !== null && local[lb] !== '') return true;
    return fields[lb] !== undefined && fields[lb] !== null;
  }
  order.forEach(function (lb) {
    if (hasVal(lb) && !skip[lb]) { labels.push(lb); seen[lb] = 1; }
  });
  Object.keys(fields).forEach(function (lb) {   // 契约外的标签也照渲染（前端不许丢后端给的内容）
    if (!seen[lb] && !skip[lb] && labels.indexOf(lb) < 0) labels.push(lb);
  });
  Object.keys(local).forEach(function (lb) {    // 本地独有（AI 没给的）标签也要出现
    if (!seen[lb] && !skip[lb] && labels.indexOf(lb) < 0) labels.push(lb);
  });
  var rows = '';
  labels.forEach(function (lb) {
    var v = efValueText(fields[lb]);
    if (local[lb] !== undefined && local[lb] !== null && local[lb] !== '') v = efValueText(local[lb]);
    if (!v) return;                              // 空值 = 后端不知道 ⟹ 不占位
    var wide = !!EF_WIDE[lb] || v.length > 46 || v.indexOf('\n') >= 0;
    rows += '<div class="efrow' + (wide ? ' wide' : '') + '">' +
            '<div class=lb>' + esc(lb) + '</div><div class=vl>' + linkifyEscaped(v) + '</div></div>';
  });
  // 261024-02 #3：曲目列表用本地曲库逐行渲染（序号 / 曲名 / 时长三列对齐），不再用 AI 的一行文本。
  // 只有调用方真的传了本地曲目（opts.tracklist）才渲染；否则保留 AI 的文本版（并在末尾标注 AI 推测）。
  var tl = (opts && opts.tracklist) || null;
  if (tl && tl.length) {
    var tlh = '<div class="efrow wide"><div class=lb>曲目列表</div><div class=vl><div class=ef-tracklist>';
    tl.forEach(function (t, i) {
      var n = (typeof t.n === 'number' && t.n > 0) ? t.n : (i + 1);
      tlh += '<div class=eft-row><span class=eft-n>' + (n < 10 ? '0' : '') + n + '</span>' +
             '<span class=eft-t title="' + esc(t.title || '') + '">' + esc(t.title || '') + '</span>' +
             '<span class=eft-d>' + fmtDurLong(t.dur || 0) + '</span></div>';
    });
    tlh += '</div></div></div>';
    rows += tlh;
  }
  return rows ? ('<div class=efields>' + rows + '</div>') : '';
}
// 简介类区块的统一渲染：优先 fields 网格，兜底 sections 段落。
// title 非空时作为小标题（内容全是 AI 整理的板块一律传「AI 整理」，全站同一措辞 —— 261024-01 #2）。
function renderSummaryContent(summary, title, kind, opts) {
  if (!summary) return '';
  var sections = (summary.sections || []);
  var body = renderFieldGrid(summary.fields, (summary.kind || kind || ''), opts);
  if (!body) {
    if (!(summary.ok && sections.length)) return '';
    var citMap0 = {};
    (summary.citations || []).forEach(function (c, idx) { citMap0[c.id] = idx + 1; });
    var b0 = '';
    sections.forEach(function (sec) {
      b0 += '<div style="margin-bottom:10px">';
      if (sec.heading && sec.heading !== '概述' && sec.heading !== '简介') {
        b0 += '<div style="font-size:12.5px;font-weight:600;color:var(--txt);margin:6px 0 4px">' + esc(sec.heading) + '</div>';
      }
      (sec.paragraphs || []).forEach(function (p) {
        var sups = '';
        (p.citations || []).forEach(function (cid) {
          var found = citMap0[cid];
          if (found) sups += '<sup style="color:var(--mut);font-size:10px;margin-left:2px">[' + found + ']</sup>';
        });
        b0 += '<div style="font-size:12.5px;line-height:1.7;color:var(--txt);margin-bottom:6px">' + esc(p.text) + sups + '</div>';
      });
      b0 += '</div>';
    });
    body = b0;
  }
  if (!body) return '';
  var h = '';
  if (title) h += '<div style="font-size:12px;font-weight:600;letter-spacing:1px;color:var(--mut2);margin-bottom:8px">' + esc(title) + '</div>';
  h += body;
  if (summary.citations && summary.citations.length > 0) {
    h += '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:10px">';
    summary.citations.forEach(function (c, idx) {
      var label = '[' + (idx + 1) + '] ' + (c.title || c.source || '来源');
      h += citationChipHtml(c.url, label, false);
    });
    h += '</div>';
  }
  // 说明行：不写「AI 生成」这类字眼（用户 261023-03 #2）。
  // 261024-01 #2：用户明确要求**只显示「AI 整理」四个字** ⟹ 旧的
  // 「AI 整理（未找到权威来源，仅供参考）」/「未核对 · 依据来源整理…」一律删掉；
  // 有标题的板块（标题就是「AI 整理」）不再重复；有真实来源时才留一行来源提示。
  if (!summary.unverified) {
    if (summary.citations && summary.citations.length > 0) {
      h += '<div style="font-size:11px;color:var(--mut2);margin-top:8px">依据上面的来源整理，可能不完整，请以来源为准</div>';
    }
  } else if (!title) {
    h += '<div style="font-size:10.5px;color:var(--mut2);letter-spacing:.6px;margin-top:10px">AI 整理</div>';
  }
  return h;
}

// 简介请求（2026-10-23 DEBUG）：后端把「未命中缓存」的生成放到了后台线程，首次请求立即回
// {"pending":true}，这里按 2s 轮询同一个 URL 直到出结果/超时。这样自动生成期间
// /api/status（400ms 轮询）与播放控制不会被单线程 HTTP 后端堵住（以前会整站卡死）。
function fetchSummary(url, onDone, tries) {
  tries = tries || 0;
  api(url).then(function (j) {
    if (j && j.pending) {
      if (tries >= 60) { onDone({ ok: false, error: '资料整理超时' }); return; }
      setTimeout(function () { fetchSummary(url, onDone, tries + 1); }, 2000);
      return;
    }
    onDone(j);
  }).catch(function (e) { onDone({ ok: false, error: String(e) }); });
}

/* ---------------- 261024-04 #7：summary 的页面级缓存 + 单飞去重 ----------------
   用户原话：「只要打开了 AI 整理，进入页面就自动加载整理，不再需要点击」。
   要做到"自动"又不烧钱，必须保证**同一实体在页面生命周期内只请求一次**：
     * 同一 URL（kind + name + artist + lang）命中缓存 → 直接回调（异步回调，避免调用方在同步栈里重入）；
     * 正在飞行 → 挂到同一批回调上（不重复发请求）；
     * 成功/失败都缓存（失败不弹错，由调用方决定是否留一行"点击重试"）；
     * refresh=true 绕过缓存重新请求（用户明确点"重试/刷新"时才用）。 */
var SUMC = { cache: {}, inflight: {} };
function summHas(s) {
  return !!(s && ((s.fields && Object.keys(s.fields).length > 0) ||
                  (s.ok && s.sections && s.sections.length > 0)));
}
function summaryCached(url) {
  return Object.prototype.hasOwnProperty.call(SUMC.cache, url) ? SUMC.cache[url] : null;
}
function summaryOnce(url, cb, refresh) {
  cb = cb || function () { };
  if (refresh) delete SUMC.cache[url];
  else if (Object.prototype.hasOwnProperty.call(SUMC.cache, url)) {
    var hit = SUMC.cache[url];
    setTimeout(function () { cb(hit); }, 0);
    return;
  }
  var q = SUMC.inflight[url];
  if (q) { q.push(cb); return; }
  q = SUMC.inflight[url] = [cb];
  fetchSummary(url, function (s) {
    delete SUMC.inflight[url];
    SUMC.cache[url] = s;
    for (var i = 0; i < q.length; ++i) { try { q[i](s); } catch (e) { } }
  });
}

// 261024-02 #2：引用 chip 拆成两个动作 —— 点 chip 本体 = 用系统浏览器打开；点右侧「复制」= 复制链接。
function citationChipHtml(url, label, small) {
  var fs = small ? 'font-size:10.5px;padding:1px 7px' : 'font-size:11px;padding:2px 8px';
  return '<span class="cite-chip" style="display:inline-flex;align-items:center;gap:0;' + fs + '">' +
         '<button class="btn chip-open" data-url="' + esc(url) + '" title="在系统浏览器打开：' + esc(url) + '" ' +
         'style="' + fs + ';border-top-right-radius:0;border-bottom-right-radius:0">' +
         '<svg width=11 height=11 viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-1px;margin-right:4px">' +
         '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><path d="M15 3h6v6"/><path d="M10 14L21 3"/></svg>' +
         esc(label) + '</button>' +
         '<button class="btn chip-copy" data-url="' + esc(url) + '" title="复制链接" ' +
         'style="' + fs + ';border-top-left-radius:0;border-bottom-left-radius:0;border-left:0">复制</button>' +
         '</span>';
}
function bindCopyChips(container) {
  if (!container) return;
  Array.prototype.forEach.call(container.querySelectorAll('.chip-open'), function (btn) {
    btn.onclick = function (ev) { ev.stopPropagation(); openExternal(btn.dataset.url); };
  });
  Array.prototype.forEach.call(container.querySelectorAll('.chip-copy'), function (btn) {
    btn.onclick = function (ev) {
      ev.stopPropagation();
      var u = btn.dataset.url;
      if (!u) return;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(u).then(function () {
          toast('已复制来源链接');
        }).catch(function () {
          toast('已复制来源链接');
        });
      } else {
        toast('已复制来源链接');
      }
    };
  });
}

function openAlbum(k) {
  S.view = 'album';
  api('/api/lib/album?k=' + encodeURIComponent(k)).then(function (j) {
    if (S.view !== 'album') return;   // 已切走 → 丢弃（否则会把别页内容覆写成专辑页）
    if (!j.ok) { toast(j.error || '打不开专辑'); return; }
    S.album = j;
    // 2026-10-26（封面在线抓取）：封面 404 时不要留一块纯色空框 —— 用 <img> + 首字母底层
    // （与列表页一致）。上游 c41ce97 把 background-image 换成 img 的理由是「封面端点现在
    // 找不到就 404」，而 background-image 的 404 会留下一块**什么都没有**的纯色方块。
    var sub = [];
    if (j.artist) sub.push(esc(j.artist));
    if (j.year) sub.push(j.year);
    // 261024-02 #3：总时长 = 本地曲目时长之和（后端 /api/lib/album 的 dur 就是 Σ 本地曲目），
    // 用 1:05:24 形式；AI 不再参与时长计算。
    var localTotal = 0;
    (j.tracks || []).forEach(function (t) { localTotal += (t.dur || 0); });
    if (!localTotal) localTotal = j.dur || 0;
    sub.push(j.tracks.length + ' 首');
    sub.push(fmtDurLong(localTotal));
    var isThisPlaying = (S.playing || S.paused) && S.lastCur && (j.tracks || []).some(function (t) { return t.path === S.lastCur; });
    var albPlayText = isThisPlaying ? (S.paused ? '▶ 继续播放' : '❚❚ 暂停') : '▶ 播放整张';
    var albPlayTitle = isThisPlaying ? (S.paused ? '继续播放专辑' : '暂停播放') : '播放整张专辑';
    var h = '<div class=ahead><div class=cv style="position:relative">' +
            '<div class=ph>' + esc((j.name || '?').slice(0, 1).toUpperCase()) + '</div>' +
            '<img src="' + (j.cvUrl || ('/api/lib/cover?k=' + j.k)) + '" alt="" onerror="this.style.display=\'none\'" style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;border-radius:inherit">' +
            '</div><div class=info>' +
            '<div class=kind>ALBUM</div><h1 title="' + esc(j.name) + '">' + esc(j.name) + '</h1>' +
            '<div class=sub>' + sub.join(' \u00b7 ') + '</div>' +
            '<button class="btn pri" id=albPlayAll aria-label="播放整张专辑" title="' + albPlayTitle + '">' + albPlayText + '</button> ' +
            '<button class="btn pri" id=aPlay style="display:none">播放</button> ' +
            '<button class=btn id=aAdd>加入队列</button> ' +
            // 2026-10-26（261026-02 #3 的人工兜底）：找不到封面的专辑（同人自出版，全网没有）
            // 允许用户自己挑一张图，存进 covercache（**不动音乐文件**）——把「99%」补到 100% 的人工通道。
            '<button class=btn id=aSetCover title="为这张专辑指定一张封面图（存到本地缓存，不改动音乐文件）">设置封面</button> ' +
            '<input type=file id=aCoverFile accept="image/*" style="display:none"> ' +
            '<button class=btn id=aShuf>随机播放</button>' +
            '</div></div>';

    // 2026-10-23（UI 评审 #2）：曲目列表必须在首屏可见 —— 以前简介（有时是很长的维基消歧义文）
    // 排在曲目之前，1024 下用户一首歌都看不到。现在先曲目、后简介。
    // 261024-02 #3：这张表就是**本地曲库的曲目列表**（行数 = 本地曲目数、逐行「曲名 + 时长」），
    // 加一行表头把"几首 / 总时长"讲清楚，避免和 AI 资料里的「时长」打架。
    // 261024-04 #7：专辑页顶部的「后台整理曲目资料」细进度条（不打扰；没开 AI 整理时是空 div）
    h += '<div id=albProgWrap></div>';
    // 261024-04 #4b：曲目列表左右各 22px，与 .ahead 对齐（以前 0 ⟹ 表头「曲目列表」贴着卡片左边）
    h += '<div style="padding:4px 22px 24px">';
    h += '<div class="trlist-head"><span class=lb>曲目列表</span><span class=sp></span>' +
         '<span class=sum>' + j.tracks.length + ' 首 · 总时长 ' + fmtDurLong(localTotal) + '</span></div>';
    j.tracks.forEach(function (t, i) {
      var isFav = FAV_SET.has(t.path);
      // 2026-10-26（B-3 / 上游 2f21626 的 mac 版）：曲目行第 7 列 = **看得见**的「+」入队按钮。
      // 以前专辑页只有「点行 = 播放整张」，连右键都没绑 ⟹ 用户想把某一首加进队列**根本无路可走**
      // （比上游诊断的"只有一条不可发现的右键路径"更严重：这里连那条路径都没有）。
      // 任何格式（含 .dsf/.dff）都一样，因为入口在 UI 层、与解码路径无关。
      h += '<div class="trow trow-track" data-i=' + i + ' style="grid-template-columns:28px 24px minmax(120px,1.6fr) minmax(0,1fr) 92px 58px 26px;gap:8px">' +
           '<div class=n>' + (t.n || (i + 1)) + '</div>' +
           favIconHtml(t.path, isFav) +
           '<div class=tt title="' + esc(t.title) + '">' + esc(t.title) + '</div>' +
           '<div class=ar title="' + esc(t.artist || j.artist) + '">' + esc(t.artist || j.artist) + '</div>' +
           '<div class=bd>' + fmtTag(t.sr, t.bits) + '</div>' +
           '<div class=du>' + fmtDurLong(t.dur) + '</div>' +
           '<button class="add-btn" data-file="' + esc(t.path) + '" title="加入播放队列" aria-label="加入播放队列">+</button>' +
           '</div>';
    });
    h += '</div>';
    // 简介放在曲目之后（评审 #2）。
    // 261024-04 #4b：资料块左右各 22px（与 .ahead 对齐），正文内边距由 .sec-card（18px）提供。
    // 261024-04 #7：打开 AI 整理后**进入即自动加载**，不再需要点任何按钮。
    if (META.summary == 1) {
      h += '<div class="sec-card summary-sec" id="albumSummary" data-k="' + esc(j.k) + '"' +
           ' style="margin:8px 22px 24px">' +
           '<div style="font-size:12px;color:var(--mut2)">正在整理资料…</div>' +
           '</div>';
    }
    D('list').innerHTML = h;
    head(j.name, j.tracks.length + ' 首', '<button class=btn id=bBackAlbums title="返回专辑列表" aria-label="返回专辑列表">← 返回专辑</button>');
    if (D('bBackAlbums')) D('bBackAlbums').onclick = function () { loadAlbums(''); };

    if (META.summary == 1) {
      var albK = String(j.k);
      // 261024-01 #4：后端现在回结构化 fields（可能没有 sections）⟹ 判据用"能渲染出东西"
      // #3：本地曲库是时长的唯一真相源；AI 的「时长」「曲目列表」一律不采信
      var albOpts = { local: { '时长': fmtDurLong(localTotal) }, drop: { '曲目列表': 1 } };
      var albUrl = '/api/entity/summary?kind=release&name=' + encodeURIComponent(j.name) +
                   '&artist=' + encodeURIComponent(j.artist || '') + '&lang=zh';
      var renderAlbumSummary = function (s) {
        var el = D('albumSummary');
        if (!el || el.dataset.k !== albK) return;   // 异步回来时已切到别的专辑 → 丢弃
        var albHtml = summHas(s) ? renderSummaryContent(s, 'AI 整理', 'release', albOpts) : '';
        if (albHtml) {
          el.innerHTML = albHtml;
          bindCopyChips(el);
        } else if (s && (s.error || s.pending)) {
          // 261024-04 #7：失败不弹错，只留一行可点击重试
          el.innerHTML = '<div class="summ-retry" id=albumSummRetry role=button tabindex=0>' +
                         '资料整理失败（' + esc(s.error || '超时') + '）· 点击重试</div>';
          var rb = D('albumSummRetry');
          if (rb) rb.onclick = function () { summaryOnce(albUrl, renderAlbumSummary, true); };
        } else {
          el.remove();   // 无资料 / 无 key 又无缓存 → 干脆不显示
        }
      };
      summaryOnce(albUrl, renderAlbumSummary);
      // 261024-04 #7：整张专辑 = 专辑本身（上面）+ 每首曲目（后台，并发 ≤2）
      albumTrackPrefetch(j);
    }

    var albBtn = D('albPlayAll');
    if (albBtn) {
      albBtn.onclick = function () {
        var playing = (S.playing || S.paused) && S.lastCur && (j.tracks || []).some(function (t) { return t.path === S.lastCur; });
        if (playing) {
          playOrPause();
          syncAlbPlayAllBtn();
        } else {
          playAlbum(j.k, 0);
          albBtn.textContent = '❚❚ 暂停';
          albBtn.title = '暂停播放';
        }
      };
    }
    if (D('aPlay')) D('aPlay').onclick = function () { playAlbum(j.k, 0); };
    D('aAdd').onclick = function () { enqueueAlbum(j.k); };
    D('aShuf').onclick = function () { playAlbum(j.k, Math.floor(Math.random() * j.tracks.length)); };
    // 2026-10-26：人工补封面（同人自出版专辑全网无图时的唯一出路；存 covercache，不动音乐文件）
    if (D('aSetCover')) D('aSetCover').onclick = function () { D('aCoverFile').click(); };
    if (D('aCoverFile')) D('aCoverFile').onchange = function (ev) {
      var f = ev.target.files && ev.target.files[0];
      if (!f) return;
      var x = new XMLHttpRequest();
      x.open('POST', '/api/lib/cover/set?k=' + encodeURIComponent(j.k));
      x.onload = function () {
        try {
          var r = JSON.parse(x.responseText);
          if (r && r.ok) { toast('封面已设置'); openAlbum(j.k); }
          else { toast('设置失败：' + ((r && r.error) || '未知原因')); }
        } catch (e) { toast('设置失败：响应无法解析'); }
      };
      x.onerror = function () { toast('设置失败：网络错误'); };
      x.send(f);
    };
    Array.prototype.forEach.call(D('list').querySelectorAll('.fav-btn'), function (btn) {
      btn.onclick = function (ev) {
        ev.stopPropagation();
        toggleFav(btn.dataset.file, ev);
      };
    });
    // 2026-10-26（B-3）：.add-btn 必须**自己**绑 click 并 stopPropagation，
    // 否则会冒泡到行的 onclick = 播放整张（用户点「+」结果整张专辑重播，是更坏的回归）。
    Array.prototype.forEach.call(D('list').querySelectorAll('.add-btn'), function (btn) {
      btn.onclick = function (ev) {
        ev.stopPropagation();
        ev.preventDefault();
        var ti = +btn.closest('.trow').dataset.i;
        var tk = (j.tracks || [])[ti] || {};
        // cue 曲目必须把区间一起带上：同一整轨的多首 path 完全相同，
        // 只传 path 会把「第 3 首」入队成整轨的「第 1 首」（cueQuery 的既有口径）。
        addPathCue(tk.path, tk.cs, tk.ce);
      };
    });
    Array.prototype.forEach.call(D('list').querySelectorAll('.trow'), function (e) {
      e.onclick = function (ev) {
        if (ev.target.closest && ev.target.closest('.fav-btn')) return;
        if (ev.target.closest && ev.target.closest('.add-btn')) return;   // 「+」自己处理（双保险）
        var ti = +e.dataset.i;
        var tk = (j.tracks || [])[ti] || {};
        playAlbum(j.k, ti, tk.cs, tk.ce);      // cue 曲目：把本轨起止秒一起带上
      };
      // 2026-10-26（B-3）：专辑页曲目行右键 = 单曲操作菜单。
      // 之前这里**完全没有** oncontextmenu ⟹ 右键是浏览器原生菜单，什么都做不了。
      // 2026-10-27（F-5）：加入「音质体检」入口。原来的"右键=直接入队"改成菜单，
      //   入队仍是菜单第一项（老用户的肌肉记忆保留），新增一项不影响任何既有路径。
      e.oncontextmenu = function (ev) {
        ev.preventDefault();
        ev.stopPropagation();
        var tk = (j.tracks || [])[+e.dataset.i] || {};
        trackActionMenu(tk, ev.clientX, ev.clientY);
      };
    });
  });
}

/* ---------------- 261024-04 #7：专辑页后台整理（曲目级 summary 预取） ----------------
   规则（用户原话）：「只要打开了 AI 整理……如果是一整张专辑，则自动整理整个专辑」。
     * 进入专辑页立即自动整理：专辑本身（release，见 openAlbum）+ **专辑内每一首**（track）；
     * 曲目级是纯后台：并发 ≤2、不阻塞渲染、不弹错；顶部一条 2px 细进度条 + 一行小字，完成即消失；
     * 同一实体只请求一次（summaryOnce 的缓存 + 单飞）；同一张专辑只排一次队；
     * 失败也计入进度（不是一直转），不留错误提示（曲目级本来就没人盯着看）。 */
var ALBPREF = { key: '', total: 0, done: 0, active: 0, queue: [], timer: 0 };
function albPrefKey(a) { return String((a && a.k) || '') + '|' + String((a && a.name) || ''); }
// 曲目级 URL 的拼法与单曲页抽屉（npDataEnsure）保持一致，才能命中同一份缓存
function albumTrackUrl(t, alb) {
  var ar = (t && t.artist) || (alb && alb.artist) || '';
  return '/api/entity/summary?kind=track&name=' + encodeURIComponent((t && t.title) || '') +
         (ar ? ('&artist=' + encodeURIComponent(ar)) : '') + '&lang=zh';
}
function albPrefRender() {
  var box = D('albProgWrap');
  if (!box) return;
  if (!ALBPREF.total) { box.innerHTML = ''; return; }
  var pct = ALBPREF.total ? Math.round(ALBPREF.done / ALBPREF.total * 100) : 0;
  var txt = (ALBPREF.done >= ALBPREF.total)
    ? ('曲目资料已后台整理 ' + ALBPREF.total + ' 首')
    : ('正在后台整理曲目资料 ' + ALBPREF.done + ' / ' + ALBPREF.total);
  box.innerHTML = '<div class="albprog"><span class=t>' + esc(txt) + '</span>' +
                  '<span class=bar><i style="width:' + pct + '%"></i></span></div>';
}
function albPrefPump() {
  while (ALBPREF.active < 2 && ALBPREF.queue.length) {
    var it = ALBPREF.queue.shift();
    ALBPREF.active++;
    summaryOnce(it.url, function () {
      ALBPREF.active--;
      ALBPREF.done++;
      albPrefRender();
      if (ALBPREF.done >= ALBPREF.total) {
        clearTimeout(ALBPREF.timer);
        ALBPREF.timer = setTimeout(function () {
          var b = D('albProgWrap');
          if (b && ALBPREF.done >= ALBPREF.total) b.innerHTML = '';
        }, 2600);
      }
      albPrefPump();
    });
  }
}
function albumTrackPrefetch(alb) {
  if (META.summary != 1) return;
  if (META.hasLlmKey !== true && META.summaryEnabled !== true) return;
  var key = albPrefKey(alb);
  if (ALBPREF.key === key) return;      // 同一张专辑只排一次
  var tracks = (alb && alb.tracks) || [];
  var q = [];
  tracks.forEach(function (t) { if (t && t.title) q.push({ url: albumTrackUrl(t, alb) }); });
  if (!q.length) return;
  ALBPREF = { key: key, total: q.length, done: 0, active: 0, queue: q, timer: 0 };
  albPrefRender();
  albPrefPump();
}

/* cs/ce = 被点那一轨的 CUE 区间（来自 /api/lib/album 每首的 cs/ce）。
   服务端本来就从库里读同一份区间（双保险：索引是旧版时前端这份仍然能把起点带对），
   两者一致时行为完全相同 —— 判据"点第 2 轨从 0 开始计 pos"两边都成立。 */
function playAlbum(k, i, cs, ce) {
  api('/api/lib/play', 'k=' + encodeURIComponent(k) + '&i=' + (i || 0) + cueQuery(cs, ce) + '&' + params()).then(function (j) {
    if (!j.ok) { toast(j.error || '播放失败'); return; }
    toast('开始播放专辑'); loadQ();
  });
}
function enqueueAlbum(k) {
  api('/api/lib/enqueue?k=' + encodeURIComponent(k)).then(function (j) {
    if (!j.ok) { toast(j.error || '加入失败'); return; }
    toast('整张专辑已加入队列'); loadQ();
  });
}

/* ---------------- 艺术家 ---------------- */
function loadArtists(q) {
  S.view = 'artists';
  S.artistsQuery = q || '';
  // 艺术家页是**纯派生视图**：数据源就是 /api/lib/albums 那一份（后端没有独立端点）。
  // 只有无过滤词的完整数据才进缓存：带 q 的即时过滤。
  var ck = (q ? '' : 'albums|');
  var hit = viewCacheGet('albums|');
  if (hit) { renderArtistsFrom(hit, q); return; }
  head('艺术家', '加载中…', '');
  api('/api/lib/albums').then(function (j) {
    if (S.view !== 'artists') return;   // 已切走 → 丢弃，别覆写当前页面
    if (j && j._err) { head('艺术家', '读取失败', ''); listErrorBox('艺术家列表读取失败', function () { loadArtists(q); }); return; }
    viewCachePut('albums|', j);
    renderArtistsFrom(j, q);
  }).catch(function () { listErrorBox('艺术家列表读取失败', function () { loadArtists(q); }); });
}

function renderArtistsFrom(j, q) {
  var m = {}, order = [];
  var filterQ = (q || '').trim().toLowerCase();
  ((j && j.albums) || []).forEach(function (a) {
    var k = a.artist || '未知艺术家';
    if (filterQ && k.toLowerCase().indexOf(filterQ) === -1) return;
    if (!m[k]) { m[k] = { n: 0, d: 0, cv: false, key: a.k }; order.push(k); }
    m[k].n++; m[k].d += a.dur;
    if (a.cv) m[k].cv = true, m[k].key = a.k;
  });
  order.sort(function (x, y) { return x.localeCompare(y, 'zh'); });
  head(q ? ('艺术家（搜索：' + q + '）') : '艺术家', order.length + ' 位', '');
  if (!order.length) {
    if (q) {
      D('list').innerHTML = '<div class=empty id=searchEmpty style="padding:48px 20px;text-align:center">' +
                            '<div style="font-size:15px;font-weight:600;margin-bottom:6px">未找到与 “' + esc(q) + '” 相关的艺术家</div>' +
                            '<div style="color:var(--mut2);font-size:12px;margin-bottom:16px">请尝试缩短搜索词，或检查是否有错别字</div>' +
                            '<button class="btn" id=bSearchClear>清空搜索词</button></div>';
      if (D('bSearchClear')) D('bSearchClear').onclick = function () {
        if (D('qClear')) D('qClear').click();
        else { D('q').value = ''; loadArtists(''); }
      };
    } else {
      D('list').innerHTML = '<div class=empty>库里还没有音乐</div>';
    }
    return;
  }
  var h = '<div class=grid style="grid-template-columns:repeat(auto-fill,minmax(150px,1fr))">';
  order.forEach(function (k) {
    var v = m[k];
    // 头像统一圆形（评审 #4）：占位字母**始终**渲染在底层，封面用 <img> 覆盖并 onerror 自隐。
    // 以前用 background-image：封面文件缺失时整块纯黑、连首字母都没有（Irotas/RØSE 就是这样）。
    var phChar = (String(k).trim().slice(0, 1) || '?').toUpperCase();
    // 2026-10-27（F-4 三层降级，与 artistHeroHtml 同一套）：
    //   ① /api/artist/image（真头像）→ ② /api/lib/cover（专辑封面兜底）→ ③ .ph 首字母
    // 以前只有②，没有专辑封面的艺人（真实库 106/245）永远只剩首字母圆。
    // 注意：列表页是**每张卡一张图**，艺人多的库会并发很多请求；
    //   所以这里加 loading=lazy（浏览器只请求视口内的），不会一次打满。
    var whoArg = encodeURIComponent(String(k == null ? '' : k));
    var imgTag = '<img data-stage="artist"' + (v.cv ? (' data-coverkey="' + esc(v.key) + '"') : '') +
                 ' src="/api/artist/image?who=' + whoArg + '" loading=lazy alt="" ' +
                 'style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;border-radius:50%" ' +
                 'onerror="artistAvatarFallback(this)">';
    h += '<div class=card data-a="' + esc(k) + '"><div class=cv style="border-radius:50%;overflow:hidden">' +
         '<div class=ph style="border-radius:50%">' + esc(phChar) + '</div>' +
         imgTag + '</div>' +
         '<div class=nm>' + esc(k) + '</div><div class=ar>' + v.n + ' 张专辑</div></div>';
  });
  h += '</div>';
  D('list').innerHTML = h;
  Array.prototype.forEach.call(D('list').querySelectorAll('.card'), function (e) {
    e.onclick = function () {
      var who = e.dataset.a;
      openArtistProfile(who);
    };
  });
}
function renderAlbumSubset(who) {
  S.view = 'albums';
  head(who, S.albums.length + ' 张专辑', '<button class=btn id=bArtistBio>艺术家资料</button> <button class=btn id=bAll>返回全部专辑</button>');
  var h = '<div class=grid>';
  S.albums.forEach(function (a, i) { h += albumCardHtml(a, i); });
  D('list').innerHTML = h + '</div>';
  D('bArtistBio').onclick = function () { openArtistProfile(who); };
  D('bAll').onclick = function () { loadAlbums(''); };
  Array.prototype.forEach.call(D('list').querySelectorAll('.card'), function (e) {
    var a = S.albums[+e.dataset.i];
    e.onclick = function (ev) {
      if (ev.target.closest && ev.target.closest('.pl')) { playAlbum(a.k, 0); ev.stopPropagation(); return; }
      openAlbum(a.k);
    };
  });
}

/* ---------------- 艺术家资料页（P3④a/④b） ----------------
   261024-04 #5：以前 openArtistProfile 先把整页写成「正在获取权威资料…」，等 /api/entity/knowledge
   回来才渲染 ⟹ 慢网下整页空白好几秒。现在：
     ① **立刻**渲染基础页（名字 + 返回按钮 + 头像 + 资料区块），「正在获取资料…」只出现在**资料区块**里；
     ② 资料回来后只重绘这几块；③ 切走再回来：同 who 的请求 in-flight ⟹ 挂回调复用，
        已有结果 ⟹ 直接渲染，绝不重复请求（费用纪律）。 */
var ARTIST_KNOW = {};    // who -> { state: 'loading'|'done', res, waiters: [] }
// F-4：头像三层降级的第二层 —— 头像端点失败时退到专辑封面，再失败就露首字母。
// 单独成函数（而不是内联 onerror）是因为要读 dataset 且只降一级，内联写不下且易错。
function artistAvatarFallback(img) {
  if (!img) return;
  var stage = img.dataset ? img.dataset.stage : '';
  var ck = img.dataset ? img.dataset.coverkey : '';
  if (stage === 'artist' && ck) {
    // 第二层：换成专辑封面；再失败就走 else 分支隐藏自己
    img.dataset.stage = 'cover';
    img.src = '/api/lib/cover?k=' + encodeURIComponent(ck);
    return;
  }
  // 第三层：两层都失败 → 隐藏 img，露出发底下的 .ph 首字母（绝不渲染空白圆）
  img.style.display = 'none';
}

function artistCoverKey(who) {
  if (!(S.albums && S.albums.length)) return '';
  for (var i = 0; i < S.albums.length; i++) {
    if ((S.albums[i].artist || '') === who && S.albums[i].cv) return S.albums[i].k;
  }
  return '';
}
function artistHeroHtml(who, subText) {
  var cvKey = artistCoverKey(who);
  // 2026-10-26（F-7）：以前是 **二选一** —— 有 cvKey 就不渲染 .ph，改成 background-image。
  // 后果：cvKey 指向的专辑只有一张 1x1 占位 PNG 时（B-1：media_info.h 的 get_cover 找不到图
  // 会返回合法 PNG，HTTP 200），background-image 铺满一个纯色 168px 圆 ⟹ **连首字母都没有**。
  // 现在与 loadArtists()（:1462-1467）的既有写法统一：
  //   · .ph 首字母**永远**渲染在底层；
  //   · 封面用 <img> 覆盖在上，加载失败/解码失败 → onerror 自隐 ⟹ 露回首字母。
  // 这样「有真封面」「有占位图」「根本没封面」三种情况都不会出现空白圆。
  var phChar = (String(who == null ? '' : who).trim().slice(0, 1) || '?').toUpperCase();
  // 2026-10-27（F-4 三层降级）：艺人**头像**优先，专辑封面次之，首字母永远兜底。
  //   ① /api/artist/image?who=  —— 真正的艺人头像（artwork.h 多源调度）
  //   ② /api/lib/cover?k=       —— 该艺人某张专辑的封面（旧行为，仍保留作兜底）
  //   ③ .ph 首字母              —— 永远渲染在底层，前两层加载失败就露出来
  // 为什么要两层 img：以前只有②，没有专辑封面的艺人（真实库 106/245）永远只剩首字母。
  // ②的 onerror 把自身 display 设成 none 之后，①还应该有机会 —— 所以这里**先①后②**，
  // ①失败时动态插入②，②也失败就只剩首字母，任何一层都不会留白圆。
  var whoArg = encodeURIComponent(String(who == null ? '' : who));
  var cvImg = whoArg
    ? '<img id=aheadImg data-stage="artist" src="/api/artist/image?who=' + whoArg + '" loading=lazy alt="" ' +
      'style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;border-radius:50%" ' +
      'onerror="artistAvatarFallback(this)">'
    : '';
  // 专辑封面作为第二层，先记在 dataset 上供 onerror 回调取用（不预先渲染，避免两张图同时请求）
  var cvKeyAttr = cvKey ? (' data-coverkey="' + esc(cvKey) + '"') : '';
  cvImg = cvImg.replace('<img ', '<img' + cvKeyAttr + ' ');
  return '<div class="ahead artist-head">' +
       '<div class=cv style="border-radius:50%;overflow:hidden">' +
       '<div class=ph style="border-radius:50%">' + esc(phChar) + '</div>' +
       cvImg +
       '</div>' +
       '<div class=info>' +
       '<div class=kind>ARTIST · 艺术家资料</div>' +
       '<h1>' + esc(who) + '</h1>' +
       '<div class=sub>' + esc(subText || '') + '</div>' +
       '<div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap">' +
       '<button class=btn id=bArtistAlbums>查看专辑</button> ' +
       '<button class=btn id=bArtistRefresh>刷新资料</button> ' +
       '<button class=btn id=bBackArtists>返回列表</button>' +
       '</div></div></div>';
}
// 基础页（骨架）：hero + 资料区块。「正在获取资料…」**只出现在资料区块里**
//（用户 261024-04 #5 的要求），hero 与返回按钮立刻可点、副标题留空不占位。
function artistBaseHtml(who) {
  var h = artistHeroHtml(who, '');
  h += '<div class=artist-body style="padding:0 22px 30px">';
  if (META.summary == 1) {
    h += '<div class="sec-card summary-sec" id=artistSummary style="margin-bottom:20px">' +
         '<div style="font-size:12px;color:var(--mut2)">正在获取资料…</div></div>';
  }
  h += '<div class="sec-card" id=artistKnowCard style="margin-bottom:24px">' +
       '<div style="font-size:12.5px;color:var(--mut)">正在获取资料…</div></div>';
  h += '</div>';
  return h;
}
function bindArtistButtons(who) {
  if (D('bArtistAlbums')) {
    D('bArtistAlbums').onclick = function () {
      api('/api/lib/albums').then(function (jj) {
        S.albums = (jj.albums || []).filter(function (a) { return (a.artist || '未知艺术家') === who; });
        renderAlbumSubset(who);
      });
    };
  }
  if (D('bArtistRefresh')) D('bArtistRefresh').onclick = function () { openArtistProfile(who, true); };
  if (D('bBackArtists')) D('bBackArtists').onclick = function () { loadArtists(); };
  if (D('bRetryKnowledge')) D('bRetryKnowledge').onclick = function () { openArtistProfile(who, true); };
  if (D('bBioToggle')) {
    D('bBioToggle').onclick = function () {
      var box = D('bioBox');
      if (!box) return;
      var isCol = box.classList.toggle('collapsed');
      this.textContent = isCol ? '展开全部' : '收起简介';
    };
  }
}
function openArtistProfile(who, refresh) {
  S.view = 'artist';
  setView('artists');
  S.view = 'artist';
  S.artistWho = who;
  head(who, '', '<button class=btn id=bBackArtistsTop>返回艺术家列表</button>');
  if (D('bBackArtistsTop')) D('bBackArtistsTop').onclick = function () { loadArtists(); };
  // ① 立刻出基础页（绝不整页空白等接口；加载文案只进资料区块）
  D('list').innerHTML = artistBaseHtml(who);
  bindArtistButtons(who);

  var wantSumm = (META.summary == 1);
  var summState = { done: false, res: null, enabled: wantSumm, skipBio: false };
  var uSumm = '/api/entity/summary?kind=person&name=' + encodeURIComponent(who) + '&lang=zh' +
              (refresh ? '&refresh=1' : '');
  var onSumm = function (s) {
    summState.done = true; summState.res = s;
    applyArtistSummary();
  };
  function applyArtistSummary() {
    if (!wantSumm) return;
    if (S.view !== 'artist' || S.artistWho !== who) return;    // 已切走 → 丢弃
    var el = D('artistSummary');
    if (!el || !summState.done) return;
    var ss = summState.res;
    // 261024-01 #4：AI 资料优先按后端结构化 fields 渲染成标签值网格；旧缓存只有 sections 也能显示。
    if (summHas(ss)) {
      el.style.display = '';
      el.innerHTML = renderSummaryContent(ss, 'AI 整理', 'person', { skip: (summState.skipBio ? { '简介': 1 } : {}) });
      bindCopyChips(el);
    } else if (ss && (ss.error || ss.pending)) {
      // 261024-04 #7：失败不弹错，只留一行可点击重试
      el.style.display = '';
      el.innerHTML = '<div class="summ-retry" id=artistSummRetry role=button tabindex=0>' +
                     '资料整理失败（' + esc(ss.error || '超时') + '）· 点击重试</div>';
      var rb = D('artistSummRetry');
      if (rb) rb.onclick = function () { summaryOnce(uSumm, onSumm, true); };
    } else {
      el.remove();   // 无资料 / 无 key 又无缓存 → 不留空白板块
    }
  }
  function paintKnow(res) {
    if (S.view !== 'artist' || S.artistWho !== who) return;
    renderArtistProfile(who, res, summState);
    applyArtistSummary();
    bindArtistButtons(who);
  }

  // ② 知识/资料：同 who 的在飞请求复用，已有结果直接渲染（不重复请求）
  var kc = ARTIST_KNOW[who];
  if (!refresh && kc && kc.state === 'done') {
    paintKnow(kc.res);
  } else if (!refresh && kc && kc.state === 'loading') {
    kc.waiters.push(paintKnow);
  } else {
    var rec = ARTIST_KNOW[who] = { state: 'loading', res: null, waiters: [paintKnow] };
    var uKnow = '/api/entity/knowledge?kind=person&name=' + encodeURIComponent(who) + (refresh ? '&refresh=1' : '');
    api(uKnow).catch(function (err) { return { ok: false, error: String(err), materials: [] }; })
      .then(function (res) {
        rec.state = 'done'; rec.res = res;
        var ws = rec.waiters; rec.waiters = [];
        ws.forEach(function (f) { try { f(res); } catch (e) { } });
      });
  }

  // ③ 简介（AI 整理）：与知识并行，谁先到都不丢；summaryOnce 保证同一实体只请求一次
  if (wantSumm) summaryOnce(uSumm, onSumm, refresh);
}

function renderArtistProfile(who, j, summary) {
  S.view = 'artist';
  setView('artists');
  S.view = 'artist';

  var mats = (j && j.materials) || [];
  var isOk = j && j.ok && mats.length > 0;
  // 资料解析提前到这里：AI 资料网格要知道"简介"是否已由词条给出（避免同一页两段简介）。
  var bioMat = null;
  var stylesMats = [];
  mats.forEach(function (m) {
    if (!bioMat && (m.kind === 'biography' || m.kind === 'disambiguation' || m.text)) bioMat = m;
    if (m.kind === 'genre' || m.kind === 'similar') stylesMats.push(m);
  });
  var bioText = (isOk && bioMat) ? (bioMat.text || '') : '';

  var subText = '';
  if (isOk) {
    var firstDate = mats[0].fetched_at ? fmtDate(mats[0].fetched_at) : '';
    if (j.from_cache) {
      subText = '缓存 · ' + (firstDate || '近期') + ' 取回' + (j.offline ? ' · 离线' : '');
    } else {
      // 261024-04 #5：去掉「权威」二字（用户要求全文案不再出现「权威资料 / 权威词条」）
      subText = '资料' + (firstDate ? (' · ' + firstDate + ' 取回') : '');
    }
  }
  // 261024-01 #3a：没有资料时**不显示**「资料暂缺」这类状态小字 —— 顶部只留名字，
  // 下方安静地给 AI 整理资料；没有资料就什么都不显示（用户原话：那句说明"纯粹多余"）。

  head(who, subText, '<button class=btn id=bTopBack>返回艺术家列表</button>');
  if (D('bTopBack')) D('bTopBack').onclick = function () { loadArtists(); };

  var h = '';
  // 头像/名称（261024-04 #5：与基础骨架共用同一份 markup，避免两处漂移）
  h += artistHeroHtml(who, subText);

  h += '<div class=artist-body style="padding:0 22px 30px">';

  // AI 整理资料（261024-01 #3a/#4）：这是本页**主内容**，紧跟 hero 之后；
  //   词条资料缺失时不再有任何"资料暂缺 / 维基百科没有匹配条目…"的解释卡（用户：那句纯粹多余）。
  //   结构化 fields → 标签值网格；旧缓存只有 sections → 段落兜底；两者都没有就整卡不渲染。
  var summHtml = '';
  if (META.summary == 1) {
    var sumObj = (summary && summary.enabled && summary.done) ? summary.res : null;
    var hasSummary = summHas(sumObj);
    var sumLoading = (META.hasLlmKey === true && !hasSummary);
    if (summary) summary.skipBio = !!bioText;   // 词条简介已在下面展示 → AI 网格里不重复「简介」
    summHtml = '<div class="sec-card summary-sec" id="artistSummary" style="margin-bottom:20px' + (sumLoading ? '' : ';display:none') + '">';
    if (hasSummary) {
      summHtml += renderSummaryContent(sumObj, 'AI 整理', 'person', { skip: (bioText ? { '简介': 1 } : {}) });
    } else if (sumLoading) {
      summHtml += '<div style="font-size:12px;color:var(--mut2)">正在获取资料…</div>';
    }
    summHtml += '</div>';
  }
  h += summHtml;

  if (!isOk) {
    // 261024-01 #3a：**删除整个「资料暂缺」说明块**。没有词条资料 → 上面 AI 资料安静显示，这里什么都不放。
    // 只有"在线整理也没开"这种确实无内容可显示的情况，才给一行极简空态 + 重试（绝不写一大段解释）。
    if (META.summary != 1 || META.hasLlmKey !== true) {
      h += '<div class="card empty-card" style="padding:22px 20px;text-align:center;background:var(--phbg);border:1px solid var(--line);border-radius:12px;margin-top:14px">' +
           '<div style="color:var(--mut);font-size:12.5px">暂无资料</div>' +
           '<button class="btn" id=bRetryKnowledge style="margin-top:12px">重试获取</button>' +
           '</div>';
    }
  } else {
    // 1) 词条简介（原文，长文折叠「展开」）—— 排在 AI 资料之后，是"佐证"而不是主内容
    var isLong = bioText.length > 280 || (bioText.split('\n').length > 5);

    h += '<div class="sec-card bio-sec" style="margin-bottom:24px">' +
         '<div class="sec-title" style="font-size:12px;font-weight:600;letter-spacing:1px;color:var(--mut2);margin-bottom:10px">简介</div>' +
         '<div class="bio-box ' + (isLong ? 'collapsed' : '') + '" id=bioBox>' +
         esc(bioText || '暂无详细文字介绍') +
         '</div>' +
         (isLong ? '<button class=btn id=bBioToggle style="margin-top:10px">展开全部</button>' : '') +
         '</div>';

    // 2) 风格与相似（有则显示）
    if (stylesMats.length > 0) {
      h += '<div class="sec-card style-sec" style="margin-bottom:24px">' +
           '<div style="font-size:12px;font-weight:600;letter-spacing:1px;color:var(--mut2);margin-bottom:10px">风格与相似</div>' +
           '<div style="display:flex;gap:8px;flex-wrap:wrap">';
      stylesMats.forEach(function (sm) {
        h += '<span class=badge>' + esc(sm.title || sm.kind) + '</span>';
      });
      h += '</div></div>';
    }

    // 3) 来源：来源徽章、标题、取回日期、「复制链接」芯片（绝不 window.open / <a target=_blank>）
    h += '<div class="sec-card sources-sec" style="margin-bottom:24px">' +
         '<div style="font-size:12px;font-weight:600;letter-spacing:1px;color:var(--mut2);margin-bottom:12px">资料来源</div>' +
         '<div style="display:flex;flex-direction:column;gap:8px">';

    mats.forEach(function (m) {
      var srcName = '来源';
      if (m.source.indexOf('wikipedia') >= 0) srcName = '维基百科';
      else if (m.source.indexOf('moegirl') >= 0) srcName = '萌娘百科';
      else if (m.source.indexOf('discogs') >= 0) srcName = 'Discogs';
      else if (m.source.indexOf('lastfm') >= 0) srcName = 'Last.fm';
      else if (m.source) srcName = m.source;

      var fDate = fmtDate(m.fetched_at);
      h += '<div class="trow source-row" style="cursor:default;display:flex;align-items:center;gap:12px;padding:9px 14px;border-radius:9px;background:var(--hov)">' +
           '<span class=badge>' + esc(srcName) + '</span>' +
           '<span style="font-weight:600;font-size:12.5px;color:var(--txt)">' + esc(m.title) + '</span>' +
           '<span style="font-size:11.5px;color:var(--mut2);margin-right:auto">' + (fDate ? ('取回于 ' + fDate) : '') + '</span>' +
           citationChipHtml(m.url, '复制链接', false) +
           '</div>';
    });
    h += '</div></div>';
  }

  h += '</div>';
  D('list').innerHTML = h;

  // 绑定事件（261024-04 #5：与基础骨架共用 bindArtistButtons，两处不再各写一遍）
  bindArtistButtons(who);

  // 复制链接芯片：navigator.clipboard.writeText(url) + toast「已复制来源链接」
  bindCopyChips(D('list'));
}

/* ---------------- 古典作品与版本推荐（P3④b Discogs L4 / 261023-03 第4条） ---------------- */
function loadWorksView(initialTitle, initialComposer, fromNp) {
  S.view = 'works';
  S.worksFrom = fromNp ? 'np' : '';
  setView('works');
  S.view = 'works';
  // 用户 261023-04 #9：左导航不再有「古典作品」入口，作品页只从单曲页「作品」tab 进入；
  // 从单曲页进来时给一个明确的返回路径（回到正在播放页），不是无路可退。
  head('古典作品 · 演绎版本', '按作品名查不同指挥/乐团/年代的录音版本',
       (fromNp && S.lastCur) ? '<button class=btn id=wBackNp title="返回单曲播放页">← 返回正在播放</button>' : '');

  var defaultTitle = initialTitle || 'Boléro';
  var defaultComposer = (initialComposer !== undefined) ? initialComposer : 'Maurice Ravel';

  var h = '<div style="padding:10px 22px 30px">';

  // 首次进入顶部说明文案（261023-03 第4条）
  h += '<div style="font-size:12.5px;color:var(--mut2);margin-bottom:12px;line-height:1.6">' +
       '古典作品页：按「作品名 + 作曲家」检索 Discogs 上的不同录音版本（指挥 / 乐团 / 年代 / 厂牌），' +
       '帮你在同一首作品的不同演绎里挑到更对味的一张。可以自己填作品名查询，也可以直接点下方「示例作品」芯片一键检索。</div>';

  // 搜索卡片
  h += '<div class=card style="padding:16px 20px;margin-bottom:20px;background:var(--hov);border:1px solid var(--line);border-radius:10px">';
  h += '<div style="display:flex;gap:12px;flex-wrap:wrap;align-items:center">';
  h += '<div style="flex:1;min-width:200px"><label style="display:block;font-size:11.5px;color:var(--mut2);margin-bottom:4px">作品名称</label>' +
       '<input id=wTitle value="' + esc(defaultTitle) + '" placeholder="作品名称，例如 Boléro / Symphony No. 5" style="width:100%;height:32px;padding:0 10px;background:var(--card);border:1px solid var(--line);border-radius:6px;color:var(--txt);box-sizing:border-box"></div>';
  h += '<div style="flex:1;min-width:200px"><label style="display:block;font-size:11.5px;color:var(--mut2);margin-bottom:4px">作曲家（可选）</label>' +
       '<input id=wComposer value="' + esc(defaultComposer) + '" placeholder="作曲家，例如 Maurice Ravel / Beethoven" style="width:100%;height:32px;padding:0 10px;background:var(--card);border:1px solid var(--line);border-radius:6px;color:var(--txt);box-sizing:border-box"></div>';
  h += '<div style="align-self:flex-end">' +
       '<button class="btn pri" id=bSearchVersions style="height:32px;padding:0 16px">查询版本</button> ' +
       '<button class=btn id=bRefreshVersions style="height:32px;padding:0 12px" title="强制刷新">刷新</button>' +
       '</div>';
  h += '</div>';

  // 示例作品芯片（261023-03 第4条：点击直接检索）
  h += '<div style="display:flex;gap:8px;align-items:center;margin-top:12px;flex-wrap:wrap">' +
       '<span style="font-size:12px;color:var(--mut2)">示例作品：</span>' +
       '<button class="btn chip-work" data-title="Boléro" data-composer="Maurice Ravel" style="font-size:11.5px;padding:2px 8px" title="Maurice Ravel — Boléro">Boléro（拉威尔）</button>' +
       '<button class="btn chip-work" data-title="Symphony No. 5" data-composer="Ludwig van Beethoven" style="font-size:11.5px;padding:2px 8px" title="Ludwig van Beethoven — Symphony No. 5">贝多芬第五交响曲</button>' +
       '<button class="btn chip-work" data-title="Brandenburg Concerto No. 3" data-composer="Johann Sebastian Bach" style="font-size:11.5px;padding:2px 8px" title="J.S. Bach — Brandenburg Concerto No. 3">勃兰登堡协奏曲</button>' +
       '<button class="btn chip-work" data-title="The Four Seasons" data-composer="Antonio Vivaldi" style="font-size:11.5px;padding:2px 8px" title="Antonio Vivaldi — The Four Seasons">四季（维瓦尔第）</button>' +
       '<button class="btn chip-work" data-title="Symphony No. 5" data-composer="Gustav Mahler" style="font-size:11.5px;padding:2px 8px" title="Gustav Mahler — Symphony No. 5">马勒第五交响曲</button>' +
       '</div>';
  h += '</div>';

  // 结果呈现容器
  h += '<div id=worksResult></div>';
  h += '</div>';

  D('list').innerHTML = h;
  if (D('wBackNp')) D('wBackNp').onclick = function () { openNowPlaying(); };

  function doQuery(refresh) {
    var t = D('wTitle') ? D('wTitle').value.trim() : '';
    var c = D('wComposer') ? D('wComposer').value.trim() : '';
    if (!t) { toast('请输入作品名称'); return; }
    openWorkVersions(t, c, refresh);
  }

  if (D('bSearchVersions')) D('bSearchVersions').onclick = function () { doQuery(false); };
  if (D('bRefreshVersions')) D('bRefreshVersions').onclick = function () { doQuery(true); };
  if (D('wTitle')) {
    D('wTitle').onkeydown = function (ev) { if (ev.key === 'Enter') doQuery(false); };
  }
  if (D('wComposer')) {
    D('wComposer').onkeydown = function (ev) { if (ev.key === 'Enter') doQuery(false); };
  }

  Array.prototype.forEach.call(D('list').querySelectorAll('.chip-work'), function (btn) {
    btn.onclick = function () {
      var t = btn.dataset.title;
      var c = btn.dataset.composer;
      if (D('wTitle')) D('wTitle').value = t;
      if (D('wComposer')) D('wComposer').value = c;
      openWorkVersions(t, c, false);
    };
  });

  if (defaultTitle) {
    openWorkVersions(defaultTitle, defaultComposer, false);
  }
}

function openWorkVersions(workTitle, composer, refresh) {
  // 261023-03 第4条：切走后再点别的栏目时，异步回调必须能识别自己已经过期。
  // 两道保险：① S.view 守卫（离开 works 直接丢弃）；② 请求序号（同一视图内连点只认最后一次）。
  if (S.view !== 'works') return;
  var box = D('worksResult');
  if (!box) return;
  S.worksReq = (S.worksReq || 0) + 1;
  var req = S.worksReq;
  box.innerHTML = '<div class=empty style="padding:60px 0">正在从 Discogs 检索版本…</div>';

  var u = '/api/entity/versions?kind=work&name=' + encodeURIComponent(workTitle) +
          (composer ? ('&composer=' + encodeURIComponent(composer)) : '') +
          (refresh ? '&refresh=1' : '');

  // 2026-10-23（用户 261023-01 #4「切到作品栏后无法切回其它栏位」）真凶：
  // 这里没有「当前是否还在作品页」的判断。用户点了作品栏、Discogs 还没返回时切到专辑/曲目，
  // 回调仍把 #worksResult 的内容写回 → 看起来就是「卡在作品页/切不过去」。
  // 修法：回调先校验 S.view 与容器是否仍属于作品页，不满足就整段丢弃（不写 DOM、不报错）。
  var stillWorks = function () {
    return S.view === 'works' && !!D('worksResult');
  };
  api(u).then(function (j) {
    // 双守卫：视图已切走 → 丢弃；同一视图内连点 → 只认最后一次请求（S.worksReq 序号）
    if (!stillWorks() || req !== S.worksReq) return;
    renderWorkVersions(workTitle, composer, j);
  }).catch(function (err) {
    if (!stillWorks() || req !== S.worksReq) return;
    renderWorkVersions(workTitle, composer, { ok: false, errors: [String(err)], performances: [] });
  });
}

function renderWorkVersions(workTitle, composer, j) {
  if (S.view !== 'works') return;   // 261023-03 第4条：已离开作品页，丢弃过期结果
  var box = D('worksResult');
  if (!box) return;
  // 同 openWorkVersions 的守卫：视图已经切走就别再动 DOM（防「切不回去」的残留内容）
  if (S.view !== 'works') return;

  var perfs = (j && j.performances) || [];
  var isOk = j && j.ok && perfs.length > 0;

  var h = '';

  if (!isOk) {
    var errMsg = (j && j.errors && j.errors[0]) || (j && j.error) || '未在 Discogs 检索到该作品的演绎版本，或当前网络不可达。';
    h += '<div class="card empty-card" style="padding:36px 20px;text-align:center;background:var(--phbg);border:1px solid var(--line);border-radius:12px">' +
         '<div style="font-size:15px;font-weight:600;margin-bottom:8px;color:var(--txt)">未找到版本或检索失败</div>' +
         '<div style="color:var(--mut);font-size:12.5px;margin-bottom:18px;max-width:520px;margin-left:auto;margin-right:auto;line-height:1.6">' +
         esc(errMsg) + '</div>' +
         '<button class="btn pri" id=bRetryVersions>重试查询</button>' +
         '</div>';
    box.innerHTML = h;
    if (D('bRetryVersions')) {
      D('bRetryVersions').onclick = function () { openWorkVersions(workTitle, composer, true); };
    }
    return;
  }

  // 统计数值（不同演绎 X / 发行版本 Y）
  var distinctCount = (typeof j.distinctCount === 'number') ? j.distinctCount : ((typeof j.distinct_count === 'number') ? j.distinct_count : perfs.length);
  var releaseCount = (typeof j.releaseCount === 'number') ? j.releaseCount : ((typeof j.release_count === 'number') ? j.release_count : perfs.length);

  // 头部概要卡片
  var subStr = (composer ? ('作曲家: ' + esc(composer) + ' · ') : '') +
               (j.from_cache ? ('缓存 · ' + fmtDate(j.generated_at) + (j.offline ? ' · 离线' : '')) : 'Discogs 实时') +
               ' · 不同演绎 ' + distinctCount + ' / 发行版本 ' + releaseCount;
  h += '<div class="ahead work-head" style="margin-bottom:16px;padding:16px 20px;background:var(--hov);border-radius:10px">' +
       '<div class=kind style="font-size:11px;font-weight:600;letter-spacing:1px;color:var(--mut2)">CLASSICAL WORK · 古典作品</div>' +
       '<h1 style="margin:4px 0 6px;font-size:20px;font-weight:700;color:var(--txt)">' + esc(workTitle) + '</h1>' +
       '<div class=sub style="font-size:12px;color:var(--mut)">' + subStr + '</div>' +
       '</div>';

  // 不足 5 条演绎提示
  if (distinctCount < 5) {
    h += '<div class="card count-hint" style="padding:10px 14px;margin-bottom:14px;background:var(--phbg);border:1px solid var(--line);border-radius:8px;font-size:12px;color:var(--mut)">' +
         '不同演绎仅 ' + distinctCount + ' 个（目标 ≥5，未做臆造）' +
         '</div>';
  }

  // 版本列表 表头
  h += '<div class="trow trow-head" style="cursor:default;display:flex;align-items:center;gap:12px;padding:6px 16px;margin-bottom:4px;border-radius:6px;font-size:11px;font-weight:600;color:var(--mut2);text-transform:uppercase;letter-spacing:0.5px">' +
       '<span style="font-family:monospace;min-width:38px">年份</span>' +
       '<span style="flex:1.3;min-width:0">标题 / 发行</span>' +
       '<span style="flex:0.9;min-width:0">指挥</span>' +
       '<span style="flex:1.2;min-width:0">乐团</span>' +
       '<span style="flex:0.9;min-width:0">独奏</span>' +
       '<span style="min-width:75px">厂牌</span>' +
       '<span style="min-width:55px">格式</span>' +
       '<span style="min-width:80px;text-align:right">操作</span>' +
       '</div>';

  // 版本列表
  h += '<div class=version-list style="display:flex;flex-direction:column;gap:8px">';
  perfs.forEach(function (p) {
    var yr = p.year > 0 ? String(p.year) : '—';
    var conductorDisplay = p.conductor || '–';
    var ensembleDisplay = p.ensemble || p.orchestra || '–';
    var soloistsDisplay = (p.soloists && p.soloists.length > 0) ? p.soloists.join(', ') : '–';

    var badges = '';
    if (p.otherEditions && p.otherEditions > 0) {
      badges += '<span class=badge style="margin-left:6px;font-size:10px;background:var(--hov2);color:var(--mut)" title="同演绎其他发行 +' + p.otherEditions + ' 版">+' + p.otherEditions + ' 版</span>';
    }
    if (p.dedupUnknown) {
      badges += '<span class=badge style="margin-left:6px;font-size:10px;background:var(--phbg);border:1px dashed var(--line);color:var(--mut2)" title="演绎信息未明，未做去重合并">未明演绎</span>';
    }

    h += '<div class="trow version-row" style="cursor:default;display:flex;align-items:center;gap:12px;padding:10px 16px;border-radius:9px;background:var(--hov)">' +
         '<span style="font-family:monospace;font-size:12px;color:var(--mut);min-width:38px">' + yr + '</span>' +
         '<div style="flex:1.3;min-width:0">' +
           '<div style="display:flex;align-items:center">' +
             '<span style="font-weight:600;font-size:13px;color:var(--txt);overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + esc(p.title) + '">' + esc(p.title) + '</span>' +
             badges +
           '</div>' +
           '<div style="font-size:11px;color:var(--mut2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-top:2px" title="' + esc(p.performers || '—') + '">' + esc(p.performers || '—') + '</div>' +
         '</div>' +
         '<div style="flex:0.9;min-width:0;font-size:12px;color:var(--txt);overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + esc(conductorDisplay) + '">' + esc(conductorDisplay) + '</div>' +
         '<div style="flex:1.2;min-width:0;font-size:12px;color:var(--txt);overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + esc(ensembleDisplay) + '">' + esc(ensembleDisplay) + '</div>' +
         '<div style="flex:0.9;min-width:0;font-size:12px;color:var(--mut);overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + esc(soloistsDisplay) + '">' + esc(soloistsDisplay) + '</div>' +
         '<div style="font-size:11.5px;color:var(--mut);min-width:75px;max-width:110px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + esc(p.label || '—') + '">' + esc(p.label || '—') + '</div>' +
         '<span class=badge style="font-size:11px;min-width:45px;text-align:center">' + esc(p.format || 'CD') + '</span>' +
         '<button class="btn chip-copy" data-url="' + esc(p.url) + '" title="复制版本链接" style="margin-left:auto">' +
           '<svg width=12 height=12 viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-1px;margin-right:4px"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>' +
           '复制链接' +
         '</button>' +
         '</div>';
  });
  h += '</div>';

  box.innerHTML = h;

  Array.prototype.forEach.call(box.querySelectorAll('.chip-copy'), function (btn) {
    btn.onclick = function (ev) {
      ev.stopPropagation();
      var u = btn.dataset.url;
      if (!u) return;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(u).then(function () {
          toast('已复制来源链接');
        }).catch(function () {
          toast('已复制来源链接');
        });
      } else {
        toast('已复制来源链接');
      }
    };
  });
}
// 261025-01 #6：以前这里把「只显示 300」当成后端的天花板，前端一句话都不说 —— 用户搜一首歌，
// 明明库里有 1200 个命中，界面上只有 300 行，也没有任何「还有更多」的提示，看起来就是"丢歌"。
// 现在：① 后端支持 ?limit= 且回报 total（真实命中总数）；② 前端按 total 与已加载条数对比，
// 显示「共 N 条，当前显示前 M 条」并给「加载更多」（limit 翻倍）。
// 前端**不硬编码任何上限**：首屏不发 limit（用后端默认），翻倍时以"已加载条数 ×2"为准。
function loadTracks(q, moreLimit) {
  S.view = 'tracks';
  S.tracksQuery = q || '';
  // 评审：搜索结果页顶栏搜索框不回显当前关键词 → 这里同步（用户正在输入时值本来就相同，不会打断输入）
  if (D('q') && String(D('q').value) !== String(q || '')) D('q').value = q || '';
  // 缓存只管「曲目」整库视图；带搜索词的一律现取（用户主动查询，结果必须新鲜）。
  var ck = (q ? '' : 'tracks|');
  if (!moreLimit) {
    S.tracksLimit = 0;   // 新的查询/新的进入 → 上限归零，下次「加载更多」从"已加载条数"重新翻倍
    var hit = viewCacheGet(ck);
    if (hit) { S.currentTracks = hit.tracks || []; S.tracksTotal = hit.total; renderTracksView(); return; }
  }
  head(q ? ('搜索：' + q) : '曲目', '搜索中…', '');
  var u = '/api/lib/search?q=' + encodeURIComponent(q || '');
  if (moreLimit) u += '&limit=' + moreLimit;   // 只有「加载更多」才带 limit，首屏用后端默认
  api(u).then(function (j) {
    if (S.view !== 'tracks') return;   // 已切走（261023-01 #4 同类问题）→ 丢弃，别覆写当前页面
    if (j && j._err) { head(q ? ('搜索：' + q) : '曲目', '读取失败', ''); listErrorBox('曲目读取失败', function () { loadTracks(q, moreLimit); }); return; }
    var t = j.tracks || [];
    // total = 后端回报的真实命中总数。老后端没有这个字段时回退 j.n（= 本次返回条数），
    // 此时 total 必然等于已加载条数 ⟹ 不显示「加载更多」，而不是假装还有更多。
    var total = (typeof j.total === 'number') ? j.total : ((typeof j.n === 'number') ? j.n : t.length);
    S.currentTracks = t;
    S.tracksTotal = total;
    if (ck) viewCachePut(ck, { tracks: t, total: total });
    renderTracksView();
  }).catch(function () { listErrorBox('曲目读取失败', function () { loadTracks(q, moreLimit); }); });
}

// 「加载更多」：把上限翻倍重新请求。为什么是翻倍而不是 +300：
// 后端没有承诺固定页大小，翻倍对任意初始上限都成立，也不会出现"翻倍后仍不够、要连点十次"。
function loadMoreTracks() {
  var loaded = (S.currentTracks || []).length;
  var cur = S.tracksLimit || loaded || 1;
  S.tracksLimit = cur * 2;
  loadTracks(S.tracksQuery || '', S.tracksLimit);
}

function renderTracksView() {
  if (S.view !== 'tracks') return;
  var t = S.currentTracks || [];
  var q = S.tracksQuery || '';
  var total = (typeof S.tracksTotal === 'number' && S.tracksTotal >= t.length) ? S.tracksTotal : t.length;
  var hasMore = total > t.length;
  // 标题上的数字口径：还有没加载完的时候写成「M / N 首」，让"被截断"这件事在第一眼就成立，
  // 而不是等用户滚到底才发现少了一半（261025-01 #6）。
  head(q ? ('搜索：' + q) : '曲目', hasMore ? (t.length + ' / ' + total + ' 首') : (t.length + ' 首'), '');
  if (!t.length) {
    if (q) {
      var emptyH = '<div class=empty id=searchEmpty style="padding:48px 20px;text-align:center">' +
                   '<div style="font-size:15px;font-weight:600;margin-bottom:6px">未找到与 “' + esc(q) + '” 相关的曲目</div>' +
                   '<div style="color:var(--mut2);font-size:12px;margin-bottom:16px">请尝试缩短搜索词，或检查是否有错别字</div>' +
                   '<button class="btn" id=bSearchClear>清空搜索词</button></div>';
      D('list').innerHTML = emptyH;
      if (D('bSearchClear')) D('bSearchClear').onclick = function () {
        if (D('qClear')) D('qClear').click();
        else { D('q').value = ''; loadAlbums(''); }
      };
    } else {
      D('list').innerHTML = '<div class=empty>没有匹配的曲目</div>';
    }
    return;
  }

  var sortMode = S.trackSort || 'default';
  var sorted = t.slice();
  if (sortMode === 'title') {
    sorted.sort(function (a, b) { return (a.title || '').localeCompare(b.title || '', 'zh'); });
  } else if (sortMode === 'artist') {
    sorted.sort(function (a, b) { return (a.artist || '').localeCompare(b.artist || '', 'zh'); });
  } else if (sortMode === 'album') {
    sorted.sort(function (a, b) { return (a.album || '').localeCompare(b.album || '', 'zh'); });
  } else if (sortMode === 'dur') {
    sorted.sort(function (a, b) { return (a.dur || 0) - (b.dur || 0); });
  } else if (sortMode === 'year') {
    sorted.sort(function (a, b) { return (b.year || 0) - (a.year || 0); });
  } else if (sortMode === 'fav') {
    sorted.sort(function (a, b) {
      var fa = FAV_SET.has(a.path) ? 1 : 0;
      var fb = FAV_SET.has(b.path) ? 1 : 0;
      if (fa !== fb) return fb - fa; // 收藏优先排前面
      return (a.title || '').localeCompare(b.title || '', 'zh');
    });
  }

  // 排序控件放列表右上，紧凑（261023-03 第5条）
  var h = '<div style="display:flex;justify-content:flex-end;align-items:center;padding:10px 20px 4px;gap:8px">' +
          '<span style="font-size:12px;color:var(--mut2)">排序：</span>' +
          '<select id=trackSort class="track-sort sort-select">' +
          '<option value=default' + (sortMode === 'default' ? ' selected' : '') + '>默认排序</option>' +
          '<option value=title' + (sortMode === 'title' ? ' selected' : '') + '>标题</option>' +
          '<option value=artist' + (sortMode === 'artist' ? ' selected' : '') + '>艺术家</option>' +
          '<option value=album' + (sortMode === 'album' ? ' selected' : '') + '>专辑</option>' +
          '<option value=dur' + (sortMode === 'dur' ? ' selected' : '') + '>时长</option>' +
          '<option value=year' + (sortMode === 'year' ? ' selected' : '') + '>年份</option>' +
          '<option value=fav' + (sortMode === 'fav' ? ' selected' : '') + '>收藏优先</option>' +
          '</select></div>';

  h += '<div style="padding:4px 0 24px">';
  sorted.forEach(function (x, i) {
    var isFav = FAV_SET.has(x.path);
    // 2026-10-26（B-3 / 列表页）：同样加第 7 列「+」。以前这里**只有**右键能入队，
    // 页面没有任何视觉提示（用户根本不会去右键试）⟹ 等于没有入口。
    h += '<div class="trow trow-track" data-i=' + i + ' style="grid-template-columns:28px 24px minmax(120px,1.6fr) minmax(0,1fr) 92px 58px 26px;gap:8px">' +
         '<div class=n>' + (i + 1) + '</div>' +
         favIconHtml(x.path, isFav) +
         '<div class=tt title="' + esc(x.title) + '">' + esc(x.title) + '</div>' +
         '<div class=ar title="' + esc(x.artist + ' \u2014 ' + x.album) + '">' + esc(x.artist) + ' \u2014 ' + esc(x.album) + '</div>' +
         '<div class=bd>' + fmtTag(x.sr, x.bits) + '</div>' +
         '<div class=du>' + fmt(x.dur) + '</div>' +
         '<button class="add-btn" data-file="' + esc(x.path) + '" title="加入播放队列" aria-label="加入播放队列">+</button>' +
         '</div>';
  });
  h += '</div>';
  // 「共 N 条，当前显示前 M 条」+「加载更多」（261025-01 #6）。
  // 只在真的被截断时出现：没截断时不占任何垂直空间，避免每页都挂一条无意义的提示。
  if (hasMore) {
    h += '<div class=morebar style="display:flex;flex-direction:column;align-items:center;gap:8px;padding:8px 20px 32px">' +
         '<div style="font-size:12px;color:var(--mut2)">共 ' + total + ' 条，当前显示前 ' + t.length + ' 条</div>' +
         '<button class="btn pri" id=trMore>加载更多</button></div>';
  }
  D('list').innerHTML = h;

  if (D('trMore')) D('trMore').onclick = function () {
    D('trMore').disabled = true;
    D('trMore').textContent = '加载中…';
    loadMoreTracks();
  };

  if (D('trackSort')) {
    D('trackSort').onchange = function () {
      S.trackSort = this.value;
      renderTracksView();
    };
  }

  Array.prototype.forEach.call(D('list').querySelectorAll('.fav-btn'), function (btn) {
    btn.onclick = function (ev) {
      ev.stopPropagation();
      toggleFav(btn.dataset.file, ev);
    };
  });

  // 2026-10-26（B-3）：列表页「+」的 click 必须自己绑 + stopPropagation（否则冒泡成 playPath）
  Array.prototype.forEach.call(D('list').querySelectorAll('.add-btn'), function (btn) {
    btn.onclick = function (ev) {
      ev.stopPropagation();
      ev.preventDefault();
      var x = sorted[+btn.closest('.trow').dataset.i] || {};
      addPathCue(x.path, x.cs, x.ce);
    };
  });
  Array.prototype.forEach.call(D('list').querySelectorAll('.trow'), function (e) {
    e.onclick = function (ev) {
      if (ev.target.closest && ev.target.closest('.fav-btn')) return;
      if (ev.target.closest && ev.target.closest('.add-btn')) return;   // 「+」自己处理（双保险）
      playPath(sorted[+e.dataset.i].path);
    };
    e.oncontextmenu = function (ev) {
      ev.preventDefault();
      var x = sorted[+e.dataset.i] || {};
      trackActionMenu(x, ev.clientX, ev.clientY);
    };
  });
}

/* ---------------- 文件夹 ---------------- */
// 反馈 #4：「从库中移除」与「删除磁盘目录」是两件事，用户必须能分清。
// 本函数只负责**删磁盘**那一条，并且确认弹窗必须写明：将删除 N 个文件、路径原文、不可恢复。
// 数字来自 /api/lib/rmdirinfo（只统计不删除，与真删共用同一套安全判据），
// 拿不到数字时**不允许**继续 —— 宁可让用户重试，也不给他一个「不知道要删多少」的确认框。
function confirmRemoveDir(dir, onDone) {
  if (!dir) return;
  var busy = toast;   // 只是别名，保持行短
  busy('正在统计要删除的文件…');
  api('/api/lib/rmdirinfo', 'dir=' + encodeURIComponent(dir)).then(function (j) {
    if (!j || j.ok !== true) {
      // 后端拒绝（库外 / 库根本身 / 含软链 / 不存在）—— 把原因原样告诉用户，绝不吞掉
      toast((j && j.error) ? j.error : '无法统计该目录，已取消');
      return;
    }
    var nf = (typeof j.files === 'number') ? j.files : 0;
    var nd = (typeof j.dirs === 'number') ? j.dirs : 0;
    var h = '<div style="font-size:12.5px;line-height:1.85;color:var(--txt)">' +
            '<div style="margin-bottom:10px">即将<b style="color:var(--danger)">从磁盘永久删除</b>下面这个目录：</div>' +
            '<div style="font-family:ui-monospace,Consolas,monospace;font-size:11.5px;word-break:break-all;' +
                 'background:var(--phbg);border:1px solid var(--line);border-radius:7px;padding:9px 11px;margin-bottom:10px">' +
                 esc(dir) + '</div>' +
            '<div style="margin-bottom:10px">将删除 <b>' + nf + '</b> 个文件' +
                 (nd ? ('、<b>' + nd + '</b> 个子目录') : '') + '。</div>' +
            '<div style="color:var(--danger);font-weight:600;margin-bottom:4px">此操作不可恢复（不进废纸篓）。</div>' +
            '<div style="color:var(--mut);font-size:11.5px;margin-bottom:16px">' +
                 '只想让它不出现在曲库里？用设置里的「移除」即可，那个不碰磁盘。</div>' +
            '<div style="display:flex;gap:9px;justify-content:flex-end">' +
              '<button class=btn id=rmdCancel>取消</button>' +
              '<button class="btn pri" id=rmdGo style="background:var(--danger);border-color:var(--danger)">' +
                '删除 ' + nf + ' 个文件</button>' +
            '</div></div>';
    openModal('删除磁盘目录（不可恢复）', h);
    if (D('rmdCancel')) D('rmdCancel').onclick = function () { D('modal').classList.remove('on'); };
    if (D('rmdGo')) D('rmdGo').onclick = function () {
      D('rmdGo').disabled = true;
      D('rmdGo').textContent = '删除中…';
      api('/api/lib/rmdir', 'dir=' + encodeURIComponent(dir)).then(function (r) {
        D('modal').classList.remove('on');
        if (!r || r.ok !== true) { toast((r && r.error) ? r.error : '删除失败'); return; }
        var extra = (typeof r.removedTracks === 'number' && r.removedTracks > 0)
          ? ('，同时清掉 ' + r.removedTracks + ' 首索引记录') : '';
        toast('已删除 ' + (r.files || 0) + ' 个文件' + extra);
        libChanged();          // 曲库结构变了 → 视图缓存失效 + 轮询切扫描节奏
        loadLibStats();
        if (onDone) onDone();
      });
    };
  });
}

function loadFiles(d) {
  S.view = 'files';
  api('/api/files?dir=' + encodeURIComponent(d || '')).then(function (j) {
    // 与 loadTracks 同一类问题（261023-01 #4）：请求在路上时用户可能已经切走，
    // 迟到的响应不许覆写当前页面 —— 否则「文件夹」偶发空白/闪回别的页（本轮自检就踩到）。
    if (S.view !== 'files') return;
    if (!j.ok) { D('list').innerHTML = '<div class=empty>' + esc(j.error) + '</div>'; return; }
    S.dir = j.dir;
    head('文件夹', '', '');
    var rows = [];
    if (base(j.dir).length > 2) rows.push({ k: 'up', n: '返回上一级', m: '' });
    (j.dirs || []).forEach(function (n) { rows.push({ k: 'dir', n: n, m: '文件夹' }); });
    (j.files || []).forEach(function (n) { rows.push({ k: 'file', n: n, m: '' }); });
    S.files = rows;
    D('cnt').textContent = rows.filter(function (r) { return r.k !== 'up'; }).length + ' 项';

    // 地址栏：可以直接输入路径，也可以从音乐库根目录跳
    var roots = S.roots || [];
    var opts = '';
    roots.forEach(function (r) { opts += '<option value="' + esc(r) + '">' + esc(nam(r)) + '</option>'; });
    var h = '<div class=pathbar>' +
            '<button class=pb id=fUp title="上一级">\u2191</button>' +
            (opts ? '<select class=psel id=fRoot><option value="">音乐库…</option>' + opts + '</select>' : '') +
            '<input class=pin id=fPath value="' + esc(j.dir) + '" spellcheck=false placeholder="输入目录后回车，例如 ' + (SEP === '/' ? '/Users/你的用户名/Music' : 'D:\\Music') + '">' +
            '<button class=pb id=fGo title="转到">\u21b5</button></div>';
    h += '<div class=frows>';
    rows.forEach(function (r, i) {
      var isd = (r.k === 'dir' || r.k === 'up');
      var ic = (r.k === 'up') ? '\u2191' : (isd ? '\u{1F4C1}' : '\u266B');
      // 反馈 #4c：每个目录行给一个删除按钮（只对真目录，不含「返回上一级」与文件）。
      // 按钮上写清它是**删磁盘**，与「从库中移除」不是一回事。
      var delBtn = (r.k === 'dir')
        ? '<button class=fdel data-i=' + i + ' title="从磁盘删除此目录（不可恢复）">\u00d7</button>'
        : '';
      h += '<div class="row' + (isd ? ' rowdir' : '') + '" data-i=' + i + '>' +
           '<span class=ico>' + ic + '</span>' +
           '<span class="nm' + (isd ? ' dir' : '') + '">' + esc(r.n) + '</span>' +
           '<span class=meta>' + esc(r.m) + '</span>' + delBtn + '</div>';
    });
    h += '</div>';
    D('list').innerHTML = rows.length ? h : h + '<div class=empty>此目录没有音频文件</div>';

    D('fGo').onclick = function () {
      var v = (D('fPath').value || '').trim();
      if (v) loadFiles(v);
    };
    D('fPath').onkeydown = function (e) { if (e.key === 'Enter') D('fGo').click(); };
    if (D('fUp')) D('fUp').onclick = function () {
      var parts = base(S.dir).split(SEP); parts.pop();
      loadFiles(parts.join(SEP) + SEP);
    };
    if (D('fRoot')) D('fRoot').onchange = function () { if (this.value) loadFiles(this.value); };

    Array.prototype.forEach.call(D('list').querySelectorAll('.row'), function (e) {
      if (e.dataset.i === undefined) return;
      var r = S.files[+e.dataset.i];
      e.onclick = function (ev) {
        // 删除按钮自己处理点击，别让行点击把用户带进目录
        if (ev.target.closest && ev.target.closest('.fdel')) return;
        if (r.k === 'up') {
          var parts = base(S.dir).split(SEP); parts.pop();
          loadFiles(parts.join(SEP) + SEP);
        } else if (r.k === 'dir') loadFiles(join(S.dir, r.n) + SEP);
        else playPath(join(S.dir, r.n));
      };
      e.oncontextmenu = function (ev) { if (r.k === 'file') { ev.preventDefault(); addPath(join(S.dir, r.n)); } };
    });
    // 反馈 #4c：目录行的「删除磁盘目录」。走二次确认弹窗（写明文件数 / 路径原文 / 不可恢复），
    // 确认后才 POST /api/lib/rmdir；成功后刷新当前目录视图。
    Array.prototype.forEach.call(D('list').querySelectorAll('.fdel'), function (b) {
      b.onclick = function (ev) {
        ev.stopPropagation(); ev.preventDefault();
        var r = S.files[+b.dataset.i];
        if (!r || r.k !== 'dir') return;
        confirmRemoveDir(join(S.dir, r.n), function () { loadFiles(S.dir || ''); });
      };
    });
  }).catch(function (e) { D('list').innerHTML = '<div class=empty>' + esc(e) + '</div>'; });
}

/* ---------------- 最近播放 ---------------- */
function loadRecent() {
  S.view = 'recent';
  head('最近播放', '加载中…', '');
  api('/api/recent').then(function (j) {
    var it = j.items || [];
    head('最近播放', it.length + ' 首', '');
    if (!it.length) { D('list').innerHTML = '<div class=empty>还没有播放记录</div>'; return; }
    var h = '<div style="padding:6px 0 24px">';
    it.forEach(function (x, i) {
      h += '<div class="trow" data-i=' + i + ' style="grid-template-columns:34px 1fr 160px 92px">' +
           '<div class=n>' + (i + 1) + '</div>' +
           '<div class=tt title="' + esc(x.path) + '">' + esc(x.title || nam(x.path)) + '</div>' +
           '<div class=ar>' + esc(x.artist) + '</div>' +
           '<div class=du>' + esc(x.album) + '</div></div>';
    });
    D('list').innerHTML = h + '</div>';
    Array.prototype.forEach.call(D('list').querySelectorAll('.trow'), function (e) {
      e.onclick = function () { playPath(it[+e.dataset.i].path); };
      e.oncontextmenu = function (ev) { ev.preventDefault(); addPath(it[+e.dataset.i].path); };
    });
  }).catch(function () { D('list').innerHTML = '<div class=empty>读取失败</div>'; });
}

/* ---------------- 交互弹窗与辅助 ---------------- */
function askText(o) {
  o = o || {};
  var m = D('modal'); if (!m) return;
  D('mtitle').textContent = o.title || '输入';
  D('mbody').innerHTML =
    '<div style="padding:2px 0 14px"><input id=askIn style="width:100%;padding:9px 11px;border-radius:9px;' +
    'border:1px solid var(--line);background:var(--field);color:var(--txt);font-size:13px" value="' +
    esc(o.value || '') + '" placeholder="' + esc(o.placeholder || '') + '"></div>' +
    (o.hint ? '<div class=hint style="margin:-8px 0 12px">' + esc(o.hint) + '</div>' : '') +
    '<div style="display:flex;gap:8px;justify-content:flex-end">' +
    '<button class=btn id=askCancel>取消</button>' +
    '<button class="btn pri" id=askOk>' + esc(o.ok || '确定') + '</button></div>';
  m.classList.add('on');
  var inp = D('askIn');
  D('askOk').onclick = function () {
    var v = (D('askIn').value || '').trim();
    if (!v) { toast('名字不能为空'); return; }
    m.classList.remove('on');
    if (o.onOk) o.onOk(v);
  };
  D('askCancel').onclick = function () { m.classList.remove('on'); };
  if (inp) {
    inp.onkeydown = function (ev) {
      if (ev.key === 'Enter') { ev.preventDefault(); D('askOk').click(); }
      else if (ev.key === 'Escape') { ev.preventDefault(); D('askCancel').click(); }
    };
    setTimeout(function () { try { inp.focus(); inp.select(); } catch (e) {} }, 30);
  }
}

function askConfirm(o) {
  o = o || {};
  var m = D('modal'); if (!m) return;
  D('mtitle').textContent = o.title || '确认';
  D('mbody').innerHTML =
    '<div style="padding:2px 0 16px;font-size:12.5px;line-height:1.7;color:var(--txt2)">' + esc(o.text || '') + '</div>' +
    '<div style="display:flex;gap:8px;justify-content:flex-end">' +
    '<button class=btn id=cfNo>取消</button>' +
    '<button class="btn pri" id=cfYes>' + esc(o.ok || '确定') + '</button></div>';
  m.classList.add('on');
  D('cfNo').onclick = function () { m.classList.remove('on'); };
  D('cfYes').onclick = function () { m.classList.remove('on'); if (o.onOk) o.onOk(); };
}

function folderOf(p) {
  var s = String(p || '');
  var i = Math.max(s.lastIndexOf(String.fromCharCode(92)), s.lastIndexOf('/'));
  if (i <= 0) return '';
  var head = s.slice(0, i);
  var j = Math.max(head.lastIndexOf(String.fromCharCode(92)), head.lastIndexOf('/'));
  return head.slice(j + 1);
}

/* ---------------- 整列起播（Q-5：收藏 / 歌单 / 队列整列起播共用） ---------------- */
function ensureSequentialMode(cb) {
  var cur = parseInt(D('sRep') ? D('sRep').value : 0, 10) || 0;
  if (cur !== 2) { cb(); return; }
  D('sRep').value = '1';
  api('/api/playmode?mode=1').then(function () { applyRep(1); cb(); }).catch(function () { cb(); });
}
function playWholeListFrom(files, start, label) {
  files = (files || []).filter(function (f) { return !!f; });
  if (!files.length) { toast('这个列表是空的'); return; }
  var i = parseInt(start, 10) || 0;
  if (i < 0) i = 0;
  if (i > files.length - 1) i = files.length - 1;
  ensureSequentialMode(function () {
    api('/api/queue/set', 'files=' + encodeURIComponent(files.join(String.fromCharCode(10)))).then(function (j) {
      if (!j || j.ok === false) { toast((j && j.error) || '建立队列失败'); return; }
      playPath(files[i]);
      toast('从第 ' + (i + 1) + ' 首开始顺序播放' + (label ? ('：' + label) : '') + '（共 ' + files.length + ' 首）');
      if (S.view === 'queue') renderQueuePage();
    }).catch(function (e) { toast('播放失败: ' + e); });
  });
}
function playWholeList(files, label) { playWholeListFrom(files, 0, label); }

/* ---------------- 我的最爱（Q-6） ---------------- */
function loadFavs() {
  S.view = 'favs';
  head('我的最爱', '加载中…', '');
  api('/api/fav/list?meta=1').then(function (j) {
    if (S.view !== 'favs') return;
    var raw = (j && j.files) || [];
    S.favs = raw.map(function (x) { return (typeof x === 'string') ? { file: x } : x; });
    FAV_SET = new Set(S.favs.map(function (x) { return x.file; }));
    var n = S.favs.length;
    head('我的最爱', n ? (n + ' 首') : '', '');
    if (!n) {
      D('list').innerHTML = '<div class=empty>还没有收藏<br><span style="font-size:11.5px">在曲目行或单曲页点心形，就会出现在这里</span></div>';
      return;
    }
    var h = '<div class=favhint><b>双击</b>任意一首，从这首开始<b>顺序播放</b>整个最爱列表（' + n + ' 首）</div>';
    h += '<div class=favhead style="grid-template-columns:34px 1fr 180px 200px 34px">' +
         '<div class=n>#</div><div>标题</div><div>艺术家</div><div class=du>专辑</div><div></div></div>';
    h += '<div style="padding:2px 0 6px">';
    S.favs.forEach(function (x, i) {
      var f = x.file || '';
      var t = x.title || nam(f);
      var ar = x.artist || '';
      var al = x.album || folderOf(f);
      h += '<div class="trow favrow" data-i=' + i + ' style="grid-template-columns:34px 1fr 180px 200px 34px">' +
           '<div class=n>' + (i + 1) + '</div>' +
           '<div class=tt title="' + esc(f) + '">' + esc(t) + '</div>' +
           '<div class=ar title="' + esc(ar) + '">' + esc(ar) + '</div>' +
           '<div class=du title="' + esc(al) + '" style="text-align:left;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(al) + '</div>' +
           '<div style="display:flex;justify-content:flex-end">' + favIconHtml(f, true) + '</div></div>';
    });
    h += '</div>';
    D('list').innerHTML = h;
    Array.prototype.forEach.call(D('list').querySelectorAll('.favrow'), function (e) {
      var i = +e.dataset.i, x = S.favs[i]; if (!x) return;
      e.onclick = function (ev) {
        if (ev.target.closest && ev.target.closest('.fav-btn')) return;
        Array.prototype.forEach.call(D('list').querySelectorAll('.favrow'), function (y) {
          y.classList.toggle('fsel', y === e);
        });
      };
      e.ondblclick = function (ev) {
        if (ev.target.closest && ev.target.closest('.fav-btn')) return;
        playWholeListFrom((S.favs || []).map(function (y) { return y.file; }), i, '我的最爱');
      };
      e.oncontextmenu = function (ev) { ev.preventDefault(); if (typeof showTrackMenu === 'function') showTrackMenu(ev.clientX, ev.clientY, { path: x.file }); };
      var b = e.querySelector('.fav-btn');
      if (b) b.onclick = function (ev) { unfavFromFavs(x.file, ev); };
    });
  }).catch(function (e) { D('list').innerHTML = '<div class=empty>读取收藏失败: ' + esc(e) + '</div>'; });
}
function unfavFromFavs(file, ev) {
  if (ev) { ev.stopPropagation(); ev.preventDefault(); }
  api('/api/fav?file=' + encodeURIComponent(file) + '&on=0').then(function (j) {
    if (!j || !j.ok) { toast((j && j.error) || '取消收藏失败'); return; }
    FAV_SET.delete(file);
    toast('已取消收藏');
    if (S.view === 'favs') loadFavs();
  }).catch(function (e) { toast('取消收藏失败: ' + e); });
}

/* ---------------- 我的歌单（Q-7 具名保存队列） ---------------- */
function renderSavedQueues() {
  api('/api/sq/list').then(function (j) {
    S.sqs = (j && j.queues) || [];
    paintSavedQueues();
  }).catch(function () {});
}
function paintSavedQueues() {
  var box = D('sqList'); if (!box) return;
  var h = '<div class=sqhd><span>我的歌单</span><button class=sqnew-btn id=sqNew title="新建空歌单">＋ 新建</button></div>';
  if (!S.sqs || !S.sqs.length) {
    h += '<div class=sqempty>点击右上角「＋ 新建」创建歌单</div>';
  } else {
    S.sqs.forEach(function (q, i) {
      h += '<div class="nav sqrow' + (S.view === 'sq' && S.sqName === q.name ? ' on' : '') + '" data-v=sq data-sq="' + esc(q.name) + '" data-i=' + i + '>' +
           '<span class=sqn title="' + esc(q.name) + '">' + esc(q.name) + '</span>' +
           '<span class="sqb ren" title="重命名">✎</span>' +
           '<span class="sqb del" title="删除">×</span></div>';
    });
  }
  box.innerHTML = h;
  if (D('sqNew')) D('sqNew').onclick = function (ev) {
    ev.stopPropagation();
    newSavedQueueDialog();
  };
  Array.prototype.forEach.call(box.querySelectorAll('.sqrow'), function (e) {
    var q = S.sqs[+e.dataset.i]; if (!q) return;
    e.onclick = function (ev) {
      if (ev.target.classList.contains('sqb')) return;
      renderSavedQueuePage(q.name);
    };
    var r1 = e.querySelector('.ren'); if (r1) r1.onclick = function (ev) { ev.stopPropagation(); renameQueueDialog(q.name); };
    var r2 = e.querySelector('.del'); if (r2) r2.onclick = function (ev) { ev.stopPropagation(); deleteSavedQueue(q.name); };
  });
}
function renderSavedQueuePage(name) {
  if (!name) return;
  S.view = 'sq'; S.sqName = name;
  head(name, '加载中…', '');
  api('/api/sq/info?name=' + encodeURIComponent(name)).then(function (j) {
    if (S.view !== 'sq' || S.sqName !== name) return;
    if (!j || !j.ok) {
      head(name, '', '');
      D('list').innerHTML = '<div class=empty>歌单不存在（可能已被删除）</div>';
      return;
    }
    var it = j.items || [];
    S.sqItems = it;
    head(name, it.length + ' 首',
      '<button class="btn pri" id=sqPlayAll>▶ 播放整列</button>' +
      '<button class=btn id=sqRen>重命名</button>' +
      '<button class=btn id=sqDel>删除</button>');
    Array.prototype.forEach.call(document.querySelectorAll('.sqlist .sqrow'), function (e) {
      e.classList.toggle('on', e.dataset.sq === name);
    });
    if (!it.length) { D('list').innerHTML = '<div class=empty>这个歌单是空的</div>'; return; }
    var h = '<div style="padding:6px 0 24px">';
    it.forEach(function (x, i) {
      h += '<div class="trow sqtrow" data-i=' + i + ' style="grid-template-columns:34px 1fr 240px">' +
           '<div class=n>' + (i + 1) + '</div>' +
           '<div class=tt title="' + esc(x.file) + '">' + esc(nam(x.file)) + '</div>' +
           '<div class=ar style="text-align:left;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(folderOf(x.file)) + '</div></div>';
    });
    D('list').innerHTML = h + '</div>';
    if (D('sqPlayAll')) D('sqPlayAll').onclick = function () { playSavedQueue(name, 0); };
    if (D('sqRen')) D('sqRen').onclick = function () { renameQueueDialog(name); };
    if (D('sqDel')) D('sqDel').onclick = function () { deleteSavedQueue(name); };
    Array.prototype.forEach.call(D('list').querySelectorAll('.sqtrow'), function (e) {
      var i = +e.dataset.i;
      e.onclick = function () { playSavedQueue(name, i); };
    });
  }).catch(function (e) { D('list').innerHTML = '<div class=empty>读取歌单失败: ' + esc(e) + '</div>'; });
}
function playSavedQueue(name, i) {
  i = i || 0;
  ensureSequentialMode(function () {
    api('/api/sq/play?name=' + encodeURIComponent(name) + '&i=' + i).then(function (j) {
      if (!j || !j.ok) { toast((j && j.error) || '载入失败'); return; }
      api('/api/sq/info?name=' + encodeURIComponent(name)).then(function (info) {
        var it = (info && info.items) || [];
        var k = Math.min(Math.max(0, i), Math.max(0, it.length - 1));
        if (it[k]) playPath(it[k].file, it[k].cs, it[k].ce);
        toast('播放歌单：' + name + '（' + it.length + ' 首）');
        loadQ();
      });
    }).catch(function (e) { toast('播放失败: ' + e); });
  });
}
function newSavedQueueDialog() {
  askText({ title: '新建歌单', ok: '创建', value: '',
    placeholder: '例如 睡眠专区',
    hint: '创建一份空歌单；可通过右键歌曲或单曲页「添加到歌单」加歌',
    onOk: function (name) {
      api('/api/sq/add?name=' + encodeURIComponent(name)).then(function (j) {
        if (!j || !j.ok) { toast((j && j.error) || '创建失败'); return; }
        toast('已新建歌单：' + j.name);
        renderSavedQueues();
        renderSavedQueuePage(j.name);
      }).catch(function (e) { toast('创建失败: ' + e); });
    } });
}
function pickSavedQueue(title, cb) {
  api('/api/sq/list').then(function (j) {
    var sqs = (j && j.queues) || [];
    var h = '<div class=castpick style="max-height:360px;overflow-y:auto">';
    if (!sqs.length) {
      h += '<div class=hint style="padding:12px 4px">还没有歌单，可直接在上方新建</div>';
    } else {
      sqs.forEach(function (q, i) {
        h += '<button class="castpick-row sqpick-item" data-i=' + i + ' style="padding:8px 12px">' +
             '<span class=cpn>' + esc(q.name) + '</span>' +
             '<span class=cph>' + q.n + ' 首曲目</span></button>';
      });
    }
    h += '</div>' +
         '<div style="margin-top:14px;padding-top:10px;border-top:1px solid var(--line);display:flex;justify-content:space-between;align-items:center">' +
         '<button class="btn sec" id=pickNewSq>＋ 新建歌单…</button>' +
         '<button class=btn id=pickCancelSq>取消</button></div>';
    openModal(title || '选择目标歌单', h);
    Array.prototype.forEach.call(D('mbody').querySelectorAll('.castpick-row'), function (b) {
      b.onclick = function () {
        var q = sqs[+b.dataset.i];
        if (D('modal')) D('modal').classList.remove('on');
        if (q && cb) cb(q.name);
      };
    });
    if (D('pickCancelSq')) D('pickCancelSq').onclick = function () {
      if (D('modal')) D('modal').classList.remove('on');
    };
    if (D('pickNewSq')) D('pickNewSq').onclick = function () {
      if (D('modal')) D('modal').classList.remove('on');
      askText({ title: '新建歌单', ok: '创建并选入', value: '',
        placeholder: '例如 我的最爱',
        onOk: function (name) {
          api('/api/sq/add?name=' + encodeURIComponent(name)).then(function (res) {
            if (!res || !res.ok) { toast((res && res.error) || '创建失败'); return; }
            renderSavedQueues();
            if (cb) cb(res.name);
          }).catch(function (e) { toast('创建失败: ' + e); });
        } });
    };
  }).catch(function (e) { toast('读取歌单列表失败: ' + e); });
}
function addToSavedQueue(file, cs, ce) {
  if (!file) { toast('没有指定要添加的曲目'); return; }
  pickSavedQueue('保存到歌单', function (sqName) {
    if (!sqName) return;
    var u = '/api/sq/add?name=' + encodeURIComponent(sqName) +
            '&file=' + encodeURIComponent(file);
    if (cs !== undefined && cs >= 0) u += '&cs=' + encodeURIComponent(cs);
    if (ce !== undefined && ce >= 0) u += '&ce=' + encodeURIComponent(ce);
    api(u).then(function (j) {
      if (!j) { toast('添加失败'); return; }
      if (!j.ok) {
        if (j.duplicate) toast('已在歌单中');
        else toast(j.error || '添加失败');
        return;
      }
      toast('已加入歌单「' + sqName + '」（共 ' + j.count + ' 首）');
      renderSavedQueues();
      if (S.view === 'sq' && S.sqName === sqName) renderSavedQueuePage(sqName);
    }).catch(function (e) { toast('添加失败: ' + e); });
  });
}
function saveQueueDialog() {
  var n = (S.q && S.q.items) ? S.q.items.length : 0;
  if (!n) { toast('队列是空的，先加几首歌再保存'); return; }
  askText({ title: '保存为歌单', ok: '保存', value: S.sqName || '',
    placeholder: '例如 夜深人静',
    hint: '把现在这 ' + n + ' 首（含顺序与 CUE 区间）存成一个歌单；写入 rlplayer-savedqueues.conf，重启后仍在',
    onOk: function (name) {
      api('/api/sq/save?name=' + encodeURIComponent(name)).then(function (j) {
        if (!j || !j.ok) { toast((j && j.error) || '保存失败'); return; }
        toast('已存为歌单：' + j.name + '（' + j.count + ' 首）');
        renderSavedQueues();
        if (S.view === 'favs') loadFavs();
        else if (S.view === 'sq') renderSavedQueuePage(j.name);
      }).catch(function (e) { toast('保存失败: ' + e); });
    } });
}
function renameQueueDialog(name) {
  askText({ title: '重命名歌单', ok: '改名', value: name,
    hint: '改名后立刻写入 rlplayer-savedqueues.conf（重启后是新名字）',
    onOk: function (to) {
      api('/api/sq/rename?from=' + encodeURIComponent(name) + '&to=' + encodeURIComponent(to)).then(function (j) {
        if (!j || !j.ok) { toast((j && j.error) || '改名失败'); return; }
        toast('已改名为：' + j.to);
        if (S.sqName === name) S.sqName = j.to;
        renderSavedQueues();
        if (S.view === 'sq') renderSavedQueuePage(j.to);
        else if (S.view === 'favs') loadFavs();
      }).catch(function (e) { toast('改名失败: ' + e); });
    } });
}
function deleteSavedQueue(name) {
  askConfirm({ title: '删除歌单', ok: '删除',
    text: '删除歌单「' + name + '」？只删这份歌单，不动当前播放队列。',
    onOk: function () {
      api('/api/sq/delete?name=' + encodeURIComponent(name)).then(function (j) {
        if (!j || !j.ok) { toast((j && j.error) || '删除失败'); return; }
        toast('已删除：' + name);
        if (S.sqName === name) S.sqName = '';
        renderSavedQueues();
        if (S.view === 'sq') { setView('favs'); loadFavs(); }
        else if (S.view === 'favs') loadFavs();
      }).catch(function (e) { toast('删除失败: ' + e); });
    } });
}

/* ---------------- 播放控制 ---------------- */
/* CUE 分轨（2026-10-25）：cue 把整轨切成 N 首，这 N 首的 path 完全相同，
   只有 cue_start/cue_end（秒）能区分。cs < 0 = 整首（旧行为，负向对照就走这条）。
   为什么不传"时长"：播放侧需要的是起点，只给时长等于少一半信息。 */
function cueQuery(cs, ce) {
  if (!(cs >= 0)) return '';
  return '&cue_start=' + encodeURIComponent(cs) +
         (ce >= 0 ? ('&cue_end=' + encodeURIComponent(ce)) : '');
}
function playPath(f, cs, ce) {
  S.lastCur = f;
  api('/api/play', 'file=' + encodeURIComponent(f) + cueQuery(cs, ce) + '&' + params()).then(function (j) {
    if (j && j.ok === false) { toast(j.error || '播放失败'); return; }
    toast('开始播放'); loadQ();
  });
}
function addPath(f) {
  api('/api/add', 'file=' + encodeURIComponent(f)).then(function () { toast('已加入队列'); loadQ(); });
}
/* 2026-10-26（B-3）：带 CUE 区间的入队。
   为什么不能直接用 addPath：CUE 分轨时**同一整轨文件里的 N 首 path 完全相同**，
   只传 path ⟹ 点「第 3 首」入队的其实是"整轨"（用户看到的是第 1 首的区间）。
   /api/add 目前只接受 file（后端 PlayParams 有 cueStart/cueEnd，但 /api/add 分支未读取），
   所以这里把区间一并送出去：后端将来接线即生效；当前对普通曲目 cs/ce = -1，行为与 addPath 完全一致。
   ⚠️ 已如实挂账：/api/add 尚未消费 cue_start/cue_end，CUE 分轨的单曲入队仍会入整轨（见交付说明）。 */
function addPathCue(f, cs, ce) {
  if (!f) return;
  api('/api/add', 'file=' + encodeURIComponent(f) + cueQuery(cs, ce)).then(function (j) {
    if (j && j.ok === false) { toast(j.error || '加入失败'); return; }
    toast('已加入队列'); loadQ();
  }).catch(function (e) { toast('加入失败: ' + e); });
}
function playRemote(it) {
  api('/api/play', 'rid=' + encodeURIComponent(it.id) + '&rsuffix=' + encodeURIComponent(it.sf || '') + '&' + params())
    .then(function (j) { if (!j.ok) toast(j.error || '播放失败'); else loadQ(); });
}

/* ---------------- 队列 ---------------- */
function loadQ() {
  // return 出去：pollSchedule 靠它做 in-flight 互斥（上一发没回来就跳过这一拍）。
  return api('/api/queue').then(function (j) {
    // 兜底对象没有 items/index：原地不动，保住上一次真实队列（清空队列 = 用户看得见的"数据消失"）。
    if (j && j._err) return;
    // cues 与 items 逐项对齐的 [起,止] 秒数组（后端 /api/queue；[-1,-1] = 整首）
    S.q = { items: j.items || [], cues: j.cues || [], index: j.index || 0 };
    if (D('sShuf')) D('sShuf').checked = !!j.shuffle;
    // mode is authoritative; repeat=0 is only the legacy projection of random.
    var mode = (typeof j.mode === 'number') ? j.mode : (j.shuffle ? 3 : (j.repeat || 0));
    if (D('sRep')) { D('sRep').value = String(mode); applyRep(mode); }
    D('rcnt').textContent = '共 ' + S.q.items.length + ' 首';
    updateNextTrackInfo();
    if (!S.q.items.length) {
      D('qlist').innerHTML = '<div class=empty style="padding:26px 14px">队列为空<br><span style="font-size:11px">右键专辑或曲目可加入</span></div>';
      return;
    }
    var h = '';
    S.q.items.forEach(function (f, i) {
      h += '<div class="qi' + (i === S.q.index ? ' on' : '') + '" data-i=' + i + ' draggable=true>' +
           '<span class=n>' + (i + 1) + '</span><span class=t title="' + esc(f) + '">' + esc(nam(f)) + '</span>' +
           '<button class=qdel data-i=' + i + ' title="从队列移除">×</button></div>';
    });
    D('qlist').innerHTML = h;
    Array.prototype.forEach.call(D('qlist').children, function (e) {
      if (e.dataset.i === undefined) return;
      var i = +e.dataset.i;
      e.onclick = function (ev) {
        if (ev.target.classList.contains('qdel')) return;
        var c = (S.q.cues || [])[i] || [-1, -1];
        playPath(S.q.items[i], c[0], c[1]);
      };
      var d = e.querySelector('.qdel');
      if (d) d.onclick = function (ev) {
        ev.stopPropagation();
        api('/api/qdel?i=' + i, '').then(function () { toast('已移除'); loadQ(); });
      };
      // 反馈 #9「右击丢行」的真身就在这里：旧实现右击**立刻** /api/qdel 把这一行从队列删掉。
      // 用户只是想看看右键能干什么，行就从界面上消失了（无确认、无撤销，和"加入队列"完全相反）。
      // 现在：右击**只弹菜单**，删除必须在菜单里显式再点一次。
      e.oncontextmenu = function (ev) {
        ev.preventDefault();
        ev.stopPropagation();
        showQueueRowMenu(e.dataset.i, ev);
      };
      e.ondragstart = function (ev) { ev.dataTransfer.setData('text/plain', e.dataset.i); };
      e.ondragover = function (ev) { ev.preventDefault(); };
      e.ondrop = function (ev) {                  // 拖动排序
        ev.preventDefault();
        var from = parseInt(ev.dataTransfer.getData('text/plain'), 10);
        var to = parseInt(e.dataset.i, 10);
        if (isNaN(from) || isNaN(to) || from === to) return;
        api('/api/qmove?from=' + from + '&to=' + to, '').then(loadQ);
      };
    });
  }).catch(function () { });
}

/* ---------------- 右键菜单（反馈 #9）----------------
   背景：右击丢行有两个来源，都是「右击直接执行破坏性动作」：
     ① 右侧队列抽屉 #qlist 的 .qi：右击立刻 qdel，行当场消失（**已实测复现：5 行 → 4 行**）；
     ② 队列页 .qrow / 曲目行没有可用的右键菜单，浏览器原生菜单弹出来盖住行，
        用户以为行没了（数据其实还在，是观感丢行）。
   本轮规则：右击**永不**直接改数据；破坏性动作必须经过菜单里的显式第二次点击。
   菜单要能被 Esc / 点空白 / 滚动关掉，且关掉时不重排列表（重排会让用户失去位置）。 */
var QMENU = { el: null, i: -1 };
function closeQueueRowMenu() {
  if (QMENU.el && QMENU.el.parentNode) QMENU.el.parentNode.removeChild(QMENU.el);
  QMENU.el = null; QMENU.i = -1;
}
function showQueueRowMenu(i, ev) {
  closeQueueRowMenu();
  var items = (S.q && S.q.items) || [];
  var f = items[+i];
  if (f === undefined) return;
  QMENU.i = +i;
  var box = document.createElement('div');
  box.className = 'qmenu';
  box.style.left = Math.max(4, Math.min((ev && ev.clientX) || 0, (window.innerWidth || 800) - 230)) + 'px';
  box.style.top  = Math.max(4, Math.min((ev && ev.clientY) || 0, (window.innerHeight || 600) - 96)) + 'px';
  box.innerHTML =
    '<div class=qmt title="' + esc(f) + '">' + esc(nam(f)) + '</div>' +
    '<button class=qm data-a=play>播放这首</button>' +
    '<button class=qm data-a=addsq>保存到歌单…</button>' +
    '<button class=qm data-a=del>从队列移除</button>';
  document.body.appendChild(box);
  QMENU.el = box;
  Array.prototype.forEach.call(box.querySelectorAll('.qm'), function (b) {
    b.onclick = function (ev2) {
      ev2.stopPropagation();
      var a = b.dataset.a;
      var idx = QMENU.i;
      closeQueueRowMenu();
      if (a === 'play') {
        var c = (S.q.cues || [])[idx] || [-1, -1];
        playPath(items[idx], c[0], c[1]);
        return;
      }
      if (a === 'addsq') {
        var c2 = (S.q.cues || [])[idx] || [-1, -1];
        addToSavedQueue(items[idx], c2[0], c2[1]);
        return;
      }
      // 移除：只有走到这里才真的改数据（右击本身不会）
      api('/api/qdel?i=' + idx, '').then(function () {
        toast('已从队列移除');
        loadQ();
        if (S.view === 'queue') renderQueuePage();
      });
    };
  });
}
// 菜单关闭：点空白 / Esc / 滚动。全部走 closeQueueRowMenu（幂等）。
document.addEventListener('mousedown', function (ev) {
  if (!QMENU.el) return;
  if (QMENU.el.contains && QMENU.el.contains(ev.target)) return;
  closeQueueRowMenu();
}, true);
document.addEventListener('keydown', function (ev) {
  if (ev.key === 'Escape' && QMENU.el) closeQueueRowMenu();
});
window.addEventListener('scroll', function () { if (QMENU.el) closeQueueRowMenu(); }, true);

function syncAlbPlayAllBtn() {
  var b = D('albPlayAll');
  if (!b || S.view !== 'album' || !S.album) return;
  var alb = S.album;
  var playing = (S.playing || S.paused) && S.lastCur && (alb.tracks || []).some(function (t) { return t.path === S.lastCur; });
  if (playing) {
    if (S.playing && !S.paused) {
      b.textContent = '❚❚ 暂停';
      b.title = '暂停播放';
    } else {
      b.textContent = '▶ 继续播放';
      b.title = '继续播放专辑';
    }
  } else {
    b.textContent = '▶ 播放整张';
    b.title = '播放整张专辑';
  }
}

function updateNextTrackInfo() {
  var el = D('npNextTrack');
  var heroEl = D('npNextTrackHero');
  var tqBadge = D('tqBadge');
  var qLen = (S.q && S.q.items) ? S.q.items.length : 0;
  if (tqBadge) {
    if (qLen > 0) {
      tqBadge.textContent = qLen;
      tqBadge.style.display = '';
    } else {
      tqBadge.style.display = 'none';
    }
  }
  if (!S.playing || !qLen) {
    if (el) el.style.display = 'none';
    if (heroEl) heroEl.style.display = 'none';
    return;
  }
  var curIdx = (S.q.index !== undefined ? S.q.index : -1);
  if (curIdx < 0 && S.lastCur) {
    curIdx = S.q.items.indexOf(S.lastCur);
  }
  var repMode = (D('sRep') && D('sRep').value) || '0';
  var nextIdx = curIdx + 1;
  var hasNext = true;
  if (nextIdx >= qLen) {
    if (repMode === '1') {
      nextIdx = 0;
    } else {
      hasNext = false;
    }
  }
  var remain = Math.max(0, qLen - 1 - (curIdx >= 0 ? curIdx : 0));
  var text = '';
  var tip = '';
  if (hasNext && qLen > 0) {
    var nextPath = S.q.items[nextIdx] || '';
    var nextTitle = nam(nextPath);
    text = '下一首: ' + nextTitle + (remain > 0 ? (' · 剩 ' + remain + ' 首') : '');
    tip = '下一首：' + nextTitle + '（队列共 ' + qLen + ' 首，剩余 ' + remain + ' 首）';
  } else {
    text = '队列末尾' + (qLen > 0 ? (' · 共 ' + qLen + ' 首') : '');
    tip = '当前已是队列最后一首（共 ' + qLen + ' 首）';
  }
  if (el) {
    el.textContent = text;
    el.title = tip;
    el.style.display = '';
  }
  if (heroEl) {
    heroEl.textContent = text;
    heroEl.title = tip;
    heroEl.style.display = '';
  }
}

/* ---------------- 元数据 / 封面 ---------------- */
// 正在播放整页的补全信息芯片（底栏不加，避免拥挤）。
// enriched=false 或无 meta → 返回空串（容器清空）；值芯片带「来源」提示，来自 meta.sources 溯源表。
function buildNpMetaHtml(m) {
  var mt = m && m.meta;
  if (!mt || mt.enriched !== true) return '';
  var src = mt.sources || {};
  var chips = '';
  [['year', '年份'], ['genre', '流派'], ['albumArtist', '专辑艺术家']].forEach(function (p) {
    var v = m[p[0]];
    if (!v) return;
    chips += '<span class=badge title="' + esc('来源: ' + (src[p[0]] || '本地标签')) + '">' +
             esc(p[1] + '  ' + v) + '</span>';
  });
  chips += '<span class="badge g" title="标签/封面/歌词已由在线来源补全，可在设置-元数据补全关闭">已补全</span>';
  return chips;
}
function loadMeta(f) {
  if (!f) return;
  api('/api/meta?file=' + encodeURIComponent(f)).then(function (m) {
    S.curMeta = m;
    if (m.title) D('npt').textContent = m.title;
    else D('npt').textContent = nam(f);
    var sub = [];
    if (m.artist) sub.push(m.artist);
    if (m.album) sub.push(m.album);
    D('npart').textContent = sub.join(' \u00b7 ');
    D('cv').style.backgroundImage = m.hasCover ? "url('/api/cover?file=" + encodeURIComponent(f) + "')" : '';
    // 补全芯片：存全局，renderNp 统一填进 #npMeta；整页开着就立刻刷一次（meta 是异步回来的）
    S.npMetaHtml = buildNpMetaHtml(m);
    if (D('npPage') && D('npPage').classList.contains('on')) {
      renderNp();   // renderNp 内部已调 updateNpSummary(S.curMeta)，不再重复请求
    }
  }).catch(function () { D('npt').textContent = nam(f); });
}

/* ---------------- 状态 ---------------- */
// ============================================================================
// 2026-10-26 B-4（debug/20261026-02）：底栏 bit-perfect 徽标 两态 → 六态
//
// 旧实现只有 3 种文本（BIT-PERFECT·1bit / BIT-PERFECT / 非 bit-perfect），
// 分不清「PCM→PCM 升频」「PCM→DSD」「DSD→DSD 升频」，也看不到降级原因。
//
// 六态 = bit-perfect / 非 bit-perfect × 直通 / PCM-PCM / PCM-DSD / DSD-DSD：
//   维度①「有没有动数据」：direct（1-bit 直通，最严格）> yes > no
//   维度②「动的是什么方向」：直通（不升频）/ PCM→PCM / PCM→DSD / DSD→DSD
//
// 数据源**全部**是 /api/status 的后端权威字段（F-5 已落地），前端不自己推导结论：
//   bitPerfect    direct | yes | no   —— 三态结论
//   bitPerfectWhy 中文原因（no 时的明细）
//   outMode       coreaudio | shared | null | upnp | ""（"" = 本进程还没播过）
//   dsd           实际 DSD 档位（0 = PCM 输出）
//   dsdRate       1-bit 有效码率（PCM = 0）
//   carrierRate   DoP 的 PCM 载波率（= dsdRate/16；PCM = 0）
//   modFamily     dsd | ec | chebyshev | ahm（直通/PCM = 空）
//   modOrder      实际生效阶数（PCM = 0）
//   fallbackWhy   非空 = 本次与用户请求不一致的中文原因
//
// ⚠️ 为什么「源是 DSD 还是 PCM」不能只看后端：
//   /api/status 没有 srcFormat 字段，而这是六态里区分「PCM→DSD」与「DSD→DSD」的唯一依据。
//   所以源格式由**当前曲目扩展名**判定（.dsf/.dff = DSD），并做交叉校验：
//   DirectSDM 直通时后端 dsdRate 就是源位率；若扩展名说 DSD 但后端一个 DSD 字段都没有，
//   宁可标「升频」也不编一个方向出来（见 bpBadgeInfo 的注释）。
//
// 负向对照（判据）：直通时**不许**出现任何「升频」字样 —— 见 bpBadgeInfo 里
//   `!up` 分支的三条文本，全部不含「升频」，且 title 也不含。
// ============================================================================
function srcIsDsdPath(p) {
  return /\.(dsf|dff)$/i.test(String(p || ''));
}
// 源文件：优先当前曲目（/api/status 的 current），其次最近一次 loadMeta 的文件。
function bpCurFile() {
  return (typeof S.lastCur === 'string' && S.lastCur) ? S.lastCur : '';
}
// 六态判定（纯函数：只读 S.bp*，不碰 DOM ⟹ 可以用 node 单独跑判据）。
// 判据来源全是后端字段，**不是**"看 outRate 猜"：DoP 的 outRate 是**载波率**（DSD128=384000），
// 和"PCM 升频到 384k"数字完全一样，拿它反推会得出相反的结论（上游踩过这个坑）。
function bpBadgeInfo() {
  var bpv = S.bpState || '';
  if (!bpv) return { text: '待播放验证', cls: 'bp-idle',
                     title: '当前预设已保存，但尚未播放。bit-perfect 结论只对实际播放生效 —— 播一首才能确认' };

  var dsdOut = (typeof S.bpDsd === 'number') ? (S.bpDsd > 0) : false;
  var srcDsd = srcIsDsdPath(bpCurFile());
  var whyBp = S.bpWhy || '';
  var whyFb = S.bpFallback || '';
  var t = '', c = '', title = '';

  // title：降级原因（fallbackWhy）优先，回退 bitPerfectWhy。两者都有且不同时**都**显示 ——
  // fallbackWhy 讲「实际 ≠ 请求」，bitPerfectWhy 讲「为什么不是 bit-perfect」，是两件事。
  if (whyFb && whyBp && whyFb !== whyBp) title = '降级原因：' + whyFb + '；' + whyBp;
  else if (whyFb) title = '降级原因：' + whyFb;
  else title = whyBp;

  // ★★ 负向对照的落点：直通两态必须在「看 dsd 输出」**之前**返回。
  //    DirectSDM 直通时后端 dsd>0（DSD 源逐位直通），若先看 dsdOut 就会把直通标成
  //    「DSD-DSD 升频」—— 那正是"直通时出现升频字样"的失败形态。
  //    所以顺序是：direct/yes/no 先定「有没有升频」，只有非直通才继续判方向。
  if (bpv === 'direct') {
    t = 'BIT-PERFECT·1bit'; c = 'bp-direct';
    if (!title) title = 'DirectSDM：DSD 1-bit 直通，跳过 PCM 与调制';
    return { text: t, cls: c, title: title };
  }
  if (bpv === 'yes') {
    // 输出逐位一致 ⟹ 没有升频。（DSD 输出不可能是 yes：DoP 载波必然被 /api/status 判 no）
    t = 'BIT-PERFECT'; c = 'bp-yes';
    if (!title) title = '源→解码→输出全程逐位一致（不重采样、0 dB、无抖动/整形、无 EQ/IR）';
    return { text: t, cls: c, title: title };
  }

  // ---- 以下是 bpv === 'no'：链路里有改动，需要判方向 ----
  // 升频方向只有三种，且**必须**有后端证据：
  //   ① dsd>0            ⟹ 输出真的是 DSD（不是靠 outRate 猜；DoP 的 outRate 是载波率）
  //        源 DSD ⟹ DSD-DSD 升频；源 PCM ⟹ PCM-DSD 升频
  //   ② why 里出现「重采样」 ⟹ PCM-PCM 升频
  //   ③ 其余（音量/EQ/位深/抖动/DoP 载波）⟹ 只写「非 bit-perfect」，绝不冒充升频
  if (dsdOut) {
    t = srcDsd ? 'DSD-DSD 升频' : 'PCM-DSD 升频';
    c = 'bp-up';
    if (!title) {
      title = srcDsd ? 'DSD 源 → 更高 DSD 档（先解成 PCM 再重新调制）'
                     : 'PCM 源 → DSD（SDM 调制后走 DoP 承载）';
    }
    return { text: t, cls: c, title: title };
  }
  var allWhy = whyFb + ' ' + whyBp;
  if (allWhy.indexOf('重采样') >= 0) {
    t = 'PCM-PCM 升频'; c = 'bp-up';
    if (!title) title = 'PCM 源 → 更高 PCM 采样率';
    return { text: t, cls: c, title: title };
  }
  t = '非 bit-perfect'; c = 'bp-no';
  if (!title) title = '链路里有改动（原因见信号链）';
  return { text: t, cls: c, title: title };
}

function tick() {
  // return 出去：pollSchedule 靠它做 in-flight 互斥（见 pollSchedule 的注释）。
  return api('/api/status').then(function (j) {
    // 兜底对象没有任何播放字段：若照常往下写，S.playing/S.dur/S.pos 会全部变 undefined，
    // 底栏进度条归零、按钮变成"停止"——断线时看起来像"播放自己停了"。直接丢弃这一次即可，
    // 下一个 tick 恢复后自然接上（进度条本来就是靠绝对 pos 重算，不需要补帧）。
    if (j && j._err) return;
    // 播放状态翻转（开始/暂停/停止）要**立刻**重排轮询节奏：否则按下播放后要等空闲档的
    // 2.5 秒才切到 400ms，进度条像卡住；反之停止后还在 400ms 空转就是白烧后端。
    if (S.playing !== !!j.playing || S.paused !== !!j.paused) pollKick();
    S.playing = !!j.playing; S.paused = !!j.paused; S.dur = j.dur; S.pos = j.pos;
    // 2026-10-23 #1：底栏 bit-perfect 徽标的数据源（后端权威判定，见 /api/status 的 bitPerfect 字段）
    S.bpState = j.bitPerfect || ""; S.bpWhy = j.bitPerfectWhy || "";
    // 2026-10-26 B-4：六态徽标要判「升频方向」，全部取后端 F-5 的自证字段（前端不自己推导）。
    //   dsd>0 ⟹ 输出真的是 DSD（DoP 载波）；dsd=0 ⟹ PCM 输出。
    //   ★ 绝不用 outRate 反推：DoP 的 outRate 是**载波率**（DSD128 = 384000），
    //     和"PCM 升频到 384k"的数字一模一样，拿它判会得出完全相反的结论。
    S.bpDsd = (typeof j.dsd === 'number') ? j.dsd : 0;
    S.bpDsdRate = (typeof j.dsdRate === 'number') ? j.dsdRate : 0;
    S.bpCarrier = (typeof j.carrierRate === 'number') ? j.carrierRate : 0;
    S.bpModFamily = j.modFamily || '';
    S.bpModOrder = (typeof j.modOrder === 'number') ? j.modOrder : 0;
    S.bpOutMode = j.outMode || '';
    S.bpFallback = j.fallbackWhy || '';
    // 2026-10-23 261023-03 #2/#5：资料简介的显示门控只用后端权威状态（400ms 轮询顺带更新）
    if (typeof j.hasLlmKey === 'boolean') META.hasLlmKey = j.hasLlmKey;
    if (typeof j.summaryEnabled === 'boolean') META.summaryEnabled = j.summaryEnabled;
    // 正在播放整页：进度条 / 时间 / 播放图标
    if (D('npPage') && D('npPage').classList.contains('on')) {
      if (D('npBar') && S.dur > 0) D('npBar').style.width = Math.min(100, S.pos / S.dur * 100) + '%';
      if (D('npPos')) D('npPos').textContent = fmt(S.pos);
      if (D('npDur')) D('npDur').textContent = fmt(S.dur);
      if (D('npIcP')) D('npIcP').setAttribute('d', (S.playing && !S.paused)
        ? 'M7 5h4v14H7zM13 5h4v14h-4z' : 'M8 5l12 7-12 7z');
      syncVolUi();     // 音量可能在别处改（键盘 ↑↓ / 底栏滑块），整页跟着走
      renderNpLyric();
      // 2026-10-26（用户实测：预设卡的「当前设备」不跟随实际播放设备）：
      //   /api/preset/caps 的探测是实时的，但前端有 10 秒缓存、只在页面渲染时拉一次
      //   ⟹ 设置里换了输出设备后，卡片仍显示旧设备。
      //   status 现在带 device 字段（PlayerState.device，空 = 默认设备），
      //   变了就**强制**刷新能力缓存（首次拿到不算变化，避免启动时空刷一次）。
      var devNow = (typeof j.device === 'string') ? j.device : '';
      if (_capsDeviceSeen === null) {
        _capsDeviceSeen = devNow;                    // 首次：只记录，不刷新
      } else if (devNow !== _capsDeviceSeen) {
        _capsDeviceSeen = devNow;
        if (typeof loadPresetCaps === 'function') loadPresetCaps(true);
      }

    }
    S.volDb = (typeof j.volDb === 'number') ? j.volDb : S.vol;
    S.startDb = (typeof j.startDb === 'number') ? j.startDb : S.vol;
    // 信号链弹层开着时，音量节点要跟着实时变（否则就是在显示过期数据）
    if (D('chainVol') && D('modal').classList.contains('on')) D('chainVol').textContent = volText(S.volDb);
    if (D('chainTiming') && D('modal').classList.contains('on')) {
      var dspB = (typeof j.dspBlockMs === 'number' && j.dspBlockMs > 0) ? j.dspBlockMs.toFixed(2) + ' ms/块' : '';
      var dspT = (typeof j.dspTotalMs === 'number' && j.dspTotalMs > 0) ? '（累计 ' + j.dspTotalMs.toFixed(1) + ' ms）' : '';
      var dspStr = (dspB || dspT) ? (dspB + dspT) : '–';
      var decStr = (typeof j.decodeMs === 'number' && j.decodeMs > 0) ? (j.decodeMs >= 1000 ? (j.decodeMs/1000).toFixed(2) + ' s' : j.decodeMs.toFixed(1) + ' ms') : '–';
      var wavStr = '–';
      if (typeof j.ffmpegMs === 'number' && j.ffmpegMs > 0) {
        wavStr = '转码写 ' + j.ffmpegMs.toFixed(1) + ' ms' + (typeof j.wavReadMs === 'number' && j.wavReadMs > 0 ? ' / 读 ' + j.wavReadMs.toFixed(1) + ' ms' : '');
      } else if (typeof j.wavReadMs === 'number' && j.wavReadMs > 0) {
        wavStr = '读取 ' + j.wavReadMs.toFixed(1) + ' ms';
      }
      var scanStr = (typeof j.scanMs === 'number' && j.scanMs > 0) ? (j.scanMs >= 1000 ? (j.scanMs/1000).toFixed(2) + ' s' : j.scanMs.toFixed(0) + ' ms') : '–';
      D('chainTiming').textContent = '解码 ' + decStr + '  \u00b7  临时WAV ' + wavStr + '  \u00b7  DSP ' + dspStr + '  \u00b7  库扫描 ' + scanStr;
    }
    var pct = (j.dur > 0 ? Math.min(100, j.pos / j.dur * 100) : 0) + '%';
    if (D('bar')) D('bar').style.width = pct;
    D('tpos').textContent = fmt(j.pos);
    D('tdur').textContent = fmt(j.dur);
    D('icP').setAttribute('d', S.playing && !S.paused
      ? 'M7 5h4v14H7zM13 5h4v14h-4z'                     /* 暂停图标 */
      : 'M8 5v14l11-7z');                                 /* 播放图标 */
    if (j.current) {
      if (S.lastCur !== j.current) { S.lastCur = j.current; loadMeta(j.current); loadLyrics(j.current); }
      syncLyrics(j.pos);
      D('nps').textContent = (j.playing ? (j.paused ? '已暂停' : '播放中') : '已停止') +
        (j.outRate ? ' \u00b7 ' + j.outRate + ' Hz / ' + j.outBits + ' bit' : '');
      D('fmt').textContent = j.outRate ? (Math.round(j.outRate / 100) / 10) + 'k/' + j.outBits : '--';
      updateNextTrackInfo();
      // 261024-04 #8：底栏 GPU 徽标只表示「GPU **真的参与**了本次播放」。
      // 后端新字段 gpuUsed（本次播放 GPU 是否实际参与）；字段还没上线时回退旧的 gpu 字段。
      // 选择"不参与就不亮"而不是"显示灰色 GPU 可用·未参与"：底栏右侧本来就挤，
      // 常驻一个灰 chip 会把"绿点 = GPU 参与"这个唯一的强信号稀释掉；可用性在设置→高级与信号链里能查到。
      S.gpuUsed = (typeof j.gpuUsed === 'boolean') ? j.gpuUsed : !!j.gpu;
      S.gpuOn = !!j.gpu;
      D('gpub').style.display = S.gpuUsed ? '' : 'none';
      D('gpub').title = S.gpuUsed ? 'GPU 参与本次播放'
        : (S.gpuOn ? 'GPU 可用 · 本次未参与（信号链里绿色节点才会亮）' : 'GPU 未参与本次播放');
    } else {
      S.gpuUsed = false; S.gpuOn = false;
      D('fmt').textContent = '--';
      D('gpub').style.display = 'none';
      if (S.lastCur) { S.lastCur = ''; D('npt').textContent = '未播放'; D('npart').textContent = ''; D('nps').textContent = '选择一个专辑开始'; D('cv').style.backgroundImage = ''; S.npMetaHtml = ''; if (D('npMeta')) D('npMeta').innerHTML = ''; }
      updateNextTrackInfo();
    }
    syncAlbPlayAllBtn();
    // 2026-10-23 #1：底栏常驻一个「b-p」徽标，不打开信号链也能知道当前是否 bit-perfect。
    // 2026-10-23 用户 261023-04 #1：改成紧凑 chip（class=bp-yes/bp-no/bp-direct），
    // 配色与显隐交给 CSS（三套主题各有一套颜色），这里不写死颜色、也不占中间列。
    // 2026-10-26 B-4：两态 → 六态。判定全在 bpBadgeInfo()（纯函数，见文件上方），
    // 这里只负责把结果写进 DOM —— 判据与渲染分开，才能用 node 单独测判定。
    if (D('bpBadge')) {
      var bi = bpBadgeInfo();
      D('bpBadge').textContent = bi.text;
      D('bpBadge').className = bi.cls;
      D('bpBadge').title = bi.title;
    }
    if (j.outMode === 'upnp') {
      var rcOk = (j.upnpVolumeSupported !== false);
      ['vol', 'npVol'].forEach(function (id) {
        var e = D(id);
        if (e) {
          e.disabled = !rcOk;
          e.title = rcOk ? '' : '该渲染器未提供 RenderingControl 服务，无法调整音量（请在渲染器端调节）';
        }
      });
    } else {
      ['vol', 'npVol'].forEach(function (id) {
        var e = D(id);
        if (e && e.disabled) {
          e.disabled = false;
          e.title = '';
        }
      });
    }
    if (j.error) D('nps').textContent = j.error;
  }).catch(function () { });
}

/* ---------------- 播放设置持久化 ---------------- */
// 2026-10-25（task-12）：已删除的后端值 → 优雅降级。
// 为什么需要：ASIO 是 Windows 专有驱动协议，macOS 的 CoreAudio 从内核层就是低延迟 / bit-perfect，
// 没有需要绕过的东西 ⟹ ASIO 在 macOS 不是「做不到」而是「不需要」。后端删了，但老用户的 conf
// 里可能还留着 backend=asio，直接沿用会让播放失败、下拉也选不中（白屏级别的体验事故）。
// 处置：落回默认后端（wasapi = CoreAudio 独占），并明确 toast 告知原因，绝不静默改。
var REMOVED_BACKENDS = {
  asio: 'ASIO 已移除（macOS 使用 CoreAudio）',
  // 2026-10-25（用户指令「不可用的要隐藏」）：NAA / RTANet 在 macOS 上没有驱动体系，
  // make_sink() 对它返回必然 open 失败的 sink。老 conf 里存过 naa 的必须降级，
  // 否则下拉选不中（该 option 已不存在）+ 播放直接失败，是白屏级别的体验事故。
  naa: 'macOS 不支持 NAA 推流，已切到 CoreAudio 独占'
};
var _removedBackendNotified = {};
function migrateRemovedBackend(v) {
  var k = String(v || '').toLowerCase();
  if (REMOVED_BACKENDS.hasOwnProperty(k)) {
    // 每次页面生命周期只提示一次，避免多处调用把 toast 刷成复读机。
    if (!_removedBackendNotified[k]) {
      _removedBackendNotified[k] = true;
      // 稍等一拍：启动期还有别的 toast，立刻弹会被盖掉，用户就看不到原因了。
      setTimeout(function () { toast(REMOVED_BACKENDS[k]); }, 1200);
    }
    return 'wasapi';
  }
  return v || 'wasapi';
}

// 2026-10-25（用户指令「A1 隐藏」）：老配置里若存过 dsdpack=nat，加载时降级到 dop 并提示一次。
// 为什么降级而不是报错：Native 在 macOS 上永远不可用（CoreAudio 只有 PCM 管线），
// 用户当年选它多半是因为 Windows 版能工作；现在直接切到 DoP 是**无损**的
// （DoP 不是转 PCM，DAC 端剥壳后仍是 bit-perfect DSD），不需要让用户手动去改。
var _dsdPackNotified = false;
function migrateDsdPack(v) {
  if (v === '0' || v === '' || v === 0 || !v) return '0';
  var s = String(v).toLowerCase();
  if (s === '0') return '0';
  if (s.indexOf('nat') === 0) {
    var rate = s.slice(3);
    if (!_dsdPackNotified) {
      _dsdPackNotified = true;
      setTimeout(function () {
        toast('macOS 不支持 Native DSD，已切到 DoP（bit-perfect，音质不受影响）');
      }, 1400);
    }
    return 'dop' + (rate || '');
  }
  return s;
}

// 2026-10-25（用户指令「能使用的要用它真正的名字」）：Windows 时代的 gpuvendor 值
// （amd / nvidia / cuda / dx12）在 macOS 上没有任何对应后端，老 conf 载入时降级为 auto。
function migrateGpuVendor(v) {
  var s = String(v || '').toLowerCase();
  if (s === 'amd' || s === 'nvidia' || (s !== 'metal' && s !== 'off' && s !== 'auto')) return 'auto';
  return s || 'auto';
}
function ensureGpuOption(val) {
  var e = D('sGpu');
  if (e && val && !e.querySelector('option[value="' + val + '"]')) {
    var o = document.createElement('option');
    o.value = val; o.text = val;
    e.appendChild(o);
  }
}
var SET_KEYS = [['sRate','rate'], ['sFilt','filter'], ['sFiltNx','filterNx'], ['sShap','shaper'],
                ['sDSD','dsd'], ['sBuf','buffer'], ['sIsp','isp'], ['s2s','twostage'], ['sGpu','gpuvendor']];
function saveSettings(immediate) {
  var body = '';
  SET_KEYS.forEach(function (p) {
    var e = D(p[0]); if (!e) return;
    var v = (e.type === 'checkbox') ? (e.checked ? '1' : '0') : e.value;
    if (body) body += '&';
    body += p[1] + '=' + encodeURIComponent(v);
  });
  body += '&volume=' + S.vol + '&loudness=' + (D('sLoud').checked ? '1' : '0');
  body += '&theme=' + encodeURIComponent(S.theme || 'dark');
  body += '&uistyle=' + encodeURIComponent(S.uiStyle || 'apple');
  body += '&device=' + encodeURIComponent(ADV.device || '') + '&bits=' + (ADV.bits || 0)
        + '&taps=' + (ADV.taps || 0) + '&atten=' + (ADV.atten || 0)
        + '&transition=' + (ADV.transition || 0) + '&phase=' + encodeURIComponent(ADV.phase || '')
        + '&modorder=' + (ADV.modorder || 5) + '&modfamily=' + encodeURIComponent(ADV.modfamily || 'dsd') + '&modcut=' + (ADV.modcut || 0)
        + '&moddith=' + (ADV.moddith === undefined ? -1 : ADV.moddith)
        + '&eq=' + encodeURIComponent(ADV.eq || '')
        + '&ir=' + encodeURIComponent(ADV.ir || '') + '&irgpu=' + (ADV.irgpu || 0)
        + '&ramp=' + (ADV.ramp || 0)
        + '&backend=' + encodeURIComponent(ADV.backend || 'wasapi')
        + '&channels=' + (ADV.channels || 0)
        + '&naahost=' + encodeURIComponent(ADV.naaHost || '')
        + '&upnpdev=' + encodeURIComponent(ADV.upnpDev || '')
        + '&trim=' + [0, 1, 2, 3, 4, 5, 6, 7].map(function (i) { return ADV['trim' + i] || 0; }).join(',')
        + '&inbackend=' + encodeURIComponent(ADV.inBackend || 'none')
        + '&indev=' + encodeURIComponent(ADV.inDev || '')
        + '&inoffset=' + (ADV.inOffset || 0)
        + '&inbuf=' + (ADV.inBuf || 100)
        + '&inmon=' + (ADV.inMonitor || 0)
        + '&inseconds=' + (ADV.inSeconds || 0)
        + '&inout=' + encodeURIComponent(ADV.inOut || '')
        + '&sdmfilt=' + encodeURIComponent(ADV.sdmFilt || '')
        + '&sdmfiltnx=' + encodeURIComponent(ADV.sdmFiltNx || '')
        + '&directsdm=' + (ADV.directsdm ? 1 : 0)
        + '&dsdkind=' + (ADV.dsdKind || 'fir') + '&dsdconv=' + (ADV.dsdConv || 'narrow')
        + '&scanthreads=' + (ADV.scanThreads !== undefined ? ADV.scanThreads : 0)
        + '&updbeta=' + (ADV.updbeta ? 1 : 0)
        + '&opraproduct=' + encodeURIComponent(ADV.opraproduct || '')
        + '&oprapreset=' + encodeURIComponent(ADV.oprapreset || '')
        // 元数据补全（P1.5）：metaon/metallm 固定两键；源开关按注册表逐源写 metasrc_<id>; metasummary 默认0
        + '&metaon=' + (META.on ? 1 : 0)
        + '&metallm=' + (META.llm ? 1 : 0)
        + '&metasummary=' + (META.summary ? 1 : 0)
        + (META_PROVIDERS || []).map(function (p) {
            return '&metasrc_' + p.id + '=' + (META_SRC[p.id] === 0 ? 0 : 1);
          }).join('');
  clearTimeout(window._setT);
  if (immediate) {
    api('/api/settings', body);
  } else {
    window._setT = setTimeout(function () { api('/api/settings', body); }, 300);
  }
}
function loadSettings() {
  api('/api/settings').then(function (j) {
    var kv = j.kv || {};
    if (kv.scanThreads !== undefined || kv.scanthreads !== undefined) {
      ADV.scanThreads = parseInt(kv.scanThreads || kv.scanthreads, 10) || 0;
    }
    if (kv.updbeta !== undefined) {
      ADV.updbeta = (kv.updbeta === '1' || kv.updbeta === 'true') ? 1 : 0;
      if (D('sp_updbeta')) D('sp_updbeta').checked = (ADV.updbeta === 1);
    }
    SET_KEYS.forEach(function (p) {
      if (kv[p[1]] !== undefined) ADV[p[1]] = kv[p[1]];
      var e = D(p[0]); if (!e || kv[p[1]] === undefined) return;
      if (e.type === 'checkbox') e.checked = (kv[p[1]] === '1');
      else if (p[1] === 'dsd') e.value = migrateDsdPack(kv[p[1]]);   // A1 隐藏：nat* → dop*
      else if (p[1] === 'gpuvendor') {
        var gv = migrateGpuVendor(kv[p[1]]);
        ensureGpuOption(gv);
        e.value = gv;
      }
      else e.value = kv[p[1]];
    });
    // ---- 老用户配置迁移（功能1 的红线：不许悄悄改老用户行为）----
    // 只有 conf 里【完全没有 rate 键】时才用新默认（follow）：
    //   老用户 conf 通常有 rate=max → kv.rate 有值 → 上面 SET_KEYS 已把它写回 <select>，
    //   所以 TA 的行为一点没变（继续按"设备最高"播，直到自己改）。
    //   全新安装没有 conf → kv.rate 缺失 → 保持 HTML 第一项 follow。
    // 注意：这里【只改 DOM 初值，不立刻 saveSettings】，避免读到旧 conf 就回写。
    if (kv.rate === undefined) {
      if (D('sRate')) D('sRate').value = 'follow';
    }
    // conf 里存的是 dB；滑块是位置刻度 ⟹ 必须换算（否则 -25.5 dB 会被塞进 0..1000 的滑块里变成 0）
    // volNormalize：老配置可能存着旧曲线的 -60（低于 v3 的 -55 曲线底）⟹ 收成 -120 真静音，
    // 否则滑块摆在最左端、后端却按 0.1% 振幅出声（与标签/位置自相矛盾）。
    if (kv.volume !== undefined) {
      S.vol = volNormalize(parseFloat(kv.volume) || 0);
      if (D('vol')) D('vol').value = volDbToPos(S.vol);
      syncVolUi();
    }
    if (kv.loudness !== undefined) { D('sLoud').checked = (kv.loudness === '1'); S.loud = D('sLoud').checked; }
    // 高级参数
    if (kv.device !== undefined) ADV.device = kv.device;
    if (kv.bits !== undefined) {
      var _b = parseInt(kv.bits, 10);
      ADV.bits = (isNaN(_b) ? 0 : _b);   // -1 = 跟随源，不能被 ||0 吃掉
    }
    if (kv.taps !== undefined) ADV.taps = parseInt(kv.taps, 10) || 0;
    if (kv.atten !== undefined) ADV.atten = parseFloat(kv.atten) || 0;
    if (kv.transition !== undefined) ADV.transition = parseFloat(kv.transition) || 0;
    if (kv.phase !== undefined) ADV.phase = kv.phase;
    if (kv.modorder !== undefined) ADV.modorder = parseInt(kv.modorder, 10) || 5;
    if (kv.modfamily !== undefined) ADV.modfamily = kv.modfamily || 'dsd';
    if (kv.modcut !== undefined) ADV.modcut = parseFloat(kv.modcut) || 0;
    if (kv.moddith !== undefined) ADV.moddith = parseFloat(kv.moddith);
    if (kv.eq !== undefined) ADV.eq = kv.eq;
    if (kv.ir !== undefined) ADV.ir = kv.ir;
    if (kv.irgpu !== undefined) ADV.irgpu = (kv.irgpu === '1') ? 1 : 0;
    if (kv.ramp !== undefined) ADV.ramp = parseFloat(kv.ramp) || 0;
    // 2026-10-25（用户指令「能使用的要用它真正的名字」）：Windows 时代的 gpuvendor 值
    // （amd / nvidia / cuda / dx12）在 macOS 上没有任何对应后端，老 conf 载入时必须降级，
    // 否则下拉选不中（这些 option 已移除）且 /api/gpu 会收到无法识别的值。
    if (kv.gpuvendor !== undefined) {
      ADV.gpuvendor = migrateGpuVendor(kv.gpuvendor);
      ensureGpuOption(ADV.gpuvendor);
      if (D('sGpu')) D('sGpu').value = ADV.gpuvendor;
    }
    if (kv.backend !== undefined) ADV.backend = migrateRemovedBackend(kv.backend);
    // 2026-10-25（方案 C）：Hog 独占开关（老 conf 无此键 = 0，即不抢 Hog，安全默认）
    if (kv.hogexcl !== undefined) ADV.hogExclusive = (kv.hogexcl === '1') ? 1 : 0;
    if (kv.channels !== undefined) ADV.channels = parseInt(kv.channels, 10) || 0;
    if (kv.naahost !== undefined) ADV.naaHost = kv.naahost || '';
    if (kv.upnpdev !== undefined) ADV.upnpDev = kv.upnpdev || '';
    if (kv.trim !== undefined) {
      var tv = String(kv.trim).split(',');
      for (var ti = 0; ti < 8; ti++) ADV['trim' + ti] = parseFloat(tv[ti]) || 0;
    }
    if (kv.inbackend !== undefined) ADV.inBackend = kv.inbackend || 'none';
    if (kv.indev !== undefined) ADV.inDev = kv.indev || '';
    if (kv.inoffset !== undefined) ADV.inOffset = parseInt(kv.inoffset, 10) || 0;
    if (kv.inbuf !== undefined) ADV.inBuf = parseInt(kv.inbuf, 10) || 100;
    if (kv.inmon !== undefined) ADV.inMonitor = (kv.inmon === '1') ? 1 : 0;
    if (kv.inseconds !== undefined) ADV.inSeconds = parseFloat(kv.inseconds) || 0;
    if (kv.inout !== undefined) ADV.inOut = kv.inout || '';
    if (kv.sdmfilt !== undefined) ADV.sdmFilt = kv.sdmfilt || '';
    if (kv.sdmfiltnx !== undefined) ADV.sdmFiltNx = kv.sdmfiltnx || '';
    if (kv.directsdm !== undefined) ADV.directsdm = (kv.directsdm === '1') ? 1 : 0;
    if (kv.dsdkind !== undefined) ADV.dsdKind = kv.dsdkind || 'fir';
    if (kv.dsdconv !== undefined) ADV.dsdConv = kv.dsdconv || 'narrow';
    if (kv.opraproduct !== undefined) ADV.opraproduct = kv.opraproduct;
    if (kv.oprapreset !== undefined) ADV.oprapreset = kv.oprapreset;
    // 元数据补全（P1.5）：metaon/metallm 从设置键读；源开关不在这里读 ——
    // 由 fillMetaProviders 走 /api/providers（同一 conf 的注册表视图，含旧键迁移）
    if (kv.metaon !== undefined) META.on = (kv.metaon === '1') ? 1 : 0;
    if (kv.metallm !== undefined) META.llm = (kv.metallm === '1') ? 1 : 0;
    if (kv.metasummary !== undefined) META.summary = (kv.metasummary === '1') ? 1 : 0;
    // 主题与界面风格：本地优先（避免闪一下），否则用服务端保存的
    var t = null, u = null;
    try { t = localStorage.getItem('rta-theme'); u = localStorage.getItem('rta-uistyle'); } catch (e) { }
    setTheme(t || kv.theme || 'dark', false);
    setUiStyle(u || kv.uistyle || 'apple', false);
    // 用户 261023-04 #4：EQ/IR 芯片读的是上面刚填好的 ADV.eq / ADV.ir ——
    // 设置页保存后立刻重绘单曲页（清空 EQ 后芯片要马上消失，不用重开页面）。
    if (D('npPage') && D('npPage').classList.contains('on')) renderNp();
  }).catch(function () { });
}

/* ---------------- 元数据源开关（P1.5：/api/providers 注册表驱动） ---------------- */
// 源开关的 HTML 由注册表条目生成：能力位决定提示文案（搜索/歌词）。渲染进设置页
// 元数据分组的 #sp_metasrc 占位容器；/api/providers 晚到也会在到达后补填。
function metaSrcHtml() {
  return (META_PROVIDERS || []).map(function (p) {
    var cap = (p.canSearch && p.canLyric) ? '标签 / 封面 / 歌词'
            : p.canSearch ? '标签 / 封面'
            : '歌词（独立歌词源）';
    return chk('sp_meta_' + p.id, p.name, META_SRC[p.id] !== 0, cap + '；按注册表顺序参与补全');
  }).join('');
}
function renderMetaSrcRows() {
  var box = D('sp_metasrc'); if (!box) return;
  box.innerHTML = metaSrcHtml();
  (META_PROVIDERS || []).forEach(function (p) {
    var e = D('sp_meta_' + p.id); if (!e) return;
    e.onchange = function () { META_SRC[p.id] = this.checked ? 1 : 0; saveSettings(); };
  });
}
// 启动时拉一次注册表（含当前开关状态，旧键已由后端迁移）；设置页开着时立即重填，
// 没开着则下次 renderSettingsPage 用缓存渲染。
function fillMetaProviders() {
  api('/api/providers').then(function (j) {
    if (!j || !j.ok || !j.items) return;
    META_PROVIDERS = j.items;
    META_PROVIDERS.forEach(function (p) { META_SRC[p.id] = p.on ? 1 : 0; });
    renderMetaSrcRows();
  }).catch(function () { });
}

/* ---------------- 标签写回（P2：/api/writeback 预览 / 执行 / 轮询） ----------------
   预览=GET dry（纯只读扫描，toast「N 首可写，M 首跳过」）；
   执行=POST {"apply":true} 起后台批，轮询 status 到 done，toast「写入 X，跳过 Y，失败 Z」。
   执行期间两按钮禁用（WB_BUSY）；写回前服务端自动做 PCM 逐位校验，
   原文件备份到 MetaBase 目录的 backups 子目录。 */
var WB_BUSY = 0;
function wbButtons(dis) {
  var a = D('sp_wbdry'), b = D('sp_wbapply');
  if (a) a.disabled = dis ? true : false;
  if (b) b.disabled = dis ? true : false;
}
function wbMsg(m) { var e = D('sp_wbmsg'); if (e) e.textContent = m || ''; }
function wbPoll() {
  api('/api/writeback/status').then(function (j) {
    if (!j || !j.ok) { WB_BUSY = 0; wbButtons(0); wbMsg(''); return; }
    if (j.running) {
      wbMsg('写回进行中 ' + (j.done || 0) + '/' + (j.total || 0) + '…');
      setTimeout(wbPoll, 800);
      return;
    }
    WB_BUSY = 0; wbButtons(0); wbMsg('');
    if (j.error) { toast('写回未执行：' + j.error); return; }
    toast('写入 ' + (j.written || 0) + '，跳过 ' + (j.skipped || 0) + '，失败 ' + (j.failed || 0) +
          '；失败清单见 rlplayer-meta' + SEP + 'writeback-failures.json');
  }).catch(function () { WB_BUSY = 0; wbButtons(0); wbMsg(''); });
}
// 页面（重）打开时同步一次在跑状态：中途刷新页面也能恢复禁用并接上轮询
function wbSyncBusy() {
  api('/api/writeback/status').then(function (j) {
    if (!j || !j.ok || !j.running) return;
    WB_BUSY = 1; wbButtons(1); wbMsg('写回批次进行中…');
    wbPoll();
  }).catch(function () { });
}
function wbPreview() {
  if (WB_BUSY) return;
  WB_BUSY = 1; wbButtons(1); wbMsg('正在扫描 MetaBase…');
  api('/api/writeback?dry=1').then(function (j) {
    WB_BUSY = 0; wbButtons(0); wbMsg('');
    if (!j || !j.ok) { toast('预览失败：' + ((j && j.error) || '未知错误')); return; }
    toast((j.writable || 0) + ' 首可写，' + (j.skipped || 0) + ' 首跳过');
  }).catch(function () { WB_BUSY = 0; wbButtons(0); wbMsg(''); toast('预览失败：网络错误'); });
}
function wbApply() {
  if (WB_BUSY) return;
  WB_BUSY = 1; wbButtons(1); wbMsg('写回批次已启动…');
  api('/api/writeback', '{"apply":true}').then(function (j) {
    if (!j || !j.ok || !j.started) {
      WB_BUSY = 0; wbButtons(0); wbMsg('');
      toast('无法启动写回：' + ((j && j.error) || '未知错误'));
      return;
    }
    wbPoll();
  }).catch(function () { WB_BUSY = 0; wbButtons(0); wbMsg(''); toast('无法启动写回：网络错误'); });
}

/* ---------------- 设备能力与混音格式（Q-1 / Q-4） ---------------- */
var DEVMIX = {};       // deviceId -> {channels, mixRate, mixBits, fmt}
function devMixOf(id) { return DEVMIX[id || ''] || null; }
function devMixChannels(id) { var d = devMixOf(id); return (d && d.channels) || 0; }
function effectiveChannels() {
  var bk = (D('sp_backend') && D('sp_backend').value) || ADV.backend || 'wasapi';
  var setCh = parseInt(ADV.channels, 10) || 0;
  var devCh = devMixChannels(ADV.device);
  // 共享模式：输出经 CoreAudio 系统混音，恒等于设备混音声道数（系统混音器决定），设置项不参与
  if (bk === 'wasapi-shared') return devCh || setCh || 2;
  // 硬件直通 / Null / UPnP：显式选了 2/6/8 就用它；「跟随源」(0) 用设备混音声道数做预览
  return setCh > 0 ? setCh : (devCh || 2);
}
function devMixText(id) {
  var d = devMixOf(id);
  if (!d || !d.channels) return '';
  return d.channels + ' 声道 · ' + (d.mixRate ? (d.mixRate + ' Hz') : '采样率未知') +
         (d.mixBits ? (' · ' + d.mixBits + ' bit ' + (d.fmt || '')) : '');
}
function updateDevMixHint() {
  var el = D('sp_trimchmsg'); if (!el) return;
  var n = effectiveChannels();
  var devCh = devMixChannels(ADV.device);
  var t = devMixText(ADV.device);
  var bk = (D('sp_backend') && D('sp_backend').value) || ADV.backend || 'wasapi';
  var tail;
  if (parseInt(ADV.channels, 10) > 0) tail = '；「输出声道数」= ' + parseInt(ADV.channels, 10) + '，以此为准';
  else if (bk === 'wasapi-shared') tail = '；共享模式输出经 CoreAudio 系统混音，恒等于设备声道数';
  else if (bk === 'wasapi') tail = '；「输出声道数」= 跟随源，硬件直通播放时实际声道随源文件变化';
  else tail = '；「输出声道数」= 跟随源';
  el.innerHTML = '按 <b>' + n + ' 声道</b> 显示' +
    (devCh ? ('（CoreAudio 设备混音 ' + devCh + ' ch' + (t ? (' · ' + esc(t.replace(/^(\d+) 声道 · /, ''))) : '') + '）') : '') + tail;
}
function repaintTrims() {
  var g = document.querySelector('#setpage .trimgrid');
  if (g) { g.innerHTML = trimFields(effectiveChannels()); bindTrims(); }
  updateDevMixHint();
}
function applyTrimChannels() { repaintTrims(); }
window.devMixText = devMixText;
window.updateDevMixHint = updateDevMixHint;
window.repaintTrims = repaintTrims;
window.effectiveChannels = effectiveChannels;

// Nx 滤波器下拉默认值：跟随 1x
(function () {
  var nx = D('sFiltNx');
  if (nx) {
    var o = document.createElement('option');
    o.value = ''; o.textContent = '\u8ddf\u968f 1x \u6ee4\u6ce2\u5668';
    nx.insertBefore(o, nx.firstChild);
    nx.value = '';
  }
})();

function loadDeviceList() {
  var bk = ADV.backend || 'wasapi';
  api('/api/devices').then(function (j) {
    var list = j.devices || [];
    list.forEach(function (d) {
      if (d && d.id) {
        DEVMIX[d.id] = {
          channels: d.channels || 0,
          mixRate: d.mixRate || 0,
          mixBits: d.mixBits || 0,
          fmt: d.mixFmt || ''
        };
      }
    });
    var sel2 = D('sp_device');
    if (!sel2) { updateDevMixHint(); return; }
    var h = '<option value="">' +
      ((bk === 'wasapi' || bk === 'wasapi-shared') ? '默认设备' : '（此后端没有本地设备）') +
      '</option>';
    list.forEach(function (d) {
      var dm = DEVMIX[d.id];
      h += '<option value="' + esc(d.id) + '">' + esc(d.name) +
           (d.default ? '（默认）' : '') +
           (dm && dm.channels ? ('  ·  ' + dm.channels + 'ch' + (dm.mixRate ? ('/' + (dm.mixRate / 1000) + 'k') : '')) : '') +
           '</option>';
    });
    sel2.innerHTML = h;
    sel2.value = ADV.device || '';
    sel2.onchange = function () {
      ADV.device = this.value;
      if (bk === 'wasapi') loadRates();   // 只有 CoreAudio 独占能查设备支持的采样率
      saveSettings();
      repaintTrims();
      toast('输出设备已选择，下次播放生效');
    };
    repaintTrims();
  }).catch(function () { });
}

function loadRates() {
  api('/api/rates' + (ADV.device ? ('?device=' + encodeURIComponent(ADV.device)) : '')).then(function (j) {
    var list = j.rates || [];
    if (!list.length) return;
    var max = list[list.length - 1];
    var sel = D('sRate');
    Array.prototype.forEach.call(sel.options, function (o) {
      if (o.value === 'max') { o.textContent = '\u81ea\u52a8\uff08\u8bbe\u5907\u6700\u9ad8 ' + max + '\uff09'; return; }
      // ★ 'follow' 必须在这里 return：它是枚举值、不是数字。漏掉这一条会让它
      //   掉进下面的 parseInt 分支（parseInt('follow') = NaN）⟹ 判为"设备不支持"
      //   ⟹ o.disabled=true 且 sel.value 被强制改成 'max'，于是"跟随系统"永远选不上。
      //   2026-10-22 功能1 实测踩到：全新安装本该是 follow，页面显示的却是 max。
      if (o.value === 'follow') {
        o.textContent = j.sysRate ? ('\u8ddf\u968f\u7cfb\u7edf\uff08' + j.sysRate + ' Hz\uff09')
                                  : '\u8ddf\u968f\u7cfb\u7edf';
        return;
      }
      if (o.value === 'src') return;
      var r = parseInt(o.value, 10);
      var ok = list.indexOf(r) >= 0;
      o.disabled = !ok;
      if (!ok && sel.value === o.value) sel.value = 'max';
      o.textContent = String(r) + (ok ? '' : '  \uff08\u8bbe\u5907\u4e0d\u652f\u6301\uff09');
    });
    var nm = j.device ? ('\u8f93\u51fa\u8bbe\u5907\uff1a' + j.device) : '';
    if (nm && D('devName')) D('devName').textContent = nm;
  }).catch(function () { });
}

/* ---------------- 媒体库状态 ---------------- */
// 2026-10-24（用户 261024-01 #6/#7）：本地音乐库页用「数字」代替一段说明文字 ——
// 曲目 / 专辑 / 扫描线程 / 上次扫描耗时 一眼可见，说明文字全部收进 (?)。
function renderLibStats(j) {
  var box = D('sp_libstats'); if (!box) return;
  var th = parseInt(j.scanThreads, 10) || 0;
  var ms = parseFloat(j.lastScanMs) || 0;
  function it(lbl, val) {
    return '<div class=it><span class=lbl>' + lbl + '</span><span class=val>' + val + '</span></div>';
  }
  // 输入框里的 0 = 自动；统计卡显示的是后端【实际生效】的线程数（例如 8），
  // 标签写成「生效」避免用户以为「输入 0 / 统计 8」是两套不一致的值。
  var h = it('曲目', (j.tracks || 0)) + it('专辑', (j.albums || 0)) +
          it('扫描线程（生效）', th ? th : '自动') + it('上次扫描', ms > 0 ? (ms / 1000).toFixed(1) + ' s' : '—');
  if (j.scanning) h += it('进度', (j.scanned || 0) + ' / ' + (j.total || 0));
  box.innerHTML = h;
}
function loadLibStats() {
  // return 出去：pollSchedule 靠它做 in-flight 互斥。
  return api('/api/lib/stats').then(function (j) {
    // 兜底对象（api() 的失败返回）**没有** scanning/roots/tracks 字段：这时必须原地不动。
    // 以前若把失败当成功处理，S.roots 会被清成 []、曲目数会显示 0，正是用户说的「数据消失」。
    // 直接 return 即可：界面保留上一次的真实数据，只由 api() 那一层弹一次 toast 说明断线。
    if (j && j._err) return;
    var wasScanning = S.scanning;
    S.scanning = !!j.scanning;
    // 扫描结束（true→false）必须让视图缓存失效：否则用户点回「专辑」看到的还是扫描前那份
    // 5 秒内的旧快照，新扫出来的歌"看不见"（261025-01 #5 的显式失效条件之一）。
    if (wasScanning && !S.scanning) { viewCacheClear(); }
    // 扫描开始/结束都影响 stats 与 queue 的节奏（扫描中 stats 要 2 秒看进度），立刻重排。
    if (wasScanning !== S.scanning) pollKick();
    S.roots = j.roots || [];
    renderLibStats(j);
    var bScanEl = D('bScan');
    if (S.scanning) {
      if (bScanEl) {
        bScanEl.classList.add('spinning');
        bScanEl.title = '正在扫描音乐库 (' + (j.scanned || 0) + '/' + (j.total || 0) + ')';
      }
      D('scanbar').style.display = '';
      var pct = j.total > 0 ? Math.min(100, j.scanned / j.total * 100) : 0;
      D('scanfill').style.width = pct + '%';
      D('cnt').textContent = '扫描中 ' + j.scanned + '/' + j.total;
    } else {
      if (bScanEl) {
        bScanEl.classList.remove('spinning');
        bScanEl.title = '重新扫描音乐库';
      }
      D('scanbar').style.display = 'none';
      if (wasScanning) {
        var msg = '扫描完成：共 ' + (j.tracks || 0) + ' 首曲目，' + (j.albums || 0) + ' 张专辑';
        toast(msg);
        window._lastScanSummary = { tracks: j.tracks, albums: j.albums };
        if (S.view === 'albums') loadAlbums('');
        else if (S.view === 'tracks') loadTracks(S.tracksQuery || '');
      } else if (j.tracks === 0 && S.view === 'albums' && !D('list').children.length) {
        loadAlbums('');
      }
    }
    if (D('roots2')) {
      var h = '';
      S.roots.forEach(function (r) {
        h += '<div class=rootline><span title="' + esc(r) + '">' + esc(r) + '</span>' +
             '<button data-r="' + esc(r) + '" title="移除">\u00d7</button></div>';
      });
      D('roots2').innerHTML = h || '<div style="font-size:11.5px;color:#5b6478">还没有添加目录</div>';
      Array.prototype.forEach.call(D('roots2').querySelectorAll('button'), function (b) {
        b.onclick = function () {
          api('/api/lib/roots', 'remove=' + encodeURIComponent(b.dataset.r)).then(function (j) {
            if (j && j.ok === false) { toast(j.error || '移除失败'); return; }
            // 反馈 #3：后端会连带清掉该目录下的曲目，这里必须把结果如实说出来 +
            // 立刻重画当前视图（否则歌还挂在界面上，看起来像没移除成功）。
            var n = (j && typeof j.removedTracks === 'number') ? j.removedTracks : 0;
            libChanged();
            toast(n > 0 ? ('已移除，清理 ' + n + ' 首') : '已移除');
            refreshCurrentView();
            loadLibStats();
          });
        };
      });
    }
    if (S.view === 'settings' && D('sp_roots')) drawRoots();
  }).catch(function () { });
}

/* ---------------- 流媒体 ---------------- */
function loadRemote(id) {
  S.view = 'remote';
  api('/api/src/browse?id=' + encodeURIComponent(id || '')).then(function (j) {
    // 兜底对象的字段名是 error 而不是 err，不先拦就会掉进"正常分支"渲染成空列表，
    // 看起来像"服务器里什么都没有"（实际是后端没响应）。
    if (j && j._err) { head('流媒体', '读取失败', ''); listErrorBox('流媒体目录读取失败', function () { loadRemote(id || ''); }); return; }
    if (j.err && !(j.items || []).length) {
      // 评审 #7：以前错误态整屏只留一行裸文本，像"页面坏了"。改成带说明 + 去配置入口的空态卡。
      head('流媒体', '', '');
      D('list').innerHTML = '<div class="card" style="max-width:560px;width:100%;margin:clamp(24px,10vh,90px) auto 0;padding:24px 26px;background:var(--phbg);border:1px solid var(--line);border-radius:12px">' +
        '<div style="font-size:14px;font-weight:650;margin-bottom:6px">还没有可浏览的流媒体服务器</div>' +
        '<div style="color:var(--mut);font-size:12.5px;line-height:1.7;margin-bottom:14px">' +
        esc(j.err) + '<br>支持 Navidrome / Subsonic / Emby（只取原始文件，不转码）。先在「设置 → 流媒体」添加并启用一台服务器，保存后回到这里即可浏览。</div>' +
        '<button class="btn pri" id=remoteGoSet>去设置里配置</button>' +
        '<button class="btn" id=remoteRetry style="margin-left:8px">重试</button></div>';
      if (D('remoteGoSet')) D('remoteGoSet').onclick = function () { openSettingsTab('stream'); };
      if (D('remoteRetry')) D('remoteRetry').onclick = function () { loadRemote(id || ''); };
      return;
    }
    S.remote = j.items || []; S.rpath = id || '';
    head('流媒体', S.remote.length + ' 项', '');
    var h = '';
    if (id) h += '<div class="row rowdir" data-r=-1><span class=ico>&#128193;</span><span class=nm>返回上一级</span></div>';
    S.remote.forEach(function (it, i) {
      h += '<div class="row' + (it.dir ? ' rowdir' : '') + '" data-r=' + i + '>' +
           '<span class=ico>' + (it.dir ? '&#128193;' : '&#127925;') + '</span>' +
           '<span class=nm>' + esc(it.t) + '</span><span class=meta>' + esc(it.dir ? '' : (it.ar || '')) + '</span></div>';
    });
    if (!S.remote.length) h = '<div class=empty>此目录为空<br><span style="font-size:11px">先在右侧「设置」里填服务器地址并保存</span></div>';
    D('list').innerHTML = h;
    Array.prototype.forEach.call(D('list').children, function (e) {
      if (e.dataset.r === undefined) return;
      var i = +e.dataset.r;
      e.onclick = function () {
        if (i < 0) loadRemote(S.rpath.split('/').slice(0, -1).join('/'));
        else { var it = S.remote[i]; if (it.dir) loadRemote(it.id); else playRemote(it); }
      };
    });
  }).catch(function (e) { D('list').innerHTML = '<div class=empty>' + esc(e) + '</div>'; });
}

/* ---------------- 流媒体服务器（多台；用户 261024-01 #5） ----------------
   后端契约（tools/rtaweb.cpp）：
     GET  /api/src/config  → {servers:[{id,name,kind,base,user,hasPass,active}], active}
     POST /api/src/config   action=add|update|remove|active（update 时 password 留空 = 保持原密码）
     POST /api/src/ping     表单里还没保存的配置也能先测；?id=N 测已保存的某台
   密码红线：GET 不回明文，界面也不回填；编辑时留空即不改。 */
var SRC = { servers: [], active: '', editing: '' };
var SRC_FORM_OPEN = false;

function srcKindName(k) { return k === 'emby' ? 'Emby' : 'Navidrome / Subsonic'; }
function srcFormMsg(t, ok) {
  var e = D('sp_src_fmsg'); if (!e) return;
  e.textContent = t || '';
  e.style.color = (ok === undefined) ? '' : (ok ? 'var(--ok-text)' : 'var(--danger)');
}
function srcShowForm(open, s) {
  var box = D('sp_src_form'); if (!box) return;
  SRC_FORM_OPEN = !!open;
  box.style.display = open ? '' : 'none';
  if (!open) { SRC.editing = ''; return; }
  SRC.editing = s ? String(s.id) : '';
  var ft = D('sp_src_ftitle');
  if (ft) ft.textContent = s ? ('编辑服务器 · ' + (s.name || s.base || '')) : '添加服务器';
  D('sp_src_name').value = s ? (s.name || '') : '';
  D('sp_src_kind').value = s ? (s.kind || 'subsonic') : 'subsonic';
  D('sp_src_base').value = s ? (s.base || '') : '';
  D('sp_src_user').value = s ? (s.user || '') : '';
  D('sp_src_pass').value = '';
  D('sp_src_pass').placeholder = s ? '留空 = 保持原密码' : '密码';
  srcFormMsg(s ? ('正在编辑「' + (s.name || s.base) + '」') : '');
  var f = D('sp_src_name'); if (f) f.focus();
}
function srcFormBody() {
  return 'kind=' + encodeURIComponent(D('sp_src_kind').value) +
         '&name=' + encodeURIComponent((D('sp_src_name').value || '').trim()) +
         '&base=' + encodeURIComponent((D('sp_src_base').value || '').trim()) +
         '&user=' + encodeURIComponent((D('sp_src_user').value || '').trim()) +
         '&pass=' + encodeURIComponent(D('sp_src_pass').value || '');
}
function renderSrcList() {
  var box = D('sp_src_list'); if (!box) return;
  var list = SRC.servers || [];
  if (!list.length) {
    box.innerHTML = '<div class=srvempty>还没有流媒体服务器 —— 点上面的「添加服务器」</div>';
    return;
  }
  var h = '';
  list.forEach(function (s) {
    var act = !!s.active;
    h += '<div class="srvrow' + (act ? ' on' : '') + '" data-id="' + esc(s.id) + '">'
       + '<span class=srvdots></span>'
       + '<div class=srvmain><div class=srvname><span class=nm>' + esc(s.name || s.base) + '</span>'
       + '<span class="srvtag kind">' + esc(srcKindName(s.kind)) + '</span>'
       + (act ? '<span class="srvtag on">已启用</span>' : '') + '</div>'
       + '<div class=srvurl>' + esc(s.base || '') + (s.user ? ' · ' + esc(s.user) : '') + '</div></div>'
       + '<div class=srvacts>'
       + (act ? '' : '<button class="srvbtn pri" data-a=on>启用</button>')
       + '<button class=srvbtn data-a=test>测试</button>'
       + '<button class=srvbtn data-a=edit>编辑</button>'
       + '<button class="srvbtn del" data-a=del>删除</button>'
       + '</div></div>';
  });
  box.innerHTML = h;
  Array.prototype.forEach.call(box.querySelectorAll('.srvbtn'), function (b) {
    b.onclick = function () {
      var row = b.closest('.srvrow'); if (!row) return;
      var id = row.dataset.id, s = null;
      (SRC.servers || []).forEach(function (x) { if (String(x.id) === id) s = x; });
      var a = b.dataset.a;
      if (a === 'edit') { srcShowForm(true, s); return; }
      if (a === 'test') { srcTestSaved(id, b); return; }
      if (a === 'on') {
        api('/api/src/config', 'action=active&id=' + encodeURIComponent(id)).then(function (j) {
          if (!j || !j.ok) { toast('启用失败：' + ((j && j.error) || '未知错误')); return; }
          toast('已启用「' + (s ? (s.name || s.base) : id) + '」');
          loadSrcConfig();
        }).catch(function () { toast('启用失败：服务没响应'); });
        return;
      }
      if (a === 'del') {
        if (!confirm('删除服务器「' + (s ? (s.name || s.base) : id) + '」？只删配置，不动已下载缓存。')) return;
        api('/api/src/config', 'action=remove&id=' + encodeURIComponent(id)).then(function (j) {
          if (!j || !j.ok) { toast('删除失败：' + ((j && j.error) || '未知错误')); return; }
          if (String(SRC.editing) === String(id)) srcShowForm(false);
          toast('已删除');
          loadSrcConfig();
        }).catch(function () { toast('删除失败：服务没响应'); });
      }
    };
  });
}
function loadSrcConfig() {
  if (!D('sp_src_list')) return;    // 流媒体页没渲染就不取
  return api('/api/src/config').then(function (j) {
    if (!j || !j.ok) return;
    SRC.servers = j.servers || [];
    SRC.active = j.active || '';
    renderSrcList();
  }).catch(function () { });
}
function bindSrcPage() {
  if (D('sp_src_add')) D('sp_src_add').onclick = function () { srcShowForm(true, null); };
  if (D('sp_src_cancel')) D('sp_src_cancel').onclick = function () { srcShowForm(false); };
  if (D('sp_src_save')) D('sp_src_save').onclick = srcSave;
  if (D('sp_src_testform')) D('sp_src_testform').onclick = srcTestForm;
  if (D('sp_upnp')) D('sp_upnp').onclick = discoverDlna;
  ['sp_src_base', 'sp_src_user'].forEach(function (id) {
    var e = D(id);
    if (e) e.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') srcSave(); });
  });
}
function srcSave() {
  if (!SRC_FORM_OPEN) return;
  var base = (D('sp_src_base').value || '').trim();
  var user = (D('sp_src_user').value || '').trim();
  if (!base) { srcFormMsg('请填写服务器地址', false); return; }
  if (base.indexOf('http://') !== 0 && base.indexOf('https://') !== 0) {
    srcFormMsg('地址要以 http:// 或 https:// 开头', false); return;
  }
  if (!user) { srcFormMsg('请填写用户名', false); return; }
  var body = 'action=' + (SRC.editing ? 'update' : 'add') +
             (SRC.editing ? ('&id=' + encodeURIComponent(SRC.editing)) : '') + '&' + srcFormBody();
  srcFormMsg('保存中…');
  api('/api/src/config', body).then(function (j) {
    if (!j || !j.ok) { srcFormMsg('保存失败：' + ((j && j.error) || '未知错误'), false); return; }
    var wasEdit = !!SRC.editing;
    srcShowForm(false);
    toast(wasEdit ? '服务器已更新' : '服务器已添加');
    loadSrcConfig();
  }).catch(function () { srcFormMsg('保存失败：服务没响应', false); });
}
function srcTestForm() {
  srcFormMsg('测试中…');
  api('/api/src/ping', srcFormBody()).then(function (j) {
    srcFormMsg(j && j.ok ? '\u2713 连接成功' : ('\u2717 ' + ((j && j.error) || '失败')), !!(j && j.ok));
  }).catch(function () { srcFormMsg('\u2717 服务没响应', false); });
}
function srcTestSaved(id, btn) {
  if (btn) { btn.disabled = true; btn.textContent = '测试中…'; }
  api('/api/src/ping?id=' + encodeURIComponent(id)).then(function (j) {
    if (btn) { btn.disabled = false; btn.textContent = '测试'; }
    toast(j && j.ok ? '连接成功' : ('连接失败：' + ((j && j.error) || '未知错误')));
  }).catch(function () {
    if (btn) { btn.disabled = false; btn.textContent = '测试'; }
    toast('连接失败：服务没响应');
  });
}
function discoverDlna() {
  var m = D('sp_upnpmsg'); if (!m) return;
  m.textContent = '正在搜索…';
  api('/api/upnp').then(function (j) {
    var devs = (j && j.devices) || [];
    if (!devs.length) { m.textContent = '没发现 DLNA 渲染器'; return; }
    m.innerHTML = devs.map(function (d) { return esc(d.name) + ' — ' + esc(d.host) + ':' + esc(d.port); }).join('<br>');
  }).catch(function () { m.textContent = '搜索失败：服务没响应'; });
}

/* ---------------- 视图切换 ---------------- */
// 2026-10-23（合并 r4-shell 的"EQ 移入设置页" + r4-np 的"单曲页 EQ 芯片"）：
// 以前 EQ 是一级视图（setView('eq') + loadEqView()），现在它是设置页里的一个页签。
// 统一走这个入口，别再直接 setView('eq')（那个视图已经不存在）。
function openSettingsTab(g) {
  setView('settings');
  var b = document.querySelector('#setpage .stab[data-g=' + (g || 'eq') + ']');
  if (b) b.click();
  var sp = document.getElementById('setpage');
  if (sp && sp.scrollTo) sp.scrollTo(0, 0);
}
function setView(v) {
  S.view = v;
  // 2026-10-23（uicheck 复现的真实 bug）：全局搜索框有 260ms 防抖，输入后立刻点左侧别的导航，
  // 定时器仍会触发 setView('tracks')+loadTracks，把用户刚切的页面顶掉（队列页就是这么被换掉的）。
  // 规则：切换视图即取消未触发的搜索，"最后一次用户操作"胜出。
  if (typeof searchTimer !== 'undefined' && searchTimer) { clearTimeout(searchTimer); searchTimer = 0; }
  // 作品页入口收进单曲页后，仍在内部使用 works 视图；离开 works 时清掉"从正在播放返回"的标记
  if (v !== 'works') S.worksFrom = '';
  Array.prototype.forEach.call(document.querySelectorAll('.nav'), function (e) {
    e.classList.toggle('on', e.dataset.v === v || (v === 'artist' && e.dataset.v === 'artists') || (v === 'work' && e.dataset.v === 'works'));
  });
  var isSet = (v === 'settings');
  // 设置页占满整屏：右栏（队列/歌词）在这里没有意义，直接藏掉。
  // 走 #app.noq 这套已有的网格规则，否则网格会留一个空列。
  // 2026-10-23（UI 评审 #8）：播放队列页自己就是队列，右侧抽屉再显示一份同样的队列是重复信息
  D('app').classList.toggle('noq', isSet || S.queueHidden || v === 'queue');
  if (isSet || v === 'queue') D('app').classList.remove('qopen');
  D('app').classList.toggle('setmode', isSet);   // 设置页隐藏 crumb，页签自己吸顶
  applyRTab(isSet);
  if (typeof syncRightDrawerBtn === 'function') setTimeout(syncRightDrawerBtn, 0);
  if (D('setpage')) D('setpage').classList.toggle('on', isSet);
  // 2026-10-23 用户反馈「切到作品栏后无法切回其它栏位」：干净环境下三种路径都复现不出来，
  // 但这里确实存在一类残留风险 —— 只要有任何路径把 #list 置为 display:none（设置页就会），
  // 离开设置页时若不显式恢复，视图就会「看起来卡住/空白」。此处按目标视图**强制**设定，
  // 不再依赖「上一个视图是什么」。
  if (D('list')) D('list').style.display = isSet ? 'none' : '';
  if (!isSet && D('scanbar')) D('scanbar').style.display = S.scanning ? '' : 'none';
  if (isSet) { head('设置', '所有参数都在这里，改完点「保存」', ''); renderSettingsPage(); }
  else if (D('scanbar')) D('scanbar').style.display = S.scanning ? '' : 'none';
}

Array.prototype.forEach.call(document.querySelectorAll('.nav'), function (e) {
  if (e.dataset.d) return;
  e.onclick = function () {
    var v = e.dataset.v;
    if (!v) return;
    setView(v);
    if (v === 'albums') loadAlbums('');
    else if (v === 'artists') loadArtists();
    else if (v === 'tracks') loadTracks('');
    else if (v === 'files') loadFiles(S.dir || '');
    else if (v === 'remote') loadRemote('');
    else if (v === 'queue') { renderQueuePage(); }
    else if (v === 'recent') loadRecent();
    else if (v === 'favs') loadFavs();
    else if (v === 'sq') renderSavedQueuePage(S.sqName);
    // 2026-10-25：音频工作站独立页（原来挤在专辑空态里，导入音乐后就看不到）
    else if (v === 'station') { renderStation(); }
  };
});

/* ---------------- 搜索（全局） ---------------- */
var searchTimer = 0;
function updateSearchClearBtn() {
  var btn = D('qClear');
  if (!btn) return;
  btn.style.display = (D('q') && D('q').value) ? '' : 'none';
}
function dispatchSearchQuery(v) {
  var cur = S.view;
  if (cur === 'albums') {
    loadAlbums(v);
  } else if (cur === 'artists') {
    loadArtists(v);
  } else if (cur === 'tracks') {
    loadTracks(v);
  } else {
    // 其它视图（如 files、recent、queue、station、settings、album、artist、works 等）：
    // 若用户主动发起搜索，默认转入曲目搜索（setView('tracks') + loadTracks(v)），
    // 保证在非库列表页（如设置页、文件页）仍能正常执行全局搜索。
    setView('tracks');
    loadTracks(v);
  }
}
function clearSearchQuery() {
  D('q').value = '';
  updateSearchClearBtn();
  var cur = S.view;
  if (cur === 'albums') {
    loadAlbums('');
  } else if (cur === 'artists') {
    loadArtists('');
  } else if (cur === 'tracks') {
    loadTracks('');
  } else {
    loadAlbums('');
  }
}
if (D('qClear')) {
  D('qClear').onclick = function () {
    clearSearchQuery();
    D('q').focus();
  };
}
D('q').oninput = function () {
  var v = this.value.trim();
  updateSearchClearBtn();
  clearTimeout(searchTimer);
  searchTimer = setTimeout(function () {
    if (v) {
      dispatchSearchQuery(v);
    } else {
      clearSearchQuery();
    }
  }, 260);
};
D('q').onkeydown = function (e) {
  if (e.key === 'Escape') {
    clearSearchQuery();
  }
  if (e.key === 'Enter' && S.view === 'tracks') {
    var first = document.querySelector('#list .trow');
    if (first) first.click();
  }
};

/* ---------------- 控件 ---------------- */
D('bStop').onclick = function () { api('/api/stop', '').then(function(){ loadQ(); }); };
D('bNext').onclick = function () { api('/api/skip?dir=1', '').then(loadQ); };
D('bPrev').onclick = function () { api('/api/skip?dir=-1', '').then(loadQ); };
function playOrPause() {
  if (!S.playing) {
    // 停止之后点播放：必须重新起播并把最新参数（采样率/滤波器/位深…）一起下发，
    // 只发 /api/pause 是不会有任何反应的（本轮用户报的就是这个）。
    var f = (S.q && S.q.items && S.q.items.length) ? S.q.items[S.q.index || 0] : S.lastCur;
    if (f) { playPath(f); return; }
    toast('队列是空的，先拖一首歌进来');
    return;
  }
  var nextPaused = !S.paused;
  S.paused = nextPaused;
  api('/api/pause?on=' + (nextPaused ? 1 : 0), '');
  if (D('npIcP')) D('npIcP').setAttribute('d', nextPaused ? 'M8 5l12 7-12 7z' : 'M7 5h4v14H7zM13 5h4v14h-4z');
}
D('bPause').onclick = playOrPause;
D('qclr').onclick = function () { api('/api/clear', '').then(function () { loadQ(); if (S.view === 'queue') renderQueuePage(); }); };
D('npOpen').onclick = openNowPlaying;
D('npClose').onclick = closeNowPlaying;
// 资料抽屉（261024-01 #3b ③）：关闭按钮 / 点遮罩 / 再点同一标签 都能收起
if (D('npDataClose')) D('npDataClose').onclick = function () { npDrawerClose(); npDataRenderBody(); };
if (D('npDrawerBg')) D('npDrawerBg').onclick = function () { npDrawerClose(); npDataRenderBody(); };
// 整页里的播放控件：直接复用底栏那套动作，避免两处逻辑漂移
D('npPrev').onclick = function () { api('/api/skip?dir=-1', '').then(loadQ); };
D('npNext').onclick = function () { api('/api/skip?dir=1', '').then(loadQ); };
D('npPlay').onclick = playOrPause;
D('npStop').onclick = function () { api('/api/stop', '').then(loadQ); };
// ---- 循环方式：整页按钮与底栏 #bRep、设置页 #sp_rep 共用 #sRep 的值（唯一真相源）----
// 为什么不自己存一份：历史上"两处各有一份"必然不一致（HANDOVER §4.5 的规矩）。
// 2026-10-27（R-4）：四态播放模式（0=顺序 1=列表循环 2=单曲循环 3=随机）。
// 图标/aria-label **随模式变化** —— 只改颜色不改图标是明令禁止的假修
// （用户看不出当前是哪种模式，等于没修）。
var REP_META = [
  { name: '顺序播放', aria: '顺序播放（播到末尾停止）', color: '',          one: false },
  { name: '列表循环', aria: '列表循环（播到末尾回到第一首）', color: 'var(--acc-text)', one: false },
  { name: '单曲循环', aria: '单曲循环（重复当前这首）', color: 'var(--acc-text)', one: true },
  { name: '随机播放', aria: '随机播放（不重复当前曲）', color: 'var(--acc-text)', one: false }
];
function repMeta(v) {
  v = parseInt(v, 10);
  if (!(v >= 0 && v <= 3)) v = 0;
  return REP_META[v];
}
function applyRep(v) {
  v = parseInt(v, 10);
  if (!(v >= 0 && v <= 3)) v = 0;
  var m = REP_META[v];
  // 「1」角标只在单曲循环时显示
  ['repOne', 'npRepOne'].forEach(function (id) {
    var e = D(id); if (e) e.style.display = m.one ? '' : 'none';
  });
  ['bRep', 'npRep'].forEach(function (id) {
    var e = D(id);
    if (!e) return;
    e.style.color = m.color;
    e.setAttribute('aria-label', m.aria);
    e.title = m.aria;
    // 图标随模式换：顺序=直线箭头 / 列表循环=环形箭头 / 单曲循环=环形+1 / 随机=交叉箭头
    var svg = e.querySelector('svg');
    if (svg) svg.innerHTML = REP_ICON[v];
  });
}
// 四种模式的图标路径（24x24 viewBox，与既有图标同风格：stroke=currentColor、无填充）
var REP_ICON = [
  '<path d="M3 6h11M3 12h11M3 18h11"/><path d="M17 9l4 3-4 3"/>',
  '<path d="M17 2l4 4-4 4"/><path d="M3 11v-1a4 4 0 014-4h14"/><path d="M7 22l-4-4 4-4"/><path d="M21 13v1a4 4 0 01-4 4H3"/>',
  '<path d="M17 2l4 4-4 4"/><path d="M3 11v-1a4 4 0 014-4h14"/><path d="M7 22l-4-4 4-4"/><path d="M21 13v1a4 4 0 01-4 4H3"/>',
  '<path d="M16 3h5v5"/><path d="M4 20L21 3"/><path d="M21 16v5h-5"/><path d="M15 15l6 6"/><path d="M4 4l5 5"/>'
];
function cycleRep() {
  var cur = parseInt(D('sRep').value, 10) || 0;
  var next = (cur + 1) % 4;            // R-4：四态
  D('sRep').value = String(next);
  api('/api/playmode?mode=' + next, '');   // 单一真相源端点
  applyRep(next);
  var sp = D('sp_rep');            // 设置页渲染中时一起同步（它只是同一值的镜像）
  if (sp) sp.value = String(next);
  toast('播放模式：' + REP_META[next].name);
  return next;
}
// ---- 音量：整页滑块是 #vol 的镜像，两边都只改 S.vol + 下发 /api/volume ----
// setVol() 是唯一入口（键盘 ↑↓ 也用它）；syncVolUi() 把状态刷到所有镜像控件。
/* ============ 音量曲线 v3（2026-10-25 二次修正：跟随实时增减 + 最低位真静音）============
 *
 * v1（线性 dB 刻度 min=-60..0）：拖到中间就没声音（中点 -30 dB 只有 3% 振幅）。
 * v2（平方曲线 db = -60·(1-p)²）：中点 17.8% 振幅，但仍有两个问题 ——
 *    ① 底端 p→0 时 db 只到 -60 dB = **0.1% 振幅**，不是静音；后端把它当"还有一点点音量"，
 *       用户把滑块拉到最左端，耳朵贴在喇叭上仍能听到残响。
 *    ② 低端 1/4 行程几乎全在 -33.8…-60 dB 之间，耳朵分辨不出差别 ⟹ 观感是
 *       "低音区拖了不动、要拖到很后面才突然变大"，也就是用户说的
 *       「音量不跟着音量条实时增减」。
 *
 * v3（幂次曲线 + 独立静音档）：按**人耳振幅感知**给曲线，gain = p^2.5 ⟺ db = 50·log10(p)，
 *     等价写法（pos > 5 时）db = -55·(1-p)^1.6；pos ≤ 5（≤0.5% 行程）直接 -120 dB。
 *       p=1.00 →  -0.0 dB (100.0% 振幅)
 *       p=0.75 →  -6.0 dB ( 50.1% 振幅，正好减半 ⟹ 拖动"听感线性"的锚点)
 *       p=0.50 → -18.1 dB ( 12.4% 振幅，中等偏轻，不是死区)
 *       p=0.25 → -34.7 dB (  1.8% 振幅，轻柔背景音，仍清晰可闻)
 *       p=0.05 → -50.7 dB (  0.3% 振幅，极微弱)
 *       p≤0.005→-120.0 dB (  0.0% 振幅 ⟹ 后端 set_gain(0) **真静音**)
 *     每一档都能听出区别（相邻档的振幅比约为 1.6~1.9 倍，接近人耳"刚可分辨"的响度台阶），
 *     所以拖动时音量是**连续跟着走**的，不会出现"拖了半天没反应、最后一格爆响"。
 *
 * 为什么静音档用 -120 dB 而不是把曲线压到 -55：后端 MacSink::set_live_gain_db
 *   （tools/rtaweb.cpp）把 ≤ -120 dB 映射成线性增益 **0**；-55 dB 仍等于 0.18% 振幅，
 *   不是静音。所以"最低位置真静音"必须显式发 -120 dB，不能只靠曲线到底。
 */
var VOL_MIN_DB = -55.0;      // 曲线的 dB 下限（不是静音位）
var VOL_SILENT_DB = -120.0;  // 真静音（后端把 ≤-120 dB 映射成增益 0）
var VOL_SILENT_POS = 5;      // 位置 ≤ 5（0.5% 行程）判定为静音档
function volPosToDb(pos) {
  // pos: 0..1000（滑块位置）→ dB
  var v = parseFloat(pos);
  if (!isFinite(v)) return VOL_SILENT_DB;
  var p = Math.max(0, Math.min(1000, v)) / 1000;
  if (p <= VOL_SILENT_POS / 1000) return VOL_SILENT_DB;   // 最左端 = 真静音（增益 0）
  return -Math.abs(VOL_MIN_DB) * Math.pow(1 - p, 1.6);
}
function volDbToPos(db) {
  // dB → 滑块位置（0..1000）。v3 反函数：p = 1000 · (1 - (-db/55)^(1/1.6))
  // 与 volPosToDb 严格互逆（pos=6..1000 往返误差 0，实测见判据 2）。
  var d = parseFloat(db);
  if (!isFinite(d) || d >= 0) return 1000;
  if (d <= VOL_MIN_DB) return 0;     // ≤ -55 dB（含 -120 静音档）全部落在最左端
  return Math.round(1000 * (1 - Math.pow(-d / Math.abs(VOL_MIN_DB), 1.0 / 1.6)));
}
/* dB 归一化：把"落在静音档里"的值统一收成真静音 -120。
 *
 * 为什么必须有：曲线只在 pos≥6 上有定义，而外部来源会给出更低的值（老配置里存的是旧曲线的
 * -60 下限、键盘 ↓ 逐格减、以及任何 ≤-55 的脏值）。若原样保留，会同时出现两个谎：
 *   ① 滑块被 volDbToPos 摆到位置 0（看起来是静音），标签却写 -60.0 dB；
 *   ② 后端收到 -60 dB ⟹ 线性增益 0.001（0.1% 振幅），**不是静音**，用户贴耳仍能听到。
 *
 * 判据用**滑块位置**而不是 dB 阈值 —— 因为位置才是界面给用户看的那个"真相"：
 *   volDbToPos 会把 (-55, -54.47) 这一小段 dB 也映射到位置 0..5（静音档），
 *   若按 dB 阈值判断（只收 ≤-55），这段会漏网 ⟹ 滑块显示「静音」而后端还在放 0.18% 残响。
 *   改成「算出的位置落在静音档就收成静音」后，位置 / 标签 / 后端增益三者**按构造**一致：
 *       volNormalize(db) === volPosToDb(volDbToPos(db))   （对 [-120,0] 全域成立，见判据 2e）
 */
function volNormalize(db) {
  var d = parseFloat(db);
  if (!isFinite(d)) return 0;              // 脏值兜底 0 dB（不静音，避免"随机变哑"）
  if (d >= 0) return 0;                    // 不允许正向增益（>0 dB 必削波）
  if (volDbToPos(d) <= VOL_SILENT_POS) return VOL_SILENT_DB;   // 落在静音档 ⟹ 真静音
  return d;
}

/* 实时音量下发：in-flight 单通道「最新值接力」，既零延迟又零堆积。
 *
 * 2026-10-25 用户报「音量不跟着音量条实时变，停下来才跳变」。根因不是后端慢，而是
 * 前端每 1 像素 oninput 就无条件 api('/api/volume?...') 发一次 fetch：快速拖 100 像素
 * 就是 100 个并发请求排队（WKWebView 自定义 scheme + 单线程后端），后面的请求排队滞后
 * 几十~几百毫秒才到达，听起来就是"拖动时不动、松手才跳到最终值"。
 *
 * 为什么不用 setTimeout 防抖：防抖 = 故意延迟首发，那正好是"拖动时音量不跟手"本身。
 * 这里改成「在途单通道 + 最新值覆盖」：
 *   ① 第 1 次调用立刻发请求（0 ms 首发延迟，跟手）；
 *   ② 在途期间再来的 100 次只覆盖 _volPendingDb，**不产生并发请求**；
 *   ③ 请求一回来就立刻把当时最新的值发出去（跳过中间所有过时值，不排队滞后）；
 *   ④ 任意时刻最多 1 个在途请求 ⟹ 通道永不被自己堵死。
 * 丢中间值是安全的：音量是**绝对值**语义（后端 ps.volDb.store(db)），最后一个值必然覆盖前面的。
 */
var _volInFlight = false;
var _volPendingDb = null;
function sendVolRealtime(db) {
  var d = parseFloat(db);
  if (!isFinite(d)) return;
  _volPendingDb = d;
  if (_volInFlight) return;          // 在途：只留最新值，不排队
  _volInFlight = true;
  var sendNext = function () {
    if (_volPendingDb === null) { _volInFlight = false; return; }
    var cur = _volPendingDb;
    _volPendingDb = null;
    // api() 契约：永不 reject（失败也返回兜底对象）⟹ 用同一个回调收尾即可，
    // 但两个分支都写 sendNext 是为了将来 api() 契约变化时也不会卡死 _volInFlight。
    api('/api/volume?db=' + cur.toFixed(1), '').then(function (j) {
      if (j && j.ok === false && j.error) toast(j.error);
      sendNext();
    }, sendNext);
  };
  sendNext();
}

/* 拖动锁：用户正在拖某个滑块时，禁止 syncVolUi 回写它的 value。
 *
 * 2026-10-25 用户报「拖动的时候会抖动」。根因：
 *   /api/status 的 400ms 轮询在单曲页每轮都调 syncVolUi()，
 *   而 syncVolUi 会把 S.vol 写回**所有**滑块（包括正在拖的那个）。
 *   拖动中 value 被外部改写 ⟹ 滑块位置与鼠标打架 ⟹ 视觉抖动。
 * 修法：拖动期间记下是哪个滑块在拖，syncVolUi 跳过它。 */
var VOL_DRAGGING = null;
function syncVolUi() {
  // 滑块是**位置刻度**（0..1000），真相源是 S.vol（dB）⟹ 每次刷新都要反向换算。
  // 正在拖动的那个滑块**跳过**：否则 400ms 轮询会把 value 写回去跟鼠标打架（抖动根因）。
  var pos = volDbToPos(S.vol);
  ['vol', 'npVol'].forEach(function (id) {
    if (VOL_DRAGGING === id) return;          // ← 拖动中不回写，避免抖动
    var e = D(id);
    if (e && Math.abs(parseFloat(e.value) - pos) > 1) e.value = pos;
  });
  var lab = D('npVolLab');
  if (lab) {
    // 2026-10-25（DoP 音量保护配套）：DSD/DoP 输出时软件音量被强制 0 dB（保护 DoP 标记字节，
    // 否则 DAC 会当普通 PCM 播、输出白噪音）。数字照常显示用户请求值，但必须如实标注
    // 「不生效」—— 否则用户拉音量条看到数字变、实际不变，会以为又是 bug（那正是本轮修的东西）。
    var dopMode = (typeof outModeOf === 'function') && outModeOf() === 'dsd';
    // 2026-10-25（v3）：静音档显示「静音」而不是「-120.0 dB」。
    // 为什么：-120 dB 对用户是个无意义的数字（后端在这个值上直接 set_gain(0)），
    // 而「静音」正是他拉到底时想要的结果，标签必须说结果而不是说内部编码。
    // 阈值 -59.5：v3 曲线在 pos=6 时约 -54.7 dB，pos<=5 才是 -120 ⟹ 用 -59.5 只圈住静音档，
    // 不会把"很轻但能听见"的位置误标成静音（铁律 3：判据要能证明真东西）。
    var hasVol = (typeof S.vol === 'number') && isFinite(S.vol);
    var silent = hasVol && S.vol <= -59.5;
    lab.textContent = (!hasVol ? '—' : (silent ? '静音' : (S.vol > 0 ? '+' : '') + S.vol.toFixed(1) + ' dB')) +
                      (dopMode ? '（DSD 输出：不生效）' : '');
    lab.title = dopMode
      ? 'DSD / DoP 输出时软件音量被强制为 0 dB：任何增益都会破坏 DoP 标记字节（0x05/0xFA），导致 DAC 把 DSD 当普通 PCM 播放、输出刺耳白噪音。请在 DAC 端调音量。'
      : (silent ? '音量条已拉到最左端：增益 0（真静音）' : '');
  }
}
if (D('npRep')) D('npRep').onclick = cycleRep;
if (D('npVol')) {
  // 拖动锁的建立/释放：pointerdown 与 change 都能覆盖（键盘方向键改值时没有 pointerdown，
  // 但那种情况不涉及抖动，照常同步即可）。
  D('npVol').addEventListener('pointerdown', function () { VOL_DRAGGING = 'npVol'; });
  D('npVol').addEventListener('pointerup', function () { VOL_DRAGGING = null; syncVolUi(); });
  D('npVol').addEventListener('pointercancel', function () { VOL_DRAGGING = null; });
  D('npVol').oninput = function () {
    // 滑块给的是**位置**（0..1000），必须经曲线换算成 dB —— 直接当 dB 用就是旧 bug
    // （位置 500 会被当成 +500 dB，clamp 到 0 dB 满幅，用户会听到音量"爆掉"）。
    S.vol = volPosToDb(parseFloat(this.value));
    syncVolUi();                               // 镜像到另一个滑块（自己会被 VOL_DRAGGING 跳过）
    // 2026-10-25（v3）：走 in-flight 单通道接力 —— 每像素发一个 fetch 会堆 100 个请求，
    // 后端单线程排队滞后 ⟹ 用户听到的是"停下来才跳变"。见 sendVolRealtime 的注释。
    sendVolRealtime(S.vol);
  };
  D('npVol').addEventListener('change', function () {
    VOL_DRAGGING = null;
    syncVolUi();
    saveSettings();
  });
}
D('npSeek').onclick = function (ev) {
  if (!S.dur) return;
  var r = this.getBoundingClientRect();
  doSeek((ev.clientX - r.left) / Math.max(1, r.width));
};
function isRightDrawerVisible() {
  var r = D('right');
  if (!r) return false;
  try { return window.getComputedStyle(r).display !== 'none'; } catch (e) { return false; }
}
function syncRightDrawerBtn() {
  var b = D('tq');
  if (b) b.classList.toggle('on', isRightDrawerVisible());
}
D('tq').onclick = function () {
  if (S.view === 'settings' || S.view === 'queue') {
    setView('queue');
    renderQueuePage();
    return;
  }
  var vis = isRightDrawerVisible();
  if (vis) {
    S.queueHidden = true;
    D('app').classList.add('noq');
    D('app').classList.remove('qopen');
  } else {
    S.queueHidden = false;
    D('app').classList.remove('noq');
    D('app').classList.add('qopen');
  }
  syncRightDrawerBtn();
};
if (D('bRoomWiz')) D('bRoomWiz').onclick = rcWizard;   // R-1：先出确认弹窗，绝不直接开播
D('sRep').onchange = function () { api('/api/playmode?mode=' + this.value, ''); applyRep(this.value); };
D('sShuf').onchange = function () { api('/api/shuffle?on=' + (this.checked ? 1 : 0), '').then(loadQ); };
// 底栏滑块同样是**位置刻度**（0..1000）→ 曲线换算成 dB。
D('vol').addEventListener('pointerdown', function () { VOL_DRAGGING = 'vol'; });
D('vol').addEventListener('pointerup', function () { VOL_DRAGGING = null; syncVolUi(); });
D('vol').addEventListener('pointercancel', function () { VOL_DRAGGING = null; });
D('vol').oninput = function () {
  S.vol = volPosToDb(parseFloat(this.value));
  if (typeof syncVolUi === 'function') syncVolUi();   // 整页滑块是镜像，必须一起动（自己会跳过）
  sendVolRealtime(S.vol);   // 播放中即时生效，不必重开（零堆积，见 sendVolRealtime）
};
D('sLoud').onchange = function () { S.loud = this.checked; saveSettings(); };
// 参数类控件改动后自动落盘（下次启动还在）
['sRate','sFilt','sFiltNx','sShap','sDSD','sIsp','s2s','sBuf'].forEach(function (id) {
  var e = D(id); if (!e) return;
  e.addEventListener('change', saveSettings);
});
D('vol').addEventListener('change', saveSettings);
// 2026-10-24 #5：旧的「流媒体服务器」单表单（srcSave/saveSrc）已删除，改由设置页「流媒体」页签的
// bindSrcPage() 绑定（多服务器列表）。这里的隐藏快捷面板不保留副本。
D('bUpnp').onclick = function () {
  D('upnpList').innerHTML = '<div style="font-size:11px;color:#5b6478">正在搜索（约 2 秒）…</div>';
  api('/api/upnp').then(function (j) {
    // 断线时报「没发现 DLNA 渲染器」是错的结论（用户会去查数播），必须区分"没发现"和"没问到"。
    if (j && j._err) { D('upnpList').innerHTML = '<div style="font-size:11px;color:#e8654b">搜索失败：后端无响应</div>'; return; }
    if (!j.devices || !j.devices.length) {
      D('upnpList').innerHTML = '<div style="font-size:11px;color:#5b6478">没发现 DLNA 渲染器</div>';
      return;
    }
    var h = '';
    j.devices.forEach(function (d) {
      h += '<div class=rootline><span title="' + esc(d.loc) + '">' + esc(d.name) +
           (d.model ? '  ·  ' + esc(d.model) : '') + '</span><span style="color:#5b6478;font-size:10.5px">' + esc(d.host) + ':' + esc(d.port) + '</span></div>';
    });
    h += '<div style="font-size:10.5px;color:#5b6478;margin-top:6px;line-height:1.7">只做发现。DLNA 投放会经过对方的重采样，' +
         '无法保证逐位，所以不作为主链路。</div>';
    D('upnpList').innerHTML = h;
  }).catch(function () { D('upnpList').innerHTML = '<div style="font-size:11px;color:#e8654b">搜索失败</div>'; });
};
D('bNet').onclick = function () {
  api('/api/net').then(function (j) {
    // 兜底对象没有 port：不拦的话这里会渲染成「http://127.0.0.1:undefined/」，比空白更误导。
    if (j && j._err) { D('netMsg').textContent = '网络信息读取失败，稍后重试'; return; }
    D('netMsg').innerHTML = '本机：http://127.0.0.1:' + j.port + '/<br>' +
      (j.lan ? ('局域网：http://' + esc(j.ip) + ':' + j.port + '/（已开启）')
             : ('局域网访问：未开启（用 <code>--lan</code> 启动即可以 http://' + esc(j.ip) + ':' + j.port + '/ 访问）'));
  });
};
D('bLyric').onclick = function () {
  if (!isRightDrawerVisible()) {
    S.queueHidden = false;
    D('app').classList.remove('noq');
    D('app').classList.add('qopen');
    setRTab('l');
  } else {
    setRTab(RTAB === 'l' ? 'q' : 'l');
  }
  syncRightDrawerBtn();
};
D('bChain').onclick = showChain;
D('bHelp').onclick = function () {
  D('mtitle').textContent = '快捷键与提示';
  D('modal').classList.add('on');
  var rows = [
    ['空格', '暂停 / 继续'], ['← →', '后退 / 前进 5 秒'], ['↑ ↓', '音量增减 1 dB'],
    ['n / p', '下一首 / 上一首'], ['s', '停止'], ['l', '歌词'], ['i', '信号链'],
    ['右键专辑', '整张加入队列'], ['右键曲目', '加入队列'], ['右键队列条目', '从队列移除'],
    ['拖动队列条目', '调整播放顺序'], ['Esc（搜索框内）', '清空搜索']
  ];
  var h = '<div style="display:grid;grid-template-columns:120px 1fr;gap:9px 14px;font-size:12.5px">';
  rows.forEach(function (r) {
    h += '<div style="color:#9dc0ff;font-family:ui-monospace,Consolas,monospace">' + esc(r[0]) + '</div><div>' + esc(r[1]) + '</div>';
  });
  h += '</div>';
  h += '<div style="margin-top:16px;font-size:11px;color:#5b6478;line-height:1.8">' +
       '独占模式下播放会接管音频设备，其他程序的声音会被静音 —— 这是正常的。<br>' +
       '想要 bit-perfect：输出采样率选「保持源采样率」、抖动选「none」、音量 0 dB。</div>';
  D('mbody').innerHTML = h;
};
D('mclose').onclick = function () { D('modal').classList.remove('on'); };
D('modal').onclick = function (e) { if (e.target === D('modal')) D('modal').classList.remove('on'); };
D('seek').onclick = function (e) {
  var r = this.getBoundingClientRect();
  doSeek((e.clientX - r.left) / r.width);
};
D('bScan').onclick = function () {
  api('/api/lib/scan', '').then(function () { toast('开始扫描音乐库'); libChanged(); loadLibStats(); });
};
D('bRescan').onclick = function () {
  api('/api/lib/scan', 'full=1').then(function () { toast('重新读取全部标签'); libChanged(); loadLibStats(); });
};
D('bAddRoot').onclick = function () {
  var d = D('sRoot').value.trim();
  if (!d) { toast('请填写目录'); return; }
  api('/api/lib/roots', 'add=' + encodeURIComponent(d)).then(function (j) {
    if (!j.ok) { toast(j.error || '添加失败'); return; }
    D('sRoot').value = ''; toast('已添加，正在建立索引'); libChanged(); loadLibStats();
    api('/api/lib/scan', '');
  });
};

// 261024-02 #4：seek 统一走这里 —— 发完请求立刻清掉歌词的手动滚动保护并重定位，
// 不等下一次 400ms tick（否则跳转后歌词要"愣一下"才跟上）。
function doSeek(frac) {
  var f = Math.max(0, Math.min(0.9999, frac));
  api('/api/seek?pos=' + f.toFixed(4), '');
  lyricReposition();
  if (D('npPage') && D('npPage').classList.contains('on')) renderNpLyric();
  if (RTAB === 'l') syncLyrics(f * (S.dur || 0));
}
function seekRel(d) {
  if (!S.dur || S.dur <= 0) return;
  doSeek((S.pos + d) / S.dur);
}
function setVol(v) {
  // v 是 **dB**（键盘 ↑↓ 等入口传的就是 dB）。滑块是位置刻度，这里必须换算。
  // volNormalize：曲线底部以下（≤ -55 dB，含键盘按到 -60 的老下限）统一收成真静音 -120，
  // 否则滑块看起来在最左、后端却还在放 0.1% 振幅的残响（用户报的"最低音量也有声音"）。
  v = volNormalize(v);
  S.vol = v;
  if (D('vol')) D('vol').value = volDbToPos(v);
  if (typeof syncVolUi === 'function') syncVolUi();   // 整页滑块跟随（同一个 S.vol）
  sendVolRealtime(v);   // 键盘连按 ↑↓ 也会连发 ⟹ 同样必须零堆积（见 sendVolRealtime）
}


/* ---------------- 右栏标签页 ---------------- */
var RTAB = 'q';
function applyRTab(forceHide) {
  D('qlist').style.display = (!forceHide && RTAB === 'q') ? '' : 'none';
  D('lyricbox').style.display = (!forceHide && RTAB === 'l') ? '' : 'none';
  D('qclr').style.display = (RTAB === 'q') ? '' : 'none';
  Array.prototype.forEach.call(document.querySelectorAll('.rtab'), function (e) {
    e.classList.toggle('on', e.dataset.t === RTAB);
  });
}
function setRTab(t) {
  RTAB = t;
  applyRTab(false);
  if (t === 'l') {
    // 页签刚显示时容器这一刻才有布局：先按当前进度强制重定位（不等下一次 /api/status 轮询）
    lyricReposition();
    syncLyrics(S.pos || 0, true);
    if (!LY.lines.length) loadLyrics(S.lastCur);
  }
}
Array.prototype.forEach.call(document.querySelectorAll('.rtab'), function (e) {
  e.onclick = function () { setRTab(e.dataset.t); };
});

/* ---------------- 歌词（LRC）---------------- */
// 261024-02 #4：歌词滚动"全错"的根因有三处，一起重做 ——
//   ① parseLrc 不支持 [offset:±ms]，且把 [00:44.26] 的百分秒/毫秒换算只做了长度判断；
//   ② 滚动用 el.offsetTop 计算，但 offsetParent 不是滚动容器（.nplyric2 无 position），
//      offsetTop 带着整页偏移 ⟹ scrollTop 被算到一个荒唐的位置（这就是"全错"）；
//   ③ 纯文本歌词（t=-1）也被当成有轴歌词，pos 一到就把高亮钉在最后一行。
// 现在：时间戳解析走标准 LRC（[mm:ss] / [mm:ss.x] / [mm:ss.xx] / [mm:ss.xxx] / [mm:ss:xx]、一行多时间戳、
// [offset:±ms]）；滚动一律用 getBoundingClientRect 相对滚动容器算目标位置（与 offsetParent 无关）。
var LY = { lines: [], at: -1, raw: '', timed: false, lastPos: -1 };
var LYMAN = { until: 0 };            // 手动滚动保护：这段时间内不自动抢滚动
function lyricManual() {
  LYMAN.until = Date.now() + 3000;
  if (LYFOLLOW.raf) { cancelAnimationFrame(LYFOLLOW.raf); LYFOLLOW.raf = 0; }
}
function lyricTimed() { return !!(LY.lines.length && LY.lines[0].t >= 0); }
function parseLrc(s) {
  var out = [];
  if (!s) return out;
  var rows = String(s).replace(/\r/g, '').split('\n');
  // [offset:±ms]：LRC 规范，正值表示歌词整体**提前**（时间戳减掉）
  var offsetMs = 0;
  for (var i = 0; i < rows.length; i++) {
    var om = rows[i].match(/^\s*\[offset:\s*([+-]?\d+)\s*\]/i);
    if (om) offsetMs = parseInt(om[1], 10) || 0;
  }
  var STAMP = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
  var timed = false;
  for (var r = 0; r < rows.length; r++) {
    var row = rows[r], stamps = [], m;
    STAMP.lastIndex = 0;
    while ((m = STAMP.exec(row))) {
      var mm = parseInt(m[1], 10), ss = parseInt(m[2], 10);
      var frac = m[3] ? parseInt(m[3], 10) : 0, ms = frac;
      if (m[3] && m[3].length === 1) ms = frac * 100;        // [mm:ss.x]  → 十分之一秒
      else if (m[3] && m[3].length === 2) ms = frac * 10;    // [mm:ss.xx] → 百分之一秒
      // 三位就是毫秒（ms = frac）
      stamps.push(mm * 60 + ss + ms / 1000);
    }
    var text = row.replace(/\[[^\]]*\]/g, '').trim();
    if (!stamps.length || !text) continue;   // [ti:]/[ar:]/[by:] 元信息行与空行跳过
    timed = true;
    for (var k = 0; k < stamps.length; k++) {
      out.push({ t: Math.max(0, stamps[k] - offsetMs / 1000), s: text });
    }
  }
  out.sort(function (a, b) { return a.t - b.t; });
  if (!timed) {
    // 纯文本歌词（没有时间轴）：保留行，但 t=-1 ⟹ 不自动滚动、不高亮（见 renderNpLyric）
    rows.forEach(function (x) {
      x = x.trim();
      if (!x || /^\[[a-z]+:/i.test(x)) return;
      out.push({ t: -1, s: x });
    });
  }
  return out;
}
// ---- 跟随滚动（261024-03 #3 重做） ----
// 旧实现用 scrollTo({behavior:'smooth'})。真机 WebView2（Chromium 155）实测：smooth 的
// 滚动动画在容器刚从 display:none 变可见 / 连续改目标时会被合并或停滞 —— 日志里
//   scrollTo lyricbox want=120 before=0 immediate=0
//   （1.5s 后）scrollTo lyricbox want=211 before=0 immediate=0
// 目标写了两次，scrollTop 一动不动；到第三次才动。视口尺寸无关（1340x880 / 893x587 都出现过）。
// 现在：
//   * 一律用 scrollTop 直接赋值（同步生效，可验证），完全不依赖 smooth；
//   * 赋值后下一帧复测，未到位就续跑（最多 1.5s）——覆盖「留白还没生效 / 布局还没稳定」；
//   * 容器 clientHeight==0（面板隐藏、网格行塌陷）时不再静默失败：在 1.5s 内逐帧重试；
//   * 行元素一律按 data-i 取，不再用 children 下标（提示条会混进 children）。
var LYFOLLOW = { raf: 0, deadline: 0 };
function lyricRows(box) {
  var out = [];
  if (!box) return out;
  for (var i = 0; i < box.children.length; i++) {
    var e = box.children[i];
    if (e && e.dataset && e.dataset.i !== undefined) out.push(e);
  }
  return out;
}
function lyricLinePx(box) {
  var rows = lyricRows(box);
  for (var i = 0; i < rows.length; i++) {
    var h = rows[i].getBoundingClientRect().height;
    if (h > 0) return h;
  }
  return 0;
}
// 上下留白 = (容器高 - 行高)/2，写进 CSS 变量（::before/::after 用它）⟹ 首行/末行也能滚到正中
function lyricPad(box) {
  if (!box) return;
  var ch = box.clientHeight, lh = lyricLinePx(box);
  if (ch <= 0 || lh <= 0) return;
  var pad = Math.max(0, (ch - lh) / 2);
  var name = (box.id === 'lyricbox') ? '--lyrpad' : '--nppad';
  var cur = box.style.getPropertyValue(name);
  if (cur && Math.abs(parseFloat(cur) - pad) < 0.3) return;
  box.style.setProperty(name, pad.toFixed(2) + 'px');
}
function lyricTarget(box, el) {
  var br = box.getBoundingClientRect(), er = el.getBoundingClientRect();
  var t = box.scrollTop + (er.top - br.top) - (box.clientHeight - er.height) / 2;
  var max = Math.max(0, box.scrollHeight - box.clientHeight);
  return Math.max(0, Math.min(t, max));
}
function lyricScrollTo(box, el) {
  if (!box || !el) return;
  lyricPad(box);
  if (LYFOLLOW.raf) { cancelAnimationFrame(LYFOLLOW.raf); LYFOLLOW.raf = 0; }
  LYFOLLOW.deadline = Date.now() + 1500;
  var step = function () {
    LYFOLLOW.raf = 0;
    if (!box || !el || !box.isConnected) return;
    lyricPad(box);
    if (box.clientHeight <= 0) {                     // 没布局：逐帧重试，别静默放弃
      if (Date.now() < LYFOLLOW.deadline) LYFOLLOW.raf = requestAnimationFrame(step);
      return;
    }
    var t = lyricTarget(box, el);
    if (Math.abs(t - box.scrollTop) >= 0.6) box.scrollTop = t;
    if (Math.abs(t - box.scrollTop) >= 0.6 && Date.now() < LYFOLLOW.deadline)
      LYFOLLOW.raf = requestAnimationFrame(step);
  };
  step();
}

// seek / 切歌：解除手动保护并允许立刻重定位
function lyricReposition() { LYMAN.until = 0; LY.lastPos = -1; LY.at = -1; }
// 2026-10-23 用户反馈「歌词要等约 10 秒才出现」：
// 根因是时序 —— 播放开始时后端才在后台线程触发元数据/歌词补全（meta_on_play），
// 而这里的 loadLyrics 只请求**一次**：补全还没写回 metabase 时拿到空结果，之后永不重试，
// 于是表现为「等很久才出现」或「必须切走再切回才出现」。
// 处理：歌词为空时做**有限次退避重试**（1s/2s/3s/5s），并在切到歌词页时也触发一次。
// 重试仅在前端，不增加后端负担；一旦拿到内容就停止。
var LYRETRY = { file: "", n: 0, timer: 0 };
function loadLyrics(file, isRetry) {
  if (!file) { D('lyricbox').innerHTML = '<div class="ly none">还没有播放曲目</div>'; return; }
  if (/^https?:/.test(file)) { D('lyricbox').innerHTML = '<div class="ly none">网络曲目暂无歌词</div>'; return; }
  if (!isRetry) {
    LYRETRY.file = file; LYRETRY.n = 0;
    if (LYRETRY.timer) { clearTimeout(LYRETRY.timer); LYRETRY.timer = 0; }
  }
  api('/api/lyrics?file=' + encodeURIComponent(file)).then(function (j) {
    LY.lines = j.ok ? parseLrc(j.lrc) : [];
    LY.raw = (j && j.lrc) || '';
    LY.timed = lyricTimed();
    LY.at = -1; LY.lastPos = -1; LYMAN.until = 0;   // 换歌：清掉上一首的高亮/手动保护
    // 纯文本歌词：给一条显式提示（否则"不滚"看起来就是坏了 —— 261024-03 #3 用户反馈）
    var lyHint = (LY.lines.length && !LY.timed)
      ? '<div class=ly-hint title="这份歌词没有 [mm:ss] 时间轴，无法按播放位置高亮/跟随">纯文本歌词（无时间轴）· 不会自动跟随滚动</div>'
      : '';
    D('lyricbox').innerHTML = LY.lines.length
      ? lyHint + LY.lines.map(function (l, i) {
          return '<div class="ly" data-i="' + i + '">' + esc(l.s) + '</div>';
        }).join('')
      : '<div class="ly none">没有歌词<br><span style="font-size:11px">同名 .lrc 文件、内嵌歌词，或播放时自动在线补全（可在设置-元数据补全关闭）</span></div>';
    // 空结果 → 退避重试（后端可能正在后台补全；最多 4 次：1s/2s/3s/5s）
    if (!LY.lines.length && LYRETRY.file === file && LYRETRY.n < 4) {
      var waits = [1000, 2000, 3000, 5000];
      var w = waits[LYRETRY.n] || 5000;
      LYRETRY.n++;
      if (LYRETRY.timer) clearTimeout(LYRETRY.timer);
      LYRETRY.timer = setTimeout(function () {
        if (LYRETRY.file === file && S.lastCur === file) loadLyrics(file, true);
      }, w);
      D("lyricbox").innerHTML = '<div class="ly none">歌词加载中…<br><span style="font-size:11px">正在等后台补全（首次播放新曲目时可能要几秒）</span></div>';
      return;
    }
    Array.prototype.forEach.call(D('lyricbox').children, function (e) {
      if (e.dataset.i === undefined) return;
      e.onclick = function () {
        var l = LY.lines[+e.dataset.i];
        if (l.t >= 0 && S.dur > 0) doSeek(l.t / S.dur);
      };
    });
    syncLyrics(S.pos);
    if (D('npPage') && D('npPage').classList.contains('on')) renderNpLyric();
  }).catch(function () { D('lyricbox').innerHTML = '<div class="ly none">歌词加载失败</div>'; });
}
// 右栏歌词（#lyricbox）：与整页歌词共用同一套解析/居中逻辑（261024-02 #4）
function syncLyrics(pos, force) {
  if (!lyricTimed()) return;
  var idx = -1;
  for (var i = 0; i < LY.lines.length; i++) { if (LY.lines[i].t <= pos + 0.05) idx = i; else break; }
  var box = D('lyricbox');
  if (!box) return;
  if (idx === LY.at && !force) return;
  LY.at = idx;
  var rows = lyricRows(box);
  for (var r = 0; r < rows.length; r++) rows[r].classList.toggle('on', +rows[r].dataset.i === idx);
  var el = rows[idx];
  // 右栏歌词页签没打开时不要滚（clientHeight=0，滚了也没意义）；切到该页签时会 force 重定位
  if (el && RTAB === 'l' && Date.now() >= LYMAN.until) lyricScrollTo(box, el);
}

/* ---------------- 播放列表（UI 已并入播放队列） ---------------- */

/* ---------------- 信号链（Roon 式）---------------- */
// 音量文案必须反映【现在真正生效的】值，而不是起播那一刻的快照。
// 之前这里用的是快照，用户拖动音量后信号链还显示旧值 —— 这是会被当成"撒谎"的 bug。
function volText(liveDb) {
  var v = (typeof liveDb === 'number') ? liveDb : 0;
  if (Math.abs(v) < 0.05) return '0.0 dB（逐位无损）';
  // 2026-10-25（v3）：静音档说「静音」而不是「-120.0 dB」——与音量条标签同一口径，
  // 否则同一时刻两个控件一个写「静音」一个写「-120.0 dB」，用户会以为是两个不同的状态。
  if (v <= -59.5) return '静音（增益 0）';
  var s = v.toFixed(1) + ' dB';
  if (typeof S.startDb === 'number' && Math.abs(S.startDb - v) >= 0.05)
    s += '（起播 ' + S.startDb.toFixed(1) + ' dB，实时微调 ' + (v - S.startDb).toFixed(1) + ' dB）';
  return s;
}
function showChain() {
  D('mtitle').textContent = '信号链';
  D('modal').classList.add('on');
  api('/api/signal').then(function (j) {
    if (!j.ok) { D('mbody').innerHTML = '<div class=empty>还没有开始播放</div>'; return; }
    var p = j.path;
    var bp = p.bitPerfect || '';
    var why = p.bitPerfectWhy || '（本次未记录）';
    var heroCls = '', heroTitle = 'BIT-PERFECT · 全链路逐位无损', heroIcon = '\u2713';
    if (bp === 'direct') { heroCls = ' direct'; heroTitle = 'BIT-PERFECT · 1-bit DSD 直通'; heroIcon = '\u25c6'; }
    else if (bp === 'yes') { heroCls = ''; heroTitle = 'BIT-PERFECT · 全链路逐位无损'; heroIcon = '\u2713'; }
    else if (bp === 'no') { heroCls = ' warn'; heroTitle = '非 Bit-Perfect · 信号经过 DSP 处理'; heroIcon = '!'; }
    else { heroCls = ' warn'; heroTitle = 'Bit-Perfect 状态未知'; heroIcon = '?'; }

    var nodes = [];
    nodes.push({ k: '源文件', v: nam(p.src) + (p.codec ? '  \u00b7  ' + p.codec.toUpperCase() : ''), badge: '无损源', kind: 'lossless' });
    nodes.push({ k: '解码', v: (p.note || '原生无损解码') + '  \u00b7  ' + p.inRate + ' Hz / ' + p.inBits + ' bit / ' + p.inCh + ' ch', badge: '无损解码', kind: 'lossless' });
    var convGpu = (typeof p.convGpu === 'boolean') ? p.convGpu : (p.irGpu === true);
    var sigGpuUsed = (typeof p.gpuUsed === 'boolean') ? p.gpuUsed : !!S.gpuUsed;
    if (p.resample) nodes.push({ k: '采样率转换', v: (p.filter || 'Kaiser sinc') + '  \u00b7  ' + p.phase + '  \u00b7  ' + p.taps + ' 抽头' + (p.twoStage ? '  \u00b7  两段式' : '') + '  \u2192  ' + p.outRate + ' Hz' + (sigGpuUsed ? '  \u00b7  GPU' : ''), gpu: !!sigGpuUsed, badge: sigGpuUsed ? 'GPU 升频' : '64-Bit 升频', kind: sigGpuUsed ? 'gpu' : 'dsp' });
    else nodes.push({ k: '采样率转换', v: '旁路（源采样率与输出一致，逐位直通）', badge: '逐位旁路', kind: 'lossless' });
    if (p.eq || p.conv) {
      var eqParts = [];
      if (p.eq) eqParts.push('参数 EQ' + (ADV.eq ? (' ' + nam(ADV.eq)) : ''));
      if (p.conv) eqParts.push('FIR 卷积' + (ADV.ir ? (' ' + nam(ADV.ir)) : ''));
      nodes.push({ k: 'EQ / 卷积', v: eqParts.join('  \u00b7  ') + '  \u00b7  ' + (convGpu ? 'GPU 计算' : 'CPU 计算'), gpu: convGpu, badge: convGpu ? 'GPU 卷积' : 'DSP 均衡', kind: convGpu ? 'gpu' : 'dsp' });
    }
    if (p.dsd) {
      nodes.push({ k: 'DSD 调制', v: 'DSD' + p.dsd + '（' + (p.dsdRate / 1000000).toFixed(4) + ' MHz）\u00b7 1-bit \u00b7 ' + (p.modOrder || 5) + ' 阶 SDM', badge: 'SDM 调制', kind: 'dsp' });
      nodes.push({ k: 'DoP 封装', v: '24-bit 载波 ' + p.outRate + ' Hz \u00b7 标记 0x05/0xFA 交替', badge: 'DoP 1.1', kind: 'lossless' });
    } else {
      var isNoShap = (!p.shaper || p.shaper === 'none');
      nodes.push({ k: '抖动 / 噪声整形', v: !isNoShap ? p.shaper : '无（逐位）', badge: isNoShap ? '逐位直通' : '噪声整形', kind: isNoShap ? 'lossless' : 'dsp' });
    }
    if (p.preAtten && p.preAtten < 0) {
      nodes.push({ k: '峰值保护', v: '检测到过采样峰值 ' + (p.ispPeak * 100).toFixed(1) + '%（' + p.ispOver +
        ' 个点超出满幅）→ 预衰减 ' + p.preAtten.toFixed(1) + ' dB', badge: 'ISP 保护', kind: 'dsp' });
    }
    if (p.loudness) nodes.push({ k: '等响度补偿', v: '开启', badge: 'DSP 响度', kind: 'dsp' });
    var isUnitVol = (typeof p.volume !== 'number') || Math.abs(p.volume) < 0.05;
    nodes.push({ k: '音量', v: volText(p.volume), id: 'chainVol', badge: isUnitVol ? '逐位无损' : '数字衰减', kind: isUnitVol ? 'lossless' : 'dsp' });
    var isSharedOut = (ADV.backend === 'wasapi-shared');
    nodes.push({ k: '输出', v: p.device + '  \u00b7  ' + p.outRate + ' Hz / ' + p.outBits + ' bit / ' + p.outCh +
      ' ch  \u00b7  ' + (isSharedOut ? '共享模式（非 bit-perfect）' : '独占模式') +
      '  \u00b7  缓冲 ' + p.buffer + ' ms', badge: isSharedOut ? '系统混音' : '硬件独占', kind: isSharedOut ? 'dsp' : 'lossless' });

    var tDec = (typeof p.decodeMs === 'number' && p.decodeMs > 0)
      ? (p.decodeMs >= 1000 ? (p.decodeMs / 1000).toFixed(2) + ' s' : p.decodeMs.toFixed(1) + ' ms')
      : '–';
    var tWav = '–';
    if (typeof p.ffmpegMs === 'number' && p.ffmpegMs > 0) {
      tWav = '转码写 ' + p.ffmpegMs.toFixed(1) + ' ms' +
             (typeof p.wavReadMs === 'number' && p.wavReadMs > 0 ? ' / 读 ' + p.wavReadMs.toFixed(1) + ' ms' : '');
    } else if (typeof p.wavReadMs === 'number' && p.wavReadMs > 0) {
      tWav = '读取 ' + p.wavReadMs.toFixed(1) + ' ms';
    }
    var tDsp = '–';
    if (typeof p.dspBlockMs === 'number' && p.dspBlockMs > 0) {
      tDsp = p.dspBlockMs.toFixed(2) + ' ms/块' +
             (typeof p.dspTotalMs === 'number' && p.dspTotalMs > 0 ? '（累计 ' + p.dspTotalMs.toFixed(1) + ' ms）' : '');
    } else if (typeof p.dspTotalMs === 'number' && p.dspTotalMs > 0) {
      tDsp = '累计 ' + p.dspTotalMs.toFixed(1) + ' ms';
    }
    var tScan = (typeof p.scanMs === 'number' && p.scanMs > 0)
      ? (p.scanMs >= 1000 ? (p.scanMs / 1000).toFixed(2) + ' s' : p.scanMs.toFixed(0) + ' ms')
      : '–';

    nodes.push({
      k: '耗时统计',
      v: '解码 ' + tDec + '  \u00b7  临时WAV ' + tWav + '  \u00b7  DSP ' + tDsp + '  \u00b7  库扫描 ' + tScan,
      id: 'chainTiming',
      badge: '实时遥测',
      kind: 'tel'
    });
    var h = '<div class="chain-hero' + heroCls + '">'
          + '<div class=ch-ic>' + esc(heroIcon) + '</div>'
          + '<div class=ch-tx><div class=ch-tt>' + esc(heroTitle) + '</div>'
          + '<div class=ch-sub>' + esc(why) + '</div></div></div>';
    h += '<div class=chain>';
    nodes.forEach(function (n, i) {
      var cls = 'cnode' + (n.gpu ? ' gpu' : '') + (n.kind ? (' ' + n.kind) : '');
      h += '<div class="' + cls + '"><div class=dot></div><div><div class=k><span>' + esc(n.k) + '</span>'
         + (n.badge ? '<span class=cbadge>' + esc(n.badge) + '</span>' : '')
         + '</div><div class=v' + (n.id ? ' id=' + n.id : '') + '>' + esc(n.v) + '</div></div></div>';
      if (i !== nodes.length - 1) h += '<div class=cline></div>';
    });
    h += '</div>';
    h += '<div class=chain-foot><span>绿色节点 = 逐位无损或 GPU 参与计算；蓝色节点 = 64-Bit DSP 处理</span><span>Bit-Perfect 音频管线</span></div>';
    D('mbody').innerHTML = h;
  }).catch(function () { D('mbody').innerHTML = '<div class=empty>读取失败</div>'; });
}


/* ---------------- 完整设置页 ---------------- */
var SET_GROUPS = null;
function opt(v, label, cur) {
  return '<option value="' + esc(v) + '"' + (String(cur) === String(v) ? ' selected' : '') + '>' + esc(label) + '</option>';
}
// 2026-10-24（用户 261024-01 #7）：「文字量太大……做成鼠标移上去的提示文本，要么就给我去掉」。
// 约定：
//   tip(说明)     → label 右侧的 (?) 图标，hover / 键盘 focus 才显示（长说明一律用这个）；
//   inlineHint()  → 真正需要常驻的安全警告，压成一句放控件下面；
//   sgroup(title, tipText, body) → 分组标题右侧同样是一个 (?)。
// 开发者注释（"实测 THD+N…""顺序挑第一个能跑的后端"这类）不进入界面。
function tip(t) {
  return t ? '<span class=tip tabindex=0 role=note data-tip="' + esc(t) + '">?</span>' : '';
}
function inlineHint(t) {
  return t ? '<div class=hint>' + t + '</div>' : '';
}
function num(id, val, min, max, step, hint) {
  return '<div class=sfld><label>' + id.label + tip(hint) + '</label><input type=number id=' + id.id +
         ' value="' + val + '" min=' + min + ' max=' + max + ' step=' + step + '></div>';
}
function sel(id, label, optsHtml, hint) {
  return '<div class=sfld><label>' + label + tip(hint) + '</label><select id=' + id + '>' + optsHtml + '</select></div>';
}
// wide=true 时整行显示（用于说明较长的开关，避免被 .sgbody 的多列网格压成窄条）
function chk(id, label, checked, hint, wide) {
  // 2026-10-26：label 包一层 <span id=Id_lbl>，供需要按真实状态动态改文案的场景定位
  //（第一个用例：#sp_irgpu 的标题原来写死"需要 librtagpu.dylib 就位"，
  //  而 .app 里其实已经打包了该库 ⟹ 用户看到永远"需要就位"的假状态）。
  return '<div class="sfld' + (wide ? ' wide' : '') + '"><label class=chk><input type=checkbox id=' + id + (checked ? ' checked' : '') + '>' +
         '<span id="' + id + '_lbl">' + label + '</span>' + (hint ? '<span class=tip tabindex=0 role=note data-tip="' + esc(hint) +
           '" onclick="event.preventDefault();event.stopPropagation()">?</span>' : '') + '</label></div>';
}
function txt(id, label, val, hint, ph) {
  return '<div class="sfld wide"><label>' + label + tip(hint) + '</label><input type=text id=' + id + ' value="' + esc(val || '') +
         '" placeholder="' + esc(ph || '') + '"></div>';
}

/* ---------------- 输出后端 / 输入设备 ---------------- */
function backendHint() {
  var m = D('sp_backendmsg'); if (!m) return;
  var bk = (D('sp_backend') && D('sp_backend').value) || 'wasapi';
  if (bk === 'wasapi') {
    // 2026-10-25（方案 C）：如实说明当前是否真的抢 Hog，而不是笼统说"独占/接管"。
    var hog = (typeof ADV !== 'undefined' && ADV.hogExclusive == 1);
    m.textContent = hog
      ? '硬件直通 + 严格独占（Hog）：播放期间屏蔽其它 App 声音；系统音量条会失效，请用本程序音量条调音量。'
      : '硬件直通 · bit-perfect；不抢 Hog ⟹ 系统音量条 / 音量键全程可用。如需彻底独占（屏蔽其它 App 声音），请勾选「严格独占」。';
  } else if (bk === 'wasapi-shared') {
    m.textContent = 'CoreAudio 共享：经系统混音，非 bit-perfect；不支持 DoP / DSD。';
  } else if (bk === 'null') {
    m.textContent = 'Null output：跑完整 DSP，不出声。';
  } else if (bk === 'naa') {
    // 2026-10-25（用户指令「不可用的要隐藏」）：NAA 已从后端下拉移除，正常路径走不到这里。
    // 保留分支只为兜底老 conf（migrateRemovedBackend 已把它降级为 wasapi）与直接调 API 的
    // 场景，如实说明不可用，而不是静默给一句看似正常的提示。
    m.textContent = 'NAA / RTANet 在 macOS 上不可用（无驱动体系），已回退 CoreAudio 独占。';
  } else if (bk === 'upnp') {
    // 261024-01 #9：后端下拉新增「UPnP / DLNA 投放」。提示用渲染器**名字**，不回显整条描述 URL。
    var devSel = D('sp_upnp_dev');
    var devName = '';
    if (devSel && devSel.selectedIndex >= 0 && devSel.value) {
      devName = devSel.options[devSel.selectedIndex].textContent || '';
    }
    m.textContent = 'UPnP / DLNA 投放：播放 / 切歌 / 暂停 / 拖动进度都会作用到渲染器 ' +
      (devName || '（未选择渲染器）') + '。按源文件原采样率供源，不经本机 DSP。';
  }
}

/* ---------------- 输入采集与直通监听（P4b） ---------------- */
var _inPollTimer = null;

function loadInputDevices() {
  return api('/api/input/devices').then(function (j) {
    var s = D('sp_indev'); if (!s) return;
    if (j && j.ok === false) {
      s.innerHTML = '<option value="">（读取设备列表失败）</option>';
      if (D('sp_inmsg')) D('sp_inmsg').textContent = j.error || '输入设备列表读取失败';
      return;
    }
    var list = (j && j.devices) || [];
    if (!list.length) {
      s.innerHTML = '<option value="">（本机未检测到可用输入设备）</option>';
      if (D('sp_inmsg')) D('sp_inmsg').textContent = '本机未检测到可用输入设备';
      return;
    }
    var hh = '<option value="">（未选择 / 默认设备）</option>';
    list.forEach(function (d) {
      var name = d.name || '';
      // 2026-10-25（系统混音回环）：后端 /api/input/devices 的字段名是 loopback，
      // 契约包含伪设备 __system_loopback__ 与普通回环设备。追加「 · 回环」标注。
      var isLb = !!(d.loopback === true || d.isLoopback === true);
      if (isLb && name.indexOf(' · 回环') < 0 && name.indexOf('[回环]') < 0 && name.indexOf('[Loopback]') < 0) {
        name += ' · 回环';
      }
      var isDef = !!(d.default === true || d.isDefault === true);
      if (isDef && name.indexOf('（默认）') < 0) {
        name += '（默认）';
      }
      hh += '<option value="' + esc(d.id) + '">' + esc(name) + '</option>';
    });
    s.innerHTML = hh;
    if (ADV.inDev) s.value = ADV.inDev;
    s.onchange = function () { ADV.inDev = this.value; saveSettings(); };
    if (D('sp_inmsg')) {
      D('sp_inmsg').textContent = '';
    }
  }).catch(function (e) {
    var s = D('sp_indev');
    if (s) s.innerHTML = '<option value="">（输入设备列表读取失败）</option>';
    if (D('sp_inmsg')) D('sp_inmsg').textContent = '输入设备列表读取失败' + (e && e.message ? ('：' + e.message) : '');
  });
}

function updateInputStateUi(st) {
  if (!st) return;
  var running = !!st.running;
  var btnStart = D('sp_instart');
  var btnStop = D('sp_instop');
  if (btnStart) btnStart.disabled = running;
  if (btnStop) btnStop.disabled = !running;

  var rEl = D('sp_stat_running');
  if (rEl) {
    if (running) {
      rEl.textContent = st.mode === 'monitor' ? '直通监听中' : (st.mode === 'null' ? '模拟源运行中' : '录制中');
      rEl.style.color = 'var(--acc)';
    } else {
      rEl.textContent = '空闲';
      rEl.style.color = '';
    }
  }

  var fEl = D('sp_stat_frames');
  if (fEl) {
    var sec = (typeof st.seconds === 'number') ? st.seconds.toFixed(1) : '0.0';
    fEl.textContent = (st.frames || 0) + ' 帧 (' + sec + 's)';
  }

  var sEl = D('sp_stat_spec');
  if (sEl) {
    if (st.rate && st.channels) {
      sEl.textContent = st.rate + ' Hz / ' + st.channels + ' 声道' + (st.device ? (' · ' + st.device) : '');
    } else {
      sEl.textContent = st.device ? st.device : '-';
    }
  }

  var wEl = D('sp_stat_water');
  var wBar = D('sp_meter_water');
  var waterVal = typeof st.water === 'number' ? Math.max(0, Math.min(1, st.water)) : 0;
  var waterPct = (waterVal * 100).toFixed(1) + '%';
  if (wEl) wEl.textContent = waterPct;
  if (wBar) wBar.style.width = waterPct;

  var xEl = D('sp_stat_xrun');
  if (xEl) {
    xEl.textContent = '溢出 ' + (st.overflow || 0) + ' / 欠载 ' + (st.underflow || 0);
    xEl.style.color = ((st.overflow || 0) > 0 || (st.underflow || 0) > 0) ? 'var(--err)' : '';
  }

  var cEl = D('sp_stat_clips');
  if (cEl) {
    var pos = st.posClips || 0;
    var neg = st.negClips || 0;
    cEl.textContent = '+' + pos + ' / -' + neg;
    cEl.style.color = (pos > 0 || neg > 0) ? 'var(--err)' : '';
  }

  var rmsEl = D('sp_stat_rms');
  var rmsBar = D('sp_meter_rms');
  var rms = typeof st.rmsDb === 'number' ? st.rmsDb : -999;
  if (rmsEl) rmsEl.textContent = (rms > -900) ? (rms.toFixed(1) + ' dBFS') : '-∞ dBFS';
  if (rmsBar) {
    var rPct = Math.max(0, Math.min(100, ((rms + 60) / 60) * 100));
    rmsBar.style.width = (rms > -900 ? rPct : 0).toFixed(0) + '%';
  }

  var pkEl = D('sp_stat_peak');
  var pkBar = D('sp_meter_peak');
  var pk = typeof st.peakDb === 'number' ? st.peakDb : -999;
  if (pkEl) pkEl.textContent = (pk > -900) ? (pk.toFixed(1) + ' dBFS') : '-∞ dBFS';
  if (pkBar) {
    var pPct = Math.max(0, Math.min(100, ((pk + 60) / 60) * 100));
    pkBar.style.width = (pk > -900 ? pPct : 0).toFixed(0) + '%';
    pkBar.classList.toggle('clip', pk >= -0.1);
  }

  var oEl = D('sp_stat_out');
  if (oEl) {
    oEl.textContent = st.outFile || (st.mode === 'monitor' ? '（直通监听无输出文件）' : '-');
  }

  var errBox = D('sp_stat_err_box');
  var errEl = D('sp_stat_err');
  if (st.error) {
    if (errEl) errEl.textContent = st.error;
    if (errBox) errBox.style.display = 'block';
    if (D('sp_inmsg')) D('sp_inmsg').textContent = st.error;
  } else {
    if (errBox) errBox.style.display = 'none';
  }
}

function pollInputState() {
  clearTimeout(_inPollTimer);
  var inPane = document.querySelector('#setpage .spane[data-g=in]');
  var isTabOn = inPane && inPane.classList.contains('on');
  var isSetOpen = D('setpage') && D('setpage').classList.contains('on');

  api('/api/input/state').then(function (st) {
    updateInputStateUi(st);
    if ((isSetOpen && isTabOn) || (st && st.running)) {
      _inPollTimer = setTimeout(pollInputState, 1000);
    }
  }).catch(function () {
    if (isSetOpen && isTabOn) {
      _inPollTimer = setTimeout(pollInputState, 1500);
    }
  });
}

function startInputCapture() {
  var btnStart = D('sp_instart');
  var btnStop = D('sp_instop');
  if (btnStart) btnStart.disabled = true;
  if (btnStop) btnStop.disabled = true;

  var isMon = D('sp_inmon') && D('sp_inmon').checked;
  var mode = isMon ? 'monitor' : 'record';
  var dev = (D('sp_indev') && D('sp_indev').value) || '';
  var sec = D('sp_inseconds') ? parseFloat(D('sp_inseconds').value) || 0 : 0;
  var out = D('sp_inout') ? D('sp_inout').value.trim() : '';

  var body = 'mode=' + encodeURIComponent(mode);
  if (dev) body += '&dev=' + encodeURIComponent(dev);
  if (sec > 0) body += '&seconds=' + sec;
  if (out) body += '&out=' + encodeURIComponent(out);

  api('/api/input/start', body).then(function (j) {
    if (j && j.ok) {
      toast(isMon ? '直通监听已启动' : '录制采集已启动');
      if (D('sp_inmsg')) D('sp_inmsg').textContent = '';
      pollInputState();
    } else {
      var err = (j && j.error) || '启动失败';
      if (D('sp_inmsg')) D('sp_inmsg').textContent = err;
      toast('启动失败: ' + err);
      pollInputState();
    }
  }).catch(function (e) {
    var err = (e && e.message) || '网络或接口错误';
    if (D('sp_inmsg')) D('sp_inmsg').textContent = err;
    toast('启动失败: ' + err);
    pollInputState();
  });
}

function stopInputCapture() {
  var btnStart = D('sp_instart');
  var btnStop = D('sp_instop');
  if (btnStart) btnStart.disabled = true;
  if (btnStop) btnStop.disabled = true;

  api('/api/input/stop', '').then(function (j) {
    if (j && j.ok) {
      toast('采集已停止');
      pollInputState();
    } else {
      var err = (j && j.error) || '停止失败';
      toast('停止失败: ' + err);
      pollInputState();
    }
  }).catch(function (e) {
    toast('停止失败');
    pollInputState();
  });
}

/* ---------------- UPnP/DLNA 媒体投放 ---------------- */
var _castPollTimer = null;
var _castDevices = [];

function fmtBytes(b) {
  if (!b || b <= 0) return '0 B';
  if (b < 1024) return b + ' B';
  if (b < 1024 * 1024) return (b / 1024).toFixed(1) + ' KB';
  if (b < 1024 * 1024 * 1024) return (b / (1024 * 1024)).toFixed(1) + ' MB';
  return (b / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

function updateCastStateUi(st) {
  if (!st) return;
  var running = !!st.running;
  var btnStart = D('sp_cast_start');
  var btnStop = D('sp_cast_stop');
  if (btnStart) btnStart.disabled = running;
  if (btnStop) btnStop.disabled = !running;

  var pEl = D('sp_cast_stat_phase');
  if (pEl) {
    var pMap = {
      'discovering': '设备发现中',
      'serving': '本地供源就绪',
      'playing': '投放播放中',
      'stopped': '已停止',
      'error': '发生错误'
    };
    pEl.textContent = pMap[st.phase] || (st.phase || '已停止');
    if (st.phase === 'playing') pEl.style.color = 'var(--ok)';
    else if (st.phase === 'error') pEl.style.color = 'var(--err)';
    else if (running) pEl.style.color = 'var(--acc)';
    else pEl.style.color = '';
  }

  var devEl = D('sp_cast_stat_dev');
  if (devEl) {
    devEl.textContent = st.device || '-';
  }

  var posEl = D('sp_cast_stat_pos');
  if (posEl) {
    posEl.textContent = fmt(st.positionSec || 0);
  }

  var trEl = D('sp_cast_stat_transport');
  if (trEl) {
    trEl.textContent = st.transportState || 'STOPPED';
    if (st.transportState === 'PLAYING') trEl.style.color = 'var(--ok)';
    else if (st.transportState === 'PAUSED_PLAYBACK') trEl.style.color = 'var(--warn, #eab308)';
    else trEl.style.color = '';
  }

  var bEl = D('sp_cast_stat_bytes');
  if (bEl) {
    bEl.textContent = fmtBytes(st.servedBytes || 0);
  }

  var reqEl = D('sp_cast_stat_reqs');
  if (reqEl) {
    reqEl.textContent = (st.requestCount || 0) + ' 次';
  }

  var portEl = D('sp_cast_stat_port');
  if (portEl) {
    portEl.textContent = String(st.servePort || 8912);
  }

  var rmEl = D('sp_cast_stat_ratematch');
  if (rmEl) {
    if (st.rateMatch === 'match') {
      rmEl.textContent = '匹配（Bit-Perfect）';
      rmEl.style.color = 'var(--ok)';
    } else if (st.rateMatch === 'mismatch') {
      rmEl.textContent = '失配（可能重采样）';
      rmEl.style.color = 'var(--err)';
    } else {
      rmEl.textContent = '未声明（需硬件确证）';
      rmEl.style.color = 'var(--mut2)';
    }
  }

  var warnBox = D('sp_cast_stat_warn_box');
  var warnEl = D('sp_cast_stat_warn');
  if (st.warning) {
    if (warnEl) warnEl.textContent = st.warning;
    if (warnBox) warnBox.style.display = 'block';
  } else {
    if (warnBox) warnBox.style.display = 'none';
  }

  var errBox = D('sp_cast_stat_err_box');
  var errEl = D('sp_cast_stat_err');
  if (st.error) {
    if (errEl) errEl.textContent = st.error;
    if (errBox) errBox.style.display = 'block';
    if (D('sp_cast_msg')) D('sp_cast_msg').textContent = st.error;
  } else {
    if (errBox) errBox.style.display = 'none';
  }
}


// 261024-01 #9：两个渲染器下拉（「输出后端」里的 sp_upnp_dev 与「投放」区块里的
// sp_cast_dev）共用同一份发现结果与同一个选择。value 一律用设备描述 URL ——
// 直连描述比按名字匹配可靠（本机 SSDP 被拦时 CastManager 仍可用 http://IP:PORT/ 直连）。
function castDevLabel(d) {
  return (d.friendlyName || d.name || d.host || '') + (d.model ? (' · ' + d.model) : '');
}
function castDevValue(d) {
  return d.location || d.friendlyName || d.name || d.host || '';
}
function populateCastDevices() {
  var opts = '';
  _castDevices.forEach(function (d) {
    opts += '<option value="' + esc(castDevValue(d)) + '">' + esc(castDevLabel(d)) + '</option>';
  });
  if (!opts) opts = '<option value="">（未发现 UPnP 渲染器）</option>';
  // 已保存的渲染器若这次没扫到（设备关机 / 换网段）也保留一项，别让用户的选择悄悄丢
  var saved = (ADV.upnpDev || '').trim();
  var haveSaved = false;
  if (saved) {
    for (var i = 0; i < _castDevices.length; i++) {
      if (castDevValue(_castDevices[i]) === saved) { haveSaved = true; break; }
    }
    if (!haveSaved) opts += '<option value="' + esc(saved) + '">（上次选择）' + esc(saved) + '</option>';
  }
  ['sp_cast_dev', 'sp_upnp_dev'].forEach(function (id) {
    var s = D(id);
    if (!s) return;
    s.innerHTML = opts;
    var want = saved;
    if (!want && _castDevices.length) want = castDevValue(_castDevices[0]);
    if (!want) return;
    for (var k = 0; k < s.options.length; k++) {
      if (s.options[k].value === want) { s.value = want; break; }
    }
  });
  // 第一次发现有设备时自动在界面回显（绝不在后台静默保存触发 saveSettings）
  if (!saved && _castDevices.length) {
    var defVal = castDevValue(_castDevices[0]);
    ADV.upnpDev = defVal;
    if (D('sp_cast_dev')) D('sp_cast_dev').value = defVal;
    if (D('sp_upnp_dev')) D('sp_upnp_dev').value = defVal;
  }
  backendHint();   // 下拉刚填好，后端提示里的渲染器名字要跟着刷新（否则会显示"未选择渲染器"）
}
function syncUpnpDev(value) {
  ADV.upnpDev = value || '';
  if (D('sp_cast_dev') && D('sp_cast_dev').value !== value) D('sp_cast_dev').value = value;
  if (D('sp_upnp_dev') && D('sp_upnp_dev').value !== value) D('sp_upnp_dev').value = value;
  saveSettings();
}
function scanCastDevices(force) {
  var msg = D('sp_cast_devmsg');
  var msg2 = D('sp_upnp_msg');
  var btns = [D('sp_cast_scan'), D('sp_upnp_scan')];
  btns.forEach(function (b) { if (b) b.disabled = true; });
  if (msg) msg.textContent = '正在发现渲染器…';
  if (msg2) msg2.textContent = '正在发现渲染器…';

  var url = '/api/cast/devices' + (force ? '?scan=1' : '');
  api(url).then(function (j) {
    btns.forEach(function (b) { if (b) b.disabled = false; });
    _castDevices = (j && j.devices) || [];
    populateCastDevices();
    if (msg) {
      msg.textContent = _castDevices.length
        ? ('共发现 ' + _castDevices.length + ' 个渲染器')
        : '未发现 UPnP/DLNA 渲染器（可能未开机、不在同一子网，或 SSDP 组播被代理/防火墙拦截）';
    }
    if (msg2) {
      msg2.textContent = _castDevices.length
        ? ('共发现 ' + _castDevices.length + ' 个渲染器')
        : '未发现 UPnP/DLNA 渲染器：确认数播已开启 UPnP/DLNA 且与本机同一子网';
    }
  }).catch(function () {
    btns.forEach(function (b) { if (b) b.disabled = false; });
    if (msg) msg.textContent = '扫描失败（/api/cast/devices 无响应）';
    if (msg2) msg2.textContent = '扫描失败（/api/cast/devices 无响应）';
  });
}

/* ---------------- NAA 端点自动发现（261024-01 #11） ---------------- */
var _naaPollTimer = null;
function renderNaaEndpoints(res) {
  var eps = (res && res.endpoints) || [];
  var s;
  if ((s = D('sp_naa_dev'))) {
    if (!eps.length) {
      s.innerHTML = '<option value="">（未发现 NAA 端点）</option>';
    } else {
      var h = '';
      eps.forEach(function (e) {
        var v = e.host + ':' + (e.port || 43210);
        h += '<option value="' + esc(v) + '">' + esc(v) + '</option>';
      });
      s.innerHTML = h;
      // 自动获取：优先沿用已保存的端点，否则选第一个并写回设置（用户不用再手填）
      var saved = (ADV.naaHost || '').trim();
      var hit = false;
      for (var i = 0; i < s.options.length; i++) {
        if (s.options[i].value === saved) { s.value = saved; hit = true; break; }
      }
      if (!hit) {
        s.selectedIndex = 0;
        ADV.naaHost = s.value;
        if (D('sp_naahost')) D('sp_naahost').value = s.value;
      }
    }
  }
  var m;
  if ((m = D('sp_naa_msg'))) {
    m.textContent = (res && res.note) || '';
    m.style.color = eps.length ? 'var(--mut2)' : 'var(--warn, #eab308)';
  }
}
function discoverNaa(force) {
  clearTimeout(_naaPollTimer);
  if (D('sp_naa_scan')) D('sp_naa_scan').disabled = true;
  var m;
  if ((m = D('sp_naa_msg'))) {
    m.textContent = '正在自动发现 NAA 端点（只读扫描本机网段的 TCP 43210）…';
    m.style.color = 'var(--mut2)';
  }
  api('/api/naa/discover' + (force ? '?refresh=1' : '')).then(function (j) {
    if (j && j.scanning) {
      _naaPollTimer = setTimeout(function () { discoverNaa(false); }, 700);
      return;
    }
    if (D('sp_naa_scan')) D('sp_naa_scan').disabled = false;
    renderNaaEndpoints(j);
    backendHint();
  }).catch(function () {
    if (D('sp_naa_scan')) D('sp_naa_scan').disabled = false;
    var em;
    if ((em = D('sp_naa_msg'))) {
      em.textContent = '自动发现失败：/api/naa/discover 无响应';
      em.style.color = 'var(--err)';
    }
  });
}

/* ---------------- 后端相关控件的显隐 / 启用状态（261024-01 #9/#11） ---------------- */
// 261024-01 #9/#11：后端 = UPnP 时，本机设备 / 采样率 / 位深 / 声道 / 缓冲 / 渐变 / 输出模式 /
// 声道微调**全都不参与**（投放按源文件原采样率供源，不经本机 DSP）。这些字段直接隐藏，而不是
// 置灰摆着 —— 用户已反馈设置页控件/文本太多（261024-01 #7），没用就别占地方。
// 注意：字段仍保留在 DOM 里（display:none），collectSettings / saveSettings 照旧读得到值。
var _UPNP_IRRELEVANT = ['sp_device', 'sp_rate', 'sp_bits', 'sp_ch', 'sp_buffer', 'sp_ramp', 'sp_outmode'];
function _setFieldVisible(id, on) {
  var e = D(id);
  if (!e) return;
  var f = e.closest ? e.closest('.sfld') : null;
  if (f) f.style.display = on ? '' : 'none';
}
function applyBackendState() {
  var bk = (D('sp_backend') && D('sp_backend').value) || 'wasapi';
  // 2026-10-25（用户指令「不可用的要隐藏」）：NAA 端点块已从设置页移除，保留存在性守卫。
  if (D('sp_naawrap')) D('sp_naawrap').style.display = 'none';
  var upnpBox = D('sp_upnpwrap'); if (upnpBox) upnpBox.style.display = (bk === 'upnp') ? '' : 'none';
  _UPNP_IRRELEVANT.forEach(function (id) { _setFieldVisible(id, bk !== 'upnp'); });
  // 2026-10-25：NAA 已移除，「输出设备」只在 UPnP 投放时无意义。
  _setFieldVisible('sp_device', bk !== 'upnp');
  var tw = D('sp_trimwrap'); if (tw) tw.style.display = (bk === 'upnp') ? 'none' : '';
  // 261024-02 #5：投放区块已整体搬到「流媒体」页（输出页不再有它），这里不再联动隐藏。
}

// 261024-02 #5：推送区块的控件绑定（旧版"填文件路径 + DoP 勾选 + 开始投放"已按用户要求删掉，
// 换成 QQ 音乐式的一键推送：选设备 → 推送当前曲 / 停止投放）。
function initCastControls() {
  var devSel = D('sp_cast_dev');
  var btnScan = D('sp_cast_scan');
  var btnPush = D('sp_cast_push');
  var btnStop = D('sp_cast_stop');

  if (devSel) {
    devSel.onchange = function () {
      var v = devSel.value || '';
      syncUpnpDev(v);
      var d = null;
      for (var i = 0; i < _castDevices.length; i++) if (castDevValue(_castDevices[i]) === v) d = _castDevices[i];
      var msg = D('sp_cast_devmsg');
      if (msg) {
        msg.textContent = d ? ((d.model ? ('型号: ' + d.model + ' · ') : '') + (d.hasAVTransport ? '支持 AVTransport' : '未知传输服务'))
                            : (v ? ('已选择：' + v) : '点「重新发现」扫描局域网里的 MediaRenderer');
      }
    };
  }
  if (btnScan) btnScan.onclick = function () { scanCastDevices(true); };
  if (btnPush) {
    btnPush.onclick = function () {
      if (D('sp_cast_msg')) D('sp_cast_msg').textContent = '';
      // 下拉里选的设备优先（用户可能刚换了一台），否则用已保存的
      if (devSel && devSel.value && devSel.value !== ADV.upnpDev) syncUpnpDev(devSel.value);
      castPush(S.lastCur);
    };
  }
  if (btnStop) btnStop.onclick = function () { castStop(); };
}

/* ---------------- 261024-02 #5：一键推送到 UPnP（学 QQ 音乐） ----------------
   用户原话：「你应该学习的是 QQ 音乐的逻辑，单曲播放页面下有一个将本曲一键推送到 UPNP 的按钮，
   然后所有播放都走 UPNP。」「输出栏位下的 UPNP 投放功能多余。」
   设计：
     * 单一真相源 = /api/cast/state（后端 CastManager）。三处 UI（单曲页按钮 / 底栏徽标 /
       流媒体页推送区块）全部由 applyCastUi(st) 从同一份状态刷新，不各存一份。
     * 推送 = ADV.backend='upnp' + ADV.upnpDev=<描述URL> 落盘，然后按新参数重放当前曲目
       ⟹ 之后的切歌/暂停/seek 全部由后端路由到同一条投放会话（"所有播放都走 UPNP"）。
     * 再点一次 = 停止投放 + 回到推送前的输出后端（默认 wasapi），并恢复本地播放。
       （刻意记 prevBackend 而不是硬编码 wasapi：测试实例是 null，硬编码会把安全设置冲掉。） */
var CAST = { state: null, prevBackend: '' };
function castRunning() { return !!(CAST.state && CAST.state.running); }
function castDevNameOf(loc) {
  loc = String(loc || '');
  for (var i = 0; i < _castDevices.length; i++) {
    if (castDevValue(_castDevices[i]) === loc) return castDevLabel(_castDevices[i]);
  }
  var m = /^https?:\/\/([^/:]+)/i.exec(loc);
  return m ? m[1] : (loc || '设备');
}
function castIconSvg() {
  return '<svg width=12 height=12 viewBox="0 0 24 24" fill=none stroke=currentColor stroke-width="2" ' +
         'style="vertical-align:-1px;margin-right:4px"><path d="M2 16.1A5 5 0 0 1 5.9 20"/><path d="M2 12.05A9 9 0 0 1 9.95 20"/>' +
         '<path d="M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6"/><path d="M2 20h.01"/></svg>';
}
// 三处 UI 的唯一刷新入口
function applyCastUi(st) {
  if (st && typeof st.running === 'boolean') CAST.state = st;
  st = CAST.state || {};
  var running = !!st.running;
  var nm = castDevNameOf(st.device);
  var nb = D('npCastBtn');
  if (nb) {
    nb.innerHTML = castIconSvg() + (running ? ('已推送到 ' + esc(nm)) : '推送到设备');
    nb.classList.toggle('on', running);
    nb.title = running ? ('点击停止投放并恢复本机输出（阶段：' + (st.phase || '-') + '）')
                       : '把当前曲目推送到 UPnP / DLNA 设备，之后所有播放都走它';
  }
  var badge = D('castBadge');
  if (badge) {
    badge.style.display = running ? 'inline-flex' : 'none';
    badge.title = running ? ('正在投放到 ' + nm) : '';
  }
  var push = D('sp_cast_push'), stop = D('sp_cast_stop');
  if (push) { push.textContent = running ? '重新推送当前曲' : '推送当前曲'; }
  if (stop) stop.disabled = !running;
  updateCastStateUi(st);
}
function pollCastState(once) {
  clearTimeout(_castPollTimer);
  var outPane = document.querySelector('#setpage .spane[data-g=out]');
  var streamPane = document.querySelector('#setpage .spane[data-g=stream]');
  var wantLoop = (streamPane && streamPane.classList.contains('on') && D('setpage') && D('setpage').classList.contains('on'))
              || (outPane && outPane.classList.contains('on') && D('setpage') && D('setpage').classList.contains('on'))
              || (D('npPage') && D('npPage').classList.contains('on'))
              || (CAST.state && CAST.state.running);
  api('/api/cast/state').then(function (st) {
    applyCastUi(st);
    if (!once && wantLoop) _castPollTimer = setTimeout(function () { pollCastState(); }, 1000);
  }).catch(function () {
    if (!once && wantLoop) _castPollTimer = setTimeout(function () { pollCastState(); }, 1500);
  });
}
/* ---------------- 曲目右键菜单（2026-10-27，F-5）----------------
   为什么要有它：F-5 需要一个「按需看音质」的入口，但曲目行是 7 列网格，
   再加一列在 1120px 下会挤破（.trow-track 的窄屏媒体查询已经把 bd 列压到 0px）。
   所以入口放右键菜单：零布局风险，且能顺手把原来的"右键=直接入队"变成可见选项
   （原来的入队仍然是第一项，老习惯不变）。
   菜单是绝对定位的临时节点，点任意处/滚动/ESC 都会关掉，不留残留 DOM。 */
/* ---------------- 多版本对比（F-8，2026-10-27）----------------
   数据源：POST /api/compare，body 为表单重复 file=<绝对路径>（2～8 个）。
   为什么用表单而不是 JSON：本地 api() 只发 application/x-www-form-urlencoded，
   后端同时接受两种写法，走表单就不必再引入第二套 fetch 封装。
   口径（铁律 3）：分数/排名/解释全部由后端 version_compare.h 算出，前端只排版。 */
var CMP = { files: [], busy: false };
function cmpBase(p) { return String(p || '').replace(/^.*[\\/]/, ''); }
function cmpNum(v, digits) { return qFmt(v, digits); }
function renderCompare(r) {
  if (!r || !r.ok) return '<div class=hint style="color:var(--warn)">' + esc((r && r.error) || '对比失败') + '</div>';
  var vs = r.versions || [], rows = r.rows || [];
  var h = '<div style="font-size:12px">';
  if (r.sameTrack === false) h += '<div class=hint style="color:var(--warn)">⚠ 包络相关偏低，这些文件可能不是同一首曲子</div>';
  h += '<div style="font-weight:650;margin:6px 0 4px">排序（好 → 差）</div><ol style="margin:0 0 10px 18px;padding:0">';
  (r.ranking || []).forEach(function (i) {
    var v = vs[i] || {};
    h += '<li>' + esc(v.label || ('#' + i)) + ' <span style="color:var(--mut)">' + esc(cmpBase(v.path)) + '</span>' +
         ' — <b>' + cmpNum(v.score, 1) + '</b> 分' +
         (v.error ? ' <span style="color:var(--warn)">' + esc(v.error) + '</span>' : '') + '</li>';
  });
  h += '</ol><div style="max-height:42vh;overflow:auto"><table style="font-size:11.5px;border-collapse:collapse;width:100%">';
  h += '<thead><tr><th style="text-align:left;padding:3px 8px 3px 0">指标</th>';
  vs.forEach(function (v, i) {
    h += '<th style="text-align:right;padding:3px 0 3px 10px;font-weight:600">' + esc(v.label || '') +
         '<div style="font-weight:400;color:var(--mut2);font-size:10.5px;max-width:170px;overflow:hidden;' +
         'text-overflow:ellipsis;white-space:nowrap">' + esc(cmpBase(v.path)) + '</div></th>';
  });
  h += '</tr></thead><tbody>';
  rows.forEach(function (row) {
    h += '<tr' + (row.comparable === false ? ' style="opacity:.55"' : '') +
         '><td style="padding:2px 8px 2px 0;white-space:nowrap">' + esc(row.label || '') +
         (row.unit ? ' <span style="color:var(--mut2)">' + esc(row.unit) + '</span>' : '') +
         (row.comparable === false ? tip(row.why) : '') + '</td>';
    (row.values || []).forEach(function (v, i) {
      var best = (i === row.bestIndex && row.comparable !== false && !row.informational);
      h += '<td style="text-align:right;padding:2px 0 2px 10px;font-variant-numeric:tabular-nums' +
           (best ? ';font-weight:700;color:var(--acc)' : '') + '">' + cmpNum(v) + '</td>';
    });
    h += '</tr>';
  });
  h += '</tbody></table></div>';
  h += '<div class=hint style="margin-top:8px;white-space:pre-wrap">' + esc(r.explanation || '') + '</div></div>';
  return h;
}
function cmpRun() {
  var sel = CMP.files.filter(function (f) { return f.on; }).map(function (f) { return f.path; });
  if (sel.length < 2) { D('cmpMsg').textContent = '至少勾选 2 个版本'; return; }
  if (sel.length > 8) { D('cmpMsg').textContent = '一次最多 8 个版本'; return; }
  if (CMP.busy) return;
  CMP.busy = true;
  D('cmpMsg').textContent = '正在对齐并分析 ' + sel.length + ' 个版本…';
  if (D('cmpGo')) D('cmpGo').disabled = true;
  var body = sel.map(function (f) { return 'file=' + encodeURIComponent(f); }).join('&');
  api('/api/compare', body).then(function (r) {
    CMP.busy = false;
    if (D('cmpGo')) D('cmpGo').disabled = false;
    if (D('cmpMsg')) D('cmpMsg').textContent = '';
    if (D('cmpOut')) D('cmpOut').innerHTML = renderCompare(r);
  }).catch(function (e) {
    CMP.busy = false;
    if (D('cmpGo')) D('cmpGo').disabled = false;
    if (D('cmpMsg')) D('cmpMsg').textContent = '对比失败：' + (e && e.message ? e.message : e);
  });
}
function openCompareModal(path) {
  var dir = String(path || '').replace(/[\\/][^\\/]*$/, '');
  if (!dir) { toast('没有可对比的曲目'); return; }
  openModal('对比版本', '<div class=hint>正在列出可选文件…</div>');
  api('/api/files?dir=' + encodeURIComponent(dir)).then(function (j) {
    var names = (j && j.files) || [];
    if (!names.length) { D('mbody').innerHTML = '<div class=hint>该目录下没有可对比的音频文件</div>'; return; }
    var base = cmpBase(path);
    CMP.files = names.map(function (n) { return { path: dir + '/' + n, on: n === base }; });
    var h = '<div class=hint style="margin-bottom:8px">' + esc(dir) +
            '：勾选 2～8 个版本（同一首曲子的不同转制/母带）</div>' +
            '<div style="max-height:46vh;overflow:auto;display:flex;flex-direction:column;gap:2px">';
    CMP.files.forEach(function (f, i) {
      h += '<label style="font-size:12px;display:flex;gap:8px;align-items:center">' +
           '<input type=checkbox class=cmpck data-i=' + i + (f.on ? ' checked' : '') + '>' +
           esc(cmpBase(f.path)) + '</label>';
    });
    h += '</div><div style="display:flex;gap:10px;align-items:center;margin-top:10px">' +
         '<button class="btn pri" id=cmpGo>开始对比</button><span class=hint id=cmpMsg></span></div>' +
         '<div id=cmpOut></div>';
    D('mbody').innerHTML = h;
    Array.prototype.forEach.call(document.querySelectorAll('#mbody .cmpck'), function (c) {
      c.onchange = function () { CMP.files[+this.dataset.i].on = this.checked; };
    });
    if (D('cmpGo')) D('cmpGo').onclick = cmpRun;
  }).catch(function (e) {
    D('mbody').innerHTML = '<div class=hint style="color:var(--warn)">列目录失败：' + esc(String(e && e.message || e)) + '</div>';
  });
}
function trackActionMenu(tk, x, y) {
  var old = D('__tmenu');
  if (old) old.remove();
  if (!tk || !tk.path) return;
  var items = [
    { k: 'queue', t: '加入播放队列', f: function () { addPathCue(tk.path, tk.cs, tk.ce); } },
    { k: 'addsq', t: '保存到歌单…', f: function () { addToSavedQueue(tk.path, tk.cs, tk.ce); } },
  ];
  // 音质体检只对真实存在的本地文件有意义（网络曲目后端没有本地路径）
  if (!/^https?:/i.test(tk.path)) {
    items.push({ k: 'quality', t: '音质体检…', f: function () { openQualityModal(tk.path); } });
    // F-8：同目录多版本对比（2～8 个）。只对本地文件有意义。
    items.push({ k: 'compare', t: '对比同目录版本…', f: function () { openCompareModal(tk.path); } });
  }
  var h = '<div id=__tmenu style="position:fixed;z-index:9999;left:' + (x || 0) + 'px;top:' + (y || 0) + 'px;' +
          'background:var(--toast);border:1px solid var(--line);border-radius:9px;padding:5px;min-width:150px;' +
          'box-shadow:0 10px 30px rgba(0,0,0,.45);font-size:12.5px">';
  items.forEach(function (it, i) {
    h += '<button data-k="' + it.k + '" style="display:block;width:100%;text-align:left;padding:7px 11px;' +
         'background:none;border:0;border-radius:6px;color:var(--txt);font-size:12.5px;cursor:pointer">' +
         esc(it.t) + '</button>';
  });
  h += '</div>';
  var box = document.createElement('div');
  box.innerHTML = h;
  var m = box.firstChild;
  document.body.appendChild(m);
  // 夹在视口内：右键点太靠右/靠下时不要跑出屏幕
  var r = m.getBoundingClientRect();
  if (r.right > innerWidth - 8) m.style.left = Math.max(8, innerWidth - r.width - 8) + 'px';
  if (r.bottom > innerHeight - 8) m.style.top = Math.max(8, innerHeight - r.height - 8) + 'px';

  var close = function () {
    if (m && m.parentNode) m.parentNode.removeChild(m);
    document.removeEventListener('click', close, true);
    document.removeEventListener('scroll', close, true);
    document.removeEventListener('keydown', onKey, true);
  };
  var onKey = function (e) { if (e.key === 'Escape') close(); };
  items.forEach(function (it) {
    var b = m.querySelector('[data-k="' + it.k + '"]');
    if (b) b.onclick = function (ev) { ev.stopPropagation(); close(); it.f(); };
  });
  // capture 阶段挂，保证点"任何地方"（含别的行）都能关，且不会误触行本身的 onclick
  setTimeout(function () {
    document.addEventListener('click', close, true);
    document.addEventListener('scroll', close, true);
    document.addEventListener('keydown', onKey, true);
  }, 0);
}

/* ---------------- 音质体检弹窗（F-5，2026-10-27）----------------
   数据源：GET /api/track/health?file=<path> → { ok, health:{ …quality:{19 项} } }
   为什么单独做弹窗：19 项指标塞进列表会把行高撑爆；用户是按需看，不是常驻。
   口径（铁律 3）：所有数字都来自后端实测，前端**不做任何再计算**，只做单位与色阶。
   不可用的指标（如 IMD 需双音素材）显示「不适用」+ 原因，绝不显示 0 冒充正常。 */
var QMODAL = { file: '', req: 0 };
function qFmt(v, digits, unit) {
  // 数值守卫（Q-3 的同一口径）：undefined/null/NaN/Infinity 一律回 '-'，不显示 "NaN"
  if (v === undefined || v === null || typeof v !== 'number' || !isFinite(v)) return '-';
  if (v <= -299 && v > -1e6) return '不适用';
  return v.toFixed(digits !== undefined ? digits : 2) + (unit || '');
}
window.qFmt = qFmt;
function qRow(label, val, hint) {
  return '<div style="display:flex;justify-content:space-between;gap:12px;padding:5px 0;border-bottom:1px solid var(--line)">' +
         '<span style="color:var(--txt2);font-size:12px">' + esc(label) + '</span>' +
         '<span style="color:var(--txt);font-size:12px;font-weight:600;font-variant-numeric:tabular-nums">' + val + '</span>' +
         '</div>' + (hint ? '<div style="color:var(--mut2);font-size:10.5px;padding:2px 0 6px;line-height:1.45">' + esc(hint) + '</div>' : '');
}
function qSection(title) {
  return '<div style="margin:14px 0 4px;font-size:12.5px;font-weight:650;color:var(--acc)">' + esc(title) + '</div>';
}
function openQualityModal(file) {
  if (!file) { toast('没有可分析的曲目'); return; }
  QMODAL.file = file;
  var seq = ++QMODAL.req;
  var base = file.split(/[\\/]/).pop() || file;
  openModal('音质体检', '<div class=hint>正在分析…（大文件需要几秒，DSD 走流式分块读）</div>' +
                       '<div class=hint style="margin-top:6px;opacity:.75">' + esc(base) + '</div>');
  api('/api/track/health?file=' + encodeURIComponent(file)).then(function (j) {
    if (seq !== QMODAL.req) return;                      // 已切到别的曲目 → 丢弃
    if (!j || !j.ok) {
      D('mbody').innerHTML = '<div class=hint style="color:var(--warn)">无法分析：' +
        esc((j && j.error) || '未知原因') + '</div>';
      return;
    }
    var h = j.health || {};
    var q = h.quality || {};
    var s = '';
    s += '<div class=hint style="margin-bottom:6px">' + esc(base) + ' · ' +
         esc(String(h.fs || '?')) + ' Hz · ' + esc(String(h.bits || '?')) + ' bit · ' +
         esc(String(h.channels || '?')) + ' ch · ' + qFmt(h.duration_sec, 1, ' s') + '</div>';

    // 动态与响度（体检原有）
    s += qSection('响度与动态');
    s += qRow('响度 (LUFS)', qFmt(h.lufs, 2));
    s += qRow('动态范围 DR', qFmt(h.dr_db, 2, ' dB'));
    s += qRow('响度范围 LRA', qFmt(h.lra, 2, ' LU'));
    s += qRow('峰值', qFmt(h.peak_dbfs, 2, ' dBFS'));

    if (typeof q.available === 'boolean' && !q.available) {
      s += '<div class=hint style="margin-top:12px;color:var(--warn)">音质指标不可用：' +
           esc(q.note || '素材不足') + '</div>';
      D('mbody').innerHTML = s;
      return;
    }

    s += qSection('失真');
    if (q.thdn_available) s += qRow('THD+N', qFmt(q.thdn_db, 2, ' dB') + '（' + qFmt(q.thdn_pct, 3, '%') + '）');
    else s += qRow('THD+N', '<span style="color:var(--mut2)">不适用（多峰素材）</span>');
    s += qRow('非谐波残留', qFmt(q.non_tonal_db, 2, ' dB'), '16 个最强谱峰之外的能量占比；音乐素材下是噪声+失真上界');
    if (q.imd_available) s += qRow('互调失真 IMD', qFmt(q.imd_db, 2, ' dB'));
    else s += qRow('互调失真 IMD', '<span style="color:var(--mut2)">不适用</span>',
                   q.imd_note || '需要双音素材');

    s += qSection('噪声');
    s += qRow('本底噪声', qFmt(q.noise_floor_dbfs, 2, ' dBFS'), '最低 10% 的 100ms 块电平');
    s += qRow('信噪比', qFmt(q.snr_db, 2, ' dB'));
    s += qRow('RMS', qFmt(q.rms_dbfs, 2, ' dBFS'));

    s += qSection('频响');
    s += qRow('频谱重心', qFmt(q.centroid_hz, 0, ' Hz'), '亮度指标');
    s += qRow('频谱倾斜', qFmt(q.tilt_db_per_oct, 2, ' dB/oct'));
    s += qRow('95% 滚降点', qFmt(q.rolloff95_hz, 0, ' Hz'));
    s += qRow('10kHz 以上能量', qFmt(q.hf_ratio_10k_db, 2, ' dB'));

    s += qSection('削波与峰值');
    s += qRow('削波样本', String(q.clipped_samples == null ? '-' : q.clipped_samples) +
              '（' + qFmt(q.clipped_pct, 4, '%') + '）');
    s += qRow('最长连续削波', String(q.longest_clip_run == null ? '-' : q.longest_clip_run) + ' 样本');
    s += qRow('峰值因子', qFmt(q.crest_db, 2, ' dB'));

    s += qSection('立体声');
    if (q.stereo) {
      s += qRow('声道相关', qFmt(q.channel_corr, 3));
      s += qRow('单声道兼容损失', qFmt(q.mono_loss_db, 2, ' dB'));
      s += qRow('side/mid', qFmt(q.side_mid_db, 1, ' dB'));
    } else {
      s += qRow('立体声', '<span style="color:var(--mut2)">单声道素材</span>');
    }

    s += qSection('动态细化');
    s += qRow('P95−P10', qFmt(q.dyn_p95_p10_db, 2, ' dB'), '3 秒块 RMS 分布');
    s += qRow('动态重心', qFmt(q.dyn_centroid_dbfs, 2, ' dBFS'));

    if (q.note) s += '<div class=hint style="margin-top:12px;line-height:1.5">' + esc(q.note) + '</div>';
    D('mbody').innerHTML = s;
  }).catch(function (e) {
    if (seq !== QMODAL.req) return;
    D('mbody').innerHTML = '<div class=hint style="color:var(--warn)">分析失败：' + esc(String(e)) + '</div>';
  });
}

function openModal(title, html) {
  var m = D('modal'); if (!m) return;
  D('mtitle').textContent = title;
  D('mbody').innerHTML = html;
  m.classList.add('on');
}
// 未选设备时的设备选择浮层
function npPickCastDevice(cb) {
  api('/api/cast/devices?scan=1').then(function (j) {
    _castDevices = (j && j.devices) || [];
    populateCastDevices();
    if (!_castDevices.length) {
      toast('未发现 UPnP / DLNA 渲染器（确认数播已开启 DLNA 且与本机同网段）');
      cb(null);
      return;
    }
    var h = '<div class=castpick>';
    _castDevices.forEach(function (d, i) {
      h += '<button class=castpick-row data-i=' + i + '>' +
           '<span class=cpn>' + esc(d.friendlyName || d.name || d.host) + '</span>' +
           '<span class=cph>' + esc((d.model ? d.model + ' · ' : '') + (d.host || '')) + '</span></button>';
    });
    h += '</div><div class=hint style="margin-top:10px">选中后会把当前曲目推送到该设备，之后的切歌/暂停/进度都作用在它上面。</div>';
    openModal('推送到设备', h);
    Array.prototype.forEach.call(D('mbody').querySelectorAll('.castpick-row'), function (b) {
      b.onclick = function () {
        var d = _castDevices[+b.dataset.i];
        D('modal').classList.remove('on');
        cb(castDevValue(d));
      };
    });
  }).catch(function () { toast('设备发现失败（/api/cast/devices 无响应）'); cb(null); });
}
// 推送：落盘 backend=upnp + upnpdev，再按新参数重放当前曲
function castPush(file) {
  file = file || S.lastCur || '';
  if (!file) { toast('当前没有可推送的曲目'); return; }
  if (/^https?:/i.test(file)) { toast('网络曲目暂不支持投放'); return; }
  var go = function (dev) {
    if (!dev) return;
    CAST.prevBackend = (ADV.backend && ADV.backend !== 'upnp') ? ADV.backend : (CAST.prevBackend || 'wasapi');
    ADV.backend = 'upnp';
    ADV.upnpDev = dev;
    saveSettings();
    playPath(file);
    toast('已推送到 ' + castDevNameOf(dev));
    pollCastState(true);
  };
  var dev = (ADV.upnpDev || '').trim();
  if (dev) go(dev);
  else npPickCastDevice(function (d) { if (d) go(d); });
}
// 停止：停会话 → 回到推送前的输出后端 → 恢复本地播放
function castStop() {
  api('/api/cast/stop', '').then(function () {
    var back = CAST.prevBackend || 'wasapi';
    if (back === 'upnp') back = 'wasapi';
    ADV.backend = back;
    saveSettings();
    toast('已停止投放，输出回到 ' + back);
    if (S.lastCur) playPath(S.lastCur);
    pollCastState(true);
  }).catch(function () { toast('停止投放失败'); });
}
function castToggle() {
  if (castRunning()) castStop();
  else castPush(S.lastCur);
}
function npCastBtnHtml() {
  var running = castRunning();
  return '<button class="chip npcast' + (running ? ' on' : '') + '" id=npCastBtn title="' +
         (running ? '点击停止投放并恢复本机输出' : '把当前曲目推送到 UPnP / DLNA 设备') + '">' +
         castIconSvg() + (running ? ('已推送到 ' + esc(castDevNameOf((CAST.state || {}).device))) : '推送到设备') +
         '</button>' +
         '<button class="chip" id=npAddSq title="把当前曲目添加到指定歌单">' +
         '<svg width=12 height=12 viewBox="0 0 24 24" fill=none stroke=currentColor stroke-width="2" style="vertical-align:-1px;margin-right:4px"><path d="M12 5v14M5 12h14"/></svg>添加到歌单' +
         '</button>';
}

/* ---------------- 输出模式 / DSD 比特率 / 封装 ---------------- */
function outModeOf() { return (D('sDSD') && D('sDSD').value !== '0') ? 'dsd' : 'pcm'; }
function dsdRateOf() {
  var v = (D('sDSD') && D('sDSD').value) || '0';
  if (v === '0') return '256';                 // PCM 时给个默认值，别让下拉空着
  var m = /([0-9]+)$/.exec(v);
  return m ? m[1] : '256';
}
// 2026-10-25（A1 隐藏）：Native DSD 在 macOS 上无法实现，选项已从界面移除。
// 本函数恒返回 'dop'；老 conf 里存过 'nat' 的，由 migrateDsdPack() 在加载时降级并提示。
function dsdPackOf() { return 'dop'; }
// 三个控件合成隐藏的 sDSD（params()/saveSettings 仍然只认这一个状态）
// 2026-10-24（用户 261024-01 #12）：这里的 disabled 逻辑整个删掉。
// 「SDM 的比特率和封装为什么灰了无法选？」—— 根因就是这一句：只在输出模式已经是 DSD 时才允许改，
// 而默认是 PCM ⟹ 两个下拉永远灰着。现在它们始终可选；在 PCM 下改动会自动把输出切到 DSD
//（联动在控件 onchange 里），并有一句常驻说明指出这件事。
function applyDsdState() {
  var isDsd = D('sp_outmode') && D('sp_outmode').value === 'dsd';
  ['sp_dsdrate', 'sp_dsdpk'].forEach(function (id) {
    var e = D(id);
    if (!e) return;
    e.disabled = false;
    e.style.opacity = '1';
    e.removeAttribute('aria-disabled');
    e.title = isDsd ? '' : '改这里会把输出模式切到 DSD（SDM）';
  });
  var note = D('sp_dsdmodenote');
  if (note) note.style.display = isDsd ? 'none' : '';
}
function applyDsd() {
  var out = D('sp_outmode') ? D('sp_outmode').value : 'pcm';
  if (out !== 'dsd') { D('sDSD').value = '0'; return; }
  var pk = D('sp_dsdpk') ? D('sp_dsdpk').value : 'dop';
  var rt = D('sp_dsdrate') ? D('sp_dsdrate').value : '256';
  D('sDSD').value = pk + rt;
}

// 声道名（WAVEFORMATEXTENSIBLE 的典型顺序）
function channelNames(n) {
  if (n <= 1) return ['单声道'];
  if (n === 2) return ['左', '右'];
  if (n === 4) return ['左', '右', '左后', '右后'];
  if (n === 6) return ['左', '右', '中置', '低音', '左环绕', '右环绕'];
  if (n === 8) return ['左', '右', '中置', '低音', '左环绕', '右环绕', '左后', '右后'];
  var out = [];
  for (var i = 0; i < n; ++i) out.push('声道 ' + (i + 1));
  return out;
}
function bindTrims() {
  for (var i = 0; i < 8; ++i) {
    (function (k) {
      var e = D('sp_trim' + k);
      if (e) e.oninput = function () { ADV['trim' + k] = parseFloat(this.value) || 0; saveSettings(); };
    })(i);
  }
}
function trimFields(chSel) {
  var n = parseInt(chSel, 10) || 0;
  if (!n) n = 2;                       // 跟随源时先按立体声显示
  var names = channelNames(n);
  var h = '';
  for (var i = 0; i < names.length && i < 8; ++i) {
    h += '<div class=sfld><label>' + names[i] + '（声道 ' + (i + 1) + '，dB）</label>' +
         '<input type=number id=sp_trim' + i + ' value="' + (ADV['trim' + i] || 0) +
         '" min=-24 max=12 step=0.1></div>';
  }
  return h;
}

function sgroup(title, hint, body) {
  if (body === undefined) { body = hint; hint = ''; }
  return '<div class=sgroup><div class=sghead>' + title + tip(hint) +
         '</div><div class=sgbody>' + (body || '') + '</div></div>';
}

// ---- 功能2（用户 2026-10-22）：把「跟随预设」跟的是什么相位实时说清楚 ----
// 数据来自 /api/filters（后端 filter_presets() 的真相源），前端不抄第二份相位表。
var FILTER_PHASES = null;      // name -> {phase, phaseName, taps}
var FILTER_PHASES_WANT = 0;    // 还没到就记下，到了再补渲染
function loadFilterPhases() {
  return api('/api/filters').then(function (j) {
    if (!j || !j.ok || !j.items) return;
    FILTER_PHASES = {};
    j.items.forEach(function (it) { FILTER_PHASES[it.name] = it; });
    bindPhaseHint();
  }).catch(function () { });
}
// 把"当前 1x 滤波器的预设相位"和"强制覆盖后的实际相位"一起写进 #sp_phasemsg。
function bindPhaseHint() {
  var msg = D('sp_phasemsg');
  if (!msg) return;
  var fname = (D('sp_filt') && D('sp_filt').value) || '';
  var override = (D('sp_phase') && D('sp_phase').value) || '';
  if (!fname) { msg.textContent = ''; return; }
  var it = FILTER_PHASES ? FILTER_PHASES[fname] : null;
  if (!it) {
    // 相位表还没回来（或该滤波器不在表里）：只说清"预设"是什么，不编造具体相位
    msg.textContent = '预设相位：读取中…';
    return;
  }
  var actual = override
    ? ({ linear: '线性相位', minimum: '最小相位', intermediate: '混合相位' }[override] || override)
    : it.phaseName;
  // 2026-10-24 #7：一行说清「预设 / 实际」，不再展开解释什么叫覆盖。
  msg.textContent = '预设 ' + it.phaseName + '（抽头 ' + it.taps + '）· 实际输出 ' + actual + (override ? '（强制覆盖）' : '');
}

// ---- 功能4（用户 2026-10-22）：DeepSeek API Key 的界面入口 ----
// 三条硬约束（对应后端 /api/llm）：
//   ① 界面只显示掩码（sk-****abcd）：GET 只回 mask，输入框永不回填；
//   ② 保存后立刻清空输入框 —— 明文不在 DOM 里多停留一秒；
//   ③ 与 /api/settings 完全分离：key 进 rlplayer-llm.conf，普通设置进另一个文件。
var LLM = { configured: false, masked: '', model: 'deepseek-flash', baseUrl: '', proxy: false, loaded: false };
function llmRender(j) {
  if (j && j.ok) {
    LLM.configured = !!j.configured;
    LLM.masked = j.masked || '';
    LLM.model = j.model || 'deepseek-flash';
    LLM.baseUrl = j.baseUrl || '';
    LLM.proxy = !!j.proxy;
    LLM.loaded = true;
  }
  var m = D('sp_llmmsg');
  if (!m) return;
  if (!LLM.loaded) { m.textContent = '读取配置中…'; return; }
  var s = LLM.configured
    ? ('已配置：' + LLM.masked + '（模型 ' + LLM.model + '）')
    : '未配置 —— 填入 DeepSeek API Key 后点「保存 Key」';
  m.textContent = s + '；key 只存本机 rlplayer-llm.conf，不进安装包、界面从不回显明文' +
    (LLM.proxy ? '；配置里的 proxy= 行已保留' : '');
}
function llmRefresh() {
  return fetch('/api/llm').then(function (r) { return r.json(); }).then(llmRender)
    .catch(function () { var m = D('sp_llmmsg'); if (m) m.textContent = '读取配置失败（服务没响应）'; });
}
function llmPost(body, okMsg) {
  return fetch('/api/llm', { method: 'POST', body: body })
    .then(function (r) { return r.json(); })
    .then(function (j) {
      if (!j || !j.ok) { toast('操作失败：' + ((j && j.error) || '未知错误')); return j; }
      var e = D('sp_llmkey');
      if (e) e.value = '';                       // 明文绝不在 DOM 里停留
      llmRender(j);
      if (okMsg) toast(okMsg);
      return j;
    });
}
function llmSave() {
  var e = D('sp_llmkey');
  var k = e ? String(e.value || '').replace(/^\s+|\s+$/g, '') : '';
  if (!k) { toast('先填入 API Key；留空保存不会改动现有配置'); return; }
  llmPost('key=' + encodeURIComponent(k), 'API Key 已保存（界面只显示掩码）');
}
function llmClear() { llmPost('clear=1', '已清除 API Key（可随时重新填入）'); }
function llmTest() {
  var b = D('sp_llmtest'), m = D('sp_llmmsg');
  if (b) { b.disabled = true; b.textContent = '测试中…'; }
  fetch('/api/llm/test').then(function (r) { return r.json(); }).then(function (j) {
    if (b) { b.disabled = false; b.textContent = '测试连接'; }
    if (!m) return;
    if (j && j.ok) m.textContent = '连接成功：模型 ' + j.model + '，耗时 ' + j.latencyMs + ' ms（key 有效）';
    else m.textContent = '连接失败：' + ((j && j.error) || '未知错误');
  }).catch(function () {
    if (b) { b.disabled = false; b.textContent = '测试连接'; }
    if (m) m.textContent = '连接失败：服务没响应';
  });
}

/* ---------------- 官方推荐预设与硬件能力 ---------------- */
var _capsCache = null;
var _capsTime = 0;

function setSelectValue(sel, val) {
  if (!sel || val === undefined || val === null) return;
  var strVal = String(val);
  var found = false;
  for (var i = 0; i < sel.options.length; i++) {
    if (sel.options[i].value === strVal) { found = true; break; }
  }
  if (!found) {
    var opt = document.createElement('option');
    opt.value = strVal;
    opt.textContent = strVal;
    sel.appendChild(opt);
  }
  sel.value = strVal;
}

function presetCardHtml() {
  var dev = (_capsCache && _capsCache.device) || {};
  var name = dev.name || '检测中…';
  var maxRate = dev.maxRate ? (dev.maxRate + ' Hz') : '- Hz';
  var dsdStr = '-';
  if (dev.dsdNative !== undefined) {
    dsdStr = dev.dsdNative ? ('是（最高 ' + (dev.dsdNativeMax || 'dsd256') + '）') : '否';
  }
  var pcmTargetRate = dev.maxRate ? dev.maxRate : '384000';
  var dsdTarget = (dev.dsdNative && dev.dsdNativeMax) ? dev.dsdNativeMax : (dev.dopMax || dev.dsdNativeMax || 'dsd256');

  var dsdBadge = '';
  if (dev.dsdNative === false) {
    dsdBadge = dev.dop ? '★ 降级为 DoP' : '★ 硬件不支持 DSD';
  }
  var pcmBadge = '';
  if (dev.maxRate && dev.maxRate <= 192000) {
    pcmBadge = '★ 仅到 ' + (dev.maxRate >= 1000 ? (dev.maxRate / 1000 + 'k') : dev.maxRate);
  }

  var h = '<div class="preset-card" id=presetCard>'
        + '<div class=preset-card-head>'
        + '<span class=preset-card-title>'
        + '<svg width=15 height=15 viewBox="0 0 24 24" fill=none stroke=currentColor stroke-width=2 style="color:var(--acc)"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>'
        + '官方推荐预设'
        + '</span>'
        + '<button class="btn" id=presetCapsRefresh title="刷新硬件能力" aria-label="刷新硬件能力" style="font-size:11.5px;padding:3px 9px;display:flex;align-items:center;gap:4px">'
        + '<svg width=12 height=12 viewBox="0 0 24 24" fill=none stroke=currentColor stroke-width=2><path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/></svg>'
        + '刷新</button>'
        + '</div>'
        + '<div class=preset-caps-line id=presetCapsInfo>'
        + '当前设备：' + esc(name) + ' · 最高 ' + esc(maxRate) + ' · 原生 DSD ' + esc(dsdStr)
        + '</div>'
        + '<div class=preset-grid>'
        + '<button class=preset-btn id=presetBitPerfect aria-label="原音直通（bit-perfect）">'
        + '<div class=preset-btn-top>'
        + '<span class=preset-btn-title>原音直通（bit-perfect）</span>'
        + '<span class=preset-btn-badge id=presetBpBadge style="' + (dev.exclusive === false ? '' : 'display:none') + '">' + (dev.exclusive === false ? '★ 仅共享模式' : '') + '</span>'
        + '</div>'
        + '<div class=preset-btn-sub>不升频、音量 0 dB、无 EQ/IR；只保证不动数据，不等于最好听</div>'
        + '</button>'
        + '<button class=preset-btn id=presetPcm aria-label="PCM 升频">'
        + '<div class=preset-btn-top>'
        + '<span class=preset-btn-title>PCM 升频</span>'
        + '<span class=preset-btn-badge id=presetPcmBadge style="' + (pcmBadge ? '' : 'display:none') + '">' + pcmBadge + '</span>'
        + '</div>'
        + '<div class=preset-btn-sub id=presetPcmSub>升到设备最高档（当前 ' + esc(pcmTargetRate) + '），tight 滤波 + 每相位 512 抽头</div>'
        + '</button>'
        + '<button class=preset-btn id=presetDsd aria-label="DSD 升频">'
        + '<div class=preset-btn-top>'
        + '<span class=preset-btn-title>DSD 升频</span>'
        + '<span class=preset-btn-badge id=presetDsdBadge style="' + (dsdBadge ? '' : 'display:none') + '">' + dsdBadge + '</span>'
        + '</div>'
        + '<div class=preset-btn-sub id=presetDsdSub>升到 ' + esc(dsdTarget) + '，EC-7 调制器</div>'
        + '</button>'
        + '</div>'
        + '</div>';
  return h;
}

function renderPresetCaps(j) {
  if (!j || !j.ok) return;
  var dev = j.device || {};
  var name = dev.name || '默认设备';
  var maxRate = dev.maxRate ? (dev.maxRate + ' Hz') : '未知';
  var dsdStr = dev.dsdNative ? ('是（最高 ' + (dev.dsdNativeMax || 'dsd256') + '）') : '否';

  if (D('presetCapsInfo')) {
    D('presetCapsInfo').textContent = '当前设备：' + name + ' · 最高 ' + maxRate + ' · 原生 DSD ' + dsdStr;
  }
  var pcmTargetRate = dev.maxRate ? dev.maxRate : '384000';
  if (D('presetPcmSub')) {
    D('presetPcmSub').textContent = '升到设备最高档（当前 ' + pcmTargetRate + '），tight 滤波 + 每相位 512 抽头';
  }
  var dsdTarget = (dev.dsdNative && dev.dsdNativeMax) ? dev.dsdNativeMax : (dev.dopMax || dev.dsdNativeMax || 'dsd256');
  if (D('presetDsdSub')) {
    D('presetDsdSub').textContent = '升到 ' + dsdTarget + '，EC-7 调制器';
  }
  if (D('presetDsdBadge')) {
    if (dev.dsdNative === false) {
      D('presetDsdBadge').textContent = dev.dop ? '★ 降级为 DoP' : '★ 硬件不支持 DSD';
      D('presetDsdBadge').style.display = '';
    } else {
      D('presetDsdBadge').style.display = 'none';
    }
  }
  if (D('presetPcmBadge')) {
    if (dev.maxRate && dev.maxRate <= 192000) {
      D('presetPcmBadge').textContent = '★ 仅到 ' + (dev.maxRate >= 1000 ? (dev.maxRate / 1000 + 'k') : dev.maxRate);
      D('presetPcmBadge').style.display = '';
    } else {
      D('presetPcmBadge').style.display = 'none';
    }
  }
  if (D('presetBpBadge')) {
    if (dev.exclusive === false) {
      D('presetBpBadge').textContent = '★ 仅共享模式';
      D('presetBpBadge').style.display = '';
    } else {
      D('presetBpBadge').style.display = 'none';
    }
  }
}

var _capsDeviceSeen = null;   // null=还没拿到过；''=默认设备；其它=设备 id
function loadPresetCaps(force) {
  var now = Date.now();
  if (!force && _capsCache && (now - _capsTime < 10000)) {
    renderPresetCaps(_capsCache);
    return Promise.resolve(_capsCache);
  }
  return fetch('/api/preset/caps').then(function (r) {
    return r.json();
  }).then(function (j) {
    if (j && j.ok) {
      _capsCache = j;
      _capsTime = Date.now();
      renderPresetCaps(j);
    }
    return j;
  }).catch(function (err) {
    console.error('loadPresetCaps error:', err);
  });
}

function applyPresetControls(applied, profile) {
  if (!applied || typeof applied !== 'object') return;

  var r = applied.rate !== undefined ? applied.rate : applied.sRate;
  if (r === undefined && profile === 'bitperfect') r = 'follow';
  if (r !== undefined) {
    ADV.rate = r;
    setSelectValue(D('sRate'), r);
    setSelectValue(D('sp_rate'), r);
  }

  var f = applied.filter !== undefined ? applied.filter : applied.sFilt;
  if (f !== undefined) {
    ADV.filter = f;
    setSelectValue(D('sFilt'), f);
    setSelectValue(D('sp_filt'), f);
  }

  var fnx = applied.filterNx !== undefined ? applied.filterNx : applied.sFiltNx;
  if (fnx !== undefined) {
    ADV.filterNx = fnx;
    setSelectValue(D('sFiltNx'), fnx);
    setSelectValue(D('sp_filtNx'), fnx);
  }

  var sh = applied.shaper !== undefined ? applied.shaper : applied.sShap;
  if (sh === undefined && profile === 'bitperfect') sh = 'none';
  if (sh !== undefined) {
    ADV.shaper = sh;
    setSelectValue(D('sShap'), sh);
    setSelectValue(D('sp_shaper'), sh);
  }

  var dsd = applied.dsd !== undefined ? applied.dsd : applied.sDSD;
  if (dsd === undefined && (profile === 'bitperfect' || profile === 'pcm')) dsd = '0';
  if (dsd !== undefined) {
    setSelectValue(D('sDSD'), dsd);
    if (D('sp_outmode')) D('sp_outmode').value = outModeOf();
    if (D('sp_dsdrate')) D('sp_dsdrate').value = dsdRateOf();
    if (D('sp_dsdpk')) D('sp_dsdpk').value = dsdPackOf();
    applyDsdState();
  }

  var buf = applied.buffer !== undefined ? applied.buffer : applied.sBuf;
  if (buf !== undefined) {
    if (D('sBuf')) D('sBuf').value = String(buf);
    if (D('sp_buffer')) D('sp_buffer').value = String(buf);
  }

  var vol = applied.volume !== undefined ? applied.volume : applied.vol;
  if (vol === undefined && profile === 'bitperfect') vol = 0;
  if (vol !== undefined) {
    // ⚠️ 2026-10-26 修（用户实测：点完预设音量条归零但音量还是满的）：
    //   `vol` 是 **dB**（后端 applied.volume 语义），而 #vol 滑块是**位置刻度 0..1000**。
    //   旧代码 `D('vol').value = String(vNum)` 把 dB 直接当位置塞进去 ⟹ 0 dB（满音量）
    //   被写成位置 0（最左 = 静音档）⟹ 条归零、声音照旧满 —— 两个谎同时成立。
    //   正确：先用 volDbToPos() 换算，再用 volNormalize() 归一（-120 静音档等边界），
    //   与 /api/status 回调里的处理保持同一口径。
    var vNum = volNormalize(Number(vol));
    S.vol = vNum;
    S.volDb = vNum;
    if (D('vol')) D('vol').value = String(volDbToPos(vNum));
    if (D('volDb')) D('volDb').textContent = vNum.toFixed(1) + ' dB';
    syncVolUi();                      // 两个滑块（#vol / #npVol）+ 标签一起对齐
    api('/api/volume', 'vol=' + vNum).catch(function () {});
  }

  var isp = applied.isp !== undefined ? applied.isp : applied.sIsp;
  if (isp === undefined && profile === 'bitperfect') isp = false;
  if (isp !== undefined) {
    var ispBool = (isp === true || isp === 1 || isp === '1');
    if (D('sIsp')) D('sIsp').checked = ispBool;
    if (D('sp_isp')) D('sp_isp').checked = ispBool;
    ADV.isp = ispBool;
  }

  var s2s = applied.twostage !== undefined ? applied.twostage : applied.s2s;
  if (s2s !== undefined) {
    var s2sBool = (s2s === true || s2s === 1 || s2s === '1');
    if (D('s2s')) D('s2s').checked = s2sBool;
    if (D('sp_2s')) D('sp_2s').checked = s2sBool;
  }

  if (applied.backend !== undefined) {
    if (D('sp_backend')) D('sp_backend').value = applied.backend;
    ADV.backend = applied.backend;
    applyBackendState();
  }

  for (var k in applied) {
    var el = D(k);
    if (el) {
      if (el.tagName === 'SELECT') setSelectValue(el, applied[k]);
      else if (el.type === 'checkbox') el.checked = !!applied[k];
      else el.value = applied[k];
    }
  }

  saveSettings(true);
  tick();
  if (typeof syncLiveSignal === 'function') syncLiveSignal();
  if (typeof updateSignalChain === 'function') updateSignalChain();
  if (D('modal') && D('modal').classList.contains('on')) showChain();
}

function applyPreset(profile) {
  var bBp = D('presetBitPerfect'), bPcm = D('presetPcm'), bDsd = D('presetDsd');
  if (bBp) bBp.disabled = true;
  if (bPcm) bPcm.disabled = true;
  if (bDsd) bDsd.disabled = true;

  return api('/api/preset/apply?profile=' + encodeURIComponent(profile), '').then(function (j) {
    if (bBp) bBp.disabled = false;
    if (bPcm) bPcm.disabled = false;
    if (bDsd) bDsd.disabled = false;

    if (!j || !j.ok) {
      toast((j && (j.error || j.message)) || '应用预设失败');
      return j;
    }

    if (j.applied) {
      applyPresetControls(j.applied, profile);
    }

    ['presetBitPerfect', 'presetPcm', 'presetDsd'].forEach(function (id) {
      if (D(id)) D(id).classList.remove('on');
    });
    if (profile === 'bitperfect' && D('presetBitPerfect')) D('presetBitPerfect').classList.add('on');
    else if (profile === 'pcm' && D('presetPcm')) D('presetPcm').classList.add('on');
    else if (profile === 'dsd' && D('presetDsd')) D('presetDsd').classList.add('on');

    if (j.notes && Array.isArray(j.notes) && j.notes.length) {
      j.notes.forEach(function (note, idx) {
        setTimeout(function () { toast(note); }, idx * 1200);
      });
    } else {
      toast('已应用 ' + (profile === 'bitperfect' ? '原音直通' : (profile === 'pcm' ? 'PCM 升频' : 'DSD 升频')) + ' 预设');
    }
    return j;
  }).catch(function (err) {
    if (bBp) bBp.disabled = false;
    if (bPcm) bPcm.disabled = false;
    if (bDsd) bDsd.disabled = false;

    var msg = (err && (err.message || err.error)) || String(err) || '应用预设失败';
    toast(msg);
  });
}

function bindPresetCard() {
  if (D('presetCapsRefresh')) {
    D('presetCapsRefresh').onclick = function () {
      var btn = this;
      btn.disabled = true;
      loadPresetCaps(true).then(function () {
        btn.disabled = false;
        toast('硬件能力已刷新');
      }).catch(function () {
        btn.disabled = false;
      });
    };
  }
  if (D('presetBitPerfect')) {
    D('presetBitPerfect').onclick = function () { applyPreset('bitperfect'); };
  }
  if (D('presetPcm')) {
    D('presetPcm').onclick = function () { applyPreset('pcm'); };
  }
  if (D('presetDsd')) {
    D('presetDsd').onclick = function () { applyPreset('dsd'); };
  }
}

// ============================================================================
// 2026-10-26（用户：「保存设置跟恢复默认按钮要做进各个页面里」）
//
// 做法：渲染时在 .sbody 末尾放一个母版 .setfoot（id=sp_footTpl），
//   然后 cloneFootIntoPanes() 把它**克隆进每一个 .spane**，克隆完移除母版。
//   于是每个页签内容结束时都有自己的「保存设置 / 恢复默认」，不再是滚动区底部的浮层。
//
// 为什么不用 id 绑定：克隆后会出现 9 个同名按钮，id 必须唯一。
//   改用 data-act="save|reset"，在 bindFootActions() 里对整个 #setpage 做事件委托，
//   这样克隆多少份、将来加多少页签，都不需要再改绑定代码。
//
// 哪些页签不放保存栏（与改动前的行为一致，是产品决策，不是遗漏）：
//   · diag（诊断）/ stream（流媒体）—— 这两页的动作全部即时生效，没有"待保存"的概念，
//     放一个「保存设置」只会让人以为还有东西没存。css 里用 .spane[data-g=diag] .setfoot 隐藏。
// ============================================================================
function cloneFootIntoPanes() {
  var tpl = D('sp_footTpl');
  var sp = D('setpage');
  if (!tpl || !sp) return;
  var panes = sp.querySelectorAll('.spane');
  Array.prototype.forEach.call(panes, function (pane) {
    // 已经有就不用再加（重建时 pane 是新 DOM，正常不会重复；这里只是防御）
    if (pane.querySelector('.setfoot')) return;
    var c = tpl.cloneNode(true);
    c.removeAttribute('id');          // id 必须唯一
    pane.appendChild(c);              // 放在该页签内容最末尾
  });
  // 母版用完即弃（不留一个"第 10 份"在 .sbody 末尾）
  if (tpl.parentNode) tpl.parentNode.removeChild(tpl);
}
function bindFootActions() {
  var sp = D('setpage');
  if (!sp) return;
  // 事件委托：一次绑定，覆盖所有克隆副本，也不会重复绑
  sp.addEventListener('click', function (ev) {
    var t = ev.target;
    var btn = t && t.closest ? t.closest('[data-act]') : null;
    if (!btn) return;
    ev.preventDefault();
    var act = btn.getAttribute('data-act');
    if (act === 'save') {
      if (typeof applySettings === 'function') applySettings();
    } else if (act === 'reset') {
      if (typeof window._resetAllSettings === 'function') window._resetAllSettings();
    }
  });
}
function renderSettingsPage() {
  var filts = D('sFilt') ? D('sFilt').innerHTML : '';
  // Nx 下拉必须带上"跟随 1x"（空值），否则重建后浏览器退回第一项，一保存就把 Nx 改掉
  var filtsNx = '<option value="">跟随 1x（不单独指定）</option>' + filts;
  var shaps = D('sShap') ? D('sShap').innerHTML : '';
  var BK = ADV.backend || 'wasapi';
  var CH = String(ADV.channels || 0);
  var h = '';

  // 2026-10-26：官方推荐预设卡片**移到快速开始页**（用户要求）。
  // 设置页这里不再渲染 —— 预设是「一键开局」的入口，属于快速开始的心智模型，
  // 放在设置页顶部反而让「精细调节」的设置页显得喧宾夺主。
  // ---------- 页签（对齐 RLPlayer：Inputs / Outputs / PCM / SDM / Advanced） ----------
  h += '<div class=stabs>'
     + '<button class="stab on" data-g=in>输入</button>'
     + '<button class=stab data-g=out>输出</button>'
     + '<button class=stab data-g=pcm>PCM</button>'
     + '<button class=stab data-g=sdm>SDM</button>'
     + '<button class=stab data-g=adv>高级</button>'
     // 2026-10-23 用户 261023-04 #2：EQ 与房间校正从左侧主导航移到这里，单开一个页签。
     + '<button class=stab data-g=eq>EQ</button>'
     + '<button class=stab data-g=cal>声音校准</button>'
     + '<button class=stab data-g=meta>元数据</button>'
     // 2026-10-24（用户 261024-01 #5）：「流媒体」从「高级」拆出来的独立页签。
     + '<button class=stab data-g=stream>流媒体</button>'
     // 「诊断」独立成页：用户 2026-10-22 功能3 明确要求不要塞在元数据里。
     // 开发期它是必需品（报错时要拿现场），所以与输入/输出/PCM/SDM/高级 平级。
     + '<button class=stab data-g=diag>诊断</button>'
     + '</div>';

  // 2026-10-26（用户：设置里只有页面进行滚动 + 上边栏要贴合 UI）：
  //   .stabs 留在 #setpage 里当**固定不滚**的页签条，下面的所有内容 + 保存栏
  //   统一装进 .sbody —— 只有 .sbody 滚动。
  //   为什么这样改（实测过旧做法的两个病）：
  //     ① .stabs 原来是 position:sticky + background:var(--bg)，但它只覆盖内容宽度
  //        （实测 250..1535，而 #setpage 内容区 226..1568）⟹ 左右各露一条 24/33px 的底，
  //        滚动时能看到内容从侧面穿过去，就是用户说的"上边栏露底"。
  //     ② sticky 在 flex 列容器里被限制在自身行内，实测滚 60px 后 stabsTop 仍是 80、
  //        而容器顶是 60 ⟹ 根本没粘住，只是恰好还没滚到。
  //   改成「页签条固定 + 内容区独立滚动」后，两个病从结构上消失，不依赖 sticky。
  h += '<div class=sbody>';

  // ---------- 输出 ----------
  h += '<div class="spane" data-g=out>'
     + sgroup('输出后端', '独占 = bit-perfect；共享 = 兼容性最好（虚拟机 / 远程桌面）',
         // 261024-04 #2：用户要求「放在后端那个选项的右边」—— bit-perfect 直通按钮从独立一行挪进
         // 「后端」下拉的同一行（flex 行，底对齐；下拉可缩、按钮 nowrap，窄窗也不换行）。
         // 原来铺在页面上的一长串判据收进按钮的 tooltip，行内只留一个按钮。
         '<div class="sfld wide" style="display:flex;align-items:flex-end;gap:10px;flex-wrap:nowrap">'
       + '<div style="flex:1 1 auto;min-width:180px">'
       + '<label>后端' + tip('选到当前不可用的后端时，播放会直接返回原因，不会假装出声') + '</label>'
       + '<select id=sp_backend>'
       // 2026-10-25（用户指令「能使用的要用它真正的名字」）：macOS 单平台，UI 的 value
       // 仍是 wasapi / wasapi-shared（rtaweb.cpp 的 make_sink() 靠这两个字符串分派），
       // 但它们背后已不是 WASAPI —— 是 CoreAudio 的两种模式。面向用户的标签必须是真名。
       // 2026-10-25（方案 C）：Hog 独占已拆成独立开关（sp_hogexcl），
       // 后端标签不能再写「Hog Mode」—— 否则用户会以为选了后端就等于独占。
       +   opt('wasapi', 'CoreAudio（硬件直通）', BK)
       +   opt('wasapi-shared', 'CoreAudio 共享（系统混音）', BK)
       // 2026-10-25（用户指令「不可用的要隐藏」）：NAA / RTANet 在 macOS 上没有驱动体系，
       // make_sink() 对 backend=="naa" 直接返回必然 open 失败的 UnavailableSink。
       // 呈现一个永远不可能工作的选项 = 骗用户，故整项移除（后端拒绝分支保留）。
       +   opt('upnp', 'UPnP / DLNA 投放（局域网渲染器）', BK)
       +   opt('null', 'Null output（只跑 DSP，不出声）', BK)
       + '</select></div>'
       + '<button class="btn pri" id=sp_bpfix style="flex:none;white-space:nowrap" ' +
         'title="判据：输出采样率 = 源 / 抖动 = none / 音量 0 dB / 无 EQ·IR / 独占 CoreAudio">切到 bit-perfect 直通</button>'
       + '</div>'
       // 2026-10-25（用户指令「不可用的要隐藏」）：NAA 端点自动发现 + 手动兜底输入整块移除。
       // 对应 NAA 端点 DOM 已移除，下方事件绑定与 discoverNaa() 调用点全部有存在性守卫。
      // 261024-01 #9：后端下拉新增「UPnP / DLNA 投放」。选中后这里直接选目标渲染器，
      // 与下方「投放」区块共用同一份发现结果、同一个选择、同一条会话（不出现两套打架的控制）。
      + '<div class="sfld wide" id=sp_upnpwrap style="display:none">'
      + '<label>目标渲染器（UPnP / DLNA）</label>'
      + '<div style="display:flex;gap:8px">'
      + '<select id=sp_upnp_dev style="flex:1"><option value="">（正在发现…）</option></select>'
      + '<button class=btn id=sp_upnp_scan style="white-space:nowrap">重新发现</button>'
      + '</div>'
      + '<div class=hint id=sp_upnp_msg>播放 / 切歌自动投放到该渲染器（与下方「投放」共用会话）</div>'
      + '</div>'
       // 2026-10-24（261024-02 #8）：一键直通预设（源采样率 + 无抖动 + 0 dB + 无 EQ/IR + 独占）。
       // 261024-04 #2：按钮已挪到「后端」下拉右侧的同一行（见上），这里不再占一行。
       + sel('sp_device', '输出设备', '<option value="">默认设备</option>', '独占模式会接管这个设备；共享模式经系统混音，不接管')
       // 2026-10-25（方案 C，用户选择）：Hog 独占开关。
       // 诚实说明副作用 —— 实测确认 Hog 会阻断其它进程改硬件音量（系统音量条失效），
       // 这是 macOS 机制限制，不是本程序的 bug，所以必须写清楚让用户自己权衡。
       + chk('sp_hogexcl', '严格独占（抢 Hog Mode）', ADV.hogExclusive == 1,
             '勾选 = 真独占：屏蔽其它 App 声音、设备所有权归本程序；' +
             '**但系统音量条 / 音量键会失效**（macOS Hog 机制限制，实测确认），' +
             '音量只能用本程序的音量条调。不勾 = 系统音量全程可用（默认）。', true)
       + sel('sp_outmode', '输出模式',
             opt('pcm', 'PCM', outModeOf()) + opt('dsd', 'DSD（SDM）', outModeOf()),
             'DSD 的比特率与封装（DoP / Native）在 SDM 页设置')
       + sel('sp_rate', '输出采样率', D('sRate').innerHTML, '自动 = 所选设备的最高采样率')
       + sel('sp_bits', '输出位深（PCM）',
             opt(-1, '跟随源（按文件位深）', ADV.bits) + opt(0, '24 bit', ADV.bits) +
             opt(16, '16 bit', ADV.bits) + opt(32, '32 bit', ADV.bits),
             '跟随源 = 按文件真实位深请求（16/24/32）；DSD 输出恒为 1 bit，此项只在 PCM 模式生效')
       + sel('sp_ch', '输出声道数',
             opt('0', '跟随源声道数', CH) + opt('2', '2 声道（立体声）', CH) +
             opt('6', '5.1（6 声道）', CH) + opt('8', '7.1（8 声道）', CH),
             '设备必须支持该声道数；多声道用 WAVEFORMATEXTENSIBLE 的声道掩码声明布局')
       + num({ id: 'sp_buffer', label: '缓冲（毫秒）' }, D('sBuf').value, 10, 500, 10, '越小延迟越低，但更容易欠载')
       + num({ id: 'sp_ramp', label: '音量渐变（毫秒）' }, ADV.ramp, 0, 2000, 10, '0 = 立即生效（可能爆音）')
       + '<div class="sfld wide"><div id=sp_backendmsg class=hint></div></div>')
     + '<div id=sp_trimwrap>' + sgroup('声道音量微调', '按声道名标注，0 dB = 不动',
         '<div class="sfld wide"><div class=trimgrid>'+ trimFields(effectiveChannels()) + '</div>' +
         '<div class=hint id=sp_trimchmsg style="margin-top:8px"></div>' +
         '<div class=hint style="margin-top:4px">显示的是「输出声道数」对应的实际声道。2 = 左/右；5.1 = 左/右/中置/低音/左环绕/右环绕；7.1 再加左后/右后</div></div>') + '</div>'
     + '</div>';
     // 261024-02 #5：用户明确要求「输出栏位下的 UPnP 投放功能多余」⟹ 整块删除
     // （原「投放（UPnP）」快捷区 + 「投放实时状态」网格）。投放的入口统一挪到
     // 单曲页「推送到设备」按钮与设置→流媒体页的「推送到设备」区块，三处共用 /api/cast/state。

  // ---------- PCM ----------
  h += '<div class=spane data-g=pcm>'
     + sgroup('升频与滤波', 'RLPlayer 多相 sinc 滤波器预设',
         sel('sp_filt', '1x 滤波器（44.1 / 48 kHz 音源）', filts, '播放 44.1 / 48 kHz 文件时使用')
       + sel('sp_filtNx', 'Nx 滤波器（88.2 kHz 及以上音源）', filtsNx,
             '播放 88.2 / 96 / 176.4 kHz 等文件时使用；留空 = 与 1x 相同')
       + sel('sp_phase', '相位（覆盖滤波器预设的相位）',
             opt('', '跟随预设（用所选滤波器自带的相位）', ADV.phase) +
             opt('linear', '强制线性相位', ADV.phase) +
             opt('minimum', '强制最小相位', ADV.phase) +
             opt('intermediate', '强制混合相位（线性/最小 各 50%）', ADV.phase),
             '「跟随预设」= 不覆盖滤波器自带相位。强制项会覆盖预设：' +
             '线性 = 无相位失真、有前振铃；最小 = 无预振铃、群延迟低；混合 = 两者按 50:50 叠加（幅频不变）')
       + '<div class="sfld wide"><div class=hint id=sp_phasemsg></div></div>'
       + num({ id: 'sp_taps', label: '原型抽头数（0 = 按预设自动）' }, ADV.taps, 0, 2097152, 1024,
             '多相分解后每一相的抽头数 ≈ 抽头数 ÷ 升频比；0 = 用所选滤波器预设自带长度')
       + num({ id: 'sp_atten', label: '阻带衰减（dB，0 = 用预设）' }, ADV.atten, 0, 300, 10,
             '目标阻带深度；实际能不能达到还要看抽头数')
       + num({ id: 'sp_transition', label: '过渡带占比（0 = 用预设）' }, ADV.transition, 0, 0.45, 0.005,
             '截止点相对理想奈奎斯特回退的比例，例如 0.04 = 回退 4%')
       + chk('sp_2s', '两段式升频', D('s2s').checked, '大比率时 CPU 运算量约 1/4'))
     + sgroup('抖动与保护', '按采样率自动重标定',
         sel('sp_shaper', '抖动 / 噪声整形', shaps, 'auto = 按输出位深自动选型')
       + chk('sp_isp', '过采样峰值保护（ISP）', D('sIsp').checked, '检测到插值峰值超满幅时预衰减'))
     + '</div>';
  // ---------- SDM ----------
  h += '<div class=spane data-g=sdm>'
     + sgroup('SDM 输出', '只在输出 DSD 时生效',
         sel('sp_sdmo1', 'Oversampling 1x（44.1 / 48 kHz 音源）',
             '<option value="">跟随 PCM 页的 1x</option>' + filts,
             '与 PCM 页独立：输出 DSD 时用这一组滤波器。留空则沿用 PCM 页的 1x')
       + sel('sp_sdmoNx', 'Oversampling Nx（88.2 kHz 及以上音源）', '<option value="">跟随上面的 1x</option>' + filts,
             '输出 DSD 且源文件 >= 88.2 kHz 时使用')
       + sel('sp_dsdrate', '比特率',
             opt('64', 'DSD64（2.8224 MHz）', dsdRateOf()) + opt('128', 'DSD128（5.6448 MHz）', dsdRateOf()) +
             opt('256', 'DSD256（11.2896 MHz）', dsdRateOf()) + opt('512', 'DSD512（22.5792 MHz）', dsdRateOf()) +
             opt('1024', 'DSD1024（45.1584 MHz）', dsdRateOf()),
             'DSD512 / 1024 的 DoP 载波是 1411.2 / 2822.4 kHz，绝大多数设备不支持')
       // 2026-10-25（用户指令「A1 隐藏」）：Native DSD 直通在 macOS 上**无法实现**，
       // 不是「还没做」。依据（联网核实，2026-10-25）：
       //   * XMOS 官方：「macOS incorporates a USB driver that only supports PCM, this is
       //     also true of the central audio engine, CoreAudio. It is therefore not possible
       //     to use the "Native" scheme using the built in driver of macOS.」
       //   * Roon 官方：「macOS CoreAudio does not support native DSD playback; it's as
       //     simple as that.」
       // ⟹ 界面上不再呈现这个**永远无法工作**的选项（呈现它等于骗用户）。
       // **能力本身没删**：后端 caps().nativeDsdRate 探测逻辑保留，如实返回 0；
       // 老配置里存过的 nat 会在加载时降级到 dop（见 migrateDsdPack）。
       // 完整说明与替代方案见 PLATFORM.md「Native DSD 在 macOS 上为何不可用」。
       + sel('sp_dsdpk', '封装',
             opt('dop', 'DoP（DSD over PCM，bit-perfect）', dsdPackOf()),
             'DSD 位流装进 24-bit PCM 容器（DAC 端剥壳，全程 bit-perfect）；' +
             'macOS 的 CoreAudio 只提供 PCM 管线，这是本平台唯一能走通的原生 DSD 传输方式')
       // 2026-10-24（用户 261024-01 #12）：这两个控件不再灰掉（见 applyDsdState）。
       // 当前输出是 PCM 时，改这里会自动把输出模式联动到 DSD —— 一句常驻说明交代清楚。
       + '<div class="sfld wide" id=sp_dsdmodenote style="display:none"><div class=hint>' +
         '当前输出 PCM：改动比特率 / 封装会自动把输出切到 DSD（SDM）' + '</div></div>'
       + sel('sp_modfamily', '调制器族',
              opt('dsd', 'DSD 标准（Butterworth NTF，1-bit）', ADV.modfamily || 'dsd') +
              opt('chebyshev', 'Chebyshev（可配带外增益与截止，1-bit 保护运行于 5 阶）', ADV.modfamily || 'dsd') +
              opt('ec', 'EC 误差反馈（频带零点扩展消除）', ADV.modfamily || 'dsd') +
              opt('ahm', 'AHM 多电平（6~8 bit 风格）', ADV.modfamily || 'dsd'),
              '多种 NTF 滤波与量化架构')
        + sel('sp_modorder', '调制器阶数',
             opt(5, '5 阶（DSD64 起）', ADV.modorder || 5) + opt(7, '7 阶（需 DSD128 以上）', ADV.modorder || 5),
             '7 阶在低采样率或 Chebyshev 1-bit 下不稳定，程序会自动降为 5 阶')
       + num({ id: 'sp_modcut', label: '噪声整形拐点（kHz，0 = 100）' }, ADV.modcut, 0, 200, 5)
       + num({ id: 'sp_moddith', label: '调制器抖动（LSB，-1 = 默认）' }, ADV.moddith, -1, 1, 0.001, '抑制空闲音'))
     + sgroup('SDM 源（DSD 文件）', '原生读取 + DirectSDM',
         chk('sp_directsdm', 'DirectSDM：DSD 源同速率直通（逐位一致）', ADV.directsdm == 1,
             '源 DSD 速率 == 目标速率、音量 0 dB、无 EQ / 卷积 / 声道改动时，1-bit 流直接装进 DoP；' +
             '条件不满足自动回退普通路径，并在信号链里写明原因。')
       + sel('sp_dsdkind', 'DSD 源抽取器',
             opt('fir', 'FIR（Kaiser 120 dB，默认）', ADV.dsdKind || 'fir') +
             opt('iir', 'IIR（Butterworth 10 阶，相位非线性）', ADV.dsdKind || 'fir') +
             opt('cic', 'CIC（6 级无乘法 + 补偿）', ADV.dsdKind || 'fir'),
             '只在「DSD 源 → PCM」路径生效；DirectSDM 直通时整条 PCM 链都被跳过')
       + sel('sp_dsdconv', 'DSD 源 Conversion',
             opt('narrow', 'narrow（通带 20 kHz，默认）', ADV.dsdConv || 'narrow') +
             opt('wide', 'wide（通带 30 kHz）', ADV.dsdConv || 'narrow') +
             opt('xfi', 'XFi（通带 40 kHz）', ADV.dsdConv || 'narrow'),
             '通带越宽，阻带起点越靠近、过渡带越窄、抽头越多')
       + '<div class="sfld wide"><div class=hint id=sp_dsdmsg></div></div>')
     + '</div>';
  // ---------- 输入 ----------
  h += '<div class="spane on" data-g=in>'
     + sgroup('输入设备与采集', 'CoreAudio 采集 / 录制与直通监听',
         // 2026-10-25（用户指令「能使用的要用它真正的名字」）：value 仍是 wasapi
         // （rtaweb.cpp 的输入采集分派靠它），但实际后端已是 CoreAudio 的 AUHAL 输入侧。
         sel('sp_inbackend', '输入后端', opt('none', '[none]', ADV.inBackend || 'none') + opt('wasapi', 'CoreAudio', ADV.inBackend || 'none'),
             '选 CoreAudio 后可以采集线路输入 / 麦克风 / 系统混音回环')
       + sel('sp_indev', '输入设备', '<option value="">（未选择 / 默认设备）</option>', '包含物理采集设备与系统混音回环端点（标注「回环」的那一项）')
       + sel('sp_inch', '声道偏移', opt('0', '0', ADV.inOffset || 0) + opt('1', '1', ADV.inOffset || 0) +
             opt('2', '2', ADV.inOffset || 0) + opt('4', '4', ADV.inOffset || 0),
             '多声道接口只取其中几路时用')
       + num({ id: 'sp_inbuf', label: '输入缓冲（毫秒）' }, ADV.inBuf || 100, 10, 500, 10, '环形缓冲时间深度')
       + chk('sp_inmon', '直通监听（非 bit-perfect）', ADV.inMonitor == 1,
             '勾选后把采集直接送到系统默认共享端点监听；不勾选则录制保存为 WAV')
       + num({ id: 'sp_inseconds', label: '录制时长（秒，0 为不限）' }, ADV.inSeconds || 0, 0, 86400, 1,
             '达到指定时长自动停止；0 = 持续采集直到手动停止')
       + '<div class="sfld wide"><label>输出文件路径（WAV）' +
           tip('仅录制模式生效；留空自动保存在 ~/Library/Application Support/RLPlayer/recordings（不可用时退回临时目录）') + '</label><input type=text id=sp_inout value="' +
             esc(ADV.inOut || '') + '" placeholder="留空自动存至 Application Support/RLPlayer/recordings' + SEP + 'cap-时间戳.wav"></div>'
       + '<div class="sfld wide" style="display:flex;align-items:center;gap:10px;margin-top:2px">'
       + '<button class="btn pri" id=sp_instart>开始采集</button>'
       + '<button class=btn id=sp_instop disabled>停止采集</button>'
       + '<span id=sp_inmsg class=hint style="margin:0"></span>'
       + '</div>')
     + sgroup('采集实时状态', '1 秒自动轮询',
         '<div class="sfld wide in-stat-grid">'
       + '<div class=in-stat-item><span class=lbl>运行状态</span><span class=val id=sp_stat_running>空闲</span></div>'
       + '<div class=in-stat-item><span class=lbl>采集帧数 / 时长</span><span class=val id=sp_stat_frames>0 帧 (0.0s)</span></div>'
       + '<div class=in-stat-item><span class=lbl>采样规格</span><span class=val id=sp_stat_spec>-</span></div>'
       + '<div class=in-stat-item><span class=lbl>缓冲水位</span><span class=val id=sp_stat_water>0.0%</span>'
       + '<div class=meter-bar><div id=sp_meter_water class=meter-val style="width:0%"></div></div></div>'
       + '<div class=in-stat-item><span class=lbl>溢出 / 欠载</span><span class=val id=sp_stat_xrun>溢出 0 / 欠载 0</span></div>'
       + '<div class=in-stat-item><span class=lbl>削波计数 (正 / 负)</span><span class=val id=sp_stat_clips>+0 / -0</span></div>'
       + '<div class=in-stat-item><span class=lbl>RMS 电平</span><span class=val id=sp_stat_rms>-∞ dBFS</span>'
       + '<div class=meter-bar><div id=sp_meter_rms class=meter-val style="width:0%"></div></div></div>'
       + '<div class=in-stat-item><span class=lbl>峰值电平</span><span class=val id=sp_stat_peak>-∞ dBFS</span>'
       + '<div class=meter-bar><div id=sp_meter_peak class=meter-val style="width:0%"></div></div></div>'
       + '<div class=in-stat-item style="grid-column:1/-1"><span class=lbl>输出文件</span><span class="val sm" id=sp_stat_out>-</span></div>'
       + '<div class=in-stat-item id=sp_stat_err_box style="grid-column:1/-1;display:none;color:var(--err)">'
       + '<span class=lbl style="color:var(--err)">错误信息</span><span class=val id=sp_stat_err></span></div>'
       + '</div>')
     + '</div>';


  // ---------- 高级 ----------
  h += '<div class=spane data-g=adv>'
     + sgroup('外观',
         '<div class=sfld><label>界面风格' + tip('在 Apple Music 风格（通顶侧栏 + 悬浮毛玻璃播放胶囊 + 精选海报）与经典 Hi-Fi 工作台（DSH / Roon 布局）之间实时切换') + '</label><select id=sp_uistyle>'
       + opt('apple', 'Apple Music 风格（默认）', S.uiStyle || 'apple') + opt('classic', '经典 Hi-Fi 工作台（DSH / Roon）', S.uiStyle || 'apple')
       + '</select></div>'
       + '<div class=sfld><label>主题' + tip('顶栏右侧的小圆点也可以快速切换主题') + '</label><select id=sp_theme>'
       + opt('dark', '深色（默认）', S.theme) + opt('light', '白色', S.theme) + opt('blue', '浅蓝色', S.theme)
       + '</select></div>')
     + sgroup('GPU',
         sel('sp_gpu', 'GPU 后端',
             // 2026-10-25（用户指令「能使用的要用它真正的名字」/「不可用的要隐藏」）：
             // Windows 的 AMD HIP / NVIDIA CUDA / DX12 在 macOS 上全部不存在（平台层已删）。
             // macOS 唯一正确的 GPU 路径是 Apple Metal。可用性不在这里写死 ——
             // 由 /api/gpu 返回的 metal / metalUsable 字段决定，缺失即按不可用处理。
             opt('auto', '自动', ADV.gpuvendor || 'auto') +
             opt('metal', 'Apple Metal（GPU 加速）', ADV.gpuvendor || 'auto') +
             opt('off', '关闭（纯 CPU）', ADV.gpuvendor || 'auto'),
             '自动 = 优先 Apple Metal，不可用时自动退回纯 CPU（NEON 向量）分块 FFT，输出逐位相同')
       + '<div class="sfld wide"><div id=sp_gpumsg class=hint></div></div>')
     // 2026-10-24（用户 261024-01 #5/#6）：
     //   ① 「流媒体服务器」整组搬去新增的「流媒体」页签（这里不再保留副本，避免重复 id）；
     //   ② 「音乐库与网络」改名「本地音乐库」—— 只放本地库根目录 / 扫描 / 线程；
     //   ③ 原组里的「发现 DLNA 设备」与结果区搬去「流媒体」页（DLNA 归流媒体）。
     + sgroup('本地音乐库', '本地目录扫描入索引；DLNA / UPnP 在「流媒体」页',
         '<div class="sfld wide libstats" id=sp_libstats></div>'
       + txt('sp_root', '添加音乐目录', '', '可以点「浏览…」直接选文件夹，也可以手填路径', (SEP === '/' ? '/Users/你的用户名/Music' : 'D:\\Music'))
       + '<div class="sfld wide" style="display:flex;gap:8px;flex-wrap:wrap">'
       // 2026-10-25（用户要求「要让用户可以通过点击文件夹来选择」）：原生目录选择面板。
       // 只有 machost（WKWebView 壳）才有宿主通道；浏览器直开时按钮隐藏，避免点了没反应。
       + '<button class="btn" id=sp_browseRoot style="display:none">浏览…</button>'
       + '<button class="btn" id=sp_addroot>添加目录</button> <button class="btn" id=sp_rescan>重新扫描全部</button></div>'
       + num({id:'sp_scanthreads', label:'扫描线程数'}, ADV.scanThreads || 0, 0, 32, 1, '0 = 自动（默认 min(CPU, 8)）')
       + '<div class="sfld wide"><div id=sp_roots class=rootlist></div></div>')
     + sgroup('播放', '',
         sel('sp_rep', '循环模式', D('sRep').innerHTML, '')
       + chk('sp_shuf', '随机播放', D('sShuf').checked, '关掉会恢复原顺序')
       + chk('sp_loud', '等响度补偿', D('sLoud').checked, '音量越低低频提升越多'))
     + '</div>';

  // ---------- EQ（PEQ 20段 + 耳机 EQ OPRA） ----------
  h += '<div class=spane data-g=eq>' + eqSettingsHtml() + '</div>';

  // ---------- 声音校准（Q-9 独立页签：房间测量向导 + REW/AutoEq 文本 + 房间校正 IR WAV） ----------
  h += '<div class=spane data-g=cal>' + calSettingsHtml() + '</div>';

  // ---------- 流媒体（用户 261024-01 #5/#6：从「高级」拆成独立页签 + 多服务器 + DLNA 归位）----------
  h += '<div class=spane data-g=stream>'
     + sgroup('流媒体服务器', '可保存多台，同一时刻启用一台；只取原始文件，不转码',
         '<div class="sfld wide" style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">'
       + '<button class="btn pri" id=sp_src_add>添加服务器</button></div>'
       + '<div class="sfld wide"><div id=sp_src_list class=srvlist></div></div>'
       + '<div class="sfld wide" id=sp_src_form style="display:none">'
       + '<div class=srvform>'
       + '<div class=mh id=sp_src_ftitle>添加服务器</div>'
       + '<div class=sfld><label>名称</label><input type=text id=sp_src_name placeholder="例如 客厅 NAS"></div>'
       + '<div class=sfld><label>类型</label><select id=sp_src_kind>'
       + '<option value=subsonic>Navidrome / Subsonic</option><option value=emby>Emby</option></select></div>'
       + '<div class="sfld wide"><label>服务器地址' + tip('带 http:// 或 https://，例如 http://192.168.1.10:4533') + '</label>'
       + '<input type=text id=sp_src_base placeholder="http://192.168.1.10:4533"></div>'
       + '<div class=sfld><label>用户名</label><input type=text id=sp_src_user autocomplete=off spellcheck=false></div>'
       + '<div class=sfld><label>密码' + tip('编辑已有服务器时留空 = 保持原密码不变；密码只存本机 rlplayer-sources.conf') + '</label>'
       + '<input type=password id=sp_src_pass autocomplete=new-password placeholder="留空 = 不修改"></div>'
       + '<div class="sfld wide" style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">'
       + '<button class="btn pri" id=sp_src_save>保存</button>'
       + '<button class=btn id=sp_src_testform>测试连接</button>'
       + '<button class=btn id=sp_src_cancel>取消</button>'
       + '<span class=hint id=sp_src_fmsg style="margin:0"></span></div>'
       + '</div></div>')
     // 261024-02 #5：用户原话「你现在只有一个发现DLNA设备按钮，但是没有推送上去的按钮，导致无法测试」
     // ⟹ 这里从"只发现"升级为完整推送区：设备下拉 + 推送当前曲 / 停止投放 + 实时状态。
     // 状态与单曲页按钮、底栏徽标同源（/api/cast/state，1 秒轮询）。
     + sgroup('推送到设备（UPnP / DLNA）', '一键把当前曲目推送到局域网渲染器；之后的切歌 / 暂停 / 进度都作用在它上面',
         '<div class="sfld wide" style="display:flex;gap:8px;align-items:flex-end;flex-wrap:wrap">'
       + '<select id=sp_cast_dev style="flex:1;min-width:220px"><option value="">（未发现 UPnP 渲染器）</option></select>'
       + '<button class=btn id=sp_cast_scan style="white-space:nowrap">重新发现</button></div>'
       + '<div class="sfld wide"><div class=hint id=sp_cast_devmsg>点「重新发现」扫描局域网里的 MediaRenderer</div></div>'
       + '<div class="sfld wide" style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:2px">'
       + '<button class="btn pri" id=sp_cast_push>推送当前曲</button>'
       + '<button class=btn id=sp_cast_stop disabled>停止投放</button>'
       + '<span id=sp_cast_msg class=hint style="margin:0"></span></div>'
       + '<div class="sfld wide in-stat-grid" style="margin-top:6px">'
       + '<div class=in-stat-item><span class=lbl>运行阶段</span><span class=val id=sp_cast_stat_phase>已停止</span></div>'
       + '<div class=in-stat-item><span class=lbl>目标渲染器</span><span class="val sm" id=sp_cast_stat_dev>-</span></div>'
       + '<div class=in-stat-item><span class=lbl>播放进度</span><span class=val id=sp_cast_stat_pos>0:00</span></div>'
       + '<div class=in-stat-item><span class=lbl>传输状态</span><span class=val id=sp_cast_stat_transport>STOPPED</span></div>'
       + '<div class=in-stat-item><span class=lbl>供源传输字节</span><span class=val id=sp_cast_stat_bytes>0 B</span></div>'
       + '<div class=in-stat-item><span class=lbl>供源请求数</span><span class=val id=sp_cast_stat_reqs>0 次</span></div>'
       + '<div class=in-stat-item><span class=lbl>供源端口</span><span class=val id=sp_cast_stat_port>8912</span></div>'
       + '<div class=in-stat-item><span class=lbl>采样率取证</span><span class=val id=sp_cast_stat_ratematch>未取证</span></div>'
       + '<div class=in-stat-item id=sp_cast_stat_warn_box style="grid-column:1/-1;display:none;color:var(--warn, #eab308)">'
       + '<span class=lbl style="color:var(--warn, #eab308)">采样率告警</span><span class=val id=sp_cast_stat_warn></span></div>'
       + '<div class=in-stat-item id=sp_cast_stat_err_box style="grid-column:1/-1;display:none;color:var(--err)">'
       + '<span class=lbl style="color:var(--err)">错误信息</span><span class=val id=sp_cast_stat_err></span></div>'
       + '</div>')
     + '</div>';

  // ---------- 诊断（用户 2026-10-22 功能3：独立页签）----------
  // 用户原话：「导出诊断信息其实就是一个 log，最好是直接导出一个压缩包或一个整体的
  // 文件，不要用户单独找 rlplayer-diag.json / rlplayer-playback.log / launcher.log
  // 三份文件；另外这个选项放在元数据这里明显不合适，单独出来做选项卡吧，
  // 我们还在开发，报错是必不可少的。」
  // 2026-10-24（用户 261024-01 #7）：包内清单从页面正文挪进 (?) 提示，页面只留一句话 + 两个按钮。
  h += '<div class=spane data-g=diag>'
     + sgroup('导出诊断包', '一个文件，不用再到处找日志',
         '<div class="sfld wide" style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">'
       + '<button class="btn pri" id=sp_diagzip>导出诊断包（.zip）</button>'
       + '<button class=btn id=sp_diagjson>只要 JSON</button>'
       // 2026-10-26（用户要求「预留好上传诊断的接口」）：
       //   上传而不是让用户去微信/QQ 传文件的理由：诊断包动辄几 MB，聊天工具会压/过期；
       //   而且用户往往说不清"该发哪个文件"。
       //   端点契约（后端接上即可用）：POST /api/diag/upload
       //     Content-Type: application/zip，Body = 诊断包原始字节
       //     期望 200 + {"ok":true,"id":"<工单号>","url":"<可选查看地址>"}
       //   端点未接上时不假装成功（见 uploadDiag 的错误分支）。
       + '<button class=btn id=sp_diagupload>上传诊断</button>'
       + tip('包内：rlplayer-diag.json（版本 / 系统 / CPU / GPU / 端口）、rlplayer-playback.log（含 .1/.2 轮转）、launcher.log、dumps-manifest.txt、settings-summary.txt；' +
             'api_key / token / password / Authorization 头一律脱敏为 <redacted>，家目录用户名与邮箱脱敏为 <user>；rlplayer-llm.conf 本体不会被打进包。')
       + '<span style="font-size:11.5px;color:var(--mut2);margin-left:2px" id=sp_diagmsg></span></div>'
       + '<div class=hint>一个 zip 打包全部日志 / 系统信息 / 设置摘要（已脱敏），不用再到处找日志文件</div>')
     // 2026-10-26 F-4 自动更新（用户要求：「云端发布更新 → 自动提示 → 客户端一键更新」）
     // 放在「诊断」页而不是主界面：更新是低频操作，弹窗打扰比省一次点击更烦；
     // 真正有新版本时由底栏徽标（updateBadge）主动提示，点这里进来装。
     // 浏览器直开（无宿主）时整块隐藏 —— 装了也没法替换 .app，不能假装能装。
     + sgroup('软件更新', '检查新版本，一键更新',
         '<div class="sfld wide" style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">'
       + '<span style="font-size:11.5px;color:var(--mut)">当前版本</span>'
       + '<b style="font-size:12.5px" id=sp_vercur></b>'
       + '<button class=btn id=sp_updcheck>检查更新</button>'
       + '<button class="btn pri" id=sp_updinstall style="display:none">立即更新</button>'
       + '<label class=chk style="margin-left:4px;font-size:12px"><input type=checkbox id=sp_updbeta' + (ADV.updbeta == 1 ? ' checked' : '') + '>'
       + '<span>接收测试版（Beta）</span>' + tip('开启后会接收包含 -beta / -rc 等预发布版本更新；关闭则只提示正式版') + '</label>'
       + '<span id=sp_updmsg style="font-size:11.5px;color:var(--mut2)"></span></div>'
       + '<div id=sp_updbar style="display:none;height:6px;border-radius:3px;background:var(--track);overflow:hidden;margin:10px 0 2px">'
       + '<i id=sp_updfill style="display:block;height:100%;width:0;background:linear-gradient(90deg,var(--acc),var(--acc2));transition:width .2s"></i></div>'
       + '<div class=hint id=sp_updnote>更新会下载安装包并校验 sha256；校验不通过一律丢弃，绝不安装被篡改的内容。安装完成后会自动重启。</div>')
     // 2026-10-26（用户：反馈走邮件，正文=反馈内容，诊断包=附件）：
     //   为什么用邮件而不是 issue/自建服务器：
     //     ① GitHub issue 匿名建不了（实测 401）⟹ 得要 token 进客户端，和安全要求冲突；
     //     ② issue body 实测上限约 64KB，而单个日志就 1.2MB，诊断包塞不下；
     //     ③ 邮件天然支持大附件，且**零凭据**（走系统邮件客户端，不在代码里存任何密码）。
     //   实现：页面收集正文 → postMessage 给原生壳 → 壳生成 .eml（含 zip 附件）→ 打开系统邮件客户端。
     //   收件人写死在壳侧常量（BH2VOQ@163.com），页面不能指定。
     + sgroup('反馈问题', '直接发送给开发者，可附诊断包',
         '<div class="sfld wide"><label>问题描述' +
           tip('写清楚「做了什么 / 期望什么 / 实际什么」最有帮助') + '</label>'
       + '<textarea id=sp_fbtext rows=5 spellcheck=false placeholder="简单描述你遇到的问题…（例如：播放 DSD 文件时切歌会卡住 1 秒）" '
       + 'style="width:100%;box-sizing:border-box;padding:8px 10px;border-radius:7px;border:1px solid var(--line);background:var(--field);color:var(--txt);font:inherit;font-size:12.5px;line-height:1.6;resize:vertical;min-height:88px"></textarea>'
       + '<div class=hint id=sp_fbcount style="margin-top:5px">0 / 8000</div></div>'
       + '<div class="sfld wide" style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:4px">'
       + '<label class=chk style="margin-right:2px"><input type=checkbox id=sp_fbdiag checked>'
       + '<span>附带诊断包</span>' + tip('打包日志 / 系统信息 / 设置摘要（token、密码等已脱敏为 <redacted>）。不建议关闭 —— 没有日志很难定位问题') + '</label>'
       + '<button class="btn pri" id=sp_fbsend>发送反馈</button>'
       + '<span id=sp_fbmsg style="font-size:11.5px;color:var(--mut2)"></span></div>'
       + '<div class=hint>点「发送反馈」会直接把内容上传给开发者，**不需要配置邮箱、不需要注册账号**。'
       + '诊断包已脱敏（token / 密码 / Authorization 头一律替换为 <redacted>，用户名与邮箱替换为 <user>），不会上传你的音乐文件。</div>')
     + '</div>';

  // ---------- 元数据补全（排在「高级」之后）----------
  // P1.5：源开关不再硬编码 —— #sp_metasrc 占位容器由 fillMetaProviders 按
  // /api/providers 动态填充（注册表驱动，后端新增数据源前端零改动）。
  // 2026-10-23 用户 261023-04 #3：三个开关 → 两个。
  //   ①「自动补全（不用 AI）」= metaon（只走公开数据源，不产生费用）；
  //   ②「AI 增强（DeepSeek）」= 原「DeepSeek 增强（无标签文件）」+「在线整理音乐资料简介」合并，
  //      保存时同时写 metallm 与 metasummary（开 = 1,1；关 = 0,0）。
  // 2026-10-24（用户 261024-01 #7/#8）：
  //   * 长说明全部收进 (?)；页面只留两个开关 + 一个「高级选项」入口；
  //   * 标签写回不再有「可选」字样/开关 —— 能力默认开启（后端本来就没有开关，永远可用）。
  var aiOn = (META.llm == 1 && META.summary == 1);
  h += '<div class=spane data-g=meta>'
     + sgroup('元数据补全', '播放时后台补全标签 / 封面 / 歌词，结果落在本地库',
         chk('sp_metaon', '自动补全（不用 AI）', META.on == 1,
             '只用公开数据源（QQ音乐 / 网易云 / iTunes / dizzylab / lrclib）补全标签、封面、歌词；全程不调用 AI，不产生费用', true)
       + chk('sp_metallm', 'AI 增强（DeepSeek）', aiOn,
             '联网调用 DeepSeek（按次计费）：解析无标签文件、并在艺术家 / 专辑 / 单曲页整理简介并缓存（7 天有效）。' +
             '关闭后两项都停，本地与公开数据源照常工作', true)
       + '<div class="sfld wide" style="margin-top:2px">'
       + '<button class=btn id=sp_metamore style="font-size:12px" aria-expanded="false">高级选项 ▾</button>'
       + '</div>'
       // #sp_metaadv 必须跨满 .sgbody 的整行（否则会被压进单个 260px 网格单元，两列各只剩 140px）
       + '<div class="sfld wide" id=sp_metaadv style="display:none;margin-top:14px">'
       + '<div class=meta-adv-grid>'
       // 左列：数据源（逐源开关，注册表驱动渲染进 #sp_metasrc）
       + '<div class=meta-card>'
       + '<div class=mh>数据源' + tip('越靠上优先级越高；关掉的源完全不参与补全') + '</div>'
       + '<div id=sp_metasrc class=meta-src-grid>' + metaSrcHtml() + '</div>'
       + '</div>'
       // 右列：DeepSeek 接入 + 标签写回
       + '<div class=meta-card>'
       + '<div class=mh>DeepSeek 接入' + tip('只用于上面的「AI 增强」；不填也能用全部本地与公开数据源') + '</div>'
       + '<label style="display:block;font-size:11px;color:var(--mut);margin-bottom:5px">DeepSeek API Key' +
           tip('只存本机 build' + SEP + 'rlplayer-llm.conf；不进安装包，界面永不回显明文') + '</label>'
       + '<input type=password id=sp_llmkey autocomplete=off spellcheck=false placeholder="sk-…（粘贴后点保存，只显示掩码）" style="width:100%">'
       + '<div class=hint id=sp_llmmsg style="margin-top:6px">读取配置中…</div>'
       + '<div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap">'
       + '<button class="btn pri" id=sp_llmsave>保存 Key</button>'
       + '<button class=btn id=sp_llmtest>测试连接</button>'
       + '<button class=btn id=sp_llmclear>清除 Key</button></div>'
       // 用户 261024-01 #8：默认开启，不提供开关 —— 只说明能力，两个动作按钮照旧。
       + '<div class="mh sub">标签写回<span class=hint style="font-weight:400">默认开启</span></div>'
       + '<div class=hint id=sp_wbdesc style="margin:2px 0 9px">补全到的标签 / 封面写回音频文件本身；写前校验音频数据逐位不变，原文件备份到 rlplayer-meta' + SEP + 'backups</div>'
       + '<div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap;align-items:center">'
       + '<button class=btn id=sp_wbdry>预览写回</button>'
       + '<button class=btn id=sp_wbapply>执行写回</button>'
       + '<span id=sp_wbmsg style="font-size:11.5px;color:var(--mut2)"></span></div>'
       + '</div>'
       + '</div></div>')
     + '</div>';

  // 2026-10-26（用户：保存设置跟恢复默认按钮要做进各个页面里）：
  //   每个 .spane 各自带一份保存栏（由 JS 在渲染后按页签克隆），而不是全局只有一个。
  //   这里先留一个"母版"放在 .sbody 末尾，供 JS 克隆；克隆完自身移除。
  //   好处：保存/恢复默认出现在**每一个**页面内容之中（用户说的"做进各个页面里"），
  //   不再是悬在滚动区底部的浮层，也就不需要 sticky / margin-top:auto 这些技巧。
  h += '<div class=setfoot id=sp_footTpl><button class="btn pri" data-act=save>保存设置</button>'
     + '<button class=btn data-act=reset>恢复默认</button><span class=sp></span>'
     + '<span style="font-size:11.5px;color:var(--mut2)">改动在下一次播放时生效</span></div>';
  h += '</div>';   // </div .sbody>

  D('setpage').innerHTML = h;

  bindPresetCard();
  loadPresetCaps(false);

  // P1.5：源开关的绑定不在上面的静态清单里 —— 重建 HTML 后逐源重新绑定
  //（/api/providers 已到则用缓存渲染+绑定；没到则等 fillMetaProviders 到达时补填）。
  renderMetaSrcRows();

  // 2026-10-26 F-4：更新卡片的两个按钮。设置页每次重建都会重跑这里，
  //   bindUpdateCard() 是纯赋值 onclick，重复调用无副作用。
  //   如果之前已经查到过"有新版本"，重建后要把「立即更新」按钮恢复出来，
  //   否则切一下页签按钮就没了（用户会以为更新消失了）。
  bindUpdateCard();
  if (UPD.stage === 'available' && UPD.info) {
    updInstallBtn(true, '立即更新');
    updMsg('发现新版本 ' + (UPD.info.version ? ('v' + UPD.info.version) : ''), 'warn');
  } else if (UPD.stage === 'up-to-date') {
    updMsg('已是最新版本', 'ok');
  } else if (UPD.stage === 'failed' && UPD.info) {
    updMsg('检查失败：' + (UPD.info.message || UPD.info.code || '未知原因'), 'err');
  }

  // 2026-10-26 邮件反馈卡片：与更新卡片同样在每次重建后重新绑定
  //（之前这里完全缺失 ⟹ 用户点「发邮件反馈」没有任何反应）。
  bindFeedbackCard();

  // 设置页里的下拉是复制的快捷面板 HTML，重建后浏览器会退回第一项。
  // 不同步回来，打开设置页再点保存就会把用户的选择悄悄改成第一项。
  [['sp_filt', 'sFilt'], ['sp_filtNx', 'sFiltNx'], ['sp_shaper', 'sShap'],
   ['sp_rate', 'sRate'], ['sp_rep', 'sRep'], ['sp_buffer', 'sBuf'],
   ['sp_shuf', 'sShuf'], ['sp_loud', 'sLoud'], ['sp_isp', 'sIsp'], ['sp_2s', 's2s']].forEach(function (pair) {
    var a = D(pair[0]), b = D(pair[1]);
    if (!a || !b) return;
    if (a.type === 'checkbox') { a.checked = b.checked; return; }
    if (a.tagName === 'SELECT') {
      for (var i = 0; i < a.options.length; i++) {
        if (a.options[i].value === b.value) { a.value = b.value; return; }
      }
    } else { a.value = b.value; }
  });

  // 先把 DSD 三个控件的当前值从隐藏状态同步过来
  if (D('sp_outmode')) D('sp_outmode').value = outModeOf();
  if (D('sp_dsdrate')) D('sp_dsdrate').value = dsdRateOf();
  if (D('sp_dsdpk')) D('sp_dsdpk').value = dsdPackOf();
  if (D('sp_sdmo1')) D('sp_sdmo1').value = ADV.sdmFilt || '';
  if (D('sp_sdmoNx')) D('sp_sdmoNx').value = ADV.sdmFiltNx || '';
  applyDsdState();
  applyBackendState();   // 261024-01 #9/#11：NAA / UPnP 选中时只显示各自的目标选择器

  // 页签切换（输入 / 输出 / PCM / SDM / 高级）
  Array.prototype.forEach.call(document.querySelectorAll('#setpage .stab'), function (b) {
    b.onclick = function () {
      Array.prototype.forEach.call(document.querySelectorAll('#setpage .stab'), function (x) {
        x.classList.toggle('on', x === b);
      });
      Array.prototype.forEach.call(document.querySelectorAll('#setpage .spane'), function (p) {
        p.classList.toggle('on', p.dataset.g === b.dataset.g);
      });
      // 评审 #12：诊断页是纯操作页（导出/写回），底部「保存设置/恢复默认」在这里没有意义 → 隐藏。
      // 2026-10-24 #5：流媒体页的增删改/启用都是即时落盘，同样不需要底部保存。
      var foot = document.querySelector('#setpage .setfoot');
      if (foot) foot.style.display = (b.dataset.g === 'diag' || b.dataset.g === 'stream') ? 'none' : '';
      if (b.dataset.g === 'in') {
        loadInputDevices();
        pollInputState();
      } else if (b.dataset.g === 'out') {
        applyBackendState();
        // 只有"输出后端 = UPnP"时才需要渲染器列表（目标设备下拉在输出页里）
        if (((D('sp_backend') && D('sp_backend').value) || 'wasapi') === 'upnp') scanCastDevices(false);
      } else if (b.dataset.g === 'stream') {
        loadSrcConfig();
        scanCastDevices(false);   // 推送区块的设备列表
        pollCastState();          // 推送区块的实时状态（与单曲页按钮同源）
      }
    };
  });

  // 输出后端 / 声道 / 微调
  D('sp_backend').onchange = function () {
    ADV.backend = this.value;
    saveSettings();
    backendHint();
    applyBackendState();
    loadDeviceList();        // CoreAudio 列端点，UPnP/Null 没有本地设备
    repaintTrims();
    // 261024-01 #9/#11：切到 UPnP 时自动发现目标（用户不用手填设备地址）
    // 2026-10-25（用户指令「不可用的要隐藏」）：NAA 已从后端下拉移除，对应分支一并删除；
    // discoverNaa() 本体保留（无副作用），但不再有 UI 入口。
    if (this.value === 'upnp') scanCastDevices(true);
  };
  if (D('sp_naahost')) D('sp_naahost').oninput = function () { ADV.naaHost = this.value; saveSettings(); backendHint(); };
  // 261024-01 #11：NAA 端点下拉 = 自动发现结果（手动框只是折叠兜底）
  if (D('sp_naa_scan')) D('sp_naa_scan').onclick = function () { discoverNaa(true); };
  if (D('sp_naa_dev')) D('sp_naa_dev').onchange = function () {
    ADV.naaHost = this.value || '';
    if (D('sp_naahost')) D('sp_naahost').value = this.value || '';
    saveSettings();
    backendHint();
  };
  // 261024-01 #9：目标渲染器与「投放」区块同一个选择（不出现两套互相打架的控制）
  if (D('sp_upnp_scan')) D('sp_upnp_scan').onclick = function () { scanCastDevices(true); };
  if (D('sp_upnp_dev')) D('sp_upnp_dev').onchange = function () { syncUpnpDev(this.value); backendHint(); };
  // 2026-10-24（261024-02 #8）：一键切到 bit-perfect 直通。
  // 用户只看到"非 bit-perfect"，不知道是哪一环：这里把判定口径对应的控件一次改到位。
  if (D('sp_bpfix')) D('sp_bpfix').onclick = function () {
    if (D('sp_backend')) { D('sp_backend').value = 'wasapi'; ADV.backend = 'wasapi'; }
    if (D('sp_outmode')) D('sp_outmode').value = 'pcm';
    if (D('sp_rate')) D('sp_rate').value = 'src';
    if (D('sRate')) D('sRate').value = 'src';
    if (D('sp_shaper')) D('sp_shaper').value = 'none';
    if (D('sShap')) D('sShap').value = 'none';
    if (D('sp_bits')) D('sp_bits').value = '0';
    // ISP 过采样峰值保护会在峰值超满幅时做预衰减（非逐位一致）→ 直通模式必须关
    if (D('sp_isp')) D('sp_isp').checked = false;
    if (D('sIsp')) D('sIsp').checked = false;
    ADV.isp = false;
    // 关掉 EQ / IR 卷积（它们都会让输出不再是逐位一致）
    if (D('sp_eq')) { D('sp_eq').value = ''; ADV.eq = ''; }
    if (D('sp_ir')) { D('sp_ir').value = ''; ADV.ir = ''; }
    // 音量：bit-perfect 必须 0 dB（不衰减），但 0 dB = 满幅输出，不能悄悄替用户拉满。
    // 必须显式确认（铁律 1：向听音设备输出可闻电平要先告知）。
    var volNow = (typeof S.vol === 'number') ? S.vol : 0;
    var volSet = false;
    if (Math.abs(volNow) > 1e-9) {
      if (window.confirm('bit-perfect 要求音量 0 dB（不衰减、输出满幅）。\n当前音量 ' + volNow.toFixed(1) +
                         ' dB。\n\n是否同时把音量设到 0 dB？\n（选"取消"则只改采样率/抖动/EQ，仍非 bit-perfect）')) {
        S.vol = 0;
        // 0 dB = 滑块**位置 1000**（最右），不是 0。滑块改成位置刻度后，
        // 直接写 0 会变成静音 —— 这行原来是 '0'，必须跟着改。
        if (D('vol')) D('vol').value = volDbToPos(0);
        if (D('volDb')) D('volDb').textContent = '0.0 dB';
        volSet = true;
      }
    } else {
      volSet = true;
    }
    saveSettings();
    backendHint();
    if (D('sp_backendmsg')) D('sp_backendmsg').textContent = volSet
      ? '已切到 bit-perfect 直通：源采样率 + 无抖动 + 0 dB + 无 EQ/IR + 独占。下次播放生效。'
      : '已改采样率/抖动/EQ，但音量仍是 ' + volNow.toFixed(1) + ' dB（非 0）→ 仍非 bit-perfect。';
    toast(volSet ? '已切到 bit-perfect 直通（下次播放生效）' : '已改采样率/抖动/EQ；音量未动，仍非 bit-perfect');
  };
  D('sp_ch').onchange = function () {
    ADV.channels = parseInt(this.value, 10) || 0;
    saveSettings();
    repaintTrims();
  };
  repaintTrims();
  // 2026-10-24（用户 261024-01 #12）：比特率 / 封装永远可选。
  // 在输出 PCM 时改这两个控件 = 用户明确想要 DSD ⟹ 输出模式自动联动到 DSD（并 toast 说明），
  // 不再出现"灰掉点不了"的控件。
  ['sp_outmode', 'sp_dsdrate', 'sp_dsdpk'].forEach(function (id) {
    var e = D(id);
    if (!e) return;
    e.onchange = function () {
      if (id !== 'sp_outmode' && D('sp_outmode') && D('sp_outmode').value !== 'dsd') {
        D('sp_outmode').value = 'dsd';
        toast('输出模式已切到 DSD（SDM）');
      }
      applyDsd(); saveSettings(); applyDsdState();
      // 2026-10-25：输出模式切到/切离 DSD 时，音量标签的「DSD 输出：不生效」标注要跟着变
      if (typeof syncVolUi === 'function') syncVolUi();
    };
  });
  ['sp_sdmo1', 'sp_sdmoNx'].forEach(function (id) {
    var e = D(id);
    if (e) e.onchange = function () { ADV[id === 'sp_sdmo1' ? 'sdmFilt' : 'sdmFiltNx'] = this.value; saveSettings(); };
  });
  ['sp_dsdkind', 'sp_dsdconv'].forEach(function (id) {
    var e = D(id); if (!e) return;
    e.onchange = function () {
      if (id === 'sp_dsdkind') ADV.dsdKind = this.value; else ADV.dsdConv = this.value;
      saveSettings();
    };
  });
  // 元数据补全开关（用户 261023-04 #3）：只剩两个。
  //   ① 自动补全 = metaon（公开数据源，不调 AI）；
  //   ② AI 增强 = metallm + metasummary 合并 —— 一开同开、一关同关（保存时写 1,1 / 0,0）。
  // 源开关仍在 renderMetaSrcRows 里按注册表逐源绑定（metasrc_<id>，改完即落盘）。
  var eMetaOn = D('sp_metaon');
  if (eMetaOn) eMetaOn.onchange = function () { META.on = this.checked ? 1 : 0; saveSettings(); };
  var eMetaAi = D('sp_metallm');
  if (eMetaAi) eMetaAi.onchange = function () {
    META.llm = META.summary = this.checked ? 1 : 0;
    saveSettings();
    if (S.lastCur) loadMeta(S.lastCur);   // 关掉后简介板块要立刻消失，不用刷新
  };
  // 功能4：DeepSeek API Key（保存 / 测试连接 / 清除）。输入框重建后必须为空 ——
  // 这是「永不回显明文」的最后一道：哪怕浏览器缓存了 value，重建也会清掉。
  if (D('sp_llmsave')) D('sp_llmsave').onclick = llmSave;
  if (D('sp_llmtest')) D('sp_llmtest').onclick = llmTest;
  if (D('sp_llmclear')) D('sp_llmclear').onclick = llmClear;
  if (D('sp_llmkey')) {
    D('sp_llmkey').value = '';
    D('sp_llmkey').addEventListener('keydown', function (ev) { if (ev.key === 'Enter') llmSave(); });
  }
  llmRefresh();
  // 诊断页签的两个按钮（2026-10-22 功能3：从元数据迁出 + 改为一个 ZIP）
  if (D('sp_diagzip')) D('sp_diagzip').onclick = exportDiagZip;
  if (D('sp_diagjson')) D('sp_diagjson').onclick = exportDiag;
  // 2026-10-26（用户要求预留上传接口）：按钮已绑，端点未接上时会如实报失败，不假装成功
  if (D('sp_diagupload')) D('sp_diagupload').onclick = uploadDiag;
  // 功能2：相位说明跟随 1x 滤波器与相位覆盖的选择联动
  ['sp_filt', 'sp_phase', 'sp_filtNx'].forEach(function (id) {
    var e = D(id);
    if (e) e.addEventListener('change', bindPhaseHint);
  });
  bindPhaseHint();
  // P2 标签写回：预览 / 执行按钮绑定，并同步一次在跑状态（中途刷新页面也能恢复禁用）
  if (D('sp_wbdry')) D('sp_wbdry').onclick = wbPreview;
  if (D('sp_wbapply')) D('sp_wbapply').onclick = wbApply;
  // 元数据「高级选项」折叠（2026-10-23 用户反馈「元数据栏繁杂」）：默认收起，点开才显示逐源开关/Key/写回
  if (D('sp_metamore')) D('sp_metamore').onclick = function () {
    var box = D('sp_metaadv'); if (!box) return;
    var open = (box.style.display === 'none');
    box.style.display = open ? '' : 'none';
    this.setAttribute('aria-expanded', open ? 'true' : 'false');
    this.textContent = open ? '高级选项 ▴' : '高级选项 ▾';
  };
  wbSyncBusy();
  if (D('sp_directsdm')) D('sp_directsdm').onchange = function () {
    ADV.directsdm = this.checked ? 1 : 0;
    if (this.checked && S.vol !== 0) {   // 直通要求 0 dB，否则逐位一致无从谈起
      S.vol = 0;
      if (D('vol')) D('vol').value = volDbToPos(0);   // 0 dB = 位置 1000，不是 0
      // 走同一条 in-flight 通道（不是直接 api）：如果用户此刻正在拖音量、通道里还压着一个
      // 待发的拖动值，直接另发一个请求会和它乱序 —— 0 dB 可能被随后的旧拖动值覆盖掉。
      sendVolRealtime(0);
      if (typeof syncVolUi === 'function') syncVolUi();   // 标签跟着显示 0.0 dB
      toast('DirectSDM 需要 0 dB 音量，已把音量设为 0 dB');
    }
    saveSettings();
  };
  applyDsdState();
  if (D('sp_inbackend')) D('sp_inbackend').onchange = function () {
    ADV.inBackend = this.value; saveSettings();
    if (this.value === 'wasapi') loadInputDevices(); else if (D('sp_inmsg')) D('sp_inmsg').textContent = '';
  };
  if (D('sp_indev')) D('sp_indev').onchange = function () { ADV.inDev = this.value; saveSettings(); };
  if (D('sp_inch')) D('sp_inch').onchange = function () { ADV.inOffset = parseInt(this.value, 10) || 0; saveSettings(); };
  if (D('sp_inbuf')) D('sp_inbuf').onchange = function () { ADV.inBuf = parseInt(this.value, 10) || 100; saveSettings(); };
  if (D('sp_inmon')) D('sp_inmon').onchange = function () { ADV.inMonitor = this.checked ? 1 : 0; saveSettings(); };
  if (D('sp_inseconds')) D('sp_inseconds').onchange = function () { ADV.inSeconds = parseFloat(this.value) || 0; saveSettings(); };
  if (D('sp_inout')) D('sp_inout').onchange = function () { ADV.inOut = (this.value || '').trim(); saveSettings(); };
  if (D('sp_instart')) D('sp_instart').onclick = startInputCapture;
  if (D('sp_instop')) D('sp_instop').onclick = stopInputCapture;
  loadInputDevices();
  pollInputState();
  backendHint();

  // 事件
  loadDeviceList();
  // GPU 后端：把 Apple Metal 标成本机真实状态（后端有没有编出来、能不能真跑）
  api('/api/gpu').then(function (j) {
    // 断线时不能报成「本目录无 librtagpu.dylib」——那是会让用户去重装包的假结论。
    if (j && j._err) return;
    var sg = D('sp_gpu');
    if (sg) {
      Array.prototype.forEach.call(sg.options, function (o) {
        // 2026-10-25（用户指令「能使用的要用它真正的名字」）：macOS 只有 Metal 一条 GPU 路径。
        // metalUsable 才是「真的能跑」（动态库在 + rta_gpu_available() 返回 1）；
        // 只有 metal 而没有 metalUsable = 文件在但本机跑不起来（例如核函数编译失败）。
        if (o.value === 'metal') {
          o.text = !(j && j.metal) ? 'Apple Metal（GPU 加速）· 后端库未就位'
                 : (j.metalUsable === false ? 'Apple Metal（GPU 加速）· 已就位，本机未检测到可用 Metal 设备（会自动回退）'
                                            : 'Apple Metal（GPU 加速）· 后端已就位');
        }
      });
    }
    var m = D('sp_gpumsg');
    if (m) {
      m.textContent = '当前状态：' + (j && j.available ? 'GPU 可用' : '走 CPU（未找到可执行的 GPU 后端）');
      var metalInfo = (j && j.metal) ? ((j.metalUsable === false ? '已就位（本机不可用）' : '已就位（可用）')) : '未就位';
      m.title = 'Apple Metal=' + metalInfo + '；厂商偏好=' + ((j && j.vendor) || 'auto');
    }
    // 2026-10-26：把 #sp_irgpu 的标题改成**真实状态**，不再写死"需要就位"。
    //   三种情况分清楚，避免再出现"库里就在包里、界面却说需要就位"的假结论：
    //     ① 库不在（j.metal 为假）      → 后端库未打包（这才叫需要就位）
    //     ② 库在但本机跑不起来           → 已就位但本机不可用（会回退 CPU）
    //     ③ 库在且能跑                   → 已就位
    var irl = D('sp_irgpu_lbl');
    if (irl) {
      irl.textContent = '卷积走 GPU 硬件加速（' +
        (!(j && j.metal) ? '后端库未打包'
         : (j.metalUsable === false ? '后端已就位，本机不可用（会回退 CPU）' : '后端已就位')) + '）';
    }
  }).catch(function () { });
  if (ADV.inBackend === 'wasapi') loadInputDevices();
  // 流媒体页（用户 261024-01 #5）：列表 / 添加 / 编辑 / 删除 / 启用 / 测试 —— 全部即时落盘
  bindSrcPage();
  loadSrcConfig();
  // 2026-10-26：保存/恢复默认已改成「每个页签各一份」（见 cloneFootIntoPanes）。
  //   这里不再按 id 绑定（克隆之后 id 会重复），改为统一按 [data-act] 绑定。
  bindFootActions();
  function _resetAll() {
    if (!confirm('把所有参数恢复成默认值？')) return;
    ADV = { device: '', bits: 0, taps: 0, atten: 0, transition: 0, phase: '', modcut: 0, moddith: -1, ir: '', irgpu: 0, ramp: 0, theme: S.theme, modorder: 5, modfamily: 'dsd', directsdm: 0, dsdKind: 'fir', dsdConv: 'narrow',
            backend: 'wasapi', channels: 0, naaHost: '',
            inBackend: 'none', inDev: '', inOffset: 0, inBuf: 100, inMonitor: 0, inSeconds: 0, inOut: '' };
    // 元数据两键的默认：自动补全开；AI 增强关（联网计费项默认关，避免「恢复默认」反而产生费用）。
    // 源开关随注册表一并全开。
    META = { on: 1, llm: 0, summary: 0 };
    (META_PROVIDERS || []).forEach(function (p) { META_SRC[p.id] = 1; });
    D('sRate').value = 'max'; D('sFiltNx').value = ''; D('sShap').value = 'auto';
    D('sBuf').value = 100; D('sDSD').value = 0; D('sIsp').checked = true; D('s2s').checked = true;
    saveSettings(); renderSettingsPage(); toast('已恢复默认');
  }
  window._resetAllSettings = _resetAll;
  // 把母版保存栏克隆进每个 .spane，然后移除母版自身
  cloneFootIntoPanes();
  D('sp_theme').onchange = function () { setTheme(this.value); };
  if (D('sp_uistyle')) D('sp_uistyle').onchange = function () {
    setUiStyle(this.value);
    toast('已切换界面风格：' + (this.value === 'classic' ? '经典 Hi-Fi 工作台' : 'Apple Music 风格'));
  };
  // 2026-10-25（用户要求「要让用户可以通过点击文件夹来选择」）：原生目录选择
  if (D('sp_browseRoot')) {
    var bb = D('sp_browseRoot');
    if (IS_MAC_HOST) {
      bb.style.display = '';                 // 有宿主通道才显示，否则保持隐藏
      bb.onclick = function () {
        var cur = (D('sp_root') && D('sp_root').value || '').trim();
        pickDirectory(cur, function (path) {
          if (!path) return;                 // 用户取消
          if (D('sp_root')) D('sp_root').value = path;
          // 选完直接加入并扫描 —— 少一步点击，符合「点文件夹就选好」的直觉
          api('/api/lib/roots', 'add=' + encodeURIComponent(path)).then(function (j) {
            if (!j.ok) { toast(j.error || '添加失败'); return; }
            toast('已添加：' + path);
            libChanged(); loadLibStats(); api('/api/lib/scan', '');
            if (D('sp_root')) D('sp_root').value = '';
          });
        });
      };
    }
  }
  // 2026-10-25（方案 C）：Hog 独占开关
  if (D('sp_hogexcl')) {
    D('sp_hogexcl').onchange = function () {
      ADV.hogExclusive = this.checked ? 1 : 0;
      saveSettings();
      toast(this.checked
        ? '已开启严格独占：系统音量条将失效，请用本程序音量条调音量'
        : '已关闭严格独占：系统音量可正常调节');
    };
  }
  D('sp_addroot').onclick = function () {
    var d = (D('sp_root').value || '').trim();
    if (!d) { toast('请填目录'); return; }
    api('/api/lib/roots', 'add=' + encodeURIComponent(d)).then(function (j) {
      if (!j.ok) { toast(j.error || '添加失败'); return; }
      toast('已添加，正在扫描'); libChanged(); loadLibStats(); api('/api/lib/scan', '');
    });
  };
  D('sp_rescan').onclick = function () { api('/api/lib/scan', 'full=1').then(function () { toast('开始重新扫描'); libChanged(); loadLibStats(); }); };
  if (D('sp_scanthreads')) {
    D('sp_scanthreads').onchange = function () {
      ADV.scanThreads = parseInt(this.value, 10) || 0;
      saveSettings();
    };
  }
  // DLNA 发现按钮已移到「流媒体」页（用户 261024-01 #6），绑定在 bindSrcPage() 里做。
  drawRoots();
  // EQ 页签的内容在 renderSettingsPage 里一并渲染；这里统一做一次事件绑定 + 初始 OPRA 状态。
  initEqViewLogic();
  initCastControls();
  scanCastDevices(false);
  pollCastState();
  document.querySelectorAll('.tip').forEach(function (t) {
    if (t.getBoundingClientRect().left > window.innerWidth * 0.55) t.classList.add('tip-r');
    else t.classList.remove('tip-r');
  });
}
/* ---------------- EQ 与房间校正（261023-03 第6/7条） ---------------- */
var OPRA_INDEX = null;
var OPRA_PRESETS = [];
var _opraLoading = false;
var OPRA_CUR_PRODUCT = '';   // 当前请求预设的型号（连点竞态守卫）

// 2026-10-23 DEBUG：旧实现用 setInterval(100ms) 轮询等 OPRA_INDEX，请求失败时 OPRA_INDEX 永远为 null
// → 定时器永不清理（每敲一个字派生一个，后台 10Hz 空转）。改成 promise 缓存 + 失败后可重试。
var _opraPromise = null;
function loadOpraIndex(cb) {
  if (OPRA_INDEX) { if (cb) cb(); return; }
  if (!_opraPromise) {
    _opraPromise = api('/api/opra/index').then(function (j) {
      if (j && j.ok && Array.isArray(j.items)) OPRA_INDEX = j.items;
    }).catch(function () {
      // 失败不缓存 promise（下次进页面可重试）；本次直接让调用方走“未加载”分支
    }).then(function () {
      _opraPromise = null;
      if (cb) cb();
    });
    return;
  }
  _opraPromise.then(function () { if (cb) cb(); });
}

/* ---------------- 调音目标曲线示意（261023-03 第7条） ----------------
   内联 SVG 手绘近似：横轴 20Hz→20kHz（对数近似），纵轴相对 dB。
   只用作「这条目标曲线大概长什么样」的示意，不是测量数据；不引外部图片。
   颜色只用 CSS 变量（--line / --acc / --mut2），跟随深色/浅色主题。 */
var TARGET_CURVES = {
  harman_oe: { label: 'Harman 头戴目标：低频温和提升、中高频平顺',
    pts: [[0,6],[0.08,6],[0.15,5],[0.22,2.6],[0.30,0.8],[0.38,0],[0.47,0.5],[0.54,2.0],[0.60,2.6],[0.66,1.5],[0.72,0.3],[0.80,-0.4],[0.90,-0.2],[1.0,0.9]] },
  harman_iem: { label: 'Harman 入耳目标：低频更厚、3kHz 耳道增益',
    pts: [[0,9],[0.07,9],[0.13,7.2],[0.20,3.4],[0.27,0.8],[0.34,0],[0.44,0.4],[0.50,1.8],[0.55,6.0],[0.59,7.2],[0.64,2.6],[0.70,0.4],[0.80,-1.0],[0.90,-0.6],[1.0,1.2]] },
  autoeq: { label: 'AutoEQ 校准：按实测目标平直化，小幅低频架',
    pts: [[0,3.8],[0.10,3.8],[0.18,2.8],[0.26,1.0],[0.34,0],[0.46,0.5],[0.53,1.8],[0.60,0.6],[0.70,-0.3],[0.82,0],[1.0,0.6]] },
  studio: { label: '录音室中性：全频段尽量平直',
    pts: [[0,0],[0.12,-0.3],[0.24,-0.6],[0.36,-0.2],[0.50,0.2],[0.62,0.5],[0.74,0],[0.86,-0.3],[1.0,0]] },
  consumer: { label: '消费级曲线：低频与极高频微抬',
    pts: [[0,4.5],[0.12,4.5],[0.20,3.0],[0.30,0.8],[0.40,0],[0.52,0.8],[0.58,2.2],[0.65,0.8],[0.75,0.2],[0.85,0.8],[1.0,2.6]] },
  diffuse: { label: '扩散场目标：声场开阔、高频细节多',
    pts: [[0,0],[0.10,-0.3],[0.20,-0.6],[0.30,-0.6],[0.40,-0.3],[0.50,0.2],[0.60,1.0],[0.70,2.0],[0.80,2.8],[0.90,3.3],[1.0,3.6]] },
  freefield: { label: '自由场目标：接近消音室直达声',
    pts: [[0,0],[0.15,-0.2],[0.30,-0.5],[0.45,-0.4],[0.55,-0.1],[0.65,0.3],[0.75,0.9],[0.85,1.6],[1.0,2.4]] },
  senselab: { label: 'SenseLab 目标：高频峰谷精细补偿',
    pts: [[0,0.5],[0.15,0.2],[0.28,-0.2],[0.40,-0.3],[0.52,0.2],[0.60,1.2],[0.68,0.4],[0.80,-0.2],[1.0,0.4]] },
  rtings: { label: 'Rtings 参考目标：平直均衡',
    pts: [[0,2.5],[0.12,2.5],[0.22,1.4],[0.32,0.2],[0.45,0],[0.55,0.6],[0.62,1.2],[0.72,0],[0.85,-0.4],[1.0,0.3]] },
  optimum: { label: 'Optimum HiFi：低频克制、中频通透',
    pts: [[0,2.0],[0.14,2.0],[0.24,1.0],[0.34,0],[0.48,0.3],[0.56,1.0],[0.66,0.2],[0.80,-0.4],[1.0,0]] },
  neutral: { label: 'IEF 中性：平直无染',
    pts: [[0,0],[0.12,0],[0.24,-0.2],[0.36,-0.2],[0.50,0],[0.58,0.8],[0.66,0.2],[0.80,-0.4],[1.0,0]] }
};

// 判据与 getTargetCurveDescInfo 各分支保持一致（只用于挑 SVG 示意）
function curveKindOfDetails(details) {
  var d = (details || '').toLowerCase();
  if (d.indexOf('harman') >= 0) return (d.indexOf('in-ear') >= 0 || d.indexOf('iem') >= 0) ? 'harman_iem' : 'harman_oe';
  if (d.indexOf('soundguys_studio') >= 0) return 'studio';
  if (d.indexOf('soundguys_consumer') >= 0) return 'consumer';
  if (d.indexOf('diffuse') >= 0 || d.indexOf('hrtf') >= 0) return 'diffuse';
  if (d.indexOf('free_field') >= 0) return 'freefield';
  if (d.indexOf('senselab') >= 0) return 'senselab';
  if (d.indexOf('rtings') >= 0) return 'rtings';
  if (d.indexOf('optimum') >= 0 || d.indexOf('hifi') >= 0) return 'optimum';
  if (d.indexOf('neutral') >= 0 || d.indexOf('ief') >= 0) return 'neutral';
  return 'autoeq';
}

function targetCurveSvg(kind, H) {
  var c = TARGET_CURVES[kind] || TARGET_CURVES.autoeq;
  var W = 260, HH = H || 58, PAD = 6, MAXDB = 9, MINDB = -2;
  function px(x) { return PAD + x * (W - 2 * PAD); }
  function py(db) { return PAD + (MAXDB - db) / (MAXDB - MINDB) * (HH - 2 * PAD); }
  var pts = c.pts.map(function (p) { return px(p[0]).toFixed(1) + ',' + py(p[1]).toFixed(1); }).join(' ');
  var s = '<svg viewBox="0 0 ' + W + ' ' + HH + '" style="display:block;width:100%;height:auto" role="img" aria-label="' + esc(c.label) + '">';
  // 0dB 基准线 + 1kHz / 10kHz 竖向参考线
  s += '<line x1="' + PAD + '" y1="' + py(0).toFixed(1) + '" x2="' + (W - PAD) + '" y2="' + py(0).toFixed(1) + '" stroke="var(--line)" stroke-width="1" stroke-dasharray="3 3"/>';
  s += '<line x1="' + px(0.52).toFixed(1) + '" y1="' + PAD + '" x2="' + px(0.52).toFixed(1) + '" y2="' + (HH - PAD) + '" stroke="var(--line)" stroke-width="1" stroke-dasharray="2 4" opacity=".7"/>';
  s += '<line x1="' + px(0.80).toFixed(1) + '" y1="' + PAD + '" x2="' + px(0.80).toFixed(1) + '" y2="' + (HH - PAD) + '" stroke="var(--line)" stroke-width="1" stroke-dasharray="2 4" opacity=".7"/>';
  s += '<polyline points="' + pts + '" fill="none" stroke="var(--acc)" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"/>';
  s += '<circle cx="' + px(c.pts[0][0]).toFixed(1) + '" cy="' + py(c.pts[0][1]).toFixed(1) + '" r="2" fill="var(--acc)"/>';
  s += '<circle cx="' + px(c.pts[c.pts.length - 1][0]).toFixed(1) + '" cy="' + py(c.pts[c.pts.length - 1][1]).toFixed(1) + '" r="2" fill="var(--acc)"/>';
  s += '<text x="' + PAD + '" y="' + (HH - 1) + '" font-size="7" fill="var(--mut2)">20Hz</text>';
  s += '<text x="' + (px(0.52) - 8).toFixed(1) + '" y="' + (HH - 1) + '" font-size="7" fill="var(--mut2)">1k</text>';
  s += '<text x="' + (W - PAD - 16) + '" y="' + (HH - 1) + '" font-size="7" fill="var(--mut2)">20k</text>';
  s += '</svg>';
  return s;
}

// 对外接口：在原有「中文解释」上补一个 kind（用于选 SVG 示意），不改变原判据
function getTargetCurveDesc(details, author) {
  var c = getTargetCurveDescInfo(details, author);
  c.kind = curveKindOfDetails(details);
  return c;
}

function getTargetCurveDescInfo(details, author) {
  var d = (details || '').toLowerCase();
  var a = (author || '').toLowerCase();
  if (d.indexOf('harman') >= 0 && (d.indexOf('in-ear') >= 0 || d.indexOf('iem') >= 0)) {
    return {
      name: '哈曼入耳目标曲线 (Harman In-Ear)',
      scene: '针对入耳式耳道封闭增强低频动态与人声清晰度，适合现代流行、人声与节奏感强的音乐。',
      tech: 'Harman In-Ear Target 补偿了耳道封闭效应，适度提升 100Hz 以下低频与 3kHz 附近耳甲腔增益，提供接近高品质音箱的听感。'
    };
  }
  if (d.indexOf('harman') >= 0) {
    return {
      name: '哈曼头戴目标曲线 (Harman Over-Ear)',
      scene: '符合大众听音盲测偏好，低频温暖厚实、中高频平衡耐听，杂食百搭，适合绝大多数现代流行乐与影视原声。',
      tech: 'Harman Target 基于 Harman 实验室长期双盲听音实验，低频有约 4~6dB 适度平滑提升，高频平顺无刺激刺耳感。'
    };
  }
  if (d.indexOf('soundguys_studio') >= 0) {
    return {
      name: 'SoundGuys 录音室中性曲线',
      scene: '严格平直的工作室参考曲线，适合录音棚监听、音频剪辑与追求原汁原味还原的听众。',
      tech: 'SoundGuys Studio 目标注重全频段线性度，消除耳机本身声学谐振，为混音制作提供真实基准。'
    };
  }
  if (d.indexOf('soundguys_consumer') >= 0) {
    return {
      name: 'SoundGuys 大众消费曲线',
      scene: '兼顾清晰度与氛围感，微调低频弹性与高频空气感，适合日常通勤随身聆听与流媒体影视。',
      tech: '面向普通消费者的均衡曲线，在平直基础上微抬极低频与极高频，听感更具感染力。'
    };
  }
  if (d.indexOf('diffuse') >= 0 || d.indexOf('hrtf_5128') >= 0) {
    return {
      name: '扩散场目标曲线 (Diffuse Field / HRTF)',
      scene: '模拟无指向多反射声学空间，空间定位感与高频解析力极强，特别适合大编制古典交响乐与现场录音。',
      tech: 'Diffuse Field 曲线基于人工头在混响室中测量的自由声场平均响应，声场开阔通透，高频细节丰富。'
    };
  }
  if (d.indexOf('free_field') >= 0) {
    return {
      name: '自由场目标曲线 (Free Field)',
      scene: '模拟消音室正前方向直达声，干脆纯净，适合需要清晰方向判断的专业监听。',
      tech: 'Free Field 曲线反映消音室内扬声器正前方的直达声听觉响应。'
    };
  }
  if (d.indexOf('senselab') >= 0) {
    return {
      name: 'SenseLab 声学实验室目标',
      scene: '注重高保真声学平直度与相位一致性，适合乐器真实音色鉴赏与原声发烧录音。',
      tech: 'SenseLab 方案基于精细声学补偿，重点修正耳机单元在高频段的群延迟与频响峰谷。'
    };
  }
  if (d.indexOf('rtings') >= 0) {
    return {
      name: 'Rtings 参考目标曲线',
      scene: 'Rtings 实验室测量的平直均衡曲线，适合影视与游戏声效还原。',
      tech: 'Rtings 综合目标结合声学生理模型，旨在使耳机频响趋近于平直扬声器室内频响。'
    };
  }
  if (d.indexOf('optimum') >= 0 || d.indexOf('hifi') >= 0) {
    return {
      name: '最佳高保真目标曲线 (Optimum HiFi)',
      scene: '低频平顺不轰鸣、中频通透无染色，适合古典乐、爵士乐与纯乐器发烧录音。',
      tech: 'Optimum HiFi 强调极低失真与线性动态，不对低频做过多主观提升，保持纯正声底。'
    };
  }
  if (d.indexOf('neutral') >= 0 || d.indexOf('ief') >= 0) {
    return {
      name: 'IEF 中性监听目标 (Neutral)',
      scene: '监听级纯中性调音，无主观音染，适合专业音频工作者与追求纯粹原声的用户。',
      tech: 'IEF Neutral 以平直无染为核心，低频不外加低音架，高频顺滑延伸。'
    };
  }
  var authorName = author || 'AutoEQ';
  return {
    name: details || (authorName + ' 专业校准预设'),
    scene: '由 ' + authorName + ' 依据测量数据生成的校准滤波，平直化固有频响缺陷。',
    tech: '基于 AutoEq 优化算法与专业人工耳测量数据计算所得的双二阶 IIR 滤波器组。'
  };
}

// EQ 页签当前是否可见（设置页开着 + 选中 EQ 页签）。用于丢弃切走后的异步回调。
function eqTabActive() {
  var p = document.querySelector('#setpage .spane[data-g=eq]');
  return !!(p && p.classList.contains('on'));
}
/* EQ 与房间校正（用户 261023-04 #2：从左侧主导航移进设置页的「EQ」页签）
   内容沿用原来的三块：① 耳机 EQ（OPRA 校准预设）② EQ 文件（REW / AutoEq）③ 房间校正 IR（WAV + GPU 卷积）。
   改用设置页统一的分组卡片（sgroup），不再用原来的独立大卡片，保证页签内视觉与其它页一致。 */
function eqSettingsHtml() {
  var h = '';
  // 0. 20 段参数均衡 PEQ（261024-02 #6）—— 新增，放在 EQ 页最上面
  h += sgroup('参数均衡 PEQ（20 段 · HIFI）',
      'RBJ 双二阶 · 20 段 ISO 1/3 倍频程中心频率（20Hz~20kHz）· 采样率相关重建 · 参数热更新交叉淡入',
      // 261024-04 #3：用户问「旁路是什么意思？当前是不是默认就启动 PEQ？只有勾选旁路才不生效？」——
      // 组标题下常驻一行状态（生效 / 已旁路），复选框文案直接写明勾选的含义，
      // 并说清「默认生效，但 20 段全 0 dB = 不改变声音」（后端 src/dsp/peq.h: bypass 默认 false，20 段默认 0 dB）。
      '<div class="sfld wide"><div class="peqstat" id=peqStat><span class=tag>状态</span>' +
        '<span id=peqStatTxt>PEQ 当前：读取中…</span></div>' +
        '<div class=hint id=peqByPassHint>旁路 = 绕过 PEQ（20 段全部不参与计算，信号直通）。默认<strong>生效</strong>；' +
        '出厂 20 段全为 0 dB、前级 0 dB，所以即使生效也不改变声音（等同直通）。</div></div>'
    + '<div class="sfld wide" style="display:flex;align-items:center;gap:14px;flex-wrap:wrap">'
    + '<label class=chk style="margin:0" title="勾选 = PEQ 不生效（直通）；不勾选 = PEQ 生效"><input type=checkbox id=peqBypass> 旁路（勾选 = PEQ 不生效，直通）</label>'
    + '<label style="font-size:12px;color:var(--mut2)">前级增益 <input type=number id=peqPreamp step=0.1 min=-24 max=24 value=0 style="width:74px;height:26px"> dB</label>'
    // 261024-03 #5：按曲线峰值一键设前级，防削波（只在前端算，DSP 不动）
    + '<button class="btn" id=peqAutoPre type=button title="把前级设为 -ceil(当前曲线峰值增益)，给 EQ 提升留出余量，避免数字削波">自动前级（防削波）</button>'
    + '<label style="font-size:12px;color:var(--mut2)">预设 <select id=peqPreset style="min-width:160px;height:26px"></select></label>'
    + '<button class="btn" id=peqLoad type=button>加载</button>'
    + '<button class="btn" id=peqSave type=button>保存为预设…</button>'
    + '<button class="btn" id=peqDelete type=button>删除预设</button>'
    + '<button class="btn" id=peqReset type=button>重置 Flat</button>'
    + '<span id=peqMsg style="font-size:11.5px;color:var(--mut2)"></span>'
    + '</div>'
    + '<div class="sfld wide"><div class="peqcv" id=peqCurve></div></div>'
    + '<div class="sfld wide"><div class=peqwrap>'
    + '<div id=peqRows class=peqrows></div>'
    + '</div>'
    + '<div style="font-size:11px;color:var(--mut2);margin-top:5px">增益 ±12 dB（步进 0.1）· Q 0.1~20 · 频率 10 Hz~20 kHz。'
    + '曲线上 <b>拖拽节点</b>：水平=频率（对数）、垂直=增益；<b>Shift+拖 / 滚轮</b>=改 Q；<b>双击节点</b>=该段复位（0 dB / Q 1.41）。'
    + '选中行后 <b>↑↓</b>=增益 0.1 dB、<b>←→</b>=频率 ±1%（Shift 加速）。修改即时生效（热更新，交叉淡入防爆音），并自动保存到 rlplayer-peq.txt。</div></div>');


  // 1. 耳机 EQ（OPRA）
  h += sgroup('耳机 EQ（OPRA 校准预设）', '收录 6,230 款耳机专业校准滤波 · CC BY-SA 4.0',
      '<div class="sfld wide" style="display:flex;align-items:center;gap:10px">'
    + '<input id=sp_opra_search type=text placeholder="搜索耳机品牌或型号（如 Sennheiser / HD 600 / AirPods / Sony / XM5…）" autocomplete=off style="flex:1;min-width:0;width:auto;height:34px;padding:0 12px;background:var(--field);border:1px solid var(--line);border-radius:8px;font-size:12.5px;color:var(--txt);box-sizing:border-box">'
    + '<span class="chip" id=sp_opra_copychip title="复制 OPRA 项目官网链接" style="cursor:pointer;display:inline-flex;align-items:center;font-size:11.5px;flex:none">'
    + '<svg width=12 height=12 viewBox="0 0 24 24" fill=none stroke=currentColor stroke-width=2 style="margin-right:4px"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>https://opra.roon.app/</span>'
    + '</div>'
    + '<div class="sfld wide" id=eqSearchGuide style="padding:2px 0 0">'
    + '<div style="display:flex;flex-wrap:wrap;gap:8px" id=eqBrandChips>'
    + '<button class="btn brand-chip" data-brand="Sennheiser">森海塞尔 Sennheiser</button>'
    + '<button class="btn brand-chip" data-brand="Sony">索尼 Sony</button>'
    + '<button class="btn brand-chip" data-brand="Apple">苹果 Apple</button>'
    + '<button class="btn brand-chip" data-brand="Beyerdynamic">拜雅 Beyerdynamic</button>'
    + '<button class="btn brand-chip" data-brand="Audio-Technica">铁三角 Audio-Technica</button>'
    + '<button class="btn brand-chip" data-brand="AKG">爱科技 AKG</button>'
    + '<button class="btn brand-chip" data-brand="Hifiman">海菲曼 Hifiman</button>'
    + '<button class="btn brand-chip" data-brand="Focal">劲浪 Focal</button>'
    + '</div></div>'
    + '<div class="sfld wide" id=sp_opra_searchhint style="font-size:12px;color:var(--mut2);display:none"></div>'
    + '<div class="sfld wide"><div id=eqModelCards style="display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:10px"></div></div>'
    + '<div class="sfld wide" id=eqPresetsArea style="display:none;margin-top:16px;padding-top:14px;border-top:1px dashed var(--line)">'
    + '<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px;gap:10px;flex-wrap:wrap">'
    + '<h3 id=eqSelectedModelTitle style="font-size:14px;margin:0;font-weight:600">选择调音目标预设</h3>'
    + '<span id=sp_opra_msg style="font-size:12px;color:var(--mut2)"></span>'
    + '</div>'
    + '<div id=eqPresetCards style="display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px"></div>'
    + '<div id=eqTargetCurveInfo style="margin-top:16px;padding:14px 16px;background:var(--field);border:1px solid var(--line);border-radius:8px;font-size:12.5px;color:var(--txt2);line-height:1.6;display:none"></div>'
    + '</div>');
  return h;
}

/* ---------------- R-1 房间测量向导（2026-10-27）----------------
   铁律 1 的 UI 落地点：**先取 /api/roomcorr/plan 把"会向哪个设备播多久多响"摆给用户**，
   用户点确认之后才 POST measure?confirm=1。没有确认这一步就绝不下发 measure ——
   后端也会二次校验（缺 confirm 回 428），两边都不许绕过。 */
var RCWIZ = { plan: null, poll: 0 };
function rcRenderPlan(p) {
  if (!p || !p.ok) {
    D('rcStatus').textContent = '配置有误';
    D('rcStatusSub').textContent = (p && p.error) || '无法生成测量计划';
    return;
  }
  RCWIZ.plan = p;
  D('rcStatus').textContent = p.chCount + ' 声道 · 约 ' + Math.round(p.totalSeconds) + ' 秒';
  D('rcStatusSub').textContent = '输出：' + p.playDevice + ' · 采集：' + p.captureDevice;
  openModal('房间测量确认', renderRoomConfirm(p));
  if (D('rcGo')) D('rcGo').onclick = rcStart;
  if (D('rcCancel2')) D('rcCancel2').onclick = function () { D('modal').classList.remove('on'); };
}
function renderRoomConfirm(p) {
  return '<div style="font-size:12.5px;line-height:1.7">' +
    '<div style="padding:10px;border:1px solid var(--warn);border-radius:8px;background:var(--bg3);margin-bottom:10px">' +
    '<b style="color:var(--warn)">⚠️ 这次测量会真的出声</b><div style="margin-top:6px">' + esc(p.warning) + '</div></div>' +
    '<table style="font-size:12px;border-collapse:collapse;margin-bottom:10px">' +
    '<tr><td style="padding:2px 12px 2px 0;color:var(--mut)">声道布局</td><td>' + esc(p.layout) + '（' + p.chCount + ' 声道）</td></tr>' +
    '<tr><td style="padding:2px 12px 2px 0;color:var(--mut)">每声道扫频</td><td>' + Math.round(p.sweepSeconds * 1000) + ' ms</td></tr>' +
    '<tr><td style="padding:2px 12px 2px 0;color:var(--mut)">预计总时长</td><td>约 ' + Math.round(p.totalSeconds) + ' 秒</td></tr>' +
    '<tr><td style="padding:2px 12px 2px 0;color:var(--mut)">电平</td><td>' + p.levelDbfs + ' dBFS</td></tr>' +
    '<tr><td style="padding:2px 12px 2px 0;color:var(--mut)">输出设备</td><td>' + esc(p.playDevice) + '</td></tr>' +
    '<tr><td style="padding:2px 12px 2px 0;color:var(--mut)">采集设备</td><td>' + esc(p.captureDevice) + '</td></tr>' +
    '</table>' +
    '<div class=hint style="margin-bottom:10px">共享模式：不会静音系统其它声音；测量期间请保持安静，可随时取消。</div>' +
    '<div style="display:flex;gap:10px"><button class="btn pri" id=rcGo>确认并开始测量</button>' +
    '<button class="btn" id=rcCancel2>取消</button></div></div>';
}
function rcPoll() {
  if (RCWIZ.poll) return;
  RCWIZ.poll = setInterval(function () {
    api('/api/roomcorr/status').then(function (s) {
      if (!s || !s.ok) return;
      if (s.phase === 'running') {
        D('rcStatus').textContent = '测量中 ' + s.channelsDone + '/' + s.channelsTotal +
                                    (s.currentChannel ? '（' + s.currentChannel + '）' : '');
      } else {
        clearInterval(RCWIZ.poll); RCWIZ.poll = 0;
        if (s.phase === 'done') {
          D('rcStatus').textContent = '完成 ' + (s.channels || []).length + ' 声道';
          var bad = (s.channels || []).filter(function (c) { return !c.valid; });
          D('rcStatusSub').textContent = bad.length
            ? ('有 ' + bad.length + ' 个声道无效：' + bad.map(function (c) { return c.name; }).join('、'))
            : '全部声道有效';
        } else if (s.phase === 'cancelled') {
          D('rcStatus').textContent = '已取消';
          D('rcStatusSub').textContent = '未生成校正集';
        } else if (s.phase === 'failed') {
          D('rcStatus').textContent = '测量失败';
          D('rcStatusSub').textContent = s.error || '';
        }
      }
    }).catch(function () {});
  }, 700);
}
function rcStart() {
  var p = RCWIZ.plan;
  if (!p || !p.ok) return;
  if (D('rcGo')) D('rcGo').disabled = true;
  var lay = (D('rcLayout') && D('rcLayout').value) || p.layout;
  api('/api/roomcorr/measure?layout=' + encodeURIComponent(lay) + '&sec=' + p.sweepSeconds + '&confirm=1', '').then(function (r) {
    if (D('modal')) D('modal').classList.remove('on');
    if (!r || r.ok !== true) { toast((r && r.error) || '无法开始测量'); return; }
    D('rcStatus').textContent = '测量中…';
    D('rcStatusSub').textContent = '正在向 ' + p.playDevice + ' 播放扫频（可点取消）';
    if (D('bRoomWiz')) { D('bRoomWiz').textContent = '取消测量'; D('bRoomWiz').onclick = function () {
      api('/api/roomcorr/cancel', '').then(function () { toast('已请求取消'); });
    }; }
    rcPoll();
  }).catch(function (e) { toast('测量请求失败：' + (e && e.message ? e.message : e)); });
}
function rcWizard() {
  var lay = (D('rcLayout') && D('rcLayout').value) || '2.0';
  D('rcStatus').textContent = '生成计划…';
  api('/api/roomcorr/plan?layout=' + encodeURIComponent(lay) + '&sec=6').then(rcRenderPlan)
    .catch(function (e) { D('rcStatus').textContent = '计划失败'; D('rcStatusSub').textContent = String(e); });
}

/* 声音校准页签（Q-9 独立页签）：① 房间测量向导 ② 校正文件（REW / AutoEq 文本）③ 房间校正 IR（WAV + GPU 卷积） */
function calSettingsHtml() {
  var h = '';
  // 1. 房间校正（测量向导）—— 本版暂隐藏向导卡片，保留提示文案与 DOM 结构（供之后改版与既有绑定安全）
  h += sgroup('房间校正（测量向导）', '房间测量功能正在重构中',
      '<div class="sfld wide"><div class=rcnote style="color:var(--txt2);padding:10px 12px;background:var(--bg2);border-radius:6px;border:1px solid var(--line)">'
    + '房间测量正在重做，本版暂不提供。支持已有的「EQ 文件」与「房间校正 IR」独立加载。'
    + '</div></div>');
  h += '<div id=roomCorrCard style="display:none">' + sgroup('房间校正（测量向导）', 'Farina 对数扫频 → 反卷积 → 心理声学平滑 → 目标曲线 → 最小相位校正 FIR · 多声道 2.0~7.1.4',
      '<div class="sfld wide"><div class="in-stat-grid" style="grid-template-columns:repeat(auto-fit,minmax(250px,1fr))">'
    + '<div class=in-stat-item><span class=lbl>算法版本</span><span class="val sm">CoreAudio 测量链路</span>' +
      '<div class=rcsub>room_correction.h · room_measurement.h · room_transport_coreaudio.h</div></div>'
    + '<div class=in-stat-item><span class=lbl>支持声道布局</span><span class="val sm">2.0 ~ 7.1.4（6 种）</span>' +
      '<div class=rcsub>2.0 / 2.1 / 5.1 / 7.1 / 5.1.2 / 7.1.4 · 带 .1 的 LFE 分频 80 Hz</div></div>'
    + '<div class=in-stat-item><span class=lbl>当前状态</span><span class="val sm" id=rcStatus>未测量</span>' +
      '<div class=rcsub id=rcStatusSub>点「开始向导」跑一次测量</div></div>'
    + '</div></div>'
    + '<div class="sfld wide" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">'
    + '<label style="font-size:12px">声道布局 <select id=rcLayout style="min-height:28px">'
    + '<option value=2.0>2.0</option><option value=2.1>2.1</option><option value=5.1>5.1</option>'
    + '<option value=7.1>7.1</option><option value=5.1.2>5.1.2</option><option value=7.1.4>7.1.4</option></select></label>'
    + '<button class="btn pri" id=bRoomWiz type=button>开始向导</button>'
    + '<button class="btn" id=bRoomDl type=button style="display:none">下载校正集</button>'
    + '<span class=rcnote id=rcHint>分 7 步走完一次测量（选布局 → 摆麦 → 测各声道 → 质检 → 生成校正集）。</span>'
    + '</div>'
    + '<div class="sfld wide"><div class=rcnote>测量结果（每声道校正 FIR，32-bit float）保存到 <code>data/roomcorr/</code>；'
    + '应用后由播放链路的 FIR 卷积执行（与下面「校正文件 → 脉冲响应 IR」共用同一个卷积器）。<br>'
    + '测量会<strong>真的出声</strong>：每个声道一段对数扫频，默认电平 −20 dBFS，开始前会让你确认设备与时长。</div></div>'
    ) + '</div>';

  // 2. EQ 文件（REW / AutoEq 文本）
  h += sgroup('EQ 文件（REW / AutoEq 文本）', '按文件里的 Filter 行生成双二阶滤波器组',
      '<div class="sfld wide"><label>EQ 文件路径' + tip('每行形如 Filter 1: ON PK Fc 1000 Hz Gain -3.0 dB Q 1.41') + '</label>'
    + '<input type=text id=sp_eq value="' + esc(ADV.eq || '') + '" placeholder="' + (SEP === '/' ? '/Users/你的用户名/Music/headphone-eq.txt' : 'D:\\Music\\headphone-eq.txt') + '"></div>');

  // 3. 房间校正 IR（WAV 路径 + GPU 卷积开关）
  h += sgroup('房间校正 IR（WAV 脉冲响应）', '把房间 / 耳机脉冲响应用 FIR 卷积叠进播放链路',
      '<div class="sfld wide"><label>IR 脉冲响应卷积文件（WAV）' + tip('留空 = 不做卷积；支持立体声 / 多声道 FIR 房间校正') + '</label>'
    + '<input type=text id=sp_ir value="' + esc(ADV.ir || '') + '" placeholder="' + (SEP === '/' ? '/Users/你的用户名/Music/room.wav' : 'D:\\Music\\room.wav') + '"></div>'
    + chk('sp_irgpu', '卷积走 GPU 硬件加速（检测中…）', ADV.irgpu == 1,
          '⚠️ macOS 上不建议开启：实测（Apple M4）卷积走 GPU 在任何 IR 长度下都比 CPU 慢 3.4~8.3 倍。'
          + '原因是 mac 的 GPU 后端把 FFT 留在 CPU、GPU 只做逐点复数乘加，而生产每块只有 4096 样，'
          + '远低于 GPU 的盈亏平衡点（实测需 n≥32768 才翻盘）。'
          + '功能保留可用（数值正确），但默认关闭。详见 docs/GPU卷积与升频效率细查.md')
    );
  return h;
}
/* ---------------- 20 段参数均衡 PEQ（261024-02 #6） ---------------- */
var PEQ_STATE = null;
var PEQ_TIMER = 0;

function peqRowsEl() { return document.querySelectorAll('#peqRows .peqr'); }
// 频率输入框接受友好写法：'20 Hz' / '1.02 kHz' / '1020' / '1.02k'
function peqParseFreq(s) {
  var t = String(s == null ? '' : s).toLowerCase().replace(/\s+/g, '');
  var m = /^([0-9]*\.?[0-9]+)(k|khz|hz)?$/.exec(t);
  if (!m) return NaN;
  var f = parseFloat(m[1]);
  if (m[2] === 'k' || m[2] === 'khz') f *= 1000;
  return f;
}
// 友好显示：<1 kHz 用 Hz（20 Hz），>=1 kHz 用 kHz（1.02 kHz / 10.0 kHz）
function peqFreqText(f) {
  f = +f || 0;
  if (f >= 10000) return (f / 1000).toFixed(1) + ' kHz';
  if (f >= 1000) return (f / 1000).toFixed(2) + ' kHz';
  return Math.round(f) + ' Hz';
}
function peqClampFreq(f) { return Math.max(10, Math.min(20000, +f || 1000)); }
function peqRowBand(tr) {
  var f = tr.querySelector('.peqF'), g = tr.querySelector('.peqG'), q = tr.querySelector('.peqQ');
  var t = tr.querySelector('.peqT'), on = tr.querySelector('.peqOn');
  var fv = peqParseFreq(f.value);
  if (!isFinite(fv) || fv <= 0) fv = 1000;
  return {
    i: +tr.dataset.i, type: t.value, freq: peqClampFreq(fv),
    gain: Math.max(-12, Math.min(12, parseFloat(g.value) || 0)),
    q: Math.max(0.1, Math.min(20, parseFloat(q.value) || 1.41)),
    on: on.checked
  };
}
function peqCollectBands() {
  var out = [];
  Array.prototype.forEach.call(peqRowsEl(), function (tr) { out.push(peqRowBand(tr)); });
  return out;
}
function peqBandsParam() {
  return peqCollectBands().map(function (b) {
    return b.i + ',' + b.type + ',' + b.freq + ',' + b.gain + ',' + b.q + (b.on ? '' : ',off');
  }).join(';');
}
// 频响曲线：后端 /api/peq 直接给 [频率, dB] 点（与 C++ 设计公式同源，前端不抄第二份）
// 261024-03 #5 HIFI 化：曲线上叠 20 个频段节点（可拖/滚轮/双击），并做增量更新
//（增量很关键：拖拽时 peqApply 每次回来都重建 SVG 会丢掉 pointer capture，拖到一半就断）
var PEQ_VIEW = null;      // 曲线坐标映射（拖拽换算要用）
var PEQ_DRAG = null;      // {i, mode:'g'|'q', y0, q0}
var PEQ_LASTCLICK = null; // {i, t}：自己判双击（不依赖宿主是否派发 dblclick）
// 2026-10-27 R-5：波形宽度自适应。旧版 viewBox 写死 640 宽、CSS 拉到 100% ⟹ 大屏上整块 SVG
// （含 9px 刻度字、1.8px 曲线）被等比放大 1.09 倍，文字发虚、线宽变粗；而且 .peqcv 上限
// 720px 比表格的 920px 窄 200px，右侧空一条。
// 现在：viewBox 宽度 = 实测 CSS 宽度 ⟹ 1:1 渲染（scale 恒为 1.0），容器一变就按新宽度重画。
// ⚠️ 口径：peqSvgPoint() 本来就是 getBoundingClientRect() 按比例映射，CSS 拉伸**不会**让拖拽点
// 错位（实测 scaleX==scaleY，等比缩放）。这条改动解决的是视觉一致性/信息密度，不是修拖拽 bug。
var PEQ_W = 640;          // 当前绘图宽度（viewBox 单位，与 CSS 像素 1:1）
var PEQ_H = 132;          // 绘图高度（固定）
var PEQ_PTS = 160;        // 曲线采样点数（按宽度算密度，见 peqResample）
var PEQ_OBS = null;       // ResizeObserver 句柄
var PEQ_OBS_EL = null;    // 正在观察的容器（换容器才重连，避免每次 apply 都 disconnect/observe）
// 量出波形实际可用的 CSS 宽度。优先量 svg 自身（它 width:100%，已扣掉 .peqcv 的 padding/border）；
// 首次绘制时 svg 还没建，退回「容器内容宽度」。
function peqMeasureW() {
  var box = D('peqCurve'); if (!box) return 0;
  var svg = box.querySelector('svg.peqsvg');
  if (svg) { var r = svg.getBoundingClientRect(); var w0 = Math.round(r.width); if (w0 > 0) return w0; }
  var cs = window.getComputedStyle(box);
  var pad = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
  var cw = Math.round(box.clientWidth - pad);
  return cw > 0 ? cw : 0;
}
// 按对数频率均匀重采样到 n 点。后端固定给 160 点；宽屏下 plot 区超过 ~960px 时
// 160 点会稀于 1 点/6px，这里线性插值补密（窄屏 n<=原点数直接返回，不做无用计算）。
function peqResample(points, n) {
  if (!points || points.length < 2 || n <= points.length) return points;
  var lf = function (f) { return Math.log(Math.max(20, Math.min(20000, +f))); };
  var lo = lf(20), hi = lf(20000), out = [], k = 0;
  for (var i = 0; i < n; i++) {
    var t = lo + (hi - lo) * i / (n - 1), f = Math.exp(t);
    while (k < points.length - 2 && lf(points[k + 1][0]) < t) k++;
    var a = points[k], b = points[k + 1] || a;
    var fa = lf(a[0]), fb = lf(b[0]);
    var u = (fb > fa) ? Math.max(0, Math.min(1, (t - fa) / (fb - fa))) : 0;
    out.push([f, a[1] + (b[1] - a[1]) * u]);
  }
  return out;
}
// 容器宽度变了就按新宽度重画。亚像素抖动不重画 —— ResizeObserver 里改 viewBox 会改变 SVG
// 高度（height:auto 跟宽高比走），不加这道闸可能自激。
function peqReflow() {
  var w = peqMeasureW();
  if (!w || Math.abs(w - PEQ_W) < 1) return;
  peqDrawCurve((PEQ_STATE && PEQ_STATE.points) || []);
}
// 监听波形容器尺寸。同一个容器已在观察就直接返回（peqDrawCurve 每次 apply 都会调到这里）。
function peqObserveWidth() {
  var box = D('peqCurve'); if (!box) return;
  if (PEQ_OBS && PEQ_OBS_EL === box) return;
  if (PEQ_OBS) { try { PEQ_OBS.disconnect(); } catch (e) { } }
  PEQ_OBS = null; PEQ_OBS_EL = null;
  if (typeof ResizeObserver !== 'function') {
    // 兜底：老宿主没有 ResizeObserver 时退回 window.resize（mac 壳是 NSWindow，拉窗同样触发）
    if (!peqObserveWidth._win) {
      peqObserveWidth._win = 1;
      window.addEventListener('resize', function () { peqReflow(); });
    }
    return;
  }
  try {
    PEQ_OBS = new ResizeObserver(function () { peqReflow(); });
    PEQ_OBS.observe(box);
    PEQ_OBS_EL = box;
  } catch (e) { PEQ_OBS = null; }
}
function peqFreqX(f) {
  var v = PEQ_VIEW; if (!v) return 0;
  return v.PADL + (Math.log(Math.max(20, Math.min(20000, f)) / 20) / Math.log(1000)) * (v.W - v.PADL - v.PADR);
}
function peqGainY(db) {
  var v = PEQ_VIEW; if (!v) return 0;
  return v.PADT + (v.maxDb - db) / (v.maxDb - v.minDb) * (v.H - v.PADT - v.PADB);
}
function peqCurveFreqAt(x) {
  var v = PEQ_VIEW; if (!v) return 1000;
  var t = (x - v.PADL) / (v.W - v.PADL - v.PADR);
  return peqClampFreq(20 * Math.pow(1000, Math.max(0, Math.min(1, t))));
}
function peqCurveGainAt(y) {
  var v = PEQ_VIEW; if (!v) return 0;
  var t = (y - v.PADT) / (v.H - v.PADT - v.PADB);
  return Math.max(-12, Math.min(12, v.maxDb - Math.max(0, Math.min(1, t)) * (v.maxDb - v.minDb)));
}
function peqDrawCurve(points) {
  var box = D('peqCurve'); if (!box) return;
  if (!points || !points.length) {
    box.innerHTML = '<div style="font-size:11.5px;color:var(--mut2);padding:12px 0">频响曲线（等待数据…）</div>';
    PEQ_VIEW = null;
    return;
  }
  var H = 132, PADL = 36, PADR = 10, PADT = 10, PADB = 18;
  // R-5：宽度不再写死 640 —— 量容器实际宽度当 viewBox 宽，SVG 1:1 渲染（不再被 CSS 放大）。
  // 量不到（容器还没布局/隐藏）才退回上次宽度，最后兜底 640。
  var mw = peqMeasureW();
  var W = mw > 120 ? mw : (PEQ_W > 120 ? PEQ_W : 640);
  PEQ_W = W; PEQ_H = H;
  // 采样点数跟着宽度走：约 1 点 / 3px（宽屏补密，曲线仍平滑），上限 800 防点数爆掉。
  // 下限固定 160 = 后端原始点数（窄屏不补密，不做无用计算）。
  var wantPts = Math.max(160, Math.min(800, Math.round(W / 3)));
  PEQ_PTS = wantPts;
  var maxDb = 6, minDb = -6;
  points.forEach(function (p) { maxDb = Math.max(maxDb, p[1]); minDb = Math.min(minDb, p[1]); });
  maxDb = Math.ceil(maxDb / 3) * 3; minDb = Math.floor(minDb / 3) * 3;
  PEQ_VIEW = { W: W, H: H, PADL: PADL, PADR: PADR, PADT: PADT, PADB: PADB, maxDb: maxDb, minDb: minDb };
  points = peqResample(points, wantPts);

  var g = '';
  for (var d = Math.ceil(minDb / 6) * 6; d <= maxDb; d += 6) {
    g += '<line x1="' + PADL + '" y1="' + peqGainY(d).toFixed(1) + '" x2="' + (W - PADR) + '" y2="' + peqGainY(d).toFixed(1) +
         '" stroke="var(--line)" stroke-width="1" stroke-dasharray="' + (d === 0 ? '4 3' : '2 4') + '" opacity="' + (d === 0 ? '0.9' : '0.5') + '"/>';
    g += '<text x="2" y="' + (peqGainY(d) + 3).toFixed(1) + '" font-size="9" fill="var(--mut2)">' + d + 'dB</text>';
  }
  [[20, '20'], [100, '100'], [1000, '1k'], [10000, '10k'], [20000, '20k']].forEach(function (fk) {
    var x = peqFreqX(fk[0]);
    g += '<line x1="' + x.toFixed(1) + '" y1="' + PADT + '" x2="' + x.toFixed(1) + '" y2="' + (H - PADB) + '" stroke="var(--line)" stroke-width="1" stroke-dasharray="2 4" opacity=".45"/>';
    g += '<text x="' + (x - 8).toFixed(1) + '" y="' + (H - 4) + '" font-size="9" fill="var(--mut2)">' + fk[1] + '</text>';
  });
  var pts = points.map(function (p) { return peqFreqX(p[0]).toFixed(1) + ',' + peqGainY(p[1]).toFixed(1); }).join(' ');

  var svg = box.querySelector('svg.peqsvg');
  if (!svg) {
    box.innerHTML =
      '<svg class=peqsvg viewBox="0 0 ' + W + ' ' + H + '">' +
        '<g class=peqgrid></g>' +
        '<polyline class=peqline fill=none stroke="var(--acc)" stroke-width=1.8 stroke-linejoin=round stroke-linecap=round points=""/>' +
        '<g class=peqnodes></g>' +
      '</svg>' +
      '<div class=peqlegend><span><b>拖拽节点</b> 水平=频率 · 垂直=增益</span><span><b>Shift+拖 / 滚轮</b> 改 Q</span>' +
      '<span><b>双击</b> 该段复位</span><span><b>↑↓←→</b> 微调（Shift 加速）</span></div>' +
      '<div class=peqtip id=peqTip></div>';
    svg = box.querySelector('svg.peqsvg');
    peqBindCurve();
  }
  // R-5：宽度变了就同步 viewBox（不只是首次建 SVG 时写一次），否则缩放后图被拉变形/留白。
  svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
  svg.querySelector('.peqgrid').innerHTML = g;
  svg.querySelector('.peqline').setAttribute('points', pts);
  peqSyncNodes();
  peqObserveWidth();   // 挂上 ResizeObserver（同一容器重复调用是 no-op）
}
/* ---------------- PEQ：行渲染 / 选中 / 曲线节点交互（261024-03 #5） ---------------- */
function peqSelectRow(tr) {
  Array.prototype.forEach.call(peqRowsEl(), function (x) { x.classList.toggle('sel', x === tr); });
}
function peqRowTipText(b) {
  return '<b>' + peqFreqText(b.freq) + '</b> · ' + (b.gain >= 0 ? '+' : '') + b.gain.toFixed(1) +
         ' dB · Q ' + b.q.toFixed(2) + ' · ' + b.type + (b.on ? '' : '（已关）');
}
// tooltip 定位：有事件用鼠标位置；没有（滚轮/键盘）就用节点自身位置
function peqTipAt(html, ev, node) {
  var tip = D('peqTip'), box = D('peqCurve');
  if (!tip || !box) return;
  var br = box.getBoundingClientRect();
  var cx, cy;
  if (ev && typeof ev.clientX === 'number') { cx = ev.clientX; cy = ev.clientY; }
  else if (node) { var nr = node.getBoundingClientRect(); cx = nr.left + nr.width / 2; cy = nr.top + nr.height / 2; }
  else { cx = br.left + br.width / 2; cy = br.top + 20; }
  tip.innerHTML = html;
  tip.classList.add('on');
  var x = Math.max(4, Math.min(cx - br.left + 14, br.width - (tip.offsetWidth || 90) - 4));
  var y = Math.max(4, Math.min(cy - br.top + 8, br.height - (tip.offsetHeight || 24) - 4));
  tip.style.left = x + 'px'; tip.style.top = y + 'px';
}
function peqTipHide() { var t = D('peqTip'); if (t) t.classList.remove('on'); }
function peqResetBand(i) {
  var tr = document.querySelector('#peqRows .peqr[data-i="' + i + '"]'); if (!tr) return;
  tr.querySelector('.peqG').value = '0.0';
  tr.querySelector('.peqQ').value = '1.41';
  peqSyncNodes();
  peqScheduleApply(100);
  peqMsg('第 ' + i + ' 段已复位（0.0 dB / Q 1.41）');
}
function peqSvgPoint(ev) {
  var box = D('peqCurve');
  var svg = box && box.querySelector('svg.peqsvg');
  if (!svg || !PEQ_VIEW) return null;
  var r = svg.getBoundingClientRect();
  if (!r.width || !r.height) return null;
  return { x: (ev.clientX - r.left) / r.width * PEQ_VIEW.W,
           y: (ev.clientY - r.top) / r.height * PEQ_VIEW.H };
}
function peqNodeRow(i) { return document.querySelector('#peqRows .peqr[data-i="' + i + '"]'); }
function peqBindCurve() {
  var box = D('peqCurve'); if (!box) return;
  var svg = box.querySelector('svg.peqsvg'); if (!svg) return;
  var pick = function (ev) {
    var t = ev.target;
    while (t && t !== svg) { if (t.dataset && t.dataset.i) return t; t = t.parentNode; }
    return null;
  };
  svg.addEventListener('pointermove', function (ev) {
    if (PEQ_DRAG) return;
    var node = pick(ev);
    if (node) {
      var tr = peqNodeRow(node.dataset.i);
      if (tr) peqTipAt(peqRowTipText(peqRowBand(tr)), ev);
      return;
    }
    var p = peqSvgPoint(ev); if (!p) return;
    var f = peqCurveFreqAt(p.x), pts = (PEQ_STATE && PEQ_STATE.points) || [], db = null;
    for (var i = 0; i < pts.length; i++) { if (pts[i][0] >= f) { db = pts[i][1]; break; } }
    if (db === null && pts.length) db = pts[pts.length - 1][1];
    peqTipAt('<b>' + peqFreqText(f) + '</b>' + (db === null ? '' : ' · 曲线 ' + (db >= 0 ? '+' : '') + db.toFixed(1) + ' dB'), ev);
  });
  svg.addEventListener('pointerleave', function () { if (!PEQ_DRAG) peqTipHide(); });
  svg.addEventListener('dblclick', function (ev) {
    var node = pick(ev); if (!node) return;
    ev.preventDefault();
    peqResetBand(+node.dataset.i);
  });
  svg.addEventListener('wheel', function (ev) {
    var node = pick(ev); if (!node) return;
    ev.preventDefault();
    var tr = peqNodeRow(node.dataset.i); if (!tr) return;
    var qEl = tr.querySelector('.peqQ'), v = parseFloat(qEl.value) || 1.41;
    v = Math.max(0.1, Math.min(20, v * Math.pow(1.15, ev.deltaY > 0 ? 1 : -1)));
    qEl.value = v.toFixed(2);
    peqSyncNodes();
    peqTipAt(peqRowTipText(peqRowBand(tr)), null, node);
    peqScheduleApply(100);
  }, { passive: false });
  svg.addEventListener('pointerdown', function (ev) {
    var node = pick(ev); if (!node) return;
    ev.preventDefault();
    var i = +node.dataset.i, tr = peqNodeRow(i); if (!tr) return;
    peqSelectRow(tr);
    // 双击 = 该段复位。自己在 pointerdown 里判（350ms 内同一节点），
    // 因为 pointerdown 里 preventDefault + setPointerCapture 会让宿主的 dblclick 时序不可靠。
    var now = Date.now();
    if (PEQ_LASTCLICK && PEQ_LASTCLICK.i === i && now - PEQ_LASTCLICK.t < 350) {
      PEQ_LASTCLICK = null;
      peqResetBand(i);
      PEQ_DRAG = null;
      return;
    }
    PEQ_LASTCLICK = { i: i, t: now };
    PEQ_DRAG = { i: i, mode: ev.shiftKey ? 'q' : 'g', y0: ev.clientY,
                 q0: parseFloat(tr.querySelector('.peqQ').value) || 1.41 };
    try { svg.setPointerCapture(ev.pointerId); } catch (e) { }
    var c = svg.querySelector('.peqnode[data-i="' + i + '"]'); if (c) c.classList.add('on');
  });
  svg.addEventListener('pointermove', function (ev) {
    if (!PEQ_DRAG) return;
    var tr = peqNodeRow(PEQ_DRAG.i); if (!tr) return;
    if (PEQ_DRAG.mode === 'q') {
      var qv = Math.max(0.1, Math.min(20, PEQ_DRAG.q0 * Math.pow(2, (PEQ_DRAG.y0 - ev.clientY) / 60)));
      tr.querySelector('.peqQ').value = qv.toFixed(2);
    } else {
      var p = peqSvgPoint(ev); if (!p) return;
      tr.querySelector('.peqF').value = peqFreqText(peqCurveFreqAt(p.x));
      tr.querySelector('.peqG').value = peqCurveGainAt(p.y).toFixed(1);
    }
    peqSyncNodes();
    var node = svg.querySelector('.peqnode[data-i="' + PEQ_DRAG.i + '"]');
    peqTipAt(peqRowTipText(peqRowBand(tr)), ev, node);
    peqScheduleApply(100);           // 拖拽 100ms 节流
  });
  var endDrag = function () {
    if (!PEQ_DRAG) return;
    var i = PEQ_DRAG.i;
    PEQ_DRAG = null;
    var c = svg.querySelector('.peqnode[data-i="' + i + '"]'); if (c) c.classList.remove('on');
    peqTipHide();
    clearTimeout(PEQ_TIMER); peqApply();   // 松手立刻落一次，不等节流窗口
  };
  svg.addEventListener('pointerup', endDrag);
  svg.addEventListener('pointercancel', endDrag);
}
// 把 20 个节点同步到当前行值（拖拽/键盘/滚轮后立即反映，不等后端）
function peqSyncNodes() {
  var box = D('peqCurve');
  var svg = box && box.querySelector('svg.peqsvg');
  if (!svg || !PEQ_VIEW) return;
  var host = svg.querySelector('.peqnodes'); if (!host) return;
  var bands = peqCollectBands();
  if (!bands.length && PEQ_STATE && PEQ_STATE.bands) bands = PEQ_STATE.bands;
  if (host.querySelectorAll('circle.peqhit').length !== bands.length) {
    var h = '';
    bands.forEach(function (b, i) {
      h += '<circle class=peqhit data-i=' + (i + 1) + ' r=13></circle>'
         + '<circle class="peqnode' + (b.on === false ? ' off' : '') + '" data-i=' + (i + 1) + ' r=4.5></circle>';
    });
    host.innerHTML = h;
  }
  Array.prototype.forEach.call(host.querySelectorAll('circle.peqnode'), function (c) {
    var i = +c.dataset.i - 1, b = bands[i];
    if (!b) return;
    var cx = peqFreqX(b.freq).toFixed(1), cy = peqGainY(b.gain).toFixed(1);
    c.setAttribute('cx', cx); c.setAttribute('cy', cy);
    c.classList.toggle('off', b.on === false);
    var hit = host.querySelector('circle.peqhit[data-i="' + (i + 1) + '"]');
    if (hit) { hit.setAttribute('cx', cx); hit.setAttribute('cy', cy); }
  });
}
function peqRenderRows(j) {
  var box = D('peqRows'); if (!box) return;
  // 表头与数据行同处 #peqRows：同一个内容宽度 ⟹ 同一套列轨道（这是"对齐"的根）
  var h = '<div class=peqhd><span>段</span><span class=num>频率</span><span class=num>增益 dB</span>'
        + '<span class=num>Q</span><span>类型</span><span class=c>启用</span></div>';
  (j.bands || []).forEach(function (b, i) {
    var sel = '<select class=peqT>'
      + '<option value=PK' + (b.type === 'PK' ? ' selected' : '') + '>峰值 PK</option>'
      + '<option value=LS' + (b.type === 'LS' ? ' selected' : '') + '>低架 LS</option>'
      + '<option value=HS' + (b.type === 'HS' ? ' selected' : '') + '>高架 HS</option></select>';
    h += '<div class=peqr data-i=' + (i + 1) + ' tabindex=0>'
       + '<span class=peqn>' + (i + 1 < 10 ? '0' : '') + (i + 1) + '</span>'
       + '<span class=peqc><input class=peqF type=text spellcheck=false value="' + esc(peqFreqText(b.freq)) + '"></span>'
       + '<span class="peqc num"><input class=peqG type=number step=0.1 min=-12 max=12 value="' + (+b.gain).toFixed(1) + '"></span>'
       + '<span class="peqc num"><input class=peqQ type=number step=0.01 min=0.1 max=20 value="' + (+b.q).toFixed(2) + '"></span>'
       + '<span class=peqc>' + sel + '</span>'
       + '<span class="peqc c"><input class=peqOn type=checkbox' + (b.on ? ' checked' : '') + '></span>'
       + '</div>';
  });
  box.innerHTML = h;
  Array.prototype.forEach.call(box.querySelectorAll('.peqr'), function (tr) {
    var inputs = tr.querySelectorAll('input,select');
    Array.prototype.forEach.call(inputs, function (el) {
      el.addEventListener('change', function () { peqScheduleApply(); });
      el.addEventListener('input', function () { peqScheduleApply(); });
      el.addEventListener('focus', function () { peqSelectRow(tr); });
    });
    tr.addEventListener('click', function () { peqSelectRow(tr); });
    tr.addEventListener('focus', function () { peqSelectRow(tr); });
    // 键盘：↑↓ 增益 0.1 dB（Shift 1 dB）/ ←→ 频率 ±1%（Shift ±5%）
    tr.addEventListener('keydown', function (ev) {
      var k = ev.key, g = tr.querySelector('.peqG'), f = tr.querySelector('.peqF');
      var fast = ev.shiftKey;
      if (k === 'ArrowUp' || k === 'ArrowDown') {
        ev.preventDefault();
        var d = (k === 'ArrowUp' ? 1 : -1) * (fast ? 1 : 0.1);
        g.value = (Math.max(-12, Math.min(12, (parseFloat(g.value) || 0) + d))).toFixed(1);
      } else if (k === 'ArrowLeft' || k === 'ArrowRight') {
        if (ev.target !== tr && ev.target.tagName === 'INPUT' && ev.target.type === 'text') return; // 文本输入框里让光标移动
        ev.preventDefault();
        var mul = (k === 'ArrowRight' ? 1 : -1) * (fast ? 0.05 : 0.01);
        var fv = peqParseFreq(f.value) || 1000;
        f.value = peqFreqText(peqClampFreq(fv * (1 + mul)));
      } else return;
      peqSyncNodes();
      peqScheduleApply(100);
    });
  });
  peqSyncNodes();
}
// 自动前级（防削波）：把前级设为 -ceil(曲线峰值)。曲线峰值优先取后端点集（架式/叠加后的真实峰值），
// 没有点集时退回"各段增益最大值"。
function peqAutoPreamp() {
  var maxGain = 0;
  var pts = (PEQ_STATE && PEQ_STATE.points) || [];
  if (pts.length) {
    pts.forEach(function (p) { if (p[1] > maxGain) maxGain = p[1]; });
  } else {
    peqCollectBands().forEach(function (b) { if (b.on && b.gain > maxGain) maxGain = b.gain; });
  }
  var pre = -Math.max(0, Math.ceil(maxGain));
  var inp = D('peqPreamp');
  if (inp) inp.value = pre;
  peqApply();
  peqMsg('自动前级：曲线峰值 +' + maxGain.toFixed(1) + ' dB → 前级 ' + pre + ' dB（留出 ' + Math.abs(pre).toFixed(0) + ' dB 余量）');
  toast('自动前级 ' + pre + ' dB（峰值 +' + maxGain.toFixed(1) + ' dB）');
}
function peqRender(j) {
  PEQ_STATE = j;
  if (D('peqBypass')) D('peqBypass').checked = !!j.bypass;
  if (D('peqPreamp')) D('peqPreamp').value = j.preamp;
  peqStatusRender(j);   // 261024-04 #3：状态行跟着后端的真值走
  var sel = D('peqPreset');
  if (sel) {
    var cur = j.name || 'Flat';
    var h = '';
    (j.presets || []).forEach(function (n) {
      h += '<option value="' + esc(n) + '"' + (n === cur ? ' selected' : '') + '>' + esc(n) + '</option>';
    });
    sel.innerHTML = h;
  }
  peqRenderRows(j);
  peqDrawCurve(j.points);
}
function peqMsg(t) { var e = D('peqMsg'); if (e) e.textContent = t || ''; }
// 261024-04 #3：把「旁路 / 生效」的**语义**写成一行常驻状态，而不是只留一个 checkbox 让用户猜。
// 判据：勾选/取消勾选后这一行文字必须立刻跟着变（不依赖后端往返）。
// 文案分三态：
//   ① 已旁路         → PEQ 完全不算，信号直通；
//   ② 生效但全 0 dB  → 严格说"生效"，但 20 段全 0 dB + 前级 0 dB ⟹ 不改变声音（下载默认就是这一档）；
//   ③ 生效且有非 0 dB 段 → 输出确实被 EQ 改变。
function peqStatusRender(j) {
  var el = D('peqStat'), tx = D('peqStatTxt');
  if (!el || !tx) return;
  j = j || PEQ_STATE || {};
  var bands = j.bands || [];
  var active = 0, total = 0;
  for (var i = 0; i < bands.length; ++i) {
    total++;
    if (bands[i].on && Math.abs(+bands[i].gain || 0) > 0.001) active++;
  }
  var pre = (typeof j.preamp === 'number') ? j.preamp : 0;
  var bypass = !!j.bypass;
  el.className = 'peqstat' + (bypass ? ' bypass' : '');
  var txt;
  if (bypass) {
    txt = 'PEQ 当前：已旁路（PEQ 不生效，信号直通）';
  } else if (active === 0 && Math.abs(pre) < 0.001) {
    txt = 'PEQ 当前：生效 · ' + (total || 20) + ' 段全为 0 dB、前级 0 dB（不改变声音）';
  } else {
    txt = 'PEQ 当前：生效 · ' + active + ' / ' + (total || 20) + ' 段非 0 dB' +
          (Math.abs(pre) >= 0.001 ? ('、前级 ' + pre.toFixed(1) + ' dB') : '') + '（输出已被 EQ 改变）';
  }
  tx.textContent = txt;
  el.title = txt;
}
// 节流：文字输入 260ms；拖拽/滚轮/键盘 100ms（拖拽时不许每次 pointermove 都打后端）
function peqScheduleApply(ms) {
  clearTimeout(PEQ_TIMER);
  PEQ_TIMER = setTimeout(peqApply, ms === undefined ? 260 : ms);
}
function peqApply() {
  var body = 'bypass=' + ((D('peqBypass') && D('peqBypass').checked) ? 1 : 0)
    + '&preamp=' + encodeURIComponent((D('peqPreamp') ? D('peqPreamp').value : 0) || 0)
    + '&bands=' + encodeURIComponent(peqBandsParam());
  peqMsg('应用中…');
  api('/api/peq', body).then(function (j) {
    if (!j || !j.ok) { peqMsg('失败：' + ((j && j.error) || '未知错误')); return; }
    PEQ_STATE = j;
    peqDrawCurve(j.points);   // 只刷新曲线，不重建输入框（避免打断正在输入的光标）
    peqStatusRender(j);       // 261024-04 #3：状态行刷新（以后端返回值为准）
    peqMsg('已应用（' + (j.bypass ? '旁路' : '生效') + ' · 采样率 ' + Math.round(j.fs) + ' Hz）');
  }).catch(function (e) { peqMsg('失败：' + e); });
}
function peqLoadState() {
  return api('/api/peq').then(function (j) {
    if (j && j.ok) peqRender(j);
  }).catch(function () { });
}
function peqPresetAction(action, name) {
  api('/api/peq/preset', 'action=' + encodeURIComponent(action) + '&name=' + encodeURIComponent(name || '')).then(function (j) {
    if (!j || !j.ok) { toast('预设操作失败：' + ((j && j.error) || '未知错误')); return; }
    peqRender(j);
    if (action === 'load') toast('已加载预设：' + name);
    else if (action === 'save') toast('已保存预设：' + name);
    else if (action === 'reset') toast('已重置为 Flat');
    else toast('已删除预设');
  }).catch(function (e) { toast('预设操作失败：' + e); });
}
function initPeqControls() {
  if (!D('peqBypass')) return;   // 当前页面没有 PEQ 卡（例如还没渲染设置页）
  // 261024-04 #3：勾选/取消后状态行**立刻**变（先按本地状态刷，不等后端往返）；再节流下发。
  D('peqBypass').onchange = function () {
    var st = {};
    for (var kk in (PEQ_STATE || {})) st[kk] = PEQ_STATE[kk];
    st.bypass = !!this.checked;
    peqStatusRender(st);
    peqScheduleApply();
  };
  if (D('peqPreamp')) D('peqPreamp').oninput = function () { peqScheduleApply(); };
  if (D('peqAutoPre')) D('peqAutoPre').onclick = peqAutoPreamp;
  if (D('peqLoad')) D('peqLoad').onclick = function () {
    var sel = D('peqPreset'); if (sel) peqPresetAction('load', sel.value);
  };
  if (D('peqSave')) D('peqSave').onclick = function () {
    var n = prompt('预设名（保存到 rlplayer-peq-presets.txt）：', (PEQ_STATE && PEQ_STATE.name) || '我的 PEQ');
    if (n && n.trim()) peqPresetAction('save', n.trim());
  };
  if (D('peqDelete')) D('peqDelete').onclick = function () {
    var sel = D('peqPreset'); if (!sel) return;
    if (confirm('删除用户预设「' + sel.value + '」？（内置预设不能删除）')) peqPresetAction('delete', sel.value);
  };
  if (D('peqReset')) D('peqReset').onclick = function () {
    if (confirm('重置为 Flat（20 段全部 0dB）？')) peqPresetAction('reset', 'Flat');
  };
  peqLoadState();
}

function initEqViewLogic() {
  initPeqControls();
  var sInput = D('sp_opra_search');
  var guide = D('eqSearchGuide');
  var hint = D('sp_opra_searchhint');
  var cardsBox = D('eqModelCards');
  var presetsArea = D('eqPresetsArea');
  var presetsBox = D('eqPresetCards');
  var targetInfo = D('eqTargetCurveInfo');
  var copyChip = D('sp_opra_copychip');
  var selectedTitle = D('eqSelectedModelTitle');
  var msg = D('sp_opra_msg');

  if (copyChip) {
    copyChip.onclick = function () {
      var text = 'https://opra.roon.app/';
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { toast('已复制来源链接: ' + text); });
      } else {
        toast('来源链接: ' + text);
      }
    };
  }

  function doSearch(q) {
    q = (q || '').trim();
    if (!q) {
      // 空输入：型号卡片数 == 0，展示引导与热门芯片（261023-03 第6条）
      cardsBox.innerHTML = '';
      if (guide) guide.style.display = 'block';
      if (hint) hint.style.display = 'none';
      if (presetsArea) presetsArea.style.display = 'none';
      return;
    }

    if (guide) guide.style.display = 'none';

    if (!OPRA_INDEX) {
      if (hint) { hint.textContent = '正在加载耳机数据库…'; hint.style.display = 'block'; }
      loadOpraIndex(function () { if (eqTabActive()) doSearch(q); });   // 切走后丢弃过期回调
      return;
    }

    var tokens = q.toLowerCase().split(/\s+/).filter(Boolean);
    var allHits = [];
    for (var i = 0; i < OPRA_INDEX.length; ++i) {
      var item = OPRA_INDEX[i];
      var str = (item[1] + ' ' + item[2] + ' ' + item[0]).toLowerCase();
      var match = true;
      for (var t = 0; t < tokens.length; ++t) {
        if (str.indexOf(tokens[t]) < 0) { match = false; break; }
      }
      if (match) allHits.push(item);
    }

    // 最多 30 条，带继续输入提示（261023-03 第6条）
    var hits = allHits.slice(0, 30);
    if (hint) {
      if (!allHits.length) {
        hint.textContent = '未找到匹配的耳机型号，请尝试不同关键词';
      } else if (allHits.length > 30) {
        hint.textContent = '共匹配到 ' + allHits.length + ' 款耳机，已显示前 30 条。继续输入更具体关键词以精确筛选…';
      } else {
        hint.textContent = '匹配到 ' + hits.length + ' 款耳机型号';
      }
      hint.style.display = 'block';
    }

    // 渲染型号卡片（品牌 · 型号 · 预设）
    var ch = '';
    hits.forEach(function (it) {
      var id = it[0], vendor = it[1], name = it[2];
      var isCur = (id === ADV.opraproduct);
      // 每项统一显示「品牌 · 型号」（261023-03 第6条：品牌/型号不能是两个互相重叠的搜索框）
      ch += '<div class="model-card card' + (isCur ? ' active' : '') + '" data-id="' + esc(id) + '" data-vendor="' + esc(vendor) + '" data-name="' + esc(name) + '">' +
            '<div style="font-size:13px;font-weight:600;line-height:1.35;color:var(--txt)">' + esc(vendor) + ' · ' + esc(name) + '</div>' +
            '<div style="font-size:11px;color:var(--mut2);margin-top:5px;display:flex;align-items:center;justify-content:space-between">' +
            '<span>OPRA 校准预设</span><span class="badge" style="font-size:10px">查看调音预设</span>' +
            '</div></div>';
    });
    cardsBox.innerHTML = ch;

    // 绑定点击型号卡片
    Array.prototype.forEach.call(cardsBox.querySelectorAll('.model-card'), function (card) {
      card.onclick = function () {
        Array.prototype.forEach.call(cardsBox.querySelectorAll('.model-card'), function (c) { c.classList.remove('active'); });
        card.classList.add('active');
        loadProductPresets(card.dataset.id, card.dataset.vendor, card.dataset.name);
      };
    });
  }

  function loadProductPresets(productId, vendor, name) {
    if (!presetsArea) return;
    presetsArea.style.display = 'block';
    if (selectedTitle) selectedTitle.textContent = vendor + ' ' + name + ' · 调音预设';
    if (msg) msg.textContent = '正在获取预设…';
    if (presetsBox) presetsBox.innerHTML = '<div class=empty style="padding:20px 0">正在加载调音目标曲线…</div>';
    if (targetInfo) targetInfo.style.display = 'none';

    OPRA_CUR_PRODUCT = productId;   // 连点不同型号时，只认最后一次选择（防止慢请求把旧预设盖到新型号上）
    api('/api/opra/presets?productId=' + encodeURIComponent(productId)).then(function (j) {
      if (!eqTabActive() || OPRA_CUR_PRODUCT !== productId) return;   // 切走 / 已换型号 → 丢弃
      if (!j.ok || !j.items || !j.items.length) {
        if (msg) msg.textContent = '暂无可用预设';
        if (presetsBox) presetsBox.innerHTML = '<div class=empty style="padding:20px 0">该型号暂无可用调音预设</div>';
        return;
      }
      var presets = j.items;
      OPRA_PRESETS = presets;
      if (msg) msg.textContent = (j.fromCache ? '已加载本地缓存（' : '共 ') + presets.length + ' 种调音目标）';

      // 渲染卡片式调音预设（至少 3 张卡，261023-03 第7条）
      var ph = '';
      presets.forEach(function (p) {
        var curve = getTargetCurveDesc(p.details, p.author);
        var isActive = (ADV.opraproduct === productId && ADV.oprapreset === p.id);
        ph += '<div class="preset-card card' + (isActive ? ' active' : '') + '" data-id="' + esc(p.id) + '">' +
              '<div>' +
              '<div style="display:flex;align-items:flex-start;justify-content:space-between;gap:8px;margin-bottom:4px">' +
              '<b style="font-size:13.5px;color:var(--txt);line-height:1.35">' + esc((p.author || 'OPRA') + (p.details ? (' · ' + p.details) : '')) + '</b>' +
              '<span class="badge" style="background:var(--hov);white-space:nowrap">' + p.bandsCount + ' 段</span>' +
              '</div>' +
              '<div style="font-size:11px;color:var(--mut2)">目标曲线：' + esc(curve.name) + '</div>' +
              '<div class="tc-curve" title="目标曲线示意（手绘近似，非测量数据）">' + targetCurveSvg(curve.kind) + '</div>' +
              '<div style="font-size:12px;color:var(--txt2);line-height:1.5;margin:8px 0 0;background:var(--card);padding:8px 10px;border-radius:6px;border:1px solid var(--line)">' +
              '说明：' + esc(curve.scene) + '</div>' +
              '<div style="font-size:11.5px;color:var(--mut2);margin-top:8px">前级增益：<b>' + p.gainDb + ' dB</b> · 频段数：<b>' + p.bandsCount + ' 段</b></div>' +
              '</div>' +
              '<div style="margin-top:12px;display:flex;align-items:center;justify-content:space-between;gap:8px">' +
              '<span style="font-size:11px;color:var(--mut2)">点击卡片选中</span>' +
              '<button class="btn pri opra-apply-btn" data-pid="' + esc(productId) + '" data-eid="' + esc(p.id) + '" style="font-size:12px;padding:5px 14px">' +
              (isActive ? '已应用当前预设' : '应用到 EQ') + '</button>' +
              '</div></div>';
      });
      presetsBox.innerHTML = ph;

      // 选中当前或第一个预设展示曲线说明
      var curP = presets.find(function (x) { return x.id === ADV.oprapreset; }) || presets[0];
      if (curP) {
        showTargetCurveInfo(curP);
      }

      // 绑定应用按钮与卡片点击
      Array.prototype.forEach.call(presetsBox.querySelectorAll('.preset-card'), function (pcard) {
        pcard.onclick = function () {
          // 选中高亮（261023-03 第7条）：点卡片只选中/预览；真正写入 EQ 要再点「应用到 EQ」
          Array.prototype.forEach.call(presetsBox.querySelectorAll('.preset-card'), function (c) { c.classList.remove('active'); });
          pcard.classList.add('active');
          var eid = pcard.dataset.id;
          var p = presets.find(function (x) { return x.id === eid; });
          if (p) showTargetCurveInfo(p);
        };
      });

      Array.prototype.forEach.call(presetsBox.querySelectorAll('.opra-apply-btn'), function (btn) {
        btn.onclick = function (ev) {
          ev.stopPropagation();
          var pid = btn.dataset.pid;
          var eid = btn.dataset.eid;
          applyOpraPreset(pid, eid, presets);
        };
      });
    }).catch(function (err) {
      if (msg) msg.textContent = '获取失败: ' + err;
      if (presetsBox) presetsBox.innerHTML = '<div class=empty style="padding:20px 0">网络错误或预设获取失败</div>';
    });
  }

  function showTargetCurveInfo(p) {
    if (!targetInfo) return;
    var curve = getTargetCurveDesc(p.details, p.author);
    targetInfo.innerHTML = '<div style="display:flex;gap:18px;flex-wrap:wrap;align-items:flex-start">' +
      '<div style="flex:1;min-width:260px">' +
      '<div style="font-weight:700;font-size:13px;margin-bottom:6px;color:var(--txt)">' + esc(curve.name) + ' · 目标曲线说明</div>' +
      '<div style="margin-bottom:5px"><b style="color:var(--txt)">是什么：</b>' + esc(curve.tech) + '</div>' +
      '<div><b style="color:var(--txt)">适合谁：</b>' + esc(curve.scene) + '</div>' +
      '</div>' +
      '<div style="flex:0 0 260px;min-width:220px" class="tc-curve">' +
      '<div style="font-size:10.5px;color:var(--mut2);margin-bottom:2px">目标曲线示意（手绘近似）</div>' +
      targetCurveSvg(curve.kind, 78) +
      '</div>' +
      '</div>' +
      '<div style="margin-top:10px;font-size:11.5px;color:var(--mut2);border-top:1px dashed var(--line);padding-top:8px">' +
      '前级增益：' + p.gainDb + ' dB（独立衰减防削波） · 滤波段数：' + p.bandsCount + ' 段 · 预设：' + esc(p.details || p.id) + '</div>';
    targetInfo.style.display = 'block';
  }

  function applyOpraPreset(pid, eid, presets) {
    api('/api/opra/apply', 'productId=' + encodeURIComponent(pid) + '&presetId=' + encodeURIComponent(eid)).then(function (j) {
      if (!j.ok) { toast(j.error || '应用失败'); return; }
      ADV.opraproduct = pid;
      ADV.oprapreset = eid;
      // 后端 /api/opra/apply 返回字段是 path（见 rtaweb.cpp）；eqPath 仅作兼容。
      // 这里以前只认 eqPath，导致「应用成功」但 EQ 文件路径根本没写进去（261023-03 第7条实测抓到）。
      var appliedPath = j.eqPath || j.path;
      if (appliedPath) ADV.eq = appliedPath;
      if (D('sp_eq')) D('sp_eq').value = ADV.eq;
      saveSettings(true);
      toast('已应用调音预设到 EQ');
      Array.prototype.forEach.call(presetsBox.querySelectorAll('.preset-card'), function (c) {
        var isThis = (c.dataset.id === eid);
        c.classList.toggle('active', isThis);
        var b = c.querySelector('.opra-apply-btn');
        if (b) b.textContent = isThis ? '已应用当前预设' : '应用到 EQ';
      });
      var p = presets.find(function (x) { return x.id === eid; });
      if (p) showTargetCurveInfo(p);
    });
  }

  // 搜索框事件
  if (sInput) {
    sInput.oninput = function () { doSearch(this.value); };
    sInput.onkeydown = function (ev) { if (ev.key === 'Enter') doSearch(this.value); };
  }

  // 热门品牌芯片点击
  if (guide) {
    Array.prototype.forEach.call(guide.querySelectorAll('.brand-chip'), function (btn) {
      btn.onclick = function () {
        var b = btn.dataset.brand;
        if (sInput) {
          sInput.value = b;
          doSearch(b);
        }
      };
    });
  }

  // 房间校正保存按钮
  if (D('bSaveRoomEq')) {
    D('bSaveRoomEq').onclick = function () {
      if (D('sp_eq')) ADV.eq = (D('sp_eq').value || '').trim();
      if (D('sp_ir')) ADV.ir = (D('sp_ir').value || '').trim();
      if (D('sp_irgpu')) ADV.irgpu = D('sp_irgpu').checked ? 1 : 0;
      saveSettings(true);
      toast('已保存房间校正设置');
    };
  }

  // 初始：有已选型号 → 回填「品牌 型号」并加载预设；否则保持空输入（0 张型号卡片）。
  // 空输入时这里**不发起任何 /api/opra/index 请求**（261023-03 第6条）。
  if (ADV.opraproduct) {
    loadOpraIndex(function () {
      if (!eqTabActive()) return;
      var it = null;
      for (var i = 0; i < (OPRA_INDEX || []).length; ++i) {
        if (OPRA_INDEX[i][0] === ADV.opraproduct) { it = OPRA_INDEX[i]; break; }
      }
      if (it) {
        sInput.value = it[1] + ' ' + it[2];
        doSearch(sInput.value);
        loadProductPresets(it[0], it[1], it[2]);
      }
    });
  } else {
    doSearch('');
  }
}

// 2026-10-23 用户 261023-04 #2：EQ 已并入设置页，不再需要「前往 EQ 页面」跳转按钮的绑定。
// ============================================================================
// 诊断导出（用户 2026-10-22 功能3）
// ----------------------------------------------------------------------------
// 用户原话：「'导出诊断信息'其实就是一个 log，最好是直接导出一个压缩包或一个整体的
// 文件，不要用户单独找 rlplayer-diag.json / rlplayer-playback.log、launcher.log
// 三份文件；另外这个选项放在元数据这里明显不合适，单独出来做选项卡吧，
// 我们还在开发，报错是必不可少的。」
//
// 落点：
//   * 独立「诊断」页签（不塞在元数据组里）—— 见 renderSettingsPage 的 data-g=diag；
//   * 主按钮「导出诊断包（.zip）」→ GET /api/diagzip，服务端打成【一个 ZIP】；
//   * 次按钮「只要 JSON」→ 保留 /api/diag，方便有人只想贴一段文本。
//
// 打包为什么在服务端做（选型理由，别改回去）：
//   ✗ 不调 PowerShell Compress-Archive —— 这是分发给用户的程序，用户机器上不保证有
//     pwsh/powershell（精简系统 / Server Core / 组策略禁用都可能没有）。把功能建在
//     "用户机器恰好有个 shell" 上，等于埋一个只在别人机器上炸的雷。
//   ✗ 不引 JSZip 之类第三方库 —— 项目至今零压缩依赖，还要过分发兼容门禁。
//   ✓ 服务端自己写 STORE（不压缩）ZIP：几十行，见 src/net/zipstore.h。
//     诊断包本来就是几 KB~几 MB 的文本，不压缩的代价可以忽略。
// ============================================================================
function downloadBlob(blob, filename) {
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
}
function diagStamp() {
  var d = new Date();
  function p2(n) { return (n < 10 ? '0' : '') + n; }
  return d.getFullYear() + p2(d.getMonth() + 1) + p2(d.getDate()) + '-' +
         p2(d.getHours()) + p2(d.getMinutes()) + p2(d.getSeconds());
}
function diagMsg(m) { var e = D('sp_diagmsg'); if (e) e.textContent = m || ''; }

function exportDiagZip() {
  var btn = D('sp_diagzip');
  if (btn) btn.disabled = true;
  diagMsg('正在打包…');
  fetch('/api/diagzip').then(function (r) {
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return r.blob();
  }).then(function (blob) {
    // 必须校验是 ZIP（PK 03 04）：服务端没有这个端点时会回 JSON 兜底报文，
    // 那样下到的是坏包 —— 宁可不给，也不假装成功（铁律 4）。
    if (blob.size < 22) throw new Error('包太小');
    return blob.slice(0, 4).arrayBuffer().then(function (b) {
      var v = new Uint8Array(b);
      if (!(v[0] === 0x50 && v[1] === 0x4B && v[2] === 0x03 && v[3] === 0x04)) throw new Error('不是 ZIP');
      var name = 'rlplayer-diag-' + diagStamp() + '.zip';
      downloadBlob(blob, name);
      diagMsg('已导出 ' + name + '（' + Math.round(blob.size / 1024) + ' KB）');
      toast('诊断包已导出：' + name);
    });
  }).catch(function (e) {
    diagMsg('');
    toast('诊断包导出失败：' + (e && e.message ? e.message : e));
  }).then(function () { if (btn) btn.disabled = false; });
}

// 只要 JSON：有人只想贴一段文本给开发者时更方便，所以保留这条路径。
// 「端点不存在」有两种形态都要兜住：真 404，以及本后端对未知 API 的
// 「HTTP 200 + {"ok":false,"error":"not found"}」（rtaweb 的统一兜底）。
function exportDiag() {
  fetch('/api/diag').then(function (r) {
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return r.text();
  }).then(function (t) {
    var noDiag = false;
    try { if (JSON.parse(t).ok === false) noDiag = true; } catch (e) { }
    if (noDiag) throw new Error('diag not available');
    var name = 'rlplayer-diag-' + diagStamp() + '.json';
    downloadBlob(new Blob([t], { type: 'application/json' }), name);
    diagMsg('已导出 ' + name);
    toast('诊断 JSON 已导出');
  }).catch(function () {
    diagMsg('');
    toast('诊断端点不可用（/api/diag 未响应）');
  });
}

// ============================================================================
// 2026-10-26（用户要求：「诊断页的诊断也预留好上传诊断的接口」）
//
// 契约（后端按这个实现就能直接用，页面侧不用再改）：
//   POST /api/diag/upload
//   Content-Type: application/zip
//   Body: 与 /api/diagzip 产出完全相同的 ZIP 字节（含已脱敏的日志与系统信息）
//   成功: 200 + {"ok":true,"id":"<工单号>","url":"<可选查看地址>"}
//   失败: 非 2xx，或 {"ok":false,"error":"..."}
//
// 三条硬约束（都是踩过的坑，不是洁癖）：
//   ① **复用** /api/diagzip 的产物上传，不另造一份打包逻辑
//      ⟹ 上传的与导出的永远是同一份内容，不会出现"导出的没问题、上传的漏了脱敏"。
//   ② 端点没接上时必须如实报错，**绝不假装修好了**。
//      注意本后端对未知 API 的兜底是「HTTP 200 + {"ok":false,"error":"not found"}」，
//      所以不能只看 r.ok，还要看 body 里的 ok 字段（与 exportDiag 同一处理）。
//   ③ 上传前确认 ZIP 头（PK\x03\x04）—— 与 exportDiagZip 同一判据，
//      防止把兜底 JSON 当诊断包发上去，让服务端收到垃圾。
// ============================================================================
function uploadDiag() {
  var btn = D('sp_diagupload');
  if (btn) btn.disabled = true;
  diagMsg('正在准备诊断包…');
  fetch('/api/diagzip').then(function (r) {
    if (!r.ok) throw new Error('打包失败 HTTP ' + r.status);
    return r.blob();
  }).then(function (blob) {
    if (blob.size < 22) throw new Error('包太小');
    return blob.slice(0, 4).arrayBuffer().then(function (b) {
      var v = new Uint8Array(b);
      if (!(v[0] === 0x50 && v[1] === 0x4B && v[2] === 0x03 && v[3] === 0x04)) throw new Error('不是 ZIP');
      diagMsg('正在上传（' + Math.round(blob.size / 1024) + ' KB）…');
      return fetch('/api/diag/upload', {
        method: 'POST',
        headers: { 'Content-Type': 'application/zip' },
        body: blob
      });
    });
  }).then(function (r) {
    // 200 也可能是兜底报文（本后端未知 API 的行为），所以必须读 body 确认
    return r.text().then(function (t) {
      var j = null;
      try { j = JSON.parse(t); } catch (e) { }
      if (!r.ok) throw new Error('HTTP ' + r.status + (j && j.error ? '：' + j.error : ''));
      if (!j || j.ok === false) {
        throw new Error((j && j.error) ? j.error : '端点未接上（/api/diag/upload 未实现）');
      }
      // ⚠️ 2026-10-26 实测踩到的坑（这条是"假成功"，比报错更危险）：
      //   后端对未知 API 的兜底是前缀匹配 —— POST /api/diag/upload 命中了
      //   `/api/diag` 的 rfind(prefix,0)==0 分支，**直接回了一份诊断 JSON 且 ok:true**。
      //   于是"上传"看起来成功了，其实什么都没上传。
      //   判据：上传成功的响应必须带**工单号 id**（契约见函数头）。
      //   没有 id 就说明拿到的不是上传端点的响应（多半是被 /api/diag 吃掉），必须报错。
      if (!j.id) {
        throw new Error('端点未接上（POST /api/diag/upload 未实现；'
          + '当前请求被 /api/diag 前缀匹配吃掉了，服务器回的是诊断 JSON 而不是上传结果）');
      }
      return j;
    });
  }).then(function (j) {
    var id = j && j.id ? String(j.id) : '';
    diagMsg(id ? ('已上传，工单号 ' + id) : '已上传');
    toast(id ? ('诊断包已上传，工单号 ' + id) : '诊断包已上传');
  }).catch(function (e) {
    // 如实说不支持，不假装成功
    diagMsg('');
    toast('诊断包上传失败：' + (e && e.message ? e.message : e));
  }).then(function () { if (btn) btn.disabled = false; });
}

function drawRoots() {
  var box = D('sp_roots'); if (!box) return;
  var h = '';
  (S.roots || []).forEach(function (r) {
    h += '<div class=rootline><span title="' + esc(r) + '">' + esc(r) + '</span><button data-r="' + esc(r) + '">\u00d7</button></div>';
  });
  box.innerHTML = h || '<div style="font-size:11.5px;color:var(--mut2)">还没有添加目录</div>';
  Array.prototype.forEach.call(box.querySelectorAll('button'), function (b) {
    b.onclick = function () {
      api('/api/lib/roots', 'remove=' + encodeURIComponent(b.dataset.r)).then(function (j) {
        if (j && j.ok === false) { toast(j.error || '移除失败'); return; }
        // 反馈 #3：后端会连带清掉该目录下的曲目，这里必须把结果如实说出来 +
        // 立刻重画当前视图（否则歌还挂在界面上，看起来像没移除成功）。
        var n = (j && typeof j.removedTracks === 'number') ? j.removedTracks : 0;
        libChanged();
        toast(n > 0 ? ('已移除，清理 ' + n + ' 首') : '已移除');
        refreshCurrentView();
        loadLibStats();
      });
    };
  });
}

// 把设置页/快捷面板的值统一写回并保存
function collectSettings() {
  ADV.bits = (function(){ var v = parseInt(D('sp_bits').value, 10); return isNaN(v) ? 0 : v; })();
  ADV.taps = parseInt(D('sp_taps').value, 10) || 0;
  ADV.atten = parseFloat(D('sp_atten').value) || 0;
  ADV.transition = parseFloat(D('sp_transition').value) || 0;
  ADV.phase = D('sp_phase').value || '';
  ADV.modorder = parseInt(D('sp_modorder').value, 10) || 5;
  ADV.modcut = parseFloat(D('sp_modcut').value) || 0;
  ADV.moddith = (D('sp_moddith').value === '') ? -1 : parseFloat(D('sp_moddith').value);
  if (D('sp_eq')) ADV.eq = (D('sp_eq').value || '').trim();
  if (D('sp_ir')) ADV.ir = (D('sp_ir').value || '').trim();
  if (D('sp_irgpu')) ADV.irgpu = D('sp_irgpu').checked ? 1 : 0;
  ADV.ramp = parseFloat(D('sp_ramp').value) || 0;
  ADV.gpuvendor = (D('sp_gpu') && D('sp_gpu').value) || 'auto';
  ensureGpuOption(ADV.gpuvendor);
  if (D('sGpu')) D('sGpu').value = ADV.gpuvendor;
  // 输出后端 / 声道 / 每声道微调
  if (D('sp_backend')) ADV.backend = D('sp_backend').value || 'wasapi';
  if (D('sp_hogexcl')) ADV.hogExclusive = D('sp_hogexcl').checked ? 1 : 0;
  // 261024-01 #11：NAA 端点优先取自动发现的下拉；手动框（折叠兜底）有值则以它为准
  if (D('sp_naa_dev') && D('sp_naa_dev').value) ADV.naaHost = D('sp_naa_dev').value;
  if (D('sp_naahost') && (D('sp_naahost').value || '').trim()) ADV.naaHost = (D('sp_naahost').value || '').trim();
  // 261024-01 #9：UPnP 目标渲染器（与「投放」区块同一下拉选择）
  if (D('sp_upnp_dev') && D('sp_upnp_dev').value) ADV.upnpDev = D('sp_upnp_dev').value;
  if (D('sp_ch')) ADV.channels = parseInt(D('sp_ch').value, 10) || 0;
  [0, 1, 2, 3, 4, 5, 6, 7].forEach(function (i) {
    var e = D('sp_trim' + i);
    if (e) ADV['trim' + i] = parseFloat(e.value) || 0;
  });
  if (D('sp_sdmo1')) ADV.sdmFilt = D('sp_sdmo1').value || '';
  if (D('sp_sdmoNx')) ADV.sdmFiltNx = D('sp_sdmoNx').value || '';
  if (D('sp_directsdm')) ADV.directsdm = D('sp_directsdm').checked ? 1 : 0;
  if (D('sp_dsdkind')) ADV.dsdKind = D('sp_dsdkind').value || 'fir';
  if (D('sp_dsdconv')) ADV.dsdConv = D('sp_dsdconv').value || 'narrow';
  applyDsd();
  if (D('sp_inbackend')) ADV.inBackend = D('sp_inbackend').value || 'none';
  if (D('sp_indev')) ADV.inDev = D('sp_indev').value || '';
  if (D('sp_inch')) ADV.inOffset = parseInt(D('sp_inch').value, 10) || 0;
  if (D('sp_inbuf')) ADV.inBuf = parseInt(D('sp_inbuf').value, 10) || 100;
  if (D('sp_inmon')) ADV.inMonitor = D('sp_inmon').checked ? 1 : 0;
  if (D('sp_inseconds')) ADV.inSeconds = parseFloat(D('sp_inseconds').value) || 0;
  if (D('sp_inout')) ADV.inOut = (D('sp_inout').value || '').trim();
  if (D('sp_updbeta')) ADV.updbeta = D('sp_updbeta').checked ? 1 : 0;
  // 同步回快捷面板

  D('sRate').value = D('sp_rate').value;
  D('sFilt').value = D('sp_filt').value;
  D('sFiltNx').value = D('sp_filtNx').value;
  D('sShap').value = D('sp_shaper').value;
  D('sBuf').value = D('sp_buffer').value;
  D('sIsp').checked = D('sp_isp').checked;
  D('s2s').checked = D('sp_2s').checked;
  D('sRep').value = D('sp_rep').value;
  D('sShuf').checked = D('sp_shuf').checked;
  D('sLoud').checked = D('sp_loud').checked;
  S.loud = D('sLoud').checked;
  // 行为类参数立即下发
  api('/api/playmode?mode=' + D('sRep').value, '');
  applyRep(D('sRep').value);
  // The shuffle checkbox is a projection, never a second competing write.
  D('sShuf').checked = String(D('sRep').value) === '3';
}

function applySettings() {
  collectSettings();
  saveSettings(true);
  // 顺带把音乐库目录那一栏的输入也处理掉
  var extra = (D('sp_root') && D('sp_root').value.trim()) ? ('&rootpending=1') : '';
  toast('设置已保存' + extra);
}

/* ---------------- 键盘快捷键 ---------------- */
document.addEventListener('keydown', function (e) {
  if ((e.ctrlKey || e.metaKey) && (e.key === 'f' || e.key === 'F')) {
    e.preventDefault();
    var q = D('q');
    if (q) { q.focus(); q.select(); }
    return;
  }
  var t = e.target || {};
  if (t.tagName === 'INPUT' || t.tagName === 'SELECT' || t.tagName === 'TEXTAREA') {
    if (e.key === 'Escape' && t.id === 'q') {
      t.blur();
    }
    return;
  }
  if (e.key === ' ') { e.preventDefault(); D('bPause').click(); }
  else if (e.key === 'ArrowRight') {
    e.preventDefault();
    if (e.shiftKey) seekRel(5);
    else D('bNext').click();
  }
  else if (e.key === 'ArrowLeft') {
    e.preventDefault();
    if (e.shiftKey) seekRel(-5);
    else D('bPrev').click();
  }
  // 音量 ↑↓：**按滑块位置**步进，不是按 dB 加减。
  // 为什么改（2026-10-25 v3 配套）：曲线在低端是幂次的，dB 加减 1 在位置 1000 附近几乎不动
  // （−1 dB 只退 5 格），在底部却会一步跨过整个静音档；更致命的是 S.vol 到了 −120（静音）后
  // `Math.max(-60, S.vol - 1)` 会把它钉死在 −60 ⟹ volNormalize 再收回 −120 ⟹ **音量键永久失灵**。
  // 改成位置步进后：静音态按 ↑ 从位置 0 走到 25（≈ −49 dB，能听见），方向对称、可逆。
  else if (e.key === 'ArrowUp') { e.preventDefault(); setVol(volPosToDb(volDbToPos(S.vol) + 25)); }
  else if (e.key === 'ArrowDown') { e.preventDefault(); setVol(volPosToDb(volDbToPos(S.vol) - 25)); }
  else if (e.key === 'n') D('bNext').click();
  else if (e.key === 'p') D('bPrev').click();
  else if (e.key === 's') D('bStop').click();
  else if (e.key === 'l') D('bLyric').click();
  // Esc：层级返回（抽屉 -> 单曲页 -> 弹窗 -> 设置页 -> 专辑/艺术家详情页）与返回按钮行为一致
  else if (e.key === 'Escape') {
    if (D('npPage') && D('npPage').classList.contains('on')) {
      if (typeof npDrawerIsOpen === 'function' && npDrawerIsOpen()) {
        npDrawerClose(); npDataRenderBody();
      } else {
        closeNowPlaying();
      }
    } else if (D('modal') && D('modal').classList.contains('on')) {
      D('modal').classList.remove('on');
    } else if (D('setpage') && D('setpage').classList.contains('on')) {
      setView('albums');
    } else if (S.view === 'album') {
      loadAlbums('');
    } else if (S.view === 'artist') {
      loadArtists();
    } else if (S.view === 'works') {
      if (S.worksFrom === 'np' || (D('wBackNp') && S.lastCur)) openNowPlaying();
      else loadAlbums('');
    }
  }
  else if (e.key === 'i') showChain();
});

/* ---------------- 队列排序（Q-8） ---------------- */
function queueItemLine(items, cues, i) {
  var f = items[i] || '';
  var c = (cues && cues[i]) || [-1, -1];
  return (c && c[0] >= 0) ? (f + '\t' + c[0] + '\t' + c[1]) : f;
}
function applyQueueSort(by) {
  if (!by) return;
  if (by === 'default') {
    api('/api/qsort?by=default', '').then(function (j) {
      if (j && j.ok === false) { toast(j.error || '没有可恢复的排序'); S.queueSort = ''; renderQueuePage(); return; }
      S.queueSort = '';
      toast('已恢复默认顺序');
      renderQueuePage(); loadQ();
    }).catch(function () { renderQueuePage(); });
    return;
  }
  api('/api/queue?meta=1').then(function (q) {
    var items = q.items || [], cues = q.cues || [], metas = q.metas || [];
    var n = items.length;
    if (!n) { toast('队列是空的'); return; }
    var idx = [];
    for (var i = 0; i < n; i++) idx.push(i);
    function meta(i) { return metas[i] || {}; }
    function txt(i, k) { return String(meta(i)[k] || ''); }
    if (by === 'title') {
      idx.sort(function (a, b) { return txt(a, 't').localeCompare(txt(b, 't'), 'zh'); });
    } else if (by === 'artist') {
      idx.sort(function (a, b) { return txt(a, 'a').localeCompare(txt(b, 'a'), 'zh'); });
    } else if (by === 'album') {
      idx.sort(function (a, b) { return txt(a, 'al').localeCompare(txt(b, 'al'), 'zh'); });
    } else if (by === 'dur') {
      idx.sort(function (a, b) { return (+meta(a).d || 0) - (+meta(b).d || 0); });
    } else if (by === 'year') {
      idx.sort(function (a, b) { return (+meta(b).y || 0) - (+meta(a).y || 0); });
    } else if (by === 'shuffle') {
      for (var k = n - 1; k > 0; k--) {
        var r = Math.floor(Math.random() * (k + 1));
        var t = idx[k]; idx[k] = idx[r]; idx[r] = t;
      }
    } else if (by === 'reverse') {
      idx.reverse();
    }
    var lines = idx.map(function (i) { return queueItemLine(items, cues, i); });
    return api('/api/qorder', 'files=' + encodeURIComponent(lines.join('\n'))).then(function (j) {
      if (j && j.ok === false) { toast(j.error || '排序失败'); renderQueuePage(); return; }
      S.queueSort = by;
      renderQueuePage(); loadQ();
    });
  }).catch(function () { renderQueuePage(); });
}

/* ---------------- 播放队列（主视图） ---------------- */
function renderQueuePage() {
  S.view = 'queue';
  // 2026-10-23（自检暴露）：标题原来只在 /api/queue 回来后才写 → 本地接口虽快，但慢的时候
  // 会出现"已经在队列页、标题还是上一页"的空窗。先同步写标题，再等数据补数量/按钮。
  head('播放队列', '', '');
  api('/api/queue?meta=1').then(function (j) {
    if (S.view !== 'queue') return;   // 已切走 → 丢弃，别覆写当前页面
    // 兜底对象没有 items：原地不动（否则队列页会显示"队列是空的"，看起来像被清空了）。
    if (j && j._err) { listErrorBox('队列读取失败', renderQueuePage); return; }
    S.q = { items: j.items || [], cues: j.cues || [], metas: j.metas || [], index: j.index || 0 };
    var n = S.q.items.length;
    head('播放队列', n ? (n + ' 首') : '',
      (n ? '<button class="btn pri" id=qSaveSq title="把当前队列原样存成一个歌单（含顺序与 CUE 区间，重启后仍在）">保存为歌单</button>' : '') +
      (n ? '<button class=btn id=qClrAll>清空队列</button>' : ''));
    if (!n) {
      D('list').innerHTML = '<div class=empty>队列是空的<br><span style="font-size:11.5px">把文件拖进窗口，或右键专辑/曲目「加入队列」</span></div>';
      return;
    }
    var qs = S.queueSort || 'default';
    var h = '<div class="qsortbar" style="display:flex;justify-content:flex-end;align-items:center;padding:10px 20px 4px;gap:8px">' +
            '<span style="font-size:12px;color:var(--mut2)">排序：</span>' +
            '<select id=qSort class="track-sort sort-select" title="只改变队列顺序，不改变正在播放的那一首">' +
            '<option value=default' + (qs === 'default' ? ' selected' : '') + '>默认顺序</option>' +
            '<option value=title' + (qs === 'title' ? ' selected' : '') + '>标题</option>' +
            '<option value=artist' + (qs === 'artist' ? ' selected' : '') + '>艺术家</option>' +
            '<option value=album' + (qs === 'album' ? ' selected' : '') + '>专辑</option>' +
            '<option value=dur' + (qs === 'dur' ? ' selected' : '') + '>时长</option>' +
            '<option value=year' + (qs === 'year' ? ' selected' : '') + '>年份</option>' +
            '<option value=shuffle' + (qs === 'shuffle' ? ' selected' : '') + '>随机打乱</option>' +
            '<option value=reverse' + (qs === 'reverse' ? ' selected' : '') + '>反转顺序</option>' +
            '</select></div>';
    h += '<div class=qlist2>';
    S.q.items.forEach(function (f, i) {
      h += '<div class="qrow' + (i === S.q.index ? ' on' : '') + '" data-i=' + i + ' draggable=true>' +
           '<span class=qn>' + (i + 1) + '</span>' +
           '<span class=qt title="' + esc(f) + '">' + esc(nam(f)) + '</span>' +
           // 评审 #8：以前这里打完整物理路径，又长又不可读；只显示所在文件夹名，全路径放 tooltip
           '<span class=qp title="' + esc(f) + '">' + esc(parentFolder(f)) + '</span>' +
           '<button class=qdel data-i=' + i + ' title="从队列移除">\u00d7</button></div>';
    });
    D('list').innerHTML = h + '</div>';
    Array.prototype.forEach.call(D('list').querySelectorAll('.qrow'), function (e) {
      var i = +e.dataset.i;
      e.onclick = function (ev) {
        if (ev.target.classList.contains('qdel')) return;
        var c = (S.q.cues || [])[i] || [-1, -1];
        playPath(S.q.items[i], c[0], c[1]);
      };
      e.ondragstart = function (ev) { ev.dataTransfer.setData('text/plain', String(i)); ev.dataTransfer.effectAllowed = 'move'; };
      e.ondragover = function (ev) { ev.preventDefault(); ev.dataTransfer.dropEffect = 'move'; };
      e.ondrop = function (ev) {
        ev.preventDefault(); ev.stopPropagation();
        var from = parseInt(ev.dataTransfer.getData('text/plain'), 10);
        if (isNaN(from) || from === i) return;
        api('/api/qmove?from=' + from + '&to=' + i, '').then(function () { renderQueuePage(); loadQ(); });
      };
      var d = e.querySelector('.qdel');
      if (d) d.onclick = function (ev) {
        ev.stopPropagation();
        api('/api/qdel?i=' + i, '').then(function () { toast('已移除'); renderQueuePage(); loadQ(); });
      };
      e.oncontextmenu = function (ev) {
        ev.preventDefault();
        ev.stopPropagation();
        showQueueRowMenu(i, ev);
      };
    });
    if (D('qSort')) D('qSort').onchange = function () { applyQueueSort(this.value); };
    if (D('qSaveSq')) D('qSaveSq').onclick = function () { saveQueueDialog(); };
    if (D('qClrAll')) D('qClrAll').onclick = function () {
      api('/api/clear', '').then(function () { toast('队列已清空'); renderQueuePage(); loadQ(); });
    };
  }).catch(function () { });
}

/* ---------------- 正在播放整页 ---------------- */
function openNowPlaying() {
  var pg = D('npPage'); if (!pg) return;
  pg.classList.add('on');
  // 每次都刷新：上一首的 LY 可能还在；而且内嵌歌词是异步加载的，
  // 只更新 #lyricbox 不会刷新整页的 #npLyric（用户反馈"整页没有歌词"）。
  if (S.lastCur) {
    loadLyrics(S.lastCur);
    if (!S.curMeta) loadMeta(S.lastCur);
  }
  renderNp();
  // 261024-04 #7：进入单曲页立刻自动加载这首歌的 AI 整理（不必等 400ms 的 renderNp 轮询）
  npAutoSummary();
  // 整页控件是底栏/设置页的镜像：进来时刷一次，绝不显示与底栏不同的值
  applyRep(D('sRep') ? D('sRep').value : 0);
  syncVolUi();
  pollCastState(true);   // 261024-02 #5：进来就取一次投放状态（按钮文案/高亮由 applyCastUi 统一刷）
}
function closeNowPlaying() { var pg = D('npPage'); if (pg) pg.classList.remove('on'); }

/* ---------------- 单曲页「资料」面板（用户 261023-04 #7/#9） ----------------
   数据：GET /api/entity/summary?kind=track|release|person&name=..&artist=..&lang=zh
     - 未命中时后端返回 {pending:true}，用 fetchSummary 的 2s 轮询等结果；
     - 命中：{ok:true, sections, citations, summaryKind, summaryCached, unverified?}
   行为（费用纪律）：
     - 打开单曲页自动加载「专辑 + 艺术家」（有缓存则秒回，不闪加载行）；
     - 「歌曲」只在首次切到该 tab 时请求（按曲目缓存，不随每首歌自动烧钱）；
     - 「作品」只在判定为古典时出现，走 /api/entity/versions（Discogs 版本推荐），
       并提供进入「古典作品」整页的入口（左导航已按 #9 移除）。
   状态机：idle → loading（骨架）→ ok / error；切歌/关页丢弃过期回调。 */
var NP_DATA = { key: '', active: '', tabs: [], cache: {}, inflight: {}, req: 0, bodyKey: '', tabSig: '' };

function npFileName(p) {
  var s = String(p || '').replace(/\\/g, '/');
  var i = s.lastIndexOf('/');
  return i >= 0 ? s.slice(i + 1) : s;
}
function npPlayingKindText(m) {
  var t = '正在播放';
  if (!m) return t;
  var b = [];
  if (m.codec) b.push(String(m.codec).toUpperCase());
  if (m.sampleRate) b.push((m.sampleRate / 1000).toFixed(m.sampleRate % 1000 ? 1 : 0) + ' kHz');
  if (m.bits) b.push(m.bits + ' bit');
  return t + (b.length ? '  ·  ' + b.join(' / ') : '');
}
// 古典判定：后端若回 composer 字段则直接算；否则用 genre/专辑名/曲名特征兜底。
// 只有特征命中才出现「作品」tab，避免给流行专辑无端加一个会发 Discogs 请求的入口。
function npIsClassical(m) {
  if (!m) return false;
  if (m.composer && String(m.composer).trim()) return true;
  var g = String(m.genre || ''), a = String(m.album || ''), t = String(m.title || '');
  if (/classical|古典|classique|baroque|巴洛克|opera|オペラ/i.test(g)) return true;
  if (/古典/.test(a)) return true;
  var s = a + ' ' + t;
  return /(symphon|concerto|sonata|caprice|capriccio|nocturne|prelude|overture|string quartet|requiem|mass in|opus\s*\d|op\.\s*\d+|kv\.?\s*\d+|bwv\s*\d+|symphonie|konzert|奏鸣曲|交响|协奏|练习曲|夜曲|前奏曲|序曲|组曲|安魂曲|作品\s*\d+)/i.test(s);
}
// 作曲家猜测（后端暂未回 composer 时的兜底）：曲名末尾括号（(Tchaikovsky)）、
// 专辑名冒号前缀（Paganini: ...）。猜不到就留空（/api/entity/versions 的 composer 是可选的）。
function npGuessComposer(m) {
  if (!m) return '';
  if (m.composer) return String(m.composer);
  var a = String(m.album || ''), t = String(m.title || '');
  var pm = t.match(/\(([A-Z][A-Za-z\u00c0-\u024f.' -]{2,40})\)\s*$/);
  if (pm) return pm[1].trim();
  var i = a.indexOf(':');
  if (i > 1) {
    var pre = a.slice(0, i).trim();
    if (pre && pre.split(/\s+/).length <= 3 && /^[A-Za-z\u00c0-\u024f.' -]+$/.test(pre)) return pre;
  }
  return '';
}
function npWorkTarget(m) {
  if (!m) return { title: '', composer: '' };
  var t = String(m.title || '');
  // 在线补全有时把曲名改写成「原文 (中文译名)」。Discogs 检索要用**原文**：
  // 去掉末尾带 CJK 的括号译名（否则 composer 猜对也搜不到版本，实测 1024 那次就 0 条）。
  var mm = t.match(/^(.*?)\s*[（(]([^()（）]*)[）)]\s*$/);
  if (mm && mm[1] && /[\u4e00-\u9fff]/.test(mm[2])) t = mm[1].trim();
  return { title: t, composer: npGuessComposer(m) };
}
// 当前 EQ / IR 芯片（用户 261023-04 #4）：读 /api/settings 的 eq/ir（loadSettings 填进 ADV），
// 有值才出现；点击跳「EQ 与房间校正」页；tooltip 显示当前文件。
function npEqChipsHtml() {
  var h = '';
  var eq = ADV.eq || '', ir = ADV.ir || '';
  if (eq) {
    h += '<button class=chip id=npEqChip title="' + esc('当前 EQ：' + npFileName(eq) + '（点击打开 EQ 与房间校正）') + '">' +
         '<svg width=11 height=11 viewBox="0 0 24 24" fill=none stroke=currentColor stroke-width=2 style="vertical-align:-1px"><path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/></svg>EQ</button>';
  }
  if (ir) {
    h += '<button class=chip id=npIrChip title="' + esc('当前 IR：' + npFileName(ir) + '（点击打开 EQ 与房间校正）') + '">' +
         '<svg width=11 height=11 viewBox="0 0 24 24" fill=none stroke=currentColor stroke-width=2 style="vertical-align:-1px"><path d="M3 12h3l2-6 3 12 2-8 2 4h6"/></svg>IR</button>';
  }
  return h;
}
function npBindEqChips() {
  var eq = D('npEqChip'), ir = D('npIrChip');
  if (eq) eq.onclick = function () { closeNowPlaying(); openSettingsTab('eq'); };
  if (ir) ir.onclick = function () { closeNowPlaying(); openSettingsTab('eq'); };
}
function npDataReset() {
  NP_DATA = { key: '', active: '', tabs: [], cache: {}, inflight: {}, req: 0, bodyKey: '', tabSig: '' };
  var b = D('npDataBody'); if (b) b.innerHTML = '';
  var t = D('npTabs'); if (t) t.innerHTML = '';
  var s = D('npDataStat'); if (s) s.textContent = '';
  NPPREF.key = '';    // 切歌：允许下一首重新预取（旧请求的结果由 key 守卫丢弃）
  npDrawerClose();
}
// 抽屉开关（#3b ③）：资料默认不占版面，点标签才从右侧滑出
// 抽屉底边动态让出控制区高度（Lead 复核要求：1024x640 下抽屉不许盖住播放控制条）
function npDrawerFit() {
  var dr = D('npDrawer');
  if (!dr) return;
  var ctl = document.querySelector('#npPage .npctl2');
  var vh = window.innerHeight || 0;
  var bottom = 14;
  if (ctl) {
    var b = ctl.getBoundingClientRect();
    if (b.top > 0 && b.top < vh) bottom = Math.max(12, Math.round(vh - b.top + 8));
  }
  dr.style.bottom = bottom + 'px';
}
function npDrawerOpen() {
  var dr = D('npDrawer'), bg = D('npDrawerBg');
  npDrawerFit();
  if (dr) dr.classList.add('on');
  if (bg) bg.classList.add('on');
}
function npDrawerClose() {
  var dr = D('npDrawer'), bg = D('npDrawerBg');
  if (dr) dr.classList.remove('on');
  if (bg) bg.classList.remove('on');
  NP_DATA.active = '';
  npDataRenderTabs();
}
function npDrawerIsOpen() {
  var dr = D('npDrawer');
  return !!(dr && dr.classList.contains('on'));
}
function npDataTargets(m) {
  var out = [];
  var title = String((m && m.title) || '') || ((D('npt') && D('npt').textContent) || '');
  var album = String((m && m.album) || '');
  var albumArtist = String((m && m.albumArtist) || '');
  var artist = String((m && m.artist) || '');
  if (title) out.push({ k: 'track', label: '歌曲', name: title, artist: artist });
  if (album && album !== title) {
    var relArtist = (m && m.summaryArtist) || albumArtist || artist;
    out.push({ k: 'release', label: '专辑', name: album, artist: relArtist });
  }
  var personName = albumArtist || artist;
  if (personName) out.push({ k: 'person', label: '艺术家', name: personName, artist: '' });
  if (npIsClassical(m)) {
    var w = npWorkTarget(m);
    if (w.title) out.push({ k: 'work', label: '作品', name: w.title, artist: '', composer: w.composer });
  }
  return out;
}
function npDataCan(m) {
  return !!(META.summary && m && (m.summaryAvailable || m.summaryCached || m.summaryCacheOk || META.hasLlmKey === true));
}
function npDataTab(kind) {
  var tabs = NP_DATA.tabs || [];
  for (var i = 0; i < tabs.length; ++i) if (tabs[i].k === kind) return tabs[i];
  return null;
}
// 右侧标签栏（#3b ③）：默认只露「歌曲 / 专辑 / 艺术家 / 作品」四类药丸；
// 每个药丸带一个状态点（灰=没取过、脉冲=整理中、绿=已有内容、黄=取不到），点开才请求、才出抽屉。
function npDataTabsSig() {
  return (NP_DATA.tabs || []).map(function (t) {
    var st = NP_DATA.cache[t.k] || { state: 'idle' };
    return t.k + ':' + t.label + ':' + st.state + ':' + (NP_DATA.active === t.k ? '1' : '0');
  }).join('|');
}
function npDataRenderTabs() {
  var el = D('npTabs'); if (!el) return;
  var sig = npDataTabsSig();
  if (sig === NP_DATA.tabSig) return;     // renderNp 每 400ms 调一次：没变化绝不重绘（否则悬停会闪）
  NP_DATA.tabSig = sig;
  var h = '';
  (NP_DATA.tabs || []).forEach(function (t) {
    var st = NP_DATA.cache[t.k] || { state: 'idle' };
    var cls = st.state === 'ok' ? ' ok' : (st.state === 'loading' ? ' busy' : (st.state === 'error' ? ' err' : ''));
    h += '<button class="npchip' + cls + (NP_DATA.active === t.k ? ' on' : '') + '" data-k="' + esc(t.k) + '"' +
         ' title="' + esc(t.label + '：' + (t.name || '') + '（点击查看 AI 整理的资料）') + '">' +
         '<i class=dot></i>' + esc(t.label) + '</button>';
  });
  el.innerHTML = h;
  Array.prototype.forEach.call(el.querySelectorAll('.npchip'), function (b) {
    b.onclick = function () { npDataToggle(b.dataset.k); };
  });
}
// 再点同一个标签 = 收起抽屉（浮层"看一眼就走"，不逼用户找关闭按钮）
function npDataToggle(kind) {
  if (NP_DATA.active === kind && npDrawerIsOpen()) { npDrawerClose(); npDataRenderBody(); return; }
  npDataActivate(kind);
}
function npDataStatHtml(kind, st) {
  if (!st || st.state === 'idle' || st.state === 'loading') return '整理中…';
  if (st.state === 'error') return '暂无资料';
  var d = st.data || {};
  if (kind === 'work') {
    var n = (d.performances || []).length;
    return (d.from_cache ? '缓存' : '实时') + (n ? ' · ' + n + ' 个版本' : '');
  }
  // 261024-01 #2：只标注来源状态（已缓存 / 刚刚整理），不再叠「未核对」这类长尾文案。
  return d.summaryCached ? '已缓存' : '刚刚整理';
}
function npDataSkeleton() {
  return '<div class=npdskel><i style="width:92%"></i><i style="width:76%"></i><i style="width:84%"></i></div>' +
         '<div class=npdhint>正在整理资料…</div>';
}
function npDataSummaryBody(d, kind) {
  // 261024-01 #4：结构化 filters/fields → 标签值网格（renderSummaryContent 内部优先 fields）；
  // 261024-01 #2：脚注只留「AI 整理」。
  // 261024-02 #3：本地曲库数据优先（歌曲=文件真实时长；专辑=Σ本地曲目 + 逐行曲目列表）。
  kind = kind || NP_DATA.active;
  var opts = {};
  if (d && d.__local) opts.local = d.__local;
  if (kind === 'release' && d && d.__album) {
    var trs = d.__album.tracks || [], tot = 0;
    trs.forEach(function (t) { tot += (t.dur || 0); });
    if (!tot) tot = d.__album.dur || 0;
    opts.local = { '时长': fmtDurLong(tot) };
    opts.tracklist = trs;
    opts.drop = { '曲目列表': 1 };   // 用下面的对齐表格替代 AI 的一行文本
  }
  var h = renderSummaryContent(d || {}, '', kind, opts);
  if (!h) h = '<div class=npdhint>该实体暂无可用的 AI 整理资料。</div>';
  return h;
}
function npDataWorkBody(d) {
  var perfs = (d && d.performances) || [];
  var w = npDataTab('work') || { name: '', composer: '' };
  if (!d || !d.ok || !perfs.length) {
    return '<div class=npdhint>未在 Discogs 检索到该作品的演绎版本（可能网络不可达或作品名不匹配）。</div>' +
           '<div class=npdhint style="margin-top:6px">作品：' + esc(w.name) + (w.composer ? (' · ' + esc(w.composer)) : '') + '</div>' +
           '<div style="margin-top:8px"><button class=btn id=npWorkRetry>重试查询</button></div>';
  }
  var sub = (d.from_cache ? ('缓存 · ' + (d.generated_at ? fmtDate(d.generated_at) : '')) : 'Discogs 实时') +
            ' · 不同演绎 ' + (typeof d.distinctCount === 'number' ? d.distinctCount : perfs.length) +
            ' / 发行版本 ' + (typeof d.releaseCount === 'number' ? d.releaseCount : perfs.length);
  var h = '<div class=npdhint style="margin-bottom:6px">' + esc(sub) + '</div>';
  perfs.forEach(function (p) {
    var ens = p.ensemble || p.orchestra || '';
    var meta = [p.conductor, ens, p.label, p.format].filter(function (x) { return !!x; }).join(' · ');
    h += '<div class=npdwork>' +
         '<span class=wy>' + (p.year > 0 ? p.year : '—') + '</span>' +
         '<span class=wt title="' + esc(p.title) + '">' + esc(p.title || '—') + '</span>' +
         '<span class=wp title="' + esc(meta) + '">' + esc(meta || '—') + '</span>' +
         '<button class="btn chip-copy" data-url="' + esc(p.url) + '" title="复制版本链接" style="font-size:10px;padding:1px 6px;flex:none">复制</button>' +
         '</div>';
  });
  h += '<div style="margin-top:10px"><button class="btn pri" id=npWorkOpen>查看 Discogs 版本推荐 →</button></div>';
  return h;
}
// 抽屉头部：类型标签 + 实体名 + 状态（#3b ③：默认看不到这些，点标签才滑出）
function npDataHeader(kind, st) {
  var t = kind ? (npDataTab(kind) || { label: '', name: '' }) : { label: '', name: '' };
  var k = D('npDrawerKind'), n = D('npDrawerName'), s = D('npDataStat');
  if (k) k.textContent = t.label || '资料';
  if (n) n.textContent = t.name || '';
  if (s) s.textContent = kind ? npDataStatHtml(kind, st) : '';
}
function npDataRenderBody(force) {
  var body = D('npDataBody');
  if (!body) return;
  var kind = NP_DATA.active;
  if (!kind) {
    if (NP_DATA.bodyKey) { body.innerHTML = ''; NP_DATA.bodyKey = ''; }
    npDataHeader('', null);
    return;
  }
  var st = NP_DATA.cache[kind] || { state: 'idle' };
  npDataHeader(kind, st);
  // renderNp 400ms 一次：内容没变就不重绘（否则抽屉里的滚动位置会被反复重置）
  var sig = kind + '|' + st.state + '|' + (st.data ? (st.data.generated_at || (st.data.summaryCached ? 'c' : 'f')) : (st.error || ''));
  var need = (sig !== NP_DATA.bodyKey);
  if (!need && !force) return;
  NP_DATA.bodyKey = sig;
  if (st.state === 'idle' || st.state === 'loading') { body.innerHTML = npDataSkeleton(); return; }
  if (st.state === 'error') {
    body.innerHTML = '<div class=npdhint>暂无该实体的资料。' + (st.error ? ('（' + esc(st.error) + '）') : '') + '</div>' +
      '<div style="margin-top:10px"><button class=btn id=npDataRetry>重试</button></div>';
    var rb = D('npDataRetry');
    if (rb) rb.onclick = function () { npDataEnsure(kind, true); };
    return;
  }
  if (kind === 'work') {
    body.innerHTML = npDataWorkBody(st.data) +
      '<div style="margin-top:14px"><button class="btn" id=npDataRefresh style="font-size:11px;padding:3px 10px">重新查询</button></div>';
    bindCopyChips(body);
    var wo = D('npWorkOpen'); if (wo) wo.onclick = npOpenWorks;
    var wr = D('npWorkRetry'); if (wr) wr.onclick = function () { npDataEnsure('work', true); };
    var wf = D('npDataRefresh'); if (wf) wf.onclick = function () { npDataEnsure('work', true); };
    return;
  }
  body.innerHTML = npDataSummaryBody(st.data, kind) +
    '<div style="margin-top:16px"><button class="btn" id=npDataRefresh style="font-size:11px;padding:3px 10px" title="重新请求 AI 整理（会消耗一次模型调用）">重新整理</button></div>';
  bindCopyChips(body);
  var rf = D('npDataRefresh');
  if (rf) rf.onclick = function () { npDataEnsure(kind, true); };
}
// 261024-02 #3：抽屉里的「专辑」标签也要用本地曲库真实曲目/总时长（AI 那份只补简介等文字字段）。
var NPLIB = { key: '', album: null };
function npLocalAlbum(name, artist, cb) {
  var key = String(name || '') + '|' + String(artist || '');
  if (NPLIB.key === key) { cb(NPLIB.album); return; }
  api('/api/lib/albums?q=' + encodeURIComponent(name || '')).then(function (j) {
    var list = (j && j.albums) || [], hit = null, i;
    for (i = 0; i < list.length; i++) {
      if (list[i].name === name && (!artist || !list[i].artist || list[i].artist === artist)) { hit = list[i]; break; }
    }
    if (!hit) for (i = 0; i < list.length; i++) { if (list[i].name === name) { hit = list[i]; break; } }
    if (!hit) { NPLIB.key = key; NPLIB.album = null; cb(null); return; }
    api('/api/lib/album?k=' + encodeURIComponent(hit.k)).then(function (a) {
      NPLIB.key = key; NPLIB.album = (a && a.ok) ? a : null; cb(NPLIB.album);
    }).catch(function () { cb(null); });
  }).catch(function () { cb(null); });
}
// 261024-02 追加（Lead 指定，属于 #1 的体感）：打开单曲页 / 切歌时**后台预取当前专辑的 release 资料**。
// 目的：用户点「专辑」标签时直接命中缓存/已完成的生成任务，不用再等 10~30s 的首次生成。
// 纪律：
//   * 只在"用户已开启在线资料整理"时预取（META.summary==1 且 hasLlmKey/summaryEnabled 为真）；
//   * 只预取 release 这一个实体，一次（同一首歌只发一次）；不打开抽屉、不改变任何 UI 状态；
//   * 失败静默（不 toast、不留错误态）；切歌后旧结果直接丢弃（key 不匹配）。
var NPPREF = { key: '' };
// 单曲页各类资料的 URL 只在这里拼（抽屉 / 预取 / 自动加载共用，才能命中同一份 summaryOnce 缓存）
function npSummUrl(kind, t, force) {
  return '/api/entity/summary?kind=' + kind + '&name=' + encodeURIComponent((t && t.name) || '') +
         ((t && t.artist) ? ('&artist=' + encodeURIComponent(t.artist)) : '') + '&lang=zh' +
         (force ? '&refresh=1' : '');
}
function npPrefetchRelease() {
  if (META.summary != 1) return;
  if (META.hasLlmKey !== true && META.summaryEnabled !== true) return;
  var tabs = NP_DATA.tabs || [], rel = null;
  for (var i = 0; i < tabs.length; ++i) if (tabs[i].k === 'release') rel = tabs[i];
  if (!rel) return;
  var myTrack = S.lastCur || '';
  var key = myTrack + '|' + rel.name + '|' + (rel.artist || '');
  if (NPPREF.key === key) return;
  NPPREF.key = key;
  var u = npSummUrl('release', rel);
  summaryOnce(u, function (s) {
    if (NPPREF.key !== key || (S.lastCur || '') !== myTrack) return;   // 切歌 → 丢弃
    if (!summHas(s)) return;                                          // 失败静默
    var finish = function () {
      if (NP_DATA.cache['release'] && NP_DATA.cache['release'].state === 'ok') return;  // 用户已自己取到
      NP_DATA.cache['release'] = { state: 'ok', data: s };
      npDataRenderTabs();
      if (NP_DATA.active === 'release') npDataRenderBody();
    };
    npLocalAlbum(rel.name, rel.artist || '', function (alb) { if (alb) s.__album = alb; finish(); });
  });
}
/* 261024-04 #7：打开 AI 整理后，**进入单曲页就自动加载**这首歌的 summary（用户原话：不再需要点击）。
   纪律：
     * 只在"开了 AI 整理 + 有 key"时自动发起（否则一次请求都不发，行为与从前一致）；
     * 已经取到 / 正在取 / 上次失败（error 不自动重试，等用户点重试）⟹ 直接跳过；
     * 抽屉**不自动打开**（261024-01 #3b ③ 的「资料默认隐藏」是既有验收项），内容就绪后标签点一下即看；
     * 失败不弹错：右侧标签栏下面留一行可点击的「重试」。 */
function npAutoSummary() {
  if (META.summary != 1) return;
  if (META.hasLlmKey !== true && META.summaryEnabled !== true) return;
  if (!npDataTab('track')) return;
  var st = NP_DATA.cache['track'];
  if (st && (st.state === 'ok' || st.state === 'loading' || st.state === 'error')) { npRailHint(); return; }
  npDataEnsure('track', false);
  npRailHint();
}
// 右侧标签栏下面那一行状态：后台整理中 / 失败可重试（不打扰：只有这两种情况才出现）
function npRailHint() {
  var el = D('npSummHint');
  if (!el) return;
  var st = NP_DATA.cache['track'];
  if (st && st.state === 'error') {
    el.style.display = '';
    el.innerHTML = '<span class=nprailerr id=npSummRetry role=button tabindex=0 title="重新请求这首歌的 AI 整理">' +
                   '歌曲资料未能取到 · 点击重试</span>';
    var b = D('npSummRetry');
    if (b) b.onclick = function () { npDataEnsure('track', true); };
  } else if (st && st.state === 'loading' && !npDrawerIsOpen()) {
    el.style.display = '';
    el.innerHTML = '<span class=nprailbusy>正在后台整理歌曲资料…</span>';
  } else {
    el.style.display = 'none';
    el.innerHTML = '';
  }
}
function npDataEnsure(kind, force) {
  var t = npDataTab(kind); if (!t) return;
  var st = NP_DATA.cache[kind];
  if (!force && st && (st.state === 'loading' || st.state === 'ok')) return;
  var fp = kind + '|' + t.name + '|' + (t.artist || '') + '|' + (t.composer || '');
  if (!force && NP_DATA.inflight[fp]) return;
  NP_DATA.inflight[fp] = 1;
  var req = NP_DATA.req;
  NP_DATA.cache[kind] = { state: 'loading' };
  if (NP_DATA.active === kind) npDataRenderBody();

  function done(data, err) {
    delete NP_DATA.inflight[fp];
    if (NP_DATA.req !== req) return;               // 已切歌 → 丢弃过期结果
    if (!D('npPage') || !D('npPage').classList.contains('on')) return;
    if (data) NP_DATA.cache[kind] = { state: 'ok', data: data };
    else NP_DATA.cache[kind] = { state: 'error', error: err || '' };
    if (NP_DATA.active === kind) npDataRenderBody();
  }
  if (kind === 'work') {
    api('/api/entity/versions?kind=work&name=' + encodeURIComponent(t.name) +
        (t.composer ? ('&composer=' + encodeURIComponent(t.composer)) : '') + (force ? '&refresh=1' : ''))
      .then(function (j) { done((j && j.ok && (j.performances || []).length) ? j : null, j && j.error); })
      .catch(function (e) { done(null, String(e)); });
    return;
  }
  // 261024-04 #7：走 summaryOnce —— 同一实体只请求一次（专辑页/单曲页/预取共用同一份缓存）
  var u = npSummUrl(kind, t, force);
  summaryOnce(u, function (s) {
    // 261024-01 #4：后端新增结构化 fields（可能没有 sections）⟹ 有 fields 也算有资料
    if (!summHas(s)) { done(null, (s && s.error) || ''); return; }
    // 261024-02 #3：把本地曲库的真实时长/曲目挂到结果上（AI 的时长/曲目列表一律不采信）
    if (kind === 'track') {
      if (S.dur > 0) s.__local = { '时长': fmtDurLong(S.dur) };   // 本地文件真实时长（AI 猜的一律不采信）
      done(s, '');
    } else if (kind === 'release') {
      npLocalAlbum(t.name, t.artist, function (alb) { if (alb) s.__album = alb; done(s, ''); });
    } else {
      done(s, '');
    }
  });
}
function npDataActivate(kind) {
  NP_DATA.active = kind;
  npDataRenderTabs();
  npDataRenderBody();
  npDrawerOpen();          // 先滑出抽屉（骨架态），再请求 —— 点一下就有反馈，不做"静默等 10 秒"
  npDataEnsure(kind, false);
}
// 打开「古典作品 · 演绎版本」整页（左导航已移除，这是唯一入口；返回按钮见 loadWorksView）
function npOpenWorks() {
  var w = npWorkTarget(S.curMeta);
  closeNowPlaying();
  loadWorksView(w.title || '', w.composer || '', true);
}
function updateNpData(m) {
  var rail = D('npRail'), grid = D('npGrid');
  if (!rail) return;
  var key = S.lastCur || '';
  if (NP_DATA.key !== key) { npDataReset(); NP_DATA.key = key; NP_DATA.req++; }
  var can = npDataCan(m);
  var tabs = can ? npDataTargets(m) : [];
  if (!can || !tabs.length) {
    // 没有任何可用资料：整个标签栏收起（不占版面、不留空白块），抽屉也收起
    rail.classList.remove('on');
    if (grid) grid.classList.remove('withdata');
    if (NP_DATA.active) npDrawerClose();
    return;
  }
  rail.classList.add('on');
  NP_DATA.tabs = tabs;
  // 切歌/元数据分两拍回来时，标签集合会变：抽屉开着的实体若已不存在 → 收起抽屉
  var activeStill = false;
  for (var i = 0; i < tabs.length; ++i) if (tabs[i].k === NP_DATA.active) activeStill = true;
  if (NP_DATA.active && !activeStill) npDrawerClose();
  npDataRenderTabs();
  // 261024-01 #3b ③「默认隐藏」：抽屉不打开、不占版面；
  // 261024-02 追加：但**专辑资料允许后台预取一次**（Lead 指定，改善"点开要等 10~30s"的体感）。
  npPrefetchRelease();
  // 261024-04 #7：进入单曲页自动加载**这首歌**的 summary（不需要点标签）
  npAutoSummary();
  if (NP_DATA.active) npDataEnsure(NP_DATA.active, false);
  npDataRenderBody();
}

// 单曲整页无内嵌封面时的占位图（内联 SVG，暗色黑胶；不引外部资源）
var NP_COVER_PLACEHOLDER = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 300">' +
  '<rect width="300" height="300" fill="#15171c"/>' +
  '<circle cx="150" cy="150" r="104" fill="none" stroke="#32353d" stroke-width="2"/>' +
  '<circle cx="150" cy="150" r="74" fill="none" stroke="#282b32" stroke-width="1.5"/>' +
  '<circle cx="150" cy="150" r="44" fill="none" stroke="#282b32" stroke-width="1.5"/>' +
  '<circle cx="150" cy="150" r="16" fill="#3d414b"/>' +
  '<circle cx="150" cy="150" r="4" fill="#15171c"/></svg>');

function renderNp() {
  var pg = D('npPage'); if (!pg || !pg.classList.contains('on')) return;
  D('npTitle').textContent = (D('npt') && D('npt').textContent) || '未播放';
  var sub = (D('npart') && D('npart').textContent) || '';
  var st = (D('nps') && D('nps').textContent) || '';
  D('npSub').textContent = sub + (st ? '  ·  ' + st : '');
  if (D('npKind')) D('npKind').textContent = npPlayingKindText(S.curMeta);
  // 元数据补全芯片 + 当前 EQ/IR 芯片（loadMeta / loadSettings 异步回来时也会走到这里刷一次）
  if (D('npMeta')) {
    // 261024-02 #5：单曲页「推送到设备」按钮（状态来自 /api/cast/state，与流媒体页/底栏同源）
    D('npMeta').innerHTML = (S.npMetaHtml || '') + npEqChipsHtml() + npCastBtnHtml();
    npBindEqChips();
    if (D('npCastBtn')) D('npCastBtn').onclick = castToggle;
    if (D('npAddSq')) D('npAddSq').onclick = function () {
      var curIdx = S.q ? S.q.index : -1;
      var file = S.lastCur || (curIdx >= 0 && S.q && S.q.items ? S.q.items[curIdx] : '');
      if (!file) { toast('当前没有播放曲目'); return; }
      var cue = (curIdx >= 0 && S.q && S.q.cues) ? S.q.cues[curIdx] : null;
      var cs = (cue && cue[0] !== undefined) ? cue[0] : -1;
      var ce = (cue && cue[1] !== undefined) ? cue[1] : -1;
      addToSavedQueue(file, cs, ce);
    };
    applyCastUi();
  }
  updateFavUi();
  updateNextTrackInfo();
  updateNpData(S.curMeta);
  // 视口/行高变化后抽屉底边要重新让出控制区（否则矮窗下会压住播放控制条）
  if (npDrawerIsOpen()) npDrawerFit();
  var bg = (D('cv') && D('cv').style.backgroundImage) || '';
  if (bg && bg.indexOf('url(') === 0) {
    D('npbg').style.backgroundImage = bg;
    D('npCover').src = bg.replace(/^url\("?/, '').replace(/"?\)$/, '');
    D('npCover').style.display = '';
  } else {
    D('npbg').style.backgroundImage = '';
    // 无封面时不再留一块黑斑（2026-10-23 DEBUG 视觉问题）：给一张内联 SVG 黑胶占位图，
    // 不依赖任何外部/包内图片资源。
    D('npCover').src = NP_COVER_PLACEHOLDER;
    D('npCover').style.display = '';
  }
  renderNpLyric();
}
// 整页歌词（261024-02 #4 重做）
//   * 当前行 .on 由**时间戳**决定（二分不需要，行数最多几百，线性即可）；
//   * 滚动 = 让 active 行在容器里垂直居中（lyricScrollTo），带平滑过渡，不是按百分比滚；
//   * 纯文本歌词（无时间戳）⟹ 不高亮、不自动滚（LY.timed=false）；
//   * 用户手动滚动后 3 秒内不抢滚动；seek / 切歌立刻重定位（lyricReposition 清保护）。
function renderNpLyric() {
  var box = D('npLyric'); if (!box) return;
  if (box.classList) box.classList.toggle('empty', !LY.lines.length);
  var grid = D('npGrid');
  if (grid) grid.classList.toggle('nolyric', !LY.lines.length);
  if (!LY.lines.length) {
    box.innerHTML = '<div class=npline>没有歌词<br><span style="font-size:12px;color:var(--mut2)">同名 .lrc 文件、内嵌歌词，或播放时自动在线补全（可在设置-元数据补全关闭）</span></div>';
    box.dataset.n = ''; box.dataset.at = ''; LY.at = -1;
    return;
  }
  var timed = lyricTimed();
  // 行集合或"带轴/纯文本"状态变化才重建 DOM（否则每 400ms 轮询都重建会把用户正在读的行冲掉）
  var key = LY.lines.length + ':' + (timed ? 1 : 0);
  if (box.dataset.n !== key) {
    box.dataset.n = key;
    var h = timed ? ''
      : '<div class=ly-hint title="这份歌词没有 [mm:ss] 时间轴，无法按播放位置高亮/跟随">纯文本歌词（无时间轴）· 不会自动跟随滚动</div>';
    LY.lines.forEach(function (l, i) { h += '<div class=npline data-i=' + i + '>' + esc(l.s) + '</div>'; });
    box.innerHTML = h;
    box.dataset.at = '';
    // 纯文本：留空让下面的 !timed 分支跑一次（复位 scrollTop + 清高亮），
    // 否则从"有轴歌词"切过来会停在上一首的滚动位置（实测 st=55 卡住）
    box.dataset.plain = timed ? '0' : '';
    LY.at = -1;
  }
  if (!timed) {
    // 无时间戳：一行都不高亮、也不自动滚（用户可能正在读，别动它）
    if (box.dataset.plain !== '1') {
      box.dataset.plain = '1';
      var rows0 = lyricRows(box);
      for (var z = 0; z < rows0.length; z++) rows0[z].classList.remove('on');
      box.scrollTop = 0;
    }
    return;
  }
  var pos = S.pos || 0;
  // 进度跳变（seek / 上一首 / 拖动进度条）→ 立刻重定位，不受"手动滚动保护"影响
  // ⚠ 必须同时清 dataset.at：否则"跳到同一行"时 dataset.at 相等，会吞掉这次重定位
  if (LY.lastPos >= 0 && Math.abs(pos - LY.lastPos) > 2.5) { LYMAN.until = 0; box.dataset.at = ''; }
  LY.lastPos = pos;
  var idx = -1;
  for (var i = 0; i < LY.lines.length; ++i) { if (LY.lines[i].t <= pos + 0.05) idx = i; else break; }
  if (idx < 0) idx = 0;   // 还没到第一句（前奏）：钉在第一行，避免整屏无高亮
  var rows = lyricRows(box);
  if (LY.at !== idx) {
    LY.at = idx;
    for (var r = 0; r < rows.length; r++) rows[r].classList.toggle('on', +rows[r].dataset.i === idx);
  }
  if (box.dataset.at !== String(idx)) {
    box.dataset.at = String(idx);
    if (Date.now() >= LYMAN.until) lyricScrollTo(box, rows[idx]);
  }
}
// 手动滚动保护（滚轮 / 触摸拖动）：3 秒内自动滚动不跟用户抢
(function bindLyricManual() {
  ['npLyric', 'lyricbox'].forEach(function (id) {
    var el = D(id);
    if (!el) return;
    el.addEventListener('wheel', lyricManual, { passive: true });
    el.addEventListener('touchstart', lyricManual, { passive: true });
  });
  // 视口尺寸变了（真机窗口 DPI/尺寸 race、用户拉窗）：留白与目标位置都要重算，
  // 否则"行高变了但 scrollTop 还是旧值"，看起来就是歌词停在半路。
  window.addEventListener('resize', function () {
    LYMAN.until = 0;
    var b = D('npLyric');
    if (b) b.dataset.at = '';
    if (D('npPage') && D('npPage').classList.contains('on')) renderNpLyric();
    if (RTAB === 'l') { LY.at = -1; syncLyrics(S.pos || 0, true); }
  });
})();

/* ---------------- 拖拽入队 ---------------- */
function pathsFromDrop(e) {
  var out = [], uris = '';
  try { uris = e.dataTransfer.getData('text/uri-list') || ''; } catch (x) { }
  if (!uris) { try { uris = e.dataTransfer.getData('text/plain') || ''; } catch (x) { } }
  String(uris).split(/\r?\n/).forEach(function (u) {
    u = u.trim();
    if (!u || u.charAt(0) === '#') return;
    if (u.indexOf('file:///') === 0) out.push(decodeURIComponent(u.slice(8)).replace(/\//g, SEP));
    else if (/^[A-Za-z]:[\\\/]/.test(u)) out.push(u);
  });
  return out;
}
function addMany(paths) {
  if (!paths.length) { toast('没有可加入的文件'); return; }
  var i = 0, n = 0;
  (function step() {
    if (i >= paths.length) {
      toast('已加入 ' + n + ' 项');
      loadQ();
      if (S.view === 'queue') renderQueuePage();
      return;
    }
    api('/api/add', 'file=' + encodeURIComponent(paths[i++])).then(function (j) {
      if (j && j.ok) n += (j.count || 1);
      step();
    }).catch(step);
  })();
}
function dropFiles(e) {
  var paths = pathsFromDrop(e);
  if (paths.length) { addMany(paths); return; }
  var files = e.dataTransfer.files ? Array.prototype.slice.call(e.dataTransfer.files) : [];
  if (!files.length) return;
  // 某些情况下浏览器不给真实路径：把内容上传到本机服务，再由服务端入队
  var done = 0, added = [];
  files.forEach(function (f) {
    var x = new XMLHttpRequest();
    x.open('POST', '/api/upload?name=' + encodeURIComponent(f.name));
    x.onload = function () {
      try { var r = JSON.parse(x.responseText); if (r && r.path) added.push(r.path); } catch (err) { }
      if (++done === files.length) addMany(added);
    };
    x.onerror = function () { if (++done === files.length) addMany(added); };
    x.send(f);
  });
}
(function initDrop() {
  var mask = document.createElement('div');
  mask.id = 'dropmask';
  mask.innerHTML = '<div>松开，加入播放队列</div>';
  document.body.appendChild(mask);
  var depth = 0;
  function hasFiles(e) {
    var t = e.dataTransfer && e.dataTransfer.types;
    if (!t) return false;
    for (var i = 0; i < t.length; ++i) if (t[i] === 'Files') return true;
    return false;
  }
  window.addEventListener('dragenter', function (e) {
    if (!hasFiles(e)) return;
    e.preventDefault(); ++depth; mask.classList.add('on');
  });
  window.addEventListener('dragover', function (e) {
    if (!hasFiles(e)) return;
    e.preventDefault(); e.dataTransfer.dropEffect = 'copy';
  });
  window.addEventListener('dragleave', function (e) {
    if (!hasFiles(e)) return;
    if (--depth <= 0) { depth = 0; mask.classList.remove('on'); }
  });
  window.addEventListener('drop', function (e) {
    if (!hasFiles(e)) return;
    e.preventDefault(); depth = 0; mask.classList.remove('on');
    dropFiles(e);
  });
})();

/* ---------------- 循环方式 ---------------- */
// applyRep / cycleRep 已在上面定义（底栏 bRep 与整页 npRep 共用同一份实现，
// 不各写一遍 —— 那正是历史上两处不一致的来源）。这里只做绑定。
D('bRep').onclick = cycleRep;
// 快捷面板 #sRep 被别处改动（如设置页保存）时，图标状态也要跟上
if (D('sRep')) D('sRep').addEventListener('change', function () { applyRep(this.value); });

/* ---------------- 自适应轮询（261025-01 缺陷 3） ----------------
   改之前是三条**固定**定时器（用 setInterval 挂的，永不停止也永不降频）：
     tick         每 400ms  → /api/status，每秒 2.5 个请求
     loadQ        每 3000ms → /api/queue，每秒 0.33 个
     loadLibStats 每 2000ms → /api/lib/stats，每秒 0.5 个
   合计**空闲时也有约 3.3 请求/秒**。后端是单线程 accept：主控实测 12000 首库冷算
   /api/lib/albums 要 625ms，这期间并发打进来的 /api/lib/stats 从 20ms 被拖到 **594ms**。
   只要阻塞超过一个轮询周期，请求就开始堆积 → 队列越滚越长 → fetch 超时 →
   用户看到的就是「Failed to fetch」。所以轮询必须**跟着状态走**，而不是一直全速跑。

   三档节奏（改后）：
     播放中（S.playing && !S.paused）：status 400ms / queue 3s / stats 30s
     扫描中（S.scanning）：            status 2.5s / queue 15s / stats 2s（进度条靠 stats 喂）
     空闲（停止或暂停）：               status 2.5s / queue 15s / stats 30s
     页面隐藏（document.hidden）：      全部暂停；可见时立刻各补一次再按当时状态恢复
   两条口径说明：
     * status 只有**播放中**才需要 400ms（进度条要顺）；扫描进度由 stats 提供，不靠 status。
     * stats 只有**扫描中**才需要 2s；播放中它没有任何快速变化的内容，30s 足够。

   为什么用 setTimeout 链而不是 setInterval：只有链式才能**每次重新算间隔**，
   而且不会在上一发还没回来时叠上去（见下面的 in-flight 互斥）——那正是堆积的来源。
   注意 status 在「暂停」时也降到慢档：暂停后 pos 不再变化，没有理由 400ms 去问一次。 */
var POLL = {
  playStatus: 400, playQueue: 3000,   // 播放中：只有这两条需要快
  scanStats: 2000, scanQueue: 15000,  // 扫描中：只有 stats（进度）需要快
  idleStatus: 2500, idleQueue: 15000, idleStats: 30000,   // 空闲/暂停
  t1: 0, t2: 0, t3: 0,
  busy: { status: false, queue: false, stats: false },   // 上一发还在路上就不再发（防堆积）
  started: false
};
function pollHidden() { return !!(document.hidden || document.visibilityState === 'hidden'); }
// 当前该用哪一档。两个维度：**是否在播**（决定 status/queue）与**是否在扫**（决定 stats）。
// 分开判断而不是"三选一档"：扫描中也可能同时在播，那时 status 仍要 400ms、stats 仍要 2s。
function pollGap(kind) {
  var playing = S.playing && !S.paused;
  if (kind === 'status') return playing ? POLL.playStatus : POLL.idleStatus;
  if (kind === 'queue') return playing ? POLL.playQueue : (S.scanning ? POLL.scanQueue : POLL.idleQueue);
  return S.scanning ? POLL.scanStats : POLL.idleStats;
}
// 一次「发请求 → 回来后 → 再排下一次」。间隔从**上一次完成时刻**起算（不是从发起时刻），
// 所以后端慢的时候自然拉长间隔、不会叠加 —— 这才是"请求不再堆积"的真正机制。
// fn 需要返回 promise 才能让 in-flight 互斥生效；tick/loadQ/loadLibStats 都 return api(...)。
function pollSchedule(kind, fn) {
  var timerKey = kind === 'status' ? 't1' : (kind === 'queue' ? 't2' : 't3');
  if (pollHidden()) { POLL[timerKey] = 0; return; }   // 隐藏时不排下一发
  var gap = pollGap(kind);
  POLL[timerKey] = setTimeout(function () {
    if (pollHidden()) { POLL[timerKey] = 0; return; }
    if (POLL.busy[kind]) { pollSchedule(kind, fn); return; }   // 上一发没回来：跳过这一拍，别叠加
    POLL.busy[kind] = true;
    var done = function () { POLL.busy[kind] = false; pollSchedule(kind, fn); };
    try {
      var r = fn();
      if (r && typeof r.then === 'function') r.then(done, done);
      // 三个轮询函数都必须 return api(...)，否则这里会同步走 done()，in-flight 互斥形同虚设：
      // 那正是改前"上一发没回来又发下一发"的堆积路径。保留这个 else 只是防御未来有人改了返回值。
      else done();
    } catch (e) { done(); }
  }, gap);
}
function pollStart() {
  if (POLL.started) return;
  POLL.started = true;
  pollSchedule('status', tick);
  pollSchedule('queue', loadQ);
  pollSchedule('stats', loadLibStats);
}
// 状态变化（开始播放 / 暂停 / 扫描开始或结束）时**立即重排**，否则用户按下播放后
// 要等最多 30 秒（空闲档）才切到 400ms 档，进度条会像卡住。重排 = 清掉旧定时器再排一次。
function pollKick() {
  ['t1', 't2', 't3'].forEach(function (k) { if (POLL[k]) { clearTimeout(POLL[k]); POLL[k] = 0; } });
  if (!POLL.started) return;
  if (pollHidden()) return;   // 隐藏中：等 visibilitychange 再恢复
  pollSchedule('status', tick);
  pollSchedule('queue', loadQ);
  pollSchedule('stats', loadLibStats);
}
document.addEventListener('visibilitychange', function () {
  if (pollHidden()) {
    // 隐藏：立刻停掉所有定时器。为什么要显式清：隐藏时已经排上的那一次还会烧掉，
    // 而且用户切回前台前不该有任何请求（后台标签页白烧后端，正是"卡顿"的隐形来源）。
    ['t1', 't2', 't3'].forEach(function (k) { if (POLL[k]) { clearTimeout(POLL[k]); POLL[k] = 0; } });
    return;
  }
  // 可见：**立刻各补一次**（用户切回来要看到的是最新状态，不是几十秒前的），再按当时状态恢复节奏。
  if (POLL.started) { tick(); loadQ(); loadLibStats(); pollKick(); }
});

/* ---------------- 本轮新增样式（反馈 #4c / #9） ----------------
   为什么不写进 ui_page.h：那个文件不在本轮可改路径白名单里（改动会与别人冲突）。
   这里是纯新增规则、不改任何既有选择器，插一个 <style> 即可；
   规则里用的都是既有 CSS 变量（--mut2/--danger/--toast/--shadow/--line/--hov），三套主题自动跟随。 */
(function injectRoundCss() {
  if (document.getElementById('roundCss')) return;
  var css = '' +
    // #4c：文件夹视图每行的「从磁盘删除」按钮（悬停才显形，避免每行常驻一个红叉）
    '.row .fdel{width:24px;height:24px;border-radius:6px;color:var(--mut2);flex:none;opacity:0;' +
      'transition:.12s;font-size:15px;line-height:1;background:none;border:0;cursor:pointer}' +
    '.row:hover .fdel{opacity:1}.row .fdel:hover{background:var(--hov2);color:var(--danger)}' +
    // #9：右击队列行的菜单（右击只弹菜单，不再直接删行）
    '.qmenu{position:fixed;z-index:95;min-width:190px;max-width:300px;background:var(--toast);' +
      'border:1px solid var(--line);border-radius:9px;box-shadow:0 10px 30px var(--shadow);padding:5px;font-size:12.5px}' +
    '.qmenu .qmt{color:var(--mut2);font-size:11px;padding:5px 9px 7px;white-space:nowrap;' +
      'overflow:hidden;text-overflow:ellipsis;border-bottom:1px solid var(--line);margin-bottom:4px}' +
    '.qmenu .qm{display:block;width:100%;text-align:left;padding:7px 10px;border-radius:6px;' +
      'color:var(--txt);font-size:12.5px;background:none;border:0;cursor:pointer}' +
    '.qmenu .qm:hover{background:var(--hov)}' +
    '.qmenu .qm[data-a=del]:hover{background:var(--hov2);color:var(--danger)}';
  var st = document.createElement('style');
  st.id = 'roundCss';
  st.appendChild(document.createTextNode(css));
  document.head.appendChild(st);
})();

/* ---------------- 启动 ---------------- */
initFavs();
renderSavedQueues();
try {
  window.playWholeListFrom = playWholeListFrom;
  window.renderSavedQueues = renderSavedQueues;
  window.loadFavs = loadFavs;
  window.saveQueueDialog = saveQueueDialog;
  window.newSavedQueueDialog = newSavedQueueDialog;
  window.addToSavedQueue = addToSavedQueue;
  window.pickSavedQueue = pickSavedQueue;
  window.applyQueueSort = applyQueueSort;
} catch (e) { }
if (D('npFavBtn')) D('npFavBtn').onclick = function (ev) { if (S.lastCur) toggleFav(S.lastCur, ev); };
// 2026-10-26 F-1/B-3：底栏跑马灯。必须在 DOM 就绪后挂，且失败绝不能影响启动 —
// 页面结构变了（缺 #mqTitle）时 mqMount() 会自己静默返回。
try { mqMount(); } catch (e) { }
// 2026-10-26 F-4：启动后自动查一次更新（用户要求「自动提示用户更新」）。
//   延迟 4s：让首屏专辑与播放状态先出来，别让更新检查跟首屏抢带宽。
//   只在原生壳里发；浏览器直开时 updCheck 会如实说明不支持，不产生网络请求。
//   失败只在「诊断」页里如实显示，**不弹窗打断**（听歌的人不该被网络错误打扰）。
setTimeout(function () {
  try { if (IS_MAC_HOST) updCheck(false); } catch (e) { }
}, 4000);
loadLibStats();
loadSettings();
loadFilterPhases();   // 功能2：相位预设真相源（/api/filters）
fillMetaProviders();   // P1.5：数据源注册表（/api/providers）驱动元数据分组源开关
loadRates();
loadAlbums('');
loadQ();
loadSrcConfig();
tick();
pollStart();
)JS";
}

} // namespace rta::net
