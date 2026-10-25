# WIP-B1b：体检编排层 + 缓存 + CLI + 主线接线契约（外部评审会话 B 包第二批）

日期：2026-10-26 实现（工作区 `D:\RTA-health`，分支 `audio-health`）
状态：编排层测试 65 条断言全 PASS（exit 0，c++20/c++23 双标准编译）；MUSIC 真实文件 smoke
5/5 全 ready（只读、无缓存）。

## 1. 一句话结论

B1a 两个纯算法分析器已接成文件级体检编排（`analyze_file` 绝不抛异常、错误进 `status/error`）、
三元组键磁盘缓存（`weakly_canonical` 路径 + mtime 毫秒 + size，原子写、损坏文件如实报错拒绝回写）、
只读 CLI（`rtahealth`，默认不落盘），并把主线接线契约写成 `docs/分析器API建议.md`；
真实文件 smoke 首战告捷：**真 24-bit FLAC 被检出「16-bit 内容装 24-bit 容器」（fake24），
两个 MP3 的有损截止 13.1k/15.5k 全部落网**，纯算法两段合计 27 ms（10 s @48k 合成信号）。

## 2. 交付物与构建

| 文件 | 说明 |
|---|---|
| `src/analysis/track_health.h` | analyze_buffer / analyze_file / track_health_json（JSON 字段名=契约逐字一致） |
| `src/analysis/health_store.h` | HealthStore：三元组键缓存，原子写，损坏不静默清空 |
| `tools/rtahealth.cpp` | CLI：文件/目录批量，默认无缓存，--cache 才落盘；wmain 入口（中文路径） |
| `tests/test_track_health.cpp` | 6 节 65 条断言，全合成 + 临时文件 |
| `docs/分析器API建议.md` | **主线接线契约**（函数签名 / 实测量级 / HTTP 契约 / UI 字段建议 / 局限） |
| `docs/WIP-B1b.md` | 本文档 |

构建配方（⚠️ 与任务书的偏差，见 §6.1）：

```
"C:/Program Files/AMD/ROCm/7.2/bin/clang++.exe" -O2 -std=c++20 -Isrc tests/test_track_health.cpp -o build-health/test_track_health.exe
"C:/Program Files/AMD/ROCm/7.2/bin/clang++.exe" -O2 -std=c++20 -Isrc tools/rtahealth.cpp -o build-health/rtahealth.exe
（-std=c++23 两个目标亦编译通过，test 同样全 PASS；项目 CMake 即 C++23）
```

## 3. 断言实测（test_track_health，65 条全 PASS）

| # | 节 | 判据 | 实测 | 结果 |
|---|---|---|---|---|
| 1 | §1 analyze_buffer 997Hz/−23dBFS/48k/10s/16bit | lufs −23.0 ±0.1（B1a 锚点不漂移） | **−23.000** | PASS |
| 2 | 同上 | dr_db 3.0 ±0.5 | 3.011 | PASS |
| 3 | 同上 | peak −23.0 ±0.05 | −22.999 | PASS |
| 4 | 同上 | status=ready、duration/fs/channels/bits、analyzed_at_ms>0 | 全符合 | PASS ×4 |
| 5 | §2 fake24 | 16-bit 值 <<8 装 24-bit → fake24=true | true | PASS |
| 6 | 同上 | <<8 装填不改变 LUFS（±0.1） | −23.000 = −23.000 | PASS |
| 7 | 同上 | 真 24-bit 量化 → fake24=false（对照） | false | PASS |
| 8 | §3 临时 WAV 端到端 | analyze_file vs analyze_buffer ±0.05（lufs/lra/dr/peak） | 差异 0.000 | PASS ×4 |
| 9 | 同上 | 元信息一致（read_wav 回读）、临时文件已删 | 全符合 | PASS ×2 |
| 10 | §4 不存在路径 | 不抛异常、status=error、error 非空、analyzed_at_ms 仍填 | 全符合 | PASS ×4 |
| 11 | §5 HealthStore | 空库构造 → save → 重载 → 同参命中 | 命中 | PASS |
| 12 | 同上 | 中文/引号/斜杠 reason 逐字往返；带 `.` 段等价路径命中 | 一致 | PASS ×2 |
| 13 | 同上 | mtime 或 size 变化 → 未命中；同键覆盖不追加 | 符合 | PASS ×5 |
| 14 | 同上 | 手改坏缓存 → loadError 非空、lookup 不崩、save 拒写、**文件字节原样保留** | 全符合 | PASS ×4 |
| 15 | §6 JSON 契约 | 16 个字段名逐一存在（dr_db…analyzed_at_ms） | 16/16 | PASS |
| 16 | 同上 | 项目 json_parse 回读：数值/布尔/整数/毫秒往返 + 转义 reason 逐字一致 | 全符合 | PASS ×6 |

