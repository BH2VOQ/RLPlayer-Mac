# 已知偏差清单（native ↔ web，2026-11-14，至 1.1.7.58）

> 已关闭的条目保留在表里并注明版本，避免后续排查把「已修」当回归反复查。
> 每一条都给了 web 依据、原生实现、为什么要这样、判据在哪。

| # | 位置 | web | 原生 | 为什么 / 判据 |
|---|---|---|---|---|
| 1 | `#npAnal` 内容左缘 / 卡宽 | 内容从 **12pt** 起（padding 11 + 1px border）；卡宽 `panelW-37` | **已关闭（1.1.7.57）**：`anlPadX 11→12`，状态右缘 38、`npAnlBody` 宽 `panelW-12`、卡宽 `panelW-37` 全部归位 | 旧版把「原生无边框」的 1pt 差烘进了判据；`test_native_analysis_panel` 5 条期望与 tolerance 0.5 已改真值。见 `native-anl-gutter-20261114.md` §1.1.7.57。 |
| 2 | 后端错误反馈（#63） | 整页 `renderNp()` **不展示** `j.error` | `st.error` 改 `RLPToast`（同一错误去重、1.8s 自动消失、文案=后端原文） | web 无 toast；原生属「可见反馈的超集」。判据 `test_native_nowplaying_web`。见 `native-error-toast-20261114.md`。 |
| 3 | `.npline.on` 放大（#41） | `transform:scale(1.03)` | `CATransform3DMakeScale(1.03,1.03,1)`；行 inset 留 ≥1.5% | 数值取 web 1.03，额外余量避免放大即裁字。见 `native-lyric-scale-20261114.md`。 |
| 4 | `.npchipwrap` 卡片宽度（#69） | 溢出时滚动条占位 **11pt**（CSS 写 6px，实测 11），首卡宽 `wrapW-11` | **已关闭（1.1.7.58）**：卡宽 `wrapW-19 → wrapW-11`，拇指 `x=W-6 → W-8`，`rail.padX.right 29→21`、`rail.card.width railW-39→railW-31` | 旧码「13 留白 + 6 拇指」比 web 多留 8pt。ego 实测 + 红绿见 `native-chipwrap-width-20261114.md`。**剩余 1pt**：web 卡右缘距面板右 22（含 1px border），原生 21。 |
| 5 | `#npDrawer` 浮层（#39） | `backdrop-filter:blur(2px)`；`transform .26s` 滑入；`overflow:hidden` 不裁 shadow | 遮罩纯 `rgba(0,0,0,.30)`（**无模糊**）；抽屉**直接到终点**、只做 0.18s alpha 淡入；`masksToBounds=NO` | 保留偏差：AppKit 无 backdrop-filter；离屏判据要确定性 frame。见 `native-drawer-20261114.md`。**待做**（用户清单 #6）。 |
| 6 | `.k.big` hover 提亮 | `filter:brightness(1.08)`（逐通道 ×1.08） | **已关闭（1.1.7.59）**：`np.play` / `pb.play` 两处 hover 都按 sRGB 分量 ×1.08 夹到 1 | 旧实现混 10% 白会去饱和（#fa2d48 → 250,66,90 ≠ 浏览器 255,49,78）。新增精确逐通道判据 `test_native_nowplaying_web` / `test_native_bar_web`。见 `native-upstream-ui-compare-20261114.md` 同期包。 |
| 7 | 歌词加载态（#44/#46） | 整页无 loading 态 | 保留两行加载态 + 失败态 | 原生超集；文案逐字取 web 抽屉。见 `native-lyric-text-20261114.md`。 |
| 8 | `#npchipwrap` 滚动实现（#69） | 原生滚动容器 `overflow:auto` | `RLPRailWrapView : NSView` 自绘 `contentOffset` + 拇指，**不新增 NSScrollView** | 单层滚动判据：可见 NSScrollView 数不增加。见 `native-chipwrap-20261114.md`。 |
| 9 | hover 覆盖范围 | `.k/.npclose/.nptoggle/.chip/.npcast/.npchip/.npseek`、面板收起键 | 正在播放页全覆盖；**底部播放条 `.k` 于 1.1.7.56 补齐**（`RLPBarKeyButton`）；**设置页 `.chip` 仍只有 AppKit 默认按下高亮** | 底栏已不挂账；**唯一剩余差距 = 设置页 `.chip`**。见 `native-hover-20261114.md` 挂账 1、`native-bar-hover-20261114.md`。 |
| 10 | 字距单位（#11/#24） | `letter-spacing:1.6px / 1.5px` | `NSKernAttributeName @1.6 / @1.5`（pt） | 1x 下 px≈pt。见 `native-kern-20261114.md`。 |
| 11 | `.npchipwrap` 滚动交互 | 原生滚动条/**惯性** | 滚轮位移（**无惯性/分页**）；拇指只在溢出时画 | 与 `#npAnlBody` 同取舍。**待做**（用户清单 #8）。 |
| 12 | `sp_opra_copychip` | **1 个 `.chip`**：`<span class=chip id=sp_opra_copychip title="复制 OPRA 项目官网链接">` + 12×12 复制 SVG + `https://opra.roon.app/`；`ui_script.h:11947-11955` 绑定 `onclick` → `navigator.clipboard.writeText` + `toast('已复制来源链接: …')` | **仅 id 映射**：`RLPSettingsViewController.mm:702` 的 `RLPControlIdentifier` 字典里有 `@"sp_opra_copychip": @"sp_opra_copychip"`，`:628` 的 `notSettingKeys` 里也有一条；**屏幕上没有这个控件、没有 target/action、没有 NSPasteboard 写入** | `parity_scan.py` 只从源码抽 identifier 字面量，所以 `docs/native-ui/parity.tsv:135` 把它标成 `done` —— 这是静态表的**假绿**，正是「identifier 存在 ≠ 功能存在」的典型。行为扫描 `behavior_scan.py` 也只抽 `D('id').on<event>` 的 50 条绑定，`copyChip.onclick` 用的是变量而非 `D()` 字面量，同样漏掉。**待做**（用户清单 #11 要求记录现状；按铁律①应补齐真实控件）。 |

## 判据索引
- 播放页：`tests/test_native_nowplaying_web.mm`（191 条，覆盖 P1–P3、hover、歌词、缩放、遮罩、chipwrap、抽屉、错误态）。
- 分析栏：`tests/test_native_analysis_panel.mm`（140+1 条，含 #28 沟槽/拇指、`.anlhide` rightGap=9）。
- 右栏卡片：`tests/test_native_rail_cards.mm`（50 条）、`test_native_rail_states.mm`（17 条）。
- 门禁：串行 `ctest` 201/201、`rlplayer_native --audit` 246/0、parity/behavior/i18n 全绿。
