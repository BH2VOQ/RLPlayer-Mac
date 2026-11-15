# 已知偏差清单（native ↔ web，2026-11-14，至 1.1.7.58）

> 已关闭的条目保留在表里并注明版本，避免后续排查把「已修」当回归反复查。
> 每一条都给了 web 依据、原生实现、为什么要这样、判据在哪。

| # | 位置 | web | 原生 | 为什么 / 判据 |
|---|---|---|---|---|
| 1 | `#npAnal` 内容左缘 / 卡宽 | 内容从 **12pt** 起（padding 11 + 1px border）；卡宽 `panelW-37` | **已关闭（1.1.7.57）**：`anlPadX 11→12`，状态右缘 38、`npAnlBody` 宽 `panelW-12`、卡宽 `panelW-37` 全部归位 | 旧版把「原生无边框」的 1pt 差烘进了判据；`test_native_analysis_panel` 5 条期望与 tolerance 0.5 已改真值。见 `native-anl-gutter-20261114.md` §1.1.7.57。 |
| 2 | 后端错误反馈（#63） | 整页 `renderNp()` **不展示** `j.error` | `st.error` 改 `RLPToast`（同一错误去重、1.8s 自动消失、文案=后端原文） | web 无 toast；原生属「可见反馈的超集」。判据 `test_native_nowplaying_web`。见 `native-error-toast-20261114.md`。 |
| 3 | `.npline.on` 放大（#41） | `transform:scale(1.03)` | `CATransform3DMakeScale(1.03,1.03,1)`；行 inset 留 ≥1.5% | 数值取 web 1.03，额外余量避免放大即裁字。见 `native-lyric-scale-20261114.md`。 |
| 4 | `.npchipwrap` 卡片宽度（#69） | 溢出时滚动条占位 **11pt**（CSS 写 6px，实测 11），首卡宽 `wrapW-11` | **已关闭（1.1.7.58）**：卡宽 `wrapW-19 → wrapW-11`，拇指 `x=W-6 → W-8`，`rail.padX.right 29→21`、`rail.card.width railW-39→railW-31` | 旧码「13 留白 + 6 拇指」比 web 多留 8pt。ego 实测 + 红绿见 `native-chipwrap-width-20261114.md`。**剩余 1pt**：web 卡右缘距面板右 22（含 1px border），原生 21。 |
| 5 | `#npDrawer` 浮层（#39） | `backdrop-filter:blur(2px)`；`transform .26s` 滑入；`overflow:hidden` 不裁 shadow | **已关闭（1.1.7.61）**：`RLPBlurView : NSVisualEffectView` 遮罩模糊层（`identifier=npDrawerBlur`）+ `CABasicAnimation(transform.translation.x, 0.26s, cubic-bezier(.2,.8,.2,1))` 滑入；`frame` 恒为终态 | AppKit 无 backdrop-filter，用 `HUDWindow`/`WithinWindow` 材质近似，模糊半径不等于 CSS 2px；阴影仍靠 `masksToBounds=NO`。判据见 `evidence/native-drawer-inertia-20261115.md`。 |
| 6 | `.k.big` hover 提亮 | `filter:brightness(1.08)`（逐通道 ×1.08） | **已关闭（1.1.7.59）**：`np.play` / `pb.play` 两处 hover 都按 sRGB 分量 ×1.08 夹到 1 | 旧实现混 10% 白会去饱和（#fa2d48 → 250,66,90 ≠ 浏览器 255,49,78）。新增精确逐通道判据 `test_native_nowplaying_web` / `test_native_bar_web`。见 `native-upstream-ui-compare-20261114.md` 同期包。 |
| 7 | 歌词加载态（#44/#46） | 整页无 loading 态 | 保留两行加载态 + 失败态 | 原生超集；文案逐字取 web 抽屉。见 `native-lyric-text-20261114.md`。 |
| 8 | `#npchipwrap` 滚动实现（#69） | 原生滚动容器 `overflow:auto` | `RLPRailWrapView : NSView` 自绘 `contentOffset` + 拇指，**不新增 NSScrollView** | 单层滚动判据：可见 NSScrollView 数不增加。见 `native-chipwrap-20261114.md`。 |
| 9 | hover 覆盖范围 | `.k/.npclose/.nptoggle/.chip/.npcast/.npchip/.npseek`、面板收起键 | 正在播放页全覆盖；**底部播放条 `.k` 于 1.1.7.56 补齐**（`RLPBarKeyButton`）；**设置页 `.chip` 仍只有 AppKit 默认按下高亮** | 底栏已不挂账；**唯一剩余差距 = 设置页 `.chip`**。见 `native-hover-20261114.md` 挂账 1、`native-bar-hover-20261114.md`。 |
| 10 | 字距单位（#11/#24） | `letter-spacing:1.6px / 1.5px` | `NSKernAttributeName @1.6 / @1.5`（pt） | 1x 下 px≈pt。见 `native-kern-20261114.md`。 |
| 11 | `.npchipwrap` 滚动交互 | 原生滚动条/惯性 | **已关闭（1.1.7.61）**：`RLPRailMomentumStep` 纯函数（每帧 ×0.90、<8pt/s 停）+ `momentumTick:` 阻尼惯性；系统 `momentumPhase` 阶段不叠加 | 自绘容器不引入 `NSScrollView`，自己补惯性；0.90 阻尼是近似而非系统动量曲线。拇指仍只在溢出时画（无经典轨道）。见 `evidence/native-drawer-inertia-20261115.md`。 |
| 12 | `sp_opra_copychip` | **1 个 `.chip`**：`<span class=chip id=sp_opra_copychip title="复制 OPRA 项目官网链接">` + 12×12 复制 SVG + `https://opra.roon.app/`；`ui_script.h:11947-11955` 绑定 `onclick` → `navigator.clipboard.writeText` + `toast('已复制来源链接: …')` | **已关闭（1.1.7.60）**：`RLPEqualizerView.mm` 的 OPRA 搜索行补真实 `NSButton`（identifier `sp_opra_copychip`、SF Symbol、tooltip、action `onCopyOpraLink:` → NSPasteboard + `RLPToast`） | 旧版只有 `RLPSettingsViewController.mm:702` 的 identifier 字典字符串，`parity_scan.py` 因此把 `parity.tsv:135` 标成 `done`（**静态表假绿**）；`behavior_scan.py` 只抽 `D('id').on…` 字面量，变量式 `copyChip.onclick` 同样漏掉。新增 C1–C5 判据钉住真实控件与剪贴板行为。见 `evidence/native-opra-copychip-20261115.md`。 |

