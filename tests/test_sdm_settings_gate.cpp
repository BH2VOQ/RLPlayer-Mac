// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_sdm_settings_gate.cpp — U12 第二步：1-bit SDM 拐点准入的**接线**黑盒判据
//
// ============================ 这个测试在证明什么 ============================
// 第一步（0fdd82b）只落了策略头 src/dsp/sdm_output_policy.h + 纯策略单测
// （test_sdm_policy）。那一步证明"判定函数本身对不对"，**没有**证明它被接到真实入口上。
// 本测试只走真实入口，不看实现：
//
//   ① POST /api/settings —— 保存前置闸门（白名单合并后、写盘前）
//        非法组合：HTTP 422 + ok:false + code=sdm.corner_quality + 人话 error，
//        且 conf 原文**没有**本次提交的键（只断言 422 不够：旧实现先写盘再报错也能回 422）。
//   ② GET  /api/settings —— additive 的 sdm 快照（policy=sdm-corner-v1）
//        corner_hz / one_bit / family / admitted / code / note 全部来自后端；
//        原生设置页的提示文案只认它（前端不写死 100000 ⟹ 这里钉住口径）。
//   ③ POST /api/play     —— 开流前闸门（同一判定，进 std::thread 之前）
//        ps.error 里带稳定子串 SDM_CORNER_QUALITY；不放行 = 不会有一声 DoP 位流。
//
// 判据的"红"必须真的红：改前（未接线）POST 会回 ok:true 并把 modcut=20 写进 conf、
// GET 根本没有 sdm 对象、/api/play 不会有 SDM_CORNER_QUALITY。
//
// 负向对照（证明不是"全拒"）：
//   · EC 族 + 20 kHz  → 准入（真 EC 豁免 corner 质量下限）；
//   · DSD 族 + 100 kHz → 准入（边界值，判据是 < 100 kHz 而不是只认 20/50k）；
//   · AHM 族 + 20 kHz → 跳过（多电平 levels != 2，不经过 1-bit 准入）；
//   · dsd=0（PCM 输出）+ 20 kHz → 保存与开流都跳过（PCM 不经过 SdmModulator）。
//
// ============================ 环境纪律（铁律 1/2）============================
//   * backend=null + volume=-120：绝不打开物理音频设备，绝不发声；
//   * 不监听端口：全程只调 rlapp::dispatch（进程内），没有 listener；绝不碰 8899；
//   * 配置/曲库/封面全部落临时目录（runtime 的播放日志除外，它在可执行目录）。
#include "rlapp_core.h"
#include "net/webui.h"
#include "net/json.h"                // 用仓库自己的解析器验证 GET 仍是合法 JSON（additive 拼接最容易写坏）
#include "dsp/sdm_output_policy.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <unistd.h>

namespace fs = std::filesystem;

static int g_pass = 0;
static int g_fail = 0;

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

struct ApiResult {
    int status = 200;
    std::string body;
};

// 进程内 dispatch：与真实 HTTP 路径同一份 handle()，只是不起 listener。
// 状态码从 webui_status_slot() 读（handle_traced 只复位不覆盖 handler 设置的值）。
static ApiResult call(const std::string& method, const std::string& path,
                      const std::string& body = std::string()) {
    rta::net::HttpRequest rq;
    rq.method = method;
    rq.path = path;
    rq.body = body;
    std::string ct;
    ApiResult r;
    r.body = rlapp::dispatch(rq, ct);
    r.status = rta::net::webui_status_slot()->load();
    return r;
}

// ---- 极简 JSON 取值（不引第三方库；够用即可）----
// 找 "key": 之后的第一个值：字符串（含转义）/ 数字 / true|false。
static std::string json_get(const std::string& json, const std::string& key, size_t from = 0) {
    const std::string needle = "\"" + key + "\":";
    size_t p = json.find(needle, from);
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

// 只看顶层的 sdm 子对象（GET /api/settings 的 additive 快照）。
static std::string sdm_get(const std::string& json, const std::string& key) {
    const size_t at = json.find("\"sdm\":{");
    if (at == std::string::npos) return std::string();
    return json_get(json, key, at);
}

static std::string read_file(const fs::path& p) {
    std::ifstream f(p.string(), std::ios::binary);
    std::ostringstream os;
    os << f.rdbuf();
    return os.str();
}

static void write_file(const fs::path& p, const std::string& text) {
    std::ofstream f(p.string(), std::ios::binary | std::ios::trunc);
    f << text;
}

// conf 里是否有 "key=value"（值按前缀比，避免 -12.0 vs -12 这类格式差）
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

// 极简百分号编码（只用于把测试音源的临时路径塞进表单，不追求完整）
static std::string urlenc(const std::string& s) {
    std::string out;
    for (char ch : s) {
        const unsigned char c = (unsigned char)ch;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == '/' || c == '~') {
            out += ch;
        } else {
            char buf[8];
            std::snprintf(buf, sizeof(buf), "%%%02X", c);
            out += buf;
        }
    }
    return out;
}

