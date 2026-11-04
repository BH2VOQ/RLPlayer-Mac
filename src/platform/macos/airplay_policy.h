// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// airplay_policy.h — 1.1.2 AirPlay 传输策略与能力纯函数（平台层，离线可测）
#pragma once

#include "platform/audio_out.h"
#include <cmath>
#include <cstdint>
#include <string>

namespace rta::platform::macos {

// CoreAudio 常见 TransportType FourCC 常量（定义于 AudioHardwareBase.h）
constexpr uint32_t kTransportUnknown            = 0;
constexpr uint32_t kTransportBuiltIn            = 0x626c746e; // 'bltn'
constexpr uint32_t kTransportAggregate          = 0x67727570; // 'grup'
constexpr uint32_t kTransportAutoAggregate      = 0x6175746f; // 'auto'
constexpr uint32_t kTransportVirtual            = 0x76697274; // 'virt'
constexpr uint32_t kTransportPCI                = 0x70636920; // 'pci '
constexpr uint32_t kTransportUSB                = 0x75736220; // 'usb '
constexpr uint32_t kTransportUsb                = kTransportUSB;
constexpr uint32_t kTransportFireWire           = 0x31333934; // '1394'
constexpr uint32_t kTransportBluetooth          = 0x626c7565; // 'blue'
constexpr uint32_t kTransportBluetoothLE        = 0x626c6561; // 'blea'
constexpr uint32_t kTransportHDMI               = 0x68646d69; // 'hdmi'
constexpr uint32_t kTransportDisplayPort        = 0x64707274; // 'dprt'
constexpr uint32_t kTransportAirPlay            = 0x61697270; // 'airp'
constexpr uint32_t kTransportAVB                = 0x65617662; // 'eavb'
constexpr uint32_t kTransportThunderbolt        = 0x7468756e; // 'thun'
constexpr uint32_t kTransportContinuityCaptureWired     = 0x63637764; // 'ccwd'
constexpr uint32_t kTransportContinuityCaptureWireless  = 0x6363776c; // 'ccwl'

// 1. 判断是否为 AirPlay 传输协议（按 CoreAudio kAudioDeviceTransportTypeAirPlay 'airp' 四CC 识别而非名字）
inline bool is_airplay_transport(uint32_t transportType) {
    return transportType == kTransportAirPlay;
}

// 2. 将 TransportType 四CC 转为标准可读英文标识
inline std::string transport_type_to_string(uint32_t transportType) {
    switch (transportType) {
        case kTransportAirPlay:           return "airplay";
        case kTransportUSB:               return "usb";
        case kTransportBuiltIn:           return "builtin";
        case kTransportBluetooth:
        case kTransportBluetoothLE:       return "bluetooth";
        case kTransportAggregate:
        case kTransportAutoAggregate:     return "aggregate";
        case kTransportVirtual:           return "virtual";
        case kTransportPCI:               return "pci";
        case kTransportHDMI:              return "hdmi";
        case kTransportDisplayPort:       return "displayport";
        case kTransportThunderbolt:       return "thunderbolt";
        case kTransportFireWire:          return "firewire";
        case kTransportAVB:               return "avb";
        case kTransportContinuityCaptureWired:
        case kTransportContinuityCaptureWireless: return "continuity";
        default:                          return "unknown";
    }
}

// 3. 规范化 AirPlay 设备的能力（AP-1.2, AP-1.3, AP-1.4）
//    若设备为 AirPlay：
//    - transport 设为 "airplay"
//    - sharedOnly 强制为 true
//    - exclusiveMode 强制为 false (不申请 Hog Mode)
//    - bitPerfectCapable 强制为 false (AirPlay 经过网络传输与缓冲重封装，未获端到端 bit-perfect 验证)
//    - dsd 设为 None，dopCarrierRate 和 nativeDsdRate 清零
inline void sanitize_airplay_caps(DeviceCaps& caps) {
    if (caps.transport == "unknown" && caps.transportType != 0) {
        caps.transport = transport_type_to_string(caps.transportType);
    }
    if (is_airplay_transport(caps.transportType)) {
        caps.transport = "airplay";
        caps.sharedOnly = true;
        caps.exclusiveMode = false;
        caps.bitPerfectCapable = false;
        caps.dsd = DsdTransport::None;
        caps.dopCarrierRate = 0;
        caps.nativeDsdRate = 0;
    }
}

// 4. 校验与仲裁 OpenSpec（开流前防护，在写硬件前完成）
//    - 严禁向 AirPlay 或 shared 模式发送 DoP (AP-1.4)
//    - 严禁 AirPlay 申请 exclusive/Hog
//    - 校验 rate/channels 与设备当前格式匹配（平台层不能直接改输入解释却不重采样）
inline bool validate_open_spec(const DeviceCaps& caps, const OpenSpec& spec,
                               std::string& errZh, std::string& errEn) {
    errZh.clear();
    errEn.clear();

    const bool isAirPlay = is_airplay_transport(caps.transportType) || caps.sharedOnly;

    // 严禁向 AirPlay 或 共享模式（经系统混音）发送 DoP（破坏 DSD 标记并导致白噪声爆音）
    if (spec.dop) {
        if (isAirPlay) {
            errZh = "拒绝向 AirPlay 设备发送 DoP：AirPlay 输出为共享有损/重封装网络流，不支持 DSD 承载";
            errEn = "Refused DoP transmission to AirPlay: AirPlay output uses shared network streaming and does not support DSD encapsulation.";
            return false;
        }
        if (spec.shared) {
            errZh = "拒绝在共享输出模式下发送 DoP：系统音频混音器会损坏 DoP 标记并产生严重白噪声";
            errEn = "Refused DoP in shared mode: system audio mixer will corrupt DoP markers and cause noise.";
            return false;
        }
    }

    // AirPlay 强制共享模式，禁止 Hog / 独占
    if (isAirPlay && (spec.exclusive || !spec.shared)) {
        errZh = "AirPlay 设备仅支持共享输出（不支持 Hog 模式独占锁定）";
        errEn = "AirPlay device only supports shared mode output (exclusive Hog mode not supported).";
        return false;
    }

    // 格式协商检查：若设备具有明确的 currentRate 且不是 0，若请求采样率与之不一致，
    // 且上层未完成重采样，平台层不能擅自按不同速率解释音频缓冲
    if (isAirPlay && caps.currentRate != 0 && spec.rate != caps.currentRate) {
        errZh = "请求采样率 (" + std::to_string(spec.rate) + " Hz) 与 AirPlay 设备当前硬件采样率 (" +
                std::to_string(caps.currentRate) + " Hz) 不匹配，必须由引擎重采样后再输出";
        errEn = "Requested sample rate (" + std::to_string(spec.rate) + " Hz) does not match AirPlay device rate (" +
                std::to_string(caps.currentRate) + " Hz); engine must resample prior to output.";
        return false;
    }

    // 声道数检查
    if (isAirPlay && caps.currentChannels > 0 && spec.channels != caps.currentChannels) {
        errZh = "请求声道数 (" + std::to_string(spec.channels) + ") 与 AirPlay 设备声道数 (" +
                std::to_string(caps.currentChannels) + ") 不匹配";
        errEn = "Requested channels (" + std::to_string(spec.channels) + ") does not match AirPlay device channels (" +
                std::to_string(caps.currentChannels) + ").";
        return false;
    }

    return true;
}

// 5. 设备延迟计算与来源构建（AP-1.2）
//    读取 device latency / safety offset / stream latency 等属性时保留可读来源，
//    数值不是端到端测量；延迟若只读部分注明 source，不能固定 2s。
inline bool compute_device_latency(uint32_t deviceLatencyFrames,
                                   uint32_t safetyOffsetFrames,
                                   uint32_t streamLatencyFrames,
                                   double sampleRate,
                                   bool hasDevLatency,
                                   bool hasSafetyOffset,
                                   bool hasStreamLatency,
                                   double& outLatencyMs,
                                   std::string& outSource) {
    outLatencyMs = 0.0;
    outSource.clear();

    if (sampleRate <= 0.0) {
        outSource = "unknown (invalid sample rate)";
        return false;
    }

    if (!hasDevLatency && !hasSafetyOffset && !hasStreamLatency) {
        outLatencyMs = 0.0;
        outSource = "unknown";
        return false;
    }

    uint32_t totalFrames = 0;
    std::string details;

    if (hasDevLatency) {
        totalFrames += deviceLatencyFrames;
        details += "device: " + std::to_string(deviceLatencyFrames) + " frames";
    }
    if (hasSafetyOffset) {
        totalFrames += safetyOffsetFrames;
        if (!details.empty()) details += ", ";
        details += "safety: " + std::to_string(safetyOffsetFrames) + " frames";
    }
    if (hasStreamLatency) {
        totalFrames += streamLatencyFrames;
        if (!details.empty()) details += ", ";
        details += "stream: " + std::to_string(streamLatencyFrames) + " frames";
    } else {
        if (!details.empty()) details += " (stream latency unavailable)";
    }

    outLatencyMs = (double)totalFrames * 1000.0 / sampleRate;
    outSource = "CoreAudio: " + details;
    return true;
}

// 6. endpoint_alive 状态判断逻辑
inline bool check_endpoint_alive(uint32_t deviceIsAliveVal, uint32_t outputStreamCount) {
    return (deviceIsAliveVal != 0) && (outputStreamCount > 0);
}

} // namespace rta::platform::macos
