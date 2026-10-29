// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_stream_decode.cpp — 流式读取 ffmpeg 输出（免临时 WAV）单元与集成测试（ROADMAP P6b）
//
// 2026-10-25 macOS 移植（PLATFORM.md §13.12）：本用例原依赖 windows.h，现已改用 POSIX
// 原生实现（pipe + poll + O_NONBLOCK + waitpid）。**判据一条都没删、阈值一处都没放宽**：
//   1. WAV 头解析器：各种 fmt/data 块顺序、奇数 chunk padding、extensible/float、非法头全拒
//   2. 管道读取分块正确性：跨 1/2/3/5/7/13 字节等任意非对齐边界拼装，样本逐位一致
//   3. 与临时路径的逐位一致比较：WAV / FLAC / MP3 / OGG(Opus) / M4A 两条路径 PCM 逐字节相同
//   4. 设置开关：streamdecode=false / 环境变量 RLPLAYER_STREAM_DECODE=0 走旧路径，默认走流式
//   5. 异常退出码与真因透传：不存在文件、损坏文件正确归因，回退策略在 note 中说明
//   6. 延迟与磁盘 I/O 改善实测：流式路径落盘临时 WAV 数为 0
//
// ⚠️ 判据强度修正（铁律 3）：原第 2 条是把 read_wav_stream_pipe 的拼装循环**抄一份**到
// 测试里再喂切片 —— 那只能证明"抄件与原件一致"，证明不了原件本身对。本版改成
// **fork 一个真子进程往真管道里按指定边界写字节**，然后调用**生产函数本体**
// read_wav_stream_pipe 去读。这样跨块拼装、非阻塞、退出后排空（drain）全在真实路径上被验证。
//
// 素材零依赖（本机 ffmpeg-lite 只解码、无 lavfi 设备、无 flac/mp3/opus 编码器）：
//   FLAC / OGG(Opus) / MP3 / WAV —— 全部由本文件用纯 C++ 手写合法字节流生成
//   M4A(AAC) —— 用 macOS 自带的 /usr/bin/afconvert 生成（系统工具，非 ffmpeg）
#include "audio/audio_loader.h"
#include "audio/wav.h"

#include <cstdio>
#include <string>
#include <vector>
#include <filesystem>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <fstream>

#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;

static int g_fail = 0;
static int g_skip = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}
static void skip(const char* what, const std::string& why) {
    std::printf("  [SKIP] %s  %s\n", what, why.c_str());
    ++g_skip;
}

// =========================================================================
// 素材生成（零依赖手写字节流）
// =========================================================================
static void wr32le(std::vector<uint8_t>& v, uint32_t val) {
    v.push_back((uint8_t)(val & 0xFF));
    v.push_back((uint8_t)((val >> 8) & 0xFF));
    v.push_back((uint8_t)((val >> 16) & 0xFF));
    v.push_back((uint8_t)((val >> 24) & 0xFF));
}
static void wr16le(std::vector<uint8_t>& v, uint16_t val) {
    v.push_back((uint8_t)(val & 0xFF));
    v.push_back((uint8_t)((val >> 8) & 0xFF));
}
static bool write_bytes(const std::string& path, const std::vector<uint8_t>& v) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f.write((const char*)v.data(), (std::streamsize)v.size());
    f.close();
    return f.good();
}

// 单帧 FLAC：44.1kHz / 16bit / 立体声 / blocksize=44100 ⟹ 恰好 1.0 秒 44100 帧
// （照抄 tests/test_decode_retry.cpp 的 make_flac()，同一份已验证的手写实现）
static bool make_flac(const std::string& dst) {
    const uint32_t sr = 44100;
    const int ch = 2, bits = 16;
    const uint32_t blocksize = 44100;
    auto crc8 = [](const std::vector<uint8_t>& d) {
        uint8_t c = 0;
        for (uint8_t b : d) { c ^= b; for (int i = 0; i < 8; ++i) c = (c & 0x80) ? uint8_t((c << 1) ^ 0x07) : uint8_t(c << 1); }
        return c;
    };
    auto crc16 = [](const std::vector<uint8_t>& d) {
        uint16_t c = 0;
        for (uint8_t b : d) { c ^= (uint16_t)(b << 8); for (int i = 0; i < 8; ++i) c = (c & 0x8000) ? uint16_t((c << 1) ^ 0x8005) : uint16_t(c << 1); }
        return c;
    };
    std::vector<uint8_t> out = {'f', 'L', 'a', 'C'};
    std::vector<uint8_t> si;
    auto be16 = [&](std::vector<uint8_t>& v, uint16_t x) { v.push_back(uint8_t(x >> 8)); v.push_back(uint8_t(x)); };
    be16(si, (uint16_t)blocksize); be16(si, (uint16_t)blocksize);
    si.insert(si.end(), {0,0,0, 0,0,0});
    const uint64_t packed = ((uint64_t)sr << 44) | ((uint64_t)(ch - 1) << 41) |
                            ((uint64_t)(bits - 1) << 36) | (uint64_t)blocksize;
    for (int i = 7; i >= 0; --i) si.push_back(uint8_t(packed >> (i * 8)));
    si.insert(si.end(), 16, 0);                 // md5 未知
    out.push_back(0x80);                        // last-metadata-block + type=0
    out.push_back(uint8_t(si.size() >> 16)); out.push_back(uint8_t(si.size() >> 8)); out.push_back(uint8_t(si.size()));
    out.insert(out.end(), si.begin(), si.end());
    std::vector<uint8_t> fh = {0xFF, 0xF8, 0b0111'1001, 0b0001'1000, 0x00};  // sr code 9 = 44.1kHz
    be16(fh, (uint16_t)(blocksize - 1));
    fh.push_back(crc8(fh));
    std::vector<uint8_t> frame = fh;
    for (int c = 0; c < ch; ++c) {
        frame.push_back(0x02);                              // VERBATIM 子帧头
        frame.insert(frame.end(), (size_t)blocksize * 2, 0); // 全零样本
    }
    const uint16_t fcrc = crc16(frame);
    out.insert(out.end(), frame.begin(), frame.end());
    out.push_back(uint8_t(fcrc >> 8));
    out.push_back(uint8_t(fcrc));
    return write_bytes(dst, out);
}

