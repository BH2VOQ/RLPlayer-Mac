// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_ffmpeg_matrix.cpp — 精简版 ffmpeg/ffprobe 的音频格式矩阵门禁（P1：裁剪 ffmpeg）
//
// 为什么需要这个测试（铁律 3：能证明「要证明的事」）：
//   P1 把内置 ffmpeg 从 gyan full（212+211.8 MB）换成自建精简版（12+11.8 MB）。
//   体积变小本身没有意义 —— 必须证明【产品自己的解码路径】对每一种音频格式仍然
//   给出有效结果（rate/channels/frames/电平），且封面、标签写回(remux)这些依赖
//   ffmpeg 的功能没被裁掉。所以：
//     * 解码断言走 rta::audio::read_any()（不是直接跑 ffmpeg CLI）——这才是产品路径；
//     * 样本由【被测的那份精简版】现场合成（−60 dBFS，**绝不发声**：本测试不打开任何音频设备）；
//     * 「用的是精简版」不是靠 PATH 碰运气：父进程把精简版 ffmpeg/ffprobe 与
//       测试自身复制到临时目录，再在该目录起子进程 —— find_tool() 先看 exe 同目录，
//       所以子进程必定用精简版（子进程打印实际解析到的路径，父进程【断言】它落在临时目录里）。
//
// 2026-10-25 修复的「伪通过」盲点（本次改动的全部理由）：
//   ① 旧版父进程硬编码 self + "\\ffmpeg-lite" / "ffmpeg.exe"，在 macOS 上永远命中不了，
//      于是**永远走 SKIP 并 return 0** —— 一条判据都没执行，却报告"通过"。这是最坏的一种
//      假绿：门禁看起来在守，实际什么都没守。现在：目录/工具不存在 → FAIL（返回非零）。
//   ② 旧版用 PATH 上的系统 ffmpeg 合成样本（本机 /usr/local/bin/ffmpeg 是坏链，退出码 134），
//      于是合成阶段整体失败、后面全部 SKIP。现在：**基带 PCM 由 C++ 直接写 RIFF**，
//      再交给精简版自己的编码器转成各格式 —— 不依赖系统 ffmpeg、不依赖 lavfi 设备。
//   ③ 旧版封面用 `-f lavfi -i color=...` 造图；精简版没有 lavfi 输入设备。现在：直接
//      写入一份 2x2 PNG 字节夹具，作为 attached_pic 输入（仍走 ffmpeg 的 png 解码 +
//      容器 picture 写入，产品 get_cover 的链路一样被真实覆盖）。
//   ④ 旧版失败分支普遍是 skip()，掩盖真实缺件。现在：只有【产品确实没有编码器、
//      无法现场合成源】的格式才 UNCOVERED（并打印原因），其余一律 FAIL。
//
// ⚠️ 未覆盖（铁律 4，如实标注）：
//   * ape / mpc7 / mpc8 / tak / shorten / dst 等**无法现场合成**：ffmpeg 只有它们的
//     解码器、没有编码器。这些格式在本测试里只断言「解码器存在」（严格比对白名单），
//     没有真实样本解码断言。白名单见 tools/ffmpeg_lite_required.txt（与出包守卫共用）。
//   * wma / tta / wavpack(.wv)：精简版没有 wmav2/tta/wavpack **编码器**，源文件造不出来。
//     - .wma：asf muxer 存在，remux 用 flac 源验证「容器可写 + writeback 命令形态可用」，
//            并单独断言 wma 家族解码器在白名单里（编解码覆盖来自白名单，不是本用例）。
//     - .tta / .wv：连容器都写不出可解码的东西（wv muxer 只接受 wavpack 编码），
//            标 UNCOVERED；它们的覆盖由「解码器白名单」+「muxer 存在」两条断言承担。
//   * DSF/DFF 样本由本测试自己按 DSF/DSDIFF 规范合成（ffmpeg 无 DSD 编码器），
//     所以它们验证的是「容器 + 1-bit 流」的读取，不是某个真实录音母带的特征。
//
// 用法：test_ffmpeg_matrix            父进程：准备环境 + 合成样本 + 起子进程
//       test_ffmpeg_matrix --child DIR 子进程：在 DIR 里跑全部断言
//
// 环境变量：RTA_FFMPEG_LITE_DIR 覆盖精简版目录（默认 <exe 目录>/ffmpeg-lite）。
//          设置了就必须可用，否则 FAIL —— 不允许"配错了就静默跳过"。
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#ifndef _SILENCE_CXX20_U8PATH_DEPRECATION_WARNING
#define _SILENCE_CXX20_U8PATH_DEPRECATION_WARNING
#endif
#include "test_compat_posix.h"   // POSIX 垫片：MAX_PATH/DWORD/GetTempPathW/GetModuleFileNameW/SearchPathW
#include "audio/audio_loader.h"
#include "audio/media_info.h"
#include "meta/writeback.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <algorithm>

#ifdef _WIN32
extern "C" __declspec(dllimport) int __stdcall SetConsoleOutputCP(unsigned int);
#else
#include <unistd.h>          // ::access —— 判"这个文件真的可执行"，不是"存在"
#endif
#ifndef CP_UTF8
#define CP_UTF8 65001
#endif

namespace fs = std::filesystem;
using rta::audio::AudioBuffer;

