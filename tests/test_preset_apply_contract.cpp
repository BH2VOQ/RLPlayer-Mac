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

    fs::remove_all(tmpDir, ec);
    if (g_fails == 0) std::printf("\n[ALL PASS] test_preset_apply_contract 全部通过\n");
    else               std::printf("\n[FAILED] %d 项未通过\n", g_fails);
    return g_fails == 0 ? 0 : 1;
}