// 16-bit PCM WAV（1 秒 440Hz 方波-ish，确定性，两条路径必须解出同样的字节）
static bool make_wav(const std::string& dst, uint32_t sr = 44100, int ch = 2, int bits = 16,
                     uint32_t seconds = 1, bool noise = false) {
    const uint32_t n = sr * seconds;
    const int bytesPer = bits / 8;
    std::vector<uint8_t> pcm;
    pcm.reserve((size_t)n * ch * bytesPer);
    for (uint32_t i = 0; i < n; ++i) {
        int amp;
        if (noise) {
            // 伪随机噪声（xorshift 确定性）：AAC 压不动它，产物大小随秒数线性增长。
            // 需要 seek 的容器用例必须用它 —— 三角波太可压，8 秒 AAC 只有 ~50KB，
            // 整个文件落进 ffmpeg 的 64KB 探测缓冲，管道上根本不需要 seek（实测踩到）。
            static uint32_t x = 0x2545F491u;
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            amp = (int)(x % 40001u) - 20000;
        } else {
            // 确定性三角波，避开任何浮点库差异
            const int period = (int)(sr / 440);
            int phase = (int)(i % (uint32_t)period);
            amp = (phase < period / 2) ? (phase * 20000 / (period / 2))
                                       : ((period - phase) * 20000 / (period / 2));
        }
        for (int c = 0; c < ch; ++c) {
            int32_t v;
            if (noise) {
                // ★ 每个声道用**各自独立**的噪声。若两声道互为反相（v 与 -v），
                //   AAC 的 MS 立体声编码能把它们完美相消，产物又被压回 64KB 以下
                //   —— 实测踩过：8 秒反相噪声 m4a 仍只有 ~50KB，管道照样能整段缓冲。
                static uint32_t y[8] = {0x9E3779B9u, 0x85EBCA6Bu, 0xC2B2AE35u, 0x27D4EB2Fu,
                                        0x165667B1u, 0xD3A2646Cu, 0xFD7046C5u, 0xB55A4F09u};
                uint32_t& r = y[c % 8];
                r ^= r << 13; r ^= r >> 17; r ^= r << 5;
                v = (int32_t)(r % 40001u) - 20000;
            } else {
                v = (c == 0) ? amp : -amp;
            }
            if (bits == 16) wr16le(pcm, (uint16_t)(int16_t)v);
            else if (bits == 24) { pcm.push_back((uint8_t)(v & 0xFF)); pcm.push_back((uint8_t)((v >> 8) & 0xFF)); pcm.push_back((uint8_t)((v >> 16) & 0xFF)); }
            else wr32le(pcm, (uint32_t)v);
        }
    }
    std::vector<uint8_t> o;
    o.insert(o.end(), {'R','I','F','F'});
    wr32le(o, 36 + (uint32_t)pcm.size());
    o.insert(o.end(), {'W','A','V','E'});
    o.insert(o.end(), {'f','m','t',' '});
    wr32le(o, 16);
    wr16le(o, 1);
    wr16le(o, (uint16_t)ch);
    wr32le(o, sr);
    wr32le(o, sr * (uint32_t)ch * (uint32_t)bytesPer);
    wr16le(o, (uint16_t)(ch * bytesPer));
    wr16le(o, (uint16_t)bits);
    o.insert(o.end(), {'d','a','t','a'});
    wr32le(o, (uint32_t)pcm.size());
    o.insert(o.end(), pcm.begin(), pcm.end());
    return write_bytes(dst, o);
}

// MP3：40 个 MPEG1 Layer3 帧（128kbps / 44.1kHz / stereo，无 CRC）。
// 帧体全零 = 静音帧，但**帧头合法**，ffmpeg 会正常解出 PCM 帧 —— 两条路径解出的
// 字节仍然必须完全一致，判据强度不受影响（比较的是两条路径，不是与"原音"比）。
static bool make_mp3(const std::string& dst) {
    const size_t frameLen = 417;                  // 144*128000/44100 向上取整
    std::vector<uint8_t> out;
    for (int i = 0; i < 40; ++i) {
        std::vector<uint8_t> fr = {0xFF, 0xFB, 0x90, 0x64};
        fr.resize(frameLen, 0);
        out.insert(out.end(), fr.begin(), fr.end());
    }
    return write_bytes(dst, out);
}

// Ogg Opus：1 个 BOS 页(OpusHead) + 1 个 OpusTags 页 + 20 个音频页。
// 每页 CRC32 按 Ogg 规范（多项式 0x04C11DB7，不反射，初值 0）重算并写回 22..25 字节。
static uint32_t ogg_crc32(const std::vector<uint8_t>& d) {
    uint32_t crc = 0;
    for (uint8_t b : d) {
        crc ^= ((uint32_t)b << 24);
        for (int i = 0; i < 8; ++i)
            crc = (crc & 0x80000000u) ? ((crc << 1) ^ 0x04C11DB7u) : (crc << 1);
    }
    return crc;
}
static void append_le32(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back((uint8_t)(x & 0xFF)); v.push_back((uint8_t)((x >> 8) & 0xFF));
    v.push_back((uint8_t)((x >> 16) & 0xFF)); v.push_back((uint8_t)((x >> 24) & 0xFF));
}
static std::vector<uint8_t> ogg_page(uint32_t serial, uint32_t seq, int64_t granule,
                                     const std::vector<std::vector<uint8_t>>& packets, uint8_t htype) {
    std::vector<uint8_t> segs, body;
    for (const auto& p : packets) {
        size_t n = p.size();
        while (n >= 255) { segs.push_back(255); n -= 255; }
        segs.push_back((uint8_t)n);
        body.insert(body.end(), p.begin(), p.end());
    }
    std::vector<uint8_t> hdr = {'O','g','g','S', 0, htype};
    for (int i = 0; i < 8; ++i) hdr.push_back((uint8_t)((uint64_t)granule >> (i * 8)));   // granule 小端
    append_le32(hdr, serial);
    append_le32(hdr, seq);
    append_le32(hdr, 0);                                     // CRC 占位
    hdr.push_back((uint8_t)segs.size());
    hdr.insert(hdr.end(), segs.begin(), segs.end());
    std::vector<uint8_t> full = hdr;
    full.insert(full.end(), body.begin(), body.end());
    const uint32_t crc = ogg_crc32(full);
    full[22] = (uint8_t)(crc & 0xFF); full[23] = (uint8_t)((crc >> 8) & 0xFF);
    full[24] = (uint8_t)((crc >> 16) & 0xFF); full[25] = (uint8_t)((crc >> 24) & 0xFF);
    return full;
}
static bool make_opus_ogg(const std::string& dst) {
    const uint32_t serial = 0x12345678u;
    std::vector<uint8_t> out;
    // OpusHead: magic(8) ver(1) ch(1) preskip(2) rate(4) gain(2) mapping(1)
    std::vector<uint8_t> head = {'O','p','u','s','H','e','a','d', 1, 2};
    head.push_back(0x38); head.push_back(0x01);              // preskip = 312
    head.push_back(0x80); head.push_back(0xBB); head.push_back(0x00); head.push_back(0x00);  // 48000
    head.push_back(0x00); head.push_back(0x00);              // gain
    head.push_back(0x00);                                    // mapping family 0
    std::vector<uint8_t> tags = {'O','p','u','s','T','a','g','s'};
    append_le32(tags, 4); tags.insert(tags.end(), {'t','e','s','t'});
    append_le32(tags, 0);

    auto p0 = ogg_page(serial, 0, 0, {head}, 0x02);          // BOS
    out.insert(out.end(), p0.begin(), p0.end());
    auto p1 = ogg_page(serial, 1, 0, {tags}, 0x00);
    out.insert(out.end(), p1.begin(), p1.end());
    for (int i = 0; i < 20; ++i) {
        std::vector<uint8_t> pkt = {0xFC, 0xFF, 0xFE};       // CELT fullband 20ms stereo
        auto pg = ogg_page(serial, (uint32_t)(2 + i), (int64_t)960 * (i + 1), {pkt},
                           (i == 19) ? 0x04 : 0x00);         // 最后一页 EOS
        out.insert(out.end(), pg.begin(), pg.end());
    }
    return write_bytes(dst, out);
}

