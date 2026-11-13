# AI 整理右栏 · 内容预览与点击实体修正（1.1.7.24）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `938d50f`（1.1.7.23，工作树仅 `?? website/`）
分支 main（仅本地提交，未推送）· 提交：`feat(native): AI rail content previews and correct card entities, 1.1.7.24`

本轮属于「比对 web 代码 → 开发 → 再比对」循环中的内容级比对：上一轮只对齐了三卡的
**几何**（`native_rail_cards` 56 项），本文件对齐的是**卡里显示什么、状态怎么走、点了打开谁**。

## 0. 基线（改前实测）

| 门禁 | 数字 | 证据 |
|---|---|---|
| build | `cmake --build build-mac -j8` exit 0 | 终端 |
| ctest | 186/186 passed（串行） | 上一轮 `native-3-ctest.log` |
| audit | 246 passed / 0 failed | `evidence/native-rail-preview-audit-246.log` 同轮基线 |
| parity | ctrl done=180 / api missing=0 / removed=1 / na=16 | 终端 |
| behavior | actionable=0（bindings 50） | 终端 |
| i18n | OK（2316 pairs） | 终端 |

## 1. 判据红 → 绿（同一份用例，旧码 vs 新码）

新增 ctest `native_rail_preview`（`tests/test_native_rail_preview.mm`，45 条断言，桩客户端，不出声/不联网/不上屏）：

| 运行对象 | 结果 | 证据 |
|---|---|---|
| 旧码 `938d50f`（生产未改，只加用例） | **8 passed / 37 failed** | `native-rail-preview-red-20261114.log` |
| 新码（本提交） | **45 passed / 0 failed** | `native-rail-preview-green-20261114.log` |
| Lead 复跑（提交前） | 45/0；旧几何用例 `native_rail_cards` 仍符合 | `native-rail-preview-lead-verify.log` / `native-rail-cards-lead-verify.log` |

旧码红的关键原文：

- `【歌曲卡】p1=「夜想曲」`（只显示曲名，不是 fields 里的 `演唱 Aimer · 作曲 梶浦由記`）；
- `【艺术家卡】p1=「Aimer」`（没有简介，sections 首段兜底也是 `Aimer`）；
- `【点击】专辑卡 loadKind=track`、`艺术家卡 loadKind=track`（`b.tag` 从未赋值，三张卡都打开歌曲实体）；
- `【资料不足】status=点开查看`（把终局结论当普通可点资料）。

## 2. web 与原生逐项对照（内容唯一真相源 = web `npRailPreview`）

| 项 | web（`src/net/ui_script.h`） | 原生（本提交） |
|---|---|---|
| 取数闸门 | `npDataCan`：`META.summary && (summaryAvailable || summaryCached || summaryCacheOk || hasLlmKey)`（12839-12852） | `railSummariesEnabled`：读 `/api/meta` 的 `summaryEnabled + summaryAvailable/summaryCached/summaryCacheOk/hasLlmKey`；关时零请求 |
| 栏目实体 | `npDataTargets`（track=title+artist+album；release=album+summaryArtist/albumArtist/artist；person=albumArtist/artist）（12818-12838） | `railBeginSummariesForMeta:` 同一套目标与空值规则（album==title 时不出专辑卡） |
| URL | `npSummUrl`：track 追加 album/file/genre；artist 非空才带；`lang=zh`（13230-13260） | `railUrlForTarget:` 逐参数、同顺序、同 `RLPEnc`（= encodeURIComponent） |
| pending 轮询 | `fetchJsonPendingOnce`：retryAfterMs 夹 150..2000、默认 400、120s 墙钟（2180-2215） | `railFetchSummaryUrl:` 同夹取/同预算；世代号 + 实体指纹双守卫 |
| 缓存/单飞 | `summaryOnce`：同 URL 缓存、在飞合并、insufficient 不缓存（2224-2255） | `railSummaryCache` / `railSummaryInflight`；insufficient 不写缓存 |
| 歌曲卡 p1/p2 | `演唱/作曲/作词/编曲` → `歌曲风格/发行时间/所属专辑/衍生作品`；兜底本地 `artist·album` / `CODEC·96k·24bit·时长`（12962-13000） | `railPreviewForKind:track` 逐分支同构；本地兜底同字段 |
| 专辑卡 p1/p2 | `artist·year·N首·总时长`（`npLocalAlbum` 本地真值）+ `出版方/专辑类型/语种/发行时间`；再兜底格式标签（12975-13010） | `railLoadAlbumForTarget:`（`/api/lib/albums`→`/api/lib/album`，按 `专辑名|艺术家` 缓存）+ 同样字段顺序与格式兜底 |
| 艺术家卡 | `npRailBio`：`fields['简介']` → `sections` 首段，名字未开头才补 `名字：`；简略 40 字截断、详细不截断（12933-12960） | `railBioFromData:who:limit:` 同三级兜底/同截断/同「名字：」规则 |
| 状态短语 | 空 / 整理中… / 资料不足 / 暂无资料 / 已缓存或已整理（13035） | `railPreviewForKind:` 同五态，ok 态按 `from_cache` 选「已缓存/已整理」 |
| 资料不足 | `npInsufficientText` 终局结论；p2 空、不拿本地事实冒充（12981-12986） | 同：`资料不足：缺少艺术家与曲名` + p2 空 |
| 详细档 | `npRailLimits`：pick 4 / bio 0；CSS clamp p1 5 行、p2 2 行，line-height 1.35（12876-12877、13061-13062） | `kRailDetailLineHeight=1.35`；实测文本高度，p1 最多 5 行、p2 最多 2 行；卡高按文本撑开，简略档保持原单行几何 |
| 档位持久化 | localStorage `rta-np-raildetail`（12880-12894） | NSUserDefaults `RLPNPRailDetail`；切档只重绘、不重新取数 |
| 点击卡 | `npDataToggle(kind)` 打开对应实体（13082） | `onRailCard:` 用 `chipIndex` 映射 `track/release/person`（修复 `b.tag` 恒 0 的错位）；离屏无窗口时不弹 NSPopover（测试/审计安全） |

