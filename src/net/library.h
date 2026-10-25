// library.h — 本地音乐库（索引 / 专辑 / 搜索 / 封面）
//
// 为什么要自己建索引：RLPlayer 的库管理一直被诟病（目录树 + 手动选文件），
// Roon 的做法是「艺术家 / 专辑 / 曲目」三层 + 全局搜索。这里照后者做，
// 但只依赖 ffprobe 读标签，不引入数据库。
//
// 设计要点：
//   * 索引落盘为 rlplayer-index.tsv，增量扫描：mtime+size 没变就复用旧记录，
//     只有新文件/改过的文件才真正跑 ffprobe（每文件一次进程，约 20-40 ms）
//   * 库根目录存 rlplayer-library.conf，每行一个
//   * 专辑键 = 专辑艺术家 + 0x1f + 专辑名（缺标签时退化为父目录名），
//     对外用 16 位十六进制哈希，避免 URL 里出现任意字符
//   * 扫描在后台线程做，查询永远不阻塞（读的是上一份完整的索引）
#pragma once
// _strtoi64 是 MSVC 名；macOS 单平台下统一映射到标准 strtoll（语义一致：十进制 64 位解析）。
// 2026-10-25 转 macOS 单平台：原 Windows 条件守卫已去掉，别名改为无条件定义。
#define _strtoi64 strtoll
#include "audio/audio_loader.h"
#include "audio/media_info.h"
#include "net/scan_pool.h"
#include "meta/entities.h"
#include <memory>
#include <string>
#include <vector>
#include <map>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <thread>
#include <filesystem>
#include <fstream>
#include <algorithm>
#include <cstdio>
#include <cstdint>

namespace rta::net {

namespace fsx = std::filesystem;

// 前置声明：class Library 的内联成员（removeRootEx / removeDirFromDisk）要用到下面这几个
// 路径工具，而它们的定义在类之后（p8 的注释解释了为什么不能用 fs::path(wstring)）。
inline std::string u8s(const std::u8string& s);
inline fsx::path p8(const std::string& s);
inline fsx::path lib_norm_path(const std::string& s);
inline bool lib_path_within(const std::string& child, const fsx::path& rootNorm);
inline bool lib_norm_equal(const std::string& a, const fsx::path& bNorm);

// 16 位十六进制哈希（FNV-1a）
inline std::string fnv_hex(const std::string& s) {
    uint64_t h = 1469598103934665603ull;
    for (unsigned char c : s) { h ^= (uint64_t)c; h *= 1099511628211ull; }
    char b[24];
    std::snprintf(b, sizeof(b), "%016llx", (unsigned long long)h);
    return std::string(b);
}

struct LibTrack {
    std::string path;         // 绝对路径（UTF-8）
    std::string title, artist, album, albumArtist, genre, codec;
    int    trackNo = 0, discNo = 0, year = 0;
    int    sampleRate = 0, bits = 0, channels = 0;
    double duration = 0;
    long long mtime = 0, size = 0;
    int    hasCover = 0;
};

struct LibAlbum {
    std::string key;          // 十六进制哈希（URL 用）
    std::string name, artist;
    int    year = 0;
    int    nTracks = 0;
    double duration = 0;
    bool   hasCover = false;
    std::vector<size_t> idx;  // tracks_ 下标，已按 disc/track 排序
};

class Library {
public:
    static Library& instance() { static Library L; return L; }

    // ---- 配置 ----
    std::vector<std::string> roots() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return roots_;
    }
    bool addRoot(const std::string& dir) {
        std::error_code ec;
        if (!fsx::is_directory(dir, ec)) return false;
        std::lock_guard<std::mutex> lk(mtx_);
        for (auto& r : roots_) if (r == dir) return true;
        roots_.push_back(dir);
        saveRootsLocked();
        return true;
    }
    // 移除库根。旧实现只从 roots_ 删目录：tracks_ 里该目录扫出来的曲目还在、索引文件也不清理
    // ⟹ 用户移除目录后歌还在列表里，点播放就失败（反馈 #3「扫描记录不可消除」）。
    // 现在同步清理该根（含子目录）下的曲目并重新落盘索引。
    // ★ 边界：移除 /Music/A 不能误删 /Music/AB 的歌 —— 判定走 fs 路径分量比较
    //   （lib_path_within），不是字符串前缀（"/Music/AB" 以 "/Music/A" 为字符串前缀）。
    // 保留 bool 返回（tests/test_library.cpp 依赖）；需要曲目数用 removeRootEx。
    bool removeRoot(const std::string& dir) { return removeRootEx(dir) >= 0; }

    // 移除库根并返回被清理的曲目数；-1 = 该目录不是库根（什么都没改）。
    int removeRootEx(const std::string& dir) {
        std::string snap;
        int removed = 0;
        {
            std::lock_guard<std::mutex> lk(mtx_);
            auto it = std::find(roots_.begin(), roots_.end(), dir);
            if (it == roots_.end()) return -1;
            roots_.erase(it);
            saveRootsLocked();
            removed = purgeTracksUnderLocked(lib_norm_path(dir), &snap);
        }
        if (removed > 0) writeIndex(snap);   // 锁外落盘：与扫描完成同一约定（见 buildIndexLocked 注释）
        return removed;
    }

    // 磁盘目录已被删除后清理索引（#4 的收尾）：否则和 #3 一样会留下点不动的行。
    int purgeTracksUnder(const std::string& dir) {
        std::string snap;
        int removed = 0;
        {
            std::lock_guard<std::mutex> lk(mtx_);
            removed = purgeTracksUnderLocked(lib_norm_path(dir), &snap);
        }
        if (removed > 0) writeIndex(snap);
        return removed;
    }

    // 真删磁盘目录（反馈 #4「目录删不掉」）：与「从库中移除」是两件事，这里只做删文件。
    // 返回 false 时 err 是给人看的中文原因；成功时 files/dirs 是删除前的统计（根目录本身不计入 dirs）。
    bool removeDirFromDisk(const std::string& dir, int& files, int& dirs, std::string& err) {
        files = 0; dirs = 0;
        const fsx::path target = lib_norm_path(dir);
        if (!checkRemovableDirLocked(dir, target, err)) return false;
        if (!scanTreeForRemoval(target, files, dirs, err)) return false;
        std::error_code ec;
        const std::uintmax_t n = fsx::remove_all(target, ec);
        if (ec || n == (std::uintmax_t)-1) {
            err = "删除失败：" + (ec ? ec.message() : std::string("未知错误"));
            return false;
        }
        return true;
    }

    // 只统计、不删除：给前端二次确认弹窗提供「将删除 N 个文件」的真实数字（反馈 #4）。
    // 安全判据与 removeDirFromDisk 完全一致（同一份 checkRemovableDirLocked），
    // 所以弹窗里能显示数字的目录，就是真删时会被允许的目录 —— 不会出现「确认了才被拒绝」。
    bool scanDirForRemoval(const std::string& dir, int& files, int& dirs, std::string& err) {
        files = 0; dirs = 0;
        const fsx::path target = lib_norm_path(dir);
        if (!checkRemovableDirLocked(dir, target, err)) return false;
        return scanTreeForRemoval(target, files, dirs, err);
    }

