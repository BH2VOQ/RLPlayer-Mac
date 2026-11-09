// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// platform/macos/audio_out_coreaudio.h — audio_out.h 的 CoreAudio 实现
#pragma once
//
// 设计要点（对应 PLATFORM.md §4/§5/§7/§8）：
//   * 用 AUHAL（kAudioUnitSubType_HALOutput）输出单元：它是 macOS 上唯一能
//     "指定设备 + 设置物理格式（采样率/位深/声道）"的官方路径，等价于 WASAPI 独占。
//   * bit-perfect 的前提：设备侧物理格式 == 源格式，且我们不插入任何格式转换
//     （关闭 AUHAL 的输入侧、不设 converter），gain == 1.0。
//   * int32 交错、低位对齐到请求位深（§1）：16 bit 时取值 [-32768,32767]。
//     交给 CoreAudio 时按设备位深重新打包成其原生交错布局。
//   * Hog Mode：独占设备，避免被系统混音器重采样 —— 这是 bit-perfect 的关键一环。
//
// ⚠️ 铁律 1（绝不擅自播放可听声音）：本文件只提供"写数据"的能力，不产生任何测试音。
//   谁调用 write 就播什么；默认电平策略在 tools/rtaplay 侧（--gen 默认 -60 dBFS）。
//
// ⚠️ 未解决项（铁律 4）：
//   * Native DSD 直通未实现（macOS 没有通用的原生 DSD 用户态 API，需要设备私有驱动）。
//     因此 caps().dsd 只报 DoP（当设备支持承载率时），Native 一律报 None。
//   * DoP 承载：本实现只保证"能按 24-bit 容器输出承载率"，不负责把 DSD 位流
//     打包进 DoP 帧（那属于 DSP/引擎层，不在平台层）。
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <cstring>
#include <cmath>      // ldexp / llround（音量定标）
#include <mutex>
#include <string>
#include <vector>

// 2026-10-25：欠载归因（ZeroAttrib / quantize_period_write）从被移除的 wasapi_out.h
// 提取到跨平台头 audio/write_attrib.h。功能不能删、只做全量移植 ——「写不进去」的
// 成因分解是 RENDERFAIL 判据本体（tests/test_renderfail.cpp 直接驱动它），
// macOS 侧必须继续提供同一套可观测性，否则等于把该能力弄丢而不是"删掉平台实现"。
#include "audio/write_attrib.h"
#include "audio/phys_format.h"   // 设备物理格式选择判据（真 bit-perfect 的前提）
#include "platform/macos/pcm_format_validation.h"
#include "platform/macos/airplay_policy.h"
#include "platform/macos/dop_silence_fill.h"   // 1.1.2 P0-3：欠载时的合法 DoP 静音帧

namespace rta::platform {
namespace detail {

// CFString -> std::string（UTF-8）
inline std::string cfstr_to_utf8(CFStringRef s) {
    if (!s) return "";
    const CFIndex len = ::CFStringGetLength(s);
    const CFIndex max = ::CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
    std::string out((size_t)max, '\0');
    if (!::CFStringGetCString(s, out.data(), max, kCFStringEncodingUTF8)) return "";
    out.resize(std::strlen(out.c_str()));
    return out;
}

// AudioObjectID -> 显示名
inline std::string device_name(AudioDeviceID dev) {
    CFStringRef name = nullptr;
    UInt32 size = sizeof(name);
    AudioObjectPropertyAddress addr{kAudioObjectPropertyName,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &name) != noErr || !name)
        return "";
    std::string s = cfstr_to_utf8(name);
    ::CFRelease(name);
    return s;
}

// 设备的输出流数量（0 = 不是输出设备）
inline UInt32 output_stream_count(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreams,
                                    kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &size) != noErr) return 0;
    return size / sizeof(AudioStreamID);
}

// 设备的可用采样率列表
inline std::vector<uint32_t> device_rates(AudioDeviceID dev) {
    std::vector<uint32_t> out;
    AudioObjectPropertyAddress addr{kAudioDevicePropertyAvailableNominalSampleRates,
                                    kAudioObjectPropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &size) != noErr) return out;
    const size_t n = size / sizeof(AudioValueRange);
    std::vector<AudioValueRange> ranges(n);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, ranges.data()) != noErr)
        return out;
    // 范围可能很宽（如 1..960000），这里只挑出本项目关心的标准采样率
    static const uint32_t kStd[] = {44100, 48000, 88200, 96000, 176400, 192000,
                                    352800, 384000, 705600, 768000};
    for (uint32_t r : kStd) {
        for (const auto& rg : ranges) {
            if ((double)r >= rg.mMinimum && (double)r <= rg.mMaximum) { out.push_back(r); break; }
        }
    }
    return out;
}

// 设备输出侧支持的最大声道数
inline int device_max_channels(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreamConfiguration,
                                    kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &size) != noErr) return 0;
    std::vector<char> buf(size);
    auto* list = reinterpret_cast<AudioBufferList*>(buf.data());
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, list) != noErr) return 0;
    int ch = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; ++i) ch += (int)list->mBuffers[i].mNumberChannels;
    return ch;
}

// 设备当前虚拟混音格式位深（kAudioDevicePropertyStreamFormat 对应 HAL 混音层/虚拟格式，
// 非底层物理硬件流的物理格式 kAudioStreamPropertyPhysicalFormat；在此如实说明层级）
inline int device_bit_depth(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreamFormat,
                                    kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription asbd{};
    UInt32 size = sizeof(asbd);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &asbd) != noErr) return 0;
    return (int)asbd.mBitsPerChannel;
}

// ---------------- 1.1.2 传输类型、延迟与生命周期属性读取 ----------------

// 读取设备的 TransportType FourCC（kAudioDevicePropertyTransportType）
inline uint32_t device_transport_type(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyTransportType,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 type = 0;
    UInt32 size = sizeof(type);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &type) != noErr) return 0;
    return type;
}

// 读取设备当前 nominal 采样率（kAudioDevicePropertyNominalSampleRate）
inline uint32_t device_current_rate(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyNominalSampleRate,
                                    kAudioObjectPropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    Float64 rate = 0.0;
    UInt32 size = sizeof(rate);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &rate) != noErr) return 0;
    return (uint32_t)std::llround(rate);
}

// 读取设备当前缓冲大小（kAudioDevicePropertyBufferFrameSize）
inline size_t device_current_buffer_frames(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyBufferFrameSize,
                                    kAudioObjectPropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    UInt32 frames = 0;
    UInt32 size = sizeof(frames);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &frames) != noErr) return 0;
    return (size_t)frames;
}

// 读取输出流的延迟帧数（kAudioStreamPropertyLatency）
inline bool stream_output_latency(AudioStreamID stream, UInt32& outLatency) {
    AudioObjectPropertyAddress addr{kAudioStreamPropertyLatency,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 lat = 0;
    UInt32 size = sizeof(lat);
    if (::AudioObjectGetPropertyData(stream, &addr, 0, nullptr, &size, &lat) != noErr) return false;
    outLatency = lat;
    return true;
}

// 读取设备输出流列表并汇总首个输出流或所有输出流的延迟（通常取第一个输出流流延迟）
inline bool device_output_stream_latency(AudioDeviceID dev, UInt32& outStreamLatency) {
    outStreamLatency = 0;
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreams,
                                    kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &size) != noErr || size == 0) return false;
    const size_t count = size / sizeof(AudioStreamID);
    std::vector<AudioStreamID> streams(count);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, streams.data()) != noErr) return false;
    for (AudioStreamID s : streams) {
        UInt32 lat = 0;
        if (stream_output_latency(s, lat)) {
            outStreamLatency = lat;
            return true;
        }
    }
    return false;
}

// 读取可读延迟信息并构建 DeviceCaps 中的延迟字段（AP-1.2）
inline void probe_device_latency(AudioDeviceID dev, double sampleRate,
                                 bool& outKnown, double& outLatencyMs, std::string& outSource) {
    outKnown = false;
    outLatencyMs = 0.0;
    outSource = "none";

    UInt32 devLat = 0;
    AudioObjectPropertyAddress addrDev{kAudioDevicePropertyLatency,
                                       kAudioDevicePropertyScopeOutput,
                                       kAudioObjectPropertyElementMain};
    UInt32 szDev = sizeof(devLat);
    bool hasDev = (::AudioObjectGetPropertyData(dev, &addrDev, 0, nullptr, &szDev, &devLat) == noErr);

    UInt32 safety = 0;
    AudioObjectPropertyAddress addrSafety{kAudioDevicePropertySafetyOffset,
                                          kAudioDevicePropertyScopeOutput,
                                          kAudioObjectPropertyElementMain};
    UInt32 szSafety = sizeof(safety);
    bool hasSafety = (::AudioObjectGetPropertyData(dev, &addrSafety, 0, nullptr, &szSafety, &safety) == noErr);

    UInt32 streamLat = 0;
    bool hasStream = device_output_stream_latency(dev, streamLat);

    outKnown = macos::compute_device_latency(devLat, safety, streamLat, sampleRate,
                                            hasDev, hasSafety, hasStream,
                                            outLatencyMs, outSource);
}

// 检查设备是否在线就绪（kAudioDevicePropertyDeviceIsAlive）
inline bool is_device_alive(AudioDeviceID dev) {
    if (dev == kAudioObjectUnknown) return false;
    AudioObjectPropertyAddress addr{kAudioDevicePropertyDeviceIsAlive,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 alive = 0;
    UInt32 size = sizeof(alive);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &alive) != noErr) return false;
    const UInt32 streams = output_stream_count(dev);
    return macos::check_endpoint_alive(alive, streams);
}

// ---------------- 设备硬件音量（2026-10-25 用户报「接管之后音量被锁死」）----------------
//
// 问题现象：独占模式接管设备后，**最高音量 = 接管前系统设置的那个值**，而且改不了。
//
// 根因（实测确认）：本项目**从未读写过设备硬件音量**（全仓 grep 零命中）。
//   * 独占(Hog)模式下系统音量 UI 被挡住，用户改不了；
//   * 而设备的硬件音量标量停留在接管那一刻的旧值（本机实测 0.152，即 -16 dB 左右）；
//   * 播放器只做**软件增益**（在旧硬件音量之上再乘）⟹ 天花板就是那个陈旧值。
//
// 设计选择（用户明确要求「要接管设备就全接管，要用系统的音量级别」）：
//   接管时把设备硬件音量**置满 (1.0)**，并解除静音，然后**全部**用软件增益控制。
//   这样：① 软件增益 0 dB 就是设备满幅（真正的 bit-perfect 前提）；
//        ② 用户拉音量条能到 100%，不再被旧值卡住；
//        ③ 退出/关闭时**恢复**接管前的硬件音量，不污染用户的系统设置。
//   为什么不用硬件音量来做音量控制：每次调音量都要发 CoreAudio 属性写，
//   实时拖动会有延迟与爆音风险；软件增益在写环时做，零延迟且可精确到样本。
//   代价：软件增益 < 0 dB 时不再是 bit-perfect —— 这是音频工程共识，UI 已如实标注。
struct HwVolumeState {
    bool      saved = false;      // 是否保存过原值（有原值才恢复）
    Float32   scalar = 1.0f;      // 原音量标量
    bool      muteSaved = false;
    Boolean   mute = false;
    // 2026-10-25（用户安全要求）：接管时把「原硬件音量」换算成等效 dB，
    // 作为软件增益的**初始值**，保证接管瞬间响度不变（不会突然满幅）。
    // scalar→dB 用 20*log10；scalar==0 视为静音（-120 dB）。
    double    equivalentDb = 0.0;
    bool      valid = false;      // 是否成功读到了原值（否则不做响度保持）
};

inline bool hw_volume_supported(AudioDeviceID dev) {
    AudioObjectPropertyAddress a{kAudioDevicePropertyVolumeScalar,
                                 kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    return ::AudioObjectHasProperty(dev, &a) != 0;
}

inline bool hw_volume_get(AudioDeviceID dev, Float32& out) {
    AudioObjectPropertyAddress a{kAudioDevicePropertyVolumeScalar,
                                 kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &a)) return false;
    UInt32 sz = sizeof(out);
    return ::AudioObjectGetPropertyData(dev, &a, 0, nullptr, &sz, &out) == noErr;
}

