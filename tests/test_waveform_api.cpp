// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_waveform_api.cpp — U2 包2：GET /api/waveform 的「波形→缓存→身份失效」黑盒判据
//
// ============================ 这个测试在证明什么 ============================
// 端点必须真的**解码出波形**，而不是回一串看着像的数组：
//   ① 30 s / 48 kHz WAV（10.0 s 处唯一满幅脉冲、其余 −60 dBFS）→ bins=300 时
//      peaks 长度 300、最大峰值 bin ∈ [99,101]、peak≈1.0；其余 bin ≈0.001；
//      rate=48000 / channels=2 / duration=30 如实回给调用方；
//   ② 同一请求第二次 → cached:true（进程内 LRU 真的命中，不是每次都重算）；
//   ③ 改文件 mtime 后 → cached:false（缓存键含 FileIdentity，旧条目不能冒充新文件）；
//   ④ bins=1 → 钳到 16（返回的 bins 与 peaks 长度都用钳位后的值）；
//   ⑤ 不存在的路径 → 400 + 稳定 code:waveform.path_missing；
//   ⑥ CUE 区间 cs/ce：只算区间（9.5..10.5 → duration=1.0 s，脉冲落在 bin 8/16）。
//
// 铁律 4：只断言 ok:true 会漏掉「回了数组但没算对」的假实现 ⟹ 每条都核对数字本身。
// 负向对照：改之前 /api/waveform 根本不存在（handle 落到默认分支），本测试在改之前必然红。
//
// 环境纪律（铁律 1/2）：backend=null + volume=-120（绝不打开音频设备）、不监听端口
// （只调 rlapp::dispatch，进程内），全部落临时目录，不碰 8899。
#include "rlapp_core.h"
#include "net/webui.h"
#include "net/json.h"
#include "audio/wav.h"
#include "analysis/waveform_limits.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <sys/time.h>
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

// float 的位型：AudioBuffer 的 float 样本按位存 int32（与 read_wav/write_wav 同一口径）
static int32_t fbits(float f) {
    int32_t v = 0;
    std::memcpy(&v, &f, sizeof(v));
    return v;
}

static const int kRate = 48000;
static const int kCh = 2;
static const int kSec = 30;
static const double kBed = 0.001;   // −60 dBFS

// 夹具：30 s / 48 kHz / 立体声 float32 WAV；10.0 s 处唯一满幅脉冲，其余 −60 dBFS。
// 用仓库既有的 rta::audio::write_wav（不自己重写 WAV 头，避免测试与实现同时错）。
static bool make_fixture(const fs::path& p) {
    const std::size_t frames = (std::size_t)kSec * (std::size_t)kRate;
    rta::audio::AudioBuffer ab;
    ab.rate = (uint32_t)kRate;
    ab.channels = kCh;
    ab.bits = 32;
    ab.isFloat = true;
    ab.raw.resize(frames * (std::size_t)kCh);
    const float bed = (float)kBed;
    for (std::size_t f = 0; f < frames; ++f) {
        for (int c = 0; c < kCh; ++c) {
            const float v = (c % 2 == 0) ? bed : -bed;
            ab.raw[f * (std::size_t)kCh + (std::size_t)c] = fbits(v);
        }
    }
    const std::size_t pulse = (std::size_t)10 * (std::size_t)kRate;
    for (int c = 0; c < kCh; ++c) {
        const float v = (c % 2 == 0) ? 1.0f : -1.0f;
        ab.raw[pulse * (std::size_t)kCh + (std::size_t)c] = fbits(v);
    }
    try {
        rta::audio::write_wav(p.string(), ab);
    } catch (const std::exception& e) {
        std::printf("  !! write_wav 失败：%s\n", e.what());
        return false;
    }
    return true;
}

static std::size_t argmax(const rta::net::Json& arr) {
    std::size_t best = 0;
    double v = -1.0;
    for (std::size_t i = 0; i < arr.size(); ++i) {
        if (arr.at(i).n() > v) { v = arr.at(i).n(); best = i; }
    }
    return best;
}

