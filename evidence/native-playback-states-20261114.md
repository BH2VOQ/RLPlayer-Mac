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
