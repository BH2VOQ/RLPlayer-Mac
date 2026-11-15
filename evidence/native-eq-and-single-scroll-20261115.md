# EQ 页调试 + 全程序单层滚动（1.1.7.87）

用户 2026-11-15 本轮两条要求（原话）：

1. 「目前首要目标是对设置页中的 **eq 页面进行 debug**」
2. 「我希望整个程序，**每一个页面只能有主体可以进行滚动，不要大框架套小框架**」

---

## 一、EQ 页：真正的根因不是样式，是**接口契约整条对不上**

上一轮（1.1.7.86）已经做过一轮"修复"：抽出 `RLPEQGeometry` 纯函数、加 13 条几何单测、
给曲线加频段分隔线与 20 个手柄、把 20 段表从 `NSScrollView` 里搬进 stack。
**门禁全绿，但用户看到的三个现象一个没变。**

原因是那一轮的判据与产品**共用同一套错误假设**，所以一起错、一起绿。

### 三条错在哪（对照真后端实测）

后端契约在 `src/dsp/peq.h:39` 与 `tools/rtaweb.cpp:5639/5676`：

```
GET  /api/peq  bands[] 字段 = {"i","on","type","freq","gain","q"}   ← freq/gain
     type 取值 = "PK" | "LS" | "HS"
POST /api/peq  bands=<序号>,<类型码>,<频率>,<增益>,<Q>[,off];…       ← 序号在最前
```

| 位置 | 原生旧实现 | 后端实际 |
|---|---|---|
| `absorbState:` 读 JSON | `x[@"f"]` / `x[@"g"]` | `freq` / `gain` |
| type 取值 | `peak`/`lowshelf`/`highshelf` | `PK`/`LS`/`HS` |
| `bandsParam` 提交 | `频率,增益,Q,类型` | `序号,类型码,频率,增益,Q` |

对隔离实例（19152）实测：

```
POST bands=20.0000,0.0000,1.4100,peak;…   → {"ok":false,"error":"bands 参数格式不对（…）"}
POST bands=1,PK,20.0,3.0,1.41;…           → {"ok":true,…}
```

### 连锁后果（与用户三个现象逐条对应）

1. `x[@"f"]` 取到 nil ⟹ `[nil doubleValue]` = 0 ⟹ **20 段频率全变 0**
   （离屏截图里参数表整列 `0.0`，实测确认）。
2. `gain` 同理 ⟹ 曲线永远平直、非零段恒 0/20。
3. `bandFreqs` 全 0 ⟹ `RLPEQPlotFractionForFrequency(0)` 夹到 0.0 ⟹
   **20 个手柄全叠在绘图区最左端**（= 用户说的"没有分 band"）；
   `RLPEQNearestBandIndex` 也永远只命中第 0 段（= "拖了没反应"）。
4. `bandsParam` 字段顺序/类型码全错 ⟹ 每次提交都被后端拒绝 ⟹ **一次都没有真正生效过**。

### 像素级核对（不是看截图顺眼）

对 `20-settings-eq.png` 的 0 dB 红线做逐像素扫描（`/tmp/eqprobe.py` 解析 BMP）：
红色连续段 **1393px、零断口**。手柄是 `bg2` 填充的圆点，画出来必然把红线挖出缺口 ——
零缺口即证明"绘图区里一个手柄都没画"，而不是"手柄画得太淡看不出来"。

### 修复（`tools/native_ui/RLPEqualizerView.mm`）

- 新增 `RLPEQTypeCodeNormalized/FromTitle/TitleForCode`：类型码统一收敛到 `PK/LS/HS`，
  下拉**显示**用 web 同款文案（峰值 PK / 低架 LS / 高架 HS），**值**用后端码。
- `absorbState:` 改读 `freq/gain`（保留 `f/g` 作兼容回退），并吸收 `on` 启停位。
- `bandsParam` 改成后端契约的 `序号,类型码,频率,增益,Q[,off]`。
- **手柄高亮不再闪没**：`absorbState` 每次回填都会跑，而拖动提交是 260ms 节流 ⟹
  旧码在这里把 `activeBand` 复位成 -1，等于"每拖一下就立刻抹掉高亮"。
  现在只做越界收敛，保留用户最后触碰的段；`mouseUp` 也不再清它。
- 补回 web 有而原生**根本没有**的两个动作（铁律①）：
  `peqAutoPre`「自动前级（防削波）」（口径与 web 一致：points 已含旧前级，先扣再加）
  与 `peqReset`「重置 Flat」。

