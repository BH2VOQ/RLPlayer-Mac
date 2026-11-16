// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_settings_race.cpp — 并发 POST /api/settings 的「丢键 / 读到半截 conf」黑盒判据
//
// ============================ 这个测试在证明什么 ============================
// 评审 BLOCKER（2026-11-16）：POST /api/settings 原来是「读全量 → 合并 → trunc 覆盖写」，
// 无锁且非原子。两个后果都是真的：
//   ① 并发保存时后写者抹掉前者的键 —— 用户的设置凭空消失（含 backend/volume 这类安全键）；
//   ② trunc 先清零再逐行写，写窗口内 load_conf_map() 读到**空 map** ⟹ /api/play 回落
//      PlayParams 默认 volume=0.0 / backend=coreaudio —— 历史「0 dB 直接出声」的同类路径。
// 本测试不看实现，只做黑盒三连：
//   a) 8 个线程各 POST 自己的键 200 次 —— 结束后 8 个键必须**全部**在 conf 且值正确；
//   b) 同时 2 个读线程不停读 conf 原文与 GET /api/settings —— 任何一次都不允许出现
//      「空/缺 backend=null」的快照（写窗口读到半截就是这条）；
//   c) 单线程对照：一个键的写入 / 读回必须通过（证明判据本身没有写错）。
//
// 铁律 3（判据不能自欺）：
//   * 只断言 "ok":true 会漏掉这个 BUG（旧实现每次 POST 都回 ok:true，而键已经丢了）
//     ⟹ 必须查 conf 原文的最终内容；
//   * 读侧不能只看 GET 的 ok ⟹ 必须看 kv 里有没有并存的 backend=null；
//   * 对照用单线程，先证明「测试本身能过」，再让 8 线程去撞。
//
// 环境纪律（铁律 1/2）：backend=null + volume=-120（绝不打开音频设备）、不监听端口
// （只调 rlapp::dispatch，进程内），全部落临时目录，不碰 8899。
#include "rlapp_core.h"
#include "net/webui.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

namespace fs = std::filesystem;

static int g_pass = 0;
static int g_fail = 0;

static void ck(bool cond, const std::string& what, const std::string& detail = std::string()) {
    if (cond) {
        ++g_pass;
        std::printf("  [PASS] %s\n", what.c_str());
    } else {
        ++g_fail;
        std::printf("  [FAIL] %s%s%s\n", what.c_str(),
                    detail.empty() ? "" : " — ", detail.c_str());
    }
}

static std::string call(const std::string& method, const std::string& path,
                        const std::string& body = std::string()) {
    rta::net::HttpRequest rq;
    rq.method = method;
    rq.path = path;
    rq.body = body;
    std::string ct;
    return rlapp::dispatch(rq, ct);
}

static std::string read_all(const fs::path& p) {
    std::ifstream f(p.string(), std::ios::binary);
    std::ostringstream os;
    os << f.rdbuf();
    return os.str();
}