// M4A(AAC)：用 macOS 自带 afconvert（系统工具，非 ffmpeg）
static bool make_m4a(const std::string& srcWav, const std::string& dst) {
    if (::access("/usr/bin/afconvert", X_OK) != 0) return false;
    const std::string cmd = "/usr/bin/afconvert -f m4af -d aac -b 128000 \"" + srcWav + "\" \"" + dst + "\"";
    return std::system((cmd + " >/dev/null 2>&1").c_str()) == 0;
}

// =========================================================================
// 1. WAV 头解析器单元测试 (parse_wav_header)
// =========================================================================
static void test_wav_header_parser() {
    std::printf("- 1 WAV 头解析器单元测试（各种 fmt/data 块顺序、奇数 chunk padding、异常格式）\n");

    // 1.1 标准 16-bit PCM WAV
    {
        std::vector<uint8_t> h;
        h.insert(h.end(), {'R','I','F','F'});
        wr32le(h, 44 - 8);
        h.insert(h.end(), {'W','A','V','E'});
        h.insert(h.end(), {'f','m','t',' '});
        wr32le(h, 16);
        wr16le(h, 1);     // PCM
        wr16le(h, 2);     // 2 ch
        wr32le(h, 44100); // rate
        wr32le(h, 44100 * 4); // byteRate
        wr16le(h, 4);     // blockAlign
        wr16le(h, 16);    // bits
        h.insert(h.end(), {'d','a','t','a'});
        wr32le(h, 100);   // data size

        rta::audio::WavHeaderInfo info{};
        std::string err;
        int r = rta::audio::parse_wav_header(h.data(), h.size(), info, &err);
        ck(r == 44, "标准 16-bit PCM WAV 头解析成功", "r=" + std::to_string(r) + " err=" + err);
        ck(info.fmtTag == 1 && info.channels == 2 && info.rate == 44100 && info.bits == 16 && !info.isFloat,
           "标准 16-bit 头参数正确 (rate=44100, ch=2, bits=16)");
        ck(info.dataDeclaredBytes == 100 && info.headerBytes == 44, "标准 16-bit 数据起始与长度正确");
    }

    // 1.2 WAVE_FORMAT_EXTENSIBLE (0xFFFE) 24-bit PCM
    {
        std::vector<uint8_t> h;
        h.insert(h.end(), {'R','I','F','F'});
        wr32le(h, 0xFFFFFFFF); // 模拟流式管道输出
        h.insert(h.end(), {'W','A','V','E'});
        h.insert(h.end(), {'f','m','t',' '});
        wr32le(h, 40);         // extensible fmt sz = 40
        wr16le(h, 0xFFFE);     // WAVE_FORMAT_EXTENSIBLE
        wr16le(h, 2);          // 2 ch
        wr32le(h, 96000);      // rate
        wr32le(h, 96000 * 6);  // byteRate
        wr16le(h, 6);          // blockAlign
        wr16le(h, 24);         // bits
        wr16le(h, 22);         // cbSize
        wr16le(h, 24);         // validBits
        wr32le(h, 3);          // channelMask
        wr16le(h, 1);          // subFormat GUID data1 = 1 (PCM)
        h.insert(h.end(), 14, 0); // rest of GUID
        h.insert(h.end(), {'d','a','t','a'});
        wr32le(h, 0xFFFFFFFF); // 流式管道未定长度

        rta::audio::WavHeaderInfo info{};
        std::string err;
        int r = rta::audio::parse_wav_header(h.data(), h.size(), info, &err);
        ck(r == 68, "WAVE_FORMAT_EXTENSIBLE 24-bit 头解析成功", "r=" + std::to_string(r) + " err=" + err);
        ck(info.fmtTag == 1 && info.channels == 2 && info.rate == 96000 && info.bits == 24 && !info.isFloat,
           "EXTENSIBLE subFormat=1 映射为线性 PCM (rate=96000, ch=2, bits=24)");
        ck(info.dataDeclaredBytes == 0xFFFFFFFF, "流式管道 0xFFFFFFFF 长度透传");
    }

    // 1.3 32-bit IEEE float WAV (fmtTag=3)
    {
        std::vector<uint8_t> h;
        h.insert(h.end(), {'R','I','F','F'});
        wr32le(h, 1000);
        h.insert(h.end(), {'W','A','V','E'});
        h.insert(h.end(), {'f','m','t',' '});
        wr32le(h, 16);
        wr16le(h, 3);          // IEEE float
        wr16le(h, 1);          // mono
        wr32le(h, 192000);
        wr32le(h, 192000 * 4);
        wr16le(h, 4);
        wr16le(h, 32);
        h.insert(h.end(), {'d','a','t','a'});
        wr32le(h, 800);

        rta::audio::WavHeaderInfo info{};
        std::string err;
        int r = rta::audio::parse_wav_header(h.data(), h.size(), info, &err);
        ck(r == 44 && info.fmtTag == 3 && info.isFloat && info.bits == 32,
           "32-bit IEEE float 头解析成功 (isFloat=true, bits=32)");
    }

    // 1.4 chunk 乱序与奇数 chunk 大小补齐 padding 测试
    // 构造：RIFF -> JUNK(15字节，奇数需补齐1字节0x00) -> fmt(16字节) -> LIST(8字节) -> data
    {
        std::vector<uint8_t> h;
        h.insert(h.end(), {'R','I','F','F'});
        wr32le(h, 500);
        h.insert(h.end(), {'W','A','V','E'});
        // 奇数 chunk: JUNK (sz = 15)
        h.insert(h.end(), {'J','U','N','K'});
        wr32le(h, 15);
        h.insert(h.end(), 15, 'X');
        h.push_back(0); // RIFF 规范要求的 1 字节对齐 padding！

        // 紧接着 fmt
        h.insert(h.end(), {'f','m','t',' '});
        wr32le(h, 16);
        wr16le(h, 1);
        wr16le(h, 2);
        wr32le(h, 48000);
        wr32le(h, 48000 * 4);
        wr16le(h, 4);
        wr16le(h, 16);

        // LIST chunk (sz = 8)
        h.insert(h.end(), {'L','I','S','T'});
        wr32le(h, 8);
        h.insert(h.end(), 8, 'Y');

        // data chunk
        h.insert(h.end(), {'d','a','t','a'});
        wr32le(h, 0xFFFFFFFF);

        rta::audio::WavHeaderInfo info{};
        std::string err;
        int r = rta::audio::parse_wav_header(h.data(), h.size(), info, &err);
        ck(r > 0 && info.fmtTag == 1 && info.rate == 48000 && info.channels == 2,
           "JUNK前置 + 奇数15字节padding + LIST中置 复合头顺利解析",
           "r=" + std::to_string(r) + " err=" + err);
        ck(r == (int)h.size(), "headerBytes 精确定位到 data 块体开始",
           "expected=" + std::to_string(h.size()) + " got=" + std::to_string(r));
    }

    // 1.5 异常格式拒绝
    {
        rta::audio::WavHeaderInfo info{};
        std::string err;

        // 非 RIFF
        uint8_t badRiff[] = "NOT_A_RIFF_HEADER_AT_ALL_XXXX";
        int r1 = rta::audio::parse_wav_header(badRiff, sizeof(badRiff), info, &err);
        ck(r1 < 0, "非 RIFF 头部被正确拒绝", err);

        // data 在 fmt 之前
        std::vector<uint8_t> noFmt;
        noFmt.insert(noFmt.end(), {'R','I','F','F'});
        wr32le(noFmt, 100);
        noFmt.insert(noFmt.end(), {'W','A','V','E'});
        noFmt.insert(noFmt.end(), {'d','a','t','a'});
        wr32le(noFmt, 10);
        int r2 = rta::audio::parse_wav_header(noFmt.data(), noFmt.size(), info, &err);
        ck(r2 < 0, "缺少 fmt 块即出现 data 块被正确拒绝", err);

        // 不支持的编码 fmtTag = 7 (Mu-law)
        std::vector<uint8_t> mulaw;
        mulaw.insert(mulaw.end(), {'R','I','F','F'});
        wr32le(mulaw, 100);
        mulaw.insert(mulaw.end(), {'W','A','V','E'});
        mulaw.insert(mulaw.end(), {'f','m','t',' '});
        wr32le(mulaw, 16);
        wr16le(mulaw, 7); // mu-law
        wr16le(mulaw, 1);
        wr32le(mulaw, 8000);
        wr32le(mulaw, 8000);
        wr16le(mulaw, 1);
        wr16le(mulaw, 8);
        mulaw.insert(mulaw.end(), {'d','a','t','a'});
        wr32le(mulaw, 10);
        int r3 = rta::audio::parse_wav_header(mulaw.data(), mulaw.size(), info, &err);
        ck(r3 < 0, "非线性 PCM 编码 (fmtTag=7) 被正确拒绝", err);

        // 截断头需要更多数据 (返回 0)
        std::vector<uint8_t> truncH = {'R','I','F','F', 0,0,0,0, 'W','A','V','E'};
        int r4 = rta::audio::parse_wav_header(truncH.data(), truncH.size(), info, &err);
        ck(r4 == 0, "截断的未完成头部返回 0（要求更多数据）");
    }
}

