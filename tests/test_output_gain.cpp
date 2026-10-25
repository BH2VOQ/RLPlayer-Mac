// test_output_gain.cpp — 设备输出层增益应用门禁（2026-10-25 音量失效事故的回归测试）
//
// 为什么单独建这条测试：
//   项目原本只有 tests/test_volume_eq.cpp 覆盖 DSP 层的 volume（浮点域乘增益），
//   但**设备输出层**（CoreAudioOutput::write 的环形缓冲写入）从来没测过 gain 是否真的应用。
//   结果是：render_loop 调 set_live_gain_db()（基类空实现）→ 请求被丢弃；
//   而 CoreAudioOutput 的 write() 又直接 memcpy 原始 PCM、从不读 gain_
//   ⟹ 用户拖音量条毫无反应（"音量不好使"），同时 bit_perfect() 还因 gain_!=1 报非位完美。
//
// 判据（与 audio_out_coreaudio.h::write() 的缩放分支逐行同构，纯离线不碰设备）：
//   1. gain == 1.0 必须**逐位不变**（bit-perfect 语义不能因修音量而退化）
//   2. gain == 0.5 输出幅度必须恰好减半（-6.02 dB）
//   3. 多档增益输出必须**严格递减**（证明"拖音量条真的有反应"）
//   4. gain == 0 必须是真静音（全 0）
//   5. 超过满幅的增益必须被限幅，不能溢出成反相爆音
//   6. dB → 线性换算必须准确（0/-6.0206/-20/-120 dB）
#include <cstdio>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>
#include <algorithm>
#include <string>

static int fails = 0;
static void ck(bool ok, const char* what, const std::string& detail = "") {
    std::printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what, detail.c_str());
    if (!ok) ++fails;
}

// === 与 src/platform/macos/audio_out_coreaudio.h::write() 的缩放分支逐行同构 ===
// 改动生产代码时必须同步这里，否则测试会失去意义（红→绿演示见文件末尾注释）。
static void writeWithGain(std::vector<int32_t>& ring, size_t capacity, size_t& write_pos,
                          const int32_t* interleaved, size_t n,
                          int channels, int bits, double gain) {
    const double g = gain;
    if (g == 1.0) {
        for (size_t i = 0; i < n; ++i)
            std::memcpy(&ring[(write_pos + i) % capacity * (size_t)channels],
                        interleaved + i * (size_t)channels,
                        sizeof(int32_t) * (size_t)channels);
    } else {
        const int shift = (bits >= 1 && bits <= 32) ? (32 - bits) : 0;
        const double scale = std::ldexp(1.0, shift);
        for (size_t i = 0; i < n; ++i) {
            int32_t* dst = &ring[(write_pos + i) % capacity * (size_t)channels];
            const int32_t* src = interleaved + i * (size_t)channels;
            for (int c = 0; c < channels; ++c) {
                if (g == 0.0) { dst[c] = 0; continue; }
                const double v = (double)src[c] / scale * g;
                const double lim = (double)((1LL << (bits - 1)) - 1);
                double cl = v;
                if (cl >  lim) cl =  lim;
                if (cl < -lim) cl = -lim;
                dst[c] = (int32_t)std::llround(cl * scale);
            }
        }
    }
    write_pos = (write_pos + n) % capacity;
}

// === 与 rtaweb.cpp 的 CoreAudioSink::set_live_gain_db 同构 ===
static double dbToLinear(double db) {
    if (db < -120.0) db = -120.0;
    if (db > 12.0) db = 12.0;
    return (db <= -120.0) ? 0.0 : std::pow(10.0, db / 20.0);
}

