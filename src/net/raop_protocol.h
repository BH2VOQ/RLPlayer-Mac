// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// raop_protocol.h — AirPlay (RAOP) 线格式编解码：纯函数、无 socket、可离线单测。
//
// 字节布局依据（全部来自本地参考实现 shairport-sync 3.3.8 的 rtp.c，按数据读取）：
//   sync 包（type 0xD4，20 字节）
//     [0]=0x80  [1]=0xD4  [2..3]=flags（AirPlay 用 4，iTunes 用 7）
//     [4..7]  = latency_delayed_timestamp —— “此刻接收端应当正在播”的 RTP 时间戳（= current − latency）
//     [8..15] = NTP 64 位时间戳（1900 纪元，整秒<<32 | 小数）
//     [16..19]= current RTP timestamp（发送端此刻的音频时间轴位置）
//     接收端据此计算 latency = packet[16] − packet[4]，并把 packet[16] 对齐到 packet[8] 的
//     NTP 时刻；真正出声还要再晚一个 latency。**两个字段填同一个值就等于宣告零缓冲**。
//   timing 请求 0xD2 / 应答 0xD3（各 32 字节）
//     [0]=0x80 [1]=类型 [2..3]=序列号 [4..7]=filler
//     [8..15]=origin [16..23]=receive [24..31]=transmit
//     应答的 origin 必须是“请求的 transmit 时刻”（NTP 语义），不是请求 origin 字段的回显。
//   NACK/重传请求（接收端 → 发送端 control 端口，8 字节）
//     [0]=0x80 [1]=0x55|0x80=0xD5 [2..3]=对方序列号 [4..5]=首个丢失序号 [6..7]=包数
//   重传应答（发送端 → 接收端 control 端口）
//     [0]=0x80 [1]=0xD6 [2..3]=原序列号 | 后接**完整的原 12 字节 RTP 头**（同 seq/ts/ssrc）| ALAC 载荷
//     rtp.c:421 「else if (packet[1] == 0xd6) { pktp = packet + 4; plen -= 4; }」——
//     接收端只认这个 4 字节外层头；直接回一个 0x60 的裸 RTP 包会被当成普通音频，
//     序号/时间戳错位，丢包修不回来。走 audio 端口的形式是 0x56（同样是 4 字节头），
//     本实现统一走 control 端口 + 0xD6。
//
// 本文件只做“把字节按上述布局摆好/读出”，不做任何策略判断。
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <string>
#include <utility>
#include <vector>

namespace rta::net::raop {

// ---------------------------------------------------------------- 大端读写
inline void put_be16(uint8_t* p, uint16_t v) {
    p[0] = static_cast<uint8_t>(v >> 8);
    p[1] = static_cast<uint8_t>(v & 0xFFu);
}

inline void put_be32(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v >> 24);
    p[1] = static_cast<uint8_t>((v >> 16) & 0xFFu);
    p[2] = static_cast<uint8_t>((v >> 8) & 0xFFu);
    p[3] = static_cast<uint8_t>(v & 0xFFu);
}

inline void put_be64(uint8_t* p, uint64_t v) {
    put_be32(p, static_cast<uint32_t>(v >> 32));
    put_be32(p + 4, static_cast<uint32_t>(v & 0xFFFFFFFFull));
}

inline uint16_t get_be16(const uint8_t* p) {
    return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | p[1]);
}

