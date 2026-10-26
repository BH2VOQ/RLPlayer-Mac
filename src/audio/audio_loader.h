// audio_loader.h — 统一音频读取入口
//
// WAV 走原生解析（wav.h），保持逐位精确、零依赖。
// 其他格式（FLAC / ALAC / MP3 / AAC / OGG / Opus / WMA / DSF / DFF ...）
// 交给系统上已有的 ffmpeg 解码成【对应位深的 PCM WAV】，再用原生 WAV 读取。
//
// 为什么这样做：
//   * 解码是确定性过程。无损格式（FLAC/ALAC/WavPack/APE）解出来的 PCM 与原文件
//     携带的 PCM 完全一致 —— 因此不会破坏"比特完美"这一核心主张。
//   * 不需要引入任何第三方库的二进制或授权问题。
//   * ffmpeg 对每种格式都是参考实现级别的正确性。
//
// 位深处理：先探测源的真实位深，再用 pcm_s16le / pcm_s24le / pcm_s32le 请求，
//   避免把 24-bit 素材降成 16-bit，也避免把 16-bit 素材无谓地抬成 24-bit。
#pragma once
// ---------------- macOS 移植（2026-10-25，PLATFORM.md §13.12）----------------
// 本头历史上直连 Win32（windows.h + CreateProcessW + wstring 命令行）。macOS 侧不重写
// 调用点：保持 run_hidden(wstring)/widen 等【签名不变】，wstring 仅作命令行载体——
// POSIX 分支把 wchar_t 串按"保序字节"还原成 UTF-8 后交给 platform::run_hidden
// （posix_spawn，PLATFORM.md §9.6）。widen/wide_to_utf8 在 POSIX 上是保序恒等。
#include "platform/process.h"
#include "platform/path.h"
#include <unistd.h>
#include <cerrno>
#include <poll.h>
#include <sys/stat.h>
#include "audio/wav.h"
#include "audio/dsd_reader.h"
#include "dsp/dsd_integrator.h"
#include <string>
#include <vector>
#include <cstdio>
#include <algorithm>
#include <stdexcept>
#include <new>
#include <chrono>
#include <thread>
#include <cstring>
#include <atomic>

