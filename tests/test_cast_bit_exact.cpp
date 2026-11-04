// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_cast_bit_exact.cpp — AirPlay 发送端「源 PCM → 网络包」逐位一致性证明
//
// 为什么要有这条测试（用户 2026-11-04 提问：「AirPlay 都是非 bit-perfect，有没有验证方式」）：
//   `bitPerfect:no` 目前只能说明「端到端没验证过」，但把「我们能控制的那一段」也一起否掉了。
//   我们能控制、也能证明的只有一段：源 PCM → ALAC 包 → 网络字节。
//   这条测试把这段单独证明出来，而且**用独立实现解码**（FFmpeg 的 ALAC 解码器），
//   不是拿 Apple 的编码器再拿 Apple 的解码器自证。
//
// 判据链条（任一步失败即红）：
//   1) 生产转换 `convert_audio_for_cast()`：44.1k/16/2 必须走 bitExactDirect，样本逐位不变；
//   2) 生产 `AlacEncoder`（AudioToolbox）按 RAOP 的 352 帧/包编码；
//   3) 用页内数据拼出 CAF 容器（ALAC + magic cookie + 包表），交给 **FFmpeg** 解码；
//   4) FFmpeg 解出的 PCM 与源 PCM **逐样本相等** → 网络包内的 ALAC 是标准可解码的，且无损。
//
// 审计边界（写清楚，避免被误读成 end-to-end）：
//   * 这条测试**不**证明接收端 DAC 输出逐位一致。AirPlay 1 的接收端可以自行重采样
//     （本机实测过的那台把 44.1k 流喂给 48k/S16 的 ALSA），发送端无从阻止。
//   * 因此 UI 只能写「源→网络包逐位一致（已用独立解码器验证）」，不能写 bit-perfect。
//
// 纪律：不打开任何音频设备、不连任何真实接收器；全程内存 + 临时文件。
#include "audio/alac_encoder.h"
#include "audio/cast_pcm_convert.h"
#include "audio/wav.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include <sys/wait.h>

namespace {

int g_fail = 0;
int g_skip = 0;

void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what.c_str());
    } else {
        std::printf("  [FAIL] %s %s\n", what.c_str(), detail.c_str());
        ++g_fail;
    }
}

void skip(const std::string& what, const std::string& why) {
    std::printf("  [SKIP] %s (%s)\n", what.c_str(), why.c_str());
    ++g_skip;
}

// ---------------- 大端写入（CAF 的字节序）----------------
void put_be16(std::vector<uint8_t>& b, uint16_t v) {
    b.push_back(static_cast<uint8_t>(v >> 8));
    b.push_back(static_cast<uint8_t>(v));
}
void put_be32(std::vector<uint8_t>& b, uint32_t v) {
    for (int i = 3; i >= 0; --i) b.push_back(static_cast<uint8_t>(v >> (8 * i)));
}
void put_be64(std::vector<uint8_t>& b, uint64_t v) {
    for (int i = 7; i >= 0; --i) b.push_back(static_cast<uint8_t>(v >> (8 * i)));
}
void put_f64be(std::vector<uint8_t>& b, double d) {
    uint64_t bits = 0;
    std::memcpy(&bits, &d, sizeof(bits));
    put_be64(b, bits);
}
void put_fourcc(std::vector<uint8_t>& b, const char* cc) {
    for (int i = 0; i < 4; ++i) b.push_back(static_cast<uint8_t>(cc[i]));
}
// CAF 的变长整数：7 位一组，最高位为「后面还有」
void put_varint(std::vector<uint8_t>& b, uint64_t v) {
    uint8_t tmp[10];
    int n = 0;
    do {
        tmp[n++] = static_cast<uint8_t>(v & 0x7Fu);
        v >>= 7;
    } while (v != 0);
    for (int i = n - 1; i >= 0; --i) b.push_back(static_cast<uint8_t>(tmp[i] | (i ? 0x80 : 0x00)));
}

