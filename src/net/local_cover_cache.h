// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#pragma once
#include "platform/path.h"
#include "platform/image_thumb.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

namespace rta::net::local_cover {
namespace fs = std::filesystem;
constexpr size_t kMaxImageBytes = 32 * 1024 * 1024;
struct Entry {
    std::string fingerprint, source, mime;
    std::vector<unsigned char> bytes;
};
inline std::string hex(const std::string& s) {
    static const char* digits = "0123456789abcdef";
    std::string out; out.reserve(s.size() * 2);
    for (unsigned char c : s) { out += digits[c >> 4]; out += digits[c & 15]; }
    return out;
}
inline uint64_t hash(const unsigned char* p, size_t n) {
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}
inline std::string root() {
    if (const char* v = std::getenv("RLPLAYER_COVER_DIR")) if (*v) return (fs::path(v) / "embed").string();
    std::string state;
    if (const char* v = std::getenv("RLPLAYER_STATE_DIR")) if (*v) state = v;
    if (state.empty()) state = rta::platform::config_dir_utf8();
    if (state.empty()) state = rta::platform::module_dir_utf8();
    return (fs::path(state) / "covercache" / "embed").string();
}
inline bool valid_key(const std::string& key) {
    if (key.empty() || key.size() > 64) return false;
    for (unsigned char c : key) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    return true;
}
inline std::vector<std::string> pictures(const std::string& audio) {
    const fs::path dir = fs::path(audio).parent_path();
    const char* names[] = {"cover", "folder", "front", "Cover", "Folder"};
    const char* exts[] = {".jpg", ".jpeg", ".png", ".JPG", ".PNG"};
    std::vector<std::string> out;
    for (auto n : names) for (auto e : exts) out.push_back((dir / (std::string(n) + e)).string());
    return out;
}
// Audio and existing picture stat are validated on every hit. A parent directory
// mtime/ctime signature detects newly added/removed pictures without 25 SMB stats.
inline bool stamp(const std::string& p, bool required, std::string& out) {
    struct stat st{};
    out += hex(p) + ":";
    if (::stat(p.c_str(), &st) != 0) {
        if (!required && errno == ENOENT) { out += "missing\n"; return true; }
        return false; // transient SMB/permission errors are not a clean miss
    }
    if (!S_ISREG(st.st_mode)) { if (required) return false; out += "not-file\n"; return true; }
    out += std::to_string(st.st_mtimespec.tv_sec) + ":" + std::to_string(st.st_mtimespec.tv_nsec) +
           ":" + std::to_string(st.st_size) + "\n";
    return true;
}
inline bool snapshot(const std::vector<std::string>& order, std::string& out) {
    out.clear(); std::set<std::string> seen, dirs;
    for (const auto& audio : order) {
        if (seen.insert(audio).second && !stamp(audio, true, out)) return false;
        const std::string dir = fs::path(audio).parent_path().string();
        if (!dirs.insert(dir).second) continue;
        struct stat st{};
        if (::stat(dir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) return false;
        const std::string signature = hex(dir) + ":dir:" + std::to_string(st.st_mtimespec.tv_sec) + ":" +
            std::to_string(st.st_mtimespec.tv_nsec) + ":" + std::to_string(st.st_ctimespec.tv_sec) + ":" +
            std::to_string(st.st_ctimespec.tv_nsec) + "\n";
        out += signature;
        struct DirMemo { std::string signature; std::vector<std::string> paths; };
        static std::mutex memoMu;
        static std::map<std::string, DirMemo> memo;
        std::vector<std::string> found; bool known = false;
        {
            std::lock_guard<std::mutex> lk(memoMu);
            auto it = memo.find(dir);
            if (it != memo.end() && it->second.signature == signature) { found = it->second.paths; known = true; }
        }
        if (!known) {
            // Enumerate only after a directory change (or first access in this process).
            auto lower = [](std::string s) {
                for (auto& c : s) if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
                return s;
            };
            std::set<std::string> names;
            for (const auto& p : pictures(audio)) names.insert(lower(fs::path(p).filename().string()));
            std::error_code ec; fs::directory_iterator it(dir, ec), end;
            if (ec) return false;
            for (; it != end; it.increment(ec)) {
                if (ec) return false;
                // Case-insensitive volumes can resolve cover.jpg to COVER.JPG; track
                // all ASCII case variants so that an in-place update is never missed.
                if (names.count(lower(it->path().filename().string()))) found.push_back(it->path().string());
            }
            if (ec) return false;
            std::sort(found.begin(), found.end());
            std::lock_guard<std::mutex> lk(memoMu);
            if (memo.size() >= 1024) memo.erase(memo.begin());
            memo[dir] = {signature, found};
        }
        for (const auto& p : found) if (!stamp(p, false, out)) return false;
    }
    return !out.empty();
}
inline std::string mime_of(const std::vector<unsigned char>& b) {
    if (b.size() > 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return "image/png";
    if (b.size() > 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return "image/jpeg";
    if (b.size() > 12 && std::string(b.begin(), b.begin() + 4) == "RIFF" &&
        std::string(b.begin() + 8, b.begin() + 12) == "WEBP") return "image/webp";
    return {};
}
inline bool read_image(const std::string& path, std::vector<unsigned char>& bytes, std::string& mime) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return false;
    const auto n = f.tellg();
    if (n <= 64 || n > (std::streamoff)kMaxImageBytes) return false;
    std::vector<unsigned char> b((size_t)n); f.seekg(0);
    if (!f.read((char*)b.data(), n)) return false;
    const std::string m = mime_of(b); if (m.empty()) return false;
    bytes = std::move(b); mime = m; return true;
}
inline bool read(const std::string& key, const std::string& fingerprint, Entry& entry) {
    if (!valid_key(key)) return false;
    const std::string base = (fs::path(root()) / key).string();
    std::ifstream f(base + ".meta", std::ios::binary | std::ios::ate);
    if (!f || f.tellg() > 1024 * 1024) return false;
    f.seekg(0);
    std::string version, source, fp, mime; long long captured = 0; uint64_t count = 0, digest = 0;
    if (!std::getline(f, version) || version != "RLPlayerLocalCover1" || !std::getline(f, source) ||
        !std::getline(f, fp) || !std::getline(f, mime) || !(f >> captured >> count >> digest)) return false;
    if (source.empty() || captured <= 0 || fp != hex(fingerprint)) return false;
    Entry got; std::string actualMime;
    if (!read_image(base + ".img", got.bytes, actualMime) || actualMime != mime || count != got.bytes.size() ||
        digest != hash(got.bytes.data(), got.bytes.size())) return false;
    // Source is hex encoded in metadata; only used diagnostically, never as a read path.
    got.source = source; got.fingerprint = fingerprint; got.mime = mime;
    entry = std::move(got); return true;
}
inline bool write(const std::string& key, const Entry& entry) {
    if (!valid_key(key) || entry.bytes.empty() || entry.bytes.size() > kMaxImageBytes ||
        mime_of(entry.bytes) != entry.mime || entry.fingerprint.empty()) return false;
    std::error_code ec; fs::create_directories(root(), ec); if (ec) return false;
    const std::string base = (fs::path(root()) / key).string();
    static std::atomic<uint64_t> seq{0};
    const std::string suffix = "." + std::to_string(getpid()) + "." + std::to_string(seq.fetch_add(1)) + ".part";
    const std::string img = base + ".img" + suffix, meta = base + ".meta" + suffix;
    auto cleanup = [&] { fs::remove(img, ec); fs::remove(meta, ec); };
    {
        std::ofstream f(img, std::ios::binary | std::ios::trunc);
        f.write((const char*)entry.bytes.data(), entry.bytes.size()); f.close();
        if (!f) { cleanup(); return false; }
    }
    {
        std::ofstream f(meta, std::ios::binary | std::ios::trunc);
        const auto now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
        f << "RLPlayerLocalCover1\n" << hex(entry.source) << '\n' << hex(entry.fingerprint) << '\n' << entry.mime << '\n'
          << now << '\n' << entry.bytes.size() << '\n' << hash(entry.bytes.data(), entry.bytes.size()) << '\n';
        f.close(); if (!f) { cleanup(); return false; }
    }
    fs::rename(img, base + ".img", ec); if (ec) { cleanup(); return false; }
    // Meta commits the pair; racing/crashed writers can only cause a checksum miss, never stale success.
    fs::rename(meta, base + ".meta", ec); const bool ok = !ec; cleanup(); return ok;
}
// The platform process API accepts a command line, not a shell. Quote using its
// backslash/quote grammar, including trailing backslashes before the closing quote.
inline std::string quote(const std::string& s) {
    std::string out = "\""; size_t slash = 0;
    for (char c : s) {
        if (c == '\\') { ++slash; continue; }
        out.append(c == '"' ? slash * 2 + 1 : slash, '\\'); slash = 0; out += c;
    }
    out.append(slash * 2, '\\'); return out + '"';
}
// Nonblocking same-album singleflight, shared across Library instances and TUs.
inline std::mutex& flight_mu() { static std::mutex m; return m; }
inline std::set<std::string>& flights() { static std::set<std::string> keys; return keys; }
struct Flight {
    std::string key; bool held;
    explicit Flight(const std::string& k) : key(k) {
        std::lock_guard<std::mutex> lk(flight_mu()); held = flights().insert(key).second;
    }
    ~Flight() { if (held) { std::lock_guard<std::mutex> lk(flight_mu()); flights().erase(key); } }
    Flight(const Flight&) = delete;
    Flight& operator=(const Flight&) = delete;
};

// ===========================================================================
// 缩略图磁盘缓存（2026-11 beta9 封面加载性能：网格卡片只取 <=512px JPEG）
//
// 为什么要单独一层、单独一个目录：全尺寸内嵌封面缓存（上面 read/write 那套）继续服务
// 详情页/下载，它的文件名、命中口径、字节上限一律不动；网格只需要小图，另存
// <coverdir>/thumb/（coverdir = root() 的父目录；RLPLAYER_COVER_DIR 覆盖时随之隔离）。
//
// 失效口径：token = 源音频文件的 "<mtime_sec>:<mtime_nsec>:<size>"。源文件一改
// （换封面/重新刮削/重新编码），token 立刻变化，旧缩略图自然失配而不是误命中。
// 提交顺序：先 rename .jpg 再 rename .meta（meta 最后提交）—— 崩溃/并发最多让两文件
// 失配（下次重新生成），不可能把半张图当命中。
// ===========================================================================
constexpr int kThumbMaxEdge = 512;
constexpr int kThumbQuality = 80;
constexpr size_t kMinThumbBytes = 64;
constexpr size_t kMaxThumbBytes = 4 * 1024 * 1024;
struct ThumbEntry {
    std::string token, mime;
    std::vector<unsigned char> bytes;
};
// <coverdir>/thumb：root() 的父目录是 coverdir（root() 本身是 coverdir/embed）。
inline std::string thumb_root() {
    return (fs::path(root()).parent_path() / "thumb").string();
}
// 源文件印章：只认普通文件；缺失/目录/其它类型一律 false（token 清空，不返回脏值）。
inline bool source_stamp(const std::string& srcPath, std::string& token) {
    token.clear();
    if (srcPath.empty()) return false;
    struct stat st{};
    if (::stat(srcPath.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return false;
    token = std::to_string(st.st_mtimespec.tv_sec) + ":" + std::to_string(st.st_mtimespec.tv_nsec) + ":" +
            std::to_string(st.st_size);
    return true;
}
// 全尺寸图片字节 -> <=512px JPEG（真正解码/缩放/EXIF 方向在 platform/image_thumb）。
inline bool make_thumb(const std::vector<unsigned char>& src, std::vector<unsigned char>& jpeg) {
    jpeg.clear();
    if (src.empty() || src.size() > kMaxImageBytes) return false;
    std::vector<unsigned char> encoded;
    if (!rta::platform::make_jpeg_thumb(src.data(), src.size(), kThumbMaxEdge, kThumbQuality, encoded))
        return false;
    if (encoded.size() < kMinThumbBytes || encoded.size() > kMaxThumbBytes) return false;
    if (encoded[0] != 0xff || encoded[1] != 0xd8 || encoded[2] != 0xff) return false;
    jpeg = std::move(encoded);
    return true;
}
// 读缓存：token 必须与调用方刚算出的源文件印章逐字节相等；meta 行序固定
// （RLPlayerCoverThumb1 / token / mime / size / fnv hash），图片按缩略图自己的
// 64 B..4 MB 口径校验，不借用 read_image() 的 32 MB 全尺寸上限。
inline bool read_thumb(const std::string& key, const std::string& token, ThumbEntry& out) {
    if (!valid_key(key) || token.empty()) return false;
    const std::string base = (fs::path(thumb_root()) / key).string();
    std::ifstream meta(base + ".meta", std::ios::binary | std::ios::ate);
    if (!meta) return false;
    const auto metaSize = meta.tellg();
    if (metaSize <= 0 || metaSize > 8192) return false;
    meta.seekg(0);
    std::string version, gotToken, mime;
    long long recorded = 0;
    uint64_t digest = 0;
    if (!std::getline(meta, version) || version != "RLPlayerCoverThumb1" ||
        !std::getline(meta, gotToken) || !std::getline(meta, mime) || !(meta >> recorded >> digest))
        return false;
    if (gotToken != token || mime != "image/jpeg" || recorded < (long long)kMinThumbBytes ||
        recorded > (long long)kMaxThumbBytes)
        return false;
    std::ifstream img(base + ".jpg", std::ios::binary | std::ios::ate);
    if (!img) return false;
    const auto imgSize = img.tellg();
    if (imgSize < (std::streamoff)kMinThumbBytes || imgSize > (std::streamoff)kMaxThumbBytes ||
        imgSize != (std::streamoff)recorded)
        return false;
    std::vector<unsigned char> bytes((size_t)imgSize);
    img.seekg(0);
    if (!img.read((char*)bytes.data(), (std::streamsize)imgSize)) return false;
    if (bytes[0] != 0xff || bytes[1] != 0xd8 || bytes[2] != 0xff) return false;
    if (digest != hash(bytes.data(), bytes.size())) return false;
    out.token = gotToken;
    out.mime = mime;
    out.bytes = std::move(bytes);
    return true;
}
// 原子写缓存：.jpg.part + .meta.part（pid+序号后缀）各写完、rename 图片、最后 rename meta。
// meta 一旦可见就代表图片已就位；任何一步失败清掉临时文件返回 false，绝不留下半个缓存。
inline bool write_thumb(const std::string& key, const std::string& token,
                        const std::vector<unsigned char>& jpeg) {
    if (!valid_key(key) || token.empty() || jpeg.size() < kMinThumbBytes ||
        jpeg.size() > kMaxThumbBytes)
        return false;
    if (jpeg[0] != 0xff || jpeg[1] != 0xd8 || jpeg[2] != 0xff) return false;
    std::error_code ec;
    fs::create_directories(thumb_root(), ec);
    if (ec) return false;
    const std::string base = (fs::path(thumb_root()) / key).string();
    static std::atomic<uint64_t> seq{0};
    const std::string suffix = "." + std::to_string(getpid()) + "." + std::to_string(seq.fetch_add(1)) + ".part";
    const std::string img = base + ".jpg" + suffix, meta = base + ".meta" + suffix;
    auto cleanup = [&] { fs::remove(img, ec); fs::remove(meta, ec); };
    {
        std::ofstream f(img, std::ios::binary | std::ios::trunc);
        f.write((const char*)jpeg.data(), (std::streamsize)jpeg.size());
        f.close();
        if (!f) { cleanup(); return false; }
    }
    {
        std::ofstream f(meta, std::ios::binary | std::ios::trunc);
        f << "RLPlayerCoverThumb1\n" << token << '\n' << "image/jpeg" << '\n' << jpeg.size() << '\n'
          << hash(jpeg.data(), jpeg.size()) << '\n';
        f.close();
        if (!f) { cleanup(); return false; }
    }
    fs::rename(img, base + ".jpg", ec);
    if (ec) { cleanup(); return false; }
    fs::rename(meta, base + ".meta", ec);
    const bool ok = !ec;
    cleanup();
    return ok;
}

} // namespace rta::net::local_cover