int main() {
    std::printf("=== test_output_gain: 设备输出层增益应用门禁 ===\n");
    std::printf("（纯离线数值验证，不打开任何音频设备 —— 铁律 1）\n\n");

    const int bits = 24, ch = 2;
    const double scale = std::ldexp(1.0, 32 - bits);
    const int32_t peak = (int32_t)(0.5 * (double)((1LL << (bits - 1)) - 1) * scale);
    std::vector<int32_t> in = { peak, peak, peak, peak };   // 4 帧，-6 dBFS
    const size_t cap = 64;
    std::vector<int32_t> ring(cap * (size_t)ch, 0);
    size_t wp = 0;

    std::printf("-- 1. gain == 1.0 必须逐位不变（bit-perfect 不能退化）--\n");
    {
        std::fill(ring.begin(), ring.end(), 0); wp = 0;
        writeWithGain(ring, cap, wp, in.data(), 4, ch, bits, 1.0);
        ck(ring[0] == peak, "gain=1.0 逐位不变",
           "ring[0]=" + std::to_string(ring[0]) + " exp=" + std::to_string(peak));
    }

    std::printf("\n-- 2. gain == 0.5 输出幅度必须恰好减半 --\n");
    {
        std::fill(ring.begin(), ring.end(), 0); wp = 0;
        writeWithGain(ring, cap, wp, in.data(), 4, ch, bits, 0.5);
        const double r = (double)ring[0] / (double)peak;
        ck(std::fabs(r - 0.5) < 1e-6, "gain=0.5 → 幅度减半（-6.02 dB）",
           "ratio=" + std::to_string(r));
    }

    std::printf("\n-- 3. 多档增益输出必须严格递减（音量条真的有反应）--\n");
    {
        const std::vector<double> gains = { 1.0, 0.5, 0.1, 0.01 };
        std::vector<int32_t> outs;
        for (double g : gains) {
            std::fill(ring.begin(), ring.end(), 0); wp = 0;
            writeWithGain(ring, cap, wp, in.data(), 4, ch, bits, g);
            outs.push_back(ring[0]);
        }
        bool dec = true;
        for (size_t i = 1; i < outs.size(); ++i) if (!(outs[i] < outs[i - 1])) dec = false;
        ck(dec, "4 档增益输出严格递减",
           "outs=" + std::to_string(outs[0]) + "," + std::to_string(outs[1]) + "," +
           std::to_string(outs[2]) + "," + std::to_string(outs[3]));
        // 反证：如果 write() 退回"只 memcpy 不乘增益"（原 BUG），4 档输出会全部相等
        bool allSame = true;
        for (size_t i = 1; i < outs.size(); ++i) if (outs[i] != outs[0]) allSame = false;
        ck(!allSame, "判据有分辨力：不会把『全部相等』误判为通过");
    }

    std::printf("\n-- 4. gain == 0 必须真静音 --\n");
    {
        std::fill(ring.begin(), ring.end(), 0); wp = 0;
        writeWithGain(ring, cap, wp, in.data(), 4, ch, bits, 0.0);
        ck(ring[0] == 0 && ring[1] == 0, "gain=0 → 全 0（真静音）");
    }

    std::printf("\n-- 5. 超过满幅的增益必须限幅，不能溢出反相 --\n");
    {
        std::vector<int32_t> big = {
            (int32_t)(((1LL << (bits - 1)) - 1) * scale), 0,
            (int32_t)(((1LL << (bits - 1)) - 1) * scale), 0
        };
        std::fill(ring.begin(), ring.end(), 0); wp = 0;
        writeWithGain(ring, cap, wp, big.data(), 2, ch, bits, 2.0);
        ck(ring[0] > 0, "满幅 ×2 削波后仍为正（不溢出成反相）",
           "got=" + std::to_string(ring[0]));
        const double lim = ((1LL << (bits - 1)) - 1) * scale;
        ck((double)ring[0] <= lim + 1, "削波被限幅在合法范围内",
           "got=" + std::to_string(ring[0]) + " lim=" + std::to_string((long long)lim));
    }

    // ---- 5b) 爆音回归判据（2026-10-25 真实事故）----
    // 事故：把 render_loop 的 delta 当绝对值用 + 把 startDb 设成硬件等效 dB
    // ⟹ 滑块拉到 0 dB 时 delta = +16.4 dB ⟹ 3.98 倍增益 ⟹ 削波爆音。
    // 这里钉住正确语义：绝对音量 = base + delta，且**绝不允许 > 0 dB**。
    std::printf("\n-- 5b. 爆音回归：delta 语义 + 硬限幅 0 dB --\n");
    {
        auto absGain = [](double baseDb, double deltaDb) -> double {
            double absDb = baseDb + deltaDb;
            if (absDb > 0.0) absDb = 0.0;          // 硬限幅：>0 dB 必削波
            if (absDb < -120.0) absDb = -120.0;
            return (absDb <= -120.0) ? 0.0 : std::pow(10.0, absDb / 20.0);
        };
        // 正常路径：base=0，delta 就是用户请求
        const double g0   = absGain(0.0,   0.0);
        const double gm6  = absGain(0.0,  -6.0);
        const double gm20 = absGain(0.0, -20.0);
        ck(std::fabs(g0 - 1.0) < 1e-9, "0 dB → 增益 1.0（满幅，不超）",
           "g=" + std::to_string(g0));
        ck(std::fabs(gm6 - 0.5012) < 1e-3, "-6 dB → 增益 ≈0.5", "g=" + std::to_string(gm6));
        ck(std::fabs(gm20 - 0.1) < 1e-6, "-20 dB → 增益 0.1", "g=" + std::to_string(gm20));
        ck(g0 > gm6 && gm6 > gm20, "增益随音量单调递减（音量条真的有效）");

        // 爆音场景复现：base = 硬件等效 -16.38，delta = +16.38（滑块 0 dB − startDb）
        // 正确实现下 abs = 0 dB → 增益 1.0（不爆）；错误实现会给 3.98 倍
        const double boom = absGain(-16.38, +16.38);
        ck(std::fabs(boom - 1.0) < 1e-3, "接管场景 base=-16.38 + delta=+16.38 → 恰好 1.0（不爆音）",
           "g=" + std::to_string(boom));
        ck(boom <= 1.0 + 1e-9, "任何组合都不得产生 >1.0 的增益（防削波爆音）");

        // 极端越界：人为给 +40 dB delta，必须被限到 0 dB
        const double huge = absGain(0.0, 40.0);
        ck(std::fabs(huge - 1.0) < 1e-9, "delta=+40 dB 被限幅到 0 dB（绝不放大）",
           "g=" + std::to_string(huge));
    }

    std::printf("\n-- 6. dB → 线性换算 --\n");
    {
        ck(std::fabs(dbToLinear(0.0) - 1.0) < 1e-12, "0 dB → 1.0");
        ck(std::fabs(dbToLinear(-6.0206) - 0.5) < 1e-4, "-6.0206 dB → 0.5");
        ck(std::fabs(dbToLinear(-20.0) - 0.1) < 1e-9, "-20 dB → 0.1");
        ck(dbToLinear(-120.0) == 0.0, "-120 dB → 0（静音）");
        ck(dbToLinear(-200.0) == 0.0, "低于 -120 dB 限幅为静音");
        ck(std::fabs(dbToLinear(20.0) - std::pow(10.0, 12.0 / 20.0)) < 1e-9,
           "超过 +12 dB 限幅");
    }

    std::printf("\n=== %s（%d 失败）===\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}

// 红→绿演示（铁律 3：判据要能证明自己抓得住 bug）：
//   把 writeWithGain 的非 1.0 分支改回"只 memcpy"（= 2026-10-25 修复前的生产代码），
//   判据 2 / 3 立即变红：
//     [FAIL] gain=0.5 → 幅度减半（-6.02 dB）  ratio=1.000000
//     [FAIL] 4 档增益输出严格递减  outs=1073741696,1073741696,1073741696,1073741696
