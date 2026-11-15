# rail 收起键 `npRailHide` 的边距与居中（1.1.7.80）

> 收口上一包（1.1.7.78 border-box 修正）后**新暴露**的一处几何差：收起键仍按旧的 8pt 边距放。

## 1. 上游真值

```css
.nprailcard{ padding:10px; border:1px solid …; box-sizing:border-box }   /* 内容内缘 = 11 */
.nprailhead{ display:flex; align-items:center; gap:8px }                 /* 一行，垂直居中 */
.nprailhide{ width:22px; height:22px; border-radius:50%; flex:none }      /* 行尾子项 */
```

⟹ 收起键（22×22）在 24pt 高的行里**垂直居中**，右缘贴内容内缘：

| 量 | web |
|---|---|
| 右端距面板内缘 | **11**（= padding 10 + border 1） |
| 顶端距面板内缘 | **12**（= 11 + (24 − 22)/2） |

## 2. 原状

```objc
self.railHide.frame = NSMakeRect(side - 8.0 - 22.0, bodyH - padTop - segH, 22.0, 22.0);
```

右端留 **8pt**（早期实测值，比 web 的 11 少 3pt），顶端与 24pt 行**齐平**（13pt，web 是居中 12pt）。
1.1.7.78 把内缩改成 11 之后，这个 8 就更加显眼 —— 说明**常量化的几何没有统一走同一个来源**。

## 3. 修法

```objc
const CGFloat railHideY = bodyH - kRailHeadPadTop - railSegH + (railSegH - 22.0) / 2.0;
NSMakeRect(side - kRailHeadPadX - 22.0, railHideY, 22.0, 22.0)
```

两个轴都改走 `kRailHeadPadX` / `kRailHeadPadTop`，不再写死数字。

## 4. 判据（`test_native_nowplaying_web`，233 checks / 0 failures）

| 判据 | 期望 | 说明 |
|---|---|---|
| 右端距面板内缘 | **11 ± 1** | 与 rail 卡片同源常量；旧值 8 会失败 |
| 顶端距面板内缘 | **12 ± 1** | 行内居中；与行顶齐平的 13 会失败 |

两条新增判据都是**先量后写**：第一次跑出 `got 13.0`（齐平），据此判定"应对齐行中心而不是行顶"，然后才改实现 ——
不是把期望值调成观测值。

## 5. 如实挂账

1. `.nprailhead` 的行高（24pt）来自分段控件，本轮沿用；若分段控件换尺寸，收起键会跟着居中但 12pt 期望值需同步。
2. 收起键的悬停态（`.nprailhide:hover{background:var(--hov2)}`）早已实现（另有判据），本轮未动。
3. 未做真机像素比对。