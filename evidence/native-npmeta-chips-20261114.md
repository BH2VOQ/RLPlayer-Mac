# native ↔ web：正在播放页 `#npMeta` 芯片行（`.badge` + `.chip` + flex-wrap）

- 日期：2026-11-14
- 仓库：`/Users/august/Downloads/DQ/RLPlayer`，branch `main`，HEAD `b894c12`（1.1.7.26）
- 写者：single writer（本任务包）
- 范围：`tools/native_ui/RLPNowPlayingViewController.mm` 的 `#npMeta` 一行（不含 web 侧改动）
- 纪律：全程没有启动核心、没有碰音频设备、没有创建可见窗口、没有无头浏览器；测试用 `RLPCoreClient` 桩，点击走 target/action（不弹真弹层）。

## 1. web 真相 → 原生落点

| 项 | web 真相（源文件:行） | 原生实现 | 判据 |
|---|---|---|---|
| 行容器 | `.npmline`：`display:flex;align-items:center;gap:6;flex-wrap:wrap;margin-top:10;min-height:22`（`src/net/ui_page.h:824`） | `metaChipsRow #npMeta`；行顶 = 副标题行底 + 10；行高按实际行数算（行间 6，`min-height` 22） | 1180 单行 h=24；640 两行 h=54；无重叠、gap≥6 |
| 徽标 | `.badge`：9.5px/600、`letter-spacing:.3`、`padding:2 7`、radius 5、bg/border `--acc-weak`、color `--acc-text`（`ui_page.h:1096`） | `npMeta.year/genre/albumArtist/enriched` 四个 NSButton，attributedTitle 9.5/600/kern.3，layer radius 5、1px border、bg/border = `theme.accentWeak`、文字 = `theme.accentText` | 测试逐值断言（字号/字重/kern/radius/border/三色） |
| 已补全 | `.badge.g`：bg `--ok-bg`、color `--ok-text`、border `--ok-line`（`ui_page.h:1097`） | `npMeta.enriched` 用 `theme.okBg/okText/okLine` | 三色断言 |
| 徽标文案 | `label + '  ' + v`（两个空格）；tooltip `来源: <sources[key] or 本地标签>`（`ui_script.h:4237-4249`） | `[NSString stringWithFormat:@"%@  %@", label, v]`；tooltip `来源: …`，缺 source 回落「本地标签」 | `年份  2019` 精确等值；tooltip 含来源 / 回落词 |
| EQ/IR | `npEqChipsHtml()`：settings `ADV.eq/ADV.ir` 非空才出；tooltip `当前 EQ：<basename>（点击打开 EQ 与房间校正）`；click = `closeNowPlaying(); openSettingsTab('eq')`（`ui_script.h:12755-12765`） | `npEqChip/npIrChip`；值来自 `/api/settings` 的 `kv.eq/kv.ir`（复用原有 10s 节流的那一次请求，**未新增轮询**）；click 依次 post `RLPCloseNowPlayingNotification` + `RLPOpenSettingsPaneNotification(@"eq")` | 同 superview；11pt/radius12/bg3/line/txt2；tooltip 含 basename；通知顺序+对象 |
| 投放/加歌单 | `npCastBtnHtml()`：两个 `.chip`（`ui_script.h:8918-8927`）；`#npMeta.innerHTML = meta + eq/ir + cast/add`（`ui_script.h:13516`） | `npCastBtn` / `npAddSq` 移进 `#npMeta`；action 仍是既有的 `onCastCurrent:` / `onSaveCurrent:`；`.chip` 度量 | superview=行；target/action 断言；点击加歌单真的发出 `/api/sq/list`（既有保存路径） |
| 行可见性 | web 里三段都在 `#npMeta`，徽标为空时行仍可能由 EQ/IR/cast/add 撑起 | 行可见 = **任一芯片可见**（不再用 `meta.enriched` 总闸门）；enriched=false 只隐藏四个徽标 | enriched=false + kv.eq → 行可见、EQ 可见、四徽标全隐藏 |
| 行位与按钮行 | 行在副标题下 10px；按钮行不应压上来 | 旧按钮行（隐藏的历史入口 `npCompare`/`np.works`）从固定 `infoY+113` 改为 `行底 + 6` | 断言按钮行 y 在行底之下 |

## 2. 改了什么（文件与行数）

