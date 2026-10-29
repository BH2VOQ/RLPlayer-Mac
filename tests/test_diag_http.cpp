// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_diag_http.cpp — 真实 loopback HTTP 诊断故障验证（ROADMAP 1.1.1 · D1/D5）
//
// 验证目标与铁律 3（测试「通过」不等于「测对了东西」）：
//   1. 真实传输超时（meta.timeout）：真正由 loopback socket 延迟响应触发 transport timeout，
//      而不是仅仅靠 timeout_ms 配置参数；
//   2. 真实 LLM 401（llm.auth_failed / llm.config_error）：假 key 发起 POST，不出网，由本地
//      HTTP 服务返回 401，验证 status=401 触发鉴权失败归因；
//   3. HTTP 404 非 LLM 配置错误：404 必须判定为 not_found / http_failed，不得被误归因为
//      LLM 鉴权/配置错误（llm.config_error）；
//   4. 成功请求带 timeout_ms（timeout_ms > 0, timed_out=false, ok=true）：绝对不得误判为超时；
//   5. 隐私与数据安全（硬红线）：断言 URL query、Authorization 头、请求 body、响应正文
//      绝不泄漏进 events.jsonl 或诊断包，同时请求 RID 能正确关联；
//   6. 离线诊断引擎结论（rtadiag / analyze）：验证通过 bundle 组装后与 report.h 结论链路一致。
//
// 安全与隔离保证：
//   - 本地服务仅监听 127.0.0.1，端口 0 动态分配，绝不碰 8899；
//   - 诊断目录独立位于 /tmp 隔离路径，测试结束自动清理；
//   - 不开音频设备、不出声；
//   - 不杀任何外部进程，优雅关闭自有服务与线程。

#include "net/http_client.h"
#include "diag/diag.h"
#include "diag/bundle.h"
#include "diag/report.h"
#include "diag/error_codes.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace rta::diag;
using namespace rta::net;

static int g_pass = 0;
static int g_fail = 0;

static void ck(bool cond, const char* what, const std::string& detail = std::string()) {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s\n", what);
        if (!detail.empty()) std::printf("         %s\n", detail.c_str());
        ++g_fail;
    }
}

// ---------------- 极简测试用 Loopback HTTP Server ----------------
class LoopbackHttpFaultServer {
public:
    int listenFd = -1;
    int port = 0;
    std::atomic<bool> running{false};
    std::thread acceptThread;
    std::vector<std::thread> workers;
    std::vector<int> clientFds;
    std::mutex mtx;

    bool start() {
        listenFd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd < 0) return false;

        int opt = 1;
        ::setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0; // 0 = 动态端口，避免冲突

        if (::bind(listenFd, (sockaddr*)&addr, sizeof(addr)) != 0) {
            ::close(listenFd);
            listenFd = -1;
            return false;
        }

        socklen_t len = sizeof(addr);
        if (::getsockname(listenFd, (sockaddr*)&addr, &len) != 0) {
            ::close(listenFd);
            listenFd = -1;
            return false;
        }
        port = ntohs(addr.sin_port);

        if (::listen(listenFd, 32) != 0) {
            ::close(listenFd);
            listenFd = -1;
            return false;
        }

