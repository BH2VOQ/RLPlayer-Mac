// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_track_identity.cpp — 1.1.5-beta2 M-13：文件名兜底的身份解析（纯逻辑，无网络）
//
// 真实判据（替换 Lead 预置的必红骨架）：
//   * `01 - Aimer - 六等星の夜.flac` 必须解析出 artist/title（source=filename）
//   * 纯曲号 / 无意义名（03、01.、Track 01、unknown、untitled、未命名、audio、recording、
//     纯数字、单字符、全符号）全部 insufficient 且 reason 非空 —— 这是 0 次检索请求的入口
//   * tag 齐全 -> source=tag；tag 缺失但文件名可解析 -> source=filename
//   * filePath 空且 tag 不全 -> insufficient
//   * tag title 有、artist 无、文件名解析不出 artist -> sufficient（单曲名检索，旧行为）
// 判据见 PLAN-1.1.5-beta2.md §1.6。
#include "meta/track_identity.h"
#include "platform/console.h"

#include <cstdio>
#include <string>

using namespace rta::meta;

static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) std::printf("  [PASS] %s\n", what.c_str());
    else { std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); ++g_fail; }
}

int main() {
    rta::platform::enable_utf8_console();
    std::printf("== meta/track_identity.h 文件名兜底身份解析 ==\n");

    // ---------------- 1) 典型无标签文件名 ----------------
    std::printf("-- 1. 曲号 + 艺术家 + 曲名 --\n");
    {
        const TrackIdentity r = resolve_track_identity("", "", "",
            "/Users/august/Music/01 - Aimer - 六等星の夜.flac");
        ck(r.sufficient, "典型文件名 sufficient=true");
        ck(r.artist == "Aimer", "解析出 artist=Aimer", "artist='" + r.artist + "'");
        ck(r.title == "六等星の夜", "解析出 title=六等星の夜", "title='" + r.title + "'");
        ck(r.source == "filename", "source=filename", "source='" + r.source + "'");
        ck(r.reason.empty(), "sufficient 时 reason 为空");
    }

    // ---------------- 2) 纯曲号 / 无意义名全部 insufficient ----------------
    std::printf("-- 2. 纯曲号与无意义文件名（0 次检索的入口）--\n");
    {
        static const char* kBadStems[] = {
            "03", "01.", "Track 01", "unknown", "untitled", "未命名",
            "audio", "recording", "123456", "A", "---", "夜", "Track01",
        };
        const size_t n = sizeof(kBadStems) / sizeof(kBadStems[0]);
        int bad = 0;
        for (size_t i = 0; i < n; ++i) {
            const std::string path = std::string("/music/") + kBadStems[i] + ".flac";
            const TrackIdentity r = resolve_track_identity("", "", "", path);
            if (r.sufficient || r.source != "insufficient" || r.reason.empty() ||
                r.reason.find("资料不足") == std::string::npos) {
                ++bad;
                std::printf("  [FAIL] 无意义名 '%s' sufficient=%d source='%s' reason='%s'\n",
                            kBadStems[i], r.sufficient ? 1 : 0, r.source.c_str(), r.reason.c_str());
            }
        }
        ck(n >= 10 && bad == 0, "13 个纯曲号/无意义名全部 insufficient 且 reason 非空含「资料不足」",
           "n=" + std::to_string(n) + " bad=" + std::to_string(bad));
    }

    // ---------------- 3) tag 齐全优先 ----------------
    std::printf("-- 3. tag 齐全时 source=tag（文件名再脏也不覆盖）--\n");
    {
        const TrackIdentity r = resolve_track_identity("六等星の夜", "Aimer",
                                                       "Sleepless Nights", "/music/03.flac");
        ck(r.source == "tag", "source=tag", "source='" + r.source + "'");
        ck(r.sufficient && r.reason.empty(), "tag 齐全 sufficient=true");
        ck(r.title == "六等星の夜" && r.artist == "Aimer" && r.album == "Sleepless Nights",
           "tag 三字段原样透传",
           "title='" + r.title + "' artist='" + r.artist + "' album='" + r.album + "'");
    }

    // ---------------- 4) tag 缺失但文件名可解析 ----------------
    std::printf("-- 4. tag 缺 artist 时由文件名补齐 --\n");
    {
        const TrackIdentity r = resolve_track_identity("六等星の夜", "", "",
                                                       "/music/Aimer - 六等星の夜.flac");
        ck(r.source == "filename", "source=filename", "source='" + r.source + "'");
        ck(r.sufficient, "sufficient=true");
        ck(r.title == "六等星の夜" && r.artist == "Aimer",
           "tag 已有 title 优先，artist 从文件名补齐",
           "title='" + r.title + "' artist='" + r.artist + "'");
    }
    {
        const TrackIdentity r = resolve_track_identity("", "Aimer", "",
                                                       "/music/六等星の夜.flac");
        ck(r.source == "filename" && r.sufficient, "只有 artist tag 时由文件名补 title");
        ck(r.title == "六等星の夜" && r.artist == "Aimer",
           "title 来自文件名、artist 来自 tag",
           "title='" + r.title + "' artist='" + r.artist + "'");
    }

    // ---------------- 5) 单曲名检索（文件名解析不出 artist）----------------
    std::printf("-- 5. 单曲名检索（旧行为：只有 title 也 sufficient）--\n");
    {
        const TrackIdentity r = resolve_track_identity("", "", "", "/music/Loving Hannah.flac");
        ck(r.source == "filename" && r.sufficient, "文件名只有曲名时 sufficient=true");
        ck(r.title == "Loving Hannah" && r.artist.empty(),
           "title=Loving Hannah 且 artist 为空", "title='" + r.title + "' artist='" + r.artist + "'");
    }
    {
        const TrackIdentity r = resolve_track_identity("六等星の夜", "", "",
                                                       "/music/Loving Hannah.flac");
        ck(r.sufficient && r.title == "六等星の夜",
           "tag title 有、artist 无、文件名解析不出 artist -> 保留 tag title 且 sufficient",
           "title='" + r.title + "' artist='" + r.artist + "'");
    }

    // ---------------- 6) filePath 空且 tag 不全 ----------------
    std::printf("-- 6. filePath 空且 tag 不全 --\n");
    {
        const TrackIdentity r1 = resolve_track_identity("六等星の夜", "", "", "");
        ck(!r1.sufficient && r1.source == "insufficient" && !r1.reason.empty(),
           "有 title tag、无 artist、无 filePath -> insufficient");
        const TrackIdentity r2 = resolve_track_identity("", "", "", "");
        ck(!r2.sufficient && r2.source == "insufficient" && !r2.reason.empty(),
           "全空 tag、空 filePath -> insufficient");
        const TrackIdentity r3 = resolve_track_identity("", "Aimer", "", "");
        ck(!r3.sufficient && r3.source == "insufficient" && !r3.reason.empty(),
           "只有 artist tag、无 filePath -> insufficient");
    }

    std::printf("== track_identity %s ==\n", g_fail ? "RED/FAIL" : "GREEN/PASS");
    return g_fail ? 1 : 0;
}