    // ---- 状态 ----
    bool scanning() const { return scanning_.load(); }
    int  scanned()  const { return scanned_.load(); }
    int  scanTotal() const { return total_.load(); }
    std::string scanMsg() const { std::lock_guard<std::mutex> lk(mtx_); return scanMsg_; }
    size_t trackCount() const { std::lock_guard<std::mutex> lk(mtx_); return tracks_.size(); }
    size_t albumCount() const { std::lock_guard<std::mutex> lk(mtx_); return albumVecLocked().size(); }

    void setScanThreads(size_t n) {
        std::lock_guard<std::mutex> lk(mtx_);
        scanThreads_ = n;
    }
    size_t scanThreads() const {
        std::lock_guard<std::mutex> lk(mtx_);
        if (scanThreads_ > 0) return scanThreads_;
        return defaultScanThreads();
    }
    static size_t defaultScanThreads() {
        unsigned int h = std::thread::hardware_concurrency();
        return std::min(std::max(1u, h), 8u);
    }
    double lastScanMs() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return lastScanMs_;
    }
    int lastScanProbed() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return lastScanProbed_;
    }
    int lastScanCached() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return lastScanCached_;
    }

    // ---- 查询 ----
    std::vector<LibAlbum> albums() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return albumVecLocked();
    }
    bool album(const std::string& key, LibAlbum& out) const {
        std::lock_guard<std::mutex> lk(mtx_);
        const auto& v = albumVecLocked();
        for (auto& a : v) if (a.key == key) { out = a; return true; }
        return false;
    }
    bool trackAt(size_t i, LibTrack& out) const {
        std::lock_guard<std::mutex> lk(mtx_);
        if (i >= tracks_.size()) return false;
        out = tracks_[i];
        return true;
    }
    // 返回命中曲目的下标（最多 limit 条）
    std::vector<size_t> search(const std::string& q, size_t limit = 300) const;

    // 某专辑的封面（字节 + mime），失败返回空
    bool albumCover(const std::string& key, std::vector<unsigned char>& bytes, std::string& mime);

    // ---- 扫描 ----
    void load();            // 读配置与索引
    void startScan(bool forceFull = false);
    void stopScan() {
        cancel_.store(true);
        std::shared_ptr<ScanPool> p;
        {
            std::lock_guard<std::mutex> lk(mtx_);
            p = activePool_;
        }
        if (p) p->cancel();
    }
    void joinScan();

    // 退出兜底（mac .app 实测崩溃 2026-10-25：库空时启动自动扫描，进程退出时 th_ 仍
    // joinable，std::thread 析构 ⟹ std::terminate ⟹ SIGABRT 弹系统崩溃报告）。
    // stopScan 已有（cancel_ + pool cancel），joinScan 收线程；幂等，正常路径零影响。
    ~Library() {
        try { stopScan(); joinScan(); } catch (...) {}
    }

private:
    Library() = default;

    void saveRootsLocked();
    // 索引落盘拆成两步（2026-10-25）：buildIndexLocked() 在锁内构造快照字符串，
    // writeIndex() 在锁外写盘 —— 否则整份索引（实测 12000 首 1.28 MB）写盘期间持锁，HTTP 单线程服务整个卡住。
    std::string buildIndexLocked() const;
    void writeIndex(const std::string& snapshot);
    // 删除 tracks_ 中位于 rootNorm 之下（含该目录自身）的曲目，返回删除数。
    // 调用方必须已持 mtx_；返回 >0 时 *snapOut 是重算好的索引快照，由调用方在锁外落盘。
    int purgeTracksUnderLocked(const fsx::path& rootNorm, std::string* snapOut);
    // #4 删目录的三条安全判据（① 库根之下 ② 不是库根本身 ③ 不是符号链接）。
    // removeDirFromDisk 与 scanDirForRemoval 共用，保证「弹窗能显示数字」与「真删被允许」同一判据。
    bool checkRemovableDirLocked(const std::string& dir, const fsx::path& target, std::string& err);
    // 递归统计 files/dirs，且树内出现任何 symlink 一律拒绝（不跟随）。
    static bool scanTreeForRemoval(const fsx::path& target, int& files, int& dirs, std::string& err);
    const std::vector<LibAlbum>& albumVecLocked() const;
    static std::string readFile(const std::string& p);
    static void writeFile(const std::string& p, const std::string& s);
    static std::string exeDirOrEmpty();   // 2026-10-23：库配置/索引固定落 exe 目录（见 confPath 注释）
    static std::string libDataDir();      // 同样可被 RLPLAYER_LIBRARY_DIR 覆盖（测试/多实例）
    static std::string confLeaf(const char* base);   // 非默认端口加 .p<port> 后缀，避免实例互相踩库
    static std::string confPath();
    static std::string indexPath();

    mutable std::mutex mtx_;
    std::vector<std::string> roots_;
    std::vector<LibTrack> tracks_;
    mutable std::vector<LibAlbum> albums_;
    mutable bool albumsDirty_ = true;
    mutable std::map<std::string, std::pair<std::vector<unsigned char>, std::string>> coverCache_;

    std::thread th_;
    std::atomic<bool> scanning_{false};
    std::atomic<bool> cancel_{false};
    std::atomic<int>  scanned_{0};
    std::atomic<int>  total_{0};
    std::string scanMsg_;

    size_t scanThreads_ = 0;
    double lastScanMs_ = 0.0;
    int lastScanProbed_ = 0;
    int lastScanCached_ = 0;
    std::shared_ptr<ScanPool> activePool_;
};

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

inline std::string lib_clean_field(const std::string& s) {
    std::string o; o.reserve(s.size());
    for (char c : s) o += (c == '\t' || c == '\n' || c == '\r') ? ' ' : c;
    return o;
}

// 路径构造：macOS 上路径原生 UTF-8（2026-10-25 删掉 Windows 的 ANSI/宽字符分支）
inline std::string u8s(const std::u8string& s) { return std::string((const char*)s.data(), s.size()); }
inline fsx::path p8(const std::string& s) {
    // POSIX：路径原生 UTF-8。绝不能走 fs::path(wstring)——macOS 27 的 libc++ 对
    // wstring 转换走 codecvt facet，该 facet 不存在时直接抛 "locale not supported"
    //（实测：Library::load() 启动即崩，lldb 栈帧 __narrow_to_utf8<32>）。
    return fsx::u8path(s);
}

