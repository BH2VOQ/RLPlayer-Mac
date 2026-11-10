// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// update_channel.h — F-4 自动更新「更新通道（中国大陆 / 全球）」纯逻辑层
//                    （无 IO、无 ObjC、零项目依赖、可离线单测）
//
// ============================ 这一层为什么单独存在 ============================
// 1.1.5.1 新增「更新通道」选项。本轮**只做框架**（后台 dmg 尚未适配，用户明确要求
// 先做框架、等后台适配好再正式接入）：
//    · 全球(Global)           = 现有 GitHub 路径（latest.json + release dmg），行为一字不变；
//    · 中国大陆(ChinaMainland) = rlplayer.rainlain.com 后台（签名清单 + files[] 对象）。
// 本层**不发起任何网络请求**、不验签、不解包、不重组整包、不碰断点续传。
// 把「通道选择 / 解析 / 清单来源 / 清单形状」抽成纯函数，是为了：
//    ① 缺省即安全可被单测证明（非法值绝不静默选到未知通道）；
//    ② 等后台就绪后只需在 tools/mac_update.mm 的 check_china_channel() 里填实，
//       配置与 UI 契约都不用再动；
//    ③ 「验签必须在解包 / 安装之前」这条顺序约束用类型(ChannelManifest)钉住，
//       不靠口头约定（同 tools/mac_update.h 里「verify 必须在 mount 之前」的做法）。
//
// ============================ 安全边界 ============================
//   * 本层不含任何 token / URL 凭据 / 公钥 DER；常量只有两个公开主机名与清单路径。
//   * 页面只发「用户选了哪个通道」的抽象枚举命令（update:channel:global|cn），
//     绝不把 URL / token 下发给宿主（见 tools/mac_host.mm:788 的硬边界注释）。
//   * 中国大陆通道在框架阶段**永远不可判定为「已是最新」**：后台未就绪时返回
//     FailedNetwork 等价的诚实失败态，绝不冒充成功、绝不引导百度网盘。
#pragma once

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

#include "net/json.h"   // 后台签名清单（JWS 信封 + payload）解析