inline uint32_t get_be32(const uint8_t* p) {
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

inline uint64_t get_be64(const uint8_t* p) {
    return (static_cast<uint64_t>(get_be32(p)) << 32) | static_cast<uint64_t>(get_be32(p + 4));
}

// ---------------------------------------------------------------- NTP（1900 纪元）
// 2208988800 = 1900-01-01 到 1970-01-01 的整秒数。
constexpr uint64_t kNtpUnixEpochOffset = 2208988800ull;

inline uint64_t ntp_from_unix_ns(uint64_t unix_ns) {
    const uint64_t sec = unix_ns / 1000000000ull + kNtpUnixEpochOffset;
    const uint64_t rem = unix_ns % 1000000000ull;
    const uint64_t frac = (rem << 32) / 1000000000ull;   // 小数部分
    return (sec << 32) | (frac & 0xFFFFFFFFull);
}

inline uint64_t ntp_now() {
    struct timespec ts {};
    clock_gettime(CLOCK_REALTIME, &ts);
    const uint64_t unix_ns = static_cast<uint64_t>(ts.tv_sec) * 1000000000ull +
                             static_cast<uint64_t>(ts.tv_nsec);
    return ntp_from_unix_ns(unix_ns);
}

// 两个 NTP 时间戳之差（纳秒，带符号）。64 位 NTP 是“整秒<<32 | 小数”的定点数，
// 单位是 2^-32 秒，所以差值必须换算成纳秒（直接当纳秒用会差 4.29 倍）。
inline int64_t ntp_delta_ns(uint64_t a, uint64_t b) {
    const int64_t fixed = static_cast<int64_t>(a - b);
    return static_cast<int64_t>((static_cast<__int128>(fixed) * 1000000000ll) / 4294967296ll);
}

// ---------------------------------------------------------------- 帧数换算
// 用 128 位中间量：ns × rate 在长时间（数天）下会溢出 int64。
inline uint64_t frames_for_elapsed_ns(uint64_t elapsed_ns, uint32_t rate) {
    if (rate == 0) return 0;
    const unsigned __int128 frames =
        (static_cast<unsigned __int128>(elapsed_ns) * rate) / 1000000000u;
    return static_cast<uint64_t>(frames);
}

// ---------------------------------------------------------------- sync 包（0xD4）
constexpr size_t kSyncPacketSize = 20;
constexpr uint8_t kSyncPacketType = 0xD4;
constexpr uint16_t kSyncFlagsAirPlay = 4;   // 参考实现对 flags==7 会额外加 11025 帧

struct SyncFields {
    uint16_t flags = kSyncFlagsAirPlay;
    uint32_t current_rtp = 0;          // 写入 [16..19]
    uint32_t latency_frames = 0;       // 本地缓冲目标（帧），被 current−delayed 表达出来
    uint64_t ntp = 0;                  // 写入 [8..15]
    // “此刻应当正在播”的时间戳；模 2^32 相减，回绕天然正确。
    uint32_t latency_delayed_timestamp() const { return current_rtp - latency_frames; }
};

inline std::vector<uint8_t> build_sync_packet(const SyncFields& f) {
    std::vector<uint8_t> p(kSyncPacketSize, 0);
    p[0] = 0x80;
    p[1] = kSyncPacketType;
    put_be16(p.data() + 2, f.flags);
    put_be32(p.data() + 4, f.latency_delayed_timestamp());
    put_be64(p.data() + 8, f.ntp);
    put_be32(p.data() + 16, f.current_rtp);
    return p;
}

// ---------------------------------------------------------------- timing（0xD2 / 0xD3）
constexpr size_t kTimingPacketSize = 32;
constexpr uint8_t kTimingRequestType = 0xD2;
constexpr uint8_t kTimingReplyType = 0xD3;

struct TimingRequest {
    bool valid = false;
    uint16_t seq = 0;
    uint64_t origin = 0;
    uint64_t receive = 0;
    uint64_t transmit = 0;
};

inline bool parse_timing_request(const uint8_t* p, size_t n, TimingRequest& out) {
    out = TimingRequest{};
    if (!p || n < kTimingPacketSize) return false;
    if ((p[0] & 0xC0u) != 0x80u) return false;   // 版本 2
    if (p[1] != kTimingRequestType) return false;
    out.valid = true;
    out.seq = get_be16(p + 2);
    out.origin = get_be64(p + 8);
    out.receive = get_be64(p + 16);
    out.transmit = get_be64(p + 24);
    return true;
}

// reply 的 origin 取请求的 transmit（NTP 语义：请求“离开对端”的时刻）。
// 有些实现对端只填 origin 不填 transmit，此时退回回显 origin——两者都没有时就是 0，
// 与 shairport-sync 的请求（origin/receive/transmit 全 0）行为一致。
inline uint64_t timing_reply_origin(const TimingRequest& req) {
    return req.transmit != 0 ? req.transmit : req.origin;
}

inline std::vector<uint8_t> build_timing_reply(const TimingRequest& req,
                                               uint64_t receive_ntp,
                                               uint64_t transmit_ntp) {
    std::vector<uint8_t> p(kTimingPacketSize, 0);
    p[0] = 0x80;
    p[1] = kTimingReplyType;
    put_be16(p.data() + 2, req.seq);
    put_be64(p.data() + 8, timing_reply_origin(req));
    put_be64(p.data() + 16, receive_ntp);
    put_be64(p.data() + 24, transmit_ntp);
    return p;
}

// ---------------------------------------------------------------- NACK / 重传请求
constexpr size_t kNackPacketSize = 8;
constexpr uint16_t kNackType = 0x55;
// 单次请求的重传包数上限：防御性裁剪，正常对端一次只请求 1~32 个。
constexpr uint16_t kMaxNackCount = 128;

struct NackRequest {
    bool valid = false;
    uint16_t seq = 0;      // 对端自己的序号（诊断用）
    uint16_t first = 0;    // 首个丢失序号
    uint16_t count = 0;    // 连续包数（已裁剪到 [1, kMaxNackCount]）
};

inline bool parse_nack(const uint8_t* p, size_t n, NackRequest& out) {
    out = NackRequest{};
    if (!p || n < kNackPacketSize) return false;
    // 参考实现发的是 0x55 | 0x80 = 0xD5；有实现只发 0x55。掩掉最高位兼容两者。
    if ((p[1] & 0x7Fu) != kNackType) return false;
    out.seq = get_be16(p + 2);
    out.first = get_be16(p + 4);
    out.count = get_be16(p + 6);
    if (out.count == 0) return false;                       // 0 个包无意义
    if (out.count > kMaxNackCount) out.count = kMaxNackCount;
    out.valid = true;
    return true;
}

// ---------------------------------------------------------------- RTP
constexpr size_t kRtpHeaderSize = 12;
constexpr uint8_t kRtpPayloadType = 96;

struct RtpHeader {
    bool valid = false;
    bool marker = false;
    uint8_t payload_type = 0;
    uint16_t sequence = 0;
    uint32_t timestamp = 0;
    uint32_t ssrc = 0;
};

inline void put_rtp_header(uint8_t* p, uint16_t seq, uint32_t ts, uint32_t ssrc,
                           uint8_t pt = kRtpPayloadType, bool marker = false) {
    p[0] = 0x80;                                            // V=2, P=0, X=0, CC=0
    p[1] = static_cast<uint8_t>((marker ? 0x80u : 0u) | (pt & 0x7Fu));
    put_be16(p + 2, seq);
    put_be32(p + 4, ts);
    put_be32(p + 8, ssrc);
}

inline bool parse_rtp_header(const uint8_t* p, size_t n, RtpHeader& out) {
    out = RtpHeader{};
    if (!p || n < kRtpHeaderSize) return false;
    if ((p[0] >> 6) != 2) return false;                     // V=2
    const bool padding = (p[0] & 0x20u) != 0;
    const bool extension = (p[0] & 0x10u) != 0;
    const int cc = p[0] & 0x0Fu;
    if (padding || extension || cc != 0) return false;      // 我们不发也用不到
    out.marker = (p[1] & 0x80u) != 0;
    out.payload_type = static_cast<uint8_t>(p[1] & 0x7Fu);
    out.sequence = get_be16(p + 2);
    out.timestamp = get_be32(p + 4);
    out.ssrc = get_be32(p + 8);
    out.valid = true;
    return true;
}

// ---------------------------------------------------------------- 重传应答（0xD6）
constexpr size_t kResendHeaderSize = 4;
constexpr uint8_t kResendPacketType = 0xD6;   // 0x56 | 0x80

// 4 字节重传头 + 原 12 字节 RTP 头 + 原 ALAC 载荷。
// 内层 RTP 头必须与**原始音频包逐字节一致**（seq/ts/ssrc 都不改），
// 否则接收端按新序号/新时间戳排包，重传等于没补。
inline std::vector<uint8_t> build_resend_packet(uint16_t seq, uint32_t ts, uint32_t ssrc,
                                                const uint8_t* payload, size_t len) {
    std::vector<uint8_t> p(kResendHeaderSize + kRtpHeaderSize + len, 0);
    p[0] = 0x80;
    p[1] = kResendPacketType;
    put_be16(p.data() + 2, seq);
    put_rtp_header(p.data() + kResendHeaderSize, seq, ts, ssrc);
    if (len > 0 && payload) {
        std::memcpy(p.data() + kResendHeaderSize + kRtpHeaderSize, payload, len);
    }
    return p;
}

// ---------------------------------------------------------------- Transport 头
struct TransportInfo {
    bool interleaved = false;      // RTP/AVP/TCP：音频走 RTSP 那条 TCP
    bool has_server_port = false;
    uint16_t server_port = 0;      // 音频
    uint16_t control_port = 0;
    uint16_t timing_port = 0;
};

namespace transport_detail {

inline std::string lower(std::string s) {
    for (char& c : s) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return s;
}

inline std::string trim_copy(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n')) ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n')) --b;
    return s.substr(a, b - a);
}

