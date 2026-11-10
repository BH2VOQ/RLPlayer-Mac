// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// rtaweb.cpp — RLPlayer 网页播放器
//
// 一个常驻的本地服务：
//   * 浏览磁盘上的 WAV 文件
//   * 点一下就用当前参数播放
//   * 参数（滤波器/抖动/采样率/音量/GPU）在页面上直接选
//   * 停止是【协作式】的：置停止标志让播放线程自己收尾，不杀进程（铁律 2）
//
// 只监听 127.0.0.1，不对外网开放。
//
// ---------------- macOS 移植（2026-10-25，PLATFORM.md §13.12）----------------
// 2026-10-25：Windows 专属件已随平台删除（项目转 macOS 单平台）；macOS 侧：
//   * 输出后端 = platform::CoreAudioOutput（§13.9/§13.10 已实测 0 LSB 逐位直通）
//     UI 的 backend 值不动（§10 契约"不要改 UI"）："coreaudio"/空 → CoreAudio 独占（Hog+物理格式），
//     "coreaudio-shared" → CoreAudio shared（OpenSpec.shared 就是照 WASAPI 共享语义设计的）；
//   * naa / upnp / input(采集) / crash_dump / rt_tune(MMCSS)：macOS 首版不支持，
//     API 路由保留并明确报错（页面顶部本来就承诺"选到不可用后端会直接返回原因"）；
//   * ASIO（2026-10-25 task-12）：**整个后端与 /api/asio* 路由已删除**。ASIO 是 Steinberg
//     为绕过 Windows 音频引擎发明的专有协议；macOS 的 CoreAudio 从内核层就是低延迟、
//     bit-perfect 的，没有需要绕过的东西（Yamaha FAQ 原话：CoreAudio 的低延迟性能足够，
//     macOS 环境不需要 ASIO 支持）⟹ 在 macOS 上它不是「做不到」而是「不需要」。
//     等价且更优的方案是 CoreAudio Hog Mode（已实现，见 audio_out_coreaudio.h）。
//   * path_in_exe_dir → platform::module_dir_utf8；QPC/Sleep → steady_clock/sleep_for。
// 2026-10-25：原 Windows 宏守卫（WIN32_LEAN_AND_MEAN / NOMINMAX）随平台删除。
#include <functional>              // 简介后台任务用 std::function 包装（2026-10-23 261023-04）
#include "net/webui.h"
#include "net/ui_page.h"
#include "net/ui_script.h"
#include "net/source_mgr.h"
#include "net/library.h"
#include "net/cast_service.h"      // UPnP/DLNA 投放会话编排（CastManager / CastState / CastStartParams）
#include "net/app_icon.h"
#include "net/zipstore.h"          // 最小 ZIP(STORE)打包：导出诊断 = 一个压缩包(2026-10-22 功能3)
#include "diag/diag.h"
#include "diag/bundle.h"
#include "diag/report.h"
#include "net/feedback_redact.h"   // 诊断包脱敏**唯一入口**（F-7 2026-10-27：吸收上游 feedback.h 的规则清单）
#include "net/http_client.h"       // 封面在线抓取：http_get/http_post（platform/http.h 的平台封装）
#include "net/json.h"              // /api/lib/cover/prefetch 解析网易 type=10 专辑搜索响应(2026-10-26)
#include "cover_fetch.h"           // 封面抓取**纯逻辑**（目录穿越/Dice/图片头/负缓存过期，可离线单测）
using rta::net::Library;
using rta::net::SourceManager;
using rta::net::SourceConfig;
using rta::net::SubEntry;
#include "engine/pipeline.h"
#include "engine/preset_profiles.h"   // 官方推荐预设的纯决策层（2026-10-25 三档 → 2026-10-26 四档；离线单测 tests/test_preset_profiles.cpp）

#include "audio/wav.h"
#include "audio/audio_loader.h"
#include "audio/media_info.h"
#include "audio/output_bit_depth.h"
#include "audio/bp_verdict.h"      // bit-perfect 结论的唯一实现（信号链 / status / 诊断共用）
#include "audio/render_loop.h"     // 渲染主循环(含 RENDERFAIL 遥测;测试与 rtaweb 共用同一份)
class CoreAudioSink;   // 本文件后部定义；render_loop 的 mac 遥测分支要用（前向声明）
#include "audio/rate_pick.h"       // 输出采样率选择的纯逻辑(可离线单测;2026-10-22 第二首按 44100 开流事故)
#include "platform/path.h"
#include "platform/audio_out_factory.h"   // macOS：CoreAudioOutput（PLATFORM.md §13.9/§13.10）
#include "platform/macos/audio_in_coreaudio.h"   // 输入采集（AUHAL input；§13.13）

// 渲染主循环迁到 rta::render 后，本文件的各后端实现继续用短名（历史上就是全局名）
using rta::render::OutSink;
using rta::render::SinkOpenOpts;
#include "analysis/track_health.h"     // F-5：/api/track/health 音质体检（含 quality 19 项）
#include "analysis/health_store.h"     // 1.1.4：/api/health 缓存键用强文件身份（mtime/size/ctime/inode/dev）
#include "analysis/version_compare_json.h" // F-8: reachable comparison and valid JSON
#include "meta/artwork.h"            // F-4：艺人头像全信源调度（provider.h 能力矩阵派生）
#include "meta/enrich.h"            // 单曲元数据补全编排(播放触发 + /api/enrich + /api/meta 兜底)
#include "meta/writeback.h"         // P2 标签写回(remux + PCM 逐位门禁;/api/writeback 三端点)
#include "meta/knowledge.h"         // P3 资料层直连与缓存(/api/entity/knowledge)
#include "meta/async_job.h"          // 1.1.5-beta2 M-12：knowledge 后台 job 去重状态机（纯逻辑）
#include "meta/track_identity.h"    // 1.1.5-beta2 M-13：文件名兜底解析（纯逻辑）
#include "meta/retrieval.h"         // P3 资料层③ AI 综合检索(/api/entity/summary)
#include "meta/discogs.h"           // P3 资料层④b Discogs 版本推荐(/api/entity/versions)
#include "meta/statusflags.h"       // gpu/gpuUsed 组合语义（用户 261024-04 #8，/api/status 与 /api/signal 同源）
#include "dsp/filter_families.h"
#include "dsp/oversample_peak.h"
#include "dsp/eq_text.h"
#include "dsp/ir_resample.h"
#include "dsp/peq.h"               // 261024-02 #6：20 段参数均衡（RBJ 双二阶，float64 系数 / float32 处理）
#include "dsp/opra.h"
#include "dsp/dop.h"
#include "dsp/dsd_rate_convert.h"
#include "dsp/room_api.h"        // R-1：房间测量端点层（授权/计划/状态机）
#include "platform/macos/room_transport_coreaudio.h"   // F-3：同族整数倍 DSD→DSD 速率转换
#include "dsp/modulator.h"
#include "dsp/direct_sdm.h"
#include "audio/direct_dsd_plan.h"
#include "audio/dop_padding.h"   // 1.1.2 P0-3：DoP 尾块合法静音（0x05/0xFA 交替）
#include "version.h"
// 2026-10-25（单进程合并）：本文件同时是「独立 CLI 的全部实现」和「进程内 embedded 核心」。
// rlapp_core.h 声明 start_embedded/dispatch/exit_requested/stop_embedded/cli_main，
// 实现放在本文件末尾（同一翻译单元，绝不复制业务代码）。mac 壳 tools/mac_host.mm 只包含
// 这个头文件 + 链接 rlapp_core.cpp（后者 = 本文件的库构建形态）。
#include "rlapp_core.h"
#include <cstdio>
#include <string>
#include <vector>
#include <sstream>
#include <fstream>
#include <map>
#include <thread>
#include <atomic>
#include <mutex>
#include <algorithm>
#include <filesystem>
#include <chrono>
#include <random>
#include <deque>
#include <condition_variable>
#include <memory>
#include <set>
#include <map>
#include <unordered_map>           // 封面抓取的查询词去重表（CoverTermCache）
#include <ctime>
#include <csignal>
#include <cstdlib>                 // strtol：--port 严格解析（2026-10-25 等号形式）

