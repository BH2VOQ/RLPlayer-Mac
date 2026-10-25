# WIP-C2：测量会话编排层（外部评审会话 C 包）

日期：2026-10-25 实现（工作区 `D:\RTA-health`，分支 `audio-health`）
状态：全部断言为本机实测（虚拟房间、确定性可复现），测试 exe **45 条断言全 PASS**
（exit 0），c++20 / c++23 双标准编译通过。

## 1. 一句话结论

测量会话编排层按 spec 落地：**传输接口注入**（会话层只见 `MeasurementTransport`
纯虚接口，不碰任何设备、不 include src/audio）+ 逐声道质检（SNR/削波/超低极性/
半套拒绝）。虚拟房间端到端 8 节 45 判据全过：直达声恢复 **10.000 / 15.500 ms（误差 0）**；
干净房间 **SNR 57.0 / 54.4 dB**；−10 dBFS 噪声声道 **SNR −0.7 dB 触发告警、另一声道不误报**；
超低反接场景 **subAlign 延迟 12.000 ms 恢复 + 极性告警命中**；校正闭环与 tilt 目标差
**1.2779 / 1.2776 dB（≤2.0，与 C1 干净 IR 的 1.278 持平）**；WAV 导出 32812 字节
（44 头 + 8192×4 数据），RIFF/WAVE/dataLen 全对。

## 2. 交付物与构建

| 文件 | 说明 |
|---|---|
| `src/dsp/room_measurement.h` | MeasurementTransport / MeasurementSession::run（逐声道扫频→采集→反卷积→质检）/ sub_polarity_inverted / build_corrections（半套拒绝 + subAlign 传递 + globalGainDb）/ export_corrections_wav（44 字节头自写 32f WAV） |
| `tests/test_room_measurement.cpp` | 虚拟房间端到端 8 节 45 条断言，全部确定性（固定种子 LCG） |
| `docs/WIP-C2.md` | 本文档 |
| `docs/测量接线说明-给主线.md` | 主线接线说明（传输契约 / 铁律 1 出声授权 / 线程模型 / CorrectionSet 进管线） |

构建配方（与 C1 同款，已验证）：

```
"C:/Program Files/AMD/ROCm/7.2/bin/clang++.exe" -O2 -std=c++20 -Isrc tests/test_room_measurement.cpp -o build-health/test_room_measurement.exe
"C:/Program Files/AMD/ROCm/7.2/bin/clang++.exe" -O2 -std=c++23 -Isrc tests/test_room_measurement.cpp -o build-health/test_room_measurement.exe   # 双验证通过
```

## 3. 断言实测值（45/45 PASS）

### §0 前置

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 1 | 布局表含 2.0 与 2.1 | 均在 | PASS |

### §1 2.0 全流程（L=10 ms / R=15.5 ms，C1 配方架+梳状房间，噪声 −80 dBFS，扫频 −20 dBFS）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 2 | 两声道都测到 | 2 | PASS |
| 3 | 两声道 valid | 全 valid | PASS |
| 4 | L peakMs = 10 ±0.5 ms | **10.000**（误差 0） | PASS |
| 5 | R peakMs = 15.5 ±0.5 ms | **15.500**（误差 0） | PASS |
| 6 | 两声道 SNR > 30 dB | **57.0 / 54.4** | PASS |
| 7 | warnings 空 | 0 条 | PASS |
| 8 | 未中止 | aborted=false | PASS |
| 9 | 进度回调次数 = 声道数 | 2 次 | PASS |
| 10 | stepIndex/totalSteps 递增 | (1,2)→(2,2) | PASS |
| 11 | 声道名进进度回调 | L、R | PASS |
| 12 | 每声道恰好一次播放采集 | 2 次 | PASS |

### §2 低信噪比（R 声道 −10 dBFS(RMS) 噪声）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 13 | R 完成测量（告警≠无效） | valid | PASS |
| 14 | R snrDb < 20 | **−0.7** | PASS |
| 15 | warnings 含 R『环境噪声偏大』 | 「R 环境噪声偏大（SNR −0.7 dB），建议关闭空调冰箱后重测」 | PASS |
| 16 | L 无 SNR 误报 | 无 | PASS |
| 17 | L SNR 不受影响 | 57.0 | PASS |