| 文件 | 改动 |
|---|---|
| `tools/native_ui/RLPNowPlayingViewController.mm` | +197 / −46（见 `git diff --numstat`） |
| `tests/test_native_npmeta_chips.mm` | 新增 525 行（ctest `native_npmeta_chips`，TIMEOUT 120） |
| `CMakeLists.txt` | +18（注册测试目标） |
| `docs/i18n/*.tsv` / `src/net/i18n_table.h` | **未改**：复用的全是既有词条（`当前 EQ：`/`当前 IR：`/`（点击打开 EQ 与房间校正）`/`推送到设备`/`添加到歌单`/`已补全`/`来源`/`本地标签`/`年份`/`流派`/`专辑艺术家`），`gen_i18n_table.py --check` OK（2318 pairs） |

关键实现点：

1. `styleMetaBadge:green:` / `styleMetaChip:` 把 web `.badge` / `.chip` 的每个值落到 NSButton 的 attributedTitle + CALayer（颜色全部取 `RLPTheme` 的对应令牌，**没有自造色**）；`applyTheme` 里补 `restyleMetaChipsForTheme`，切主题不会停在旧色。
2. `renderMetaChipsFromMeta:` 拆成「徽标三值 + 已补全 + 统一可见性判定」；徽标仍是 enriched 才出，但**不再整行隐藏**。
3. `applyMetaChipVisibility`：EQ/IR 取 `eqPath/irPath`（settings.kv）；cast/add 需要「live」态（`polling || webStatus != nil`）。
4. `layoutMetaChipsInWidth:`：按文字实测宽度分箱换行（徽标固有宽 = 文字 + 2×7 + 2×1，高 22；chip = 文字 + 2×9 + 2×1，高 24），行高 = 该行成员最大高（矮的在行内垂直居中），行间 6。
5. `layoutWebPlayback`：`#npMeta` 行顶 = 副标题底 + 10，行高来自实际行数；隐藏的 compare/works 按钮行跟着行底 +6 下移。
6. `anlRefreshAutoSettingIfStale` 读完 `kv.autoanl` 后继续读 `kv.eq/kv.ir` 并刷新芯片 —— 与 web `loadSettings` 同一份响应，10s 节流原样，**没有新增任何请求**。
7. `onSaveCurrent:` 在无窗口时把 popover 锚点交 `nil`（请求路径照旧）——与既有 `onRailCard` 的离屏守卫同一套纪律；真机有窗口时行为不变。

## 3. 红 → 绿（先红后绿，同一份测试）

| 阶段 | 生产码 | 结果 | 日志 |
|---|---|---|---|
| RED | 1.1.7.26 原版（临时 `git checkout` 回原文件，测试与 CMake 已在位） | **19 passed / 16 failed**，exit 1 | `evidence/native-npmeta-chips-red-20261114.log` |
| GREEN | 本轮修改后 | **83 passed / 0 failed**，exit 0 | `evidence/native-npmeta-chips-green-20261114.log` |

红的关键失败（原版确实做不到的点）：徽标 11pt/radius10/无 kern/`bg2`、`已补全`不是绿令牌、`npEqChip/npIrChip` 不存在、enriched=false 行整行隐藏、窄宽行高恒 22（无换行）、行顶压在副标题上（rowY=154.2 == subMaxY=154.2）、`npCastBtn/npAddSq` 不在行内且无 live 语义。

覆盖场景（`tests/test_native_npmeta_chips.mm`）：

1. 1180px：四个徽标逐值（9.5/600、kern .3、radius 5、1px、acc-weak 三色、`年份  2019` 两个空格、来源/本地标签 tooltip、绿三令牌）；EQ/IR 同 superview + `.chip` 度量 + basename tooltip + 点击通知（先 close 再 open-settings `@"eq"`）；cast/add 在行内、action 指向生产方法、点击加歌单发出 `/api/sq/list`；单行高 24 且不溢出。
2. enriched=false + kv.eq：行仍可见、EQ 可见、四个徽标全隐藏（不再「整行隐藏」）。
3. 窄宽 640：`h 24 → 54`（两行），8 个芯片两两不相交、gap≥6、行不压标题/副标题、按钮行在行底之下、行底不压分析/AI 面板；回到 1180 行高收回 24。
4. 无任何芯片数据（无 meta/无 settings/无 status）：行隐藏、EQ/投放不摆空壳（与审计⑤a 同一契约）。

