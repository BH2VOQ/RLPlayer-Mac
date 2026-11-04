// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// raop_session.h — AirPlay (RAOP) 投放会话管理 (RTSP/RTP)
//
// ── 1.1.2 修正说明（2026-11-04）───────────────────────────────────────────────
// 旧实现有四处**协议级**错误，真机表现为“能连上、声音抖、偶发断”：
//   1) sync 包的 [4..7] 与 [16..19] 填了同一个值 ⟹ 等于向接收端宣告“零缓冲”，
//      接收端按“此刻就要出声”调度，任何调度抖动都变成欠载/追帧（听感抖动）；
//   2) RTP 时间轴锚点建立在“第一个包写出的时刻”，还把 lead 从播放位置里减掉、
//      前 0.6 秒夹住——映射既不单调也不连续，接收端据此估出的帧率直接超界；
//   3) timing 应答把请求的 origin 字段回显到 origin，而 NTP 语义要求回显请求的 transmit；
//   4) 完全没有处理 control 端口的 NACK（0x55），丢一个包就是一段坏音频。
// 现在：时间轴由**单调时钟**唯一决定（与写包节奏、暂停无关），latency 与 prebuffer
// 分开配置，sync 字段按参考实现逐字节填对；control 端口回 NACK 重传原 ALAC 载荷；
// 所有 RTSP/UDP 解析都有上限；状态在 open/close 时彻底复位。
//
// ── 1.1.2 复核修正（2026-11-04，第四轮）─────────────────────────────────────
// 复审发现四处会在真机上直接出问题的地方，逐条修：
//   1) NACK 重传发的是**裸 0x60 音频包**且发去 audio 端口。参考实现 rtp.c:421 只认
//      control 端口上的 0xD6（= 4 字节重传头 + 原 12 字节 RTP 头 + 原载荷）；
//      现在按 0xD6 封装、回 control 端口，并校验请求来源（防伪造放大）。
//   2) set_paused(true) 以前会 join 掉 timing 线程 ⟹ 暂停期间不再回对端 0xD2 时钟请求，
//      对端失锁。现在 timing 线程整个会话生命周期都在跑，暂停只抑制 sync。
//      暂停仍发 FLUSH（听感立即静音），但**不再丢未发出的输入**；恢复时用有界重传缓存
//      按原 seq/rtptime 把“已发未播”的在途窗口重发回来，所以既不跳音也不丢源帧。
//   3) open() 的 openDeadlineMs 以前管不到 getaddrinfo 与多地址遍历。现在预算透传到
//      解析/连接/每条 RTSP 请求；域名解析改成 dns_sd（Bonjour）异步查询 + 有界轮询，
//      不新建后台线程、不留悬空引用；数字 IP 直接跳过解析。
//   4) 瞬时 UDP 错误（EAGAIN/EWOULDBLOCK/ENOBUFS/EINTR）以前会被当成连续致命失败，
//      3 个包就把会话锁死。现在同一包在有限预算内 poll 重试（序号不前进），
//      SO_SNDBUF 提到 256 KB；永久错误仍然如实上报。worker 自己控制节奏，
//      协议层不再额外加节流。
//
// 真机（shairport-sync 3.3.8）行为依据见 raop_protocol.h 顶部注释。
#pragma once

#include "net/raop_packet_cache.h"
#include "net/raop_protocol.h"

// 真实 ALAC 编码器是硬依赖：**不再提供假 ALAC 回退**。
// 旧的 stub 把原始 PCM 前面加 3 个假字节当 ALAC 发出去，接收端只会放出噪声/静音，
// 却让“握手成功”看起来像“投放成功”。宁可构建期失败，也不要静默的错误音频。
#if __has_include("audio/alac_encoder.h")
#include "audio/alac_encoder.h"
#elif __has_include("../audio/alac_encoder.h")
#include "../audio/alac_encoder.h"
#else
#error "RAOP 需要真实 ALAC 编码器 src/audio/alac_encoder.h；不允许假 ALAC 回退"
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <iomanip>
#include <limits>
#include <memory>
#include <mutex>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

// 域名解析：macOS 用 dns_sd（mDNSResponder）的异步接口，.local 的 mDNS 与普通 DNS
// 都走它，且可以 poll 自己的 fd、随时 DNSServiceRefDeallocate 取消——不阻塞、不留线程。
#if defined(__APPLE__) && __has_include(<dns_sd.h>)
#include <dns_sd.h>
#define RTA_RAOP_HAS_DNS_SD 1
#else
#define RTA_RAOP_HAS_DNS_SD 0
#endif

namespace rta::net {

// AirPlay 1 / RAOP 的固定音频格式：44100 Hz、16 bit、ALAC 每包 352 帧。
constexpr uint32_t kRaopSampleRate = 44100;
constexpr int kRaopFramesPerPacket = 352;
// AirPlay 默认播放缓冲 2.0 s（88200 帧）：与 shairport-sync 的默认 latency 一致。
constexpr uint32_t kRaopDefaultLatencyFrames = 88200;
// 时间轴开始前的余量：给上层解码/首批写入留时间，避免接收端“到场即迟到”。
constexpr double kRaopDefaultPrebufferSeconds = 0.35;
// sync 包发送周期。参考实现要用相邻两个 sync 估算帧率，500 ms 足够稳。
constexpr int kRaopSyncIntervalMs = 500;

struct RaopConfig {
    std::string host;               // IP 或 DNS 名
    uint16_t    port = 5000;        // RTSP 端口
    uint32_t    sampleRate = 44100;
    int         channels = 2;
    int         bits = 16;
    std::string deviceId;           // 诊断用（host:port 也可）
    std::string sessionName = "RLPlayer";
    bool        needsEncryption = false; // 调用方**确证**需要 RSA 加密时才置 true
    // ↓ 1.1.2 新增的可选字段（都有默认值；按字段名赋值的现有调用方无需改动）
    int         rtspTimeoutMs = 1500;    // 单条 RTSP 请求/响应的总时限
    uint32_t    latencyFrames = 0;       // 0 = kRaopDefaultLatencyFrames
    double      prebufferSeconds = -1.0; // <0 = kRaopDefaultPrebufferSeconds
    int         maxOpenAttempts = 3;     // 453（接收端仍认为旧会话存在）重试次数上限
    int         openDeadlineMs = 6000;   // 整个 open() 的总时限，含重试与退避
};

// ── 预检：能不能连、为什么不能 ────────────────────────────────────────────────
// 明确区分“设备支持 RSA 配对”（TXT pk= 非空）与“本次必须加密”。
// pk= 只说明设备带公钥，不构成“必须加密”的证据：本端仍以明文 ANNOUNCE（不带
// rsaaeskey）尝试；若接收端真的要求加密，会在 ANNOUNCE 阶段以真实状态码失败。
struct RaopPreflightInput {
    bool hasPublicKey = false;                // 发现阶段 TXT pk= 非空
    bool passwordRequired = false;            // TXT pw=1/true
    bool explicitEncryptionRequired = false;  // 调用方从别处确证必须 RSA 加密
    bool receiverNeedsAirPlay2 = false;       // 只支持 AirPlay 2 / PTP 的设备
};

struct RaopPreflightResult {
    bool ok = false;
    bool requiresEncryption = false;
    bool requiresPassword = false;
    std::string reason;      // 中文，可直接进 UI
    std::string reasonEn;    // 同一事实的英文
    std::string note;        // 不阻断的提示（例如 pk= 存在但不足以判定必须加密）
};

inline RaopPreflightResult preflight_raop(const RaopPreflightInput& in) {
    RaopPreflightResult r;
    if (in.passwordRequired) {
        r.requiresPassword = true;
        r.reason = "该接收端要求输入密码；本版本 AirPlay 投放未实现密码认证";
        r.reasonEn = "This receiver requires a password; password authentication is not implemented for AirPlay casting";
        return r;
    }
    if (in.explicitEncryptionRequired) {
        r.requiresEncryption = true;
        r.reason = "该接收端要求 AirPlay 1 RSA 加密；本版本未实现，无法投放";
        r.reasonEn = "This receiver requires AirPlay 1 RSA encryption, which is not implemented";
        return r;
    }
    if (in.receiverNeedsAirPlay2) {
        r.reason = "该接收端只支持 AirPlay 2（PTP 时钟），不支持本版本的 AirPlay 1 (RAOP) 投放";
        r.reasonEn = "This receiver only supports AirPlay 2 (PTP), not AirPlay 1 (RAOP)";
        return r;
    }
    r.ok = true;
    if (in.hasPublicKey) {
        r.note = "设备公布了 pk=（支持 RSA 配对）；这不代表本次必须加密，仍按明文尝试";
    }
    return r;
}

// 解析结果（解析阶段一次性取得；连接、UDP 目标、来源校验都用同一份，绝不再二次阻塞解析）。
struct RaopEndpoint {
    struct sockaddr_storage addr {};
    socklen_t len = 0;
    int family = AF_INET;
};

// ── 运行时健康/诊断 ───────────────────────────────────────────────────────────
struct RaopHealth {
    bool open = false;
    bool transport_failed = false;
    bool interleaved = false;
    bool timing_thread = false;
    bool control_thread = false;
    bool paused = false;
    uint32_t sample_rate = kRaopSampleRate;
    uint32_t latency_frames = 0;
    double prebuffer_seconds = 0.0;
    uint64_t packets_sent = 0;
    uint64_t bytes_sent = 0;
    uint64_t sync_sent = 0;
    uint64_t timing_requests = 0;
    uint64_t timing_replies = 0;
    uint64_t timing_malformed = 0;
    uint64_t nack_requests = 0;
    uint64_t retransmits = 0;
    uint64_t nack_misses = 0;
    uint64_t nack_rejected = 0;      // 来源不在允许范围（防伪造放大）而被丢弃的请求
    uint64_t send_errors = 0;
    uint64_t send_retries = 0;       // 瞬时错误（EAGAIN/ENOBUFS…）后重试成功的次数
    uint64_t resume_replays = 0;     // 暂停恢复时重发的在途音频包数
    uint64_t resolver_calls = 0;     // 真正走了域名解析的次数（数字 IP 为 0）
    uint64_t late_packets = 0;       // 写包时已经晚于时间轴（接收端要丢的那个）
    int64_t min_ahead_frames = 0;    // 发送领先量最小值（负 = 迟到）
    int64_t last_ahead_frames = 0;
    int last_errno = 0;
    uint32_t last_sync_rtp = 0;
    uint64_t last_sync_ntp = 0;
    std::string last_error;
};

class RaopSession {
public:
    RaopSession() {
        std::random_device rd;
        rng_.seed((static_cast<uint64_t>(rd()) << 32) ^ static_cast<uint64_t>(rd()));
        encoder_ = std::make_unique<rta::audio::AlacEncoder>();
        prebufferSeconds_ = kRaopDefaultPrebufferSeconds;
        latencyFrames_ = kRaopDefaultLatencyFrames;
    }

    ~RaopSession() { close(); }

    RaopSession(const RaopSession&) = delete;
    RaopSession& operator=(const RaopSession&) = delete;

    // 允许外部注入自定义编码器（例如主控的 AudioToolbox AlacEncoder 变体）。
    // 传空指针等价于恢复默认的真实编码器；假编码器永远不会被使用。
    void set_encoder(std::unique_ptr<rta::audio::AlacEncoder> enc) {
        encoder_ = enc ? std::move(enc) : std::make_unique<rta::audio::AlacEncoder>();
    }

    // ── 仅测试用的注入点（默认空 = 生产路径）────────────────────────────────
    // 解析注入：默认走 dns_sd；测试用它把"域名"映射到假接收端，或确定性地模拟解析失败。
    // UDP 发送注入：默认 ::sendto；测试用它确定性地制造 ENOBUFS/EAGAIN 与永久错误。
    // 两者都必须在 open() 之前设置（运行期不再改动，内部不加锁）。
    using ResolveHook = std::function<bool(const std::string& host, uint16_t port,
                                           std::vector<RaopEndpoint>& out, std::string* err)>;
    using UdpSendHook = std::function<ssize_t(int fd, const void* data, size_t len,
                                              const struct sockaddr* to, socklen_t tolen,
                                              int* outErrno)>;
    void set_resolve_hook(ResolveHook hook) { resolveHook_ = std::move(hook); }
    void set_udp_send_hook(UdpSendHook hook) { udpSendHook_ = std::move(hook); }

