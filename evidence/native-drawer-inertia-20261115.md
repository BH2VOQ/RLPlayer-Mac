# 抽屉 blur + 滑入 / chipwrap 惯性滚动（1.1.7.61）

> 关闭 `evidence/native-known-deviations-20261114.md` #5 / #11 与用户清单 #6 / #8。
> 方向：骨架与语言不动，继续补 AppKit UI（不依赖任何新后端端点）。

## 1. web 真值

| 项 | web (`src/net/ui_page.h`) |
|---|---|
| 遮罩 | `.npdrawerbg{background:rgba(0,0,0,.30); -webkit-backdrop-filter:blur(2px); backdrop-filter:blur(2px); transition:opacity .22s}` |
| 抽屉 | `.npdrawer{transform:translateX(calc(100% + 26px)); opacity:0; transition:transform .26s cubic-bezier(.2,.8,.2,1),opacity .18s ease,visibility .26s}`；`.on{transform:none;opacity:1}` |
| 滚动 | `.npchipwrap{overflow:auto;scrollbar-width:thin}` 由 WKWebView/Chromium 提供原生惯性 |

## 2. 旧原生（1.1.7.60 及以前）

- `RLPOverlayBackdrop` 是纯 `NSView` + `layer.backgroundColor = rgba(0,0,0,.30)`，**无模糊**。
- `openDataDrawer` 直接把 `frame` 放到终点，只做 0.18s alpha 淡入，**无滑入**。
- `RLPRailWrapView.scrollWheel:` 只把 `scrollingDeltaY` 一次性转成 `contentOffset`，**无惯性**。

## 3. 实现（1.1.7.61）

| 项 | 做法 | 为什么 |
|---|---|---|
| 遮罩模糊 | 新增 `RLPBlurView : NSVisualEffectView`（`HUDWindow` 材质、`WithinWindow` 混合、`Active`、`identifier=npDrawerBlur`），作为 `RLPOverlayBackdrop` 子视图；`hitTest:` 返回 nil 让点击穿透 | AppKit 无 `backdrop-filter`；30% 黑仍由遮罩 layer 承担 |
| 滑入 | `openDataDrawer` 加 `CABasicAnimation(keyPath=transform.translation.x)`，`from = drawerW+26`、`to=0`、`duration=0.26`、timingFunction `cubic-bezier(.2,.8,.2,1)`；**frame 始终在终点**，只动 presentation layer | 离屏判据量的是确定性 `frame`；动画若改 model frame 会让「抽屉宽/right/bottom 14」判据随帧漂移 |
| 关闭 | `closeDataDrawer` `removeAnimationForKey:@"npDrawerSlide"` | 下次打开重新挂动画 |
| 惯性 | 纯函数 `RLPRailMomentumStep(v,&out)`：每帧 ×0.90、<8pt/s 收敛到 0，位移 = v/60；`RLPRailWrapView` 新增 `momentumVelocity` / `momentumTimer` / `beginMomentumWithVelocity:` / `momentumTick:` / `stopMomentum` | 自绘容器不引入 `NSScrollView`，自己补 web `overflow:auto` 的惯性；纯函数可离屏判据 |
| wheel 分流 | `momentumPhase != None`（系统惯性阶段）按普通位移处理且不叠加自绘惯性；离散滚轮按 `-dy*12` 估初速启动阻尼惯性 | 避免触摸板上双重惯性叠加 |
| timer 门控 | `beginMomentumWithVelocity:` 只在 `self.window != nil` 时挂 `NSTimer`；`dealloc` invalidate | 离屏判据直接调 `momentumTick:` 驱动，不依赖 runloop |

## 4. 红 → 绿（`test_native_nowplaying_web.mm` 新增 5 条判据）

| 判据 | 旧码 | 新码 |
|---|---|---|
| `beginMomentumWithVelocity:` 入口存在 | FAIL | PASS |
| 惯性位移有限且单调（>10pt 且 <2000pt） | 跳过 | PASS |
| 惯性速度衰减到 0（自动停止） | 跳过 | PASS |
| `npDrawerBg` 含 `NSVisualEffectView` 模糊层 | FAIL | PASS |
| 抽屉 0.26s `transform` 滑入动画 + model frame 不变 | FAIL | PASS |

| 轮次 | 结果 | 证据 |
|---|---|---|
| 旧码（仅判据） | build 0 error；**3 FAIL**（惯性入口 / blur 层 / 滑入动画） | `evidence/native-drawer-inertia-red-20261115.log` |
| 新码（1.1.7.61） | build 0 error；5 项相关 ctest 全绿 | `evidence/native-drawer-inertia-green-20261115.log` |

**判据修正记录**：惯性位移首轮得 0 —— `momentumTick` 会触发 `railLayoutChips` 重算
`contentHeight` 为不溢出值，`contentOffset` 被 `setContentOffset:` 夹回 0。已按既有
chipwrap 判据同口径，在每帧后把 `contentHeight` 恢复为 1200（模拟真实溢出）。
这是判据前置条件缺失，不是改阈值放水。

## 5. 如实挂账

- `NSVisualEffectView` 材质是系统固定模糊强度，**半径不等于 CSS 的 2px**；行为（遮罩模糊 +
  30% 黑）对齐，像素级不等价。
- 滑入只做 `transform`，未复刻 `visibility .26s` 的延迟显隐；抽屉 `masksToBounds=NO`
  保留（CSS `overflow:hidden` 不裁 box-shadow，见 #5 旧记录）。
- 惯性是 0.90 阻尼近似，不是 AppKit/CoreAnimation 的原生动量曲线；`momentumPhase`
  阶段不叠加自绘惯性，避免触摸板双份滚动。
- 抽屉/惯性均**离屏判据验证**，未做实机肉眼验收（由用户执行）。