// 同目录是否存在独立封面文件（与 get_cover 的候选顺序/扩展名保持一致；只 stat）
inline bool lib_has_cover_file(const std::string& trackPath) {
    std::error_code ec;
    fsx::path dir = p8(trackPath).parent_path();
    static const char* kNames[] = { "cover", "folder", "front", "Cover", "Folder" };
    static const char* kExts[]  = { ".jpg", ".jpeg", ".png", ".JPG", ".PNG" };
    for (const char* n : kNames)
        for (const char* e : kExts)
            if (fsx::exists(dir / (std::string(n) + e), ec)) return true;
    return false;
}

// ---- 路径包含判定（#3 移除库根 / #4 删目录的安全判据共用）----
// 为什么不用字符串前缀："/Music/AB" 以 "/Music/A" 为字符串前缀，会把 AB 的歌一起删掉，
// 也可能被 "../" 穿越绕过。这里统一走 fs::path 的**路径分量**比较：
//   lib_norm_path()   = lexically_normal（吃掉 "." / ".." / 重复分隔符 / 结尾分隔符）
//   lib_path_within() = child 的每个分量前缀都等于 root 的分量（root 自身算"在其内"）
//   lib_norm_equal()  = 规范化后分量完全相等
inline fsx::path lib_norm_path(const std::string& s) {
    std::error_code ec;
    fsx::path p = p8(s);
    fsx::path n = p.lexically_normal();
    if (n.empty()) return p;
    // 结尾分隔符会让最后一个分量变成空串（实测 "/Music/A/" 分量 = </> <Music> <A> <>），
    // 会让「相等」判定失真 ⟹ 统一去掉尾分隔符（根 "/" 除外）。
    while (n.has_relative_path() && n.filename().empty()) n = n.parent_path();
    return n;
}
inline bool lib_path_within(const std::string& child, const fsx::path& rootNorm) {
    const fsx::path c = lib_norm_path(child);
    auto ci = c.begin();
    for (auto ri = rootNorm.begin(); ri != rootNorm.end(); ++ri, ++ci) {
        if (ci == c.end()) return false;
        if (*ci != *ri) return false;
    }
    return true;
}
inline bool lib_norm_equal(const std::string& a, const fsx::path& bNorm) {
    return lib_norm_path(a) == bNorm;
}

inline bool lib_is_audio(const fsx::path& p) {
    std::string ext = u8s(p.extension().u8string());
    for (auto& c : ext) c = (char)std::tolower((unsigned char)c);
    static const char* kExt[] = { ".wav", ".wave", ".flac", ".m4a", ".alac", ".mp3", ".aac",
                                  ".ogg", ".opus", ".wma", ".ape", ".wv", ".dsf", ".dff",
                                  ".aif", ".aiff", ".aifc", ".caf", ".mka", ".mpc" };
    for (auto* x : kExt) if (ext == x) return true;
    return false;
}

// 一次 ffprobe 取全部信息（比 media_info.h 的两次调用快一倍）
inline LibTrack lib_probe_one(const std::string& file, const std::string& ffprobePath = "") {
    LibTrack t;
    t.path = file;
    const std::string ffprobe = !ffprobePath.empty() ? ffprobePath : rta::audio::find_tool("ffprobe");
    if (ffprobe.empty()) return t;

    std::string out;
    // 2026-10-23 真机 DEBUG（用户反馈「1.3.x 封面不显示」，实测曲目 C:\...\谭晶 - 游京 (长征版).flac）：
    // 那首是**单文件 + 内嵌封面**（同目录没有 cover.jpg），而 hasCover 只看同目录文件 → cv:false → UI 不显示封面；
    // 但 /api/cover 其实能抽出 706,780 字节的图。所以必须在这里同时问「有没有视频流（=内嵌封面）」。
    // 做法：去掉 -select_streams（一次读出所有流），流里 codec_type=video 即内嵌封面/图片。
    //   ⚠️ 注意：某些容器把封面报成 video 流，所以只看 codec_type 即可，不看 codec_name。
    const std::wstring cmd =
        L"\"" + rta::audio::widen(ffprobe) + L"\" -v error"
        L" -show_entries stream=codec_type,codec_name,sample_rate,channels,bits_per_raw_sample"
        L" -show_entries format=duration:format_tags=title,artist,album,album_artist,date,genre,track,disc,tracktotal"
        L" -of default=nw=1 \"" + rta::audio::widen(file) + L"\"";
    if (rta::audio::run_hidden(cmd, &out) != 0) return t;

    std::string title, artist, album, aartist, date, genre, track, disc;
    bool curIsAudio = false;   // 当前解析到的流是不是音频（封面流的字段不能覆盖音频参数）
    std::string line;
    for (size_t i = 0; i <= out.size(); ++i) {
        if (i == out.size() || out[i] == '\n') {
            const size_t e = line.find('=');
            if (e != std::string::npos) {
                std::string k = line.substr(0, e);
                const std::string v = line.substr(e + 1);
                for (auto& c : k) c = (char)std::tolower((unsigned char)c);
                if (k.compare(0, 4, "tag:") == 0) k = k.substr(4);
                auto put = [&](std::string& dst) { dst = v; while (!dst.empty() && (dst.back() == '\r' || dst.back() == ' ')) dst.pop_back(); };
                // 2026-10-23：内嵌封面判定 —— 出现任意 codec_type=video 的流即视为有封面
                if (k == "codec_type") {
                    std::string v2 = v; while (!v2.empty() && (v2.back() == '\r' || v2.back() == ' ')) v2.pop_back();
                    if (v2 == "video") t.hasCover = 1;
                    curIsAudio = (v2 == "audio");
                    line.clear(); continue;
                }
                if      (k == "title")        put(title);
                else if (k == "artist")       put(artist);
                else if (k == "album")        put(album);
                else if (k == "album_artist") put(aartist);
                else if (k == "albumartist")  put(aartist);
                else if (k == "date")         put(date);
                else if (k == "genre")        put(genre);
                else if (k == "track")        put(track);
                else if (k == "disc")         put(disc);
                else if (k == "codec_name")   put(t.codec);
                // 2026-10-23：去掉 -select_streams 后，封面流（mjpeg）的字段会覆盖音频流
                // （实测：24-bit FLAC + mjpeg 封面 → t.bits 被写成 8）。所以这里只在「当前流是音频」时采信。
                else if (k == "sample_rate")  { if (curIsAudio) t.sampleRate = atoi(v.c_str()); }
                else if (k == "channels")     { if (curIsAudio) t.channels = atoi(v.c_str()); }
                else if (k == "bits_per_raw_sample") { if (curIsAudio) t.bits = atoi(v.c_str()); }
                else if (k == "duration")     t.duration = atof(v.c_str());
            }
            line.clear();
        } else if (line.size() < 8192) line += out[i];
    }
    t.title = title; t.artist = artist; t.album = album;
    t.albumArtist = aartist; t.genre = genre;
    t.trackNo = atoi(track.c_str());
    t.discNo  = atoi(disc.c_str());
    t.year    = atoi(date.c_str());
    if (t.bits <= 0) t.bits = (t.codec == "flac" || t.codec == "alac") ? 16 : 16;
    // 封面存在性（2026-10-23 修：此前 hasCover 恒 0，UI 因此不请求封面 → 「封面全部不显示」）
    // 只 stat 同目录 cover/folder/front（与 get_cover 的查找顺序一致），不启动 ffmpeg，扫描开销可忽略。
    // 内嵌封面无法靠 stat 判断，这里只保证「有独立封面文件」的专辑能显示；没有独立文件的专辑
    // 仍会在 get_cover 阶段尝试内嵌抽取（UI 用 img onerror 兜底，不会裂图）。
    // 只置位不清零：上面若已从内嵌封面流判定为 1，不能被同目录探测覆盖回 0。
    // （两种情况任一成立即视为有封面：内嵌 PICTURE/APIC 流，或同目录 cover/folder/front 文件。）
    if (!t.hasCover && lib_has_cover_file(t.path)) t.hasCover = 1;
    return t;
}