// 严格解析 1..65535 的十进制端口；其它（空、溢出、夹杂字符）一律失败。
inline bool parse_port(const std::string& s, uint16_t& out) {
    if (s.empty() || s.size() > 5) return false;
    uint32_t v = 0;
    for (char c : s) {
        if (c < '0' || c > '9') return false;
        v = v * 10 + static_cast<uint32_t>(c - '0');
    }
    if (v == 0 || v > 65535) return false;
    out = static_cast<uint16_t>(v);
    return true;
}

}  // namespace transport_detail

// 解析 SETUP 的 Transport。只看 RTP/AVP/TCP 才判定交织（真机 shairport-sync 3.3.8
// 会在 UDP 的回包里**同时**带 interleaved=0-1，把 interleaved= 当条件会把音频发进 TCP）。
inline bool parse_transport(const std::string& header, TransportInfo& out, std::string* err) {
    out = TransportInfo{};
    if (header.empty()) {
        if (err) *err = "SETUP 响应缺失 Transport 头";
        return false;
    }
    const std::string lowerHeader = transport_detail::lower(header);
    out.interleaved = lowerHeader.find("rtp/avp/tcp") != std::string::npos;

    uint16_t range_second = 0;
    size_t pos = 0;
    while (pos <= header.size()) {
        size_t semi = header.find(';', pos);
        if (semi == std::string::npos) semi = header.size();
        const std::string token = transport_detail::trim_copy(header.substr(pos, semi - pos));
        pos = semi + 1;
        if (token.empty()) continue;
        const size_t eq = token.find('=');
        if (eq == std::string::npos) continue;              // unicast / mode=.. 之外的无值 token
        const std::string key = transport_detail::lower(transport_detail::trim_copy(token.substr(0, eq)));
        const std::string value = transport_detail::trim_copy(token.substr(eq + 1));
        if (key != "server_port" && key != "control_port" && key != "timing_port") continue;

        // 端口允许写成 "a" 或 "a-b"（RAOP 里 a-b 表示 RTP/RTCP 这一对）。
        std::string firstStr = value, secondStr;
        const size_t dash = value.find('-');
        if (dash != std::string::npos) {
            firstStr = value.substr(0, dash);
            secondStr = value.substr(dash + 1);
        }
        uint16_t port = 0, second = 0;
        if (!transport_detail::parse_port(transport_detail::trim_copy(firstStr), port)) {
            if (err) *err = "Transport 头端口非法: " + key + "=" + value;
            return false;
        }
        if (!secondStr.empty()) {
            if (!transport_detail::parse_port(transport_detail::trim_copy(secondStr), second)) {
                if (err) *err = "Transport 头端口区间非法: " + key + "=" + value;
                return false;
            }
            if (second <= port) {
                if (err) *err = "Transport 头端口区间倒序: " + key + "=" + value;
                return false;
            }
        }
        if (key == "server_port") {
            out.has_server_port = true;
            out.server_port = port;
            range_second = second;
        } else if (key == "control_port") {
            out.control_port = port;
        } else {
            out.timing_port = port;
        }
    }

    if (!out.has_server_port && !out.interleaved) {
        if (err) *err = "SETUP Transport 头未提供有效的 server_port: " + header;
        return false;
    }
    // 缺省推导：server_port 的 a-b 里 b 就是 control；否则 audio+1；timing 在 control+1。
    if (out.control_port == 0) {
        if (range_second != 0) out.control_port = range_second;
        else if (out.server_port != 0 && out.server_port < 65535) out.control_port = static_cast<uint16_t>(out.server_port + 1);
    }
    if (out.timing_port == 0) {
        if (out.control_port != 0 && out.control_port < 65535) out.timing_port = static_cast<uint16_t>(out.control_port + 1);
        else if (out.server_port != 0 && out.server_port < 65534) out.timing_port = static_cast<uint16_t>(out.server_port + 2);
    }
    return true;
}

