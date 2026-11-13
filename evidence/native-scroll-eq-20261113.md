# 第 6/7 项：单层滚动 + EQ 曲线拖动（真实响应链）

日期 2026-11-13。基线 d717ef0（1.1.7.17）。

## 根因结论（两项都已在上轮 680d395 修过，本轮补的是**判据**）

第 6 项与第 7 项在**代码层面**上一轮已经处理过：
- `RLPEqualizerView setEmbeddedInPage:` 会拆掉内层 `NSScrollView`，把 stack 直接铺在外层页面上；
- `RLPEQCurveView` 的 `mouseDown/mouseDragged` 已绑到 `onDragBand` 并节流下发 `/api/peq`。

所以本轮真正的产出不是"再改一遍实现"，而是**把判据换成真的会红的那种**。

### 上一轮的判据为什么是假绿

| 项 | 上一轮的判据 | 它证明了什么 | 它证明不了什么 |
|---|---|---|---|
| 6 | `scrollersInsideEQ == 0`（数 `hasVerticalScroller/hasHorizontalScroller`） | 没有人**打开**滚动条 | 内容超高但没开滚动条时仍可被滚轮滚动（`hasVerticalScroller=NO` 不等于不可滚） |
| 7 | 直接调 `applyDragEvent:` | 给定一个事件时，频率/增益换算是对的 | 真实鼠标事件能不能**走到**这个视图（遮挡、hitTest、响应链、滚动容器截胡，一条都抓不到） |

这两条正是"测试通过 ≠ 测对了东西"的典型：它们都在测**内部函数**，不在测**用户的操作**。

### 本轮的判据（`tests/test_native_scroll_eq.mm`，ctest `native_scroll_eq`）

全部走 hitTest + 真实事件对象，不使用"只看属性"的断言：

1. **内层可滚动 scroll view 数量 == 0**：判定"可滚动"= `hasVerticalScroller || hasHorizontalScroller || 内容确实超出可视区`（三选一），不再是只看滚动条开关。
2. **响应链可达性**：从 20 段参数表上真实的鼠标点出发，沿 `nextResponder` 必须能走到外层页面 `NSScrollView`；链上不得出现第二个**可滚动**的 `NSScrollView`。
   —— 这就是用户说的"滚动被拐到 20 段参数的滚动机制上"的判据面：被拐走 = 走不到 / 中间有拦截者。
3. **EQ 拖动走真实响应链**：`hitTest` 命中曲线 → `mouseDown/mouseDragged/mouseUp` → 断言 `/api/peq` **真的被下发**，且解码后的 body 里**至少一段增益 ≠ 0**（防止"发了请求但参数没变"这种最容易骗过判据的形态）。

### 平台限制与其处理（如实写清）

- `-[NSWindow sendEvent:]` 在窗口**没有上屏**时什么也不投递（实测 `/tmp/probe_send`：未上屏 hits=0，`makeKeyAndOrderFront` 后 hits=1）。让测试弹真窗口会打扰用户，因此改用 `hitTest` + 对命中视图直接发事件——这正是 AppKit 在 `sendEvent` 内部做的两步。
- `NSScrollView scrollWheel:` 的滚动是**窗口动画**，离屏窗口里 `scrollWheel:` 之后 `clipView.bounds` 不动（实测 `/tmp/probe_scroll2`；`scrollToPoint:` 立刻动）。因此在离屏环境里断言"滚了 N 像素"只能得到假红，**不是产品缺陷**。判据相应改为「链路可达性 + 内层不可滚动」，像素位移由这两条共同蕴含。

## 先红后绿（本轮证据）

由于实现已在 680d395 修过，直接拿旧提交跑会全绿（我已跑过 `e0ec65f`：该项的新测试**连编译都过不了** —— `setEmbeddedInPage:` 与曲线拖动在当时根本不存在）。
为了让判据的"会红"这件事**可复核**，采用**受控降级**：在修复后的代码上，分别把上一轮的实现退回去，确认判据变红。

| 降级 | 判据表现 |
|---|---|
| 保留 EQ 内层 NSScrollView（不退化成扁平布局） | `[FAIL] EQ 页内没有任何可滚动的内层 scroll view — NSScrollView(v=1 h=0 overV=1 overH=0)`<br>`[FAIL] 这条链上没有第二个可滚动的 scroll view — NSScrollView(v=1 h=0 overV=1)`<br>合计 9 passed / 2 failed |
| 不绑定 `curve.onDragBand`（曲线只读） | `[FAIL] 真实鼠标拖动曲线后 /api/peq 真的被下发 — posts=`<br>`[FAIL] 下发体里至少一段增益真的变了`<br>合计 9 passed / 2 failed |
| 恢复实现 | **11 passed / 0 failed** |

两条降级都**精确命中**用户描述的两种现象（滚动被拐走、曲线拖不动），且各自只让对应的判据变红 —— 说明判据不是恒真，也不是互相串扰。

## 过程中修掉的三个**判据自身**的 bug（这些比改动本身更值得记）

1. `image.name` 判暂停图标：SF Symbol 的 name 可能是 nil ⟹ 判据恒红。改为位图指纹（见第 2 项）。
2. 未翻转的 `NSView` 文档视图把子视图排到可视区外，`hitTest` 直接返回 nil。改为翻转文档视图。
3. `/api/peq` 的 body 是 urlencoded，增益分隔符是 `%2C`；没解码就按 `,` 切 ⟹ 永远解析不出增益，判据假红。改为先 `stringByRemovingPercentEncoding`。

## 证据文件
- `evidence/native-scroll-eq-green-20261113.log`（11/11 全绿）
- 降级红证据：本文件上表（复现方式：把 `setEmbeddedInPage:` 里拆滚动那几行 return 掉 / 把 `onDragBand` 赋值注释掉）
