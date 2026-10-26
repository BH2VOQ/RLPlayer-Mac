// test_dynamics.cpp — 音频体检 B1a：动态分析器合成信号验证
//
// 全部信号现场合成、完全离线（不开设备、不解码真实文件），判据确定性可复现。
// 锚点：BS.1770 官方校准点（997 Hz / −23 dBFS / 立体声 ⟹ −23.0 LUFS）必须过。
//
// ---------------- macOS 移植（2026-10-26，上游 68e628f v1.5.2 → 本库）----------------
// 上游 §1~§6 逐条保留（判据阈值一字未改），**新增 §7 边界组**：
//   静音 / 极短文件（< 400 ms）/ 单声道 / 零长 / 非法 fs —— 任务书判据 4 要求
//   「不许崩，且给出合理值」。上游没有这组（它在 mac 与 Windows 上都不会崩，
//   只是没人测过），这里按 mac 实测补上，并把「什么算合理值」写成可核对的断言。
//
// 平台差异：本测试零 Win32 依赖（纯 std::vector + <cstdio>），mac 上原样可跑。
// 唯一的写法调整是 `setvbuf(..., _IONBF, ...)` 保留不动（POSIX 同样支持）。
#include "analysis/dynamics.h"
#include <cstdio>
#include <cmath>
#include <string>
#include <vector>

using namespace rta::analysis;
using rta::dsp::kPi;

static int fails = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++fails;
}

static std::vector<std::vector<double>> make_sine(int channels, size_t n, double fs, double hz, double amp) {
    std::vector<std::vector<double>> ch((size_t)channels, std::vector<double>(n));
    for (int c = 0; c < channels; ++c)
        for (size_t i = 0; i < n; ++i)
            ch[(size_t)c][i] = amp * std::sin(2.0 * kPi * hz * (double)i / fs);
    return ch;
}

static std::vector<const double*> ptrs(const std::vector<std::vector<double>>& ch) {
    std::vector<const double*> p;
    for (const auto& c : ch) p.push_back(c.data());
    return p;
}

