// gpu_metal.mm — macOS Metal 版 GPU 加速后端（产物 librtagpu.dylib）
//
// ============================================================================
// 1) 这个文件是什么
// ============================================================================
// 它是 gpu_conv_hip.cpp / gpu_resample_hip.cpp 的 macOS 等价物：同样导出那套
// 动态加载 ABI，让管线在【链接期不依赖】它，运行时 dlopen 不到就自动退回 CPU。
//
// 导出符号（与 HIP/CUDA 版逐字节一致的 4 个，别增删）：
//   int  rta_gpu_available(void);
//   int  rta_gpu_convolve(const double* in, long long n,
//                         const double* ir, long long irLen,
//                         double* out, int block);
//   int  rta_gpu_resample(const double* hist, int ch, long long histLen,
//                         const double* phases, int L, int T,
//                         const int* bases, const int* phIdx, long long nOut,
//                         double* outInterleaved);
//   void rta_gpu_resample_invalidate(void);
//
// ⚠️ 注意 rta_gpu_resample 的【返回值语义】——这里很容易写错，写错就静默退回 CPU：
//     成功时返回 (int)nOut（= 实际产出的帧数），不是 0！
//     依据 src/dsp/resampler.h:268 `if (rc == (int)produced)`，
//     以及 src/gpu/gpu_resample_hip.cpp:119 `return (int)nOut;`。
//     rta_gpu_convolve 才是「0 = 成功 / 非 0 = 失败」
//     （依据 src/engine/pipeline.h:287 `... == 0`）。
//     两者语义不同，本文件按真实调用方写，不按想当然写。
//
// ============================================================================
// 2) 为什么用「运行时编译 MSL」而不是离线 metal 工具链
// ============================================================================
// 本机（macOS 27.0.1 / arm64 / Apple M4）没有安装 Metal 离线工具链：
//     $ xcrun -f metal
//     xcrun: error: unable to find utility "metal", not a developer tool or in PATH
// 所以 MSL 源码以 C 字符串内嵌在本文件里，首次调用时用
//     [device newLibraryWithSource:options:error:]
// 现场编译（主控已实测该路径可用，newComputePipelineStateWithFunction: 也成功）。
//
// 代价（如实记录）：
//   * 首次调用多花一次编译时间。本机实测（Apple M4 / macOS 27.0.1）：
//         首次 rta_gpu_available() = 116.6 ms（含 MSL 编译 + 3 个 pipeline + 探针）
//         第二次 rta_gpu_available() = 0.000 ms（结果已缓存，g_init_done）
//     即这 117 ms 在进程生命周期内只付一次。
//   * 编译期抓不到 MSL 语法错误，错误要等运行时才暴露 —— 因此
//     rta_gpu_available() 会把「库编译成功 + 三个 pipeline 都建成 + 平凡 kernel
//     真的跑出正确结果」全部作为可用性判据（见 §5），任何一步失败都返回 0。
//
// ============================================================================
// 3) 关键取舍：FFT 留在 CPU，GPU 只做「逐点复数乘累加」
// ============================================================================
// rta_gpu_convolve 是分块频域卷积（uniformly-partitioned overlap-add）：
//     out = conv(in, ir)，block = 分块大小 B，fftN = 2B
//     P  = ceil(irLen/B)  个 IR 分区；Nb = ceil(n/B) 个输入块
//     H[p] = FFT(ir[pB .. pB+B) 补零到 fftN)
//     X[b] = FFT(in[bB .. bB+B) 补零到 fftN)
//     Y[b][k] = Σ_{p=0..min(b,P-1)} H[p][k] · X[b-p][k]      ← 复数乘累加
//     逆变换 + overlap-add 得到 out
//
// 【取舍】本实现把 FFT / IFFT 留在 CPU（用项目自带的 src/dsp/fft.h，双精度），
// 只把中间的「逐点复数乘累加」搬到 GPU。理由：
//   1. 正确性容易保证：FFT 的旋转因子/位反转/归一化约定完全复用项目现有实现，
//      与 CPU 参考路径同源，不会引入「符号相反 / 少除 N」这类经典坑。
//   2. 复数乘累加就是这条链路的算力大头：它是 O(Nb·P·fftN) 的三重循环，
//      而 FFT 只是 O(Nb·fftN·log fftN)。IR 越长（P 越大）GPU 占比越高。
//   3. 不用在 MSL 里手写 radix-2 FFT，省掉一大块易错代码。
//
// 【代价】如实写清（以下数字为本机 Apple M4 / macOS 27.0.1 实测，2026-10-25）：
//   * 每块都要把 H/X/Y 频谱在 CPU↔GPU 之间过一遍，带宽成为上限。
//     Apple Silicon 是统一内存（MTLResourceStorageModeShared），CPU 直接读写
//     同一块物理内存，没有显式拷贝，代价主要是 cache 一致性而不是 bus 传输。
//   * FFT 部分仍然是 CPU 串行。实测「GPU/CPU 耗时比」（n=32768, block=1024）：
//         irLen=1024  (P=1)  → 1.26x   ← GPU 更慢 26%
//         irLen=4096  (P=4)  → 1.25x   ← GPU 更慢 25%
//         irLen=16384 (P=16) → 0.84x   ← GPU 快 16%
//         irLen=65536 (P=64) → 0.84x   ← GPU 快 16%
//     即：IR 很短时 GPU 路径【反而更慢】（命令缓冲提交/等待的开销压过复数乘的收益），
//     只有 P 足够大（复数乘 O(Nb·P·fftN) 压过 FFT 的 O(Nb·fftN·log fftN)）才有收益。
//     ⚠️ 因此不要声称「macOS 上卷积一定更快」。它保证【数值正确】，
//        性能是否更好取决于 IR 长度；短 IR 场景建议上层按 IR 长度决定是否走 GPU。
//   * 想让长 IR 拿到满速，后续应该把 FFT 也搬上 GPU（一次编译、多次复用）；
//     本次按任务要求优先选「CPU FFT + GPU 复数乘」，不为未验证的性能冒险。
//
// ============================================================================
// 4) 精度：double → float 的真实损失（必须如实写明）
// ============================================================================
// 桥接层传的是 double*，但 Apple GPU 对 double 支持极差（MSL 在 Apple Silicon
// 上根本不提供 double 运算）。所以本实现在边界上做 double→float→double 转换：
//
//   * 卷积：输入【不】先降精度 —— FFT 全程在 CPU 用 double 做完，只把【频谱】
//     H/X 舍入成 float 送 GPU，复数乘累加用 float（显式 fma，减少一次中间舍入），
//     再把 Y 频谱还原成 double 做 IFFT 与 overlap-add。
//     ⟹ 比 HIP 版更准：HIP 版先把输入降 float 再 FFT（多损失一次）。
//   * 升频：hist 与 phases 降 float 送 GPU，乘累加用 float（显式 fma），
//     结果还原 double。
//
// 为什么这个损失可以接受：
//   * 音频样本幅度在 |v| < 1 量级，float32 有 24 bit 有效位（相对精度 2^-24 ≈ 6e-8），
//     换算成 dB 约 −144 dBFS 的量化底噪 —— 远低于 16 bit（−96 dBFS）/
//     24 bit（−144 dBFS）容器的本底，也低于本机 DAC 的实际动态范围。
//   * float32 的动态范围（±3.4e38）对音频信号绰绰有余，不存在溢出风险。
//   * 卷积的 float 部分只作用于频谱（同一量级），累加项数 = P（分区数），
//     实测相对误差见 tests/test_gpu_metal.cpp 打印的具体数值。
//
// ⚠️ 边界（不假装没有）：极低电平信号（例如 −140 dBFS 以下的抖动/底噪）
// 在 float 下会被舍入噪声淹没，与 CPU double 路径【会有可测差异】。
// 这不是 bug，是 float 精度的物理上限；本实现不做 dither，也不声称 bit-perfect。
//
// ============================================================================
// 5) 失败策略（铁律：不许假装成功）
// ============================================================================
// 任何一步失败（设备拿不到 / MSL 编译失败 / pipeline 建不出来 / buffer 分配失败 /
// 命令缓冲提交或执行失败）都：fprintf(stderr, ...) 写清原因 → 返回非 0。
// 绝不返回「成功」却留下半成品输出 —— 调用方看到非 0 会退回 CPU 重算。
// rta_gpu_available() 只在「平凡 kernel 真的跑出正确结果」时才返回 1。

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "dsp/fft.h"

