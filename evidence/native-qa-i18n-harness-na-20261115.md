# v3.3.11「QA 引导」与「i18n 上报」—— 本仓架构下不适用（N/A）

> 两个清单项一并判定。结论都是**不移植**，理由同为「它们是 Web 前端的自动化验收设施，
> 不是用户功能」；本仓有等价物，且是更硬的门禁。

## 1.「QA 引导」= 多语言验收驱动，不是新手引导

上游代码自带说明（`ui_script.h:268-271`）：

> 「多语言验收驱动（仅 RLPLAYER_QA=1 时由 tick 启动）—— 页面自己动：展开音频分析的所有折叠块、
> 打开 AI 抽屉、按步滚动，然后把两个面板的 innerText 回报给后端（写 qa_text.log）。
> 外部脚本按 step 推进并逐屏截图。」

| 事实 | 证据 |
|---|---|
| 只在 `/api/status` 返回 `qa` 标志时启动（`j.qa && !QA.on`） | `ui_script.h:4372` |
| 轮询 `/api/qa/next` 拿「第 N 步要执行的 DOM 指令」 | `ui_script.h:512-521` |
| 指令全是 DOM 动作：`scroll:#npDataBody`、`top:`、展开折叠块、清浮层 | `qaExec` |
| 回传 `qaPanelsText()` —— 抓 `document.querySelector` 的 innerText | `ui_script.h:279+` |
| 结束后 `POST /api/qa/done` | 同上 |

**这不是产品里的「引导」**，是给自动化截图脚本用的驱动端。AppKit 没有 DOM，
`document.querySelector` 一类指令在原生里没有对应物。

**本仓等价物（更硬）**：
- `rlplayer_native --audit` → **246 项**像素级/契约级判据（每次门禁都跑）
- `ctest` 202 项，其中 30+ 项是原生 UI 行为判据（`native_*` 系列）
- 两者都不需要「生产期 qa 开关」通道，也不会在生产里被误触发

## 2.「i18n 上报」= Web DOM 运行时扫描缺译

| 事实 | 证据 |
|---|---|
| 扫 `NodeWalker` 文本节点与 `title/placeholder/aria-label/alt/data-tip` 属性 | `ui_script.h:4336-4345` |
| 只挑「含 CJK 且不在 `I18N.map` 里」的串 | 同上 |
| 聚合后 `POST /api/i18n/miss`（最多 400 条） | `ui_script.h:4351` |
| 本仓后端**没有**该端点 | `grep -c 'i18n/miss' tools/rtaweb.cpp` → 0 |

**为什么原生不需要**：Web 版是「用渲染结果当键」的运行时翻译，只有跑到那一刻才知道哪句没译；
原生版每条文案都是**编译期可见的** `RLPTr(@"…")` 字面量，可以在构建时穷举校验。

**本仓等价物（更硬，已全绿）**：

```
i18n_table_check          Web 词表生成一致性
native_i18n_table_check   原生词表生成一致性
native_i18n_coverage      每条 RLPTr 中文字面量都必须有英文译文
```

当前 `native_i18n_coverage`：`RLPTr 中文字面量 1672 处，去重未进词表 0 条`。
运行时上报是「出了事才知道」，编译期门禁是「进不来」——后者更强，不需要再引一条遥测通道。

## 3. 如实挂账

1. 两项均**不新增任何代码**，故无版本号变更、无 i18n 词条、无判据变更。
2. 上游这两条设施对**Web 版**仍有价值；本仓 Web 前端（`src/net/ui_script.h` 本地分支）
   是否要补属于另一条工作线，不在原生移植范围内。
3. 未做的事说清：原生侧**没有**「运行期发现错译/漏译就回传服务器」的通道。
   若将来确有需要，正确做法是扩 `check_native_i18n_coverage.py` 的覆盖面（编译期），
   而不是再造一条网络遥测。

## 4. 复核方式

```bash
grep -n 'RLPLAYER_QA' /tmp/rlp2-v3311/ui_script.h        # 268 行自带说明
grep -n 'api/qa'     /tmp/rlp2-v3311/ui_script.h        # 512 / 519 / 520
grep -c 'i18n/miss'  tools/rtaweb.cpp                   # 0
grep -c 'api/qa'     tools/rtaweb.cpp                   # 0
python3 tools/check_native_i18n_coverage.py             # OK: 全部有英文译文
```
