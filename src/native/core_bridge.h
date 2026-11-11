// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// core_bridge.h — 原生 UI 与 C++ 核心之间的「类型化门面」（P1，1.1.7，新增）
//
// 设计要点（对应 docs/ui-redo/UI_REDESIGN_PLAN.md §3/§5/附录 B）：
//   · 状态真相源仍在 C++ 核心（QueueState / 播放线程）；本层只读快照 + 转发意图，
//     不复制一份模式/队列状态。
//   · 全部走进程内 rlapp::dispatch()，复用现有 /api/* handler，不改任何端点语义，
//     不新增第二套播放逻辑。web UI / CLI / UPnP / ctest 与 native UI 因此共用同一真相。
//   · 纯 C++，不依赖 AppKit，可用 ctest 直接测（tests/test_native_bridge.cpp）。
//
// 本文件是「新增抽象」，1.1.6 中不存在；引用到的既有端点均带 tools/rtaweb.cpp 行号。
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace rlnative {

// 播放状态快照。revision 由本层按「真实状态变化」递增（mode/index/current/playing/paused
// 任一变化即 +1），进度 pos 不参与递增 —— UI 可据此丢弃旧快照/避免无意义重绘。
// 注意：这是**桥层**的 revision，不是核心的；核心没有 revision 概念，故不伪装成核心字段。
struct PlaybackSnapshot {
    std::uint64_t revision = 0;
    int    mode = 0;            // 0=顺序 1=列表循环 2=单曲循环 3=随机
    bool   playing = false;
    bool   paused = false;
    std::string current;
    std::size_t index = 0;
    std::size_t count = 0;
    double pos = 0.0;
    double dur = 0.0;
    double volDb = 0.0;
    std::string error;          // /api/status.error 的自由文本（1.1.7 仍无稳定码，见方案 §6.4）
};

// 专辑列表项（/api/lib/albums 的类型化投影）。
struct Album {
    std::string key, name, artist;
    int  year = 0;
    int  n = 0;
    int  sr = 0, bits = 0;
    double dur = 0.0;
    bool cover = false;
};

// 队列项（/api/queue 的类型化投影）。
struct QueueItem {
    std::string path;
    std::string title, artist, album;
    double dur = 0.0;
};

struct QueueState {
    int mode = 0;
    std::size_t index = 0;
    std::vector<QueueItem> items;
};

// ---- 读 ----
PlaybackSnapshot snapshot();                       // /api/status + /api/queue（后者补 mode/index/count）
std::vector<Album> albums(const std::string& q);   // /api/lib/albums
QueueState queue(bool withMeta = false);           // /api/queue[?meta=1]

// ---- 写（意图）----
// set_mode：先读当前 mode 去重（want==cur → 直接返回 false，不写盘、不广播）；
// 非法值钳到 0；写成功后递增 revision。返回 true 表示确实发生了一次状态变更。
bool set_mode(int want);
bool play_path(const std::string& path);           // /api/play（追加并定位，保留既有语义）
bool play_album(const std::string& key, int startIndex); // /api/lib/play（整列替换）
bool next_track();                                 // /api/skip?dir=1
bool previous_track();                             // /api/skip?dir=-1
bool toggle_pause();                               // /api/pause?on=
bool stop();                                       // /api/stop
bool seek(double fraction);                        // /api/seek?pos=
bool set_volume_db(double db);                     // /api/volume

// ---- 诊断/测试辅助 ----
// 重置本层的 revision/上次状态（仅供隔离测试用；生产不调用）。
void reset_bridge_state();

} // namespace rlnative
