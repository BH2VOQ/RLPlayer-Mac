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
#include <cstdio>
#include <ctime>
#include <fstream>
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

// ---------------------------------------------------------------------------
// 全量功能移植：文件/流媒体/设备/PEQ/OPRA/健康分析/房间校正/诊断
// ---------------------------------------------------------------------------
namespace {
rta::net::Json get_json(const std::string& path) {
    return rta::net::json_parse(dispatch("GET", path));
}
bool post_ok(const std::string& path, const std::string& body = std::string()) {
    return response_ok(dispatch("POST", path, body));
}
std::string file_name(const std::string& p) {
    const size_t s = p.find_last_of("/\\");
    return s == std::string::npos ? p : p.substr(s + 1);
}
} // namespace

FilesListing list_files(const std::string& path) {
    FilesListing out;
    std::string url = "/api/files";
    if (!path.empty()) url += "?path=" + url_encode(path);
    const auto j = get_json(url);
    if (!(j.has("ok") && j["ok"].b)) return out;
    out.ok = true;
    out.dir = j["dir"].s();
    for (const auto& d : j["dirs"].arr) {
        FileEntry e; e.name = d.s(); e.path = out.dir.empty() ? e.name : out.dir + "/" + e.name; e.dir = true;
        out.dirs.push_back(std::move(e));
    }
    for (const auto& f : j["files"].arr) {
        FileEntry e; e.name = file_name(f.s()); e.path = out.dir.empty() ? f.s() : out.dir + "/" + f.s(); e.dir = false;
        out.files.push_back(std::move(e));
    }
    return out;
}

std::vector<RemoteEntry> remote_browse(const std::string& id, bool search, const std::string& q) {
    std::vector<RemoteEntry> out;
    const std::string url = search ? ("/api/src/search?q=" + url_encode(q))
                                   : ("/api/src/browse?id=" + url_encode(id));
    const auto j = get_json(url);
    if (!(j.has("ok") && j["ok"].b)) return out;
    for (const auto& it : j["items"].arr) {
        RemoteEntry e;
        e.ok = true;
        e.id = it["id"].s();
        e.title = it["t"].s();
        e.artist = it["ar"].s();
        e.album = it["al"].s();
        e.suffix = it["sf"].s();
        e.dur = it["dur"].n();
        e.dir = it["dir"].b;
        e.coverId = it["cv"].s();
        out.push_back(std::move(e));
    }
    return out;
}

bool play_remote(const RemoteEntry& e) {
    if (e.id.empty()) return false;
    std::string body = "rid=" + url_encode(e.id) + "&rsuffix=" + url_encode(e.suffix) +
                       "&rtitle=" + url_encode(e.title);
    return post_ok("/api/play", body);
}

bool enqueue_remote(const RemoteEntry& e) {
    if (e.id.empty()) return false;
    std::string body = "rid=" + url_encode(e.id) + "&rsuffix=" + url_encode(e.suffix) +
                       "&rtitle=" + url_encode(e.title);
    return post_ok("/api/add", body);
}

std::vector<DeviceInfo> output_devices() {
    std::vector<DeviceInfo> out;
    const auto j = get_json("/api/devices");
    for (const auto& d : j["devices"].arr) {
        DeviceInfo i;
        i.id = d["id"].s(); i.name = d["name"].s(); i.mixFmt = d["mixFmt"].s();
        i.channels = (int)d["channels"].n();
        i.mixRate = (int)d["mixRate"].n();
        i.mixBits = (int)d["mixBits"].n();
        i.isDefault = d["default"].b;
        out.push_back(std::move(i));
    }
    return out;
}

std::vector<DeviceInfo> input_devices() {
    std::vector<DeviceInfo> out;
    const auto j = get_json("/api/indevices");
    for (const auto& d : j["devices"].arr) {
        DeviceInfo i;
        i.id = d["id"].s(); i.name = d["name"].s();
        i.isDefault = d["default"].b;
        i.loopback = d["loopback"].b;
        out.push_back(std::move(i));
    }
    return out;
}

bool input_start(const std::string& id, const std::string& mode, std::string& err) {
    const std::string body = "dev=" + url_encode(id) + "&mode=" + url_encode(mode.empty() ? "record" : mode);
    const auto j = rta::net::json_parse(dispatch("POST", "/api/input/start", body));
    if (j.has("ok") && j["ok"].b) return true;
    err = j.has("error") ? j["error"].s() : std::string("采集启动失败");
    return false;
}
bool input_stop() { return post_ok("/api/input/stop"); }
std::string input_state_json() { return dispatch("GET", "/api/input/state"); }

std::vector<CastDevice> cast_devices() {
    std::vector<CastDevice> out;
    const auto j = get_json("/api/cast/devices");
    for (const auto& d : j["devices"].arr) {
        CastDevice c;
        c.id = d["location"].s();
        if (c.id.empty()) c.id = d["dev"].s();
        c.name = d["friendlyName"].s();
        if (c.name.empty()) c.name = d["name"].s();
        c.airplay = d["kind"].s() == "airplay";
        out.push_back(std::move(c));
    }
    return out;
}
bool cast_start(const std::string& id, std::string& err) {
    const auto q = queue(false);
    std::string file;
    if (q.index < q.items.size()) file = q.items[q.index].path;
    if (file.empty()) { err = "当前没有可投放的曲目"; return false; }
    const std::string body = "dev=" + url_encode(id) + "&file=" + url_encode(file);
    const auto j = rta::net::json_parse(dispatch("POST", "/api/cast/start", body));
    if (j.has("ok") && j["ok"].b) return true;
    err = j.has("error") ? j["error"].s() : std::string("投放启动失败");
    return false;
}
bool cast_stop() { return post_ok("/api/cast/stop"); }
std::string cast_state_json() { return dispatch("GET", "/api/cast/state"); }

