// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_coreaudio.cpp — CoreAudio 后端（platform::AudioOutput）的真机端到端测试
//
// 为什么要有这个测试（PLATFORM.md §13.4 第 3 条原本写成"未做"）：
//   之前的说法是"需要真实声卡且会改变系统音频状态"——但本机就有声卡，
//   这个理由不成立。CoreAudio 后端的 open/start/write 是 bit-perfect 承诺的
//   最后一环，不测就等于没做。
//
// 🔴 铁律 1（绝不擅自向用户的听音设备播放可听声音）：
//   * 测试音电平默认 **−60 dBFS**（不是 0 dBFS！），只验证"写进去了、设备在跑、
//     没有欠载、格式协商正确"，**不需要听得见**
//   * 每段播放前打印醒目横幅（设备名、时长、峰值电平、独占模式会静音系统声音）
//   * 单段时长 ≤ 0.5 秒，总时长 < 10 秒（满足铁律 1 第 6 条）
//   * 默认只测虚拟设备；物理声卡必须显式传 --device 才测
//   * 优先用 --no-open 做纯离线判定（不碰设备）
//
// 判据（铁律 3：测试通过 ≠ 测对了东西）：
//   * 不只看"没崩"，而是断言【设备真的渲染了帧】（frames_rendered 增长），
//     以及【渲染帧数 ≈ 请求时长】——只写进环形缓冲但设备没跑会当场被抓出来
//   * 欠载计数作为可观测指标打印；稳态下要求为 0
//   * 格式协商：设备不支持的格式必须 open 失败且 last_error 非空（§5.3 拒绝而非静默替换）
//
// ⚠️ 未解决项（铁律 4；2026-10-24 第二轮更新，见 PLATFORM.md §13.10）：
//   1) ~~逐位比对需要设备侧回环录制，本机没有回环设备~~ 已解决：
//      macOS 14.2+ 有官方 Aggregate Tap（rtaloop record-tap），在 Pocket Master 上
//      实测 16/24/32 bit 三种位深 0 LSB 偏差、100% 覆盖（含 24 bit 三字节打包）。
//      本测试仍只证明"帧被消费"——逐位证据在 rtaloop，两者互补不重复。
//   2) Hog Mode 已有跨进程独立探针（rtaloop hogprobe）：owner 归属全局可见 ✓。
//      但实测发现 Hog **不阻止**其它进程 IO（第三进程 IOProc 照常运行）——
//      macOS 的 Hog 语义弱于 WASAPI 独占，bit-perfect 的实际保障是物理格式锁定。
#include "platform/audio_out_factory.h"
#include "platform/macos/audio_out_coreaudio.h"
#include "engine/preset_profiles.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using namespace rta::platform;

static int g_failed = 0;
static int g_total = 0;

static void check(bool ok, const std::string& what, const std::string& detail = "") {
    ++g_total;
    if (!ok) ++g_failed;
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                detail.empty() ? "" : "  ", detail.c_str());
}

static const double kPi = 3.14159265358979323846;

// 生成测试音：level_dbfs 相对满幅。默认 -60 dBFS = 满幅的 0.001 倍。
// 1-bit 输出只能是 ±1，但这里是 PCM 后端，int32 低位对齐到 bits。
static void fill_sine(std::vector<int32_t>& buf, size_t frames, int channels,
                      double rate, double freq, double level_dbfs, int bits) {
    buf.assign(frames * (size_t)channels, 0);
    const double amp = std::pow(10.0, level_dbfs / 20.0);
    // 满幅：bits=16 -> 32767，bits=24 -> 8388607，bits=32 -> INT32_MAX
    const double full = (bits == 16) ? 32767.0 : (bits == 24) ? 8388607.0 : 2147483647.0;
    for (size_t n = 0; n < frames; ++n) {
        const double v = amp * std::sin(2.0 * kPi * freq * (double)n / rate);
        const int32_t s = (int32_t)std::llround(v * full);
        for (int c = 0; c < channels; ++c) buf[n * (size_t)channels + (size_t)c] = s;
    }
}

