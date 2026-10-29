// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_fake_lossless.cpp — 音频体检 B1a：假无损检测合成信号验证
// 全部信号现场合成、完全离线：砖墙低通用项目现成的 Kaiser 窗函数法 FIR（src/dsp/filter_design.h）
// 造出来，缓坡滚降用 Butterworth 双二阶级联 —— 判据确定性可复现。
// 关键反误报用例（第 4 节）必须证明「陡沿门」确实把温和滚降拦在判假之外。
//
// ---------------- macOS 移植（2026-10-26，上游 68e628f v1.5.2 → 本库）----------------
// 上游 §1~§5 逐条保留（阈值一字未改），**新增 §6/§7 两组**，对应任务书判据 3 的
// 「负向对照」硬要求：
//   §6 真无损不得被误判 —— 但注意：上游 §1「全带白噪」**不是**真无损的代表性对照。
//      白噪的谱是平的，本来就没有"内容在哪儿截止"这件事；真实无损音乐的能量集中在
//      低频/中频，高频天然掉下去。所以 §6 用「真无损音乐形态」的合成信号（谐波簇 +
//      带内高通噪声底 + 自然 −12 dB/oct 高频滚降 + 20 kHz 处仍有内容），
//      在 44.1k / 48k / 96k 三个采样率上都必须判 false。
//   §7 假无损必须被抓到 —— 对同一个真无损信号做**真实的**有损编码往返
//      （用本机 ffmpeg-lite 的 libmp3lame / aac，再解回 PCM），而不是"手搓一个低通"。
//      这是负向对照的正向侧：真实编码器产出的截止必须被检出。
//      ⚠️ 依赖纪律（铁律 3，2026-10-26 B-1 事故）：**「找到工具」≠「工具能跑」**。
//      本测试先跑 `-version` 自检；不可用就明确 SKIP 并打印原因，**不判红也不谎报通过**。
#include "analysis/fake_lossless.h"
#include "dsp/filter_design.h"
#include "dsp/matrix.h"
#include "dsp/dither.h"
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

using namespace rta::analysis;
using namespace rta::dsp;
using rta::dsp::kPi;

static int fails = 0;
static int skips = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++fails;
}
static void skip(const std::string& what, const std::string& why) {
    printf("  [SKIP] %s — %s\n", what.c_str(), why.c_str());
    ++skips;
}
// 「已实测的已知边界」：既不算通过也不算失败，只把测量事实钉在输出里（铁律 4）。
// 用途：检测器按「宁可漏报不可误报」设计，某些编码组合确实抓不到 —— 那不是 bug，
// 是设计取舍。但必须**留下可复跑的实测数字**，否则下一个人会以为"没测过"。
static int knowns = 0;
static void known(const std::string& what, const std::string& detail) {
    printf("  [KNOWN] %s — %s\n", what.c_str(), detail.c_str());
    ++knowns;
}

static const double kFs = 44100.0;
static const size_t kN = 882000;          // 20 s：够均匀铺满 12 个 65536 样窗
static const int kTaps = 511;             // 奇数抽头 Kaiser FIR（44.1k 下过渡带 ≈550 Hz）

// 确定性高斯白噪，峰值归一到 target
static std::vector<std::vector<double>> make_noise(int channels, uint64_t seed, double target) {
    std::vector<std::vector<double>> ch((size_t)channels, std::vector<double>(kN));
    for (int c = 0; c < channels; ++c) {
        Rng rng(seed + (uint64_t)c * 7919ull);
        double pk = 0.0;
        for (size_t i = 0; i < kN; ++i) {
            ch[(size_t)c][i] = rng.gauss();
            pk = std::max(pk, std::fabs(ch[(size_t)c][i]));
        }
        const double g = target / pk;
        for (size_t i = 0; i < kN; ++i) ch[(size_t)c][i] *= g;
    }
    return ch;
}

static std::vector<const double*> ptrs(const std::vector<std::vector<double>>& ch) {
    std::vector<const double*> p;
    for (const auto& c : ch) p.push_back(c.data());
    return p;
}

