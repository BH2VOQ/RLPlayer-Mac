// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// check_114_analysis_ui.js — 1.1.4 单曲页「音频分析」面板的 UI 判据
//
// ============================ 这个测试在证明什么 ============================
// 驱动的是**生产页面里的真实函数**（anlTick / anlAnalyze / anlPaint / anlCardsHtml / anlIsLocal），
// 不是在测试里另写一份"和产品一样的逻辑" —— 那只能证明两份代码都写了同一段文字。
//
// 判据（每条都对着一条明确的产品要求）：
//   A1 面板在 #npPage 的 .npbody 左竖栏；.npgrid 三行、.npbody 三列且左右等宽；
//      音频分析在左、AI 整理在右、歌词中心恒等于容器中心（对称且不影响歌词居中）。
//   A2 默认 auto=0 / lvl=0；三张 L0 卡片可见且**没有**指标网格。
//   A3 三个层级都渲染三张卡；L1 有「真峰」「dBTP」，L0 没有（折叠真的折叠了）。
//   A4 fs/4 45° 的假素材：样本峰值 -3.01 与真峰 0.00 dBTP 同时出现，且真峰 > 样本峰值
//      （采样点之间越界这件事，只有真峰能看见）。
//   A5 短素材（dr_available=false）：DR/LRA 显示「不适用」，且那一格**没有任何数字**
//      —— 0.0 与"没测到"必须能分辨（铁律 3：判据不能只看"有没有数字出现"）。
//   A6 多声道（channels=6）：卡片头出现「多声道 6 ch」，立体声相关 / side-mid 显示「不适用（多声道）」。
//   A7 fs=8000：10k 以上能量显示「不适用（采样率 ≤20 kHz）」。
//   A8 真峰 > 0：警告行「母带已过载」在 L0 也可见（关键结论不许被折叠藏起来）。
//   A9 按钮循环 0→1→2→0，文案依次是 详细 / 全部指标 / 收起。
//   A10 自动分析默认关：auto=0 时 anlTick(path,true) **不发** /api/health。
//   A11 状态轮询真的接进了 anlTick（tick 调它，参数是 S.lastCur 与 playing&&!paused）。
//   A12 自动分析开：首次 anlTick 恰好 1 次请求；暂停/继续/拖动（同曲再次 active）不重复；
//       结果进缓存并重绘到面板。
//   A13 切歌：取消上一首（/api/anl/cancel）、seq++、lvl 复位 0；**旧曲目迟到的响应不得写进缓存**
//       （串台判据 —— 这是本面板最容易出错、也最容易被"看起来正常"掩盖的一条）。
//   A14 状态文字：完成态是「分析于 HH:MM」或「… · 缓存命中」。
//   A15 设置页「通用 → 播放」里有 sp_autoanl，默认未勾选；勾选后 ANL.auto 跟着变 1。
//   A16 几何：1024x640 与 1576x908 下三行互不重叠、左右竖栏等宽、歌词恒居中、
//      控制区完整在视口内（左右竖栏铺满行2 高度、卡片区内滚，不许把控件顶出屏幕）。
//   A17 anlIsLocal：只认本地绝对路径（http/smb/UNC/.cda 一律拒绝）。
//
// 🔴 铁律 1：全程 headless，**不播放任何音频**（不调 /api/play），后端用 Lead 起好的 backend=null 实例。
// 🔴 铁律 2：浏览器进程由 uibrowser 核验属主后 SIGTERM，绝不 force-kill。
//
// 用法：node tools/check_114_analysis_ui.js http://127.0.0.1:19114/
'use strict';
const ub = require('./uibrowser');

const URL_ = process.argv[2] || 'http://127.0.0.1:19114/';
let fail = 0, total = 0;
function ck(ok, what, detail) {
  total++;
  if (!ok) fail++;
  console.log(`  [${ok ? 'PASS' : 'FAIL'}] ${what}${detail ? '  ' + detail : ''}`);
}
const J = (o) => JSON.stringify(o);

