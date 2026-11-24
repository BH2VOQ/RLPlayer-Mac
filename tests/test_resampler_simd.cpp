#if defined(RTA_TEST_EARLY_INTRINSICS) && defined(__clang__) && \
    (defined(__aarch64__) || defined(__arm64__))
#  include <arm_neon.h>
#endif
#include "dsp/resampler.h"
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <utility>

using namespace rta::dsp;

static double oracle(const double* k, size_t stride, const double* h, size_t base, int taps) {
    volatile double acc = 0;
    for (int u = 0; u < taps; ++u) {
        volatile double product = k[(size_t)u * stride] * h[base - (size_t)u];
        acc = acc + product;
    }
    return acc;
}

int main() {
    size_t checked = 0, lanes = 0, maxThreads = 0;
#if RTA_RESAMPLER_NEON
    if (resampler_simd_available()) {
        for (int taps : {1, 2, 7, 8, 31, 32, 211}) {
            std::vector<double> k((size_t)taps * 8), h((size_t)taps);
            for (size_t i = 0; i < k.size(); ++i) k[i] = std::cos((double)i * 0.193) * 0.07;
            for (int i = 0; i < taps; ++i) h[(size_t)i] = std::sin((double)i * 0.37) * 0.8;
            for (int special = 0; special < 6; ++special) {
                h[0] = special == 0 ? 0.125 :
                       special == 1 ? -0.0 :
                       special == 2 ? 1e-310 :
                       special == 3 ? std::numeric_limits<double>::infinity() :
                       special == 4 ? -std::numeric_limits<double>::infinity() :
                                      std::bit_cast<double>(uint64_t(0x7ff8000000001234ULL));
                double out[4]{};
                resampler_phase4(k.data() + 1, 8, h.data(), (size_t)(taps - 1), taps, out);
                for (int p = 0; p < 4; ++p) {
                    const double expected = oracle(k.data() + 1 + p, 8, h.data(), (size_t)(taps - 1), taps);
                    if (std::bit_cast<uint64_t>(expected) != std::bit_cast<uint64_t>(out[p])) return 3;
                    ++checked;
                }
            }
        }
    }
#endif

    for (int channels : {1, 2, 6}) {
        for (int factor : {2, 3, 4, 5, 8, 16, 32}) {
            for (int taps : {7, 8, 31, 32}) {
                for (bool cascade : {false, true}) {
                    ResamplerConfig cfg;
                    cfg.channels = channels;
                    cfg.outRate = cfg.inRate * (uint32_t)factor;
                    cfg.minTapsPerInput = taps;
                    cfg.applyTapFloor = false;
                    cfg.twoStage = cascade;
                    cfg.cpuKernel = ResamplerCpuKernel::Scalar;
                    PolyphaseResampler ref(cfg);
                    cfg.cpuKernel = ResamplerCpuKernel::Simd;
                    PolyphaseResampler simd(cfg);

                    for (int chunk : {1, 3, 17, 2, 65, 1, 37, 257}) {
                        std::vector<std::vector<double>> input((size_t)channels, std::vector<double>((size_t)chunk));
                        std::vector<const double*> ip((size_t)channels);
                        const size_t cap = ref.maxOutFrames((size_t)chunk);
                        std::vector<std::vector<double>> a((size_t)channels, std::vector<double>(cap)), b = a;
                        std::vector<double*> ap((size_t)channels), bp((size_t)channels);
                        for (int c = 0; c < channels; ++c) {
                            ip[(size_t)c] = input[(size_t)c].data();
                            ap[(size_t)c] = a[(size_t)c].data();
                            bp[(size_t)c] = b[(size_t)c].data();
                            for (int i = 0; i < chunk; ++i)
                                input[(size_t)c][(size_t)i] = (chunk == 257) ? 0.0 : std::sin((double)(i + (int)checked + 1) * 0.137 + c) * 0.8;
                        }
                        const size_t n = ref.process(ip.data(), (size_t)chunk, ap.data());
                        if (simd.process(ip.data(), (size_t)chunk, bp.data()) != n) std::abort();
                        lanes += simd.cpu_simd_outputs_last_block();
                        if (ref.cpu_simd_outputs_last_block() != 0) return 4;
                        for (int c = 0; c < channels; ++c) {
                            for (size_t i = 0; i < n; ++i) {
                                if (std::bit_cast<uint64_t>(a[(size_t)c][i]) != std::bit_cast<uint64_t>(b[(size_t)c][i])) {
                                    std::fprintf(stderr, "mismatch ch%d L%d T%d cascade%d idx%zu\n", channels, factor, taps, cascade, i);
                                    return 1;
                                }
                                ++checked;
                            }
                        }
                    }
                }
            }
        }
    }

    for (unsigned target : {22050u, 44100u, 48000u, 192000u}) {
        ResamplerConfig cfg;
        cfg.outRate = target;
        cfg.minTapsPerInput = 7;
        cfg.applyTapFloor = false;
        cfg.cpuKernel = ResamplerCpuKernel::Scalar;
        PolyphaseResampler ref(cfg);
        cfg.cpuKernel = ResamplerCpuKernel::Auto;
        PolyphaseResampler simd(cfg);
        double input[17] = {0.5, -0.25, 0.125};
        const double* ip[2] = {input, input};
        std::vector<double> a(ref.maxOutFrames(17)), b = a, x = a, y = a;
        double* ap[2] = {a.data(), x.data()};
        double* bp[2] = {b.data(), y.data()};
        const size_t n = ref.process(ip, 17, ap);
        if (simd.process(ip, 17, bp) != n || (target == cfg.inRate && simd.cpu_simd_outputs_last_block() != 0))
            return 5;
        for (size_t i = 0; i < n; ++i) {
            if (std::bit_cast<uint64_t>(a[i]) != std::bit_cast<uint64_t>(b[i])) return 6;
            ++checked;
        }
        simd.reset();
        if (simd.cpu_simd_outputs_last_block() != 0) return 7;
    }

    // 显式覆写整数倍升频代表场景：96k->192k (L=2)、64k->192k (L=3)、48k->192k (L=4) 与 L=16 多核大块
    for (auto ratio : {std::pair{96000u, 192000u}, {64000u, 192000u}, {48000u, 192000u}, {44100u, 705600u}}) {
        for (int channels : {1, 2, 6}) {
            for (int taps : {210, 211}) {
                ResamplerConfig cfg;
                cfg.inRate = ratio.first;
                cfg.outRate = ratio.second;
                cfg.channels = channels;
                cfg.minTapsPerInput = taps;
                cfg.applyTapFloor = false;
                cfg.cpuKernel = ResamplerCpuKernel::Scalar;
                PolyphaseResampler ref(cfg);
                cfg.cpuKernel = ResamplerCpuKernel::Auto;
                cfg.cpuParallel = false;
                PolyphaseResampler serial(cfg);
                cfg.cpuParallel = true;
                PolyphaseResampler pooled(cfg);

                size_t ratioSimd = 0, ratioThreads = 0;
                for (size_t chunk : {1024u, 2053u, 4096u, 257u}) {
                    std::vector<std::vector<double>> input((size_t)channels, std::vector<double>(chunk));
                    const size_t cap = ref.maxOutFrames(chunk);
                    std::vector<std::vector<double>> a((size_t)channels, std::vector<double>(cap)), b = a, c = a;
                    std::vector<const double*> ip((size_t)channels);
                    std::vector<double*> ap((size_t)channels), bp((size_t)channels), cp((size_t)channels);
                    for (int channel = 0; channel < channels; ++channel) {
                        ip[(size_t)channel] = input[(size_t)channel].data();
                        ap[(size_t)channel] = a[(size_t)channel].data();
                        bp[(size_t)channel] = b[(size_t)channel].data();
                        cp[(size_t)channel] = c[(size_t)channel].data();
                        for (size_t i = 0; i < chunk; ++i)
                            input[(size_t)channel][i] = (chunk == 257) ? 0.0 : std::sin((double)i * 0.127 + channel) * 0.7;
                    }
                    const size_t n = ref.process(ip.data(), chunk, ap.data());
                    if (serial.process(ip.data(), chunk, bp.data()) != n ||
                        pooled.process(ip.data(), chunk, cp.data()) != n)
                        return 8;
                    ratioSimd += pooled.cpu_simd_outputs_last_block();
                    ratioThreads = std::max(ratioThreads, pooled.cpu_parallel_threads_last_block());
                    maxThreads = std::max(maxThreads, pooled.cpu_parallel_threads_last_block());
                    if (serial.cpu_parallel_threads_last_block() > 1 || pooled.cpu_parallel_threads_last_block() > 8)
                        return 9;
                    for (int channel = 0; channel < channels; ++channel) {
                        for (size_t i = 0; i < n; ++i) {
                            const auto expected = std::bit_cast<uint64_t>(a[(size_t)channel][i]);
                            if (expected != std::bit_cast<uint64_t>(b[(size_t)channel][i]) ||
                                expected != std::bit_cast<uint64_t>(c[(size_t)channel][i])) {
                                std::fprintf(stderr, "pool mismatch %u->%u ch%d T%d idx%zu\n",
                                             ratio.first, ratio.second, channels, taps, i);
                                return 10;
                            }
                            checked += 2;
                        }
                    }
                }
                if (resampler_simd_available() && (ratioSimd == 0 || (hardware_threads() > 1 && channels >= 2 && ratioThreads <= 1))) {
                    std::fprintf(stderr, "missing simd/pool on %u->%u ch%d simd=%zu threads=%zu\n",
                                 ratio.first, ratio.second, channels, ratioSimd, ratioThreads);
                    return 11;
                }
            }
        }
    }

    if (resampler_simd_available() && lanes == 0) return 2;
    std::printf("PASS bit comparisons=%zu actual SIMD outputs=%zu neon=%d max_pool_threads=%zu\n",
                checked, lanes, resampler_simd_available() ? 1 : 0, maxThreads);
    return 0;
}
