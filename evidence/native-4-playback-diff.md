# 播放页（web `#np` 系列）→ 原生 逐选择器对照表

- 仓库：`/Users/august/Downloads/DQ/RLPlayer`（git main，本地）
- 生成方式：机器抽取 web 侧 `src/net/ui_page.h`（CSS/HTML 模板）+ `src/net/ui_script.h`（交互/状态渲染）
  的 `#np` 系列选择器、样式值（字号/间距/内边距/颜色）、交互绑定；原生侧人工逐函数比对
  `tools/native_ui/RLPNowPlayingViewController.mm`（含 `RLPNPControlBar`、`RLPAnlCardView`、
  `RLPRailChipView`、`RLPNPCanvas`）与 `tools/native_ui/RLPPlaybackBarView.mm`。
- 基线：`1.1.7.39`（本表随每一包的 commit 更新「状态」列）。
- 状态图例：
  - **已对齐** = web 的选择器/字段/值在原生有等价落点（含语义等价，如 SVG→SF Symbol）。
  - **已修** = 本轮比对发现差异，先红后绿修掉的（附 commit）。
  - **未修** = 仍有差异，写清原因与风险（不假装已对齐）。
- 「原生实现位置」为当前文件的行号/方法名；行号随提交漂移，以方法名为准。

## 1. 容器 / 背景 / 窗口级

| # | web 选择器/字段/值 | 原生实现位置 | 状态 |
|---|---|---|---|
| 1 | `#npPage{position:fixed;inset:0;z-index:70;display:none/.on}` | `RLPNowPlayingViewController` 全窗口覆盖层（`RLPCloseNowPlayingNotification` 关闭） | 已对齐（窗口级，非 WebView 覆盖） |
| 2 | `.npbgwrap/.npbg{inset:-60px;blur(64px) saturate(1.15) brightness(.38);scale(1.08)}` | `updateBlurredCover`（2849）/ `RLPNPCanvas.drawRect`（77）缩放 1.08 绘制 | 已对齐 |
| 3 | `.npveil{linear-gradient(180deg,rgba(8,9,12,.35)→.82)}`；浅色 `.62/.95` | `RLPNPCanvas.drawRect` 同两个 stop 的 NSGradient | 已对齐 |
| 4 | `.npedge`（页面外圈 = --bg，遮宿主 5px 边带） | 原生无宿主边带 | 已对齐（N/A） |
| 5 | `.npgrip{top:0;h:34;cursor:grab}` + `webview.postMessage("drag")` | 原生窗口标题栏/背景可拖，无需热区 | 已对齐（N/A） |
| 6 | `.npclose{38×38;top:16;right:18;圆形}` 双内向箭头图标 | `buildContent` 1243：`npClose` 38×38 @(w-56,16)，`arrow.down.right.and.arrow.up.left` | 已对齐 |
| 7 | `.nppanels{top:16;right:66;gap:8}`、`.nptoggle{34×34}` | `npAnalToggle`/`npRailToggle` 34×34 @(w-142/w-100,18)，gap 8 | 已对齐 |
| 8 | `.npgrid{grid-template-rows:auto minmax(0,1fr) auto;gap:18;padding:44px 16px 18px}` | `layoutWebPlayback`（1489）：`top=44,gutter=16,by=top+c+18` | 已对齐 |

## 2. 封面 / 标题 / 副标题 / 下一首

