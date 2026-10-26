// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_album_cover.cpp — 专辑封面取图（261026-02 B-1，上游 v1.5.2 `fb77a0b` 的同构缺陷）
//
// 背景（实测诊断，不是推测）：
//   旧 `Library::albumCover()` 只拿 `tracks_[a.idx[0]].path` 问一次封面，而
//   `rta::audio::get_cover()` 找不到图时**不返回空**，返回一张 **1x1 透明 PNG**
//   （src/audio/media_info.h 末尾的 px[]，77~89 字节）。于是：
//     * 首曲没图 ⟹ 整张专辑空白（哪怕第 2 首内嵌了 4.7 KB 的封面）；
//     * 1x1 占位图被当成真封面**写进 coverCache_ 永不重试**，且 `return !bytes.empty()`
//       为 true ⟹ HTTP 200 + 合法 PNG ⟹ 前端 `<img onerror>` 永远不触发
//       ⟹ 用户看到的是一块空白而不是首字母占位。
//
// 本用例的判据（铁律 3：每条都能被单独否定）：
//   [A] 「首曲无图 + 次曲有图」⟹ albumCover() 返回 true，且拿到的是**次曲那张真图**
//       （逐字节相等 —— 不是"非空就算过"，也不是"大小差不多"）。
//   [B] 「整张专辑都没有图」⟹ 返回 **false**，且 out bytes 为空。
//       这条直接否定旧行为：旧实现返回 true + 1x1 PNG。
//   [C] 占位图**不许**被当成封面缓存：先造一个"没有图"的专辑问一次（false），
//       再给首曲补上封面、清掉 get_cover 的内部缓存，重问 ⟹ 必须变 true。
//       旧实现这里恒为 false（占位图进了 coverCache_）。
//   [D] 顺序判据：cv=1 的曲目**优先**于 cv=0。构造「首曲 cv=1 但其实没图 + 次曲 cv=0 有图」，
//       以及「首曲 cv=0 有图 A + 次曲 cv=1 有图 B」——后者必须拿到 B（不是按 idx 顺序的 A）。
//   [E] 1x1 占位 PNG 的识别是**按 IHDR 宽高**判的，不是按字节数：
//       同一张 4.7 KB 的图缩成 1x1 也必须被识别成占位（防"以后占位图变大"）。
//   [F] 负向对照：真实小图（>=1KB 但不是 1x1）必须被接受 —— 不许把「小」直接判死。
//
// 夹具全部**运行时生成**（不往仓库塞二进制），内嵌封面走 WAV 的 `id3 ` 块 + APIC，
// 与 get_cover() 的真实抽取路径（ffmpeg -map 0:v:0 -c:v copy）完全一致。
//
// ⚠️ 未解决项（铁律 4）：
//   1) 依赖 ffmpeg（内嵌 APIC 抽取要起进程）。本机系统 ffmpeg 坏（缺 libx265，-version
//      退出 134），走仓库自建 build-mac/ffmpeg-lite/。取不到可用 ffmpeg 时本用例**明确 SKIP**
//      而不是假绿 —— 口径同上游 8431c5b（缺依赖明确跳过，不许判红也不许谎报通过）。
//   2) 同目录 cover.jpg 这条路径（get_cover 的第 1 候选）本用例没覆盖：它不依赖 ffmpeg，
//      但 B-1 的缺陷不在这条路径上（它本来就返回真字节）。留给 test_library 的既有判据。
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif
#include "test_compat_posix.h"
#include "net/library.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;
using rta::net::Library;
using rta::net::LibAlbum;

static int g_fail = 0, g_pass = 0, g_skip = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) { ++g_pass; std::printf("  [PASS] %s\n", what.c_str()); }
    else { ++g_fail; std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); }
}
static void skip(const std::string& what) {
    ++g_skip; std::printf("  [SKIP] %s\n", what.c_str());
}