namespace rta::audio {

inline std::string lowerExt(const std::string& p) {
    const size_t d = p.find_last_of('.');
    if (d == std::string::npos) return "";
    std::string e = p.substr(d);
    std::transform(e.begin(), e.end(), e.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return e;
}

// ---------------- POSIX 桥接（wstring 只是命令行载体，见文件头注）----------------
inline std::wstring widen(const std::string& s) {
    return std::wstring(s.begin(), s.end());    // UTF-8 字节保序进 wchar_t（不转码）
}
inline std::string narrow(const std::wstring& w) {
    std::string s;
    s.reserve(w.size());
    for (wchar_t c : w) s += (char)(c & 0xFF);  // 保序还原 UTF-8 字节
    return s;
}
inline std::string wide_to_utf8(const std::wstring& w) { return narrow(w); }
inline int run_hidden(const std::wstring& cmdline, std::string* captured = nullptr) {
    const rta::platform::ProcessResult r =
        rta::platform::run_hidden(narrow(cmdline), captured != nullptr);
    if (captured) *captured = r.output;
    return r.started ? r.exit_code : -1;
}
inline std::wstring exe_dir_w() {
    const std::string d = rta::platform::module_dir_utf8();
    return std::wstring(d.begin(), d.end());
}
// 工具可执行性自检（2026-10-26 二次 DEBUG 修，debug/20261026-01）：
//   「找到工具」≠「工具能跑」。本机系统 ffmpeg/ffprobe 因 libx265 缺失 `-version` 直接
//   退出 134（SIGABRT），find_executable 仍会返回路径 ⟹ 解码链路拿到坏工具才在很远处
//   抛 "ffmpeg 解码失败（退出码 134）"，与真因（工具链坏了）脱钩（铁律 3）。
//   这里对候选做一次 `-version` 自检，不可用就跳过。
inline bool tool_runnable(const std::string& exe) {
    if (exe.empty()) return false;
    const std::wstring cmd = L"\"" + widen(exe) + L"\" -version";
    return run_hidden(cmd, nullptr) == 0;
}
inline std::string find_tool(const char* name) {
    // ① 环境变量覆盖（RLPLAYER_FFMPEG / RLPLAYER_FFPROBE 等）—— 换机器/自定义工具链的
    //    正当产品能力；不设时行为与之前一致。
    {
        std::string envName = "RLPLAYER_";
        for (const char* p = name; *p; ++p) envName += (char)std::toupper((unsigned char)*p);
        if (const char* env = std::getenv(envName.c_str())) {
            if (env[0] && tool_runnable(env)) return std::string(env);
        }
    }
    // ② exe 同目录（无 .exe 后缀）→ PATH，但必须通过 -version 自检
    const std::string found = rta::platform::find_executable(name);
    if (tool_runnable(found)) return found;
    // ③ 自建 ffmpeg-lite（系统工具链坏掉时的既定可用件）。两处候选：
    //    a) 与可执行同目录（发布形态：.app/Contents/MacOS/ffmpeg-lite/）
    //    b) 从可执行目录向上找 build-mac/ffmpeg-lite/（开发/测试形态：ctest 二进制在
    //       build-mac/ 或 /tmp，仓库根的 lite 才是真的那份）
    if (std::string(name) == "ffmpeg" || std::string(name) == "ffprobe") {
        const std::string md = rta::platform::module_dir_utf8();
        const std::string cand1 = md + "/ffmpeg-lite/" + name;
        if (tool_runnable(cand1)) return cand1;
        std::string up = md;
        for (int depth = 0; depth < 4 && !up.empty(); ++depth) {
            const std::string cand = up + "/build-mac/ffmpeg-lite/" + name;
            if (tool_runnable(cand)) return cand;
            const size_t slash = up.find_last_of('/');
            if (slash == std::string::npos || slash == 0) break;
            up = up.substr(0, slash);
        }
    }
    return found;   // 都不可用时仍返回找到的路径，让调用方的错误文案带出真实路径
}
// 删临时文件（两平台同名；失败静默——清理动作不该掩盖主流程错误）
inline void remove_temp(const std::string& p) { std::remove(p.c_str()); }
// 源文件可读性自检的 POSIX 版（Windows 版语义见下方注释）：
// 用 access(R_OK) 问 errno 要人话原因，与 Win32 探针同一返回约定（空=可读）。
inline std::string source_read_probe(const std::string& path) {
    if (::access(path.c_str(), R_OK) == 0) return "";
    switch (errno) {
        case ENOENT:  return "源文件此刻不存在（可能正在被移动/标签写回/删除，或刚被改名）";
        case EACCES:  return "没有读取权限（ACL / 只读介质 / 受保护目录）";
        default:      return "无法打开，errno " + std::to_string(errno);
    }
}


// 用 ffprobe 探测源文件的真实位深，返回 16/24/32；失败返回 24
inline int probe_bit_depth(const std::string& ffprobe, const std::string& file) {
    if (ffprobe.empty()) return 24;
    std::string out;
    const std::wstring cmd = L"\"" + widen(ffprobe) + L"\" -v error -select_streams a:0 "
                             L"-show_entries stream=bits_per_raw_sample -of default=nw=1:nk=1 \"" + widen(file) + L"\"";
    if (run_hidden(cmd, &out) != 0) return 32;
    // 有损格式（MP3/AAC/OGG/Opus）的 bits_per_raw_sample 是 N/A，atoi 得 0。
    // 这种情况绝不能当成 16 bit：解码器内部是 float，提前量化到 16 bit 会引入
    // 实测 -101 dBFS RMS 的量化误差（峰值 -96 dBFS），而且是在 DSP 之前。
    // 未知一律按 32 bit 请求，让量化只发生在最后按用户选择的位深做抖动时。
    const int v = atoi(out.c_str());
    if (v <= 0) return 32;
    if (v <= 16) return 16;
    if (v <= 24) return 24;
    return 32;
}

struct LoadNote {
    std::string text;
    double ffmpegMs = 0.0;   // ffmpeg 转码写入临时 WAV 耗时 (ms)
    double wavReadMs = 0.0;  // 读取临时/原生 WAV 耗时 (ms)
    double totalMs = 0.0;    // 解码总耗时 (ms)
};

// DSD 源抽取设置（由 rtaweb / rtaplay 按配置写入；默认 FIR + narrow）
// 为什么用全局：read_any 的签名在很多地方被调用，加参数会波及媒体信息、库扫描与预解码槽。
// 代价是"播放线程与预解码线程可能短暂看到不同设置"，最多影响一首歌的开头，可接受。
struct DsdPcmSettings {
    dsp::IntegratorKind kind = dsp::IntegratorKind::Fir;
    dsp::DsdConversion  conversion = dsp::DsdConversion::Narrow;
    bool                twoStage = true;
};
inline DsdPcmSettings& dsd_pcm_settings() { static DsdPcmSettings s; return s; }

// 流式解码开关（ROADMAP P6b：免临时 WAV，默认 1 开启）
// 可通过设置键 streamdecode（/api/settings）、环境变量 RLPLAYER_STREAM_DECODE、
// 或 C++ set_stream_decode_enabled(bool) 进行控制，保持随时可回退。
struct StreamDecodeSettings {
    bool enabled = true;
};
inline StreamDecodeSettings& stream_decode_settings() { static StreamDecodeSettings s; return s; }
// 2026-10-25 macOS 移植：POSIX 侧的流式管道已补齐（read_via_ffmpeg_stream），
// 本函数恢复与 Windows 完全相同的判定逻辑，不再是恒 false 的占位。
// 优先级：环境变量（非空时）> 设置项。环境变量只认下面这 6 个字面量，
// 其余取值（含 "2"、空串）一律不改变判定 —— 与 Windows 侧逐字一致。
inline bool is_stream_decode_enabled() {
    const char* env = std::getenv("RLPLAYER_STREAM_DECODE");
    if (env && env[0] != '\0') {
        if (std::strcmp(env, "0") == 0 || std::strcmp(env, "false") == 0 || std::strcmp(env, "off") == 0)
            return false;
        if (std::strcmp(env, "1") == 0 || std::strcmp(env, "true") == 0 || std::strcmp(env, "on") == 0)
            return true;
    }
    return stream_decode_settings().enabled;
}
inline void set_stream_decode_enabled(bool en) {
    stream_decode_settings().enabled = en;
}

// 从匿名管道读取 WAV 音频流并填充到 AudioBuffer（非阻塞读、分块拼装、逐位精确）
//
// 2026-10-25 POSIX 移植（PLATFORM.md §13.12）。与 Windows 版（git HEAD 同名函数）
// 逐条对齐的语义，缺一不可：
//   ① 非阻塞读：O_NONBLOCK + poll() 取代 PeekNamedPipe 轮询可用字节。
//      读端设成非阻塞，read() 没数据时立刻 EAGAIN，主循环靠 poll 决定"等"还是"退"。
//   ② 任意非对齐边界分块拼装：24-bit 样本 3 字节、32-bit 4 字节，管道边界可以落在
//      样本中间。leftover[] 缓存跨块残字节，拼满 bytesPer 才 decode_sample —— 这是
//      逐位精确的前提（不许按"整块"取整丢掉尾巴）。
//   ③ 样本逐位精确：解码只走 decode_sample（与 read_wav 同一函数），不做任何缩放/取整。
//   ④ 异常退出码透传：本函数只管读，退出码由调用方 waitpid 拿；但**读失败原因**要
//      通过 errOut 带出去，不能让"管道断了"变成"帧数为空"这种无信息错误。
//   ⑤ 读完排空（drain）：子进程退出后管道里可能还有没读走的数据，必须继续读到 EOF。
//      ⚠️ 实测修正（2026-10-25，别照抄我最初的猜测）：
//        · 我最初写的是"不排空 ⟹ ffmpeg 吃 SIGPIPE 被杀"。**变异测试证明这句夸大了**：
//          把 drain 分支整个删掉，69 条判据仍全绿。原因见下。
//        · 真正保证"不丢尾"的是**主循环的 EOF 兜底**：read_once() 读到 0 字节就置
//          eofSeen，主循环 `if (eofSeen) break;` 之前的 while 已经把管道里剩余字节
//          全部读走了（read_once 每次只读一个块，循环直到 EOF）。drain 分支只是
//          "子进程已退出但 EOF 还没到"这条时序的**加速通道**，与 EOF 兜底互为冗余。
//        · SIGPIPE 的真实形态：父进程**主动提前 close 读端**才会让 ffmpeg 拿到 EPIPE
//          （实测退出码 141 = 128+13）。本实现从不提前关读端 —— 读端由调用方在
//          read_wav_stream_pipe 返回**之后**才 close，且返回前已读到 EOF。所以只要
//          "读完才关"这条顺序不破，SIGPIPE 就不会发生；这与是否走 drain 分支无关。
//        · 保留 drain 的理由：①与 Windows 原实现（finalAvail 循环）语义对齐；
//          ②在"进程先退、EOF 后到"的时序下少一轮 poll 等待；③它是显式的正确性
//          意图表达，删掉后只剩 EOF 兜底这一条隐式保证，后人改 read_once 容易踩。
//        · 实测证据：ffmpeg 在 5.3M 样本 / 60 秒 M4A 上退出码 0（未被信号杀死），
//          见 tests/test_stream_decode.cpp 第 2 节与 SIGPIPE 专项探针。
//   ⑥ 头部 1MB 防御上限 + 30 秒头超时：与 Windows 侧同一常量、同一判据。
inline bool read_wav_stream_pipe(int fd, rta::platform::PipeProcess& proc,
                                 AudioBuffer& ab, std::string* errOut = nullptr) {
    std::vector<uint8_t> hbuf;
    WavHeaderInfo hdr{};
    bool hdrOk = false;
    constexpr size_t kMaxHeaderBytes = 1 << 20; // 1 MB 上限防异常
    const auto t_start = std::chrono::steady_clock::now();
    bool eofSeen = false;                       // 读到 EOF（写端全关）
    bool procExited = false;                    // 子进程已退出（用非阻塞 waitpid 探）

    // 非阻塞探一次子进程是否已退出。等价于 Windows 的 WaitForSingleObject(hProcess, 0)。
    // 不用阻塞 wait：主循环要"退出后继续排空"，阻塞 wait 会把这一步卡死。
    auto poll_exited = [&]() -> bool {
        if (procExited) return true;
        int status = 0;
        const pid_t r = ::waitpid(proc.pid, &status, WNOHANG);
        if (r == proc.pid) {
            procExited = true;
            proc.pid = -1;                      // 已被本函数回收，wait() 不该再等
            proc.exit_status_ = status;         // 交给调用方判定退出码
        }
        return procExited;
    };

    // 读一次管道：返回读到的字节数；0 = EOF；-1 = 暂无数据（EAGAIN）；-2 = 硬错误。
    // timeout_ms < 0 表示不等待（纯非阻塞探一次）；否则 poll 等这么久。
    auto read_once = [&](std::vector<uint8_t>& dst, size_t cap, int timeout_ms) -> long {
        if (fd < 0 || eofSeen) return 0;
        struct ::pollfd pfd{};
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        const int pr = ::poll(&pfd, 1, timeout_ms);
        if (pr == 0) return -1;                             // 超时，无数据
        if (pr < 0) {
            if (errno == EINTR) return -1;
            if (errOut) *errOut = std::string("poll 管道失败，errno ") + std::to_string(errno);
            return -2;
        }
        const size_t off = dst.size();
        dst.resize(off + cap);
        ssize_t got = 0;
        do {
            got = ::read(fd, dst.data() + off, cap);
        } while (got < 0 && errno == EINTR);
        if (got > 0) { dst.resize(off + (size_t)got); return (long)got; }
        dst.resize(off);
        if (got == 0) { eofSeen = true; return 0; }          // 写端全关 = EOF
        if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;
        if (errno == EPIPE) { eofSeen = true; return 0; }    // 写端已关，按 EOF 处理
        if (errOut) *errOut = std::string("读取管道失败，errno ") + std::to_string(errno);
        return -2;
    };

    // ---- 阶段一：凑齐 WAV 头 ----
    while (!hdrOk) {
        std::vector<uint8_t> chunk;
        const long got = read_once(chunk, 4096, 20 /* ms */);
        if (got == -2) return false;
        if (got > 0) {
            hbuf.insert(hbuf.end(), chunk.begin(), chunk.end());
            std::string err;
            const int r = parse_wav_header(hbuf.data(), hbuf.size(), hdr, &err);
            if (r > 0) { hdrOk = true; break; }
            if (r < 0) { if (errOut) *errOut = err; return false; }
            if (hbuf.size() > kMaxHeaderBytes) {
                if (errOut) *errOut = "WAV 头超过 1MB 防御上限";
                return false;
            }
            continue;
        }
        // got <= 0：没数据（-1）或 EOF（0）。EOF 时还要给 parse 最后一次机会。
        if (eofSeen) {
            std::string err;
            const int r = parse_wav_header(hbuf.data(), hbuf.size(), hdr, &err);
            if (r > 0) { hdrOk = true; break; }
            if (errOut) *errOut = err.empty() ? "WAV 头不完整或进程提前退出" : err;
            return false;
        }
        if (poll_exited()) {
            // 子进程退出：先排空再判断（管道里可能还有完整头部）
            std::vector<uint8_t> rest;
            while (read_once(rest, 65536, 0) > 0) {
                hbuf.insert(hbuf.end(), rest.begin(), rest.end());
                rest.clear();
            }
            std::string err;
            const int r = parse_wav_header(hbuf.data(), hbuf.size(), hdr, &err);
            if (r > 0) { hdrOk = true; break; }
            if (errOut) *errOut = err.empty() ? "WAV 头不完整或进程提前退出" : err;
            return false;
        }
        if (std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - t_start).count() > 30) {
            if (errOut) *errOut = "读取 WAV 头超时";
            return false;
        }
    }

    ab.rate = hdr.rate;
    ab.channels = (int)hdr.channels;
    ab.bits = (int)hdr.bits;
    ab.isFloat = hdr.isFloat;
    const int bytesPer = (int)hdr.bits / 8;
    if (bytesPer <= 0 || ab.channels <= 0) {
        if (errOut) *errOut = "非法的 bits 或 channels";
        return false;
    }

    // ---- 阶段二：头部之后的残余字节先解掉（可能包含完整样本 + 半样本尾巴）----
    const size_t pcmStart = hdr.headerBytes;
    const size_t initPcmBytes = hbuf.size() > pcmStart ? (hbuf.size() - pcmStart) : 0;
    uint8_t leftover[4] = {0, 0, 0, 0};
    size_t leftoverCount = 0;

    if (initPcmBytes > 0) {
        const size_t completeSamples = initPcmBytes / (size_t)bytesPer;
        ab.raw.resize(completeSamples);
        const uint8_t* p = hbuf.data() + pcmStart;
        for (size_t i = 0; i < completeSamples; ++i)
            ab.raw[i] = decode_sample(p + i * (size_t)bytesPer, ab.bits, ab.isFloat);
        leftoverCount = initPcmBytes % (size_t)bytesPer;
        if (leftoverCount > 0)
            std::memcpy(leftover, p + completeSamples * (size_t)bytesPer, leftoverCount);
    }
    hbuf.clear();
    hbuf.shrink_to_fit();

    // ---- 阶段三：主循环读 PCM（分块拼装 + 退出后排空）----
    std::vector<uint8_t> readChunk;
    readChunk.reserve(65536);
    while (true) {
        readChunk.clear();
        const long got = read_once(readChunk, 65536, 20 /* ms */);
        if (got == -2) return false;
        if (got > 0) {
            size_t chunkOff = 0;
            const size_t g = (size_t)got;
            if (leftoverCount > 0) {
                const size_t needed = (size_t)bytesPer - leftoverCount;
                if (g >= needed) {
                    std::memcpy(leftover + leftoverCount, readChunk.data(), needed);
                    ab.raw.push_back(decode_sample(leftover, ab.bits, ab.isFloat));
                    leftoverCount = 0;
                    chunkOff = needed;
                } else {
                    std::memcpy(leftover + leftoverCount, readChunk.data(), g);
                    leftoverCount += g;
                    continue;
                }
            }
            const size_t rem = g - chunkOff;
            const size_t numSamples = rem / (size_t)bytesPer;
            if (numSamples > 0) {
                const size_t oldSz = ab.raw.size();
                ab.raw.resize(oldSz + numSamples);
                const uint8_t* p = readChunk.data() + chunkOff;
                for (size_t i = 0; i < numSamples; ++i)
                    ab.raw[oldSz + i] = decode_sample(p + i * (size_t)bytesPer, ab.bits, ab.isFloat);
            }
            leftoverCount = rem % (size_t)bytesPer;
            if (leftoverCount > 0)
                std::memcpy(leftover, readChunk.data() + chunkOff + numSamples * (size_t)bytesPer,
                            leftoverCount);
            continue;
        }
        // got <= 0：EOF 或暂时无数据
        if (eofSeen) break;                                  // 写端全关，数据已读完
        if (poll_exited()) {
            // ★ 排空：子进程已退出，但管道缓冲里可能还有数据。
            //   这里用 timeout=0 的纯非阻塞读把剩余字节全部取走，直到 EOF。
            //   注：这不是"防 SIGPIPE"的唯一保障（真正的保障是"读到 EOF 才 close 读端"，
            //   以及主循环的 EOF 兜底）—— 详见函数头注释 ⑤ 的实测修正。
            while (true) {
                std::vector<uint8_t> rest;
                const long more = read_once(rest, 65536, 0);
                if (more <= 0) break;
                size_t chunkOff = 0;
                const size_t g = (size_t)more;
                if (leftoverCount > 0) {
                    const size_t needed = (size_t)bytesPer - leftoverCount;
                    if (g >= needed) {
                        std::memcpy(leftover + leftoverCount, rest.data(), needed);
                        ab.raw.push_back(decode_sample(leftover, ab.bits, ab.isFloat));
                        leftoverCount = 0;
                        chunkOff = needed;
                    } else {
                        std::memcpy(leftover + leftoverCount, rest.data(), g);
                        leftoverCount += g;
                        continue;
                    }
                }
                const size_t rem = g - chunkOff;
                const size_t numSamples = rem / (size_t)bytesPer;
                if (numSamples > 0) {
                    const size_t oldSz = ab.raw.size();
                    ab.raw.resize(oldSz + numSamples);
                    const uint8_t* p = rest.data() + chunkOff;
                    for (size_t i = 0; i < numSamples; ++i)
                        ab.raw[oldSz + i] = decode_sample(p + i * (size_t)bytesPer, ab.bits, ab.isFloat);
                }
                leftoverCount = rem % (size_t)bytesPer;
                if (leftoverCount > 0)
                    std::memcpy(leftover, rest.data() + chunkOff + numSamples * (size_t)bytesPer,
                                leftoverCount);
            }
            break;
        }
    }
    // 收尾：不足一个样本的残字节按 Windows 原实现丢弃（不是截断数据，是管道尾部的
    // 半个样本 —— 正常 ffmpeg 输出不会出现；出现说明数据源本身坏了，此时保留会让
    // frames() 与 read_wav 的算法不一致）。
    return true;
}


// ---------------- DSD 流式解码（大文件；不整曲入内存） ----------------
//
// 为什么需要（2026-10-25 用户实测：384 s DSD64 / 271 MB）：
//   整曲原生解码要同时握住「1-bit 流 + 每声道 double 平面 + int32 缓冲」三层数据 ——
//   实测解码 4.9 s、缓冲 517 MB、进程峰值 1813 MB，起播前就先卡住、吃掉近 2 GB。
//   流式解码只保留「一个块」（DSF 默认 4 KB/声道）与抽取器状态：
//   起播延迟 = 一块的时间，内存 = 常数，与文件长度无关。
//
// 逐位一致性：与 read_dsd_native 使用同一个 DsdDecimator、同一组设置、同样的块边界
// （从第 0 位开始按块连续喂），因此 PCM 输出与整曲解码逐位相同 —— 测试里逐样本比对。
// 跳转（seek）会重建抽取器状态并从块边界重新开始；调用方按现有惯例预卷 0.5 s 丢弃，
// 抽取器瞬态因此落在被丢弃的区段里（与整曲缓冲 + seek_reset 的既有行为一致）。

struct DsdFileLayout {
    bool     isDsf = false;
    uint32_t rate = 0;                 // 1-bit 采样率
    int      channels = 0;
    uint64_t bitsPerChannel = 0;       // 每声道有效位数
    uint64_t bytesPerChannel = 0;      // 每声道字节数
    uint64_t dataOffset = 0;           // 数据区在文件内的绝对偏移
    uint64_t dataSize = 0;             // 数据区总字节
    uint32_t blockSize = 0;            // DSF：每声道块字节数；DFF：0（内部按 4 KB 读块）
    bool     paddedLastBlock = true;   // DSF 末块是否按整块补齐
    std::string container;             // "dsf" / "dff"
};

// 跨平台 64 位文件定位
inline int dsd_fseek64(FILE* f, int64_t off, int origin) {
    return ::fseeko(f, (off_t)off, origin);   // mac：fseeko（原 Windows _fseeki64 分支已删）
}

// 只读文件头（不载入数据）：给"要不要走流式"的判断与流式解码器用。
inline DsdFileLayout probe_dsd_layout(const std::string& path) {
    using namespace dsd_detail;
    const std::string ext = lowerExt(path);
    DsdFileLayout L;
    FILE* f = dsd_fopen(path, L"rb", "rb");
    if (!f) throw std::runtime_error("无法打开文件: " + path);
    struct Guard { FILE* f; ~Guard() { if (f) std::fclose(f); } } g{ f };
    auto rd = [&](uint64_t off, void* buf, size_t n) -> size_t {
        if (dsd_fseek64(f, (int64_t)off, SEEK_SET) != 0) return 0;
        return std::fread(buf, 1, n, f);
    };

    if (ext == ".dsf") {
        uint8_t h[28];
        if (rd(0, h, 28) != 28 || std::memcmp(h, "DSD ", 4) != 0)
            throw std::runtime_error("不是 DSF 文件（缺少 \"DSD \" 头）: " + path);
        if (rdl64(h + 4) != 28) throw std::runtime_error("DSF 头长度异常");
        uint64_t off = 28;
        bool haveFmt = false, haveData = false;
        uint32_t chNum = 0, rate = 0, blockSize = 0;
        uint64_t sampleCnt = 0;
        for (int guard = 0; guard < 64 && !haveData; ++guard) {
            uint8_t ch[12];
            if (rd(off, ch, 12) != 12) break;
            const uint64_t sz = rdl64(ch + 4);
            if (sz < 12) break;
            if (std::memcmp(ch, "fmt ", 4) == 0) {
                if (sz < 52) throw std::runtime_error("DSF fmt 块长度异常");
                std::vector<uint8_t> fb((size_t)sz);
                if (rd(off + 12, fb.data(), fb.size()) != fb.size())
                    throw std::runtime_error("DSF fmt 块被截断");
                const uint32_t fmtId = rdl32(fb.data() + 4);
                chNum     = rdl32(fb.data() + 12);
                rate      = rdl32(fb.data() + 16);
                const uint32_t bps = rdl32(fb.data() + 20);
                sampleCnt = rdl64(fb.data() + 24);
                blockSize = rdl32(fb.data() + 32);
                if (fmtId != 0) throw std::runtime_error("DSF 为 DST 压缩，暂不支持流式解码");
                if (bps != 1) throw std::runtime_error("DSF bits per sample 非 1");
                if (chNum < 1 || chNum > 8) throw std::runtime_error("DSF 声道数异常");
                if (rate < 44100) throw std::runtime_error("DSF 采样率异常");
                if (blockSize == 0 || blockSize > (1u << 20)) throw std::runtime_error("DSF 块长异常");
                if (sampleCnt == 0) throw std::runtime_error("DSF 样本数为 0");
                haveFmt = true;
            } else if (std::memcmp(ch, "data", 4) == 0) {
                L.dataOffset = off + 12;
                L.dataSize   = sz - 12;
                haveData = true;
                break;
            }
            off += (size_t)sz;
        }
        if (!haveFmt) throw std::runtime_error("DSF 缺少 fmt 块");
        if (!haveData) throw std::runtime_error("DSF 缺少 data 块");
        const uint64_t needBytes  = (sampleCnt + 7) / 8;
        const uint64_t fullBlocks = needBytes / blockSize;
        const uint64_t remBytes   = needBytes % blockSize;
        const uint64_t needData   = (fullBlocks + (remBytes ? 1 : 0)) * (uint64_t)chNum * blockSize;
        if (L.dataSize < (uint64_t)chNum * 8) throw std::runtime_error("DSF data 块过短");
        L.isDsf = true;
        L.rate = rate; L.channels = (int)chNum;
        L.bitsPerChannel = sampleCnt;
        L.bytesPerChannel = needBytes;
        L.blockSize = blockSize;
        L.paddedLastBlock = (L.dataSize >= needData);
        L.container = "dsf";
        return L;
    }
    if (ext == ".dff") {
        uint8_t h[16];
        if (rd(0, h, 16) != 16 || std::memcmp(h, "FRM8", 4) != 0)
            throw std::runtime_error("不是 DFF(DSDIFF) 文件: " + path);
        if (std::memcmp(h + 12, "DSD ", 4) != 0)
            throw std::runtime_error("DFF form type 不是 \"DSD \"（DST 不支持）");
        const uint64_t frm8Size = rdb64(h + 4);
        const uint64_t end = 12 + frm8Size;
        uint32_t rate = 0, declaredCh = 0;
        std::string cmpType;
        bool haveData = false;
        for (uint64_t off = 16; off + 12 <= end; ) {
            uint8_t ch[12];
            if (rd(off, ch, 12) != 12) break;
            const uint64_t sz = rdb64(ch + 4);
            if (sz > (1ull << 62)) break;
            if (std::memcmp(ch, "PROP", 4) == 0) {
                std::vector<uint8_t> body((size_t)sz);
                if (rd(off + 12, body.data(), body.size()) != body.size())
                    throw std::runtime_error("DFF PROP 块被截断");
                if (body.size() >= 4 && std::memcmp(body.data(), "SND ", 4) == 0) {
                    size_t q = 4;
                    while (q + 12 <= body.size()) {
                        const uint64_t ss = rdb64(body.data() + q + 4);
                        const uint8_t* p = body.data() + q + 12;
                        if (q + 12 + ss > body.size()) break;
                        if (std::memcmp(body.data() + q, "FS  ", 4) == 0 && ss >= 4) rate = rdb32(p);
                        else if (std::memcmp(body.data() + q, "CHNL", 4) == 0 && ss >= 2) declaredCh = rdb16(p);
                        else if (std::memcmp(body.data() + q, "CMPR", 4) == 0 && ss >= 4) cmpType.assign((const char*)p, 4);
                        q += 12 + (size_t)ss + (size_t)(ss & 1);
                    }
                }
            } else if (std::memcmp(ch, "DSD ", 4) == 0) {
                L.dataOffset = off + 12;
                L.dataSize = sz;
                haveData = true;
                break;
            } else if (std::memcmp(ch, "DST ", 4) == 0 || std::memcmp(ch, "DSTI", 4) == 0) {
                throw std::runtime_error("DFF 使用 DST 压缩，暂不支持流式解码");
            }
            off += 12 + sz + (sz & 1);
        }
        if (!haveData) throw std::runtime_error("DFF 缺少 DSD 数据块");
        if (rate == 0) throw std::runtime_error("DFF 缺少 FS");
        if (!cmpType.empty() && cmpType != "DSD ") throw std::runtime_error("DFF 压缩类型不是 DSD");
        const uint32_t ch = declaredCh ? declaredCh : 2;
        if (ch < 1 || ch > 8) throw std::runtime_error("DFF 声道数异常");
        if (L.dataSize == 0 || L.dataSize % ch != 0) throw std::runtime_error("DFF DSD 数据长度异常");
        L.isDsf = false;
        L.rate = rate; L.channels = (int)ch;
        L.bytesPerChannel = L.dataSize / ch;
        L.bitsPerChannel = L.bytesPerChannel * 8;
        L.blockSize = 0;
        L.paddedLastBlock = true;
        L.container = "dff";
        return L;
    }
    throw std::runtime_error("不是 DSD 文件（按扩展名判断）: " + path);
}


// 流式 DSD -> PCM 读取器：按「块」读原始 1-bit 流、逐块抽取，内存与文件长度无关。
// 用法：
//   DsdPcmStream s; std::string err;
//   if (!s.open(path, dsd_pcm_settings(), &err)) { /* 回退整曲路径 */ }
//   AudioBuffer chunk; s.read(0, 4096, chunk);        // 任意位置（顺序读最快）
class DsdPcmStream {
public:
    DsdPcmStream() = default;
    ~DsdPcmStream() { if (f_) std::fclose(f_); }
    DsdPcmStream(const DsdPcmStream&) = delete;
    DsdPcmStream& operator=(const DsdPcmStream&) = delete;

