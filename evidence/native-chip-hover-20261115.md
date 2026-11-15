# `sp_opra_copychip` 悬停态（web `.chip:hover`）（1.1.7.79）

> 收口《已知偏差》台账里「设置页 `.chip` hover 未做」这一条。

## 1. 上游真值

```css
.chip{ font-size:11px; padding:3px 9px; border-radius:12px; background:var(--bg3);
       color:var(--txt2); border:1px solid var(--line); transition:.15s; cursor:pointer }
.chip:hover{ background:var(--hov); color:var(--txt); border-color:var(--acc) }
```

即悬停时**底色换成 `--hov`、文字升到 `--txt`、边框变 `--acc`**。

## 2. 原生现状（补之前）

`sp_opra_copychip` 是系统圆角 `NSButton`（`bezelStyle = Rounded`，字体 11.5，带 `doc.on.doc` 图标），
点击复制官网链接 —— 功能与判据（C1–C5）都在，**唯一缺的是悬停态**：鼠标移上去外观完全不变。

## 3. 实现（只补悬停，不改形状）

新增文件内子类 `RLPChipHoverButton : NSButton`：

| 点 | 做法 |
|---|---|
| 触发 | `NSTrackingArea`（`MouseEnteredAndExited`、`ActiveInKeyWindow`、`InVisibleRect`），在 `updateTrackingAreas` 里重建 |
| 进入 | 记录原 bezel（`nil` 表示系统默认，用 `NSNull` 哨兵标注）、记录原 `attributedTitle`；然后 `bezelColor = t.hov`，文字改 `t.text` |
| 退出 | bezel 复原（`nil` 就真的恢复 `nil`）、文字复原 |
| 判据入口 | `-setChipHovered:`（真实路径是 tracking area 的两个事件） |

**为什么不做成自绘胶囊**：把系统 bezel 换成自绘 pill 属于**重新设计控件**（形状、内边距、圆角、图标排布全变），
超出「补一处悬停」的范围；台账里记的也正是 hover 这一项。形状差异另可单独立项。

## 4. 判据（`test_native_opra_cards`，25 passed / 0 failed）

| 判据 | 钉住什么 |
|---|---|
| C3b | 控件支持悬停入口（`setChipHovered:` 存在） |
| C3c | 悬停时 bezel 取主题 `hov`（逐分量比对 ≤0.02，与 web `background:var(--hov)` 同口径） |
| C3d | 悬停时文字**显式**带前景色（web `color:var(--txt)`；系统按钮默认不带，必须写死才可验证） |
| C3e | 退出悬停复原成 `nil`（**不留永久着色** —— 这是 hover 实现最容易写错的地方） |

C1–C5（控件存在 / 可点 / 有 target-action / 显示链接 / 点击真写剪贴板）全部保持通过。

## 5. 结果与门禁

- `test_native_opra_cards: 25 passed / 0 failed`
- `np web: 231 checks / 0 failures`（同一文件的其它判据未受影响）
- 全量门禁见提交里的 `evidence/native-79-*.log`。

## 6. 如实挂账

1. **边框色未做**：web 悬停还有 `border-color:var(--acc)`；系统 bezel 无法单独改边框色，故只做了底色与文字两项 —— 
   这是「系统控件可达成范围」内的对齐，不是遗漏。
2. **过渡动画未做**：web 有 `transition:.15s`，原生切换是瞬时的（`NSAnimationContext` 可加，本轮未做）。
3. 只有 `sp_opra_copychip` 一个控件走这个子类；设置页其它 `.chip`（若有）未接入。
4. 未做真机鼠标移入移出验证（离屏判据走的是 `setChipHovered:` 入口，不模拟真实 tracking event）。