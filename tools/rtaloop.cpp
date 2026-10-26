// rtaloop.cpp — CoreAudio 回环逐位比对工具（PLATFORM.md §13.9.5 未解决项 1/3 的正面强攻）
//
// 为什么需要它：
//   test_coreaudio 只能证明"帧被设备消费了"（frames_rendered 增长），证明不了
//   【样本值没被改动】。真正的证明需要把送进设备的样本录回来逐位比对。
//   macOS 没有虚拟回环驱动也能做：14.4+ 的 Aggregate Tap（系统官方机制，
//   ScreenCaptureKit 同款）可以把"其它进程播给某设备的声音"变成聚合设备的
//   输入流。播放端与抓录端是两个进程，恰好绕开"tap 不抓自己进程"的语义。
//
// 两条回环路径（互补）：
//   A. record-tap：聚合设备 + tap 抓【物理设备】（Pocket Master，真 USB）。
//      证明：我们交出去的采样值 == 设备混音节点上的采样值。
//      数值链：int16/24/32 ->（AUHAL 换算，|v|<2^24 时精确）-> float32 混音
//              -> tap 抓到 float32 -> *2^(bits-1) 取整 == 原整数（逐位）。
//   B. record-input：虚拟设备（Oray）自带输入侧，播到输出、从输入录回，
//      走完整驱动环。若驱动内部透明则同样逐位；若不透明（重采样/缩放），
//      如实报告特征，不硬凑判据（铁律 3）。
//
// 🔴 铁律 1：测试序列峰值 −60 dBFS（16bit=±32 LSB / 24bit=±8388 / 32bit=±2147483），
//    全程几乎不可闻；每段播放前打印横幅；单段时长由 --seconds 控制，默认 ≤3 秒。
//
// 判据设计（铁律 3：测对东西）：
//   * 播放端必须走【被测后端】platform::create_audio_output()，不是绕开它另写播放
//   * 序列 = Barker-13 前导（对齐用）+ xorshift32 确定性伪随机体（每个声道独立种子），
//     期望文件就是喂给 write() 的那份内存，不存在"重算一遍可能不一样"
//   * 比对前先检查：前导之前全是 0（没有别的进程在灌声音，混音污染会当场暴露）；
//     序列结束后也全是 0
//   * 逐样本整数域严格相等；任何 ±1 LSB 的差都算失败并报位置与数值
//   * 若所有差都是同一比例因子（音量 ≠ 1.0 的特征），报告该因子而不是硬判失败
//
// 用法：
//   rtaloop info
//   rtaloop play    --device 99 --bits 16 [--rate 44100] [--seconds 3] --out exp.pcm [--shared]
//   rtaloop record-tap   --device 99 --seconds 5 --out cap.pcm
//   rtaloop record-input --device 72 --seconds 5 --out cap.pcm
//   rtaloop compare --expected exp.pcm --captured cap.pcm --bits 16
//   rtaloop hogprobe --device 99 --seconds 3
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <map>
#include <string>
#include <thread>
#include <vector>

#include "platform/audio_out_factory.h"

using namespace rta::platform;

// rtaloop_tap.mm 里的 ObjC++ 包装（CATapDescription 纯 C++ 够不着，见该文件头注）
extern "C" bool rl_create_process_tap(const char* deviceUidUtf8, uint32_t* outTapId,
                                      char* outTapUid, size_t outTapUidLen);
extern "C" void rl_destroy_process_tap(uint32_t tapId);

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
static std::string cfstr(CFStringRef s) {
    if (!s) return "";
    const CFIndex len = ::CFStringGetLength(s);
    const CFIndex max = ::CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
    std::string out((size_t)max, '\0');
    if (!::CFStringGetCString(s, out.data(), max, kCFStringEncodingUTF8)) return "";
    out.resize(std::strlen(out.c_str()));
    return out;
}

static std::string device_name(AudioDeviceID dev) {
    CFStringRef name = nullptr;
    UInt32 size = sizeof(name);
    AudioObjectPropertyAddress addr{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &name) != noErr || !name)
        return "?";
    std::string s = cfstr(name);
    ::CFRelease(name);
    return s;
}

static std::string device_uid(AudioDeviceID dev) {
    CFStringRef uid = nullptr;
    UInt32 size = sizeof(uid);
    AudioObjectPropertyAddress addr{kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &uid) != noErr || !uid)
        return "";
    std::string s = cfstr(uid);
    ::CFRelease(uid);
    return s;
}

static AudioDeviceID resolve_device(const std::string& id) {
    if (id.empty()) {
        AudioObjectPropertyAddress addr{kAudioHardwarePropertyDefaultOutputDevice,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        AudioDeviceID dev = kAudioObjectUnknown;
        UInt32 size = sizeof(dev);
        if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, &dev) != noErr)
            return kAudioObjectUnknown;
        return dev;
    }
    char* end = nullptr;
    const unsigned long v = std::strtoul(id.c_str(), &end, 10);
    if (end && *end == '\0' && v != 0) return (AudioDeviceID)v;
    AudioObjectPropertyAddress addr{kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size) != noErr)
        return kAudioObjectUnknown;
    const size_t n = size / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> devs(n);
    if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, devs.data()) != noErr)
        return kAudioObjectUnknown;
    for (AudioDeviceID d : devs)
        if (device_name(d) == id) return d;
    return kAudioObjectUnknown;
}

static std::vector<AudioDeviceID> all_devices() {
    AudioObjectPropertyAddress addr{kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size) != noErr)
        return {};
    std::vector<AudioDeviceID> devs(size / sizeof(AudioDeviceID));
    if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, devs.data()) != noErr)
        return {};
    return devs;
}

// 某个 scope（输入/输出）方向的流列表
static std::vector<AudioStreamID> device_streams(AudioDeviceID dev, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &size) != noErr) return {};
    std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, streams.data()) != noErr) return {};
    return streams;
}