### §3 削波（R 声道输出 ×1.5，扫频 −9 dBFS）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 18 | warnings 含 R『削波』 | 「R 录音接近削波，请调低话筒/功放增益重测」 | PASS |
| 19 | L 无削波误报 | 无（L 峰值 ≈0.84，预警线下） | PASS |
| 20 | 恰好一条警告（无误报叠加） | 1 条 | PASS |
| 21 | 削波声道仍 valid | valid | PASS |

### §4 2.1 布局 + 超低反接（主 δ@10 ms / 超低 −0.5·δ@22 ms）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 22 | 三声道，LFE 识别为超低 | isSub 正确 | PASS |
| 23 | 三声道全部 valid | 全 valid | PASS |
| 24 | subAlign 延迟 = 12 ±0.5 ms | **576.0 样本 = 12.000 ms** | PASS |
| 25 | warnings 含『相位疑似反接』 | 「超低相位疑似反接，请在功放反转相位或对调接线后重测」 | PASS |
| 26 | subAlign 增益 = +6 ±0.5 dB | **+6.021**（真值 10log10(1/0.25)） | PASS |

### §5 取消（第 1 声道后 cancelled=true）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 27 | aborted = true | true | PASS |
| 28 | channels.size() == 1 | 1 | PASS |
| 29 | 已完成声道仍有效 | valid | PASS |

### §6 校正闭环（build_corrections，target=tilt −1 dB/oct）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 30 | 两声道校正 IR 齐全 | [L,R] ×2 | PASS |
| 31 | fs/taps 如实记录 | 48000 / 8192 | PASS |
| 32 | 声道名一一对应 | [L,R] | PASS |
| 33 | 无超低布局对齐参数为 0 | 0 / 0 | PASS |
| 34 | L 闭环平滑幅度 vs target ≤2 dB | **1.2779 dB @ 4865 Hz** | PASS |
| 35 | R 闭环 vs target ≤2 dB | **1.2776 dB @ 4865 Hz** | PASS |

（与 C1 §3 干净 IR 的 1.278 dB 持平——测量路径引入的噪声底与正则化在 2 dB 判据的
余量内几乎不可见；同宽心理声学平滑验收，理由同 C1 坑 4。）

### §7 WAV 导出

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 36 | 临时目录创建 | 成功 | PASS |
| 37 | 导出无错误 | 空串 | PASS |
| 38-40 | L：≥44 字节 / RIFF·WAVE 头 / dataLen | 32812 字节 / RIFF·WAVE / 32768 = 8192×4 | PASS |
| 41-43 | R：同上 | 32812 / RIFF·WAVE / 32768 | PASS |
| 44 | 临时目录已删除 | 不存在 | PASS |

### §8 半套拒绝

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 45 | 任一声道 valid=false → 空集 | channelNames/correctionIrs 均空 | PASS |

## 4. 实现与测试踩坑（全部有实测证据）

1. **SNR 用均方而不是总能量**：到达前/后两窗长度天然不同（本测试 240~504 vs 4800
   样本），总能量比会把窗长混进 SNR；均方（每样本功率）才只反映"信号窗比噪声窗响
   多少 dB"。
2. **SNR 噪声窗要求直达声 > 5 ms 守卫**：第一版测试房间用 C1 的 3 ms 延迟，被
   5 ms 峰前守卫吃掉整个噪声窗（nn=0）。测试房间改为 10/15.5 ms。真实链路必然满足
   （WASAPI 往返延迟 ≥ 数 ms），但向导若遇到"零延迟直通"配置，会话层按已知局限 1
   处理（不告警）。
3. **−10 dBFS 噪声下 ir_peak_index 会被噪声尖峰俘获**（探针实测）：δ 房间（峰 1.03）
   峰仍正确落在 744；但架式核的直接声峰约 0.2~0.3，与 IR 域噪声最大激发（~4.5σ_IR）
   同量级 → 峰被俘获 → snrDb≈0 → 告警照常触发。**推论（已写进接线说明 §4）：SNR
   告警在场时 peakMs 不可信，主线 UI 应抑制直达声显示、优先提示重测**——这正是告警
   要求重测的物理现实。