inline bool hw_volume_set(AudioDeviceID dev, Float32 v) {
    AudioObjectPropertyAddress a{kAudioDevicePropertyVolumeScalar,
                                 kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &a)) return false;
    Boolean settable = false;
    if (::AudioObjectIsPropertySettable(dev, &a, &settable) != noErr || !settable) return false;
    return ::AudioObjectSetPropertyData(dev, &a, 0, nullptr, sizeof(v), &v) == noErr;
}

inline bool hw_mute_get(AudioDeviceID dev, Boolean& out) {
    AudioObjectPropertyAddress a{kAudioDevicePropertyMute,
                                 kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &a)) return false;
    UInt32 sz = sizeof(out);
    return ::AudioObjectGetPropertyData(dev, &a, 0, nullptr, &sz, &out) == noErr;
}

inline bool hw_mute_set(AudioDeviceID dev, Boolean m) {
    AudioObjectPropertyAddress a{kAudioDevicePropertyMute,
                                 kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &a)) return false;
    Boolean settable = false;
    if (::AudioObjectIsPropertySettable(dev, &a, &settable) != noErr || !settable) return false;
    return ::AudioObjectSetPropertyData(dev, &a, 0, nullptr, sizeof(m), &m) == noErr;
}

// 接管：存原值 → 硬件音量置满 → 解除静音。返回 false 表示设备不支持（不致命）。
//
// ⚠️ 安全要求（用户 2026-10-25 明确）：「接管的情况下，默认音量要与之前系统设置的音量相同，
//    防止音量过大」。所以这里必须把原硬件音量换算成等效 dB 交给调用方，由它把软件增益
//    初始化到同一个响度 —— **绝不能**硬件置满后软件还停在 0 dB（那等于瞬间满幅）。
inline bool hw_volume_takeover(AudioDeviceID dev, HwVolumeState& st) {
    st = HwVolumeState{};
    if (!hw_volume_supported(dev)) return false;
    Float32 cur = 1.0f;
    if (hw_volume_get(dev, cur)) {
        st.saved = true;
        st.scalar = cur;
        st.valid = true;
        // scalar → dB：0 → 静音；否则 20*log10。夹在 [-120, 0]（硬件音量不会 > 0 dB）。
        if (cur <= 0.000001f) st.equivalentDb = -120.0;
        else {
            double db = 20.0 * std::log10((double)cur);
            if (db > 0.0) db = 0.0;
            if (db < -120.0) db = -120.0;
            st.equivalentDb = db;
        }
    }
    Boolean m = 0;
    if (hw_mute_get(dev, m)) { st.muteSaved = true; st.mute = m; }
    // 置满并解除静音：之后音量完全由软件增益控制
    const bool okVol = hw_volume_set(dev, 1.0f);
    if (st.muteSaved && st.mute) hw_mute_set(dev, 0);
    return okVol;
}

// 归还：把接管前的硬件音量/静音写回去（幂等；失败不抛）
//
// ⚠️ 2026-10-25：**当前已不使用**。用户要求「独占时让系统调节音量」，
// 所以本播放器不再接管硬件音量（open 的 2b 注释），也就不需要归还。
// 函数保留是给将来可能的选择性接管用，并在 test_hw_volume 里仍有覆盖。
inline void hw_volume_restore(AudioDeviceID dev, const HwVolumeState& st) {
    if (!st.saved) return;
    hw_volume_set(dev, st.scalar);
    if (st.muteSaved) hw_mute_set(dev, st.mute);
}

// ---------------- 设备物理格式（硬件真正跑的那一层）----------------
// 为什么必须区分两层（2026-11-09，用户质问「HQPlayer 能 bit-perfect」）：
//   kAudioDevicePropertyStreamFormat   = HAL 虚拟/混音层（我们此前只写这一层）
//   kAudioStreamPropertyPhysicalFormat = 硬件流的物理格式（真正决定 DAC 吃什么）
// 只设虚拟层时，物理层若不同，HAL 会在中间做采样率转换或 int→float32 ——
// 位流已被改动，但代码从不读物理层，所以 bit_perfect() 照样报 true。
// 本机实测（只读探针，未播放任何声音）：
//   Pocket Master (USB)  物理层只有 44100/16 整数
//   M140F2 (DisplayPort) 物理层 21 档，全为整数 24/20
//   Mac mini 扬声器       物理层只有 float32（物理上不可能整数直通）
//   Oray 虚拟设备         物理层只有 float32（同上）
// 四台设备的物理层 settable 全为 YES ⟹ 锁定这条路是通的，只是此前没走。
inline AudioStreamID first_output_stream(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreams,
                                    kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &size) != noErr ||
        size < sizeof(AudioStreamID)) return kAudioObjectUnknown;
    AudioStreamID sid = kAudioObjectUnknown;
    UInt32 n = sizeof(sid);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &n, &sid) != noErr) return kAudioObjectUnknown;
    return sid;
}

// 读设备当前物理格式
inline bool get_physical_format(AudioStreamID sid, AudioStreamBasicDescription& out) {
    if (sid == kAudioObjectUnknown) return false;
    AudioObjectPropertyAddress addr{kAudioStreamPropertyPhysicalFormat,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(out);
    std::memset(&out, 0, sizeof(out));
    return ::AudioObjectGetPropertyData(sid, &addr, 0, nullptr, &size, &out) == noErr;
}

// 写设备物理格式（真正锁硬件）。失败说明该格式不被硬件接受。
inline bool set_physical_format(AudioStreamID sid, const AudioStreamBasicDescription& asbd) {
    if (sid == kAudioObjectUnknown) return false;
    AudioObjectPropertyAddress addr{kAudioStreamPropertyPhysicalFormat,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    return ::AudioObjectSetPropertyData(sid, &addr, 0, nullptr, sizeof(asbd), &asbd) == noErr;
}

// 枚举设备物理层支持的格式（供 pick_physical_format 决策）
inline std::vector<rta::audio::PhysFormat> available_physical_formats(AudioStreamID sid) {
    std::vector<rta::audio::PhysFormat> out;
    if (sid == kAudioObjectUnknown) return out;
    AudioObjectPropertyAddress addr{kAudioStreamPropertyAvailablePhysicalFormats,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(sid, &addr, 0, nullptr, &size) != noErr || size == 0) return out;
    std::vector<AudioStreamRangedDescription> list(size / sizeof(AudioStreamRangedDescription));
    UInt32 got = size;
    if (::AudioObjectGetPropertyData(sid, &addr, 0, nullptr, &got, list.data()) != noErr) return out;
    const size_t n = got / sizeof(AudioStreamRangedDescription);
    for (size_t i = 0; i < n; ++i) {
        const AudioStreamBasicDescription& f = list[i].mFormat;
        if (f.mFormatID != kAudioFormatLinearPCM) continue;
        rta::audio::PhysFormat p;
        p.rate = (uint32_t)std::llround(f.mSampleRate);
        p.bits = (int)f.mBitsPerChannel;
        p.isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        out.push_back(p);
    }
    return out;
}

// 其它进程是否正在使用该设备（kAudioDevicePropertyDeviceIsRunningSomewhere）
// Hog Mode 在 macOS 上**不能**阻止其它进程播放（PLATFORM.md 13.10.5 实测：
// 独占期间第三进程 IOProc 照常运行、成功抓录 1.5 秒）。所以真独占必须显式检测，
// 不能把 Hog 的登记归属当成保证。
inline bool device_running_somewhere(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyDeviceIsRunningSomewhere,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 v = 0;
    UInt32 size = sizeof(v);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &v) != noErr) return false;
    return v != 0;
}

// 把 pick 结果转成 ASBD（交错整数 + packed）
inline AudioStreamBasicDescription make_int_asbd(uint32_t rate, int bits, int channels) {
    AudioStreamBasicDescription a{};
    a.mSampleRate = (Float64)rate;
    a.mFormatID = kAudioFormatLinearPCM;
    a.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    a.mBytesPerPacket = (UInt32)(bits / 8) * (UInt32)channels;
    a.mFramesPerPacket = 1;
    a.mBytesPerFrame  = (UInt32)(bits / 8) * (UInt32)channels;
    a.mChannelsPerFrame = (UInt32)channels;
    a.mBitsPerChannel = (UInt32)bits;
    return a;
}

// 读取设备当前 StreamFormat（虚拟/混音层 ASBD）
inline bool get_device_stream_format(AudioDeviceID dev, AudioStreamBasicDescription& outAsbd) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreamFormat,
                                    kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(outAsbd);
    std::memset(&outAsbd, 0, sizeof(outAsbd));
    return ::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &outAsbd) == noErr;
}

// 设置设备流格式（虚拟/混音格式，独占模式下向驱动申请源格式）。失败说明该格式不被接受。
inline bool set_device_format(AudioDeviceID dev, uint32_t rate, int bits, int channels) {
    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = (Float64)rate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    // 交错整数 + packed（packed 才能让 24-bit 真的按 3 字节存）
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = (UInt32)(bits / 8) * (UInt32)channels;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = (UInt32)(bits / 8) * (UInt32)channels;
    asbd.mChannelsPerFrame = (UInt32)channels;
    asbd.mBitsPerChannel = (UInt32)bits;

    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreamFormat,
                                    kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    return ::AudioObjectSetPropertyData(dev, &addr, 0, nullptr, sizeof(asbd), &asbd) == noErr;
}

// Hog Mode 的读写语义（2026-10-25 实测确认，**原实现写反了**）
//
// 这个属性的 set 值**不是"要设成谁"，而是"本进程是否继续持有"**：
//   写 0        → 请求独占；内核成功后把**真实持有者 pid 回填**进这个属性
//                 （实测：写 0 之后读到 owner == 我自己的 pid）
//   写 getpid() → 释放独占（实测：写自己的 pid 之后读到 owner == -1）
//
// 原实现是 `pid_t pid = on ? getpid() : 0;` —— 正好反了：
//   set_hog_mode(dev, true)  实际在**释放**，
//   set_hog_mode(dev, false) 实际在**抢**。
// 后果：①「独占」从来没真正生效过（所以系统音量其实一直可用，只是别处有问题）；
//       ② close 时的"释放"反而去抢独占，导致退出后设备被本进程残留占用 ——
//          用户看到的就是「系统音量调不了」。
// 实测证据（/tmp/hogfinal）：
//   写 0        → owner=67584(me)  → 系统音量被阻断 ✅ 真独占
//   写 getpid() → owner=-1         → 系统音量恢复   ✅ 真释放
inline bool set_hog_mode(AudioDeviceID dev, bool on) {
    // on=true → 写 0（请求独占）；on=false → 写 getpid()（释放）
    pid_t val = on ? 0 : ::getpid();
    AudioObjectPropertyAddress addr{kAudioDevicePropertyHogMode,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &addr)) return false;
    const OSStatus st = ::AudioObjectSetPropertyData(dev, &addr, 0, nullptr, sizeof(val), &val);
    return st == noErr;
}

inline bool is_hogged_by_us(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyHogMode,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &addr)) return false;
    pid_t owner = -1;
    UInt32 size = sizeof(owner);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &owner) != noErr) return false;
    return owner == ::getpid();
}

// 读取当前占用 Hog 的进程 PID（-1 表示无占用或无法读取）
inline pid_t get_hog_owner(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyHogMode,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &addr)) return -1;
    pid_t owner = -1;
    UInt32 size = sizeof(owner);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &owner) != noErr) return -1;
    return owner;
}

// 该设备是否支持 Hog Mode（= 能否做"独占"）。
// 判据：属性存在 + 当前没有被别的进程占着。注意：这【不】会去抢独占，
// 只做只读探测 —— 铁律 2/1 都要求"先只读检查"。
inline bool hog_mode_supported(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyHogMode,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &addr)) return false;
    pid_t owner = -1;
    UInt32 size = sizeof(owner);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &owner) != noErr) return false;
    return owner == -1 || owner == ::getpid();   // -1 = 无人占用
}

