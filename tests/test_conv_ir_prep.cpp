// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_conv_ir_prep.cpp — 卷积 IR 预处理（超 Nyquist 外推 + 自动增益）验证
//
// 判据设计（遵守"测试通过 != 测对了东西"）：
//   增益：解析值必须精确匹配（峰值 / 通带平均 / L1 / 能量）
//   最坏情况：Σ|h| 的倒数必须是真实上界 —— 用最坏输入实测验证
//   外推：边界必须真的被压到 0（不能只是"看起来干净"）
//   外推：通带必须保持不变（这是最关键的一条 —— 外推不能改动已测量的频段）
//   外推：结果必须因果（最小相位），不能有前导能量
#include "dsp/conv_ir_prep.h"
#include "dsp/convolution.h"
#include "dsp/filter_design.h"
#include <cstdio>
#include <vector>
#include <cmath>
#include <string>
#include <random>

using namespace rta::dsp;

static int fails = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++fails;
}

// 在指定频率上算 IR 的幅度（dB），用直接相关法（不依赖 FFT 补零）
static double mag_db_at(const std::vector<double>& h, double f, double fs) {
    const double w = 2.0 * kPi * f / fs;
    double re = 0.0, im = 0.0;
    for (size_t i = 0; i < h.size(); ++i) {
        re += h[i] * std::cos(w * (double)i);
        im -= h[i] * std::sin(w * (double)i);
    }
    const double m = std::sqrt(re * re + im * im);
    return 20.0 * std::log10(m > 1e-300 ? m : 1e-300);
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);

    // =====================================================================
    printf("=== 1. 增益估算：解析值必须精确 ===\n");
    {
        // 构造已知峰值的 IR：一个 delta
        std::vector<double> d(1024, 0.0);
        d[100] = 0.5;
        auto g = estimate_ir_gain(d, 44100.0);
        check(std::fabs(g.peakAbs - 0.5) < 1e-12, "delta 峰值 = 0.5",
              "得到 " + std::to_string(g.peakAbs));
        check(std::fabs(g.peakDb - (-6.0206)) < 0.01, "delta 峰值 dB ≈ -6.02",
              "得到 " + std::to_string(g.peakDb));
        check(g.peakIndex == 100, "峰值位置 = 100",
              "得到 " + std::to_string(g.peakIndex));
        check(std::fabs(g.sumAbs - 0.5) < 1e-12, "L1 = 0.5",
              "得到 " + std::to_string(g.sumAbs));
        check(std::fabs(g.energy - 0.25) < 1e-12, "能量 = 0.25",
              "得到 " + std::to_string(g.energy));
        // 通带平均：delta 的幅度谱是平坦的 0.5
        check(std::fabs(g.passbandMean - 0.5) < 0.02, "delta 通带平均 ≈ 0.5",
              "得到 " + std::to_string(g.passbandMean));
    }
    {
        // 全零 IR：不能崩、不能除零
        std::vector<double> z(256, 0.0);
        auto g = estimate_ir_gain(z, 48000.0);
        check(g.peakAbs == 0.0, "全零 IR 峰值 = 0");
        check(std::isfinite(suggest_ir_gain(g)), "全零 IR 的补偿增益有限");
        check(suggest_ir_gain(g) == 1.0, "全零 IR 的补偿增益 = 1.0（保守）");
    }
    {
        // 空 IR
        auto g = estimate_ir_gain({}, 44100.0);
        check(g.peakAbs == 0.0, "空 IR 不崩");
    }

    // =====================================================================
    printf("\n=== 2. 最坏情况余量：必须是真实上界 ===\n");
    {
        // 构造一个 Σ|h| 已知的 IR
        std::vector<double> h(64, 0.0);
        h[0] = 0.5; h[1] = 0.25; h[2] = 0.125;   // Σ|h| = 0.875
        auto g = estimate_ir_gain(h, 44100.0);
        check(std::fabs(g.sumAbs - 0.875) < 1e-12, "Σ|h| = 0.875",
              "得到 " + std::to_string(g.sumAbs));
        const double hr = worst_case_headroom_db(g);
        const double expect = -20.0 * std::log10(0.875);
        check(std::fabs(hr - expect) < 0.01, "余量 dB 匹配解析值（Σ|h|<1 应为正）",
              "得到 " + std::to_string(hr) + " 期望 " + std::to_string(expect));
        check(hr > 0.0, "Σ|h|<1 时余量为正（不需要衰减）",
              "得到 " + std::to_string(hr));

        // 反向验证：Σ|h| > 1 必须返回负值
        std::vector<double> big(64, 0.0);
        big[0] = 1.5; big[1] = 0.5;      // Σ|h| = 2.0
        auto gb = estimate_ir_gain(big, 44100.0);
        const double hrb = worst_case_headroom_db(gb);
        check(std::fabs(hrb - (-6.0206)) < 0.01, "Σ|h|=2 时余量 = -6.02 dB",
              "得到 " + std::to_string(hrb));

        // 实测验证：用"与 h 同号的满幅输入"构造最坏情况，输出峰值必须 <= Σ|h|
        std::vector<double> x(256, 0.0);
        for (size_t i = 0; i < h.size(); ++i) x[i] = (h[i] >= 0.0) ? 1.0 : -1.0;
        auto y = direct_convolve(x, h);
        double peak = 0.0;
        for (double v : y) peak = std::max(peak, std::fabs(v));
        check(peak <= g.sumAbs + 1e-9, "实测峰值 <= Σ|h|（上界成立）",
              "实测 " + std::to_string(peak) + " 上界 " + std::to_string(g.sumAbs));
    }

    // =====================================================================
    printf("\n=== 3. 补偿增益：两种基准必须各自自洽 ===\n");
    {
        std::vector<double> h(512, 0.0);
        h[10] = 0.8;      // 峰值 0.8
        h[11] = 0.1;
        auto g = estimate_ir_gain(h, 48000.0);

        const double gp = suggest_ir_gain(g, IrGainMode::Peak);
        check(std::fabs(gp * g.peakAbs - 1.0) < 1e-9, "Peak 模式：峰值 × 增益 = 1.0",
              "得到 " + std::to_string(gp * g.peakAbs));

        const double gb = suggest_ir_gain(g, IrGainMode::Passband);
        check(std::fabs(gb * g.passbandMean - 1.0) < 1e-6, "Passband 模式：通带 × 增益 = 1.0",
              "得到 " + std::to_string(gb * g.passbandMean));

        // headroom 必须真的降增益
        const double g3 = suggest_ir_gain(g, IrGainMode::Passband, 6.0);
        check(std::fabs(g3 / gb - std::pow(10.0, -6.0 / 20.0)) < 1e-9,
              "6 dB headroom 精确降 6 dB", "比值 " + std::to_string(g3 / gb));
    }

    // =====================================================================
    printf("\n=== 4. 超 Nyquist 外推：边界必须真的被压掉 ===\n");
    {
        // 44.1k 的 IR：通带平坦，22.05k 以上本来就没有内容
        const double srcFs = 44100.0;
        const size_t taps = 4096;
        // 用低通设计一个已知带宽的 IR（截止 18 kHz，远低于 Nyquist）
        LowpassSpec sp;
        sp.taps = taps; sp.cutoff = 18000.0 / (srcFs * 0.5); sp.attenDb = 120.0;
        std::vector<double> ir = design_lowpass(sp);

        // 先确认原始 IR 在 18k 内平坦、20k 外已衰减
        const double m1k  = mag_db_at(ir, 1000.0, srcFs);
        const double m17k = mag_db_at(ir, 17000.0, srcFs);
        const double m21k = mag_db_at(ir, 21000.0, srcFs);
        check(std::fabs(m1k) < 0.5, "原始 IR 1 kHz 通带 0 dB",
              "得到 " + std::to_string(m1k));
        check(m17k > -3.0, "原始 IR 17 kHz 仍在通带",
              "得到 " + std::to_string(m17k));
        check(m21k < -40.0, "原始 IR 21 kHz 已衰减 >40 dB",
              "得到 " + std::to_string(m21k));

        // 外推到 96k
        ExtrapolateSpec es;
        es.srcFs = srcFs; es.dstFs = 96000.0;
        es.fadeStartHz = 19000.0; es.fadeEndHz = 22000.0;
        auto out = extrapolate_ir_bandwidth(ir, es, taps);
        check(!out.empty(), "外推结果非空",
              "长度 " + std::to_string(out.size()));

        const double dstFs = 96000.0;
        // 关键判据 1：通带（1k / 17k）必须保持
        const double o1k  = mag_db_at(out, 1000.0, dstFs);
        const double o17k = mag_db_at(out, 17000.0, dstFs);
        check(std::fabs(o1k) < 1.0, "外推后 1 kHz 仍 0 dB",
              "得到 " + std::to_string(o1k));
        check(std::fabs(o17k) < 3.0, "外推后 17 kHz 仍在通带",
              "得到 " + std::to_string(o17k));

        // 关键判据 2：原 Nyquist 以上必须被压掉（不能留镜像）
        const double o22k = mag_db_at(out, 22000.0, dstFs);
        const double o30k = mag_db_at(out, 30000.0, dstFs);
        const double o40k = mag_db_at(out, 40000.0, dstFs);
        check(o22k < -30.0, "外推后 22 kHz 已衰减 >30 dB",
              "得到 " + std::to_string(o22k));
        check(o30k < -60.0, "外推后 30 kHz 已衰减 >60 dB",
              "得到 " + std::to_string(o30k));
        check(o40k < -80.0, "外推后 40 kHz 已衰减 >80 dB",
              "得到 " + std::to_string(o40k));

        // 关键判据 3：因果性 —— 峰值必须靠近头部（最小相位）
        auto g = estimate_ir_gain(out, dstFs);
        check(g.peakIndex < out.size() / 8, "峰值靠近头部（最小相位、因果）",
              "peakIndex=" + std::to_string(g.peakIndex) + " / " + std::to_string(out.size()));

        // 关键判据 4：不得有前导能量（因果性硬判据）
        // 最小相位 IR 的 index 0 之前没有样本，这里检查 index 0 附近的能量占比
        double eHead = 0.0, eAll = 0.0;
        for (size_t i = 0; i < out.size(); ++i) {
            const double e = out[i] * out[i];
            eAll += e;
            if (i < out.size() / 4) eHead += e;
        }
        check(eAll > 1e-20 && eHead / eAll > 0.9,
              "前 1/4 能量占比 >90%（能量集中在头部）",
              "占比 " + std::to_string(eAll > 1e-20 ? eHead / eAll : 0.0));
    }

    // =====================================================================
    printf("\n=== 5. 外推的边界条件与异常 ===\n");
    {
        std::vector<double> ir(512, 0.0);
        ir[0] = 1.0;

        // dstFs == srcFs：允许（等价于只做边界整形）
        ExtrapolateSpec es;
        es.srcFs = 48000.0; es.dstFs = 48000.0;
        bool ok = true;
        try { auto o = extrapolate_ir_bandwidth(ir, es, 512); (void)o; }
        catch (...) { ok = false; }
        check(ok, "dstFs == srcFs 允许");

        // dstFs < srcFs：必须明确报错（不能静默降采样）
        ExtrapolateSpec bad;
        bad.srcFs = 96000.0; bad.dstFs = 44100.0;
        bool threw = false;
        try { auto o = extrapolate_ir_bandwidth(ir, bad, 512); (void)o; }
        catch (const std::runtime_error&) { threw = true; }
        check(threw, "dstFs < srcFs 明确抛异常");

        // srcFs <= 0：必须报错
        ExtrapolateSpec bad2;
        bad2.srcFs = 0.0; bad2.dstFs = 48000.0;
        bool threw2 = false;
        try { auto o = extrapolate_ir_bandwidth(ir, bad2, 512); (void)o; }
        catch (const std::runtime_error&) { threw2 = true; }
        check(threw2, "srcFs <= 0 明确抛异常");

        // 空 IR：返回空，不崩
        auto e = extrapolate_ir_bandwidth({}, es, 512);
        check(e.empty(), "空 IR 返回空");
    }

    // =====================================================================
    printf("\n=== 6. 外推后直接喂卷积器：不得削波、不得 NaN ===\n");
    {
        const double srcFs = 44100.0;
        LowpassSpec sp;
        sp.taps = 2048; sp.cutoff = 0.85; sp.attenDb = 120.0;
        std::vector<double> ir = design_lowpass(sp);

        ExtrapolateSpec es;
        es.srcFs = srcFs; es.dstFs = 96000.0;
        auto out = extrapolate_ir_bandwidth(ir, es, 2048);

        // 用安全增益归一（Typical 档：按音乐信号统计特性）
        auto g = estimate_ir_gain(out, 96000.0);
        const double gain = safe_ir_gain(g, IrGainMode::Passband, 3.0);
        for (auto& v : out) v *= gain;

        // 先验证安全增益确实 <= 通带归一增益（否则说明逻辑没生效）
        const double gPassband = suggest_ir_gain(g, IrGainMode::Passband, 3.0);
        check(gain <= gPassband + 1e-12, "安全增益 <= 通带增益",
              "safe=" + std::to_string(gain) + " passband=" + std::to_string(gPassband));

        // Typical 档不能把音量压太低（这是本文件实现中踩过的坑：
        // 用 Σ|h| 严格上界会压 10~18 dB，用户听感是"打开卷积就变小声"）
        // 注意：比较基准必须是**同样带 headroom** 的通带增益，否则 3 dB 被算两次
        const double gPass3 = suggest_ir_gain(g, IrGainMode::Passband, 3.0);
        const double gainDb = 20.0 * std::log10(gain / gPass3);
        check(gainDb > -6.0, "Typical 档相对通带归一的衰减 < 6 dB（不压听感）",
              "衰减 " + std::to_string(gainDb) + " dB");

        // 满幅白噪输入，检查输出有限且不超 1.0
        std::mt19937 rng(999);
        std::uniform_real_distribution<double> u(-1.0, 1.0);
        std::vector<double> x(96000, 0.0);
        for (auto& v : x) v = u(rng);

        StreamingConvolver sc(out, 1024);
        std::vector<double> y(x.size(), 0.0);
        sc.process(x.data(), y.data(), x.size());

        bool allFinite = true;
        double peak = 0.0;
        for (double v : y) {
            if (!std::isfinite(v)) allFinite = false;
            peak = std::max(peak, std::fabs(v));
        }
        check(allFinite, "输出全部有限（无 NaN/Inf）");
        check(peak <= 1.0, "满幅白噪输入下不削波（Typical 档）",
              "峰值 " + std::to_string(peak));
        check(peak > 0.01, "输出不是静音（增益没算成 0）",
              "峰值 " + std::to_string(peak));

        // Guaranteed 档：用最坏情况输入（与 IR 同号的满幅）也必须不削波
        auto out2 = extrapolate_ir_bandwidth(ir, es, 2048);
        auto g2 = estimate_ir_gain(out2, 96000.0);
        const double gGuar = guaranteed_ir_gain(g2, 0.0);
        for (auto& v : out2) v *= gGuar;
        std::vector<double> xw(out2.size() * 2, 0.0);
        for (size_t i = 0; i < out2.size(); ++i) xw[i] = (out2[i] >= 0.0) ? 1.0 : -1.0;
        auto yw = direct_convolve(xw, out2);
        double peakW = 0.0;
        for (double v : yw) peakW = std::max(peakW, std::fabs(v));
        check(peakW <= 1.0 + 1e-9, "Guaranteed 档：最坏情况输入下不削波（Σ|h| 上界有效）",
              "峰值 " + std::to_string(peakW));
    }

    // =====================================================================
    printf("\n=== 7. 性能：4096 抽头外推耗时 ===\n");
    {
        LowpassSpec sp;
        sp.taps = 4096; sp.cutoff = 0.9; sp.attenDb = 120.0;
        std::vector<double> ir = design_lowpass(sp);
        ExtrapolateSpec es;
        es.srcFs = 44100.0; es.dstFs = 192000.0;
        const int N = 20;
        auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < N; ++i) {
            auto o = extrapolate_ir_bandwidth(ir, es, 4096);
            (void)o;
        }
        auto t1 = std::chrono::steady_clock::now();
        const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count() / N;
        printf("  平均 %.2f ms / 次（离线操作，不影响实时）\n", ms);
        check(ms < 2000.0, "单次外推 < 2 s", "得到 " + std::to_string(ms) + " ms");
    }

    // =====================================================================
    printf("\n=== 8. 峰值因子：经验测量必须覆盖真实值（含房间校正风格 IR）===\n");
    {
        // 这一节是 2026-10-26 修 bug 后加的回归测试。
        // v1 用固定 crestFactor=1.8，在下面 room/65536 这个用例上会削波到 2.20。
        struct Case { std::string name; std::vector<double> ir; double fs; };
        std::vector<Case> cases;

        // 低通类（v1 能过的）
        for (auto pr : std::vector<std::pair<int,double>>{{512,0.5},{2048,0.85},{8192,0.3},{32768,0.95}}) {
            LowpassSpec sp;
            sp.taps = pr.first; sp.cutoff = pr.second; sp.attenDb = 120.0;
            cases.push_back({"lp/" + std::to_string(pr.first), design_lowpass(sp), 44100.0});
        }
        // 房间校正风格（v1 失效的）
        {
            std::mt19937 r(42); std::uniform_real_distribution<double> u(-1,1);
            std::vector<double> ir(65536);
            for (size_t i=0;i<ir.size();++i) {
                double t=(double)i/ir.size();
                ir[i]=(u(r)*0.5 + 0.3*std::sin(2*3.14159265*80.0*(double)i/48000.0)
                       + 0.2*std::sin(2*3.14159265*3000.0*(double)i/48000.0))*std::exp(-5.0*t);
            }
            cases.push_back({"room/65536", ir, 48000.0});
        }
        // 衰减噪声
        {
            std::mt19937 r(11); std::uniform_real_distribution<double> u(-1,1);
            std::vector<double> ir(65536);
            for (size_t i=0;i<ir.size();++i) ir[i]=u(r)*std::exp(-6.0*(double)i/ir.size());
            cases.push_back({"noise/65536", ir, 48000.0});
        }
        // 单频共振
        {
            std::vector<double> ir(8192);
            for (size_t i=0;i<ir.size();++i)
                ir[i]=std::sin(2*3.14159265*1000.0*(double)i/48000.0)*std::exp(-3.0*(double)i/ir.size());
            cases.push_back({"reson/8192", ir, 48000.0});
        }
        // 稀疏脉冲（多路径）
        {
            std::vector<double> ir(8192,0.0);
            ir[0]=1.0; ir[100]=0.8; ir[500]=0.6; ir[2000]=0.4; ir[5000]=0.3;
            cases.push_back({"sparse/8192", ir, 48000.0});
        }
        // 强低频共振（最恶劣）
        {
            std::mt19937 r(77); std::uniform_real_distribution<double> u(-1,1);
            std::vector<double> ir(32768);
            for (size_t i=0;i<ir.size();++i) {
                double t=(double)i/ir.size();
                ir[i]=(u(r)*0.1 + 0.8*std::sin(2*3.14159265*50.0*(double)i/48000.0))*std::exp(-2.0*t);
            }
            cases.push_back({"bass-reson/32768", ir, 48000.0});
        }

        // 真实场景：REW 导出的房间校正 IR —— 按【通带】归一，不是按峰值。
        // 这一点很关键：按峰值归一的宽带噪声 IR 通带增益高达 20+ 倍，
        // 它本来就不是透明滤波器，safe_ir_gain 压 -38 dB 是正确的
        // （但那种 IR 不是用户会导入的东西）。
        {
            std::mt19937 r(2024); std::uniform_real_distribution<double> u(-1,1);
            std::vector<double> ir(32768);
            for (size_t i=0;i<ir.size();++i)
                ir[i]=u(r)*std::exp(-7.0*(double)i/ir.size());
            // 按通带归一（REW 的做法）：先量再除
            auto g0 = estimate_ir_gain(ir, 48000.0, 200.0, 0.0, /*measureCrest=*/false);
            if (g0.passbandMean > 1e-300)
                for (auto& v : ir) v /= g0.passbandMean;
            cases.push_back({"real-rew/32768", ir, 48000.0});
        }
        // 真实场景：归一化到通带 0 dB 的 IR
        {
            LowpassSpec sp; sp.taps=4096; sp.cutoff=0.8; sp.attenDb=120.0;
            cases.push_back({"real-passband/4096", design_lowpass(sp), 48000.0});
        }

        double worstRatio = 1e9;
        // 增益合理性检查：对已归一化的 IR，safe 增益不应低于 -12 dB
        // （否则用户听感是"开了卷积就没声音"）
        double minGainDbNormalized = 0.0;
        for (auto& c : cases) {
            // estimate_ir_gain 默认会实测 crest
            auto g = estimate_ir_gain(c.ir, c.fs);
            check(g.measuredCrest > 0.0, std::string(c.name) + " measuredCrest 已测量",
                  "crest=" + std::to_string(g.measuredCrest));

            // 长时参考：20 万样本白噪
            std::mt19937 rng(7); std::uniform_real_distribution<double> u(-1,1);
            std::vector<double> x(200000);
            for (auto& v : x) v = u(rng);
            StreamingConvolver sc(c.ir, 1024);
            std::vector<double> y(200000);
            sc.process(x.data(), y.data(), 200000);
            double pk = 0.0;
            for (double v : y) pk = std::max(pk, std::fabs(v));
            const double refCrest = (g.passbandMean > 1e-300) ? pk / g.passbandMean : 0.0;

            // 关键判据：经验值不能低于参考值太多（允许 10% 低估，由 safetyMargin 兜）
            const double ratio = (refCrest > 1e-300) ? g.measuredCrest / refCrest : 1.0;
            worstRatio = std::min(worstRatio, ratio);
            check(ratio > 0.90, std::string(c.name) + " 经验 crest 不低于参考的 90%",
                  "ratio=" + std::to_string(ratio));

            // 关键判据：safe_ir_gain 归一后，白噪输出必须不削波
            const double gain = safe_ir_gain(g, IrGainMode::Passband, 0.0);
            double outPeak = 0.0;
            for (double v : y) outPeak = std::max(outPeak, std::fabs(v) * gain);
            check(outPeak <= 1.0, std::string(c.name) + " safe 增益下不削波",
                  "峰值 " + std::to_string(outPeak) + " 增益 " + std::to_string(gain));

            // 已归一化的 IR（peak≈1 或 passband≈1）不该被压得太狠
            if (c.name.rfind("real-", 0) == 0) {
                const double gdb = 20.0 * std::log10(gain);
                minGainDbNormalized = std::min(minGainDbNormalized, gdb);
                check(gdb > -12.0, std::string(c.name) + " 归一化 IR 增益 > -12 dB（不压听感）",
                      std::to_string(gdb) + " dB");
            }
        }
        check(minGainDbNormalized > -12.0, "所有归一化 IR 的增益 > -12 dB",
              "最差 " + std::to_string(minGainDbNormalized) + " dB");
        check(worstRatio > 0.90, "所有用例的经验 crest 最坏比值 > 0.90",
              "worst=" + std::to_string(worstRatio));
    }

    // =====================================================================
    printf("\n=== 9. measureCrest=false 时必须退回保守上界（不削波但压小声）===\n");
    {
        LowpassSpec sp; sp.taps = 2048; sp.cutoff = 0.85; sp.attenDb = 120.0;
        auto ir = design_lowpass(sp);
        auto gFast = estimate_ir_gain(ir, 44100.0, 200.0, 0.0, /*measureCrest=*/false);
        check(gFast.measuredCrest == 0.0, "measureCrest=false 时 measuredCrest = 0",
              "得到 " + std::to_string(gFast.measuredCrest));

        const double gSafe = safe_ir_gain(gFast, IrGainMode::Passband, 0.0);
        // 退回 Σ|h| 上界，应该比实测版更保守（增益更小）
        auto gFull = estimate_ir_gain(ir, 44100.0);
        const double gMeasured = safe_ir_gain(gFull, IrGainMode::Passband, 0.0);
        check(gSafe <= gMeasured + 1e-12, "无实测时增益 <= 实测版（更保守）",
              "safe=" + std::to_string(gSafe) + " measured=" + std::to_string(gMeasured));

        // 仍然必须不削波
        std::mt19937 rng(7); std::uniform_real_distribution<double> u(-1,1);
        std::vector<double> x(120000);
        for (auto& v : x) v = u(rng);
        StreamingConvolver sc(ir, 1024);
        std::vector<double> y(120000);
        sc.process(x.data(), y.data(), 120000);
        double pk = 0.0;
        for (double v : y) pk = std::max(pk, std::fabs(v) * gSafe);
        check(pk <= 1.0, "无实测时也不削波", "峰值 " + std::to_string(pk));
    }

    // =====================================================================
    printf("\n=== 10. 测量耗时（离线可接受）===\n");
    {
        for (int taps : {2048, 65536}) {
            LowpassSpec sp; sp.taps = taps; sp.cutoff = 0.9; sp.attenDb = 120.0;
            auto ir = design_lowpass(sp);
            auto t0 = std::chrono::steady_clock::now();
            auto g = estimate_ir_gain(ir, 44100.0);
            auto t1 = std::chrono::steady_clock::now();
            const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
            printf("  taps=%-6d 估算+实测耗时 %.1f ms (crest=%.3f)\n", taps, ms, g.measuredCrest);
            check(ms < 2000.0, "taps=" + std::to_string(taps) + " 耗时 < 2s",
                  std::to_string(ms) + " ms");
        }
    }

    printf("\n%s (fails=%d)\n", fails == 0 ? "ALL PASS" : "SOME FAILED", fails);
    return fails == 0 ? 0 : 1;
}
