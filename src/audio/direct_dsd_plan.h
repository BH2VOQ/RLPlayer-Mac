// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// direct_dsd_plan.h — 1.1.2 DSD P0-1 / P0-2: DirectSDM 资格判定与播放切片规划辅助
//
// ============================ 1.1.2 加固（审计后续）============================
// 本文件是**纯规划逻辑**：不读文件、不分配、不开设备，因此可以被离线测试逐条钉死。
// 本轮加固只处理"能证明的缺陷"，不按猜测放宽/收紧判据：
//   * 非有限 CUE 时间（NaN/±Inf）：旧代码 `cueStart >= 0.0` 对 NaN 为 false ⟹ NaN 被
//     当成"没有 CUE"静默整轨播放；+Inf 则会先 `llround(Inf * framesPerSec)`（未定义行为）
//     再靠 `b < 0` 碰巧拒掉。现在两者都在入口显式拒绝。
//   * 整数溢出：`requestedDsd * base` 用 32 位乘（档位填大值会回绕成"合法"目标），
//     `cueStart * framesPerSec` 也先乘后判。现在全部先升到 64 位 / double 域判定。
//   * 非法速率：`effectiveRate` 不是 16 的整数倍时 `effectiveRate/16` 会静默截断载波率。
//   * 跨度校验：`plan` 只说"要多少帧"，不说"数据够不够"。新增 validate_direct_dsd_span()
//     把"帧号 → 字节跨度"这个换算收口到一处，避免调用方各自手写 `posFrames * 2`。
#pragma once
#include <cstdint>
#include <cstddef>
#include <string>
#include <algorithm>
#include <cmath>
#include <limits>