// 采样率是否在列表里（caps() 内部用；audio_out.h 的 detail::has_rate 在另一个命名空间层级）
inline bool has_rate_in(const std::vector<uint32_t>& v, uint32_t r) {
    for (uint32_t x : v) if (x == r) return true;
    return false;
}

// ---------------------------------------------------------------------------
// DoP 载波推导（纯能力逻辑：只读设备报出的 rates，不打开设备、不碰音频输出）
//
// DoP 把 1 bit DSD 塞进 16 bit PCM 容器 ⟹ 承载率 = DSD 位率 / 16：
//   44.1k 族 DSD64/128/256/512 → 176400 / 352800 / 705600 / 1411200
//   48k   族 DSD64/128/256/512 → 192000 / 384000 / 768000 / 1536000
//
// 判据（#8 的验收要求「无对应采样率族不能虚报支持」）：
//   · 设备 rates 里必须有**某个族**的载波率，否则 carrier=0 ⟹ 不能声称支持 DoP。
//     只有 44100/48000/96000 的设备一个载波都没有，必须报「不支持」而不是 176400。
//   · 取**最高档**：支持 705600 的设备报 705600，不是写死 176400。
//   · 同档位两族都在（如 352800 与 384000）时报数值更大者；两个载波都真实存在，
//     报大的不构成虚报。
//
// ⚠️ 这张表必须与 src/engine/preset_profiles.h 的 preset_dop_max_from_rates() 一致：
// 平台层 DeviceCaps.dopCarrierRate 与引擎侧 preset caps.dopMax 是两份能力模型，
// 历史上已漂移过一次（此处写死 176400，引擎侧按 rates 算出 705600）。
// tests/test_coreaudio.cpp 的 [1b] 段有一条**跨模型一致性**断言锁住两者；
// 改这里必须同时看 src/engine/preset_profiles.h:192。
struct DopCarrier {
    uint32_t carrier = 0;   // DoP 承载的 PCM 采样率（Hz）；0 = 无可用载波
    int level = 0;          // 对应 DSD 档位（64/128/256/512）；0 = 无
};

inline DopCarrier dop_carrier_from_rates(const std::vector<uint32_t>& rates) {
    DopCarrier best;
    for (uint32_t r : rates) {
        if (r == 0) continue;
        for (int m : {64, 128, 256, 512}) {
            const uint32_t c441 = (uint32_t)(44100 * m) / 16u;
            const uint32_t c48  = (uint32_t)(48000 * m) / 16u;
            if (r != c441 && r != c48) continue;
            if (m > best.level || (m == best.level && r > best.carrier)) {
                best.level = m;
                best.carrier = r;
            }
        }
    }
    return best;
}

// 默认输出设备
inline AudioDeviceID default_output_device() {
    AudioObjectPropertyAddress addr{kAudioHardwarePropertyDefaultOutputDevice,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, &dev) != noErr)
        return kAudioObjectUnknown;
    return dev;
}

// 实时音量定点缩放辅助函数（暴露给测试做量化核对，见 CoreAudioOutput::scale_sample_i32）
// 管线输入 s 为低位对齐到 bits 位的有符号整数：
//   bits=16: [-32768, 32767]
//   bits=24: [-8388608, 8388607]
//   bits=32: [INT32_MIN, INT32_MAX]
// g == 1.0 时逐位不变（100% bit-perfect 保证）；
// g <= 0.0 时直接返回 0（真静音）；
// 其余按 bits 限幅并四舍五入。
inline int32_t scale_sample_i32(int32_t s, int bits, double g) {
    if (g == 1.0) return s;
    if (g <= 0.0) return 0;
    const double v = (double)s * g;
    const double lim_pos = (bits >= 32) ? 2147483647.0 : (double)((1LL << (bits - 1)) - 1);
    const double lim_neg = (bits >= 32) ? -2147483648.0 : (double)(-(1LL << (bits - 1)));
    if (v > lim_pos) return (int32_t)lim_pos;
    if (v < lim_neg) return (int32_t)lim_neg;
    return (int32_t)std::llround(v);
}

// 容器解包辅助函数（用于验证打包进 AudioBuffer 的字节流）：
// 从小端整型容器还原为 int32_t（低位对齐到 bits）
inline int32_t unpack_sample_i32(const uint8_t* p, int bits) {
    if (!p) return 0;
    if (bits == 16) {
        int16_t v;
        std::memcpy(&v, p, 2);
        return (int32_t)v;
    }
    if (bits == 24) {
        uint32_t u = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16);
        if (u & 0x800000u) u |= 0xFF000000u; // 符号扩展
        return (int32_t)u;
    }
    if (bits == 32) {
        int32_t v;
        std::memcpy(&v, p, 4);
        return v;
    }
    return 0;
}

// 模拟 render() 中的打包逻辑（单样本）
inline void pack_sample_i32(uint8_t* dst, int32_t s, int bits) {
    if (bits == 16) {
        const uint16_t v = (uint16_t)(s & 0xFFFF);
        std::memcpy(dst, &v, 2);
    } else if (bits == 24) {
        const uint32_t v = (uint32_t)s & 0xFFFFFFu;
        dst[0] = (uint8_t)(v & 0xFF);
        dst[1] = (uint8_t)((v >> 8) & 0xFF);
        dst[2] = (uint8_t)((v >> 16) & 0xFF);
    } else {
        std::memcpy(dst, &s, 4);
    }
}
} // namespace detail

class CoreAudioOutput final : public AudioOutput {
public:
    CoreAudioOutput() = default;
    ~CoreAudioOutput() override { close(); }

    // ---------------- 能力查询 ----------------
    DeviceCaps caps(const std::string& deviceId) override {
        DeviceCaps c;
        const AudioDeviceID dev = resolve_device(deviceId);
        if (dev == kAudioObjectUnknown) return c;

        c.rates = detail::device_rates(dev);
        c.maxChannels = detail::device_max_channels(dev);
        if (c.maxChannels <= 0) c.maxChannels = 2;

        // 位深：CoreAudio 的设备物理格式位深可设，但"能设哪些"要实际试。
        // 这里用保守规则：macOS 全系列支持 16/24/32 整数输出（CoreAudio 内部按 float32
        // 处理，HAL 负责转成设备位深）；如实标注为"可请求"而非"已实测"。
        c.bitDepths = {16, 24, 32};

        // 独占模式：AUHAL + Hog Mode 可用即认为支持（等价 WASAPI 独占）
        c.exclusiveMode = detail::hog_mode_supported(dev);
        // bit-perfect 前提：独占 + 不插入任何转换。AUHAL 直连设备时成立。
        c.bitPerfectCapable = c.exclusiveMode;

        // DoP：按设备**真实** rates 选最高载波（#8）。
        // 旧实现写死「有 176400 就报 176400」，设备支持 352800/705600 时被误判成只能 DSD64，
        // 且紧跟的 `c.dsd = (c.dsd==DoP)?DoP:None;` 是恒等赋值（把「支持」永久钉死）。
        // 现在：没有任何族的载波就保持 None/0 —— 不虚报。
        const detail::DopCarrier dop = detail::dop_carrier_from_rates(c.rates);
        if (dop.carrier != 0) {
            c.dsd = DsdTransport::DoP;
            c.dopCarrierRate = dop.carrier;
        }
        // Native DSD：macOS 无通用用户态 API（见文件头"未解决项"）
        c.nativeDsdRate = 0;

        // 缓冲范围：HAL 默认 IO 缓冲 512 帧可调；按设备采样率折算成毫秒
        const uint32_t base = c.rates.empty() ? 48000u : c.rates.front();
        c.minPeriodFrames = 32;
        c.minBufferMs = 32.0 * 1000.0 / (double)base;
        c.maxBufferMs = 4096.0 * 1000.0 / (double)base;

        // 1.1.2 传输类型、延迟与硬件当前格式（AP-1.1 ~ AP-1.4）
        c.transportType = detail::device_transport_type(dev);
        c.transport = macos::transport_type_to_string(c.transportType);
        c.currentRate = detail::device_current_rate(dev);
        c.currentChannels = detail::device_max_channels(dev);
        c.currentBufferFrames = detail::device_current_buffer_frames(dev);

        const double sampleRateForLatency = (c.currentRate > 0) ? (double)c.currentRate : (double)base;
        detail::probe_device_latency(dev, sampleRateForLatency, c.latencyKnown, c.latencyMs, c.latencySource);

        // 统一应用 AirPlay 能力收敛策略（AP-1.2, AP-1.3, AP-1.4）：
        // 若 transportType 为 'airp'，强制 sharedOnly=true、exclusive=false、bitPerfectCapable=false、dsd=None
        macos::sanitize_airplay_caps(c);

        return c;
    }

    // ---------------- 结构化格式探测（HF-01/02 地基，2026-10-25 从 WasapiOutput 移植）----------------
    // 原 WasapiOutput::probe_formats 返回 FormatProbe：按 16/24/32-bit 分别列出该位深下
    // 独占支持的采样率，外加端点是否存活与友好名。这是**用户可见能力**——
    // 设置页的能力提示、开流失败时的 supportedList 都读它，所以平台换了也要有。
    // macOS 等价物：caps() 已经拿到了 rates 与 bitDepths（CoreAudio 对 16/24/32 都报可请求），
    // 这里做纯映射，不额外开流、不接管设备（与原实现同为只读探测）。
    static rta::audio::FormatProbe probe_formats(const std::string& deviceId) {
        rta::audio::FormatProbe p;
        p.deviceId = deviceId;
        CoreAudioOutput probe;          // 仅用于调 caps()；构造不打开设备
        const DeviceCaps c = probe.caps(deviceId);
        // 端点存活：caps 能拿到采样率列表即说明设备在（resolve_device 失败会返回空 caps）
        p.endpointAlive = !c.rates.empty();
        if (!p.endpointAlive) return p;  // 端点不在：如实返回空，与原实现一致
        // 友好名
        const AudioDeviceID dev = resolve_device(deviceId);
        if (dev != kAudioObjectUnknown) p.friendlyName = detail::device_name(dev);
        // 位深 → 采样率列表：CoreAudio 侧 16/24/32 共享同一套硬件采样率
        // （HAL 负责把 int32 重打包成设备物理位深），所以三者同源。
        // ⚠️ 如实标注：这是「可请求」而非「已逐位实测」——与 caps() 的既有口径一致。
        for (int bd : c.bitDepths) {
            if (bd == 16) p.rates16 = c.rates;
            else if (bd == 24) p.rates24 = c.rates;
            else if (bd == 32) p.rates32 = c.rates;
        }
        return p;
    }