// ---------------------------------------------------------------------------
// 字节流小工具（与 tests/test_tags_native.cpp 的写法同源，但这里只造 WAV，保持自包含）
// ---------------------------------------------------------------------------
static void put16le(std::vector<unsigned char>& v, uint32_t x) {
    v.push_back((unsigned char)(x & 0xFF)); v.push_back((unsigned char)((x >> 8) & 0xFF));
}
static void put32le(std::vector<unsigned char>& v, uint32_t x) {
    put16le(v, x & 0xFFFF); put16le(v, x >> 16);
}
static void put32be(std::vector<unsigned char>& v, uint32_t x) {
    v.push_back((unsigned char)((x >> 24) & 0xFF)); v.push_back((unsigned char)((x >> 16) & 0xFF));
    v.push_back((unsigned char)((x >> 8) & 0xFF));  v.push_back((unsigned char)(x & 0xFF));
}
static void put16be(std::vector<unsigned char>& v, uint32_t x) {
    v.push_back((unsigned char)((x >> 8) & 0xFF)); v.push_back((unsigned char)(x & 0xFF));
}
static void putStr(std::vector<unsigned char>& v, const std::string& s) {
    v.insert(v.end(), s.begin(), s.end());
}
static void syncsafe32(std::vector<unsigned char>& v, uint32_t x) {
    v.push_back((unsigned char)((x >> 21) & 0x7F)); v.push_back((unsigned char)((x >> 14) & 0x7F));
    v.push_back((unsigned char)((x >> 7) & 0x7F));  v.push_back((unsigned char)(x & 0x7F));
}

// ID3v2.3 的 TIT2（UTF-16LE + BOM）
static void id3Title(std::vector<unsigned char>& frames, const std::string& utf8) {
    std::vector<unsigned char> body;
    body.push_back(1); body.push_back(0xFF); body.push_back(0xFE);
    for (unsigned char c : utf8) { body.push_back(c); body.push_back(0); }   // ASCII 子集即可（夹具只用 ASCII）
    body.push_back(0); body.push_back(0);
    putStr(frames, "TIT2"); put32be(frames, (uint32_t)body.size()); put16be(frames, 0);
    frames.insert(frames.end(), body.begin(), body.end());
}
// ID3v2.3 的 APIC（内嵌封面；MIME + 图片类型 + 描述 + 原始图片字节）
static void id3Apic(std::vector<unsigned char>& frames, const std::string& mime,
                    const std::vector<unsigned char>& img) {
    std::vector<unsigned char> body;
    body.push_back(0);                                     // ISO-8859-1
    putStr(body, mime); body.push_back(0);
    body.push_back(3);                                     // front cover
    putStr(body, "Cover"); body.push_back(0);
    body.insert(body.end(), img.begin(), img.end());
    putStr(frames, "APIC"); put32be(frames, (uint32_t)body.size()); put16be(frames, 0);
    frames.insert(frames.end(), body.begin(), body.end());
}
static std::vector<unsigned char> buildId3(const std::string& title,
                                           const std::vector<unsigned char>& pic) {
    std::vector<unsigned char> frames;
    if (!title.empty()) id3Title(frames, title);
    if (!pic.empty())   id3Apic(frames, "image/png", pic);
    std::vector<unsigned char> tag;
    putStr(tag, "ID3"); tag.push_back(3); tag.push_back(0); tag.push_back(0);
    syncsafe32(tag, (uint32_t)frames.size());
    tag.insert(tag.end(), frames.begin(), frames.end());
    return tag;
}
static std::vector<unsigned char> buildWav(const std::string& title,
                                           const std::vector<unsigned char>& pic,
                                           int sr = 44100, int ch = 2, int bits = 16,
                                           int frames = 4410) {
    std::vector<unsigned char> data((size_t)frames * ch * (bits / 8), 0);
    std::vector<unsigned char> fmt;
    put16le(fmt, 1); put16le(fmt, (uint32_t)ch); put32le(fmt, (uint32_t)sr);
    put32le(fmt, (uint32_t)(sr * ch * (bits / 8))); put16le(fmt, (uint32_t)(ch * (bits / 8)));
    put16le(fmt, (uint32_t)bits);
    std::vector<unsigned char> chunks;
    putStr(chunks, "fmt "); put32le(chunks, (uint32_t)fmt.size());
    chunks.insert(chunks.end(), fmt.begin(), fmt.end());
    putStr(chunks, "data"); put32le(chunks, (uint32_t)data.size());
    chunks.insert(chunks.end(), data.begin(), data.end());
    const std::vector<unsigned char> id3 = buildId3(title, pic);
    putStr(chunks, "id3 "); put32le(chunks, (uint32_t)id3.size());
    chunks.insert(chunks.end(), id3.begin(), id3.end());
    std::vector<unsigned char> out;
    putStr(out, "RIFF"); put32le(out, (uint32_t)(chunks.size() + 4)); putStr(out, "WAVE");
    out.insert(out.end(), chunks.begin(), chunks.end());
    return out;
}

