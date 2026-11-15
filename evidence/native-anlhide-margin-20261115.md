# 分析面板收起键 `npAnalHide` 的边距（1.1.7.81）

> 与 1.1.7.78/1.1.7.80 同一族缺陷：**CSS 的定位框是 padding box，而原生按外缘算**。

## 1. 上游真值

```css
#npAnal{ position:relative; padding:8px 11px 9px; border:1px solid rgba(255,255,255,.08); }
.anlhide{ position:absolute; top:7px; right:8px; width:22px; height:22px; border-radius:50%; }
```

绝对定位的**包含块是 padding box**（边框以内），所以相对**面板外缘**的实际距离是：

| 边 | 计算 | web 外缘距离 |
|---|---|---|
| 右 | `8`（right）+ `1`（border） | **9** |
| 顶 | `7`（top）+ `1`（border） | **8** |

## 2. 原状

```objc
NSMakeRect(side - 9.0 - 22.0, bodyH - 7.0 - 22.0, 22.0, 22.0)   // 右 9 ✓ / 顶 7 ✗
```

右侧已经把边框算进去了（9），顶部却少算 1pt —— 和 rail 收起键那次一样，**同一个换算在两处用了两套数**。

## 3. 修法

顶部改 `bodyH - 8.0 - 22.0`，注释写明 8 = `top:7` + border 1。

## 4. 判据（`test_native_nowplaying_web`，235 checks / 0 failures）

| 判据 | 期望 | 旧值会怎样 |
|---|---|---|
| 右端距面板外缘 | **9 ± 1** | 旧码本就 9，此判据是**防回归**（不在本次改动里，但同一公式已被证明会漂） |
| 顶端距面板外缘 | **8 ± 1** | 旧码 7 → **失败** |

两条都是按 CSS 语义算出的真值，不是照观测值写回。

## 5. 如实挂账

1. `#npAnal` 的内边距（8/11/9）与 rail 面板的 11/11 不同源，本轮**没有**统一成常量 —— 两栏本就用不同的 padding，
   统一会改布局。
2. 未做真机像素比对（离屏判据只量 frame 距离）。