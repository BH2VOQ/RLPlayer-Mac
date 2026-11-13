# 第 13 项：底栏三枚徽章文字双向居中

日期 2026-11-13。

## 根因（两层，都量过）

**① 垂直方向：`NSTextField` 在固定高胶囊里把单行文字排在顶部。**
不是"居中没设"——`alignment` 根本不管垂直方向。实测旧实现：

| 徽章 | 框高 | 文字墨迹 上留白 | 下留白 |
|---|---|---|---|
| `gpuBadge`（"GPU"） | 20 pt | **0.5 pt** | **9.0 pt** |

**② 水平方向：`gpuBadge` 根本没设 `alignment`。**
它的 `alignment` 是 `NSTextAlignmentNatural`（=4），在英文标签上等价于左对齐。
实测 左留白 **0.5 pt**、右留白 **10.0 pt**。另外两枚设了 `Center`，所以只有这一枚偏左。

两条叠在一起，就是用户说的「文字不在徽章的正中心」。

附带发现：`gpuBadge` **没有胶囊底与描边**（web `.badge.g` 有 `background:ok-bg` +
`border:ok-line`），截图上是裸文字 —— 用户要求"三枚徽章统一成同一构件"，所以一并补上。

## 修法

新增 `RLPBadgeLabel`（`NSTextField` 子类），自绘时按 attributed string 的实测尺寸算中心落笔：
- 水平 `round((bounds.w − text.w)/2)`，垂直 `round((bounds.h − text.h)/2)`；
- 保留 layer 负责胶囊圆角/底/描边，这个类只接管"字画在哪"。

三枚徽章（`bpBadge` / `fmtBadge` / `gpuBadge`）统一由 `badgeLabelWithFont:color:` 构造，
`gpuBadge` 补上 `cornerRadius=5 / borderWidth=1 / borderColor=okLine / backgroundColor=okBg`。

## 判据（墨迹实测，不看属性）

`tests/test_native_bar_web.mm`：把每枚徽章渲染成位图，跳过 1px 边框与抗锯齿后，
按「与边缘底色差异 > 0.25」求文字墨迹包围盒，换算成 pt 断言
**|左−右| ≤ 1pt 且 |上−下| ≤ 1pt**；另断言三枚高度一致（±1pt）。

| 徽章 | 修复前（实测） | 修复后（实测） |
|---|---|---|
| `fmtBadge` "96k/16" | —（旧判据采样自身有 bug，见下） | L8.0 R8.0 T4.0 B3.5 → **|Δx|=0.0 |Δy|=0.5** |
| `gpuBadge` "GPU" | L0.5 R10.0 T0.5 B9.0 → **|Δx|=9.5 |Δy|=8.5** | L4.5 R5.0 T4.0 B4.5 → **|Δx|=0.5 |Δy|=0.5** |
| `bpBadge` | 已居中（0/0） | 仍 0/0 |

三枚高度一致：PASS。

## 过程中修掉的三个**判据自身**的 bug（都写进 `native-fake-green-criteria.md`）

1. **背景采样被文字拉偏**：第一版取全框平均当作底色，窄徽章（`fmtBadge`）里文字占比大，
   底色估错 ⟹ "找不到墨迹"假红。改为只取**四条边缘内侧**像素当底色。
2. **`RLPSetBadgeText` 只设 `attributedStringValue`，不回填 `stringValue`**：
   既有的「徽标文案随状态变」判据读的是 `stringValue`，于是它**过去一直在比较空串**
   ——看似通过的假绿。已同步维护 `stringValue`。
3. **过时的期望值**：那条判据把 `bitPerfect="no"` 一律期望成「非 bit-perfect」，
   而实现（与 web 同口径）在 inRate≠outRate 时会细分成「PCM-PCM 升频」。
   判据已改为**按同一批字段推导期望值**，不再钉死字符串。

## 证据
- `evidence/native-badges-centered-after-20261113.png`（修复后三枚徽章的放大截图：文字双向居中、同一胶囊构件）
- `./build-mac/test_native_bar_web` → 290 checks / 0 failures
