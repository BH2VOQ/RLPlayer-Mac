// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_diag_channels.cpp — GET /api/diag/channels 真实探活端点离线门禁
//
// 判据：
//   1) global 通道选中 https://raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/latest.json，
//      cn 通道选中 https://rlplayer.rainlain.com/api/v1/update/macos/latest；
//      反馈选中 https://rlplayer.rainlain.com/api/v1/feedback/macos/watchdog；
//      均为 GET 且 timeoutMs == 4000。
//   2) 200/200、超时、404/403、连接 reset 场景下，整体 HTTP 均保持 200 且 top-level ok=true，
//      单通道失败如实写进 update/feedback 的 ok/http/latency/timedOut/error 字段。
//   3) 不泄露 update.conf 里的 token，也不返回响应体 body。
//   4) 不写入 EventLog / events.jsonl（不写日志），不发 POST 反馈，不下载包。
//   5) diag_snapshot_json(false) 在探活前为 channels:null，探活后携带最新 channels 状态。

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#define RLPLAYER_EMBEDDED_LIBRARY 1
#include "rtaweb.cpp"

namespace fs = std::filesystem;

static int g_pass = 0;
static int g_fail = 0;

static void ck(bool ok, const std::string& what, const std::string& detail = {}) {
    if (ok) {
        ++g_pass;
        std::printf("  [PASS] %s\n", what.c_str());
    } else {
        ++g_fail;
        std::printf("  [FAIL] %s%s%s\n", what.c_str(),
                    detail.empty() ? "" : " — ", detail.c_str());
    }
}