    bool open(const std::string& path, const DsdPcmSettings& st, std::string* errOut = nullptr) {
        close();
        try {
            layout_ = probe_dsd_layout(path);
        } catch (const std::exception& e) {
            if (errOut) *errOut = e.what();
            return false;
        }
        outRate_ = std::min<uint32_t>(layout_.rate / 16u, 705600u);
        if (outRate_ == 0 || layout_.rate % outRate_ != 0) {
            if (errOut) *errOut = "DSD 采样率无法整数抽取（" + std::to_string(layout_.rate) + " → " +
                                  std::to_string(outRate_) + "）";
            return false;
        }
        cfg_ = dsp::conversion_integrator(st.kind, st.conversion, layout_.rate, outRate_, 120.0, st.twoStage);
        dec_.clear();
        for (int c = 0; c < layout_.channels; ++c)
            dec_.push_back(std::make_unique<dsp::DsdDecimator>(cfg_));
        f_ = dsd_detail::dsd_fopen(path, L"rb", "rb");
        if (!f_) { if (errOut) *errOut = "无法打开文件: " + path; return false; }
        ch_ = layout_.channels;
        M_ = layout_.rate / outRate_;
        totalFrames_ = (size_t)(layout_.bitsPerChannel / M_);
        readBlock_ = layout_.isDsf ? layout_.blockSize : 4096u;
        if (readBlock_ == 0) readBlock_ = 4096u;
        scratch_.assign(readBlock_, 0);
        pending_.assign((size_t)ch_, {});
        reset_to(0);
        return true;
    }

