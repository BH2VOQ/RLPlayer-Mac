# 播放队列页排序 = web `#qSort`（8 档 + CUE 区间保真）（1.1.7.27 → 1.1.7.28）

日期：2026-11-14 · 仓库 `/Users/august/Downloads/DQ/RLPlayer` · 基线 `6d2d45d`（1.1.7.27，工作树仅 `?? website/`）
分支 main（仅本地提交，未推送）· 提交：`feat(native): queue sort parity and cue-preserving qorder, 1.1.7.28`

## 0. 结论

| 项 | 结果 |
|---|---|
| 新判据 `native_queue_sort` | 旧码 **21 passed / 25 failed** → 新码 **56 passed / 0 failed** |
| build | exit 0 |
| ctest / audit | 待最终门禁回填 |

## 1. web ↔ native 对照

| 维度 | web | 原生旧码（1.1.7.27） | 原生新码 |
|---|---|---|---|
| 排序档位 | `ui_script.h:12564-12574`：默认顺序/标题/艺术家/专辑/时长/年份/随机打乱/反转顺序（8 档） | 3 档：默认/标题/艺术家 | 8 档，顺序/文案/representedObject 逐值一致 |
| default | `POST /api/qsort?by=default` 后重载 | 同（保留） | 同 |
| 文本排序 | title/artist/album 用 meta `t/a/al` 文本升序（`strCompare`） | 仅 title/artist，album 无 | 三种都用 `localizedStandardCompare`，空 meta 退路径 basename |
| 时长 | `meta.d` 升序 | 无 | 同 |
| 年份 | `meta.y` **降序**（新→旧） | 无 | 同 |
| 随机 | Fisher-Yates（`Math.random`） | 无 | Fisher-Yates（`arc4random_uniform`，不可预测） |
| 反转 | idx 反序 | 无 | 同 |
| qorder 行 | `queueItemLine`：path + `\t<cs>\t<ce>`（cs>=0 时），`files=` encodeURIComponent 多行 | 只发 path（**CUE 分轨丢失**） | path + `\t%.3f\t%.3f`；整轨行不带 |
| 行播放 | `playPath(items[i], cues[i][0], cues[i][1])` | `RLPPlayPath(path)`（丢区间） | 新增 `RLPPlayPathCue(path,cs,ce)`；队列行带区间 |
| 按钮 | 保存为歌单 / 清空队列；标签「排序：」 | 存为歌单 / 清空 / 排序 | 逐字对齐 |

## 2. 红 → 绿（同一份判据）

```
# 红：把 Queue/Support 生产文件还原到 6d2d45d，保留新测试 + CMake 注册
git checkout -- tools/native_ui/RLPQueueViewController.mm tools/native_ui/RLPSupport.h tools/native_ui/RLPSupport.mm
cmake --build build-mac -j8 --target test_native_queue_sort
./build-mac/test_native_queue_sort   # 21 passed / 25 failed, exit 1
git apply /tmp/queue-prod.patch
./build-mac/test_native_queue_sort   # 56 passed / 0 failed, exit 0
```

日志：`evidence/native-queue-sort-red-20261114.log` / `-green-20261114.log`。

## 3. 判据覆盖（桩客户端、离屏、不出声）

- 8 档标题/representedObject 顺序；按钮文案；「排序：」标签。
- title/artist/album/dur/year/reverse 的**路径顺序**逐一对齐 web 语义（fixture: 4 项，t/a/al/d/y 各不相同）。
- CUE 保真：第 2 项 `10.000/20.000`、第 4 项 `30.000/40.000` 在 qorder 对应行带上 `\tcs\tce`；整轨行不带。
- 行点击播放：CUE 行 body 带 `cs=10.000&ce=20.000`；整轨行不带 cs/ce。
- shuffle：同一批路径、无重复（不写随机序断言）。
- 既有入口：拖拽 pasteboard 类型 `RLPQueueRowDrag` 仍注册、行尾 `q.del` 仍在。

## 4. 如实挂账

1. 队列**行布局**（web `.qrow`：序号/标题/文件夹名/悬停 ×、行高 38、border-bottom、当前行 accent-weak）仍未移植：本包只做排序/播放契约，行布局留作下一包。
2. 本包由 Lead 直接实现（原派发的子代理在开始写文件前失败，工作树零残留）；红→绿与门禁由 Lead 本人跑。
3. 全部离屏单测；实机观感由用户验收。
