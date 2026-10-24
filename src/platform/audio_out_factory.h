// platform/audio_out_factory.h — 按平台创建 AudioOutput 后端
//
// 为什么不把实现塞进 audio_out.h：那是【纯契约】（Windows/Mac 都必须给同一套答案），
// 一旦在里面 #include CoreAudio 或 windows.h，任何只想用 decide_route 纯函数的测试
// 都会被拖进平台 SDK。契约与实现分开，纯函数才真正可离线测（PLATFORM.md §11.7 的要求）。
//
// 现状（如实记录，铁律 4）：
//   * macOS ：CoreAudioOutput 已实现（AUHAL + Hog Mode）。
//   * Windows：仍走既有 rta::render::OutSink（wasapi_out.h / wasapi_shared.h / asio_out.h），
//     没有 platform::AudioOutput 适配器（PLATFORM.md §11.3 已登记为未做项）。
//     因此 Windows 上 create_audio_output() 返回 nullptr，调用方必须继续用 OutSink。
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