// ---------------------------------------------------------------- RTSP 响应（有界增量解析）
constexpr size_t kMaxRtspHeaderBytes = 16 * 1024;
constexpr size_t kMaxRtspBodyBytes = 64 * 1024;

struct RtspResponse {
    int status_code = 0;
    std::string status_text;
    std::string first_line;
    int cseq = -1;                       // -1 = 响应里没有 CSeq
    std::string session;                 // 去掉 ;timeout=..
    std::string transport;
    std::string audio_latency;           // RECORD 回包的 Audio-Latency（设备自报延迟）
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body;

    std::string get_header(const std::string& name) const {
        const std::string want = transport_detail::lower(name);
        for (const auto& h : headers) {
            if (transport_detail::lower(h.first) == want) return h.second;
        }
        return std::string();
    }
};

enum class ParseState { NeedMore, Complete, Error };

namespace rtsp_detail {

inline bool parse_uint_bounded(const std::string& s, size_t maxValue, size_t& out) {
    if (s.empty() || s.size() > 12) return false;
    size_t v = 0;
    for (char c : s) {
        if (c < '0' || c > '9') return false;
        v = v * 10 + static_cast<size_t>(c - '0');
        if (v > maxValue) return false;
    }
    out = v;
    return true;
}

inline bool parse_int_header(const std::string& s, int& out) {
    if (s.empty() || s.size() > 10) return false;
    int sign = 1;
    size_t i = 0;
    if (s[0] == '-') { sign = -1; i = 1; }
    if (i >= s.size()) return false;
    long v = 0;
    for (; i < s.size(); ++i) {
        if (s[i] < '0' || s[i] > '9') return false;
        v = v * 10 + (s[i] - '0');
        if (v > 1000000000L) return false;
    }
    out = static_cast<int>(sign * v);
    return true;
}

}  // namespace rtsp_detail

