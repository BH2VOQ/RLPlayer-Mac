// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
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

// 设备当前物理格式（bit depth 由 mFormatFlags 推断）
inline int device_bit_depth(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreamFormat,
                                    kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription asbd{};
    UInt32 size = sizeof(asbd);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &asbd) != noErr) return 0;
    return (int)asbd.mBitsPerChannel;
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

// 设置设备物理格式（等价于"按源格式开独占"）。失败说明该格式不被接受。
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

        // DoP：设备支持 176400 就能承载 DSD64
        if (detail::has_rate_in(c.rates, 176400)) {
            c.dsd = DsdTransport::DoP;
            c.dopCarrierRate = 176400;
        }
        // Native DSD：macOS 无通用用户态 API（见文件头"未解决项"）
        c.dsd = (c.dsd == DsdTransport::DoP) ? DsdTransport::DoP : DsdTransport::None;
        c.nativeDsdRate = 0;

        // 缓冲范围：HAL 默认 IO 缓冲 512 帧可调；按设备采样率折算成毫秒
        const uint32_t base = c.rates.empty() ? 48000u : c.rates.front();
        c.minPeriodFrames = 32;
        c.minBufferMs = 32.0 * 1000.0 / (double)base;
        c.maxBufferMs = 4096.0 * 1000.0 / (double)base;
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
        rate_ = spec.rate;
        bits_ = spec.bits;
        channels_ = spec.channels;
        buffer_ms_ = spec.bufferMs;
        shared_ = spec.shared;

        // 1) Hog Mode（严格独占）—— 2026-10-25 改为由 OpenSpec::exclusive **独立控制**。
        //
        // 为什么不再是「!shared 就抢」：实测确认 Hog 会阻断其它进程改硬件音量
        // （系统音量条/音量键失效），而用户希望「正常调节系统音量的前提下独占」。
        // 二者物理互斥，所以做成开关（方案 C）：
        //   exclusive=true  → 抢 Hog：真独占，其他 App 声音被屏蔽，但系统音量失效；
        //   exclusive=false → 不抢 Hog：系统音量全程可用（默认）。
        // 失败不致命，如实降级为"非 bit-perfect"。
        hogged_ = false;
        if (spec.exclusive && !shared_) {
            hogged_ = detail::set_hog_mode(device_, true) && detail::is_hogged_by_us(device_);
        }

        // 2) 按源格式设置设备物理格式 —— 这是 bit-perfect 的关键。
        //    共享模式跳过（设备可能被其它客户端占用，物理格式归系统管）；
        //    AUHAL 会按需做 int<->float32 换算（|v|<2^24 时精确）。
        // 物理格式：不抢 Hog 也照样按源格式设置（保证采样率/位深正确）。
        // 只有「共享」模式才跳过 —— 那时设备可能被别的客户端占用，物理格式归系统管。
        if (!shared_ && !detail::set_device_format(device_, rate_, bits_, channels_)) {
            // 回滚 hog
            if (hogged_) { detail::set_hog_mode(device_, false); hogged_ = false; }
            const DeviceCaps c = caps(spec.deviceId);
            std::string supported;
            for (uint32_t r : c.rates) supported += std::to_string(r) + " ";
            fail(OutputError::UnsupportedFormat,
                 "设备不支持 " + std::to_string(rate_) + " Hz / " + std::to_string(bits_) +
                 " bit / " + std::to_string(channels_) + " ch（设备支持采样率: " +
                 (supported.empty() ? std::string("未知") : supported) + "）");
            device_ = kAudioObjectUnknown;
            return false;
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

        // 5) 在输出总线上设我们的流格式（int32 交错，按请求位深打包）
        AudioStreamBasicDescription asbd{};
        asbd.mSampleRate = (Float64)rate_;
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        asbd.mBytesPerFrame = (UInt32)(bits_ / 8) * (UInt32)channels_;
        asbd.mChannelsPerFrame = (UInt32)channels_;
        asbd.mBitsPerChannel = (UInt32)bits_;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerPacket = asbd.mBytesPerFrame;
        st = ::AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
        if (st != noErr) {
            rollback_unit();
            rollback_device();
            fail(OutputError::UnsupportedFormat,
                 "音频单元不接受该流格式（OSStatus=" + std::to_string((int)st) + "）");
            return false;
        }

        // 6) 缓冲帧数 = bufferMs 折算
        UInt32 frames = (UInt32)((double)rate_ * buffer_ms_ / 1000.0);
        if (frames < 32) frames = 32;
        ::AudioUnitSetProperty(unit_, kAudioDevicePropertyBufferFrameSize,
                               kAudioUnitScope_Global, 0, &frames, sizeof(frames));
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
        // 空间不足一个 IO 周期 ⟹ 等价「供料不足一个周期」(avail<period)；
        // 其余归 other。这三个计数由 STAT/WFAIL/RENDERFAIL 直接打印。
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
    }

    size_t buffer_frames() const override { return buffer_frames_; }
    size_t frames_written() const override { return frames_written_; }
    size_t frames_rendered() const override { return frames_rendered_.load(); }
    uint64_t underruns() const override { return underruns_.load(); }

    // ---------------- 欠载归因（与 WASAPI 侧同名同义，2026-10-25 移植）----------------
    // 对应原来 WasapiOutput::zero_pad_full / zero_starved / last_zero_reason。
    // 调用方（rtaweb 的 STAT/WFAIL、tests/test_renderfail）无需区分平台。
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

    void set_gain(double linear) override { gain_.store(linear, std::memory_order_relaxed); }

    // 2026-10-25：接管后「音量条的起点 dB」。
    // 独占接管时硬件音量被置满、软件增益接管；为了让用户看到/拖动的音量值与
    // 实际响度一致，上层（rtaweb）需要知道这个起点。返回 false = 没接管/没读到原值。
    bool hw_takeover_db(double& outDb) const {
        if (!hwStartDbValid_) return false;
        outDb = hwStartDb_;
        return true;
    }

    bool bit_perfect() const override {
        // bit-perfect 的判据（2026-10-25 随 exclusive 开关调整）：
        //   不经系统混音(shared==false) + 物理格式==源格式 + 增益 1.0 + 无 DSP
        //
        // ⚠️ **不再要求 hogged_**。原因：Hog 只保证「设备所有权独占」，
        // 与「位流是否被改动」无关 —— 不抢 Hog 时，只要不经系统混音器、
        // 物理格式按源设置、增益 1.0，送到 DAC 的仍然是逐位相同的位流。
        // 系统音量（硬件标量）作用在 DAC 的模拟/数字音量级，不改变位流本身，
        // 这也是 macOS 上 bit-perfect 的通行判定（Roon / Audirvana 同）。
        //
        // 反过来，抢了 Hog 但走了 DSP/增益，依然不是 bit-perfect —— 那个由引擎层判。
        return opened_ && !shared_ && (gain_.load(std::memory_order_relaxed) == 1.0);
    }

    OutputError last_error_class() const override { return err_class_; }
    const std::string& last_error() const override { return err_text_; }

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
        const size_t bytes_per_sample = (size_t)(bits_ / 8);
        const size_t frame_bytes = bytes_per_sample * ch;
        // 设备请求的帧数 = 字节数 / 每帧字节数（不能用 int32 宽度反推！）
        const size_t out_frames = frame_bytes ? (io->mBuffers[0].mDataByteSize / frame_bytes) : 0;

        const double g = gain_.load(std::memory_order_relaxed);
        size_t i = 0;
        for (; i < take && i < out_frames; ++i) {
            const int32_t* src = &ring_[((read_pos_ + i) % capacity) * ch];
            uint8_t* dst = out + i * frame_bytes;
            for (size_t c = 0; c < ch; ++c) {
                const int32_t s = scale_sample_i32(src[c], bits_, g);
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
        // 不足补静音（真静音 = 0），并记一次欠载
        if (i < out_frames) {
            std::memset(out + i * frame_bytes, 0, frame_bytes * (out_frames - i));
            underruns_.fetch_add(1);
        }
        read_pos_ = (read_pos_ + take) % capacity;
        frames_rendered_.fetch_add(out_frames);
    }

    void fail(OutputError e, std::string text) {
        err_class_ = e;
        err_text_ = std::move(text);
    }
    void clear_error() { err_class_ = OutputError::None; err_text_.clear(); }

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
        write_pos_ = read_pos_ = 0;
        ring_.clear();
        ring_frames_ = 0;
        frames_written_ = 0;
        frames_rendered_.store(0);
        underruns_.store(0);
        gain_.store(1.0, std::memory_order_relaxed);
        buffer_frames_ = 0;
    }

    std::mutex mu_;
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
    bool hogged_ = false;
    bool shared_ = false;
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
};

} // namespace rta::platform
