// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_queue_manual_order.cpp — 随机模式下手动调整队列后，关闭随机不得回退旧顺序
//
// 真实语义（本判据实测确认，勿按想象写）：/api/playmode?mode=3 会**立即打乱** items
// 并把打乱前的顺序存进 g_q.base；关闭随机时用 base 还原。
// 因此若用户在随机模式下拖动过队列而 base 未作废，关闭随机会把整列覆盖回打乱前的顺序。
//
// 判据（黑盒，只看 /api/queue 的 items 顺序）：
//   1) 设队列 a,b,c,d → 读回 a,b,c,d；
//   2) 开随机 → 仍是这 4 项（顺序被打乱，只校验是同一组）；
//   3) /api/qmove from=0 to=3 → 记录当前顺序 M；
//   4) 关随机 → 必须仍等于 M（修复前会退回 a,b,c,d）。
//
// 环境纪律：backend=null / volume=-120；只在进程内 dispatch；HOME 与状态目录全落临时目录，
// 不碰用户真实队列、不监听端口、不发声。

#include "rlapp_core.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
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

// 从 {"items":["a","b",...]} 里按出现顺序取出路径。
static std::vector<std::string> items_of(const std::string& json) {
    std::vector<std::string> out;
    const std::string key = "\"items\":[";
    const size_t p = json.find(key);
    if (p == std::string::npos) return out;
    size_t i = p + key.size();
    while (i < json.size() && json[i] != ']') {
        const size_t q1 = json.find('"', i);
        if (q1 == std::string::npos) break;
        const size_t q2 = json.find('"', q1 + 1);
        if (q2 == std::string::npos) break;
        out.push_back(json.substr(q1 + 1, q2 - q1 - 1));
        i = q2 + 1;
    }
    return out;
}

static std::string seq_text(const std::vector<std::string>& v) {
    std::string s;
    for (size_t i = 0; i < v.size(); ++i) {
        if (i) s += ",";
        s += v[i];
    }
    return s;
}

// 四项是否恰好是 {a,b,c,d} 的一个排列
static bool is_perm4(const std::vector<std::string>& v) {
    if (v.size() != 4) return false;
    bool a = false, b = false, c = false, d = false;
    for (const auto& s : v) {
        if (s == "/a") a = true;
        else if (s == "/b") b = true;
        else if (s == "/c") c = true;
        else if (s == "/d") d = true;
        else return false;
    }
    return a && b && c && d;
}

int main() {
    std::printf("== 队列手动调整 vs 随机模式快照 ==\n");

    const fs::path tmp = fs::temp_directory_path() /
                         ("rlplayer_queue_order_" + std::to_string(::getpid()));
    std::error_code ec;
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp, ec);
    if (ec) {
        std::printf("!! 无法创建临时目录\n");
        return 2;
    }
    for (const char* leaf : {"home", "state", "covers", "lib"})
        fs::create_directories(tmp / leaf, ec);
    ::setenv("HOME", (tmp / "home").string().c_str(), 1);
    ::setenv("CFFIXED_USER_HOME", (tmp / "home").string().c_str(), 1);
    ::setenv("RLPLAYER_STATE_DIR", (tmp / "state").string().c_str(), 1);
    ::setenv("RLPLAYER_LIBRARY_DIR", (tmp / "lib").string().c_str(), 1);
    ::setenv("RLPLAYER_COVER_DIR", (tmp / "covers").string().c_str(), 1);
    {
        std::ofstream f((tmp / "state" / "rlplayer-settings.conf").string(),
                        std::ios::binary | std::ios::trunc);
        f << "backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n";
    }

    ck(rlapp::start_embedded(), "start_embedded() 返回 true");

    const std::string body = "files=%2Fa%0A%2Fb%0A%2Fc%0A%2Fd";
    const std::string setQ = call("POST", "/api/queue/set", body);
    ck(setQ.find("\"ok\":true") != std::string::npos, "queue/set 返回 ok:true", setQ.substr(0, 160));
    {
        const std::vector<std::string> it = items_of(call("GET", "/api/queue"));
        ck(it.size() == 4 && it[0] == "/a" && it[1] == "/b" && it[2] == "/c" && it[3] == "/d",
           "初始顺序为 a,b,c,d", "实际=" + seq_text(it));
    }

    const std::string sh = call("POST", "/api/playmode?mode=3");
    ck(sh.find("\"ok\":true") != std::string::npos, "playmode=3（随机）返回 ok:true", sh.substr(0, 160));
    {
        const std::vector<std::string> it = items_of(call("GET", "/api/queue"));
        ck(is_perm4(it), "开启随机后仍是同一组 4 项（顺序由随机决定）", "实际=" + seq_text(it));
    }

    const std::string mv = call("POST", "/api/qmove?from=0&to=3");
    ck(mv.find("\"ok\":true") != std::string::npos, "qmove 返回 ok:true", mv.substr(0, 160));
    const std::vector<std::string> moved = items_of(call("GET", "/api/queue"));
    ck(is_perm4(moved), "拖动后仍是同一组 4 项", "实际=" + seq_text(moved));

    // 关键判据：关随机必须保留用户手动调整（修复前会退回 a,b,c,d）
    const std::string seq = call("POST", "/api/playmode?mode=1");
    ck(seq.find("\"ok\":true") != std::string::npos, "playmode=1（列表循环）返回 ok:true", seq.substr(0, 160));
    {
        const std::vector<std::string> it = items_of(call("GET", "/api/queue"));
        ck(it.size() == moved.size() && it == moved,
           "关闭随机后顺序与拖动后完全一致（旧 base 已作废）",
           "拖动后=" + seq_text(moved) + " 关随机后=" + seq_text(it));
    }

    rlapp::stop_embedded();
    fs::remove_all(tmp, ec);

    std::printf("\n== 结果：%d 通过, %d 失败 ==\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
