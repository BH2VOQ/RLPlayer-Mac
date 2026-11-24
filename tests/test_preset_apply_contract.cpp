// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_preset_apply_contract.cpp — 预设事务、脏配置清理回读、8条件直通、/api/filters 与 uimode 契约
// 离线运行：不启动 HTTP 服务，不打开真实音频设备，不触碰 8899。
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

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
    std::printf("=== test_preset_apply_contract: 预设事务 / 脏配置清理 / 8条件直通 / filters / uimode ===\n");

    const fs::path tmpDir = fs::temp_directory_path() / "rlplayer_test_preset_apply_contract";
    std::error_code ec;
    fs::remove_all(tmpDir, ec);
    fs::create_directories(tmpDir, ec);
    setenv("RLPLAYER_STATE_DIR", tmpDir.c_str(), 1);

    // ---- 1. 脏配置写入 → /api/preset/apply?profile=bitperfect 完整事务清理与回读 ----
    {
        const fs::path confPath = tmpDir / "rlplayer-settings.conf";
        {
            std::ofstream f(confPath);
            f << "backend=null\n"
              << "volume=-120\n"
              << "taps=4096\n"
              << "mintapsperinput=1024\n"
              << "phase=minimum\n"
              << "atten=90\n"
              << "transition=0.25\n"
              << "modfamily=ec\n"
              << "modorder=9\n"
              << "modcut=150\n"
              << "moddith=0.5\n"
              << "oobgain=8\n"
              << "ahmbits=6\n"
              << "rg.mode=album\n"
              << "rgmode=album\n"
              << "rg.preamp=6.0\n"
              << "opraproduct=HD650\n"
              << "oprapreset=Oratory1990\n"
              << "opravendor=Sennheiser\n"
              << "eq=old.txt\n"
              << "ir=old.wav\n"
              << "irgpu=1\n"
              << "loudness=1\n"
              << "trim=1,2,3,4,5,6,7,8\n"
              << "isp=1\n";
        }
        peq_load_current();
        if (g_peq) {
            auto peq = g_peq->settings();
            peq.bypass = false;
            g_peq->set_settings(peq);
            peq_save_current(peq);
        }

        std::string ct;
        const std::string res = handle(make_req("POST", "/api/preset/apply?profile=bitperfect&src=pcm&srcrate=44100&srcbits=16"), ct);
        ck(res.find("\"ok\":true") != std::string::npos, "Case 1a: /api/preset/apply?profile=bitperfect 返回 ok=true", res);
        ck(res.find("\"rate\":\"src\"") != std::string::npos, "Case 1b: applied.rate == src (非 follow)", res);
        ck(res.find("\"bitPerfectOk\":false") != std::string::npos &&
           res.find("⑧") != std::string::npos,
           "Case 1c: backend=null/非独占时 8 条件直通校验返回 bitPerfectOk=false 且点名⑧", res);

        const std::string got = handle(make_req("GET", "/api/settings"), ct);
        ck(got.find("\"rate\":\"src\"") != std::string::npos, "Case 1d: conf 回读 rate=src", got);
        ck(got.find("\"volume\":\"-120\"") != std::string::npos,
           "Case 1d-volume: applying a preset preserves global volume", got);
        ck(got.find("\"taps\":\"0\"") != std::string::npos &&
           got.find("\"mintapsperinput\":\"0\"") != std::string::npos &&
           got.find("\"phase\":\"\"") != std::string::npos &&
           got.find("\"atten\":\"0\"") != std::string::npos &&
           got.find("\"transition\":\"0\"") != std::string::npos,
           "Case 1e: 清除了 taps/mintapsperinput/phase/atten/transition 旧覆盖", got);
        ck(got.find("\"modfamily\":\"dsd\"") != std::string::npos &&
           got.find("\"modorder\":\"5\"") != std::string::npos &&
           got.find("\"modcut\":\"0\"") != std::string::npos &&
           got.find("\"oobgain\":\"5\"") != std::string::npos &&
           got.find("\"ahmbits\":\"8\"") != std::string::npos,
           "Case 1f: 调制旧值已复位为安全默认值（不盲目清 0 触发 SDM 闸门）", got);
        ck(got.find("\"rg.mode\":\"off\"") != std::string::npos &&
           got.find("\"rgmode\":\"off\"") != std::string::npos &&
           got.find("\"opraproduct\":\"\"") != std::string::npos &&
           got.find("\"oprapreset\":\"\"") != std::string::npos &&
           got.find("\"opravendor\":\"\"") != std::string::npos,
           "Case 1g: 清除了 RG 与 OPRA 残留", got);
        ck(!g_peq || g_peq->settings().bypass, "Case 1h: PEQ 已自动旁路");

        // 证明清理后的调制默认值可通过 SDM 闸门（不会误拒）
        const std::string sdmOk = handle(make_req("POST", "/api/settings", "dsd=64"), ct);
        ck(sdmOk.find("\"ok\":true") != std::string::npos,
           "Case 1i: 清理后的默认调制参数可通过 SDM 1-bit 闸门", sdmOk);
    }

    // ---- 2. /api/filters 含 auto 解析与真实 metadata ----
    {
        std::string ct;
        const std::string f1x = handle(make_req("GET", "/api/filters?fs=44100&content=20000"), ct);
        ck(f1x.find("\"ok\":true") != std::string::npos, "Case 2a: /api/filters 返回 ok=true");
        ck(f1x.find("\"name\":\"auto\"") != std::string::npos &&
           f1x.find("\"resolved\":\"poly-sinc-short-lp\"") != std::string::npos,
           "Case 2b: /api/filters 含 auto 且 resolved 真实解析为 poly-sinc-short-lp", f1x);
        ck(f1x.find("\"attenDb\":") != std::string::npos &&
           f1x.find("\"transition\":") != std::string::npos &&
           f1x.find("\"family\":\"") != std::string::npos,
           "Case 2c: /api/filters 返回真实 metadata (attenDb/transition/family)");
    }

    // ---- 3. /api/settings uimode 白名单 (listen | pro, 默认 listen) ----
    {
        std::string ct;
        const std::string g0 = handle(make_req("GET", "/api/settings"), ct);
        ck(g0.find("\"uimode\":\"listen\"") != std::string::npos,
           "Case 3a: GET /api/settings 默认 uimode=listen", g0);

        const std::string pPro = handle(make_req("POST", "/api/settings", "uimode=pro"), ct);
        ck(pPro.find("\"ok\":true") != std::string::npos, "Case 3b: POST uimode=pro 成功", pPro);
        const std::string g1 = handle(make_req("GET", "/api/settings"), ct);
        ck(g1.find("\"uimode\":\"pro\"") != std::string::npos &&
           g1.find("\"backend\":\"null\"") != std::string::npos,
           "Case 3c: uimode=pro 落盘且不改设备/后端", g1);

        const std::string pBad = handle(make_req("POST", "/api/settings", "uimode=expert"), ct);
        ck(pBad.find("\"ok\":false") != std::string::npos, "Case 3d: POST uimode=expert 被拒绝", pBad);
        const std::string g2 = handle(make_req("GET", "/api/settings"), ct);
        ck(g2.find("\"uimode\":\"pro\"") != std::string::npos,
           "Case 3e: 拒绝非法 uimode 后保留原值 pro", g2);
    }

    // Legacy UI values must use the same DSD contract as numeric playback values.
    {
        const auto dop = parseForm("backend=null&volume=-120&dsd=dop256");
        ck(dop.dsd == 256 && !dop.dsdNative, "Case 4a: legacy dop256 parses as DSD256 DoP");
        const auto native = parseForm("backend=null&volume=-120&dsd=native128");
        ck(native.dsd == 128 && native.dsdNative, "Case 4b: legacy native marker cannot silently become PCM/DoP");
        std::string err, ct;
        conf_merge_write({{"dsd", "dop128"}, {"dsdnative", "0"}, {"modfamily", "dsd"}, {"modcut", "100"}}, err);
        const auto inherited = apply_conf_defaults_for_play(parseForm("backend=null"), {"backend"});
        ck(inherited.dsd == 128 && !inherited.dsdNative, "Case 4c: legacy persisted DoP survives next-play defaults");
        const auto rejected = handle(make_req("POST", "/api/settings", "dsd=dop256&modfamily=dsd&modcut=50"), ct);
        ck(rejected.find("sdm.corner_quality") != std::string::npos && conf_get("dsd", "") == "dop128",
           "Case 4d: prefixed DSD cannot bypass corner admission or mutate saved state", rejected);
        const auto accepted = handle(make_req("POST", "/api/settings", "dsd=dop256&dsdnative=0&modfamily=dsd&modcut=100"), ct);
        ck(accepted.find("\"ok\":true") != std::string::npos && conf_get("dsd", "") == "256",
           "Case 4e: valid DoP persists a canonical numeric multiplier", accepted);
        const auto noNative = handle(make_req("POST", "/api/settings", "dsd=nat128"), ct);
        ck(noNative.find("\"ok\":false") != std::string::npos && conf_get("dsd", "") == "256",
           "Case 4f: macOS rejects Native instead of pretending support", noNative);
        const auto junk = handle(make_req("POST", "/api/settings", "dsd=dop256junk"), ct);
        ck(junk.find("\"ok\":false") != std::string::npos && conf_get("dsd", "") == "256",
           "Case 4g: malformed DSD values do not replace valid settings", junk);
        handle(make_req("POST", "/api/settings", "dsd=0&dsdnative=0"), ct);
    }

    // ---- 5. pro vs listen 后端配置 & PEQ 完全隔离 ----
    {
        std::string ct;
        // 当前在 pro：配置一组独立 DSP 参数与 PEQ preamp=+3.5
        const std::string spPro = handle(make_req("POST", "/api/settings",
            "uimode=pro&filter=poly-sinc-long-lp&rate=192000&loudness=1&dsd=0"), ct);
        ck(spPro.find("\"ok\":true") != std::string::npos, "Case 5a: pro 模式设置落盘");
        const std::string pqPro = handle(make_req("POST", "/api/peq", "bypass=0&preamp=3.5"), ct);
        ck(pqPro.find("\"ok\":true") != std::string::npos, "Case 5b: pro 模式设置 PEQ");

        // 切到 listen：listen 不得被 pro 的 filter/rate/loudness 或 PEQ 污染，也不得暴露 mode.* 内部键
        const std::string swListen = handle(make_req("POST", "/api/settings", "uimode=listen"), ct);
        ck(swListen.find("\"ok\":true") != std::string::npos &&
           swListen.find("\"mode.") == std::string::npos,
           "Case 5c: 切回 listen 成功且响应隐藏内部 mode.* 键", swListen);
        const std::string gListen = handle(make_req("GET", "/api/settings"), ct);
        ck(gListen.find("\"uimode\":\"listen\"") != std::string::npos &&
           gListen.find("\"backend\":\"null\"") != std::string::npos &&
           gListen.find("poly-sinc-long-lp") == std::string::npos &&
           gListen.find("\"192000\"") == std::string::npos &&
           gListen.find("\"mode.") == std::string::npos,
           "Case 5d: listen 未被 pro DSP 参数污染，且全局 backend 保留", gListen);
        ck(g_peq && g_peq->settings().bypass && std::abs(g_peq->settings().preampDb) < 0.01,
           "Case 5e: 切到 listen 后 PEQ 切为 listen 独立状态");

        // 在 listen 设置另一组参数与 PEQ preamp=-2.0
        handle(make_req("POST", "/api/settings", "filter=sinc-M&rate=96000&loudness=0"), ct);
        handle(make_req("POST", "/api/peq", "bypass=0&preamp=-2.0"), ct);
        ck(params_snapshot().filter == "sinc-M" && params_snapshot().rate == "96000",
           "Case 5f: listen 模式新参数即时刷新到 g_params");

        // 切回 pro：完整恢复 pro 的参数与 PEQ
        handle(make_req("POST", "/api/settings", "uimode=pro"), ct);
        const std::string gProBack = handle(make_req("GET", "/api/settings"), ct);
        ck(gProBack.find("poly-sinc-long-lp") != std::string::npos &&
           gProBack.find("\"192000\"") != std::string::npos &&
           gProBack.find("\"loudness\":\"1\"") != std::string::npos,
           "Case 5g: 切回 pro 后完整恢复 pro 独立配置", gProBack);
        ck(g_peq && !g_peq->settings().bypass && std::abs(g_peq->settings().preampDb - 3.5) < 0.05,
           "Case 5h: 切回 pro 后恢复 pro 独立 PEQ");
        ck(params_snapshot().filter == "poly-sinc-long-lp" && params_snapshot().rate == "192000",
           "Case 5i: 切回 pro 后 g_params 同步恢复 pro 设置");
    }

    // ---- 6. 队列下一曲 DSP 快照刷新 + 预解码缓存失效 ----
    {
        std::string ct;
        const unsigned long long gen0 = g_settingsGen.load(std::memory_order_acquire);
        {
            std::lock_guard<std::mutex> lk(g_pre.mtx);
            g_pre.path = "/tmp/fake-next-track.flac";
            g_pre.gen = gen0;
            g_pre.buf.raw.assign(16, 1024);
        }
        handle(make_req("POST", "/api/settings", "filter=sinc-L&dsd=0&loudness=0"), ct);
        const unsigned long long gen1 = g_settingsGen.load(std::memory_order_acquire);
        ck(gen1 > gen0, "Case 6a: 修改设置后递增 g_settingsGen 并作废预解码缓存");
        const auto staleTaken = prefetch_take("/tmp/fake-next-track.flac");
        ck(staleTaken.raw.empty(), "Case 6b: 过期代次的预解码缓存不可再被下一曲复用");

        PlayParams pit;
        pit.backend = "null";
        pit.volume = -120.0;
        pit.filter = "stale-filter";
        pit.dsd = 256;
        pit.loudness = true;
        apply_dsp_settings_snapshot(pit, params_snapshot());
        ck(pit.filter == "sinc-L" && pit.dsd == 0 && !pit.loudness &&
           pit.backend == "null" && pit.volume == -120.0,
           "Case 6c: 下一曲快照同步最新 DSP 模式同时保留设备/音量会话");
    }

    // ---- 7. 设备切换自动识别 PCM / DSD bit 率，含降级、恢复与未点击预设按钮时的自动推断 ----
    {
        rlapp::set_coreaudio_caps_probe_override_for_test(
            true, "pa-dsd256", "PA DAC 256",
            {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000});
        rlapp::set_coreaudio_caps_probe_override_for_test(
            true, "pa-dsd128", "PA DAC 128",
            {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000});
        rlapp::set_coreaudio_caps_probe_override_for_test(
            true, "pa-pcm96", "PA PCM 96",
            {44100, 48000, 88200, 96000});
        rlapp::set_coreaudio_caps_probe_override_for_test(
            true, "pa-airplay", "PA AirPlay",
            {44100}, true, true);

        std::string ct;
        handle(make_req("POST", "/api/settings", "backend=coreaudio&device=pa-dsd256&upnpdev=&volume=-120"), ct);
        const std::string ap = handle(make_req("POST", "/api/preset/apply?profile=dsd"), ct);
        const std::string st = handle(make_req("POST", "/api/settings", "filter=poly-sinc-gauss-long"), ct);
        ck(ap.find("\"profile\":\"dsd\"") != std::string::npos && conf_get("ui_profile", "") == "dsd" &&
           st.find("\"ui_profile\":\"dsd\"") != std::string::npos,
           "Case 7a: preset apply 设置 ui_profile 且调整听音风格时保留 ui_profile", st);

        const std::string sw128 = handle(make_req("POST", "/api/settings", "device=pa-dsd128"), ct);
        const std::string sw96  = handle(make_req("POST", "/api/settings", "device=pa-pcm96"), ct);
        const std::string swAir = handle(make_req("POST", "/api/settings", "device=pa-airplay"), ct);
        const std::string sw256 = handle(make_req("POST", "/api/settings", "device=pa-dsd256"), ct);
        ck(sw128.find("\"dsd\":\"128\"") != std::string::npos &&
           sw96.find("\"dsd\":\"0\"") != std::string::npos &&
           sw96.find("\"rate\":\"96000\"") != std::string::npos &&
           swAir.find("\"dsd\":\"0\"") != std::string::npos &&
           swAir.find("\"rate\":\"src\"") != std::string::npos &&
           sw256.find("\"dsd\":\"256\"") != std::string::npos,
           "Case 7b: 设备切换自动降档 DSD128 -> PCM96k -> AirPlay src -> 切回自动恢复 DSD256", sw256);

        // 手动改 rate 清除 ui_profile，但后续切设备仍可基于最后一次升频状态自动推断与恢复
        const std::string manEdit = handle(make_req("POST", "/api/settings", "rate=48000&dsd=0"), ct);
        const std::string manTo128 = handle(make_req("POST", "/api/settings", "device=pa-dsd128"), ct);
        const std::string manToAir = handle(make_req("POST", "/api/settings", "device=pa-airplay"), ct);
        const std::string manBack96 = handle(make_req("POST", "/api/settings", "device=pa-pcm96"), ct);
        ck(manEdit.find("\"ui_profile\":\"\"") != std::string::npos &&
           manTo128.find("\"rate\":\"384000\"") != std::string::npos &&
           manToAir.find("\"rate\":\"src\"") != std::string::npos &&
           manBack96.find("\"rate\":\"96000\"") != std::string::npos,
           "Case 7c: 手动修改采样率清除 ui_profile 后，切设备/AirPlay 仍自动跟踪与恢复 PCM 升频上限", manBack96);

        rlapp::set_coreaudio_caps_probe_override_for_test(false, "", "", {});
        handle(make_req("POST", "/api/settings", "backend=null&device=&upnpdev=&dsd=0&rate=src"), ct);
    }

    fs::remove_all(tmpDir, ec);
    if (g_fails == 0) std::printf("\n[ALL PASS] test_preset_apply_contract 全部通过\n");
    else               std::printf("\n[FAILED] %d 项未通过\n", g_fails);
    return g_fails == 0 ? 0 : 1;
}