| # | web | 原生 | 状态 |
|---|---|---|---|
| 9 | `.nphero{grid auto 1fr;gap:26}` | `layoutWebPlayback`：`x=gutter+c+26` | 已对齐 |
| 10 | `.npcover{height:clamp(132px,24vh,236px)}` + `radius14` | `c=MIN(236,MAX(132,h*.24))`，`cover.layer.cornerRadius=14` | 已对齐 |
| 11 | `.npkind{font-size:10;letter-spacing:1.6;font-weight:600;margin-bottom:8}` | `kindLabel` 10/600（**无 letter-spacing**） | 未修（字距 1.6 未接；wants kern，与 anllab 同一手法） |
| 12 | `.npkind` 文案 = `npPlayingKindText(curMeta)`：`正在播放 · CODEC / kHz / bit`；`null` ⟹ 纯「正在播放」 | `loadMetaAndKnowledgeForPath`（2431）同格式；`refresh` 切曲分支先复位 | **已修（1.1.7.40）**：旧码停止后挂上一首格式串、无字段时挂尾 ` · `（见 #60） |
| 13 | `.nptit{font-size:clamp(19px,2.6vh,27px);font-weight:700;line-height:1.3;…ellipsis}` | `layoutWebPlayback`：`RLPNPTitlePointSize(vh)`，`titleH=ceil(size·1.3)`，下方行 Y 从标题行底推导 | **已修（1.1.7.43）**：旧码固定 20/30 |
| 14 | `.npsub{font-size:13;color:var(--mut);margin-top:8;ellipsis}` | `artistLabel2` 13/mut @infoY+63；`loadMeta` 拼 `artist · album` | 已对齐 |
| 15 | `#npNextTrackHero{font-size:12;color:var(--mut2);margin-top:4;默认隐藏}` 文案 `下一首: X · 剩 N 首` / `队列末尾 · 共 N 首`；隐藏条件 `!S.playing \|\| !qLen`（**暂停仍显示**） | `metaLabel` 12/mut2 默认隐藏；`applyQueueSnapshot:` 逐条移植（mode2/回绕/remain/半角 `: `）；切曲即清空；可见时 `.npmline` 下移 22pt | **已修（1.1.7.45）** |
| 16 | `#npFavBtn{padding:4;display:none→收藏态显示}` 20×20 心形 | `favoriteButton` 28×30 `♡`（`refreshFavorite` 控制） | 已对齐（图标为字形而非 SVG） |

## 3. `#npMeta` 芯片行

| # | web | 原生 | 状态 |
|---|---|---|---|
| 17 | `.npmline{gap:6;flex-wrap;margin-top:10;min-height:22}` | `layoutMetaChipsInWidth`（1452）：gap 6、逐行折行、行高 22/24 | 已对齐 |
| 18 | `buildNpMetaHtml`：`year/genre/albumArtist` 三个 `.badge`（`label + 两个空格 + 值`），`sources` 进 title | `renderMetaChipsFromMeta`（1387）逐字两空格 + 来源 tooltip | 已对齐（1.1.7.36） |
| 19 | `.badge.g`「已补全」绿色徽标 | 第 4 枚 `npMeta.enriched`，`styleMetaBadge green:YES` | 已对齐 |
| 20 | `npEqChipsHtml`：`eq`/`ir` 非空才出 `.chip`，11×11 SVG + 文件名 tooltip | `npEqChip`/`npIrChip`（`applyMetaChipVisibility`），SF Symbol 11×11（1.1.7.36） | 已对齐 |
| 21 | `npCastBtnHtml`：`.npcast{11.5;pad4 10;radius12}`，文案 `推送到设备`/`已推送到 X` | `npCastBtn` + `applyCastChipStyle`（1695）同文案/配色 | 已对齐 |
| 22 | `#npAddSq`「添加到歌单」chip 12×12 + 文字 | `npAddSq`（`saveButton`）同文案 | 已对齐 |

## 4. 左栏 `#npAnal`（音频分析）

| # | web | 原生 | 状态 |
|---|---|---|---|
| 23 | `#npAnal{padding:8px 11px 9px;radius14;gap:6}` | `layoutWebPlayback`：`anlPadX=11/anlPadTop=8/anlPadBottom=9` | 已对齐 |
| 24 | `.anllab{9.5;letter-spacing:1.5;700}` | `anlLab` 9.5/700（无 kern；量宽时按 kern 补 4.5pt 的注释已注明） | 未修（同 #11，字距属性未接） |
| 25 | `#npAnlStat{10;right;tabular}` | `analysisStatus` 10/right | 已对齐 |
| 26 | `.npseg{radius9;1px}；`b{10.5;600;pad3 11;border-left}`；`b.on{ok-bg}` | `anlSeg` radius9/border + 三枚 10.5/600 无边框按钮 + 两条发丝分隔 | 已对齐 |
| 27 | `.anlhide{22×22;圆形;top7 right8}‹` | `analysisPanel` 头部 `npAnalHide`（22×22、cornerRadius 11、`chevron.left`），点击=隐藏+写 `RLPNPAnalysisHidden` | **已修（1.1.7.42）** |
| 28 | `#npAnlBody{overflow-y:scroll;gap:8;padding-right:13;margin-right:-11}`；web 实测 panelW=301 → cardW=264（右缘距面板右 25、clear=13、滚动条占位 11） | `anlBody` 撑到面板右缘（`x=11/width=panelW-11`）、卡片 `width=bodyW-25`（13 留白 + 12 拇指条，三档恒定）、6pt 拇指自绘在沟槽内、不加 NSScrollView | **已修（1.1.7.49）**：卡宽期望 `panelW-22`(311) → `panelW-36`(297)，差因=web 1px 边框+右内边距 1，见 `evidence/native-anl-gutter-20261114.md` |
| 29 | `.anlcard{radius10;pad7 9 8;gap4}` | `kAnlCardPadTop/X/Bottom/Gap/Radius` 常量 | 已对齐 |
| 30 | `.anlgrid{2 列;gap1 10}`、`.anlml`、`.anlv`、`.anlwarn`、`.anlnote` | `RLPAnlCardView` 逐行布局（`kAnlColGap=10`） | 已对齐 |

