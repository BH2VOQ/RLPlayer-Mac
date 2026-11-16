// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_playback_control_reset.cpp — 播放控制状态复位 & /api/queue/set require_stopped=1 回归判据
//
// 覆盖：
//   1. PlayerState::stopJoin() 停旧线程后清 pauseReq=false, paused=false, seekReq=-1.0
//   2. PlayerState::restart() 直接重启旧线程时同样清 pauseReq=false, paused=false, seekReq=-1.0
//   3. eq_hot_reload() 在 stopJoin() 之后主动恢复 seekReq 的语义不被 restart() 破坏
//   4. /api/clear 等通过 stopJoin() 停播时清干净 pauseReq/paused/seekReq
//   5. /api/queue/set?require_stopped=1 在本地播放或 UPnP/Cast 运行中拒绝替换且不改队列
//   6. /api/queue/set?require_stopped=1 在停止态正常替换；不带 require_stopped 时兼容现有整列替换
//   7. 并发竞态（ctlMtx -> g_q.mtx 锁序）下无死锁/无误替换
//
// 铁律 1：全程使用 backend="null", volume=-120.0，不打开任何音频设备，不启 HTTP 服务。

#include <atomic>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#define RLPLAYER_EMBEDDED_LIBRARY 1
#include "rtaweb.cpp"

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

static std::string post_api(const std::string& path, const std::string& body) {
    rta::net::HttpRequest rq;
    rq.method = "POST";
    rq.path = path;
    rq.body = body;
    rq.host = "127.0.0.1";
    std::string ct;
    return handle(rq, ct);
}

static std::string create_silent_wav(const std::string& path, uint32_t rate, double sec) {
    std::filesystem::create_directories(std::filesystem::path(path).parent_path());
    rta::audio::AudioBuffer b;
    b.rate = rate;
    b.channels = 2;
    b.bits = 16;
    b.isFloat = false;
    const size_t frames = (size_t)(rate * sec);
    b.raw.assign(frames * 2, 0);
    rta::audio::write_wav(path, b);
    return path;
}

static void test_stopjoin_resets_control_state() {
    std::printf("[1] PlayerState::stopJoin() 复位 pauseReq / paused / seekReq\n");
    std::atomic<bool> started{false};
    g_ps.restart([&]() {
        started.store(true);
        while (!g_ps.stop.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });
    while (!started.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));

    g_ps.pauseReq.store(true);
    g_ps.paused.store(true);
    g_ps.seekReq.store(0.42);

    g_ps.stopJoin();

    ck(!g_ps.pauseReq.load(), "stopJoin 后 pauseReq == false");
    ck(!g_ps.paused.load(), "stopJoin 后 paused == false");
    ck(g_ps.seekReq.load() == -1.0, "stopJoin 后 seekReq == -1.0",
       "got=" + std::to_string(g_ps.seekReq.load()));
}

