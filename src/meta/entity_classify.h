// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// entity_classify.h — 1.1.5-beta2 #21a/#21b：页面类型多信号分类 + 归属证明（纯头文件）
//
// 契约见 PLAN-1.1.5-beta2.md §1.2：
//   * PageKind 7 档（Unknown/Track/Release/Person/Group/Label/Series），tag/label 往返
//   * classify_page(url,title,text)：URL 路径 / 标题 / 正文（前 ~1200 字节）三个来源各投一票，
//     同一 PageKind 得到 >=2 票才给出非 Unknown，否则 Unknown（宁缺毋错，不猜）
//   * page_kind_compatible(requested, page)：固定兼容矩阵（Unknown 一律放行）
//   * attribute_page(...)：先兼容、再名称证明、再艺术家/专辑证据，全过才 belongs=true；
//     拒绝原因写进 reason（进 diag，不静默）
//   * 归一化：%XX 解码 + 全半角折叠 + ASCII 小写 + 丢弃标点/空白；CJK >=2 字、ASCII >=3 字
//     的名称才参与匹配（太短的 "A"/"夜" 无法证明归属）
//
// 无网络、无平台依赖、无音频；namespace rta::meta；全部 inline。
#pragma once

#include "meta/entities.h"   // EntityKind / entity_kind_tag（复用 id 与标签口径）

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

namespace rta::meta {

// ---------------------------------------------------------------------------
// 页面类型
// ---------------------------------------------------------------------------

enum class PageKind : int { Unknown = 0, Track, Release, Person, Group, Label, Series };

inline const char* page_kind_tag(PageKind k) {
    switch (k) {
        case PageKind::Unknown: return "unknown";
        case PageKind::Track:   return "track";
        case PageKind::Release: return "release";
        case PageKind::Person:  return "person";
        case PageKind::Group:   return "group";
        case PageKind::Label:   return "label";
        case PageKind::Series:  return "series";
    }
    return "unknown";
}

inline const char* page_kind_label(PageKind k) {
    switch (k) {
        case PageKind::Unknown: return "未知";
        case PageKind::Track:   return "歌曲";
        case PageKind::Release: return "专辑";
        case PageKind::Person:  return "人物";
        case PageKind::Group:   return "团体";
        case PageKind::Label:   return "厂牌";
        case PageKind::Series:  return "系列";
    }
    return "未知";
}

inline bool page_kind_from_tag(const std::string& tag, PageKind& out) {
    for (int v = 0; v <= 6; ++v) {
        const PageKind k = (PageKind)v;
        if (tag == page_kind_tag(k)) { out = k; return true; }
    }
    return false;
}

// ---------------------------------------------------------------------------
// 归一化细节（ec_ = entity classify detail）
// ---------------------------------------------------------------------------
namespace entity_classify_detail {

inline int ec_hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// URL 里的 %XX 解成原始字节（UTF-8 中文 slug 才能参与名称匹配）。
inline std::string ec_percent_decode(const std::string& s) {
    std::string o;
    o.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size()) {
            const int h = ec_hex(s[i + 1]), l = ec_hex(s[i + 2]);
            if (h >= 0 && l >= 0) { o.push_back((char)((h << 4) | l)); i += 2; continue; }
        }
        o.push_back(s[i]);
    }
    return o;
}

inline size_t ec_u8_len(unsigned char c) {
    if (c >= 0xF0) return 4;
    if (c >= 0xE0) return 3;
    if (c >= 0xC0) return 2;
    return 1;
}

// 全半角折叠 + ASCII 小写；保留标点（供关键词匹配用）。
inline std::string ec_fold(const std::string& raw) {
    std::string o;
    o.reserve(raw.size());
    for (size_t i = 0; i < raw.size();) {
        const unsigned char c = (unsigned char)raw[i];
        if (c < 0x80) {
            char a = (char)c;
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            o.push_back(a);
            ++i;
            continue;
        }
        size_t len = ec_u8_len(c);
        if (i + len > raw.size()) len = 1;
        if (len == 3) {
            const unsigned cp = ((c & 0x0Fu) << 12) |
                                (((unsigned char)raw[i + 1] & 0x3Fu) << 6) |
                                ((unsigned char)raw[i + 2] & 0x3Fu);
            if (cp >= 0xFF01u && cp <= 0xFF5Eu) {
                char a = (char)(cp - 0xFEE0u);
                if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
                o.push_back(a);
                i += 3;
                continue;
            }
        }
        o.append(raw, i, len);
        i += len;
    }
    return o;
}

