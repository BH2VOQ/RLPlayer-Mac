// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// rtaloop_tap.mm — Process Tap 的 ObjC++ 薄包装（给 rtaloop.cpp 的纯 C++ 侧用）
//
// 为什么需要这个文件：macOS 14.2+ 的公开回环机制是
//   CATapDescription(ObjC 类) -> AudioHardwareCreateProcessTap -> tap UUID
//   -> 聚合设备 taps 数组引用【tap UUID】（不是设备 UID！）
// CATapDescription.h / AudioHardwareTapping.h 都被 #ifdef __OBJC__ 门控，
// 纯 C++ 文件 include 不进来，所以拆出这个最小包装。
//
// 语义选择（对结果有直接影响，改动前想清楚）：
//   * initExcludingProcesses:@[] = 排除空列表 = 抓【设备上所有进程】的声音。
//     不能用 init（processes 为空 + include 语义 = 什么都不抓，表现为全零假成功）。
//   * CATapUnmuted：抓录的同时声音照常送硬件（播放行为不变，符合真实链路）。
//   * privateTap：只对本进程可见，不污染系统设备列表。
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

#include <cstdint>

extern "C" bool rl_create_process_tap(const char* deviceUidUtf8, uint32_t* outTapId,
                                      char* outTapUid, size_t outTapUidLen) {
    if (!deviceUidUtf8 || !outTapId || !outTapUid || outTapUidLen == 0) return false;
    @try {
        NSString* uid = [NSString stringWithUTF8String:deviceUidUtf8];
        CATapDescription* desc =
            [[CATapDescription alloc] initExcludingProcesses:@[]
                                                andDeviceUID:uid
                                                   withStream:0];
        desc.privateTap = YES;
        desc.muteBehavior = CATapUnmuted;
        AudioObjectID tapId = kAudioObjectUnknown;
        const OSStatus st = AudioHardwareCreateProcessTap(desc, &tapId);
        [desc release];
        if (st != noErr || tapId == kAudioObjectUnknown) return false;

        // 取 tap 的 UUID —— 聚合设备 taps 数组引用的是它
        CFStringRef tapUid = nullptr;
        UInt32 sz = sizeof(tapUid);
        AudioObjectPropertyAddress a{kAudioTapPropertyUID, kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(tapId, &a, 0, nullptr, &sz, &tapUid) != noErr || !tapUid) {
            AudioHardwareDestroyProcessTap(tapId);
            return false;
        }
        const BOOL ok = CFStringGetCString(tapUid, outTapUid, (CFIndex)outTapUidLen,
                                           kCFStringEncodingUTF8);
        CFRelease(tapUid);
        if (!ok) {
            AudioHardwareDestroyProcessTap(tapId);
            return false;
        }
        *outTapId = tapId;
        return true;
    } @catch (id) {
        return false;
    }
}

extern "C" void rl_destroy_process_tap(uint32_t tapId) {
    if (tapId != 0 && tapId != kAudioObjectUnknown)
        AudioHardwareDestroyProcessTap((AudioObjectID)tapId);
}
