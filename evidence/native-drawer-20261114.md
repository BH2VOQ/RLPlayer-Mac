# `#npDrawer` 页内抽屉浮卡（1.1.7.54，表 #39）

## web 值（`src/net/ui_page.h:798-802`）
```
.npdrawerbg{position:absolute;inset:0;z-index:5;background:rgba(0,0,0,.30);
            -webkit-backdrop-filter:blur(2px);...;transition:opacity .22s}
.npdrawer{position:absolute;top:14px;right:14px;bottom:14px;z-index:6;
          width:min(430px,44vw);background:var(--bg2);border:1px solid var(--line2,var(--line));
          border-radius:18px;box-shadow:0 28px 80px rgba(0,0,0,.42);overflow:hidden;
          transform:translateX(calc(100% + 26px));transition:transform .26s,opacity .18s}
.npdrawer.on{transform:none;opacity:1;visibility:visible}
```
点 `#npDrawerBg` = `npDrawerClose()`；Esc 也走同一关闭路径。

## 原生 1.1.7.53
点右栏 chip：`loadKind` 后弹 `NSPopover`（`RLPCardController(knowledge,420,380)`）——**系统浮卡**，
宽度/圆角/阴影/动效都不是 web 的 1:1，且离屏（无窗口）时直接不弹（判据测不到）。

## 判据（`tests/test_native_nowplaying_web.mm` 追加 13 条）
1. 点 chip 后出现 `npDrawer`（页内视图，不是系统弹窗）与 `npDrawerBg`；
2. 打开后两者可见；
3. 抽屉宽 = `min(430, 44vw)`；4. 上/右各 14pt；5. 高 = 页面高 − 28；
6. 圆角 18；7. 1px 描边；
8. 阴影 opacity≈0.42、radius≈40（CSS blur 80 → CALayer 40）、向下 28；
9. 遮罩铺满页面（inset 0）；
10. 打开**不新增 NSScrollView**；
11. 打开**不动底层歌词滚动位置**（contentView bounds origin 不变）；
12. 点遮罩关闭（drawer/bg 都隐藏）；
13. Esc 关闭（`cancelOperation:`）。

## 红 → 绿
| 轮次 | 结果 |
|---|---|
| 旧码（1.1.7.53） | **2 FAIL**（无 npDrawer / npDrawerBg） |
| 新码 | **191 passed / 0 failures**（173 既有 + 13 新 + 前提） |

## 实现
- 新 `RLPOverlayBackdrop`（遮罩，`mouseDown` → 关闭）；创建 `npDrawerBg`/`npDrawer` 加在 `webCanvas`
  **最上层**（`buildContent` 末尾），`knowledge` 放进抽屉并随抽屉尺寸自适应。
- `layoutWebPlayback` 每次按页面尺寸排：`top/right/bottom:14`、`width:min(430,44vw)`；遮罩 `inset 0`。
- `openDataDrawer` / `closeDataDrawer`；`onRailCard` 不再弹 NSPopover；停止/切歌时自动关；
  `cancelOperation:` 处理 Esc。
- 阴影按 CALayer 参数：`shadowOpacity .42`、`shadowRadius 40`、`shadowOffset (0,-28)`；圆角 18、1px 边框。

## 如实挂账
1. web 有 `backdrop-filter:blur(2px)` 与滑入 `transform .26s`；原生遮罩是纯 rgba(.30)（无模糊滤镜），
   抽屉**直接放到终点**（只做 0.18s alpha 淡入），避免离屏判据与动画帧抢跑。
2. `masksToBounds=NO` 才能显示阴影（CSS 的 `overflow:hidden` 不裁 box-shadow）；内容圆角裁切交给 knowledge 自身。
3. 抽屉是页内视图：覆盖在播放页上、点遮罩/ Esc 关闭；`#npDrawer` 不进入滚动链路，不动底层滚动。
