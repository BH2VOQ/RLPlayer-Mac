# EQ 页第二轮：点/曲线对应、OPRA 输入即检索、卡片空白与遮挡（1.1.7.88）

用户 2026-11-15 第二轮反馈（原话，四条）：

1. 「eq 的图，**点要跟 band 对应好**」
2. 「耳机 eq，要做到 web 版当时的效果，**输入耳机名的同时自动检索**，你看看 web 版的实现方式」
3. 「图一所示，**上半部分留了很多空白**」
4. 「**下半部分还有遮挡**」
5. （追加）「**重置底下 band 数据，曲线图不会随动**，这个也是 bug」

---

## 一、重置后曲线不随动（第 5 条）

### 根因（实测定位，不是猜）

用真实设置页跑诊断：

```
POST /api/peq bands=…(第11段 +9dB) → ok=1
后端立刻读：band11 gain=9.00  points 数=160      ← 后端确实存进去了
A  settings.reloadData 后 curve.points 峰值=0.00  ← 设置页刷新**没带上 EQ**
A2 eqView.reload 后     curve.points 峰值=9.00   ← 直接调 EQ 才拿到
```

`RLPSettingsViewController.mm` 的 `reloadData` 末尾本来就有其它子视图的刷新：

```objc
[self.serversView reload];
[self.metaSourcesView reload];
[self.libStatsView reload];
[self loadLlmConfig];
```

**唯独漏了 `self.eqView`**。而 `eqView` 只在 `fillEqualizer` 建立时 reload 一次，
此后再没人刷新它 ⟹ 用户做任何"外部改变"（重置 Flat、工作台改预设、OPRA 应用）之后
回到设置页，曲线仍停在旧数据上。

### 修复

补进那一串：`[self.eqView reload];`

### 判据 E12（**能红**）

走设置页真实刷新入口 `reloadData`（不是直接调 eqView.reload），
断言 `curve.points` 峰值 > 5；再点「重置 Flat」，断言峰值 < 0.5。

> 红→绿实测：修复前 A 处峰值恒 0.00（曲线拿不到新数据）；修复后 9.00 → 0.00。

---

## 二、点要跟 band 对应好（第 1 条）

### 根因

手柄原来画在**该段自己的 gain** 上：

```objc
const double db = self.bandGains[i].doubleValue;   // ← 错
```

但相邻段互相叠加：某段设 +9 dB 时，曲线在它自己的中心频率处**并不等于 +9**。
于是 20 个点连起来不是曲线，点会浮在曲线外面 —— 这正是"点跟 band 对不上"。

### 修复

1. 新增 `- (double)curveDbAtFrequency:`：用**后端 points 线性插值**求曲线值
   （对数频率轴，与 `drawRect` 同一套坐标；不自己算第二份频响公式）。
2. 手柄 y 改为 `curveDbAtFrequency:该段频率`（拖动中的那一段仍用实时值）。
3. 拖动语义改为 web 的**位移累加**（`ui_script.h:11645` 有 web 自己的解释）：
   `db = 起拖时增益 + 指针位移像素 / (绘图区高 / 36 dB)`，夹在 ±18。
   绝对映射会让指针不动值也变（量程一变就自己冲），位移累加才能"点贴着手指"。

### 判据 E13（**能红**）

造"邻居段把某点抬起来"的形状（第 10 段 +12 dB，第 11 段自身 0 dB），此时：
- 曲线在第 11 段中心频率处 = 非零（实测通过）
- 两种画法（贴曲线 / 贴自身增益）差得开（> 3pt，判据有区分力）
- 生产入口取到的值 = 曲线插值，不是 bandGains

> ⚠️ 判据自己踩过一个坑并修掉：第一版按 `bf[10]` 取"第 11 个频点"，
> 但后端给的是 ISO 1/3 倍频程序列（20/25/40/63/80/125/200/315/500/800/**1000**/1250/…），
> 索引 10 才是 1000 Hz，`bf[10]` 是 9920 Hz。**期望值算错导致的假红，不是产品问题**。

---

## 三、OPRA 输入即检索（第 2 条）

### web 的实现方式（`src/net/ui_script.h`）

```js
sInput.oninput = function () { doSearch(this.value); };   // 11959 / 12147
```

