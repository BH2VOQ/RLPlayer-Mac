# v3.3.11 底栏音量旋钮 `volKnob`（1.1.7.72）

> 待移植清单「音量旋钮」组的底栏部分（播放页 `npVolKnob` 见 `native-volume-knob-20261115.md`，1.1.7.71）。

## 1. 上游真值（tag v3.3.11）

| 元素 | 内容 |
|---|---|
| `ui_page.h:1501` | 底栏 `#volKnob`：与播放页同构的 64×64 圆盘（track 弧 + 刻度 + 值弧 + 中心 cap + 居中静音键 `volFloor`） |
| `ui_page.h:1502` | `#vol` range **sr-only**（`class=rlSrOnly`，视觉上不存在） |
| `ui_page.h:1498/1503` | 另有 `volumePending`（未读提示）与 `barVolInput` 精确 dB 输入 |

## 2. 本轮发现的上游差异（这不是"加个控件"，是纠错）

原生日志与判据一直宣称底栏音量用「web 冻结的 `volPosToDb`（-55·(1-p)^1.6）曲线」，
并在 `test_native_bar_web` 里专门锁住它。但核对 v3.3.11 后发现：

```
grep -c volPosToDb /tmp/rlp2-v3311/ui_script.h   →  0
```

**上游 v3.3.11 已不再有任何地方使用位置曲线**；音量唯一映射是 `volDbToNorm` / `volNormToDb`
（以 0 dB 为圆心的对称指数，两端 -120/+20）。也就是说原生底栏此前守的是一条
**上游已删除的曲线**，同一个 dB 在两个界面会落在不同位置。

## 3. 实现

| 项 | 做法 |
|---|---|
| 新增控件 | `volKnob`（`RLPVolumeKnobView`，identifier `volKnob`），复用播放页同一份组件 |
| 旧滑块 | `self.volume` 保留为**状态载体**但 `hidden = YES`（对齐 web `#vol` 的 sr-only） |
| 下发路径 | 新增 `commitVolumeDb:` —— 旋钮 dB 经 `RLPVolClampDb` 后原样下发 `/api/volume?db=`；不再经过 -55 曲线换算 |
| 拖动中 | 新增 `updateVolumeUiForDb:` —— 只同步界面（旋钮 + 滑块载体），不下发 |
| 状态回填 | `fetchStatus` 里 `volKnob.db = st.volumeDb`，旋钮是可见真值 |
| 布局 | 右侧控制簇改为**右对齐**（web status 簇 flex-end）：旋钮是方形、比原滑块槽窄，左对齐会在条右端留下多出 20pt 的空白 |
| 尺寸 | `knobS = wrap ? 22 : min(36, H-18)` —— wrap 模式右簇拆两行、行中心仅 13pt，36pt 方形会顶出条外 |

## 4. 判据（`test_native_bar_web`，350 项全绿）

被改写的既有判据（**并说明为什么这是纠错而不是放宽**）：

| 判据 | 改动 |
|---|---|
| 「custom theme-colored slider cell」 | → 「`volKnob` 存在」+「旧滑块已隐藏（web `#vol` 是 sr-only）」 |
| 「volume curve matches frozen web including true silent notch」 | → 「v3.3.11 音量：旋钮 dB 原样下发（-120 真静音 / 0 dB / 负值 / +20 上限）」—— 旧判据守的曲线上游已删除 |
| 「drawn slider fill uses web accent」 | → 「旋钮有真实可见尺寸」+「旋钮槽位是方形」 （accent 值弧的色彩断言由 `test_native_volume_knob` 覆盖同一份实现） |
| 右侧簇列表 / 右端留白基准 | `volume` → `volKnob`；留白判据改以旋钮右缘为准 |

未被放宽的两条布局判据（正是它们抓出了真实缺陷）：
- 「626pt 条内所有控件都在界内」——第一次接线时 36pt 方形在 wrap 行顶出条外，被判据抓到；
- 「左右两端留白差 ≤2pt」——左对齐时右端多出 20pt，被判据抓到，改为右对齐后通过。

## 5. 如实挂账

1. **底栏静音键 `volFloor` 未做**：上游底栏旋钮中心也有静音键；原生底栏没有，播放页有（`npVolFloor`）。
2. **`barVolInput` 精确 dB 输入未做**：上游底栏有 `type=number` 的精确输入；原生播放页有 `npVolInput`，底栏没有。
3. **`volumePending`（音量尚未读取提示）未做**：属播放设置闸门那一组，已判定为架构 N/A（`native-playback-settings-na-20261115.md`）。
4. 拖动期间不下发请求（沿用原生「松开才提交」纪律，web 每帧下发），同播放页。
5. 底栏旋钮未接 NSAccessibility（与其它原生控件现状一致）。

## 6. 门禁记录（含一次瞬时失败，如实记录）

| 轮次 | 结果 |
|---|---|
| 首次 `ctest` | **2 项失败**：`native_bar_core (Not Run)`、`library (Failed)` |
| 直接运行两者 | `native_bar_core` 12 passed / 0 failed；`library` 全部通过 |
| `ctest -R` 复跑两者 | 4/4 通过（含 library_fingerprint、library_probe_retry） |
| 全量复跑 | **203/203 通过**（380.58s） |

判定：两条都是**瞬时失败**（`Not Run` = ctest 取二进制与链接落盘撞车；`library` 为环境敏感项），
不是本次改动引入的回归 —— 同一二进制单独跑、复跑、全量复跑均通过。首次失败已如实留在
`evidence/native-72-ctest.log` 的历次输出里，没有改日志掩盖。

