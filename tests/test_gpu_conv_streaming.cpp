// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_gpu_conv_streaming.cpp — GPU 卷积「逐块调用丢失 IR 拖尾」的正确性门禁
//
// ============================================================================
// 被测 BUG（2026-10-26 实测取证的生产正确性缺陷）
// ============================================================================
// 现象：δ 放在样点 0、IR=65536、按 4096 样逐块调用，16 块里【只有第 0 块有输出】，
//       其余 15 块全零。65410/65536 个样点与真值不符，相对 RMS −1.63 dB（等效 0.3 bit）。
//       ⟹ irLen > 块长时每块只保留 IR 的前 块长/irLen，后 (1−块长/irLen) 被丢弃。
// 根因：rta_gpu_convolve（src/gpu/gpu_metal.mm:419-531）是【无状态整块卷积】，
//       每次调用从零状态算 conv(本块, ir)；而管线按块调用它，且每块的 w 都是新的
//       ⟹「上一块输入 × 本块 IR 的尾巴」这一项没有任何地方被计算。
// 对照：CPU 路径用持久 dsp::StreamingConvolver（ss_.conv[c]），跨块保状态，所以正确。
//
// 修法（src/engine/pipeline.h 的 GpuConvStream）：overlap-save。
//   拼接 [上一块末尾 irLen−1 样 | 本块 w] 后喂无状态卷积，只取输出末尾 w.size() 个样点。
//   ⟹ 因果卷积正确，且【算法延迟仍为 0】（不是"攒够 irLen 再算"，那会引入 irLen 帧延迟）。
//
// ============================================================================
// 判据说明（铁律 3：这个指标真的能证明我要证明的事吗？）
// ============================================================================
// [1] 核心红→绿：δ@0 / IR=65536 / 16×4096。判据是 out[i]==ir[i]（i<65536），
//     不是"有输出就行"：全零输出对全零输入也满足任何误差判据，所以另外断言
//     【每一块】都必须有非零输出（红基线正是"块 1..15 全零"）。
// [2] 对照 CPU 生产路径：与 StreamingConvolver 逐样点比，按它的 convBlock 延迟对齐。
//     额外自证：参考信号必须有能量（den>0），否则"都全零所以相等"会假绿 —— 显式拒绝。
// [3] IR 换掉后历史必须清：先用 IR_A 跑几块，再换 IR_B，输出必须等于「从零用 IR_B 跑」。
//     含两个子例：长度不同、长度相同但内容不同（抽样指纹那条路）。
// [4] 边界：irLen = 1 / 2 / 512(<block) / 1024(==block) / 2048(==2*block)。
// [5] 多声道：2 声道不同 IR，且 ch1 输入为纯静音 ⟹ ch1 输出必须恒零。
//     这一条才真正证明历史是【每声道一份】：若共用一份，ch0 的尾巴会漏进 ch1。
// [6] GPU 不可用时不回归：vendor=off 后 useGpu=true 必须退回 CPU，输出与 useGpu=false 一致。
//
// ---- 电平标定（为什么有 fit_level 这个东西）----
// Pipeline 的输出缓冲【恒为整数格式】（pipeline.h:282 `out.isFloat = false`），
// setSample 对整数格式会钳位到 [−1, 1−2^-(bits-1)]（audio/wav.h:53-59）。
// 房间校正样 IR（65536 抽头、峰值归一到 1）的直流增益可达 ~28 倍 ⟹ 0.7 峰值的音乐样
// 输入会撞上钳位，测到的就是削波失真而不是卷积精度（红基线实测 max|Δ|=29.8、峰值 28.8）。
// 所以凡是"输入 × 长 IR"的用例，先把输入压到「预期输出峰值 ≈ 0.25」再进管线，
// 参考侧按同一线性因子缩放 —— 线性系统，缩放不改变任何正确性判据。
//
// 铁律 1：本测试全程离线，不打开任何音频设备、不播放任何声音。
#include "engine/pipeline.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace rta::engine;
namespace dsp = rta::dsp;

