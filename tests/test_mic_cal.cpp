// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_mic_cal.cpp — U4 第一步：测量麦克风校准曲线头（解析 / 对数插值 / 读数减校准）
//
// 判据怎么证明「测到了要证明的事」（铁律 4：先红后绿 —— 头文件不存在时本 target 编译不过）：
//   §1 解析：真实出厂文件形态各一例（两列 UMIK、CSV、三列忽略相位、注释行、表头、
//      UTF-8 BOM、科学计数、乱序/同频重复、token 不严格不算数据）；坏文件 → false。
//      BOM 用例若没剥 BOM，首行 token 会变成 "\xEF\xBB\xBF20.0" ⟹ 少一个点 ⟹ 点数断言红。
//   §2 负向对照：无校准表时 mic_cal_apply 原样返回（不允许「没表也改读数」）。
//   §3 方向判据：1000 Hz 校准 −6 dB ⟹ 该点读数 +6 dB（读数 − (−6)）；
//      远处频点 |变化| < 0.5 dB；对数中点 −3 dB（若按线性频率插值会给 −2.83，故可分辨）；
//      越界钳端点、不外推成 0（用端点非零的表证明不是「补 0」）。
//
// 全部数据在内存里；唯一 IO 是 §1 末尾的 mic_cal_load 临时文件（跑完即删）。
#include "dsp/mic_cal.h"
#include "dsp/room_measurement.h"   // §4：把校准表接进「测量→算校正」路径

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using namespace rta::dsp;

static int fails = 0;
static int total = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    ++total;
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++fails;
}
static std::string fmt(double v) {
    char b[64];
    std::snprintf(b, sizeof(b), "%.6f", v);
    return b;
}

// ---------------- §1 的样例文本：真实出厂校准文件的形态 ----------------

// UMIK-1 出厂文件：miniDSP 的 '*' 首行 + 带引号的 "Sens Factor=..." 行（都不是数据行）
static const std::string kUmik =
    "* UMIK-1 calibration file, SERNO 7006540\n"
    "# exported by miniDSP 2026-10-29\n"
    "\"Sens Factor =-2.087dB, AGain =0dB, SERNO: 7006540\"\n"
    "10.054\t-1.23\n"
    "20.000\t-0.80\n"
    "100.000\t0.10\n"
    "500.000\t1.70\n"
    "1000.000\t-0.20\n"
    "2000.000\t-0.35\n"
    "5000.000\t0.55\n"
    "10000.000\t1.20\n"
    "20000.000\t2.10\n";

// CSV + Windows 记事本的 CRLF 行尾
static const std::string kCsv =
    "freq,dB\r\n"
    "20.0,-1.0\r\n"
    "100.0,0.0\r\n"
    "1000.0,-6.0\r\n"
    "20000.0,1.0\r\n";

// 三列：第三列是相位，必须忽略
static const std::string kThreeCol =
    "Hz, dB, phase\n"
    "20.0, -1.0, 0.0\n"
    "1000.0, 2.5, 45.0\n"
    "20000.0, 0.5, 90.0\n";

// 只有表头 + 数据（表头是非数字行，整行跳过，不算错误）
static const std::string kHeader =
    "Frequency (Hz)  Response (dB)\n"
    "20.0 -2.0\n"
    "200.0 1.0\n"
    "2000.0 0.0\n";

// UTF-8 BOM（记事本另存为 UTF-8 会带）
static const std::string kBom =
    "\xEF\xBB\xBF" "20.0 -1.5\n"
    "100.0 0.0\n"
    "1000.0 1.0\n";

// 科学计数法
static const std::string kSci =
    "1.2e1 -1.5\n"
    "1.0e2 0.0\n"
    "1.0E3 1.0\n"
    "1.2e4 -0.5\n";

// token 必须整段是数字："12dB" 不能被读成 12（否则会多出 1000 Hz 这个点）
static const std::string kSuffixNoise =
    "20.0 -1.0\n"
    "200.0 0.0\n"
    "2000.0 1.0\n"
    "1000.0 12dB\n";

