# WIP-B1a：音频体检两个纯算法分析器（外部评审会话 B 包）

日期：2026-10-25 实现（工作区 `D:\RTA-health`，分支 `audio-health`）
状态：全部断言为本机实测（合成信号、确定性可复现），两个测试 exe 全 PASS（exit 0）。

## 1. 一句话结论

两个纯算法分析器（TT DR / BS.1770-4 LUFS / EBU R128 LRA 动态测量；频谱截止+陡沿+24bit LSB
假无损检测）按公开规范实现并通过全部 20 条合成信号断言：**BS.1770 官方校准点
（997 Hz / −23 dBFS / 立体声）实测 −23.000 LUFS**，且 44.1/48/96/192 kHz 全部守住 ±0.003 LU；
假无损检测对 16k/19k 砖墙判出截止 16.2k/19.2k（置信度 1.000），对缓坡滚降与
「截止可见但边沿缓和」两种老录音形态都正确放过（宁可漏报）。

## 2. 交付物与构建

| 文件 | 说明 |
|---|---|
| `src/analysis/dynamics.h` | measure_dynamics()：TT DR + BS.1770-4 LUFS + LRA + 样本峰值 |
| `src/analysis/fake_lossless.h` | check_lossless()：假无损 suspected/cutoff/confidence/reason + fake24bit |
| `tests/test_dynamics.cpp` | 6 节 13 条断言，全部合成信号 |
| `tests/test_fake_lossless.cpp` | 6 节 12 条断言（含补充用例 4b），全部合成信号 |
| `docs/WIP-B1a.md` | 本文档 |

构建配方（与 A 包同款，已验证；`-std=c++23` 亦编译通过，项目 CMake 用 23）：

```
"C:/Program Files/AMD/ROCm/7.2/bin/clang++.exe" -O2 -std=c++17 -Isrc tests/test_dynamics.cpp -o build-health/test_dynamics.exe
"C:/Program Files/AMD/ROCm/7.2/bin/clang++.exe" -O2 -std=c++17 -Isrc tests/test_fake_lossless.cpp -o build-health/test_fake_lossless.exe
```

## 3. 动态测量（test_dynamics，13 条断言全 PASS）

### 3.1 K 加权系数校验（48 kHz vs ITU-R BS.1770-4 表 1）

实现以规范表 48 kHz 系数为锚点，经「数字→模拟（Tustin 反演）→模拟→数字（Tustin 正演）」
重标定到任意 fs。48 kHz 下 roundtrip 为恒等，实测全频点与规范表响应差：

| 频点 | 20 Hz | 100 Hz | 500 Hz | 997 Hz | 4 kHz | 10 kHz | 20 kHz |
|---|---|---|---|---|---|---|---|
| K 增益 dB | −13.2754 | −1.1335 | +0.0425 | **+0.6910** | +3.9680 | +4.0419 | +4.0431 |

**max|Δ| = 1.76e-10 dB**（判据 <1e-6）。997 Hz 处 +0.6910 dB 与「块响度常数 −0.691 dB」
互为镜像，这正是 −23 dBFS 正弦读出 −23.0 LUFS 的机理。

### 3.2 断言实测值

| # | 信号 | 判据 | 实测 | 结果 |
|---|---|---|---|---|
| 1 | 997 Hz −23 dBFS 立体声 48k | LUFS −23.0 ±0.1（官方校准点） | **−23.000** | PASS |
| 2 | 同上 | LRA ≤ 1.0 | 0.000 LU | PASS |
| 3 | 同上 | DR 3.0 ±0.5 | 3.010 dB | PASS |
| 4 | 1 kHz −12 dBFS 单声道 48k | peakDbfs −12.0 ±0.05 | −12.0000 | PASS |
| 5 | 同上 | DR 3.0 ±0.5 | 3.010 dB | PASS |
| 6 | 20 dB 交替正弦 4 s×6 段 | LRA > 10 | **20.000 LU**（积分 −15.274 LUFS） | PASS |
| 7 | 满幅方波 48k | DR 0 ±0.5 | 0.0000 dB | PASS |
| 8 | 同上 | peak = 0 dBFS | 0.0000 | PASS |
| 9-11 | 997 Hz −23 dBFS @44.1/96/192k | LUFS −23.0 ±0.1 | −22.999 / −23.002 / −23.003 | PASS ×3 |

