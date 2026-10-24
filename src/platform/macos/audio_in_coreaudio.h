// audio_in_coreaudio.h — macOS 输入采集（AUHAL 输入侧）
//
// 对齐 Windows 的 audio/wasapi_capture.h 接口子集（rtaweb 的采集 worker 与
// /api/input/* 直接复用）：enumerate_capture / open(cfg) / start / stop / close /
// read_available / 观测（rate/channels/water/overflow/underflow/clips/total/last_error）。
//
// 机制：AUHAL（HALOutput unit）——EnableIO 开输入侧（bus 1）、禁输出侧（bus 0），
// 客户端格式固定 float32 交错（AUHAL 对设备的 int 打包自动换算）；输入回调里
// AudioUnitRender 拉帧进 SPSC 环，消费线程 read_available 取。
//
// ⚠️ TCC（铁律 4 如实记录）：app 采集麦克风需要 NSMicrophoneUsageDescription +
//    用户授权。若被拒/被门控，输入流可能恒为零（§13.10.6 的先例：与真静音难区分）。
//    实测结论见 PLATFORM.md。
// ⚠️ loopback（采集系统混音）：macOS 对应机制是 Process Tap（§13.10，与独占互斥、
//    抓的是设备混音节点）——首版不实现，enumerate 的 includeLoopback 忽略。
#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace rta::platform {

struct MacCaptureInfo {
    std::string name, id;
    bool isDefault = false;
    bool isLoopback = false;      // 恒 false（见头注：Process Tap 首版不做）
    uint32_t mixRate = 0;
    int mixChannels = 0;
    int mixBits = 32;             // CoreAudio 混音域 float32
};

struct MacCaptureConfig {
    std::string deviceId;         // 十进制 AudioDeviceID 或名称（空 = 默认输入设备）
    bool srcNull = false;         // 模拟源（不开设备；自动化门禁用，与 Windows 同语义）
    double injectFreq = 1000.0;
    double injectAmp = 0.001;     // ≈ -60 dBFS（铁律 1）
    size_t targetFrames = 0;
    bool paced = true;
    double bufferMs = 200.0;      // SPSC 环容量
};

namespace detail {

// SPSC 环（写=音频回调线程，读=消费线程）。容量以帧计，样本 = 帧×声道 float。
class CaptureFifo {
public:
    void reset(size_t frames, int channels) {
        std::lock_guard<std::mutex> lk(m_);
        buf_.assign(frames * (size_t)channels, 0.0f);
        capacity_ = frames;
        channels_ = channels;
        write_ = read_ = 0;
        water_ = 0;
        overflow_ = underflowPolls_ = 0;
    }
    // 仅音频回调线程调用；返回溢出帧数（环满丢弃）
    size_t push(const float* src, size_t frames) {
        const size_t cap = capacity_;
        if (!cap) return frames;
        const size_t used = write_ - read_;
        const size_t space = cap - used;
        const size_t n = frames < space ? frames : space;
        for (size_t i = 0; i < n; ++i)
            std::memcpy(&buf_[((write_ + i) % cap) * (size_t)channels_],
                        src + i * (size_t)channels_,
                        sizeof(float) * (size_t)channels_);
        write_ += n;
        const size_t u2 = write_ - read_;
        if (u2 > water_) water_ = u2;
        if (frames > n) overflow_ += frames - n;
        return frames - n;
    }
    // 仅消费线程调用
    size_t read_available(float* dst, size_t maxFrames) {
        const size_t cap = capacity_;
        if (!cap) return 0;
        const size_t used = write_ - read_;
        const size_t n = maxFrames < used ? maxFrames : used;
        for (size_t i = 0; i < n; ++i)
            std::memcpy(dst + i * (size_t)channels_,
                        &buf_[((read_ + i) % cap) * (size_t)channels_],
                        sizeof(float) * (size_t)channels_);
        read_ += n;
        if (used == 0) ++underflowPolls_;
        return n;
    }
    double water_level() const { return capacity_ ? (double)water_ / (double)capacity_ : 0.0; }
    uint64_t overflow_count() const { return overflow_; }
    uint64_t underflow_count() const { return underflowPolls_; }
private:
    std::mutex m_;                // 回调与消费不会同时进来（各自单线程），锁只护 reset
    std::vector<float> buf_;
    size_t capacity_ = 0, write_ = 0, read_ = 0, water_ = 0;
    int channels_ = 2;
    uint64_t overflow_ = 0, underflowPolls_ = 0;
};

inline AudioDeviceID default_input_device() {
    AudioDeviceID d = kAudioObjectUnknown;
    UInt32 sz = sizeof(d);
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDefaultInputDevice,
                                 kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &sz, &d) != noErr)
        return kAudioObjectUnknown;
    return d;
}
inline bool device_has_input(AudioDeviceID d) {
    AudioObjectPropertyAddress a{kAudioDevicePropertyStreams,
                                 kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 sz = 0;
    return ::AudioObjectGetPropertyDataSize(d, &a, 0, nullptr, &sz) == noErr && sz > 0;
}
} // namespace detail