static void write_update_conf(const fs::path& dir, const std::string& content) {
    std::ofstream f(dir / "update.conf", std::ios::binary | std::ios::trunc);
    f << content;
}

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    const fs::path tmpDir = fs::temp_directory_path() /
        ("rlplayer-test-diag-channels-" + std::to_string((long long)current_pid()));
    std::error_code ec;
    fs::remove_all(tmpDir, ec);
    fs::create_directories(tmpDir, ec);
    ::setenv("RLPLAYER_STATE_DIR", tmpDir.string().c_str(), 1);
    ::setenv("RLPLAYER_DISABLE_DIAG_START", "0", 1);

    // ------------------------------------------------------------------
    std::printf("\n=== 1. 初始状态：diag_snapshot_json 不联网，channels 为 null ===\n");
    clear_diag_channels_cache_for_test();
    int callsBefore = 0;
    set_diag_channels_transport_for_test([&](const rta::platform::HttpRequest&) {
        ++callsBefore;
        return rta::platform::HttpResult{};
    });
    {
        const auto snap = rta::net::json_parse(diag_snapshot_json(false));
        ck(callsBefore == 0, "diag_snapshot_json(false) 不触发网络探活");
        ck(snap.has("channels") && snap["channels"].type == rta::net::Json::Null,
           "首次探活前 diag_snapshot_json().channels 为 null");
    }

    // ------------------------------------------------------------------
    std::printf("\n=== 2. global 通道 200/200 + 不写日志 + 不含 token/body ===\n");
    std::vector<rta::platform::HttpRequest> seen;
    set_diag_channels_transport_for_test([&](const rta::platform::HttpRequest& req) {
        seen.push_back(req);
        rta::platform::HttpResult r;
        r.status = 200;
        r.ok = true;
        if (req.url.find("watchdog") != std::string::npos) {
            const std::string body = "{\"ok\":true,\"limits\":{\"ratePerMinute\":5},\"secretLeakGuard\":\"BODY_MUST_NOT_LEAK\"}";
            r.body.assign(body.begin(), body.end());
        } else {
            const std::string body = "{\"version\":\"9.9.9\",\"secretLeakGuard\":\"BODY_MUST_NOT_LEAK\"}";
            r.body.assign(body.begin(), body.end());
        }
        return r;
    });

    const size_t evBefore = rta::diag::event_log().recent(50).size();
    {
        rta::net::HttpRequest rq;
        rq.method = "GET";
        rq.path = "/api/diag/channels";
        std::string ct;
        const std::string raw = rlapp::dispatch(rq, ct);
        const auto j = rta::net::json_parse(raw);

        ck(rta::net::webui_status_slot()->load() == 200, "200/200 返回 HTTP 200");
        ck(ct.find("application/json") != std::string::npos, "Content-Type 为 JSON", ct);
        ck(j["ok"].b == true, "顶层 ok=true");
        ck(!j["checkedAt"].s().empty(), "checkedAt 非空", j["checkedAt"].s());
        ck(seen.size() == 2, "恰好发出 2 次 GET 请求", std::to_string(seen.size()));
        if (seen.size() == 2) {
            ck(seen[0].method == "GET" && seen[0].timeoutMs == 4000,
               "update 请求为 GET 且超时 4000ms");
            ck(seen[0].url == "https://raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/latest.json",
               "global 通道选中 raw.githubusercontent.com manifest URL", seen[0].url);
            ck(seen[1].method == "GET" && seen[1].timeoutMs == 4000,
               "feedback 请求为 GET 且超时 4000ms");
            ck(seen[1].url == "https://rlplayer.rainlain.com/api/v1/feedback/macos/watchdog",
               "feedback 选中 watchdog URL", seen[1].url);
        }
        ck(j["update"]["channel"].s() == "global", "update.channel=global");
        ck(j["update"]["ok"].b == true && (int)j["update"]["http"].n() == 200,
           "update ok=true & http=200");
        ck(j["update"]["latency"].n() >= 0, "update.latency >= 0");
        ck(j["feedback"]["ok"].b == true && (int)j["feedback"]["http"].n() == 200,
           "feedback ok=true & http=200");
        ck(!j["update"].has("token") && !j["update"].has("body") &&
           !j["feedback"].has("token") && !j["feedback"].has("body"),
           "返回体不含 token / body 字段");
        ck(raw.find("BODY_MUST_NOT_LEAK") == std::string::npos,
           "响应不包含远端 body 内容");
    }
    const size_t evAfter = rta::diag::event_log().recent(50).size();
    ck(evAfter == evBefore, "调用 /api/diag/channels 不写入 EventLog",
       std::to_string(evBefore) + " -> " + std::to_string(evAfter));

    // ------------------------------------------------------------------
    std::printf("\n=== 3. cn 通道选国内 manifest + token 不泄露 ===\n");
    write_update_conf(tmpDir, "token=glpat-SECRETTOKEN999\nchannel=cn\n");
    seen.clear();
    {
        rta::net::HttpRequest rq;
        rq.method = "GET";
        rq.path = "/api/diag/channels";
        std::string ct;
        const std::string raw = handle(rq, ct);
        const auto j = rta::net::json_parse(raw);

        ck(!seen.empty() && seen[0].url == "https://rlplayer.rainlain.com/api/v1/update/macos/latest",
           "cn 通道选中国内 manifest URL", seen.empty() ? "" : seen[0].url);
        bool leakedHeader = false;
        for (const auto& r : seen) {
            for (const auto& h : r.headers) {
                if (h.find("SECRETTOKEN999") != std::string::npos) leakedHeader = true;
            }
        }
        ck(!leakedHeader, "探活请求头不携带 update.conf 中的 token");
        ck(raw.find("SECRETTOKEN999") == std::string::npos, "响应不含 token 内容");
        ck(j["update"]["channel"].s() == "cn", "update.channel=cn");
    }

    // ------------------------------------------------------------------
    std::printf("\n=== 4. 超时场景：单通道超时不返回整体 500 ===\n");
    set_diag_channels_transport_for_test([](const rta::platform::HttpRequest& req) {
        rta::platform::HttpResult r;
        if (req.url.find("watchdog") != std::string::npos) {
            r.status = 200;
            r.ok = true;
            const std::string body = "{\"ok\":true}";
            r.body.assign(body.begin(), body.end());
        } else {
            r.status = 0;
            r.ok = false;
            r.timedOut = true;
            r.error = "请求失败: Timeout was reached";
        }
        return r;
    });
    {
        rta::net::HttpRequest rq;
        rq.method = "GET";
        rq.path = "/api/diag/channels";
        std::string ct;
        const std::string raw = handle(rq, ct);
        const auto j = rta::net::json_parse(raw);

        ck(rta::net::webui_status_slot()->load() == 200, "单通道超时整体仍 HTTP 200");
        ck(j["ok"].b == true, "单通道超时顶层 ok=true");
        ck(j["update"]["ok"].b == false && j["update"]["timedOut"].b == true &&
           (int)j["update"]["http"].n() == 0 && !j["update"]["error"].s().empty(),
           "update 如实标记 timedOut=true, ok=false, http=0 且带 error");
        ck(j["feedback"]["ok"].b == true && (int)j["feedback"]["http"].n() == 200,
           "feedback 仍正常返回 ok=true, http=200");
    }

    // ------------------------------------------------------------------
    std::printf("\n=== 5. 404 / 403 场景：如实显示失败状态码 ===\n");
    set_diag_channels_transport_for_test([](const rta::platform::HttpRequest& req) {
        rta::platform::HttpResult r;
        r.ok = false;
        if (req.url.find("watchdog") != std::string::npos) {
            r.status = 403;
            r.error = "HTTP 403";
        } else {
            r.status = 404;
            r.error = "HTTP 404";
        }
        return r;
    });
    {
        rta::net::HttpRequest rq;
        rq.method = "GET";
        rq.path = "/api/diag/channels";
        std::string ct;
        const std::string raw = handle(rq, ct);
        const auto j = rta::net::json_parse(raw);

        ck(rta::net::webui_status_slot()->load() == 200 && j["ok"].b == true,
           "404/403 场景整体仍 HTTP 200 & ok=true");
        ck(j["update"]["ok"].b == false && (int)j["update"]["http"].n() == 404 &&
           j["update"]["error"].s() == "HTTP 404",
           "update 如实报 HTTP 404");
        ck(j["feedback"]["ok"].b == false && (int)j["feedback"]["http"].n() == 403 &&
           j["feedback"]["error"].s() == "HTTP 403",
           "feedback 如实报 HTTP 403");
    }

    // ------------------------------------------------------------------
    std::printf("\n=== 6. global 连接 reset + 诊断快照可见失败 ===\n");
    write_update_conf(tmpDir, "channel=global\n");
    set_diag_channels_transport_for_test([](const rta::platform::HttpRequest& req) {
        rta::platform::HttpResult r;
        if (req.url.find("watchdog") != std::string::npos) {
            r.status = 200;
            r.ok = true;
            const std::string body = "{\"ok\":true}";
            r.body.assign(body.begin(), body.end());
        } else {
            r.status = 0;
            r.ok = false;
            r.timedOut = false;
            r.error = "请求失败: Recv failure: Connection reset by peer";
        }
        return r;
    });
    {
        rta::net::HttpRequest rq;
        rq.method = "GET";
        rq.path = "/api/diag/channels";
        std::string ct;
        (void)handle(rq, ct);

        const auto snap = rta::net::json_parse(diag_snapshot_json(false));
        ck(snap["channels"]["update"]["channel"].s() == "global",
           "diag_snapshot_json 携带最新 channel=global");
        ck(snap["channels"]["update"]["ok"].b == false &&
           snap["channels"]["update"]["error"].s().find("Connection reset by peer") != std::string::npos,
           "diag_snapshot_json 如实记录连接 reset 失败");
        ck(snap["channels"]["feedback"]["ok"].b == true &&
           (int)snap["channels"]["feedback"]["http"].n() == 200,
           "diag_snapshot_json 记录 feedback=200");
    }

    // ------------------------------------------------------------------
    std::printf("\n=== 7. 非 GET 请求返回 405 ===\n");
    {
        rta::net::HttpRequest rq;
        rq.method = "POST";
        rq.path = "/api/diag/channels";
        std::string ct;
        const std::string raw = handle(rq, ct);
        const auto j = rta::net::json_parse(raw);
        ck(rta::net::webui_status_slot()->load() == 405 && j["ok"].b == false,
           "POST /api/diag/channels 拒绝（405）");
    }

    set_diag_channels_transport_for_test(nullptr);
    fs::remove_all(tmpDir, ec);

    std::printf("\n----------------------------------------\n");
    std::printf("PASS %d / FAIL %d\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