// 2026-10-23 修复「曲库根丢失 / 索引漂移」：
//   旧实现返回相对文件名 → 实际落在进程 cwd，而 8899 实例是从 exe 目录启动、自检沙箱是另一个 cwd，
//   两边看到的是不同的 library.conf / index.tsv（用户升级后曲库变空、封面全无，就是这么来的）。
//   统一改为 **exe 目录绝对路径**（取不到 exe 目录时退回相对名，保证老行为可用）。
inline std::string Library::exeDirOrEmpty() {
    const std::wstring w = rta::audio::exe_dir_w();
    if (w.empty()) return std::string();
    std::string u = rta::audio::wide_to_utf8(w);
    while (!u.empty() && (u.back() == '\\' || u.back() == '/')) u.pop_back();
    return u;
}
// 配置/索引落点：
//   1) 环境变量 RLPLAYER_LIBRARY_DIR（测试 / 多实例 / 便携部署用；测试必须用它，否则会读到真实库配置）
//   2) 否则用 platform::data_dir_utf8()（macOS = ~/Library/Application Support/RLPlayer）
//   3) 再取不到才退回 exe 目录（老行为 / 便携兜底）
//
// 2026-10-25（默认目录纠正）：第 2 档原来是「exe 目录」。在 macOS 上那是
// RLPlayer.app/Contents/MacOS/ —— 应用包是只读签名体，配置与曲库索引写进去会在
// 正式签名/公证后失败，且随 .app 升级被静默丢弃（用户表现为「升级后曲库变空」）。
// 改为按 macOS 规范落 ~/Library/Application Support/RLPlayer。
// 注意：**多实例后缀 confLeaf() 仍然生效**（.p<port>），所以自检沙箱与用户实例
// 即使共用同一个目录也不会互相覆盖。
inline std::string Library::libDataDir() {
    if (const char* env = std::getenv("RLPLAYER_LIBRARY_DIR")) {
        if (*env) { std::string s(env); while (!s.empty() && (s.back() == '\\' || s.back() == '/')) s.pop_back(); if (!s.empty()) return s; }
    }
    const std::string dataDir = rta::platform::data_dir_utf8();
    if (!dataDir.empty()) return dataDir;
    return exeDirOrEmpty();
}
// 文件名区分实例：默认实例（8899）用原名；--port 指定的其它实例加 ".p<端口>" 后缀。
// 为什么不再共用一份：自检沙箱（8907/8908/8911）会写自己的库根与索引，共用会把用户库覆盖成空
// （1.3.x「升级后曲库变空」的另一半原因）。端口从 RLPLAYER_PORT 取（rtaweb 启动时设置）。
inline std::string Library::confLeaf(const char* base) {
    const char* p = std::getenv("RLPLAYER_PORT");
    const std::string port = (p && *p) ? std::string(p) : std::string();
    std::string name(base);
    if (!port.empty() && port != "8899") name += ".p" + port;
    return name;
}
// 2026-10-25 修「重打包会静默删掉用户曲库索引」：
//   旧实现硬编码 '\\' 拼路径。'\\' 只是 Windows 的分隔符；macOS/Linux 上它是**合法文件名字符**，
//   于是索引实际落在 `<exe 目录的父目录>` 下、文件名是 `MacOS\rlplayer-index.tsv`
//   （实测产物：RLPlayer.app/Contents/MacOS\rlplayer-index.tsv，看着像目录其实是一个文件）。
//   读写都走同一个错路径，所以运行时从不报错，只有在重新打包 rm -rf Contents/* 时才暴露 ——
//   用户曲库索引被静默删掉，下次启动全量重扫。
//   改用平台层唯一的拼接入口 rta::platform::join（platform/path.h:41，自动用 native_separator()）。
inline std::string Library::confPath() {
    const std::string d = libDataDir(), leaf = confLeaf("rlplayer-library.conf");
    return d.empty() ? leaf : rta::platform::join(d, leaf);
}
inline std::string Library::indexPath() {
    const std::string d = libDataDir(), leaf = confLeaf("rlplayer-index.tsv");
    return d.empty() ? leaf : rta::platform::join(d, leaf);
}
inline std::string Library::readFile(const std::string& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) {
        // 老版本用 rta- 前缀：读不到新文件时回退一次（迁移用，不重建用户的库）
        if (p.rfind("rlplayer-", 0) == 0) {
            std::ifstream f2("rta-" + p.substr(9), std::ios::binary);
            if (f2) return std::string((std::istreambuf_iterator<char>(f2)), std::istreambuf_iterator<char>());
        }
        return "";
    }
    std::string s((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    return s;
}
inline void Library::writeFile(const std::string& p, const std::string& s) {
    std::string tmp = p + ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return;
        f.write(s.data(), (std::streamsize)s.size());
        // ★ 2026-10-25（索引一致性审查）：必须在 flush 之后才能 rename。
        //   旧实现出了作用域才析构 → 析构时才 flush；写盘出错时剩下的只有"截断的 tmp"，
        //   而 rename 不看内容。这里把"写失败"变成"绝不替换旧索引"，并在 rename 前检查。
        f.flush();
        if (!f.good()) { f.close(); std::error_code e2; fsx::remove(tmp, e2); return; }
    }
    std::error_code ec;
    fsx::rename(tmp, p, ec);
    // rename 不能覆盖已存在文件时（个别网络盘/杀软占用），退化为"删旧再改名"；
    // 仍然失败就保留 tmp（不回滚旧索引 —— 旧索引比没有索引好）。
    if (ec) {
        std::error_code e2;
        fsx::remove(p, e2);
        ec.clear();
        fsx::rename(tmp, p, ec);
    }
}