// 直接卷积 FIR（h 已归一直流增益）；只做因果部分，头部瞬态远小于分析窗
static void fir_apply(std::vector<double>& x, const std::vector<double>& h) {
    std::vector<double> y(x.size(), 0.0);
    for (size_t i = 0; i < x.size(); ++i) {
        double s = 0.0;
        const size_t kmax = std::min(h.size(), i + 1);
        for (size_t k = 0; k < kmax; ++k) s += h[k] * x[i - k];
        y[i] = s;
    }
    x.swap(y);
}

// Kaiser 砖墙低通（fc 以 Nyquist 归一）
static std::vector<double> brickwall(double fcHz) {
    LowpassSpec spec;
    spec.taps = kTaps;
    spec.cutoff = fcHz / (kFs * 0.5);
    spec.attenDb = 100.0;
    return design_lowpass(spec);
}

static std::string brief(const LosslessCheck& c) {
    char b[256];
    std::snprintf(b, sizeof(b), "(cutoff %.1f Hz, conf %.3f, suspected %d, fake24 %d) %s",
                  c.cutoffHz, c.confidence, c.suspected ? 1 : 0, c.fake24bit ? 1 : 0,
                  c.reason.c_str());
    return std::string(b);
}

// ---------------- §6/§7 用的「真无损音乐形态」合成器 ----------------
// 造一段在**所有**判据维度上都像真无损音乐的信号：
//   * 谐波簇：基频 + 2..40 次谐波（1/n 幅度 ⟹ 自然 −6 dB/oct 包络），多个「音符」交替；
//   * 带内噪声底：−72 dBFS 白噪（模拟录音/母带噪声），它**铺到奈奎斯特**，
//     所以任何"从高频往下扫到 −40 dB"的截止检测都扫不到东西；
//   * 高频内容：14~20 kHz 处的弱谐波簇（−45 dBFS 级），证明 20 kHz 附近仍有能量；
//   * 轻微高频滚降：−12 dB/oct 一阶低通 @ 18 kHz 量级（真实母带/话筒的形态），
//     用来证明「有滚降」≠「判假」。
// 输出峰值归一到 0.5（约 −6 dBFS），24-bit 量化。
static std::vector<double> make_true_lossless_music(double fs, size_t n, uint64_t seed) {
    std::vector<double> x(n, 0.0);
    Rng rng(seed);
    // 音符序列：每 2.5 s 换一个基频（A2/C3/E3/G3 之类），模拟真实音乐的音高变化
    const double roots[4] = { 110.0, 130.81, 164.81, 196.00 };
    const size_t segN = (size_t)(2.5 * fs);
    // ★ 关键（第一版踩的坑，如实记下来）：谐波簇**不许**在 0.45·fs 处一刀切。
    //   那样造出来的是**真的砖墙**，检测器判它"有陡峭截止"是**判对了**，不是误报
    //   （第一版实测 44.1k 处 cutoff=19927 Hz / 下降 36 dB / suspected=1）。
    //   真无损音乐的高频是**平滑衰减到奈奎斯特**的，所以这里让谐波一直排到
    //   0.49·fs，并用 1/h 的自然包络（−6 dB/oct）继续衰减 —— 谱上没有台阶。
    for (size_t i = 0; i < n; ++i) {
        const size_t seg = std::min<size_t>(3, i / (segN ? segN : 1));
        const double f0 = roots[seg];
        double s = 0.0;
        for (int h = 1; h <= 400; ++h) {
            const double fh = f0 * (double)h;
            if (fh >= 0.49 * fs) break;
            s += std::sin(2.0 * kPi * fh * (double)i / fs) / (double)h;
        }
        x[i] = 0.12 * s;   // 谐波簇主体（1/h 包络 ⟹ 高频自然衰减，无台阶）
        // 高频弱簇：14~20 kHz（在 44.1k 上也能放下），让它明确"有内容"
        for (double fh = 14000.0; fh < 20000.0 && fh < 0.49 * fs; fh += 1500.0)
            x[i] += 0.0016 * std::sin(2.0 * kPi * fh * (double)i / fs + (double)seed);
    }
    // 抖动级噪声底（真实 ADC/母带的噪声，铺满到奈奎斯特）：保证高频段不会
    // 一路跌到 −40 dB 以下而被当成"截止"。电平取 −78 dBFS RMS 量级（约 24-bit 抖动）。
    for (size_t i = 0; i < n; ++i) x[i] += 0.00004 * rng.gauss();
    // 温和高频滚降（真实母带/话筒形态，不是 codec 的砖墙）
    Biquad lp;
    biquad_design::lowpass(lp, fs, std::min(18000.0, 0.45 * fs), 0.70710678);
    for (size_t i = 0; i < n; ++i) x[i] = lp.process(x[i]);
    // 峰值归一到 0.5
    double pk = 0.0;
    for (double v : x) pk = std::max(pk, std::fabs(v));
    if (pk > 0.0) for (double& v : x) v *= 0.5 / pk;
    return x;
}

