// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_entity_classify.cpp — 1.1.5-beta2 #21a/#21b：页面类型多信号分类 + 归属校验
//
// 真实判据（替换 Lead 预置的必红骨架）：
//   * 28 条分类夹具（person/group/label/series/track/release/unknown 混合 URL+标题+正文），错分率 0
//   * 兼容矩阵全表（8 EntityKind × 7 PageKind），逐格断言
//   * 归属证明：合法 6 例、跨实体/缺名/缺艺术家/缺专辑/短名 6 例全拒绝且 reason 非空
// 全部纯逻辑、无网络、无音频。判据见 PLAN-1.1.5-beta2.md §1.2。
#include "meta/entity_classify.h"
#include "platform/console.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace rta::meta;

static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) std::printf("  [PASS] %s\n", what.c_str());
    else { std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); ++g_fail; }
}

struct Fix {
    const char* url;
    const char* title;
    const char* text;
    PageKind want;
};

int main() {
    rta::platform::enable_utf8_console();
    std::printf("== meta/entity_classify.h 页面类型分类 / 归属证明 ==\n");

    // ---------------- 1) 分类夹具：≥20 条，错分率 0 ----------------
    std::printf("-- 1. 多信号分类（URL 路径 / 标题 / 正文，只看正文前 1200 字节）--\n");
    // 中性夹具：三个来源都不含任何分类关键词 -> 0 票 -> Unknown
    const char* kNeutralUrl = "https://example.com/page/42";
    const char* kNeutralTitle = "页面内容";
    const char* kNeutralText = "这是一段普通的说明文字，记录了一些背景信息。";

    static const Fix kFix[] = {
        // Person（4）
        { "https://musicbrainz.org/artist/123", "Aimer 歌手 简介", kNeutralText, PageKind::Person },
        { kNeutralUrl, "坂井泉水 生平", "出生于 1970 年，个人简介", PageKind::Person },
        { "https://zh.wikipedia.org/wiki/Aimer", "Aimer - 人物介绍", "born in 1990, biography", PageKind::Person },
        { "https://www.discogs.com/artist/Aimer", kNeutralTitle, "出生于日本，个人简介", PageKind::Person },
        // Group（4）
        { "https://example.com/band/zard", "ZARD 乐团 成员", kNeutralText, PageKind::Group },
        { kNeutralUrl, "乐队介绍", "formed in 1991, members include", PageKind::Group },
        { "https://example.com/group/123", kNeutralTitle, "成员名单 lineup", PageKind::Group },
        { kNeutralUrl, "组合 成员", "成员包括主唱", PageKind::Group },
        // Label（4）
        { "https://example.com/label/sme", "厂牌介绍", kNeutralText, PageKind::Label },
        { kNeutralUrl, "唱片公司", "旗下艺人众多，record label", PageKind::Label },
        { "https://example.com/labels/xyz", kNeutralTitle, "founded in 1990, signed artists", PageKind::Label },
        { kNeutralUrl, "Label 资料", "唱片公司 旗下艺人", PageKind::Label },
        // Series（4）
        { "https://example.com/series/arknights", "明日方舟 企划", kNeutralText, PageKind::Series },
        { kNeutralUrl, "系列作品", "franchise 原作 企划", PageKind::Series },
        { "https://example.com/project/msr", kNeutralTitle, "系列作品介绍", PageKind::Series },
        { kNeutralUrl, "企画 绍介", "series 作品", PageKind::Series },
        // Track（4）
        { "https://example.com/track/rokutousei", "六等星の夜 歌曲", kNeutralText, PageKind::Track },
        { kNeutralUrl, "单曲 歌词", "作词 作曲 编曲 Aimer", PageKind::Track },
        { "https://example.com/song/123", kNeutralTitle, "作词 作曲 演唱", PageKind::Track },
        { kNeutralUrl, "Song lyrics", "composed by Aimer, lyrics", PageKind::Track },
        // Release（4）
        { "https://example.com/album/sleepless-nights", "Sleepless Nights 专辑", kNeutralText, PageKind::Release },
        { kNeutralUrl, "专辑 曲目列表", "发行时间 2024, tracklist", PageKind::Release },
        { "https://www.discogs.com/release/123", kNeutralTitle, "収録曲 10 曲，专辑介绍", PageKind::Release },
        { kNeutralUrl, "Album release", "release date 2024, discography", PageKind::Release },
        // Unknown（4）
        { kNeutralUrl, kNeutralTitle, kNeutralText, PageKind::Unknown },
        { "https://news.example.com/2024/06/01/index.html", "最新消息", "今天发生了一些事情。", PageKind::Unknown },
        { "https://example.com/search?q=music", "搜索结果", "找到若干条目。", PageKind::Unknown },
        { "https://example.com/blog/post-1", "随笔", "随便写点东西，没有关键词。", PageKind::Unknown },
    };
    const size_t nFix = sizeof(kFix) / sizeof(kFix[0]);
    ck(nFix >= 20, "分类夹具数量 >= 20", "n=" + std::to_string(nFix));
    int mismatches = 0;
    for (size_t i = 0; i < nFix; ++i) {
        const Fix& f = kFix[i];
        const PageClassification c = classify_page(f.url, f.title, f.text);
        if (c.kind != f.want) {
            ++mismatches;
            std::printf("  [FAIL] 夹具#%zu 期望 %s 实得 %s (score=%d signals=%s)\n",
                        i, page_kind_tag(f.want), page_kind_tag(c.kind), c.score, c.signals.c_str());
        }
        if (f.want != PageKind::Unknown) {
            if (c.score < 2 || c.signals.empty()) {
                ++mismatches;
                std::printf("  [FAIL] 夹具#%zu 非 Unknown 但 score=%d signals='%s'\n",
                            i, c.score, c.signals.c_str());
            }
        } else if (c.score >= 2) {
            ++mismatches;
            std::printf("  [FAIL] 夹具#%zu Unknown 但 score=%d\n", i, c.score);
        }
    }
    ck(mismatches == 0, "28 条分类夹具错分率 0（含 score/signals 判据）",
       "mismatches=" + std::to_string(mismatches));

    // page_kind_tag / page_kind_from_tag 往返
    {
        int bad = 0;
        for (int v = 0; v <= 6; ++v) {
            const PageKind k = (PageKind)v;
            PageKind out = PageKind::Unknown;
            if (!page_kind_from_tag(page_kind_tag(k), out) || out != k) ++bad;
        }
        ck(bad == 0, "page_kind_tag / page_kind_from_tag 全 7 档往返一致", "bad=" + std::to_string(bad));
        PageKind dummy;
        ck(!page_kind_from_tag("nonsense", dummy), "非法 tag 拒绝");
    }

    // ---------------- 2) 兼容矩阵全表 ----------------
    std::printf("-- 2. page_kind_compatible 8×7 矩阵全表 --\n");
    {
        // 列顺序：Unknown, Track, Release, Person, Group, Label, Series
        const PageKind cols[7] = { PageKind::Unknown, PageKind::Track, PageKind::Release,
                                   PageKind::Person, PageKind::Group, PageKind::Label, PageKind::Series };
        const EntityKind rows[8] = { EntityKind::Person, EntityKind::Group, EntityKind::Label,
                                     EntityKind::Series, EntityKind::Work, EntityKind::Recording,
                                     EntityKind::Release, EntityKind::Track };
        // 独立写死的期望真值表（不是从生产逻辑抄来的）
        const bool want[8][7] = {
            /* Person    */ { 1, 0, 0, 1, 1, 0, 0 },
            /* Group     */ { 1, 0, 0, 1, 1, 0, 0 },
            /* Label     */ { 1, 0, 0, 0, 0, 1, 0 },
            /* Series    */ { 1, 0, 0, 0, 0, 0, 1 },
            /* Work      */ { 1, 1, 1, 0, 0, 0, 0 },
            /* Recording */ { 1, 1, 1, 0, 0, 0, 0 },
            /* Release   */ { 1, 1, 1, 0, 0, 0, 0 },
            /* Track     */ { 1, 1, 1, 0, 0, 0, 0 },
        };
        int bad = 0;
        for (int r = 0; r < 8; ++r) {
            for (int c = 0; c < 7; ++c) {
                const bool got = page_kind_compatible(rows[r], cols[c]);
                if (got != want[r][c]) {
                    ++bad;
                    std::printf("  [FAIL] 矩阵 [%s][%s] 期望 %d 实得 %d\n",
                                entity_kind_tag(rows[r]), page_kind_tag(cols[c]),
                                want[r][c] ? 1 : 0, got ? 1 : 0);
                }
            }
        }
        ck(bad == 0, "兼容矩阵 56 格逐格一致（宁缺毋错）", "bad=" + std::to_string(bad));
    }

    // ---------------- 3) 归属证明：合法 ≥5 例 ----------------
    std::printf("-- 3. attribute_page 合法归属（名称/艺术家/专辑证据）--\n");
    {
        const std::string name = "六等星の夜", artist = "Aimer", album = "Sleepless Nights";
        struct Good { EntityKind kind; const char* nm; const char* ar; const char* al;
                      const char* url; const char* title; const char* text; };
        static const Good kGood[] = {
            { EntityKind::Track, "六等星の夜", "Aimer", "Sleepless Nights",
              "https://example.com/track/六等星の夜", "六等星の夜 - Aimer 歌曲",
              "作词 作曲 编曲，所属专辑 Sleepless Nights" },
            { EntityKind::Track, "六等星の夜", "Aimer", "Sleepless Nights",
              "https://example.com/album/sleepless-nights", "Sleepless Nights 专辑 Aimer",
              "曲目列表：六等星の夜，发行时间 2024" },
            { EntityKind::Track, "六等星の夜", "Aimer", "Sleepless Nights",
              "https://example.com/page/42", "六等星の夜 Aimer Sleepless Nights 资料",
              "这是一段普通说明文字。" },
            { EntityKind::Track, "六等星の夜", "Aimer", "Sleepless Nights",
              "https://example.com/track/六等星の夜/", "六等星の夜 Aimer 歌曲",
              "作词 作曲 Sleepless Nights" },
            { EntityKind::Release, "Sleepless Nights", "Aimer", "",
              "https://www.discogs.com/release/123", "Sleepless Nights 专辑 Aimer",
              "曲目列表 六等星の夜" },
            { EntityKind::Person, "Aimer", "", "",
              "https://musicbrainz.org/artist/Aimer", "Aimer 歌手 简介", "出生于日本" },
        };
        const size_t nGood = sizeof(kGood) / sizeof(kGood[0]);
        int bad = 0;
        for (size_t i = 0; i < nGood; ++i) {
            const Good& g = kGood[i];
            const PageAttribution a = attribute_page(g.kind, g.nm, g.ar, g.al, g.url, g.title, g.text);
            if (!a.belongs || !a.reason.empty() ||
                (a.kind == PageKind::Unknown && a.score >= 2)) {
                ++bad;
                std::printf("  [FAIL] 合法#%zu belongs=%d kind=%s reason='%s'\n",
                            i, a.belongs ? 1 : 0, page_kind_tag(a.kind), a.reason.c_str());
            }
        }
        ck(nGood >= 5 && bad == 0, "归属合法 6 例全部通过（含 Unknown 页带证据 / 发行页 / 尾斜杠）",
           "n=" + std::to_string(nGood) + " bad=" + std::to_string(bad));
    }

    // ---------------- 4) 归属拒绝：跨实体 / 缺名 / 缺艺术家 / 缺专辑 / 短名 ----------------
    std::printf("-- 4. attribute_page 拒绝路径（reason 必须非空）--\n");
    {
        const std::string name = "六等星の夜", artist = "Aimer", album = "Sleepless Nights";
        struct Bad { const char* label; EntityKind kind; const char* nm; const char* ar; const char* al;
                     const char* url; const char* title; const char* text; const char* reasonPart; };
        static const Bad kBad[] = {
            { "跨实体(厂牌页查歌曲)", EntityKind::Track, "六等星の夜", "Aimer", "Sleepless Nights",
              "https://example.com/label/sme", "厂牌 唱片公司", "旗下艺人 六等星の夜 Aimer Sleepless Nights", "跨实体页面" },
            { "跨实体(系列页查人物)", EntityKind::Person, "Aimer", "", "",
              "https://example.com/series/ark", "企划 系列", "系列作品", "跨实体页面" },
            { "缺名称", EntityKind::Track, "六等星の夜", "Aimer", "Sleepless Nights",
              "https://example.com/track/other", "别的歌 歌曲", "作词 作曲 Aimer Sleepless Nights", "缺少名称" },
            { "缺艺术家", EntityKind::Track, "六等星の夜", "Aimer", "Sleepless Nights",
              "https://example.com/track/六等星の夜", "六等星の夜 歌曲", "作词 作曲 Sleepless Nights", "缺少艺术家" },
            { "缺专辑", EntityKind::Track, "六等星の夜", "Aimer", "Sleepless Nights",
              "https://example.com/track/六等星の夜", "六等星の夜 Aimer 歌曲", "作词 作曲", "缺少专辑" },
            { "名称过短", EntityKind::Track, "A", "Aimer", "Sleepless Nights",
              "https://example.com/track/a", "A Aimer 歌曲", "作词 作曲 Sleepless Nights", "名称过短" },
        };
        const size_t nBad = sizeof(kBad) / sizeof(kBad[0]);
        int bad = 0;
        for (size_t i = 0; i < nBad; ++i) {
            const Bad& b = kBad[i];
            const PageAttribution a = attribute_page(b.kind, b.nm, b.ar, b.al, b.url, b.title, b.text);
            if (a.belongs || a.reason.empty() ||
                std::string(a.reason).find(b.reasonPart) == std::string::npos) {
                ++bad;
                std::printf("  [FAIL] 拒绝#%zu (%s) belongs=%d reason='%s'\n",
                            i, b.label, a.belongs ? 1 : 0, a.reason.c_str());
            }
        }
        ck(nBad >= 3 && bad == 0, "跨实体/缺名/缺艺术家/缺专辑/短名 6 例全拒绝且 reason 含具体原因",
           "n=" + std::to_string(nBad) + " bad=" + std::to_string(bad));
    }

    std::printf("== entity_classify %s ==\n", g_fail ? "RED/FAIL" : "GREEN/PASS");
    return g_fail ? 1 : 0;
}
