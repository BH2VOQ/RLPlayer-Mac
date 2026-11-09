// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// platform/audio_out_factory.h — 按平台创建 AudioOutput 后端
//
// 为什么不把实现塞进 audio_out.h：那是【纯契约】（Windows/Mac 都必须给同一套答案），
// 一旦在里面 #include CoreAudio 或 windows.h，任何只想用 decide_route 纯函数的测试
// 都会被拖进平台 SDK。契约与实现分开，纯函数才真正可离线测（PLATFORM.md §11.7 的要求）。
//
// 现状（2026-10-25 更新：项目已转 macOS 单平台）：
//   * macOS ：CoreAudioOutput 已实现（AUHAL + Hog Mode + 欠载归因），本平台唯一后端。
//   * Windows：平台层（wasapi_out / wasapi_shared / asio_out）已随平台删除；
//     对应能力在 macOS 上由 CoreAudioOutput 承接（独占=Hog Mode、共享=shared 标志、
//     欠载归因=ZeroAttrib 移植到 audio/write_attrib.h）。详见 PLATFORM.md §13.15。
#pragma once
#include <memory>

#include "platform/audio_out.h"

#if defined(__APPLE__)
#include "platform/macos/audio_out_coreaudio.h"
#endif

namespace rta::platform {

// 返回 nullptr 表示"本平台没有 AudioOutput 适配器，请走既有后端"。
inline std::unique_ptr<AudioOutput> create_audio_output() {
#if defined(__APPLE__)
    return std::make_unique<CoreAudioOutput>();
#else
    return nullptr;
#endif
}

// 本平台是否有 AudioOutput 适配器（编译期即可判定，供宿主选择路径）
inline constexpr bool has_audio_output_adapter() {
#if defined(__APPLE__)
    return true;
#else
    return false;
#endif
}

#if defined(__APPLE__)
// ---------------------------------------------------------------------------
// 只读探测（2026-11-09）。给**开流之前**的判据用：
//   resolve_audio_device       deviceId 字符串 → AudioDeviceID（0 = 找不到/用默认）
//   first_output_stream        首个输出流的 AudioStreamID
//   available_physical_formats 物理层支持的格式列表
//   device_running_somewhere   是否有**任意**客户端在跑（含本进程；开流前读才有意义）
// 为什么必须放在这里而不是直接 include CoreAudio 头：tools/rtaweb.cpp 只想拿结论，
// 不该把 AUHAL 的细节摊到 UI 层；这里做一层薄封装，签名只用 POD 类型。
// ---------------------------------------------------------------------------
namespace macos_probe {
using DeviceId = unsigned int;   // 与 AudioDeviceID 同宽（UInt32）

// deviceId 字符串 → 设备号；空串或非法值返回 0（表示"用默认设备"，由后端 resolve）
inline DeviceId resolve_audio_device(const std::string& deviceId) {
    return static_cast<DeviceId>(CoreAudioOutput::probe_resolve_device(deviceId));
}
inline unsigned int first_output_stream(DeviceId dev) {
    return static_cast<unsigned int>(detail::first_output_stream(static_cast<AudioDeviceID>(dev)));
}
inline std::vector<rta::audio::PhysFormat> available_physical_formats(unsigned int sid) {
    return detail::available_physical_formats(static_cast<AudioStreamID>(sid));
}
inline bool device_running_somewhere(DeviceId dev) {
    return detail::device_running_somewhere(static_cast<AudioDeviceID>(dev));
}
}  // namespace macos_probe
#endif

} // namespace rta::platform
