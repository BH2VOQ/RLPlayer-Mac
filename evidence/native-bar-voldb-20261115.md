# v3.3.11 底栏精确 dB 输入 `barVolInput` + 数字校验修复（1.1.7.73）

> 待移植清单「音量」组：底栏精确输入 + 由此暴露的一处**两处共有真缺陷**。

## 1. 上游真值（`ui_page.h:1503`）

```
<label class=rlVolumeValue><input id=barVolInput type=number min=-120 max=20 step=0.1 value=0 disabled><span>dB</span></label>
<output class=rlSrOnly for=vol id=barVolDb hidden></output>
```

JS 侧（`ui_script.h:6365`）：写入时 `e.value = db.toFixed(1)`；未锁定时才覆盖（聚焦中不打断输入）。

## 2. 实现

| 项 | 做法 |
|---|---|
| 控件 | `volDbField`（identifier **`barVolInput`**），位于底栏右侧簇、旋钮之后（与 web 顺序一致） |
| 提交 | Enter（`action` → `onCommitPreciseVolume:`），校验通过后 `commitVolumeDb:` 下发 `/api/volume?db=` |
| 非法值 | 标红边框 + 回填旋钮当前值，**不下发**（web `aria-invalid` 同语义） |
| 状态回填 | `fetchStatus` 写 `db.toFixed(1)`；仅当输入框非第一响应者时覆盖（不打断用户输入） |
| 布局 | 右侧簇加宽 52pt ⟹ 626pt 最小宽度下单行放不下，改为**两行簇**（`overflowRight` 触发 wrap）；簇起点下界由「中栏右缘」改为「五键组右缘 + gap」，允许向右延伸区域向左借用 |

## 3. 判据抓出的真缺陷（数字校验）

新增判据「非数字不下发」第一次跑就 **FAIL**，原因：

```objc
const double db0 = text.doubleValue;   // "abc" → 0.0
const BOOL valid = text.length > 0 && isfinite(db0) && db0 >= -120 && db0 <= 20;
```

`doubleValue` 对非数字文本返回 **0**，而 0 dB 恰是**合法值** —— 于是 `abc` 被当成 0 dB 下发。
这条判据一并修了**两处**：底栏 `barVolInput` 与播放页 `npVolInput`（同一份隐患）。

修法：`NSScanner` 扫描并**要求消费到字符串末尾**（`scan.isAtEnd`），非完整数字一律判非法。

## 4. 红 → 绿

| 判据 | 接线前 | 修复后 |
|---|---|---|
| 控件存在 + target/action | **FAIL**（不存在） | PASS |
| 合法值 `-12.5` Enter 后下发 | **FAIL** | PASS |
| 越界 `999` 不下发 + 标红 | **FAIL** | PASS |
| 非数字 `abc` 不下发 | **FAIL**（当时被当 0 dB 下发） | PASS |
| 上下限 `+20` / `-120` 合法下发 | **FAIL** | PASS |

接线过程中另有两处被既有判据抓到（都是真缺陷，不是调阈值）：
1. 「左右两端留白差 ≤2pt」——右侧簇变宽后起点被中栏右缘卡住，右端超出 12pt ⟹ 改簇起点下界为五键右缘；
2. 「626pt 条内所有控件在界内」——单行放不下 ⟹ 加 `overflowRight` 触发两行布局。

最终：`native_bar_web: 358 checks, 0 failures`；`np web: 0 failures`（播放页同名校验同步修好）。

## 5. 如实挂账

1. **`barVolDb`（sr-only 输出）未做**：上游是给辅助技术用的 `<output>`；原生未接 NSAccessibility，故无处可放。
2. **`volumePending`（音量尚未读取）未做**：属播放设置闸门组，已判定为架构 N/A。
3. 底栏静音键 `volFloor` 仍未做（旋钮中心；播放页 `npVolFloor` 已有）。
4. 输入框宽度固定 46pt（web 由 `type=number` 自动宽度）；字体 10pt 以适配 66pt 高底栏。