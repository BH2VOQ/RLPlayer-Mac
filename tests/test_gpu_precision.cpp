// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_gpu_precision.cpp — 把 tools/gpu_precision 的【本机实测结论】固化成 ctest 判据
//
// ============================================================================
// 这个测试与 tools/gpu_precision.cpp 的分工
// ============================================================================
//   tools/gpu_precision.cpp  = 探针。它【测】并打印矩阵，阈值由人读表后决定。
//   本文件                   = 门禁。它把 mac 上已经实测出来的量级钉成回归判据，
//                              防止将来某个改动让精度悄悄退化却没人发现。
//
// 判据里的每一个阈值都来自 tools/gpu_precision 在本机（macOS 27.0.1 / arm64 / M4）
// 的实测值，并留出明确裕量。**不是照抄上游 CUDA/HIP 的数字**——上游的
// "−127.6~−147.8 dB" 是 HIP 的实测，本机卷积实测落在 −130.3~−146.5 dB，
// 形态相近但极值不同，所以阈值按本机数字取。
//
// ============================================================================
// 铁律 3 自省：这些判据真的能证明要证明的事吗？
// ============================================================================
// 1) 不能只断言"误差小于 X" —— 全零输出对全零输入也满足。所以：
//    * 每条断言前先确认参考信号有能量（|cpu| 峰值 > 0.01）；
//    * 每条断言前先确认 GPU 输出非全零（kernel 静默不执行时会保持初值 0，
//      这正是 HIP 铁律 5 记录过的事故形态）；
//    * 断言"差异样数 > 0"——float 路径与 double 参考不可能逐位相同，
//      若报告 0 个差异样，说明根本没算。
//
// 2) 精度阈值用【相对 RMS】而不是 max|Δ|/峰值 做主要判据：
//    max 类指标由单个样点决定，对输入构造敏感、容易因为换了素材就假红；
//    相对 RMS 是能量口径，更稳。max|Δ|/峰值 作为次要判据一起卡（防止
//    "整体 RMS 好但某处爆一个样点"被漏掉）。
//
// 3) 升频这条**故意不用窄阈值**：mac 的 Metal 升频是 float 路径，本机实测
//    max|Δ|/峰值 到 8.3e-06。上游 CUDA/HIP 的 "≤1e-12 / ≤2 ULP" 口径在 mac 上
//    【完全不成立】。所以本测试卡的是 float 量级的阈值，并在打印里写明
//    这是 mac 口径，防止后人拿上游数字来"收紧"这个阈值。
//
// 4) GPU 不可用不算失败，但必须明确打印 [SKIP] 与原因——
//    不允许把"没测到"写成"通过"（铁律 4）。
//
// 5) 【已知缺陷】第 5 节把生产调用形态（4096 样一块逐块调用整块 API）的
//    IR 拖尾丢失固定成一个"已知问题"断言：它断言"当前确实会丢"。
//    这样做的目的：一旦有人修好了生产路径，这条会【变红】，
//    提醒接手者"该把这条改成正向判据了"，而不是让问题悄悄被忘记。
//    ⚠️ 这条不是"期望的行为"，是"如实记录的现状"。见文件内注释与回报。
#include <dlfcn.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// ---- dylib 里那 4 个符号的真实签名（与 test_gpu_metal.cpp 保持一致）----
// ⚠️ 返回值语义不同：
//    rta_gpu_convolve : 0 = 成功，非 0 = 失败
//    rta_gpu_resample : (int)nOut = 成功，-1 = 失败
using FnAvail      = int  (*)();
using FnConvolve   = int  (*)(const double*, long long, const double*, long long, double*, int);
using FnResample   = int  (*)(const double*, int, long long, const double*, int, int,
                              const int*, const int*, long long, double*);
using FnInvalidate = void (*)();

static int g_fail = 0;
static int g_pass = 0;

static void ck(bool cond, const char* what, const char* detail = "") {
    if (cond) { std::printf("  [PASS] %s%s%s\n", what, *detail ? "  " : "", detail); ++g_pass; }
    else      { std::printf("  [FAIL] %s  %s\n", what, detail); ++g_fail; }
}

// 确定性 xorshift（与 tools/gpu_precision.cpp 同款）：测试可复现
static uint64_t s_seed = 0x123456789ABCDEFull;
static double rnd() {
    s_seed ^= s_seed >> 12; s_seed ^= s_seed << 25; s_seed ^= s_seed >> 27;
    return (double)((s_seed * 2685821657736338717ull) >> 11) / 9007199254740992.0 * 2.0 - 1.0;
}