（参考量：单声道 −12 dBFS 正弦积分响度实测 −15.004 LUFS，与「mono z=A²/2、G=1」口径一致；
满幅方波 LUFS 0.826 —— K 加权对高频谐波的抬升，不作断言仅打印。）

## 4. 假无损检测（test_fake_lossless，12 条断言全 PASS）

砖墙用项目现成 Kaiser 窗函数法 FIR（511 抽头、100 dB），缓坡用 Butterworth 双二阶级联；
信号为 20 s 白噪 @44.1k（12 个 65536 样窗铺满全轨）。

| # | 信号 | 判据 | 实测 | 结果 |
|---|---|---|---|---|
| 1 | 全带白噪 | suspected=false 且 cutoff=0 | cutoff 0.0，conf 0.000 | PASS ×2 |
| 2 | 16 kHz 砖墙 | suspected=true | **cutoff 16193.0 Hz**，conf 1.000，下降 62 dB | PASS |
| 3 | 同上 | cutoff 16000 ±800 | 16193.0（偏差 +193） | PASS |
| 4 | 同上 | confidence ≥ 0.5 | 1.000 | PASS |
| 5 | 19 kHz 砖墙 | suspected=true | cutoff 19195.5 Hz，conf 1.000，下降 63 dB | PASS |
| 6 | 同上 | cutoff 19000 ±800 | 19195.5（偏差 +196） | PASS |
| 7 | −3 dB@18k 二阶 Butterworth 缓坡 | suspected=false | cutoff 21679.9（见 §5 坑 3），≥20.5k 不判假 | PASS |
| 8 | 4 阶 Butterworth ≈30 dB/oct（截止可见） | suspected=false | cutoff 9842.7，**1/6 倍频程仅 5 dB，陡沿门拦下** | PASS |
| 9 | 同上 | cutoff 被检出（9000~16000） | 9842.7 | PASS |
| 10 | 同上 | 拒绝原因 =「下降沿缓和」 | reason 命中，conf 0.000 | PASS |
| 11 | 16-bit 内容 <<8 装 24-bit | fake24bit=true | true（低 8 位恒零占比 100%） | PASS |
| 12 | 同上 + ±1 LSB(24bit) 抖动 | fake24bit=false | false | PASS |

UI 直显 reason 示例（实测输出）：
- 判假：「16.2 kHz 处存在陡峭截止（下降 62 dB），典型的有损源转制特征」
- 放过缓坡：「9.8 kHz 处频谱走低但下降沿缓和（1/6 倍频程约 5 dB），更像老录音自然滚降，不判假」

## 5. 实现踩坑（三处，均有实证）

1. **任务书 K 加权参数写串了**：「一阶高通 f=1681.97 级联高架 f=3819.6」与规范不符 ——
   ITU-R BS.1770-4 表 1 里 1681.97 Hz 属于**高频架**（+4.0 dB）、38.1 Hz 才是 RLB **高通**。
   按任务书字面实现无法过 −23.0 ±0.1 校准点（手算响应差 ~0.2 dB）。本实现按规范表系数做，
   并在 `dynamics.h` 文件头注明与任务书文字的差异。
2. **RBJ 公式不能复现 ITU 系数**：用规范参数（1681.97 Hz / Q0.70718 / +3.9998 dB）直接套
   RBJ high-shelf，48 kHz 系数与规范表差 0.4%~3.7%（b0 1.5294 vs 1.5351），997 Hz 响应差
   ~0.18 dB —— 超出 ±0.1 LUFS 容差。改用「规范系数为锚点的 Tustin 反演/正演重标定」：
   48 kHz 下 roundtrip 恒等（1.76e-10 dB），任意 fs 校准点守住（§3.2 第 9-11 条）。