namespace rta::audio {

// DSD 合法位率下限：DSD64（44.1k 族 = 2822400，48k 族 = 3072000 更大）。
// 低于它的"DSD 速率"不是 DSD 位流（例如 88200 是 PCM 采样率，按本文件的整数倍规则
// 会被错算成"可整数倍转换"），所以在资格判定里直接判非法。
inline constexpr uint32_t kMinDirectDsdRate = 2822400u;
// 规划用的合理性上限：1-bit 位率不可能到这个量级（DSD1024 = 45.2 MHz）。
// 超过它说明输入已经坏掉，继续算只会得到荒谬的帧数（以及下游的越界）。
inline constexpr uint32_t kMaxDirectDsdRate = 100000000u;
// DoP 帧数上限：2^40 帧 ≈ 1.1e12 帧 ≈ 137 TB 的 1-bit 数据。
// 这远高于任何真实文件，只为把 size_t → long long 的换算与下游 `frameEnd*2` 关进安全区。
inline constexpr uint64_t kMaxDirectDoPFrames = (1ull << 40);

enum class DirectDsdMode {
    PassThrough, // 逐位直通：源速率 == 目标速率，无任何处理
    RateConvert, // 1-bit 速率转换（同族整数倍）：需转换后送 DoP 载波，不可标逐位直通
    Ineligible   // 不满足直通或转换条件（需回退 PCM/调制）
};

struct DirectDsdEligibility {
    bool eligible = false;
    DirectDsdMode mode = DirectDsdMode::Ineligible;
    uint32_t srcRate = 0;
    uint32_t targetRate = 0;
    std::string why;
    std::string bitPerfectState = "no"; // "direct", "no"
    std::string bitPerfectWhy;
};

// P0-2 严格直通与转换资格判定
//
// ⚠️ 关于"跨族"分支（保留但按构造不可达，如实标注而不是假装它在工作）：
//    target 的族是由**源**族推出来的（base = 源的族），所以 target 永远与 srcRate 同族。
//    "44.1k 源 → 48k 目标"这种请求在本函数里根本构造不出来（它由用户选择的 DSD 档位 ×
//    源族决定，而不是由设备族决定）。因此 srcFam != dstFam 这段是**防御性代码**：
//    它现在不承担判据职责，只在 base 推导规则将来改变时兜底。
//    旧测试注释把它写成"44.1k 族 → 48k 族"，是把"档位"当成了"族"，属注释错误（已改）。
inline DirectDsdEligibility evaluate_direct_dsd(
    uint32_t srcRate,
    int channels,
    int requestedDsd,
    bool dsdNative,
    bool anyProc,
    bool volumeActive)
{
    DirectDsdEligibility r;
    r.srcRate = srcRate;

    if (dsdNative) {
        r.why = "DSD Native 还没实现（它走 Native DSD 驱动通道，不是 DoP）";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }
    if (requestedDsd < 64) {
        r.why = "输出不是 DSD：把 SDM 页的比特率选成 DSD64/128/256（DoP）";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }
    if (srcRate == 0) {
        r.why = "缺少源 DSD 速率";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }
    // 非法源速率（见 kMinDirectDsdRate 的说明）：低于 DSD64 的"位率"不是 DSD 位流。
    if (srcRate < kMinDirectDsdRate || srcRate > kMaxDirectDsdRate || (srcRate % 16u) != 0u) {
        r.why = "源速率不是合法 DSD 位率（" + std::to_string(srcRate) +
                " Hz）：需要 16 的整数倍且不低于 DSD64（" + std::to_string(kMinDirectDsdRate) + " Hz）";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }

    const uint32_t base = (srcRate % 48000u == 0) ? 48000u : 44100u;
    // 64 位乘法 + 显式溢出判据：旧实现用 uint32 乘，档位填大值会回绕成一个"看起来合法"
    // 的目标速率（例如 100000 * 44100 回绕后甚至可能等于源速率 ⟹ 被误判为逐位直通）。
    const uint64_t target64 = (uint64_t)(unsigned)requestedDsd * (uint64_t)base;
    if (target64 == 0ull || target64 > (uint64_t)std::numeric_limits<uint32_t>::max()) {
        r.why = "DSD 档位非法（" + std::to_string(requestedDsd) + " × " + std::to_string(base) +
                " Hz 溢出或为 0）";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }
    const uint32_t target = (uint32_t)target64;
    // 目标必须是 16 的整数倍：DoP 载波 = 位率/16，否则载波会被截断（例如档位填 65 时
    // 44100×65 = 2866500，/16 = 179156.25）。真实档位（64/128/256/512）恒满足。
    if ((target % 16u) != 0u) {
        r.why = "DSD 档位非法（" + std::to_string(requestedDsd) + " × " + std::to_string(base) +
                " Hz = " + std::to_string(target) + " Hz 不是 16 的整数倍，得不到有效 DoP 载波）";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }
    r.targetRate = target;

    // 任何音效处理、音量激活，绝对不可直通也不可转换直接输出（必须经 PCM/调制处理）
    if (anyProc) {
        r.why = "存在处理（EQ / 卷积 / 响度 / 重放增益 / 声道微调 / 声道映射），不能直通";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }
    if (volumeActive) {
        r.why = "音量不是 0 dB（或渐变未结束），直通会失去逐位一致性";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }

    if (srcRate == target) {
        r.eligible = true;
        r.mode = DirectDsdMode::PassThrough;
        r.why = "源与目标同为 " + std::to_string(srcRate) + " Hz 且无处理：跳过调制";
        r.bitPerfectState = "direct";
        r.bitPerfectWhy = "DirectSDM：1-bit 直通，跳过 PCM 与调制";
        return r;
    }

    // 同族整数倍转换判定（防御性分支，见函数头注：target 族恒等于源族）
    const uint32_t srcFam = (srcRate % 48000u == 0u) ? 48000u : 44100u;
    const uint32_t dstFam = (target % 48000u == 0u) ? 48000u : 44100u;
    if (srcFam != dstFam) {
        r.why = "跨族转换不可行（" + std::to_string(srcRate) + " Hz → " + std::to_string(target) + " Hz）";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }

    const bool up = target > srcRate;
    const uint32_t hi = up ? target : srcRate;
    const uint32_t lo = up ? srcRate : target;
    if (lo == 0 || (hi % lo) != 0) {
        r.why = "非整数倍转换不可行（" + std::to_string(srcRate) + " Hz → " + std::to_string(target) + " Hz）";
        r.bitPerfectState = "no";
        r.bitPerfectWhy = r.why;
        return r;
    }

    r.eligible = true;
    r.mode = DirectDsdMode::RateConvert;
    r.why = "源 DSD " + std::to_string(srcRate) + " Hz → 目标 " + std::to_string(target) +
            " Hz 同族整数倍：先做 1-bit 速率转换（非逐位直通）";
    r.bitPerfectState = "no";
    r.bitPerfectWhy = "DSD 速率转换 " + std::to_string(srcRate) + "→" + std::to_string(target) + " Hz（1-bit 调制变换）";
    return r;
}

// P0-1 播放切片与参数规划（必须在速率转换后，基于实际有效流计算）
struct DirectDsdSlicePlan {
    uint32_t effectiveRate = 0;
    uint32_t carrierRate = 0;
    uint64_t totalBits = 0;
    size_t totalDoPFrames = 0;
    size_t frameBase = 0;
    size_t frameCount = 0;
    size_t frameEnd = 0;
    bool cueValid = true;
    std::string cueError;
};

// 每声道需要多少字节才能容纳 bits 个 1-bit 样本（= ceil(bits/8)）。
//
// ★ 为什么 `floor(bits/16)` 个 DoP 帧一定装得下（审计里"可能越界"那个说法的正解）：
//     DoP 帧 = 16 个 DSD 位 = **正好 2 字节**。
//     totalDoPFrames = floor(bits/16) ⟹ totalDoPFrames*2 = 2*floor(bits/16) ≤ bits/8 ≤ ceil(bits/8)。
//   所以只要 `data[c].size() == ceil(bits/8)`（read_dsd 的 DSF 分支）或 `size() == bits/8`
//   （DFF 分支 bits 本身就是字节数×8），整轨切片的最后一帧都在界内。
//   换句话说：越界需要"数据比 bits 声明的还短"，那是**流本身不自洽**，不是规划算错。
//   既然如此，`totalDoPFrames` 不该为了"防越界"而再被扣一帧（那会静默丢掉有效数据）；
//   正确的做法是在真正切片的地方做一次**跨度校验**（见 validate_direct_dsd_span）。
inline size_t direct_dsd_channel_bytes(uint64_t bits) {
    if (bits > std::numeric_limits<uint64_t>::max() - 7ull) return std::numeric_limits<size_t>::max();
    const uint64_t bytes = (bits + 7ull) / 8ull;
    if (bytes > (uint64_t)std::numeric_limits<size_t>::max()) return std::numeric_limits<size_t>::max();
    return (size_t)bytes;
}

// 严格跨度校验结果：切片 [frameBase, frameEnd) 需要的字节是否真的存在于每声道数据里。
struct DirectDsdSpanCheck {
    bool ok = false;
    size_t requiredBytes = 0;   // 每声道至少需要的字节数 = frameEnd * 2
    size_t availableBytes = 0;  // 各声道里最少的那个（用于报错定位）
    size_t badChannel = 0;      // 第一个不够的声道号（ok=false 时有效）
    std::string why;
};

// 校验切片的字节跨度。perChannelBytes(c) 返回第 c 声道的字节数（应为 data[c].size()）。
// 判据：每个声道都必须有 frameEnd*2 字节（frameEnd 帧 × 2 字节/帧），且声道数足够。
// 这是给**真正做切片的地方**用的（rtaweb 的 append lambda），不是给规划用的：
// 规划只负责算帧号，是否切得动由这里如实回答，绝不靠"应该够"。
template <class FnBytes>
inline DirectDsdSpanCheck validate_direct_dsd_span(const DirectDsdSlicePlan& sp,
                                                   size_t channels, FnBytes perChannelBytes) {
    DirectDsdSpanCheck ck;
    if (!sp.cueValid) {
        ck.why = "切片规划本身无效：" + sp.cueError;
        return ck;
    }
    if (channels == 0) {
        ck.why = "声道数为 0";
        return ck;
    }
    if (sp.frameEnd > std::numeric_limits<size_t>::max() / 2u) {
        ck.why = "帧数过大导致字节跨度溢出（frameEnd=" + std::to_string(sp.frameEnd) + "）";
        return ck;
    }
    ck.requiredBytes = sp.frameEnd * 2u;
    size_t minAvail = std::numeric_limits<size_t>::max();
    for (size_t c = 0; c < channels; ++c) {
        const size_t avail = perChannelBytes(c);
        if (avail < minAvail) minAvail = avail;
        if (avail < ck.requiredBytes) {
            ck.ok = false;
            ck.availableBytes = avail;
            ck.badChannel = c;
            ck.why = "第 " + std::to_string(c) + " 声道数据不足：切片需要 " +
                     std::to_string(ck.requiredBytes) + " 字节（" + std::to_string(sp.frameEnd) +
                     " 帧 × 2），实际只有 " + std::to_string(avail) + " 字节";
            return ck;
        }
    }
    ck.ok = true;
    ck.availableBytes = (minAvail == std::numeric_limits<size_t>::max()) ? 0 : minAvail;
    return ck;
}

// 指针版本（给 C 风格调用点用；nullptr 当 0 字节处理，即"数据不足"）
inline DirectDsdSpanCheck validate_direct_dsd_span(const DirectDsdSlicePlan& sp,
                                                   size_t channels,
                                                   const size_t* perChannelBytes) {
    return validate_direct_dsd_span(sp, channels, [perChannelBytes](size_t c) -> size_t {
        return perChannelBytes ? perChannelBytes[c] : 0;
    });
}

inline DirectDsdSlicePlan plan_direct_dsd_slice(
    uint32_t effectiveRate,
    uint64_t effectiveBits,
    double cueStart,
    double cueEnd)
{
    DirectDsdSlicePlan sp;
    sp.effectiveRate = effectiveRate;
    sp.totalBits = effectiveBits;
    if (effectiveRate == 0) {
        sp.cueValid = false;
        sp.cueError = "effectiveRate 为 0";
        return sp;
    }
    // DoP 载波 = 位率/16，所以位率必须是 16 的整数倍；否则 carrierRate 会被静默截断，
    // 下游所有帧号/时间换算都跟着偏（这是"看着能用"的错，必须明确拒）。
    if ((effectiveRate % 16u) != 0u) {
        sp.cueValid = false;
        sp.cueError = "采样率不是 16 的整数倍（" + std::to_string(effectiveRate) + " Hz），无法得到有效 DoP 载波";
        return sp;
    }
    if (effectiveRate > kMaxDirectDsdRate) {
        sp.cueValid = false;
        sp.cueError = "采样率异常（" + std::to_string(effectiveRate) + " Hz 超出 DSD 合理范围）";
        return sp;
    }

    sp.carrierRate = effectiveRate / 16u;
    // floor(bits/16)：见 direct_dsd_channel_bytes 上方的证明 —— 对自洽的流（data 覆盖 bits）
    // 这个地板除法不会越界，所以**不**额外扣减（那等于静默丢数据）。
    sp.totalDoPFrames = (size_t)(effectiveBits / 16ull);
    if (sp.totalDoPFrames == 0) {
        sp.cueValid = false;
        sp.cueError = "DSD 数据不足一个 DoP 帧（16 位）";
        return sp;
    }
    if ((uint64_t)sp.totalDoPFrames > kMaxDirectDoPFrames) {
        sp.cueValid = false;
        sp.cueError = "DSD 数据量异常（DoP 帧数 " + std::to_string(sp.totalDoPFrames) + " 超出规划上限）";
        return sp;
    }

    sp.frameBase = 0;
    sp.frameCount = sp.totalDoPFrames;

    // 非有限 CUE 时间：NaN 的比较全为 false（旧代码会把它当"没有 CUE"静默整轨播），
    // ±Inf 会让 llround 进入未定义行为区。两者都必须在入口拒绝。
    if (!std::isfinite(cueStart)) {
        sp.cueValid = false;
        sp.cueError = "CUE 起点非法（非数值或无穷）";
        return sp;
    }
    if (cueStart >= 0.0) {
        if (!std::isfinite(cueEnd)) {
            sp.cueValid = false;
            sp.cueError = "CUE 终点非法（非数值或无穷）";
            return sp;
        }
        const double fileSec = (double)sp.totalDoPFrames / (double)sp.carrierRate;

        if (cueEnd >= 0.0 && cueEnd <= cueStart) {
            sp.cueValid = false;
            sp.cueError = "CUE 分轨区间非法：终点 " + std::to_string(cueEnd) +
                          "s 不大于起点 " + std::to_string(cueStart) + "s（文件 " +
                          std::to_string(fileSec) + "s）";
            return sp;
        }

        // 先在 double 域判越界，再做 llround：旧实现先乘后判，`llround(1e300 * 176400)`
        // 是未定义行为（实践上得到 LLONG_MIN，靠 `b < 0` 碰巧拒掉）。
        if (!(cueStart < fileSec)) {
            sp.cueValid = false;
            sp.cueError = "CUE 分轨起点越界：起点 " + std::to_string(cueStart) +
                          "s ≥ 文件时长 " + std::to_string(fileSec) + "s";
            return sp;
        }

        const long long b = (long long)std::llround(cueStart * (double)sp.carrierRate);
        if (b < 0 || (size_t)b >= sp.totalDoPFrames) {   // 后置条件（四舍五入后仍须在界内）
            sp.cueValid = false;
            sp.cueError = "CUE 分轨起点越界：起点 " + std::to_string(cueStart) +
                          "s ≥ 文件时长 " + std::to_string(fileSec) + "s";
            return sp;
        }

        long long e;
        if (cueEnd >= 0.0) {
            // 终点越界 = "到结尾"（与原行为一致），但要先判再用，绝不能把 Inf/超界值送进 llround。
            e = (cueEnd >= fileSec) ? (long long)sp.totalDoPFrames
                                    : (long long)std::llround(cueEnd * (double)sp.carrierRate);
        } else {
            e = (long long)sp.totalDoPFrames;
        }
        if (e > (long long)sp.totalDoPFrames) e = (long long)sp.totalDoPFrames;
        if (e <= b) {
            sp.cueValid = false;
            sp.cueError = "CUE 分轨区间越界";
            return sp;
        }

        sp.frameBase = (size_t)b;
        sp.frameCount = (size_t)(e - (long long)b);
    }

    sp.frameEnd = sp.frameBase + sp.frameCount;   // ≤ totalDoPFrames，不会溢出
    return sp;
}

// seek 偏移计算（基于区间内 frameCount 计算实际绝对 DoP 帧）
// 非有限 seekFrac（NaN/±Inf）按"不跳转"处理：旧实现里 NaN 会穿过 `< 0.0` 与 clamp，
// 结果依赖 std::min/std::max 的参数顺序，属于"碰巧对"。
inline size_t calculate_direct_seek_pos(size_t frameBase, size_t frameCount, double seekFrac) {
    if (!std::isfinite(seekFrac) || seekFrac < 0.0) return frameBase;
    const double clamped = std::max(0.0, std::min(1.0, seekFrac));
    const size_t rel = std::min(frameCount, (size_t)(clamped * (double)frameCount + 0.5));
    return frameBase + rel;
}

} // namespace rta::audio
