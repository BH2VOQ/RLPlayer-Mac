// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
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
//     UI 的 backend 值不动（§10 契约"不要改 UI"）："wasapi"/空 → CoreAudio 独占（Hog+物理格式），
//     "wasapi-shared" → CoreAudio shared（OpenSpec.shared 就是照 WASAPI 共享语义设计的）；
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
#include "analysis/version_compare_json.h" // F-8: reachable comparison and valid JSON
#include "meta/artwork.h"            // F-4：艺人头像全信源调度（provider.h 能力矩阵派生）
#include "meta/enrich.h"            // 单曲元数据补全编排(播放触发 + /api/enrich + /api/meta 兜底)
#include "meta/writeback.h"         // P2 标签写回(remux + PCM 逐位门禁;/api/writeback 三端点)
#include "meta/knowledge.h"         // P3 资料层直连与缓存(/api/entity/knowledge)
#include "meta/retrieval.h"         // P3 资料层③ AI 综合检索(/api/entity/summary)
#include "meta/discogs.h"           // P3 资料层④b Discogs 版本推荐(/api/entity/versions)
#include "meta/statusflags.h"       // gpu/gpuUsed 组合语义（用户 261024-04 #8，/api/status 与 /api/signal 同源）
#include "dsp/filter_families.h"
#include "dsp/oversample_peak.h"
#include "dsp/eq_text.h"
#include "dsp/peq.h"               // 261024-02 #6：20 段参数均衡（RBJ 双二阶，float64 系数 / float32 处理）
#include "dsp/opra.h"
#include "dsp/dop.h"
#include "dsp/dsd_rate_convert.h"
#include "dsp/room_api.h"        // R-1：房间测量端点层（授权/计划/状态机）
#include "platform/macos/room_transport_coreaudio.h"   // F-3：同族整数倍 DSD→DSD 速率转换
#include "dsp/modulator.h"
#include "dsp/direct_sdm.h"
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
    //   "wasapi"        → CoreAudio 独占（AUHAL + Hog Mode）
    //   "wasapi-shared" → CoreAudio 共享（系统混音）
    //   "naa"           → macOS 不可用（make_sink 返回必然 open 失败的 sink；UI 已移除该项）
    //   "upnp"          → UPnP/DLNA 投放（CastManager）
    //   "null"          → 只跑 DSP 不出声
    // 2026-10-25（方案 C，用户选择）：Hog 独占做成独立开关。
    //   默认 false = 不抢 Hog ⟹ **系统音量条 / 音量键全程可用**（用户明确要求）；
    //   true      = 抢 Hog ⟹ 真独占（其他 App 声音被屏蔽），但系统音量失效 ——
    //               这是 macOS Hog Mode 的机制限制（实测：Hog 中其它进程改音量无效）。
    bool hogExclusive = false;
    std::string backend = "wasapi";   // 默认 = CoreAudio 独占（等价 WASAPI 独占语义）
    std::string naaHost;              // NAA 端点 host:port（macOS 不可用，仅老 conf 兼容）
    std::string upnpDev;              // UPnP/DLNA 渲染器（设备描述 URL；后端 = upnp 时使用）
    int    outChannels = 0;           // 0 = 跟随源
    double trim[8] = {0,0,0,0,0,0,0,0};   // 每声道增益 dB

    // ---- 输入 ----
    std::string inBackend = "none";   // none | wasapi（macOS 上 "wasapi" = CoreAudio 输入）
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
    double outRate = 0;
    int    outBits = 0;
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

// ---- 后台 detached 任务追踪（元数据补全 / 资料整理）----
// 2026-10-25（单进程合并）：这两类任务原来是纯 detached 线程，进程退出时没人等它们。
// CLI 形态下进程直接消失，系统一并收走；但 embedded 形态是**壳进程继续活着**，这些线程
// 还在摸 MetaStore/Library 单例 —— 所以 stop_embedded 必须给它们一个有界的收尾窗口
// （协作等待，绝不 force-kill；超时就如实记日志，不假装收干净了）。
// 声明放在这里（文件靠前）：两个 detach 点（meta_on_play / summary_job_start_fn）都在下方。
static std::atomic<int> g_bgJobs{0};
static std::mutex g_bgMx;
static std::condition_variable g_bgCv;

static void bg_job_begin() { g_bgJobs.fetch_add(1); }
static void bg_job_end() {
    g_bgJobs.fetch_sub(1);
    { std::lock_guard<std::mutex> lk(g_bgMx); }   // 与 wait_for 的谓词检查配对（避免丢唤醒）
    g_bgCv.notify_all();
}

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

static std::string urlDecode(const std::string& s) {
    std::string o;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size()) {
            auto hex = [](char c) -> int {
                if (c >= '0' && c <= '9') return c - '0';
                if (c >= 'a' && c <= 'f') return c - 'a' + 10;
                if (c >= 'A' && c <= 'F') return c - 'A' + 10;
                return -1;
            };
            const int a = hex(s[i + 1]), b = hex(s[i + 2]);
            if (a >= 0 && b >= 0) { o += (char)(a * 16 + b); i += 2; continue; }
        }
        if (s[i] == '+') o += ' ';
        else o += s[i];
    }
    return o;
}

// ---------------- F1：严格 UTF-8 校验（逐字节状态机）----------------
// fs::u8path 对非法 UTF-8 字节会抛异常 —— 而本服务对请求异常没有整体兜底，一次
// 编码不对的 file 参数就能把整个进程打崩（2026-10-22 两次复现）。所有把 file/dir
// 交给 fs 路径的端点必须先过这一关。拒绝：续字节错配、截断、过短编码、代理区、>U+10FFFF。
static bool valid_utf8(const std::string& s) {
    const unsigned char* p = (const unsigned char*)s.data();
    const size_t n = s.size();
    size_t i = 0;
    while (i < n) {
        const unsigned char c = p[i];
        int cont; uint32_t cp;
        if (c < 0x80) { ++i; continue; }                                  // 0xxxxxxx
        else if (c >= 0xC2 && c <= 0xDF) { cont = 1; cp = c & 0x1Fu; }    // 110xxxxx
        else if (c >= 0xE0 && c <= 0xEF) { cont = 2; cp = c & 0x0Fu; }    // 1110xxxx
        else if (c >= 0xF0 && c <= 0xF4) { cont = 3; cp = c & 0x07u; }    // 11110xxx
        else return false;                                                // C0/C1、F5..FF、续字节错位
        if (i + (size_t)cont >= n) return false;                          // 截断
        for (int k = 1; k <= cont; ++k) {
            const unsigned char cc = p[i + (size_t)k];
            if ((cc & 0xC0) != 0x80) return false;                        // 续字节必须 10xxxxxx
            cp = (cp << 6) | (uint32_t)(cc & 0x3Fu);
        }
        if ((cont == 1 && cp < 0x80) || (cont == 2 && cp < 0x800) ||
            (cont == 3 && cp < 0x10000)) return false;                    // 过短编码
        if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false; // 越界/代理区
        i += (size_t)cont + 1;
    }
    return true;
}

// F6：非法 UTF-8 字节替换为 U+FFFD（替换符）。playback.log 里可能出现旧版本写入或
// 外部工具追加的非 UTF-8 字节，直接塞进 JSON 会被浏览器当乱码。
static std::string utf8_sanitize(const std::string& s) {
    static const char kRepl[] = "\xEF\xBF\xBD";                            // U+FFFD
    std::string o; o.reserve(s.size() + 16);
    const size_t n = s.size();
    size_t i = 0;
    while (i < n) {
        const unsigned char c = (unsigned char)s[i];
        if (c < 0x80) { o += (char)c; ++i; continue; }
        int cont; uint32_t cp;
        if      (c >= 0xC2 && c <= 0xDF) { cont = 1; cp = c & 0x1Fu; }
        else if (c >= 0xE0 && c <= 0xEF) { cont = 2; cp = c & 0x0Fu; }
        else if (c >= 0xF0 && c <= 0xF4) { cont = 3; cp = c & 0x07u; }
        else { o += kRepl; ++i; continue; }
        bool ok = (i + (size_t)cont < n);
        if (ok) {
            for (int k = 1; k <= cont; ++k) {
                const unsigned char cc = (unsigned char)s[i + (size_t)k];
                if ((cc & 0xC0) != 0x80) { ok = false; break; }
                cp = (cp << 6) | (uint32_t)(cc & 0x3Fu);
            }
        }
        if (ok && cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF) &&
            !((cont == 1 && cp < 0x80) || (cont == 2 && cp < 0x800) || (cont == 3 && cp < 0x10000))) {
            o.append(s, i, (size_t)cont + 1);                              // 合法序列原样保留
            i += (size_t)cont + 1;
        } else {
            o += kRepl; ++i;                                               // 坏起点换 U+FFFD，只前进 1 字节
        }
    }
    return o;
}

// 解析 "k=v&k=v"（**只解析 body**，不读 conf）
// 2026-10-27（L-2 重构）：原来把"conf 兜底"直接缝在这个函数尾部，导致**所有**调用方都被兜底，
// 其中包括 /api/repeat —— 它复用 `rate` 字段传循环模式，于是 conf 里的 rate=96000 会把它算成
// 非法值判 0，把用户的循环设置静默清掉（实测复现过）。现在 conf 兜底拆成下面独立的
// apply_conf_defaults_for_play()，只由真正"开始播放"的路径调用。
static PlayParams parseForm(const std::string& body, std::set<std::string>* seenOut = nullptr) {
    PlayParams p;
    std::istringstream is(body);
    std::string tok;
    std::set<std::string> seen;
    while (std::getline(is, tok, '&')) {
        const size_t e = tok.find('=');
        if (e == std::string::npos) continue;
        const std::string k = urlDecode(tok.substr(0, e));
        const std::string v = urlDecode(tok.substr(e + 1));
        seen.insert(k);
        if      (k == "file")     p.file = v;
        else if (k == "filter")   p.filter = v;
        else if (k == "filterNx") p.filterNx = v;
        else if (k == "shaper")   p.shaper = v;
        else if (k == "rate")     p.rate = v;
        else if (k == "volume")   p.volume = atof(v.c_str());
        else if (k == "hogexcl")  p.hogExclusive = (v == "1" || v == "true");
        else if (k == "gpu")      p.gpu = (v == "1");
        else if (k == "isp")      p.isp = (v == "1");
        else if (k == "twostage") p.twoStage = (v == "1");
        else if (k == "dsd")      p.dsd = atoi(v.c_str());
        else if (k == "modorder") p.modOrder = atoi(v.c_str());
        else if (k == "modfamily") p.modFamily = v;
        else if (k == "oobgain")   p.oobGain = atof(v.c_str());
        else if (k == "ahmbits")   p.ahmBits = atoi(v.c_str());
        else if (k == "gpuvendor") p.gpuVendor = v;
        else if (k == "dsdnative") p.dsdNative = (v == "1");
        else if (k == "directsdm") p.directSdm = (v == "1");
        else if (k == "dsdkind")  p.dsdKind = v;
        else if (k == "dsdconv")  p.dsdConv = v;
        else if (k == "dsd2stage") p.dsd2Stage = (v == "1" || v == "true");
        else if (k == "loudness") p.loudness = (v == "1");
        else if (k == "buffer")   p.bufferMs = std::max(10, atoi(v.c_str()));
        else if (k == "device")   p.device = v;
        else if (k == "bits")     p.bits = atoi(v.c_str());
        else if (k == "taps")     p.taps = atoi(v.c_str());
        else if (k == "mintapsperinput") p.minTapsPerInput = atoi(v.c_str());
        else if (k == "atten")    p.atten = atof(v.c_str());
        else if (k == "transition") p.transition = atof(v.c_str());
        else if (k == "phase")    p.phase = v;
        else if (k == "modcut")   p.modCutoff = atof(v.c_str());
        else if (k == "moddith")  p.modDither = atof(v.c_str());
        else if (k == "ir")       p.convIr = v;
        else if (k == "eq")       p.eqFile = v;
        else if (k == "irgpu")    p.convGpu = (v == "1");
        else if (k == "ramp")     p.volRamp = atof(v.c_str());
        else if (k == "sdmfilt")   p.sdmFilter = v;
        else if (k == "sdmfiltnx") p.sdmFilterNx = v;
        else if (k == "backend") p.backend = v;
        else if (k == "naahost") p.naaHost = v;
        else if (k == "upnpdev")  p.upnpDev = v;
        else if (k == "channels") p.outChannels = atoi(v.c_str());
        else if (k == "trim") {
            std::istringstream ts(v);
            std::string tv;
            for (int i = 0; i < 8 && std::getline(ts, tv, ','); ++i) p.trim[i] = atof(tv.c_str());
        }
        else if (k == "inbackend") p.inBackend = v;
        else if (k == "indev")    p.inDevice = v;
        else if (k == "inoffset") p.inOffset = atoi(v.c_str());
        else if (k == "inbuf")    p.inBufferMs = std::max(10, atoi(v.c_str()));
        else if (k == "inmon")    p.inMonitor = (v == "1");
        else if (k == "srcbits") p.srcBits = atoi(v.c_str());
        // ReplayGain / Album Gain
        else if (k == "rgmode" || k == "rg_mode" || k == "rg.mode" || k == "rg") p.rgMode = v;
        else if (k == "rgpreamp" || k == "rg_preamp" || k == "rg.preamp" || k == "preamp") p.rgPreamp = atof(v.c_str());
        else if (k == "rgpreventclip" || k == "rgpreventclipping" || k == "rg_preventclipping" || k == "rg.preventclipping" || k == "rg.preventClipping")
            p.rgPreventClip = (v == "1" || v == "true");
        // CUE 分轨区间（秒，浮点）。不带 cue_start ⟹ 整首（cueStart 保持 -1）。
        else if (k == "cue_start") p.cueStart = atof(v.c_str());
        else if (k == "cue_end")   p.cueEnd   = atof(v.c_str());
        else if (k == "rid")     p.remoteId = v;
        else if (k == "rsuffix") p.remoteSuffix = v;
        else if (k == "rtitle")  p.remoteTitle = v;
    }
    // 把"body 里确实出现过的键"交回调用方，供 apply_conf_defaults_for_play 判断哪些该兜底。
    if (seenOut) *seenOut = seen;
    return p;
}

// L-2：对 body 中未出现的**播放偏好**从 rlplayer-settings.conf 兜底。
//
// 为什么单独成函数，而不是缝在 parseForm 末尾：
//   parseForm 有 4 个调用方（/api/play、/api/add、/api/lib/play、/api/repeat），
//   其中 /api/repeat 复用的是 `rate` 字段来传循环模式（0/1/2）。
//   兜底一旦无差别生效，conf 里的 rate=96000 就会被 atoi 成 96000 > 2 判非法 → 归 0，
//   用户的"循环列表/单曲"被静默清成"不循环"（已实测复现）。
//   ⟹ 兜底只属于"真的要把参数用于播放"的路径，不能属于"解析表单"这个公共动作。
//
// 严格绝缘（这些键**永不**从 conf 兜底，否则会串烧队列 / CUE / 远程曲目）：
//   file, cue_start, cue_end, rid, rsuffix, rtitle, initialSeekFrac, srcbits, dsdnative
static PlayParams apply_conf_defaults_for_play(const PlayParams& in, const std::set<std::string>& seen) {
    PlayParams p = in;
    const auto conf = load_conf_map();
    auto getConf = [&](const std::string& key) -> std::string {
        auto it = conf.find(key);
        return it != conf.end() ? it->second : std::string();
    };
    auto hasConf = [&](const std::string& key) -> bool {
        return conf.find(key) != conf.end();
    };

    if (seen.find("rate") == seen.end() && hasConf("rate")) {
        p.rate = getConf("rate");
    }
    if (seen.find("filter") == seen.end() && hasConf("filter")) {
        p.filter = getConf("filter");
    }
    if (seen.find("filterNx") == seen.end() && hasConf("filterNx")) {
        p.filterNx = getConf("filterNx");
    }
    if (seen.find("shaper") == seen.end() && hasConf("shaper")) {
        p.shaper = getConf("shaper");
    }
    if (seen.find("twostage") == seen.end() && hasConf("twostage")) {
        p.twoStage = (getConf("twostage") == "1" || getConf("twostage") == "true");
    }
    if (seen.find("isp") == seen.end() && hasConf("isp")) {
        p.isp = (getConf("isp") == "1" || getConf("isp") == "true");
    }
    if (seen.find("dsd") == seen.end() && hasConf("dsd")) {
        p.dsd = atoi(getConf("dsd").c_str());
    }
    if (seen.find("directsdm") == seen.end() && hasConf("directsdm")) {
        p.directSdm = (getConf("directsdm") == "1");
    }
    if (seen.find("modorder") == seen.end() && hasConf("modorder")) {
        p.modOrder = atoi(getConf("modorder").c_str());
    }
    if (seen.find("modfamily") == seen.end() && hasConf("modfamily")) {
        p.modFamily = getConf("modfamily");
    }
    if (seen.find("buffer") == seen.end() && hasConf("buffer")) {
        p.bufferMs = std::max(10, atoi(getConf("buffer").c_str()));
    }
    if (seen.find("device") == seen.end() && hasConf("device")) {
        p.device = getConf("device");
    }
    if (seen.find("bits") == seen.end() && hasConf("bits")) {
        p.bits = atoi(getConf("bits").c_str());
    }
    if (seen.find("taps") == seen.end() && hasConf("taps")) {
        p.taps = atoi(getConf("taps").c_str());
    }
    if (seen.find("mintapsperinput") == seen.end() && hasConf("mintapsperinput")) {
        p.minTapsPerInput = atoi(getConf("mintapsperinput").c_str());
    }
    if (seen.find("atten") == seen.end() && hasConf("atten")) {
        p.atten = atof(getConf("atten").c_str());
    }
    if (seen.find("transition") == seen.end() && hasConf("transition")) {
        p.transition = atof(getConf("transition").c_str());
    }
    if (seen.find("phase") == seen.end() && hasConf("phase")) {
        p.phase = getConf("phase");
    }
    if (seen.find("modcut") == seen.end() && hasConf("modcut")) {
        p.modCutoff = atof(getConf("modcut").c_str());
    }
    if (seen.find("moddith") == seen.end() && hasConf("moddith")) {
        p.modDither = atof(getConf("moddith").c_str());
    }
    if (seen.find("ir") == seen.end() && hasConf("ir")) {
        p.convIr = getConf("ir");
    }
    if (seen.find("eq") == seen.end() && hasConf("eq")) {
        p.eqFile = getConf("eq");
    }
    if (seen.find("irgpu") == seen.end() && hasConf("irgpu")) {
        p.convGpu = (getConf("irgpu") == "1");
    }
    if (seen.find("ramp") == seen.end() && hasConf("ramp")) {
        p.volRamp = atof(getConf("ramp").c_str());
    }
    if (seen.find("hogexcl") == seen.end() && hasConf("hogexcl")) {
        p.hogExclusive = (getConf("hogexcl") == "1" || getConf("hogexcl") == "true");
    }
    if (seen.find("gpuvendor") == seen.end() && hasConf("gpuvendor")) {
        p.gpuVendor = getConf("gpuvendor");
    }
    if (seen.find("sdmfilt") == seen.end() && hasConf("sdmfilt")) {
        p.sdmFilter = getConf("sdmfilt");
    }
    if (seen.find("sdmfiltnx") == seen.end() && hasConf("sdmfiltnx")) {
        p.sdmFilterNx = getConf("sdmfiltnx");
    }
    if (seen.find("dsdkind") == seen.end() && hasConf("dsdkind")) {
        p.dsdKind = getConf("dsdkind");
    }
    if (seen.find("dsdconv") == seen.end() && hasConf("dsdconv")) {
        p.dsdConv = getConf("dsdconv");
    }
    if (seen.find("dsd2stage") == seen.end() && hasConf("dsd2stage")) {
        p.dsd2Stage = (getConf("dsd2stage") == "1" || getConf("dsd2stage") == "true");
    }
    if (seen.find("channels") == seen.end() && hasConf("channels")) {
        p.outChannels = atoi(getConf("channels").c_str());
    }
    if (seen.find("backend") == seen.end() && hasConf("backend")) {
        p.backend = getConf("backend");
    }
    if (seen.find("upnpdev") == seen.end() && hasConf("upnpdev")) {
        p.upnpDev = getConf("upnpdev");
    }
    if (seen.find("volume") == seen.end() && hasConf("volume")) {
        p.volume = atof(getConf("volume").c_str());
    }
    if (seen.find("loudness") == seen.end() && hasConf("loudness")) {
        p.loudness = (getConf("loudness") == "1");
    }
    if (seen.find("rgmode") == seen.end() && seen.find("rg_mode") == seen.end() &&
        seen.find("rg.mode") == seen.end() && seen.find("rg") == seen.end()) {
        if (hasConf("rg.mode")) p.rgMode = getConf("rg.mode");
        else if (hasConf("rg_mode")) p.rgMode = getConf("rg_mode");
        else if (hasConf("rgmode")) p.rgMode = getConf("rgmode");
        else if (hasConf("rg")) p.rgMode = getConf("rg");
    }
    if (seen.find("rgpreamp") == seen.end() && seen.find("rg_preamp") == seen.end() &&
        seen.find("rg.preamp") == seen.end() && seen.find("preamp") == seen.end()) {
        if (hasConf("rg.preamp")) p.rgPreamp = atof(getConf("rg.preamp").c_str());
        else if (hasConf("rg_preamp")) p.rgPreamp = atof(getConf("rg_preamp").c_str());
        else if (hasConf("rgpreamp")) p.rgPreamp = atof(getConf("rgpreamp").c_str());
        else if (hasConf("preamp")) p.rgPreamp = atof(getConf("preamp").c_str());
    }
    if (seen.find("rgpreventclip") == seen.end() && seen.find("rgpreventclipping") == seen.end() &&
        seen.find("rg_preventclipping") == seen.end() && seen.find("rg.preventclipping") == seen.end() &&
        seen.find("rg.preventClipping") == seen.end()) {
        if (hasConf("rg.preventClipping")) p.rgPreventClip = (getConf("rg.preventClipping") == "1" || getConf("rg.preventClipping") == "true");
        else if (hasConf("rg.preventclipping")) p.rgPreventClip = (getConf("rg.preventclipping") == "1" || getConf("rg.preventclipping") == "true");
        else if (hasConf("rg_preventclipping")) p.rgPreventClip = (getConf("rg_preventclipping") == "1" || getConf("rg_preventclipping") == "true");
        else if (hasConf("rgpreventclip")) p.rgPreventClip = (getConf("rgpreventclip") == "1" || getConf("rgpreventclip") == "true");
    }

    return p;
}

// CUE 分轨区间在日志/信号链里的统一写法（"4.000..8.000" / "4.000..end"）。
// 单独抽出来是因为 START / END / PLAY 三处都要写同一个东西 —— 三处各写一遍迟早写成三种格式。
static std::string cue_range_text(double cs, double ce) {
    char b[96];
    if (ce < 0.0) std::snprintf(b, sizeof(b), "%.3f..end", cs);
    else          std::snprintf(b, sizeof(b), "%.3f..%.3f", cs, ce);
    return std::string(b);
}

static void recent_add(const std::string& file, const std::string& title,
                       const std::string& artist, const std::string& album);

// ---------------- 输出后端 ----------------
// OutSink 接口与渲染主循环已迁至 src/audio/render_loop.h（测试与 rtaweb 共用同一份，
// RENDERFAIL 回归测试用 mock sink 真跑同一循环）。这里只放各后端的实现。

static SinkOpenOpts sink_opts(const PlayParams& p) {
    SinkOpenOpts o;
    o.device = p.device;
    o.naaHost = p.naaHost;
    o.bufferMs = p.bufferMs;
    return o;
}

// 播放器 exe 目录下的文件路径（定义在本文件后面；WasapiSink 的学习缓存要用，先声明）。
static std::string path_in_exe_dir(const char* name);


// ---------------- CoreAudio 输出后端（macOS）----------------
// 包装 platform::CoreAudioOutput（PLATFORM.md §13.9 真机实测 16/24/32 bit 0 LSB）。
// UI 的 backend 值（§10 契约不改 UI）："wasapi"/空 → 独占（Hog+物理格式，等价 WASAPI 独占语义）；
// "wasapi-shared" → OpenSpec.shared（等价 WASAPI 共享语义：不抢 Hog、不改物理格式）。
class CoreAudioSink : public OutSink {
public:
    bool open(const SinkOpenOpts& o, uint32_t rate, int ch, int bits) override {
        rta::platform::OpenSpec sp;
        sp.deviceId = o.device;
        sp.rate = rate;
        sp.bits = bits > 0 ? bits : 32;
        sp.channels = ch;
        sp.bufferMs = o.bufferMs > 0 ? (double)o.bufferMs : 100.0;
        sp.shared = shared_;
        // 2026-10-25（方案 C）：Hog 独占由独立开关控制，不再与 shared 绑定。
        // exclusive_ 由 make_sink 依据 PlayParams::hogExclusive 设置。
        sp.exclusive = exclusive_;
        if (!ao_->open(sp)) {
            err_ = std::string(rta::platform::output_error_text(ao_->last_error_class()));
            if (!ao_->last_error().empty()) err_ += "：" + ao_->last_error();
            return false;
        }
        return true;
    }
    bool start() override { return ao_->start(); }
    size_t buffer_frames() const override { return ao_->buffer_frames() ? ao_->buffer_frames() : 4096; }
    size_t write_one_period(const int32_t* pcm, size_t frames) override {
        const size_t w = ao_->write(pcm, frames);
        return w;
    }
    // 2026-10-25（音量修复，真 BUG）：render_loop 每 tick 调用 set_live_gain_db()
    // 但**此前没有任何 sink 覆盖它**（基类 render_loop.h:43 是空实现）
    // ⟹ 音量请求被静默丢弃，拖动音量条毫无反应。
    //
    // ⚠️ 语义关键（2026-10-25 二次修复，曾因此产生爆音）：
    //   render_loop 传进来的 db 是 **delta**（当前请求 − 起播时已应用），**不是绝对值**！
    //   源码：sink.set_live_gain_db(h.volDb->load() - h.startDb->load());
    //   所以这里必须做 base × 10^(delta/20)，其中 base = 起播时的基准增益。
    //   我第一版把 delta 直接当绝对值用（linear = 10^(delta/20)），再叠加
    //   「接管后 startDb = 硬件等效 dB」⟹ 滑块拉到 0 dB 时 delta = +16.4 dB
    //   ⟹ 3.98 倍增益 ⟹ 削波爆音。这就是"音量爆炸"的直接原因。
    //
    // 正确模型：
    //   * baseDb_ = 起播时用户请求的绝对音量（= startDb），设备层用它作为基准；
    //   * 每次收到 delta，绝对音量 = baseDb_ + delta，再换算线性增益；
    //   * 硬件音量已被接管置满（见 hw_volume_takeover），所以绝对增益完全由这里决定；
    //   * 限幅到 [-120, 0]：>0 dB 会削波，绝不允许（这是爆音的另一道闸）。
    void set_live_gain_db(double deltaDb) override {
        // 绝对音量 = 基准 + 增量（delta 语义）
        double absDb = baseDb_ + deltaDb;
        // 硬限幅：不允许正向增益（>0 dB 必削波），下限 -120 dB 视为静音
        if (absDb > 0.0) absDb = 0.0;
        if (absDb < -120.0) absDb = -120.0;
        // 滑块最左端是 -60 dB：<= -59.5 dB 一律视为真静音（linear = 0.0），解决「最低音量还有声音」
        const double linear = (absDb <= -59.5) ? 0.0 : std::pow(10.0, absDb / 20.0);
        ao_->set_gain(linear);
    }
    // 起播时调用：把"用户请求的绝对音量"设为基准（render_loop 之后只发 delta）
    void set_base_gain_db(double absDb) {
        if (absDb > 0.0) absDb = 0.0;
        if (absDb < -120.0) absDb = -120.0;
        baseDb_ = absDb;
        const double linear = (absDb <= -59.5) ? 0.0 : std::pow(10.0, absDb / 20.0);
        ao_->set_gain(linear);
    }
    void pause() override { ao_->pause(); }
    void resume() override { ao_->resume(); }
    void close() override { ao_->close(); }
    const std::string& last_error() const override { return err_; }
    // render_loop 的节奏依赖（实测教训 2026-10-25：不实现时它零等待空转，
    // 402 次重试在 1ms 内打满 200 次超时判据 → 秒判 RENDERFAIL，设备其实正常）。
    // AUHAL 没有 WASAPI 式事件句柄：按 ≤10ms 半周期轮询。环容量 ≥4 个缓冲周期，
    // 10ms 的轮询粒度不可能追不上设备 22.7µs/帧的消费速度。
    bool wait_event(int ms) override {
        const int nap = (ms > 0 && ms < 10) ? ms : 10;
        std::this_thread::sleep_for(std::chrono::milliseconds(nap));
        return true;
    }
    size_t frames_rendered() const { return ao_->frames_rendered(); }
    uint64_t underruns() const { return ao_->underruns(); }
    bool bit_perfect() const { return ao_->bit_perfect(); }
    // 2026-10-25：接管后音量条的起点 dB（原硬件音量的等效值）。
    // render_loop 的实时增益是「volDb − startDb」的**增量**，而接管已经把设备硬件音量
    // 置满并把等效增益写进设备层 ⟹ startDb 必须同步成这个等效值，否则会二次叠加：
    //   例：原硬件 0.15（−16.4 dB）→ 设备层已含 −16.4 dB，若 startDb 仍为 0，
    //   用户把音量条拉到 0 dB 时增量 = 0−0 = 0 ⟹ 实际响度还是 −16.4 dB，看起来"调不动"。
    bool hw_takeover_db(double& outDb) const {
        if (auto* p = dynamic_cast<rta::platform::CoreAudioOutput*>(ao_.get()))
            return p->hw_takeover_db(outDb);
        return false;
    }
    // out_peak/underruns 遥测走 OutSink 之外的直接查询（STAT 行用）
    void set_shared(bool sh) { shared_ = sh; }
    // 2026-10-25（方案 C）：严格独占开关。true = 抢 Hog（系统音量失效、其他 App 静音）；
    // false = 不抢 Hog（系统音量可用，默认）。见 OpenSpec::exclusive 的注释。
    void set_exclusive(bool ex) { exclusive_ = ex; }
private:
    std::unique_ptr<rta::platform::AudioOutput> ao_ = rta::platform::create_audio_output();
    bool shared_ = false;
    bool exclusive_ = false;   // 严格独占（抢 Hog）；默认 false = 系统音量可用
    double baseDb_ = 0.0;   // 起播时的绝对音量基准（set_live_gain_db 收到的是相对它的 delta）
    std::string err_;
};

// macOS 上不可用后端（naa）的占位：open 必然失败并把原因写进 last_error，
// 让"选到不可用后端"在界面上得到明确解释（§10：不假装出声）。
class UnavailableSink : public OutSink {
public:
    explicit UnavailableSink(std::string why) : why_(std::move(why)) {}
    bool open(const SinkOpenOpts&, uint32_t, int, int) override { return false; }
    bool start() override { return false; }
    size_t buffer_frames() const override { return 4096; }
    size_t write_one_period(const int32_t*, size_t) override { return 0; }
    const std::string& last_error() const override { return why_; }
private:
    std::string why_;
};

// Null output：完整跑 DSP，但样本直接丢掉。按实时节奏"消耗"，所以进度条与真播放一致。
// 用途：验证管线、量 CPU 占用、给频谱分析抓数据，都不必打开任何设备。
class NullSink : public OutSink {
public:
    bool open(const SinkOpenOpts& o, uint32_t rate, int ch, int bits) override {
        rate_ = rate ? rate : 44100; ch_ = ch;
        period_ = (size_t)((double)rate_ * (double)o.bufferMs / 1000.0);
        if (period_ < 256) period_ = 256;
        t0_ = now();
        return true;
    }
    bool start() override { return true; }
    size_t buffer_frames() const override { return period_; }
    size_t write_one_period(const int32_t* /*pcm*/, size_t frames) override {
        written_ += frames;
        pace(written_ / (double)rate_);
        return frames;
    }
    const std::string& last_error() const override { return err_; }
private:
    static double now() {
        return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    void pace(double audioSec) const {
        for (;;) {
            const double el = now() - t0_;
            if (el >= audioSec) return;
            double ms = (audioSec - el) * 1000.0;
            if (ms > 20.0) ms = 20.0;
            std::this_thread::sleep_for(std::chrono::milliseconds((long long)(ms > 0 ? ms : 1)));
        }
    }
    uint32_t rate_ = 44100;
    int ch_ = 2;
    size_t period_ = 4410;
    size_t written_ = 0;
    double t0_ = 0.0;
    std::string err_;
};

// ---------------- 当前活跃输出端点指针与 DoP 标记（/api/volume 实时直通透传）----------------
static std::atomic<OutSink*> g_activeSink{nullptr};
static std::atomic<bool>     g_activeDop{false};

struct ActiveSinkGuard {
    ActiveSinkGuard(OutSink* s, bool dop) {
        g_activeDop.store(dop);
        g_activeSink.store(s);
    }
    ~ActiveSinkGuard() {
        g_activeSink.store(nullptr);
        g_activeDop.store(false);
    }
};

static std::string path_in_exe_dir(const char* name);   // 定义在后面
static void play_log(const std::string& s);              // 定义在后面
static void play_log_rotate();

// E-11: 记录上一次播放以 END pos=0 error="" 结束的状态，供下一次 START 显式归因 PLAY_ABORT
struct LastPlayEnd {
    bool isPosZeroNoErr = false;
    std::string file;
    std::chrono::steady_clock::time_point tp{};
};
static std::mutex g_lastEndMx;
static LastPlayEnd g_lastEnd;

// ---------------- 设备独占支持率探测（带重试 + 上次成功结果缓存）----------------
// 为什么需要这一层（2026-10-22 现场事故，日志 playback (4).log 第 9~23 行）：
//   第一首 44.1k FLAC 按 rate=max 探到 96000 并正常播完；紧接着播第二首，同一端点、
//   同一设置的 exclusive_rates() 却【瞬时返回空列表】（上一首独占流 sink->close() 之后
//   约 165ms，端点正在重配置/占用切换），几毫秒后同一端点又能读到 48000/96000
//   （紧接着的错误路径里 probe_formats 就证明过）。旧代码 want = rr.empty() ? 0 : rr.back()
//   把「探测为空」静默当成「跟随源率」→ 按 44100 开独占流 → 端点只支持 48k/96k 族 →
//   在写 PLAY 之前就报错退出（日志里连 PLAY 都没有）。
// 三道防线，任一条生效都不会再犯：
//   ① 探测最多 3 次、间隔 40ms，第一次非空即返回（3×40ms=120ms 的起播延迟可接受，
//      比一次误判导致整首不出声便宜得多）；
//   ② 进程内按端点键缓存【上一次成功的列表】——「上一首刚用 96k 播完整首歌」本身就是
//      设备支持 96k 的铁证，不能让一次瞬时探测为空把它抹掉（铁律 3：判据要测对东西）；
//   ③ 探测为空且无缓存时，pick_output_rate 明确标 RATEPROBE_EMPTY（decided=false），
//      绝不静默当成「探测结果是源率」。
// 缓存键含位深与声道数：16-bit 与 24-bit 的独占支持列表本来就不同，混用等于造假数据。
static std::mutex g_rateCacheMtx;
static std::map<std::string, std::vector<uint32_t>> g_rateCache;

static std::string rate_cache_key(const std::string& devId, int bits, int channels) {
    // devId 为空 = "WASAPI 默认端点"：必须解析成真实端点 id 再当键，否则用户中途换了默认设备时
    // 会把上一个设备的支持列表当成新设备的（那就是造假数据）。
    std::string id = devId;
    if (id.empty()) {
        for (const auto& d : mac_enum_devices())
            if (d.isDefault && d.hasOutput) { id = d.id; break; }
        if (id.empty()) id = "(默认端点)";
    }
    return id + "|" + std::to_string(bits) + "bit|" + std::to_string(channels) + "ch";
}
// 容量的有界性：键 = 端点 id | 位深 | 声道数，端点数最多几十个、位深 3 档、声道数也只是个位数，
// 因此总量是「端点数 × 3 × 声道数」这个量级（几十~几百条），进程生命期内无需淘汰 —— 不是内存泄漏。
//
// ⚠️ key 必须在【锁外】算好：rate_cache_key 在 devId 为空时要 enumerate()（COM + 每个端点的
//    PropertyStore，本机 39 个端点）。把 COM 枚举放进全局锁里，一旦 COM 慢/卡，会同时冻住
//    播放线程和 web 线程（这把锁被 /api/rates 用，而 webui 是单线程 accept）。
static void rate_cache_put(const std::string& devId, int bits, int channels,
                           const std::vector<uint32_t>& rates) {
    if (rates.empty()) return;                 // 空列表绝不入缓存：否则一次瞬时故障把「什么都没有」永久固化
    const std::string key = rate_cache_key(devId, bits, channels);   // 锁外（可能 enumerate）
    std::lock_guard<std::mutex> lk(g_rateCacheMtx);
    g_rateCache[key] = rates;
}
static std::vector<uint32_t> rate_cache_get(const std::string& devId, int bits, int channels) {
    const std::string key = rate_cache_key(devId, bits, channels);   // 锁外（可能 enumerate）
    std::lock_guard<std::mutex> lk(g_rateCacheMtx);
    const auto it = g_rateCache.find(key);
    return it == g_rateCache.end() ? std::vector<uint32_t>() : it->second;
}

// 独占支持率探测：最多 tries 次、每次间隔 40ms，第一次非空即返回并刷新缓存。
// 不修改 wasapi_out.h 的行为 —— 重试策略只属于「调用方知不知道自己被瞬时态坑过」这一层。
static std::vector<uint32_t> probe_exclusive_rates(const std::string& deviceId, int bits,
                                                   int channels, int tries = 3) {
    std::vector<uint32_t> rr;
    for (int i = 0; i < tries; ++i) {
        if (i > 0)
            std::this_thread::sleep_for(std::chrono::milliseconds(40));   // 等端点从「刚关闭独占流」的重配置里恢复
        // macOS：CoreAudio caps() 是对设备的真实查询（AudioObjectGetPropertyData），语义等价
        auto out = rta::platform::create_audio_output();
        if (out) {
            const auto c = out->caps(deviceId);
            rr = c.rates;
        }
        if (!rr.empty()) { rate_cache_put(deviceId, bits, channels, rr); return rr; }
    }
    return rr;                     // 全空：调用方按「探测为空」处理（不是结论）
}

// 探测 + 缓存兜底：探测为空时退回该端点/位深/声道上一次成功的列表，并记一行 RATEPROBE_STALE。
// 为什么能力检查也要走这一层：rate=max 那一步即使靠缓存拿到了 96000，如果紧接着的能力检查
// 又探测为空，位深循环会认为「该位深什么都不支持」→ 仍旧硬失败 —— 缓存只救第一步等于没救。
// ⚠️ 如实说明：重试与缓存这两层依赖真实设备的瞬时态，没有自动化测试覆盖（离线造不出
//    端点重配置窗口），只有代码审查 + 逻辑推演 + 现场日志形态推演。
static std::vector<uint32_t> probe_rates_cached(const std::string& deviceId, int bits, int channels,
                                                const char* why, int tries = 3) {
    std::vector<uint32_t> rr = probe_exclusive_rates(deviceId, bits, channels, tries);
    if (!rr.empty()) return rr;
    rr = rate_cache_get(deviceId, bits, channels);
    if (!rr.empty()) {
        play_log(std::string("RATEPROBE_STALE ") + why + " 探测为空，沿用上次结果（最高 " +
                 std::to_string(rr.back()) + " Hz） bits=" + std::to_string(bits) +
                 " device=" + (deviceId.empty() ? std::string("默认端点") : deviceId));
    }
    return rr;
}
static void meta_on_play(const std::string& file);       // 定义在后面:播放触发的元数据补全(后台线程)

// F1：非法 UTF-8 的 file/dir 参数统一在此挡下 —— 记一行 play_log WARN（原始字节
// 十六进制前 64 字节，不含解释），返回统一错误 JSON。绝不把非法字节交给 fs::u8path。
static std::string utf8_path_reject(const std::string& path) {
    std::string hex;
    char b[4];
    const size_t nb = path.size() < 64 ? path.size() : 64;
    for (size_t i = 0; i < nb; ++i) { std::snprintf(b, sizeof(b), "%02X", (unsigned char)path[i]); hex += b; }
    play_log("WARN 拒绝非UTF-8路径 原始字节[" + std::to_string(path.size()) + "B]=" + hex);
    return "{\"ok\":false,\"error\":\"路径编码非 UTF-8(请用浏览器或 UTF-8 客户端)\"}";
}

// F2：enriched 语义 —— 「真的被在线补过」：任一字段 source ∈ 在线源集合，或缓存过封面。
// 只有本地 tag/user 写入的基本标签（如 studio 曲目自带 title/album）不再误显示「已补全」。
static bool meta_enriched(const rta::meta::TrackMeta& tm) {
    if (!tm.coverRelPath.empty()) return true;
    for (const auto& kv : tm.fields) {
        const std::string& s = kv.second.source;
        if (s == "qq" || s == "netease" || s == "itunes" || s == "lrclib" ||
            s == "musicbrainz" || s == "wiki" || s == "llm") return true;
    }
    return false;
}

// F1 兜底：播放线程里 recent_add 要的文件名主干。队列项理论上都来自已校验端点，
// 但 rlplayer-queue.txt 可被旧版本/手工编辑写坏 —— 非法字节绝不能进 fs::u8path
//（播放线程里抛异常 = 整进程终止），此时直接用原串当标题兜底。
static std::string stem_or_self(const std::string& file) {
    if (!valid_utf8(file)) return file;
    return pathToUtf8(fs::u8path(file).stem());
}

// 输出通道模式（F-5 的 outMode 取值）—— **mac 口径**，不是上游的 pcm|dop|native。
//   上游 outMode 表达的是"1-bit 通路怎么走"；mac 没有 ASIO 原生 DSD 通道，
//   Native DSD 在 /api/play 就被明确拒绝（见那里的 dsdnative 门），
//   所以这里表达的是**输出通道的独占/共享语义**，DSD 与否由 dsd/dsdRate 单独表达。
//   ★ 绝不允许出现 "wasapi" / "asio" / "native"：那是 Windows 的虚构通路（A-5 事故教训）。
static std::string out_mode_of_backend(const std::string& backend) {
    if (backend == "wasapi-shared") return "shared";   // CoreAudio 共享（系统混音）
    if (backend == "null")          return "null";     // 只跑 DSP 不出声
    if (backend == "upnp")          return "upnp";     // 投放：格式由远端渲染器决定
    // 空 / "wasapi" / 未知历史值（含老 conf 的 "asio"）一律落到 CoreAudio 独占 ——
    // 与 make_sink 的第二道闸完全同一口径（那边也是 else → CoreAudioSink 独占）。
    return "coreaudio";
}

static std::unique_ptr<OutSink> make_sink(const PlayParams& p) {
    // 守门（261024-01 #9）：backend=upnp 由 /api/play 直接转交投放会话，本地播放线程根本不该启动。
    // 万一将来有别的路径漏过来，也绝不能落到默认的本地独占后端 —— 那会真的接管本机声卡。
    if (p.backend == "upnp")           return std::make_unique<NullSink>();
    if (p.backend == "null")           return std::make_unique<NullSink>();
    // macOS（§10 契约不改 UI）：UI 的 backend 值映射到 CoreAudio 的两种模式。
    // "wasapi"/空 → 独占（Hog+物理格式，等价 WASAPI 独占语义）；
    // "wasapi-shared" → shared（OpenSpec.shared 按 WASAPI 共享语义设计）。
    // naa 在 macOS 无驱动体系：造一个必然 open 失败的 sink，把"不支持"如实报到界面。
    if (p.backend == "naa")
        return std::make_unique<UnavailableSink>("macOS 版暂不支持 NAA / RTANet 推流（Windows 专属后端）");
    // 2026-10-25（task-12）：ASIO 分支已删除。未知/历史 backend 值（含老 conf 里的 "asio"）
    // 一律落到 CoreAudio 独占 —— 前端 migrateRemovedBackend() 会先把它降级成 wasapi 并提示，
    // 这里是第二道闸：即便绕过 UI 直接调 /api/play，也不会落到一个空指针或假装成功。
    auto s = std::make_unique<CoreAudioSink>();
    s->set_shared(p.backend == "wasapi-shared");
    // 2026-10-25（方案 C）：Hog 独占开关。共享模式本来就不该抢 Hog。
    s->set_exclusive(p.hogExclusive && p.backend != "wasapi-shared");
    return s;
}

// ---------------- UPnP / DLNA 输出后端（261024-01 #9）----------------
// 用户原话：「输出，后端没有 UPNP 选项，那你是怎么测试连接我的数播的？漏了就给我加上」。
//
// 设计：不另起一套控制。后端下拉选中 upnp 后，播放启动路径（/api/play、/api/skip）
// 把曲目交给现有的 CastManager（cast_service.h：本地 HTTP 供源 + AVTransport），
// 底栏的暂停 / 跳转 / 停止也映射到同一条投放会话 —— 一条会话、一个状态源。
//
// 已知限制（写进 docs/WIP-t24-out.md）：投放按「源文件原采样率」供源，
// 不经过播放器的升频 / 滤波器 / EQ / 音量 / DSP 链（cast_service 只做解码 → WAV/DoP）。
// 要"把 DSP 处理后的流实时推给渲染器"需要另外的牵引式流式供源，本轮不做。
static std::atomic<bool> g_upnpPlayer{false};   // true = 当前"播放器"由投放会话承担

// DSD 源（.dsf/.dff）必须走 DoP 打包：cast_service 对未开 DoP 的 DSD 会明确拒绝，
// 而不是悄悄转码成 PCM 降质输出（铁律 3）。
static bool upnp_is_dsd_file(const std::string& file) {
    const std::string ext = rta::audio::lowerExt(file);
    return ext == ".dsf" || ext == ".dff";
}

// 把一条曲目交给投放会话。切歌 / 重播都走这里：先停旧会话再起新会话
//（CastManager 同一时刻只允许一条会话）。失败原因原样返回，界面直接显示，不假装成功。
static bool upnp_start_track(const PlayParams& p, const std::string& file, std::string& err) {
    if (p.upnpDev.empty()) {
        err = "未选择 UPnP / DLNA 渲染器：设置 → 输出 → 目标渲染器（点「重新发现」刷新列表）";
        return false;
    }
    if (file.empty()) { err = "未指定曲目"; return false; }
    rta::net::CastStartParams cp;
    cp.dev  = p.upnpDev;
    cp.file = file;
    cp.port = 8912;
    cp.rate = 0;              // 0 = 按源文件原采样率供源
    // bits 必须留 0：cast_service 只在 rate==0 && bits==0 时走「源 WAV 原文件直供」的
    // 逐位直通分支；传了非 0 位深会落进重采样/位深转换分支，等于悄悄降质。
    cp.bits = 0;
    cp.seconds = 0.0;
    // DSD 源必须 DoP 打包（cast_service 对未开 DoP 的 DSD 会明确拒绝 —— 铁律 3：不悄悄转码降质）
    cp.dop = upnp_is_dsd_file(file) || p.dsd >= 64;
    rta::net::CastManager::instance().stop();
    const auto r = rta::net::CastManager::instance().start(cp);
    if (!r.ok) { err = "UPnP 投放启动失败：" + r.error; return false; }
    return true;
}

// 投放模式下写播放器状态：底栏从 /api/status 读这些字段，必须与投放会话口径一致。
static void upnp_mark_player_state(const std::string& file, bool ok, const std::string& err) {
    auto& ps = g_ps;
    std::lock_guard<std::mutex> lk(ps.mtx);
    if (ok) {
        ps.current = file;
        ps.error.clear();
        ps.bpState = "no";
        ps.bpWhy = "UPnP 投放：源文件按原采样率供源，渲染器侧是否重采样由对方决定（本机 DSP 未介入）";
        ps.rgMode = "bypassed";
        ps.rgAppliedDb = 0.0;
        ps.rgClipLimited = false;
        ps.rgSource = "upnp:bypassed";
        ps.rgNote = "UPnP 投放：源文件直供，本机 ReplayGain 旁路";
        // F-5：投放模式下输出格式由**远端渲染器**决定，本机无从自证 ⟹
        //   dsd/dsdRate/carrierRate/modFamily/modOrder 一律归零（绝不许拿上一首本地播放的
        //   残留值冒充远程事实，与 ps.gpu 在投放模式归零是同一条纪律），
        //   fallbackWhy 如实说明"无法自证"而不是留空（留空 = 声称"没降级"，那是假话）。
        ps.outMode        = "upnp";
        ps.outDsdLevel    = 0;
        ps.outDsdRate     = 0;
        ps.outCarrierRate = 0;
        ps.outModFamily.clear();
        ps.outModOrder    = 0;
        ps.outFallbackWhy = "UPnP 投放：输出格式与采样率由远端渲染器决定（本机 DSP 未介入，无法自证）";
    } else {
        ps.error = err;
        ps.bpState = "no";
        ps.bpWhy = err;
    }
}

// ---------------- NAA 端点自动发现（261024-01 #11）----------------
// 用户原话：「NAA 端点（host:port）这个选项不应该出现啊，应该是自动获取的啊」。
// 探测本体在 tools/naa_discover.h（与 CLI naa_scan 共用）。这里做异步任务：
// Web UI 是单线程 accept，同步扫 254 个主机（每个最长 300ms）会把 /api/status 全部堵住，
// 所以扫描放后台线程，前端轮询同一端点直到 scanning=false。
static std::string naa_discover_json(bool) {
    return "{\"ok\":false,\"error\":\"macOS 版暂不支持 NAA 端点发现（Windows 专属）\"}";
}

// ---------------- Native DSD 采样率判定（上游 6bd21a6）----------------
// Native DSD 按源位率直通，不做升频。
// ⚠️ 2026-10-25 修：这里原来只认 "" 和 "src"，而**设置页/conf 里「跟随源」写的是 "follow"**
//（ui_script.h 的 sRate 第一项、rtaweb.cpp 的 rateAuto 也都把 follow 当跟随源）。
// 后果是 GUI 用户明明选的就是「跟随源」，却被告知「请改成跟随源」——永远用不了原生 DSD。
// 现在三种等价写法都接受；"max"（要升频）和具体数字（要换率）仍然明确拒绝。
// ---------------- DirectSDM：源 DSD 与目标 DSD 同速率时的逐位直通 ----------------
// 判定必须在解码之前：DSD256 整曲解成 PCM 要几百 MB，先判再决定路径。
static bool direct_sdm_eligible(const PlayParams& p, const DsdInfo& info, std::string& why) {
    if (p.dsdNative) { why = "DSD Native 还没实现（它走 Native DSD 驱动通道，不是 DoP）"; return false; }
    if (p.dsd < 64) { why = "输出不是 DSD：把 SDM 页的比特率选成 DSD64/128/256（DoP）"; return false; }
    const uint32_t base = (info.rate % 48000u == 0) ? 48000u : 44100u;
    const uint32_t target = rta::dsp::dsd_rate(p.dsd, base);
    bool anyProc = !p.eqFile.empty() || !p.convIr.empty() || p.loudness;
    rta::dsp::replaygain::Mode rgm = rta::dsp::replaygain::Mode::Off;
    if (rta::dsp::replaygain::parse_mode(p.rgMode, &rgm) && rgm != rta::dsp::replaygain::Mode::Off) anyProc = true;
    for (int i = 0; i < 8; ++i) if (p.trim[i] != 0.0) anyProc = true;
    if (p.outChannels > 0 && p.outChannels != info.channels) anyProc = true;   // 声道数变化也是处理
    const auto d = rta::dsp::direct_sdm_decision(info.rate, target, anyProc, p.volume != 0.0);
    // F-3（2026-10-27）：源 DSD 与目标同族不同速率时，不再一律退回「ffmpeg 解 PCM 再调制」。
    // 只要 plan_dsd_rate 说同族整数倍可行，就先做 1-bit→1-bit 速率转换，再走直通。
    // 为什么值得：退回 PCM 重调制要多一次抽取+插值+SDM，且会丢掉源自身的 1-bit 噪声形状；
    // 而 DSD→DSD 转换的实测代价是 DSD64→128 的 THD+N 与「原样」差 +0.002 dB（模块自述判据）。
    if (!d.enabled && info.rate != 0 && target != 0) {
        const auto plan = rta::dsp::plan_dsd_rate(info.rate, target);
        if (plan.ok()) {
            why = "源 DSD " + std::to_string(info.rate) + " Hz → 目标 " + std::to_string(target) +
                  " Hz 同族整数倍：先做 1-bit 速率转换再直通";
            return true;
        }
        why = d.reason + "；且速率转换不可行：" + plan.note;
        return false;
    }
    why = d.reason;
    return d.enabled;
}

// 直接播放 DSD 源：1-bit 流按 16 位整数倍切片 → DoP 24-bit 载波 → 输出后端。
// 不经过 PCM、不调制、不做音量/抖动 —— 这正是"逐位一致"的前提。
static bool play_one_direct(const std::string& file, const PlayParams& p) {
    auto& ps = g_ps;
    play_log_rotate();
    g_dbgPeak.store(0.0);
    g_dbgClip.store(0);
    RtTune rt = rta::audio::apply_playback_tuning();
    struct RtGuard { RtTune* t; ~RtGuard() { rta::audio::release_playback_tuning(*t); } } rtg{ &rt };
    try {
        ps.decodeMs.store(0);
        ps.ffmpegMs.store(0);
        ps.wavReadMs.store(0);
        ps.dspChunkUs.store(0);
        ps.dspTotalUs.store(0);
        ps.dspChunks.store(0);
        const auto t_dsd_0 = std::chrono::steady_clock::now();
        DsdStream src = read_dsd(file);
        const auto t_dsd_1 = std::chrono::steady_clock::now();
        const double dsdMs = std::chrono::duration<double, std::milli>(t_dsd_1 - t_dsd_0).count();
        ps.decodeMs.store((long long)(dsdMs + 0.5));
        if (src.rate == 0 || src.bits == 0) {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error = "DSD 解码结果为空：" + file;
            return false;
        }
        // 共享模式不支持 DoP/DSD：共享会经系统混音引擎重采样，DoP 载波（0x05/0xFA 标记）
        // 一旦被重采样就不再是合法 DoP，接收端判非法并静音 —— 必须明确报错而不是降质播放。
        if (p.backend == "wasapi-shared") {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error = "共享模式不支持 DoP/DSD（共享会重采样破坏 DoP 载波），请切换到独占模式。";
            return false;
        }
        const uint32_t srcRate = src.rate;
        const uint32_t carrier = srcRate / 16u;
        const int      ch = src.channels;
        const size_t   totalFrames = (size_t)(src.bits / 16ull);   // DoP 帧数（每声道）
        if (totalFrames == 0) {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error = "DSD 数据不足一个 DoP 帧（16 位）";
            return false;
        }
        // ---- CUE 分轨（2026-10-25）：1-bit 直通（DirectSDM / DoP 回落）同样按区间播 ----
        // 换算：totalFrames 是 DoP 帧（= 1-bit 样点/16），区间是"秒" ⟹
        //   帧号 = 秒 × srcRate / 16（srcRate 就是 1-bit 位率）。
        // 不实现这一档的代价很实在：SACD 整轨 .dsf + cue 在 DirectSDM 下会从文件头开播，
        // 用户听到的是第 1 首而进度条显示第 5 首 —— 静默错位比报错更难查。
        size_t frameBase = 0, frameCount = totalFrames;
        if (p.cueStart >= 0.0) {
            const double fileSec = (double)totalFrames / (double)carrier;
            const double framesPerSec = (double)srcRate / 16.0;   // DoP 帧/秒
            auto cueFail = [&](const std::string& why) {
                play_log("CUE_REJECT " + why + " cue=" + cue_range_text(p.cueStart, p.cueEnd) +
                         " file=" + file);
                std::lock_guard<std::mutex> lk(ps.mtx);
                ps.error = why;
                return false;
            };
            if (p.cueEnd >= 0.0 && p.cueEnd <= p.cueStart)
                return cueFail("CUE 分轨区间非法：终点 " + std::to_string(p.cueEnd) +
                               "s 不大于起点 " + std::to_string(p.cueStart) + "s（文件 " +
                               std::to_string(fileSec) + "s）：" + file);
            const long long b = (long long)std::llround(p.cueStart * framesPerSec);
            if (b < 0 || (size_t)b >= totalFrames)
                return cueFail("CUE 分轨起点越界：起点 " + std::to_string(p.cueStart) +
                               "s ≥ 文件时长 " + std::to_string(fileSec) + "s：" + file);
            long long e = (p.cueEnd >= 0.0) ? (long long)std::llround(p.cueEnd * framesPerSec)
                                            : (long long)totalFrames;
            if (e > (long long)totalFrames) e = (long long)totalFrames;
            if (e <= b)
                return cueFail("CUE 分轨区间越界：" + cue_range_text(p.cueStart, p.cueEnd) +
                               " 落在文件时长 " + std::to_string(fileSec) + "s 之外：" + file);
            frameBase  = (size_t)b;
            frameCount = (size_t)(e - (long long)b);
            play_log("CUE_RANGE cue=" + cue_range_text(p.cueStart, p.cueEnd) +
                     " base=" + std::to_string(frameBase) + " frames=" + std::to_string(frameCount) +
                     " carrier=" + std::to_string(carrier) + " fileSec=" + std::to_string(fileSec) +
                     " path=direct-sdm file=" + file);
        }
        const size_t   frameEnd = frameBase + frameCount;

        // ---- F-3：DSD→DSD 速率转换（同族整数倍）----
        // 只在"目标档位与源不同"时做；同速率完全不进这里（保持逐位直通）。
        // 失败必须明确报错并回退普通路径，绝不静默按源速率播（那会让用户以为升频生效了）。
        if (p.dsd >= 64) {
            const uint32_t base = (src.rate % 48000u == 0) ? 48000u : 44100u;
            const uint32_t targetRate = rta::dsp::dsd_rate(p.dsd, base);
            if (targetRate != src.rate) {
                const auto plan = rta::dsp::plan_dsd_rate(src.rate, targetRate);
                if (plan.ok()) {
                    try {
                        rta::audio::DsdStream converted;
                        const auto cr = rta::dsp::convert_dsd_stream(src, targetRate,
                                                                     rta::dsp::DsdRateConvertConfig{}, converted);
                        play_log("DSD_RATE src=" + std::to_string(src.rate) + " dst=" +
                                 std::to_string(targetRate) + " rt=" + std::to_string(cr.realtimeFactor) +
                                 " headroomDb=" + std::to_string(cr.headroomDb) +
                                 " ms=" + std::to_string(cr.totalMs) +
                                 (cr.steppedDown ? (" stepdown=" + cr.stepDownReason) : std::string()));
                        src = std::move(converted);
                    } catch (const std::exception& e) {
                        std::lock_guard<std::mutex> lk(ps.mtx);
                        ps.error = std::string("DSD 速率转换失败（不按源速率静默播放）：") + e.what();
                        return false;
                    }
                } else {
                    std::lock_guard<std::mutex> lk(ps.mtx);
                    ps.error = "DSD 速率转换不可行：" + plan.note;
                    return false;
                }
            }
        }

        // 设备能力：DoP 载波率是源 DSD/16，本机 DAC 不一定支持（DSD256 要 705.6 kHz）。
        // HF-01 接线（2026-10-22）：空支持列表一律当「不支持/端点异常」，绝不静默放行（交接单 §6）。
        // DoP 固定 24-bit 容器，不参与位深回退（维持现状）。
        if (p.backend.empty() || p.backend == "wasapi") {
            const std::vector<uint32_t> rates = probe_exclusive_rates(p.device, 24, ch);
            bool ok = false;
            for (auto r : rates) if (r == carrier) ok = true;
            if (!ok) {
                std::string list;
                for (size_t i = 0; i < rates.size(); ++i) { if (i) list += " / "; list += std::to_string(rates[i]); }
                std::lock_guard<std::mutex> lk(ps.mtx);
                ps.error = rates.empty()
                    ? ("设备独占支持列表为空（端点不可用或 24-bit 容器不被接受），无法确认 DirectSDM 所需的 DoP 载波 " +
                       std::to_string(carrier) + " Hz。")
                    : ("设备不支持 DirectSDM 所需的 DoP 载波 " + std::to_string(carrier) +
                       " Hz。设备支持：" + list);
                return false;
            }
        }

        ps.outRate = carrier;
        ps.outBits = 24;
        ps.total.store(frameCount);   // CUE 分轨：本区间的 DoP 帧数（不是整轨）
        ps.played.store(0);
        ps.startDb.store(0.0);
        ps.volDb.store(0.0);
        ps.gpu = false;
        ps.gpuConvUsed.store(false);   // 直通路径不会有卷积，显式归零（#8）
        ps.rgMode = "off";
        ps.rgAppliedDb = 0.0;
        ps.rgClipLimited = false;
        ps.rgSource = "directsdm:bypass";
        ps.rgNote = "DirectSDM 1-bit 直通，跳过 PCM 增益处理";

        // 信号链快照：DirectSDM 只有"源 → DoP → 设备"三环，如实写出来
        {
            std::string dev = "默认音频设备";
            if (p.backend == "naa") dev = p.naaHost.empty() ? "NAA 127.0.0.1:43210" : p.naaHost;
            else if (p.backend == "null") dev = "Null 输出（不出声）";
            else { std::string di; mac_find_dev(std::string(), dev, di); }
            std::ostringstream sig;
            sig << "{\"src\":\"" << jesc(file) << "\""
                << ",\"codec\":\"dsd\""
                << ",\"inRate\":" << srcRate
                << ",\"inBits\":1"
                << ",\"inCh\":" << ch
                << ",\"dur\":" << (double)frameCount / (double)carrier   // CUE：本区间时长
                << ",\"cueStart\":" << p.cueStart
                << ",\"cueEnd\":" << p.cueEnd
                << ",\"fileDur\":" << (double)totalFrames / (double)carrier
                << ",\"note\":\"" << jesc(std::string("DirectSDM：1-bit 直通，跳过 PCM 与调制")) << "\""
                << ",\"outRate\":" << srcRate
                << ",\"outBits\":24"
                << ",\"outCh\":" << ch
                << ",\"carrier\":" << carrier
                << ",\"device\":\"" << jesc(dev) << "\""
                << ",\"resample\":false,\"twoStage\":false,\"taps\":0"
                << ",\"filter\":\"DirectSDM\""
                << ",\"phaseCode\":\"direct\",\"phase\":\"逐位直通\""
                << ",\"gpuAvailable\":false,\"shaper\":\"none\",\"loudness\":false"
                << ",\"volume\":0,\"buffer\":" << p.bufferMs
                << ",\"dsd\":" << p.dsd
                << ",\"dsdRate\":" << srcRate
                << ",\"modOrder\":0"
                << ",\"ispPeak\":0,\"ispOver\":0,\"preAtten\":0"
                << ",\"atten\":0,\"conv\":false,\"irGpu\":false"
                << ",\"gpuVendor\":\"\",\"gpuStatus\":\"\""
                << ",\"volRamp\":0,\"bits\":24,\"eq\":false"
                << ",\"directSdm\":true"
                << ",\"rg\":\"off\",\"rgDb\":0,\"rgClip\":false,\"rgSource\":\"directsdm:bypass\",\"rgNote\":\"DirectSDM 1-bit 直通，跳过 PCM 增益处理\""
                << ",\"decodeMs\":" << dsdMs
                << ",\"ffmpegMs\":0"
                << ",\"wavReadMs\":0"
                << ",\"scanMs\":" << Library::instance().lastScanMs()
                << "}";
            recent_add(file, stem_or_self(file), "", "");
            play_log(std::string("PLAY v") + RLPLAYER_VERSION + " " + sig.str());
            meta_on_play(file);   // 播放触发元数据补全(设置可关;inFlight 去重,后台线程)
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.signal = sig.str();
            ps.info = "DirectSDM：DSD 源 " + std::to_string(srcRate) + " Hz → DoP " +
                      std::to_string(carrier) + " Hz（跳过调制，逐位直通）";
        }
        // F-5 自证（DirectSDM 分支）：1-bit 直通**没有调制器参与** ⟹ modFamily 必须为空、
        // modOrder = 0（上游 261025-02 #5 同款口径：native 直通 modOrder=0）。
        // ★ 这里刻意不写 "native"：mac 的 DirectSDM 仍然是 DoP 装箱送 CoreAudio，
        //   不是 ASIO 原生 1-bit 通道（那种通路在 mac 不存在，见 /api/play 的 dsdnative 门）。
        // dsd 档位按源 1-bit 位率反推（srcRate / 44100 或 /48000），dsdRate = 源位率本身，
        // carrierRate = DoP 载波 = srcRate/16 —— 三个数一起给，用户才能分辨"384000 是载波"。
        {
            uint32_t lvl = 0;
            if (srcRate && srcRate % 48000u == 0) lvl = srcRate / 48000u;
            else if (srcRate && srcRate % 44100u == 0) lvl = srcRate / 44100u;
            set_out_format_state(out_mode_of_backend(p.backend).c_str(),
                                 (int)lvl, srcRate, carrier,
                                 std::string(), 0, std::string());
        }

        auto sink = make_sink(p);
        if (!sink->open(sink_opts(p), carrier, ch, 24)) {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error = "打开输出后端失败: " + sink->last_error();
            return false;
        }
        ActiveSinkGuard sinkGuard(sink.get(), true);
        if (!sink->start()) {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error = "启动输出失败: " + sink->last_error();
            sink->close();
            return false;
        }

        const size_t period = sink->buffer_frames() ? sink->buffer_frames() : 4096;
        std::vector<int32_t> pend;
        size_t pendFrames = 0, posFrames = frameBase, played = 0;
        bool pausedNow = false, eos = false;
        int  timeouts = 0;
        auto lastLog = std::chrono::steady_clock::now();
        rta::dsp::DopPackState packSt;      // 标记相位跨块保持；跳转时也不重置（避免出现 A,A）

        // 从 posFrames 处切 n 个 DoP 帧（n 个 16 位组）打包
        auto append = [&](size_t want) -> bool {
            if (posFrames >= frameEnd) return false;
            const size_t n = std::min(want, frameEnd - posFrames);
            DsdStream chunk;
            chunk.rate = srcRate;
            chunk.channels = ch;
            chunk.bits = (uint64_t)n * 16ull;
            chunk.data.resize((size_t)ch);
            for (int c = 0; c < ch; ++c)
                chunk.data[(size_t)c].assign(src.data[(size_t)c].begin() + (long long)(posFrames * 2),
                                             src.data[(size_t)c].begin() + (long long)((posFrames + n) * 2));
            std::vector<int32_t> packed;
            rta::dsp::dsd_to_dop(chunk, packed, packSt);
            pend.insert(pend.end(), packed.begin(), packed.end());
            pendFrames += n;
            posFrames += n;
            return true;
        };
        // 末尾补"合法的 DoP 静音帧"（0x55 交替）而不是全 0：
        // 全 0 样本的标记位是 0x00，接收端会判定"非法 DoP"并可能静音/报错。
        auto append_silence = [&](size_t n) {
            DsdStream chunk;
            chunk.rate = srcRate;
            chunk.channels = ch;
            chunk.bits = (uint64_t)n * 16ull;
            chunk.data.assign((size_t)ch, std::vector<uint8_t>(n * 2, 0x55));
            std::vector<int32_t> packed;
            rta::dsp::dsd_to_dop(chunk, packed, packSt);
            pend.insert(pend.end(), packed.begin(), packed.end());
            pendFrames += n;
        };

        while (!ps.stop.load()) {
            if (ps.pauseReq.load() != pausedNow) {
                pausedNow = ps.pauseReq.load();
                if (pausedNow) { sink->pause(); ps.paused.store(true); }
                else { sink->resume(); ps.paused.store(false); timeouts = 0; }
            }
            if (pausedNow) { std::this_thread::sleep_for(std::chrono::milliseconds(30)); continue; }

            const double sk = ps.seekReq.exchange(-1.0);
            if (sk >= 0.0) {
                // CUE 分轨：seek 比例是**区间内**的（0 = 本轨开头）⟹ 先算区间内偏移再加 frameBase
                const size_t rel = std::min(frameCount, (size_t)(sk * (double)frameCount + 0.5));
                posFrames = frameBase + rel;
                pend.clear(); pendFrames = 0; eos = false; timeouts = 0;
                played = rel;
                ps.played.store(played);
                continue;
            }

            while (!eos && pendFrames < period * 3) {
                if (!append(period)) { eos = true; break; }
                if (posFrames >= frameEnd) { eos = true; break; }
            }
            if (eos && pendFrames > 0 && pendFrames < period)
                append_silence(period - pendFrames);
            if (pendFrames == 0) {
                if (eos) break;
                sink->wait_event(20);
                continue;
            }

            ps.dbgPad.store(sink->last_pad());
            {
                const double full = (double)((int64_t)1 << 23);
                double pk = 0.0; long long cl = 0;
                for (size_t i = 0; i < pendFrames * (size_t)ch; ++i) {
                    const double a = std::fabs((double)pend[i]);
                    if (a > pk) pk = a;
                    if (a >= full - 0.5) ++cl;
                }
                g_dbgPeak.store(pk / full);
                if (cl) g_dbgClip.fetch_add(cl);
                const auto nowT = std::chrono::steady_clock::now();
                if (nowT - lastLog > std::chrono::seconds(5)) {
                    lastLog = nowT;
                    std::ostringstream ls;
                    ls << "STAT pos=" << (double)played / (double)carrier
                       << " rate=" << carrier << " pad=" << ps.dbgPad.load()
                       << " peak=" << g_dbgPeak.load() << " clip=" << g_dbgClip.load()
                       << " fpeak=" << sink->out_peak()   // 后端实际写出峰值（float 域）
                       << " w0=" << g_dbgW0.load() << " wr=" << g_dbgWr.load();
                    play_log(ls.str());
                }
            }
            sink->wait_event(20);
            const size_t w = sink->write_available(pend.data(), pendFrames);
            if (w > 0) {
                pend.erase(pend.begin(), pend.begin() + (long long)(w * (size_t)ch));
                pendFrames -= w;
                played += w;
                ps.played.store(played);
                timeouts = 0;
            } else if (pendFrames >= period) {
                // 手里有数据却 4 秒写不进去 ⟹ 设备异常。DoP 路径不回退共享（重采样会
                // 破坏 DoP 载波），但必须留下完整归因（2026-10-22 事故：静默 break
                // 导致 END pos=0 error=""）。
                if (++timeouts > 200) {
                    std::string devL = "默认音频设备", devId;
                    mac_find_dev(p.device, devL, devId);
                    std::ostringstream fs;
                    fs << "RENDERFAIL 设备流 " << (timeouts * 20 / 1000.0) << " 秒未接受数据（DirectSDM/DoP）"
                       << "（疑似虚拟声卡/独占模式不可用）"
                       << " last_pad=" << sink->last_pad()
                       << " 缓冲=" << period << "帧"
                       << " GetBuffer HRESULT=" << sink->last_gb_hr()
                       << " device=\"" << devL << "\""
                       << " id=" << (devId.empty() ? "(默认)" : devId)
                       << "。DoP/DSD 不能回退共享模式(共享会重采样破坏 DoP 载波),请改用独占可用的设备。";
                    play_log(fs.str());
                    { std::lock_guard<std::mutex> lk(ps.mtx); ps.error = fs.str(); }
                    break;
                }
            }
        }

        ps.paused.store(false);
        std::this_thread::sleep_for(std::chrono::milliseconds(std::max(10, p.bufferMs)));   // 让设备把缓冲里最后一点放完
        g_activeSink.store(nullptr); g_activeDop.store(false);
        sink->close();
        // error 非空 = 上面的 RENDERFAIL/渲染失败路径，绝不能当"正常播完"返回 true
        //（否则队列线程会自动续播下一曲，把设备故障掩盖成正常切歌）。
        return !ps.stop.load() && ps.error.empty();
    } catch (const std::exception& e) {
        std::lock_guard<std::mutex> lk(ps.mtx);
        ps.error = std::string("DirectSDM 异常: ") + e.what();
    } catch (...) {
        std::lock_guard<std::mutex> lk(ps.mtx);
        ps.error = "DirectSDM 未知异常";
    }
    return false;
}

// ---------------- 设置文件里的 EQ/IR 兜底（2026-10-25 耳机 EQ "切了没变化" 修复 · 根因 3）----------------
// 为什么需要：前端 ADV.eq 来自 /api/settings 的**异步**加载。用户在它落地之前就点播放时，
// params() 带上来的是 eq= 空串 —— 于是"设置里明明选了 OPRA 预设，这一首却完全没上 EQ"，
// 用户听到的自然就是"切了没变化"。起播时按 rlplayer-settings.conf 兜底一次即可闭合这个窗口。
// 只读文件、只在 p.eqFile 为空时调用（正常路径零开销、零行为变化）。
static std::string settings_conf_value(const char* wantKey) {
    if (!wantKey || !*wantKey) return std::string();
    std::ifstream f(path_in_exe_dir("rlplayer-settings.conf"));
    if (!f) return std::string();
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t e = line.find('=');
        if (e == std::string::npos) continue;
        if (line.compare(0, e, wantKey) != 0) continue;
        return line.substr(e + 1);
    }
    return std::string();
}

// EQ 路径"可用吗"：空串 = 明确不要 EQ（合法）；非空但读不到 = 用户还在逐字符输入 / 写错了。
// 用途只有一个：决定【要不要为它热重启播放】。少了这道闸，用户在设置页手打路径时
// 每敲一个字符都会 POST /api/settings，把正在播的歌反复重启 —— 那比"没变化"更糟。
static bool eq_path_usable(const std::string& path) {
    if (path.empty()) return true;
    { std::ifstream f(path); if (f) return true; }
    { std::ifstream f(path_in_exe_dir(path.c_str())); if (f) return true; }
    return false;
}

// ---------------- 起播定位（EQ 热重载用）----------------
// 把「从哪开始播」的比例翻译成 (生产者起点帧, 播放计数起点)。
// 纯函数（无 I/O、无全局状态）⟹ 可以被离线单测精确钉住（铁律 3：判据要能证明真东西）。
// 两者必须同源：只设 pos 不设 played 会变成"声音从 50% 起、进度条从 0 起"的自相矛盾。
struct StartPos { size_t pos = 0; size_t played = 0; };
static StartPos start_pos_for(double frac, size_t inFrames, size_t totalOut) {
    StartPos r;
    if (!(frac > 0.0) || frac >= 1.0 || inFrames == 0) return r;   // 默认：从头播
    r.pos = (size_t)(frac * (double)inFrames);
    if (r.pos >= inFrames) r.pos = inFrames - 1;
    r.played = (size_t)(frac * (double)totalOut);
    if (r.played > totalOut) r.played = totalOut;
    return r;
}

// ---------------- 大文件流式播放：数据源 + 块级过采样峰值扫描 ----------------
//
// 背景（2026-10-25 用户实测 user_ginshoku.dsf，384 s DSD64 / 271 MB）：
//   整曲预解码 read_dsd_native：4910 ms、PCM 缓冲 517 MB、解码瞬时峰值 1813 MB；
//   再叠加"整曲过采样峰值扫描"的 double 平面 1034 MB 与 2887 ms 扫描 ⟹ 起播前 8 s 无声音、峰值 2071 MB。
//   而管线本身的首块只要 18 ms（96k 输出 / GPU 升频）—— 卡的是解码与扫描，不是 DSP。
//
// 因此：解码后超过阈值（默认 200 MB，可配置）的 DSD 文件改走流式解码（DsdPcmStream），
// 峰值扫描改为逐块扫描（只保留一块的平面）；小文件仍走原来的整曲路径（行为不变）。
struct PlaySource {
    const rta::audio::AudioBuffer* mem = nullptr;                      // 非空 = 整曲在内存
    std::unique_ptr<rta::audio::DsdPcmStream> stream;      // 非空 = 流式解码
    uint32_t rate = 0;
    int      channels = 0;
    int      bits = 0;
    bool     isFloat = false;
    size_t   frames = 0;

    bool streaming() const { return stream != nullptr; }

    // 读 [pos, pos+n) 帧。整曲路径与原实现逐字节相同；流式路径向 DsdPcmStream 要。
    size_t read(size_t pos, size_t n, rta::audio::AudioBuffer& out) const {
        if (stream) return stream->read(pos, n, out);
        out.rate = mem->rate; out.channels = mem->channels; out.bits = mem->bits; out.isFloat = mem->isFloat;
        out.raw.clear();
        if (!mem || pos >= frames || n == 0) return 0;
        if (n > frames - pos) n = frames - pos;
        const size_t ch = (size_t)channels;
        out.raw.assign(mem->raw.begin() + (long long)(pos * ch),
                       mem->raw.begin() + (long long)((pos + n) * ch));
        return n;
    }
};

// 读 rlplayer-settings.conf 的单键（缺失返回 def）
static std::string conf_get(const std::string& key, const std::string& def = std::string()) {
    std::ifstream f(path_in_exe_dir("rlplayer-settings.conf"));
    if (!f) return def;
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t e = line.find('=');
        if (e == std::string::npos) continue;
        if (line.substr(0, e) == key) return line.substr(e + 1);
    }
    return def;
}

// 每次播放开始时把「大文件流式」策略刷成配置值：
//   stream_threshold_mb  解码后超过多少 MB 走流式（0 = 关闭流式，回到整曲预解码）
//   isp_prescan_sec      流式播放的峰值预扫窗口（秒）—— 整曲扫描等于再解一遍，不划算
static void apply_stream_settings() {
    auto& s = rta::audio::big_file_stream_settings();
    const double mb = std::atof(conf_get("stream_threshold_mb", "200").c_str());
    const double win = std::atof(conf_get("isp_prescan_sec", "20").c_str());
    s.enabled = (mb > 0.0);
    s.thresholdMb = (mb > 0.0) ? mb : 200.0;
    s.ispPrescanSec = (win > 0.0) ? win : 20.0;
    // 每次播放都落一行：出问题时"这次用的是哪套阈值"不该靠猜（阈值可配置，必须能自证）
    char b[200];
    std::snprintf(b, sizeof(b), "STREAMCFG enabled=%d threshold_mb=%.0f isp_prescan_sec=%.0f",
                  (int)s.enabled, s.thresholdMb, s.ispPrescanSec);
    play_log(b);
}

// ============================================================================
// 官方推荐预设（2026-10-25 用户钦定，2026-10-26 扩为四档）：自动探测硬件能力 → 一键把设置调到对应目标
//
// 三条硬纪律：
//   ① **只读探测**：macOS 走 probe_rates_cached（CoreAudio AudioObjectGetPropertyData，
//      不开流、不接管设备、不抢占 Hog mode）。日志留一行 PRESET_CAPS 自证"只读"。
//   ② 决策全在 engine/preset_profiles.h 的纯函数里（离线单测 tests/test_preset_profiles.cpp）；
//      本块只做「探测 → 落盘 → JSON」，一行决策逻辑都不重复写，避免两处口径漂移。
//   ③ 探测失败/未知一律保守降级，并把原因写进 notes（绝不静默假装支持）。
//   ⚠️ macOS 事实：mac 没有原生 DSD 驱动通道（ASIO/WASAPI 专属），DSD 档走 DoP；
//      无 DoP 载波能力时明确降级为 PCM 并在 notes 里说明（上游同款语义）。
// ============================================================================

// 探测当前设置下的输出设备能力（只读）。
// macOS 统一走 CoreAudio 设备能力查询，dsdNative 恒为 false（macOS 没有 ASIO 原生 DSD 驱动通路）。
// DSD 支持完全取决于设备是否有足够高的 PCM 采样率以承载 DoP（DSD64: 176.4k, DSD128: 352.8k, DSD256: 705.6k, DSD512: 1.4112M）。
static rta::engine::DeviceCaps preset_probe_caps() {
    using rta::engine::DeviceCaps;
    DeviceCaps c;
    const std::string savedBackend = conf_get("backend", "");
    int ch = std::atoi(conf_get("channels", "0").c_str());
    if (ch <= 0) ch = 2;
    int bits = std::atoi(conf_get("bits", "0").c_str());
    if (bits <= 0) bits = 24;
    c.channels = ch;
    c.bits = bits;
    const std::string devId = conf_get("device", "");

    c.backend = savedBackend.empty() ? "coreaudio" : savedBackend;
    const auto rates = probe_rates_cached(devId, bits, ch, "PRESET_CAPS");
    c.rates = rates;
    c.maxRate = rates.empty() ? 0u : rates.back();
    c.exclusive = !rates.empty();
    c.dopMax = rta::engine::preset_dop_max_from_rates(rates);
    c.dop = !c.dopMax.empty();
    c.dsdNative = false;                       // macOS 没有 ASIO 原生 DSD 驱动通路
    c.dsdNativeMax.clear();

    for (const auto& d : mac_enum_devices()) {
        if (devId.empty() ? d.isDefault : d.id == devId) {
            c.deviceName = d.name;
            break;
        }
    }
    if (c.deviceName.empty()) c.deviceName = devId.empty() ? std::string("默认音频设备") : devId;
    if (rates.empty()) {
        c.probeNote = "CoreAudio 独占/支持率探测为空（端点被占用/禁用/不支持所选位深）：按能力未知处理";
    }
    if (!savedBackend.empty() && savedBackend != "coreaudio" && savedBackend != "wasapi" && savedBackend != "wasapi-shared") {
        c.probeNote += (c.probeNote.empty() ? std::string() : std::string("；")) +
                       "当前后端是「" + savedBackend + "」（非本地独占设备）：能力按 CoreAudio 默认端点报，"
                       "原生 DSD 恒为 false";
    }
    return c;
}

// 一行 PRESET_CAPS：探测结果必须能自证（后端/驱动/支持率/DSD 档/是否只读/降级原因）
static std::string preset_caps_line(const rta::engine::DeviceCaps& c) {
    std::string rates;
    for (size_t i = 0; i < c.rates.size(); ++i) {
        if (i) rates += ",";
        rates += std::to_string((unsigned long long)c.rates[i]);
    }
    std::string s = "PRESET_CAPS backend=" + c.backend + " device=\"" + c.deviceName + "\"" +
                    " rates=[" + rates + "]" +
                    " maxRate=" + std::to_string((unsigned long long)c.maxRate) +
                    " dsdNative=" + (c.dsdNative ? "1" : "0") +
                    " dsdNativeMax=" + (c.dsdNativeMax.empty() ? std::string("-") : c.dsdNativeMax) +
                    " dop=" + (c.dop ? "1" : "0") +
                    " dopMax=" + (c.dopMax.empty() ? std::string("-") : c.dopMax) +
                    " exclusive=" + (c.exclusive ? "1" : "0") +
                    " ch=" + std::to_string(c.channels) +
                    " bits=" + std::to_string(c.bits) +
                    " readonly=1";      // 只读：没有开流、没有建缓冲、没有改设备状态
    if (!c.probeNote.empty()) s += " note=\"" + c.probeNote + "\"";
    return s;
}

// 查询串 → k/v（GET/POST 的 path 都带 ?a=b&c=d）
static std::map<std::string, std::string> preset_query(const std::string& path) {
    std::map<std::string, std::string> kv;
    const size_t q = path.find('?');
    if (q == std::string::npos) return kv;
    std::istringstream is(path.substr(q + 1));
    std::string tok;
    while (std::getline(is, tok, '&')) {
        const size_t e = tok.find('=');
        if (e == std::string::npos) { kv[urlDecode(tok)] = std::string(); continue; }
        kv[urlDecode(tok.substr(0, e))] = urlDecode(tok.substr(e + 1));
    }
    return kv;
}

// 源信息：显式参数优先（?src=dsd&dsdlevel=256 / ?src=pcm&srcrate=96000&srcbits=24），
// 否则用"当前正在播的曲目 → 最近一次播放的文件"，都没有就按 PCM 44.1k/16bit 规划并写明。
// 为什么 PCM 不去跑 ffprobe：为一个说明文字要几百毫秒，而 PCM 源只影响 note 与位深判据。
static rta::engine::SourceInfo preset_source_info(const std::map<std::string, std::string>& q,
                                                  std::string& note) {
    using rta::engine::SourceInfo;
    SourceInfo s;
    auto get = [&q](const std::string& k) -> std::string {
        const auto it = q.find(k);
        return it == q.end() ? std::string() : it->second;
    };
    const std::string kind = get("src");
    const std::string dsdLevel = get("dsdlevel");
    const std::string srcRate = get("srcrate");
    const std::string srcBits = get("srcbits");
    s.isStream = (get("stream") == "1" || get("stream") == "true");

    if (kind == "dsd" || !dsdLevel.empty() || get("dsd") == "1") {
        s.isDsd = true;
        s.srcBits = 1;
        int lvl = rta::engine::dsd_level_from_name(dsdLevel);
        if (lvl == 0 && !srcRate.empty()) {
            lvl = rta::engine::dsd_level_of_bitrate((uint32_t)std::atoll(srcRate.c_str()));
        }
        s.srcRate = (lvl > 0) ? (uint32_t)(44100 * lvl) : 2822400u;
        note = "源按参数指定为 DSD（" + std::to_string((unsigned long long)s.srcRate) + " Hz）";
        return s;
    }
    if (kind == "pcm") {
        s.isDsd = false;
        s.srcRate = srcRate.empty() ? 44100u : (uint32_t)std::atoll(srcRate.c_str());
        if (s.srcRate == 0) s.srcRate = 44100u;
        s.srcBits = srcBits.empty() ? 16 : std::atoi(srcBits.c_str());
        if (s.srcBits <= 0) s.srcBits = 16;
        note = "源按参数指定为 PCM（" + std::to_string((unsigned long long)s.srcRate) + " Hz / " +
               std::to_string(s.srcBits) + " bit）";
        return s;
    }

    std::string file;
    {
        std::lock_guard<std::mutex> lk(g_ps.mtx);
        file = g_ps.current;
    }
    if (file.empty()) file = g_params.file;
    if (!file.empty()) {
        const std::string ext = rta::audio::lowerExt(file);
        if (ext == ".dsf" || ext == ".dff") {
            try {
                const DsdInfo info = probe_dsd(file);
                if (info.rate > 0) {
                    s.isDsd = true;
                    s.srcBits = 1;
                    s.srcRate = info.rate;
                    note = "源取自当前曲目（" + ext + "，DSD " +
                           std::to_string((unsigned long long)info.rate) + " Hz）";
                    return s;
                }
            } catch (...) {
                // 读不了文件头就按 DSD64 —— 下面统一写 note
            }
            s.isDsd = true;
            s.srcBits = 1;
            s.srcRate = 2822400u;
            note = "源取自当前曲目（" + ext + "），但位率读取失败：按 DSD64 处理";
            return s;
        }
        s.isDsd = false;
        s.srcRate = 44100u;
        s.srcBits = 16;
        note = "源取自当前曲目（PCM：" + ext + "），未重解码：按 44.1k/16bit 规划（只影响说明文字）";
        return s;
    }
    s.isDsd = false;
    s.srcRate = 44100u;
    s.srcBits = 16;
    note = "未指定源（无 ?src= 参数、也没有当前曲目）：按 PCM 44.1k/16bit 规划";
    return s;
}

// 合并写 rlplayer-settings.conf（与 /api/settings 的 POST 同一套语义：先读全量、覆盖本次的键、
// 再整体写回）。绝不 trunc + 只写本次的键 —— 那样会把 backend/device 等其余设置清空
//（2026-10-23 的真实事故，见 /api/settings 处的注释）。
static bool preset_write_conf(const std::map<std::string, std::string>& kv, std::string& err) {
    const std::string sp = path_in_exe_dir("rlplayer-settings.conf");
    std::map<std::string, std::string> merged;
    std::vector<std::string> order;
    {
        std::ifstream in(sp);
        std::string line;
        while (std::getline(in, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            const size_t e = line.find('=');
            if (e == std::string::npos) continue;
            const std::string k = line.substr(0, e);
            if (merged.find(k) == merged.end()) order.push_back(k);
            merged[k] = line.substr(e + 1);
        }
    }
    for (const auto& p : kv) {
        const auto it = merged.find(p.first);
        if (it == merged.end()) {
            order.push_back(p.first);
            merged[p.first] = p.second;
        } else {
            it->second = p.second;
        }
    }
    std::ofstream f(sp, std::ios::trunc);
    if (!f) { err = "无法写入 " + sp; return false; }
    for (const auto& k : order) {
        const auto it = merged.find(k);
        if (it == merged.end()) continue;
        f << k << "=" << it->second << (char)10;
    }
    if (!f.good()) { err = "写入未完成"; return false; }
    return true;
}

// GET /api/preset/caps → 设备能力（字段与界面约定一致，多带 notes 便于排查）
static std::string preset_caps_json() {
    const rta::engine::DeviceCaps c = preset_probe_caps();
    play_log(preset_caps_line(c));
    std::ostringstream j;
    j << "{\"ok\":true,\"device\":{\"name\":\"" << jesc(c.deviceName) << "\""
      << ",\"backend\":\"" << jesc(c.backend) << "\""
      << ",\"rates\":[";
    for (size_t i = 0; i < c.rates.size(); ++i) {
        if (i) j << ",";
        j << c.rates[i];
    }
    j << "]"
      << ",\"maxRate\":" << c.maxRate
      << ",\"dsdNative\":" << (c.dsdNative ? "true" : "false")
      << ",\"dsdNativeMax\":\"" << jesc(c.dsdNativeMax) << "\""
      << ",\"dop\":" << (c.dop ? "true" : "false")
      << ",\"dopMax\":\"" << jesc(c.dopMax) << "\""
      << ",\"exclusive\":" << (c.exclusive ? "true" : "false")
      << ",\"channels\":" << c.channels
      << ",\"bits\":" << c.bits
      << "},\"readonly\":true,\"notes\":[";
    if (!c.probeNote.empty()) j << "\"" << jesc(c.probeNote) << "\"";
    j << "]}";
    return j.str();
}

// POST /api/preset/apply?profile=bitperfect|pcm|dsd|pcm2dsd
// 成功：{"ok":true,"profile":…,"applied":{…},"notes":[…]}；参数非法或写盘失败：400 + {"ok":false,"error":…}
static std::string preset_apply_json(const std::string& path) {
    using namespace rta::engine;
    const std::map<std::string, std::string> q = preset_query(path);
    const auto itProf = q.find("profile");
    const std::string profStr = (itProf == q.end()) ? std::string() : itProf->second;
    PresetProfile prof = PresetProfile::Pcm;
    if (!preset_profile_parse(profStr, prof)) {
        rta::net::webui_set_status(400);
        // 2026-10-26 第 4 档：错误文案必须把 pcm2dsd 列出来，否则前端只能猜
        return std::string("{\"ok\":false,\"error\":\"profile 非法（只接受 bitperfect / pcm / dsd / pcm2dsd）：") +
               jesc(profStr) + "\"}";
    }
    const DeviceCaps caps = preset_probe_caps();
    play_log(preset_caps_line(caps));
    std::string srcNote;
    const SourceInfo src = preset_source_info(q, srcNote);
    PresetSettings s = plan_preset(prof, caps, src);

    // ---- 落盘（键名与 /api/play 的请求键名一致）----
    std::map<std::string, std::string> kv;
    kv["volume"]   = "0";                        // 官方推荐链路：0 dB（预衰减交给 DSP 的余量逻辑）
    kv["rate"]     = s.rate;
    kv["shaper"]   = s.shaper;
    kv["filter"]   = s.filter;
    // 1x 与 Nx 用同一个滤波器：否则 88.2k 以上的源会走另一套（用户以为预设生效了，其实没有）
    kv["filterNx"] = "";
    kv["sdmfilt"]  = "";
    kv["sdmfiltnx"] = "";
    // ★ taps 写 0（= 不手动覆盖）：minTapsPerInput=512 由 poly-sinc-tight-lp 预设自带
    //（filter_families.h:314 的 tapsPerInput=512，rtaweb 的 cfg.minTapsPerInput=fp->tapsPerInput）。
    // 写 512 反而会被 /api/play 当成"总抽头预算"覆盖成 max(1024,512)=1024，是错的旋钮。
    kv["taps"]     = "0";
    kv["dsd"]      = std::to_string(s.dsd);
    kv["directsdm"] = s.directSdm ? "1" : "0";
    if (!s.modFamily.empty()) kv["modfamily"] = s.modFamily;
    if (s.modOrder > 0)       kv["modorder"] = std::to_string(s.modOrder);
    if (prof != PresetProfile::BitPerfect) {
        kv["twostage"] = "0";                    // poly-sinc-tight-lp 自带 twoStage=false
    }
    if (s.clearEqIr) {
        kv["eq"]         = "";
        kv["ir"]         = "";
        kv["irgpu"]      = "0";
        kv["loudness"]   = "0";
        kv["atten"]      = "0";                  // 手动阻带衰减覆盖（以预设值为准）
        kv["transition"] = "0";
        kv["phase"]      = "";
        kv["trim"]       = "0,0,0,0,0,0,0,0";
        // 预衰减：只有原音直通关掉 ISP 扫描（否则 ④预衰减一条永远不成立）；
        // 升频/DSD 档保留 ISP —— 它挡的是过采样峰值削波，与"清空 EQ/IR"是两件事。
        kv["isp"]        = (prof == PresetProfile::BitPerfect) ? "0" : "1";
    }
    std::string werr;
    if (!preset_write_conf(kv, werr)) {
        rta::net::webui_set_status(400);
        return std::string("{\"ok\":false,\"error\":\"写入设置失败：") + jesc(werr) + "\"}";
    }

    // ---- 说明（决策 notes + 落盘事实）----
    std::vector<std::string> notes;
    if (!srcNote.empty()) notes.push_back(srcNote);
    for (const auto& n : s.notes) notes.push_back(n);
    if (s.minTapsPerInput > 0) {
        notes.push_back("minTapsPerInput=" + std::to_string(s.minTapsPerInput) +
                        " 由 poly-sinc-tight-lp 预设自带（手动 taps 覆盖已清 0，避免被当成总抽头预算）");
    }
    if (s.clearEqIr) notes.push_back("已清空 EQ/IR/等响度/每声道增益" +
                                     std::string(prof == PresetProfile::BitPerfect
                                                 ? "，并关闭 ISP 预衰减" : ""));

    play_log("PRESET_APPLY profile=" + std::string(preset_profile_name(prof)) +
             " rate=" + s.rate + " filter=" + (s.filter.empty() ? std::string("-") : s.filter) +
             " tapsPerInput=" + std::to_string(s.minTapsPerInput) +
             " dsd=" + std::to_string(s.dsd) +
             " modfamily=" + (s.modFamily.empty() ? std::string("-") : s.modFamily) +
             " modorder=" + std::to_string(s.modOrder) +
             " shaper=" + s.shaper + " volume=0 directsdm=" + std::to_string(s.directSdm) +
             " src=" + (src.isDsd ? "dsd" : "pcm") + "/" +
             std::to_string((unsigned long long)src.srcRate) +
             " notes=" + std::to_string(notes.size()));

    std::ostringstream j;
    j << "{\"ok\":true,\"profile\":\"" << preset_profile_name(prof) << "\",\"applied\":{"
      << "\"rate\":\"" << jesc(s.rate) << "\""
      << ",\"filter\":\"" << jesc(s.filter) << "\""
      << ",\"minTapsPerInput\":" << s.minTapsPerInput
      << ",\"dsd\":\"" << s.dsd << "\""
      << ",\"modfamily\":\"" << jesc(s.modFamily) << "\""
      << ",\"modorder\":" << s.modOrder
      << ",\"shaper\":\"" << jesc(s.shaper) << "\""
      << ",\"volume\":" << (long long)std::llround(s.volumeDb)
      << ",\"directsdm\":" << s.directSdm
      << "},\"notes\":[";
    for (size_t i = 0; i < notes.size(); ++i) {
        if (i) j << ",";
        j << "\"" << jesc(notes[i]) << "\"";
    }
    j << "]}";

    // 预设已写盘 ⟹ 上次播放的 bit-perfect 结论不再代表当前配置。
    // 清零而不是硬写一个状态：此刻没有播放，任何 yes/no 都是编的（铁律 3）。
    {
        std::lock_guard<std::mutex> lk(g_ps.mtx);
        g_ps.bpState.clear();
        g_ps.bpWhy.clear();
    }

    return j.str();
}


// 块级过采样峰值扫描（4 相 × 8 抽头，与 dsp::detect_isp 同一个核、同一套边界规则）。
// 为什么不用 dsp::detect_isp(整曲 planes)：那要 2 声道 × 8 字节 × 帧数（384 s DSD64 = 1034 MB）。
// 这里按 256K 帧一块读源，块与块之间带 TAPS/2-1 = 3 帧真样本重叠，因此块内样本的插值
// 与整曲扫描逐位相同（块边界不用"复制端点"，只有文件首尾才钳位）。
struct BigIspScan {
    double peak = 0.0;
    double srcPeak = 0.0;
    long long over = 0;
    size_t scannedFrames = 0;
    bool   partial = false;
};
// fromFrame/limitFrames（2026-10-25 CUE 分轨）：只扫 [fromFrame, fromFrame+limitFrames)。
// 为什么必须带起点：cue 的每首虚拟曲目都该按**本轨**的峰值算预衰减，而不是拿整轨（可能 40 分钟）
// 的最高峰值去压一首 2 分钟的小品；顺带也把扫描耗时从"整轨"降到"本轨"。
// ⚠️ 边界代价（如实标注）：块内 4 相 8 抽头会读到区间首尾外各 half=3 帧的样本（与整曲扫描的
//    端点钳位同一规则），因此极值估计可能有 <3 帧的"越界取样"，对预衰减结论无实际影响。
static BigIspScan scan_isp_blocks(PlaySource& src, size_t fromFrame, size_t limitFrames, bool partial) {
    BigIspScan r;
    r.partial = partial;
    const auto& K = rta::dsp::isp_kernel();
    const int TAPS = (int)K[0].size();
    const int half = TAPS / 2 - 1;
    const int PH = (int)K.size();
    const size_t BLK = 1u << 18;          // 262144 帧/块
    const size_t total = src.frames;
    if (fromFrame > total) fromFrame = total;
    const size_t avail = total - fromFrame;
    if (limitFrames == 0 || limitFrames > avail) limitFrames = avail;
    const size_t endFrame = fromFrame + limitFrames;
    for (size_t a = fromFrame; a < endFrame; a += BLK) {
        const size_t b = std::min(endFrame, a + BLK);
        const size_t lo = (a > (size_t)half) ? a - (size_t)half : 0;
        const size_t hi = std::min(total, b + (size_t)half);
        rta::audio::AudioBuffer chunk;
        const size_t got = src.read(lo, hi - lo, chunk);
        if (got == 0) break;
        const int chn = chunk.channels;
        const size_t n = chunk.frames();
        std::vector<std::vector<double>> planes((size_t)chn, std::vector<double>(n));
        for (size_t i = 0; i < n; ++i)
            for (int c = 0; c < chn; ++c) {
                const double v = chunk.sample(i, c);
                planes[(size_t)c][i] = v;
                if (std::fabs(v) > r.srcPeak) r.srcPeak = std::fabs(v);
            }
        const size_t endInChunk = std::min(n, b - lo);
        for (size_t i = a - lo; i < endInChunk; ++i) {
            for (int c = 0; c < chn; ++c) {
                const auto& x = planes[(size_t)c];
                for (int p = 0; p < PH; ++p) {
                    double acc = 0.0;
                    for (int k = 0; k < TAPS; ++k) {
                        long long idx = (long long)i + k - half;
                        if (idx < 0) idx = 0;                       // 全局首端钳位（与整曲扫描一致）
                        if (idx >= (long long)n) idx = (long long)n - 1;
                        acc += K[(size_t)p][(size_t)k] * x[(size_t)idx];
                    }
                    const double v = std::fabs(acc);
                    if (v > r.peak) r.peak = v;
                    if (v > 1.0) ++r.over;
                }
            }
        }
        r.scannedFrames += (b - a);
    }
    return r;
}

// ---------------- 播放单曲 ----------------
// buf 若已含数据则直接使用（预解码命中），否则现场解码。
// 返回 true = 正常播完；false = 被打断或出错。
//
// sharedFallback（可选出参）：独占流 RENDERFAIL（设备持续不接受数据）且允许回退时置 true，
// 由 play_one 包装层决定是否以 wasapi-shared 重开整条播放；extraNote：回退重入时追加到
// note/ps.info/信号链的说明（"独占流无响应,已回退 WASAPI 共享"）。
// 参数名用 pIn 而不是 p：函数体里会先做一次「EQ/IR 配置兜底」得到 pE，
// 然后 `const PlayParams& p = pE;` —— 让下面几百行原有的 p.* 全部自动用上兜底结果，
// 一个字符都不用改（改动面最小 = 回归面最小）。
static bool play_one_impl(const std::string& file, const PlayParams& pIn, rta::audio::AudioBuffer& buf,
                          bool* sharedFallback, const std::string& extraNote) {
    auto& ps = g_ps;
    play_log_rotate();
    g_dbgPeak.store(0.0);
    g_dbgClip.store(0);
    apply_dsd_src_settings(pIn);
    // F-5（2026-10-26）：每次本地播放先把"输出格式自证"复位成本曲的**已知起点**。
    // 不复位的话 /api/status 会把上一曲的 outMode/dsdRate 当成本次事实（同 ps.gpu 的教训）。
    // 起点 = 该后端对应的通道模式 + DSD/调制全零（本曲还没决定是否走 DSD）；
    // 真正走 DoP 的分支会在确定 dsdRate 与**实际生效阶数**之后再覆盖一次。
    // ⚠️ 这里在 DirectSDM 分支**之前**执行 —— play_one_direct 自己会再写一次更精确的值。
    reset_out_format_state(out_mode_of_backend(pIn.backend).c_str());
    // ---- 2026-10-25（耳机 EQ "切了没变化" · 根因 3）：EQ/IR 的配置兜底 ----
    // 只在 pIn 里为空时补，正常路径（前端已带上来）逐字节不变。
    // 为什么要兜底：见 settings_conf_value 的注释 —— ADV.eq 是异步加载的，
    // 起播早于它落地时本曲就会"完全没上 EQ"，用户听起来就是"切了没变化"。
    PlayParams pE = pIn;
    if (pE.eqFile.empty()) {
        const std::string confEq = settings_conf_value("eq");
        if (!confEq.empty() && eq_path_usable(confEq)) pE.eqFile = confEq;
    }
    if (pE.convIr.empty()) {
        const std::string confIr = settings_conf_value("ir");
        if (!confIr.empty() && eq_path_usable(confIr)) {
            pE.convIr = confIr;
            const std::string g = settings_conf_value("irgpu");
            if (!g.empty()) pE.convGpu = (g == "1");
        }
    }
    const PlayParams& p = pE;
    // ---- DirectSDM 判定：必须在解码之前（DSD256 整曲解成 PCM 要几百 MB）----
    // 不满足条件时把原因带到信号链里（不能只写 ps.info —— 紧接着 read_any 会覆盖它）
    std::string directNote;
    std::string bitNote;   // HF-01：位深回退说明（进信号链 JSON，PLAY 日志随之带出）
    // F-5：本次"实际输出 ≠ 用户请求"的中文原因汇总（进 /api/status 的 fallbackWhy）。
    // 与 bitNote 分开：bitNote 只记位深，这里记**所有**降级（共享混音率改写、换采样率、
    // 降位深、独占→共享回退），空串 = 没降级。appendFallback 保证多原因不互相覆盖。
    std::string fallbackWhy;
    auto appendFallback = [&](const std::string& s) {
        if (s.empty()) return;
        if (!fallbackWhy.empty()) fallbackWhy += "；";
        fallbackWhy += s;
    };
    if (p.directSdm) {
        const std::string ext = lowerExt(file);
        if (ext == ".dsf" || ext == ".dff") {
            try {
                const DsdInfo info = probe_dsd(file);
                std::string why;
                // ★ 必须用 pE：EQ 是否启用直接决定 DirectSDM 能不能直通（anyProc 判据）。
                //   用 p 的话，"设置里有 EQ 但本次请求没带"会被误判成"无处理" ⟹ 绕过 EQ 直通，
                //   那正是"切了预设声音不变"的另一条路径。
                if (direct_sdm_eligible(pE, info, why)) return play_one_direct(file, pE);
                directNote = "DirectSDM 未启用：" + why;
            } catch (const std::exception& e) {
                directNote = std::string("DirectSDM 判定失败（回退普通路径）：") + e.what();
            }
        } else {
            directNote = "DirectSDM 只对 DSD 源（.dsf / .dff）有效，本文件按普通路径播放";
        }
    }
    // 系统级时序调优：MMCSS Pro Audio + CPU 亲和 + 定时器 1ms
    RtTune rt = rta::audio::apply_playback_tuning();
    struct RtGuard { RtTune* t; ~RtGuard() { rta::audio::release_playback_tuning(*t); } } rtg{ &rt };
    try {
        // 共享模式不支持 DoP/DSD 输出：共享经系统混音引擎重采样，DoP 载波（0x05/0xFA
        // 标记）被重采样后即非法，接收端判非法并静音 —— 直接明确报错，不降质播放。
        // （DirectSDM 路径在 play_one_direct 里另有一个相同的门。）
        if (p.backend == "wasapi-shared" && p.dsd >= 64) {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error = "共享模式不支持 DoP/DSD（共享会重采样破坏 DoP 载波），请切换到独占模式。";
            return false;
        }
        LoadNote note;
        // HF-03 可观测性：read_any 之前先写 START —— 2.log 那种"END 有 error、前面没有 PLAY"
        // 的失败，靠 START 与 DECODE 的有无就能把故障段定位到解码/临时 WAV。
        ps.decodeMs.store(0);
        ps.ffmpegMs.store(0);
        ps.wavReadMs.store(0);
        ps.dspChunkUs.store(0);
        ps.dspTotalUs.store(0);
        ps.dspChunks.store(0);
        {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.rgMode = "off";
            ps.rgAppliedDb = 0.0;
            ps.rgClipLimited = false;
            ps.rgSource.clear();
            ps.rgNote.clear();
        }
        {
            std::lock_guard<std::mutex> lk(g_lastEndMx);
            if (g_lastEnd.isPosZeroNoErr) {
                const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - g_lastEnd.tp).count();
                if (elapsedMs < 30000) {
                    play_log("PLAY_ABORT prev=" + g_lastEnd.file + " reason=superseded_by_new_play");
                }
                g_lastEnd.isPosZeroNoErr = false;
            }
        }
        play_log(p.cueStart >= 0.0
                     ? ("START file=" + file + " cue=" + cue_range_text(p.cueStart, p.cueEnd))
                     : ("START file=" + file));
        play_log(mem_line("pre-decode"));
        apply_stream_settings();
        const auto t_dec_0 = std::chrono::steady_clock::now();
        // 大文件不整曲预解码（2026-10-25 大 DSD 卡死）：先只读文件头，解码后 > 阈值就流式。
        // 判据是"解码后 PCM 字节数"（DSD64 的 271 MB 文件解出来是 517 MB），见 audio_loader.h。
        PlaySource src;
        double streamMb = 0.0;
        {
            std::string why;
            if (buf.raw.empty() && rta::audio::should_stream_decode(file, &streamMb, &why)) {
                auto st = std::make_unique<rta::audio::DsdPcmStream>();
                std::string serr;
                if (st->open(file, rta::audio::dsd_pcm_settings(), &serr)) {
                    src.rate = st->rate();
                    src.channels = st->channels();
                    src.bits = 32;
                    src.isFloat = false;
                    src.frames = st->totalFrames();
                    src.stream = std::move(st);
                    char b[240];
                    std::snprintf(b, sizeof(b),
                                  "流式解码（解码后 %.0f MB > 阈值 %.0f MB）：不整曲预解码，边读边解",
                                  streamMb, rta::audio::big_file_stream_settings().thresholdMb);
                    note.text = b;
                    play_log(std::string("STREAM_BEGIN ") + b + " file=" + file);
                } else {
                    play_log("STREAM_SKIP open failed: " + serr + " file=" + file);   // 宁可慢，也不能不出声
                }
            } else if (!why.empty()) {
                play_log("STREAM_NOT_USED " + why + " file=" + file);
            }
        }
        if (!src.stream) {
            if (buf.raw.empty()) buf = read_any(file, &note);
            else note.text = "预解码命中（整曲已在内存）";
        }
        const auto t_dec_1 = std::chrono::steady_clock::now();
        if (note.totalMs <= 0.0) {
            note.totalMs = std::chrono::duration<double, std::milli>(t_dec_1 - t_dec_0).count();
        }
        ps.decodeMs.store((long long)(note.totalMs + 0.5));
        ps.ffmpegMs.store((long long)(note.ffmpegMs + 0.5));
        ps.wavReadMs.store((long long)(note.wavReadMs + 0.5));
        // 流式时 buf 是空的：用只有元数据的 AudioBuffer 顶替 in 的元数据用途（raw 不参与）
        rta::audio::AudioBuffer inMeta;
        if (src.stream) {
            inMeta.rate = src.rate; inMeta.channels = src.channels;
            inMeta.bits = src.bits; inMeta.isFloat = src.isFloat;
        } else {
            src.mem = &buf;
            src.rate = buf.rate; src.channels = buf.channels; src.bits = buf.bits;
            src.isFloat = buf.isFloat; src.frames = buf.frames();
        }
        const rta::audio::AudioBuffer& in = src.stream ? inMeta : buf;
        const size_t srcFrames = src.frames;
        {
            char b[240];
            std::snprintf(b, sizeof(b), "stream=%d decodedMb=%.0f inBufMb=%.0f",
                          (int)src.streaming(),
                          src.streaming() ? streamMb : (double)buf.raw.size() * 4.0 / (1024.0 * 1024.0),
                          (double)buf.raw.size() * 4.0 / (1024.0 * 1024.0));
            play_log(mem_line("decoded", b));
        }
        if (!note.text.empty()) { std::lock_guard<std::mutex> lk(ps.mtx); ps.info = note.text; }
        if (!directNote.empty()) { std::lock_guard<std::mutex> lk(ps.mtx); ps.info += " ｜ " + directNote; }
        if (ps.stop.load()) return false;
        // 空解码结果不要再往下走到"设备不支持 0 Hz"——那是误导性的错误。
        if (in.rate == 0 || srcFrames == 0) {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error = "解码结果为空（文件损坏、格式不支持，或 ffmpeg 解码失败）：" + file;
            return false;
        }
        // 解码成功即记 DECODE（含临时 WAV 之类 note；START 有、DECODE 无 ⟹ 死在解码段）
        {
            std::ostringstream ds;
            ds << "DECODE file=" << file
               << " rate=" << in.rate << " ch=" << in.channels << " bits=" << in.bits
               << " frames=" << srcFrames
               << " stream=" << (src.streaming() ? 1 : 0)
               << " decodeMs=" << (long long)(note.totalMs + 0.5);
            if (p.cueStart >= 0.0) ds << " cue=" << cue_range_text(p.cueStart, p.cueEnd);
            if (!note.text.empty()) ds << " note=\"" << note.text << "\"";
            play_log(ds.str());
        }
        // ---------------- CUE 分轨（2026-10-25）：把 [cueStart, cueEnd) 变成一个"虚拟文件" ----------------
        // 为什么卡在这里：此刻已经解出 in.rate / srcFrames，而下游一切（totalOut、seek 基准、
        // ISP 扫描范围、信号链 dur）都还没定 —— 这里是"本区间"能成为唯一真相源的最后一个位置。
        // 口径（与本文件 PlayParams::cueStart 的注释一致）：
        //   · srcBase/srcCount = 本轨在**解码结果**里的起点/长度（源采样率帧）；
        //   · 前 srcBase 帧永远不写设备（生产者从 srcBase 起读，不是"读出来再丢"）；
        //   · 到 srcBase+srcCount 就正常结束（eos），不是"整轨播到 40 分钟"。
        // 失败必须明确：给了 cue_start 却越界/读不了 ⟹ 报错（绝不静默从头播）。
        size_t srcBase = 0, srcCount = srcFrames;
        const bool cueOn = (p.cueStart >= 0.0);
        if (cueOn) {
            const double fileSec = (double)srcFrames / (double)in.rate;
            auto cueFail = [&](const std::string& why) {
                play_log("CUE_REJECT " + why + " cue=" + cue_range_text(p.cueStart, p.cueEnd) +
                         " file=" + file);
                std::lock_guard<std::mutex> lk(ps.mtx);
                ps.error = why;
                return false;
            };
            if (p.cueEnd >= 0.0 && p.cueEnd <= p.cueStart)
                return cueFail("CUE 分轨区间非法：终点 " + std::to_string(p.cueEnd) +
                               "s 不大于起点 " + std::to_string(p.cueStart) + "s（文件 " +
                               std::to_string(fileSec) + "s）：" + file);
            const long long b = (long long)std::llround(p.cueStart * (double)in.rate);
            if (b < 0 || (size_t)b >= srcFrames)
                return cueFail("CUE 分轨起点越界：起点 " + std::to_string(p.cueStart) +
                               "s ≥ 文件时长 " + std::to_string(fileSec) + "s：" + file);
            long long e = (p.cueEnd >= 0.0) ? (long long)std::llround(p.cueEnd * (double)in.rate)
                                            : (long long)srcFrames;
            if (e > (long long)srcFrames) e = (long long)srcFrames;
            if (e <= b)
                return cueFail("CUE 分轨区间越界：" + cue_range_text(p.cueStart, p.cueEnd) +
                               " 落在文件时长 " + std::to_string(fileSec) + "s 之外：" + file);
            srcBase  = (size_t)b;
            srcCount = (size_t)(e - (long long)b);
            play_log("CUE_RANGE cue=" + cue_range_text(p.cueStart, p.cueEnd) +
                     " base=" + std::to_string(srcBase) + " frames=" + std::to_string(srcCount) +
                     " inRate=" + std::to_string(in.rate) + " fileSec=" + std::to_string(fileSec) +
                     " file=" + file);
        }
        // 位深回退 / 端点回退等"不能悄悄变"的说明都汇进 note（进 ps.info 与信号链 JSON 的 note）
        auto appendNote = [&](const std::string& s) {
            if (s.empty()) return;
            if (!note.text.empty()) note.text += " ｜ ";
            note.text += s;
            std::lock_guard<std::mutex> lk(ps.mtx);
            if (!ps.info.empty()) ps.info += " ｜ ";
            ps.info += s;
        };
        // 独占 RENDERFAIL 回退共享后的重入：把回退原因带进 note/ps.info/信号链
        if (!extraNote.empty()) { appendNote(extraNote); appendFallback(extraNote); }
        // ---- HF-02：open 前先核对端点状态。找不到/禁用/拔出 → 日志写明，并回退默认端点 ----
        // 必须在设备能力检查之前做：失效端点会让 exclusive_rates 对任何位深都返回空列表，
        // 否则永远走不到"回退默认端点"这一步（交接单 §2.1 的并行嫌疑）。
        PlayParams pEff = p;
        // macOS：空设备由 CoreAudioOutput::open 解析为系统默认输出（§13.9 实测）；
        // 指定设备失效时 open 返回 DeviceNotFound 并带设备可见文案，不需要播放前预检。

        // ---- ReplayGain / Album Gain 决策与接入 ----
        rta::dsp::replaygain::Mode rgMode = rta::dsp::replaygain::Mode::Off;
        rta::dsp::replaygain::parse_mode(pEff.rgMode, &rgMode);
        rta::dsp::replaygain::Params rgParams;
        rgParams.mode = rgMode;
        rgParams.preventClipping = pEff.rgPreventClip;
        rgParams.preampDb = pEff.rgPreamp;

        rta::dsp::replaygain::Track tr;
        tr.path = file;
        rta::dsp::replaygain::read_tags(file, &tr.tags);

        std::vector<rta::dsp::replaygain::AlbumInfo> albums;
        if (rgParams.mode == rta::dsp::replaygain::Mode::Album) {
            std::vector<rta::dsp::replaygain::Track> albTracks = { tr };
            albums = rta::dsp::replaygain::compute_albums(albTracks, rgParams.referenceLufs);
        }
        const auto rgDec = rta::dsp::replaygain::decide(tr, rgParams, albums.empty() ? nullptr : &albums);

        // GPU 后端偏好要在建管线之前生效（DLL 是懒加载的）
        rta::dsp::set_gpu_vendor(p.gpuVendor.empty() ? "auto" : p.gpuVendor);
        rta::dsp::GpuBridge::instance().reload();
        dlog("stage gpu-ok");

        eng::PipelineConfig cfg;
        cfg.outBits = (p.bits > 0) ? p.bits : 24;
        if (!p.shaper.empty()) cfg.shaper = parse_shaper(p.shaper);
        cfg.replayGainDb = (rgDec.active ? rgDec.appliedDb : 0.0);
        {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.rgMode = rta::dsp::replaygain::mode_name(rgParams.mode);
            ps.rgAppliedDb = cfg.replayGainDb;
            ps.rgClipLimited = (rgDec.active && rgDec.clipLimited);
            ps.rgSource = rgDec.source;
            ps.rgNote = rgDec.note;
        }
        // 2026-10-25（消除双重衰减与死锁）：
        // 音量由设备输出层（CoreAudioOutput::render）通过原子变量毫秒级实时应用。
        // Pipeline 软件音量固定不衰减（0.0 dB），消除"低音量起播后无法拉大"及"双重衰减"。
        cfg.volumeEnabled = false;
        cfg.volumeDb = 0.0;
        cfg.loudnessEnabled = p.loudness;
        if (p.volRamp > 0.0) cfg.volumeRampMs = p.volRamp;
        // GPU：升频与卷积都走显卡（rtagpu.dll 缺失时自动退回 CPU，结果逐位相同）
        cfg.gpuResample = true;

        // ---- 采样率（选择逻辑在 src/audio/rate_pick.h，纯函数、可离线单测）----
        // 只有 WASAPI 独占有"设备支持哪些采样率"可查。NAA / Null 没有本地设备，共享模式由
        // 系统混音率决定，这三者都把 "max" 当"跟随源"（想升频就直接选具体数值）。
        const bool wasapiExcl = (p.backend.empty() || p.backend == "wasapi");
        // 非 WASAPI 独占（NAA / Null / 共享）没有"设备采样率"可查，follow 与 max 一样
        // 归一成"跟随源"；否则 pick_output_rate("follow") 会因为 systemRate==0 退回源率
        // 并打一条 SYSRATE_EMPTY，日志噪音且语义含糊。
        const std::string reqRate = ((p.rate == "max" || p.rate == "follow") && !wasapiExcl)
                                        ? std::string("src") : p.rate;
        // rate=max 的探测带重试（3 次 × 40ms）并刷新"上次成功列表"缓存 —— 上一首独占流刚
        // sink->close() 时 IsFormatSupported 会瞬时返回空，一次结果不足以下结论。
        std::vector<uint32_t> probeRates;
        bool rateStale = false;        // true = 本次探测为空，沿用了缓存里的上次结果
        if (reqRate == "max") {
            probeRates = probe_exclusive_rates(pEff.device, 24, in.channels);
            if (probeRates.empty()) {
                // 三次都空：先看缓存。⚠️ 这里刻意"退回上次结果"而不是退回源率 ——
                // 上一首刚用 96k 播完整首歌，本身就是这个端点支持 96k 的铁证；
                // 一次瞬时探测为空不能把它抹掉（铁律 3：判据要能证明它要证明的事）。
                probeRates = rate_cache_get(pEff.device, 24, in.channels);
                rateStale = !probeRates.empty();
            }
        }
        // ---- rate=follow：跟随【声卡当前配置的采样率】（用户 2026-10-22 功能1）----
        // 首次安装默认就是这一档（见 settings_defaults / loadSettings 的迁移注释）。
        // 取法：GetMixFormat（wasapi_shared.h 已有能力，这里复用它，不开流不出声）。
        // bit-perfect 说明：跟随系统 ≠ 跟随源，44.1k 源在 48k 混音的机器上必然重采样一次，
        // 所以这一档不承诺 bit-perfect；要 bit-perfect 仍选「保持源采样率」。
        // 独占模式下真正的开流率由我们决定，系统率只当"当前配置"的参考值 ——
        // 这正是用户要的"锁定声卡当前设置的采样率"。
        uint32_t sysRate = 0;
        if (reqRate == "follow") {
            // macOS：CoreAudio 无"混音格式"概念，跟随设备当前标称采样率（语义等价：
            // 用户要的"锁定声卡当前设置的采样率"，kAudioDevicePropertyNominalSampleRate）。
            std::string dn, di;
            mac_find_dev(pEff.device, dn, di);
            for (const auto& d : mac_enum_devices())
                if (d.id == di && d.nominalRate) { sysRate = d.nominalRate; break; }
            if (!sysRate) play_log("SYSRATE_EMPTY 设备标称率不可读");
        }
        const rta::audio::RatePick pick =
            rta::audio::pick_output_rate(reqRate, in.rate, probeRates, sysRate);
        cfg.outRate = pick.rate;
        {
            const std::string devShown = pEff.device.empty() ? std::string("默认端点") : pEff.device;
            if (rateStale) {
                play_log("RATEPROBE_STALE 自动采样率沿用上次结果 " + std::to_string(pick.rate) +
                         " Hz（本次探测为空） device=" + devShown);
                appendNote("自动采样率沿用上次探测结果 " + std::to_string(pick.rate) +
                           " Hz（本次探测为空，端点可能正在重配置）");
            } else if (!pick.logTag.empty()) {
                // 探测为空且无缓存：绝不能当成"探测结果就是源率"（那正是第二首按 44100
                // 开流、在 PLAY 之前就报错退出的事故根因）。logTag 让日志能自证。
                play_log(pick.logTag + " " + pick.note + " device=" + devShown);
                appendNote(pick.note);
            } else if (!pick.note.empty()) {
                appendNote(pick.note);        // 例如采样率参数无法解析
            }
        }
        // 用户是否选了「自动采样率」（max / 跟随源 / 未指定）。
        // ★ 判据必须用 p.rate（用户原始输入），不能用上面的 reqRate —— 非 WASAPI 后端时
        //   reqRate 被归一成 "src"，那是实现细节，不是用户意图。
        // 用途：能力不命中时的行为要分档 ——
        //   自动档的职责是「让声音出来」⟹ 挑一个设备能用的率继续播（否则 44.1k 源在只支持
        //     48k 族的端点上永远没声音，而这类端点很常见）；
        //   明确选择的职责是「如实告诉用户做不到」⟹ 保持硬失败，绝不悄悄改成别的率。
        //   保真播放器不能替用户改主意：错要错得看得见（用户选了 768k 就该知道设备做不了）。
        // follow 也属于「自动档」：它的职责是"让声音出来"，所以设备做不到系统率时
        // 允许按 pick_supported_rate 挑一个能用的（与 max 同族逻辑）。
        const bool rateAuto = (p.rate == "max" || p.rate == "src" || p.rate.empty() ||
                               p.rate == "follow");

        // 自动抖动：按输出位深选型（16 bit 用 NS9，24 bit 用 LNS15，更高位深不整形）
        if (p.shaper == "auto") {
            const int ob = cfg.outBits ? cfg.outBits : in.bits;
            cfg.shaper = (ob <= 16) ? rta::dsp::Shaper::NS9
                       : (ob <= 24) ? rta::dsp::Shaper::LNS15
                                    : rta::dsp::Shaper::None;
        }

        // 过采样峰值（ISP）检测：逐块扫描（4 相 × 8 抽头）。
        // ★ 旧实现把整曲铺成 double 平面（2 声道 × 8 字节 × 帧数）：384 s DSD64 就是 1034 MB，
        //   而且 detect_isp 全曲扫描要 2887 ms —— 这正是"点播放后 7 秒没声音"的一半原因。
        //   改为块级扫描后：内存只占一块（256K 帧 ≈ 4 MB），数学与整曲扫描逐位相同。
        // ★ 必须用 sample() 而不是直接读 raw：float WAV 的 raw 是 float 的位模式。
        double preAtten = 0.0;
        double ispPeak = 0.0;
        double srcPeak = 0.0;
        long long ispOver = 0;
        std::string ispScan = "off";
        if (p.isp || p.dsd >= 64) {
            const auto t_isp_0 = std::chrono::steady_clock::now();
            const double winSec = rta::audio::big_file_stream_settings().ispPrescanSec;
            // 扫描范围按**本区间**（cue 分轨时不是整轨）：partial 判据也用 srcCount
            const bool partial = src.streaming() && (double)srcCount > winSec * (double)in.rate;
            const size_t limit = partial ? (size_t)(winSec * (double)in.rate) : srcCount;
            const BigIspScan sc = scan_isp_blocks(src, srcBase, limit, partial);
            ispPeak = sc.peak;
            srcPeak = sc.srcPeak;
            ispOver = sc.over;
            ispScan = partial ? "partial" : "full";
            const double ispMs = std::chrono::duration<double, std::milli>(
                                     std::chrono::steady_clock::now() - t_isp_0).count();
            char b[260];
            std::snprintf(b, sizeof(b), "scan=%s ms=%.0f frames=%zu/%zu peak=%.4f over=%lld srcPeak=%.4f base=%zu",
                          ispScan.c_str(), ispMs, sc.scannedFrames, srcCount, ispPeak, ispOver, srcPeak, srcBase);
            play_log(mem_line("isp", b));
            if (p.isp && sc.peak > 1.0) {
                const double peakDb = 20.0 * std::log10(sc.peak);
                preAtten = std::max(-3.0, -std::ceil(peakDb * 10.0) / 10.0 - 0.1);
            }
        }
        dlog("stage isp-ok");

        // DSD 调制器余量（2026-10-21）：1-bit 5 阶在 DSD64 上实测最大稳定输入约 0.65
        // （0.70 起环路锁死，输出变成满幅噪音）。这里按本曲真峰值给一个【恒定】预衰减，
        // 只削峰值、不动动态；安静曲目不衰减。不做这一步，任何接近 0 dBFS 的曲目
        // 只要选了 DSD 输出，播到第一个大动态就会"突然变噪音"。
        double modHeadroomDb = 0.0;
        if (p.dsd >= 64) {
            double peak = std::max(std::max(srcPeak, ispPeak), 1e-9);
            // 流式文件的峰值只扫了开头 isp_prescan_sec 秒：若后面出现更大的峰值而余量按前面算，
            // 1-bit 调制器会过载锁死（0.70 起环路锁死，见 dsd_integrator/modulator 注释）。
            // 所以流式 + DSD 输出时按满幅保守取值（代价约 -4.4 dB，换来"任何曲目都不会锁死"）。
            if (src.streaming() && peak < 1.0) {
                peak = 1.0;
                play_log("MODHEADROOM stream_partial_peak=1.0（流式峰值预扫只覆盖开头，按满幅保守取值）");
            }
            const double afterIsp = peak * std::pow(10.0, preAtten / 20.0);
            modHeadroomDb = rta::dsp::sdm_headroom_db(afterIsp);
            if (modHeadroomDb < 0.0) preAtten += modHeadroomDb;
            if (preAtten < -12.0) preAtten = -12.0;   // 极端峰值也不至于把曲目变哑
        }
        cfg.preAttenDb = preAtten;
        cfg.twoStage = p.twoStage;

        // ---- DSD Native：本平台没有原生 DSD 驱动通道，如实告知而不是假装在放 ----
        if (p.dsdNative) {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error = "DSD Native 需要 Windows 专有驱动通道，macOS 上不可用；请用 DoP（CoreAudio 可承载）。";
            return false;
        }

        // ---- DSD（DoP）：管线先升到 DSD 速率，再调制 + 打包成 24-bit 载波 ----
        const bool dop = (p.dsd >= 64);
        uint32_t deviceRate = cfg.outRate;            // 设备真正打开的采样率
        uint32_t dsdRate = 0;
        if (dop) {
            const uint32_t base = (in.rate % 48000u == 0) ? 48000u : 44100u;
            dsdRate    = rta::dsp::dsd_rate(p.dsd, base);
            deviceRate = dsdRate / 16u;               // DoP 载波
            cfg.outRate = dsdRate;
            cfg.outBits = 24;                         // DoP 固定 24-bit 容器
            cfg.shaper  = rta::dsp::Shaper::None;     // 抖动交给调制器之后的 1-bit 量化
            // F-5 自证：先把**请求值**写出去（level/有效码率/载波/族/请求阶数）。
            // 真正的**生效阶数**由生产者在 stable_sdm_order() 之后覆盖（见下方调制器创建处）——
            // 用户填 7 阶、按位率被降成 5 阶时，/api/status 的 modOrder 必须是实际值，
            // 否则"我选了 EC-7"永远无法证伪（上游 261025-02 #5 同款口径）。
            // ★ carrierRate 单独给：DoP 的 PCM 载波率（= dsdRate/16，也就是 ps.outRate）
            //   与 DSD 有效码率是两个数，只给一个必然被误读成"PCM 降级"。
            set_out_format_state(out_mode_of_backend(p.backend).c_str(),
                                 p.dsd, dsdRate, deviceRate,
                                 p.modFamily.empty() ? std::string("dsd") : p.modFamily,
                                 p.modOrder > 0 ? p.modOrder : 5,
                                 std::string());
        }

        // 设备能力检查（仅 WASAPI）。HF-01/02/04 接线（2026-10-22）：
        //   * rates.empty() 一律当「不支持/端点异常」，绝不静默放行（交接单 §6）；
        //   * 位深候选序列：请求位深 → 源位深(8/16/24/32) → 16 → 32，去重后依序检查，
        //     首个「独占支持列表含目标率」的位深生效（记 effectiveBits → cfg.outBits）；
        //   * 全不命中 → 用 probe_formats 拿三档列表，错误含 deviceId、请求 rate/bits、
        //     16/24/32 各自支持列表（不再只丢 UNSUPPORTED_FORMAT）；
        //   * 降位深必须在信号链 note 与 PLAY 日志明示，不能悄悄变（交接单 §3 风险注）；
        //   * deviceRate==0（解析不出设备率）防御：错误带 inRate/frames/rate/dsd（HF-04）。
        if (p.backend.empty() || p.backend == "wasapi") {
            // deviceRate 为 0 表示"跟随源"——设备真正会打开的率是 in.rate（与下方 outRate 解析一致）。
            // DoP 时 deviceRate 已是 DoP 载波，必非 0。
            const uint32_t wantDevRate = dop ? deviceRate : (deviceRate ? deviceRate : in.rate);
            if (wantDevRate == 0) {
                std::lock_guard<std::mutex> lk(ps.mtx);
                char eb[256];
                std::snprintf(eb, sizeof(eb),
                              "输出采样率解析为 0（防御，拒绝开流）：inRate=%u frames=%zu rate=%s dsd=%d",
                              (unsigned)in.rate, srcFrames, p.rate.c_str(), p.dsd);
                ps.error = eb;
                return false;
            }
            // 错误文案带上源采样率与后端：日志要能自证（哪首源、哪个后端、请求的什么率）
            const std::string srcDesc = "（源采样率 " + std::to_string(in.rate) + " Hz，后端 " +
                                        (p.backend.empty() ? std::string("wasapi") : p.backend) + "）";
            if (dop) {
                // DoP 路径：24-bit 容器固定，不参与位深回退（维持现状）；空列表不再当成功。
                // 载波率不可变（DoP 的 0x05/0xFA 标记依赖精确的 DSD/16），所以这里保持硬失败。
                // 探测带重试 + 缓存兜底：DoP 的载波率不可变（不换率），但"探测为空"绝不等于
                // "设备不支持" —— 一次瞬时为空不能让 DSD 播放被误判成硬失败。
                const auto rates = probe_rates_cached(pEff.device, 24, in.channels, "DoP 载波率检查");
                bool ok = false;
                for (auto r : rates) if (r == deviceRate) ok = true;
                if (!ok) {
                    std::string list;
                    for (size_t i = 0; i < rates.size(); ++i) { if (i) list += " / "; list += std::to_string(rates[i]); }
                    std::lock_guard<std::mutex> lk(ps.mtx);
                    ps.error = (rates.empty()
                        ? ("设备独占支持列表为空（端点不可用或 24-bit 容器不被接受），无法确认 DoP 所需的 " +
                           std::to_string(deviceRate) + " Hz（DSD" + std::to_string(p.dsd) + "）。")
                        : ("设备不支持 DoP 所需的 " + std::to_string(deviceRate) + " Hz（DSD" +
                           std::to_string(p.dsd) + "）。设备支持：" + list)) +
                        "；端点 id=" + (pEff.device.empty() ? std::string("(默认端点)") : pEff.device) + srcDesc;
                    return false;
                }
            } else {
                const int reqBits = (p.bits > 0) ? p.bits : 24;
                int bitsCand[4];
                int nBits = 0;
                auto pushBit = [&](int b) {
                    if (b != 8 && b != 16 && b != 24 && b != 32) return;   // 候选只认合法位深
                    for (int i = 0; i < nBits; ++i) if (bitsCand[i] == b) return;   // 去重
                    if (nBits < 4) bitsCand[nBits++] = b;
                };
                pushBit(reqBits);                                          // ① 请求位深（默认 24）
                if (in.bits == 8 || in.bits == 16 || in.bits == 24 || in.bits == 32)
                    pushBit(in.bits);                                      // ② 源位深
                pushBit(16);                                               // ③ 16
                pushBit(32);                                               // ④ 32
                int effBits = 0;
                // 位深循环里每个候选位深的支持列表都留一份：目标率不命中时，自适应换率
                // 要在这三档位深里挑，不能只试最后一个（否则可能白丢一个本来能用的位深）
                std::vector<std::vector<uint32_t>> ratesByBits((size_t)std::max(nBits, 1));
                for (int i = 0; i < nBits && effBits == 0; ++i) {
                    // 探测带重试 + 缓存兜底：独占流刚 close 时 IsFormatSupported 会瞬时返回空列表，
                    // 空列表若被当成"该位深什么都不支持"，即使 rate=max 靠缓存拿到了率也照样硬失败
                    const auto rates = probe_rates_cached(pEff.device, bitsCand[i], in.channels, "位深能力检查");
                    if (i < (int)ratesByBits.size()) ratesByBits[(size_t)i] = rates;
                    if (rates.empty()) continue;     // 该位深独占全不支持/端点异常 → 试下一位深
                    for (auto r : rates) if (r == wantDevRate) { effBits = bitsCand[i]; break; }
                }
                if (effBits == 0 && rateAuto) {
                    // ---- 自适应换率：只用于「自动/跟随源」档 ----
                    // 为什么自动档要换：44.1k 源 + 只支持 48k/96k 族的端点是很常见的组合
                    //（本机就是这样），硬失败等于这类端点永远放不出声音。降一点总比不出声好。
                    // 为什么明确选择档【不换】：用户选了 96000 / 768000 就是要在那个率上听，
                    // 设备做不到时必须如实报错（见下方 effBits==0 的硬失败分支），
                    // 替用户悄悄改成别的率等于骗他 —— 这是保真播放器，不是"能响就行"的播放器。
                    // 判据用纯函数 pick_supported_rate（同族优先，避免 44.1k 换到 48k 族引入
                    // 非整数比重采样），并把它钉在 test_ratepick.cpp 里。
                    // 取【第一个非空】位深列表（位深优先于换率：能保 24-bit 就不降到 16-bit；
                    // 而且若该列表恰好含源率，就等于完全不用重采样 —— 最优解）
                    int      effBitsFB = 0;
                    uint32_t pickedRate = 0;
                    std::string pickedWhy;
                    for (int i = 0; i < nBits && effBitsFB == 0; ++i) {
                        const std::vector<uint32_t>& rates = (i < (int)ratesByBits.size())
                            ? ratesByBits[(size_t)i] : ratesByBits[0];
                        uint32_t outR = wantDevRate;
                        const auto dec = rta::audio::decide_capability_failure(rateAuto, wantDevRate, rates, outR, in.rate);
                        if (dec.action == rta::audio::CapAction::FallbackRate && outR > 0) {
                            effBitsFB = bitsCand[i];
                            pickedRate = outR;
                            pickedWhy = dec.userMessage;
                        }
                    }
                    if (effBitsFB != 0 && pickedRate != 0) {
                        // 设备真正打开的是 pickedRate：cfg.outRate 与 deviceRate 必须同时改。
                        // deviceRate 在 cfg.outRate 之后初始化、又在 !dop 时按 outRate 重算，
                        // 两边都改才能保证 sink->open / STAT / totalOut 三者一致（见报告里的核对链）。
                        // 位深与抖动选型交给下方既有逻辑（effBits 赋值后统一处理），不在这里重复。
                        cfg.outRate = pickedRate;
                        deviceRate  = pickedRate;   // 本分支只在 !dop 时进入（DoP 走上面的硬失败）
                        // 不能悄悄换率：note / ps.info / 信号链 JSON 都要写明（HF-01 同理）
                        std::string why = pickedWhy.empty()
                                          ? ("目标 " + std::to_string(wantDevRate) + " Hz 独占不支持，已用 " +
                                             std::to_string(pickedRate) + " Hz（源 " +
                                             std::to_string(in.rate) + " Hz 重采样，非 bit-perfect）")
                                          : pickedWhy;
                        appendNote(why);
                        bitNote = bitNote.empty() ? why : (bitNote + "；" + why);
                        appendFallback(why);   // F-5：换采样率也是"与请求不一致"
                        play_log("RATEFALLBACK " + why + " bits=" + std::to_string(effBitsFB) +
                                 " device=" + (pEff.device.empty() ? std::string("默认端点") : pEff.device));
                        // 走到这里说明已选定位深与采样率，跳过下面的硬失败
                        effBits = effBitsFB;
                    }
                }
                if (effBits == 0) {
                    // 全不命中：probe_formats 拿三档列表，错误带端点 id 与请求值
                    auto join = [](const std::vector<uint32_t>& v) {
                        std::string s;
                        for (size_t k = 0; k < v.size(); ++k) { if (k) s += "/"; s += std::to_string(v[k]); }
                        return s.empty() ? std::string("无") : s;
                    };
                    std::ostringstream es;
                    es << "设备独占模式不支持 " << wantDevRate << " Hz（请求位深 " << reqBits
                       << "-bit，候选 16/24/32 全不命中）。";
                    // macOS：CoreAudio caps 是"整设备一份率表"（无按位深分档），用已探测的列表
                    {
                        const std::vector<uint32_t>& rl = ratesByBits.empty()
                            ? std::vector<uint32_t>() : ratesByBits[0];
                        es << "设备 id=" << (pEff.device.empty() ? std::string("(默认端点)") : pEff.device)
                           << "；CoreAudio 支持率: " << join(rl)
                           << srcDesc;
                    }
                    if (!rateAuto) {
                        // 明确选择档：绝不自动改率，但必须让用户清楚「做不到的是你选的那个率」
                        const auto dec = rta::audio::decide_capability_failure(false, wantDevRate, {});
                        es << "。" << dec.userMessage;
                    }
                    std::lock_guard<std::mutex> lk(ps.mtx);
                    ps.error = es.str();
                    return false;
                }
                if (effBits != reqBits) {
                    // 不能悄悄降位深：note 进 ps.info 与信号链 JSON（PLAY 日志随之带出）
                    const std::string bn = "实际输出 " + std::to_string(effBits) + "-bit（设备不支持 " +
                                           std::to_string(reqBits) + "-bit 独占）";
                    appendNote(bn);
                    // 追加而不是覆盖：上面可能已经写过换采样的 RATEFALLBACK 说明，不能丢掉
                    bitNote = bitNote.empty() ? bn : (bitNote + "；" + bn);
                    appendFallback(bn);   // F-5：降位深同样是"与请求不一致"
                }
                cfg.outBits = effBits;
                if (p.shaper == "auto") {
                    // 位深变了，自动抖动选型跟着变（16→NS9，24→LNS15，更高不整形）
                    cfg.shaper = (cfg.outBits <= 16) ? rta::dsp::Shaper::NS9
                               : (cfg.outBits <= 24) ? rta::dsp::Shaper::LNS15
                                                     : rta::dsp::Shaper::None;
                }
            }
        }

        // ---- WASAPI 共享后端：格式由系统混音引擎（GetMixFormat）决定 ----
        // 不走独占能力检查；输出采样率与声道一律对齐混音格式：
        //   * 管线只做一次重采样到 mix_rate，系统引擎不再二次重采样（避免双重降质）；
        //   * 声道对齐 mix_channels（管线负责 downmix/upmix），否则共享开流直接错乱。
        uint32_t mixRate = 0;
        int      mixCh   = 0;
        bool     mixFloat = false;
        if (p.backend == "wasapi-shared") {
            std::string mixErr;
            // macOS 共享模式：CoreAudio 混音域恒为 float32、声道取设备输出流声道数（实测 2ch），
            // 率取设备当前标称率（§13.10.3：共享路径数值在 |v|<2^24 时逐位精确）。
            std::string dn, di;
            mac_find_dev(pEff.device, dn, di);
            for (const auto& d : mac_enum_devices()) {
                if (d.id == di) { mixRate = d.nominalRate; break; }
            }
            mixCh = 2;
            mixFloat = true;
            if (!mixRate) {
                std::lock_guard<std::mutex> lk(ps.mtx);
                ps.error = "读取设备标称采样率失败（共享模式）；端点=" +
                           (pEff.device.empty() ? "(默认)" : pEff.device);
                return false;
            }
            const uint32_t wantRate = cfg.outRate ? cfg.outRate : (uint32_t)in.rate;
            if (wantRate != mixRate) {
                const std::string shareWhy = "共享模式按系统混音率 " + std::to_string(mixRate) +
                                             " Hz 输出（请求 " + std::to_string(wantRate) +
                                             " Hz，非 bit-perfect）";
                appendNote(shareWhy);
                appendFallback(shareWhy);   // F-5：共享模式改采样率是**必然**的降级路径
            }
            cfg.outRate = mixRate;                     // 下方 outRate/deviceRate 随之取 mixRate
            if (p.outChannels > 0 && p.outChannels != mixCh)
                appendNote("共享模式输出声道按系统混音 " + std::to_string(mixCh) + " ch（请求 " +
                           std::to_string(p.outChannels) + " ch 已忽略）");
            pEff.outChannels = mixCh;                  // 下方 outCh 取 pEff —— 管线负责声道变换
        }

        // 滤波器：1x 与 Nx 可以分开选（RLPlayer 的标准做法：
        // 44.1/48k 用陡一点的，>=88.2k 用短一点的，避免过度处理）
        // DSD 输出时优先用 SDM 页那一组滤波器（与 PCM 独立）；没选就沿用 PCM 的
        std::string fname;
        if (p.dsd >= 64) {
            fname = (in.rate >= 88200)
                ? (!p.sdmFilterNx.empty() ? p.sdmFilterNx : (!p.filterNx.empty() ? p.filterNx : p.sdmFilter))
                : (!p.sdmFilter.empty() ? p.sdmFilter : p.filter);
        } else {
            fname = (in.rate >= 88200 && !p.filterNx.empty()) ? p.filterNx : p.filter;
        }
        if (!fname.empty()) {
            const auto* fp = rta::dsp::find_preset(fname, in.rate >= 88200);
            if (fp) {
                cfg.taps = fp->taps; cfg.transition = fp->transition; cfg.attenDb = fp->attenDb;
                cfg.filterWindow = fp->window; cfg.filterPhase = fp->phase;
                cfg.twoStage = fp->twoStage;
                // 2026-10-25（音质线）：每相位抽头地板 —— 新预设（*-tight）靠它把「每相位抽头数 T」与
                // 插值因子 L 解耦；否则 44.1→384k（L=1280）时 4095 抽头的预设只剩 4 抽头/相位
                // （20 kHz 掉 5 dB、THD+N 只剩 -29 dBFS）。既有预设 tapsPerInput=0，逐位不变。
                cfg.minTapsPerInput = fp->tapsPerInput;
                if (fp->twoStage && fp->stage2Taps > 0) cfg.stage2Taps = fp->stage2Taps;
            }
        }

        // ---- 手动覆盖（设置页里可以逐项调，不再受预设限制）----
        if (p.taps > 0)       cfg.taps = std::max(1024, p.taps);
        if (p.minTapsPerInput > 0) cfg.minTapsPerInput = p.minTapsPerInput;
        if (p.atten > 0.0)    cfg.attenDb = std::min(300.0, std::max(60.0, p.atten));
        if (p.transition > 0.0) cfg.transition = std::min(0.45, std::max(0.005, p.transition));
        if (p.phase == "minimum") cfg.filterPhase = rta::dsp::PhaseKind::Minimum;
        else if (p.phase == "linear") cfg.filterPhase = rta::dsp::PhaseKind::Linear;
        else if (p.phase == "intermediate") cfg.filterPhase = rta::dsp::PhaseKind::Intermediate;

        // ---- EQ（REW / AutoEq 文本）：在【输入采样率】上工作（EQ 位于重采样之前）----
        bool eqLoaded = false;
        if (!p.eqFile.empty()) {
            std::ifstream ef(p.eqFile);
            if (!ef) {
                ef.open(path_in_exe_dir(p.eqFile.c_str()));
            }
            if (ef) {
                std::string text((std::istreambuf_iterator<char>(ef)), std::istreambuf_iterator<char>());
                // 去掉 UTF-8 BOM
                if (text.size() > 3 && (unsigned char)text[0] == 0xEF && (unsigned char)text[1] == 0xBB) text.erase(0, 3);
                try {
                    auto spec = rta::dsp::parse_eq_text(text);
                    auto chain = rta::dsp::build_eq_filters(spec, (double)in.rate);
                    if (!chain.empty() || spec.preampDb != 0.0) {
                        const size_t maxCh = (size_t)std::max(in.channels, 2);
                        if (cfg.channel.size() < maxCh) cfg.channel.resize(maxCh);
                        for (size_t c = 0; c < maxCh; ++c) {
                            cfg.channel[c].eq = chain;
                            if (spec.preampDb != 0.0) cfg.channel[c].gainDb += spec.preampDb;
                        }
                        eqLoaded = true;
                    }
                } catch (...) { /* 解析失败就当没配 */ }
            }
        }

        // ---- 20 段参数均衡 PEQ（261024-02 #6）----
        // 在【输入采样率】、现有文件 EQ 之前处理；挂在管线上，UI 改参数时引擎内部热更新。
        // prepare() 会按本次音源采样率重建全部系数（切歌/切率），最多支持 7.1（8 声道）。
        if (g_peq) {
            g_peq->prepare((double)in.rate, 8);
            cfg.peq = g_peq;
        }

        // ---- 卷积 / 房间校正：IR 是 WAV，按输出声道数铺开 ----
        bool convLoaded = false;
        if (!p.convIr.empty()) {
            try {
                rta::audio::AudioBuffer irb = read_wav(p.convIr);
                if (!irb.raw.empty()) {
                    const size_t maxCh = (size_t)std::max(in.channels, 2);
                    cfg.channel.resize(maxCh);
                    for (size_t c = 0; c < maxCh; ++c) {
                        auto& dst = cfg.channel[c];
                        dst.ir.assign(irb.frames(), 0.0);
                        const int srcCh = (irb.channels > 1) ? (int)(c % (size_t)irb.channels) : 0;
                        for (size_t n = 0; n < irb.frames(); ++n) dst.ir[n] = irb.sample(n, srcCh);
                        dst.useGpu = p.convGpu;
                    }
                    convLoaded = true;
                }
            } catch (...) { /* IR 读失败就当没配 */ }
        }

        // ---------------- 流式渲染 ----------------
        // 生产者线程：分块【解码 -> DSP】-> 有界队列；本线程：按设备事件把队列写进设备。
        // 为什么必须流式：整曲一次性处理时，705.6 kHz 下 5 分钟的输出缓冲就是 1.7 GB，
        // 既会 OOM，VirtualLock 整块更会把系统拖死。分块后内存恒定在几秒量级，
        // 起播延迟也从「整曲处理时间」降到「一块的处理时间」。
        rta::render::RenderQ RQ;

        // outRate = 管线输出（DSD 时是 DSD 速率）；deviceRate = 设备真正打开的采样率
        // （DSD 时是 DoP 载波 = DSD/16）
        const uint32_t outRate  = cfg.outRate ? cfg.outRate : in.rate;
        if (!dop) deviceRate = outRate;
        // 输出声道数：0 = 跟随源。5.1/7.1 需要设备与文件都支持。
        // 共享后端：pEff.outChannels 已被强制为系统混音声道数（见上方共享归一块）。
        const int      outCh    = (pEff.outChannels > 0) ? pEff.outChannels : in.channels;
        if (outCh != in.channels) cfg.outChannels = outCh;
        {
            // 每声道增益：左右平衡 / 多声道校正
            int need = 0;
            for (int c = 0; c < outCh && c < 8; ++c) if (p.trim[c] != 0.0) need = c + 1;
            if (need > 0) {
                if ((int)cfg.channel.size() < need) cfg.channel.resize((size_t)need);
                for (int c = 0; c < need; ++c) cfg.channel[(size_t)c].gainDb = p.trim[c];
            }
        }
        const int      outBits  = cfg.outBits ? cfg.outBits : 24;   // 跟随设置里的输出位深
        // 2026-10-24（261024-02 #8）：bit-perfect 的"位深降低"必须用**源文件真实位深**（p.srcBits，由界面从
        // 元数据带下来）。解码器容器位深（flac 恒为 32）会把 16bit 源 → 24bit 输出误判成"位深降低"。
        const int srcBitsEff = p.srcBits > 0 ? p.srcBits
                              : ((in.bits > 0 && in.bits <= 24) ? in.bits : 0);
        // ★ CUE 分轨：总长按**本区间**（srcCount）算，不是整轨 —— 否则 /api/status 的 dur 与
        //   进度条都会是"整轨"的（实测会看到 dur=10s 而实际只播 4s）。
        const size_t   totalOut = (size_t)((double)srcCount * (double)deviceRate / (double)in.rate + 0.5);
        ps.outRate = deviceRate; ps.outBits = outBits;
        // F-5：把本曲**最终的**输出格式自证写进 ps（PCM 路径）。
        // 走 DoP 的分支上面已经写过一次（含 level/码率/族）；这里补的是：
        //   * PCM 路径：dsd=0 / dsdRate=0 / carrierRate=0 / modFamily 空 / modOrder=0
        //     （**没有调制器参与**，写个非零阶数就是虚构事实）
        //   * fallbackWhy：本次所有降级原因（换采样率/降位深/共享混音率改写/独占→共享回退）
        // ★ 必须在这里统一写，而不是各分支各写一次：漏一处就会出现"降级了但 fallbackWhy 空"，
        //   那比没有这个字段更糟（用户会以为没降级）。
        {
            const std::string mode = out_mode_of_backend(p.backend);
            if (dop) {
                // DoP：只补 fallbackWhy，其余字段保持上面写好的实际值
                std::lock_guard<std::mutex> lk(ps.mtx);
                ps.outFallbackWhy = fallbackWhy;
            } else {
                set_out_format_state(mode.c_str(), 0, 0, 0, std::string(), 0, fallbackWhy);
            }
        }
        ps.total.store(totalOut);

        // ---- 2026-10-25（耳机 EQ 热重载）：起播定位 ----
        // initialSeekFrac 只由「播放中切换 EQ/IR」这条路径设置（见 /api/settings 的 eqChanged 分支）。
        // 正常播放恒为 -1 ⟹ startPos 全 0 ⟹ 与旧行为逐字节相同。
        const StartPos startPos = start_pos_for(p.initialSeekFrac, srcCount, totalOut);
        if (startPos.pos > 0 || startPos.played > 0) {
            ps.played.store(startPos.played);
            std::ostringstream ss;
            ss.setf(std::ios::fixed); ss.precision(4);
            ss << "EQ_RELOAD_SEEK frac=" << p.initialSeekFrac
               << " pos=" << startPos.pos << "/" << srcCount
               << " played=" << startPos.played << "/" << totalOut
               << " eq=" << (p.eqFile.empty() ? "(none)" : p.eqFile);
            play_log(ss.str());
        }

        // 实际端点名称/id：信号链 JSON 与 RENDERFAIL 遥测共用同一来源（HF-02 + 本轮事故归因）
        std::string dev, devId;
        if (p.backend == "null") {
            dev = "Null 输出（不出声）";
            devId = "null";
        } else if (p.backend == "naa") {
            dev = p.naaHost.empty() ? "NAA 127.0.0.1:43210" : p.naaHost;
            devId = "naa";
        } else {
            mac_find_dev(pEff.device, dev, devId);
        }

        // 信号链快照：源文件 -> 解码 -> 重采样 -> 抖动 -> 音量 -> 设备
        {
            const MediaInfo mi = probe_media(file);
            // HF-02：device/deviceId 反映【实际使用的端点】（含回退默认端点后的真实身份），
            // 不再无条件下写成默认设备 —— 1.log 那种"只有友好名没有 id"的日志无法区分端点失效。
            // DSD 源抽取设置（P0-5）：信号链里如实写出来，便于核对"选的是不是真生效"
            const rta::dsp::DsdConversion dsdConv = rta::dsp::parse_conversion(p.dsdConv);
            const std::string dsdConvName = rta::dsp::conversion_name(dsdConv);
            const double dsdPassbandHz = rta::dsp::conversion_passband(dsdConv);
            std::ostringstream sig;
            sig << "{\"src\":\"" << jesc(file) << "\""
                << ",\"codec\":\"" << jesc(mi.codec.empty() ? "wav" : mi.codec) << "\""
                << ",\"inRate\":" << in.rate
                << ",\"inBits\":" << in.bits
                << ",\"inCh\":" << in.channels
                << ",\"dur\":" << (double)srcCount / (double)in.rate
                // CUE 分轨：本曲在整轨文件里的区间（秒；cueStart<0 = 整首）。
                // 界面据此显示"本轨 0:04/0:04"而不是"整轨 10:00"。
                << ",\"cueStart\":" << p.cueStart
                << ",\"cueEnd\":" << p.cueEnd
                << ",\"fileDur\":" << (double)srcFrames / (double)in.rate
                << ",\"note\":\"" << jesc(note.text) << "\""
            << ",\"outRate\":" << outRate
            << ",\"outBits\":" << outBits
            << ",\"outCh\":" << outCh
            << ",\"device\":\"" << jesc(dev) << "\""
            << ",\"deviceId\":\"" << jesc(devId) << "\""
            << ",\"bitsFallback\":\"" << jesc(bitNote) << "\""
                // 2026-10-23（用户 261023-02 #1）：信号链要在显眼处给出**权威的 bit-perfect 结论**，
                // 而不是让用户自己从 resample/volume/shaper/eq 等一堆字段里推。
                // 判定口径（严格）：①不重采样（outRate == in.rate）②音量增益为 0 dB ③无抖动/整形器
                // ④无 EQ / IR 卷积 ⑤非 DoP(DSD 载波必然重采样) ⑥位深未降(实际输出 ≥ 源位深)。
                // 注意：DirectSDM 一比特直通是另一条更严格的路，单独标 bitPerfect=direct。
                << ",\"resample\":" << (outRate != in.rate ? "true" : "false")
                << ",\"twoStage\":" << ((cfg.twoStage && outRate >= in.rate * 8) ? "true" : "false")
                << ",\"taps\":" << cfg.taps
                << ",\"filter\":\"" << jesc(fname.empty() ? std::string("Kaiser sinc") : fname) << "\""
                << ",\"phaseCode\":\"" << (cfg.filterPhase == rta::dsp::PhaseKind::Minimum ? "minimum"
                                            : (cfg.filterPhase == rta::dsp::PhaseKind::Intermediate ? "intermediate" : "linear")) << "\""
                << ",\"gpuAvailable\":" << (rta::dsp::GpuBridge::instance().available() ? "true" : "false")
                << ",\"phase\":\"" << (cfg.filterPhase == rta::dsp::PhaseKind::Minimum ? "最小相位"
                                  : (cfg.filterPhase == rta::dsp::PhaseKind::Intermediate ? "混合相位" : "线性相位")) << "\""
                << ",\"shaper\":\"" << jesc(p.shaper == "auto" ? std::string(rta::dsp::shaper_name(cfg.shaper))
                                                          : (p.shaper.empty() ? std::string("none") : p.shaper)) << "\""
                << ",\"loudness\":" << (p.loudness ? "true" : "false")
                << ",\"volume\":" << p.volume
                << ",\"buffer\":" << p.bufferMs
                << ",\"dsdKind\":\"" << jesc(p.dsdKind.empty() ? std::string("fir") : p.dsdKind) << "\""
                << ",\"dsdConv\":\"" << jesc(dsdConvName) << "\""
                << ",\"dsdPassband\":" << dsdPassbandHz
                << ",\"dsd\":" << (dop ? p.dsd : 0)
                << ",\"dsdRate\":" << (dop ? dsdRate : 0)
                << ",\"modFamily\":\"" << jesc(p.modFamily.empty() ? std::string("dsd") : p.modFamily) << "\""
                 << ",\"modOrder\":" << (dop ? (p.modOrder > 0 ? p.modOrder : 5) : 0)
                << ",\"ispPeak\":" << ispPeak
                << ",\"ispOver\":" << ispOver
                // ispScan: full（整曲扫描）/ partial（流式文件只扫开头 isp_prescan_sec 秒）/ off
                << ",\"ispScan\":\"" << ispScan << "\""
                // stream: 本次是否走流式解码（大文件）；inBufMb = 整曲缓冲大小（流式时为 0）
                << ",\"stream\":" << (src.streaming() ? "true" : "false")
                << ",\"inBufMb\":" << ((double)buf.raw.size() * 4.0 / (1024.0 * 1024.0))
                << ",\"srcPeak\":" << srcPeak
                << ",\"modHeadroom\":" << modHeadroomDb
                << ",\"preAtten\":" << preAtten
                << ",\"atten\":" << cfg.attenDb
                << ",\"conv\":" << (convLoaded ? "true" : "false")
                << ",\"irGpu\":" << (p.convGpu ? "true" : "false")
                << ",\"gpuVendor\":\"" << jesc(p.gpuVendor) << "\""
                << ",\"gpuStatus\":\"" << jesc(rta::dsp::GpuBridge::instance().status()) << "\""
                << ",\"volRamp\":" << cfg.volumeRampMs
                << ",\"bits\":" << outBits
                << ",\"srcBits\":" << p.srcBits
                << ",\"eq\":" << (eqLoaded ? "true" : "false")
                << ",\"directSdm\":false"
                << ",\"directNote\":\"" << jesc(directNote) << "\""
                << ",\"rg\":\"" << jesc(ps.rgMode) << "\""
                << ",\"rgDb\":" << ps.rgAppliedDb
                << ",\"rgClip\":" << (ps.rgClipLimited ? "true" : "false")
                << ",\"rgSource\":\"" << jesc(ps.rgSource) << "\""
                << ",\"rgNote\":\"" << jesc(ps.rgNote) << "\""
                // ---- bit-perfect 权威结论（用户 261023-02 #1）----
                // 三态：direct（DirectSDM 1-bit 直通，最严格）/ yes / no（附原因）
                // 口径：①不重采样 ②音量 0 dB ③无抖动/整形 ④无衰减 ⑤无 EQ/IR ⑥非 DoP ⑦位深未降
                // 2026-10-24（261024-02 #8）：位深判据用"源文件真实位深"（见下方 srcBitsEff 声明）
                << ",\"bitPerfect\":\"" << ([&] {
                       if (p.directSdm && directNote.empty()) return std::string("direct");
                       if (outRate != in.rate) return std::string("no");
                       if (std::fabs(p.volume) > 1e-9) return std::string("no");
                       if (cfg.shaper != rta::dsp::Shaper::None) return std::string("no");
                       // 2026-10-24（261024-02 #8）：attenDb 是**滤波器阻带衰减设计值**（如 120 dB），
                       // 不是信号增益！以前拿它判"衰减"⟹ 只要选了滤波器预设就永远非 bit-perfect（误报）。
                       // 真正的信号衰减是 preAttenDb（ISP/调制器余量预衰减）。
                       if (cfg.preAttenDb > 1e-9) return std::string("no");
                       if (eqLoaded || convLoaded || dop) return std::string("no");
                       if (srcBitsEff > 0 && outBits > 0 && outBits < srcBitsEff) return std::string("no");
                       if (std::fabs(cfg.replayGainDb) > 1e-9) return std::string("no");
                       return std::string("yes");
                   }()) << "\""
                << ",\"bitPerfectWhy\":\"" << jesc([&] {
                       if (p.directSdm && directNote.empty()) return std::string("DirectSDM：1-bit 直通，跳过 PCM 与调制");
                       std::vector<std::string> why;
                       if (outRate != in.rate) why.push_back("重采样 " + std::to_string(in.rate) + "→" + std::to_string(outRate) + " Hz");
                       if (std::fabs(p.volume) > 1e-9) why.push_back("音量 " + std::to_string((int)std::lround(p.volume)) + " dB");
                       if (cfg.shaper != rta::dsp::Shaper::None) why.push_back("抖动/整形");
                       if (cfg.preAttenDb > 1e-9) why.push_back("预衰减");
                       if (eqLoaded) why.push_back("EQ");
                       if (convLoaded) why.push_back("IR 卷积");
                       if (dop) why.push_back("DoP 载波");
                       if (srcBitsEff > 0 && outBits > 0 && outBits < srcBitsEff) why.push_back("位深降低");
                       if (std::fabs(cfg.replayGainDb) > 1e-9) {
                           char rgb[64];
                           std::snprintf(rgb, sizeof(rgb), "ReplayGain (%+.2f dB)", cfg.replayGainDb);
                           why.push_back(rgb);
                       }
                       if (why.empty()) return std::string("源→解码→输出全程逐位一致");
                       std::string s; for (size_t i = 0; i < why.size(); ++i) { if (i) s += "、"; s += why[i]; }
                       return s;
                   }()) << "\""
                << ",\"decodeMs\":" << note.totalMs
                << ",\"ffmpegMs\":" << note.ffmpegMs
                << ",\"wavReadMs\":" << note.wavReadMs
                << ",\"scanMs\":" << Library::instance().lastScanMs()
                << "}";
            recent_add(file, mi.title.empty() ? stem_or_self(file) : mi.title,
                       mi.artist, mi.album);
            // 把结论写进 ps 供 /api/status 带出（用同一个判定，避免两处口径漂移）
            {
                std::string bps = "no", bpw = "见信号链";
                if (p.directSdm && directNote.empty()) { bps = "direct"; bpw = "DirectSDM：1-bit 直通，跳过 PCM 与调制"; }
                else {
                    std::vector<std::string> why;
                    if (outRate != in.rate) why.push_back("重采样 " + std::to_string(in.rate) + "→" + std::to_string(outRate) + " Hz");
                    if (std::fabs(p.volume) > 1e-9) why.push_back("音量 " + std::to_string((int)std::lround(p.volume)) + " dB");
                    if (cfg.shaper != rta::dsp::Shaper::None) why.push_back("抖动/整形");
                    if (cfg.preAttenDb > 1e-9) why.push_back("预衰减");   // 见上方口径注：attenDb 是滤波设计值
                    if (eqLoaded) why.push_back("EQ");
                    if (convLoaded) why.push_back("IR 卷积");
                    if (dop) why.push_back("DoP 载波");
                    if (srcBitsEff > 0 && outBits > 0 && outBits < srcBitsEff) why.push_back("位深降低");
                    if (std::fabs(cfg.replayGainDb) > 1e-9) {
                        char rgb[64];
                        std::snprintf(rgb, sizeof(rgb), "ReplayGain (%+.2f dB)", cfg.replayGainDb);
                        why.push_back(rgb);
                    }
                    if (why.empty()) { bps = "yes"; bpw = "源→解码→输出全程逐位一致"; }
                    else { std::string s; for (size_t i = 0; i < why.size(); ++i) { if (i) s += "、"; s += why[i]; } bpw = s; }
                }
                std::lock_guard<std::mutex> lk(ps.mtx);
                ps.bpState = bps; ps.bpWhy = bpw;
            }
            dlog("stage recent-ok");
            play_log(std::string("PLAY v") + RLPLAYER_VERSION + " " + sig.str());
            dlog("stage playlog-ok");
            meta_on_play(file);   // 播放触发元数据补全(设置可关;inFlight 去重,后台线程)
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.signal = sig.str();
            // 2026-10-24（用户 261024-04 #8）：GPU 标志**每曲复位**。
            // 旧代码只有 DirectSDM 分支复位过 ps.gpu，普通路径一路沿用上一曲的值 ——
            // 这就是"bit-perfect 直通时右下角 GPU 图标还亮着"的直接根因。
            // 必须先复位再起生产者/渲染线程，否则它们会把上一曲的 true 当成本次的事实。
            ps.gpu = false;
            ps.gpuConvUsed.store(false);
        }
        ps.startDb.store(0.0);
        dlog("stage sig-ok");
        // ★ 必须无条件重置：旧代码只在 p.volume != 0 时写 volDb，导致上一曲
        //   拖过音量后，下一曲的实时增益 = 旧 volDb - 新 startDb（凭空多减几十 dB）。
        ps.volDb.store(p.volume);

        std::thread prod([&]() {
            const size_t kChunk = 4096;
            uint64_t myEpoch = RQ.epoch.load();
            auto pl = std::make_unique<eng::Pipeline>(cfg);
            // ---- CUE 分轨（2026-10-25）：生产者在 [srcBase, srcBase+srcCount) 里跑 ----
            // 为什么用"从 srcBase 起读"而不是"整轨读出来再丢"：两者对设备完全等价（区间之前的
            // 帧一个都不会进 RQ），但前者不为前 4 秒付解码/DSP 的代价，40 分钟的 cue 第 12 首
            // 也不会先把前 30 分钟跑一遍。
            // seek：render_loop 给的 seekFrame 是**区间内**的帧号（h.inFrames=srcCount），
            // 所以这里加回 srcBase —— 0 = 本轨开头，这是"暂停/跳转相对本节区间"的落点。
            const size_t segEnd = srcBase + srcCount;
            size_t pos = srcBase + startPos.pos, skipOut = 0, blocksDone = 0;

            // ---- DSD：每声道一个调制器（状态必须跨块保持）+ DoP 打包残样 ----
            std::vector<std::unique_ptr<rta::dsp::SdmModulator>> mods;
            rta::dsp::DopPackState dopSt;
            std::vector<std::vector<double>> carry;
            if (dop) {
                rta::dsp::SdmConfig mcfg;
                mcfg.fs = (double)dsdRate;
                mcfg.family = rta::dsp::parse_modulator_family(p.modFamily);
                mcfg.levels = 2;                 // 1-bit (DoP)
                mcfg.order = rta::dsp::stable_sdm_order(p.modOrder > 0 ? p.modOrder : 5, mcfg.fs, mcfg.levels, mcfg.family);
                // F-5 自证：**生效阶数**如实上报（261025-02 #5 口径）。
                // stable_sdm_order 会按位率/族把 7 阶降到 5 阶（1-bit 下 7 阶 Chebyshev NTF
                // 极点阻尼比过低会极限环失稳）；若这里不覆盖，/api/status 永远显示用户填的 7，
                // "我选了 EC-7 声音不对"就永远无法从数据上证伪。
                {
                    const int effOrder = (int)mcfg.order;
                    const int reqOrder = p.modOrder > 0 ? p.modOrder : 5;
                    std::string why;
                    if (effOrder != reqOrder) {
                        why = "调制器阶数由 " + std::to_string(reqOrder) + " 阶降为 " +
                              std::to_string(effOrder) + " 阶（" + std::to_string(dsdRate) +
                              " Hz 1-bit 下高阶 NTF 不稳定，自动降阶保护）";
                    }
                    set_out_format_state(out_mode_of_backend(p.backend).c_str(),
                                         p.dsd, dsdRate, deviceRate,
                                         p.modFamily.empty() ? std::string("dsd") : p.modFamily,
                                         effOrder, why);
                }
                mcfg.cutoffHz = (p.modCutoff > 0.0) ? (p.modCutoff * 1000.0) : 100000.0;
                // 默认 0.0005：1-bit 的量化步长是 2.0，旧默认 0.01 等于注入 -34 dBFS 白噪，
                // 实测把 DSD64 的带内 SNR 从 89 dB 砍到 54 dB（听感：持续嘶声）。
                mcfg.ditherLsb = (p.modDither >= 0.0) ? p.modDither : 0.0005;
                for (int c = 0; c < outCh; ++c) mods.push_back(std::make_unique<rta::dsp::SdmModulator>(mcfg));
                carry.assign((size_t)outCh, {});
            }
            try {
                for (;;) {
                    if (RQ.abort.load()) break;
                    const long long sf = RQ.seekFrame.exchange(-1);
                    if (sf >= 0) {
                        // sf 是区间内的帧号（0 = 本轨开头）⟹ 先夹到 srcCount，再加 srcBase
                        size_t rel = (size_t)sf;
                        if (rel > srcCount) rel = srcCount;
                        const size_t target  = srcBase + rel;
                        const size_t preroll = std::min<size_t>(rel, (size_t)(0.5 * (double)in.rate));
                        pos = target - preroll;
                        skipOut = (size_t)((double)preroll * (double)outRate / (double)in.rate + 0.5);
                        // 清空滤波历史（不是重建管线：重建要重新设计 26 万抽头滤波器，秒级卡顿）
                        pl->seek_reset();

                        { std::lock_guard<std::mutex> lk(RQ.mtx); RQ.q.clear(); }
                        myEpoch = RQ.epoch.load();
                        RQ.cv.notify_all();
                    }
                    if (pos >= segEnd) break;
                    const size_t n = std::min(kChunk, segEnd - pos);
                    rta::audio::AudioBuffer c;
                    // ★ 流式：向源要这一块（整曲路径下与旧代码逐字节相同）
                    const size_t gotFrames = src.read(pos, n, c);
                    pos += gotFrames;
                    if (gotFrames == 0) break;
                    const auto t_dsp_0 = std::chrono::steady_clock::now();
                    // 2026-10-24（用户 261024-04 #8）：把 PipelineStats 收下来，才能回答
                    // 「本次卷积到底走没走 GPU」—— 旧代码传 nullptr，这个事实被直接丢掉，
                    // 于是 /api/signal 的 irGpu 只能是"用户勾了开关"（设置项），不是实测。
                    eng::PipelineStats pst;
                    rta::audio::AudioBuffer o = pl->process(c, &pst);
                    if (blocksDone++ == 0) {
                        // 首块成本 = 重采样器设计（26 万抽头）+ 一块 DSP。这是"起播延迟"里
                        // 除解码/扫描之外的第三项，必须能单独量出来（2026-10-25 大文件卡死取证）。
                        char b[200];
                        std::snprintf(b, sizeof(b), "prepareMs=%.0f coeffMb=%.1f outFrames=%zu",
                                      pst.prepareMs, (double)pst.coeffBytes / (1024.0 * 1024.0), o.frames());
                        play_log(mem_line("dsp-first-block", b));
                    }
                    if (pst.usedGpuConvolution) ps.gpuConvUsed.store(true);
                    if (!RQ.gpu.load()) RQ.gpu.store(pl->gpuResampleActive());
                    if (skipOut > 0 && !o.raw.empty()) {
                        const size_t d = std::min(skipOut, o.frames());
                        o.raw.erase(o.raw.begin(), o.raw.begin() + (long long)(d * (size_t)o.channels));
                        skipOut -= d;
                    }
                    // ---- DSD：PCM(DSD 速率) -> 1-bit -> DoP 24-bit 载波 ----
                    if (dop && !o.raw.empty()) {
                        const size_t n = o.frames();
                        std::vector<std::vector<double>> sd((size_t)outCh);
                        for (int c = 0; c < outCh; ++c) {
                            auto& v = sd[(size_t)c];
                            v = carry[(size_t)c];                    // 接着上一块的残余
                            v.reserve(v.size() + n);
                            for (size_t i = 0; i < n; ++i) v.push_back(mods[(size_t)c]->process(o.sample(i, c)));
                        }
                        const size_t total = sd[0].size();
                        const size_t use = (total / 16) * 16;        // 只打包整数个 DoP 帧
                        std::vector<const double*> sp;
                        for (auto& v : sd) sp.push_back(v.data());
                        std::vector<int32_t> packed;
                        rta::dsp::dop_pack(sp.data(), outCh, use, packed, dopSt);
                        for (int c = 0; c < outCh; ++c)
                            carry[(size_t)c].assign(sd[(size_t)c].begin() + (long long)use, sd[(size_t)c].end());
                        rta::audio::AudioBuffer nb;
                        nb.rate = deviceRate; nb.channels = outCh; nb.bits = 24; nb.isFloat = false;
                        nb.raw = std::move(packed);
                        o = std::move(nb);
                    }
                    const auto t_dsp_1 = std::chrono::steady_clock::now();
                    const long long dsp_us = std::chrono::duration_cast<std::chrono::microseconds>(t_dsp_1 - t_dsp_0).count();
                    ps.dspChunkUs.store(dsp_us);
                    ps.dspTotalUs.fetch_add(dsp_us, std::memory_order_relaxed);
                    ps.dspChunks.fetch_add(1, std::memory_order_relaxed);
                    if (o.raw.empty()) continue;
                    {
                        std::unique_lock<std::mutex> lk(RQ.mtx);
                        RQ.cv.wait(lk, [&] { return RQ.q.size() < RQ.cap || RQ.abort.load(); });
                        if (RQ.abort.load()) break;
                        RQ.q.emplace_back(std::move(o), myEpoch);
                    }
                    RQ.cv.notify_all();
                }
            } catch (const std::exception& e) {
                std::lock_guard<std::mutex> lk(RQ.mtx); RQ.err = e.what(); RQ.error = true;
            } catch (...) {
                std::lock_guard<std::mutex> lk(RQ.mtx); RQ.err = "未知异常"; RQ.error = true;
            }
            { std::lock_guard<std::mutex> lk(RQ.mtx); RQ.done = true; }
            RQ.cv.notify_all();
        });

        // 必须等第一块数据就绪再开流。实测踩到的坑：WASAPI 独占事件驱动在 Start 之后
        // 迟迟拿不到数据，驱动会判定欠载、此后【停止发事件】，GetBuffer 一直失败，
        // 表现为「播放中但一直停在 0 秒」。旧版之所以没这个问题，是因为它先把整曲处理完
        // 才 open/start —— 那份缓冲本身就是"预填充"。
        {
            std::unique_lock<std::mutex> lk(RQ.mtx);
            RQ.cv.wait_for(lk, std::chrono::seconds(15),
                           [&] { return !RQ.q.empty() || RQ.done || RQ.abort.load(); });
            if (RQ.q.empty()) {
                RQ.abort.store(true); RQ.cv.notify_all(); prod.join();
                // 归因（本轮补）：首块 15 秒未产出发生在【输出设备打开之前】，
                // 与音频设备无关 —— 解码、滤波器设计（大抽头数）、CPU 过载都会导致。
                const std::string msg = RQ.err.empty()
                    ? "渲染线程未产出数据（解码/DSP 管线 15 秒无首块输出；尚未到输出设备环节，"
                      "与音频设备无关。文件过大、滤波器抽头过多或 CPU 过载都会导致）"
                    : ("渲染失败: " + RQ.err);
                play_log("NORENDER kind=producer-first-block " + msg + " file=" + file);
                std::lock_guard<std::mutex> lk2(ps.mtx);
                ps.error = msg;
                return false;
            }
        }

        // 输出后端：独占 / 共享 / NAA / Null，由 make_sink 决定（pEff：可能已回退默认端点）
        auto sink = make_sink(pEff);
        if (!sink->open(sink_opts(pEff), deviceRate, outCh, outBits)) {
            RQ.abort.store(true); RQ.cv.notify_all(); prod.join();
            std::lock_guard<std::mutex> lk(ps.mtx);
            std::string msg = "打开输出后端失败: " + sink->last_error();
            // HF-01/02：open 失败把第一刀的 OpenFail（请求格式/支持列表/HRESULT/端点 id）拼进错误，
            // 不再只剩一句 UNSUPPORTED_FORMAT。
            if (!note.text.empty()) msg += "；note=" + note.text;
            ps.error = msg;
            return false;
        }
        ActiveSinkGuard sinkGuard(sink.get(), dop);
        // 2026-10-23 真机 DEBUG：打开成功也要如实带出「驱动实际接受的是哪种独占格式」。
        // 之前这句只有失败时才有，成功时用户只看到"32-bit"，根本不知道内部是紧凑24还是32容器，
        // 1.3.x「能播/不能播」的原因因此全靠猜（本机是紧凑24、UltraLite 是32容器/24有效）。

        // 2026-10-25（音量语义）：基准恒为 0.0 dB，起播初始增益直接调 set_live_gain_db(p.volume)！
        // render_loop 之后每 tick 传入的 delta（volDb - startDb）恒等于用户当前请求的绝对音量 volDb。
        if (auto* ca = dynamic_cast<CoreAudioSink*>(sink.get())) {
            ca->set_base_gain_db(0.0);
            ca->set_live_gain_db(p.volume);
        }
        if (!sink->start()) {
            RQ.abort.store(true); RQ.cv.notify_all(); prod.join();
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error = "启动输出失败: " + sink->last_error();
            return false;
        }

        // ---- C1/C2：缓冲策略落定后记录「请求 / 实际 / 配方」（方案 §5.4）----
        // 为什么不是塞进上面的 PLAY 行：PLAY 在 open 之前就写出去了（信号链要先落盘，
        // 而设备必须等首块数据就绪才打开），那时还不知道实际缓冲。这里单独一条 PLAYBUF，
        // 字段名与方案 §5.4 一致，日志检索方便。

        // ---------------- 渲染主循环（实现在 src/audio/render_loop.h，与回归测试共用）----------------
        // 2026-10-22 事故（VM 上独占流 GetCurrentPadding 恒满 → write_available 恒 0 →
        // 200 次超时静默 break → END pos=0 error=""）之后，循环内的超时 break 带 RENDERFAIL
        // 遥测（w0/wr、last_pad、缓冲帧数、GetBuffer HRESULT、设备名/id、处置建议）。
        rta::render::RenderHost rl;
        rl.stop = &ps.stop; rl.pauseReq = &ps.pauseReq; rl.paused = &ps.paused;
        rl.seekReq = &ps.seekReq; rl.played = &ps.played;
        rl.volDb = &ps.volDb; rl.startDb = &ps.startDb; rl.dbgPad = &ps.dbgPad; rl.gpuOut = &ps.gpu;
        rl.rq = &RQ;
        rl.deviceRate = deviceRate; rl.outBits = outBits; rl.outCh = outCh;
        // inFrames/totalOut 必须是**本区间**的：render_loop 的 seek 用 inFrames 算 seekFrame，
        // 用 totalOut 换算 played 比例 —— 这两个数一旦还是整轨的，跳转就会落到文件别处。
        rl.inRate = in.rate; rl.inFrames = srcCount; rl.totalOut = totalOut;
        rl.dbgW0 = &g_dbgW0; rl.dbgWr = &g_dbgWr; rl.dbgPulls = &g_dbgPulls;
        rl.dbgClip = &g_dbgClip; rl.dbgPeak = &g_dbgPeak;
        // C2 遥测导出（/api/status 用；STAT 行本身由 render_loop 直接打印）
        rl.dbgDry = &g_dbgDry; rl.dbgDryMs = &g_dbgDryMs;
        rl.dbgEv = &g_dbgEv; rl.dbgEvInt = &g_dbgEvInt; rl.dbgProd = &g_dbgProd;
        // C1 L2 起播看门狗：8 秒太慢、4 秒 RENDERFAIL 会触发「回退共享 + 从头重播」，
        // 所以 0.8 秒零写入就重开 20ms（只对 WASAPI 独占有意义，其它后端不设这个钩子）。
        // macOS 扩展诊断：RENDERFAIL 时带出 CoreAudio 设备侧实测（render_loop 是共享代码，
        // 平台细节经钩子注入 —— Windows 侧不设钩子，日志逐字节不变）
        rl.extraDiag = [&sink]() -> std::string {
            if (auto* ca = dynamic_cast<CoreAudioSink*>(sink.get())) {
                return "coreaudio_rendered=" + std::to_string(ca->frames_rendered()) +
                       " underruns=" + std::to_string(ca->underruns()) +
                       " bp=" + (ca->bit_perfect() ? "1" : "0");
            }
            return std::string();
        };
        rl.log = [](const std::string& s) { play_log(s); };
        rl.dlogFn = [](const std::string& s) { dlog(s); };
        rl.deviceLabel = dev;
        rl.deviceIdDesc = devId;
        rl.onShared = (p.backend == "wasapi-shared");
        // 只有「默认走 WASAPI 独占」的普通 PCM 播放才允许自动回退共享；
        // DoP/DSD 绝不回退（共享会重采样破坏 DoP 载波），NAA/Null 与共享本身无关。
        rl.fallbackEligible = (sharedFallback != nullptr) && !dop &&
                              (p.backend.empty() || p.backend == "wasapi");
        rl.dop = dop;
        rta::render::render_loop(*sink, rl);

        RQ.abort.store(true); RQ.cv.notify_all();
        if (prod.joinable()) prod.join();
        if (rl.renderFail) {
            // 设备持续不接受数据：完整归因原样进 ps.error —— END 不再是 error="" 悬案
            // C3（N300 掉线）：端点已消失时绝不回退共享、也不从头重播 —— 用户要 bit-perfect，
            // 静默降级比报错更有害（方案 §7）。ps.error 已在 render_loop 里写成「输出设备已断开」。
            if (sharedFallback && rl.fallbackEligible && !rl.deviceLost) *sharedFallback = true;
            g_activeSink.store(nullptr); g_activeDop.store(false);
            sink->close();
            { std::lock_guard<std::mutex> lk(ps.mtx); ps.error = rl.failMsg; }
            return false;
        }
        ps.paused.store(false);
        std::this_thread::sleep_for(std::chrono::milliseconds(std::max(10, p.bufferMs)));      // 让设备把缓冲里的尾音放完（RENDERFAIL 路径已提前 return，不睡）
        g_activeSink.store(nullptr); g_activeDop.store(false);
        sink->close();
        if (rl.normalEnd) {
            // 显式「正常结束」语义：此后 END 的 error="" 只可能是正常播完（有 RENDER_DONE 为证）
            play_log("RENDER_DONE 正常播完 pos=" +
                     std::to_string((double)ps.played.load() / (double)deviceRate) + "s");
        } else if (ps.stop.load()) {
            play_log("RENDER_STOP 停止/切歌 pos=" +
                     std::to_string((double)ps.played.load() / (double)deviceRate) + "s");
        }
        if (!RQ.err.empty()) { std::lock_guard<std::mutex> lk(ps.mtx); ps.error = "渲染失败: " + RQ.err; }
        // error 非空 = 非正常退出（生产者异常等），绝不能当"正常播完"返回 true
        //（否则队列线程会静默续播下一曲，把故障掩盖成正常切歌）。
        return !ps.stop.load() && ps.error.empty();
    } catch (const std::exception& e) {
        std::lock_guard<std::mutex> lk(ps.mtx);
        ps.error = std::string("异常: ") + e.what();
    } catch (...) {
        std::lock_guard<std::mutex> lk(ps.mtx);
        ps.error = "未知异常";
    }
    return false;
}

// ---------------- 播放入口（独占 RENDERFAIL 自动回退共享）----------------
// 2026-10-22 VM 事故的落地修复：独占流开得出来但设备 4 秒不接受数据时，
// 以 wasapi-shared 重开整条 play_one（设备率取系统混音率、shaper=None、note 明示
// 已回退非 bit-perfect）；共享也失败才最终报错。DoP/DSD 不回退（impl 已把关）。
static bool play_one(const std::string& file, const PlayParams& p, rta::audio::AudioBuffer& buf) {
    auto& ps = g_ps;
    bool sharedFallback = false;
    const bool ok = play_one_impl(file, p, buf, &sharedFallback, std::string());
    if (ok || !sharedFallback) return ok;
    if (ps.stop.load()) return false;   // 用户已停止：不要再重开一遍

    PlayParams p2 = p;
    p2.backend = "wasapi-shared";
    p2.shaper = "none";                 // 共享模式不追求 bit-perfect，关掉抖动整形
    play_log("FALLBACK_SHARED 独占流无响应,回退 WASAPI 共享(非 bit-perfect) file=" + file);
    { std::lock_guard<std::mutex> lk(ps.mtx); ps.error.clear(); }
    ps.played.store(0);
    return play_one_impl(file, p2, buf, nullptr,
                         "独占流无响应,已回退 WASAPI 共享(非 bit-perfect)");
}

// ---------------- 播放队列 ----------------

// 队列项：路径 + 可选 CUE 分轨区间（秒）。
// 为什么队列项必须自带区间：cue 把整轨展开成 N 首，这 N 条的 **path 完全相同**，
// 只按路径排队的话「下一首 / 点队列项 / 单曲循环」都会退化成「整个文件从头播」
//（这正是本轮要修的那个 bug 在队列侧的翻版）。
struct QItem {
    std::string path;
    double      cs = -1.0;   // CUE 起点（秒）；<0 = 整首
    double      ce = -1.0;   // CUE 终点（秒）；<0 = 文件末尾
    QItem() {}
    QItem(std::string p, double a = -1.0, double b = -1.0)
        : path(std::move(p)), cs(a), ce(b) {}
    bool isCue() const { return cs >= 0.0; }
    // 同一首的判定：路径 + 区间都要相等（同一 path 的不同 cue 轨是不同曲目）
    bool same(const QItem& o) const {
        if (path != o.path) return false;
        if (isCue() != o.isCue()) return false;
        if (!isCue()) return true;
        return std::fabs(cs - o.cs) < 0.001 && std::fabs(ce - o.ce) < 0.001;
    }
};

// 库里的一条曲目 → 播放侧区间（秒）。非 cue 曲目返回 false（cs/ce 不动）。
// 唯一口径来源是 library.h 的 lib_cue_range_sec（本文件不重算，避免两套算法漂移）。
static bool lib_track_cue_sec(const rta::net::LibTrack& t, double& cs, double& ce) {
    return rta::net::lib_cue_range_sec(t, cs, ce);
}

// 2026-10-27（R-4）：播放模式收敛成**单一真相源** mode ∈ {0,1,2,3}。
//
// 为什么必须收敛：原来 `repeat`(0/1/2) 与 `shuffle`(on/off) 是**两个独立字段**，
// 它们组合出 6 种状态，但用户心智里只有 4 种（顺序 / 列表循环 / 单曲循环 / 随机）。
// 两套真相的直接后果：前端按钮只能表达 3 态、`repeat=1 + shuffle=true` 这种组合
// 到底算"列表循环"还是"随机"没有定义，播放推进逻辑里两处 if 各判各的。
//
// 现在的模型（与上游 /api/playmode 一致）：
//   0 = 顺序（播到末尾停）
//   1 = 列表循环（末尾回到第 1 首）
//   2 = 单曲循环（原地重播）
//   3 = 随机（不重复当前曲）
//
// ⚠️ 向后兼容：`/api/repeat` 与 `/api/shuffle` 仍然工作，但它们**不再有独立存储**，
//    而是 mode 的派生写入口（repeat=2 ⟹ mode=2；shuffle=on ⟹ mode=3；shuffle=off ⟹ mode=0）。
//    读的时候由 mode 反推。这样"两处真相打架"在结构上不可能发生。
struct QueueState {
    std::mutex mtx;
    std::vector<QItem> items;
    size_t index = 0;
    int    mode = 0;        // 0=顺序 1=列表循环 2=单曲循环 3=随机（唯一真相源）
    std::vector<QItem> base;   // 随机前的原始顺序（关掉随机时还原）
    std::vector<QItem> sortBase; // 排序前的原始顺序（恢复默认顺序用）

    // ---- 派生访问器：给既有代码用，语义与旧字段一一对应 ----
    // repeat：0=关 1=列表循环 2=单曲循环。随机模式下 repeat 视为 0（随机不循环）。
    int  repeat_of() const { return (mode == 1) ? 1 : (mode == 2) ? 2 : 0; }
    bool shuffle_of() const { return mode == 3; }
};
static QueueState g_q;

// ---- 队列项的一行文本 → QItem（queue_load 与具名保存队列/整列替换共用）----
static QItem item_from_line(const std::string& rest) {
    const size_t t1 = rest.find('\t');
    if (t1 == std::string::npos) return QItem(rest);
    QItem it;
    it.path = rest.substr(0, t1);
    const size_t t2 = rest.find('\t', t1 + 1);
    it.cs = std::atof(rest.c_str() + t1 + 1);
    if (t2 != std::string::npos) it.ce = std::atof(rest.c_str() + t2 + 1);
    return it;
}

static size_t queue_reindex_locked(const QItem& cur) {
    if (!cur.path.empty()) {
        for (size_t i = 0; i < g_q.items.size(); ++i) {
            if (g_q.items[i].same(cur)) { g_q.index = i; break; }
        }
    }
    if (g_q.index >= g_q.items.size()) g_q.index = g_q.items.empty() ? 0 : g_q.items.size() - 1;
    return g_q.index;
}
// ---- 队列持久化：重启后仍保留播放列表 ----
static std::string queue_file() {
    // 2026-10-25（默认目录纠正）：播放队列是运行期状态，不许写进应用包。
    return path_in_exe_dir("rlplayer-playlist.txt");
}

// ---- 运行期状态文件（配置 / 日志 / 缓存）的落盘位置 ----
//
// 2026-10-25（默认目录纠正，重要）：
//   原实现 `path_in_exe_dir(name)` 把**所有**运行期文件都写在可执行文件同目录。
//   在 Windows 便携版上这是合理设计（拷走整个目录就带走配置），但在 macOS 上：
//     * 独立 CLI（build-mac/rtaweb）跑在仓库里 —— 还行；
//     * **RLPlayer.app** 的可执行文件在 Contents/MacOS/ —— 应用包是只读签名体，
//       `codesign` 之后（尤其公证/正式签名）往里写会失败或被 Gatekeeper 拒绝；
//       即使 ad-hoc 签名下能写，配置也会随 .app 被替换/升级而丢失。
//   证据：dist-mac/RLPlayer.app/Contents/MacOS/data/opra_index.json ——
//   配置确实被写进了应用包。
//
//   正确做法（macOS 规范）：配置/日志/缓存落 ~/Library/Application Support/RLPlayer
//   （platform::config_dir_utf8() / data_dir_utf8()，path_posix.h 已实现）。
//   只有在 config_dir 不可用（极端环境）时才退回 exe 目录，保持便携语义的兜底。
//
// 命名保留 path_in_exe_dir 以减小改动面，但语义已变为「运行期状态文件目录」。
// 需要"真的在 exe 旁边"的东西（例如 ffmpeg/ffprobe 的定位）不走这个函数。
static const std::string& runtime_state_dir() {
    static const std::string dir = [] {
        // 2026-10-26（debug/20261026-02 事故后加）：允许用 RLPLAYER_STATE_DIR 重定向整个状态目录。
        // 为什么必须加：本函数决定 settings.conf / 索引 / covercache / uploads 的落点，而它**硬编码**
        // 到 ~/Library/Application Support/RLPlayer，没有任何覆盖手段。后果是**任何**起实例做端点
        // 测试的动作都会写用户的真实配置 —— 本轮做预设测试时就这样污染过用户 rlplayer-settings.conf
        // 两次（rate/filter/shaper/isp 被改），只能靠事前备份还原。
        // 有了这个变量，测试只需 RLPLAYER_STATE_DIR=/tmp/xxx 就能完全隔离，不必再备份/还原。
        // 语义与既有 RLPLAYER_LIBRARY_DIR（只改库数据）不同：本变量改的是**整个**状态目录。
        // 空值 = 不覆盖，行为与以前完全一致（用户实例不受影响）。
        if (const char* env = std::getenv("RLPLAYER_STATE_DIR")) {
            if (*env) {
                std::string s(env);
                while (!s.empty() && (s.back() == '\\' || s.back() == '/')) s.pop_back();
                if (!s.empty()) return s;
            }
        }
        const std::string cfg = rta::platform::config_dir_utf8();
        if (!cfg.empty()) return cfg;
        return rta::platform::module_dir_utf8();
    }();
    return dir;
}

// 老用户数据迁移（2026-10-25，与「落点改为 config_dir」配套；缺了它等于把用户配置丢掉）。
//
// 背景：本轮之前所有运行期文件都写在 exe 目录。现在新落点是 config_dir，
// 老用户的配置仍躺在旧位置 —— 不搬的话，升级后启动读不到 settings/library/PEQ/收藏，
// 用户看到的就是「我的设置和曲库全没了」。
//
// 迁移策略（保守，绝不覆盖、绝不删）：
//   * 只搬「新位置不存在」且「旧位置存在」的项 —— 新位置已有说明用户已在新版本写过，不动；
//   * **不删旧文件**（留作回滚；磁盘代价可接受）；
//   * 逐项搬，任一失败不影响其它（失败只跳过，不阻塞启动）；
//   * exe 目录 == config_dir 时不搬（便携兜底场景本来就是同一处）。
//
// 注意：**不要**搬 data/opra_index.json 之类只读资源 —— 那是随包分发的安装产物，
// 由 make_app_mac.sh 复制，不属于用户状态。这里只列用户状态文件。
static void migrate_legacy_state_files() {
    const std::string newDir = runtime_state_dir();
    const std::string oldDir = rta::platform::module_dir_utf8();
    if (newDir.empty() || oldDir.empty() || newDir == oldDir) return;

    // 2026-10-25（用户报「改完文件夹重启又回归」的第二个根因，实测已复现）：
    // 开发机上 exe 目录是 build-mac/ —— 那里残留的旧配置会被当成「老用户数据」搬进
    // 正式配置目录，把用户刚改的设置**覆盖回去**。日志里抓到过：
    //   MIGRATE 旧位置 → config_dir：3 项；from=/Users/august/Downloads/DQ/RLPlayer/build-mac
    // 而且每次重新编译，build-mac 里又会产生新的旧文件 ⟹ 用户感觉「一直在被重置」。
    //
    // 判据：**只有"看起来像正式安装目录"才做迁移**。开发构建目录一律跳过：
    //   * 路径里含 /build（build、build-mac、build-*）
    //   * 路径以 /Debug 或 /Release 结尾（Xcode 产物）
    //   * 可执行文件同目录存在 CMakeCache.txt（CMake 构建树的铁证）
    // 跳过迁移不影响功能：正式 .app 的 module_dir 是 .../Contents/MacOS，不会被这些规则命中。
    {
        std::string od = oldDir;
        for (char& ch : od) ch = (char)std::tolower((unsigned char)ch);
        const bool isBuildDir =
            od.find("/build") != std::string::npos ||
            (od.size() >= 8 && od.compare(od.size() - 8, 8, "/release") == 0) ||
            (od.size() >= 6 && od.compare(od.size() - 6, 6, "/debug") == 0) ||
            std::ifstream(oldDir + "/CMakeCache.txt").good();
        if (isBuildDir) {
            // 只记一次日志，避免每次启动刷屏
            static bool warned = false;
            if (!warned) {
                warned = true;
                play_log("MIGRATE 跳过：exe 目录是开发构建目录（" + oldDir +
                         "），不搬它的配置以免覆盖用户设置");
            }
            return;
        }
    }

    // 注意：rlplayer-library.conf / rlplayer-index.tsv 在非默认实例上带 ".p<port>" 后缀
    // （Library::confLeaf）。这里用前缀扫描把带后缀的一并搬，否则多实例的老索引读不到。
    static const char* kFiles[] = {
        "rlplayer-settings.conf", "rlplayer-library.conf", "rlplayer-index.tsv",
        "rlplayer-playlist.txt", "rlplayer-favs.json", "rlplayer-recent.txt",
        "rlplayer-peq.txt", "rlplayer-peq-presets.txt", "rlplayer-sources.conf",
        "rlplayer-llm.conf", "rlplayer-playback.log", "launcher.log",
    };
    // 带实例后缀的家族：前缀匹配 + 原样搬（含 .p<port> 变体）
    static const char* kPrefixes[] = {
        "rlplayer-library.conf", "rlplayer-index.tsv",
    };
    static const char* kDirs[] = { "rlplayer-meta", "recordings", "playlists", "uploads" };

    std::error_code ec;
    int moved = 0;
    for (const char* n : kFiles) {
        const std::string from = oldDir + "/" + n;
        const std::string to   = newDir + "/" + n;
        if (!fs::exists(fs::u8path(from), ec) || ec) { ec.clear(); continue; }
        if (fs::exists(fs::u8path(to), ec) && !ec) { ec.clear(); continue; }   // 新位置已有 → 不动
        ec.clear();
        fs::copy_file(fs::u8path(from), fs::u8path(to),
                      fs::copy_options::overwrite_existing, ec);
        if (!ec) ++moved;
        ec.clear();
    }
    // 前缀家族（含 .p<port> 变体）
    for (const char* pre : kPrefixes) {
        const std::string prefix(pre);
        for (auto& e : fs::directory_iterator(fs::u8path(oldDir),
                 fs::directory_options::skip_permission_denied, ec)) {
            if (ec) { ec.clear(); break; }
            const std::string nm = pathToUtf8(e.path().filename());
            if (nm.size() < prefix.size() || nm.compare(0, prefix.size(), prefix) != 0) continue;
            const std::string to = newDir + "/" + nm;
            if (fs::exists(fs::u8path(to), ec) && !ec) { ec.clear(); continue; }
            ec.clear();
            fs::copy_file(e.path(), fs::u8path(to), fs::copy_options::overwrite_existing, ec);
            if (!ec) ++moved;
            ec.clear();
        }
    }
    for (const char* n : kDirs) {
        const std::string from = oldDir + "/" + n;
        const std::string to   = newDir + "/" + n;
        if (!fs::is_directory(fs::u8path(from), ec) || ec) { ec.clear(); continue; }
        if (fs::exists(fs::u8path(to), ec) && !ec) { ec.clear(); continue; }
        ec.clear();
        fs::copy(fs::u8path(from), fs::u8path(to),
                 fs::copy_options::recursive | fs::copy_options::skip_existing, ec);
        if (!ec) ++moved;
        ec.clear();
    }
    if (moved > 0)
        play_log("MIGRATE 旧位置 → config_dir：" + std::to_string(moved) +
                 " 项（旧文件保留未删，可回滚）；from=" + oldDir + " to=" + newDir);
}

static std::string path_in_exe_dir(const char* name) {
    const std::string& base = runtime_state_dir();
    return (name && *name) ? (base + "/" + name) : base;
}
static std::string path_in_exe_dir(const std::string& name) { return path_in_exe_dir(name.c_str()); }

// ================== 专辑封面在线抓取（2026-10-26，上游 c41ce97 的 mac 重做）==================
// 需求：库内嵌封面覆盖率有限，"缺图的专辑永远空白"。按「专辑名 + 艺术家」去网易云搜专辑
// （type=10）拿 picUrl，下载后缓存到磁盘。
//
// 端点契约：
//   GET  /api/lib/cover?k=<专辑键>   **只读、零网络**（只 stat / 读磁盘）
//        ① 内嵌/同目录图（沿用 albumCover 的现有逻辑 + 多曲重试 + 负缓存）
//        ② <coverdir>/<key>.jpg（网图/人工设置的正缓存）
//        ③ <coverdir>/<key>.none（负缓存，7 天有效）
//        三者都没有 → 404 + 空 body（前端 <img onerror> 露回首字母占位）
//   GET  /api/lib/cover/progress      **只读**：{"ok":true,"running":bool,"done","total",
//                                     "hit","miss","fail","lastName"}
//   POST /api/lib/cover/prefetch      **副作用端点**（进 kNeedPost）：立刻返回
//        {"ok":true,"queued":N,"candidates":N,"running":true}，网络全部丢到后台线程
//        · 不给 k：库里所有「内嵌无封面且无缓存」的专辑
//        · 给 k（逗号/换行分隔）：只抓这几张（UI 打开专辑页时可单点预热）
//        上一轮还在跑 ⟹ {"ok":true,"queued":0,"running":false}（不排队，前端下次再试）
//   POST /api/lib/cover/set?k=<16位十六进制>  body = 图片原始字节（人工补封面）
//
// ★ 为什么绝不能在请求线程里发网络：一次网易搜索 3 s、一张专辑 6 s；放进请求线程
//   就把整站（含 /api/ping 与静态页）全部排队 —— 这正是"封面页卡死"的老病根。
//
// ★ mac 与上游的四处**故意改写**（本段是移植的核心价值，别退回 Windows 写法）：
//   ① 缓存目录：上游 `<exe>\covercache\`（便携版语义）；mac 用 runtime_state_dir()/covercache
//      —— .app 内是只读签名区，写进去在正式签名后必失败。额外支持 RLPLAYER_COVER_DIR
//      覆盖，让测试指向干净的临时目录（不受历史缓存干扰）。
//   ② 原子改名：上游先试 MoveFileExW、失败再 rename；mac 没有 MoveFileExW，
//      直接「先写 .part，再 std::filesystem::rename」（同卷 rename 本身原子）。
//   ③ 网络：上游 WinHTTP；mac 走已有的 rta::net::http_get/http_post（platform/http.h 封装）。
//   ④ 路径：上游 widen() 宽字符；mac 的 widen() 是**保序恒等**，fs::path(wstring) 对中文
//      路径直接抛 "locale not supported"（已实测）⟹ 一律 std::filesystem::u8path。
//   ⑤ 目录穿越防护（?k= 白名单）：与平台无关，照做（见 tools/cover_fetch.h 的 cover_key_slug）。
//
// 缓存布局（用户可直接删掉重来）：
//   <coverdir>/<key>.jpg        正缓存（永久，直到用户手动删）
//   <coverdir>/<key>.jpg.part   写入中（rename 前；读侧永远看不到半张图）
//   <coverdir>/<key>.none       负缓存（空文件；mtime 超过 7 天即视为过期，可再抓一次）
// 只有「服务器明确答复没有」才写 .none；断网/超时/异常（HTTP status==0）**不写** ——
//   否则一次离线运行就把 7 天负缓存全污染成"没有封面"，用户联网后再也看不到图。
//   （瞬态失败只计数 fail，下一轮 prefetch 会重试。）
//
// 兜底开关：环境变量 RLPLAYER_COVER_HOST（scheme://host）可把搜索请求指到别处
//   （自动化测试用不可达地址验证「断网不崩、不污染负缓存」）。
// RLPLAYER_COVER_DIR 覆盖缓存目录；两者都为空 = 默认行为。

// 缓存目录：只解析一次（列表端点每张专辑都会问）
static const std::string& cover_cache_dir() {
    static const std::string d = [] {
        // 测试/多实例隔离优先（与 RLPLAYER_STATE_DIR 同风格）：空值 = 不覆盖。
        if (const char* env = std::getenv("RLPLAYER_COVER_DIR")) {
            if (*env) {
                std::string s(env);
                while (!s.empty() && (s.back() == '\\' || s.back() == '/')) s.pop_back();
                if (!s.empty()) return s;
            }
        }
        // mac 口径：放运行期状态目录（~/Library/Application Support/RLPlayer/covercache），
        // 绝不放进 .app 包内 —— 那是只读签名区，正式签名/公证后写入必失败。
        return path_in_exe_dir("covercache");
    }();
    return d;
}

// 封面抓取的**纯逻辑**全部在 tools/cover_fetch.h（可离线单测：目录穿越/Dice/图片头/负缓存过期）。
// 这里只做平台接线：目录注入、HTTP、后台线程、路由。
static rta::cover::CoverPaths cover_paths(const std::string& key) {
    return rta::cover::cover_paths_in(cover_cache_dir(), key);
}
static bool cover_has_disk(const std::string& key) {
    return rta::cover::cover_has_disk_in(cover_cache_dir(), key);
}
static bool cover_read_cached(const std::string& key, std::vector<unsigned char>& out) {
    return rta::cover::cover_read_cached_in(cover_cache_dir(), key, out);
}
static bool cover_neg_fresh(const std::string& key) {
    return rta::cover::cover_neg_fresh_in(cover_cache_dir(), key);
}
static const char* cover_mime_of(const std::vector<unsigned char>& b) {
    return rta::cover::cover_mime_of(b);
}

static std::string cover_env_host() {
    const char* v = std::getenv("RLPLAYER_COVER_HOST");
    std::string host = v ? std::string(v) : std::string();
    while (!host.empty() && (host.back() == ' ' || host.back() == '/')) host.pop_back();
    return host;                              // 空 = 用网易官方域名
}

// 落盘正缓存：先写 .part，再 rename（同卷原子）。
// 返回空串 = 成功；非空 = 人话原因。
static std::string cover_write_atomic(const std::string& key, const std::vector<unsigned char>& body) {
    const rta::cover::CoverPaths pp = cover_paths(key);
    std::error_code ec;
    fs::create_directories(fs::u8path(pp.dir), ec);
    {
        std::ofstream f(fs::u8path(pp.part), std::ios::binary | std::ios::trunc);
        if (!f) return "无法写入 covercache（目录/权限？）";
        f.write(reinterpret_cast<const char*>(body.data()), (std::streamsize)body.size());
        f.flush();
        if (!f) return "covercache 写入失败（磁盘满？）";
    }
    // POSIX 上 rename(2) 同卷替换是原子的；fs::rename 在目标存在时也直接替换
    // （与 Windows 不同，POSIX 不需要 MOVEFILE_REPLACE_EXISTING）。
    std::error_code em;
    fs::rename(fs::u8path(pp.part), fs::u8path(pp.jpg), em);
    if (em) { std::error_code e2; fs::remove(fs::u8path(pp.part), e2); return "改名失败：" + em.message(); }
    std::error_code el;
    fs::remove(fs::u8path(pp.none), el);       // 有图了，旧负缓存作废
    return std::string();
}

// 一张待抓的专辑（**深拷贝**自库快照：后台线程绝不回头读 Library 单例）
struct CoverJob { std::string key, name, artist, term; };

// 一轮预热内共享的「查询词 → 封面 URL」缓存。
// 为什么需要：同一张碟常因为标签差异被拆成多条，第二轮（只按专辑名）的查询词在重复专辑
// 之间**完全相同**。不去重就要把同一个词打十几次，既慢又容易触发对方限流。
// 值 "" = 查过但没有。
struct CoverTermCache {
    std::mutex mtx;
    std::unordered_map<std::string, std::string> pic;
};

// 后台专用：真正去网上取一张封面并落盘。
// 返回值只用于统计：Hit = 拿到并写盘；Miss = 服务器确实没有（写 .none）；Fail = 瞬态失败（不写 .none）。
enum class CoverOutcome { Hit, Miss, Fail };

static CoverOutcome cover_fetch(const CoverJob& job, CoverTermCache& tc,
                                std::string* detail, long long* bytesOut) {
    const auto t0 = std::chrono::steady_clock::now();
    auto elapsed_ms = [&]() {
        return (int)std::chrono::duration_cast<std::chrono::milliseconds>(
                   std::chrono::steady_clock::now() - t0).count();
    };
    const rta::cover::CoverPaths pp = cover_paths(job.key);
    std::string pic, err;
    bool transient = false;      // 瞬态失败（超时/断网/异常）⟹ 不写 7 天负缓存

    try {
        // 两跳搜索：① "专辑名 艺术家"  ② 只 "专辑名"。
        // 为什么要第二跳：artist 是目录名/同人社团名时，把艺术家拼进去会**降低**召回 ——
        //   上游实测 172 张无封面专辑里，带艺术家搜索命中 61，只按专辑名搜索能命中 66 张"完全同名"。
        struct Try { std::string term, note; };
        std::vector<Try> tries;
        if (!job.term.empty()) tries.push_back({job.term, "album+artist"});
        if (!job.name.empty() && job.name != job.term) tries.push_back({job.name, "album"});
        std::string host = cover_env_host();
        if (host.empty()) host = "https://music.163.com";
        const std::string surl = host + "/api/search/get";
        const std::vector<std::string> hdr = {
            "User-Agent: Mozilla/5.0",
            "Referer: https://music.163.com/",
        };
        if (tries.empty()) err = "搜索词为空（专辑名与艺术家都没有）";
        for (const auto& at : tries) {
            const int remain = rta::cover::kCoverBudgetMs - elapsed_ms();
            if (remain <= 0) { err = "预算耗尽（搜索前）"; transient = true; break; }
            bool have = false;
            std::string cached;
            {
                std::lock_guard<std::mutex> lk(tc.mtx);
                auto it = tc.pic.find(at.term);
                if (it != tc.pic.end()) { cached = it->second; have = true; }
            }
            if (have) {
                if (!cached.empty()) { pic = cached; break; }
                err = "search(" + at.note + ") 无 picUrl";
                continue;
            }
            const int to = remain < rta::cover::kCoverSearchMs ? remain : rta::cover::kCoverSearchMs;
            const std::string body = "s=" + rta::cover::cover_pct_encode(at.term) + "&type=10&limit=5&offset=0";
            auto sr = rta::net::http_post(surl, body, hdr, "application/x-www-form-urlencoded", to);
            if (sr.ok && sr.status == 200) {
                const std::string js(sr.body.begin(), sr.body.end());
                const std::string got = rta::cover::cover_pick_pic(js, job.name, job.artist);
                {
                    std::lock_guard<std::mutex> lk(tc.mtx);
                    if (tc.pic.size() < 8192) tc.pic[at.term] = got;
                }
                if (!got.empty()) { pic = got; break; }
                err = "search(" + at.note + ") 无 picUrl";
            } else {
                err = "search(" + at.note + ") HTTP " + std::to_string(sr.status) + " " + sr.error;
                transient = (sr.status == 0);
                if (transient) break;      // 断网/超时：第二跳也一定失败，别再浪费一个超时
            }
        }
        if (!pic.empty()) {
            const int remain = rta::cover::kCoverBudgetMs - elapsed_ms();
            if (remain > 0) {
                const int to = remain < rta::cover::kCoverDownloadMs ? remain : rta::cover::kCoverDownloadMs;
                auto ir = rta::net::http_get(pic,
                                             {"User-Agent: Mozilla/5.0", "Referer: https://music.163.com/"}, to);
                if (ir.ok && ir.status == 200 && rta::cover::cover_accept_bytes(ir.body)) {
                    const std::string werr = cover_write_atomic(job.key, ir.body);
                    if (!werr.empty()) throw std::runtime_error(werr);
                    if (detail) *detail = pic;
                    if (bytesOut) *bytesOut = (long long)ir.body.size();
                    return CoverOutcome::Hit;
                }
                if (ir.ok && ir.status == 200) {
                    // 200 但不是图（错误页/防盗链 HTML）或太小 ⟹ 这是**服务器给了内容**的确定性结论，
                    // 不是瞬态失败。但也不能当"没有封面"写 7 天负缓存（下一轮可能就好），
                    // 上游口径：归为 transient（只计 fail，不写 .none）。
                    err = ir.body.size() < rta::cover::kCoverMinBytes
                              ? ("图片太小 " + std::to_string(ir.body.size()) + "B")
                              : ("不是图片（首字节 " + std::to_string(ir.body.empty() ? 0 : (int)ir.body[0]) + "）");
                    transient = true;
                } else {
                    err = "download HTTP " + std::to_string(ir.status) + " " + ir.error;
                    transient = (ir.status == 0);
                }
            } else {
                err = "预算耗尽（下载前）";
                transient = true;
            }
        }
    } catch (const std::exception& e) {
        err = std::string("exception: ") + e.what();
        transient = true;
    } catch (...) {
        err = "exception: unknown";
        transient = true;
    }

    if (!transient) {
        try {
            std::error_code ec;
            fs::create_directories(fs::u8path(pp.dir), ec);
            std::ofstream f(fs::u8path(pp.none), std::ios::binary | std::ios::trunc);
        } catch (...) {}
    }
    if (detail) *detail = err + " ms=" + std::to_string(elapsed_ms());
    return transient ? CoverOutcome::Fail : CoverOutcome::Miss;
}

// 一轮预热的共享状态：jobs 是**深拷贝**的名单（线程绝不回头读 Library 单例），
// 计数全原子；lastName 用短锁保护（progress 端点只在这里排队，一次字符串拷贝）。
struct CoverBg {
    std::vector<CoverJob> jobs;
    CoverTermCache terms;                      // 查询词去重（同一专辑名只打一次网易）
    std::atomic<size_t> next{0};
    std::atomic<int> hit{0}, miss{0}, fail{0};
    std::atomic<bool> running{true};
    std::mutex lastMtx;
    std::string last;
};
static std::mutex g_cover_bg_mtx;
static std::shared_ptr<CoverBg> g_cover_bg;
static std::atomic<size_t> g_cover_active{0};      // 当前在跑的预热轮数（0 或 1）

static void cover_bg_worker(std::shared_ptr<CoverBg> bg) {
    for (;;) {
        if (g_shutdown.load()) return;             // 退出中：不再开工（detach 掉也安全）
        const size_t i = bg->next.fetch_add(1);
        if (i >= bg->jobs.size()) return;
        const CoverJob job = bg->jobs[i];          // 拷贝：下面只碰局部 + 网络 + 文件系统
        {
            std::lock_guard<std::mutex> lk(bg->lastMtx);
            bg->last = job.name.empty() ? job.term : job.name;
        }
        std::string detail;
        long long got = 0;
        const CoverOutcome oc = cover_fetch(job, bg->terms, &detail, &got);
        switch (oc) {
        case CoverOutcome::Hit:
            bg->hit.fetch_add(1);
            play_log("COVERBG hit key=" + job.key + " name=" + job.name + " bytes=" + std::to_string(got) +
                     " url=" + detail);
            break;
        case CoverOutcome::Miss:
            bg->miss.fetch_add(1);
            play_log("COVERBG miss key=" + job.key + " name=" + job.name + " " + detail);
            break;
        default:
            bg->fail.fetch_add(1);
            play_log("COVERBG fail key=" + job.key + " name=" + job.name + " " + detail);
            break;
        }
    }
}

// 起一轮预热。返回 true = 已排队；false = 上一轮还在跑 / 名单为空（都不排队）。
static bool cover_bg_start(std::vector<CoverJob> jobs) {
    if (jobs.empty()) return false;
    size_t expect = 0;
    if (!g_cover_active.compare_exchange_strong(expect, 1)) return false;
    auto bg = std::make_shared<CoverBg>();
    bg->jobs = std::move(jobs);
    const size_t total = bg->jobs.size();
    {
        std::lock_guard<std::mutex> lk(g_cover_bg_mtx);
        g_cover_bg = bg;
    }
    std::thread([bg, total]() {
        std::vector<std::thread> ws;
        ws.reserve((size_t)rta::cover::kCoverBgConcurrency);
        for (int k = 0; k < rta::cover::kCoverBgConcurrency; ++k)
            ws.emplace_back([bg]() { cover_bg_worker(bg); });
        for (auto& t : ws) if (t.joinable()) t.join();
        bg->running.store(false);
        play_log("COVERBG done hit=" + std::to_string(bg->hit.load()) +
                 " miss=" + std::to_string(bg->miss.load()) +
                 " fail=" + std::to_string(bg->fail.load()) +
                 " total=" + std::to_string(total));
        g_cover_active.store(0);      // 先放行下一轮，再让 shared_ptr 释放名单
    }).detach();
    return true;
}

// 待抓名单（**请求线程**里构建：只读库 + 读目录，不发网络、不下载）。
// 已有正缓存 / 负缓存未过期 的专辑直接跳过 ⟹ queued 与 total 就是"真的还要联网"的张数。
static std::vector<CoverJob> cover_build_queue(const std::vector<std::string>& onlyKeys) {
    std::vector<CoverJob> out;
    auto& lib = Library::instance();
    if (!onlyKeys.empty()) {
        for (const auto& k : onlyKeys) {
            rta::net::LibCoverTerm t;
            if (!lib.albumCoverTerm(k, t)) continue;   // 键不存在：忽略（别把队列撑成假进度）
            if (cover_has_disk(t.key)) continue;       // 已有网图缓存
            out.push_back({t.key, t.name, t.artist, t.term});
        }
        return out;
    }
    for (const auto& t : lib.albumsWithoutCover()) {
        if (cover_has_disk(t.key)) continue;           // 已经抓到了
        if (cover_neg_fresh(t.key)) continue;          // 7 天内确认为"没有"，别每天重打
        out.push_back({t.key, t.name, t.artist, t.term});
    }
    return out;
}

// 列表端点用：一张专辑的封面来源。只信扫描时算好的 hasCover 标志 + 一次 stat，绝不触发 ffmpeg。
static const char* cover_src_of(const std::string& key, bool hasCover) {
    if (hasCover) return "embed";
    if (cover_has_disk(key)) return "net";
    return "none";
}

// ---------------- 20 段参数均衡 PEQ（261024-02 #6）----------------
// 全局单例：HTTP 线程改参数（热更新），播放线程处理音频；引擎内部互斥 + 128 样本交叉淡入。
// （g_peq 本体声明在文件靠前的 g_ps 附近 —— 播放线程代码在它之前就要用。）

static std::string peq_current_path()  { return path_in_exe_dir("rlplayer-peq.txt"); }
static std::string peq_presets_path()  { return path_in_exe_dir("rlplayer-peq-presets.txt"); }

// 用户预设文件格式：每个预设一段
//   [预设名]
//   preamp=...
//   band=1,PK,20,0.0,1.41
static bool peq_load_presets_file(std::map<std::string, rta::dsp::PeqSettings>& out) {
    std::ifstream f(peq_presets_path());
    if (!f) return false;
    std::string line, cur, body;
    auto flush = [&]() {
        if (cur.empty() || body.empty()) return;
        rta::dsp::PeqSettings s;
        std::string err;
        if (rta::dsp::peq_from_text(body, s, &err)) { s.presetName = cur; out[cur] = s; }
        body.clear();
    };
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.size() >= 2 && line.front() == '[' && line.back() == ']') {
            flush();
            cur = line.substr(1, line.size() - 2);
        } else {
            body += line; body += '\n';
        }
    }
    flush();
    return true;
}

static bool peq_save_presets_file(const std::map<std::string, rta::dsp::PeqSettings>& presets) {
    std::ofstream f(peq_presets_path(), std::ios::trunc);
    if (!f) return false;
    f << "# rlplayer PEQ presets v1\n";
    for (const auto& kv : presets) {
        rta::dsp::PeqSettings s = kv.second;
        s.presetName = kv.first;
        f << "[" << kv.first << "]\n" << rta::dsp::peq_to_text(s);
    }
    return true;
}

static std::vector<std::string> peq_all_preset_names() {
    std::vector<std::string> names = rta::dsp::peq_builtin_preset_names();
    std::map<std::string, rta::dsp::PeqSettings> user;
    peq_load_presets_file(user);
    for (const auto& kv : user) {
        bool dup = false;
        for (const auto& n : names) if (n == kv.first) dup = true;
        if (!dup) names.push_back(kv.first);
    }
    return names;
}

static void peq_load_current() {
    if (!g_peq) g_peq = std::make_shared<rta::dsp::PeqEngine>();
    rta::dsp::PeqSettings s = rta::dsp::peq_flat_settings();
    std::ifstream f(peq_current_path());
    if (f) {
        std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        rta::dsp::PeqSettings parsed;
        std::string err;
        if (rta::dsp::peq_from_text(text, parsed, &err)) s = parsed;
    }
    g_peq->set_settings(s);
}

static bool peq_save_current(const rta::dsp::PeqSettings& s) {
    std::ofstream f(peq_current_path(), std::ios::trunc);
    if (!f) return false;
    f << rta::dsp::peq_to_text(s);
    return true;
}

// 解析 UI 提交的 bands= 紧凑串：序号,类型,频率,增益,Q[,off];...
static bool peq_parse_bands_param(const std::string& val, std::vector<rta::dsp::PeqBand>& out) {
    out.clear();
    std::istringstream is(val);
    std::string item;
    while (std::getline(is, item, ';')) {
        if (item.empty()) continue;
        rta::dsp::PeqBand b;
        char type[8] = {0};
        double f = 1000.0, g = 0.0, q = 1.41;
        char tail[16] = {0};
        const int n = std::sscanf(item.c_str(), "%*d,%7[^,],%lf,%lf,%lf,%15s", type, &f, &g, &q, tail);
        if (n < 4) return false;
        rta::dsp::PeqBandType t;
        if (!rta::dsp::peq_band_type_from_name(type, t)) t = rta::dsp::PeqBandType::Peak;
        b.type = t;
        b.freq = std::min(std::max(f, 10.0), 20000.0);
        b.gainDb = std::min(std::max(g, -24.0), 24.0);
        b.q = std::min(std::max(q, 0.1), 20.0);
        b.enabled = !(std::string(tail).find("off") != std::string::npos);
        out.push_back(b);
    }
    return !out.empty();
}

// 当前 PEQ 状态 JSON（含预设名列表；withCurve 时附带 20Hz~20kHz 对数 160 点频响）
static std::string peq_state_json(bool withCurve) {
    if (!g_peq) peq_load_current();
    const rta::dsp::PeqSettings s = g_peq->settings();
    const double fs = g_peq->sample_rate();
    std::ostringstream j;
    j << "{\"ok\":true,\"bypass\":" << (s.bypass ? 1 : 0)
      << ",\"preamp\":" << s.preampDb
      << ",\"name\":\"" << jesc(s.presetName) << "\""
      << ",\"fs\":" << fs
      << ",\"bands\":[";
    for (size_t i = 0; i < s.bands.size(); ++i) {
        const auto& b = s.bands[i];
        if (i) j << ",";
        j << "{\"i\":" << (i + 1) << ",\"on\":" << (b.enabled ? 1 : 0)
          << ",\"type\":\"" << rta::dsp::peq_band_type_name(b.type) << "\""
          << ",\"freq\":" << b.freq << ",\"gain\":" << b.gainDb << ",\"q\":" << b.q << "}";
    }
    j << "],\"presets\":[";
    const auto names = peq_all_preset_names();
    for (size_t i = 0; i < names.size(); ++i) {
        if (i) j << ",";
        j << "\"" << jesc(names[i]) << "\"";
    }
    j << "]";
    if (withCurve) {
        const int N = 160;
        j << ",\"points\":[";
        for (int i = 0; i < N; ++i) {
            const double t = (double)i / (double)(N - 1);
            const double f = 20.0 * std::pow(1000.0, t);   // 20Hz → 20kHz
            if (i) j << ",";
            j << "[" << f << "," << rta::dsp::peq_response_db(s, fs, f) << "]";
        }
        j << "]";
    }
    j << "}";
    return j.str();
}

// ---------------- 采集 / 直通监听状态与后台线程 (ROADMAP P4b) ----------------
struct InputSessionState {
    std::mutex mtx;
    std::mutex joinMtx;
    std::thread th;
    std::atomic<bool> running{false};
    std::atomic<bool> stopFlag{false};

    std::string mode = "null"; // "record" | "monitor" | "null"
    std::string device;
    uint32_t rate = 0;
    int channels = 0;
    double seconds = 0.0;
    uint64_t frames = 0;
    double water = 0.0;
    uint64_t overflow = 0;
    uint64_t underflow = 0;
    long long posClips = 0;
    long long negClips = 0;
    std::string outFile;
    double rmsDb = -999.0;
    double peakDb = -999.0;
    std::string error;

    void reap() {
        std::lock_guard<std::mutex> lk(joinMtx);
        if (!running.load() && th.joinable()) {
            th.join();
        }
    }

    void stop() {
        stopFlag.store(true);
        std::lock_guard<std::mutex> lk(joinMtx);
        if (th.joinable()) {
            th.join();
        }
        running.store(false);
    }
};
static InputSessionState g_inputSession;

static std::string default_recording_path() {
    // 2026-10-25（默认目录纠正）：原来固定写 path_in_exe_dir("recordings")，
    // 在 macOS 上就是 RLPlayer.app/Contents/MacOS/recordings —— **包内不可写**
    // （应用包是只读签名体，SIP 与代码签名都会拒绝写入），录制必然失败。
    // 现在优先落到 data_dir（~/Library/Application Support/RLPlayer/recordings），
    // 那是 macOS 上唯一正确的位置；只有在 data_dir 不可用时才退回 exe 目录（便携场景）。
    std::string recDir;
    const std::string dataDir = rta::platform::data_dir_utf8();
    if (!dataDir.empty()) recDir = dataDir + "/recordings";
    if (recDir.empty()) recDir = path_in_exe_dir("recordings");

    std::error_code ec;
    fs::create_directories(fs::u8path(recDir), ec);
    if (ec || !fs::is_directory(fs::u8path(recDir), ec)) {
        // 建不出来就退回临时目录，绝不返回一个写不进去的路径（否则用户录完才发现全丢）。
        const std::string tmp = rta::platform::temp_dir_utf8();
        recDir = tmp + "rlplayer-recordings";
        fs::create_directories(fs::u8path(recDir), ec);
    }
    auto t = std::time(nullptr);
    auto tm = *std::localtime(&t);
    char buf[64];
    std::strftime(buf, sizeof(buf), "cap-%Y%m%d-%H%M%S.wav", &tm);
    return recDir + "/" + buf;
}

// 2026-10-25：原 WASAPI 采集线程（Windows 专属）已随平台删除。
// 能力未丢：macOS 侧由下方 input_worker_mac（CoreAudioInput）等价实现，
// 主体逻辑同构（读取/统计/状态上报/结束写 WAV），仅直通监听用 CoreAudioSink。

// ---------------- macOS 采集 worker（§13.13）----------------
// 主体逻辑与 Windows 的 input_worker_func 同构（读取/统计/状态上报/结束写 WAV）；
// 差异只有直通监听：mac 用 CoreAudioSink（int32 低位对齐语义），float→int32 转换后写入
// ——监听本就声明非 bit-perfect（§10 语义），float32 域承载 -144 dB 级转换噪声。
static void input_worker_mac(std::shared_ptr<rta::platform::CoreAudioInput> cap,
                             std::shared_ptr<CoreAudioSink> monitorOut,
                             std::string mode, std::string outFile, double maxSeconds) {
    const uint32_t rate = cap->rate();
    const int channels = cap->channels();
    const size_t totalTargetFrames = (maxSeconds > 0.0) ? (size_t)(maxSeconds * (double)rate) : 0;

    std::vector<float> recorded;
    if (mode == "record" && totalTargetFrames > 0)
        recorded.reserve(totalTargetFrames * (size_t)channels);

    std::vector<float> chunk(2048 * (size_t)channels);
    std::vector<int32_t> mon;
    size_t recordedFrames = 0;

    while (!g_inputSession.stopFlag.load()) {
        if (totalTargetFrames > 0 && recordedFrames >= totalTargetFrames) break;
        size_t want = 2048;
        if (totalTargetFrames > 0 && recordedFrames + want > totalTargetFrames)
            want = totalTargetFrames - recordedFrames;

        const size_t n = cap->read_available(chunk.data(), want);
        if (n > 0) {
            if (mode == "record")
                recorded.insert(recorded.end(), chunk.begin(), chunk.begin() + n * (size_t)channels);
            recordedFrames += n;

            double sumSq = 0.0, maxPeak = 0.0;
            const size_t totalSamples = n * (size_t)channels;
            for (size_t i = 0; i < totalSamples; ++i) {
                const double a = std::fabs((double)chunk[i]);
                if (a > maxPeak) maxPeak = a;
                sumSq += (double)chunk[i] * (double)chunk[i];
            }
            const double rms = std::sqrt(sumSq / (double)(totalSamples ? totalSamples : 1));
            const double rmsDb = (rms > 1e-12) ? 20.0 * std::log10(rms) : -999.0;
            const double peakDb = (maxPeak > 1e-12) ? 20.0 * std::log10(maxPeak) : -999.0;

            if (monitorOut) {
                mon.resize(n * (size_t)channels);
                for (size_t i = 0; i < mon.size(); ++i)
                    mon[i] = (int32_t)std::lround((double)chunk[i] * 2147483647.0);
                size_t fed = 0;
                while (fed < n)
                    fed += monitorOut->write_one_period(mon.data() + fed * (size_t)channels, n - fed);
            }

            {
                std::lock_guard<std::mutex> lk(g_inputSession.mtx);
                g_inputSession.frames = recordedFrames;
                g_inputSession.seconds = (double)recordedFrames / (double)rate;
                g_inputSession.water = cap->water_level();
                g_inputSession.overflow = cap->overflow_count();
                g_inputSession.underflow = cap->underflow_count();
                g_inputSession.rmsDb = rmsDb;
                g_inputSession.peakDb = peakDb;
            }
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }
    if (mode == "record" && !recorded.empty()) {
        if (outFile.empty()) outFile = default_recording_path();
        FILE* f = std::fopen(outFile.c_str(), "wb");
        if (f) {
            const uint32_t dataBytes = (uint32_t)(recorded.size() * sizeof(float));
            const uint32_t byteRate = rate * (uint32_t)channels * 4;
            std::vector<char> h(44);
            h[0]='R';h[1]='I';h[2]='F';h[3]='F'; h[8]='W';h[9]='A';h[10]='V';h[11]='E';
            h[12]='f';h[13]='m';h[14]='t';h[15]=' ';
            h[16]=16; h[20]=3; h[36]='d';h[37]='a';h[38]='t';h[39]='a';
            *(uint16_t*)&h[22] = (uint16_t)channels;   // nChannels（曾经写死 1：stereo 数据配 mono 头）
            *(uint32_t*)&h[4]  = 36 + dataBytes;
            *(uint32_t*)&h[24] = rate;
            *(uint32_t*)&h[28] = byteRate;
            *(uint16_t*)&h[32] = (uint16_t)channels * 4;   // blockAlign（2 字节！写 4 字节会盖掉 bitsPerSample）
            *(uint16_t*)&h[34] = 32;                        // wBitsPerSample（float32）
            *(uint32_t*)&h[40] = dataBytes;
            std::fwrite(h.data(), 1, h.size(), f);
            std::fwrite(recorded.data(), sizeof(float), recorded.size(), f);
            std::fclose(f);
            std::lock_guard<std::mutex> lk(g_inputSession.mtx);
            g_inputSession.outFile = outFile;
        }
    }
    g_inputSession.running.store(false);
}

// rlplayer-llm.conf 的可选 proxy= 行(P1.5 后备代理)。llm.h 的 LlmConfig 不带该字段
// (llm.h 不在本轮可改清单),rtaweb 侧自行解析同一文件:键名 proxy,值形如
// http://127.0.0.1:7897;# 注释/空行/trim 规则与 llm_config_load 一致。没有该行 → 空。
static std::string llm_conf_proxy_line() {
    std::ifstream f(path_in_exe_dir("rlplayer-llm.conf"), std::ios::binary);
    std::string line;
    while (std::getline(f, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t')) line.pop_back();
        size_t b = 0;
        while (b < line.size() && (line[b] == ' ' || line[b] == '\t')) ++b;
        line = line.substr(b);
        if (line.empty() || line[0] == '#') continue;
        const size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        if (line.substr(0, eq) == "proxy") return line.substr(eq + 1);
    }
    return "";
}

// ---- 播放日志（落盘，排查"播几秒变噪音"这类现场问题）----
// 启动器日志只有启动信息；播放格式、峰值、欠载必须由播放线程自己记，
// 否则用户发来的 launcher.log 里根本看不到"放到第几秒、什么采样率、峰值多少"。
// 位置：exe 同目录 rlplayer-playback.log；超过 4 MB 轮转。
// 轮转保留 3 份（1.0.5 改）：playback.log → .1 → .2，再轮转时最旧的 .2 被删 ——
// 旧版只有单份 .1，一盖就丢，现场排查要"上上次启动"的日志时无从找起。
static std::mutex g_playLogMx;
static void play_log(const std::string& s) {
    std::lock_guard<std::mutex> lk(g_playLogMx);
    const std::string p = path_in_exe_dir("rlplayer-playback.log");
    std::error_code ec;
    const bool needBom = !fs::exists(p, ec) || fs::file_size(p, ec) == 0;
    std::ofstream f(p, std::ios::app | std::ios::binary);
    if (!f) return;
    if (needBom) f.write("\xEF\xBB\xBF", 3);   // Notepad 才能正确识别中文
    // 本地时间戳（原 Windows 用 SYSTEMTIME/GetLocalTime；chrono 等价跨平台）
    {
        const std::time_t nowT = std::time(nullptr);
        std::tm lt{};
        localtime_r(&nowT, &lt);
        const auto ms = (int)(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count() % 1000);
        char ts[64];
        std::snprintf(ts, sizeof(ts), "%04d-%02d-%02d %02d:%02d:%02d.%03d ",
                      lt.tm_year + 1900, lt.tm_mon + 1, lt.tm_mday,
                      lt.tm_hour, lt.tm_min, lt.tm_sec, ms);
        f << ts;
    }
    f << s << "\n";
}
static void play_log_rotate() {
    const std::string p = path_in_exe_dir("rlplayer-playback.log");
    std::error_code ec;
    const auto sz = fs::file_size(p, ec);
    if (ec || sz <= 4u * 1024u * 1024u) return;
    const std::string p1 = p + ".1", p2 = p + ".2";
    std::error_code eDel, eR1, eR2;
    fs::remove(p2, eDel);          // 最旧的一份出队（保留 3 份：当前 + .1 + .2）
    fs::rename(p1, p2, eR1);
    fs::rename(p, p1, eR2);
}

// ---------------- 元数据补全(播放触发 + /api/enrich 共用) ----------------
// P1.5 注册表化:数据源开关按注册表逐源存 metasrc_<id>(metasrc_qq/...)。
// 读侧:旧键 metaqq/metanetease/metaitunes/metalrclib 若存在则迁移读取(只读不写,
// 写侧只写新键);metaon 总开关、metallm 不变。每次现读文件 —— 设置改完立即生效。
// POST 白名单见 /api/settings。
struct MetaSettings {
    bool on = true;                          // metaon 总开关
    bool llm = true;                         // metallm
    bool summary = false;                    // metasummary 默认 0（成本策略：显式开启）
    std::map<std::string, bool> srcOn;       // 注册表 id → 开关(缺省 true)
};
static bool meta_bool_val(const std::string& v) {
    return v == "1" || v == "true" || v == "on";
}
static MetaSettings meta_settings_load() {
    MetaSettings ms;
    std::map<std::string, std::string> legacy;      // 旧键 metaqq/... 的值(迁移读取用)
    std::ifstream f(path_in_exe_dir("rlplayer-settings.conf"));
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t e = line.find('=');
        if (e == std::string::npos) continue;
        const std::string k = line.substr(0, e);
        const std::string v = line.substr(e + 1);
        if      (k == "metaon")      ms.on      = meta_bool_val(v);
        else if (k == "metallm")     ms.llm     = meta_bool_val(v);
        else if (k == "metasummary") ms.summary = meta_bool_val(v);
        else if (k.rfind("metasrc_", 0) == 0) ms.srcOn[k.substr(8)] = meta_bool_val(v);
        else if (k == "metaqq")      legacy["qq"]      = v;
        else if (k == "metanetease") legacy["netease"] = v;
        else if (k == "metaitunes")  legacy["itunes"]  = v;
        else if (k == "metalrclib")  legacy["lrclib"]  = v;
    }
    // 补全:注册表逐源,新键未写且旧键存在 → 迁移;两者都没有 → 缺省开
    for (const rta::meta::ProviderDesc& pd : rta::meta::provider_registry()) {
        if (ms.srcOn.count(pd.id) != 0) continue;
        const auto it = legacy.find(pd.id);
        ms.srcOn[pd.id] = (it == legacy.end()) ? true : meta_bool_val(it->second);
    }
    return ms;
}
static rta::meta::EnrichOpts meta_opts_from_settings() {
    const MetaSettings ms = meta_settings_load();
    rta::meta::EnrichOpts o;
    o.srcOn = ms.srcOn;
    o.llm = ms.llm;
    // 功能4：llm 配置固定读 exe 同目录（界面 /api/llm 写的就是这一份）
    o.llmConfPath = path_in_exe_dir("rlplayer-llm.conf");
    // 挂入全局退出标志：g_shutdown 是静态全局对象，生命周期覆盖整个进程，安全
    o.cancel = &g_shutdown;
    return o;
}

// 播放触发的后台补全:metaon 关 → 直接回;同一文件在途(inFlight)不重复起线程。
// enrich_track 自带全链路降级,线程内任何失败只影响该文件的 note,不影响播放。
static void meta_on_play(const std::string& file) {
    const MetaSettings ms = meta_settings_load();
    // F1：后台线程入口同样校验 —— 端点层已挡，这里防的是旧队列/外部写入的坏路径
    //（enrich_track 链路 meta_path_of 用 u8string→fs::path，后台线程抛异常=整进程终止）。
    if (!ms.on || file.empty()) return;
    if (!valid_utf8(file)) { utf8_path_reject(file); return; }
    static std::mutex s_metaMx;
    static std::set<std::string> s_inFlight;
    {
        std::lock_guard<std::mutex> lk(s_metaMx);
        if (s_inFlight.count(file) != 0) return;    // 在途:本曲已在补全,不重复
        s_inFlight.insert(file);
    }
    bg_job_begin();     // 登记：stop_embedded 会等它收完（有界，超时如实记日志）
    std::thread([file, ms] {
        rta::meta::EnrichOpts o;
        o.srcOn = ms.srcOn; o.llm = ms.llm;
        o.llmConfPath = path_in_exe_dir("rlplayer-llm.conf");
        // EnrichOpts 是值拷贝进 lambda，但 cancel 指针指向全局对象 g_shutdown，
        // 生命周期覆盖整个进程，后台线程安全访问
        o.cancel = &g_shutdown;
        rta::meta::enrich_track(file, false, o);
        { std::lock_guard<std::mutex> lk(s_metaMx); s_inFlight.erase(file); }
        bg_job_end();
    }).detach();
}

// ---------------- 标签写回(P2;/api/writeback 三端点共用状态) ----------------
// POST /api/writeback {"apply":true} 起后台线程跑 writeback_library,立即返回;
// GET /api/writeback/status 轮询进度。互斥量保护全部字段;进度回调在批任务线程上
// 同步到来,只做赋值。dry-run 批(POST 不带 apply:true)同样支持 —— 全流程校验但不落盘。
struct WbJob {
    std::mutex mtx;
    std::thread th;              // 当前/上一轮批任务线程(start 时收割上一轮的 join)
    bool running = false;
    bool dryRun = true;
    int done = 0, total = 0, written = 0, skipped = 0, failed = 0;
    std::string err;             // 整批级错误(如 MetaStore 目录不存在)
    std::vector<std::pair<std::string, std::string>> lastFailures;   // 截到 10 条
};
static WbJob g_wb;

// 起批;已在进行返回 false(调用端回「已在进行中」,不覆盖在跑的一轮)。
static bool writeback_start(const bool apply) {
    std::thread prev;
    {
        std::lock_guard<std::mutex> lk(g_wb.mtx);
        if (g_wb.running) return false;
        if (g_wb.th.joinable()) prev = std::move(g_wb.th);   // 收割已结束的上一轮,锁外 join
        g_wb.running = true;
        g_wb.dryRun = !apply;
        g_wb.done = g_wb.total = g_wb.written = g_wb.skipped = g_wb.failed = 0;
        g_wb.err.clear();
        g_wb.lastFailures.clear();
        g_wb.th = std::thread([apply] {
            rta::meta::WritebackOpts o;
            o.dryRun = !apply;
            o.backup = true;                 // Web 批写回固定备份(安全红线①)
            std::string err;
            const rta::meta::BatchResult br = rta::meta::writeback_library(
                o, &err,
                [](const rta::meta::BatchResult& b, const int done, const int total) {
                    std::lock_guard<std::mutex> lk(g_wb.mtx);
                    g_wb.done = done; g_wb.total = total;
                    g_wb.written = b.written; g_wb.skipped = b.skipped; g_wb.failed = b.failed;
                });
            std::lock_guard<std::mutex> lk(g_wb.mtx);
            g_wb.done = br.total; g_wb.total = br.total;
            g_wb.written = br.written; g_wb.skipped = br.skipped; g_wb.failed = br.failed;
            g_wb.err = err;
            g_wb.lastFailures = br.failureList;
            if (g_wb.lastFailures.size() > 10) g_wb.lastFailures.resize(10);
            g_wb.running = false;
        });
    }
    if (prev.joinable()) prev.join();
    return true;
}

// GET /api/writeback 预览:纯只读扫描 MetaStore 记录,复刻 writeback_file 的
// 扩展名门与非空字段门来数「可写/跳过」,不跑 ffmpeg、不做 remux、不写任何文件
// (remux + PCM 逐位校验只发生在真正起批的 writeback_file 里)。
struct WbPreviewItem {
    std::string file;        // 音频路径(记录损坏时是 json 文件名)
    bool writable = false;
    std::string fields;      // 将写入的字段名(逗号分隔;可写时)
    std::string reason;      // 跳过原因(不可写时)
};
struct WbPreview {
    int total = 0, writable = 0, skipped = 0;
    std::string err;
    std::vector<WbPreviewItem> items;
};
static WbPreview writeback_preview_scan() {
    WbPreview w;
    const std::string baseDir = rta::meta::MetaStore::instance().baseDir();
    const fs::path tracksDir = fs::u8path(baseDir) / "tracks";
    std::error_code ec;
    if (!fs::exists(tracksDir, ec) || ec) {
        // 从未 enrich 的空库不是错误:预览如实给 0/0/0(UI toast「0 首可写,0 首跳过」)。
        // 真正起批时 writeback_library 仍会对缺失目录报错(那里"无事可做"必须说清)。
        return w;
    }
    std::vector<fs::path> jsons;
    for (fs::directory_iterator it(tracksDir, ec), end; !ec && it != end; it.increment(ec)) {
        std::error_code e2;
        if (!it->is_regular_file(e2) || e2) continue;
        const std::string name = pathToUtf8(it->path().filename());
        if (name.size() < 6 || name.compare(name.size() - 5, 5, ".json") != 0) continue;
        jsons.push_back(it->path());
    }
    if (ec) { w.err = "扫描 MetaStore 记录目录失败:" + baseDir + "/tracks"; return w; }
    std::sort(jsons.begin(), jsons.end());
    for (const fs::path& jp : jsons) {
        ++w.total;
        WbPreviewItem it;
        rta::meta::TrackMeta tm;
        if (!rta::meta::writeback_load_store_record(pathToUtf8(jp), tm)) {
            it.file = pathToUtf8(jp.filename());
            it.reason = "记录解析失败/缺 path";
            ++w.skipped;
            w.items.push_back(std::move(it));
            continue;
        }
        it.file = tm.path;
        // 与 writeback_file 相同的门,只判断不落盘(DSD/ape/未知扩展/空字段/源缺失/PICTURE畸形)
        const std::string ext = rta::audio::lowerExt(tm.path);
        std::string reason;
        if (ext == ".dsf" || ext == ".dff") reason = "DSD(" + ext + ")按安全红线绝不写回";
        else if (ext == ".ape") reason = "ffmpeg 无 APE muxer,无法无损 remux";
        else if (!rta::meta::writeback_muxer(ext))
            reason = "不支持的扩展名 \"" + ext + "\"(支持 flac/mp3/ogg/opus/m4a/wma/wav/wv)";
        else if (rta::meta::writeback_collect(tm, rta::meta::writeback_vorbis_family(ext)).empty())
            reason = "无可写字段(12 个常规字段全空)";
        else {
            std::error_code e3;
            if (!fs::exists(fs::u8path(tm.path), e3) || e3) reason = "源文件不存在";
            else if (rta::meta::writeback_detect_picture_malformed(tm.path, &reason)) {
                // reason 已由纯容器头解析判定为 PICTURE 块/APIC 帧畸形
            }
        }
        if (reason.empty()) {
            it.writable = true;
            ++w.writable;
            const std::vector<rta::meta::WbField> kvs =
                rta::meta::writeback_collect(tm, rta::meta::writeback_vorbis_family(ext));
            for (size_t i = 0; i < kvs.size(); ++i) {
                if (i) it.fields += ",";
                it.fields += kvs[i].field;
            }
        } else {
            it.reason = reason;
            ++w.skipped;
        }
        w.items.push_back(std::move(it));
    }
    return w;
}

// ---------------- 收藏（曲目喜好标记，落盘到 exe 目录小 json）----------------
static std::mutex g_favMu;
static std::set<std::string> g_favFiles;
static bool g_favLoaded = false;

static std::string normalize_fav_path(std::string p) {
    for (char& c : p) { if (c == '/') c = '\\'; }
    return p;
}

static void fav_load_if_needed() {
    std::lock_guard<std::mutex> lk(g_favMu);
    if (g_favLoaded) return;
    g_favLoaded = true;
    const std::string path = path_in_exe_dir("rlplayer-favs.json");
    std::error_code ec;
    if (!fs::exists(fs::u8path(path), ec)) return;
    std::ifstream f(fs::u8path(path), std::ios::binary);
    if (!f) return;
    std::string s((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    rta::net::Json j = rta::net::json_parse(s);
    if (j.type == rta::net::Json::Arr) {
        for (size_t i = 0; i < j.size(); ++i) {
            if (j.at(i).type == rta::net::Json::Str) {
                g_favFiles.insert(normalize_fav_path(j.at(i).s()));
            }
        }
    } else if (j.type == rta::net::Json::Obj && j.has("files") && j["files"].type == rta::net::Json::Arr) {
        const auto& arr = j["files"];
        for (size_t i = 0; i < arr.size(); ++i) {
            if (arr.at(i).type == rta::net::Json::Str) {
                g_favFiles.insert(normalize_fav_path(arr.at(i).s()));
            }
        }
    }
}

// 落盘收藏：**原子写**（tmp + rename）+ 返回是否成功。
// 2026-10-23 DEBUG：旧实现 trunc 直写且失败静默 return，exe 在 Program Files/被杀软占用时
// 会「前端弹已收藏、重启后全丢」；进程中断还会留半截 JSON 导致下次解析失败清空。
static bool fav_save_locked() {
    const std::string path = path_in_exe_dir("rlplayer-favs.json");
    const std::string tmp = path + ".tmp";
    std::string body = "{\"files\":[";
    bool first = true;
    for (const auto& file : g_favFiles) {
        if (!first) body += ",";
        first = false;
        body += "\"" + jesc(file) + "\"";
    }
    body += "]}\n";
    {
        std::ofstream f(fs::u8path(tmp), std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f << body;
        if (!f.good()) return false;
    }
    std::error_code ec;
    fs::rename(fs::u8path(tmp), fs::u8path(path), ec);
    if (ec) { std::error_code ec2; fs::remove(fs::u8path(tmp), ec2); return false; }
    return true;
}

static void recent_add(const std::string& file, const std::string& title,
                       const std::string& artist, const std::string& album) {
    const std::string p = path_in_exe_dir("rlplayer-recent.txt");
    std::vector<std::string> lines;
    { std::ifstream f(p); std::string l;
      while (std::getline(f, l)) { if (!l.empty() && l.back() == '\r') l.pop_back(); if (!l.empty()) lines.push_back(l); } }
    // 去重（同一文件只留最新一条）
    std::vector<std::string> out;
    out.push_back(file + "\t" + title + "\t" + artist + "\t" + album);
    for (auto& l : lines) {
        if (l.rfind(file + "\t", 0) == 0) continue;
        out.push_back(l);
        if (out.size() >= 200) break;
    }
    std::ofstream f(p, std::ios::trunc);
    for (auto& l : out) f << l << "\n";
}

static void queue_save() {
    std::lock_guard<std::mutex> lk(g_q.mtx);
    std::ofstream f(queue_file(), std::ios::trunc);
    if (!f) return;
    f << "# RLPlayer playlist v1\n";
    f << "index=" << g_q.index << "\n";
    f << "mode=" << g_q.mode << "\n";
    // 旧键同时写一份：万一用户回滚到旧版本，repeat/shuffle 仍能读（单向兼容）
    f << "repeat=" << g_q.repeat_of() << "\n";
    f << "shuffle=" << (g_q.shuffle_of() ? 1 : 0) << "\n";
    // 队列项落盘格式：item=<路径>，CUE 分轨项再跟两个 TAB 分隔的秒数（cs/ce）。
    // 普通曲目**逐字节与旧格式相同** ⟹ 老队列文件照旧可读（读侧只在有 TAB 时才当 cue 解析）。
    for (const auto& it : g_q.items) {
        f << "item=" << it.path;
        if (it.isCue()) {
            char cb[80];
            std::snprintf(cb, sizeof(cb), "\t%.6f\t%.6f", it.cs, it.ce);
            f << cb;
        }
        f << "\n";
    }
}

static void queue_load() {
    std::ifstream f(queue_file());
    if (!f) return;
    std::lock_guard<std::mutex> lk(g_q.mtx);
    std::string line;
    g_q.items.clear();
    // R-4：优先读 mode；老文件只有 repeat/shuffle 时按旧语义推导一次（单向兼容）
    bool hasMode = false;
    int  oldRepeat = 0;
    bool oldShuffle = false;
    while (std::getline(f, line)) {
        if (line.rfind("index=", 0) == 0) g_q.index = (size_t)atoi(line.c_str() + 6);
        else if (line.rfind("mode=", 0) == 0) { g_q.mode = atoi(line.c_str() + 5); hasMode = true; }
        else if (line.rfind("repeat=", 0) == 0) oldRepeat = atoi(line.c_str() + 7);
        else if (line.rfind("shuffle=", 0) == 0) oldShuffle = (atoi(line.c_str() + 8) != 0);
        else if (line.rfind("item=", 0) == 0) {
            g_q.items.push_back(item_from_line(line.substr(5)));
        }
    }
    g_q.sortBase.clear();
    if (g_q.index >= g_q.items.size()) g_q.index = 0;
    // R-4：没有 mode 键（老队列文件）⟹ 由 repeat/shuffle 推导一次（单向兼容）
    if (!hasMode) {
        if (oldShuffle)          g_q.mode = 3;
        else if (oldRepeat == 2) g_q.mode = 2;
        else if (oldRepeat == 1) g_q.mode = 1;
        else                     g_q.mode = 0;
    }
    if (g_q.mode < 0 || g_q.mode > 3) g_q.mode = 0;
}

// ---------------- 具名保存队列（用户 261026-08 #6「保存队列 + 重命名」）----------------
// 为什么不复用 playlists\*.m3u8（/api/pl）：m3u8 装不下 CUE 区间，"保存队列"要求**原样还原整列**
//   （顺序 + cue 区间都要在），所以单独存一份带区间的 conf；风格与 rlplayer-playlist.txt 一致：
//   纯文本 / 每行 key=value / # 开头是注释 / UTF-8。
// 落盘：path_in_exe_dir("rlplayer-savedqueues.conf") ⟹ 重启后仍在（支持 RLPLAYER_STATE_DIR 隔离）。
struct SavedQueue {
    std::string name;
    std::vector<QItem> items;
};
static std::mutex g_sqMu;
static std::vector<SavedQueue> g_sqList;
static bool g_sqLoaded = false;

static std::string saved_queues_path() { return path_in_exe_dir("rlplayer-savedqueues.conf"); }

static void sq_load_if_needed() {
    std::lock_guard<std::mutex> lk(g_sqMu);
    if (g_sqLoaded) return;
    g_sqLoaded = true;
    std::ifstream f(fs::u8path(saved_queues_path()), std::ios::binary);
    if (!f) return;
    SavedQueue cur;
    bool open = false;
    auto flush = [&] {
        if (open && !cur.name.empty()) g_sqList.push_back(cur);
        cur = SavedQueue{};
        open = false;
    };
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        if (line.rfind("name=", 0) == 0) {
            flush();
            cur.name = line.substr(5);
            open = true;
        } else if (line.rfind("item=", 0) == 0 && open) {
            cur.items.push_back(item_from_line(line.substr(5)));
        }
    }
    flush();
}

static bool sq_save_locked() {
    const std::string path = saved_queues_path();
    const std::string tmp = path + ".tmp";
    {
        std::ofstream f(fs::u8path(tmp), std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f << "# RLPlayer saved queues v1\n";
        for (const auto& q : g_sqList) {
            f << "name=" << q.name << "\n";
            for (const auto& it : q.items) {
                f << "item=" << it.path;
                if (it.isCue()) {
                    char cb[80];
                    std::snprintf(cb, sizeof(cb), "\t%.6f\t%.6f", it.cs, it.ce);
                    f << cb;
                }
                f << "\n";
            }
        }
        if (!f.good()) return false;
    }
    std::error_code ec;
    fs::rename(fs::u8path(tmp), fs::u8path(path), ec);
    if (ec) { std::error_code ec2; fs::remove(fs::u8path(tmp), ec2); return false; }
    return true;
}

// ---- 预解码槽：当前曲播放的同时，后台把下一曲解码进内存 ----
struct PreSlot {
    std::mutex mtx;
    std::thread th;
    std::atomic<bool> busy{false};
    std::string path;
    rta::audio::AudioBuffer buf;
};
static PreSlot g_pre;

static void prefetch_start(const std::string& path) {
    if (path.empty() || g_pre.busy.load()) return;
    // 大文件不预解码（2026-10-25）：这类文件在播放时走流式，预先把整曲塞进内存正好是
    // 要修的那个病（517 MB + 1 GB 峰值）。判据与播放路径同一个函数，不会出现两套口径。
    {
        double mb = 0.0;
        if (rta::audio::should_stream_decode(path, &mb, nullptr)) {
            play_log("PREFETCH_SKIP stream file=" + path);
            return;
        }
    }
    if (g_pre.th.joinable()) g_pre.th.join();
    {
        std::lock_guard<std::mutex> lk(g_pre.mtx);
        if (g_pre.path == path && !g_pre.buf.raw.empty()) return;   // 已有现成的
    }
    g_pre.busy.store(true);
    g_pre.path = path;
    { std::lock_guard<std::mutex> lk(g_pre.mtx); g_pre.buf = rta::audio::AudioBuffer{}; }
    g_pre.th = std::thread([path]() {
        try {
            apply_dsd_src_settings(params_snapshot());   // 预解码也按当前设置（否则会解码出另一套滤波器）
            rta::audio::AudioBuffer b = read_any(path, nullptr);
            std::lock_guard<std::mutex> lk(g_pre.mtx);
            if (g_pre.path == path) g_pre.buf = std::move(b);
        } catch (...) { /* 预解码失败不影响正常解码 */ }
        g_pre.busy.store(false);
    });
}

static rta::audio::AudioBuffer prefetch_take(const std::string& path) {
    std::lock_guard<std::mutex> lk(g_pre.mtx);
    if (g_pre.path == path && !g_pre.buf.raw.empty()) {
        rta::audio::AudioBuffer b = std::move(g_pre.buf);
        g_pre.buf = rta::audio::AudioBuffer{};
        return b;
    }
    return rta::audio::AudioBuffer{};
}

// ---- 队列播放线程：自动播下一首，并在播当前曲时预解码下一曲 ----
static void queue_thread(PlayParams p, size_t start) {
    auto& ps = g_ps;
    size_t idx = start;
    for (;;) {
        if (ps.stop.load()) break;

        QItem cur;
        std::string nextPath;
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            if (g_q.items.empty()) break;
            if (idx >= g_q.items.size()) {
                if (g_q.mode == 1 || g_q.mode == 3) idx = 0;   // R-4：列表循环与随机都在末尾回绕
                else break;
            }
            cur = g_q.items[idx];
            g_q.index = idx;
            if (idx + 1 < g_q.items.size()) nextPath = g_q.items[idx + 1].path;
        }

        { std::lock_guard<std::mutex> lk(ps.mtx); ps.current = cur.path; ps.error.clear(); }
        ps.played.store(0);
        ps.total.store(0);

        if (!nextPath.empty()) prefetch_start(nextPath);   // 后台预解码下一曲

        rta::audio::AudioBuffer buf = prefetch_take(cur.path);
        // ★ 本曲的播放区间**只来自队列项**：绝不沿用上一曲的 cueStart/cueEnd。
        //   （p 是"最近一次播放参数"，同专辑内切到非 cue 曲目时必须归零，否则会少播一段。）
        PlayParams pit = p;
        pit.cueStart = cur.cs;
        pit.cueEnd   = cur.ce;
        const bool done = play_one(cur.path, pit, buf);
        const double endPos = (ps.outRate > 0 ? (double)ps.played.load() / (double)ps.outRate : 0.0);
        const size_t endPlayed = ps.played.load();
        std::string endErr = ps.error;
        const std::string endCur = cur.path;
        {
            std::ostringstream es;
            es << "END pos=" << endPos
               << " played=" << endPlayed << " total=" << ps.total.load()
               << " clip=" << g_dbgClip.load()
               << " error=\"" << endErr << "\""
               << " cue=" << (cur.isCue() ? cue_range_text(cur.cs, cur.ce) : std::string("-"))
               << " file=" << endCur
               << " v" << RLPLAYER_VERSION;
            play_log(es.str());
        }
        {
            std::lock_guard<std::mutex> lk(g_lastEndMx);
            g_lastEnd.isPosZeroNoErr = (endPos == 0.0 && endPlayed == 0 && endErr.empty());
            g_lastEnd.file = endCur;
            g_lastEnd.tp = std::chrono::steady_clock::now();
        }
        if (ps.stop.load() || !done) break;

        std::lock_guard<std::mutex> lk(g_q.mtx);
        if (g_q.mode == 2) continue;                       // 单曲循环
        if (g_q.mode == 3) {                               // 随机：随机挑一首不等于当前的
            if (g_q.items.size() <= 1) continue;
            size_t pick = idx;
            for (int tries = 0; tries < 8 && pick == idx; ++tries)
                pick = (size_t)(std::rand() % (int)g_q.items.size());
            if (pick == idx) pick = (idx + 1) % g_q.items.size();   // 兜底：确定性前进一首
            idx = pick; continue;
        }
        if (idx + 1 < g_q.items.size()) { idx += 1; continue; }
        if (g_q.mode == 1) { idx = 0; continue; }
        break;
    }
    ps.playing = false;
}

// ---------------- 播放中切换 EQ/IR 的热重载（2026-10-25「耳机 EQ 切了没变化」核心修复）----------------
// 为什么必须有这一步（用户原话「耳机 EQ 切换之后，感觉没什么变化」）：
//   EQ 链是在 play_one 开头**一次性**从 p.eqFile 建进 Pipeline 的，之后播放线程再也不会看它。
//   所以用户在设置页点「应用到 EQ」换预设时，正在播的这一首 100% 不会有任何变化 ——
//   这不是听感玄学，是代码里根本没有热更新路径。用户在「边听边对比」这个最自然的用法下，
//   得到的就是"切了没变化"。
//
// 修法：换 EQ = 换一条管线。停旧线程 → 用新 eqFile 从**同一位置**起重播。
//   * 位置用 frac（played/total）算，由 start_pos_for 同时定 pos 与 played，
//     进度条与声音不会互相矛盾；
//   * frac 太靠近开头/结尾（<0.5% / >99%）时直接从头播 —— 那种位置"从头"与"接着播"
//     听不出差别，反而不该为它多写一条路径。
// 返回 true = 真的重启了播放线程（调用方据此在 JSON 里回 hotReload）。
static bool eq_hot_reload(const PlayParams& pNew, double frac, const char* why) {
    auto& ps = g_ps;
    // 只有「本地播放中」才热重载：UPnP 投放由渲染器解码，本机管线根本没参与；
    // 没在播就什么都不用做（下次起播自然会读到新设置）。
    if (!ps.playing.load() || g_upnpPlayer.load()) return false;
    size_t curIdx = 0;
    bool haveItem = false;
    {
        std::lock_guard<std::mutex> lk(g_q.mtx);
        if (!g_q.items.empty()) {
            curIdx = (g_q.index < g_q.items.size()) ? g_q.index : 0;
            haveItem = true;
        }
    }
    if (!haveItem) return false;

    PlayParams p = pNew;
    const bool keepPos = (frac > 0.005 && frac < 0.99);
    p.initialSeekFrac = keepPos ? frac : -1.0;

    // 停旧管线（协作：置 stop 让 queue_thread 自己退，绝不 force-kill —— 铁律 2）
    ps.stopJoin();
    // 重启期间的瞬态必须是"可解释的"，否则前端会把这一刻读成"播完了/出错了"
    // ★ seekReq 同时承担两件事，缺一不可：
    //   ① 旧管线残留的跳转请求必须作废（-1），否则新管线一起来就先跳一次；
    //   ② 保留位置时**必须**再置一次 frac —— render_loop 内部的 played 是它自己的局部量
    //      （从 0 开始数，每次写设备就 ps.played.store(局部值)），不喂 seekReq 的话
    //      它会把刚设好的"从 50% 起"覆盖成"从 0 起" ⟹ 声音在 50%、进度条在 0%，自相矛盾。
    //      seekReq 的处理恰好就是 played = frac*totalOut + seekFrame = frac*inFrames，
    //      与 start_pos_for 同一口径（render_loop.h 在别的子代理手上，这里不去改它）。
    ps.seekReq.store(keepPos ? frac : -1.0);
    ps.pauseReq.store(false);
    ps.paused.store(false);
    ps.played.store(0);
    ps.total.store(0);
    ps.playing.store(true);
    {
        std::ostringstream es;
        es.setf(std::ios::fixed); es.precision(4);
        es << "EQ_RELOAD reason=" << (why ? why : "eq-changed")
           << " idx=" << curIdx
           << " frac=" << p.initialSeekFrac
           << " eq=" << (p.eqFile.empty() ? "(none)" : p.eqFile)
           << " ir=" << (p.convIr.empty() ? "(none)" : p.convIr);
        play_log(es.str());
    }
    ps.restart([p, curIdx] { return queue_thread(p, curIdx); });
    return true;
}

// ---------------- HTTP 处理 ----------------
static std::string page();

// F3：端点探活缓存。probe_formats 对 16/24/32 各跑一遍独占支持率（每端点最多约 1s），
// 而 webui 是单线程 accept —— /api/diag 每次实时探活会让期间的全部 API 排队。
// 这里按端点 id 缓存探活结果，TTL 60s；?refresh=1 强制重探。

// ---------------- DeepSeek API Key（2026-10-22 功能4）----------------
// 用户原话：「元数据没有提供 ds 的 api 输入接口（就默认 deepseek）」。
//
// 红线（本端点存在的唯一理由）：
//   * key 绝不进源码、绝不进安装包 —— 只落在 exe 同目录 rlplayer-llm.conf；
//   * 界面【只显示掩码】，GET 不返回明文；POST 只写不读；
//   * 写 conf 时保留既有行（proxy= / 注释）—— 走 llm_config_save_merge，
//     不是整文件重写的 llm_config_save；
//   * 测试连接的错误一律过 llm_redact，服务端把 key 回显进错误文本也不会漏。
//
// 存哪里：rlplayer-llm.conf 与 enrich 的 llm_config_load 是同一份文件，
// 所以「界面填的 key」就是「补全时用的 key」，不存在第二个真相源。
static std::string llm_conf_path() { return path_in_exe_dir("rlplayer-llm.conf"); }

// 只读状态：是否已配置 + 掩码 + 模型/端点 + 代理行是否在。绝不返回 api_key 明文。
static std::string llm_status_json() {
    const rta::meta::LlmConfig c = rta::meta::llm_config_load(llm_conf_path());
    std::ostringstream j;
    j << "{\"ok\":true"
      << ",\"configured\":" << (c.apiKey.empty() ? "false" : "true")
      << ",\"masked\":\"" << jesc(rta::meta::llm_mask_key(c.apiKey)) << "\""
      << ",\"model\":\"" << jesc(c.model) << "\""
      << ",\"baseUrl\":\"" << jesc(c.baseUrl) << "\""
      << ",\"path\":\"" << jesc(llm_conf_path()) << "\""
      << ",\"proxy\":" << (llm_conf_proxy_line().empty() ? "false" : "true")
      << ",\"monthlyCap\":" << c.monthlyCap
      << ",\"currentUsage\":" << rta::meta::llm_get_monthly_count(rta::meta::llm_current_month(), c.usagePath)
      << "}";
    return j.str();
}

// key/值合法性：长度上限 + 不允许控制字符与空格（粘进来的 key 常带换行/空格，
// 写进 conf 会把文件结构弄坏，读的时候又被 trim 掉，症状极难查）。
static bool llm_value_ok(const std::string& v, size_t maxLen) {
    if (v.size() > maxLen) return false;
    for (unsigned char c : v) {
        if (c < 0x20 || c == 0x7f) return false;
        if (c == ' ') return false;
    }
    return true;
}

// 「测试连接」：最小一次 chat 请求（max_tokens=8），只判「key 有效」。
// 单独用 15s 超时而不是 llm_chat 的 60s —— 这是交互按钮，不能让设置页转一分钟。
// 返回体只带模型/耗时/token 数：reply 内容对用户没用，反而多一个可能夹带信息的面。
static std::string llm_test_json() {
    const rta::meta::LlmConfig c = rta::meta::llm_config_load(llm_conf_path());
    if (c.apiKey.empty())
        return "{\"ok\":false,\"error\":\"尚未配置 API Key\"}";
    const std::string body = rta::meta::llm_build_chat_body(
        c.model, { rta::meta::LlmMessage{"user", "ping"} }, 8, 0.0f, false);
    const auto t0 = std::chrono::steady_clock::now();
    const rta::net::HttpResponse resp = rta::net::http_post(
        rta::meta::llm_base_url(c.baseUrl) + "/chat/completions", body,
        { "Authorization: Bearer " + c.apiKey }, "application/json", 15000);
    const long long ms = (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();
    const std::string text(resp.body.begin(), resp.body.end());
    if (resp.status == 0) {
        const std::string e = rta::meta::llm_redact(c.apiKey, "网络请求失败: " + resp.error);
        return "{\"ok\":false,\"error\":\"" + jesc(e) + "\",\"latencyMs\":" + std::to_string(ms) + "}";
    }
    const rta::meta::LlmReply p = rta::meta::llm_parse_chat_response(text);
    if (resp.status < 200 || resp.status >= 300) {
        const std::string e = rta::meta::llm_redact(c.apiKey,
            "HTTP " + std::to_string(resp.status) + (p.error.empty() ? "" : ": " + p.error));
        return "{\"ok\":false,\"error\":\"" + jesc(e) + "\",\"latencyMs\":" + std::to_string(ms) + "}";
    }
    if (!p.ok) {
        const std::string e = rta::meta::llm_redact(c.apiKey, p.error);
        return "{\"ok\":false,\"error\":\"" + jesc(e) + "\",\"latencyMs\":" + std::to_string(ms) + "}";
    }
    return "{\"ok\":true,\"model\":\"" + jesc(c.model) + "\",\"latencyMs\":" +
           std::to_string(ms) + ",\"tokens\":" + std::to_string(p.totalTokens) + "}";
}

// 简介返回 JSON 附带「实体种类 / 是否来自缓存」标志（2026-10-23 用户 261023-03 #2/#3）：
// 前端据此决定加载态与是否重复请求；summary_to_json 本体是缓存文件格式，不掺入运行时标志。
static std::string summary_json_with_flags(const rta::meta::SummaryResult& sr,
                                           const std::string& kind, bool cached) {
    std::string js = rta::meta::summary_to_json(sr);
    const size_t close = js.find_last_of('}');
    if (close == std::string::npos) return js;
    js.insert(close, ",\"summaryKind\":\"" + jesc(kind) + "\",\"summaryCached\":" +
                     (cached ? "true" : "false") + ",\"summaryAvailable\":true");
    return js;
}

// ---------------- 资料简介后台生成（不阻塞单线程 HTTP accept）----------------
// 背景（2026-10-23 DEBUG 定位）：WebUi 是单线程阻塞 accept，/api/entity/summary 原先在 handler 里
// 同步跑 Wikipedia + Discogs + ds_search + LLM 综合，最坏可达数十秒；期间前端 400ms 一次的 /api/status
// 以及播放/暂停/音量/seek 全部排队 → 用户看到的是「整个界面卡死」。
// 现在：缓存命中仍然同步秒回；未命中则立即返回 {"pending":true} 并起后台线程，前端轮询同一 URL 取结果。
struct SummaryJob {
    bool running = false;
    bool done = false;
    bool ok = false;
    std::string body;
    long long started_at = 0;
    long long finished_at = 0;
};
static std::mutex g_summ_mu;
static std::map<std::string, SummaryJob> g_summ_jobs;

// 通用后台任务：work 里跑检索/综合，完成后把 JSON 放进 job 表，由前端轮询取走。
static void summary_job_start_fn(const std::string& key, const std::string& kindStr,
                                 const std::string& label,
                                 std::function<rta::meta::SummaryResult()> work) {
    bg_job_begin();     // 登记：stop_embedded 会等它收完（有界，超时如实记日志）
    std::thread([key, kindStr, label, work]() {
        const rta::meta::SummaryResult sr = work();
        std::string body;
        if (!sr.ok) {
            play_log("SUMMARY failed kind=" + kindStr + " name=" + label + " err=" + sr.error);
            body = "{\"ok\":false,\"error\":\"" + jesc(sr.error.empty() ? "资料整理失败" : sr.error) +
                   "\",\"summaryKind\":\"" + jesc(kindStr) + "\",\"summaryCached\":false}";
        } else {
            play_log("SUMMARY generated kind=" + kindStr + " name=" + label + " eid=" + key +
                     " fromCache=" + std::string(sr.from_cache ? "1" : "0") +
                     " unverified=" + std::string(sr.unverified ? "1" : "0") +
                     // 2026-10-24（261024-02 #1/#7）：分阶段耗时（search/fetch/llm），用于回答"为什么慢"
                     (sr.diag.empty() ? std::string() : (" diag=" + sr.diag)));
            body = summary_json_with_flags(sr, kindStr, sr.from_cache);
        }
        {
            std::lock_guard<std::mutex> lk(g_summ_mu);
            auto& job = g_summ_jobs[key];
            job.running = false;
            job.done = true;
            job.ok = sr.ok;
            job.body = body;
            job.finished_at = (long long)std::time(nullptr);
        }   // 锁必须先放，再登记结束（否则 bg_job_end 里的 g_bgMx 与 g_summ_mu 顺序无保证）
        bg_job_end();
    }).detach();
}

static void summary_job_start(const std::string& key, rta::meta::EntityKind ek, const std::string& name,
                              const std::string& lang, const std::string& kindStr,
                              const rta::meta::RetrievalOptions& ropts) {
    summary_job_start_fn(key, kindStr, name, [ek, name, lang, ropts]() {
        return rta::meta::retrieval_fetch(ek, name, lang, ropts);
    });
}

// ---------------------------------------------------------------------------
// 副作用端点必须 POST（2026-10-25，外部评审 P1#6）
//
// 背景（实测，build-dbg-net http_probe）：
//   GET /api/fav?file=...&on=1      → 200，并且真的写进 rlplayer-favs.json
//   GET /api/pl/save?name=x         → 建 playlists\x.m3u8
//   GET /api/lib/remove?path=<dir>  → 200，剔除记录并落盘
//   GET /api/lib/scan / prune / quit / play / settings …
// 全部可被一个 <img src="http://127.0.0.1:8899/api/lib/remove?path=D:\Music"> 触发 ——
// 因为 handler 从不看 method，而 WebUi 单线程 accept 对所有响应都回 200。
//
// 最小修法（不动前端：前端本来就一律用 fetch POST 调这些端点，见 ui_script.h 的 api()）：
//   ① 这张表里的端点只接受 POST（GET 一律 405 + JSON）；
//   ② 主页面 / 静态资源仍然是 GET。
// 只读端点（status/albums/diag/…）不受影响。
// ---------------------------------------------------------------------------
static bool is_side_effect_path(const std::string& p) {
    static const char* kNeedPost[] = {
        "/api/play", "/api/pause", "/api/stop", "/api/seek", "/api/skip", "/api/volume",
        "/api/clear", "/api/repeat", "/api/shuffle", "/api/add", "/api/qdel", "/api/qmove",
        "/api/qorder", "/api/qsort", "/api/queue/set", "/api/sq",
        "/api/fav", "/api/pl", "/api/lib/scan", "/api/lib/prune", "/api/lib/remove",
        "/api/lib/roots", "/api/rescan", "/api/quit", "/api/shutdown", "/api/settings",
        "/api/writeback", "/api/enrich", "/api/peq", "/api/opra/apply", "/api/cast/start",
        "/api/cast/stop", "/api/upnp", "/api/src", "/api/input/start", "/api/input/stop",
        "/api/buffer/reset", "/api/upload",
        // CPU-intensive analysis must not be triggered by an incidental GET.
        "/api/compare",
        // Room measurement plays an audible sweep: a stray GET must never start it.
        "/api/roomcorr/measure", "/api/roomcorr/cancel",
        // 预设的 apply 会写 rlplayer-settings.conf（副作用）；caps 是只读查询，不进这张表
        "/api/preset/apply",
        // 专辑封面预热（2026-10-26）：会落盘 covercache + 打网络。
        // 只读端点是 /api/lib/cover（单张）与 /api/lib/cover/progress（进度）。
        "/api/lib/cover/prefetch", "/api/lib/cover/set",
    };
    for (const char* k : kNeedPost) {
        const size_t n = std::strlen(k);
        if (p.compare(0, n, k) != 0) continue;
        // 前缀必须"整段"命中：/api/pause 不能匹配到 /api/pauses
        if (p.size() == n) return true;
        const char c = p[n];
        if (c == '/' || c == '?' || c == '&') return true;
    }
    return false;
}

// 只读白名单里的例外：这些端点在**同名前缀**下是查询语义，必须继续允许 GET。
// （/api/fav/list、/api/peq 的 GET 现状、/api/writeback 的 GET 预览、/api/settings 的 GET 读取）
static bool is_side_effect_exempt(const std::string& p) {
    static const char* kGetOk[] = {
        "/api/fav/list", "/api/pl/load", "/api/sq/list", "/api/sq/info", "/api/writeback/status", "/api/writeback/dry", "/api/src/browse",
        "/api/src/search", "/api/src/cover", "/api/lib/status", "/api/lib/stats",
        "/api/lib/albums", "/api/lib/album", "/api/lib/search", "/api/lib/cover",
        // /api/llm：GET = 读配置状态（已配置 + 掩码），POST = 保存；状态读取必须允许 GET。
        "/api/llm", "/api/llm/test",
    };
    // ★ 例外中的例外（2026-10-26）：白名单是按**前缀**放的，而 "/api/lib/cover" 下面还有
    //   /api/lib/cover/prefetch —— 它会落盘 covercache 并打网络，绝不能因为前缀相同而放行 GET。
    //   （一个 <img src=.../api/lib/cover/prefetch> 就能让整库去联网，正是这张表当年要防的事。）
    //   这条是 B-6 记录的同类缺陷：新增 /api/x 时必须检查是否已存在 /api/x 的兄弟端点。
    if (p.rfind("/api/lib/cover/prefetch", 0) == 0) return false;
    if (p.rfind("/api/lib/cover/set", 0) == 0) return false;
    for (const char* k : kGetOk) if (p.rfind(k, 0) == 0) return true;
    return false;
}

static std::string handle(const rta::net::HttpRequest& rq, std::string& ct) {
    auto& ps = g_ps;

    // ---- 副作用端点强制 POST（见上方注释）----
    // ★ GET 副作用判定不是"查表就完"，还要看参数：
    //   * /api/writeback 的 GET 是**纯只读预览**（writeback_preview_scan，不跑 ffmpeg、不写文件）；
    //   * /api/settings 的 GET 只是读当前设置（POST 才落盘）；
    //   * /api/peq 的 GET 只读状态（POST 才热更新+落盘）；
    //   带显式副作用参数（dry=0 / apply=1 / action=…）的 GET 一律仍按副作用处理。
    auto hasSideEffectQuery = [&](const std::string& p) {
        const size_t q = p.find('?');
        if (q == std::string::npos) return false;
        const std::string qs = p.substr(q);
        auto has = [&](const char* needle) { return qs.find(needle) != std::string::npos; };
        if (has("apply=1") || has("apply=true")) return true;
        if (has("action=")) return true;
        if (p.rfind("/api/writeback", 0) == 0 && !has("dry=1") && !has("dry=true") && qs.size() > 1) return true;
        return false;
    };
    auto getReadOnlyOk = [&](const std::string& p) {
        if (hasSideEffectQuery(p)) return false;
        if (p.rfind("/api/writeback", 0) == 0) return p.rfind("/api/writeback/status", 0) != 0;  // 预览端点
        if (p.rfind("/api/settings", 0) == 0) return true;
        if (p.rfind("/api/peq", 0) == 0) return p.rfind("/api/peq/preset", 0) != 0;
        return false;
    };
    // 注意：/api/fav 既要有 GET 列表（/api/fav/list）又要有 POST 切换，所以先判豁免。
    if (!is_side_effect_exempt(rq.path) && !getReadOnlyOk(rq.path) &&
        is_side_effect_path(rq.path) && rq.method != "POST") {
        ct = "application/json; charset=utf-8";
        rta::net::webui_set_status(405);   // 状态行由 webui 写（见 webui.h 的 webui_set_status）
        return std::string("{\"ok\":false,\"error\":\"Method Not Allowed：") +
               (rq.method.empty() ? std::string("?") : rq.method) +
               " 不支持，" + rq.path.substr(0, rq.path.find('?')) + " 只接受 POST\"}";
    }

    if (rq.path.rfind("/favicon", 0) == 0) {
        ct = "image/png";
        return std::string(reinterpret_cast<const char*>(rta::net::kAppIconPng), rta::net::kAppIconPngSize);
    }
    if (rq.path.rfind("/app.js", 0) == 0) {
        ct = "application/javascript; charset=utf-8";
        return std::string(rta::net::rta_ui_script());
    }
    if (rq.path == "/" || rq.path == "/index.html") {
        ct = "text/html; charset=utf-8";
        return page();
    }

    if (rq.path.rfind("/api/files", 0) == 0) {
        ct = "application/json; charset=utf-8";
        // 默认位置：音乐库的第一个根目录（而不是磁盘根 —— 那样打开就是空的）
        //
        // 2026-10-26 BUG 修复（根因 c，用户截图「点文件夹显示目录不存在」的最后一环）：
        //   原来无脑取 roots().front()，拿到就直接 exists 判定，不存在就报「目录不存在」。
        //   conf 里一旦存了相对根（./data），.app 双击启动 cwd=/ ⟹ ./data 解析成 /data ⟹
        //   永远不存在 ⟹ 用户点「文件夹」永远看到「目录不存在」，而曲库照样能播（索引里
        //   69 首都在），现象极其割裂。
        //   现在：不带 ?dir= 时按 roots 顺序挑**第一个真实存在**的根；一个都不存在才回退
        //   $HOME（见下）。用户**显式**传了 ?dir=X 而 X 不存在时仍然如实报错（不偷换目录），
        //   否则用户会以为自己的目录被打开了，实际看的是别处。
        std::string dir;
        const size_t q = rq.path.find("?dir=");
        if (q != std::string::npos) dir = urlDecode(rq.path.substr(q + 5));
        if (dir.empty()) {
            const auto roots = Library::instance().roots();
            std::error_code rec;
            for (const auto& r : roots) {
                // 坏根（相对路径 / 已删除 / 外接盘掉线）跳过，继续找下一个真实存在的
                if (fs::is_directory(r, rec)) { dir = r; break; }
            }
        }
        if (dir.empty()) {
            // 2026-10-25（默认目录纠正）：原来兜底写死 "C:\Users"，macOS 上这个路径
            // 不存在 ⟹ 文件浏览器打开就报「目录不存在」。
            // 现在按平台：macOS 落到 $HOME（用户主目录，一定有），Windows 保留原语义。
#if defined(__APPLE__)
            if (const char* home = std::getenv("HOME")) dir = home;
            if (dir.empty()) dir = "/Users";
#else
            dir = "C:\\Users";
#endif
        }
        if (!valid_utf8(dir)) return utf8_path_reject(dir);   // F1：目录名进 fs 前先校验

        std::error_code ec;
        // 2026-10-26：错误信息必须**带上路径**。原来只说「目录不存在」，把根因藏起来 ——
        //   用户/我们根本看不出是哪个目录坏了（本 BUG 里真正坏的是 conf 里的相对根
        //   "./data"，但界面只显示一句没有主语的「目录不存在」，所以一直排查不动）。
        if (!fs::is_directory(dir, ec)) {
            return "{\"ok\":false,\"error\":\"" + jesc("目录不存在: " + dir) + "\"}";
        }
        std::vector<std::string> dirs, files;
        for (auto& e : fs::directory_iterator(dir, fs::directory_options::skip_permission_denied, ec)) {
            const std::string name = pathToUtf8(e.path().filename());
            if (!name.empty() && name[0] == '.') continue;
            std::string ext = pathToUtf8(e.path().extension());
            std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
            if (e.is_directory(ec)) dirs.push_back(name);
            else {
                static const char* kAudioExt[] = {
                    ".wav", ".wave", ".flac", ".alac", ".m4a", ".mp3", ".aac", ".ogg", ".opus",
                    ".wma", ".ape", ".wv", ".dsf", ".dff", ".aif", ".aiff", ".aifc", ".caf", ".mka"
                };
                for (const char* x : kAudioExt) if (ext == x) { files.push_back(name); break; }
            }
        }
        std::sort(dirs.begin(), dirs.end());
        std::sort(files.begin(), files.end());

        std::ostringstream j;
        j << "{\"ok\":true,\"dir\":\"" << jesc(dir) << "\",\"dirs\":[";
        for (size_t i = 0; i < dirs.size(); ++i) { if (i) j << ","; j << "\"" << jesc(dirs[i]) << "\""; }
        j << "],\"files\":[";
        for (size_t i = 0; i < files.size(); ++i) { if (i) j << ","; j << "\"" << jesc(files[i]) << "\""; }
        j << "]}";
        return j.str();
    }

    // ---------------- 本地音乐库（专辑 / 艺术家 / 搜索）----------------
    // 设计取向参考 Roon：以「专辑」为一等公民，而不是让用户翻目录树。
    // ---- 单曲音质体检（F-5 接线；2026-10-27）----
    // GET /api/track/health?file=<绝对路径>[&force=1]
    // 返回 track_health_json() 的全部字段（含 quality 19 项）。
    // 为什么走这个端点而不是让前端自己算：分析是 CPU 密集（DSD 几百 MB），
    // 必须在服务端跑；前端只负责把数字画出来。
    // ⚠️ 只读端点：不改文件、不写缓存以外的东西（缓存由 health_store 管）。
    // ---- 艺人头像（F-4 / R-6；2026-10-27）----
    // GET /api/artist/image?who=<艺人名>[&refresh=1]
    //   200 + 图片字节（Content-Type 按魔数定）—— 命中
    //   404 + JSON 原因                      —— 没找到（前端 onerror 露回首字母）
    // 为什么只保留这一个端点（不另加 /api/artist/apifill）：
    //   两处真相会打架（HANDOVER §4.5）。头像的「多源」由 artwork.h 的能力矩阵统一调度，
    //   调用方永远只问这一个 URL，源顺序的调整不需要改前端。
    // 缓存：用 runtime_state_dir()/artistcache（与 covercache 同风格），绝不写进 .app 包内。
    if (rq.path.rfind("/api/artist/image", 0) == 0) {
        std::string who;
        bool refresh = false;
        {
            const size_t q = rq.path.find("?who=");
            if (q != std::string::npos) {
                std::string rest = rq.path.substr(q + 5);
                const size_t amp = rest.find("&refresh=");
                if (amp != std::string::npos) {
                    refresh = rest.compare(amp + 9, 1, "1") == 0;
                    rest = rest.substr(0, amp);
                }
                who = urlDecode(rest);
            }
        }
        if (who.empty()) {
            ct = "application/json; charset=utf-8";
            rta::net::webui_set_status(400);
            return "{\"ok\":false,\"error\":\"未指定 who\"}";
        }
        if (!valid_utf8(who)) return utf8_path_reject(who);
        rta::meta::ArtworkOpts aopts;
        aopts.cacheDir = path_in_exe_dir("artistcache");
        aopts.useCache = !refresh;
        // 源开关沿用既有设置（与 /api/enrich 同一套 srcOn 语义：
        // MetaSettings.srcOn 是「注册表 id → 开关」，缺省 true，不要写死具体源名）
        aopts.srcOn = meta_settings_load().srcOn;
        const rta::meta::ArtistImageResult r = rta::meta::artwork_fetch_artist_image(who, aopts);
        if (!r.ok || r.bytes.empty()) {
            ct = "application/json; charset=utf-8";
            rta::net::webui_set_status(404);
            std::ostringstream j;
            j << "{\"ok\":false,\"who\":\"" << jesc(who) << "\",\"error\":\"未找到该艺人头像\""
              << ",\"tried\":[";
            for (size_t i = 0; i < r.tried.size(); ++i) {
                if (i) j << ",";
                j << "{\"src\":\"" << jesc(r.tried[i].source) << "\",\"ok\":"
                  << (r.tried[i].ok ? "true" : "false")
                  << ",\"reason\":\"" << jesc(r.tried[i].reason) << "\"}";
            }
            j << "]}";
            return j.str();
        }
        // Content-Type 按**魔数**定，不信 URL 后缀（错误页伪装成 .jpg 的情况真实存在）
        const unsigned char* b = (const unsigned char*)r.bytes.data();
        const size_t n = r.bytes.size();
        if (n >= 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') ct = "image/png";
        else if (n >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) ct = "image/jpeg";
        else {
            ct = "application/json; charset=utf-8";
            rta::net::webui_set_status(502);
            return "{\"ok\":false,\"error\":\"取回的内容不是有效图片（无 JPEG/PNG 魔数）\"}";
        }
        return r.bytes;
    }

    // ---------------- R-1 房间测量（铁律 1：确认前绝不发声）----------------
    // GET  /api/roomcorr/layouts          可选布局
    // GET  /api/roomcorr/plan?layout=&sec= 只读计划（设备/时长/电平/横幅），**不打开设备**
    // POST /api/roomcorr/measure?...&confirm=1  真正测量；缺 confirm 回 428
    // POST /api/roomcorr/cancel           取消
    // GET  /api/roomcorr/status           进度与结果
    if (rq.path.rfind("/api/roomcorr", 0) == 0) {
        ct = "application/json; charset=utf-8";
        static rta::dsp::RoomMeasureController s_room;
        auto qs = [&](const char* key) -> std::string {
            const std::string pat = std::string("?") + key + "=";
            size_t pos = rq.path.find(pat);
            if (pos == std::string::npos) {
                const std::string pat2 = std::string("&") + key + "=";
                pos = rq.path.find(pat2);
                if (pos == std::string::npos) return {};
                pos += pat2.size();
            } else {
                pos += pat.size();
            }
            const size_t end = rq.path.find('&', pos);
            return urlDecode(rq.path.substr(pos, end == std::string::npos ? std::string::npos : end - pos));
        };

        if (rq.path.rfind("/api/roomcorr/layouts", 0) == 0) {
            std::ostringstream j;
            j << "{\"ok\":true,\"layouts\":[";
            bool first = true;
            for (const auto& l : rta::dsp::room_layouts()) {
                if (!first) j << ",";
                first = false;
                j << "{\"name\":\"" << jesc(l.name ? l.name : "") << "\",\"ch\":" << l.chCount
                  << ",\"sub\":" << (l.sub ? "true" : "false") << "}";
            }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/roomcorr/plan", 0) == 0) {
            std::string layout = qs("layout");
            const std::string secs = qs("sec");
            double sec = secs.empty() ? 6.0 : atof(secs.c_str());
            std::string playDev, capDev;
            const auto devs = mac_enum_devices();
            for (const auto& d : devs) if (d.isDefault) { playDev = d.name; break; }
            const auto caps = rta::platform::CoreAudioInput::enumerate_capture(false);
            if (!caps.empty()) capDev = caps[0].name;
            const auto plan = rta::dsp::room_make_plan(layout, sec, 800.0, playDev, capDev);
            std::ostringstream j;
            j << "{\"ok\":" << (plan.ok ? "true" : "false")
              << ",\"error\":\"" << jesc(plan.error) << "\""
              << ",\"layout\":\"" << jesc(plan.layout) << "\""
              << ",\"chCount\":" << plan.chCount
              << ",\"sweepSeconds\":" << plan.sweepSeconds
              << ",\"totalSeconds\":" << plan.totalSeconds
              << ",\"levelDbfs\":" << plan.levelDbfs
              << ",\"playDevice\":\"" << jesc(plan.playDevice) << "\""
              << ",\"captureDevice\":\"" << jesc(plan.captureDevice) << "\""
              << ",\"warning\":\"" << jesc(plan.warning) << "\""
              << ",\"needsConfirm\":true}";
            if (!plan.ok) rta::net::webui_set_status(400);
            return j.str();
        }
        if (rq.path.rfind("/api/roomcorr/cancel", 0) == 0) {
            s_room.cancel();
            return "{\"ok\":true,\"cancelling\":true}";
        }
        if (rq.path.rfind("/api/roomcorr/status", 0) == 0) {
            const auto snap = s_room.snapshot();
            static const char* kPhase[] = { "idle", "running", "done", "failed", "cancelled" };
            const int pi = (int)snap.phase;
            std::ostringstream j;
            j << "{\"ok\":true,\"phase\":\"" << kPhase[(pi >= 0 && pi <= 4) ? pi : 0] << "\""
              << ",\"layout\":\"" << jesc(snap.layout) << "\""
              << ",\"channelsTotal\":" << snap.channelsTotal
              << ",\"channelsDone\":" << snap.channelsDone
              << ",\"currentChannel\":\"" << jesc(snap.currentChannel) << "\""
              << ",\"error\":\"" << jesc(snap.error) << "\""
              << ",\"aborted\":" << (snap.aborted ? "true" : "false")
              << ",\"subDelaySamples\":" << snap.subDelaySamples
              << ",\"subGainDb\":" << snap.subGainDb
              << ",\"channels\":[";
            for (size_t i = 0; i < snap.channels.size(); ++i) {
                if (i) j << ",";
                const auto& c = snap.channels[i];
                j << "{\"name\":\"" << jesc(c.channelName) << "\""
                  << ",\"valid\":" << (c.valid ? "true" : "false")
                  << ",\"snrDb\":" << c.snrDb
                  << ",\"peakMs\":" << c.peakMs
                  << ",\"note\":\"" << jesc(c.note) << "\"}";
            }
            j << "],\"warnings\":[";
            for (size_t i = 0; i < snap.warnings.size(); ++i) {
                if (i) j << ",";
                j << "\"" << jesc(snap.warnings[i]) << "\"";
            }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/roomcorr/measure", 0) == 0) {
            const std::string confirm = qs("confirm");
            std::string layout = qs("layout");
            const std::string secs = qs("sec");
            const double sec = secs.empty() ? 6.0 : atof(secs.c_str());
            std::string playDev, capDev;
            const auto devs = mac_enum_devices();
            for (const auto& d : devs) if (d.isDefault) { playDev = d.name; break; }
            const auto caps = rta::platform::CoreAudioInput::enumerate_capture(false);
            if (!caps.empty()) capDev = caps[0].name;
            const auto plan = rta::dsp::room_make_plan(layout, sec, 800.0, playDev, capDev);
            std::string err;
            const bool confirmed = (confirm == "1" || confirm == "true");
            if (!s_room.start(plan, confirmed, err)) {
                rta::net::webui_set_status(confirmed ? 400 : 428);
                return std::string("{\"ok\":false,\"needsConfirm\":") +
                       (confirmed ? "false" : "true") + ",\"error\":\"" + jesc(err) + "\"}";
            }
            // 会话在线程里跑（扫频最长几十秒，不能堵住 accept）。
            bg_job_begin();
            std::thread([plan]() {
                try {
                    rta::dsp::RoomTxConfig cfg;
                    cfg.rate = 48000;
                    cfg.channels = plan.chCount;
                    rta::dsp::CoreAudioRoomTransport tx(cfg);
                    rta::dsp::SweepSpec spec;
                    spec.fs = 48000;
                    spec.f0 = 40.0;
                    spec.f1 = 18000.0;
                    spec.durSec = plan.sweepSeconds;
                    rta::dsp::RoomLayout layout{};
                    layout.name = plan.layout.c_str();
                    const auto all = rta::dsp::room_layouts();
                    for (const auto& l : all)
                        if (plan.layout == (l.name ? l.name : "")) { layout = l; break; }
                    tx.cancelled = [] { return false; };
                    rta::dsp::MeasurementSession session(spec, layout, plan.levelDbfs);
                    const auto res = session.run(tx);
                    s_room.finish(res);
                    if (!tx.lastOk() && res.channels.empty())
                        s_room.fail(tx.lastError().empty() ? "测量失败" : tx.lastError());
                } catch (const std::exception& e) {
                    s_room.fail(std::string("测量异常：") + e.what());
                }
                bg_job_end();
            }).detach();
            return "{\"ok\":true,\"started\":true,\"warning\":\"" + jesc(plan.warning) + "\"}";
        }
        return "{\"ok\":false,\"error\":\"unknown roomcorr api\"}";
    }

    // F-8: call both the analyzer and scorer; importing the header alone exposes no feature.
    if (rq.path == "/api/compare") {
        ct = "application/json; charset=utf-8";
        std::vector<std::string> files;
        if (!rq.body.empty() && rq.body.find_first_not_of(" \t\r\n") != std::string::npos &&
            rq.body[rq.body.find_first_not_of(" \t\r\n")] == '{') {
            const auto doc = rta::net::json_parse(rq.body);
            const auto& paths = doc["files"];
            for (size_t i = 0; i < paths.size(); ++i) {
                if (paths.at(i).type != rta::net::Json::Str)
                    return "{\"ok\":false,\"error\":\"files 必须为路径字符串数组\"}";
                files.push_back(paths.at(i).s());
            }
        } else {
            std::istringstream form(rq.body);
            std::string part;
            while (std::getline(form, part, '&')) {
                const size_t eq = part.find('=');
                if (eq == std::string::npos) continue;
                const std::string key = urlDecode(part.substr(0, eq));
                if (key == "file") files.push_back(urlDecode(part.substr(eq + 1)));
            }
        }
        if (files.size() < 2 || files.size() > 8)
            return "{\"ok\":false,\"error\":\"请选择 2～8 个版本\"}";
        for (const auto& file : files) {
            if (!valid_utf8(file)) return utf8_path_reject(file);
            std::error_code ec;
            if (file.find('\0') != std::string::npos || !fs::is_regular_file(fs::u8path(file), ec) || ec)
                return "{\"ok\":false,\"error\":\"对比文件不存在或不是普通文件\"}";
        }
        // Bound concurrent analysis without serializing unrelated player requests.
        static std::mutex compareMutex;
        std::unique_lock<std::mutex> lock(compareMutex, std::try_to_lock);
        if (!lock.owns_lock()) {
            rta::net::webui_set_status(503);
            return "{\"ok\":false,\"error\":\"已有版本对比正在分析，请稍后重试\"}";
        }
        try {
            auto result = rta::analysis::compare_versions(files);
            rta::analysis::score_versions(result);
            return rta::analysis::version_compare_json(result);
        } catch (const std::exception& e) {
            return std::string("{\"ok\":false,\"error\":\"") + jesc(e.what()) + "\"}";
        }
    }

    if (rq.path.rfind("/api/track/health", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string file;
        bool force = false;
        {
            const size_t q = rq.path.find("?file=");
            if (q != std::string::npos) {
                std::string rest = rq.path.substr(q + 6);
                const size_t amp = rest.find("&force=");
                if (amp != std::string::npos) {
                    force = rest.compare(amp + 7, 1, "1") == 0;
                    rest = rest.substr(0, amp);
                }
                file = urlDecode(rest);
            }
        }
        if (file.empty()) return "{\"ok\":false,\"error\":\"未指定文件\"}";
        if (!valid_utf8(file)) return utf8_path_reject(file);
        std::error_code ec;
        if (!fs::exists(fs::u8path(file), ec) || ec)
            return std::string("{\"ok\":false,\"error\":\"文件不存在\"}");
        (void)force;   // 缓存策略由 health_store 按 mtime/size 判定，端点不越权清缓存
        // 文件级入口保证不抛异常（解码失败落 status=error + 人话原因），
        // 所以这里不需要 try/catch 兜底。
        const rta::analysis::TrackHealth h = rta::analysis::analyze_file(file);
        return std::string("{\"ok\":true,\"health\":") +
               rta::analysis::track_health_json(h) + "}";
    }

    if (rq.path.rfind("/api/lib", 0) == 0) {
        ct = "application/json; charset=utf-8";
        auto& lib = Library::instance();

        // ---- 状态查询（261025-01 一.1：扫描期间必须 <50ms 返回）----
        // 两个端点共用无锁快照（Library::snapshot()）：只读原子量 + 一次短锁读进度文本，
        // 绝不触发专辑整理、绝不排队等扫描线程持有的 mtx_。
        // /api/lib/status 是给"轮询进度"用的窄端点；/api/lib/stats 保留原字段（含 roots）。
        if (rq.path.rfind("/api/lib/status", 0) == 0) {
            const auto s = lib.snapshot();
            std::ostringstream j;
            j << "{\"ok\":true"
              << ",\"scanning\":" << (s.scanning ? "true" : "false")
              << ",\"scanned\":" << s.scanned
              << ",\"total\":" << s.total
              << ",\"tracks\":" << s.tracks
              << ",\"albums\":" << s.albums
              << ",\"lastScanMs\":" << s.lastScanMs
              << ",\"probed\":" << s.probed
              << ",\"cached\":" << s.cached
              << ",\"removed\":" << s.removed
              << ",\"msg\":\"" << jesc(s.msg) << "\"}";
            return j.str();
        }
        if (rq.path.rfind("/api/lib/stats", 0) == 0) {
            std::ostringstream j;
            const auto roots = lib.roots();
            const auto s = lib.snapshot();
            const size_t albums = (s.albums > 0 || s.scanning) ? s.albums : lib.albumCount();
            j << "{\"ok\":true,\"tracks\":" << s.tracks
              << ",\"albums\":" << albums
              << ",\"scanning\":" << (s.scanning ? "true" : "false")
              << ",\"scanned\":" << s.scanned
              << ",\"total\":" << s.total
              << ",\"scanThreads\":" << lib.scanThreads()
              << ",\"lastScanMs\":" << s.lastScanMs
              << ",\"probed\":" << s.probed
              << ",\"cached\":" << s.cached
              << ",\"removed\":" << s.removed
              << ",\"msg\":\"" << jesc(s.msg) << "\",\"roots\":[";
            for (size_t i = 0; i < roots.size(); ++i) { if (i) j << ","; j << "\"" << jesc(roots[i]) << "\""; }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/lib/scan", 0) == 0 || rq.path.rfind("/api/rescan", 0) == 0) {
            const bool full = rq.body.find("full=1") != std::string::npos || rq.path.rfind("/api/rescan", 0) == 0;
            static std::atomic<int> s_scanSeq{0};
            const std::string lg = "LIBSCAN req #" + std::to_string(s_scanSeq.fetch_add(1) + 1) +
                     std::string(" full=") + (full ? "1" : "0");
            play_log(lg);
            dlog(lg);
            lib.startScan(full);
            return "{\"ok\":true}";
        }
        // ---- 清理（261025-01 一.3：删掉的文件的记录必须能清掉）----
        if (rq.path.rfind("/api/lib/prune", 0) == 0) {
            const auto r = lib.pruneMissing();
            dlog("LIBSCAN prune removed=" + std::to_string(r.removed) + " tracks=" + std::to_string(r.tracks));
            return "{\"ok\":true,\"removed\":" + std::to_string(r.removed) +
                   ",\"tracks\":" + std::to_string(r.tracks) + "}";
        }
        if (rq.path.rfind("/api/lib/remove", 0) == 0) {
            std::string p;
            size_t q = rq.path.find("?path=");
            if (q == std::string::npos) q = rq.path.find("&path=");
            if (q != std::string::npos) {
                p = rq.path.substr(q + 6);
                const size_t amp = p.find('&');
                if (amp != std::string::npos) p = p.substr(0, amp);
                p = urlDecode(p);
            }
            if (p.empty()) {
                // 也接受表单体 path=<dir>（POST 时更稳，避免超长 URL）
                std::istringstream is(rq.body);
                std::string tok;
                while (std::getline(is, tok, (char)38)) {
                    const size_t e = tok.find((char)61);
                    if (e == std::string::npos) continue;
                    if (urlDecode(tok.substr(0, e)) == "path") p = urlDecode(tok.substr(e + 1));
                }
            }
            if (p.empty()) return "{\"ok\":false,\"error\":\"未指定 path\"}";
            if (!valid_utf8(p)) return utf8_path_reject(p);
            const auto r = lib.removeUnder(p);
            dlog("LIBSCAN remove path=" + p + " removed=" + std::to_string(r.removed) +
                 " tracks=" + std::to_string(r.tracks));
            return "{\"ok\":true,\"removed\":" + std::to_string(r.removed) +
                   ",\"tracks\":" + std::to_string(r.tracks) + "}";
        }
        if (rq.path.rfind("/api/lib/roots", 0) == 0) {
            std::string add, rem;
            std::istringstream is(rq.body);
            std::string tok;
            while (std::getline(is, tok, (char)38)) {
                const size_t e = tok.find((char)61);
                if (e == std::string::npos) continue;
                const std::string kk = urlDecode(tok.substr(0, e));
                const std::string vv = urlDecode(tok.substr(e + 1));
                if (kk == "add") add = vv;
                else if (kk == "remove") rem = vv;
            }
            // 2026-10-26：addRoot 失败的原因不再一律说「目录不存在」。
            //   addRootEx 现在会因「非绝对路径 / 编码非 UTF-8 / 路径无法解析」而拒，
            //   把它们统统回成「目录不存在」会把用户引向错误的排查方向（本 BUG 就是这么被藏住的）。
            //   直接回传 ar.why，让前端 toast 出真正的原因。
            if (!add.empty()) {
                const auto ar = lib.addRootEx(add);
                if (!ar.ok) {
                    return "{\"ok\":false,\"error\":\"" + jesc(ar.why) + "\"}";
                }
            }
            // 反馈 #3「扫描记录不可消除」：移除库根必须连带清掉该目录（含子目录）扫出来的曲目，
            // 否则歌还留在列表里、点了播放就失败。removedTracks 让前端能如实告诉用户清掉了几首。
            int removedTracks = 0;
            bool removedRoot = false;
            if (!rem.empty()) {
                const int n = lib.removeRootEx(rem);
                removedRoot = (n >= 0);
                removedTracks = (n > 0) ? n : 0;
                if (!removedRoot) removedTracks = 0;
            }
            std::ostringstream j;
            j << "{\"ok\":true,\"removedRoot\":" << (removedRoot ? "true" : "false")
              << ",\"removedTracks\":" << removedTracks
              << ",\"tracks\":" << lib.trackCount() << "}";
            return j.str();
        }
        // 反馈 #4「目录删不掉」：真删磁盘目录，与「从库中移除」是两件不同的事（前者不碰磁盘）。
        // 安全约束全在 Library 里（库根之下 / 不是库根本身 / 拒绝符号链接），
        // 这里只负责参数校验与把「统计」如实回给前端做二次确认的落地校验。
        // ⚠️ 路由顺序：/api/lib/rmdirinfo 必须以 /api/lib/rmdir 为**前缀**匹配到，
        //    所以 rmdirinfo 的判定必须写在 rmdir 之前（否则永远走不进统计分支）。
        auto parse_dir_body = [&](const std::string& body) -> std::string {
            std::string dir;
            std::istringstream is(body);
            std::string tok;
            while (std::getline(is, tok, (char)38)) {
                const size_t e = tok.find((char)61);
                if (e == std::string::npos) continue;
                const std::string kk = urlDecode(tok.substr(0, e));
                const std::string vv = urlDecode(tok.substr(e + 1));
                if (kk == "dir") dir = vv;
            }
            return dir;
        };
        // 只统计、不删除：给前端二次确认弹窗提供「将删除 N 个文件」的真实数字。
        if (rq.path.rfind("/api/lib/rmdirinfo", 0) == 0) {
            const std::string dir = parse_dir_body(rq.body);
            if (dir.empty()) return "{\"ok\":false,\"error\":\"缺少 dir 参数\"}";
            if (!valid_utf8(dir)) return utf8_path_reject(dir);
            int files = 0, dirs = 0;
            std::string err;
            if (!lib.scanDirForRemoval(dir, files, dirs, err))
                return "{\"ok\":false,\"error\":\"" + jesc(err) + "\"}";
            std::ostringstream j;
            j << "{\"ok\":true,\"dir\":\"" << jesc(dir) << "\""
              << ",\"files\":" << files << ",\"dirs\":" << dirs << "}";
            return j.str();
        }
        if (rq.path.rfind("/api/lib/rmdir", 0) == 0) {
            const std::string dir = parse_dir_body(rq.body);
            if (dir.empty()) return "{\"ok\":false,\"error\":\"缺少 dir 参数\"}";
            if (!valid_utf8(dir)) return utf8_path_reject(dir);   // F1：下面就是 fs 操作
            int files = 0, dirs = 0;
            std::string err;
            if (!lib.removeDirFromDisk(dir, files, dirs, err))
                return "{\"ok\":false,\"error\":\"" + jesc(err) + "\"}";
            // 目录已经从磁盘消失 ⟹ 索引里对应的曲目必须同时清掉，否则又是 #3 那个「点了播放就失败」。
            const int purged = lib.purgeTracksUnder(dir);
            std::ostringstream j;
            j << "{\"ok\":true,\"dir\":\"" << jesc(dir) << "\""
              << ",\"files\":" << files << ",\"dirs\":" << dirs
              << ",\"removedTracks\":" << purged
              << ",\"tracks\":" << lib.trackCount() << "}";
            return j.str();
        }
        // 注意：/api/lib/albums 必须在 /api/lib/album 之前判断（后者是前者的前缀）
        if (rq.path.rfind("/api/lib/albums", 0) == 0) {
            std::string q;
            const size_t p = rq.path.find("?q=");
            if (p != std::string::npos) q = urlDecode(rq.path.substr(p + 3));
            std::string ql = q;
            for (auto& c : ql) c = (char)std::tolower((unsigned char)c);
            const auto albums = lib.albums();
            std::ostringstream j;
            j << "{\"ok\":true,\"q\":\"" << jesc(q) << "\",\"albums\":[";
            bool first = true;
            for (const auto& a : albums) {
                if (!ql.empty()) {
                    std::string hay = a.name + " " + a.artist;
                    for (auto& c : hay) c = (char)std::tolower((unsigned char)c);
                    if (hay.find(ql) == std::string::npos) continue;
                }
                if (!first) j << ",";
                first = false;
                rta::net::LibTrack t0;
                int sr = 0, bits = 0;
                if (!a.idx.empty() && lib.trackAt(a.idx[0], t0)) { sr = t0.sampleRate; bits = t0.bits; }
                j << "{\"k\":\"" << a.key << "\",\"name\":\"" << jesc(a.name)
                  << "\",\"artist\":\"" << jesc(a.artist) << "\",\"year\":" << a.year
                  << ",\"n\":" << a.nTracks << ",\"dur\":" << a.duration
                  << ",\"sr\":" << sr << ",\"bits\":" << bits
                  // cvSrc（2026-10-26）：embed = 库里已有图（内嵌流/同目录封面文件）；
                  // net = 磁盘 covercache 有网图；none = 都没有（前端显示首字母占位）。
                  // cvUrl 只在有网图时给 —— 与 GET /api/lib/cover?k= 完全同一条路径。
                  // ★ 只算一次 cover_src_of：它内部是一次 stat，列表端点会走 N 张专辑，
                  //   同一行里连调 3 次就是 3N 次 stat（本库 1502 张 ⟹ 4506 次）。
                  //   这正是「封面页慢」这一类问题的形态，别为了少写一行把它引回来。
                  ;
                const std::string csrc = cover_src_of(a.key, a.hasCover);
                j << ",\"cv\":" << ((a.hasCover || csrc == "net") ? "true" : "false")
                  << ",\"cvSrc\":\"" << csrc << "\"";
                if (csrc == "net")
                    j << ",\"cvUrl\":\"/api/lib/cover?k=" << a.key << "\"";
                j << "}";
            }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/lib/album", 0) == 0) {
            std::string key;
            const size_t p = rq.path.find("?k=");
            if (p != std::string::npos) key = urlDecode(rq.path.substr(p + 3));
            rta::net::LibAlbum a;
            if (!lib.album(key, a)) return "{\"ok\":false,\"error\":\"专辑不存在\"}";
            std::ostringstream j;
            // cvSrc/cvUrl 与 /api/lib/albums 同一口径（见那里注释）
            const std::string csrc = cover_src_of(a.key, a.hasCover);
            j << "{\"ok\":true,\"k\":\"" << a.key << "\",\"name\":\"" << jesc(a.name)
              << "\",\"artist\":\"" << jesc(a.artist) << "\",\"year\":" << a.year
              << ",\"dur\":" << a.duration
              << ",\"cv\":" << ((a.hasCover || csrc == "net") ? "true" : "false")
              << ",\"cvSrc\":\"" << csrc << "\"";
            if (csrc == "net") j << ",\"cvUrl\":\"/api/lib/cover?k=" << a.key << "\"";
            j << ",\"tracks\":[";
            for (size_t i = 0; i < a.idx.size(); ++i) {
                rta::net::LibTrack t;
                if (!lib.trackAt(a.idx[i], t)) continue;
                if (i) j << ",";
                // ---- CUE 分轨字段（2026-10-25）----
                // cs/ce = 本曲在整轨文件里的起止秒（与 /api/play 的 cue_start/cue_end 同一口径）；
                // 非 cue 曲目一律 -1（前端判 >=0 才带参数，负向对照"整首播"就靠这一档）。
                // 为什么不复用 dur：cue 虚拟曲目的 dur 已经是"本轨时长"，但播放侧还需要**起点**，
                // 只给时长等于少了一半信息（起点 4s 还是 8s 决定听到的是哪一首）。
                double cs = -1.0, ce = -1.0;
                const bool isCue = lib_track_cue_sec(t, cs, ce);
                j << "{\"i\":" << i << ",\"n\":" << t.trackNo << ",\"d\":" << t.discNo
                  << ",\"title\":\"" << jesc(t.title) << "\",\"artist\":\"" << jesc(t.artist)
                  << "\",\"dur\":" << t.duration << ",\"sr\":" << t.sampleRate
                  << ",\"bits\":" << t.bits << ",\"ch\":" << t.channels
                  << ",\"codec\":\"" << jesc(t.codec) << "\",\"path\":\"" << jesc(t.path) << "\""
                  << ",\"cs\":" << (isCue ? cs : -1.0)
                  << ",\"ce\":" << (isCue ? ce : -1.0) << "}";
            }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/lib/search", 0) == 0) {
            // 搜索（2026-10-25 修用户 bug #6「列表只显示 300」）：
            //   旧版把上限硬编码成 300 —— 库里命中再多也只返回前 300 条，用户看到的就是
            //   "搜索列表只有 300 首"，且没有任何字段告诉他还有多少。
            //   现在：?limit= 可调（默认 300，上限 5000，非法值回落默认），并新增 "total"
            //   报告真实命中总数，前端才能显示"共 N 条 / 已显示 M 条"。
            // 取参数到 '&' 为止：旧代码 q 用 substr 一路吃到结尾，?q=a&limit=1000 会把
            // "&limit=1000" 当成关键词的一部分（那样 limit 永远拿不到）。
            auto qs_val = [&](const char* key) -> std::string {
                const std::string pat = std::string(key) + "=";
                size_t p = rq.path.find("?" + pat);
                if (p == std::string::npos) p = rq.path.find("&" + pat);
                if (p == std::string::npos) return std::string();
                p += 1 + pat.size();
                const size_t e = rq.path.find('&', p);
                return urlDecode(rq.path.substr(p, e == std::string::npos ? std::string::npos : e - p));
            };
            const std::string q = qs_val("q");
            size_t limit = 300;
            {
                const std::string ls = qs_val("limit");
                if (!ls.empty()) {
                    bool digits = true;
                    for (char ch : ls) if (ch < '0' || ch > '9') { digits = false; break; }
                    const long long v = digits ? atoll(ls.c_str()) : 0;
                    if (digits && v >= 1) limit = (v > 5000) ? 5000 : (size_t)v;
                    // 非数字 / 0 / 越界一律保持默认 300（绝不因为一个坏参数把整个列表变空）
                }
            }
            const auto hits = lib.search(q, limit);
            // total = 真实命中总数。lib.search 的 limit 只是截断，拿总数只能再扫一遍
            // （12000 首线性扫两次可接受）；hits 没打满 limit 时它就是总数，省掉第二次扫描。
            size_t total = hits.size();
            if (hits.size() >= limit) total = lib.search(q, (size_t)-1).size();
            std::ostringstream j;
            j << "{\"ok\":true,\"q\":\"" << jesc(q) << "\",\"n\":" << hits.size()
              << ",\"limit\":" << limit << ",\"total\":" << total << ",\"tracks\":[";
            // 用 first 而不是循环下标：trackAt 失败被 continue 跳过时，下标判断会在开头多吐一个逗号
            bool firstHit = true;
            for (size_t i = 0; i < hits.size(); ++i) {
                rta::net::LibTrack t;
                if (!lib.trackAt(hits[i], t)) continue;
                if (!firstHit) j << ",";
                firstHit = false;
                j << "{\"title\":\"" << jesc(t.title) << "\",\"artist\":\"" << jesc(t.artist)
                  << "\",\"album\":\"" << jesc(t.album) << "\",\"dur\":" << t.duration
                  << ",\"sr\":" << t.sampleRate << ",\"bits\":" << t.bits
                  << ",\"year\":" << t.year
                  << ",\"path\":\"" << jesc(t.path) << "\"}";
            }
            j << "]}";
            return j.str();
        }
        // ---- 封面预热进度（只读；见文件中部「专辑封面在线抓取」注释）----
        // 必须排在 /api/lib/cover 之前：后者是前者的前缀（同一类路由顺序坑见 /api/lib/albums）。
        if (rq.path.rfind("/api/lib/cover/progress", 0) == 0) {
            std::shared_ptr<CoverBg> bg;
            {
                std::lock_guard<std::mutex> lk(g_cover_bg_mtx);
                bg = g_cover_bg;
            }
            int hit = 0, miss = 0, fail = 0, total = 0;
            bool running = false;
            std::string last;
            if (bg) {
                hit  = bg->hit.load();
                miss = bg->miss.load();
                fail = bg->fail.load();
                total = (int)bg->jobs.size();
                running = bg->running.load();
                std::lock_guard<std::mutex> lk(bg->lastMtx);
                last = bg->last;
            }
            std::ostringstream j;
            j << "{\"ok\":true,\"running\":" << (running ? "true" : "false")
              << ",\"done\":" << (hit + miss + fail)
              << ",\"total\":" << total
              << ",\"hit\":" << hit
              << ",\"miss\":" << miss
              << ",\"fail\":" << fail
              << ",\"lastName\":\"" << jesc(last) << "\"}";
            return j.str();
        }
        // ---- 封面预热（POST；副作用端点，见 kNeedPost）----
        // 立刻返回，网络/下载全在后台 2 线程（见文件中部「专辑封面在线抓取」注释）。
        if (rq.path.rfind("/api/lib/cover/prefetch", 0) == 0) {
            std::string rawK;
            const size_t q = rq.path.find("?k=");
            if (q != std::string::npos) rawK = urlDecode(rq.path.substr(q + 3));
            if (rawK.empty()) {   // 也接受表单体 k=<键,键>
                const size_t f = rq.body.find("k=");
                if (f != std::string::npos) {
                    std::string v = rq.body.substr(f + 2);
                    const size_t amp = v.find('&');
                    if (amp != std::string::npos) v = v.substr(0, amp);
                    rawK = urlDecode(v);
                }
            }
            const std::vector<std::string> keys = rta::cover::cover_parse_keys(rawK);
            const auto jobs = cover_build_queue(keys);      // 只读库 + stat，不发网络
            const size_t total = jobs.size();
            const bool started = cover_bg_start(std::move(jobs));
            // 2026-10-27（E-4 真修法）：`running` 必须回答「**现在**后台到底有没有活」，
            // 而不是「这一次调用有没有启动成功」。
            // 旧语义 `started?"true":"false"` 的后果：任务由别处（上一页 / 上一次进库页）启动时，
            // 本次回 running=false ⟹ 前端据此 return ⟹ 没人轮询 /api/lib/cover/progress
            // ⟹ 抓完不重绘，用户看到「服务端已有图、界面仍首字母占位」。
            // 改成读真实活跃度后，前端用同一个字段就能覆盖三种情形：
            //   · 本次启动成功 → 后台在跑 → true
            //   · 上一轮还在跑 → 后台在跑 → true（旧代码这里错报 false ← 就是本 BUG）
            //   · 上一轮刚结束 → 后台空闲 → false（此时确实不该显示进度）
            // 注意：queued 语义**不变**（仍是「本次真的排进队列的张数」），别把两者混为一谈。
            const bool bgActive = g_cover_active.load() != 0;
            play_log("COVERBG prefetch queued=" + std::to_string(started ? total : 0) +
                     " candidates=" + std::to_string(total) +
                     " running=" + (bgActive ? "1" : "0") +
                     " source=" + (keys.empty() ? "library" : "keys"));
            std::ostringstream j;
            j << "{\"ok\":true,\"queued\":" << (started ? total : 0)
              << ",\"candidates\":" << total
              << ",\"running\":" << (bgActive ? "true" : "false") << "}";
            return j.str();
        }
        // ---- 人工指定封面（POST；副作用端点）----
        // 为什么需要它：同人自出版专辑在网易/QQ/iTunes 全都查不到、文件里也没有图，
        // 程序再怎么抓也抓不到 —— 这类只能由用户挑一张图。落盘到 covercache（**不改动音乐文件**）。
        // 契约：POST /api/lib/cover/set?k=<专辑键>，body = 图片原始字节（jpg/png/webp/gif），≤24MB。
        if (rq.path.rfind("/api/lib/cover/set", 0) == 0) {
            std::string key;
            const size_t qp = rq.path.find("?k=");
            if (qp != std::string::npos) key = urlDecode(rq.path.substr(qp + 3));
            std::string kk;
            for (char c : key) if (std::isxdigit((unsigned char)c)) kk.push_back((char)std::tolower((unsigned char)c));
            // 专辑键必须是平台生成的 16 位十六进制（fnv_hex 的长度）：这样什么都没有的垃圾输入
            // （例如 k=..\..\windows\win.ini 里恰好含 hex 字符 "d"）不会莫名其妙写出一张 d.jpg。
            if (!rta::cover::cover_key_is_strict_hex16(kk))
                return "{\"ok\":false,\"error\":\"专辑键非法（应为 16 位十六进制）\"}";
            if (rq.body.size() < 1024) return "{\"ok\":false,\"error\":\"图片太小（<1KB）\"}";
            if (rq.body.size() > rta::cover::kCoverMaxBytes) return "{\"ok\":false,\"error\":\"图片超过 24MB\"}";
            const std::vector<unsigned char> body(rq.body.begin(), rq.body.end());
            if (!rta::cover::cover_looks_like_image(body))
                return "{\"ok\":false,\"error\":\"不是可识别的图片（jpg/png/webp/gif）\"}";
            const std::string werr = cover_write_atomic(kk, body);
            if (!werr.empty()) return "{\"ok\":false,\"error\":\"" + jesc(werr) + "\"}";
            play_log("COVERSET k=" + kk + " bytes=" + std::to_string((long long)rq.body.size()));
            return std::string("{\"ok\":true,\"k\":\"") + kk + "\",\"bytes\":" + std::to_string((long long)rq.body.size()) + "}";
        }
        // ---- 一张封面（只读；**零网络**，见文件中部「专辑封面在线抓取」注释）----
        if (rq.path.rfind("/api/lib/cover", 0) == 0) {
            std::string key;
            const size_t p = rq.path.find("?k=");
            if (p != std::string::npos) key = urlDecode(rq.path.substr(p + 3));
            const auto t0 = std::chrono::steady_clock::now();
            std::vector<unsigned char> bytes;
            std::string mime = "image/jpeg";
            const char* src = "none";
            // ① 内嵌/同目录图（现有逻辑）。
            //    ★ 只有 hasCover=1 才去问 —— hasCover 是扫描时算好的（内嵌流 or 同目录封面文件）。
            //      对 hasCover=0 的专辑调 albumCover() 会为每张专辑起 3 次 ffmpeg（~200 ms/张），
            //      上百张就把控制面堵死几十秒 —— 这正是"封面页卡死"的老病根。现在这条路是 0 次 ffmpeg。
            bool hasEmbedded = false;
            rta::net::LibAlbum a;
            if (!key.empty() && lib.album(key, a)) hasEmbedded = a.hasCover;
            if (hasEmbedded && lib.albumCover(key, bytes, mime) && !bytes.empty()) {
                src = "embed";
            } else {
                // ② 磁盘正缓存（网图/人工设置）
                bytes.clear();
                mime = "image/jpeg";
                if (cover_read_cached(key, bytes)) { src = "net"; mime = cover_mime_of(bytes); }
            }
            const double ms = std::chrono::duration<double, std::milli>(
                                  std::chrono::steady_clock::now() - t0).count();
            // 日志节流：专辑页一次渲染就会打上百次这个端点，且响应头是 Cache-Control: no-store
            // （浏览器每次都重新要）⟹ 每张都写日志等于给播放日志灌噪声 + 给每个请求加一次文件 I/O。
            // 规则：本进程前 60 次全记（排查"谁 404 / 走哪条路"够用），之后只记 ≥5 ms 的慢请求。
            static std::atomic<int> s_coverGetSeq{0};
            const int seq = s_coverGetSeq.fetch_add(1);
            if (seq < 60 || ms >= 5.0) {
                char msbuf[24];
                std::snprintf(msbuf, sizeof(msbuf), "%.2f", ms);
                play_log(std::string("COVERGET n=") + std::to_string(seq + 1) + " k=" + key + " src=" + src +
                         " bytes=" + std::to_string(bytes.size()) + " ms=" + msbuf);
            }
            if (std::string(src) == "none") {
                ct = "image/jpeg";
                rta::net::webui_set_status(404);
                return std::string();          // 404 + 空 body：<img onerror> 露回首字母
            }
            ct = mime;
            return std::string(bytes.begin(), bytes.end());
        }
        // 播放整张专辑（?k=专辑键&i=起始曲序），队列被换成这张专辑
        if (rq.path.rfind("/api/lib/play", 0) == 0) {
            // L-2：播放路径才吃 conf 兜底（前端未传的键用用户在设置页保存的值）。
            std::set<std::string> seenKeys;
            PlayParams p = apply_conf_defaults_for_play(parseForm(rq.body, &seenKeys), seenKeys);
            std::string key;
            size_t start = 0;
            {
                std::istringstream is(rq.body);
                std::string tok;
                while (std::getline(is, tok, (char)38)) {
                    const size_t e = tok.find((char)61);
                    if (e == std::string::npos) continue;
                    const std::string kk = urlDecode(tok.substr(0, e));
                    const std::string vv = urlDecode(tok.substr(e + 1));
                    if (kk == "k") key = vv;
                    else if (kk == "i") start = (size_t)atoi(vv.c_str());
                }
            }
            rta::net::LibAlbum a;
            if (!lib.album(key, a)) return "{\"ok\":false,\"error\":\"专辑不存在\"}";
            // 队列项带上每首的 CUE 区间：这张专辑是"整轨 + cue"时，N 首的 path 完全相同，
            // 只有区间能区分。不带区间的旧实现 ⟹ 整张专辑每一首都从文件头开播。
            std::vector<QItem> items;
            for (size_t ix : a.idx) {
                rta::net::LibTrack t;
                if (!lib.trackAt(ix, t)) continue;
                double cs = -1.0, ce = -1.0;
                const bool isCue = lib_track_cue_sec(t, cs, ce);
                items.emplace_back(t.path, isCue ? cs : -1.0, isCue ? ce : -1.0);
            }
            if (items.empty()) return "{\"ok\":false,\"error\":\"专辑为空\"}";
            if (start >= items.size()) start = 0;
            // 可选 cue_start/cue_end（前端点某一轨时显式带上）：覆盖起始曲目的区间。
            // 用途是"前端与库必须说同一句话"：库读不出区间（例如索引来自旧版）时，前端仍能播对。
            if (p.cueStart >= 0.0) {
                if (p.cueEnd >= 0.0 && p.cueEnd <= p.cueStart)
                    return "{\"ok\":false,\"error\":\"cue_start/cue_end 区间非法\"}";
                items[start].cs = p.cueStart;
                items[start].ce = p.cueEnd;
            }
            {
                std::lock_guard<std::mutex> lk(g_q.mtx);
                g_q.items = items;
                g_q.index = start;
            }
            queue_save();
            params_store(p);
            // 停旧线程 + join + 起新线程 = 一次原子操作（并发点播放不再撞 thread 赋值 terminate）
            ps.restart([p, start] { return queue_thread(p, start); });
            { std::lock_guard<std::mutex> lk(ps.mtx); ps.error.clear(); ps.current = items[start].path; }
            ps.played.store(0);
            ps.total.store(0);
            ps.playing.store(true);
            return "{\"ok\":true,\"count\":" + std::to_string(items.size()) + "}";
        }
        // 整张专辑加入队列（不打断当前播放）
        if (rq.path.rfind("/api/lib/enqueue", 0) == 0) {
            std::string key;
            const size_t p = rq.path.find("?k=");
            if (p != std::string::npos) key = urlDecode(rq.path.substr(p + 3));
            rta::net::LibAlbum a;
            if (!lib.album(key, a)) return "{\"ok\":false,\"error\":\"专辑不存在\"}";
            size_t cnt = 0;
            {
                std::lock_guard<std::mutex> lk(g_q.mtx);
                for (size_t ix : a.idx) {
                    rta::net::LibTrack t;
                    if (!lib.trackAt(ix, t)) continue;
                    double cs = -1.0, ce = -1.0;
                    const bool isCue = lib_track_cue_sec(t, cs, ce);
                    g_q.items.emplace_back(t.path, isCue ? cs : -1.0, isCue ? ce : -1.0);
                    ++cnt;
                }
                cnt = g_q.items.size();
            }
            queue_save();
            return "{\"ok\":true,\"count\":" + std::to_string(cnt) + "}";
        }
        return "{\"ok\":false,\"error\":\"unknown lib api\"}";
    }

    // ---------------- 歌词 ----------------
    if (rq.path.rfind("/api/lyrics", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string file;
        const size_t q = rq.path.find("?file=");
        if (q != std::string::npos) file = urlDecode(rq.path.substr(q + 6));
        if (file.empty()) return "{\"ok\":false,\"error\":\"未指定文件\"}";
        if (!valid_utf8(file)) return utf8_path_reject(file);   // F1：本端点下方就是 fs::u8path
        std::string text, src;
        // 1) 同名 .lrc（或同目录唯一的 .lrc）
        {
            std::error_code ec;
            fs::path p = fs::u8path(file);
            std::vector<fs::path> cands;
            fs::path lrc = p; lrc.replace_extension(".lrc");
            if (fs::exists(lrc, ec)) cands.push_back(lrc);
            fs::path LRC = p; LRC.replace_extension(".LRC");
            if (fs::exists(LRC, ec)) cands.push_back(LRC);
            if (cands.empty()) {
                int cnt = 0;
                for (auto& e : fs::directory_iterator(p.parent_path(), ec)) {
                    std::string ext = pathToUtf8(e.path().extension());
                    for (auto& c : ext) c = (char)std::tolower((unsigned char)c);
                    if (ext == ".lrc") { cands.push_back(e.path()); ++cnt; }
                }
                if (cnt != 1) cands.clear();          // 有多个就不知道配哪个了
            }
            for (auto& c : cands) {
                std::ifstream f(c, std::ios::binary);
                if (!f) continue;
                std::string s((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
                if (s.size() > 3 && (unsigned char)s[0] == 0xEF && (unsigned char)s[1] == 0xBB && (unsigned char)s[2] == 0xBF) s.erase(0, 3);
                // UTF-8 校验；失败则按 GBK 转（中文 LRC 大量是 GBK）
                bool utf8 = true;
                for (size_t i = 0; i < s.size(); ) {
                    const unsigned char c0 = (unsigned char)s[i];
                    int n = c0 < 0x80 ? 0 : ((c0 >> 5) == 6 ? 1 : ((c0 >> 4) == 14 ? 2 : ((c0 >> 3) == 30 ? 3 : -1)));
                    if (n < 0) { utf8 = false; break; }
                    for (int k = 1; k <= n; ++k) if (i + k >= s.size() || ((unsigned char)s[i + k] >> 6) != 2) { utf8 = false; break; }
                    if (!utf8) break;
                    i += (size_t)n + 1;
                }
                // POSIX：GBK(936) 歌词转码未移植；非 UTF-8 内容按原样返回（POSIX 文件生态默认 UTF-8）
                (void)utf8;
                text.swap(s); src = "sidecar"; break;
            }
        }
        // 2) 内嵌歌词标签：FLAC/MP3/M4A 在 format_tags，OGG/Opus 在 stream_tags；
        //    标签名有 LYRICS / UNSYNCEDLYRICS / USLT / SYLT / LRC 等多种写法。
        if (text.empty()) {
            const std::string ffprobe = find_tool("ffprobe");
            if (!ffprobe.empty()) {
                std::string out;
                const std::wstring cmd = L"\"" + widen(ffprobe) +
                    L"\" -v error -show_entries format_tags:stream_tags -of json \"" + widen(file) + L"\"";
                if (run_hidden(cmd, &out) == 0 && !out.empty()) {
                    const rta::net::Json j = rta::net::JsonParser(out).parse();
                    std::string best; bool bestTimed = false;
                    auto consider = [&](const rta::net::Json& tags) {
                        for (const auto& kv : tags.obj) {
                            std::string k = kv.first;
                            for (auto& c : k) c = (char)std::tolower((unsigned char)c);
                            if (k.find("lyric") == std::string::npos && k.find("uslt") == std::string::npos &&
                                k.find("sylt") == std::string::npos && k.find("unsync") == std::string::npos &&
                                k.find("lrc") == std::string::npos) continue;
                            if (kv.second.type != rta::net::Json::Str || kv.second.str.empty()) continue;
                            const std::string& v = kv.second.str;
                            const bool timed = v.find('[') != std::string::npos && v.find(':') != std::string::npos;
                            // 优先"带时间轴"的歌词；否则取最长的一段（有些文件同时有纯文本+时间轴）
                            if (best.empty() || (timed && !bestTimed) ||
                                (timed == bestTimed && v.size() > best.size())) {
                                best = v; bestTimed = timed;
                            }
                        }
                    };
                    consider(j["format"]["tags"]);
                    for (size_t i = 0; i < j["streams"].size(); ++i)
                        consider(j["streams"].at(i)["tags"]);
                    if (!best.empty()) { text = best; src = "embedded"; }
                }
            }
        }
        // 3) MetaStore 补全歌词兜底(P1):前两路都空才查;原文样输出(src="meta:<来源>")
        if (text.empty()) {
            rta::meta::TrackMeta tm;
            if (rta::meta::MetaStore::instance().load(file, tm)) {
                const auto it = tm.fields.find("lyrics");
                if (it != tm.fields.end() && !it->second.value.empty()) {
                    text = it->second.value;
                    src = "meta:" + (it->second.source.empty() ? std::string("unknown")
                                                               : it->second.source);
                }
            }
        }
        std::ostringstream j;
        j << "{\"ok\":" << (text.empty() ? "false" : "true")
          << ",\"src\":\"" << src << "\",\"lrc\":\"" << jesc(text) << "\"}";
        return j.str();
    }

    // ---------------- 具名保存队列 /api/sq（用户 261026-08 #6）----------------
    //   POST /api/sq/save?name=X        把**当前队列**存成具名队列（同名覆盖）
    //   GET  /api/sq/list               {"queues":[{name,n}]}
    //   POST /api/sq/rename?from=A&to=B 改名（目标已存在则拒绝）
    //   POST /api/sq/delete?name=X      删除
    //   POST /api/sq/play?name=X&i=0    装进当前队列（前端随后 /api/play 起播第一首）
    if (rq.path.rfind("/api/sq", 0) == 0) {
        ct = "application/json; charset=utf-8";
        sq_load_if_needed();
        auto sqp = [&](const char* key) -> std::string {
            const size_t qp = rq.path.find('?');
            if (qp != std::string::npos) {
                std::istringstream qs(rq.path.substr(qp + 1));
                std::string q;
                while (std::getline(qs, q, '&')) {
                    const size_t eq = q.find('=');
                    if (eq == std::string::npos) continue;
                    if (urlDecode(q.substr(0, eq)) == key) return urlDecode(q.substr(eq + 1));
                }
            }
            std::istringstream is(rq.body);
            std::string tok;
            while (std::getline(is, tok, '&')) {
                const size_t eq = tok.find('=');
                if (eq == std::string::npos) continue;
                if (urlDecode(tok.substr(0, eq)) == key) return urlDecode(tok.substr(eq + 1));
            }
            return std::string();
        };

        auto sqName = [](std::string n) {
            std::string o;
            for (char c : n) {
                if (c == '\n' || c == '\r' || c == '\t' || c == '/' || c == '\\') continue;
                o.push_back(c);
            }
            while (!o.empty() && o.front() == ' ') o.erase(o.begin());
            while (!o.empty() && o.back() == ' ') o.pop_back();
            while (true) {
                size_t pos = o.find("..");
                if (pos == std::string::npos) break;
                o.erase(pos, 2);
            }
            while (!o.empty() && o.front() == ' ') o.erase(o.begin());
            while (!o.empty() && o.back() == ' ') o.pop_back();
            if (o.size() > 60) {
                size_t cut = 60;
                while (cut > 0 && ((unsigned char)o[cut] & 0xC0) == 0x80) --cut;
                o.resize(cut);
            }
            return o;
        };

        if (rq.path.rfind("/api/sq/list", 0) == 0) {
            std::ostringstream j;
            j << "{\"ok\":true,\"queues\":[";
            {
                std::lock_guard<std::mutex> lk(g_sqMu);
                bool first = true;
                for (const auto& q : g_sqList) {
                    if (!first) j << ",";
                    first = false;
                    j << "{\"name\":\"" << jesc(q.name) << "\",\"n\":" << q.items.size() << "}";
                }
            }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/sq/info", 0) == 0) {
            const std::string name = sqName(sqp("name"));
            std::vector<QItem> items;
            {
                std::lock_guard<std::mutex> lk(g_sqMu);
                bool found = false;
                for (const auto& q : g_sqList) if (q.name == name) { items = q.items; found = true; break; }
                if (!found) return "{\"ok\":false,\"error\":\"队列不存在\"}";
            }
            std::ostringstream j;
            j << "{\"ok\":true,\"name\":\"" << jesc(name) << "\",\"items\":[";
            for (size_t i = 0; i < items.size(); ++i) {
                if (i) j << ",";
                j << "{\"file\":\"" << jesc(items[i].path) << "\",\"cs\":" << items[i].cs
                  << ",\"ce\":" << items[i].ce << "}";
            }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/sq/save", 0) == 0) {
            const std::string name = sqName(sqp("name"));
            if (name.empty()) return "{\"ok\":false,\"error\":\"缺少队列名字\"}";
            std::vector<QItem> items;
            { std::lock_guard<std::mutex> lk(g_q.mtx); items = g_q.items; }
            if (items.empty()) return "{\"ok\":false,\"error\":\"当前队列是空的，没有可保存的内容\"}";
            size_t count = 0;
            bool saved = false;
            {
                std::lock_guard<std::mutex> lk(g_sqMu);
                bool replaced = false;
                for (auto& q : g_sqList) {
                    if (q.name == name) { q.items = items; replaced = true; break; }
                }
                if (!replaced) g_sqList.push_back(SavedQueue{name, items});
                count = items.size();
                saved = sq_save_locked();
            }
            std::ostringstream j;
            j << "{\"ok\":" << (saved ? "true" : "false") << ",\"name\":\"" << jesc(name)
              << "\",\"count\":" << count;
            if (!saved) j << ",\"error\":\"队列已生效但写入磁盘失败（目录不可写？），重启后可能丢失\"";
            j << "}";
            return j.str();
        }
        if (rq.path.rfind("/api/sq/rename", 0) == 0) {
            const std::string from = sqName(sqp("from"));
            const std::string to   = sqName(sqp("to"));
            if (from.empty() || to.empty()) return "{\"ok\":false,\"error\":\"缺少 from/to 参数\"}";
            bool found = false, dup = false, saved = false;
            {
                std::lock_guard<std::mutex> lk(g_sqMu);
                for (const auto& q : g_sqList) {
                    if (q.name == from) found = true;
                    else if (q.name == to) dup = true;
                }
                if (found && !dup && from != to) {
                    for (auto& q : g_sqList) if (q.name == from) { q.name = to; break; }
                    saved = sq_save_locked();
                } else if (found && from == to) {
                    saved = true;
                }
            }
            if (!found) return "{\"ok\":false,\"error\":\"队列不存在\"}";
            if (dup && from != to) return "{\"ok\":false,\"error\":\"同名队列已存在\"}";
            std::ostringstream j;
            j << "{\"ok\":" << (saved ? "true" : "false") << ",\"from\":\"" << jesc(from)
              << "\",\"to\":\"" << jesc(to) << "\"";
            if (!saved) j << ",\"error\":\"写入磁盘失败\"";
            j << "}";
            return j.str();
        }
        if (rq.path.rfind("/api/sq/delete", 0) == 0) {
            const std::string name = sqName(sqp("name"));
            if (name.empty()) return "{\"ok\":false,\"error\":\"缺少 name 参数\"}";
            bool found = false, saved = false;
            {
                std::lock_guard<std::mutex> lk(g_sqMu);
                for (size_t i = 0; i < g_sqList.size(); ++i) {
                    if (g_sqList[i].name != name) continue;
                    g_sqList.erase(g_sqList.begin() + (long long)i);
                    found = true;
                    break;
                }
                if (found) saved = sq_save_locked();
            }
            if (!found) return "{\"ok\":false,\"error\":\"队列不存在\"}";
            return std::string("{\"ok\":") + (saved ? "true" : "false") + ",\"name\":\"" + jesc(name) + "\"}";
        }
        if (rq.path.rfind("/api/sq/play", 0) == 0) {
            const std::string name = sqName(sqp("name"));
            const std::string idxS = sqp("i");
            std::vector<QItem> items;
            {
                std::lock_guard<std::mutex> lk(g_sqMu);
                bool found = false;
                for (const auto& q : g_sqList) if (q.name == name) { items = q.items; found = true; break; }
                if (!found) return "{\"ok\":false,\"error\":\"队列不存在\"}";
            }
            if (items.empty()) return "{\"ok\":false,\"error\":\"这个队列是空的\"}";
            size_t idx = idxS.empty() ? 0 : (size_t)std::max(0, atoi(idxS.c_str()));
            if (idx >= items.size()) idx = 0;
            size_t cnt = 0;
            {
                std::lock_guard<std::mutex> lk(g_q.mtx);
                g_q.items = std::move(items);
                g_q.index = idx;
                g_q.base.clear();
                g_q.sortBase.clear();
                cnt = g_q.items.size();
            }
            queue_save();
            std::ostringstream j;
            j << "{\"ok\":true,\"name\":\"" << jesc(name) << "\",\"count\":" << cnt
              << ",\"index\":" << idx << "}";
            return j.str();
        }
        return "{\"ok\":false,\"error\":\"未知的 /api/sq 子端点\"}";
    }

    // ---------------- 播放列表 ----------------
    // 注意：不能写成 rfind("/api/pl",0)，否则 /api/play 会被这里截走（本轮真踩到）
    if (rq.path.rfind("/api/pl/", 0) == 0 || rq.path == "/api/pl") {
        ct = "application/json; charset=utf-8";
        auto plDir = [] { return fs::u8path(path_in_exe_dir("playlists")); };
        std::error_code ec;
        fs::create_directories(plDir(), ec);

        auto cleanName = [](std::string name) {
            while (!name.empty() && (name.front() == ' ' || name.front() == '\t')) name.erase(name.begin());
            while (!name.empty() && (name.back() == ' ' || name.back() == '\t')) name.pop_back();
            if (name.empty()) name = "未命名播放列表";
            for (auto& c : name)
                if (c == '\\' || c == '/' || c == ':' || c == '*' || c == '?' || c == '"' ||
                    c == '<' || c == '>' || c == '|' || c == '\n' || c == '\r' || c == '\t') c = '_';
            while (true) {
                size_t p = name.find("..");
                if (p == std::string::npos) break;
                name.replace(p, 2, "__");
            }
            if (name.size() > 80) {
                size_t cut = 80;
                while (cut > 0 && ((unsigned char)name[cut] & 0xC0) == 0x80) --cut;
                name.resize(cut);
            }
            return name;
        };

        auto qparam = [&](const char* key) -> std::string {
            const size_t qp = rq.path.find('?');
            if (qp != std::string::npos) {
                std::istringstream qs(rq.path.substr(qp + 1));
                std::string tok;
                while (std::getline(qs, tok, '&')) {
                    const size_t eq = tok.find('=');
                    if (eq == std::string::npos) continue;
                    if (urlDecode(tok.substr(0, eq)) == key) return urlDecode(tok.substr(eq + 1));
                }
            }
            std::istringstream is(rq.body);
            std::string tok;
            while (std::getline(is, tok, '&')) {
                const size_t eq = tok.find('=');
                if (eq == std::string::npos) continue;
                if (urlDecode(tok.substr(0, eq)) == key) return urlDecode(tok.substr(eq + 1));
            }
            return std::string();
        };

        auto isPl = [&](const char* sub) {
            const std::string base = std::string("/api/pl/") + sub;
            if (rq.path == base) return true;
            return rq.path.rfind(base + "?", 0) == 0;
        };

        auto plFile = [&](const std::string& name) { return plDir() / fs::u8path(name + ".m3u8"); };

        auto loadList = [&](const std::string& name, std::vector<QItem>& out) -> bool {
            std::ifstream f(plFile(name), std::ios::binary);
            if (!f) return false;
            out.clear();
            std::string line;
            double pendCs = -1.0, pendCe = -1.0;
            while (std::getline(f, line)) {
                if (!line.empty() && line.back() == '\r') line.pop_back();
                if (line.empty()) continue;
                if (line.rfind("#RTA-CUE ", 0) == 0) {
                    const char* s = line.c_str() + 9;
                    char* e2 = nullptr;
                    pendCs = std::strtod(s, &e2);
                    pendCe = (e2 && *e2) ? std::strtod(e2, nullptr) : -1.0;
                    continue;
                }
                if (line[0] == '#') continue;
                out.push_back(QItem(line, pendCs, pendCe));
                pendCs = -1.0; pendCe = -1.0;
            }
            return true;
        };

        auto saveList = [&](const std::string& name, const std::vector<QItem>& items) -> bool {
            std::ofstream f(plFile(name), std::ios::binary | std::ios::trunc);
            if (!f) return false;
            f << "#EXTM3U\n";
            for (const auto& it : items) {
                if (it.isCue()) {
                    char cb[96];
                    std::snprintf(cb, sizeof(cb), "#RTA-CUE %.6f %.6f\n", it.cs, it.ce);
                    f << cb;
                }
                f << it.path << "\n";
            }
            f.flush();
            return f.good();
        };

        if (isPl("save")) {
            const std::string name = cleanName(qparam("name"));
            std::vector<QItem> items;
            { std::lock_guard<std::mutex> lk(g_q.mtx); items = g_q.items; }
            if (!saveList(name, items)) return "{\"ok\":false,\"error\":\"写文件失败\"}";
            return "{\"ok\":true,\"name\":\"" + jesc(name) + "\",\"count\":" +
                   std::to_string(items.size()) + "}";
        }
        if (isPl("create")) {
            const std::string name = cleanName(qparam("name"));
            std::error_code ec2;
            const bool exists = fs::exists(plFile(name), ec2);
            if (!exists && !saveList(name, {})) return "{\"ok\":false,\"error\":\"写文件失败\"}";
            return std::string("{\"ok\":true,\"name\":\"") + jesc(name) +
                   "\",\"existed\":" + (exists ? "true" : "false") + ",\"count\":0}";
        }
        if (isPl("rename")) {
            const std::string from = cleanName(qparam("from"));
            const std::string to   = cleanName(qparam("to"));
            std::error_code ec2;
            if (!fs::exists(plFile(from), ec2)) return "{\"ok\":false,\"error\":\"播放列表不存在\"}";
            if (from != to && fs::exists(plFile(to), ec2)) return "{\"ok\":false,\"error\":\"目标名字已存在\"}";
            if (from != to) {
                fs::rename(plFile(from), plFile(to), ec2);
                if (ec2) return "{\"ok\":false,\"error\":\"改名失败\"}";
            }
            return "{\"ok\":true,\"from\":\"" + jesc(from) + "\",\"to\":\"" + jesc(to) + "\"}";
        }
        if (isPl("add")) {
            const std::string name = cleanName(qparam("name"));
            const std::string file = qparam("file");
            if (file.empty()) return "{\"ok\":false,\"error\":\"缺少 file 参数\"}";
            if (!valid_utf8(file)) return utf8_path_reject(file);
            const std::string csS = qparam("cue_start");
            const std::string ceS = qparam("cue_end");
            QItem it(file, csS.empty() ? -1.0 : std::atof(csS.c_str()),
                           ceS.empty() ? -1.0 : std::atof(ceS.c_str()));
            std::vector<QItem> items;
            loadList(name, items);
            items.push_back(it);
            if (!saveList(name, items)) return "{\"ok\":false,\"error\":\"写文件失败\"}";
            return "{\"ok\":true,\"name\":\"" + jesc(name) + "\",\"count\":" +
                   std::to_string(items.size()) + "}";
        }
        if (isPl("addmany")) {
            const std::string name = cleanName(qparam("name"));
            const std::string files = qparam("files");
            if (files.empty()) return "{\"ok\":false,\"error\":\"缺少 files 参数\"}";
            std::vector<QItem> items;
            loadList(name, items);
            size_t added = 0;
            {
                std::istringstream ls(files);
                std::string line;
                while (std::getline(ls, line)) {
                    if (!line.empty() && line.back() == '\r') line.pop_back();
                    if (line.empty()) continue;
                    items.push_back(item_from_line(line));
                    ++added;
                }
            }
            if (!saveList(name, items)) return "{\"ok\":false,\"error\":\"写文件失败\"}";
            return "{\"ok\":true,\"name\":\"" + jesc(name) + "\",\"added\":" + std::to_string(added) +
                   ",\"count\":" + std::to_string(items.size()) + "}";
        }
        if (isPl("remove")) {
            const std::string name = cleanName(qparam("name"));
            const std::string idxS = qparam("i");
            if (idxS.empty()) return "{\"ok\":false,\"error\":\"缺少 i 参数\"}";
            const size_t idx = (size_t)std::max(0, atoi(idxS.c_str()));
            std::vector<QItem> items;
            if (!loadList(name, items)) return "{\"ok\":false,\"error\":\"播放列表不存在\"}";
            if (idx >= items.size()) return "{\"ok\":false,\"error\":\"下标越界\"}";
            items.erase(items.begin() + (long long)idx);
            if (!saveList(name, items)) return "{\"ok\":false,\"error\":\"写文件失败\"}";
            return "{\"ok\":true,\"name\":\"" + jesc(name) + "\",\"count\":" +
                   std::to_string(items.size()) + "}";
        }
        if (isPl("load")) {
            const std::string name = cleanName(qparam("name"));
            std::vector<QItem> items;
            if (!loadList(name, items)) return "{\"ok\":false,\"error\":\"播放列表不存在\"}";
            {
                std::lock_guard<std::mutex> lk(g_q.mtx);
                g_q.items = items;
                g_q.index = 0;
                g_q.base.clear();
                g_q.sortBase.clear();
            }
            queue_save();
            return "{\"ok\":true,\"name\":\"" + jesc(name) + "\",\"count\":" +
                   std::to_string(items.size()) + "}";
        }
        if (isPl("delete")) {
            const std::string raw = qparam("name");
            if (raw.empty()) return "{\"ok\":false,\"error\":\"缺少 name 参数\"}";
            const std::string name = cleanName(raw);
            std::error_code ec3;
            if (!fs::exists(plFile(name), ec3)) return "{\"ok\":false,\"error\":\"播放列表不存在\"}";
            fs::remove(plFile(name), ec3);
            return std::string("{\"ok\":") + (ec3 ? "false" : "true") + ",\"name\":\"" + jesc(name) + "\"}";
        }
        if (isPl("info")) {
            const std::string raw = qparam("name");
            if (raw.empty()) return "{\"ok\":false,\"error\":\"缺少 name 参数\"}";
            const std::string name = cleanName(raw);
            std::vector<QItem> items;
            if (!loadList(name, items)) return "{\"ok\":false,\"error\":\"播放列表不存在\"}";
            std::ostringstream j;
            j << "{\"ok\":true,\"name\":\"" << jesc(name) << "\",\"items\":[";
            for (size_t i = 0; i < items.size(); ++i) {
                if (i) j << ",";
                j << "{\"file\":\"" << jesc(items[i].path) << "\",\"cs\":" << items[i].cs
                  << ",\"ce\":" << items[i].ce << "}";
            }
            j << "]}";
            return j.str();
        }
        // 列表
        std::ostringstream j;
        j << "{\"ok\":true,\"lists\":[";
        bool first = true;
        for (auto& e : fs::directory_iterator(plDir(), ec)) {
            std::string ext = e.path().extension().string();
            for (auto& c : ext) c = (char)std::tolower((unsigned char)c);
            if (ext != ".m3u8") continue;
            std::string name = e.path().stem().string();
            int n = 0;
            { std::ifstream f(e.path()); std::string l; while (std::getline(f, l)) if (!l.empty() && l[0] != '#') ++n; }
            if (!first) j << ",";
            first = false;
            j << "{\"name\":\"" << jesc(name) << "\",\"n\":" << n << "}";
        }
        j << "]}";
        return j.str();
    }

    // ⚠️ 顺序关键（2026-10-27 R-4 实测踩到）：/api/playmode 以 "/api/play" 开头，
    // 后端用 rfind(prefix,0)==0 做前缀匹配 ⟹ playmode 分支**必须排在 /api/play 之前**，
    // 否则请求会掉进 /api/play 的 "未指定文件" 分支（diagzip 当年同款坑）。
    // ---- 播放模式：单一真相源（R-4，2026-10-27）----
    // GET  /api/playmode            → {"ok":true,"mode":N,"name":"顺序|列表循环|单曲循环|随机"}
    // POST /api/playmode?mode=N     → 设置（body 或查询串皆可）
    if (rq.path.rfind("/api/playmode", 0) == 0) {
        ct = "application/json; charset=utf-8";
        static const char* kNames[] = { "顺序", "列表循环", "单曲循环", "随机" };
        int want = -1;
        {
            const size_t q = rq.path.find("?mode=");
            if (q != std::string::npos) want = atoi(rq.path.c_str() + q + 6);
        }
        if (want < 0) {   // mode is not a playback sampling-rate parameter.
            std::istringstream form(rq.body);
            std::string part;
            while (std::getline(form, part, '&')) {
                const size_t eq = part.find('=');
                if (eq == std::string::npos || urlDecode(part.substr(0, eq)) != "mode") continue;
                const std::string value = urlDecode(part.substr(eq + 1));
                if (!value.empty() && value.find_first_not_of("0123456789") == std::string::npos)
                    want = (value.size() <= 2) ? atoi(value.c_str()) : 99;
            }
        }
        if (rq.method == "POST" && want >= 0) {
            if (want > 3) want = 0;
            {
                std::lock_guard<std::mutex> lk(g_q.mtx);
                const bool wasShuffle = g_q.shuffle_of();
                const bool wantShuffle = (want == 3);
                if (wantShuffle && !wasShuffle) {
                    g_q.base = g_q.items;
                    if (g_q.items.size() > 1) {
                        std::mt19937 rng((unsigned)std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now().time_since_epoch()).count());
                        std::shuffle(g_q.items.begin(), g_q.items.end(), rng);
                    }
                } else if (!wantShuffle && wasShuffle) {
                    if (!g_q.base.empty()) g_q.items = g_q.base;
                }
                g_q.mode = want;
            }
            queue_save();
        }
        int cur = 0;
        { std::lock_guard<std::mutex> lk(g_q.mtx); cur = g_q.mode; }
        return std::string("{\"ok\":true,\"mode\":") + std::to_string(cur) +
               ",\"name\":\"" + kNames[(cur >= 0 && cur <= 3) ? cur : 0] + "\"}";
    }

    if (rq.path.rfind("/api/play", 0) == 0) {
        ct = "application/json; charset=utf-8";
        // L-2：播放路径才吃 conf 兜底；/api/repeat /api/add 不受影响（见 apply_conf_defaults_for_play 注释）
        std::set<std::string> seenKeys;
        PlayParams p = apply_conf_defaults_for_play(parseForm(rq.body, &seenKeys), seenKeys);   // 非 const：远程曲目会把 p.file 换成缓存路径
        // 远程曲目：先把原始文件完整下载到缓存，再走与本地完全相同的解码与 DSP 路径
        if (!p.remoteId.empty()) {
            std::string ferr;
            const std::string local = SourceManager::instance().fetch(p.remoteId, p.remoteSuffix, ferr);
            if (local.empty())
                return std::string("{\"ok\":false,\"error\":\"获取远程曲目失败: ") + jesc(ferr) + "\"}";
            p.file = local;
        }
        if (p.file.empty()) return "{\"ok\":false,\"error\":\"未指定文件\"}";
        // F1：file 会进队列 → 播放线程 recent_add/meta_on_play/fs::u8path 全链消费，
        // 非法字节在这里挡下（播放线程里抛异常没有兜底，等于整进程退出）。
        if (!valid_utf8(p.file)) return utf8_path_reject(p.file);

        // CUE 分轨（2026-10-25）：参数在 HTTP 层先挡一道。
        // 这里只判"能不能自洽"（区间合法/后端适不适合），**不判越界** ——
        // 文件真实时长要解码后才知道，那一条在 play_one 里报（越界也绝不放行成"从头播"）。
        if (p.cueStart >= 0.0) {
            if (!(p.cueEnd >= 0.0) && p.cueEnd != -1.0)
                return "{\"ok\":false,\"error\":\"cue_end 非法（必须是 >=0 的秒数，或省略）\"}";
            if (p.cueEnd >= 0.0 && p.cueEnd <= p.cueStart)
                return "{\"ok\":false,\"error\":\"cue_start/cue_end 区间非法：cue_end 必须大于 cue_start\"}";
            if (p.backend == "upnp")
                return "{\"ok\":false,\"error\":\"UPnP 投放不支持 CUE 分轨（渲染器只能播整个文件），请切到本地后端\"}";
            // 越界尽量**同步**报（能判就判）：ffprobe 给不出时长（duration=0 = 未知）时不判，
            // 由 play_one 在解码后报 CUE_REJECT —— 两条路都必须报错，绝无"静默从头播"。
            const rta::audio::MediaInfo mi = rta::audio::probe_media(p.file);
            if (mi.duration > 0.0 && p.cueStart >= mi.duration)
                return std::string("{\"ok\":false,\"error\":\"") +
                       jesc("CUE 分轨起点越界：起点 " + std::to_string(p.cueStart) +
                            "s ≥ 文件时长 " + std::to_string(mi.duration) + "s") + "\"}";
            if (mi.duration > 0.0 && p.cueEnd > mi.duration + 0.5)
                return std::string("{\"ok\":false,\"error\":\"") +
                       jesc("CUE 分轨终点越界：终点 " + std::to_string(p.cueEnd) +
                            "s > 文件时长 " + std::to_string(mi.duration) + "s") + "\"}";
            play_log("PLAY_CUE cue=" + cue_range_text(p.cueStart, p.cueEnd) + " file=" + p.file);
        }

        // 2026-10-26：这里曾有 native_dsd_precheck（上游 6bd21a6 的 follow 判定移植），已移除。
        //   理由：mac 的 dsdNative 能力恒为 false（CoreAudio 无 ASIO 原生 DSD 通道），
        //   按采样率判定只会把用户引向「改成跟随源」——改了也没用，是误导。
        // 真正的修法是下面这条：**在 /api/play 入口直接拒绝 dsdnative=1**。
        //   修前缺陷（实测）：`POST /api/play?dsdnative=1` 返回 {"ok":true} 就放行了，
        //   而拒绝逻辑只在 direct_sdm_eligible()（DirectSDM 分支）里，普通播放路径
        //   根本不检查 ⟹ 用户看到"播放成功"却没有任何声音（Native DSD 在 mac 上不存在）。
        if (p.dsdNative) {
            const std::string why =
                "DSD Native 还没实现（它走 Native DSD 驱动通道，不是 DoP）。"
                "macOS 没有原生 DSD 驱动通路：请把输出封装改成 DoP（设置 → 输出 → DSD 封装）。";
            play_log("PLAY_REJECT dsdnative=1 file=" + p.file + " " + why);
            return std::string("{\"ok\":false,\"nativeDsd\":true,\"error\":\"") + jesc(why) + "\"}";
        }

        params_store(p);

        // 先停掉上一次（原子：并发点播放时不会撞 thread 赋值 terminate）
        ps.stopJoin();
        // 一条会话原则（261024-01 #9）：开始新的本地播放时，停掉可能还在跑的投放会话，
        // 避免本机声卡与网络渲染器同时出声（两套控制互相打架）。
        g_upnpPlayer.store(false);
        {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.error.clear();
            ps.current = p.file;
        }
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            // 如果点的文件已在队列里，就从它开始播；否则把队列换成它。
            // CUE 分轨（2026-10-25）：匹配必须带区间 —— 同一路径在一张 cue 专辑里出现 N 次，
            // 只按路径找会永远命中第 1 首（点第 3 轨听到第 1 轨）。
            const QItem want(p.file, p.cueStart, p.cueEnd);
            bool found = false;
            for (size_t i = 0; i < g_q.items.size(); ++i)
                if (g_q.items[i].same(want)) { g_q.index = i; found = true; break; }
            if (!found) {
                g_q.items.clear();
                g_q.items.push_back(want);
                g_q.index = 0;
                g_q.sortBase.clear();
            }
        }
        queue_save();
        ps.played.store(0);
        ps.total.store(0);
        // 后端 = UPnP / DLNA：曲目交给投放会话（cast_service），不启动本地播放线程。
        // 失败如实返回原因（note/前端 toast），绝不假装出声。
        if (p.backend == "upnp") {
            std::string err;
            if (!upnp_start_track(p, p.file, err)) {
                upnp_mark_player_state(p.file, false, err);
                ps.playing.store(false);
                g_upnpPlayer.store(false);
                return std::string("{\"ok\":false,\"error\":\"") + jesc(err) + "\"}";
            }
            g_upnpPlayer.store(true);
            upnp_mark_player_state(p.file, true, "");
            ps.outRate = 0;
            ps.outBits = 0;
            ps.playing.store(true);
            return "{\"ok\":true,\"upnp\":true}";
        }
        ps.playing.store(true);
        const size_t st0 = g_q.index;
        // restart 内部会 join 旧线程（上一步 stopJoin 已把它停掉），再接管新线程
        ps.restart([p, st0] { return queue_thread(p, st0); });
        return "{\"ok\":true}";
    }

    if (rq.path.rfind("/api/qdel", 0) == 0) {
        ct = "application/json; charset=utf-8";
        size_t idx = 0;
        const size_t q = rq.path.find("?i=");
        if (q != std::string::npos) idx = (size_t)atoi(rq.path.c_str() + q + 3);
        size_t cnt = 0;
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            if (idx < g_q.items.size()) {
                const QItem gone = g_q.items[idx];
                g_q.items.erase(g_q.items.begin() + (long long)idx);
                if (!g_q.sortBase.empty()) {
                    for (size_t i = 0; i < g_q.sortBase.size(); ++i) {
                        if (g_q.sortBase[i].same(gone)) {
                            g_q.sortBase.erase(g_q.sortBase.begin() + (long long)i);
                            break;
                        }
                    }
                }
                if (g_q.index > idx && g_q.index > 0) --g_q.index;
                if (g_q.index >= g_q.items.size()) g_q.index = g_q.items.empty() ? 0 : g_q.items.size() - 1;
            }
            cnt = g_q.items.size();
        }
        queue_save();
        return "{\"ok\":true,\"count\":" + std::to_string(cnt) + "}";
    }
    if (rq.path.rfind("/api/qmove", 0) == 0) {
        ct = "application/json; charset=utf-8";
        size_t from = 0, to = 0;
        { const size_t q = rq.path.find("?from="); if (q != std::string::npos) from = (size_t)atoi(rq.path.c_str() + q + 6); }
        { const size_t q = rq.path.find("&to=");   if (q != std::string::npos) to   = (size_t)atoi(rq.path.c_str() + q + 4); }
        size_t cnt = 0;
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            if (from < g_q.items.size() && to < g_q.items.size() && from != to) {
                QItem v = g_q.items[from];
                g_q.items.erase(g_q.items.begin() + (long long)from);
                g_q.items.insert(g_q.items.begin() + (long long)to, v);
            }
            cnt = g_q.items.size();
        }
        queue_save();
        return "{\"ok\":true,\"count\":" + std::to_string(cnt) + "}";
    }

    // ---------------- 队列排序（261027-02 #4）----------------
    // 两个入口：
    //   POST /api/qorder  body: files=<urlencoded>，值为按目标顺序排列的多行队列项（与 /api/queue/set 同格式）
    //   POST /api/qsort?by=default  —— 「恢复默认顺序」：把第一次排序前的快照整列还原
    if (rq.path.rfind("/api/qsort", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string by = "default";
        { const size_t q = rq.path.find("?by="); if (q != std::string::npos) by = urlDecode(rq.path.substr(q + 4)); }
        if (by != "default") return "{\"ok\":false,\"error\":\"未知排序方式（只支持 by=default）\"}";
        size_t n = 0, newIndex = 0;
        bool had = false;
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            if (!g_q.sortBase.empty()) {
                const QItem cur = (g_q.index < g_q.items.size()) ? g_q.items[g_q.index] : QItem();
                g_q.items = g_q.sortBase;
                g_q.sortBase.clear();
                newIndex = queue_reindex_locked(cur);
                n = g_q.items.size();
                had = true;
            }
            if (!had) newIndex = g_q.index;
        }
        if (!had) return "{\"ok\":false,\"error\":\"没有可恢复的排序（队列本来就是默认顺序）\"}";
        queue_save();
        return "{\"ok\":true,\"by\":\"default\",\"n\":" + std::to_string(n) +
               ",\"index\":" + std::to_string(newIndex) + "}";
    }
    if (rq.path.rfind("/api/qorder", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string files;
        {
            std::istringstream is(rq.body);
            std::string tok;
            while (std::getline(is, tok, '&')) {
                const size_t e = tok.find('=');
                if (e == std::string::npos) continue;
                if (urlDecode(tok.substr(0, e)) == "files") files = urlDecode(tok.substr(e + 1));
            }
        }
        std::vector<QItem> want;
        {
            std::istringstream ls(files);
            std::string line;
            while (std::getline(ls, line)) {
                if (!line.empty() && line.back() == '\r') line.pop_back();
                if (line.empty()) continue;
                want.push_back(item_from_line(line));
            }
        }
        for (const auto& w : want)
            if (!valid_utf8(w.path)) return utf8_path_reject(w.path);
        size_t n = 0, newIndex = 0;
        std::string err;
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            if (want.size() != g_q.items.size()) {
                err = "顺序与队列条数不一致（" + std::to_string(want.size()) + " vs " +
                      std::to_string(g_q.items.size()) + "）";
            } else {
                std::vector<bool> used(g_q.items.size(), false);
                for (const auto& w : want) {
                    bool hit = false;
                    for (size_t i = 0; i < g_q.items.size(); ++i) {
                        if (used[i] || !g_q.items[i].same(w)) continue;
                        used[i] = true;
                        hit = true;
                        break;
                    }
                    if (!hit) { err = "顺序里出现了队列中没有的曲目"; break; }
                }
            }
            if (err.empty()) {
                const QItem cur = (g_q.index < g_q.items.size()) ? g_q.items[g_q.index] : QItem();
                if (g_q.sortBase.empty()) g_q.sortBase = g_q.items;
                g_q.items = std::move(want);
                newIndex = queue_reindex_locked(cur);
                n = g_q.items.size();
            }
        }
        if (!err.empty()) return std::string("{\"ok\":false,\"error\":\"") + jesc(err) + "\"}";
        queue_save();
        return "{\"ok\":true,\"n\":" + std::to_string(n) + ",\"index\":" + std::to_string(newIndex) + "}";
    }

    if (rq.path.rfind("/api/add", 0) == 0) {
        ct = "application/json; charset=utf-8";
        PlayParams p = parseForm(rq.body);   // 非 const：远程曲目会把 p.file 换成缓存路径
        // 远程曲目：先把原始文件完整下载到缓存，再走与本地完全相同的解码与 DSP 路径
        if (!p.remoteId.empty()) {
            std::string ferr;
            const std::string local = SourceManager::instance().fetch(p.remoteId, p.remoteSuffix, ferr);
            if (local.empty())
                return std::string("{\"ok\":false,\"error\":\"获取远程曲目失败: ") + jesc(ferr) + "\"}";
            p.file = local;
        }
        // 拖进来的是目录时，把里面的音频文件全部展开（最多 5000 个，递归）
        if (!p.file.empty() && !valid_utf8(p.file)) return utf8_path_reject(p.file);   // F1
        std::vector<std::string> addList;
        {
            std::error_code ec;
            if (fs::is_directory(fs::u8path(p.file), ec) && !ec) {
                static const char* kExt[] = { ".wav", ".flac", ".mp3", ".m4a", ".aac", ".ogg", ".opus",
                                              ".ape", ".wv", ".aiff", ".aif", ".dsf", ".dff", ".wma" };
                int guard = 0;
                for (auto it = fs::recursive_directory_iterator(fs::u8path(p.file), fs::directory_options::skip_permission_denied, ec);
                     it != fs::recursive_directory_iterator() && !ec && guard < 5000; it.increment(ec)) {
                    if (!it->is_regular_file(ec)) continue;
                    std::string ext = pathToUtf8(it->path().extension());
                    std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return (char)std::tolower(c); });
                    bool ok = false;
                    for (const char* e : kExt) if (ext == e) { ok = true; break; }
                    if (ok) { addList.push_back(pathToUtf8(it->path())); ++guard; }
                }
            } else {
                addList.push_back(p.file);
            }
        }
        size_t cnt = 0;
        {
            // 注意：必须用独立作用域释放锁 —— queue_save() 内部会再次加锁，
            // 若在持锁状态下调用就会死锁（本轮踩到：服务端直接挂住，连接被关闭）。
            std::lock_guard<std::mutex> lk(g_q.mtx);
            for (const auto& f : addList) g_q.items.emplace_back(f);
            if (!addList.empty()) g_q.sortBase.clear();
            cnt = g_q.items.size();
        }
        queue_save();
        return "{\"ok\":true,\"count\":" + std::to_string(cnt) + "}";
    }

    // ---------------- 收藏（新增 /api/fav?file=...&on=1 与 /api/fav/list）----------------
    if (rq.path.rfind("/api/fav", 0) == 0) {
        ct = "application/json; charset=utf-8";
        fav_load_if_needed();
        if (rq.path.rfind("/api/fav/list", 0) == 0) {
            const bool wantMeta = rq.path.find("meta=1") != std::string::npos;
            std::vector<std::string> files;
            { std::lock_guard<std::mutex> lk(g_favMu); files.assign(g_favFiles.begin(), g_favFiles.end()); }

            std::map<std::string, rta::net::LibTrack> meta;
            if (wantMeta && !files.empty()) {
                std::set<std::string> want;
                for (const auto& f : files) want.insert(rta::net::lib_path_key(f));
                auto& lib = rta::net::Library::instance();
                const size_t n = lib.trackCount();
                for (size_t i = 0; i < n; ++i) {
                    rta::net::LibTrack t;
                    if (!lib.trackAt(i, t)) continue;
                    const std::string k = rta::net::lib_path_key(t.path);
                    if (want.count(k)) meta[k] = t;
                }
            }
            std::ostringstream j;
            j << "{\"ok\":true,\"files\":[";
            bool first = true;
            for (const auto& f : files) {
                if (!first) j << ",";
                first = false;
                if (!wantMeta) { j << "\"" << jesc(f) << "\""; continue; }
                const auto it = meta.find(rta::net::lib_path_key(f));
                j << "{\"file\":\"" << jesc(f) << "\"";
                if (it != meta.end()) {
                    j << ",\"title\":\"" << jesc(it->second.title) << "\""
                      << ",\"artist\":\"" << jesc(it->second.artist) << "\""
                      << ",\"album\":\"" << jesc(it->second.album) << "\""
                      << ",\"dur\":" << it->second.duration;
                }
                j << "}";
            }
            j << "]}";
            return j.str();
        }

        std::string file;
        std::string onStr = "1";
        auto parseKvs = [&](const std::string& query) {
            std::istringstream qs(query);
            std::string tok;
            while (std::getline(qs, tok, '&')) {
                const size_t eq = tok.find('=');
                if (eq == std::string::npos) continue;
                const std::string k = urlDecode(tok.substr(0, eq));
                const std::string v = urlDecode(tok.substr(eq + 1));
                if (k == "file") file = v;
                else if (k == "on") onStr = v;
            }
        };
        const size_t qpos = rq.path.find('?');
        if (qpos != std::string::npos) parseKvs(rq.path.substr(qpos + 1));
        if (!rq.body.empty()) parseKvs(rq.body);

        if (file.empty()) {
            return "{\"ok\":false,\"error\":\"缺少 file 参数\"}";
        }
        file = normalize_fav_path(file);
        bool on = (onStr == "1" || onStr == "true" || onStr == "on");
        bool saved = false;
        {
            std::lock_guard<std::mutex> lk(g_favMu);
            if (on) {
                g_favFiles.insert(file);
            } else {
                g_favFiles.erase(file);
            }
            saved = fav_save_locked();
        }
        // 落盘失败要如实告诉前端（否则「弹已收藏、重启全丢」）；内存里的集合已改，本次会话仍生效。
        std::ostringstream j;
        j << "{\"ok\":" << (saved ? "true" : "false")
          << ",\"file\":\"" << jesc(file) << "\",\"on\":" << (on ? "true" : "false");
        if (!saved) j << ",\"error\":\"收藏已生效但写入磁盘失败（目录不可写？），重启后可能丢失\"";
        j << "}";
        return j.str();
    }

    if (rq.path.rfind("/api/src", 0) == 0) {
        ct = "application/json; charset=utf-8";
        auto& mgr = SourceManager::instance();
        // 2026-10-24（用户 261024-01 #5）：单服务器 → 多服务器。
        //   GET  /api/src/config             → 服务器列表 + 当前启用（密码只回 hasPass，永不回明文）
        //   POST /api/src/config action=add|update|remove|active …
        //        （无 action 且带 kind/base/user/pass = 旧协议：更新当前启用服务器，保持兼容）
        if (rq.path.rfind("/api/src/config", 0) == 0) {
            if (rq.method == "POST") {
                std::map<std::string, std::string> f;
                std::istringstream is(rq.body);
                std::string tok;
                while (std::getline(is, tok, (char)38)) {
                    const size_t e = tok.find((char)61);
                    if (e == std::string::npos) continue;
                    f[urlDecode(tok.substr(0, e))] = urlDecode(tok.substr(e + 1));
                }
                auto gv = [&](const char* k) {
                    const auto it = f.find(k);
                    return it == f.end() ? std::string() : it->second;
                };
                const std::string action = gv("action");
                if (action == "add" || action == "update" ||
                    (action.empty() && !gv("kind").empty() && gv("id").empty() && f.count("base"))) {
                    SourceConfig c;
                    c.kind = gv("kind").empty() ? "subsonic" : gv("kind");
                    c.base = gv("base");
                    c.user = gv("user");
                    c.pass = gv("pass");
                    c.name = gv("name");
                    const std::string id = gv("id");
                    if (action == "add" || (action.empty() && id.empty())) {
                        const std::string nid = mgr.add_server(c);
                        return std::string("{\"ok\":true,\"id\":\"") + jesc(nid) + "\"}";
                    }
                    if (!mgr.update_server(id, c, /*keepPass=*/true))
                        return "{\"ok\":false,\"error\":\"服务器不存在（可能已被删除）\"}";
                    return "{\"ok\":true,\"id\":\"" + jesc(id) + "\"}";
                }
                if (action == "remove") {
                    const bool ok = mgr.remove_server(gv("id"));
                    return std::string("{\"ok\":") + (ok ? "true" : "false") +
                           ",\"error\":\"" + (ok ? "" : "服务器不存在（可能已被删除）") + "\"}";
                }
                if (action == "active") {
                    const bool ok = mgr.set_active(gv("id"));
                    return std::string("{\"ok\":") + (ok ? "true" : "false") +
                           ",\"error\":\"" + (ok ? "" : "服务器不存在（可能已被删除）") + "\"}";
                }
                // 旧协议兜底：只带 kind/base/user/pass → 更新当前启用服务器（没有就新建）
                SourceConfig c = mgr.config();
                if (f.count("kind")) c.kind = gv("kind");
                if (f.count("base")) c.base = gv("base");
                if (f.count("user")) c.user = gv("user");
                if (f.count("pass")) c.pass = gv("pass");
                mgr.set_config(c);
                return "{\"ok\":true}";
            }
            const std::vector<SourceConfig> list = mgr.servers();
            const std::string act = mgr.active_id();
            const SourceConfig cur = mgr.config();
            std::ostringstream j;
            j << "{\"ok\":true,\"configured\":" << (cur.valid() ? "true" : "false")
              << ",\"active\":\"" << jesc(act) << "\""
              << ",\"kind\":\"" << jesc(cur.kind) << "\""
              << ",\"base\":\"" << jesc(cur.base) << "\""
              << ",\"user\":\"" << jesc(cur.user) << "\""
              << ",\"cache\":" << mgr.cache_count()
              << ",\"servers\":[";
            for (size_t i = 0; i < list.size(); ++i) {
                if (i) j << ",";
                j << "{\"id\":\"" << jesc(list[i].id) << "\""
                  << ",\"name\":\"" << jesc(list[i].display_name()) << "\""
                  << ",\"kind\":\"" << jesc(list[i].kind) << "\""
                  << ",\"base\":\"" << jesc(list[i].base) << "\""
                  << ",\"user\":\"" << jesc(list[i].user) << "\""
                  << ",\"hasPass\":" << (list[i].pass.empty() ? "false" : "true")
                  << ",\"active\":" << (list[i].id == act ? "true" : "false") << "}";
            }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/src/ping", 0) == 0) {
            std::string err;
            bool ok = false;
            if (rq.method == "POST") {
                // 表单里还没保存的服务器也能先测：kind/base/user/pass 直接带进来
                std::map<std::string, std::string> f;
                std::istringstream is(rq.body);
                std::string tok;
                while (std::getline(is, tok, (char)38)) {
                    const size_t e = tok.find((char)61);
                    if (e == std::string::npos) continue;
                    f[urlDecode(tok.substr(0, e))] = urlDecode(tok.substr(e + 1));
                }
                auto gv = [&](const char* k) {
                    const auto it = f.find(k);
                    return it == f.end() ? std::string() : it->second;
                };
                const std::string id = gv("id");
                if (!id.empty() && gv("base").empty()) {
                    ok = mgr.ping_server(id, err);
                } else {
                    SourceConfig c;
                    c.kind = gv("kind").empty() ? "subsonic" : gv("kind");
                    c.base = gv("base");
                    c.user = gv("user");
                    c.pass = gv("pass");
                    ok = mgr.ping_config(c, err);
                }
            } else {
                std::string id;
                const size_t q = rq.path.find("?id=");
                if (q != std::string::npos) id = urlDecode(rq.path.substr(q + 4));
                ok = id.empty() ? mgr.ping(err) : mgr.ping_server(id, err);
            }
            return std::string("{\"ok\":") + (ok ? "true" : "false") + ",\"error\":\"" + jesc(err) + "\"}";
        }
        if (rq.path.rfind("/api/src/browse", 0) == 0 || rq.path.rfind("/api/src/search", 0) == 0) {
            const bool isSearch = rq.path.rfind("/api/src/search", 0) == 0;
            std::string key;
            const size_t q = rq.path.find(isSearch ? "?q=" : "?id=");
            if (q != std::string::npos) key = urlDecode(rq.path.substr(q + (isSearch ? 3 : 4)));
            std::string err;
            std::vector<SubEntry> v;
            if (isSearch) v = mgr.search(key, err);
            else if (key.empty()) v = mgr.indexes(err);
            else v = mgr.browse(key, err);
            std::ostringstream j;
            j << "{\"ok\":true,\"key\":\"" << jesc(key) << "\",\"err\":\"" << jesc(err) << "\",\"items\":[";
            for (size_t i = 0; i < v.size(); ++i) {
                if (i) j << ",";
                j << "{\"id\":\"" << jesc(v[i].id) << "\""
                  << ",\"t\":\"" << jesc(v[i].title) << "\""
                  << ",\"ar\":\"" << jesc(v[i].artist) << "\""
                  << ",\"al\":\"" << jesc(v[i].album) << "\""
                  << ",\"sf\":\"" << jesc(v[i].suffix) << "\""
                  << ",\"dur\":" << v[i].duration
                  << ",\"dir\":" << (v[i].isDir ? "true" : "false")
                  << ",\"cv\":\"" << jesc(v[i].coverId) << "\"}";
            }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/src/cover", 0) == 0) {
            std::string id;
            const size_t q = rq.path.find("?id=");
            if (q != std::string::npos) id = urlDecode(rq.path.substr(q + 4));
            std::vector<unsigned char> bytes;
            if (!id.empty()) { auto rr = mgr.cover(id); if (rr.ok) bytes = rr.body; }
            ct = "image/jpeg";
            return std::string(bytes.begin(), bytes.end());
        }
        return "{\"ok\":false,\"error\":\"unknown src api\"}";
    }
    // ---------------- 数据源注册表(P1.5;设置页动态渲染依据) ----------------
    // GET /api/providers → 注册表内容 + 当前开关状态(rlplayer-settings.conf,旧键迁移读取)。
    // UI 启动时拉一次,按 items 逐源渲染 metasrc_<id> 开关 —— 新增数据源前端零改动。
    if (rq.path.rfind("/api/providers", 0) == 0) {
        ct = "application/json; charset=utf-8";
        const MetaSettings ms = meta_settings_load();
        std::ostringstream j;
        j << "{\"ok\":true,\"items\":[";
        bool first = true;
        for (const rta::meta::ProviderDesc& pd : rta::meta::provider_registry()) {
            if (!first) j << ",";
            first = false;
            const auto it = ms.srcOn.find(pd.id);
            const bool on = (it == ms.srcOn.end()) ? true : it->second;
            j << "{\"id\":\"" << jesc(pd.id) << "\",\"name\":\"" << jesc(pd.name)
              << "\",\"on\":" << (on ? "true" : "false")
              << ",\"canSearch\":" << (pd.canSearch ? "true" : "false")
              << ",\"canLyric\":" << (pd.canLyric ? "true" : "false") << "}";
        }
        j << "],\"llm\":" << (ms.llm ? "true" : "false")
          << ",\"on\":" << (ms.on ? "true" : "false") << "}";
        return j.str();
    }
    // ---------------- 单曲元数据补全(同步;按设置组装 EnrichOpts) ----------------
    // /api/enrich?file=...&force=1 → enrich_track 结果 JSON。正常命中数秒返回;
    // 全源超时的最坏情形可能超 20s(enrich.h 头注「未解决项」如实记录)。
    if (rq.path.rfind("/api/enrich", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string file;
        bool force = false;
        {
            const size_t q = rq.path.find("?file=");
            if (q != std::string::npos) {
                const std::string rest = rq.path.substr(q + 6);
                const size_t amp = rest.find("&force=");
                if (amp != std::string::npos) {
                    file = urlDecode(rest.substr(0, amp));
                    force = rest.compare(amp + 7, 1, "1") == 0;
                } else {
                    file = urlDecode(rest);
                }
            }
        }
        if (file.empty()) return "{\"ok\":false,\"error\":\"未指定文件\"}";
        if (!valid_utf8(file)) return utf8_path_reject(file);   // F1：enrich_track 内部走 u8string→fs::path
        const rta::meta::EnrichStats st = rta::meta::enrich_track(file, force, meta_opts_from_settings());
        std::ostringstream j;
        j << "{\"ok\":" << (st.ok ? "true" : "false")
          << ",\"skipped\":" << (st.skipped ? "true" : "false")
          << ",\"nCand\":" << st.nCand
          << ",\"bestScore\":" << st.bestScore
          << ",\"bestSource\":\"" << jesc(st.bestSource) << "\""
          << ",\"confident\":" << (st.confident ? "true" : "false")
          << ",\"fields\":[";
        for (size_t i = 0; i < st.fieldsFilled.size(); ++i) {
            if (i) j << ",";
            j << "\"" << jesc(st.fieldsFilled[i]) << "\"";
        }
        j << "],\"note\":\"" << jesc(st.note) << "\"}";
        return j.str();
    }

    if (rq.path.rfind("/api/meta", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string file;
        const size_t q = rq.path.find("?file=");
        if (q != std::string::npos) file = urlDecode(rq.path.substr(q + 6));
        if (file.empty()) return "{\"ok\":false,\"error\":\"未指定文件\"}";
        if (!valid_utf8(file)) return utf8_path_reject(file);   // F1：probe_media/get_cover 内部有 u8path
        const MediaInfo mi = probe_media(file);
        std::string mime;
        // 只探测有没有封面（不把图片塞进 JSON）
        auto c = get_cover(file, mime);
        const bool hasCover = c.size() > 128;
        // MetaStore 补全结果覆盖输出(P1):记录里值非空才覆盖;albumArtist/year/lyrics 是新增键
        rta::meta::TrackMeta tm;
        const bool haveMeta = rta::meta::MetaStore::instance().load(file, tm);
        std::string fTitle = mi.title, fArtist = mi.artist, fAlbum = mi.album, fGenre = mi.genre;
        std::string fAlbumArtist, fYear, fLyrics;
        std::map<std::string, std::string> metaSrc;     // 字段 → MetaValue.source(溯源表)
        auto metaOverride = [&](const char* key, std::string& dst) {
            if (!haveMeta) return;
            const auto it = tm.fields.find(key);
            if (it != tm.fields.end() && !it->second.value.empty()) {
                dst = it->second.value;
                metaSrc[key] = it->second.source;
            }
        };
        metaOverride("title", fTitle);
        metaOverride("artist", fArtist);
        metaOverride("album", fAlbum);
        metaOverride("albumArtist", fAlbumArtist);
        metaOverride("year", fYear);
        metaOverride("genre", fGenre);
        metaOverride("lyrics", fLyrics);

        // 简介可用性标志（2026-10-23 用户 261023-03 #2/#3/#5）
        // 单曲播放整页据此决定：是否显示简介板块、是否显示「正在整理资料…」加载行。
        // key 一律从 exe 同目录 rlplayer-llm.conf 读（与设置页 /api/llm 写的同一份，
        // 不随进程工作目录漂移 —— 旧实现先读 "./rlplayer-llm.conf"，从别的 cwd 启动就漏判）。
        const MetaSettings msMeta = meta_settings_load();
        const std::string metabaseDir = path_in_exe_dir("rlplayer-meta");
        bool hasKeyMeta = false;
        {
            const rta::meta::LlmConfig cfg = rta::meta::llm_config_load(llm_conf_path());
            hasKeyMeta = !cfg.apiKey.empty();
        }
        std::string summaryKind = "";
        std::string summaryTarget = "";
        std::string summaryArtist = "";
        std::string summaryEid = "";
        bool summaryCached = false;
        // 单曲播放页显示的是【所属专辑】的简介，不是每首歌各调一次（用户 261023-03 #3）。
        // 但标签缺失/在线补全把 album 覆盖成歌名时（实测：合辑单曲、假文件被在线匹配），
        // 若仍按 release 生成就会变成「每首歌一次调用」→ 烧钱且内容重复。
        // 这里加一道保守回退：album 为空或 album==title 时改按【艺术家】取 person 简介（按艺术家缓存一次）。
        // 实体 ID 里的 artist 必须与前端请求时带的 artist 完全一致，否则同一张专辑会算出
        // 两个缓存键 → 明明有缓存却闪「正在整理资料」/ 重复付费（2026-10-23 DEBUG 定位）。
        // 统一口径：albumArtist 优先，缺省用 artist；并把它作为 summaryArtist 回给前端。
        const std::string album_artist_for_key = !fAlbumArtist.empty() ? fAlbumArtist : fArtist;
        const bool album_usable = !fAlbum.empty() && fAlbum != fTitle;
        if (album_usable) {
            summaryKind = "release";
            summaryTarget = fAlbum;
            summaryArtist = album_artist_for_key;
            summaryEid = (!album_artist_for_key.empty())
                ? rta::meta::entity_make_id("release", rta::meta::entity_norm(album_artist_for_key) + "\x1f" + rta::meta::entity_norm(fAlbum))
                : rta::meta::entity_id(rta::meta::EntityKind::Release, fAlbum);
        } else if (!album_artist_for_key.empty()) {
            summaryKind = "person";
            summaryTarget = album_artist_for_key;
            summaryArtist = album_artist_for_key;
            summaryEid = rta::meta::entity_id(rta::meta::EntityKind::Person, album_artist_for_key);
        }
        bool summaryCacheOk = false;   // 有任何可读缓存（含已过期 → 无 key 时的离线回退）
        if (!summaryEid.empty()) {
            rta::meta::SummaryResult srCached;
            std::string cErr;
            if (rta::meta::summary_load_cache(metabaseDir, summaryEid, "zh", srCached, &cErr) && srCached.ok) {
                summaryCacheOk = true;
                summaryCached = !rta::meta::summary_is_expired(srCached);
            }
        }
        // 可用 = 开关开 且（有缓存 或 有 key 能现场整理）。三者任一不成立 → 前端干脆不显示板块。
        const bool summaryAvailable = msMeta.summary && (summaryCacheOk || hasKeyMeta);
        std::ostringstream j;
        j << "{\"ok\":true"
          << ",\"title\":\"" << jesc(fTitle) << "\""
          << ",\"artist\":\"" << jesc(fArtist) << "\""
          << ",\"album\":\"" << jesc(fAlbum) << "\""
          << ",\"albumArtist\":\"" << jesc(fAlbumArtist) << "\""
          << ",\"year\":\"" << jesc(fYear) << "\""
          << ",\"genre\":\"" << jesc(fGenre) << "\""
          << ",\"lyrics\":\"" << jesc(fLyrics) << "\""
          << ",\"date\":\"" << jesc(mi.date) << "\""
          << ",\"track\":\"" << jesc(mi.track) << "\""
          << ",\"codec\":\"" << jesc(mi.codec) << "\""
          << ",\"sampleRate\":" << mi.sampleRate
          << ",\"channels\":" << mi.channels
          << ",\"bits\":" << mi.bits
          << ",\"hasCover\":" << (hasCover ? "true" : "false")
          << ",\"meta\":{\"enriched\":" << (meta_enriched(tm) ? "true" : "false")   // F2：真被在线补过才算
          << ",\"sources\":{";
        {
            bool firstS = true;
            for (const auto& kv : metaSrc) {
                if (!firstS) j << ",";
                firstS = false;
                j << "\"" << jesc(kv.first) << "\":\"" << jesc(kv.second) << "\"";
            }
        }
        j << "}}"
          << ",\"summaryAvailable\":" << (summaryAvailable ? "true" : "false")
          << ",\"summaryCached\":" << (summaryCached ? "true" : "false")
          << ",\"summaryCacheOk\":" << (summaryCacheOk ? "true" : "false")
          << ",\"summaryKind\":\"" << jesc(summaryKind) << "\""
          << ",\"summaryTarget\":\"" << jesc(summaryTarget) << "\""
          << ",\"summaryArtist\":\"" << jesc(summaryArtist) << "\""
          << ",\"hasLlmKey\":" << (hasKeyMeta ? "true" : "false")
          << ",\"summaryEnabled\":" << (msMeta.summary ? "true" : "false")
          << "}";
        return j.str();
    }

    // ---------------- 标签写回(P2):预览 / 起批 / 状态轮询 ----------------
    // GET  /api/writeback(?dry=1)   纯只读扫描:记录数/可写数(有非空字段且非 DSD)/
    //                               逐条预览 JSON;不跑 ffmpeg、不写任何文件
    // POST /api/writeback {"apply":true}  起后台线程执行 writeback_library,立即返回;
    //                               已有批次在跑时 {"ok":false,"running":true}
    // GET  /api/writeback/status    {"running","done","total","written","skipped",
    //                               "failed","lastFailures"[≤10],"error"}
    if (rq.path.rfind("/api/writeback", 0) == 0) {
        ct = "application/json; charset=utf-8";
        if (rq.path.rfind("/api/writeback/status", 0) == 0) {
            std::lock_guard<std::mutex> lk(g_wb.mtx);
            std::ostringstream j;
            j << "{\"ok\":true,\"running\":" << (g_wb.running ? "true" : "false")
              << ",\"dryRun\":" << (g_wb.dryRun ? "true" : "false")
              << ",\"done\":" << g_wb.done << ",\"total\":" << g_wb.total
              << ",\"written\":" << g_wb.written << ",\"skipped\":" << g_wb.skipped
              << ",\"failed\":" << g_wb.failed
              << ",\"error\":\"" << jesc(g_wb.err) << "\",\"lastFailures\":[";
            for (size_t i = 0; i < g_wb.lastFailures.size(); ++i) {
                if (i) j << ",";
                j << "{\"file\":\"" << jesc(g_wb.lastFailures[i].first)
                  << "\",\"err\":\"" << jesc(g_wb.lastFailures[i].second) << "\"}";
            }
            j << "]}";
            return j.str();
        }
        if (rq.method == "POST") {
            bool apply = false;
            const rta::net::Json jb = rta::net::json_parse(rq.body);
            if (jb.type == rta::net::Json::Obj && jb.has("apply"))
                apply = (jb["apply"].type == rta::net::Json::Bool) ? jb["apply"].b
                                                                   : (jb["apply"].n() != 0.0);
            if (!writeback_start(apply))
                return "{\"ok\":false,\"started\":false,\"running\":true,"
                       "\"error\":\"已有写回批次在进行中(见 /api/writeback/status)\"}";
            return std::string("{\"ok\":true,\"started\":true,\"apply\":") +
                   (apply ? "true" : "false") + "}";
        }
        // GET:预览扫描(纯只读,无 IO 写)
        const WbPreview w = writeback_preview_scan();
        std::ostringstream j;
        j << "{\"ok\":" << (w.err.empty() ? "true" : "false")
          << ",\"total\":" << w.total << ",\"writable\":" << w.writable
          << ",\"skipped\":" << w.skipped;
        if (!w.err.empty()) j << ",\"error\":\"" << jesc(w.err) << "\"";
        j << ",\"items\":[";
        for (size_t i = 0; i < w.items.size(); ++i) {
            if (i) j << ",";
            j << "{\"file\":\"" << jesc(w.items[i].file) << "\",\"writable\":"
              << (w.items[i].writable ? "true" : "false")
              << ",\"fields\":\"" << jesc(w.items[i].fields)
              << "\",\"reason\":\"" << jesc(w.items[i].reason) << "\"}";
        }
        j << "]}";
        return j.str();
    }

    // ---------------- 资料层(P3④a 实体权威文本与来源 materials): GET /api/entity/knowledge ----------------
    if (rq.path.rfind("/api/entity/knowledge", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string kindStr = "person";
        std::string name;
        std::string lang = "zh";
        bool refresh = false;

        const size_t qpos = rq.path.find('?');
        if (qpos != std::string::npos) {
            std::istringstream is(rq.path.substr(qpos + 1));
            std::string tok;
            while (std::getline(is, tok, '&')) {
                const size_t eq = tok.find('=');
                if (eq == std::string::npos) continue;
                const std::string k = urlDecode(tok.substr(0, eq));
                const std::string v = urlDecode(tok.substr(eq + 1));
                if (k == "kind") kindStr = v;
                else if (k == "name") name = v;
                else if (k == "refresh") refresh = (v == "1" || v == "true");
                else if (k == "lang") lang = v;
            }
        }
        if (name.empty()) {
            return "{\"ok\":false,\"entity\":{\"id\":\"\",\"kind\":\"" + jesc(kindStr) +
                   "\",\"name\":\"\"},\"materials\":[],\"errors\":[{\"source\":\"params\",\"error\":\"未指定实体名称\"}],\"from_cache\":false,\"offline\":false}";
        }
        rta::meta::EntityKind ek = rta::meta::EntityKind::Person;
        if (!rta::meta::entity_kind_from_tag(kindStr, ek)) {
            return "{\"ok\":false,\"entity\":{\"id\":\"\",\"kind\":\"" + jesc(kindStr) +
                   "\",\"name\":\"" + jesc(name) + "\"},\"materials\":[],\"errors\":[{\"source\":\"params\",\"error\":\"未知实体类型: " + jesc(kindStr) + "\"}],\"from_cache\":false,\"offline\":false}";
        }

        rta::meta::KnowledgeOpts opts;
        opts.metabase = path_in_exe_dir("rlplayer-meta");
        opts.refresh = refresh;
        if (!lang.empty()) opts.lang = lang;

        const rta::meta::KnowledgeResult kr = rta::meta::knowledge_fetch(ek, name, opts);
        const bool ok = !kr.materials.empty();
        const std::string entId = kr.entityId.empty() ? rta::meta::entity_id(ek, name) : kr.entityId;
        const std::string kindTag = rta::meta::entity_kind_tag(ek);

        std::ostringstream j;
        j << "{\"ok\":" << (ok ? "true" : "false")
          << ",\"entity\":{"
          << "\"id\":\"" << jesc(entId) << "\","
          << "\"kind\":\"" << jesc(kindTag) << "\","
          << "\"name\":\"" << jesc(name) << "\""
          << "},"
          << "\"materials\":[";
        for (size_t i = 0; i < kr.materials.size(); ++i) {
            if (i) j << ",";
            const auto& m = kr.materials[i];
            j << "{"
              << "\"source\":\"" << jesc(m.source) << "\","
              << "\"kind\":\"" << jesc(m.kind) << "\","
              << "\"subject\":\"" << jesc(m.subject) << "\","
              << "\"title\":\"" << jesc(m.title) << "\","
              << "\"text\":\"" << jesc(m.text) << "\","
              << "\"url\":\"" << jesc(m.url) << "\","
              << "\"lang\":\"" << jesc(m.lang) << "\","
              << "\"fetched_at\":" << m.fetched_at << ","
              << "\"expires_at\":" << m.expires_at << ","
              << "\"authority\":" << m.authority
              << "}";
        }
        j << "],\"errors\":[";
        bool firstErr = true;
        for (const auto& ep : kr.errors) {
            if (!firstErr) j << ",";
            firstErr = false;
            j << "{\"source\":\"" << jesc(ep.first) << "\",\"error\":\"" << jesc(ep.second) << "\"}";
        }
        if (!ok && kr.errors.empty()) {
            const std::string errText = !kr.error.empty() ? kr.error : "未找到任何相关权威材料";
            j << "{\"source\":\"general\",\"error\":\"" << jesc(errText) << "\"}";
        }
        j << "],"
          << "\"from_cache\":" << (kr.from_cache ? "true" : "false") << ","
          << "\"offline\":" << (kr.offline ? "true" : "false")
          << "}";
        return j.str();
    }

    // ---------------- 资料层(P3③ 检索综合): GET /api/entity/summary ----------------
    if (rq.path.rfind("/api/entity/summary", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string kindStr = "person";
        std::string name;
        std::string artist;
        std::string lang = "zh";
        bool refresh = false;

        const size_t qpos = rq.path.find('?');
        if (qpos != std::string::npos) {
            std::istringstream is(rq.path.substr(qpos + 1));
            std::string tok;
            while (std::getline(is, tok, '&')) {
                const size_t eq = tok.find('=');
                if (eq == std::string::npos) continue;
                const std::string k = urlDecode(tok.substr(0, eq));
                const std::string v = urlDecode(tok.substr(eq + 1));
                if (k == "kind") kindStr = v;
                else if (k == "name") name = v;
                else if (k == "artist") artist = v;
                else if (k == "refresh") refresh = (v == "1" || v == "true");
                else if (k == "lang") lang = v;
            }
        }
        if (name.empty()) {
            return "{\"ok\":false,\"error\":\"未指定实体名称\"}";
        }
        // ---- 歌曲级简介（261023-04 #7）：没有任何权威源可引，走 AI 自有知识 + unverified 标注，
        //      按 artist+title 归键缓存；同样把这个耗时操作放后台线程，前端轮询。 ----
        if (kindStr == "track" || kindStr == "song") {
            const std::string eidTrack = rta::meta::entity_make_id(
                "track", rta::meta::entity_norm(artist) + "\x1f" + rta::meta::entity_norm(name));
            const MetaSettings msT = meta_settings_load();
            if (!msT.summary) {
                return "{\"ok\":false,\"error\":\"未开启在线资料整理\",\"summaryEnabled\":false,"
                       "\"summaryKind\":\"track\",\"summaryCached\":false}";
            }
            const std::string metabaseT = path_in_exe_dir("rlplayer-meta");
            if (!refresh) {
                rta::meta::SummaryResult cached;
                std::string cErr;
                if (rta::meta::summary_load_cache(metabaseT, eidTrack, lang, cached, &cErr) && cached.ok &&
                    !rta::meta::summary_is_expired(cached)) {
                    cached.from_cache = true;
                    return summary_json_with_flags(cached, "track", true);
                }
            }
            rta::meta::RetrievalOptions ropts;
            ropts.metabase = metabaseT;
            ropts.refresh = refresh;
            ropts.llm_cfg = rta::meta::llm_config_load(llm_conf_path());
            const std::string jobKey = eidTrack + "|" + lang;
            {
                std::lock_guard<std::mutex> lk(g_summ_mu);
                const long long now = (long long)std::time(nullptr);
                for (auto it = g_summ_jobs.begin(); it != g_summ_jobs.end();) {
                    if (it->second.done && it->second.finished_at > 0 && now - it->second.finished_at > 600)
                        it = g_summ_jobs.erase(it);
                    else ++it;
                }
                auto it = g_summ_jobs.find(jobKey);
                if (it != g_summ_jobs.end() && it->second.done) {
                    std::string body = it->second.body;
                    g_summ_jobs.erase(it);
                    return body;
                }
                if (it == g_summ_jobs.end() || !it->second.running) {
                    SummaryJob job;
                    job.running = true;
                    job.started_at = now;
                    g_summ_jobs[jobKey] = job;
                    play_log("SUMMARY generate(async) kind=track name=" + name);
                    summary_job_start_fn(jobKey, "track", name, [name, artist, lang, ropts]() {
                        return rta::meta::retrieval_fetch_track(name, artist, lang, ropts);
                    });
                }
            }
            return "{\"ok\":false,\"pending\":true,\"error\":\"正在整理资料\",\"summaryKind\":\"track\",\"summaryCached\":false}";
        }
        if (kindStr == "album") kindStr = "release";
        rta::meta::EntityKind ek = rta::meta::EntityKind::Person;
        if (!rta::meta::entity_kind_from_tag(kindStr, ek)) {
            return "{\"ok\":false,\"error\":\"未知实体类型: " + jesc(kindStr) + "\"}";
        }

        const MetaSettings ms = meta_settings_load();
        const std::string metabaseDir = path_in_exe_dir("rlplayer-meta");

        // 统一实体 ID：针对 Release 若带 artist 则纳入归一键，与 retrieval_fetch 保持完全一致
        const std::string eid = (!artist.empty() && ek == rta::meta::EntityKind::Release)
            ? rta::meta::entity_make_id("release", rta::meta::entity_norm(artist) + "\x1f" + rta::meta::entity_norm(name))
            : rta::meta::entity_id(ek, name);

        // 1. 开关关闭：拒绝（前端也不显示板块；不产生任何在线调用）
        if (!ms.summary) {
            return "{\"ok\":false,\"error\":\"未开启在线资料整理\",\"summaryEnabled\":false,"
                   "\"summaryKind\":\"" + jesc(kindStr) + "\",\"summaryCached\":false}";
        }

        // 2. 缓存命中（TTL 7 天）→ 直接返回，绝不再调 LLM（用户 261023-03 #2：生成后保存为缓存）
        if (!refresh) {
            rta::meta::SummaryResult cached;
            std::string cache_err;
            if (rta::meta::summary_load_cache(metabaseDir, eid, lang, cached, &cache_err) && cached.ok &&
                !rta::meta::summary_is_expired(cached)) {
                cached.from_cache = true;
                play_log("SUMMARY cache-hit kind=" + kindStr + " name=" + name + " eid=" + eid);
                return summary_json_with_flags(cached, kindStr, true);
            }
        }

        // 3. 未命中（或显式 refresh）→ **后台生成**，handler 立即返回 pending，前端轮询。
        //    绝不在这条单线程 accept 路径里同步跑网络+LLM（否则整站卡死，见 summary_job_start 注释）。
        rta::meta::RetrievalOptions ropts;
        ropts.metabase = metabaseDir;
        ropts.artist = artist;
        ropts.entity_id = eid;
        ropts.refresh = refresh;
        ropts.timeout_ms = 25000;
        ropts.llm_cfg = rta::meta::llm_config_load(llm_conf_path());   // 与设置页写的 key 同一份

        const std::string jobKey = eid + "|" + lang;
        {
            std::lock_guard<std::mutex> lk(g_summ_mu);
            // 清理 10 分钟前的陈旧任务，避免 map 无限增长（正常前端拿到结果就会取走）
            const long long now = (long long)std::time(nullptr);
            for (auto it = g_summ_jobs.begin(); it != g_summ_jobs.end();) {
                if (it->second.done && it->second.finished_at > 0 && now - it->second.finished_at > 600) {
                    it = g_summ_jobs.erase(it);
                } else ++it;
            }
            auto it = g_summ_jobs.find(jobKey);
            if (it != g_summ_jobs.end() && it->second.done) {
                std::string body = it->second.body;
                g_summ_jobs.erase(it);   // 一次性交付；下次直接命中磁盘缓存
                return body;
            }
            if (it == g_summ_jobs.end() || !it->second.running) {
                SummaryJob job;
                job.running = true;
                job.started_at = now;
                g_summ_jobs[jobKey] = job;
                play_log("SUMMARY generate(async) kind=" + kindStr + " name=" + name + " eid=" + eid);
                summary_job_start(jobKey, ek, name, lang, kindStr, ropts);
            }
        }
        return "{\"ok\":false,\"pending\":true,\"error\":\"正在整理资料\",\"summaryKind\":\"" +
               jesc(kindStr) + "\",\"summaryCached\":false}";
    }

    // ---------------- 资料层(P3④b Discogs L4 古典作品版本推荐): GET /api/entity/versions ----------------
    if (rq.path.rfind("/api/entity/versions", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string kindStr = "work";
        std::string name;
        std::string composer;
        bool refresh = false;

        const size_t qpos = rq.path.find('?');
        if (qpos != std::string::npos) {
            std::istringstream is(rq.path.substr(qpos + 1));
            std::string tok;
            while (std::getline(is, tok, '&')) {
                const size_t eq = tok.find('=');
                if (eq == std::string::npos) continue;
                const std::string k = urlDecode(tok.substr(0, eq));
                const std::string v = urlDecode(tok.substr(eq + 1));
                if (k == "name" || k == "title") name = v;
                else if (k == "composer") composer = v;
                else if (k == "refresh") refresh = (v == "1" || v == "true");
                else if (k == "kind") kindStr = v;
            }
        }
        if (name.empty()) {
            return "{\"ok\":false,\"error\":\"未指定作品名称\"}";
        }

        rta::meta::DiscogsOptions dopts;
        dopts.metabase = path_in_exe_dir("rlplayer-meta");
        dopts.refresh = refresh;
        dopts.timeout_ms = 15000;

        const rta::meta::WorkVersionsResult wr = rta::meta::discogs_versions(name, composer, dopts);
        return rta::meta::work_versions_to_json(wr);
    }

    if (rq.path.rfind("/api/cover", 0) == 0) {
        std::string file;
        const size_t q = rq.path.find("?file=");
        if (q != std::string::npos) file = urlDecode(rq.path.substr(q + 6));
        if (!file.empty() && !valid_utf8(file)) {   // F1：get_cover/MetaStore 内部消费路径
            ct = "application/json; charset=utf-8";
            return utf8_path_reject(file);
        }
        std::string mime = "image/png";
        std::vector<unsigned char> bytes;
        if (!file.empty()) bytes = rta::audio::get_cover(file, mime);
        // 内嵌/本地图片读取失败(≤128B = get_cover 的占位 PNG)→ MetaStore 缓存封面兜底
        if (file.empty() || bytes.size() <= 128) {
            std::vector<unsigned char> mb;
            std::string mm;
            if (!file.empty() && rta::meta::MetaStore::instance().cover(file, mb, mm) && !mb.empty()) {
                bytes = std::move(mb);
                mime = mm;
            }
        }
        ct = mime;
        return std::string(bytes.begin(), bytes.end());
    }

    if (rq.path.rfind("/api/shuffle", 0) == 0) {
        ct = "application/json; charset=utf-8";
        int on = 1;
        const size_t q = rq.path.find("?on=");
        if (q != std::string::npos) on = atoi(rq.path.c_str() + q + 4);
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            // 记住"正在播的那首"，重排后要让 index 仍然指向它，
            // 否则一按随机就会跳歌（这是最容易被用户当成 bug 的细节）
            // 记住整项（不是只记路径）：cue 专辑里同一路径有 N 项，只按路径还原会跳到第 1 首
            const QItem cur = (g_q.index < g_q.items.size()) ? g_q.items[g_q.index] : QItem();
            const bool want = (on != 0);
            const bool was = g_q.shuffle_of();
            // R-4：shuffle 不再是独立字段，而是 mode 的派生写入口
            //   on  → mode=3（随机）
            //   off → mode=0（顺序）—— 与旧行为一致：关随机后回到不循环的顺序播放
            if (want && !was) {
                g_q.base = g_q.items;                 // 保存原顺序，关掉时能还原
                if (g_q.items.size() > 1) {
                    std::mt19937 rng((unsigned)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
                    std::shuffle(g_q.items.begin(), g_q.items.end(), rng);
                }
                g_q.mode = 3;
            } else if (!want && was) {
                if (!g_q.base.empty()) g_q.items = g_q.base;   // 还原原始顺序
                g_q.mode = 0;
            }
            if (!cur.path.empty()) {
                for (size_t i = 0; i < g_q.items.size(); ++i)
                    if (g_q.items[i].same(cur)) { g_q.index = i; break; }
            }
        }
        queue_save();
        return std::string("{\"ok\":true,\"shuffle\":") + (on ? "true" : "false") + "}";
    }
    // ---------------- 整列替换队列（#5 播放全部 / 具名队列播放共用）----------------
    // POST /api/queue/set  body: files=<urlencoded>，值为多行文本，每行一项：
    //   普通曲目 = <路径>；CUE 分轨 = <路径><TAB><cs><TAB><ce>（与 rlplayer-playlist.txt 同格式）
    if (rq.path.rfind("/api/queue/set", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string files;
        {
            std::istringstream is(rq.body);
            std::string tok;
            while (std::getline(is, tok, '&')) {
                const size_t e = tok.find('=');
                if (e == std::string::npos) continue;
                if (urlDecode(tok.substr(0, e)) == "files") files = urlDecode(tok.substr(e + 1));
            }
        }
        std::vector<QItem> items;
        {
            std::istringstream ls(files);
            std::string line;
            while (std::getline(ls, line)) {
                if (!line.empty() && line.back() == '\r') line.pop_back();
                if (line.empty()) continue;
                items.push_back(item_from_line(line));
            }
        }
        if (items.empty()) return "{\"ok\":false,\"error\":\"曲目列表为空\"}";
        for (const auto& it : items)
            if (!valid_utf8(it.path)) return utf8_path_reject(it.path);
        size_t cnt = 0;
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            g_q.items = std::move(items);
            g_q.index = 0;
            g_q.base.clear();
            g_q.sortBase.clear();
            cnt = g_q.items.size();
        }
        queue_save();
        return "{\"ok\":true,\"count\":" + std::to_string(cnt) + "}";
    }
    if (rq.path.rfind("/api/queue", 0) == 0) {
        ct = "application/json; charset=utf-8";
        const bool wantMeta = rq.path.find("meta=1") != std::string::npos;
        std::vector<QItem> items;
        size_t index = 0;
        int mode = 0;
        bool shuffle = false;
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            items = g_q.items;
            index = g_q.index;
            mode = g_q.mode;
            shuffle = g_q.shuffle_of();
        }
        std::map<std::string, rta::net::LibTrack> meta;
        if (wantMeta && !items.empty()) {
            std::set<std::string> want;
            for (const auto& it : items) want.insert(rta::net::lib_path_key(it.path));
            auto& lib = rta::net::Library::instance();
            const size_t nt = lib.trackCount();
            for (size_t i = 0; i < nt; ++i) {
                rta::net::LibTrack t;
                if (!lib.trackAt(i, t)) continue;
                const std::string k = rta::net::lib_path_key(t.path);
                if (!want.count(k)) continue;
                meta.emplace(k, std::move(t));
                if (meta.size() >= want.size()) break;
            }
        }
        std::ostringstream j;
        j << "{\"ok\":true,\"index\":" << index
          << ",\"repeat\":" << ((mode == 1) ? 1 : (mode == 2) ? 2 : 0)
          << ",\"shuffle\":" << (shuffle ? "true" : "false")
          << ",\"mode\":" << mode << ",\"items\":[";
        for (size_t i = 0; i < items.size(); ++i) {
            if (i) j << ",";
            j << "\"" << jesc(items[i].path) << "\"";
        }
        j << "],\"cues\":[";
        for (size_t i = 0; i < items.size(); ++i) {
            if (i) j << ",";
            j << "[" << items[i].cs << "," << items[i].ce << "]";
        }
        j << "]";
        if (wantMeta) {
            j << ",\"metas\":[";
            for (size_t i = 0; i < items.size(); ++i) {
                if (i) j << ",";
                std::string t, a, al;
                int y = 0;
                double d = 0.0;
                const bool isCue = items[i].isCue() && items[i].ce > items[i].cs;
                if (isCue) d = items[i].ce - items[i].cs;
                auto f = meta.find(rta::net::lib_path_key(items[i].path));
                if (f != meta.end()) {
                    t = f->second.title;
                    a = f->second.artist;
                    al = f->second.album;
                    y = f->second.year;
                    if (!isCue) d = f->second.duration;
                }
                j << "{\"t\":\"" << jesc(t) << "\",\"a\":\"" << jesc(a)
                  << "\",\"al\":\"" << jesc(al) << "\",\"d\":" << d << ",\"y\":" << y << "}";
            }
            j << "]";
        }
        j << "}";
        return j.str();
    }

    if (rq.path.rfind("/api/clear", 0) == 0) {
        ct = "application/json; charset=utf-8";
        ps.stopJoin();          // 原子停线程（并发请求下不再撞 thread 赋值 terminate）
        ps.playing.store(false);
        // 清空队列同时结束投放会话（否则渲染器还会继续播上一首）
        g_upnpPlayer.store(false);
        if (rta::net::CastManager::instance().get_state().running)
            rta::net::CastManager::instance().stop();
        {
            std::lock_guard<std::mutex> lk(g_lastEndMx);
            g_lastEnd.isPosZeroNoErr = false;
        }
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            g_q.items.clear();
            g_q.index = 0;
            g_q.sortBase.clear();
        }
        queue_save();
        return "{\"ok\":true}";
    }

    // 兼容端点：/api/repeat（0=关 1=列表循环 2=单曲循环）⟹ 派生写 mode
    if (rq.path.rfind("/api/repeat", 0) == 0) {
        ct = "application/json; charset=utf-8";
        PlayParams p = parseForm(rq.body);
        int old = atoi(p.rate.c_str());
        if (old < 0 || old > 2) old = 0;
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            const bool wasShuffle = g_q.shuffle_of();
            // 旧语义：repeat 0/1/2 都是"非随机"；切到非随机要还原顺序
            if (wasShuffle) {
                if (!g_q.base.empty()) g_q.items = g_q.base;
            }
            g_q.mode = old;          // 0→0 顺序，1→1 列表循环，2→2 单曲循环
        }
        queue_save();
        return std::string("{\"ok\":true,\"repeat\":") + std::to_string(old) + "}";
    }

    if (rq.path.rfind("/api/skip", 0) == 0) {
        // ?dir=1 下一首，?dir=-1 上一首
        ct = "application/json; charset=utf-8";
        int dir = 1;
        const size_t q = rq.path.find("?dir=");
        if (q != std::string::npos) dir = atoi(rq.path.c_str() + q + 5);

        ps.stopJoin();          // 原子停线程

        PlayParams p = params_snapshot();
        size_t target = 0;
        bool ok = false;
        {
            std::lock_guard<std::mutex> lk(g_q.mtx);
            if (g_q.items.empty()) return "{\"ok\":false,\"error\":\"队列为空\"}";
            if (dir > 0) {
                if (g_q.index + 1 < g_q.items.size()) { target = g_q.index + 1; ok = true; }
                else if (g_q.mode != 0) { target = 0; ok = true; }   // R-4：循环/随机都可回绕
            } else {
                if (g_q.index > 0) { target = g_q.index - 1; ok = true; }
                else if (g_q.mode != 0) { target = g_q.items.size() - 1; ok = true; }
            }
        }
        if (!ok) return "{\"ok\":false,\"error\":\"已到队列边界\"}";
        ps.played.store(0);
        ps.total.store(0);
        // 后端 = UPnP / DLNA：切歌同样转交投放会话（停旧会话 → 起新会话），
        // 保证底栏「下一首 / 上一首」在投放模式下行为与本地播放一致。
        if (p.backend == "upnp") {
            std::string targetFile;
            {
                std::lock_guard<std::mutex> lk(g_q.mtx);
                targetFile = g_q.items[target].path;
            }
            std::string err;
            if (!upnp_start_track(p, targetFile, err)) {
                upnp_mark_player_state(targetFile, false, err);
                ps.playing.store(false);
                g_upnpPlayer.store(false);
                return std::string("{\"ok\":false,\"error\":\"") + jesc(err) + "\"}";
            }
            g_upnpPlayer.store(true);
            upnp_mark_player_state(targetFile, true, "");
            ps.outRate = 0;
            ps.outBits = 0;
            ps.playing.store(true);
            return "{\"ok\":true,\"index\":" + std::to_string(target) + ",\"upnp\":true}";
        }
        ps.playing.store(true);
        ps.restart([p, target] { return queue_thread(p, target); });
        return "{\"ok\":true,\"index\":" + std::to_string(target) + "}";
    }

    // ---------------- UPnP/DLNA 媒体投放（ROADMAP P5b）----------------
    // 2026-10-25：SSDP 协议栈已 POSIX 移植（src/net/upnp.h / upnp_control.h），
    // 四个子路由全部接真实 CastManager，不再有桩。
    if (rq.path.rfind("/api/cast", 0) == 0) {
        ct = "application/json; charset=utf-8";
        if (rq.path.rfind("/api/cast/devices", 0) == 0) {
            const bool forceRescan = (rq.path.find("scan=1") != std::string::npos ||
                                      rq.path.find("rescan=1") != std::string::npos);
            auto devs = rta::net::CastManager::instance().get_devices(forceRescan);
            std::ostringstream j;
            j << "{\"ok\":true,\"n\":" << devs.size() << ",\"devices\":[";
            for (size_t i = 0; i < devs.size(); ++i) {
                if (i) j << ",";
                // WebUI 的 castDevValue() 取 location 作为下拉 value（直连描述 URL 比按名字匹配可靠），
                // castDevLabel() 读 friendlyName + model；npPickCastDevice 读 friendlyName/name/host/model。
                j << "{\"name\":\"" << jesc(devs[i].name) << "\""
                  << ",\"friendlyName\":\"" << jesc(devs[i].name) << "\""
                  << ",\"model\":\"" << jesc(devs[i].model) << "\""
                  << ",\"host\":\"" << jesc(devs[i].host) << "\""
                  << ",\"port\":" << devs[i].port
                  << ",\"location\":\"" << jesc(devs[i].location) << "\""
                  << ",\"controlUrl\":\"" << jesc(devs[i].av_transport_url()) << "\""
                  << ",\"avTransportUrl\":\"" << jesc(devs[i].av_transport_url()) << "\""
                  << ",\"connectionManagerUrl\":\"" << jesc(devs[i].connection_manager_url()) << "\""
                  << ",\"hasAVTransport\":" << (!devs[i].control.empty() ? "true" : "false")
                  << "}";
            }
            j << "]}";
            return j.str();
        }
        if (rq.path.rfind("/api/cast/state", 0) == 0) {
            auto st = rta::net::CastManager::instance().get_state();
            std::ostringstream j;
            j << "{\"ok\":true"
              << ",\"running\":" << (st.running ? "true" : "false")
              << ",\"device\":\"" << jesc(st.device) << "\""
              << ",\"sourceFile\":\"" << jesc(st.sourceFile) << "\""
              << ",\"servePort\":" << st.servePort
              << ",\"phase\":\"" << jesc(st.phase) << "\""
              << ",\"positionSec\":" << st.positionSec
              << ",\"transportState\":\"" << jesc(st.transportState) << "\""
              << ",\"servedBytes\":" << st.servedBytes
              << ",\"requestCount\":" << st.requestCount
              << ",\"rateMatch\":\"" << jesc(st.rateMatch) << "\""
              << ",\"warning\":\"" << jesc(st.warning) << "\""
              << ",\"error\":\"" << jesc(st.error) << "\""
              // 261024-01 #9：后端 = UPnP 时播放器底栏的进度/时长/格式/暂停也取这份数据
              //（一条会话、一个状态源，避免底栏与投放面板各显示一套进度）
              << ",\"durationSec\":" << st.durationSec
              << ",\"sampleRate\":" << st.sampleRate
              << ",\"bits\":" << st.bits
              << ",\"paused\":" << (st.paused ? "true" : "false")
              << "}";
            return j.str();
        }
        if (rq.path.rfind("/api/cast/start", 0) == 0) {
            if (rq.method != "POST") return "{\"ok\":false,\"error\":\"Method Not Allowed\"}";
            rta::net::CastStartParams p;
            // body 同时支持 JSON 与 k=v&k=v（照历史实现；WebUI 用空 body 表单风格）
            if (!rq.body.empty() && rq.body.front() == '{') {
                auto j = rta::net::json_parse(rq.body);
                if (j.has("dev")) p.dev = j["dev"].s();
                if (j.has("file")) p.file = j["file"].s();
                if (j.has("port")) p.port = (uint16_t)j["port"].n();
                if (j.has("rate")) p.rate = (uint32_t)j["rate"].n();
                if (j.has("bits")) p.bits = (int)j["bits"].n();
                if (j.has("seconds")) p.seconds = j["seconds"].n();
                if (j.has("dop")) p.dop = (j["dop"].type == rta::net::Json::Bool) ? j["dop"].b : (j["dop"].n() != 0.0);
            } else {
                std::istringstream is(rq.body);
                std::string tok;
                while (std::getline(is, tok, '&')) {
                    size_t eq = tok.find('=');
                    if (eq == std::string::npos) continue;
                    std::string k = urlDecode(tok.substr(0, eq));
                    std::string v = urlDecode(tok.substr(eq + 1));
                    if (k == "dev") p.dev = v;
                    else if (k == "file") p.file = v;
                    else if (k == "port") p.port = (uint16_t)std::atoi(v.c_str());
                    else if (k == "rate") p.rate = (uint32_t)std::strtoul(v.c_str(), nullptr, 10);
                    else if (k == "bits") p.bits = std::atoi(v.c_str());
                    else if (k == "seconds") p.seconds = std::atof(v.c_str());
                    else if (k == "dop") p.dop = (v == "1" || v == "true");
                }
            }
            if (p.port == 0) p.port = 8912;
            // 一条会话原则（261024-01 #9）：手动「开始投放」先停本地播放，
            // 避免本机声卡与网络渲染器同时出声；播放器状态交给投放会话接管前先清零。
            ps.stopJoin();      // 原子停线程
            ps.playing.store(false);
            ps.paused.store(false);
            g_upnpPlayer.store(false);
            auto res = rta::net::CastManager::instance().start(p);
            if (!res.ok) {
                // 铁律：不假装成功 —— 真实原因原样透给前端
                return "{\"ok\":false,\"error\":\"" + jesc(res.error) + "\"}";
            }
            g_upnpPlayer.store(true);
            upnp_mark_player_state(p.file, true, "");
            return "{\"ok\":true,\"started\":true,\"phase\":\"discovering\"}";
        }
        if (rq.path.rfind("/api/cast/stop", 0) == 0) {
            rta::net::CastManager::instance().stop();
            g_upnpPlayer.store(false);
            ps.playing.store(false);
            ps.paused.store(false);
            return "{\"ok\":true,\"stopped\":true}";
        }
        return "{\"ok\":false,\"error\":\"未知的投放 API 路径\"}";
    }

    // ---------------- NAA 端点自动发现（261024-01 #11）----------------
    // 用户原话：「NAA 端点（host:port）这个选项不应该出现啊，应该是自动获取的啊」。
    // 异步扫描（tools/naa_discover.h）：先返回 scanning=true，前端 700ms 轮询；
    // 扫描完成后 30 秒内复用结果（?refresh=1 强制重扫）。
    if (rq.path.rfind("/api/naa", 0) == 0) {
        ct = "application/json; charset=utf-8";
        if (rq.path.rfind("/api/naa/discover", 0) == 0) {
            const bool force = (rq.path.find("refresh=1") != std::string::npos);
            return naa_discover_json(force);
        }
        return "{\"ok\":false,\"error\":\"未知的 NAA API 路径\"}";
    }

    if (rq.path.rfind("/api/upnp", 0) == 0) {
        ct = "application/json; charset=utf-8";
        // 2026-10-23（用户 261023-04 #11）：多网卡逐卡发 M-SEARCH + 诊断信息，
        // 并且在 JSON 里把"为什么没搜到"如实说出来（组播被代理/防火墙/AP 隔离拦截是最常见原因）。
        // 2026-10-25：macOS 侧 upnp.h 已 POSIX 移植，走同一份实现。
        rta::net::UpnpDiscoverDiag diag;
        const auto devs = rta::net::upnp_discover(1800, &diag);
        std::ostringstream j;
        j << "{\"ok\":true,\"n\":" << devs.size() << ",\"devices\":[";
        for (size_t i = 0; i < devs.size(); ++i) {
            if (i) j << ",";
            // WebUI（discoverDlna / bUpnp）读 name / model / host / port / loc
            j << "{\"name\":\"" << jesc(devs[i].name) << "\""
              << ",\"friendlyName\":\"" << jesc(devs[i].name) << "\""
              << ",\"model\":\"" << jesc(devs[i].model) << "\""
              << ",\"host\":\"" << jesc(devs[i].host) << "\""
              << ",\"port\":" << devs[i].port
              << ",\"loc\":\"" << jesc(devs[i].location) << "\""
              << ",\"location\":\"" << jesc(devs[i].location) << "\""
              << ",\"udn\":\"" << jesc(devs[i].udn) << "\""
              << "}";
        }
        j << "],\"diag\":{\"ifaces\":" << diag.ifaces_tried
          << ",\"sent\":" << diag.msgs_sent
          << ",\"note\":\"" << jesc(diag.note) << "\"}";
        if (devs.empty()) {
            j << ",\"hint\":\"未发现 UPnP 渲染器：SSDP 组播可能被代理(VPN/TUN)/防火墙/路由器 AP 隔离拦截。"
                 "可关闭代理后重试，或直接填设备地址（http://IP:端口/）直连。\"";
        }
        j << "}";
        return j.str();
    }
    // ---------------- DeepSeek API Key（2026-10-22 功能4）----------------
    // ★ 不并入 /api/settings：那个端点写 rlplayer-settings.conf（整文件重写），
    //   key 混进去会被诊断包 / 导出 / 同步顺手带走，而且 POST 白名单里也不该有它。
    //   本端点单独写 rlplayer-llm.conf，且 GET 只回掩码。
    if (rq.path.rfind("/api/llm", 0) == 0) {
        ct = "application/json; charset=utf-8";
        if (rq.path.rfind("/api/llm/test", 0) == 0) return llm_test_json();
        if (rq.method != "POST") return llm_status_json();

        std::map<std::string, std::string> f;
        {
            std::istringstream is(rq.body);
            std::string tok;
            while (std::getline(is, tok, (char)38)) {
                const size_t e = tok.find((char)61);
                if (e == std::string::npos) continue;
                f[urlDecode(tok.substr(0, e))] = urlDecode(tok.substr(e + 1));
            }
        }
        // 空 body 绝不落盘：GET/POST 撞车或前端 bug 时，整份配置不能被"空写"清掉。
        if (f.empty()) return "{\"ok\":false,\"error\":\"没有参数（拒绝空写入，避免误清空配置）\"}";
        const bool clear    = (f.count("clear") != 0) && (f["clear"] == "1" || f["clear"] == "true");
        const bool hasKey   = (f.count("key") != 0) && !f["key"].empty();
        const bool hasModel = (f.count("model") != 0) && !f["model"].empty();
        const bool hasBase  = (f.count("base_url") != 0) && !f["base_url"].empty();
        const bool hasCap   = (f.count("llmmonthlycap") != 0) || (f.count("monthly_cap") != 0);
        if (!clear && !hasKey && !hasModel && !hasBase && !hasCap)
            return "{\"ok\":false,\"error\":\"没有可保存的字段\"}";
        if (hasKey && !llm_value_ok(f["key"], 512))
            return "{\"ok\":false,\"error\":\"API Key 格式不对（不允许空格/控制字符，最长 512）\"}";
        if (hasModel && !llm_value_ok(f["model"], 128))
            return "{\"ok\":false,\"error\":\"模型名格式不对\"}";
        if (hasBase && !llm_value_ok(f["base_url"], 512))
            return "{\"ok\":false,\"error\":\"base_url 格式不对\"}";

        rta::meta::LlmConfig c = rta::meta::llm_config_load(llm_conf_path());
        std::string changed;
        auto note = [&changed](const char* s) { if (!changed.empty()) changed += ","; changed += s; };
        if (clear)         { c.apiKey.clear(); note("key"); }
        else if (hasKey)   { c.apiKey = f["key"]; note("key"); }
        if (hasModel)      { c.model = f["model"]; note("model"); }
        if (hasBase)       { c.baseUrl = rta::meta::llm_base_url(f["base_url"]); note("baseUrl"); }
        if (hasCap) {
            std::string capStr = f.count("llmmonthlycap") ? f["llmmonthlycap"] : f["monthly_cap"];
            c.monthlyCap = atoi(capStr.c_str());
            note("monthlyCap");
        }
        if (!rta::meta::llm_config_save_merge(c, llm_conf_path()))
            return "{\"ok\":false,\"error\":\"写入 rlplayer-llm.conf 失败（文件被占用？）\"}";
        // 日志只记「改了哪些字段 + 掩码」，绝不记值：launcher/playback 日志会进诊断包。
        play_log("LLM_CONF 更新 fields=" + changed +
                 " key=" + (c.apiKey.empty() ? std::string("(未设置)") : rta::meta::llm_mask_key(c.apiKey)) +
                 " model=" + c.model + " (proxy 行等既有内容保留)");
        std::string out = llm_status_json();
        if (!out.empty() && out.back() == '}') {
            out.pop_back();
            out += ",\"changed\":\"" + jesc(changed) + "\"}";
        }
        return out;
    }

    // ---------------- 20 段参数均衡 PEQ（261024-02 #6）----------------
    // GET  /api/peq            → 当前状态 + 预设列表 + 频响曲线
    // POST /api/peq            → 更新 bypass/preamp/bands（热更新 + 落盘），返回同样结构
    // POST /api/peq/preset     → action=save|load|delete|reset & name=...
    if (rq.path.rfind("/api/peq", 0) == 0) {
        ct = "application/json; charset=utf-8";
        if (!g_peq) peq_load_current();

        if (rq.path.rfind("/api/peq/preset", 0) == 0) {
            std::map<std::string, std::string> f;
            std::istringstream is(rq.body);
            std::string tok;
            while (std::getline(is, tok, '&')) {
                const size_t e = tok.find('=');
                if (e == std::string::npos) continue;
                f[urlDecode(tok.substr(0, e))] = urlDecode(tok.substr(e + 1));
            }
            const std::string action = f.count("action") ? f["action"] : "";
            const std::string name   = f.count("name") ? f["name"] : "";
            if (action == "reset") {
                rta::dsp::PeqSettings s = rta::dsp::peq_flat_settings();
                g_peq->set_settings(s);
                peq_save_current(s);
                return peq_state_json(true);
            }
            if (action == "save") {
                if (name.empty()) return "{\"ok\":false,\"error\":\"缺少预设名\"}";
                if (name.size() > 64) return "{\"ok\":false,\"error\":\"预设名太长（最多 64 字节）\"}";
                rta::dsp::PeqSettings s = g_peq->settings();
                s.presetName = name;
                std::map<std::string, rta::dsp::PeqSettings> user;
                peq_load_presets_file(user);
                user[name] = s;
                if (!peq_save_presets_file(user)) return "{\"ok\":false,\"error\":\"写预设文件失败\"}";
                g_peq->set_settings(s);
                peq_save_current(s);
                return peq_state_json(true);
            }
            if (action == "load") {
                rta::dsp::PeqSettings s;
                bool ok = false;
                if (rta::dsp::peq_builtin_preset(name, s)) {
                    ok = true;
                } else {
                    std::map<std::string, rta::dsp::PeqSettings> user;
                    peq_load_presets_file(user);
                    auto it = user.find(name);
                    if (it != user.end()) { s = it->second; s.presetName = name; ok = true; }
                }
                if (!ok) return "{\"ok\":false,\"error\":\"没有这个预设\"}";
                g_peq->set_settings(s);
                peq_save_current(s);
                return peq_state_json(true);
            }
            if (action == "delete") {
                std::map<std::string, rta::dsp::PeqSettings> user;
                peq_load_presets_file(user);
                if (user.erase(name) == 0) return "{\"ok\":false,\"error\":\"没有这个用户预设（内置预设不能删除）\"}";
                if (!peq_save_presets_file(user)) return "{\"ok\":false,\"error\":\"写预设文件失败\"}";
                return peq_state_json(true);
            }
            return "{\"ok\":false,\"error\":\"未知 action\"}";
        }

        if (rq.method == "POST") {
            std::map<std::string, std::string> f;
            std::istringstream is(rq.body);
            std::string tok;
            while (std::getline(is, tok, '&')) {
                const size_t e = tok.find('=');
                if (e == std::string::npos) continue;
                f[urlDecode(tok.substr(0, e))] = urlDecode(tok.substr(e + 1));
            }
            rta::dsp::PeqSettings s = g_peq->settings();
            if (f.count("bypass")) s.bypass = (f["bypass"] == "1" || f["bypass"] == "true");
            if (f.count("preamp")) s.preampDb = std::min(std::max(std::atof(f["preamp"].c_str()), -24.0), 24.0);
            if (f.count("name") && !f["name"].empty()) s.presetName = f["name"];
            if (f.count("bands")) {
                std::vector<rta::dsp::PeqBand> bands;
                if (!peq_parse_bands_param(f["bands"], bands))
                    return "{\"ok\":false,\"error\":\"bands 参数格式不对（应为 序号,类型,频率,增益,Q;...）\"}";
                s.bands = bands;
            }
            g_peq->set_settings(s);
            if (!peq_save_current(s)) return "{\"ok\":false,\"error\":\"写 rlplayer-peq.txt 失败\"}";
            return peq_state_json(true);
        }
        return peq_state_json(true);
    }

    // ---------------- 耳机 EQ（OPRA 预设管理）----------------
    if (rq.path.rfind("/api/opra/index", 0) == 0) {
        ct = "application/json; charset=utf-8";
        rta::dsp::OpraService::instance().init(rta::platform::module_dir_utf8() + "/data/opra_index.json", rta::platform::module_dir_utf8());
        const auto& index = rta::dsp::OpraService::instance().index();
        // 261023-03 第6条：显式带 ?q= 但值为空 → 返回空列表。
        // 用户抱怨「什么都没输入就匹配到 100 个」：旧逻辑 q 为空时会走「全量索引」分支。
        // 注意保留「不带 q 参数 = 全量索引」的老语义：前端第一次搜索时靠它一次性拉
        // data/opra_index.json 做本地过滤（loadOpraIndex），不能一起改空。
        std::string q;
        bool hasQ = false;
        const size_t qpos = rq.path.find("?q=");
        if (qpos != std::string::npos) {
            hasQ = true;
            q = urlDecode(rq.path.substr(qpos + 3));
            const size_t amp = q.find('&');      // 允许 &limit=... 之类后续参数
            if (amp != std::string::npos) q = q.substr(0, amp);
        }
        // 空白查询（?q=%20 / ?q=+）也要按空处理：用户 #6 的判据是「什么都没输入就不能列出型号」，
        // 不能只在 protocol 层挡住空串（filter 内部才 trim，trim 后为空会回落成「全量前 100 条」）。
        if (hasQ) {
            size_t b = 0, e2 = q.size();
            while (b < e2 && (unsigned char)q[b] <= ' ') ++b;
            while (e2 > b && (unsigned char)q[e2 - 1] <= ' ') --e2;
            q = q.substr(b, e2 - b);
        }
        std::ostringstream j;
        if (hasQ && q.empty()) {
            j << "{\"ok\":true,\"count\":0,\"items\":[],\"q\":\"\",\"emptyQuery\":true}";
        } else if (hasQ) {
            auto items = index.filter(q, 100);
            j << "{\"ok\":true,\"count\":" << items.size() << ",\"items\":[";
            for (size_t i = 0; i < items.size(); ++i) {
                if (i) j << ",";
                j << "[\"" << jesc(items[i].id) << "\",\"" << jesc(items[i].vendor) << "\",\"" << jesc(items[i].name) << "\"]";
            }
            j << "]}";
        } else {
            // 不带 q：索引 bootstrap（全量给前端做本地过滤）
            j << "{\"ok\":true,\"count\":" << index.size() << ",\"items\":[";
            bool first = true;
            for (const auto& it : index.items()) {
                if (!first) j << ",";
                first = false;
                j << "[\"" << jesc(it.id) << "\",\"" << jesc(it.vendor) << "\",\"" << jesc(it.name) << "\"]";
            }
            j << "]}";
        }
        return j.str();
    }
    if (rq.path.rfind("/api/opra/presets", 0) == 0) {
        ct = "application/json; charset=utf-8";
        rta::dsp::OpraService::instance().init(rta::platform::module_dir_utf8() + "/data/opra_index.json", rta::platform::module_dir_utf8());
        std::string productId;
        bool forceRefresh = false;
        const size_t qpos = rq.path.find('?');
        if (qpos != std::string::npos) {
            std::istringstream qs(rq.path.substr(qpos + 1));
            std::string tok;
            while (std::getline(qs, tok, '&')) {
                const size_t eq = tok.find('=');
                if (eq == std::string::npos) continue;
                const std::string k = urlDecode(tok.substr(0, eq));
                const std::string v = urlDecode(tok.substr(eq + 1));
                if (k == "productId" || k == "id") productId = v;
                else if (k == "refresh") forceRefresh = (v == "1" || v == "true");
            }
        }
        if (productId.empty()) {
            return "{\"ok\":false,\"error\":\"缺少 productId 参数\"}";
        }
        std::vector<rta::dsp::OpraPreset> presets;
        bool fromCache = false;
        std::string err;
        bool ok = rta::dsp::OpraService::instance().get_presets(productId, presets, fromCache, err, forceRefresh);
        if (!ok && presets.empty()) {
            std::ostringstream j;
            j << "{\"ok\":false,\"error\":\"" << jesc(err.empty() ? "获取预设失败" : err) << "\"}";
            return j.str();
        }
        std::ostringstream j;
        j << "{\"ok\":true,\"fromCache\":" << (fromCache ? "true" : "false");
        if (!err.empty()) j << ",\"msg\":\"" << jesc(err) << "\"";
        j << ",\"items\":[";
        for (size_t i = 0; i < presets.size(); ++i) {
            const auto& p = presets[i];
            if (i) j << ",";
            j << "{\"id\":\"" << jesc(p.id) << "\""
              << ",\"author\":\"" << jesc(p.author) << "\""
              << ",\"details\":\"" << jesc(p.details) << "\""
              << ",\"link\":\"" << jesc(p.link) << "\""
              << ",\"gainDb\":" << p.gainDb
              << ",\"bandsCount\":" << p.bands.size()
              << "}";
        }
        j << "]}";
        return j.str();
    }
    if (rq.path.rfind("/api/opra/apply", 0) == 0) {
        ct = "application/json; charset=utf-8";
        rta::dsp::OpraService::instance().init(rta::platform::module_dir_utf8() + "/data/opra_index.json", rta::platform::module_dir_utf8());
        std::string productId, presetId;
        std::istringstream is(rq.body);
        std::string tok;
        while (std::getline(is, tok, '&')) {
            const size_t eq = tok.find('=');
            if (eq == std::string::npos) continue;
            const std::string k = urlDecode(tok.substr(0, eq));
            const std::string v = urlDecode(tok.substr(eq + 1));
            if (k == "productId") productId = v;
            else if (k == "presetId") presetId = v;
        }
        if (productId.empty() || presetId.empty()) {
            return "{\"ok\":false,\"error\":\"缺少 productId 或 presetId 参数\"}";
        }
        std::string outRelPath, err;
        bool ok = rta::dsp::OpraService::instance().apply_preset(productId, presetId, path_in_exe_dir(""), outRelPath, err);
        if (!ok) {
            std::ostringstream j;
            j << "{\"ok\":false,\"error\":\"" << jesc(err) << "\"}";
            return j.str();
        }
        std::ostringstream j;
        j << "{\"ok\":true,\"path\":\"" << jesc(outRelPath) << "\""
          << ",\"productId\":\"" << jesc(productId) << "\""
          << ",\"presetId\":\"" << jesc(presetId) << "\""
          // 2026-10-25（耳机 EQ 热重载时序）：这里**故意不写 g_params.eqFile**。
          // 前端 applyOpraPreset 紧接着一定会发 saveSettings(true) → POST /api/settings
          // （body 里带 eq=<这个 path>），热重载统一在那边按 "g_params.eqFile != clean" 触发。
          // 如果这里先把 g_params.eqFile 改成同样的值，那边就会判成"没变化" ⟹ 永不热重载。
          // 也正因如此，只有一处重启点：不会因为 apply + save 而重启两次（那会让用户听两遍卡顿）。
          << ",\"hotReload\":\"pending-settings\""
          << "}";
        return j.str();
    }

    // 局域网监听状态（控制面默认只对本机开放）
    // ---------------- 播放设置持久化 ----------------
    // 没有这个，用户每次重启都要重新选滤波器/抖动/缓冲 —— 日常用起来很烦。
    if (rq.path.rfind("/api/settings", 0) == 0) {
        ct = "application/json; charset=utf-8";
        const std::string sp = path_in_exe_dir("rlplayer-settings.conf");
        if (rq.method == "POST" && !rq.body.empty()) {
            // 2026-10-23（真实事故后加固）：旧实现 std::ios::trunc + 只写本次提交的键 ——
            // 任何「只提交部分键」的客户端都会把其余设置整份清空。
            // 事故复现：测试脚本只 POST eq=… 一个键 → backend/volume 等被抹掉 → 重启后回落
            // wasapi + 0 dB → 直接对用户听音设备出声（违反铁律 1）。
            // 现在改为**合并写**：先读全量 kv，覆盖本次提交的白名单键，再整体写回；文件不可读时按空处理。
            std::map<std::string, std::string> merged;
            std::vector<std::string> order;
            // 2026-10-25（耳机 EQ 热重载）：本次提交里 eq/ir/irgpu 是否真的变了。
            // 只在这里记「变没变」，写盘之后再统一决定要不要热重启（保证只重启一次）。
            bool eqChanged = false, irChanged = false, irgpuChanged = false;
            std::string eqNew, irNew;
            bool irgpuNew = false;
            {
                std::set<std::string> seen_keys;
                std::ifstream in(sp);
                std::string line;
                while (std::getline(in, line)) {
                    if (!line.empty() && line.back() == '\r') line.pop_back();
                    const size_t eqp = line.find('=');
                    if (eqp == std::string::npos) continue;
                    const std::string kk = line.substr(0, eqp);
                    if (seen_keys.insert(kk).second) order.push_back(kk);
                    merged[kk] = line.substr(eqp + 1);
                }
            }
            std::istringstream is(rq.body);
            std::string tok;
            while (std::getline(is, tok, (char)38)) {
                const size_t e = tok.find((char)61);
                if (e == std::string::npos) continue;
                const std::string k = urlDecode(tok.substr(0, e));
                const std::string v = urlDecode(tok.substr(e + 1));
                if (k.empty() || v.size() > 512) continue;
                bool okKey = false;
                for (const char* allow : { "rate", "filter", "filterNx", "shaper", "dsd", "modorder",
                                           "buffer", "volume", "loudness", "isp", "twostage",
                                           "device", "bits", "taps", "atten", "transition", "phase",
                                           "modfamily", "oobgain", "ahmbits", "modcut", "moddith", "ir", "irgpu", "ramp", "theme", "uistyle", "eq",
                                           "gpuvendor", "dsdnative", "directsdm", "dsdkind", "dsdconv", "dsd2stage",
                                           "backend", "naahost", "upnpdev", "channels", "trim",
                                           "inbackend", "indev", "inoffset", "inbuf", "inmon",
                                           "inseconds", "inout",
                                           "sdmfilt", "sdmfiltnx", "streamdecode",
                                           // 大文件流式播放（2026-10-25）：阈值与峰值预扫窗口
                                           "stream_threshold_mb", "isp_prescan_sec",
                                           // 耳机 EQ (OPRA)
                                           "opraproduct", "oprapreset", "opravendor",
                                           // 元数据补全(P1.5):总开关与 LLM 固定两键;
                                           // 源开关 metasrc_<id> 按注册表动态放行(见下);
                                           // P3④b AI 综合开关 metasummary (默认0)
                                           "metaon", "metallm", "metasummary", "llmmonthlycap", "scanthreads", "scanThreads",
                                           // ReplayGain / Album Gain
                                           "rg.mode", "rg_mode", "rgmode", "rg",
                                           "rg.preventClipping", "rg.preventclipping", "rg_preventclipping", "rgpreventclip",
                                           "rg.preamp", "rg_preamp", "rgpreamp", "preamp" })
                    if (k == allow) okKey = true;
                if (!okKey && k.rfind("metasrc_", 0) == 0) {
                    const std::string id = k.substr(8);
                    for (const rta::meta::ProviderDesc& pd : rta::meta::provider_registry())
                        if (id == pd.id) { okKey = true; break; }
                }
                if (!okKey) continue;
                std::string clean;
                for (char ch : v) if (ch != 10 && ch != 13) clean += ch;
                if (k == "scanThreads" || k == "scanthreads") {
                    const int st = atoi(clean.c_str());
                    if (st > 0) Library::instance().setScanThreads((size_t)st);
                }
                if (k == "streamdecode") {
                    rta::audio::set_stream_decode_enabled(clean != "0" && clean != "false");
                }
                // ---- 2026-10-25（耳机 EQ "切了没变化" · 根因 1）：同步内存里的 g_params ----
                // 旧实现只把键值写进 conf，g_params 完全不动 —— 于是"设置页选了 EQ"这件事
                // 对正在播的这一首、对下一次 /api/skip，都是不存在的（g_params 里还是旧值/空值）。
                // 这里只记"变了没变"，真正的热重载放到写完 conf 之后统一做（只重启一次）。
                if (k == "eq") {
                    const PlayParams cur = params_snapshot();
                    if (cur.eqFile != clean) { eqChanged = true; eqNew = clean; }
                } else if (k == "ir") {
                    const PlayParams cur = params_snapshot();
                    if (cur.convIr != clean) { irChanged = true; irNew = clean; }
                } else if (k == "irgpu") {
                    const PlayParams cur = params_snapshot();
                    const bool g = (clean == "1");
                    if (cur.convGpu != g) { irgpuChanged = true; irgpuNew = g; }
                }
                if (merged.find(k) == merged.end()) order.push_back(k);
                merged[k] = clean;
            }
            // 整体写回（合并后的全量键；顺序保持首次出现次序，便于人工排查）
            std::ofstream f(sp, std::ios::trunc);
            if (!f) return "{\"ok\":false,\"error\":\"写入失败\"}";
            for (const auto& kk : order) {
                const auto itv = merged.find(kk);
                if (itv == merged.end()) continue;
                f << kk << "=" << itv->second << (char)10;
            }
            if (!f.good()) return "{\"ok\":false,\"error\":\"写入未完成\"}";
            f.close();

            // ---- 2026-10-25（耳机 EQ "切了没变化" · 根因 1+2）：同步 g_params + 播放中热重载 ----
            // 顺序很重要：先把新值落进 g_params（跳曲/预解码/下次起播立刻用新的），
            // 再判断要不要为"正在播的这一首"重启管线。两件事都只在真的变了时做。
            const bool anyChange = eqChanged || irChanged || irgpuChanged;
            bool hotReloaded = false;
            if (anyChange) {
                PlayParams gp = params_snapshot();
                if (eqChanged)  gp.eqFile = eqNew;
                if (irChanged)  gp.convIr = irNew;
                if (irgpuChanged) gp.convGpu = irgpuNew;
                gp.initialSeekFrac = -1.0;      // 这个是"本次起播"的一次性参数，绝不留在 g_params 里
                params_store(gp);

                // 只在「真的要重建管线」时热重载：
                //   * 路径可读（或为空 = 明确不要 EQ）—— 用户还在手打路径时不要每字符重启；
                //   * 新 EQ/IR 与"本次播放实际用的那一个"确实不同。
                // 后者防止"用户反复保存同一个预设"把播放反复重启。
                PlayParams active = params_snapshot();
                const bool eqOk = eq_path_usable(active.eqFile);
                const bool irOk = eq_path_usable(active.convIr);
                if (eqOk && irOk) {
                    // 播放进度：用 played/total 的比例（两者都是输出帧，口径一致）
                    const size_t plNow = ps.played.load(), ttNow = ps.total.load();
                    const double frac = (ttNow > 0 && plNow < ttNow)
                                        ? (double)plNow / (double)ttNow : 0.0;
                    hotReloaded = eq_hot_reload(active, frac,
                                                eqChanged ? "eq-changed" : "ir-changed");
                }
            }
            {
                std::ostringstream j;
                j << "{\"ok\":true,\"merged\":true";
                if (anyChange) j << ",\"eqChanged\":" << (eqChanged ? "true" : "false")
                                 << ",\"irChanged\":" << (irChanged ? "true" : "false");
                if (hotReloaded) j << ",\"hotReload\":true";
                j << ",\"kv\":{";
                bool firstK = true;
                for (const auto& kk : order) {
                    const auto itv = merged.find(kk);
                    if (itv == merged.end()) continue;
                    if (!firstK) j << ",";
                    firstK = false;
                    j << "\"" << jesc(kk) << "\":\"" << jesc(itv->second) << "\"";
                }
                j << "}}";
                return j.str();
            }
        }
        std::ifstream f(sp);
        std::ostringstream j;
        j << "{\"ok\":true,\"kv\":{";
        std::string line; bool first = true;
        std::set<std::string> seen;                 // 元数据键缺省带出(缺省全开),见下
        std::map<std::string, std::string> kvs;     // 全量 k→v(旧键迁移带值用)
        while (std::getline(f, line)) {
            if (!line.empty() && line.back() == 13) line.pop_back();
            const size_t e = line.find('=');
            if (e == std::string::npos) continue;
            const std::string k = line.substr(0, e);
            seen.insert(k);
            kvs[k] = line.substr(e + 1);
            if (!first) j << ",";
            first = false;
            j << "\"" << jesc(k) << "\":\"" << jesc(line.substr(e + 1)) << "\"";
        }
        // 元数据开关缺省值(P1.5):没写进 conf 也要让 UI 拿到「开」。源开关输出新键
        // metasrc_<id>:新键未写而旧键(metaqq 等)存在 → 迁移带出旧值;都没有 → "1"。
        // 只读迁移 —— 写侧(POST 白名单)只认新键,下次保存后旧键自然消失。
        auto injectKv = [&](const std::string& k, const std::string& v) {
            if (seen.count(k) != 0) return;
            if (!first) j << ",";
            first = false;
            j << "\"" << jesc(k) << "\":\"" << jesc(v) << "\"";
        };
        injectKv("metaon", "1");
        injectKv("metallm", "1");
        injectKv("metasummary", "0");
        injectKv("llmmonthlycap", "0");
        injectKv("streamdecode", "1");
        injectKv("stream_threshold_mb", "200");
        injectKv("isp_prescan_sec", "20");
        injectKv("rg.mode", "off");
        injectKv("rg.preventClipping", "1");
        injectKv("rg.preamp", "0.0");
        for (const rta::meta::ProviderDesc& pd : rta::meta::provider_registry()) {
            const std::string nk = std::string("metasrc_") + pd.id;
            if (seen.count(nk) != 0) continue;
            const auto it = kvs.find("meta" + std::string(pd.id));   // metaqq/metanetease/metaitunes/metalrclib
            injectKv(nk, it == kvs.end() ? std::string("1") : it->second);
        }
        j << "}}";
        return j.str();
    }

    // 输出设备列表（设置页里可以选，不再写死"默认设备"）
    if (rq.path.rfind("/api/devices", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::ostringstream j;
        j << "{\"ok\":true,\"devices\":[";
        bool first = true;
        for (const auto& d : mac_enum_devices()) {
            if (!d.hasOutput) continue;   // 只列输出设备（与 Windows 端点语义一致）
            if (!first) j << ",";
            first = false;
            j << "{\"id\":\"" << jesc(d.id) << "\",\"name\":\"" << jesc(d.name) << "\""
              << ",\"default\":" << (d.isDefault ? "true" : "false")
              << ",\"channels\":" << d.channels
              << ",\"mixRate\":" << d.nominalRate
              << ",\"mixBits\":" << d.mixBits
              << ",\"mixFmt\":\"" << jesc(d.mixFmt) << "\"}";
        }
        j << "]}";
        return j.str();
    }

    // 独占缓冲学习缓存重置（C1，2026-10-24 N300 欠载；方案 §5.3）。
    // 删除 <exe>\rlplayer-buffer-learned.json：之后每次播放都重新按用户设置尝试（必要时再学）。
    // 为什么需要它：学习缓存是为了「不每次都先失败一次」，但用户换了线/固件/驱动后，
    // 旧的 20ms 学习值可能不再必要 —— 不提供重置就只能靠改设置绕。
    if (rq.path.rfind("/api/buffer/reset", 0) == 0) {
        ct = "application/json; charset=utf-8";
        return "{\"ok\":true,\"note\":\"macOS 无 WASAPI 独占缓冲学习缓存（CoreAudio 由设备自管周期）\"}";
    }

    // 滤波器预设表（含每个预设【自带的相位】）：
    // 用户 2026-10-22 功能2 的诉求是「'跟随预设'到底跟的是什么」说不清。
    // 让后端把真相源交出来，前端只负责显示 —— 避免前端再抄一份相位表（那必然漂移）。
    if (rq.path.rfind("/api/filters", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::ostringstream j;
        j << "{\"ok\":true,\"items\":[";
        bool firstF = true;
        for (const auto& fp : rta::dsp::filter_presets()) {
            if (!firstF) j << ",";
            firstF = false;
            const char* ph = (fp.phase == rta::dsp::PhaseKind::Minimum) ? "minimum"
                           : (fp.phase == rta::dsp::PhaseKind::Intermediate) ? "intermediate"
                           : "linear";
            const char* phCn = (fp.phase == rta::dsp::PhaseKind::Minimum) ? "最小相位"
                             : (fp.phase == rta::dsp::PhaseKind::Intermediate) ? "混合相位"
                             : "线性相位";
            j << "{\"name\":\"" << jesc(fp.name) << "\""
              << ",\"phase\":\"" << ph << "\""
              << ",\"phaseName\":\"" << phCn << "\""
              << ",\"taps\":" << fp.taps
              << ",\"twoStage\":" << (fp.twoStage ? "true" : "false")
              << ",\"forNx\":" << (fp.forNx ? "true" : "false") << "}";
        }
        j << "]}";
        return j.str();
    }

    // 设备能力：只让用户选设备真正支持的采样率（选了不支持的一播放就报错，体验很差）
    if (rq.path.rfind("/api/rates", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string devId;
        { const size_t q = rq.path.find("?device="); if (q != std::string::npos) devId = urlDecode(rq.path.substr(q + 8)); }
        // 同一套带重试/缓存的探测：页面刚播完一首就拉列表时，同样会撞上端点重配置的瞬时空表。
        // 探测成功会刷新"上次成功列表"缓存，rate=max 在探测为空时可以据此沿用（RATEPROBE_STALE）。
        const auto rates = probe_exclusive_rates(devId, 24, 2);
        std::string dev = "默认音频设备";
        uint32_t sysRate = 0;
        { std::string di; mac_find_dev(devId, dev, di); }
        for (const auto& d : mac_enum_devices())
            if (d.id == devId || (devId.empty() && d.isDefault)) { sysRate = d.nominalRate; break; }
        std::ostringstream j;
        j << "{\"ok\":true,\"device\":\"" << jesc(dev) << "\",\"sysRate\":" << sysRate
          << ",\"rates\":[";
        for (size_t i = 0; i < rates.size(); ++i) { if (i) j << ","; j << rates[i]; }
        j << "]}";
        return j.str();
    }

    // ---------------- 官方推荐预设（2026-10-25 三档 → 2026-10-26 四档）----------------
    // GET  /api/preset/caps                     → 设备能力（只读探测：不开流、不抢设备）
    // POST /api/preset/apply?profile=…          → 探测 + 决策 + 落盘；返回 applied 与 notes
    //   profile ∈ {bitperfect, pcm, dsd, pcm2dsd}（pcm2dsd 是 2026-10-26 第 4 档）
    // 决策细节全在 engine/preset_profiles.h（纯函数、离线单测），这里只做 IO 与 JSON。
    // ⚠️ mac 事实：本平台的 DSD 通路**只有 DoP**（preset_probe_caps 的 dsdNative 恒 false），
    //    所以 pcm2dsd 档的 notes 只写 DoP 载波率，绝不出现「原生 / 1-bit 直送」。
    if (rq.path.rfind("/api/preset", 0) == 0) {
        ct = "application/json; charset=utf-8";
        if (rq.path.rfind("/api/preset/caps", 0) == 0) return preset_caps_json();
        if (rq.path.rfind("/api/preset/apply", 0) == 0) return preset_apply_json(rq.path);
        rta::net::webui_set_status(400);
        return std::string("{\"ok\":false,\"error\":\"未知的预设端点：只支持 /api/preset/caps 与 "
                           "/api/preset/apply\"}");
    }

    // 拖拽兜底：浏览器拿不到真实路径时，把文件内容传上来，落到 exe 目录下的 uploads
    if (rq.path.rfind("/api/upload", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::string name = "upload.bin";
        const size_t qp = rq.path.find("?name=");
        if (qp != std::string::npos) name = urlDecode(rq.path.substr(qp + 6));
        std::string safe;
        for (char ch : name) {
            const unsigned char c = (unsigned char)ch;
            if (c < 0x20 || ch == '\\' || ch == '/' || ch == ':' || ch == '*' || ch == '?' ||
                ch == '"' || ch == '<' || ch == '>' || ch == '|') safe += '_';
            else safe += ch;
        }
        if (safe.empty()) safe = "upload.bin";
        if (!valid_utf8(safe)) return utf8_path_reject(name);   // F1：下方 fs::u8path(full) 消费
        std::error_code ec;
        const std::string dir = path_in_exe_dir("uploads");
        fs::create_directories(fs::u8path(dir), ec);
        const std::string full = dir + "/" + safe;
        std::ofstream of(fs::u8path(full), std::ios::binary | std::ios::trunc);
        if (!of) return "{\"ok\":false,\"error\":\"无法写入上传目录\"}";
        of.write(rq.body.data(), (std::streamsize)rq.body.size());
        of.close();
        return std::string("{\"ok\":true,\"path\":\"") + jesc(full) + "\",\"size\":" +
               std::to_string((long long)rq.body.size()) + "}";
    }

    // ---------------- ROADMAP P4b：输入采集与直通监听 API ----------------
    // 设备列表：含 loopback 端点标记、默认、混音率/声道/位深
    if (rq.path.rfind("/api/input/devices", 0) == 0 || rq.path.rfind("/api/indevices", 0) == 0) {
        ct = "application/json; charset=utf-8";
        // macOS：CoreAudio 输入设备（§13.13）。includeLoopback=true 时把回环端点一并列出，
        // loopback 字段如实反映设备属性（不再硬编码 false）。
        std::ostringstream j;
        j << R"({"ok":true,"devices":[)";
        bool first = true;
        for (const auto& d : rta::platform::CoreAudioInput::enumerate_capture(true)) {
            if (!first) j << ",";
            first = false;
            j << R"({"id":")" << jesc(d.id) << R"(",)"
              << R"("name":")" << jesc(d.name) << R"(",)"
              << R"("default":)" << (d.isDefault ? "true" : "false")
              << R"(,"loopback":)" << (d.isLoopback ? "true" : "false")
              << R"(,"mixRate":)" << d.mixRate
              << R"(,"mixChannels":)" << d.mixChannels
              << R"(,"mixBits":)" << d.mixBits << "}";
        }
        j << R"(],"note":"macOS 采集走 CoreAudio 输入；loopback=true 的端点表示系统混音回环端点，其可用性取决于 Process Tap 是否已接入采集路径"})";
        return j.str();
    }

    // 实时状态：{running, mode(record|monitor|null), device, rate, channels, seconds, frames, water, overflow, underflow, posClips, negClips, outFile, rmsDb, peakDb, error}
    if (rq.path.rfind("/api/input/state", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::lock_guard<std::mutex> lk(g_inputSession.mtx);
        std::ostringstream j;
        j << R"({"ok":true)";
        j << R"(,"running":)" << (g_inputSession.running.load() ? "true" : "false");
        j << R"(,"mode":")" << jesc(g_inputSession.mode) << R"(")";
        j << R"(,"device":")" << jesc(g_inputSession.device) << R"(")";
        j << R"(,"rate":)" << g_inputSession.rate;
        j << R"(,"channels":)" << g_inputSession.channels;
        j << R"(,"seconds":)" << g_inputSession.seconds;
        j << R"(,"frames":)" << g_inputSession.frames;
        j << R"(,"water":)" << g_inputSession.water;
        j << R"(,"overflow":)" << g_inputSession.overflow;
        j << R"(,"underflow":)" << g_inputSession.underflow;
        j << R"(,"posClips":)" << g_inputSession.posClips;
        j << R"(,"negClips":)" << g_inputSession.negClips;
        j << R"(,"outFile":")" << jesc(g_inputSession.outFile) << R"(")";
        j << R"(,"rmsDb":)" << g_inputSession.rmsDb;
        j << R"(,"peakDb":)" << g_inputSession.peakDb;
        j << R"(,"error":")" << jesc(g_inputSession.error) << R"(")";
        j << "}";
        return j.str();
    }

    // 启动采集：POST /api/input/start（macOS §13.13：CoreAudioInput）
    // 参数语义与 Windows 版一致：mode=record|monitor|null、dev、seconds、out、inject、src=null
    if (rq.path.rfind("/api/input/start", 0) == 0) {
        ct = "application/json; charset=utf-8";
        auto parseParams = [](const rta::net::HttpRequest& req) {
            std::map<std::string, std::string> m;
            auto trim = [](std::string s) {
                while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' ' || s.back() == '\t')) s.pop_back();
                size_t p = 0;
                while (p < s.size() && (s[p] == '\r' || s[p] == '\n' || s[p] == ' ' || s[p] == '\t')) p++;
                return s.substr(p);
            };
            auto parseStr = [&](const std::string& str) {
                std::istringstream is(str);
                std::string tok;
                while (std::getline(is, tok, '&')) {
                    tok = trim(tok);
                    if (tok.empty()) continue;
                    const size_t e = tok.find('=');
                    if (e == std::string::npos) m[trim(urlDecode(tok))] = "1";
                    else m[trim(urlDecode(tok.substr(0, e)))] = trim(urlDecode(tok.substr(e + 1)));
                }
            };
            const size_t q = req.path.find('?');
            if (q != std::string::npos) parseStr(req.path.substr(q + 1));
            if (!req.body.empty()) parseStr(req.body);
            return m;
        };
        auto params = parseParams(rq);   // 非 const：operator[] 按语义需要
        if (g_inputSession.running.load())
            return R"({"ok":false,"error":"设备忙：采集已在运行中"})";
        g_inputSession.reap();

        std::string mode = "record";
        if (params.count("mode")) mode = params["mode"];
        std::string src = params.count("src") ? params["src"] : "";
        if (src == "null" && (!params.count("mode") || params["mode"] == "null")) mode = "null";
        if (mode != "record" && mode != "monitor" && mode != "null")
            return R"({"ok":false,"error":"不支持的采集模式（仅支持 record/monitor/null）"})";
        // 参数名防呆（与 Windows 版同规：形似设备的键名收到但未生效会静默回落，拒绝）
        for (const auto& kv : params) {
            if (kv.first == "device" || kv.first == "deviceId" || kv.first == "devid")
                return R"({"ok":false,"error":"参数名应为 dev（不是 )" + jesc(kv.first) + R"()；已拒绝以免静默回落默认设备"})";
        }
        std::string dev = params.count("dev") ? params["dev"] : "";
        const bool loopback = (params.count("loopback") && (params["loopback"] == "1" || params["loopback"] == "true"));
        if (loopback)
            return R"({"ok":false,"error":"macOS 首版不支持系统混音回环（Process Tap 未接入采集路径）"})";
        double seconds = params.count("seconds") ? std::strtod(params["seconds"].c_str(), nullptr) : 0.0;
        if (seconds < 0.0 || std::isnan(seconds)) seconds = 0.0;
        if (seconds > 86400.0) seconds = 86400.0;
        std::string outFile = params.count("out") ? params["out"] : "";
        if (!outFile.empty() && !valid_utf8(outFile)) return utf8_path_reject(outFile);
        double injectFreq = 1000.0, injectAmp = 0.001;
        if (params.count("inject")) {
            const std::string inj = params["inject"];
            const size_t colon = inj.find(':');
            if (colon != std::string::npos) {
                injectFreq = std::strtod(inj.substr(0, colon).c_str(), nullptr);
                injectAmp = std::strtod(inj.substr(colon + 1).c_str(), nullptr);
            } else injectFreq = std::strtod(inj.c_str(), nullptr);
        }

        if (src != "null" && mode != "null" && !dev.empty()) {
            bool found = false;
            for (const auto& d : rta::platform::CoreAudioInput::enumerate_capture(false)) {
                if (d.id == dev || d.name == dev || d.name.find(dev) != std::string::npos) {
                    found = true;
                    if (dev != d.id && dev != d.name) dev = d.id;   // 子串命中归一成精确 id
                    break;
                }
            }
            if (!found)
                return R"({"ok":false,"error":"打开采集端点失败: 未找到指定的输入设备 [)" + jesc(dev) + R"(]"})";
        }

        rta::platform::MacCaptureConfig cfg;
        cfg.deviceId = dev;
        cfg.srcNull = (src == "null" || mode == "null");
        cfg.injectFreq = injectFreq;
        cfg.injectAmp = injectAmp;
        cfg.paced = true;
        cfg.bufferMs = 200.0;
        if (cfg.srcNull && seconds > 0.0) cfg.targetFrames = (size_t)(seconds * 48000.0);

        auto cap = std::make_shared<rta::platform::CoreAudioInput>();
        if (!cap->open(cfg)) {
            std::string err = cap->last_error();
            if (err.empty()) err = "打开采集端点失败: 无法打开目标采集设备或设备无输入流";
            return R"({"ok":false,"error":")" + jesc(err) + R"("})";
        }
        std::shared_ptr<CoreAudioSink> monitorOut;
        if (mode == "monitor" && !cfg.srcNull) {
            monitorOut = std::make_shared<CoreAudioSink>();
            SinkOpenOpts mo;
            mo.bufferMs = 120;                     // 空 device = 系统默认输出
            if (!monitorOut->open(mo, cap->rate(), cap->channels(), 24)) {
                monitorOut.reset();
                cap->close();
                return R"({"ok":false,"error":"直通监听打开输出设备失败（默认输出不可用）"})";
            }
            if (!monitorOut->start()) {
                monitorOut.reset();
                cap->close();
                return R"({"ok":false,"error":"直通监听启动输出失败"})";
            }
        }
        if (!cap->start()) {
            if (monitorOut) monitorOut->close();
            cap->close();
            return R"({"ok":false,"error":"启动采集流失败: ")" + jesc(cap->last_error()) + R"("})";
        }
        {
            std::lock_guard<std::mutex> lk(g_inputSession.mtx);
            g_inputSession.mode = mode;
            g_inputSession.device = dev.empty() ? "默认输入设备" : dev;
            g_inputSession.rate = cap->rate();
            g_inputSession.channels = cap->channels();
            g_inputSession.seconds = 0.0;
            g_inputSession.frames = 0;
            g_inputSession.water = 0.0;
            g_inputSession.overflow = 0;
            g_inputSession.underflow = 0;
            g_inputSession.posClips = 0;
            g_inputSession.negClips = 0;
            g_inputSession.outFile = (mode == "record") ? outFile : "";
            g_inputSession.rmsDb = -999.0;
            g_inputSession.peakDb = -999.0;
            g_inputSession.error.clear();
            g_inputSession.stopFlag.store(false);
            g_inputSession.running.store(true);
        }
        {
            std::lock_guard<std::mutex> lk(g_inputSession.joinMtx);
            g_inputSession.th = std::thread(input_worker_mac, cap, monitorOut, mode, outFile, seconds);
        }
        return R"({"ok":true})";
    }

    // 停止采集：POST /api/input/stop
    if (rq.path.rfind("/api/input/stop", 0) == 0) {
        ct = "application/json; charset=utf-8";
        g_inputSession.stop();
        return R"({"ok":true})";
    }

    // ---------------- 导出诊断：一个压缩包（2026-10-22 功能3）----------------
    // ★ 顺序很重要：本块必须排在 /api/diag 之前。两个端点都用 rfind(prefix,0)==0
    //   前缀匹配，"diagzip" 也满足 "/api/diag" 的前缀 —— 放在后面就永远进不来
    //   （2026-10-22 实测：下载回来的是 JSON 不是 ZIP，Expand-Archive 报
    //   "找不到中央目录结尾记录"，第一 4 字节是 7B 22 6F 6B = {"ok）。
    // 用户原话：「其实就是个 log，最好直接导出一个压缩包或一个整体的文件，不要用户
    // 单独找 rlplayer-diag.json / rlplayer-playback.log / launcher.log 三份文件」。
    //
    // 打包方式：本进程内存里生成 STORE(不压缩) ZIP（src/net/zipstore.h）。
    //   ✗ 不调 PowerShell Compress-Archive —— 这是分发给用户的程序，用户机器上不保证有。
    //   ✗ 不引第三方库 —— 项目零压缩依赖，且要过分发兼容门禁。
    //   ✓ 自己写几十行：本地头 + 数据 + 中央目录 + EOCD，每文件 CRC32。
    //
    // ★ 红线：包内【绝不能有 api key】。两道保险：
    //   ① 逐条内容都过 redact_secrets()（F-7 2026-10-27 起 = src/net/feedback_redact.h 的
    //      rta::feedback::redact()，9 条规则，可离线单测；README.txt 自己也过一遍，
    //      不给任何条目开例外 —— 见该文件头注释与 tests/test_feedback_redact.cpp）；
    //   ② 只挑【已知文件名】，绝不整目录打包（避免把 rlplayer-llm.conf 之类带 key
    //      的配置文件顺手塞进去）。白名单在下面 kFiles 里写死。
    // 2026-10-26（邮件反馈通道）：把诊断包**保存到约定临时目录**，供页面随后把路径
    // 交给原生壳作为邮件附件。
    //
    // 为什么需要这个端点：浏览器/WebView 里的页面**无法**直接往 $TMPDIR 写文件（沙箱），
    // 而邮件附件必须是一个真实文件路径。所以由服务端代写。
    //
    // 安全（三道）：
    //   ① 目标目录固定为 $TMPDIR/rlplayer-feedback（不接受页面指定目录）；
    //   ② 文件名只允许 [A-Za-z0-9._-]，不接受 '/' 与 '..'；后缀强制 .zip；
    //   ③ 失败一律返回 ok:false + 原因，不返回半成品。
    //
    // ⚠️ 顺序：必须排在 "/api/diag" 之前。后端用 rfind(prefix,0)==0 做前缀匹配，
    //    "/api/diag/save" 也满足 "/api/diag" 的前缀 ⟹ 放后面就永远进不来
    //    （"diagzip" 当年就踩过一模一样的坑，见上面 diagzip 的注释）。
    if (rq.path.rfind("/api/diag/save", 0) == 0) {
        ct = "application/json";
        std::string name = "rlplayer-diag.zip";
        // 允许 ?name=xxx.zip 指定文件名（只取 basename，且过滤危险字符）
        const size_t qpos = rq.path.find('?');
        if (qpos != std::string::npos) {
            const std::string qs = rq.path.substr(qpos + 1);
            const std::string key = "name=";
            const size_t kp = qs.find(key);
            if (kp != std::string::npos) {
                std::string v = qs.substr(kp + key.size());
                const size_t amp = v.find('&');
                if (amp != std::string::npos) v = v.substr(0, amp);
                // 取 basename：截掉最后一个 '/' 之前
                const size_t sl = v.find_last_of('/');
                if (sl != std::string::npos) v = v.substr(sl + 1);
                if (!v.empty()) name = v;
            }
        }
        // 字符白名单 + 强制 .zip 后缀
        std::string clean;
        for (char ch : name) {
            const unsigned char u = (unsigned char)ch;
            if ((u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') ||
                (u >= '0' && u <= '9') || u == '.' || u == '_' || u == '-') {
                clean.push_back(ch);
            }
        }
        if (clean.empty() || clean == "." || clean == "..") clean = "rlplayer-diag.zip";
        if (clean.size() < 4 || clean.compare(clean.size() - 4, 4, ".zip") != 0) clean += ".zip";
        if (rq.body.empty()) return std::string("{\"ok\":false,\"error\":\"请求体为空（需要诊断包 zip 字节）\"}");
        // 校验 ZIP 头 PK\\x03\\x04：别把兜底 JSON 当包存盘（与前端 exportDiagZip 同一判据）
        if (rq.body.size() < 22 || (unsigned char)rq.body[0] != 0x50 ||
            (unsigned char)rq.body[1] != 0x4B || (unsigned char)rq.body[2] != 0x03 ||
            (unsigned char)rq.body[3] != 0x04) {
            return std::string("{\"ok\":false,\"error\":\"不是合法 ZIP（缺少 PK 头）\"}");
        }
        // 目录固定为 <temp>/rlplayer-feedback，与原生壳的 rta::feedback::diagnostic_temp_root()
        // **必须一致**（那是邮件附件校验的 root；不一致会导致附件被壳拒绝）。
        // 这里直接用平台层 temp_dir_utf8() 拼，而不是调 rta::feedback::* ——
        // 那些函数定义在 mac_feedback.mm（ObjC++），rtaweb 不链接它（CLI 不需要发邮件）。
        std::string tdir = rta::platform::temp_dir_utf8();
        if (tdir.empty()) return std::string("{\"ok\":false,\"error\":\"临时目录不可用\"}");
        while (!tdir.empty() && tdir.back() == '/') tdir.pop_back();
        const std::string dir = tdir + "/rlplayer-feedback";
        ::mkdir(dir.c_str(), 0700);   // 已存在则忽略（EEXIST）
        const std::string full = dir + "/" + clean;
        FILE* fp = std::fopen(full.c_str(), "wb");
        if (!fp) return std::string("{\"ok\":false,\"error\":\"无法写入临时目录\"}");
        const size_t wn = std::fwrite(rq.body.data(), 1, rq.body.size(), fp);
        std::fclose(fp);
        if (wn != rq.body.size()) {
            std::remove(full.c_str());
            return std::string("{\"ok\":false,\"error\":\"写入不完整，已删除\"}");
        }
        std::string j = "{\"ok\":true,\"path\":\"";
        j += full;
        j += "\",\"size\":";
        j += std::to_string((long long)wn);
        j += "}";
        return j;
    }
    if (rq.path.rfind("/api/diagzip", 0) == 0) {
        ct = "application/zip";
        // 把 secret 抹掉 —— ★ F-7（2026-10-27）：这里**只剩一次转发调用**，规则本体在
        // src/net/feedback_redact.h（纯函数，可离线单测 tests/test_feedback_redact.cpp）。
        //
        // 为什么把原来的内联 lambda 换掉：那段只认 5 个 `k=v` 前缀 + 散落的 sk-，
        // 实测漏掉 v1.1.1 的这四种明文（红证据见 tests/ 与交付报告）：
        //   ① JSON 形态   {"token": "abcdef123456"}      —— 键后是 `":` 不是 `=`，整条漏
        //   ② 头形态     Authorization: Bearer eyJ...    —— 不认识 header 名，整条漏
        //   ③ 家目录     /Users/august/...               —— 完全不做路径归一
        //   ④ 邮箱       tester@example.com              —— 不做邮箱处理
        //   另加：旧代码对 sk-live-XXX 只抹掉 "live" 一段，中段仍明文（比不抹更危险）。
        // 新实现同时补了 github/AWS/Slack 前缀、Cookie 头、裸 Bearer，并去掉误伤
        // （曲名里的 "token"、COVERBG 的 key=<短缓存键> 都保留）。
        rta::feedback::RedactStats redactStats;   // 逐包累计：写进 README.txt 证明真的跑过
        auto redact_secrets = [&redactStats](std::string s) {
            return rta::feedback::redact(s, &redactStats);
        };
        auto read_all = [](const std::string& path, size_t maxBytes) {
            std::ifstream f(fs::u8path(path), std::ios::binary);
            if (!f) return std::string();
            f.seekg(0, std::ios::end);
            const std::streamoff len = f.tellg();
            if (len <= 0) return std::string();
            const std::streamoff take = (len > (std::streamoff)maxBytes) ? (std::streamoff)maxBytes : len;
            f.seekg(len - take);      // 只取尾部：诊断看的是最近发生了什么
            std::string s((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            return s;
        };

        std::vector<rta::zip::Entry> items;
        // ① diag.json：直接把 /api/diag 同一份内容拿进来（现算，不递归 HTTP）
        //    这里不重跑端点探活（可能耗时 3 秒），只取"设置摘要 + 版本/OS/CPU/GPU"这类
        //    静态信息；探活结果本来就属于"现场状态"，用户要时再点一次 /api/diag 即可。
        {
            std::ostringstream dj;
            dj << "{\"ok\":true"
               << ",\"version\":\"" << RLPLAYER_VERSION << "\""
               << ",\"build\":\"" << jesc(g_buildTime) << "\""
               << ",\"pid\":" << current_pid()
               << ",\"uptime\":" << (long long)std::chrono::duration_cast<std::chrono::seconds>(
                      std::chrono::steady_clock::now() - g_startTp).count()
               << ",\"os\":\"" << jesc(rta::diag::os_version_string()) << "\""
               << ",\"cpu\":\"" << jesc(rta::diag::cpu_brand()) << "\""
               << ",\"tester\":\"" << jesc(rta::diag::read_tester()) << "\""
               << ",\"gpu\":\"" << jesc(std::string(rta::dsp::GpuBridge::instance().available() ? "可用" : "不可用") +
                                        std::string("(") + rta::dsp::GpuBridge::instance().status() + ")") << "\""
               << ",\"port\":" << g_uiPort
               << ",\"lan\":" << (g_lanOn ? "true" : "false")
               // F-7：把"会脱敏什么"写进包本身，收到包的人不用翻源码就知道边界。
               // ⚠️ 这里只报规则名/标记，**不报命中数** —— diag.json 是第一个打包的条目，
               //    此刻后面的日志还没过脱敏，写进来的计数必然是假的。真实计数在 README.txt
               //    （最后生成，那时 redactStats 才是完整的）。
               << ",\"redaction\":{\"applied\":true,\"rules\":[";
            {
                const auto rules = rta::feedback::redaction_rules();
                for (size_t i = 0; i < rules.size(); ++i) {
                    if (i) dj << ",";
                    dj << "\"" << jesc(rules[i]) << "\"";
                }
            }
            dj << "],\"marker\":\"<redacted>\",\"user_marker\":\"<user>\""
               << ",\"excluded_files\":[\"rlplayer-llm.conf\",\"KEY.txt\"]"
               << ",\"note\":\"" << jesc("上面两个文件的内容从不读取、从不打包；本包里所有字符串都过了同一条脱敏函数"
                                          "（src/net/feedback_redact.h，单测 tests/test_feedback_redact.cpp）") << "\""
               << "}"      // 关闭 redaction 对象
               << "}";     // 关闭最外层 diag.json 对象
            rta::zip::Entry e;
            e.name = "rlplayer-diag.json";
            e.data = redact_secrets(utf8_sanitize(dj.str()));
            items.push_back(std::move(e));
        }
        // ② 播放日志：当前 + 轮转的 .1/.2（现场排查常常需要"上上次启动"）
        for (const char* nm : {"rlplayer-playback.log", "rlplayer-playback.log.1",
                               "rlplayer-playback.log.2"}) {
            std::string body = read_all(path_in_exe_dir(nm), 2u * 1024u * 1024u);
            if (body.empty()) continue;
            rta::zip::Entry e;
            e.name = nm;
            e.data = redact_secrets(utf8_sanitize(body));
            items.push_back(std::move(e));
        }
        // ③ 启动器日志
        {
            std::string body = read_all(path_in_exe_dir("launcher.log"), 2u * 1024u * 1024u);
            if (!body.empty()) {
                rta::zip::Entry e;
                e.name = "launcher.log";
                e.data = redact_secrets(utf8_sanitize(body));
                items.push_back(std::move(e));
            }
        }
        // ④ 崩溃转储目录：只带文件名清单（dump 本身几十 MB，塞进诊断包没有意义，
        //    但"有没有 dump、叫什么名字"对排查非常有用）
        {
            std::ostringstream ls;
            std::error_code ec;
            const std::string dir = path_in_exe_dir("dumps");
            int n = 0;
            if (fs::exists(fs::u8path(dir), ec) && fs::is_directory(fs::u8path(dir), ec)) {
                for (auto& de : fs::directory_iterator(fs::u8path(dir),
                                                       fs::directory_options::skip_permission_denied, ec)) {
                    ls << pathToUtf8(de.path().filename()) << "\t"
                       << (long long)fs::file_size(de.path(), ec) << " bytes\n";
                    if (++n > 200) break;
                }
            }
            ls << "\n" << (n == 0 ? "(dumps 目录为空或不存在：本机没有发生崩溃转储)\n"
                                  : ("共 " + std::to_string(n) + " 个文件；完整 dump 未打包（体积过大）\n"));
            rta::zip::Entry e;
            e.name = "dumps-manifest.txt";
            e.data = redact_secrets(ls.str());
            items.push_back(std::move(e));
        }
        // ⑤ 设置摘要（只放白名单键，绝不整份 conf —— 里面可能躺着别的东西）
        {
            std::ostringstream st2;
            st2 << "# RLPlayer 设置摘要（仅白名单键，不含 api key / 路径以外的敏感项）\n";
            std::ifstream f(fs::u8path(path_in_exe_dir("rlplayer-settings.conf")));
            std::string line;
            static const char* kAllow[] = {"rate", "filter", "filterNx", "shaper", "dsd", "modorder",
                                           "modfamily", "buffer", "isp", "twostage", "backend", "bits", "device",
                                           "theme", "uistyle", "taps", "atten", "transition", "phase", "directsdm",
                                           "dsdkind", "dsdconv", "dsd2stage", "channels", "metaon", "metallm"};
            while (std::getline(f, line)) {
                if (!line.empty() && line.back() == '\r') line.pop_back();
                const size_t e2 = line.find('=');
                if (e2 == std::string::npos) continue;
                const std::string k = line.substr(0, e2);
                for (const char* a : kAllow) if (k == a) { st2 << line << "\n"; break; }
            }
            rta::zip::Entry e;
            e.name = "settings-summary.txt";
            e.data = redact_secrets(st2.str());
            items.push_back(std::move(e));
        }
        // ⑥ 说明文件：让用户/我们打开包就知道怎么用、以及包内容边界
        //    ★ F-7：脱敏规则清单从 src/net/feedback_redact.h 直接取，不再手写在这段注释里
        //      —— 否则规则改了文档不跟着改，用户看到的"会脱敏什么"就是骗人的。
        //      同时把**本包真实命中数**写出来（redactStats 到这里已经累计完所有条目），
        //      这是"脱敏真的跑过"的硬证据，而不是一句 applied:true。
        {
            std::ostringstream rd;
            rd << "RLPlayer 诊断包\n"
               << "=================================================\n"
               << "版本: " << RLPLAYER_VERSION << "\n"
               << "生成: " << g_buildTime << "（构建时间）\n"
               << "条目:\n"
               << "  rlplayer-diag.json      版本/OS/CPU/GPU/端口等静态信息\n"
               << "  rlplayer-playback.log   播放格式/峰值/欠载（当前，最多 2MB 尾部）\n"
               << "  rlplayer-playback.log.1 上一次轮转的播放日志（存在才带）\n"
               << "  rlplayer-playback.log.2 上上次轮转（存在才带）\n"
               << "  launcher.log            启动器日志（启动横幅/主题/子进程）\n"
               << "  dumps-manifest.txt      崩溃转储文件清单（dump 本体不打包）\n"
               << "  settings-summary.txt    设置摘要（仅白名单键）\n"
               << "\n安全: 本包里所有文本都过了同一条脱敏函数（规则见下）。\n"
               << "      配置文件本体 rlplayer-llm.conf / KEY.txt 【不在包内】，从不读取、从不打包。\n"
               << "\n脱敏规则（被替换的值写 <redacted>，用户目录名写 <user>；键名与路径结构保留）:\n"
               << rta::feedback::redaction_summary_zh() << "\n"
               << "\n本包实际命中统计（为 0 表示这次日志里确实没有可脱敏内容，不是没跑）:\n"
               << "  prefixed_key=" << redactStats.prefixed_token
               << "  auth_header=" << redactStats.header_value
               << "  bearer=" << redactStats.bearer
               << "  credential_kv=" << redactStats.credential_kv
               << "  user_path=" << redactStats.user_path
               << "  email=" << redactStats.email
               << "  total=" << redactStats.total() << "\n";
            rta::zip::Entry e;
            e.name = "README.txt";
            // ⚠️ README 自己也要过脱敏：规则清单里不会有命中，但万一用户设置里带路径
            //    （后续条目名会把路径拼进来）也不该漏。这条调用同时保证"所有条目无一例外"。
            e.data = redact_secrets(rd.str());
            items.push_back(std::move(e));
        }
        return rta::zip::build(items);
    }

    // ---------------- 诊断（1.0.5 可观测性）----------------
    // 版本/构建/PID/运行时长/OS/CPU/GPU/内测标识 + 端点探活摘要 + 设置六键 + 日志尾 + 最近错误。
    // 端点探活（probe_formats 对 16/24/32 各跑一遍独占支持率）可能耗时：总预算 3 秒，
    // 超时未探的字段如实写"不可用"，绝不卡住 HTTP 线程。
    if (rq.path.rfind("/api/diag", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::ostringstream j;
        // 2026-10-25：forceProbe 是 Windows 侧"强制重探"的开关；macOS 侧 caps() 每次都实查
        // （无缓存层），所以这里不再需要该变量。保留 refresh=1 的路由语义不变。
        const auto upSec = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - g_startTp).count();
        j << "{\"ok\":true"
          << ",\"version\":\"" << RLPLAYER_VERSION << "\""
          << ",\"build\":\"" << jesc(g_buildTime) << "\""
          << ",\"pid\":" << current_pid()
          << ",\"uptime\":" << (long long)upSec
          << ",\"os\":\"" << jesc(rta::diag::os_version_string()) << "\""
          << ",\"cpu\":\"" << jesc(rta::diag::cpu_brand()) << "\""
          << ",\"gpu\":\"" << jesc(std::string(rta::dsp::GpuBridge::instance().available() ? "可用" : "不可用") +
                                   std::string("(") + rta::dsp::GpuBridge::instance().status() + ")") << "\""
          << ",\"tester\":\"" << jesc(rta::diag::read_tester()) << "\"";
        // 端点：每端点给友好名/ID/活状态 + 16/24/32 各自的支持率数。
        // F3：probe 结果走 60s TTL 缓存（probeAge = 本次响应所用探活的最大年龄秒数，
        // 刚探的为 0）；refresh=1 强制全部重探。只有真要探时才受 3 秒共享预算约束。
        // 2026-10-25：probeDeadline（3 秒共享预算）是 Windows 侧多点位探活用的；
        // macOS 侧 caps() 是单次 CoreAudio 查询，不存在多点位预算，故移除。
        long long probeAgeMax = -1;
        j << ",\"endpoints\":[";
        {
            // macOS：设备清单来自 CoreAudio；"探活+三档率表"用 caps() 一次查询（无按位深分档，
            // 三档同表 —— CoreAudio caps 语义，如实呈现而不是编造分档数据）
            std::vector<MacDevInfo> devs;
            for (const auto& d : mac_enum_devices())
                if (d.hasOutput) devs.push_back(d);
            auto joinRates = [](const std::vector<uint32_t>& v) {
                std::string s;
                for (size_t k = 0; k < v.size(); ++k) { if (k) s += "/"; s += std::to_string(v[k]); }
                return s;
            };
            bool firstE = true;
            for (const auto& d : devs) {
                if (!firstE) j << ",";
                firstE = false;
                j << "{\"name\":\"" << jesc(d.name) << "\",\"id\":\"" << jesc(d.id) << "\""
                  << ",\"default\":" << (d.isDefault ? "true" : "false");
                auto out = rta::platform::create_audio_output();
                const rta::platform::DeviceCaps c = out ? out->caps(d.id) : rta::platform::DeviceCaps{};
                j << ",\"alive\":" << (c.rates.empty() ? "false" : "true")
                  << ",\"r16\":" << c.rates.size()
                  << ",\"r24\":" << c.rates.size()
                  << ",\"r32\":" << c.rates.size()
                  << ",\"rates16\":\"" << joinRates(c.rates) << "\""
                  << ",\"rates24\":\"" << joinRates(c.rates) << "\""
                  << ",\"rates32\":\"" << joinRates(c.rates) << "\"}";
            }
        }
        j << "],\"probeAge\":" << probeAgeMax;
        // 设置摘要：只取六个白名单键（不回显 ir/eq 等文件路径内容）
        {
            std::ifstream f(path_in_exe_dir("rlplayer-settings.conf"));
            std::string line, backend = "wasapi", rate, bits, filter, shaper, metaon = "1";
            while (std::getline(f, line)) {
                if (!line.empty() && line.back() == '\r') line.pop_back();
                const size_t e = line.find('=');
                if (e == std::string::npos) continue;
                const std::string k = line.substr(0, e), v = line.substr(e + 1);
                if      (k == "backend") backend = v;
                else if (k == "rate")    rate    = v;
                else if (k == "bits")    bits    = v;
                else if (k == "filter")  filter  = v;
                else if (k == "shaper")  shaper  = v;
                else if (k == "metaon")  metaon  = v;
            }
            j << ",\"settings\":{\"backend\":\"" << jesc(backend)
              << "\",\"rate\":\"" << jesc(rate)
              << "\",\"bits\":\"" << jesc(bits)
              << "\",\"filter\":\"" << jesc(filter)
              << "\",\"shaper\":\"" << jesc(shaper)
              << "\",\"metaon\":\"" << jesc(metaon) << "\"}";
        }
        // 日志尾 ≤8KB。当前日志不写 key 等敏感串；仍加一层 sk-[A-Za-z0-9]+ 掩码作保险
        {
            std::string tail;
            {
                std::ifstream f(path_in_exe_dir("rlplayer-playback.log"), std::ios::binary);
                if (f) {
                    f.seekg(0, std::ios::end);
                    const std::streamoff len = f.tellg();
                    if (len > 0) {
                        f.seekg(len > 8192 ? len - 8192 : (std::streamoff)0);
                        tail.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
                    }
                }
            }
            size_t scan = 0;
            for (;;) {
                const size_t p2 = tail.find("sk-", scan);
                if (p2 == std::string::npos) break;
                const bool boundary = (p2 == 0) || !std::isalnum((unsigned char)tail[p2 - 1]);
                size_t e2 = p2 + 3;
                while (e2 < tail.size() && std::isalnum((unsigned char)tail[e2])) ++e2;
                if (boundary && e2 > p2 + 3) { tail.replace(p2 + 3, e2 - (p2 + 3), "***"); scan = p2 + 6; }
                else scan = p2 + 3;
            }
            tail = utf8_sanitize(tail);   // F6：日志里的非 UTF-8 字节换成 U+FFFD，浏览器不再乱码
            j << ",\"logTail\":\"" << jesc(tail) << "\"";
        }
        {
            std::lock_guard<std::mutex> lk(ps.mtx);
            j << ",\"lastError\":\"" << jesc(ps.error) << "\"";
        }
        j << "}";
        return j.str();
    }

    // 应用标识：启动器用它区分"本程序的实例"和"别的程序占了这个端口"
    if (rq.path.rfind("/api/ping", 0) == 0) {
        ct = "application/json; charset=utf-8";
        return std::string("{\"ok\":true,\"app\":\"RLPlayer\",\"version\":\"") + RLPLAYER_VERSION + "\"}";
    }

    // GPU 后端实际情况：后端 DLL 与 HIP 运行库是否在本目录、当前能不能用
    // （设置页要用它把"AMD"标成可用或未构建，而不是让用户选了才发现没后端）
    if (rq.path.rfind("/api/gpu", 0) == 0) {
        ct = "application/json; charset=utf-8";
        // 2026-10-25（Apple Metal GPU 加速落地）：macOS 唯一的 GPU 后端是 Metal，
        // 产物是 librtagpu.dylib（tools/build_gpu_metal_mac.sh 构建，随包内置）。
        //
        // 两个字段必须分开报，不能合成一个（用户 261024-01 #7 的教训：把"文件在不在"
        // 和"本机真能不能跑"混成一个字段，会让用户看到「后端已就位」却实际走 CPU）：
        //   metal       = 动态库存在且加载成功
        //   metalUsable = 真跑过一次平凡 kernel（rta_gpu_available()==1），真的能跑
        // 注意 GpuBridge::available() 本身就是"加载成功 && rta_gpu_available()==1"，
        // 所以这里两者同值；保留两个字段是为了让前端语义清晰、且将来若要区分
        // "文件在但 kernel 编不出来"时不必改契约。
        // amd/cuda/hip 保留为恒 false：本平台没有对应后端，但字段不能删 ——
        // 老前端仍在读，删字段会让它们拿到 undefined 而误判。
        const bool metal = rta::dsp::GpuBridge::instance().available();
        std::ostringstream j;
        j << "{\"ok\":true"
          << ",\"vendor\":\"" << jesc(rta::dsp::gpu_vendor()) << "\""
          << ",\"metal\":" << (metal ? "true" : "false")
          << ",\"metalUsable\":" << (metal ? "true" : "false")
          << ",\"amd\":false"
          << ",\"cuda\":false"
          << ",\"cudaUsable\":false"
          << ",\"hip\":false"
          << ",\"available\":" << (metal ? "true" : "false")
          << ",\"status\":\"" << jesc(rta::dsp::GpuBridge::instance().status()) << "\"}";
        return j.str();
    }

    if (rq.path.rfind("/api/net", 0) == 0) {
        ct = "application/json; charset=utf-8";
        char hn[256] = {0};
        gethostname(hn, sizeof(hn) - 1);
        std::string ip;
        hostent* he = gethostbyname(hn);
        if (he && he->h_addr_list && he->h_addr_list[0]) {
            in_addr a; std::memcpy(&a, he->h_addr_list[0], 4);
            ip = inet_ntoa(a);
        }
        // 2026-10-25（单进程合并）：多一个 http 字段如实告诉界面「这个端口到底有没有人在听」。
        // 单进程 embedded 形态下是 false —— 界面据此显示「进程内直连（无本地端口）」，
        // 而不是渲染一个连不上的 http://127.0.0.1:8899/ 。port 字段保留（配置/诊断仍要看它）。
        const bool httpOn = g_httpListening.load();
        std::ostringstream j;
        j << "{\"ok\":true,\"port\":" << g_uiPort << ",\"ip\":\"" << jesc(ip) << "\""
          << ",\"lan\":" << (g_lanOn ? "true" : "false")
          << ",\"http\":" << (httpOn ? "true" : "false") << "}";
        return j.str();
    }

    if (rq.path.rfind("/api/signal", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::lock_guard<std::mutex> lk(ps.mtx);
        if (ps.signal.empty()) return "{\"ok\":false}";
        const long long dspCnt = ps.dspChunks.load();
        const long long dspTotUs = ps.dspTotalUs.load();
        const double avgDspBlockMs = dspCnt > 0 ? (double)dspTotUs / (dspCnt * 1000.0) : 0.0;
        const double totalDspMs = (double)dspTotUs / 1000.0;
        std::string s = ps.signal;
        if (!s.empty() && s.back() == '}') {
            s.pop_back();
            std::ostringstream dyn;
            dyn << ",\"dspBlockMs\":" << avgDspBlockMs
                << ",\"dspTotalMs\":" << totalDspMs
                << ",\"dspChunkUs\":" << ps.dspChunkUs.load()
                << ",\"scanMs\":" << Library::instance().lastScanMs()
                // 2026-10-24（用户 261024-04 #8）：路径上的 GPU 事实（**实测**，不是设置项）。
                //   convGpu     = 本次 IR 卷积真的走了 GPU（CPU 回落/无 IR/无 DLL ⟹ false）
                //   gpuResample = 本次升频真的走了 GPU（不重采样 ⟹ false）
                //   gpuUsed     = 二者之一（旧字段 irGpu 仍是"用户勾了卷积走 GPU"的设置值，
                //                 两者并存：irGpu=true & convGpu=false 表示勾了但没跑起来）
                << ",\"convGpu\":" << (ps.gpuConvUsed.load() ? "true" : "false")
                << ",\"gpuResample\":" << (ps.gpu ? "true" : "false")
                << ",\"gpuUsed\":" << ((ps.gpu || ps.gpuConvUsed.load()) ? "true" : "false")
                << "}";
            s += dyn.str();
        }
        return "{\"ok\":true,\"path\":" + s + "}";
    }

    if (rq.path.rfind("/api/rescan", 0) == 0) {
        Library::instance().startScan(true);
        return "{\"ok\":true}";
    }

    if (rq.path.rfind("/api/quit", 0) == 0 || rq.path.rfind("/api/shutdown", 0) == 0) {
        g_exitReq.store(true);
        return "{\"ok\":true}";
    }

    if (rq.path.rfind("/api/dbg", 0) == 0) {
        ct = "text/plain; charset=utf-8";
        std::lock_guard<std::mutex> lk(g_logMx);
        std::string s;
        for (auto& l : g_log) { s += l; s += "\n"; }
        return s;
    }

    if (rq.path.rfind("/api/recent", 0) == 0) {
        ct = "application/json; charset=utf-8";
        std::ifstream f(path_in_exe_dir("rlplayer-recent.txt"));
        std::ostringstream j;
        j << "{\"ok\":true,\"items\":[";
        std::string line;
        bool first = true;
        while (std::getline(f, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty()) continue;
            std::vector<std::string> f4;
            size_t s = 0;
            for (size_t k = 0; k <= line.size(); ++k)
                if (k == line.size() || line[k] == '\t') { f4.push_back(line.substr(s, k - s)); s = k + 1; }
            if (f4.size() < 4) continue;
            if (!first) j << ",";
            first = false;
            j << "{\"path\":\"" << jesc(f4[0]) << "\",\"title\":\"" << jesc(f4[1])
              << "\",\"artist\":\"" << jesc(f4[2]) << "\",\"album\":\"" << jesc(f4[3]) << "\"}";
        }
        j << "]}";
        return j.str();
    }

    if (rq.path.rfind("/api/volume", 0) == 0) {
        ct = "application/json; charset=utf-8";
        const size_t q = rq.path.find("?db=");
        double db = 0.0;
        if (q != std::string::npos) db = atof(urlDecode(rq.path.substr(q + 4)).c_str());
        if (db > 0.0) db = 0.0;
        if (db < -120.0) db = -120.0;
        ps.volDb.store(db);
        {
            std::lock_guard<std::mutex> lk(g_paramsMtx);
            g_params.volume = db;
        }
        if (g_upnpPlayer.load()) {
            if (!rta::net::CastManager::instance().volume_supported()) {
                return "{\"ok\":false,\"upnp\":true,\"error\":\"该渲染器未提供 RenderingControl 服务，无法调整音量（请在渲染器端调节）\"}";
            }
            rta::net::CastManager::instance().set_volume_db(db);
            return "{\"ok\":true,\"db\":" + std::to_string(db) + ",\"upnp\":true}";
        }
        if (!g_activeDop.load()) {
            if (OutSink* s = g_activeSink.load()) {
                s->set_live_gain_db(db - ps.startDb.load());
            }
        }
        return "{\"ok\":true,\"db\":" + std::to_string(db) + "}";
    }

    if (rq.path.rfind("/api/seek", 0) == 0) {
        ct = "application/json; charset=utf-8";
        double frac = 0.0;
        const size_t q = rq.path.find("?pos=");
        if (q != std::string::npos) frac = atof(rq.path.c_str() + q + 5);
        if (frac < 0.0) frac = 0.0;
        if (frac > 1.0) frac = 1.0;
        // 后端 = UPnP（261024-01 #9）：进度条跳转转交投放会话（worker 里发 AVTransport Seek REL_TIME）。
        // 时长未知（渲染器还没报）时不瞎跳，如实返回。
        if (g_upnpPlayer.load()) {
            const auto st = rta::net::CastManager::instance().get_state();
            if (st.running && st.durationSec > 0.0) {
                rta::net::CastManager::instance().seek_seconds(frac * st.durationSec);
                return "{\"ok\":true,\"upnp\":true}";
            }
            return "{\"ok\":true,\"upnp\":true,\"skipped\":true}";
        }
        ps.seekReq.store(frac);
        return "{\"ok\":true}";
    }

    if (rq.path.rfind("/api/pause", 0) == 0) {
        ct = "application/json; charset=utf-8";
        int on = 1;
        const size_t q = rq.path.find("?on=");
        if (q != std::string::npos) on = atoi(rq.path.c_str() + q + 4);
        // 后端 = UPnP：暂停 / 继续转交投放会话（AVTransport Pause / Play）
        if (g_upnpPlayer.load()) {
            rta::net::CastManager::instance().set_paused(on != 0);
            return std::string("{\"ok\":true,\"paused\":") + ((on != 0) ? "true" : "false") + ",\"upnp\":true}";
        }
        ps.pauseReq.store(on != 0);
        return std::string("{\"ok\":true,\"paused\":") + ((on != 0) ? "true" : "false") + "}";
    }

    if (rq.path.rfind("/api/stop", 0) == 0) {
        ct = "application/json; charset=utf-8";
        ps.stopJoin();          // 原子停线程（stop 标志已在其中置位并复位）
        ps.pauseReq.store(false);
        ps.seekReq.store(-1.0);
        ps.paused.store(false);
        ps.playing.store(false);
        {
            std::lock_guard<std::mutex> lk(g_lastEndMx);
            g_lastEnd.isPosZeroNoErr = false;
        }
        // 投放会话若还在跑（含手动「开始投放」的会话），一并停掉 —— 底栏「停止」只能有一个结果。
        if (g_upnpPlayer.exchange(false) || rta::net::CastManager::instance().get_state().running)
            rta::net::CastManager::instance().stop();
        // 停止播放后清零 bit-perfect 结论（停播后结论已无对象，不留上次播放的旧结论）
        {
            std::lock_guard<std::mutex> lk(ps.mtx);
            ps.bpState.clear();
            ps.bpWhy.clear();
        }
        return "{\"ok\":true}";
    }

    if (rq.path.rfind("/api/status", 0) == 0) {
        ct = "application/json; charset=utf-8";
        // 261024-01 #9：后端 = UPnP 时，播放器状态唯一来源 = 投放会话（一条会话、一个数字），
        // 否则底栏与「投放实时状态」会各显示一套进度，互相打架。
        rta::net::CastState castSt;
        bool castMode = false;
        if (g_upnpPlayer.load()) {
            castSt = rta::net::CastManager::instance().get_state();
            if (castSt.running) {
                castMode = true;
            } else {
                // 投放自然结束（渲染器播完 / 出错被停）：播放器回到停止态并清掉投放标志
                g_upnpPlayer.store(false);
                ps.playing.store(false);
                ps.paused.store(false);
            }
        }
        std::lock_guard<std::mutex> lk(ps.mtx);
        std::ostringstream j;
        const size_t pl2 = ps.played.load(), tt = ps.total.load();
        const double pos = castMode ? castSt.positionSec
                                    : (ps.outRate > 0 ? (double)pl2 / ps.outRate : 0.0);
        const double dur = castMode ? castSt.durationSec
                                    : (ps.outRate > 0 ? (double)tt / ps.outRate : 0.0);
        const bool playingStat = castMode ? true : ps.playing.load();
        const bool pausedStat = castMode ? castSt.paused : ps.paused.load();
        const std::string curStat = castMode ? castSt.sourceFile : ps.current;
        const std::string errStat = castMode ? castSt.error : ps.error;
        const uint32_t rateStat = castMode ? castSt.sampleRate : ps.outRate;
        const int bitsStat = castMode ? castSt.bits : ps.outBits;
        // 2026-10-24（用户 261024-04 #8）：GPU 语义拆分。组合语义的唯一事实源 =
        // rta::meta::playback_gpu_flags（src/meta/statusflags.h，带真值表与单测）：
        //   gpu         = GPU 可用性（与本次播放无关，旧字段名保留）
        //   gpuUsed     = 本次播放 GPU 真的参与了计算（升频 或 卷积）
        //   gpuResample / gpuConv = 两条路径各自的实测结果
        // 投放（UPnP）模式下渲染在远端设备上，本地这两个实测标志必须归零 ——
        // 否则会拿"上一首本地播放"的残留值冒充本次远程播放的事实。
        rta::meta::PlaybackGpuInput gpuIn;
        gpuIn.gpuAvailable = rta::dsp::GpuBridge::instance().available();
        gpuIn.resampleGpu  = castMode ? false : ps.gpu;
        gpuIn.convGpu      = castMode ? false : ps.gpuConvUsed.load();
        const rta::meta::PlaybackGpuFlags gpuF = rta::meta::playback_gpu_flags(gpuIn);
        const ProcMemInfo memNow = proc_mem();   // 内存遥测（大文件卡死判据：峰值内存）
        j << "{\"ok\":true"
          << ",\"wsMb\":" << memNow.wsMb
          << ",\"wsPeakMb\":" << memNow.peakMb
          << ",\"playing\":" << (playingStat ? "true" : "false")
          << ",\"current\":\"" << jesc(curStat) << "\""
          << ",\"error\":\"" << jesc(errStat) << "\""
          << ",\"info\":\"" << jesc(ps.info) << "\""
          << ",\"paused\":" << (pausedStat ? "true" : "false")
          << ",\"pos\":" << pos
          << ",\"dur\":" << dur
          << ",\"outRate\":" << rateStat
          << ",\"outBits\":" << bitsStat
          << ",\"gpu\":" << (gpuF.gpu ? "true" : "false")
          << ",\"gpuUsed\":" << (gpuF.gpuUsed ? "true" : "false")
          << ",\"gpuResample\":" << (gpuF.gpuResample ? "true" : "false")
          << ",\"gpuConv\":" << (gpuF.gpuConv ? "true" : "false")
          << ",\"rg\":\"" << jesc(ps.rgMode) << "\""
          << ",\"rgDb\":" << ps.rgAppliedDb
          << ",\"rgClip\":" << (ps.rgClipLimited ? "true" : "false")
          << ",\"rgSource\":\"" << jesc(ps.rgSource) << "\""
          << ",\"rgNote\":\"" << jesc(ps.rgNote) << "\""
          << ",\"volDb\":" << ps.volDb.load()
          << ",\"startDb\":" << ps.startDb.load()
          << ",\"pad\":" << ps.dbgPad.load() << ",\"skips\":" << ps.dbgSkips.load()
          << ",\"w0\":" << g_dbgW0.load() << ",\"wr\":" << g_dbgWr.load()
          << ",\"peak\":" << g_dbgPeak.load() << ",\"clip\":" << g_dbgClip.load()
          << ",\"wf\":" << g_dbgWf.load() << ",\"pulls\":" << g_dbgPulls.load()
          << ",\"per\":" << g_dbgPer.load()
          // C2 遥测（2026-10-24 N300 欠载）：dry=设备缓冲空且我们写不进去的次数（≈可闻「啵」），
          // dryms=累计毫秒，ev/evint=事件次数/间隔中位数，prod=pull_chunk 最长阻塞毫秒。
          // 2026-10-26（用户实测：预设卡「当前设备」不跟随实际播放设备）：
          //   前端需要知道当前输出设备，才能在换设备后刷新 /api/preset/caps。
          //   /api/status 之前没有这个字段 ⟹ 卡片一直显示上次探测的结果。
          //   设备 id 的真相源是配置文件（conf_get("device")，空 = 默认设备），
          //   与 /api/preset/caps 探测用的是同一个来源（见上方 preset_caps 实现）。
          << ",\"device\":\"" << jesc(conf_get("device", "")) << "\""
          << ",\"dry\":" << g_dbgDry.load()
          << ",\"dryms\":" << g_dbgDryMs.load()
          << ",\"ev\":" << g_dbgEv.load()
          << ",\"evint\":" << g_dbgEvInt.load()
          << ",\"prod\":" << g_dbgProd.load()
          << ",\"decodeMs\":" << ps.decodeMs.load()
          << ",\"ffmpegMs\":" << ps.ffmpegMs.load()
          << ",\"wavReadMs\":" << ps.wavReadMs.load()
          << ",\"dspChunkUs\":" << ps.dspChunkUs.load()
          << ",\"dspBlockMs\":" << (ps.dspChunks.load() > 0 ? (double)ps.dspTotalUs.load() / (ps.dspChunks.load() * 1000.0) : 0.0)
          << ",\"dspTotalMs\":" << ((double)ps.dspTotalUs.load() / 1000.0)
          << ",\"scanMs\":" << Library::instance().lastScanMs()
          // 2026-10-23（用户 261023-02 #1）：status 也带上 bit-perfect 结论，
          // 让底栏徽标不用额外请求 /api/signal 就能显示（轮询已经是 400ms 一次）。
          << ",\"bitPerfect\":\"" << jesc(ps.bpState) << "\""
          << ",\"bitPerfectWhy\":\"" << jesc(ps.bpWhy) << "\""
          // ---- 输出格式自证（2026-10-26 F-5，mac 口径）----
          // 为什么底栏只拿到 outRate 会误判：DoP 的 outRate 是**载波率**
          // （DSD128/48k 族 = 6144000/16 = 384000），和"PCM 升频到 384k"数字完全一样。
          // 所以这里必须同时给 dsdRate（1-bit 有效码率）与 carrierRate（PCM 载波率），
          // 三个数一起才自证得清"到底是真 DSD 还是 PCM 降级"。
          //   outMode      coreaudio | shared | null | upnp | ""（未播过）
          //                ★ 绝不出现 wasapi/asio/native：mac 无 ASIO、无 Native DSD 通路
          //   dsd          实际 DSD 档位（64/128/256/512；PCM = 0）
          //   dsdRate      1-bit 有效码率（DSD128 = 6144000；PCM = 0）
          //   carrierRate  DoP 的 PCM 载波率 = dsdRate/16（DSD128 = 384000；PCM = 0）
          //   modFamily    调制器族（PCM / DirectSDM 直通 = 空）
          //   modOrder     **实际生效**阶数（降阶保护后的值，不是用户填的值）
          //   fallbackWhy  非空 = 与用户请求不一致的中文原因（空 = 没降级）
          << ",\"outMode\":\"" << jesc(ps.outMode) << "\""
          << ",\"dsd\":" << ps.outDsdLevel
          << ",\"dsdRate\":" << ps.outDsdRate
          << ",\"carrierRate\":" << ps.outCarrierRate
          << ",\"modFamily\":\"" << jesc(ps.outModFamily) << "\""
          << ",\"modOrder\":" << ps.outModOrder
          << ",\"fallbackWhy\":\"" << jesc(ps.outFallbackWhy) << "\""
          << ",\"upnpVolumeSupported\":" << (castMode ? (castSt.volumeSupported ? "true" : "false") : "false")
          << ",\"upnpVolume\":" << (castMode ? castSt.currentVolume : -1);
        const MetaSettings msStat = meta_settings_load();
        bool hasKeyStat = false;
        {
            const rta::meta::LlmConfig cfg = rta::meta::llm_config_load(llm_conf_path());   // exe 同目录，不随 cwd 漂移
            hasKeyStat = !cfg.apiKey.empty();
        }
        j << ",\"hasLlmKey\":" << (hasKeyStat ? "true" : "false")
          << ",\"summaryEnabled\":" << (msStat.summary ? "true" : "false")
          << "}";
        return j.str();
    }

    // 2026-10-25（task-12）：/api/asio 与 /api/asiodevices 已整段删除（不是返回空列表）。
    // 理由：后端没了还留着"永远返回空驱动清单"的假路由，只会让前端继续以为"本机没装驱动"，
    // 那是会误导用户去装一个 macOS 上根本不需要的东西的假结论。现在它落到这里 = 明确的 not found。
    ct = "application/json; charset=utf-8";
    return "{\"ok\":false,\"error\":\"not found\"}";
}

// ---------------- 页面 ----------------
static std::string page() {
    std::string h = rta::net::rta_ui_page();
    std::string fo, so;
    // 滤波器下拉：文案里标出预设自带相位（用户 2026-10-22 功能2 要把"预设"讲明白）。
    // 设置页的 #sp_phasemsg 也从这份数据取真实值（/api/filters），不靠前端硬编码。
    for (const auto& fp : rta::dsp::filter_presets()) {
        fo += "<option value=\"" + std::string(fp.name) + "\">" + fp.name
            + (fp.twoStage ? "  [两段式]" : "")
            + (fp.phase == rta::dsp::PhaseKind::Minimum ? "  [最小相位]"
             : fp.phase == rta::dsp::PhaseKind::Intermediate ? "  [混合相位]"
             : "  [线性相位]")
            + "</option>";
    }
    for (const char* s : {"auto", "none", "NS1", "NS4", "NS5", "NS9", "LNS15", "RPDF", "TPDF", "Gauss1", "Shaped"}) {
        so += std::string("<option value=\"") + s + "\">" + s + "</option>";
    }
    // 占位符要【全部】替换：FILTER_OPTS 同时被 1x 和 Nx 两个下拉使用，
    // 之前只 replace 第一处，Nx 那个下拉于是留着字面量、一个选项都没有，
    // 也就是"Nx 滤波器"根本选不了（本轮修）。
    auto fill_all = [&h](const std::string& key, const std::string& val) {
        if (val.empty()) return;
        for (size_t p = h.find(key); p != std::string::npos; p = h.find(key, p + val.size()))
            h.replace(p, key.size(), val);
    };
    fill_all("FILTER_OPTS", fo);
    fill_all("SHAPER_OPTS", so);
    return h;
}

// ===========================================================================
// 单进程合并（2026-10-25）：CLI 与进程内 embedded 共用同一份初始化 / 收尾。
//
// 为什么抽出来而不是复制：初始化顺序有强约束（库索引 → 源配置 → 代理 → MetaStore →
// OPRA → PEQ → 设置 → 空库首扫），收尾顺序也有强约束（先停控制面 → 停播放 → 停采集 →
// 收预解码 → 停扫描 → 等后台任务）。任何一处顺序错了都是 SIGABRT 或悬垂线程。
// 两条形态只允许在「有没有 HTTP 监听」和「要不要开浏览器」这两点上不同。
// ===========================================================================

// ---- 后台 detached 任务追踪：g_bgJobs/g_bgCv 的声明已上移到文件前部（g_httpListening 附近）----
// 返回 true = 全部收完；false = 超出预算（调用方必须如实记录，不许假装收干净了）
static bool bg_jobs_wait(std::chrono::milliseconds budget) {
    std::unique_lock<std::mutex> lk(g_bgMx);
    return g_bgCv.wait_for(lk, budget, [] { return g_bgJobs.load() == 0; });
}

// ---- 启动横幅（1.0.5 可观测性）----
// 版本/构建时间/PID/端口/OS/CPU/GPU/端点数/内测标识 —— 现场排查第一眼就有的信息。
static void core_log_startup_banner(unsigned port, bool embedded) {
    std::ostringstream b;
    b << "STARTUP v" << RLPLAYER_VERSION
      << " build=" << g_buildTime
      << " pid=" << current_pid()
      << " port=" << port
      << " os=" << rta::diag::os_version_string()
      << " cpu=" << rta::diag::cpu_brand()
      << " gpu=" << (rta::dsp::GpuBridge::instance().available() ? "available" : "unavailable")
      << "(" << rta::dsp::GpuBridge::instance().status() << ")"
      << " endpoints=" << (
          [] { size_t n = 0; for (const auto& d : mac_enum_devices()) if (d.hasOutput) ++n; return n; }()
      );
    const std::string tester = rta::diag::read_tester();
    if (!tester.empty()) b << " tester=" << tester;
    // embedded 明确标注：这个进程没有本地 HTTP 端口（port=0 会被误读成"随机端口"）
    if (embedded) b << " mode=embedded";
    play_log(b.str());
    printf("%s\n", b.str().c_str());
}

// ---- 共享初始化（不含 HTTP 监听、不含开浏览器）----
static void core_init_common() {
    rta::crash::install();    // 崩溃转储（1.0.5）：dump 落 exe 目录 dumps\，filter 先写日志
    setvbuf(stdout, nullptr, _IONBF, 0);
    // 系统级调优：提高进程优先级 + 把系统定时器精度提到 1ms。
    // 默认 15.6ms 的定时器粒度会让喂数节奏变粗（Round 6 实测过这个问题）。
    // macOS：无 timeBeginPeriod 等价物（AUHAL 回调按设备时钟拉数据，不依赖 host 定时器精度）。
    // 喂数线程走高 QoS；进程级 renice 需要 root，不做（如实记录，不假装等效）。
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);

    // 2026-10-25（默认目录纠正配套）：**必须**在任何 load() 之前搬旧数据。
    // 顺序敏感：queue_load / Library::load / SourceManager::load 都从 path_in_exe_dir()
    // （= 新的 config_dir）读，先搬后读才不会让老用户"设置和曲库全没了"。
    migrate_legacy_state_files();

    queue_load();                             // 恢复上次的播放列表
    Library::instance().load();               // 载入音乐库索引
    (void)Library::instance().albumCount();   // 整理并缓存初始专辑数（让 snapshot 的 albumCountFast 有初值）
    // 2026-10-24（用户 261024-01 #5）：流媒体服务器配置必须开机载入。
    // 旧版从未调用过 SourceManager::load() —— 填过的服务器重启后就"消失"，只能重填。
    SourceManager::instance().load(path_in_exe_dir("rlplayer-sources.conf"));
    // 可选后备代理(P1.5):rlplayer-llm.conf 里 proxy=http://127.0.0.1:7897(可省)。
    // 非空则本进程全部 http_get/http_post 走它(HTTPS 由 WinHTTP 走 CONNECT 隧道);
    // 没有该行 = 直连,现状行为不变(本机 MusicBrainz 已可直连,代理只是后备)。
    {
        const std::string proxy = llm_conf_proxy_line();
        if (!proxy.empty()) {
            rta::net::set_http_proxy(proxy);
            printf("HTTP 代理: %s(来自 rlplayer-llm.conf 的 proxy= 行)\n", proxy.c_str());
        }
    }
    // MetaBase 存放 exe 同目录 rlplayer-meta/(与播放日志/设置同位置约定);
    // 播放触发补全与 /api/enrich、/api/meta、/api/cover、/api/lyrics 都走这个单例
    //
    // 2026-10-23 真机 DEBUG(用户反馈「升级后封面/歌词没了」):
    //   旧版把 metabase 落在**进程工作目录**,新版固定在 exe 目录 → 老用户既有的歌词/内嵌封面缓存
    //   全部"看不见"(数据没丢,只是指到了另一个空目录)。这里做**一次性只读回退**:
    //   exe 目录下没有 metabase、而工作目录下有 → 继续用工作目录那份,老用户无感;
    //   exe 目录下已经有 → 用 exe 目录(新数据写新位置,不会两边分裂)。
    {
        std::string metaBase = path_in_exe_dir("rlplayer-meta");
        std::error_code mec;
        if (!fs::is_directory(fs::u8path(metaBase), mec)) {
            const fs::path legacy = fs::u8path("rlplayer-meta");
            if (fs::is_directory(legacy, mec)) {
                metaBase = pathToUtf8(fs::absolute(legacy, mec));
                play_log("METABASE legacy(工作目录): " + metaBase);
            }
        }
        rta::meta::MetaStore::instance().setBaseDir(metaBase);
        rta::meta::EntityStore::instance().setBaseDir(metaBase);
    }
    rta::dsp::OpraService::instance().init(rta::platform::module_dir_utf8() + "/data/opra_index.json", rta::platform::module_dir_utf8());
    // 20 段参数均衡 PEQ（261024-02 #6）：开机载入用户当前设置；文件不存在 = Flat（20 段 0dB）
    peq_load_current();
    {
        std::ifstream f(path_in_exe_dir("rlplayer-settings.conf"));
        std::string line;
        while (std::getline(f, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            const size_t e = line.find('=');
            if (e == std::string::npos) continue;
            const std::string k = line.substr(0, e);
            const std::string v = line.substr(e + 1);
            if (k == "scanThreads" || k == "scanthreads") {
                const int st = atoi(v.c_str());
                if (st > 0) Library::instance().setScanThreads((size_t)st);
            }
            if (k == "streamdecode") {
                rta::audio::set_stream_decode_enabled(v != "0" && v != "false");
            }
        }
    }
    if (Library::instance().trackCount() == 0) {
        printf("音乐库为空，开始首次扫描（根目录见 rlplayer-library.conf）…\n");
        Library::instance().startScan();
    }
}

// ---- 共享收尾（调用方必须已经停掉「新请求入口」）----
// 顺序不能动：播放线程可能还在 prefetch/写 ps，采集线程可能还在摸 CoreAudio，
// 扫描线程持有 Library 的 th_（joinable 的析构 = terminate → mac .app 实测 SIGABRT）。
static void core_shutdown_common() {
    g_ps.stopJoin();        // 原子停播放线程（协作：置 stop 让 queue_thread 自己退）
    g_inputSession.stop();  // 停采集（同样协作）
    // 预解码槽：只在播放线程停掉之后才安全 join（queue_thread 是唯一会起它的地方）
    if (g_pre.th.joinable()) g_pre.th.join();
    // 库扫描线程必须在 exit() 的静态析构前收掉（th_ joinable 的析构 = terminate；
    // mac .app 实测 SIGABRT，2026-10-25）。Library 析构里还有兜底，这里保证顺序。
    Library::instance().stopScan();
    Library::instance().joinScan();
    // 写回批任务：**不可取消**（writeback_library 没有 cancel 钩子），只能等它跑完。
    // 绝不 detach —— 它全程摸 MetaStore 单例，detach 之后壳进程继续活着 = 悬垂访问。
    {
        std::thread prev;
        {
            std::lock_guard<std::mutex> lk(g_wb.mtx);
            if (g_wb.th.joinable()) prev = std::move(g_wb.th);
        }
        if (prev.joinable()) prev.join();
    }
    // detached 的后台任务（元数据补全 / 资料整理）：有界等待，收不完就如实记日志。
    // 预算设为 1200ms（任务项 B），超时时记录已等待毫秒数与剩余数
    const auto tWait0 = std::chrono::steady_clock::now();
    if (!bg_jobs_wait(std::chrono::milliseconds(1200))) {
        const auto tWaitMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - tWait0).count();
        const int left = g_bgJobs.load();
        play_log("SHUTDOWN 后台任务已在 1.2s 内取消并等待，仍有 " + std::to_string(left) + " 个未收完（已等待 " + std::to_string(tWaitMs) + "ms）");
        printf("!! 退出时仍有 %d 个后台任务未收完（已在 1.2s 内取消并等待 %lldms，已在日志记录）\n", left, (long long)tWaitMs);
    }
}

// ===========================================================================
// rlapp —— 进程内 embedded 接口（给 tools/mac_host.mm 用；契约见 rlapp_core.h）
// ===========================================================================

bool rlapp::start_embedded() {
    static std::once_flag once;
    std::call_once(once, [] {
        // 单进程形态：**不** bind/listen 任何本地端口，**不** fork/open 浏览器。
        // RLPLAYER_PORT 仍固定 "8899" —— Library::confLeaf 据此走「默认实例」分支，
        // 沿用用户既有的 rlplayer-library.conf / rlplayer-index.tsv 文件名，
        // 绝不因为改造而让用户的曲库"变空"（那是 1.3.x 已经踩过一次的事故）。
        ::setenv("RLPLAYER_PORT", "8899", 1);
        // g_uiPort = 0：/api/net 与 /api/diagzip 里的 port 字段不再冒充一个真实端口。
        // 真正的"有没有在监听"由 g_httpListening 单独表达（embedded 恒 false）。
        g_uiPort = 0;
        g_lanOn = false;
        g_httpListening.store(false);
        core_init_common();
        core_log_startup_banner(0, /*embedded=*/true);
        play_log("MODE embedded（进程内直连，无本地 HTTP 监听，无浏览器 fork）");
    });
    return true;
}

std::string rlapp::dispatch(const rta::net::HttpRequest& request, std::string& contentType) {
    // 与旧 WebUi::handle 逐字一致的默认值：handler 自己改 ct（图片/JS/HTML/文本/zip）。
    contentType = "application/json; charset=utf-8";
    // 这里【绝不】加全局请求锁：WKURLSchemeHandler 用多个工作线程并发回调，
    // 加锁就把旧 WebUi「每连接一个工作线程」的并行能力退化回串行（那是本轮明确禁止的）。
    // 线程安全由 handle() 内部原有的 per-endpoint 锁（ps.mtx / g_q.mtx / g_logMx …）保证，
    // 与旧路径完全相同 —— 旧路径本来就是在任意工作线程上跑同一个 handle()。
    //
    // 并发观测（无锁）：进入 +1，更新峰值，离开 -1。全是 relaxed 原子操作，不进临界区，
    // 因此这个探针本身不会成为「隐形的串行化」——否则它就是在测自己。
    struct InFlight {
        InFlight() {
            g_dispatchCount.fetch_add(1, std::memory_order_relaxed);
            const int now = g_inFlight.fetch_add(1, std::memory_order_relaxed) + 1;
            int peak = g_peakConcurrent.load(std::memory_order_relaxed);
            while (now > peak &&
                   !g_peakConcurrent.compare_exchange_weak(peak, now, std::memory_order_relaxed)) {}
        }
        ~InFlight() { g_inFlight.fetch_sub(1, std::memory_order_relaxed); }
    } inFlight;
    try {
        return handle(request, contentType);
    } catch (...) {
        // 旧 WebUi::handle 也是 try/catch 吞掉异常后关连接；这里等价，绝不把异常抛回 ObjC++。
        contentType = "application/json; charset=utf-8";
        play_log("DISPATCH 异常已拦截（请求 " + request.path + "）");
        return "{\"ok\":false,\"error\":\"internal error\"}";
    }
}

int       rlapp::max_concurrent_dispatches() { return g_peakConcurrent.load(); }
long long rlapp::dispatch_count()            { return g_dispatchCount.load(); }
void      rlapp::reset_dispatch_probe() {
    g_peakConcurrent.store(g_inFlight.load());
    g_dispatchCount.store(0);
}

bool rlapp::exit_requested() {
    return g_exitReq.load();
}

void rlapp::stop_embedded() {
    // 幂等：壳可能因为「用户点退出」和「窗口关闭」各调一次。
    static std::atomic<bool> stopped{false};
    if (stopped.exchange(true)) return;
    g_shutdown = true;     // 协作式取消：让后台任务感知到要退出了
    core_shutdown_common();
}

int rlapp::cli_main(int argc, char** argv) {
    uint16_t port = 8899;
    bool lan = false;
    // 2026-10-25（单进程原生化收口）：macOS 已全面采用 WKWebView 单进程应用（RLPlayer.app），
    // 不再使用浏览器端。CLI 入口 rtaweb 仅作无头测试工具，默认绝不自动 open 系统浏览器。
    bool noBrowser = true;
    std::string musicDir;   // --music-dir：直接指定库根（覆盖配置文件）
    // 端口解析（2026-10-25 修）：macOS 壳 tools/mac_host.mm:62 传的是 "--port=%u"（等号形式），
    // 旧代码只认 "--port N"（空格形式）→ 等号形式被静默忽略、永远绑 8899，
    // 于是壳里 8899..8910 的端口回退全是死代码（8899 被占时只能报「无法启动播放服务」）。
    // 现在两种形式都认；非法/越界值一律回落到默认 8899，绝不静默绑到 0（= 随机端口）。
    auto parse_port = [](const std::string& s, uint16_t& out) -> bool {
        if (s.empty()) return false;
        for (char ch : s) if (ch < '0' || ch > '9') return false;   // 只接受纯十进制（不接受 "-1"/"89x"）
        const long v = strtol(s.c_str(), nullptr, 10);
        if (v < 1 || v > 65535) return false;
        out = (uint16_t)v;
        return true;
    };
    for (int i = 1; i < argc; ++i) {
        const std::string k = argv[i];
        if (k == "--port" && i + 1 < argc) {
            uint16_t v = 0;
            if (parse_port(argv[++i], v)) port = v;
            else printf("!! --port 的值 \"%s\" 不是合法端口（1..65535），回落到默认 %u\n",
                        argv[i], (unsigned)port);
        }
        else if (k.rfind("--port=", 0) == 0) {
            uint16_t v = 0;
            if (parse_port(k.substr(7), v)) port = v;
            else printf("!! --port= 的值 \"%s\" 不是合法端口（1..65535），回落到默认 %u\n",
                        k.c_str() + 7, (unsigned)port);
        }
        else if (k == "--lan") lan = true;
        else if (k == "--no-browser") noBrowser = true;   // macOS .app 模式：界面已自动打开
        // 2026-10-26（二次 DEBUG 修，debug/20261026-01）：补 --music-dir / --music-dir=<dir>。
        //   此前只能靠 RLPLAYER_LIBRARY_DIR 或 rlplayer-library.conf.p<port> 指定库根，
        //   命令行传 --music-dir 会被静默忽略（用户以为生效了，实际扫的是别的目录）。
        else if (k == "--music-dir" && i + 1 < argc) musicDir = argv[++i];
        else if (k.rfind("--music-dir=", 0) == 0) musicDir = k.substr(12);
    }
    // 2026-10-23：把端口写进环境，供 Library 选择实例私有的库配置/索引文件名
    //（非 8899 实例用 .p<port> 后缀，避免自检沙箱与用户实例互相覆盖库根）。
    // ★ 2026-10-26 BUG 修复（用户截图：点侧栏「文件夹」显示「目录不存在」）的根因 (a)：
    //   本块原在 --music-dir 处理块**之后**。Library::confLeaf() 靠 RLPLAYER_PORT 决定
    //   文件名后缀，setenv 晚于 --music-dir ⟹ 后缀不生效 ⟹ 不管 --port 是多少，
    //   --music-dir 都会写进**默认实例**的 rlplayer-library.conf（用户真实那份），
    //   把用户的库根改掉。**必须**在任何 Library 写盘动作之前设好，别再把本块往下挪。
    {
        char pb[16]; std::snprintf(pb, sizeof(pb), "%u", (unsigned)port);
        ::setenv("RLPLAYER_PORT", pb, 1);   // Library 实例私有后缀（语义同 Windows）
    }
    // --music-dir：**替换**音乐库扫描根（不是数据目录 —— RLPLAYER_LIBRARY_DIR 是
    // 配置/索引的存放目录，语义不同，别混用）。这样 `rtaweb --music-dir X` 扫的就是 X，
    // 不会再去扫配置文件里遗留的旧根（2026-10-26 二次 DEBUG 实测：之前会叠加）。
    if (!musicDir.empty()) {
        // 2026-10-26 BUG 修复（根因 b/c 的入口侧）：先把用户给的值绝对化，再进库。
        //   Library::addRootEx() 现在**拒绝**相对路径（不变量），而 `--music-dir ./data`
        //   这种写法本身是合理的；这里转成绝对路径 ⟹ 从任何 cwd 启动都能工作，且存进
        //   conf 的是稳定绝对路径（不再随 .app 双击 cwd=/ 而漂移）。
        //   转换失败就保持原值，让 addRootEx 去拒并给出明确原因（不静默兜底）。
        {
            std::error_code ec;
            const fs::path abs = fs::absolute(fs::path(musicDir), ec);
            if (!ec) {
                std::error_code ec2;
                const fs::path norm = abs.lexically_normal();
                const std::string s = pathToUtf8(norm);
                if (!s.empty()) musicDir = s;
            }
        }
        auto& lib = Library::instance();
        for (auto r : lib.roots()) lib.removeRoot(r);
        const auto ar = lib.addRootEx(musicDir);
        if (!ar.ok) printf("!! --music-dir \"%s\" 加不进库：%s\n", musicDir.c_str(), ar.why.c_str());
        else printf("  音乐库根已设为：%s\n", musicDir.c_str());
    }
    g_uiPort = port;
    g_lanOn  = lan;
    // 与 embedded 完全相同的初始化（库/配置/OPRA/代理/MetaStore/PEQ/设置/空库首扫）
    core_init_common();

    rta::net::WebUi ui;
    if (!ui.start(port, handle, !lan)) {
        printf("!! 端口 %u 启动失败（被占用？）\n", (unsigned)port);
        return 1;
    }
    // CLI 形态：真的有本地监听在服务 → /api/net 可以如实说 http:true
    g_httpListening.store(true);
    core_log_startup_banner((unsigned)ui.port(), /*embedded=*/false);
    printf("RLPlayer 网页播放器\n");
    printf("  打开浏览器访问: http://127.0.0.1:%u/\n", (unsigned)ui.port());
    printf("  （只监听本机；播放会以独占模式接管音频设备）\n");
    // macOS .app 双击形态：无控制台可读，直接用默认浏览器打开界面
    //（Windows 的 WebView2 内置窗口由 RLPlayer.exe 启动器承担，mac 首版浏览器界面）
    if (!noBrowser) {
        const std::string url = "http://127.0.0.1:" + std::to_string((unsigned)ui.port()) + "/";
        if (::fork() == 0) { ::execl("/usr/bin/open", "open", url.c_str(), (char*)nullptr); ::_exit(127); }
    }
    // 优雅退出：Dock「退出」/ kill 发 SIGTERM/SIGINT → 置停止标志走正常收尾（铁律 2：不硬杀）
    ::signal(SIGINT, [](int){ g_exitReq.store(true); });
    ::signal(SIGTERM, [](int){ g_exitReq.store(true); });
    printf("  按 Ctrl+C 退出（或 Dock 图标右键 → 退出）\n");
    while (!g_exitReq.load()) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    // 退出顺序（2026-10-25 并发化配套）：
    //   先停 HTTP 控制面 —— handler 现在跑在工作线程里，stop() 会 shutdown 活跃连接并等
    //   连接表清空；然后才拆播放线程 / 库扫描线程。否则在途请求会访问正在析构的单例。
    ui.stop();
    g_httpListening.store(false);
    // ---- 2026-10-25：退出崩溃取证 + 收尾（上游 6bd21a6）----
    {
        std::ostringstream o;
        o << "SHUTDOWN joinable: player=" << (g_ps.th.joinable() ? 1 : 0)
          << " prefetch=" << (g_pre.th.joinable() ? 1 : 0)
          << " scan=" << (g_wb.th.joinable() ? 1 : 0);
        play_log(o.str());
    }
    g_shutdown = true;                     // 让后台活儿看到"要退了"，别再碰全局
    // 控制面已停 → 与 embedded 完全相同的协作收尾（播放/采集/预解码/扫描/写回/后台任务）
    core_shutdown_common();
    if (g_pre.th.joinable()) g_pre.th.detach();
    if (g_wb.th.joinable())  g_wb.th.detach();
    std::fflush(nullptr);
    std::_Exit(0);
}

// ---------------------------------------------------------------------------
// 独立 CLI 入口：rtaweb 可执行文件（add_executable(rtaweb tools/rtaweb.cpp)）用这个。
// 库构建形态（rlapp_core.cpp：#define RLPLAYER_EMBEDDED_LIBRARY）里屏蔽掉，
// 否则会和 rlapp_cli.cpp 的 main() 重复定义 —— 那是链接错误，不是"两个入口"。
// ---------------------------------------------------------------------------
#ifndef RLPLAYER_EMBEDDED_LIBRARY
int main(int argc, char** argv) {
    return rlapp::cli_main(argc, argv);
}
#endif