namespace rta::update {

// ---------------------------------------------------------------------------
// 0. 通道枚举与默认值（唯一真相源）
// ---------------------------------------------------------------------------
enum class UpdateChannel {
    Global,         // 全球：现有 GitHub 路径（清单 + release dmg），行为一字不变
    ChinaMainland   // 中国大陆：rlplayer.rainlain.com 后台（本轮只做框架）
};

// ⚠️ 框架阶段默认**仍为全球**：后台 dmg 未适配，默认切大陆会立刻不可用，
//    也会改变现有用户升级后的行为。后台适配完成后，把这一行改成
//    `kDefaultChannel = UpdateChannel::ChinaMainland` 即可（用户 2026-11-09 定的
//    最终产品语义：中国大陆默认走后台）。默认值只在这里定义一次，
//    parse_channel / Config / 模板 / UI 全部从它派生，别在别处再写一遍。
inline constexpr UpdateChannel kDefaultChannel = UpdateChannel::Global;

// ---------------------------------------------------------------------------
// 1. 后台通道常量（本轮只用于「解析出来源」，不发起请求）
// ---------------------------------------------------------------------------
inline constexpr const char kChinaHost[] = "rlplayer.rainlain.com";

inline constexpr const char kChinaManifestUrl[] =
    "https://rlplayer.rainlain.com/api/v1/update/macos/latest";

// 配置键取值。global / cn 为主，china 作为容错别名（大小写不敏感）。
inline constexpr const char kChannelValueGlobal[] = "global";
inline constexpr const char kChannelValueCn[] = "cn";
inline constexpr const char kChannelValueChina[] = "china";

// ---------------------------------------------------------------------------
// 2. 通道解析 —— 缺省即安全
//
// 语义：
//   * 空 / 纯空白        → 「未配置」，回退 kDefaultChannel，valid=true，无 warning
//                          （首次运行没有 channel= 是常态，不报错）
//   * global/cn/china    → 对应通道（大小写不敏感），valid=true
//   * 其它非空值         → 回退 kDefaultChannel，valid=false，warning 说明原因
//                          （绝不静默选一个未知通道；warning 不含任何凭据）
// ---------------------------------------------------------------------------
struct ChannelParseResult {
    UpdateChannel channel = kDefaultChannel;
    bool valid = true;          // false = 输入非法且已安全回退
    std::string warning;        // 非法时的提示（不含任何凭据）
};

namespace detail_channel {
inline std::string ch_trim(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && std::isspace((unsigned char)s[b])) ++b;
    while (e > b && std::isspace((unsigned char)s[e - 1])) --e;
    return s.substr(b, e - b);
}
inline std::string ch_lower(const std::string& s) {
    std::string o = s;
    std::transform(o.begin(), o.end(), o.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    return o;
}
} // namespace detail_channel

inline ChannelParseResult parse_channel(const std::string& raw) {
    ChannelParseResult r;
    const std::string v = detail_channel::ch_lower(detail_channel::ch_trim(raw));
    if (v.empty()) return r;                       // 未配置 → 默认，无警告
    if (v == kChannelValueGlobal) { r.channel = UpdateChannel::Global; return r; }
    if (v == kChannelValueCn || v == kChannelValueChina) {
        r.channel = UpdateChannel::ChinaMainland;
        return r;
    }
    r.valid = false;
    r.channel = kDefaultChannel;                  // 安全回退，绝不落到未知通道
    r.warning = "update.conf: channel 取值非法，已安全回退到默认通道";
    return r;
}

// 枚举 → 配置键（写回 update.conf / 生成模板用）。
inline const char* channel_config_value(UpdateChannel ch) {
    return ch == UpdateChannel::ChinaMainland ? kChannelValueCn : kChannelValueGlobal;
}

// 枚举 → 稳定 code（UI 命令 / 回显用，与配置键同形但语义独立）。
inline const char* channel_code(UpdateChannel ch) { return channel_config_value(ch); }

// ---------------------------------------------------------------------------
// 3. 通道 → 清单来源（**本轮只返回常量/结构，不发起请求**）
//
// global 的清单地址沿用现有 kDefaultManifestUrl（在 update_check.h），由调用方传入
// globalManifestUrl —— 避免在两个头里各写一遍同一字面量（唯一真相源在 update_check.h）。
// cn 返回后台签名清单地址常量。
// ---------------------------------------------------------------------------
inline std::string channel_manifest_url(UpdateChannel ch,
                                        const std::string& globalManifestUrl) {
    return ch == UpdateChannel::ChinaMainland
        ? std::string(kChinaManifestUrl)
        : globalManifestUrl;
}

// ---------------------------------------------------------------------------
// 4. 后台签名清单形状（框架阶段只定义形状，不解析 / 不验签 / 不解包）
//
// 与现有 Manifest（单 dmg + download_url）形状**不同**：后台清单是
//   PS256 签名清单 + files[]（每个文件一个确定性 ZIP 对象，服务端不托管整包 dmg 直链）。
// 本结构把「后台清单 → 与现有 Manifest 等价的 version/sha256/size/notes + 对象列表」
// 表达出来；等后台就绪后填实的顺序**用字段和 ready() 钉死**：
//
//   固定顺序（顺序本身就是安全边界，不许重排；同 install_from_local_dmg）：
//     ① 取签名清单           GET /api/v1/update/macos/latest
//     ② 验签(PS256)         ← 必须先于 ③④；signatureVerified=true 才能继续
//     ③ 按 files[] 取对象   GET /api/v1/update/macos/objects/<sha256>.zip
//     ④ deflate 解包 + 整包重组（全量更新，不做本地 sha 差异）→ 得到完整 .dmg；
//                          objectsAssembled=true 才能继续
//     ⑤ verify(sha256+size) = 现有 verify_downloaded_file（**必须在 mount 之前**）
//     ⑥ mount_image → install_app_bundle → unmount_image（现有 install_from_local_dmg）
//
// 本轮 ①②③④ 都未实现：signatureVerified / objectsAssembled 默认 false，
// ready()==false ⟹ 任何调用方都不得进入 ⑤⑥，也不得判「已是最新 / 可安装」。
// 这样「切到大陆后既有链路的调用形状与失败语义保持一致」由类型保证，而非注释约定。
// ---------------------------------------------------------------------------
struct ChannelObject {
    std::string sha256;     // 对象标识 = /objects/<sha256>.zip
    long long   size = 0;
    std::string path;       // 解包后在整包内的相对路径
};

// 2026-11-10：后台新增「全量包」通道（DMG / ZIP 整包直链）。
//   与增量对象（files[]）**并存、互不替代**：增量省流量是日常，全量包用于
//   装新机 / 回滚 / 兜底，不再依赖百度网盘。
//   下载：GET /api/v1/update/macos/packages/<sha256>.dmg（200/206、ETag）
//   清单里是**可选**字段：
//     "package": {"kind":"dmg","name":"RLPlayer-3.2.3.dmg","sha256":"<64hex>","size":12345678}
//   ⚠️ sha256 必须等于 URL 里的那段（服务端上传时已强校验，客户端仍要复核本地字节）。
namespace detail_channel {
// 64 位 hex（sha256）。放在 ChannelPackage 之前，避免结构体内静态函数的声明顺序问题。
inline bool is_hex64(const std::string& s) {
    if (s.size() != 64) return false;
    for (unsigned char c : s) if (!std::isxdigit(c)) return false;
    return true;
}
} // namespace detail_channel

struct ChannelPackage {
    std::string kind;       // "dmg" / "zip"
    std::string name;       // 文件名（Content-Disposition 用；客户端只用来回显）
    std::string sha256;     // 包内容摘要，也用于拼下载 URL
    long long   size = 0;

