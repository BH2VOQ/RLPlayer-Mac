# v3.3.11 `quickStartModel` 能力门控（1.1.7.69）

> 待移植清单「快速启动」组的**真实可移植部分**。
> 先说清一件事：上游的「快速开始**页面**」在 v3.3.11 已经**是死代码**（见第 1 节），
> 活着的是它的**能力模型**，用于「播放方式」三档能不能点。

## 1. 上游现状核对（重要，避免做无用功）

| 事实 | 证据 |
|---|---|
| `quickStartHtml()` **没有任何调用点**（定义了却从不渲染） | `grep -n "quickStartHtml(" /tmp/rlp2-v3311/ui_script.h` → 只有 5340 行的定义自身 |
| 导航项被**永久隐藏** | `syncQuickStartVisibility()`：`nav.hidden=true; nav.style.display='none'`（5373-5374） |
| 页面标记在 `ui_page.h` 里只剩 4 处残留 | `grep -c "quick-start\|qsEnterLibrary" ui_page.h` → 4 |
| **活着的是** `quickStartModel()` | 唯一消费点是 `rlPaintPreset()`（5760 行），服务于「日常设置 → 预设」 |

结论：照搬「快速开始页面」= 移植一个上游自己都不渲染的页面。**不做**。
真正该移植的是 `quickStartModel` 的三项判定，它决定了用户能不能点「PCM 升频 / DSD 升频」。

## 2. 上游判定（`ui_script.h:5326-5338` + `5771-5774`）

```js
var remote = backend==='upnp', shared = backend==='wasapi-shared', offline = backend==='null';
var known = !offline && !remote && !!(caps.ok && d.name && Array.isArray(d.rates) && d.rates.length && d.maxRate>0);
var nativeDsd = backend==='asio' && d.dsdNative===true;
pcmReady = known && !remote && !shared;
dsdReady = known && !remote && !shared && (nativeDsd || d.dop===true);
// rlPaintPreset：
b.disabled = state.applying || (k==='pcm' && !model.pcmReady) || (k==='dsd' && !model.dsdReady);
提示：!model.pcmReady ⟹ 「能力尚未确认，请先选择输出设备。」
     S.playing||S.paused   ⟹ 「请先停止播放，再应用预设。」
```

## 3. 本仓旧码的真实缺陷（本包修的）

`tools/native_ui/RLPQuickStartViewController.mm` 旧实现：

```objc
- (void)loadPresetCaps:(BOOL)force {
    …
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary *json) {
        // 能力只影响按钮是否可用；读不到就保持可用（宁可点下去报错，也不假装不支持）
        (void)json;          // ← 拉回来就丢掉
    }];
}
```

后果：`/api/preset/caps` 是一次**纯装饰**请求；「播放方式」弹层的三档**永远可点**。
用户点了不支持的档位，只会事后在后端 `notes` 里看到降级说明，事先没有任何提示。

## 4. 实现

| 项 | 做法 |
|---|---|
| 纯函数 `+gatingForCapsJSON:` | 从 `/api/preset/caps` 响应算出 `@{known, pcmReady, dsdReady}`；**逐条**照上游四条分支（offline / remote / shared / known / dsdNative / dop）。抽成类方法的理由：这条决策决定按钮能否点，必须能被判据直接测，而不是只能"开弹层再找按钮"间接测 |
| `applyPresetCaps:` | 把纯函数结果写进 `presetCapsKnown / presetPcmReady / presetDsdReady`（旧码丢弃的位置） |
| 弹层置灰 | `onOpenPlay:` 按上游 `rlPaintPreset` 逐档判定：`code==1 → pcmReady`、`code==2 → dsdReady`；`busy = playing \|\| paused` 时三档全禁；置灰行写 `toolTip` 说明原因 |
| 说明行 | 新增 `quickstart.presetGate` 标签，把原因**写在界面上**（上游也是文字提示，不只靠禁用态） |
| 播放状态 | 该页原本只记 `playing = st.playing && !st.paused`；**暂停会被误判成"可以应用"**，故新增 `pausedNow` 单独记暂停态 |
| i18n | 4 条（`chunk-native122-qsgate`），逐字取上游同文案；coverage 0 缺失 |

mac 侧差异（如实）：`backend` 不存在 `upnp` / `wasapi-shared`，故这两条分支在当前平台恒 false ——
**代码保留**（将来若接投放/共享输出立即可用），不是死分支。

## 5. 红 → 绿（`test_listening_room.mm` 新增 Q1–Q5）

| 判据 | 红（能力恒可用 = 旧码效果） | 绿 |
|---|---|---|
| Q1a 完整能力 ⟹ known | PASS | PASS |
| Q1b 完整能力 ⟹ PCM 可用 | PASS | PASS |
| Q1c 有 DoP ⟹ DSD 可用 | PASS | PASS |
| Q2a 无 DoP 无 Native ⟹ DSD **不可用** | **FAIL** | PASS |
| Q2b 但 PCM 仍可用（不连坐） | PASS | PASS |
| Q3 离线（null）⟹ known=false | **FAIL** | PASS |
| Q3b 离线时两档都不可用 | **FAIL** | PASS |
| Q4 无名/无采样率 ⟹ 能力未确认 | **FAIL** | PASS |
| Q5a `ok:false` ⟹ 不可用 | **FAIL** | PASS |
| Q5b `nil` ⟹ 不可用（不臆造能力） | **FAIL** | PASS |

| 轮次 | 结果 | 证据 |
|---|---|---|
| 红（门控恒 true） | build 0 error；**6 FAIL**（Q2a/Q3/Q3b/Q4/Q5a/Q5b） | `evidence/native-quickstart-gating-red-20261115.log` |
| 绿（1.1.7.69） | build 0 error；`listening_room 全部通过（0 项失败）` | `evidence/native-quickstart-gating-green-20261115.log` |

## 6. 如实挂账

1. **「快速开始页面」不移植**：上游 `quickStartHtml` 无调用点、导航永久隐藏 —— 移植一个不渲染的页面
   是空转。原生侧对应的用户路径是专辑页空态（`还没有添加音乐目录` + `添加音乐目录` 按钮），已存在。
2. **`quickstart` 偏好（初始视图走聆听室）未移植**：属偏好项，不影响能力判定；记在此备查。
3. 弹层的置灰/说明**未做页面级真点击判据**（离屏弹 NSPopover 不稳）；已用纯函数覆盖同一决策，
   并在代码里把纯函数作为唯一真源（没有第二份判定）。
4. `preset/apply` 未加 `require_stopped=1`/`preserve_processing`：本仓后端不认这些参数
   （`preset_apply_json` 只读 `profile` 与 source info），加了是空参数。停止闸门由 UI 侧承担。