// 判等键：只保留 ASCII 小写字母数字与 CJK 字节，丢掉空白/标点/斜杠/连字符。
inline std::string ec_norm(const std::string& raw) {
    const std::string f = ec_fold(ec_percent_decode(raw));
    std::string o;
    o.reserve(f.size());
    for (size_t i = 0; i < f.size();) {
        const unsigned char c = (unsigned char)f[i];
        if (c < 0x80) {
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) o.push_back((char)c);
            ++i;
        } else {
            const size_t len = ec_u8_len(c);
            const size_t n = (i + len <= f.size()) ? len : 1;
            o.append(f, i, n);
            i += n;
        }
    }
    return o;
}

// 归一化串的「字」数：UTF-8 首字节个数（CJK 每字 3 字节算 1）。
inline size_t ec_cp_count(const std::string& norm) {
    size_t n = 0;
    for (unsigned char c : norm) if (c < 0x80 || c >= 0xC0) ++n;
    return n;
}

inline bool ec_has_cjk(const std::string& norm) {
    for (unsigned char c : norm) if (c >= 0x80) return true;
    return false;
}

// CJK >=2 字、ASCII >=3 字才允许参与名称匹配（太短的名字到处都是，证明不了归属）。
inline bool ec_name_provable(const std::string& norm) {
    if (norm.empty()) return false;
    const size_t cps = ec_cp_count(norm);
    return ec_has_cjk(norm) ? (cps >= 2) : (cps >= 3);
}

struct SignalRule { PageKind kind; const char* needle; };

// 固定优先级：先 Specialized 实体，再 Release，最后 Track（避免 "tracklist" 被 "track" 抢走）。
inline const SignalRule kUrlRules[] = {
    { PageKind::Person,  "/artist/" }, { PageKind::Person,  "/artists/" },
    { PageKind::Person,  "/person/" }, { PageKind::Person,  "/people/" },
    { PageKind::Person,  "/musician/" }, { PageKind::Person, "/singer/" },
    { PageKind::Group,   "/band/" }, { PageKind::Group,   "/bands/" },
    { PageKind::Group,   "/group/" }, { PageKind::Group,   "/groups/" },
    { PageKind::Group,   "/idol/" },
    { PageKind::Label,   "/label/" }, { PageKind::Label,   "/labels/" },
    { PageKind::Label,   "/record-label/" }, { PageKind::Label, "/recordlabel/" },
    { PageKind::Series,  "/series/" }, { PageKind::Series,  "/franchise/" },
    { PageKind::Series,  "/project/" }, { PageKind::Series,  "/projects/" },
    { PageKind::Release, "/album/" }, { PageKind::Release, "/albums/" },
    { PageKind::Release, "/release/" }, { PageKind::Release, "/releases/" },
    { PageKind::Release, "/discography/" },
    { PageKind::Track,   "/track/" }, { PageKind::Track,   "/tracks/" },
    { PageKind::Track,   "/song/" }, { PageKind::Track,   "/songs/" },
    { PageKind::Track,   "/lyrics/" },
};

