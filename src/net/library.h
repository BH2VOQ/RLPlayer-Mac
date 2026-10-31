// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// library.h — 本地音乐库（索引 / 专辑 / 搜索 / 封面）
//
// 索引按「艺术家 / 专辑 / 曲目」组织并提供全局搜索，避免逐层翻找目录。
// 只依赖 ffprobe 读标签，不引入数据库。
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
#include "platform/fs.h"        // 容错目录枚举 list_dir（1.1.1.4：SMB 失效项不再中止遍历）
#include "meta/entities.h"
#include "meta/cue.h"          // CUE 整轨分轨解析
#include <cmath>
#include "meta/tags_native.h"   // 原生标签快速通道（FLAC/WAV/MP3/OGG；lib_probe_one 的原生分支）
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <map>
#include <unordered_map>
#include <mutex>
#include <condition_variable>   // 封面 ffmpeg 全局并发闸门（1.1.1.4-beta「封面提取卡 UI」）
#include <chrono>               // 同上：闸门等待与专辑取图总预算
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
// 严格 UTF-8 校验（与 rtaweb 的 valid_utf8 同一判据）
inline bool lib_valid_utf8(const std::string& s) {
    const unsigned char* p = (const unsigned char*)s.data();
    const size_t n = s.size();
    size_t i = 0;
    while (i < n) {
        const unsigned char c = p[i];
        int cont; uint32_t cp;
        if (c < 0x80) { ++i; continue; }
        else if (c >= 0xC2 && c <= 0xDF) { cont = 1; cp = c & 0x1Fu; }
        else if (c >= 0xE0 && c <= 0xEF) { cont = 2; cp = c & 0x0Fu; }
        else if (c >= 0xF0 && c <= 0xF4) { cont = 3; cp = c & 0x07u; }
        else return false;
        if (i + (size_t)cont >= n) return false;
        for (int k = 1; k <= cont; ++k) {
            const unsigned char cc = p[i + (size_t)k];
            if ((cc & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (uint32_t)(cc & 0x3Fu);
        }
        if ((cont == 1 && cp < 0x80) || (cont == 2 && cp < 0x800) || (cont == 3 && cp < 0x10000)) return false;
        if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        i += (size_t)cont + 1;
    }
    return true;
}

// 路径 a 是否在目录 b 之下（大小写不敏感，且要求分隔符对齐）
inline bool lib_path_under(const std::string& a, const std::string& b) {
    if (b.empty() || a.size() < b.size()) return false;
    for (size_t i = 0; i < b.size(); ++i) {
        char x = a[i], y = b[i];
        if (x == '/') x = '\\';
        if (y == '/') y = '\\';
        if (x >= 'A' && x <= 'Z') x = (char)(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = (char)(y - 'A' + 'a');
        if (x != y) return false;
    }
    if (a.size() == b.size()) return true;
    return a[b.size()] == '\\' || a[b.size()] == '/';
}

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

    // ---- CUE 整轨分轨（2026-10-25 第二里程碑）----
    // 一张 .cue 把「一个整轨音频文件」切成 N 首：path 仍然是物理音频路径
    std::string cuePath;      // 所属 .cue 的绝对路径（UTF-8）；空 = 普通（非 cue）曲目
    int         cueNo  = 0;
    long long   cueOff = 0;
    long long   cueLen = 0;
    bool isCueTrack() const { return !cuePath.empty(); }
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

// 封面在线抓取（2026-10-26，上游 c41ce97 的同构能力）：「专辑键 → 专辑名 + 艺术家 + 拼好的搜索词」。
// 为什么需要反查：抓取线程只拿到 key，而网易云的专辑搜索接口吃的是**文字**（s=专辑名 艺术家）；
// 而专辑名/艺术家在库里有两种来源（真实标签 / 目录回填，见 albumVecLocked 的 aName 推导），
// 只有 Library 自己知道最终拼出来的那个值 —— 由本模块给，调用方不要自己再猜一遍。
// 否则抓取侧回头翻 tracks_ 拼搜索词，就会与 UI 上显示的那张专辑不一致
// （缺标签的专辑在 UI 上叫目录名，tracks_ 里却是空串）。
struct LibCoverTerm {
    std::string key;      // 专辑键（与 /api/lib/cover?k= 同一个）
    std::string name;     // 专辑名（可能来自目录回填）
    std::string artist;   // 专辑艺术家（albumArtist 优先，退回 artist；可能为空）
    std::string term;     // 已拼好的搜索词："名 艺术家"，艺术家为空时只有名
};

// addRoot 的完整结果：ok=false 时 why 是人话原因（HTTP 层原样回给 UI，别只说"目录不存在"）
struct addRootResult { bool ok = false; std::string why; };

// 清理结果（/api/lib/prune 与 /api/lib/remove 共用）
struct LibCleanResult { int removed = 0; size_t tracks = 0; };

// 前置声明：类内联实现（addRoot 等）要用（定义在下方"内部工具"一节）
inline bool lib_valid_utf8(const std::string& s);
inline bool lib_path_under(const std::string& a, const std::string& b);
inline bool lib_file_exists(const std::string& p);


class Library {
public:
    static Library& instance() { static Library L; return L; }

    // ---- 配置 ----
    std::vector<std::string> roots() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return roots_;
    }
    // 加根：必须先过 UTF-8 校验、绝对路径校验与合法目录检查
    addRootResult addRootEx(const std::string& dir) {
        if (dir.empty()) return { false, "目录为空" };
        if (!lib_valid_utf8(dir)) return { false, "路径编码非 UTF-8" };
        // 2026-10-26 BUG（用户截图：点侧栏「文件夹」显示「目录不存在」）的根因 (b)：
        //   这里原来只查 is_directory，不要求绝对路径 ⟹ "./data" 被原样存进 conf。
        //   LibTrack::path 的契约本来就是「绝对路径」；相对根存进 conf 后**含义随进程 cwd
        //   漂移**（.app 双击启动 cwd=/ ⟹ ./data 解析成 /data；开发时 cwd=项目根 ⟹ 指向
        //   真实目录），同一个 conf 在不同启动方式下指向不同地方，扫描/文件浏览必然对不上
        //   —— 这正是本 BUG。
        // ★ 刻意**不**用 fsx::absolute() 自动转换：静默改写用户输入会让「我填的路径」与
        //   「实际存进 conf 的路径」不一致，且测试会掩盖问题（看着加进去了，存的是别的）。
        //   拒绝 + 说明原因更诚实。调用方（rtaweb 的 --music-dir）负责先做绝对化。
        if (!fsx::path(p8(dir)).is_absolute()) return { false, "库根必须是绝对路径: " + dir };
        std::error_code ec;
        bool ok = false;
        try {
            ok = fsx::is_directory(p8(dir), ec);
        } catch (const std::exception& e) {
            return { false, std::string("路径无法解析: ") + e.what() };
        }
        if (!ok) return { false, "目录不存在: " + dir };
        std::lock_guard<std::mutex> lk(mtx_);
        for (auto& r : roots_) if (r == dir) return { true, "" };
        roots_.push_back(dir);
        saveRootsLocked();
        return { true, "" };
    }
    bool addRoot(const std::string& dir) { return addRootEx(dir).ok; }
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
    // 2026-10-25（261025-01 一.1/8）：/api/lib/status 在扫描期间要 <50ms 返回，所以这里
    // **一律不碰 mtx_** —— 扫描线程会在收尾时长时间持有 mtx_（整理索引/落盘），旧实现的
    // status/trackCount 都排在它后面。改为：进度文本走 msgMtx_（只做一次字符串赋值），
    // 计数/耗时走原子量（snapshot 无锁），专辑数用上次整理好的缓存值。
    bool scanning() const { return scanning_.load(); }
    int  scanned()  const { return scanned_.load(); }
    int  scanTotal() const { return total_.load(); }
    std::string scanMsg() const { std::lock_guard<std::mutex> lk(msgMtx_); return scanMsg_; }
    size_t trackCount() const { return trackCount_.load(); }
    // 费用高（会触发专辑整理）；交互热路径请用 albumCountFast()
    size_t albumCount() const { std::lock_guard<std::mutex> lk(mtx_); return albumVecLocked().size(); }
    size_t albumCountFast() const { return albumCount_.load(); }
    int lastScanRemoved() const { return removedMissing_.load(); }

    // status 快照（无锁／最多一次短锁读 msg）：/api/lib/status 与 /api/lib/stats 共用
    struct Snapshot {
        bool   scanning = false;
        int    scanned = 0, total = 0;
        size_t tracks = 0, albums = 0;
        double lastScanMs = 0.0;
        int    probed = 0, cached = 0, removed = 0;
        // 1.1.1.4：这次遍历里失效的目录项数、读不全的目录数，以及索引是否"完整"。
        // complete=false 表示索引可用但可能缺行（SMB 失效项/目录权限），前端/用户据此判断要不要复核。
        size_t skipped = 0;
        size_t failedDirs = 0;
        bool   complete = true;
        std::string msg;
    };
    Snapshot snapshot() const {
        Snapshot s;
        s.scanning = scanning_.load();
        s.scanned  = scanned_.load();
        s.total    = total_.load();
        s.tracks   = trackCount_.load();
        s.albums   = albumCountFast();
        s.lastScanMs = lastScanMs_.load();
        s.probed   = lastScanProbed_.load();
        s.cached   = lastScanCached_.load();
        s.removed  = removedMissing_.load();
        s.skipped  = scanSkipped_.load();
        s.failedDirs = scanFailedDirs_.load();
        s.complete = scanComplete_.load();
        s.msg      = scanMsg();
        return s;
    }

    void setScanThreads(size_t n) { scanThreads_.store(n); }
    size_t scanThreads() const {
        const size_t n = scanThreads_.load();
        return n > 0 ? n : defaultScanThreads();
    }
    static size_t defaultScanThreads() {
        unsigned int h = std::thread::hardware_concurrency();
        return std::min(std::max(1u, h), 8u);
    }
    double lastScanMs() const { return lastScanMs_.load(); }
    int lastScanProbed() const { return lastScanProbed_.load(); }
    int lastScanCached() const { return lastScanCached_.load(); }

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

    // ---- 封面在线抓取用的「按 album+artist 反查」（2026-10-26）----
    // ① 全库快照：所有「内嵌流与同目录封面文件都没有」的专辑（hasCover 在扫描时已算好：
    //    内嵌 video 流 **或** 同目录 cover/folder/front 任一存在 ⟹ hasCover=1）。
    //    文件系统 IO 由调用方做（磁盘正/负缓存留在 rtaweb），本模块只回答「库里有没有图」。
    std::vector<LibCoverTerm> albumsWithoutCover() const;
    // ② 单张反查：按 key 取回专辑名/艺术家/搜索词。key 不在库里返回 false。
    bool albumCoverTerm(const std::string& key, LibCoverTerm& out) const;

    // ---- 扫描 ----
    void load();            // 读配置与索引
    // 返回值（1.1.1.4）：已有一轮扫描在跑时返回 false（调用方据此告诉前端"已在进行中"，
    // 而不是假装又启动了一次）；成功起了后台线程返回 true。
    bool startScan(bool forceFull = false);
    // 索引文件多久没更新过（秒）。文件不存在/读不到返回 1e9 ⟹ 立刻值得扫。
    // 1.1.1.4 启动增量扫描的判据（索引非空但过期太久时后台补一次）。
    double indexAgeSeconds() const;
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

    // ---- 删除 / 清理（261025-01 一.3：以前只能"按原路径重扫"，删掉的文件永远留在索引里）----
    // 剔除「文件已不存在」的记录并落盘；返回删掉的条数。扫描开始前会自动跑一次。
    LibCleanResult pruneMissing();
    // 剔除 dir 之下（含子目录）的全部记录并落盘；用于 /api/lib/remove?path=<目录>
    LibCleanResult removeUnder(const std::string& dir);
    // 剔除单个文件记录（精确路径，大小写不敏感）
    bool removePath(const std::string& path);

    // 退出兜底（mac .app 实测崩溃 2026-10-25：库空时启动自动扫描，进程退出时 th_ 仍
    // joinable，std::thread 析构 ⟹ std::terminate ⟹ SIGABRT 弹系统崩溃报告）。
    // stopScan 已有（cancel_ + pool cancel），joinScan 收线程；幂等，正常路径零影响。
    ~Library() {
        try { stopScan(); joinScan(); } catch (...) {}
    }

private:
    Library() = default;

    void saveRootsLocked();
    void saveIndexLocked();
    std::string indexTextLocked() const;          // 持锁只做内存序列化（写盘放到锁外）
    LibCleanResult pruneMissingLocked();          // 扫描线程内部用：调用方已持锁
    void applyCleanLocked(std::vector<LibTrack>&& kept, int removed);
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
    mutable std::mutex msgMtx_;        // 只保护 scanMsg_（与 mtx_ 分离：status 不再排在索引工作后面）
    std::string scanMsg_;

    std::atomic<size_t> scanThreads_{0};
    std::atomic<double> lastScanMs_{0.0};
    std::atomic<int> lastScanProbed_{0};
    std::atomic<int> lastScanCached_{0};
    std::atomic<int> removedMissing_{0};
    // 1.1.1.4：本轮遍历的失效项计数 / 读不全的目录数 / 索引是否完整
    std::atomic<size_t> scanSkipped_{0};
    std::atomic<size_t> scanFailedDirs_{0};
    std::atomic<bool>   scanComplete_{true};
    std::atomic<size_t> trackCount_{0};
    mutable std::atomic<size_t> albumCount_{0};   // albumVecLocked() 是 const
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

inline bool lib_file_exists(const std::string& p) {
    std::error_code ec;
    try { return fsx::exists(p8(p), ec); } catch (const std::exception&) { return false; }
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

// ---------------------------------------------------------------------------
// CUE 整轨分轨 —— library 侧（2026-10-25 第二里程碑）
// ---------------------------------------------------------------------------

// 路径比较键：大小写不敏感 + '/' 统一成 '\' + 去掉尾分隔符。
inline std::string lib_path_key(const std::string& p) {
    std::string k = p;
    for (auto& c : k) {
        if (c == '/') c = '\\';
        else if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    }
    while (!k.empty() && k.back() == '\\') k.pop_back();
    return k;
}

// .cue 扩展名识别（大小写不敏感）
inline bool lib_is_cue(const fsx::path& p) {
    std::string ext = u8s(p.extension().u8string());
    for (auto& c : ext) c = (char)std::tolower((unsigned char)c);
    return ext == ".cue";
}

// ---------------------------------------------------------------------------
// 容错目录遍历（2026-10-31，1.1.1.4 索引停滞）
// ---------------------------------------------------------------------------
// 为什么不能用 recursive_directory_iterator：SMB 上只要有一个目录项 lstat 失败
// （实测 /Volumes/Music/KOKIA/翼を広けて (EP)，err=2 ENOENT），increment 就置 ec
// 并把迭代器变成 end —— 外层 for 直接正常退出，整次遍历被静默截断，
// 而扫描仍以"完成"写盘（索引 4.4k 行 vs 实际 6.0k 首）。
//
// 这里的契约：
//   * 失效目录项（lstat 失败）只计入 skipped，遍历继续
//   * 目录打不开计入 failedDirs（调用方据此保留其下旧记录），遍历继续
//   * 隐藏项（name[0]=='.'）跳过，与旧逻辑一致
//   * 目录 symlink 不递归；文件 symlink 按文件名扩展名照旧当音频/cue 收录
//   * 非 UTF-8 名称计入 skipped（索引只存 UTF-8）
//   * onProgress：每 128 个目录项 + 每个目录结束时各调一次（限频由调用方做）
struct LibWalkResult {
    size_t skipped = 0;                  // 失效目录项（ENOENT 等）
    std::vector<std::string> failedDirs; // opendir 失败的目录
    bool cancelled = false;
};

inline LibWalkResult lib_walk_tree(const std::string& root,
                                   const std::function<void(const std::string&)>& onFile,
                                   const std::function<void(const std::string&)>& onCue,
                                   const std::function<void()>& onProgress,
                                   const std::function<bool()>& cancelled) {
    LibWalkResult r;
    std::vector<std::string> stack;      // 显式栈做深度优先，避免递归爆栈
    stack.push_back(root);
    size_t seen = 0;
    std::vector<rta::platform::DirEntry> ents;
    while (!stack.empty()) {
        if (cancelled && cancelled()) { r.cancelled = true; return r; }
        const std::string dir = stack.back();
        stack.pop_back();
        size_t badItems = 0;
        ents.clear();
        if (!rta::platform::list_dir(dir, ents, badItems)) {
            r.failedDirs.push_back(dir);       // 打不开：记下来，但不中止
        } else {
            r.skipped += badItems;
            const bool needSep = !dir.empty() && dir.back() != '/';
            for (const auto& e : ents) {
                if (cancelled && cancelled()) { r.cancelled = true; return r; }
                if (!e.name.empty() && e.name[0] == '.') continue;   // 隐藏项（旧逻辑一致）
                std::string full = dir;
                if (needSep) full += '/';
                full += e.name;
                if (!lib_valid_utf8(full)) { ++r.skipped; continue; }
                if ((++seen & 0x7F) == 0) {
                    if (onProgress) onProgress();
                    std::this_thread::yield();   // 大库遍历别把 UI/播放线程拖死（旧遍历每 64 项让出）
                }
                if (e.is_dir) { stack.push_back(std::move(full)); continue; }
                // 到这里是普通文件或符号链接：is_dir 已排除符号链接指向的目录（不递归）
                const fsx::path p = p8(full);
                if (lib_is_audio(p)) { if (onFile) onFile(full); }
                else if (lib_is_cue(p)) { if (onCue) onCue(full); }
            }
        }
        if (onProgress) onProgress();      // 每个目录结束汇报一次
    }
    return r;
}

// cue 的 FILE 指向的音频此刻是否真的在磁盘上
inline bool lib_cue_audio_exists(const std::string& p) {
    if (p.empty() || !lib_valid_utf8(p)) return false;
    std::error_code ec;
    try {
        const fsx::path wp = p8(p);
        if (!fsx::is_regular_file(wp, ec)) return false;
        return lib_is_audio(wp);
    } catch (const std::exception&) { return false; }
}

// 纯函数：一份已解析的 cue + 物理文件探测表 → N 条虚拟曲目。
inline std::vector<LibTrack> lib_cue_expand(const rta::meta::CueSheet& sh,
                                            const std::map<std::string, LibTrack>& probes) {
    std::vector<LibTrack> out;
    if (sh.tracks.empty() || probes.empty()) return out;

    std::map<std::string, const LibTrack*> probeByKey;
    for (const auto& kv : probes) probeByKey[lib_path_key(kv.first)] = &kv.second;

    std::vector<std::string> fileOrder;
    std::map<std::string, std::vector<const rta::meta::CueTrack*>> byFile;
    for (const auto& ct : sh.tracks) {
        if (!ct.audio || ct.index1 < 0) continue;          // 数据轨 / 没有 INDEX 的轨不产生曲目
        const std::string k = lib_path_key(ct.file);
        if (byFile.find(k) == byFile.end()) fileOrder.push_back(k);
        byFile[k].push_back(&ct);
    }

    std::string albArtist = sh.performer;
    if (albArtist.empty()) {
        for (const auto& ct : sh.tracks)
            if (ct.audio && !ct.performer.empty()) { albArtist = ct.performer; break; }
    }
    const int year = atoi(sh.date.c_str());

    for (const auto& fk : fileOrder) {
        auto pit = probeByKey.find(fk);
        if (pit == probeByKey.end()) continue;             // 该文件不存在/没探测到 → 跳过（降级）
        const LibTrack& probe = *pit->second;
        std::vector<const rta::meta::CueTrack*> trs = byFile[fk];
        std::stable_sort(trs.begin(), trs.end(),
                         [](const rta::meta::CueTrack* a, const rta::meta::CueTrack* b) {
                             return a->index1 < b->index1;
                         });
        const int sr = probe.sampleRate;
        for (size_t i = 0; i < trs.size(); ++i) {
            const rta::meta::CueTrack& ct = *trs[i];
            LibTrack t = probe;                            // 采样率/位深/声道/封面/mtime/size 透传
            t.path = probe.path.empty() ? ct.file : probe.path;   // 用磁盘真名，不用 cue 里的拼写
            t.title = ct.title;
            if (t.title.empty()) t.title = ct.performer;
            if (t.title.empty()) {
                std::string stem = u8s(p8(ct.file).stem().u8string());
                if (stem.empty()) stem = ct.file;
                char b[32];
                std::snprintf(b, sizeof(b), " #%02d", ct.number);
                t.title = stem + b;
            }
            t.artist      = ct.performer.empty() ? albArtist : ct.performer;
            t.album       = sh.albumTitle.empty() ? ct.albumTitle : sh.albumTitle;
            t.albumArtist = albArtist;
            t.genre       = sh.genre;
            t.year        = year;
            t.trackNo     = (int)out.size() + 1;           // 专辑内连续 1..N
            t.discNo      = 0;
            t.cuePath     = sh.cuePath;
            t.cueNo       = ct.number;
            t.cueOff      = rta::meta::cue_frames_to_samples(ct.index1, sr);
            long long lenSamples = -1;
            if (t.cueOff >= 0) {
                long long endSamples = -1;
                if (i + 1 < trs.size())
                    endSamples = rta::meta::cue_frames_to_samples(trs[i + 1]->index1, sr);
                else if (probe.duration > 0.0)
                    endSamples = (long long)std::llround(probe.duration * (double)sr);
                if (endSamples >= t.cueOff) lenSamples = endSamples - t.cueOff;
            }
            t.cueLen = lenSamples;
            if (t.cueLen >= 0 && sr > 0) t.duration = (double)t.cueLen / (double)sr;
            else if (i + 1 < trs.size())  t.duration = rta::meta::cue_frames_to_sec(trs[i + 1]->index1 - ct.index1);
            else if (probe.duration > 0.0) {
                t.duration = probe.duration - (double)ct.index1 / 75.0;
                if (t.duration < 0.0) t.duration = 0.0;
            } else t.duration = 0.0;
            out.push_back(std::move(t));
        }
    }
    return out;
}

// 虚拟曲目在整轨里的播放区间（秒）。
inline bool lib_cue_range_sec(const LibTrack& t, double& startSec, double& endSec) {
    startSec = 0.0;
    endSec   = 0.0;
    if (!t.isCueTrack() || t.cueOff < 0 || t.cueLen <= 0 || t.sampleRate <= 0) return false;
    startSec = (double)t.cueOff / (double)t.sampleRate;
    endSec   = (double)(t.cueOff + t.cueLen) / (double)t.sampleRate;
    return endSec > startSec;
}


// 判据给一首曲目推出的专辑名与碟号（只依赖父目录，故同一目录的结果必然相同）
struct LibDirAlbum {
    std::string album;      // 已拆过「专辑 @ 社团」的专辑名（与 albumVecLocked 的 aName 同源同算法）
    int  disc = 0;          // 目录推断的碟号（0 = 没推断出来）
    bool fromDir = false;   // true = 命中真实专辑目录；false = 只有父目录名兜底（判据没命中）
};

inline LibDirAlbum lib_dir_album_for(const std::string& trackPath) {
    LibDirAlbum r;
    int inferredDisc = 0;
    const fsx::path albDir = rta::meta::entity_find_album_dir_for_track(p8(trackPath), &inferredDisc);
    if (!albDir.empty()) {
        const std::string dn = u8s(albDir.filename().u8string());
        std::string a, c;
        rta::meta::entity_parse_album_circle(dn, a, c);
        r.album   = a.empty() ? dn : a;
        r.disc    = inferredDisc > 0 ? inferredDisc : 0;
        r.fromDir = true;
        return r;
    }
    const std::string dn = u8s(p8(trackPath).parent_path().filename().u8string());
    r.album = dn.empty() ? std::string("未知专辑") : dn;
    return r;
}

// 按父目录 memo 推断结果：并行扫描时同一目录会被多个线程问到，目录扫描（stat）不必重复做。
// 键 = 父目录绝对路径（判据只依赖它），不是曲目路径。
struct LibDirAlbumMemo {
    std::mutex mtx;
    std::unordered_map<std::string, LibDirAlbum> m;
    LibDirAlbum get(const std::string& parentDir, const std::string& trackPath) {
        { std::lock_guard<std::mutex> lk(mtx); auto it = m.find(parentDir); if (it != m.end()) return it->second; }
        LibDirAlbum r = lib_dir_album_for(trackPath);
        std::lock_guard<std::mutex> lk(mtx);
        if (m.size() < 65536) m.emplace(parentDir, r);
        return r;
    }
};

// 一次 ffprobe 取全部信息（比 media_info.h 的两次调用快一倍）
inline LibTrack lib_probe_one(const std::string& file, const std::string& ffprobePath = "") {
    LibTrack t;
    t.path = file;
    // ===================== 原生标签快速通道（调度层，2026-10-25） =====================
    // 261025-01 一.1/一.8：首次全量扫描 45.9 首/s（3000 首 65.4 s），瓶颈是**每个文件起一次 ffprobe 进程**。
    // src/meta/tags_native.h 就地解析 FLAC/WAV/MP3/OGG 的头部与标签块，语义与下面 ffprobe 分支逐字段对齐
    // （见该文件顶部的实测依据：LAME delay/padding、WAV data 截断、OGG 末页 granulepos、bits 的 N/A 口径…）。
    //
    // 保底原则：原生通道**只在结构完全说得通时**返回 true；任何解析失败/不支持的变体（ID3v2.2、
    // unsynchronisation、数字流派引用、Opus、RF64、"id3 " 块…）一律返回 false，原样落到下面的 ffprobe，
    // 保证「关掉原生通道」与「开着」得到同一份入库结果（tests/verify 与 tests/test_tags_native.cpp 判据）。
    // 环境变量 RLPLAYER_NATIVE_TAGS=0 可整体关闭（默认开）。
    if (rta::meta::native::enabled()) {
        rta::meta::native::TagInfo ni;
        std::string why;
        if (rta::meta::native::probe_file(file, &ni, &why)) {
            t.title = ni.title; t.artist = ni.artist; t.album = ni.album;
            t.albumArtist = ni.albumArtist; t.genre = ni.genre;
            t.trackNo = ni.trackNo; t.discNo = ni.discNo; t.year = ni.year;
            t.sampleRate = ni.sampleRate; t.channels = ni.channels;
            t.bits = ni.bits; t.duration = ni.duration; t.codec = ni.codec;
            // 与下面 ffprobe 分支的老口径逐条对齐：
            //   * ffprobe 的 bits_per_raw_sample 对 16-bit WAV / MP3 / OGG 是 N/A ⟹ 旧代码统一写成 16；
            //     FLAC/WAV-24bit 则报真值（24）。这里同样是「<=0 就 16」。
            if (t.bits <= 0) t.bits = 16;
            // 同目录独立封面（只 stat）与内嵌封面任一成立即算有封面 —— 与下面同一行逻辑。
            t.hasCover = ni.hasCover ? 1 : 0;
            if (!t.hasCover && lib_has_cover_file(t.path)) t.hasCover = 1;
            return t;
        }
    }
    const std::string ffprobe = !ffprobePath.empty() ? ffprobePath : rta::audio::find_tool("ffprobe");
    if (ffprobe.empty()) return t;

    std::string out;
    // 2026-10-23 真机 DEBUG（用户反馈「1.3.x 封面不显示」，实测曲目 C:\...\谭晶 - 游京 (长征版).flac）：
    // 那首是**单文件 + 内嵌封面**（同目录没有 cover.jpg），而 hasCover 只看同目录文件 → cv:false → UI 不显示封面；
    // 但 /api/cover 其实能抽出 706,780 字节的图。所以必须在这里同时问「有没有视频流（=内嵌封面）」。
    // 做法：去掉 -select_streams（一次读出所有流），流里 codec_type=video 即内嵌封面/图片。
    //   ⚠️ 注意：某些容器把封面报成 video 流，所以只看 codec_type 即可，不看 codec_name。
    // * 2026-10-25（261025-01 关联缺陷，实测）：只取 format_tags 会漏掉 **OGG/Opus 的 Vorbis Comment**
    // —— 它们挂在 stream_tags 上。实测 ffprobe -show_entries format_tags=... 对
    //   "夏微 - 天鸟.ogg" 返回空，而 stream_tags 给出
    //   ALBUM=翻唱集 / ARTIST=夏微 / TITLE=天鸟（Cover：奥華子）
    // ⟹ 该文件在库里退化成"文件名当曲名、目录名当专辑"。
    // 修法：一次调用同时取 stream_tags 与 format_tags，并用 -of default=nw=0（带 [STREAM]/[FORMAT]
    // 段标记）解析，从而确定性地实现「format 优先、缺失回退 stream」——
    // 不依赖 ffprobe 的输出顺序（只靠"后者覆盖前者"是脆的：一旦顺序变了，stream 就会覆盖真标签）。
    // 另测：mp3(ID3) / wav(INFO) / m4a 的标签都在 format_tags，行为不变。
    const std::wstring cmd =
        L"\"" + rta::audio::widen(ffprobe) + L"\" -v error"
        L" -show_entries stream=codec_type,codec_name,sample_rate,channels,bits_per_raw_sample"
        L":stream_tags=title,artist,album,album_artist,date,genre,track,disc"
        L":format=duration:format_tags=title,artist,album,album_artist,date,genre,track,disc,tracktotal"
        L" -of default=nw=0 \"" + rta::audio::widen(file) + L"\"";
    if (rta::audio::run_hidden(cmd, &out) != 0) return t;

    std::string title, artist, album, aartist, date, genre, track, disc;
    bool curIsAudio = false;   // 当前解析到的流是不是音频（封面流的字段不能覆盖音频参数）
    bool inFormat = false;     // 当前是否在 [FORMAT] 段（=标签权威来源；[STREAM] 段只做兜底）
    std::string line;
    for (size_t i = 0; i <= out.size(); ++i) {
        if (i == out.size() || out[i] == '\n') {
            // -of default=nw=0 会打印段标记：[STREAM] / [/STREAM] / [FORMAT] / [/FORMAT]
            if (line == "[FORMAT]") { inFormat = true; line.clear(); continue; }
            if (line == "[/FORMAT]") { inFormat = false; line.clear(); continue; }
            if (line == "[STREAM]") { inFormat = false; curIsAudio = false; line.clear(); continue; }
            const size_t e = line.find('=');
            if (e != std::string::npos) {
                std::string k = line.substr(0, e);
                const std::string v = line.substr(e + 1);
                for (auto& c : k) c = (char)std::tolower((unsigned char)c);
                if (k.compare(0, 4, "tag:") == 0) k = k.substr(4);
                // format 段 = 真标签，覆盖；stream 段 = 只填空（OGG/Opus 的 Vorbis Comment 在这里）
                auto put = [&](std::string& dst) {
                    if (!dst.empty()) return;
                    dst = v; while (!dst.empty() && (dst.back() == '\r' || dst.back() == ' ')) dst.pop_back(); };
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
// 索引文件的"年龄"（秒）：last_write_time 与当前时钟差。读不到 = 1e9（当作立刻要扫）。
inline double Library::indexAgeSeconds() const {
    std::error_code ec;
    const auto t = fsx::last_write_time(p8(indexPath()), ec);
    if (ec) return 1e9;
    const auto now = fsx::file_time_type::clock::now();
    const double sec = std::chrono::duration<double>(now - t).count();
    return sec < 0.0 ? 0.0 : sec;
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
            // 首次运行：探测常见音乐目录，减少初次打开时的空库情况。
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
        const bool fresh = (idx.find("#libIndexV\t4") != std::string::npos);
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
                        // v4 追加列（v3 只有 16 列；前 16 列的读取路径与 v3 逐字相同）
                        if (f.size() >= 20) {
                            t.cuePath = f[16];
                            t.cueNo   = atoi(f[17].c_str());
                            t.cueOff  = _strtoi64(f[18].c_str(), nullptr, 10);
                            t.cueLen  = _strtoi64(f[19].c_str(), nullptr, 10);
                        }
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
        trackCount_.store(tracks_.size());
        albumCount_.store(0);
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
                        if (st > 0) scanThreads_.store((size_t)st);
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
    s += "#libIndexV\t4\n";   // v4 = 2026-10-25 起 CUE 虚拟分轨：前 16 列不变 + 末尾 4 列
    s += "#path\tmtime\tsize\talbum\talbumArtist\tartist\ttitle\ttrack\tdisc\tyear\tsr\tbits\tch\tdur\thasCover\tgenre"
         "\tcue\tcueN\tcueOff\tcueLen\n";
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
        s += lib_clean_field(t.genre);     s += '\t';
        s += lib_clean_field(t.cuePath);   s += '\t';
        std::snprintf(buf, sizeof(buf), "%d\t%lld\t%lld\n", t.cueNo, t.cueOff, t.cueLen);
        s += buf;
    }
    return s;
}
// 锁外落盘（调用方持锁时构造好的快照）。writeFile 自己走 tmp+rename，原子性由它保证。
inline void Library::writeIndex(const std::string& snapshot) {
    writeFile(indexPath(), snapshot);
}

// 专辑整理（读时推算）。
//
// ★ 2026-10-25 性能重写（261025-01 一.5「切标签每次都像重新扫描」/ 一.8「导入几千首后要等几分钟」）：
// 旧实现在 **std::sort 的比较器里**调 entity_find_album_dir_for_track()（每次都是一轮目录 stat +
// 逐文件判定）。N 首曲目的比较次数是 O(N logN)，每比较 2 次目录扫描 ⟹ 3000 首约 3~6 万次目录扫描，
// 全在 mtx_ 里做；/api/lib/albums 与 /api/lib/stats 都走这里，而 rtaweb 的 HTTP 是单线程 accept 循环
// ⟹ 一次专辑重建能把整个控制面堵住十几秒，看着就像"卡死/又在扫描"。
// 现在：① 每个目录只 stat 一次（LibDirAlbumMemo，键=父目录）；② 碟号预先算进 discOf[]，
// 比较器里**不再碰文件系统**；③ 结束时把专辑数写进 albumCount_（status 无锁读）。
//
// ★ 2026-10-26（上游 9ce018f 的专辑归并，mac 重做）：专辑键不再带 artist。
//   旧键 = (albumArtist?:artist) + 0x1f + 专辑名 ⟹ 同一张碟里每首 artist 不同就被切成多张"专辑"
//   （上游实测 654 首 → 301 张卡，物理目录只有 87 个；RESOLVERS 一张碟裂成 19 张）。
//   后果：专辑页零碎、封面按裂开的卡逐张去搜（同一张碟搜 19 次）、覆盖率分母被人为放大。
//   新键 = 专辑名 + 0x1f + 目录（目录做 CD1/Disc 2/disk_3 归一，保证多碟装仍合成一张）。
//
//   mac 侧额外理由（不是照抄）：mac 的 `albumCover()` 按专辑键缓存，键被 artist 切碎后
//   同一张碟的每张碎卡各自起 ffmpeg 取图 —— 与「封面页卡死」是同一个根因链。
//
//   归一函数只在**目录段**上做，不动专辑名：`CD Collection` 这类正常目录名必须原样保留。
inline std::string lib_dir_album_key(const std::string& dir) {
    std::string d;
    d.reserve(dir.size());
    for (char c : dir) d.push_back((char)std::tolower((unsigned char)c));
    for (;;) {
        size_t e = d.size();
        while (e > 0 && (d[e - 1] == '\\' || d[e - 1] == '/')) --e;
        d.resize(e);
        size_t digitsEnd = e;
        while (e > 0 && std::isdigit((unsigned char)d[e - 1])) --e;
        if (e == digitsEnd) break;
        size_t q = e;
        if (q > 0 && (d[q - 1] == '-' || d[q - 1] == '_' || d[q - 1] == ' ')) --q;
        if (q >= 2 && d.compare(q - 2, 2, "cd") == 0) { d.resize(q - 2); continue; }
        if (q >= 4 && d.compare(q - 4, 4, "disc") == 0) { d.resize(q - 4); continue; }
        if (q >= 4 && d.compare(q - 4, 4, "disk") == 0) { d.resize(q - 4); continue; }
        break;
    }
    return d;
}

inline const std::vector<LibAlbum>& Library::albumVecLocked() const {
    if (!albumsDirty_) return albums_;
    albums_.clear();
    const size_t n = tracks_.size();
    LibDirAlbumMemo memo;               // 局部 memo：同目录只扫一次
    std::vector<int> discOf(n, 0);      // 预先算好排序用碟号（comparator 里必须零 IO）
    std::map<std::string, size_t> byKey;
    for (size_t i = 0; i < n; ++i) {
        const auto& t = tracks_[i];
        std::string aName = t.album;
        std::string aArtist = t.albumArtist.empty() ? t.artist : t.albumArtist;
        int discForSort = t.discNo;
        // 父目录**无条件**先算出来：专辑键要用它（旧实现只在缺标签时才取，键里就没有目录信息）
        const std::string pdir = u8s(p8(t.path).parent_path().u8string());
        if (aName.empty() || discForSort == 0) {
            const LibDirAlbum da = memo.get(pdir, t.path);
            if (da.fromDir) {
                if (aName.empty()) aName = da.album;
                if (discForSort == 0 && da.disc > 0) discForSort = da.disc;
            } else if (aName.empty()) {
                aName = da.album.empty() ? std::string("未知专辑") : da.album;
            }
        }
        discOf[i] = discForSort;
        const std::string dirKey = lib_dir_album_key(pdir);
        const std::string rawKey = aName + "\x1f" + dirKey;
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
    for (auto& a : albums_) {
        std::sort(a.idx.begin(), a.idx.end(), [&](size_t x, size_t y) {
            const int pDisc = discOf[x], qDisc = discOf[y];
            if (pDisc != qDisc) return pDisc < qDisc;
            const auto& p = tracks_[x]; const auto& q = tracks_[y];
            if (p.trackNo != q.trackNo) return p.trackNo < q.trackNo;
            return p.path < q.path;
        });
    }
    std::sort(albums_.begin(), albums_.end(), [](const LibAlbum& a, const LibAlbum& b) {
        const std::string x = a.artist + "\x1f" + a.name, y = b.artist + "\x1f" + b.name;
        return x < y;
    });
    albumsDirty_ = false;
    albumCount_.store(albums_.size());
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

// ---------------------------------------------------------------------------
// 封面取图（261026-02 B-1，来自上游 v1.5.2 `fb77a0b` 的实测诊断，本机同构复现）
//
// 旧实现的两个连锁缺陷（实测必现，与平台无关）：
//   ① 只问 `tracks_[a.idx[0]].path` 一首 —— 首曲没图就整张专辑空白，哪怕同专辑第 2 首
//      内嵌了 700 KB 的封面。合辑/精选集里这非常常见（各曲来自不同源文件）。
//   ② `rta::audio::get_cover()` 找不到图时**不返回空**，而是返回一张 **1x1 透明 PNG**
//      （media_info.h:362 的 px[]，77~89 字节）。旧代码 `return !bytes.empty()` 于是
//      恒为 true ⟹ HTTP 200 + 合法 PNG ⟹ 前端 `<img onerror>` 永远不会触发
//      ⟹ 用户看到的是一块空白而不是首字母占位；更糟的是这张占位图还被写进 coverCache_
//      **永不重试**，用户后来补了封面也得重启才看得见。
//
// 现在的口径：
//   * 顺序：本专辑 **cv=1 的曲目优先**（≤3 首），再其余曲目（≤3 首）。
//     两个 3 的上限是为了别对 200 首的合辑起 200 次 ffmpeg（每次一个进程，实测 ~20-40 ms）。
//   * 判定：真封面 ⟺ 字节数 >= kCoverMinBytes(1KB)。小于它的**继续试下一首**。
//   * 1x1 占位图（get_cover 的兜底产物）靠 IHDR 宽高识别，**当作"没有"**，不当小图。
//   * 全部试完：拿到真图 ⟹ 正缓存 + true；只有"小但真实"的图 ⟹ 用它 + true（总比空白好）；
//     什么都没有 ⟹ **负缓存 + false**（前端 onerror 露首字母，且下次还会重试）。
//
// ⚠️ 负缓存用的是「空字节」这一既有约定（见下面 cache 命中分支），不是新的哨兵值。
// ---------------------------------------------------------------------------
// 1x1 占位 PNG 识别：只看 PNG 签名 + IHDR 的前 10 字节（宽/高），不解码、不依赖具体字节序列。
// 这样即使 media_info.h 以后换了占位图颜色/压缩参数，这条判据依然成立。
inline bool lib_cover_is_1x1_placeholder(const std::vector<unsigned char>& b) {
    static const unsigned char kPng[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (b.size() < 33) return false;                       // 8(sig)+4(len)+4("IHDR")+8(w,h) = 24；33 是宽松下界
    if (std::memcmp(b.data(), kPng, 8) != 0) return false;
    if (std::memcmp(b.data() + 12, "IHDR", 4) != 0) return false;
    auto be32 = [&](size_t off) {
        return ((uint32_t)b[off] << 24) | ((uint32_t)b[off + 1] << 16) |
               ((uint32_t)b[off + 2] << 8) | (uint32_t)b[off + 3];
    };
    return be32(16) == 1u && be32(20) == 1u;
}

// ---------------------------------------------------------------------------
// 封面 ffmpeg 的全局并发闸门（1.1.1.4-beta「封面提取卡 UI」，2026-10-31）
//
// 为什么需要：每次 `/api/lib/cover` 缓存未命中都会**同步**起一次 ffmpeg 抽内嵌封面。
// 实测 SMB 库上单次 20–249 s（rlplayer-events.jsonl：399 次 >60 s，最大 248,783 ms），
// 而封面请求走 scheme-handler 的并发队列 ⟹ 几十个慢 ffmpeg 同时占住 SMB 与 WebKit，
// 播放器 UI 跟着卡住。两道闸：
//   ① 硬超时 —— 单文件 6 s（get_cover 的 ffmpeg_timeout_ms）+ 单张专辑总预算 12 s；
//   ② 全进程并发上限 2 —— 不管有多少封面请求排队，同时跑的 ffmpeg 不超过 2 个。
//
// 为什么放 header-inline 的 static：C++17 保证这种 inline 函数内的 static 局部变量在**整个
// 程序里唯一**（跨 TU 共享）。webui 的封面线程与测试里的多实例因此共用同一份计数。
// 闸门只包住真的需要起 ffmpeg 的路径 —— 缓存命中在上面就返回了，不占位。
// ---------------------------------------------------------------------------
inline std::mutex& cover_gate_mu() { static std::mutex m; return m; }
inline std::condition_variable& cover_gate_cv() { static std::condition_variable cv; return cv; }
inline int& cover_gate_active() { static int n = 0; return n; }

// 取一个并发位。wait_ms <= 0 只做非阻塞尝试。成功返回 true（**必须**配对 cover_gate_release）。
inline bool cover_gate_acquire(int wait_ms) {
    constexpr int kMaxConcurrent = 2;                       // 全局并发上限
    std::unique_lock<std::mutex> lk(cover_gate_mu());
    auto ready = [] { return cover_gate_active() < kMaxConcurrent; };
    if (ready()) { ++cover_gate_active(); return true; }
    if (wait_ms <= 0) return false;
    if (!cover_gate_cv().wait_for(lk, std::chrono::milliseconds(wait_ms), ready)) return false;
    ++cover_gate_active();
    return true;
}

inline void cover_gate_release() {
    {
        std::lock_guard<std::mutex> lk(cover_gate_mu());
        if (cover_gate_active() > 0) --cover_gate_active();
    }
    cover_gate_cv().notify_all();
}

// RAII：保证任何返回路径（含提前 return / 异常）都放开并发位。
struct CoverGateGuard {
    bool held = false;
    explicit CoverGateGuard(bool ok) : held(ok) {}
    CoverGateGuard(const CoverGateGuard&) = delete;
    CoverGateGuard& operator=(const CoverGateGuard&) = delete;
    ~CoverGateGuard() { if (held) cover_gate_release(); }
};

inline bool Library::albumCover(const std::string& key, std::vector<unsigned char>& bytes, std::string& mime) {
    // 1 KB：真实封面（含 APIC 缩略图）极少这么小；比它还小的一律先当"可疑"，继续试下一首。
    const size_t kCoverMinBytes = 1024;
    // ---- 三个时限 + 一个并发上限（1.1.1.4-beta「封面提取卡 UI」，2026-10-31）----
    // 数值依据：SMB 库上单次 ffmpeg 实测 20–249 s（P50 也远超 6 s 的样本 399 个）。
    //   * 单文件 6 s：正常的本地盘/千兆 SMB 抽一张内嵌图远小于它，超过就在这一首上止损；
    //   * 单张专辑 12 s（最多 6 首候选）：等价于"允许两次单文件超时"，再多就是盘真的不行了；
    //   * 等并发位 1.5 s：等不到说明已有 2 个慢 ffmpeg 在跑，这时候排队只是在堆请求线程。
    const int kFfmpegTimeoutMs = 6000;      // 单文件 ffmpeg 硬上限
    const int kAlbumBudgetMs   = 12000;     // 单张专辑总预算
    const int kGateWaitMs      = 1500;      // 等全局并发位最多这么久
    // 取图顺序：cv=1 的曲目优先（≤3），再其余曲目（≤3）。锁内只收集路径，锁外才起 ffmpeg。
    std::vector<std::string> order;
    {
        std::lock_guard<std::mutex> lk(mtx_);
        auto it = coverCache_.find(key);
        if (it != coverCache_.end()) {
            if (it->second.first.empty()) return false;    // 负缓存：确定没有
            bytes = it->second.first; mime = it->second.second; return true;
        }
        std::vector<std::string> withCv, without;
        const auto& v = albumVecLocked();
        for (const auto& a : v) {
            if (a.key != key) continue;
            for (size_t ix : a.idx) {
                if (ix >= tracks_.size()) continue;
                const LibTrack& t = tracks_[ix];
                if (t.path.empty()) continue;
                if (t.hasCover) { if (withCv.size()  < 3) withCv.push_back(t.path); }
                else            { if (without.size() < 3) without.push_back(t.path); }
            }
            break;                                          // 专辑键唯一，命中即停
        }
        order = withCv;
        order.insert(order.end(), without.begin(), without.end());
    }
    if (order.empty()) return false;

    // ---- 并发闸门（2026-10-31，1.1.1.4-beta「封面提取卡 UI」）----
    // 只在真的要起 ffmpeg 时才排队；缓存命中已在上面返回，不占位。
    // 等不到就**放弃这一次**：宁可这次不显示封面，也不要把请求线程堆在慢盘后面。
    // 注意这里**不写负缓存** —— 排队失败不等于"这张专辑没有封面"，下次还得能重试。
    if (!cover_gate_acquire(kGateWaitMs)) return false;
    CoverGateGuard gate(true);

    // 等位期间别的线程可能已经把这张专辑取好了 —— 再查一次，避免重复起 ffmpeg。
    {
        std::lock_guard<std::mutex> lk(mtx_);
        auto it = coverCache_.find(key);
        if (it != coverCache_.end()) {
            if (it->second.first.empty()) return false;    // 负缓存：确定没有
            bytes = it->second.first; mime = it->second.second; return true;
        }
    }

    std::vector<unsigned char> best;      // 真封面（>= 1KB）
    std::string bestMime;
    std::vector<unsigned char> small;     // 小但**不是** 1x1 占位图（最后兜底）
    std::string smallMime;
    bool timedOut = false;
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(kAlbumBudgetMs);
    for (const std::string& p : order) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) { timedOut = true; break; }        // 整张专辑的预算用完
        long long remain =
            std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
        if (remain < 1) remain = 1;
        const int timeoutMs = (int)std::min<long long>(kFfmpegTimeoutMs, remain);
        std::string m;
        bool t = false;
        std::vector<unsigned char> cand = rta::audio::get_cover(p, m, timeoutMs, &t);
        if (t) { timedOut = true; continue; }        // 超时不是"没封面"：占位图不算数，试下一首
        if (cand.empty()) continue;
        if (lib_cover_is_1x1_placeholder(cand)) continue;    // get_cover 的"没有"兜底：跳过，继续问下一首
        if (cand.size() >= kCoverMinBytes) { best.swap(cand); bestMime = m; break; }
        if (small.empty()) { small.swap(cand); smallMime = m; }
    }
    if (!best.empty()) {
        std::lock_guard<std::mutex> lk(mtx_);
        if (coverCache_.size() > 256) coverCache_.clear();
        coverCache_[key] = { best, bestMime };
        bytes.swap(best);
        mime = bestMime;
        return true;
    }
    if (!small.empty()) {
        // 全专辑只有小图（真实但很小，例如 600 字节的缩略图）：用它，但仍然**不写负缓存**
        // —— 让用户以后换了更大的封面时能自动生效。这里也不写正缓存，理由同下。
        bytes.swap(small);
        mime = smallMime;
        return true;
    }
    if (!timedOut) {
        // 全专辑都没有封面：写负缓存（空字节 = 确定没有），返回 false 让前端露首字母。
        // 为什么敢缓存"没有"：这一轮已经把 cv=1 与其余各 3 首都问过了，短期内重试只会重复
        // 起同样的 ffmpeg 进程；而**占位图不写正缓存**这条保证不会把坏结果钉死。
        std::lock_guard<std::mutex> lk(mtx_);
        if (coverCache_.size() > 256) coverCache_.clear();
        coverCache_[key] = { std::vector<unsigned char>(), std::string() };
    }
    // 超时（有曲目是"没问完"而不是"问了没有"）⟹ 直接返回 false，**不写负缓存**：
    // 否则慢盘上的一次超时会让这张专辑在本次进程生命周期里永久显示首字母。
    bytes.clear();
    mime = "image/png";
    return false;
}

// ---------------- 封面在线抓取：按 album+artist 反查（2026-10-26）----------------
// 只读：不落盘、不改索引；专辑表还没整理时由 albumVecLocked() 触发一次整理（与 albums() 同代价）。
inline std::string lib_cover_term(const std::string& name, const std::string& artist) {
    std::string t = name;
    if (!artist.empty()) { if (!t.empty()) t += ' '; t += artist; }
    return t;
}

inline std::vector<LibCoverTerm> Library::albumsWithoutCover() const {
    std::vector<LibCoverTerm> out;
    std::lock_guard<std::mutex> lk(mtx_);
    const auto& v = albumVecLocked();
    out.reserve(v.size());
    for (const auto& a : v) {
        if (a.hasCover) continue;                 // 库里已有图（内嵌流或同目录封面文件）
        LibCoverTerm t;
        t.key = a.key; t.name = a.name; t.artist = a.artist;
        t.term = lib_cover_term(a.name, a.artist);
        out.push_back(std::move(t));
    }
    return out;
}

inline bool Library::albumCoverTerm(const std::string& key, LibCoverTerm& out) const {
    if (key.empty()) return false;
    std::lock_guard<std::mutex> lk(mtx_);
    for (const auto& a : albumVecLocked()) {
        if (a.key != key) continue;
        out.key = a.key; out.name = a.name; out.artist = a.artist;
        out.term = lib_cover_term(a.name, a.artist);
        return true;
    }
    return false;
}

inline void Library::joinScan() {
    if (th_.joinable()) th_.join();
}

inline bool Library::startScan(bool forceFull) {
    if (scanning_.load()) return false;
    joinScan();
    const auto roots = this->roots();
    // 旧索引（增量基准）
    std::vector<LibTrack> old = [&] { std::lock_guard<std::mutex> lk(mtx_); return tracks_; }();

    cancel_.store(false);
    scanning_.store(true);
    scanned_.store(0);
    total_.store(0);
    // 1.1.1.4：新一轮开始 ⟹ 上一轮的"完成/失效项/坏目录"结论全部作废
    scanSkipped_.store(0);
    scanFailedDirs_.store(0);
    scanComplete_.store(false);
    { std::lock_guard<std::mutex> lk(msgMtx_); scanMsg_ = "正在遍历目录…"; }

    const size_t thCount = this->scanThreads();

    th_ = std::thread([this, roots, old, forceFull, thCount]() {
        // ★ 整个扫描体包一层 catch：扫描是后台线程，任何未捕获异常都会 std::terminate，
        // 进程直接消失。异常只允许降级成一条错误文案。
        try {
        const auto tStart = std::chrono::steady_clock::now();

        // 老记录按路径建索引，便于复用
        std::unordered_map<std::string, size_t> oldByPath;
        oldByPath.reserve(old.size() * 2);
        for (size_t i = 0; i < old.size(); ++i) oldByPath[old[i].path] = i;

        // ---- 扫描前先剔除「文件已不存在」的记录并落盘（261025-01 一.3）----
        // 这样即使本次遍历中途被取消/失败，索引里也不会永久留着已删除文件的行。
        // ★ 先在锁外把存在性问完，锁内只做一次整体替换 ——
        //   否则状态查询在扫描刚启动时会被这一下堵住上百毫秒。
        int gone = 0;
        {
            std::unordered_map<std::string, bool> existsMemo;
            existsMemo.reserve(old.size() * 2);
            std::vector<const std::string*> dead;
            for (const auto& o : old) {
                auto itm = existsMemo.find(o.path);
                bool alive;
                if (itm == existsMemo.end()) { alive = lib_file_exists(o.path); existsMemo.emplace(o.path, alive); }
                else alive = itm->second;
                if (!alive) dead.push_back(&o.path);
            }
            if (!dead.empty()) {
                std::unordered_map<std::string, char> deadSet;
                deadSet.reserve(dead.size() * 2);
                for (auto* d : dead) deadSet[*d] = 1;
                std::string text;
                {
                    std::lock_guard<std::mutex> lk(mtx_);
                    std::vector<LibTrack> kept;
                    kept.reserve(tracks_.size());
                    for (auto& t : tracks_) {
                        if (deadSet.count(t.path)) { ++gone; continue; }
                        kept.push_back(std::move(t));
                    }
                    if (gone > 0) {
                        tracks_.swap(kept);
                        albumsDirty_ = true;
                        albumCount_.store(0);
                        trackCount_.store(tracks_.size());
                        text = indexTextLocked();
                    }
                }
                if (gone > 0) writeIndex(text);
            }
            removedMissing_.store(gone);
        }

        std::vector<LibTrack> fresh;
        std::vector<std::string> walked;
        std::vector<std::string> cueWalked;
        std::vector<std::string> badRoots;   // 打不开的根（例如离线外接盘）
        std::vector<std::string> failedDirs; // 能进但读不全的子目录（SMB 失效项 / 权限）
        std::error_code ec;
        auto lastTick = std::chrono::steady_clock::now();
        // 进度限频（150ms）：遍历是单线程 I/O，这里只是让用户看到数字在动
        auto noteProgress = [&] {
            const auto now = std::chrono::steady_clock::now();
            if (std::chrono::duration<double, std::milli>(now - lastTick).count() < 150.0) return;
            lastTick = now;
            std::lock_guard<std::mutex> lk(msgMtx_);
            scanMsg_ = "正在遍历目录… " + std::to_string(walked.size()) + " 首";
        };
        size_t skippedItems = 0;
        for (const auto& root : roots) {
            if (cancel_.load()) break;
            bool isDir = false;
            try {
                if (!lib_valid_utf8(root)) { badRoots.push_back(root); continue; }
                isDir = fsx::is_directory(p8(root), ec);
            } catch (const std::exception&) { isDir = false; }
            if (!isDir) { badRoots.push_back(root); continue; }
            // 1.1.1.4：改用平台层容错枚举（失效项只计数、不中止整次遍历）
            LibWalkResult wr = lib_walk_tree(
                root,
                [&](const std::string& f) { walked.push_back(f); total_.store((int)walked.size()); },
                [&](const std::string& c) { cueWalked.push_back(c); },
                noteProgress,
                [&] { return cancel_.load(); });
            skippedItems += wr.skipped;
            for (auto& d : wr.failedDirs) failedDirs.push_back(std::move(d));
            if (wr.cancelled || cancel_.load()) break;
            std::this_thread::yield();   // 多个根之间让出一次时间片（大库扫描不拖死界面）
        }
        scanSkipped_.store(skippedItems);
        scanFailedDirs_.store(failedDirs.size());
        if (cancel_.load()) {
            // 取消：绝不写索引（半截结果落盘比不扫更糟），也不算"完成"
            scanComplete_.store(false);
            scanning_.store(false);
            return;
        }

        const int n = (int)walked.size();
        total_.store(n);
        if (n == 0 && cueWalked.empty()) {
            const auto tEnd = std::chrono::steady_clock::now();
            const double durMs = std::chrono::duration<double, std::milli>(tEnd - tStart).count();
            // ★ 防"库被清空"：有坏根/有读不全的目录就保留这些位置下的老记录，只在真没有坏根时清空。
            std::vector<LibTrack> kept;
            if (!badRoots.empty() || !failedDirs.empty()) {
                for (auto& o : old) {
                    bool keep = false;
                    for (auto& br : badRoots)
                        if (lib_path_under(o.path, br)) { keep = true; break; }   // 盘不在：直接保留
                    if (!keep)
                        for (auto& fd : failedDirs)
                            // 坏子目录不一定是"盘不在"（可能只是这一层读不了）⟹ 文件确实还在才保留
                            if (lib_path_under(o.path, fd)) { keep = lib_file_exists(o.path); break; }
                    if (keep) kept.push_back(o);
                }
            }
            std::string text;
            {
                std::lock_guard<std::mutex> lk(mtx_);
                tracks_.swap(kept);
                albumsDirty_ = true;
                albumCount_.store(0);
                trackCount_.store(tracks_.size());
                lastScanMs_.store(durMs);
                lastScanProbed_.store(0);
                lastScanCached_.store(0);
                text = indexTextLocked();
            }
            writeIndex(text);          // 锁外写盘
            scanComplete_.store(failedDirs.empty() && badRoots.empty());
            {
                std::lock_guard<std::mutex> lk(msgMtx_);
                std::string m = "完成：0 首";
                if (!badRoots.empty()) {
                    m += "（" + std::to_string(badRoots.size()) + " 个根目录无法访问，已保留其下 " +
                         std::to_string(trackCount_.load()) + " 条旧记录：" + badRoots[0];
                    if (badRoots.size() > 1) m += " 等";
                    m += "）";
                }
                if (skippedItems > 0) m += "；跳过 " + std::to_string(skippedItems) + " 个失效项";
                if (!failedDirs.empty()) m += "；" + std::to_string(failedDirs.size()) + " 个目录不可读（保留旧记录）";
                scanMsg_ = m;
            }
            scanning_.store(false);
            return;
        }

        // =====================================================================
        // CUE 认领判定
        // =====================================================================
        struct CueJob {
            std::string cuePath;
            rta::meta::CueSheet sh;
            std::map<std::string, LibTrack> slots;   // key = lib_path_key(FILE 路径)，value.path = 磁盘真名
        };
        std::vector<CueJob> cueJobs;
        std::unordered_map<std::string, char> cueCand;   // 候选认领（决定哪些文件必须重探）
        if (!cueWalked.empty()) {
            std::unordered_map<std::string, std::string> walkedByKey;
            walkedByKey.reserve(walked.size() * 2 + 8);
            for (const auto& w : walked) walkedByKey.emplace(lib_path_key(w), w);
            std::sort(cueWalked.begin(), cueWalked.end());
            for (const auto& cf : cueWalked) {
                if (cancel_.load()) break;
                CueJob job;
                job.cuePath = cf;
                job.sh = rta::meta::cue_parse_file(cf);
                if (job.sh.tracks.empty()) continue;
                for (const auto& ct : job.sh.tracks) {
                    if (!ct.audio || ct.index1 < 0) continue;
                    const std::string k = lib_path_key(ct.file);
                    if (cueCand.count(k) || job.slots.count(k)) continue;
                    auto wit = walkedByKey.find(k);
                    const std::string real = (wit != walkedByKey.end()) ? wit->second : ct.file;
                    if (wit == walkedByKey.end() && !lib_cue_audio_exists(real)) continue;
                    LibTrack slot;
                    slot.path = real;
                    job.slots.emplace(k, std::move(slot));
                    cueCand[k] = 1;
                }
                if (!job.slots.empty()) cueJobs.push_back(std::move(job));
            }
        }
        std::mutex cueProbeMtx;
        std::map<std::string, LibTrack> cueProbeMap;

        fresh.resize((size_t)n);
        std::atomic<int> completed{0};
        std::atomic<int> probedCount{0};
        std::atomic<int> cachedCount{0};

        // 2026-10-26（B-1）：允许用环境变量 RLPLAYER_FFPROBE 指定 ffprobe 路径。
        // 为什么需要：本机系统 ffprobe 坏了（-version 退出 134），find_tool 仍会返回它，
        // 于是扫描拿不到标签。用户/测试可以显式指向可用的 ffprobe（如仓库自建的
        // build-mac/ffmpeg-lite/ffprobe）——这是**正当的产品能力**（换机器/自定义工具链），
        // 不是为测试开的后门：不设该变量时行为与之前逐字一致。
        const std::string ffprobe = [&] {
            if (const char* env = std::getenv("RLPLAYER_FFPROBE")) {
                if (env[0]) return std::string(env);
            }
            return rta::audio::find_tool("ffprobe");
        }();

        auto pool = std::make_shared<ScanPool>(thCount);
        {
            std::lock_guard<std::mutex> lk(mtx_);
            activePool_ = pool;
        }

        std::chrono::steady_clock::time_point lastMsg = std::chrono::steady_clock::now();

        for (int i = 0; i < n; ++i) {
            if (cancel_.load()) break;
            const bool submitted = pool->submit([this, i, n, &walked, &oldByPath, &old, forceFull, &ffprobe,
                                                 &fresh, &completed, &probedCount, &cachedCount, &lastMsg,
                                                 &cueCand, &cueProbeMtx, &cueProbeMap]() {
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
                const std::string pkey = lib_path_key(p);
                const bool cueOwned = (cueCand.count(pkey) != 0);
                auto oit = oldByPath.find(p);
                if (!forceFull && !cueOwned && oit != oldByPath.end()) {
                    const LibTrack& o = old[oit->second];
                    if (!o.isCueTrack() && o.mtime == mt && o.size == sz) {
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
                if (cueOwned) {
                    std::lock_guard<std::mutex> lk(cueProbeMtx);
                    cueProbeMap[pkey] = t;
                }
                fresh[(size_t)i] = std::move(t);
                probedCount.fetch_add(1, std::memory_order_relaxed);
                const int c = completed.fetch_add(1, std::memory_order_relaxed) + 1;
                scanned_.store(c);
                // 进度文案：改为限频（每 100ms 一次）而不是每 8 首一次
                if (c == n || std::chrono::duration<double, std::milli>(
                                  std::chrono::steady_clock::now() - lastMsg).count() >= 100.0) {
                    lastMsg = std::chrono::steady_clock::now();
                    std::lock_guard<std::mutex> lk(msgMtx_);
                    scanMsg_ = "读取标签 " + std::to_string(c) + "/" + std::to_string(n);
                }
            });
            if (!submitted) break;
            if ((i & 0x3F) == 0) std::this_thread::yield();   // 分片让出（提交侧）
        }

        pool->wait(false);

        {
            std::lock_guard<std::mutex> lk(mtx_);
            activePool_.reset();
        }

        if (cancel_.load()) {
            scanComplete_.store(false);
            scanning_.store(false);
            return;
        }

        // ---- CUE 展开（整轨 → N 条虚拟曲目）----
        std::vector<LibTrack> cueTracks;
        std::unordered_map<std::string, char> cueClaimed;   // 最终认领（整轨从 fresh 里摘掉）
        int cueOk = 0, cueLost = 0;
        for (auto& job : cueJobs) {
            std::map<std::string, LibTrack> probes;
            for (auto& kv : job.slots) {
                LibTrack pr;
                auto pit = cueProbeMap.find(kv.first);
                if (pit != cueProbeMap.end()) pr = pit->second;
                else {
                    pr = lib_probe_one(kv.second.path, ffprobe);
                    if (pr.path.empty()) pr.path = kv.second.path;
                    std::error_code e2;
                    const fsx::path wp = p8(kv.second.path);
                    auto ft = fsx::last_write_time(wp, e2);
                    if (!e2) pr.mtime = (long long)ft.time_since_epoch().count();
                    auto fsz = fsx::file_size(wp, e2);
                    if (!e2) pr.size = (long long)fsz;
                }
                if (pr.sampleRate <= 0) continue;    // 探测失败 → 该文件退回整轨
                probes.emplace(kv.first, std::move(pr));
            }
            if (probes.empty()) { ++cueLost; continue; }
            std::vector<LibTrack> vt = lib_cue_expand(job.sh, probes);
            if (vt.empty()) { ++cueLost; continue; }
            for (const auto& kv : probes) cueClaimed[kv.first] = 1;
            for (auto& t : vt) cueTracks.push_back(std::move(t));
            ++cueOk;
        }
        if (!cueTracks.empty()) {
            std::vector<LibTrack> kept;
            kept.reserve(fresh.size() + cueTracks.size());
            for (auto& t : fresh) {
                if (t.path.empty()) continue;
                if (cueClaimed.count(lib_path_key(t.path))) continue;
                kept.push_back(std::move(t));
            }
            for (auto& t : cueTracks) kept.push_back(std::move(t));
            fresh.swap(kept);
        }

        const auto tEnd = std::chrono::steady_clock::now();
        const double durMs = std::chrono::duration<double, std::milli>(tEnd - tStart).count();

        // 打不开的根 + 读不全的子目录：保留下面的老记录（不因为它们"这次没被遍历到"就被删掉）
        // 坏根恢复防复活：逐条问 lib_file_exists，不在的不复活
        int badKeepSkipped = 0;
        if (!badRoots.empty() || !failedDirs.empty()) {
            const std::unordered_map<std::string, size_t> freshByPath = [&] {
                std::unordered_map<std::string, size_t> m;
                m.reserve(fresh.size() * 2);
                for (size_t k = 0; k < fresh.size(); ++k) if (!fresh[k].path.empty()) m[fresh[k].path] = k;
                return m;
            }();
            for (auto& o : old) {
                if (freshByPath.count(o.path)) continue;
                if (cueClaimed.count(lib_path_key(o.path))) continue;
                bool under = false;
                for (auto& br : badRoots) if (lib_path_under(o.path, br)) { under = true; break; }
                if (!under)
                    for (auto& fd : failedDirs) if (lib_path_under(o.path, fd)) { under = true; break; }
                if (!under) continue;
                if (lib_file_exists(o.path)) fresh.push_back(o);
                else ++badKeepSkipped;
            }
        }

        const size_t nt = fresh.size();
        std::string text;
        {
            std::lock_guard<std::mutex> lk(mtx_);
            tracks_.swap(fresh);
            albumsDirty_ = true;
            lastScanMs_.store(durMs);
            lastScanProbed_.store(probedCount.load());
            lastScanCached_.store(cachedCount.load());
            trackCount_.store(nt);
            // ★ 扫描结束就把专辑整理做掉（261025-01 一.8）
            albumVecLocked();
            text = indexTextLocked();
        }
        writeIndex(text);          // 锁外写盘（见 indexTextLocked 注释）
        // 1.1.1.4：有读不全的目录 ⟹ 索引可用但不完整（行数可能偏少），complete=false
        scanComplete_.store(failedDirs.empty() && badRoots.empty());
        {
            std::lock_guard<std::mutex> lk(msgMtx_);
            std::string m = "完成：" + std::to_string(nt) + " 首 (" + std::to_string((int)(durMs + 0.5)) + " ms)";
            if (!badRoots.empty()) {
                m += "；" + std::to_string(badRoots.size()) + " 个根目录无法访问（已保留其下旧记录";
                if (badKeepSkipped > 0) m += "，跳过 " + std::to_string(badKeepSkipped) + " 条已不存在的文件";
                m += "）";
            }
            if (skippedItems > 0) m += "；跳过 " + std::to_string(skippedItems) + " 个失效项";
            if (!failedDirs.empty())
                m += "；" + std::to_string(failedDirs.size()) + " 个目录不可读（保留旧记录）";
            const int gone = removedMissing_.load();
            if (gone > 0) m += "；已剔除 " + std::to_string(gone) + " 条不存在的文件";
            if (!cueWalked.empty())
                m += "；CUE 展开 " + std::to_string(cueOk) + " 张/" + std::to_string(cueTracks.size()) +
                     " 首" + (cueLost > 0 ? "（" + std::to_string(cueLost) + " 张退回整轨）" : "");
            scanMsg_ = m;
        }
        scanning_.store(false);
        }
        catch (const std::exception& e) {
            // 任何异常都不许把进程带走：降级成一条错误文案，索引维持扫描前的样子。
            { std::lock_guard<std::mutex> lk(msgMtx_); scanMsg_ = std::string("扫描失败：") + e.what(); }
            scanComplete_.store(false);
            scanning_.store(false);
        }
        catch (...) {
            { std::lock_guard<std::mutex> lk(msgMtx_); scanMsg_ = "扫描失败：未知异常"; }
            scanComplete_.store(false);
            scanning_.store(false);
        }
    });
    return true;
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


inline void Library::saveIndexLocked() {
    writeIndex(indexTextLocked());
}
inline std::string Library::indexTextLocked() const {
    return buildIndexLocked();
}
inline void Library::applyCleanLocked(std::vector<LibTrack>&& kept, int removed) {
    if (removed > 0) {
        tracks_.swap(kept);
        albumsDirty_ = true;
        albumCount_.store(0);
        trackCount_.store(tracks_.size());
    }
}
inline LibCleanResult Library::pruneMissingLocked() {
    std::vector<LibTrack> kept;
    kept.reserve(tracks_.size());
    int removed = 0;
    for (auto& t : tracks_) {
        if (lib_file_exists(t.path)) kept.push_back(std::move(t));
        else ++removed;
    }
    applyCleanLocked(std::move(kept), removed);
    LibCleanResult r; r.removed = removed; r.tracks = tracks_.size();
    return r;
}
inline LibCleanResult Library::pruneMissing() {
    LibCleanResult r;
    std::string text;
    {
        std::lock_guard<std::mutex> lk(mtx_);
        r = pruneMissingLocked();
        removedMissing_.store(r.removed);
        if (r.removed == 0) return r;
        text = indexTextLocked();
    }
    writeIndex(text);
    return r;
}
inline LibCleanResult Library::removeUnder(const std::string& dir) {
    LibCleanResult r;
    if (dir.empty() || !lib_valid_utf8(dir)) return r;
    std::string text;
    {
        std::lock_guard<std::mutex> lk(mtx_);
        std::vector<LibTrack> kept;
        kept.reserve(tracks_.size());
        for (auto& t : tracks_) {
            if (lib_path_under(t.path, dir)) { ++r.removed; continue; }
            kept.push_back(std::move(t));
        }
        applyCleanLocked(std::move(kept), r.removed);
        r.tracks = tracks_.size();
        if (r.removed > 0) text = indexTextLocked();
    }
    if (r.removed > 0) writeIndex(text);
    return r;
}
inline bool Library::removePath(const std::string& path) {
    if (path.empty()) return false;
    std::string text;
    bool hit = false;
    {
        std::lock_guard<std::mutex> lk(mtx_);
        std::vector<LibTrack> kept;
        kept.reserve(tracks_.size());
        for (auto& t : tracks_) {
            if (!hit && lib_path_under(t.path, path) && t.path.size() == path.size()) { hit = true; continue; }
            kept.push_back(std::move(t));
        }
        if (!hit) return false;
        applyCleanLocked(std::move(kept), 1);
        text = indexTextLocked();
    }
    writeIndex(text);
    return true;
}

} // namespace rta::net
