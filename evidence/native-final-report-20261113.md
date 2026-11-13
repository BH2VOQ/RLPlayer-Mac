# RLPlayer（macOS 原生 AppKit 版）14 项修复 · 总报告

**日期**：2026-11-13　**版本**：1.1.7.22　**提交**：`673f735`（本地，未推送）
**仓库**：`/Users/august/Downloads/DQ/RLPlayer`（git main；只本地提交，未推 Gitea/GitHub、未发版、未打 tag）

> 现场确认：接手时 HEAD=`af67b84` / `1.1.7.21`，工作树里有上一轮中断留下的第 8 项半成品
> （`RLPTargetCurve.h/.mm` + `RLPEqualizerView.mm` 的 targetCurve 绘制层）。经构建验证其为**可构建**状态
> （不是红状态），且 11 条曲线数据与 web `ui_script.h:10797-10820` **逐值一致**，故保留并完成（未重头再来）。
> （`website/` 是与本次无关的历史目录，未提交。）

---

## ① 十四项逐项结论

| # | 项 | 结论 | 依据 / 挂在哪个门禁上 |
|---|---|---|---|
| 1 | 播放失败（硬故障） | **未修复（根因未定位）**：已加播放门禁。决定性发现：`--audit` **从未调用任何播放入口**（`grep -c RLPPlayPath --audit = 0`），所以"219 项全绿却带着无法播放上线"成立。引擎侧已系统排除（backend=null / coreaudio / Hog 独占 / 全新状态目录 / 特殊路径 / 90s 连续播放 / 并发 600 次 status 全绿）。**需用户导出诊断包**才能继续定位 | `evidence/native-playback-*.md`、`native-playback-audit-green-20261113.log` |
| 2 | 播放页外底栏图标不切暂停态 | **仅回归防线**（旧码上新判据也全绿，自动化环境复现不出）。过程中修了两个真问题：SF Symbol `image.name` 可能为 nil ⟹ 判据恒红；`say -o` 夹具只有 0.69 秒而索引写死 30s ⟹ 所有"播放中"断言都在音频结束后执行 | `native_bar_core`（ctest） |
| 3 | 播放页红圆"不圆" | **仅回归防线**。实测两张原图：红圆 67×66px 完整、三角左右留白 25/25px、圆心偏差 0/0.5px；真实缺陷是**白色进度滑块头压在圆键上方**被播放条上沿切掉 ⟹ 判据写成"滑块头不得与圆键相交" | `evidence/native-playback-bar-20261113.md` |
| 4 | 播放页左栏一点击气泡丢失 | **已解决**：与 9/10 同为 popover 形态问题，随内联化（`9a79797`）一并消失 | `9a79797` |
| **5** | **AI 整理栏三张卡片间距/排版** | **本轮完成**。三张卡原是 NSButton 多行标题，AppKit 把文字画在卡片**左下角**（上半部全空，`padY.top` 实测 72pt vs web 8pt）；改为真实子视图卡片：内边距 8/10/9、行距 2、圆点 5/间距 7、圆角 11、卡片间 6、栏头→首卡 8、栏左右 10、栏头字距 1.5 | 新 ctest **`native_rail_cards`**：旧码 **15P/14F** → 新码 **56P/0F**；`native-item5-20261113.md`（含 web/原生/差值三列表） |
| 6 | 统一单层滚动 | **判据已修**（实现其实 `680d395` 就做了）。坏的是旧判据只数 `hasVerticalScroller`，而 `hasVerticalScroller=NO` ≠ 不可滚。新判据 `test_native_scroll_eq`：内层"可滚动"scroll view 数 == 0（滚动条开关 OR 内容溢出双条件），且真实鼠标点沿 nextResponder 必须走到外层滚动容器 | `fb022e8` |
| 7 | EQ 曲线拖不动 | **判据已修**（实现早已绑 `onDragBand`）。旧判据直接调 `applyDragEvent:`，没测事件能否到达视图；新判据走 hitTest → mouseDown/Dragged/Up，断言 `/api/peq` 真下发且 body 解码后至少一段增益 ≠ 0 | `fb022e8` |
| **8** | **耳机目标曲线按 web 接入** | **本轮完成（功能缺失，四层全部断过，全部修）**：①`/api/opra/index` items 是 `[id,vendor,name]` **数组三元组**，旧码按字典解析 ⟹ 搜索恒空；②无 target curve 图层；③`/api/opra/presets` **没有 name 字段**（id/author/details/gainDb/bandsCount），旧码读 name ⟹ 预设下拉恒空、apply 后也没写回 settings 的 `eq=` ⟹ 后端不热重载；④选中/应用后不展示目标曲线说明。现按 web：索引全量拉一次（不带 q）+ 本地 token 过滤、显示名 author·details、11 条曲线 + 10 条文案全量移植、虚线图层画在 EQ 图上、`opra.info` 说明行、写回 `eq/opraproduct/oprapreset` | 新 ctest **`native_target_curve`**：旧码 **4P/10F** → 新码 **22P/0F**；`native-item8-20261113.md` + `native-item8-web-diff-20261113.txt` |
| 9/10/11 | 诊断/反馈区重做 | **已完成**（`9a79797`）：取消 NSPopover 改内联。根因 `RLPCardController` 只钉 root width=660 却**从没设 `preferredContentSize`**，content stack `alignment=Leading` 且内部 620pt NSScrollView 无父宽约束 ⟹ 气泡按 fittingSize 塌到近 0 高。诊断包区改 web 形态三按钮（红底「导出诊断包（.zip）」/「只要 JSON」/「查看 / 复制诊断摘要」），**删除「随反馈上传诊断」**并用 `parity_removed.tsv` 双向核验 | `9a79797`、parity removed=1 ok |
| **12** | **标签写回并入卡片、整页排版** | **本轮完成**。旧码是"空壳「标签写回」卡片 + 页面并列的说明/两个按钮"（用户描述完全复现）；并入「AI 接入（OpenAI 兼容）」卡体（web `.mh.sub` 位置），新增 `addSubHeader:`/`addNoteView:` 原语，按钮走卡片通用按钮行；写回语义/identifier/文案逐条保留 | 新 ctest **`native_writeback_card`**：旧码 **3P/1F**（结构）→ 新码 **19P/0F**；`native-item12-20261113.md` + 离屏前后对比 PNG |
| 13 | 徽章文字居中 | **已完成**（`af67b84`）：垂直真因 `NSTextField` 在固定高胶囊里把单行文字排顶部（实测 0.5/9.0pt），水平真因 `gpuBadge` 没设 alignment（左 0.5/右 10.0）。改用自绘居中 `RLPBadgeLabel`，修后三枚 \|Δ\| ≤ 0.5pt | `af67b84`、`native-badge-centering-20261113.md` |
| 14 | 播放条磨砂胶囊条 | **结构已实现，模糊只能实机验**（`af67b84`）：`.hudWindow`/`.withinWindow`/`.state=active`、玻璃层最底层覆盖整条、圆角一致、条高 66、控制键居中 0.00pt、左右留白 18/18、有投影。**离屏无法证明模糊**：单独渲染 VEV 纯白 sd=0.0000；有/无玻璃层整窗渲染**逐字节相同**（AppKit 离屏不做 backdrop 合成）。此前两个"磨砂判据"都被自证假绿 | `native-bar-frosted-after-20261113.png`、假绿清单 #7 |
| + | 安全缺陷 `generate_random_token` | **已修**（`af67b84`，见 §③） | `test_upnp_control` 并发判据 |

