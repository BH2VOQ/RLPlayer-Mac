# AI 整理栏空态与状态行 = web `nprailempty` / `nprailhint`（1.1.7.30 → 1.1.7.31）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `f5e144c`（1.1.7.30，工作树仅 `?? website/`）
分支 main（仅本地提交，未推送）· 提交：`feat(native): rail empty state and summary hint, 1.1.7.31`

## 0. 结论

| 项 | 结果 |
|---|---|
| 新判据 `native_rail_states` | 旧码 **2 passed / 5 failed**（缺标签后按条件提前收窄）→ 新码 **17 passed / 0 failed** |
| build | exit 0 |
| ctest / audit | 最终门禁统一回跑回填 |

## 1. web ↔ native 对照

| 维度 | web | 原生旧码（1.1.7.30） | 原生新码 |
|---|---|---|---|
| 无 AI 栏目（无标题/专辑/艺术家） | 卡片不渲染，`nprailempty` 出现：「播放后在右侧显示歌曲、专辑、艺术家（古典作品还会多一栏演绎版本）的精简整理资料。」（`ui_script.h:13055-13060`，CSS `ui_page.h:763` 10.5/1.6） | 恒显示 3 张空白卡 | 卡片全部 hidden，空态说明可见（`npRailEmpty`，10.5 mut2 换行） |
| 有实体 | 三卡显示 | 三卡显示 | 三卡显示、空态收起 |
| 歌曲资料状态行 | `nprailhint`（`ui_script.h:13331-13346`）：loading→「正在后台整理歌曲资料…」；error→「歌曲资料未能取到 · 点击重试」（可点，重取 summary）；insufficient→资料不足文案；其余隐藏 | 无状态行 | `npSummHint` 按钮：同三态文案；error 用 warn 色、点击清缓存并重取 `/api/entity/summary?kind=track`；ok 时隐藏 |
| 位置/字号 | 卡片区之后；10.5/1.5 | — | 栏底 10.5，宽 = 栏内容宽 |

## 2. 红 → 绿（同一份判据）

```
git checkout -- tools/native_ui/RLPNowPlayingViewController.mm
cmake --build build-mac -j8 --target test_native_rail_states
./build-mac/test_native_rail_states     # 2 passed / 5 failed, exit 1（缺 npRailEmpty 后条件收窄）
git apply /tmp/railstates-prod.patch
./build-mac/test_native_rail_states     # 17 passed / 0 failed, exit 0
```

日志：`evidence/native-rail-states-red-20261114.log` / `-green-20261114.log`。

## 3. 判据覆盖（桩客户端、离屏、不出声）

- 无实体：nprailempty 存在、真实可见（沿祖先链）、文案逐字 = web；三张卡全部不可见。
- 有实体：空态收起、三卡重新可见。
- loading / insufficient / error（文案、warn 色）/ ok 隐藏。
- error 点击：真的发 `/api/entity/summary?kind=track`（先清 URL 缓存，web npSummRetry 语义）。

## 4. 如实挂账

1. 本包由 Lead 直接实现。
2. 状态行放在栏底（web 在卡片区流式之后）；3 卡场景下视觉位置不同但区域一致，未做像素判据。
3. 空态说明/状态行的字号与换行由真实 NSView 断言；未做像素截图，观感由用户实机验收。