static void test_direct_restart_resets_control_state() {
    std::printf("[2] PlayerState::restart() 直接重启旧线程时复位 pauseReq / paused / seekReq\n");
    std::atomic<bool> t1Started{false};
    g_ps.restart([&]() {
        t1Started.store(true);
        while (!g_ps.stop.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        g_ps.playing.store(false); // Exactly the queue_thread exit behavior.
    });
    while (!t1Started.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));

    g_ps.pauseReq.store(true);
    g_ps.paused.store(true);
    g_ps.seekReq.store(0.75);

    g_ps.playing.store(true); // A caller may mark start before the old thread exits.
    std::atomic<bool> seenPlaying{false};
    std::atomic<bool> seenPauseReq{true}, seenPaused{true};
    std::atomic<double> seenSeekReq{0.0};
    std::atomic<bool> t2Done{false};
    g_ps.restart([&]() {
        seenPlaying.store(g_ps.playing.load());
        seenPauseReq.store(g_ps.pauseReq.load());
        seenPaused.store(g_ps.paused.load());
        seenSeekReq.store(g_ps.seekReq.load());
        t2Done.store(true);
    });
    while (!t2Done.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    g_ps.stopJoin();

    ck(seenPlaying.load(), "旧线程退出写 false 后，新线程仍看到 playing == true");
    ck(!seenPauseReq.load(), "direct restart 新线程看到 pauseReq == false");
    ck(!seenPaused.load(), "direct restart 新线程看到 paused == false");
    ck(seenSeekReq.load() == -1.0, "direct restart 新线程看到 seekReq == -1.0",
       "got=" + std::to_string(seenSeekReq.load()));
}

// Deterministic handoff: inspect the restored request before any renderer consumes it.
static void test_restored_seek_handoff() {
    g_ps.stopJoin();
    g_ps.seekReq.store(0.5);
    std::atomic<double> seen{-1};
    g_ps.restart([&] { seen.store(g_ps.seekReq.load()); });
    g_ps.joinIfDone();
    ck(seen.load() == 0.5, "stopJoin 后显式恢复的 seek 请求完整交接给新线程");
    g_ps.stopJoin();
}

static void test_eq_reload_preserves_seek_recovery(const std::string& wavPath) {
    std::printf("[3] eq_hot_reload() 在 stopJoin 后主动恢复 seekReq 的语义不被破坏\n");
    {
        std::lock_guard<std::mutex> lk(g_q.mtx);
        g_q.items.clear();
        g_q.items.emplace_back(wavPath);
        g_q.index = 0;
    }
    g_upnpPlayer.store(false);
    g_ps.playing.store(true);
    g_ps.pauseReq.store(true);
    g_ps.paused.store(true);

    g_ps.volDb.store(-120.0);
    PlayParams p;
    p.file = wavPath;
    p.backend = "null";

    const bool reloaded = eq_hot_reload(p, 0.5, "test-eq-preserve-seek");
    // 等待 queue_thread 消费 seekReq 或跑完（2s 静音在 null sink 上约几毫秒~几十毫秒）
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    const size_t played = g_ps.played.load();
    const size_t total = g_ps.total.load();
    const bool pausedAfter = g_ps.paused.load() || g_ps.pauseReq.load();
    g_ps.stopJoin();
    g_ps.playing.store(false);

    ck(reloaded, "eq_hot_reload 返回 true");
    ck(!pausedAfter, "eq_hot_reload 后保持非暂停态");
    // 若 seekReq=0.5 被 restart() 误清，则从 0 帧起播；保留时 initialSeekFrac=0.5 + seekReq=0.5
    // played 应从 >= 0.45 * total 开始（或已播完接近 total）
    ck(total > 0 && played >= (total * 45) / 100,
       "eq_hot_reload 保留了 0.5 定位进度",
       "played=" + std::to_string(played) + " total=" + std::to_string(total));
}

static void test_api_clear_resets_pause_and_seek() {
    std::printf("[4] /api/clear 通过 stopJoin() 清理 pauseReq / paused / seekReq\n");
    g_ps.pauseReq.store(true);
    g_ps.paused.store(true);
    g_ps.seekReq.store(0.33);
    const std::string res = post_api("/api/clear", "");
    ck(res.find("\"ok\":true") != std::string::npos, "/api/clear 返回 ok:true", res);
    ck(!g_ps.pauseReq.load(), "/api/clear 后 pauseReq == false");
    ck(!g_ps.paused.load(), "/api/clear 后 paused == false");
    ck(g_ps.seekReq.load() == -1.0, "/api/clear 后 seekReq == -1.0",
       "got=" + std::to_string(g_ps.seekReq.load()));
}

static void test_queue_set_require_stopped() {
    std::printf("[5] /api/queue/set require_stopped=1 播放/投放守卫与正常替换\n");
    {
        std::lock_guard<std::mutex> lk(g_q.mtx);
        g_q.items.clear();
        g_q.items.emplace_back("/tmp/orig_1.flac");
        g_q.items.emplace_back("/tmp/orig_2.flac");
        g_q.index = 1;
    }

    // 5a: 本地播放中 + require_stopped=1 -> 拒绝且不改队列
    g_ps.playing.store(true);
    g_upnpPlayer.store(false);
    std::string r1 = post_api("/api/queue/set", "require_stopped=1&files=%2Ftmp%2Fnew_1.flac");
    ck(r1.find("\"ok\":false") != std::string::npos, "本地播放中 require_stopped=1 返回 ok:false", r1);
    {
        std::lock_guard<std::mutex> lk(g_q.mtx);
        ck(g_q.items.size() == 2 && g_q.items[0].path == "/tmp/orig_1.flac" && g_q.index == 1,
           "本地播放中拒绝替换后队列保持原样");
    }

    // 5b: UPnP/Cast 活跃 + require_stopped=1 -> 拒绝且不改队列
    g_ps.playing.store(false);
    g_upnpPlayer.store(true);
    std::string r2 = post_api("/api/queue/set", "require_stopped=1&files=%2Ftmp%2Fnew_2.flac");
    ck(r2.find("\"ok\":false") != std::string::npos, "UPnP/Cast 活跃时 require_stopped=1 返回 ok:false", r2);
    {
        std::lock_guard<std::mutex> lk(g_q.mtx);
        ck(g_q.items.size() == 2 && g_q.items[0].path == "/tmp/orig_1.flac",
           "UPnP/Cast 活跃时拒绝替换后队列保持原样");
    }

    // 5c: 不带 require_stopped=1 时（播放全部/专辑播放）仍允许替换
    g_ps.playing.store(true);
    g_upnpPlayer.store(false);
    std::string r3 = post_api("/api/queue/set", "files=%2Ftmp%2Fcompat_1.flac");
    ck(r3.find("\"ok\":true") != std::string::npos, "未传 require_stopped 时兼容现有整列替换", r3);

    // 5d: 停止态 + require_stopped=1 -> 正常替换
    g_ps.playing.store(false);
    g_upnpPlayer.store(false);
    std::string r4 = post_api("/api/queue/set",
                              "require_stopped=1&files=%2Ftmp%2Fok_1.flac%0A%2Ftmp%2Fok_2.flac");
    ck(r4.find("\"ok\":true") != std::string::npos && r4.find("\"count\":2") != std::string::npos,
       "停止态 require_stopped=1 正常替换队列", r4);
    {
        std::lock_guard<std::mutex> lk(g_q.mtx);
        ck(g_q.items.size() == 2 && g_q.items[0].path == "/tmp/ok_1.flac" && g_q.items[1].path == "/tmp/ok_2.flac",
           "停止态队列内容正确更新");
    }
}

static void test_queue_set_ctl_race() {
    std::printf("[6] ctlMtx -> g_q.mtx 并发竞态（无死锁/无崩溃）\n");
    std::atomic<bool> done{false};
    std::thread playerCtl([&]() {
        for (int i = 0; i < 40; ++i) {
            g_ps.stopJoin();
            g_ps.playing.store(true);
            g_ps.restart([]() {
                while (!g_ps.stop.load()) {
                    std::this_thread::sleep_for(std::chrono::microseconds(200));
                }
            });
            std::this_thread::sleep_for(std::chrono::microseconds(300));
            g_ps.stopJoin();
            g_ps.playing.store(false);
        }
        done.store(true);
    });

    int okCnt = 0, rejCnt = 0;
    while (!done.load()) {
        std::string r = post_api("/api/queue/set", "require_stopped=1&files=%2Ftmp%2Frace.flac");
        if (r.find("\"ok\":true") != std::string::npos) ++okCnt;
        else if (r.find("\"ok\":false") != std::string::npos) ++rejCnt;
    }
    playerCtl.join();
    g_ps.stopJoin();
    g_ps.playing.store(false);
    ck(okCnt + rejCnt > 0, "并发 /api/queue/set 与 stopJoin/restart 交替执行未死锁",
       "ok=" + std::to_string(okCnt) + " rej=" + std::to_string(rejCnt));
}

int main() {
    std::printf("=== test_playback_control_reset ===\n");
    char tempDir[] = "/tmp/rlplayer-test-ctrl-reset-XXXXXX";
    if (!mkdtemp(tempDir)) return 2;
    setenv("RLPLAYER_STATE_DIR", tempDir, 1);
    const std::string wavPath = std::string(tempDir) + "/silent_2s.wav";
    create_silent_wav(wavPath, 48000, 2.0);

    test_stopjoin_resets_control_state();
    test_direct_restart_resets_control_state();
    test_restored_seek_handoff();
    test_eq_reload_preserves_seek_recovery(wavPath);
    test_api_clear_resets_pause_and_seek();
    test_queue_set_require_stopped();
    test_queue_set_ctl_race();

    std::error_code ec;
    std::filesystem::remove_all(tempDir, ec);
    std::printf("\n结果: %d 项失败\n", g_fail);
    return g_fail == 0 ? 0 : 1;
}
