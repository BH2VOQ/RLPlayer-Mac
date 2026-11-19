// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_track_health.cpp — 音频体检 B1b：编排层（track_health / health_store）+ CLI 底层验证
// 全合成 + 临时文件，确定性可复现；与 B1a 的锚点（997 Hz / −23 dBFS 立体声 ⟹ −23.0 LUFS）
// 直接对齐，证明编排层没有改变底层口径。不碰音频设备、不读真实曲库。
//
// ---------------- macOS 移植（2026-10-26，上游 68e628f v1.5.2 → 本库）----------------
// 上游 §1~§6 保留（阈值一字未改），**路径拼接与 §7/§8 是本移植的核心价值**：
//
//  a) 路径拼接：上游用 `tmpDir + "\\rtahealth_b1b_tone.wav"`（反斜杠 + Win32 分隔符）。
//     mac 上 `\` 是**合法文件名字符**而不是分隔符 ⟹ 照抄会在 /tmp 下造出一个名字里带
//     反斜杠的文件（不报错、看起来"通过"，但行为与 Windows 完全不同）。
//     本库统一走 `rta::platform::temp_dir_utf8()`（**带尾分隔符**，语义与 GetTempPathW 一致）
//     + `rta::platform::join()`（平台分隔符）。
//
//  b) 上游 `check(b.lookup(tmpDir + "\\.\\rtahealth_b1b_tone.wav", ...))` 用 `\.\` 段测
//     weakly_canonical 归一。mac 的等价写法是 `/./`（正斜杠）。
//
//  c) **新增 §7**：中文路径往返。这是上游 `health_store.h` 用宽字符 fopen 的**唯一理由**，
//     也是 mac 上最容易踩死的地方 —— 上游注释说「widen() UTF-8→UTF-16，中文缓存路径必需」，
//     但 mac 的 widen 是字节保序恒等，拿它构造 fs::path 对非 ASCII 会直接
//     `throw std::runtime_error("locale not supported")`（本机 clang 21/libc++ 实测）。
//     §7 用**真的中文目录**跑完整 save→load→lookup，证明 u8path 路线在 mac 上是对的。
//
//  d) **新增 §8**：mtime 精度负向对照。上游注释担心 MSVC file_clock 100ns count 超 2^53。
//     mac 的 file_clock 是**纳秒**（实测 1.79e18，比 MSVC 还大 10 倍），同样超 2^53。
//     本库取毫秒规避；§8 把「纳秒会丢精度 / 毫秒不丢」两侧都实测钉住。
#include "analysis/track_health.h"
#include "analysis/container_duration.h"   // U10：容器声明时长探针（§13/§14）
#include "analysis/health_store.h"
#include "platform/path.h"
#include <cstdio>
#include <cmath>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <chrono>
#include <cstring>     // std::memcmp（逐位比对）
#include <algorithm>   // std::max（max|Δ| 汇总）
#include <atomic>      // std::atomic<bool>（分析取消）

using namespace rta::analysis;
using rta::dsp::kPi;
namespace fsx = std::filesystem;

static int fails = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++fails;
}

// UTF-8 串 → fs::path（本测试唯一允许的路径构造方式；**不经过 widen**）
static fsx::path P(const std::string& utf8) { return path_from_utf8(utf8); }

// 确定性构造：997 Hz / −23 dBFS 立体声 48k / 10 s。
// bits=16 走 16-bit 量化；shifted=true 时把同样的 16-bit 值 <<8 装进 24-bit 容器（fake24 用例）。
static rta::audio::AudioBuffer make_tone(int bits, bool shifted) {
    rta::audio::AudioBuffer ab;
    ab.rate = 48000;
    ab.channels = 2;
    ab.bits = bits;
    ab.isFloat = false;
    const size_t n = (size_t)(10.0 * 48000.0);
    ab.raw.resize(n * 2);
    const double amp = std::pow(10.0, -23.0 / 20.0);
    for (size_t i = 0; i < n; ++i) {
        const double x = amp * std::sin(2.0 * kPi * 997.0 * (double)i / 48000.0);
        const int32_t v16 = (int32_t)std::llround(x * 32768.0);
        for (int c = 0; c < 2; ++c) {
            const size_t k = i * 2 + (size_t)c;
            if (bits == 16)          ab.raw[k] = v16;
            else if (shifted)        ab.raw[k] = v16 << 8;
            else                     ab.raw[k] = (int32_t)std::llround(x * 8388608.0);
        }
    }
    return ab;
}

// 手写 44 字节头 + 16-bit PCM 数据（仅支持 16-bit 立体声，测试够用）
static bool write_wav44(const std::string& path, const rta::audio::AudioBuffer& ab) {
    if (ab.bits != 16 || ab.isFloat) return false;
    std::ofstream f(P(path), std::ios::binary | std::ios::trunc);
    if (!f) return false;
    const uint32_t n = (uint32_t)ab.raw.size();
    const uint32_t dataBytes = n * 2;
    const uint32_t rate = ab.rate, ch = (uint32_t)ab.channels;
    const uint16_t blockAlign = (uint16_t)(ch * 2);
    const uint32_t byteRate = rate * (uint32_t)blockAlign;
    auto u32 = [&](uint32_t v) { f.put((char)(v & 0xFF)); f.put((char)((v >> 8) & 0xFF));
                                 f.put((char)((v >> 16) & 0xFF)); f.put((char)((v >> 24) & 0xFF)); };
    auto u16 = [&](uint16_t v) { f.put((char)(v & 0xFF)); f.put((char)((v >> 8) & 0xFF)); };
    f.write("RIFF", 4); u32(36 + dataBytes); f.write("WAVE", 4);
    f.write("fmt ", 4); u32(16); u16(1); u16((uint16_t)ch); u32(rate); u32(byteRate); u16(blockAlign); u16(16);
    f.write("data", 4); u32(dataBytes);
    for (uint32_t i = 0; i < n; ++i) u16((uint16_t)(int16_t)ab.raw[i]);
    return (bool)f;
}

// ---- U10 夹具：手工拼四个容器的**最小合法头**（只测头解析，不测解码）----
// 数值与上游 tests/test_health_completeness.cpp 的锚点逐一致：
//   FLAC 1413239 @44100 = 32.046 s / WAV 10485760 B @176400 Bps = 59.443 s /
//   MP3 Xing 4098 帧 ×1152 @44100 = 107.050 s / DSF 1083768832 @2822400 = 383.988 s
static void write_raw_bytes(const std::string& path, const std::vector<unsigned char>& b) {
    std::ofstream f(P(path), std::ios::binary | std::ios::trunc);
    f.write((const char*)b.data(), (std::streamsize)b.size());
}
static std::vector<unsigned char> flac_hdr(uint32_t rate, int ch, int bps, long long total) {
    std::vector<unsigned char> v;
    auto put = [&v](const char* s) { for (int i = 0; s[i]; ++i) v.push_back((unsigned char)s[i]); };
    put("fLaC");
    v.push_back(0x80);                                  // last-block=1, type=0(STREAMINFO)
    v.push_back(0); v.push_back(0); v.push_back(34);    // 长度 34
    std::vector<unsigned char> si(34, 0);
    si[0] = 0x12; si[1] = 0x00; si[2] = 0x12; si[3] = 0x00;   // min/max block size（值无关）
    si[10] = (unsigned char)((rate >> 12) & 0xFF);
    si[11] = (unsigned char)((rate >> 4) & 0xFF);
    si[12] = (unsigned char)(((rate & 0x0F) << 4) | (((ch - 1) & 0x7) << 1) | (((bps - 1) >> 4) & 0x1));
    si[13] = (unsigned char)((((bps - 1) & 0x0F) << 4) | ((total >> 32) & 0x0F));
    for (int i = 0; i < 4; ++i) si[14 + i] = (unsigned char)((total >> (8 * (3 - i))) & 0xFF);
    v.insert(v.end(), si.begin(), si.end());
    v.resize(v.size() + 64, 0);
    return v;
}
static std::vector<unsigned char> wav_hdr(uint32_t byteRate, uint32_t dataSize, bool dataFirst = false) {
    std::vector<unsigned char> v;
    auto put = [&v](const char* s) { for (int i = 0; s[i]; ++i) v.push_back((unsigned char)s[i]); };
    auto le32 = [&v](uint32_t x) { for (int i = 0; i < 4; ++i) v.push_back((unsigned char)((x >> (8*i)) & 0xFF)); };
    auto le16 = [&v](unsigned x) { for (int i = 0; i < 2; ++i) v.push_back((unsigned char)((x >> (8*i)) & 0xFF)); };
    auto fmt = [&]() {
        put("fmt "); le32(16);
        le16(1); le16(2); le32(44100); le32(byteRate); le16(4); le16(16);
    };
    auto data = [&]() { put("data"); le32(dataSize); };
    put("RIFF"); le32(36 + dataSize); put("WAVE");
    if (dataFirst) { data(); } else { fmt(); data(); }
    if (dataFirst) { fmt(); }                  // 坏头：data 在 fmt 之前
    v.resize(v.size() + 128, 0);               // 一点真实字节（远少于声明值）
    return v;
}
static std::vector<unsigned char> mp3_xing_hdr(uint32_t frames, long long delay, long long padding) {
    std::vector<unsigned char> v;
    v.push_back(0xFF); v.push_back(0xFB);       // MPEG1 Layer3，无 CRC
    v.push_back(0x90);                           // bitrate idx 9(128k) / sr idx 0(44.1k)
    v.push_back(0x00);                           // 立体声
    v.resize(4 + 32, 0);                         // 边信息 32 字节（MPEG1 立体声）
    auto putBE32 = [&v](uint32_t x) { for (int i = 3; i >= 0; --i) v.push_back((unsigned char)((x >> (8*i)) & 0xFF)); };
    v.push_back('X'); v.push_back('i'); v.push_back('n'); v.push_back('g');
    putBE32(0x1);                                // flags: FRAMES 位
    putBE32(frames);
    v.resize(4 + 32 + 120, 0);                   // Xing 头合计 120 字节
    if (delay >= 0) {
        v.push_back('L'); v.push_back('A'); v.push_back('M'); v.push_back('E');
        v.resize(v.size() + 17, 0);              // 到 LAME 标签 +21
        v.push_back((unsigned char)((delay >> 4) & 0xFF));
        v.push_back((unsigned char)(((delay & 0x0F) << 4) | ((padding >> 8) & 0x0F)));
        v.push_back((unsigned char)(padding & 0xFF));
    }
    v.resize(v.size() + 256, 0);
    return v;
}
static std::vector<unsigned char> dsf_hdr(uint32_t rate, uint64_t count) {
    std::vector<unsigned char> v;
    auto put = [&v](const char* s) { for (int i = 0; s[i]; ++i) v.push_back((unsigned char)s[i]); };
    auto le32 = [&v](uint32_t x) { for (int i = 0; i < 4; ++i) v.push_back((unsigned char)((x >> (8*i)) & 0xFF)); };
    auto le64 = [&v](uint64_t x) { for (int i = 0; i < 8; ++i) v.push_back((unsigned char)((x >> (8*i)) & 0xFF)); };
    put("DSD "); le64(28); le64(28 + 12 + 52 + 12 + 128); le64(0);      // 头 + fmt + 一点 data
    put("fmt "); le64(52);
    le32(1); le32(0); le32(2); le32(2);           // 版本 / 格式ID / 声道类型 / 声道数
    le32(rate); le32(1); le64(count); le32(4096); le32(0);
    put("data"); le64(128);
    v.resize(v.size() + 128, 0);
    return v;
}

