# EQ 页三处修复（1.1.7.86）

用户 2026-11-15 明确（原话）：**「eq 的效果图无法拖动 没有分 band 然后底下的数据栏会抢滚动焦点
每个界面只允许整个页面滚动 禁止页面中的小页面滚动」**。三条按原话逐条落实。

## 1. 效果图无法拖动

旧实现其实已经有 `mouseDown/mouseDragged` → `applyDragEvent:`，但坐标换算是**写在事件处理里**的一串临时算式：
没有独立判据、也没法在离屏环境验证它到底算对没有（用户看到的就是「拖了没反应」）。

本轮把换算抽成纯函数模块 `tools/native_ui/RLPEQGeometry.{h,mm}`：
- `RLPEQFrequencyForPlotFraction` / `RLPEQPlotFractionForFrequency`（20 Hz..20 kHz 对数轴，3 个十倍频程）
- `RLPEQDbForPlotFraction`（±18 dB，越界夹取）
- `RLPEQNearestBandIndex(freqs, xFraction)`（拖到哪一段）

`applyDragEvent:` 现在只做「取事件坐标 → 归一化 → 查表」三步，并且拖动时记录 `activeBand/activeBandDb` 做高亮。

## 2. 没有分 band

曲线绘制新增两层视觉：
- **频段分隔线**：相邻两段中点画 0.5pt 竖线（20 段太密，画在段中心会糊成栅栏）；
- **每段一个手柄圆点**：位置 = 该段中心频率 × 该段当前增益；拖动中的那段**放大且换主题色**（这
  是「我在调哪一段」唯一的可见反馈）。

拖动改完 `bands[idx][g]` 后同步 `bandGains` 并 `setNeedsDisplay` —— 否则松手后手柄会停在旧位置，
用户会以为没生效（这正是「拖了没反应」的一种成因）。

## 3. 数据栏抢滚动焦点 / 禁止页面内小页面滚动

旧实现的 20 段参数表放在 `NSScrollView` 里（`hasVerticalScroller = NO`，所以看不见滚动条），
**滚轮在表上仍然被这个内层滚动视图吃掉**，整页滚不动。

改法：表格直接铺在 stack 里（高度 = 表头 + 20×26pt），滚轮事件一路交给设置页。

**顺带发现旧审计判据是假绿**：它只数 `hasVerticalScroller || hasHorizontalScroller`，
不显示滚动条的 NSScrollView 照样通过 ⟹ 换成「EQ 页内部不允许存在**任何** NSScrollView」。

## 判据

- 新增 `tests/test_native_eq_geometry.mm`：**13 条**（频率轴往返、±18 dB 量程与夹取、最近段选择、空频段不崩）。
  先红后绿：首轮 E3 FAIL，查证是**我的期望值算错**（1 kHz 在 20..20k 的对数轴上是 0.566，不是 0.65）；改正后 13/13。
- `--audit` 新增/加强 2 条：`EQ 页内部没有任何 NSScrollView`、`EQ 曲线已分 band（20 频点 + 20 增益手柄）`。

## 门禁

- `ctest` **205/205**（新增 `native_eq_geometry`，原 204）。
- `rlplayer_native --audit` **247/0**（原 246，+1 条分 band 判据）。
- parity `missing=0`、behavior `actionable=0`、i18n 0 缺失。

## ⚠️ 未验证

**未真机拖动验证**：判据证明的是「坐标换算正确 + 视图树里没有内层滚动 + 20 段手柄数据齐备」，
真正的手感（拖动跟手、松手下发、20 段的分隔线密不密）需要你在设置 → EQ 页实测。