inline const SignalRule kTitleRules[] = {
    { PageKind::Person,  "歌手" }, { PageKind::Person,  "音乐人" },
    { PageKind::Person,  "人物" }, { PageKind::Person,  "生平" },
    { PageKind::Person,  "传记" }, { PageKind::Person,  "简介" },
    { PageKind::Person,  "艺人" }, { PageKind::Person,  "singer" },
    { PageKind::Person,  "musician" }, { PageKind::Person, "artist" },
    { PageKind::Person,  "biography" }, { PageKind::Person, "profile" },
    { PageKind::Person,  "solo" },
    { PageKind::Group,   "乐团" }, { PageKind::Group,   "乐队" },
    { PageKind::Group,   "组合" }, { PageKind::Group,   "团体" },
    { PageKind::Group,   "成员" }, { PageKind::Group,   "band" },
    { PageKind::Group,   "group" }, { PageKind::Group,   "members" },
    { PageKind::Group,   "duo" },
    { PageKind::Label,   "厂牌" }, { PageKind::Label,   "唱片公司" },
    { PageKind::Label,   "label" }, { PageKind::Label,   "records" },
    { PageKind::Series,  "系列" }, { PageKind::Series,  "企划" },
    { PageKind::Series,  "企画" }, { PageKind::Series,  "series" },
    { PageKind::Series,  "franchise" }, { PageKind::Series, "project" },
    { PageKind::Release, "专辑" }, { PageKind::Release, "唱片" },
    { PageKind::Release, "发行" }, { PageKind::Release, "album" },
    { PageKind::Release, "release" }, { PageKind::Release, "discography" },
    { PageKind::Release, "曲目列表" }, { PageKind::Release, "tracklist" },
    { PageKind::Release, "アルバム" }, { PageKind::Release, "発売" },
    { PageKind::Track,   "歌曲" }, { PageKind::Track,   "单曲" },
    { PageKind::Track,   "歌词" }, { PageKind::Track,   "song" },
    { PageKind::Track,   "lyrics" }, { PageKind::Track,   "楽曲" },
};

inline const SignalRule kTextRules[] = {
    { PageKind::Person,  "出生" }, { PageKind::Person,  "生于" },
    { PageKind::Person,  "生平" }, { PageKind::Person,  "个人简介" },
    { PageKind::Person,  "born" }, { PageKind::Person,  "biography" },
    { PageKind::Group,   "成员" }, { PageKind::Group,   "乐团" },
    { PageKind::Group,   "乐队" }, { PageKind::Group,   "组合" },
    { PageKind::Group,   "formed" }, { PageKind::Group,  "members" },
    { PageKind::Group,   "lineup" },
    { PageKind::Label,   "旗下艺人" }, { PageKind::Label, "厂牌" },
    { PageKind::Label,   "唱片公司" }, { PageKind::Label, "founded" },
    { PageKind::Label,   "record label" }, { PageKind::Label, "signed" },
    { PageKind::Series,  "系列作品" }, { PageKind::Series, "企划" },
    { PageKind::Series,  "series" }, { PageKind::Series,  "franchise" },
    { PageKind::Series,  "原作" },
    { PageKind::Release, "曲目列表" }, { PageKind::Release, "tracklist" },
    { PageKind::Release, "track listing" }, { PageKind::Release, "发行时间" },
    { PageKind::Release, "发行日期" }, { PageKind::Release, "release date" },
    { PageKind::Release, "収録曲" }, { PageKind::Release, "专辑介绍" },
    { PageKind::Release, "album" },
    { PageKind::Track,   "作词" }, { PageKind::Track,   "作曲" },
    { PageKind::Track,   "编曲" }, { PageKind::Track,   "演唱" },
    { PageKind::Track,   "歌词" }, { PageKind::Track,   "lyrics" },
    { PageKind::Track,   "songwriter" }, { PageKind::Track, "composed by" },
};

struct Vote { PageKind kind = PageKind::Unknown; const char* needle = nullptr; };

template <size_t N>
inline Vote ec_vote(const std::string& folded, const SignalRule (&rules)[N]) {
    for (size_t i = 0; i < N; ++i) {
        if (folded.find(rules[i].needle) != std::string::npos)
            return Vote{ rules[i].kind, rules[i].needle };
    }
    return Vote{};
}

} // namespace entity_classify_detail

// ---------------------------------------------------------------------------
// 多信号分类
// ---------------------------------------------------------------------------

struct PageClassification {
    PageKind kind = PageKind::Unknown;
    int score = 0;              // 命中的信号强度，>=2 才给出非 Unknown
    std::string signals;        // 可复核：如 "url:/album/|title:专辑|text:tracklist"
};

