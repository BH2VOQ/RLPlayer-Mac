# 设置页卡片粒度 + cal 页真控件（1.1.7.39）

## 1. 这条包在补什么（web 逐行比对结论）

对照 web `src/net/ui_script.h`：

- `eqSettingsHtml()` = **两张** `sgroup`（卡片）：
  1. 「参数均衡 PEQ（20 段 · HIFI）」：PEQ 旁路 / 前级 / 20 段参数表 / 目标曲线
  2. 「耳机 EQ（OPRA 校准预设）」：OPRA 型号搜索 / 型号卡片墙 / 预设卡片墙 / 目标曲线说明
- `calSettingsHtml()` = **三张** `sgroup`：
  1. 「房间校正（测量向导）」
  2. 「EQ 文件（REW / AutoEq 文本）」 ← web `#sp_eq` 路径输入
  3. 「房间校正 IR（WAV 脉冲响应）」 ← web `#sp_ir` 路径输入 + `#sp_irgpu` GPU 卷积开关

而原生 1.1.7.38 之前：EQ 页 = 1 张卡（整块均衡器子界面），cal 页 = 1 张卡；
更严重的是 `sp_eq / sp_ir / sp_irgpu` 在 `RLPSettingsViewController.mm` 里**只有 identifier
映射表里的字符串，屏幕上没有任何控件**——`parity_scan.py` 只认源码字面量，于是把它们记成 done
（missing=0 是假绿，属于"测试通过≠测对了东西"的典型）。

## 2. 判据（`tests/test_native_settings_granularity.mm`，新 ctest `native_settings_granularity`）

23 条断言，分四类：

- **结构**：EQ 页 = 2 张 `RLPSettingsGroup`，标题逐字 `参数均衡 PEQ…` / `耳机 EQ…`，顺序正确；
  cal 页 = 3 张卡，标题逐字 `房间校正…` / `EQ 文件…` / `房间校正 IR…`。
- **控件归属**：`peqBypass / peqPreamp / peq.bands / eq.curve` 必须是第 1 张卡的后代；
  `opra.query / opra.search` 必须是第 2 张卡的后代（不是"页面上存在"就算对齐）。
- **真控件**：`sp_eq` 是 `NSTextField` 且宽 > 20pt；`sp_ir` 存在；`sp_irgpu` 是 `NSSwitch`
  （不是只有 identifier 的占位视图）；三者必须落在对应卡片体内。
- **行为**（不是只改 UI）：把 `sp_eq` 的值改成 `/tmp/gran-eq.txt` 并触发 action ⟹
  真打 `GET /api/settings` 读回 `kv.eq` 等于该值；`sp_irgpu` 打开 ⟹ `kv.irgpu == "1"`。
- **单层滚动**：EQ/cal 页签内不得再有第二条可见滚动条（旧 cal 视图自带
  `hasVerticalScroller=YES` 的内层 NSScrollView，会把整页变成双滚动条）。

纪律：隔离 `RLPLAYER_STATE_DIR / RLPLAYER_LIBRARY_DIR`，`backend=null`、`volume=-120`，不播放、不联网。

## 3. 红 → 绿（旧码 `524ae0e` = 1.1.7.38）

| 轮次 | 二进制 | 结果 | 证据 |
|---|---|---|---|
| 旧码（不改任何东西） | 1.1.7.38 build Nov 14 14:19:55 | **6 passed, 15 failed**（2 条行为判据因控件缺失被跳过） | `evidence/native-settings-granularity-red-20261114.log` |
| 新码 | 1.1.7.39 | **23 passed, 0 failed** | `evidence/native-settings-granularity-green-20261114.log` |

旧码失败项（逐条）：EQ 页只有 1 张卡、标题不对；`opra.query/opra.search` 归卡错误；
cal 页只有 1 张卡、标题不对；`sp_eq` 不存在（3 条）、`sp_ir` 不存在、`sp_irgpu` 不存在且不是开关、
`sp_ir/sp_irgpu` 归卡错误；cal 页签内有第二条滚动条。

> 如实挂账（判据自身的修正）：「页签内单层滚动」这条最初把**页签根**（它本身就是整页滚动容器）
> 和 EQ 20 段表的固定高度 `NSTableView` 包装也算成"嵌套滚动"，于是 EQ 半条在旧码上也红。
> 这是判据定义过宽（假红）。已改成「只数 `hasVerticalScroller/hasHorizontalScroller` 为真的嵌套
> 滚动容器，且排除页签根」；EQ 半条因此在新旧码都不触发（它本来就没有第二条滚动条），
> cal 半条是真差异（旧 cal 视图自带 `hasVerticalScroller=YES`）。两件都写在测试注释里。

## 4. 实现要点（不复制第二套控件）

- `RLPEqualizerView` 新增 `opraSection` 容器：OPRA 段整段是**同一个视图子树**，
  设置页用 `[opraGroup addFullRow:eqView.opraSectionView]` 整段搬进第二张卡（AppKit 重挂父视图），
  控件/数据/请求都不复制。
- `RLPCalibrationView` 新增 `irSection` 容器 + `setEmbeddedInPage:`（拆掉自己的 NSScrollView，
  由整页滚动）+ `preferredContentHeight`；`sp_ir` / `sp_irgpu` 是这里已有的真控件，
  本轮补上 web 的 identifier 与"回车即保存"语义。
- `sp_eq` 是新加的真 `NSTextField`（`onEqPath:` → `POST /api/settings` 的 `eq=`），
  读回时由 `/api/settings` 的 `kv.eq` 回填。
- 修复一处实测崩溃：`buildOpraSection` 里「`opraInfo` 宽 = `opraSection` 宽」的约束
  在 `opraInfo` 还没进 hierarchy 时就 `setActive` ⟹ AppKit 抛
  `NSGenericException: no common ancestor`（离屏测试第一次跑直接 abort）。
  已改成先 `addArrangedSubview` 再激活约束。

## 5. 门禁（1.1.7.39）

见 `evidence/native-progress.md` 的 1.1.7.39 条目（build / ctest / audit / parity / behavior / i18n）。

## 6. 仍未对齐（如实）

1. `sp_ir` 的 web 语义是「与 `sp_irgpu` 同卡、保存走 `ir` 字段」；原生 `sp_ir` 的 action 走
   `/api/settings` 的 `ir`（同 web），但**判据只覆盖了 `eq` 与 `irgpu`**，`ir` 写回没有单独断言。
2. EQ 页第二张卡里 OPRA 段的内部仍是原生命名（`OPRA 耳机目标曲线` 等）排版，不是 web 的
   `.npchip` 卡片墙逐像素复刻（1.1.7.35 已做过卡片墙，本轮只动卡片归属）。
3. 声道音量微调仍是 `NSSlider`（web 是 number 输入）；本轮未动，上一轮已记在
   `evidence/native-3-settings-cards-20261114.md` §5。
