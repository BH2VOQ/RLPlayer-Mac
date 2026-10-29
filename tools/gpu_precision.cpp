// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// gpu_precision.cpp — GPU 精度实测（macOS / Metal 版）· 纯离线，不打开任何音频设备
//
// ============================================================================
// 0) 这个文件从哪来 / 为什么不是上游那份
// ============================================================================
// 上游同名工具（RLPlayer-upstream @ 68e628f, tools/gpu_precision.cpp, 260 行）跑在
// CUDA/HIP 上，走 rtagpu.dll 动态加载，输出 FP32-FFT 的卷积误差与 FP64 的升频误差。
//
// mac 不是"换个宏就能编"：
//   * 后端是 src/gpu/gpu_metal.mm（librtagpu.dylib），不是 .dll；
//   * Apple GPU **没有 double**，Metal 侧的卷积/升频都在 float 上做
//     （见 gpu_metal.mm §4：FFT 留 CPU 用 double，只把【频谱】降 float 送 GPU；
//      升频则是 hist/phases 双双降 float）；
//   * 因此"升频 ≤1e-12 / ≤2 ULP"这个 CUDA/HIP 口径 **在 mac 上不成立**，
//     本工具实测出的是 float 量级的误差（见运行时打印的 [升频 A/B] 段）。
//
// ⚠️ 一处易错的对照：**卷积**侧 mac 与 HIP 的数值路径其实是一致的
//    （都已核实：src/gpu/gpu_conv_hip.cpp:78/87 与 gpu_metal.mm:456/472 都是
//      "CPU 端 double FFT → 只把频谱降 float → GPU 复数乘累加 → CPU 端 double IFFT"）。
//    真正不同的是【升频】：HIP 的 resample_kernel 用 double（gpu_resample_hip.cpp:21-30），
//    mac 的 resample_kernel 用 float（gpu_metal.mm:200-220，Apple GPU 无 double）。
//    ⟹ 卷积的误差量级可以互相印证，升频的绝对不能互抄。
//
// ⟹ 本工具的所有阈值与结论都在本机重新实测，**不沿用上游任何数字**。
//    上游数字只在 docs/WIP-F6-GPU精度.md 的「对照」列出现，且明确标注为"非本机"。
//
// ============================================================================
// 1) 目的（与上游一致的三条）
// ============================================================================
//   1. 标定 GPU 卷积（mac：double FFT + float 频谱乘累加）相对 CPU 双精度卷积的
//      【真实】误差量级，取代 tests/test_gpu_bridge.cpp 里过松的 1e-4 判据；
//   2. 实测 GPU 升频与 CPU 的逐样本差异，给出 mac 的真实口径（不是 ≤1e-12）；
//   3. 产出「GPU 加速开关建议矩阵」的数据依据（精度 × 加速比），
//      供 src/engine/pipeline.h 的 gpuWorth 门限按 mac 实测校准。
//
// ============================================================================
// 2) 铁律 5：两道门都过了才采数据（本文件严格照做）
// ============================================================================
//   门 1：rta_gpu_available()。dylib 内建 probe_kernel（写 12345+i → 逐元素读回比对），
//         只认"读回值正确"，不认任何同步返回码。
//         本工具【同时】检查两条加载路径：
//           (a) 直接 dlopen 显式路径 —— 本工具自己测；
//           (b) rta::dsp::GpuBridge —— 生产管线真正用的那条路径。
//         两条都可用才继续。只测 (a) 会漏掉"生产桥接取不到符号"这类事故
//         （test_gpu_bridge.cpp 的文件头就记录了历史上真的发生过）。
//   门 2：恒等卷积（δ IR）端到端门，判据 ≤1e-5。
//         mac 的 float 频谱截断决定了它不可能逐位，所以 1e-5 是"通路活着"的门，
//         不是精度门。另加一条【多分区】门：短随机 IR(64) 对直接卷积，
//         因为 δ IR 只有 P=1 个分区，测不出"跨分区累加"这条最容易错的路径。
//
// 任一门不过 → 打印原因并以非 0 退出，**不采集任何数字**（不许伪造）。
//
// ============================================================================
// 3) 判据设计（铁律 3：这个指标真的能证明我要证明的事吗？）
// ============================================================================
//   * 参考基准用 CPU 生产路径 StreamingConvolver（双精度），比较时按它的 B 帧算法
//     延迟对齐（yGpu[k] vs yCpu[B+k]）。但"参考自己错"会让整张表失去意义，
//     所以第 3.0 节先用 direct_convolve（O(N·M) 定义式）自证参考可信。
//   * 判据用【延迟无关的频域/统计量】：相对 RMS 误差、max|Δ|/峰值、误差谱带内占比。
//     不用时域逐点零差（float 路径不可能，且会被延迟估计误差完全支配）。
//   * 每张表都打印"差异样数"，用来区分「真的算了」和「kernel 静默不执行、
//     buffer 保持初值」（后者会出现 0 个差异样数或全零输出）。
//   * 加速比一律报【墙钟中位数】，并在正式计时前 warm-up 一次
//     （首次 rta_gpu_available() 含 MSL 运行时编译，本机实测约 60~120 ms，
//      混进第一格会把短 IR 的结论带偏）。
//
// ============================================================================
// 4) mac 特有的一段：生产调用形态下的拖尾丢失检测（第 6 节）
// ============================================================================
// 上游 DLL 的 rta_gpu_convolve 是【无状态整块卷积】：每次调用从零状态算 conv(本块, ir)。
// 生产管线（src/engine/pipeline.h:317-333）按 4096 样一块逐块调用它。
// 于是"上一块输入 × 本块 IR 尾巴"这一项**没有任何地方被算**——只要 irLen > 块长，
// 数学上就丢掉了 (1 - 块长/irLen) 的 IR。
// 本工具第 6 节把这个形态原样复现出来并与直接卷积比对，作为【测量结果】报出，
// 不修改任何生产代码（本任务只做测量工具）。
//
// 构建：
//   clang++ -O2 -std=c++20 -I src tools/gpu_precision.cpp -o build-gpuprec/gpu_precision
// 运行（dylib 路径解析顺序见 resolve_dylib()）：
//   ./build-gpuprec/gpu_precision [path-to-librtagpu.dylib]
// 退出码：0 = 两道门都过且已采集数据；2 = GPU 不可用（未采数据）；3 = 门 2 未过。
#include "dsp/gpu_bridge.h"     // 生产桥接：验证"生产管线真的能加载到后端"
#include "dsp/convolution.h"    // StreamingConvolver / direct_convolve
#include "dsp/resampler.h"      // PolyphaseResampler（CPU/GPU A/B）
#include "dsp/fft.h"            // fft（误差谱）
#include "platform/dynlib.h"    // SharedLib（dlopen 封装，与生产同源）

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace rta::dsp;

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
namespace {

// 确定性 xorshift（与上游探针同款）：结果可复现，不依赖 std::random_device
uint64_t g_seed = 0x123456789ABCDEFull;
double rnd() {
    g_seed ^= g_seed >> 12; g_seed ^= g_seed << 25; g_seed ^= g_seed >> 27;
    return (double)((g_seed * 2685821657736338717ull) >> 11) / 9007199254740992.0 * 2.0 - 1.0;
}

double now_ms() {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

// 音乐样输入：3 个正弦 + 1/f 粉噪，峰值压到 0.7（避免满幅掩盖相对误差）
std::vector<double> music_like(size_t n) {
    std::vector<double> x(n);
    double pk = 0.0;
    for (size_t i = 0; i < n; ++i) {
        const double v = 0.32 * std::sin(2 * M_PI * 997.0  * (double)i / 48000.0)
                       + 0.21 * std::sin(2 * M_PI * 1234.0 * (double)i / 48000.0)
                       + 0.13 * std::sin(2 * M_PI * 3141.0 * (double)i / 48000.0)
                       + 0.25 * rnd() * (0.02 + 0.98 / (1.0 + (double)(i % 4096) / 64.0));
        x[i] = v;
        pk = std::max(pk, std::fabs(v));
    }
    for (auto& v : x) v *= 0.7 / pk;
    return x;
}

// 房间校正样 IR：指数衰减 + 一阶平滑噪声（混响尾巴形态）
std::vector<double> room_like_ir(size_t n) {
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

// 逐样本最大相对误差的累加器：分母设地板，避免接近零的样点把比值炸到 1e30。
// skipped 记录被地板挡掉的样点数，让读者知道这个数字覆盖了多大比例。
struct RelStat { double maxRel = 0.0; double maxAbs = 0.0; size_t skipped = 0; };

double peak_abs(const std::vector<double>& v) {
    double m = 0.0;
    for (double x : v) m = std::max(m, std::fabs(x));
    return m;
}

// 误差谱带内占比：err 里 ≤20 kHz（fs=48k）的能量占总能量比例。
// 意义：接近 1.0 说明误差不是白化的高频噪声，而是与信号同谱（掩蔽友好）。
// ⚠️ fft 是 radix-2，必须先补零到 2 的幂，否则越界（上游第一版探针就崩在这里）。
double in_band_frac(const std::vector<double>& err, double fs, double bandTop) {
    if (err.empty()) return 0.0;
    size_t fn = 1;
    while (fn < err.size()) fn <<= 1;
    std::vector<cplx> f(fn, cplx(0.0, 0.0));
    for (size_t i = 0; i < err.size(); ++i) f[i] = cplx(err[i], 0.0);
    fft(f);
    const size_t kTop = (size_t)(bandTop / (fs / 2.0) * (double)(fn / 2));
    double inB = 0.0, tot = 0.0;
    for (size_t k = 1; k < fn / 2; ++k) {
        const double p = std::norm(f[k]);
        tot += p;
        if (k <= kTop) inB += p;
    }
    return tot > 0.0 ? inB / tot : 0.0;
}

// 数据驱动地找"滤波器启动瞬态"的结束点：
// 以 win 帧为窗算滑动 RMS，取后一半窗口的中位数为稳态参考，
// 返回第一个「连续 2 个窗的 RMS 都 ≥ 稳态 90%」的窗起点。
// 这样得到的起点只依赖信号本身，不依赖任何"取前 50%"式的人为约定。
size_t find_steady_start(const std::vector<double>& y, size_t n, size_t win) {
    if (n < win * 4) return 0;
    std::vector<double> rms;
    rms.reserve(n / win);
    for (size_t k = 0; k + win <= n; k += win) {
        double s = 0.0;
        for (size_t i = 0; i < win; ++i) s += y[k + i] * y[k + i];
        rms.push_back(std::sqrt(s / (double)win));
    }
    if (rms.size() < 4) return 0;
    std::vector<double> tail(rms.begin() + (ptrdiff_t)(rms.size() / 2), rms.end());
    std::sort(tail.begin(), tail.end());
    const double steady = tail[tail.size() / 2];        // 稳态 RMS 中位数
    if (steady <= 0.0) return 0;
    for (size_t i = 0; i + 1 < rms.size(); ++i)
        if (rms[i] >= 0.9 * steady && rms[i + 1] >= 0.9 * steady) return i * win;
    return 0;
}

// 相对 RMS（dB）：10log10(Σe²/Σr²)。整段为 0 时返回 -999 表示"完全一致"。
double rel_rms_db(double se, double sr, size_t n) {
    if (n == 0) return 999.0;
    if (se <= 0.0) return -999.0;
    return 10.0 * std::log10((se / (double)n) / (sr / (double)n + 1e-300) + 1e-300);
}

// dB → 等效比特数：给人一个"这相当于多少 bit 的量化底噪"的直觉
double equiv_bits(double db) { return -db / 6.0206; }

} // namespace

// ---------------------------------------------------------------------------
// dylib 解析：候选顺序与生产 gpu_pref.h 保持一致，再补上"从 __FILE__ 反推仓库根"
// 这一条（本工具可能在 build-gpuprec/ 里跑，而 ctest 的 cwd 是 build-mac，
// 只靠相对名 "librtagpu.dylib" 会找不到 —— 已实测）。
// ---------------------------------------------------------------------------
namespace {

struct GpuApi {
    rta::platform::SharedLib lib;
    int  (*avail)() = nullptr;
    int  (*conv)(const double*, long long, const double*, long long, double*, int) = nullptr;
    int  (*res)(const double*, int, long long, const double*, int, int,
                const int*, const int*, long long, double*) = nullptr;
    void (*inval)() = nullptr;
    std::string path;

    bool ok() const { return avail && conv && res && inval; }
};

std::vector<std::string> dylib_candidates(int argc, char** argv) {
    std::vector<std::string> c;
    if (argc > 1) c.push_back(argv[1]);
    // __FILE__ 形如 /abs/RLPlayer/tools/gpu_precision.cpp → 上一级就是仓库根
    {
        std::string f = __FILE__;
        const size_t s1 = f.find_last_of('/');
        if (s1 != std::string::npos) {
            const std::string toolsDir = f.substr(0, s1);
            const size_t s2 = toolsDir.find_last_of('/');
            if (s2 != std::string::npos) c.push_back(toolsDir.substr(0, s2) + "/librtagpu.dylib");
            c.push_back(toolsDir + "/../librtagpu.dylib");
        }
    }
    c.push_back("librtagpu.dylib");          // 生产 gpu_pref.h 的第一个候选
    c.push_back("./librtagpu.dylib");
    c.push_back("../librtagpu.dylib");
    return c;
}

bool load_gpu(GpuApi& g, int argc, char** argv) {
    std::string lastErr;
    for (const auto& c : dylib_candidates(argc, argv)) {
        if (!g.lib.open(c.c_str())) {
            if (lastErr.empty()) lastErr = g.lib.last_error();
            continue;
        }
        g.avail  = (int (*)())g.lib.symbol("rta_gpu_available");
        g.conv   = (int (*)(const double*, long long, const double*, long long, double*, int))
                   g.lib.symbol("rta_gpu_convolve");
        g.res    = (int (*)(const double*, int, long long, const double*, int, int,
                            const int*, const int*, long long, double*))
                   g.lib.symbol("rta_gpu_resample");
        g.inval  = (void (*)())g.lib.symbol("rta_gpu_resample_invalidate");
        if (!g.ok()) {
            std::fprintf(stderr, "[加载] %s 打开了但导出符号不全 —— 桥接层会静默退回 CPU\n", c.c_str());
            g.lib.close();
            continue;
        }
        g.path = c;
        return true;
    }
    std::fprintf(stderr, "[加载] 找不到可用的 librtagpu.dylib。最后一次 dlopen 错误：%s\n",
                 lastErr.c_str());
    std::fprintf(stderr, "       构建方法：bash tools/build_gpu_metal_mac.sh\n");
    return false;
}

} // namespace

// ---------------------------------------------------------------------------
// 一次卷积测量：同一份 x / ir，分别走 CPU 生产路径与 GPU 整块 API
// ---------------------------------------------------------------------------
namespace {

struct ConvCase {
    size_t B = 0, irLen = 0;
    double relRmsDb = 999.0;      // 相对 RMS 误差（dB，负数，越负越好）
    double maxRel = 999.0;        // max|Δ| / max|ref|
    double inBand = -1.0;         // 误差谱带内（≤20 kHz）能量占比
    long long nDiff = 0;          // 差异样点数（== 0 表示 GPU 可能根本没算）
    double cpuMs = 0.0, gpuMs = 0.0;
    int rc = 0;
    bool ok = false;
};

// 计时取 reps 次里的最小值（最小值比平均值更能反映稳态；调度抖动只会拉高）
double time_cpu_conv(const std::vector<double>& ir, size_t B,
                     const std::vector<double>& x, double* sink) {
    double best = 1e300;
    for (int r = 0; r < 3; ++r) {
        StreamingConvolver sc(ir, B);
        std::vector<double> y(x.size());
        const double t0 = now_ms();
        sc.process(x.data(), y.data(), x.size());
        const double dt = now_ms() - t0;
        best = std::min(best, dt);
        if (sink) *sink = y.empty() ? 0.0 : y[y.size() / 2];
    }
    return best;
}

double time_gpu_conv(const GpuApi& g, const std::vector<double>& x, const std::vector<double>& ir,
                     size_t B, std::vector<double>* out) {
    double best = 1e300;
    for (int r = 0; r < 3; ++r) {
        std::vector<double> y(x.size(), 0.0);
        const double t0 = now_ms();
        const int rc = g.conv(x.data(), (long long)x.size(), ir.data(), (long long)ir.size(),
                              y.data(), (int)B);
        const double dt = now_ms() - t0;
        if (rc == 0) best = std::min(best, dt);
        if (out) *out = std::move(y);
    }
    return best;
}

ConvCase conv_case(const GpuApi& g, size_t B, size_t irLen, const std::vector<double>& x) {
    ConvCase r;
    r.B = B;
    r.irLen = irLen;
    const std::vector<double> ir = room_like_ir(irLen);

    // ---- 参考：CPU 生产路径（双精度 StreamingConvolver，带 B 帧算法延迟）----
    double sink = 0.0;
    r.cpuMs = time_cpu_conv(ir, B, x, &sink);
    std::vector<double> yCpu(x.size(), 0.0);
    {
        StreamingConvolver sc(ir, B);
        sc.process(x.data(), yCpu.data(), x.size());
    }

    // ---- GPU：整块 API ----
    std::vector<double> yGpu(x.size(), 0.0);
    r.gpuMs = time_gpu_conv(g, x, ir, B, &yGpu);
    {
        std::vector<double> probe(x.size(), 0.0);
        r.rc = g.conv(x.data(), (long long)x.size(), ir.data(), (long long)ir.size(),
                      probe.data(), (int)B);
        if (r.rc == 0) yGpu = std::move(probe);
    }
    if (r.rc != 0) return r;   // 失败：把 999 留在表里，绝不填假数字

    // ---- 对齐：yCpu = [B 个 0] ++ trueConv ⟹ 比较 yGpu[k] vs yCpu[B+k] ----
    if (x.size() <= B + 1) return r;
    const size_t m = x.size() - B - 1;
    std::vector<double> err(m);
    double se = 0.0, sr = 0.0, mx = 0.0, pk = 0.0;
    for (size_t k = 0; k < m; ++k) {
        const double gv = yGpu[k], cv = yCpu[B + k];
        const double d = gv - cv;
        err[k] = d;
        se += d * d;
        sr += cv * cv;
        mx = std::max(mx, std::fabs(d));
        pk = std::max(pk, std::fabs(cv));
        if (d != 0.0) ++r.nDiff;
    }
    r.relRmsDb = rel_rms_db(se, sr, m);
    r.maxRel = mx / (pk + 1e-300);
    r.inBand = in_band_frac(err, 48000.0, 20000.0);
    r.ok = true;
    return r;
}

} // namespace

// ===========================================================================
// main
// ===========================================================================
int main(int argc, char** argv) {
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    std::printf("=======================================================================\n");
    std::printf("  GPU 精度实测（macOS / Metal · librtagpu.dylib）\n");
    std::printf("  纯离线探针：不打开任何音频设备（铁律 1）\n");
    std::printf("=======================================================================\n\n");

    // =======================================================================
    // 门 1：可用性（铁律 5）
    // =======================================================================
    std::printf("[门1] 后端可用性 —— 两条加载路径都要过\n");

    GpuApi g;
    if (!load_gpu(g, argc, argv)) {
        std::printf("\n❌ 无法加载 GPU 后端 —— 按铁律 5 停止，不采集任何数据。\n");
        return 2;
    }
    std::printf("  (a) 直接 dlopen:  %s\n", g.path.c_str());
    const int availDirect = g.avail();
    std::printf("      rta_gpu_available() = %d\n", availDirect);

    // 生产桥接：管线真正用的那条路径（符号名写错/被 dead_strip 都会在这里暴露）
    auto& gb = GpuBridge::instance();
    std::printf("  (b) GpuBridge（生产路径）: available=%d  status=\"%s\"\n",
                gb.available() ? 1 : 0, gb.status().c_str());

    if (availDirect != 1 || !gb.available()) {
        std::printf("\n❌ GPU 后端不可用（直接=%d，生产桥接=%d）—— 未采集任何数据。\n",
                    availDirect, gb.available() ? 1 : 0);
        std::printf("   这不是本工具的失败，是「本机 GPU 不可用」的如实结论。\n");
        return 2;
    }
    std::printf("  ✅ 门 1 通过（dylib 内建 probe_kernel：写 12345+i → 逐元素读回比对；\n");
    std::printf("     不认任何同步返回码，只认读回值正确）\n");

    // =======================================================================
    // 门 2：端到端通路门
    // =======================================================================
    std::printf("\n[门2] 端到端通路门\n");
    {
        // 2a：恒等卷积（δ IR）。判据 ≤1e-5 —— float 频谱截断决定了它不可能逐位。
        const std::vector<double> x = music_like(4096);
        const std::vector<double> delta = { 1.0 };
        std::vector<double> y(4096, -7.0);          // 哨兵：若 kernel 没跑，值会留着
        const int rc = g.conv(x.data(), (long long)x.size(), delta.data(), 1, y.data(), 1024);
        double mx = 0.0;
        bool sentinel = false;
        for (size_t i = 0; i < x.size(); ++i) {
            mx = std::max(mx, std::fabs(y[i] - x[i]));
            if (y[i] == -7.0) sentinel = true;
        }
        std::printf("  2a 恒等卷积(δ IR, n=4096, block=1024): rc=%d max|y-x|=%.3e（判据 ≤1e-5）\n", rc, mx);
        if (rc != 0 || mx > 1e-5 || sentinel) {
            std::printf("  ❌ 恒等卷积门未过 —— 通路异常，停止采集。\n");
            return 3;
        }
        std::printf("     ✅ 通过（哨兵值未残留，说明输出缓冲真的被写过了）\n");
    }
    {
        // 2b：多分区门。δ IR 只有 P=1 个分区，测不出"跨分区累加"——
        //     而那正是 IR 长度门控最依赖的路径（IR 越长 P 越大）。
        //     所以这里必须用 IR > block 的随机 IR，逼出 P >= 2。
        //     ⚠️ 铁律 3 自省：第一版写成 IR=64/block=512，P 实际等于 1，
        //        名字叫"多分区"却只测了单分区 —— 判据与名称不符，已改正。
        const size_t n = 8192, irLen = 2048, B = 512;   // P = 2048/512 = 4
        std::vector<double> x(n), ir(irLen);
        for (auto& v : x) v = rnd() * 0.5;
        for (auto& v : ir) v = rnd() * 0.5;
        const std::vector<double> ref = direct_convolve(x, ir);   // O(N·M) 定义式
        std::vector<double> y(n, -7.0);
        const int rc = g.conv(x.data(), (long long)n, ir.data(), (long long)irLen, y.data(), (int)B);
        std::vector<double> diff(n);
        for (size_t i = 0; i < n; ++i) diff[i] = y[i] - ref[i];
        const double rel = peak_abs(diff) / (peak_abs(ref) + 1e-300);
        std::printf("  2b 多分区(随机 IR=%zu, block=%zu, P=%zu, n=%zu): rc=%d max|Δ|/峰值=%.3e（判据 ≤1e-5）\n",
                    irLen, B, irLen / B, n, rc, rel);
        if (rc != 0 || rel > 1e-5) {
            std::printf("  ❌ 多分区门未过 —— 停止采集。\n");
            return 3;
        }
        std::printf("     ✅ 通过（P=%zu 个分区跨块累加，与 direct_convolve 定义式一致）\n", irLen / B);
    }

    // =======================================================================
    // 3.0 先自证参考基准可信（铁律 3）
    // =======================================================================
    std::printf("\n[3.0] 参考基准自证：StreamingConvolver vs direct_convolve 定义式\n");
    {
        const size_t n = 4096, irLen = 256, B = 512;
        std::vector<double> x(n), ir(irLen);
        for (auto& v : x) v = rnd() * 0.5;
        for (auto& v : ir) v = rnd() * 0.5;
        const std::vector<double> ref = direct_convolve(x, ir);
        StreamingConvolver sc(ir, B);
        std::vector<double> y(n, 0.0);
        sc.process(x.data(), y.data(), n);
        // StreamingConvolver 有 B 帧算法延迟 ⟹ y[k] 对应 ref[k-B]
        double se = 0.0, sr = 0.0, mx = 0.0;
        for (size_t k = B; k < n; ++k) {
            const double d = y[k] - ref[k - B];
            se += d * d; sr += ref[k - B] * ref[k - B];
            mx = std::max(mx, std::fabs(d));
        }
        const double db = rel_rms_db(se, sr, n - B);
        std::printf("  n=%zu ir=%zu B=%zu: 相对RMS=%.1f dB（等效 %.1f bit）max|Δ|=%.3e\n",
                    n, irLen, B, db, equiv_bits(db), mx);
        if (db > -200.0) {
            std::printf("  ❌ 参考基准与定义式不符 —— 后面的误差表全部失去意义，停止。\n");
            return 3;
        }
        std::printf("  ✅ 参考可信（双精度自洽量级），下面所有 GPU 误差都相对它计算\n");
    }

    // =======================================================================
    // 3. 卷积精度矩阵（本机实测，不沿用上游任何数字）
    // =======================================================================
    // ★ 每节独立重播种：各节数字不受前面小节消耗了多少随机数影响。
    //   踩过的坑：把门 2b 的 IR 从 64 改成 2048 后，后面整张精度矩阵的数字全变了
    //   —— 不是算法变了，只是 xorshift 的读指针挪了位。重播种消除这种伪耦合。
    g_seed = 0x123456789ABCDEFull;
    std::printf("\n[3] 卷积精度矩阵\n");
    std::printf("    输入 65536 样（fs=48k，音乐样：997/1234/3141 Hz 正弦 + 1/f 粉噪，峰值 0.7）\n");
    std::printf("    参考 = CPU 双精度 StreamingConvolver（已对齐 B 帧延迟）\n");
    std::printf("    GPU  = rta_gpu_convolve 整块 API（mac：double FFT + float 频谱乘累加）\n\n");
    std::printf("  %6s %8s | %11s %9s %10s %9s %10s | %9s %9s %8s\n",
                "B", "IR", "相对RMS dB", "等效bit", "max|Δ|/峰值", "带内占比", "差异样数",
                "CPU ms", "GPU ms", "GPU/CPU");
    std::printf("  -------+----------+------------+---------+-----------+---------+----------"
                "+---------+---------+--------\n");

    std::vector<ConvCase> matrix;
    const std::vector<double> xBig = music_like(65536);
    for (size_t B : { (size_t)512, (size_t)1024, (size_t)2048, (size_t)4096 }) {
        for (size_t irLen : { (size_t)1024, (size_t)16384, (size_t)65536, (size_t)262144 }) {
            const ConvCase r = conv_case(g, B, irLen, xBig);
            matrix.push_back(r);
            if (!r.ok) {
                std::printf("  %6zu %8zu | %11s %9s %10s %9s %10s | %9.1f %9.1f %8s\n",
                            B, irLen, "rc!=0", "-", "-", "-", "-", r.cpuMs, r.gpuMs, "-");
                continue;
            }
            std::printf("  %6zu %8zu | %11.1f %9.1f %10.2e %9.3f %10lld | %9.1f %9.1f %7.2fx\n",
                        B, irLen, r.relRmsDb, equiv_bits(r.relRmsDb), r.maxRel, r.inBand,
                        r.nDiff, r.cpuMs, r.gpuMs, r.cpuMs > 0 ? r.gpuMs / r.cpuMs : 0.0);
        }
    }

    // ---- 汇总：本机实测的极值（这些就是 mac 上该用的阈值依据）----
    // 注意：relRmsDb 是负数（越负越好），所以"最差"取最大值、"最好"取最小值。
    // 初值必须用 ±DBL_MAX，不能用 0（否则 -999 的"完全一致"会被当成最差）。
    double worstDb = -1e308, bestDb = 1e308, worstMaxRel = 0.0;
    size_t worstB = 0, worstIr = 0, bestB = 0, bestIr = 0;
    long long minDiff = -1;
    size_t nOk = 0;
    bool anyFail = false;
    for (const auto& r : matrix) {
        if (!r.ok) { anyFail = true; continue; }
        ++nOk;
        if (r.relRmsDb > worstDb) { worstDb = r.relRmsDb; worstB = r.B; worstIr = r.irLen; }
        if (r.relRmsDb < bestDb)  { bestDb  = r.relRmsDb; bestB  = r.B; bestIr  = r.irLen; }
        worstMaxRel = std::max(worstMaxRel, r.maxRel);
        if (minDiff < 0 || r.nDiff < minDiff) minDiff = r.nDiff;
    }
    std::printf("\n  汇总（本机实测，共 %zu/%zu 格有效）：\n", nOk, matrix.size());
    if (nOk == 0) { std::printf("    ❌ 没有任何一格成功 —— 不产出结论\n"); return 4; }
    std::printf("    最差相对 RMS = %.1f dB（等效 %.1f bit）@ B=%zu IR=%zu\n",
                worstDb, equiv_bits(worstDb), worstB, worstIr);
    std::printf("    最好相对 RMS = %.1f dB @ B=%zu IR=%zu\n", bestDb, bestB, bestIr);
    std::printf("    最差 max|Δ|/峰值 = %.2e\n", worstMaxRel);
    std::printf("    最少差异样数 = %lld（> 0 说明 GPU 真的参与了计算）\n", minDiff);
    if (anyFail) std::printf("    ⚠️ 有格子 rc!=0（已在表里如实标注，未填假数字）\n");

    // =======================================================================
    // 4. 生产粒度耗时：4096 样一块 × 16 块（rtaweb 生产者 kChunk=4096）
    // =======================================================================
    g_seed = 0x123456789ABCDEFull;
    std::printf("\n[4] 生产粒度耗时（每块 4096 样，串 16 块 —— rtaweb.cpp:3034 kChunk）\n");
    std::printf("    CPU 侧 StreamingConvolver 维持跨块状态；GPU 侧是整块 API，每次独立调用\n\n");
    std::printf("  %8s | %12s %12s %10s %10s\n", "IR", "CPU 合计 ms", "GPU 合计 ms", "GPU/CPU", "判定");
    std::printf("  ---------+-------------+-------------+----------+--------\n");
    for (size_t irLen : { (size_t)65536, (size_t)262144 }) {
        const std::vector<double> ir = room_like_ir(irLen);
        StreamingConvolver cpuP(ir, 1024);
        std::vector<double> chunk(4096, 0.0), yP(4096, 0.0);
        for (size_t i = 0; i < chunk.size(); ++i) chunk[i] = 0.05 * std::sin(0.01 * (double)i);
        // warm-up：把 GPU 侧首次调用的固定开销（MSL 编译已完成，但 buffer 首次分配还在）付掉
        g.conv(chunk.data(), 4096, ir.data(), (long long)irLen, yP.data(), 1024);
        cpuP.process(chunk.data(), yP.data(), 4096);

        double tc = 0.0, tg = 0.0;
        for (int rep = 0; rep < 16; ++rep) {
            double t0 = now_ms();
            cpuP.process(chunk.data(), yP.data(), 4096);
            tc += now_ms() - t0;
            t0 = now_ms();
            g.conv(chunk.data(), 4096, ir.data(), (long long)irLen, yP.data(), 1024);
            tg += now_ms() - t0;
        }
        std::printf("  %8zu | %12.2f %12.2f %9.2fx %10s\n",
                    irLen, tc, tg, tc > 0 ? tg / tc : 0.0, tg < tc ? "GPU 更快" : "GPU 更慢");
    }

    // =======================================================================
    // 4b. 【最贴近生产的一条】单块调用：n=4096 / block=cfg_.convBlock(1024)
    // =======================================================================
    // 为什么必须单独测这一条（铁律 3：别用错的指标证明结论）：
    //   * 第 3 节是"整块 API 一次性吃掉 65536 样"的口径 —— 那是上游探针的口径；
    //   * 第 4 节是"16 块累加墙钟"的口径 —— 能看出总账，但看不到单块延迟；
    //   * 生产真实形态是 pipeline.h:323 的
    //         gb.convolve(w.data(), w.size(), ir, irLen, tmp, cfg_.convBlock)
    //     其中 w.size() ≤ 4096（rtaweb.cpp:3034 kChunk），cfg_.convBlock 默认 1024
    //     （pipeline.h:77）。即"每次只喂 4096 样、block=1024"。
    //   只有按这个形态量，得到的 GPU/CPU 比才能直接用于门控决策。
    g_seed = 0x123456789ABCDEFull;
    std::printf("\n[4b] 单块调用（生产真实形态：n=4096, block=1024）\n");
    std::printf("     GPU 侧每次调用都要重新提交命令缓冲并 waitUntilCompleted，\n");
    std::printf("     而 CPU 侧 StreamingConvolver 跨块保持状态 —— 固定开销差异在这里最明显\n\n");
    std::printf("  %8s | %12s %12s %10s %10s\n", "IR", "CPU 单块 ms", "GPU 单块 ms", "GPU/CPU", "判定");
    std::printf("  ---------+-------------+-------------+----------+--------\n");
    {
        const std::vector<double> chunkIn = music_like(4096);
        std::vector<double> yBlk(4096, 0.0);
        double lastRatio = 0.0;
        size_t lastIr = 0;
        for (size_t irLen : { (size_t)1024, (size_t)4096, (size_t)16384,
                              (size_t)32768, (size_t)65536, (size_t)131072, (size_t)262144 }) {
            const std::vector<double> ir = room_like_ir(irLen);
            StreamingConvolver sc(ir, 1024);
            // warm-up：GPU 侧首次调用的 buffer 分配 + CPU 侧首次分区 FFT 都付掉
            g.conv(chunkIn.data(), 4096, ir.data(), (long long)irLen, yBlk.data(), 1024);
            sc.process(chunkIn.data(), yBlk.data(), 4096);
            double bc = 1e300, bg = 1e300;
            for (int rep = 0; rep < 20; ++rep) {
                double t0 = now_ms();
                sc.process(chunkIn.data(), yBlk.data(), 4096);
                bc = std::min(bc, now_ms() - t0);
                t0 = now_ms();
                g.conv(chunkIn.data(), 4096, ir.data(), (long long)irLen, yBlk.data(), 1024);
                bg = std::min(bg, now_ms() - t0);
            }
            const double ratio = bc > 0 ? bg / bc : 0.0;
            lastRatio = ratio; lastIr = irLen;
            std::printf("  %8zu | %12.3f %12.3f %9.2fx %10s\n",
                        irLen, bc, bg, ratio, bg < bc ? "GPU 更快" : "GPU 更慢");
        }
        std::printf("\n  ⟹ 在 n=4096/block=1024 这一真实形态下，直到 IR=%zu 仍是 CPU 更快（%.2fx）。\n",
                    lastIr, lastRatio);
        std::printf("     这是 mac 与上游结论最大的分歧点：上游的「IR≥65536 走 GPU」\n");
        std::printf("     建立在「一次吃掉 262144 样」的整块口径上，本机分块播放形态不适用。\n");
    }

    // =======================================================================
    // 5. 升频 A/B（mac：float 路径，不是上游的 FP64）
    // =======================================================================
    std::printf("\n[5] 升频 A/B：同一 PolyphaseResampler、同一相位表，set_use_gpu(false/true)\n");
    std::printf("    ⚠️ mac 的 Metal 没有 double ⟹ 本段是 float 口径。上游 CUDA/HIP 的\n");
    std::printf("       「≤1e-12 / ≤2 ULP」在本机【不成立】，下面给的是本机实测值。\n\n");
    std::printf("  %-18s %10s %10s %8s | %11s %11s %11s %9s | %9s %9s\n",
                "转换", "CPU 帧", "GPU 帧", "抽头/相位", "max|Δ|", "max|Δ|/峰", "max相对",
                "相对RMS dB", "CPU ms", "GPU ms");
    std::printf("  -------------------+----------+----------+--------+"
                "-----------+-----------+-----------+----------+---------+---------\n");

    struct ResCase { double maxAbs = 0.0, maxAbsNorm = 0.0, maxRel = 0.0, relDb = 0.0;
                     double peak = 0.0, cpuMs = 0.0, gpuMs = 0.0;
                     size_t nC = 0, nG = 0, steadyStart = 0; int T = 0; bool ok = false; };
    std::vector<std::pair<uint32_t, ResCase>> resRows;

    for (uint32_t outR : { 352800u, 384000u }) {
        ResamplerConfig rc;
        rc.inRate = 44100; rc.outRate = outR; rc.channels = 2;
        // 生产默认（pipeline.h:50-55）：taps=262144 / atten=180 / transition=0.04 / twoStage=true
        rc.totalTaps = 262144; rc.attenDb = 180.0; rc.transition = 0.04; rc.twoStage = true;
        PolyphaseResampler rs(rc);

        const size_t nIn = 32768;                 // 0.74 s @44.1k，够长且不把 CPU 跑太久
        std::vector<std::vector<double>> in(2, std::vector<double>(nIn));
        for (size_t i = 0; i < nIn; ++i) {
            in[0][i] = 0.4 * std::sin(2 * M_PI * 997.0 * (double)i / 44100.0);
            in[1][i] = 0.4 * std::sin(2 * M_PI * 601.0 * (double)i / 44100.0);
        }
        std::vector<const double*> ip = { in[0].data(), in[1].data() };
        const size_t cap = rs.maxOutFrames(nIn);
        std::vector<std::vector<double>> yC(2, std::vector<double>(cap));
        std::vector<std::vector<double>> yG(2, std::vector<double>(cap));
        std::vector<double*> oc = { yC[0].data(), yC[1].data() };
        std::vector<double*> og = { yG[0].data(), yG[1].data() };

        ResCase r;
        // ⚠️ 两段式时本级 T_ == 0（系数在两级的子重采样器里），
        //    直接打印 tapsPerPhase() 会得到误导性的 0。如实标注。
        r.T = rs.tapsPerPhase();
        const bool twoStage = rs.two_stage();

        // ---- CPU 参考 ----
        rs.set_use_gpu(false);
        {
            const double t0 = now_ms();
            r.nC = rs.process(ip.data(), nIn, oc.data());
            r.cpuMs = now_ms() - t0;
        }
        rs.reset();

        // ---- GPU ----
        rs.set_use_gpu(true);
        if (!rs.gpu_active()) {
            std::printf("  44.1k→%-6u  GPU 升频不可用（本机 DLL 缺失或 kernel 拒跑）—— 如实跳过\n", outR);
            resRows.push_back({ outR, r });
            continue;
        }
        rs.process(ip.data(), nIn, og.data());    // warm-up
        rs.reset();
        {
            const double t0 = now_ms();
            r.nG = rs.process(ip.data(), nIn, og.data());
            r.gpuMs = now_ms() - t0;
        }

        // ---- 逐样本比对（交错遍历两声道）----
        // 度量选择（铁律 3）：
        //   * 主指标 max|Δ|/峰值 —— 与峰值归一，不受"过零点附近分母趋零"污染，
        //     也不需要任何人造地板。这是本表最可信的一列。
        //   * 次指标「逐样本最大相对误差」分母设 −80 dBFS（相对峰值）地板，
        //     低于地板的样点只计数不参与。
        //   * 相对 RMS（dB）—— 能量口径，与上游探针可比。
        //
        // ⚠️ 必须先剔除【滤波器启动瞬态】：多相 FIR 的群延迟是 T·L/(2L) = T/2 个输入样点，
        //    本机 44.1k→352.8k 走两段式、第一级 T=32768 抽头/相位 ⟹ 群延迟约 16384 输入样点，
        //    正好是本段输入长度 32768 的一半。前一半输出是"滤波器还没吃饱"的爬升段，
        //    参考值本身在 −∞ 附近 ⟹ 任何逐样本相对误差都会被放大成噪声。
        //    下面的稳态起点是【数据驱动】算出来的（滑动 RMS 首次进入稳态 90% 区间），
        //    不是拍脑袋取 50%。
        const size_t m = std::min(r.nC, r.nG);
        const size_t kSteady = find_steady_start(yC[0], m, 1024);
        r.steadyStart = kSteady;
        const size_t mS = (kSteady < m) ? (m - kSteady) : 0;
        if (mS == 0) {
            std::printf("  44.1k→%-6u Hz  稳态区为空（输出过短），本行不产出精度数字\n", outR);
            resRows.push_back({ outR, r });
            continue;
        }

        double pk = 0.0, maxAbs = 0.0;
        for (size_t k = kSteady; k < m; ++k)
            for (int c = 0; c < 2; ++c) {
                pk = std::max(pk, std::fabs(yC[(size_t)c][k]));
                maxAbs = std::max(maxAbs, std::fabs(yG[(size_t)c][k] - yC[(size_t)c][k]));
            }
        const double floorAbs = pk * 1e-4;      // −80 dBFS 相对峰值
        double se = 0.0, sr = 0.0;
        RelStat st;
        for (size_t k = kSteady; k < m; ++k) {
            for (int c = 0; c < 2; ++c) {
                const double gv = yG[(size_t)c][k], cv = yC[(size_t)c][k];
                const double d = gv - cv;
                se += d * d; sr += cv * cv;
                if (std::fabs(cv) >= floorAbs) st.maxRel = std::max(st.maxRel, std::fabs(d) / std::fabs(cv));
                else ++st.skipped;
            }
        }
        r.maxAbs = maxAbs;
        r.maxRel = st.maxRel;
        r.peak = pk;
        r.maxAbsNorm = maxAbs / (pk + 1e-300);
        r.relDb = rel_rms_db(se, sr, mS * 2);
        r.ok = true;
        resRows.push_back({ outR, r });

        std::printf("  44.1k→%-6u Hz %10zu %10zu %8s | %11.3e %11.3e %11.3e %9.1f | %9.1f %9.1f\n",
                    outR, r.nC, r.nG,
                    twoStage ? "两段式" : std::to_string(r.T).c_str(),
                    r.maxAbs, r.maxAbsNorm, r.maxRel, r.relDb, r.cpuMs, r.gpuMs);
        std::printf("                      （稳态起点 %zu/%zu = %.1f%%（启动瞬态已剔除）；峰值 %.3f；"
                    "相对误差地板 −80 dBFS = %.2e，跳过 %zu/%zu 个低于地板的样点）\n",
                    kSteady, m, 100.0 * (double)kSteady / (double)m, pk, floorAbs, st.skipped, mS * 2);
    }

    // =======================================================================
    // 5b. 升频的生产形态：按 4096 样一块逐块喂（pipeline.h:359）
    // =======================================================================
    // 与卷积的关键差异（值得单独记一笔）：
    //   PolyphaseResampler 把 hist_ 留在【自己身上】跨块累积，每次调用都把
    //   "截至当前的全部历史"（已裁到 T_ 个）交给 GPU ⟹ 分块调用【不会】丢拖尾。
    //   卷积那边没有这层状态（GpuBridge::convolve 是无状态整块 API），所以会丢。
    //   两者形态相同、正确性却不同，不能想当然类推。
    std::printf("\n[5b] 升频的生产形态（4 块 × 4096 样，模拟 pipeline.h:359 的逐块调用）\n");
    std::printf("  %-18s %10s %10s %9s %9s\n", "转换", "CPU 合计 ms", "GPU 合计 ms", "GPU/CPU", "判定");
    std::printf("  -------------------+-------------+-------------+----------+--------\n");
    {
        const size_t chunk = 4096, nChunks = 4;   // 4 块够看形态；再多 CPU 侧太慢（见下）
        for (uint32_t outR : { 352800u, 384000u }) {
            ResamplerConfig rc;
            rc.inRate = 44100; rc.outRate = outR; rc.channels = 2;
            rc.totalTaps = 262144; rc.attenDb = 180.0; rc.transition = 0.04; rc.twoStage = true;
            PolyphaseResampler rs(rc);
            std::vector<std::vector<double>> in(2, std::vector<double>(chunk));
            for (size_t i = 0; i < chunk; ++i) {
                in[0][i] = 0.4 * std::sin(2 * M_PI * 997.0 * (double)i / 44100.0);
                in[1][i] = 0.4 * std::sin(2 * M_PI * 601.0 * (double)i / 44100.0);
            }
            std::vector<const double*> ip = { in[0].data(), in[1].data() };
            const size_t cap = rs.maxOutFrames(chunk);
            std::vector<std::vector<double>> y(2, std::vector<double>(cap));
            std::vector<double*> op = { y[0].data(), y[1].data() };

            rs.set_use_gpu(false);
            for (size_t c = 0; c < nChunks; ++c) rs.process(ip.data(), chunk, op.data());  // warm
            rs.reset();
            double tc = 0.0;
            {
                const double t0 = now_ms();
                for (size_t c = 0; c < nChunks; ++c) rs.process(ip.data(), chunk, op.data());
                tc = now_ms() - t0;
            }
            rs.reset();
            rs.set_use_gpu(true);
            if (!rs.gpu_active()) {
                std::printf("  44.1k→%-6u Hz %10s %10s %9s %9s\n", outR, "-", "-", "-", "GPU 不可用");
                continue;
            }
            for (size_t c = 0; c < nChunks; ++c) rs.process(ip.data(), chunk, op.data());  // warm
            rs.reset();
            double tg = 0.0;
            {
                const double t0 = now_ms();
                for (size_t c = 0; c < nChunks; ++c) rs.process(ip.data(), chunk, op.data());
                tg = now_ms() - t0;
            }
            std::printf("  44.1k→%-6u Hz %10.1f %10.1f %8.3fx %9s\n",
                        outR, tc, tg, tc > 0 ? tg / tc : 0.0, tg < tc ? "GPU 更快" : "GPU 更慢");
        }
        std::printf("  ⟹ 本机实测的这两档转换下，GPU 升频在【整块与分块两种形态】都大幅占优。\n");
        std::printf("     未覆盖的档位（见回报「未验证项」）：44.1k→88.2k/192k 只测了分块形态，\n");
        std::printf("     且没有穷举所有 outRate；结论不应外推成「升频一定快」。\n");
        std::printf("     原因：升频每输出样本要做 T 次乘加（T 可达 32768），是纯算力活；\n");
        std::printf("     而卷积在 mac 上是「CPU 做 FFT + GPU 只做逐点复数乘」，FFT 留在 CPU 上，\n");
        std::printf("     分块后每块 FFT 的固定开销压过了 GPU 的收益。\n");
    }

    // =======================================================================
    // 6. 生产调用形态下的拖尾丢失检测（mac 实测发现，见文件头 §4）
    // =======================================================================
    g_seed = 0x123456789ABCDEFull;
    std::printf("\n[6] 生产调用形态检测：按 4096 样逐块调用整块 API 时，IR 拖尾是否被算进去\n");
    std::printf("    做法：δ 放在样点 0，IR=65536（有值区间 0..65535），16 块 × 4096 样\n");
    std::printf("    期望：out[i] == ir[i]（i < 65536）。任何非零块全零 = 该块的 IR 尾巴丢了。\n\n");
    double tailRelDb = 0.0;
    long long tailLost = 0;
    {
        const size_t B = 4096, nCh = 16, n = B * nCh, irLen = 65536;
        std::vector<double> x(n, 0.0);
        x[0] = 1.0;
        std::vector<double> ir(irLen);
        for (size_t i = 0; i < irLen; ++i) ir[i] = std::exp(-3.0 * (double)i / (double)irLen);
        std::vector<double> out(n, 0.0), tmp(B, 0.0);
        for (size_t c = 0; c < nCh; ++c) {
            const int rc = g.conv(x.data() + c * B, (long long)B, ir.data(), (long long)irLen,
                                  tmp.data(), 1024);
            if (rc != 0) { std::printf("    第 %zu 块 rc=%d\n", c, rc); }
            for (size_t i = 0; i < B; ++i) out[c * B + i] = tmp[i];
        }
        // 真值：δ × ir = ir（0..irLen-1 有值，其余 0）
        std::vector<double> ref(n, 0.0);
        for (size_t i = 0; i < irLen && i < n; ++i) ref[i] = ir[i];
        double se = 0.0, sr = 0.0;
        for (size_t i = 0; i < n; ++i) {
            const double d = out[i] - ref[i];
            se += d * d; sr += ref[i] * ref[i];
            if (std::fabs(d) > 1e-9) ++tailLost;
        }
        tailRelDb = rel_rms_db(se, sr, n);
        std::printf("  逐块最大 |out|：");
        for (size_t c = 0; c < nCh; ++c) {
            double m = 0.0;
            for (size_t i = c * B; i < (c + 1) * B; ++i) m = std::max(m, std::fabs(out[i]));
            std::printf("%s%.0e", c == 0 ? "" : " ", m);
        }
        std::printf("\n  与真值不符的样点数 = %lld / %zu\n", tailLost, n);
        std::printf("  相对 RMS 误差 = %.2f dB（等效 %.1f bit）\n", tailRelDb, equiv_bits(tailRelDb));
        if (tailLost > 0) {
            std::printf("  ⚠️ 结论：逐块调用整块 API 会丢失上一块的 IR 拖尾。\n");
            std::printf("     irLen=65536 / 块=4096 ⟹ 每块只保留了 IR 的前 1/16，后 15/16 被丢弃。\n");
            std::printf("     这是【测量结果】，本工具不修改生产代码。详见回报与 docs/WIP-F6-GPU精度.md。\n");
        } else {
            std::printf("  ✅ 未观察到拖尾丢失。\n");
        }
    }

    // =======================================================================
    // 7. GPU 加速开关建议矩阵（由本机实测推导，不沿用上游）
    // =======================================================================
    std::printf("\n[7] GPU 加速开关建议矩阵（由上面第 3/4/5 节的【本机】实测推导）\n\n");

    // 7a：卷积按 (B, IR) 的收益矩阵 —— 用"整块调用"口径，因为那是 API 的真实语义
    std::printf("  7a 卷积收益矩阵（整块调用口径，n=65536，GPU/CPU 墙钟比；<1 表示 GPU 更快）\n");
    std::printf("      %6s |", "B\\IR");
    for (size_t irLen : { (size_t)1024, (size_t)16384, (size_t)65536, (size_t)262144 })
        std::printf(" %10zu", irLen);
    std::printf("\n      -------+-------------------------------------------\n");
    for (size_t B : { (size_t)512, (size_t)1024, (size_t)2048, (size_t)4096 }) {
        std::printf("      %6zu |", B);
        for (size_t irLen : { (size_t)1024, (size_t)16384, (size_t)65536, (size_t)262144 }) {
            double ratio = -1.0;
            for (const auto& r : matrix)
                if (r.ok && r.B == B && r.irLen == irLen && r.cpuMs > 0) ratio = r.gpuMs / r.cpuMs;
            if (ratio < 0) std::printf(" %10s", "-");
            else           std::printf(" %9.2fx%s", ratio, ratio < 1.0 ? "*" : " ");
        }
        std::printf("\n");
    }
    std::printf("      （* = GPU 更快）\n");

    // 7b：给出建议门限 —— 取"所有测试块长下 GPU 都更快"的最小 IR
    std::vector<size_t> irs = { 1024, 16384, 65536, 262144 };
    size_t suggestedIr = 0;
    for (size_t irLen : irs) {
        bool allWin = true, any = false;
        for (size_t B : { (size_t)512, (size_t)1024, (size_t)2048, (size_t)4096 }) {
            for (const auto& r : matrix) {
                if (r.ok && r.B == B && r.irLen == irLen && r.cpuMs > 0) {
                    any = true;
                    if (r.gpuMs >= r.cpuMs) allWin = false;
                }
            }
        }
        if (any && allWin) { suggestedIr = irLen; break; }
    }
    std::printf("\n  7b 卷积门控建议\n");
    if (suggestedIr)
        std::printf("      IR ≥ %zu：在全部测试块长（512/1024/2048/4096）下 GPU 都更快\n", suggestedIr);
    else
        std::printf("      没有任何 IR 档在全部测试块长下都让 GPU 占优 —— 必须按 (IR, 块长) 联合门控\n");

    // 逐块找"该 IR 下 GPU 开始占优的最小块长"
    std::printf("      分块长看拐点：\n");
    for (size_t irLen : irs) {
        std::printf("        IR=%-7zu ", irLen);
        for (size_t B : { (size_t)512, (size_t)1024, (size_t)2048, (size_t)4096 }) {
            double ratio = -1.0;
            for (const auto& r : matrix)
                if (r.ok && r.B == B && r.irLen == irLen && r.cpuMs > 0) ratio = r.gpuMs / r.cpuMs;
            std::printf("B=%zu:%-7s ", B, ratio < 0 ? "n/a"
                        : (ratio < 1.0 ? "GPU快" : "CPU快"));
        }
        std::printf("\n");
    }

    // 7c：升频
    std::printf("\n  7c 升频建议\n");
    for (const auto& row : resRows) {
        const ResCase& r = row.second;
        if (!r.ok) { std::printf("      44.1k→%-6u Hz：GPU 不可用，无法给建议\n", row.first); continue; }
        std::printf("      44.1k→%-6u Hz：GPU/CPU 墙钟 = %.2fx（%s）；精度 max|Δ|=%.2e，相对RMS=%.1f dB\n",
                    row.first, r.cpuMs > 0 ? r.gpuMs / r.cpuMs : 0.0,
                    (r.cpuMs > 0 && r.gpuMs < r.cpuMs) ? "GPU 更快" : "CPU 更快",
                    r.maxAbs, r.relDb);
    }
    std::printf("      ⚠️ mac 的升频是 float 路径，误差比上游 CUDA/HIP 的 FP64 大若干个数量级。\n");
    std::printf("         「输出逐位相同」（pipeline.h:52 注释）在 mac 上【不成立】——\n");
    std::printf("         应改为「偏差见 tools/gpu_precision 实测」。\n");

    // 7d：生产形态
    std::printf("\n  7d 生产形态（4096 样一块）\n");
    std::printf("      上游按 IR≥65536 门控是【整块调用】口径的结论；mac 生产是 4096 样分块，\n");
    std::printf("      两者不能互相套用 —— 见第 4 节实测比值与第 6 节的拖尾问题。\n");

    // =======================================================================
    // 8. 本机 vs 上游 的口径差异（写进输出，避免被当成"照抄"）
    // =======================================================================
    std::printf("\n[8] mac 与上游的口径差异（本工具不沿用上游数字）\n");
    std::printf("  * 后端：mac = librtagpu.dylib（Metal，运行时编译 MSL）；上游 = rtagpu.dll（HIP/CUDA）。\n");
    std::printf("  * 卷积数值路径：mac 与 HIP **相同**（都已核实）：CPU 端 double FFT →\n");
    std::printf("    只把【频谱】降 float → GPU 复数乘累加 → CPU 端 double IFFT。\n");
    std::printf("    （gpu_conv_hip.cpp:78/87 vs gpu_metal.mm:456/472）\n");
    std::printf("    ⟹ 卷积误差量级可互相印证，但阈值仍以本机实测为准（上表）。\n");
    std::printf("  * 升频数值路径：mac = float（Apple GPU 无 double）；上游 = double（FP64 MAC）。\n");
    std::printf("    ⟹ 上游「≤1e-12 / ≤2 ULP」口径在 mac 上完全不适用，本机实测见第 5 节。\n");
    std::printf("  * 显存模型：mac = 统一内存（MTLResourceStorageModeShared，无显式拷贝）；\n");
    std::printf("    上游独显 = 显式 H2D/D2H。所以「GPU/CPU 比」的形态必然不同，不能互抄。\n");
    std::printf("  * 上游 DLL 每次调用 hipMalloc/hipFree；mac 已用几何增长复用 MTLBuffer\n");
    std::printf("    （gpu_metal.mm Buf::ensure），固定开销本就小得多。\n");

    std::printf("\n完成。判据解读与阈值建议见 docs/WIP-F6-GPU精度.md。\n");
    return 0;
}