inline void Library::load() {
    {
        std::string conf = readFile(confPath());
        if (conf.size() >= 3 && (unsigned char)conf[0] == 0xEF && (unsigned char)conf[1] == 0xBB && (unsigned char)conf[2] == 0xBF)
            conf = conf.substr(3);
        std::lock_guard<std::mutex> lk(mtx_);
        roots_.clear();
        std::string line;
        for (size_t i = 0; i <= conf.size(); ++i) {
            if (i == conf.size() || conf[i] == '\n') {
                while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
                if (!line.empty() && line[0] != '#') roots_.push_back(line);
                line.clear();
            } else line += conf[i];
        }
        if (roots_.empty()) {
            // 首次运行：探一遍常见位置，别一打开就是空的（RLPlayer 被诟病的就是这个）
            //
            // 2026-10-25（默认目录纠正）：本项目已改为 macOS 单平台，但这里仍留着
            // Windows 盘符探测（D:\Music / E:\音乐 / C:\Users\Public\Music …），
            // 在 macOS 上**永远不可能命中** ⟹ 首次启动必定落进最后的兜底
            // "C:\Users\Public\Music"（一个 macOS 上不存在的路径），曲库恒为空。
            // 现在按平台分支：macOS 用 HOME 下的 Music / 音乐 / Downloads/Music 等真实位置。
            std::vector<std::string> cands;
#if defined(__APPLE__)
            if (const char* home = std::getenv("HOME")) {
                const std::string h(home);
                // 顺序即优先级：先 Apple 默认音乐目录，再中文目录名（本机常见），
                // 再下载目录（用户常把音乐丢这里），最后 iCloud Drive。
                for (const char* sub : { "/Music", "/音乐", "/Downloads/Music",
                                         "/Downloads/音乐",
                                         "/Library/Mobile Documents/com~apple~CloudDocs/Music" })
                    cands.push_back(h + sub);
            }
            // 系统级共享音乐目录（对应 Windows 的 Public\Music）
            cands.push_back("/Users/Shared/Music");
            cands.push_back("/Users/Shared/音乐");
#else
            if (const char* up = std::getenv("USERPROFILE")) {
                cands.push_back(std::string(up) + "\\Music");
                cands.push_back(std::string(up) + "\\音乐");
            }
            for (const char* d : { "D:\\Music", "E:\\Music", "D:\\音乐", "E:\\音乐",
                                   "D:\\MUSIC", "E:\\MUSIC", "C:\\Users\\Public\\Music" })
                cands.push_back(d);
#endif
            std::error_code ec;
            for (const auto& c : cands) {
                if (!fsx::is_directory(p8(c), ec)) continue;
                bool dup = false;
                for (auto& r : roots_) if (r == c) dup = true;
                if (!dup) roots_.push_back(c);
                if (roots_.size() >= 4) break;
            }
            // 兜底：一个都没探到就【留空】而不是塞一个不存在的路径。
            // 塞假路径的后果是界面上显示一个根目录、扫描永远 0 首、用户以为程序坏了；
            // 留空则界面显示「未添加音乐目录」，用户知道该自己点「添加目录」。
            // （2026-10-25 修正：原代码兜底 push "C:\Users\Public\Music"，macOS 上必错。）
            //
            // 2026-10-25（用户报「改完文件夹重启又回归」的根因之一）：
            // 探测到的默认目录以前**只进内存、从不落盘** ⟹ 每次启动都重新探测一遍，
            // 用户看到的就是「我改了，但重启又变回去」。这里探测成功后立刻写回 conf，
            // 让"首次自动选中的目录"也成为一个稳定的、可被用户覆盖的持久值。
            if (!roots_.empty()) saveRootsLocked();
        }
    }
    // 索引
    std::string idx = readFile(indexPath());
    if (idx.size() >= 3 && (unsigned char)idx[0] == 0xEF && (unsigned char)idx[1] == 0xBB && (unsigned char)idx[2] == 0xBF)
        idx = idx.substr(3);
    // 2026-10-23：索引格式版本校验。旧索引（无 #libIndexV 或版本不符）直接丢弃，
    // 本次扫描会全量重建 —— 否则升级后「扫描逻辑改了但旧索引被复用」，修复永远不生效。
    // 代价：升级后首次启动会全量扫一遍（653 首约 10 秒，并行 8 线程），之后照旧增量。
    {
        const bool fresh = (idx.find("#libIndexV\t3") != std::string::npos);
        if (!fresh && !idx.empty()) idx.clear();
    }
    std::vector<LibTrack> loaded;
    if (!idx.empty()) {
        std::string line;
        for (size_t i = 0; i <= idx.size(); ++i) {
            if (i == idx.size() || idx[i] == '\n') {
                if (!line.empty() && line[0] != '#') {
                    std::vector<std::string> f;
                    size_t s = 0;
                    for (size_t k = 0; k <= line.size(); ++k) {
                        if (k == line.size() || line[k] == '\t') { f.push_back(line.substr(s, k - s)); s = k + 1; }
                    }
                    if (f.size() >= 16) {
                        LibTrack t;
                        t.path        = f[0];
                        t.mtime       = _strtoi64(f[1].c_str(), nullptr, 10);
                        t.size        = _strtoi64(f[2].c_str(), nullptr, 10);
                        t.album       = f[3];
                        t.albumArtist = f[4];
                        t.artist      = f[5];
                        t.title       = f[6];
                        t.trackNo     = atoi(f[7].c_str());
                        t.discNo      = atoi(f[8].c_str());
                        t.year        = atoi(f[9].c_str());
                        t.sampleRate  = atoi(f[10].c_str());
                        t.bits        = atoi(f[11].c_str());
                        t.channels    = atoi(f[12].c_str());
                        t.duration    = atof(f[13].c_str());
                        t.hasCover    = atoi(f[14].c_str());
                        t.genre       = f[15];
                        if (!t.path.empty()) loaded.push_back(t);
                    }
                }
                line.clear();
            } else line += idx[i];
        }
    }
    {
        std::lock_guard<std::mutex> lk(mtx_);
        tracks_.swap(loaded);
        albumsDirty_ = true;
    }
    std::string sconf = readFile("rlplayer-settings.conf");
    if (sconf.size() >= 3 && (unsigned char)sconf[0] == 0xEF && (unsigned char)sconf[1] == 0xBB && (unsigned char)sconf[2] == 0xBF)
        sconf = sconf.substr(3);
    if (!sconf.empty()) {
        std::string line;
        for (size_t i = 0; i <= sconf.size(); ++i) {
            if (i == sconf.size() || sconf[i] == '\n') {
                while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
                const size_t e = line.find('=');
                if (e != std::string::npos) {
                    const std::string k = line.substr(0, e);
                    const std::string v = line.substr(e + 1);
                    if (k == "scanThreads" || k == "scanthreads") {
                        const int st = atoi(v.c_str());
                        if (st > 0) {
                            std::lock_guard<std::mutex> lk(mtx_);
                            scanThreads_ = (size_t)st;
                        }
                    }
                }
                line.clear();
            } else line += sconf[i];
        }
    }
}

inline void Library::saveRootsLocked() {
    std::string s = "# RLPlayer 音乐库根目录，每行一个\n";
    for (auto& r : roots_) s += r + "\n";
    writeFile(confPath(), s);
}