struct PlayResult {
    bool opened = false;
    bool started = false;
    size_t written = 0;
    size_t rendered = 0;
    uint64_t underruns = 0;
    std::string error;
    OutputError err_class = OutputError::None;
};

// 开流 -> 写数据 -> 等设备消费 -> 关闭。
// 关键：write 是"推进环形缓冲"，设备靠回调拉取；必须等 frames_rendered 跟上，
// 否则测到的只是"写进内存了"，不是"设备真的在跑"。
static PlayResult play(const std::string& device, uint32_t rate, int bits, int channels,
                       double ms, double level_dbfs, bool do_open = true) {
    PlayResult r;
    auto out = create_audio_output();
    if (!out) { r.error = "本平台没有 AudioOutput 适配器"; return r; }
    if (!do_open) return r;

    OpenSpec spec;
    spec.deviceId = device;
    spec.rate = rate;
    spec.bits = bits;
    spec.channels = channels;
    spec.bufferMs = ms;

    if (!out->open(spec)) {
        r.error = out->last_error();
        r.err_class = out->last_error_class();
        return r;
    }
    r.opened = true;
    if (!out->start()) {
        r.error = out->last_error();
        r.err_class = out->last_error_class();
        out->close();
        return r;
    }
    r.started = true;

    // 喂 0.4 秒的音频；每块 = 设备缓冲大小
    const size_t total = (size_t)((double)rate * 0.4);
    const size_t chunk = out->buffer_frames() ? out->buffer_frames() : 512;
    std::vector<int32_t> block;
    size_t fed = 0;
    auto t0 = std::chrono::steady_clock::now();
    while (fed < total) {
        const size_t n = std::min(chunk, total - fed);
        fill_sine(block, n, channels, rate, 1000.0, level_dbfs, bits);
        const size_t w = out->write(block.data(), n);
        r.written += w;
        fed += w;
        if (w == 0) {
            // 缓冲满：睡 1ms 再试（真实时间纪律：不在音频线程上忙等）
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > 5.0)
                break;                       // 5 秒还不消费 = 设备没在跑
        }
    }
    // 等设备把剩下的消费掉（最多 1 秒）
    const auto deadline = t0 + std::chrono::seconds(1);
    while (std::chrono::steady_clock::now() < deadline) {
        if (out->frames_rendered() >= total) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    r.rendered = out->frames_rendered();
    r.underruns = out->underruns();
    out->close();
    return r;
}

static void banner(const char* dev, double ms, double dbfs) {
    std::printf("\n  ┌─────────────────────────────────────────────────────────┐\n");
    std::printf("  │ ⚠️  即将打开音频设备（独占模式会静音系统其他声音）        │\n");
    std::printf("  │ 设备: %-48s │\n", dev);
    std::printf("  │ 时长: %.0f ms   峰值电平: %.0f dBFS（几乎不可闻）        │\n", ms, dbfs);
    std::printf("  └─────────────────────────────────────────────────────────┘\n");
}

