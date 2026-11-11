// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// core_bridge.cpp — 原生 UI ↔ C++ 核心的类型化门面实现（1.1.7）
//
// 全部请求通过进程内 rlapp::dispatch() 打给现有 /api/* handler；不改端点语义。
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

std::string dispatch_ct(const std::string& method, const std::string& path,
                        std::string* contentType, const std::string& body = std::string()) {
    rta::net::HttpRequest rq;
    rq.method = method;
    rq.path = path;
    rq.body = body;
    std::string ct;
    std::string out = rlapp::dispatch(rq, ct);
    if (contentType) *contentType = ct;
    return out;
}

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

Album album_from_json(const rta::net::Json& a) {
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
    al.coverNet = a["cvSrc"].s() == "net";
    return al;
}

Track track_from_json(const rta::net::Json& t, int index) {
    Track tr;
    tr.title = t["title"].s();
    tr.artist = t["artist"].s();
    tr.album = t["album"].s();
    tr.path = t["path"].s();
    tr.dur = t["dur"].n();
    tr.sr = (int)t["sr"].n();
    tr.bits = (int)t["bits"].n();
    tr.ch = (int)t["ch"].n();
    tr.codec = t["codec"].s();
    tr.index = index >= 0 ? index : (int)t["i"].n();
    tr.cueStart = t.has("cs") ? t["cs"].n() : -1.0;
    tr.cueEnd = t.has("ce") ? t["ce"].n() : -1.0;
    return tr;
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
    for (const auto& a : j["albums"].arr) out.push_back(album_from_json(a));
    return out;
}

AlbumDetail album_detail(const std::string& key) {
    AlbumDetail d;
    if (key.empty()) return d;
    const auto j = rta::net::json_parse(dispatch("GET", "/api/lib/album?k=" + url_encode(key)));
    if (!j.has("ok") || !j["ok"].b) return d;
    d.album = album_from_json(j);
    for (std::size_t i = 0; i < j["tracks"].size(); ++i) {
        d.tracks.push_back(track_from_json(j["tracks"].at(i), (int)i));
    }
    return d;
}

std::vector<Track> search_tracks(const std::string& q, int limit) {
    if (limit < 1) limit = 300;
    if (limit > 5000) limit = 5000;
    const auto j = rta::net::json_parse(
        dispatch("GET", "/api/lib/search?q=" + url_encode(q) + "&limit=" + std::to_string(limit)));
    std::vector<Track> out;
    for (std::size_t i = 0; i < j["tracks"].size(); ++i) {
        out.push_back(track_from_json(j["tracks"].at(i), (int)i));
    }
    return out;
}

std::vector<Track> recent_tracks() {
    const auto j = rta::net::json_parse(dispatch("GET", "/api/recent"));
    std::vector<Track> out;
    for (std::size_t i = 0; i < j["items"].size(); ++i) {
        const auto& it = j["items"].at(i);
        Track t;
        t.title = it["title"].s();
        t.artist = it["artist"].s();
        t.album = it["album"].s();
        t.path = it["path"].s();
        out.push_back(std::move(t));
    }
    return out;
}