// 删除 tracks_ 中位于 rootNorm 之下的曲目（反馈 #3）。
// 调用方已持 mtx_。判据是路径分量包含（lib_path_within），因此：
//   root=/Music/A  ⟹  /Music/A/t1 删；/Music/AB/t1 **不删**（分量 <AB> ≠ <A>）。
// 返回删除数；>0 时顺手把 albumsDirty_ 置脏，并在 *snapOut 里留下重算后的索引快照
// （锁内只构造字符串，锁外由调用方 writeIndex 落盘 —— 与扫描完成同一约定）。
inline int Library::purgeTracksUnderLocked(const fsx::path& rootNorm, std::string* snapOut) {
    std::vector<LibTrack> keep;
    keep.reserve(tracks_.size());
    int removed = 0;
    for (auto& t : tracks_) {
        if (lib_path_within(t.path, rootNorm)) { ++removed; continue; }
        keep.push_back(std::move(t));
    }
    if (removed == 0) return 0;
    tracks_.swap(keep);
    albumsDirty_ = true;
    if (snapOut) *snapOut = buildIndexLocked();
    return removed;
}

// #4 的三条安全判据。dir 是用户给的原始串（未规范化），target 是 lib_norm_path(dir)。
// ① 必须落在某个库根之下 —— 用**路径分量**包含判定（lib_path_within），不是字符串前缀：
//    "/lib/../etc" 规范化后是 "/etc"，分量前缀对不上任何库根 ⟹ 拒绝，穿越无效。
// ② 库根本身拒绝（只能删根里面的子目录）。
// ③ 目标自身不能是符号链接：symlink_status 不跟随，能看出真身；
//    若跟随（status）就会把 /lib/link -> /Users/x 当成库内目录，递归删掉库外内容。
inline bool Library::checkRemovableDirLocked(const std::string& dir, const fsx::path& target,
                                            std::string& err) {
    {
        std::lock_guard<std::mutex> lk(mtx_);
        bool insideRoot = false, isRoot = false;
        for (const auto& r : roots_) {
            const fsx::path rn = lib_norm_path(r);
            if (!lib_path_within(dir, rn)) continue;
            insideRoot = true;
            if (lib_norm_equal(dir, rn)) { isRoot = true; break; }
        }
        if (!insideRoot) { err = "只能删除音乐库根目录之下的子目录"; return false; }
        if (isRoot)      { err = "不能删除音乐库根目录本身（请用「从库中移除」）"; return false; }
    }
    std::error_code ec;
    const fsx::file_status st = fsx::symlink_status(target, ec);
    if (ec || !fsx::exists(st)) { err = "目录不存在"; return false; }
    if (fsx::is_symlink(st)) { err = "拒绝删除符号链接（可能指向库外）"; return false; }
    if (!fsx::is_directory(st)) { err = "不是目录"; return false; }
    return true;
}

// 递归预扫：统计 files/dirs，且树内任何 symlink 直接拒绝。
// 为什么在删除**之前**扫：删一半再报错会留下半残目录树，比直接拒绝更糟。
inline bool Library::scanTreeForRemoval(const fsx::path& target, int& files, int& dirs,
                                       std::string& err) {
    std::error_code ec;
    for (auto it = fsx::recursive_directory_iterator(
             target, fsx::directory_options::skip_permission_denied, ec);
         it != fsx::recursive_directory_iterator(); it.increment(ec)) {
        if (ec) { err = "遍历目录失败：" + ec.message(); return false; }
        const fsx::file_status s = it->symlink_status(ec);
        if (ec) { err = "读取目录项失败：" + ec.message(); return false; }
        if (fsx::is_symlink(s)) {
            err = "目录内含符号链接，拒绝删除（可能指向库外）：" +
                  u8s(it->path().filename().u8string());
            return false;
        }
        if (fsx::is_directory(s)) ++dirs;
        else ++files;
    }
    return true;
}

// 2026-10-25 修「扫描完成时整个服务卡住」：索引格式化 + 写盘（实测 12000 首 1.28 MB）原先在持 mtx_ 时做，
//   写盘期间所有查询（albums/search/trackAt）全部排队，HTTP 单线程服务直接失去响应。
//   现在拆成两步：锁内只把 tracks_ 快照格式化成字符串（纯内存，微秒级），锁外再落盘。
//   调用方约定：本函数**不再自己加锁**，必须在已持 mtx_ 的临界区里调用（旧名带 Locked 就是这个意思）。
inline std::string Library::buildIndexLocked() const {
    std::string s;
    s.reserve(tracks_.size() * 160 + 64);
    // 索引格式版本：改动「扫描产出字段」时必须 +1，否则旧索引会因为 mtime+size 未变而被整份复用，
    // 新逻辑永远不生效（2026-10-23 真机踩到：加了内嵌封面判定，用户那首 cv 仍是 false）。
    // v2 = 2026-10-23 起 hasCover 同时覆盖「内嵌封面流」与「同目录封面文件」。
    s += "#libIndexV\t3\n";   // v3 = 2026-10-23 起「音频流字段不再被封面流覆盖」(24-bit 不再变 8)
    s += "#path\tmtime\tsize\talbum\talbumArtist\tartist\ttitle\ttrack\tdisc\tyear\tsr\tbits\tch\tdur\thasCover\tgenre\n";
    char buf[256];
    for (auto& t : tracks_) {
        s += lib_clean_field(t.path); s += '\t';
        std::snprintf(buf, sizeof(buf), "%lld\t%lld\t", t.mtime, t.size); s += buf;
        s += lib_clean_field(t.album);       s += '\t';
        s += lib_clean_field(t.albumArtist); s += '\t';
        s += lib_clean_field(t.artist);      s += '\t';
        s += lib_clean_field(t.title);       s += '\t';
        std::snprintf(buf, sizeof(buf), "%d\t%d\t%d\t%d\t%d\t%d\t%.3f\t%d\t", t.trackNo, t.discNo, t.year,
                      t.sampleRate, t.bits, t.channels, t.duration, t.hasCover);
        s += buf;
        s += lib_clean_field(t.genre);
        s += '\n';
    }
    return s;
}
// 锁外落盘（调用方持锁时构造好的快照）。writeFile 自己走 tmp+rename，原子性由它保证。
inline void Library::writeIndex(const std::string& snapshot) {
    writeFile(indexPath(), snapshot);
}