// =========================================================================
// 2. 管道读取分块与跨块样本拼接正确性（驱动生产函数本体，非抄件）
// =========================================================================
// 做法：fork 一个子进程，把 [WAV 头 + PCM] 按 chunkSizes 指定的边界写进真管道，
//       写完 _exit(0)。父进程用 read_wav_stream_pipe 读同一管道。
// 这样一次性验证：真非阻塞读、真跨块拼装、真 EOF、真"子进程退出后排空"。
static bool run_pipe_case(size_t chunkSize, const std::vector<uint8_t>& streamBytes,
                          rta::audio::AudioBuffer& out, std::string& errOut) {
    int fds[2] = {-1, -1};
    if (::pipe(fds) != 0) return false;

    const pid_t child = ::fork();
    if (child < 0) { ::close(fds[0]); ::close(fds[1]); return false; }
    if (child == 0) {
        // ---- 子进程：按 chunkSize 切片写入，模拟 ffmpeg 任意分块输出 ----
        ::close(fds[0]);
        size_t pos = 0;
        while (pos < streamBytes.size()) {
            const size_t n = std::min(chunkSize, streamBytes.size() - pos);
            ssize_t w = 0;
            do { w = ::write(fds[1], streamBytes.data() + pos, n); } while (w < 0 && errno == EINTR);
            if (w <= 0) _exit(1);
            pos += (size_t)w;
            // 小睡 0.2ms：让"父进程比写端快"的时序也覆盖到（纯非阻塞分支）
            ::usleep(200);
        }
        ::close(fds[1]);
        _exit(0);                                // 退出后管道里可能仍有缓冲数据 → 触发 drain
    }

    ::close(fds[1]);
    rta::platform::PipeProcess proc;
    proc.pid = child;
    proc.out_fd = fds[0];
    proc.started = true;
    proc.set_stdout_nonblocking();

    const bool ok = rta::audio::read_wav_stream_pipe(proc.out_fd, proc, out, &errOut);
    if (proc.out_fd >= 0) { ::close(proc.out_fd); proc.out_fd = -1; }
    const int rc = proc.wait();
    return ok && rc == 0;
}

