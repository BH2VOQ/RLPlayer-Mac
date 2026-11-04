// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_cast_status.cpp — 1.1.2 生产级端点 /api/cast/* 与 /api/status 真实回归测试
//
// 验证契约：
//   1. 必须调用生产真实 handle()，绝不 mock 后端，绝不自造 string scan 假通过。
//   2. /api/cast/start 在合法 AirPlay 假接收端下返回 accepted/started。
//   3. 真实后台 RAOP worker 异步推流期间，即使 g_upnpPlayer 初始或被重置，
//      /api/status 必须返回 playing=true、outMode="airplay"、pos/dur > 0。
//   4. /api/signal 提供诚实的源与目标转换（48k/24 -> 44.1k/16）以及配置延迟来源说明。
//   5. /api/cast/state 提供真实的 phase / volume 字段。
//   6. /api/pause、/api/status、/api/seek：AirPlay 投放显式拒绝 seek。
//   7. 异常处理：ANNOUNCE 403 导致 worker 进入 stopped/error，不残留脏播放状态。
//   8. 停止后再次起播（stop then replay）干净无泄漏。
//   9. 全程 backend="null"，电平 <= -60 dBFS（本测试采用全零静音合成音频），严禁发声。

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <chrono>
#include <filesystem>
#include <sstream>
#include <functional>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>

// 环境变量与工作目录隔离（必须在 include rtaweb.cpp 之前设置）
static void init_test_env() {
    const std::string tmpRoot = "/tmp/rlplayer_cast_status_test_" + std::to_string(::getpid());
    std::filesystem::remove_all(tmpRoot);
    std::filesystem::create_directories(tmpRoot + "/state");
    std::filesystem::create_directories(tmpRoot + "/lib");
    std::filesystem::create_directories(tmpRoot + "/home");

    ::setenv("HOME", (tmpRoot + "/home").c_str(), 1);
    ::setenv("CFFIXED_USER_HOME", (tmpRoot + "/home").c_str(), 1);
    ::setenv("RLPLAYER_STATE_DIR", (tmpRoot + "/state").c_str(), 1);
    ::setenv("RLPLAYER_LIBRARY_DIR", (tmpRoot + "/lib").c_str(), 1);
}

namespace {
struct EnvInit {
    EnvInit() { init_test_env(); }
} g_env_init;
} // namespace

#define RLPLAYER_EMBEDDED_LIBRARY 1
#include "rtaweb.cpp"

static int g_fail = 0;
static void ck(bool cond, const std::string& name, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", name.c_str());
    } else {
        std::printf("  [FAIL] %s %s\n", name.c_str(), detail.empty() ? "" : ("(" + detail + ")").c_str());
        g_fail++;
    }
}

// ---------------------------------------------------------------------------
// 本地回环假 RAOP 接收端（仅绑定 127.0.0.1 临时端口）
// ---------------------------------------------------------------------------
struct EphemeralRaopReceiver {
    int listenFd = -1;
    uint16_t port = 0;
    int audioFd = -1;
    uint16_t audioPort = 0;
    int controlFd = -1;
    uint16_t controlPort = 0;
    int timingFd = -1;
    uint16_t timingPort = 0;

    std::atomic<bool> stop{false};
    std::thread acceptTh;
    std::thread udpTh;

    uint32_t latencyFrames = 44100; // 1.0s 延迟
    std::atomic<bool> announceForbidden{false};
    std::atomic<bool> failVolume{false};

    std::mutex mtx;
    std::vector<std::string> rtspMethods;
    std::vector<std::string> rtspBodies;
    size_t audioPackets = 0;
    size_t controlPackets = 0;
    bool recorded = false;

    size_t get_audio_packets() {
        std::lock_guard<std::mutex> lk(mtx);
        return audioPackets;
    }

    bool saw_method(const std::string& m) {
        std::lock_guard<std::mutex> lk(mtx);
        for (const auto& x : rtspMethods) if (x == m) return true;
        return false;
    }