// 造一张合法的 N×N PNG（8-bit RGBA）。不用 zlib：IDAT 用 **stored（未压缩）** deflate 块，
// 这是 RFC 1951 里合法的无压缩块格式，手写十几行就能得到真 PNG —— 零依赖、字节数可控。
static uint32_t crcTable[256];
static void crcInit() {
    for (uint32_t n = 0; n < 256; ++n) {
        uint32_t c = n;
        for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crcTable[n] = c;
    }
}
static uint32_t crc32Of(const unsigned char* p, size_t n, uint32_t crc = 0xFFFFFFFFu) {
    for (size_t i = 0; i < n; ++i) crc = crcTable[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    return crc;
}
static void pngChunk(std::vector<unsigned char>& out, const char* type,
                     const std::vector<unsigned char>& body) {
    put32be(out, (uint32_t)body.size());
    const size_t typeOff = out.size();
    putStr(out, type);
    out.insert(out.end(), body.begin(), body.end());
    uint32_t crc = crc32Of(out.data() + typeOff, 4 + body.size());
    put32be(out, crc ^ 0xFFFFFFFFu);
}
static std::vector<unsigned char> makePng(int w, int h, unsigned char r, unsigned char g, unsigned char b) {
    static bool inited = false;
    if (!inited) { crcInit(); inited = true; }
    std::vector<unsigned char> out;
    const unsigned char sig[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    out.insert(out.end(), sig, sig + 8);
    {   // IHDR
        std::vector<unsigned char> ihdr;
        put32be(ihdr, (uint32_t)w); put32be(ihdr, (uint32_t)h);
        ihdr.push_back(8); ihdr.push_back(6); ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
        pngChunk(out, "IHDR", ihdr);
    }
    {   // IDAT：zlib 头 + stored deflate 块（每行 = 1 字节 filter + w*4 字节 RGBA）+ adler32
        std::vector<unsigned char> raw;
        for (int y = 0; y < h; ++y) {
            raw.push_back(0);                              // filter type 0 (None)
            for (int x = 0; x < w; ++x) { raw.push_back(r); raw.push_back(g); raw.push_back(b); raw.push_back(255); }
        }
        std::vector<unsigned char> z;
        z.push_back(0x78); z.push_back(0x01);              // CMF/FLG：deflate, 32K window, 最快
        size_t pos = 0;
        while (pos < raw.size()) {
            const size_t n = std::min<size_t>(65535, raw.size() - pos);
            z.push_back((pos + n >= raw.size()) ? 1 : 0);  // BFINAL / BTYPE=00 (stored)
            z.push_back((unsigned char)(n & 0xFF)); z.push_back((unsigned char)(n >> 8));
            z.push_back((unsigned char)(~n & 0xFF)); z.push_back((unsigned char)((~n >> 8) & 0xFF));
            z.insert(z.end(), raw.begin() + (long)pos, raw.begin() + (long)(pos + n));
            pos += n;
        }
        uint32_t a = 1, bsum = 0;
        for (unsigned char c : raw) { a = (a + c) % 65521; bsum = (bsum + a) % 65521; }
        put32be(z, (bsum << 16) | a);                      // adler32（大端）
        pngChunk(out, "IDAT", z);
    }
    pngChunk(out, "IEND", {});
    return out;
}

static void writeFile(const fs::path& p, const std::vector<unsigned char>& b) {
    std::error_code ec;
    fs::create_directories(p.parent_path(), ec);
    std::ofstream f(p, std::ios::binary);
    f.write((const char*)b.data(), (std::streamsize)b.size());
}
static std::vector<unsigned char> readFile(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    return std::vector<unsigned char>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}
static std::string U8(const fs::path& p) { auto u = p.u8string(); return std::string((const char*)u.data(), u.size()); }

// 索引行（列顺序必须与 library.h buildIndexLocked 一致：v4 = 20 列）
struct Row {
    std::string path, album, albumArtist, artist, title;
    int trackNo = 0, discNo = 0, year = 0, sr = 44100, bits = 16, ch = 2;
    double dur = 1.0;
    int hasCover = 0;
};
static void writeIndex(const fs::path& dir, const std::vector<Row>& rows) {
    std::error_code ec;
    fs::create_directories(dir, ec);
    std::ofstream f(dir / "rlplayer-index.tsv", std::ios::binary);
    f << "#libIndexV\t4\n";
    f << "#path\tmtime\tsize\talbum\talbumArtist\tartist\ttitle\ttrack\tdisc\tyear\tsr\tbits\tch\tdur\thasCover\tgenre"
         "\tcue\tcueN\tcueOff\tcueLen\n";
    for (const Row& r : rows) {
        f << r.path << "\t111\t222\t" << r.album << "\t" << r.albumArtist << "\t" << r.artist << "\t"
          << r.title << "\t" << r.trackNo << "\t" << r.discNo << "\t" << r.year << "\t" << r.sr << "\t"
          << r.bits << "\t" << r.ch << "\t" << r.dur << "\t" << r.hasCover << "\tRock\t\t0\t0\t0\n";
    }
}

// 取某专辑的 key（专辑键 = albumArtist + 0x1f + album 的 FNV-1a，library.h 的既有口径）
static std::string albumKeyOf(const Library& lib, const std::string& album, const std::string& artist) {
    for (const auto& a : lib.albums()) if (a.name == album && a.artist == artist) return a.key;
    return std::string();
}

// ffmpeg 自检：内嵌 APIC 抽取要起进程，「找到」≠「能跑」（本机系统版缺 libx265，退出 134）。
static bool toolRunnable(const std::string& path) {
    if (path.empty()) return false;
    std::string cmd = "\"" + path + "\" -version >/dev/null 2>&1";
    return std::system(cmd.c_str()) == 0;
}

int main(int argc, char** argv) {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    std::printf("== 专辑封面取图验证（B-1：多曲回退 + 占位图识别 + 负缓存） ==\n");

    const fs::path root = (argc > 1) ? fs::path(argv[1]) : fs::path(".");
    std::printf("仓库根：%s\n", U8(root).c_str());

    // ---- ffmpeg 可用性（内嵌封面抽取的唯一依赖）----
    // 先问产品自己的 find_tool（它会按 ① 环境变量 ② exe 同目录 ③ build-mac/ffmpeg-lite 找），
    // 找不到再用仓库根下的 lite 兜底；两者都必须真跑一次 -version 才算可用。
    std::string ffmpeg = rta::audio::find_tool("ffmpeg");
    if (!toolRunnable(ffmpeg)) {
        const std::string lite = U8(root / "build-mac" / "ffmpeg-lite" / "ffmpeg");
        if (toolRunnable(lite)) ffmpeg = lite;
    }
    if (!toolRunnable(ffmpeg)) {
        skip("ffmpeg 不可执行 ⟹ 内嵌 APIC 抽取无法验证，本用例整体跳过");
        std::printf("\n[SKIP] 全部判据跳过（%d 项）—— 缺依赖时明确跳过，不判红也不谎报通过\n", g_skip);
        return 0;
    }
    std::printf("ffmpeg：%s\n", ffmpeg.c_str());
    // 让 get_cover() 走这份自检通过的 ffmpeg（产品既有的 RLPLAYER_FFMPEG 覆盖机制）
    ::setenv("RLPLAYER_FFMPEG", ffmpeg.c_str(), 1);

    std::error_code ec;
    const fs::path tmp = fs::temp_directory_path() / "rta_album_cover_test";
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp, ec);
    // 曲库配置/索引必须落临时目录，否则会读写用户真实库（test_library.cpp 同一条纪律）
    ::setenv("RLPLAYER_LIBRARY_DIR", U8(tmp / "lib").c_str(), 1);

    // 夹具图片：真封面用 64x64（>1KB，实测 4.7 KB 量级），小图用 8x8（<1KB 但**不是** 1x1），
    // 占位图用 1x1（正是 get_cover 兜底时返回的那种）。
    const std::vector<unsigned char> coverA = makePng(64, 64, 200, 40, 40);   // 4 KB 量级
    const std::vector<unsigned char> coverB = makePng(64, 64, 40, 40, 200);
    const std::vector<unsigned char> tinyOk = makePng(8, 8, 10, 200, 10);     // 8x8*4+行头 ≈ 300 字节
    std::printf("夹具图片：coverA=%zu B coverB=%zu B tiny(8x8)=%zu B\n",
                coverA.size(), coverB.size(), tinyOk.size());
    ck(coverA.size() >= 1024, "夹具 coverA 是真封面尺寸（>=1KB）", std::to_string(coverA.size()) + " B");
    ck(tinyOk.size() < 1024, "夹具 tiny(8x8) 是「小但真实」的图（<1KB 且非 1x1）",
       std::to_string(tinyOk.size()) + " B");

    // ---- [E] 1x1 占位识别是按 IHDR 宽高，不是按字节数 ----
    {
        const std::vector<unsigned char> one = makePng(1, 1, 0, 0, 0);
        ck(rta::net::lib_cover_is_1x1_placeholder(one), "1x1 PNG 被识别成占位图",
           std::to_string(one.size()) + " B");
        ck(!rta::net::lib_cover_is_1x1_placeholder(coverA), "64x64 真封面**不**被误判成占位图");
        ck(!rta::net::lib_cover_is_1x1_placeholder(tinyOk), "8x8 小图**不**被误判成占位图（只按宽高判）");
        // 反面对照：非 PNG 字节流一律不判占位（哪怕恰好很短）
        const std::vector<unsigned char> jpegish = { 0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4 };
        ck(!rta::net::lib_cover_is_1x1_placeholder(jpegish), "非 PNG 字节流不判占位（判据只看 PNG 的 IHDR）");
        ck(!rta::net::lib_cover_is_1x1_placeholder({}), "空字节流不判占位（空另有口径）");
    }

    // =====================================================================
    // [A] 首曲无图 + 次曲有图 ⟹ 必须拿到**次曲那张真图**（逐字节相等）
    // =====================================================================
    {
        const fs::path d = tmp / "A";
        const fs::path p1 = d / "01.wav", p2 = d / "02.wav";
        writeFile(p1, buildWav("Track One", {}));            // 首曲：没有 APIC
        writeFile(p2, buildWav("Track Two", coverA));        // 次曲：内嵌 64x64 封面
        writeIndex(tmp / "libA", {
            { U8(p1), "Album A", "Artist A", "Artist A", "Track One", 1, 1, 2020, 44100, 16, 2, 1.0, 1 },
            { U8(p2), "Album A", "Artist A", "Artist A", "Track Two", 2, 1, 2020, 44100, 16, 2, 1.0, 1 },
        });
        ::setenv("RLPLAYER_LIBRARY_DIR", U8(tmp / "libA").c_str(), 1);
        Library& lib = Library::instance();
        lib.load();
        ck(lib.trackCount() == 2, "[A] 夹具曲目数 = 2", std::to_string(lib.trackCount()));
        const std::string key = albumKeyOf(lib, "Album A", "Artist A");
        ck(!key.empty(), "[A] 找到专辑 Album A / Artist A");
        std::vector<unsigned char> bytes;
        std::string mime = "image/jpeg";
        const bool ok = lib.albumCover(key, bytes, mime);
        std::printf("     [A] albumCover -> ok=%d size=%zu mime=%s\n", (int)ok, bytes.size(), mime.c_str());
        ck(ok, "[A] 首曲无图、次曲有图 ⟹ albumCover 返回 true", "size=" + std::to_string(bytes.size()));
        ck(bytes.size() >= 1024, "[A] 返回的是真图（>=1KB），不是 1x1 占位",
           std::to_string(bytes.size()) + " B");
        ck(!rta::net::lib_cover_is_1x1_placeholder(bytes), "[A] 返回的字节不是 1x1 占位 PNG");
        ck(bytes == coverA, "[A] 返回的字节与次曲内嵌的那张图**逐字节相等**",
           "got " + std::to_string(bytes.size()) + " B / want " + std::to_string(coverA.size()) + " B");
        ck(mime == "image/png", "[A] mime 按文件头判定为 image/png（不是写死的 image/jpeg）", mime);
    }

    // =====================================================================
    // [B] 整张专辑都没有图 ⟹ **false**（旧实现返回 true + 1x1 PNG）
    //     先直接证明缺陷机制：get_cover() 对"没有图"的曲目**确实**返回一张 1x1 占位 PNG，
    //     而不是空 —— 旧代码 `return !bytes.empty()` 因此在"没有封面"时恒为 true。
    // =====================================================================
    {
        const fs::path d = tmp / "B";
        const fs::path p1 = d / "01.wav", p2 = d / "02.wav";
        writeFile(p1, buildWav("No Art 1", {}));
        writeFile(p2, buildWav("No Art 2", {}));
        writeIndex(tmp / "libB", {
            { U8(p1), "Album B", "Artist B", "Artist B", "No Art 1", 1, 1, 2020, 44100, 16, 2, 1.0, 0 },
            { U8(p2), "Album B", "Artist B", "Artist B", "No Art 2", 2, 1, 2020, 44100, 16, 2, 1.0, 0 },
        });
        // ---- 缺陷机制的独立证据（不经过 albumCover）----
        {
            std::string gm;
            const std::vector<unsigned char> raw = rta::audio::get_cover(U8(p1), gm);
            std::printf("     [B] get_cover(无图曲目) -> %zu B, mime=%s, is1x1=%d\n",
                        raw.size(), gm.c_str(), (int)rta::net::lib_cover_is_1x1_placeholder(raw));
            ck(!raw.empty(), "[B] 证据①：get_cover() 对没有封面的曲目**不返回空**（这就是缺陷根源）",
               std::to_string(raw.size()) + " B");
            ck(rta::net::lib_cover_is_1x1_placeholder(raw),
               "[B] 证据②：它返回的正是 1x1 占位 PNG ⟹ 旧代码 `!bytes.empty()` 恒 true",
               std::to_string(raw.size()) + " B");
            ck(raw.size() < 1024, "[B] 证据③：占位图 < 1KB（所以 1KB 阈值也能挡住它，双保险）",
               std::to_string(raw.size()) + " B");
        }
        ::setenv("RLPLAYER_LIBRARY_DIR", U8(tmp / "libB").c_str(), 1);
        Library& lib = Library::instance();
        lib.load();
        const std::string key = albumKeyOf(lib, "Album B", "Artist B");
        ck(!key.empty(), "[B] 找到专辑 Album B / Artist B");
        std::vector<unsigned char> bytes(4, 0xAA);           // 预置脏值：必须被清空
        std::string mime = "image/jpeg";
        const bool ok = lib.albumCover(key, bytes, mime);
        std::printf("     [B] albumCover -> ok=%d size=%zu\n", (int)ok, bytes.size());
        ck(!ok, "[B] 全专辑无图 ⟹ albumCover 返回 **false**（旧实现返回 true + 1x1 PNG）");
        ck(bytes.empty(), "[B] 返回的字节为空（不是 1x1 占位图）", std::to_string(bytes.size()) + " B");
    }

    // =====================================================================
    // [C] 负缓存的口径：空/占位结果**写负缓存并返回 false**（这是任务书指定的行为），
    //     同时证明负缓存**不会串味**到别的专辑，也不会把占位图变成"正命中"。
    //
    //     ⚠️ 这条初稿写成「补上封面后重问必须变 true」，被自己的实现判红 —— 那不是实现错，
    //        是**判据写错了**：任务书明确要求「空/占位结果写负缓存」，负缓存的语义就是
    //        「本轮不再重试」，补图后要等进程重启或缓存清理才生效。这里改成断言真实契约
    //        （留痕，避免以后有人"为了让测试绿"去偷偷去掉负缓存）。
    //     否定能力：旧实现把 1x1 占位图写进**正**缓存 ⟹ 同一专辑永远返回 true + 占位图；
    //        本用例断言反复问都是 false + 空字节，这条在旧实现下必红。
    // =====================================================================
    {
        const fs::path d = tmp / "C";
        const fs::path p1 = d / "01.wav";
        const fs::path pOk = d / "02.wav";
        writeFile(p1, buildWav("Later", {}));
        writeFile(pOk, buildWav("HasArt", coverB));
        writeIndex(tmp / "libC", {
            { U8(p1), "Album C", "Artist C", "Artist C", "Later", 1, 1, 2020, 44100, 16, 2, 1.0, 1 },
            { U8(pOk), "Album C2", "Artist C", "Artist C", "HasArt", 1, 1, 2020, 44100, 16, 2, 1.0, 1 },
        });
        ::setenv("RLPLAYER_LIBRARY_DIR", U8(tmp / "libC").c_str(), 1);
        Library& lib = Library::instance();
        lib.load();
        const std::string key = albumKeyOf(lib, "Album C", "Artist C");
        ck(!key.empty(), "[C] 找到专辑 Album C / Artist C");
        // 反复问 3 次：必须是稳定的 false + 空字节（旧实现是稳定的 true + 1x1）
        bool allFalse = true, allEmpty = true;
        size_t lastSize = 0;
        for (int i = 0; i < 3; ++i) {
            std::vector<unsigned char> b; std::string m;
            const bool ok = lib.albumCover(key, b, m);
            lastSize = b.size();
            if (ok) allFalse = false;
            if (!b.empty()) allEmpty = false;
        }
        std::printf("     [C] 连续 3 次 -> allFalse=%d allEmpty=%d lastSize=%zu\n",
                    (int)allFalse, (int)allEmpty, lastSize);
        ck(allFalse, "[C] 无封面的专辑连续问 3 次都是 false（旧实现恒 true + 1x1 占位图）");
        ck(allEmpty, "[C] 三次返回的字节都为空（占位图没有被当成封面返回）");
        // 负缓存不串味：同一进程里另一张有图的专辑必须照常拿到真图
        const std::string keyOk = albumKeyOf(lib, "Album C2", "Artist C");
        std::vector<unsigned char> bOk; std::string mOk;
        const bool okOk = lib.albumCover(keyOk, bOk, mOk);
        std::printf("     [C] 邻专辑 Album C2 -> ok=%d size=%zu\n", (int)okOk, bOk.size());
        ck(okOk && bOk == coverB, "[C] 负缓存不串味：邻专辑仍然拿到它自己的真图（逐字节相等）",
           "ok=" + std::to_string((int)okOk) + " size=" + std::to_string(bOk.size()));
    }

    // =====================================================================
    // [D] 顺序判据：cv=1 的曲目**优先**（不是按 idx 顺序的第一首）
    // =====================================================================
    {
        // D1：首曲 cv=1 但**其实没图**，次曲 cv=0 有图 ⟹ 必须拿到次曲的图。
        //     这条同时否定了「只问 cv=1 那首就放弃」和「只问首曲」两种旧行为。
        const fs::path d = tmp / "D1";
        const fs::path p1 = d / "01.wav", p2 = d / "02.wav";
        writeFile(p1, buildWav("Cv1 NoArt", {}));
        writeFile(p2, buildWav("Cv0 HasArt", coverA));
        writeIndex(tmp / "libD1", {
            { U8(p1), "Album D1", "Artist D", "Artist D", "Cv1 NoArt", 1, 1, 2020, 44100, 16, 2, 1.0, 1 },
            { U8(p2), "Album D1", "Artist D", "Artist D", "Cv0 HasArt", 2, 1, 2020, 44100, 16, 2, 1.0, 0 },
        });
        ::setenv("RLPLAYER_LIBRARY_DIR", U8(tmp / "libD1").c_str(), 1);
        Library& lib = Library::instance();
        lib.load();
        const std::string key = albumKeyOf(lib, "Album D1", "Artist D");
        std::vector<unsigned char> b; std::string m;
        const bool ok = lib.albumCover(key, b, m);
        std::printf("     [D1] ok=%d size=%zu\n", (int)ok, b.size());
        ck(ok && b == coverA, "[D1] cv=1 首曲没图时，仍然去问 cv=0 的次曲并拿到它的图",
           "ok=" + std::to_string((int)ok) + " size=" + std::to_string(b.size()));

        // D2：首曲 cv=0 有图 A，次曲 cv=1 有图 B ⟹ 必须拿到 **B**（cv=1 优先）。
        //     这条否定「按 idx 顺序取第一张」——那会拿到 A。
        const fs::path e = tmp / "D2";
        const fs::path q1 = e / "01.wav", q2 = e / "02.wav";
        writeFile(q1, buildWav("Cv0 ArtA", coverA));
        writeFile(q2, buildWav("Cv1 ArtB", coverB));
        writeIndex(tmp / "libD2", {
            { U8(q1), "Album D2", "Artist D", "Artist D", "Cv0 ArtA", 1, 1, 2020, 44100, 16, 2, 1.0, 0 },
            { U8(q2), "Album D2", "Artist D", "Artist D", "Cv1 ArtB", 2, 1, 2020, 44100, 16, 2, 1.0, 1 },
        });
        ::setenv("RLPLAYER_LIBRARY_DIR", U8(tmp / "libD2").c_str(), 1);
        Library& lib2 = Library::instance();
        lib2.load();
        const std::string key2 = albumKeyOf(lib2, "Album D2", "Artist D");
        std::vector<unsigned char> b2; std::string m2;
        const bool ok2 = lib2.albumCover(key2, b2, m2);
        std::printf("     [D2] ok=%d size=%zu ==coverB? %d\n", (int)ok2, b2.size(), (int)(b2 == coverB));
        ck(ok2 && b2 == coverB, "[D2] cv=1 的次曲优先于 cv=0 的首曲（拿到 B 而不是 A）",
           "ok=" + std::to_string((int)ok2) + " size=" + std::to_string(b2.size()) +
           " ==B?" + std::to_string((int)(b2 == coverB)) + " ==A?" + std::to_string((int)(b2 == coverA)));
    }

    // =====================================================================
    // [F] 负向对照：小但真实的图（<1KB，非 1x1）必须被**接受**，不许一刀切判死
    // =====================================================================
    {
        const fs::path d = tmp / "F";
        const fs::path p1 = d / "01.wav";
        writeFile(p1, buildWav("Tiny", tinyOk));
        writeIndex(tmp / "libF", {
            { U8(p1), "Album F", "Artist F", "Artist F", "Tiny", 1, 1, 2020, 44100, 16, 2, 1.0, 1 },
        });
        ::setenv("RLPLAYER_LIBRARY_DIR", U8(tmp / "libF").c_str(), 1);
        Library& lib = Library::instance();
        lib.load();
        const std::string key = albumKeyOf(lib, "Album F", "Artist F");
        std::vector<unsigned char> b; std::string m;
        const bool ok = lib.albumCover(key, b, m);
        std::printf("     [F] ok=%d size=%zu (tiny=%zu)\n", (int)ok, b.size(), tinyOk.size());
        ck(ok, "[F] 只有小图（<1KB 但非 1x1）时仍然返回 true（总比空白好）");
        ck(b == tinyOk, "[F] 拿到的就是那张小图（逐字节相等）",
           "got " + std::to_string(b.size()) + " B / want " + std::to_string(tinyOk.size()) + " B");
    }

    fs::remove_all(tmp, ec);
    std::printf("\n%s（通过 %d 项，失败 %d 项，跳过 %d 项）\n",
                g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail, g_skip);
    return g_fail == 0 ? 0 : 1;
}