    bool valid() const {
        return (kind == "dmg" || kind == "zip") &&
               detail_channel::is_hex64(sha256) && size > 0;
    }
    // 下载地址由 sha256 + kind 决定，**不接受清单直接给 URL**
    //（否则等于让服务端指定客户端去下载任意地址）。
    std::string download_url() const {
        if (!valid()) return std::string();
        std::string u = "https://";
        u += kChinaHost;
        u += "/api/v1/update/macos/packages/";
        u += sha256;
        u += ".";
        u += kind;
        return u;
    }
};

struct ChannelManifest {
    // —— 与现有 Manifest 等价的判定字段（版本比较 / 校验全复用 update_check.h 的纯函数）——
    std::string version;
    std::string sha256;     // 整包 dmg 的 sha256（全量包路径用它）
    long long   size = 0;
    std::string notes;

    // —— 后台特有 ——
    std::string signature;                   // PS256 签名
    std::string kid;                         // 验签公钥 id
    std::string installMode;                 // "incremental" / "manual" / ...
    std::vector<ChannelObject> objects;      // files[] 等价：增量对象列表
    ChannelPackage package;                  // 全量包（可选；空 = 该清单没提供）

    // 顺序闸门：只有验签完成后才允许置 true。
    bool signatureVerified = false;          // ② 验签完成
    bool objectsAssembled  = false;          // ④ 增量对象解包 + 整包重组完成