static bool stream_virtual_format(AudioStreamID st, AudioStreamBasicDescription* out) {
    AudioObjectPropertyAddress addr{kAudioStreamPropertyVirtualFormat,
                                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(*out);
    return ::AudioObjectGetPropertyData(st, &addr, 0, nullptr, &size, out) == noErr;
}

static std::string fmt_desc(const AudioStreamBasicDescription& f) {
    char buf[128];
    const bool fl = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool si = (f.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    std::snprintf(buf, sizeof buf, "%gHz %uch %ubits %s", f.mSampleRate, f.mChannelsPerFrame,
                  f.mBitsPerChannel, fl ? "float" : (si ? "sint" : "uint"));
    return buf;
}

// 设备当前标称采样率
static double device_rate(AudioDeviceID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyNominalSampleRate,
                                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Float64 r = 0;
    UInt32 size = sizeof(r);
    if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &size, &r) != noErr) return 0;
    return r;
}

// ---------------------------------------------------------------------------
// 期望/抓录文件的公共格式：RTLP 头 + 原始交错样本
// ---------------------------------------------------------------------------
#pragma pack(push, 1)
struct PcmHead {
    char magic[4]{'R', 'T', 'L', 'P'};
    uint32_t version = 1;
    uint32_t kind;       // 0=int32 期望（低位对齐源位深）；1=float32 抓录；2=int32 抓录
    uint32_t rate = 0;
    uint32_t channels = 0;
    uint32_t frames = 0;
    int32_t bits = 0;    // 源位深（期望文件）；抓录文件记录对标位深
};
#pragma pack(pop)

static bool write_pcm(const char* path, uint32_t kind, uint32_t rate, uint32_t ch, uint32_t frames,
                      int bits, const void* data, size_t bytes) {
    FILE* f = std::fopen(path, "wb");
    if (!f) return false;
    PcmHead h;
    h.kind = kind; h.rate = rate; h.channels = ch; h.frames = frames; h.bits = bits;
    if (std::fwrite(&h, sizeof h, 1, f) != 1 || std::fwrite(data, 1, bytes, f) != bytes) {
        std::fclose(f);
        return false;
    }
    std::fclose(f);
    return true;
}

// ---------------------------------------------------------------------------
// 确定性测试序列（铁律 1：−60 dBFS 量级）
// ---------------------------------------------------------------------------
static const int kBarker13[13] = {1, 1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1};
static constexpr size_t kPreambleFrames = 64;

static int amp_for_bits(int bits) {
    switch (bits) {
        case 16: return 32;         // −60.2 dBFS
        case 24: return 8388;       // −60.0 dBFS
        default: return 2147483;    // 32bit：−60.0 dBFS，且 < 2^24（float32 精确域）
    }
}

static inline uint32_t xs32(uint32_t& s) {
    s ^= s << 13; s ^= s >> 17; s ^= s << 5;
    return s;
}

// 生成交错 int32 序列（低位对齐到 bits 满量程）
static std::vector<int32_t> gen_pattern(size_t frames, int channels, int bits) {
    const int amp = amp_for_bits(bits);
    std::vector<int32_t> buf(frames * (size_t)channels);
    std::vector<uint32_t> seed((size_t)channels);
    for (int c = 0; c < channels; ++c)
        seed[(size_t)c] = 0x4A37D9C1u ^ (uint32_t)(bits * 2654435761u) ^ (uint32_t)(c + 1) * 0x9E3779B9u;
    for (size_t i = 0; i < frames; ++i) {
        for (int c = 0; c < channels; ++c) {
            int32_t v;
            if (i < kPreambleFrames) {
                const int b = kBarker13[i % 13];
                v = (int32_t)(b * amp) * (c == 0 ? 1 : -1);   // R 声道取反，抓到单声道也能对上
            } else {
                const uint32_t span = (uint32_t)(2 * amp + 1);
                v = (int32_t)((int64_t)(xs32(seed[(size_t)c]) % span) - amp);
            }
            buf[i * (size_t)channels + (size_t)c] = v;
        }
    }
    return buf;
}