// 音乐样输入（与探针同款，保证两边测的是同一族信号）
static std::vector<double> music_like(size_t n) {
    std::vector<double> x(n);
    double pk = 0.0;
    for (size_t i = 0; i < n; ++i) {
        const double v = 0.32 * std::sin(2 * 3.14159265358979 * 997.0  * (double)i / 48000.0)
                       + 0.21 * std::sin(2 * 3.14159265358979 * 1234.0 * (double)i / 48000.0)
                       + 0.13 * std::sin(2 * 3.14159265358979 * 3141.0 * (double)i / 48000.0)
                       + 0.25 * rnd() * (0.02 + 0.98 / (1.0 + (double)(i % 4096) / 64.0));
        x[i] = v;
        pk = std::max(pk, std::fabs(v));
    }
    for (auto& v : x) v *= 0.7 / pk;
    return x;
}

// 房间校正样 IR（指数衰减 + 平滑噪声）
static std::vector<double> room_like_ir(size_t n) {
    std::vector<double> h(n);
    double prev = 0.0, pk = 0.0;
    for (size_t i = 0; i < n; ++i) {
        prev = 0.72 * prev + 0.28 * rnd();
        h[i] = prev * std::exp(-6.5 * (double)i / (double)n);
        pk = std::max(pk, std::fabs(h[i]));
    }
    for (auto& v : h) v /= pk;
    return h;
}

static double peak_abs(const std::vector<double>& v) {
    double m = 0.0;
    for (double x : v) m = std::max(m, std::fabs(x));
    return m;
}

static bool all_zero(const std::vector<double>& v) {
    for (double x : v) if (x != 0.0) return false;
    return true;
}

// CPU 参考：直接卷积（双精度定义式）。只用于短 IR，避免 O(N·M) 太慢。
static std::vector<double> direct_convolve(const std::vector<double>& x,
                                           const std::vector<double>& h) {
    std::vector<double> y(x.size(), 0.0);
    for (size_t i = 0; i < x.size(); ++i) {
        double acc = 0.0;
        for (size_t k = 0; k < h.size() && k <= i; ++k) acc += x[i - k] * h[k];
        y[i] = acc;
    }
    return y;
}

// 相对 RMS（dB）。se = Σ|Δ|²，sr = Σ|ref|²，n = 样点数。
static double rel_rms_db(double se, double sr, size_t n) {
    if (n == 0) return 999.0;
    if (se <= 0.0) return -999.0;
    return 10.0 * std::log10((se / (double)n) / (sr / (double)n + 1e-300) + 1e-300);
}

// 一格的卷积比对结果
struct ConvStat {
    double relDb = 999.0, maxAbsNorm = 0.0, cpuPeak = 0.0;
    long long nDiff = 0;
    bool gpuNonZero = false;
};

// 按【整块调用】口径比对：yCpu 带 B 帧延迟 ⟹ yGpu[k] vs yCpu[B+k]
static ConvStat compare_conv(const std::vector<double>& yGpu, const std::vector<double>& yCpu,
                             size_t B) {
    ConvStat s;
    if (yCpu.size() <= B + 1) return s;
    const size_t m = yCpu.size() - B - 1;
    double se = 0.0, sr = 0.0, mx = 0.0, pk = 0.0;
    for (size_t k = 0; k < m; ++k) {
        const double gv = yGpu[k], cv = yCpu[B + k];
        const double d = gv - cv;
        se += d * d; sr += cv * cv;
        mx = std::max(mx, std::fabs(d));
        pk = std::max(pk, std::fabs(cv));
        if (d != 0.0) ++s.nDiff;
    }
    s.cpuPeak = pk;
    s.relDb = rel_rms_db(se, sr, m);
    s.maxAbsNorm = mx / (pk + 1e-300);
    s.gpuNonZero = !all_zero(yGpu);
    return s;
}