namespace fs = std::filesystem;
using namespace rta;
using namespace rta::audio;
namespace eng = rta::engine;

// 2026-10-25：原「非 Windows」条件守卫已去掉（macOS 单平台，内容无条件生效）。
// ---------------- macOS 替身层（Windows 专属件的非 Windows 等价物）----------------
// rt_tune.h 是 MMCSS（avrt），crash_dump.h 是 dbghelp——macOS 没有这两样。
// 播放线程与 STARTUP 横幅引用它们的接口，这里给行为等价或"如实为空"的替身。
#include <sys/sysctl.h>
#include <unistd.h>
#include <netdb.h>
#include <arpa/inet.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

namespace rta::crash {
inline void install() {}   // macOS 无 MiniDump；信号崩溃由系统 .crash 报告承接
}

namespace rta::diag {
inline std::string os_version_string() {
    char buf[256] = {0};
    size_t len = sizeof(buf) - 1;
    if (::sysctlbyname("kern.osproductversion", buf, &len, nullptr, 0) != 0) return "macOS(未知版本)";
    return "macOS " + std::string(buf);
}
inline std::string cpu_brand() {
    char buf[256] = {0};
    size_t len = sizeof(buf) - 1;
    if (::sysctlbyname("machdep.cpu.brand_string", buf, &len, nullptr, 0) != 0) return "(未知 CPU)";
    return std::string(buf);
}
inline std::string read_tester() {   // Windows 版读 exe 同目录 tester 文件；mac 同目录同名
    return std::string();
}
} // namespace rta::diag

// 2026-10-25：CastState 替身已删除 —— UPnP/DLNA 投放已在 macOS 打通（cast_service.h 真实现，
// SSDP 发现 + 本地 HTTP 供源 + AVTransport 全链 POSIX 移植），/api/status 直接用真实 CastState。

// RtTune 替身：macOS 的实时调度由 AUDIOUNIT/线程 QoS 承接，播放线程不需要显式 MMCSS。
struct RtTune {};
namespace rta::audio {
inline RtTune apply_playback_tuning() { return RtTune{}; }
inline void release_playback_tuning(RtTune&) {}
} // namespace rta::audio

// 路径分隔符（配置/数据文件的相对子路径拼接）
static const char kPathSep[] = "/";

// 进程号（Windows: GetCurrentProcessId；POSIX: getpid）
static unsigned long current_pid() {
    return (unsigned long)::getpid();
}

