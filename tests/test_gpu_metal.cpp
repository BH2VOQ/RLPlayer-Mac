// test_gpu_metal.cpp — macOS Metal GPU 后端（librtagpu.dylib）的数值正确性门禁
//
// 纯 C++，【不链接】dylib：用 dlopen 运行时加载，与管线真实的调用方式完全一致。
// 为什么必须这样测：桥接层（gpu_bridge.h / resampler.h）就是 dlopen + dlsym，
// 如果测试改成链接期依赖，符号名写错、导出被 dead_strip 掉这类问题就测不出来。
//
// ---- 判据说明（铁律 3：这个指标真的能证明我要证明的事吗？）----
// 1. GPU 内部用 float（Apple GPU 没有 double），CPU 参考用 double，
//    所以【不可能逐位相同】。判据用「相对误差」而不是逐位比较：
//        rel = max|gpu - cpu| / max|cpu|
//    任务书要求 < 1e-6。实测值见下方打印（float32 有 24 bit 有效位，
//    理论上单次运算相对误差 ~6e-8，累加若干项后仍在 1e-6 量级）。
//
// 2. 但「相对误差小」还不够 —— 全零输出对全零输入也满足误差判据。
//    所以额外断言：参考信号必须有足够能量（非退化输入），且 GPU 输出
//    不能是全零（能区分「真的算了」和「kernel 没执行、buffer 保持初值」）。
//    这正是 HIP 铁律 5 的教训：kernel 静默不执行时输出缓冲全零。
//
// 3. 卷积用【冲激 + 随机 FIR】两组：
//    * 冲激测试：in = δ[n] ⟹ out 必须逐点等于 ir（这是卷积的定义，
//      任何 FFT/分块/overlap-add 的索引或补零错误都会在这里暴露成明显偏差）。
//    * 随机测试：覆盖真实的宽带信号 × 长 IR，考察 float 频谱乘的累积误差。
//    只做随机测试会掩盖「索引错位但统计上接近」的错误，所以两者都要。
//
// 4. 升频：除了随机相位表，还单独测【相位表首相位恒等】的特例 ——
//    phases[0] = {1,0,0,...} 时，base 处的输出必须精确等于 hist[c][base]。
//    这能钉住 base-u 递减索引方向：如果实现写成 base+u，这个用例会立刻失败。
//
// 5. rta_gpu_resample_invalidate() 之后必须重传相位表。测试做法是：
//    换一组相位表 → invalidate → 再算一遍 → 结果必须与不 invalidate 时一致，
//    且必须等于【新】相位表的 CPU 参考（不是旧相位表的）。
//    只比「两次结果相同」是不够的：如果 invalidate 后相位表没重传，
//    而 L/T 又没变，两次都会用同一份【旧】缓存 —— 结果自洽但全是错的。
#include <dlfcn.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// ---- dylib 里那 4 个符号的真实签名 ----
// ⚠️ 注意两个函数的返回值语义【不同】：
//    rta_gpu_convolve : 0 = 成功，非 0 = 失败（pipeline.h 判 == 0）
//    rta_gpu_resample : (int)nOut = 成功，-1 = 失败（resampler.h 判 == produced）
using FnAvail     = int  (*)();
using FnConvolve  = int  (*)(const double*, long long, const double*, long long, double*, int);
using FnResample  = int  (*)(const double*, int, long long, const double*, int, int,
                             const int*, const int*, long long, double*);
using FnInvalidate = void (*)();

static int g_fail = 0;

static void fail(const char* what) {
    printf("  [FAIL] %s\n", what);
    ++g_fail;
}

// 相对误差：max|gpu-cpu| / max|cpu|（分母用 max|cpu|，对单点误差最敏感）
static double rel_max_err(const std::vector<double>& gpu, const std::vector<double>& cpu) {
    double num = 0.0, den = 0.0;
    for (size_t i = 0; i < cpu.size(); ++i) {
        const double e = std::fabs(gpu[i] - cpu[i]);
        if (e > num) num = e;
        const double a = std::fabs(cpu[i]);
        if (a > den) den = a;
    }
    if (den <= 0.0) return (num <= 0.0) ? 0.0 : 1e30;   // 退化：参考全零
    return num / den;
}