## 5. 右栏 `#npRail`（AI 整理）

| # | web | 原生 | 状态 |
|---|---|---|---|
| 31 | `.nprailcard{pad10;radius14;gap8;blur}` | `railPanel` 几何 `kRailHeadPadX/PadTop/gap` | 已对齐 |
| 32 | `.nprailcap{9.5;letter-spacing:1.5;700}` | `railTitle` 9.5 + NSKern 1.5 | 已对齐 |
| 33 | `.npseg`「简略/详细」| `railDensity`(npRailSeg) NSSegmentedControl h24 | 已对齐 |
| 34 | `.nprailhide{22×22;圆形}›` | `railPanel` 栏头 `npRailHide`（22×22、`chevron.right`），点击=隐藏+写 `RLPNPRailHidden` | **已修（1.1.7.42）** |
| 35 | `.npchip{pad8 10 9;radius11;12/11.5/9.5/11.5/10.5}`、`-top/-name/-st/-p1/-p2` | `RLPRailChipView`（768-955）同字号层级 | 已对齐 |
| 36 | `.npchipwrap[data-detail=1]` 5 行/2 行钳制 | `kRailDetailLineHeight=1.35`、`measuredTextHeight cap:5/2` | 已对齐 |
| 37 | `.nprailempty{10.5;1.6}` | `railEmptyLabel` 10.5 多行 | 已对齐 |
| 38 | `.nprailhint{10.5}` + `err` 可点重试 | `npSummHint`(`railHintBtn`) 10.5，点击重试 | 已对齐 |
| 39 | `#npDrawer` 右侧浮卡（`npdrawer` 430 宽、18 圆角、滑入） | `RLPShowCardPopover` + `RLPKnowledgeView` 浮卡 | 未修（原生用系统浮卡，动效/宽度非 1:1；功能等价，不删） |

## 6. 歌词区

| # | web | 原生 | 状态 |
|---|---|---|---|
| 40 | `#npLyric`：`mask-image` 上下 26px 渐隐、`scrollbar-width:none`、`padding:2px 0` | `lyricScroll`：无 mask 层、隐藏滚动条 | 未修（CAGradientLayer mask 未接；视觉差异在长歌词首/末行） |
| 41 | `.npline{font-size:clamp(13px,1.9vh,17px);line-height:2.05}`；`.on{650;scale1.03}` | `applyLyricText`/`layoutLyricRows`：字号=`RLPNPLyricPointSize(vh)`、行盒=2.05×字号，窗口变化时 `restyleLyricRows`；active=Semibold | **已修（1.1.7.48）**：字号/行盒（1.1.7.43）+ active `transform:scale(1.03)`（行左右留 ≥1.5% 余量保证放大不裁字） |
| 42 | 行留白 = `(容器高-行高)/2`（JS 写 `--nppad`），首/末行也能居中 | `layoutLyricRows`：`pad=MAX(26,h/2-18)` | 已对齐（等价公式，行高固定 30 时一致） |
| 43 | 手动滚动 3s 保护；seek/切歌立即重定位 | `lyricManualUntil`/`onLyricScrolled`（1604）、`onCommitSeek` 清保护 | 已对齐 |
| 44 | 空态：`没有歌词`（clamp 字号）+ 副行 12px `--mut2` `同名 .lrc 文件、内嵌歌词，或播放时自动在线补全（可在设置-元数据补全关闭）`；无曲目/网络曲目同文案 | `lyricsEmpty` 多行居中 + `setLyricsPlaceholder:detail:`：主行跟 clamp、副行 12px/`--mut2`；整页去掉 `还没有播放曲目`/`网络曲目暂无歌词` 错位文案 | **已修（1.1.7.47）** |
| 45 | 网络曲目：`网络曲目暂无歌词`（右侧抽屉 `lyricbox`） | `loadLyricsForPath`（2395）同文案 | 已对齐 |
| 46 | 加载中：抽屉 `歌词加载中…` + 副行 `正在等后台补全（首次播放新曲目时可能要几秒）` | `setLyricsPlaceholder:@"歌词加载中…" detail:@"正在等后台补全（首次播放新曲目时可能要几秒）"`（两行）；失败态保留 `歌词加载失败` | **已修（1.1.7.47）**（整页无 loading 态，原生仍为超集） |