// CoreAudio 设备枚举（/api/devices、速率探测、信号链 device 名共用）。
// deviceId 约定与 platform 层一致：十进制 AudioDeviceID 字符串。
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
// ⚠️ CoreAudio 的 C 结构 ::AudioBuffer 与 rta::audio::AudioBuffer 撞名：裸用一律限定化（见下方词边界替换）
struct MacDevInfo {
    std::string id, name;
    bool isDefault{false};
    bool hasOutput{false};
    uint32_t nominalRate{0};
    int channels{0};
    int mixBits{0};
    std::string mixFmt{"unknown"};
    uint32_t transportType{0}; // CoreAudio fourCC, read-only evidence; zero means unknown
};
static std::string mac_cfstr(CFStringRef s) {
    if (!s) return "";
    const CFIndex len = ::CFStringGetLength(s);
    const CFIndex max = ::CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
    std::string out((size_t)max, '\0');
    if (!::CFStringGetCString(s, out.data(), max, kCFStringEncodingUTF8)) return "";
    out.resize(std::strlen(out.c_str()));
    return out;
}
static std::vector<MacDevInfo> mac_enum_devices() {
    std::vector<MacDevInfo> out;
    AudioObjectPropertyAddress addr{kAudioHardwarePropertyDevices,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size) != noErr || !size)
        return out;
    const size_t n = size / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> devs(n);
    if (::AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, devs.data()) != noErr)
        return out;
    // 默认输出设备
    AudioDeviceID defId = kAudioObjectUnknown;
    UInt32 dsz = sizeof(defId);
    AudioObjectPropertyAddress daddr{kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    const bool hasDef = ::AudioObjectGetPropertyData(kAudioObjectSystemObject, &daddr, 0, nullptr, &dsz, &defId) == noErr;
    for (AudioDeviceID d : devs) {
        MacDevInfo mi;
        mi.id = std::to_string((unsigned)d);
        mi.isDefault = hasDef && d == defId;
        UInt32 transportBytes=sizeof(mi.transportType);
        AudioObjectPropertyAddress transportAddress{kAudioDevicePropertyTransportType,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        if(::AudioObjectGetPropertyData(d,&transportAddress,0,nullptr,&transportBytes,&mi.transportType)!=noErr)mi.transportType=0;
        CFStringRef name = nullptr;
        UInt32 nsz = sizeof(name);
        AudioObjectPropertyAddress naddr{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        if (::AudioObjectGetPropertyData(d, &naddr, 0, nullptr, &nsz, &name) == noErr && name) {
            mi.name = mac_cfstr(name);
            ::CFRelease(name);
        }
        // 有没有输出流
        AudioObjectPropertyAddress ostream{kAudioDevicePropertyStreams,
                                           kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
        UInt32 osz = 0;
        mi.hasOutput = ::AudioObjectGetPropertyDataSize(d, &ostream, 0, nullptr, &osz) == noErr && osz > 0;
        // 当前标称率
        Float64 rate = 0; UInt32 rsz = sizeof(rate);
        AudioObjectPropertyAddress raddr{kAudioDevicePropertyNominalSampleRate,
                                         kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
        if (::AudioObjectGetPropertyData(d, &raddr, 0, nullptr, &rsz, &rate) == noErr) mi.nominalRate = (uint32_t)rate;

        // Q-1: CoreAudio 输出流混音声道数与流格式探测
        if (mi.hasOutput) {
            AudioObjectPropertyAddress saddr{kAudioDevicePropertyStreamConfiguration,
                                             kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
            UInt32 csz = 0;
            if (::AudioObjectGetPropertyDataSize(d, &saddr, 0, nullptr, &csz) == noErr && csz > 0) {
                std::vector<uint8_t> abuf(csz);
                ::AudioBufferList* abl = reinterpret_cast<::AudioBufferList*>(abuf.data());
                if (::AudioObjectGetPropertyData(d, &saddr, 0, nullptr, &csz, abl) == noErr) {
                    for (UInt32 bi = 0; bi < abl->mNumberBuffers; ++bi) {
                        mi.channels += abl->mBuffers[bi].mNumberChannels;
                    }
                }
            }
            AudioStreamBasicDescription asbd{};
            UInt32 fsz = sizeof(asbd);
            AudioObjectPropertyAddress faddr{kAudioDevicePropertyStreamFormat,
                                             kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
            if (::AudioObjectGetPropertyData(d, &faddr, 0, nullptr, &fsz, &asbd) == noErr) {
                if (asbd.mSampleRate > 0) mi.nominalRate = (uint32_t)asbd.mSampleRate;
                mi.mixBits = (int)asbd.mBitsPerChannel;
                if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) mi.mixFmt = "float32";
                else if (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) mi.mixFmt = "pcm";
                else mi.mixFmt = "pcm";
            }
            if (mi.channels <= 0) mi.channels = 2;
            if (mi.nominalRate <= 0) mi.nominalRate = 44100;
            if (mi.mixBits <= 0) mi.mixBits = 32;
            if (mi.mixFmt.empty() || mi.mixFmt == "unknown") mi.mixFmt = "float32";
        }

        out.push_back(std::move(mi));
    }
    return out;
}
// 统一"找设备显示名/id"：devId 为空取默认输出设备，否则按 id 精确匹配
// （Windows 侧对应 WasapiOutput::enumerate() + isDefault/id/name 的三处内联循环）。
static void mac_find_dev(const std::string& devId, std::string& name, std::string& id) {
    for (const auto& d : mac_enum_devices()) {
        if (!d.hasOutput) continue;
        const bool hit = devId.empty() ? d.isDefault : (d.id == devId);
        if (hit) { name = d.name; id = d.id; return; }
    }
    if (name.empty()) name = devId.empty() ? std::string("默认音频设备") : devId;
}


// 路径 <-> UTF-8 字符串（C++20 的 u8string 返回 char8_t，不能直接当 std::string 用）
static std::string pathToUtf8(const fs::path& p) {
    const auto u8 = p.u8string();
    return std::string(reinterpret_cast<const char*>(u8.data()), u8.size());
}

static rta::dsp::Shaper parse_shaper(const std::string& s) {
    std::string u = s;
    std::transform(u.begin(), u.end(), u.begin(), [](unsigned char c) { return (char)std::toupper(c); });
    if (u == "NONE")   return rta::dsp::Shaper::None;
    if (u == "NS1")    return rta::dsp::Shaper::NS1;
    if (u == "NS4")    return rta::dsp::Shaper::NS4;
    if (u == "NS5")    return rta::dsp::Shaper::NS5;
    if (u == "NS9")    return rta::dsp::Shaper::NS9;
    if (u == "LNS15")  return rta::dsp::Shaper::LNS15;
    if (u == "RPDF")   return rta::dsp::Shaper::RPDF;
    if (u == "TPDF")   return rta::dsp::Shaper::TPDF;
    if (u == "GAUSS1") return rta::dsp::Shaper::Gauss1;
    if (u == "SHAPED") return rta::dsp::Shaper::Shaped;
    return rta::dsp::Shaper::None;
}

// ---------------- 参数 ----------------
struct PlayParams {
    std::string file;
    std::string filter;      // 1x（44.1/48k）用；空 = 默认 Kaiser
    std::string filterNx;    // Nx（>=88.2k）用；空则沿用 filter
    std::string shaper = "none";
    std::string rate;        // "src" | "max" | 数字
    double volume = 0.0;
    bool   gpu = false;
    bool   loudness = false;
    bool   isp = true;         // 过采样峰值保护
    bool   twoStage = true;    // 两段式升频
    int    dsd = 0;            // 0 = PCM；64/128/256 = DoP 封装的 DSD
    int    modOrder = 5;       // SDM 调制器阶数
    std::string modFamily = "dsd";     // SDM 调制器族：dsd | chebyshev | ec | ahm
    double oobGain = 5.0;              // Chebyshev 带外增益 dB
    int    ahmBits = 8;                // AHM 多电平位深 (6~8 bit)
    std::string gpuVendor = "auto";   // auto | amd | nvidia | off
    bool   dsdNative = false;         // true = 走 Native DSD（Windows 专有驱动通道；本平台不可用，会明确报错）
    bool   directSdm = false;         // true = DirectSDM：源 DSD 与目标同速率时逐位直通（要求 0 dB、无 PCM 处理）
    int    bufferMs = 100;

    // ---- ReplayGain / Album Gain ----
    std::string rgMode = "off";       // off | track | album
    double      rgPreamp = 0.0;       // 前级增益 dB（-15.0 ~ +15.0，默认 0.0）
    bool        rgPreventClip = true; // 防削波保护（默认 true）

    // ---- 输出后端 / 多声道 / 每声道微调 ----
    std::string sdmFilter;            // SDM（DSD 输出）用的 1x 滤波器；空 = 沿用 filter
    std::string sdmFilterNx;          // SDM 用的 Nx 滤波器；空 = 沿用 filterNx
    // 2026-10-25（默认值纠正）：这些 value 名是 UI 契约（前端下拉的 value 未变），
    // 但 macOS 上的真实语义已经不同 —— 注释必须说清，否则后来者会以为还在用 WASAPI。
    //   "coreaudio"        → CoreAudio 独占（AUHAL + Hog Mode）
    //   "coreaudio-shared" → CoreAudio 共享（系统混音）
    //   "naa"           → macOS 不可用（make_sink 返回必然 open 失败的 sink；UI 已移除该项）
    //   "upnp"          → UPnP/DLNA 投放（CastManager）
    //   "null"          → 只跑 DSP 不出声
    // Hog 独占是独立开关（2026-10-25 从 shared 拆出来，方案 C）。
    //   true  = 抢 Hog ⟹ 真独占（其他 App 声音被屏蔽）；代价是系统音量条 / 音量键失效 ——
    //           这是 macOS Hog Mode 的机制限制（实测：Hog 中其它进程改音量无效），
    //           音量只能用本程序的音量条调。
    //   false = 不抢 Hog ⟹ 系统音量全程可用，但设备所有权不独占。
    // ★ 2026-11-09 用户明确要求「独占功能要默认开启」⟹ 默认改为 true。
    //   这与"bit-perfect 不要求 Hog"并不矛盾：Hog 只保证设备所有权独占，
    //   位流是否被改由采样率/位深/增益/处理链决定（见 src/audio/bp_verdict.h）。
    //   Hog 打开的真实价值是「别的声音不会插进来一起播」，代价是系统音量失效。
    bool hogExclusive = true;
    std::string backend = "coreaudio";   // 默认 = CoreAudio 独占（等价 WASAPI 独占语义）
    std::string naaHost;              // NAA 端点 host:port（macOS 不可用，仅老 conf 兼容）
    std::string upnpDev;              // UPnP/DLNA 渲染器（设备描述 URL；后端 = upnp 时使用）
    int    outChannels = 0;           // 0 = 跟随源
    double trim[8] = {0,0,0,0,0,0,0,0};   // 每声道增益 dB

    // ---- 输入 ----
    std::string inBackend = "none";   // none | wasapi（macOS 上 "coreaudio" = CoreAudio 输入）
    std::string inDevice;
    int    inOffset = 0;
    int    inBufferMs = 100;
    bool   inMonitor = false;

    // ---- 完整设置（设置页用）----
    std::string device;          // 输出设备 id，空 = 默认设备
    int    bits = 0;             // 0 = 24（或 DSD 时固定 24）
    int    taps = 0;             // 0 = 用滤波器预设的抽头数
    int    minTapsPerInput = 0;  // 0 = 用滤波器预设的每相位地板；>0 手动覆盖
    double atten = 0.0;          // 0 = 用预设的阻带衰减
    double transition = 0.0;     // 0 = 用预设的过渡带
    std::string phase;           // "" = 预设 | "linear" | "minimum"
    double modCutoff = 0.0;      // kHz，0 = 100 kHz
    double modDither = -1.0;     // <0 = 默认 0.01
    std::string convIr;          // 卷积 IR 的 WAV 路径（空 = 不做卷积）
    std::string eqFile;          // EQ 文本（REW / AutoEq 格式）
    bool   convGpu = false;
    double volRamp = 0.0;        // 音量渐变毫秒，0 = 200

    std::string dsdKind = "fir";     // DSD 源抽取器：fir | iir | cic
    std::string dsdConv = "narrow";  // DSD 源 Conversion 预设：narrow | wide | xfi
    bool        dsd2Stage = true;    // DSD 源两级抽取（CIC 4x + 短 FIR），默认开启

    // 2026-10-24（261024-02 #8）：源文件真实位深（16/24/32）。解码器给的是容器位深（flac 一律 32），
    // 用容器位深判"位深降低"会误报（16bit 源 → 24bit 输出明明没降低）。
    int    srcBits = 0;
    // ---- CUE 分轨播放区间（2026-10-25）----
    // 一张 .cue 把整轨文件切成 N 首：库里这 N 条的 path 完全相同，位置由 cueOff/cueLen 给出
    //（见 src/net/library.h 的 LibTrack）。播放侧只认"秒"，所以这里用 cueStart/cueEnd 两个浮点：
    //   cueStart < 0  ⟹ 整首（旧行为，负向对照就是这一档）
    //   cueEnd   < 0  ⟹ 到文件末尾
    // 语义（三条都不能含糊）：
    //   · 区间是**播放区间**：前 cueStart 帧一个都不写给设备，到 cueEnd 正常结束；
    //   · ps.total 按 (cueEnd-cueStart) 算 ⟹ 进度条/时长是本轨的，不是整轨的；
    //   · seek 的 pos 语义落在本区间内（0 = 本轨开头）。
    // 给了 cueStart 却读不了/越界 ⟹ **明确报错**，绝不静默从头播（那样用户只会以为 cue 没生效）。
    double cueStart = -1.0;
    double cueEnd   = -1.0;
    std::string remoteId;        // 远程曲目 id（Subsonic）
    std::string remoteSuffix;    // 远程文件后缀，决定缓存文件名
    std::string remoteTitle;

    // ---- 2026-10-25（耳机 EQ 切换"没变化" 修复）：起播即定位 ----
    // 为什么必须有这个字段：播放中切换 OPRA 预设时 EQ 链变了，Pipeline 必须重建；
    // 而"重建 + 从第 0 帧重播"等于把用户刚听到的位置丢掉 —— 用户会听到"从头开始"，
    // 于是判定"EQ 切换把播放搞乱了"而不是"EQ 变了"。用这个比例让新管线直接从
    // 原采样帧继续输出：听感上只有 EQ 的差别，没有跳回开头。
    //   取值域：(-1, 0] = 不定位（正常从头播）；(0, 1) = 从 frac 处起播。
    //   消费点：play_one_impl 里生产者线程的 pos 起点 + ps.played 起点（同源，见那里的注释）。
    double initialSeekFrac = -1.0;
};

// ---------------- 播放状态 ----------------
struct PlayerState {
    std::mutex  mtx;
    std::thread th;
    std::atomic<bool> stop{false};
    std::atomic<double> seekReq{-1.0};   // 跳转目标（0..1 的比例），-1 表示无请求
    std::atomic<bool> pauseReq{false};   // HTTP 线程置位，播放线程响应
    std::atomic<bool> paused{false};     // 实际是否处于暂停
    std::atomic<bool> playing{false};
    std::atomic<size_t> played{0};
    std::atomic<size_t> total{0};
    std::string current;
    std::string error;
    std::string info;
    std::string signal;       // 本次播放的信号链快照（JSON），供界面画"每一环"
    // 真实 Hog 独占请求与持有状态（2026-10-30 用户拍板：status 不得用设置偏好当实际持有）
    std::atomic<bool> hogRequested{false};
    std::atomic<bool> hogAcquired{false};
    // 2026-10-23（用户 261023-02 #1）：本次播放的 bit-perfect 结论（direct/yes/no）+ 原因。
    // 在信号链 JSON 生成处一并写入，/api/status 直接带出，供底栏常驻徽标使用。
    std::string bpState;
    std::string bpWhy;
    // ---- 输出格式自证（2026-10-26，debug/20261026-02 F-5）----
    // 为什么必须由后端给：底栏只拿到 outRate，而 **DoP 的 outRate 是载波率**
    // （DSD128 / 48k 族 = 6144000/16 = 384000），和"PCM 升频到 384k"的数字一模一样。
    // 用户看到 384000 会判断"选了 DSD 却变成 PCM 升频"（上游踩过这个坑）；
    // 后端不把 dsdRate 交出来，这个误解永远无法自证。
    //   outMode     输出通道模式：coreaudio（独占）/ shared（共享）/ null / upnp
    //               ★ mac **没有** wasapi / asio / native 这些值（ASIO 整段已删；
    //                 Native DSD 在 mac 不存在，/api/play 直接拒绝 dsdnative=1）。
    //               "" = 本进程还没播过任何东西（未知，不是"pcm"）
    //   dsd         实际输出的 DSD 档位（64/128/256/512；PCM = 0）
    //   dsdRate     实际 1-bit **有效码率**（DSD128 = 6144000；PCM = 0）
    //   carrierRate DoP 的 **PCM 载波率** = dsdRate/16（就是 ps.outRate 那个数；
    //               DSD128 = 384000；PCM = 0）。两个数都给，用户才不会把载波当 PCM 降级
    //   modFamily   调制器族（PCM / DirectSDM 直通 = 空，因为没有调制器参与）
    //   modOrder    **实际生效**的阶数（stable_sdm_order 可能按稳定性下调，不是用户填的）
    //   fallbackWhy 非空 = 本次实际输出与用户请求不一致的**中文**原因（空 = 没降级）
    std::string outMode;
    int         outDsdLevel    = 0;
    uint32_t    outDsdRate     = 0;
    uint32_t    outCarrierRate = 0;
    std::string outModFamily;
    int         outModOrder    = 0;
    std::string outFallbackWhy;
    // ---- 1.1.2 AirPlay 输出适配（AP-1.8）：本次输出的传输与延迟自证 ----
    // 与 outMode/outFallbackWhy 同源同时机写入（起播时探一次），不给 /api/status 的 400ms
    // 轮询增加任何 CoreAudio 属性查询。空/0/false = 未知，绝不拿猜测值填充。
    std::string outTransport = "unknown";   // airplay | usb | builtin | ...
    bool        outLatencyKnown = false;    // 系统属性读到了才为 true
    double      outLatencyMs = 0.0;         // 系统属性换算值（不是端到端实测）
    std::string outLatencySource = "none";  // 这个数从哪来
    bool        outSharedOnly = false;      // AirPlay 等仅共享端点
    double outRate = 0;
    int    outBits = 0;
    // 2026-11-09（用户截图：48000→44100 被标成「GPU 升频」）：
    // 底栏与信号链要判"升频还是降采样"，就必须拿到**源采样率**。
    // 以前 /api/status 的 inRate 只在投放模式给值，本地恒为 0 ⟹ 前端只能靠
    // why 文案里有没有「重采样」三个字猜方向，于是降采样被标成升频。
    // 这里与 outRate 同源同时机写入（起播时一次），不增加轮询开销。
    uint32_t inRate = 0;
    // ---- ReplayGain / Album Gain 状态 ----
    std::string rgMode = "off";
    double      rgAppliedDb = 0.0;
    bool        rgClipLimited = false;
    std::string rgSource;
    std::string rgNote;
    // 2026-10-24（用户 261024-04 #8：bit-perfect 时信号链没绿点、右下角 GPU 图标还亮着）：
    //   gpu 只有 render_loop 在 RQ.gpu 置位时写 true（见 rtaweb.cpp 的 rl.gpuOut 接线），
    //   而 **正常播放路径从不复位它** —— 于是一旦本进程里有一首走过 GPU 升频，后面所有曲目
    //   （包括不重采样的 bit-perfect 直通）都显示"在用 GPU"。现在：每次播放开始都复位，
    //   并且 /api/status 的 gpu 改成"可用性"、另加 gpuUsed 表达"本次真的参与了"。
    bool   gpu = false;        // 本次播放是否由 GPU 升频（render_loop 写，PLAY 入口复位）
    // 本次播放 IR 卷积是否真的跑在 GPU 上（PipelineStats::usedGpuConvolution 写；DLL 缺失/失败= false）
    std::atomic<bool> gpuConvUsed{false};
    std::atomic<long long> dbgPad{0}, dbgSkips{0};   // 诊断：设备侧水位与欠载跳过次数
    std::atomic<double> volDb{0.0};    // 用户当前请求的音量（拖动滑块即时生效）
    std::atomic<double> startDb{0.0};  // 本次播放起点音量（DSP 里已按它做过抖动量化）

    // 耗时统计（ROADMAP P6a 可观测性）
    std::atomic<long long> decodeMs{0};     // 解码总耗时 (ms)
    std::atomic<long long> ffmpegMs{0};     // 临时 WAV 转码写耗时 (ms)
    std::atomic<long long> wavReadMs{0};    // 临时 WAV / WAV 读取耗时 (ms)
    std::atomic<long long> dspChunkUs{0};   // 最近一块 DSP 处理耗时 (微秒)
    std::atomic<long long> dspTotalUs{0};   // 累计 DSP 处理耗时 (微秒)
    std::atomic<long long> dspChunks{0};    // 处理的 DSP 块数

    // ---- 播放线程生命周期（2026-10-25 并发化配套）----
    // 旧版 HTTP 是单线程串行，ps.th 的「停→join→重新起线程」天然互斥。
    // 改成每连接一个工作线程后，多个请求可能同时点播放/停止/切歌，于是出现两个真 UB：
    //   ① 对 joinable 的 std::thread 赋值 = std::terminate（整个进程消失）；
    //   ② 两个线程同时 join 同一个 thread 也是 UB。
    // 修法：所有「停/join/起线程」都在这把 ctlMtx 下串行（锁序固定 ctlMtx → g_q.mtx，
    // 播放线程自身只拿 g_q.mtx，不会反向，因此没有死锁环）。
    std::mutex ctlMtx;

    void joinIfDone() {
        std::lock_guard<std::mutex> lk(ctlMtx);
        joinIfDoneLocked();
    }
    // 调用方已持有 ctlMtx 时用这个（避免同一把锁重入）
    void joinIfDoneLocked() {
        if (th.joinable()) th.join();
    }
    // 起新播放线程：同样必须在 ctlMtx 下，先 join 掉旧的再接管 th
    void startLocked(std::thread t) {
        if (th.joinable()) th.join();
        th = std::move(t);
    }
    // 一次原子操作：停旧播放线程 → join → 清 stop → 起新的。
    // 三个播放入口（/api/play、/api/lib/play、/api/skip）都走这里，
    // 保证并发点播放时不会出现「两个线程都在写 ps.current」或 thread 赋值 terminate。
    template <class Fn>
    void restart(Fn&& makeThread) {
        std::lock_guard<std::mutex> lk(ctlMtx);
        stop.store(true);
        joinIfDoneLocked();
        stop.store(false);
        startLocked(std::thread(std::forward<Fn>(makeThread)));
    }
    // 只停不启（/api/stop、/api/clear、转投投放会话前）：同样原子，避免与并发播放请求撞车
    void stopJoin() {
        std::lock_guard<std::mutex> lk(ctlMtx);
        stop.store(true);
        joinIfDoneLocked();
        stop.store(false);
        hogRequested.store(false);
        hogAcquired.store(false);
    }
};
static PlayerState g_ps;

// 写"输出格式自证"字段（2026-10-26 F-5）。**唯一入口**：字段成组更新，
// 且必须持 ps.mtx —— /api/status 的读线程在同一把锁下取值。
// 调用点不得已经持有 ps.mtx（否则死锁）。
// 分成两个函数：① 每曲起播先 reset 成"未知/PCM"，② 真正走 DSD 的分支再覆盖。
static void set_out_format_state(const char* mode, int dsdLevel, uint32_t dsdBitRate,
                                 uint32_t carrierRate, const std::string& family,
                                 int order, const std::string& fallbackWhy) {
    std::lock_guard<std::mutex> lk(g_ps.mtx);
    g_ps.outMode        = mode ? mode : "";
    g_ps.outDsdLevel    = dsdLevel;
    g_ps.outDsdRate     = dsdBitRate;
    g_ps.outCarrierRate = carrierRate;
    g_ps.outModFamily   = family;
    g_ps.outModOrder    = order;
    g_ps.outFallbackWhy = fallbackWhy;
}
// 起播前复位：不复位的话 /api/status 会把**上一曲**的 outMode 当成本次事实
// （与 ps.gpu 每曲复位同一个教训，见 261024-04 #8）。
// mode 传实际后端模式，dsd/调制字段归零（本曲还没决定是否走 DSD）。
static void reset_out_format_state(const char* mode) {
    set_out_format_state(mode, 0, 0, 0, std::string(), 0, std::string());
    g_ps.hogRequested.store(false);
    g_ps.hogAcquired.store(false);
}

// 20 段参数均衡 PEQ（261024-02 #6）：全局单例。播放线程处理音频，HTTP 线程改参数（热更新）。
static std::shared_ptr<rta::dsp::PeqEngine> g_peq;
static std::atomic<bool> g_exitReq{false};
// 2026-10-25：退出中标志。后台 detached 任务看到它就尽量提前收尾
static std::atomic<bool> g_shutdown{false};

// ---------------- 进程内存遥测（2026-10-25 大 DSD 文件"卡死"取证） ----------------
// 为什么必须自己量：外部按秒采样会漏掉解码阶段的瞬时峰值（整曲解成 double 平面只在几秒内存在），
// 而"峰值内存"正是本次事故的核心判据之一。这里既给 /api/status 用，也写进 MEM 日志行。
struct ProcMemInfo { double wsMb = 0.0; double peakMb = 0.0; };
static ProcMemInfo proc_mem() {
    static std::mutex m;
    static double peak = 0.0;
    double ws = 0.0;
#if defined(__APPLE__)
    mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
        ws = (double)info.resident_size / (1024.0 * 1024.0);
#endif
    std::lock_guard<std::mutex> lk(m);
    if (ws > peak) peak = ws;
    ProcMemInfo r; r.wsMb = ws; r.peakMb = peak;
    return r;
}
// MEM 行：播放各阶段的内存快照。格式固定，便于 grep / 出报告。
static std::string mem_line(const std::string& stage, const std::string& extra = std::string()) {
    const ProcMemInfo m = proc_mem();
    char b[320];
    std::snprintf(b, sizeof(b), "MEM stage=%s ws=%.1fMB peak=%.1fMB", stage.c_str(), m.wsMb, m.peakMb);
    std::string s = b;
    if (!extra.empty()) s += " " + extra;
    return s;
}
// 播放线程诊断计数（出问题时第一手证据，比猜快得多）
static std::atomic<long long> g_dbgW0{0}, g_dbgPulls{0}, g_dbgWf{0}, g_dbgWr{0}, g_dbgPer{0};
// C2 遥测（2026-10-24 N300 欠载）：dry/dryms/ev/evint/prod 由 render_loop 计数并导出，
// STAT 行是权威输出，这四个原子量只是让 /api/status 也能读到（诊断页/底栏用）。
static std::atomic<long long> g_dbgDry{0}, g_dbgDryMs{0}, g_dbgEv{0}, g_dbgEvInt{0}, g_dbgProd{0};
static std::atomic<double> g_dbgPeak{0.0};    // 最近一个写入周期的峰值（0..1）
static std::atomic<long long> g_dbgClip{0};   // 本次播放的满幅样本数（诊断削波/噪音）
static uint16_t g_uiPort = 8899;
static bool     g_lanOn  = false;
// 2026-10-25（单进程合并）：本进程**当前是否真的有一个本地 HTTP 监听**在服务。
//   * 独立 CLI（rtaweb 可执行文件）：main() 里 WebUi::start 成功后置 true；
//   * 进程内 embedded（rlapp_core，WKURLSchemeHandler 直连 dispatch）：恒 false。
// 存在理由：/api/net 原来无条件回 "port":8899，界面就照着渲染「本机：http://127.0.0.1:8899/」。
// 单进程之后那个端口**根本没人监听**，再这么说就是让用户去点一个死链接（铁律 4：不许假装）。
static std::atomic<bool> g_httpListening{false};
static rta::diag::DiagStartResult g_diagStartup; // initialized before request entry points open

// ---- 后台 detached 任务追踪（元数据补全 / 资料整理）----
// 2026-10-25（单进程合并）：这两类任务原来是纯 detached 线程，进程退出时没人等它们。
// CLI 形态下进程直接消失，系统一并收走；但 embedded 形态是**壳进程继续活着**，这些线程
// 还在摸 MetaStore/Library 单例 —— 所以 stop_embedded 必须给它们一个有界的收尾窗口
// （协作等待，绝不 force-kill；超时就如实记日志，不假装收干净了）。
// 声明放在这里（文件靠前）：两个 detach 点（meta_on_play / summary_job_start_fn）都在下方。
static std::atomic<int> g_bgJobs{0};
static std::mutex g_bgMx;
static std::condition_variable g_bgCv;
// 1.1.5-beta2 M-12：knowledge 后台 job 去重状态机（纯逻辑在 meta/async_job.h）。
// rtaweb 只负责起线程 / 取结果 / 退出闸门，判据全在 JobRegistry 里可单测。
static rta::meta::JobRegistry g_knowledge_jobs;

// 尽早置位全局退出标志，与 g_bgMx 互斥锁保护，彻底杜绝 check-then-act 竞态
// 1.1.5-beta2 M-12：同时关掉 knowledge job 表的派发闸门（不 force-kill 在途任务，
// 在途任务仍可 finish；BgJobGuard 负责协作收尾）。
static void set_shutdown_flag() {
    g_knowledge_jobs.shutdown();
    std::lock_guard<std::mutex> lk(g_bgMx);
    g_shutdown.store(true);
}

// 检查并登记后台任务：登记检查与 shutdown 使用同一 mutex，避免 check-then-act 竞态。
// 返回 true 表示成功登记，false 表示系统已处于退出中（g_shutdown == true），禁止登记新任务。
static bool bg_job_begin() {
    std::lock_guard<std::mutex> lk(g_bgMx);
    if (g_shutdown.load()) return false;
    g_bgJobs.fetch_add(1);
    return true;
}

static void bg_job_end() {
    g_bgJobs.fetch_sub(1);
    { std::lock_guard<std::mutex> lk(g_bgMx); }   // 与 wait_for 的谓词检查配对（避免丢唤醒）
    g_bgCv.notify_all();
}

// 异常安全 RAII 卫 guard：无论正常结束或发生异常均保证 bg_job_end 归零
class BgJobGuard {
public:
    BgJobGuard() : active_(bg_job_begin()) {}
    ~BgJobGuard() {
        if (active_) {
            bg_job_end();
            active_ = false;
        }
    }
    bool active() const { return active_; }
    BgJobGuard(const BgJobGuard&) = delete;
    BgJobGuard& operator=(const BgJobGuard&) = delete;
private:
    bool active_ = false;
};

// ---- dispatch 并发观测（诊断/测试用；全部 relaxed 原子，不进任何临界区）----
// 见 rlapp_core.h 的说明：用来证明「dispatch 没有被串行化」，而不是靠代码审查自证。
static std::atomic<int>       g_inFlight{0};
static std::atomic<int>       g_peakConcurrent{0};
static std::atomic<long long> g_dispatchCount{0};
static std::mutex g_logMx;
static std::deque<std::string> g_log;
static void dlog(const std::string& s) {
    std::lock_guard<std::mutex> lk(g_logMx);
    if (g_log.size() > 400) g_log.pop_front();
    g_log.push_back(s);
}
static PlayParams  g_params;      // 最近一次播放参数，跳曲时沿用
// 2026-10-25（耳机 EQ 热重载）：g_params 从"只在播放入口写、跳曲时读"变成
// **HTTP 设置线程也会写**（/api/settings 同步 eq/ir/irgpu）。而 /api/skip 与
// prefetch_start 会同时读它 —— 一个 std::string 被边写边读就是真 UB（可能读到
// 半改的指针 ⟹ 崩溃或读到乱码路径）。这把锁只护 g_params 本身，粒度极细。
static std::mutex   g_paramsMtx;
static PlayParams params_snapshot() {
    std::lock_guard<std::mutex> lk(g_paramsMtx);
    return g_params;
}
static void params_store(const PlayParams& p) {
    std::lock_guard<std::mutex> lk(g_paramsMtx);
    g_params = p;
}

// 后端标识历史别名的规范化函数（定义在文件后部 out_mode_of_backend 之前）。
// 前置声明：parseForm / apply_conf_defaults_for_play 都在它之前就要用。
static std::string normalize_backend_id(const std::string& v);

// ---------------- 可观测性（1.0.5）：运行时长 / 构建时间 ----------------
static const std::chrono::steady_clock::time_point g_startTp = std::chrono::steady_clock::now();
static const char* const g_buildTime = __DATE__ " " __TIME__;

// DSD 源抽取设置（P0-4/P0-5）：播放与预解码两条线程都要用，所以放在一个函数里
static void apply_dsd_src_settings(const PlayParams& p) {
    auto& st = dsd_pcm_settings();      // 必须是引用：auto 会拷贝，设置就丢了（本轮踩到）
    st.kind = (p.dsdKind == "iir") ? rta::dsp::IntegratorKind::Iir
            : (p.dsdKind == "cic") ? rta::dsp::IntegratorKind::Cic
                                   : rta::dsp::IntegratorKind::Fir;
    st.conversion = rta::dsp::parse_conversion(p.dsdConv);
    st.twoStage = p.dsd2Stage;
}

// ---------------- 工具 ----------------
static std::string path_in_exe_dir(const char* name);

static std::map<std::string, std::string> load_conf_map() {
    std::map<std::string, std::string> m;
    std::ifstream f(path_in_exe_dir("rlplayer-settings.conf"));
    if (!f) return m;
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t e = line.find('=');
        if (e == std::string::npos) continue;
        m[line.substr(0, e)] = line.substr(e + 1);
    }
    return m;
}

static std::string jesc(const std::string& s) {
    std::string o; o.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) { char b[8]; std::snprintf(b, sizeof(b), "\\u%04x", c); o += b; }
                else o += (char)c;
        }
    }
    return o;
}

// ---------------- 请求 id / 最近动作轨迹（D3，2026-10-29）----------------
// 为什么要 rid：诊断包要能回答"用户此前做了什么"（ROADMAP Q8），而现有日志只有事件、
// 没有"这一次请求"的关联键；前后端同一个码/同一个 id 才能把 UI 报错与后端现场对上。
// 为什么现在还不能写进 diag/event.h：src/diag 由基础代理实现，接口未落地；
// 这里先用进程内自增号（与后端稳定码同一命名空间），diag 就绪后由 diag_new_rid() 接管。
static std::atomic<unsigned long long> g_ridSeq{0};
static std::string rid_new() {
    static const unsigned long long boot =
        (unsigned long long)std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
    const unsigned long long n = g_ridSeq.fetch_add(1, std::memory_order_relaxed) + 1;
    char b[64];
    std::snprintf(b, sizeof(b), "r-%08llx-%04llu", (unsigned long long)(boot & 0xffffffffull), n);
    return b;
}
static thread_local std::string t_rid;
static const std::string& rid_current() { return t_rid; }
struct RidScope {
    explicit RidScope(const std::string& r) : previous(t_rid) { t_rid = r; }
    ~RidScope() { t_rid = previous; }
    std::string previous;
    RidScope(const RidScope&) = delete;
    RidScope& operator=(const RidScope&) = delete;
};

// 最近动作轨迹：只记"做了什么"，不记查询串（查询串可能含搜索词/签名/key，见脱敏要求）。
struct ActionRec {
    long long ts = 0;
    std::string rid, method, path;
    int status = 0;          // HTTP 语义状态（200 / 400 / 404 / 422 / 500）
    bool ok = true;          // 业务层 {"ok":false} 也算失败（HTTP 200 不代表成功）
    bool dispatchException = false;
    long long ms = 0;
};
static std::mutex          g_actMx;
static std::deque<ActionRec> g_actRing;
static void action_record(const ActionRec& a) {
    std::lock_guard<std::mutex> lk(g_actMx);
    g_actRing.push_back(a);
    while (g_actRing.size() > 200) g_actRing.pop_front();
}
static std::string path_no_query(const std::string& p) {
    const size_t q = p.find('?');
    return q == std::string::npos ? p : p.substr(0, q);
}
static std::string actions_json(size_t limit = 50) {
    std::lock_guard<std::mutex> lk(g_actMx);
    std::ostringstream j;
    j << "[";
    const size_t n = g_actRing.size();
    const size_t start = (n > limit) ? n - limit : 0;
    bool first = true;
    for (size_t i = start; i < n; ++i) {
        const ActionRec& a = g_actRing[i];
        if (!first) j << ",";
        first = false;
        j << "{\"ts\":" << a.ts << ",\"rid\":\"" << jesc(a.rid) << "\""
          << ",\"method\":\"" << jesc(a.method) << "\""
          << ",\"path\":\"" << jesc(a.path) << "\""
          << ",\"status\":" << a.status
          << ",\"ok\":" << (a.ok ? "true" : "false")
          << ",\"exception\":" << (a.dispatchException ? "true" : "false")
          << ",\"ms\":" << a.ms << "}";
    }
    j << "]";
    return j.str();
}

// 诊断/错误文本脱敏：所有"写日志或回给界面"的异常原因都过这一道。
// 为什么要去查询串：feedback_redact.h 的既有规则**不认 URL query**（tests/test_diag_event.cpp
// 的 A 段把这条红基线钉住了），而 HTTP 客户端的异常文本里经常整条 URL 带 access_token/q=。
// 这里只动真正长得像 URL 的片段，不动普通文件路径。
static std::string err_text_redacted(std::string s) {
    s = rta::feedback::redact(std::move(s));
    size_t scan = 0;
    while (true) {
        const size_t h = s.find("http", scan);
        if (h == std::string::npos) break;
        const size_t q = s.find('?', h);
        if (q == std::string::npos) break;
        // 只有当 '?' 前面确实是 http(s):// 结构时才裁剪，避免误伤文件名里的 '?'
        const bool isUrl = (s.compare(h, 7, "http://") == 0) || (s.compare(h, 8, "https://") == 0);
        if (!isUrl) { scan = h + 4; continue; }
        const size_t stop = s.find_first_of(" \t\r\n\"'<>", q);
        const size_t end = (stop == std::string::npos) ? s.size() : stop;
        s.replace(q, end - q, "?<redacted-query>");
        scan = q + 17;
    }
    return s;
}

// ---------------- 体检端点统一错误契约（#17 / B4，2026-10-29）----------------// 修前实测（debug/20261028-02-RLPlayer2核对/evidence/api-cli-results.json）：
//   * 非法 WAV → {"ok":true,"health":{status:"error", 各指标 0}} —— 调用方看 ok 就当成功，
//     把 0 当响度/峰值画出去（默认 0 冒充正常结果）；
//   * 缺参数/文件不存在 → {"ok":false,"error":...} 没有 health —— 与上一条不同构，
//     前端无法用同一套判据区分"没分析"与"分析失败"。
// 现契约（三种结果同构，字段只增不删）：
//   {"ok":<bool>,"usable":<bool>,"code":"<稳定码>","error":"<人话>","health":{...}}
//   ok == usable == (health.status == "ready")；失败时 health.status=="error"，
//   指标字段一律为 null（不是 0 —— 0 在 JSON/JS 里是"测出来就是 0"，null 才是"没有结论"）。
// 稳定码取自 src/diag/error_codes.h（未就绪时用同名字面量，落地后逐字一致，见 diag 接线处）。
static long long rlp_epoch_ms() {
    return (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch()).count();
}
static std::string health_failure_json(const std::string& code, const std::string& msg,
                                       const rta::analysis::TrackHealth* h = nullptr,
                                       const std::string& rid = std::string()) {
    std::ostringstream j;
    j << "{\"ok\":false,\"usable\":false,\"code\":\"" << jesc(code) << "\""
      << ",\"error\":\"" << jesc(msg) << "\"";
    if (!rid.empty()) j << ",\"rid\":\"" << jesc(rid) << "\"";
    j << ",\"health\":{\"dr_db\":null,\"lufs\":null,\"lra\":null,\"peak_dbfs\":null"
      << ",\"true_peak_dbtp\":null,\"true_peak_available\":false"
      << ",\"dr_available\":false,\"lra_available\":false,\"lufs_available\":false"
      << ",\"lossless_suspected\":false,\"cutoff_hz\":null,\"confidence\":null"
      << ",\"reason\":\"\",\"fake24\":false"
      << ",\"duration_sec\":" << (h ? h->durationSec : 0.0)
      << ",\"fs\":" << (h ? (unsigned long long)h->fs : 0ull)
      << ",\"channels\":" << (h ? h->channels : 0)
      << ",\"bits\":" << (h ? h->bits : 0)
      << ",\"status\":\"error\",\"error\":\"" << jesc(msg) << "\""
      << ",\"analyzed_at_ms\":" << (h && h->analyzedAtMs > 0 ? (long long)h->analyzedAtMs : rlp_epoch_ms())
      << ",\"quality\":{\"available\":false,\"hf_ratio_10k_available\":false,\"side_mid_available\":false}}}";
    return j.str();
}

// 空的 UPnP 设备列表必须给出"为什么 + 怎么办"。
// 2026-10-28 用户反馈「UPnP 搜不到设备」时，界面只有「共发现 0 个渲染器」，
// 分不清是设备没开机、组播被拦，还是本机路由把局域网段交给了虚拟网卡。
// 判据全部来自 UpnpDiscoverDiag（实测字段），不猜。
static std::string upnp_empty_hint(const rta::net::UpnpDiscoverDiag& d) {
    std::string h = "未发现 UPnP/DLNA 渲染器。";
    const bool mcast_dead = (d.multicast_sent == 0 && d.send_failed > 0);
    if (mcast_dead && d.broadcast_sent > 0) {
        h += "本机 SSDP 组播发不出去（常见于「Internet 共享」把同一网段抢成虚拟网桥、代理 TUN "
             "抢占路由，或进程被系统/沙箱限制），已自动改用子网广播探测；如果设备就在隔壁，"
             "请确认它已开机并开启了 DLNA/UPnP 渲染器功能。";
    } else if (mcast_dead) {
        h += "组播和广播都发不出去（见 diag 的失败原因），请检查网络连接与代理设置。";
    } else if (d.replies > 0 && d.describe_failed > 0) {
        h += "收到 " + std::to_string(d.replies) + " 个应答，但抓不到设备描述（" +
             std::to_string(d.describe_failed) + " 个失败）—— 多为本机到设备的路由被虚拟网卡抢走，"
             "或设备描述端口被防火墙拦。";
    } else {
        h += "同网段内没有渲染器应答 M-SEARCH：确认设备已开机、与电脑在同一局域网、"