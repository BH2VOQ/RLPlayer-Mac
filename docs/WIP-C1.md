# WIP-C1：房间校正算法核心（外部评审会话 C 包）

日期：2026-10-25 实现（工作区 `D:\RTA-health`，分支 `audio-health`）
状态：全部断言为本机实测（合成信号、确定性可复现），测试 exe **19 条断言全 PASS**（exit 0），
c++20 / c++23 双标准编译通过。

## 1. 一句话结论

房间校正算法核心按公开方法学（Farina 2000 对数扫频、REW 式正则化反卷积与心理声学平滑、
复倒谱 Hilbert 最小相位）独立实现并通过全部 19 条合成信号断言：扫频回环恢复 δ 的
**峰位 0、±16 样本外旁瓣 −42.1 dB**；已知房间（3 ms 延迟 + 双架 + 梳状）反卷积后
**峰位误差 0 样本、平滑幅度与解析真值差 0.0095 dB**；校正闭环与 tilt(−1 dB/oct) 目标差
**1.28 dB（≤1.5）**、校正器自增益 **+4.83 dB（≤6.5）**；超低对齐恢复 **12.000 ms / +3.0000 dB**。

## 2. 交付物与构建

| 文件 | 说明 |
|---|---|
| `src/dsp/room_correction.h` | generate_sweep / deconvolve_ir / psychoacoustic_smooth / target_curve_db / compute_correction_ir / sub_alignment / room_layouts + 辅助（ir_magnitude_db、minimum_phase_ir、ir_peak_index、next_pow2） |
| `tests/test_room_correction.cpp` | 6 节 19 条断言，全部合成信号、确定性 |
| `docs/WIP-C1.md` | 本文档 |
| `docs/房间校正向导-内容建议.md` | 可选交付：给主线的向导文案/摆位图示建议（纯内容，无代码） |

构建配方（与 A/B 包同款，已验证）：

```
"C:/Program Files/AMD/ROCm/7.2/bin/clang++.exe" -O2 -std=c++20 -Isrc tests/test_room_correction.cpp -o build-health/test_room_correction.exe
"C:/Program Files/AMD/ROCm/7.2/bin/clang++.exe" -O2 -std=c++23 -Isrc tests/test_room_correction.cpp -o build-health/test_room_correction.exe   # 双验证通过
```

方法学引用（公开文献，独立实现、未抄任何开源代码）：
* A. Farina, "Simultaneous measurement of impulse response and distortion with a
  swept-sine technique", AES 108th Convention, 2000（对数扫频 + 反卷积测量）。
* 正则化反卷积 / 变分数倍频程心理声学平滑 / 目标曲线校正工作流：REW 用户手册公开描述
  （方法学同名，非代码）。
* 最小相位：复倒谱同态法（Oppenheim & Schafer 经典方法），
  h_min = IFFT(exp(FFT(ramp · IFFT(ln|H|))))。

## 3. 断言实测值（19/19 PASS）

### §1 扫频回环（roomIr = δ，measured = sweep）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 1 | 峰在 0±2 样本内 | 峰位 0（峰值 0.9474 ≈ 频带占空比 10 Hz~22 kHz / 24 kHz） | PASS |
| 2 | 主瓣 ±16 样本外旁瓣 < −40 dB | **−42.1 dB @ 样本 22** | PASS |

（0.9474 不是误差：反卷积谱在扫频带外为 0，恢复的 δ 是带限 δ，峰值 = 频带占比。）

### §2 已知响应恢复（3 ms 延迟 + 100 Hz +4 dB 一阶架 + 8 kHz −3 dB 架 + 0.5 ms −6 dB 梳状）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 3 | 延迟恢复 3 ms ±1 样本 | 峰位 144，误差 **0** | PASS |
| 4 | 平滑后 100 Hz~10 kHz 与真值差 ≤0.5 dB | **0.0095 dB @ 9005 Hz** | PASS |

（未平滑逐点差 3.50 dB @ 9005 Hz——正是梳状谷被 1/6 oct 平滑填起来的部分，见 §4 坑 1。）

### §3 校正闭环（target = tilt −1 dB/oct）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 5 | 100 Hz~10 kHz 平滑幅度与 target 差 ≤1.5 dB | **1.278 dB @ 6993 Hz**（同宽验收） | PASS |
| 6 | 校正器任意频率增益 ≤ +6.5 dB | **+4.83 dB** | PASS |