PeqState peq_state() {
    PeqState out;
    const auto j = get_json("/api/peq");
    if (!(j.has("ok") && j["ok"].b)) return out;
    out.ok = true;
    out.bypass = j["bypass"].n() != 0.0;
    out.preamp = j["preamp"].n();
    out.fs = j["fs"].n();
    out.name = j["name"].s();
    for (const auto& b : j["bands"].arr) {
        PeqBand x;
        x.index = (int)b["i"].n();
        x.on = b["on"].n() != 0.0;
        x.type = b["type"].s();
        x.freq = b["freq"].n(); x.gain = b["gain"].n(); x.q = b["q"].n();
        out.bands.push_back(std::move(x));
    }
    for (const auto& p : j["presets"].arr) out.presets.push_back(p.s());
    return out;
}
std::vector<std::pair<double, double>> peq_curve() {
    std::vector<std::pair<double, double>> out;
    const auto j = get_json("/api/peq");
    for (const auto& pt : j["points"].arr) {
        if (pt.size() >= 2) out.emplace_back(pt.at(0).n(), pt.at(1).n());
    }
    return out;
}

bool cover_prefetch_all() { return post_ok("/api/lib/cover/prefetch"); }

bool peq_save(const std::vector<PeqBand>& bands, bool bypass, double preamp, const std::string& name) {
    std::string spec;
    for (const auto& b : bands) {
        if (!spec.empty()) spec += ";";
        char buf[160];
        std::snprintf(buf, sizeof(buf), "%d,%s,%.2f,%.2f,%.3f,%s", b.index, b.type.c_str(), b.freq, b.gain, b.q, b.on ? "on" : "off");
        spec += buf;
    }
    std::string body = "bands=" + url_encode(spec) + "&bypass=" + (bypass ? "1" : "0");
    body += "&preamp=" + std::to_string(preamp);
    if (!name.empty()) body += "&name=" + url_encode(name);
    return post_ok("/api/peq", body);
}
bool peq_apply_preset(const std::string& name) {
    return post_ok("/api/peq/preset", "action=load&name=" + url_encode(name));
}

std::vector<OpraPreset> opra_presets(const std::string& product) {
    std::vector<OpraPreset> out;
    const auto j = get_json("/api/opra/presets?productId=" + url_encode(product));
    for (const auto& p : j["items"].arr) {
        OpraPreset x;
        x.id = p["id"].s();
        x.name = p["name"].s();
        if (x.name.empty()) x.name = x.id;
        x.product = product;
        out.push_back(std::move(x));
    }
    return out;
}
bool opra_apply(const std::string& productId, const std::string& presetId) {
    if (productId.empty() || presetId.empty()) return false;
    return post_ok("/api/opra/apply", "productId=" + url_encode(productId) +
                                     "&presetId=" + url_encode(presetId));
}

std::string health_stats_json() { return dispatch("GET", "/api/anl/stats"); }
std::string health_report_json(const std::string& file) {
    return dispatch("GET", "/api/health?file=" + url_encode(file));
}
bool enrich_track(const std::string& file) {
    return post_ok("/api/enrich?file=" + url_encode(file));
}
std::string meta_json(const std::string& file) { return dispatch("GET", "/api/meta?file=" + url_encode(file)); }

std::string room_status_json() { return dispatch("GET", "/api/roomcorr/status"); }
std::string room_layouts_json() { return dispatch("GET", "/api/roomcorr/layouts"); }
bool room_measure(const std::string& layout, double seconds, std::string& err) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.1f", seconds);
    const std::string url = "/api/roomcorr/measure?confirm=1&layout=" + url_encode(layout) + "&sec=" + buf;
    const auto j = rta::net::json_parse(dispatch("POST", url));
    if (j.has("ok") && j["ok"].b) return true;
    err = j.has("error") ? j["error"].s() : std::string("测量启动失败");
    return false;
}
bool room_cancel() { return post_ok("/api/roomcorr/cancel"); }

std::string diag_export(std::string& zipPath) {
    std::string ct;
    const std::string body = dispatch_ct("GET", "/api/diagzip", &ct);
    if (body.size() < 4 || ct.find("zip") == std::string::npos) return std::string();
    char tmpl[] = "/tmp/rlplayer-diag-XXXXXX";
    int fd = ::mkstemp(tmpl);
    if (fd < 0) return std::string();
    std::string path = std::string(tmpl) + ".zip";
    std::rename(tmpl, path.c_str());
    std::ofstream f(path, std::ios::binary);
    if (!f) return std::string();
    f.write(body.data(), (std::streamsize)body.size());
    f.close();
    zipPath = path;
    return path;
}
std::string signal_json() { return dispatch("GET", "/api/signal"); }
std::string providers_json() { return dispatch("GET", "/api/providers"); }
std::string entity_summary(const std::string& kind, const std::string& name) {
    return dispatch("GET", "/api/entity/summary?kind=" + url_encode(kind) + "&name=" + url_encode(name) + "&lang=zh");
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