// 0.3 s / 44.1 kHz / 16-bit / 2ch 正弦：只为让解码成功走到开流闸门，不参与听感判据。
static void write_test_wav(const fs::path& p) {
    const uint32_t rate = 44100, ch = 2, frames = 13230, bits = 16;
    const uint32_t dataBytes = frames * ch * (bits / 8);
    std::ofstream f(p.string(), std::ios::binary | std::ios::trunc);
    auto u32 = [&](uint32_t v) { f.write(reinterpret_cast<const char*>(&v), 4); };
    auto u16 = [&](uint16_t v) { f.write(reinterpret_cast<const char*>(&v), 2); };
    f.write("RIFF", 4); u32(36 + dataBytes); f.write("WAVE", 4);
    f.write("fmt ", 4); u32(16); u16(1); u16((uint16_t)ch); u32(rate);
    u32(rate * ch * (bits / 8)); u16((uint16_t)(ch * (bits / 8))); u16((uint16_t)bits);
    f.write("data", 4); u32(dataBytes);
    for (uint32_t i = 0; i < frames; ++i) {
        const double s = std::sin(2.0 * 3.141592653589793 * 440.0 * (double)i / (double)rate) * 0.3;
        const int16_t v = (int16_t)std::lround(s * 32767.0);
        u16((uint16_t)v); u16((uint16_t)v);
    }
}