## 7. 传输控制 / 进度 / 音量 / 模式

| # | web | 原生 | 状态 |
|---|---|---|---|
| 47 | `.npctl2{max-width:1160;居中;rows auto auto;gap12}` | `webControls` 宽 `MIN(1160,w-32)` 居中，高 58 @`h-76` | 已对齐 |
| 48 | `.npseek{height:5;radius3;hover→7}`、`>i` 已播色 | `RLPNPAccentCell.barThickness` 5/7pt + `RLPNPSlider.hoverGrow` 跟踪区（mouseEntered/Exited 切换轨道厚并重绘） | **已修（1.1.7.44）** |
| 49 | `.nptime{12;tabular}`、`.tval{min-width:42;居中}`、`.tsep{opacity:.45}` | `posLabel/durLabel` monospacedDigit 12pt、42 宽、均居中；`tsep` 10 宽 + 1pt 间距 | **已修（1.1.7.44）** |
| 50 | `.npkeys{width:min(460px,40vw);gap14}`；`.k{32×32;radius9}`；`.k.big{34×34;圆形;accent}` | `RLPNPControlBar.layout`：rep 32、prev/next/stop 32、play 34（radius17），gap 14 | 已对齐（宽度上限 min(460,40vw) 未接） |
| 51 | `#npRep` 图标随模式换（`REP_ICON[0..3]`），`title/aria` 随模式 | `onCycleMode` + `applyPlayModeUI`：SF Symbol `arrow.right`/`repeat`/`repeat.1`/`shuffle` + web `REP_META[].aria` tooltip | **已修（1.1.7.41）**：旧码固定 `repeat`、无档位指示 |
| 52 | `#npRepOne{display:'' only 单曲循环}`「1」角标 | `RLPNPControlBar.repBadge`（identifier `npRepOne`，10pt/700），`applyPlayModeUI` 只在 mode=2 显示 | **已修（1.1.7.41）**：旧码无此控件 |
| 53 | `#npPrev/#npNext` 18×18 filled | `backward.fill`/`forward.fill` 32pt 按钮 | 已对齐 |
| 54 | `#npPlay` `#npIcP`：playing&&!paused → 暂停图标，否则播放图标 | `refresh`（2322）`pause.fill/play.fill` 切换 | 已对齐 |
| 55 | `#npStop` 15×15 圆角方块 | `stop.fill` 32pt 按钮 | 已对齐 |
| 56 | `.npvol{icon14;gap8;min-width150}`、`input{width:104}`、`.vlab{11;min-w58;right}` | `RLPNPControlBar`：icon14/gap8/slider 104/label 58/font 11 | **已修（1.1.7.44）** |
| 57 | `volPosToDb/volDbToPos`：`-55·(1-p)^1.6`，`p≤5→-120dB` 真静音 | `RLPNPVolPosToDb/RLPNPVolDbToPos/RLPNPVolDbLabel` 逐字同曲线 | 已对齐 |
| 58 | 拖拽期间 400ms 轮询不得回写（`dragging` + holdUntil） | `RLPNPSlider.dragging` + `refresh` 跳过回写，松手 `onCommit` 一次 | 已对齐 |

## 8. 状态机（playing / paused / stopped / loading）