#include <cstdio>
#include <cstring>
#include <climits>
#include <cmath>
#include <mutex>
#include <vector>

using namespace rta::dsp;

// macOS 没有 __declspec(dllexport)
#define RTA_EXPORT extern "C" __attribute__((visibility("default")))

namespace {

// ---------------------------------------------------------------------------
// MSL 源码（运行时编译）
// ---------------------------------------------------------------------------
// 只用各代 Metal 都稳定的语法：metal_stdlib、device/constant 指针、
// [[thread_position_in_grid]]。不依赖任何新特性，避免默认语言版本变化踩坑。
constexpr const char* kMslSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

// 与主机侧 struct ConvParams 逐字段对应（全 int，无 padding 歧义）
struct ConvParams { int P; int Nb; int N; };
struct ResParams  { int ch; int histLen; int T; int L; int nOut; };

// ---- 平凡 kernel：验证「GPU 真的在执行」，而不只是「设备存在」----
// 写 12345 + i（不是常数）：如果只有第 0 个线程跑了，读回会不匹配，
// 常数写法则无法区分「全跑」和「只跑一个」。
kernel void probe_kernel(device float* y [[buffer(0)]],
                         uint i [[thread_position_in_grid]]) {
    y[i] = 12345.0f + float(i);
}

// ---- 分块卷积的「逐点复数乘累加」----
// H: [P][N] 频谱；X: [Nb][N] 频谱；Y: [Nb][N] 频谱（均为 float2 交错）
// Y[b][k] = sum_{p=0..min(b,P-1)} H[p][k] * X[b-p][k]
kernel void conv_mac_kernel(device const float2* H [[buffer(0)]],
                            device const float2* X [[buffer(1)]],
                            device float2*       Y [[buffer(2)]],
                            constant ConvParams& p [[buffer(3)]],
                            uint2 gid [[thread_position_in_grid]]) {
    const int k = (int)gid.x;
    const int b = (int)gid.y;
    if (k >= p.N || b >= p.Nb) return;
    const int pmax = (b < p.P - 1) ? b : (p.P - 1);
    float2 acc = float2(0.0f, 0.0f);
    for (int i = 0; i <= pmax; ++i) {
        const float2 h = H[(ulong)i * (ulong)p.N + (ulong)k];
        const float2 x = X[(ulong)(b - i) * (ulong)p.N + (ulong)k];
        // 复数乘：(hx+i·hy)(xx+i·xy) = (hx·xx - hy·xy) + i·(hx·xy + hy·xx)
        // 用 fma 让每项只舍入一次（硬件 FFMA），比 a*b+c 少一次中间舍入。
        acc.x = fma(h.x,  x.x, acc.x);
        acc.x = fma(-h.y, x.y, acc.x);
        acc.y = fma(h.x,  x.y, acc.y);
        acc.y = fma(h.y,  x.x, acc.y);
    }
    Y[(ulong)b * (ulong)p.N + (ulong)k] = acc;
}

// ---- 多相升频：每个输出样本 = 某相位的 T 个抽头 · 最近 T 个输入样本 ----
// 索引语义严格照 src/gpu/gpu_resample_hip.cpp:21-50 与 src/dsp/resampler.h:278-292：
//   hist 是【声道主序】[ch][histLen]（不是交错！）
//   acc  = sum_{u=0..uEnd-1} phases[p][u] * hist[c][base - u]   ← base-u 递减
//   uEnd = min(base+1, T, histLen)     ← 启动阶段历史不足 T 时缺的部分视为零
//   out 是【交错】[nOut][ch]
kernel void resample_kernel(device const float* hist   [[buffer(0)]],
                            device const float* phases [[buffer(1)]],
                            device const int*   bases  [[buffer(2)]],
                            device const int*   phIdx  [[buffer(3)]],
                            device float*       out    [[buffer(4)]],
                            constant ResParams& p      [[buffer(5)]],
                            uint gid [[thread_position_in_grid]]) {
    const ulong total = (ulong)p.nOut * (ulong)p.ch;
    if ((ulong)gid >= total) return;
    const int n = (int)((ulong)gid / (ulong)p.ch);
    const int c = (int)((ulong)gid % (ulong)p.ch);

    const int base = bases[n];
    const int ph   = phIdx[n];
    // 防御：越界索引一律输出 0（绝不读越界显存）。
    // 正常调用方不会给出这种输入；给出时宁可保守地写 0 并让上层看到数值异常，
    // 也不赌一个越界读。
    if (ph < 0 || ph >= p.L || base < 0 || base >= p.histLen) { out[gid] = 0.0f; return; }

    int uEnd = base + 1;
    if (uEnd > p.T)       uEnd = p.T;
    if (uEnd > p.histLen) uEnd = p.histLen;

    device const float* tab = phases + (ulong)ph * (ulong)p.T;
    device const float* h   = hist   + (ulong)c  * (ulong)p.histLen;

    float acc = 0.0f;
    for (int u = 0; u < uEnd; ++u) acc = fma(tab[u], h[base - u], acc);
    out[gid] = acc;
}
)MSL";