/* ---------- 合成 health：字段与 tools/rtaweb.cpp 的 track_health_json 逐项对齐 ---------- */
const H_BASE = {
  dr_db: 14.6, lufs: -14.2, lra: 8.1, peak_dbfs: -0.9, true_peak_dbtp: -0.4,
  true_peak_available: true, dr_available: true, lra_available: true, lufs_available: true,
  lossless_suspected: false, cutoff_hz: 22040.0, confidence: 0.92,
  reason: '截止频率接近 Nyquist（22.0 kHz），未发现上采样痕迹',
  fake24: false, duration_sec: 201.5, fs: 44100, channels: 2, bits: 16,
  status: 'ready', error: '', analyzed_at_ms: 1762400000000,
  quality: {
    available: true, thdn_db: -61.2, thdn_pct: 0.087, thdn_available: true, thdn_method: '多峰平均',
    non_tonal_db: -57.4, imd_available: false, imd_db: -300.0, imd_note: '需要双音素材',
    noise_floor_dbfs: -91.5, spectral_min_dbfs: -101.9, snr_db: 69.8, centroid_hz: 1740.5,
    tilt_db_per_oct: -3.2, rolloff95_hz: 15250.0, hf_ratio_10k_db: -20.4, hf_ratio_10k_available: true,
    peak_dbfs_q: -0.9, rms_dbfs: -19.4, clipped_samples: 0, clipped_pct: 0.0,
    clipped_runs: 0, longest_clip_run: 0, crest_db: 13.7,
    stereo: true, channel_corr: 0.712, mono_loss_db: -1.1, side_mid_db: -9.4, side_mid_available: true,
    dyn_p95_p10_db: 11.8, dyn_centroid_dbfs: -18.6, quiet_p10_dbfs: -38.2, silence_pct: 0.9,
    spectral_windows: 198, note: ''
  }
};
const clone = (o) => JSON.parse(JSON.stringify(o));
const withQ = (over, qover) => {
  const h = clone(H_BASE);
  Object.assign(h, over || {});
  if (qover) Object.assign(h.quality, qover);
  return h;
};
// fs/4、45° 的正弦（采样点恰好不落在峰值上）：样本峰值 -3.01 dBFS，真峰 0.00 dBTP
const H_45 = withQ({ peak_dbfs: -3.01, true_peak_dbtp: 0.0 });
// 短素材：后端把不可用的值写成 -300 哨兵 + dr_available=false
const H_SHORT = withQ({ dr_db: -300.0, lufs: -300.0, lra: -300.0, dr_available: false, lra_available: false, lufs_available: false, true_peak_dbtp: -300.0, true_peak_available: false, duration_sec: 0.9, cutoff_hz: -300.0, confidence: 0.0 });
// 多声道：side/mid 不再有意义
const H_MULTI = withQ({ channels: 6 }, { side_mid_available: false });
// 8 kHz 素材：10 kHz 以上没有可测带宽
const H_LO = withQ({ fs: 8000 }, { hf_ratio_10k_available: false });
// 真峰越界（母带过载）
const H_OVER = withQ({ true_peak_dbtp: 0.31, peak_dbfs: -0.2 });