耗时参考（测试内打印）：analyze_buffer ≈ 28 ms、analyze_file ≈ 29 ms（10 s @48k 立体声）。
三段分解（scratch 基准，未入库）：decode 1.2 / dynamics 15.0 / lossless 12.1 ms。

## 4. 真实文件 smoke 实录（D:\RTA-hqplayer\MUSIC，只读、不带 --cache）

```
> build-health/rtahealth.exe "<5 个真实文件>"
路径 | DR dB | LUFS | LRA LU | Peak dBFS | 截止 | 疑似假无损 | 24bit假 | 状态

D:/RTA-hqplayer/MUSIC/TEST站测评曲/器乐音质（铜管） - 威廉退尔序曲.wav
    DR  14.98 | LUFS  -14.94 | LRA  11.00 | Peak    0.00 | 截止 18.7k   | 疑似假无损 否       | 24bit假 否 | 状态 ready | 分析 193 ms
D:/RTA-hqplayer/MUSIC/蔡琴 - 不了情.flac
    DR  11.83 | LUFS  -20.83 | LRA  16.57 | Peak   -3.64 | 截止 20.1k   | 疑似假无损 是(0.50) | 24bit假 否 | 状态 ready | 分析 2011 ms
D:/RTA-hqplayer/MUSIC/专辑-感动我的&RainLain/2020/林魂胡茬子 - 渊海无畏 (TV Version).mp3
    DR  12.56 | LUFS  -12.56 | LRA   4.74 | Peak   -0.21 | 截止 13.1k   | 疑似假无损 是(0.75) | 24bit假 否 | 状态 ready | 分析 498 ms
D:/RTA-hqplayer/MUSIC/专辑-感动我的&RainLain/2021/咻咻满 - 赤伶 (交响乐版).mp3
    DR   9.44 | LUFS   -9.51 | LRA  11.08 | Peak    0.00 | 截止 15.5k   | 疑似假无损 是(1.00) | 24bit假 否 | 状态 ready | 分析 989 ms
D:/RTA-hqplayer/MUSIC/专辑-原创&同人/相对无害 @ Mugai无害P/8 I Use Numbers feat. 南蛮大尘.flac
    DR  10.56 | LUFS   -8.39 | LRA   1.30 | Peak   -0.00 | 截止 21.2k   | 疑似假无损 否       | 24bit假 是 | 状态 ready | 分析 268 ms

共 5 个文件：分析 5（缓存命中 0），错误 0；平均分析 791.9 ms/文件，总耗时 3.96 s
```

判读（B1a 未验证项的第一手真实数据）：

1. **fake24 首例真实抓获**：「8 I Use Numbers」FLAC 容器声明 24-bit，全曲低 8 位恒零 →
   `24bit假 是`——16-bit 内容装 24-bit 容器，与 B1a 合成用例同判据，真实文件复现。
2. **两个 MP3 截止 13.1k/15.5k 全部落网**（置信度 0.75/1.00）——但语义是「有损音源」而非
   「假无损」（见 §6.3 的接线注意）；cutoff 数值与 MP3 典型低通特征一致，方向正确。
3. **蔡琴 - 不了情（老录音）置信度恰为 0.50**（cutoff 20.1k）：恰在判假门限上，可能是老母带
   温和滚降、也可能是上一代有损转制残留——**未做人工频谱核对，不下结论**（铁律 3/4）。
   这正是「低置信度徽标降权」UI 建议的实证。
4. 威廉退尔（16-bit 测试碟 WAV）DR 14.98 / LRA 11.0，体检数字与素材定位相符；无截止误报。
5. 耗时：WAV 193 ms（原生解码）≪ FLAC 268~2011 ms（ffmpeg 转码占大头）；MP3 0.5~1 s。
   平均 792 ms/文件 ⟹ 后台 job 必须串行队列 + 缓存（契约文档 §3.2 已按此写）。

## 5. 实现踩坑（四处，均有实证）

1. **缓存 mtime 的 double 精度坑（设计期抓住）**：JSON number 走 double（53 位尾数），
   MSVC `file_clock` 原生 100ns count ≈1.3e17 > 2^53，直接存会导致重载后 mtime 失真、
   缓存永不命中。键统一用「自时钟纪元的毫秒数」（≈1.3e13，double 精确表示），
   测试 §5 以 int64 往返逐字命中验证。