// 朴素直接卷积（双精度）：out[i] = Σ_k in[i-k]·ir[k]，k < irLen 且 k <= i
static std::vector<double> cpu_convolve(const std::vector<double>& in, const std::vector<double>& ir) {
    std::vector<double> out(in.size(), 0.0);
    for (size_t i = 0; i < in.size(); ++i) {
        double acc = 0.0;
        for (size_t k = 0; k < ir.size() && k <= i; ++k) acc += in[i - k] * ir[k];
        out[i] = acc;
    }
    return out;
}

// 多相升频的 CPU 参考，逐行照 src/dsp/resampler.h:278-292 与
// src/gpu/gpu_resample_hip.cpp:42-49 写（hist 声道主序、base-u 递减、uEnd 截断）
static std::vector<double> cpu_resample(const std::vector<double>& hist, int ch, long long histLen,
                                        const std::vector<double>& phases, int L, int T,
                                        const std::vector<int>& bases, const std::vector<int>& phIdx,
                                        long long nOut) {
    std::vector<double> out((size_t)nOut * (size_t)ch, 0.0);
    for (long long n = 0; n < nOut; ++n) {
        const int base = bases[(size_t)n];
        const int p    = phIdx[(size_t)n];
        int uEnd = base + 1;
        if (uEnd > T)       uEnd = T;
        if (uEnd > histLen) uEnd = (int)histLen;
        for (int c = 0; c < ch; ++c) {
            const double* h = hist.data() + (size_t)c * (size_t)histLen;
            const double* ph = phases.data() + (size_t)p * (size_t)T;
            double acc = 0.0;
            for (int u = 0; u < uEnd; ++u) acc += ph[(size_t)u] * h[base - u];
            out[(size_t)n * (size_t)ch + (size_t)c] = acc;
        }
    }
    return out;
}

static bool all_zero(const std::vector<double>& v) {
    for (double x : v) if (x != 0.0) return false;
    return true;
}

static double max_abs(const std::vector<double>& v) {
    double m = 0.0;
    for (double x : v) m = std::fmax(m, std::fabs(x));
    return m;
}

