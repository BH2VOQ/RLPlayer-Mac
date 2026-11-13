# 专辑页 / 文件夹页空态 = web emptyStateHtml（1.1.7.29 → 1.1.7.30）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `924a03f`（1.1.7.29，工作树仅 `?? website/`）
分支 main（仅本地提交，未推送）· 提交：`feat(native): albums/folders empty states match web, 1.1.7.30`

## 0. 结论

| 项 | 结果 |
|---|---|
| 新判据 `native_empty_states` | 旧码 **0 passed / 14 failed** → 新码 **17 passed / 0 failed** |
| build | exit 0 |
| ctest / audit | 最终门禁统一复跑回填 |

## 1. web ↔ native 对照

| 维度 | web（`ui_script.h:1603-1651`、`:3545`） | 原生旧码（1.1.7.29） | 原生新码 |
|---|---|---|---|
| 专辑 0 张（无 roots） | 空态卡：🎵 + 「还没有添加音乐目录」+ 两行说明；按钮 添加音乐目录 / 扫描目录 / 打开快速开始 | 空网格 + 「0 张专辑」 | 空态卡（520 宽、radius 12、边框 --line）；文案/按钮逐字对齐 |
| 专辑 0 张（有 roots） | 「已添加音乐目录，但未找到音频文件」+「当前目录中未发现…」；按钮 管理音乐目录 / 重新扫描 / 打开快速开始；显示 root 路径 | 同上 | 同；root 路径来自 `/api/lib/stats` 的 `roots[0]`，单行中部省略 |
| 按钮动作 | bEmptyAddRoot → openSettingsTab('adv')；bEmptyScan → POST /api/lib/scan；emptyGoStation → 快速开始 | 无入口 | 三条路径逐一对齐（通知/请求由判据固定） |
| 文件夹 0 行 | `此目录没有音频文件`（rows 为空才追加） | 无提示 | `folders.empty` 标签，dirs+files 都为 0 时可见，否则收起 |
| 圆角/边距/字号 | .empty-guide-card padding 32 28、radius 12；标题 15/650；说明 12.5/1.7；root 11 | — | 520 宽、内边距 32/28、标题 15 semibold、说明 12.5、root 11 |

## 2. 红 → 绿（同一份判据）

```
git checkout -- tools/native_ui/RLPAlbumsViewController.mm tools/native_ui/RLPFoldersViewController.mm
cmake --build build-mac -j8 --target test_native_empty_states
./build-mac/test_native_empty_states     # 0 passed / 14 failed, exit 1
git apply /tmp/empty-prod.patch
./build-mac/test_native_empty_states     # 17 passed / 0 failed, exit 0
```

日志：`evidence/native-empty-states-red-20261114.log` / `-green-20261114.log`。

## 3. 判据覆盖（桩客户端、离屏、不出声）

- 有 roots 变体：空态卡真实可见、标题/说明/root 路径文案、三个按钮文案；扫描 POST `/api/lib/scan`、管理目录通知 `RLPOpenSettingsPaneNotification` object `adv`、快速开始通知 `RLPNavigateKeyNotification` object `sq`。
- 有专辑时卡片收起；无 roots 默认文案「还没有添加音乐目录 / 添加音乐目录」。
- 文件夹页空目录显示「此目录没有音频文件」；有目录/文件后收起。
- 「真实可见」沿祖先链检查 hidden/alpha/frame（防「控件在但父容器隐藏」的假绿）。

## 4. 如实挂账

1. 本包由 Lead 直接实现（此前后台派发的子代理在开始写文件前失败，工作树零残留）。
2. 空态卡未做像素级样式采样；几何/文案/动作由离屏判据固定，观感由用户实机验收。
3. 320/480 窄窗下空态卡 520 宽可能超宽（主窗口最小 900，不可达），未加自适应宽度。