## 判据索引
- 播放页：`tests/test_native_nowplaying_web.mm`（191 条，覆盖 P1–P3、hover、歌词、缩放、遮罩、chipwrap、抽屉、错误态）。
- 分析栏：`tests/test_native_analysis_panel.mm`（140+1 条，含 #28 沟槽/拇指、`.anlhide` rightGap=9）。
- 右栏卡片：`tests/test_native_rail_cards.mm`（50 条）、`test_native_rail_states.mm`（17 条）。
- 门禁：串行 `ctest` 201/201、`rlplayer_native --audit` 246/0、parity/behavior/i18n 全绿。

## 附：非偏差类挂账（不在本表内）

- **#14 播放 RENDERFAIL**：不是已解释偏差，也不是已关闭项。用户 2026-11-15 明确
  「已经没办法拿诊断包了、不知道是哪个版本的 bug，先当不存在吧」⟹ **用户放弃提供诊断包、
  暂挂账、停止追查**，未改播放引擎、未定位根因、**不写成已修**。完整状态见
  `evidence/native-renderfail-status-20261115.md`。

### 追加（2026-11-15，v3.3.11 对照）

**非法保存音量：静默 clamp，不提示用户**

- 上游（`ui_script.h:684`）：`invalidVolume` 时拒绝播放并提示
  「保存的音量无效，请修正为 -120～+20 dB 后重新读取播放设置」。
- 本仓（`tools/rtaweb.cpp:2012`）：`defaultVolumeDb = isfinite(p.volume) ? clamp(p.volume,-144,0) : -20`，
  clamp 后继续工作，用户**看不到提示**。
- 判定：安全（不会 NaN / 不会爆音），但用户意图被静默改写。
- 要做成上游那样需要跨后端契约改动（解析期记 `volumeInvalid` → 上抛到 `/api/settings` → UI 展示），
  不在小范围移植内，故挂账。

---

## 2026-11-15 收口记录（1.1.7.75 → 1.1.7.81）

本日对照 v3.3.11 又收口了 6 条，记在这里避免上表把它们当「未修」重复排查。

### 已关闭

