// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// track_identity.h — 1.1.5-beta2 M-13：文件名兜底的曲目身份解析（纯逻辑）
//
// 契约见 PLAN-1.1.5-beta2.md §1.6：
//   * tag title+artist 都有 -> source=tag（标签优先，原样透传）
//   * 否则用 parse.h 的 parse_filename 解析「去扩展名的 basename」补缺失字段，source=filename
//   * 纯曲号 / 无意义名（unknown/untitled/未命名/audio/recording/纯数字/单字符/全符号）
//     -> sufficient=false，reason="资料不足：缺少艺术家与曲名"（0 次检索请求的入口）
//   * tag title 有、artist 无、文件名解析不出 artist -> title 可用、sufficient=true（单曲名检索）
//   * filePath 为空且 tag 不全 -> insufficient
//
// 纯头文件、无网络、无平台依赖、无音频；namespace rta::meta；复用 src/meta/parse.h。
#pragma once

#include "meta/parse.h"

#include <string>

namespace rta::meta {

struct TrackIdentity {
    std::string title, artist, album;
    std::string source;      // "tag" | "filename" | "insufficient"
    bool sufficient = false;
    std::string reason;      // insufficient 的原因（中文，给 UI）
};

namespace track_identity_detail {

inline std::string ti_trim(const std::string& s) {
    return parse_detail::pd_trim(s);
}

// 去路径 + 去扩展名（只取最后一段；不碰原串其它内容）。
inline std::string ti_stem(const std::string& filePath) {
    std::string s = filePath;
    const size_t slash = s.find_last_of("/\\");
    if (slash != std::string::npos) s = s.substr(slash + 1);
    const size_t dot = s.find_last_of('.');
    if (dot != std::string::npos && dot > 0) s = s.substr(0, dot);
    return s;
}

inline bool ti_is_meaningful(const std::string& raw) {
    const std::string s = ti_trim(raw);
    if (s.empty()) return false;

    // 统计「字」数并判断是否含字母/CJK（纯数字、全符号 -> false）
    size_t cps = 0;
    bool hasLetter = false;
    std::string lower;
    lower.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        const unsigned char c = (unsigned char)s[i];
        size_t len = 1;
        if (c >= 0xF0) len = 4;
        else if (c >= 0xE0) len = 3;
        else if (c >= 0xC0) len = 2;
        if (i + len > s.size()) len = 1;
        ++cps;
        if (c >= 0x80) {
            hasLetter = true;
            lower.append(s, i, len);
        } else {
            char ch = (char)c;
            if (ch >= 'A' && ch <= 'Z') ch = (char)(ch - 'A' + 'a');
            if (ch >= 'a' && ch <= 'z') hasLetter = true;
            lower.push_back(ch);
        }
        i += len;
    }
    if (cps < 2) return false;          // 单字符（含单个 CJK）无法证明
    if (!hasLetter) return false;       // 纯数字 / 全符号

    // 压缩成「小写字母数字 + CJK」串，便于判纯曲号/无意义名
    std::string compact;
    for (unsigned char ch : lower) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch >= 0x80)
            compact.push_back((char)ch);
    }
    if (compact.empty()) return false;
    bool allDigits = true;
    for (char ch : compact) if (ch < '0' || ch > '9') { allDigits = false; break; }
    if (allDigits) return false;

    static const char* kBad[] = {
        "unknown", "untitled", "audio", "recording", "未命名", "track", "song",
        "title", "音轨", "曲目", "无名", "未知", "新建录音",
    };
    for (const char* b : kBad) if (compact == b) return false;

    // "Track 01" / "Track01" / "曲目01" 这类「词 + 纯数字」仍是曲号
    static const char* kNumPrefix[] = { "track", "song", "audio", "recording", "音轨", "曲目" };
    for (const char* p : kNumPrefix) {
        const std::string pre(p);
        if (compact.size() > pre.size() && compact.compare(0, pre.size(), pre) == 0) {
            bool restDigits = true;
            for (size_t i = pre.size(); i < compact.size(); ++i)
                if (compact[i] < '0' || compact[i] > '9') { restDigits = false; break; }
            if (restDigits) return false;
        }
    }
    return true;
}

inline TrackIdentity ti_insufficient() {
    TrackIdentity r;
    r.source = "insufficient";
    r.sufficient = false;
    r.reason = "资料不足：缺少艺术家与曲名";
    return r;
}

} // namespace track_identity_detail

inline TrackIdentity resolve_track_identity(const std::string& tagTitle,
                                            const std::string& tagArtist,
                                            const std::string& tagAlbum,
                                            const std::string& filePath) {
    namespace d = track_identity_detail;
    TrackIdentity r;
    r.title  = d::ti_trim(tagTitle);
    r.artist = d::ti_trim(tagArtist);
    r.album  = d::ti_trim(tagAlbum);

    // 1) tag 齐全 -> 标签优先，文件名再脏也不覆盖
    if (!r.title.empty() && !r.artist.empty()) {
        r.source = "tag";
        r.sufficient = true;
        return r;
    }

    // 2) filePath 为空且 tag 不全 -> 无从兜底
    if (d::ti_trim(filePath).empty()) return d::ti_insufficient();

    // 3) 解析文件名（去扩展名的 basename）
    const ParsedName p = parse_filename(d::ti_stem(filePath));
    const bool titleOk = d::ti_is_meaningful(p.title);
    const bool artistOk = d::ti_is_meaningful(p.artist);

    // tag 已有 title 时也算「有曲名」；文件名解析不出 artist 仍允许单曲名检索（旧行为）
    const bool haveTitle = !r.title.empty() || titleOk;
    if (!haveTitle) return d::ti_insufficient();

    if (r.title.empty() && titleOk) r.title = p.title;      // 用解析值补缺失字段
    if (r.artist.empty() && artistOk) r.artist = p.artist;  // tag 已有的优先
    // album 只能来自 tag：文件名规则不解析专辑
    r.source = "filename";
    r.sufficient = true;
    r.reason.clear();
    return r;
}

} // namespace rta::meta
