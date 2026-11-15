# v3.3.11 音量旋钮本体 `npVolKnob`（1.1.7.71）

> 待移植清单最后一项功能：「音量旋钮本体」。

## 1. 上游真值（tag v3.3.11）

| 层 | 内容 |
|---|---|
| HTML `ui_page.h:1581` | `#npVolKnob` 是 64×64 圆盘：track 弧（r=24）+ 刻度组 + 值弧 + 中心 cap（r=20）+ 静音键（居中 28×28）+ 读数；配套的 `#npVol` range 是 **sr-only**（视觉上不存在） |
| CSS `ui_page.h:1305-1322` | 圆盘 64×64；track stroke 4、值弧 stroke 4 圆头；刻度 minor 1.2/opacity .65、major 1.7/.95；cap bg2 填充 + 1px line 边；锁定态 opacity .45 |
| 常量 `ui_script.h:6218` | `VOL_MIN=-120 VOL_MAX=20`，`volClamp` 四舍五入到 0.1 dB |
| 映射 `ui_script.h:6221-6231` | `volDbToNorm` / `volNormToDb`：**以 0 dB 为圆心的对称指数曲线**（0→0.5，两端各自铺满半弧） |
| 几何 `ui_script.h:6235-6246` | `rlVolPoint(norm,r)`：角度 `= (-135 + 270·norm - 90)°`；**`large-arc-flag = (270·norm > 180)`，阈值 2/3** |
| 绘制 `ui_script.h:6247-6266` | 刻度表 `RL_VOL_TICKS = [-120,-60,-30,-18,-12,-9,-6,-3,0,3,6,12,20]`，major 为 -120/-60/-12/0/6/12/20，半径 major 29.2→25.8、minor 28.4→26.6 |
| 拖动 `rlBindVolumeKnob` | 角度 = `atan2(x-cx, cy-y)`，夹到 ±135°，norm=(deg+135)/270；按下才拖、抬手提交、rAF 合并 |

## 2. 历史事故（本包判据的两个核心锚点）

1. **弧线错位（3.3.10 用户反馈「音量弧线仍然偏移」）**：旧代码用 `norm > 0.5`（扫角 135°）判大弧，
   于是 0 dB 附近（norm≈0.53）被画成 216° 大弧、绕到左下角，看起来「弧线跑到圈外、与刻度不同心」。
   正确阈值是 **180/270 = 2/3**。判据 K4b 专门钉住这一点。
2. **拖到中间没声音（web 2026-10-25 事故）**：音量刻度若用线性 dB，中点 = -30 dB（约 3% 振幅）。
   上游因此用对称指数曲线（0 dB 在正上方）。判据 K7/K8 钉住映射两端与中点。

## 3. 实现（本仓）

新增两个文件，纯几何 + 视图分离，**不复制第二份映射**：

| 文件 | 内容 |
|---|---|
| `tools/native_ui/RLPVolumeKnobView.h` | 纯 C 函数：`RLPVolClampDb` / `RLPVolDbToNorm` / `RLPVolNormToDb` / `RLPVolKnobPoint` / `RLPVolKnobArcIsLarge` / `RLPVolKnobArcPath` / `RLPVolKnobTickDbs` / `RLPVolKnobTickIsMajor` / `RLPVolKnobDbFromAngleDegrees`；视图 `RLPVolumeKnobView` |
| `tools/native_ui/RLPVolumeKnobView.mm` | 绘制（圆盘/轨道弧/刻度/值弧/中心盖/锁定置灰）+ 拖动（mouseDown/Dragged/Up）+ `dragToPointForAudit:` 判据入口 |

接入播放页控制栏（`RLPNowPlayingViewController.mm`）：

- 新增 `volKnob`（identifier **`npVolKnob`**），取代可见滑块的位置；滑块 `hidden = YES`
  但仍作状态载体（`applyVolumeDb:` 继续同步它，既有判据不破）。
- 静音键 `npVolFloor` 移到旋钮圆盖中心（对齐 web：静音键在圆盘中心，28×28）。
- 拖动中走新入口 `updateVolumeUiForDb:`（只同步标签/精确输入/滑块/旋钮，**不下发**）；
  松开走 `applyVolumeDb:`（下发 `/api/volume?db=` 并同步全部控件）。
- 主题切换时旋钮 `needsDisplay`，与其它控件同一帧刷新。

## 4. 红 → 绿（新测试 `test_native_volume_knob.mm`，K1–K10）

| 判据 | 钉住什么 |
|---|---|
| K1/K2/K3 | 三点几何：norm 0 → (15.03, 48.97)、0.5 → 正上方 (32,8)、1 → (48.97,48.97)，与 web 轨道端点同值 |
| K4a-c | 小弧：norm 0.5 / **0.53（0 dB 附近）** / 0.666 都不是大弧 |
| K5a-b | 大弧：norm 0.68 / 1.0 |
| K6 | norm=0 时弧为空（不画零长度弧） |
| K7a-e | 0 dB ⟹ norm 0.5；-120/+20 ⟹ 0/1；**互逆误差 ≤ 0.1 dB** |
| K8a-e | 角度映射：0°⟹0 dB、±135°⟹端点、超圈被夹、**NaN 不产生 NaN dB** |
| K9a-b | 刻度表逐项等于 `RL_VOL_TICKS`；major 判定一致 |
| K10a-e | 视图行为：拖动改值、实时回调、**拖动中不提交**、锁定后不可拖、越界赋值被夹 |

**红阶段说明（如实）**：本次新组件是**先从零建起**，没有"旧实现"可对照，
因此红证据的形式是**逐条判据先在未实现状态下失败**（第 3 节列出的 26 条在文件建立前必然不存在），
而不是像移植类判据那样"旧码有、新码才有"。为避免假绿，两处最容易写错的地方（K4b 大弧阈值、
K8e NaN）都在实现里单独写了注释说明为何是那个值，并各自对应一次真实事故。

结果：`测试 native_volume_knob：26 passed, 0 failed`；接入后 `np web: 0 failures`、
`native_bar_web: 348 checks, 0 failures`。

## 5. 与 web 的差异（如实挂账）

1. **尺寸**：web 圆盘 64×64；原生控制栏行高约 40pt，旋钮取 `min(40, H-22)`（≥28）。
   比 web 小 —— 这是行高约束下的必要差异，不是设计选择。
2. **静音键 22×22**（web 28×28）：受上面更小的圆盘限制，避免盖住刻度；标识仍为 `npVolFloor`。
3. **拖动期间不下发请求**：web 每帧 `setVol` 都打 `/api/volume`（rAF 合并到 ~60/s）；
   原生沿用既有「松开才提交」纪律（与底栏滑块一致）。手感更稳，但与 web 的实时下发不同。
4. **读数 `.rlVolVal` 在 web 是 `display:none`**（不显示），原生同样不画读数，靠右侧
   `npVolLab` 与精确输入框显示数值 —— 与 web 一致。
5. **未做辅助功能语义**：web 有 `role=slider` + `aria-valuemin/max/now/valuetext`；
   原生没接 NSAccessibility（与其它原生控件现状一致）。
6. **底栏旋钮未做**：web 底栏也有一个 `#volKnob`；本包只做了播放页 `#npVolKnob`。
   底栏仍用滑块（判据 348 项保持全绿）。