// ---------------------------------------------------------------------------
// 主机侧参数结构（必须与 MSL 里的同名 struct 逐字段一致）
// 全部用 int ⟹ 无 padding 歧义，sizeof 在两侧必然相同。
// ---------------------------------------------------------------------------
struct ConvParams { int P; int Nb; int N; };
struct ResParams  { int ch; int histLen; int T; int L; int nOut; };
static_assert(sizeof(ConvParams) == 12, "ConvParams 必须与 MSL 布局一致");
static_assert(sizeof(ResParams)  == 20, "ResParams 必须与 MSL 布局一致");

// 与 MSL float2 内存布局一致（8 字节：x,y 各 float）
struct F2 { float x, y; };
static_assert(sizeof(F2) == 8, "F2 必须与 MSL float2 同布局");

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------
// 用 recursive_mutex：rta_gpu_available() 会调 init_once()，而 convolve/resample
// 先拿锁再调 init_once()，非递归锁会自死锁。GPU 调用本身是毫秒级，
// 递归锁的额外开销可忽略。
std::recursive_mutex g_mu;

id<MTLDevice>              g_dev      = nil;
id<MTLCommandQueue>        g_queue    = nil;
id<MTLComputePipelineState> g_psProbe = nil;
id<MTLComputePipelineState> g_psConv  = nil;
id<MTLComputePipelineState> g_psRes   = nil;