    // ---------------- 开流 ----------------
    bool open(const OpenSpec& spec) override {
        std::lock_guard<std::mutex> lk(mu_);
        close_locked();
        clear_error();

        if (spec.rate == 0 || spec.bits == 0 || spec.channels <= 0) {
            fail(OutputError::UnsupportedFormat, "开流参数非法：rate/bits/channels 不能为 0");
            return false;
        }
        device_ = resolve_device(spec.deviceId);
        if (device_ == kAudioObjectUnknown) {
            fail(OutputError::DeviceNotFound, "找不到输出设备（deviceId=\"" + spec.deviceId + "\"）");
            return false;
        }

        // 1.1.2 实际设备再确认与防护（AP-1.3, AP-1.4）：
        // 读取设备实际能力（含 transportType 与 currentRate），执行开流策略校验。
        // ⚠️ 顺序很重要：先把 AirPlay 的请求**规范化**成共享输出，再走校验。
        //   AP-1.3 要的是"共享输出、不申请 Hog"，不是"拒绝开流"：用户把设备选成
        //   AirPlay、而后端仍是默认独占时，必须自动落到共享路径，而不是报一个他无法
        //   理解的 UnsupportedFormat。下面的 validate 保留为纵深防御（断言）。
        const DeviceCaps actualDevCaps = caps(spec.deviceId);
        const bool isAirPlay = macos::is_airplay_transport(actualDevCaps.transportType) || actualDevCaps.sharedOnly;

        OpenSpec effective = spec;
        if (isAirPlay) {
            effective.shared = true;
            effective.exclusive = false;   // AirPlay 永不抢 Hog
        }

        std::string policyErrZh, policyErrEn;
        if (!macos::validate_open_spec(actualDevCaps, effective, policyErrZh, policyErrEn)) {
            close_locked();
            fail(OutputError::UnsupportedFormat, policyErrZh, policyErrEn);
            return false;
        }

        rate_ = effective.rate;
        bits_ = effective.bits;
        channels_ = effective.channels;
        buffer_ms_ = effective.bufferMs;
        // AirPlay 强制 shared=true、禁止 Hog
        shared_ = isAirPlay ? true : effective.shared;
        // DoP 走的是"必须独占"的路径：共享/规范化后若仍带 dop，平台的
        // validate_open_spec 已经拒绝；这里把标记存下来供自证与诊断使用。
        dop_requested_.store(effective.dop, std::memory_order_relaxed);

        // ---- 1.1.2 DoP 客户端的容器门槛（任务要求：只拒"真的不够"）----
        // DoP 把 16 位 DSD + 8 位标记拼进**一个 24-bit 字**，本实现的打包也只产出 3 字节/样本
        // （见 dop_silence_fill.h::dop_write_period_24le）。所以客户端位深必须是 24：
        // 16 位装不下 24 个有效位；32 位则要求把标记搬到 bit24..31，那是另一种打包，
        // 本实现不产出 —— 两种情况都必须在动硬件之前明确拒绝，而不是让 DAC 收到错位数据。
        // 注意：这里只管**客户端**位深；设备侧容器是 Float32 / 24-in-32 都允许（见下方门槛）。
        if (effective.dop && bits_ != 24) {
            close_locked();
            fail(OutputError::UnsupportedFormat,
                 "DoP 只支持 24-bit 容器（当前请求 " + std::to_string(bits_) +
                     "-bit）：DoP 的标记就在 24-bit 字的高 8 位，位深不对时载波无法成立",
                 "DoP requires a 24-bit container (requested " + std::to_string(bits_) +
                     "-bit): DoP markers live in the top 8 bits of the 24-bit word.");
            return false;
        }
        if (effective.dop && shared_) {
            // 冗余闸：validate_open_spec 已挡过一遍。这里再挡一次是因为 `shared_` 还受
            // AirPlay 规范化影响，两条路径必须都落到"明确拒绝"，绝不能偷偷共享输出。
            close_locked();
            fail(OutputError::UnsupportedFormat,
                 "拒绝在共享输出（经系统混音）下发送 DoP：混音/重采样会破坏 DoP 标记",
                 "Refused DoP on shared output: the system mixer would corrupt DoP markers.");
            return false;
        }

        // 1) Hog Mode（严格独占）—— 由 OpenSpec::exclusive 独立控制。
        //    用户拍板：严格 Hog 请求（spec.exclusive && !shared）抢占失败必须在改格式前明确拒绝，
        //    不静默降级，不假冒格式不支持（UnsupportedFormat），必须返回 DeviceBusy 并提示真正 owner PID。
        hog_requested_ = (effective.exclusive && !shared_);
        hogged_ = false;
        if (hog_requested_) {
            hogged_ = detail::set_hog_mode(device_, true) && detail::is_hogged_by_us(device_);
            if (!hogged_) {
                const pid_t owner = detail::get_hog_owner(device_);
                const std::string ownerStr = (owner > 0) ? std::to_string(owner) : "unknown";
                close_locked();
                hog_requested_ = true;
                hogged_ = false;
                fail(OutputError::DeviceBusy,
                     "独占模式（Hog Mode）申请被拒绝：输出设备当前被其它程序（PID: " + ownerStr + "）占用，请关闭占用该设备的程序，或改用共享模式",
                     "Exclusive mode (Hog Mode) request denied: audio device is occupied by another process (PID: " + ownerStr + "). Please close the occupying process or switch to shared mode in Settings.");
                return false;
            }
        }

        // 2) 按源格式设置设备物理格式 —— 这是 bit-perfect 的关键。
        //    共享模式跳过设置设备格式（物理格式归系统/其他客户端管），但必须真实读回
        //    当前生效的虚拟/混音格式，说明 client vs device 的区别。
        //    独占模式：先尝试设置设备格式，设完之后真实读回 ASBD 校验！
        //    若不提供正确 repack 则必须拒绝 client requiresRepack！绝不假称已直接打包！
        //    fallback 描述为 HAL/AUHAL 设备转换，而非内存打包。
        devicePacking_ = macos::ContainerPacking::Packed16;
        deviceEffectiveBits_ = (uint32_t)bits_;
        deviceContainerBits_ = (uint32_t)bits_;
        deviceIsFloat_ = false;
        clientPacking_ = macos::ContainerPacking::Packed16;
        clientBits_ = (uint32_t)bits_;
        formatFallbackNote_.clear();

        if (!shared_) {
            // ---- 2a) 先锁**硬件物理格式**（kAudioStreamPropertyPhysicalFormat）----
            // 2026-11-09：这是「真 bit-perfect」与「看起来 bit-perfect」的分界线。
            // 之前只写虚拟层（下面那段），物理层不受控 ⟹ HAL 在中间做重采样/int→float，
            // 位流已被改动而代码不知道。现在按源格式把物理层也锁到同一档，并真实读回校验。
            //
            // 策略来自纯函数 rta::audio::pick_physical_format（tests/test_phys_format.cpp 钉住）：
            //   · 采样率必须精确相等（绝不重采样）
            //   · 位深优先精确相等，否则补零（数值不变）
            //   · 端点只有 float32 ⟹ 判否（用户明确要求「不能是接近」）
            physStream_ = detail::first_output_stream(device_);
            physLocked_ = false;
            physNote_.clear();
            {
                const auto avail = detail::available_physical_formats(physStream_);
                const auto pk = rta::audio::pick_physical_format(avail, rate_, bits_);
                // ⚠️ 锁不上时**不阻止播放**，只如实降级为"非 bit-perfect"。
                // 理由：锁不上的典型场景是内置扬声器 / 虚拟声卡（物理层只有 float32），
                // 那里根本没插听音 DAC。若在这种端点上直接拒绝播放，等于让笔记本外放
                // 完全不能用 —— 那不是保真，是把程序弄坏。用户要的是"别谎报"，
                // 判据由 physLocked_ 如实传给界面（→ 黄标 + 具体理由）。
                if (!pk.ok) {
                    physNote_ = "物理格式未锁定：" + pk.why;
                    formatFallbackNote_ = physNote_;
                    physDeviceBits_ = bits_;   // 客户端仍按请求位深打包
                } else {
                    const AudioStreamBasicDescription wantAsbd =
                        detail::make_int_asbd(pk.pick.rate, pk.pick.bits, channels_);
                    bool wrote = detail::set_physical_format(physStream_, wantAsbd);
                    AudioStreamBasicDescription got{};
                    const bool readback = wrote && detail::get_physical_format(physStream_, got);
                    if (!readback) {
                        physNote_ = "物理格式锁定失败（SetProperty=" +
                                    std::string(wrote ? "ok" : "fail") + "，读回=" +
                                    std::string(readback ? "ok" : "fail") + "）";
                        formatFallbackNote_ = physNote_;
                        physDeviceBits_ = bits_;
                    } else {
                        const bool rateOk = ((uint32_t)std::llround(got.mSampleRate) == rate_);
                        const bool intOk  = (got.mFormatFlags & kAudioFormatFlagIsFloat) == 0;
                        const int  gotBits = (int)got.mBitsPerChannel;
                        physReadRate_ = (uint32_t)std::llround(got.mSampleRate);
                        physReadBits_ = gotBits;
                        physReadFloat_ = !intOk;
                        // 逐位直通的物理条件：同率 + 整数 + 位深 >= 源位深
                        physLocked_ = rateOk && intOk && gotBits >= bits_;
                        // 容器是否丢源位深的有效位：
                        //   · 物理层是整数且位深 >= 源位深 ⟹ 不丢（补零只是把 0 填进低位）
                        //   · 物理位深 < 源位深 ⟹ 真的丢位（上面的 physLocked_ 已判否，这里双保险）
                        // 注意：HAL 虚拟层静默用 float32 容器**不算**丢位（尾数 24 位），
                        // 但源是 32-bit 整型时 float32 确实装不下 32 位 —— 那条在下面判。
                        containerLossy_ = (gotBits < bits_);
                        if (!physLocked_) {
                            physNote_ = "物理格式读回与请求不符：请求 " + std::to_string(rate_) +
                                        " Hz/" + std::to_string(bits_) + " bit 整数，读回 " +
                                        std::to_string(physReadRate_) + " Hz/" +
                                        std::to_string(physReadBits_) +
                                        (physReadFloat_ ? " bit 浮点" : " bit 整数");
                            formatFallbackNote_ = physNote_;
                            physDeviceBits_ = bits_;
                        } else {
                            // 锁定成功：客户端必须按**物理位深**打包（补零在此发生）
                            physDeviceBits_ = physReadBits_;
                            if (pk.zeroPad) physNote_ = pk.why;   // 补零要如实告知，但不影响物理锁定
                        }
                    }
                }
            }

            if (!detail::set_device_format(device_, rate_, bits_, channels_)) {
                // 回滚 hog
                if (hogged_) { detail::set_hog_mode(device_, false); hogged_ = false; }
                const DeviceCaps c = caps(spec.deviceId);
                std::string supported;
                for (uint32_t r : c.rates) supported += std::to_string(r) + " ";
                fail(OutputError::UnsupportedFormat,
                     "设备不支持 " + std::to_string(rate_) + " Hz / " + std::to_string(bits_) +
                     " bit / " + std::to_string(channels_) + " ch（设备支持采样率: " +
                     (supported.empty() ? std::string("未知") : supported) + "）");
                close_locked();
                return false;
            }

            // 设完后真 GetProperty 读取设备 StreamFormat ASBD，包括 rate, ch, bits, bytes, flags 校验
            AudioStreamBasicDescription devAsbd{};
            if (!detail::get_device_stream_format(device_, devAsbd)) {
                if (hogged_) { detail::set_hog_mode(device_, false); hogged_ = false; }
                fail(OutputError::Internal, "设置格式后无法读回设备实际格式(StreamFormat)");
                close_locked();
                return false;
            }

            // ⚠️ 2026-10-28 真机回归修复（1.1.0-beta2 用户实测「无法播放」）：
            //   这里读回的是 **HAL 设备虚拟/混音格式**（kAudioDevicePropertyStreamFormat），
            //   而 macOS 上它**经常就是 Float32**，与「客户端交给 AUHAL 的内存打包」是两层东西。
            //   AUHAL 本来就负责 client packed ↔ device 格式之间的转换，所以：
            //     * 设备层是 Float32 / 24-in-32 **不是错误**，绝不能因此拒绝开流（1.1.4 从没拒绝过，
            //       本版一度按 requiresRepack 一律拒绝，导致用户所有歌都播不了 —— 已修）；
            //     * 真正必须严格校验的是 **客户端 ASBD**（见下方 AudioUnitGetProperty），
            //       因为那才是我们 render 回调真正写出的字节布局。
            //   设备层格式只做**如实记录**（device_format()/bits_fallback_note()），不参与放行判定。
            auto neg = macos::validate_and_negotiate_format(rate_, bits_, channels_, devAsbd);
            dopDeviceRate_.store((uint32_t)devAsbd.mSampleRate, std::memory_order_relaxed);
            dopExclusiveRateOk_.store(((uint32_t)devAsbd.mSampleRate == rate_),
                                      std::memory_order_relaxed);
            if (neg.accepted) {
                devicePacking_ = neg.acceptedPacking;
                deviceEffectiveBits_ = neg.effectiveBits;
                deviceContainerBits_ = neg.containerBits;
                deviceIsFloat_ = neg.isFloat;
                formatFallbackNote_ = neg.fallbackNote;
                // 第二判据（纵深防御）：HAL 混音容器是 float32 时，只有源位深 <= 24 才无损。
                // CoreAudio 的混音域恒为 float32，这不是"降级"而是架构；但源是 32-bit 整型时
                // 尾数装不下全部 32 位 ⟹ 真的会丢低位。这一条必须判否，否则又成了"接近"。
                if (neg.isFloat && bits_ > 24) {
                    containerLossy_ = true;
                    if (formatFallbackNote_.empty())
                        formatFallbackNote_ = "HAL 混音容器为 float32（尾数 24 位），"
                                              "装不下 " + std::to_string(bits_) + "-bit 源样本";
                }
            } else {
                // 设备层格式认不出来（例如非交错/异常 ASBD）也只记录，不拒绝：AUHAL 仍会做转换。
                devicePacking_ = macos::ContainerPacking::Invalid;
                deviceEffectiveBits_ = (uint32_t)bits_;
                deviceContainerBits_ = (uint32_t)bits_;
                deviceIsFloat_ = false;
                formatFallbackNote_ = "设备层格式无法解析（" + neg.rejectReason +
                                      "）；客户端仍按 packed 输出，由 AUHAL/HAL 转换";
            }

            // ---- 1.1.2 DoP 的真实精度/速率门槛（只拒"真的不够"）----
            //
            // 这里是**独立于 PCM 协商**的判据：PCM 的"位深必须完全匹配否则拒绝"对 DoP 太严
            // （那会把 24-in-32 / Float32 / 32-bit 容器这些**无损**承载全部判死），
            // 而 DoP 真正需要的只有三条：
            //   ① 设备有效精度 ≥ 24 bit：DoP 用 24 个有效位（低 16 位 DSD + 高 8 位标记）。
            //      Packed16(16) 就是"真的不够"，拒绝 —— 这不是保守，是物理上装不下。
            //   ② 设备速率必须**等于**请求载波率：不等就意味着 AUHAL/HAL 在中间做采样率转换，
            //      重采样会插值/滤波，0x05/0xFA 的逐帧交替立刻消失 ⟹ 拒绝。
            //   ③ 声道数必须一致：否则 DoP 帧被摊到不同声道，接收端拿到的位流是错位拼起来的。
            //
            // 明确**不拒**的三类（都能证明无损，拒了就是删功能）：
            //   · Float32（effectiveBits=24）：24-bit 整数样本 |v| ≤ 2^23 在 IEEE-754 float32
            //     的 24 位尾数里可**精确**表示（2^23 以内整数全部可表示，无舍入）⟹ 转换本身
            //     不破坏 DoP。会破坏它的是系统混音/抖动/增益 —— 那些在共享模式与增益闸里挡掉了。
            //   · 24-in-32（effectiveBits=24）：24 位有效数据放进 32 位容器，HAL 在**同一组
            //     24 位有效位**上搬运（左移 8 或右移 8），标记仍落在有效 24 位的最高 8 位，
            //     不会错位成 0x0500（那要求真有 8 位信息丢失，对齐搬运没有）。
            //   · Int32（effectiveBits=32）：24 位字装进 32 位整型容器同样是纯移位，无损。
            // 这三类仍会如实写入 formatFallbackNote_ ⟹ bit_perfect() 报 false（不谎报位完美），
            // 但**不**阻止开流。
            if (effective.dop) {
                const auto devAn = macos::analyze_pcm_asbd(devAsbd);
                if (!devAn.valid) {
                    close_locked();   // close_locked→rollback_device 会归还 Hog，无需重复
                    fail(OutputError::UnsupportedFormat,
                         "DoP 无法确认设备精度：设备读回格式不可解析（" + devAn.description + "）",
                         "DoP cannot verify device precision: unreadable device ASBD (" +
                             devAn.description + ")");
                    return false;
                }
                if (devAn.effectiveBits < 24) {
                    close_locked();
                    fail(OutputError::UnsupportedFormat,
                         "DoP 需要至少 24-bit 有效精度，设备实际只有 " +
                             std::to_string(devAn.effectiveBits) + "-bit（" + devAn.description + "）",
                         "DoP requires >= 24-bit effective precision; the device reports " +
                             std::to_string(devAn.effectiveBits) + "-bit.");
                    return false;
                }
                if (devAn.sampleRate != rate_) {
                    close_locked();
                    fail(OutputError::UnsupportedFormat,
                         "DoP 要求设备运行在请求的载波率 " + std::to_string(rate_) +
                             " Hz，设备实际为 " + std::to_string(devAn.sampleRate) +
                             " Hz（中间做采样率转换会破坏 DoP 标记）",
                         "DoP requires the device to run at the requested carrier rate " +
                             std::to_string(rate_) + " Hz; the device reports " +
                             std::to_string(devAn.sampleRate) + " Hz.");
                    return false;
                }
                if ((int)devAn.channels != channels_) {
                    close_locked();
                    fail(OutputError::UnsupportedFormat,
                         "DoP 要求设备声道数与输出一致：请求 " + std::to_string(channels_) +
                             " ch，设备实际 " + std::to_string(devAn.channels) + " ch",
                         "DoP requires matching channel count: requested " +
                             std::to_string(channels_) + " ch, device reports " +
                             std::to_string(devAn.channels) + " ch.");
                    return false;
                }
            }
        } else {
            // 共享模式：不设设备格式，但必须真实读回 ASBD 说明 client vs device 的区别
            AudioStreamBasicDescription devAsbd{};
            if (detail::get_device_stream_format(device_, devAsbd)) {
                auto devAnalysis = macos::analyze_pcm_asbd(devAsbd);
                std::string desc = devAnalysis.valid ? devAnalysis.description : "未知格式";
                devicePacking_ = devAnalysis.packing;
                deviceEffectiveBits_ = devAnalysis.effectiveBits;
                deviceContainerBits_ = devAnalysis.containerBits;
                deviceIsFloat_ = devAnalysis.isFloat;
                formatFallbackNote_ = "共享模式：客户端请求 " + std::to_string(rate_) + "Hz/" +
                                      std::to_string(bits_) + "bit/" + std::to_string(channels_) +
                                      "ch，设备当前为 " + std::to_string((uint32_t)devAsbd.mSampleRate) +
                                      "Hz/" + desc + "（由 AUHAL/HAL 进行设备格式转换与混音）";
            } else {
                formatFallbackNote_ = "共享模式（无法读回设备混音格式，由系统混音转接）";
            }
        }

        // 2b) 设备硬件音量：**不接管**（2026-10-25 用户明确要求，推翻上一版设计）。
        //
        // 用户原话：「音量不对，能不能做到独占的时候能让系统调节音量」。
        //
        // 上一版我让接管时把硬件音量强制置满、音量全交给软件增益，结果有两个严重问题：
        //   ① **满幅爆炸**：硬件 1.0 × 软件 0 dB = 满幅输出，只要起播音量是 0 就炸；
        //   ② **系统音量条失效**：硬件被钉死在 1.0，用户按系统音量键/拖系统音量条都没反应。
        //
        // 实测确认（/tmp/hogvol）：**Hog Mode 并不阻止硬件音量读写**
        //   Hog 中读 0.1848 成功、写 0.5 成功、settable=YES。
        // 所以正确做法是：独占只抢「设备所有权」，音量仍归系统和硬件控制。
        //
        // 现在的语义：
        //   * 硬件音量：完全不动，用户用系统音量条 / 音量键 / DAC 旋钮控制；
        //   * 软件增益：只在用户主动拖播放器音量条时按 delta 应用（默认 0 dB = 不衰减）；
        //   * bit-perfect 判据仍是「增益 == 1.0」，与系统音量无关（系统音量在 DAC 前生效，
        //     不影响位流完整性，这也是 macOS 上 bit-perfect 的通行做法）。
        hwVol_ = detail::HwVolumeState{};
        hwStartDbValid_ = false;

        // 3) 建 AUHAL 输出单元
        AudioComponentDescription desc{};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_HALOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent comp = ::AudioComponentFindNext(nullptr, &desc);
        if (!comp) {
            rollback_device();
            fail(OutputError::Internal, "找不到 HALOutput 音频组件");
            return false;
        }
        OSStatus st = ::AudioComponentInstanceNew(comp, &unit_);
        if (st != noErr || unit_ == nullptr) {
            rollback_device();
            fail(OutputError::Internal, "创建音频单元失败（OSStatus=" + std::to_string((int)st) + "）");
            return false;
        }

        // 4) 绑定设备到输出的第一个总线（AUHAL 的 element 0 = 输出）
        UInt32 dev = (UInt32)device_;
        st = ::AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &dev, sizeof(dev));
        if (st != noErr) {
            rollback_unit();
            rollback_device();
            fail(OutputError::DeviceBusy,
                 "无法绑定输出设备（OSStatus=" + std::to_string((int)st) +
                 "）：设备可能被其它程序独占");
            return false;
        }

