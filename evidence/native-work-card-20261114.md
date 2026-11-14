# 古典曲目第 4 张「作品」卡 + 作品抽屉（1.1.7.55）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `6d5d93f`（1.1.7.54）
分支：main（**仅本地提交，未推送 / 未发版 / 未打 tag**）

> 本包是上轮 `evidence/native-loop-gaps-20261114.md` §19 第 1 项（P2「古典曲目第 4 张作品卡」）的落地。
> 现场：本工单前几次重试已写入判据、实现、红/绿日志并把版本改到 1.1.7.55，但全量门禁留了
> 一条红灯（`native_i18n_coverage`）且未提交。本轮接力把门禁收干净、补齐证据、只做本地提交。

## 1. web 真相（逐行比对，不是照感觉写）

| web 函数 / 位置 | 语义 | 原生落点 |
|---|---|---|
| `npIsClassical(m)` `ui_script.h:12720` | composer 非空即古典；否则 genre/专辑名/曲名的古典体裁正则兜底 | `RLPNPIsClassical`（`RLPSupport.mm`）逐条移植，正则逐字符一致 |
| `npGuessComposer(m)` `:12731` | 曲名末尾 `(Tchaikovsky)` 或专辑名冒号前缀 `Beethoven: …`（≤3 词、纯拉丁） | `RLPNPGuessComposer` |
| `npWorkTarget(m)` `:12744` | 去掉末尾「(中文译名)」括号，Discogs 用原文；返回 `{title,composer}` | `RLPNPWorkTarget` |
| `npDataTargets(m)` `:12818` | 古典时追加 `{k:'work',label:'作品',name:w.title,composer}` | `loadMetaAndKnowledgeForPath` 里 `railTargets[@"work"]`；`renderRailMetadata` 第 4 张卡 |
| `npDataEnsure(kind)` work 分支 | `/api/entity/versions?kind=work&name=…&composer=…`，成功判据 `ok && performances.length` | `railUrlForTarget:` / `railHasWorkData:`；同一实体 in-flight 合并不重发 |
| `npRailPreview` work 分支 | p1 = 作曲家（无 fields 时兜底）、p2 = 体裁 | `renderRailMetadata` 的 `work` 分支，无 fields 时 p2 为空（不拿本地字段冒充） |
| `npDataWorkBody(d)` `:13123` | 来源行 `Discogs 实时 / 缓存 · 日期 · 不同演绎 N / 发行版本 M`；每条 `.npdwork` = `年份 | 标题 | 指挥·乐团·厂牌·格式`；空态两行 + `重试查询`；`npWorkOpen` 打开整页 | `RLPKnowledgeView -loadWorkName:composer:` 全套（加载态 / 空态 / 缓存态 / 版本行 / 打开整页） |
| `npDataActivate('work')` | 作品实体**没有 summary**，抽屉正文走 versions | `onRailCard:` 的 work 分支不再 `loadKind`，改 `loadWorkName` |

另外修掉旧码一处真错：`onOpenWorks:` 把「艺术家」当作曲家传给 `RLPOpenWorksNotification`，
Discogs 检索几乎必然 0 条；现改为 `RLPNPWorkTarget` 的 title + composer。

## 2. 判据（`tests/test_native_rail_preview.mm` 场景 5/6，46 → 78 条）

全部离线：夹具队列喂 `/api/entity/summary` 与 `/api/entity/versions`，不出声、不发真请求。

- 场景 5（右栏第 4 张卡）：古典夹具（专辑名 `Beethoven: Symphony No. 5`、genre `Classical`）⟹
  4 张卡、`npChip.作品` 存在且可见、卡名逐字「作品」；
  `/api/entity/versions?kind=work&name=Symphony%20No.%205&composer=Beethoven` 恰好发 1 次；
  p1 = `Beethoven`、p2 为空、状态「已整理」；点击 → `work` 实体带 composer；
  非古典夹具（J-POP）⟹ 作品卡不显示且**零 versions 请求**（不给流行曲发 Discogs）。
- 场景 6（作品抽屉正文）：`loadWorkName:composer:` 方法存在性；加载态文案「正在整理资料…」；
  2 条 performances ⟹ 2 行 `npWorkRow`，行首年份/标题/`指挥·乐团·厂牌·格式` 逐字；
  来源行含「Discogs 实时」与「不同演绎 2 / 发行版本 2」；
  `ok:false` 空态两行文案 + 「重试查询」按钮 + 不残留上一轮行；
  `from_cache:true` 来源行以「缓存」开头且仍有 2 行；
  `npWorkOpen` 点后发 `RLPOpenWorksNotification` 且带 title/composer。
- 同步改两条既有判据（不是删红判据，是跟着结构变化更新）：
  `test_native_rail_cards.mm` 从「3 张卡」改成「4 张槽、非古典可见 3 张、隐藏卡 frame 归零不占排版」，
  几何量只对可见卡；`test_native_nowplaying_web.mm` 先喂一份 meta 让栏目成立再量 chipwrap
  （否则 wrap 隐藏、卡片 0 帧，等于没量到真实滚动），并断言 4 个槽都在 wrap 内。

## 3. 红 → 绿

| 轮次 | 二进制 | 结果 | 证据 |
|---|---|---|---|
| 旧码（1.1.7.54） | 未改 | **46 passed / 3 failed** | `evidence/native-work-card-red-20261114.log` |
| 新码（1.1.7.55） | 本包 | **78 passed / 0 failed** | `evidence/native-work-card-green-20261114.log` |
| `test_native_nowplaying_web` | 本包 | **0 failures** | `evidence/native-work-card-npweb-green.log` |

