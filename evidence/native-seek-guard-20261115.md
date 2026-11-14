# v3.3.11 `doSeek` 守卫 + 精度（1.1.7.70）

> 待移植清单「波形 / 传输进度」组的**可聚焦部分**。
> `npWaveform`（真波形）判定为超出小范围改动，只读评估见第 5 节。

## 1. 上游真值（`/tmp/rlp2-v3311/ui_script.h:6572-6579`）

```js
function doSeek(frac) {
  if (!S.playing || !(S.dur > 0) || !Number.isFinite(frac)) return;
  var f = Math.max(0, Math.min(0.9999, frac));
  api('/api/seek?pos=' + f.toFixed(4), '');
  lyricReposition();
  if (D('npPage') && D('npPage').classList.contains('on')) renderNpLyric();
  if (RTAB === 'l') syncLyrics(f * (S.dur || 0));
}
function seekRel(d) { if (!S.dur || S.dur <= 0) return; doSeek((S.pos + d) / S.dur); }
```

三条守卫各自的理由：

| 守卫 | 为什么 |
|---|---|
| `!S.playing ⟹ return` | 未播放时 seek 后端必然拒绝；发出去只会在状态栏闪一个失败 |
| `!(S.dur > 0) ⟹ return` | 时长未知（尚未拿到 `/api/status` 的 `dur`）时，任何比例都没有意义 |
| `!Number.isFinite(frac) ⟹ return` | 除零等异常值不能进 URL |
| `clamp [0, 0.9999]` | 上界故意**不是 1.0**：pos=1.0 会让后端精确跳到文件末尾，等于直接停住 |
| `toFixed(4)` | 后端 pos 是比例，4 位小数足够（URL 更短） |

## 2. 本仓旧码（缺陷）

```objc
- (void)onCommitSeek:(id)s {if(self.webControls.seek.dragging)return;[[RLPCoreClient shared]
    postJSON:[NSString stringWithFormat:@"/api/seek?pos=%.6f",self.webControls.seek.doubleValue]
    body:nil completion:nil];self.lyricManualUntil=0;}
```

一处单行实现，**三条守卫一条都没有**：

1. 未播放 / 时长 0 时照发 —— 后端拒绝，用户看到一次无意义的失败；
2. 拖到轨道最右（`doubleValue == 1.0`）时发 `pos=1.000000`，后端跳到文件末尾；
3. 精度 `%.6f`，与上游 `toFixed(4)` 不一致（同一操作在两个前端产生不同 URL）。

## 3. 实现

判据按上游逐条：`!st.playing` / `!(st.duration > 0)` / `!isfinite(raw)` 任一成立即 return；
否则 `fmin(0.9999, fmax(0.0, raw))` 后以 `%.4f` 下发；随后 `lyricManualUntil = 0`。

歌词手动滚动保护（`lyricManualUntil = 0`）在旧码里**已经有**，本包保留未动 ——
它对应上游 `lyricReposition()`，不是新功能。

## 4. 红 → 绿（`test_native_nowplaying_web.mm` 新增 S1–S4）

| 判据 | 旧码 | 新码 |
|---|---|---|
| S1a 未播放时不发 seek | **FAIL** | PASS |
| S1b 时长 0 时不发 seek | **FAIL** | PASS |
| S2 `pos=1.0` clamp 到 `0.9999` | **FAIL** | PASS |
| S3 负值 clamp 到 `0.0000` | **FAIL** | PASS |
| S4 正常值按 `toFixed(4)` 精度下发 | **FAIL** | PASS |
| 既有判据 `seek uses real backend pos parameter` | **FAIL**（仍断言 6 位小数） | PASS |

| 轮次 | 结果 | 证据 |
|---|---|---|
| 红 | build 0 error；**5 FAIL** | `evidence/native-seek-guard-red-20261115.log` |
| 绿（1.1.7.70） | build 0 error；`np web: 0 failures` | `evidence/native-seek-guard-green-20261115.log` |

**如实记录**：既有那条判据在绿阶段先红了 —— 它写的是 `pos=0.500000`（6 位），
而本包按上游改成 4 位。**这是判据随实现意图更新，不是放宽判据**：精度本身就是本次移植的目标，
保留 6 位等于没移植 `toFixed(4)`。

## 5. `npWaveform`（真波形）—— 超出小范围改动，只读评估

上游不是「加一条进度条」，而是**一整套子系统**：

| 组成 | 规模 |
|---|---|
| `src/analysis/waveform.h` | 峰值包络（≤4096 箱、双声道配对保峰）、ffmpeg 管道、DSD/DVD-A MLP 分支、取消、5 分钟上限 |
| 缓存格式 | `RLW336v1` 二进制 + FNV-1a 键 + 原子替换 + 256 KiB 上限校验 |
| 后台 worker | 单线程队列、`pending/ready/error` 三态、代际取消、源变更检测、32 条 LRU |
| 端点 | `/api/waveform?file=&clip_start=&clip_length=&fresh=`（仅 GET；405/400 分支齐全） |
| 前端 | `src/net/ui_waveform.h`（18.7 KB）Canvas 波形 + 点击 seek + CUE 区间 + 停播禁用 |

本仓现状：`grep -c 'api/waveform' tools/rtaweb.cpp` = **0**，`src/analysis/` 下无波形模块。
落地需要：新分析模块（解码接线）+ 缓存/worker + 新端点 + AppKit 绘制（Canvas 等价物）。
这是**跨三个模块的新子系统**，不是「加个可选字段」级别；按 Ticket scope 规则属于需单独排期的工作，
本轮不做，如实挂账。

替代现状（不是空着）：`np.seek` 滑块 + `npPos/npDur` 时间标签 + 本包的守卫与精度 ——
播放页的进度**功能**已完整（web 的波形是同一功能的**可视化增强**）。

## 6. 如实挂账

1. **`npWaveform` 未做**（见第 5 节，需独立排期）。
2. 波形不做时，上游 `npTransportSeek` 的两条副产物无落地对象：`aria-valuetext`
   （原生无对应辅助功能标签体系）、`syncLyrics(f*dur)`（原生歌词按自己 tick 重定位，
   `lyricManualUntil=0` 已达同一效果）。
3. 未验证真机拖拽手感（离屏判据只覆盖请求语义与数值范围）。
