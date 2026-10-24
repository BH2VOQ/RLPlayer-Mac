// platform/macos/audio_out_coreaudio.h — audio_out.h 的 CoreAudio 实现
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
#include <mutex>
#include <string>
#include <vector>

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

inline bool set_hog_mode(AudioDeviceID dev, bool on) {
    pid_t pid = on ? ::getpid() : 0;
    AudioObjectPropertyAddress addr{kAudioDevicePropertyHogMode,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &addr)) return false;
    const OSStatus st = ::AudioObjectSetPropertyData(dev, &addr, 0, nullptr, sizeof(pid), &pid);
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

        // 1) 抢占 Hog Mode（独占）。失败不致命，但要如实降级为"非 bit-perfect"。
        hogged_ = detail::set_hog_mode(device_, true) && detail::is_hogged_by_us(device_);

        // 2) 按源格式设置设备物理格式 —— 这是 bit-perfect 的关键
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
            device_ = kAudioObjectUnknown;
            return false;
        }

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
        if (space == 0) return 0;                       // 满：部分写语义，返回 0 让调用方稍后重试
        const size_t n = frames < space ? frames : space;

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

    void set_gain(double linear) override { gain_ = linear; }

    bool bit_perfect() const override {
        // bit-perfect 的充分必要条件（PLATFORM.md §5.1）：
        //   独占(Hog) + 设备物理格式 == 源格式 + 增益 1.0 + 无任何 DSP
        // 本层只能保证前三项；DSP 是否启用由引擎层决定并另行显示。
        return opened_ && hogged_ && gain_ == 1.0;
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

        size_t i = 0;
        for (; i < take && i < out_frames; ++i) {
            const int32_t* src = &ring_[((read_pos_ + i) % capacity) * ch];
            uint8_t* dst = out + i * frame_bytes;
            for (size_t c = 0; c < ch; ++c) {
                const int32_t s = src[c];
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
        write_pos_ = read_pos_ = 0;
        ring_.clear();
        ring_frames_ = 0;
        frames_written_ = 0;
        frames_rendered_.store(0);
        underruns_.store(0);
        buffer_frames_ = 0;
    }

    std::mutex mu_;
    AudioUnit unit_ = nullptr;
    AudioDeviceID device_ = kAudioObjectUnknown;
    uint32_t rate_ = 0;
    int bits_ = 0;
    int channels_ = 0;
    double buffer_ms_ = 100.0;
    double gain_ = 1.0;
    bool opened_ = false;
    bool initialized_ = false;
    bool running_ = false;
    bool paused_ = false;
    bool hogged_ = false;
    size_t buffer_frames_ = 0;
    size_t frames_written_ = 0;

    // 环形缓冲（帧）
    std::vector<int32_t> ring_;
    size_t ring_frames_ = 0;
    size_t write_pos_ = 0;
    size_t read_pos_ = 0;
    std::atomic<uint64_t> underruns_{0};
    std::atomic<size_t> frames_rendered_{0};

    OutputError err_class_ = OutputError::None;
    std::string err_text_;
};

} // namespace rta::platform