(async () => {
  const s = await ub.open({ url: URL_, width: 1280, height: 900 });
  try {
    const ready = await s.waitFor("typeof window.anlTick === 'function' && document.getElementById('npAnal')", 15000);
    if (!ready) {
      console.log('FATAL: 页面没起来（找不到 #npAnal 或 anlTick）: ' + await s.eval('location.href'));
      process.exit(2);
    }

    /* ---------------- A1/A16：结构（1.1.4-beta4 竖栏对称布局） ---------------- */
    const dom = await s.eval(`(function(){
      var p=document.getElementById('npAnal'), page=document.getElementById('npPage'),
          grid=document.getElementById('npGrid'), body=document.querySelector('.npbody'),
          lyr=document.getElementById('npLyric'), rail=document.getElementById('npRail');
      if(!p||!page||!grid||!body||!lyr||!rail) return {ok:false};
      // computed 值是 "auto minmax(0px, 1fr) auto" —— minmax() 内部有空格，先折叠再切
      var rows=getComputedStyle(grid).gridTemplateRows.replace(/minmax\\([^)]*\\)/g,'MINMAX')
                 .split(/\\s+/).filter(Boolean);
      var cols=getComputedStyle(body).gridTemplateColumns.split(/\\s+/).filter(Boolean)
                 .map(function(x){return parseFloat(x);});
      var rb=body.getBoundingClientRect(), lr=lyr.getBoundingClientRect(),
          pr=p.getBoundingClientRect(), rr=rail.getBoundingClientRect();
      return {
        ok:true, inPage: page.contains(p), inBody: body.contains(p),
        rows: rows.length,
        cols: cols.length,
        // 左右竖栏等宽（对称）：三列模板 1fr|2fr|1fr ⟹ 第一列 == 第三列
        sideEq: cols.length===3 && Math.abs(cols[0]-cols[2])<=1.5,
        // 音频分析在歌词左、AI 整理在歌词右
        leftRail: pr.right <= lr.left + 1.5,
        rightRail: rr.left >= lr.right - 1.5,
        // 歌词中心恒等于 .npbody 中心（用户硬约束：两侧竖栏不影响歌词居中）
        centerDx: Math.abs((lr.left+lr.width/2)-(rb.left+rb.width/2)),
        overflow: getComputedStyle(document.getElementById('npAnlBody')).overflowY
      };
    })()`);
    ck(dom && dom.ok && dom.inPage && dom.inBody, 'A1 #npAnal 在 #npPage 的 .npbody 内（左竖栏）');
    ck(dom && dom.rows === 3, 'A1 .npgrid 是三行网格（音频分析不再单独占行）', dom ? `tracks=${dom.rows}` : '');
    ck(dom && dom.cols === 3 && dom.sideEq, 'A1 .npbody 三列且左右竖栏等宽（对称分布）',
      dom ? `cols=${dom.cols} sideEq=${dom.sideEq}` : '');
    ck(dom && dom.leftRail && dom.rightRail, 'A1 音频分析在左、AI 整理在右（对称分布）',
      dom ? `left=${dom.leftRail} right=${dom.rightRail}` : '');
    ck(dom && dom.centerDx <= 1.5, 'A1 歌词中心恒等于容器中心（两侧竖栏不影响歌词居中）',
      dom ? `centerDx=${dom.centerDx}` : '');
    ck(dom && dom.overflow === 'auto', 'A1 卡片区自己滚动（不会把控制区顶下去）', dom ? `overflow=${dom.overflow}` : '');

    /* ---------------- A2：默认 auto=0 / lvl=0 ---------------- */
    const def = await s.eval("[window.ANL.auto, window.ANL.lvl].join(',')");
    ck(def === '0,0', 'A2 默认 ANL.auto=0、ANL.lvl=0', def);
    await s.eval("(function(){ if(typeof openNowPlaying==='function') openNowPlaying(); return 1; })()");
    await ub.sleep(250);
    const l0 = await s.eval("(function(){var b=document.getElementById('npAnlBody');return {cards:b.querySelectorAll('.anlcard').length,grids:b.querySelectorAll('.anlgrid').length,stat:(document.getElementById('npAnlStat')||{}).textContent,toggle:(document.getElementById('npAnlToggle')||{}).textContent};})()");
    ck(l0.cards === 3 && l0.grids === 0, 'A2 L0 三张卡片可见且没有指标网格', J(l0));

    /* ---------------- A3–A8：纯渲染（anlCardsHtml） ---------------- */
    // 在页面里渲染并解析成 {text, rows:[[label,value]], cards, grids}，判据直接对着真实产出
    const render = (health, lvl, path) => s.eval(`(function(){
      var box=document.createElement('div');
      box.innerHTML=anlCardsHtml(${J(health)}, ${J(path || '/music/fake.flac')}, ${lvl});
      var rows=[];
      Array.prototype.forEach.call(box.querySelectorAll('.anlml'),function(r){
        var l=r.querySelector('.anllb'), v=r.querySelector('.anlv');
        rows.push([l?l.textContent:'', v?v.textContent:'']);
      });
      var badges=[];
      Array.prototype.forEach.call(box.querySelectorAll('.anlbadge'),function(b){badges.push(b.textContent);});
      var cards=box.querySelectorAll('.anlcard').length, grids=box.querySelectorAll('.anlgrid').length;
      var sums=[];
      Array.prototype.forEach.call(box.querySelectorAll('.anlcs'),function(x){sums.push(x.textContent);});
      return {cards:cards, grids:grids, text:box.textContent, rows:rows, badges:badges, sums:sums};
    })()`);
    const findRow = (r, lb) => (r.rows.filter((x) => x[0] === lb)[0] || ['', ''])[1];

    const L0 = await render(H_BASE, 0), L1 = await render(H_BASE, 1), L2 = await render(H_BASE, 2);
    ck(L0.cards === 3 && L1.cards === 3 && L2.cards === 3, 'A3 三个层级都渲染三张卡片',
      `L0=${L0.cards} L1=${L1.cards} L2=${L2.cards}`);
    ck(L0.grids === 0 && L1.grids === 3 && L2.grids === 3, 'A3 只有 L1/L2 有指标网格', `L0=${L0.grids} L1=${L1.grids} L2=${L2.grids}`);
    ck(/真峰/.test(L1.text) && /dBTP/.test(L1.text), 'A3 L1 含「真峰」与「dBTP」');
    ck(!/真峰/.test(L0.text) && !/dBTP/.test(L0.text), 'A3 L0 不含「真峰」/「dBTP」（摘要真的是摘要）',
      (L0.sums || []).join(' | ').slice(0, 120));
    ck(L0.text.length > 20 && /动态|密度|带宽|削波/.test(L0.sums.join('')), 'A3 L0 摘要由真实字段推导（不是空壳）',
      (L0.sums || []).join(' | ').slice(0, 140));

    // A4：fs/4 45°
    const R45 = await render(H_45, 1);
    const pk = findRow(R45, '样本峰值'), tp = findRow(R45, '真峰 (dBTP)');
    ck(/-3\.01/.test(pk) && /0\.00/.test(tp), 'A4 样本峰值 -3.01 与真峰 0.00 dBTP 同时出现', `peak=${pk} tp=${tp}`);
    ck(parseFloat(tp) > parseFloat(pk), 'A4 真峰值 > 样本峰值（采样点之间越界可见）', `${tp} > ${pk}`);

    // A5：短素材
    const RS = await render(H_SHORT, 1);
    const dr = findRow(RS, '动态范围 DR'), lra = findRow(RS, '响度范围 LRA');
    ck(/不适用/.test(dr) && !/\d/.test(dr), 'A5 素材过短：DR 显示「不适用」且不含任何数字', `DR="${dr}"`);
    ck(/不适用/.test(lra) && !/\d/.test(lra), 'A5 素材过短：LRA 显示「不适用」且不含任何数字', `LRA="${lra}"`);
    ck(!/0\.0\s*dB/.test(dr + ' ' + lra), 'A5 短素材没有被渲染成 0.0（哨兵 -300 不许冒充测量值）');

    // A6：多声道
    const RM = await render(H_MULTI, 1);
    ck((RM.badges || []).some((b) => /多声道\s*6\s*ch/.test(b)), 'A6 多声道徽标「多声道 6 ch」可见', J(RM.badges));
    const corr = findRow(RM, '立体声相关');
    ck(/不适用（多声道）/.test(corr), 'A6 多声道时立体声相关显示「不适用（多声道）」', `corr="${corr}"`);

    // A7：8 kHz 素材
    const RL = await render(H_LO, 1);
    const hf = findRow(RL, '10k 以上能量');
    ck(/不适用（采样率 ≤20 kHz）/.test(hf), 'A7 fs=8000 时 10k 比例显示「不适用（采样率 ≤20 kHz）」', `hf="${hf}"`);

    // A8：真峰过载
    const RO0 = await render(H_OVER, 0), RO1 = await render(H_OVER, 1);
    ck(/母带已过载/.test(RO0.text) && /\+0\.31\s*dBTP/.test(RO0.text), 'A8 真峰 +0.31 时 L0 就出现「母带已过载」警告');
    ck(/采样点/.test(RO0.text), 'A8 警告里说明样本峰值只反映采样点');
    ck(/母带已过载/.test(RO1.text), 'A8 L1 同样保留过载警告');

    /* ---------------- A9：三级折叠按钮 ---------------- */
    const tgSeq = [];
    for (let i = 0; i < 4; i++) {
      tgSeq.push(await s.eval("(function(){var t=document.getElementById('npAnlToggle');t.click();return window.ANL.lvl+'|'+t.textContent;})()"));
      await ub.sleep(60);
    }
    const lvls = tgSeq.map((x) => x.split('|')[0]).join(',');
    const labels = tgSeq.map((x) => x.split('|')[1]);
    ck(lvls === '1,2,0,1', 'A9 按钮循环 0→1→2→0', lvls);
    ck(labels[0] === '全部指标' && labels[1] === '收起' && labels[2] === '详细',
      'A9 文案依次是 全部指标 / 收起 / 详细（写的是"点下去会发生什么"）', J(labels));
    ck(await s.eval("window.ANL.lvl") === 1, 'A9 复位到已知层级以便后续判据');
    await s.eval("anlSetLvl(0)");

    /* ---------------- A17：anlIsLocal ---------------- */
    const loc = await s.eval(`[['/Users/x/a.flac',1],['C:\\\\Music\\\\a.flac',1],['http://h/a.flac',0],
      ['https://h/a.flac',0],['smb://h/a.flac',0],['\\\\\\\\host\\\\share\\\\a.flac',0],
      ['/cd/01.cda',0],['rel/a.flac',0],['',0]].map(function(p){return [p[0], anlIsLocal(p[0])===!!p[1]];})`);
    const badLoc = loc.filter((x) => !x[1]).map((x) => x[0]);
    ck(badLoc.length === 0, 'A17 anlIsLocal 只认本地绝对路径（http/smb/UNC/.cda 全部拒绝）', badLoc.length ? J(badLoc) : '');

    /* ---------------- A15：设置页开关 ---------------- */
    await s.eval("(function(){ if(typeof openSettingsTab==='function') openSettingsTab('adv'); return 1; })()");
    const hasChk = await s.waitFor("document.getElementById('sp_autoanl')", 6000);
    const chkInfo = hasChk ? await s.eval("(function(){var c=document.getElementById('sp_autoanl');var l=document.getElementById('sp_autoanl_lbl');return {checked:c.checked,label:l?l.textContent:'',hint:(c.parentNode.querySelector('.tip')||{}).dataset?c.parentNode.querySelector('.tip').dataset.tip:''};})()") : null;
    ck(hasChk && chkInfo && chkInfo.checked === false, 'A15 设置→通用→播放 有「播放时自动分析」且默认未勾选', chkInfo ? J(chkInfo) : 'missing');
    ck(chkInfo && /自动分析/.test(chkInfo.label) && /默认关闭/.test(chkInfo.hint), 'A15 开关文案与提示写明默认关闭/只分析本地/切歌取消',
      chkInfo ? chkInfo.label + ' | ' + chkInfo.hint : '');
    const chkOn = await s.eval("(function(){var c=document.getElementById('sp_autoanl');c.checked=true;c.onchange.call(c);return [c.checked, window.ANL.auto, window.ADV.autoanl].join('|');})()");
    ck(chkOn === 'true|1|1', 'A15 勾选后 ANL.auto 与 ADV.autoanl 同步为 1', chkOn);
    const chkOff = await s.eval("(function(){var c=document.getElementById('sp_autoanl');c.checked=false;c.onchange.call(c);return [window.ANL.auto, window.ADV.autoanl].join('|');})()");
    ck(chkOff === '0|0', 'A15 取消勾选后回到 0', chkOff);
    await s.eval("(function(){if(typeof setView==='function')setView('albums');return 1;})()");

    /* ---------------- 状态机：装上假后端 ----------------
       只拦 /api/health 与 /api/anl/*；其余（status/queue/…）转发给原生 api，页面照常运行。 */
    const FAKE_A = '/music/anl-a.flac', FAKE_B = '/music/anl-b.flac';
    await s.eval(`(function(){
      window.__anl = {calls:[], other:[], payload:{}, delay:{}, defaultPayload:null};
      if(!window.__anlOrigApi) window.__anlOrigApi = window.api;
      window.__anl.payload[${J(FAKE_A)}] = {ok:true, usable:true, cached:false, ms:12345, stats:{runs:1,hits:0,cancelled:0,cache:1}, health:${J(H_BASE)}};
      window.__anl.payload[${J(FAKE_B)}] = {ok:true, usable:true, cached:true, ms:2, stats:{runs:1,hits:1,cancelled:0,cache:1}, health:${J(withQ({ dr_db: 7.5, lufs: -9.1, lossless_suspected: true, cutoff_hz: 16000, confidence: 0.81 }))}};
      window.api = function(u, body){
        if (u && u.indexOf('/api/health') === 0){
          window.__anl.calls.push(u);
          var m=/[?&]file=([^&]*)/.exec(u), f=m?decodeURIComponent(m[1]):'';
          var d=window.__anl.delay[f]||0;
          var pl=window.__anl.payload[f]||window.__anl.defaultPayload||{ok:false,error:'no fake'};
          return new Promise(function(res){ setTimeout(function(){ res(pl); }, d); });
        }
        if (u && u.indexOf('/api/anl/') === 0){ window.__anl.other.push(u); return Promise.resolve({ok:true}); }
        // 只为了让 tick 走到「有当前曲目」的分支：证明状态轮询把 (S.lastCur, playing&&!paused) 传给了 anlTick。
        if (u && u.indexOf('/api/status') === 0){
          return Promise.resolve({ok:true, playing:true, paused:false, current:${J(FAKE_A)}, dur:210, pos:5.0, volDb:0, startDb:0});
        }
        return window.__anlOrigApi(u, body);
      };
      return 1;
    })()`);

    // 停掉状态轮询链，保证后面的状态机判据不被真实 /api/status 抢跑（并把挂起的定时器清掉）
    await s.eval(`(function(){
      window.__anlPollSchedule = window.pollSchedule;
      window.pollSchedule = function(){};
      ['t1','t2','t3'].forEach(function(k){ if(window.POLL&&POLL[k]){ clearTimeout(POLL[k]); POLL[k]=0; } });
      POLL.busy={status:false,queue:false,stats:false};
      return 1;
    })()`);
    // 清掉真实 tick 可能刚写进去的“无当前曲目”状态
    await s.eval("(function(){S.lastCur='';S.playing=false;S.paused=false;ANL.cur='';ANL.seq=0;ANL.lvl=0;ANL.auto=0;ANL.autoDone='';ANL.cache={};ANL.meta={};ANL.busy={};ANL.err='';ANL.paintSig='';window.__anl.calls.length=0;window.__anl.other.length=0;anlPaint();return 1;})()");

    /* ---------------- A11：tick 真的把状态接进 anlTick ---------------- */
    const tickSpy = await s.eval(`(function(){
      var orig=window.anlTick, args=[];
      window.anlTick=function(p,a){ args.push([p,a]); };
      return window.tick().then(function(){ window.anlTick=orig; return JSON.stringify(args); });
    })()`);
    ck(tickSpy === J([[FAKE_A, true]]), 'A11 状态轮询调用 anlTick(S.lastCur, playing&&!paused)', tickSpy);
    await s.eval("(function(){ S.lastCur=''; S.playing=false; S.paused=false; return 1; })()");

    /* ---------------- A10：自动分析默认关 ---------------- */
    const offRes = await s.eval(`(function(){
      window.__anl.calls.length=0;
      window.S.lastCur=${J(FAKE_A)}; window.S.playing=true; window.S.paused=false;
      window.ANL.auto=0; window.ANL.autoDone='';
      anlTick(${J(FAKE_A)}, true);
      return window.__anl.calls.length;
    })()`);
    ck(offRes === 0, 'A10 auto=0 时 anlTick(path,true) 不发分析请求', 'calls=' + offRes);

    /* ---------------- A12：自动分析开，只跑一次 ---------------- */
    const auto1 = await s.eval(`(function(){
      window.__anl.calls.length=0;
      window.ANL.auto=1; window.ANL.autoDone=''; window.ANL.cache={}; window.ANL.busy={};
      window.S.lastCur=${J(FAKE_A)}; window.S.playing=true; window.S.paused=false;
      anlTick(${J(FAKE_A)}, true);
      return window.__anl.calls.length;
    })()`);
    ck(auto1 === 1, 'A12 自动分析开：首次 anlTick 恰好触发 1 次请求', 'calls=' + auto1);
    await ub.sleep(250);
    const afterFirst = await s.eval(`(function(){
      return {calls:window.__anl.calls.length, cached:!!window.ANL.cache[${J(FAKE_A)}],
              stat:(document.getElementById('npAnlStat')||{}).textContent,
              body:(document.getElementById('npAnlBody')||{}).textContent||''};
    })()`);
    ck(afterFirst.cached === true, 'A12 结果进 ANL.cache 并重绘（面板用的是真数据）', 'cached=' + afterFirst.cached);
    ck(/分析于 \d{2}:\d{2}/.test(afterFirst.stat) || /缓存命中/.test(afterFirst.stat),
      'A14 完成态状态文字是「分析于 HH:MM」或「… · 缓存命中」', afterFirst.stat);
    ck(/良好动态|素材过短/.test(afterFirst.body), 'A12 面板里出现由 health 推导的摘要', afterFirst.body.trim().slice(0, 80));

    const autoAgain = await s.eval(`(function(){
      window.__anl.calls.length=0;
      anlTick(${J(FAKE_A)}, false);   // 暂停
      anlTick(${J(FAKE_A)}, true);    // 继续
      anlTick(${J(FAKE_A)}, false);   // 拖动进度（同曲，仍在播）
      anlTick(${J(FAKE_A)}, true);
      return window.__anl.calls.length;
    })()`);
    ck(autoAgain === 0, 'A12 暂停/继续/拖动（同一首）不重复分析', 'calls=' + autoAgain);

    const lvlKeep = await s.eval(`(function(){
      anlSetLvl(2);
      anlTick(${J(FAKE_A)}, false);   // 暂停
      anlTick(${J(FAKE_A)}, true);    // 继续
      return window.ANL.lvl;
    })()`);
    ck(lvlKeep === 2, 'A9 暂停/继续（同一首）不会把折叠层级打回 0', 'lvl=' + lvlKeep);
    const hdrClick = await s.eval(`(function(){
      var hd=document.querySelector('#npAnlBody .anlchd'); if(!hd) return 'no-header';
      hd.click();
      return window.ANL.lvl;
    })()`);
    ck(hdrClick === 0, 'A9 点卡片头部同样能推进层级（2 → 0）', 'lvl=' + hdrClick);

    // 缓存命中场景：切到 B（后端说 cached:true）。
    // 生产里切歌那一拍 anlTick 只做「取消旧请求 + 复位」，下一次轮询才起分析 —— 这里照实模拟两拍。
    const bRes = await s.eval(`(function(){
      window.__anl.calls.length=0;
      window.S.lastCur=${J(FAKE_B)};
      anlTick(${J(FAKE_B)}, true);      // 第 1 拍：路径变了
      var first=window.__anl.calls.length;
      anlTick(${J(FAKE_B)}, true);      // 第 2 拍：同曲 + 在播 ⟹ 触发
      return [first, window.__anl.calls.length].join('|');
    })()`);
    await ub.sleep(250);
    const bStat = await s.eval("(document.getElementById('npAnlStat')||{}).textContent");
    ck(bRes === '0|1', 'A12 切歌那一拍只复位，下一拍才起分析（不重复、不漏）', 'calls=' + bRes);
    ck(/缓存命中/.test(bStat), 'A14 「缓存命中」写在状态行里（后端 cached:true）', bStat);

    /* ---------------- A13：切歌取消 + 串台防护 ---------------- */
    await s.eval(`(function(){
      window.__anl.calls.length=0; window.__anl.other.length=0;
      window.ANL.auto=1; window.ANL.autoDone=''; window.ANL.cache={};
      window.__anl.delay[${J(FAKE_A)}]=400;          // 让 A 的分析慢慢回来
      window.S.lastCur=${J(FAKE_A)}; window.S.playing=true; window.S.paused=false;
      anlTick(${J(FAKE_A)}, true);                    // 拍 1：路径变化 → 复位
      anlSetLvl(2);                                   // 用户展开到"全部指标"
      anlTick(${J(FAKE_A)}, true);                    // 拍 2：起分析（在途 400 ms）
      return 1;
    })()`);
    await ub.sleep(40);
    const beforeSwitch = await s.eval("[window.ANL.cur, window.ANL.lvl, window.ANL.seq, window.__anl.calls.length].join('|')");
    const switched = await s.eval(`(function(){
      window.S.lastCur=${J(FAKE_B)};
      anlTick(${J(FAKE_B)}, true);                    // 切歌：取消 A，复位层级
      return [window.ANL.cur, window.ANL.lvl, window.ANL.seq,
              window.__anl.other.filter(function(u){return u.indexOf('/api/anl/cancel')===0;}).length].join('|');
    })()`);
    const b0 = beforeSwitch.split('|'), s0 = switched.split('|');
    ck(b0[3] === '1', 'A13 切歌前 A 的分析确实在途（1 次请求）', beforeSwitch);
    ck(s0[0] === FAKE_B, 'A13 切歌后 ANL.cur 指向新曲目', switched);
    ck(s0[1] === '0', 'A13 切歌后折叠层级复位为 0', 'lvl=' + s0[1]);
    ck(+s0[2] === +b0[2] + 1, 'A13 切歌让 seq 自增（迟到的响应对不上号）', `${b0[2]} → ${s0[2]}`);
    ck(+s0[3] >= 1, 'A13 切歌会 fire-and-forget 调 /api/anl/cancel（让服务器停手）', 'cancel=' + s0[3]);
    // 下一拍把 B 的分析起起来，然后等 A 的迟到响应回来 —— 它必须被丢弃
    await s.eval(`(function(){ anlTick(${J(FAKE_B)}, true); return 1; })()`);
    await ub.sleep(700);
    const late = await s.eval(`(function(){
      return {aCached: !!window.ANL.cache[${J(FAKE_A)}],
              cur: window.ANL.cur,
              bCached: !!window.ANL.cache[${J(FAKE_B)}],
              body:(document.getElementById('npAnlBody')||{}).textContent||''};
    })()`);
    ck(late.aCached === false, 'A13 旧曲目迟到的响应没有写进缓存（不串台）', 'aCached=' + late.aCached);
    ck(late.bCached === true, 'A13 新曲目的结果正常入缓存', 'bCached=' + late.bCached);
    ck(!/良好动态/.test(late.body), 'A13 面板显示的是新曲目的结论（不是 A 的"良好动态"）',
      late.body.trim().slice(0, 90));

    /* ---------------- A18：手动「分析」按钮 ---------------- */
    const runNoTrack = await s.eval(`(function(){
      window.S.lastCur=''; window.ANL.cur='';
      var n0=window.__anl.calls.length;
      anlRunManual();
      return [(document.getElementById('toast')||{}).textContent||'', window.__anl.calls.length===n0].join('|');
    })()`);
    ck(/当前没有可分析的本地曲目/.test(runNoTrack) && /\|true$/.test(runNoTrack),
      'A18 没有本地曲目时点「分析」只提示、不发请求', runNoTrack);

    const runForce = await s.eval(`(function(){
      window.S.lastCur=${J(FAKE_A)}; window.ANL.cur=${J(FAKE_A)};
      window.S.playing=true; window.S.paused=false;
      window.__anl.calls.length=0;
      document.getElementById('npAnlRun').click();
      return JSON.stringify(window.__anl.calls);
    })()`);
    ck(/force=1/.test(runForce), 'A18 手动「分析」走 force=1（忽略服务端缓存）', runForce);
    await ub.sleep(300);

    /* ---------------- A16：几何（1.1.4-beta4 竖栏对称布局） ---------------- */
    const geo = async (w, h) => {
      await s.setViewport(w, h);
      await ub.sleep(220);
      return s.eval(`(function(){
        var g=function(sel){var e=document.querySelector(sel);if(!e)return null;var b=e.getBoundingClientRect();
          return {t:Math.round(b.top),b:Math.round(b.bottom),l:Math.round(b.left),r:Math.round(b.right),h:Math.round(b.height)};};
        var a=document.getElementById('npAnal'), lyr=document.getElementById('npLyric'),
            rail=document.getElementById('npRail'), body=document.querySelector('.npbody');
        var ab=a?a.getBoundingClientRect():null, lb=lyr?lyr.getBoundingClientRect():null,
            rb=body?body.getBoundingClientRect():null, rr=rail?rail.getBoundingClientRect():null;
        return {hero:g('.nphero'), body:g('.npbody'), anl:g('#npAnal'), ctl:g('.npctl2'),
                anlShown: a?getComputedStyle(a).display:'(missing)', vh:innerHeight,
                cards:(document.querySelectorAll('#npAnlBody .anlcard')||[]).length,
                // 左右竖栏等宽（对称）
                sideEq: !!(ab&&rr) && Math.abs(ab.width-rr.width)<=1.5,
                // 歌词中心 == 容器中心（恒居中）
                centerDx: (lb&&rb)?Math.abs((lb.left+lb.width/2)-(rb.left+rb.width/2)):-1,
                // 竖栏铺满行2 高度（不再限高把控制区顶出去）
                anlInBody: !!(ab&&rb) && ab.top>=rb.top-1.5 && ab.bottom<=rb.bottom+1.5};
      })()`);
    };
    for (const [w, h] of [[1024, 640], [1576, 908]]) {
      const g = await geo(w, h);
      const okBox = g && g.anl && g.hero && g.body && g.ctl;
      ck(okBox && g.anlShown !== 'none' && g.anl.h > 0, `A16 ${w}x${h}：#npAnal 可见且有高度`,
        g ? `h=${g.anl && g.anl.h} display=${g.anlShown} cards=${g.cards}` : '');
      ck(okBox && g.hero.b <= g.body.t + 1 && g.body.b <= g.ctl.t + 1,
        `A16 ${w}x${h}：三行互不重叠（左竖栏并入行2）`,
        g ? `hero.b=${g.hero.b} body.b=${g.body.b} ctl.t=${g.ctl.t}` : '');
      ck(okBox && g.anlInBody, `A16 ${w}x${h}：音频分析竖栏铺在行2 内（不额外占行、不顶控制区）`,
        g ? `anlInBody=${g.anlInBody}` : '');
      ck(okBox && g.sideEq, `A16 ${w}x${h}：左右竖栏等宽（对称分布）`, g ? `sideEq=${g.sideEq}` : '');
      ck(okBox && g.centerDx >= 0 && g.centerDx <= 1.5,
        `A16 ${w}x${h}：歌词恒居中（两侧竖栏不影响）`, g ? `centerDx=${g.centerDx}` : '');
      ck(okBox && g.ctl.b <= g.vh, `A16 ${w}x${h}：控制区完整留在视口内（竖栏没有把它顶出去）`,
        g ? `ctl.b=${g.ctl.b} vh=${g.vh}` : '');
      ck(okBox && g.body.h > 0, `A16 ${w}x${h}：歌词行仍分得到高度`, g ? `body.h=${g.body.h}` : '');
    }
    await s.setViewport(1280, 900);
  } finally {
    await s.close();
  }
  console.log(`\n=== 结果：${total} 项，${fail} 失败 ===`);
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => { console.error('FATAL', (e && e.stack) || e); process.exit(2); });