3. **两处「想当然」被实测打脸**：
   - 测试侧共享 Biquad 实例过滤双声道 —— 状态机按 2 倍速率步进，输出变成抽取后的
     多相混合，高频镜像只降 10 dB，把 21k 以上频谱抬到阈值之上，截止完全检不出
     （4b 首轮 cutoff=0 的真因）。修为每声道独立实例。
   - RBJ 双二阶在奈奎斯特处有双重零点，接近奈奎斯特时斜率远陡于模拟原型：8 阶
     Butterworth@11k 的实测 −40 dB 点斜率 ~170 dB/oct 而非模拟式的 48 dB/oct，原计划的
     「截止可见但中等边沿」场景在 19.5k 附近根本造不出来。改用 4 阶 @3.4k 把 −40 dB 点
     放到 12k 附近（奈奎斯特安全区）才成立。
   - 附带发现：二阶缓坡 @18k 在奈奎斯特附近仍有可检出的陡降（实测 cutoff 21679.9），
     正确落在「≥20.5 kHz 不判假」分支 —— 该门的存在必要性被此用例证实。

## 6. 已知局限（如实标注）

1. **LUFS 多声道权重只实现了立体声 L/R = 1.0**；≥3 声道一律按 G=1.0（BS.1770 的
   Ls/Rs = 1.41 未做），多声道节目的积分响度会偏低 ≤1.5 dB。
2. **DR 的 3 秒块口径**：素材 <3 s 时 DR 无定义（返回 0）；块尾不足 3 s 丢弃；
   「前 20%」按 floor(nBlocks/5)、至少 1 块。TT DR 官方另有 −20 dB 门，任务书口径不含门，
   按任务书实现（无门）。
3. K 加权滤波从 t=0 零状态起算，首块含滤波器建立过程（实测对 10 s 素材影响 <0.01 LU）。
4. 假无损检测混单声道分析、Hann 窗、≤12×65536 窗、截止扫描下限 1 kHz、窗间一致率
   容差 ±1000 Hz、run ≥8 bin —— 这些参数未做敏感性扫描，真实音乐上的表现留 B1b。
5. `srcBits ≥ 24` 才做 LSB 检查；纯数字静音也会触发 fake24bit（低 8 位恒零），
   体检面板展示时可结合峰值旁路。

## 7. 未验证项（铁律 4）

1. **真实音乐文件的行为未验证**：本包全部判据为合成信号（铁律 3 允许范围内自洽），
   真实有损转制样本（MP3/AAC 转 FLAC）与真实老录音的检出率/误报率留 B1b 用文件侧用例验证。
2. **其他采样率的假无损检测未测**（仅 44.1k）；88.2/96k 素材的 bin 宽减半后 run≥8 bin
   的实际含义变化未评估。
3. **项目 CMake 门禁未跑**（本包不改 CMakeLists.txt，见 §8；ctest 接入由主线合入后生效）。

## 8. CMake 接入建议（文本 diff，由主线合入；本包不改 CMakeLists.txt）

仿 WIP-A.md §8，格式对齐既有测试段（`tests/test_host_msg` 等）：

```cmake
# ---------------- 音频体检 B1a（外部评审会话 B 包：动态测量 + 假无损检测）----------------
add_executable(test_dynamics tests/test_dynamics.cpp)
target_link_libraries(test_dynamics PRIVATE rtadsp)
add_test(NAME dynamics COMMAND test_dynamics)

add_executable(test_fake_lossless tests/test_fake_lossless.cpp)
target_link_libraries(test_fake_lossless PRIVATE rtadsp)
add_test(NAME fake_lossless COMMAND test_fake_lossless)
```

（两个目标仅依赖 src 头文件与 C++17 标准库，无平台/设备依赖，可直接进 CI 门禁。）

## 9. 触碰文件清单

| 文件 | 操作 |
|---|---|
| `src/analysis/dynamics.h` | 新建 |
| `src/analysis/fake_lossless.h` | 新建 |
| `tests/test_dynamics.cpp` | 新建 |
| `tests/test_fake_lossless.cpp` | 新建 |
| `docs/WIP-B1a.md` | 新建（本文档） |

未改任何既有文件（含 A 包 `tools/gpu_precision.cpp`、`docs/WIP-A.md`、`src/audio/*`、
`src/dsp/*`、`CMakeLists.txt`）。构建产物在 `build-health/`（不入库）。
