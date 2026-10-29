// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// process_tap_bridge.h — Process Tap（macOS 14.2+ 系统混音回环）的纯 C 接口
//
// 为什么需要这个"纯 C 头 + ObjC++ 实现"的两件套：
//   CATapDescription.h / AudioHardwareTapping.h 都被 `#ifdef __OBJC__` 门控，
//   纯 C++ 的 audio_in_coreaudio.h include 不进来（那边一 include 就要求整条
//   编译单元变成 ObjC++，会污染 tools/rtaweb.cpp 这种纯 C++ 主程序）。
//   所以这里只暴露 3 个 extern "C" 函数，ObjC/CoreAudio 的细节全留在
//   process_tap_bridge.mm 里。
//
// ⚠️ 编译选项：实现文件在 **ARC 与非 ARC 下都能编译**（内部用 RL_OBJC_RELEASE 宏
//    统一处理 CATapDescription 的释放，绝不出现裸 [x release]）。
//    推荐与项目其它 .mm 一致加 -fobjc-arc，CMake 侧写法：
//      set_source_files_properties(src/platform/macos/process_tap_bridge.mm
//                                  PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
//    不加也能编、也不泄漏，只是少了编译器的生命周期检查。
//
// ⚠️ 语义（照 tools/rtaloop.cpp 的实测结论，改动前先看那里）：
//    * tap 抓的是【目标输出设备上所有进程】的混音（排除空列表）。
//    * tap 是 private 的，不污染系统设备列表。
//    * muteBehavior = CATapUnmuted：抓录的同时声音照常送硬件。
//    * 与独占输出（Hog Mode）互斥：独占期间设备混音节点不走常规路径，可能抓不到。
//
// 调用约定（失败必须让调用方看得出来，不许"假成功"）：
//    * 三个函数都是线程安全的"每次调用自包含"，但同一个聚合设备的 create/destroy
//      必须由同一个线程串行配对（内部不持锁）。
//    * rl_loopback_create 返回 0 = 成功；非 0 = 失败，此时 errBuf 里有中文原因，
//      *outAggDeviceId / *outTapId 均为 0，且【不会残留】tap 或聚合设备。
#pragma once
#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// 在 deviceUidUtf8 对应的输出设备上建一个 private Process Tap，
// 再组成一个以该设备为 main sub-device、只含这一个 tap 的 private 聚合设备。
// 成功返回 0，*outAggDeviceId = 聚合设备 AudioObjectID（AUHAL 输入侧就开它），
// *outTapId = tap id（销毁时用）。
// 失败返回非 0 的 OSStatus 或 -1，并在 errBuf 写中文原因（长度 errBufLen，保证 NUL 结尾）。
int rl_loopback_create(const char* deviceUidUtf8, uint32_t* outAggDeviceId,
                       uint32_t* outTapId, char* errBuf, size_t errBufLen);

// 销毁聚合设备与 tap。顺序固定：先 destroy aggregate（它还引用着 tap），再 destroy tap。
// 传 0 的 id 会被忽略；重复调用安全。
void rl_loopback_destroy(uint32_t aggDeviceId, uint32_t tapId);

// 本机是否支持 Process Tap：macOS >= 14.2 且 CATapDescription 类与
// AudioHardwareCreate/DestroyProcessTap、AudioHardwareCreate/DestroyAggregateDevice
// 全部可解析。返回 1 = 支持，0 = 不支持（调用方据此决定是否列出回环设备）。
int rl_loopback_supported(void);

#ifdef __cplusplus
}
#endif