| # | web | 原生 | 状态 |
|---|---|---|---|
| 59 | 播放图标：`S.playing && !S.paused` | `refresh` 同判据（1.1.7.33 三入口统一） | 已对齐 |
| 60 | 停止：清 `lastCur`，`#npTitle`=`未播放`、副标题/`#npMeta` 清空、歌词回空态、`#npKind` 回「正在播放」 | `refresh`（2325）：`title=未播放`、`artist=""`、`meta=""`；**新码**再加 `kindLabel=正在播放` | **已修（1.1.7.40）**：旧码保留上一首 `正在播放 · FLAC / 48 kHz / 24 bit` |
| 61 | 切曲：`trackMetadata`/封面/歌词/分析全量复位，旧请求作废（世代号） | `refresh` 切曲分支 + `anlSeq`/`coverSeq`/`lyricSeq`/`rail` gen | 已对齐 |
| 62 | `anl` 状态文字：`未播放 / 正在分析… / 缓存命中 / 失败·点击重试 / 分析于 HH:MM` | `anlPaint`（2716）同状态机 | 已对齐 |
| 63 | 错误态：`j.error` 不进整页正文 | `st.error` 不再写 `artistLabel2`；改 `RLPToast`（同一错误去重，1.8s 自动消失） | **已修（1.1.7.50）**（web 无 toast 组件，原生用既有轻提示：可见反馈的超集，文案=后端原文） |
| 64 | loading：web 整页只靠 400ms 轮询，无显式 loading 文案 | 原生 `statusInFlight` + 轮询，无额外骨架 | 已对齐 |

## 9. hover / active / 滚动行为

| # | web | 原生 | 状态 |
|---|---|---|---|
| 65 | `.k:hover{background:var(--hov2);color:var(--txt)}`、`.k.big:hover{brightness 1.08}` | `np.rep/np.prev/np.next/np.stop`（`RLPHoverButton` + `NPCreateKeyButton`）hover `--hov2`、`np.play` accent 混白提亮；圆角 9/17 | **已修（1.1.7.46）**（仅 np 页；底部播放条 `.k` 未含） |
| 66 | `.npclose:hover{background:#fff;scale1.04}`、`.nptoggle:hover` 同款、`.nprailhide/.anlhide:hover{background:var(--hov2);color:var(--txt)}` | `npClose`/`npAnalToggle`/`npRailToggle`：静态底改 web 的 alpha .92，hover 提亮到不透明 + `scale 1.04`；`npAnalHide`/`npRailHide` hover `--hov2`+`--txt` | **已修（1.1.7.46）** |
| 67 | `.npchip:hover`（浅色半透明值）、`.npcast:hover`（`--hov`/`--acc`）、`.npseek:hover` 5→7 | `RLPRailChipView.setHovered:`、`applyChipHover:hovered:`、`RLPNPAccentCell.barThickness` | **已修（1.1.7.46）** |
| 68 | `#npAnlBody` 自己滚（`overflow-y:scroll`），头部固定；`#npLyric` 独立滚动；整页不滚 | `RLPNPAnalBody.onScroll`/`anlDetailScroll`/`lyricScroll` 各自滚动，`webCanvas` 不滚 | 已对齐 |
| 69 | 右栏 `.npchipwrap` 内部滚动、脚注固定 | 原生 rail 卡片按可用高度均分（`preferredHeightForWidth`），溢出时 hint 置底 | 未修（无独立 chipwrap 滚动容器；卡片少时视觉等价） |

## 10. 本轮未覆盖 / 明确不做

- **A/B 对比**：web 单曲页没有 A/B 开关；A/B 语义在 web 是「同目录多版本对比」（右键菜单 +
  `#modal` 对比弹窗），原生保留同一功能（`npCompare` 右键 + 对比卡），不是缺失项。
- `#npGrip`（窗口拖拽热区）是 WebView 覆盖层的产物；原生窗口由 AppKit 承担，N/A。
- `.npedge`（WebView 5px 边带）N/A。
- 页面内自检脚本（`window.__SELFTEST`）是 web 侧判据载体，原生用 `--audit`/ctest，载体不同、判据等价。

## 11. 红→绿记录（逐包追加）

### 1.1.7.49 —— `#npAnlBody` 沟槽 + 自绘拇指（表 #28）

- web 实测：panelW=301、cardW=264、右缘 25、clear 13（C8 `w=264/264/264 spread=0`）。
- 判据：卡宽 `panelW-36`、body 撑到右缘、右缘 25、拇指 ≥13 不压卡片、非 NSScrollView。
- 旧码（1.1.7.48）：**7 FAIL** → 新码 **140P / 0F**。
- 证据：`evidence/native-anl-gutter-20261114.md`、`native-gutter-{red,green}-20261114.log`。

### 1.1.7.48 —— `.npline.on` active 缩放（表 #41）

- 判据：8 条（transform 1.03 / 其余 1.0 / 切换复位 + 缩放后不裁切，doc 556×489）。
- 旧码（1.1.7.47）：**8 FAIL** → 新码 **140P / 0F**。
- 证据：`evidence/native-lyricscale-{red,green}-20261114.log`。

