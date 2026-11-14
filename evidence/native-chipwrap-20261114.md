# `.npchipwrap` 自绘滚动（1.1.7.53，表 #69）

## web 值（`src/net/ui_page.h:747-749`）
```
.npchipwrap{display:flex;flex-direction:column;align-items:stretch;gap:6px;min-height:0;
            flex:1 1 auto;overflow:auto;scrollbar-width:thin}
.npchipwrap::-webkit-scrollbar{width:6px}
.npchipwrap::-webkit-scrollbar-thumb{background:var(--line);border-radius:3px}
```
即：芯片卡区是**独立滚动区**（栏头/分段固定，只有卡片滚）；滚动条 6px 画在区域右缘。

## 原生 1.1.7.52
`railCards` 直接铺在 `railPanel` 上、从栏头下方依次排（栏头固定、卡片多时溢出面板/没有滚动），
没有独立滚动容器；卡片少时视觉等价，多时就会顶出面板。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 11 条）
1. 存在 `npChipWrap` 且**不是 NSScrollView**（不引入嵌套滚动）；
2. `railPanel` 子树内 `NSScrollView` 数量 == 0（「单层滚动」仍成立）；
3. 三张 chip 的 superview == wrap（不是直接铺面板）；
4. 卡宽 = wrap 宽 − 19（13pt 留白 + 6pt 拇指条）；
5. 设 `contentOffset=150` 后卡片整体上移 150（真实位移，不是只改属性）；
6. 栏头 `railTitle` 的 y **不随卡片滚动改变**；
7. 内容溢出时 `scrollThumbRect` 非空；
8. 拇指与卡片右缘 ≥13pt（不压卡片圆角）；
9. 拇指在 wrap 右缘沟槽内；
10. 内容不溢出时拇指为空（不常驻）；
11. 判据全部读真实 frame/thumb 矩形，不靠 drawRect 常量自证。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.52） | **1 FAIL**（无 npChipWrap；后续判据跳过） |
| 新码 | **173 passed / 0 failures**（158 既有 + 11 新 + 前提） |

## 实现
- 新 `RLPRailWrapView : NSView`（**不是 NSScrollView**）：`contentHeight/contentOffset` + `scrollWheel` 回调 +
  `drawRect` 6pt 拇指（右侧 6pt 沟槽）。
- `buildContent`：wrap `identifier=npChipWrap`、`masksToBounds`，三张 chip 挂到 wrap 里；
  `onScrollDelta` 改 offset、`onOffsetChanged` 调 `railLayoutChips`。
- `layoutWebPlayback`：wrap frame = 栏头之下、栏底（有 hint 时 34、否则 10）之上；栏头/分段/收起键坐标不变。
- `railLayoutChips`：卡宽 = wrap 宽−19；从顶部按 contentOffset 排；contentHeight = 卡片高总和 + 6×间隔。
- 空态（`.nprailempty`）仍是 wrap 隐藏 + 面板内说明文字（与 web 的 `.nprailempty` 同位置）。

## 同步更新的既有判据（`native_rail_cards` / `native_rail_states`）
卡片从 railPanel 直挂改为在 `.npchipwrap` 内（web 结构），两处判据同步修改并披露差因：
- 卡片发现改为**递归**找 `npChip.歌曲/专辑/艺术家`（排除卡内 `npChip.dot/name/st/p1/p2`）；
- 几何一律 `convertRect:toView:rail`（卡片 frame 现在是 wrap 局部坐标）；
- `rail.card.width`：`railW-20` → **`railW-39`**（右侧常驻 19pt = 13 留白 + 6 拇指条；
  web 该处是 ~11px 滚动条占位，原生多留 8pt 保证"滚动条不压圆角"，与 #28 同一取舍）；
- `rail.padX.right`：10 → **29**（同一差因）。
严格说这是**与 web 的已知宽度偏差**（chips 比 web 窄 8pt），列入已知偏差清单。

## 如实挂账
1. 拇指是 6pt 自绘（web CSS 6px）；没有做 web 的经典滚动条轨道，只在溢出时画拇指（与 #28 同一取舍）。
2. 滚动只支持滚轮位移（与既有 `#npAnlBody` 一致），没有触摸板惯性/分页。
3. `contentOffset` 在测试里用 KVC 直接驱动（生产入口是 `scrollWheel` 回调；判据走同一 setter）。
