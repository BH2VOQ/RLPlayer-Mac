// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_provider_order.cpp — 数据源顺序（用户可排序）纯离线单测
//
// 判据说明（铁律 3：测试通过 ≠ 测对了东西）：
//   本文件只测 src/meta/provider.h 末尾那组纯函数（pv_default_order / pv_parse_order /
//   pv_order_join / pv_ordered）与 artwork.h 由它派生的 art_*_sources —— 全是内存里的
//   字符串与指针运算，**零网络、零文件、零时钟**，所以不可能「假绿」也不会打扰用户。
//   ⚠️ 网络路径（真去 QQ/网易/lrclib 取词）不在这里测，也不伪造：它由真机实测负责。
//
// 三条硬判据（默认行为等价）：
//   ① 默认顺序的搜索链**成员** = {dizzylab, qq, netease, itunes}（canSearch 过滤后）；
//      次序是 dizzylab→netease→qq→itunes —— qq/netease 对调，这是 pv_default_order() 里
//      写明的取舍（搜索结果按 match_score_all 统一排序，源先后只影响同分先后与调用先后）
//   ② 默认顺序的歌词链 = lrclib→netease→qq（canLyric 过滤后）—— 与改造前的
//      「注册表逆序」结果逐项相同，这条一旦变红就说明默认行为被改坏了；
//   ③ 用户自定义顺序真的生效（歌词链 lrclib→qq→netease 可被排出来）。
//
// ⚠️ 注册表当前是 **6 项**（dizzylab / qq / netease / itunes / lrclib / discogs）。
//   discogs 于 2026-10-27 补进能力矩阵，能力位 = Cover/ArtistImage/ArtistBio/ArtistLink/
//   TrackMeta，**没有 Search、没有 Lyrics**，且匿名限频约 25 req/min ⟹ 它天然只出现在
//   封面/头像/简介链且排在最后。所以本文件一律断言「长度 == provider_registry().size()」
//   与「前 5 项 == 默认顺序」，而不是写死 5 或 6 —— 将来再加源时这些断言仍然成立。
#include "meta/artwork.h"      // art_sources_with / art_lyric_sources（顺序驱动的派生入口）
#include "meta/enrich.h"       // EnrichOpts::order（搜索链/歌词链读的那个字段）
#include "meta/provider.h"     // pv_default_order / pv_parse_order / pv_order_join / pv_ordered
#include <algorithm>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

using namespace rta::meta;

static int g_pass = 0;
static int g_fail = 0;

static void ck(bool cond, const std::string& what, const std::string& detail = std::string()) {
    if (cond) {
        std::printf("  [PASS] %s\n", what.c_str());
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str());
        ++g_fail;
    }
}

static void ck_ids(const std::vector<std::string>& got, const std::vector<std::string>& want,
                   const std::string& what) {
    ck(got == want, what, "got=[" + pv_order_join(got) + "] want=[" + pv_order_join(want) + "]");
}

// 指针数组 → id 串（指针链的断言都先转成这个再看，失败时人能读懂）
static std::vector<std::string> ids_of(const std::vector<const ProviderDesc*>& v) {
    std::vector<std::string> out;
    out.reserve(v.size());
    for (const ProviderDesc* pd : v) out.push_back(pd ? pd->id : std::string("<null>"));
    return out;
}

// 按注册表**原序**挑出满足谓词的 id —— 这是改造前两条链的行为基线（搜索正序 / 歌词逆序
// 在下面各自单独构造），用来证明「默认顺序 == 旧的硬编码行为」。
static std::vector<std::string> reg_filter(bool (*pred)(const ProviderDesc&), bool reverse) {
    std::vector<std::string> out;
    const std::vector<ProviderDesc>& reg = provider_registry();
    if (reverse) {
        for (auto it = reg.rbegin(); it != reg.rend(); ++it)
            if (pred(*it)) out.push_back(it->id);
    } else {
        for (const ProviderDesc& pd : reg)
            if (pred(pd)) out.push_back(pd.id);
    }
    return out;
}

