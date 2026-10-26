// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_cover_fetch.cpp — 在线封面抓取的**纯逻辑**判据（2026-10-26，上游 c41ce97 + 9ce018f 的 mac 重做）
//
// 为什么这些判据必须单独存在（铁律 3：测「通过」≠ 测对了东西）：
//   上游把这 1044 行混在 rtaweb.cpp 里，判据只能靠"真库跑一遍看覆盖率 41.89%→77.36%"。
//   本机没有那份真库、也没有那份网易云响应 ⟹ 照抄数字 = 把"未验证"当"已完成"。
//   所以本轮把**判据本身**抽进 tools/cover_fetch.h，由本文件逐条否定：
//   每条都构造一个"看起来能过"的输入，再证明它**过不去**。
//
// 覆盖的判据（与任务书 1..10 的编号对应）：
//   [5] Dice 负向对照：《深空余音》vs《日落日出》必须拒绝（Dice=0）；
//       《Routine LP》vs《Funky Routine LP》艺术家不符时必须拒绝，艺术家相符才认。
//   [6] 落盘校验：200 的 HTML 错误页（<2048B 或非图片头）必须**不收**。
//   [7] 目录穿越：?k=..\..\windows\win.ini 不得逃出缓存目录。
//   [4] 负缓存过期：.none 的 mtime 改成 8 天前 ⟹ 必须视为过期（可重抓）。
//   [+] 正向对照（防止"全拒绝也算过"）：真同名、繁体/括号/词序差异、包含关系+艺术家 必须认。
//   [+] 两跳搜索词：term = "名 艺术家"；只有专辑名时 term = 名。
//
// 完全离线：不联网、不开设备、不写用户目录（临时目录全部自建在 temp_dir 下并清理）。
#include "test_compat_posix.h"
#include "cover_fetch.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;
namespace cov = rta::cover;

static int g_pass = 0, g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) { ++g_pass; std::printf("  [PASS] %s\n", what.c_str()); }
    else { ++g_fail; std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); }
}

// path -> UTF-8 窄串（mac 上 u8string() 是 char8_t，不能直接塞进 std::string）
static std::string u8s(const std::u8string& s) { return std::string((const char*)s.data(), s.size()); }
static std::string u8p(const fs::path& p) { return u8s(p.u8string()); }

// ---- 构造：网易 type=10 搜索响应（只保留 cover_pick_pic 用到的字段）----
// 为什么要自己拼而不是存一份真实响应：真实响应里有 id/picId/company 等十几个字段，
// 存进仓库既大又无法解释"这条判据到底在测哪个字段"。
static std::string albumJson(const std::string& name, const std::string& picUrl,
                             const std::string& artistName) {
    std::string s = "{\"name\":\"" + name + "\"";
    if (!picUrl.empty()) s += ",\"picUrl\":\"" + picUrl + "\"";
    if (!artistName.empty()) {
        s += ",\"artist\":{\"name\":\"" + artistName + "\"}";
        s += ",\"artists\":[{\"name\":\"" + artistName + "\"}]";
    }
    s += "}";
    return s;
}
static std::string searchJson(const std::vector<std::string>& albums) {
    std::string s = "{\"result\":{\"albums\":[";
    for (size_t i = 0; i < albums.size(); ++i) { if (i) s += ","; s += albums[i]; }
    s += "]}}";
    return s;
}

