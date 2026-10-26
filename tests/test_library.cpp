// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_library.cpp — 音乐库索引：解析 / 专辑分组 / 搜索 / 库根目录
//
// 判据说明（铁律 3）：这里验证的是「索引文件 -> 内存模型 -> 查询结果」这条链路，
// 用构造好的 TSV 直接喂进去，不依赖 ffprobe，也不依赖磁盘上有真实音频。
// 真实扫描的端到端验证放在 verify.ps1 的库扫描检查里（会用真文件跑）。
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "net/library.h"
#if !defined(_WIN32)
#include <iconv.h>
#endif
#include <cstdio>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include "test_compat_posix.h"   // POSIX 垫片：SetConsoleOutputCP/_putenv_s（macOS 门禁）

namespace fs = std::filesystem;
using rta::net::Library;

// fs::path -> UTF-8 窄串（不经 ANSI 代码页；索引里存的就是 UTF-8）
static std::string u8str(const fs::path& p) {
    const std::u8string u = p.u8string();
    return std::string(reinterpret_cast<const char*>(u.data()), u.size());
}

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) std::printf("  [PASS] %s\n", what);
    else { std::printf("  [FAIL] %s  %s\n", what, detail.c_str()); ++g_fail; }
}

int main() {
    SetConsoleOutputCP(CP_UTF8);
    std::printf("== 音乐库索引验证 ==\n");

    const fs::path tmp = fs::temp_directory_path() / "rta_lib_test";
    // 2026-10-25（macOS 单平台）：索引里的路径原来是 Windows 盘符字面量（D:\\Music\\...）。
    // 在 POSIX 上 fs::path(u8str(fixtureRoot / "Loose" / "solo.wav")).parent_path() 会退化，
    // 「无专辑标签 -> 用父目录名当专辑名」这条判据就会假失败（主控已踩过）。
    // 因此夹具路径改为 <tmp>/music/... 的真实层级——**判据与阈值不变**，只是让路径真有父目录。
    const fs::path fixtureRoot = tmp / "music";
    std::error_code ec;
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp, ec);
    const std::string oldCwd = fs::current_path().string();
    fs::current_path(tmp, ec);
    // 2026-10-23：库配置/索引默认落 exe 目录（修「升级后曲库变空」）。测试必须显式改到临时目录，
    // 否则会读写真实 exe 目录里的 rlplayer-library.conf / index.tsv，污染用户库并让断言全错。
    _putenv_s("RLPLAYER_LIBRARY_DIR", tmp.string().c_str());

    // 构造索引：2 张专辑 + 1 个没有专辑标签的目录级条目
    // 字段顺序必须与 library.h 的 load() 一致
    {
        std::ofstream f("rlplayer-index.tsv", std::ios::binary);
        // 2026-10-23：索引多了格式版本头（Library 会校验，不匹配就整份丢弃重建）。
        // 测试夹具必须与真实 saveIndexLocked() 的输出格式保持一致，否则加载后为空。
        f << "#libIndexV\t4\n";
        f << "#path\tmtime\tsize\talbum\talbumArtist\tartist\ttitle\ttrack\tdisc\tyear\tsr\tbits\tch\tdur\thasCover\tgenre"
             "\tcue\tcueN\tcueOff\tcueLen\n";
        auto row = [&](const std::string& path, const std::string& alb, const std::string& aa,
                       const std::string& art, const std::string& ttl, int trk, int disc,
                       int yr, int sr, int bits, int ch, double dur, int cov) {
            f << path << "\t111\t222\t" << alb << "\t" << aa << "\t" << art << "\t" << ttl
              << "\t" << trk << "\t" << disc << "\t" << yr << "\t" << sr << "\t" << bits
              << "\t" << ch << "\t" << dur << "\t" << cov << "\tRock" << "\t\t0\t0\t0\n";
        };
        row(u8str(fixtureRoot / "Beatles" / "Abbey Road" / "02.flac"), "Abbey Road", "The Beatles", "The Beatles", "Something", 2, 1, 1969, 44100, 16, 2, 182.0, 1);
        row(u8str(fixtureRoot / "Beatles" / "Abbey Road" / "01.flac"), "Abbey Road", "The Beatles", "The Beatles", "Come Together", 1, 1, 1969, 44100, 16, 2, 259.0, 1);
        // 同专辑名、不同专辑艺术家 -> 必须分成两张，不能合并
        row(u8str(fixtureRoot / "Other" / "Abbey Road" / "01.flac"), "Abbey Road", "Someone Else", "Someone Else", "Track A", 1, 1, 2001, 96000, 24, 2, 100.0, 0);
        // 多碟：第 2 碟应排在第 1 碟之后
        row(u8str(fixtureRoot / "Big" / "Live" / "d2t1.flac"), "Live Box", "Big Band", "Big Band", "Encore", 1, 2, 1990, 48000, 16, 2, 300.0, 0);
        row(u8str(fixtureRoot / "Big" / "Live" / "d1t1.flac"), "Live Box", "Big Band", "Big Band", "Overture", 1, 1, 1990, 48000, 16, 2, 200.0, 0);
        // 无专辑标签 -> 用父目录名当专辑名
        row(u8str(fixtureRoot / "Loose" / "solo.wav"), "", "", "无名氏", "即兴", 0, 0, 0, 44100, 16, 1, 60.0, 0);
    }

    Library& lib = Library::instance();
    lib.load();

    ck(lib.trackCount() == 6, "曲目数 = 6", "实际 " + std::to_string(lib.trackCount()));
    auto albums = lib.albums();
    ck(albums.size() == 4, "专辑数 = 4（同名不同艺术家不合并）", "实际 " + std::to_string(albums.size()));

    // 找 Abbey Road / The Beatles
    rta::net::LibAlbum ab;
    bool found = false;
    std::string abKey;
    for (auto& a : albums) if (a.name == "Abbey Road" && a.artist == "The Beatles") { ab = a; found = true; abKey = a.key; }
    ck(found, "能找到 Abbey Road / The Beatles");
    ck(ab.nTracks == 2, "该专辑 2 首", "实际 " + std::to_string(ab.nTracks));
    if (found && ab.idx.size() == 2) {
        rta::net::LibTrack t0, t1;
        lib.trackAt(ab.idx[0], t0);
        lib.trackAt(ab.idx[1], t1);
        ck(t0.trackNo == 1 && t1.trackNo == 2, "专辑内按音轨号排序（01 在 02 前）",
           "首曲 trackNo=" + std::to_string(t0.trackNo));
        ck(t0.title == "Come Together", "曲名解析正确", t0.title);
        ck(t0.sampleRate == 44100 && t0.bits == 16 && t0.channels == 2, "流参数解析正确");
    }
    ck(ab.hasCover, "专辑封面标记透传（02/01 有封面）");

    // 多碟排序
    for (auto& a : albums) if (a.name == "Live Box") {
        rta::net::LibTrack x, y;
        lib.trackAt(a.idx[0], x); lib.trackAt(a.idx[1], y);
        ck(x.discNo == 1 && y.discNo == 2, "多碟按碟号排序", "首曲 disc=" + std::to_string(x.discNo));
    }

    // 无专辑标签的兜底
    bool loose = false;
    for (auto& a : albums) if (a.name == "Loose") loose = true;
    ck(loose, "无专辑标签时用父目录名当专辑名");

    // 搜索
    ck(lib.search("abbey").size() == 3, "搜索 abbey 命中 3 首", "实际 " + std::to_string(lib.search("abbey").size()));
    ck(lib.search("OVERTURE").size() == 1, "搜索不区分大小写");
    ck(lib.search("即兴").size() == 1, "搜索支持 UTF-8 中文");
    ck(lib.search("不存在的词").empty(), "搜索无结果时返回空");
    ck(lib.search("", 100).size() == 6, "空串返回全部曲目");

    // 专辑键：稳定的十六进制
    ck(abKey.size() == 16 && abKey.find_first_not_of("0123456789abcdef") == std::string::npos,
       "专辑键是 16 位十六进制", abKey);
    ck(rta::net::fnv_hex("a") == rta::net::fnv_hex("a"), "哈希稳定");

    // 不存在的专辑
    rta::net::LibAlbum nope;
    ck(!lib.album("0000000000000000", nope), "查询不存在的专辑返回 false（除非真撞上哈希）");

    // 库根目录
    const std::string rootDir = (tmp / "music").string();
    fs::create_directories(rootDir, ec);
    ck(lib.addRoot(rootDir), "可添加库根目录");
    bool has = false;
    for (auto& r : lib.roots()) if (r == rootDir) has = true;
    ck(has, "根目录已记录");
    ck(!lib.addRoot(u8str(tmp / "不存在的目录")), "添加不存在的目录被拒绝");
    ck(lib.removeRoot(rootDir), "可移除库根目录");
    ck(fs::exists("rlplayer-library.conf"), "根目录落盘为 rlplayer-library.conf");

    // =======================================================================
    // [4] 261025-01 一.1/2/3/5/8（大面积扫描 / 中文路径 / 删除清理 / 切标签不重扫 / 快照 / try-catch 兜底）
    // =======================================================================
    std::printf("\n== [4] 中文路径 / 大库 / 删除清理 / 快照 ==\n");
    auto U = [](const char* s) { return fs::u8path(s); };
    auto p2u = [](const fs::path& p) {
        const std::u8string u = p.u8string();
        return std::string((const char*)u.data(), u.size());
    };
    // ---- 4.1 纯函数：UTF-8 校验与路径前缀判定 ----
    {
        ck(rta::net::lib_valid_utf8("/音乐/专辑"), "合法 UTF-8 路径通过校验");
        ck(!rta::net::lib_valid_utf8("/bad/\xC4\xE3\xBA\xC3"), "非 UTF-8 字节被拒");
        ck(rta::net::lib_path_under("/mu/a.flac", "/mu"), "前缀判定：子路径命中");
        ck(rta::net::lib_path_under("/MU/a.flac", "/mu"), "前缀判定：大小写不敏感");
        ck(!rta::net::lib_path_under("/music/a.flac", "/mu"), "前缀判定：不把 mu 当 music 的前缀");
    }
    // ---- 4.2 中文/日文根目录：能加、能扫、能落盘 ----
    {
        const fs::path tmp4 = fs::temp_directory_path() / "rta_lib_utf8";
        fs::remove_all(tmp4, ec);
        fs::create_directories(tmp4 / U("lib"), ec);
        _putenv_s("RLPLAYER_LIBRARY_DIR", p2u(tmp4 / U("lib")).c_str());
        for (auto r : lib.roots()) lib.removeRoot(r);
        const fs::path zhRoot = tmp4 / U("中文音乐库");
        fs::create_directories(zhRoot / U("专辑甲"), ec);
        fs::create_directories(zhRoot / U("日语-アルバム"), ec);
        auto mk = [&](const char* rel) { std::ofstream f(zhRoot / U(rel), std::ios::binary); f << "fLaC"; };
        mk("专辑甲/第一首.flac");
        mk("专辑甲/第二首（全角括号）.flac");
        mk("日语-アルバム/曲名.flac");
        const auto ar = lib.addRootEx(p2u(zhRoot));
        ck(ar.ok, "含中文/日文的根目录能被 addRoot", ar.why);
        ck(!lib.addRootEx("/不存在的非真实目录/123xyz").ok, "不存在的目录仍被拒");
        lib.load();                       // 清空索引（conf 里已有中文根）
        lib.startScan(true);
        lib.joinScan();
        ck(lib.trackCount() == 3, "中文根下 3 首全部入库", std::to_string(lib.trackCount()));
        ck(!lib.scanning(), "扫描正常结束（没有 fatal 异常）");
        ck(lib.scanMsg().find("无法访问") == std::string::npos, "扫描消息里没有坏根告警", lib.scanMsg());
        auto albums4 = lib.albums();
        bool hasZh = false, hasJp = false;
        for (auto& a : albums4) { if (a.name == "专辑甲") hasZh = true; if (a.name == "日语-アルバム") hasJp = true; }
        ck(hasZh && hasJp, "专辑列表里中文/日文专辑都在", std::to_string(albums4.size()) + " 张");
        ck(lib.albumCountFast() == albums4.size(), "snapshot 用的专辑数与真实一致");
        lib.load();
        ck(lib.trackCount() == 3, "索引落盘后能读回", std::to_string(lib.trackCount()));
        // ---- 4.3 删除清理：prune / removeUnder / 根目录消失时的保护 ----
        fs::remove(zhRoot / U("专辑甲") / U("第二首（全角括号）.flac"), ec);
        const auto pr = lib.pruneMissing();
        ck(pr.removed == 1 && lib.trackCount() == 2, "pruneMissing 剔除 1 条已删文件的记录",
           std::to_string(pr.removed) + " / " + std::to_string(lib.trackCount()));
        lib.load();
        ck(lib.trackCount() == 2, "prune 的结果已落盘", std::to_string(lib.trackCount()));
        const auto rm = lib.removeUnder(p2u(zhRoot / U("日语-アルバム")));
        ck(rm.removed == 1 && lib.trackCount() == 1, "removeUnder 按目录移除 1 条",
           std::to_string(rm.removed) + " / " + std::to_string(lib.trackCount()));
        lib.load();
        ck(lib.trackCount() == 1, "removeUnder 的结果已落盘", std::to_string(lib.trackCount()));
        fs::rename(zhRoot, tmp4 / U("中文音乐库-OFFLINE"), ec);   // 根忽然不可访问（外接盘拔出）
        lib.startScan(false);
        lib.joinScan();
        ck(lib.trackCount() == 1, "根目录不可访问时保留其下旧记录（旧实现会掉成 0）",
           std::to_string(lib.trackCount()) + " msg=" + lib.scanMsg());
        ck(lib.scanMsg().find("无法访问") != std::string::npos, "扫描消息如实报告坏根", lib.scanMsg());
        fs::rename(tmp4 / U("中文音乐库-OFFLINE"), zhRoot, ec);
        fs::remove_all(tmp4, ec);
    }
    // ---- 4.4 大库专辑整理：3000 首必须快（旧实现在比较器里扫目录，全在锁内） ----
    {
        const fs::path tmp5 = fs::temp_directory_path() / "rta_lib_big";
        fs::remove_all(tmp5, ec);
        fs::create_directories(tmp5, ec);
        _putenv_s("RLPLAYER_LIBRARY_DIR", p2u(tmp5).c_str());
        {
            std::ofstream f(tmp5 / "rlplayer-index.tsv", std::ios::binary);
            f << "#libIndexV\t4\n";
            f << "#path\tmtime\tsize\talbum\talbumArtist\tartist\ttitle\ttrack\tdisc\tyear\tsr\tbits\tch\tdur\thasCover\tgenre"
                 "\tcue\tcueN\tcueOff\tcueLen\n";
            for (int d = 0; d < 300; ++d)
                for (int t = 0; t < 10; ++t) {
                    char row[512];
                    std::snprintf(row, sizeof(row),
                        "/fake/Album%04d/t%d.flac\t111\t222\t\t\tArtist%03d\tTitle%d\t%d\t0\t0\t44100\t16\t2\t60.0\t0\tRock"
                        "\t\t0\t0\t0\n",
                        d, t, d, t, t + 1);
                    f << row;
                }
        }
        lib.load();
        ck(lib.trackCount() == 3000, "3000 首索引载入", std::to_string(lib.trackCount()));
        const auto tA = std::chrono::steady_clock::now();
        auto big = lib.albums();
        const double msBig = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tA).count();
        ck(big.size() == 300, "3000 首整理成 300 张专辑", std::to_string(big.size()));
        ck(msBig < 100.0, "3000 首专辑整理 < 100ms", std::to_string((int)msBig) + " ms");
        std::printf("  [INFO] 3000 首专辑整理 %.1f ms（旧实现：比较器内目录扫描，实测秒级）\n", msBig);
        const auto tB = std::chrono::steady_clock::now();
        lib.albums();
        const double msCache = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tB).count();
        ck(msCache < msBig + 5.0, "第二次 albums() 走缓存（不重复整理）", std::to_string((int)msCache) + " ms");
        fs::remove_all(tmp5, ec);
    }
    // ---- 4.5 并发无锁状态快照 Snapshot：耗时 < 50ms 且计数非负 ----
    {
        const fs::path tmp6 = fs::temp_directory_path() / "rta_lib_snap";
        fs::remove_all(tmp6, ec);
        fs::create_directories(tmp6, ec);
        _putenv_s("RLPLAYER_LIBRARY_DIR", p2u(tmp6).c_str());
        for (auto r : lib.roots()) lib.removeRoot(r);
        const fs::path sRoot = tmp6 / U("snap_music");
        fs::create_directories(sRoot, ec);
        for (int i = 0; i < 50; ++i) {
            std::ofstream f(sRoot / ("track_" + std::to_string(i) + ".flac"), std::ios::binary);
            f << "fLaC";
        }
        lib.addRoot(p2u(sRoot));
        lib.startScan(true);
        double maxSnapMs = 0.0;
        int snapCount = 0;
        while (lib.scanning()) {
            const auto t0 = std::chrono::steady_clock::now();
            auto s = lib.snapshot();
            const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            if (ms > maxSnapMs) maxSnapMs = ms;
            ck(s.scanned >= 0 && s.total >= 0 && s.tracks >= 0, "快照计数非负");
            ++snapCount;
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        lib.joinScan();
        auto finalSnap = lib.snapshot();
        ck(!finalSnap.scanning, "扫描结束快照 scanning=false");
        ck(maxSnapMs < 50.0, "扫描期间并发读 status 耗时 < 50ms", "最大 " + std::to_string(maxSnapMs) + " ms");
        std::printf("  [INFO] 扫描期间快照采样 %d 次，单次最大耗时 %.3f ms\n", snapCount, maxSnapMs);
        fs::remove_all(tmp6, ec);
    }
    // ---- 4.6 扫描线程 try/catch 兜底：异常不崩溃 ----
    {
        const fs::path tmp7 = fs::temp_directory_path() / "rta_lib_trycatch";
        fs::remove_all(tmp7, ec);
        fs::create_directories(tmp7, ec);
        _putenv_s("RLPLAYER_LIBRARY_DIR", p2u(tmp7).c_str());
        for (auto r : lib.roots()) lib.removeRoot(r);
        // 添加一个带非法字节的根目录，测试 lib_valid_utf8 / try-catch 是否接住
        lib.addRootEx("/tmp/\xC4\xE3\xBA\xC3_bad_utf8");
        lib.startScan(false);
        lib.joinScan();
        ck(!lib.scanning(), "非法根或异常探测时扫描线程不崩且正常退出");
        fs::remove_all(tmp7, ec);
    }


    // =======================================================================
    // [5] CUE 整轨分轨（2026-10-25 第二里程碑）：v4 索引 / 迁移 / 真实扫描 / 删 cue 回归
    // =======================================================================
    std::printf("\n== [5] CUE 整轨分轨（真实扫描） ==\n");
    {
        // 优先使用环境变量或 build-mac/ffmpeg-lite 提供的 ffprobe
        std::string ffprobe = rta::audio::find_tool("ffprobe");
        if (const char* env = std::getenv("RLPLAYER_FFPROBE")) {
            if (env[0]) ffprobe = std::string(env);
        }
        if (ffprobe.empty()) {
            const fs::path lite = fs::current_path() / "build-mac" / "ffmpeg-lite" / "ffprobe";
            if (fs::exists(lite)) ffprobe = lite.string();
        }
        ck(!ffprobe.empty(),
           "ffprobe 可用（末轨长度必须知道文件总时长；本仓同类门禁：writeback / media_duration）", ffprobe);

        auto u8_to_gbk = [](const std::string& u8) {
#if defined(_WIN32)
            const int n = ::MultiByteToWideChar(CP_UTF8, 0, u8.c_str(), (int)u8.size(), nullptr, 0);
            if (n <= 0) return std::string();
            std::wstring w((size_t)n, L'\0');
            ::MultiByteToWideChar(CP_UTF8, 0, u8.c_str(), (int)u8.size(), w.data(), n);
            const int m = ::WideCharToMultiByte(936, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
            if (m <= 0) return std::string();
            std::string s((size_t)m, '\0');
            ::WideCharToMultiByte(936, 0, w.c_str(), (int)w.size(), s.data(), m, nullptr, nullptr);
            return s;
#else
            if (u8.empty()) return std::string();
            iconv_t cd = iconv_open("GBK", "UTF-8");
            if (cd == (iconv_t)-1) return std::string();
            size_t inbytesleft = u8.size();
            char* inbuf = const_cast<char*>(u8.data());
            size_t outbufsize = u8.size() * 2 + 16;
            std::string out;
            out.resize(outbufsize);
            char* outbuf = &out[0];
            size_t outbytesleft = outbufsize;
            size_t res = iconv(cd, &inbuf, &inbytesleft, &outbuf, &outbytesleft);
            iconv_close(cd);
            if (res == (size_t)-1) return std::string();
            out.resize(outbufsize - outbytesleft);
            return out;
#endif
        };
        auto writeText = [](const fs::path& p, const std::string& s) {
            std::ofstream f(p, std::ios::binary | std::ios::trunc);
            f.write(s.data(), (std::streamsize)s.size());
        };
        // 真正可探测的 WAV（RIFF + fmt16 + data；全零 = 数字静音，不打开任何设备、不出声）
        auto writeWav = [](const fs::path& p, int sr, int ch, int seconds) {
            const int bits = 16;
            const long long frames = (long long)sr * seconds;
            const long long dataBytes = frames * ch * (bits / 8);
            std::ofstream f(p, std::ios::binary | std::ios::trunc);
            auto le = [&](long long v, int n) { for (int i = 0; i < n; ++i) f.put((char)((v >> (8 * i)) & 0xFF)); };
            f.write("RIFF", 4); le(36 + dataBytes, 4); f.write("WAVE", 4);
            f.write("fmt ", 4); le(16, 4); le(1, 2); le(ch, 2); le(sr, 4);
            le((long long)sr * ch * (bits / 8), 4); le(ch * (bits / 8), 2); le(bits, 2);
            f.write("data", 4); le(dataBytes, 4);
            std::vector<char> zero(65536, 0);
            for (long long left = dataBytes; left > 0; ) {
                const long long k = std::min<long long>(left, (long long)zero.size());
                f.write(zero.data(), (std::streamsize)k);
                left -= k;
            }
        };
        // 换库目录 + 换根 + 全量/增量扫描（与 /api/lib/scan 同一个 Library 实现）
        auto scanLib = [&](const fs::path& root, const fs::path& libDir, bool full) {
            fs::create_directories(libDir, ec);
            _putenv_s("RLPLAYER_LIBRARY_DIR", p2u(libDir).c_str());
            _putenv_s("RLPLAYER_PORT", "");
            for (auto r : lib.roots()) lib.removeRoot(r);
            const auto ar = lib.addRootEx(p2u(root));
            lib.load();
            lib.startScan(full);
            lib.joinScan();
            return ar;
        };
        auto trackOf = [&](size_t i) { rta::net::LibTrack t; lib.trackAt(i, t); return t; };
        auto albumNamed = [&](const std::string& name) {
            rta::net::LibAlbum a;
            for (auto& x : lib.albums()) if (x.name == name) { a = x; return a; }
            return a;
        };
        auto countIn = [&](const std::string& dirName) {
            int c = 0;
            for (size_t i = 0; i < lib.trackCount(); ++i) {
                rta::net::LibTrack t; lib.trackAt(i, t);
                if (t.path.find(dirName) != std::string::npos) ++c;
            }
            return c;
        };
        auto readIdx = [&](const fs::path& dir, fs::path& out) {
            out.clear();
            std::error_code e;
            for (auto& de : fs::directory_iterator(dir, e))
                if (de.path().filename().string().rfind("rlplayer-index", 0) == 0) out = de.path();
        };

        const fs::path tmp6 = fs::temp_directory_path() / "rta_lib_cue";
        fs::remove_all(tmp6, ec);
        const long long SEC = 44100;   // 1 秒的采样数（44.1k）

        // ---------------- ① 端到端扫描：10 秒整轨 + 3 轨 GBK cue ----------------
        {
            const fs::path libA = tmp6 / "libA";
            const fs::path rootA = tmp6 / U("音乐库A");
            const fs::path albA = rootA / U("整轨专辑");
            fs::create_directories(albA, ec);
            const fs::path wavA = albA / U("album.wav");
            writeWav(wavA, 44100, 2, 10);
            const std::string cueA =
                "TITLE \"整轨测试专辑\"\r\nPERFORMER \"测试艺术家\"\r\n"
                "REM GENRE \"Classical\"\r\nREM DATE 2019\r\n"
                "FILE \"album.wav\" WAVE\r\n"
                "  TRACK 01 AUDIO\r\n    TITLE \"第一首 四秒\"\r\n    INDEX 01 00:00:00\r\n"
                "  TRACK 02 AUDIO\r\n    TITLE \"第二首 四秒\"\r\n    INDEX 01 00:04:00\r\n"
                "  TRACK 03 AUDIO\r\n    TITLE \"第三首 两秒\"\r\n    INDEX 01 00:08:00\r\n";
            const std::string gbkA = u8_to_gbk(cueA);
            ck(!gbkA.empty() && gbkA != cueA, "GBK 编码成功且与 UTF-8 不同（真的走了 CP936 存盘）");
            writeText(albA / U("album.cue"), gbkA);

            const auto arA = scanLib(rootA, libA, true);
            ck(arA.ok, "CUE 夹具：库根可加", arA.why);
            ck(lib.trackCount() == 3, "10 秒整轨 + 3 轨 cue ⟹ 库里 3 首（整轨不再单独出现）",
               std::to_string(lib.trackCount()) + " msg=" + lib.scanMsg());
            const std::string wavU8 = p2u(wavA);
            const std::string cueU8 = p2u(albA / U("album.cue"));
            const rta::net::LibAlbum aa = albumNamed("整轨测试专辑");
            ck(aa.nTracks == 3, "专辑名 = cue 的全局 TITLE（GBK 中文逐字相等），3 首",
               std::to_string(aa.nTracks));
            ck(aa.artist == "测试艺术家", "专辑艺术家 = cue 的 PERFORMER", aa.artist);
            ck(std::abs(aa.duration - 10.0) < 1e-6,
               "专辑总时长 = 10 秒 = 整轨时长（不是 3×10）", std::to_string(aa.duration));
            if (aa.idx.size() == 3) {
                const rta::net::LibTrack v0 = trackOf(aa.idx[0]);
                const rta::net::LibTrack v1 = trackOf(aa.idx[1]);
                const rta::net::LibTrack v2 = trackOf(aa.idx[2]);
                ck(v0.title == "第一首 四秒" && v1.title == "第二首 四秒" && v2.title == "第三首 两秒",
                   "3 个中文曲名逐字相等（GBK cue → 库 → 专辑视图）",
                   v0.title + " | " + v1.title + " | " + v2.title);
                ck(v0.path == wavU8 && v1.path == wavU8 && v2.path == wavU8,
                   "3 首的 path 是同一个物理文件（播放器照旧能吃）", v2.path);
                ck(v0.trackNo == 1 && v1.trackNo == 2 && v2.trackNo == 3, "专辑内曲目号 1/2/3");
                ck(v0.cueNo == 1 && v1.cueNo == 2 && v2.cueNo == 3, "cueNo 保留 cue 里的 TRACK 号");
                ck(v0.isCueTrack() && v1.isCueTrack() && v2.isCueTrack(), "3 首都带 isCueTrack()");
                ck(v0.sampleRate == 44100 && v0.channels == 2 && v0.bits == 16,
                   "采样率/声道/位深来自物理文件（ffprobe 透传）", std::to_string(v0.sampleRate));
                ck(v0.cuePath == cueU8 && v1.cuePath == cueU8, "cuePath 回填成 .cue 的绝对路径");
                ck(v0.cueOff == 0 && v1.cueOff == 4 * SEC && v2.cueOff == 8 * SEC,
                   "cueOff = 0 / 176400 / 352800（4 秒 @44100）",
                   std::to_string(v0.cueOff) + "/" + std::to_string(v1.cueOff) + "/" + std::to_string(v2.cueOff));
                ck(v0.cueLen == 4 * SEC && v1.cueLen == 4 * SEC && v2.cueLen == 2 * SEC,
                   "cueLen = 4/4/2 秒（末轨 = 文件总时长 10s - 8s，靠 ffprobe 的总时长）",
                   std::to_string(v0.cueLen) + "/" + std::to_string(v1.cueLen) + "/" + std::to_string(v2.cueLen));
                ck(std::abs(v0.duration - 4.0) < 1e-6 && std::abs(v1.duration - 4.0) < 1e-6 &&
                   std::abs(v2.duration - 2.0) < 1e-6,
                   "dur = 4 / 4 / 2（= /api/lib/album 的 d.dur 字段）",
                   std::to_string(v0.duration) + "/" + std::to_string(v1.duration) + "/" + std::to_string(v2.duration));
                double s = -1, e = -1;
                ck(rta::net::lib_cue_range_sec(v1, s, e) &&
                   std::abs(s - 4.0) < 1e-9 && std::abs(e - 8.0) < 1e-9,
                   "lib_cue_range_sec(第 2 首) = 4.0..8.0 秒（播放侧要用的区间）",
                   std::to_string(s) + ".." + std::to_string(e));
            }

            // ---- 认领的整轨每次扫描都重探（不靠 mtime+size 缓存）----
            lib.startScan(false);
            lib.joinScan();
            ck(lib.lastScanProbed() == 1 && lib.lastScanCached() == 0,
               "cue 认领的整轨在增量扫描里仍被重探（1 次 ffprobe、0 次缓存复用）",
               std::to_string(lib.lastScanProbed()) + " probed / " + std::to_string(lib.lastScanCached()) + " cached");
            ck(lib.trackCount() == 3, "空跑一次增量扫描后仍是 3 首", std::to_string(lib.trackCount()));

            // ---- ② 落盘索引：v4 + 前 16 列原样 + 末尾 4 列 ----
            fs::path idxA;
            readIdx(libA, idxA);
            ck(!idxA.empty(), "v4 索引已落盘");
            auto readAll = [](const fs::path& p) -> std::string {
                std::ifstream f(p, std::ios::binary);
                return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            };
            auto splitTsv = [](const std::string& line) {
                std::vector<std::string> f; size_t s = 0;
                for (size_t k = 0; k <= line.size(); ++k)
                    if (k == line.size() || line[k] == '\t') { f.push_back(line.substr(s, k - s)); s = k + 1; }
                return f;
            };
            const std::string textA = readAll(idxA);
            ck(textA.find("#libIndexV\t4") != std::string::npos, "落盘版本头 = #libIndexV 4");
            std::string headA;
            std::vector<std::vector<std::string>> rowsA;
            {
                std::string line;
                for (size_t i = 0; i <= textA.size(); ++i) {
                    if (i == textA.size() || textA[i] == '\n') {
                        if (!line.empty() && line[0] != '#') rowsA.push_back(splitTsv(line));
                        else if (line.rfind("#path\t", 0) == 0) headA = line;
                        line.clear();
                    } else line += textA[i];
                }
            }
            const std::string kV3Head =
                "#path\tmtime\tsize\talbum\talbumArtist\tartist\ttitle\ttrack\tdisc\tyear\tsr\tbits\tch\tdur\thasCover\tgenre";
            ck(headA == kV3Head + "\tcue\tcueN\tcueOff\tcueLen",
               "表头 = v3 的 16 列逐字不变 + 末尾 4 列 cue/cueN/cueOff/cueLen", headA);
            ck(rowsA.size() == 3, "索引 3 行（3 条虚拟曲目，没有整轨那一行）", std::to_string(rowsA.size()));
            bool rows20 = rowsA.size() == 3;
            for (auto& r : rowsA) if (r.size() != 20) rows20 = false;
            ck(rows20, "每行 20 列");
            bool cueCols = rowsA.size() == 3;
            for (size_t i = 0; cueCols && i < rowsA.size(); ++i) {
                if (rowsA[i][16] != cueU8) cueCols = false;
                if (atoi(rowsA[i][17].c_str()) != (int)i + 1) cueCols = false;
                if (_strtoi64(rowsA[i][18].c_str(), nullptr, 10) != (long long)i * 4 * SEC) cueCols = false;
                if (_strtoi64(rowsA[i][19].c_str(), nullptr, 10) <= 0) cueCols = false;
            }
            ck(cueCols, "落盘 cue 列 = 绝对路径 / cueN=1,2,3 / cueOff=0,176400,352800 / cueLen>0");

            // ---- 重启回读：cue 字段必须真的从索引里回来 ----
            lib.load();
            ck(lib.trackCount() == 3, "重启后仍是 3 首（v4 索引可读）", std::to_string(lib.trackCount()));
            const rta::net::LibAlbum ab2 = albumNamed("整轨测试专辑");
            ck(ab2.nTracks == 3, "重启后专辑仍 3 首", std::to_string(ab2.nTracks));
            if (ab2.idx.size() == 3) {
                const rta::net::LibTrack t2 = trackOf(ab2.idx[1]);
                ck(t2.isCueTrack() && t2.cueNo == 2 && t2.cueOff == 4 * SEC && t2.cueLen == 4 * SEC,
                   "重启后第 2 首的 cueNo/cueOff/cueLen 仍在（真的落盘了，不是内存巧合）",
                   std::to_string(t2.cueOff) + "/" + std::to_string(t2.cueLen));
            }

            // ---- ③ 迁移：v3 索引整份丢弃，一次全量重建 ----
            {
                const std::string v3 = "#libIndexV\t3\n" + kV3Head + "\n" +
                    wavU8 + "\t1\t222\t整轨测试专辑\t测试艺术家\t测试艺术家\talbum\t1\t0\t0\t44100\t16\t2\t10.0\t0\tClassical\n";
                writeText(idxA, v3);
                lib.load();
                ck(lib.trackCount() == 0, "v3 索引被整份丢弃（不迁移旧行，否则整轨曲目会被复用）",
                   std::to_string(lib.trackCount()));
                lib.startScan(false);
                lib.joinScan();
                ck(lib.trackCount() == 3, "v3 → v4 迁移后重新扫出 3 首虚拟曲目（cue 生效）",
                   std::to_string(lib.trackCount()));
            }

            // ---- ④ 删 cue 回归：删掉 .cue 后增量扫描必须回到 1 首整轨 ----
            fs::remove(albA / U("album.cue"), ec);
            lib.startScan(false);
            lib.joinScan();
            ck(lib.trackCount() == 1, "删掉 .cue 后回到 1 首整轨（旧索引里的虚拟曲目不能被缓存命中）",
               std::to_string(lib.trackCount()) + " msg=" + lib.scanMsg());
            if (lib.trackCount() == 1) {
                const rta::net::LibTrack t = trackOf(0);
                ck(t.path == wavU8 && !t.isCueTrack() && t.cueNo == 0 && t.cueOff == 0,
                   "整轨曲目：path 不变、cue 字段清零", t.path);
                ck(t.title == "album", "曲名回退到文件名（不再是 cue 第 3 轨的标题）", t.title);
                ck(std::abs(t.duration - 10.0) < 1e-6, "整轨时长 = 10 秒", std::to_string(t.duration));
            }
        }

        // ---------------- ⑤ 大小写不一致：cue 写 ALBUM.WAV、磁盘 album.wav ----------------
        {
            const fs::path libC = tmp6 / "libC";
            const fs::path rootC = tmp6 / U("音乐库C");
            const fs::path albC = rootC / U("大小写");
            fs::create_directories(albC, ec);
            const fs::path wavC = albC / U("album.wav");
            writeWav(wavC, 44100, 2, 10);
            writeText(albC / U("case.cue"),
                      "TITLE \"大小写专辑\"\nPERFORMER \"P\"\nFILE \"ALBUM.WAV\" WAVE\n"
                      "  TRACK 01 AUDIO\n    TITLE \"c1\"\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    TITLE \"c2\"\n    INDEX 01 00:06:00\n");
            const auto arC = scanLib(rootC, libC, true);
            ck(arC.ok, "大小写夹具：库根可加");
            ck(lib.trackCount() == 2, "cue 的 FILE 与磁盘大小写不一致 ⟹ 仍展开 2 首",
               std::to_string(lib.trackCount()));
            bool pathReal = lib.trackCount() == 2;
            for (size_t i = 0; pathReal && i < lib.trackCount(); ++i) {
                const rta::net::LibTrack t = trackOf(i);
                if (t.path != p2u(wavC)) pathReal = false;
            }
            ck(pathReal, "path = 磁盘真名（album.wav，不是 cue 里的 ALBUM.WAV）");
            bool lenOk = lib.trackCount() == 2;
            for (size_t i = 0; lenOk && i < lib.trackCount(); ++i) {
                const rta::net::LibTrack t = trackOf(i);
                if (i == 0 && t.cueLen != 6 * SEC) lenOk = false;
                if (i == 1 && t.cueLen != 4 * SEC) lenOk = false;
            }
            ck(lenOk, "长度按索引换算：轨 1 = 6 秒、轨 2 = 10-6 = 4 秒");
        }

        // ---------------- ⑥ 退回整轨：坏 cue / 全数据轨 / 整轨不存在 / 被抢 ----------------
        {
            const fs::path libD = tmp6 / "libD";
            const fs::path rootD = tmp6 / U("音乐库D");
            auto mk = [&](const char* dir, const char* wavName, int sec) {
                const fs::path d = rootD / U(dir);
                fs::create_directories(d, ec);
                writeWav(d / U(wavName), 44100, 2, sec);
                return d;
            };
            const fs::path d1 = mk("broken", "album.wav", 10);
            writeText(d1 / U("broken.cue"),
                      "TITLE \"坏\"\nFILE \"album.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"x\"\n");
            const fs::path d2 = mk("dataonly", "album.wav", 10);
            writeText(d2 / U("data.cue"),
                      "FILE \"album.wav\" WAVE\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n");
            const fs::path d3 = mk("ghost", "ghost.wav", 10);
            writeText(d3 / U("ghost.cue"),
                      "TITLE \"幽灵\"\nFILE \"gone.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n");
            const fs::path d4 = mk("dup", "album.wav", 10);
            writeText(d4 / U("a.cue"),
                      "TITLE \"抢A\"\nFILE \"album.wav\" WAVE\n"
                      "  TRACK 01 AUDIO\n    TITLE \"A1\"\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    TITLE \"A2\"\n    INDEX 01 00:05:00\n");
            writeText(d4 / U("b.cue"),
                      "TITLE \"抢B\"\nFILE \"album.wav\" WAVE\n"
                      "  TRACK 01 AUDIO\n    TITLE \"B1\"\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    TITLE \"B2\"\n    INDEX 01 00:05:00\n");
            const auto arD = scanLib(rootD, libD, true);
            ck(arD.ok, "退回整轨夹具：库根可加");
            ck(lib.trackCount() == 5,
               "坏 cue / 数据轨 / 整轨缺失 各退回 1 首整轨 + 被抢的只展开一次 = 5 首",
               std::to_string(lib.trackCount()) + " msg=" + lib.scanMsg());
            ck(countIn("broken") == 1, "坏 cue ⟹ 退回 1 首整轨（不丢歌）", std::to_string(countIn("broken")));
            ck(countIn("dataonly") == 1, "全是数据轨的 cue ⟹ 退回 1 首整轨",
               std::to_string(countIn("dataonly")));
            ck(countIn("ghost") == 1, "cue 指向的整轨不存在 ⟹ 不产生幽灵曲目，同目录音频照旧整轨",
               std::to_string(countIn("ghost")));
            ck(countIn("dup") == 2, "两张 cue 抢同一整轨 ⟹ 只展开一次（先到先得，不重复）",
               std::to_string(countIn("dup")));
            bool fallbackClean = true;
            std::string fbTitles;
            for (size_t i = 0; i < lib.trackCount(); ++i) {
                const rta::net::LibTrack t = trackOf(i);
                if (t.path.find("dup") != std::string::npos) continue;
                if (t.isCueTrack()) fallbackClean = false;
                fbTitles += t.title + " ";
            }
            ck(fallbackClean, "退回整轨的 3 首没有 cue 字段（不假装自己是虚拟曲目）", fbTitles);
            std::string dupTitles;
            for (size_t i = 0; i < lib.trackCount(); ++i) {
                const rta::net::LibTrack t = trackOf(i);
                if (t.path.find("dup") != std::string::npos) dupTitles += t.title + " ";
            }
            ck(dupTitles == "A1 A2 ", "被抢后只用先到的 a.cue 展开（B1/B2 不重复出现）", dupTitles);
        }
        fs::remove_all(tmp6, ec);
    }

        fs::current_path(oldCwd, ec);
    fs::remove_all(tmp, ec);

    std::printf("\n%s\n", g_fail == 0 ? "全部通过" : (std::to_string(g_fail) + " 项失败").c_str());
    return g_fail == 0 ? 0 : 1;
}
