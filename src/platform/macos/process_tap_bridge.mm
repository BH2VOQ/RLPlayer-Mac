// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// process_tap_bridge.mm — Process Tap（macOS 14.2+ 系统混音回环）的 ObjC++ 实现
//
// 语义与踩坑全部照 tools/rtaloop.cpp + tools/rtaloop_tap.mm（那套已在真机跑通），
// 这里只是把它抽成可复用的平台层，**不要重新发明**：
//
//   1) CATapDescription 必须用 initExcludingProcesses:@[] andDeviceUID:uid withStream:0
//      —— 排除空列表 = 抓该输出设备上【所有进程】的声音。
//      用 init（processes 为空 + include 语义）会什么都不抓，表现为全零假成功。
//   2) desc.privateTap = YES —— 不污染系统设备列表。
//   3) desc.muteBehavior = CATapUnmuted —— 抓录的同时声音照常送硬件（播放行为不变）。
//   4) 聚合设备字典的 key 是【C 字符串宏】（"name"/"uid"/"taps"/…），
//      必须 CFSTR() 包一层；直接传 char* 会让 CFDictionary 把字符串字节当 CFTypeRef
//      retain，当场 SIGSEGV。
//   5) 聚合设备 taps 数组引用的是【tap 的 UUID】（kAudioTapPropertyUID），不是设备 UID。
//      放设备 UID 进去，聚合设备永远不出现输入流（rtaloop 实测教训）。
//   6) 销毁顺序固定：先 AudioHardwareDestroyAggregateDevice（它还引用着 tap），
//      再 AudioHardwareDestroyProcessTap。反了会留下幽灵 tap。
//
// ⚠️ 编译选项：本文件在 **ARC 与非 ARC 两种模式下都能编译**，行为一致。
//    * 推荐（与本项目其它 .mm 一致）：-fobjc-arc。CMake 侧写法：
//        set_source_files_properties(src/platform/macos/process_tap_bridge.mm
//                                    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
//    * 也允许不加：文件里唯一的 alloc'd ObjC 对象走 RL_OBJC_RELEASE 宏，
//      在 MRR 下是 [(x) release]，在 ARC 下是置 nil。**绝不出现裸 [x release]**，
//      所以两种模式都不会过释放，也不会因忘接线而泄漏。
//    之所以做成双模式：任务书里的手工编译判据不带 -fobjc-arc，而 CMake 侧要带，
//    两边都得能过（少一个开关就编译失败的门禁不叫门禁）。
//
// ⚠️ 弱链接：本工程 minos=13.0，而 tap API 是 14.2 才有。直接调用在 13.x 上会
//    跳空指针崩。所以这里一律用 dlsym 解析函数指针 + @available 双保险，
//    rl_loopback_supported() 就是这两者的合取。

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

#include <dlfcn.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>

#include "platform/macos/process_tap_bridge.h"

#ifndef __has_feature
#  define __has_feature(x) 0
#endif
#if __has_feature(objc_arc)
#  define RL_OBJC_ARC 1
#else
#  define RL_OBJC_ARC 0
#endif

// 唯一的 ObjC 强引用：CATapDescription。ARC 下置 nil 交给编译器释放；
// 非 ARC 下显式 release。**不许在别处写裸 [x release]**——那正是本宏存在的理由。
#if RL_OBJC_ARC
#  define RL_OBJC_RELEASE(x) do { (x) = nil; } while (0)
#else
#  define RL_OBJC_RELEASE(x) do { [(x) release]; (x) = nil; } while (0)
#endif