int main() {
    std::printf("== /api/waveform 黑盒判据（波形 / 缓存 / 身份失效 / bins 钳位 / 路径错误）==\n");

    const fs::path tmp = fs::temp_directory_path() /
                         ("rlplayer_waveform_api_" + std::to_string(::getpid()));
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

    {
        std::ofstream f(tmp / "state" / "rlplayer-settings.conf", std::ios::binary | std::ios::trunc);
        f << "backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n";
    }

    ck(rlapp::start_embedded(), "start_embedded() 返回 true");

    // ---- 夹具：中文目录 + 中文文件名（证明 UTF-8 路径走的是现有口径）----
    const fs::path fixtureDir = tmp / "波形夹具";
    fs::create_directories(fixtureDir, ec);
    const fs::path fixture = fixtureDir / "30秒脉冲.wav";
    ck(make_fixture(fixture), "夹具落盘（30 s / 48 kHz / float32 WAV）");

    const std::string base = "/api/waveform?file=" + pct(fixture.string());

    // ---- 首算：波形本体 ----
    std::printf("\n[首算] GET /api/waveform?file=<中文绝对路径>&bins=300\n");
    {
        const std::string got = call("GET", base + "&bins=300");
        ck(status() == 200, "首次请求 → 200", "status=" + std::to_string(status()));
        const rta::net::Json j = rta::net::json_parse(got);
        ck(j["ok"].b, "首次 ok:true", got.substr(0, 220));
        ck(!j["cached"].b, "首次 cached:false", got.substr(0, 220));
        ck(j["file"].s() == fixture.string(), "file 回显请求路径（含中文）",
           "期望=" + fixture.string() + " 实际=" + j["file"].s());
        ck((int)j["rate"].n() == kRate, "rate=48000", got.substr(0, 220));
        ck((int)j["channels"].n() == kCh, "channels=2", got.substr(0, 220));
        ck(std::fabs(j["duration"].n() - 30.0) < 1e-9, "duration=30.0");
        ck((int)j["bins"].n() == 300, "bins=300");

        const rta::net::Json& peaks = j["peaks"];
        ck(peaks.size() == 300, "peaks 长度 300", "实际=" + std::to_string(peaks.size()));
        const std::size_t top = argmax(peaks);
        ck(top >= 99 && top <= 101, "最大峰值 bin ∈ [99,101]",
           "实际 argmax=" + std::to_string(top));
        ck(std::fabs(j["peak"].n() - 1.0) < 1e-6, "peak≈1.0（10.0 s 满幅脉冲）");
        ck(top < peaks.size() && std::fabs(peaks.at(top).n() - 1.0) < 1e-6,
           "argmax bin 的峰值 = 1.0");
        ck(std::fabs(peaks.at(0).n() - kBed) < 1e-5, "其余 bin 峰值 = −60 dBFS (0.001)",
           "peaks[0]=" + std::to_string(peaks.at(0).n()));
        const rta::net::Json& rms = j["rms"];
        ck(rms.size() == 300, "rms 长度 300", "实际=" + std::to_string(rms.size()));
        ck(std::fabs(rms.at(0).n() - kBed) < 1e-5, "底噪 bin 的 rms ≈ 0.001");
    }

    // ---- 缓存命中 ----
    std::printf("\n[缓存] 同一请求第二次\n");
    {
        const std::string got = call("GET", base + "&bins=300");
        ck(status() == 200, "第二次 → 200");
        const rta::net::Json j = rta::net::json_parse(got);
        ck(j["ok"].b, "第二次 ok:true");
        ck(j["cached"].b, "第二次 cached:true（LRU 命中）", got.substr(0, 220));
        ck(argmax(j["peaks"]) >= 99 && argmax(j["peaks"]) <= 101,
           "命中结果的波形与首算一致（argmax 仍 ∈ [99,101]）");
    }

    // ---- force=1：跳过缓存重算 ----
    std::printf("\n[强制重算] force=1\n");
    {
        const std::string got = call("GET", base + "&bins=300&force=1");
        ck(status() == 200, "force=1 → 200");
        const rta::net::Json j = rta::net::json_parse(got);
        ck(j["ok"].b && !j["cached"].b, "force=1 跳过缓存（cached:false）", got.substr(0, 220));
    }

    // ---- 身份失效：只改 mtime 也必须 miss ----
    std::printf("\n[身份失效] 改文件 mtime\n");
    {
        struct stat st {};
        ck(::stat(fixture.string().c_str(), &st) == 0, "stat 取到夹具 mtime");
        struct timeval tv[2];
        tv[0].tv_sec = st.st_atime;        tv[0].tv_usec = 0;
        tv[1].tv_sec = st.st_mtime + 10;   tv[1].tv_usec = 0;
        ck(::utimes(fixture.string().c_str(), tv) == 0, "utimes 把 mtime 推后 10 s");
        const std::string got = call("GET", base + "&bins=300");
        ck(status() == 200, "mtime 变化后仍能分析 → 200");
        const rta::net::Json j = rta::net::json_parse(got);
        ck(j["ok"].b, "mtime 变化后 ok:true");
        ck(!j["cached"].b, "mtime 变化后 cached:false（键含 FileIdentity）", got.substr(0, 220));
        ck(argmax(j["peaks"]) >= 99 && argmax(j["peaks"]) <= 101,
           "重算结果的波形仍正确（argmax ∈ [99,101]）");
    }

    // ---- bins 钳位：1 → 16 ----
    std::printf("\n[bins 钳位] bins=1\n");
    {
        const std::string got = call("GET", base + "&bins=1");
        ck(status() == 200, "bins=1 → 200");
        const rta::net::Json j = rta::net::json_parse(got);
        ck(j["ok"].b, "bins=1 ok:true");
        ck((int)j["bins"].n() == 16, "bins 钳到下界 16", got.substr(0, 220));
        ck(j["peaks"].size() == 16, "peaks 长度 16（钳位后的实际 bin 数）",
           "实际=" + std::to_string(j["peaks"].size()));
        ck(j["rms"].size() == 16, "rms 长度 16");
        const std::size_t top = argmax(j["peaks"]);
        ck(top >= 5 && top <= 6, "16 bin 时脉冲落在 bin 5/6", "实际=" + std::to_string(top));
    }

    // ---- 严格解析：整串必须是数字，垃圾值不再被静默接受 ----
    std::printf("\n[bins 严格解析] bins=300abc\n");
    {
        const std::string got = call("GET", base + "&bins=300abc");
        ck(status() == 200, "bins=300abc → 200（垃圾值不报错）");
        const rta::net::Json j = rta::net::json_parse(got);
        ck(j["ok"].b, "bins=300abc ok:true");
        ck((int)j["bins"].n() == 512, "整串非数字 ⇒ 保持默认 512（不再静默当 300）",
           "实际=" + std::to_string((int)j["bins"].n()));
    }

    // ---- CUE 区间：cs/ce 只算该段 ----
    std::printf("\n[CUE 区间] cs=9.5&ce=10.5\n");
    {
        const std::string got = call("GET", base + "&bins=16&cs=9.5&ce=10.5");
        ck(status() == 200, "CUE 区间 → 200");
        const rta::net::Json j = rta::net::json_parse(got);
        ck(j["ok"].b, "CUE 区间 ok:true");
        ck(std::fabs(j["duration"].n() - 1.0) < 1e-9, "duration=1.0（区间长度，不是整曲 30 s）",
           "实际=" + std::to_string(j["duration"].n()));
        ck(j["peaks"].size() == 16, "区间波形 peaks 长度 16");
        const std::size_t top = argmax(j["peaks"]);
        ck(top == 8, "10.0 s 的脉冲落在区间 bin 8", "实际=" + std::to_string(top));
        ck(std::fabs(j["peaks"].at(top).n() - 1.0) < 1e-6, "区间内脉冲峰值 = 1.0");
    }

    // ---- 路径错误：稳定码 ----
    std::printf("\n[路径错误] 不存在的路径\n");
    {
        const std::string missing = (fixtureDir / "不存在.wav").string();
        const std::string got = call("GET", "/api/waveform?file=" + pct(missing));
        ck(status() == 400, "不存在的路径 → 400", "status=" + std::to_string(status()));
        const rta::net::Json j = rta::net::json_parse(got);
        ck(!j["ok"].b, "不存在路径 ok:false");
        ck(j["code"].s() == "waveform.path_missing",
           "不存在路径 → 稳定 code:waveform.path_missing", got.substr(0, 220));

        const std::string rel = call("GET", "/api/waveform?file=" + pct("relative/波形.wav"));
        ck(status() == 400, "相对路径 → 400（只接受绝对路径）", "status=" + std::to_string(status()));
        ck(rta::net::json_parse(rel)["code"].s() == "waveform.path_missing",
           "相对路径 → 稳定 code:waveform.path_missing", rel.substr(0, 200));
    }

    // ---- 解码失败：稳定码（损坏的 WAV 不能回空数组冒充成功）----
    std::printf("\n[解码失败] 损坏的 .wav\n");
    {
        const fs::path bad = fixtureDir / "坏文件.wav";
        {
            std::ofstream f(bad, std::ios::binary | std::ios::trunc);
            f << "not a wav file";
        }
        const std::string got = call("GET", "/api/waveform?file=" + pct(bad.string()));
        ck(status() == 422, "损坏的 WAV → 422", "status=" + std::to_string(status()));
        const rta::net::Json j = rta::net::json_parse(got);
        ck(!j["ok"].b, "损坏的 WAV ok:false");
        ck(j["code"].s() == "waveform.decode_failed",
           "损坏的 WAV → 稳定 code:waveform.decode_failed", got.substr(0, 220));
    }

    // ---- 缺省 file：当前没有在播曲目 → path_missing（不猜路径）----
    std::printf("\n[缺省文件] 没有在播曲目\n");
    {
        const std::string got = call("GET", "/api/waveform");
        ck(status() == 400, "没有在播曲目时缺省 file → 400", "status=" + std::to_string(status()));
        ck(rta::net::json_parse(got)["code"].s() == "waveform.path_missing",
           "没有在播曲目时 → 稳定 code:waveform.path_missing", got.substr(0, 200));
    }

    // ---- 空/反向 CUE 区间：参数错误 400，不是解码失败 422 ----
    std::printf("\n[区间错误] cs >= ce / 钳位后为空\n");
    {
        const std::string got = call("GET", base + "&bins=16&cs=2.0&ce=1.0");
        ck(status() == 400, "cs > ce → 400（不是 422）", "status=" + std::to_string(status()));
        const rta::net::Json j = rta::net::json_parse(got);
        ck(!j["ok"].b && j["code"].s() == "waveform.bad_range",
           "cs > ce → 稳定 code:waveform.bad_range", got.substr(0, 200));
        const std::string eq = call("GET", base + "&bins=16&cs=1.0&ce=1.0");
        ck(status() == 400 && rta::net::json_parse(eq)["code"].s() == "waveform.bad_range",
           "cs == ce 同样 400 waveform.bad_range", eq.substr(0, 200));
        // 钳位后为空：cs 超出整曲时长（30 s）⟹ start == end，也必须是 400 而不是 422。
        const std::string over = call("GET", base + "&bins=16&cs=31");
        ck(status() == 400 && rta::net::json_parse(over)["code"].s() == "waveform.bad_range",
           "cs 超过时长（钳位后 start==end）→ 400 waveform.bad_range", over.substr(0, 200));
    }

    // ---- 纯逻辑：探测失败时的「按 codec 估算」上限（可离线直接调）----
    std::printf("\n[上限估算] waveform_limits 纯逻辑\n");
    {
        namespace wl = rta::analysis::waveform_limits;
        const std::uint64_t mib32 = 32ull * 1024ull * 1024ull;
        ck(wl::expansion_factor(".flac") == 4u && wl::expansion_factor(".mp3") == 12u,
           "按 codec 分档（无损 4× / 有损 12× / 未知 6×）",
           "flac=" + std::to_string(wl::expansion_factor(".flac")) +
           " mp3=" + std::to_string(wl::expansion_factor(".mp3")) +
           " xyz=" + std::to_string(wl::expansion_factor(".xyz")));
        ck(wl::unbounded_est_pcm_bytes(mib32, ".flac") == 128ull * 1024ull * 1024ull,
           "32 MiB 无损文件 → 128 MiB PCM 估算");
        ck(wl::unbounded_est_pcm_bytes(mib32, ".mp3") == 384ull * 1024ull * 1024ull,
           "32 MiB 有损文件 → 384 MiB PCM 估算");
        ck(!wl::whole_decode_too_large(false, mib32, wl::unbounded_est_pcm_bytes(mib32, ".flac")),
           "32 MiB 无损：估算未超 256 MiB ⟹ 允许尝试解码");
        ck(wl::whole_decode_too_large(false, mib32, wl::unbounded_est_pcm_bytes(mib32, ".mp3")),
           "32 MiB 有损：估算 384 MiB > 256 MiB ⟹ 解码前直接 413");
        ck(wl::whole_decode_too_large(false, mib32 + 1, 0),
           "超过兜底文件上限（32 MiB+1）⟹ 413");
        ck(!wl::whole_decode_too_large(true, mib32, 64ull * 1024ull * 1024ull),
           "有界路径：64 MiB 精确估计未超限 ⟹ 不拒（对照）");
    }

    // ---- 413 与 422 不混：探测失败的 .flac，大文件 413 / 小文件 422 ----
    std::printf("\n[内存上界] 探测失败的大 .flac vs 小 .flac\n");
    {
        const fs::path big = fixtureDir / "伪造大文件.flac";
        {
            std::ofstream f(big, std::ios::binary | std::ios::trunc);
            const std::string block(4096, '\0');
            for (int i = 0; i < 10240; ++i) f.write(block.data(), (std::streamsize)block.size());
        }
        const std::string got = call("GET", "/api/waveform?file=" + pct(big.string()));
        ck(status() == 413, "探测失败 + 40 MiB → 413（不是 422）",
           "status=" + std::to_string(status()));
        ck(rta::net::json_parse(got)["code"].s() == "waveform.too_large",
           "→ 稳定 code:waveform.too_large", got.substr(0, 200));

        const fs::path small = fixtureDir / "伪造小文件.flac";
        {
            std::ofstream f(small, std::ios::binary | std::ios::trunc);
            const std::string block(4096, '\0');
            for (int i = 0; i < 256; ++i) f.write(block.data(), (std::streamsize)block.size());
        }
        const std::string got2 = call("GET", "/api/waveform?file=" + pct(small.string()));
        ck(status() == 422, "探测失败 + 1 MiB（没超上限）→ 422 解码失败",
           "status=" + std::to_string(status()));
        ck(rta::net::json_parse(got2)["code"].s() == "waveform.decode_failed",
           "→ 稳定 code:waveform.decode_failed（与 413 分开）", got2.substr(0, 200));
        fs::remove(big, ec);
        fs::remove(small, ec);
    }

    rlapp::stop_embedded();

    std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
    if (g_fail) { std::printf("!! 有失败项\n"); return 1; }
    std::printf("/api/waveform 黑盒判据全部通过\n");
    return 0;
}