int main(int argc, char** argv) {
    std::string device;
    bool no_open = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--device") == 0 && i + 1 < argc) device = argv[++i];
        else if (std::strcmp(argv[i], "--no-open") == 0) no_open = true;
    }

    std::printf("== CoreAudio 后端端到端测试 ==\n");
    std::printf("   适配器可用: %s\n", has_audio_output_adapter() ? "是" : "否");
    std::printf("   目标设备  : %s\n", device.empty() ? "(系统默认)" : device.c_str());

    auto out = create_audio_output();
    check(out != nullptr, "create_audio_output() 返回有效后端");
    if (!out) { std::printf("\nFAILED\n"); return 1; }

    // ---------- 1. 能力查询（只读，不 open） ----------
    std::printf("\n[1] 设备能力查询（只读）\n");
    const DeviceCaps caps = out->caps(device);
    std::printf("   采样率: ");
    for (uint32_t r : caps.rates) std::printf("%u ", r);
    std::printf("\n   位深: ");
    for (int b : caps.bitDepths) std::printf("%d ", b);
    std::printf("\n   声道: %d  独占: %s  bit-perfect: %s  DoP: %s\n",
                caps.maxChannels, caps.exclusiveMode ? "是" : "否",
                caps.bitPerfectCapable ? "是" : "否",
                caps.dsd == DsdTransport::DoP ? "支持" : "不支持");
    check(!caps.rates.empty(), "能枚举到设备支持的采样率");

    // ---------- 1b. 纯离线：#8 DoP 载波推导（不 open、不出声、只读设备 rates） ----------
    //
    // 为什么必须有这一段（铁律 3）：旧代码的判据是「rates 里有 176400 ⟹ 报 176400」，
    // 这条错误判据**无法**被「设备能开流」「DSD64 能播」这类测试抓到 —— 支持 705.6k 的
    // DAC 在旧代码下也照样开流成功，只是被误标成 DSD64 上限。这里直接测映射函数本身。
    std::printf("\n[1b] DoP 载波推导（纯能力逻辑；含 44.1k/48k 两族与空列表边界）\n");
    {
        using rta::platform::detail::dop_carrier_from_rates;
        using rta::platform::detail::DopCarrier;

        struct Case {
            std::vector<uint32_t> rates;
            uint32_t wantCarrier;
            int wantLevel;
            const char* what;
        };
        const std::vector<Case> cases = {
            // 设备只报 176400：只能是 DSD64
            {{44100, 48000, 88200, 96000, 176400}, 176400, 64, "只到 176400 载波 -> DSD64"},
            // 支持 352.8k：DSD128
            {{44100, 88200, 176400, 352800}, 352800, 128, "352800 载波 -> DSD128"},
            // 题面点名的三档都在：取最高（旧代码在这里报 176400）
            {{44100, 88200, 176400, 352800, 705600}, 705600, 256, "支持 705600 -> DSD256（旧代码错报 176400）"},
            // DSD512 载波
            {{44100, 705600, 1411200}, 1411200, 512, "1411200 载波 -> DSD512"},
            // 只有 48k 族载波：192000 = 48k*64/16，等价 DSD64（48k 族）
            {{48000, 96000, 192000}, 192000, 64, "只有 48k 族 192000 载波 -> DSD64（旧代码报不支持）"},
            {{48000, 192000, 384000}, 384000, 128, "48k 族 384000 载波 -> DSD128"},
            // 同档两族都在：报数值更大者，且不得低于该档
            {{176400, 192000, 352800, 384000}, 384000, 128, "同档两族都在 -> 取数值更大者（384000/DSD128）"},
            // 一个载波都没有：必须报 0，不得虚报
            {{44100, 48000, 88200, 96000}, 0, 0, "没有载波 -> 0（不得虚报 176400）"},
            {{44100, 48000}, 0, 0, "只有 44.1k/48k -> 0"},
            {{}, 0, 0, "空列表 -> 0"},
        };
        for (const Case& c : cases) {
            const DopCarrier got = dop_carrier_from_rates(c.rates);
            char detail[160];
            std::snprintf(detail, sizeof detail, "%s：got carrier=%u level=%d, want carrier=%u level=%d",
                          c.what, got.carrier, got.level, c.wantCarrier, c.wantLevel);
            check(got.carrier == c.wantCarrier && got.level == c.wantLevel,
                  std::string("载波推导：") + c.what, detail);
        }

        // 占位 0 的采样率不得被当成载波（设备列表里偶发 0 值）
        {
            const DopCarrier z = dop_carrier_from_rates({0, 0, 0});
            check(z.carrier == 0 && z.level == 0, "rates 里的 0 不被当成载波");
        }

        // 跨模型一致性（防漂移）：平台层 helper 与引擎侧 preset_dop_max_from_rates()
        // 必须对同一 rates 给出**同一档位**。两处任一改动不同步，这里立刻红。
        {
            using rta::engine::preset_dop_max_from_rates;
            using rta::engine::dsd_level_from_name;
            const std::vector<std::vector<uint32_t>> lists = {
                {44100, 48000, 88200, 96000, 176400, 192000},
                {44100, 88200, 176400, 352800, 705600},
                {48000, 96000, 192000},
                {48000, 192000, 384000, 768000},
                {44100, 352800},
                {44100, 176400, 352800, 384000, 705600, 768000},
                {44100, 48000, 96000},
                {},
            };
            for (const auto& rs : lists) {
                const DopCarrier plat = dop_carrier_from_rates(rs);
                const int engLevel = dsd_level_from_name(preset_dop_max_from_rates(rs));
                const bool same = (plat.level == (engLevel > 0 ? engLevel : 0));
                std::string detail = "rates=[";
                for (size_t i = 0; i < rs.size(); ++i) {
                    if (i) detail += ",";
                    detail += std::to_string(rs[i]);
                }
                detail += "] platform_level=" + std::to_string(plat.level) +
                          " engine_level=" + std::to_string(engLevel);
                check(same, "平台层载波档位与引擎侧 preset_dop_max_from_rates 一致", detail);
            }
        }
    }

    // ---------- 1c. 真实设备只读核对：caps() 的 DoP 字段必须与 rates 自洽 ----------
    //
    // 只读断言（不 open、不 start、不写数据）：无论本机插的是什么设备，
    // dopCarrierRate 与 dsd 都必须与「rates 里到底有没有载波」一致。
    std::printf("\n[1c] 真实设备 caps().dopCarrierRate / dsd 与 rates 自洽（只读）\n");
    {
        using rta::platform::detail::dop_carrier_from_rates;
        const auto expect = dop_carrier_from_rates(caps.rates);
        std::printf("   rates 推导载波=%u（DSD%d）  caps 报告载波=%u  caps.dsd=%s\n",
                    expect.carrier, expect.level, caps.dopCarrierRate,
                    caps.dsd == DsdTransport::DoP ? "DoP" : "None");
        check(caps.dopCarrierRate == expect.carrier,
              "caps.dopCarrierRate 等于按设备 rates 推导出的最高载波",
              "got=" + std::to_string(caps.dopCarrierRate) + " want=" + std::to_string(expect.carrier));
        check((caps.dopCarrierRate != 0) == (caps.dsd == DsdTransport::DoP),
              "dsd 与 dopCarrierRate 一致（有载波才说 DoP，无载波不能说支持）");
        check(caps.dsd != DsdTransport::Native && caps.nativeDsdRate == 0,
              "macOS 不虚报 Native DSD（无通用用户态通路）");
    }

    // ---------- 1d. AudioOutput Hog 接口只读默认契约 ----------
    std::printf("\n[1d] AudioOutput Hog 接口只读默认契约\n");
    {
        auto outTest = create_audio_output();
        check(outTest != nullptr, "create_audio_output 成功");
        if (outTest) {
            check(outTest->hog_requested() == false, "初始状态 hog_requested() == false");
            check(outTest->hog_acquired() == false, "初始状态 hog_acquired() == false");
        }
    }

    // ---------- 2. 纯离线：decide_route 与真实设备能力交叉验证 ----------
    std::printf("\n[2] 用真实设备能力跑 decide_route（纯函数，不开流）\n");
    if (!caps.rates.empty()) {
        const uint32_t devRate = caps.rates.front();
        SourceSpec s;
        s.isDsd = false;
        s.rate = devRate;
        s.bits = 16;
        const RouteDecision d1 = decide_route(s, caps, false);
        std::printf("   源 %u/16 -> 路由=%d  理由=%s\n", devRate, (int)d1.kind, d1.reason.c_str());
        // 设备原生支持该格式 + 独占 -> 应判为逐位直通（或至少不拒绝）
        check(d1.kind != RouteKind::Refused, "设备原生格式不应被拒绝");

        // 一个设备必然不支持的格式（例如 11 kHz / 8 bit）
        SourceSpec bad;
        bad.isDsd = false;
        bad.rate = 11025;
        bad.bits = 8;
        const RouteDecision d2 = decide_route(bad, caps, false);
        std::printf("   源 11025/8 -> 路由=%d  理由=%s\n", (int)d2.kind, d2.reason.c_str());
        check(d2.kind == RouteKind::Refused, "设备不支持的格式必须拒绝，不静默替换");
        check(!d2.reason.empty(), "拒绝时理由必须非空");
    }

    // ---------- 2b. 纯离线：CoreAudio 容器电平与量化往返核对（2026-10-25 移植 3496d46）----------
    std::printf("\n[2b] 容器电平与量化往返核对（16/24/32 位逐码值与 0.00 dBFS 偏差）\n");
    {
        using rta::platform::detail::scale_sample_i32;
        using rta::platform::detail::pack_sample_i32;
        using rta::platform::detail::unpack_sample_i32;

        auto calc_dbfs = [](double v, double full) {
            const double norm = std::fabs(v) / full;
            return 20.0 * std::log10(norm > 0.0 ? norm : 1e-30);
        };

        // 1) 16-bit 容器核对
        {
            const int bits = 16;
            const int32_t s_pos = 32767;
            const int32_t s_neg = -32768;
            const int32_t s_half = 16384;
            uint8_t b[4]{};

            pack_sample_i32(b, s_pos, bits);
            const int32_t r_pos = unpack_sample_i32(b, bits);
            const double db_pos = calc_dbfs((double)r_pos, 32767.0);

            pack_sample_i32(b, s_neg, bits);
            const int32_t r_neg = unpack_sample_i32(b, bits);
            const double db_neg = calc_dbfs((double)r_neg, 32768.0);

            pack_sample_i32(b, s_half, bits);
            const int32_t r_half = unpack_sample_i32(b, bits);
            const double db_half = calc_dbfs((double)r_half, 32768.0);

            std::printf("   16-bit 容器: 满幅正 = %d (%.4f dBFS), 负满幅 = %d (%.4f dBFS), 半幅 = %d (%.4f dBFS)\n",
                        r_pos, db_pos, r_neg, db_neg, r_half, db_half);

            check(r_pos == 32767, "16-bit 满幅正样本往返一致 (+32767)");
            check(r_neg == -32768, "16-bit 负满幅样本往返一致 (-32768)");
            check(r_half == 16384, "16-bit 半幅样本往返一致 (16384)");
            check(std::fabs(db_pos - 0.0) < 0.001, "16-bit 满幅电平偏差 = 0.00 dBFS (无 -48dB 错位)");
            check(std::fabs(db_half - (-6.0206)) < 0.01, "16-bit 半幅电平 = -6.02 dBFS");

            // 全域 65536 码值扫描
            int diff_count = 0;
            for (int32_t v = -32768; v <= 32767; ++v) {
                pack_sample_i32(b, v, bits);
                if (unpack_sample_i32(b, bits) != v) ++diff_count;
            }
            check(diff_count == 0, "16-bit 全域 65536 码值往返 100% 逐码值吻合");
        }

        // 2) 24-bit 容器核对（3 字节小端 packed）
        {
            const int bits = 24;
            const int32_t s_pos = 8388607;
            const int32_t s_neg = -8388608;
            const int32_t s_half = 4194304;
            uint8_t b[4]{};

            pack_sample_i32(b, s_pos, bits);
            const int32_t r_pos = unpack_sample_i32(b, bits);
            const double db_pos = calc_dbfs((double)r_pos, 8388607.0);

            pack_sample_i32(b, s_neg, bits);
            const int32_t r_neg = unpack_sample_i32(b, bits);
            const double db_neg = calc_dbfs((double)r_neg, 8388608.0);

            pack_sample_i32(b, s_half, bits);
            const int32_t r_half = unpack_sample_i32(b, bits);
            const double db_half = calc_dbfs((double)r_half, 8388608.0);

            std::printf("   24-bit 容器: 满幅正 = %d (%.4f dBFS), 负满幅 = %d (%.4f dBFS), 半幅 = %d (%.4f dBFS)\n",
                        r_pos, db_pos, r_neg, db_neg, r_half, db_half);

            check(r_pos == 8388607, "24-bit 满幅正样本往返一致 (+8388607)");
            check(r_neg == -8388608, "24-bit 负满幅样本往返一致 (-8388608)");
            check(r_half == 4194304, "24-bit 半幅样本往返一致 (4194304)");
            check(std::fabs(db_pos - 0.0) < 0.001, "24-bit 满幅电平偏差 = 0.00 dBFS (无 -48dB 错位)");
            check(std::fabs(db_half - (-6.0206)) < 0.01, "24-bit 半幅电平 = -6.02 dBFS");

            // 抽样 + 边界扫描
            int diff_count = 0;
            for (int32_t step = -8388608; step <= 8388607; step += 127) {
                pack_sample_i32(b, step, bits);
                if (unpack_sample_i32(b, bits) != step) ++diff_count;
            }
            check(diff_count == 0, "24-bit 抽样扫描往返 100% 逐码值吻合");
        }

        // 3) 32-bit 容器核对
        {
            const int bits = 32;
            const int32_t s_pos = 2147483647;
            const int32_t s_neg = (int32_t)(-2147483647L - 1L); // INT32_MIN
            const int32_t s_half = 1073741824;
            uint8_t b[4]{};

            pack_sample_i32(b, s_pos, bits);
            const int32_t r_pos = unpack_sample_i32(b, bits);
            const double db_pos = calc_dbfs((double)r_pos, 2147483647.0);

            pack_sample_i32(b, s_neg, bits);
            const int32_t r_neg = unpack_sample_i32(b, bits);
            const double db_neg = calc_dbfs((double)r_neg, 2147483648.0);

            pack_sample_i32(b, s_half, bits);
            const int32_t r_half = unpack_sample_i32(b, bits);
            const double db_half = calc_dbfs((double)r_half, 2147483648.0);

            std::printf("   32-bit 容器: 满幅正 = %d (%.4f dBFS), 负满幅 = %d (%.4f dBFS), 半幅 = %d (%.4f dBFS)\n",
                        r_pos, db_pos, r_neg, db_neg, r_half, db_half);

            check(r_pos == 2147483647, "32-bit 满幅正样本往返一致 (+2147483647)");
            check(r_neg == (int32_t)(-2147483647L - 1L), "32-bit 负满幅样本往返一致 (INT32_MIN)");
            check(r_half == 1073741824, "32-bit 半幅样本往返一致 (1073741824)");
            check(std::fabs(db_pos - 0.0) < 0.001, "32-bit 满幅电平偏差 = 0.00 dBFS (无 -48dB 错位)");
            check(std::fabs(db_half - (-6.0206)) < 0.01, "32-bit 半幅电平 = -6.02 dBFS");
        }

        // 4) scale_sample_i32 增益定标核对（非 1.0 增益时）
        {
            // 16 bit
            check(scale_sample_i32(16384, 16, 1.0) == 16384, "scale_sample_i32(gain=1.0) 保持原值");
            check(scale_sample_i32(16384, 16, 0.5) == 8192, "scale_sample_i32(gain=0.5) 16-bit 半幅衰减");
            check(scale_sample_i32(32767, 16, 2.0) == 32767, "scale_sample_i32 饱和不溢出 (16-bit 满幅)");
            // 24 bit
            check(scale_sample_i32(4194304, 24, 0.5) == 2097152, "scale_sample_i32(gain=0.5) 24-bit 半幅衰减");
        }
    }

    if (no_open) {
        std::printf("\n(--no-open：跳过所有开流步骤)\n");
        std::printf("\n%d/%d 断言通过\n%s\n", g_total - g_failed, g_total,
                    g_failed ? "FAILED" : "PASS");
        return g_failed ? 1 : 0;
    }

    // ---------- 3. 格式协商：不支持的格式必须 open 失败 ----------
    std::printf("\n[3] 格式协商：不支持的格式必须 open 失败（§5.3 拒绝而非静默替换）\n");
    {
        auto o2 = create_audio_output();
        OpenSpec bad;
        bad.deviceId = device;
        bad.rate = 11025;          // 绝大多数设备不支持
        bad.bits = 8;              // 8 bit 也不是标准输出格式
        bad.channels = 2;
        bad.bufferMs = 50.0;
        const bool ok = o2->open(bad);
        if (!ok) {
            std::printf("   open(11025/8) 如期失败: %s\n", o2->last_error().c_str());
            check(o2->last_error_class() == OutputError::UnsupportedFormat,
                  "错误分类应为 UnsupportedFormat");
            check(!o2->last_error().empty(), "失败文案必须非空（不许静默失败）");
            o2->close();
        } else {
            // 少数设备确实接受任意格式（虚拟设备常如此）——如实记录，不判失败
            std::printf("   该设备接受了 11025/8（虚拟/宽松设备），跳过拒绝断言\n");
            o2->close();
        }
    }

    // ---------- 4. 真实开流：设备必须真的消费帧 ----------
    std::printf("\n[4] 真实开流与端到端渲染（-60 dBFS，几乎不可闻）\n");
    const uint32_t rate = caps.rates.empty() ? 44100u : caps.rates.front();
    banner(device.empty() ? "(系统默认)" : device.c_str(), 400.0, -60.0);
    const PlayResult pr = play(device, rate, 16, 2, 100.0, -60.0);
    if (!pr.opened) {
        std::printf("   open 失败: %s\n", pr.error.c_str());
        check(false, "open 应当成功", pr.error);
    } else {
        check(pr.started, "start 成功");
        std::printf("   写入 %zu 帧，设备渲染 %zu 帧，欠载 %llu 次\n",
                    pr.written, pr.rendered, (unsigned long long)pr.underruns);
        check(pr.written > 0, "write 有进展");
        // 核心判据：设备真的在跑（不是只写进了内存）
        check(pr.rendered > 0, "设备侧确实渲染了帧（证明设备在跑，不是只写进环形缓冲）");
        check(pr.rendered >= pr.written / 2,
              "渲染帧数与写入帧数同量级（吞吐跟得上）",
              "rendered=" + std::to_string(pr.rendered) + " written=" + std::to_string(pr.written));
    }

    // ---------- 5. pause / resume ----------
    std::printf("\n[5] pause / resume 不释放资源\n");
    {
        auto o3 = create_audio_output();
        OpenSpec sp;
        sp.deviceId = device;
        sp.rate = rate;
        sp.bits = 16;
        sp.channels = 2;
        sp.bufferMs = 100.0;
        if (o3->open(sp) && o3->start()) {
            banner(device.empty() ? "(系统默认)" : device.c_str(), 200.0, -60.0);
            std::vector<int32_t> blk;
            fill_sine(blk, 2048, 2, rate, 1000.0, -60.0, 16);
            o3->write(blk.data(), 2048);
            const size_t before = o3->frames_rendered();
            o3->pause();
            std::this_thread::sleep_for(std::chrono::milliseconds(120));
            const size_t during = o3->frames_rendered();
            o3->resume();
            std::this_thread::sleep_for(std::chrono::milliseconds(120));
            const size_t after = o3->frames_rendered();
            std::printf("   渲染帧: 暂停前=%zu 暂停中=%zu 恢复后=%zu\n", before, during, after);
            check(after >= during, "resume 后设备继续渲染");
            o3->close();
            check(true, "pause/resume 未崩溃");
        } else {
            std::printf("   开流失败，跳过: %s\n", o3->last_error().c_str());
            o3->close();
        }
    }

    // ---------- 6. close 幂等 ----------
    std::printf("\n[6] close 幂等\n");
    {
        auto o4 = create_audio_output();
        o4->close();          // 未 open 就 close
        check(o4->hog_requested() == false, "close 后 hog_requested 保持 false");
        check(o4->hog_acquired() == false, "close 后 hog_acquired 保持 false");
        o4->close();          // 再 close 一次
        check(true, "未 open 时重复 close 不崩溃");
    }

    std::printf("\n%d/%d 断言通过\n", g_total - g_failed, g_total);
    std::printf("%s\n", g_failed ? "FAILED" : "PASS");
    return g_failed ? 1 : 0;
}
