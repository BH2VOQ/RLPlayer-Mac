// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_room_correction.cpp — 房间校正 C1：全合成信号、确定性、完全离线（不开设备）
//
// 判据真值全部来自解析式（§2 的三部件功率响应），不依赖被测代码；
// 唯一用到被测函数构造的是「真值 IR 的时间域实现」（最小相位延迟版），
// 而断言比较的是解析幅度公式 —— 见 §2 说明（铁律 3：判据必须测到要证明的事）。
//
// ---------------- macOS 移植（2026-10-26，上游 68e628f v1.5.2 → 本库）----------------
// 上游 §1~§6 **逐条保留、阈值一字未改**（本文件本身零 Win32 依赖，mac 原样可跑）。
// 新增 §7 边界组：空输入 / taps=0 / 全零 IR / 极短 IR / 非法 fs / 非 2 的幂半谱 ——
// 这些是"校正链路拿到脏数据"时的现实情况（坏的测量文件、被截断的 IR），
// 上游没有覆盖。判据只要求「不崩 + 返回可判定的大小」，不虚构数值真值。
#include "dsp/room_correction.h"
#include <cstdio>
#include <cmath>
#include <string>
#include <vector>

using namespace rta::dsp;

static int fails = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++fails;
}

// FFT 线性卷积（测试专用；返回全长 m+s−1，无时域卷绕）
static std::vector<double> fft_convolve(const std::vector<double>& a, const std::vector<double>& b) {
    if (a.empty() || b.empty()) return {};
    const size_t need = a.size() + b.size() - 1;
    size_t n = 1;
    while (n < need) n <<= 1;
    std::vector<cplx> fa(n, cplx(0.0, 0.0)), fb(n, cplx(0.0, 0.0));
    for (size_t i = 0; i < a.size(); ++i) fa[i] = cplx(a[i], 0.0);
    for (size_t i = 0; i < b.size(); ++i) fb[i] = cplx(b[i], 0.0);
    fft(fa);
    fft(fb);
    for (size_t i = 0; i < n; ++i) fa[i] *= fb[i];
    fft(fa, true);
    std::vector<double> y(need);
    for (size_t i = 0; i < need; ++i) y[i] = fa[i].real();
    return y;
}

// 比较两个半谱幅度（dB）在 [fLo, fHi] 内的最大差；同时返回最大差所在频率
static double max_diff_db(const std::vector<double>& a, const std::vector<double>& b,
                          double fs, double fLo, double fHi, double* atHz = nullptr) {
    const double binHz = fs / (2.0 * (double)(a.size() - 1));
    double worst = -1e300, worstF = 0.0;
    for (size_t k = 0; k < a.size(); ++k) {
        const double f = (double)k * binHz;
        if (f < fLo || f > fHi) continue;
        const double d = std::fabs(a[k] - b[k]);
        if (d > worst) { worst = d; worstF = f; }
    }
    if (atHz) *atHz = worstF;
    return worst;
}

