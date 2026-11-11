// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// core_bridge.h — 原生 UI 与 C++ 核心之间的「类型化门面」（1.1.7）
//
// 设计要点（对应 docs/ui-redo/UI_REDESIGN_PLAN.md §3/§5/附录 B）：
//   · 状态真相源仍在 C++ 核心（QueueState / 播放线程）；本层只读快照 + 转发意图，
//     不复制一份模式/队列状态。
//   · 全部走进程内 rlapp::dispatch()，复用现有 /api/* handler，不改任何端点语义，
//     不新增第二套播放逻辑。web UI / CLI / UPnP / ctest 与 native UI 因此共用同一真相。
//   · 纯 C++，不依赖 AppKit，可用 ctest 直接测（tests/test_native_bridge.cpp）。
#pragma once

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace rlnative {

// 播放状态快照。revision 由本层按「真实状态变化」递增（mode/index/current/playing/paused
// 任一变化即 +1），进度 pos 不参与递增 —— UI 可据此丢弃旧快照/避免无意义重绘。
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
    std::string error;
};

// 专辑列表项（/api/lib/albums）。
struct Album {
    std::string key, name, artist;
    int  year = 0;
    int  n = 0;
    int  sr = 0, bits = 0;
    double dur = 0.0;
    bool cover = false;
    bool coverNet = false;      // cvSrc == "net"（可走 /api/lib/cover?k= 取网图）
};

// 曲目（专辑详情 / 搜索 / 队列共用）。
struct Track {
    std::string title, artist, album, path, codec;
    double dur = 0.0;
    int sr = 0, bits = 0, ch = 0;
    int index = 0;              // 专辑内序号（0 起）
    double cueStart = -1.0, cueEnd = -1.0;
};

struct AlbumDetail {
    Album album;
    std::vector<Track> tracks;
};

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

struct LyricLine {
    double t = -1.0;            // <0 = 无时间轴
    std::string text;
};

struct SavedQueue {
    std::string name;
    int n = 0;
};

struct LibraryStats {
    int tracks = 0, albums = 0;
    bool scanning = false;
    int scanned = 0, total = 0;
    int failedDirs = 0;
    bool complete = false;
    std::string roots;          // 以 \n 分隔的根目录（仅用于展示）
};

// ---- 读 ----
PlaybackSnapshot snapshot();                       // /api/status + /api/queue
std::vector<Album> albums(const std::string& q);   // /api/lib/albums[?q=]
AlbumDetail album_detail(const std::string& key);  // /api/lib/album?k=
std::vector<Track> search_tracks(const std::string& q, int limit = 300); // /api/lib/search
std::vector<Track> recent_tracks();                // /api/recent
std::vector<Track> favorite_tracks();              // /api/fav/list?meta=1
QueueState queue(bool withMeta = false);           // /api/queue[?meta=1]
std::vector<SavedQueue> saved_queues();            // /api/sq/list
std::vector<LyricLine> lyrics(const std::string& path); // /api/lyrics?file=
std::string cover_bytes(const std::string& key);   // /api/lib/cover?k=（原始图片字节）
std::map<std::string, std::string> settings();     // /api/settings（kv）
LibraryStats library_stats();                      // /api/lib/stats

// 流媒体源（/api/src/config 的关键字段；只做展示与基本保存，不在 UI 里重写协议）
struct SourceConfig {
    std::string kind, base, user, active;
    bool hasPass = false, configured = false;
};
SourceConfig source_config();
bool source_save(const std::string& kind, const std::string& base,
                 const std::string& user, const std::string& pass);

// ---- 写（意图）----
// set_mode：先读当前 mode 去重（want==cur → 直接返回 false，不写盘、不广播）；
// 非法值钳到 0；写成功后递增 revision。返回 true 表示确实发生了一次状态变更。
bool set_mode(int want);
bool play_path(const std::string& path);           // /api/play（追加并定位）
bool play_album(const std::string& key, int startIndex); // /api/lib/play
bool next_track();                                 // /api/skip?dir=1
bool previous_track();                             // /api/skip?dir=-1
bool toggle_pause();                               // /api/pause?on=
bool stop();                                       // /api/stop
bool seek(double fraction);                        // /api/seek?pos=
bool set_volume_db(double db);                     // /api/volume

bool queue_remove(std::size_t index);              // /api/qdel?i=
bool queue_move(std::size_t from, std::size_t to); // /api/qmove?from=&to=
bool queue_clear();                                // /api/clear
bool queue_sort_default();                         // /api/qsort?by=default
bool queue_play_index(std::size_t index);          // 取队列第 index 首 → /api/play

bool saved_queue_save(const std::string& name);    // /api/sq/save?name=
bool saved_queue_play(const std::string& name, int i = 0); // /api/sq/play?name=&i=
bool saved_queue_delete(const std::string& name);  // /api/sq/delete?name=

bool favorite_set(const std::string& path, bool on);// /api/fav
bool favorite_toggle(const std::string& path);     // 读当前状态后翻转

bool scan_library(bool full = false);              // /api/lib/scan / /api/rescan
bool settings_save(const std::map<std::string, std::string>& kv); // 合并写

// ---- 外观（主题色，用户 2026-11-11：放设置里、默认 light）----
std::string get_theme();
bool set_theme(const std::string& theme);

// ---- 诊断/测试辅助 ----
void reset_bridge_state();

} // namespace rlnative
