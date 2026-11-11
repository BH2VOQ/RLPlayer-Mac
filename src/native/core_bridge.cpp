// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// core_bridge.cpp — 原生 UI ↔ C++ 核心的类型化门面实现（P1，1.1.7，新增）
//
// 全部请求通过进程内 rlapp::dispatch() 打给现有 /api/* handler；不改端点语义。
// 这是「新增抽象」，1.1.6 不存在。测试见 tests/test_native_bridge.cpp。
#include "native/core_bridge.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <sstream>

#include "net/json.h"
#include "net/webui.h"
#include "rlapp_core.h"

namespace rlnative {
namespace {

std::mutex g_stateMx;
std::uint64_t g_revision = 0;
PlaybackSnapshot g_last;

// 只把「真实状态变化」计入 revision：进度/音量不参与，避免 10 Hz 轮询把 UI 打爆。
bool state_changed(const PlaybackSnapshot& a, const PlaybackSnapshot& b) {
    return a.mode != b.mode || a.playing != b.playing || a.paused != b.paused ||
           a.current != b.current || a.index != b.index || a.count != b.count ||
           a.error != b.error;
}

std::string dispatch(const std::string& method, const std::string& path,
                     const std::string& body = std::string()) {
    rta::net::HttpRequest rq;
    rq.method = method;
    rq.path = path;
    rq.body = body;
    std::string ct;
    return rlapp::dispatch(rq, ct);
}

// 只做 form/query 编码：非字母数字一律 %XX（与后端 urlDecode 配对）。
std::string url_encode(const std::string& s) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : s) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            out.push_back((char)c);
        } else {
            out.push_back('%');
            out.push_back(hex[c >> 4]);
            out.push_back(hex[c & 0x0F]);
        }
    }
    return out;
}

bool response_ok(const std::string& body) {
    const auto j = rta::net::json_parse(body);
    return j.has("ok") && j["ok"].b;
}

int current_mode() {
    const auto j = rta::net::json_parse(dispatch("GET", "/api/queue"));
    return j.has("mode") ? (int)j["mode"].n() : 0;
}

} // namespace

PlaybackSnapshot snapshot() {
    const auto st = rta::net::json_parse(dispatch("GET", "/api/status"));
    const auto q  = rta::net::json_parse(dispatch("GET", "/api/queue"));

    PlaybackSnapshot s;
    s.mode = q.has("mode") ? (int)q["mode"].n() : 0;
    s.playing = st.has("playing") && st["playing"].b;
    s.paused = st.has("paused") && st["paused"].b;
    s.current = st.has("current") ? st["current"].s() : std::string();
    s.pos = st.has("pos") ? st["pos"].n() : 0.0;
    s.dur = st.has("dur") ? st["dur"].n() : 0.0;
    s.volDb = st.has("volDb") ? st["volDb"].n() : 0.0;
    s.error = st.has("error") ? st["error"].s() : std::string();
    s.index = q.has("index") ? (std::size_t)q["index"].n() : 0;
    s.count = q.has("items") ? q["items"].size() : 0;

    {
        std::lock_guard<std::mutex> lk(g_stateMx);
        if (state_changed(g_last, s)) ++g_revision;
        s.revision = g_revision;
        g_last = s;
        g_last.revision = g_revision;
    }
    return s;
}

std::vector<Album> albums(const std::string& q) {
    std::string path = "/api/lib/albums";
    if (!q.empty()) path += "?q=" + url_encode(q);
    const auto j = rta::net::json_parse(dispatch("GET", path));
    std::vector<Album> out;
    if (!j.has("albums")) return out;
    for (const auto& a : j["albums"].arr) {
        Album al;
        al.key = a["k"].s();
        al.name = a["name"].s();
        al.artist = a["artist"].s();
        al.year = (int)a["year"].n();
        al.n = (int)a["n"].n();
        al.dur = a["dur"].n();
        al.sr = (int)a["sr"].n();
        al.bits = (int)a["bits"].n();
        al.cover = a["cv"].b;
        out.push_back(std::move(al));
    }
    return out;
}

QueueState queue(bool withMeta) {
    QueueState out;
    const auto j = rta::net::json_parse(dispatch("GET", withMeta ? "/api/queue?meta=1" : "/api/queue"));
    out.mode = j.has("mode") ? (int)j["mode"].n() : 0;
    out.index = j.has("index") ? (std::size_t)j["index"].n() : 0;
    const auto& items = j["items"];
    const auto& metas = j["metas"];
    for (std::size_t i = 0; i < items.size(); ++i) {
        QueueItem it;
        it.path = items.arr[i].s();
        if (withMeta && metas.size() > i) {
            it.title = metas.arr[i]["t"].s();
            it.artist = metas.arr[i]["a"].s();
            it.album = metas.arr[i]["al"].s();
            it.dur = metas.arr[i]["d"].n();
        }
        out.items.push_back(std::move(it));
    }
    return out;
}

bool set_mode(int want) {
    if (want < 0 || want > 3) want = 0;        // 非法值回落顺序（方案 A-5）
    if (want == current_mode()) return false;  // 去重：不写盘、不广播（方案 A-4）
    const std::string body = "mode=" + std::to_string(want);
    if (!response_ok(dispatch("POST", "/api/playmode", body))) return false;
    std::lock_guard<std::mutex> lk(g_stateMx);
    ++g_revision;
    g_last.mode = want;
    g_last.revision = g_revision;
    return true;
}

bool play_path(const std::string& path) {
    if (path.empty()) return false;
    return response_ok(dispatch("POST", "/api/play", "file=" + url_encode(path)));
}

bool play_album(const std::string& key, int startIndex) {
    if (key.empty()) return false;
    std::string body = "k=" + url_encode(key) + "&i=" + std::to_string(startIndex);
    return response_ok(dispatch("POST", "/api/lib/play", body));
}

bool next_track()     { return response_ok(dispatch("POST", "/api/skip?dir=1")); }
bool previous_track() { return response_ok(dispatch("POST", "/api/skip?dir=-1")); }
bool stop()           { return response_ok(dispatch("POST", "/api/stop")); }
bool seek(double fraction) {
    fraction = std::max(0.0, std::min(1.0, fraction));
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.6f", fraction);
    return response_ok(dispatch("POST", std::string("/api/seek?pos=") + buf));
}
bool set_volume_db(double db) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.2f", db);
    return response_ok(dispatch("POST", std::string("/api/volume?db=") + buf));
}

bool toggle_pause() {
    const auto st = rta::net::json_parse(dispatch("GET", "/api/status"));
    const bool paused = st.has("paused") && st["paused"].b;
    return response_ok(dispatch("POST", paused ? "/api/pause?on=0" : "/api/pause?on=1"));
}

void reset_bridge_state() {
    std::lock_guard<std::mutex> lk(g_stateMx);
    g_revision = 0;
    g_last = PlaybackSnapshot{};
}

} // namespace rlnative