bool g_init_done = false;   // 是否已尝试过初始化
bool g_ready     = false;   // 是否【验证过】真的可用

// 可增长复用的 MTLBuffer 缓存。
// 要求：不许每次调用都重新分配大 buffer（相位表 2 MB 级，每块重传会吃掉全部收益）。
struct Buf {
    id<MTLBuffer> b = nil;
    size_t        cap = 0;

    // 确保容量 >= bytes。realloced 置位表示【换了新 buffer】（旧内容丢失，
    // 上层缓存的相位表等必须重传）。
    bool ensure(id<MTLDevice> dev, size_t bytes, const char* what, bool* realloced = nullptr) {
        if (realloced) *realloced = false;
        if (b && bytes <= cap) return true;
        size_t want = bytes;
        if (cap && want < cap * 2) want = cap * 2;   // 几何增长，避免抖动
        if (want < 4096) want = 4096;
        // StorageModeShared：Apple Silicon 统一内存，CPU 可直接读写 contents，
        // 不需要 blit 拷贝。这也是本实现能省掉一次显式 memcpy 的原因。
        b = [dev newBufferWithLength:want options:MTLResourceStorageModeShared];
        if (!b) {
            std::fprintf(stderr, "[rtagpu-metal] 分配 MTLBuffer 失败: %s（请求 %zu 字节）\n", what, want);
            cap = 0;
            return false;
        }
        cap = want;
        if (realloced) *realloced = true;
        return true;
    }
    void* host() const { return b ? b.contents : nullptr; }
};

Buf g_bufH, g_bufX, g_bufY;      // 卷积：IR 频谱 / 输入频谱 / 输出频谱
Buf g_bufHist, g_bufPh, g_bufBases, g_bufPhIdx, g_bufOut;   // 升频