## 4. 门禁（串行，机器空闲）

| 门禁 | 命令 | 结果 |
|---|---|---|
| 构建 | `$CM/cmake --build build-mac -j8` | **exit 0** |
| 全量单测 | `$CM/ctest --test-dir build-mac -j1 --output-on-failure` | **190/190 passed, 0 failed**（基线 189 + 本包 1；真实 362.58 s，exit 0） |
| 功能审计 | `RLPLAYER_STATE_DIR/LIBRARY/HOME` 隔离 → `rlplayer_native --audit <tmp/shots>` | **246 passed, 0 failed**（与基线一致；`evidence/native-npmeta-chips-audit-20261114.log`） |
| 移植扫描 | `python3 tools/native_ui/parity_scan.py --check` | `total=317 done=299 missing=0 removed=2 na=16`；na 16 ok/0 bad，removed 2 ok/0 bad，exit 0 |
| 行为扫描 | `python3 tools/native_ui/behavior_scan.py --check` | `total bindings=50 actionable=0`，exit 0 |
| i18n | `python3 tools/gen_i18n_table.py --check` | `OK: i18n table up to date (2318 pairs)`，exit 0 |

指定保留绿的用例（本次 ctest 输出逐个核对）：`native_rail_cards`、`native_rail_preview`、`native_analysis_panel`、`native_npmeta_chips`、`native_tracks_rows`、`native_nowplaying_web` 全部 `Passed`。

## 5. 布局验证（1180 / 窄宽）

- 1180px、中文：`#npMeta` frame = `(224.4, 164.2, 931.6 × 24)`；8 个芯片同一行，最后一个不超出 `iw`。
- 640px（离屏窄帧，触发换行）：`#npMeta` frame = `(224.4, 164.2, 391.6 × 54)`；行底 218.2 < 面板顶 244.4。
- 900px（**主窗口最小宽度**）英文：徽标/芯片文案变长后真实换行——`Add to Playlist` 掉到第二行，行高 54，行底 218.2 < 面板顶 244.4。离屏渲染截图（一次性探针产物，未进仓库）：`/tmp/npmeta-1180-en.png`、`/tmp/npmeta-900-en.png`、`/tmp/npmeta-640.png`。
- 480px（低于窗口最小宽度 900，不可达）：3 行、行底 246.2 比面板顶 244.4 多 1.8pt —— 见第 6 节残余项。

## 6. 残余 / 风险（如实挂账）

1. **投放的运行态未移植**：web `npCastBtnHtml` 在投放中显示 `已推送到 <device>` 且点击 = 停止（`castToggle`）；本包按要求保留既有 `onCastCurrent:`（打开设备弹框），因此原生始终显示 `推送到设备`。夹具里的 `/api/cast/state`（未投放）没有被读取 —— 没有新增 cast 状态轮询，也就没有「已推送」态。**这是与 web 的已知差异，不是本次遗漏的测试失败。**
2. **芯片图标**：web 的 EQ/IR/cast/add `.chip` 各带 11–12px 内联 SVG;原生是纯文字芯片。度量、tooltip、动作、位置一致，图标是纯装饰差异。
3. **<900px 窄帧**：主窗口 `minSize = 900×600`，480px 一类的 3 行布局不可达；若将来放开最小宽度，需要给行高与面板顶之间加钳制（当前只保证 900/640 验证宽度不压面板）。
4. **「live」可见性口径**：web 的 cast/add 恒显示（`CAST.state` 启动即读）；原生没有全局 cast 状态缓存，故 cast/add 只在 `polling || webStatus` 时出现（真机上页面可见即满足），EQ/IR 只在 settings 回来后出现。这也是审计⑤a「无数据时行隐藏」能继续成立的原因（审计不在本包写白名单内）。enriched=false + 有 EQ/IR 时行仍显示，已由场景 2 固定。
5. **实机视觉验收未做**：遵循项目分工，真机（装 /Applications、真点）由用户执行。本包只有离屏几何断言 + 一次性位图探针；没有播可听音频、没有打开可见窗口。
6. 本次只验证 `#npMeta` 一行；`max-height:720px` 的 web 媒体查询（`.npmline{margin-top:6;min-height:20}`，`ui_page.h:1066`）没有移植（窗口 760 高时不生效，600 高时会差 4pt），属于已知未覆盖项。