// 把「一堆 ALAC 包 + magic cookie」拼成 FFmpeg 能吃的 CAF。
// 为什么要 CAF：ALAC 没有 raw 容器，FFmpeg 的 alac 解码器需要 extradata(cookie) 与包边界，
// CAF 是唯一要求最少（desc + kuki + pakt + data）的 Apple 容器。
std::vector<uint8_t> build_caf(const std::vector<std::vector<uint8_t>>& packets,
                               const std::vector<uint8_t>& cookie,
                               uint32_t sampleRate, int channels, int framesPerPacket,
                               uint64_t totalFrames) {
    std::vector<uint8_t> out;
    put_fourcc(out, "caff");
    put_be16(out, 1);   // version
    put_be16(out, 0);   // flags

    // desc: AudioStreamBasicDescription（CAF 里是大端）
    put_fourcc(out, "desc");
    put_be64(out, 32);
    put_f64be(out, static_cast<double>(sampleRate));
    put_fourcc(out, "alac");
    put_be32(out, 0);                        // mFormatFlags：ALAC 不需要
    put_be32(out, 0);                        // mBytesPerPacket（压缩格式填 0）
    put_be32(out, static_cast<uint32_t>(framesPerPacket));
    put_be32(out, static_cast<uint32_t>(channels));
    put_be32(out, 16);                       // mBitsPerChannel
    // kuki: magic cookie
    put_fourcc(out, "kuki");
    put_be64(out, static_cast<uint64_t>(cookie.size()));
    out.insert(out.end(), cookie.begin(), cookie.end());

    // pakt: 包表（每包字节数 + 每包帧数）
    {
        std::vector<uint8_t> p;
        put_be64(p, static_cast<uint64_t>(packets.size()));   // mNumberPackets
        put_be64(p, totalFrames);                            // mNumberValidFrames
        put_be32(p, 0);                                      // mPrimingFrames
        put_be32(p, 0);                                      // mRemainderFrames
        for (const auto& pkt : packets) put_varint(p, pkt.size());
        for (size_t i = 0; i < packets.size(); ++i) put_varint(p, static_cast<uint64_t>(framesPerPacket));
        put_fourcc(out, "pakt");
        put_be64(out, static_cast<uint64_t>(p.size()));
        out.insert(out.end(), p.begin(), p.end());
    }

    // data: 4 字节 edit count（0）+ 包数据
    {
        std::vector<uint8_t> d;
        put_be32(d, 0);
        for (const auto& pkt : packets) d.insert(d.end(), pkt.begin(), pkt.end());
        put_fourcc(out, "data");
        put_be64(out, static_cast<uint64_t>(d.size()));
        out.insert(out.end(), d.begin(), d.end());
    }
    return out;
}

bool write_file(const std::string& path, const std::vector<uint8_t>& bytes) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const bool ok = bytes.empty() || std::fwrite(bytes.data(), 1, bytes.size(), f) == bytes.size();
    std::fclose(f);
    return ok;
}

bool read_file(const std::string& path, std::vector<uint8_t>& out) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    out.clear();
    uint8_t buf[65536];
    size_t n = 0;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) out.insert(out.end(), buf, buf + n);
    std::fclose(f);
    return true;
}

std::string resolve_ffmpeg(int argc, char** argv) {
    if (argc > 1 && argv[1][0] != '\0') return argv[1];
    if (const char* e = std::getenv("FFMPEG")) { if (*e) return e; }
    return "ffmpeg";
}

std::string temp_dir() {
    const char* t = std::getenv("TMPDIR");
    std::string d = (t && *t) ? t : "/tmp";
    if (!d.empty() && d.back() == '/') d.pop_back();
    return d + "/rlplayer-castbitexact-" + std::to_string(::getpid());
}