std::vector<Track> favorite_tracks() {
    const auto j = rta::net::json_parse(dispatch("GET", "/api/fav/list?meta=1"));
    std::vector<Track> out;
    for (std::size_t i = 0; i < j["files"].size(); ++i) {
        const auto& f = j["files"].arr[i];
        if (f.type == rta::net::Json::Str) {   // 无 meta 时是纯字符串
            Track t; t.path = f.s(); out.push_back(std::move(t));
            continue;
        }
        Track t;
        t.path = f["file"].s();
        t.title = f["title"].s();
        t.artist = f["artist"].s();
        t.album = f["album"].s();
        t.dur = f["dur"].n();
        out.push_back(std::move(t));
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

std::vector<SavedQueue> saved_queues() {
    const auto j = rta::net::json_parse(dispatch("GET", "/api/sq/list"));
    std::vector<SavedQueue> out;
    for (const auto& q : j["queues"].arr) out.push_back(SavedQueue{q["name"].s(), (int)q["n"].n()});
    return out;
}

std::vector<LyricLine> lyrics(const std::string& path) {
    std::vector<LyricLine> out;
    if (path.empty()) return out;
    const auto j = rta::net::json_parse(
        dispatch("GET", "/api/lyrics?file=" + url_encode(path)));
    if (!j.has("ok") || !j["ok"].b) return out;
    std::string lrc = j["lrc"].s();
    // 解析 [mm:ss.xx] 时间轴；同一行可挂多个时间标签。
    std::istringstream is(lrc);
    std::string line;
    while (std::getline(is, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        std::vector<double> stamps;
        std::size_t pos = 0;
        while (pos < line.size() && line[pos] == '[') {
            const std::size_t close = line.find(']', pos);
            if (close == std::string::npos) break;
            const std::string tag = line.substr(pos + 1, close - pos - 1);
            const std::size_t colon = tag.find(':');
            if (colon == std::string::npos) break;
            const double mm = atof(tag.substr(0, colon).c_str());
            const double ss = atof(tag.substr(colon + 1).c_str());
            stamps.push_back(mm * 60.0 + ss);
            pos = close + 1;
        }
        if (stamps.empty()) {
            if (!line.empty()) out.push_back(LyricLine{-1.0, line});
            continue;
        }
        const std::string text = line.substr(pos);
        for (double t : stamps) out.push_back(LyricLine{t, text});
    }
    return out;
}

std::string cover_bytes(const std::string& key) {
    if (key.empty()) return std::string();
    std::string ct;
    std::string body = dispatch_ct("GET", "/api/lib/cover?k=" + url_encode(key), &ct);
    if (body.size() > 8 && ct.rfind("image/", 0) == 0) return body;
    return std::string();
}

std::map<std::string, std::string> settings() {
    std::map<std::string, std::string> out;
    const auto j = rta::net::json_parse(dispatch("GET", "/api/settings"));
    for (const auto& kv : j["kv"].obj) out[kv.first] = kv.second.s();
    return out;
}

LibraryStats library_stats() {
    LibraryStats s;
    const auto j = rta::net::json_parse(dispatch("GET", "/api/lib/stats"));
    s.tracks = (int)j["tracks"].n();
    s.albums = (int)j["albums"].n();
    s.scanning = j["scanning"].b;
    s.scanned = (int)j["scanned"].n();
    s.total = (int)j["total"].n();
    s.failedDirs = (int)j["failedDirs"].n();
    s.complete = j["complete"].b;
    return s;
}

SourceConfig source_config() {
    SourceConfig c;
    const auto j = rta::net::json_parse(dispatch("GET", "/api/src/config"));
    // 兼容两种布局：顶层字段 或 {servers:[...],active:i}
    const auto& srv = j.has("kind") ? j : j["current"];
    c.kind = srv["kind"].s();
    c.base = srv["base"].s();
    c.user = srv["user"].s();
    c.hasPass = srv["hasPass"].b;
    c.active = j["active"].s();
    c.configured = !(c.kind.empty() && c.base.empty());
    if (!c.configured && j.has("servers") && j["servers"].size() > 0) {
        const auto& s0 = j["servers"].at(0);
        c.kind = s0["kind"].s();
        c.base = s0["base"].s();
        c.user = s0["user"].s();
        c.hasPass = s0["hasPass"].b;
        c.configured = !(c.kind.empty() && c.base.empty());
    }
    return c;
}

bool source_save(const std::string& kind, const std::string& base,
                 const std::string& user, const std::string& pass) {
    std::string body = "kind=" + url_encode(kind) + "&base=" + url_encode(base) +
                       "&user=" + url_encode(user);
    if (!pass.empty()) body += "&pass=" + url_encode(pass);
    return response_ok(dispatch("POST", "/api/src/config", body));
}

bool set_mode(int want) {
    if (want < 0 || want > 3) want = 0;
    if (want == current_mode()) return false;
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
    if (db > 0.0) db = 0.0;
    if (db < -120.0) db = -120.0;
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.2f", db);
    return response_ok(dispatch("POST", std::string("/api/volume?db=") + buf));
}

bool toggle_pause() {
    const auto st = rta::net::json_parse(dispatch("GET", "/api/status"));
    const bool paused = st.has("paused") && st["paused"].b;
    return response_ok(dispatch("POST", paused ? "/api/pause?on=0" : "/api/pause?on=1"));
}

bool queue_remove(std::size_t index) {
    return response_ok(dispatch("POST", "/api/qdel?i=" + std::to_string(index)));
}

bool queue_move(std::size_t from, std::size_t to) {
    return response_ok(dispatch("POST", "/api/qmove?from=" + std::to_string(from) +
                                "&to=" + std::to_string(to)));
}

bool queue_clear() { return response_ok(dispatch("POST", "/api/clear")); }
bool queue_sort_default() { return response_ok(dispatch("POST", "/api/qsort?by=default")); }

bool queue_play_index(std::size_t index) {
    const QueueState q = queue(false);
    if (index >= q.items.size()) return false;
    return play_path(q.items[index].path);
}

bool saved_queue_save(const std::string& name) {
    if (name.empty()) return false;
    return response_ok(dispatch("POST", "/api/sq/save?name=" + url_encode(name)));
}

bool saved_queue_play(const std::string& name, int i) {
    if (name.empty()) return false;
    return response_ok(dispatch("POST", "/api/sq/play?name=" + url_encode(name) +
                                "&i=" + std::to_string(i)));
}

bool saved_queue_delete(const std::string& name) {
    if (name.empty()) return false;
    return response_ok(dispatch("POST", "/api/sq/delete?name=" + url_encode(name)));
}

bool favorite_set(const std::string& path, bool on) {
    if (path.empty()) return false;
    return response_ok(dispatch("POST", "/api/fav",
                                "file=" + url_encode(path) + "&on=" + (on ? "1" : "0")));
}

bool favorite_toggle(const std::string& path) {
    const auto list = favorite_tracks();
    bool on = false;
    for (const auto& t : list) if (t.path == path) { on = true; break; }
    return favorite_set(path, !on);
}

bool scan_library(bool full) {
    return response_ok(dispatch("POST", full ? "/api/rescan" : "/api/lib/scan"));
}

bool settings_save(const std::map<std::string, std::string>& kv) {
    if (kv.empty()) return false;
    std::string body;
    for (const auto& [k, v] : kv) {
        if (!body.empty()) body += "&";
        body += url_encode(k) + "=" + url_encode(v);
    }
    return response_ok(dispatch("POST", "/api/settings", body));
}

std::string get_theme() {
    const auto kv = settings();
    const auto it = kv.find("theme");
    if (it != kv.end()) {
        const std::string t = it->second;
        if (t == "dark" || t == "light" || t == "blue") return t;
    }
    return "light";   // 用户已定默认 light
}

bool set_theme(const std::string& theme) {
    if (theme != "dark" && theme != "light" && theme != "blue") return false;
    return settings_save({{"theme", theme}});
}

void reset_bridge_state() {
    std::lock_guard<std::mutex> lk(g_stateMx);
    g_revision = 0;
    g_last = PlaybackSnapshot{};
}

} // namespace rlnative
