# `/api/meta` 补 `coverSource` + 「自动」封面按钮闸门（1.1.7.76）

> 收口偏差台账里由我此前记录的一条：**`/api/meta` 不返回 `coverSource` ⟹ 原生「自动」封面按钮常显**。

## 1. 上游真值

| 位置 | 内容 |
|---|---|
| `rtaweb.cpp:13916`（上游） | `/api/meta` 输出 `,"coverSource":"<source>"` |
| 词表 | `manual` / `online` / `extracted` / `embed` / `none`（`CoverResolution.source`，见上游 6855/5943/6016 行） |
| 前端 | 播放页「自动」按钮（`npResetCover`）仅在 `coverSource === 'manual'` 时出现 |

## 2. 原生缺口

- `/api/meta` 只给 `hasCover` / `coverFromAlbum`，没有 `coverSource`；
- 于是播放页只能让「自动」按钮**常显** —— 点了也没有手动封面可恢复（因为本来就没有），
  属于"看起来能用、实际无意义"的控件（偏差台账已如实记录）。

## 3. 实现

| 侧 | 改动 |
|---|---|
| 后端 | 新增 `cover_manual_active_for(file)`：key 口径与 `/api/cover` 完全一致（`track:<hash>`，`lib_path_key` + `MetaStore::hashOf`）；有 `.source.json`（reset 标记）时不生效 |
| 后端 | `/api/meta` 输出 `coverSource`：`manual` / `embed`（有封面）/ `none` |
| 前端 | 抽出 `-applyCoverSourceGate`（读 `trackMetadata[@"coverSource"]`，非 `manual` 即隐藏）；`loadMeta` 回调里调用它 |
| 前端 | 控件初始 `hidden = YES`（没有手动封面就不该出现） |

抽成独立方法是为了**判据可直接调用**（不必等 `/api/meta` 的网络回调，避免脆弱的异步判据）。

## 4. 判据

| 判据 | 位置 | 钉住什么 |
|---|---|---|
| K7 | `test_embedded_api` | 手动封面生效时 `coverSource == manual` |
| K8 | `test_embedded_api` | `/api/cover/reset` 之后**不再是** `manual` |
| C4b | `test_native_nowplaying_web` | 无手动封面时「自动」按钮隐藏 |
| C4c | 同上 | `coverSource == manual` 时按钮显示 |
| C4d | 同上 | 切回 `embed` 时按钮重新隐藏 |

红 → 绿：接线前 K7/K8 与 C4b–C4d 均无可断言对象（字段/闸门不存在）；接线后
`test_embedded_api: 0 失败 / 1 跳过`（K7/K8 PASS），`np web: 231 checks / 0 failures`。

## 5. 如实挂账

1. **只区分 `manual` 与其余**：本仓没有上游那套 `online`/`extracted` 的完整来源溯源链，
   所以 `embed`/`none` 的两分法是本仓现状的诚实映射，不是上游五值全集。
2. `reset` 判定用 `.source.json` 存在性（与 `/api/cover` 读路径同口径），未逐字节校验 manifest 内容。
3. 未验证真机上"设置封面后按钮出现、恢复后消失"的完整交互（离屏判据只覆盖闸门与后端字段）。