class CoreAudioInput {
public:
    CoreAudioInput() = default;
    ~CoreAudioInput() { close(); }
    CoreAudioInput(const CoreAudioInput&) = delete;
    CoreAudioInput& operator=(const CoreAudioInput&) = delete;

    static std::vector<MacCaptureInfo> enumerate_capture(bool includeLoopback = true) {
        (void)includeLoopback;    // loopback=Process Tap，首版不做（头注）
        std::vector<MacCaptureInfo> out;
        AudioObjectPropertyAddress a{kAudioHardwarePropertyDevices,
                                     kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 sz = 0;
        if (::AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &sz) != noErr || !sz)
            return out;
        const size_t n = sz / sizeof(AudioDeviceID);
        std::vector<AudioDeviceID> devs(n);
        if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &sz, devs.data()) != noErr)
            return out;
        const AudioDeviceID defId = detail::default_input_device();
        for (AudioDeviceID d : devs) {
            if (!detail::device_has_input(d)) continue;
            MacCaptureInfo mi;
            mi.id = std::to_string((unsigned)d);
            mi.isDefault = (d == defId);
            CFStringRef name = nullptr;
            UInt32 nsz = sizeof(name);
            AudioObjectPropertyAddress na{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
            if (::AudioObjectGetPropertyData(d, &na, 0, nullptr, &nsz, &name) == noErr && name) {
                const CFIndex len = ::CFStringGetLength(name);
                const CFIndex max = ::CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
                mi.name.resize((size_t)max, '\0');
                if (!::CFStringGetCString(name, mi.name.data(), max, kCFStringEncodingUTF8)) mi.name.clear();
                mi.name.resize(std::strlen(mi.name.c_str()));
                ::CFRelease(name);
            }
            // 输入流格式（标称率/声道）
            AudioStreamBasicDescription asbd{};
            UInt32 fsz = sizeof(asbd);
            AudioObjectPropertyAddress fa{kAudioStreamPropertyPhysicalFormat,
                                          kAudioDevicePropertyScopeInput, 1};
            if (::AudioObjectGetPropertyData(d, &fa, 0, nullptr, &fsz, &asbd) == noErr && asbd.mSampleRate > 0) {
                mi.mixRate = (uint32_t)asbd.mSampleRate;
                mi.mixChannels = (int)asbd.mChannelsPerFrame;
            }
            out.push_back(std::move(mi));
        }
        return out;
    }

    bool open(const MacCaptureConfig& cfg) {
        close();
        cfg_ = cfg;
        if (cfg.srcNull) {
            isNull_ = true; rate_ = 48000; channels_ = 2;
            scratch_.clear();
            fifo_.reset((size_t)(48000.0 * cfg.bufferMs / 1000.0), 2);   // 环必须先建（实测教训：漏了这里 frames=0）
            return true;
        }

        AudioDeviceID dev = kAudioObjectUnknown;
        if (cfg.deviceId.empty()) {
            dev = detail::default_input_device();
        } else {
            char* end = nullptr;
            const unsigned long v = std::strtoul(cfg.deviceId.c_str(), &end, 10);
            if (end && *end == '\0' && v != 0) dev = (AudioDeviceID)v;
            if (dev == kAudioObjectUnknown)
                for (const auto& d : enumerate_capture())
                    if (d.name == cfg.deviceId || d.id == cfg.deviceId) { dev = (AudioDeviceID)std::strtoul(d.id.c_str(), nullptr, 10); break; }
        }
        if (dev == kAudioObjectUnknown) { err_ = "找不到输入设备（deviceId=\"" + cfg.deviceId + "\"）"; return false; }
        dev_ = dev;

        // 设备输入流物理格式（率/声道）——客户端格式按它请求（AUHAL 只做位深换算）
        AudioStreamBasicDescription phys{};
        UInt32 psz = sizeof(phys);
        AudioObjectPropertyAddress fa{kAudioStreamPropertyPhysicalFormat,
                                      kAudioDevicePropertyScopeInput, 1};
        if (::AudioObjectGetPropertyData(dev, &fa, 0, nullptr, &psz, &phys) != noErr || phys.mSampleRate <= 0) {
            err_ = "读不到设备输入流格式"; return false;
        }
        rate_ = (uint32_t)phys.mSampleRate;
        channels_ = (int)phys.mChannelsPerFrame ? (int)phys.mChannelsPerFrame : 2;

        AudioComponentDescription desc{};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_HALOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        AudioComponent comp = ::AudioComponentFindNext(nullptr, &desc);
        if (!comp) { err_ = "找不到 HALOutput 组件"; return false; }
        if (::AudioComponentInstanceNew(comp, &unit_) != noErr || !unit_) { err_ = "创建音频单元失败"; return false; }

        // 输入侧开、输出侧关（AUHAL 采集形态）
        UInt32 on = 1, off = 0;
        if (::AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, 1, &on, sizeof(on)) != noErr ||
            ::AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, 0, &off, sizeof(off)) != noErr) {
            err_ = "EnableIO 配置失败（输入侧开/输出侧关）"; close(); return false;
        }
        UInt32 dv = (UInt32)dev;
        if (::AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &dv, sizeof(dv)) != noErr) {
            err_ = "绑定输入设备失败"; close(); return false;
        }
        // 客户端格式：float32 交错（注意 AUHAL 输入的 client 格式设在 scope_Output bus 1）
        AudioStreamBasicDescription client{};
        client.mSampleRate = (Float64)rate_;
        client.mFormatID = kAudioFormatLinearPCM;
        client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        client.mBytesPerFrame = sizeof(float) * (UInt32)channels_;
        client.mFramesPerPacket = 1;
        client.mBytesPerPacket = client.mBytesPerFrame;
        client.mChannelsPerFrame = (UInt32)channels_;
        client.mBitsPerChannel = 32;
        if (::AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1, &client, sizeof(client)) != noErr) {
            err_ = "设置输入流格式失败（float32/2ch）"; close(); return false;
        }
        // 输入回调：AudioUnitRender 从设备拉帧 → FIFO
        AURenderCallbackStruct cb{};
        cb.inputProc = [](void* self, AudioUnitRenderActionFlags* flags,
                          const AudioTimeStamp* ts, UInt32 /*bus*/, UInt32 frames,
                          AudioBufferList* /*io*/) -> OSStatus {
            return static_cast<CoreAudioInput*>(self)->pull(flags, ts, frames);
        };
        cb.inputProcRefCon = this;
        if (::AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0, &cb, sizeof(cb)) != noErr) {
            err_ = "设置输入回调失败"; close(); return false;
        }
        if (::AudioUnitInitialize(unit_) != noErr) { err_ = "AudioUnitInitialize 失败"; close(); return false; }

        scratch_.resize((size_t)channels_ * 4096);
        fifo_.reset((size_t)((double)rate_ * cfg_.bufferMs / 1000.0), channels_);
        opened_ = true;
        return true;
    }

    bool start() {
        if (isNull_) { running_ = true; nullTh_ = std::thread(&CoreAudioInput::null_worker, this); return true; }
        if (!opened_ || running_) return false;
        if (::AudioOutputUnitStart(unit_) != noErr) { err_ = "AudioOutputUnitStart 失败"; return false; }
        running_ = true;
        return true;
    }
    bool stop() {
        if (!running_) return false;
        running_ = false;
        if (isNull_) { if (nullTh_.joinable()) nullTh_.join(); return true; }
        if (unit_) ::AudioOutputUnitStop(unit_);
        return true;
    }
    void close() {
        stop();
        if (unit_) { ::AudioUnitUninitialize(unit_); ::AudioComponentInstanceDispose(unit_); unit_ = nullptr; }
        opened_ = false; isNull_ = false;
    }

    size_t read_available(float* dst, size_t maxFrames) {
        if (isNull_) return null_read(dst, maxFrames);
        return fifo_.read_available(dst, maxFrames);
    }
    uint32_t rate() const { return rate_; }
    int channels() const { return channels_; }
    int bits() const { return 32; }
    bool is_null() const { return isNull_; }
    bool is_running() const { return running_; }
    double water_level() const { return fifo_.water_level(); }
    uint64_t overflow_count() const { return fifo_.overflow_count(); }
    uint64_t underflow_count() const { return fifo_.underflow_count(); }
    size_t total_captured_frames() const { return total_.load(); }
    const std::string& last_error() const { return err_; }