## 3. 门禁（提交前实测）

| 门禁 | 数字 | 证据 |
|---|---|---|
| build | `cmake --build build-mac -j8` exit 0 | 终端 |
| ctest | **187/187 passed, 0 failed**（366.09s 串行；181→187 新增本轮用例） | `native-rail-preview-ctest-187.log` |
| audit | **246 passed, 0 failed**（exit 0） | `native-rail-preview-audit-246.log` |
| parity | ctrl done=179 **missing=0** removed=2（2 ok / 0 bad）na=16（都 ok） | 终端 |
| behavior | actionable=0（bindings 50） | 终端 |
| i18n | **OK（2318 pairs）**（新增「资料不足 / 资料不足：缺少艺术家与曲名」两条） | 终端 |

## 4. 视觉证据（同一审计夹具、同视口、同主题）

| | 文件 | 说明 |
|---|---|---|
| Before（基线 1.1.7.23） | `native-rail-before-20261114.png` | 右栏三卡：状态「暂无…」+ 正文「暂无资料」，内容只有本地曲名/专辑/曲风 |
| After（本提交） | `native-rail-after-20261114.png` | 同一审计夹具（无 AI key）：不再出现「点开查看」假状态；有 AI 数据时的三卡正文由 `native_rail_preview` 的 45 条断言固定（夹具字段→卡片文本逐字比对） |

> 审计夹具本身没有 LLM 元数据，所以截图只证明「结构/状态回退」这一半；「AI 字段真的进卡片」由
> `native_rail_preview` 的桩客户端夹具（track/release/person + insufficient + sections 兜底）证明。

## 5. 如实挂账（本轮未做，留给下一轮）

1. **古典曲目的第 4 张「作品」卡**（web `npDataTargets` 的 `work`）：原生仍只有 3 张固定卡；作品页入口在右键菜单/单曲页已有，未删功能。
2. **点卡后的呈现形态**：web 是从右侧滑出 `#npDrawer`（430pt 抽屉，含完整 fields/sections + 重试）；原生仍是 420×380 的 NSPopover。本轮只修「打开哪个实体」，未改形态。
3. **`npSummHint` 行与 `nprailempty`**：web 在卡片区下方显示「正在后台整理歌曲资料…/失败点击重试」，无栏目时显示整块空态文案；原生固定 3 卡恒显示，此两处未做（本轮审计夹具无 meta 时卡片为空白，就是该差异的可见表现）。
4. **实机验收**：本轮全部为离屏审计 + 单测；真实 AI 端点/真实点击由用户实机验收。

## 6. 改动清单

| 文件 | 行数 | 内容 |
|---|---|---|
| `tools/native_ui/RLPNowPlayingViewController.mm` | +658/−30 | 卡片详细档布局、summary 数据层（闸门/目标/URL/缓存/轮询/预览/状态）、点击实体修正、档位持久化 |
| `tests/test_native_rail_preview.mm` | 新增（45 断言） | 红→绿判据：字段进卡、两档、点击 kind、闸门关闭、资料不足、sections 兜底、URL 形状 |
| `CMakeLists.txt` | +15 | 注册 ctest `native_rail_preview` |
| `docs/i18n/chunk-release117-rail.en.tsv` + `src/net/i18n_table.h` | +2 对 | 两条新文案（生成物不手改） |
| `evidence/*` | 新增 | 红/绿/门禁/Lead 复跑日志与前后截图 |
