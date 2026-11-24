#if defined(RTA_TEST_EARLY_INTRINSICS) && defined(__clang__) && \
    (defined(__aarch64__) || defined(__arm64__))
#  include <arm_neon.h>
#endif
#include "dsp/resampler.h"
#include <bit>
#include <cstdio>
#include <limits>
#include <utility>

using namespace rta::dsp;

int main() {
    size_t checks = 0, vectorOutputs = 0, maxThreadsSmallL = 0;
    for (auto rates : {std::pair{44100u, 48000u}, {44100u, 192000u}, {48000u, 44100u},
                       {96000u, 44100u}, {192000u, 48000u}, {96000u, 64000u},
                       {48000u, 24000u}, {48000u, 16000u}}) {
        for (int channels : {1, 2, 6}) {
            for (int taps : {7, 32, 211}) {
                ResamplerConfig cfg;
                cfg.inRate = rates.first;
                cfg.outRate = rates.second;
                cfg.channels = channels;
                cfg.minTapsPerInput = taps;
                cfg.applyTapFloor = false;
                cfg.cpuKernel = ResamplerCpuKernel::Scalar;
                PolyphaseResampler scalar(cfg);
                cfg.cpuKernel = ResamplerCpuKernel::Auto;
                cfg.cpuParallel = false;
                PolyphaseResampler serial(cfg);
                cfg.cpuParallel = true;
                PolyphaseResampler pooled(cfg);

                for (int pass = 0; pass < 2; ++pass) {
                    if (pass) { scalar.reset(); serial.reset(); pooled.reset(); }
                    for (size_t frames : {1u, 3u, 17u, 129u, 4096u, 2053u, 257u}) {
                        const size_t cap = scalar.maxOutFrames(frames);
                        std::vector<std::vector<double>> in((size_t)channels, std::vector<double>(frames));
                        std::vector<std::vector<double>> a((size_t)channels, std::vector<double>(cap + 4, 123.0)), b = a, c = a;
                        std::vector<const double*> ip((size_t)channels);
                        std::vector<double*> ap((size_t)channels), bp((size_t)channels), cp((size_t)channels);
                        for (int ch = 0; ch < channels; ++ch) {
                            ip[(size_t)ch] = in[(size_t)ch].data();
                            ap[(size_t)ch] = a[(size_t)ch].data();
                            bp[(size_t)ch] = b[(size_t)ch].data();
                            cp[(size_t)ch] = c[(size_t)ch].data();
                            for (size_t i = 0; i < frames; ++i)
                                in[(size_t)ch][i] = (frames == 257) ? 0.0 : std::sin((double)(i + 1) * 0.113 + ch) * 0.8;
                            if (pass && frames == 4096) {
                                in[(size_t)ch][70] = -0.0;
                                in[(size_t)ch][240] = 1e-310;
                                in[(size_t)ch][4020] = std::numeric_limits<double>::infinity();
                            }
                        }
                        const size_t n = scalar.process(ip.data(), frames, ap.data());
                        if (serial.process(ip.data(), frames, bp.data()) != n ||
                            pooled.process(ip.data(), frames, cp.data()) != n)
                            return 1;
                        vectorOutputs += pooled.cpu_simd_outputs_last_block();
                        if (rates.first == 96000u && rates.second == 64000u && taps == 211 && channels >= 2 && frames == 4096)
                            maxThreadsSmallL = std::max(maxThreadsSmallL, pooled.cpu_parallel_threads_last_block());
                        for (int ch = 0; ch < channels; ++ch) {
                            for (size_t i = 0; i < cap + 4; ++i) {
                                const auto expected = std::bit_cast<uint64_t>(a[(size_t)ch][i]);
                                if (expected != std::bit_cast<uint64_t>(b[(size_t)ch][i]) ||
                                    expected != std::bit_cast<uint64_t>(c[(size_t)ch][i])) {
                                    std::printf("FAIL %u->%u ch%d taps%d frames%zu i%zu\n",
                                                rates.first, rates.second, channels, taps, frames, i);
                                    return 2;
                                }
                                checks += 2;
                            }
                        }
                        if (scalar.cpu_simd_outputs_last_block() != 0 || serial.cpu_parallel_threads_last_block() > 1)
                            return 3;
                    }
                }
            }
        }
    }
    if (resampler_simd_available() && (!vectorOutputs || (hardware_threads() > 1 && maxThreadsSmallL <= 1)))
        return 4;
    std::printf("PASS rational bit checks=%zu vector_outputs=%zu smallL_threads=%zu neon=%d\n",
                checks, vectorOutputs, maxThreadsSmallL, resampler_simd_available() ? 1 : 0);
    return 0;
}