// 从 buf 头部解析一个完整响应。consumed 返回消费掉的字节数。
// 超出头部/正文上限一律 Error（绝不无限增长缓冲）。
inline ParseState parse_rtsp_response(const std::string& buf, RtspResponse& out,
                                      size_t& consumed, std::string* err) {
    consumed = 0;
    out = RtspResponse{};
    size_t headerEnd = buf.find("\r\n\r\n");
    size_t sepLen = 4;
    if (headerEnd == std::string::npos) {
        headerEnd = buf.find("\n\n");
        sepLen = 2;
    }
    if (headerEnd == std::string::npos) {
        if (buf.size() > kMaxRtspHeaderBytes) {
            if (err) *err = "RTSP 响应头超过上限 " + std::to_string(kMaxRtspHeaderBytes) + " 字节";
            return ParseState::Error;
        }
        return ParseState::NeedMore;
    }
    if (headerEnd > kMaxRtspHeaderBytes) {
        if (err) *err = "RTSP 响应头超过上限 " + std::to_string(kMaxRtspHeaderBytes) + " 字节";
        return ParseState::Error;
    }

    const std::string headerPart = buf.substr(0, headerEnd);
    size_t lineStart = 0;
    bool haveStatusLine = false;
    size_t contentLength = 0;
    bool hasContentLength = false;

    while (lineStart <= headerPart.size()) {
        size_t nl = headerPart.find('\n', lineStart);
        if (nl == std::string::npos) nl = headerPart.size();
        std::string line = headerPart.substr(lineStart, nl - lineStart);
        lineStart = nl + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;

        if (!haveStatusLine) {
            haveStatusLine = true;
            out.first_line = line;
            // 形如 "RTSP/1.0 200 OK"（协议名大小写不敏感，只接受 RTSP/）。
            if (line.size() < 12) {
                if (err) *err = "RTSP 状态行过短: " + line;
                return ParseState::Error;
            }
            std::string proto = transport_detail::lower(line.substr(0, 5));
            if (proto != "rtsp/") {
                if (err) *err = "RTSP 状态行协议名非法: " + line;
                return ParseState::Error;
            }
            // 跳过版本号
            size_t sp1 = line.find(' ');
            if (sp1 == std::string::npos) {
                if (err) *err = "RTSP 状态行缺少状态码: " + line;
                return ParseState::Error;
            }
            size_t codeStart = sp1;
            while (codeStart < line.size() && line[codeStart] == ' ') ++codeStart;
            if (codeStart + 3 > line.size()) {
                if (err) *err = "RTSP 状态行缺少状态码: " + line;
                return ParseState::Error;
            }
            for (int i = 0; i < 3; ++i) {
                const char c = line[codeStart + static_cast<size_t>(i)];
                if (c < '0' || c > '9') {
                    if (err) *err = "RTSP 状态码非数字: " + line;
                    return ParseState::Error;
                }
            }
            out.status_code = (line[codeStart] - '0') * 100 + (line[codeStart + 1] - '0') * 10 +
                              (line[codeStart + 2] - '0');
            size_t textStart = codeStart + 3;
            while (textStart < line.size() && line[textStart] == ' ') ++textStart;
            out.status_text = line.substr(textStart);
            continue;
        }

        const size_t colon = line.find(':');
        if (colon == std::string::npos) {
            // 折行续行（以空白开头）：接到上一个头的值后面，不当作独立字段。
            if ((line[0] == ' ' || line[0] == '\t') && !out.headers.empty()) {
                out.headers.back().second += " " + transport_detail::trim_copy(line);
                continue;
            }
            if (err) *err = "RTSP 响应头行缺少冒号: " + line.substr(0, 80);
            return ParseState::Error;
        }
        const std::string key = transport_detail::trim_copy(line.substr(0, colon));
        const std::string value = transport_detail::trim_copy(line.substr(colon + 1));
        if (key.empty()) {
            if (err) *err = "RTSP 响应头字段名为空";
            return ParseState::Error;
        }
        out.headers.push_back({key, value});
        const std::string lowerKey = transport_detail::lower(key);
        if (lowerKey == "cseq") {
            int v = 0;
            if (!rtsp_detail::parse_int_header(value, v) || v < 0) {
                if (err) *err = "RTSP CSeq 非法: " + value;
                return ParseState::Error;
            }
            out.cseq = v;
        } else if (lowerKey == "session") {
            const size_t semi = value.find(';');
            out.session = transport_detail::trim_copy(semi == std::string::npos ? value : value.substr(0, semi));
        } else if (lowerKey == "transport") {
            out.transport = value;
        } else if (lowerKey == "audio-latency") {
            out.audio_latency = value;
        } else if (lowerKey == "content-length") {
            if (!rtsp_detail::parse_uint_bounded(value, kMaxRtspBodyBytes, contentLength)) {
                if (err) *err = "RTSP Content-Length 非法或超过上限: " + value;
                return ParseState::Error;
            }
            hasContentLength = true;
        }
    }
    if (!haveStatusLine) {
        if (err) *err = "RTSP 响应为空";
        return ParseState::Error;
    }

    const size_t totalNeeded = headerEnd + sepLen + (hasContentLength ? contentLength : 0);
    if (buf.size() < totalNeeded) return ParseState::NeedMore;
    if (hasContentLength && contentLength > 0) {
        out.body = buf.substr(headerEnd + sepLen, contentLength);
    }
    consumed = totalNeeded;
    return ParseState::Complete;
}

