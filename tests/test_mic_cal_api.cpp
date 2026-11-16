// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_mic_cal_api.cpp — U4 第二步：/api/miccal 的「导入→读回→清除」黑盒判据
//
// ============================ 这个测试在证明什么 ============================
// 端点三个动作必须真的改到**同一份进程内状态**，而不是只回一句 ok:true：
//   ① POST /api/miccal?path=<绝对路径>  → 200 {ok:true,n_points,min_db,max_db,how}
//   ② GET  /api/miccal                  → 同一份 n_points / min_db / max_db / path / how
//   ③ POST /api/miccal?clear=1          → {ok:true,active:false}，GET 回到空态
//   ④ 坏文件/缺文件/缺参数/相对路径      → 400 + 稳定 code:miccal.parse_failed，
//      且**不破坏**已经导入的表（失败不能把用户的表悄悄清掉）
//
// 铁律 4：只断言 ok:true 会漏掉「回了 ok 但没改状态」的假实现 ⟹ 每条导入都必须 GET 读回。
// 路径用**中文目录 + 中文文件名**，证明 UTF-8 路径走的是现有 utf8 路径口径（不是自己拼）。
// 负向对照：旧实现 /api/miccal 根本不存在（返回 not found），本测试在改之前必然红。
//
// 环境纪律（铁律 1/2）：backend=null + volume=-120（绝不打开音频设备）、不监听端口
// （只调 rlapp::dispatch，进程内），全部落临时目录，不碰 8899。
#include "rlapp_core.h"
#include "net/webui.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
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

static int status() { return rta::net::webui_status_slot()->load(); }

// URL 组件编码：RFC 3986 unreserved 之外全部 %XX（中文路径必须靠它进查询串）
static std::string pct(const std::string& s) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : s) {
        const bool safe = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~';
        if (safe) { out += (char)c; continue; }
        out += '%';
        out += hex[c >> 4];
        out += hex[c & 0x0F];
    }
    return out;
}

// 从 JSON 里读数字/字符串/布尔（够用即可，不引入 JSON 库；服务端已保证字段存在）
static bool jnum(const std::string& j, const std::string& key, double& v) {
    const std::string needle = "\"" + key + "\":";
    const size_t p = j.find(needle);
    if (p == std::string::npos) return false;
    const size_t b = p + needle.size();
    char* end = nullptr;
    v = std::strtod(j.c_str() + b, &end);
    return end && end != j.c_str() + b;
}

static bool jstr(const std::string& j, const std::string& key, std::string& v) {
    const std::string needle = "\"" + key + "\":\"";
    const size_t p = j.find(needle);
    if (p == std::string::npos) return false;
    size_t i = p + needle.size();
    std::string out;
    while (i < j.size() && j[i] != '"') {
        if (j[i] == '\\' && i + 1 < j.size()) { out += j[i + 1]; i += 2; continue; }
        out += j[i++];
    }
    v = out;
    return true;
}

static bool jtrue(const std::string& j, const std::string& key) {
    const std::string needle = "\"" + key + "\":true";
    return j.find(needle) != std::string::npos;
}

static void write_text(const fs::path& p, const std::string& text) {
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    f << text;
}