static void test_chunked_pipe_real() {
    std::printf("- 2 真管道分块读取（生产函数本体 × 任意非对齐边界 × 退出后排空）\n");

    // 24-bit 立体声：每帧 6 字节，500 帧 = 3000 字节 PCM。管道缓冲远小于此 ⟹
    // 子进程必然被写阻塞，父进程必须持续读走才能推进 —— 真·流式语义。
    constexpr size_t kFrames = 500;
    const int ch = 2, bits = 24, bytesPer = 3;
    const size_t frameBytes = (size_t)ch * bytesPer;

    std::vector<int32_t> expected;
    std::vector<uint8_t> pcm;
    for (size_t i = 0; i < kFrames; ++i) {
        for (int c = 0; c < ch; ++c) {
            int32_t v = (int32_t)((i * 334455) ^ (uint32_t)(c * 1234567));
            if ((i + (size_t)c) % 2 == 1) v = -v;
            v &= 0x00FFFFFF;
            if (v & 0x800000) v |= (int32_t)0xFF000000;
            expected.push_back(v);
            pcm.push_back((uint8_t)(v & 0xFF));
            pcm.push_back((uint8_t)((v >> 8) & 0xFF));
            pcm.push_back((uint8_t)((v >> 16) & 0xFF));
        }
    }

    // WAV 头 + PCM 组成完整字节流（头里的 data 长度按管道惯例写 0xFFFFFFFF）
    std::vector<uint8_t> stream = {'R','I','F','F'};
    wr32le(stream, 0xFFFFFFFF);
    stream.insert(stream.end(), {'W','A','V','E'});
    stream.insert(stream.end(), {'f','m','t',' '});
    wr32le(stream, 16);
    wr16le(stream, 1);
    wr16le(stream, (uint16_t)ch);
    wr32le(stream, 48000);
    wr32le(stream, 48000 * (uint32_t)frameBytes);
    wr16le(stream, (uint16_t)frameBytes);
    wr16le(stream, (uint16_t)bits);
    stream.insert(stream.end(), {'d','a','t','a'});
    wr32le(stream, 0xFFFFFFFF);
    const size_t hdrBytes = stream.size();
    stream.insert(stream.end(), pcm.begin(), pcm.end());

    // 刁钻边界：1/2/3/5/7/11/13/64/256/1024，以及"刚好跨样本"的 6±1
    const std::vector<size_t> chunkSizes = {1, 2, 3, 5, 6, 7, 11, 13, 64, 256, 1024};

    for (size_t csz : chunkSizes) {
        rta::audio::AudioBuffer ab;
        std::string err;
        const bool ok = run_pipe_case(csz, stream, ab, err);
        bool match = ok && ab.rate == 48000 && ab.channels == ch && ab.bits == bits;
        if (match && ab.raw.size() != expected.size()) match = false;
        if (match) {
            for (size_t i = 0; i < expected.size(); ++i) {
                if (ab.raw[i] != expected[i]) { match = false; break; }
            }
        }
        ck(match, ("块大小 " + std::to_string(csz) + " 字节切片：真管道解出样本逐位完全一致").c_str(),
           "ok=" + std::to_string((int)ok) + " err=" + err +
           " got=" + std::to_string(ab.raw.size()) + " expected=" + std::to_string(expected.size()) +
           " rate=" + std::to_string(ab.rate) + " bits=" + std::to_string(ab.bits));
    }

    // 2.2 超出管道缓冲的压力用例（真·流式语义）。
    // macOS 管道缓冲实测 64KB。上面 3KB 的用例一次就能塞进缓冲，压不到"写端阻塞→
    // 父进程读走→写端继续"这条真实路径。这里造 512KB PCM（≈87 倍缓冲），
    // 子进程必然被写阻塞，父进程必须持续读走才能推进 —— 这正是播放长曲目的形态。
    // 判据仍是最硬的：全部样本逐位一致（丢一个样本就红）。
    {
        constexpr size_t kBigFrames = 512 * 1024 / frameBytes;   // ≈512KB
        std::vector<int32_t> bigExpected;
        std::vector<uint8_t> bigPcm;
        bigExpected.reserve(kBigFrames * (size_t)ch);
        for (size_t i = 0; i < kBigFrames; ++i) {
            for (int c = 0; c < ch; ++c) {
                int32_t v = (int32_t)((i * 2654435761u) ^ (uint32_t)(c * 40503u));
                if ((i + (size_t)c) % 2 == 1) v = -v;
                v &= 0x00FFFFFF;
                if (v & 0x800000) v |= (int32_t)0xFF000000;
                bigExpected.push_back(v);
                bigPcm.push_back((uint8_t)(v & 0xFF));
                bigPcm.push_back((uint8_t)((v >> 8) & 0xFF));
                bigPcm.push_back((uint8_t)((v >> 16) & 0xFF));
            }
        }
        std::vector<uint8_t> big = stream;
        big.resize(hdrBytes);                    // 只留头
        big.insert(big.end(), bigPcm.begin(), bigPcm.end());

        rta::audio::AudioBuffer ab;
        std::string err;
        const bool ok = run_pipe_case(4096, big, ab, err);
        const bool match = ok && ab.raw == bigExpected;
        ck(match, "512KB PCM（≈87 倍管道缓冲）跨块流式读取：全部样本逐位一致（不丢尾）",
           "ok=" + std::to_string((int)ok) + " err=" + err +
           " got=" + std::to_string(ab.raw.size()) + " expected=" + std::to_string(bigExpected.size()));
        std::printf("    [实测] 本次管道压力：%zu 字节 PCM / %zu 帧 / 子进程按 4096 字节分块\n",
                    bigPcm.size(), kBigFrames);
    }
}