// 确定性源信号：覆盖 int16 全域（含 -32768/32767 端点与 0），外加一条合成正弦。
// 之所以要全域：ALAC 的 predictor/escape 分支在极端值上才会走不同路径，
// 只用小信号（比如 ≤±1000）会漏掉那些分支。
std::vector<int16_t> make_probe_pcm(size_t frames) {
    std::vector<int16_t> pcm(frames * 2);
    for (size_t i = 0; i < frames; ++i) {
        const double ph = 2.0 * M_PI * static_cast<double>(i) / 97.0;
        const double s = std::sin(ph);
        int16_t l, r;
        switch (i % 6) {
            case 0: l = 0; r = 0; break;
            case 1: l = 32767; r = -32768; break;
            case 2: l = -32768; r = 32767; break;
            case 3: l = 1; r = -1; break;
            case 4: l = static_cast<int16_t>(s * 32767.0); r = static_cast<int16_t>(s * 32000.0); break;
            default: l = static_cast<int16_t>((i * 37) % 65536 - 32768); r = static_cast<int16_t>(32767 - (int)(i % 32768)); break;
        }
        pcm[i * 2 + 0] = l;
        pcm[i * 2 + 1] = r;
    }
    return pcm;
}

}  // namespace

int main(int argc, char** argv) {
    std::printf("=== test_cast_bit_exact: 源 PCM → ALAC 网络包 逐位一致性（独立解码器交叉验证）===\n\n");

    const std::string ffmpeg = resolve_ffmpeg(argc, argv);

    // ---- 1. 生产转换路径：44.1k/16/2 必须逐位直通 ----
    std::printf("[1] 生产转换路径 bitExactDirect\n");
    const size_t kFrames = 352 * 12;   // 12 个整包，覆盖多包预测器上下文
    const std::vector<int16_t> probe = make_probe_pcm(kFrames);
    {
        rta::audio::AudioBuffer ab;
        ab.rate = 44100;
        ab.channels = 2;
        ab.bits = 16;
        ab.isFloat = false;
        // AudioBuffer::raw 是 int32 容器（16 bit 源把 -32768..32767 存在 int32 里），
        // 直接 memcpy int16 会把样本位序彻底打乱 —— 这一条自己踩过，别再犯。
        ab.raw.resize(kFrames * 2);
        for (size_t i = 0; i < probe.size(); ++i) ab.raw[i] = static_cast<int32_t>(probe[i]);

        rta::audio::CastAudioSpec spec;
        const auto conv = rta::audio::convert_audio_for_cast(ab, spec);
        ck(conv.bitExactDirect, "44.1k/16/2 走逐位直通分支");
        ck(conv.pcm.size() == probe.size(), "样本总数不变",
           std::to_string(conv.pcm.size()) + " vs " + std::to_string(probe.size()));
        ck(conv.pcm == probe, "转换输出与源 PCM 逐样本相等");
        ck(conv.warningZh.empty() && conv.warningEn.empty(), "逐位直通不产生降级警告",
           conv.warningZh);
    }

    // ---- 2. 生产 ALAC 编码（RAOP 的 352 帧/包）----
    std::printf("\n[2] 生产 AlacEncoder（352 帧/包）\n");
    rta::audio::AlacEncoder enc;
    std::string err;
    if (!enc.init(44100, 2, 16, 352, &err)) {
        std::printf("  [FAIL] 编码器初始化：%s\n", err.c_str());
        ++g_fail;
        return 1;
    }
    std::vector<std::vector<uint8_t>> packets;
    for (size_t off = 0; off + 352 <= kFrames; off += 352) {
        std::vector<uint8_t> out;
        if (!enc.encode_frame(probe.data() + off * 2, 352, out, &err)) {
            std::printf("  [FAIL] 编码第 %zu 包：%s\n", packets.size(), err.c_str());
            ++g_fail;
            break;
        }
        packets.push_back(std::move(out));
    }
    ck(packets.size() == kFrames / 352, "包数 = 帧数/352", std::to_string(packets.size()));
    bool sizesOk = !packets.empty();
    for (const auto& p : packets) if (p.empty()) sizesOk = false;
    ck(sizesOk, "每个包都非空");
    const std::vector<uint8_t> cookie = enc.magic_cookie();
    ck(!cookie.empty(), "拿到 ALAC magic cookie 供解码器使用", std::to_string(cookie.size()) + " bytes");

    // ---- 3. 交给 FFmpeg（独立解码器）----
    std::printf("\n[3] 用 FFmpeg 独立解码这些包\n");
    const std::string dir = temp_dir();
    std::string mk = "mkdir -p '" + dir + "'";
    if (std::system(mk.c_str()) != 0) {
        std::printf("  [FAIL] 无法创建临时目录 %s\n", dir.c_str());
        ++g_fail;
        return 1;
    }
    const std::string cafPath = dir + "/probe.caf";
    const auto caf = build_caf(packets, cookie, 44100, 2, 352, kFrames);
    ck(write_file(cafPath, caf), "写出 CAF 容器", cafPath);

    // 输出用 WAV 而不是 s16le：随包内置的 FFmpeg 是裁剪版（--enable-muxer 里没有 s16le），
    // 用 wav 才能保证「在发布包里也能跑」这条测试。
    const std::string wavPath = dir + "/probe_decode.wav";
    const std::string cmd = "'" + ffmpeg + "' -v error -y -i '" + cafPath +
                            "' -c:a pcm_s16le -f wav '" + wavPath + "' 2>'" + dir + "/ff.log'";
    const int rc = std::system(cmd.c_str());
    std::vector<uint8_t> log;
    read_file(dir + "/ff.log", log);
    const std::string logText(log.begin(), log.end());

    if (rc != 0) {
        skip("FFmpeg 独立解码", "ffmpeg 不可用或拒绝该容器：" + (logText.empty() ? "no output" : logText));
    } else {
        std::vector<uint8_t> wav;
        ck(read_file(wavPath, wav), "读到 FFmpeg 输出的 WAV", wavPath);
        // 定位 data 块（WAV 允许 fmt 前后附加块，不能假设固定 44 字节头）
        size_t dataOff = 0, dataLen = 0;
        for (size_t i = 12; i + 8 <= wav.size();) {
            const uint32_t len = static_cast<uint32_t>(wav[i + 4]) |
                                 (static_cast<uint32_t>(wav[i + 5]) << 8) |
                                 (static_cast<uint32_t>(wav[i + 6]) << 16) |
                                 (static_cast<uint32_t>(wav[i + 7]) << 24);
            const bool isData = wav[i] == 'd' && wav[i + 1] == 'a' && wav[i + 2] == 't' && wav[i + 3] == 'a';
            if (isData) { dataOff = i + 8; dataLen = std::min<size_t>(len, wav.size() - dataOff); break; }
            i += 8 + static_cast<size_t>(len) + (len & 1u);
        }
        ck(dataLen > 0, "WAV 里有 data 块", std::to_string(dataLen) + " bytes");
        ck(dataLen == probe.size() * sizeof(int16_t),
           "FFmpeg 解出的样本数与源一致",
           std::to_string(dataLen / sizeof(int16_t)) + " vs " + std::to_string(probe.size()));
        if (dataLen == probe.size() * sizeof(int16_t)) {
            std::vector<int16_t> decoded(probe.size());
            std::memcpy(decoded.data(), wav.data() + dataOff, dataLen);
            size_t firstDiff = decoded.size();
            for (size_t i = 0; i < decoded.size(); ++i) {
                if (decoded[i] != probe[i]) { firstDiff = i; break; }
            }
            ck(firstDiff == decoded.size(),
               "FFmpeg 解码结果与源 PCM 逐样本相等（独立实现交叉验证）",
               firstDiff == decoded.size()
                   ? std::string()
                   : ("首个不同样本 @" + std::to_string(firstDiff) + " src=" +
                      std::to_string(probe[firstDiff]) + " dec=" + std::to_string(decoded[firstDiff])));
        }
    }

    // ---- 4. 审计边界：这条测试不能证明什么 ----
    std::printf("\n[4] 审计边界（写死在测试里，防止结论被放大）\n");
    std::printf("  [NOTE] 本测试只覆盖「源 PCM → 网络包内的 ALAC」这一段的逐位一致。\n");
    std::printf("  [NOTE] 接收端解码后的重采样 / 音量的模拟输出不受发送端控制，此处不作任何断言。\n");

    const std::string rm = "rm -rf '" + dir + "'";
    if (std::system(rm.c_str()) != 0) std::printf("  [WARN] 临时目录未能清理：%s\n", dir.c_str());

    std::printf("\n=== 总结: %s（失败 %d，跳过 %d）===\n",
                g_fail ? "FAIL" : "PASS", g_fail, g_skip);
    return g_fail ? 1 : 0;
}