namespace {

constexpr double kPi = 3.14159265358979323846;

// 工具名后缀：macOS 单平台无后缀；Windows 分支保留（项目已 mac 单平台，
// 但保留它不影响任何判据，且删掉会让"以后想编 Windows"变成不可能）。
#ifdef _WIN32
constexpr const char* kExeSuffix = ".exe";
#else
constexpr const char* kExeSuffix = "";
#endif

int g_fail = 0;
int g_pass = 0;

void ok(const std::string& what)   { ++g_pass; std::printf("[PASS] %s\n", what.c_str()); }
void bad(const std::string& what)  { ++g_fail; std::printf("[FAIL] %s\n", what.c_str()); }
void info(const std::string& what) { std::printf("[INFO] %s\n", what.c_str()); }
// 只用于「产品确实没有对应编码器、源文件物理上造不出来」的情形，并且必须打印原因。
void uncovered(const std::string& what) { std::printf("[UNCOVERED] %s\n", what.c_str()); }

// ---------------- 路径（一律 POSIX '/'，mac 单平台；Windows 也接受 '/'）----------------
std::string j(const std::string& dir, const std::string& leaf) {
    if (dir.empty()) return leaf;
    if (leaf.empty()) return dir;
    if (dir.back() == '/' || dir.back() == '\\') return dir + leaf;
    return dir + "/" + leaf;
}

std::string exe_path() {
    wchar_t p[MAX_PATH] = {0};
    const DWORD n = GetModuleFileNameW(nullptr, p, MAX_PATH);
    if (n == 0) return "";
    return rta::audio::wide_to_utf8(std::wstring(p, n));
}

std::string exe_dir() {
    const std::string p = exe_path();
    if (p.empty()) return "";
    return rta::platform::to_utf8(fs::u8path(p).parent_path());
}

std::string base_name(const std::string& p) {
    return rta::platform::to_utf8(fs::u8path(p).filename());
}

// 真的可执行吗？"文件存在"不够 —— 精简版被截断/无 +x 位时存在性检查会放它过去，
// 后面每条断言都变成"ffmpeg 起不来"，反而看不出根因。
bool is_runnable(const std::string& p) {
    std::error_code ec;
    if (!fs::is_regular_file(fs::u8path(p), ec) || ec) return false;
#ifdef _WIN32
    return true;
#else
    return ::access(p.c_str(), X_OK) == 0;
#endif
}

bool exists(const std::string& p) {
    std::error_code ec;
    return fs::exists(fs::u8path(p), ec) && !ec;
}

// 归一化绝对路径：macOS 上 /var 是 /private/var 的符号链接，而 find_tool 走的
// module_dir_utf8() 内部有 realpath()。不归一化的话「子进程用的是临时目录里的副本」
// 这条判据会因为 /var vs /private/var 而假红（第一版就踩到了）。
std::string canon(const std::string& p) {
    std::error_code ec;
    const fs::path c = fs::weakly_canonical(fs::u8path(p), ec);
    if (ec) return p;
    return rta::platform::to_utf8(c);
}

long long fsize(const std::string& p) {
    std::error_code ec;
    const auto s = fs::file_size(fs::u8path(p), ec);
    return ec ? -1 : (long long)s;
}

// ---------------- 命令执行（统一走 run_hidden，POSIX/Windows 同签名）----------------
std::wstring wq(const std::string& s) { return L"\"" + rta::audio::widen(s) + L"\""; }

int run(const std::wstring& cmd, std::string* out = nullptr) {
    std::string buf;
    return rta::audio::run_hidden(cmd, out ? out : &buf);
}

// 失败信息要能读：把 ffmpeg 的多行输出压成一行（保留原因，不刷屏）
std::string one_line(const std::string& s, size_t cap = 240) {
    std::string o;
    for (char c : s) {
        if (c == '\r' || c == '\n') { if (!o.empty() && o.back() != ' ') o.push_back(' '); }
        else o.push_back(c);
    }
    while (!o.empty() && o.back() == ' ') o.pop_back();
    if (o.size() > cap) o = o.substr(0, cap) + "...";
    return o;
}

// ---------------- 能力清单解析（decoders / encoders / muxers 共用一个解析器）----------------
// 三张表的格式一致：<flags> <name> <description>，例如
//   " A....D aac                  AAC (Advanced Audio Coding)"      (decoders)
//   "  E  asf             ASF (Advanced / Active Streaming Format)" (muxers)
// 图例行（" A..... = Audio"、" D.. = Demuxing supported"）的 name 位是 "="，必须滤掉。
// kind：'A' = 音频编解码器行，'E' = 可封装(mux)行。
std::vector<std::string> tool_names(const std::string& tool, const char* flag, char kind) {
    std::string out;
    if (run(wq(tool) + L" -hide_banner " + rta::audio::widen(flag), &out) != 0) return {};
    std::vector<std::string> names;
    size_t i = 0;
    while (i < out.size()) {
        size_t e = out.find('\n', i);
        if (e == std::string::npos) e = out.size();
        const std::string line = out.substr(i, e - i);
        i = e + 1;
        // 切出前两个 token：flags 与 name
        std::vector<std::string> tok;
        size_t p = 0;
        while (p < line.size() && tok.size() < 3) {
            while (p < line.size() && (line[p] == ' ' || line[p] == '\t')) ++p;
            if (p >= line.size()) break;
            const size_t s = p;
            while (p < line.size() && line[p] != ' ' && line[p] != '\t') ++p;
            tok.push_back(line.substr(s, p - s));
        }
        if (tok.size() < 2) continue;
        const std::string& flags = tok[0];
        if (flags.find(kind) == std::string::npos) continue;
        // flags 必须全由标志字符组成（否则这行不是能力表条目）
        if (flags.find_first_not_of(".ABCDEFGHIJKLMNOPQRSTUVWXYZ") != std::string::npos) continue;
        const std::string& nm = tok[1];
        const bool name_like = !nm.empty() &&
            nm.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_.") == std::string::npos;
        if (name_like) names.push_back(nm);
    }
    std::sort(names.begin(), names.end());
    names.erase(std::unique(names.begin(), names.end()), names.end());
    return names;
}

bool has(const std::vector<std::string>& v, const std::string& x) {
    return std::binary_search(v.begin(), v.end(), x);
}

// ---------------- 白名单 ----------------
std::vector<std::string> read_required_list() {
    std::vector<std::string> out;
#ifdef RTA_SOURCE_DIR
    const std::string p = std::string(RTA_SOURCE_DIR) + "/tools/ffmpeg_lite_required.txt";
    std::ifstream f(fs::u8path(p));
    std::string line;
    while (std::getline(f, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        out.push_back(line);
    }
#else
    (void)0;
#endif
    return out;
}

// ---------------- 音频度量 ----------------
double peak(const AudioBuffer& b) {
    double m = 0.0;
    for (size_t i = 0; i < b.frames(); ++i)
        for (int c = 0; c < b.channels; ++c) m = std::max(m, std::fabs(b.sample(i, c)));
    return m;
}

double rms(const AudioBuffer& b) {
    double acc = 0.0;
    const size_t n = b.frames();
    if (n == 0) return 0.0;
    for (size_t i = 0; i < n; ++i)
        for (int c = 0; c < b.channels; ++c) { const double v = b.sample(i, c); acc += v * v; }
    return std::sqrt(acc / (double)(n * (size_t)b.channels));
}

std::string dbfs(double x) {
    char buf[64];
    if (x <= 0.0) { std::snprintf(buf, sizeof buf, "-inf dBFS"); return buf; }
    std::snprintf(buf, sizeof buf, "%.1f dBFS", 20.0 * std::log10(x));
    return buf;
}

// ---------------- 字节写入小工具 ----------------
void put_le16(std::vector<uint8_t>& v, uint16_t x) { v.push_back((uint8_t)x); v.push_back((uint8_t)(x >> 8)); }
void put_le32(std::vector<uint8_t>& v, uint32_t x) { for (int i = 0; i < 4; ++i) v.push_back((uint8_t)(x >> (8 * i))); }
void put_le64(std::vector<uint8_t>& v, uint64_t x) { for (int i = 0; i < 8; ++i) v.push_back((uint8_t)(x >> (8 * i))); }
void put_be16(std::vector<uint8_t>& v, uint16_t x) { v.push_back((uint8_t)(x >> 8)); v.push_back((uint8_t)x); }
void put_be32(std::vector<uint8_t>& v, uint32_t x) { for (int i = 3; i >= 0; --i) v.push_back((uint8_t)(x >> (8 * i))); }
void put_be64(std::vector<uint8_t>& v, uint64_t x) { for (int i = 7; i >= 0; --i) v.push_back((uint8_t)(x >> (8 * i))); }
void put_tag(std::vector<uint8_t>& v, const char* t) { for (int i = 0; i < 4; ++i) v.push_back((uint8_t)t[i]); }

bool write_file(const std::string& path, const std::vector<uint8_t>& v) {
    std::ofstream f(fs::u8path(path), std::ios::binary);
    if (!f) return false;
    f.write((const char*)v.data(), (std::streamsize)v.size());
    return (bool)f;
}

// ---------------- 基带 PCM：C++ 直接写 RIFF，不依赖 ffmpeg / lavfi ----------------
// 为什么自己写：旧版用 `-f lavfi -i aevalsrc=...` 造基带，而精简版【没有 lavfi 输入设备】，
// 加上本机系统 ffmpeg 是坏链（134），合成阶段必然失败 → 后面全部 SKIP。
// 自己写 RIFF 是零依赖的，且能保证"电平/频率/位深"这三个被断言的东西完全可控。
// 电平 −60 dBFS（amp=0.001）—— 铁律 1：任何测试音都不许听得见，而且本测试不打开设备。
bool write_riff_wav(const std::string& path, uint32_t rate, int ch, double seconds, double amp) {
    if (ch < 1 || ch > 8) return false;
    const size_t n = (size_t)((double)rate * seconds);
    const uint32_t blockAlign = (uint32_t)(ch * 3);            // 24-bit
    std::vector<uint8_t> data;
    data.reserve(n * blockAlign);
    for (size_t i = 0; i < n; ++i) {
        const double v = amp * std::sin(2.0 * kPi * 1000.0 * (double)i / (double)rate);
        long x = (long)std::lround(v * 8388607.0);
        if (x > 8388607L) x = 8388607L;
        if (x < -8388608L) x = -8388608L;
        const uint32_t u = (uint32_t)x & 0xFFFFFFu;
        for (int c = 0; c < ch; ++c) {
            data.push_back((uint8_t)(u & 0xFF));
            data.push_back((uint8_t)((u >> 8) & 0xFF));
            data.push_back((uint8_t)((u >> 16) & 0xFF));
        }
    }
    std::vector<uint8_t> f;
    put_tag(f, "RIFF"); put_le32(f, (uint32_t)(36 + data.size())); put_tag(f, "WAVE");
    put_tag(f, "fmt "); put_le32(f, 16);
    put_le16(f, 1);                                    // PCM
    put_le16(f, (uint16_t)ch);
    put_le32(f, rate);
    put_le32(f, rate * blockAlign);                     // byte rate
    put_le16(f, (uint16_t)blockAlign);
    put_le16(f, 24);                                    // bits
    put_tag(f, "data"); put_le32(f, (uint32_t)data.size());
    f.insert(f.end(), data.begin(), data.end());
    return write_file(path, f);
}

// ---------------- 封面夹具：2x2 红色 PNG（73 字节，硬编码）----------------
// 为什么不用 lavfi color：精简版没有 lavfi。为什么不用 ffmpeg 编码 PNG：
// 产品 get_cover 走的是 `-map 0:v:0 -c:v copy -f image2`（拷贝，不转码），
// 所以夹具只需要是"容器里能存、ffmpeg 能 demux 出来"的合法 PNG 字节。
std::vector<uint8_t> png_2x2() {
    static const uint8_t p[] = {
        0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A, 0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
        0x00,0x00,0x00,0x02,0x00,0x00,0x00,0x02,0x08,0x02,0x00,0x00,0x00,0xFD,0xD4,0x9A,0x73,
        0x00,0x00,0x00,0x10,0x49,0x44,0x41,0x54,0x78,0x9C,0x63,0xF8,0xCF,0xC0,0x00,0x44,0x0C,
        0x10,0x0A,0x00,0x1F,0xEE,0x03,0xFD,0x8B,0x5F,0x14,0xD4,0x00,0x00,0x00,0x00,0x49,0x45,
        0x4E,0x44,0xAE,0x42,0x60,0x82
    };
    return std::vector<uint8_t>(p, p + sizeof(p));
}

// ---------------- DSD 现场合成 ----------------
// 二阶 sigma-delta 把 −60 dBFS 1 kHz 正弦变成 1-bit 流。
// 位序：内部按 MSB-first 打包；DSF 文件是 LSB-first，所以写文件前按字节反位。
std::vector<std::vector<uint8_t>> make_dsd(int64_t bitsPerCh, int ch, uint32_t rate, double amp) {
    std::vector<std::vector<uint8_t>> out((size_t)ch, std::vector<uint8_t>((size_t)((bitsPerCh + 7) / 8), 0));
    for (int c = 0; c < ch; ++c) {
        double i1 = 0.0, i2 = 0.0, y = 1.0;
        for (int64_t n = 0; n < bitsPerCh; ++n) {
            const double in = amp * std::sin(2.0 * kPi * 1000.0 * (double)n / (double)rate +
                                             (c == 0 ? 0.0 : 0.35));
            y = (i2 >= 0.0) ? 1.0 : -1.0;
            i1 += in - y;
            i2 += i1 - y;
            if (i1 > 4.0) i1 = 4.0; if (i1 < -4.0) i1 = -4.0;   // 防积分器发散
            if (i2 > 4.0) i2 = 4.0; if (i2 < -4.0) i2 = -4.0;
            if (y > 0.0) out[(size_t)c][(size_t)(n >> 3)] |= (uint8_t)(1u << (7 - (n & 7)));
        }
    }
    return out;
}

uint8_t reverse_bits(uint8_t b) {
    b = (uint8_t)(((b & 0xF0) >> 4) | ((b & 0x0F) << 4));
    b = (uint8_t)(((b & 0xCC) >> 2) | ((b & 0x33) << 2));
    b = (uint8_t)(((b & 0xAA) >> 1) | ((b & 0x55) << 1));
    return b;
}

// DSF：28 字节头 + fmt(52) + data；每声道按 blockSize 分块交错（末块补齐整块）。
bool write_dsf(const std::string& path, uint32_t rate, int ch, double seconds, double amp) {
    const int64_t bits = (int64_t)((double)rate * seconds);
    auto data = make_dsd(bits, ch, rate, amp);
    const uint32_t blockSize = 4096;
    const uint64_t needBytes = (uint64_t)((bits + 7) / 8);
    const uint64_t blocks = (needBytes + blockSize - 1) / blockSize;
    std::vector<uint8_t> body;
    for (uint64_t b = 0; b < blocks; ++b)
        for (int c = 0; c < ch; ++c)
            for (uint32_t i = 0; i < blockSize; ++i) {
                const uint64_t idx = b * blockSize + i;
                uint8_t byte = (idx < needBytes) ? data[(size_t)c][(size_t)idx] : 0;
                body.push_back(reverse_bits(byte));       // 文件内 LSB-first
            }
    std::vector<uint8_t> f;
    put_tag(f, "DSD ");
    put_le64(f, 28);
    put_le64(f, 0);                                        // 文件总长（读者不校验，稍后回填）
    put_le64(f, 0);                                        // 元数据指针
    put_tag(f, "fmt ");
    put_le64(f, 52);
    put_le32(f, 1);                                        // format version = 1
    put_le32(f, 0);                                        // format id = 0（未压缩 DSD）
    put_le32(f, 2);                                        // channel type = 2（stereo）
    put_le32(f, (uint32_t)ch);
    put_le32(f, rate);
    put_le32(f, 1);                                        // bits per sample
    put_le64(f, (uint64_t)bits);
    put_le32(f, blockSize);
    put_le32(f, 0);                                        // reserved
    put_tag(f, "data");
    put_le64(f, 12 + body.size());
    f.insert(f.end(), body.begin(), body.end());
    const uint64_t total = f.size();
    for (int i = 0; i < 8; ++i) f[(size_t)(12 + i)] = (uint8_t)(total >> (8 * i));
    return write_file(path, f);
}

// DFF(DSDIFF)：FRM8("DSD ") → FVER → PROP(SND: FS/CHNL/CMPR) → DSD(每声道连续)
bool write_dff(const std::string& path, uint32_t rate, int ch, double seconds, double amp) {
    const int64_t bits = (int64_t)((double)rate * seconds);
    auto data = make_dsd(bits, ch, rate, amp);
    const uint64_t perCh = (uint64_t)((bits + 7) / 8);

    std::vector<uint8_t> snd;
    put_tag(snd, "SND ");
    put_tag(snd, "FS  "); put_be64(snd, 4); put_be32(snd, rate);
    // DSDIFF 的 CHNL：声道数是【2 字节】大端（不是 4 字节）——写错会被 ffmpeg 判成
    // "compression is not supported"/Invalid data（2026-10-22 实测踩到）。
    put_tag(snd, "CHNL"); put_be64(snd, 2 + 4 * (uint64_t)ch); put_be16(snd, (uint16_t)ch);
    const char* ids[2] = {"SLFT", "SRGT"};
    for (int c = 0; c < ch; ++c) put_tag(snd, ids[c & 1]);
    put_tag(snd, "CMPR"); put_be64(snd, 4 + 1 + 3); put_tag(snd, "DSD ");
    snd.push_back(14); snd.push_back(0); snd.push_back(0); snd.push_back(0);   // 名称长度 + "not compressed"

    std::vector<uint8_t> body;
    put_tag(body, "FVER"); put_be64(body, 4); put_be32(body, 0x01050000u);
    put_tag(body, "PROP"); put_be64(body, snd.size()); body.insert(body.end(), snd.begin(), snd.end());
    if (snd.size() & 1) body.push_back(0);
    put_tag(body, "DSD "); put_be64(body, perCh * (uint64_t)ch);
    for (int c = 0; c < ch; ++c) body.insert(body.end(), data[(size_t)c].begin(), data[(size_t)c].end());
    if (body.size() & 1) body.push_back(0);

    std::vector<uint8_t> f;
    put_tag(f, "FRM8"); put_be64(f, 4 + body.size()); put_tag(f, "DSD ");
    f.insert(f.end(), body.begin(), body.end());
    return write_file(path, f);
}

// ---------------- 覆盖清单（父进程写、子进程读；单一事实来源，避免两边口径漂移）----------------
std::string uncovered_path(const std::string& dir) { return j(dir, "uncovered.txt"); }

void write_uncovered(const std::string& dir, const std::vector<std::string>& labels) {
    std::ofstream f(fs::u8path(uncovered_path(dir)));
    for (const auto& l : labels) f << l << "\n";
}

std::vector<std::string> read_uncovered(const std::string& dir) {
    std::vector<std::string> out;
    std::ifstream f(fs::u8path(uncovered_path(dir)));
    std::string line;
    while (std::getline(f, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
        if (!line.empty()) out.push_back(line);
    }
    return out;
}

bool in_list(const std::vector<std::string>& v, const std::string& x) {
    return std::find(v.begin(), v.end(), x) != v.end();
}

// =====================================================================================
// 子进程：全部断言
// =====================================================================================
struct Case { const char* label; const char* file; };

int child_main(const std::string& dir) {
    const std::string ffmpeg = rta::audio::find_tool("ffmpeg");
    const std::string ffprobe = rta::audio::find_tool("ffprobe");
    info("find_tool(ffmpeg)  = " + (ffmpeg.empty() ? "<未找到>" : ffmpeg));
    info("find_tool(ffprobe) = " + (ffprobe.empty() ? "<未找到>" : ffprobe));
    info("临时目录 = " + dir);
    if (ffmpeg.empty() || ffprobe.empty()) {
        bad("找不到 ffmpeg/ffprobe（子进程应运行在含精简版的目录里）");
        return 1;
    }
    // 判据 1 的另一半：子进程真的用了【临时目录里那份】，不是系统 PATH 上的。
    // 两边都归一化（/var ↔ /private/var）再比，否则这条判据会被符号链接假红。
    const std::string want = canon(dir) + "/";
    const std::string gotF = canon(ffmpeg), gotP = canon(ffprobe);
    if (gotF.rfind(want, 0) != 0) bad("ffmpeg 不在临时目录里（" + gotF + "）——测的不是被测物");
    else ok("ffmpeg 解析到临时目录里的副本（" + base_name(ffmpeg) + "）");
    if (gotP.rfind(want, 0) != 0) bad("ffprobe 不在临时目录里（" + gotP + "）");

    const std::vector<std::string> unc = read_uncovered(dir);

    // --- 1. 解码器白名单（与出包守卫共用同一份列表） ---
    {
        const auto req = read_required_list();
        const auto have = tool_names(ffmpeg, "-decoders", 'A');
        if (req.empty()) {
            bad("读不到 tools/ffmpeg_lite_required.txt（RTA_SOURCE_DIR 未定义？）");
        } else if (have.empty()) {
            bad("ffmpeg -decoders 没有输出（精简版不可执行？）");
        } else {
            std::vector<std::string> miss;
            for (const auto& n : req)
                if (!has(have, n)) miss.push_back(n);
            if (miss.empty()) {
                ok("解码器白名单 " + std::to_string(req.size()) + " 项齐全（精简版共 " +
                   std::to_string(have.size()) + " 个音频解码器）");
            } else {
                std::string s;
                for (const auto& m : miss) s += m + " ";
                bad("精简版缺必需解码器：" + s);
            }
        }
    }

    // --- 1b. 写回 muxer 白名单：writeback.h 承诺的每个扩展名都必须能真的封装 ---
    // 这一条是"产品承诺 vs 构建产物"的直接对账，缺一个就是缺件（不许靠删断言转绿）。
    {
        const auto muxers = tool_names(ffmpeg, "-muxers", 'E');
        const char* exts[] = {".flac", ".mp3", ".ogg", ".opus", ".m4a", ".wma", ".wav", ".wv"};
        std::vector<std::string> miss;
        std::string detail;
        for (const char* ext : exts) {
            const char* m = rta::meta::writeback_muxer(ext);
            if (!m) { miss.push_back(std::string(ext) + "（writeback_muxer 返回 null）"); continue; }
            if (!has(muxers, m)) miss.push_back(std::string(ext) + "→" + m);
            else detail += std::string(ext) + "→" + m + " ";
        }
        if (miss.empty())
            ok("写回 muxer 8 项齐全：" + detail);
        else {
            std::string s;
            for (const auto& m : miss) s += m + " ";
            bad("精简版缺写回 muxer：" + s);
        }
    }

    // --- 2. 格式矩阵：走产品自己的 read_any ---
    const std::vector<Case> cases = {
        {"flac",    "m.flac"}, {"mp3", "m.mp3"}, {"aac(m4a)", "m_aac.m4a"},
        {"alac(m4a)", "m_alac.m4a"}, {"ogg-vorbis", "m.ogg"}, {"opus", "m.opus"},
        {"wav",     "m.wav"},  {"wma",  "m.wma"}, {"tta", "m.tta"},
        {"wavpack", "m.wv"},   {"dsf",  "m.dsf"}, {"dff", "m.dff"},
    };
    // 判据 2 要求这 7 类必须真的生成并走 read_any（这是产品的核心格式承诺）
    const std::vector<std::string> core = {"wav", "flac", "mp3", "aac(m4a)", "alac(m4a)", "ogg-vorbis", "opus"};
    int core_ok = 0;
    for (const auto& c : cases) {
        const std::string path = j(dir, c.file);
        if (!exists(path)) {
            // 缺失分两种：产品没有编码器（父进程已登记 UNCOVERED）/ 本该有却没有（真缺件）
            if (in_list(unc, c.label)) uncovered(std::string(c.label) + "：无对应编码器，源文件无法现场合成");
            else bad(std::string(c.label) + "：样本应当存在却缺失（" + path + "）——合成阶段有真缺件");
            continue;
        }
        rta::audio::LoadNote note;
        try {
            const AudioBuffer b = rta::audio::read_any(path, &note);
            const size_t frames = b.frames();
            const double pk = peak(b);
            const double rmsV = rms(b);
            char detail[640];
            std::snprintf(detail, sizeof detail,
                          "%s: rate=%u ch=%d bits=%d frames=%zu rms=%.5f (%s) peak=%.4f (%s) note=%s",
                          c.label, b.rate, b.channels, b.bits, frames, rmsV, dbfs(rmsV).c_str(),
                          pk, dbfs(pk).c_str(),
                          note.text.empty() ? "-" : note.text.c_str());
            const bool frames_ok = frames > (size_t)(b.rate / 10);          // 至少 0.1 s
            // −60 dBFS 正弦的 RMS = 7.07e-4。留 ±10 dB 余量容纳有损编码与 DSD 噪声整形；
            // 下界防"解出全 0"，上界防"解出噪声/错位数据"。DSD 的 out-of-band 噪声
            // 主要抬高峰值，所以判据用 RMS（峰值只打印，不判定）。
            const bool level_ok = rmsV > 2e-4 && rmsV < 4e-3;
            if (b.rate >= 8000 && b.channels >= 1 && b.channels <= 8 && frames_ok && level_ok) {
                ok(detail);
                if (in_list(core, c.label)) ++core_ok;
            } else {
                bad(std::string(detail) + (frames_ok ? "" : " [帧数太少]") + (level_ok ? "" : " [电平异常]"));
            }
        } catch (const std::exception& e) {
            bad(std::string(c.label) + "：read_any 抛异常：" + e.what());
        }
    }
    if (core_ok >= 7)
        ok("核心 7 类音频全部实际解码通过（" + std::to_string(core_ok) + "/7）");
    else
        bad("核心 7 类只通过 " + std::to_string(core_ok) + "/7（WAV/FLAC/MP3/M4A-AAC/M4A-ALAC/OGG/Opus 必须全覆盖）");

    // --- 2b. DSD 回退路径：read_any 对 .dsf/.dff 先走原生读取，读不了才回退 ffmpeg。
    //     所以这里直接用精简版 ffmpeg 解一次，证明"回退解码器"也在包里（不是白列） ---
    for (const char* f : {"m.dsf", "m.dff"}) {
        const std::string src = j(dir, f);
        if (!exists(src)) { uncovered(std::string("DSD 回退解码 ") + f + "：样本缺失（本地合成失败）"); continue; }
        const std::string out = j(dir, "dsdfallback.wav");
        std::string log;
        const int rc = run(wq(ffmpeg) + L" -hide_banner -v error -y -i " + wq(src) +
                           L" -vn -c:a pcm_s24le -f wav " + wq(out), &log);
        if (rc == 0 && fsize(out) > 1000) ok(std::string("精简版 ffmpeg 回退解码 ") + f);
        else bad(std::string("精简版 ffmpeg 回退解码 ") + f + "：rc=" + std::to_string(rc) + " " + one_line(log, 160));
    }

    // --- 3. 标签写回（remux，-c copy）用到的 8 个 muxer ---
    // 源的选择要如实：.wma/.wv 没有编码器造不出真源。
    //   * .wma：用 flac 源走 asf 容器（验证"容器可写 + writeback 命令形态"），打印源差异；
    //   * .wv ：wv muxer 只接受 wavpack 编码，没有 wavpack 编码器 ⇒ 物理上造不出来 → UNCOVERED。
    {
        struct Remux { const char* ext; const char* muxer; const char* src; const char* note; };
        const Remux rm[] = {
            {".flac", "flac", "m.flac", nullptr}, {".mp3", "mp3", "m.mp3", nullptr},
            {".ogg",  "ogg",  "m.ogg",  nullptr}, {".opus", "opus", "m.opus", nullptr},
            {".m4a",  "ipod", "m_aac.m4a", nullptr}, {".wav", "wav", "m.wav", nullptr},
            {".wma",  "asf",  "m.wma",  "（无 wmav2 编码器，源用 flac；asf 容器/命令形态仍被验证）"},
            {".wv",   "wv",   "m.wv",   nullptr},
        };
        for (const auto& r : rm) {
            std::string src = j(dir, r.src);
            // .wma 源缺失时退到 flac 源（容器可写性仍能验），其余源缺失就是真缺件
            if (!exists(src) && std::string(r.ext) == ".wma" && exists(j(dir, "m.flac")))
                src = j(dir, "m.flac");
            if (!exists(src)) {
                if (std::string(r.ext) == ".wv")
                    uncovered("remux -f wv：无 wavpack 编码器 ⇒ 造不出 .wv 源（muxer/解码器存在性已由 1b 断言）");
                else
                    bad(std::string("remux ") + r.muxer + "：源样本缺失（" + r.src + "）");
                continue;
            }
            const std::string dst = j(dir, std::string("rm") + r.ext + ".rtatmp");
            const bool vorbis = rta::meta::writeback_vorbis_family(r.ext);
            std::vector<rta::meta::WbField> kvs;
            kvs.push_back(rta::meta::WbField{"title", vorbis ? "TITLE" : "title",
                                             std::string("matrix-") + r.muxer});
            std::string err;
            const bool good = rta::meta::writeback_remux(ffmpeg, src, dst, r.muxer,
                                                         std::string(r.ext) == ".mp3", kvs, err) &&
                              fsize(dst) > 100;
            if (good)
                ok(std::string("remux -f ") + r.muxer + "（writeback 用）" + (r.note ? r.note : ""));
            else
                bad(std::string("remux -f ") + r.muxer + "：" + (err.empty() ? "产物过小/失败" : err));
        }
        // 顺带用 ffprobe 读回一个 remux 产物，证明标签真的写进去了
        const std::string probeFile = j(dir, "rm.flac.rtatmp");
        if (exists(probeFile)) {
            std::string out;
            const int rc = run(wq(ffprobe) + L" -v error -show_entries format_tags=TITLE "
                              L"-of default=nw=1:nk=1 " + wq(probeFile), &out);
            if (rc == 0 && out.find("matrix-flac") != std::string::npos)
                ok("ffprobe 读回 remux 后的标签（TITLE=matrix-flac）");
            else
                bad("ffprobe 读不回 remux 后的标签（rc=" + std::to_string(rc) + "）：" + one_line(out, 120));
        } else {
            bad("remux 产物缺失，无法验证标签写回（rm.flac.rtatmp）");
        }
    }

    // --- 3b. PCM 逐字节门禁（writeback.h 的核心判据：remux 前后解码必须完全一致） ---
    {
        struct Pr { const char* src; const char* dst; };
        const Pr pr[] = {
            {"m.flac", "rm.flac.rtatmp"}, {"m.mp3", "rm.mp3.rtatmp"},
            {"m.ogg",  "rm.ogg.rtatmp"},  {"m.opus", "rm.opus.rtatmp"},
            {"m_aac.m4a", "rm.m4a.rtatmp"}, {"m.wav", "rm.wav.rtatmp"},
        };
        for (const auto& c : pr) {
            const std::string a = j(dir, c.src);
            const std::string b = j(dir, c.dst);
            if (!exists(a) || !exists(b)) {
                bad(std::string("PCM 门禁 ") + c.src + "：样本或 remux 产物缺失（a=" +
                    std::to_string(exists(a)) + " b=" + std::to_string(exists(b)) + "）");
                continue;
            }
            const std::string wa = j(dir, "pcm_a.wav");
            const std::string wb = j(dir, "pcm_b.wav");
            const std::wstring base = L" -v error -y -i ";
            const std::wstring tail = L" -map 0:a:0 -vn -map_metadata -1 -f wav -c:a pcm_s32le ";
            const int ra = run(wq(ffmpeg) + base + wq(a) + tail + wq(wa));
            const int rb = run(wq(ffmpeg) + base + wq(b) + tail + wq(wb));
            if (ra != 0 || rb != 0) {
                bad(std::string("PCM 门禁 ") + c.src + "：解码失败 ra=" + std::to_string(ra) +
                    " rb=" + std::to_string(rb));
                continue;
            }
            std::ifstream fa(fs::u8path(wa), std::ios::binary), fb(fs::u8path(wb), std::ios::binary);
            const std::vector<char> ba((std::istreambuf_iterator<char>(fa)), std::istreambuf_iterator<char>());
            const std::vector<char> bb((std::istreambuf_iterator<char>(fb)), std::istreambuf_iterator<char>());
            if (!ba.empty() && ba == bb)
                ok(std::string("PCM 门禁 ") + c.src + " 逐字节一致（" + std::to_string(ba.size()) + " 字节）");
            else
                bad(std::string("PCM 门禁 ") + c.src + " 不一致（" + std::to_string(ba.size()) + " vs " +
                    std::to_string(bb.size()) + " 字节）");
        }
    }

    // --- 3c. probe_media（media_info.h）：时长/码率等靠精简版 ffprobe ---
    {
        const std::string f = j(dir, "m.flac");
        if (!exists(f)) {
            bad("probe_media：m.flac 缺失（FLAC 是核心格式，不允许缺）");
        } else {
            const rta::audio::MediaInfo mi = rta::audio::probe_media(f);
            const bool okAll = mi.sampleRate == 48000 && mi.channels == 1 &&
                               mi.codec == "flac" && mi.bits == 24 &&
                               std::fabs((double)mi.duration - 0.6) < 0.1;
            char d[256];
            std::snprintf(d, sizeof d, "probe_media(flac): codec=%s rate=%d ch=%d bits=%d duration=%.3fs",
                          mi.codec.c_str(), mi.sampleRate, mi.channels, mi.bits, mi.duration);
            if (okAll) ok(d); else bad(d);
        }
    }

    // --- 4. 内嵌封面（media_info.h 的 get_cover：ffmpeg 取出 attached_pic 原始字节） ---
    // 产品实现在 2026-10-23 已改成 `-c:v copy`（不转码），因此这里断言的是
    // 「容器里的图片字节能被完整取回」——缺 png/mjpeg 解码或 image2 封装都会让它 RED。
    {
        const std::string withCover = j(dir, "m_cover.flac");
        if (!exists(withCover)) {
            bad("内嵌封面：样本 m_cover.flac 未生成（封面链是产品功能，缺件必须 RED）");
        } else {
            std::string mime;
            const auto bytes = rta::audio::get_cover(withCover, mime);
            const auto want = png_2x2();
            const bool isPng = bytes.size() > 64 && bytes[0] == 0x89 && bytes[1] == 'P' &&
                               bytes[2] == 'N' && bytes[3] == 'G';
            // 更强的判据：必须与嵌入时的字节完全一致（copy 模式下不该有任何重编码）
            const bool same = bytes == want;
            if (isPng && same)
                ok("内嵌封面取回 PNG 且字节与夹具一致（" + std::to_string(bytes.size()) + " 字节）");
            else if (isPng)
                bad("内嵌封面是 PNG 但字节被改动（" + std::to_string(bytes.size()) + " vs 夹具 " +
                    std::to_string(want.size()) + " 字节，mime=" + mime + "）");
            else
                bad("内嵌封面解码失败（" + std::to_string(bytes.size()) + " 字节, mime=" + mime + "）");
        }
    }

    // --- 5. ffprobe 位深探测（read_via_ffmpeg 用它决定 pcm_s16/24/32） ---
    {
        const std::string p = j(dir, "m.flac");
        if (!exists(p)) {
            bad("probe_bit_depth：m.flac 缺失");
        } else {
            const int bits = rta::audio::probe_bit_depth(ffprobe, p);
            if (bits == 24) ok("probe_bit_depth(flac) = 24（与源位深一致，未降位）");
            else bad("probe_bit_depth(flac) 返回 " + std::to_string(bits) + "，期望 24");
        }
    }

    std::printf("[SUMMARY] pass=%d fail=%d\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

// =====================================================================================
// 父进程：准备环境 + 合成样本 + 起子进程
// =====================================================================================
bool has_encoder(const std::vector<std::string>& encs, const char* name) {
    return has(encs, std::string(name));
}

} // namespace

int main(int argc, char** argv) {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    if (argc >= 3 && std::string(argv[1]) == "--child") {
        return child_main(std::string(argv[2]));
    }

    std::printf("=== 精简版 ffmpeg 音频格式矩阵 ===\n");

    const std::string selfPath = exe_path();
    const std::string selfDir = exe_dir();
    if (selfPath.empty() || selfDir.empty()) {
        std::printf("[FAIL] 取不到自身可执行文件路径（GetModuleFileNameW 失败）\n");
        return 1;
    }

    // ---- 精简版目录：环境变量优先，其次 <exe 目录>/ffmpeg-lite ----
    // 这里【绝不】再走 SKIP：配错/没编出来就是缺件，必须让门禁红（铁律 6）。
    std::string liteDir;
    const bool envOverride = (std::getenv("RTA_FFMPEG_LITE_DIR") != nullptr &&
                              *std::getenv("RTA_FFMPEG_LITE_DIR") != '\0');
    if (envOverride) liteDir = std::getenv("RTA_FFMPEG_LITE_DIR");
    else liteDir = j(selfDir, "ffmpeg-lite");

    const std::string liteFfmpeg  = j(liteDir, std::string("ffmpeg") + kExeSuffix);
    const std::string liteFfprobe = j(liteDir, std::string("ffprobe") + kExeSuffix);
    info(std::string("精简版目录 = ") + liteDir + (envOverride ? "（来自 RTA_FFMPEG_LITE_DIR）" : ""));
    if (!exists(liteDir)) {
        std::printf("[FAIL] 精简版目录不存在：%s\n", liteDir.c_str());
        std::printf("       先跑 tools/build_ffmpeg_lite_mac.sh；或用 RTA_FFMPEG_LITE_DIR 指定。\n");
        return 1;
    }
    if (!is_runnable(liteFfmpeg) || !is_runnable(liteFfprobe)) {
        std::printf("[FAIL] 精简版工具缺失或不可执行：%s / %s\n", liteFfmpeg.c_str(), liteFfprobe.c_str());
        return 1;
    }

    // ---- 临时目录 ----
    std::string tmpRoot = rta::platform::temp_dir_utf8();
    if (tmpRoot.empty()) { std::printf("[FAIL] 取不到临时目录\n"); return 1; }
    const std::string dir = j(tmpRoot, "rta_ffmatrix_" + std::to_string((long long)GetCurrentProcessId()));
    std::error_code ec;
    fs::remove_all(fs::u8path(dir), ec);
    fs::create_directories(fs::u8path(dir), ec);
    if (!exists(dir)) { std::printf("[FAIL] 建不出临时目录：%s\n", dir.c_str()); return 1; }
    info("临时目录 = " + dir);

    // ---- 把精简版 + 测试自身复制进来：子进程的 find_tool 会命中同目录的精简版 ----
    bool copyOk = true;
    for (const std::string& src : {liteFfmpeg, liteFfprobe}) {
        const std::string dst = j(dir, base_name(src));
        std::error_code e2;
        fs::copy_file(fs::u8path(src), fs::u8path(dst), fs::copy_options::overwrite_existing, e2);
        if (e2 || !exists(dst)) { copyOk = false; std::printf("[FAIL] 复制失败：%s → %s\n", src.c_str(), dst.c_str()); }
    }
    const std::string childExe = j(dir, base_name(selfPath));
    {
        std::error_code e2;
        fs::copy_file(fs::u8path(selfPath), fs::u8path(childExe), fs::copy_options::overwrite_existing, e2);
        if (e2 || !exists(childExe)) { copyOk = false; std::printf("[FAIL] 复制测试自身失败：%s\n", selfPath.c_str()); }
    }
    if (!copyOk) return 1;
    // 复制过来的测试自身必须也可执行（cp 保留模式位，但要真的验一遍）
    if (!is_runnable(childExe)) { std::printf("[FAIL] 临时目录里的测试副本不可执行：%s\n", childExe.c_str()); return 1; }

    // ---- 合成样本：全部由【被测的那份精简版】自己做，不碰系统 ffmpeg ----
    const std::string gen = j(dir, base_name(liteFfmpeg));
    info("样本合成器 = " + gen + "（= 被测的精简版，不用 PATH 上的系统 ffmpeg）");

    // 基带 PCM：C++ 直接写 RIFF（mono 给 FLAC/AAC/ALAC/MP3/WAV；stereo 给 vorbis，其编码器只支持 2 声道）
    const std::string baseMono   = j(dir, "base_mono.wav");
    const std::string baseStereo = j(dir, "base_stereo.wav");
    if (!write_riff_wav(baseMono, 48000, 1, 0.6, 0.001) ||
        !write_riff_wav(baseStereo, 48000, 2, 0.6, 0.001)) {
        std::printf("[FAIL] 写基带 WAV 失败（%s）\n", baseMono.c_str());
        return 1;
    }
    info("基带 WAV = " + std::to_string(fsize(baseMono)) + " / " + std::to_string(fsize(baseStereo)) +
         " 字节（−60 dBFS / 1 kHz / 48k / 24-bit，mono / stereo）");

    const std::vector<std::string> encoders = tool_names(gen, "-encoders", 'A');
    if (encoders.empty()) {
        std::printf("[FAIL] 精简版 ffmpeg -encoders 没有输出（不可执行？）\n");
        return 1;
    }

    struct Enc { const char* label; const char* out; const char* enc; const char* args; bool stereo; };
    // args 里的 -strict -2 是必须的：vorbis/opus 在 ffmpeg 里标了 experimental(X)，
    // 不加 -strict -2 会以 "Experimental feature" 失败 —— 这不是测试放宽，而是调用方式。
    const Enc encs[] = {
        {"flac",      "m.flac",     "flac",       "",                      false},
        {"mp3",       "m.mp3",      "libmp3lame", "-b:a 192k",             false},
        {"aac(m4a)",  "m_aac.m4a",  "aac",        "-b:a 192k",             false},
        {"alac(m4a)", "m_alac.m4a", "alac",       "",                      false},
        {"ogg-vorbis","m.ogg",      "vorbis",     "-strict -2 -q:a 5",     true},
        {"opus",      "m.opus",     "opus",       "-strict -2 -b:a 128k",  false},
        {"wav",       "m.wav",      "pcm_s24le",  "",                      false},
        {"wma",       "m.wma",      "wmav2",      "-b:a 192k",             false},
        {"tta",       "m.tta",      "tta",        "",                      false},
        {"wavpack",   "m.wv",       "wavpack",    "",                      false},
    };
    std::vector<std::string> unc;
    int genFail = 0;
    for (const auto& e : encs) {
        if (!has_encoder(encoders, e.enc)) {
            unc.push_back(e.label);
            std::printf("[UNCOVERED] %s：精简版无 %s 编码器，源文件无法现场合成\n", e.label, e.enc);
            continue;
        }
        const std::string src = e.stereo ? baseStereo : baseMono;
        const std::string dst = j(dir, e.out);
        std::string log;
        const int rc = run(wq(gen) + L" -hide_banner -v error -y -i " + wq(src) +
                           L" -c:a " + rta::audio::widen(e.enc) +
                           (e.args && *e.args ? (L" " + rta::audio::widen(e.args)) : L"") +
                           L" " + wq(dst), &log);
        if (rc != 0 || fsize(dst) < 200) {
            ++genFail;
            std::printf("[FAIL] 合成 %s 失败：rc=%d size=%lld %s\n", e.label, rc, fsize(dst),
                        one_line(log, 200).c_str());
        } else {
            info("合成 " + std::string(e.label) + " = " + std::to_string(fsize(dst)) + " 字节");
        }
    }

    // DSD：ffmpeg 没有 DSD 编码器 → 自己合成（见文件头 ⚠️）
    if (!write_dsf(j(dir, "m.dsf"), 2822400, 2, 0.5, 0.001)) { unc.push_back("dsf"); std::printf("[UNCOVERED] dsf：本地合成失败\n"); }
    if (!write_dff(j(dir, "m.dff"), 2822400, 2, 0.5, 0.001)) { unc.push_back("dff"); std::printf("[UNCOVERED] dff：本地合成失败\n"); }

    // ---- 带内嵌封面的 FLAC：直接嵌入 PNG 字节夹具（不用 lavfi color）----
    // 每个失败分支都必须计数（bad() 里 ++g_fail）。只 printf("[FAIL]") 不计数的话，
    // 封面链坏掉时父进程照样 return 0 —— 那正是本测试要根除的假绿。
    {
        const std::string png = j(dir, "cover_src.png");
        const std::string coverFlac = j(dir, "m_cover.flac");
        if (!write_file(png, png_2x2())) {
            bad("写封面夹具失败：" + png);
        } else {
            const std::string flac = j(dir, "m.flac");
            if (!exists(flac)) {
                bad("无 m.flac，无法生成封面样本（FLAC 是核心格式，不允许缺）");
            } else {
                std::string log;
                const int rc = run(wq(gen) + L" -hide_banner -v error -y -i " + wq(flac) +
                                   L" -i " + wq(png) + L" -map 0:a -map 1:v -c copy "
                                   L"-disposition:v attached_pic " + wq(coverFlac), &log);
                if (rc != 0 || fsize(coverFlac) < 500)
                    bad("内嵌封面样本生成失败：rc=" + std::to_string(rc) + " size=" +
                        std::to_string(fsize(coverFlac)) + " " + one_line(log, 200));
                else
                    info("内嵌封面样本 = " + std::to_string(fsize(coverFlac)) + " 字节");
            }
        }
    }

    // 覆盖清单落盘：子进程据此区分「产品没编码器」与「真缺件」
    write_uncovered(dir, unc);

    std::printf("[UNCOVERED] ape / mpc7 / mpc8 / tak / shorten / dst —— ffmpeg 只有解码器没有编码器，"
                "无法现场合成；它们的覆盖由「解码器白名单」断言（见 tools/ffmpeg_lite_required.txt）\n");

    // ---- 起子进程（在临时目录里，保证 find_tool 命中精简版）----
    const std::wstring childCmd = wq(childExe) + L" --child " + wq(dir);
    std::string childOut;
    const int rc = rta::audio::run_hidden(childCmd, &childOut);
    std::printf("%s", childOut.c_str());
    if (childOut.find("[SUMMARY]") == std::string::npos) {
        std::printf("[FAIL] 子进程没有输出 [SUMMARY]（rc=%d）——很可能没跑起来\n", rc);
        ++g_fail;
    }
    // 判据 1：子进程必须报告它用的是临时目录里的 ffmpeg
    {
        const std::string key = "find_tool(ffmpeg)  = ";
        const size_t p = childOut.find(key);
        if (p == std::string::npos) {
            std::printf("[FAIL] 子进程没有打印 find_tool(ffmpeg)，无法确认用的是哪份二进制\n");
            ++g_fail;
        } else {
            const size_t s = p + key.size();
            const size_t e = childOut.find('\n', s);
            const std::string got = childOut.substr(s, (e == std::string::npos ? childOut.size() : e) - s);
            if (canon(got).rfind(canon(dir) + "/", 0) == 0) {
                std::printf("[PASS] 子进程用的 ffmpeg 就在临时目录里：%s\n", got.c_str());
                ++g_pass;
            } else {
                std::printf("[FAIL] 子进程用的 ffmpeg 不是临时目录里的副本：%s\n", got.c_str());
                ++g_fail;
            }
        }
    }
    if (rc != 0) { std::printf("[FAIL] 子进程退出码 %d\n", rc); ++g_fail; }
    if (genFail > 0) { std::printf("[FAIL] 样本合成阶段失败 %d 项（产品缺编码器或调用错误）\n", genFail); ++g_fail; }

    std::printf("[SUMMARY] parent_fail=%d (子进程内已分别统计)\n", g_fail);
    // 失败时保留现场，便于人工复核；全绿才清理
    if (g_fail == 0) {
        std::error_code ec2;
        fs::remove_all(fs::u8path(dir), ec2);
    } else {
        std::printf("[INFO] 保留现场目录供复核：%s\n", dir.c_str());
    }
    return g_fail == 0 ? 0 : 1;
}