    // ── 会话建立 ────────────────────────────────────────────────────────────
    // 只在接收端返回 453（它仍认为上一个会话存在）时重试，次数与总时长都有上限；
    // 状态码来自结构化解析，绝不靠错误字符串里“包含 453”判断。
    bool open(const RaopConfig& cfgIn, std::string* err) {
        const RaopConfig cfg = sanitize_config(cfgIn);
        const int attempts = std::max(1, std::min(cfg.maxOpenAttempts, 8));
        const auto deadline = std::chrono::steady_clock::now() +
                              std::chrono::milliseconds(std::max(0, cfg.openDeadlineMs));
        std::string lastErr;
        int done = 0;
        for (int attempt = 0; attempt < attempts; ++attempt) {
            std::string e;
            if (open_once(cfg, deadline, &e)) return true;
            lastErr = e;
            ++done;
            if (!lastFailure_.retryable) break;
            if (attempt + 1 >= attempts) break;
            const auto backoff = std::chrono::milliseconds(250 * (attempt + 1));
            if (std::chrono::steady_clock::now() + backoff >= deadline) break;
            std::this_thread::sleep_for(backoff);
        }
        if (err) {
            *err = lastErr;
            if (done > 1) {
                *err += "（接收端一直认为上一个会话仍在，已尝试 " + std::to_string(done) + " 次）";
            }
        }
        return false;
    }

    bool open_once(const RaopConfig& cfgIn, std::string* err) {
        const RaopConfig cfg = sanitize_config(cfgIn);
        return open_once(cfg, std::chrono::steady_clock::now() +
                                 std::chrono::milliseconds(std::max(0, cfg.openDeadlineMs)),
                         err);
    }

    // deadline 是**绝对**单调时刻：解析、多地址连接、每条 RTSP 请求的等待都必须落在它之内。
    bool open_once(const RaopConfig& cfgIn, std::chrono::steady_clock::time_point deadline,
                   std::string* err) {
        reset_all();
        cfg_ = cfgIn;
        lastFailure_ = Failure{};
        openDeadline_ = deadline;
        // 作用域守卫：open_once 的每条返回路径（含 close() 期间）都能自动解除预算钳制，
        // 否则一次 open 失败后，之后的 flush/set_volume 会被误按 open 预算截断。
        const DeadlineGuard deadlineGuard(openDeadlineActive_);

        if (cfg_.needsEncryption) {
            if (err) *err = "AirPlay 1 RSA 加密暂不支持";
            lastFailure_.stage = "PREFLIGHT";
            return false;
        }
        if (cfg_.host.empty()) {
            if (err) *err = "无效的目标主机地址";
            return false;
        }
        if (cfg_.channels != 1 && cfg_.channels != 2) {
            if (err) *err = "RAOP 只支持 1 或 2 声道（当前 " + std::to_string(cfg_.channels) + "）";
            return false;
        }
        if (cfg_.bits != 16) {
            if (err) *err = "RAOP 只支持 16 bit 采样（当前 " + std::to_string(cfg_.bits) + "）";
            return false;
        }
        if (cfg_.sampleRate < 8000 || cfg_.sampleRate > 192000) {
            if (err) *err = "RAOP 采样率非法: " + std::to_string(cfg_.sampleRate) +
                            "（支持 8000…192000）";
            return false;
        }
        if (!std::isfinite(cfg_.prebufferSeconds)) {
            if (err) *err = "prebufferSeconds 必须是有限数（当前不是）";
            return false;
        }
        if (cfg_.latencyFrames != 0) {
            const uint32_t maxFrames = cfg_.sampleRate * 10u;   // 最长 10 s 播放缓冲
            latencyFrames_ = std::min(std::max<uint32_t>(cfg_.latencyFrames, 352), maxFrames);
        }
        if (cfg_.prebufferSeconds >= 0.0) prebufferSeconds_ = cfg_.prebufferSeconds;
        if (latencyFrames_ < 352) latencyFrames_ = 352;
        if (latencyFrames_ > cfg_.sampleRate * 10u) latencyFrames_ = cfg_.sampleRate * 10u;

        if (!encoder_) encoder_ = std::make_unique<rta::audio::AlacEncoder>();
        std::string encErr;
        if (!encoder_->init(cfg_.sampleRate, cfg_.channels, cfg_.bits, kRaopFramesPerPacket, &encErr)) {
            if (err) *err = "初始化 ALAC 编码器失败: " + encErr;
            return false;
        }
        framesPerPacket_ = encoder_->frames_per_packet();
        if (framesPerPacket_ != kRaopFramesPerPacket) {
            if (err) *err = "ALAC 编码器每包帧数必须是 352（当前 " + std::to_string(framesPerPacket_) + "）";
            return false;
        }

        // 每次会话一套全新的 RTP 随机数：同一进程里重开不会复用旧 SSRC/序号（接收端会当成重复包）。
        rtpSeq_ = static_cast<uint16_t>(rng_());
        rtpTimestamp_ = static_cast<uint32_t>(rng_());
        rtpSsrc_ = static_cast<uint32_t>(rng_());
        if (rtpSsrc_ == 0) rtpSsrc_ = 0x5A5A5A5Au;   // 0 不是合法 SSRC，避免概率性异常
        sessionId_ = std::to_string(1000000000ull + (rng_() % 900000000ull));

        if (!connect_tcp(cfg_.host, cfg_.port, deadline, err)) {
            close();
            return false;
        }
        if (!setup_local_udp_sockets(err)) {
            close();
            return false;
        }

        raop::RtspResponse resp;
        // (1) OPTIONS
        {
            std::string req = "OPTIONS * RTSP/1.0\r\n"
                              "CSeq: " + std::to_string(++cseq_) + "\r\n"
                              "User-Agent: RLPlayer/1.1.2\r\n"
                              "Client-Instance: " + clientInstance() + "\r\n\r\n";
            if (!send_rtsp_and_recv(req, cseq_, resp, err, "OPTIONS")) {
                close();
                return false;
            }
            record_handshake("OPTIONS " + std::to_string(resp.status_code));
        }

        // (2) ANNOUNCE
        const std::string localIp = get_local_ip_str();
        const std::string ipFamilyStr = (localFamily_ == AF_INET6) ? "IP6" : "IP4";
        std::ostringstream sdp;
        sdp << "v=0\r\n"
            << "o=iTunes " << sessionId_ << " 0 IN " << ipFamilyStr << " " << cfg_.host << "\r\n"
            << "s=iTunes\r\n"
            << "c=IN " << ipFamilyStr << " " << localIp << "\r\n"
            << "t=0 0\r\n"
            << "m=audio 0 RTP/AVP 96\r\n"
            << "a=rtpmap:96 AppleLossless\r\n"
            // 第 7 个字段是 ALAC 的声道数：以前写死 2，单声道源会被接收端按立体声解，
            // 声音速度/音高都错。这里跟随实际配置。
            << "a=fmtp:96 " << kRaopFramesPerPacket << " 0 16 40 10 14 " << cfg_.channels
            << " 255 0 0 " << cfg_.sampleRate << "\r\n";
        const std::string sdpStr = sdp.str();
        const std::string announceUri =
            "rtsp://" + cfg_.host + ":" + std::to_string(cfg_.port) + "/" + sessionId_;
        {
            std::ostringstream announceReq;
            announceReq << "ANNOUNCE " << announceUri << " RTSP/1.0\r\n"
                        << "CSeq: " << (++cseq_) << "\r\n"
                        << "Content-Type: application/sdp\r\n"
                        << "Content-Length: " << sdpStr.size() << "\r\n"
                        << "User-Agent: RLPlayer/1.1.2\r\n\r\n"
                        << sdpStr;
            if (!send_rtsp_and_recv(announceReq.str(), cseq_, resp, err, "ANNOUNCE")) {
                close();
                return false;
            }
            record_handshake("ANNOUNCE " + std::to_string(resp.status_code));
        }

        // (3) SETUP：请求里带交织（真机回包会带上，但音频仍走 UDP 的 server_port）
        {
            std::ostringstream setupReq;
            setupReq << "SETUP " << announceUri << " RTSP/1.0\r\n"
                     << "CSeq: " << (++cseq_) << "\r\n"
                     << "Transport: RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port="
                     << localControlPort_ << ";timing_port=" << localTimingPort_ << "\r\n"
                     << "User-Agent: RLPlayer/1.1.2\r\n\r\n";
            if (!send_rtsp_and_recv(setupReq.str(), cseq_, resp, err, "SETUP")) {
                close();
                return false;
            }
            serverSessionId_ = resp.session;
            raop::TransportInfo ti;
            if (!raop::parse_transport(resp.transport, ti, err)) {
                close();
                return false;
            }
            interleaved_ = ti.interleaved;
            serverAudioPort_ = ti.server_port;
            serverControlPort_ = ti.control_port;
            serverTimingPort_ = ti.timing_port;
            update_device_latency(resp);
            record_handshake("SETUP " + std::to_string(resp.status_code) + " transport=[" +
                             resp.transport + "] ports=" + std::to_string(serverAudioPort_) + "," +
                             std::to_string(serverControlPort_) + "," +
                             std::to_string(serverTimingPort_));
        }

        if (!setup_server_audio_addr(err)) {
            close();
            return false;
        }

        // (4) RECORD：RTP-Info 里的 seq/rtptime 必须与随后第一个包**逐位一致**。
        {
            std::ostringstream recReq;
            recReq << "RECORD " << announceUri << " RTSP/1.0\r\n"
                   << "CSeq: " << (++cseq_) << "\r\n";
            if (!serverSessionId_.empty()) recReq << "Session: " << serverSessionId_ << "\r\n";
            recReq << "Range: npt=0-\r\n"
                   << "RTP-Info: seq=" << rtpSeq_ << ";rtptime=" << rtpTimestamp_ << "\r\n"
                   << "User-Agent: RLPlayer/1.1.2\r\n\r\n";
            if (!send_rtsp_and_recv(recReq.str(), cseq_, resp, err, "RECORD")) {
                close();
                return false;
            }
            update_device_latency(resp);
            record_handshake("RECORD " + std::to_string(resp.status_code));
        }
        recorded_ = true;

        // 时间轴锚点：锚在这个单调时刻 + prebuffer 上，与“第几个包什么时候写”无关。
        const auto now = std::chrono::steady_clock::now();
        {
            std::lock_guard<std::mutex> lk(anchorMtx_);
            openSteady_ = now;
            anchorRtp_ = rtpTimestamp_;
            anchorTime_ = now + prebufferDurationLocked();
            timelineStarted_ = false;
            lastSyncSteady_ = std::chrono::steady_clock::time_point{};
        }

        isOpen_ = true;
        transportFailed_.store(false);
        timingRun_.store(true);
        controlRun_.store(true);
        timingThread_ = std::thread([this]() { timing_loop(); });
        controlThread_ = std::thread([this]() { control_loop(); });
        return true;
    }