// ---------------- 流式体检的一致性判据（macOS 移植：路径与段号已本地化） ----------------
// 上游这三节的路径拼接是 `tmpDir + "\\xxx"`。mac 上 `\` 是【合法文件名字符】而非分隔符，
// 照抄会在临时目录造出一个名字里带反斜杠的文件 —— 不报错、看起来"通过"，但行为与
// Windows 完全不同（且不会覆盖同名文件）。本库统一改走 rta::platform::join()（与 §1~§6 一致）。
// 段号 7/8/9 顺延为 9/10/11：本地 §7 是中文路径往返、§8 是 mtime 纳秒精度，两者都保留。
static bool same_bits(double a, double b) {
    if (a == b) return true;                                  // 含 +0/-0
    return std::memcmp(&a, &b, sizeof(double)) == 0;
}
// 逐位相同 = 全部指标 + 元信息 + 人话原因逐字相同（"差不多"不算）
static bool same_health(const TrackHealth& a, const TrackHealth& b) {
    return a.status == b.status && a.error == b.error
        && same_bits(a.drDb, b.drDb) && same_bits(a.lufs, b.lufs)
        && same_bits(a.lra, b.lra) && same_bits(a.peakDbfs, b.peakDbfs)
        && same_bits(a.truePeakDbtp, b.truePeakDbtp)
        && a.truePeakAvailable == b.truePeakAvailable
        && a.drAvailable == b.drAvailable && a.lraAvailable == b.lraAvailable
        && a.lufsAvailable == b.lufsAvailable
        && same_bits(a.cutoffHz, b.cutoffHz) && same_bits(a.confidence, b.confidence)
        && a.losslessSuspected == b.losslessSuspected && a.fake24bit == b.fake24bit
        && a.reason == b.reason
        && same_bits(a.durationSec, b.durationSec)
        // U10：整段与流式两条路径的完整性结论也必须逐字一致（声明时长、是否半截、人话提示）
        && same_bits(a.declaredSec, b.declaredSec) && a.incomplete == b.incomplete && a.note == b.note
        && a.fs == b.fs && a.channels == b.channels && a.bits == b.bits;
}
static std::string health_brief(const TrackHealth& h) {
    char b[320];
    std::snprintf(b, sizeof(b),
                  "(DR %.17g / LUFS %.17g / LRA %.17g / peak %.17g / tp %.17g / cutoff %.17g / conf %.17g / sus %d / fake24 %d / %s)",
                  h.drDb, h.lufs, h.lra, h.peakDbfs, h.truePeakDbtp, h.cutoffHz, h.confidence,
                  (int)h.losslessSuspected, (int)h.fake24bit, h.status.c_str());
    return std::string(b);
}
static std::string max_diff_text(const TrackHealth& x, const TrackHealth& y) {
    auto d = [](double p, double q) { return std::fabs(p - q); };
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "max|Δ| = %.17g (dr %.3g, lufs %.3g, lra %.3g, peak %.3g, tp %.3g, cutoff %.3g, conf %.3g)",
                  std::max({ d(x.drDb, y.drDb), d(x.lufs, y.lufs), d(x.lra, y.lra), d(x.peakDbfs, y.peakDbfs),
                             d(x.truePeakDbtp, y.truePeakDbtp),
                             d(x.cutoffHz, y.cutoffHz), d(x.confidence, y.confidence) }),
                  d(x.drDb, y.drDb), d(x.lufs, y.lufs), d(x.lra, y.lra), d(x.peakDbfs, y.peakDbfs),
                  d(x.truePeakDbtp, y.truePeakDbtp),
                  d(x.cutoffHz, y.cutoffHz), d(x.confidence, y.confidence));
    return std::string(buf);
}

// 通用 WAV 写出（8/16/24/32 整型 + 32-bit float）：raw 里存的是 AudioBuffer 的整数样本
static bool write_wav_any(const std::string& path, const rta::audio::AudioBuffer& ab) {
    const int bytesPer = ab.bits / 8;
    if (bytesPer < 1 || ab.channels <= 0) return false;
    const uint32_t dataBytes = (uint32_t)(ab.raw.size() * (size_t)bytesPer);
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (!f) return false;
    const uint16_t ch = (uint16_t)ab.channels;
    const uint16_t blockAlign = (uint16_t)(ch * bytesPer);
    const uint32_t byteRate = ab.rate * (uint32_t)blockAlign;
    auto u32 = [&](uint32_t v) { f.put((char)(v & 0xFF)); f.put((char)((v >> 8) & 0xFF));
                                 f.put((char)((v >> 16) & 0xFF)); f.put((char)((v >> 24) & 0xFF)); };
    auto u16 = [&](uint16_t v) { f.put((char)(v & 0xFF)); f.put((char)((v >> 8) & 0xFF)); };
    f.write("RIFF", 4); u32(36 + dataBytes); f.write("WAVE", 4);
    f.write("fmt ", 4); u32(16); u16(ab.isFloat ? (uint16_t)3 : (uint16_t)1); u16(ch); u32(ab.rate);
    u32(byteRate); u16(blockAlign); u16((uint16_t)ab.bits);
    f.write("data", 4); u32(dataBytes);
    for (size_t i = 0; i < ab.raw.size(); ++i) {
        const int32_t v = ab.raw[i];
        if (ab.isFloat) {
            float x; std::memcpy(&x, &v, 4);
            uint32_t u; std::memcpy(&u, &x, 4);
            u32(u);
        } else if (ab.bits == 8) {
            f.put((char)(uint8_t)(v + 128));            // 8-bit WAV 无符号，中心 128
        } else {
            for (int k = 0; k < bytesPer; ++k) f.put((char)((v >> (8 * k)) & 0xFF));
        }
    }
    return (bool)f;
}