    void close() {
        if (f_) { std::fclose(f_); f_ = nullptr; }
        dec_.clear();
        pending_.clear();
        curBit_ = 0; absFrames_ = 0; totalFrames_ = 0;
    }
    bool is_open() const { return f_ != nullptr; }
    uint32_t rate() const { return outRate_; }
    int channels() const { return ch_; }
    size_t totalFrames() const { return totalFrames_; }
    double seconds() const { return outRate_ ? (double)totalFrames_ / (double)outRate_ : 0.0; }
    uint64_t streamBytes() const { return layout_.dataSize; }
    const DsdFileLayout& layout() const { return layout_; }

    // 读取 [pos, pos+n) 帧，写入 out（rate/channels/bits 会被填好）。
    // 返回实际产出的帧数（到文件末尾会变短）。
    size_t read(size_t pos, size_t n, AudioBuffer& out) {
        out.rate = outRate_; out.channels = ch_; out.bits = 32; out.isFloat = false; out.raw.clear();
        if (!f_ || ch_ <= 0 || n == 0 || pos >= totalFrames_) return 0;
        if (n > totalFrames_ - pos) n = totalFrames_ - pos;
        const uint64_t wantEnd = (uint64_t)pos + (uint64_t)n;
        const uint64_t haveBegin = pendStart_;
        const uint64_t haveEnd = pendStart_ + (uint64_t)pendCount();
        // 顺序读命中 → 直接续；向后跳/回头 → 重建状态（块边界对齐）
        if ((uint64_t)pos < haveBegin || (uint64_t)pos > haveEnd) reset_to((uint64_t)pos * (uint64_t)M_);
        size_t guard = 0;
        while (pendStart_ + (uint64_t)pendCount() < wantEnd && guard++ < 1000000u) {
            if (!feed_next_block()) break;
        }
        const uint64_t availEnd = pendStart_ + (uint64_t)pendCount();
        if (availEnd <= (uint64_t)pos) return 0;
        const size_t take = (size_t)(std::min<uint64_t>(wantEnd, availEnd) - (uint64_t)pos);
        const size_t skip = (size_t)((uint64_t)pos - pendStart_);
        out.raw.resize(take * (size_t)ch_);
        for (int c = 0; c < ch_; ++c) {
            const auto& v = pending_[(size_t)c];
            for (size_t i = 0; i < take; ++i)
                out.setSample(i, c, v[skip + i]);
        }
        // 丢掉已消费的前缀，控制内存（每次最多留下不到一块）
        const size_t drop = skip + take;
        for (auto& v : pending_) v.erase(v.begin(), v.begin() + (long long)drop);
        pendStart_ = (uint64_t)pos + take;
        return take;
    }

private:
    size_t pendCount() const { return pending_.empty() ? 0 : pending_[0].size(); }