        // 5) 在输出总线上设我们的流格式（交错整数，按**物理位深**打包）
        //
        // ⚠️ 2026-11-09：这里用 physDeviceBits_ 而不是 bits_。
        // 原因：物理层锁到的是设备真实位深（例如源 16-bit、设备只有 24-bit 整数物理格式），
        // 客户端必须按物理位深打包并**低位补零**，否则 AUHAL 会在 client↔device 之间
        // 再做一次转换，那正是我们刚刚锁物理层要消除的东西。
        // 独占路径上 physDeviceBits_ 已由 pick_physical_format 校验过（>= bits_）；
        // 共享路径没有锁物理层，退回 bits_（那里本来就如实标注非 bit-perfect）。
        const int clientPackBits = (!shared_ && physDeviceBits_ >= bits_) ? physDeviceBits_ : bits_;
        AudioStreamBasicDescription asbd{};
        asbd.mSampleRate = (Float64)rate_;
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        asbd.mBytesPerFrame = (UInt32)(clientPackBits / 8) * (UInt32)channels_;
        asbd.mChannelsPerFrame = (UInt32)channels_;
        asbd.mBitsPerChannel = (UInt32)clientPackBits;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerPacket = asbd.mBytesPerFrame;
        st = ::AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
        if (st != noErr) {
            close_locked();
            fail(OutputError::UnsupportedFormat,
                 "音频单元不接受该流格式（OSStatus=" + std::to_string((int)st) + "）");
            return false;
        }

        // 读回 client ASBD，严格校验 AUHAL 是否接受了我们所配置的客户端打包格式
        AudioStreamBasicDescription clientReadback{};
        UInt32 clientAsbdSize = sizeof(clientReadback);
        st = ::AudioUnitGetProperty(unit_, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input, 0, &clientReadback, &clientAsbdSize);
        if (st != noErr) {
            close_locked();
            fail(OutputError::Internal,
                 "无法读回音频单元客户端流格式（OSStatus=" + std::to_string((int)st) + "）");
            return false;
        }
        // 严格匹配 client 打包参数（位深按 clientPackBits，其余与请求一致）
        if ((uint32_t)clientReadback.mSampleRate != rate_ ||
            clientReadback.mChannelsPerFrame != (UInt32)channels_ ||
            clientReadback.mBitsPerChannel != (UInt32)clientPackBits ||
            clientReadback.mBytesPerFrame != asbd.mBytesPerFrame ||
            clientReadback.mFormatFlags != asbd.mFormatFlags) {
            close_locked();
            fail(OutputError::UnsupportedFormat,
                 "音频单元读回格式与客户端打包要求不匹配（AUHAL 自动重协商偏离）："
                 "请求 " + std::to_string(clientPackBits) + "-bit 整数，" +
                 "读回 " + std::to_string((int)clientReadback.mBitsPerChannel) + "-bit");
            return false;
        }

        if (clientPackBits == 16) clientPacking_ = macos::ContainerPacking::Packed16;
        else if (clientPackBits == 24) clientPacking_ = macos::ContainerPacking::Packed24;
        else clientPacking_ = macos::ContainerPacking::Int32;
        clientBits_ = (uint32_t)clientPackBits;

        // 6) 缓冲帧数：
        // 若为 AirPlay 设备（isAirPlay），严禁硬套本地 bufferMs，采用设备实际 buffer size
        UInt32 frames = 0;
        if (isAirPlay && actualDevCaps.currentBufferFrames >= 32) {
            frames = (UInt32)actualDevCaps.currentBufferFrames;
        } else {
            frames = (UInt32)((double)rate_ * buffer_ms_ / 1000.0);
            if (frames < 32) frames = 32;
            ::AudioUnitSetProperty(unit_, kAudioDevicePropertyBufferFrameSize,
                                   kAudioUnitScope_Global, 0, &frames, sizeof(frames));
        }