// 相位表缓存（整首歌不变；rtagpu 的 HIP 版曾因每次重传 2 MB 导致只有 7.5x 加速比）
int  g_phL = -1, g_phT = -1;
bool g_phValid = false;

// ---------------------------------------------------------------------------
// 初始化：设备 + 运行时编译 MSL + 三个 pipeline + 平凡 kernel 真跑一次
// 调用方必须持有 g_mu（recursive，所以不持有时也安全）
// ---------------------------------------------------------------------------
bool init_once() {
    if (g_init_done) return g_ready;
    g_init_done = true;

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) {
        std::fprintf(stderr, "[rtagpu-metal] MTLCreateSystemDefaultDevice() 返回 nil（无可用 Metal 设备）\n");
        return false;
    }

    NSError* err = nil;
    NSString* src = [NSString stringWithUTF8String:kMslSource];
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    if (!lib) {
        std::fprintf(stderr, "[rtagpu-metal] MSL 运行时编译失败: %s\n",
                     err ? [[err localizedDescription] UTF8String] : "未知原因");
        return false;
    }

    // 三个 kernel 全都要能建出 pipeline：只要有一个失败，就说明这个 dylib 的
    // 一部分能力不可用。此时 available() 报 0（宁可整条链路退回 CPU，
    // 也不要让桥接层以为「GPU 可用」而每次调用都失败）。
    // 注意 __strong：目标是【全局】变量，默认的 __autoreleasing 写回参数
    // 会触发 "passing address of non-local object to __autoreleasing parameter"。
    auto make_ps = [&](const char* name, id<MTLComputePipelineState> __strong* out) -> bool {
        id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:name]];
        if (!fn) {
            std::fprintf(stderr, "[rtagpu-metal] MSL 里找不到 kernel '%s'\n", name);
            return false;
        }
        NSError* e2 = nil;
        *out = [dev newComputePipelineStateWithFunction:fn error:&e2];
        if (!*out) {
            std::fprintf(stderr, "[rtagpu-metal] 创建 pipeline '%s' 失败: %s\n", name,
                         e2 ? [[e2 localizedDescription] UTF8String] : "未知原因");
            return false;
        }
        return true;
    };
    if (!make_ps("probe_kernel",     &g_psProbe)) return false;
    if (!make_ps("conv_mac_kernel",  &g_psConv))  return false;
    if (!make_ps("resample_kernel",  &g_psRes))   return false;

    id<MTLCommandQueue> q = [dev newCommandQueue];
    if (!q) {
        std::fprintf(stderr, "[rtagpu-metal] 创建 MTLCommandQueue 失败\n");
        return false;
    }

    // ---- 平凡 kernel 验活（铁律 5：不信「设备存在」就当可用）----
    // 写 12345+i 并逐元素比对。架构/驱动不匹配时会静默不执行，读回全是哨兵值。
    constexpr int kProbeN = 256;
    id<MTLBuffer> pb = [dev newBufferWithLength:(kProbeN * sizeof(float))
                                       options:MTLResourceStorageModeShared];
    if (!pb) {
        std::fprintf(stderr, "[rtagpu-metal] 探针 buffer 分配失败\n");
        return false;
    }
    float* hp = (float*)pb.contents;
    for (int i = 0; i < kProbeN; ++i) hp[i] = -7.0f;   // 哨兵

    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    if (!cb || !enc) {
        std::fprintf(stderr, "[rtagpu-metal] 探针命令缓冲/编码器创建失败\n");
        return false;
    }
    [enc setComputePipelineState:g_psProbe];
    [enc setBuffer:pb offset:0 atIndex:0];
    const NSUInteger tg = (kProbeN + 63) / 64;
    [enc dispatchThreadgroups:MTLSizeMake(tg, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        std::fprintf(stderr, "[rtagpu-metal] 探针命令缓冲未完成（status=%ld, error=%s）\n",
                     (long)cb.status,
                     cb.error ? [[cb.error localizedDescription] UTF8String] : "无");
        return false;
    }
    int bad = -1;
    for (int i = 0; i < kProbeN; ++i) {
        if (hp[i] != 12345.0f + (float)i) { bad = i; break; }
    }
    if (bad >= 0) {
        std::fprintf(stderr,
                     "[rtagpu-metal] 平凡 kernel 结果不符（第 %d 个应为 %.1f，实为 %.1f）"
                     "——GPU 没有真的执行，判为不可用\n",
                     bad, 12345.0f + (float)bad, (double)hp[bad]);
        return false;
    }

    g_dev = dev;
    g_queue = q;
    g_ready = true;
    return true;
}