| 原条目 | 关闭版本 | 做了什么 | 判据 / 证据 |
|---|---|---|---|
| #4 剩余 1pt（web 22 / native 21） | **1.1.7.75 + 1.1.7.78** | ①滚动条占位改为真溢出才占 11pt（旧码无条件占位，短列表也空一条槽）；②rail 内容内缩按 box-sizing:border-box 取 **11**（= padding 10 + border 1） | np web 228→233 条、rail_cards 52 条；证据 `native-chipwrap-reserve-20261115.md`、`native-rail-borderbox-20261115.md` |
| #9 设置页 .chip hover | **1.1.7.79** | 新增 `RLPChipHoverButton`（NSTrackingArea → bezel 取 hov、文字取 txt，退出复原） | `test_native_opra_cards` C3b–C3e；证据 `native-chip-hover-20261115.md` |
| #12 `sp_opra_copychip` 悬停 | **1.1.7.79** | 同上（该芯片此前只有点击与剪贴板行为，无悬停态） | 同上 |
| （表外）`/api/meta` 缺 `coverSource` ⟹「自动」封面按钮常显 | **1.1.7.76** | 后端新增 `cover_manual_active_for()`，`/api/meta` 输出 manual/embed/none；前端按 coverSource == manual 显隐 | `test_embedded_api` K7/K8 + np web C4b–C4d；证据 `native-cover-source-20261115.md` |
| （表外）rail 收起键写死 8pt、与行顶齐平 | **1.1.7.80** | 两轴改走 `kRailHeadPadX/Top`：右 11、顶 12（行内居中） | np web 两条新判据（右 11±1 / 顶 12±1）；证据 `native-railhide-margin-20261115.md` |
| （表外）分析面板收起键顶部少算边框 | **1.1.7.81** | 顶 7 → **8**（top:7 在 padding box 内，加 border 1） | np web 两条新判据（右 9±1 / 顶 8±1）；证据 `native-anlhide-margin-20261115.md` |

### 仍未关闭（本日盘点后的真实剩余项）

| # | 项 | 现状 | 为什么没做 |
|---|---|---|---|
| A | 专辑卡播放角标（web `right:7;bottom:7`、32×32，原生约束 `-8`） | **待修，且比台账原来记的更多**：本轮尝试建夹具时量到原生角标实际是 **32.5×36**（不是 32×32） | ①差 1pt 已定位（注释写 7、约束写 8，属注释与代码不一致）；②量到的 32.5×36 是按钮**固有尺寸**；把它挂进离屏 `NSWindow` 后重跑，**数字仍是 32.5×36 / 内距 7.5 / 6.5**（`-8` 约束也没生效）⟹ 问题不在窗口，而在**这个集合项实例的约束没有参与该次布局**（回收项 / 另一条布局路径，未定位）；因此在拿到可信夹具前不动这 1pt |
| B | .chip 悬停的边框色 border-color:var(--acc) | 只做了底色+文字 | 系统 NSButton bezel 无法单独改边框色（自绘胶囊等于重新设计控件） |
| C | .chip 的 transition:.15s | 瞬时切换 | bezelColor 不可动画；要做需自绘层 |
| D | #npDrawer 模糊半径 | NSVisualEffectView 材质近似 | AppKit 无 backdrop-filter 半径控制 |
| E | 惯性阻尼 0.90 | 近似而非系统动量曲线 | 自绘滚动容器，无系统动量可对齐 |
| F | 非法保存音量静默 clamp | 不提示 | 上游是拒绝播放并提示；原生在启动期读取，缺一处可见提示 |
| G | npWaveform 真波形 | 未做 | 跨 src/analysis + 缓存 worker + 端点 + AppKit 绘制的新子系统，需独立排期（`native-seek-guard-20261115.md` §5） |
| H | #13 双模式薄表现层 | 只读评估已完成，不建议现在做 | 前提虽满足但收益面未定义，且会冲撞 246 项 audit / 203 项 ctest 的可见性断言（`native-dualmode-assessment-20261115.md`） |

### 判据索引（当日基线）

- 播放页 `test_native_nowplaying_web`：**235 条**；底栏 `test_native_bar_web`：**350 条**；右栏 `test_native_rail_cards`：**52 条**；OPRA `test_native_opra_cards`：**25 条**。
- 门禁基线：串行 `ctest` **203/203**、`rlplayer_native --audit` **246/0**、parity `missing=0`、behavior `actionable=0`、i18n 覆盖 0 缺失。
