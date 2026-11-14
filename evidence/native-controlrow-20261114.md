# 控制区逐值（1.1.7.44，按对照表 #48/#49/#56）

## 包 2（1.1.7.44，P2）：控制区逐值（`#npSeek` hover / `.nptime` / `.npvol`）

### 差异（对照表 #48 / #49 / #56）
- `#npSeek`：web `.npseek{height:5px}`、`.npseek:hover{height:7px}`；原生轨道恒 5pt（无 hover 响应）。
- `.nptime{font-size:12px}`、`.tval{min-width:42px;text-align:center}`；原生 **11pt / 46pt 宽**、当前值右对齐、
  总时长左对齐（`.tsep{margin:0 1px;min-width:10px}`）。
- `.npvol{display:flex;gap:8px}` + `input[type=range]{width:104px}` + `.vlab{font-size:11px;min-width:58px;text-align:right}`；
  原生滑杆 **118pt**、标签 **56pt / 10.5pt**、gap 6。

### 判据（`tests/test_native_nowplaying_web.mm` 追加 15 条）
量**实际视图**尺寸/字号/对齐（±0.3~1pt）：
1. seek cell 暴露 `barThickness`：默认 5pt、`hovered=YES` 时 7pt；
2. seek 有 hover 跟踪区（`hoverGrow` + `trackingAreas≥1`，证明不是只有属性没响应）；
3. `np.pos` / `np.dur`：字号 12、宽 42、居中；
4. `np.vol` 滑杆宽 104、`np.vollab` 字号 11 / 宽 58 / 右对齐。

### 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.43） | 15 条里 **10 FAIL**（`barThickness` 不存在，3 条 hover 子判据因前提缺失跳过；时间 11pt/46 宽/右左对齐、音量 118/56/10.5） |
| 新码 | **75 passed / 0 failures**（60 条既有 + 15 条新） |

证据：`evidence/native-controlrow-{red,green}-20261114.log`。

### 实现
- `RLPNPAccentCell` 新增 `hovered` + `barThickness`（5/7pt），`drawBarInside` 用该值画轨道与圆角（半径=厚度/2）；
- `RLPNPSlider` 新增 `hoverGrow` + 跟踪区（`NSTrackingMouseEnteredAndExited|ActiveInKeyWindow|InVisibleRect`），
  `mouseEntered/Exited` 只对 seek 切换 `hovered`；拖动提交逻辑不变；
- `.nptime`：时间字体 `monospacedDigit 12pt`、两个 `.tval` 宽 42 且居中、`.tsep` 10 宽 + 1pt 间距；
- `.npvol`：滑杆 104、标签 58/11pt、图标与滑杆间距 8（保留窄窗收缩兜底）。