// ---------------------------------------------------------------------------
// info：只读枚举（决定回环路径用）
// ---------------------------------------------------------------------------
static int cmd_info() {
    std::printf("设备清单（只读，不碰任何状态）\n");
    for (AudioDeviceID d : all_devices()) {
        const std::string name = device_name(d);
        const auto outs = device_streams(d, kAudioObjectPropertyScopeOutput);
        const auto ins = device_streams(d, kAudioObjectPropertyScopeInput);
        AudioObjectPropertyAddress hog{kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
        pid_t owner = -1;
        UInt32 sz = sizeof(owner);
        const bool hasHog = ::AudioObjectHasProperty(d, &hog) &&
                            ::AudioObjectGetPropertyData(d, &hog, 0, nullptr, &sz, &owner) == noErr;
        std::printf("  [%u] %s  uid=%s\n", d, name.c_str(), device_uid(d).c_str());
        std::printf("      输出流 %zu 个，输入流 %zu 个，Hog=%s(owner=%d) 当前标称率=%g\n",
                    outs.size(), ins.size(), hasHog ? "支持" : "不支持", (int)owner, device_rate(d));
        for (size_t i = 0; i < outs.size() && i < 3; ++i) {
            AudioStreamBasicDescription f{};
            if (stream_virtual_format(outs[i], &f))
                std::printf("      out#%zu: %s\n", i, fmt_desc(f).c_str());
        }
        for (size_t i = 0; i < ins.size() && i < 3; ++i) {
            AudioStreamBasicDescription f{};
            if (stream_virtual_format(ins[i], &f))
                std::printf("      in #%zu: %s\n", i, fmt_desc(f).c_str());
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// play：经【被测后端】播放确定性序列，落盘期望文件
// ---------------------------------------------------------------------------
static void banner(const std::string& dev, double seconds, int bits, bool shared) {
    std::printf("\n  ┌────────────────────────────────────────────────────────────┐\n");
    std::printf("  │ ⚠️  即将打开音频设备播放测试序列                          │\n");
    std::printf("  │ 设备: %-52s │\n", dev.c_str());
    std::printf("  │ 时长: %.1fs  峰值电平: -60 dBFS（几乎不可闻）%s\n", seconds,
                shared ? " 共享模式（不抢独占）" : " 独占模式会静音系统其他声音");
    std::printf("  │ 位深: %-52d │\n", bits);
    std::printf("  └────────────────────────────────────────────────────────────┘\n");
    std::fflush(stdout);
}

static int cmd_play(const std::string& device, uint32_t rate, int bits, double seconds,
                    const std::string& outPath, bool shared) {
    auto out = create_audio_output();
    if (!out) { std::printf("错误：本平台没有 AudioOutput 适配器\n"); return 1; }

    const AudioDeviceID dev = resolve_device(device);
    if (dev == kAudioObjectUnknown) { std::printf("错误：找不到设备 %s\n", device.c_str()); return 1; }
    if (rate == 0) rate = (uint32_t)device_rate(dev);
    if (rate == 0) rate = 44100;

    banner(device_name(dev) + " (" + std::to_string(dev) + ")", seconds, bits, shared);
    std::printf("  本进程 PID=%d（供 hogprobe 跨进程核对）\n", (int)::getpid());

    const size_t total = (size_t)((double)rate * seconds);
    const std::vector<int32_t> pattern = gen_pattern(total, 2, bits);

    OpenSpec sp;
    sp.deviceId = std::to_string(dev);
    sp.rate = rate;
    sp.bits = bits;
    sp.channels = 2;
    sp.bufferMs = 100.0;
    sp.shared = shared;
    if (!out->open(sp)) {
        std::printf("  open 失败 [%d]: %s\n", (int)out->last_error_class(), out->last_error().c_str());
        return 1;
    }
    // 先把环形缓冲灌满再 start，消除启动期欠载（上一轮实测欠载 1 次的真因）
    const size_t chunk = out->buffer_frames() ? out->buffer_frames() : 512;
    size_t fed = 0;
    while (fed < total) {
        const size_t n = std::min(chunk, total - fed);
        const size_t w = out->write(pattern.data() + fed * 2, n);
        fed += w;
        if (w == 0) break;   // 环形缓冲已满，先 start
    }
    if (!out->start()) {
        std::printf("  start 失败: %s\n", out->last_error().c_str());
        out->close();
        return 1;
    }
    const auto t0 = std::chrono::steady_clock::now();
    while (fed < total) {
        const size_t n = std::min(chunk, total - fed);
        const size_t w = out->write(pattern.data() + fed * 2, n);
        fed += w;
        if (w == 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > seconds + 15.0) {
            std::printf("  错误：喂入超时（fed=%zu/%zu）\n", fed, total);
            out->close();
            return 1;
        }
    }
    // 等设备把最后一段真实渲染掉（不是只进了环形缓冲）
    const auto dl = t0 + std::chrono::milliseconds((int)(seconds * 1000) + 2500);
    while (out->frames_rendered() < total && std::chrono::steady_clock::now() < dl)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    std::this_thread::sleep_for(std::chrono::milliseconds(150));

    std::printf("  结果：写入 %zu 帧，设备渲染 %zu 帧，欠载 %llu 次，bit_perfect=%d（%s）\n",
                fed, out->frames_rendered(), (unsigned long long)out->underruns(),
                out->bit_perfect() ? 1 : 0,
                shared ? "共享模式，false 属预期" : "独占+物理格式");
    out->close();

    if (!write_pcm(outPath.c_str(), 0, rate, 2, (uint32_t)total, bits, pattern.data(),
                   pattern.size() * sizeof(int32_t))) {
        std::printf("错误：写期望文件失败 %s\n", outPath.c_str());
        return 1;
    }
    std::printf("  期望文件: %s（%u Hz / %d bit / %u 帧 / Barker+xorshift）\n",
                outPath.c_str(), rate, bits, (uint32_t)total);
    return 0;
}

// ---------------------------------------------------------------------------
// 抓录公共部分：IOProc 把输入侧写进大缓冲（float 或 int32 域，按流格式）
// ---------------------------------------------------------------------------
struct CapCtx {
    std::vector<float> f;
    std::vector<int32_t> i;
    uint32_t ch = 0;
    uint32_t bytesPerSample = 4;
    bool isFloat = true;
    std::atomic<bool> gotInput{false};
    std::atomic<size_t> frames{0};
};

static OSStatus io_proc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* in,
                        const AudioTimeStamp*, AudioBufferList* out, const AudioTimeStamp*, void* ref) {
    auto* ctx = static_cast<CapCtx*>(ref);
    if (in && in->mNumberBuffers > 0) {
        ctx->gotInput = true;
        if (in->mNumberBuffers == 1) {          // 交错
            const UInt32 ch = in->mBuffers[0].mNumberChannels;
            if (ch && ctx->ch) {
                const size_t frames = in->mBuffers[0].mDataByteSize / (ctx->bytesPerSample * ch);
                const uint8_t* p = static_cast<const uint8_t*>(in->mBuffers[0].mData);
                for (size_t n = 0; n < frames; ++n)
                    for (UInt32 c = 0; c < ch; ++c, p += ctx->bytesPerSample) {
                        if (ctx->isFloat) {
                            float v; std::memcpy(&v, p, 4); ctx->f.push_back(v);
                        } else {
                            int32_t v; std::memcpy(&v, p, 4); ctx->i.push_back(v);
                        }
                    }
                ctx->frames += frames;
            }
        } else {                                 // 非交错：每缓冲一声道
            const size_t frames = in->mBuffers[0].mDataByteSize / ctx->bytesPerSample;
            const UInt32 ch = in->mNumberBuffers;
            const size_t base = ctx->isFloat ? ctx->f.size() : ctx->i.size();
            if (ctx->isFloat) ctx->f.resize(base + frames * ch);
            else ctx->i.resize(base + frames * ch);
            for (UInt32 b = 0; b < ch; ++b) {
                const uint8_t* p = static_cast<const uint8_t*>(in->mBuffers[b].mData);
                for (size_t n = 0; n < frames; ++n, p += ctx->bytesPerSample) {
                    if (ctx->isFloat) {
                        float v; std::memcpy(&v, p, 4); ctx->f[base + n * ch + b] = v;
                    } else {
                        int32_t v; std::memcpy(&v, p, 4); ctx->i[base + n * ch + b] = v;
                    }
                }
            }
            ctx->frames += frames;
        }
    }
    if (out)   // 输出侧给静音：0 混入设备混音不改变任何人（tap 抓的是目标设备自己的混音）
        for (UInt32 b = 0; b < out->mNumberBuffers; ++b)
            if (out->mBuffers[b].mData) std::memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    return noErr;
}

// 查询一个设备的输入侧虚拟格式（取第一条输入流）。返回 false = 无输入流。
static bool input_format(AudioDeviceID dev, AudioStreamBasicDescription* f, uint32_t* nStreams) {
    const auto streams = device_streams(dev, kAudioObjectPropertyScopeInput);
    *nStreams = (uint32_t)streams.size();
    if (streams.empty()) return false;
    return stream_virtual_format(streams[0], f);
}

static int capture_device(AudioDeviceID dev, double seconds, const std::string& outPath,
                          const char* what) {
    AudioStreamBasicDescription f{};
    uint32_t nStreams = 0;
    if (!input_format(dev, &f, &nStreams)) {
        std::printf("错误：%s 没有输入流，无法抓录\n", what);
        return 1;
    }
    const bool isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isSInt32 = !isFloat && (f.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
                          f.mBitsPerChannel == 32;
    if (!isFloat && !isSInt32) {
        // 如实报告：只支持 float32 / sint32 两种抓录域，别的格式不硬猜
        std::printf("错误：%s 输入格式不支持（%s；本工具只处理 float32/sint32）\n", what,
                    fmt_desc(f).c_str());
        return 1;
    }
    std::printf("  %s 输入流 %u 条，虚拟格式 %s\n", what, nStreams, fmt_desc(f).c_str());

    CapCtx ctx;
    ctx.ch = f.mChannelsPerFrame;
    ctx.bytesPerSample = f.mBytesPerFrame / (f.mChannelsPerFrame ? f.mChannelsPerFrame : 1);
    ctx.isFloat = isFloat;

    AudioDeviceIOProcID proc = nullptr;
    OSStatus st = ::AudioDeviceCreateIOProcID(dev, &io_proc, &ctx, &proc);
    if (st != noErr || !proc) {
        std::printf("错误：CreateIOProcID 失败 (%d)\n", (int)st);
        return 1;
    }
    st = ::AudioDeviceStart(dev, proc);
    if (st != noErr) {
        std::printf("错误：AudioDeviceStart 失败 (%d)——设备可能被其它进程独占\n", (int)st);
        ::AudioDeviceDestroyIOProcID(dev, proc);
        return 1;
    }
    std::printf("  抓录中 %.1f 秒……\n", seconds);
    std::fflush(stdout);
    const auto t0 = std::chrono::steady_clock::now();
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < seconds)
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    ::AudioDeviceStop(dev, proc);
    ::AudioDeviceDestroyIOProcID(dev, proc);

    const size_t frames = ctx.frames.load();
    const double measured = (double)frames / seconds;
    std::printf("  抓到 %zu 帧（实测 %.0f 帧/秒，标称 %g），有输入回调=%d\n", frames, measured,
                f.mSampleRate, ctx.gotInput.load() ? 1 : 0);
    if (frames == 0) { std::printf("错误：一帧都没抓到\n"); return 1; }

    const uint32_t kind = isFloat ? 1u : 2u;
    const void* data = isFloat ? (const void*)ctx.f.data() : (const void*)ctx.i.data();
    const size_t bytes = frames * ctx.ch * 4;
    if (!write_pcm(outPath.c_str(), kind, (uint32_t)f.mSampleRate, ctx.ch, (uint32_t)frames, 0,
                   data, bytes)) {
        std::printf("错误：写抓录文件失败 %s\n", outPath.c_str());
        return 1;
    }
    std::printf("  抓录文件: %s\n", outPath.c_str());
    return 0;
}

// ---------------------------------------------------------------------------
// record-input：直接抓某设备的输入侧（虚拟设备回环用）
// ---------------------------------------------------------------------------
static int cmd_record_input(const std::string& device, double seconds, const std::string& outPath) {
    const AudioDeviceID dev = resolve_device(device);
    if (dev == kAudioObjectUnknown) { std::printf("错误：找不到设备 %s\n", device.c_str()); return 1; }
    std::printf("record-input：设备 [%u] %s\n", dev, device_name(dev).c_str());
    return capture_device(dev, seconds, outPath, "该设备");
}

// ---------------------------------------------------------------------------
// record-tap：聚合设备 + tap，抓"其它进程播给目标设备的声音"
// ---------------------------------------------------------------------------
struct VolRestore {
    AudioDeviceID dev;
    int element;
    float vol;
    bool isMute;
    UInt32 mute;
};

static int cmd_record_tap(const std::string& device, double seconds, const std::string& outPath) {
    const AudioDeviceID dev = resolve_device(device);
    if (dev == kAudioObjectUnknown) { std::printf("错误：找不到设备 %s\n", device.c_str()); return 1; }
    const std::string uid = device_uid(dev);
    if (uid.empty()) { std::printf("错误：设备 %u 拿不到 UID\n", dev); return 1; }
    std::printf("record-tap：目标设备 [%u] %s（uid=%s）\n", dev, device_name(dev).c_str(), uid.c_str());

    // 音量/静音归一（tap 抓的是设备混音；软件音量 != 1.0 会表现为统一比例缩放）。
    // 记住原值，结束恢复。改的是 −60 dBFS 测试音的电平策略参数，全程不可闻。
    std::vector<VolRestore> restore;
    for (int element = 0; element <= 2; ++element) {
        for (int isMute = 0; isMute <= 1; ++isMute) {
            AudioObjectPropertyAddress addr{isMute ? kAudioDevicePropertyMute
                                                    : kAudioDevicePropertyVolumeScalar,
                                            kAudioObjectPropertyScopeOutput, (AudioObjectPropertyElement)element};
            if (!::AudioObjectHasProperty(dev, &addr)) continue;
            if (isMute) {
                UInt32 m = 0; UInt32 sz = sizeof(m);
                if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &sz, &m) != noErr) continue;
                if (m == 0) continue;
                UInt32 zero = 0;
                if (::AudioObjectSetPropertyData(dev, &addr, 0, nullptr, sizeof(m), &zero) == noErr) {
                    restore.push_back({dev, element, 0.f, true, m});
                    std::printf("  静音已临时关闭（元素 %d，原值 %u），结束后恢复\n", element, m);
                }
            } else {
                Float32 v = 0; UInt32 sz = sizeof(v);
                if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &sz, &v) != noErr) continue;
                if (v >= 0.999f && v <= 1.001f) continue;
                Float32 one = 1.0f;
                if (::AudioObjectSetPropertyData(dev, &addr, 0, nullptr, sizeof(v), &one) == noErr) {
                    restore.push_back({dev, element, v, false, 0});
                    std::printf("  音量 %.3f -> 1.0（元素 %d），结束后恢复原值\n", v, element);
                }
            }
        }
    }

    // 先建 Process Tap（macOS 14.2+ 公开机制；抓"设备上所有进程"的声音）。
    // ⚠️ 聚合设备 taps 数组引用的是【tap 的 UUID】，不是设备 UID——
    //    之前直接放设备 UID，聚合设备永远不出现输入流（实测教训）。
    uint32_t tapId = 0;
    char tapUid[64] = {0};
    if (!rl_create_process_tap(uid.c_str(), &tapId, tapUid, sizeof tapUid)) {
        std::printf("错误：创建 Process Tap 失败——macOS < 14.2、无录音权限（TCC）或设备不支持\n");
        for (const auto& r : restore) {
            AudioObjectPropertyAddress addr{r.isMute ? kAudioDevicePropertyMute
                                                      : kAudioDevicePropertyVolumeScalar,
                                            kAudioObjectPropertyScopeOutput,
                                            (AudioObjectPropertyElement)r.element};
            if (r.isMute) ::AudioObjectSetPropertyData(r.dev, &addr, 0, nullptr, sizeof(r.mute), &r.mute);
            else ::AudioObjectSetPropertyData(r.dev, &addr, 0, nullptr, sizeof(r.vol), &r.vol);
        }
        return 1;
    }
    std::printf("  Process Tap 已创建：id=%u uuid=%s\n", tapId, tapUid);

    // 组聚合设备：main = 目标设备，taps = [上面的 tap]
    // ⚠️ kAudioAggregateDevice*Key / kAudioSubTapUIDKey 是【C 字符串宏】（"name"/"uid"/…），
    //    不是 CFStringRef 常量——直接当 key 传给 CFDictionarySetValue 会把 char* 当
    //    CFTypeRef retain，当场 SIGSEGV（objc_msgSend 到字符串字节上）。必须 CFSTR() 包一层。
    CFStringRef uidStr = ::CFStringCreateWithCString(kCFAllocatorDefault, uid.c_str(),
                                                     kCFStringEncodingUTF8);
    CFStringRef tapUidStr = ::CFStringCreateWithCString(kCFAllocatorDefault, tapUid,
                                                        kCFStringEncodingUTF8);
    CFMutableDictionaryRef desc = ::CFDictionaryCreateMutable(kCFAllocatorDefault, 8,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef aggUid = ::CFStringCreateWithCString(kCFAllocatorDefault, "rlplayer.rtaloop.tap",
                                                     kCFStringEncodingUTF8);
    ::CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceNameKey), CFSTR("RLPlayer rtaloop"));
    ::CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceUIDKey), aggUid);
    ::CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceMainSubDeviceKey), uidStr);
    ::CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceIsPrivateKey), kCFBooleanTrue);
    CFMutableDictionaryRef tap = ::CFDictionaryCreateMutable(kCFAllocatorDefault, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    ::CFDictionarySetValue(tap, CFSTR(kAudioSubTapUIDKey), tapUidStr);
    CFTypeRef tapArr[1] = {tap};
    CFArrayRef taps = ::CFArrayCreate(kCFAllocatorDefault, tapArr, 1, &kCFTypeArrayCallBacks);
    ::CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceTapListKey), taps);

    AudioDeviceID agg = kAudioObjectUnknown;
    OSStatus st = ::AudioHardwareCreateAggregateDevice(desc, &agg);
    ::CFRelease(taps); ::CFRelease(tap); ::CFRelease(desc); ::CFRelease(aggUid);
    ::CFRelease(tapUidStr); ::CFRelease(uidStr);
    if (st != noErr) {
        std::printf("错误：创建聚合设备失败 (%d)\n", (int)st);
        rl_destroy_process_tap(tapId);
        for (const auto& r : restore) {   // 尽力恢复
            AudioObjectPropertyAddress addr{r.isMute ? kAudioDevicePropertyMute
                                                      : kAudioDevicePropertyVolumeScalar,
                                            kAudioObjectPropertyScopeOutput,
                                            (AudioObjectPropertyElement)r.element};
            if (r.isMute) ::AudioObjectSetPropertyData(r.dev, &addr, 0, nullptr, sizeof(r.mute), &r.mute);
            else ::AudioObjectSetPropertyData(r.dev, &addr, 0, nullptr, sizeof(r.vol), &r.vol);
        }
        return 1;
    }

    // 等聚合设备的输入流（tap 流）出现
    bool ready = false;
    for (int i = 0; i < 60 && !ready; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        ready = !device_streams(agg, kAudioObjectPropertyScopeInput).empty();
    }
    int rc = 1;
    if (!ready) {
        std::printf("错误：聚合设备 3 秒内没有出现输入流（tap 未生效）\n");
    } else {
        rc = capture_device(agg, seconds, outPath, "聚合设备");
    }

    ::AudioHardwareDestroyAggregateDevice(agg);
    rl_destroy_process_tap(tapId);
    for (const auto& r : restore) {
        AudioObjectPropertyAddress addr{r.isMute ? kAudioDevicePropertyMute
                                                  : kAudioDevicePropertyVolumeScalar,
                                        kAudioObjectPropertyScopeOutput,
                                        (AudioObjectPropertyElement)r.element};
        if (r.isMute) ::AudioObjectSetPropertyData(r.dev, &addr, 0, nullptr, sizeof(r.mute), &r.mute);
        else ::AudioObjectSetPropertyData(r.dev, &addr, 0, nullptr, sizeof(r.vol), &r.vol);
    }
    if (!restore.empty()) std::printf("  音量/静音已恢复原值\n");
    return rc;
}

