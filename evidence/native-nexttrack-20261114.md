# `#npNextTrackHero` 状态机（1.1.7.45，按对照表 #15）

## web 真相（`ui_script.h` `updateNextTrackInfo()`）
```
if (!S.playing || !qLen) { el.style.display = 'none'; heroEl.style.display = 'none'; return; }
curIdx = S.q.index（缺失时 items.indexOf(S.lastCur)）
mode 0 顺序 / 1 列表循环 / 2 单曲循环 / 3 随机
  mode==2            → nextIdx = curIdx, hasNext = qLen>0
  否则 nextIdx=curIdx+1；越界时 mode 1/3 回绕到 0，mode 0 = hasNext:false
remain = max(0, qLen-1-curIdx)
  hasNext  → 「下一首: <basename> · 剩 <remain> 首」（remain==0 时不带后缀）
  else     → 「队列末尾 · 共 <qLen> 首」
```
注意：**暂停不隐藏**。web 的判据是 `!S.playing`（`playing` 是会话态，暂停时仍为 true），
所以暂停时「下一首」仍显示。

> **差异来源（已裁决，勿当未完成项）**：Lead 任务书里写的「停止/暂停隐藏」是**措辞错误**；
> 用户既定要求是「与 web 一一对应」。Lead 已确认**保持 web 行为**（暂停不隐藏），
> 依据 `ui_script.h updateNextTrackInfo()` 的 `if (!S.playing || !qLen)`。
> 因此本项不算未修，也不再改成 `!playing || paused`。

## 原生 1.1.7.44 及以前
`refreshQueueContext` 只在「有下一首」时写一次文案：**全角冒号**「下一首：X · 剩 N 首」，
没有「队列末尾」分支、不识别单曲循环、`metaLabel` 从不清空/隐藏 ⟹ 停止后仍挂上一首的「下一首：…」，
队列末尾时显示的是更早的陈旧文本。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 6 条）
用真实 `refreshQueueContext` + 队列 fixture：
1. 有下一首：文案逐字 `下一首: c.flac · 剩 1 首`（半角冒号 + 空格），且 `hidden==NO`；
2. 队列末尾（index=2）：`队列末尾 · 共 3 首`；
3. 单曲循环（mode=2）：下一首 = 当前曲 `下一首: cur.flac · 剩 1 首`；
4. 停止（playing=0）：`hidden==YES` 且文案清空（web `!S.playing`）；
5. 换歌：旧文案立即清空（`hidden==YES`），不等新队列返回。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.44） | **5 FAIL**（全角冒号、无末尾分支、不识别单曲循环、停止不清空/不隐藏、换歌后仍可见） |
| 新码 | **82 passed / 0 failures**（75 既有 + 6 新，另有 1 条前提检查） |

证据：`evidence/native-nexttrack-red-20261114.log` / `-green-…log`。
（红色记录使用**最终测试版本**：先临时还原 HEAD 的原生文件跑红、再恢复实现跑绿。）

## 实现
- `applyQueueSnapshot:`：逐条移植 web 规则（含 `mode==2`、越界回绕、`remain`、半角 `: ` 与 ` · `）；
  文案通过 `RLPTr` 三种格式串（`下一首: %@ · 剩 %ld 首` / `下一首: %@` / `队列末尾 · 共 %ld 首`），
  新词条已进 `docs/i18n/chunk-native117.en.tsv` 并重生成两张表（2419 pairs）。
- `refreshQueueContext`：队列响应改走快照函数；响应为空（nil）也走同一条清理路径（不再"什么都不做"）。
- `refresh` 的切曲分支：`metaLabel` 清空 + `hidden=YES` + `nextTrackVisible=NO`（换歌立刻清旧文案）。
- 布局：`#npNextTrackHero` 可见时 `.npmline` 下移 22pt（web 多一行：margin-top 4 + 12px 行 + margin-top 10）。
- 默认隐藏（web `display:none`）；队列条目兼容字符串与 `{path|file}` 字典两种形状。

## 如实挂账
1. **暂停行为与 Lead 任务书不一致**：按 web，暂停时仍显示下一首（见上）；未擅自改成隐藏。
2. tooltip（web `title` 是「下一首：X（队列共 N 首，剩余 N 首）」）原生暂时与正文一致，未逐字复刻。
3. 队列实时性：原生只在切歌/激活时拉 `/api/queue?meta=1`（与之前一致），
   队列内「加歌/删歌」不会即时改下一首文案（web 也是 loadQ 时才刷新；本轮未加轮询）。