        // 读回实际生效的 buffer frame size 并检查校验
        UInt32 actualBufferFrames = 0;
        UInt32 bufSizeVal = sizeof(actualBufferFrames);
        if (::AudioUnitGetProperty(unit_, kAudioDevicePropertyBufferFrameSize,
                                   kAudioUnitScope_Global, 0, &actualBufferFrames, &bufSizeVal) == noErr &&
            actualBufferFrames >= 32) {
            frames = actualBufferFrames;
        }
        // ⚠️ 兜底：AirPlay 且设备没报 currentBufferFrames、读回也失败时 frames 会是 0。
        // 0 会让 buffer_frames() 返回 0 ⟹ 渲染循环只能拿 4096 的猜测周期，而环形缓冲
        // 却按 1024 分配，等于人为把吞吐压到 1/4。这里退回 bufferMs 折算，绝不返回 0。
        if (frames < 32) {
            frames = (UInt32)((double)rate_ * (buffer_ms_ > 0.0 ? buffer_ms_ : 100.0) / 1000.0);
            if (frames < 32) frames = 32;
        }

        buffer_frames_ = frames;
        // 2026-10-25：IO 周期帧数 = 设备的 buffer frame size。ZeroAttrib 用它判
        // 「供料不足一个周期」（等价 WASAPI 的 per）。
        io_period_frames_ = (size_t)frames;

        // 6b) 分配环形缓冲（容量 = 设备缓冲的 4 倍，留调度抖动余量）。
        // ⚠️ 这一步曾经漏掉：ring_ 只有 clear() 从没分配过，write() 直接对空
        // vector 做 memcpy ⟹ 段错误（实测 Pocket Master 上 SIGSEGV @ write）。
        // 只测 caps() 不会暴露这个缺陷，必须真的 open+write 才能抓到。
        ring_frames_ = (size_t)frames * 4u;
        if (ring_frames_ < 1024) ring_frames_ = 1024;
        ring_.assign(ring_frames_ * (size_t)channels_, 0);
        write_pos_ = read_pos_ = 0;