// conf 原文 → map；同时数重复键（旧实现并发写可能写出同一个键两行）。
static std::map<std::string, std::string> parse_conf(const std::string& text, int* dupCount = nullptr) {
    std::map<std::string, std::string> m;
    int dups = 0;
    std::istringstream is(text);
    std::string line;
    while (std::getline(is, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t e = line.find('=');
        if (e == std::string::npos) continue;
        const std::string k = line.substr(0, e);
        if (m.find(k) != m.end()) ++dups;
        m[k] = line.substr(e + 1);
    }
    if (dupCount) *dupCount = dups;
    return m;
}

int main() {
    std::printf("== /api/settings 并发判据（8 写 ×200 / 并发读不得到空 conf）==\n");

    const fs::path tmp = fs::temp_directory_path() /
                         ("rlplayer_settings_race_" + std::to_string(::getpid()));
    std::error_code ec;
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp, ec);
    if (ec) { std::printf("!! 无法创建临时目录\n"); return 2; }
    for (const char* leaf : {"home", "state", "covers", "lib"})
        fs::create_directories(tmp / leaf, ec);
    ::setenv("HOME", (tmp / "home").string().c_str(), 1);
    ::setenv("CFFIXED_USER_HOME", (tmp / "home").string().c_str(), 1);
    ::setenv("RLPLAYER_STATE_DIR", (tmp / "state").string().c_str(), 1);
    ::setenv("RLPLAYER_LIBRARY_DIR", (tmp / "lib").string().c_str(), 1);
    ::setenv("RLPLAYER_COVER_DIR", (tmp / "covers").string().c_str(), 1);

    const fs::path confPath = tmp / "state" / "rlplayer-settings.conf";
    {
        std::ofstream f(confPath.string(), std::ios::binary | std::ios::trunc);
        // backend=null / volume=-120 是安全基线：并发的任何一次写都不许把它抹掉。
        f << "backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n";
    }

    ck(rlapp::start_embedded(), "start_embedded() 返回 true");

    // ---------------- [0] 单线程对照：判据本身必须先能过 ----------------
    std::printf("\n[对照] 单线程写一个键 → 读回 + 落盘\n");
    {
        const std::string post = call("POST", "/api/settings", "atten=1.5");
        ck(post.find("\"ok\":true") != std::string::npos, "单线程 POST atten=1.5 → ok:true",
           post.substr(0, 160));
        const std::string conf = read_all(confPath);
        auto m = parse_conf(conf);
        ck(m.count("atten") && m["atten"] == "1.5", "单线程：atten=1.5 真的落盘",
           conf.substr(0, 200));
        ck(m.count("backend") && m["backend"] == "null", "单线程：合并写没有抹掉 backend=null",
           conf.substr(0, 200));
    }

    // ---------------- [1] 8 线程 × 200 次：各自写自己的键 ----------------
    static const char* kKeys[8] = { "filter", "filterNx", "shaper", "bits",
                                    "taps", "atten", "transition", "phase" };
    static const char* kVals[8] = { "Kaiser", "Kaiser", "NS9", "24",
                                    "65536", "120", "0.8", "linear" };
    static const unsigned kIters = 200;

    std::atomic<bool> stopReaders{false};
    std::atomic<long> rawEmpty{0};     // conf 原文读到 0 字节 / 缺 backend=null
    std::atomic<long> rawPartial{0};
    std::atomic<long> apiEmpty{0};     // GET /api/settings 的 kv 读不到 backend=null
    std::atomic<long> rawReads{0}, apiReads{0};

    auto readerFn = [&]() {
        while (!stopReaders.load(std::memory_order_relaxed)) {
            // (b1) 原文：写窗口里读到 0 字节或半截 conf 就是事故路径本身
            const std::string conf = read_all(confPath);
            rawReads.fetch_add(1);
            if (conf.empty()) rawEmpty.fetch_add(1);
            else if (conf.find("backend=null") == std::string::npos) rawPartial.fetch_add(1);
            // (b2) 端点读：kv 里必须有并存的 backend=null
            const std::string got = call("GET", "/api/settings");
            apiReads.fetch_add(1);
            if (got.find("\"backend\":\"null\"") == std::string::npos) apiEmpty.fetch_add(1);
        }
    };

    std::atomic<long> postsOk{0}, postsErr{0};
    std::vector<std::thread> writers;
    std::vector<std::thread> readers;
    for (int t = 0; t < 8; ++t) {
        writers.emplace_back([&, t]() {
            const std::string body = std::string(kKeys[t]) + "=" + kVals[t];
            for (unsigned i = 0; i < kIters; ++i) {
                const std::string r = call("POST", "/api/settings", body);
                if (r.find("\"ok\":true") != std::string::npos) postsOk.fetch_add(1);
                else postsErr.fetch_add(1);
            }
        });
    }
    for (int t = 0; t < 2; ++t) readers.emplace_back(readerFn);
    for (auto& w : writers) w.join();
    stopReaders.store(true);
    for (auto& r : readers) r.join();

    std::printf("\n[结果] POST ok=%ld err=%ld；原文读 %ld 次（空 %ld / 缺 backend %ld）；API 读 %ld 次（缺 backend %ld）\n",
                (long)postsOk.load(), (long)postsErr.load(),
                (long)rawReads.load(), (long)rawEmpty.load(), (long)rawPartial.load(),
                (long)apiReads.load(), (long)apiEmpty.load());

    ck(postsOk.load() == (long)(8 * kIters) && postsErr.load() == 0,
       "1600 次并发 POST 全部 ok:true（没有一次被并发写坏）",
       "ok=" + std::to_string(postsOk.load()) + " err=" + std::to_string(postsErr.load()));

    int dups = 0;
    const std::string conf = read_all(confPath);
    auto m = parse_conf(conf, &dups);
    bool allKeys = true;
    std::string detail;
    for (int i = 0; i < 8; ++i) {
        const auto it = m.find(kKeys[i]);
        if (it == m.end() || it->second != kVals[i]) {
            allKeys = false;
            detail += std::string(kKeys[i]) + "=" + (it == m.end() ? "<missing>" : it->second) + " ";
        }
    }
    ck(allKeys, "8 个线程各 200 次之后，8 个键全部在 conf 且值正确（旧实现必丢键）", detail);
    ck(dups == 0, "conf 没有重复键（并发写没有写出同一键两行）", "重复=" + std::to_string(dups));
    ck(m.count("backend") && m["backend"] == "null",
       "并发写之后 backend=null 仍在（不会被抹回真实设备）", conf.substr(0, 220));
    ck(m.count("volume") && m["volume"] == "-120",
       "并发写之后 volume=-120 仍在（不会被抹成 0 dB）", conf.substr(0, 220));

    ck(rawReads.load() > 0 && rawEmpty.load() == 0,
       "写期间读 conf 原文：从不出现 0 字节文件",
       "读取次数=" + std::to_string(rawReads.load()) + " 空=" + std::to_string(rawEmpty.load()));
    ck(rawPartial.load() == 0,
       "写期间读 conf 原文：从不出现缺少 backend=null 的半截文件",
       "缺 backend 次数=" + std::to_string(rawPartial.load()));
    ck(apiReads.load() > 0 && apiEmpty.load() == 0,
       "写期间 GET /api/settings：kv 从没有空掉 / 缺 backend=null",
       "读取次数=" + std::to_string(apiReads.load()) + " 空=" + std::to_string(apiEmpty.load()));

    rlapp::stop_embedded();
    fs::remove_all(tmp, ec);

    std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
    if (g_fail) { std::printf("!! 有失败项\n"); return 1; }
    std::printf("并发设置写入判据全部通过\n");
    return 0;
}