---

## 二、全程序单层滚动

### 怎么证明（新判据 `tests/test_native_single_scroll.mm`）

遍历左导航全部 10 个 key + 设置页全部 10 个页签，对每个页面回答两个问题：

- **顶层能滚的容器 ≤ 1**（>1 就是滚轮有歧义）；
- **没有任何"能滚的容器套着另一个能滚的容器"**（按祖先链判定）。

"能滚"的定义是本判据的核心，**不能退化成"有没有滚动条"**：
`hasVerticalScroller`、内容溢出可视区、内容高度约束超过容器 —— 三者任一即算。
旧 EQ 的 20 段表就是"不显示滚动条但照样吃滚轮"的第一类漏网，正是上一轮判据假绿的形态。

### 判据自身踩过的三个坑（都修了，记录在此避免重犯）

1. **第一版把"页面唯一那根"当成内层**（页面根不是 NSScrollView，排除条件永不成立）
   ⟹ 10 个页面全假红。必须用**祖先链**判嵌套，不能用"是不是页面根"。
2. **用 frame 面积判可见**⟹ 离屏未布局时把真能滚的容器误判成不可见
   （albums/streaming/favorites 三页假红）。改为只判 hidden 链。
3. **断言"恰好一根"** ⟹ 空态页（书库为空的专辑 / 未配置服务器的流媒体）会把主体滚动条
   整根隐藏只留空态卡，那是正常空态。实测确认 `hidden=1` 后改为"至多一根"。

### 唯一实测抓到的真缺陷

`【settings.in】NSScrollView 套在 tab.in 里` —— 设置·输入页的「采集实时状态」
由 `RLPInputView` 自带一根 `NSScrollView`，套在页签的整页滚动条里 = 大框架套小框架。

修法照 `RLPEqualizerView` / `RLPCalibrationView` 已有模式：给 `RLPInputView` 加
`setEmbeddedInPage:` + `preferredContentHeight`，设置页嵌入时拆掉内层滚动、
由宿主给高度约束（`RLPSettingsViewController.mm` 的 `fillInput`）。

---

## 三、判据

| 测试 | 条数 | 证明什么 |
|---|---|---|
| `native_eq_contract`（新增） | 17 | 真 embedded 核心 / 真数据 / 真拖动：字段名、频点真实且互不相同、手柄铺满、拖动命中第 11 段、**核心状态里恰好那一段 gain 变了**、提交被接受、类型码是 PK |
| `native_single_scroll`（新增） | 40 | 20 个"页面 × 检查"：顶层 ≤1 + 无嵌套 |
| `native_scroll_eq`（改） | 12 | 原来按**错的格式**解析下发体，现改为按后端契约断言序号/类型码/字段位（能抓住格式错误）+ 增益确实变了 |
| `native_eq_geometry` | 13 | 坐标映射纯函数（沿用） |
| `--audit` 分 band 判据（改） | 1 | 原来只数 `count == 20`（20 个 0.0 也满足 ⟹ 假绿），现改为"20 个**互不相同**且覆盖 20Hz~20kHz" |

红→绿实测：`native_eq_contract` 修复前 E2/E3/E4/E5/E6/E7/E8 全红，修复后 17/17；
`native_single_scroll` 修复前 `settings.in` 红，修复后 40/40。

---

## 四、门禁

- `cmake --build build-mac -j8` → **0 error**。
- `ctest`：见下方实测结论（6 条沙箱假红见 ⚠️）。

## ⚠️ 未验证 / 已知限制

1. **未真机拖动验证**：判据证明的是"核心状态里那一段的 gain 真的变了、
   高亮不被回填抹掉"，但 20 段分隔线的疏密、拖动跟手的手感仍需你在
   设置 → EQ 页实测。
2. **`native_scroll_eq` 之外的 6 条 ctest 失败是本机沙箱假红**（与本轮改动无关，
   与交接文档记录的 6 条一致）：`mac_update`（hdiutil 不允许建 dmg）、
   `dsd_path`/`libroot_regress`/`upnp_control`/`webui_hardening`/`net_405`
   （`/bin/ps` 被拒 + 测试端口已有属主 79104）。
3. 「整页滚动」这一条只覆盖**左导航页面 + 设置 10 个页签**；
   详情页（专辑/艺术家/作品）与右抽屉、正在播放覆盖页尚未纳入本轮判据。
