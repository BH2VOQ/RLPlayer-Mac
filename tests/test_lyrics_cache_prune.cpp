// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_lyrics_cache_prune — AI 歌词缓存目录的容量上限（2026-11-16 评审 MINOR）。
// 规则：最多 maxFiles 个 *.json / 总字节 ≤ maxBytes，超出按**最近修改时间最旧**先删；0 = 该维度不限。

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "meta/lyrics_ai.h"

namespace fs = std::filesystem;

static int g_pass = 0;
static int g_fail = 0;

static void ck(bool ok, const char* name, const std::string& detail = std::string()) {
    if (ok) { g_pass++; std::printf("  [PASS] %s\n", name); }
    else { g_fail++; std::printf("  [FAIL] %s  %s\n", name, detail.c_str()); }
}

static void make_file(const fs::path& d, const std::string& name, size_t bytes, int ageSec) {
    std::ofstream f(d / name, std::ios::binary | std::ios::trunc);
    f << std::string(bytes, 'x');
    f.close();
    // ageSec 越大 = 越旧；测试里 k000 传最大 ageSec，所以 k000 最旧。
    fs::last_write_time(d / name,
        fs::file_time_type::clock::now() - std::chrono::seconds(ageSec));
}

static size_t count_json(const fs::path& d) {
    size_t n = 0;
    for (const auto& e : fs::directory_iterator(d)) {
        if (e.path().filename().extension() == fs::path(".json")) ++n;
    }
    return n;
}

static bool has_json(const fs::path& d, const std::string& name) {
    return fs::exists(d / name);
}

int main() {
    const fs::path dir = fs::temp_directory_path() / "rlp-lyrics-prune-test";
    fs::remove_all(dir);
    fs::create_directories(dir);
    const std::string d8 = dir.string();

    // 12 个文件，各 1 KB，mtime 从旧到新（k011 最新）
    for (int i = 0; i < 12; ++i) {
        char nm[32];
        std::snprintf(nm, sizeof(nm), "k%03d.json", i);
        make_file(dir, nm, 1024, (11 - i) * 10);   // k000 最旧
    }

    std::printf("== 1. 文件数上限 ==\n");
    ck(count_json(dir) == 12, "初始 12 个缓存文件");
    const size_t removed = rta::meta::lyrics_cache_prune(d8, 5, 0);
    ck(count_json(dir) == 5, "maxFiles=5 ⇒ 只剩 5 个", std::to_string(count_json(dir)));
    ck(removed == 7, "删除 7 个", std::to_string(removed));
    ck(has_json(dir, "k011.json") && has_json(dir, "k010.json") && has_json(dir, "k009.json")
       && has_json(dir, "k008.json") && has_json(dir, "k007.json"), "保留的是最新的 5 个");
    ck(!has_json(dir, "k006.json") && !has_json(dir, "k000.json"), "最旧的被删掉");

    std::printf("== 2. 字节上限 ==\n");
    fs::remove_all(dir);
    fs::create_directories(dir);
    for (int i = 0; i < 6; ++i) {
        char nm[32];
        std::snprintf(nm, sizeof(nm), "b%03d.json", i);
        make_file(dir, nm, 1024, (5 - i) * 10);
    }
    ck(count_json(dir) == 6, "初始 6 个文件");
    const size_t removed2 = rta::meta::lyrics_cache_prune(d8, 0, 3u * 1024u);
    ck(count_json(dir) == 3, "maxBytes=3KB ⇒ 只剩 3 个", std::to_string(count_json(dir)));
    ck(removed2 == 3, "删除 3 个", std::to_string(removed2));
    ck(has_json(dir, "b005.json") && has_json(dir, "b004.json") && has_json(dir, "b003.json"),
       "保留的是最新 3 个");

    std::printf("== 3. 上限内不删 ==\n");
    const size_t removed3 = rta::meta::lyrics_cache_prune(d8, 0, 0);
    ck(removed3 == 0 && count_json(dir) == 3, "0/0 = 不限 ⇒ 一个也不删");

    std::printf("== 4. 空目录/不存在目录安全 ==\n");
    const fs::path none = fs::temp_directory_path() / "rlp-lyrics-prune-none";
    fs::remove_all(none);
    ck(rta::meta::lyrics_cache_prune(none.string(), 5, 0) == 0, "目录不存在 ⇒ 返回 0 不抛");
    ck(rta::meta::lyrics_cache_prune(std::string(), 5, 0) == 0, "空路径 ⇒ 返回 0 不抛");

    fs::remove_all(dir);
    fs::remove_all(none);

    std::printf("\n----------------------------------------\n");
    std::printf("PASS %d / FAIL %d\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