// 带锁的入口
bool ready() {
    std::lock_guard<std::recursive_mutex> lk(g_mu);
    return init_once();
}

// 提交并等待；失败返回 false 并打印原因
bool run_and_wait(id<MTLCommandBuffer> cb, const char* what) {
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        std::fprintf(stderr, "[rtagpu-metal] %s 执行失败（status=%ld, error=%s）\n", what,
                     (long)cb.status,
                     cb.error ? [[cb.error localizedDescription] UTF8String] : "无");
        return false;
    }
    return true;
}

} // namespace

// ===========================================================================
// 导出：可用性
// ===========================================================================
RTA_EXPORT int rta_gpu_available(void) {
    return ready() ? 1 : 0;
}

// ===========================================================================
// 导出：分块频域卷积
// 返回 0 = 成功；非 0 = 失败（调用方 src/engine/pipeline.h:287 据此退回 CPU）
// ===========================================================================
RTA_EXPORT int rta_gpu_convolve(const double* in, long long n,
                               const double* ir, long long irLen,
                               double* out, int block) {
    if (!in || !ir || !out || n <= 0 || irLen <= 0) {
        std::fprintf(stderr, "[rtagpu-metal] convolve: 参数非法（in=%p ir=%p out=%p n=%lld irLen=%lld）\n",
                     (const void*)in, (const void*)ir, (const void*)out, n, irLen);
        return 1;
    }
    std::lock_guard<std::recursive_mutex> lk(g_mu);
    if (!init_once()) return 1;

    const size_t B    = (block > 0 && (block & (block - 1)) == 0) ? (size_t)block : (size_t)1024;
    const size_t N    = (size_t)n;
    const size_t fftN = B * 2;
    const size_t P    = ((size_t)irLen + B - 1) / B;
    const size_t Nb   = (N + B - 1) / B;

    // 上限保护：参数结构用 int 传，超范围就如实拒绝，绝不静默截断
    if (fftN > (size_t)INT_MAX || P > (size_t)INT_MAX || Nb > (size_t)INT_MAX) {
        std::fprintf(stderr, "[rtagpu-metal] convolve: 规模超限（fftN=%zu P=%zu Nb=%zu）\n", fftN, P, Nb);
        return 2;
    }

    bool rh = false, rx = false, ry = false;
    if (!g_bufH.ensure(g_dev, P  * fftN * sizeof(F2), "卷积 H 频谱", &rh)) return 3;
    if (!g_bufX.ensure(g_dev, Nb * fftN * sizeof(F2), "卷积 X 频谱", &rx)) return 3;
    if (!g_bufY.ensure(g_dev, Nb * fftN * sizeof(F2), "卷积 Y 频谱", &ry)) return 3;

    F2* H = static_cast<F2*>(g_bufH.host());
    F2* X = static_cast<F2*>(g_bufX.host());
    if (!H || !X) {
        std::fprintf(stderr, "[rtagpu-metal] convolve: MTLBuffer contents 为空\n");
        return 3;
    }

    // ---- 1) 主机侧 double 精度 FFT：只有【频谱】降为 float 送 GPU ----
    std::vector<cplx> buf(fftN);
    for (size_t p = 0; p < P; ++p) {
        std::fill(buf.begin(), buf.end(), cplx(0.0, 0.0));
        for (size_t i = 0; i < B; ++i) {
            const size_t k = p * B + i;
            if (k < (size_t)irLen) buf[i] = cplx(ir[k], 0.0);
        }
        fft(buf);
        F2* dst = H + p * fftN;
        for (size_t k = 0; k < fftN; ++k) {
            dst[k].x = (float)buf[k].real();
            dst[k].y = (float)buf[k].imag();
        }
    }
    for (size_t b = 0; b < Nb; ++b) {
        std::fill(buf.begin(), buf.end(), cplx(0.0, 0.0));
        for (size_t i = 0; i < B; ++i) {
            const size_t k = b * B + i;
            if (k < N) buf[i] = cplx(in[k], 0.0);
        }
        fft(buf);
        F2* dst = X + b * fftN;
        for (size_t k = 0; k < fftN; ++k) {
            dst[k].x = (float)buf[k].real();
            dst[k].y = (float)buf[k].imag();
        }
    }

    // ---- 2) GPU：逐点复数乘累加 ----
    ConvParams cp{};
    cp.P = (int)P;
    cp.Nb = (int)Nb;
    cp.N = (int)fftN;
    {
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        if (!cb || !enc) {
            std::fprintf(stderr, "[rtagpu-metal] convolve: 命令缓冲/编码器创建失败\n");
            return 4;
        }
        [enc setComputePipelineState:g_psConv];
        [enc setBuffer:g_bufH.b offset:0 atIndex:0];
        [enc setBuffer:g_bufX.b offset:0 atIndex:1];
        [enc setBuffer:g_bufY.b offset:0 atIndex:2];
        [enc setBytes:&cp length:sizeof(cp) atIndex:3];
        // 64x4=256 线程/组；k 在 x 方向连续 ⟹ 同一 warp 内地址连续，合并访存良好
        const NSUInteger gx = (fftN + 63) / 64;
        const NSUInteger gy = (Nb + 3) / 4;
        [enc dispatchThreadgroups:MTLSizeMake(gx, gy, 1) threadsPerThreadgroup:MTLSizeMake(64, 4, 1)];
        [enc endEncoding];
        if (!run_and_wait(cb, "卷积复数乘累加 kernel")) return 4;
    }

    const F2* Y = static_cast<const F2*>(g_bufY.host());
    if (!Y) {
        std::fprintf(stderr, "[rtagpu-metal] convolve: Y buffer contents 为空\n");
        return 5;
    }

    // ---- 3) 主机侧 double 精度 IFFT + overlap-add ----
    std::vector<double> ola(B, 0.0);
    for (size_t b = 0; b < Nb; ++b) {
        const F2* src = Y + b * fftN;
        for (size_t k = 0; k < fftN; ++k) buf[k] = cplx((double)src[k].x, (double)src[k].y);
        fft(buf, /*inverse=*/true);
        for (size_t i = 0; i < B; ++i) {
            const size_t k = b * B + i;
            const double v = buf[i].real() + ola[i];
            if (k < N) out[k] = v;
            ola[i] = buf[B + i].real();
        }
    }
    return 0;
}

