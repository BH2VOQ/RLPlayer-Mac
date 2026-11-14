# 播放页差异移植（按 `evidence/native-4-playback-diff.md` 逐项红→绿）

对照表：`evidence/native-4-playback-diff.md`（web `#np` 选择器 → 原生落点 → 状态）。
本文件按包记录每项的判据、旧码红数字、新码绿数字。

## 包 1（1.1.7.40）：停止/切曲时 `#npKind` 状态机复位

### 差异（对照表 #12 / #60）
- web：`renderNp()` 每次都 `D('npKind').textContent = npPlayingKindText(S.curMeta)`；
  `npPlayingKindText(null)` 返回纯「正在播放」，有格式字段才追加 ` · CODEC / kHz / bit`。
  所以停止（`curMeta` 清空）后标题行回到纯「正在播放」。
- 原生 1.1.7.39 及以前：`kindLabel` 只在 `/api/meta` 异步回来时覆盖 ⟹
  **停止后仍挂着上一首的「正在播放 · FLAC / 48 kHz / 24 bit」**（用户可见的假信息）；
  且 `/api/meta` 缺 codec/sampleRate/bits 时无条件拼分隔符 ⟹「正在播放 · 」（尾部悬挂）。

### 判据（`tests/test_native_nowplaying_web.mm` 追加 3 条，走真实 `/api/status` → `refresh` → 渲染）
1. `npKind` 带 `FLAC / 48 kHz / 24 bit`（前提：证明工装真的走了 meta 渲染路径）；
2. 停止态（`current=""`、`playing=0`）后 `npKind` **逐字等于**「正在播放」（旧码红）；
3. 切曲后新 meta（无 codec）回来前 `npKind` 仍是「正在播放」，不是上一首的格式串（旧码红）。

桩说明：测试里的 `RLPCoreClient` 替身新增「按路径前缀返回固定 JSON」的 fixture 表
+ `getData:` 应答（`refresh` 会顺带请求 `/api/cover`；缺这个方法时第二次跑直接
`doesNotRecognizeSelector` → SIGABRT，已修在测试工装里，与产品代码无关）。

### 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.39） | **18 passed / 3 条新判据中 2 条 FAIL**（`stopped state resets npKind…`、`track switch resets npKind…`）|
| 新码 | **21 passed / 0 failures** |

证据：`evidence/native-playback-state-red-20261114.log` / `-green-…log`。

### 实现
- `refresh` 的「切曲/停止」分支先 `kindLabel = RLPTr(@"正在播放")`，再由新 meta 覆盖；
- `loadMetaAndKnowledgeForPath` 的格式串改为「有字段才拼 ` · `」，否则纯「正在播放」。

## 包 2（1.1.7.41）：循环模式图标 + `#npRepOne`「1」角标

### 差异（对照表 #51 / #52）
- web `applyRep(v)`/`cycleRep()`（`ui_script.h` L6117/6145）：四档 0 顺序 / 1 列表循环 / 2 单曲循环 / 3 随机，
  **图标随档位换**（`REP_ICON[0..3]` 四条 SVG 路径），`aria-label`/`title` 同步换，
  `#npRepOne` 的「1」角标**只在单曲循环** `display:''`。web 注释明写「只改颜色不改图标是明令禁止的假修」。
- 原生 1.1.7.40：整页 `#npRep`（`repBtn`）**永远 `repeat` 图标、没有「1」角标**，
  用户看不出当前是顺序/列表/单曲/随机（只有右键/设置页能查）。

### 判据（`tests/test_native_nowplaying_web.mm` 追加）
1. `np.rep` 控件存在（前提）、`npRepOne` 角标存在（旧码红）；
2. 0..3 四档逐档：`playModeSymbol` 等于 web `REP_ICON` 的等价 SF Symbol
   （`arrow.right`/`repeat`/`repeat.1`/`shuffle`）（旧码红，方法缺失/属性为空）；
3. 四档图标互不相同（旧码红）；
4. 「1」角标只在 2（单曲循环）可见（旧码红），且文字是 `1`。

### 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.40） | 12 条新判据里 **10 条 FAIL**（只有 `np.rep` 存在、mode=2 时"角标不可见"两条碰巧成立）|
| 新码 | **33 passed / 0 failures**（21 条既有 + 12 条新） |

证据：`evidence/native-playback-mode-red-20261114.log` / `-green-…log`。

### 实现
- `RLPNPControlBar` 新增 `repBadge`（identifier `npRepOne`，10pt/700，`hidden=YES` 默认），
  布局放在循环键右上角（web `margin-left:22 / margin-top:-18` 的等价位）。
- `RLPNowPlayingViewController -applyPlayModeUI`：按 `playbackMode` 选 SF Symbol + `REP_META[].aria`
  tooltip + 单曲循环才显示角标；`onCycleMode` 与 `/api/queue` 读回（`refreshQueueContext`）后都调用它，
  `buildContent` 末尾初始化一次。