4. **削波测试的电平算术**：本房间低频 |H| ≈ +7.4 dB（+4 dB 架 × 梳状同相），默认
   −20 dBFS 扫频永不触顶。取 −9 dBFS ×1.5：L 峰 ≈0.84（预警线下）、R 峰 ≈1.26
   （≥0.999 触发），判据分离且确定性。虚拟传输不做硬限幅——真实链路 |x|≥0.999
   正是 ADC 触顶前的预警区，会话质检就该在这之前命中。
5. **极性维度 C1 拿不到**：sub_alignment 按 |峰| 取极值、不带符号（C1 已知局限 3），
   而本包不许改既有文件 → 会话层独立实现同款 40~120 Hz 带限互相关（`sub_polarity_inverted`）
   补上极性；全零带内容返回 false（不告警）——误报反接比漏报更折腾用户。

## 5. 已知局限（如实标注）

1. **SNR 在直达声 t=0 时不可评**：无到达前窗时返回 300 dB（不告警）。真实 WASAPI
   链路必有端点延迟不会命中；异常配置下会静默通过，代码内已注释。
2. **告警不判无效**：嘈杂/削波环境测出的校正依然可被 build_corrections 接受
   （valid 只看结构失败）。这是设计选择（用户有权利"看看测成什么样"再决定）；
   主线 UI 建议在场告警时提示重测但不硬拦。
3. **极性检测无"相关性太弱"保护**：超低没接好/无输出时带限互相关峰可能落在噪声上，
   极性判断无意义。当前不检测此情形（未解决项，等真实链路有样本再定判据）。
4. **sub_alignment 主参考取第一个非超低声道**：多主声道布局（5.1+）下其他主声道
   与超低的相对延迟未分别对齐（REW 同为单参考工作流）。
5. **自定义布局的超低约定名为 LFE**（与布局预置一致），其他名字按主声道处理。
6. **WAV 导出走窄字符 fopen**：中文路径需主线 widen+_wfopen 包装（接线说明 §6）。

## 6. 未验证项（铁律 4）

1. **真实扬声器测量全链路未验证（明确留白）**：真实房间（混响/噪声底/话筒频响/
   声学反馈）下的播放采集需要主线实现 MeasurementTransport + 用户按铁律 1 授权出声。
   本包全部判据为虚拟房间（与真实链路信号同构：同一参考序列 + 房间响应 + 噪声 +
   增益设置）。
2. **88.2/96 kHz 采样率链路未跑**（算法全部按 fs 参数化，48 kHz 全验证；预期一致）。
3. **多次平均/抗噪策略未做**：低信噪比单次测量的方差未评估（C1 未验证项 2 的延续）。
4. **项目 CMake 门禁未跑**（本包不改 CMakeLists.txt，见 §7）。
5. **aborted 半套结果的 build_corrections 未拒绝**（通道都 valid 时能出校正集）——
   UI 拦截策略归主线（接线说明 §4），会话层不拦。

## 7. CMake 接入建议（文本 diff，由主线合入；本包不改 CMakeLists.txt）

```cmake
# ---------------- 房间测量会话 C2（外部评审会话 C 包：传输接口注入/逐声道质检/超低对齐/校正集导出）----------------
add_executable(test_room_measurement tests/test_room_measurement.cpp)
target_link_libraries(test_room_measurement PRIVATE rtadsp)
add_test(NAME room_measurement COMMAND test_room_measurement)
```

（单目标仅依赖 src 头文件与 C++ 标准库 + std::filesystem，无平台/设备依赖，
可直接进 CI 门禁；c++20/23 均编译通过，项目 CMake 用 23。）

## 8. 触碰文件清单

| 文件 | 操作 |
|---|---|
| `src/dsp/room_measurement.h` | 新建 |
| `tests/test_room_measurement.cpp` | 新建 |
| `docs/WIP-C2.md` | 新建（本文档） |
| `docs/测量接线说明-给主线.md` | 新建 |

未改任何既有文件（含 C1 的 `src/dsp/room_correction.h` 与其测试、`src/audio/*`、
`CMakeLists.txt`）。构建产物在 `build-health/`（gitignored，不入库）。