inline const std::vector<LibAlbum>& Library::albumVecLocked() const {
    if (!albumsDirty_) return albums_;
    albums_.clear();
    // 2026-10-25 修「扫描时整个服务卡死 / Failed to fetch / 几分钟才出声 / 切标签数据消失」的根因：
    //   旧实现把「碟号推断」放在 std::sort 的比较器里（每个比较都比两次目录扫描），
    //   比较器被调用 O(n log n) 次，而 albumVecLocked 全程持着 mtx_。
    //   entity_find_album_dir_for_track → entity_dir_is_album → entity_scan_dir →
    //   fs::directory_iterator（整目录扫描），于是 12000 首 / 1000 张专辑（disc=0 的绝大多数 FLAC）
    //   冷 albums() 实测 555 ms；HTTP 服务是单线程（webui.h），这期间所有请求排队
    //   → 前端 fetch 超时（Failed to fetch）、播放请求排在后面（几分钟才出声）、切标签取数失败。
    //   修法：① 按「父目录」缓存目录推断结果，同一张专辑的 12 首只扫一次目录；
    //        ② 排序前把每首曲目的 discForSort 一次性算好，比较器只读这个 vector，零文件系统调用。
    //   （entity_find_album_dir_for_track 的输入只有 trackPath.parent_path()，所以按父目录缓存是等价的。）
    std::map<std::string, std::pair<std::string, int>> dirCache;   // 父目录 -> {专辑目录, 推断碟号}
    std::vector<int> discForSort(tracks_.size(), 0);              // 排序用碟号（比较器只读）
    auto albumDirFor = [&dirCache](const std::string& trackPath) -> const std::pair<std::string, int>& {
        const std::string parent = u8s(p8(trackPath).parent_path().u8string());
        auto it = dirCache.find(parent);
        if (it == dirCache.end()) {
            int inferred = 0;
            const auto albDir = rta::meta::entity_find_album_dir_for_track(p8(trackPath), &inferred);
            const std::string albStr = albDir.empty() ? std::string() : u8s(albDir.u8string());
            it = dirCache.emplace(parent, std::make_pair(albStr, inferred)).first;
        }
        return it->second;
    };
    std::map<std::string, size_t> byKey;
    for (size_t i = 0; i < tracks_.size(); ++i) {
        const auto& t = tracks_[i];
        std::string aName = t.album;
        std::string aArtist = t.albumArtist.empty() ? t.artist : t.albumArtist;
        int discForSortVal = t.discNo;
        if (aName.empty() || discForSortVal == 0) {
            const auto& ad = albumDirFor(t.path);
            if (!ad.first.empty()) {
                if (aName.empty()) {
                    std::string a, c;
                    const std::string dirName = u8s(p8(ad.first).filename().u8string());
                    rta::meta::entity_parse_album_circle(dirName, a, c);
                    aName = a.empty() ? dirName : a;
                }
                if (discForSortVal == 0 && ad.second > 0) discForSortVal = ad.second;
            } else if (aName.empty()) {
                std::string dn = u8s(p8(t.path).parent_path().filename().u8string());
                aName = dn.empty() ? "未知专辑" : dn;
            }
        }
        discForSort[i] = discForSortVal;
        const std::string rawKey = aArtist + "\x1f" + aName;
        auto it = byKey.find(rawKey);
        if (it == byKey.end()) {
            LibAlbum a; a.key = fnv_hex(rawKey); a.name = aName; a.artist = aArtist; a.year = t.year;
            byKey[rawKey] = albums_.size();
            albums_.push_back(a);
            it = byKey.find(rawKey);
        }
        LibAlbum& a = albums_[it->second];
        a.idx.push_back(i);
        a.nTracks = (int)a.idx.size();
        a.duration += t.duration;
        if (t.hasCover) a.hasCover = true;
        if (a.year == 0) a.year = t.year;
    }
    // 比较器只读 discForSort / tracks_，【绝不允许】在这里出现任何文件系统调用（见上面的根因说明）
    for (auto& a : albums_) {
        std::sort(a.idx.begin(), a.idx.end(), [&](size_t x, size_t y) {
            const auto& p = tracks_[x]; const auto& q = tracks_[y];
            const int pDisc = discForSort[x], qDisc = discForSort[y];
            if (pDisc != qDisc) return pDisc < qDisc;
            if (p.trackNo != q.trackNo) return p.trackNo < q.trackNo;
            return p.path < q.path;
        });
    }
    std::sort(albums_.begin(), albums_.end(), [](const LibAlbum& a, const LibAlbum& b) {
        const std::string x = a.artist + "\x1f" + a.name, y = b.artist + "\x1f" + b.name;
        return x < y;
    });
    albumsDirty_ = false;
    return albums_;
}

inline std::vector<size_t> Library::search(const std::string& q, size_t limit) const {
    std::vector<size_t> hits;
    std::string needle = q;
    for (auto& c : needle) c = (char)std::tolower((unsigned char)c);
    std::lock_guard<std::mutex> lk(mtx_);
    for (size_t i = 0; i < tracks_.size() && hits.size() < limit; ++i) {
        if (needle.empty()) { hits.push_back(i); continue; }
        std::string hay = tracks_[i].title + " " + tracks_[i].artist + " " + tracks_[i].album + " " + tracks_[i].albumArtist;
        for (auto& c : hay) c = (char)std::tolower((unsigned char)c);
        if (hay.find(needle) != std::string::npos) hits.push_back(i);
    }
    return hits;
}

inline bool Library::albumCover(const std::string& key, std::vector<unsigned char>& bytes, std::string& mime) {
    std::string firstPath;
    {
        std::lock_guard<std::mutex> lk(mtx_);
        auto it = coverCache_.find(key);
        if (it != coverCache_.end()) {
            if (it->second.first.empty()) return false;
            bytes = it->second.first; mime = it->second.second; return true;
        }
        const auto& v = albumVecLocked();
        for (auto& a : v) if (a.key == key && !a.idx.empty()) { firstPath = tracks_[a.idx[0]].path; break; }
    }
    if (firstPath.empty()) return false;
    std::vector<unsigned char> b = rta::audio::get_cover(firstPath, mime);
    {
        std::lock_guard<std::mutex> lk(mtx_);
        if (coverCache_.size() > 256) coverCache_.clear();
        coverCache_[key] = { b, mime };
    }
    bytes.swap(b);
    return !bytes.empty();
}

inline void Library::joinScan() {
    if (th_.joinable()) th_.join();
}