// ---------------------------------------------------------------------------
// compare：对齐 + 逐位比对
// ---------------------------------------------------------------------------
struct Loaded {
    PcmHead h{};
    std::vector<int64_t> v;   // 交错，已换到【源位深整数域】
};

static bool load_pcm(const char* path, int bits, Loaded* out) {
    FILE* f = std::fopen(path, "rb");
    if (!f) { std::printf("错误：打不开 %s\n", path); return false; }
    PcmHead h;
    if (std::fread(&h, sizeof h, 1, f) != 1 || std::memcmp(h.magic, "RTLP", 4) != 0) {
        std::printf("错误：%s 不是 RTLP 文件\n", path);
        std::fclose(f);
        return false;
    }
    const bool isExpected = h.kind == 0;
    const int srcBits = isExpected ? h.bits : bits;   // 抓录文件按 compare 指定的源位深换算
    const double scale = std::pow(2.0, srcBits - 1);
    const size_t n = (size_t)h.frames * h.channels;
    out->v.assign(n, 0);
    if (h.kind == 0) {
        std::vector<int32_t> buf(n);
        if (std::fread(buf.data(), 4, n, f) != n) { std::fclose(f); return false; }
        for (size_t i = 0; i < n; ++i) out->v[i] = buf[i];
    } else if (h.kind == 1) {
        std::vector<float> buf(n);
        if (std::fread(buf.data(), 4, n, f) != n) { std::fclose(f); return false; }
        for (size_t i = 0; i < n; ++i) out->v[i] = (int64_t)std::llround((double)buf[i] * scale);
    } else {
        std::vector<int32_t> buf(n);
        if (std::fread(buf.data(), 4, n, f) != n) { std::fclose(f); return false; }
        const double k = std::pow(2.0, 32 - srcBits);
        for (size_t i = 0; i < n; ++i) out->v[i] = (int64_t)std::llround((double)buf[i] / k);
    }
    std::fclose(f);
    out->h = h;
    return true;
}