        running = true;
        acceptThread = std::thread([this]() {
            while (running) {
                sockaddr_in caddr{};
                socklen_t clen = sizeof(caddr);
                int cfd = ::accept(listenFd, (sockaddr*)&caddr, &clen);
                if (cfd < 0) break;
                {
                    std::lock_guard<std::mutex> lk(mtx);
                    clientFds.push_back(cfd);
                    workers.emplace_back([this, cfd]() {
                        handleClient(cfd);
                        ::close(cfd);
                        std::lock_guard<std::mutex> lk2(mtx);
                        for (auto it = clientFds.begin(); it != clientFds.end(); ++it) {
                            if (*it == cfd) {
                                clientFds.erase(it);
                                break;
                            }
                        }
                    });
                }
            }
        });
        return true;
    }

    void handleClient(int cfd) {
        int noSigPipe = 1;
        ::setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

        char buf[2048];
        std::string req;
        while (running) {
            ssize_t n = ::recv(cfd, buf, sizeof(buf) - 1, 0);
            if (n <= 0) return;
            req.append(buf, n);
            if (req.find("\r\n\r\n") != std::string::npos) break;
        }

        std::string path;
        size_t sp1 = req.find(' ');
        if (sp1 != std::string::npos) {
            size_t sp2 = req.find(' ', sp1 + 1);
            if (sp2 != std::string::npos) path = req.substr(sp1 + 1, sp2 - sp1 - 1);
        }

        if (path.find("/meta/timeout") != std::string::npos) {
            // 真实延迟 400ms，客户端设超时 100ms，触发真正 transport 级别超时
            int slept = 0;
            while (running && slept < 400) {
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
                slept += 25;
            }
            if (running) {
                std::string resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                ::send(cfd, resp.data(), resp.size(), 0);
            }
        } else if (path.find("/llm/401") != std::string::npos) {
            // 模拟 401 鉴权失败
            std::string body = "{\"error\":{\"message\":\"Invalid API key provided\",\"type\":\"invalid_request_error\"}}";
            std::string resp = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: "
                               + std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
            ::send(cfd, resp.data(), resp.size(), 0);
        } else if (path.find("/notfound") != std::string::npos) {
            // 模拟 404 资源未找到
            std::string body = "<html><body>404 Not Found</body></html>";
            std::string resp = "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: "
                               + std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
            ::send(cfd, resp.data(), resp.size(), 0);
        } else if (path.find("/success") != std::string::npos) {
            // 模拟正常响应
            std::string body = "{\"status\":\"ok\",\"data\":[1,2,3]}";
            std::string resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                               + std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
            ::send(cfd, resp.data(), resp.size(), 0);
        }
    }

    void stop() {
        if (!running.exchange(false)) return;
        if (listenFd >= 0) {
            ::shutdown(listenFd, SHUT_RDWR);
            ::close(listenFd);
            listenFd = -1;
        }
        {
            std::lock_guard<std::mutex> lk(mtx);
            for (int fd : clientFds) ::shutdown(fd, SHUT_RDWR);
        }
        if (acceptThread.joinable()) acceptThread.join();

        std::vector<std::thread> toJoin;
        {
            std::lock_guard<std::mutex> lk(mtx);
            toJoin.swap(workers);
        }
        for (auto& t : toJoin) {
            if (t.joinable()) t.join();
        }
    }

    ~LoopbackHttpFaultServer() { stop(); }
};