    // ── 音频写入 ─────────────────────────────────────────────────────────────
    // Detect a closed RTSP control channel even while UDP sendto still succeeds.
    // This is a local socket observation, not proof that a receiver has rendered audio.
    bool check_connection(std::string* err = nullptr) {
        if (!isOpen_) { if (err) *err = "RAOP 会话未打开"; return false; }
        if (transportFailed_.load()) { if (err) *err = lastErrorText(); return false; }
        pollfd pfd{};
        pfd.fd = tcpFd_;
        pfd.events = POLLIN;
        const int rc = ::poll(&pfd, 1, 0);
        if (rc > 0) {
            bool closed = (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0;
            if (!closed && (pfd.revents & POLLIN)) {
                uint8_t byte = 0;
                const ssize_t n = ::recv(tcpFd_, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
                closed = n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR);
            }
            if (closed) {
                note_error("AirPlay 传输失败：接收端已关闭控制连接", ECONNRESET);
                sendErrors_.fetch_add(1);
                transportFailed_.store(true);
                if (err) *err = lastErrorText();
                return false;
            }
        }
        return true;
    }

    bool write_pcm(const int16_t* interleaved, size_t frames, std::string* err) {
        if (!check_connection(err)) return false;
        if (!isOpen_) {
            if (err) *err = "RAOP 会话未建立或已关闭";
            return false;
        }
        if (transportFailed_.load()) {
            if (err) *err = "RAOP 传输已失败: " + lastErrorText();
            return false;
        }
        if (!interleaved || frames == 0) return true;
        if (cfg_.channels <= 0) {
            if (err) *err = "RAOP 声道数非法";
            return false;
        }

        const size_t chan = static_cast<size_t>(cfg_.channels);
        // 两个乘法都要防溢出：frames*chan 与 (rate*30)*chan 都可能被异常入参顶出 size_t。
        if (frames > std::numeric_limits<size_t>::max() / chan) {
            if (err) *err = "RAOP 写入帧数过大（frames*channels 溢出）";
            return false;
        }
        const size_t incoming = frames * chan;
        const size_t rate = cfg_.sampleRate ? static_cast<size_t>(cfg_.sampleRate) : kRaopSampleRate;
        if (rate <= std::numeric_limits<size_t>::max() / kMaxPendingSeconds / chan) {
            const size_t maxPending = rate * kMaxPendingSeconds * chan;
            const size_t buffered = pendingPcm_.size() - pendingOffset_;
            // 先比 incoming 再做减法：否则 buffered + incoming 回绕会绕过上限检查。
            if (incoming > maxPending || buffered > maxPending - incoming) {
                if (err) *err = "RAOP 待发缓冲超过 " + std::to_string(kMaxPendingSeconds) +
                                " s 上限（写包远超实时？）";
                return false;
            }
        }
        pendingPcm_.insert(pendingPcm_.end(), interleaved, interleaved + incoming);
        const size_t samplesPerPacket = static_cast<size_t>(framesPerPacket_) * chan;

        while (pendingPcm_.size() - pendingOffset_ >= samplesPerPacket) {
            if (!emit_audio_packet(pendingPcm_.data() + pendingOffset_, err)) return false;
            pendingOffset_ += samplesPerPacket;
            update_ahead();
            maybe_sync();
        }

        // 消费掉的前缀及时回收：长播放下 vector 不能无限长。
        if (pendingOffset_ > 0 &&
            (pendingOffset_ == pendingPcm_.size() || pendingOffset_ > samplesPerPacket * 16)) {
            pendingPcm_.erase(pendingPcm_.begin(),
                              pendingPcm_.begin() + static_cast<long>(pendingOffset_));
            pendingOffset_ = 0;
        }
        return true;
    }

    size_t pending_frames() const {
        if (cfg_.channels <= 0) return 0;
        const size_t off = std::min(pendingOffset_, pendingPcm_.size());
        return (pendingPcm_.size() - off) / static_cast<size_t>(cfg_.channels);
    }

    // EOS：把不足一包的尾部用静音补齐后发出（ALAC 每包固定 352 帧）。
    // 不补的话最后最多 351 帧（≈8 ms）会被静默丢掉。
    bool finish(std::string* err) {
        if (!isOpen_) {
            if (err) *err = "RAOP 会话未建立或已关闭";
            return false;
        }
        const size_t chan = static_cast<size_t>(cfg_.channels);
        const size_t partialFrames = pending_frames();
        if (partialFrames == 0) return true;
        std::vector<int16_t> block(static_cast<size_t>(framesPerPacket_) * chan, 0);
        std::memcpy(block.data(), pendingPcm_.data() + pendingOffset_,
                    partialFrames * chan * sizeof(int16_t));
        const bool ok = emit_audio_packet(block.data(), err);
        pendingPcm_.clear();
        pendingOffset_ = 0;
        return ok;
    }

    // ── 控制类 RTSP ──────────────────────────────────────────────────────────
    bool set_volume_db(double db, std::string* err) {
        if (!isOpen_ || tcpFd_ < 0) {
            if (err) *err = "RAOP 会话未打开";
            return false;
        }
        if (!std::isfinite(db)) {
            if (err) *err = "音量必须是有限数";
            return false;
        }
        if (db < -144.0) db = -144.0;
        if (db > 0.0) db = 0.0;
        std::ostringstream body;
        body << std::fixed << std::setprecision(2) << "volume: " << db << "\r\n";
        return send_set_parameter(body.str(), err, "SET_PARAMETER volume");
    }

    bool set_progress(int64_t rtpTime, int64_t nowNtp, std::string* err) {
        if (!isOpen_ || tcpFd_ < 0) {
            if (err) *err = "RAOP 会话未打开";
            return false;
        }
        std::ostringstream body;
        body << "progress: " << rtpTime << "/" << nowNtp << "\r\n";
        return send_set_parameter(body.str(), err, "SET_PARAMETER progress");
    }

    // FLUSH：seek 语义——丢掉接收端缓冲、丢掉本地未发输入与重传缓存，时间轴重锚到“现在 + prebuffer”。
    void flush() {
        flush_wire(FlushKind::DiscardPending);
        if (isOpen_) reanchor_from(std::chrono::steady_clock::now());
    }

    // 显式重锚（seek / 久停后由上层调用，**不是**恢复播放）：下一个待发包成为时间轴起点。
    // 若当时处于暂停，等价于 resume（解除暂停，sync 由常驻的 timing 线程继续发）。
    // 与 set_paused(false) 的区别：这里不复用暂停前的在途窗口（上层已经换了播放位置）。
    void reanchor() {
        if (!isOpen_) return;
        pauseWindowValid_ = false;
        paused_.store(false);
        reanchor_from(std::chrono::steady_clock::now());
    }

    // 暂停/恢复。
    // RAOP 1 没有 PAUSE 方法：唯一的“暂停”是 FLUSH（让对端立刻静音）＋停止喂数据，
    // 恢复时把时间轴重锚到“现在 + prebuffer”，否则恢复后的音频在对端看来全是迟到包。
    //
    // 与旧实现的两点关键区别：
    //   1) **绝不销毁 timing 线程**：它同时负责应答对端每 ~3 s 一次的 NTP 0xD2 请求。
    //      以前暂停就 join 掉它，对端几秒内就判定时钟 ping 丢失、时间基准漂移，
    //      恢复播放时直接断音。现在暂停只抑制 sync（maybe_sync 里判 paused_）。
    //   2) **不丢未发出的输入**：pendingPcm_ 原样保留；FLUSH 只清接收端缓冲。
    //      “已发未播”的在途窗口留在有界重传缓存里，恢复时按原 seq/rtptime 补发，
    //      所以恢复既不跳音也不丢源帧（worker 不需要回退读位置，接着写就行）。
    bool set_paused(bool paused, std::string* err = nullptr) {
        if (!isOpen_) {
            if (err) *err = "RAOP 会话未打开";
            return false;
        }
        if (paused == paused_.load()) return true;
        if (paused) {
            const auto now = std::chrono::steady_clock::now();
            uint32_t frozen = 0;
            {
                std::lock_guard<std::mutex> lk(anchorMtx_);
                frozen = current_rtp_locked(now);
                anchorRtp_ = frozen;
                anchorTime_ = now;
                timelineStarted_ = false;
                lastSyncSteady_ = std::chrono::steady_clock::time_point{};
            }
            paused_.store(true);          // 先冻结映射：timing 线程从此不再发 sync，但仍回 0xD2
            pauseWindowValid_ = true;
            // FLUSH 的 RTP-Info 用“包边界”：对端已播到 P，从 P 之后的第一个包边界开始丢，
            // 正在播的那个包放完为止（<=8 ms），不会出现重放或撕裂。
            const uint32_t startRtp = pause_window_start(frozen);
            pauseWindowStartRtp_ = startRtp;
            flush_wire(FlushKind::KeepPending);
            return true;
        }
        paused_.store(false);
        // 恢复的时间轴必须锚在**窗口起点**，而不是“下一个待发”：
        // 否则补发的包时间戳都早于新锚点，接收端会把它们当成迟到包直接丢掉。
        std::vector<raop::CachedRtpPacket> window;
        collect_pause_window(window);
        const auto now = std::chrono::steady_clock::now();
        reanchor_from(now, window.empty() ? rtpTimestamp_ : window.front().timestamp);
        send_pause_window(window);                         // 按原 seq/rtptime/载荷补发
        return true;
    }
    bool paused() const { return paused_.load(); }

    // 暂停期间 current_rtp_at() 报的是“已播到哪”（冻结值）；worker 用它显示进度即可。
    // 恢复后时间轴锚在**在途窗口起点**（= 恢复时补发的第一个包的原始时间戳），
    // 之后新写的包继续用 rtpTimestamp_，所以序号与时间戳全程连续、无空洞、无重复。

    // ── 关闭 ────────────────────────────────────────────────────────────────
    void close() {
        // 先停线程再动 fd：线程只在 poll 里等自己的 UDP 端口，100 ms 内退出，
        // 次序反了会出现“线程还在用已关闭的 fd”。
        isOpen_ = false;
        // close() 不属于 open() 的预算：先解除钳制，TEARDOWN 才有它自己的 350 ms
        openDeadlineActive_.store(false);
        timingRun_.store(false);
        controlRun_.store(false);
        join_thread(timingThread_);
        join_thread(controlThread_);

        // TEARDOWN 尽力而为 + 有时限：接收端不在线时绝不能让 close() 卡住上层。
        if (tcpFd_ >= 0 && recorded_) {
            recorded_ = false;
            std::ostringstream req;
            req << "TEARDOWN " << session_uri() << " RTSP/1.0\r\n"
                << "CSeq: " << (++cseq_) << "\r\n";
            if (!serverSessionId_.empty()) req << "Session: " << serverSessionId_ << "\r\n";
            req << "User-Agent: RLPlayer/1.1.2\r\n\r\n";
            raop::RtspResponse resp;
            std::string ignore;
            send_rtsp_and_recv(req.str(), cseq_, resp, &ignore, "TEARDOWN", 350);
        }

        close_fd(tcpFd_);
        close_fd(audioFd_);
        close_fd(controlFd_);
        close_fd(timingFd_);
        pendingPcm_.clear();
        pendingOffset_ = 0;
        tcpRecvBuf_.clear();
        cache_.clear();
        paused_.store(false);
        pauseWindowValid_ = false;
        peerAddrLen_ = 0;
        {
            std::lock_guard<std::mutex> lk(anchorMtx_);
            timelineStarted_ = false;
            lastSyncSteady_ = std::chrono::steady_clock::time_point{};
        }
    }

    // ── 查询 ────────────────────────────────────────────────────────────────
    bool is_open() const { return isOpen_.load(); }
    std::string last_handshake_summary() const { return handshakeLog_; }
    uint16_t server_audio_port() const { return serverAudioPort_; }
    uint16_t server_control_port() const { return serverControlPort_; }
    uint16_t server_timing_port() const { return serverTimingPort_; }
    uint16_t local_rtp_port() const { return localAudioPort_; }
    uint16_t local_control_port() const { return localControlPort_; }
    uint16_t local_timing_port() const { return localTimingPort_; }
    uint64_t packets_sent() const { return packetsSent_.load(); }
    uint64_t bytes_sent() const { return bytesSent_.load(); }
    uint64_t sync_packets_sent() const { return syncPacketsSent_.load(); }
    uint64_t timing_replies() const { return timingReplies_.load(); }
    uint64_t timing_requests() const { return timingRequests_.load(); }
    uint64_t nack_requests() const { return nackRequests_.load(); }
    uint64_t retransmits() const { return retransmits_.load(); }
    uint64_t nack_misses() const { return nackMisses_.load(); }
    uint64_t nack_rejected() const { return nackRejected_.load(); }
    uint64_t send_retries() const { return sendRetries_.load(); }
    uint64_t resume_replays() const { return resumeReplays_.load(); }
    uint64_t resolver_calls() const { return resolverCalls_.load(); }
    uint32_t device_audio_latency_frames() const { return deviceAudioLatencyFrames_; }
    bool interleaved() const { return interleaved_; }

    // 播放缓冲（会写进 sync 包的 current − delayed）。
    // 运行中改 latency 只影响下一条 sync 的 (current - delayed)，**不动时间轴**：
    // 重锚会让接收端的参考点跳到"待发位置"，把它缓冲里的音频判成迟到而丢弃。
    // 若要把延迟显著调大，应先 pause（FLUSH）再 resume，让缓冲区按新目标重建。
    void set_latency_frames(uint32_t frames) {
        std::lock_guard<std::mutex> lk(anchorMtx_);
        const uint32_t rate = cfg_.sampleRate ? cfg_.sampleRate : kRaopSampleRate;
        latencyFrames_ = std::min(std::max<uint32_t>(frames, 352), rate * 10u);
    }
    void set_latency_seconds(double sec) {
        if (!std::isfinite(sec) || sec <= 0.0) return;   // NaN/inf 一律忽略，不进时间轴
        const double rate = cfg_.sampleRate ? static_cast<double>(cfg_.sampleRate) : 44100.0;
        set_latency_frames(static_cast<uint32_t>(sec * rate + 0.5));
    }
    uint32_t latency_frames() const {
        std::lock_guard<std::mutex> lk(anchorMtx_);
        return latencyFrames_;
    }

    // prebuffer：时间轴起点相对 open() 的余量（给上层解码/首批写入留时间）。
    // 旧 API set_playback_lead_seconds 语义保留为“发送领先量”，在新模型里它就是 prebuffer：
    // 它不再被从播放位置里减掉（那正是旧的抖源），只决定时间轴何时开始。
    void set_prebuffer_seconds(double sec) {
        if (!std::isfinite(sec) || sec < 0.0) return;    // NaN/inf 一律忽略
        if (sec > 30.0) sec = 30.0;
        std::lock_guard<std::mutex> lk(anchorMtx_);
        prebufferSeconds_ = sec;
        if (!timelineStarted_ && isOpen_) {
            openSteady_ = std::chrono::steady_clock::now();
            anchorTime_ = openSteady_ + prebufferDurationLocked();
        }
    }
    void set_playback_lead_seconds(double sec) { set_prebuffer_seconds(sec); }
    double prebuffer_seconds() const {
        std::lock_guard<std::mutex> lk(anchorMtx_);
        return prebufferSeconds_;
    }

    // 立即发一条 sync。用途：reanchor()/恢复播放后马上把新的时间轴告诉接收端，
    // 不必等 500 ms 的周期。时间轴尚未开始时返回 false（此时没有“此刻在播什么”可报）。
    bool emit_sync_now(std::string* err = nullptr) {
        if (!isOpen_ || paused_.load()) {
            if (err) *err = "RAOP 会话未打开或已暂停";
            return false;
        }
        const auto now = std::chrono::steady_clock::now();
        {
            std::lock_guard<std::mutex> lk(anchorMtx_);
            if (now < anchorTime_) {
                if (err) *err = "时间轴尚未开始（还在 prebuffer 内）";
                return false;
            }
            timelineStarted_ = true;
        }
        return emit_sync(now);
    }

    // ── 时间映射（纯函数，测试可断言精确值）─────────────────────────────────
    uint32_t anchor_rtp() const {
        std::lock_guard<std::mutex> lk(anchorMtx_);
        return anchorRtp_;
    }
    std::chrono::steady_clock::time_point anchor_time() const {
        std::lock_guard<std::mutex> lk(anchorMtx_);
        return anchorTime_;
    }

    // 给定单调时刻，返回“接收端此刻应当正在播”的 RTP 时间戳。
    // 语义固定：t <= anchorTime 时停在起点；之后严格线性，不夹、不跳、与写包节奏无关。
    uint32_t current_rtp_at(std::chrono::steady_clock::time_point t) const {
        std::lock_guard<std::mutex> lk(anchorMtx_);
        return current_rtp_locked(t);
    }

    // sync 包字段（纯函数）：current = 当前时间轴位置；delayed = current − latency。
    raop::SyncFields sync_fields_at(std::chrono::steady_clock::time_point t, uint64_t ntp) const {
        std::lock_guard<std::mutex> lk(anchorMtx_);
        raop::SyncFields f;
        f.flags = raop::kSyncFlagsAirPlay;
        f.current_rtp = current_rtp_locked(t);
        f.latency_frames = latencyFrames_;
        f.ntp = ntp;
        return f;
    }

    RaopHealth health() const {
        RaopHealth h;
        h.open = isOpen_;
        h.transport_failed = transportFailed_.load();
        h.interleaved = interleaved_;
        // 报“线程真的在跑”，而不是“我们请求它跑”
        h.timing_thread = timingRun_.load() && timingAlive_.load();
        h.control_thread = controlRun_.load() && controlAlive_.load();
        h.paused = paused_.load();
        h.sample_rate = cfg_.sampleRate;
        h.latency_frames = latency_frames();
        h.prebuffer_seconds = prebuffer_seconds();
        h.packets_sent = packetsSent_.load();
        h.bytes_sent = bytesSent_.load();
        h.sync_sent = syncPacketsSent_.load();
        h.timing_requests = timingRequests_.load();
        h.timing_replies = timingReplies_.load();
        h.timing_malformed = timingMalformed_.load();
        h.nack_requests = nackRequests_.load();
        h.retransmits = retransmits_.load();
        h.nack_misses = nackMisses_.load();
        h.nack_rejected = nackRejected_.load();
        h.send_errors = sendErrors_.load();
        h.send_retries = sendRetries_.load();
        h.resume_replays = resumeReplays_.load();
        h.resolver_calls = resolverCalls_.load();
        h.late_packets = latePackets_.load();
        const int64_t minAhead = minAheadFrames_.load();
        h.min_ahead_frames = (minAhead == kAheadUnset) ? 0 : minAhead;
        h.last_ahead_frames = lastAheadFrames_.load();
        h.last_errno = lastErrno_.load();
        h.last_sync_rtp = lastSyncRtp_.load();
        h.last_sync_ntp = lastSyncNtp_.load();
        h.last_error = lastErrorText();
        return h;
    }

    // 一行式诊断（日志/UI 可直接显示；只报事实，不做“应该没问题”的推断）。
    std::string health_summary() const {
        const RaopHealth h = health();
        std::ostringstream os;
        os << "raop open=" << (h.open ? 1 : 0)
           << " lat=" << h.latency_frames << "f pre=" << h.prebuffer_seconds << "s"
           << " pkt=" << h.packets_sent << " sync=" << h.sync_sent
           << " timing=" << h.timing_replies << "/" << h.timing_requests
           << " nack=" << h.nack_requests << " retx=" << h.retransmits << " miss=" << h.nack_misses
           << " nrej=" << h.nack_rejected
           << " err=" << h.send_errors << " retry=" << h.send_retries
           << " late=" << h.late_packets
           << " ahead=" << h.last_ahead_frames << "f";
        if (!h.last_error.empty()) os << " last=\"" << h.last_error << "\"";
        return os.str();
    }

private:
    struct Failure {
        int status = 0;
        std::string stage;
        bool retryable = false;   // 只有 453（接收端仍认为旧会话存在）才重试
    };

    struct DeadlineGuard {
        std::atomic<bool>& flag;
        explicit DeadlineGuard(std::atomic<bool>& f) : flag(f) { flag.store(true); }
        ~DeadlineGuard() { flag.store(false); }
        DeadlineGuard(const DeadlineGuard&) = delete;
        DeadlineGuard& operator=(const DeadlineGuard&) = delete;
    };

    // 配置标量只允许**有限、在支持范围内**的值：NaN/inf 一旦进到时间轴里，
    // sync 包会算出垃圾时间戳（接收端直接失锁），所以在这里就挡掉/夹住。
    static RaopConfig sanitize_config(const RaopConfig& in) {
        RaopConfig c = in;
        c.maxOpenAttempts = std::max(1, std::min(c.maxOpenAttempts, 8));
        c.rtspTimeoutMs = std::max(50, std::min(c.rtspTimeoutMs, 60000));
        c.openDeadlineMs = std::max(0, std::min(c.openDeadlineMs, 120000));
        return c;
    }

    static int64_t remaining_ms(std::chrono::steady_clock::time_point deadline) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) return 0;
        return static_cast<int64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count());
    }

    static constexpr int64_t kAheadUnset = INT64_MAX;
    static constexpr uint64_t kMaxConsecutiveSendErrors = 3;
    static constexpr size_t kMaxRtspBufferBytes = 256 * 1024;
    static constexpr size_t kMaxPendingSeconds = 30;          // 待发 PCM 上限（内存防护）
    static constexpr int kSendRetryBudgetMs = 20;             // 单个包的瞬时错误重试预算
    static constexpr int kMaxSendRetryAttempts = 32;          // 同预算内的尝试次数上限
    static constexpr size_t kSendBufferBytes = 256 * 1024;    // SO_SNDBUF 目标（不超 256 KB）
    static constexpr size_t kMaxResolvedEndpoints = 8;        // 一次解析最多试这么多个地址
    static constexpr int kDnsPollSliceMs = 50;                // 解析期间每片最多等这么久
    static constexpr int kDnsIdleMs = 30;                     // 拿到结果后静默多久算收齐

    // ── 时间轴（全部在 anchorMtx_ 下读写：timing 线程也会读）─────────────────
    uint32_t current_rtp_locked(std::chrono::steady_clock::time_point t) const {
        if (paused_.load()) return anchorRtp_;
        if (t <= anchorTime_) return anchorRtp_;
        const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t - anchorTime_).count();
        if (ns <= 0) return anchorRtp_;
        const uint64_t frames = raop::frames_for_elapsed_ns(
            static_cast<uint64_t>(ns), cfg_.sampleRate ? cfg_.sampleRate : kRaopSampleRate);
        return static_cast<uint32_t>(anchorRtp_ + static_cast<uint32_t>(frames));
    }

    std::chrono::steady_clock::duration prebufferDurationLocked() const {
        const double sec = prebufferSeconds_ > 0.0 ? prebufferSeconds_ : 0.0;
        return std::chrono::duration_cast<std::chrono::steady_clock::duration>(
            std::chrono::duration<double>(sec));
    }

    void reanchor_from(std::chrono::steady_clock::time_point now, uint32_t rtp) {
        std::lock_guard<std::mutex> lk(anchorMtx_);
        anchorRtp_ = rtp;                           // 无 ±1 误差：起点就是这个包的原始时间戳
        anchorTime_ = now + prebufferDurationLocked();
        openSteady_ = now;
        timelineStarted_ = false;
        lastSyncSteady_ = std::chrono::steady_clock::time_point{};
    }

    void reanchor_from(std::chrono::steady_clock::time_point now) {
        reanchor_from(now, rtpTimestamp_);          // 下一个待发的包 = 时间轴起点
    }

    void update_ahead() {
        const uint32_t playNow = current_rtp_at(std::chrono::steady_clock::now());
        const int64_t ahead = static_cast<int32_t>(rtpTimestamp_ - playNow);
        lastAheadFrames_.store(ahead);
        if (ahead < 0) latePackets_.fetch_add(1);
        const int64_t prevMin = minAheadFrames_.load();
        if (ahead < prevMin) minAheadFrames_.store(ahead);
    }

    // ── 状态复位 ────────────────────────────────────────────────────────────
    void reset_all() {
        close();
        cfg_ = RaopConfig{};
        handshakeLog_.clear();
        cseq_ = 0;
        sessionId_.clear();
        serverSessionId_.clear();
        serverAudioPort_ = 0;
        serverControlPort_ = 0;
        serverTimingPort_ = 0;
        localAudioPort_ = 0;
        localControlPort_ = 0;
        localTimingPort_ = 0;
        localIpStr_.clear();
        localFamily_ = AF_INET;
        interleaved_ = false;
        recorded_ = false;
        deviceAudioLatencyFrames_ = 0;
        framesPerPacket_ = kRaopFramesPerPacket;
        pendingPcm_.clear();
        pendingOffset_ = 0;
        tcpRecvBuf_.clear();
        cache_.reset();
        {
            std::lock_guard<std::mutex> lk(anchorMtx_);
            anchorRtp_ = 0;
            anchorTime_ = std::chrono::steady_clock::time_point{};
            openSteady_ = std::chrono::steady_clock::time_point{};
            timelineStarted_ = false;
            lastSyncSteady_ = std::chrono::steady_clock::time_point{};
        }
        packetsSent_.store(0);
        bytesSent_.store(0);
        syncPacketsSent_.store(0);
        timingRequests_.store(0);
        timingReplies_.store(0);
        timingMalformed_.store(0);
        nackRequests_.store(0);
        retransmits_.store(0);
        nackMisses_.store(0);
        nackRejected_.store(0);
        sendErrors_.store(0);
        sendRetries_.store(0);
        resumeReplays_.store(0);
        resolverCalls_.store(0);
        consecutiveSendErrors_.store(0);
        latePackets_.store(0);
        minAheadFrames_.store(kAheadUnset);
        lastAheadFrames_.store(0);
        lastErrno_.store(0);
        lastSyncRtp_.store(0);
        lastSyncNtp_.store(0);
        transportFailed_.store(false);
        paused_.store(false);
        pauseWindowValid_ = false;
        pauseWindowStartRtp_ = 0;
        openDeadlineActive_.store(false);
        {
            std::lock_guard<std::mutex> lk(errMtx_);
            lastTransportError_.clear();
        }
        serverAudioAddr_ = sockaddr_storage{};
        serverAudioAddrLen_ = 0;
        peerAddr_ = sockaddr_storage{};
        peerAddrLen_ = 0;
    }

    void note_error(const std::string& text, int err) {
        lastErrno_.store(err);
        std::lock_guard<std::mutex> lk(errMtx_);
        lastTransportError_ = text;
    }
    std::string lastErrorText() const {
        std::lock_guard<std::mutex> lk(errMtx_);
        return lastTransportError_;
    }

    void update_device_latency(const raop::RtspResponse& resp) {
        std::string v = resp.audio_latency;
        if (v.empty()) v = resp.get_header("Audio-Latency");
        if (v.empty()) return;
        const int hint = std::atoi(v.c_str());
        if (hint > 0 && hint < 1000000) deviceAudioLatencyFrames_ = static_cast<uint32_t>(hint);
    }

    // ── sync / timing / NACK ────────────────────────────────────────────────
    void maybe_sync() {
        if (!isOpen_ || paused_.load()) return;
        const auto now = std::chrono::steady_clock::now();
        {
            std::lock_guard<std::mutex> lk(anchorMtx_);
            if (lastSyncSteady_.time_since_epoch().count() != 0 &&
                now - lastSyncSteady_ < std::chrono::milliseconds(kRaopSyncIntervalMs)) {
                return;
            }
            // 时间轴还没开始就别发：此时“现在”对应的位置就是起点，
            // 提前发会让接收端把起点排到 latency 之后，而 prebuffer 还没走完。
            if (now < anchorTime_) return;
            lastSyncSteady_ = now;
            timelineStarted_ = true;
        }
        emit_sync(now);
    }

    bool emit_sync(std::chrono::steady_clock::time_point now) {
        const uint64_t ntp = raop::ntp_now();
        const raop::SyncFields fields = sync_fields_at(now, ntp);
        const std::vector<uint8_t> pkt = raop::build_sync_packet(fields);

        if (interleaved_) {
            // 交织模式下 control 流走 RTSP 连接的信道 1。
            if (!send_interleaved(1, pkt.data(), pkt.size())) return false;
        } else {
            if (controlFd_ < 0) return false;
            struct sockaddr_storage peer {};
            socklen_t plen = 0;
            if (!fill_peer(serverControlPort_, peer, plen)) return false;
            const ssize_t n = ::sendto(controlFd_, pkt.data(), pkt.size(), 0,
                                       reinterpret_cast<const struct sockaddr*>(&peer), plen);
            if (n != static_cast<ssize_t>(pkt.size())) {
                if (n < 0) note_error("sync 包发送失败: " + std::string(std::strerror(errno)), errno);
                return false;
            }
        }
        syncPacketsSent_.fetch_add(1);
        lastSyncRtp_.store(fields.current_rtp);
        lastSyncNtp_.store(fields.ntp);
        return true;
    }

    void timing_loop() {
        timingAlive_.store(true);
        while (timingRun_.load()) {
            maybe_sync();                     // sync 节奏不受写包影响
            const int rc = wait_readable(timingFd_, 100);
            if (rc <= 0) continue;
            uint8_t buf[256];
            struct sockaddr_storage from {};
            socklen_t fl = sizeof(from);
            const ssize_t n = ::recvfrom(timingFd_, buf, sizeof(buf), 0,
                                        reinterpret_cast<struct sockaddr*>(&from), &fl);
            if (n <= 0) continue;
            if (n < static_cast<ssize_t>(raop::kTimingPacketSize)) {
                timingMalformed_.fetch_add(1);
                continue;
            }
            raop::TimingRequest req;
            if (!raop::parse_timing_request(buf, static_cast<size_t>(n), req)) {
                timingMalformed_.fetch_add(1);
                continue;
            }
            timingRequests_.fetch_add(1);
            const uint64_t recvNtp = raop::ntp_now();
            const uint64_t sendNtp = raop::ntp_now();
            const std::vector<uint8_t> reply = raop::build_timing_reply(req, recvNtp, sendNtp);
            const ssize_t w = ::sendto(timingFd_, reply.data(), reply.size(), 0,
                                       reinterpret_cast<const struct sockaddr*>(&from), fl);
            if (w == static_cast<ssize_t>(reply.size())) {
                timingReplies_.fetch_add(1);
            } else if (w < 0) {
                note_error("timing 应答发送失败: " + std::string(std::strerror(errno)), errno);
            }
        }
        timingAlive_.store(false);
    }

    void control_loop() {
        controlAlive_.store(true);
        while (controlRun_.load()) {
            const int rc = wait_readable(controlFd_, 100);
            if (rc <= 0) continue;
            uint8_t buf[256];
            struct sockaddr_storage from {};
            socklen_t fl = sizeof(from);
            const ssize_t n = ::recvfrom(controlFd_, buf, sizeof(buf), 0,
                                        reinterpret_cast<struct sockaddr*>(&from), &fl);
            if (n <= 0) continue;
            raop::NackRequest req;
            if (!raop::parse_nack(buf, static_cast<size_t>(n), req)) continue;  // 不是 NACK，忽略
            // 来源校验：只接受**本次 RTSP 对端**、且来自它 audio/control/timing 端口之一的请求。
            // 重传响应固定回对端的 control 端口（不是回包源地址），所以本来就不存在
            // “把流量反射给第三方”的放大路径；这里再挡掉无关主机/端口的噪声与伪造触发。
            if (!nack_source_allowed(from)) {
                nackRejected_.fetch_add(1);
                continue;
            }
            nackRequests_.fetch_add(1);
            handle_nack(req);
        }
        controlAlive_.store(false);
    }

    // NACK 来源白名单：IP 必须是本次 RTSP 对端（sockaddr 逐字节比较，含 IPv6 scope），
    // 端口必须是它对端在 SETUP 里给出的 audio/control/timing 之一。
    // 依据 rtp.c:1019/1217——参考实现的 NACK 就从它自己的 control socket 发出，
    // 而那个端口正是它 SETUP 里报给我们的 control_port。
    bool nack_source_allowed(const struct sockaddr_storage& from) const {
        if (peerAddrLen_ == 0) return false;
        if (from.ss_family != peerAddr_.ss_family) return false;
        uint16_t port = 0;
        if (from.ss_family == AF_INET) {
            const auto* a = reinterpret_cast<const struct sockaddr_in*>(&from);
            const auto* b = reinterpret_cast<const struct sockaddr_in*>(&peerAddr_);
            if (a->sin_addr.s_addr != b->sin_addr.s_addr) return false;
            port = ntohs(a->sin_port);
        } else if (from.ss_family == AF_INET6) {
            const auto* a = reinterpret_cast<const struct sockaddr_in6*>(&from);
            const auto* b = reinterpret_cast<const struct sockaddr_in6*>(&peerAddr_);
            if (std::memcmp(&a->sin6_addr, &b->sin6_addr, sizeof(struct in6_addr)) != 0) return false;
            port = ntohs(a->sin6_port);
        } else {
            return false;
        }
        const bool anyKnownPort =
            serverAudioPort_ != 0 || serverControlPort_ != 0 || serverTimingPort_ != 0;
        if (!anyKnownPort) return true;   // 交织会话：对端没报 UDP 端口，只能按 IP 校验
        return port != 0 && (port == serverAudioPort_ || port == serverControlPort_ ||
                             port == serverTimingPort_);
    }

    // 按请求补发：原序号、原时间戳、原 ALAC 载荷。找不到（过老/超范围）= Miss，
    // 宁可让接收端静音一个包，也不补一个“序号对但内容错”的包。
    void handle_nack(const raop::NackRequest& req) {
        for (uint16_t i = 0; i < req.count; ++i) {
            const uint16_t seq = static_cast<uint16_t>(req.first + i);
            raop::CachedRtpPacket cached;
            if (!cache_.find(seq, cached)) {
                nackMisses_.fetch_add(1);
                continue;
            }
            std::string sendErr;
            if (send_rtp_resend(seq, cached.timestamp, cached.payload.data(), cached.payload.size(),
                                &sendErr)) {
                retransmits_.fetch_add(1);
            }   // 失败细节由 send_rtp_resend 自己记账（errno 在这里已经不可靠）
        }
    }

    // ── 发包 ────────────────────────────────────────────────────────────────
    bool emit_audio_packet(const int16_t* pcm, std::string* err) {
        std::vector<uint8_t> alac;
        std::string encErr;
        if (!encoder_->encode_frame(pcm, static_cast<size_t>(framesPerPacket_), alac, &encErr)) {
            if (err) *err = "ALAC 帧编码失败: " + encErr;
            return false;
        }
        if (alac.empty()) {
            if (err) *err = "ALAC 帧编码结果为空（编码器未产出数据包）";
            return false;
        }
        const uint16_t seq = rtpSeq_;
        const uint32_t ts = rtpTimestamp_;
        if (!send_rtp(seq, ts, alac.data(), alac.size(), "RTP 发送", err)) return false;
        cache_.store(seq, ts, alac.data(), alac.size());
        ++rtpSeq_;
        rtpTimestamp_ += static_cast<uint32_t>(framesPerPacket_);
        packetsSent_.fetch_add(1);
        bytesSent_.fetch_add(raop::kRtpHeaderSize + alac.size());
        return true;
    }

    bool send_rtp(uint16_t seq, uint32_t ts, const uint8_t* payload, size_t len,
                  const char* stage, std::string* err) {
        std::vector<uint8_t> pkt(raop::kRtpHeaderSize + len);
        raop::put_rtp_header(pkt.data(), seq, ts, rtpSsrc_);
        if (len > 0) std::memcpy(pkt.data() + raop::kRtpHeaderSize, payload, len);
        return send_audio_frame(pkt, stage, err);
    }

    // NACK 重传：0xD6 = 4 字节重传头 + 原 12 字节 RTP 头 + 原 ALAC 载荷，回对端 control 端口。
    // Use the explicit resend envelope on the control path. Some receivers also
    // accept an original RTP packet on the audio port; do not assume all do.
    bool send_rtp_resend(uint16_t seq, uint32_t ts, const uint8_t* payload, size_t len,
                         std::string* err) {
        const std::vector<uint8_t> pkt = raop::build_resend_packet(seq, ts, rtpSsrc_, payload, len);
        if (interleaved_) {
            // 交织模式下 control 流走 RTSP 连接的信道 1（sync 也走这条）。
            if (!send_interleaved(1, pkt.data(), pkt.size())) {
                sendErrors_.fetch_add(1);
                if (err) *err = "NACK 重传 交织发送失败（RTSP 连接已断）";
                return false;
            }
            return true;
        }
        if (controlFd_ < 0) {
            if (err) *err = "NACK 重传: control UDP socket 未就绪";
            return false;
        }
        struct sockaddr_storage peer {};
        socklen_t plen = 0;
        if (!fill_peer(serverControlPort_, peer, plen)) {
            if (err) *err = "NACK 重传: 对端 control 端口未知";
            return false;
        }
        int retries = 0;
        int e = 0;
        const ssize_t n = udp_send_bounded(controlFd_, pkt.data(), pkt.size(),
                                           reinterpret_cast<const struct sockaddr*>(&peer), plen,
                                           kSendRetryBudgetMs, &retries, &e);
        if (retries > 0) sendRetries_.fetch_add(static_cast<uint64_t>(retries));
        if (n == static_cast<ssize_t>(pkt.size())) return true;
        sendErrors_.fetch_add(1);
        // control 端口不可达不代表音频链路断了：只记账，不锁死会话。
        if (err) *err = std::string("NACK 重传发送失败: ") + std::strerror(e);
        note_error(std::string("NACK 重传发送失败: ") + std::strerror(e), e);
        return false;
    }

    // 音频帧发送（UDP 路径带瞬时错误重试；TCP 交织路径直接反映连接状态）。
    bool send_audio_frame(const std::vector<uint8_t>& pkt, const char* stage, std::string* err) {
        if (interleaved_) {
            if (!send_interleaved(0, pkt.data(), pkt.size())) {
                sendErrors_.fetch_add(1);
                consecutiveSendErrors_.fetch_add(1);
                transportFailed_.store(true);   // TCP 断了就是断了
                if (err) *err = std::string(stage) + " 交织发送失败（RTSP 连接已断）";
                return false;
            }
            consecutiveSendErrors_.store(0);
            return true;
        }

        if (audioFd_ < 0 || serverAudioAddrLen_ == 0) {
            sendErrors_.fetch_add(1);
            transportFailed_.store(true);
            if (err) *err = std::string(stage) + " UDP socket 未就绪";
            return false;
        }
        int retries = 0;
        int e = 0;
        const ssize_t n = udp_send_bounded(audioFd_, pkt.data(), pkt.size(),
                                           reinterpret_cast<const struct sockaddr*>(&serverAudioAddr_),
                                           serverAudioAddrLen_, kSendRetryBudgetMs, &retries, &e);
        if (retries > 0) sendRetries_.fetch_add(static_cast<uint64_t>(retries));
        if (n == static_cast<ssize_t>(pkt.size())) {
            consecutiveSendErrors_.store(0);
            return true;
        }
        sendErrors_.fetch_add(1);
        const uint64_t consecutive = consecutiveSendErrors_.fetch_add(1) + 1;
        note_error(std::string(stage) + " 失败: " +
                       (n < 0 ? std::string(std::strerror(e)) : std::string("短写")), e);
        // 瞬时错误已经在 udp_send_bounded 里重试过；到这里说明预算用尽或错误是永久的。
        // 但**任何**失败都必须带原因返回：静默的 false 会让上层以为“写成功了只是没声”。
        if (err) {
            *err = std::string(stage) + " 失败: " +
                   (n < 0 ? std::string(std::strerror(e)) : std::string("短写"));
        }
        // 仍然只在**连续**多个包都发不出去时才锁死会话，不让一次抖动掐断整场播放。
        if (consecutive >= kMaxConsecutiveSendErrors) {
            transportFailed_.store(true);
            if (err) *err += "（连续失败 " + std::to_string(consecutive) + " 次，会话已锁死）";
        }
        return false;
    }

    static bool transient_send_errno(int e) {
        return e == EAGAIN || e == EWOULDBLOCK || e == ENOBUFS || e == EINTR;
    }

    // 一次真实的 sendto（或测试注入）。返回 -1 时 *outErr 给出 errno。
    ssize_t udp_send_raw(int fd, const void* data, size_t len, const struct sockaddr* to,
                         socklen_t tolen, int* outErr) {
        if (udpSendHook_) {
            int e = 0;
            const ssize_t n = udpSendHook_(fd, data, len, to, tolen, &e);
            if (n < 0) *outErr = e;
            return n;
        }
        errno = 0;
        const ssize_t n = ::sendto(fd, data, len, 0, to, tolen);
        if (n < 0) *outErr = errno;
        return n;
    }

    // 同一个包在有限预算内重试；**不发下一个包、序号不前进**。
    // 永久错误（EPERM/ENETUNREACH/EBADF…）立即返回，绝不吞掉。
    ssize_t udp_send_bounded(int fd, const void* data, size_t len, const struct sockaddr* to,
                             socklen_t tolen, int budgetMs, int* retries, int* outErr) {
        const auto deadline = std::chrono::steady_clock::now() +
                              std::chrono::milliseconds(std::max(1, budgetMs));
        int attempts = 0;
        for (;;) {
            int e = 0;
            const ssize_t n = udp_send_raw(fd, data, len, to, tolen, &e);
            if (n >= 0) {
                if (outErr) *outErr = 0;
                return n;
            }
            if (!transient_send_errno(e)) {
                if (outErr) *outErr = e;
                return -1;
            }
            ++attempts;
            if (retries) ++*retries;
            const int64_t remain = remaining_ms(deadline);
            if (remain <= 0 || attempts >= kMaxSendRetryAttempts) {
                if (outErr) *outErr = e;
                return -1;
            }
            // UDP 的 POLLOUT 在发送缓冲有空间时立刻返回；这里最多等 1 ms，
            // 既给内核时间回收缓冲，也不会在写线程里空转。
            struct pollfd pfd {};
            pfd.fd = fd;
            pfd.events = POLLOUT;
            (void)::poll(&pfd, 1, static_cast<int>(std::min<int64_t>(remain, 1)));
        }
    }

    bool send_interleaved(uint8_t channel, const uint8_t* data, size_t len) {
        if (tcpFd_ < 0 || len > 0xFFFF) return false;
        std::vector<uint8_t> frame(4 + len);
        frame[0] = 0x24;
        frame[1] = channel;
        frame[2] = static_cast<uint8_t>((len >> 8) & 0xFF);
        frame[3] = static_cast<uint8_t>(len & 0xFF);
        if (len > 0) std::memcpy(frame.data() + 4, data, len);
        std::lock_guard<std::mutex> lk(tcpSendMtx_);   // 交织模式下两条线程共用一条 TCP
        std::string e;
        if (!send_all(tcpFd_, frame.data(), frame.size(), cfg_.rtspTimeoutMs, &e)) {
            note_error("交织帧发送失败: " + e, errno);
            return false;
        }
        return true;
    }

    // ── RTSP ────────────────────────────────────────────────────────────────
    bool send_set_parameter(const std::string& bodyStr, std::string* err, const char* stage) {
        std::ostringstream req;
        req << "SET_PARAMETER " << session_uri() << " RTSP/1.0\r\n"
            << "CSeq: " << (++cseq_) << "\r\n";
        if (!serverSessionId_.empty()) req << "Session: " << serverSessionId_ << "\r\n";
        req << "Content-Type: text/parameters\r\n"
            << "Content-Length: " << bodyStr.size() << "\r\n"
            << "User-Agent: RLPlayer/1.1.2\r\n\r\n"
            << bodyStr;
        raop::RtspResponse resp;
        return send_rtsp_and_recv(req.str(), cseq_, resp, err, stage);
    }

    // timeoutMs < 0 用 cfg_.rtspTimeoutMs。返回 false 时 lastFailure_ 记下结构化状态码。
    bool send_rtsp_and_recv(const std::string& request, int expectedCseq,
                            raop::RtspResponse& resp, std::string* err,
                            const char* stageName, int timeoutMs = -1) {
        lastFailure_ = Failure{};
        lastFailure_.stage = stageName ? stageName : "";
        if (tcpFd_ < 0) {
            if (err) *err = std::string(stageName) + " 错误: TCP 连接未建立或已断开";
            return false;
        }
        int timeout = timeoutMs >= 0 ? timeoutMs : cfg_.rtspTimeoutMs;
        if (openDeadlineActive_.load()) {
            // open() 的总预算优先于单条请求的时限：DNS 慢/多地址/对端迟迟不回时，
            // 剩下的时间不够就立刻失败，而不是把配置的超时再走一遍。
            const int64_t remain = remaining_ms(openDeadline_);
            if (remain <= 0) {
                if (err) *err = std::string(stageName) + " 未发出: open() 总时限已用尽";
                return false;
            }
            timeout = static_cast<int>(std::min<int64_t>(timeout, remain));
        }
        const auto deadline = std::chrono::steady_clock::now() +
                              std::chrono::milliseconds(std::max(1, timeout));

        std::string sendErr;
        {
            // 交织模式下 NACK 重传线程也会往这条 TCP 写 0x24 帧；
            // 两条线程的写必须串行，否则帧边界会互相插进对方的字节流里。
            std::lock_guard<std::mutex> lk(tcpSendMtx_);
            if (!send_all(tcpFd_, reinterpret_cast<const uint8_t*>(request.data()), request.size(),
                          timeout, &sendErr)) {
                if (err) *err = std::string(stageName) + " 发送失败: " + sendErr;
                return false;
            }
        }

        for (;;) {
            // RTSP 连接上可能夹带 0x24 交织帧，先跳掉（有界）。
            const raop::InterleavedSkip skip = raop::skip_interleaved_frames(tcpRecvBuf_);
            if (skip == raop::InterleavedSkip::Invalid) {
                if (err) *err = std::string(stageName) + " 响应里的交织帧长度非法";
                return false;
            }
            size_t consumed = 0;
            std::string parseErr;
            const raop::ParseState st = raop::parse_rtsp_response(tcpRecvBuf_, resp, consumed, &parseErr);
            if (st == raop::ParseState::Error) {
                if (err) *err = std::string(stageName) + " 响应解析失败: " + parseErr;
                return false;
            }
            if (st == raop::ParseState::Complete) {
                tcpRecvBuf_.erase(0, consumed);
                break;
            }
            std::string recvErr;
            const int r = recv_some(deadline, &recvErr);
            if (r == 0) {
                if (err) *err = std::string(stageName) + " 等待响应超时（" +
                                std::to_string(timeout) + " ms）";
                return false;
            }
            if (r < 0) {
                if (err) *err = std::string(stageName) + " " + recvErr;
                return false;
            }
        }

        if (resp.cseq < 0) {
            if (err) *err = std::string(stageName) + " 响应缺少 CSeq 头";
            return false;
        }
        if (resp.cseq != expectedCseq) {
            if (err) *err = std::string(stageName) + " CSeq 不匹配: 期望 " +
                            std::to_string(expectedCseq) + " 实际 " + std::to_string(resp.cseq);
            return false;
        }
        if (resp.status_code < 200 || resp.status_code >= 300) {
            lastFailure_.status = resp.status_code;
            // 只有 453 才可能是“接收端仍认为上一个会话存在”；
            // ANNOUNCE/SETUP 之外的 453 不是这个语义，不重试。
            lastFailure_.retryable =
                resp.status_code == 453 &&
                (lastFailure_.stage == "ANNOUNCE" || lastFailure_.stage == "SETUP");
            if (err) *err = std::string(stageName) + " 服务端返回错误状态: " + resp.first_line;
            return false;
        }
        return true;
    }

    // >0 收到数据；0 超时；<0 出错（recvErr 带原因）
    int recv_some(std::chrono::steady_clock::time_point deadline, std::string* recvErr) {
        for (;;) {
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) return 0;
            const auto remain =
                std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
            struct pollfd pfd {};
            pfd.fd = tcpFd_;
            pfd.events = POLLIN;
            const int prc = ::poll(&pfd, 1, static_cast<int>(std::max<int64_t>(1, remain)));
            if (prc == 0) return 0;
            if (prc < 0) {
                if (errno == EINTR) continue;
                if (recvErr) *recvErr = std::string("poll 失败: ") + std::strerror(errno);
                return -1;
            }
            uint8_t buf[4096];
            const ssize_t n = ::recv(tcpFd_, buf, sizeof(buf), 0);
            if (n == 0) {
                if (recvErr) *recvErr = "服务端过早关闭连接";
                return -1;
            }
            if (n < 0) {
                if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
                if (recvErr) *recvErr = std::string("接收失败: ") + std::strerror(errno);
                return -1;
            }
            if (tcpRecvBuf_.size() + static_cast<size_t>(n) > kMaxRtspBufferBytes) {
                if (recvErr) *recvErr = "响应缓冲超过上限（服务端未按 RTSP 分帧）";
                return -1;
            }
            tcpRecvBuf_.append(reinterpret_cast<const char*>(buf), static_cast<size_t>(n));
            return 1;
        }
    }

    enum class FlushKind {
        DiscardPending,   // seek：本地待发输入与重传缓存一起作废
        KeepPending,      // pause：只让对端丢缓冲，未发出的输入与在途窗口都保留
    };

    // 暂停用：把“已播到的时间戳”对齐到**包边界**（向前取整）。
    // 时间戳与序号一一对应（每包 framesPerPacket_ 帧），所以序号可以由差值精确反推。
    // 若已播位置已经越过“下一个待发”（发送落后于时间轴，例如欠载），在途窗口为空，
    // 直接以 rtpTimestamp_ 为界——绝不做模 2^32 的减法，否则会算出一个天文数字的差值。
    uint32_t pause_window_start(uint32_t frozen) const {
        const uint32_t per = static_cast<uint32_t>(framesPerPacket_ > 0 ? framesPerPacket_
                                                                       : kRaopFramesPerPacket);
        if (static_cast<int32_t>(rtpTimestamp_ - frozen) <= 0) return rtpTimestamp_;
        const uint32_t delta = static_cast<uint32_t>(rtpTimestamp_ - frozen);
        const uint32_t packets = (delta + per - 1) / per;      // 向上取整
        if (packets == 0) return rtpTimestamp_;
        return static_cast<uint32_t>(rtpTimestamp_ - packets * per);
    }

    void flush_wire(FlushKind kind) {
        if (!isOpen_ || tcpFd_ < 0) return;
        uint16_t flushSeq = rtpSeq_;
        uint32_t flushRtp = rtpTimestamp_;
        if (kind == FlushKind::DiscardPending) {
            pendingPcm_.clear();
            pendingOffset_ = 0;
            cache_.clear();
            pauseWindowValid_ = false;
        } else {
            // pause：缓存必须留着——恢复时要靠它把在途窗口补回去。
            flushRtp = pauseWindowStartRtp_;
            const uint32_t delta = static_cast<uint32_t>(rtpTimestamp_ - flushRtp);
            const uint32_t per = static_cast<uint32_t>(framesPerPacket_ > 0 ? framesPerPacket_
                                                                           : kRaopFramesPerPacket);
            flushSeq = static_cast<uint16_t>(rtpSeq_ - static_cast<uint16_t>(delta / per));
        }

        std::ostringstream req;
        req << "FLUSH " << session_uri() << " RTSP/1.0\r\n"
            << "CSeq: " << (++cseq_) << "\r\n";
        if (!serverSessionId_.empty()) req << "Session: " << serverSessionId_ << "\r\n";
        req << "RTP-Info: seq=" << flushSeq << ";rtptime=" << flushRtp << "\r\n"
            << "User-Agent: RLPlayer/1.1.2\r\n\r\n";
        raop::RtspResponse resp;
        std::string ignore;
        send_rtsp_and_recv(req.str(), cseq_, resp, &ignore, "FLUSH");
    }

    // 暂停时“已发未播”的那一段：从有界重传缓存里按发送顺序取出。
    // 只取 rtptime ∈ [窗口起点, 下一个待发包)，最多缓存容量个（内存与流时长无关）。
    void collect_pause_window(std::vector<raop::CachedRtpPacket>& out) {
        out.clear();
        if (!pauseWindowValid_) return;
        pauseWindowValid_ = false;
        const uint32_t end = static_cast<uint32_t>(rtpTimestamp_ - pauseWindowStartRtp_);
        if (end == 0) return;
        std::vector<raop::CachedRtpPacket> snap;
        cache_.snapshot_in_order(snap);
        for (auto& p : snap) {
            const uint32_t rel = static_cast<uint32_t>(p.timestamp - pauseWindowStartRtp_);
            if (rel >= end) continue;
            out.push_back(std::move(p));
        }
    }

    // 恢复播放：把窗口里的包按原 seq/rtptime/载荷补发回去（序号不前进，不算新音频）。
    void send_pause_window(const std::vector<raop::CachedRtpPacket>& window) {
        if (window.empty() || !isOpen_) return;
        if (!interleaved_ && audioFd_ < 0) return;
        size_t replayed = 0;
        int consecutiveFailures = 0;
        for (const auto& p : window) {
            std::string e;
            if (send_rtp(p.sequence, p.timestamp, p.payload.data(), p.payload.size(),
                         "暂停恢复重发", &e)) {
                ++replayed;
                consecutiveFailures = 0;
            } else if (++consecutiveFailures >= 3) {
                break;
            }
        }
        resumeReplays_.fetch_add(replayed);
    }

    // ── socket ──────────────────────────────────────────────────────────────
    static ssize_t send_no_sigpipe(int fd, const void* data, size_t len) {
#ifdef MSG_NOSIGNAL
        return ::send(fd, data, len, MSG_NOSIGNAL);
#else
        return ::send(fd, data, len, 0);
#endif
    }

    static void set_no_sigpipe(int fd) {
#ifdef SO_NOSIGPIPE
        int one = 1;
        ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#else
        (void)fd;
#endif
    }

    static bool send_all(int fd, const uint8_t* data, size_t len, int timeoutMs, std::string* err) {
        size_t off = 0;
        const auto deadline = std::chrono::steady_clock::now() +
                              std::chrono::milliseconds(std::max(1, timeoutMs));
        while (off < len) {
            const ssize_t n = send_no_sigpipe(fd, data + off, len - off);
            if (n > 0) {
                off += static_cast<size_t>(n);
                continue;
            }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                const auto now = std::chrono::steady_clock::now();
                if (now >= deadline) {
                    if (err) *err = "发送超时";
                    return false;
                }
                const auto remain =
                    std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
                struct pollfd pfd {};
                pfd.fd = fd;
                pfd.events = POLLOUT;
                const int prc = ::poll(&pfd, 1, static_cast<int>(std::max<int64_t>(1, remain)));
                if (prc == 0) {
                    if (err) *err = "发送超时";
                    return false;
                }
                if (prc < 0 && errno != EINTR) {
                    if (err) *err = std::string("poll(POLLOUT) 失败: ") + std::strerror(errno);
                    return false;
                }
                continue;
            }
            if (err) *err = n < 0 ? std::strerror(errno) : "连接被关闭（短写 0 字节）";
            return false;
        }
        return true;
    }

    static void close_fd(int& fd) {
        if (fd >= 0) {
            ::close(fd);
            fd = -1;
        }
    }

    static void join_thread(std::thread& t) {
        if (!t.joinable()) return;
        if (t.get_id() == std::this_thread::get_id()) {
            t.detach();
            return;
        }
        t.join();
    }

    // 等待可读：>0 就绪，0 超时，<0 错误（EINTR 已消化）
    static int wait_readable(int fd, int timeoutMs) {
        if (fd < 0) return -1;
        for (;;) {
            struct pollfd pfd {};
            pfd.fd = fd;
            pfd.events = POLLIN;
            const int rc = ::poll(&pfd, 1, timeoutMs);
            if (rc < 0 && errno == EINTR) continue;
            return rc;
        }
    }

    bool fill_peer(uint16_t port, struct sockaddr_storage& out, socklen_t& len) const {
        if (serverAudioAddrLen_ == 0 || port == 0) return false;
        std::memcpy(&out, &serverAudioAddr_, serverAudioAddrLen_);
        len = serverAudioAddrLen_;
        if (out.ss_family == AF_INET) ((struct sockaddr_in*)&out)->sin_port = htons(port);
        else if (out.ss_family == AF_INET6) ((struct sockaddr_in6*)&out)->sin6_port = htons(port);
        else return false;
        return true;
    }

    // ── 解析：数字 IP 直接构造；域名走 dns_sd 异步查询，全程受 deadline 约束 ────
    static bool parse_numeric_host(const std::string& host, uint16_t port, RaopEndpoint& out) {
        std::string h = host;
        if (h.size() >= 2 && h.front() == '[' && h.back() == ']') h = h.substr(1, h.size() - 2);
        struct sockaddr_in a4 {};
        if (::inet_pton(AF_INET, h.c_str(), &a4.sin_addr) == 1) {
            a4.sin_family = AF_INET;
            a4.sin_port = htons(port);
            std::memcpy(&out.addr, &a4, sizeof(a4));
            out.len = sizeof(a4);
            out.family = AF_INET;
            return true;
        }
        struct sockaddr_in6 a6 {};
        if (::inet_pton(AF_INET6, h.c_str(), &a6.sin6_addr) == 1) {
            a6.sin6_family = AF_INET6;
            a6.sin6_port = htons(port);
            std::memcpy(&out.addr, &a6, sizeof(a6));
            out.len = sizeof(a6);
            out.family = AF_INET6;
            return true;
        }
        return false;
    }

    // IPv4 优先：局域网接收端绝大多数是 IPv4，先把 v4 试完再退回 v6。
    static void sort_ipv4_first(std::vector<RaopEndpoint>& eps) {
        std::stable_sort(eps.begin(), eps.end(), [](const RaopEndpoint& a, const RaopEndpoint& b) {
            return a.family == AF_INET && b.family != AF_INET;
        });
    }

