// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// cover_fetch.h — 在线封面抓取的**纯逻辑**（无网络、无全局状态、可离线单测）
//
// 为什么单独成头文件（而不是像上游那样全塞进 tools/rtaweb.cpp）：
//   上游把「专辑键清洗 / Dice 名称比对 / 图片头校验 / 负缓存过期」这些**判据**和
//   「WinHTTP 下载 / 后台线程池 / 路由分发」混在同一个 1044 行改动里，结果这些判据
//   一条都没法单独测 —— 上游只能靠"真库跑一遍看覆盖率"。本机没有那份真库，
//   照抄就等于把"未验证"当"已完成"（铁律 3）。
//   拆出来后 tests/test_cover_fetch.cpp 能对**同一份实现**逐条否定：
//   目录穿越、Dice 负向对照、HTML 错误页、负缓存过期 —— 全部离线可跑。
//   与 tools/naa_discover.h（与 CLI naa_scan 共用探测本体）是同一套拆分口径。
//
// 平台中立性（本文件是 mac 移植的**核心差异点**，Windows 假设一条都不许进来）：
//   * 路径一律 UTF-8 窄串 + std::filesystem::u8path（mac 的 fs::path(wstring) 会抛
//     "locale not supported"，见 src/net/library.h 的 p8() 注释）；
//   * 不出现 MoveFileExW / _dupenv_s / GetFileAttributesExW / WinHTTP；
//   * 缓存目录由调用方注入（rtaweb 传 runtime_state_dir()/covercache），
//     所以这里也不假设"exe 同目录可写"（.app 内是只读签名区）。
#pragma once
#include "net/json.h"          // 网易 type=10 专辑搜索响应解析（rta::net::Json）

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <vector>

