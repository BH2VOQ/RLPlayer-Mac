# v3.3.11 `PLAYBACK_SETTINGS` 闸门 —— 本仓架构下不适用（N/A）

> 待移植清单「播放设置面板」组的**结论性文档**。结论：**不移植**，原因是架构差异，
> 不是遗漏，也不是"做不了"。记录证据与替代关系，供后来者复核。

## 1. 上游是什么（`/tmp/rlp2-v3311/ui_script.h:682-716`）

```js
var PLAYBACK_SETTINGS = { ready:false, loading:false, failed:false, invalidVolume:false, generation:0 };
function playbackSettingsBlocked() { … errorCode:'PLAYBACK_SETTINGS_NOT_READY' … }
function ensurePlaybackSettings() { if (PLAYBACK_SETTINGS.ready) return true; playbackSettingsBlocked(); return false; }
```

配套行为：

| 项 | 语义 |
|---|---|
| `apiRaw()` 前缀闸门 | `/api/{play,lib/play,sq/play,skip,pause,seek,cast/start,input/start,roomcorr/measure,volume,settings,preset/apply,workbench/*}` 在 `!PLAYBACK_SETTINGS.ready` 时**解析为拒绝**，不重试、不排队 |
| `playbackSettingsNotice` | 未就绪时显示提示块 |
| `playbackSettingsMsg` | `正在读取播放设置，完成后请再次点击播放。` / `播放设置读取失败，请重试后再手动播放。` / `保存的音量无效，请修正为 -120～+20 dB 后重新读取播放设置。` |
| `playbackSettingsRetry` | 读取失败时出现的「重新读取播放设置」按钮（重新 `loadSettings()`） |
| 音量相关控件 | 未就绪时 `volKnob`/`npVolKnob` 置 `locked`、`volFloor` disabled、`npVolLab` 显示「音量尚未读取」 |

## 2. 为什么在 mac 原生里**不可达**

原生版是**单进程整体**，启动顺序由代码写死（`tools/native_ui/RLPAppDelegate.mm`）：

```
59  applicationDidFinishLaunching:
73      [[RLPCoreClient shared] startEmbedded];   // ← 同步；设置在 rlapp::start_embedded() 内部读完
75      self.mainWC = [[RLPMainWindowController alloc] init];
76      [self.mainWC showWindow:nil];             // ← 直到这里才存在任何 UI
77      [self.mainWC.window makeKeyAndOrderFront:nil];
```

`startEmbedded` 返回时设置已读完（`RLPCoreClient.mm:29-34`，同步调用 `rlapp::start_embedded()` 并把结果存进 `_startedStorage`）。
**没有任何窗口在"设置尚未读取"时存在** ⟹ `ready=false` 这个状态在原生版里永远不可能出现。

上游之所以需要这套闸门，是因为 **Web 版页面经 HTTP 独立渲染**：页面可以先画出来、
后端还在读 `rlplayer-settings.conf`，中间存在真实的"能点按钮但设置没读"窗口。
把闸门照搬到原生，会得到一个**永远为 true 的 `ready`** —— 那是死代码 + 一排永远不显示的控件。

## 3. 原生已有的等价保护（不是空着）

| 上游闸门要防的事 | 原生对应 |
|---|---|
| 设置没读就播 ⟹ 用默认值播放 | 结构上不可能：UI 出现时设置已读 |
| 核心启动失败还让用户点 | `RLPCoreClient.started == NO`，各页显示「核心未启动」并禁用动作（`RLPAlbumDetailViewController` 等 12 个页面共 30+ 处 `shared].started` 判断） |
| 保存的音量是垃圾值 ⟹ NaN / 爆音 | **后端已做防护**：`tools/rtaweb.cpp:2012` `cp.initialVolumeDb = std::isfinite(p.volume) ? std::clamp(p.volume, -144.0, 0.0) : -20.0;` |
| 音量非法时告知用户改正 | **未做**（见第 4 节挂账） |

## 4. 如实挂账（唯一真实差异）

1. **非法保存音量是"静默 clamp"而非"告知用户"**：上游在 `invalidVolume` 时**拒绝播放**并提示
   「保存的音量无效，请修正为 -120～+20 dB 后重新读取播放设置」；本仓把它 clamp 进合法区间后
   继续工作，用户**看不到任何提示**。这是两者的真实行为差异，已记入偏差台账。
   要做成上游那样需要：设置解析时记 `volumeInvalid` → 通过 `/api/settings` 或诊断端点上抛 →
   原生设置页/播放页展示提示。属于**跨后端契约的改动**，不在本轮小范围移植内。
2. `playbackSettingsRetry`（重新读取按钮）同样不需要：原生没有"读取失败但 UI 还在"的状态；
   读取失败 ⟹ `started == NO` ⟹ 走「核心未启动」路径。
3. 未新增任何控件，故无 i18n 词条变化（上游那三条文案没有落地对象，不做空转词条）。

## 5. 复核方式

```bash
grep -n "startEmbedded" tools/native_ui/RLPAppDelegate.mm      # 73 行同步启动
grep -n "mainWC = " tools/native_ui/RLPAppDelegate.mm          # 75 行才建窗口
grep -n "initialVolumeDb" tools/rtaweb.cpp                     # 2012 行 clamp 防护
grep -c "PLAYBACK_SETTINGS" tools/native_ui/*.mm               # 0（如预期）
```