#if RTA_RAOP_HAS_DNS_SD
    struct DnsCtx {
        std::vector<RaopEndpoint>* out = nullptr;
        uint16_t port = 0;
        DNSServiceErrorType error = kDNSServiceErr_NoError;
    };

    static void dns_addr_callback(DNSServiceRef, DNSServiceFlags flags, uint32_t,
                                  DNSServiceErrorType errorCode, const char*, const struct sockaddr* address,
                                  uint32_t, void* context) {
        auto* ctx = static_cast<DnsCtx*>(context);
        if (!ctx || !ctx->out) return;
        if (errorCode != kDNSServiceErr_NoError) {
            ctx->error = errorCode;
            return;
        }
        if (!address || (flags & kDNSServiceFlagsAdd) == 0) return;
        if (address->sa_family != AF_INET && address->sa_family != AF_INET6) return;
        if (ctx->out->size() >= kMaxResolvedEndpoints) return;
        RaopEndpoint ep;
        const socklen_t len = (address->sa_family == AF_INET) ? sizeof(struct sockaddr_in)
                                                             : sizeof(struct sockaddr_in6);
        std::memcpy(&ep.addr, address, len);
        ep.len = len;
        ep.family = address->sa_family;
        if (address->sa_family == AF_INET) {
            reinterpret_cast<struct sockaddr_in*>(&ep.addr)->sin_port = htons(ctx->port);
        } else {
            reinterpret_cast<struct sockaddr_in6*>(&ep.addr)->sin6_port = htons(ctx->port);
        }
        ctx->out->push_back(ep);
    }

    bool resolve_with_dns_sd(const std::string& host, uint16_t port,
                             std::chrono::steady_clock::time_point deadline,
                             std::vector<RaopEndpoint>& out, std::string* err) {
        DNSServiceRef ref = nullptr;
        DnsCtx ctx;
        ctx.out = &out;
        ctx.port = port;
        const DNSServiceErrorType rc =
            DNSServiceGetAddrInfo(&ref, 0, kDNSServiceInterfaceIndexAny,
                                  kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6,
                                  host.c_str(), &dns_addr_callback, &ctx);
        if (rc != kDNSServiceErr_NoError || ref == nullptr) {
            if (err) *err = "解析主机失败 (" + host + "): dns_sd 错误 " + std::to_string(rc);
            return false;
        }
        const int fd = DNSServiceRefSockFD(ref);
        auto lastResult = std::chrono::steady_clock::now();
        bool firstResult = false;
        for (;;) {
            const int64_t remain = remaining_ms(deadline);
            if (remain <= 0) break;
            int64_t waitMs = std::min<int64_t>(remain, kDnsPollSliceMs);
            if (firstResult) {
                const int64_t idleMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                           std::chrono::steady_clock::now() - lastResult)
                                           .count();
                if (idleMs >= kDnsIdleMs) break;      // 结果齐了：静默一小会儿就收手
                waitMs = std::min<int64_t>(waitMs, kDnsIdleMs - idleMs);
            }
            if (fd < 0) break;
            struct pollfd pfd {};
            pfd.fd = fd;
            pfd.events = POLLIN;
            const int prc = ::poll(&pfd, 1, static_cast<int>(std::max<int64_t>(1, waitMs)));
            if (prc < 0) {
                if (errno == EINTR) continue;
                ctx.error = kDNSServiceErr_Unknown;
                break;
            }
            if (prc == 0) continue;                    // 时间片到了，回去检查总预算
            const DNSServiceErrorType pr = DNSServiceProcessResult(ref);
            if (pr != kDNSServiceErr_NoError) {
                ctx.error = pr;
                break;
            }
            lastResult = std::chrono::steady_clock::now();
            firstResult = !out.empty();
            if (out.size() >= kMaxResolvedEndpoints) break;
        }
        DNSServiceRefDeallocate(ref);                  // 立即取消：没有后台线程、没有悬空引用
        if (out.empty()) {
            if (err) {
                if (ctx.error != kDNSServiceErr_NoError) {
                    *err = "解析主机失败 (" + host + "): DNS 错误 " + std::to_string(ctx.error);
                } else {
                    *err = "解析主机超时: " + host + " 未在 open() 总时限内返回地址";
                }
            }
            return false;
        }
        sort_ipv4_first(out);
        return true;
    }