int main(int argc, char** argv) {
    // dylib 路径解析顺序（ctest 的 cwd 是 build-mac，不是仓库根，所以要多试几个）：
    //   1) argv[1] 显式指定
    //   2) 仓库根（由本文件路径 __FILE__ 反推，最可靠）
    //   3) 当前目录 / 上一级（兼容手动在仓库根或 build-mac 里跑）
    std::vector<std::string> cands;
    if (argc > 1) cands.push_back(argv[1]);
    {
        // __FILE__ 形如 /abs/path/RLPlayer/tests/test_gpu_metal.cpp
        std::string f = __FILE__;
        const size_t slash = f.find_last_of('/');
        if (slash != std::string::npos) {
            const std::string testsDir = f.substr(0, slash);
            const size_t slash2 = testsDir.find_last_of('/');
            if (slash2 != std::string::npos) cands.push_back(testsDir.substr(0, slash2) + "/librtagpu.dylib");
            cands.push_back(testsDir + "/../librtagpu.dylib");
        }
    }
    cands.push_back("librtagpu.dylib");
    cands.push_back("../librtagpu.dylib");

    printf("== test_gpu_metal ==\n");

    // ---- 1) 全部候选都加载不到 → SKIP（GPU 是锦上添花，缺失不算失败）----
    void* h = nullptr;
    std::string path;
    std::string lastErr;
    for (const auto& c : cands) {
        h = dlopen(c.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (h) { path = c; break; }
        const char* e = dlerror();
        if (lastErr.empty()) lastErr = e ? e : "未知原因";
    }
    if (!h) {
        printf("尝试过的路径：\n");
        for (const auto& c : cands) printf("  %s\n", c.c_str());
        printf("[SKIP] 无法加载 librtagpu.dylib —— %s\n", lastErr.c_str());
        printf("       GPU 是可选加速：缺失时管线自动退回 CPU，不算失败。\n");
        printf("       构建方法：bash tools/build_gpu_metal_mac.sh\n");
        return 0;
    }
    printf("dylib: %s\n", path.c_str());

    // ---- 2) 4 个符号一个都不能少 ----
    dlerror();
    auto avail      = (FnAvail)dlsym(h, "rta_gpu_available");
    auto conv       = (FnConvolve)dlsym(h, "rta_gpu_convolve");
    auto res        = (FnResample)dlsym(h, "rta_gpu_resample");
    auto invalidate = (FnInvalidate)dlsym(h, "rta_gpu_resample_invalidate");
    if (!avail)      fail("缺少符号 rta_gpu_available");
    if (!conv)       fail("缺少符号 rta_gpu_convolve");
    if (!res)        fail("缺少符号 rta_gpu_resample");
    if (!invalidate) fail("缺少符号 rta_gpu_resample_invalidate");
    if (g_fail) { printf("[FAIL] 导出符号不全，桥接层会静默退回 CPU\n"); return 1; }
    printf("  4 个导出符号全部取到\n");

    // ---- 3) rta_gpu_available() 必须返回 1（内部已真跑平凡 kernel 验活）----
    const int a = avail();
    printf("  rta_gpu_available() = %d\n", a);
    if (a != 1) {
        printf("[FAIL] rta_gpu_available() != 1（Metal 不可用或平凡 kernel 验活失败）\n");
        return 1;
    }

    // =====================================================================
    // 4) 卷积正确性
    // =====================================================================
    printf("\n-- 卷积正确性 --\n");
    std::mt19937 rng(20251025);
    std::uniform_real_distribution<double> dist(-0.5, 0.5);

    // ---- 4a) 冲激测试：in = δ[n] ⟹ out 必须等于 ir ----
    {
        const int n = 4096, irLen = 512;
        std::vector<double> in(n, 0.0), ir(irLen);
        in[0] = 1.0;
        for (auto& v : ir) v = dist(rng);

        std::vector<double> out(n, 0.0);
        const int rc = conv(in.data(), (long long)n, ir.data(), (long long)irLen, out.data(), 1024);
        if (rc != 0) {
            fail("冲激测试：rta_gpu_convolve 返回非 0");
        } else {
            // 参考：δ 卷积 = ir 补零（CPU 直接卷积同样能算，但这里用定义更硬）
            std::vector<double> ref(n, 0.0);
            for (int k = 0; k < irLen; ++k) ref[(size_t)k] = ir[(size_t)k];
            const double rel = rel_max_err(out, ref);
            printf("  冲激×FIR(n=%d, ir=%d, block=1024): 最大相对误差 = %.3e\n", n, irLen, rel);
            if (rel >= 1e-6) {
                fail("冲激测试：相对误差 >= 1e-6（分块/补零/overlap-add 索引可能错）");
            } else {
                printf("    [PASS] 冲激响应与 IR 一致\n");
            }
        }
    }

    // ---- 4b) 随机宽带 × 长 IR（跨多个 IR 分区，P > 1）----
    double conv_rel = 0.0;
    {
        const int n = 8192, irLen = 4096;
        std::vector<double> in(n), ir(irLen);
        for (auto& v : in) v = dist(rng);
        for (auto& v : ir) v = dist(rng);

        const std::vector<double> ref = cpu_convolve(in, ir);
        std::vector<double> out(n, 0.0);
        const int rc = conv(in.data(), (long long)n, ir.data(), (long long)irLen, out.data(), 1024);
        if (rc != 0) {
            fail("随机卷积：rta_gpu_convolve 返回非 0");
        } else if (all_zero(out)) {
            // 这条专门抓「kernel 静默不执行、buffer 保持初值」——HIP 铁律 5 的形态
            fail("随机卷积：GPU 输出全零（kernel 可能没有真的执行）");
        } else if (max_abs(ref) <= 1e-12) {
            fail("随机卷积：CPU 参考全零，输入退化，测不到东西");
        } else {
            conv_rel = rel_max_err(out, ref);
            printf("  随机×随机(n=%d, ir=%d, block=1024, P=%d 个 IR 分区): 最大相对误差 = %.3e\n",
                   n, irLen, (irLen + 1023) / 1024, conv_rel);
            printf("    参考峰值 |cpu|max = %.6f，GPU 峰值 |gpu|max = %.6f\n",
                   max_abs(ref), max_abs(out));
            if (conv_rel >= 1e-6) {
                fail("随机卷积：最大相对误差 >= 1e-6");
            } else {
                printf("    [PASS] 与 CPU 双精度直接卷积一致\n");
            }
        }
    }

    // ---- 4c) 非 2 的幂 / 极小规模边界（block 非法时应回落到 1024）----
    {
        const int n = 100, irLen = 7;
        std::vector<double> in(n), ir(irLen);
        for (auto& v : in) v = dist(rng);
        for (auto& v : ir) v = dist(rng);
        const std::vector<double> ref = cpu_convolve(in, ir);
        std::vector<double> out(n, 0.0);
        const int rc = conv(in.data(), (long long)n, ir.data(), (long long)irLen, out.data(), 0);
        if (rc != 0) {
            fail("小规模卷积：返回非 0");
        } else {
            const double rel = rel_max_err(out, ref);
            printf("  小规模(n=100, ir=7, block=0→1024): 最大相对误差 = %.3e\n", rel);
            if (rel >= 1e-6) fail("小规模卷积：最大相对误差 >= 1e-6");
            else             printf("    [PASS] 小规模与短 IR 一致\n");
        }
    }

    // =====================================================================
    // 5) 升频正确性
    // =====================================================================
    printf("\n-- 升频正确性 --\n");
    double res_rel = 0.0;

    // ---- 5a) 随机多相参数（L=16, T=8, ch=2）----
    {
        const int L = 16, T = 8, ch = 2;
        const long long histLen = 256;
        const long long nOut = 400;

        std::vector<double> hist((size_t)ch * (size_t)histLen);
        for (auto& v : hist) v = dist(rng);

        std::vector<double> phases((size_t)L * (size_t)T);
        for (auto& v : phases) v = dist(rng);

        std::vector<int> bases((size_t)nOut), phIdx((size_t)nOut);
        std::uniform_int_distribution<int> bd(0, (int)histLen - 1);
        std::uniform_int_distribution<int> pd(0, L - 1);
        for (long long n = 0; n < nOut; ++n) {
            bases[(size_t)n] = bd(rng);
            phIdx[(size_t)n] = pd(rng);
        }

        const std::vector<double> ref = cpu_resample(hist, ch, histLen, phases, L, T, bases, phIdx, nOut);
        std::vector<double> out((size_t)nOut * (size_t)ch, 0.0);
        const int rc = res(hist.data(), ch, histLen, phases.data(), L, T,
                           bases.data(), phIdx.data(), nOut, out.data());
        // ⚠️ 成功判据是 rc == nOut，不是 rc == 0
        if (rc != (int)nOut) {
            char msg[160];
            std::snprintf(msg, sizeof(msg),
                          "随机升频：rta_gpu_resample 返回 %d，应为 nOut=%lld（成功必须返回帧数）",
                          rc, nOut);
            fail(msg);
        } else if (all_zero(out) || max_abs(ref) <= 1e-12) {
            fail("随机升频：GPU 输出全零或 CPU 参考退化");
        } else {
            res_rel = rel_max_err(out, ref);
            printf("  随机(L=%d, T=%d, ch=%d, histLen=%lld, nOut=%lld): 最大相对误差 = %.3e\n",
                   L, T, ch, histLen, nOut, res_rel);
            printf("    参考峰值 |cpu|max = %.6f，GPU 峰值 |gpu|max = %.6f\n",
                   max_abs(ref), max_abs(out));
            if (res_rel >= 1e-6) fail("随机升频：最大相对误差 >= 1e-6");
            else                 printf("    [PASS] 与 CPU 双精度参考一致\n");
        }
    }

    // ---- 5b) 抽头位置测试（钉住 base-u 递减方向，而不是 base+u）----
    // ⚠️ 判据设计教训（铁律 3）：最初写的是「phases[p] = {1,0,0,...}，输出应等于
    //    hist[base]」—— 这条【测不出方向】！因为只有第 0 抽头非零，
    //    h[base-u] 和 h[base+u] 在 u=0 时是同一个元素，写成 base+u 也能过。
    //    改成让【第 u0 个抽头】为 1（u0 > 0），方向错误才会暴露：
    //      正确（base-u）：out = hist[base - u0]
    //      错误（base+u）：out = hist[base + u0]
    //    只要 hist 是单调序列，两者数值必然不同。
    {
        const int L = 4, T = 8, ch = 2;
        const int u0 = 3;                       // 关键：非零抽头位置必须 > 0
        const long long histLen = 64;
        const long long nOut = 64;

        std::vector<double> hist((size_t)ch * (size_t)histLen);
        for (size_t i = 0; i < hist.size(); ++i) hist[i] = (double)(i + 1) * 0.001;   // 严格单调

        std::vector<double> phases((size_t)L * (size_t)T, 0.0);
        for (int p = 0; p < L; ++p) phases[(size_t)p * (size_t)T + (size_t)u0] = 1.0;

        std::vector<int> bases((size_t)nOut), phIdx((size_t)nOut);
        for (long long n = 0; n < nOut; ++n) {
            // base 从 u0 起，保证 base-u0 不越界（越界时本实现按 uEnd 截断，属于另一条路径）
            bases[(size_t)n] = (int)(u0 + (n % (histLen - u0)));
            phIdx[(size_t)n] = (int)(n % L);
        }

        std::vector<double> out((size_t)nOut * (size_t)ch, 0.0);
        const int rc = res(hist.data(), ch, histLen, phases.data(), L, T,
                           bases.data(), phIdx.data(), nOut, out.data());
        if (rc != (int)nOut) {
            fail("抽头位置测试：返回帧数不符");
        } else {
            double errDesc = 0.0, errAsc = 0.0;
            for (long long n = 0; n < nOut; ++n)
                for (int c = 0; c < ch; ++c) {
                    const double* h = hist.data() + (size_t)c * (size_t)histLen;
                    const double got = out[(size_t)n * (size_t)ch + (size_t)c];
                    // 正确语义（base-u，见 resampler.h:288 与 gpu_resample_hip.cpp:48）
                    errDesc = std::fmax(errDesc, std::fabs(got - h[bases[(size_t)n] - u0]));
                    // 错误语义（base+u）—— 用来证明这条判据真的有分辨力
                    errAsc  = std::fmax(errAsc,  std::fabs(got - h[bases[(size_t)n] + u0]));
                }
            printf("  抽头位置(u0=%d): 与 hist[base-u] 的最大误差 = %.3e\n", u0, errDesc);
            printf("                    与 hist[base+u] 的最大误差 = %.3e（应显著更大，证明判据有分辨力）\n", errAsc);
            if (errDesc >= 1e-6) {
                fail("抽头位置测试：输出 != hist[base-u]（base-u 递减索引方向写错）");
            } else if (errAsc < 1e-3) {
                // 若两种语义误差都很小，说明测试构造退化（例如 hist 常数），判据无效
                fail("抽头位置测试：无法区分 base-u / base+u，判据本身退化");
            } else {
                printf("    [PASS] 索引方向正确（base-u），且判据能区分 base+u\n");
            }
        }
    }

    // =====================================================================
    // 6) invalidate 后必须重传相位表，且结果保持一致
    // =====================================================================
    printf("\n-- 缓存失效 --\n");
    {
        const int L = 8, T = 6, ch = 1;
        const long long histLen = 128;
        const long long nOut = 200;

        std::vector<double> hist((size_t)ch * (size_t)histLen);
        for (auto& v : hist) v = dist(rng);

        std::vector<int> bases((size_t)nOut), phIdx((size_t)nOut);
        std::uniform_int_distribution<int> bd(0, (int)histLen - 1);
        std::uniform_int_distribution<int> pd(0, L - 1);
        for (long long n = 0; n < nOut; ++n) {
            bases[(size_t)n] = bd(rng);
            phIdx[(size_t)n] = pd(rng);
        }

        // 相位表 A
        std::vector<double> phA((size_t)L * (size_t)T);
        for (auto& v : phA) v = dist(rng);
        std::vector<double> outA((size_t)nOut * (size_t)ch, 0.0);
        const int rcA = res(hist.data(), ch, histLen, phA.data(), L, T,
                            bases.data(), phIdx.data(), nOut, outA.data());
        if (rcA != (int)nOut) fail("缓存失效测试：第一遍返回帧数不符");

        // 失效 → 用同一份相位表再算一遍，必须与第一遍完全一致
        invalidate();
        std::vector<double> outB((size_t)nOut * (size_t)ch, 0.0);
        const int rcB = res(hist.data(), ch, histLen, phA.data(), L, T,
                            bases.data(), phIdx.data(), nOut, outB.data());
        if (rcB != (int)nOut) fail("缓存失效测试：invalidate 后返回帧数不符");

        double d = 0.0;
        for (size_t i = 0; i < outA.size(); ++i) d = std::fmax(d, std::fabs(outA[i] - outB[i]));
        printf("  invalidate 前后同一相位表: 最大差异 = %.3e（应严格为 0）\n", d);
        if (d != 0.0) fail("缓存失效测试：invalidate 后结果变化（缓存重传逻辑有问题）");
        else          printf("    [PASS] 结果一致\n");

        // 换一组相位表 B：不 invalidate 也必须得到 B 的正确结果吗？
        // —— 这里必须 invalidate，因为契约是「换滤波器后由上层调用 invalidate」。
        // 若 L/T 不变而相位表变了却不 invalidate，本实现会沿用旧缓存（符合契约，
        // 因为 HIP 版行为相同：cachedL/cachedT 不变就跳过重传）。
        // 因此正确测法是：invalidate → 传 B → 结果必须等于 B 的 CPU 参考。
        std::vector<double> phB((size_t)L * (size_t)T);
        for (auto& v : phB) v = dist(rng);
        invalidate();
        std::vector<double> outC((size_t)nOut * (size_t)ch, 0.0);
        const int rcC = res(hist.data(), ch, histLen, phB.data(), L, T,
                            bases.data(), phIdx.data(), nOut, outC.data());
        if (rcC != (int)nOut) {
            fail("缓存失效测试：换相位表后返回帧数不符");
        } else {
            const std::vector<double> refB =
                cpu_resample(hist, ch, histLen, phB, L, T, bases, phIdx, nOut);
            const double relB = rel_max_err(outC, refB);
            // 额外确认 B 与 A 的结果确实不同，否则这条测不出「真的换了表」
            double dAB = 0.0;
            for (size_t i = 0; i < outA.size(); ++i) dAB = std::fmax(dAB, std::fabs(outA[i] - outC[i]));
            printf("  invalidate 后换相位表 B: 最大相对误差 = %.3e，A/B 输出差异 = %.3e\n", relB, dAB);
            if (dAB <= 0.0)      fail("缓存失效测试：换表后结果与旧表相同，测不到重传");
            else if (relB >= 1e-6) fail("缓存失效测试：invalidate 后新相位表结果与 CPU 参考不符");
            else                 printf("    [PASS] invalidate 后新相位表已重传且正确\n");
        }
    }

    // =====================================================================
    printf("\n");
    if (g_fail) {
        printf("[FAIL] %d 项判据未通过\n", g_fail);
        dlclose(h);
        return 1;
    }
    printf("[PASS] 全部判据通过\n");
    printf("       卷积最大相对误差 = %.3e；升频最大相对误差 = %.3e\n", conv_rel, res_rel);
    dlclose(h);
    return 0;
}