（固定 1/6 oct 验收同一点为 3.12 dB——宽窗平滑有意不填人耳听不出来的窄谷，
REW 明确警告不要补谷；这是设计选择不是误差，见 §4 坑 4。）

### §4 超低对齐（主 10 ms / 超低 22 ms、带内 −3 dB）

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 7 | delaySamples = 12 ms ±0.5 ms | **576.0 样本 = 12.000 ms** | PASS |
| 8 | gainDb = 3 dB ±0.5 dB | **+3.0000 dB** | PASS |

符号约定：delaySamples 正 = 超低更晚（超低链路补延迟）；gainDb 正 = 超低偏安静（超低补增益）。

### §5 布局表

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 9 | 6 种布局 | 2.0 / 2.1 / 5.1 / 7.1 / 5.1.2 / 7.1.4 | PASS |
| 10 | 含 2.0 / 5.1.2 / 7.1.4 | 均在 | PASS |
| 11 | 带超低的布局 LFE 分频全 80 Hz | 全 80.0 | PASS |
| 12 | 通道计数与名字非空 | 通过 | PASS |
| 13 | 7.1.4 = 12 通道，顺序 L R C LFE Lss Rss Lrs Rrs Ltf Rtf Ltr Rtr | 逐名一致 | PASS |
| 14 | 5.1.2 = 8 通道 | 8 | PASS |
| 15 | 2.0 = 2 通道无超低 | 2, sub=false | PASS |

### §6 平滑数学

| # | 判据 | 实测 | 结果 |
|---|---|---|---|
| 16 | 白谱平滑后仍平 ±0.05 dB | 0.00e+00 dB | PASS |
| 17 | +10 dB 尖峰经 1/3 oct 平滑后峰高下降 | 10 → 0.0355 dB | PASS |
| 18 | 峰仍定位在尖峰 ±半窗宽内 | 偏 −148 bin（半窗宽 ≈ 165 bin） | PASS |
| 19 | 尖峰 bin 平滑值 ≥ 0.8×全局最大 | 0.0316 / 0.0355 = 0.89 | PASS |

## 4. 实现踩坑（四（+一）处，全部有实测证据）

1. **「平滑后数据 vs 逐点解析真值」不是反卷积的正确判据**（铁律 3 现行犯）：
   梳状谷 −6 dB、间距 2 kHz、谷宽约 ±230 Hz，任何**正确的** 1/6 oct 平滑都会把谷填起来
   （9005 Hz 处逐点差 3.5 dB），这不是反卷积的错，是平滑在履职。反卷积的正确判据是
   「平滑(恢复) vs 平滑(真值)」——同一把尺子才在测反卷积本身（实测 0.0095 dB）。
2. **对称 Kaiser 窗会杀死最小相位 IR**：第一版对截断后的校正 FIR 套 80 dB Kaiser 窗，
   整条频谱掉 40~70 dB、闭环误差 20.3 dB。真因：对称窗峰值在 index taps/2，而最小相位
   IR 的能量全在头部，w[0] = I0(0)/I0(β) ≈ 1e-4，头部被乘掉 80 dB。逐级探针证明
   最小相位本身精确（全长度 |FFT(hMin)| 与输入幅度逐 bin 一致、tail 能量占比 5e-11）。
   修法：最小相位 FIR 只削尾巴（后 25% 升余弦渐出）。
3. **扫频端点淡入淡出是反效果**：想当然认为「渐变端点 → 带边更软 → 振铃更小」，
   实测相反（±16 样本外旁瓣：无渐变 −42.1 dB，5 ms 渐变 −35.1 dB，10 ms −34.6 dB）。
   恢复谱 H = |S|²/(|S|²+ε) 的带边形状由扫频泄漏裙决定，渐变把泄漏收窄成陡沿，
   时域振铃衰减反而变慢。保持纯 Farina 扫频；播放防点击归 C2 接线层（用实际播放的
   同一份序列作参考）。
4. **验收平滑宽度必须等于校正设计平滑宽度**：校正器内部用变宽心理声学平滑
   （1/6→1/3 oct），7 kHz 梳状谷处宽窗看到 6k/8k 的峰，判定谷「不用补多少」；
   用固定 1/6 oct 验收则看到谷的残余（−3.1 dB）。用同宽验收后 1.28 dB 过判据，
   固定 1/6 的 3.12 dB 作为信息项打印（宽窗不填窄谷的设计代价，REW 同款取舍）。