// =========================================================================
// 3. 5 文件真实格式比对：流式 vs 旧临时WAV 逐位一致（判据必须硬）
// =========================================================================
static void test_bit_exact_formats(const std::string& sandbox) {
    std::printf("- 3 真实格式双路径逐位一致比对（FLAC/MP3/OGG-Opus/M4A/WAV PCM逐字节完全相同）\n");

    struct FormatSpec { std::string name; std::string file; bool made; };
    std::vector<FormatSpec> specs;

    const std::string wavPath  = sandbox + "/m_wav.wav";
    const std::string flacPath = sandbox + "/m_flac.flac";
    const std::string mp3Path  = sandbox + "/m_mp3.mp3";
    const std::string oggPath  = sandbox + "/m_ogg.ogg";
    const std::string m4aPath  = sandbox + "/m_m4a.m4a";

    specs.push_back({"WAV (16-bit 44.1kHz 立体声)", wavPath,  make_wav(wavPath)});
    specs.push_back({"FLAC (16-bit 44.1kHz 立体声)", flacPath, make_flac(flacPath)});
    specs.push_back({"MP3 (44.1kHz CBR 立体声)",     mp3Path,  make_mp3(mp3Path)});
    specs.push_back({"OGG (Opus 48kHz 立体声)",      oggPath,  make_opus_ogg(oggPath)});
    specs.push_back({"M4A (AAC 44.1kHz 立体声)",     m4aPath,  make_m4a(wavPath, m4aPath)});

    for (const auto& sp : specs) {
        if (!sp.made) {
            skip((sp.name + " 素材生成").c_str(), "本机无法零依赖生成该格式（afconvert 不可用）");
            continue;
        }
        rta::audio::LoadNote noteStream, noteFile;
        rta::audio::AudioBuffer bufStream, bufFile;

        try {
            bufStream = rta::audio::read_via_ffmpeg_stream(sp.file, &noteStream);
        } catch (const std::exception& e) {
            ck(false, ("流式解码失败: " + sp.name).c_str(), e.what());
            continue;
        }
        try {
            bufFile = rta::audio::read_via_ffmpeg_file(sp.file, &noteFile);
        } catch (const std::exception& e) {
            ck(false, ("临时文件解码失败: " + sp.name).c_str(), e.what());
            continue;
        }

        const bool metaOk = (bufStream.rate == bufFile.rate &&
                             bufStream.channels == bufFile.channels &&
                             bufStream.bits == bufFile.bits &&
                             bufStream.isFloat == bufFile.isFloat &&
                             bufStream.frames() == bufFile.frames());
        ck(metaOk, (sp.name + " 元数据一致 (rate, ch, bits, isFloat, frames)").c_str(),
           "stream: rate=" + std::to_string(bufStream.rate) + " ch=" + std::to_string(bufStream.channels) +
           " bits=" + std::to_string(bufStream.bits) + " frames=" + std::to_string(bufStream.frames()) +
           " | file: rate=" + std::to_string(bufFile.rate) + " frames=" + std::to_string(bufFile.frames()));

        // 核心判据（铁律 3）：逐样本逐位比对
        bool samplesIdentical = (bufStream.raw.size() == bufFile.raw.size());
        size_t diffCount = 0, firstDiffIdx = 0;
        if (samplesIdentical) {
            for (size_t i = 0; i < bufStream.raw.size(); ++i) {
                if (bufStream.raw[i] != bufFile.raw[i]) {
                    if (diffCount == 0) firstDiffIdx = i;
                    ++diffCount;
                }
            }
            if (diffCount > 0) samplesIdentical = false;
        }
        ck(samplesIdentical && bufStream.frames() > 0,
           (sp.name + " 流式 vs 临时WAV PCM逐位完全一致（0错位0误差）").c_str(),
           diffCount == 0 ? ("总样本数: " + std::to_string(bufStream.raw.size()))
                          : ("不匹配样本数: " + std::to_string(diffCount) + " 首次不匹配位于索引 " + std::to_string(firstDiffIdx)));

        std::printf("    [实测数据] %s: 流式耗时=%.1f ms (写磁盘=0 字节) | 临时文件耗时=%.1f ms (ffmpeg=%.1f ms, wavRead=%.1f ms)\n",
                    sp.name.c_str(), noteStream.totalMs, noteFile.totalMs, noteFile.ffmpegMs, noteFile.wavReadMs);
    }
}

// =========================================================================
// 4. 设置开关 (streamdecode) 与环境变量回退测试
// =========================================================================
static void test_settings_toggle(const std::string& sandbox) {
    std::printf("- 4 设置开关控制测试（streamdecode 与环境变量可控回退）\n");

    const std::string testFlac = sandbox + "/test_setting_toggle.flac";
    ck(make_flac(testFlac), "开关用例素材（手写 FLAC）生成成功");

    // 4.0 环境变量未设置时的默认值必须是 true（POSIX 移植前这里是恒 false）
    {
        ::unsetenv("RLPLAYER_STREAM_DECODE");
        rta::audio::set_stream_decode_enabled(true);
        ck(rta::audio::is_stream_decode_enabled() == true,
           "默认（无环境变量 + 设置开）is_stream_decode_enabled() == true");
    }

    // 4.1 默认开启流式
    rta::audio::set_stream_decode_enabled(true);
    ck(rta::audio::is_stream_decode_enabled() == true, "默认或显式开启时 stream_decode_enabled 为 true");
    {
        rta::audio::LoadNote note;
        rta::audio::AudioBuffer b = rta::audio::read_any(testFlac, &note);
        ck(note.text.find("流式解码") != std::string::npos, "开启时 read_any 走流式路径", "note=" + note.text);
        ck(b.frames() > 0, "开启时 read_any 解出非零帧", "frames=" + std::to_string(b.frames()));
    }

    // 4.2 设置关闭 streamdecode = false
    rta::audio::set_stream_decode_enabled(false);
    ck(rta::audio::is_stream_decode_enabled() == false, "set_stream_decode_enabled(false) 后为 false");
    {
        rta::audio::LoadNote note;
        rta::audio::AudioBuffer b = rta::audio::read_any(testFlac, &note);
        ck(note.text.find("流式解码") == std::string::npos && note.text.find("已用 ffmpeg 解码") != std::string::npos,
           "关闭时 read_any 自动回退走临时 WAV 路径", "note=" + note.text);
        ck(note.wavReadMs > 0.0 || note.totalMs > 0.0, "回退路径含 WAV 读取耗时");
        ck(b.frames() > 0, "回退路径解出非零帧", "frames=" + std::to_string(b.frames()));
    }

    // 4.3 环境变量 RLPLAYER_STREAM_DECODE=0 必须压过设置项（设置仍为 true）
    rta::audio::set_stream_decode_enabled(true);
    ::setenv("RLPLAYER_STREAM_DECODE", "0", 1);
    ck(rta::audio::is_stream_decode_enabled() == false,
       "环境变量 RLPLAYER_STREAM_DECODE=0 覆盖设置为 true（走旧路径）");
    ::setenv("RLPLAYER_STREAM_DECODE", "1", 1);
    ck(rta::audio::is_stream_decode_enabled() == true,
       "环境变量 RLPLAYER_STREAM_DECODE=1 覆盖设置为 false 前的开启语义");
    rta::audio::set_stream_decode_enabled(false);
    ck(rta::audio::is_stream_decode_enabled() == true,
       "环境变量 =1 优先于设置项 false（与 Windows 判定顺序一致）");
    ::setenv("RLPLAYER_STREAM_DECODE", "off", 1);
    ck(rta::audio::is_stream_decode_enabled() == false, "环境变量 off 等价于 0");
    ::setenv("RLPLAYER_STREAM_DECODE", "on", 1);
    ck(rta::audio::is_stream_decode_enabled() == true, "环境变量 on 等价于 1");
    ::setenv("RLPLAYER_STREAM_DECODE", "garbage", 1);
    rta::audio::set_stream_decode_enabled(true);
    ck(rta::audio::is_stream_decode_enabled() == true,
       "环境变量非法值不改变判定（回落设置项 true）");
    ::unsetenv("RLPLAYER_STREAM_DECODE");

    // 恢复开启
    rta::audio::set_stream_decode_enabled(true);
    ck(rta::audio::is_stream_decode_enabled() == true, "恢复 stream_decode_enabled(true)");
}