// 合成一个最小可用的 DSF（DSD64 单声道/立体声，1-bit 白噪位流）
static bool write_test_dsf(const std::string& path, int channels, uint32_t dsdRate, uint64_t bitsPerCh) {
    const uint32_t blockSize = 4096;
    const uint64_t needBytes = (bitsPerCh + 7) / 8;
    const uint64_t fullBlocks = needBytes / blockSize;
    const uint64_t rem = needBytes % blockSize;
    const uint64_t nBlocks = fullBlocks + (rem ? 1 : 0);
    const uint64_t dataSize = nBlocks * (uint64_t)channels * (uint64_t)blockSize;
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    if (!f) return false;
    auto u32 = [&](uint32_t v) { f.put((char)(v & 0xFF)); f.put((char)((v >> 8) & 0xFF));
                                 f.put((char)((v >> 16) & 0xFF)); f.put((char)((v >> 24) & 0xFF)); };
    auto u64 = [&](uint64_t v) { for (int k = 0; k < 8; ++k) f.put((char)((v >> (8 * k)) & 0xFF)); };
    const uint64_t totalSize = 28 + 52 + 12 + dataSize;
    f.write("DSD ", 4); u64(28); u64(totalSize); u64(0);
    f.write("fmt ", 4); u64(52);
    u32(1);                                   // format version
    u32(0);                                   // format id = DSD raw
    u32(2);                                   // channel type = stereo
    u32((uint32_t)channels);
    u32(dsdRate);
    u32(1);                                   // bits per sample
    u64(bitsPerCh);                           // sample count（每声道 1-bit 采样数）
    u32(blockSize);                           // block size per channel
    u32(0);                                   // reserved
    f.write("data", 4); u64(dataSize + 12);
    for (uint64_t b = 0; b < nBlocks; ++b) {
        for (int c = 0; c < channels; ++c) {
            uint32_t rng = 0x12345679u * (uint32_t)(b + 1) + 0x9E3779B9u * (uint32_t)(c + 1);
            for (uint32_t i = 0; i < blockSize; ++i) {
                rng = rng * 1664525u + 1013904223u;
                f.put((char)(uint8_t)(rng >> 24));
            }
        }
    }
    return (bool)f;
}