int main() {
    std::printf("== /api/miccal 黑盒判据（导入 / 读回 / 清除 / 坏文件）==\n");

    const fs::path tmp = fs::temp_directory_path() /
                         ("rlplayer_miccal_api_" + std::to_string(::getpid()));
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
    write_text(confPath, "backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n");

    ck(rlapp::start_embedded(), "start_embedded() 返回 true");

    // ---- 空态（没导入过任何校准表）----
    std::printf("\n[空态] GET /api/miccal\n");
    {
        const std::string got = call("GET", "/api/miccal");
        ck(got.find("\"ok\":true") != std::string::npos, "空态 GET 返回 ok:true", got.substr(0, 200));
        ck(!jtrue(got, "active"), "空态 active=false", got.substr(0, 200));
        double n = -1;
        ck(jnum(got, "n_points", n) && n == 0, "空态 n_points=0", got.substr(0, 200));
        std::string path;
        ck(jstr(got, "path", path) && path.empty(), "空态 path 为空", got.substr(0, 200));
    }

    // ---- 安全：带 clear=1 的 GET 必须被 405 拦住（<img src> 不能清掉用户的校准表）----
    std::printf("\n[安全] GET 带副作用参数\n");
    {
        const std::string got = call("GET", "/api/miccal?clear=1");
        ck(status() == 405, "GET /api/miccal?clear=1 → 405", "status=" + std::to_string(status()));
        ck(got.find("\"ok\":false") != std::string::npos, "405 响应为 ok:false JSON", got.substr(0, 160));
        const std::string after = call("GET", "/api/miccal");
        ck(!jtrue(after, "active"), "被拦下的 GET 没有改状态", after.substr(0, 160));
    }

    // ---- 夹具：两列（逗号）校准文件，放在中文目录里 ----
    const fs::path fixtureDir = tmp / "校准夹具";
    fs::create_directories(fixtureDir, ec);
    const fs::path fixture = fixtureDir / "麦克风两列.csv";
    write_text(fixture,
               "freq,dB\n"
               "20.0,-2.0\n"
               "100.0,0.0\n"
               "1000.0,0.5\n"
               "20000.0,1.5\n");

    std::printf("\n[导入] POST /api/miccal?path=<中文绝对路径>\n");
    {
        const std::string post = call("POST", "/api/miccal?path=" + pct(fixture.string()));
        ck(status() == 200, "合法文件 → 200", "status=" + std::to_string(status()));
        ck(post.find("\"ok\":true") != std::string::npos, "导入返回 ok:true", post.substr(0, 220));
        double n = -1;
        ck(jnum(post, "n_points", n) && n == 4, "导入响应 n_points=4", post.substr(0, 220));
        double mn = 0, mx = 0;
        ck(jnum(post, "min_db", mn) && mn == -2.0, "导入响应 min_db=-2.0", post.substr(0, 220));
        ck(jnum(post, "max_db", mx) && mx == 1.5, "导入响应 max_db=1.5", post.substr(0, 220));
        std::string how;
        ck(jstr(post, "how", how) && how.find("逗号") != std::string::npos,
           "how 标明逗号分隔（解析形态摘要）", how);
        // 2026-11-16（评审 P0-3）：miccal 在本分支是「只导入、未接线」——生产链路里
        // build_corrections(...) 一次都没有被调用（只有 tests/），所以端点必须如实标注
        // wired=false：界面不能假装这条校准表已经在参与校正。接线落地时这组断言要改成 true。
        ck(!jtrue(post, "wired"), "导入响应 wired=false（校准表尚未接入校正计算）",
           post.substr(0, 240));
        std::string note;
        ck(jstr(post, "wired_note", note) && note.find("下一版") != std::string::npos,
           "wired_note 如实说明「参与校正将在下一版接入」", note);
    }

    // ---- 读回：GET 必须与 POST 是同一份状态，且路径逐字回显 ----
    std::printf("\n[读回] GET /api/miccal\n");
    {
        const std::string got = call("GET", "/api/miccal");
        ck(jtrue(got, "active"), "导入后 active=true", got.substr(0, 220));
        double n = -1, mn = 0, mx = 0;
        ck(jnum(got, "n_points", n) && n == 4, "读回 n_points=4", got.substr(0, 220));
        ck(jnum(got, "min_db", mn) && mn == -2.0, "读回 min_db=-2.0", got.substr(0, 220));
        ck(jnum(got, "max_db", mx) && mx == 1.5, "读回 max_db=1.5", got.substr(0, 220));
        std::string path, how;
        ck(jstr(got, "path", path) && path == fixture.string(),
           "读回 path 与导入的路径逐字一致（含中文）",
           "期望=" + fixture.string() + " 实际=" + path);
        ck(jstr(got, "how", how) && !how.empty(), "读回 how 非空", how);
        ck(!jtrue(got, "wired"), "读回 wired=false（与导入响应同一口径）", got.substr(0, 240));
    }

    // ---- 坏文件不能破坏已经生效的表（失败不清空）----
    const fs::path bad = fixtureDir / "坏文件.txt";
    write_text(bad, "# 只有注释\n* miniDSP 灵敏度行\nSens Factor =-2.087dB\n");
    std::printf("\n[坏文件] POST /api/miccal?path=<无可解析数据>\n");
    {
        const std::string post = call("POST", "/api/miccal?path=" + pct(bad.string()));
        ck(status() == 400, "坏文件 → 400", "status=" + std::to_string(status()));
        ck(post.find("\"ok\":false") != std::string::npos, "坏文件返回 ok:false", post.substr(0, 200));
        ck(post.find("\"code\":\"miccal.parse_failed\"") != std::string::npos,
           "坏文件 → 稳定 code:miccal.parse_failed", post.substr(0, 220));
        const std::string got = call("GET", "/api/miccal");
        ck(jtrue(got, "active"), "坏文件导入失败后旧表仍然生效", got.substr(0, 220));
        double n = -1;
        ck(jnum(got, "n_points", n) && n == 4, "坏文件导入失败没有把旧表清成 0 点", got.substr(0, 220));
    }

    // ---- 缺文件 / 缺参数 / 相对路径：都必须是 400 + 稳定 code，且状态不变 ----
    std::printf("\n[路径错误] 缺文件 / 缺参数 / 相对路径\n");
    {
        const std::string missing = (fixtureDir / "不存在.txt").string();
        const std::string post = call("POST", "/api/miccal?path=" + pct(missing));
        ck(status() == 400, "不存在的文件 → 400", "status=" + std::to_string(status()));
        ck(post.find("\"code\":\"miccal.parse_failed\"") != std::string::npos,
           "不存在的文件 → 稳定 code", post.substr(0, 200));

        const std::string none = call("POST", "/api/miccal");
        ck(status() == 400, "缺 path 参数 → 400", "status=" + std::to_string(status()));
        ck(none.find("\"code\":\"miccal.parse_failed\"") != std::string::npos,
           "缺 path 参数 → 稳定 code", none.substr(0, 200));

        const std::string rel = call("POST", "/api/miccal?path=" + pct("relative/path.txt"));
        ck(status() == 400, "相对路径 → 400（只接受绝对路径）", "status=" + std::to_string(status()));
        ck(rel.find("\"code\":\"miccal.parse_failed\"") != std::string::npos,
           "相对路径 → 稳定 code", rel.substr(0, 200));

        const std::string got = call("GET", "/api/miccal");
        double n = -1;
        ck(jtrue(got, "active") && jnum(got, "n_points", n) && n == 4,
           "路径错误后旧表仍生效（4 点）", got.substr(0, 200));
    }

    // ---- clear 只认 1/true：clear=0 不能清掉表（缺 path ⟹ 400，状态不变）----
    std::printf("\n[清除语义] clear=0 不等于清除\n");
    {
        const std::string c0 = call("POST", "/api/miccal?clear=0");
        ck(status() == 400, "POST clear=0 → 400（不是清除请求）", "status=" + std::to_string(status()));
        const std::string got = call("GET", "/api/miccal");
        double n = -1;
        ck(jtrue(got, "active") && jnum(got, "n_points", n) && n == 4,
           "clear=0 没有清掉已导入的 4 点表", got.substr(0, 200));
    }

    // ---- 清除：回到空态，且重复清除仍然 ok ----
    std::printf("\n[清除] POST /api/miccal?clear=1\n");
    {
        const std::string post = call("POST", "/api/miccal?clear=1");
        ck(status() == 200, "清除 → 200", "status=" + std::to_string(status()));
        ck(post.find("\"ok\":true") != std::string::npos, "清除返回 ok:true", post.substr(0, 200));
        ck(!jtrue(post, "active"), "清除响应 active=false", post.substr(0, 160));

        const std::string got = call("GET", "/api/miccal");
        ck(!jtrue(got, "active"), "清除后 GET active=false", got.substr(0, 200));
        double n = -1;
        ck(jnum(got, "n_points", n) && n == 0, "清除后 n_points=0", got.substr(0, 200));
        std::string path;
        ck(jstr(got, "path", path) && path.empty(), "清除后 path 为空", got.substr(0, 200));

        const std::string again = call("POST", "/api/miccal?clear=1");
        ck(status() == 200 && again.find("\"ok\":true") != std::string::npos,
           "重复清除仍然 200 + ok:true", again.substr(0, 160));
    }

    // ---- 清除后重新导入同一文件（状态可重建）----
    std::printf("\n[重导入] 清除后再导入\n");
    {
        const std::string post = call("POST", "/api/miccal?path=" + pct(fixture.string()));
        ck(status() == 200 && post.find("\"ok\":true") != std::string::npos,
           "清除后可重新导入", post.substr(0, 200));
        const std::string got = call("GET", "/api/miccal");
        double n = -1;
        ck(jtrue(got, "active") && jnum(got, "n_points", n) && n == 4,
           "重导入后读回 4 点", got.substr(0, 200));
    }

    rlapp::stop_embedded();

    std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
    if (g_fail) { std::printf("!! 有失败项\n"); return 1; }
    std::printf("/api/miccal 黑盒判据全部通过\n");
    return 0;
}
