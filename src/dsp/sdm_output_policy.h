// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// sdm_output_policy.h — U12：1-bit SDM 输出 corner 准入策略
//
// 上游契约（照抄语义，不新增规则）：
//   1. 只有「真 EC」豁免 corner 质量下限。真 EC 的判定必须与 modulator.h 里
//      SdmModulator 的 NTF 分支 **同构**（那里是 Chebyshev 优先，其次 Ec/ecCorrection）：
//            family == Chebyshev                  -> Chebyshev 设计分支
//            family == Ec                         -> EC 设计分支
//            family != Chebyshev && ecCorrection  -> EC 设计分支
//      ⟹ actualEc = (family == Ec) || (family != Chebyshev && ecCorrection)
//      所以「Chebyshev + ecCorrection」**不**豁免：它实际走的是 Chebyshev NTF，
//      corner 直接参与极点设计，20 kHz corner 会把二次量化噪声堆回可听带。
//   2. 非真 EC（actualEc == false）且 cornerHz < 100 kHz ⟹ 拒绝，错误码
//      sdm.corner_quality，消息里带稳定子串 SDM_CORNER_QUALITY。
//      20 kHz / 50 kHz 只是被点名的样例，判据是「< 100 kHz」——99 kHz 同样拒绝。
//   3. corner <= 0 或非有限值（NaN/Inf）⟹ 拒绝，错误码 sdm.corner_invalid，
//      与质量下限错误分开：「值本身不成立」vs「值合法但音质不合格」。
//      这一类先于族豁免检查：corner 是会被回显/序列化的配置量，即便 EC 族在
//      设计上不使用它，NaN/非正数也不该作为有效配置被接受。
//   4. 绝不静默换 corner：拒绝就是拒绝。调用方不得把非法值悄悄改成 100 kHz 后
//      沿用同一设置继续——那会让用户在不知情时听到与所选配置不同的输出。
//
// 两个入口：
//   - sdm_corner_admission(...)          不抛版，给设置保存 / 开流前置闸门用；
//   - validate_one_bit_sdm_corner(...)   抛 std::invalid_argument 版，照抄上游异常语义。
//   ⚠️ 该策略只适用于 1-bit（levels == 2）路径；多电平 AHM 不经过这两个函数。
//
// 为什么把 policy 独立成头而不是塞进 SdmModulator：
//   构造函数 throw 会把异常带上音频线程/播放路径；本地要求三处前置闸门在
//   「改设置」和「开流」之前就用不抛接口拒绝，并把原因原样交给 UI。
//
// 依赖关系：只依赖 modulator.h 的 ModulatorFamily（保持调用点类型一致）。
#pragma once

#include "modulator.h"

#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace rta::dsp {

// 1-bit SDM corner 质量下限（Hz）。非真 EC 的 1-bit corner 必须 >= 该值。
inline constexpr double kSdmOneBitCornerFloorHz = 100000.0;

// 稳定字面量（UI / 日志 / 测试按字符串匹配；改字面量 = 破坏契约）。
inline constexpr const char* kSdmCornerQualityCode = "sdm.corner_quality";
inline constexpr const char* kSdmCornerInvalidCode = "sdm.corner_invalid";
inline constexpr const char* kSdmCornerQualityTag  = "SDM_CORNER_QUALITY";
inline constexpr const char* kSdmCornerInvalidTag  = "SDM_CORNER_INVALID";

struct SdmCornerAdmission {
    bool        admitted = true;
    std::string code;     // 拒绝时非空
    std::string message;  // 拒绝时非空，以对应稳定 tag 开头
};

// 真 EC 判定：与 SdmModulator 的 NTF 分支同构（Chebyshev 优先）。
inline constexpr bool sdm_is_actual_ec(ModulatorFamily family, bool ecCorrection) {
    return family == ModulatorFamily::Ec ||
           (family != ModulatorFamily::Chebyshev && ecCorrection);
}

namespace sdm_policy_detail {
// 十进制文本（不依赖 std::to_string 的小数尾巴；测试输出也用它）。
inline std::string hz_text(double hz) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.6g", hz);
    return std::string(buf);
}
}  // namespace sdm_policy_detail

// 不抛版准入：admitted=false 时 code/message 已填好，调用方原样转交给 UI。
inline SdmCornerAdmission sdm_corner_admission(ModulatorFamily family, bool ecCorrection,
                                               double cornerHz) {
    // (1) 数值本身先校验，不依赖族（见文件头第 3 条）。
    if (!std::isfinite(cornerHz) || cornerHz <= 0.0) {
        SdmCornerAdmission a;
        a.admitted = false;
        a.code     = kSdmCornerInvalidCode;
        a.message  = std::string(kSdmCornerInvalidTag) +
                     ": 1-bit SDM corner 必须是有限正数（当前 " +
                     sdm_policy_detail::hz_text(cornerHz) + "）";
        return a;
    }

    // (2) 质量下限：只有真 EC 豁免（见文件头第 1、2 条）。
    if (!sdm_is_actual_ec(family, ecCorrection) && cornerHz < kSdmOneBitCornerFloorHz) {
        SdmCornerAdmission a;
        a.admitted = false;
        a.code     = kSdmCornerQualityCode;
        a.message  = std::string(kSdmCornerQualityTag) + ": 1-bit SDM（" +
                     modulator_family_name(family) + (ecCorrection ? " + ecCorrection" : "") +
                     "）的 corner " + sdm_policy_detail::hz_text(cornerHz) + " Hz 低于 " +
                     sdm_policy_detail::hz_text(kSdmOneBitCornerFloorHz) +
                     " Hz 下限；低 corner 会把量化噪声压回可听带（仅 EC 族豁免）";
        return a;
    }

    return SdmCornerAdmission{};  // admitted
}

// 抛异常版（上游语义）：拒绝一律 std::invalid_argument，质量下限情形消息内含
// 稳定子串 SDM_CORNER_QUALITY，非法数值情形内含 SDM_CORNER_INVALID。
inline void validate_one_bit_sdm_corner(ModulatorFamily family, bool ecCorrection,
                                        double cornerHz) {
    const SdmCornerAdmission a = sdm_corner_admission(family, ecCorrection, cornerHz);
    if (!a.admitted) throw std::invalid_argument(a.message);
}

}  // namespace rta::dsp