---

## ② 「假绿判据」清单现状

`evidence/native-fake-green-criteria.md`：**从 8 条增至 11 条**。本轮新增 3 条（都是本轮判据自己抓出来的）：

| # | 假绿形态 | 本轮教训 |
|---|---|---|
| 9 | **几何判据全绿 ≠ 渲染正确** | 第 12 项 19 项几何全绿，但第一次导出离屏图才发现：状态标签与按钮塞同一横向 stack，状态文本内在宽度把「预览写回」压成 0 宽、「执行写回」截断成「执行…」。改回卡片通用按钮行 + 强制附离屏渲染图作交付证据 |
| 10 | **属性存在 ≠ 功能接入** | 上一轮半成品有 `RLPTargetCurve` 数据表和 `targetCurve` 属性、能编译，看起来"已接入"；实际**没有任何赋值点**，图层永远 nil。必须用真实 UI 动作链 + 像素判据 |
| 11 | **编译绿 ≠ 运行绿** | 第 8 项判据第一轮就崩两次：`RLPMutableTargetCurve` 重声明 readwrite 属性但 clang 不合成 setter ⟹ `unrecognized selector`；`targetCurve` 误用 `copy` 而曲线未实现 `NSCopying` ⟹ `copyWithZone:` 崩溃 |

