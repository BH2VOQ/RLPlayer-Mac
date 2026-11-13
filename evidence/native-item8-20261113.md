# 第8项 · 耳机目标曲线按 web 方式接入（2026-11-13）

> 判据：`tests/test_native_target_curve.mm`（ctest 名 `native_target_curve`）。
> 桩客户端（不发网络请求、不启动核心、不碰音频设备 —— 铁律②）。

## 四层判定（逐层给结论，不是"修一条就报完成"）

| 层 | 判定 | 证据 |
|---|---|---|
| ① 桥层取数据 | **断**（已修）：`/api/opra/index` 的 `items` 是 `[id,vendor,name]` 数组三元组（`tools/rtaweb.cpp:11285`），旧原生只认 `NSDictionary` ⟹ 搜索结果恒 0 项 | 红：`items=0`；绿：`Sennheiser · HD 600` |
| ② 画到图上 | **断**（已修）：旧原生没有 target curve 图层；现按 web `TARGET_CURVES`（11 条，逐值与 `ui_script.h:10797-10820` 一致）叠加虚线图层 | 红：`changedPixels=0`；绿：像素变化 + 虚线列覆盖率 |
| ③ 字段/参数 | **断**（已修）：`/api/opra/presets` 返回 `id/author/details/link/gainDb/bandsCount`，**没有 name**；旧码读 `name` ⟹ 预设下拉恒空、永远无法应用 | 红：`items=0`；绿：`oratory1990 · Harman Target` |
| ④ 加载时机 | **断**（已修）：web 选中预设即 `showTargetCurveInfo(p)`、应用后 `saveSettings(true)` 写回 eq；旧原生选中后什么都不显示、apply 后也没写 settings ⟹ 后端热重载不触发 | 红：`opra.info` 缺失、settings 无 `eq=`；绿：说明行 + 三个键写回 |

附带修掉的真缺陷（判据第一轮抓到的）：`RLPMutableTargetCurve` 的 readwrite 属性没有 setter
（父类同名属性 readonly，clang 不自动合成）⟹ 运行时 `unrecognized selector` 直接崩溃；
`targetCurve` 属性写成 `copy` 但 `RLPTargetCurve` 没实现 `NSCopying` ⟹ 第二次崩溃。两处都已修。

## 红→绿

| 阶段 | 命令 | 结果 | 证据 |
|---|---|---|---|
| 旧码（红） | `./build-mac/test_native_target_curve` | **4 passed, 10 failed** | `evidence/native-item8-red-20261113.log` |
| 新码（绿） | `./build-mac/test_native_target_curve` | **22 passed, 0 failed** | `evidence/native-item8-green-20261113.log` |

旧码红的 10 条里，最关键的 4 条：
```
[FAIL] 【请求】索引请求 = /api/opra/index（不带 q，web loadOpraIndex 同口径） — noQ=0 withQ=1
[FAIL] 【①桥层】数组三元组被解析成型号项 — items=0
[FAIL] 【③字段】预设列表被填满（后端没有 name 字段）— items=0
[FAIL] 【②绘制】选中目标曲线后 EQ 图上出现新图层（像素变化）— changedPixels=0
```

## 判据细节（证明的是真东西）

1. **①/③ 桥层**：桩返回真实形态的数组三元组与无 name 预设 ⟹ 型号下拉 1 项、预设下拉 2 项，
   显示名逐字符断言为 `author · details`。
2. **② 像素采样**：曲线视图离屏渲染三张图（无目标曲线 / Preset A / Preset B），
   在 plot 区域内逐像素比较（跳过网格/坐标轴外区域）：
   - 出现目标曲线 ⟹ 变化像素 > 40、虚线**列覆盖率 20%~85%**（虚线 4/3 模式 ⟹ 与实线 PEQ 可区分）；
   - 切换曲线 ⟹ 两张图之间变化像素 > 20 且**重心位移 > 1px**（不是同一形状重画）。
3. **③ 请求逐字段**：桩记录真实发出的字符串，逐字符断言
   `presets?productId=sennheiser%3A%3Ahd_600`、
   `productId=sennheiser%3A%3Ahd_600&presetId=sennheiser%3Ahd_600%3A%3Aautoeq_harman_iem`、
   settings `eq=eq%2Fopra-hd600.txt&opraproduct=…&oprapreset=…`。
   web 侧源码对照见 `evidence/native-item8-web-diff-20261113.txt`。
4. **④ 时机**：选中后 `opra.info` 出现「哈曼头戴目标曲线」「前级增益：」；切到 In-Ear 后文案同步变化。

## 如实挂账

- 实测（离线）：22 项全绿 + 红/绿两次日志 + web diff 表。
- **结构差异（不是功能缺失）**：web 的预设是卡片墙（每卡一张 `.tc-curve` 小图），原生 OPRA 是
  两个下拉框；因此原生把目标曲线画在**主 EQ 图**上、说明文字放在 `opra.info` 行。
  11 条曲线数据与 10 条说明文案是全量移植，没有删，只是呈现位置不同。
- **未实机**：真实后端返回的 OPRA 索引（约数千条）下的搜索延迟、以及曲线叠加与 PEQ 的实际观感
  需要实机看一眼；本项判据用的是桩数据，不依赖网络。
- 曲线叠加采用 web `.tc-curve` 的纵轴常数（MAXDB=9/MINDB=-2 映射到绘图区高度）——即"示意图形"，
  不是把 dB 精确画在 EQ 的 ±18dB 轴上；这是沿用了上一轮半成品的设计选择，报告里如实说明。