// ---------------- 辅助函数 ----------------
static std::string read_text_file(const std::string& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return {};
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

static AssembleResult make_bundle_from_events(const std::string& case_id, const std::string& events) {
    BundleSpec spec;
    spec.case_id = case_id;
    spec.app_version = "1.1.1-beta1";
    spec.platform.os = "macOS 27.0.1";
    spec.platform.arch = "arm64";
    spec.run.clean_exit = true;

    std::vector<BundleEntry> items;
    items.push_back(make_entry("diag.json", "{\"version\":\"1.1.1-beta1\",\"os\":\"macOS 27.0.1\"}", EntryKind::Json, 100));
    items.push_back(make_entry("events.jsonl", events, EntryKind::Jsonl, 80));
    items.push_back(make_entry("uievents.jsonl", "", EntryKind::Jsonl, 60));

    spec.cs.origin="loopback-transport-test";
    return assemble_with_report(spec, std::move(items),[&spec](const std::vector<MaterializedEntry>& entries){return render_report_text_for_bundle(entries,spec);});
}

int main() {
    std::printf("=== test_diag_http: 真实 loopback HTTP 诊断故障验证 ===\n");

    // 1. 启动 loopback HTTP 测试服务（动态端口，纯本地，绝不碰 8899）
    LoopbackHttpFaultServer server;
    if (!server.start()) {
        std::fprintf(stderr, "Fatal: failed to start loopback server\n");
        return 1;
    }
    ck(server.port > 0 && server.port != 8899, "server bound to dynamic loopback port",
       "Port=" + std::to_string(server.port));

    // 2. 隔离诊断运行目录
    std::string tmpDir = "/tmp/rlplayer-diag-http-" + std::to_string(::getpid());
    fs::remove_all(tmpDir);
    fs::create_directories(tmpDir);

    DiagConfig cfg;
    cfg.dir = tmpDir;
    cfg.app_version = "1.1.1-beta1";
    auto startRes = diag_start(cfg);
    ck(startRes.ok, "diag_start initialized in isolated directory");

    const std::string baseUrl = "http://127.0.0.1:" + std::to_string(server.port);

    // 敏感测试凭证（用于验证绝不泄露）
    const std::string kSecretQueryParam = "secret_token_val_998877";
    const std::string kSecretApiKey = "sk-live-secret-key-abcdef0123456789";
    const std::string kSecretReqBody = "PROMPT_WITH_PRIVATE_PASSWORD_123";
    const std::string kSecretRespBodySub = "Invalid API key provided";

    // -------------------------------------------------------------
    // 测试点 1：真实 Meta 超时（实际请求超时，不能只是 timeout_ms 配置）
    // -------------------------------------------------------------
    const std::string kRidMetaTimeout = "RID-META-TIMEOUT-001";
    {
        HttpDiagScope scope(Stage::Meta);
        ScopedRid rid(kRidMetaTimeout);
        // timeoutMs 设为 100ms，服务端 delay 400ms，确保实际请求超时
        auto r = http_get(baseUrl + "/meta/timeout?token=" + kSecretQueryParam, {}, 100);
        ck(!r.ok && r.timedOut, "meta request timed out via transport",
           "status=" + std::to_string(r.status) + " timedOut=" + std::to_string(r.timedOut) + " err=" + r.error);
        ck(r.status == 0, "timed out transport status is 0");
    }

    // -------------------------------------------------------------
    // 测试点 2：LLM 401（假 key，不出网，真正服务端返回 401）
    // -------------------------------------------------------------
    const std::string kRidLlm401 = "RID-LLM-401-002";
    {
        HttpDiagScope scope(Stage::Llm);
        ScopedRid rid(kRidLlm401);
        std::vector<std::string> headers = {"Authorization: Bearer " + kSecretApiKey};
        std::string postBody = "{\"prompt\":\"" + kSecretReqBody + "\"}";
        auto r = http_post(baseUrl + "/llm/401", postBody, headers, "application/json", 5000);
        ck(!r.ok && !r.timedOut, "LLM request finished with HTTP failure, not timeout");
        ck(r.status == 401, "LLM received HTTP 401 Unauthorized");
    }

    // -------------------------------------------------------------
    // 测试点 3：HTTP 404 不得一律推成 LLM 配置错误
    // -------------------------------------------------------------
    const std::string kRidLlm404 = "RID-LLM-404-003";
    {
        HttpDiagScope scope(Stage::Llm);
        ScopedRid rid(kRidLlm404);
        auto r = http_post(baseUrl + "/notfound", "{\"test\":1}", {}, "application/json", 5000);
        ck(!r.ok && r.status == 404, "LLM endpoint 404 received");
    }

    const std::string kRidMeta404 = "RID-META-404-004";
    {
        HttpDiagScope scope(Stage::Meta);
        ScopedRid rid(kRidMeta404);
        auto r = http_get(baseUrl + "/notfound?title=none", {}, 5000);
        ck(!r.ok && r.status == 404, "Meta endpoint 404 received");
    }

    // -------------------------------------------------------------
    // 测试点 4：成功请求带 timeout_ms 不得误判超时
    // -------------------------------------------------------------
    const std::string kRidSuccess = "RID-SUCCESS-005";
    {
        HttpDiagScope scope(Stage::Meta);
        ScopedRid rid(kRidSuccess);
        // 带 5000ms 超时预算的成功请求
        auto r = http_get(baseUrl + "/success?query=valid", {}, 5000);
        ck(r.ok && !r.timedOut && r.status == 200, "successful request completed with timeout_ms set");
    }

    // 停止诊断会话，刷新事件至磁盘
    diag_stop("test_http_done");
    server.stop();

    // -------------------------------------------------------------
    // 测试点 5：事件日志与落盘脱敏检查（绝不泄漏 query / Authorization / body / response 正文）
    // -------------------------------------------------------------
    std::string eventsPath = tmpDir + "/rlplayer-events.jsonl";
    std::string eventsContent = read_text_file(eventsPath);
    ck(!eventsContent.empty(), "rlplayer-events.jsonl generated and readable");

    // 检查绝不泄漏项
    ck(eventsContent.find(kSecretQueryParam) == std::string::npos,
       "URL query parameter secret NOT leaked in events.jsonl");
    ck(eventsContent.find(kSecretApiKey) == std::string::npos,
       "Authorization Bearer API key NOT leaked in events.jsonl");
    ck(eventsContent.find(kSecretReqBody) == std::string::npos,
       "Request body payload NOT leaked in events.jsonl");
    ck(eventsContent.find(kSecretRespBodySub) == std::string::npos,
       "Response body payload NOT leaked in events.jsonl");

    // 检查 URL query 替换标记
    ck(eventsContent.find("<redacted-query:") != std::string::npos,
       "URL query parameters properly replaced with <redacted-query:N>");

    // 检查 RID 关联性
    ck(eventsContent.find(kRidMetaTimeout) != std::string::npos, "RID for meta timeout correlated");
    ck(eventsContent.find(kRidLlm401) != std::string::npos, "RID for LLM 401 correlated");
    ck(eventsContent.find(kRidLlm404) != std::string::npos, "RID for LLM 404 correlated");
    ck(eventsContent.find(kRidMeta404) != std::string::npos, "RID for Meta 404 correlated");
    ck(eventsContent.find(kRidSuccess) != std::string::npos, "RID for Success correlated");

    // 检查事件代码映射（v2 表中的 llm.http_failed / llm.auth_failed / meta.timeout / meta.not_found）
    ck(eventsContent.find("\"code\":\"llm.http_failed\"") != std::string::npos,
       "event log emits llm.http_failed (id 66) on HTTP 404 for LLM stage");
    ck(eventsContent.find("\"code\":\"llm.auth_failed\"") != std::string::npos,
       "event log emits llm.auth_failed on HTTP 401 for LLM stage");
    ck(eventsContent.find("\"code\":\"meta.timeout\"") != std::string::npos,
       "event log emits meta.timeout on transport timeout");
    ck(eventsContent.find("\"code\":\"meta.not_found\"") != std::string::npos,
       "event log emits meta.not_found on HTTP 404 for Meta stage");

    // -------------------------------------------------------------
    // 测试点 6：端到端诊断包组装与离线分析结论（report.h / rtadiag 链路）
    // -------------------------------------------------------------

    // 6.1 单独组装 Meta Timeout 事件包并分析
    {
        std::string metaTimeoutEv;
        std::istringstream iss(eventsContent);
        std::string line;
        while (std::getline(iss, line)) {
            if (line.find(kRidMetaTimeout) != std::string::npos) {
                metaTimeoutEv += line + "\n";
            }
        }
        ck(!metaTimeoutEv.empty(), "extracted meta timeout event line");
        auto bundle = make_bundle_from_events("RLP-CASE-TIMEOUT", metaTimeoutEv);
        ck(bundle.ok, "bundle assemble for meta timeout ok");
        BundleSpec spec; spec.case_id = bundle.case_id; spec.run.clean_exit = true;
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));
        ck(rep.verdict == Verdict::Known && rep.conclusion.id == "meta.timeout",
           "rtadiag conclusion: meta.timeout correctly diagnosed",
           "got id=" + rep.conclusion.id + " title=" + rep.conclusion.title);
    }

    // 6.2 单独组装 LLM 401 事件包并分析
    {
        std::string llm401Ev;
        std::istringstream iss(eventsContent);
        std::string line;
        while (std::getline(iss, line)) {
            if (line.find(kRidLlm401) != std::string::npos) {
                llm401Ev += line + "\n";
            }
        }
        ck(!llm401Ev.empty(), "extracted LLM 401 event line");
        auto bundle = make_bundle_from_events("RLP-CASE-LLM401", llm401Ev);
        ck(bundle.ok, "bundle assemble for LLM 401 ok");
        BundleSpec spec; spec.case_id = bundle.case_id; spec.run.clean_exit = true;
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));
        ck(rep.verdict == Verdict::Known && rep.conclusion.id == "llm.config_error",
           "rtadiag conclusion: llm.config_error correctly diagnosed for 401",
           "got id=" + rep.conclusion.id + " title=" + rep.conclusion.title);
    }

    // 6.3 验证 HTTP 404 事件包：绝不能判定为 llm.config_error 或 meta.timeout
    {
        std::string notFoundEv;
        std::istringstream iss(eventsContent);
        std::string line;
        while (std::getline(iss, line)) {
            if (line.find(kRidLlm404) != std::string::npos || line.find(kRidMeta404) != std::string::npos) {
                notFoundEv += line + "\n";
            }
        }
        ck(!notFoundEv.empty(), "extracted 404 event lines");
        auto bundle = make_bundle_from_events("RLP-CASE-404", notFoundEv);
        ck(bundle.ok, "bundle assemble for 404 ok");
        BundleSpec spec; spec.case_id = bundle.case_id; spec.run.clean_exit = true;
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));
        ck(rep.conclusion.id != "llm.config_error",
           "HTTP 404 is NOT misdiagnosed as llm.config_error",
           "verdict=" + std::to_string((int)rep.verdict) + " id=" + rep.conclusion.id);
        ck(rep.conclusion.id != "meta.timeout",
           "HTTP 404 is NOT misdiagnosed as meta.timeout",
           "id=" + rep.conclusion.id);
    }

    // 6.4 验证成功请求包：带 timeout_ms 绝不能判定为超时
    {
        std::string successEv;
        std::istringstream iss(eventsContent);
        std::string line;
        while (std::getline(iss, line)) {
            if (line.find(kRidSuccess) != std::string::npos) {
                successEv += line + "\n";
            }
        }
        ck(!successEv.empty(), "extracted success event line");
        auto bundle = make_bundle_from_events("RLP-CASE-SUCCESS", successEv);
        ck(bundle.ok, "bundle assemble for success ok");
        BundleSpec spec; spec.case_id = bundle.case_id; spec.run.clean_exit = true;
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));
        ck(rep.conclusion.id != "meta.timeout",
           "successful request with timeout_ms is NOT misdiagnosed as meta.timeout",
           "verdict=" + std::to_string((int)rep.verdict) + " id=" + rep.conclusion.id);
        ck(rep.verdict == Verdict::Unknown,
           "successful request without fault evidence remains unknown (no false fault)",
           "verdict=" + std::to_string((int)rep.verdict));
    }

    // 6.5 诊断包成员中二次核对无敏感明文泄露
    {
        auto bundleAll = make_bundle_from_events("RLP-CASE-ALL", eventsContent);
        for (const auto& entry : bundleAll.entries) {
            ck(entry.data.find(kSecretQueryParam) == std::string::npos,
               ("bundle member " + entry.rec.name + " free of secret query").c_str());
            ck(entry.data.find(kSecretApiKey) == std::string::npos,
               ("bundle member " + entry.rec.name + " free of secret api key").c_str());
            ck(entry.data.find(kSecretReqBody) == std::string::npos,
               ("bundle member " + entry.rec.name + " free of request body").c_str());
            ck(entry.data.find(kSecretRespBodySub) == std::string::npos,
               ("bundle member " + entry.rec.name + " free of response body").c_str());
        }
    }

    // 清理临时文件
    if (std::getenv("RLP_TEST_KEEP_TMP") == nullptr) {
        fs::remove_all(tmpDir);
    }

    std::printf("\n=== Summary: %d PASS, %d FAIL ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