// 16-bit 量化到 24-bit 容器（左移 8 位）+ 1 LSB 抖动：让低 8 位"干净但不是恒零"，
// 这样 §6 同时证明"真 24-bit 容器不该被判 fake24"。
static void quantize_true24(std::vector<double>& x, uint64_t seed) {
    Rng rng(seed);
    for (double& v : x) {
        long long q = (long long)std::llround(v * 8388608.0);        // 24-bit 满幅
        q += (long long)(rng.next() % 3) - 1;                        // ±1 LSB 抖动
        v = (double)q / 8388608.0;
    }
}

// ---------------- ffmpeg 自检（铁律 3：找到 ≠ 能跑） ----------------
struct ToolProbe { std::string path; bool usable = false; std::string why; };

static ToolProbe probe_tool(const char* name) {
    ToolProbe tp;
    // ① 环境变量覆盖（与 audio_loader::find_tool 同口径，便于换工具链）
    char envName[64];
    std::snprintf(envName, sizeof(envName), "RLPLAYER_%s", name);
    for (char* p = envName; *p; ++p) *p = (char)std::toupper((unsigned char)*p);
    if (const char* env = std::getenv(envName)) {
        if (env[0]) { tp.path = env; }
    }
    // ② exe 同目录 → ③ 从可执行目录向上找 build-mac/ffmpeg-lite/（与 audio_loader::find_tool 同口径）
    if (tp.path.empty()) {
        // 先看环境变量指定的仓库根；否则从 cwd 逐级向上找 build-mac/ffmpeg-lite/
        std::vector<std::string> bases;
        if (const char* root = std::getenv("RLPLAYER_REPO_ROOT"); root && *root) bases.push_back(root);
        char cwd[4096] = {0};
        if (::getcwd(cwd, sizeof(cwd) - 1)) {
            std::string up = cwd;
            for (int depth = 0; depth < 5 && !up.empty(); ++depth) {
                bases.push_back(up);
                const size_t slash = up.find_last_of('/');
                if (slash == std::string::npos || slash == 0) break;
                up = up.substr(0, slash);
            }
        }
        for (const std::string& base : bases) {
            const std::string cand = base + "/build-mac/ffmpeg-lite/" + name;
            struct stat st{};
            if (::stat(cand.c_str(), &st) == 0 && S_ISREG(st.st_mode)) { tp.path = cand; break; }
        }
    }
    if (tp.path.empty()) { tp.why = std::string("找不到 ") + name; return tp; }
    // ★ 关键：跑一次 -version 自检（本机系统 ffmpeg/ffprobe 已坏，退出码 134）
    const std::string cmd = "\"" + tp.path + "\" -version >/dev/null 2>&1";
    const int rc = std::system(cmd.c_str());
    if (rc != 0) {
        tp.why = tp.path + " 自检失败（-version 退出码 " + std::to_string(rc) + "）";
        return tp;
    }
    tp.usable = true;
    return tp;
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);

    printf("=== 1. 全带白噪 @44.1k → 不判假、无截止 ===\n");
    {
        auto ch = make_noise(2, 0xDEADBEEFull, 0.5);
        auto p = ptrs(ch);
        const LosslessCheck c = check_lossless(p.data(), 2, kN, kFs, 16);
        printf("  %s\n", brief(c).c_str());
        check(!c.suspected, "suspected = false");
        check(c.cutoffHz == 0.0, "cutoffHz = 0（全带无截止）");
    }

    printf("\n=== 2. 16 kHz 砖墙低通白噪 → 判假、截止 16000±800 ===\n");
    {
        auto ch = make_noise(2, 0x12345678ull, 0.5);
        fir_apply(ch[0], brickwall(16000.0));
        fir_apply(ch[1], brickwall(16000.0));
        auto p = ptrs(ch);
        const LosslessCheck c = check_lossless(p.data(), 2, kN, kFs, 16);
        printf("  %s\n", brief(c).c_str());
        check(c.suspected, "suspected = true");
        check(std::fabs(c.cutoffHz - 16000.0) <= 800.0, "cutoffHz = 16000 ±800", brief(c));
        check(c.confidence >= 0.5, "confidence ≥ 0.5");
    }

    printf("\n=== 3. 19 kHz 砖墙低通白噪 → 判假、截止 19000±800 ===\n");
    {
        auto ch = make_noise(2, 0x9ABCDEF0ull, 0.5);
        fir_apply(ch[0], brickwall(19000.0));
        fir_apply(ch[1], brickwall(19000.0));
        auto p = ptrs(ch);
        const LosslessCheck c = check_lossless(p.data(), 2, kN, kFs, 16);
        printf("  %s\n", brief(c).c_str());
        check(c.suspected, "suspected = true");
        check(std::fabs(c.cutoffHz - 19000.0) <= 800.0, "cutoffHz = 19000 ±800", brief(c));
    }

    printf("\n=== 4. 缓和滚降（−3 dB @18k、2 阶 Butterworth 缓坡）→ 不判假 ===\n");
    {
        auto ch = make_noise(2, 0x55AA55AAull, 0.5);
        // 每声道独立的滤波器实例 —— 共享实例会让状态机按 2 倍速率步进，
        // 输出变成抽取后的多相混合（高频镜像只降 10 dB，完全污染频谱）
        Biquad lp0, lp1;
        biquad_design::lowpass(lp0, kFs, 18000.0, 0.70710678);
        biquad_design::lowpass(lp1, kFs, 18000.0, 0.70710678);
        for (size_t i = 0; i < kN; ++i) { ch[0][i] = lp0.process(ch[0][i]); ch[1][i] = lp1.process(ch[1][i]); }
        auto p = ptrs(ch);
        const LosslessCheck c = check_lossless(p.data(), 2, kN, kFs, 16);
        printf("  %s\n", brief(c).c_str());
        check(!c.suspected, "suspected = false（缓坡必须放过）");
    }

    printf("\n=== 4b. 截止可见但下降沿缓和（4 阶 Butterworth ≈30 dB/oct，−40 dB 点 ≈12k）→ 陡沿门拦下 ===\n");
    {
        // IIR 在接近奈奎斯特处因双线性零点而急剧变陡，「有截止但边沿缓和」的场景必须把
        // 转折频率放低才成立。4 阶 Butterworth 在 −40 dB 点附近局部斜率只有 ~30 dB/oct，
        // 换算 1/6 倍频程仅 ~5 dB，过不了 >12 dB 陡沿门 —— 专门证明「有截止≠判假」。
        auto ch = make_noise(2, 0x77777777ull, 0.5);
        const double f0 = 3400.0;
        const double Q[2] = { 0.541196, 1.306563 };
        Biquad bq[2][2];
        for (int k = 0; k < 2; ++k) {
            biquad_design::lowpass(bq[k][0], kFs, f0, Q[k]);
            biquad_design::lowpass(bq[k][1], kFs, f0, Q[k]);
        }
        for (size_t i = 0; i < kN; ++i) {
            ch[0][i] = bq[0][1].process(bq[0][0].process(ch[0][i]));
            ch[1][i] = bq[1][1].process(bq[1][0].process(ch[1][i]));
        }
        auto p = ptrs(ch);
        const LosslessCheck c = check_lossless(p.data(), 2, kN, kFs, 16);
        printf("  %s\n", brief(c).c_str());
        check(!c.suspected, "suspected = false（陡沿门生效）");
        check(c.cutoffHz > 9000.0 && c.cutoffHz < 16000.0, "截止确实被检出（9000 < cutoff < 16000）", brief(c));
        check(c.reason.find("缓和") != std::string::npos, "拒绝原因 = 下降沿缓和（不是没检出）");
    }

    printf("\n=== 5. fake24bit：16-bit 内容 <<8 装入 24-bit → true；加 1 LSB 抖动 → false ===\n");
    {
        // 5a：确定性 16-bit 量化，再左移 8 位装 24-bit 容器
        auto ch = make_noise(1, 0x0F0F0F0Full, 0.5);
        Rng rng(42);
        for (size_t i = 0; i < kN; ++i) {
            long long v16 = (long long)std::llround(ch[0][i] * 32767.0);
            v16 = std::max(-32768ll, std::min(32767ll, v16));
            ch[0][i] = (double)(v16 << 8) / 8388608.0;
        }
        auto p = ptrs(ch);
        const LosslessCheck a = check_lossless(p.data(), 1, kN, kFs, 24);
        printf("  5a %s\n", brief(a).c_str());
        check(a.fake24bit, "fake24bit = true（低 8 位恒零）");

        // 5b：同信号叠加 ±1 LSB(24bit) 抖动 —— 低 8 位被激活，占比跌到 ~1/3
        for (size_t i = 0; i < kN; ++i)
            ch[0][i] += (double)((long long)(rng.next() % 3) - 1) / 8388608.0;
        const LosslessCheck b2 = check_lossless(p.data(), 1, kN, kFs, 24);
        printf("  5b %s\n", brief(b2).c_str());
        check(!b2.fake24bit, "加 1 LSB 抖动后 fake24bit = false");
    }

    // ---------------- §6 真无损负向对照（mac 新增，任务书判据 3） ----------------
    printf("\n=== 6. 【负向对照】真无损音乐形态 × 3 采样率 → 一律不许判假 ===\n");
    printf("  （信号：谐波簇 + 铺满奈奎斯特的 −72 dBFS 噪声底 + 14~20 kHz 弱簇 + 温和 −12 dB/oct 高频滚降）\n");
    {
        struct Case { double fs; const char* tag; };
        const Case cases[] = {
            { 44100.0, "44.1k" },
            { 48000.0, "48k"   },
            { 96000.0, "96k"   },
        };
        for (const Case& cs : cases) {
            const size_t n = (size_t)(20.0 * cs.fs);
            std::vector<double> mono = make_true_lossless_music(cs.fs, n, 0x5EED0001ull);
            quantize_true24(mono, 0xC0FFEEull + (uint64_t)cs.fs);
            std::vector<std::vector<double>> ch(2, mono);   // 左右同源（真实立体声的截止特征同理）
            auto p = ptrs(ch);
            const LosslessCheck c = check_lossless(p.data(), 2, n, cs.fs, 24);
            printf("  %s %s\n", cs.tag, brief(c).c_str());
            check(!c.suspected, std::string("真无损不得判假（") + cs.tag + "）", brief(c));
            check(!c.fake24bit, std::string("真 24-bit 容器不得判 fake24（") + cs.tag + "）", brief(c));
        }
    }

    // ---------------- §7 假无损正向对照：真实有损编码往返（mac 新增） ----------------
    printf("\n=== 7. 【正向对照】真无损信号 → 真实有损编码往返 → 必须抓到 ===\n");
    {
        const ToolProbe ff = probe_tool("ffmpeg");
        if (!ff.usable) {
            skip("真实有损编码往返", ff.why + "；本机系统 ffmpeg 已坏（缺 libx265，-version 退出 134），"
                                       "可用件应在 build-mac/ffmpeg-lite/ —— 本项按铁律 3 明确 SKIP，不判红");
        } else {
            printf("  工具自检通过：%s\n", ff.path.c_str());
            const size_t n = (size_t)(20.0 * kFs);
            std::vector<double> mono = make_true_lossless_music(kFs, n, 0x5EED0002ull);
            quantize_true24(mono, 0xBEEF01ull);

            // 先写 24-bit WAV 源（手写 44 字节头，避免依赖 src/audio）
            const std::string srcWav = "/tmp/rta_fl_src.wav";
            {
                FILE* f = std::fopen(srcWav.c_str(), "wb");
                if (!f) {
                    skip("真实有损编码往返", "无法写临时 WAV: " + srcWav);
                } else {
                    const uint32_t dataBytes = (uint32_t)mono.size() * 3;
                    uint8_t h[44];
                    std::memcpy(h, "RIFF", 4);
                    const uint32_t riffLen = 36 + dataBytes;
                    h[4] = (uint8_t)riffLen; h[5] = (uint8_t)(riffLen >> 8);
                    h[6] = (uint8_t)(riffLen >> 16); h[7] = (uint8_t)(riffLen >> 24);
                    std::memcpy(h + 8, "WAVE", 4);
                    std::memcpy(h + 12, "fmt ", 4);
                    h[16] = 16; h[17] = 0; h[18] = 0; h[19] = 0;
                    h[20] = 1; h[21] = 0;                      // PCM
                    h[22] = 1; h[23] = 0;                      // 单声道
                    const uint32_t rate = (uint32_t)kFs;
                    h[24] = (uint8_t)rate; h[25] = (uint8_t)(rate >> 8);
                    h[26] = (uint8_t)(rate >> 16); h[27] = (uint8_t)(rate >> 24);
                    const uint32_t byteRate = rate * 3;
                    h[28] = (uint8_t)byteRate; h[29] = (uint8_t)(byteRate >> 8);
                    h[30] = (uint8_t)(byteRate >> 16); h[31] = (uint8_t)(byteRate >> 24);
                    h[32] = 3; h[33] = 0;                      // blockAlign
                    h[34] = 24; h[35] = 0;                     // bits
                    std::memcpy(h + 36, "data", 4);
                    h[40] = (uint8_t)dataBytes; h[41] = (uint8_t)(dataBytes >> 8);
                    h[42] = (uint8_t)(dataBytes >> 16); h[43] = (uint8_t)(dataBytes >> 24);
                    std::fwrite(h, 1, 44, f);
                    for (double v : mono) {
                        long long q = (long long)std::llround(v * 8388608.0);
                        if (q > 8388607) q = 8388607;
                        if (q < -8388608) q = -8388608;
                        const uint8_t b[3] = { (uint8_t)(q & 0xFF), (uint8_t)((q >> 8) & 0xFF),
                                               (uint8_t)((q >> 16) & 0xFF) };
                        std::fwrite(b, 1, 3, f);
                    }
                    std::fclose(f);

                    // 编码组合的选择依据（2026-10-26 实测，不是拍脑袋）：
                    //   MP3 320k  → 截止 20.19 kHz、下降 60 dB ⟹ 必须抓到（正向对照）
                    //   AAC  96k  → 截止 20.09 kHz、下降 46 dB ⟹ 必须抓到（正向对照）
                    //   AAC 256k  → **实测没有可检出的截止**（18.6 kHz 处仅 −20 dB，
                    //               全带保留），检测器按"宁可漏报"设计就不报 ⟹ 记 KNOWN
                    struct Enc { const char* ext; const char* args; const char* tag; bool mustDetect; };
                    const Enc encs[] = {
                        { ".mp3", "-c:a libmp3lame -b:a 320k", "MP3 320k（libmp3lame）", true  },
                        { ".m4a", "-c:a aac -b:a 96k",         "AAC 96k",                true  },
                        { ".m4a", "-c:a aac -b:a 256k",        "AAC 256k",               false },
                    };
                    for (const Enc& e : encs) {
                        const std::string enc = "/tmp/rta_fl_enc" + std::string(e.ext);
                        const std::string dec = "/tmp/rta_fl_dec" + std::string(e.ext) + ".wav";
                        const std::string c1 = "\"" + ff.path + "\" -hide_banner -loglevel error -y -i \"" +
                                               srcWav + "\" " + e.args + " \"" + enc + "\"";
                        const int rc1 = std::system(c1.c_str());
                        if (rc1 != 0) {
                            skip(std::string("有损往返：") + e.tag,
                                 "编码失败（退出码 " + std::to_string(rc1) + "），编码器可能未内置");
                            continue;
                        }
                        const std::string c2 = "\"" + ff.path + "\" -hide_banner -loglevel error -y -i \"" +
                                               enc + "\" -c:a pcm_s24le \"" + dec + "\"";
                        const int rc2 = std::system(c2.c_str());
                        if (rc2 != 0) {
                            skip(std::string("有损往返：") + e.tag,
                                 "解码失败（退出码 " + std::to_string(rc2) + "）");
                            continue;
                        }
                        // 读回解出的 WAV。
                        // ★ 第一版踩的坑（如实记录）：以为是"44 字节规范头 + data 紧跟其后"，
                        //   实测 ffmpeg 写出的是 **WAVE_FORMAT_EXTENSIBLE (0xFFFE)** + `fmt ` 块 40 字节
                        //   + `LIST/INFO` 块，`data` 根本不在偏移 36 —— 按固定偏移读会读到
                        //   LIST 里的 "INFOISFT..." 当样本，帧数算成 1/3，直接"样本不足"。
                        //   所以这里必须**真走 chunk 链表**（RIFF 语义本来就是这样）。
                        std::vector<double> back;
                        {
                            FILE* f = std::fopen(dec.c_str(), "rb");
                            if (!f) { skip(std::string("有损往返：") + e.tag, "解出的 WAV 读不回"); continue; }
                            std::vector<uint8_t> whole;
                            {
                                uint8_t buf[65536];
                                size_t got = 0;
                                while ((got = std::fread(buf, 1, sizeof(buf), f)) > 0)
                                    whole.insert(whole.end(), buf, buf + got);
                            }
                            std::fclose(f);
                            auto rd32 = [&](size_t off) -> uint32_t {
                                if (off + 4 > whole.size()) return 0;
                                return (uint32_t)whole[off] | ((uint32_t)whole[off + 1] << 8) |
                                       ((uint32_t)whole[off + 2] << 16) | ((uint32_t)whole[off + 3] << 24);
                            };
                            auto rd16 = [&](size_t off) -> uint16_t {
                                if (off + 2 > whole.size()) return 0;
                                return (uint16_t)((uint32_t)whole[off] | ((uint32_t)whole[off + 1] << 8));
                            };
                            uint16_t fmtTag = 0, chn = 0, bits = 0;
                            size_t dataOff = 0;
                            uint32_t dataLen = 0;
                            if (whole.size() >= 12 &&
                                std::memcmp(whole.data(), "RIFF", 4) == 0 &&
                                std::memcmp(whole.data() + 8, "WAVE", 4) == 0) {
                                size_t pos = 12;
                                while (pos + 8 <= whole.size()) {
                                    const uint32_t clen = rd32(pos + 4);
                                    const size_t body = pos + 8;
                                    if (std::memcmp(whole.data() + pos, "fmt ", 4) == 0) {
                                        fmtTag = rd16(body);
                                        chn    = rd16(body + 2);
                                        bits   = rd16(body + 14);
                                        // 0xFFFE = WAVE_FORMAT_EXTENSIBLE：真实格式藏在 SubFormat GUID
                                        // 前 2 字节（见 AGENTS 记录的 A-1 教训：gemini 当年就栽在这）
                                        if (fmtTag == 0xFFFE && clen >= 40) fmtTag = rd16(body + 24);
                                    } else if (std::memcmp(whole.data() + pos, "data", 4) == 0) {
                                        dataOff = body;
                                        dataLen = clen;
                                        break;
                                    }
                                    pos = body + clen + (clen & 1u);   // 奇数块有 1 字节 padding
                                }
                            }
                            const size_t bps = (size_t)(bits / 8);
                            if (fmtTag != 1 || bits != 24 || chn < 1 || bps == 0 ||
                                dataOff + dataLen > whole.size() || dataLen < bps * chn) {
                                skip(std::string("有损往返：") + e.tag,
                                     "解出的 WAV 头不符合预期（fmtTag=" + std::to_string(fmtTag) +
                                     " bits=" + std::to_string(bits) + " ch=" + std::to_string(chn) +
                                     " dataLen=" + std::to_string(dataLen) + "）");
                                continue;
                            }
                            const size_t frames = dataLen / (bps * chn);
                            back.resize(frames);
                            for (size_t i = 0; i < frames; ++i) {
                                const size_t off = dataOff + i * bps * chn;
                                const int32_t q = (int32_t)((uint32_t)whole[off] |
                                                            ((uint32_t)whole[off + 1] << 8) |
                                                            ((uint32_t)whole[off + 2] << 16));
                                const int32_t s24 = (q & 0x800000) ? (q | (int32_t)0xFF000000) : q;
                                back[i] = (double)s24 / 8388608.0;
                            }
                        }
                        if (back.size() < 65536) {
                            skip(std::string("有损往返：") + e.tag, "解码样本不足一个分析窗");
                            continue;
                        }
                        std::vector<std::vector<double>> bch(1, back);
                        auto bp = ptrs(bch);
                        const LosslessCheck c = check_lossless(bp.data(), 1, back.size(), kFs, 24);
                        printf("  %s → %s\n", e.tag, brief(c).c_str());
                        if (e.mustDetect) {
                            check(c.suspected, std::string(e.tag) + " 的有损转制必须被判假", brief(c));
                            check(c.confidence >= 0.5, std::string(e.tag) + " confidence ≥ 0.5", brief(c));
                            // 编码器的截止通常落在 15~20.5 kHz（320k mp3 可到 20 kHz 附近）
                            check(c.cutoffHz > 1000.0 && c.cutoffHz < 20500.0,
                                  std::string(e.tag) + " cutoff 落在合理区间（1k~20.5k）", brief(c));
                        } else {
                            // ⚠️ 已知漏报边界（铁律 4）：这一档**实测就是没有可检出的截止**，
                            //    检测器按「宁可漏报不可误报」不报是**设计正确**。
                            //    这里只把事实钉住：既不断言"抓到了"（那是谎报），
                            //    也不断言"必须抓不到"（那会把未来的改进当成回归）。
                            known(std::string(e.tag) + " 实测无可检出截止（已知漏报边界）", brief(c));
                        }
                    }
                    // 调试用：RTA_KEEP_TMP=1 时保留源/中间文件，便于用 ffmpeg 做码率扫描
                    // （2026-10-26 用它定位「AAC 在 320k/256k 下检不出截止」的边界）
                    if (!std::getenv("RTA_KEEP_TMP")) {
                        std::remove(srcWav.c_str());
                        std::remove("/tmp/rta_fl_enc.mp3");
                        std::remove("/tmp/rta_fl_enc.m4a");
                        std::remove("/tmp/rta_fl_dec.mp3.wav");
                        std::remove("/tmp/rta_fl_dec.m4a.wav");
                    }
                }
            }
        }
    }

    printf("\n%s (失败项 %d，跳过 %d，已知边界 %d)\n",
           fails == 0 ? "全部通过" : "存在失败", fails, skips, knowns);
    return fails == 0 ? 0 : 1;
}