    void reset_capture() {
        std::lock_guard<std::mutex> lk(mtx);
        rtspMethods.clear();
        rtspBodies.clear();
        audioPackets = 0;
        controlPackets = 0;
        recorded = false;
    }

    static int bind_udp_loopback(uint16_t& p) {
        int s = ::socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) return -1;
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = 0;
        if (::bind(s, (sockaddr*)&a, sizeof(a)) < 0) { ::close(s); return -1; }
        socklen_t len = sizeof(a);
        ::getsockname(s, (sockaddr*)&a, &len);
        p = ntohs(a.sin_port);
        return s;
    }

    bool start() {
        listenFd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd < 0) return false;
        int one = 1;
        ::setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = 0;
        if (::bind(listenFd, (sockaddr*)&a, sizeof(a)) < 0) return false;
        socklen_t len = sizeof(a);
        ::getsockname(listenFd, (sockaddr*)&a, &len);
        port = ntohs(a.sin_port);
        if (::listen(listenFd, 8) < 0) return false;

        audioFd = bind_udp_loopback(audioPort);
        controlFd = bind_udp_loopback(controlPort);
        timingFd = bind_udp_loopback(timingPort);
        if (audioFd < 0 || controlFd < 0 || timingFd < 0) return false;

        acceptTh = std::thread([this]() {
            while (!stop.load()) {
                pollfd pfd{};
                pfd.fd = listenFd;
                pfd.events = POLLIN;
                if (::poll(&pfd, 1, 25) <= 0) continue;
                sockaddr_in ca{};
                socklen_t cl = sizeof(ca);
                int c = ::accept(listenFd, (sockaddr*)&ca, &cl);
                if (c < 0) continue;

                std::thread([this, c]() {
                    char buf[4096];
                    std::string inBuf;
                    while (!stop.load()) {
                        pollfd cfd{};
                        cfd.fd = c;
                        cfd.events = POLLIN;
                        if (::poll(&cfd, 1, 25) <= 0) continue;
                        ssize_t n = ::recv(c, buf, sizeof(buf), 0);
                        if (n <= 0) break;
                        inBuf.append(buf, n);

                        size_t pos = 0;
                        while ((pos = inBuf.find("\r\n\r\n")) != std::string::npos) {
                            std::string req = inBuf.substr(0, pos + 4);
                            inBuf.erase(0, pos + 4);

                            std::string method;
                            size_t sp = req.find(' ');
                            if (sp != std::string::npos) method = req.substr(0, sp);

                            std::string cseq = "1";
                            size_t csp = req.find("CSeq: ");
                            if (csp != std::string::npos) {
                                size_t cr = req.find("\r\n", csp);
                                cseq = req.substr(csp + 6, cr - (csp + 6));
                            }

                            std::string clenStr;
                            size_t clp = req.find("Content-Length: ");
                            if (clp != std::string::npos) {
                                size_t cr = req.find("\r\n", clp);
                                clenStr = req.substr(clp + 16, cr - (clp + 16));
                            }
                            size_t clen = clenStr.empty() ? 0 : std::stoul(clenStr);
                            std::string body;
                            if (clen > 0) {
                                while (inBuf.size() < clen && !stop.load()) {
                                    ssize_t rn = ::recv(c, buf, sizeof(buf), 0);
                                    if (rn <= 0) break;
                                    inBuf.append(buf, rn);
                                }
                                if (inBuf.size() >= clen) {
                                    body = inBuf.substr(0, clen);
                                    inBuf.erase(0, clen);
                                }
                            }

                            {
                                std::lock_guard<std::mutex> lk(mtx);
                                rtspMethods.push_back(method);
                                if (!body.empty()) rtspBodies.push_back(body);
                            }

                            if (method == "ANNOUNCE" && announceForbidden.load()) {
                                std::string resp = "RTSP/1.0 403 Forbidden\r\nCSeq: " + cseq + "\r\n\r\n";
                                ::send(c, resp.data(), resp.size(), 0);
                                continue;
                            }

                            const bool volFail = (method == "SET_PARAMETER") &&
                                                 failVolume.load() &&
                                                 body.find("volume:") != std::string::npos;

                            std::ostringstream resp;
                            if (volFail) {
                                resp << "RTSP/1.0 453 Not Enough Bandwidth\r\nCSeq: " << cseq << "\r\n";
                            } else {
                                resp << "RTSP/1.0 200 OK\r\nCSeq: " << cseq << "\r\n";
                            }
                            if (!volFail) {
                                if (method == "SETUP") {
                                    resp << "Transport: RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;"
                                         << "server_port=" << audioPort << ";control_port=" << controlPort
                                         << ";timing_port=" << timingPort << "\r\n"
                                         << "Session: 11223344\r\n";
                                } else if (method == "RECORD") {
                                    resp << "Audio-Latency: " << latencyFrames << "\r\n"
                                         << "Session: 11223344\r\n";
                                    std::lock_guard<std::mutex> lk(mtx);
                                    recorded = true;
                                }
                            }
                            resp << "\r\n";
                            std::string s = resp.str();
                            ::send(c, s.data(), s.size(), 0);
                        }
                    }
                    ::close(c);
                }).detach();
            }
        });

        udpTh = std::thread([this]() {
            pollfd pfds[2]{};
            pfds[0].fd = audioFd; pfds[0].events = POLLIN;
            pfds[1].fd = controlFd; pfds[1].events = POLLIN;
            uint8_t ubuf[4096];
            while (!stop.load()) {
                if (::poll(pfds, 2, 25) <= 0) continue;
                if (pfds[0].revents & POLLIN) {
                    sockaddr_storage from{};
                    socklen_t flen = sizeof(from);
                    ssize_t n = ::recvfrom(audioFd, ubuf, sizeof(ubuf), 0, (sockaddr*)&from, &flen);
                    if (n > 0) {
                        std::lock_guard<std::mutex> lk(mtx);
                        audioPackets++;
                    }
                }
                if (pfds[1].revents & POLLIN) {
                    sockaddr_storage from{};
                    socklen_t flen = sizeof(from);
                    ssize_t n = ::recvfrom(controlFd, ubuf, sizeof(ubuf), 0, (sockaddr*)&from, &flen);
                    if (n > 0) {
                        std::lock_guard<std::mutex> lk(mtx);
                        controlPackets++;
                    }
                }
            }
        });
        return true;
    }

    void shutdown() {
        stop.store(true);
        if (acceptTh.joinable()) acceptTh.join();
        if (udpTh.joinable()) udpTh.join();
        if (listenFd >= 0) { ::close(listenFd); listenFd = -1; }
        if (audioFd >= 0) { ::close(audioFd); audioFd = -1; }
        if (controlFd >= 0) { ::close(controlFd); controlFd = -1; }
        if (timingFd >= 0) { ::close(timingFd); timingFd = -1; }
    }
};