        // 7) 设置渲染回调（拉模式：设备来要数据，我们从队列取）
        AURenderCallbackStruct cb{};
        cb.inputProc = &CoreAudioOutput::render_trampoline;
        cb.inputProcRefCon = this;
        st = ::AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback,
                                    kAudioUnitScope_Input, 0, &cb, sizeof(cb));
        if (st != noErr) {
            rollback_unit();
            rollback_device();
            fail(OutputError::Internal, "设置渲染回调失败（OSStatus=" + std::to_string((int)st) + "）");
            return false;
        }

        st = ::AudioUnitInitialize(unit_);
        if (st != noErr) {
            rollback_unit();
            rollback_device();
            fail(OutputError::StartFailed, "音频单元初始化失败（OSStatus=" + std::to_string((int)st) + "）");
            return false;
        }
        initialized_ = true;
        opened_ = true;
        return true;
    }

    bool start() override {
        std::lock_guard<std::mutex> lk(mu_);
        if (!opened_ || !initialized_) {
            fail(OutputError::NotOpened, "start 前必须先 open");
            return false;
        }
        const OSStatus st = ::AudioOutputUnitStart(unit_);
        if (st != noErr) {
            fail(OutputError::StartFailed, "启动输出失败（OSStatus=" + std::to_string((int)st) + "）");
            return false;
        }
        running_ = true;
        return true;
    }

    // ---------------- 写入 ----------------
    // 渲染回调从这里取数据。用环形缓冲解耦"设备拉"与"引擎推"。
    size_t write(const int32_t* interleaved, size_t frames) override {
        if (!opened_) { fail(OutputError::NotOpened, "write 前必须先 open"); return 0; }
        if (!interleaved || frames == 0) return 0;

        std::lock_guard<std::mutex> lk(mu_);
        // 环形缓冲剩余空间（帧）。capacity 为 0 说明 open 没走完 —— 防御性返回 0，
        // 绝不能让下面的 % capacity 触发除零（铁律 3：判据要能证明自己没崩）。
        const size_t capacity = ring_frames_;
        if (capacity == 0) {
            fail(OutputError::NotOpened, "环形缓冲未初始化（open 未完成）");
            return 0;
        }
        const size_t used = (write_pos_ + capacity - read_pos_) % capacity;
        size_t space = capacity - used - 1;
        // 2026-10-25：接入欠载归因（与 WASAPI 侧同构）。
        // 环形缓冲满 ⟹ 等价 WASAPI 的「设备缓冲满」(pad=full)；
        // CoreAudio接受任意正帧数的部分写，不实施WASAPI式整周期量化。
        // 因此正常开流下只有ring满会产生零写；starved/other为0是该后端能力事实，
        // 不为“填统计”拒绝原本可写的半周期数据。其它后端不支持时返回-1。
        if (space == 0) {
            zero_.classify(0, 0, frames, io_period_frames_);
            return 0;                       // 满：部分写语义，返回 0 让调用方稍后重试
        }
        const size_t n = frames < space ? frames : space;
        zero_.classify(n, space, frames, io_period_frames_);

        // 2026-10-25（实时音量改造）：原始 PCM 原样写入 ring_，不在此处乘 gain_。
        // 音量缩放在 render() 硬件回调出环打包时实时应用（scale_sample_i32），
        // 彻底消除 400ms 环形缓冲排空延迟，拖动音量条毫秒级即时跟手。
        for (size_t i = 0; i < n; ++i) {
            std::memcpy(&ring_[(write_pos_ + i) % capacity * (size_t)channels_],
                        interleaved + i * (size_t)channels_,
                        sizeof(int32_t) * (size_t)channels_);
        }
        // ⚠️ 1.1.2 修正（P0-3 后续）：这里**不再**记录 DoP 相位。
        //
        // 旧实现在生产者侧算「最后一帧入队的是 0x05 ⟹ 欠载时下一帧用 0xFA」。这个推断在
        // 环形缓冲里还留着**更旧的未渲染帧**时是错的（部分渲染 / 欠载后的真实场景）：
        //   已渲染到 0xFA，环里还剩 0x05…，生产者却给出"下一帧 = 0xFA"
        //   ⟹ 欠载填充的第一帧与刚渲染出去的最后一帧**同标记** ⟹ 接收端判非法（A,A）。
        // 而且这个字节跨线程（write 线程写、render 线程读）本来就是一条数据竞争。
        // 现在相位只由渲染线程持有（dopPhase_，见 dop_silence_fill.h 的 DopPhase），
        // 从**真正渲染出去的最后一帧**接续；生产者线程不参与，竞争与错相一起消失。
        write_pos_ = (write_pos_ + n) % capacity;
        frames_written_ += n;
        return n;
    }

    void pause() override {
        std::lock_guard<std::mutex> lk(mu_);
        if (running_ && unit_) { ::AudioOutputUnitStop(unit_); running_ = false; paused_ = true; }
    }

    void resume() override {
        std::lock_guard<std::mutex> lk(mu_);
        if (paused_ && unit_) { ::AudioOutputUnitStart(unit_); running_ = true; paused_ = false; }
    }

    void close() override {
        std::lock_guard<std::mutex> lk(mu_);
        close_locked();
        hog_requested_ = false;
        hogged_ = false;
    }

    bool hog_requested() const override { return hog_requested_; }
    bool hog_acquired() const override { return hogged_; }
    // 1.1.2：本次 open 是否请求了 DoP 承载（AirPlay/共享模式已被前置拒绝）。
    bool dop_requested() const { return dop_requested_.load(std::memory_order_relaxed); }
    // 1.1.2 AP-1.3 自证：本次是否被平台强制成了共享输出（AirPlay 恒为 true）。
    bool shared_mode() const { return shared_; }

    // ---------------- 1.1.2 DoP 安全自证（只读诊断，供 STAT / signal chain 取用）----------------
    // phase    : 渲染侧标记相位的异常计数（改写/非法/声道对齐）与"下一帧标记"
    // gainBlocked : DoP 下被拒绝的非 1.0 增益请求次数
    // exclusiveRateOk : 开流时设备实际速率是否真的等于请求速率（DoP 的硬前提）
    // 这些值只增不减，读它们不会改变行为，也不会进实时路径。
    struct DopSafety {
        uint8_t phaseNext = 0;
        uint64_t rephasedFrames = 0;
        uint64_t invalidMarkerFrames = 0;
        uint64_t channelFixedFrames = 0;
        uint64_t gainRequestsBlocked = 0;
        uint32_t deviceRate = 0;      // 开流时读回的设备速率（0 = 没读/共享模式）
        bool exclusiveRateOk = false; // 设备速率 == 请求速率
    };
    DopSafety dop_safety() const {
        DopSafety s;
        const auto snap = dopPhase_.snapshot();
        s.phaseNext = snap.next;
        s.rephasedFrames = snap.rephased;
        s.invalidMarkerFrames = snap.invalidMarker;
        s.channelFixedFrames = snap.channelFixed;
        s.gainRequestsBlocked = dopGainIgnored_.load(std::memory_order_relaxed);
        s.deviceRate = dopDeviceRate_.load(std::memory_order_relaxed);
        s.exclusiveRateOk = dopExclusiveRateOk_.load(std::memory_order_relaxed);
        return s;
    }

    // 1.1.2 生命周期与端点存活监测（AP-1.6）
    // 只读根据 kAudioDevicePropertyDeviceIsAlive 及输出流查询，避免渲染循环无限等待
    bool endpoint_alive() const {
        std::lock_guard<std::mutex> lk(mu_);
        if (device_ == kAudioObjectUnknown) return false;
        return detail::is_device_alive(device_);
    }

    size_t buffer_frames() const override { return buffer_frames_; }
    size_t frames_written() const override { return frames_written_; }
    size_t frames_rendered() const override { return frames_rendered_.load(); }
    uint64_t underruns() const override { return underruns_.load(); }

    // ---------------- 欠载归因（与 WASAPI 侧同名同义，2026-10-25 移植）----------------
    // 对应原来 WasapiOutput::zero_pad_full / zero_starved / last_zero_reason。
    // 调用方（rtaweb 的 STAT/WFAIL、tests/test_renderfail）无需区分平台。
    size_t io_period_frames() const { return io_period_frames_; }
    long long queued_frames() const {
        std::lock_guard<std::mutex> lk(mu_);
        return ring_frames_ ? (long long)((write_pos_ + ring_frames_ - read_pos_) % ring_frames_) : 0;
    }
    long long zero_pad_full() const { return zero_.padFull; }
    long long zero_starved() const { return zero_.starved; }
    long long zero_other() const { return zero_.other; }
    std::string last_zero_reason() const { return zero_.reason(); }

    // ---------------- 实时音量定点缩放辅助函数 ----------------
    // g == 1.0 时逐位不变（100% bit-perfect 保证）；
    // g <= 0.0 时直接返回 0（真静音）；
    // 其余按 bits 归一后乘增益、四舍五入并限幅。
    static inline int32_t scale_sample_i32(int32_t s, int bits, double g) {
        return detail::scale_sample_i32(s, bits, g);
    }

    // ---------------- 实时音量 ----------------
    // 🔴 1.1.2 DoP 增益闸（纵深防御，任务要求）：DoP 请求下**丢弃**任何非 1.0 的软件增益。
    //
    // 为什么必须在入口丢，而不是只靠 render 侧兜底：
    //   * DoP 把 DSD 位流装进 24-bit 容器，高 8 位是 0x05/0xFA 标记。任何增益都会把它
    //     当整数缩放（0x05XXXX × 0.5 = 0x02XXXX）⟹ 标记消失 ⟹ 接收端判非法 PCM/白噪。
    //   * 这条路径**不能**靠"调用方记得不要设增益"来保证：音量滑块、渐变、set_base 与
    //     set_live 的交叉都可能在切歌/停止瞬间漏进来。丢弃 + 计数才是可自证的。
    // 语义后果（必须让 UI/用户知道）：DSD 播放期间软件音量不生效，音量由 DAC/系统负责。
    // 这不是退步 —— 对 DSD 来说软件增益本来就不该存在。
    void set_gain(double linear) override {
        if (dop_requested_.load(std::memory_order_relaxed)) {
            // 只记"被挡了几次"，不改 gain_：干净地保持 1.0，bit_perfect() 判据不受影响。
            dopGainIgnored_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        gain_.store(linear, std::memory_order_relaxed);
    }

    // 2026-10-25：接管后「音量条的起点 dB」。
    // 独占接管时硬件音量被置满、软件增益接管；为了让用户看到/拖动的音量值与
    // 实际响度一致，上层（rtaweb）需要知道这个起点。返回 false = 没接管/没读到原值。
    bool hw_takeover_db(double& outDb) const {
        if (!hwStartDbValid_) return false;
        outDb = hwStartDb_;
        return true;
    }

    bool bit_perfect() const override {
        // bit-perfect 的判据（2026-10-25 随 exclusive 开关调整，2026-10-28 补格式校验）：
        //   不经系统混音(shared==false) + 物理格式==源格式(无降级回退说明) + 增益 1.0 + 无 DSP
        //
        // ⚠️ **不再要求 hogged_**。原因：Hog 只保证「设备所有权独占」，
        // 与「位流是否被改动」无关 —— 不抢 Hog 时，只要不经系统混音器、
        // 物理格式按源设置且真实读回完全匹配（formatFallbackNote_ 为空）、增益 1.0，
        // 送到 DAC 的仍然是逐位相同的位流。
        // 系统音量（硬件标量）作用在 DAC 的模拟/数字音量级，不改变位流本身，
        // 这也是 macOS 上 bit-perfect 的通行判定（Roon / Audirvana 同）。
        //
        // 若发生了 24-in-32 或 Float32 等回退，尽管精度未丢但容器改变或需转换，不视为严格 bit-perfect。
        // 反过来，抢了 Hog 但走了 DSP/增益，依然不是 bit-perfect —— 那个由引擎层判。
        // 2026-11-09：新增 physLocked_ —— 物理层没锁到源格式就**不可能**逐位直通。
        // 这条是本轮的核心：此前只看虚拟层，物理层若是 176400 而源是 44100，
        // HAL 正在重采样，代码却报 true（用户实测质疑「HQPlayer 能做到，为什么我们不行」）。
        // 判据（2026-11-09 真机实测后收紧，每一条都能被设备读回值证伪）：
        //   1. opened_ && !shared_      不经系统混音
        //   2. physLocked_              物理层锁到「同率 + 整数 + 位深 >= 源位深」
        //   3. !containerLossy_         中间容器不丢源位深的任何一位
        //   4. gain == 1.0              渲染增益真的是 1.0
        //
        // 为什么**不再**要求 formatFallbackNote_ 为空（真机实测推翻的旧判据）：
        //   CoreAudio 的 HAL 混音域恒为 float32 —— Pocket Master 物理层是 44100/16 整数，
        //   而虚拟层读回 float32。旧的 validate_and_negotiate_format 把这件事写进
        //   formatFallbackNote_（"由 AUHAL/HAL 进行设备转换"），于是接一台**能**做
        //   逐位直通的 USB DAC 也永远报 false。真正要问的是：
        //   float32 装 int16/int24 会不会丢位？—— 不会（IEEE-754 尾数 24 位，
        //   24 bit 以内全部整数可精确表示，这正是 PLATFORM.md 13.10.3 实测 0 LSB 的原因）。
        //   会丢位的情形是容器**有效精度低于源位深**（如源 32 bit 走 float32），
        //   那条由 containerLossy_ 单独判。
        return opened_ && !shared_ && physLocked_ && !containerLossy_ &&
               (gain_.load(std::memory_order_relaxed) == 1.0);
    }

    // ---------------- 只读实际生效格式（供主控 status / signal chain / UI 查询）----------------
    // 明确拆分为客户端格式与设备格式，分别对应 AUHAL 客户端输入与 HAL 设备虚拟/混音层
    struct ClientFormatInfo {
        uint32_t sampleRate = 0;
        int channels = 0;
        int bits = 0;                      // 容器宽度（位，如 16, 24, 32）
        macos::ContainerPacking packing = macos::ContainerPacking::Invalid;
    };

    struct DeviceFormatInfo {
        uint32_t sampleRate = 0;
        int channels = 0;
        int bits = 0;                      // 容器宽度（位，如 16, 24, 32）
        int effectiveBits = 0;             // 有效精度位数（如 Float32 为 24，24-in-32 为 24）
        bool isFloat = false;              // 是否为浮点
        macos::ContainerPacking packing = macos::ContainerPacking::Invalid;
        std::string fallbackNote;          // 转换说明（由 AUHAL/HAL 进行设备转换而非内存重打包）
    };

    // 兼容原有接口，返回客户端视角格式及 fallbackNote
    struct ActualFormatInfo {
        uint32_t sampleRate = 0;
        int channels = 0;
        int bits = 0;                      // 容器宽度（位，如 16, 24, 32）
        int effectiveBits = 0;             // 有效精度位数（如 Float32 为 24，24-in-32 为 24）
        bool isFloat = false;              // 是否为浮点
        macos::ContainerPacking packing = macos::ContainerPacking::Invalid;
        std::string fallbackNote;          // 降级/回退说明（与请求完全一致时为空）
    };

    ClientFormatInfo client_format() const {
        std::lock_guard<std::mutex> lk(mu_);
        ClientFormatInfo info;
        if (!opened_) return info;
        info.sampleRate = rate_;
        info.channels = channels_;
        info.bits = (int)clientBits_;
        info.packing = clientPacking_;
        return info;
    }

    DeviceFormatInfo device_format() const {
        std::lock_guard<std::mutex> lk(mu_);
        DeviceFormatInfo info;
        if (!opened_) return info;
        // 观察 device_format：若读取到了底层设备真实 sampleRate，保留真实 device readback 而不谎报 client rate
        const uint32_t realDevRate = detail::device_current_rate(device_);
        info.sampleRate = (realDevRate > 0) ? realDevRate : rate_;
        const int realDevCh = detail::device_max_channels(device_);
        info.channels = (realDevCh > 0) ? realDevCh : channels_;
        info.bits = (int)deviceContainerBits_;
        info.effectiveBits = (int)deviceEffectiveBits_;
        info.isFloat = deviceIsFloat_;
        info.packing = devicePacking_;
        info.fallbackNote = formatFallbackNote_;
        return info;
    }

    ActualFormatInfo actual_format() const {
        std::lock_guard<std::mutex> lk(mu_);
        ActualFormatInfo info;
        if (!opened_) return info;
        info.sampleRate = rate_;
        info.channels = channels_;
        info.bits = (int)clientBits_;
        info.effectiveBits = (int)clientBits_;
        info.isFloat = false;
        info.packing = clientPacking_;
        info.fallbackNote = formatFallbackNote_;
        return info;
    }

    // 物理格式自证（2026-11-09）：给上层判据填 BpInputs::formatFallback 用。
    // 返回 true 表示"物理层已锁定且与源格式一致"，false 表示存在转换/未锁。
    // ⚠️ 只看物理层，**不看** formatFallbackNote_。
    // 原因（2026-11-09 真机实测暴露）：CoreAudio 的 HAL 混音域恒为 float32，
    // 所以 kAudioDevicePropertyStreamFormat 读回 float32 是**正常架构**，不是降级 ——
    // 它由 validate_and_negotiate_format 写成 formatFallbackNote_，
    // 若把那条当失败，接 Pocket Master（物理层 44100/16 整数、虚拟层 float32）
    // 会永远报"未锁定"。float32 是否精确由 bit_perfect() 单独判（见那里）。
    bool physical_format_ok() const {
        std::lock_guard<std::mutex> lk(mu_);
        return opened_ && physLocked_;
    }
    uint32_t physical_rate() const { std::lock_guard<std::mutex> lk(mu_); return physReadRate_; }
    int      physical_bits() const { std::lock_guard<std::mutex> lk(mu_); return physReadBits_; }
    bool     physical_is_float() const { std::lock_guard<std::mutex> lk(mu_); return physReadFloat_; }
    std::string physical_note() const { std::lock_guard<std::mutex> lk(mu_); return physNote_; }
    // 其它进程是否正在使用本设备（Hog 挡不住别的进程，见 device_running_somewhere 注释）
    bool device_shared_with_others() const {
        return device_ != kAudioObjectUnknown && detail::device_running_somewhere(device_);
    }
    // 渲染增益（线性）。判据用它确认"实际写出去的增益确实是 1.0"（纵深防御）。
    double render_gain() const { return gain_.load(std::memory_order_relaxed); }
    // 中间容器是否丢掉源位深的有效位（物理位深不足 / float32 装 32-bit 源）
    bool container_lossy() const { std::lock_guard<std::mutex> lk(mu_); return containerLossy_; }

    // 格式回退说明（若格式与请求真正完全一致则为空；非空表示存在回退或说明）
    std::string bits_fallback_note() const {
        std::lock_guard<std::mutex> lk(mu_);
        return formatFallbackNote_;
    }

    OutputError last_error_class() const override { return err_class_; }
    const std::string& last_error() const override { return err_text_; }
    const std::string& last_error_en() const { return err_text_en_; }

private:
public:
    // 供只读探测（platform/audio_out_factory.h::macos_probe）在**开流之前**解析设备号。
    // 返回 0 表示"无有效设备号"（留空表示默认端点，由 open() 内部解析）。
    static unsigned int probe_resolve_device(const std::string& id) {
        if (id.empty()) return static_cast<unsigned int>(detail::default_output_device());
        return static_cast<unsigned int>(resolve_device(id));
    }
private:
    static AudioDeviceID resolve_device(const std::string& id) {
        if (id.empty()) return detail::default_output_device();
        // deviceId 约定：十进制 AudioDeviceID 字符串（宿主枚举时生成）
        char* end = nullptr;
        const unsigned long v = std::strtoul(id.c_str(), &end, 10);
        if (end && *end == '\0' && v != 0) return (AudioDeviceID)v;
        // 也接受设备名（便于 CLI 手填）
        AudioObjectPropertyAddress addr{kAudioHardwarePropertyDevices,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        UInt32 size = 0;
        if (::AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size) != noErr)
            return kAudioObjectUnknown;
        const size_t n = size / sizeof(AudioDeviceID);
        std::vector<AudioDeviceID> devs(n);
        if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, devs.data()) != noErr)
            return kAudioObjectUnknown;
        for (AudioDeviceID d : devs)
            if (detail::device_name(d) == id) return d;
        return kAudioObjectUnknown;
    }

    // 设备拉数据的回调：把环形缓冲里的帧按设备请求量填出去；不够就补静音并记欠载
    static OSStatus render_trampoline(void* refcon, AudioUnitRenderActionFlags* /*flags*/,
                                      const AudioTimeStamp* /*ts*/, UInt32 /*bus*/,
                                      UInt32 frames, AudioBufferList* io) {
        auto* self = static_cast<CoreAudioOutput*>(refcon);
        if (!self || !io) return noErr;
        self->render(frames, io);
        return noErr;
    }

    void render(UInt32 frames, AudioBufferList* io) {
        const size_t ch = (size_t)channels_;
        const size_t capacity = ring_frames_;
        // 环形缓冲未分配（open 没走完）时一帧都不碰：原来的 `% capacity` 在这里是除零。
        if (!io || io->mNumberBuffers == 0 || capacity == 0) return;
        const size_t avail = (write_pos_ + capacity - read_pos_) % capacity;
        const size_t take = frames < avail ? frames : avail;

        // ⚠️ 设备要的是【按请求位深打包】的交错样本，而环形缓冲里是 int32 满量程。
        //    这里必须逐样本重打包，不能直接把 int32 内存拷过去：
        //      bits=16 -> 取 int32 的低 16 位（低位对齐语义，见 audio_out.h 头注）
        //      bits=24 -> 取低 24 位，按 3 字节小端打包
        //      bits=32 -> 原样 4 字节
        //    曾经这里直接 memcpy(sizeof(int32_t)*ch)，16bit 时会把 8 字节/帧写进
        //    设备要的 4 字节/帧缓冲 —— 既越界又全是噪声。
        auto* out = static_cast<uint8_t*>(io->mBuffers[0].mData);
        // ⚠️ 2026-11-09：打包宽度必须跟**客户端流格式**（clientBits_）走，不能用 bits_。
        // 独占路径把物理层锁到设备真实位深后，客户端也是按那个位深打包的
        // （例如源 16-bit、设备物理只有 24-bit 整数 ⟹ 客户端写 24-bit 并低位补零）。
        // 若这里仍按 bits_=16 打包，AUHAL 收到的字节数和它要的对不上：
        // 要么越界写、要么把相邻样本当数据 —— 这正是当年 memcpy 事故的同型错误。
        // clientBits_ 为 0 表示尚未 open（理论上不会进 render），退回 bits_。
        const int packBits = (clientBits_ > 0) ? (int)clientBits_ : bits_;
        const size_t bytes_per_sample = (size_t)(packBits / 8);
        const size_t frame_bytes = bytes_per_sample * ch;
        // 设备请求的帧数 = 字节数 / 每帧字节数（不能用 int32 宽度反推！）
        const size_t out_frames = frame_bytes ? (io->mBuffers[0].mDataByteSize / frame_bytes) : 0;

        // ---- 1.1.2 P0-3 后续：DoP 输出整段委托给纯函数（dop_silence_fill.h）----
        //
        // 为什么整段切出去：DoP 的三件事——24-bit 容器打包、标记相位、欠载补静音——过去
        // 一半在实时回调里手写、一半在纯函数里，于是"相位从哪来"这类错误只能靠真机听出来
        // （而铁律 1 禁止我们那样验证）。现在这三件事只有一份实现，测试离线驱动同一份代码。
        //
        // 增益闸（task 1）：DoP 请求时 render 侧**无条件**按 1.0 输出，不看 gain_。
        // 任何非单位增益都会改写 24-bit 字（含承载标记的高 8 位）⟹ 接收端判非法。
        // set_gain() 已经在入口丢弃这类请求，这里是第二道闸（纵深防御，不依赖调用顺序）。
        const bool dop = dop_requested_.load(std::memory_order_relaxed);
        if (dop && bytes_per_sample == 3) {
            const macos::DopPeriodStats st = macos::dop_write_period_24le(
                out, out_frames, ring_.data(), capacity, read_pos_, take, ch,
                gain_.load(std::memory_order_relaxed), dopPhase_);
            if (st.gainIgnored) dopGainIgnored_.fetch_add(1, std::memory_order_relaxed);
            // 只消费真正写出去的帧（out_frames 小于 take 时不白丢环里的数据）。
            read_pos_ = (read_pos_ + st.written) % capacity;
            if (st.written < out_frames) underruns_.fetch_add(1);
            frames_rendered_.fetch_add(out_frames);
            return;
        }

        const double g = gain_.load(std::memory_order_relaxed);
        size_t i = 0;
        for (; i < take && i < out_frames; ++i) {
            const int32_t* src = &ring_[((read_pos_ + i) % capacity) * ch];
            uint8_t* dst = out + i * frame_bytes;
            for (size_t c = 0; c < ch; ++c) {
                int32_t s = scale_sample_i32(src[c], bits_, g);
                // 低位补零：客户端容器比源位深宽时，必须左移对齐到容器满量程，
                // 否则 -32768..32767 写进 24-bit 容器只等于 -128..127 的满量程比例 —— 声音会小 48 dB。
                // 左移只是把已知的 0 填进低位，**数值不变**（这正是"补零不破坏逐位"的含义）。
                if (packBits > bits_) {
                    const int sh = packBits - bits_;
                    if (sh < 32) s = (int32_t)((uint32_t)s << sh);
                }
                if (bytes_per_sample == 2) {
                    const uint16_t v = (uint16_t)(s & 0xFFFF);          // 低 16 位
                    std::memcpy(dst + c * 2, &v, 2);
                } else if (bytes_per_sample == 3) {
                    const uint32_t v = (uint32_t)s & 0xFFFFFFu;          // 低 24 位
                    dst[c * 3 + 0] = (uint8_t)(v & 0xFF);
                    dst[c * 3 + 1] = (uint8_t)((v >> 8) & 0xFF);
                    dst[c * 3 + 2] = (uint8_t)((v >> 16) & 0xFF);
                } else {
                    std::memcpy(dst + c * 4, &s, 4);
                }
            }
        }
        // 不足补静音，并记一次欠载。
        //
        // 普通 PCM 路径行为逐字节不变（仍补 0），旧判据与测试阈值一律不动。
        // DoP 路径已在上面由 dop_write_period_24le 处理（补的是合法 0x05/0xFA 静音帧）。
        if (i < out_frames) {
            std::memset(out + i * frame_bytes, 0, frame_bytes * (out_frames - i));
            underruns_.fetch_add(1);
        }
        read_pos_ = (read_pos_ + take) % capacity;
        frames_rendered_.fetch_add(out_frames);
    }

    void fail(OutputError e, std::string text, std::string textEn = "") {
        err_class_ = e;
        err_text_ = std::move(text);
        err_text_en_ = std::move(textEn);
    }
    void clear_error() { err_class_ = OutputError::None; err_text_.clear(); err_text_en_.clear(); }

    void rollback_unit() {
        if (unit_) { ::AudioComponentInstanceDispose(unit_); unit_ = nullptr; }
        initialized_ = false;
    }
    void rollback_device() {
        if (hogged_ && device_ != kAudioObjectUnknown) {
            detail::set_hog_mode(device_, false);
            hogged_ = false;
        }
    }

    void close_locked() {
        // 2026-10-25：**不再归还硬件音量** —— 因为已改为「不接管」（见 open 的 2b）。
        // 硬件音量全程由系统控制，我们一个字节都没改过，自然也不需要恢复。
        // （保留 hwVol_ 清零只是把状态归位，不再对设备写任何音量属性。）
        hwVol_ = detail::HwVolumeState{};
        if (unit_) {
            if (running_) ::AudioOutputUnitStop(unit_);
            if (initialized_) ::AudioUnitUninitialize(unit_);
            ::AudioComponentInstanceDispose(unit_);
            unit_ = nullptr;
        }
        rollback_device();
        device_ = kAudioObjectUnknown;
        opened_ = false;
        initialized_ = false;
        running_ = false;
        paused_ = false;
        shared_ = false;
        dop_requested_.store(false, std::memory_order_relaxed);
        dopPhase_.reset();               // 相位归零：下一次开流从"未知"重新接管上游标记
        dopGainIgnored_.store(0, std::memory_order_relaxed);
        dopDeviceRate_.store(0, std::memory_order_relaxed);
        dopExclusiveRateOk_.store(false, std::memory_order_relaxed);
        write_pos_ = read_pos_ = 0;
        ring_.clear();
        ring_frames_ = 0;
        frames_written_ = 0;
        frames_rendered_.store(0);
        underruns_.store(0);
        gain_.store(1.0, std::memory_order_relaxed);
        buffer_frames_ = 0;
        devicePacking_ = macos::ContainerPacking::Packed16;
        deviceEffectiveBits_ = 0;
        deviceContainerBits_ = 0;
        deviceIsFloat_ = false;
        clientPacking_ = macos::ContainerPacking::Packed16;
        clientBits_ = 0;
        formatFallbackNote_.clear();
        // 物理格式锁定状态归位（close 不还原硬件物理格式：那是系统级共享属性，
        // 别的客户端可能依赖当前值；Roon/Audirvana 同样不还原）。
        physStream_ = kAudioObjectUnknown;
        physLocked_ = false;
        physReadRate_ = 0;
        physReadBits_ = 0;
        physReadFloat_ = false;
        physDeviceBits_ = 0;
        physNote_.clear();
        containerLossy_ = false;
    }

    mutable std::mutex mu_;
    AudioUnit unit_ = nullptr;
    AudioDeviceID device_ = kAudioObjectUnknown;
    uint32_t rate_ = 0;
    int bits_ = 0;
    int channels_ = 0;
    double buffer_ms_ = 100.0;
    std::atomic<double> gain_{1.0};
    detail::HwVolumeState hwVol_{};   // 接管前的设备硬件音量（close 时恢复）
    double hwStartDb_ = 0.0;          // 接管后音量条的起点 dB（原硬件音量的等效值）
    bool   hwStartDbValid_ = false;
    bool opened_ = false;
    bool initialized_ = false;
    bool running_ = false;
    bool paused_ = false;
    bool hog_requested_ = false;
    bool hogged_ = false;
    bool shared_ = false;
    // ---- 物理格式锁定状态（2026-11-09，真 bit-perfect 的关键）----
    AudioStreamID physStream_ = kAudioObjectUnknown;  // 首个输出流的 AudioStreamID
    bool physLocked_ = false;      // 物理层已锁到源格式（读回校验通过）
    uint32_t physReadRate_ = 0;    // 读回的物理采样率
    int  physReadBits_ = 0;        // 读回的物理位深
    bool physReadFloat_ = false;   // 读回的物理格式是否浮点
    int  physDeviceBits_ = 0;      // 设备物理位深（客户端按此打包，补零在此发生）
    std::string physNote_;         // 补零等说明（非空 = 有需要如实告知的点）
    bool containerLossy_ = false;  // 中间容器是否丢源位深有效位（float32 + 32-bit 源 / 位深不足）
    // 1.1.2：本次 open 是否请求 DoP 承载（供自证/诊断；AirPlay 与共享模式在
    // validate_open_spec 里已被前置拒绝，绝不会走到写硬件）。
    // 原子：open() 在控制线程写，render() 在实时线程读，set_gain() 也可能从 UI 线程读。
    std::atomic<bool> dop_requested_{false};
    // DoP 渲染相位（**只由渲染线程推进**；控制线程仅在 close/open 时 reset）。
    // ⚠️ 不要再加"生产者侧相位"：write() 记录的是入队顺序，不是渲染顺序，
    //    环里还有旧帧时会算错（这正是 1.1.2 修掉的缺陷，见 write() 的注释）。
    macos::DopPhase dopPhase_;
    // DoP 下被拒绝的非 1.0 增益请求次数（纵深防御的自证，UI/诊断可读）。
    std::atomic<uint64_t> dopGainIgnored_{0};
    // 开流时读回的设备速率与"是否等于请求速率"（DoP 的硬前提，自证用；共享模式不填）。
    // 原子：open() 在控制线程写，dop_safety() 可能从 STAT 线程读（并发读不能是裸变量）。
    std::atomic<uint32_t> dopDeviceRate_{0};
    std::atomic<bool> dopExclusiveRateOk_{false};
    size_t buffer_frames_ = 0;
    size_t frames_written_ = 0;

    // 环形缓冲（帧）
    std::vector<int32_t> ring_;
    size_t ring_frames_ = 0;
    size_t write_pos_ = 0;
    size_t read_pos_ = 0;
    std::atomic<uint64_t> underruns_{0};
    std::atomic<size_t> frames_rendered_{0};

    // 欠载归因（2026-10-25 从 wasapi_out.h 移植过来，见文件上方 include 处的说明）。
    // io_period_frames_ 是 CoreAudio 的 IO 缓冲帧数（= HAL 的 kAudioDevicePropertyBufferFrameSize），
    // open() 时确定；0 表示未知，此时 ZeroAttrib 不做「供料不足」判定（退化为 pad/other 二分）。
    rta::audio::ZeroAttrib zero_;
    size_t io_period_frames_ = 0;

    OutputError err_class_ = OutputError::None;
    std::string err_text_;
    std::string err_text_en_;

    // 格式协商与读回校验记录（设备端 vs 客户端）
    macos::ContainerPacking devicePacking_ = macos::ContainerPacking::Packed16;
    uint32_t deviceEffectiveBits_ = 0;
    uint32_t deviceContainerBits_ = 0;
    bool deviceIsFloat_ = false;

    macos::ContainerPacking clientPacking_ = macos::ContainerPacking::Packed16;
    uint32_t clientBits_ = 0;

    std::string formatFallbackNote_;
};

} // namespace rta::platform