// 轮询 /api/status，直到某个字段包含 wantSub（超时后返回最后一次结果）。
static std::string wait_status(const std::string& key, const std::string& wantSub, int timeoutMs) {
    const auto t0 = std::chrono::steady_clock::now();
    std::string st;
    for (;;) {
        st = call("GET", "/api/status").body;
        if (json_get(st, key).find(wantSub) != std::string::npos) return st;
        if (std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0).count() >= timeoutMs) return st;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

int main() {
    std::printf("== U12 1-bit SDM 拐点准入（保存 / 开流 / GET 快照）黑盒判据 ==\n");

    const fs::path tmp = fs::temp_directory_path() /
                         ("rlplayer_sdm_gate_" + std::to_string(::getpid()));
    std::error_code ec;
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp, ec);
    if (ec) { std::printf("!! 无法创建临时目录\n"); return 2; }

    for (const char* leaf : {"home", "state", "covers", "lib"})
        fs::create_directories(tmp / leaf, ec);
    ::setenv("HOME", (tmp / "home").string().c_str(), 1);
    ::setenv("CFFIXED_USER_HOME", (tmp / "home").string().c_str(), 1);
    ::setenv("RLPLAYER_STATE_DIR", (tmp / "state").string().c_str(), 1);
    ::setenv("RLPLAYER_LIBRARY_DIR", (tmp / "lib").string().c_str(), 1);
    ::setenv("RLPLAYER_COVER_DIR", (tmp / "covers").string().c_str(), 1);

    const fs::path confPath = tmp / "state" / "rlplayer-settings.conf";
    const std::string confBase =
        "backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n";
    // 起点：DSD 输出 + DSD 族 + 合法拐点 100 kHz。后面每一段按需要改写。
    write_file(confPath, confBase + "dsd=64\nmodfamily=dsd\nmodcut=100\n");

    const fs::path wavPath = tmp / "u12_probe.wav";
    write_test_wav(wavPath);

    ck(rlapp::start_embedded(), "start_embedded() 返回 true");

    auto post_settings = [](const std::string& body) {
        return call("POST", "/api/settings", body);
    };
    auto ok_true = [](const ApiResult& r) {
        return r.body.find("\"ok\":true") != std::string::npos;
    };
    auto detail_of = [](const ApiResult& r) {
        return "status=" + std::to_string(r.status) + " body=" + r.body.substr(0, 220);
    };

    // ================= [A] 负向对照：合法组合必须能存 =================
    std::printf("\n[A] 负向对照：合法组合必须能存（证明实现不是「全拒」）\n");
    {
        const ApiResult r = post_settings("dsd=64&modfamily=ec&modcut=20");
        ck(r.status == 200 && ok_true(r),
           "EC 族 + 20 kHz：保存放行（真 EC 豁免 corner 质量下限）", detail_of(r));
        const std::string conf = read_file(confPath);
        ck(conf_has(conf, "modcut", "20") && conf_has(conf, "modfamily", "ec"),
           "EC 族 + 20 kHz 真的落盘（不是只在响应里说 ok）", conf.substr(0, 200));

        const ApiResult r2 = post_settings("dsd=64&modfamily=dsd&modcut=100");
        ck(r2.status == 200 && ok_true(r2),
           "DSD 族 + 100 kHz：保存放行（边界值；判据是 < 100 kHz）", detail_of(r2));
        const std::string conf2 = read_file(confPath);
        ck(conf_has(conf2, "modcut", "100") && conf_has(conf2, "modfamily", "dsd"),
           "DSD 族 + 100 kHz 真的落盘", conf2.substr(0, 200));

        const ApiResult r3 = post_settings("dsd=64&modfamily=ahm&modcut=20");
        ck(r3.status == 200 && ok_true(r3),
           "AHM 族 + 20 kHz：保存放行（多电平 levels != 2，不经过 1-bit 准入）", detail_of(r3));

        const ApiResult r4 = post_settings("dsd=0&modfamily=dsd&modcut=20");
        ck(r4.status == 200 && ok_true(r4),
           "dsd=0（PCM 输出）+ 20 kHz：保存放行（不出 DSD 就不判 1-bit corner）", detail_of(r4));

        // 复位到 [B] 需要的"合法 + 旧拐点 100 kHz"状态（并且 dsd 回到 64）。
        const ApiResult r5 = post_settings("dsd=64&modfamily=dsd&modcut=100");
        ck(r5.status == 200 && ok_true(r5), "复位到 dsd=64 / dsd 族 / 100 kHz", detail_of(r5));
    }

    // ================= [B] 被测：保存闸门 =================
    std::printf("\n[B] 被测：dsd>0 + 非真 EC + corner < 100 kHz ⟹ 422 且不写盘\n");
    {
        // 故意带上 dsd=128：既能证明闸门按"未来状态"判（不是按旧 conf），
        // 又能证明整份写盘是**原子拒绝**（dsd 不会被写成 128）。
        const ApiResult r = post_settings("dsd=128&modfamily=dsd&modcut=20");
        ck(r.status == 422, "POST /api/settings 返回 HTTP 422", detail_of(r));
        ck(r.body.find("\"ok\":false") != std::string::npos, "响应 ok:false", r.body.substr(0, 220));
        ck(json_get(r.body, "code") == rta::dsp::kSdmCornerQualityCode,
           std::string("code 是稳定字面量 ") + rta::dsp::kSdmCornerQualityCode,
           "code=" + json_get(r.body, "code"));
        const std::string err = json_get(r.body, "error");
        ck(err.find(rta::dsp::kSdmCornerQualityTag) != std::string::npos,
           "error 带稳定子串 SDM_CORNER_QUALITY（UI/日志按它匹配）", err);
        ck(err.find("100 kHz") != std::string::npos && err.find("EC") != std::string::npos,
           "error 给出人话出路（改 100 kHz 或切 EC 族）", err);

        const std::string conf = read_file(confPath);
        ck(!conf_has(conf, "modcut", "20"),
           "conf 里没有 modcut=20（写盘前就拒绝，不是写进去再报错）", conf.substr(0, 220));
        ck(conf_has(conf, "modcut", "100"), "conf 的旧拐点仍是 100（没有被本次提交覆盖）",
           conf.substr(0, 220));
        ck(conf_has(conf, "dsd", "64"),
           "conf 的 dsd 仍是 64（整份写盘原子拒绝，没写成 128）", conf.substr(0, 220));
    }
    {
        const ApiResult r = post_settings("dsd=128&modfamily=chebyshev&modcut=20");
        ck(r.status == 422, "Chebyshev + 20 kHz 也拒绝（ecCorrection 不能把 Chebyshev 变回 EC）",
           detail_of(r));
    }
    {
        const ApiResult r = post_settings("dsd=128&modfamily=dsd&modcut=-5");
        ck(r.status == 422, "负拐点拒绝（值本身不成立）", detail_of(r));
        ck(json_get(r.body, "code") == rta::dsp::kSdmCornerInvalidCode,
           std::string("负拐点的 code 是 ") + rta::dsp::kSdmCornerInvalidCode +
           "（与质量下限分开）", "code=" + json_get(r.body, "code"));
        const std::string conf = read_file(confPath);
        ck(!conf_has(conf, "modcut", "-5"),
           "负拐点没被静默改写成 100 kHz 后放行（conf 不变）", conf.substr(0, 220));
    }

    // ================= [C] GET sdm 快照（additive 契约） =================
    std::printf("\n[C] GET /api/settings 的 additive sdm 快照（原生提示文案由它驱动）\n");
    {
        write_file(confPath, confBase + "dsd=64\nmodfamily=dsd\nmodcut=20\n");
        const ApiResult g = call("GET", "/api/settings");
        ck(g.body.find("\"sdm\":{") != std::string::npos,
           "GET 顶层有 sdm 子对象（additive，不动 kv）", g.body.substr(0, 320));
        // 手写字符串拼接最容易把整份 JSON 写坏（多/少一个括号在字段级断言里看不出来）。
        // 用仓库自己的解析器过一遍：kv 仍在 + sdm 的数值/布尔真的按类型解析出来。
        const rta::net::Json parsed = rta::net::json_parse(g.body);
        ck(parsed.has("kv") && parsed.has("sdm") && parsed["ok"].b,
           "GET 是合法 JSON 且 kv 仍在（additive：只增不改）", g.body.substr(0, 200));
        ck(parsed["sdm"]["corner_hz"].n() == 20000.0,
           "解析后 sdm.corner_hz 是数字 20000", std::to_string(parsed["sdm"]["corner_hz"].n()));
        ck(parsed["sdm"]["admitted"].ok() && !parsed["sdm"]["admitted"].b,
           "解析后 sdm.admitted 是布尔 false", std::to_string(parsed["sdm"]["admitted"].b));
        ck(sdm_get(g.body, "policy") == "sdm-corner-v1", "policy=sdm-corner-v1",
           "policy=" + sdm_get(g.body, "policy"));
        ck(sdm_get(g.body, "corner_hz") == "20000", "corner_hz=20000（modcut=20 kHz 换算）",
           "corner_hz=" + sdm_get(g.body, "corner_hz"));
        ck(sdm_get(g.body, "family") == "dsd", "family=dsd", "family=" + sdm_get(g.body, "family"));
        ck(sdm_get(g.body, "one_bit") == "true", "one_bit=true（非 AHM = 1-bit 路径）",
           "one_bit=" + sdm_get(g.body, "one_bit"));
        ck(sdm_get(g.body, "admitted") == "false", "admitted=false（20 kHz 不合格）",
           "admitted=" + sdm_get(g.body, "admitted"));
        ck(sdm_get(g.body, "code") == rta::dsp::kSdmCornerQualityCode,
           std::string("code=") + rta::dsp::kSdmCornerQualityCode, sdm_get(g.body, "code"));
        const std::string note = sdm_get(g.body, "note");
        ck(note.find(rta::dsp::kSdmCornerQualityTag) != std::string::npos &&
           note.find("100 kHz") != std::string::npos &&
           note.find("EC") != std::string::npos,
           "note 是人话全文（稳定子串 + 100 kHz + EC 出路；前端原样显示、不写死阈值）", note);
    }
    {
        write_file(confPath, confBase + "dsd=64\nmodfamily=dsd\nmodcut=0\n");
        const ApiResult g = call("GET", "/api/settings");
        ck(sdm_get(g.body, "corner_hz") == "100000",
           "modcut=0 时 corner_hz=100000（设置里的 0 = 默认 100 kHz）",
           "corner_hz=" + sdm_get(g.body, "corner_hz"));
        ck(sdm_get(g.body, "admitted") == "true", "modcut=0 时 admitted=true",
           "admitted=" + sdm_get(g.body, "admitted"));
        ck(sdm_get(g.body, "note").empty(), "准入时 note 为空（不残留上一轮的拒绝文案）",
           sdm_get(g.body, "note"));
    }
    {
        write_file(confPath, confBase + "dsd=64\nmodfamily=ec\nmodcut=20\n");
        const ApiResult g = call("GET", "/api/settings");
        ck(sdm_get(g.body, "admitted") == "true", "EC 族 + 20 kHz 时 admitted=true（真 EC 豁免）",
           "admitted=" + sdm_get(g.body, "admitted"));
    }
    {
        write_file(confPath, confBase + "dsd=64\nmodfamily=ahm\nmodcut=20\n");
        const ApiResult g = call("GET", "/api/settings");
        ck(sdm_get(g.body, "one_bit") == "false", "AHM 族 one_bit=false（多电平不是 1-bit）",
           "one_bit=" + sdm_get(g.body, "one_bit"));
        ck(sdm_get(g.body, "admitted") == "true", "AHM 族跳过准入 ⟹ admitted=true",
           "admitted=" + sdm_get(g.body, "admitted"));
    }
    {
        write_file(confPath, confBase + "dsd=64\nmodfamily=cheb\nmodcut=20\n");
        const ApiResult g = call("GET", "/api/settings");
        ck(sdm_get(g.body, "family") == "chebyshev", "family 规范化成 chebyshev",
           "family=" + sdm_get(g.body, "family"));
        ck(sdm_get(g.body, "admitted") == "false", "Chebyshev + 20 kHz 仍 admitted=false",
           "admitted=" + sdm_get(g.body, "admitted"));
    }

    // ================= [D] 开流前闸门（同一判定） =================
    std::printf("\n[D] POST /api/play：DoP 开流前闸门（拒绝走播放失败路径、不进生产者线程）\n");
    {
        const std::string body =
            "file=" + urlenc(wavPath.string()) +
            "&backend=null&volume=-120&buffer=100&isp=0&twostage=0"
            "&dsd=64&modfamily=dsd&modcut=20";
        const ApiResult pr = call("POST", "/api/play", body);
        ck(pr.body.find("\"ok\":") != std::string::npos,
           "POST /api/play 有明确响应（播放是异步的，失败原因在 /api/status）",
           pr.body.substr(0, 160));
        const std::string st = wait_status("error", rta::dsp::kSdmCornerQualityTag, 4000);
        const std::string err = json_get(st, "error");
        ck(err.find(rta::dsp::kSdmCornerQualityTag) != std::string::npos,
           "开流被拒：/api/status.error 带 SDM_CORNER_QUALITY（与保存闸门同一判定）", err);
        ck(err.find("100 kHz") != std::string::npos && err.find("EC") != std::string::npos,
           "开流拒绝同样给出去路（100 kHz / EC）", err);
        call("POST", "/api/stop");
        const std::string st2 = call("GET", "/api/status").body;
        ck(json_get(st2, "playing") == "false", "拒绝后 playing=false（没停在播放态）",
           "playing=" + json_get(st2, "playing"));
    }
    {
        // 对照：PCM 输出（dsd=0）根本不经过 1-bit 准入 —— 同一拐点不得报 SDM_CORNER_QUALITY。
        const std::string body =
            "file=" + urlenc(wavPath.string()) +
            "&backend=null&volume=-120&buffer=100&isp=0&twostage=0"
            "&dsd=0&modfamily=dsd&modcut=20";
        call("POST", "/api/play", body);
        std::this_thread::sleep_for(std::chrono::milliseconds(1200));   // 0.3 s 音源 + null sink：足够跑完
        const std::string st = call("GET", "/api/status").body;
        const std::string err = json_get(st, "error");
        ck(err.find(rta::dsp::kSdmCornerQualityTag) == std::string::npos,
           "PCM 输出（dsd=0）+ 20 kHz 不报 SDM_CORNER_QUALITY（闸门不误伤 PCM）", err);
        call("POST", "/api/stop");
    }
    {
        // AHM + DoP 由更早的 P0-3 多电平冲突闸门拒绝（早于本轮的 corner 准入）：
        // 断言"仍然是那条错误" ⟹ 本轮闸门没有抢报、AHM 确实被跳过。
        const std::string body =
            "file=" + urlenc(wavPath.string()) +
            "&backend=null&volume=-120&buffer=100&isp=0&twostage=0"
            "&dsd=64&modfamily=ahm&modcut=20";
        call("POST", "/api/play", body);
        const std::string st = wait_status("error", "AHM", 4000);
        const std::string err = json_get(st, "error");
        ck(err.find("AHM") != std::string::npos,
           "AHM + DoP 走的仍是 P0-3 多电平冲突闸门", err);
        ck(err.find(rta::dsp::kSdmCornerQualityTag) == std::string::npos,
           "AHM 情形下 corner 闸门没有抢报（levels != 2 跳过）", err);
        call("POST", "/api/stop");
    }

    rlapp::stop_embedded();
    fs::remove_all(tmp, ec);

    std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
    if (g_fail) { std::printf("!! 有失败项\n"); return 1; }
    std::printf("U12 第二步接线判据全部通过\n");
    return 0;
}