namespace rta::cover {

namespace fsx = std::filesystem;

// 专辑键的**唯一合法形态**：恰好 16 位十六进制（= library.h 的 fnv_hex 输出）。
// 大写也接受（?k= 是公开入口，浏览器/用户可能写成大写），调用方需要小写时自己 tolower。
inline bool cover_key_is_strict_hex16_lower_ok(const std::string& key) {
    if (key.size() != 16) return false;
    for (unsigned char c : key)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
    return true;
}

// 「人工设置封面」端点专用：只接受**平台自己生成的 16 位十六进制**专辑键。
// 为什么比 GET 严：GET 只读，乱输入最多 404；set 会**写盘**，必须没有解释空间。
// 上游口径：k=..\..\windows\win.ini 里恰好含 hex 字符 "d"，若不校验长度就会写出一张 d.jpg。
inline bool cover_key_is_strict_hex16(const std::string& key) {
    return cover_key_is_strict_hex16_lower_ok(key);
}

// ---------------- 预算与阈值（与上游 c41ce97 逐字对齐，改动会改变行为）----------------
inline constexpr int    kCoverBudgetMs      = 6000;              // 单张专辑总预算（硬上限）
inline constexpr int    kCoverSearchMs      = 3000;              // 搜索单跳上限
inline constexpr int    kCoverDownloadMs    = 3000;              // 下载单跳上限
inline constexpr std::size_t kCoverMinBytes = 2048;              // 小于它当「没有封面」
// 正缓存读取上限：上游实测 163 会给 8~10 MB 的封面，旧上限 8 MB 会造成
// 「cvSrc=net 但 GET 404」。放宽到 24 MB，并让 has/read 同一口径。
inline constexpr unsigned long long kCoverMaxBytes = 24ull * 1024ull * 1024ull;
inline constexpr long long kCoverNegSec     = 7LL * 24 * 3600;   // 负缓存有效期：7 天
inline constexpr int    kCoverBgConcurrency = 2;                 // 后台同时抓几张

// ---------------- 专辑键 → 文件名安全片段 ----------------
// 库里正常是 16 位十六进制（fnv_hex），但 ?k= 是**公开入口**：
//   ?k=..\..\windows\win.ini  之类必须挡住 —— 否则任何本机进程都能借这个端点
//   往任意路径写/读文件（目录穿越）。这条与平台无关，Windows/mac 都要做。
// mac 侧额外理由：POSIX 上 '\' 是**合法文件名字符**，`..\..\x` 不是一个穿越路径，
//   但 `../../x` 是；白名单对两种写法都一并挡住，不留"换个分隔符试试"的口子。
//
// ★ 与上游的一处**收紧**（mac 重做时的实测发现，见 tests/test_cover_fetch.cpp）：
//   上游口径是 `!key.empty() && key.size() <= 40 && 全 hex`，于是 `?k=d` 能原样通过
//   ⟹ 在缓存目录里凭空写出一张 `d.jpg`。它不构成穿越（仍在缓存目录内），但那是
//   "任何本机进程都能让程序在缓存目录造任意短名文件"的口子，而且与真专辑键永不冲突的
//   前提也不成立（真键恒为 16 位）。这里收紧成**恰好 16 位 hex**才原样保留，
//   其余一律 FNV-1a 成 16 位 hex —— 与 set 端点 `cover_key_is_strict_hex16` 同一口径。
inline std::string cover_key_slug(const std::string& key) {
    if (cover_key_is_strict_hex16_lower_ok(key)) return key;
    // 非 16 位十六进制 ⟹ 用 FNV-1a 64 位重算成一个纯十六进制叶子（与 library.h 的 fnv_hex 同算法同格式）
    uint64_t h = 1469598103934665603ull;
    for (unsigned char c : key) { h ^= (uint64_t)c; h *= 1099511628211ull; }
    char b[24];
    std::snprintf(b, sizeof(b), "%016llx", (unsigned long long)h);
    return std::string(b);
}

// 「人工设置封面」端点专用：只接受**平台自己生成的 16 位十六进制**专辑键。
// 为什么比 GET 严：GET 只读，乱输入最多 404；set 会**写盘**，必须没有解释空间。
// 上游口径：k=..\..\windows\win.ini 里恰好含 hex 字符 "d"，若不校验长度就会写出一张 d.jpg。
// （实现见文件顶部 cover_key_is_strict_hex16_lower_ok —— 两者同一判据，避免两处口径漂移。）

struct CoverPaths {
    std::string dir;      // 缓存目录（由调用方注入：runtime_state_dir()/covercache 或 RLPLAYER_COVER_DIR）
    std::string jpg;      // <dir>/<slug>.jpg    正缓存（网图/人工设置）
    std::string part;     // <dir>/<slug>.jpg.part 写入中的临时文件（rename 前）
    std::string none;     // <dir>/<slug>.none   负缓存（空文件；mtime 超过 7 天视为过期）
};

// 平台路径拼接一律走 rta::platform::join（自动用 native_separator），
// 不用 '\\' 硬拼 —— 那是 Windows 分隔符，在 POSIX 上会被当成文件名字符（历史事故见 library.h）。
inline CoverPaths cover_paths_in(const std::string& dir, const std::string& key) {
    CoverPaths p;
    p.dir  = dir;
    const std::string leaf = cover_key_slug(key);
    const std::string base = dir.empty() ? leaf : (dir + "/" + leaf);
    p.jpg  = base + ".jpg";
    p.part = p.jpg + ".part";
    p.none = base + ".none";
    return p;
}

// ---------------- 图片真伪校验（别把 4xx 错误页/防盗链 HTML 当封面存下来）----------------
inline bool cover_looks_like_image(const std::vector<unsigned char>& b) {
    if (b.size() >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;               // JPEG
    if (b.size() >= 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return true;  // PNG
    if (b.size() >= 12 && b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F' &&             // WEBP
        b[8] == 'W' && b[9] == 'E' && b[10] == 'B' && b[11] == 'P') return true;
    if (b.size() >= 6 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F' && b[3] == '8') return true;   // GIF
    return false;
}

// 落盘前**唯一的**准入判据：大小够 + 文件头是图。
// 两条必须同时成立：只查大小会收下 3 KB 的 HTML 错误页；只查头会收下 200 B 的坏图。
inline bool cover_accept_bytes(const std::vector<unsigned char>& b) {
    return b.size() >= kCoverMinBytes &&
           (unsigned long long)b.size() <= kCoverMaxBytes &&
           cover_looks_like_image(b);
}

// 按文件头给 Content-Type（人工设置的封面可能是 PNG/WEBP/GIF，不能一律报 jpeg）
inline const char* cover_mime_of(const std::vector<unsigned char>& b) {
    if (b.size() >= 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return "image/png";
    if (b.size() >= 3 && b[0] == 0xFF && b[1] == 0xD8) return "image/jpeg";
    if (b.size() >= 12 && b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F' &&
        b[8] == 'W' && b[9] == 'E' && b[10] == 'B' && b[11] == 'P') return "image/webp";
    if (b.size() >= 6 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F') return "image/gif";
    return "image/jpeg";
}

// ---------------- 磁盘缓存（**请求线程零网络**的实现基础：只有 stat/读文件）----------------
// 正缓存存在且大小在 [1, 24MB]？只 stat，不读内容（列表端点每张专辑会调一次）。
inline bool cover_has_disk_in(const std::string& dir, const std::string& key) {
    if (key.empty()) return false;
    std::error_code ec;
    const auto sz = fsx::file_size(fsx::u8path(cover_paths_in(dir, key).jpg), ec);
    return !ec && sz > 0 && (unsigned long long)sz <= kCoverMaxBytes;
}

inline bool cover_read_cached_in(const std::string& dir, const std::string& key,
                                std::vector<unsigned char>& out) {
    if (key.empty()) return false;
    const std::string p = cover_paths_in(dir, key).jpg;
    std::error_code ec;
    const auto sz = fsx::file_size(fsx::u8path(p), ec);
    if (ec || sz == 0 || (unsigned long long)sz > kCoverMaxBytes) return false;
    std::ifstream f(fsx::u8path(p), std::ios::binary);
    if (!f) return false;
    out.resize((std::size_t)sz);
    f.read(reinterpret_cast<char*>(out.data()), (std::streamsize)sz);
    if (!f || (std::size_t)f.gcount() != (std::size_t)sz) { out.clear(); return false; }
    return true;
}

// 文件 mtime 是否比 maxAgeSec 更旧。读不到 mtime 一律当"过期"（宁可多查一次）。
inline bool cover_file_older_than(const std::string& path, long long maxAgeSec) {
    std::error_code ec;
    const auto t = fsx::last_write_time(fsx::u8path(path), ec);
    if (ec) return true;
    const auto now = fsx::file_time_type::clock::now();
    return std::chrono::duration_cast<std::chrono::seconds>(now - t).count() > maxAgeSec;
}

// 负缓存是否**还在有效期内**（存在且 mtime ≤ 7 天）。
// ★ 铁律级语义：只有"服务器明确答复没有"才写 .none；断网/超时**不写** ——
//   否则一次离线运行把 7 天缓存全污染成"没有封面"，用户联网后再也看不到图。
inline bool cover_neg_fresh_in(const std::string& dir, const std::string& key) {
    if (key.empty()) return false;
    const std::string p = cover_paths_in(dir, key).none;
    std::error_code ec;
    if (!fsx::exists(fsx::u8path(p), ec)) return false;
    return !cover_file_older_than(p, kCoverNegSec);
}

// ---------------- 名称比对（宁缺勿错，但容得下"同一张碟的不同写法"）----------------
// 网易云的专辑名与文件标签在四类细节上不一致（上游实测：28 个"完全同名搜不到"里 22 个属这四类）：
//   ① 引号：       RESOLVERS 1st "幻梦拟声"          vs RESOLVERS 1st 幻梦拟声
//   ② 括号后缀：   熏风（Dizzymart Special Release） vs 熏风
//   ③ 繁体/异体字：春秋历命序 vs 春秋歷命序
//   ④ 词序/重音符：NACATA Vol.1 New Born 新生 vs NACATA Vol.1 新生 New Born
// 所以判据不是"字符串相等"，而是「规范化后的**字符多重集 Dice 系数**」：
//   ≥ 0.90 ⟹ 认；0.72~0.90 ⟹ 必须**艺术家也对得上**；< 0.72 ⟹ 一律不认。
// **绝不**在名字都不像时"拿第一张凑数"：落盘的错图不会自己变对，比空白更糟。
inline void cover_utf8_cp(const std::string& s, std::vector<uint32_t>& out) {
    std::size_t i = 0;
    while (i < s.size()) {
        const unsigned char c = (unsigned char)s[i];
        uint32_t cp = c;
        std::size_t n = 1;
        if (c >= 0xF0) { n = 4; cp = c & 0x07u; }
        else if (c >= 0xE0) { n = 3; cp = c & 0x0Fu; }
        else if (c >= 0xC0) { n = 2; cp = c & 0x1Fu; }
        if (n > 1) {
            if (i + n > s.size()) { out.push_back(c); ++i; continue; }
            for (std::size_t k = 1; k < n; ++k) cp = (cp << 6) | ((uint32_t)((unsigned char)s[i + k]) & 0x3Fu);
        }
        out.push_back(cp);
        i += n;
    }
}

// 规范化：全角 ASCII → 半角、ASCII 小写、丢标点/空白/引号、丢括号（含全角括号）里的内容、
// 丢带音符的拉丁字母（Promúsica → Promsica，不影响 Dice 判断）。
// 保留：ASCII 字母数字、CJK 汉字、假名、谚文。
inline std::vector<uint32_t> cover_name_key(const std::string& s) {
    std::vector<uint32_t> raw, out;
    cover_utf8_cp(s, raw);
    int depth = 0;
    out.reserve(raw.size());
    for (uint32_t cp : raw) {
        if (cp >= 0xFF01 && cp <= 0xFF5E) cp -= 0xFEE0;        // 全角 ASCII → 半角
        if (cp == 0x3000) cp = ' ';                            // 全角空格
        if (cp == '(') { ++depth; continue; }
        if (cp == ')') { if (depth > 0) --depth; continue; }
        if (depth > 0) continue;                               // 括号里的后缀不参与比对
        if (cp >= 'A' && cp <= 'Z') { out.push_back(cp - 'A' + 'a'); continue; }
        if ((cp >= 'a' && cp <= 'z') || (cp >= '0' && cp <= '9')) { out.push_back(cp); continue; }
        if (cp < 0x2E80) continue;                             // 其它 ASCII/拉丁补充（标点、重音符）全丢
        if (cp >= 0x3000 && cp <= 0x303F) continue;            // CJK 标点
        if (cp >= 0xFE30 && cp <= 0xFE4F) continue;            // 兼容形式标点
        if (cp >= 0xFF00 && cp <= 0xFF0F) continue;
        if (cp >= 0xFF1A && cp <= 0xFF20) continue;
        if (cp >= 0xFF3B && cp <= 0xFF40) continue;
        out.push_back(cp);                                     // 汉字 / 假名 / 谚文 / 拉丁字母
    }
    return out;
}

// 字符多重集 Dice 系数：2·|A∩B| / (|A|+|B|)，按多重集（重复字符各算各的）。
inline double cover_dice(const std::vector<uint32_t>& a, const std::vector<uint32_t>& b) {
    if (a.empty() || b.empty()) return 0.0;
    std::map<uint32_t, int> cnt;
    for (uint32_t c : a) ++cnt[c];
    std::size_t inter = 0;
    for (uint32_t c : b) {
        auto it = cnt.find(c);
        if (it != cnt.end() && it->second > 0) { --it->second; ++inter; }
    }
    return 2.0 * (double)inter / (double)(a.size() + b.size());
}

// needle 是否是 hay 的连续子序列（用于「包含关系」单独放行）
inline bool cover_vec_has(const std::vector<uint32_t>& hay, const std::vector<uint32_t>& needle) {
    if (needle.empty() || needle.size() > hay.size()) return false;
    const std::size_t last = hay.size() - needle.size();
    for (std::size_t i = 0; i <= last; ++i) {
        bool ok = true;
        for (std::size_t k = 0; k < needle.size(); ++k) if (hay[i + k] != needle[k]) { ok = false; break; }
        if (ok) return true;
    }
    return false;
}

// 从网易 type=10 专辑搜索结果里挑一张**可信的** picUrl；挑不出就返回空串。
// 判据（三条同时管）：
//   ① Dice < 0.72 且无包含关系 ⟹ 直接排除（《深空余音》vs《日落日出》Dice=0 天然挡住）；
//   ② Dice < 0.90 或仅靠包含关系 ⟹ 必须艺术家也对得上（《Routine LP》vs《Funky Routine LP》
//      Dice=0.75 但没有艺术家佐证 ⟹ 挡住）；
//   ③ 多张候选取 Dice 最高者；≥0.999 提前收工。
inline std::string cover_pick_pic(const std::string& js, const std::string& wantName,
                                  const std::string& wantArtist) {
    const rta::net::Json j = rta::net::json_parse(js);
    const rta::net::Json& albums = j["result"]["albums"];
    const std::vector<uint32_t> want = cover_name_key(wantName);
    const std::vector<uint32_t> who  = cover_name_key(wantArtist);
    std::string best;
    double bestScore = 0.0;
    for (std::size_t i = 0; i < albums.size(); ++i) {
        const rta::net::Json& a = albums.at(i);
        const std::string pic = a["picUrl"].s();
        if (pic.empty()) continue;
        const std::vector<uint32_t> nm = cover_name_key(a["name"].s());
        const double d = cover_dice(want, nm);
        // 「名字被加了前缀/后缀」也算候选：《遠景Landscape》vs 网易的
        // 《遠景Landscape -Touhou Mellow Beats-》Dice 只有 0.52，但确实是同一张碟。
        // 所以包含关系单独放行 —— 只是仍要艺术家佐证。
        const bool contained = (want.size() >= 4 && cover_vec_has(nm, want)) ||
                               (nm.size() >= 4 && cover_vec_has(want, nm));
        if (d < 0.72 && !contained) continue;
        bool artistOk = false;
        if (who.size() >= 2) {
            const rta::net::Json& arr = a["artists"];
            for (std::size_t k = 0; k < arr.size() && !artistOk; ++k) {
                const std::vector<uint32_t> ca = cover_name_key(arr.at(k)["name"].s());
                if (ca.size() >= 2 && (cover_vec_has(who, ca) || cover_vec_has(ca, who))) artistOk = true;
            }
            if (!artistOk) {
                const std::vector<uint32_t> ca = cover_name_key(a["artist"]["name"].s());
                if (ca.size() >= 2 && (cover_vec_has(who, ca) || cover_vec_has(ca, who))) artistOk = true;
            }
        }
        if (d < 0.90 && !artistOk) continue;          // 只是"有点像"或"名字被加了前后缀"：必须有艺术家佐证
        if (d > bestScore) { best = pic; bestScore = d; if (d >= 0.999) break; }
    }
    return best;
}

// ---------------- 查询串百分号编码 ----------------
// 为什么不复用 rta::platform::percent_encode_path：那个不打 '&' '=' '+' '%'，
// 专辑名里出现「AC/DC & Friends」「100%」时会被服务端拆成别的参数，必须全编。
inline std::string cover_pct_encode(const std::string& s) {
    static const char* hex = "0123456789ABCDEF";
    std::string o;
    o.reserve(s.size() * 3);
    for (unsigned char c : s) {
        const bool unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                                (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~';
        if (unreserved) { o += (char)c; continue; }
        o += '%';
        o += hex[c >> 4];
        o += hex[c & 0x0F];
    }
    return o;
}

// 把 prefetch 的 ?k=/body k= 拆成键列表（逗号/分号/竖线/换行分隔，去首尾空白）。
inline std::vector<std::string> cover_parse_keys(const std::string& raw) {
    std::vector<std::string> keys;
    std::string cur;
    auto flush = [&]() {
        std::size_t b = 0, e = cur.size();
        while (b < e && (unsigned char)cur[b] <= 0x20) ++b;
        while (e > b && (unsigned char)cur[e - 1] <= 0x20) --e;
        if (e > b) keys.push_back(cur.substr(b, e - b));
        cur.clear();
    };
    for (char ch : raw) {
        if (ch == ',' || ch == ';' || ch == '|' || ch == '\n' || ch == '\r') flush();
        else cur += ch;
    }
    flush();
    return keys;
}

// 拼搜索词："名 艺术家"（艺术家为空时只有名）
inline std::string cover_term_of(const std::string& name, const std::string& artist) {
    std::string t = name;
    if (!artist.empty()) { if (!t.empty()) t += ' '; t += artist; }
    return t;
}

} // namespace rta::cover
