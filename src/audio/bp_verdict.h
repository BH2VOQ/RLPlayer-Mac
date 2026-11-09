// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// bp_verdict.h —— bit-perfect 结论的**唯一判定实现**（纯函数，零设备依赖，可离线单测）
//
// 为什么必须收敛到一处（2026-11-09，用户反馈「共享模式必然不是 bit-perfect，但程序显示是」）：
//   同一个结论原本有五份互不一致的实现：
//     ① tools/rtaweb.cpp 的信号链 JSON 内联 lambda；
//     ② tools/rtaweb.cpp 的 ps.bpState 分支（①的复制粘贴）；
//     ③ src/platform/audio_out.h 的 decide_route（注释自称「唯一实现」，生产**从未调用**）；
//     ④ src/engine/preset_profiles.h 的 check_bit_perfect（只有测试在调）；
//     ⑤ src/platform/macos/audio_out_coreaudio.h 的 CoreAudioOutput::bit_perfect()
//        （生产在跑，但结论只进了 RENDERFAIL 诊断行，没进界面）。
//   判决权分散的后果不是"风格问题"：③④⑤ 里都有的判据（独占、是否经混音、float 源、
//   声道变换），在真正给用户看的 ①② 里**统统缺失** ⟹ 界面会报出后端明确否认的结论。
//
// 本文件的判据（任何一条成立 ⟹ 非 bit-perfect）：
//   0. 不是 DirectSDM 的 1-bit 直通（直通是比 yes 更严格的一档，单独返回 "direct"）
//   1. 经系统混音（CoreAudio 共享 / AirPlay）—— 样本进入混音域，后级增益/格式/抖动全不可控
//   2. 重采样（outRate != inRate）
//   3. 音量 != 0 dB
//   4. 抖动/噪声整形
//   5. 预衰减（ISP 过采样峰值保护 / 调制器余量）
//   6. EQ / IR 卷积 / DoP 载波
//   7. 位深降低（outBits < 源真实位深）
//   8. ReplayGain / AlbumGain
//   9. 等响度补偿**实际生效**（音量 0 dB 时它自动旁路，不算违规）
//  10. 声道变换（上混/下混）
//  11. 解码器给的是 float 容器（管线必然走双精度平面 + 重新量化）
//
// 允许但必须如实说明的：源位深 < 输出位深（低位补零，数值逐位不变，不构成违规）。
#pragma once
#include <cmath>        // fabs / lround
#include <cstdint>
#include <string>
#include <vector>

