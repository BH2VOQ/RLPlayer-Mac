// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_filter_settings_snapshot.cpp — POST /api/settings 滤波/DSP 键同步 g_params 与 queue_thread 下一曲采纳回归判据
//
// 覆盖：
//   1. POST /api/settings 写 filter/filterNx/sdmfilt/sdmfiltnx/phase/taps/transition/atten/twostage
//      后立即同步到 params_snapshot()（g_params），且不擅自热重启当前曲目（hotReload 不触发）。
//   2. POST /api/settings 被 422 准入闸门拒绝时，g_params 不被污染。
//   3. /api/skip 切到下一曲时采纳最新滤波/DSP 设置。
//   4. queue_thread 自动续播下一曲时采纳最新听感 DSP 设置，同时：
//      - 不破坏当前设备会话（backend / device / volume / bufferMs）；
//      - 复位 one-shot initialSeekFrac（不把首曲定位带到下一曲）。
//
// 铁律 1：全程使用 backend="null", volume=-120.0，不打开任何音频设备，不启 HTTP 服务，不碰 8899。

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#define RLPLAYER_EMBEDDED_LIBRARY 1
#include "rtaweb.cpp"

static int g_fail = 0;
static int g_pass = 0;

static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) {
        ++g_pass;
        std::printf("  [PASS] %s\n", what);
    } else {
        ++g_fail;
        std::printf("  [FAIL] %s%s%s\n", what, detail.empty() ? "" : " — ", detail.c_str());
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

static bool wait_until(const std::function<bool()>& pred, int timeoutMs) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (std::chrono::steady_clock::now() < deadline) {
        if (pred()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return pred();
}

static void test_settings_post_updates_gparams_without_hot_reload(const std::string& wav1) {
    std::printf("[1] POST /api/settings 更新 9 个滤波/DSP 键到 g_params 且不热重启当前曲\n");
    g_ps.stopJoin();
    {
        std::lock_guard<std::mutex> lk(g_q.mtx);
        g_q.items = { QItem(wav1, -1.0, -1.0) };
        g_q.index = 0;
        g_q.mode = 0;
    }

    PlayParams init;
    init.file = wav1;
    init.backend = "null";
    init.volume = -120.0;
    init.rate = "96000";
    init.filter = "poly-sinc-short-lp";
    init.filterNx = "poly-sinc-short-lp";
    init.sdmFilter = "poly-sinc-short-lp";
    init.sdmFilterNx = "poly-sinc-short-lp";
    init.phase = "linear";
    init.taps = 4096;
    init.transition = 0.04;
    init.atten = 180.0;
    init.twoStage = true;
    params_store(init);

    // 模拟当前正在播放（但不触发真实音频设备）
    std::atomic<bool> playingEntered{false};
    g_ps.playing.store(true);
    g_ps.restart([&]() {
        playingEntered.store(true);
        while (!g_ps.stop.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    });
    wait_until([&]() { return playingEntered.load(); }, 1000);

    const std::string resp = post_api(
        "/api/settings",
        "filter=poly-sinc-long-lp&filterNx=poly-sinc-ext2&sdmfilt=poly-sinc-gauss&"
        "sdmfiltnx=poly-sinc-short-mp&phase=minimum&taps=16384&transition=0.075&"
        "atten=145.5&twostage=0");

    ck(resp.find("\"ok\":true") != std::string::npos, "POST /api/settings 返回 ok:true", resp);
    ck(resp.find("\"hotReload\":true") == std::string::npos, "修改滤波参数不擅自热重启当前曲", resp);
    ck(!g_ps.stop.load(), "正在运行的播放线程未被 stopJoin 打断");

    const PlayParams snap = params_snapshot();
    ck(snap.filter == "poly-sinc-long-lp", "g_params.filter 已更新", snap.filter);
    ck(snap.filterNx == "poly-sinc-ext2", "g_params.filterNx 已更新", snap.filterNx);
    ck(snap.sdmFilter == "poly-sinc-gauss", "g_params.sdmFilter 已更新", snap.sdmFilter);
    ck(snap.sdmFilterNx == "poly-sinc-short-mp", "g_params.sdmFilterNx 已更新", snap.sdmFilterNx);
    ck(snap.phase == "minimum", "g_params.phase 已更新", snap.phase);
    ck(snap.taps == 16384, "g_params.taps 已更新", std::to_string(snap.taps));
    ck(std::abs(snap.transition - 0.075) < 1e-6, "g_params.transition 已更新", std::to_string(snap.transition));
    ck(std::abs(snap.atten - 145.5) < 1e-6, "g_params.atten 已更新", std::to_string(snap.atten));
    ck(snap.twoStage == false, "g_params.twoStage 已更新为 false");

    g_ps.stopJoin();
    g_ps.playing.store(false);
}

static void test_settings_422_does_not_pollute_gparams() {
    std::printf("[2] POST /api/settings 被 422 准入闸门拒绝时不污染 g_params\n");
    PlayParams before = params_snapshot();
    before.filter = "poly-sinc-short-lp";
    before.taps = 4096;
    params_store(before);

    const std::string rej = post_api(
        "/api/settings",
        "filter=poly-sinc-long-lp&taps=32768&dsd=128&modfamily=dsd&modcut=10");
    ck(rej.find("\"ok\":false") != std::string::npos, "SDM 422 闸门拒绝非法配置", rej);

    const PlayParams after = params_snapshot();
    ck(after.filter == "poly-sinc-short-lp", "422 拒绝后 g_params.filter 未被修改", after.filter);
    ck(after.taps == 4096, "422 拒绝后 g_params.taps 未被修改", std::to_string(after.taps));
}

static void test_skip_adopts_latest_filter_settings(const std::string& wav1, const std::string& wav2) {
    std::printf("[3] /api/skip 切到下一曲时采纳最新滤波/DSP 设置\n");
    g_ps.stopJoin();
    g_ps.playing.store(false);

    // 写入安全测试会话参数（backend=null, volume=-120）
    const std::string setInit = post_api(
        "/api/settings",
        "backend=null&volume=-120&rate=96000&dsd=0&filter=poly-sinc-short-lp&phase=linear&taps=4096&twostage=1");
    ck(setInit.find("\"ok\":true") != std::string::npos, "初始化安全测试 conf", setInit);

    const std::string qset = post_api("/api/queue/set", "files=" + wav1 + "%0A" + wav2);
    ck(qset.find("\"ok\":true") != std::string::npos, "设置两曲队列", qset);

    const std::string playResp = post_api("/api/play", "file=" + wav1 + "&backend=null&volume=-120&rate=96000");
    ck(playResp.find("\"ok\":true") != std::string::npos, "起播第 1 曲", playResp);

    const std::string upd = post_api("/api/settings", "filter=poly-sinc-long-lp&phase=minimum&taps=8192&twostage=0");
    ck(upd.find("\"ok\":true") != std::string::npos, "播放中更新滤波设置", upd);

    const std::string skipResp = post_api("/api/skip?dir=1", "");
    ck(skipResp.find("\"ok\":true") != std::string::npos, "/api/skip 切到第 2 曲", skipResp);

    const bool gotSignal = wait_until([&]() {
        std::lock_guard<std::mutex> lk(g_ps.mtx);
        return g_ps.current == wav2 && !g_ps.signal.empty();
    }, 15000);
    ck(gotSignal, "第 2 曲产出信号链快照");

    std::string sig;
    {
        std::lock_guard<std::mutex> lk(g_ps.mtx);
        sig = g_ps.signal;
    }
    // 2026-11-21：判据口径对齐 8b9e446「report real polyphase taps」。
    // 那条提交之后，信号链里的 `taps` 是**实际系数个数**（poly-sinc-long-lp @44.1k→96k
    // 实测 90240 = 282 taps/phase × 320 相位），而**用户设定的预算**在 `nominalTaps`。
    // 本条要证明的是「切曲后用户最新选定的抽头预算真的生效」⟹ 断言 nominalTaps。
    // （旧断言写死 taps=8192，是 8b9e446 之前的口径，此后恒红；实测同快照里
    //   nominalTaps:8192、taps:90240、filter:poly-sinc-long-lp，参数确实生效了。）
    ck(sig.find("\"nominalTaps\":8192") != std::string::npos,
       "skip 后第 2 曲采用用户设定的抽头预算 nominalTaps=8192", sig);
    ck(sig.find("\"filter\":\"poly-sinc-long-lp\"") != std::string::npos,
       "skip 后第 2 曲采用最新滤波器 poly-sinc-long-lp", sig);
    ck(sig.find("\"phaseCode\":\"minimum\"") != std::string::npos, "skip 后第 2 曲采用 phaseCode=minimum", sig);
    ck(sig.find("\"deviceId\":\"null\"") != std::string::npos, "skip 后仍保持 null 后端", sig);

    g_ps.stopJoin();
    g_ps.playing.store(false);
}

static void test_queue_thread_auto_advance_preserves_session_and_adopts_dsp(
    const std::string& wav1, const std::string& wav2) {
    std::printf("[4] queue_thread 自动续播采纳最新 DSP 设置且不破坏会话/初始 seek\n");
    g_ps.stopJoin();
    g_ps.playing.store(false);

    {
        std::lock_guard<std::mutex> lk(g_q.mtx);
        g_q.items = { QItem(wav1, -1.0, -1.0), QItem(wav2, -1.0, -1.0) };
        g_q.index = 0;
        g_q.mode = 0;
    }

    PlayParams sessionP;
    sessionP.file = wav1;
    sessionP.backend = "null";
    sessionP.device = "test-session-dev";
    sessionP.bufferMs = 120;
    sessionP.volume = -120.0;
    sessionP.rate = "384000"; // 8x 升频，能观测 twoStage 变化
    sessionP.filter = "poly-sinc-short-lp";
    sessionP.phase = "linear";
    sessionP.taps = 4096;
    sessionP.twoStage = true;
    sessionP.initialSeekFrac = 0.25; // 首曲 one-shot seek
    params_store(sessionP);

    // 模拟 g_params 被外部（或设置页）改写，其中包含危险字段（若全量覆盖会破坏会话）
    PlayParams pollutedSnap = sessionP;
    pollutedSnap.backend = "coreaudio"; // 若盲目全量拷贝会破坏 null 会话！
    pollutedSnap.volume = 0.0;          // 若盲目全量拷贝会破坏 -120 dB！
    pollutedSnap.device = "wrong-dev";
    pollutedSnap.initialSeekFrac = 0.75; // 若盲目全量拷贝会破坏下一曲起点！
    pollutedSnap.filter = "poly-sinc-long-lp";
    pollutedSnap.phase = "minimum";
    pollutedSnap.taps = 8192;
    pollutedSnap.twoStage = false;
    params_store(pollutedSnap);

    g_ps.playing.store(true);
    g_ps.restart([sessionP]() { return queue_thread(sessionP, 0); });

    // 等第 2 曲开始并产出 signal
    const bool track2Started = wait_until([&]() {
        std::lock_guard<std::mutex> lk(g_ps.mtx);
        return g_ps.current == wav2 && !g_ps.signal.empty();
    }, 25000);
    ck(track2Started, "queue_thread 自动续播进入第 2 曲并产出信号链");

    std::string sig2;
    {
        std::lock_guard<std::mutex> lk(g_ps.mtx);
        sig2 = g_ps.signal;
    }
    ck(sig2.find("\"nominalTaps\":8192") != std::string::npos,
       "自动续播第 2 曲采用用户设定的抽头预算 nominalTaps=8192", sig2);
    ck(sig2.find("\"phaseCode\":\"minimum\"") != std::string::npos, "自动续播第 2 曲采用 phaseCode=minimum", sig2);
    ck(sig2.find("\"twoStage\":false") != std::string::npos, "自动续播第 2 曲采用 twoStage=false", sig2);
    ck(sig2.find("\"deviceId\":\"null\"") != std::string::npos, "自动续播第 2 曲保持会话 backend=null", sig2);

    // 等队列自然结束，检查第 2 曲 played == total（未继承 initialSeekFrac）
    const bool finished = wait_until([&]() { return !g_ps.playing.load(); }, 25000);
    g_ps.stopJoin();
    const size_t pl2 = g_ps.played.load();
    const size_t tt2 = g_ps.total.load();
    ck(finished && tt2 > 0 && pl2 >= tt2 && pl2 < tt2 + tt2 / 10,
       "自动续播第 2 曲完整播放（未继承首曲 initialSeekFrac）",
       "finished=" + std::to_string(finished) + " played=" + std::to_string(pl2) + " total=" + std::to_string(tt2));
}

int main() {
    std::printf("=== test_filter_settings_snapshot ===\n");
    char tempDir[] = "/tmp/rlplayer-test-filter-snap-XXXXXX";
    if (!mkdtemp(tempDir)) return 2;
    setenv("RLPLAYER_STATE_DIR", tempDir, 1);

    const std::string wav1 = std::string(tempDir) + "/t1.wav";
    const std::string wav2 = std::string(tempDir) + "/t2.wav";
    create_silent_wav(wav1, 44100, 0.3);
    create_silent_wav(wav2, 44100, 0.3);

    test_settings_post_updates_gparams_without_hot_reload(wav1);
    test_settings_422_does_not_pollute_gparams();
    test_skip_adopts_latest_filter_settings(wav1, wav2);
    test_queue_thread_auto_advance_preserves_session_and_adopts_dsp(wav1, wav2);

    if (g_pre.th.joinable()) g_pre.th.join();
    std::error_code ec;
    std::filesystem::remove_all(tempDir, ec);
    std::printf("\n结果: %d 通过, %d 失败\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
