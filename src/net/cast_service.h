// SPDX-FileCopyrightText: 2026 rainlain <https://github.com/okhuoyanyan>
// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// cast_service.h — UPnP 媒体投放后台会话编排与状态模型 (ROADMAP P5b)
#pragma once
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#ifndef _WINSOCK_DEPRECATED_NO_WARNINGS
#define _WINSOCK_DEPRECATED_NO_WARNINGS
#endif
#include "net/thread_join_safe.h"
#include "net/upnp.h"
#include "net/upnp_control.h"
#include "audio/wav.h"
#include "audio/audio_loader.h"
#include "audio/dsd_reader.h"
#include "dsp/dop.h"
#include "dsp/resampler.h"
// 1.1.2 AirPlay(RAOP) 投放后端：mDNS 发现 + ALAC 编码 + RTSP/RTP 推送。
// 这两块是独立纯实现（各有离线测试），本文件只做会话编排。
#include "net/airplay_discovery.h"
#include "net/raop_session.h"
#include "audio/alac_encoder.h"
#include "audio/cast_pcm_convert.h"
#include "net/cast_url_parser.h"
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>

namespace rta::net {

namespace fs = std::filesystem;

inline std::string cast_lower_str(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

inline std::string make_cast_temp_wav_path(const char* tag) {
    std::error_code ec;
    auto td = fs::temp_directory_path(ec);
    static std::atomic<uint64_t> s_seq{0};
    auto name = "rtacast_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())
                + "_" + std::to_string(++s_seq) + "_" + (tag ? tag : "") + ".wav";
    return (td / name).string();
}

// 向 state.warning 追加一条用户可见提示：**去重**（轮询循环里同一句只出现一次，否则每 25 ms
// 刷一遍会把 warning 撑成几百 KB 的重复文本），空串忽略。
inline void cast_append_warning(std::string& w, const std::string& add) {
    if (add.empty()) return;
    if (w.find(add) != std::string::npos) return;
    w = w.empty() ? add : (w + "；" + add);
}

// ── 可听位置 / 自然结束判据（纯函数：离线单测可直接断言边界，不依赖摇摆的墙钟）────────
//
// current_rtp_at() 给的是接收端**源时钟**（不含播放缓冲延迟）；真正在响的帧要减去 latency。
// 求差必须按**模 2^32**：RTP 时间戳会在 ~27 小时后回绕，那时 current 反而小于 start，
// 任何 `current >= start` 形式的判据都会永久失效（进度卡死、EOF 永不成立）。
inline uint64_t cast_audible_frames(uint32_t current_rtp, uint32_t start_rtp, uint32_t latency_frames) {
    const uint32_t elapsed = static_cast<uint32_t>(current_rtp - start_rtp);  // 模 2^32 差值
    return elapsed > latency_frames ? static_cast<uint64_t>(elapsed - latency_frames) : 0ull;
}

// 自然结束 = 尾部补齐被确认 + 全部源帧已送出 + 用户没有中途停止。
// 三者任一不成立都不许报「自然播完」（历史实现忽略 finish() 返回值，失败也报自然结束）。
inline bool cast_natural_end(bool finish_ok, bool all_sent, bool stop_requested) {
    return finish_ok && all_sent && !stop_requested;
}

// ---------------------------------------------------------------------------
// 用户可见错误文案（中文 / 英文并行；**纯函数**，可离线单测 tests/test_cast_service.cpp）
//
// 为什么抽成函数：这些句子带插值（设备描述 URL、查询串、文件路径、SOAP 原因），以前是
// 行内拼接的中文字面量 —— 一旦写坏，单测抓不到（历史事故：那一处
// 「未找到名称/型号包含 "" + p.dev + ""」少了转义，界面上就真的显示一对空引号）。
// 抽出来之后测试可以逐条断言「插值真的进去了」「没有残留 "" 字样」「英文非空且不含中文」。
//
// 纪律：
//   · error（中文）永远是行为真相；errorEn 只是同一事实的另一语言。两者同时设置、同时清空。
//   · 英文分支绝不改变成功/失败判定、不改变 phase、不改变 diag 事件。
//   · 底层原因串只做**可枚举前缀**的精确剥离/映射，绝不逐词贪心翻译（见 strip_dup_cn_prefix）。
// ---------------------------------------------------------------------------
namespace cast_err {

inline std::string replace_all(std::string str, const std::string& from, const std::string& to) {
    if (from.empty()) return str;
    size_t start_pos = 0;
    while ((start_pos = str.find(from, start_pos)) != std::string::npos) {
        str.replace(start_pos, from.length(), to);
        start_pos += to.length();
    }
    return str;
}

inline bool has_cjk(const std::string& s) {
    for (unsigned char c : s) {
        if (c >= 0xE3) return true;
    }
    return false;
}

// 本地音频读取/解码底层异常（源文件格式损坏/截断/缺少块等）的结构化英文转换
inline std::string local_audio_why_en(const std::string& why) {
    if (!has_cjk(why)) return why;

    std::string s = why;

    // 1. 处理常见前缀
    if (s.rfind("无法打开文件: ", 0) == 0) {
        return "cannot open file: " + s.substr(std::string("无法打开文件: ").size());
    }
    if (s.rfind("空文件或无法定长: ", 0) == 0) {
        return "empty file or cannot determine length: " + s.substr(std::string("空文件或无法定长: ").size());
    }
    if (s.rfind("读取不完整: ", 0) == 0) {
        return "incomplete read: " + s.substr(std::string("读取不完整: ").size());
    }
    if (s.rfind("无法写入: ", 0) == 0) {
        return "cannot write: " + s.substr(std::string("无法写入: ").size());
    }
    if (s.rfind("写入不完整: ", 0) == 0) {
        return "incomplete write: " + s.substr(std::string("写入不完整: ").size());
    }
    if (s.rfind("解码阶段异常: ", 0) == 0) {
        return "decoding phase error: " + local_audio_why_en(s.substr(std::string("解码阶段异常: ").size()));
    }

    // 2. 不是合法的 WAV 文件(文件=..., 实际字节=..., 需 RIFF/WAVE 头且≥44 字节)
    static const std::string kBadWavPrefix = "不是合法的 WAV 文件(文件=";
    if (s.rfind(kBadWavPrefix, 0) == 0) {
        size_t pBytes = s.find(", 实际字节=");
        size_t pReq = s.find(", 需 RIFF/WAVE 头且≥44 字节)");
        if (pBytes != std::string::npos && pReq != std::string::npos && pReq > pBytes) {
            std::string filePath = s.substr(kBadWavPrefix.size(), pBytes - kBadWavPrefix.size());
            size_t bytesStart = pBytes + std::string(", 实际字节=").size();
            std::string actualBytes = s.substr(bytesStart, pReq - bytesStart);
            return "not a valid WAV file (file=" + filePath + ", actual bytes=" + actualBytes +
                   ", requires RIFF/WAVE header and >= 44 bytes)";
        }
    }

    // 3. DSD / DSF / DFF 前缀形式
    static const std::string kNotDsfPrefix = "不是 DSF 文件（缺少 \"DSD \" 头）: ";
    if (s.rfind(kNotDsfPrefix, 0) == 0) {
        return "not a DSF file (missing \"DSD \" header): " + s.substr(kNotDsfPrefix.size());
    }
    static const std::string kNotDffPrefix = "不是 DFF(DSDIFF) 文件（缺少 \"FRM8\" 头）: ";
    if (s.rfind(kNotDffPrefix, 0) == 0) {
        return "not a DFF (DSDIFF) file (missing \"FRM8\" header): " + s.substr(kNotDffPrefix.size());
    }
    static const std::string kNotDsdPrefix = "不是 DSD 文件（按扩展名判断）: ";
    if (s.rfind(kNotDsdPrefix, 0) == 0) {
        return "not a DSD file (by extension): " + s.substr(kNotDsdPrefix.size());
    }

    // 4. 带 ctx(...) 后缀的结构化错误：
    // 形如: <HEAD>(文件=<path>, fmtTag=<tag>, ch=<ch>, bps=<bps>, rate=<rate>, dataLen=<len>, 实际文件字节=<bytes>)
    size_t ctxPos = s.rfind("(文件=");
    if (ctxPos != std::string::npos && s.back() == ')') {
        std::string head = s.substr(0, ctxPos);
        std::string ctxTail = s.substr(ctxPos);

        ctxTail = replace_all(ctxTail, "(文件=", "(file=");
        ctxTail = replace_all(ctxTail, ", 实际文件字节=", ", actual file bytes=");

        std::string headEn = head;
        if (head.find("WAV data 块被截断(声明 dataLen=") != std::string::npos) {
            size_t pD = head.find("声明 dataLen=");
            size_t pAvail = head.find(", 块体实际可用=");
            if (pD != std::string::npos && pAvail != std::string::npos) {
                size_t dStart = pD + std::string("声明 dataLen=").size();
                size_t dEnd = head.find(" 字节", dStart);
                std::string decl = head.substr(dStart, dEnd - dStart);
                size_t aStart = pAvail + std::string(", 块体实际可用=").size();
                size_t aEnd = head.find(" 字节", aStart);
                std::string avail = head.substr(aStart, aEnd - aStart);
                headEn = "WAV data chunk truncated (declared dataLen=" + decl +
                         " bytes, chunk body available=" + avail + " bytes)";
            }
        } else if (head.find("WAV fmt 块过短(声明 sz=") != std::string::npos) {
            size_t pSz = head.find("声明 sz=");
            if (pSz != std::string::npos) {
                size_t szStart = pSz + std::string("声明 sz=").size();
                size_t szEnd = head.find(" 字节", szStart);
                std::string sz = head.substr(szStart, szEnd - szStart);
                headEn = "WAV fmt chunk too short (declared sz=" + sz + " bytes, requires >= 16)";
            }
        } else if (head == "WAV 缺少 fmt 块") {
            headEn = "WAV missing fmt chunk";
        } else if (head == "WAV 缺少 data 块") {
            headEn = "WAV missing data chunk";
        } else if (head == "WAV 编码不是线性 PCM(fmtTag 需 1=PCM 或 3=IEEE float)") {
            headEn = "WAV encoding is not linear PCM (fmtTag requires 1=PCM or 3=IEEE float)";
        } else if (head == "float WAV 位深非法(允许 32 或 64)") {
            headEn = "float WAV bit depth invalid (allows 32 or 64)";
        } else if (head.find("float64 WAV 不支持") != std::string::npos) {
            headEn = "float64 WAV not supported (pipeline stores float32), please convert to 32-bit float or integer PCM";
        } else if (head == "WAV 位深非法(允许 8/16/24/32)") {
            headEn = "WAV bit depth invalid (allows 8/16/24/32)";
        } else if (head == "WAV 声道数非法(允许 1..32)") {
            headEn = "WAV channels invalid (allows 1..32)";
        } else if (head.find("WAV 采样率非法") != std::string::npos) {
            size_t pCur = head.find("当前=");
            if (pCur != std::string::npos) {
                size_t rStart = pCur + std::string("当前=").size();
                size_t rEnd = head.find(" Hz", rStart);
                std::string rate = (rEnd != std::string::npos) ? head.substr(rStart, rEnd - rStart) : "";
                headEn = "WAV sample rate invalid (current=" + rate + " Hz, allowed 1..4000000; 0 causes inf duration/progress)";
            } else {
                headEn = "WAV sample rate invalid (allowed 1..4000000)";
            }
        } else if (head == "WAV 位深换算字节数非法(bytesPer<=0)") {
            headEn = "WAV bytes-per-sample invalid (bytesPer<=0)";
        } else if (head.find("WAV data 块越界(dataLen=") != std::string::npos) {
            size_t pD = head.find("dataLen=");
            size_t pAvail = head.find(" > 块体实际可用=");
            if (pD != std::string::npos && pAvail != std::string::npos) {
                std::string dlen = head.substr(pD + 8, pAvail - (pD + 8));
                std::string avail = head.substr(pAvail + std::string(" > 块体实际可用=").size());
                if (!avail.empty() && avail.back() == ')') avail.pop_back();
                headEn = "WAV data chunk out of bounds (dataLen=" + dlen + " > chunk body available=" + avail + ")";
            }
        } else if (head.find("样本数超过防御上限(") != std::string::npos) {
            headEn = replace_all(head, "样本数超过防御上限", "sample count exceeds safety limit");
        }

        return headEn + ctxTail;
    }

    // 5. 其他带括号单参数或具体字段的已知错误
    if (s.rfind("无法确定文件大小(文件=", 0) == 0) {
        return replace_all(replace_all(s, "无法确定文件大小(文件=", "cannot determine file size (file="), ")", ")");
    }
    if (s.rfind("文件为空(文件=", 0) == 0) {
        return replace_all(replace_all(s, "文件为空(文件=", "file is empty (file="), ", 大小=0 字节)", ", size=0 bytes)");
    }
    if (s.rfind("文件超过防御上限(文件=", 0) == 0) {
        std::string res = replace_all(s, "文件超过防御上限(文件=", "file exceeds safety limit (file=");
        res = replace_all(res, ", 大小=", ", size=");
        res = replace_all(res, " 字节, 上限=", " bytes, limit=");
        res = replace_all(res, " 字节)", " bytes)");
        return res;
    }
    if (s.rfind("读取失败(文件=", 0) == 0) {
        std::string res = replace_all(s, "读取失败(文件=", "read failed (file=");
        res = replace_all(res, ", 期望=", ", expected=");
        res = replace_all(res, " 字节)", " bytes)");
        return res;
    }

    // 6. 其他 DSD 错误枚举
    if (s.find("DSF 头长度异常") != std::string::npos) {
        return replace_all(replace_all(s, "DSF 头长度异常（", "DSF header size abnormal ("), "，应为 28）", ", expected 28)");
    }
    if (s == "DSF 缺少 fmt 块或文件被截断") return "DSF missing fmt chunk or file truncated";
    if (s.find("DSF fmt 块长度异常") != std::string::npos) {
        return replace_all(replace_all(s, "DSF fmt 块长度异常（", "DSF fmt chunk size abnormal ("), "）", ")");
    }
    if (s == "DSF fmt 块被截断") return "DSF fmt chunk truncated";
    if (s.find("DSF format id = ") != std::string::npos && s.find("暂不支持") != std::string::npos) {
        return replace_all(s, "（DST 压缩）暂不支持", " (DST compression) not supported");
    }
    if (s.find("DSF bits per sample = ") != std::string::npos) {
        return replace_all(s, "（应为 1）", " (expected 1)");
    }
    if (s == "DSF bits per sample 非 1") return "DSF bits per sample not 1";
    if (s.rfind("DSF 声道数异常: ", 0) == 0) return "DSF channels abnormal: " + s.substr(std::string("DSF 声道数异常: ").size());
    if (s.rfind("DSF 采样率异常: ", 0) == 0) return "DSF sample rate abnormal: " + s.substr(std::string("DSF 采样率异常: ").size());
    if (s.rfind("DSF 每声道块长异常: ", 0) == 0) return "DSF block size per channel abnormal: " + s.substr(std::string("DSF 每声道块长异常: ").size());
    if (s == "DSF 样本数为 0") return "DSF sample count is 0";
    if (s == "DSF 缺少 fmt 块") return "DSF missing fmt chunk";
    if (s == "DSF 缺少 data 块") return "DSF missing data chunk";
    if (s == "DSF data 块过短") return "DSF data chunk too short";
    if (s == "DSF data 块长度不足（文件被截断）") return "DSF data chunk length insufficient (file truncated)";
    if (s.rfind("DSF 声道 ", 0) == 0 && s.find(" 数据不足") != std::string::npos) {
        std::string ch = s.substr(std::string("DSF 声道 ").size());
        size_t end = ch.find(" 数据不足");
        if (end != std::string::npos) ch = ch.substr(0, end);
        return "DSF channel " + ch + " data insufficient";
    }

    if (s == "DFF 的 form type 不是 \"DSD \"（不支持 DST 或其它容器）" ||
        s == "DFF form type 不是 \"DSD \"（DST 不支持）") {
        return "DFF form type is not \"DSD \" (DST or other containers not supported)";
    }
    if (s == "DFF PROP 块不是 \"SND \"") return "DFF PROP chunk is not \"SND \"";
    if (s == "DFF PROP 块被截断") return "DFF PROP chunk truncated";
    if (s == "DFF 使用 DST 压缩（DST 块），暂不支持" || s == "DFF 使用 DST 压缩，暂不支持流式解码") {
        return "DFF uses DST compression (DST chunk), not supported";
    }
    if (s == "DFF 缺少 DSD 数据块") return "DFF missing DSD data block";
    if (s == "DFF 缺少 FS（采样率）子块" || s == "DFF 缺少 FS") return "DFF missing FS (sample rate) subchunk";
    if (s.rfind("DFF 压缩类型不是 \"DSD \"", 0) == 0) {
        return replace_all(replace_all(s, "DFF 压缩类型不是 \"DSD \"（为 \"", "DFF compression type is not \"DSD \" (is \""), "\"）", "\")");
    }
    if (s.rfind("DFF 声道数异常: ", 0) == 0) return "DFF channels abnormal: " + s.substr(std::string("DFF 声道数异常: ").size());
    if (s.rfind("DFF DSD 数据长度 ", 0) == 0) {
        return replace_all(s, " 异常", " abnormal");
    }

    // 7. ffmpeg 解码产物异常
    if (s.rfind("ffmpeg 解码产物异常: 临时 WAV 缺失或过小(源文件=", 0) == 0) {
        std::string res = replace_all(s, "ffmpeg 解码产物异常: 临时 WAV 缺失或过小(源文件=", "ffmpeg decode output abnormal: temp WAV missing or too small (source file=");
        res = replace_all(res, ", 实际字节=", ", actual bytes=");
        res = replace_all(res, " 字节)", " bytes)");
        return res;
    }

    // 未知错误：不逐词机器瞎翻，保留原样以保证事实不失真
    return s;
}

// 底层 http 层的失败串自带「请求失败: <原因>」前缀（src/platform/macos/http_posix.h:260），
// 上层再包一层就成了「…失败: 请求失败: <原因>」。这里只剥离可枚举的重复前缀，
// 剩下的原因**原样保留**（可能是英文 curl 文案，也可能是设备给的中文描述）。
inline std::string strip_dup_cn_prefix(const std::string& s) {
    static const char* kPrefixes[] = {"网络请求失败: ", "网络请求失败：", "网络请求失败",
                                      "请求失败: ", "请求失败：", "请求失败"};
    for (const char* p : kPrefixes) {
        const std::string pf(p);
        if (pf.empty() || s.size() < pf.size()) continue;
        if (s.compare(0, pf.size(), pf) != 0) continue;
        std::string rest = s.substr(pf.size());
        // 前缀后面可能还留着空白/冒号（"请求失败: " 已被整段吃掉，这里只清残留）
        while (!rest.empty()) {
            if (rest.front() == ' ' || rest.front() == ':') rest.erase(rest.begin());
            else if (rest.compare(0, std::string("：").size(), "：") == 0)
                rest.erase(0, std::string("：").size());
            else break;
        }
        return rest;
    }
    return s;
}

// 设备描述 URL 取不到（手动填写 http:// 渲染器描述地址）
inline std::string dev_desc_url_failed(const std::string& url) {
    return "无法从指定设备描述 URL 获取描述: " + url;
}
inline std::string dev_desc_url_failed_en(const std::string& url) {
    return "Could not fetch the device description from the specified URL: " + url;
}

// SSDP 一个都没搜到
inline std::string no_renderer_found() {
    return "局域网内未发现任何 UPnP 渲染器（请检查设备是否开机与网络配置）";
}
inline std::string no_renderer_found_en() {
    return "No UPnP renderer found on the local network (check that the device is powered on and networked)";
}

// 名称/型号未命中：插值必须带引号，且不能出现空引号对（""）
inline std::string dev_not_found(const std::string& query) {
    return "未找到名称/型号包含 \"" + query + "\" 的 UPnP 渲染器";
}
inline std::string dev_not_found_en(const std::string& query) {
    return "No UPnP renderer found whose name/model contains \"" + query + "\"";
}

// DSD 源
inline std::string dsd_read_invalid(const std::string& file) {
    return "DSD 文件读取失败或格式无效: " + file;
}
inline std::string dsd_read_invalid_en(const std::string& file) {
    return "Failed to read the DSD file, or its format is invalid: " + file;
}
inline std::string dsd_pack_failed(const std::string& why) {
    return "DSD 读取/打包失败: " + why;
}
inline std::string dsd_pack_failed_en(const std::string& why) {
    return "DSD decode / DoP packing failed: " + local_audio_why_en(why);
}

// 非 DSD 源
inline std::string wav_read_failed(const std::string& why) {
    return "读取源 WAV 失败: " + why;
}
inline std::string wav_read_failed_en(const std::string& why) {
    return "Failed to read the source WAV: " + local_audio_why_en(why);
}
inline std::string temp_wav_write_failed(const std::string& why) {
    return "解码/写出临时 WAV 失败: " + why;
}
inline std::string temp_wav_write_failed_en(const std::string& why) {
    return "Failed to decode or write the temporary WAV: " + local_audio_why_en(why);
}

// 本地供源 HTTP 服务起不来（端口段全被占）
inline std::string http_server_bind_failed(uint32_t wantPort, uint32_t lastPort) {
    return "无法在 0.0.0.0:" + std::to_string(wantPort) + "–" + std::to_string(lastPort) +
           " 启动 HTTP 供源服务（端口全被占用）";
}
inline std::string http_server_bind_failed_en(uint32_t wantPort, uint32_t lastPort) {
    return "Cannot start the HTTP streaming server on 0.0.0.0:" + std::to_string(wantPort) +
           "-" + std::to_string(lastPort) + " (every port in that range is in use)";
}

// SOAP 原因串的英文版：只映射一条已知中文原因（控制 URL 为空），其余按前缀去重后原样保留。
inline std::string upnp_reason_en(const std::string& raw) {
    static const std::string kEmptyCtrlUrl = "控制 URL 为空，无法执行 ";
    if (raw.compare(0, kEmptyCtrlUrl.size(), kEmptyCtrlUrl) == 0) {
        return "control URL is empty; cannot execute " + raw.substr(kEmptyCtrlUrl.size());
    }
    const std::string rest = strip_dup_cn_prefix(raw);
    // 只剩「请求失败」前缀、没有原因时不要输出空括号："( )" 等于什么都没说。
    // 如实写 no detail，让日志里也能看出"这条确实没带原因"。
    return rest.empty() ? std::string("no detail") : rest;
}

// 「<动作> 失败: <SOAP 原因>」：中文版与历史文案逐字一致，英文版是同一事实的另一语言
inline std::string action_failed(const std::string& action, const UpnpError& e) {
    return action + " 失败: " + e.str();
}
inline std::string action_failed_en(const std::string& action, const UpnpError& e) {
    if (!e.has_error()) return action + " failed: OK";
    return action + " failed: UPnPError " + std::to_string(e.code) + " (" +
           upnp_reason_en(e.description) + ")";
}

}  // namespace cast_err

struct CastState {
    bool        running = false;
    bool        endedNaturally = false; // 本次投放是否因曲目自然播完而结束（主动 stop / 报错 / 未起播均为 false）
    std::string device;
    std::string sourceFile;
    uint16_t    servePort = 8912;
    std::string phase = "stopped"; // discovering, serving, playing, stopped, error
    double      positionSec = 0.0;
    std::string transportState = "STOPPED";
    int64_t     servedBytes = 0;
    int         requestCount = 0;
    // 261024-01 #9：UPnP 作为输出后端时，播放器（底栏进度条 / 时长 / 格式 / 暂停）
    // 的状态统一取这次投放会话 —— 一条会话、一个状态源，避免两套控制互相打架。
    double      durationSec = 0.0;
    uint32_t    sampleRate = 0;
    int         bits = 0;
    bool        paused = false;
    uint32_t    sourceRate = 0;
    int         sourceBits = 0;
    int         sourceChannels = 0;
    bool        resampled = false;
    bool        latencyKnown = false;
    double      latencyMs = 0.0;
    std::string latencySource;
    double      currentVolumeDb = -20.0;
    std::string rateMatch = "unknown"; // match, mismatch, unknown
    std::string warning;
    std::string error;
    // 同一条失败事实的英文版（英文界面用）。error 永远是中文真相，两者同进同退：
    // 会话开始时一起清空，失败时一起写入。英文可能为空（例如底层原因无法英文表述时），
    // 消费方必须按「英文为空 → 回落中文」处理，绝不显示空白。
    std::string errorEn;

    // RenderingControl 音量状态与能力（供后续 HTTP /api/cast/volume 接线）
    bool        volumeSupported = false;
    // 0..100，未知为 -1。**只在接收端确认成功后才更新**：SET_PARAMETER 失败时保持上一次
    // 已确认的数值并把原因写进 lastVolumeError，绝不把「没发出去」显示成「已设为 0%」。
    int         currentVolume = -1;
    std::string lastVolumeError;          // 最近一次 SetVolume 失败的真实错误描述（成功则为空）
};

struct CastStartParams {
    std::string dev;
    std::string file;
    uint16_t    port = 8912;
    uint32_t    rate = 0;
    int         bits = 0;
    double      seconds = 0.0;
    // AirPlay(RAOP) 会话**不接受** DoP/DSD 原生直通：DSD 源必须由调用方置 dop=false
    // （即明确同意解码为 PCM），否则 start() 直接拒绝。UPnP 路径语义不变。
    bool        dop = false;
    // 初始音量（dB，RAOP 标度上限 0 dB）。非有限值 / 越界会被 sanitize_cast_volume_db()
    // 夹到 [-144, 0]；保守默认 -20 dB，绝不以未知/满幅音量起播。
    // 每次 start() 都会用它**覆盖**上一条会话遗留的待发音量请求（不会带到新接收端）。
    double      initialVolumeDb = kCastVolumeDefaultDb;
};

struct CastStartResult {
    bool ok = false;
    std::string error;
};

class CastManager {
public:
    static CastManager& instance() {
        static CastManager s_inst;
        return s_inst;
    }

    CastManager() = default;
    ~CastManager() {
        stop();
    }

    CastManager(const CastManager&) = delete;
    CastManager& operator=(const CastManager&) = delete;

    // diagOut（可空）：把"这次/上次扫描为什么没搜到"如实带出去 —— UI 要显示，
    // 不能让用户对着空的设备列表猜（2026-10-28 用户反馈「UPnP 搜不到设备」）。
    std::vector<UpnpDevice> get_devices(bool forceRescan = false, UpnpDiscoverDiag* diagOut = nullptr) {
        std::lock_guard<std::mutex> lk(devMutex_);
        auto now = std::chrono::steady_clock::now();
        double ageSec = std::chrono::duration<double>(now - lastScanTime_).count();
        if (forceRescan || cachedDevices_.empty() || ageSec > 15.0) {
            cachedDevices_ = upnp_discover(1200, &lastDiag_);
            lastScanTime_ = std::chrono::steady_clock::now();
        }
        if (diagOut) *diagOut = lastDiag_;
        return cachedDevices_;
    }

    UpnpDiscoverDiag last_discovery_diag() {
        std::lock_guard<std::mutex> lk(devMutex_);
        return lastDiag_;
    }

    // ---------------- 1.1.2 AirPlay(RAOP) 投放 ----------------
    // 设备标识约定：location = "airplay://<host>:<port>/<稳定 id>"
    // 为什么复用 location：WebUI 的 castDevValue() 就是取 location 当 value，
    // 这样"AirPlay 也出现在同一个推送到设备列表里"不必改前端取值逻辑。
    static bool is_airplay_dev(const std::string& dev) {
        return rta::net::is_airplay_dev(dev);
    }
    static bool parse_airplay_dev(const std::string& dev, std::string& host, uint16_t& port) {
        return rta::net::parse_airplay_dev(dev, host, port);
    }

    // AirPlay 接收器列表（mDNS 只读浏览，缓存 15 秒，与 UPnP 互不影响）
    std::vector<rta::net::AirPlayDevice> get_airplay_devices(bool forceRescan = false,
                                                             std::string* diagOut = nullptr) {
        std::lock_guard<std::mutex> lk(apMutex_);
        const auto now = std::chrono::steady_clock::now();
        const double ageSec = std::chrono::duration<double>(now - apScanTime_).count();
        if (forceRescan || apDevices_.empty() || ageSec > 15.0) {
            std::string diag;
            // 冷缓存实测：进程刚起时第一次 browse 常常只拿到"本机 AirPlay Receiver"，
            // 接收器要第二轮才出现（mDNS 缓存未热）。所以 1500ms 一轮 + 空结果再补一轮。
            apDevices_ = rta::net::airplay_discover(2500, &diag);
            if (apDevices_.empty()) {
                std::string d2;
                apDevices_ = rta::net::airplay_discover(1500, &d2);
                if (!d2.empty()) diag += "；重试：" + d2;
            }
            apScanTime_ = std::chrono::steady_clock::now();
            apDiag_ = diag;
        }
        if (diagOut) *diagOut = apDiag_;
        return apDevices_;
    }

    // 仅供离线测试注入合成 AirPlay 发现设备（避免触发真实网络与 Bonjour 扫描）
    void set_airplay_devices_for_test(const std::vector<rta::net::AirPlayDevice>& devs) {
        std::lock_guard<std::mutex> lk(apMutex_);
        apDevices_ = devs;
        apScanTime_ = std::chrono::steady_clock::now();
    }

    CastState get_state() {
        std::lock_guard<std::mutex> lk(mtx_);
        return state_;
    }

    CastStartResult start(const CastStartParams& p) {
        if (p.file.empty()) {
            return {false, "未指定音频文件路径"};
        }

        std::string ext = cast_lower_str(rta::audio::lowerExt(p.file));
        bool isDsd = (ext == ".dsf" || ext == ".dff");
        const bool apTarget = is_airplay_dev(p.dev);
        // AirPlay 只能送 PCM：DSD 源必须解码，这里**允许**但在 state.warning 里如实写
        // "DSD 已解码为 PCM"，绝不声称 DSD 直通（AP-1.4）。UPnP 维持原 DoP 闸门。
        //
        // 但 DoP=true 与 AirPlay 是互斥的：RAOP/ALAC 不接受 DoP 载体（24-bit 里塞 DSD 位流），
        // 若照收就是「以为在直通、实际按 PCM 解码」的静默不一致。调用方（rtaweb）对 AirPlay
        // 必须显式置 dop=false；这里明确拒绝，不做隐式降级。
        if (apTarget && p.dop) {
            return {false, "AirPlay(RAOP) 投放不支持 DoP：DSD 源会解码为 PCM 44100 Hz / 16 bit 推送。"
                           "请关闭 DoP（dop=false）后重试"};
        }
        if (isDsd && !p.dop && !apTarget) {
            return {false, "源文件为 DSD 格式 (" + p.file + ")。未开启 DoP 模式，为保证音质拒绝转码为 PCM 降质输出（请勾选 DoP）"};
        }

        std::error_code ec;
#if defined(__cpp_char8_t)
        const fs::path filePath(reinterpret_cast<const char8_t*>(p.file.data()),
                                reinterpret_cast<const char8_t*>(p.file.data() + p.file.size()));
#else
        const fs::path filePath = fs::u8path(p.file);
#endif
        if (!fs::exists(filePath, ec) || ec) {
            return {false, "音频文件不存在: " + p.file};
        }

        // 先把「上一次会话是否还在跑」判掉（短锁），再在锁外 join —— 原来是在持有 mtx_
        // 的情况下 join，worker 退出前若还需要 mtx_ 就会互等；同时和 stop() 共用 threadMx_，
        // 避免两处同时取同一个 std::thread 造成重复 join。
        //
        // 2026-11-04（终版集成）：上面只在 mtx_ 下判一次 running 是不够的 —— 两个并发 start()
        // 可以同时看到 running==false，然后**各自**去 join 同一个 workerThread_、各自覆盖它，
        // 甚至第二条 start() 在第一条刚起播时 join 到整首歌结束（期间 stop() 也可能插进来）。
        // 现在 start()/stop() 整段动作由 lifecycleMtx_ 串行化；worker 从不取这把锁，
        // 所以 join 期间不会与 worker 互等（join 也仍然不在 mtx_ 里做）。
        std::lock_guard<std::mutex> life(lifecycleMtx_);
        {
            std::lock_guard<std::mutex> lk(mtx_);
            if (state_.running) {
                return {false, "已有投放会话正在进行中，请先停止"};
            }
        }
        rta::net::join_thread_safely(workerThread_, threadMx_);   // 同 stop()：统一走安全收尾

        std::lock_guard<std::mutex> lk(mtx_);
        stopReq_.store(false);
        pauseReq_.store(false);
        seekReq_.store(-1.0);
        // 初始音量预置（防爆音：绝不以未知/满幅音量起播）。
        // 这里**无条件覆盖** volumeReqDb_：上一条会话没来得及消费的 dB 请求（可能来自上一位
        // 用户/上一台设备）不得带到新接收端；非有限值/越界由 sanitize_cast_volume_db 夹紧。
        const double initVol = sanitize_cast_volume_db(p.initialVolumeDb);
        volumeReqDb_.store(initVol);
        state_.running = true;
        state_.endedNaturally = false;
        state_.device = p.dev;
        state_.sourceFile = p.file;
        state_.servePort = p.port ? p.port : 8912;
        state_.phase = "discovering";
        state_.positionSec = 0.0;
        state_.transportState = "STOPPED";
        state_.servedBytes = 0;
        state_.requestCount = 0;
        state_.rateMatch = "unknown";
        state_.durationSec = 0.0;
        state_.sampleRate = 0;
        state_.bits = 0;
        state_.sourceRate = 0;
        state_.sourceBits = 0;
        state_.sourceChannels = 0;
        state_.resampled = false;
        state_.latencyKnown = false;
        state_.latencyMs = 0.0;
        state_.latencySource.clear();
        state_.currentVolumeDb = sanitize_cast_volume_db(p.initialVolumeDb);
        state_.paused = false;
        state_.warning.clear();
        state_.error.clear();
        state_.errorEn.clear();
        state_.volumeSupported = false;
        state_.currentVolume = -1;
        state_.lastVolumeError.clear();

        if (apTarget) {
            state_.volumeSupported = true;   // AirPlay 支持 SET_PARAMETER volume
            state_.currentVolume = -1;
            std::lock_guard<std::mutex> tlk(threadMx_);
            workerThread_ = std::thread([this, p]() { run_airplay_worker(p); });
            return {true, ""};
        }
        {
            std::lock_guard<std::mutex> tlk(threadMx_);
            workerThread_ = std::thread([this, p]() {
                run_worker(p);
            });
        }

        return {true, ""};
    }

    // 播放器控制映射（后端 = UPnP 时 /api/pause、/api/seek 转交给投放会话）：
    // HTTP 线程只写原子量，真正的 SOAP 动作在 worker 的轮询循环里做（不在请求线程里阻塞）。
    void set_paused(bool on) { pauseReq_.store(on); }
    void seek_seconds(double sec) { seekReq_.store(sec < 0.0 ? -1.0 : sec); }

    // RenderingControl 增补：以 dB 设定投放音量（原子请求，由 worker 轮询循环消费与下发 SOAP）
    // 合法范围约定：db <= 0.0，幅度法换算为 0..100。传入 1.0 用于清空。
    void set_volume_db(double db) { volumeReqDb_.store(db); }

    // 查询当前投放设备是否支持 RenderingControl
    bool volume_supported() {
        std::lock_guard<std::mutex> lk(mtx_);
        return state_.volumeSupported;
    }

    // 查询最近一次 SetVolume 错误信息（若成功则为空）
    std::string last_volume_error() {
        std::lock_guard<std::mutex> lk(mtx_);
        return state_.lastVolumeError;
    }

    // 查询当前音量（0..100，若未获取到或不支持则为 -1）
    int get_current_volume() {
        std::lock_guard<std::mutex> lk(mtx_);
        return state_.currentVolume;
    }

    bool stop() {
        // 与 start() 串行化：否则 start() 可能在本函数 join 期间检查到 running==false、
        // 清掉 stopReq_ 并复用同一个 workerThread_（用户连点「停止」+「投放」即可复现）。
        // lifecycleMtx_ 只被 start()/stop() 取，worker 从不取 ⟹ join 期间不会与 worker 互等。
        std::lock_guard<std::mutex> life(lifecycleMtx_);
        stopReq_.store(true);
        // 2026-10-28 真机事故：`/api/cast/stop` 反复打「DISPATCH 异常已拦截」，前端提示
        // 「停止投放失败」。根因是这里直接 workerThread_.join()：
        //   ① 在 worker 线程内部调用（自己 join 自己）——本机实测**不是抛异常而是死锁**；
        //   ② 用户连点「停止投放」/ 多请求并发 → 同一 std::thread 被 join 两次 → 抛
        //      std::system_error("Invalid argument") → 整个请求被打成 500。
        // 收尾逻辑统一走 join_thread_safely()（可离线单测，见 src/net/thread_join_safe.h
        // 与 tests/test_thread_join_safe.cpp），这里不再自己拼 join。
        rta::net::join_thread_safely(workerThread_, threadMx_);
        std::lock_guard<std::mutex> lk(mtx_);
        state_.running = false;
        state_.endedNaturally = false;
        state_.phase = "stopped";
        state_.transportState = "STOPPED";
        state_.paused = false;
        state_.volumeSupported = false;
        state_.currentVolume = -1;
        state_.lastVolumeError.clear();
        return true;
    }

private:
    // ---------------- 1.1.2 AirPlay(RAOP) 投放 worker ----------------
    // 与 UPnP 的"把文件供出去让渲染器来拉"完全不同：AirPlay 必须**主动推流**。
    // 链路：解码 → 44100/16/2 交错 → ALAC(352/包) → RTP/UDP；控制面是 RTSP。
    // 线程模型：本函数独占 worker 线程；HTTP 线程只写原子请求（stop/pause/volume/seek）。
    void run_airplay_worker(const CastStartParams& p) {
        auto fail = [this](const std::string& zh, const std::string& en = std::string()) {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.running = false;
            state_.endedNaturally = false;
            state_.phase = "error";
            state_.error = zh;
            state_.errorEn = en.empty() ? zh : en;
            // 失败后不能让界面停在「播放中/已暂停」，也不能残留「本会话支持音量」的假象
            // （start() 在 AirPlay 路径上会先把 volumeSupported 置 true）。
            state_.paused = false;
            state_.transportState = "STOPPED";
            state_.volumeSupported = false;
            state_.currentVolume = -1;
        };

        auto set_phase = [this](const char* ph) {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.phase = ph;
        };

        auto is_stopped = [this]() { return stopReq_.load(); };

        try {
            std::string host;
            uint16_t port = 5000;
            if (!parse_airplay_dev(p.dev, host, port)) {
                fail("AirPlay 设备标识非法：" + p.dev, "Invalid AirPlay device identifier: " + p.dev);
                return;
            }

            // 1. 发现能力与预检（密码 / 加密 / 编码）
            //
            // 三个判定必须分开，历史实现把它们搅在一起，导致两个真实的安全/兼容漏洞：
            //   · hasPublicKey（TXT 有 pk=）只说明「支持 RSA 配对」，**不是**加密要求；
            //   · 真正的要求是发现层算好的 needsEncryption（= et 明确不含明文类型 0），
            //     或调用方在 URL 里显式 enc=1/encrypt=1；
            //   · 旧代码把 hasPublicKey 赋成 true、explicitEncryptionRequired 写死 false ⟹
            //     「只支持加密」的接收端会被放行，随后明文 RTSP 直接失败（用户只看到连接失败）；
            //   · supportsAlac（cn 含 1）以前**从未检查**，只支持其它编码的接收端会收到 ALAC 包。
            AirPlayDevice devInfo;
            bool foundDev = false;
            {
                std::lock_guard<std::mutex> lk(apMutex_);
                for (const auto& d : apDevices_) {
                    if (d.host == host && d.port == port) {
                        devInfo = d;
                        foundDev = true;
                        break;
                    }
                }
            }
            const bool reqPassword = (foundDev && devInfo.password) ||
                                     airplay_dev_query_flag(p.dev, "pw") ||
                                     airplay_dev_query_flag(p.dev, "password");
            const bool reqEncryption = (foundDev && devInfo.needsEncryption) ||
                                       airplay_dev_query_flag(p.dev, "enc") ||
                                       airplay_dev_query_flag(p.dev, "encrypt");

            // 只发 ALAC（RAOP 96 / AppleLossless）。接收端明确声明 cn 不含 1 时直接拒绝，
            // 不浪费一次握手再让对端丢包。未发现（foundDev=false）时能力未知，按乐观放行。
            if (foundDev && !devInfo.supportsAlac) {
                fail("该接收端未声明支持 ALAC 编码（cn 能力列表不含 1）；本版本 AirPlay 投放只发送 ALAC",
                     "This receiver does not advertise ALAC (its cn list lacks 1); this build casts ALAC only");
                return;
            }

            RaopPreflightInput pfi;
            pfi.hasPublicKey = foundDev && devInfo.hasPublicKey;
            pfi.passwordRequired = reqPassword;
            pfi.explicitEncryptionRequired = reqEncryption;   // 决定是否拒绝的分支在这里
            auto pfr = preflight_raop(pfi);
            if (!pfr.ok) {
                fail(pfr.reason, pfr.reasonEn);
                return;
            }

            if (is_stopped()) {
                fail("投放已取消", "Cast cancelled");
                return;
            }

            // 2. 解码阶段
            // ⚠️ 取消粒度：read_any / convert_audio_for_cast 本身**不可中断**（没有传入取消令牌），
            // 所以这里只在进入前后检查 stopReq_；不宣称「解码可取消」，如实写清楚。
            set_phase("decoding");
            rta::audio::AudioBuffer src;
            try {
                src = rta::audio::read_any(p.file, nullptr);
            } catch (const std::exception& e) {
                fail(std::string("投放解码失败：") + e.what(), std::string("Cast decoding failed: ") + e.what());
                return;
            } catch (...) {
                fail("投放解码失败（未知异常）", "Cast decoding failed (unknown exception)");
                return;
            }

            if (is_stopped()) {
                fail("投放已取消", "Cast cancelled");
                return;
            }

            if (src.raw.empty() || src.channels <= 0 || src.rate == 0) {
                fail("投放解码结果为空：" + p.file, "Cast decoding result is empty: " + p.file);
                return;
            }

            // 3. 规范化音频转换（逐样本直通 / 诚实下混 / 延迟补偿与尾部排空重采样 / TPDF 抖动安全量化）
            rta::audio::CastAudioConversionResult conv;
            try {
                conv = rta::audio::convert_audio_for_cast(src);
            } catch (const std::exception& e) {
                fail(std::string("投放音频转换失败：") + e.what(), std::string("Cast audio conversion failed: ") + e.what());
                return;
            } catch (...) {
                fail("投放音频转换失败（未知异常）", "Cast audio conversion failed (unknown exception)");
                return;
            }

            if (conv.pcm.empty() || conv.frames == 0) {
                fail("投放音频转换结果为空", "Cast audio conversion output is empty");
                return;
            }

            const size_t outCh = 2;
            const size_t nFrames = conv.frames;
            const double totalSec = conv.durationSec;

            {
                std::lock_guard<std::mutex> lk(mtx_);
                state_.durationSec = totalSec;
                state_.sourceRate = src.rate;
                state_.sourceBits = src.bits;
                state_.sourceChannels = src.channels;
                state_.resampled = src.rate != 44100;
                state_.sampleRate = 44100;
                state_.bits = 16;
                state_.rateMatch = "match";
                state_.warning = conv.warningZh;
                if (!pfr.note.empty()) {
                    state_.warning = state_.warning.empty() ? pfr.note : (state_.warning + "；" + pfr.note);
                }
                const std::string ext = cast_lower_str(rta::audio::lowerExt(p.file));
                if (ext == ".dsf" || ext == ".dff") {
                    std::string w = "DSD 源已解码为 PCM 44100 Hz / 16 bit（AirPlay 不支持 DoP/DSD 直通）";
                    state_.warning = state_.warning.empty() ? w : (state_.warning + "；" + w);
                }
            }

            if (is_stopped()) {
                fail("投放已取消", "Cast cancelled");
                return;
            }

            // 4. 握手阶段
            set_phase("connecting");
            rta::net::RaopConfig cfg;
            cfg.host = host;
            cfg.port = port;
            cfg.sampleRate = 44100;
            cfg.channels = static_cast<int>(outCh);
            cfg.bits = 16;
            cfg.deviceId = p.dev;
            cfg.sessionName = "RLPlayer";
            // 预检通过就说明对端不要求 RSA 加密；这里如实传预检结论，不写死。
            cfg.needsEncryption = pfr.requiresEncryption;

            rta::net::RaopSession sess;
            std::string err;
            if (!sess.open(cfg, &err)) {
                fail("AirPlay 连接失败：" + err, "AirPlay connection failed: " + err);
                return;
            }

            if (is_stopped()) {
                // open() 内部是多条 RTSP，期间可能已被要求停止：先关会话再退，绝不开始推流。
                sess.close();
                fail("投放已取消", "Cast cancelled");
                return;
            }

            {
                // 诊断自证：把真实握手结果与端口落进 state，出问题时不靠猜。
                std::lock_guard<std::mutex> lk(mtx_);
                std::string hs = sess.last_handshake_summary();
                cast_append_warning(state_.warning, hs);
                if (sess.server_audio_port() || sess.local_rtp_port()) {
                    std::string p2 = "ports server=" + std::to_string(sess.server_audio_port()) +
                                     " local=" + std::to_string(sess.local_rtp_port());
                    cast_append_warning(state_.warning, p2);
                }
            }

            {
                std::lock_guard<std::mutex> lk(mtx_);
                state_.latencyKnown = true;
                state_.latencyMs = 1000.0 * sess.latency_frames() / cfg.sampleRate;
                state_.latencySource = "RAOP sender-configured buffer (not measured output latency)";
            }

            // 5. 初始音量安全下发（防爆音：绝不以未知/满幅音量起播）
            //
            // 这一步必须在**发出任何音频之前**完成且必须确认成功：SET_PARAMETER volume 失败时
            // 接收端音量完全未知（可能是它上次留下的 0 dB ⟹ 满幅爆音），历史上这里忽略了返回值
            // 直接开播并把 currentVolume 写成「已设置」。现在失败即中止整条会话。
            std::string initVolErr;
            {
                const double pendingVol = volumeReqDb_.exchange(1.0);
                const double initVol = (pendingVol <= 0.0)
                                           ? pendingVol
                                           : sanitize_cast_volume_db(p.initialVolumeDb);
                if (!sess.set_volume_db(initVol, &initVolErr)) {
                    const std::string why = initVolErr.empty() ? std::string("接收端未确认")
                                                               : initVolErr;
                    sess.close();
                    fail("AirPlay 初始音量设置失败（已在发出音频前中止，避免以未知音量起播）：" + why,
                         "Failed to set the initial AirPlay volume; aborted before sending any audio "
                         "to avoid playing at an unknown level: " + why);
                    return;
                }
                std::lock_guard<std::mutex> lk(mtx_);
                state_.currentVolume = airplay_db_to_percent(initVol);
                state_.currentVolumeDb = initVol;
                state_.lastVolumeError.clear();
            }

            set_phase("playing");
            {
                std::lock_guard<std::mutex> lk(mtx_);
                state_.transportState = "PLAYING";
                state_.paused = false;
            }

            // ── 时间轴辅助（全部按「接收端此刻真正在响的那一帧」计算）──────────────
            //
            // 时钟语义（协议层现行实现）：
            //   current_rtp_at(t) = 接收端**源时钟**位置（下一帧该被喂进去的位置），
            //   它**不含**接收端播放缓冲的延迟（latency_frames，默认 ≈2 s）。
            //   真正可听的帧 = current − latency；所以进度必须减掉 latency，否则界面会
            //   比实际声音超前整整一个缓冲（旧实现还把 EOF 判据也建在这个值上，提前切歌）。
            // 回绕：RTP 时间戳是 uint32，必须用**模 2^32 差值**（current − startRtp），
            //   绝不能写 `current >= startRtp` —— 播放超过 ~27 小时后该条件恒假，进度卡死。
            const size_t chunkFrames = 352 * 5; // 40 ms/批
            const uint32_t latencyFrames = sess.latency_frames();
            const uint32_t startRtp = sess.anchor_rtp();
            const uint64_t endFrames = static_cast<uint64_t>(nFrames);
            uint64_t displayedFrames = 0;   // 单调不减：暂停/恢复重锚只允许短暂回退，界面不回跳

            auto audible_elapsed = [startRtp, latencyFrames](uint32_t current) -> uint64_t {
                return cast_audible_frames(current, startRtp, latencyFrames);
            };
            auto publish_position = [&](uint32_t current) {
                const uint64_t aud = std::min<uint64_t>(audible_elapsed(current), endFrames);
                if (aud > displayedFrames) displayedFrames = aud;
                const double pos = std::min(totalSec, static_cast<double>(displayedFrames) / 44100.0);
                std::lock_guard<std::mutex> lk(mtx_);
                state_.positionSec = pos;
            };

            // 暂停状态同步（含失败如实记录）。返回 true 表示当前处于暂停。
            auto apply_pause_state = [&](bool& pausedNow, std::chrono::steady_clock::time_point& pauseStart,
                                         std::chrono::nanoseconds& pausedTotal) {
                const bool want = pauseReq_.load();
                if (want == pausedNow) return;
                pausedNow = want;
                std::string perr;
                const bool pok = sess.set_paused(pausedNow, &perr);
                if (pausedNow) {
                    pauseStart = std::chrono::steady_clock::now();
                } else {
                    pausedTotal += std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now() - pauseStart);
                }
                std::lock_guard<std::mutex> lk(mtx_);
                if (!pok) {
                    const std::string why = perr.empty() ? std::string("协议层未返回原因") : perr;
                    cast_append_warning(state_.warning,
                                        (pausedNow ? "暂停请求未被接受：" : "恢复请求未被接受：") + why);
                }
                state_.paused = pausedNow;
                state_.transportState = pausedNow ? "PAUSED" : "PLAYING";
            };

            // 运行期音量：只有接收端确认成功才更新百分比；失败保留上一次已确认的值 + 原因。
            auto apply_pending_volume = [&]() {
                const double vreq = volumeReqDb_.exchange(1.0);
                if (!(vreq <= 0.0)) return;   // 1.0 = 「无待发请求」标记；NaN 也按无请求处理
                std::string verr;
                const bool vok = sess.set_volume_db(vreq, &verr);
                std::lock_guard<std::mutex> lk(mtx_);
                if (vok) {
                    state_.currentVolume = airplay_db_to_percent(vreq);
                    state_.currentVolumeDb = vreq;
                    state_.lastVolumeError.clear();
                } else {
                    state_.lastVolumeError = verr.empty()
                                                 ? std::string("接收端未确认 SET_PARAMETER volume")
                                                 : verr;
                }
            };

            // 6. 推流循环
            const auto t0 = std::chrono::steady_clock::now();
            size_t sent = 0;
            bool hadError = false;
            bool pausedNow = false;
            auto pauseStart = std::chrono::steady_clock::now();
            std::chrono::nanoseconds totalPausedDuration{0};

            while (sent < nFrames) {
                if (is_stopped()) break;
                if (!sess.check_connection(&err)) {
                    fail("AirPlay 控制连接已断开：" + err, "AirPlay control connection closed: " + err);
                    hadError = true;
                    break;
                }

                // 暂停控制（通过 RaopSession::set_paused 冻结时间轴 + FLUSH 静音；
                // 恢复时协议层把「已发未播」窗口按原 seq/rtptime 补发，worker 不回退读位置）
                apply_pause_state(pausedNow, pauseStart, totalPausedDuration);

                if (pausedNow) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(25));
                    continue;
                }

                // 音量更新消费（原子 exchange，防止并发请求被覆盖丢失）
                apply_pending_volume();

                // seek
                if (seekReq_.exchange(-1.0) >= 0.0) {
                    std::lock_guard<std::mutex> lk(mtx_);
                    cast_append_warning(state_.warning, "AirPlay 投放暂不支持拖动进度（会继续当前进度）");
                }

                const size_t n = std::min(chunkFrames, nFrames - sent);
                if (!sess.write_pcm(conv.pcm.data() + sent * outCh, n, &err)) {
                    fail("AirPlay 推流失败：" + err, "AirPlay streaming failed: " + err);
                    hadError = true;
                    break;
                }
                sent += n;

                // 真实进度同步：接收端源时钟 − 播放缓冲延迟 = 此刻真正在响的位置。
                const auto now = std::chrono::steady_clock::now();
                publish_position(sess.current_rtp_at(now));

                // 平滑节流（排除暂停耗时，消除 catch-up bursts）
                const double sentSec = static_cast<double>(sent) / 44100.0;
                const double activePlaybackSec = std::chrono::duration<double>(now - t0 - totalPausedDuration).count();
                const double prebuffer = sess.prebuffer_seconds();
                if (sentSec > activePlaybackSec + prebuffer) {
                    const double waitSec = (sentSec - activePlaybackSec - prebuffer);
                    if (waitSec >= 0.001) {
                        std::this_thread::sleep_for(std::chrono::microseconds(
                            static_cast<long long>(waitSec * 1000000.0)));
                    }
                }
            }

            // 7. EOF 处理：补齐部分包，然后等**接收端真的把最后一个样本播完**
            //
            // 旧实现有三处会让「自然结束」提前/失真：
            //   a) finish() 的返回值没检查 ⟹ 尾部补齐失败也报自然结束（假成功）；
            //   b) 结束判据用 current >= start+nFrames（源时钟）⟹ 比可听位置早一个 latency
            //      （默认 2 s），最后一段被切掉；
            //   c) drain 用**绝对 deadline**：暂停期间时间照样流逝，一首歌可以在「暂停中结束」。
            // 现在：判据基于可听位置（audible_elapsed ≥ 总帧数），预算只累计**非暂停**时间。
            bool finishOk = false;
            bool reachedEnd = false;
            if (!hadError && !is_stopped() && sent >= nFrames) {
                std::string finErr;
                if (sess.finish(&finErr)) {
                    finishOk = true;
                } else {
                    hadError = true;
                    fail("AirPlay 收尾失败（尾部补齐未获接收端确认）：" + finErr,
                         "AirPlay end-of-stream failed (tail padding not acknowledged): " + finErr);
                }
            }

            if (!hadError && finishOk && !is_stopped()) {
                // 预算 = 一个完整播放缓冲 + prebuffer + 0.5 s 余量（够对端把缓冲播完），
                // 只在**未暂停**时消耗：暂停多久都不算超时。
                const double latencySec = static_cast<double>(latencyFrames) / 44100.0 + sess.prebuffer_seconds();
                const auto drainBudget = std::chrono::milliseconds(
                    static_cast<long long>((latencySec + 0.5) * 1000.0));
                std::chrono::milliseconds drainUsed{0};
                auto drainLast = std::chrono::steady_clock::now();

                while (!is_stopped()) {
                    if (!sess.check_connection(&err)) {
                        fail("AirPlay 控制连接已断开：" + err, "AirPlay control connection closed: " + err);
                        hadError = true;
                        break;
                    }
                    apply_pause_state(pausedNow, pauseStart, totalPausedDuration);
                    const auto now = std::chrono::steady_clock::now();
                    if (pausedNow) {
                        // 暂停不消耗预算，也不推进位置（冻结值已经减过 latency，不会回跳）
                        drainLast = now;
                        publish_position(sess.current_rtp_at(now));
                        std::this_thread::sleep_for(std::chrono::milliseconds(25));
                        continue;
                    }
                    drainUsed += std::chrono::duration_cast<std::chrono::milliseconds>(now - drainLast);
                    drainLast = now;
                    if (drainUsed > drainBudget) break;   // 超预算：停止等待，但下方不谎报自然结束

                    apply_pending_volume();
                    const uint32_t currentPlayingRtp = sess.current_rtp_at(now);
                    publish_position(currentPlayingRtp);
                    if (audible_elapsed(currentPlayingRtp) >= endFrames) {
                        reachedEnd = true;
                        break;
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(15));
                }
            }

            // 收尾诊断：只有出问题时才把协议层计数器塞进 warning（正常时保持用户可读）。
            if (hadError || (!finishOk && sent >= nFrames && !is_stopped())) {
                const std::string hs = sess.health_summary();
                std::lock_guard<std::mutex> lk(mtx_);
                cast_append_warning(state_.warning, hs);
            }

            sess.close();
            {
                std::lock_guard<std::mutex> lk(mtx_);
                if (!hadError && state_.error.empty()) {
                    // 自然结束 = 全部源帧已送出 + 尾部补齐确认 + 用户没中途停止。
                    // 与「drain 是否等到可听终点」解耦：等不到只影响 position 的推送精度，
                    // 但 finish 失败或用户 stop 一律不算自然结束（绝不假报）。
                    const bool natural = cast_natural_end(finishOk, sent >= nFrames, is_stopped());
                    state_.running = false;
                    state_.phase = "stopped";
                    state_.transportState = "STOPPED";
                    state_.paused = false;
                    state_.endedNaturally = natural;
                    if (natural) {
                        state_.positionSec = totalSec;
                        displayedFrames = endFrames;
                    } else if (reachedEnd) {
                        state_.positionSec = std::min(totalSec, static_cast<double>(displayedFrames) / 44100.0);
                    }
                }
                state_.volumeSupported = false;
                state_.currentVolume = -1;
            }
        } catch (const std::exception& e) {
            fail(std::string("AirPlay worker 异常：") + e.what(),
                 std::string("AirPlay worker exception: ") + e.what());
        } catch (...) {
            fail("AirPlay worker 出现未知异常", "AirPlay worker encountered unknown exception");
        }
    }

    void run_worker(const CastStartParams& p) {
        std::string tempWavPath;
        bool needCleanupTemp = false;
        std::string wavToServe = p.file;
        AudioSourceFormat srcFormat;
        double durationSec = 0.0;   // 供播放器进度条用（源文件时长，秒）

        // err：中文（行为真相，历史文案逐字保留）；errEn：同一事实的英文版（可空）。
        // 英文参数必须与中文同时给出，避免出现「界面切英文但错误还是中文」的半截状态。
        auto fail = [this, &tempWavPath, &needCleanupTemp](const std::string& err,
                                                          const std::string& errEn = std::string()) {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.running = false;
            state_.endedNaturally = false;
            state_.phase = "error";
            state_.error = err;
            state_.errorEn = errEn;
            if (needCleanupTemp && !tempWavPath.empty()) {
                std::remove(tempWavPath.c_str());
            }
        };

        // 1) 发现渲染器
        {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.phase = "discovering";
        }

        UpnpDevice targetDev;
        bool foundDev = false;

        if (!p.dev.empty() && (p.dev.rfind("http://", 0) == 0 || p.dev.rfind("https://", 0) == 0)) {
            targetDev.location = p.dev;
            const size_t sp = p.dev.find("//");
            if (sp != std::string::npos) {
                const size_t slash = p.dev.find('/', sp + 2);
                std::string hostport = p.dev.substr(sp + 2, (slash == std::string::npos ? p.dev.size() : slash) - (sp + 2));
                const std::string path = (slash == std::string::npos) ? "/" : p.dev.substr(slash);
                const size_t colon = hostport.find(':');
                targetDev.host = (colon == std::string::npos) ? hostport : hostport.substr(0, colon);
                targetDev.port = (colon == std::string::npos) ? 80 : std::atoi(hostport.substr(colon + 1).c_str());

                std::string xml;
                if (upnp_detail::http_get(targetDev.host, targetDev.port, path, xml, targetDev.ifindex)) {
                    targetDev.name = upnp_detail::xml_tag(xml, "friendlyName");
                    targetDev.model = upnp_detail::xml_tag(xml, "modelName");
                    targetDev.udn = upnp_detail::xml_tag(xml, "UDN");
                    targetDev.control = upnp_detail::extract_service_control_url(xml, "AVTransport");
                    if (targetDev.control.empty()) targetDev.control = upnp_detail::xml_tag(xml, "controlURL");
                    targetDev.controlConnection = upnp_detail::extract_service_control_url(xml, "ConnectionManager");
                    targetDev.controlRendering  = upnp_detail::extract_service_control_url(xml, "RenderingControl");
                    foundDev = true;
                }
            }
            if (!foundDev) {
                fail(cast_err::dev_desc_url_failed(p.dev), cast_err::dev_desc_url_failed_en(p.dev));
                return;
            }
        } else {
            auto devs = upnp_discover(2000);
            if (devs.empty()) {
                fail(cast_err::no_renderer_found(), cast_err::no_renderer_found_en());
                return;
            }
            if (!p.dev.empty()) {
                std::string query = cast_lower_str(p.dev);
                for (const auto& d : devs) {
                    if (cast_lower_str(d.name).find(query) != std::string::npos ||
                        cast_lower_str(d.model).find(query) != std::string::npos ||
                        d.host.find(query) != std::string::npos) {
                        targetDev = d;
                        foundDev = true;
                        break;
                    }
                }
                if (!foundDev) {
                    // 历史实现是行内拼接（`"…包含 "" + p.dev + "" 的…"`），能编但极易被误改成
                    // 真的输出一对空引号；改成纯函数后 tests/test_cast_service.cpp 可以断言
                    // 「查询串出现在引号里」且「没有残留 "" 字样」。
                    fail(cast_err::dev_not_found(p.dev), cast_err::dev_not_found_en(p.dev));
                    return;
                }
            } else {
                targetDev = devs[0];
                foundDev = true;
            }
        }

        if (stopReq_.load()) {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.running = false;
            state_.endedNaturally = false;
            state_.phase = "stopped";
            return;
        }

        {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.device = targetDev.name.empty() ? targetDev.host : targetDev.name;
            state_.phase = "serving";
        }

        // 2) 准备供源音频
        std::string ext = cast_lower_str(rta::audio::lowerExt(p.file));
        bool isDsd = (ext == ".dsf" || ext == ".dff");
        if (isDsd) {
            try {
                rta::audio::DsdStream dsd = rta::audio::read_dsd(p.file);
                if (dsd.rate == 0 || dsd.channels == 0 || dsd.data.empty()) {
                    fail(cast_err::dsd_read_invalid(p.file), cast_err::dsd_read_invalid_en(p.file));
                    return;
                }
                const uint32_t carrierRate = dsd.rate / 16u;
                const size_t carrierFrames = (size_t)(dsd.bits / 16u);

                rta::audio::AudioBuffer dopBuf;
                dopBuf.rate = carrierRate;
                dopBuf.channels = dsd.channels;
                dopBuf.bits = 24;
                dopBuf.isFloat = false;
                dopBuf.raw.resize(carrierFrames * (size_t)dsd.channels);

                for (int c = 0; c < dsd.channels; ++c) {
                    bool phaseA = true;
                    for (size_t n = 0; n < carrierFrames; ++n) {
                        uint8_t b0 = dsd.data[(size_t)c][n * 2 + 0];
                        uint8_t b1 = dsd.data[(size_t)c][n * 2 + 1];
                        uint32_t bits16 = ((uint32_t)b0 << 8) | (uint32_t)b1;
                        uint32_t marker = (phaseA ? rta::dsp::DOP_MARKER_A : rta::dsp::DOP_MARKER_B) << 16;
                        int32_t v = (int32_t)(marker | bits16);
                        if (v & 0x800000) v |= (int32_t)0xFF000000;
                        dopBuf.raw[n * (size_t)dsd.channels + (size_t)c] = v;
                        phaseA = !phaseA;
                    }
                }

                tempWavPath = make_cast_temp_wav_path("dop");
                rta::audio::write_wav(tempWavPath, dopBuf);
                wavToServe = tempWavPath;
                needCleanupTemp = true;

                srcFormat.sampleRate = carrierRate;
                srcFormat.bits = 24;
                srcFormat.channels = dsd.channels;
                srcFormat.isDsd = true;
                srcFormat.encoding = "DSD over PCM (DoP v1.1)";
                durationSec = (double)dsd.bits / (double)dsd.rate;
            } catch (const std::exception& e) {
                fail(cast_err::dsd_pack_failed(e.what()), cast_err::dsd_pack_failed_en(e.what()));
                return;
            }
        } else {
            if (ext == ".wav" && p.rate == 0 && p.bits == 0) {
                try {
                    rta::audio::AudioBuffer ab = rta::audio::read_wav(p.file);
                    srcFormat.sampleRate = ab.rate;
                    srcFormat.bits = ab.bits;
                    srcFormat.channels = ab.channels;
                    srcFormat.isDsd = false;
                    srcFormat.encoding = ab.isFloat ? "IEEE Float PCM" : "Linear PCM";
                    durationSec = ab.rate ? (double)ab.frames() / (double)ab.rate : 0.0;
                    wavToServe = p.file;
                } catch (const std::exception& e) {
                    fail(cast_err::wav_read_failed(e.what()), cast_err::wav_read_failed_en(e.what()));
                    return;
                }
            } else {
                try {
                    rta::audio::LoadNote note;
                    rta::audio::AudioBuffer ab = rta::audio::read_any(p.file, &note);

                    if (p.rate > 0 && p.rate != ab.rate) {
                        rta::dsp::ResamplerConfig rcfg;
                        rcfg.inRate = ab.rate;
                        rcfg.outRate = p.rate;
                        rcfg.channels = ab.channels;
                        rta::dsp::PolyphaseResampler resampler(rcfg);
                        const size_t inFrames = ab.frames();
                        const size_t maxOut = resampler.maxOutFrames(inFrames);
                        std::vector<std::vector<double>> inCh(ab.channels, std::vector<double>(inFrames));
                        std::vector<const double*> inPtrs(ab.channels);
                        for (int c = 0; c < ab.channels; ++c) {
                            for (size_t n = 0; n < inFrames; ++n) inCh[c][n] = ab.sample(n, c);
                            inPtrs[c] = inCh[c].data();
                        }
                        std::vector<std::vector<double>> outCh(ab.channels, std::vector<double>(maxOut));
                        std::vector<double*> outPtrs(ab.channels);
                        for (int c = 0; c < ab.channels; ++c) outPtrs[c] = outCh[c].data();

                        const size_t outFrames = resampler.process(inPtrs.data(), inFrames, outPtrs.data());
                        rta::audio::AudioBuffer resBuf;
                        resBuf.rate = p.rate;
                        resBuf.channels = ab.channels;
                        resBuf.bits = (p.bits > 0) ? p.bits : ab.bits;
                        resBuf.isFloat = false;
                        resBuf.raw.resize(outFrames * (size_t)ab.channels);
                        for (size_t n = 0; n < outFrames; ++n) {
                            for (int c = 0; c < ab.channels; ++c) {
                                resBuf.setSample(n, c, outCh[c][n]);
                            }
                        }
                        ab = std::move(resBuf);
                    } else if (p.bits > 0 && p.bits != ab.bits) {
                        ab.bits = p.bits;
                    }

                    tempWavPath = make_cast_temp_wav_path("pcm");
                    rta::audio::write_wav(tempWavPath, ab);
                    wavToServe = tempWavPath;
                    needCleanupTemp = true;

                    srcFormat.sampleRate = ab.rate;
                    srcFormat.bits = ab.bits;
                    srcFormat.channels = ab.channels;
                    srcFormat.isDsd = false;
                    srcFormat.encoding = "Linear PCM";
                    durationSec = ab.rate ? (double)ab.frames() / (double)ab.rate : 0.0;
                } catch (const std::exception& e) {
                    fail(cast_err::temp_wav_write_failed(e.what()),
                         cast_err::temp_wav_write_failed_en(e.what()));
                    return;
                }
            }
        }

        {
            // 供源格式与时长：播放器底栏（/api/status）在 UPnP 后端下直接取这份数据
            std::lock_guard<std::mutex> lk(mtx_);
            state_.sampleRate = srcFormat.sampleRate;
            state_.bits = srcFormat.bits;
            // Original source metadata is only known here for unconverted PCM.
            if (!srcFormat.isDsd && p.rate == 0 && p.bits == 0) {
                state_.sourceRate = srcFormat.sampleRate;
                state_.sourceBits = srcFormat.bits;
                state_.sourceChannels = srcFormat.channels;
            }
            state_.durationSec = durationSec > 0.0 ? durationSec : 0.0;
        }

        if (stopReq_.load()) {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.running = false;
            state_.endedNaturally = false;
            state_.phase = "stopped";
            state_.paused = false;
            if (needCleanupTemp && !tempWavPath.empty()) std::remove(tempWavPath.c_str());
            return;
        }

        // 3) 启动本地 HTTP 供源服务
        // 2026-10-24（261024-02 #5 实测）：8912 可能被别的程序占用（本机 Clash/verge-mihomo 就长期监听
        // 0.0.0.0:8912）⟹ 投放直接失败。改为在 8912..8921 里挑第一个能绑上的端口，
        // 实际端口写回 state_.servePort（UI 与取流 URL 都以 state 为准，不假设 8912）。
        const uint16_t wantPort = p.port ? p.port : 8912;
        UpnpHttpServer server;
        uint16_t servePort = wantPort;
        bool bound = false;
        for (uint16_t i = 0; i < 10; ++i) {
            servePort = (uint16_t)(wantPort + i);
            if (server.start(servePort, "0.0.0.0")) { bound = true; break; }
            if (stopReq_.load()) break;
        }
        if (!bound) {
            // 端口段上界按 uint32_t 传：wantPort 是 uint16_t，+9 若按 uint16_t 计算会回绕
            fail(cast_err::http_server_bind_failed((uint32_t)wantPort, (uint32_t)wantPort + 9u),
                 cast_err::http_server_bind_failed_en((uint32_t)wantPort, (uint32_t)wantPort + 9u));
            return;
        }
        {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.servePort = servePort;
        }

        std::string localIp = upnp_local_ip_for(targetDev.host, (uint16_t)targetDev.port);
        std::string streamPath = server.register_file(wavToServe, "audio/wav");
        std::string streamUrl = "http://" + localIp + ":" + std::to_string(server.port()) + streamPath;

        // 4) UPnP 控制动作 SetAVTransportURI & Play
        UpnpControlClient client(targetDev.av_transport_url(),
                                targetDev.connection_manager_url(),
                                targetDev.rendering_control_url(),
                                targetDev.ifname);

        UpnpDidlItem didl;
        didl.title = p.file;
        size_t lastSlash = didl.title.find_last_of("\\/");
        if (lastSlash != std::string::npos) didl.title = didl.title.substr(lastSlash + 1);
        didl.creator = "RLPlayer Cast";
        didl.uri = streamUrl;
        didl.sampleRate = srcFormat.sampleRate;
        didl.bits = srcFormat.bits;
        didl.channels = srcFormat.channels;
        std::string didlXml = build_didl_lite(didl);

        UpnpActionResult setRes = client.set_av_transport_uri(streamUrl, didlXml);
        if (!setRes.ok) {
            server.stop();
            fail(cast_err::action_failed("SetAVTransportURI", setRes.error),
                 cast_err::action_failed_en("SetAVTransportURI", setRes.error));
            return;
        }

        UpnpActionResult playRes = client.play("1");
        if (!playRes.ok) {
            client.stop();
            server.stop();
            fail(cast_err::action_failed("Play", playRes.error),
                 cast_err::action_failed_en("Play", playRes.error));
            return;
        }

        // 5) 轮询与状态更新
        const bool rcSupported = client.rendering_control_supported();
        {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.phase = "playing";
            state_.transportState = "PLAYING";
            state_.volumeSupported = rcSupported;
            state_.currentVolume = -1;
            state_.lastVolumeError.clear();
        }

        // 首次尝试读取一次当前音量
        if (rcSupported) {
            auto vInfo = client.get_volume();
            if (vInfo.ok) {
                std::lock_guard<std::mutex> lk(mtx_);
                state_.currentVolume = vInfo.volume;
            }
        }

        UpnpProtocolInfo proto = client.get_protocol_info();
        auto startTime = std::chrono::steady_clock::now();
        bool pausedApplied = false;
        bool sawActive = false;
        bool naturalEnd = false;

        while (!stopReq_.load()) {
            auto now = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - startTime).count();
            if (p.seconds > 0.0 && elapsed >= p.seconds) {
                naturalEnd = !stopReq_.load();
                break;
            }

            // 261024-01 #9：暂停 / 跳转请求（来自播放器底栏）。HTTP 线程只写原子量，
            // SOAP 动作在这里做 —— 请求线程不会因为渲染器慢响应而卡住整个 Web UI。
            const bool wantPause = pauseReq_.load();
            if (wantPause != pausedApplied) {
                const UpnpActionResult pr = wantPause ? client.pause() : client.play("1");
                if (pr.ok) {
                    pausedApplied = wantPause;
                    std::lock_guard<std::mutex> lk(mtx_);
                    state_.paused = wantPause;
                }
            }
            {
                const double seekSec = seekReq_.exchange(-1.0);
                if (seekSec >= 0.0) {
                    char hms[32]{};
                    const int total = (int)(seekSec + 0.5);
                    std::snprintf(hms, sizeof(hms), "%02d:%02d:%02d",
                                  total / 3600, (total % 3600) / 60, total % 60);
                    const UpnpActionResult sr = client.seek_rel_time(hms);
                    if (sr.ok) {
                        std::lock_guard<std::mutex> lk(mtx_);
                        state_.positionSec = seekSec;
                    }
                }
            }
            {
                // 音量设置请求消费（HTTP 线程写入 volumeReqDb_，这里原子取出）
                const double vDb = volumeReqDb_.exchange(1.0);
                if (vDb <= 0.0) {
                    if (rcSupported) {
                        const int desiredVol = db_to_upnp_volume(vDb);
                        const UpnpActionResult vr = client.set_volume(desiredVol);
                        std::lock_guard<std::mutex> lk(mtx_);
                        if (vr.ok) {
                            state_.currentVolume = desiredVol;
                            state_.lastVolumeError.clear();
                        } else {
                            state_.lastVolumeError = vr.error.str();
                        }
                    } else {
                        std::lock_guard<std::mutex> lk(mtx_);
                        state_.lastVolumeError = "设备不支持 RenderingControl，已忽略 SetVolume";
                    }
                }
            }

            // 2026-10-30（真机：投放中切歌整机静默 10s/18s 的根因）：
            // 这三个是**轮询**查询，原来各用 8000ms 超时，而停止投放是同步 join 工作线程
            // ⟹ 切歌最坏要等 3×8s=24s，前端 await 这个请求就等于界面卡死。
            // 现在：①每个查询前先看 stopReq_，已请求停止就一个都不打；
            //       ②轮询超时降到 kPollTimeoutMs（控制类动作 SetAVTransportURI/Play/Stop 仍 8s）。
            static constexpr int kPollTimeoutMs = 1500;
            bool cancelled = false;
            UpnpTransportInfo transport;
            UpnpPositionInfo pos;
            UpnpMediaInfo media;
            if (stopReq_.load()) { cancelled = true; }
            if (!cancelled) { media = client.get_media_info(0, kPollTimeoutMs);  if (stopReq_.load()) cancelled = true; }
            if (!cancelled) { pos = client.get_position_info(0, kPollTimeoutMs); if (stopReq_.load()) cancelled = true; }
            if (!cancelled) { transport = client.get_transport_info(0, kPollTimeoutMs); }
            if (cancelled) break;   // 已请求停止：立刻退出循环去收尾，别再拖累 join

            SamplingRateAnalysis analysis = analyze_sampling_rate(srcFormat, media, pos, proto);

            {
                std::lock_guard<std::mutex> lk(mtx_);
                state_.transportState = !transport.state.empty() ? transport.state : "PLAYING";
                state_.positionSec = parse_time_hh_mm_ss(pos.relTime);
                state_.servedBytes = server.total_bytes_served();
                state_.requestCount = (int)server.total_requests_served();

                if ((transport.ok && transport.state == "PLAYING") ||
                    state_.servedBytes > 0 ||
                    state_.positionSec > 0.0) {
                    sawActive = true;
                }

                if (analysis.verdict == SamplingRateVerdict::Match) {
                    state_.rateMatch = "match";
                } else if (analysis.verdict == SamplingRateVerdict::Mismatch) {
                    state_.rateMatch = "mismatch";
                } else {
                    state_.rateMatch = "unknown";
                }
                state_.warning = analysis.warning;
                // 2026-10-24（261023-01 #9 实测）：设备回 PLAYING 但 8 秒内一次都没来取流，
                // 最常见原因是 Windows 防火墙挡住入站 8912/TCP（本机被 sandbox 的 Block 规则挡住时，
                // 现象就是 servedBytes=0 / requestCount=0）。给用户可执行的提示，而不是静默"在播"。
                if (elapsed > 8.0 && state_.requestCount == 0 && state_.warning.empty()) {
                    state_.warning = "渲染器没有来取流：请检查 Windows 防火墙是否允许 rtaweb.exe 入站 TCP " +
                                     std::to_string(server.port()) + "，或设备是否支持该格式";
                }
            }

            if (transport.ok && (transport.state == "STOPPED" || transport.state == "NO_MEDIA_PRESENT") &&
                !wantPause && !pausedApplied) {
                const double minElapsed = (durationSec > 0.0 && durationSec < 2.0)
                                          ? std::max(0.25, durationSec * 0.8)
                                          : 2.0;
                if (sawActive && elapsed >= minElapsed) {
                    naturalEnd = true;
                    break;
                }
                if (!sawActive && elapsed > 2.0) {
                    naturalEnd = false;
                    break;
                }
            }

            for (int i = 0; i < 5; ++i) {
                if (stopReq_.load()) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }

        // 6) 结束收尾
        client.stop();
        server.stop();
        if (needCleanupTemp && !tempWavPath.empty()) {
            std::remove(tempWavPath.c_str());
        }

        {
            std::lock_guard<std::mutex> lk(mtx_);
            state_.running = false;
            state_.endedNaturally = naturalEnd && !stopReq_.load();
            state_.phase = "stopped";
            state_.transportState = "STOPPED";
            state_.paused = false;
        }
    }

    std::mutex              mtx_;
    CastState               state_;
    std::atomic<bool>       stopReq_{false};
    std::atomic<bool>       pauseReq_{false};
    std::atomic<double>     seekReq_{-1.0};
    std::atomic<double>     volumeReqDb_{1.0}; // <=0.0 为有效音量请求，1.0 为无请求
    std::thread             workerThread_;
    std::mutex              threadMx_;    // 保护 workerThread_ 的取出/join（见 stop() 注释）
    // 串行化 start()/stop() 的整段动作（判状态 → join 旧 worker → 重置状态 → 起新线程）。
    // 只被这两个公开动作取；worker 线程**从不**取它 ⟹ join 期间不会与 worker 互等，
    // 也不与 mtx_ 形成 ABBA（本锁一律先于 mtx_ 获取，且只在 join 之后才取 mtx_）。
    std::mutex              lifecycleMtx_;

    std::mutex              devMutex_;
    // AirPlay 发现缓存（独立于 UPnP，便于分别看诊断）
    std::mutex              apMutex_;
    std::vector<rta::net::AirPlayDevice> apDevices_;
    std::chrono::steady_clock::time_point apScanTime_{};
    std::string             apDiag_;
    std::vector<UpnpDevice> cachedDevices_;
    std::chrono::steady_clock::time_point lastScanTime_;
    UpnpDiscoverDiag lastDiag_;
};

} // namespace rta::net