// 乱序 + 同频重复：按 hz 升序；同频取文件中后者（1000 Hz 记 3.0 而不是 1.0）
static const std::string kUnsortedDup =
    "1000.0 1.0\n"
    "20.0 -1.0\n"
    "20000.0 2.0\n"
    "1000.0 3.0\n";

// 坏文件：一个数字都没有
static const std::string kNoNumbers =
    "# 只有注释\n"
    "* miniDSP 灵敏度行\n"
    "Sens Factor =-2.087dB, AGain =0dB\n";

// 坏文件：只有 2 个有效点（不足 3 点 ⟹ 无效，与上游一致）
static const std::string kTooFew = "20.0 -1.0\n200.0 0.0\n";

int main() {
    printf("test_mic_cal — U4/1 测量麦克风校准头（解析 / 对数插值 / 读数减校准）\n");

    // ---------------- §1 解析 ----------------
    printf("[§1] 解析\n");
    {
        MicCalTable t;
        check(mic_cal_parse(kUmik, t), "UMIK-1 两列样例可解析");
        check(t.points.size() == 9, "UMIK 点数=9", "size=" + std::to_string(t.points.size()));
        check(std::abs(t.minDb - (-1.23)) < 1e-9 && std::abs(t.maxDb - 2.10) < 1e-9,
              "UMIK min/max 正确", fmt(t.minDb) + " ~ " + fmt(t.maxDb));
        check(std::abs(t.min_hz() - 10.054) < 1e-9 && std::abs(t.max_hz() - 20000.0) < 1e-9,
              "UMIK 频率范围正确", fmt(t.min_hz()) + " ~ " + fmt(t.max_hz()));
        check(!t.how.empty(), "how 有解析形态摘要", t.how);
    }
    {
        MicCalTable t;
        check(mic_cal_parse(kCsv, t), "CSV 两列（CRLF）可解析");
        check(t.points.size() == 4, "CSV 点数=4", "size=" + std::to_string(t.points.size()));
        check(std::abs(t.minDb - (-6.0)) < 1e-9 && std::abs(t.maxDb - 1.0) < 1e-9,
              "CSV min/max 正确", fmt(t.minDb) + " ~ " + fmt(t.maxDb));
        check(t.how.find("逗号") != std::string::npos, "how 标明逗号分隔", t.how);
    }
    {
        MicCalTable t;
        check(mic_cal_parse(kThreeCol, t), "三列（第三列相位）可解析");
        check(t.points.size() == 3, "三列点数=3", "size=" + std::to_string(t.points.size()));
        check(std::abs(t.points[1].hz - 1000.0) < 1e-9 && std::abs(t.points[1].db - 2.5) < 1e-9,
              "三列忽略第三列（取前两列）", fmt(t.points[1].db));
        check(t.how.find("3") != std::string::npos, "how 标明 3+ 列", t.how);
    }
    {
        MicCalTable t;
        check(mic_cal_parse(kHeader, t), "表头非数字行自动跳过");
        check(t.points.size() == 3, "表头样例点数=3", "size=" + std::to_string(t.points.size()));
    }
    {
        MicCalTable t;
        check(mic_cal_parse(kBom, t), "UTF-8 BOM 可解析");
        check(t.points.size() == 3, "BOM 样例点数=3（未因 BOM 丢首行）",
              "size=" + std::to_string(t.points.size()));
        check(std::abs(t.points.front().db - (-1.5)) < 1e-9, "BOM 后首行数值正确");
    }
    {
        MicCalTable t;
        check(mic_cal_parse(kSci, t), "科学计数法可解析");
        check(t.points.size() == 4, "科学计数点数=4", "size=" + std::to_string(t.points.size()));
        check(std::abs(t.points.front().hz - 12.0) < 1e-12, "1.2e1 → 12 Hz", fmt(t.points.front().hz));
        check(std::abs(t.points.back().hz - 12000.0) < 1e-9, "1.2e4 → 12000 Hz", fmt(t.points.back().hz));
    }
    {
        MicCalTable t;
        check(mic_cal_parse(kSuffixNoise, t), "带单位后缀的行不算数据");
        check(t.points.size() == 3, "suffix 样例点数=3（12dB 未被读成 12）",
              "size=" + std::to_string(t.points.size()));
        bool has1000 = false;
        for (const MicCalPoint& p : t.points) has1000 = has1000 || std::abs(p.hz - 1000.0) < 1e-9;
        check(!has1000, "没有凭空出现 1000 Hz 点");
    }
    {
        MicCalTable t;
        check(mic_cal_parse(kUnsortedDup, t), "乱序 + 同频重复可解析");
        check(t.points.size() == 3, "去重后点数=3", "size=" + std::to_string(t.points.size()));
        check(std::abs(t.points.front().hz - 20.0) < 1e-9, "已按 hz 升序", fmt(t.points.front().hz));
        check(std::abs(t.points[1].hz - 1000.0) < 1e-9 && std::abs(t.points[1].db - 3.0) < 1e-9,
              "同频取文件中后者", fmt(t.points[1].db));
    }
    {
        MicCalTable t;
        t.points = {MicCalPoint{1.0, 1.0}, MicCalPoint{2.0, 2.0}, MicCalPoint{3.0, 3.0}};
        check(!mic_cal_parse(kNoNumbers, t), "无数字的坏文件 → false");
        check(t.points.empty(), "解析失败时不留半成品（apply 才不会误改读数）",
              "size=" + std::to_string(t.points.size()));
        check(!mic_cal_parse(std::string(), t), "空文本 → false");
        check(!mic_cal_parse(kTooFew, t), "只有 2 个点 → false（至少 3 点，同上游）");
    }
    {
        namespace fs = std::filesystem;
        const fs::path p = fs::temp_directory_path() / "rl_test_mic_cal_umik.txt";
        {
            std::ofstream f(p, std::ios::binary);
            f << kUmik;
        }
        MicCalTable t;
        check(mic_cal_load(p.string(), t), "mic_cal_load 读临时 UMIK 文件");
        check(t.points.size() == 9, "load 点数=9", "size=" + std::to_string(t.points.size()));
        check(t.source == p.string(), "load 记录了 source 路径", t.source);
        const fs::path miss = fs::temp_directory_path() / "rl_test_mic_cal_absent.txt";
        check(!mic_cal_load(miss.string(), t), "load 不存在的路径 → false");
        check(t.points.empty(), "load 失败后表为空");
        check(!mic_cal_load(std::string(), t), "load 空路径 → false");
        std::error_code ec;
        fs::remove(p, ec);
    }

    // ---------------- §2 负向对照：没有校准表 ----------------
    printf("[§2] 负向对照：无校准表\n");
    {
        const MicCalTable none;
        check(mic_cal_apply(none, 1000.0, -3.5) == -3.5, "无表 → apply 原样返回", fmt(mic_cal_apply(none, 1000.0, -3.5)));
        check(mic_cal_apply(none, 20.0, 0.0) == 0.0, "无表 → 0 dB 读数仍 0 dB");
        check(mic_cal_interp(none, 1000.0) == 0.0, "无表 → interp 0 dB（不补偿）");
    }

    // ---------------- §3 方向判据 + 插值语义 ----------------
    printf("[§3] 方向判据（读数 − 校准）\n");
    {
        MicCalTable shape;   // 1000 Hz 处 −6 dB，两侧邻点 0 dB
        shape.points = {MicCalPoint{20.0, 0.0}, MicCalPoint{100.0, 0.0}, MicCalPoint{800.0, 0.0},
                        MicCalPoint{1000.0, -6.0}, MicCalPoint{1250.0, 0.0},
                        MicCalPoint{5000.0, 0.0}, MicCalPoint{20000.0, 0.0}};
        check(std::abs(mic_cal_interp(shape, 1000.0) - (-6.0)) < 1e-9, "1000 Hz 插值 = −6 dB",
              fmt(mic_cal_interp(shape, 1000.0)));
        const double measured = -6.0;
        const double applied = mic_cal_apply(shape, 1000.0, measured);
        check(std::abs((applied - measured) - 6.0) < 1e-9, "该点读数 +6 dB（读数 − (−6)）",
              "measured=" + fmt(measured) + " applied=" + fmt(applied));
        check(std::abs(mic_cal_apply(shape, 1000.0, 0.0) - 6.0) < 1e-9, "0 dB 读数在 −6 dB 点 → +6 dB");
        const double far[] = {100.0, 500.0, 1500.0, 5000.0, 20000.0};
        bool farOk = true;
        std::string farDetail;
        for (double hz : far) {
            const double d = mic_cal_apply(shape, hz, 0.0) - 0.0;
            farDetail += fmt(hz) + "→" + fmt(d) + " ";
            if (std::abs(d) >= 0.5) farOk = false;
        }
        check(farOk, "远处频点 |变化| < 0.5 dB", farDetail);

        // 对数频率中点：sqrt(800*1000) ≈ 894.427 ⟹ −3 dB；线性频率会给 −2.83，可分辨
        const double mid = std::sqrt(800.0 * 1000.0);
        const double midDb = mic_cal_interp(shape, mid);
        check(std::abs(midDb - (-3.0)) < 1e-9, "对数中点 −3 dB（对数插值）", "at " + fmt(mid) + " = " + fmt(midDb));
        const double linearDb = -6.0 * (mid - 800.0) / 200.0;
        check(std::abs(midDb - linearDb) > 0.05, "不是线性频率插值", "linear 会给 " + fmt(linearDb));
    }
    {
        MicCalTable clamp;   // 端点非零：证明越界是「保持端点」而不是「补 0」
        clamp.points = {MicCalPoint{100.0, 3.0}, MicCalPoint{1000.0, -1.0}, MicCalPoint{10000.0, 2.0}};
        check(mic_cal_interp(clamp, 10.0) == 3.0, "低于最低点 → 端点 3 dB（不外推成 0）");
        check(mic_cal_interp(clamp, 48000.0) == 2.0, "高于最高点 → 端点 2 dB（不外推成 0）");
        check(mic_cal_interp(clamp, 0.0) == 3.0, "hz<=0 → 最低端（同上游）");
        check(mic_cal_interp(clamp, std::nan("")) == 3.0, "NaN → 最低端（同上游）");
        check(mic_cal_apply(clamp, 10.0, -10.0) == -13.0, "越界点 apply：−10 − 3 = −13");
        check(mic_cal_apply(clamp, 48000.0, 0.0) == -2.0, "高频越界 apply：0 − 2 = −2");
    }

    // ---------------- §4 接进「测量→算校正」：有表扣话筒，无表逐字节不变 ----------------
    // 判据（铁律 4）：
    //   a) 负向对照：无表时 helper 原样返回；build_corrections 与直接调用
    //      compute_correction_ir 逐元素相同 ⟹ 「没有表就什么都不改」不是靠注释保证。
    //   b) 有表时只改幅度：频谱幅度比必须等于 10^(−校准值/20)（逐 bin 对数插值），
    //      相位逐 bin 不变（乘的是正实数）。
    //   c) 路径等价：默认参数 / 显式 nullptr / 空表 三种「无表」调用结果完全一致。
    //   d) 频率选择性：1 kHz 有 −4 dB 校准 ⟹ 校正 IR 的「1k 相对 10k」比无表时下降约 4 dB；
    //      100 Hz 无校准 ⟹ 同一指标变化 < 0.5 dB（证明不是整体增益被改掉）。
    printf("[§4] 测量→算校正：扣话筒（只改幅度）+ 无表负向对照\n");
    {
        const double fs = 48000.0;
        // 合成房间 IR：5 ms 主峰 + 一对敲不对称的回声（频谱因此带非零相位）
        std::vector<double> ir(4096, 0.0);
        ir[240] = 1.0;
        ir[300] = 0.40;
        ir[301] = -0.15;

        // 校准表：1 kHz 处 −4 dB，两端 0 dB（对数频率插值 → 一条宽而平滑的凹口）
        MicCalTable cal;
        cal.points = {MicCalPoint{20.0, 0.0}, MicCalPoint{100.0, 0.0},
                      MicCalPoint{1000.0, -4.0}, MicCalPoint{10000.0, 0.0},
                      MicCalPoint{20000.0, 0.0}};
        check(cal.ok(), "合成校准表有效（≥3 点）");

        auto spectrum = [](const std::vector<double>& x) {
            const size_t n = next_pow2(x.size());
            std::vector<cplx> S(n, cplx(0.0, 0.0));
            for (size_t i = 0; i < x.size(); ++i) S[i] = cplx(x[i], 0.0);
            fft(S);
            return S;
        };
        auto nearest_bin = [](double hz, size_t n, double fs) {
            return (size_t)std::llround(hz * (double)n / fs);
        };
        auto mag_db = [](const cplx& v) { return 20.0 * std::log10(std::max(std::abs(v), 1e-12)); };

        // (a) 无表：helper 逐元素原样返回
        {
            const std::vector<double> same = subtract_mic_cal_from_ir(ir, fs, MicCalTable{});
            check(same.size() == ir.size(), "空表：长度不变", "size=" + std::to_string(same.size()));
            bool exact = same.size() == ir.size();
            for (size_t i = 0; exact && i < ir.size(); ++i) exact = (same[i] == ir[i]);
            check(exact, "空表：逐元素与输入完全相同（负向对照）");
        }

        // (b) 有表：只改幅度（幅度比 = 10^(−校准/20)，相位不变）
        {
            const std::vector<double> fixed = subtract_mic_cal_from_ir(ir, fs, cal);
            check(fixed.size() == ir.size(), "有表：长度不变", "size=" + std::to_string(fixed.size()));
            const auto S0 = spectrum(ir), S1 = spectrum(fixed);
            const size_t n = S0.size();
            const double probes[] = {100.0, 500.0, 1000.0, 2000.0, 10000.0};
            bool magOk = true, phaseOk = true;
            std::string magDetail, phaseDetail;
            for (double hz : probes) {
                const size_t k = nearest_bin(hz, n, fs);
                const double expectDelta = -mic_cal_interp(cal, (double)k * fs / (double)n);
                const double gotDelta = mag_db(S1[k]) - mag_db(S0[k]);
                magDetail += fmt(hz) + "→" + fmt(gotDelta) + "/" + fmt(expectDelta) + " ";
                if (std::abs(gotDelta - expectDelta) > 1e-9) magOk = false;
                const double dPhase = std::abs(std::arg(S1[k]) - std::arg(S0[k]));
                phaseDetail += fmt(hz) + "→" + fmt(dPhase) + " ";
                if (std::abs(S0[k]) > 1e-3 && dPhase > 1e-9) phaseOk = false;
            }
            check(magOk, "每个频点幅度比 = 10^(−校准值/20)（读数 − 校准，方向正确）", magDetail);
            check(phaseOk, "相位逐 bin 不变（补偿只乘正实数增益）", phaseDetail);
        }

        // (c) 接进 build_corrections：无表与旧路径逐元素相同
        MeasurementSessionResult res;
        {
            ChannelMeasurement cm;
            cm.channelName = "L";
            cm.valid = true;
            cm.roomIr = ir;
            res.channels.push_back(cm);
        }
        const TargetCurve target = TargetCurve::tilt(-1.0);
        const CorrectionOpts opts;
        const CorrectionSet base = build_corrections(res, target, opts, fs);
        const CorrectionSet noCal = build_corrections(res, target, opts, fs, 0.0, nullptr);
        const MicCalTable emptyCal;
        const CorrectionSet emptyCalSet = build_corrections(res, target, opts, fs, 0.0, &emptyCal);
        const std::vector<double> direct = compute_correction_ir(ir, fs, target, opts);
        {
            bool sameBase = base.correctionIrs.size() == 1 &&
                            base.correctionIrs[0].size() == direct.size();
            for (size_t i = 0; sameBase && i < direct.size(); ++i)
                sameBase = (base.correctionIrs[0][i] == direct[i]);
            check(sameBase, "默认参数 ≡ 直接 compute_correction_ir（逐元素相同）",
                  "taps=" + std::to_string(direct.size()));

            bool sameNoCal = noCal.correctionIrs.size() == 1 &&
                             noCal.correctionIrs[0].size() == base.correctionIrs[0].size();
            for (size_t i = 0; sameNoCal && i < base.correctionIrs[0].size(); ++i)
                sameNoCal = (noCal.correctionIrs[0][i] == base.correctionIrs[0][i]);
            check(sameNoCal, "显式 nullptr ≡ 旧调用（逐元素相同，负向对照）");

            bool sameEmpty = emptyCalSet.correctionIrs.size() == 1 &&
                             emptyCalSet.correctionIrs[0].size() == base.correctionIrs[0].size();
            for (size_t i = 0; sameEmpty && i < base.correctionIrs[0].size(); ++i)
                sameEmpty = (emptyCalSet.correctionIrs[0][i] == base.correctionIrs[0][i]);
            check(sameEmpty, "传空表 ≡ 无表（空表不改任何东西）");
        }

        // (d) 有表：频率选择性抬升（1 kHz 该抬，100 Hz 不该抬）
        const CorrectionSet withCal = build_corrections(res, target, opts, fs, 0.0, &cal);
        {
            const size_t n = next_pow2(2 * (size_t)opts.taps);
            auto corrMagDb = [&](const std::vector<double>& h, double hz) {
                std::vector<cplx> S(n, cplx(0.0, 0.0));
                for (size_t i = 0; i < h.size() && i < n; ++i) S[i] = cplx(h[i], 0.0);
                fft(S);
                const size_t k = nearest_bin(hz, n, fs);
                return mag_db(S[k]);
            };
            // 用「相对 10 kHz」的形状指标，消掉末端 200 Hz~2 kHz 归一化带来的整体增益差
            const double base1k = corrMagDb(base.correctionIrs[0], 1000.0) - corrMagDb(base.correctionIrs[0], 10000.0);
            const double cal1k = corrMagDb(withCal.correctionIrs[0], 1000.0) - corrMagDb(withCal.correctionIrs[0], 10000.0);
            const double base100 = corrMagDb(base.correctionIrs[0], 100.0) - corrMagDb(base.correctionIrs[0], 10000.0);
            const double cal100 = corrMagDb(withCal.correctionIrs[0], 100.0) - corrMagDb(withCal.correctionIrs[0], 10000.0);
            const double lift1k = cal1k - base1k;
            const double lift100 = cal100 - base100;
            // 方向：校准 −4 dB = 话筒该频点本身偏低 ⟹ 房间读数里那个「假凹口」被填平 4 dB
            // ⟹ 校正 IR 对该频点的抬升必须**减少**约 4 dB（读数 − 校准 = 读数 + 4）。
            check(lift1k < -2.0, "1 kHz 校正相对 10 kHz 比无表时下降 > 2 dB（话筒 −4 dB 已从房间读数填平）",
                  "lift=" + fmt(lift1k) + " dB（base=" + fmt(base1k) + " cal=" + fmt(cal1k) + "）");
            check(std::abs(lift100) < 0.5, "100 Hz（校准为 0 dB）同一指标变化 < 0.5 dB（不是整体增益）",
                  "lift=" + fmt(lift100) + " dB");
            check(withCal.channelNames == base.channelNames && withCal.fs == base.fs &&
                  withCal.taps == base.taps, "有表时校正集元数据不变（声道/fs/taps）");
        }
    }

    printf("test_mic_cal: %d/%d 通过 %s\n", total - fails, total, fails == 0 ? "PASS" : "FAIL");
    return fails == 0 ? 0 : 1;
}