    void reset_to(uint64_t bitIndex) {
        const uint64_t blockBits = (uint64_t)readBlock_ * 8ull;
        const uint64_t aligned = (bitIndex / blockBits) * blockBits;
        curBit_ = aligned;
        absFrames_ = curBit_ / (uint64_t)M_;
        pendStart_ = absFrames_;
        for (auto& d : dec_) d->reset();
        for (auto& v : pending_) v.clear();
    }

    bool feed_next_block() {
        if (!f_) return false;
        const uint64_t blockBytes = readBlock_;
        if (curBit_ / 8ull >= layout_.bytesPerChannel) return false;
        const uint64_t b = curBit_ / (blockBytes * 8ull);
        const uint64_t byteOff = b * blockBytes;
        if (byteOff >= layout_.bytesPerChannel) return false;
        const size_t thisBlock = (size_t)std::min<uint64_t>(blockBytes, layout_.bytesPerChannel - byteOff);
        for (int c = 0; c < ch_; ++c) {
            uint64_t src = 0;
            if (layout_.isDsf) {
                const uint64_t base = layout_.dataOffset + b * (uint64_t)ch_ * (uint64_t)layout_.blockSize;
                const uint64_t stride = layout_.paddedLastBlock ? (uint64_t)layout_.blockSize : (uint64_t)thisBlock;
                src = base + (uint64_t)c * stride;
            } else {
                src = layout_.dataOffset + (uint64_t)c * layout_.bytesPerChannel + byteOff;
            }
            if (scratch_.size() < thisBlock) scratch_.resize(thisBlock, 0);
            size_t got = 0;
            if (dsd_fseek64(f_, (int64_t)src, SEEK_SET) == 0)
                got = std::fread(scratch_.data(), 1, thisBlock, f_);
            if (got < thisBlock) std::memset(scratch_.data() + got, 0, thisBlock - got);
            if (layout_.isDsf)
                for (size_t i = 0; i < thisBlock; ++i) scratch_[i] = dsd_detail::reverse_bits8(scratch_[i]);
            dec_[(size_t)c]->process_bits(scratch_.data(), thisBlock * 8, pending_[(size_t)c]);
        }
        curBit_ += (uint64_t)thisBlock * 8ull;
        absFrames_ = curBit_ / (uint64_t)M_;
        pendStart_ = absFrames_ - (uint64_t)pendCount();
        return true;
    }