2. **CLI --json 拼接括号 bug（实测暴露并已修）**：把 `track_health_json`（完整对象）的 `{`
   去掉拼接后，又手写了一个收尾 `}` 且漏了分隔逗号——首轮输出 `"analysis_ms":16.2"dr_db":…}}`。
   修复后用 python `json.loads` 逐行验证全文件合法（JSONL_VALID）。
3. **既有 `src/audio/dsd_reader.h` 需要 C++20**（`char8_t`/`std::u8string`，dsd_reader.h:114）：
   任务书要求的 c++17 配方对本包不成立——B1a 只含 dsp 头从未触及；`analyze_file` 必须经
   `audio_loader.h` ⟹ 只能 C++20 起。按"不改既有文件"铁律，以 c++20 为下限、c++23（项目
   CMake 标准）双验证，如实记录此偏差。
4. **B1a 纯音误报边界被 bench 复现**：纯 double 正弦（无量化噪声）被 check_lossless 判
   「1.2 kHz 陡峭截止（下降 32 dB）」——[1k..5k] 参考段几乎全空时，参考−40 dB 门变得极低，
   纯音以上整带皆"阈下"。B1a 的「扫到底不报」护栏只覆盖纯音 <1 kHz 的情形，1~2 kHz 纯音
   仍会落网。16-bit 量化噪声（实测测试路径）可自然压住，真实音乐（宽带）未观察到。
   **B1a 文件只读未改**，已写入契约文档局限 §5.4 供主线知悉。

## 6. 未验证项 / 接线注意（铁律 4）

1. **构建标准偏差**：未按任务书验证 c++17（见 §5.3，既有文件依赖 C++20，不可在本包内修）；
   c++20 / c++23 双通过。
2. **蔡琴 0.50 边界个案**未人工核对频谱，检出/误报结论不下；**真实检出率/误报率未标定**
   （样本 5 个，方向性参考）。
3. **有损容器的「疑似假无损」语义**：MP3 被标 `lossless_suspected=true` 是「有损音源」事实，
   但「假无损」文案只对无损容器成立——TrackHealth 有意不带 codec（接口最小），**主线必须
   用自家媒体信息区分文案**（契约文档 §4.3）。
4. **大 DSD 未 smoke**：MUSIC 里的 271 MB DSF64 按 read_any 会整曲解码（实测历史峰值
   ~1.8 GB、~5 s），本轮为省内存未跑；体检侧流式解码未接（播放侧已有）。
5. **88.2/96k+ 真实高采样率文件的假无损判据未测**（B1a 遗留，bin 宽变化未评估）。
6. 项目 CMake 门禁未跑（本包不改 CMakeLists.txt，见 §8；ctest 接入由主线合入后生效）。

## 7. 触碰文件清单

| 文件 | 操作 |
|---|---|
| `src/analysis/track_health.h` | 新建 |
| `src/analysis/health_store.h` | 新建 |
| `tools/rtahealth.cpp` | 新建 |
| `tests/test_track_health.cpp` | 新建 |
| `docs/分析器API建议.md` | 新建 |
| `docs/WIP-B1b.md` | 新建（本文档） |

未改任何既有文件（含 B1a 的 `dynamics.h` / `fake_lossless.h` / 两个测试、`src/audio/*`、
`CMakeLists.txt`）。`D:\RTA-hqplayer\MUSIC\` 只读未写。构建产物与 scratch 基准
（`bench_b1b.cpp`）在 `build-health/`（不入库）。

## 8. CMake 接入建议（文本 diff，由主线合入；本包不改 CMakeLists.txt）

仿 WIP-B1a §8，格式对齐既有工具/测试段：

```cmake
# ---------------- 音频体检 B1b（体检编排 + 缓存 + CLI）----------------
add_executable(rtahealth tools/rtahealth.cpp)
target_link_libraries(rtahealth PRIVATE rtadsp)

add_executable(test_track_health tests/test_track_health.cpp)
target_link_libraries(test_track_health PRIVATE rtadsp)
add_test(NAME track_health COMMAND test_track_health)
```

（两个目标仅依赖 src 头文件与 C++20+ 标准库——含 `audio_loader.h` 故受 dsd_reader.h 的
C++20 约束，项目 CMake 已是 C++23；无平台外依赖、不开音频设备，可直接进 CI 门禁。）