### 1.1.7.47 —— 歌词空态/加载态两行文案（表 #44/#46）

- 判据：8 条（两行逐字、行数、主/副字号、加载态、无曲目）。
- 旧码（1.1.7.46）：**6 FAIL** → 新码 **131P / 0F**。
- 证据：`evidence/native-lyrictext-{red,green}-20261114.log`。

### 1.1.7.46 —— hover 统一（表 #65/#66/#67）

- 判据：35 条 hover 视觉断言（底色/描边/transform/字色，逐分量 ±0.02~0.06）。
- 旧码（1.1.7.45）：**10 FAIL** → 新码 **121P / 0F**。
- 证据：`evidence/native-hover-{red,green}-20261114.log`。
- 挂账：底部播放条 `.k` 与设置页 `.chip` 未含；`.npchip.on` hover 优先级未区分。

### 1.1.7.45 —— `#npNextTrackHero` 状态机（表 #15）

- 判据：`tests/test_native_nowplaying_web.mm` 追加 6 条（有下一首/队列末尾/单曲循环/停止/换歌）。
- 旧码（1.1.7.44）：**5 FAIL** → 新码 **82P / 0F**。
- 证据：`evidence/native-nexttrack-{red,green}-20261114.log`。
- 挂账：web 只在 `!playing`（停止）时隐藏，暂停仍显示（与任务书措辞不同，待确认）。

### 1.1.7.44 —— 控制区逐值（表 #48 / #49 / #56）

- 判据：`tests/test_native_nowplaying_web.mm` 追加 15 条（seek `barThickness` 5→7 + hover 跟踪区、
  pos/dur 12pt/42 宽/居中、vol 104 + vlab 11pt/58 宽/右对齐）。
- 旧码（1.1.7.43）：15 条里 **10 FAIL**（其余 3 条 hover 子判据因 `barThickness` 不存在跳过）。
- 新码：**75P / 0F**（60 既有 + 15 新）。
- 证据：`evidence/native-controlrow-{red,green}-20261114.log`。

### 1.1.7.43 —— 响应式字号/行距（表 #13 / #41）

- 判据：`tests/test_native_nowplaying_web.mm` 追加 18 条（640/800/1080 三档真实窗口高度）。
- 旧码（1.1.7.42）：**9 FAIL** → 新码 **60P / 0F**。
- 证据：`evidence/native-responsive-type-{red,green}-20261114.log`。

### 1.1.7.42 —— 面板内置收起键 `#npAnalHide` / `#npRailHide`（表 #27 / #34）

- 判据：`tests/test_native_nowplaying_web.mm` 追加 9 条（两枚键存在、各 22×22、圆形、两盏灯点击后
  panel.hidden + 同一 `NSUserDefaults` 键）。
- 旧码（1.1.7.41）：**2 FAIL**（两枚键都不存在；其余 7 条因控件缺失被跳过）。
- 新码：**42P / 0F**（33 既有 + 9 新）。
- 证据：`evidence/native-playback-hidekeys-{red,green}-20261114.log`。

### 1.1.7.41 —— 循环模式图标 + `#npRepOne` 角标（表 #51 / #52）

- 判据：`tests/test_native_nowplaying_web.mm` 追加 12 条（4 档 symbol 映射 + 4 档角标可见性 + 图标互异 + 文字）。
- 旧码（1.1.7.40）：12 条里 **10 条 FAIL**（只剩「`np.rep` 存在」「mode=2 时角标不可见」两条碰巧成立）。
- 新码：**33P / 0F**（21 既有 + 12 新）。
- 证据：`evidence/native-playback-mode-{red,green}-20261114.log`。
- 挂账：原生 SF Symbol 与 web 四条 SVG 路径造型非 1:1（语义/档位映射对齐）。

### 1.1.7.40 —— 停止/切曲 `#npKind` 复位（表 #12 / #60）

- 判据：`tests/test_native_nowplaying_web.mm` 追加 3 条（真实 `/api/status → refresh → 渲染`）。
- 旧码（1.1.7.39）：18P / **2F**（`stopped state resets npKind…`、`track switch resets npKind…`）。
- 新码：**21P / 0F**。
- 证据：`evidence/native-playback-states-20261114.md`、`native-playback-state-{red,green}-20261114.log`。