inline PageClassification classify_page(const std::string& url, const std::string& title,
                                        const std::string& text) {
    namespace d = entity_classify_detail;
    const std::string head = text.size() > 1200 ? text.substr(0, 1200) : text;
    const d::Vote vu = d::ec_vote(d::ec_fold(url), d::kUrlRules);
    const d::Vote vt = d::ec_vote(d::ec_fold(title), d::kTitleRules);
    const d::Vote vx = d::ec_vote(d::ec_fold(head), d::kTextRules);

    int votes[7] = { 0, 0, 0, 0, 0, 0, 0 };
    std::string sig;
    auto add = [&](const d::Vote& v, const char* src) {
        if (v.kind == PageKind::Unknown) return;
        votes[(int)v.kind]++;
        if (!sig.empty()) sig += "|";
        sig += std::string(src) + ":" + (v.needle ? v.needle : "");
    };
    add(vu, "url");
    add(vt, "title");
    add(vx, "text");

    PageClassification r;
    r.signals = sig;
    int best = 0;
    PageKind bestKind = PageKind::Unknown;
    for (int k = 1; k <= 6; ++k) {
        if (votes[k] > best) { best = votes[k]; bestKind = (PageKind)k; }
    }
    r.score = best;
    r.kind = (best >= 2) ? bestKind : PageKind::Unknown;
    return r;
}

// ---------------------------------------------------------------------------
// 兼容矩阵（宁缺毋错，不猜；Unknown 一律放行）
// ---------------------------------------------------------------------------

inline bool page_kind_compatible(EntityKind requested, PageKind page) {
    if (page == PageKind::Unknown) return true;
    switch (requested) {
        case EntityKind::Track:
        case EntityKind::Release:
        case EntityKind::Work:
        case EntityKind::Recording:
            return page == PageKind::Track || page == PageKind::Release;
        case EntityKind::Person:
        case EntityKind::Group:
            return page == PageKind::Person || page == PageKind::Group;
        case EntityKind::Label:
            return page == PageKind::Label;
        case EntityKind::Series:
            return page == PageKind::Series;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 归属证明
// ---------------------------------------------------------------------------

struct PageAttribution {
    bool belongs = false;
    PageKind kind = PageKind::Unknown;
    int score = 0;
    std::string reason;         // 拒绝原因（进 diag，不静默）
};

inline PageAttribution attribute_page(EntityKind requested,
                                      const std::string& name, const std::string& artist,
                                      const std::string& album,
                                      const std::string& url, const std::string& title,
                                      const std::string& text) {
    namespace d = entity_classify_detail;
    PageAttribution a;
    const PageClassification c = classify_page(url, title, text);
    a.kind = c.kind;
    a.score = c.score;

    // 1) 页面类型不兼容 -> 直接拒绝（跨实体页面）
    if (!page_kind_compatible(requested, c.kind)) {
        a.belongs = false;
        a.reason = std::string("跨实体页面: 类型") + page_kind_label(c.kind) +
                   " 与查询" + entity_kind_tag(requested) + " 不符";
        return a;
    }

    const std::string head = text.size() > 1200 ? text.substr(0, 1200) : text;
    const std::string hay = d::ec_norm(url + "\n" + title + "\n" + head);

    // 2) 名称证明
    const std::string nm = d::ec_norm(name);
    if (!d::ec_name_provable(nm)) {
        a.reason = "无法证明归属: 名称过短或为空";
        return a;
    }
    if (hay.find(nm) == std::string::npos) {
        a.reason = "无法证明归属: 缺少名称";
        return a;
    }

    // 3) 艺术家证据（Track/Release 额外要求）；4) Track + album 非空还要专辑证据
    if ((requested == EntityKind::Track || requested == EntityKind::Release) && !artist.empty()) {
        const std::string ar = d::ec_norm(artist);
        if (!d::ec_name_provable(ar) || hay.find(ar) == std::string::npos) {
            a.reason = "无法证明归属: 缺少艺术家";
            return a;
        }
    }
    if (requested == EntityKind::Track && !album.empty()) {
        const std::string al = d::ec_norm(album);
        if (!d::ec_name_provable(al) || hay.find(al) == std::string::npos) {
            a.reason = "无法证明归属: 缺少专辑";
            return a;
        }
    }

    a.belongs = true;
    a.reason.clear();
    return a;
}

} // namespace rta::meta
