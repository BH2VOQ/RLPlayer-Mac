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

} // namespace rta::platform