static std::string brief(const TrackHealth& h) {
    char b[256];
    std::snprintf(b, sizeof(b), "(LUFS %.3f, DR %.3f, LRA %.3f, peak %.3f, fake24 %d, %s) %s",
                  h.lufs, h.drDb, h.lra, h.peakDbfs, h.fake24bit ? 1 : 0, h.status.c_str(),
                  h.reason.c_str());
    return std::string(b);
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    // mac：temp_dir_utf8() 带尾分隔符（GetTempPathW 语义）；拼路径一律用 join()
    const std::string tmpDir = rta::platform::temp_dir_utf8();
    const std::string wavPath = rta::platform::join(tmpDir, "rtahealth_b1b_tone.wav");
    const std::string storePath = rta::platform::join(tmpDir, "rtahealth_b1b_store.json");
    printf("临时目录: %s\n", tmpDir.c_str());

    printf("=== 1. analyze_buffer：997 Hz / −23 dBFS 立体声 48k / 10 s / 16-bit（B1a 锚点一致性）===\n");
    rta::audio::AudioBuffer tone16;
    TrackHealth h1;
    {
        tone16 = make_tone(16, false);
        const auto t0 = std::chrono::steady_clock::now();
        h1 = analyze_buffer(tone16);
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        printf("  %s（analyze_buffer 耗时 %.1f ms）\n", brief(h1).c_str(), ms);
        check(h1.status == "ready", "status = ready");
        check(std::fabs(h1.lufs - (-23.0)) <= 0.1, "lufs = −23.0 ±0.1（与 B1a 一致）", brief(h1));
        check(std::fabs(h1.drDb - 3.0) <= 0.5, "dr_db = 3.0 ±0.5（与 B1a 一致）", brief(h1));
        check(std::fabs(h1.peakDbfs - (-23.0)) <= 0.05, "peak_dbfs = −23.0 ±0.05", brief(h1));
        check(std::fabs(h1.durationSec - 10.0) <= 0.01, "duration_sec = 10 ±0.01");
        check(h1.fs == 48000 && h1.channels == 2 && h1.bits == 16, "元信息 fs/channels/bits");
        check(h1.analyzedAtMs > 1700000000000ll, "analyzed_at_ms 已填（Unix 毫秒量级）");
        check(!h1.fake24bit, "16-bit 素材 fake24 = false");
    }

    printf("\n=== 2. fake24：同内容 16-bit 值 <<8 装入 24-bit → true；真 24-bit 量化 → false ===\n");
    {
        TrackHealth hs = analyze_buffer(make_tone(24, true));
        printf("  shifted: %s\n", brief(hs).c_str());
        check(hs.status == "ready", "status = ready");
        check(hs.fake24bit, "fake24 = true（16-bit 内容 <<8 装入 24-bit）");
        check(std::fabs(hs.lufs - h1.lufs) <= 0.1, "<<8 装填不改变响度读数（±0.1）", brief(hs));
        TrackHealth ht = analyze_buffer(make_tone(24, false));
        printf("  true24 : %s\n", brief(ht).c_str());
        check(!ht.fake24bit, "真 24-bit 量化 fake24 = false（对照）");
    }

    printf("\n=== 3. 临时 WAV 端到端：analyze_file 与 analyze_buffer 数字一致（±0.05）===\n");
    {
        const bool written = write_wav44(wavPath, tone16);
        check(written, "临时 WAV 写出成功（44 字节头 + PCM）", wavPath);
        const auto t0 = std::chrono::steady_clock::now();
        const TrackHealth hf = analyze_file(wavPath);
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        printf("  file: %s（analyze_file 耗时 %.1f ms）\n", brief(hf).c_str(), ms);
        check(hf.status == "ready", "status = ready");
        check(std::fabs(hf.lufs - h1.lufs) <= 0.05, "lufs 与 analyze_buffer 一致（±0.05）",
              brief(hf) + " vs " + brief(h1));
        check(std::fabs(hf.drDb - h1.drDb) <= 0.05, "dr_db 一致（±0.05）");
        check(std::fabs(hf.lra - h1.lra) <= 0.05, "lra 一致（±0.05）");
        check(std::fabs(hf.peakDbfs - h1.peakDbfs) <= 0.05, "peak_dbfs 一致（±0.05）");
        check(hf.fs == 48000 && hf.channels == 2 && hf.bits == 16, "元信息一致（read_wav 回读）");
        // 1.1.4：正常 analyze_file 的结果必须带 true peak 与 available 标志，JSON 键齐全
        check(hf.truePeakAvailable && hf.drAvailable && hf.lraAvailable && hf.lufsAvailable,
              "新 flags 透传：10 s 素材 truePeak/dr/lra/lufs 全部 available", health_brief(hf));
        const std::string jf = track_health_json(hf);
        const char* newKeys[] = { "true_peak_dbtp", "true_peak_available",
                                  "dr_available", "lra_available", "lufs_available",
                                  "hf_ratio_10k_available", "side_mid_available" };
        for (const char* k : newKeys) {
            const std::string needle = std::string("\"") + k + "\":";
            check(jf.find(needle) != std::string::npos,
                  std::string("正常 analyze_file JSON 含新字段: ") + k);
        }
        check(jf.find("\"true_peak_available\":true") != std::string::npos,
              "正常 analyze_file JSON: true_peak_available=true");
        std::error_code ec;
        fsx::remove(P(wavPath), ec);
        check(!fsx::exists(P(wavPath)), "临时文件已删除");
    }

    printf("\n=== 4. analyze_file 不存在的路径 → status=error、error 非空、不抛异常 ===\n");
    {
        const std::string ghost = rta::platform::join(tmpDir, "rtahealth_b1b_no_such_file.wav");
        bool threw = false;
        TrackHealth hg;
        try {
            hg = analyze_file(ghost);
        } catch (...) { threw = true; }
        check(!threw, "未抛异常");
        check(hg.status == "error", "status = error", hg.error);
        check(!hg.error.empty(), "error 非空（人话原因）", hg.error);
        check(hg.analyzedAtMs > 0, "analyzed_at_ms 仍已填");
        const std::string j = track_health_json(hg);
        check(j.find("\"status\":\"error\"") != std::string::npos && j.find("\"error\":\"") != std::string::npos,
              "error 形态的 JSON 序列化正常");
    }

    printf("\n=== 5. HealthStore：落盘→重载命中；mtime/size 变化未命中；损坏文件报错不静默清空 ===\n");
    {
        // 5a upsert → save → 重新构造加载 → 命中（含中文 reason 往返 + 规范化路径命中）
        std::error_code ec;
        fsx::remove(P(storePath), ec);
        fsx::remove(P(storePath + ".tmp"), ec);
        write_wav44(wavPath, tone16); // content digest requires the actual source, not a deleted placeholder
        TrackHealth hCache = h1;
        hCache.reason = "测试往返：中文\"引号\"\\斜杠 与 16.2 kHz 截止";
        {
            HealthStore a(storePath);
            check(a.size() == 0 && a.loadError().empty(), "不存在的缓存文件 → 空库、无错误");
            a.upsert(wavPath, 111, 222, hCache);
            a.upsert(wavPath, 111, 222, hCache);          // 重复 upsert 覆盖同键
            check(a.save(), "save() 原子写成功");
            check(fsx::exists(P(storePath)), "缓存文件已产生");
            check(!fsx::exists(P(storePath + ".tmp")), "tmp 已被 rename 消费");
        }
        TrackHealth out;
        HealthStore b(storePath);
        check(b.size() == 1 && b.loadError().empty(), "重新构造加载：1 条、无错误");
        check(b.lookup(wavPath, 111, 222, out), "同参命中");
        check(std::fabs(out.lufs - hCache.lufs) <= 1e-3 && std::fabs(out.drDb - hCache.drDb) <= 1e-3,
              "数值往返一致（1e-3 精度）", brief(out));
        check(out.reason == hCache.reason && out.status == "ready", "中文 reason / status 往返逐字一致", out.reason);
        // mac：等价路径用 "/./"（正斜杠）而不是上游的 "\\.\\"（反斜杠在 POSIX 上是文件名字符）
        check(b.lookup(tmpDir + "./rtahealth_b1b_tone.wav", 111, 222, out),
              "带 /./ 段的等价路径经 weakly_canonical 规范化后命中");
        check(!b.lookup(wavPath, 111, 223, out), "size 变化 → 未命中");
        check(!b.lookup(wavPath, 112, 222, out), "mtime 变化 → 未命中");

        // 5b 改 size 再写 → 旧条目被覆盖、新键命中
        {
            HealthStore c(storePath);
            c.upsert(wavPath, 111, 999, hCache);
            check(c.save(), "改 size 后 save 成功");
        }
        {
            HealthStore d(storePath);
            check(d.size() == 1, "同键覆盖（不是追加）");
            check(d.lookup(wavPath, 111, 999, out) && !d.lookup(wavPath, 111, 222, out),
                  "新三元组命中、旧三元组失效");
        }

        // 5c 手改坏缓存文件 → 重新加载报错不崩；save() 拒绝写盘；文件保持原样（不静默清空）
        const std::string garbage = "{{{ 这不是 JSON ！！";
        {
            std::ofstream g(P(storePath), std::ios::binary | std::ios::trunc);
            g << garbage;
        }
        HealthStore e(storePath);
        check(!e.loadError().empty(), "损坏文件 → loadError() 非空（如实报错）", e.loadError());
        check(!e.lookup(wavPath, 111, 999, out), "损坏库 lookup 一律未命中（不崩）");
        check(!e.save(), "损坏库 save() 拒绝写盘");
        std::ifstream back(P(storePath), std::ios::binary);
        const std::string after((std::istreambuf_iterator<char>(back)), std::istreambuf_iterator<char>());
        check(after == garbage, "损坏文件内容原样保留（没有被静默清空/覆盖）");
        fsx::remove(P(storePath), ec);
        fsx::remove(P(storePath + ".tmp"), ec);
        fsx::remove(P(wavPath), ec);
    }

    printf("\n=== 6. track_health_json：字段名与契约逐字一致 + 转义回读 ===\n");
    {
        TrackHealth t;
        t.drDb = 8.125; t.lufs = -23.456; t.lra = 5.25; t.peakDbfs = -0.1;
        // 1.1.4 新字段（additive）：true peak 与 available 标志
        t.truePeakDbtp = -0.075; t.truePeakAvailable = true;
        t.drAvailable = true; t.lraAvailable = true; t.lufsAvailable = true;
        t.losslessSuspected = true; t.cutoffHz = 16193.0; t.confidence = 0.875;
        t.reason = "测试\"引号\"\\反斜杠\n换行\t制表 中文直通 16.2 kHz";
        t.fake24bit = true; t.durationSec = 123.4567; t.fs = 48000;
        t.channels = 2; t.bits = 24; t.status = "ready"; t.error = "";
        t.analyzedAtMs = 1761360000123ll;
        const std::string j = track_health_json(t);
        const char* keys[] = { "dr_db", "lufs", "lra", "peak_dbfs", "lossless_suspected", "cutoff_hz",
                               "confidence", "reason", "fake24", "duration_sec", "fs", "channels",
                               "bits", "status", "error", "analyzed_at_ms",
                               "true_peak_dbtp", "true_peak_available",
                               "dr_available", "lra_available", "lufs_available" };
        for (const char* k : keys) {
            const std::string needle = std::string("\"") + k + "\":";
            check(j.find(needle) != std::string::npos, std::string("字段名存在: ") + k);
        }
        const rta::net::Json p = rta::net::json_parse(j);
        check(p.ok(), "项目 JSON 解析器可解析（合法 JSON）");
        check(std::fabs(p["lufs"].n() - (-23.456)) < 5e-4, "lufs 数值往返", std::to_string(p["lufs"].n()));
        check(std::fabs(p["true_peak_dbtp"].n() - (-0.075)) < 5e-4, "true_peak_dbtp 数值往返",
              std::to_string(p["true_peak_dbtp"].n()));
        check(p["true_peak_available"].b && p["dr_available"].b && p["lra_available"].b
                  && p["lufs_available"].b,
              "新 available 布尔字段往返");
        check(p["lossless_suspected"].b && p["fake24"].b, "布尔字段往返");
        check(p["reason"].s() == t.reason, "reason 转义回读逐字一致", p["reason"].s());
        check((int64_t)p["analyzed_at_ms"].n() == 1761360000123ll, "analyzed_at_ms 毫秒往返（double 精度内无损）");
        check((int)p["fs"].n() == 48000 && (int)p["channels"].n() == 2 && (int)p["bits"].n() == 24,
              "整数元信息往返");
        // 不可用时必须写 -300（0 会被误读成 0 dBTP）
        TrackHealth t2;
        t2.truePeakDbtp = 0.0; t2.truePeakAvailable = false;
        const std::string j2 = track_health_json(t2);
        check(j2.find("\"true_peak_dbtp\":-300.000") != std::string::npos
                  && j2.find("\"true_peak_available\":false") != std::string::npos,
              "true peak 不可用时 JSON 写 -300 / false", j2.substr(0, 120));
    }

    // ---------------- §7 中文路径往返（mac 新增：本移植的核心判据） ----------------
    printf("\n=== 7. 中文路径往返：中文目录 + 中文文件名 走完整 save→load→lookup ===\n");
    {
        // 造一个真的中文目录（mac 文件系统 UTF-8 原生，不需要任何转码）
        const std::string cnDir = rta::platform::join(tmpDir, "音频体检-中文目录");
        std::error_code ec;
        fsx::create_directories(P(cnDir), ec);
        check(fsx::is_directory(P(cnDir), ec) && !ec, "中文目录创建成功", cnDir);

        const std::string cnWav = rta::platform::join(cnDir, "测试曲目-不由己.wav");
        const std::string cnStore = rta::platform::join(cnDir, "体检缓存-中文.json");

        // 7a 先把「上游 widen 路线在 mac 上会炸」这件事钉死（负向对照，铁证）
        {
            // mac 的 widen 是字节保序恒等（audio_loader.h:52）
            const std::wstring w = rta::audio::widen(cnWav);
            bool threw = false;
            std::string what;
            try {
                const fsx::path p(w);          // ← 上游 health_store.h:30/118 就是这么写的
                (void)p;
            } catch (const std::exception& e) { threw = true; what = e.what(); }
            printf("  上游 widen 路线: %s\n",
                   threw ? ("抛异常 → " + what).c_str() : "未抛异常");
            // 这不是"上游代码写错了"，是 mac 的 wchar_t 语义与 Windows 不同。
            // 断言它**确实会炸**，才能证明本移植改用 u8path 不是无的放矢。
            check(threw, "上游 widen→fs::path 路线在 mac 上对中文路径会抛异常（所以必须改写）",
                  threw ? what : "本机未抛——若为真则本移植的理由需重新论证");
        }

        // 7b 本移植的 u8path 路线：中文路径全流程可用
        write_wav44(cnWav, tone16);
        const TrackHealth hf = analyze_file(cnWav);
        printf("  中文 WAV 体检: %s\n", brief(hf).c_str());
        check(hf.status == "ready", "analyze_file 读中文路径成功", hf.error);
        check(std::fabs(hf.lufs - h1.lufs) <= 0.05, "中文路径读数与 ASCII 路径一致（±0.05）", brief(hf));

        TrackHealth hCache = h1;
        hCache.reason = "中文缓存条目";
        {
            HealthStore a(cnStore);
            a.upsert(cnWav, 7, 8, hCache);
            check(a.save(), "中文路径 save() 成功", cnStore);
            check(fsx::exists(P(cnStore)), "中文名缓存文件已产生");
        }
        {
            HealthStore b(cnStore);
            check(b.loadError().empty() && b.size() == 1, "中文路径重载：1 条、无错误", b.loadError());
            TrackHealth out;
            check(b.lookup(cnWav, 7, 8, out), "中文路径 lookup 命中");
            check(out.reason == "中文缓存条目", "中文 reason 往返一致", out.reason);
            // 规范化后的键必须是 UTF-8（不是被破坏的字节）
            const std::string key = normalize_path_key(cnWav);
            check(key.find("测试曲目-不由己") != std::string::npos,
                  "规范化键保留中文（未被编码破坏）", key);
        }

        fsx::remove(P(cnWav), ec);
        fsx::remove(P(cnStore), ec);
        fsx::remove(P(cnStore + ".tmp"), ec);
        fsx::remove(P(cnDir), ec);
        check(!fsx::exists(P(cnDir)), "中文临时目录已清理");
    }

    // ---------------- §8 mtime 精度（mac 新增：file_clock 是纳秒，比 MSVC 还大） ----------------
    printf("\n=== 8. mtime 精度：mac file_clock 是纳秒（1.79e18 > 2^53），毫秒口径不丢 ===\n");
    {
        // 实测本机 file_clock 的量级与两种口径的 double 往返误差
        const auto now = fsx::file_time_type::clock::now();
        const long long ns = (long long)std::chrono::duration_cast<std::chrono::nanoseconds>(
                                 now.time_since_epoch()).count();
        const long long ms = (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                                 now.time_since_epoch()).count();
        const long long nsErr = (long long)(double)ns - ns;
        const long long msErr = (long long)(double)ms - ms;
        printf("  file_clock now: ns=%lld (2^53=%.0f), ms=%lld\n", ns, 9007199254740992.0, ms);
        printf("  double 往返误差: ns=%+lld, ms=%+lld\n", nsErr, msErr);
        check(ns > 9007199254740992ll, "mac 纳秒 count 确实超 2^53（所以必须降到毫秒）");
        check(ms < 9007199254740992ll, "毫秒 count 在 2^53 内");
        check(msErr == 0, "毫秒口径 double 往返零误差（本库选它的理由）", std::to_string(msErr));
        // 纳秒口径**确实会丢**（本机实测丢 8 ns）：这条是负向对照，证明"担心不是多余的"。
        // 不断言一定非零（不同时刻可能恰好为 0），只把实测值打出来。
        printf("  （注：纳秒口径本机实测丢 %+lld ns —— 只要非零就足以让缓存永不命中）\n", nsErr);

        // 端到端：真实文件的 mtime 经 store 往返后仍能命中
        const std::string mp = rta::platform::join(tmpDir, "rtahealth_mtime_probe.json");
        const std::string wp = rta::platform::join(tmpDir, "rtahealth_mtime_probe.wav");
        write_wav44(wp, tone16);
        std::error_code ec;
        const auto wt = fsx::last_write_time(P(wp), ec);
        check(!ec, "取到临时文件 mtime");
        const int64_t mtMs = (int64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
                                 wt.time_since_epoch()).count();
        const int64_t sz = (int64_t)fsx::file_size(P(wp), ec);
        check(!ec && sz > 0, "取到临时文件 size");
        {
            HealthStore s(mp);
            s.upsert(wp, mtMs, sz, h1);
            check(s.save(), "按真实 mtime/size 落盘");
        }
        {
            HealthStore s(mp);
            TrackHealth out;
            check(s.lookup(wp, mtMs, sz, out), "真实 mtime/size 重载后命中（精度足够）");
            check(!s.lookup(wp, mtMs + 1, sz, out), "mtime +1ms 即未命中（不是靠模糊匹配混过去）");
        }
        fsx::remove(P(mp), ec);
        fsx::remove(P(wp), ec);
    }

    printf("\n=== 9. 流式 vs 整段：WAV 各格式（8/16/24-bit + 32-bit float）× 块大小 1000/65536/262144 全逐位一致 ===\n");
    {
        const std::string dir = rta::platform::join(tmpDir, "rtahealth_stream_");
        // 文件名一律 ASCII：Windows 上 std::ofstream 的窄路径按 ANSI 代码页解释，中文名写不出来
        struct Case { const char* name; const char* file; int bits; bool isFloat; int ch; };
        const Case cases[] = {
            { "8-bit 单声道",       "wav8_mono.wav",     8,  false, 1 },
            { "16-bit 立体声",      "wav16_stereo.wav",  16, false, 2 },
            { "24-bit 立体声",      "wav24_stereo.wav",  24, false, 2 },
            { "32-bit float 立体声", "wav32f_stereo.wav", 32, true,  2 },
        };
        for (const Case& cs : cases) {
            rta::audio::AudioBuffer ab;
            ab.rate = 48000; ab.channels = cs.ch; ab.bits = cs.bits; ab.isFloat = cs.isFloat;
            const size_t n = (size_t)(6.0 * 48000.0);
            ab.raw.resize(n * (size_t)cs.ch);
            // 复合内容：997 Hz 正弦 + 慢包络 + 一段静音（同时压 DR / 门限 / 谱窗）
            for (size_t i = 0; i < n; ++i) {
                const double t = (double)i / 48000.0;
                double x = (0.5 + 0.4 * std::sin(2.0 * kPi * 0.3 * t))
                         * (0.25 * std::sin(2.0 * kPi * 997.0 * t) + 0.08 * std::sin(2.0 * kPi * 7300.0 * t));
                if (t > 4.0 && t < 4.5) x = 0.0;
                for (int c = 0; c < cs.ch; ++c) {
                    const double v = (c == 0) ? x : x * 0.7;
                    if (cs.isFloat) {
                        const float fv = (float)v;
                        int32_t bits32; std::memcpy(&bits32, &fv, 4);
                        ab.raw[i * (size_t)cs.ch + (size_t)c] = bits32;
                    } else {
                        ab.setSample(i, c, v);
                    }
                }
            }
            const std::string p = dir + cs.file;
            const bool ok = write_wav_any(p, ab);
            check(ok, std::string("写出 WAV: ") + cs.name, p);
            if (!ok) continue;
            const TrackHealth whole = analyze_file_whole(p);
            const TrackHealth s1 = analyze_file(p, [] { HealthStreamOptions o; o.blockFrames = 1000; return o; }());
            const TrackHealth s2 = analyze_file(p, [] { HealthStreamOptions o; o.blockFrames = 65536; return o; }());
            const TrackHealth s3 = analyze_file(p, [] { HealthStreamOptions o; o.blockFrames = 262144; return o; }());
            check(whole.status == "ready" && s2.status == "ready", std::string("status=ready: ") + cs.name, health_brief(whole));
            check(s2.streamed, std::string("确实走了流式分块（streamed=true）: ") + cs.name);
            check(same_health(whole, s1), std::string("整段 vs 流式(1000) 逐位一致: ") + cs.name, max_diff_text(whole, s1));
            check(same_health(whole, s2), std::string("整段 vs 流式(65536) 逐位一致: ") + cs.name, max_diff_text(whole, s2));
            check(same_health(whole, s3), std::string("整段 vs 流式(262144) 逐位一致: ") + cs.name, max_diff_text(whole, s3));
            printf("   %s %s\n", cs.name, health_brief(whole).c_str());
            std::error_code ec; fsx::remove(p, ec);
        }
    }

    printf("\n=== 10. 流式 vs 整段：合成 DSF（DSD64 → PCM 176.4k）逐位一致 ===\n");
    {
        const std::string p = rta::platform::join(tmpDir, "rtahealth_stream_test.dsf");
        const bool ok = write_test_dsf(p, 2, 2822400u, 2822400ull);   // 1 s / 立体声 / DSD64
        check(ok, "写出合成 DSF（DSD64, 1 s, 立体声）", p);
        if (ok) {
            const TrackHealth whole = analyze_file_whole(p);
            printf("   整段: %s\n   整段: %s\n", health_brief(whole).c_str(), whole.reason.c_str());
            check(whole.status == "ready", "整段解码 ready", whole.error);
            check(whole.fs == 176400 && whole.channels == 2 && whole.bits == 32,
                  "DSD64 → PCM 176.4 kHz / 2ch / 32bit", std::to_string(whole.fs));
            for (size_t B : {size_t(1000), size_t(65536), size_t(262144)}) {
                HealthStreamOptions o; o.blockFrames = B;
                const TrackHealth s = analyze_file(p, o);
                char b[128];
                std::snprintf(b, sizeof(b), "(块 %zu 帧, streamed=%d)", B, (int)s.streamed);
                check(s.streamed && same_health(whole, s),
                      std::string("DSD 整段 vs 流式逐位一致 ") + b, max_diff_text(whole, s));
            }
            std::error_code ec; fsx::remove(p, ec);
        }
    }

    printf("\n=== 11. 回退路径：WavPcmStream 拿不准的 WAV（data 在 fmt 之前）仍走整段且结果一致 ===\n");
    {
        // 手写一个 data 块在 fmt 之前的 WAV：read_wav 接受，parse_wav_header 拒绝 → 走整段回退
        const std::string p = rta::platform::join(tmpDir, "rtahealth_stream_datafirst.wav");
        const size_t n = (size_t)(2.0 * 48000.0);
        std::vector<int16_t> pcm(n * 2);
        for (size_t i = 0; i < n; ++i) {
            const double x = 0.2 * std::sin(2.0 * kPi * 997.0 * (double)i / 48000.0);
            pcm[i * 2] = (int16_t)std::llround(x * 32768.0);
            pcm[i * 2 + 1] = pcm[i * 2];
        }
        {
            std::ofstream f(p, std::ios::binary | std::ios::trunc);
            auto u32 = [&](uint32_t v) { f.put((char)(v & 0xFF)); f.put((char)((v >> 8) & 0xFF));
                                         f.put((char)((v >> 16) & 0xFF)); f.put((char)((v >> 24) & 0xFF)); };
            auto u16 = [&](uint16_t v) { f.put((char)(v & 0xFF)); f.put((char)((v >> 8) & 0xFF)); };
            const uint32_t dataBytes = (uint32_t)(pcm.size() * 2);
            f.write("RIFF", 4); u32(36 + dataBytes); f.write("WAVE", 4);
            f.write("data", 4); u32(dataBytes);                        // data 在 fmt 之前
            for (int16_t v : pcm) u16((uint16_t)v);
            f.write("fmt ", 4); u32(16); u16(1); u16(2); u32(48000);
            u32(48000 * 4); u16(4); u16(16);
        }
        const TrackHealth whole = analyze_file_whole(p);
        HealthStreamOptions o; o.blockFrames = 65536;
        const TrackHealth s = analyze_file(p, o);
        check(whole.status == "ready", "整段路径接受该文件（read_wav 容忍 data 在 fmt 前）", whole.error);
        check(!s.streamed, "流式源拒绝 → 已回退整段（streamed=false）", health_brief(s));
        check(same_health(whole, s), "回退结果与整段逐位一致", max_diff_text(whole, s));
        std::error_code ec; fsx::remove(p, ec);
    }

    // ---------------- §12 分析取消（1.1.4 新增） ----------------
    printf("\n=== 12. 取消：opt.cancel 置位 → cancelled / analysis.cancelled，且不回退整段解码 ===\n");
    {
        const std::string cp = rta::platform::join(tmpDir, "rtahealth_cancel_small.wav");
        rta::audio::AudioBuffer small;
        small.rate = 48000; small.channels = 2; small.bits = 16; small.isFloat = false;
        const size_t sn = (size_t)(0.5 * 48000.0);
        small.raw.resize(sn * 2);
        for (size_t i = 0; i < sn; ++i) {
            const double x = 0.2 * std::sin(2.0 * kPi * 997.0 * (double)i / 48000.0);
            const int32_t v = (int32_t)std::llround(x * 32768.0);
            small.raw[i * 2] = v;
            small.raw[i * 2 + 1] = v;
        }
        check(write_wav44(cp, small), "写出小型 WAV 夹具（0.5 s / 16-bit 立体声）", cp);

        // 12a 调用前就置位：应立刻返回 cancelled，不打开/解码文件
        std::atomic<bool> cancel{true};
        HealthStreamOptions o;
        o.blockFrames = 1000;
        o.cancel = &cancel;
        TrackHealth hc = analyze_file(cp, o);
        check(hc.status == "cancelled", "预置 cancel=true → status=cancelled", hc.status);
        check(hc.errorCode == "analysis.cancelled", "errorCode=analysis.cancelled", hc.errorCode);
        check(hc.error == "分析已取消", "error=分析已取消", hc.error);
        check(hc.analyzedAtMs > 0, "cancelled 结果仍填 analyzed_at_ms");

        // 12b 路径不存在 + 预置取消：仍必须是 cancelled 而不是 error
        //     —— 若错误地回退 analyze_file_whole，这里会变成"打不开文件"的 error。
        const std::string ghost = rta::platform::join(tmpDir, "rtahealth_cancel_ghost.wav");
        const TrackHealth hg = analyze_file(ghost, o);
        check(hg.status == "cancelled" && hg.errorCode == "analysis.cancelled",
              "不存在的路径 + 预置 cancel → cancelled（证明未回退整段解码）",
              hg.status + " / " + hg.errorCode);

        // 12c 正常路径（cancel=false，指针仍传入）：ready，且新字段/JSON 键齐全
        cancel.store(false);
        HealthStreamOptions o2;
        o2.blockFrames = 1000;
        o2.cancel = &cancel;
        const TrackHealth hn = analyze_file(cp, o2);
        check(hn.status == "ready", "cancel=false → 正常 ready", hn.error);
        check(hn.truePeakAvailable && hn.lufsAvailable,
              "0.5 s 素材 truePeak/lufs available", health_brief(hn));
        check(!hn.drAvailable && !hn.lraAvailable,
              "0.5 s 素材 dr/lra 不可用（<3 s 口径不成立）", health_brief(hn));
        const std::string jn = track_health_json(hn);
        const char* nk[] = { "true_peak_dbtp", "true_peak_available",
                             "dr_available", "lra_available", "lufs_available",
                             "hf_ratio_10k_available", "side_mid_available" };
        for (const char* k : nk) {
            const std::string needle = std::string("\"") + k + "\":";
            check(jn.find(needle) != std::string::npos,
                  std::string("正常 analyze_file JSON 含新字段: ") + k);
        }
        check(jn.find("\"true_peak_available\":true") != std::string::npos
                  && jn.find("\"dr_available\":false") != std::string::npos
                  && jn.find("\"lra_available\":false") != std::string::npos,
              "0.5 s 素材 JSON 的 available 标志与结构体一致");

        // 12d 流式块循环内部的取消：源在第一次 read 时置位，drive_health 必须在
        //     下一块开头看到并退出，同时保留已解析的 fs/channels/bits/analyzedAtMs。
        std::atomic<bool> loopCancel{false};
        struct CancelAfterFirstRead {
            std::atomic<bool>* flag;
            size_t total;
            uint32_t rate() const { return 48000; }
            int channels() const { return 2; }
            int bits() const { return 16; }
            bool isFloat() const { return false; }
            size_t totalFrames() const { return total; }
            size_t read(size_t pos, size_t n, rta::audio::AudioBuffer& out) {
                if (pos >= total || n == 0) return 0;
                if (n > total - pos) n = total - pos;
                out.rate = 48000; out.channels = 2; out.bits = 16; out.isFloat = false;
                out.raw.assign(n * 2, 0);
                flag->store(true);   // 第一块读完即请求取消
                return n;
            }
        } src{ &loopCancel, 10000 };
        bool streamedOk = true;
        const TrackHealth hl = detail::drive_health(src, 1000, &streamedOk, &loopCancel);
        check(hl.status == "cancelled" && hl.errorCode == "analysis.cancelled",
              "drive_health 在下一块开头检测取消", hl.status);
        check(hl.fs == 48000 && hl.channels == 2 && hl.bits == 16,
              "取消结果保留 fs/channels/bits");
        check(hl.analyzedAtMs > 0, "取消结果保留 analyzed_at_ms");
        check(!streamedOk, "取消时 streamedOk=false（未完成流式读取）");

        std::error_code ec;
        fsx::remove(P(cp), ec);
        check(!fsx::exists(P(cp)), "取消测试临时文件已删除");
    }


    // ---------------- §13 「文件可能不完整」判据（U10，2026-11-16） ----------------
    // 背景：半截文件（正在拷贝/下载/下载中断）能解码出"已有的那一部分"，duration_sec 只反映
    // 已有字节的长度，指标看起来全对 —— 旧实现在这里给 status=ready，用户拿到的是半份结论。
    // 本判据把容器声明时长（FLAC/WAV/MP3 Xing·VBRI/DSF）与实际解码时长比对，差太多就降为
    // status=incomplete + note（指标照给，不拒绝出数）。
    //
    // 本机（macOS 分支）实测的三种"半截"行为**不一样**，判据必须分别钉住：
    //   ① MP3：ffmpeg 照常解码已有帧 ⟹ 旧实现 status=ready + duration≈一半（**真正的假象**，
    //      这正是本判据要抓的形态；判据上线后变 incomplete）；
    //   ② WAV：产品自己的 read_wav 已经拒绝（"WAV data 块被截断…"）⟹ status=error。判据绝不能
    //      把这种**真错误**降级成 merely-incomplete（否则用户会以为只是没下载完）；
    //   ③ DSF：整段路径读到一半就结束（ready + 半长 ⟹ 判据能抓；素材要够长 —— 1 s 容差下限会让
    //      太短的素材被当噪声放过）；但**流式**路径按 fmt.sampleCount
    //      把缺失块补成静音 ⟹ analyze_file 会报满长，判据看不出差别（⚠️ 未解决项，见交付报告）。
    printf("\n=== 13. 文件可能不完整：容器声明时长 vs 实际解码（半截文件）===\n");
    {
        std::error_code ec;
        auto json_at = [](const std::string& js) { return rta::net::json_parse(js); };
        auto jnum = [](const rta::net::Json& p, const char* key) { return p.ok() ? p[key].n() : 0.0; };
        auto jstr = [](const rta::net::Json& p, const char* key) { return p.ok() ? p[key].s() : std::string(); };
        auto jhas = [](const std::string& js, const char* needle) { return js.find(needle) != std::string::npos; };
        auto truncate_half = [&](const std::string& path) {
            const uintmax_t n = fsx::file_size(P(path), ec);
            if (ec || n < 1000) return false;
            fsx::resize_file(P(path), n / 2, ec);
            return !ec;
        };

        // 13a 完整 WAV（10 s）：负向对照 —— declared ≈ duration，绝不误报
        const std::string fullWav = rta::platform::join(tmpDir, "rtahealth_u10_10s.wav");
        check(write_wav44(fullWav, tone16), "写出完整 WAV 夹具（10 s / 48 k / 16-bit 立体声）", fullWav);
        {
            const TrackHealth h = analyze_file(fullWav);
            const std::string js = track_health_json(h);
            const rta::net::Json p = json_at(js);
            printf("  wav full : status=%s dur=%.3f declared=%.3f\n", h.status.c_str(), h.durationSec,
                   jnum(p, "declared_sec"));
            check(h.status == "ready", "完整 WAV status = ready（负向对照）", h.status);
            check(jhas(js, "\"incomplete\":false"), "完整 WAV JSON incomplete=false");
            check(std::fabs(jnum(p, "declared_sec") - h.durationSec) <= 0.02,
                  "完整 WAV declared_sec ≈ 实际时长（±0.02，不误报的前提）",
                  std::to_string(jnum(p, "declared_sec")));
            check(jstr(p, "note").empty(), "完整 WAV note 为空串（不写死文案）");
            check(!h.incomplete && h.declaredSec > 0.0 && h.note.empty(), "完整 WAV 结构体字段：未判不完整");
        }
        // analyze_buffer 不判完整性（没有路径可读容器头，本来也无从判定）
        {
            const TrackHealth hb = analyze_buffer(tone16);
            check(hb.status == "ready" && !hb.incomplete && hb.declaredSec == 0.0 && hb.note.empty() &&
                      hb.errorCode.empty(),
                  "analyze_buffer 不判：declared_sec=0 / incomplete=false / note 空 / errorCode 空");
        }

        // 13b 截断 WAV（任务书指定的夹具）：本机解码器已拒绝 ⟹ 判据不许把它降级成 incomplete
        const std::string halfWav = rta::platform::join(tmpDir, "rtahealth_u10_half.wav");
        check(write_wav44(halfWav, tone16), "写出待截断 WAV 夹具", halfWav);
        check(truncate_half(halfWav), "resize_file 把 WAV 截到 ~50%",
              std::to_string((unsigned long long)fsx::file_size(P(halfWav), ec)) + " B");
        {
            const TrackHealth h = analyze_file(halfWav);
            const std::string js = track_health_json(h);
            printf("  wav half : status=%s dur=%.3f err=%s\n", h.status.c_str(), h.durationSec,
                   h.error.substr(0, 70).c_str());
            check(h.status == "error", "截断 WAV 是**解码错误**（read_wav 拒绝越界 data 块），不是 ready",
                  h.status + " / " + h.error.substr(0, 90));
            check(!jhas(js, "\"incomplete\":true"), "截断 WAV 绝不被降级成 incomplete（真错误 ≠ 没下载完）");
        }

        // 13c MP3：10 s 同内容 → ffmpeg 编码 → 截 50% ⟹ 旧实现 ready + 半长（真正的假象）
        // MP3 夹具要 ffmpeg 编码器（仓库自带 build-mac/ffmpeg-lite）；取不到就明确 SKIP，不谎报通过。
        std::string ffmpegBin;
        auto runnable = [](const std::string& p) {
            if (p.empty()) return false;
            return std::system((std::string("\"") + p + "\" -version >/dev/null 2>&1").c_str()) == 0;
        };
        if (runnable("ffmpeg")) ffmpegBin = "ffmpeg";
        if (ffmpegBin.empty() && runnable(rta::audio::find_tool("ffmpeg")))
            ffmpegBin = rta::audio::find_tool("ffmpeg");
        if (ffmpegBin.empty()) {
            for (const char* rel : { "build-mac/ffmpeg-lite/ffmpeg", "ffmpeg-lite/ffmpeg" }) {
                const std::string p = fsx::current_path().string() + "/" + rel;
                if (runnable(p)) { ffmpegBin = p; break; }
            }
        }
        const std::string fullMp3 = rta::platform::join(tmpDir, "rtahealth_u10_10s.mp3");
        const std::string halfMp3 = rta::platform::join(tmpDir, "rtahealth_u10_half.mp3");
        if (ffmpegBin.empty()) {
            printf("  [SKIP] ffmpeg 不可执行 ⟹ 半截 MP3 判据跳过（WAV/DSF 判据仍已执行）\n");
        } else {
            const std::string cmd = "\"" + ffmpegBin + "\" -v error -y -i \"" + fullWav +
                                    "\" -ar 44100 -ac 2 -c:a libmp3lame -b:a 192k \"" + halfMp3 + "\"";
            check(std::system(cmd.c_str()) == 0, "ffmpeg 用同一份 10 s 内容编码 MP3 夹具（44.1 k / 192 kbps）",
                  ffmpegBin);
            check(fsx::copy_file(P(halfMp3), P(fullMp3), fsx::copy_options::overwrite_existing, ec) && !ec,
                  "复制一份完整 MP3 作负向对照");
            check(truncate_half(halfMp3), "把 MP3 截到 ~50%",
                  std::to_string((unsigned long long)fsx::file_size(P(halfMp3), ec)) + " B");
            {
                const TrackHealth h = analyze_file(fullMp3);
                const std::string js = track_health_json(h);
                const rta::net::Json p = json_at(js);
                printf("  mp3 full : status=%s dur=%.3f declared=%.3f\n", h.status.c_str(), h.durationSec,
                       jnum(p, "declared_sec"));
                check(h.status == "ready", "完整 MP3 status = ready（负向对照）", h.status);
                check(jhas(js, "\"incomplete\":false"), "完整 MP3 JSON incomplete=false");
                check(std::fabs(jnum(p, "declared_sec") - h.durationSec) <= 0.02,
                      "完整 MP3 declared_sec ≈ 实际时长（±0.02）", std::to_string(jnum(p, "declared_sec")));
                check(jstr(p, "note").empty(), "完整 MP3 note 为空串");
            }
            {
                const TrackHealth h = analyze_file(halfMp3);
                const std::string js = track_health_json(h);
                const rta::net::Json p = json_at(js);
                const double decl = jnum(p, "declared_sec");
                printf("  mp3 half : status=%s dur=%.3f declared=%.3f\n", h.status.c_str(), h.durationSec, decl);
                check(h.status == "incomplete", "红：半截 MP3 status = incomplete（旧实现为 ready）", h.status);
                check(jhas(js, "\"incomplete\":true"), "红：半截 MP3 JSON incomplete=true", js.substr(0, 200));
                check(std::fabs(decl - 10.0) <= 0.01, "红：declared_sec ≈ 10.0 ±0.01（容器头声明）",
                      "declared_sec = " + std::to_string(decl));
                check(std::fabs(h.durationSec - 5.0) <= 0.05, "实际解码 ≈ 5.0 s（只有半截字节）",
                      "duration_sec = " + std::to_string(h.durationSec));
                char durTxt[32] = {0};
                std::snprintf(durTxt, sizeof(durTxt), "%.3f", jnum(p, "duration_sec"));
                const std::string note = jstr(p, "note");
                check(note.find("10.000") != std::string::npos && note.find(durTxt) != std::string::npos &&
                          note.find("文件可能不完整") != std::string::npos,
                      "红：note 同时给出声明值与实际值（后端人话原样）", note);
                // 结构体字段直接钉住（JSON 只证明序列化；这里证明判据落在 TrackHealth 上）
                check(h.incomplete, "红：TrackHealth.incomplete = true（结构体字段）");
                check(std::fabs(h.declaredSec - 10.0) <= 0.01, "红：TrackHealth.declaredSec ≈ 10.0",
                      std::to_string(h.declaredSec));
                check(h.note.find("文件可能不完整") != std::string::npos,
                      "红：TrackHealth.note 是有内容的中文人话", h.note);
                check(h.errorCode == "analysis.incomplete", "红：errorCode = analysis.incomplete（稳定码）",
                      h.errorCode);
                check(h.error.empty(), "incomplete 不是 error：error 字段保持空串", h.error);
                // 整段路径必须给同一份结论（两条路径各调一次 apply_completeness）
                const TrackHealth hw = analyze_file_whole(halfMp3);
                check(hw.status == "incomplete" && same_bits(hw.declaredSec, h.declaredSec) &&
                          hw.incomplete == h.incomplete && hw.note == h.note,
                      "红：整段 vs 流式对同一半截 MP3 的完整性结论逐字一致",
                      hw.status + " / " + std::to_string(hw.declaredSec));
            }
        }

        // 13d 合成 DSF 截半：整段路径抓到（判据的第二个容器）
        const std::string fullDsf = rta::platform::join(tmpDir, "rtahealth_u10_full.dsf");
        const std::string halfDsf = rta::platform::join(tmpDir, "rtahealth_u10_half.dsf");
        // 必须是够长的素材：判据有 1 s 容差下限，1 s 的 DSF 截半只差 0.5 s ⟹ 会被当噪声放过。
        check(write_test_dsf(fullDsf, 2, 2822400u, 2822400ull * 4), "写出合成 DSF（4 s / 立体声 / DSD64）",
              fullDsf);
        check(fsx::copy_file(P(fullDsf), P(halfDsf), fsx::copy_options::overwrite_existing, ec) && !ec,
              "复制一份待截断 DSF");
        check(truncate_half(halfDsf), "把 DSF 截到 ~50%");
        {
            const TrackHealth h = analyze_file_whole(halfDsf);
            const std::string js = track_health_json(h);
            const rta::net::Json p = json_at(js);
            printf("  dsf half (whole): status=%s dur=%.3f declared=%.3f\n", h.status.c_str(), h.durationSec,
                   jnum(p, "declared_sec"));
            check(h.status == "incomplete", "红：半截 DSF（整段路径）status = incomplete（旧实现为 ready）", h.status);
            check(std::fabs(jnum(p, "declared_sec") - 4.0) <= 0.01, "半截 DSF declared_sec ≈ 4.0 s",
                  std::to_string(jnum(p, "declared_sec")));
            check(h.durationSec > 1.80 && h.durationSec < 2.20, "半截 DSF 实际解码约一半（只覆盖已存在字节）",
                  std::to_string(h.durationSec));
            // ⚠️ 未解决项（如实打印，不假装已修）：流式 DSD 源按 fmt.sampleCount 把缺失块补成静音，
            //    于是 analyze_file 报满长 ⟹ declared≈实际，判据在这条路径上看不出差别。
            //    修它要动解码路径（本包范围外，与「不动 DSP/解码路径」的纪律冲突）。
            const TrackHealth sHalf = analyze_file(halfDsf);
            printf("  dsf half (stream): status=%s dur=%.3f（⚠️ 流式 DSD 源补静音，判据在此路径无效）\n",
                   sHalf.status.c_str(), sHalf.durationSec);
            const TrackHealth fullDsfH = analyze_file(fullDsf);
            const std::string jsF = track_health_json(fullDsfH);
            const rta::net::Json pF = json_at(jsF);
            check(fullDsfH.status == "ready", "完整 DSF status = ready（负向对照）", fullDsfH.status);
            check(jhas(jsF, "\"incomplete\":false"), "完整 DSF JSON incomplete=false");
            check(std::fabs(jnum(pF, "declared_sec") - fullDsfH.durationSec) <= 0.02,
                  "完整 DSF declared_sec ≈ 实际时长（±0.02）", std::to_string(jnum(pF, "declared_sec")));
        }

        // 13e 伪文件（纯文本冒充 WAV）：探针必须拒绝 ⟹ 不做任何判定
        const std::string fakeWav = rta::platform::join(tmpDir, "rtahealth_u10_fake.wav");
        {
            std::vector<unsigned char> junk(4096, 'Z');
            write_raw_bytes(fakeWav, junk);
            DeclaredDuration dFake;
            check(!probe_declared_duration(fakeWav, &dFake), "伪文件 probe 返回 false（unknown ⟹ 不判）");
            check(dFake.seconds <= 0.0 && dFake.how.empty(),
                  "伪文件 DeclaredDuration 为空（不是猜出来的 0 s）");
            const std::string jFake = track_health_json(analyze_file(fakeWav));
            check(!jhas(jFake, "\"incomplete\":true"), "伪文件绝不判 incomplete");
        }

        fsx::remove(P(halfWav), ec);
        fsx::remove(P(fullWav), ec);
        fsx::remove(P(fakeWav), ec);
        if (!ffmpegBin.empty()) { fsx::remove(P(fullMp3), ec); fsx::remove(P(halfMp3), ec); }
        fsx::remove(P(halfDsf), ec);
        fsx::remove(P(fullDsf), ec);
        check(!fsx::exists(P(halfWav)) && !fsx::exists(P(fullWav)) && !fsx::exists(P(fakeWav)) &&
                  !fsx::exists(P(halfDsf)) && !fsx::exists(P(fullDsf)),
              "§13 临时文件已清理");
    }

    // ---------------- §14 容器声明时长探针：四个合法头 + 四个坏头（宁可漏报） ----------------
    printf("\n=== 14. probe_declared_duration：四个容器逐项 + 坏头一律 unknown ===\n");
    {
        const std::string dir = rta::platform::join(tmpDir, "rtahealth_u10_probe_");
        std::error_code ec;
        fsx::create_directories(P(dir), ec);
        check(!ec && fsx::is_directory(P(dir), ec), "探针夹具目录创建成功", dir);
        auto probe_sec = [](const std::string& path, double* sec, std::string* how) {
            DeclaredDuration d;
            if (!probe_declared_duration(path, &d)) return false;
            *sec = d.seconds;
            *how = d.how;
            return true;
        };
        // 14a 四个合法头：声明时长必须读得对（锚点值 = 上游 tests/test_health_completeness.cpp）
        {
            const std::string f = rta::platform::join(dir, "probe.flac");
            write_raw_bytes(f, flac_hdr(44100, 2, 16, 1413239));
            double s = 0; std::string how;
            check(probe_sec(f, &s, &how) && std::fabs(s - 32.0462) < 0.001,
                  "FLAC STREAMINFO total_samples 1413239 @44100 = 32.046 s", how);
        }
        {
            const std::string w = rta::platform::join(dir, "probe.wav");
            write_raw_bytes(w, wav_hdr(176400, 10485760u));
            double s = 0; std::string how;
            check(probe_sec(w, &s, &how) && std::fabs(s - 59.4435) < 0.001,
                  "WAV data 10485760 B / byteRate 176400 = 59.443 s", how);
        }
        {
            const std::string m = rta::platform::join(dir, "probe.mp3");
            write_raw_bytes(m, mp3_xing_hdr(4098u, -1, 0));
            double s = 0; std::string how;
            check(probe_sec(m, &s, &how) && std::fabs(s - (4098.0 * 1152) / 44100.0) < 0.001,
                  "MP3 Xing 4098 帧 ×1152 @44100 = 107.050 s", how);
            const std::string m2 = rta::platform::join(dir, "probe_lame.mp3");
            write_raw_bytes(m2, mp3_xing_hdr(4098u, 576, 1000));
            double s2 = 0; std::string how2;
            check(probe_sec(m2, &s2, &how2) && std::fabs(s2 - (4098.0 * 1152 - 1576) / 44100.0) < 0.001,
                  "MP3 Xing 扣掉 LAME delay/padding（与 ffmpeg 的裁切口径一致）", how2);
        }
        {
            const std::string ds = rta::platform::join(dir, "probe.dsf");
            write_raw_bytes(ds, dsf_hdr(2822400u, 1083768832ull));
            double s = 0; std::string how;
            check(probe_sec(ds, &s, &how) && std::fabs(s - 383.9884) < 0.001,
                  "DSF fmt.sampleCount 1083768832 @2822400 = 383.988 s", how);
        }
        // 14b 四个坏头：一律返回 false（宁可漏报，不许误报）
        {
            const std::string f0 = rta::platform::join(dir, "stream.flac");
            write_raw_bytes(f0, flac_hdr(44100, 2, 16, 0));      // total_samples=0 = 流式编码
            double s = 0; std::string how;
            check(!probe_sec(f0, &s, &how), "FLAC total_samples=0 → unknown（不判）", how);
        }
        {
            const std::string wf = rta::platform::join(dir, "rf64.wav");
            write_raw_bytes(wf, wav_hdr(176400, 0xFFFFFFFFu));    // RF64/流式占位
            double s = 0; std::string how;
            check(!probe_sec(wf, &s, &how), "WAV dataSize=0xFFFFFFFF → unknown（不猜）", how);
        }
        {
            std::vector<unsigned char> v;
            v.push_back(0xFF); v.push_back(0xFB); v.push_back(0x90); v.push_back(0x00);
            v.resize(4 + 32 + 512, 0);                            // 有帧、无 Xing/VBRI
            const std::string cbr = rta::platform::join(dir, "cbr.mp3");
            write_raw_bytes(cbr, v);
            double s = 0; std::string how;
            check(!probe_sec(cbr, &s, &how), "MP3 无 Xing/VBRI → unknown（不做 CBR 估算）", how);
        }
        {
            const std::string df = rta::platform::join(dir, "datafirst.wav");
            write_raw_bytes(df, wav_hdr(176400, 10485760u, /*dataFirst=*/true));
            double s = 0; std::string how;
            check(!probe_sec(df, &s, &how), "WAV data 在 fmt 之前 → unknown（没有 byteRate 就不判）", how);
        }
        {
            const std::string none = rta::platform::join(dir, "no-such-file.flac");
            DeclaredDuration d;
            check(!probe_declared_duration(none, &d), "不存在的文件 → unknown（不抛异常）");
        }
        fsx::remove_all(P(dir), ec);
        check(!fsx::exists(P(dir)), "§14 临时目录已清理");
    }

    printf("\n%s (失败项 %d)\n", fails == 0 ? "全部通过" : "存在失败", fails);
    return fails == 0 ? 0 : 1;
}