前 8 条摘要（细节见文件）：#1 只看尾行不看退出码；#2 `--audit` 从未调用播放入口；#3 "有 VEV 就算磨砂"；
#4 "换背景像素会变"（删掉玻璃层仍 PASS）；#5 只数 `hasVerticalScroller`；#6 只调 `applyDragEvent:` 内部方法；
#7 单线程随机 token 断言；#8 磨砂离屏渲染不可证（单独 VEV 纯白 / 有玻璃与无玻璃逐字节相同）。

---

## ③ `arc4random` 安全缺陷（上一轮 `af67b84`）

- **缺陷**：`generate_random_token` 用 `high_resolution_clock` 计数当种子喂 LCG。同一时钟刻度内两次调用种子相同 ⟹ **token 完全相同**。
- **为什么是安全问题**：token 是 `/stream/<token>.wav` 的**访问凭据**（UPnP/HTTP 供源）。可预测凭据 = 没有凭据；同一秒内起两个会话还会撞 token。
- **怎么发现**：一个"连续两次不同"的判据偶发红 —— 进而追到根因。
- **量化**：单线程 20000 对撞 **0** 次（单线程判据基本无检出力）；**4 线程各 2000 次（8000 个 token）旧实现实测碰撞 80 次**（`af67b84` 提交记录；测试注释里另一次运行记录为 13 次碰撞/8 个完全重复，说明旧实现的行为随时钟刻度抖动，但**稳定红**）。
- **修法**：`arc4random`（macOS/BSD 自带 CSPRNG，无需播种、无失败模式、线程安全；每 hex 字符取一个随机字节低 4 位）。非 BSD 平台退回"时钟 + pid + 计数器 + 对象地址"混合种子，保证两次不同源。
- **红绿判据**：`tests/test_upnp_control.cpp` —— 4 线程并发生成 8000 个 token，断言零碰撞。旧码稳定红（实测 73–80 / 13 取决于运行），新码稳定绿。

---

## ④ 最终提交列表与门禁数字

**提交（全部本地，未推送）**

```
673f735 feat(native): rail chip geometry, inline writeback, headphone target curve, 1.1.7.22   ← 本轮
af67b84 fix(native): centred badges, frosted bar, real random tokens, 1.1.7.21
fb022e8 test(native): real event chain for single scroll and EQ drag, 1.1.7.20
0bb2f21 test(native): playback gate, bar-core test, honest fixture, 1.1.7.19
9a79797 fix(native): inline diagnostics and feedback, drop popover, 1.1.7.18
d717ef0 feat(native): analysis summary cards like web, 1.1.7.17
87c83d7 feat(native): two-column metadata advanced layout, 1.1.7.16
90e5b54 test(native): red-first evidence + badge typography and popover probe
680d395 feat(native): 1.1.7.15 UI parity fixes from on-device feedback
```

**最终门禁（2026-11-13 23:20 实测）**

| 门禁 | 数字 | 证据 |
|---|---|---|
| build (`cmake --build build-mac -j8`) | **0 error**（全部 target 链接通过） | 构建日志 |
| ctest (`ctest --test-dir build-mac -j1`) | **184/184 passed, 0 failed**（357.05s） | `evidence/native-item5-12-8-ctest-184.log` |
| audit (`rlplayer_native --audit`) | **246 passed, 0 failed**（exit 0） | `evidence/native-final-audit.log` |
| parity (`parity_scan.py --check`) | ctrl done=180 **missing=0** removed=1；api done=96 **missing=0** na=16（na 16 ok/0 bad；removed 1 ok/0 bad） | 终端输出 |
| behavior (`behavior_scan.py --check`) | **actionable=0**（bindings=50） | 终端输出 |
| i18n (`gen_i18n_table.py --check`) | **OK (2316 pairs)** | 终端输出 |

