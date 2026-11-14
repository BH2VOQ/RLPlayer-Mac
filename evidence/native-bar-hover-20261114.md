# 底部播放条 `.k` / `.k.big` hover 态（1.1.7.56）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `4b7d99c`（1.1.7.55）
分支：main（**仅本地提交，未推送 / 未发版 / 未打 tag**）

> 关闭 `evidence/native-hover-20261114.md` 挂账 1 与 `evidence/native-known-deviations-20261114.md`
> #9 的**底栏部分**：web 底栏 5 个 `.k` 键有 hover 反馈，原生此前只有 AppKit 默认按下高亮
> （用户悬停看不到任何变化）。设置页 `.chip` 不在本包范围，仍挂账。

## 1. web 真相（`src/net/ui_page.h`）

| 行 | 规则 |
|---|---|
| `:1081` | `.k{width:32px;height:32px;border-radius:9px;color:var(--mut);transition:.13s}` |
| `:1082` | `.k:hover{background:var(--hov2);color:var(--txt)}` |
| `:1084` | `.k.big{width:34px;height:34px;border-radius:50%;background:var(--acc);color:#fff;box-shadow:0 2px 10px var(--acc-weak)}` |
| `:1085` | `.k.big:hover{filter:brightness(1.08)}` |
| `:276` | `.ibtn{...;color:var(--mut)}` / `:277` `.ibtn:hover{background:var(--hov2);color:var(--txt)}`（同值） |
| `:1594-1600` | 底栏 `.keys` 里 `#bRep/#bPrev/#bPause(.k.big)/#bNext/#bStop` 都是 `.k` |

## 2. 判据（`tests/test_native_bar_web.mm` 追加，315 → 346 条）

判据量 hover 前后**实际视觉值**（`CALayer.backgroundColor` / `contentTintColor` 逐分量），
并验证 `respondsToSelector(@"setHovered:")` + `trackingAreas.count >= 1`（证明鼠标真能触发），
不是「有跟踪区就算过」。与 np 页 hover 判据同口径：

- `pb.repeatBtn` / `pb.prevBtn` / `pb.nextBtn` / `pb.stopBtn`（`.k`）：
  有 hover 状态机、有跟踪区、静态无底色、静态图标色存在；
  hover → 底 = `--hov2`、图标色 = `--txt`；退出 → 透明底 + **恢复 hover 前图标色**。
- `pb.play`（`.k.big`）：有 hover 状态机、静态底 = `--acc`（圆形红键，不能被清成透明）；
  hover → 底色变化（web brightness 1.08）；退出 → 恢复 `--acc`。

**为什么静态图标色不写死 `--mut`**：底栏 `applyTheme` / `refreshModeButtons` 会按主题和播放模式
改写 tint（`repeat`/`shuffle` 激活时是 `--acc`）。判据捕获 hover 前基线并要求退出恢复，
这样既验证 hover 状态机、又保证「hover 一次不会抹掉播放模式强调色」，而不把底栏既有的
静态色偏差卷进本包。

## 3. 红 → 绿

| 轮次 | 二进制 | 结果 | 证据 |
|---|---|---|---|
| 旧码（1.1.7.55） | 改前 | **315 passed / 5 failed**（5 个键都没有 hover 状态机，视觉判据按设计跳过） | `evidence/native-bar-hover-red-20261114.log` |
| 新码（1.1.7.56） | 本包 | **346 passed / 0 failed** | `evidence/native-bar-hover-green-20261114.log` |

## 4. 实现

- 新增 `RLPBarKeyButton : NSButton`（`tools/native_ui/RLPPlaybackBarView.mm` 本地同构）：
  跟踪区（`NSTrackingMouseEnteredAndExited|ActiveInKeyWindow|InVisibleRect`）+ `hovered` 状态 +
  `hoverApplier` 视觉回调；`setHovered:` 是鼠标事件与判据共用的唯一入口。
  `viewDidMoveToSuperview` 时主动建跟踪区——离屏构造（无 window）时 AppKit 未必调
  `updateTrackingAreas`，不这么做判据里 `trackingAreas.count>=1` 会是假绿。
- `symbolButton:` 工厂改返回 `RLPBarKeyButton`，注入 `.k:hover` 语义：
  hover → `--hov2` 底 + `--txt` 图标；退出 → 透明底 + **恢复进入前 tint**（不抹掉 `--acc`）。
  `.ibtn`（歌词 / 信号链）同值，一并覆盖（web 也有 `.ibtn:hover`）。
- `pb.play` 单独覆盖为 `.k.big`：`accent` 混 10% 白（CSS `filter:brightness(1.08)` 的
  AppKit 等价近似，与播放页 `np.play` 同一取舍）；退出恢复 `accent`、白图标不变。
- **不复用播放页的 `RLPHoverButton`**：那个类定义在 `RLPNowPlayingViewController.mm` 内部，
  提到公共层会牵动播放页 191 条既有判据；本包只补底栏，本地同构一份
  （与 `RLPBarCoverView` 自管 tracking area 的既有做法一致）。

## 5. 门禁（1.1.7.56 树）

build 0 error；`rlplayer_native --audit` `246/0`；parity missing=0；behavior actionable=0；
i18n 三项 OK（2421 pairs，本包无新增中文文案）。
串行全量 ctest：首次 `200/201`（唯一红 `library` 时间敏感断言，见 §6.6）→ 干净复跑 `201/201`。
日志见 `evidence/native-56-*.log`（`native-56-ctest-final.log` 为交付依据）。

## 6. 如实挂账

1. **设置页 `.chip` 仍未做**：`native-hover-20261114.md` 挂账 1 的后半段、已知偏差 #9 已改为
   只挂设置页；底栏部分本包关闭。
2. `.k.big` 的 `brightness(1.08)` 用「混 10% 白」近似，不是 CSS filter 的像素级复刻
   （AppKit 无 filter API；播放页同款，已知偏差 #6）。
3. hover 判据走 `setHovered:`（与 `mouseEntered/Exited` 同一入口），**未做真实鼠标注入**
   （遵守「不做键鼠自动化」铁律）。
4. 底栏与播放页各有一份同构 hover 载体，未合并到公共层（避免牵动 191 条判据）——
   这是刻意的范围控制，不是遗漏；两处语义逐值一致。
5. 既有挂账不因本包关闭：`#npAnlBody` 左缘 1pt（已知偏差 #1）、`.npchip.on` hover 优先级
   （`native-hover-20261114.md` 挂账 4）、默认渲染器切换、双模式薄表现层、
   RENDERFAIL 根因（需用户诊断包）、`native_ui_functional` 偶发 bus error（open flake）。
6. **本包首次全量 ctest 的 `library` 偶发超时，不是本包回归**：
   `test_library` 是纯 C++（`CMakeLists.txt:1636`，只链接 iconv，不链接任何 `tools/native_ui`），
   与本包 UI 改动零关联。失败项是 `tests/test_library.cpp:891` 的时间敏感断言
   `[7.3] get_cover 在 200ms 预算内返回（<2000ms）`，首次冷启动实测 2352ms（第二次调用 223ms 正常）；
   同树前三轮全量（1.1.7.55）该用例均 0.96–1.34s Passed，本包单跑 5/5 通过（0.93–1.16s）。
   按「不改判据、不掩盖」纪律：保留原断言，另起一次干净全量复跑作为交付证据，
   此处如实记录该 flake（与 `native_ui_functional` 偶发 bus error 同类，属已知时间敏感项）。