`doSearch(q)` 的口径：
- 空输入 ⟹ 清空卡片、显示引导（不发请求）
- 索引未加载 ⟹ 先 `loadOpraIndex` 再重入
- 按空白切 token，**每个 token 都要出现在** `vendor name id` 里（AND 语义）
- 最多 30 条；>30 时提示"已显示前 30 条，继续输入更具体关键词"
- 结果为空 ⟹「未找到匹配的耳机型号」

### 原来的原生实现

只有「点搜索按钮 / 回车」才查（`onOpraSearch:`），**边打字不出结果**。

### 修复

- 拆出 `runOpraSearch:`（按钮 / 回车 / 输入去抖三处共用一份逻辑）。
- 加 `NSTextFieldDelegate` 的 `controlTextDidChange:`，**180ms 去抖**后调 `runOpraSearch:`。
  去抖不是为了性能（6230 条本地过滤很快），而是每次都会重排卡片栈 ⟹ 不去抖打字时界面会抖。
- 同一关键词不重复重排（`opraLastQuery`）。
- 输入清空 ⟹ 回到初始态（与 web `doSearch('')` 同语义）。

### 判据 E14（**能红**）

**不点按钮、不回车**，只改文本并投递 `NSControlTextDidChangeNotification`，
断言结果集真的变了（k701 → akg，条数不同）。

---

## 四、上半部分空白 / 下半部分遮挡（第 3、4 条）

### 根因

`fillEqualizer` 里高度只在**变大**时更新：

```objc
CGFloat h = [self.eqView preferredContentHeight];
if (h > self.eqHeightConstraint.constant) {           // ← 只放大
    self.eqHeightConstraint.constant = MAX(420.0, h);
}
```

以及 OPRA 卡片**异步**到达（搜索才拉 / 应用后才渲染）时，**从不通知父卡片重新量高** ⟹
卡片高度停在"0 行"时算出的值，卡片内容溢出边框 = 截图里的下半遮挡。

### 修复

- 新增 `RLPEqualizerView.onContentSizeChanged` 回调，在 `renderModelCards` /
  `renderPresetCards` 结束时触发。
- 设置页改成**双向**同步（`fabs(h - constant) > 0.5` 就改），并在建立时 + 下一个 runloop 各调一次。

### 判据 E15（**能红**，且第一版是**无效判据**）

⚠️ 第一版 E15 只量静态首帧，**在旧代码上也是绿的** —— 因为静态时两张卡的高度本来就对。
它测不出用户报的那个问题。**无效判据比没有判据更糟**，所以重写成异步路径：

- 先记下 OPRA 卡片原高
- 搜 `k701`，等卡片异步渲染
- 断言卡片**长高了**（> +20pt）
- 断言内容没溢出卡片边框、底部没留 > 60pt 空白

> 红→绿实测：把 `onContentSizeChanged` 注释掉 ⟹
> `[FAIL] E15 型号卡片到达后 OPRA 卡片长高了 — before=200 after=200`；
> 恢复后 44/44 全绿。**这条判据确实有区分力。**

---

## 五、判据总表

| 测试 | 条数 | 覆盖 |
|---|---|---|
| `native_eq_contract` | **44** | E1–E8 契约/数据/拖动、E9–E10 自动前级、E11 重置随动、**E12** 设置页刷新带 EQ、**E13** 点贴曲线、**E14** 输入即检索、**E15** 卡片空白/遮挡 |
| `native_single_scroll` | 40 | 每页至多一层滚动 + 无嵌套 |
| `native_scroll_eq` | 12 | 单层滚动 + 拖动下发体符合后端契约 |
| `native_opra_cards` | 25 | OPRA 卡片墙 |

## 六、门禁

- build **0 error**
- parity `missing=0`、i18n 0 缺失
- ctest 见下方实测结论

## ⚠️ 未验证

1. **未真机拖动/输入验证**：判据证明的是"数据链路 + 命中位置 + 卡片高度跟随"，
   真正的拖动手感、边打字边出结果的观感、以及 20 条分隔线的疏密仍需你在
   设置 → EQ 页实测。
2. 「上半空白」我只在**异步路径**（E15）上拿到可红判据；如果你的现象出现在
   别的入口（例如从工作台切回设置页），告诉我具体路径，我按那条路径补判据。