static int cmd_compare(const std::string& expPath, const std::string& capPath, int bits) {
    Loaded exp, cap;
    if (!load_pcm(expPath.c_str(), bits, &exp)) return 1;
    if (!load_pcm(capPath.c_str(), bits, &cap)) return 1;
    const uint32_t ch = exp.h.channels;
    if (cap.h.channels < ch) {
        std::printf("错误：抓录声道 %u < 期望声道 %u\n", cap.h.channels, ch);
        return 1;
    }
    if (exp.h.rate != cap.h.rate) {
        std::printf("错误：采样率不一致（期望 %u，抓录 %u）——路径上有重采样，无法逐位比对\n",
                    exp.h.rate, cap.h.rate);
        return 1;
    }
    std::printf("比对：期望 %u 帧/%u Hz/%d bit，抓录 %u 帧/%s\n", exp.h.frames, exp.h.rate, bits,
                cap.h.frames, cap.h.kind == 1 ? "float32" : "int32");

    const int64_t* E = exp.v.data();
    const int64_t* C = cap.v.data();
    const size_t capFrames = cap.h.frames;

    // 1) 用 Barker 前导找对齐（同时试 L/R 交换——抓录端声道序不保证）
    long long align = -1;
    int swapped = 0;
    for (int sw = 0; sw < 2 && align < 0; ++sw) {
        for (size_t f = 0; f + kPreambleFrames <= capFrames; ++f) {
            bool ok = true;
            for (size_t i = 0; i < kPreambleFrames && ok; ++i)
                for (uint32_t c = 0; c < ch && ok; ++c) {
                    const uint32_t cc = sw ? (ch - 1 - c) : c;
                    if (E[i * ch + c] != C[(f + i) * cap.h.channels + cc]) ok = false;
                }
            if (ok) { align = (long long)f; swapped = sw; break; }
        }
    }
    if (align < 0) {
        std::printf("FAIL：抓录里找不到 Barker 前导（信号没到抓录端，或数值被改）\n");
        size_t nz = 0, firstNz = SIZE_MAX;
        for (size_t i = 0; i < cap.v.size(); ++i)
            if (cap.v[i] != 0) { ++nz; if (firstNz == SIZE_MAX) firstNz = i; }
        std::printf("  抓录非零样本 %zu 个（%.2f%%），第一个非零在样本 %zu\n", nz,
                    100.0 * (double)nz / (double)cap.v.size(), firstNz == SIZE_MAX ? 0 : firstNz);
        return 1;
    }
    std::printf("对齐：前导位于抓录第 %lld 帧（%.1f ms 处）%s\n", align,
                1000.0 * (double)align / (double)cap.h.rate, swapped ? "，L/R 已交换" : "");

    // 2) 前导之前必须全是静音（否则有其它声音混入，比对无意义）
    size_t preNonzero = 0;
    for (long long f = 0; f < align; ++f)
        for (uint32_t c = 0; c < cap.h.channels; ++c)
            if (C[(size_t)f * cap.h.channels + c] != 0) ++preNonzero;
    if (preNonzero) std::printf("⚠️ 前导之前有 %zu 个非零样本（其它进程的声音混入了）\n", preNonzero);

    // 3) 逐位比对主体
    const size_t L = std::min<size_t>(exp.h.frames, capFrames - (size_t)align);
    size_t mism = 0, firstMism = SIZE_MAX;
    int64_t maxDiff = 0;
    double ratioSum = 0; size_t ratioN = 0;   // 检测统一比例因子（音量特征）
    for (size_t i = 0; i < L; ++i)
        for (uint32_t c = 0; c < ch; ++c) {
            const uint32_t cc = swapped ? (ch - 1 - c) : c;
            const int64_t e = E[i * ch + c];
            const int64_t v = C[(size_t)(align + (long long)i) * cap.h.channels + cc];
            if (e != v) {
                ++mism;
                if (firstMism == SIZE_MAX) firstMism = i * ch + c;
                const int64_t d = v > e ? v - e : e - v;
                if (d > maxDiff) maxDiff = d;
            }
            if (e != 0) { ratioSum += (double)v / (double)e; ++ratioN; }
        }
    std::printf("比对 %zu 帧 × %u 声道：不匹配 %zu 个，最大偏差 %lld LSB", L * ch, ch, mism,
                (long long)maxDiff);
    if (mism && ratioN) std::printf("，中位比例 %.6f", ratioSum / (double)ratioN);
    std::printf("\n");
    if (mism) {
        const size_t fr = firstMism / ch, c = firstMism % ch;
        const uint32_t cc = swapped ? (ch - 1 - c) : c;
        std::printf("  第一个不匹配：帧 %zu 声道 %zu：期望 %lld，抓到 %lld\n", fr, (size_t)c,
                    (long long)E[fr * ch + c],
                    (long long)C[(size_t)(align + (long long)fr) * cap.h.channels + cc]);
    }

    // 4) 序列结束之后应回到静音
    const size_t endF = (size_t)align + L;
    size_t postNonzero = 0;
    for (size_t f = endF; f < capFrames; ++f)
        for (uint32_t c = 0; c < cap.h.channels; ++c)
            if (C[f * cap.h.channels + c] != 0) ++postNonzero;
    if (postNonzero) std::printf("⚠️ 序列结束后有 %zu 个非零样本\n", postNonzero);

    const bool pass = mism == 0 && preNonzero == 0 && postNonzero == 0 &&
                      L >= exp.h.frames - 64;
    std::printf("%s（匹配 %zu/%u 帧，覆盖率 %.2f%%）\n", pass ? "PASS：逐位一致" : "FAIL", L,
                exp.h.frames, 100.0 * (double)L / (double)exp.h.frames);
    return pass ? 0 : 1;
}

