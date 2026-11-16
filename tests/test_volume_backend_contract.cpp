// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_volume_backend_contract.cpp — 后端音量 [-120, +20] dB 契约与 DSP/CoreAudioSink/HTTP 状态测试
// 离线运行：不启动 HTTP 服务，不打开真实音频设备，仅用 null 后端与离线对象。
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#define RLPLAYER_EMBEDDED_LIBRARY 1
#include "rtaweb.cpp"

namespace fs = std::filesystem;

static int g_fails = 0;
static void ck(bool cond, const char* desc, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", desc);
    } else {
        std::printf("  [FAIL] %s %s\n", desc, detail.c_str());
        ++g_fails;
    }
}

static rta::net::HttpRequest make_req(const std::string& method, const std::string& path,
                                      const std::string& body = "") {
    rta::net::HttpRequest rq;
    rq.method = method;
    rq.path = path;
    rq.body = body;
    return rq;
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("=== test_volume_backend_contract: [-120, +20] dB 后端音量契约 ===\n");

    const fs::path tmpDir = fs::temp_directory_path() / "rlplayer_test_volume_backend_contract";
    std::error_code ec;
    fs::remove_all(tmpDir, ec);
    fs::create_directories(tmpDir, ec);
    setenv("RLPLAYER_STATE_DIR", tmpDir.c_str(), 1);

    // ---- 1. CoreAudioSink live/base clamps [-120, +20] 与 -80 dB 非提前静音 ----
    {
        CoreAudioSink ca;
        ca.set_base_gain_db(0.0);
        ca.set_live_gain_db(0.0);
        ck(ca.render_gain() == 1.0, "Case 1a: 0 dB 增益精确为 1.0");

        ca.set_live_gain_db(6.0);
        const double g6 = ca.render_gain();
        const double exp6 = std::pow(10.0, 6.0 / 20.0);
        ck(std::fabs(g6 - exp6) < 1e-6 && g6 > 1.9,
           "Case 1b: CoreAudioSink live +6 dB 不被夹到 0 dB",
           "got=" + std::to_string(g6));

        ca.set_live_gain_db(20.0);
        const double g20 = ca.render_gain();
        ck(std::fabs(g20 - 10.0) < 1e-6,
           "Case 1c: CoreAudioSink live +20 dB = 10.0",
           "got=" + std::to_string(g20));

        ca.set_live_gain_db(28.0);
        const double gClamp = ca.render_gain();
        ck(std::fabs(gClamp - 10.0) < 1e-6,
           "Case 1d: CoreAudioSink live +28 dB 夹紧到 +20 dB (10.0)",
           "got=" + std::to_string(gClamp));

        ca.set_base_gain_db(12.0);
        const double gBase12 = ca.render_gain();
        const double exp12 = std::pow(10.0, 12.0 / 20.0);
        ck(std::fabs(gBase12 - exp12) < 1e-6,
           "Case 1e: CoreAudioSink base +12 dB 不被夹到 0 dB",
           "got=" + std::to_string(gBase12));

        ca.set_base_gain_db(0.0);
        ca.set_live_gain_db(-80.0);
        const double g80 = ca.render_gain();
        const double exp80 = std::pow(10.0, -80.0 / 20.0);
        ck(g80 > 0.0 && std::fabs(g80 - exp80) < 1e-9,
           "Case 1f: CoreAudioSink -80 dB 不被 -59.5 提前静音",
           "got=" + std::to_string(g80));

        ca.set_live_gain_db(-120.0);
        ck(ca.render_gain() == 0.0,
           "Case 1g: CoreAudioSink -120 dB 为真静音 (0.0)",
           "got=" + std::to_string(ca.render_gain()));
    }

    // ---- 2. 0 dB 逐位语义 & 正增益真实 DSP 输出（VolumeControl + scale_sample_i32 + Pipeline）----
    {
        const int32_t sIn = 123456;
        ck(rta::platform::detail::scale_sample_i32(sIn, 24, 1.0) == sIn,
           "Case 2a: scale_sample_i32 0 dB (g=1.0) 逐位一致");
        const int32_t sBoost = rta::platform::detail::scale_sample_i32(sIn, 24, std::pow(10.0, 6.0 / 20.0));
        ck(sBoost > 240000 && sBoost < 250000,
           "Case 2b: scale_sample_i32 +6 dB 正增益真实放大",
           "got=" + std::to_string(sBoost));

        rta::dsp::VolumeControl vc;
        vc.set_sample_rate(44100.0);
        vc.set_ramp_ms(0.0);
        vc.set_gain_db(0.0);
        vc.snap();
        const double x0 = 0.123456789012345;
        ck(vc.process(x0) == x0, "Case 2c: VolumeControl 0 dB 逐位一致");

        vc.set_gain_db(6.0);
        vc.snap();
        const double y6 = vc.process(0.1);
        ck(std::fabs(y6 - 0.1 * std::pow(10.0, 6.0 / 20.0)) < 1e-9,
           "Case 2d: VolumeControl +6 dB 正增益真实输出",
           "got=" + std::to_string(y6));

        vc.set_gain_db(-80.0);
        vc.snap();
        const double y80 = vc.process(1.0);
        ck(y80 > 0.0 && std::fabs(y80 - 1e-4) < 1e-9,
           "Case 2e: VolumeControl -80 dB 非提前静音",
           "got=" + std::to_string(y80));
    }

    // ---- 3. /api/volume HTTP 契约：正增益 / -80 / 非法数字拒绝且不改状态 / 原始 DSD 锁 ----
    {
        g_ps.playing.store(false);
        {
            std::lock_guard<std::mutex> lk(g_ps.mtx);
            g_ps.rawVolumeLocked = false;
        }
        g_ps.volDb.store(-120.0);

        std::string ct;
        std::string r1 = handle(make_req("POST", "/api/volume?db=6"), ct);
        ck(r1.find("\"ok\":true") != std::string::npos && std::fabs(g_ps.volDb.load() - 6.0) < 1e-6,
           "Case 3a: /api/volume?db=6 接受正增益 +6 dB", r1);

        std::string r2 = handle(make_req("POST", "/api/volume?db=25"), ct);
        ck(r2.find("\"ok\":true") != std::string::npos && std::fabs(g_ps.volDb.load() - 20.0) < 1e-6,
           "Case 3b: /api/volume?db=25 夹紧到 +20 dB", r2);

        std::string r3 = handle(make_req("POST", "/api/volume?db=-80"), ct);
        ck(r3.find("\"ok\":true") != std::string::npos && std::fabs(g_ps.volDb.load() - (-80.0)) < 1e-6,
           "Case 3c: /api/volume?db=-80 接受 -80 dB", r3);

        for (const char* bad : {"/api/volume?db=nan", "/api/volume?db=inf", "/api/volume?db=12abc", "/api/volume?db=", "/api/volume"}) {
            const double before = g_ps.volDb.load();
            std::string rb = handle(make_req("POST", bad), ct);
            ck(rb.find("\"ok\":false") != std::string::npos && std::fabs(g_ps.volDb.load() - before) < 1e-9,
               (std::string("Case 3d: 非法输入拒绝且不改状态: ") + bad).c_str(), rb);
        }

        // 原始 DSD 音量锁保护 + /api/status volumeWritable/rawVolumeLocked
        g_ps.volDb.store(0.0);
        g_ps.startDb.store(0.0);
        g_ps.playing.store(true);
        {
            std::lock_guard<std::mutex> lk(g_ps.mtx);
            g_ps.rawVolumeLocked = true;
        }
        std::string stLocked = handle(make_req("GET", "/api/status"), ct);
        ck(stLocked.find("\"rawVolumeLocked\":true") != std::string::npos &&
           stLocked.find("\"volumeWritable\":false") != std::string::npos,
           "Case 3e: 原始 DSD 播放中 /api/status 报告 rawVolumeLocked=true, volumeWritable=false",
           stLocked);

        std::string rLockReject = handle(make_req("POST", "/api/volume?db=-6"), ct);
        ck(rLockReject.find("\"ok\":false") != std::string::npos &&
           rLockReject.find("\"rawVolumeLocked\":true") != std::string::npos &&
           std::fabs(g_ps.volDb.load()) < 1e-9,
           "Case 3f: 原始 DSD 锁定时拒绝非 0 dB 音量且保持 0 dB", rLockReject);

        std::string rLockZero = handle(make_req("POST", "/api/volume?db=0"), ct);
        ck(rLockZero.find("\"ok\":true") != std::string::npos,
           "Case 3g: 原始 DSD 锁定时允许 db=0", rLockZero);

        g_ps.playing.store(false);
        {
            std::lock_guard<std::mutex> lk(g_ps.mtx);
            g_ps.rawVolumeLocked = false;
        }
        std::string stUnlocked = handle(make_req("GET", "/api/status"), ct);
        ck(stUnlocked.find("\"rawVolumeLocked\":false") != std::string::npos &&
           stUnlocked.find("\"volumeWritable\":true") != std::string::npos,
           "Case 3h: 停止后 /api/status 报告 rawVolumeLocked=false, volumeWritable=true",
           stUnlocked);
    }

    // ---- 4. parseForm / /api/settings 持久化 [-120, +20] 与拒绝非法数字 ----
    {
        const PlayParams p12 = parseForm("backend=null&volume=12.5");
        ck(p12.backend == "null" && std::fabs(p12.volume - 12.5) < 1e-6,
           "Case 4a: parseForm 支持正增益 +12.5 dB");

        const PlayParams pClamp = parseForm("backend=null&volume=35");
        ck(std::fabs(pClamp.volume - 20.0) < 1e-6,
           "Case 4b: parseForm 超上限夹紧到 +20 dB");

        const PlayParams pNan = parseForm("backend=null&volume=nan");
        ck(std::isfinite(pNan.volume) && pNan.volume == 0.0,
           "Case 4c: parseForm 拒绝 NaN（不写入 NaN）");

        std::string ct;
        std::string sOk = handle(make_req("POST", "/api/settings", "backend=null&volume=15"), ct);
        ck(sOk.find("\"ok\":true") != std::string::npos, "Case 4d: /api/settings 保存 volume=15", sOk);
        std::string sBad = handle(make_req("POST", "/api/settings", "volume=nan"), ct);
        ck(sBad.find("\"ok\":false") != std::string::npos, "Case 4e: /api/settings 拒绝 volume=nan", sBad);
        std::string sGet = handle(make_req("GET", "/api/settings"), ct);
        ck(sGet.find("\"volume\":\"15\"") != std::string::npos,
           "Case 4f: /api/settings 拒绝非法值后旧值 15 未被破坏", sGet);
    }

    // Global volume must survive a new album/play request, not just the live sink.
    {
        std::string ct;
        handle(make_req("POST", "/api/settings", "backend=null&volume=-120"), ct);
        const auto result = handle(make_req("POST", "/api/volume?db=-80"), ct);
        const auto next = apply_conf_defaults_for_play(parseForm("backend=null&file=next-album.wav"), {"backend", "file"});
        ck(result.find("\"ok\":true") != std::string::npos && std::fabs(next.volume + 80.0) < 1e-9,
           "Case 5a: next album inherits the user global volume", std::to_string(next.volume));
        ck(std::fabs(saved_volume_setting() + 80.0) < 1e-9,
           "Case 5b: live volume is persisted for subsequent playback");
    }

    {
        std::string ct;
        g_ps.playing.store(true);
        g_ps.bpInputs = {};
        g_ps.bpInputs.inRate = g_ps.bpInputs.outRate = 44100;
        g_ps.bpInputs.srcBits = g_ps.bpInputs.outBits = 24;
        g_ps.bpInputs.volumeDb = -80.0;
        g_ps.bpInputsKnown = true;
        const auto before = rta::audio::bp_verdict(g_ps.bpInputs);
        g_ps.bpState = before.state; g_ps.bpWhy = before.why;
        handle(make_req("POST", "/api/volume?db=0"), ct);
        ck(g_ps.bpState == "yes", "Case 6a: removing only volume attenuation recalculates bit-perfect");
        g_ps.bpInputs.sharedMixer = true;
        handle(make_req("POST", "/api/volume?db=-80"), ct);
        handle(make_req("POST", "/api/volume?db=0"), ct);
        ck(g_ps.bpState == "no" && g_ps.bpWhy.find("共享") != std::string::npos,
           "Case 6b: unity volume cannot conceal shared output");
        g_ps.playing.store(false);
        g_ps.bpInputsKnown = false;
    }

    // Cold retry must stay a single bounded attempt: never after success, never after stop,
    // never once the track has effectively finished.
    {
        ck(!should_cold_retry_shared(true, false, 0.10), "Case 7a: success never triggers a retry");
        ck(!should_cold_retry_shared(false, true, 0.10), "Case 7b: user stop never triggers a retry");
        ck(!should_cold_retry_shared(false, false, 0.999), "Case 7c: finished track never triggers a retry");
        ck(should_cold_retry_shared(false, false, 0.40), "Case 7d: failed mid-track allows exactly one retry");

        // The signal-chain readout must never claim hardware exclusivity when the
        // active backend is the shared fallback (2026-11-17 audit).
        ck(signal_shared_only(true,  "coreaudio"),      "Case 8a: shared-only device reports shared");
        ck(signal_shared_only(false, "coreaudio-shared"), "Case 8b: shared fallback reports shared");
        ck(!signal_shared_only(false, "coreaudio"),      "Case 8c: true exclusive path stays exclusive");
        ck(std::string(signal_out_mode("coreaudio-shared")) == "shared" &&
           std::string(signal_out_mode("coreaudio")) == "exclusive",
           "Case 8d: outMode tracks the active backend");

        // Image magic classification (2026-11-17): WebP/GIF must NOT be rejected as
        // "not a valid image" (the old PNG/JPEG-only path returned 502 for valid art).
        {
            const unsigned char png[] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
            const unsigned char jpg[] = {0xFF, 0xD8, 0xFF, 0xE0};
            const unsigned char webp[] = {'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'E', 'B', 'P'};
            const unsigned char gif[] = {'G', 'I', 'F', '8', '9', 'a'};
            const unsigned char junk[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
            const char* pt = image_content_type_by_magic(png, sizeof png);
            const char* jt = image_content_type_by_magic(jpg, sizeof jpg);
            const char* wt = image_content_type_by_magic(webp, sizeof webp);
            const char* gt = image_content_type_by_magic(gif, sizeof gif);
            ck(pt && std::string(pt) == "image/png", "Case 9a: PNG magic → image/png", pt ? pt : "null");
            ck(jt && std::string(jt) == "image/jpeg", "Case 9b: JPEG magic → image/jpeg", jt ? jt : "null");
            ck(wt && std::string(wt) == "image/webp", "Case 9c: WebP magic → image/webp", wt ? wt : "null");
            ck(gt && std::string(gt) == "image/gif", "Case 9d: GIF magic → image/gif", gt ? gt : "null");
            ck(image_content_type_by_magic(junk, sizeof junk) == nullptr, "Case 9e: junk bytes → nullptr (502 path preserved)");
        }
    }

    fs::remove_all(tmpDir, ec);
    if (g_fails == 0) std::printf("\n[ALL PASS] test_volume_backend_contract 全部通过\n");
    else               std::printf("\n[FAILED] %d 项未通过\n", g_fails);
    return g_fails == 0 ? 0 : 1;
}