// CPU 生产路径参考：StreamingConvolver（双精度，带 B 帧算法延迟）
// 为了不把 dsp 头拖进来（本测试刻意只依赖 dlfcn，与 test_gpu_metal.cpp 一致），
// 这里用等价的分块 FFT 实现太啰嗦 —— 改用"直接卷积 + 补 B 个零"来等价，
// 只在短 IR / 短输入上用，语义与 StreamingConvolver 完全一致（同样的延迟、同样的值）。
static std::vector<double> cpu_reference_with_latency(const std::vector<double>& x,
                                                      const std::vector<double>& h,
                                                      size_t B) {
    const std::vector<double> y = direct_convolve(x, h);
    std::vector<double> out(B, 0.0);
    out.insert(out.end(), y.begin(), y.end());
    out.resize(x.size(), 0.0);          // 与 StreamingConvolver 一样：输出长度 == 输入长度
    return out;
}

int main(int argc, char** argv) {
    std::printf("== test_gpu_precision（mac / Metal 口径）==\n");

    // ---- dylib 路径解析：argv[1] → __FILE__ 反推仓库根 → cwd → 上一级 ----
    std::vector<std::string> cands;
    if (argc > 1) cands.push_back(argv[1]);
    {
        std::string f = __FILE__;
        const size_t s1 = f.find_last_of('/');
        if (s1 != std::string::npos) {
            const std::string testsDir = f.substr(0, s1);
            const size_t s2 = testsDir.find_last_of('/');
            if (s2 != std::string::npos) cands.push_back(testsDir.substr(0, s2) + "/librtagpu.dylib");
            cands.push_back(testsDir + "/../librtagpu.dylib");
        }
    }
    cands.push_back("librtagpu.dylib");
    cands.push_back("../librtagpu.dylib");

    void* h = nullptr;
    std::string path, lastErr;
    for (const auto& c : cands) {
        h = dlopen(c.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (h) { path = c; break; }
        const char* e = dlerror();
        if (lastErr.empty()) lastErr = e ? e : "未知原因";
    }
    if (!h) {
        std::printf("[SKIP] 无法加载 librtagpu.dylib —— %s\n", lastErr.c_str());
        std::printf("       GPU 是可选加速：缺失时管线自动退回 CPU，不算失败。\n");
        std::printf("       构建方法：bash tools/build_gpu_metal_mac.sh\n");
        std::printf("       ⚠️ 本机 GPU 精度【未验证】—— 不要把这条 SKIP 当成通过（铁律 4）。\n");
        return 0;
    }
    std::printf("dylib: %s\n", path.c_str());

    auto avail = (FnAvail)dlsym(h, "rta_gpu_available");
    auto conv  = (FnConvolve)dlsym(h, "rta_gpu_convolve");
    auto res   = (FnResample)dlsym(h, "rta_gpu_resample");
    auto inval = (FnInvalidate)dlsym(h, "rta_gpu_resample_invalidate");
    if (!avail || !conv || !res || !inval) {
        std::printf("[FAIL] 导出符号不全（桥接层会静默退回 CPU）\n");
        dlclose(h);
        return 1;
    }

    if (avail() != 1) {
        std::printf("[SKIP] rta_gpu_available() != 1（Metal 不可用或平凡 kernel 验活失败）\n");
        std::printf("       ⚠️ 本机 GPU 精度【未验证】（铁律 4）。\n");
        dlclose(h);
        return 0;
    }
    std::printf("rta_gpu_available() = 1\n");

    // =====================================================================
    // 1) 门 2：端到端通路（恒等卷积 δ IR + 多分区）
    // =====================================================================
    std::printf("\n-- 1) 端到端通路门 --\n");
    {
        const std::vector<double> x = music_like(4096);
        const std::vector<double> delta = { 1.0 };
        std::vector<double> y(4096, -7.0);
        const int rc = conv(x.data(), 4096, delta.data(), 1, y.data(), 1024);
        double mx = 0.0;
        bool sentinel = false;
        for (size_t i = 0; i < x.size(); ++i) {
            mx = std::max(mx, std::fabs(y[i] - x[i]));
            if (y[i] == -7.0) sentinel = true;
        }
        char buf[160];
        std::snprintf(buf, sizeof(buf), "rc=%d max|y-x|=%.3e（本机实测 1.979e-08，判据 ≤1e-5）", rc, mx);
        ck(rc == 0 && mx <= 1e-5 && !sentinel, "恒等卷积(δ IR)通路活着", buf);
    }
    {
        // IR=2048 / block=512 ⟹ P=4，真的跨分区（不是 P=1 的单分区冒充）
        const size_t n = 8192, irLen = 2048, B = 512;
        std::vector<double> x(n), ir(irLen);
        for (auto& v : x) v = rnd() * 0.5;
        for (auto& v : ir) v = rnd() * 0.5;
        const std::vector<double> ref = direct_convolve(x, ir);
        std::vector<double> y(n, -7.0);
        const int rc = conv(x.data(), (long long)n, ir.data(), (long long)irLen, y.data(), (int)B);
        std::vector<double> diff(n);
        for (size_t i = 0; i < n; ++i) diff[i] = y[i] - ref[i];
        const double rel = peak_abs(diff) / (peak_abs(ref) + 1e-300);
        char buf[200];
        std::snprintf(buf, sizeof(buf), "rc=%d P=%zu max|Δ|/峰值=%.3e（本机实测 6.122e-08，判据 ≤1e-5）",
                      rc, irLen / B, rel);
        ck(rc == 0 && rel <= 1e-5, "多分区(P=4)与定义式一致", buf);
    }

    // =====================================================================
    // 2) 卷积精度回归（mac 实测阈值，非上游数字）
    // =====================================================================
    // 探针实测全矩阵（tools/gpu_precision，16 格全过，3 次重跑逐位一致）：
    //     相对 RMS 最差 −126.5 dB（B=512 IR=65536），最好 −148.4 dB；
    //     max|Δ|/峰值 最差 6.72e-07。
    //
    // ⚠️ 本测试【覆盖不到全矩阵】：CPU 参考用的是 O(N·M) 直接卷积（为了不依赖 dsp 头、
    //    也不引入"参考自己错"的风险），所以 IR 只能取到 16384 量级 ——
    //    32k 样 × 65536 抽头 = 21 亿次乘加，跑一次要几十秒，不适合进门禁。
    //    因此下面两格的实测值（−133.4 / −135.3 dB）**优于**探针的最差格 −126.5 dB。
    //    这是本测试已知的覆盖缺口，已在 docs/WIP-F6-GPU精度.md §11 挂账。
    //
    // 阈值取：
    //     相对 RMS ≤ −120 dB —— 对本测试实际覆盖的两格留 13~15 dB 裕量；
    //                          对探针最差格（−126.5）仍有 6.5 dB 裕量。
    //     max|Δ|/峰值 ≤ 2e-6 —— 对实测 4.00e-07 留 5 倍裕量。
    // 这两个数**故意比实测松**：目的是抓"精度掉一个数量级"的回归，
    // 不是复述实测值。要精确值请看 tools/gpu_precision 的输出。
    std::printf("\n-- 2) 卷积精度回归（阈值 −120 dB / 2e-6；探针全矩阵最差 −126.5 dB / 6.72e-07）--\n");
    {
        // 代表性两格：最差格（B=512, IR=16384）与大 IR 格（B=1024, IR=65536）
        struct Cell { size_t B, irLen; };
        const Cell cells[] = { { 512, 16384 }, { 1024, 65536 } };
        const std::vector<double> x = music_like(32768);
        for (const Cell& c : cells) {
            const std::vector<double> ir = room_like_ir(c.irLen);
            const std::vector<double> yCpu = cpu_reference_with_latency(x, ir, c.B);
            std::vector<double> yGpu(x.size(), 0.0);
            const int rc = conv(x.data(), (long long)x.size(), ir.data(), (long long)ir.size(),
                                yGpu.data(), (int)c.B);
            char buf[256];
            if (rc != 0) {
                std::snprintf(buf, sizeof(buf), "B=%zu IR=%zu rc=%d", c.B, c.irLen, rc);
                ck(false, "卷积调用成功", buf);
                continue;
            }
            const ConvStat s = compare_conv(yGpu, yCpu, c.B);
            std::snprintf(buf, sizeof(buf),
                          "B=%zu IR=%zu: 相对RMS=%.1f dB max|Δ|/峰=%.2e 差异样=%lld 参考峰=%.3f",
                          c.B, c.irLen, s.relDb, s.maxAbsNorm, s.nDiff, s.cpuPeak);
            // 三条一起卡：非退化输入 + GPU 真的算了 + 精度达标
            const bool ok = s.cpuPeak > 0.01 && s.gpuNonZero && s.nDiff > 0
                         && s.relDb <= -120.0 && s.maxAbsNorm <= 2e-6;
            ck(ok, "卷积精度在 mac 阈值内", buf);
        }
    }

    // =====================================================================
    // 3) 升频精度回归（mac = float 路径；**不是** 上游的 ≤1e-12）
    // =====================================================================
    // 本机实测（tools/gpu_precision 第 5 节）：
    //     44.1k→352800：max|Δ|/峰值 8.279e-06，相对 RMS −115.4 dB
    //     44.1k→384000：max|Δ|/峰值 1.009e-06，相对 RMS −132.5 dB
    // ⚠️ 上游 CUDA/HIP 是 FP64 路径，实测 max|Δ|≈3.3e-16（−316 dB）。
    //    mac 的 Apple GPU 没有 double，升频只能走 float ⟹ 差 10 个数量级。
    //    这里卡 ≤ −100 dB / 1e-4 是 float 量级阈值，**不许拿上游数字来收紧**。
    std::printf("\n-- 3) 升频精度回归（mac float 口径；本机实测最差 −132.6 dB / 4.39e-07）--\n");
    // 三档抽头规模都要测（铁律 3：单档偶然通过会掩盖"抽头越多越差"的趋势）：
    //    L=16   T=8      —— 基本规模
    //    L=1280 T=204    —— 生产 44.1k→384k 的真实参数（resampler.h 两段式第二级）
    //    L=16   T=32768  —— 生产 44.1k→352.8k 两段式第一级的抽头规模
    // 本机实测这三档最差 −132.6 dB / 4.39e-07，阈值仍按 float 量级取 ≤−100 dB / 1e-4。
    {
        const int ch = 2;
        const long long histLen = 256, nOut = 400;
        const int dims[3][2] = { { 16, 8 }, { 1280, 204 }, { 16, 32768 } };
        double worstDb = -1e300, worstNorm = 0.0;
        bool allOk = true;
        for (const auto& d : dims) {
        const int L = d[0], T = d[1];
        std::vector<double> hist((size_t)ch * (size_t)histLen);
        for (auto& v : hist) v = rnd();
        std::vector<double> phases((size_t)L * (size_t)T);
        for (auto& v : phases) v = rnd();
        std::vector<int> bases((size_t)nOut), phIdx((size_t)nOut);
        for (long long n = 0; n < nOut; ++n) {
            bases[(size_t)n] = (int)((n * 37) % histLen);        // 确定性，不依赖 <random>
            phIdx[(size_t)n] = (int)((n * 7) % L);
        }
        // CPU 参考：严格照 resampler.h:288 与 gpu_resample_hip.cpp:42-49
        std::vector<double> ref((size_t)nOut * (size_t)ch, 0.0);
        for (long long n = 0; n < nOut; ++n) {
            const int base = bases[(size_t)n], p = phIdx[(size_t)n];
            int uEnd = base + 1;
            if (uEnd > T) uEnd = T;
            if (uEnd > histLen) uEnd = (int)histLen;
            for (int c = 0; c < ch; ++c) {
                const double* hh = hist.data() + (size_t)c * (size_t)histLen;
                const double* ph = phases.data() + (size_t)p * (size_t)T;
                double acc = 0.0;
                for (int u = 0; u < uEnd; ++u) acc += ph[(size_t)u] * hh[base - u];
                ref[(size_t)n * (size_t)ch + (size_t)c] = acc;
            }
        }
        std::vector<double> out((size_t)nOut * (size_t)ch, 0.0);
        const int rc = res(hist.data(), ch, histLen, phases.data(), L, T,
                           bases.data(), phIdx.data(), nOut, out.data());
        // ⚠️ 成功判据是 rc == nOut，不是 rc == 0
        char buf[256];
        if (rc != (int)nOut) {
            std::snprintf(buf, sizeof(buf), "L=%d T=%d: rta_gpu_resample 返回 %d，应为 nOut=%lld",
                          L, T, rc, nOut);
            ck(false, "升频调用成功（成功返回帧数，不是 0）", buf);
            allOk = false;
        } else {
            double se = 0.0, sr = 0.0, mx = 0.0;
            for (size_t i = 0; i < ref.size(); ++i) {
                const double dd = out[i] - ref[i];
                se += dd * dd; sr += ref[i] * ref[i];
                mx = std::max(mx, std::fabs(dd));
            }
            const double pk = peak_abs(ref);
            const double db = rel_rms_db(se, sr, ref.size());
            const double norm = mx / (pk + 1e-300);
            worstDb = std::max(worstDb, db);
            worstNorm = std::max(worstNorm, norm);
            std::snprintf(buf, sizeof(buf),
                          "L=%-5d T=%-6d 相对RMS=%.1f dB max|Δ|/峰=%.2e 参考峰=%.3f",
                          L, T, db, norm, pk);
            // 三档各自都要过：非退化参考 + GPU 真的算了 + 精度达标
            const bool ok = pk > 1e-3 && !all_zero(out) && db <= -100.0 && norm <= 1e-4;
            if (!ok) allOk = false;
            ck(ok, "升频精度在 mac float 阈值内", buf);
        }
        }
        char sum[200];
        std::snprintf(sum, sizeof(sum),
                      "三档最差 相对RMS=%.1f dB max|Δ|/峰=%.2e（判据 ≤−100 dB 且 ≤1e-4）",
                      worstDb, worstNorm);
        ck(allOk, "升频三档全部达标", sum);
    }

    // =====================================================================
    // 4) 【已知缺陷】生产调用形态的 IR 拖尾丢失
    // =====================================================================
    // 现状（本机实测，tools/gpu_precision 第 6 节）：
    //   生产管线 pipeline.h:323 每次只喂 w.size() ≤ 4096 样给无状态的整块卷积 API。
    //   只要 irLen > 块长，上一块输入 × 本块 IR 尾巴这一项就没有任何地方被计算。
    //   实测：δ 在样点 0、IR=65536、16 块 × 4096 ⟹ 只有第 0 块有输出，
    //         其余 15 块全零，61440/65536 个样点不符，相对 RMS −1.63 dB。
    //
    // ⚠️ 这条断言的是"当前确实会丢"（红→红），**不是**"期望的行为"。
    //    目的是让修复者一改就变红，从而被迫把这条改成正向判据，而不是忘掉它。
    std::printf("\n-- 4) 生产调用形态：IR 拖尾（已知缺陷，断言「当前会丢」）--\n");
    {
        const size_t B = 4096, nCh = 4, n = B * nCh, irLen = 16384;
        std::vector<double> x(n, 0.0);
        x[0] = 1.0;
        std::vector<double> ir(irLen);
        for (size_t i = 0; i < irLen; ++i) ir[i] = std::exp(-3.0 * (double)i / (double)irLen);
        std::vector<double> out(n, 0.0), tmp(B, 0.0);
        for (size_t c = 0; c < nCh; ++c) {
            if (conv(x.data() + c * B, (long long)B, ir.data(), (long long)irLen,
                     tmp.data(), 1024) != 0) {
                for (size_t i = 0; i < B; ++i) tmp[i] = 0.0;
            }
            for (size_t i = 0; i < B; ++i) out[c * B + i] = tmp[i];
        }
        // 真值：δ × ir = ir（0..irLen-1 有值）
        size_t lost = 0;
        for (size_t i = 0; i < irLen && i < n; ++i)
            if (std::fabs(out[i] - ir[i]) > 1e-9) ++lost;
        // 判定：块 1..nCh-1 是否全零（= 拖尾全丢）
        bool tailAllZero = true;
        for (size_t i = B; i < n; ++i) if (out[i] != 0.0) tailAllZero = false;
        char buf[256];
        std::snprintf(buf, sizeof(buf),
                      "IR=%zu/块=%zu：不符样点 %zu/%zu，块 1..%zu 全零=%s",
                      irLen, B, lost, (size_t)std::min(irLen, n), nCh - 1,
                      tailAllZero ? "是（拖尾全丢）" : "否");
        // 期望：拖尾确实全丢（= 现状）。若变红说明生产路径被修好了。
        ck(tailAllZero && lost > 0, "【已知缺陷】逐块调用整块 API 丢 IR 拖尾", buf);
        if (!(tailAllZero && lost > 0)) {
            std::printf("       ↑ 这条变红意味着生产路径【已经修好】了。\n");
            std::printf("         请把这条改成正向判据（要求 out[i]==ir[i]），并更新\n");
            std::printf("         docs/WIP-F6-GPU精度.md 与 debug/ 清单里的 F-6 挂账。\n");
        }
    }

    // =====================================================================
    dlclose(h);
    std::printf("\n%s（%d PASS / %d FAIL）\n", g_fail ? "[FAIL]" : "[PASS]", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
