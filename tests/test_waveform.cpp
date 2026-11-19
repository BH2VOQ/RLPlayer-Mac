// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_waveform.cpp — U2 包1：波形包络算法（WaveformAccumulator）合成信号验证
//
// 全部离线：信号现场合成，不开音频设备、不解码文件、不读写缓存。判据（派单任务书）：
//   §1 30 s / 48 kHz / 立体声，10.0 s 处唯一满幅脉冲、其余 −60 dBFS：
//      bins=300 时最大峰值 bin ∈ [99,101]，maxPeak ≈ 1.0；
//   §2 分块（1024 帧）与整段喂入：peaks / rms 逐 bin **逐位相等**
//      （实现按帧逐次累加，块边界不改变加法顺序；不是近似相等）；
//   §3 边界：bins 钳 [16,4096]（含默认 512）、totalFrames=0 不崩、
//      满幅多声道取 abs max、越界帧丢弃、声道数/空指针拒绝；
//   §4 恒定正弦 rms/peak ≈ 0.707 ± 0.02；整段便捷入口与累加器逐位一致。
//   §5 钳位语义（>1 → 1、NaN → 0、±inf → 1）与 finish() 幂等。
//
// 平台：纯 std::vector + <cmath>/<cstdio>，零平台依赖（macOS 原样可跑）。
#include "analysis/waveform.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <string>
#include <vector>

using namespace rta::analysis;

static constexpr double kPi = 3.14159265358979323846264338327950288;

static int fails = 0;

static void check(bool ok, const std::string& what, const std::string& detail = "") {
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                detail.empty() ? "" : " ", detail.c_str());
    if (!ok) ++fails;
}

static std::size_t argmax_bin(const std::vector<float>& v) {
    std::size_t best = 0;
    for (std::size_t i = 1; i < v.size(); ++i)
        if (v[i] > v[best]) best = i;
    return best;
}

// 逐位比较（memcmp）：任务要求"逐 bin 相等"，这里连 float 的位模式都不许差。
static bool same_bits(const std::vector<float>& a, const std::vector<float>& b, std::string& why) {
    if (a.size() != b.size()) {
        char buf[96];
        std::snprintf(buf, sizeof(buf), "size %zu != %zu", a.size(), b.size());
        why = buf;
        return false;
    }
    if (a.empty()) return true;
    if (std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0) return true;
    std::size_t i = 0;
    while (i < a.size() && std::memcmp(&a[i], &b[i], sizeof(float)) == 0) ++i;
    char buf[160];
    std::snprintf(buf, sizeof(buf), "first diff at bin %zu: %.9g vs %.9g", i,
                  (double)a[i], (double)b[i]);
    why = buf;
    return false;
}

// 合成底噪 + 唯一满幅脉冲：所有声道偶数位 +amp、奇数位 −amp；脉冲帧同样交替 ±1。
static std::vector<float> make_bed_pulse(std::size_t frames, int channels,
                                         std::size_t pulse_frame, float bed_amp) {
    std::vector<float> pcm(frames * (std::size_t)channels, 0.0f);
    for (std::size_t f = 0; f < frames; ++f) {
        for (int c = 0; c < channels; ++c) {
            const float v = (c % 2 == 0) ? bed_amp : -bed_amp;
            pcm[f * (std::size_t)channels + (std::size_t)c] = v;
        }
    }
    if (pulse_frame < frames) {
        for (int c = 0; c < channels; ++c) {
            const float v = (c % 2 == 0) ? 1.0f : -1.0f;
            pcm[pulse_frame * (std::size_t)channels + (std::size_t)c] = v;
        }
    }
    return pcm;
}

static std::vector<float> make_sine(std::size_t frames, int channels, double fs,
                                    double hz, double amp) {
    std::vector<float> pcm(frames * (std::size_t)channels, 0.0f);
    for (std::size_t f = 0; f < frames; ++f) {
        const float v = (float)(amp * std::sin(2.0 * kPi * hz * (double)f / fs));
        for (int c = 0; c < channels; ++c)
            pcm[f * (std::size_t)channels + (std::size_t)c] = v;
    }
    return pcm;
}