// ---- §2 解析真值：+4 dB 一阶低架@100 Hz × −3 dB 一阶高架@8 kHz × 0.5 ms −6 dB 梳状 ----
// 全部写在功率域 |H|²，三个部件独立推导，与被测实现零共享。
static double truth_p2(double f) {
    const double k1 = std::pow(10.0, 4.0 / 10.0), r1 = f / 100.0;
    const double a2 = std::pow(10.0, -3.0 / 10.0), r2 = f / 8000.0;
    const double g = std::pow(10.0, -6.0 / 20.0);
    const double p1 = k1 * (1.0 + r1 * r1) / (1.0 + k1 * r1 * r1);
    const double p2 = (1.0 + a2 * r2 * r2) / (1.0 + r2 * r2);
    const double p3 = 1.0 + g * g + 2.0 * g * std::cos(2.0 * kPi * f * 0.0005);
    return p1 * p2 * p3;
}
static double truth_db(double f) { return 10.0 * std::log10(std::max(truth_p2(f), 1e-12)); }

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    const double fs = 48000.0;

    printf("=== 1. 扫频回环：roomIr = δ，measured = sweep 本身 → 反卷积应还原 δ ===\n");
    {
        SweepSpec spec;                      // 48 kHz / 10 Hz~22050 Hz / 10 s
        auto sweep = generate_sweep(spec);
        auto ir = deconvolve_ir(sweep, sweep, fs);
        const size_t peak = ir_peak_index(ir);
        // 反卷积谱 H = |S|²/(|S|²+ε) 是实偶函数 ⟹ 恢复的 δ 关于 0 对称，负时间
        // 部分循环卷绕到数组末尾（index N−1 ≡ −1）。旁瓣必须在【循环距离】意义下
        // 排除主瓣邻域后再量。主瓣邻域取 ±16 样本（0.33 ms）：带限 δ 的 Gibbs
        // 振铃集中在这几样本内，是 10 Hz~22 kHz 带边的物理属性，不是反卷积误差；
        // 该邻域之外的能量才是反卷积/正则化自己引入的。
        const size_t guard = 16;
        const double pv = std::fabs(ir[peak]);
        size_t smax = 0;
        double side = 0.0;
        for (size_t i = 0; i < ir.size(); ++i) {
            const size_t d = std::min((i + ir.size() - peak) % ir.size(), (peak - i) % ir.size());
            if (d <= guard) continue;
            if (std::fabs(ir[i]) > side) { side = std::fabs(ir[i]); smax = i; }
        }
        char b[160];
        std::snprintf(b, sizeof(b), "(峰位 %zu，峰值 %.6f，旁瓣 %.1f dB @ %zu，样本数 %zu)",
                      peak, pv, 20.0 * std::log10(side / pv), smax, sweep.size());
        printf("  %s\n", b);
        check(peak <= 2, "峰在 0±2 样本内", b);
        check(20.0 * std::log10(side / pv) < -40.0, "主瓣 ±16 样本外旁瓣 < −40 dB", b);
    }

    printf("\n=== 2. 已知响应恢复：3 ms 延迟 + 双架 + 梳状 → 反卷积后幅度/延迟 ===\n");
    std::vector<double> roomIr;
    {
        // 真值 IR 的时间域实现：解析幅度 → 最小相位 → 平移 3 ms（144 样本）。
        // 幅度真值始终是上面的解析式；最小相位只负责给出一个可实现（因果）的
        // 时间域「房间」，不参与任何幅度判据。
        const size_t delay = 144, NR = 16384;
        std::vector<double> magLin(NR / 2 + 1);
        for (size_t k = 0; k <= NR / 2; ++k)
            magLin[k] = std::pow(10.0, truth_db((double)k * fs / NR) / 20.0);
        const auto hmp = minimum_phase_ir(magLin);
        roomIr.assign(NR, 0.0);
        for (size_t i = 0; i + delay < NR; ++i) roomIr[i + delay] = hmp[i];

        SweepSpec spec;
        auto sweep = generate_sweep(spec);
        auto measured = fft_convolve(sweep, roomIr);   // 全长线性卷积，无时域混叠
        auto ir = deconvolve_ir(measured, sweep, fs);

        const size_t peak = ir_peak_index(ir);
        char b[128];
        std::snprintf(b, sizeof(b), "(峰位 %zu，期望 144，误差 %+zd 样本)", peak, (ptrdiff_t)peak - 144);
        printf("  %s\n", b);
        check(peak >= 143 && peak <= 145, "延迟恢复 3 ms ±1 样本", b);

        // 幅度：平滑后与平滑后的解析真值比。
        // 判据说明（铁律 3）：梳状谷 −6 dB、间距 2 kHz，任何正确的 1/6 oct 平滑
        // 都会把谷「填」起来 —— 平滑后数据 vs 逐点解析式必然差 >1 dB（谷点实测见下），
        // 这不是反卷积的错，是平滑在履职。所以过判据必须双方同平滑：
        // 「平滑(反卷积结果) vs 平滑(解析真值)」才是在测反卷积本身。
        auto mag = ir_magnitude_db(ir, fs);
        auto raw = mag;
        psychoacoustic_smooth(mag, fs, 6.0, 6.0);      // 恒定 1/6 oct
        std::vector<double> truth(raw.size());
        const double binHz = fs / (2.0 * (double)(raw.size() - 1));
        for (size_t k = 0; k < raw.size(); ++k) truth[k] = truth_db((double)k * binHz);
        psychoacoustic_smooth(truth, fs, 6.0, 6.0);
        double atHz = 0.0;
        const double dSm = max_diff_db(mag, truth, fs, 100.0, 10000.0, &atHz);
        const double dRaw = max_diff_db(raw, truth, fs, 100.0, 10000.0, &atHz);
        char b2[160];
        std::snprintf(b2, sizeof(b2), "(平滑后 max|Δ| = %.4f dB @ %.0f Hz；未平滑 max|Δ| = %.2f dB @ %.0f Hz)",
                      dSm, atHz, dRaw, atHz);
        printf("  %s\n", b2);
        check(dSm <= 0.5, "100 Hz~10 kHz 平滑幅度与真值差 ≤0.5 dB", b2);
    }

    printf("\n=== 3. 校正闭环：tilt(−1 dB/oct) 目标 → conv(校正, 房间) 应贴合目标 ===\n");
    {
        CorrectionOpts copt;                 // +6 dB 限升 / fMax 16 kHz / 300 ms 窗 / 8192 taps
        auto corr = compute_correction_ir(roomIr, fs, TargetCurve::tilt(-1.0), copt);
        auto closed = fft_convolve(corr, roomIr);

        auto magC = ir_magnitude_db(closed, fs);
        psychoacoustic_smooth(magC, fs);                 // 与校正器设计同宽（默认 1/6→1/3）
        const auto tgt = target_curve_db(TargetCurve::tilt(-1.0), fs, magC.size());
        double atHz = 0.0;
        const double d = max_diff_db(magC, tgt, fs, 100.0, 10000.0, &atHz);
        // 信息项：固定 1/6 oct 验收的偏差（预期在梳状谷/峰处 ~±3 dB）——
        // 校正是在变宽心理声学平滑域里求的，宽窗有意不填人耳听不出来的窄谷
        // （REW 明确警告不要补听不见的谷），用更窄的尺子验收会把「设计选择」
        // 当成「误差」。过判据必须与设计用同一把尺子。
        auto magC6 = ir_magnitude_db(closed, fs);
        psychoacoustic_smooth(magC6, fs, 6.0, 6.0);
        const double d6 = max_diff_db(magC6, tgt, fs, 100.0, 10000.0, &atHz);
        char b[160];
        std::snprintf(b, sizeof(b), "(同宽验收 max|Δ| = %.4f dB @ %.0f Hz；固定 1/6 验收 %.4f dB，宽窗不填窄谷所致)",
                      d, atHz, d6);
        printf("  %s\n", b);
        check(d <= 1.5, "100 Hz~10 kHz 平滑幅度与 target 差 ≤1.5 dB", b);

        // 校正器自身频响：任意频率增益不得超过限升 + 0.5 dB 余量
        auto magCorr = ir_magnitude_db(corr, fs);
        double mx = -1e300;
        for (double v : magCorr) mx = std::max(mx, v);
        char b2[96];
        std::snprintf(b2, sizeof(b2), "(max 增益 %.4f dB @ %zu bins)", mx, magCorr.size());
        printf("  %s\n", b2);
        check(mx <= 6.5, "校正器任意频率增益 ≤ +6.5 dB", b2);
    }

    printf("\n=== 4. 超低对齐：主 10 ms / 超低 22 ms 且带内 −3 dB → 12 ms / +3 dB ===\n");
    {
        const size_t n1s = (size_t)fs;       // 1 s 缓冲
        std::vector<double> mainIr(n1s, 0.0), subIr(n1s, 0.0);
        mainIr[480] = 1.0;                                       // 主 10 ms
        subIr[1056] = std::pow(10.0, -3.0 / 20.0);               // 超低 22 ms，−3 dB
        const SubAlign a = sub_alignment(mainIr, subIr, fs);
        char b[128];
        std::snprintf(b, sizeof(b), "(delay %.1f 样本 = %.3f ms，gain %+.4f dB)",
                      a.delaySamples, a.delaySamples / fs * 1000.0, a.gainDb);
        printf("  %s\n", b);
        check(std::fabs(a.delaySamples - 576.0) <= 24.0, "延迟差恢复 12 ms ±0.5 ms", b);
        check(std::fabs(a.gainDb - 3.0) <= 0.5, "增益差恢复 3 dB ±0.5 dB", b);
    }

    printf("\n=== 5. 布局表：通道数/通道名/LFE 分频 ===\n");
    {
        const auto layouts = room_layouts();
        char b[64];
        std::snprintf(b, sizeof(b), "(共 %zu 种)", layouts.size());
        printf("  %s\n", b);
        check(layouts.size() == 6, "6 种布局", b);

        const RoomLayout* h714 = nullptr;
        const RoomLayout* h512 = nullptr;
        const RoomLayout* h20 = nullptr;
        bool allSub80 = true, countsOk = true;
        for (const auto& r : layouts) {
            if (std::string(r.name) == "7.1.4") h714 = &r;
            if (std::string(r.name) == "5.1.2") h512 = &r;
            if (std::string(r.name) == "2.0") h20 = &r;
            if (r.sub && r.crossoverHz != 80.0) allSub80 = false;
            if (r.chCount <= 0 || r.chCount > 12) countsOk = false;
            for (int i = 0; i < r.chCount; ++i)
                if (!r.chName[i] || r.chName[i][0] == '\0') countsOk = false;
        }
        check(h714 && h512 && h20, "含 2.0 / 5.1.2 / 7.1.4");
        check(allSub80, "带超低的布局 LFE 分频全为 80 Hz");
        check(countsOk, "通道计数与名字非空");

        const char* exp714[12] = { "L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs",
                                   "Ltf", "Rtf", "Ltr", "Rtr" };
        bool ok714 = h714 && h714->chCount == 12 && h714->sub;
        if (ok714)
            for (int i = 0; i < 12; ++i)
                if (std::string(h714->chName[i]) != exp714[i]) ok714 = false;
        check(ok714, "7.1.4 = 12 通道，顺序 L R C LFE Lss Rss Lrs Rrs Ltf Rtf Ltr Rtr");
        check(h512 && h512->chCount == 8 && h512->sub, "5.1.2 = 8 通道");
        check(h20 && h20->chCount == 2 && !h20->sub, "2.0 = 2 通道无超低");
    }

    printf("\n=== 6. 平滑数学：平谱不动 / 尖峰降高不位移 ===\n");
    {
        // 6a. 白谱（全 0 dB）平滑后仍平：考的是滑动窗的求和/计数不变量
        const size_t N6 = 65536;
        std::vector<double> flat(N6 / 2 + 1, 0.0);
        psychoacoustic_smooth(flat, fs);                     // 默认 1/6→1/3
        double worst = 0.0;
        for (double v : flat) worst = std::max(worst, std::fabs(v));
        char b[64];
        std::snprintf(b, sizeof(b), "(max|Δ| = %.2e dB)", worst);
        printf("  %s\n", b);
        check(worst <= 0.05, "白谱平滑后仍平 ±0.05 dB", b);

        // 6b. 单频 +10 dB 尖峰经 1/3 oct 平滑：峰高下降、位置不变。
        // 判据说明（铁律 3）：FFT bin 分辨率（0.73 Hz）远细于 1/3 oct 窗（~300 Hz），
        // 单 bin 冲激平滑后的 argmax 由「窗内 bin 计数」决定——窗沿向低频侧更窄、
        // 计数更小、均值更高，argmax 天然偏向尖峰低频侧约半窗宽处（实测偏 −148 bin，
        // 峰值仅差 13%）。要求 argmax 钉在尖峰 bin 上是错误判据；正确的判据是
        // 【平滑后的能量仍定位在尖峰处】：argmax 落在 ±半窗宽内，且尖峰 bin
        // 本身的平滑值接近全局最大。
        std::vector<double> spiky(N6 / 2 + 1, 0.0);
        const size_t kSpike = (size_t)std::llround(1000.0 * N6 / fs);   // ≈1 kHz bin
        spiky[kSpike] = 10.0;
        psychoacoustic_smooth(spiky, fs, 3.0, 3.0);          // 恒定 1/3 oct
        size_t kMax = 0;
        for (size_t k = 0; k < spiky.size(); ++k) if (spiky[k] > spiky[kMax]) kMax = k;
        // 1/3 oct 窗的半宽（1/6 oct）在尖峰 bin 处折成的 bin 数
        const int halfWin = (int)std::ceil((double)kSpike * (std::pow(2.0, 1.0 / 6.0) - 1.0)) + 2;
        const ptrdiff_t shift = (ptrdiff_t)kMax - (ptrdiff_t)kSpike;
        const double atSpike = spiky[kSpike];
        char b2[160];
        std::snprintf(b2, sizeof(b2), "(尖峰 bin %zu (%.1f Hz)，平滑后峰 %.4f dB @ bin %zd（偏 %+zd），尖峰处 %.4f dB)",
                      kSpike, (double)kSpike * fs / N6, spiky[kMax], (ptrdiff_t)kMax, shift, atSpike);
        printf("  %s\n", b2);
        check(spiky[kMax] < 1.0 && spiky[kMax] > 0.0, "1/3 oct 平滑后峰高下降（10 dB → <1 dB）", b2);
        check(shift >= -halfWin && shift <= halfWin, "峰仍定位在尖峰 ±半窗宽内", b2);
        check(atSpike >= 0.8 * spiky[kMax], "尖峰 bin 平滑值 ≥ 0.8×全局最大（能量未漂移）", b2);
    }

    printf("\n=== 7. 边界：空输入 / taps=0 / 全零 IR / 极短 IR / 非法 fs（不许崩）===\n");
    {
        // 7a generate_sweep 的非法参数：一律返回空序列（不是随机长度）
        check(generate_sweep(SweepSpec{0.0, 10.0, 22050.0, 10.0}).empty(), "fs=0 → 空扫频");
        check(generate_sweep(SweepSpec{48000.0, 0.0, 22050.0, 10.0}).empty(), "f0=0 → 空扫频");
        check(generate_sweep(SweepSpec{48000.0, 10.0, 22050.0, 0.0}).empty(), "durSec=0 → 空扫频");
        // ★ 第一版这条写错了（如实记录）：用了 f0=20000 / f1=22050，而钳位只压 f1 不压 f0，
        //   钳完 f1 仍是 22050 > f0 ⟹ 合法参数，出样本是对的。要真测倒挂必须让 f0 高于
        //   0.499·fs（钳位后的 f1 上限），例如 f0=30000 > 23952。
        check(generate_sweep(SweepSpec{48000.0, 30000.0, 22050.0, 1.0}).empty(),
              "f0 > 0.499·fs（钳位后 f1 仍低于 f0）→ 空扫频");
        check(!generate_sweep(SweepSpec{48000.0, 20000.0, 22050.0, 0.1}).empty(),
              "对照：f0=20k < f1=22.05k 是合法参数，必须出样本（防止上一条测成永远空）");
        // 超奈奎斯特的 f1 必须被钳住而不是混叠：长度 = durSec·fs，且序列有界
        {
            SweepSpec s; s.f1 = 96000.0; s.durSec = 0.1;
            const auto x = generate_sweep(s);
            double pk = 0.0;
            for (double v : x) pk = std::max(pk, std::fabs(v));
            char b[128];
            std::snprintf(b, sizeof(b), "(n=%zu, 峰值 %.4f)", x.size(), pk);
            check(x.size() == (size_t)std::llround(0.1 * 48000.0), "f1 超奈奎斯特仍按 durSec·fs 出样本", b);
            check(pk <= 1.0 + 1e-9, "序列有界（钳位后不混叠成怪值）", b);
        }

        // 7b deconvolve_ir 的空输入
        check(deconvolve_ir({}, {}, fs).empty(), "measured/sweep 皆空 → 空 IR");
        check(deconvolve_ir({1.0, 2.0}, {}, fs).empty(), "sweep 空 → 空 IR");
        {
            const std::vector<double> zeros(1024, 0.0);
            check(deconvolve_ir(zeros, zeros, fs).empty(), "全零扫频（pmax=0）→ 空 IR，不做除零");
        }

        // 7c ir_peak_index / ir_magnitude_db 的退化输入
        check(ir_peak_index({}) == 0, "空序列 peak 索引 = 0（不越界）");
        check(ir_magnitude_db({}, fs).empty(), "空 IR → 空半谱");
        check(ir_magnitude_db({1.0, 0.0}, 0.0).empty(), "fs=0 → 空半谱");

        // 7d psychoacoustic_smooth 的退化输入：长度 <2 / 非法 fs / 非法倍频程参数
        {
            std::vector<double> one(1, 5.0);
            psychoacoustic_smooth(one, fs);
            check(one.size() == 1 && one[0] == 5.0, "单点谱原样返回（n<2 早退）");
            std::vector<double> v(9, 3.0);
            psychoacoustic_smooth(v, 0.0);
            check(v[0] == 3.0, "fs=0 早退，不写坏数据");
            std::vector<double> v2(9, 3.0);
            psychoacoustic_smooth(v2, fs, 0.0, 3.0);
            check(v2[0] == 3.0, "octLow=0 早退，不除零");
        }

        // 7e target_curve_db：nBins<2 与 fs 非法
        check(target_curve_db(TargetCurve::tilt(), fs, 0).empty(), "nBins=0 → 空目标曲线");
        check(target_curve_db(TargetCurve::tilt(), fs, 1).size() == 1, "nBins=1 → 1 点（不崩）");
        check(target_curve_db(TargetCurve::tilt(), 0.0, 16).size() == 16, "fs=0 → 仍返回 nBins 个 0（不崩）");

        // 7f minimum_phase_ir：半谱过短
        check(minimum_phase_ir({}).empty(), "空半谱 → 空 IR");
        check(minimum_phase_ir({1.0}).empty(), "半谱 1 点 → 空 IR");

        // 7g compute_correction_ir：taps=0 / 空 IR / 全零 IR / 极短 IR
        {
            CorrectionOpts o;
            o.taps = 0;
            const auto h0 = compute_correction_ir(roomIr, fs, TargetCurve::tilt(), o);
            check(h0.size() == 1 && h0[0] == 0.0, "taps=0 → 返回 1 个 0（上游约定，不崩）", std::to_string(h0.size()));

            CorrectionOpts o2;
            const auto hEmpty = compute_correction_ir({}, fs, TargetCurve::tilt(), o2);
            check(hEmpty.size() == o2.taps, "空 roomIr → 返回全零 taps 长度", std::to_string(hEmpty.size()));
            bool allZero = true;
            for (double v : hEmpty) if (v != 0.0) allZero = false;
            check(allZero, "空 roomIr → 全零（不是未初始化内存）");

            const std::vector<double> zeros((size_t)fs, 0.0);
            const auto hZ = compute_correction_ir(zeros, fs, TargetCurve::tilt(), o2);
            bool finite = true;
            for (double v : hZ) if (!std::isfinite(v)) finite = false;
            check(finite, "全零 IR → 输出全部有限（无 NaN/Inf）", std::to_string(hZ.size()));

            // 极短 IR（< 16 样本的窗）：compute_correction_ir 应早退成全零而不是越界读
            const std::vector<double> tiny(8, 0.0);
            const auto hT = compute_correction_ir(tiny, fs, TargetCurve::tilt(), o2);
            check(hT.size() == o2.taps, "极短 IR → 仍返回 taps 长度", std::to_string(hT.size()));
            bool tz = true;
            for (double v : hT) if (v != 0.0) tz = false;
            check(tz, "极短 IR（winLen<16）→ 全零早退（不越界）");
        }

        // 7h sub_alignment：空输入 / 全零输入
        {
            const SubAlign a0 = sub_alignment({}, {}, fs);
            check(a0.delaySamples == 0.0 && a0.gainDb == 0.0, "空 IR → 对齐参数全 0（不崩）");
            const SubAlign a1 = sub_alignment(std::vector<double>(1024, 0.0),
                                              std::vector<double>(1024, 0.0), fs);
            check(a1.delaySamples == 0.0 && a1.gainDb == 0.0, "全零 IR → 对齐参数全 0（不做 log(0)）");
            const SubAlign a2 = sub_alignment(std::vector<double>(1024, 0.0),
                                              std::vector<double>(1024, 0.0), 0.0);
            check(a2.delaySamples == 0.0, "fs=0 → 早退");
        }

        // 7i 布局表：非法索引防护（chName 至少 chCount 个非空）
        {
            bool ok = true;
            for (const auto& r : room_layouts()) {
                if (r.chCount < 1 || r.chCount > 12) ok = false;
                for (int i = 0; i < r.chCount; ++i)
                    if (!r.chName[i] || !r.chName[i][0]) ok = false;
            }
            check(ok, "所有布局的通道名非空且计数在 1..12");
        }
    }

    printf("\n%s (失败项 %d)\n", fails == 0 ? "全部通过" : "存在失败", fails);
    return fails == 0 ? 0 : 1;
}