namespace {

// ---- 错误写入（保证 NUL 结尾；errBuf 可为空）----------------------------------
void set_err(char* buf, size_t len, const char* msg) {
    if (!buf || len == 0) return;
    std::snprintf(buf, len, "%s", msg ? msg : "");
}
void set_errf(char* buf, size_t len, const char* fmt, int code) {
    if (!buf || len == 0) return;
    std::snprintf(buf, len, fmt, code);
}

// ---- 弱链接符号表 ------------------------------------------------------------
using CreateTapFn   = OSStatus (*)(CATapDescription*, AudioObjectID*);
using DestroyTapFn  = OSStatus (*)(AudioObjectID);
using CreateAggFn   = OSStatus (*)(CFDictionaryRef, AudioObjectID*);
using DestroyAggFn  = OSStatus (*)(AudioObjectID);

struct TapApi {
    CreateTapFn  createTap  = nullptr;
    DestroyTapFn destroyTap = nullptr;
    CreateAggFn  createAgg  = nullptr;
    DestroyAggFn destroyAgg = nullptr;
    bool ok() const { return createTap && destroyTap && createAgg && destroyAgg; }
};

template <typename Fn>
Fn resolve(const char* name) {
    return reinterpret_cast<Fn>(::dlsym(RTLD_DEFAULT, name));
}

// 进程内只解析一次（C++11 函数内 static 初始化线程安全）
const TapApi& tap_api() {
    static const TapApi api = [] {
        TapApi a;
        if (@available(macOS 14.2, *)) {
            a.createTap  = resolve<CreateTapFn>("AudioHardwareCreateProcessTap");
            a.destroyTap = resolve<DestroyTapFn>("AudioHardwareDestroyProcessTap");
            a.createAgg  = resolve<CreateAggFn>("AudioHardwareCreateAggregateDevice");
            a.destroyAgg = resolve<DestroyAggFn>("AudioHardwareDestroyAggregateDevice");
        }
        return a;
    }();
    return api;
}

// 类也要能解析（老系统上 CATapDescription 是弱链接类，直接 [CATapDescription alloc] 会 nil）
bool tap_class_available() {
    return NSClassFromString(@"CATapDescription") != nil;
}

// ---- 设备输入流探测（等 tap 流出现在聚合设备上）--------------------------------
size_t input_stream_count(AudioObjectID dev) {
    AudioObjectPropertyAddress addr{kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (::AudioObjectGetPropertyDataSize(dev, &addr, 0, nullptr, &size) != noErr) return 0;
    return size / sizeof(AudioStreamID);
}

// 聚合设备建好后，tap 的输入流不一定立刻出现。rtaloop 实测需要轮询等待，
// 否则紧接着 AUHAL open 会读不到流格式而失败。最多等 3 秒。
bool wait_for_input_stream(AudioObjectID agg, int timeoutMs) {
    for (int waited = 0; waited <= timeoutMs; waited += 50) {
        if (input_stream_count(agg) > 0) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return input_stream_count(agg) > 0;
}

// 从 tap 对象读出 UUID（聚合设备 taps 数组引用的是它，不是设备 UID）
CFStringRef copy_tap_uid(AudioObjectID tapId) {
    CFStringRef uid = nullptr;
    UInt32 size = sizeof(uid);
    AudioObjectPropertyAddress addr{kAudioTapPropertyUID, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (::AudioObjectGetPropertyData(tapId, &addr, 0, nullptr, &size, &uid) != noErr) return nullptr;
    return uid;   // 调用方负责 CFRelease
}

} // namespace

extern "C" int rl_loopback_supported(void) {
    if (!@available(macOS 14.2, *)) return 0;
    if (!tap_class_available()) return 0;
    return tap_api().ok() ? 1 : 0;
}

extern "C" int rl_loopback_create(const char* deviceUidUtf8, uint32_t* outAggDeviceId,
                                  uint32_t* outTapId, char* errBuf, size_t errBufLen) {
    if (errBuf && errBufLen) errBuf[0] = '\0';
    if (outAggDeviceId) *outAggDeviceId = 0;
    if (outTapId) *outTapId = 0;

    if (!outAggDeviceId || !outTapId) {
        set_err(errBuf, errBufLen, "内部错误：输出参数为空");
        return -1;
    }
    if (!deviceUidUtf8 || deviceUidUtf8[0] == '\0') {
        set_err(errBuf, errBufLen, "目标输出设备 UID 为空（回环需要先有一个默认输出设备）");
        return -1;
    }
    if (rl_loopback_supported() != 1) {
        set_err(errBuf, errBufLen,
                "本机不支持 Process Tap（需要 macOS 14.2+，且 CoreAudio 符号可解析）");
        return -1;
    }

    const TapApi& api = tap_api();

    @autoreleasepool {
        @try {
            NSString* uid = [NSString stringWithUTF8String:deviceUidUtf8];
            if (!uid) {
                set_err(errBuf, errBufLen, "目标设备 UID 不是合法 UTF-8");
                return -1;
            }

            // ① 建 private Process Tap（排除空列表 = 抓该设备上所有进程）
            CATapDescription* desc =
                [[CATapDescription alloc] initExcludingProcesses:@[]
                                                    andDeviceUID:uid
                                                      withStream:0];
            if (!desc) {
                set_err(errBuf, errBufLen, "创建 CATapDescription 失败（系统版本可能低于 14.2）");
                return -1;
            }
            desc.privateTap = YES;
            desc.muteBehavior = CATapUnmuted;   // 抓录的同时声音照常送硬件

            AudioObjectID tapId = kAudioObjectUnknown;
            const OSStatus tapSt = api.createTap(desc, &tapId);
            RL_OBJC_RELEASE(desc);              // ARC 置 nil / MRR 显式 release（见宏）
            if (tapSt != noErr || tapId == kAudioObjectUnknown) {
                set_errf(errBuf, errBufLen,
                         "创建 Process Tap 失败（OSStatus=%d）——需要 macOS 14.2+ 且已授予录音权限",
                         (int)tapSt);
                return tapSt != noErr ? (int)tapSt : -1;
            }

            // ② 读 tap UUID（聚合设备引用它，不是设备 UID）
            CFStringRef tapUid = copy_tap_uid(tapId);
            if (!tapUid) {
                set_err(errBuf, errBufLen, "读不到 Process Tap 的 UUID（kAudioTapPropertyUID）");
                api.destroyTap(tapId);
                return -1;
            }

            // ③ 组 private 聚合设备：main sub-device = 目标输出设备，taps = [tap]
            //    ⚠️ kAudioAggregateDevice*Key / kAudioSubTapUIDKey 是 C 字符串宏，必须 CFSTR()
            const CFStringRef devUidStr = (__bridge CFStringRef)uid;
            NSString* aggUidNs = [NSString stringWithFormat:@"rlplayer.loopback.%@",
                                                            [[NSUUID UUID] UUIDString]];
            const CFStringRef aggUidStr = (__bridge CFStringRef)aggUidNs;

            CFMutableDictionaryRef aggDesc = ::CFDictionaryCreateMutable(
                kCFAllocatorDefault, 8, &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
            CFMutableDictionaryRef tapEntry = ::CFDictionaryCreateMutable(
                kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
            if (!aggDesc || !tapEntry) {
                if (aggDesc) ::CFRelease(aggDesc);
                if (tapEntry) ::CFRelease(tapEntry);
                ::CFRelease(tapUid);
                set_err(errBuf, errBufLen, "内部错误：分配聚合设备描述字典失败");
                api.destroyTap(tapId);
                return -1;
            }

            ::CFDictionarySetValue(tapEntry, CFSTR(kAudioSubTapUIDKey), tapUid);
            const void* tapArrItems[1] = {(const void*)tapEntry};
            CFArrayRef tapArr = ::CFArrayCreate(kCFAllocatorDefault, tapArrItems, 1,
                                                &kCFTypeArrayCallBacks);

            ::CFDictionarySetValue(aggDesc, CFSTR(kAudioAggregateDeviceNameKey),
                                   CFSTR("RLPlayer 系统混音回环"));
            ::CFDictionarySetValue(aggDesc, CFSTR(kAudioAggregateDeviceUIDKey), aggUidStr);
            ::CFDictionarySetValue(aggDesc, CFSTR(kAudioAggregateDeviceMainSubDeviceKey),
                                   devUidStr);
            ::CFDictionarySetValue(aggDesc, CFSTR(kAudioAggregateDeviceIsPrivateKey),
                                   kCFBooleanTrue);
            if (tapArr) ::CFDictionarySetValue(aggDesc, CFSTR(kAudioAggregateDeviceTapListKey), tapArr);

            AudioObjectID agg = kAudioObjectUnknown;
            const OSStatus aggSt = tapArr ? api.createAgg(aggDesc, &agg) : -1;

            if (tapArr) ::CFRelease(tapArr);
            ::CFRelease(tapEntry);
            ::CFRelease(aggDesc);
            ::CFRelease(tapUid);

            if (aggSt != noErr || agg == kAudioObjectUnknown) {
                set_errf(errBuf, errBufLen,
                         "创建聚合设备失败（OSStatus=%d）——目标设备可能不支持 tap 或已被独占",
                         (int)aggSt);
                api.destroyTap(tapId);
                return aggSt != noErr ? (int)aggSt : -1;
            }

            // ④ 等 tap 的输入流出现（不出现就说明 tap 没生效，别让上层拿到空设备）
            if (!wait_for_input_stream(agg, 3000)) {
                set_err(errBuf, errBufLen,
                        "聚合设备 3 秒内没有出现输入流（tap 未生效，可能未授予录音权限）");
                api.destroyAgg(agg);
                api.destroyTap(tapId);
                return -1;
            }

            *outAggDeviceId = (uint32_t)agg;
            *outTapId = (uint32_t)tapId;
            return 0;
        } @catch (id) {
            set_err(errBuf, errBufLen, "创建系统混音回环时抛出异常（ObjC/CoreAudio）");
            return -1;
        }
    }
}

extern "C" void rl_loopback_destroy(uint32_t aggDeviceId, uint32_t tapId) {
    if (rl_loopback_supported() != 1) return;   // 老系统上符号可能是空指针，别跳空
    const TapApi& api = tap_api();
    // 顺序固定：聚合设备还引用着 tap，必须先拆聚合
    if (aggDeviceId != 0 && aggDeviceId != (uint32_t)kAudioObjectUnknown)
        api.destroyAgg((AudioObjectID)aggDeviceId);
    if (tapId != 0 && tapId != (uint32_t)kAudioObjectUnknown)
        api.destroyTap((AudioObjectID)tapId);
}