#endif

    // 域名/数字 IP 统一入口。解析结果只在这里产生一次，之后连接与 UDP 目标都用它。
    bool resolve_host(const std::string& host, uint16_t port,
                      std::chrono::steady_clock::time_point deadline,
                      std::vector<RaopEndpoint>& out, std::string* err) {
        out.clear();
        RaopEndpoint literal;
        if (parse_numeric_host(host, port, literal)) {
            out.push_back(literal);   // 数字 IP：不碰解析器，不可能阻塞
            return true;
        }
        if (host.empty()) {
            if (err) *err = "目标主机为空";
            return false;
        }
        if (resolveHook_) {
            resolverCalls_.fetch_add(1);
            if (!resolveHook_(host, port, out, err)) {
                if (err && err->empty()) *err = "解析主机失败: " + host;
                return false;
            }
            if (out.empty()) {
                if (err) *err = "解析主机失败: " + host + " 没有可用地址";
                return false;
            }
            sort_ipv4_first(out);
            return true;
        }
#if RTA_RAOP_HAS_DNS_SD
        resolverCalls_.fetch_add(1);
        return resolve_with_dns_sd(host, port, deadline, out, err);
#else
        // 没有可用的异步解析器时，宁可在预检阶段明确拒绝，也不在推流链路上阻塞。
        if (err) {
            *err = "本平台只支持数字 IP 直连（不做阻塞式域名解析）: " + host;
        }
        return false;
#endif
    }

    bool connect_tcp(const std::string& host, uint16_t port,
                     std::chrono::steady_clock::time_point deadline, std::string* err) {
        std::vector<RaopEndpoint> eps;
        if (!resolve_host(host, port, deadline, eps, err)) return false;

        const std::string portStr = std::to_string(port);
        std::string lastErr;
        for (const auto& ep : eps) {
            const int64_t remain = remaining_ms(deadline);
            if (remain <= 0) {
                lastErr = "open() 总时限已用尽（连接阶段）";
                break;
            }
            const int s = ::socket(ep.family, SOCK_STREAM, 0);
            if (s < 0) {
                lastErr = std::string("socket 失败: ") + std::strerror(errno);
                continue;
            }
            set_no_sigpipe(s);

            const int flags = ::fcntl(s, F_GETFL, 0);
            ::fcntl(s, F_SETFL, flags | O_NONBLOCK);
            bool connected = (::connect(s, reinterpret_cast<const struct sockaddr*>(&ep.addr),
                                        ep.len) == 0);
            if (!connected && errno == EINPROGRESS) {
                // 单地址等待也吃总预算：多 A/AAAA 记录不会把 open() 拖成 N × 超时。
                const int64_t waitMs = std::min<int64_t>(cfg_.rtspTimeoutMs, remaining_ms(deadline));
                struct pollfd pfd {};
                pfd.fd = s;
                pfd.events = POLLOUT;
                const int prc = ::poll(&pfd, 1, static_cast<int>(std::max<int64_t>(1, waitMs)));
                if (prc > 0) {
                    int soError = 0;
                    socklen_t elen = sizeof(soError);
                    if (::getsockopt(s, SOL_SOCKET, SO_ERROR, &soError, &elen) == 0 && soError == 0) {
                        connected = true;
                    } else {
                        lastErr = std::string("连接失败: ") + std::strerror(soError);
                    }
                } else if (prc == 0) {
                    lastErr = "连接超时（" + std::to_string(waitMs) + " ms 预算内未完成）";
                } else {
                    lastErr = std::string("poll(POLLOUT) 失败: ") + std::strerror(errno);
                }
            } else if (!connected) {
                // 非阻塞 connect 失败后 errno 常停在 EINPROGRESS，不能拿它当原因。
                lastErr = "连接被拒绝或不可达";
            }

            if (!connected) {
                ::close(s);
                continue;
            }
            ::fcntl(s, F_SETFL, flags);
            struct timeval tv {};
            tv.tv_sec = 0;
            tv.tv_usec = 200000;   // 兜底；真正的时限由 poll 控制
            ::setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            int one = 1;
            ::setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

            struct sockaddr_storage localAddr {};
            socklen_t addrLen = sizeof(localAddr);
            if (getsockname(s, reinterpret_cast<struct sockaddr*>(&localAddr), &addrLen) == 0) {
                char ipbuf[INET6_ADDRSTRLEN] = {0};
                if (localAddr.ss_family == AF_INET) {
                    inet_ntop(AF_INET, &reinterpret_cast<struct sockaddr_in*>(&localAddr)->sin_addr,
                              ipbuf, sizeof(ipbuf));
                    localFamily_ = AF_INET;
                } else if (localAddr.ss_family == AF_INET6) {
                    inet_ntop(AF_INET6, &reinterpret_cast<struct sockaddr_in6*>(&localAddr)->sin6_addr,
                              ipbuf, sizeof(ipbuf));
                    localFamily_ = AF_INET6;
                }
                localIpStr_ = ipbuf;
            }
            // 记住实际连上的那个对端：UDP 目标与 NACK 来源校验都以它为准，
            // 不再二次解析（否则可能解析到另一台同名设备/另一族地址）。
            peerAddr_ = ep.addr;
            peerAddrLen_ = ep.len;
            tcpFd_ = s;
            return true;
        }

        if (err) {
            *err = "无法连接到 RTSP 服务端 " + host + ":" + portStr +
                   "（拒绝连接/超时/网段不通；确认接收器与本机同一网段）";
            if (!lastErr.empty()) *err += "；最后一个错误: " + lastErr;
        }
        return false;
    }

    bool setup_local_udp_sockets(std::string* err) {
        const int family = (localFamily_ == AF_INET6) ? AF_INET6 : AF_INET;
        auto bind_udp = [family](int& fd, uint16_t& outPort) -> bool {
            fd = ::socket(family, SOCK_DGRAM, 0);
            if (fd < 0) return false;
            set_no_sigpipe(fd);
            if (family == AF_INET) {
                struct sockaddr_in addr {};
                addr.sin_family = AF_INET;
                addr.sin_addr.s_addr = htonl(INADDR_ANY);
                addr.sin_port = 0;
                if (::bind(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
                    close_fd(fd);
                    return false;
                }
                socklen_t len = sizeof(addr);
                if (::getsockname(fd, reinterpret_cast<struct sockaddr*>(&addr), &len) == 0) {
                    outPort = ntohs(addr.sin_port);
                }
            } else {
                struct sockaddr_in6 addr6 {};
                addr6.sin6_family = AF_INET6;
                addr6.sin6_addr = in6addr_any;
                addr6.sin6_port = 0;
                if (::bind(fd, reinterpret_cast<struct sockaddr*>(&addr6), sizeof(addr6)) < 0) {
                    close_fd(fd);
                    return false;
                }
                socklen_t len = sizeof(addr6);
                if (::getsockname(fd, reinterpret_cast<struct sockaddr*>(&addr6), &len) == 0) {
                    outPort = ntohs(addr6.sin6_port);
                }
            }
            return true;
        };

        if (!bind_udp(audioFd_, localAudioPort_) || !bind_udp(controlFd_, localControlPort_) ||
            !bind_udp(timingFd_, localTimingPort_)) {
            if (err) *err = "本地分配 UDP 端口失败: " + std::string(std::strerror(errno));
            return false;
        }
        // 发送缓冲：系统默认（macOS 约 9 KB）只够 ~8 个 ALAC 包，一旦上层灌得快一点就 ENOBUFS。
        // 提到 256 KB（≈180 个包，>2 s 音频）后，瞬时抖动由内核吸收，不必靠重试硬扛。
        // 失败不致命（有些系统会静默夹住），继续用默认值。
        const int sndbuf = static_cast<int>(kSendBufferBytes);
        ::setsockopt(audioFd_, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        return true;
    }

    bool setup_server_audio_addr(std::string* err) {
        if (interleaved_) return true;   // 交织模式不需要 UDP 目标
        if (peerAddrLen_ == 0) {
            if (err) *err = "内部错误: 尚未建立 RTSP 连接，无法确定音频目的地址";
            return false;
        }
        serverAudioAddr_ = peerAddr_;
        serverAudioAddrLen_ = peerAddrLen_;
        if (serverAudioAddr_.ss_family == AF_INET) {
            reinterpret_cast<struct sockaddr_in*>(&serverAudioAddr_)->sin_port = htons(serverAudioPort_);
        } else if (serverAudioAddr_.ss_family == AF_INET6) {
            reinterpret_cast<struct sockaddr_in6*>(&serverAudioAddr_)->sin6_port = htons(serverAudioPort_);
        } else {
            if (err) *err = "内部错误: 对端地址族未知";
            return false;
        }
        return true;
    }

    std::string get_local_ip_str() const {
        if (!localIpStr_.empty()) return localIpStr_;
        return (localFamily_ == AF_INET6) ? "::1" : "127.0.0.1";
    }

    std::string session_uri() const {
        return "rtsp://" + cfg_.host + ":" + std::to_string(cfg_.port) + "/" + sessionId_;
    }

    std::string clientInstance() {
        // 稳定但每个进程不同：用 SSRC + 一次性随机，避免所有实例都自称同一个 Client-Instance。
        char buf[17];
        std::snprintf(buf, sizeof(buf), "%08X%08X", rtpSsrc_, static_cast<uint32_t>(rng_()));
        return std::string(buf, 16);
    }

    void record_handshake(const std::string& item) {
        if (!handshakeLog_.empty()) handshakeLog_ += " / ";
        handshakeLog_ += item;
    }

private:
    RaopConfig cfg_;
    std::unique_ptr<rta::audio::AlacEncoder> encoder_;
    std::mt19937_64 rng_;

    // isOpen_ 会被 timing 线程（maybe_sync）读、被上层线程写：必须是原子的。
    std::atomic<bool> isOpen_{false};
    bool interleaved_ = false;   // 只在 open() 里设置（线程启动之前），之后只读
    bool recorded_ = false;

    int tcpFd_ = -1;
    int audioFd_ = -1;
    int controlFd_ = -1;
    int timingFd_ = -1;

    int localFamily_ = AF_INET;
    uint16_t localAudioPort_ = 0;
    uint16_t localControlPort_ = 0;
    uint16_t localTimingPort_ = 0;

    uint16_t serverAudioPort_ = 0;
    uint16_t serverControlPort_ = 0;
    uint16_t serverTimingPort_ = 0;
    uint32_t deviceAudioLatencyFrames_ = 0;

    // 时间轴：anchorRtp_ 在 anchorTime_ 时刻应当“正在播”。
    mutable std::mutex anchorMtx_;
    uint32_t anchorRtp_ = 0;
    std::chrono::steady_clock::time_point anchorTime_{};
    std::chrono::steady_clock::time_point openSteady_{};
    std::chrono::steady_clock::time_point lastSyncSteady_{};
    bool timelineStarted_ = false;
    uint32_t latencyFrames_ = kRaopDefaultLatencyFrames;
    double prebufferSeconds_ = kRaopDefaultPrebufferSeconds;

    // open() 的总预算：解析/连接/每条 RTSP 请求都要落在它之内（仅 open 期间生效）。
    std::chrono::steady_clock::time_point openDeadline_{};
    std::atomic<bool> openDeadlineActive_{false};

    // 暂停窗口：起点是包边界时间戳，恢复时按原 seq/rtptime 补发 [起点, rtpTimestamp_)。
    bool pauseWindowValid_ = false;
    uint32_t pauseWindowStartRtp_ = 0;

    // 实际连上的对端地址（UDP 目标 + NACK 来源校验的唯一依据）。
    struct sockaddr_storage peerAddr_{};
    socklen_t peerAddrLen_ = 0;

    // 仅测试用注入（默认空 = 生产路径）。
    ResolveHook resolveHook_;
    UdpSendHook udpSendHook_;

    std::atomic<bool> timingRun_{false};
    std::atomic<bool> controlRun_{false};
    std::atomic<bool> timingAlive_{false};
    std::atomic<bool> controlAlive_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> transportFailed_{false};
    std::thread timingThread_;
    std::thread controlThread_;

    struct sockaddr_storage serverAudioAddr_{};
    socklen_t serverAudioAddrLen_ = 0;

    std::string localIpStr_;
    std::string sessionId_;
    std::string serverSessionId_;
    int cseq_ = 0;

    uint16_t rtpSeq_ = 0;
    uint32_t rtpTimestamp_ = 0;
    uint32_t rtpSsrc_ = 0;
    int framesPerPacket_ = kRaopFramesPerPacket;

    std::atomic<uint64_t> packetsSent_{0};
    std::atomic<uint64_t> bytesSent_{0};
    std::atomic<uint64_t> syncPacketsSent_{0};
    std::atomic<uint64_t> timingRequests_{0};
    std::atomic<uint64_t> timingReplies_{0};
    std::atomic<uint64_t> timingMalformed_{0};
    std::atomic<uint64_t> nackRequests_{0};
    std::atomic<uint64_t> retransmits_{0};
    std::atomic<uint64_t> nackMisses_{0};
    std::atomic<uint64_t> nackRejected_{0};
    std::atomic<uint64_t> sendErrors_{0};
    std::atomic<uint64_t> sendRetries_{0};
    std::atomic<uint64_t> resumeReplays_{0};
    std::atomic<uint64_t> resolverCalls_{0};
    std::atomic<uint64_t> consecutiveSendErrors_{0};
    std::atomic<uint64_t> latePackets_{0};
    std::atomic<int64_t> minAheadFrames_{kAheadUnset};
    std::atomic<int64_t> lastAheadFrames_{0};
    std::atomic<int> lastErrno_{0};
    std::atomic<uint32_t> lastSyncRtp_{0};
    std::atomic<uint64_t> lastSyncNtp_{0};

    std::string tcpRecvBuf_;
    std::vector<int16_t> pendingPcm_;
    size_t pendingOffset_ = 0;
    std::string handshakeLog_;

    raop::RtpPacketCache cache_;
    std::mutex tcpSendMtx_;
    mutable std::mutex errMtx_;
    std::string lastTransportError_;
    Failure lastFailure_;
};

}  // namespace rta::net