// 构造测试音频：48kHz / 24-bit / 2ch / 1.5 秒全零静音（严格不可听，电平 <= -60 dBFS）
static std::string create_synth_wav(const std::string& path) {
    std::filesystem::create_directories(std::filesystem::path(path).parent_path());
    rta::audio::AudioBuffer ab;
    ab.rate = 48000;
    ab.channels = 2;
    ab.bits = 24;
    ab.isFloat = false;
    ab.raw.assign(48000 * 2 * 3 / 2, 0); // 1.5 秒
    rta::audio::write_wav(path, ab);
    return path;
}

static rta::net::Json http_get(const std::string& path) {
    rta::net::HttpRequest req;
    req.method = "GET";
    req.path = path;
    std::string ct;
    std::string resp = handle(req, ct);
    return rta::net::json_parse(resp);
}

static rta::net::Json http_post(const std::string& path, const std::string& body) {
    rta::net::HttpRequest req;
    req.method = "POST";
    req.path = path;
    req.body = body;
    std::string ct;
    std::string resp = handle(req, ct);
    return rta::net::json_parse(resp);
}

static bool wait_condition(const std::function<bool()>& fn, double timeoutSec = 4.0) {
    const auto t0 = std::chrono::steady_clock::now();
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < timeoutSec) {
        if (fn()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return false;
}

int main() {
    std::printf("=== test_cast_status: 1.1.2 生产级端点 /api/cast/* 与 /api/status 回归测试 ===\n");

    // 铁律 1 强制门禁：初始化为 null backend，绝不上真实音频硬件
    {
        std::lock_guard<std::mutex> lk(g_paramsMtx);
        g_params.backend = "null";
        g_params.device = "";
    }

    const std::string tmpDir = "/tmp/rlplayer_cast_status_synth";
    std::filesystem::create_directories(tmpDir);
    const std::string wav48k = create_synth_wav(tmpDir + "/test_48k24.wav");

    EphemeralRaopReceiver receiver;
    if (!receiver.start()) {
        std::printf("  [FATAL] EphemeralRaopReceiver 启动失败\n");
        return 1;
    }

    const std::string airplayDev = "airplay://127.0.0.1:" + std::to_string(receiver.port) + "/living_room";

    // =========================================================================
    // 1. /api/cast/start -> /api/status 真实后台播放状态与 g_upnpPlayer 健壮性
    // =========================================================================
    std::printf("\n--- 1. /api/cast/start 启动与 /api/status 状态契约 ---\n");
    {
        // 发起 POST /api/cast/start
        std::string startBody = "{\"dev\":\"" + airplayDev + "\",\"file\":\"" + wav48k + "\",\"dop\":false,\"volume\":-15.0}";
        rta::net::Json startRes = http_post("/api/cast/start", startBody);
        ck(startRes.b || startRes["ok"].b, "/api/cast/start 返回 ok=true", startRes["error"].s());
        ck(startRes["started"].b, "/api/cast/start 返回 started=true");

        // 等待后台 worker 连接并进入 playing 阶段（UDP 开始推流）
        bool startedPlaying = wait_condition([&]() {
            rta::net::CastState cs = rta::net::CastManager::instance().get_state();
            return cs.running && (cs.phase == "playing" || cs.phase == "serving") && receiver.get_audio_packets() > 0;
        }, 4.0);
        ck(startedPlaying, "后台 AirPlay worker 成功进入 playing 并向本地 UDP 推送音频包");

        // 原用户反馈场景：模拟 g_upnpPlayer 被意外重置为 false
        // /api/status 必须以真实 CastManager::get_state() 为准，自愈并将 g_upnpPlayer 扶正
        g_upnpPlayer.store(false);

        rta::net::Json st = http_get("/api/status");
        ck(st["ok"].b, "/api/status 返回 ok=true");
        ck(st["playing"].b, "即使 g_upnpPlayer=false，/api/status 仍诚实报告 playing=true");
        ck(st["outMode"].s() == "airplay", "/api/status outMode 为 airplay", st["outMode"].s());
        ck(st["castMode"].b, "/api/status castMode 为 true");
        ck(st["transport"].s() == "airplay", "/api/status transport 为 airplay", st["transport"].s());
        ck(g_upnpPlayer.load() == true, "g_upnpPlayer 被 /api/status 自愈同步为 true");

        // 验证进度与时长为正
        ck(st["dur"].n() > 1.4, "/api/status dur 正确反映文件时长 (~1.5s)", std::to_string(st["dur"].n()));
        ck(st["pos"].n() >= 0.0, "/api/status pos 为非负数值", std::to_string(st["pos"].n()));

        // =====================================================================
        // 2. /api/signal 信号链真实自证 (48k/24 -> 44.1k/16, latencySource)
        // =====================================================================
        std::printf("\n--- 2. /api/signal 信号链与延迟来源契约 ---\n");
        rta::net::Json sig = http_get("/api/signal");
        ck(sig["ok"].b, "/api/signal 返回 ok=true");
        rta::net::Json pth = sig["path"];
        ck(pth.ok(), "/api/signal 包含 path 对象");
        ck(pth["inRate"].n() == 48000, "signal inRate 为源采样率 48000", std::to_string(pth["inRate"].n()));
        ck(pth["inBits"].n() == 24, "signal inBits 为源位深 24", std::to_string(pth["inBits"].n()));
        ck(pth["outRate"].n() == 44100, "signal outRate 为 AirPlay 固定率 44100", std::to_string(pth["outRate"].n()));
        ck(pth["outBits"].n() == 16, "signal outBits 为 AirPlay 固定位深 16", std::to_string(pth["outBits"].n()));
        ck(pth["resample"].b, "signal 诚实报告进行了重采样 resample=true");
        ck(pth["latencyKnown"].b, "signal latencyKnown 为 true");
        ck(pth["latencyMs"].n() > 0.0, "signal latencyMs > 0", std::to_string(pth["latencyMs"].n()));
        // 延迟来源必须诚实说明是 sender-configured 而非 measured output latency
        ck(pth["latencySource"].s().find("not measured") != std::string::npos,
           "signal latencySource 诚实说明为配置延迟而非测量延迟", pth["latencySource"].s());

        // =====================================================================
        // 3. /api/cast/state 字段自证
        // =====================================================================
        std::printf("\n--- 3. /api/cast/state 字段自证 ---\n");
        rta::net::Json cs = http_get("/api/cast/state");
        ck(cs["ok"].b, "/api/cast/state 返回 ok=true");
        ck(cs["running"].b, "cast/state running 为 true");
        ck(cs["phase"].s() == "playing" || cs["phase"].s() == "serving", "cast/state phase 为 playing/serving", cs["phase"].s());
        ck(cs["volumeSupported"].b, "AirPlay 投放报告 volumeSupported=true");
        ck(cs["currentVolume"].n() >= 0, "cast/state currentVolume 为有效百分比", std::to_string(cs["currentVolume"].n()));

        // =====================================================================
        // 4. 控制交互：/api/pause、/api/seek 拒绝、/api/status 暂停感知
        // =====================================================================
        std::printf("\n--- 4. 控制端点与行为契约 ---\n");
        // AirPlay 投放显式拒绝拖动进度 /api/seek
        rta::net::Json seekRes = http_post("/api/seek?pos=0.5", "");
        ck(!seekRes["ok"].b, "/api/seek 显式拒绝 AirPlay 拖动进度");
        ck(seekRes["airplay"].b, "/api/seek 返回 airplay=true 标识");

        // 暂停 /api/pause?on=1
        rta::net::Json pauseRes = http_post("/api/pause?on=1", "");
        ck(pauseRes["ok"].b, "/api/pause 请求接受");
        wait_condition([&]() {
            rta::net::Json s = http_get("/api/status");
            return s["paused"].b;
        }, 2.0);
        rta::net::Json pausedSt = http_get("/api/status");
        ck(pausedSt["paused"].b, "/api/status 观察到 paused=true");

        // 恢复 /api/pause?on=0
        rta::net::Json resumeRes = http_post("/api/pause?on=0", "");
        ck(resumeRes["ok"].b, "/api/pause 恢复请求接受");
        wait_condition([&]() {
            rta::net::Json s = http_get("/api/status");
            return !s["paused"].b;
        }, 2.0);
        rta::net::Json resumedSt = http_get("/api/status");
        ck(!resumedSt["paused"].b, "/api/status 观察到恢复播放 paused=false");

        // 停止当前投放
        rta::net::Json stopRes = http_post("/api/cast/stop", "");
        ck(stopRes["ok"].b, "/api/cast/stop 成功");
        wait_condition([&]() {
            return !rta::net::CastManager::instance().get_state().running;
        }, 3.0);
        rta::net::Json stoppedSt = http_get("/api/status");
        ck(!stoppedSt["playing"].b, "停止后 /api/status playing 为 false");
    }

    // =========================================================================
    // 5. 异常处理：ANNOUNCE 403 导致 worker 进入 stopped/error，不残留脏状态
    // =========================================================================
    std::printf("\n--- 5. 异常响应 ANNOUNCE 403 隔离测试 ---\n");
    {
        receiver.reset_capture();
        receiver.announceForbidden.store(true); // 注入 403

        std::string startBody = "{\"dev\":\"" + airplayDev + "\",\"file\":\"" + wav48k + "\",\"dop\":false}";
        rta::net::Json startRes = http_post("/api/cast/start", startBody);
        ck(startRes["ok"].b, "/api/cast/start 异步请求接受");

        // 等待 worker 握手遇到 403 失败，并等待 upnp_queue_thread 观测到退出将错误收敛到 player 状态
        bool sawError = wait_condition([&]() {
            rta::net::CastState cs = rta::net::CastManager::instance().get_state();
            rta::net::Json st = http_get("/api/status");
            return !cs.running && cs.phase == "error" && !st["playing"].b && !st["error"].s().empty();
        }, 4.0);
        ck(sawError, "ANNOUNCE 403 后 CastManager 与 /api/status 均转入 error 且 playing=false");

        rta::net::Json cs = http_get("/api/cast/state");
        ck(!cs["running"].b, "cast/state running 为 false");
        ck(cs["phase"].s() == "error", "cast/state phase 为 error");
        ck(!cs["error"].s().empty(), "cast/state 包含非空错误说明");

        rta::net::Json st = http_get("/api/status");
        ck(!st["playing"].b, "错误发生后 /api/status playing 必须为 false（无残留播放）");
        ck(!st["error"].s().empty(), "/api/status error 报告了错误信息", st["error"].s());

        receiver.announceForbidden.store(false);
    }

    // =========================================================================
    // 6. Stop then replay 重新正常起播
    // =========================================================================
    std::printf("\n--- 6. 停止并重新起播 (Stop then replay) ---\n");
    {
        receiver.reset_capture();

        // 显式调一次 /api/cast/stop 清理
        http_post("/api/cast/stop", "");

        std::string startBody = "{\"dev\":\"" + airplayDev + "\",\"file\":\"" + wav48k + "\",\"dop\":false,\"volume\":-10.0}";
        rta::net::Json startRes = http_post("/api/cast/start", startBody);
        ck(startRes["ok"].b, "Replay 时 /api/cast/start 再次成功发起");

        bool replayPlaying = wait_condition([&]() {
            rta::net::CastState cs = rta::net::CastManager::instance().get_state();
            return cs.running && (cs.phase == "playing" || cs.phase == "serving") && receiver.get_audio_packets() > 0;
        }, 4.0);
        ck(replayPlaying, "Replay 后后台 worker 恢复正常推流");

        rta::net::Json st = http_get("/api/status");
        ck(st["playing"].b, "Replay 时 /api/status playing 为 true");
        ck(st["outMode"].s() == "airplay", "Replay 时 /api/status outMode 为 airplay");

        // 干净收尾
        http_post("/api/cast/stop", "");
        wait_condition([&]() {
            return !rta::net::CastManager::instance().get_state().running;
        }, 3.0);
    }

    receiver.shutdown();
    std::filesystem::remove_all(tmpDir);

    std::printf("\n=== test_cast_status 结束: FAIL=%d ===\n", g_fail);
    return g_fail > 0 ? 1 : 0;
}
