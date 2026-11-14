# 歌词视口 26pt 上下渐隐遮罩（1.1.7.52，表 #40）

## web 值（`src/net/ui_page.h:856`）
```
.nplyric2{...;
  -webkit-mask-image:linear-gradient(180deg,transparent 0,#000 26px,#000 calc(100% - 26px),transparent 100%);
  mask-image:linear-gradient(180deg,transparent 0,#000 26px,#000 calc(100% - 26px),transparent 100%)}
```
即：视口**顶部 0→26px** 由透明渐变到不透明、底部最后 26px 再渐隐到透明；中间全显示。

## 原生 1.1.7.51
`lyricScroll` 没有任何 mask：长歌词滚到首/末行时是**硬切**（行被视口边缘一刀切掉），
与 web 的渐隐观感不同（web 里首/末行淡出，不会被"切"）。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 8 条）
1. `lyricScroll.layer.mask` 是 `CAGradientLayer`（不是只写注释）；
2. 四个色标：首/尾 alpha≈0、中段两个 alpha≈1；
3. locations 覆盖 0→1；
4. 第二/三色标 = **26/H** 与 **1-26/H**（26pt 与视口高度成比例，不是固定常量）；
5. 遮罩尺寸 = 视口 bounds；
6. 窗口变矮（760→640）后 26pt 对应的 location **重算**（不是一次性值）；
7. 复位回 760 后仍正确；
8. 判据全部读真实 `CAGradientLayer` 属性（colors/locations/frame），不靠 drawRect 常量自证。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.51） | **1 FAIL**（遮罩缺失，后续 7 条被跳过） |
| 新码 | **158 passed / 0 failures**（150 既有 + 8 遮罩判据） |

## 实现
- `updateLyricFadeMask`：`lyricScroll.wantsLayer=YES`；首次创建 `CAGradientLayer`（colors 透明/黑/黑/透明，
  `startPoint=(0.5,1)`、`endPoint=(0.5,0)`：非翻转坐标从顶到底），之后每次布局更新 `frame=bounds` 与
  `locations=[0, 26/H, 1-26/H, 1]`（H<52 时中段夹到 0.5 防止反序）。
- `layoutWebPlayback` 设完 `lyricScroll.frame` 后调用，窗口高度变化即重算。
- 遮罩挂在**滚动视图**上（不是 document）：滚动时渐隐区固定在视口边缘（与 web 的 `.nplyric2` 相同）。
- 遮罩不影响行盒/滚动几何，也不新增 NSScrollView（单层滚动判据不变）。

## 如实挂账
1. 遮罩是 26pt 固定像素（web 同）；高 DPI 下 CALayer 用点坐标，视觉一致。
2. 未做 web 的 `::-webkit-scrollbar{display:none}` 以外的滚动条样式（原生本来 hasVerticalScroller=NO）。
3. 若后续歌词行高改成非 2.05 倍（clamp 已定），渐隐区仍按 26pt，不随字号缩放——web 同样是固定 26px。