namespace rta::audio {

// 一次播放的全部事实（全部来自后端自证，不许由调用方猜）
struct BpInputs {
    bool     directSdmOk = false;   // DirectSDM 1-bit 直通且确无处理
    bool     viaAirPlay  = false;   // 传输是 AirPlay（比"共享"更具体，理由优先）
    bool     sharedMixer = false;   // 经系统混音（CoreAudio 共享 / AirPlay 恒真）
    uint32_t inRate      = 0;       // 源采样率（0 = 未知，不据此下结论）
    uint32_t outRate     = 0;       // 实际送出去的采样率（DoP 时是载波率）
    double   volumeDb    = 0.0;
    bool     shaperOn    = false;   // 抖动/噪声整形实际生效
    double   preAttenDb  = 0.0;     // 预衰减（<0 才是真衰减）
    bool     eqOn        = false;
    bool     convOn      = false;   // IR 卷积
    bool     dopCarrier  = false;
    int      srcBits     = 0;       // 源文件真实位深（0 = 未知）
    int      outBits     = 0;
    double   replayGainDb= 0.0;
    bool     loudnessOn  = false;   // 等响度**实际**有提升（音量达上界时后端自动旁路 ⟹ false）
    bool     channelMix  = false;   // 发生上混/下混
    bool     floatSource = false;   // 解码容器是 IEEE float
    // 硬件回调侧的实测自证（来自 CoreAudioOutput）：
    //   formatFallback 非空 = 设备层做了容器转换（如 24-in-32 / Float32），精度可能没丢但容器变了
    //   gainNotUnity    = 后端渲染增益 != 1.0（已在 volumeDb 之外再确认一次，纵深防御）
    bool     formatFallback = false;
    bool     gainNotUnity   = false;
};

struct BpVerdict {
    std::string state;              // "direct" | "yes" | "no"
    std::string why;                // 直接可进 UI/日志的中文理由（空 violations 时给绿色说明）
    std::vector<std::string> violations;
};

// 方向判定：只有两端都已知才下结论。降采样绝不能被叫成"升频"（用户 2026-11-09 截图）。
enum class RateDirection { Unknown = 0, Same, Upsample, Downsample };

inline RateDirection rate_direction(uint32_t inRate, uint32_t outRate) {
    if (inRate == 0 || outRate == 0) return RateDirection::Unknown;
    if (inRate == outRate) return RateDirection::Same;
    return (outRate < inRate) ? RateDirection::Downsample : RateDirection::Upsample;
}

inline BpVerdict bp_verdict(const BpInputs& x) {
    BpVerdict r;
    auto bad = [&r](std::string s) { r.violations.push_back(std::move(s)); };

    // 0) DirectSDM：比 "yes" 更严格的一档，必须最先返回（DSD 源逐位直通，跳过 PCM 与调制）
    if (x.directSdmOk) {
        r.state = "direct";
        r.why   = "DirectSDM：1-bit 直通，跳过 PCM 与调制";
        return r;
    }

    // 1) 传输/混音域。AirPlay 的理由更具体，先报 AirPlay 再报共享。
    if (x.viaAirPlay) {
        bad("AirPlay 网络传输（发送端逐位无损；接收端解码后的输出无法验证）");
    } else if (x.sharedMixer) {
        // 这条是用户 2026-11-09 报的**根因缺失项**：共享模式经 CoreAudio 混音器，
        // 样本被转 float32、经系统音量与其它客户端混音，后级是否还有重采样/抖动不可观测。
        // 后端 CoreAudioOutput::bit_perfect() 一直据此报 false，界面却从不看它。
        bad("共享输出（经系统混音，样本进入混音域后不可控）");
    }

    // 2) 重采样（方向另由 rate_direction() 给，理由文案只说事实）
    if (x.inRate && x.outRate && x.inRate != x.outRate) {
        bad("重采样 " + std::to_string(x.inRate) + "→" + std::to_string(x.outRate) + " Hz");
    }

    if (std::abs(x.volumeDb) > 1e-9) bad("音量 " + std::to_string((int)std::lround(x.volumeDb)) + " dB");
    if (x.shaperOn)   bad("抖动/整形");
    if (x.preAttenDb < -1e-9) bad("预衰减");
    if (x.eqOn)       bad("EQ");
    if (x.convOn)     bad("IR 卷积");
    if (x.dopCarrier) bad("DoP 载波");
    if (x.srcBits > 0 && x.outBits > 0 && x.outBits < x.srcBits) bad("位深降低");
    if (std::abs(x.replayGainDb) > 1e-9) bad("ReplayGain");
    if (x.loudnessOn) bad("等响度补偿");
    if (x.channelMix) bad("声道变换");
    if (x.floatSource) bad("浮点解码容器（需重新量化）");
    if (x.formatFallback) bad("设备层容器转换（实际格式与源不一致）");
    if (x.gainNotUnity)   bad("输出级增益非 1.0");

    if (r.violations.empty()) {
        r.state = "yes";
        r.why   = "源→解码→输出全程逐位一致";
        // 源位深低于输出位深：低位补零，数值逐个不变。如实说明，不算违规。
        if (x.srcBits > 0 && x.outBits > x.srcBits) {
            r.why += "（" + std::to_string(x.srcBits) + "→" + std::to_string(x.outBits) +
                     " bit 低位补零，数值不变）";
        }
        return r;
    }

    r.state = "no";
    for (size_t i = 0; i < r.violations.size(); ++i) {
        if (i) r.why += "、";
        r.why += r.violations[i];
    }
    return r;
}

}  // namespace rta::audio