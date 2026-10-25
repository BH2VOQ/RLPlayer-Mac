// measure_big_dsd_playback.cpp -- attribution harness for "big DSD file playback stalls"
//
// What it measures (same code paths as rtaweb's /api/play producer):
//   phase 1  read_any()                whole-file decode (DSD native -> PCM int32)
//   phase 2  ISP scan over full planes whole-file inter-sample-peak scan (2 ch x 8 B x frames)
//   phase 3  Pipeline 4096-frame chunks resampler design + per-block DSP, time to first block
// It prints working set / peak working set after every phase and writes one MEM line per phase.

#include "audio/audio_loader.h"
#include "audio/wav.h"
#include "dsp/oversample_peak.h"
#include "dsp/resampler.h"
#include "engine/pipeline.h"

#if defined(__APPLE__)
#include <mach/mach.h>
#endif
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <cmath>

using rta::audio::AudioBuffer;
namespace eng = rta::engine;

static double ws_mb() {
#if defined(__APPLE__)
    mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
        return (double)info.resident_size / (1024.0 * 1024.0);
    return 0.0;
#else
    return 0.0;
#endif
}

static double peak_mb() {
    static double peak = 0.0;
    const double ws = ws_mb();
    if (ws > peak) peak = ws;
    return peak;
}

static double now_ms() {
    using clk = std::chrono::steady_clock;
    return std::chrono::duration<double, std::milli>(clk::now().time_since_epoch()).count();
}

static void mem(const char* stage, const std::string& extra = std::string()) {
    std::printf("  MEM stage=%-12s ws=%8.1f MB peak=%8.1f MB %s\n", stage, ws_mb(), peak_mb(), extra.c_str());
    std::fflush(stdout);
}

// 现场合成测试文件
static std::string make_test_dsf(const std::string& path, uint32_t rate, int channels, size_t bitsPerChannel) {
    rta::audio::DsdStream s;
    s.rate = rate;
    s.channels = channels;
    s.bits = bitsPerChannel;
    s.container = "dsf";
    s.fileOrder = rta::audio::DsdBitOrder::LsbFirst;
    s.channelIds = rta::audio::dsd_detail::dsf_channel_ids(channels);
    s.channelType = rta::audio::dsd_detail::dsf_channel_type(channels);
    const size_t bytes = (bitsPerChannel + 7) / 8;
    s.data.resize((size_t)channels, std::vector<uint8_t>(bytes));
    for (int c = 0; c < channels; ++c) {
        uint32_t st = 123456789u + (uint32_t)c * 1010101u;
        for (size_t i = 0; i < bytes; ++i) {
            st = st * 1664525u + 1013904223u;
            s.data[(size_t)c][i] = (uint8_t)(st >> 16);
        }
    }
    rta::audio::write_dsf(path, s, 4096);
    return path;
}