// 造一张「真的像图」的字节串：JPEG 文件头 + 填充到指定大小
static std::vector<unsigned char> fakeJpeg(size_t n) {
    std::vector<unsigned char> b(n, 0x00);
    b[0] = 0xFF; b[1] = 0xD8; b[2] = 0xFF; b[3] = 0xE0;
    return b;
}
static std::vector<unsigned char> fakePng(size_t n) {
    std::vector<unsigned char> b(n, 0x00);
    const unsigned char sig[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    for (int i = 0; i < 8; ++i) b[i] = sig[i];
    return b;
}

int main() {
    std::printf("== 在线封面抓取纯逻辑验证（目录穿越 / Dice / 图片头 / 负缓存过期）==\n");

    const std::string tmpRoot = rta::platform::temp_dir_utf8() + "rlplayer-cover-test";
    std::error_code ec;
    fs::remove_all(fs::u8path(tmpRoot), ec);
    fs::create_directories(fs::u8path(tmpRoot), ec);

    // ================= [7] 目录穿越（?k= 白名单）=================
    // 攻击面：GET /api/lib/cover?k=<任意串> 与 POST /api/lib/cover/set?k=<任意串> 都是公开入口。
    // 判据不是"输入里有没有 .."，而是**产出的路径必须仍在缓存目录之内**：
    // 换个分隔符（Windows 的 '\'）、用绝对路径、用 URL 编码都不许逃出去。
    {
        std::printf("\n[7] 目录穿越防护（?k= 白名单）\n");
        const std::vector<std::string> attacks = {
            "..\\..\\windows\\win.ini",
            "../../etc/passwd",
            "..%2f..%2fetc%2fpasswd",
            "/etc/passwd",
            "....//....//etc/passwd",
            "a/b/c",
            "d",                                  // 单个 hex 字符：上游记录的"写出 d.jpg"入口
        };
        for (const auto& k : attacks) {
            const cov::CoverPaths p = cov::cover_paths_in(tmpRoot, k);
            // ① 叶子必须是纯 [0-9a-f]{16} + ".jpg"（不含分隔符、不含点、不含 ..）
            const std::string leaf = u8p(fs::u8path(p.jpg).filename());
            bool leafOk = leaf.size() == 20 && leaf.substr(16) == ".jpg";
            for (size_t i = 0; i < 16 && leafOk; ++i) {
                const char c = leaf[i];
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) leafOk = false;
            }
            // ② 归一化后的路径必须以缓存目录为前缀（真正的穿越判据）
            const std::string norm = u8p(fs::u8path(p.jpg).lexically_normal());
            const bool inside = norm.rfind(tmpRoot + "/", 0) == 0;
            ck(leafOk && inside, "拒绝穿越：k=\"" + k + "\"",
               "leaf=" + leaf + " norm=" + norm);
        }
        // 负向对照：合法 16 位 hex 必须**原样保留**（不能把正常键也哈希掉，否则缓存永远不命中）
        const cov::CoverPaths good = cov::cover_paths_in(tmpRoot, "0123456789abcdef");
        ck(u8p(fs::u8path(good.jpg).filename()) == "0123456789abcdef.jpg",
           "合法 16 位 hex 键原样保留（不误伤）");
        // set 端点的严格校验：只接受 16 位 hex
        ck(cov::cover_key_is_strict_hex16("0123456789abcdef"), "set：16 位 hex 接受");
        ck(!cov::cover_key_is_strict_hex16("0123456789abcde"),  "set：15 位拒绝");
        ck(!cov::cover_key_is_strict_hex16("0123456789abcdef0"), "set：17 位拒绝");
        ck(!cov::cover_key_is_strict_hex16("d"), "set：单字符 'd' 拒绝（上游记录的 d.jpg 入口）");
        ck(!cov::cover_key_is_strict_hex16("..\\..\\windows\\win.ini"), "set：穿越串拒绝");
    }

    // ================= [5] Dice 名称比对负向对照 =================
    {
        std::printf("\n[5] Dice 判据负向对照\n");
        const auto kDeep = cov::cover_name_key("深空余音");
        const auto kSun  = cov::cover_name_key("日落日出");
        ck(cov::cover_dice(kDeep, kSun) == 0.0,
           "《深空余音》vs《日落日出》Dice = 0",
           "实际 " + std::to_string(cov::cover_dice(kDeep, kSun)));
        // 关键：网易上「深空余音」唯一沾边的就是「日落日出」。必须**一个都不选**。
        const std::string js1 = searchJson({ albumJson("日落日出", "http://x/p.jpg", "某某") });
        ck(cov::cover_pick_pic(js1, "深空余音", "某某").empty(),
           "《深空余音》在网易只有《日落日出》⟹ 必须返回空（不落盘错图）",
           "实际=" + cov::cover_pick_pic(js1, "深空余音", "某某"));

        // Routine LP vs Funky Routine LP：Dice = 0.75（<0.90），艺术家不符必须拒绝
        const auto kRoutine = cov::cover_name_key("Routine LP");
        const auto kFunky   = cov::cover_name_key("Funky Routine LP");
        const double dRF = cov::cover_dice(kRoutine, kFunky);
        ck(dRF > 0.72 && dRF < 0.90, "《Routine LP》vs《Funky Routine LP》Dice 落在 0.72~0.90 灰区",
           "实际 " + std::to_string(dRF));
        const std::string js2 = searchJson({ albumJson("Funky Routine LP", "http://x/r.jpg", "Legal") });
        ck(cov::cover_pick_pic(js2, "Routine LP", "Kos.Mos.Music").empty(),
           "灰区 + 艺术家不符 ⟹ 必须拒绝",
           "实际=" + cov::cover_pick_pic(js2, "Routine LP", "Kos.Mos.Music"));
        // 正向对照：艺术家相符才认（否则上面的"拒绝"可能只是判据写死返回空）
        ck(!cov::cover_pick_pic(js2, "Routine LP", "Legal").empty(),
           "灰区 + 艺术家相符 ⟹ 必须接受（证明上一条不是恒空）");

        // ---- 正向对照：规范化确实把"同一张碟的不同写法"放进来 ----
        const std::string js3 = searchJson({
            albumJson("RESOLVERS 1st 幻梦拟声", "http://x/a.jpg", "RESOLVERS"),
        });
        ck(!cov::cover_pick_pic(js3, "RESOLVERS 1st \"幻梦拟声\"", "RESOLVERS").empty(),
           "引号差异 ⟹ 仍认（引号被规范化丢弃）");
        const std::string js4 = searchJson({
            albumJson("熏风", "http://x/b.jpg", "社团"),
        });
        ck(!cov::cover_pick_pic(js4, "熏风（Dizzymart Special Release）", "社团").empty(),
           "括号后缀差异 ⟹ 仍认（括号内容不参与比对）");
        const std::string js5 = searchJson({
            albumJson("春秋歷命序", "http://x/c.jpg", "社团"),
        });
        // 繁体/异体字不同码点 ⟹ Dice 会低于 1；这里只要"不为 0 且过 0.72 线"就是被接受了
        ck(!cov::cover_pick_pic(js5, "春秋历命序", "社团").empty(),
           "繁体/异体字差异 ⟹ 仍认（字符多重集 Dice 容得下）");
        // 包含关系单独放行：名字被加了前后缀
        const std::string js6 = searchJson({
            albumJson("遠景Landscape -Touhou Mellow Beats-", "http://x/d.jpg", "社团"),
        });
        ck(!cov::cover_pick_pic(js6, "遠景Landscape", "社团").empty(),
           "名字被加前后缀（包含关系 + 艺术家相符）⟹ 认");
        ck(cov::cover_pick_pic(js6, "遠景Landscape", "完全无关的艺术家").empty(),
           "包含关系但艺术家不符 ⟹ 拒绝");

        // 空输入不许崩、不许"随便给一张"
        ck(cov::cover_pick_pic("", "任意", "任意").empty(), "空响应 ⟹ 返回空（不崩）");
        ck(cov::cover_pick_pic(searchJson({}), "任意", "任意").empty(), "空 albums ⟹ 返回空");
        ck(cov::cover_pick_pic(searchJson({ albumJson("同名专辑", "", "艺术家") }), "同名专辑", "艺术家").empty(),
           "picUrl 为空 ⟹ 跳过");
    }

    // ================= [6] 落盘校验：错误页必须不收 =================
    {
        std::printf("\n[6] 落盘校验（≥2048B 且 JPEG/PNG/WEBP 文件头）\n");
        // ① 典型场景：服务器 200 返回一个 HTML 错误页（比如防盗链页），体积不小但根本不是图
        std::string html = "<!DOCTYPE html><html><head><title>403 Forbidden</title></head><body>";
        while (html.size() < 4096) html += "<p>Access denied by CDN</p>";
        const std::vector<unsigned char> htmlBytes(html.begin(), html.end());
        ck(!cov::cover_accept_bytes(htmlBytes),
           "200 的 HTML 错误页（4KB）必须**不收**", "size=" + std::to_string(htmlBytes.size()));
        // ② 小于 2048B 的真图也必须不收（上游口径：小于它当"没有封面"）
        ck(!cov::cover_accept_bytes(fakeJpeg(1024)), "1024B 的真 JPEG 头也必须拒（< 2048B）");
        ck(cov::cover_accept_bytes(fakeJpeg(2048)),  "2048B 的 JPEG 头接受（边界值）");
        ck(cov::cover_accept_bytes(fakePng(3000)),   "3000B 的 PNG 头接受");
        // ③ 超上限（24MB）
        ck(!cov::cover_accept_bytes(fakeJpeg((size_t)cov::kCoverMaxBytes + 1)),
           "超过 24MB 必须拒");
        // ④ 空 body
        ck(!cov::cover_accept_bytes({}), "空 body 必须拒");
        // ⑤ MIME 按文件头给（人工设置的封面可能是 PNG/WEBP/GIF）
        ck(std::string(cov::cover_mime_of(fakePng(3000))) == "image/png", "PNG ⟹ image/png");
        ck(std::string(cov::cover_mime_of(fakeJpeg(3000))) == "image/jpeg", "JPEG ⟹ image/jpeg");
        std::vector<unsigned char> webp(20, 0);
        webp[0] = 'R'; webp[1] = 'I'; webp[2] = 'F'; webp[3] = 'F';
        webp[8] = 'W'; webp[9] = 'E'; webp[10] = 'B'; webp[11] = 'P';
        ck(std::string(cov::cover_mime_of(webp)) == "image/webp", "WEBP ⟹ image/webp");
    }

    // ================= [4] 负缓存过期（7 天）=================
    {
        std::printf("\n[4] 负缓存过期（.none mtime 8 天前 ⟹ 视为过期可重抓）\n");
        const std::string key = "0011223344556677";
        const cov::CoverPaths p = cov::cover_paths_in(tmpRoot, key);
        fs::create_directories(fs::u8path(p.dir), ec);
        // 刚写的 .none ⟹ 新鲜
        { std::ofstream f(fs::u8path(p.none), std::ios::binary | std::ios::trunc); }
        ck(fs::exists(fs::u8path(p.none)), ".none 已创建");
        ck(cov::cover_neg_fresh_in(tmpRoot, key), "刚写的 .none ⟹ 新鲜（会跳过抓取）");
        // 把 mtime 改成 8 天前
        const auto eightDaysAgo = fs::file_time_type::clock::now() - std::chrono::hours(24 * 8);
        fs::last_write_time(fs::u8path(p.none), eightDaysAgo, ec);
        ck(!ec, "mtime 改写成功", ec ? ec.message() : "");
        ck(!cov::cover_neg_fresh_in(tmpRoot, key), "8 天前的 .none ⟹ 过期（可重抓）");
        // 边界：6 天前仍然新鲜
        const auto sixDaysAgo = fs::file_time_type::clock::now() - std::chrono::hours(24 * 6);
        fs::last_write_time(fs::u8path(p.none), sixDaysAgo, ec);
        ck(cov::cover_neg_fresh_in(tmpRoot, key), "6 天前的 .none ⟹ 仍新鲜（不误判过期）");
        // 不存在的 .none ⟹ 不算新鲜（否则永远不抓）
        ck(!cov::cover_neg_fresh_in(tmpRoot, "ffffffffffffffff"), "不存在的 .none ⟹ 不新鲜");
        // 有正缓存时 has_disk 为真、读得回字节
        {
            const auto jpg = fakeJpeg(3000);
            std::ofstream f(fs::u8path(p.jpg), std::ios::binary | std::ios::trunc);
            f.write(reinterpret_cast<const char*>(jpg.data()), (std::streamsize)jpg.size());
        }
        ck(cov::cover_has_disk_in(tmpRoot, key), "正缓存存在 ⟹ has_disk 真");
        std::vector<unsigned char> got;
        ck(cov::cover_read_cached_in(tmpRoot, key, got) && got.size() == 3000,
           "正缓存读回 3000B", "实际 " + std::to_string(got.size()));
        // 超大文件不读（防 24MB 上限失效时把内存打爆）
        {
            std::ofstream f(fs::u8path(p.jpg), std::ios::binary | std::ios::trunc);
            const std::vector<unsigned char> big((size_t)cov::kCoverMaxBytes + 16, 0xFF);
            f.write(reinterpret_cast<const char*>(big.data()), (std::streamsize)big.size());
        }
        ck(!cov::cover_has_disk_in(tmpRoot, key), "超过 24MB 的正缓存 ⟹ has_disk 假（与读侧同一口径）");
        std::vector<unsigned char> got2;
        ck(!cov::cover_read_cached_in(tmpRoot, key, got2), "超过 24MB ⟹ 读侧也拒绝");
        // 空键：任何一条都不许把缓存目录当文件去 stat
        ck(!cov::cover_has_disk_in(tmpRoot, ""), "空键 ⟹ has_disk 假");
        ck(!cov::cover_neg_fresh_in(tmpRoot, ""), "空键 ⟹ neg_fresh 假");
    }

    // ================= 两跳搜索词 / 百分号编码 / 键解析 =================
    {
        std::printf("\n[+] 搜索词与查询串编码\n");
        ck(cov::cover_term_of("专辑", "艺术家") == "专辑 艺术家", "term = 名 + 空格 + 艺术家");
        ck(cov::cover_term_of("专辑", "") == "专辑", "无艺术家时 term 只有名");
        ck(cov::cover_term_of("", "") == "", "两者皆空 ⟹ 空 term（调用方据此判空）");
        // 百分号编码必须编 & = + % 空格（platform::percent_encode_path 不编这几个）
        ck(cov::cover_pct_encode("AC/DC & Friends") == "AC%2FDC%20%26%20Friends",
           "编码 & / 空格", cov::cover_pct_encode("AC/DC & Friends"));
        ck(cov::cover_pct_encode("100%") == "100%25", "编码 %");
        ck(cov::cover_pct_encode("a+b") == "a%2Bb", "编码 +");
        ck(cov::cover_pct_encode("中文") == "%E4%B8%AD%E6%96%87", "UTF-8 中文逐字节编码");
        // 键列表解析
        const auto ks = cov::cover_parse_keys(" aaa , bbb;\nccc | ddd ");
        ck(ks.size() == 4 && ks[0] == "aaa" && ks[3] == "ddd",
           "键列表支持 , ; | 换行 与首尾空白", "size=" + std::to_string(ks.size()));
        ck(cov::cover_parse_keys("").empty(), "空串 ⟹ 空列表（= 全库预热）");
        ck(cov::cover_parse_keys(" , , ; ").empty(), "全分隔符 ⟹ 空列表");
    }

    fs::remove_all(fs::u8path(tmpRoot), ec);

    std::printf("\n== 结果：%d passed, %d failed ==\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