    // 「可以进入既有 verify→mount→replace 链路」的唯一判据。
    // 两条路径二选一：全量包（package 合法）或增量重组完成。
    bool ready() const {
        if (!signatureVerified) return false;
        if (!version.empty() && !sha256.empty() && size > 0 && objectsAssembled) return true;
        return has_package();
    }
    bool has_package() const { return package.valid(); }
};

// ---------------------------------------------------------------------------
// 5. 中国大陆通道「不可用」时的诚实提示
//
// 绝不冒充「已是最新」，绝不引导百度网盘（用户 2026-11-09 定的语义）。
// 后台就绪后正常路径不再用它；仅当后台真的取不到清单时才回这条。
// ---------------------------------------------------------------------------
inline constexpr const char kChinaChannelUnavailableMessage[] =
    "中国大陆更新通道暂时不可用，请稍后重试，或切换为全球通道";

// ---------------------------------------------------------------------------
// 6. 后台签名清单（JWS 信封）解析 —— 纯函数、无 IO、可离线单测
//
// 线上形态（2026-11-10 实测）：
//   {"alg":"PS256","kid":"rlplayer-macos-...","payload":"<base64url>","signature":"<base64url>"}
// payload 解出来的 JSON：
//   {schema, platform, channel, version, install_mode, notes, files[], manual, package?}
//
// ⚠️ **本函数只解包与解析，不做验签**。验签必须在调用方（Security.framework）完成，
//    并且必须在解包 / 安装之前（由 ChannelManifest::signatureVerified 闸门保证）。
//    解析失败一律返回 valid=false —— 绝不"读不到就当最新"。
// ---------------------------------------------------------------------------
struct ManifestParse {
    bool valid = false;
    std::string error;       // 人类可读，**不含**凭据
    ChannelManifest manifest;
    std::string payloadJson; // 解出来的 payload 原文（验签要对它做 PSS-verify）
};

namespace detail_channel {

inline int b64url_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

// base64url 解码（容忍缺失的 '=' 填充；遇到非法字符即失败）。
inline bool b64url_decode(const std::string& in, std::string& out) {
    out.clear();
    if (in.size() % 4 == 1) return false;
    unsigned int buf = 0;
    int bits = 0;
    for (char ch : in) {
        if (ch == '=') break;                       // 填充：忽略
        if (ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t') continue;
        const int v = b64url_val(ch);
        if (v < 0) return false;
        buf = (buf << 6) | (unsigned int)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back((char)((buf >> bits) & 0xFF));
        }
    }
    return true;
}

// base64url 编码（无填充）。**生产路径不用它** —— 只用给测试构造信封、
// 以及将来若需要回传签名数据。客户端永远不签名（私钥不在客户端）。
inline std::string b64url_encode(const std::string& in) {
    static const char* kAlphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    std::string out;
    out.reserve((in.size() * 4 + 2) / 3);
    unsigned int buf = 0;
    int bits = 0;
    for (unsigned char c : in) {
        buf = (buf << 8) | c;
        bits += 8;
        while (bits >= 6) {
            bits -= 6;
            out.push_back(kAlphabet[(buf >> bits) & 0x3F]);
        }
    }
    if (bits > 0) out.push_back(kAlphabet[(buf << (6 - bits)) & 0x3F]);
    return out;
}

} // namespace detail_channel

// 解析后台清单信封 + payload。这一步**不含验签**。
inline ManifestParse parse_china_manifest(const std::string& json) {
    ManifestParse r;
    const rta::net::Json j = rta::net::json_parse(json);
    if (j.type != rta::net::Json::Obj) { r.error = "清单不是 JSON 对象"; return r; }

    const std::string alg = j["alg"].s();
    const std::string payloadB64 = j["payload"].s();
    if (payloadB64.empty()) { r.error = "清单缺少 payload"; return r; }
    if (!alg.empty() && alg != "PS256") { r.error = "清单 alg 不是 PS256"; return r; }

    std::string payload;
    if (!detail_channel::b64url_decode(payloadB64, payload) || payload.empty()) {
        r.error = "清单 payload 不是合法 base64url";
        return r;
    }
    const rta::net::Json p = rta::net::json_parse(payload);
    if (p.type != rta::net::Json::Obj) { r.error = "payload 不是 JSON 对象"; return r; }

    ChannelManifest m;
    m.kid = j["kid"].s();
    m.signature = j["signature"].s();
    m.version = p["version"].s();
    m.notes = p["notes"].s();
    m.installMode = p["install_mode"].s();

    // version 必须是合法版本号，否则视为清单非法（绝不"读不到就当最新"）
    if (m.version.empty()) { r.error = "清单缺少 version"; return r; }

    // 增量对象列表（可选）
    const rta::net::Json& files = p["files"];
    if (files.type == rta::net::Json::Arr) {
        for (size_t i = 0; i < files.size(); ++i) {
            const rta::net::Json& f = files.at(i);
            if (f.type != rta::net::Json::Obj) continue;
            ChannelObject o;
            o.sha256 = f["sha256"].s();
            o.path = f["path"].s();
            if (f.has("size") && f["size"].type == rta::net::Json::Num)
                o.size = (long long)f["size"].n();
            if (!o.sha256.empty()) m.objects.push_back(o);
        }
    }

    // 全量包（可选）：package{kind,name,sha256,size}
    const rta::net::Json& pk = p["package"];
    if (pk.type == rta::net::Json::Obj) {
        ChannelPackage cp;
        cp.kind = pk["kind"].s();
        cp.name = pk["name"].s();
        cp.sha256 = pk["sha256"].s();
        if (pk.has("size") && pk["size"].type == rta::net::Json::Num)
            cp.size = (long long)pk["size"].n();
        if (cp.valid()) {
            m.package = cp;
            // 有合法全量包时，判定用的 sha256/size 用它（与增量路径字段同义）
            m.sha256 = cp.sha256;
            m.size = cp.size;
        }
    }

    r.valid = true;
    r.manifest = m;
    r.payloadJson = payload;
    return r;
}

} // namespace rta::update