旧码 3 条红：`cards=3`（无第 4 张卡）、找不到 `npChip.作品`、`RLPKnowledgeView` 无 `loadWorkName:composer:`。
全量串行 ctest 首次（本包实现已落、i18n 未收口）：**200/201**，唯一红 `native_i18n_coverage`
（`evidence/native-55-ctest.log`）——新增 `RLPTr(@"不同演绎")` / `RLPTr(@"发行版本")` 两个独立字面量
在词表里只有整串（`· 不同演绎` / `不同演绎 %ld / 发行版本 %ld`），没有独立键，英文界面会回落中文。

## 4. 收口修法（i18n，不是掩盖判据）

1. 新增 `docs/i18n/chunk-native118-work.en.tsv`：`不同演绎 → Performances`、`发行版本 → Releases`
   （术语沿用既有 `不同演绎 %ld / 发行版本 %ld → %ld distinct performances / %ld releases`）。
2. 重生成两份**生成物**（`src/net/i18n_table.h`、`tools/native_ui/RLPNativeI18n.mm`），各 +2 条；
   现场只有 web 表头被重生成过，原生表漏了 ⟹ `native_i18n_table_check` 一度也是红的，本轮补齐。
3. 三条门禁同时绿：
   `check_native_i18n_coverage.py` 0 missing（词表键 2421）、
   `gen_i18n_table.py --check` OK（2421 pairs）、`gen_native_i18n.py --check` OK（2421 pairs）。
4. 顺手修同包内两处一致性：`onOpenWorks:` 注释仍写「原生不假装自动判定」（与新的自动判定矛盾），
   `onRailCard:` work 分支把两条语句挤在一行。均为注释/排版，不改行为。

## 5. 实现清单（改动文件）

| 文件 | 内容 |
|---|---|
| `tools/native_ui/RLPSupport.h/.mm` | `RLPNPIsClassical` / `RLPNPGuessComposer` / `RLPNPWorkTarget`（公共层单一真相源，4 处入口共用） |
| `tools/native_ui/RLPKnowledgeView.h/.mm` | `loadWorkName:composer:` + `workUrlWithRefresh:` / `fetchWorkRefresh:` / `renderWorkRows:` / `renderWorkEmpty:` / `workSourceLine:`；`npWorkRow`/`npWorkYear`/`npWorkTitle`/`npWorkMeta`/`npWorkHintSub`/`npWorkOpen`/`knowledgeStatus`/`knowledgeRefresh` 锚点 |
| `tools/native_ui/RLPNowPlayingViewController.mm` | 右栏 4 张卡（隐藏卡不参与排版、frame 归零）、work URL / 成功判据 / 预览 / 点击实体、`railFpForKind` 指纹含 composer、`onOpenWorks:` 改取作品名+作曲家 |
| `tests/test_native_rail_preview.mm` | 场景 5/6（+248 行判据） |
| `tests/test_native_rail_cards.mm` / `test_native_nowplaying_web.mm` | 既有判据随 4 卡结构同步 |
| `docs/i18n/chunk-native118-work.en.tsv` + 两份生成表 | 2 条新词 |
| `src/version.h` | 1.1.7.54 → **1.1.7.55** |

## 6. 门禁（本包最终复跑，日志见 `evidence/native-55-*.log`）

build 0 error；串行全量 ctest `201/201`；`rlplayer_native --audit` `246/0`；
parity missing=0（view 14 / tab 10 / ctrl 179 / api 96，na 16 全可复核、removed 2 双向核验）；
behavior actionable=0（50 bindings）；i18n 三项 OK（2421 pairs）。

## 7. 如实挂账（不是回归，勿反复查）

1. **离线判据**：场景 5/6 用夹具队列，没有真连 Discogs；端点形状、URL 编码、回包解析有判据，
   「真网络能搜到某作品」这条没有实跑（避免给后台灌测试请求）。
2. **版本行不是逐像素复刻 web `.npdwork`**：web 是 `年份/标题/右侧 meta` 三列 + 每行「复制版本链接」按钮；
   原生用 `NSStackView` 三列（年份固定 38pt、标题 ≥60pt、meta 可压缩 + 省略），
   **没有移植「复制」按钮**（web 的 `chip-copy` 是复制 URL 到剪贴板）。功能等价差距，挂账。
3. **缓存日期**：web `fmtDate(generated_at)` 的完整格式未逐字复刻，原生用 `yyyy-MM-dd`。
4. **抽屉形态**：沿用 1.1.7.54 的页内抽屉（无 backdrop blur、无滑入动画），
   见 `evidence/native-known-deviations-20261114.md` #5，本包不改。
5. **作品卡数据依赖右栏 summary 闸门**：web 的 work tab 同样受 `npDataCan` 限制；原生沿用既有闸门，
   未额外做「闸门关也强制拉 versions」的超集。
6. 既有挂账不因本包关闭：底部播放条 `.k` / 设置页 `.chip` hover（`native-hover-20261114.md` 挂账 1）、
   `#npAnlBody` 左缘 1pt 差（已知偏差 #1）、默认渲染器切换、双模式薄表现层、RENDERFAIL 根因
   （需用户诊断包）、`native_ui_functional` 偶发 bus error（open flake）。