// 排序副本：只用于「集合相同」这类与次序无关的断言（次序另有断言，不会互相掩盖）
static std::vector<std::string> sorted(std::vector<std::string> v) {
    std::sort(v.begin(), v.end());
    return v;
}

static bool is_search(const ProviderDesc& pd) { return pd.canSearch; }
static bool is_lyric(const ProviderDesc& pd) { return pd.canLyric; }

int main() {
    std::printf("== meta/provider.h 数据源顺序（用户可排序，离线单测）==\n");
    const size_t n = provider_registry().size();
    std::printf("   注册表项数 = %zu\n", n);

    // ---------------------------------------------------------------
    std::printf("-- 1) 默认顺序 --\n");
    {
        const std::vector<std::string> def = pv_default_order();
        ck_ids(def, { "dizzylab", "lrclib", "netease", "qq", "itunes" },
               "pv_default_order() = dizzylab,lrclib,netease,qq,itunes（刻意选的，别乱改）");

        // 空 csv → 默认顺序（+ 默认顺序里没列出的注册表兜底项，当前就是 discogs）
        const std::vector<std::string> empty = pv_parse_order("");
        ck(empty.size() == n, "空 csv → 长度 == 注册表项数",
           "got=" + std::to_string(empty.size()) + " want=" + std::to_string(n));
        const std::vector<std::string> prefix(empty.begin(),
                                              empty.begin() + (empty.size() < def.size() ? empty.size() : def.size()));
        ck_ids(prefix, def, "空 csv → 前 5 项正是默认顺序 dizzylab,lrclib,netease,qq,itunes");
        ck(empty.size() >= def.size() && std::vector<std::string>(empty.begin(), empty.begin() + 5) == def,
           "空 csv → 前 5 项逐项相等（显式 vector 比较）");
    }

    // ---------------------------------------------------------------
    std::printf("-- 2) 只写一个源：其余按默认顺序补齐 --\n");
    {
        const std::vector<std::string> qq = pv_parse_order("qq");
        ck(!qq.empty() && qq[0] == "qq", "\"qq\" → qq 排第一", pv_order_join(qq));
        ck(qq.size() == n, "\"qq\" → 长度仍是注册表项数（其余源被补回来，不是只剩一个）",
           "got=" + std::to_string(qq.size()) + " want=" + std::to_string(n));
        ck_ids(qq, { "qq", "dizzylab", "lrclib", "netease", "itunes", "discogs" },
               "\"qq\" → qq 之后按默认顺序补 dizzylab,lrclib,netease,itunes，discogs 兜底在尾");
    }

    // ---------------------------------------------------------------
    std::printf("-- 3) 大小写 / 空格 / 重复 / 尾逗号 --\n");
    {
        const std::vector<std::string> v = pv_parse_order("QQ, netease,qq,");
        ck_ids(v, { "qq", "netease", "dizzylab", "lrclib", "itunes", "discogs" },
               "\"QQ, netease,qq,\" → qq,netease + 默认顺序补齐（大写归一/去空格/去重保序/尾巴空项忽略）");
        ck(v.size() == n, "去重后长度仍 == 注册表项数（重复项没有撑大数组）",
           "got=" + std::to_string(v.size()));
    }

    // ---------------------------------------------------------------
    std::printf("-- 4) 未知 id 被丢弃 --\n");
    {
        const std::vector<std::string> v = pv_parse_order("spotify,qq");
        ck(!v.empty() && v[0] == "qq", "\"spotify,qq\" → spotify 被丢弃，qq 第一", pv_order_join(v));
        bool hasSpotify = false;
        for (const std::string& id : v) if (id == "spotify") hasSpotify = true;
        ck(!hasSpotify, "结果里不存在 spotify（未知 id 不进链）");
        ck(v.size() == n, "\"spotify,qq\" → 长度 == 注册表项数", "got=" + std::to_string(v.size()));
    }

    // ---------------------------------------------------------------
    std::printf("-- 5) 全是垃圾 → 默认顺序 --\n");
    {
        const std::vector<std::string> v = pv_parse_order("???,");
        const std::vector<std::string> def = pv_default_order();
        ck(v.size() >= def.size() && std::vector<std::string>(v.begin(), v.begin() + 5) == def,
           "\"???, \" → 前 5 项回到默认顺序", pv_order_join(v));
        ck(v.size() == n, "\"???,\" → 长度 == 注册表项数", "got=" + std::to_string(v.size()));
        ck(pv_parse_order("") == v, "空串与全垃圾等价（都退回默认顺序）");
    }

    // ---------------------------------------------------------------
    std::printf("-- 6) pv_ordered()：长度与指针归属 --\n");
    {
        const std::vector<const ProviderDesc*> v = pv_ordered("");
        ck(v.size() == provider_registry().size(), "pv_ordered(\"\") 长度 == provider_registry().size()",
           "got=" + std::to_string(v.size()) + " want=" + std::to_string(provider_registry().size()));
        bool allInReg = true, anyNull = false, allUnique = true;
        std::vector<const ProviderDesc*> seen;
        for (const ProviderDesc* pd : v) {
            if (!pd) { anyNull = true; allInReg = false; continue; }
            bool found = false;
            for (const ProviderDesc& r : provider_registry()) if (&r == pd) found = true;   // 指针相等
            if (!found) allInReg = false;
            for (const ProviderDesc* s : seen) if (s == pd) allUnique = false;
            seen.push_back(pd);
        }
        ck(!anyNull, "pv_ordered 不含空指针");
        ck(allInReg, "每一项都指向 provider_registry() 内部元素（指针相等，不是拷贝/野指针）");
        ck(allUnique, "每个源恰好出现一次（无重复）");
        ck_ids(ids_of(v), pv_parse_order(""), "pv_ordered(\"\") 顺序 == pv_parse_order(\"\")");
    }

    // ---------------------------------------------------------------
    std::printf("-- 7) 默认顺序下「默认行为不变」两条硬判据 --\n");
    {
        std::vector<std::string> searchNow, lyricNow;
        for (const ProviderDesc* pd : pv_ordered("")) {
            if (pd->canSearch) searchNow.push_back(pd->id);
            if (pd->canLyric)  lyricNow.push_back(pd->id);
        }
        // 歌词链：与改造前（注册表逆序 + canLyric）**逐项**相同 —— 这条是硬判据，红了就是默认行为被改坏
        ck_ids(lyricNow, { "lrclib", "netease", "qq" },
               "歌词链（canLyric 过滤）= lrclib,netease,qq（与改造前逆序结果逐项相同）");
        ck_ids(lyricNow, reg_filter(is_lyric, true),
               "歌词链 == 旧实现（注册表逆序 + canLyric）");
        // 搜索链：**成员**与改造前相同（判据写的就是集合 {dizzylab,qq,netease,itunes}），
        // 但次序按默认顺序变成 qq/netease 对调 —— 这是 pv_default_order() 注释里写明的取舍：
        // 搜索结果收齐后按 match_score_all 统一排序，源的先后只影响同分先后与调用先后。
        ck_ids(sorted(searchNow), sorted({ "dizzylab", "qq", "netease", "itunes" }),
               "搜索链成员 == {dizzylab,qq,netease,itunes}（与改造前同一集合，一个不漏一个不多）");
        ck_ids(searchNow, { "dizzylab", "netease", "qq", "itunes" },
               "搜索链次序 = dizzylab,netease,qq,itunes（默认顺序下 qq/netease 对调，刻意取舍）");
        ck_ids(sorted(searchNow), sorted(reg_filter(is_search, false)),
               "搜索链成员 == 旧实现（注册表正序 + canSearch）的成员");
    }

    // ---------------------------------------------------------------
    std::printf("-- 8) 自定义顺序真的生效 --\n");
    {
        const std::string csv = "lrclib,qq,dizzylab,netease,itunes";
        std::vector<std::string> lyricCustom;
        for (const ProviderDesc* pd : pv_ordered(csv))
            if (pd->canLyric) lyricCustom.push_back(pd->id);
        ck_ids(lyricCustom, { "lrclib", "qq", "netease" },
               "自定义 order → 歌词链变 lrclib,qq,netease（证明顺序真的驱动调用）");
        std::vector<std::string> searchCustom;
        for (const ProviderDesc* pd : pv_ordered(csv))
            if (pd->canSearch) searchCustom.push_back(pd->id);
        ck_ids(searchCustom, { "qq", "dizzylab", "netease", "itunes" },
               "同一条 order → 搜索链跟着变成 qq,dizzylab,netease,itunes");
    }

    // ---------------------------------------------------------------
    std::printf("-- 9) 往返：pv_order_join(pv_parse_order(x)) --\n");
    {
        const std::string out = pv_order_join(pv_parse_order("qq"));
        ck(out == "qq,dizzylab,lrclib,netease,itunes,discogs",
           "join(parse(\"qq\")) 往返一致", "got=[" + out + "]");
        ck(pv_order_join(pv_parse_order(out)) == out, "已规范化的串再走一遍 parse+join 不变（幂等）",
           "got=[" + pv_order_join(pv_parse_order(out)) + "]");
        ck(pv_order_join(pv_parse_order("")) == "dizzylab,lrclib,netease,qq,itunes,discogs",
           "空串 parse+join == 默认顺序的规范串", pv_order_join(pv_parse_order("")));
        ck(pv_order_join({}).empty(), "空数组 → 空串");
    }

    // ---------------------------------------------------------------
    std::printf("-- 10) artwork.h 派生入口跟着同一条顺序（顺序唯一事实源）--\n");
    {
        const std::map<std::string, bool> allOn;   // 空 map = 全部源都开（与 EnrichOpts 同语义）
        const std::string custom = "lrclib,qq,dizzylab,netease,itunes";
        ck_ids(ids_of(art_lyric_sources(allOn)), { "lrclib", "netease", "qq" },
               "art_lyric_sources(默认) = lrclib,netease,qq（不再是靠 reverse 凑出来的）");
        ck_ids(ids_of(art_lyric_sources(allOn, custom)), { "lrclib", "qq", "netease" },
               "art_lyric_sources(自定义 order) 跟着用户顺序走");
        ck_ids(ids_of(art_artist_sources(allOn)), { "dizzylab", "netease", "qq", "discogs" },
               "art_artist_sources(默认) = dizzylab,netease,qq,discogs（discogs 无头像之外的链尾）");
        ck_ids(ids_of(art_cover_sources(allOn)), { "dizzylab", "netease", "qq", "itunes", "discogs" },
               "art_cover_sources(默认) = dizzylab,netease,qq,itunes,discogs");
        // 源开关仍然生效（关掉 qq 后它不在链里）
        std::map<std::string, bool> off;
        off["qq"] = false;
        ck_ids(ids_of(art_lyric_sources(off)), { "lrclib", "netease" },
               "srcOn[qq]=false → 歌词链里没有 qq（开关语义未被改坏）");
    }

    // ---------------------------------------------------------------
    std::printf("-- 11) 两个 opts 结构的 order 字段可用 --\n");
    {
        EnrichOpts eo;
        eo.order = "qq,netease";
        ck(eo.order == "qq,netease", "EnrichOpts.order 存在且原样保存（搜索链/歌词链读它）");
        ck(EnrichOpts().order.empty(), "EnrichOpts.order 缺省为空 ⟹ 默认顺序（调用方零改动）");
        ArtworkOpts ao;
        ao.order = "dizzylab,qq";
        ck(ao.order == "dizzylab,qq", "ArtworkOpts.order 存在且原样保存（封面/头像/简介链读它）");
        ck(ArtworkOpts().order.empty(), "ArtworkOpts.order 缺省为空 ⟹ 默认顺序");
    }

    std::printf("\nRESULT: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail > 0 ? 1 : 0;
}