// ===========================================================================
// 导出：多相升频（缓存失效）
// ===========================================================================
RTA_EXPORT void rta_gpu_resample_invalidate(void) {
    std::lock_guard<std::recursive_mutex> lk(g_mu);
    g_phValid = false;
    g_phL = -1;
    g_phT = -1;
}

// ===========================================================================
// 导出：多相升频
// ⚠️ 成功返回 (int)nOut（帧数），失败返回 -1 —— 与 HIP/CUDA 版一致。
//    不要改成「0 = 成功」，那会让 src/dsp/resampler.h:268 永远不成立。
// ===========================================================================
RTA_EXPORT int rta_gpu_resample(const double* hist, int ch, long long histLen,
                               const double* phases, int L, int T,
                               const int* bases, const int* phIdx, long long nOut,
                               double* outInterleaved) {
    // 与 HIP 版同样的退化输入约定：返回 0
    if (nOut <= 0 || ch <= 0 || T <= 0) return 0;
    if (!hist || !phases || !bases || !phIdx || !outInterleaved) {
        std::fprintf(stderr, "[rtagpu-metal] resample: 空指针参数\n");
        return -1;
    }
    if (L <= 0 || histLen <= 0) {
        std::fprintf(stderr, "[rtagpu-metal] resample: 参数非法（L=%d histLen=%lld）\n", L, histLen);
        return -1;
    }
    // 参数结构用 int 传递；超范围如实拒绝，不静默截断
    if (histLen > (long long)INT_MAX || nOut > (long long)INT_MAX) {
        std::fprintf(stderr, "[rtagpu-metal] resample: 规模超限（histLen=%lld nOut=%lld）\n", histLen, nOut);
        return -1;
    }

    std::lock_guard<std::recursive_mutex> lk(g_mu);
    if (!init_once()) return -1;

    const size_t nOutS  = (size_t)nOut;
    const size_t chS    = (size_t)ch;
    const size_t hlS    = (size_t)histLen;
    const size_t needPh = (size_t)L * (size_t)T;

    bool rHist = false, rOut = false, rB = false, rI = false, rPh = false;
    if (!g_bufHist .ensure(g_dev, chS * hlS * sizeof(float), "升频 hist",  &rHist)) return -1;
    if (!g_bufOut  .ensure(g_dev, nOutS * chS * sizeof(float), "升频 out", &rOut))  return -1;
    if (!g_bufBases.ensure(g_dev, nOutS * sizeof(int), "升频 bases", &rB))          return -1;
    if (!g_bufPhIdx.ensure(g_dev, nOutS * sizeof(int), "升频 phIdx", &rI))          return -1;
    if (!g_bufPh   .ensure(g_dev, needPh * sizeof(float), "升频 phases", &rPh))     return -1;

    // 换过 buffer ⟹ 之前上传的相位表丢了，必须重传
    if (rPh) g_phValid = false;

    // ---- 上传 hist：double[ch][histLen] → float[ch][histLen] ----
    {
        float* d = static_cast<float*>(g_bufHist.host());
        if (!d) { std::fprintf(stderr, "[rtagpu-metal] resample: hist contents 为空\n"); return -1; }
        const size_t tot = chS * hlS;
        for (size_t i = 0; i < tot; ++i) d[i] = (float)hist[i];
    }
    std::memcpy(g_bufBases.host(), bases,  nOutS * sizeof(int));
    std::memcpy(g_bufPhIdx.host(), phIdx,  nOutS * sizeof(int));

    // ---- 相位表：整首歌不变，只在 L/T 变化或 invalidate() 后重传 ----
    if (!g_phValid || g_phL != L || g_phT != T) {
        float* d = static_cast<float*>(g_bufPh.host());
        if (!d) { std::fprintf(stderr, "[rtagpu-metal] resample: phases contents 为空\n"); return -1; }
        for (size_t i = 0; i < needPh; ++i) d[i] = (float)phases[i];
        g_phL = L;
        g_phT = T;
        g_phValid = true;
    }

    // ---- GPU ----
    ResParams rp{};
    rp.ch      = ch;
    rp.histLen = (int)histLen;
    rp.T       = T;
    rp.L       = L;
    rp.nOut    = (int)nOut;
    {
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        if (!cb || !enc) {
            std::fprintf(stderr, "[rtagpu-metal] resample: 命令缓冲/编码器创建失败\n");
            return -1;
        }
        [enc setComputePipelineState:g_psRes];
        [enc setBuffer:g_bufHist.b  offset:0 atIndex:0];
        [enc setBuffer:g_bufPh.b    offset:0 atIndex:1];
        [enc setBuffer:g_bufBases.b offset:0 atIndex:2];
        [enc setBuffer:g_bufPhIdx.b offset:0 atIndex:3];
        [enc setBuffer:g_bufOut.b   offset:0 atIndex:4];
        [enc setBytes:&rp length:sizeof(rp) atIndex:5];
        const size_t total = nOutS * chS;
        const NSUInteger tg = (NSUInteger)((total + 255) / 256);
        [enc dispatchThreadgroups:MTLSizeMake(tg, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        [enc endEncoding];
        if (!run_and_wait(cb, "升频多相乘累加 kernel")) return -1;
    }

    // ---- 读回：float[nOut][ch] 交错 → double[nOut][ch] 交错 ----
    {
        const float* s = static_cast<const float*>(g_bufOut.host());
        if (!s) { std::fprintf(stderr, "[rtagpu-metal] resample: out contents 为空\n"); return -1; }
        const size_t tot = nOutS * chS;
        for (size_t i = 0; i < tot; ++i) outInterleaved[i] = (double)s[i];
    }

    return (int)nOut;   // ← 成功返回帧数，不是 0
}