// 直接用 ITU 表 48 kHz 系数算级联响应（dB）—— 与重标定实现独立比对，防变换代数写错
static double itu48_response_db(double hz) {
    static const double sb[3] = { 1.53512485958697, -2.69169618940638, 1.19839281085285 };
    static const double sa[3] = { 1.0, -1.69065929318241, 0.73248077421585 };
    static const double hb[3] = { 1.0, -2.0, 1.0 };
    static const double ha[3] = { 1.0, -1.99004745483398, 0.99007225036621 };
    const double w = 2.0 * kPi * hz / 48000.0;
    const double c1 = std::cos(w), s1 = std::sin(w);
    const double c2 = std::cos(2.0 * w), s2 = std::sin(2.0 * w);
    auto mag = [&](const double b[3], const double a[3]) {
        const double nr = b[0] + b[1] * c1 + b[2] * c2, ni = -(b[1] * s1 + b[2] * s2);
        const double dr = 1.0 + a[1] * c1 + a[2] * c2, di = -(a[1] * s1 + a[2] * s2);
        return std::sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
    };
    return 20.0 * std::log10(mag(sb, sa) * mag(hb, ha) + 1e-300);
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    const double fs = 48000.0;

    printf("=== 1. K 加权系数校验（48 kHz 应与 ITU-R BS.1770-4 表 1 一致）===\n");
    {
        rta::dsp::Biquad shelf, hp;
        k_weight_biquads(fs, shelf, hp);
        double maxDiff = 0.0;
        std::string resp = "(kHz: ";
        for (double hz : {20.0, 100.0, 500.0, 997.0, 4000.0, 10000.0, 20000.0}) {
            const double mine = shelf.response_db(hz / (fs * 0.5)) + hp.response_db(hz / (fs * 0.5));
            const double ref = itu48_response_db(hz);
            maxDiff = std::max(maxDiff, std::fabs(mine - ref));
            char one[64];
            std::snprintf(one, sizeof(one), "%.1f:%+.4f ", hz / 1000.0, mine);
            resp += one;
        }
        printf("  %s]\n", resp.c_str());
        char b[200];
        std::snprintf(b, sizeof(b), "(max|Δ| = %.2e dB，997 Hz K 增益 %+.4f dB)", maxDiff,
                      shelf.response_db(997.0 / (fs * 0.5)) + hp.response_db(997.0 / (fs * 0.5)));
        check(maxDiff < 1e-6, "48 kHz 全频点与规范表一致", b);
    }

    printf("\n=== 2. 官方校准点：997 Hz / −23 dBFS / 立体声 → LUFS = −23.0 ±0.1 ===\n");
    {
        const size_t n = (size_t)(10.0 * fs);
        auto ch = make_sine(2, n, fs, 997.0, std::pow(10.0, -23.0 / 20.0));
        auto p = ptrs(ch);
        const DynamicsResult r = measure_dynamics(p.data(), 2, n, fs);
        char b[200];
        std::snprintf(b, sizeof(b), "(LUFS %.3f, LRA %.3f LU, DR %.3f dB, peak %.3f dBFS)",
                      r.lufsIntegrated, r.lra, r.drDb, r.peakDbfs);
        printf("  %s\n", b);
        check(r.valid, "valid 标志");
        check(std::fabs(r.lufsIntegrated - (-23.0)) <= 0.1, "LUFS = −23.0 ±0.1（官方校准点）", b);
        check(r.lra <= 1.0, "稳态正弦 LRA ≤ 1.0", b);
        check(std::fabs(r.drDb - 3.0) <= 0.5, "DR = 3.0 ±0.5（正弦峰值/RMS = √2）", b);
    }

    // ---------------- §2b TT DR 口径判别（mac 新增：抓"块 RMS 平均"这个经典错误） ----------------
    printf("\n=== 2b. TT DR 口径判别：块幅度不等时，合并样本 RMS ≠ 块 RMS 平均 ===\n");
    printf("  （这是本文件头注第 1 条点名的经典实现错误；§2 的稳态正弦**区分不出来**，必须专门测）\n");
    {
        // 构造：30 s 单声道 = 10 个 3 秒块（nSel = 10/5 = 2，正好取前 2 块）。
        //   块 0 幅度 A1=1.0，块 1 幅度 A2=0.1，块 2..9 幅度 A3=0.01（安静，不会被选中）
        // 解析真值（正弦块 RMS = a/√2）：
        //   合并样本口径（正确）：rms2 = √((A1²+A2²)/4) = √((1+0.01)/4) = 0.502494
        //                          DR = 20log10(1.0/0.502494) = 5.976 dB
        //   块 RMS 平均口径（错误）：rms2 = (A1+A2)/(2√2) = 1.1/2.828427 = 0.388909
        //                          DR = 20log10(1.0/0.388909) = 8.203 dB
        // 两者差 2.23 dB ⟹ 用 ±0.3 dB 的窗口就能**唯一判定**用的是哪条口径。
        // （第一版本测试只测了稳态正弦，两种口径结果相同，实测变异测试抓不到，
        //   故补这一节 —— 铁律 3：判据必须能证明它要证明的事。）
        const double fs30 = 48000.0;
        const size_t blockN = (size_t)std::llround(3.0 * fs30);
        const size_t nBlocks = 10;
        const size_t n30 = blockN * nBlocks;
        std::vector<std::vector<double>> ch(1, std::vector<double>(n30));
        const double A1 = 1.0, A2 = 0.1, A3 = 0.01;
        for (size_t i = 0; i < n30; ++i) {
            const size_t blk = i / blockN;
            const double a = (blk == 0) ? A1 : (blk == 1 ? A2 : A3);
            ch[0][i] = a * std::sin(2.0 * kPi * 997.0 * (double)i / fs30);
        }
        auto p30 = ptrs(ch);
        const DynamicsResult r = measure_dynamics(p30.data(), 1, n30, fs30);

        const double truthMerged = 20.0 * std::log10(A1 / std::sqrt((A1 * A1 + A2 * A2) / 4.0));
        const double truthMeanOfRms = 20.0 * std::log10(A1 / ((A1 + A2) / (2.0 * std::sqrt(2.0))));
        char b[256];
        std::snprintf(b, sizeof(b),
                      "(实测 DR %.4f dB；合并样本真值 %.4f dB；块RMS平均真值 %.4f dB；两者差 %.2f dB)",
                      r.drDb, truthMerged, truthMeanOfRms, truthMeanOfRms - truthMerged);
        printf("  %s\n", b);
        check(std::fabs(r.drDb - truthMerged) <= 0.3,
              "DR 命中「合并样本 RMS」真值 ±0.3 dB（正确口径）", b);
        check(std::fabs(r.drDb - truthMeanOfRms) > 1.0,
              "DR 明确偏离「块 RMS 平均」真值 >1 dB（排除了经典错误口径）", b);
    }

    printf("\n=== 3. 1 kHz / −12 dBFS / 单声道 → 峰值与 DR ===\n");
    {
        const size_t n = (size_t)(10.0 * fs);
        auto ch = make_sine(1, n, fs, 1000.0, std::pow(10.0, -12.0 / 20.0));
        auto p = ptrs(ch);
        const DynamicsResult r = measure_dynamics(p.data(), 1, n, fs);
        char b[200];
        std::snprintf(b, sizeof(b), "(peak %.4f dBFS, DR %.3f dB, LUFS %.3f)",
                      r.peakDbfs, r.drDb, r.lufsIntegrated);
        printf("  %s\n", b);
        check(std::fabs(r.peakDbfs - (-12.0)) <= 0.05, "peakDbfs = −12.0 ±0.05", b);
        check(std::fabs(r.drDb - 3.0) <= 0.5, "DR = 3.0 ±0.5", b);
    }

    printf("\n=== 4. 响度差 20 dB 的两段交替正弦（各 4 s × 6 段）→ LRA > 10 ===\n");
    {
        const double segSec = 4.0, segs = 6.0;
        const size_t segN = (size_t)(segSec * fs);
        const size_t n = segN * (size_t)segs;
        std::vector<std::vector<double>> ch(1, std::vector<double>(n));
        const double aLoud = std::pow(10.0, -12.0 / 20.0), aQuiet = std::pow(10.0, -32.0 / 20.0);
        for (size_t i = 0; i < n; ++i) {
            const size_t seg = i / segN;                       // 0,2,4 响；1,3,5 轻
            const double amp = (seg % 2 == 0) ? aLoud : aQuiet;
            ch[0][i] = amp * std::sin(2.0 * kPi * 997.0 * (double)i / fs);   // 相位连续
        }
        auto p = ptrs(ch);
        const DynamicsResult r = measure_dynamics(p.data(), 1, n, fs);
        char b[200];
        std::snprintf(b, sizeof(b), "(LRA %.3f LU, 积分 %.3f LUFS)", r.lra, r.lufsIntegrated);
        printf("  %s\n", b);
        check(r.lra > 10.0, "LRA > 10（20 dB 交替应拉开分布）", b);
    }

    printf("\n=== 5. 满幅方波 → DR = 0 ±0.5（peak/RMS = 1）===\n");
    {
        const size_t n = (size_t)(10.0 * fs);
        std::vector<std::vector<double>> ch(1, std::vector<double>(n));
        for (size_t i = 0; i < n; ++i) ch[0][i] = (i % 48 < 24) ? 1.0 : -1.0;   // 1 kHz 方波 ±满幅
        auto p = ptrs(ch);
        const DynamicsResult r = measure_dynamics(p.data(), 1, n, fs);
        char b[200];
        std::snprintf(b, sizeof(b), "(DR %.4f dB, peak %.4f dBFS, LUFS %.3f)",
                      r.drDb, r.peakDbfs, r.lufsIntegrated);
        printf("  %s\n", b);
        check(std::fabs(r.drDb - 0.0) <= 0.5, "DR = 0 ±0.5", b);
        check(std::fabs(r.peakDbfs) < 1e-9, "peak = 0 dBFS", b);
    }

    printf("\n=== 6. K 加权重标定跨采样率校准（44.1/96/192k 同一校准点）===\n");
    {
        // Tustin 重标定的意义就在这里：任何 fs 下官方校准点都必须守住
        for (double rate : {44100.0, 96000.0, 192000.0}) {
            const size_t n = (size_t)(10.0 * rate);
            auto ch = make_sine(2, n, rate, 997.0, std::pow(10.0, -23.0 / 20.0));
            auto p = ptrs(ch);
            const DynamicsResult r = measure_dynamics(p.data(), 2, n, rate);
            char b[128];
            std::snprintf(b, sizeof(b), "(fs=%.0f, LUFS %.3f)", rate, r.lufsIntegrated);
            check(std::fabs(r.lufsIntegrated - (-23.0)) <= 0.1, "LUFS = −23.0 ±0.1", b);
        }
    }

    // ---------------- §7 边界组（mac 新增，任务书判据 4） ----------------
    printf("\n=== 7. 边界：静音 / 极短 / 单声道 / 零长 / 非法参数（不许崩，且值合理）===\n");

    printf("  --- 7a. 全静音 10 s 立体声 ---\n");
    {
        const size_t n = (size_t)(10.0 * fs);
        auto ch = make_sine(2, n, fs, 997.0, 0.0);   // 振幅 0 = 全零
        auto p = ptrs(ch);
        const DynamicsResult r = measure_dynamics(p.data(), 2, n, fs);
        char b[220];
        std::snprintf(b, sizeof(b), "(valid=%d, peak %.1f dBFS, LUFS %.1f, DR %.3f, LRA %.3f)",
                      (int)r.valid, r.peakDbfs, r.lufsIntegrated, r.drDb, r.lra);
        printf("  %s\n", b);
        // 「合理值」的口径：静音没有可测响度 ⟹ LUFS 落到 −300 哨兵值，不是 0.0（0.0 会被误读成"满响度"）；
        // 峰值同理；DR/LRA 无定义保持 0。valid 仍为 true（块结构成立，只是全在门限下）。
        check(r.valid, "静音仍返回 valid=true（块结构成立）", b);
        check(r.peakDbfs <= -299.0, "peakDbfs 落到 −300 哨兵（不是 0 dBFS）", b);
        check(r.lufsIntegrated <= -299.0, "LUFS 落到 −300 哨兵（不是 0 LUFS）", b);
        check(r.drDb == 0.0, "DR = 0（静音无峰值，不参与取较低者）", b);
        check(r.lra == 0.0, "LRA = 0（无短时窗过门）", b);
    }

    printf("  --- 7b. 极短文件：200 ms（< 400 ms 分析块）---\n");
    {
        const size_t n = (size_t)(0.2 * fs);          // 9600 样本
        auto ch = make_sine(2, n, fs, 997.0, std::pow(10.0, -20.0 / 20.0));
        auto p = ptrs(ch);
        const DynamicsResult r = measure_dynamics(p.data(), 2, n, fs);
        char b[220];
        std::snprintf(b, sizeof(b), "(n=%zu, valid=%d, peak %.3f dBFS, LUFS %.1f, DR %.3f, LRA %.3f)",
                      n, (int)r.valid, r.peakDbfs, r.lufsIntegrated, r.drDb, r.lra);
        printf("  %s\n", b);
        // 口径：< 400 ms 装不下一个积分块 ⟹ valid=false（如实说"测不出"），但峰值仍必须对
        check(!r.valid, "valid=false（< 400 ms 装不下积分块）", b);
        check(std::fabs(r.peakDbfs - (-20.0)) <= 0.1, "峰值仍算对（−20 dBFS ±0.1）", b);
        check(r.drDb == 0.0 && r.lra == 0.0, "DR/LRA = 0（< 3 s 口径不成立）", b);
        check(r.lufsIntegrated == 0.0, "LUFS = 0（未计算；与 valid=false 配对，不会被当成 0 LUFS 响度）", b);
    }

    printf("  --- 7c. 极短文件：正好 400 ms（边界，应刚好 valid）---\n");
    {
        const size_t n = (size_t)std::llround(0.4 * fs);   // 19200 样本
        auto ch = make_sine(2, n, fs, 997.0, std::pow(10.0, -20.0 / 20.0));
        auto p = ptrs(ch);
        const DynamicsResult r = measure_dynamics(p.data(), 2, n, fs);
        char b[220];
        std::snprintf(b, sizeof(b), "(n=%zu, valid=%d, LUFS %.3f)", n, (int)r.valid, r.lufsIntegrated);
        printf("  %s\n", b);
        check(r.valid, "valid=true（刚好一个 400 ms 块）", b);
        check(std::fabs(r.lufsIntegrated - (-20.0)) <= 0.3, "LUFS ≈ −20 ±0.3（单块，门限后仍准）", b);
    }

    printf("  --- 7d. 单声道：与立体声同源信号，LUFS 应低 3.01 dB ---\n");
    {
        const size_t n = (size_t)(10.0 * fs);
        const double amp = std::pow(10.0, -23.0 / 20.0);
        auto chM = make_sine(1, n, fs, 997.0, amp);
        auto chS = make_sine(2, n, fs, 997.0, amp);
        auto pM = ptrs(chM);
        auto pS = ptrs(chS);
        const DynamicsResult rm = measure_dynamics(pM.data(), 1, n, fs);
        const DynamicsResult rs = measure_dynamics(pS.data(), 2, n, fs);
        char b[220];
        std::snprintf(b, sizeof(b), "(单声道 LUFS %.3f vs 立体声 %.3f，差 %.3f dB)",
                      rm.lufsIntegrated, rs.lufsIntegrated, rs.lufsIntegrated - rm.lufsIntegrated);
        printf("  %s\n", b);
        // 声学真值：两路同相正弦功率相加 ⟹ +3.01 dB。这条同时证明"声道是求和而不是取平均"
        check(std::fabs((rs.lufsIntegrated - rm.lufsIntegrated) - 3.0103) <= 0.15,
              "立体声比单声道高 3.01 dB ±0.15（功率相加，非取平均）", b);
        check(std::fabs(rm.drDb - 3.0) <= 0.5, "单声道 DR = 3.0 ±0.5", b);
    }

    printf("  --- 7e. 零长 / 空指针 / 非法 fs：一律返回 valid=false，不崩 ---\n");
    {
        std::vector<double> empty;
        const double* p1[1] = { empty.data() };
        const DynamicsResult r1 = measure_dynamics(p1, 1, 0, fs);
        check(!r1.valid, "n=0 → valid=false");

        const DynamicsResult r2 = measure_dynamics(nullptr, 2, 1000, fs);
        check(!r2.valid, "ch=nullptr → valid=false");

        auto ch = make_sine(2, 4800, fs, 997.0, 0.5);
        auto p = ptrs(ch);
        const DynamicsResult r3 = measure_dynamics(p.data(), 0, 4800, fs);
        check(!r3.valid, "channels=0 → valid=false");

        const DynamicsResult r4 = measure_dynamics(p.data(), 2, 4800, 0.0);
        check(!r4.valid, "fs=0 → valid=false");

        const DynamicsResult r5 = measure_dynamics(p.data(), 2, 4800, -48000.0);
        check(!r5.valid, "fs<0 → valid=false");

        // 单边空声道指针：某一层为 nullptr 时该层跳过，其余层照常（不崩）
        const double* p6[2] = { p[0], nullptr };
        const DynamicsResult r6 = measure_dynamics(p6, 2, 4800, fs);
        check(!r6.valid, "第 2 声道 nullptr → 不崩，valid=false（样本不足一块）");
    }

    printf("\n%s (失败项 %d)\n", fails == 0 ? "全部通过" : "存在失败", fails);
    return fails == 0 ? 0 : 1;
}
