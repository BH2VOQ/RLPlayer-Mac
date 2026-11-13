# 第 9/10/11 项：诊断/反馈区形态重做（先红后绿）

日期 2026-11-13。基线提交 d717ef0（1.1.7.17）。

## 根因（三层，逐层量过）

1. **气泡空白 = 尺寸没协商，不是内容没搬**。
   `RLPCardController`（tools/native_ui/RLPSupport.mm:289）只给 root 钉了
   `width = 660` 与 `height >= minHeight`，**从没设 `NSPopover.preferredContentSize`**；
   而被搬进去的 content stack 用 `alignment = Leading`，其子控件是一个
   `width = 620`（约束在自身）的 NSScrollView + 若干固定宽度控件。
   NSPopover 按 contentViewController 的 fittingSize 定尺寸，一旦子视图是
   translatesAutoresizingMaskIntoConstraints=NO 且没有父宽约束，
   fittingSize 只给出**极小的垂直高度** ⟹ 用户看到一条空白框，
   真实控件全被裁在下方（截图里只在底部露出「附带诊断包 / 发送反馈」正是这个形态）。

2. **旧判据假绿**：上一轮的审计只验证「把同一批控件搬进/搬回内容容器」
   （`auditDiagPopoverContent` / `auditRestoreDiagPopover`），
   **完全没有断言气泡显示出来之后控件是否可见**。所以故障在门禁全绿的情况下上线。

3. **用户要的形态根本不是气泡**：「填写反馈这里我希望做成 web 版的效果，直接给用户填写窗」
   ⟹ 正确修法不是修气泡尺寸，而是**取消 NSPopover**，把表单与诊断按钮内联进设置页。

## 修法

- 诊断区：`导出诊断包（.zip）` 红底主按钮 + `只要 JSON` / `查看 / 复制诊断摘要` 次按钮，
  一行三个、默认可见；下方两行说明（web 原文逐字）；摘要正文点按钮后**就地展开**。
- 反馈区：内联填写窗 —— `问题描述` 标签 + 大文本域（h=150）+ `0 / 16384 字节` 计数
  + 底部行（☑ 附带诊断包 + 红底 `发送反馈` + 重试探活）。默认展开，不需要点任何东西。
- **删除**「随反馈上传诊断」按钮（用户明确要求；文案与 identifier 双重断言防回退）。
- 计数按 **UTF-8 字节**（web `fbBytes` 同口径）：6 个汉字 = 18 字节，不是 6。

## 判据（rendered red → green）

判据放在 `rlplayer_native --audit`（真实视图树遍历 + 祖先链可见性 + 真实 layer 颜色）。

| | 旧实现 d717ef0 | 新实现 |
|---|---|---|
| 红底主按钮可见且为 accent 色 | FAIL（缺按钮 / bg=null） | PASS |
| 三个按钮逐字文案、无需点击即可见 | FAIL ×3 | PASS |
| 「随反馈上传诊断」已删除 | FAIL（byTitle=1 byIdentifier=1） | PASS |
| 反馈文本域内联可见且 h>=100 | FAIL（h=110 但被藏在 hidden 容器里） | PASS |
| 反馈计数内联可见 | FAIL（藏在隐藏容器） | PASS |
| 附带诊断包默认勾选且可见 | FAIL | PASS |
| 发送反馈按钮内联可见 | FAIL | PASS |
| 诊断/反馈不由 NSPopover 承载 | FAIL（legacyEntry=1） | PASS |
| 诊断摘要面板默认收起 + 调用后就地展开 | FAIL（缺 sp_diagscroll） | PASS |
| 合计 | **215 passed / 12 failed** | **230 passed / 0 failed** |

### 一条被自己否掉的判据（说明为什么加强了）
第一版可见性判据写成 `b && !b.hidden && frame 有面积`，结果在**旧实现上照样 PASS**
—— 因为旧代码把控件放在 `hidden=YES` 的容器里，控件自身 `hidden` 是 0。
这正是铁律④的反例。改成 `RLPViewActuallyVisible()`（自身 + **全部祖先** hidden/alpha/frame）
之后，同一批判据在旧实现上从 4 FAIL 变成 12 FAIL，才真正抓住故障。

## 证据文件
- `evidence/native-diag-feedback-red-20261113.log`（旧实现 215/12，exit=12）
- `evidence/native-diag-feedback-green-20261113.log`（新实现 230/0，exit=0）

## 回归过程中顺手修掉的一处判据时序抖动
`新建歌单 toast 带上歌单名` 原来固定 `Pump(0.8)` 后检查，机器忙时会在 `/api/sq/add`
回调之前就断言 ⟹ 偶发假红（本轮第一次 green 跑就红在这一条）。
改成轮询到出现或 3s 超时，判据强度不变（仍要求文案带歌单名），只去掉时序抖动。