int main() {
    const int fs = 48000;
    const int ch = 2;
    const std::size_t frames30 = (std::size_t)30 * (std::size_t)fs;
    const float bed = std::pow(10.0f, -60.0f / 20.0f);
    const std::size_t pulse_frame = (std::size_t)10 * (std::size_t)fs;
    const std::vector<float> pcm30 = make_bed_pulse(frames30, ch, pulse_frame, bed);

    std::printf("test_waveform: U2 包1 波形包络算法（流式累加器）\n");

    // ---------------- §1 30 s / 48 kHz / 立体声：10.0 s 唯一满幅脉冲 ----------------
    {
        std::printf("\n§1 30 s / 48 kHz / 立体声：10.0 s 唯一满幅脉冲（其余 −60 dBFS）\n");
        WaveformAccumulator acc(frames30, 300, fs, ch);
        check(acc.addBlock(pcm30.data(), frames30, ch), "整段 addBlock 返回 true");
        const WaveformResult r = acc.finish();

        char buf[160];
        check(r.bins == 300, "结果 bins=300（请求在 [16,4096] 内，不钳位）");
        check(r.peaks.size() == 300 && r.rms.size() == 300, "peaks/rms 长度均为 300");
        check(r.sampleRate == fs && r.channels == ch, "sampleRate=48000、channels=2");
        std::snprintf(buf, sizeof(buf), "(durationSec=%.9f)", r.durationSec);
        check(std::fabs(r.durationSec - 30.0) < 1e-12, "durationSec=30.0（totalFrames/sampleRate）", buf);
        std::snprintf(buf, sizeof(buf), "(maxPeak=%.9f)", (double)r.maxPeak);
        check(std::fabs((double)r.maxPeak - 1.0) < 1e-6, "maxPeak ≈ 1.0", buf);

        const std::size_t top = argmax_bin(r.peaks);
        std::snprintf(buf, sizeof(buf), "(argmax bin=%zu, peaks[100]=%.6f)", top, (double)r.peaks[100]);
        check(top >= 99 && top <= 101, "最大峰值 bin ∈ [99,101]", buf);
        check(r.peaks[100] == 1.0f, "10.0 s 恰落在 bin 100，峰值为满幅 1.0");

        std::size_t hot = 0;
        for (std::size_t i = 0; i < r.peaks.size(); ++i)
            if (r.peaks[i] > 0.01f) ++hot;
        std::snprintf(buf, sizeof(buf), "(hot bins=%zu)", hot);
        check(hot == 1, "满幅脉冲只点亮一个 bin（其余为 −60 dBFS 底噪）", buf);

        float max_bed = 0.0f;
        for (std::size_t i = 0; i < r.peaks.size(); ++i)
            if (i != 100 && r.peaks[i] > max_bed) max_bed = r.peaks[i];
        std::snprintf(buf, sizeof(buf), "(max bed peak=%.9f, bed=%.9f)", (double)max_bed, (double)bed);
        check(std::fabs((double)max_bed - (double)bed) < 1e-6, "其余 bin 峰值 = −60 dBFS (0.001)", buf);

        // bin 100 恰好 4800 帧：1 帧满幅 + 4799 帧 0.001 ⟹ rms = sqrt((1 + 4799·bed²)/4800)
        const double expect_rms = std::sqrt((1.0 + 4799.0 * (double)bed * (double)bed) / 4800.0);
        std::snprintf(buf, sizeof(buf), "(rms[100]=%.9f, expect=%.9f)", (double)r.rms[100], expect_rms);
        check(std::fabs((double)r.rms[100] - expect_rms) < 1e-6, "bin 100 的 rms = 内层均值平方根", buf);
    }

    // ---------------- §2 分块喂入 vs 整段喂入：逐 bin 逐位相等 ----------------
    {
        std::printf("\n§2 分块喂入 vs 整段喂入：逐 bin 逐位相等（不是近似）\n");
        WaveformAccumulator whole(frames30, 300, fs, ch);
        check(whole.addBlock(pcm30.data(), frames30, ch), "整段参照 addBlock 返回 true");

        WaveformAccumulator chunked(frames30, 300, fs, ch);
        const std::size_t chunk = 1024;
        std::size_t calls = 0;
        bool all_added = true;
        for (std::size_t off = 0; off < frames30; off += chunk) {
            const std::size_t n = std::min(chunk, frames30 - off);
            all_added = chunked.addBlock(pcm30.data() + off * (std::size_t)ch, n, ch) && all_added;
            ++calls;
        }
        char buf[128];
        std::snprintf(buf, sizeof(buf), "(calls=%zu, frames=%zu)", calls, frames30);
        check(all_added, "1024 帧分块每次 addBlock 均返回 true", buf);

        const WaveformResult a = whole.finish();
        const WaveformResult b = chunked.finish();
        std::string why;
        check(same_bits(a.peaks, b.peaks, why), "peaks 逐位相等（1024 帧 vs 整段）", why);
        check(same_bits(a.rms, b.rms, why), "rms 逐位相等（1024 帧 vs 整段）", why);
        std::snprintf(buf, sizeof(buf), "(maxPeak %.9f vs %.9f)", (double)a.maxPeak, (double)b.maxPeak);
        check(a.maxPeak == b.maxPeak, "maxPeak 相等", buf);
        check(a.bins == b.bins && a.durationSec == b.durationSec && a.sampleRate == b.sampleRate
                  && a.channels == b.channels, "bins/durationSec/sampleRate/channels 一致");

        // 更多块长（含 1 帧、跨 bin 边界、超过总长）在小信号上同样逐位一致。
        const std::size_t small_frames = (std::size_t)fs;
        const std::vector<float> spcm = make_bed_pulse(small_frames, ch, small_frames / 2, bed);
        WaveformAccumulator ref(small_frames, 300, fs, ch);
        check(ref.addBlock(spcm.data(), small_frames, ch), "1 s 参照 addBlock 返回 true");
        const WaveformResult ra = ref.finish();
        for (const std::size_t cs : {std::size_t(1), std::size_t(37), std::size_t(1024),
                                     std::size_t(4800), std::size_t(65536)}) {
            WaveformAccumulator sa(small_frames, 300, fs, ch);
            int bad = 0;
            for (std::size_t off = 0; off < small_frames; off += cs) {
                const std::size_t n = std::min(cs, small_frames - off);
                if (!sa.addBlock(spcm.data() + off * (std::size_t)ch, n, ch)) ++bad;
            }
            const WaveformResult rb = sa.finish();
            std::snprintf(buf, sizeof(buf), "(block=%zu, failed calls=%d)", cs, bad);
            std::string why2;
            check(bad == 0 && same_bits(ra.peaks, rb.peaks, why2)
                      && same_bits(ra.rms, rb.rms, why2) && ra.maxPeak == rb.maxPeak,
                  "任意块长（1/37/1024/4800/65536）结果与整段逐位相等", buf + why2);
        }
    }

    // ---------------- §3 边界：bins 钳位、totalFrames=0、多声道、越界/非法输入 ----------------
    {
        std::printf("\n§3 边界：bins 钳位、totalFrames=0、多声道 abs max、越界/非法输入\n");
        struct BinCase { std::size_t request; std::size_t expect; };
        const BinCase cases[] = {
            {0, 16}, {1, 16}, {15, 16}, {16, 16}, {300, 300}, {512, 512},
            {4095, 4095}, {4096, 4096}, {4097, 4096}, {100000, 4096},
        };
        std::size_t mismatches = 0;
        std::string first_bad;
        for (const BinCase& c : cases) {
            WaveformAccumulator acc(1000, c.request, fs, 1);
            const WaveformResult r = acc.finish();
            if ((std::size_t)r.bins != c.expect || r.peaks.size() != c.expect || r.rms.size() != c.expect) {
                ++mismatches;
                if (first_bad.empty()) {
                    char buf[128];
                    std::snprintf(buf, sizeof(buf), "(request=%zu: got bins=%d, size=%zu, expect=%zu)",
                                  c.request, r.bins, r.peaks.size(), c.expect);
                    first_bad = buf;
                }
            }
        }
        check(mismatches == 0, "bins 钳 [16,4096]：0/1/15→16、16/300/512/4095/4096 原样、4097/100000→4096",
              first_bad);

        WaveformAccumulator def(1000);
        const WaveformResult rd = def.finish();
        check(rd.bins == 512 && rd.peaks.size() == 512 && rd.rms.size() == 512,
              "bins 缺省值 = 512");

        WaveformAccumulator empty_total(0, 300, fs, ch);
        const std::vector<float> blk = make_bed_pulse(1024, ch, 0, 0.5f);
        check(empty_total.addBlock(blk.data(), 1024, ch),
              "totalFrames=0 时 addBlock 接受块（帧越界，全部丢弃）");
        const WaveformResult r0 = empty_total.finish();
        bool all_zero = true;
        for (std::size_t i = 0; i < r0.peaks.size(); ++i)
            if (r0.peaks[i] != 0.0f || r0.rms[i] != 0.0f) all_zero = false;
        check(all_zero && r0.peaks.size() == 300, "totalFrames=0：peaks/rms 仍为 300 项且全 0（不崩、不猜）");
        check(r0.maxPeak == 0.0f && r0.durationSec == 0.0, "totalFrames=0：maxPeak=0、durationSec=0");
        check(r0.sampleRate == fs && r0.channels == ch, "totalFrames=0：sampleRate/channels 仍如实返回");

        // 满幅多声道：abs max 折叠，不是相加；超幅钳位、NaN→0、±inf→1。
        WaveformAccumulator multi(16, 16, fs, 3);
        std::vector<float> mblock(16 * 3, 0.0f);
        mblock[0 * 3 + 0] = 0.25f;  mblock[0 * 3 + 1] = -0.9f; mblock[0 * 3 + 2] = 0.5f;
        mblock[1 * 3 + 0] = -0.5f;  mblock[1 * 3 + 1] = 0.125f; mblock[1 * 3 + 2] = 0.0f;
        mblock[2 * 3 + 0] = 2.5f;   mblock[2 * 3 + 1] = -3.0f; mblock[2 * 3 + 2] = 0.0f;
        mblock[3 * 3 + 0] = std::numeric_limits<float>::infinity();
        mblock[3 * 3 + 1] = std::numeric_limits<float>::quiet_NaN();
        mblock[3 * 3 + 2] = -std::numeric_limits<float>::infinity();
        mblock[4 * 3 + 0] = std::numeric_limits<float>::quiet_NaN();
        mblock[4 * 3 + 1] = std::numeric_limits<float>::quiet_NaN();
        mblock[4 * 3 + 2] = 0.75f;
        check(multi.addBlock(mblock.data(), 16, 3), "16 帧 / 3 声道 addBlock 返回 true");
        const WaveformResult rm = multi.finish();
        check(rm.peaks[0] == 0.9f, "帧0：三声道 abs max = 0.9（不是 0.25+0.9+0.5）");
        check(rm.peaks[1] == 0.5f, "帧1：三声道 abs max = 0.5");
        check(rm.peaks[2] == 1.0f, "帧2：>1 的超幅样本钳到 1.0");
        check(rm.peaks[3] == 1.0f, "帧3：±inf → 1.0、NaN → 0");
        check(rm.peaks[4] == 0.75f, "帧4：NaN 不污染有效声道（0.75）");
        check(rm.maxPeak == 1.0f, "满幅多声道：maxPeak = 1.0（钳位后）");
        check(rm.rms[1] == 0.5f, "单帧 bin 的 rms = 折叠峰值（均值平方根）");

        // 越界帧丢弃 + 后续块继续丢弃（不重复计入）。
        WaveformAccumulator over(8, 16, fs, 1);
        std::vector<float> oblock(16, 1.0f);
        for (std::size_t f = 0; f < 8; ++f) oblock[f] = 0.1f;
        oblock[7] = 0.4f;
        check(over.addBlock(oblock.data(), 16, 1), "totalFrames=8 收到 16 帧：接受并丢弃越界帧");
        const WaveformResult ro = over.finish();
        check(ro.peaks[14] == 0.4f, "第 7 帧（最后一帧）落在 bin 14 且保留 0.4");
        check(ro.peaks[15] == 0.0f && ro.maxPeak == 0.4f,
              "越界帧（8..15 的 1.0）未被计入（maxPeak 仍 0.4）");
        check(over.addBlock(oblock.data(), 16, 1), "越界后再次 addBlock 仍返回 true");
        check(over.finish().maxPeak == 0.4f, "越界后的后续块继续丢弃，不重复计入");

        // 非整除映射：最后帧不会被丢掉，mid-range 单帧也能归位。
        WaveformAccumulator tail(1000, 16, fs, ch);
        const std::vector<float> tpcm = make_bed_pulse(1000, ch, 999, bed);
        check(tail.addBlock(tpcm.data(), 1000, ch), "totalFrames=1000 / bins=16：addBlock 返回 true");
        const WaveformResult rt = tail.finish();
        check(rt.peaks[15] == 1.0f && std::fabs((double)rt.peaks[0] - (double)bed) < 1e-6,
              "1000 帧不整除 16 bin：第 999 帧仍归入 bin 15，不丢尾帧");

        WaveformAccumulator mid(1000, 16, fs, ch);
        const std::vector<float> mpcm = make_bed_pulse(1000, ch, 62, bed);
        check(mid.addBlock(mpcm.data(), 1000, ch), "单帧脉冲（第 62 帧）addBlock 返回 true");
        const WaveformResult rmid = mid.finish();
        check(rmid.peaks[0] == 1.0f, "第 62 帧（bin 0 内）的单帧脉冲被捕获（不按块粗采样）");

        // 声道锁定 / 非法参数。
        WaveformAccumulator infer(100, 16, fs, 0);
        std::vector<float> b2(200, 0.5f);
        check(infer.addBlock(b2.data(), 100, 2), "构造未给 channels 时由首个块定声道数");
        check(infer.finish().channels == 2, "结果 channels = 首个块的 2");
        check(!infer.addBlock(b2.data(), 100, 1), "后续块声道数变化一律拒绝（不静默改帧索引）");
        check(!infer.addBlock(nullptr, 10, 2), "interleaved=nullptr 且 frames>0 拒绝");
        check(infer.addBlock(nullptr, 0, 2), "frames=0 + nullptr 视为空块（true）");
        check(!infer.addBlock(b2.data(), 100, 0), "channels<=0 拒绝");

        WaveformAccumulator locked(100, 16, fs, 2);
        check(!locked.addBlock(b2.data(), 100, 1), "构造指定 channels=2 时不同声道数拒绝");
    }

    // ---------------- §4 恒定正弦 rms/peak ≈ 0.707 ± 0.02；便捷入口一致 ----------------
    {
        std::printf("\n§4 恒定正弦：rms/peak ≈ 0.707 ± 0.02；便捷入口与累加器逐位一致\n");
        const std::size_t n = 2 * (std::size_t)fs;  // 2 s
        const std::vector<float> sine = make_sine(n, ch, fs, 997.0, 0.8);
        WaveformAccumulator acc(n, 128, fs, ch);
        check(acc.addBlock(sine.data(), n, ch), "正弦 addBlock 返回 true");
        const WaveformResult r = acc.finish();

        double min_ratio = 2.0, max_ratio = 0.0;
        std::size_t bad = 0;
        std::size_t active = 0;
        for (std::size_t i = 0; i < r.peaks.size(); ++i) {
            if (r.peaks[i] <= 0.0f) continue;
            ++active;
            const double ratio = (double)r.rms[i] / (double)r.peaks[i];
            min_ratio = std::min(min_ratio, ratio);
            max_ratio = std::max(max_ratio, ratio);
            if (!(ratio >= 0.687 && ratio <= 0.727)) ++bad;
        }
        char buf[160];
        std::snprintf(buf, sizeof(buf), "(min=%.6f, max=%.6f, active=%zu, out-of-range=%zu)",
                      min_ratio, max_ratio, active, bad);
        check(active == 128 && bad == 0, "全部 128 个 bin 的 rms/peak 落在 0.707±0.02", buf);
        std::snprintf(buf, sizeof(buf), "(maxPeak=%.9f)", (double)r.maxPeak);
        check(std::fabs((double)r.maxPeak - 0.8) < 2e-3, "0.8 满幅正弦 maxPeak ≈ 0.8", buf);
        std::snprintf(buf, sizeof(buf), "(rms[64]=%.9f, expect=%.9f)", (double)r.rms[64],
                      (double)0.8 / std::sqrt(2.0));
        check(std::fabs((double)r.rms[64] - 0.8 / std::sqrt(2.0)) < 0.01,
              "中段 bin 的 rms ≈ 0.8/√2", buf);

        // 便捷入口：内部用 Accumulator；不知道采样率 ⟹ duration/rate 如实为 0。
        const WaveformResult conv = waveform_peaks_from_pcm(sine, ch, 300);
        WaveformAccumulator mirror(n, 300, 0, ch);
        check(mirror.addBlock(sine.data(), n, ch), "便捷入口对照 addBlock 返回 true");
        const WaveformResult mir = mirror.finish();
        std::string why;
        check(same_bits(conv.peaks, mir.peaks, why), "便捷入口 peaks 与累加器逐位一致", why);
        check(same_bits(conv.rms, mir.rms, why), "便捷入口 rms 与累加器逐位一致", why);
        check(conv.bins == 300 && conv.maxPeak == mir.maxPeak && conv.channels == ch,
              "便捷入口 bins/maxPeak/channels 一致");
        check(conv.sampleRate == 0 && conv.durationSec == 0.0,
              "便捷入口无采样率：sampleRate/durationSec 如实为 0（不猜）");

        // 非法/退化输入：不崩，返回钳位后的全零结果。
        const WaveformResult badch = waveform_peaks_from_pcm(sine, 0, 4);
        check(badch.bins == 16 && badch.peaks.size() == 16 && badch.maxPeak == 0.0f,
              "channels=0 不崩：返回钳位 bins=16 的全零结果");
        const std::vector<float> nothing;
        const WaveformResult re = waveform_peaks_from_pcm(nothing, ch, 512);
        check(re.bins == 512 && re.peaks.size() == 512 && re.maxPeak == 0.0f && re.channels == ch,
              "空 PCM 不崩：bins=512 全零、channels 如实");

        // 样本数不被声道数整除：尾样丢弃（帧数 floor(size/channels)）。
        const std::vector<float> ragged = {1.0f, -1.0f, 0.2f, 0.2f, 0.9f};
        const WaveformResult rr = waveform_peaks_from_pcm(ragged, 2, 16);
        check(rr.peaks[0] == 1.0f && rr.peaks[8] == 0.2f && rr.maxPeak == 1.0f,
              "size 不被 channels 整除：按整帧计，多出的尾样丢弃");
    }

    // ---------------- §5 finish() 幂等 ----------------
    {
        std::printf("\n§5 finish() 幂等（只读快照，可重复调用）\n");
        WaveformAccumulator acc(1000, 37, fs, ch);
        const std::vector<float> p = make_bed_pulse(1000, ch, 999, bed);
        check(acc.addBlock(p.data(), 1000, ch), "37 bins addBlock 返回 true");
        const WaveformResult a = acc.finish();
        const WaveformResult b = acc.finish();
        std::string why;
        check(same_bits(a.peaks, b.peaks, why) && same_bits(a.rms, b.rms, why)
                  && a.maxPeak == b.maxPeak && a.bins == b.bins && a.durationSec == b.durationSec,
              "两次 finish() 结果完全一致", why);
        check(a.bins == 37, "非钳位值 37 原样保留");
    }

    std::printf("\n%s（失败项 %d）\n", fails == 0 ? "全部通过" : "存在失败", fails);
    return fails == 0 ? 0 : 1;
}