private:
    OSStatus pull(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 frames) {
        if (frames > 4096) frames = 4096;
        AudioBufferList abl{};
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = (UInt32)channels_;
        abl.mBuffers[0].mDataByteSize = frames * sizeof(float) * (UInt32)channels_;
        abl.mBuffers[0].mData = scratch_.data();
        const OSStatus st = ::AudioUnitRender(unit_, flags, ts, 1, frames, &abl);
        if (st != noErr) return st;
        fifo_.push(scratch_.data(), frames);
        total_ += frames;
        return noErr;
    }
    // 模拟源：1 kHz、amp 线性幅（默认 0.001 = -60 dBFS，铁律 1）；按实时节奏
    void null_worker() {
        const double omega = 2.0 * 3.14159265358979323846 * cfg_.injectFreq / (double)rate_;
        size_t n = 0;
        std::vector<float> pkt(480 * (size_t)channels_);
        while (running_.load() && (cfg_.targetFrames == 0 || n < cfg_.targetFrames)) {
            for (size_t i = 0; i < 480; ++i)
                for (int c = 0; c < channels_; ++c)
                    pkt[i * (size_t)channels_ + c] =
                        (float)(cfg_.injectAmp * std::sin(omega * (double)(n + i)));
            fifo_.push(pkt.data(), 480);
            total_ += 480;
            n += 480;
            if (cfg_.paced) std::this_thread::sleep_for(std::chrono::microseconds(480 * 1000000LL / (long long)rate_));
        }
    }
    size_t null_read(float* dst, size_t maxFrames) { return fifo_.read_available(dst, maxFrames); }

    MacCaptureConfig cfg_;
    AudioUnit unit_ = nullptr;
    AudioDeviceID dev_ = kAudioObjectUnknown;
    std::vector<float> scratch_;
    detail::CaptureFifo fifo_;
    std::thread nullTh_;
    std::atomic<bool> running_{false};
    std::atomic<size_t> total_{0};
    bool opened_ = false, isNull_ = false;
    uint32_t rate_ = 48000;
    int channels_ = 2;
    std::string err_;
};

} // namespace rta::platform
