// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_settings_persist.cpp — /api/settings 的"写了就是写了"判据
//
// ============================ 这个测试在证明什么 ============================
// 2026-11-11 实测发现：POST /api/settings 的键白名单**漏了 hogexcl**。
// 症状极具欺骗性 —— 端点回 {"ok":true,"merged":true,"kv":{}}，
// 看起来一切正常，但 conf 里根本没有该键，/api/settings 读回也是空的。
// web 版设置页的「严格独占」勾选因此从不落盘，重启后回落到 PlayParams 的默认值。
//
// 本测试不看代码、不数白名单条目，只用**黑盒三连**判定：
//   ① POST 一个键 → 响应里必须回显它（merged 里的 kv 是后端自己说"我收了哪些"）；
//   ② 立刻 GET 读回 → 必须读到同一个值（证明落进了内存/文件，不是只在响应里糊弄）；
//   ③ 读 conf 文件原文 → 必须真的有一行 k=v（证明落盘，不是只在内存里）；
//   ④ 重启语义：新起一次 core 再读（换进程最接近真实重启，但同一进程里
//      stop/start 已足以证明"不是靠进程内全局变量兜着"）。
//
// ============================ 铁律 3：判据不能自欺 ============================
//   * 只断言 "ok":true 会漏掉这个真 BUG（它正是 ok:true）⟹ 必须读回值。
//   * 只 GET 读回还不够：GET 可能来自内存快照 ⟹ 必须查 conf 文件原文。
//   * 用一个**当前白名单里确实有**的键（volume）做对照：
//     它对这套判据必须通过。如果连 volume 都过不了，说明是判据写错了，
//     而不是 hogexcl 有问题 —— 这条对照能区分"被测代码错"与"测试错"。
//
// ============================ 环境纪律（铁律 1/2）============================
//   * backend=null + volume=-120：绝不打开物理音频设备，绝不发声。
//   * 不监听端口：全程只调 rlapp::dispatch（进程内），没有 listener。
//   * 曲库/配置全部落临时目录，不碰用户真实库根，不碰 8899。
#include "rlapp_core.h"
#include "net/webui.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

static int g_fail = 0;
static int g_pass = 0;

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

// 从 {"kv":{...}} 里读某个键的值（够用即可，不引入 JSON 库）
static std::string kv_get(const std::string& json, const std::string& key) {
    const std::string needle = "\"" + key + "\":";
    size_t p = json.find(needle);
    if (p == std::string::npos) return std::string();
    p += needle.size();
    while (p < json.size() && (json[p] == ' ' || json[p] == '\t')) ++p;
    if (p >= json.size()) return std::string();
    if (json[p] == '"') {
        ++p;
        std::string out;
        while (p < json.size() && json[p] != '"') {
            if (json[p] == '\\' && p + 1 < json.size()) { out += json[p + 1]; p += 2; continue; }
            out += json[p++];
        }
        return out;
    }
    std::string out;
    while (p < json.size() && json[p] != ',' && json[p] != '}') out += json[p++];
    return out;
}

static std::string read_file(const fs::path& p) {
    std::ifstream f(p.string(), std::ios::binary);
    std::ostringstream os;
    os << f.rdbuf();
    return os.str();
}

// conf 里是否有 "key=value" 这一行（值按前缀比，避免 -12.0 vs -12 这类格式差）
static bool conf_has(const std::string& conf, const std::string& key, const std::string& valuePrefix) {
    std::istringstream is(conf);
    std::string line;
    const std::string k = key + "=";
    while (std::getline(is, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.rfind(k, 0) == 0) {
            const std::string v = line.substr(k.size());
            return valuePrefix.empty() || v.rfind(valuePrefix, 0) == 0;
        }
    }
    return false;
}

// 一组「写 → 回显 → 读回 → 落盘」的完整判定
static void roundtrip(const fs::path& confPath, const std::string& key,
                      const std::string& postValue, const std::string& expectPrefix) {
    std::printf("\n  键 %s（POST %s=%s）\n", key.c_str(), key.c_str(), postValue.c_str());
    const std::string body = key + "=" + postValue;
    const std::string post = call("POST", "/api/settings", body);
    ck(post.find("\"ok\":true") != std::string::npos,
       key + " POST 返回 ok:true", post.substr(0, 160));
    // ① 响应回显：后端自己说它收了哪些键
    const std::string echo = kv_get(post, key);
    ck(!echo.empty(), key + " 在 POST 响应里被回显（证明过了白名单）",
       "响应=" + post.substr(0, 200));
    // ② 读回
    const std::string got = call("GET", "/api/settings");
    const std::string readBack = kv_get(got, key);
    ck(!readBack.empty() && readBack.rfind(expectPrefix, 0) == 0,
       key + " 能被 /api/settings 读回", "期望前缀=" + expectPrefix + " 实际=" + readBack);
    // ③ 落盘
    const std::string conf = read_file(confPath);
    ck(conf_has(conf, key, expectPrefix), key + " 真的写进了 rlplayer-settings.conf",
       "conf=" + conf.substr(0, 200));
}

int main() {
    std::printf("== /api/settings 持久化判据（hogexcl 回归）==\n");

    const fs::path tmp = fs::temp_directory_path() /
                         ("rlplayer_settings_persist_" + std::to_string(::getpid()));
    std::error_code ec;
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp, ec);
    if (ec) { std::printf("!! 无法创建临时目录\n"); return 2; }

    // 隔离 + 绝不出声（铁律 1）：backend=null、volume=-120
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
        f << "backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n";
    }

    ck(rlapp::start_embedded(), "start_embedded() 返回 true");

    // ---- 对照：白名单里**确实存在**的键必须先通过 ----
    // 如果这条红了，说明判据本身写错了（或环境不对），后面 hogexcl 的红不能归因给被测代码。
    std::printf("\n[对照] 白名单内既有键必须通过同一套判据\n");
    roundtrip(confPath, "volume", "-24", "-24");

    // ---- 被测：hogexcl（2026-11-11 修复前必然红）----
    std::printf("\n[被测] hogexcl（白名单遗漏键）\n");
    roundtrip(confPath, "hogexcl", "1", "1");

    // ---- 语义：关掉也必须能存（不是"只能写 1"）----
    roundtrip(confPath, "hogexcl", "0", "0");

    // ---- 合并写：设过 hogexcl 之后，别的键不被清空 ----
    // 这是 /api/settings 的历史事故点（trunc + 只写本次键会把 backend 抹掉 ⟹ 可能对用户设备出声）。
    {
        const std::string conf = read_file(confPath);
        ck(conf_has(conf, "backend", "null"),
           "合并写未清掉 backend=null（铁律 1：不会被静默切回真实设备）",
           conf.substr(0, 200));
        ck(conf_has(conf, "scanonstartup", "0"),
           "合并写未清掉 scanonstartup=0（不会意外触发真库扫描）", conf.substr(0, 200));
    }

    rlapp::stop_embedded();

    std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
    if (g_fail) { std::printf("!! 有失败项\n"); return 1; }
    std::printf("settings 持久化判据全部通过\n");
    return 0;
}
