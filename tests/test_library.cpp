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
        f << "#libIndexV\t3\n";
        f << "#path\tmtime\tsize\talbum\talbumArtist\tartist\ttitle\ttrack\tdisc\tyear\tsr\tbits\tch\tdur\thasCover\tgenre\n";
        auto row = [&](const std::string& path, const std::string& alb, const std::string& aa,
                       const std::string& art, const std::string& ttl, int trk, int disc,
                       int yr, int sr, int bits, int ch, double dur, int cov) {
            f << path << "\t111\t222\t" << alb << "\t" << aa << "\t" << art << "\t" << ttl
              << "\t" << trk << "\t" << disc << "\t" << yr << "\t" << sr << "\t" << bits
              << "\t" << ch << "\t" << dur << "\t" << cov << "\tRock\n";
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
            f << "#libIndexV\t3\n";
            f << "#path\tmtime\tsize\talbum\talbumArtist\tartist\ttitle\ttrack\tdisc\tyear\tsr\tbits\tch\tdur\thasCover\tgenre\n";
            for (int d = 0; d < 300; ++d)
                for (int t = 0; t < 10; ++t) {
                    char row[512];
                    std::snprintf(row, sizeof(row),
                        "/fake/Album%04d/t%d.flac\t111\t222\t\t\tArtist%03d\tTitle%d\t%d\t0\t0\t44100\t16\t2\t60.0\t0\tRock\n",
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

    fs::current_path(oldCwd, ec);
    fs::remove_all(tmp, ec);

    std::printf("\n%s\n", g_fail == 0 ? "全部通过" : (std::to_string(g_fail) + " 项失败").c_str());
    return g_fail == 0 ? 0 : 1;
}