// =========================================================================
// 5. 异常退出码透传与回退机制测试
// =========================================================================
static void test_error_propagation_and_fallback(const std::string& sandbox) {
    std::printf("- 5 异常退出码透传与回退机制验证\n");

    // 5.1 不存在文件：必须快速失败并带出 POSIX 真因（ENOENT）
    {
        const std::string missing = sandbox + "/non_existent_file.flac";
        std::string err;
        try {
            rta::audio::LoadNote note;
            rta::audio::read_any(missing, &note);
        } catch (const std::exception& e) {
            err = e.what();
        }
        ck(!err.empty(), "不存在的文件必须抛出异常");
        ck(err.find("不存在") != std::string::npos, "错误文本包含真因「不存在」", "err=" + err);
        ck(err.find("退出码") != std::string::npos, "错误文本保留退出码标识", "err=" + err);
    }

    // 5.2 损坏的文件：必须带出退出码和 ffmpeg 输出
    {
        const std::string corrupted = sandbox + "/corrupted_file.flac";
        {
            std::vector<uint8_t> garbage;
            const char g[] = "NOT_A_VALID_FLAC_FILE_HEADER_GARBAGE_DATA_1234567890";
            garbage.assign((const uint8_t*)g, (const uint8_t*)g + sizeof(g));
            write_bytes(corrupted, garbage);
        }
        std::string err;
        try {
            rta::audio::LoadNote note;
            rta::audio::read_any(corrupted, &note);
        } catch (const std::exception& e) {
            err = e.what();
        }
        ck(!err.empty(), "损坏文件必须抛出异常");
        ck(err.find("退出码") != std::string::npos, "损坏文件错误文本保留 ffmpeg 退出码", "err=" + err);
    }
}

// =========================================================================
// 6. 流式确实免落盘：临时 WAV 文件数必须为 0
// =========================================================================
// 生产侧临时文件名规则（audio_loader.h read_via_ffmpeg_file）：
//   temp_dir + "rta" + <pid> + "-" + <seq> + ".wav"
// 所以按 "rta<本进程 pid>-*.wav" 精确统计，不受其他进程干扰。
static int count_temp_wavs() {
    const std::string dir = rta::platform::temp_dir_utf8();
    const std::string prefix = "rta" + std::to_string((unsigned long)::getpid()) + "-";
    int n = 0;
    std::error_code ec;
    for (fs::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec)) {
        const std::string name = it->path().filename().string();
        if (name.rfind(prefix, 0) == 0 && it->path().extension() == ".wav") ++n;
    }
    return n;
}

static void test_no_temp_wav_on_stream(const std::string& sandbox) {
    std::printf("- 6 流式路径免落盘实测（临时 WAV 文件数必须为 0）\n");

    const std::string src = sandbox + "/test_nodisk.flac";
    ck(make_flac(src), "免落盘用例素材（手写 FLAC）生成成功");

    rta::audio::set_stream_decode_enabled(true);
    const int before = count_temp_wavs();
    rta::audio::LoadNote note;
    rta::audio::AudioBuffer b;
    try {
        b = rta::audio::read_any(src, &note);
    } catch (const std::exception& e) {
        ck(false, "流式解码成功（免落盘前提）", e.what());
        return;
    }
    const int after = count_temp_wavs();

    ck(note.text.find("流式解码") != std::string::npos, "note 标明走流式路径（不是临时文件）", "note=" + note.text);
    ck(after == before, ("流式解码后临时 WAV 文件数为 0（实测前后均为 " +
                         std::to_string(before) + "）").c_str(), "after=" + std::to_string(after));
    ck(b.frames() > 0, "流式解出非零帧", "frames=" + std::to_string(b.frames()));
    ck(note.wavReadMs == 0.0, "流式路径没有独立的 WAV 读取耗时（wavReadMs==0）",
       "wavReadMs=" + std::to_string(note.wavReadMs));

    // 对照：关掉流式后必须真的产生并清理掉临时 WAV（证明计数方法本身有效，
    // 否则"前后都是 0"可能只是因为计数写错了 —— 铁律 3）
    rta::audio::set_stream_decode_enabled(false);
    {
        const int b2 = count_temp_wavs();
        rta::audio::LoadNote note2;
        try { (void)rta::audio::read_any(src, &note2); } catch (const std::exception&) {}
        const int a2 = count_temp_wavs();
        ck(note2.text.find("已用 ffmpeg 解码") != std::string::npos,
           "对照组（关闭流式）确实走了临时文件路径", "note=" + note2.text);
        ck(a2 == b2, ("对照组结束后临时 WAV 也被清理干净（前后均为 " + std::to_string(b2) + "）").c_str(),
           "before=" + std::to_string(b2) + " after=" + std::to_string(a2));
    }
    rta::audio::set_stream_decode_enabled(true);
}