> 本轮新增 3 个 ctest 用例：`native_rail_cards`、`native_writeback_card`、`native_target_curve`
> （基线 181 → 184）。

---

## ⑤ 一次性实机验收清单（只能实机验的项）

| # | 项 | 实机怎么看 | 预期 |
|---|---|---|---|
| 1 | **第 14 项 磨砂模糊** | 播放页，深色主题，播放条后面放一张有纹理的封面/背景 | 条内背景**被模糊**（离屏渲染无法证明，结构/几何已绿） |
| 2 | **第 1 项 播放失败** | 播放一首歌；失败时用诊断区「导出诊断包（.zip）」把 zip 发给开发 | 能定位根因；zip 内应含播放日志与状态 |
| 3 | **第 5 项 AI 整理栏观感** | 播放页右栏三张卡：标题在左上、下方两行正文、圆点在名称左侧；切「详细」看内容 | 不再出现"文字趴在卡片左下角、上半部全空" |
| 4 | **第 12 项 标签写回排版** | 设置·元数据 → 高级选项展开，看「AI 接入」卡内「标签写回」子段 | 标题/说明/两个按钮在同一卡片内；窄窗口下两列变一列不溢出 |
| 5 | **第 8 项 耳机目标曲线** | 设置·EQ：搜索耳机型号 → 选型号 → 选预设 → 看 EQ 图与说明行 → 点应用 | 图上出现虚线目标形状且随预设变化；说明行显示曲线名/是什么/适合谁；应用后 EQ 真的切换（听感/曲线都变） |
| 6 | 第 2/3 项 回归防线 | 播放中看底栏图标是否切暂停；看红圆与进度滑块 | 图标切暂停；滑块头不与圆键相交 |
| 7 | 第 6 项 单层滚动 | 设置·EQ：在 20 段表上滚动 | 只滚外层页面，不出现"滚不动/被拐走" |
| 8 | 第 7 项 EQ 拖动 | EQ 图上按住拖动某段 | 曲线与 20 段表增益同步变化 |
| 9 | 第 9/10/11 项 内联诊断 | 设置·诊断：三按钮形态、无「随反馈上传诊断」 | 导出 zip / 只要 JSON / 查看·复制摘要 三条都在 |
| 10 | 第 13 项 徽章居中 | 首页/播放条上的徽章 | 文字水平垂直居中 |

> 纪律：**实机测试由用户执行**，agent 只给命令与预期；用户可能戴着耳机，任何自动化测试都不得出声。

---

## ⑥ 仍未完成项与下一步建议

1. **第 1 项播放失败根因未定位（P0）** —— 唯一需要用户动作的一项：实机复现后导出诊断包（zip）给我/下一轮。
   现有门禁只能证明"入口被调用时引擎路径正常"，证明不了"真实点播放按钮时的完整链路"。
2. **第 2/3 项只是回归防线**（自动化环境复现不出用户描述的现象）；若实机仍出现，需用户在出问题时截图/录制。
3. **第 5 项内容层差异**：栏卡片正文仍是本地曲目事实 + 「点开查看」，没有把 web 的 AI fields 预览
   （`/api/entity/summary` 缓存）接到栏上。几何/排版已对齐，内容保真属另一件事，建议下一轮单独做。
4. **第 8 项两处呈现差异（不是功能缺失）**：① web 是预设卡片墙（每卡一张小曲线图），原生是下拉框，
   所以曲线画在主 EQ 图上；② 曲线纵轴沿用 web `.tc-curve` 的示意常数（MAXDB=9/MINDB=-2 映射绘图区），
   是"示意图形"而非 EQ 的 ±18dB 精确坐标。若用户要求"按 dB 精确叠加"，需再改一次（会说清语义）。
5. **第 14 项模糊**：结构/几何已绿，模糊必须实机确认（见 §⑤）。
6. **建议**：把本轮新增的 3 个 ctest（184 项）纳入之后的回归基线；假绿清单继续按"判据自己抓到的"原则续写。
