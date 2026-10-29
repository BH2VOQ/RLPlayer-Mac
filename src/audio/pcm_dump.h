// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// pcm_dump.h — 跨后端 PCM 取证（调试用，默认关闭）
//
// 目的（2026-10-23）：ASIO 与 WASAPI 独占在同一台机器上听感有细微差异。
// 先用最硬的办法把「数据层」和「交付层」分开：把两条路径**送给驱动的那份 PCM**
// 各落一份，等长（固定 44100 帧），跑 SHA256 —— 一致就说明差异来自驱动/时钟，
// 不一致就说明我们的某一层动了数据。
//
// 启用条件：exe 目录下存在文件 `rlplayer-pcmdump.on`（内容忽略）。
// 输出：`pcm-<tag>-<bits>.raw`，交错 int24 小端，每后端一份、只落前 1 秒。
#pragma once
#include <cstdint>
#include <cstdio>
#include <string>


namespace rta::audio::detail {

inline const std::string& pcm_dump_dir() {
    static std::string d = []() -> std::string {
        return {};
    }();
    return d;
}

// tag 区分后端（"asio" / "wasapi-ex"）；bits = 管线有效位深（16/24/32）。
// 内部统一归一到 24 位再落盘，所以两条路径的文件可以直接逐字节比对。
inline void pcm_dump(const char* tag, const int32_t* src, size_t n, int bits) {
    static const size_t kFrames = 44100;    // 固定 1 秒 @44.1k，等长才好比哈希
    static FILE* f = nullptr;
    static std::string cur;
    static size_t frames = 0;
    static bool done = false;
    const std::string& dir = pcm_dump_dir();
    if (dir.empty() || !src || n == 0) return;
    // 换后端（tag 变化）时重置：每个后端各落一份，互不影响
    if (cur != tag) {
        if (f) { std::fclose(f); f = nullptr; }
        cur = tag; frames = 0; done = false;
    }
    if (done) return;
    if (!f) {
        const std::string path = dir + "\\pcm-" + tag + "-" + std::to_string(bits) + ".raw";
        f = std::fopen(path.c_str(), "wb");
        if (!f) return;
    }
    const size_t ch = 2;                    // 仅用于立体声路径（本项目输出恒为 2ch）
    size_t take = n / ch;
    if (frames + take > kFrames) take = (frames < kFrames) ? (kFrames - frames) : 0;
    for (size_t i = 0; i < take * ch; ++i) {
        int32_t v = src[i];
        if (bits > 0 && bits < 24)      v = (int32_t)((int64_t)v << (24 - bits));
        else if (bits > 24)             v = (int32_t)(v >> (bits - 24));
        const uint32_t u = (uint32_t)v;
        const unsigned char b[3] = {(unsigned char)(u & 0xFF), (unsigned char)((u >> 8) & 0xFF),
                                    (unsigned char)((u >> 16) & 0xFF)};
        std::fwrite(b, 1, 3, f);
    }
    frames += take;
    if (frames >= kFrames) { std::fclose(f); f = nullptr; done = true; }
}

} // namespace rta::audio::detail