// =========================================================================
// 7. 流式不适用时：必须自动回退临时文件，且 note 说明走了哪条路径
// =========================================================================
// 为什么需要这条（铁律 3）：光测"流式能用"证明不了"流式不适用时会正确回退"。
//
// ⚠️ 先说清一个**被实测推翻的假设**（记录以免后人重踩）：
//   我最初想用"moov 在文件尾的 M4A"当"需要 seek 的容器"样本。实测证明这条路走不通：
//   read_via_ffmpeg_stream 的 `-i` 参数永远是**真实文件路径**，只有输出是 pipe:1。
//   所以 ffmpeg 对**输入**永远可以 seek —— moov 在尾部照样解得出来。
//   实测：8 秒不可压缩噪声 M4A（136KB，moov 移尾）走 pipe:1 输出的 PCM 与写文件
//   完全一致（1412942 字节），一字节不差。
//   （之前看到的"管道只有 78 字节"是我自己的 shell 测试写错了：`cat f | ffmpeg -i pipe:0`
//     把**输入**变成了不可 seek 的管道，与生产代码的调用形态根本不同。）
//
// 那么在 POSIX 上，流式真正会失败的现实场景是什么？
//   ① ffmpeg 构建受限 / 被沙箱挡住管道输出（本机就有前例：ffmpeg-lite 无 lavfi、无编码器）；
//   ② 输出端在解码中途出问题（管道被外部关闭、muxer 报错）；
//   ③ 未来给某些容器加"已知不支持管道"的黑名单。
// 因此本用例改用**故障注入**来验证回退链路：在 PATH 前置一个只拦截 pipe:1 的 ffmpeg
// 包装脚本（其它情况原样转发给真 ffmpeg）。这样：
//   * 触发条件是**真实存在**的失败形态，不是我编的；
//   * 回退路径必须真的跑通并产出与正常路径逐字节相同的 PCM；
//   * note 必须说清"流式不适用 + 已回退临时文件"。
static void test_stream_fallback_on_failure(const std::string& sandbox) {
    std::printf("- 7 流式失败时必须自动回退临时文件，且 note 说明走了哪条路径\n");

    const std::string src = sandbox + "/fallback_src.flac";
    if (!make_flac(src)) { skip("流式失败回退", "FLAC 素材生成失败"); return; }

    // 7.1 基线：正常环境走流式，PCM 作为逐字节比对基准
    rta::audio::set_stream_decode_enabled(true);
    rta::audio::AudioBuffer ref;
    {
        rta::audio::LoadNote n;
        try {
            ref = rta::audio::read_via_ffmpeg(src, &n);
        } catch (const std::exception& e) {
            ck(false, "基线：正常环境流式解码成功（回退判据的前提）", e.what());
            return;
        }
        ck(ref.frames() > 0 && n.text.find("流式解码") != std::string::npos,
           "基线：正常环境走流式并解出非零帧", "frames=" + std::to_string(ref.frames()) + " note=" + n.text);
    }

    // 7.2 注入一个「只拒绝 pipe:1」的 ffmpeg 包装脚本
    const std::string fakeDir = sandbox + "/fakebin";
    std::error_code ec;
    fs::create_directories(fs::path(fakeDir), ec);
    const std::string realFfmpeg = rta::audio::find_tool("ffmpeg");
    const std::string fakePath = fakeDir + "/ffmpeg";
    {
        std::ofstream f(fakePath);
        if (!f) { skip("流式失败回退", "无法写入包装脚本"); return; }
        f << "#!/bin/sh\n"
          << "# 测试用故障注入：只让 pipe:1 输出失败，其余原样转发给真 ffmpeg\n"
          << "for a in \"$@\"; do\n"
          << "  if [ \"$a\" = \"pipe:1\" ]; then\n"
          << "    echo 'injected: pipe output not supported' >&2\n"
          << "    exit 1\n"
          << "  fi\n"
          << "done\n"
          << "exec \"" << realFfmpeg << "\" \"$@\"\n";
        f.close();
    }
    ::chmod(fakePath.c_str(), 0755);

    const char* oldPath = ::getenv("PATH");
    const std::string savedPath = oldPath ? oldPath : "";
    ::setenv("PATH", (fakeDir + ":" + savedPath).c_str(), 1);

    // 7.3 核心：流式失败 → 必须自动回退，且 PCM 与基线逐字节相同
    rta::audio::LoadNote note;
    rta::audio::AudioBuffer got;
    bool threw = false;
    try {
        got = rta::audio::read_via_ffmpeg(src, &note);
    } catch (const std::exception& e) {
        threw = true;
        ck(false, "流式失败时 read_via_ffmpeg 必须自动回退（而不是直接抛错）", e.what());
    }
    if (!threw) {
        ck(got.frames() == ref.frames() && got.raw == ref.raw,
           "回退后的 PCM 与流式基线逐字节相同",
           "got=" + std::to_string(got.frames()) + " ref=" + std::to_string(ref.frames()));
        ck(note.text.find("流式解码不适用") != std::string::npos &&
           note.text.find("已回退临时文件解码") != std::string::npos,
           "note 明确说明「流式不适用，已回退临时文件」", "note=" + note.text);
        std::printf("    [实测 note] %s\n", note.text.c_str());
    }

    // 7.4 反向对照：note 里那句"流式解码不适用"不是恒有串
    //     —— 同一注入环境、但关掉流式开关时走的是纯临时文件路径
    rta::audio::set_stream_decode_enabled(false);
    {
        rta::audio::LoadNote n2;
        rta::audio::AudioBuffer b2;
        try { b2 = rta::audio::read_via_ffmpeg(src, &n2); } catch (const std::exception&) {}
        ck(b2.frames() == ref.frames(), "关闭流式时在注入环境下仍正常解码（回归）",
           "frames=" + std::to_string(b2.frames()));
        ck(n2.text.find("流式解码不适用") == std::string::npos,
           "关闭流式时 note 不出现「流式解码不适用」（证明 7.3 的串不是恒有）", "note=" + n2.text);
    }
    rta::audio::set_stream_decode_enabled(true);

    // 7.5 复原 PATH
    ::setenv("PATH", savedPath.c_str(), 1);
    std::error_code ec2;
    fs::remove_all(fs::path(fakeDir), ec2);
}


int main() {
    std::printf("== ROADMAP P6b: 解码免临时 WAV（流式读 ffmpeg 输出）离线验收 ==\n");

    const std::string ffmpeg = rta::audio::find_tool("ffmpeg");
    ck(!ffmpeg.empty(), "环境有 ffmpeg（测试前提）");
    if (ffmpeg.empty()) {
        std::printf("缺 ffmpeg，无法执行测试\n");
        return 1;
    }
    std::printf("  ffmpeg: %s\n", ffmpeg.c_str());

    std::string sandbox = rta::platform::temp_dir_utf8() + "rta_stream_decode_" +
                          std::to_string((unsigned long)::getpid());
    std::error_code ec;
    fs::create_directories(fs::path(sandbox), ec);
    std::printf("  沙箱: %s\n", sandbox.c_str());

    test_wav_header_parser();
    test_chunked_pipe_real();
    test_bit_exact_formats(sandbox);
    test_settings_toggle(sandbox);
    test_error_propagation_and_fallback(sandbox);
    test_no_temp_wav_on_stream(sandbox);
    test_stream_fallback_on_failure(sandbox);

    fs::remove_all(fs::path(sandbox), ec);

    std::printf("\n测试结果: %s (g_fail=%d, g_skip=%d)\n",
                g_fail == 0 ? "全部通过" : "存在失败", g_fail, g_skip);
    return g_fail == 0 ? 0 : 1;
}