static int g_fail = 0;
static int g_pass = 0;
static int g_skip = 0;

static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) { std::printf("  [PASS] %s%s%s\n", what.c_str(), detail.empty() ? "" : "  ", detail.c_str()); ++g_pass; }
    else      { std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); ++g_fail; }
}
static void skip(const std::string& what, const std::string& why) {
    std::printf("  [SKIP] %s  （%s）\n", what.c_str(), why.c_str()); ++g_skip;
}

// 相对 RMS（dB）：sqrt(Σe²/Σr²)。den==0 ⟹ 返回 +1e30（拒绝把退化参考当"误差为 0"）
static double rel_rms_db(double se, double sr) {
    if (sr <= 0.0) return 1e30;
    const double rel = std::sqrt(se / sr);
    return (rel <= 0.0) ? -1000.0 : 20.0 * std::log10(rel);
}

static double peak_abs(const std::vector<double>& v) {
    double m = 0.0;
    for (double x : v) m = std::max(m, std::fabs(x));
    return m;
}

// 房间校正样 IR：指数衰减 × 一阶平滑噪声（与 tools/gpu_precision.cpp 同形态）
static std::vector<double> room_like_ir(size_t n, uint32_t seed = 1) {
    std::vector<double> h(n);
    uint32_t s = seed * 2654435761u + 12345u;
    auto rnd = [&s] { s = s * 1664525u + 1013904223u; return (double)(s >> 8) / 8388608.0 - 1.0; };
    double prev = 0.0, pk = 0.0;
    for (size_t i = 0; i < n; ++i) {
        prev = 0.72 * prev + 0.28 * rnd();
        h[i] = prev * std::exp(-6.5 * (double)i / (double)n);
        pk = std::max(pk, std::fabs(h[i]));
    }
    for (auto& v : h) v /= (pk > 0 ? pk : 1.0);
    return h;
}

// 音乐样输入（多正弦 + 噪声，峰值归一到 0.7）
static std::vector<double> music_like(size_t n, double f0 = 997.0, uint32_t seed = 7) {
    std::vector<double> x(n);
    uint32_t s = seed * 2654435761u + 99991u;
    auto rnd = [&s] { s = s * 1664525u + 1013904223u; return (double)(s >> 8) / 8388608.0 - 1.0; };
    double pk = 0.0;
    for (size_t i = 0; i < n; ++i) {
        const double v = 0.32 * std::sin(2 * M_PI * f0 * (double)i / 48000.0)
                       + 0.21 * std::sin(2 * M_PI * (f0 * 1.237) * (double)i / 48000.0)
                       + 0.13 * std::sin(2 * M_PI * (f0 * 3.151) * (double)i / 48000.0)
                       + 0.25 * rnd();
        x[i] = v;
        pk = std::max(pk, std::fabs(v));
    }
    for (auto& v : x) v *= 0.7 / (pk > 0 ? pk : 1.0);
    return x;
}

// 按块喂真实 Pipeline（生产形态：每块一次 process()）
static std::vector<std::vector<double>> run_pipeline(const PipelineConfig& cfg,
                                                    const std::vector<std::vector<double>>& x,
                                                    uint32_t rate, int bits, size_t blk,
                                                    PipelineStats* stOut = nullptr) {
    const int nch = (int)x.size();
    const size_t total = x.empty() ? 0 : x[0].size();
    std::vector<std::vector<double>> out((size_t)nch);
    Pipeline pl(cfg);
    PipelineStats last;
    for (size_t off = 0; off < total; off += blk) {
        const size_t n = std::min(blk, total - off);
        AudioBuffer b;
        b.rate = rate; b.channels = nch; b.bits = bits; b.isFloat = false;
        b.raw.assign(n * (size_t)nch, 0);
        for (size_t i = 0; i < n; ++i)
            for (int c = 0; c < nch; ++c) b.setSample(i, c, x[(size_t)c][off + i]);
        AudioBuffer o = pl.process(b, &last);
        for (size_t i = 0; i < o.frames(); ++i)
            for (int c = 0; c < nch; ++c) out[(size_t)c].push_back(o.sample(i, c));
    }
    if (stOut) *stOut = last;
    return out;
}