// ---------------------------------------------------------------------------
// hogprobe：跨进程读 Hog Mode 归属（§13.9.5 未解决项 2 的独立探针）
// ---------------------------------------------------------------------------
static int cmd_hogprobe(const std::string& device, double seconds) {
    const AudioDeviceID dev = resolve_device(device);
    if (dev == kAudioObjectUnknown) { std::printf("错误：找不到设备 %s\n", device.c_str()); return 1; }
    std::printf("hogprobe：设备 [%u] %s，本进程 PID=%d，轮询 %.1f 秒\n", dev,
                device_name(dev).c_str(), (int)::getpid(), seconds);
    AudioObjectPropertyAddress addr{kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (!::AudioObjectHasProperty(dev, &addr)) {
        std::printf("该设备不支持 Hog Mode\n");
        return 1;
    }
    int sawOther = 0, sawNone = 0;
    const auto t0 = std::chrono::steady_clock::now();
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < seconds) {
        pid_t owner = -2;
        UInt32 sz = sizeof(owner);
        if (::AudioObjectGetPropertyData(dev, &addr, 0, nullptr, &sz, &owner) == noErr) {
            std::printf("  hog owner = %d %s\n", (int)owner,
                        owner == -1 ? "(无人独占)" : owner == ::getpid() ? "(本进程)" : "(其它进程)");
            if (owner >= 0 && owner != ::getpid()) ++sawOther;
            if (owner == -1) ++sawNone;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    std::printf("结论：观察到其它进程持有独占 %d 次、无独占 %d 次\n", sawOther, sawNone);
    return 0;
}

// ---------------------------------------------------------------------------
// loopback：同进程"独占播放 + 输入侧抓录"（虚拟设备用；Hog 按 PID 独占，
// 同进程的 IOProc 不受阻碍——这正是跨进程做不到的那条【完整独占路径】验证）
// 顺序：播放端 open（抢 Hog + 设物理格式）→ 同进程挂输入 IOProc → 预灌 → start → 喂完
// → 停抓录 → close（释放 Hog）。独占 open 失败时如实回退共享模式并标注。
// ---------------------------------------------------------------------------
static int run_loopback(AudioDeviceID dev, int bits, double seconds, bool shared,
                        const std::vector<int32_t>& pattern, uint32_t rate, size_t total,
                        CapCtx* ctx, AudioDeviceIOProcID* procOut, std::string* note) {
    auto out = create_audio_output();
    if (!out) { *note = "本平台没有 AudioOutput 适配器"; return 1; }
    OpenSpec sp;
    sp.deviceId = std::to_string(dev);
    sp.rate = rate; sp.bits = bits; sp.channels = 2; sp.bufferMs = 100.0; sp.shared = shared;
    if (!out->open(sp)) {
        *note = std::string(shared ? "open(共享)" : "open(独占)") + " 失败: " + out->last_error();
        return 1;
    }
    // 同进程抓录端（Hog 属主是本 PID）
    OSStatus st = ::AudioDeviceCreateIOProcID(dev, &io_proc, ctx, procOut);
    if (st != noErr || !*procOut) {
        out->close();
        *note = "同进程 CreateIOProcID 失败 (" + std::to_string((int)st) + ")——独占路径抓录受阻";
        return 1;
    }
    if (::AudioDeviceStart(dev, *procOut) != noErr) {
        ::AudioDeviceDestroyIOProcID(dev, *procOut); *procOut = nullptr;
        out->close();
        *note = "同进程 AudioDeviceStart 失败——独占路径抓录受阻";
        return 1;
    }
    // 预灌满环形缓冲再 start（消除启动期欠载）
    const size_t chunk = out->buffer_frames() ? out->buffer_frames() : 512;
    size_t fed = 0;
    while (fed < total) {
        const size_t n = std::min(chunk, total - fed);
        const size_t w = out->write(pattern.data() + fed * 2, n);
        fed += w;
        if (w == 0) break;
    }
    if (!out->start()) {
        *note = "start 失败: " + out->last_error();
        ::AudioDeviceStop(dev, *procOut); ::AudioDeviceDestroyIOProcID(dev, *procOut); *procOut = nullptr;
        out->close();
        return 1;
    }
    const auto t0 = std::chrono::steady_clock::now();
    while (fed < total) {
        const size_t n = std::min(chunk, total - fed);
        const size_t w = out->write(pattern.data() + fed * 2, n);
        fed += w;
        if (w == 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() > seconds + 15.0) {
            *note = "喂入超时";
            break;
        }
    }
    const auto dl = t0 + std::chrono::milliseconds((int)(seconds * 1000) + 2500);
    while (out->frames_rendered() < total && std::chrono::steady_clock::now() < dl)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    std::this_thread::sleep_for(std::chrono::milliseconds(150));

    std::printf("  [%s] 写入 %zu 帧，设备渲染 %zu 帧，欠载 %llu 次，bit_perfect=%d\n",
                shared ? "共享" : "独占", fed, out->frames_rendered(),
                (unsigned long long)out->underruns(), out->bit_perfect() ? 1 : 0);
    const int rc = (fed == total && out->frames_rendered() >= total) ? 0 : 1;
    out->close();   // 释放 Hog —— 必须在抓录停止前后都成立，这里先关不影响已抓数据
    return rc;
}

static int cmd_loopback(const std::string& device, int bits, double seconds,
                        const std::string& outPath) {
    const AudioDeviceID dev = resolve_device(device);
    if (dev == kAudioObjectUnknown) { std::printf("错误：找不到设备 %s\n", device.c_str()); return 1; }
    AudioStreamBasicDescription f{};
    uint32_t nStreams = 0;
    if (!input_format(dev, &f, &nStreams) || nStreams == 0) {
        std::printf("错误：设备 [%u] %s 没有输入流，无法回环\n", dev, device_name(dev).c_str());
        return 1;
    }
    const uint32_t rate = (uint32_t)device_rate(dev);
    std::printf("loopback：设备 [%u] %s（输入流 %u 条 %s；设备率 %u Hz）\n", dev,
                device_name(dev).c_str(), nStreams, fmt_desc(f).c_str(), rate);
    if (rate == 0) { std::printf("错误：拿不到设备采样率\n"); return 1; }
    if ((uint32_t)f.mSampleRate != rate) {
        std::printf("错误：输入流 %g Hz != 输出 %u Hz——设备两侧不同步，逐位比对无从谈起\n",
                    f.mSampleRate, rate);
        return 1;
    }

    banner(device_name(dev) + " (" + std::to_string(dev) + ")", seconds, bits, false);
    const size_t total = (size_t)((double)rate * seconds);
    const std::vector<int32_t> pattern = gen_pattern(total, 2, bits);

    CapCtx ctx;
    ctx.ch = f.mChannelsPerFrame;
    ctx.bytesPerSample = f.mBytesPerFrame / (f.mChannelsPerFrame ? f.mChannelsPerFrame : 1);
    ctx.isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    if (!ctx.isFloat && !((f.mFormatFlags & kAudioFormatFlagIsSignedInteger) && f.mBitsPerChannel == 32)) {
        std::printf("错误：输入格式只支持 float32/sint32（当前 %s）\n", fmt_desc(f).c_str());
        return 1;
    }

    // 先试完整独占路径；受阻（open 失败/IOProc 挂不上）再回退共享并如实标注
    AudioDeviceIOProcID proc = nullptr;
    std::string note;
    std::printf("—— 尝试独占路径（Hog + 物理格式 %u/%d）——\n", rate, bits);
    int rc = run_loopback(dev, bits, seconds, false, pattern, rate, total, &ctx, &proc, &note);
    bool shared = false;
    if (rc != 0) {
        std::printf("  独占路径未走通：%s\n回退共享模式（系统混音器在路径上，bit_perfect=0）\n",
                    note.c_str());
        if (proc) { ::AudioDeviceStop(dev, proc); ::AudioDeviceDestroyIOProcID(dev, proc); proc = nullptr; }
        ctx.f.clear(); ctx.i.clear(); ctx.frames = 0;
        rc = run_loopback(dev, bits, seconds, true, pattern, rate, total, &ctx, &proc, &note);
        shared = true;
    }
    if (proc) { ::AudioDeviceStop(dev, proc); ::AudioDeviceDestroyIOProcID(dev, proc); proc = nullptr; }
    if (rc != 0) { std::printf("错误：%s\n", note.c_str()); return 1; }

    const size_t frames = ctx.frames.load();
    std::printf("  抓到 %zu 帧（%.1f 秒），%s 域\n", frames,
                (double)frames / (double)rate, ctx.isFloat ? "float32" : "int32");
    const uint32_t kind = ctx.isFloat ? 1u : 2u;
    const void* data = ctx.isFloat ? (const void*)ctx.f.data() : (const void*)ctx.i.data();
    if (!write_pcm(outPath.c_str(), kind, rate, ctx.ch, (uint32_t)frames, 0, data,
                   frames * ctx.ch * 4)) {
        std::printf("错误：写抓录文件失败\n");
        return 1;
    }
    if (!write_pcm((outPath + ".exp").c_str(), 0, rate, 2, (uint32_t)total, bits, pattern.data(),
                   pattern.size() * sizeof(int32_t))) {
        std::printf("错误：写期望文件失败\n");
        return 1;
    }
    std::printf("—— 逐位比对（%s 路径）——\n", shared ? "共享" : "独占");
    return cmd_compare(outPath + ".exp", outPath, bits);
}

// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    std::setvbuf(stdout, nullptr, _IONBF, 0);   // 崩溃时日志不丢（调试期教训）
    if (argc < 2) {
        std::printf("用法：rtaloop <info|play|record-tap|record-input|loopback|compare|hogprobe> [选项]\n");
        return 1;
    }
    const std::string cmd = argv[1];
    std::string device, out, expected;
    uint32_t rate = 0;
    int bits = 16;
    double seconds = 3.0;
    bool shared = false;
    for (int i = 2; i < argc; ++i) {
        const std::string a = argv[i];
        auto next = [&](const char* what) -> std::string {
            if (i + 1 >= argc) { std::printf("错误：%s 缺参数\n", what); std::exit(2); }
            return argv[++i];
        };
        if (a == "--device") device = next("--device");
        else if (a == "--rate") rate = (uint32_t)std::strtoul(next("--rate").c_str(), nullptr, 10);
        else if (a == "--bits") bits = std::atoi(next("--bits").c_str());
        else if (a == "--seconds") seconds = std::atof(next("--seconds").c_str());
        else if (a == "--out") out = next("--out");
        else if (a == "--expected") expected = next("--expected");
        else if (a == "--captured") out = next("--captured");
        else if (a == "--shared") shared = true;
        else { std::printf("错误：未知参数 %s\n", a.c_str()); return 2; }
    }
    if (cmd == "info") return cmd_info();
    if (cmd == "play") return cmd_play(device, rate, bits, seconds, out, shared);
    if (cmd == "record-tap") return cmd_record_tap(device, seconds, out);
    if (cmd == "record-input") return cmd_record_input(device, seconds, out);
    if (cmd == "loopback") return cmd_loopback(device, bits, seconds, out);
    if (cmd == "compare") return cmd_compare(expected, out, bits);
    if (cmd == "hogprobe") return cmd_hogprobe(device, seconds);
    std::printf("错误：未知子命令 %s\n", cmd.c_str());
    return 2;
}