    DsdFileLayout layout_;
    FILE* f_ = nullptr;
    uint32_t outRate_ = 0;
    uint32_t M_ = 1;
    int ch_ = 0;
    uint32_t readBlock_ = 4096;
    uint64_t curBit_ = 0;        // 已喂给抽取器的位数（每声道）
    size_t   absFrames_ = 0;     // 抽取器已产出的帧数
    size_t   totalFrames_ = 0;
    uint64_t pendStart_ = 0;     // pending_[c][0] 对应的绝对帧号
    dsp::IntegratorConfig cfg_;
    std::vector<std::unique_ptr<dsp::DsdDecimator>> dec_;
    std::vector<std::vector<double>> pending_;
    std::vector<uint8_t> scratch_;
};


// ---------------- 大文件流式播放策略（阈值可配置） ----------------
// 「解码后大小」超过阈值的 DSD 文件不再整曲预解码，改走 DsdPcmStream 流式解码。
// 为什么用解码后大小而不是文件大小：DSD64 的 271 MB 文件解成 PCM 是 517 MB，
// 而 DSD128/256 的文件更小、解码后更大 —— 判据必须落在真正会占内存的量上。
struct BigFileStreamSettings {
    bool    enabled = true;
    double  thresholdMb = 200.0;    // 解码后 > 200 MB 走流式（默认值来自实测：517 MB 的文件会卡 5 s）
    double  ispPrescanSec = 20.0;   // 流式播放的过采样峰值只扫开头这么长（整曲扫描要再解一遍）
};
inline BigFileStreamSettings& big_file_stream_settings() { static BigFileStreamSettings s; return s; }

// 该文件能否流式解码（只读文件头，不加载数据）。decodedBytes 返回解码后的 PCM 字节数。
inline bool dsd_streamable(const std::string& path, double* decodedMb = nullptr, std::string* why = nullptr) {
    try {
        const DsdFileLayout L = probe_dsd_layout(path);
        const uint32_t outRate = std::min<uint32_t>(L.rate / 16u, 705600u);
        if (outRate == 0 || L.rate % outRate != 0) {
            if (why) *why = "DSD 采样率无法整数抽取";
            return false;
        }
        const size_t frames = (size_t)(L.bitsPerChannel / (uint64_t)(L.rate / outRate));
        if (decodedMb) *decodedMb = (double)frames * (double)L.channels * 4.0 / (1024.0 * 1024.0);
        return true;
    } catch (const std::exception& e) {
        if (why) *why = e.what();
        return false;
    }
}

// 是否应该对这次播放走流式（只看文件头）：DSD 且解码后超过阈值 且 开关打开。
inline bool should_stream_decode(const std::string& path, double* decodedMb = nullptr, std::string* why = nullptr) {
    const std::string ext = lowerExt(path);
    if (ext != ".dsf" && ext != ".dff") { if (why) *why = "非 DSD 文件"; return false; }
    const BigFileStreamSettings& s = big_file_stream_settings();
    if (!s.enabled) { if (why) *why = "流式播放已关闭(stream_threshold_mb=0)"; return false; }
    double mb = 0.0;
    std::string whyLocal;
    if (!dsd_streamable(path, &mb, &whyLocal)) { if (why) *why = whyLocal; return false; }
    if (decodedMb) *decodedMb = mb;
    if (mb <= s.thresholdMb) { if (why) *why = "解码后 " + std::to_string((long long)mb) + " MB 低于阈值"; return false; }
    return true;
}

// DSD 源：原生读取 + 我们的抽取器（ROADMAP P0-1/P0-4/P0-5）
//
// 以前 .dsf/.dff 走 ffmpeg 解成 PCM：多一层量化、拿不到 1-bit 流、DirectSDM 无从谈起。
// 现在读原始位流，按设置用 FIR / IIR / CIC 抽取到 DSD/16（上限 705.6 kHz），
// 后续升频/抖动/SDM 完全不变。读取失败仍回退 ffmpeg（保持可用）。
inline AudioBuffer read_dsd_native(const std::string& path, LoadNote* note) {
    const auto t_dsd_0 = std::chrono::steady_clock::now();
    DsdStream s = read_dsd(path);
    const uint32_t outRate = std::min<uint32_t>(s.rate / 16u, 705600u);
    const DsdPcmSettings st = dsd_pcm_settings();
    const dsp::IntegratorConfig cfg =
        dsp::conversion_integrator(st.kind, st.conversion, s.rate, outRate, 120.0, st.twoStage);
    dsp::DsdDecimator dec(cfg);
    auto planes = dec.process(s);

    AudioBuffer out;
    out.rate = outRate;
    out.channels = s.channels;
    out.bits = 32;
    out.isFloat = false;
    const size_t n = planes.empty() ? 0 : planes[0].size();
    out.raw.resize(n * (size_t)s.channels);
    for (size_t i = 0; i < n; ++i)
        for (int c = 0; c < s.channels; ++c)
            out.setSample(i, c, planes[(size_t)c][i]);

    const auto t_dsd_1 = std::chrono::steady_clock::now();
    if (note) {
        char buf[320];
        std::snprintf(buf, sizeof(buf),
                      "DSD 原生解码：%s %u Hz → PCM %u Hz（%s%s / %s 通带 %.1f kHz / 阻带 %.1f kHz）",
                      s.container.c_str(), s.rate, outRate,
                      dec.isTwoStage() ? "两级 " : "",
                      dsp::integrator_name(cfg.kind), dsp::conversion_name(st.conversion),
                      cfg.passbandHz / 1000.0, dec.stopbandStartHz() / 1000.0);
        note->text = buf;
        note->totalMs = std::chrono::duration<double, std::milli>(t_dsd_1 - t_dsd_0).count();
    }
    return out;
}

// ffmpeg 解码：写临时 WAV 文件再原生读取（旧路径，作为流式不支持或关闭时的完整回退路径）
inline AudioBuffer read_via_ffmpeg_file(const std::string& path, LoadNote* note = nullptr) {
    const std::string ext = lowerExt(path);
    const std::string ffmpeg  = find_tool("ffmpeg");
    const std::string ffprobe = find_tool("ffprobe");
    if (ffmpeg.empty()) {
        throw std::runtime_error(
            "需要 ffmpeg 才能解码 " + ext + " 文件：把 ffmpeg.exe（以及 ffprobe.exe）放到播放器"
            "同目录，或加进 PATH。WAV / DSF / DFF 不需要 ffmpeg。");
    }

    const int bits = probe_bit_depth(ffprobe, path);
    const char* codec = (bits <= 16) ? "pcm_s16le" : (bits <= 24 ? "pcm_s24le" : "pcm_s32le");

    // POSIX：临时目录用 platform 层（含尾分隔符契约）；文件名用 pid+原子计数保证并发唯一
    static std::atomic<unsigned long long> seq{0};
    std::string tmpPath = rta::platform::temp_dir_utf8() + "rta" +
                          std::to_string((unsigned long)::getpid()) + "-" +
                          std::to_string(seq.fetch_add(1)) + ".wav";
const std::wstring cmd = L"\"" + widen(ffmpeg) + L"\" -v error -y -i \"" + widen(path) +
                             L"\" -vn -c:a " + widen(codec) + L" -f wav \"" + widen(tmpPath) + L"\"";

    // ---- 瞬时故障重试（2026-10-22 现场 BUG：FLAC 间歇性 -42 Illegal byte sequence）----
    // 根因有两层，都在这里治：
    //   ① ffmpeg 打不开输入时会【回退到 ANSI 代码页】再试一次；含非 ASCII 字符的路径在这个
    //      回退里被 MultiByteToWideChar(CP_ACP, MB_ERR_INVALID_CHARS) 判成非法序列，于是
    //      「文件此刻不在」/「被独占占用」统统被报成 EILSEQ(-42 "Illegal byte sequence")。
    //      实测（包内 ffmpeg 9.0）：日文名 + 存在 → exit=0；日文名 + 独占占用 → exit=-42；
    //      纯 ASCII 名 + 独占占用 → exit=-13(Permission denied)。即 -42 是【掩码】不是原因。
    //   ② 触发这类瞬时不可读的现实场景：标签写回(备份 rename + 替换 rename 的窗口)、
    //      同步客户端/杀毒扫描短暂占用、用户在资源管理器里改名。
    // 所以：失败后用 Win32 问「此刻到底能不能读、为什么读不了」。
    // 注意：首次失败（i == 0）后必须至少再试一次，「此刻可读」不能排除「刚刚在 ffmpeg 运行期间才释放独占」；
    // 只有在已重试（i >= 1）且探针证明此刻仍可读时，才说明是真正的解码错误并提前退出。
    const auto t_total_0 = std::chrono::steady_clock::now();
    constexpr int kDecodeTries = 3;
    int rc = -1;
    int attempts = 0;
    std::string fflog;                     // ffmpeg 的 stderr（错误时进错误文本，不吞不瞒）
    std::string unreadable;                // 非空 = 此刻源文件读不了（Win32 权威原因）
    double ffmpeg_ms = 0.0;
    for (int i = 0; i < kDecodeTries; ++i) {
        ++attempts;
        fflog.clear();
        if (i > 0) {
            // 上一轮可能留下半成品；清掉再让 ffmpeg 重建，避免把半截 WAV 当产物
            std::remove(tmpPath.c_str());
            std::this_thread::sleep_for(std::chrono::milliseconds(120 * i));  // 退避语义一致
        }
        const auto t_ff_0 = std::chrono::steady_clock::now();
        rc = run_hidden(cmd, &fflog);
        const auto t_ff_1 = std::chrono::steady_clock::now();
        ffmpeg_ms += std::chrono::duration<double, std::milli>(t_ff_1 - t_ff_0).count();
        if (rc == 0) break;
        unreadable = source_read_probe(path);
        // 关键判据修正（2026-10-23 回归）：除 rc==0 退出外，首轮失败（i == 0）必须至少再试一次。
        // 根因：在真实场景（标签写回 rename 窗口、杀毒扫描或同步客户端短暂独占）以及 CI 云机环境中，
        // 占用方极可能恰好在 ffmpeg 尝试期间松手；ffmpeg 进程退出时探针虽然检测到「此刻可读」
        // （unreadable 为空），但这恰恰证明瞬时占用刚刚解除，进行第二轮重试即可成功！
        // 若在 i==0 时因「此刻可读」就 break，就会把本可恢复的瞬时占用直接报成解码失败（现场那种
        // 「重试一下就好」的用户痛点，以及 CI 云机上 ffmpeg 耗时 >150ms 导致尝试 1 次即失败的竞态）。
        // 因此：只有在已经至少重试过一次之后（i >= 1），且探针明确说明源文件此刻可读时，
        // 才能证明故障并非瞬时占用引起（而是真正的格式/解码损坏），此时方可提前 break 退出。
        if (i >= 1 && unreadable.empty()) break;
    }

    // ffmpeg 输出压成单行、截断，方便进一行的错误日志
    std::string ffTail;
    for (char c : fflog) {
        if (c == '\r' || c == '\n') { if (!ffTail.empty() && ffTail.back() != ' ') ffTail.push_back(' '); }
        else ffTail.push_back(c);
    }
    if (!ffTail.empty() && ffTail.back() == ' ') ffTail.pop_back();
    if (ffTail.size() > 300) ffTail = ffTail.substr(0, 300) + "...";

    // HF-03：ffmpeg 退出后先检查临时 WAV 存在与大小，再交给 read_wav。
    // 产物缺失/过小说明 ffmpeg 解码异常，直接报「ffmpeg 解码产物异常」并带路径与字节数。
    auto size_of = [](const std::string& p) -> long long {
        struct ::stat st{};
        if (::stat(p.c_str(), &st) != 0) return -1;
        return (long long)st.st_size;
    };
    const long long tmpBytes = size_of(tmpPath);
    const std::string tmpBytesTxt = (tmpBytes < 0) ? "未知(文件不存在)" : (std::to_string(tmpBytes) + " 字节");

    AudioBuffer buf;
    double wav_ms = 0.0;
    try {
        if (rc != 0) {
            // -42 = -EILSEQ。ffmpeg 对非 ASCII 路径会用它掩盖真实原因（详见上面重试循环的注释），
            // 所以这里把 Win32 探到的真实原因放在最前面：日志读起来必须是「读不了，因为 X」，
            // 而不是让用户/我们自己去猜 "Illegal byte sequence" 是什么意思。
            std::string why;
            if (rc == -42) {
                why = "ffmpeg 报非法字节序列(-42/EILSEQ)。该退出码只说明 ffmpeg 在非 ASCII 路径上"
                      "回退到 ANSI 代码页后失败，不代表文件真有编码问题";
                why += unreadable.empty()
                    ? "（重试期间源文件已可读：更像是 ffmpeg 打开瞬间的偶发失败）"
                    : "；真实原因：" + unreadable;
            } else {
                why = "ffmpeg 解码失败";
                if (!unreadable.empty()) why += "（源文件此刻读不了：" + unreadable + "）";
            }
            throw std::runtime_error(why + "（退出码 " + std::to_string(rc) +
                                     "，尝试 " + std::to_string(attempts) + " 次，源文件=" + path +
                                     "，临时WAV=" + tmpPath + "，大小=" + tmpBytesTxt +
                                     (ffTail.empty() ? "" : "，ffmpeg输出=" + ffTail) + "）");
        }
        if (tmpBytes < 44)
            throw std::runtime_error("ffmpeg 解码产物异常: 临时 WAV 缺失或过小(源文件=" + path +
                                     "，临时WAV=" + tmpPath + "，大小=" + tmpBytesTxt + "，退出码=0)");
        const auto t_wav_0 = std::chrono::steady_clock::now();
        buf = read_wav(tmpPath);
        const auto t_wav_1 = std::chrono::steady_clock::now();
        wav_ms = std::chrono::duration<double, std::milli>(t_wav_1 - t_wav_0).count();
    } catch (...) {
        remove_temp(tmpPath);
        throw;
    }
    remove_temp(tmpPath);

    const auto t_total_1 = std::chrono::steady_clock::now();
    if (note) {
        note->text = std::string("已用 ffmpeg 解码 ") + ext + " -> " + codec;
        note->ffmpegMs = ffmpeg_ms;
        note->wavReadMs = wav_ms;
        note->totalMs = std::chrono::duration<double, std::milli>(t_total_1 - t_total_0).count();
    }
    return buf;
}

// ffmpeg 流式解码路径（ROADMAP P6b：直接读管道输出，不落临时 WAV 文件）
//
// 2026-10-25 POSIX 移植（PLATFORM.md §13.12）。对照 Windows 原实现
//（git HEAD:src/audio/audio_loader.h 的 read_via_ffmpeg_stream）逐项对齐：
//   CreatePipe(stdout) + CreatePipe(stderr)  -> PipeProcess::start（两个 ::pipe()）
//   CloseHandle(outWr/errWr)                 -> start() 内立刻 close 写端
//   后台线程收 stderr（防管道填满卡死）       -> 同样是后台线程（语义必须保留：
//                                                ffmpeg 的 stderr 写满 64KB 会阻塞，
//                                                我们不读 stderr 就会死锁）
//   read_wav_stream_pipe + PeekNamedPipe     -> read_wav_stream_pipe（poll + O_NONBLOCK）
//   WaitForSingleObject + GetExitCodeProcess -> PipeProcess::wait（waitpid）
//   重试 3 次 + 退避 120ms*i                 -> 同参数
inline AudioBuffer read_via_ffmpeg_stream(const std::string& path, LoadNote* note = nullptr) {
    const std::string ext = lowerExt(path);
    const std::string ffmpeg  = find_tool("ffmpeg");
    const std::string ffprobe = find_tool("ffprobe");
    if (ffmpeg.empty()) {
        throw std::runtime_error(
            "需要 ffmpeg 才能解码 " + ext + " 文件：把 ffmpeg（以及 ffprobe）放到播放器"
            "同目录，或加进 PATH。WAV / DSF / DFF 不需要 ffmpeg。");
    }

    const int bits = probe_bit_depth(ffprobe, path);
    const char* codec = (bits <= 16) ? "pcm_s16le" : (bits <= 24 ? "pcm_s24le" : "pcm_s32le");
    // pipe:1 = stdout。ffmpeg 的 wav muxer 在不可 seek 的输出上会写 0xFFFFFFFF
    // 的长度字段（实测本机 ffmpeg 8.1.2：RIFF sz 与 data sz 均为 0xFFFFFFFF），
    // parse_wav_header 已按"流式管道未定长度"处理，不需要额外分支。
    const std::wstring cmd = L"\"" + widen(ffmpeg) + L"\" -v error -i \"" + widen(path) +
                             L"\" -vn -c:a " + widen(codec) + L" -f wav pipe:1";
    const auto t_total_0 = std::chrono::steady_clock::now();
    constexpr int kDecodeTries = 3;
    int rc = -1;
    int attempts = 0;
    std::string fflog;
    std::string unreadable;
    double ffmpeg_ms = 0.0;
    AudioBuffer buf;
    bool success = false;
    std::string streamError;

    for (int i = 0; i < kDecodeTries; ++i) {
        ++attempts;
        fflog.clear();
        streamError.clear();
        buf = AudioBuffer{};

        if (i > 0) std::this_thread::sleep_for(std::chrono::milliseconds(120 * i));  // 退避

        rta::platform::PipeProcess proc;
        const auto t_ff_0 = std::chrono::steady_clock::now();
        if (!proc.start(narrow(cmd))) {
            rc = -1;
            streamError = std::string("启动 ffmpeg 失败（pipe/posix_spawn），errno ") + std::to_string(errno);
            unreadable = source_read_probe(path);
            if (i >= 1 && unreadable.empty()) break;
            continue;
        }

        // 非阻塞读端：PeekNamedPipe 的等价物。必须在读之前设好。
        if (!proc.set_stdout_nonblocking()) {
            proc.close_fds();
            (void)proc.wait();
            rc = -1;
            streamError = "设置管道 O_NONBLOCK 失败";
            unreadable = source_read_probe(path);
            if (i >= 1 && unreadable.empty()) break;
            continue;
        }

        // stderr 必须并发读走：ffmpeg 的 stderr 一旦写满管道缓冲（macOS 64KB）就会阻塞，
        // 而它阻塞后不再往 stdout 写，我们读 stdout 也会跟着卡死 —— 双向死锁。
        // 这是 Windows 原实现里那条 errThread 的等价物，不是可省的性能优化。
        const int errFd = proc.err_fd;
        proc.err_fd = -1;                       // 所有权移交给线程
        std::thread errThread([errFd, &fflog] {
            char ebuf[4096];
            ssize_t eg = 0;
            while ((eg = ::read(errFd, ebuf, sizeof(ebuf))) > 0) fflog.append(ebuf, (size_t)eg);
            ::close(errFd);
        });

        bool readOk = false;
        try {
            readOk = read_wav_stream_pipe(proc.out_fd, proc, buf, &streamError);
        } catch (const std::exception& ex) {
            streamError = ex.what();
            readOk = false;
        }
        if (proc.out_fd >= 0) { ::close(proc.out_fd); proc.out_fd = -1; }

        // 先等进程退出再判读结果：退出码是"ffmpeg 到底成没成"的唯一权威。
        rc = proc.wait();
        errThread.join();

        const auto t_ff_1 = std::chrono::steady_clock::now();
        ffmpeg_ms += std::chrono::duration<double, std::milli>(t_ff_1 - t_ff_0).count();

        if (rc == 0 && readOk && buf.frames() > 0) {
            success = true;
            break;
        }
        // 退出码 0 但读失败/零帧：把 readOk 的失败原因并进日志，否则错误文本只剩"帧数为空"
        if (rc == 0 && !readOk && !streamError.empty()) fflog += " [pipe] " + streamError;

        unreadable = source_read_probe(path);
        // 与 Windows 同一判据修正（2026-10-23 回归）：首轮失败必须至少再试一次。
        if (i >= 1 && unreadable.empty()) break;
    }

    std::string ffTail;
    for (char c : fflog) {
        if (c == '\r' || c == '\n') { if (!ffTail.empty() && ffTail.back() != ' ') ffTail.push_back(' '); }
        else ffTail.push_back(c);
    }
    if (!ffTail.empty() && ffTail.back() == ' ') ffTail.pop_back();
    if (ffTail.size() > 300) ffTail = ffTail.substr(0, 300) + "...";

    if (!success) {
        std::string why;
        if (rc == -42) {
            why = "ffmpeg 报非法字节序列(-42/EILSEQ)。该退出码只说明 ffmpeg 在非 ASCII 路径上"
                  "回退到 ANSI 代码页后失败，不代表文件真有编码问题";
            why += unreadable.empty()
                ? "（重试期间源文件已可读：更像是 ffmpeg 打开瞬间的偶发失败）"
                : "；真实原因：" + unreadable;
        } else if (rc != 0) {
            why = "ffmpeg 解码失败";
            if (!unreadable.empty()) why += "（源文件此刻读不了：" + unreadable + "）";
        } else {
            why = "ffmpeg 解码产物异常: 流式解析失败(" +
                  (streamError.empty() ? "帧数为空" : streamError) + ")";
        }
        throw std::runtime_error(why + "（退出码 " + std::to_string(rc) +
                                 "，尝试 " + std::to_string(attempts) + " 次，源文件=" + path +
                                 (ffTail.empty() ? "" : "，ffmpeg输出=" + ffTail) + "）");
    }

    const auto t_total_1 = std::chrono::steady_clock::now();
    if (note) {
        note->text = std::string("已用 ffmpeg 流式解码 ") + ext + " -> " + codec;
        note->ffmpegMs = ffmpeg_ms;
        note->wavReadMs = 0.0;                  // 流式没有独立的 WAV 读取阶段
        note->totalMs = std::chrono::duration<double, std::milli>(t_total_1 - t_total_0).count();
    }
    return buf;
}

// ffmpeg 解码统一入口（非 WAV / 非 DSD，或 DSD 原生读取失败时的回退路径）
// 优先走流式管道读取（免落临时 WAV 文件）；对需要 seek 的特殊容器或设置关闭时自动回退临时文件。
inline AudioBuffer read_via_ffmpeg(const std::string& path, LoadNote* note = nullptr) {
    if (!is_stream_decode_enabled()) {
        return read_via_ffmpeg_file(path, note);
    }
    try {
        return read_via_ffmpeg_stream(path, note);
    } catch (const std::exception& e) {
        // 源文件探针归因：如果源文件此刻确实读不了（权限/不存在），回退临时文件同样
        // 无法解决，必须直接重抛，保留原始退出码与权威归因。
        const std::string unreadable = source_read_probe(path);
        if (!unreadable.empty()) throw;
        // 源文件此刻可读 ⟹ 流式失败是管道/容器特性（需要 seek 的特殊容器、管道解析失败等），
        // 自动回退到既有临时 WAV 文件路径，并在 note 里说明回退原因（note 语义与 Windows 一致）。
        LoadNote fileNote;
        AudioBuffer b = read_via_ffmpeg_file(path, &fileNote);
        if (note) {
            note->text = "流式解码不适用(" + std::string(e.what()) + ")，已回退临时文件解码：" + fileNote.text;
            note->ffmpegMs = fileNote.ffmpegMs;
            note->wavReadMs = fileNote.wavReadMs;
            note->totalMs = fileNote.totalMs;
        }
        return b;
    }
}

// 统一读取：WAV 原生，DSD 原生（失败回退 ffmpeg），其他格式经 ffmpeg
// HF-03：外层把巨量分配类异常（std::length_error="vector too long" / std::bad_alloc）
// 转成带文件与阶段的明确错误 —— 捕获只为带上下文重抛，绝不吞掉后继续（交接单 §6 红线）。
inline AudioBuffer read_any(const std::string& path, LoadNote* note = nullptr) {
    const std::string ext = lowerExt(path);
    const auto t_any_0 = std::chrono::steady_clock::now();
    try {
        if (ext == ".wav" || ext == ".wave" || ext.empty()) {
            AudioBuffer b = read_wav(path);
            if (note) {
                const auto t_any_1 = std::chrono::steady_clock::now();
                const double ms = std::chrono::duration<double, std::milli>(t_any_1 - t_any_0).count();
                note->wavReadMs = ms;
                note->totalMs = ms;
            }
            return b;
        }
        if (ext == ".dsf" || ext == ".dff") {
            try {
                AudioBuffer b = read_dsd_native(path, note);
                if (note && note->totalMs <= 0.0) {
                    const auto t_any_1 = std::chrono::steady_clock::now();
                    note->totalMs = std::chrono::duration<double, std::milli>(t_any_1 - t_any_0).count();
                }
                return b;
            } catch (const std::length_error& e) {
                throw std::runtime_error(std::string("解码阶段异常: ") + e.what() +
                                         "(文件=" + path + ",阶段=read_dsd_native)");
            } catch (const std::bad_alloc& e) {
                throw std::runtime_error(std::string("解码阶段异常: ") + e.what() +
                                         "(文件=" + path + ",阶段=read_dsd_native)");
            } catch (const std::exception& e) {
                // 回退策略（ROADMAP P0）：读不了的文件仍走 ffmpeg，并在 note 里说明。
                // 注意 length_error/bad_alloc 已在上面被拦截重抛 —— 不允许"vector too long"
                // 被这个回退吞掉后继续播放。
                LoadNote tmp;
                AudioBuffer b = read_via_ffmpeg(path, &tmp);
                if (note) {
                    note->text = std::string("DSD 原生读取失败（") + e.what() + "），已回退 ffmpeg：" + tmp.text;
                    note->ffmpegMs = tmp.ffmpegMs;
                    note->wavReadMs = tmp.wavReadMs;
                    note->totalMs = tmp.totalMs;
                }
                return b;
            }
        }
        return read_via_ffmpeg(path, note);
    } catch (const std::length_error& e) {
        throw std::runtime_error(std::string("解码阶段异常: ") + e.what() +
                                 "(文件=" + path + ",阶段=read_any)");
    } catch (const std::bad_alloc& e) {
        throw std::runtime_error(std::string("解码阶段异常: ") + e.what() +
                                 "(文件=" + path + ",阶段=read_any)");
    }
}

} // namespace rta::audio