static PipelineConfig make_cfg(const std::vector<std::vector<double>>& irs, bool useGpu) {
    PipelineConfig cfg;
    cfg.convBlock = 1024;                     // 生产默认（pipeline.h:77）
    cfg.channel.resize(irs.size());
    for (size_t c = 0; c < irs.size(); ++c) {
        cfg.channel[c].ir = irs[c];
        cfg.channel[c].useGpu = useGpu;
    }
    return cfg;
}

// 把输入整体缩放到「与 ir 卷积后峰值 ≈ targetPeak」，避免撞上整数输出的钳位。
static void fit_level(std::vector<double>& x, const std::vector<double>& ir, double targetPeak) {
    dsp::StreamingConvolver sc(ir, 1024);
    std::vector<double> probe(x.size(), 0.0);
    sc.process(x.data(), probe.data(), x.size());
    const double pk = peak_abs(probe);
    const double g = (pk > 1e-12) ? (targetPeak / pk) : 1.0;
    for (auto& v : x) v *= g;
}

int main() {
    std::printf("== GPU 卷积逐块流式正确性（IR 拖尾不许丢）==\n");
    auto& gb = dsp::GpuBridge::instance();
    std::printf("GPU 后端：%s\n", gb.status().c_str());
    const bool gpuOk = gb.available();
    if (!gpuOk) {
        std::printf("\n⚠️ GPU 不可用 ⟹ 判据 [1][2][3][4][5] 的 GPU 分支无法执行。\n");
        std::printf("   这不是通过：下面只跑 [6] 的 CPU 回退判据，并明确 SKIP 其余各条。\n\n");
    }

    const uint32_t kRate = 48000;
    const int kBits = 32;          // 32-bit 容器：量化地板 −186 dB，远低于 GPU float32 误差
    const double kGate = -120.0;   // 卷积精度门（docs/WIP-F6-GPU精度.md §7 的 mac 建议值）

    // =======================================================================
    // [1] 核心红→绿：δ@0 / IR=65536 / 16 块 × 4096 样
    // =======================================================================
    std::printf("\n[1] 核心判据：δ 在样点 0，IR=65536，16 块 × 4096 样\n");
    std::printf("    红基线（修前实测）：逐块最大 |out| = 1e+00 0e+00 … 0e+00（只第 0 块有输出）\n");
    std::printf("                       65410/65536 样点不符，相对 RMS −1.63 dB\n");
    {
        const size_t B = 4096, nCh = 16, n = B * nCh, irLen = 65536;
        std::vector<double> ir(irLen);
        for (size_t i = 0; i < irLen; ++i) ir[i] = std::exp(-3.0 * (double)i / (double)irLen);
        std::vector<double> x(n, 0.0);
        x[0] = 1.0;

        if (!gpuOk) {
            skip("GPU 卷积逐块不丢 IR 拖尾", "GPU 不可用");
        } else {
            PipelineStats st;
            auto out = run_pipeline(make_cfg({ir}, true), {x}, kRate, kBits, B, &st);
            const std::vector<double>& y = out[0];

            std::printf("     逐块最大 |out|：");
            size_t zeroBlocks = 0;
            for (size_t c = 0; c < nCh; ++c) {
                double m = 0.0;
                for (size_t i = c * B; i < std::min((c + 1) * B, y.size()); ++i)
                    m = std::max(m, std::fabs(y[i]));
                std::printf("%s%.0e", c == 0 ? "" : " ", m);
                if (m <= 0.0) ++zeroBlocks;
            }
            std::printf("\n");

            // "不符"必须用【相对】口径：GPU 内部是 float32（24 bit 有效位），
            // 绝对阈值 1e-9 会把每个样点都算成不符（那是精度地板，不是拖尾丢失）。
            // 1e-5 相对峰值：只有"拖尾真丢了"（误差 ~1e-1 量级）才会被计入。
            long long bad = 0;
            double se = 0.0, sr = 0.0, maxAbs = 0.0;
            const double badTol = 1e-5;
            for (size_t i = 0; i < n && i < y.size(); ++i) {
                const double d = y[i] - ir[i];
                se += d * d; sr += ir[i] * ir[i];
                maxAbs = std::max(maxAbs, std::fabs(d));
                if (std::fabs(d) > badTol) ++bad;
            }
            const double db = rel_rms_db(se, sr);
            std::printf("     与真值不符的样点数 = %lld / %zu（相对阈值 1e-5）\n", bad, std::min(n, y.size()));
            std::printf("     相对 RMS 误差 = %.2f dB（等效 %.1f bit），最大绝对误差 = %.3e\n",
                        db, -db / 6.0206, maxAbs);

            char buf[320];
            std::snprintf(buf, sizeof(buf), "(全零块 %zu / %zu，走了 GPU=%s)",
                          zeroBlocks, nCh, st.usedGpuConvolution ? "是" : "否");
            ck(st.usedGpuConvolution, "本用例真的走了 GPU 路径（否则这条判据测的不是 GPU）", buf);
            ck(zeroBlocks == 0, "【每一块】都有非零输出（红基线正是块 1..15 全零）", buf);
            std::snprintf(buf, sizeof(buf), "(不符 %lld / %zu，相对 RMS %.2f dB，max|Δ| %.3e)",
                          bad, std::min(n, y.size()), db, maxAbs);
            ck(db <= kGate, "out[i] == ir[i]（相对 RMS ≤ −120 dB）", buf);
        }
    }

    // =======================================================================
    // [2] 对照 CPU 生产路径（StreamingConvolver，按 convBlock 延迟对齐）
    // =======================================================================
    std::printf("\n[2] 对照 CPU 路径：GPU 逐块 vs 持久 StreamingConvolver 逐样点\n");
    std::printf("    门 = %.0f dB（docs/WIP-F6-GPU精度.md 实测量级 −126.5 ~ −148.4 dB）\n", kGate);
    {
        const size_t B = 4096, nBlk = 8, n = B * nBlk, irLen = 65536;
        const std::vector<double> ir = room_like_ir(irLen, 3);
        std::vector<double> x = music_like(n, 997.0, 11);
        fit_level(x, ir, 0.25);        // 压到不撞整数输出钳位（见文件头「电平标定」）

        // CPU 参考：生产用的持久流式卷积器（整段喂入；它自身是分块不变的）
        std::vector<double> cpuRef(n, 0.0);
        {
            dsp::StreamingConvolver sc(ir, 1024);
            sc.process(x.data(), cpuRef.data(), n);
        }
        const double refPeak = peak_abs(cpuRef);
        // 自证参考非退化（铁律 3：全零参考会让"都全零所以相等"假绿）
        ck(refPeak > 0.05 && refPeak < 0.5, "CPU 参考有能量且未撞钳位（拒绝假绿与削波）",
           std::string("(峰值 ") + std::to_string(refPeak) + ")");

        if (!gpuOk) {
            skip("GPU 与 CPU 生产路径逐样点一致", "GPU 不可用");
        } else {
            PipelineStats st;
            auto out = run_pipeline(make_cfg({ir}, true), {x}, kRate, kBits, B, &st);
            const std::vector<double>& y = out[0];
            // StreamingConvolver 预置 B(=convBlock=1024) 帧延迟 ⟹ cpuRef[m] = 真值[m−1024]
            // ⟹ 零延迟的 GPU 输出 y[m] 应与 cpuRef[m + 1024] 比
            const size_t lat = 1024;
            double se = 0.0, sr = 0.0, maxAbs = 0.0;
            size_t cnt = 0;
            for (size_t m = 0; m + lat < n; ++m) {
                const double d = y[m] - cpuRef[m + lat];
                se += d * d; sr += cpuRef[m + lat] * cpuRef[m + lat];
                maxAbs = std::max(maxAbs, std::fabs(d));
                ++cnt;
            }
            const double db = rel_rms_db(se, sr);
            std::printf("     比较样点 %zu，相对 RMS %.2f dB，最大绝对误差 %.3e\n", cnt, db, maxAbs);
            char buf[240];
            std::snprintf(buf, sizeof(buf), "(相对 RMS %.2f dB, max|Δ| %.3e)", db, maxAbs);
            ck(st.usedGpuConvolution, "本用例走了 GPU 路径");
            ck(db <= kGate, "GPU 逐块与 CPU 生产路径一致（相对 RMS ≤ −120 dB）", buf);
        }
    }

    // =======================================================================
    // [3] IR 换掉后历史必须清
    // =======================================================================
    std::printf("\n[3] IR 换掉后 GPU 历史必须清空（不许残留旧 IR 的输入尾巴）\n");
    if (!gpuOk) {
        skip("换 IR 后历史清空", "GPU 不可用");
    } else {
        const size_t B = 2048, nBlk = 6;
        const std::vector<double> irA = room_like_ir(8192, 21);
        const std::vector<double> irB = room_like_ir(8192, 22);   // 同长度、不同内容
        const std::vector<double> irC = room_like_ir(3000, 23);   // 不同长度

        // 逐块喂 GpuConvStream（直接测流式包装，能精确构造"换 IR"的形态）
        auto run_stream = [&](GpuConvStream& g, const std::vector<double>& ir,
                              const std::vector<double>& x) {
            std::vector<double> out;
            std::vector<double> w;
            for (size_t off = 0; off < x.size(); off += B) {
                const size_t n = std::min(B, x.size() - off);
                w.assign(x.begin() + (std::ptrdiff_t)off, x.begin() + (std::ptrdiff_t)(off + n));
                if (!g.process(gb, w, ir, 1024)) std::printf("     ⚠️ GPU 调用失败\n");
                out.insert(out.end(), w.begin(), w.end());
            }
            return out;
        };

        std::vector<double> xA = music_like(B * nBlk, 1201.0, 31);
        std::vector<double> xB = music_like(B * nBlk, 733.0, 32);
        fit_level(xA, irA, 0.25);
        fit_level(xB, irB, 0.25);

        for (int which = 0; which < 2; ++which) {
            const std::vector<double>& irNew = (which == 0) ? irB : irC;
            const char* tag = (which == 0) ? "同长度换 IR（抽样指纹）" : "不同长度换 IR（长度判据）";

            // 污染：先用 IR_A 跑几块，把历史填满 A 的内容
            GpuConvStream g;
            (void)run_stream(g, irA, xA);
            // 再换 IR 直接 process（不手动 reset —— 这正是"换 IR"的真实形态）
            const std::vector<double> got = run_stream(g, irNew, xB);
            // 真值：全新实例只用 irNew 从零跑
            GpuConvStream gFresh;
            const std::vector<double> want = run_stream(gFresh, irNew, xB);

            double se = 0.0, sr = 0.0, maxAbs = 0.0;
            for (size_t i = 0; i < want.size(); ++i) {
                const double d = got[i] - want[i];
                se += d * d; sr += want[i] * want[i];
                maxAbs = std::max(maxAbs, std::fabs(d));
            }
            const double db = rel_rms_db(se, sr);
            char buf[280];
            std::snprintf(buf, sizeof(buf), "(%s: 相对 RMS %.2f dB, max|Δ| %.3e, 峰值 %.3f)",
                          tag, db, maxAbs, peak_abs(want));
            ck(peak_abs(want) > 1e-3 && db <= kGate,
               std::string("换 IR 后输出等于「从零状态用新 IR 跑」— ") + tag, buf);
        }
    }

    // =======================================================================
    // [4] 边界：irLen = 1 / 2 / 512(<block) / 1024(==block) / 2048(==2*block)
    // =======================================================================
    std::printf("\n[4] 边界：irLen = 1 / 2 / 512(<block) / 1024(==block) / 2048(==2*block)\n");
    if (!gpuOk) {
        skip("irLen 边界", "GPU 不可用");
    } else {
        const size_t B = 1024;
        const size_t total = B * 6;
        for (size_t irLen : { (size_t)1, (size_t)2, (size_t)512, (size_t)1024, (size_t)2048 }) {
            std::vector<double> ir(irLen);
            for (size_t i = 0; i < irLen; ++i) ir[i] = std::exp(-3.0 * (double)i / (double)irLen);
            std::vector<double> x(total, 0.0);
            x[0] = 1.0;                       // δ：out[i] 必须 == ir[i]（i<irLen），其余 0
            PipelineStats st;
            auto out = run_pipeline(make_cfg({ir}, true), {x}, kRate, kBits, B, &st);
            const std::vector<double>& y = out[0];

            double se = 0.0, sr = 0.0, maxAbs = 0.0;
            for (size_t i = 0; i < total; ++i) {
                const double want = (i < irLen) ? ir[i] : 0.0;
                const double d = y[i] - want;
                se += d * d; sr += want * want;
                maxAbs = std::max(maxAbs, std::fabs(d));
            }
            const double db = rel_rms_db(se, sr);
            char buf[260];
            std::snprintf(buf, sizeof(buf), "(irLen=%zu, 相对 RMS %.2f dB, max|Δ| %.3e, GPU=%s)",
                          irLen, db, maxAbs, st.usedGpuConvolution ? "是" : "否");
            ck(db <= kGate, std::string("irLen=") + std::to_string(irLen) + " 结果等于 ir（δ 卷积定义）", buf);
        }
    }

    // =======================================================================
    // [5] 多声道：2 声道不同 IR，ch1 纯静音 ⟹ 输出必须恒零（历史按声道隔离）
    // =======================================================================
    std::printf("\n[5] 多声道：2 声道不同 IR；ch0=正弦、ch1=纯静音 ⟹ ch1 输出必须恒零\n");
    std::printf("     （若历史是全局共用一份，ch0 的输入尾巴会漏进 ch1 ⟹ ch1 出现非零）\n");
    {
        const size_t B = 4096, n = B * 5;
        const std::vector<double> ir0 = room_like_ir(16384, 41);
        const std::vector<double> ir1 = room_like_ir(16384, 42);
        std::vector<double> x0 = music_like(n, 440.0, 51);
        fit_level(x0, ir0, 0.25);
        std::vector<double> x1(n, 0.0);                       // 纯静音
        if (!gpuOk) {
            skip("多声道历史隔离", "GPU 不可用");
        } else {
            PipelineStats st;
            auto out = run_pipeline(make_cfg({ir0, ir1}, true), {x0, x1}, kRate, kBits, B, &st);
            const double leak = peak_abs(out[1]);
            char buf[240];
            std::snprintf(buf, sizeof(buf), "(ch1 峰值 %.3e，GPU=%s)", leak,
                          st.usedGpuConvolution ? "是" : "否");
            ck(leak <= 1e-12, "静音声道的输出恒为零（历史没有跨声道串味）", buf);

            // ch0 正确性：对照 CPU 生产路径
            std::vector<double> cpuRef(n, 0.0);
            { dsp::StreamingConvolver sc(ir0, 1024); sc.process(x0.data(), cpuRef.data(), n); }
            const size_t lat = 1024;
            double se = 0.0, sr = 0.0;
            size_t cnt = 0;
            for (size_t m = 0; m + lat < n; ++m) {
                const double d = out[0][m] - cpuRef[m + lat];
                se += d * d; sr += cpuRef[m + lat] * cpuRef[m + lat];
                ++cnt;
            }
            const double db = rel_rms_db(se, sr);
            std::snprintf(buf, sizeof(buf), "(相对 RMS %.2f dB, 峰值 %.3f)", db, peak_abs(cpuRef));
            ck(db <= kGate, "ch0 用它自己的 IR 得到正确结果", buf);

            // ---- 5b 更强的一条：两声道用【同一个 IR】，ch1 仍纯静音 ----
            // 为什么必须补这条：上面用不同 IR 时，"换 IR 清历史"的指纹检查会顺带把共用
            // 状态冲掉 ⟹ 即使历史是全局共用一份，ch1 也恰好是零（假绿）。
            // 同 IR + 静音 ch1 时没有任何东西能"洗掉"串味：若共用一份，ch0 的输入尾巴
            // 会被卷进 ch1 的输出 ⟹ ch1 必然出现非零。这才是"每声道独立"的真判据。
            {
                std::vector<double> x0b = music_like(n, 440.0, 51);
                fit_level(x0b, ir0, 0.25);
                std::vector<double> x1b(n, 0.0);
                PipelineStats st2;
                auto out2 = run_pipeline(make_cfg({ir0, ir0}, true), {x0b, x1b},
                                        kRate, kBits, B, &st2);
                const double leak2 = peak_abs(out2[1]);
                std::snprintf(buf, sizeof(buf), "(同 IR，ch1 峰值 %.3e)", leak2);
                ck(leak2 <= 1e-12,
                   "5b 同 IR 下静音声道仍恒为零（排除指纹检查掩盖串味的假绿）", buf);
            }
        }
    }

    // =======================================================================
    // [6] GPU 不可用时不回归：useGpu=true 必须退回 CPU，且与 useGpu=false 逐样点一致
    // =======================================================================
    std::printf("\n[6] GPU 不可用时退回 CPU 路径（不许回归）\n");
    {
        const size_t B = 2048, n = B * 6;
        const std::vector<double> ir = room_like_ir(8192, 61);
        std::vector<double> x = music_like(n, 555.0, 62);
        fit_level(x, ir, 0.25);

        // 强制 GPU 不可用
        const std::string savedVendor = dsp::gpu_vendor();
        dsp::set_gpu_vendor("off");
        gb.reload();
        ck(!gb.available(), "vendor=off 后 GpuBridge 报不可用（前置条件成立）",
           std::string("(") + gb.status() + ")");

        PipelineStats stG, stC;
        auto yGpuCfg = run_pipeline(make_cfg({ir}, true), {x}, kRate, kBits, B, &stG);
        auto yCpuCfg = run_pipeline(make_cfg({ir}, false), {x}, kRate, kBits, B, &stC);

        double se = 0.0, sr = 0.0, maxAbs = 0.0;
        for (size_t i = 0; i < n; ++i) {
            const double d = yGpuCfg[0][i] - yCpuCfg[0][i];
            se += d * d; sr += yCpuCfg[0][i] * yCpuCfg[0][i];
            maxAbs = std::max(maxAbs, std::fabs(d));
        }
        char buf[300];
        std::snprintf(buf, sizeof(buf), "(useGpu=true 实际走 GPU=%s；逐样点 max|Δ| = %.3e，峰值 %.3f)",
                      stG.usedGpuConvolution ? "是" : "否", maxAbs, peak_abs(yCpuCfg[0]));
        ck(!stG.usedGpuConvolution, "useGpu=true 但 GPU 不可用 ⟹ usedGpuConvolution=false（如实回落）", buf);
        ck(peak_abs(yCpuCfg[0]) > 0.05 && maxAbs == 0.0,
           "回落 CPU 后输出与 useGpu=false 逐样点相同（行为不变）", buf);

        // 还原 vendor 设置，避免影响后续/其它测试
        dsp::set_gpu_vendor(savedVendor);
        gb.reload();
        std::printf("     （已还原 vendor=%s，GPU 可用=%s）\n",
                    savedVendor.c_str(), gb.available() ? "是" : "否");
    }

    // =======================================================================
    // 汇总
    // =======================================================================
    std::printf("\n== 汇总：%d PASS / %d FAIL / %d SKIP ==\n", g_pass, g_fail, g_skip);
    if (g_skip > 0) std::printf("⚠️ 有 %d 条 SKIP —— 这是「未验证」，不是「通过」（铁律 4）\n", g_skip);
    return g_fail == 0 ? 0 : 1;
}