5. **（测试侧）细分辨率下单 bin 冲激的平滑 argmax 不在冲激上**：FFT bin 0.73 Hz 远细于
   1/3 oct 窗（~300 Hz），平滑后 argmax 由窗内 bin 计数决定——窗沿向低频侧更窄、
   计数更小、均值更高，argmax 天然偏向尖峰低频侧约半窗宽（实测偏 −148 bin，
   峰值只差 13%）。「峰位置不变 ±2 bin」是错误判据，改为「argmax ±半窗宽 +
   尖峰 bin 平滑值 ≥ 0.8×全局最大」。

## 5. 已知局限（如实标注）

1. **梳状谷不补**：心理声学平滑的设计结果。需要补谷的用户应改用更窄平滑或手工 PEQ
   （后续 UI 暴露平滑宽度时必须带此警告，避免用户把 +6 dB 打进不可补的鞍谷里烧喇叭）。
2. **校正幅度下限 −60 dB**：复倒谱 ln 域深坑会拖长 IR 尾巴，截断到 taps 时幅度失真
   可达 20 dB（第一版 1e-7 下限的教训，后来被坑 2 的探针一并覆盖）。−60 dB 以下的
   校正在物理上不可信也不必要。
3. **sub_alignment 不判极性**：超低反接（互相关峰为负）时会给出负 delay 附近的错误
   对齐建议；极性检测留 C2（在互相关里同时报告峰的符号即可，一行代码，等 UI 需要）。
4. **fMax 渐出固定 2×fMax 或 0.97·奈奎斯特**、**次声 10~30 Hz 渐入**为实现常量，UI 不暴露。
5. **taps 应 ≤ 反卷积窗 FFT 长度一半**（默认 300 ms 窗 @48 kHz = 16384 点，taps 8192 恰好）；
   更高采样率下 irWindowMs 折算的点数变大，约束自动放松，无越界风险。

## 6. 未验证项（铁律 4）

1. **真实扬声器测量全链路未验证（留 C2）**：本包全部判据为合成信号（铁律 3 允许范围内
   自洽）。真实房间（多斜入射反射、噪声底、喇叭自身频响）下的扫频播放与录音涉及
   **出声**，须用户按铁律 1 授权后进行；采集接口由主线经回调注入，本包不含任何
   src/audio 依赖（红线已守）。
2. **非白噪声环境 / 多次平均**：单次测量在低信噪比下的方差未评估。
3. **88.2/96 kHz 采样率下的完整链路未跑**（算法全部按 fs 参数化，§2/§3 的构造在 48 kHz
   验证；预期行为一致，未实测）。
4. **项目 CMake 门禁未跑**（本包不改 CMakeLists.txt，见 §7；ctest 接入由主线合入后生效）。

## 7. CMake 接入建议（文本 diff，由主线合入；本包不改 CMakeLists.txt）

仿 WIP-A/WIP-B1a §8，格式对齐既有测试段（`tests/test_dynamics` 等 B 包目标亦待合入）：

```cmake
# ---------------- 房间校正 C1（外部评审会话 C 包：Farina 扫频/正则化反卷积/心理声学平滑/最小相位/超低对齐）----------------
add_executable(test_room_correction tests/test_room_correction.cpp)
target_link_libraries(test_room_correction PRIVATE rtadsp)
add_test(NAME room_correction COMMAND test_room_correction)
```

（单目标仅依赖 src 头文件与 C++ 标准库，无平台/设备依赖，可直接进 CI 门禁；
c++20/23 均编译通过，项目 CMake 用 23。）

## 8. 触碰文件清单

| 文件 | 操作 |
|---|---|
| `src/dsp/room_correction.h` | 新建 |
| `tests/test_room_correction.cpp` | 新建 |
| `docs/WIP-C1.md` | 新建（本文档） |
| `docs/房间校正向导-内容建议.md` | 新建（可选交付，纯内容） |

未改任何既有文件（含 B1a/B1b 的 `src/analysis/*`、`docs/WIP-B1*.md`、`src/dsp/*` 既有头、
`src/audio/*`、`CMakeLists.txt`）。构建产物在 `build-health/`（不入库）。