inline void Library::startScan(bool forceFull) {
    if (scanning_.load()) return;
    joinScan();
    const auto roots = this->roots();
    // 旧索引（增量基准）
    std::vector<LibTrack> old = [&] { std::lock_guard<std::mutex> lk(mtx_); return tracks_; }();

    cancel_.store(false);
    scanning_.store(true);
    scanned_.store(0);
    total_.store(0);
    { std::lock_guard<std::mutex> lk(mtx_); scanMsg_ = "正在遍历目录…"; }

    const size_t thCount = this->scanThreads();

    th_ = std::thread([this, roots, old, forceFull, thCount]() {
        const auto tStart = std::chrono::steady_clock::now();

        // 老记录按路径建索引，便于复用
        std::unordered_map<std::string, size_t> oldByPath;
        oldByPath.reserve(old.size() * 2);
        for (size_t i = 0; i < old.size(); ++i) oldByPath[old[i].path] = i;

        std::vector<LibTrack> fresh;
        std::vector<std::string> walked;
        std::error_code ec;
        for (const auto& root : roots) {
            if (cancel_.load()) break;
            if (!fsx::is_directory(root, ec)) continue;
            for (auto it = fsx::recursive_directory_iterator(
                     root, fsx::directory_options::skip_permission_denied, ec);
                 it != fsx::recursive_directory_iterator(); ) {
                if (cancel_.load()) break;
                if (ec) { it.increment(ec); continue; }
                const auto& ep = it->path();
                std::string name = u8s(ep.filename().u8string());
                if (!name.empty() && name[0] == '.') { it.disable_recursion_pending(); it.increment(ec); continue; }
                if (it->is_directory(ec)) { it.increment(ec); continue; }
                if (lib_is_audio(ep)) {
                    walked.push_back(u8s(ep.u8string()));
                    total_.store((int)walked.size());
                }
                it.increment(ec);
            }
        }
        if (cancel_.load()) { scanning_.store(false); return; }

        const int n = (int)walked.size();
        total_.store(n);
        if (n == 0) {
            const auto tEnd = std::chrono::steady_clock::now();
            const double durMs = std::chrono::duration<double, std::milli>(tEnd - tStart).count();
            std::string snap;
            {
                std::lock_guard<std::mutex> lk(mtx_);
                tracks_.clear();
                albumsDirty_ = true;
                lastScanMs_ = durMs;
                lastScanProbed_ = 0;
                lastScanCached_ = 0;
                scanMsg_ = "完成：0 首";
                snap = buildIndexLocked();   // 锁内只构造快照（见 buildIndexLocked 注释）
            }
            writeIndex(snap);                // 锁外写盘
            scanning_.store(false);
            return;
        }

        fresh.resize((size_t)n);
        std::atomic<int> completed{0};
        std::atomic<int> probedCount{0};
        std::atomic<int> cachedCount{0};

        const std::string ffprobe = rta::audio::find_tool("ffprobe");

        auto pool = std::make_shared<ScanPool>(thCount);
        {
            std::lock_guard<std::mutex> lk(mtx_);
            activePool_ = pool;
        }

        for (int i = 0; i < n; ++i) {
            if (cancel_.load()) break;
            const bool submitted = pool->submit([this, i, n, &walked, &oldByPath, &old, forceFull, &ffprobe,
                                                 &fresh, &completed, &probedCount, &cachedCount]() {
                if (cancel_.load()) return;
                const std::string& p = walked[(size_t)i];
                long long mt = 0, sz = 0;
                {
                    std::error_code e2;
                    auto wp = p8(p);
                    auto ft = fsx::last_write_time(wp, e2);
                    if (!e2) mt = (long long)ft.time_since_epoch().count();
                    auto s = fsx::file_size(wp, e2);
                    if (!e2) sz = (long long)s;
                }
                auto oit = oldByPath.find(p);
                if (!forceFull && oit != oldByPath.end()) {
                    const LibTrack& o = old[oit->second];
                    if (o.mtime == mt && o.size == sz) {
                        fresh[(size_t)i] = o;
                        cachedCount.fetch_add(1, std::memory_order_relaxed);
                        const int c = completed.fetch_add(1, std::memory_order_relaxed) + 1;
                        scanned_.store(c);
                        return;
                    }
                }
                LibTrack t = lib_probe_one(p, ffprobe);
                t.mtime = mt;
                t.size = sz;
                if (t.title.empty()) {
                    std::string sn = u8s(p8(p).stem().u8string());
                    t.title = sn.empty() ? p : sn;
                }
                fresh[(size_t)i] = std::move(t);
                probedCount.fetch_add(1, std::memory_order_relaxed);
                const int c = completed.fetch_add(1, std::memory_order_relaxed) + 1;
                scanned_.store(c);
                if (c % 8 == 0 || c == n) {
                    std::lock_guard<std::mutex> lk(mtx_);
                    scanMsg_ = "读取标签 " + std::to_string(c) + "/" + std::to_string(n);
                }
            });
            if (!submitted) break;
        }

        pool->wait(false);

        {
            std::lock_guard<std::mutex> lk(mtx_);
            activePool_.reset();
        }

        if (cancel_.load()) {
            scanning_.store(false);
            return;
        }

        const auto tEnd = std::chrono::steady_clock::now();
        const double durMs = std::chrono::duration<double, std::milli>(tEnd - tStart).count();

        std::string snap;
        {
            std::lock_guard<std::mutex> lk(mtx_);
            tracks_.swap(fresh);
            albumsDirty_ = true;
            lastScanMs_ = durMs;
            lastScanProbed_ = probedCount.load();
            lastScanCached_ = cachedCount.load();
            const size_t nt = tracks_.size();
            scanMsg_ = "完成：" + std::to_string(nt) + " 首 (" + std::to_string((int)(durMs + 0.5)) + " ms)";
            // 锁内只构造快照：tracks_ 已 swap 完，这份字符串就是那一刻的完整索引，
            // 出锁后再写盘不会破坏原子性（writeFile 内部 tmp + rename 是原子的）。
            snap = buildIndexLocked();
        }
        writeIndex(snap);   // 锁外写盘：整份索引落盘期间不再阻塞任何查询
        scanning_.store(false);
    });
}

// 真实批量入口：从音乐库 LibTrack 扫描结果构建实体图
inline rta::meta::EntityGraph entity_graph_from_library_tracks(
    const std::vector<LibTrack>& tracks, long long ts = 0) {
    std::vector<rta::meta::MetaSeed> seeds;
    seeds.reserve(tracks.size());
    for (const auto& t : tracks) {
        std::map<std::string, std::string> tags;
        if (!t.title.empty()) tags["title"] = t.title;
        if (!t.artist.empty()) tags["artist"] = t.artist;
        if (!t.album.empty()) tags["album"] = t.album;
        if (!t.albumArtist.empty()) tags["albumArtist"] = t.albumArtist;
        if (!t.genre.empty()) tags["genre"] = t.genre;
        if (t.year > 0) tags["year"] = std::to_string(t.year);
        if (t.discNo > 0) {
            tags["disc"] = std::to_string(t.discNo);
            tags["discNo"] = std::to_string(t.discNo);
        }
        if (t.trackNo > 0) tags["track"] = std::to_string(t.trackNo);
        seeds.push_back(rta::meta::entity_seed_from_track_path(t.path, tags));
    }
    return rta::meta::entity_batch_build_graph(seeds, ts);
}

inline rta::meta::EntityGraph entity_graph_from_library(const Library& lib, long long ts = 0) {
    std::vector<LibTrack> trs;
    const size_t n = lib.trackCount();
    trs.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        LibTrack t;
        if (lib.trackAt(i, t)) trs.push_back(std::move(t));
    }
    return entity_graph_from_library_tracks(trs, ts);
}

} // namespace rta::net