int main(int argc, char** argv) {
    std::string file;
    std::string tempFile;
    if (argc > 1) {
        file = argv[1];
    } else {
        const char* tmp = std::getenv("TMPDIR");
        if (!tmp) tmp = "/tmp";
        tempFile = std::string(tmp) + "/rta_measure_big_test.dsf";
        // 生成 30 秒 DSD64 文件
        std::printf("未指定文件，自动合成 30s DSD64: %s\n", tempFile.c_str());
        make_test_dsf(tempFile, 2822400, 2, 2822400 * 30);
        file = tempFile;
    }

    std::printf("measure_big_dsd_playback file=%s\n", file.c_str());
    std::printf("  ws0=%.1f MB peak0=%.1f MB\n", ws_mb(), peak_mb());

    double t = now_ms();
    rta::audio::LoadNote note;
    AudioBuffer in = rta::audio::read_any(file, &note);
    const double decodeMs = now_ms() - t;
    if (in.rate == 0 || in.frames() == 0) { std::printf("  decode FAILED: %s\n", note.text.c_str()); return 2; }
    const double bufMb = (double)in.raw.size() * sizeof(int32_t) / (1024.0 * 1024.0);
    std::printf("  DECODE ms=%.0f rate=%u ch=%d bits=%d frames=%zu buf=%.1f MB note=%s\n",
                decodeMs, in.rate, in.channels, in.bits, in.frames(), bufMb, note.text.c_str());
    mem("decoded", "bufMb=" + std::to_string((long long)bufMb));

    // ---- phase 2: whole-file ISP scan ----
    t = now_ms();
    std::vector<std::vector<double>> planes;
    double srcPeak = 0.0;
    const bool wantIsp = true;
    if (wantIsp) {
        planes.resize((size_t)in.channels, std::vector<double>(in.frames()));
        for (size_t n = 0; n < in.frames(); ++n)
            for (int c = 0; c < in.channels; ++c) {
                const double v = in.sample(n, c);
                planes[(size_t)c][n] = v;
                if (std::fabs(v) > srcPeak) srcPeak = std::fabs(v);
            }
    }
    const double fillMs = now_ms() - t;
    t = now_ms();
    rta::dsp::IspReport rep = rta::dsp::detect_isp(planes);
    const double ispMs = now_ms() - t;
    const double planesMb = (double)planes.size() * (double)in.frames() * 8.0 / (1024.0 * 1024.0);
    std::printf("  ISP fillMs=%.0f scanMs=%.0f planes=%.1f MB peak=%.4f over=%lld srcPeak=%.4f\n",
                fillMs, ispMs, planesMb, rep.peak, rep.overCount, srcPeak);
    mem("isp", "planesMb=" + std::to_string((long long)planesMb));

    // ---- phase 3: pipeline, 4096-frame chunks ----
    eng::PipelineConfig cfg;
    cfg.outRate = 96000;
    cfg.outBits = 24;
    cfg.volumeEnabled = true;
    cfg.volumeDb = -60.0;
    cfg.gpuResample = true;
    cfg.twoStage = rta::audio::dsd_pcm_settings().twoStage;
    t = now_ms();
    auto pl = std::make_unique<eng::Pipeline>(cfg);
    const size_t kChunk = 4096;
    size_t pos = 0, outFrames = 0, blocks = 0;
    double tFirst = -1.0, dspTotal = 0.0;
    const double capSec = (argc > 2) ? std::atof(argv[2]) : 10.0;
    const size_t capFrames = (size_t)(capSec * (double)in.rate);
    while (pos < in.frames() && pos < capFrames) {
        const size_t n = std::min(kChunk, in.frames() - pos);
        AudioBuffer c;
        c.rate = in.rate; c.channels = in.channels; c.bits = in.bits; c.isFloat = in.isFloat;
        c.raw.assign(in.raw.begin() + (long long)(pos * (size_t)in.channels),
                     in.raw.begin() + (long long)((pos + n) * (size_t)in.channels));
        pos += n;
        const double b0 = now_ms();
        eng::PipelineStats pst;
        AudioBuffer o = pl->process(c, &pst);
        dspTotal += now_ms() - b0;
        ++blocks;
        outFrames += o.frames();
        if (tFirst < 0.0) { tFirst = now_ms() - t; std::printf("  DSP first-block ms=%.0f gpuResample=%d\n", tFirst, (int)pst.usedResample); }
    }
    std::printf("  PIPELINE firstBlockMs=%.0f totalMs=%.0f dspMs=%.0f blocks=%zu outFrames=%zu\n",
                tFirst, now_ms() - t, dspTotal, blocks, outFrames);
    mem("pipeline");
    std::printf("RESULT file=%s decodeMs=%.0f bufMb=%.0f ispMs=%.0f firstBlockMs=%.0f peakMb=%.1f\n",
                file.c_str(), decodeMs, bufMb, fillMs + ispMs, tFirst, peak_mb());

    if (!tempFile.empty()) {
        std::remove(tempFile.c_str());
    }
    return 0;
}
