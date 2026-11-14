# 已知偏差清单（native ↔ web，2026-11-14，至 1.1.7.54）

> 这些是**有意的、已解释的**偏差，不是未完成项；后续排查不要当回归反复查。
> 每一条都给了 web 依据、原生实现、为什么要这样、判据在哪。

| # | 位置 | web | 原生 | 为什么 / 判据 |
|---|---|---|---|---|
| 1 | `#npAnlBody` 卡片左缘 | 内容从 **12pt** 起（面板 padding 11 + **1px border**） | **11pt**（原生面板无边框） | 历史实现无边框；1.1.7.49 只对齐右缘 25pt 与卡宽 `panelW-36`。已知 1pt 差；改左缘会连带头部状态/收起键判据，需单独包。见 `native-anl-gutter-20261114.md`。 |
| 2 | 后端错误反馈（#63） | 整页 `renderNp()` **不展示** `j.error`（失败走另一套提示通道） | `st.error` 不再写副标题，改 `RLPToast`（同一错误去重、**1.8s 自动消失**、文案=后端原文） | web 没有 toast 组件；原生用既有轻提示，属「可见反馈的超集」。判据：`test_native_nowplaying_web`（副标题≠错误、toast 出现、2.6s 后消失）。见 `native-error-toast-20261114.md`。 |
| 3 | `.npline.on` 放大（#41） | `transform:scale(1.03)`（只影响绘制） | `CATransform3DMakeScale(1.03,1.03,1)`；行左右 inset 加到 `max(6, ceil((w-12)*0.015)+1)` | 数值直接取 web 1.03；额外留 ≥1.5% 宽度余量，避免"放大即裁字"（旧码 556pt 文档下会溢出 ~2pt）。判据含缩放后首/末行不越文档边界。见 `native-lyric-scale-20261114.md`。 |
| 4 | `.npchipwrap` 卡片宽度（#69） | 滚动条占位 ~**11px**，卡片宽 = wrap 内容宽 | 右侧**常驻 19pt**（13 留白 + 6 拇指条）⟹ 卡片比 web **窄 8pt** | 为了"滚动条不压卡片圆角"（与 #28 沟槽同一取舍）。判据锁「拇指与卡片右缘 ≥13pt」并在 `native_rail_cards` 里把期望 `railW-20→railW-39`、`padX.right 10→29` 明示。见 `native-chipwrap-20261114.md`。 |
| 5 | `#npDrawer` 浮层（#39） | `backdrop-filter:blur(2px)`；`transform .26s` 滑入；`overflow:hidden` 但 box-shadow 不裁 | 遮罩纯 `rgba(0,0,0,.30)`（**无模糊**）；抽屉**直接到终点**、只做 0.18s alpha 淡入；`masksToBounds=NO` 以显示阴影 | AppKit 无 backdrop-filter；离屏判据需要确定性 frame，故不做滑入；阴影必须 `masksToBounds=NO`（CSS 的 overflow 不裁 box-shadow）。判据覆盖 frame/圆角/阴影/遮罩点击/Esc/底层滚动不动。见 `native-drawer-20261114.md`。 |
| 6 | `.k.big` hover 提亮 | `filter:brightness(1.08)` | accent 色**混 10% 白** | AppKit 无 CSS filter；混白是亮度等价近似。判据只要求"hover 底色发生变化 + 退出恢复 accent"。见 `native-hover-20261114.md`。 |
| 7 | 歌词加载态（#44/#46） | **整页**没有 loading 态（空歌词直接显示「没有歌词」两行） | 保留两行加载态（文案取自抽屉 `歌词加载中…` + 副行说明），失败态保留 `歌词加载失败` | 原生超集（等后端补全时给用户反馈）；文案逐字取 web 抽屉同词条，不是整页逐像素。见 `native-lyric-text-20261114.md`。 |
| 8 | `#npchipwrap` 滚动实现（#69） | 原生滚动容器（`overflow:auto`） | `RLPRailWrapView : NSView` 自绘 `contentOffset` + `drawRect` 拇指，**不新增 NSScrollView** | 单层滚动判据：可见 NSScrollView 数不增加，避免嵌套滚轮打架。判据锁"NSScrollView=0 + 栏头不动 + 拇指不压卡片"。见 `native-chipwrap-20261114.md`。 |
| 9 | hover 覆盖范围 | `.k/.npclose/.nptoggle/.chip/.npcast/.npchip/.npseek`、面板收起键 | 正在播放页已全部覆盖；**底部播放条 `.k`** 与设置页 `.chip` 仍是 AppKit 默认按下高亮 | 本轮范围限定 np 页差异表；底部播放条不在表内，未动。见 `native-hover-20261114.md` 挂账 1。 |
| 10 | 字距单位（#11/#24） | `letter-spacing:1.6px / 1.5px` | `NSKernAttributeName @1.6 / @1.5`（pt） | 1x 下 px≈pt，与既有 anllab 做法一致；高分屏只影响像素密度，不改变相对字距。见 `native-kern-20261114.md`。 |
| 11 | `.npchipwrap` 滚动交互 | 原生滚动条/惯性 | 滚轮位移（无惯性/分页）；拇指只在溢出时画（无经典轨道） | 与既有 `#npAnlBody` 同一取舍；判据只锁位移与拇指位置。 |

## 判据索引
- 播放页：`tests/test_native_nowplaying_web.mm`（191 条，覆盖 P1–P3、hover、歌词文案、缩放、遮罩、chipwrap、抽屉、错误态）。
- 分析栏：`tests/test_native_analysis_panel.mm`（140 条，含 #28 沟槽/拇指）。
- 右栏卡片：`tests/test_native_rail_cards.mm`（50 条）、`tests/test_native_rail_states.mm`（17 条）。
- 门禁：串行 `ctest` 201/201、`rlplayer_native --audit` 246/0、parity/behavior/i18n 全绿。