// RTSP 连接上可能夹带 0x24 交织帧（$ channel len16be payload）。
// 解析响应前先把它们跳掉；帧头声明超大长度视为错误（有界）。
enum class InterleavedSkip { None, Skipped, NeedMore, Invalid };

// 交织帧的长度上限：RAOP 音频帧约 1.4 KB，8 KB 已经非常宽松；
// 超过这个数说明帧头被写坏了，必须报错而不是照着它去缓冲几十 KB。
constexpr size_t kMaxInterleavedFrameBytes = 8 * 1024;

inline InterleavedSkip skip_interleaved_frames(std::string& buf,
                                               size_t maxFrameBytes = kMaxInterleavedFrameBytes) {
    bool skippedAny = false;
    while (!buf.empty() && static_cast<uint8_t>(buf[0]) == 0x24) {
        if (buf.size() < 4) return skippedAny ? InterleavedSkip::Skipped : InterleavedSkip::NeedMore;
        const size_t len = (static_cast<size_t>(static_cast<uint8_t>(buf[2])) << 8) |
                           static_cast<uint8_t>(buf[3]);
        if (len > maxFrameBytes) return InterleavedSkip::Invalid;
        if (buf.size() < 4 + len) return skippedAny ? InterleavedSkip::Skipped : InterleavedSkip::NeedMore;
        buf.erase(0, 4 + len);
        skippedAny = true;
    }
    return skippedAny ? InterleavedSkip::Skipped : InterleavedSkip::None;
}

}  // namespace rta::net::raop
