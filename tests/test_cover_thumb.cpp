// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_cover_thumb.cpp — 封面缩略图（ImageIO 编码）与缩略图磁盘缓存（beta9 封面性能）
//
// 背景：网格卡片原来直接发全尺寸内嵌封面（538 张缓存，均值 1.1 MB / p90 2.5 MB /
// 最大 19.6 MB），且每个 /api/lib/cover 请求要跨 SMB stat 最多 6 个音频文件。缩略图
// 通路必须做到「<=512px JPEG + 本地磁盘缓存 + 源文件印章失效」，本用例把这条通路
// 的每个判据单独钉住（每条都能被单独否定，不是"跑起来就算过"）。
//
// 判据：
//   [A] 800x600 BMP -> make_thumb() -> JPEG（FF D8 FF），SOF 尺寸 == 512x384，比源小
//   [B] 40x40 BMP -> 缩略图仍 40x40（永不放大）
//   [C] 垃圾字节 / 0 字节 / 截断 JPEG 头 -> false 且输出清空（不崩溃）
//   [D] source_stamp：缺失/目录 -> false；普通文件 -> true；文件改写后 token 变化
//   [E] write_thumb/read_thumb 往返逐字节相等；错误 token / 非法 key / 截断 .jpg /
//       篡改 .jpg（size 不变，只能靠 hash 发现）/ 篡改 meta 版本 -> 一律 false
//   [F] RLPLAYER_STATE_DIR 在 main() 第一件事就指向全新临时目录（先清掉 RLPLAYER_COVER_DIR，
//       否则它会绕过 STATE_DIR 指到真实用户缓存）；结束清理临时目录
//
// 夹具全部运行时生成（手写 24-bit BMP + 手写 SOF0/SOF2 扫描器），不往仓库塞二进制。
// 依赖：macOS 系统 ImageIO（BMP 解码 + JPEG 编码），不存在"依赖缺失"的正常情况，
// 因此本用例没有 SKIP 分支 —— 失败就是失败。
#include "net/local_cover_cache.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <unistd.h>

namespace fs = std::filesystem;
namespace lc = rta::net::local_cover;

static int g_pass = 0, g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) { ++g_pass; std::printf("  [PASS] %s\n", what.c_str()); }
    else { ++g_fail; std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); }
}

static std::string U8(const fs::path& p) {
    const auto u = p.u8string();
    return std::string((const char*)u.data(), u.size());
}
static bool writeFile(const fs::path& p, const std::vector<unsigned char>& b) {
    std::error_code ec;
    fs::create_directories(p.parent_path(), ec);
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    f.write((const char*)b.data(), (std::streamsize)b.size());
    f.close();
    return (bool)f;
}
static std::vector<unsigned char> readFile(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    return std::vector<unsigned char>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// ---------------------------------------------------------------------------
// 夹具：手写 24-bit BMP（BITMAPFILEHEADER 14 B + BITMAPINFOHEADER 40 B + BGR 像素）
// 造真图而不是塞假字节：ImageIO 必须真解码它，这条通路才有验证价值。
// ---------------------------------------------------------------------------
static void put16le(std::vector<unsigned char>& v, uint32_t x) {
    v.push_back((unsigned char)(x & 0xFF));
    v.push_back((unsigned char)((x >> 8) & 0xFF));
}
static void put32le(std::vector<unsigned char>& v, uint32_t x) {
    put16le(v, x & 0xFFFF);
    put16le(v, x >> 16);
}
static std::vector<unsigned char> makeBmp(int w, int h) {
    const int stride = (w * 3 + 3) & ~3;                 // 每行按 4 字节对齐
    const size_t pixels = (size_t)stride * (size_t)h;
    std::vector<unsigned char> out;
    out.reserve(54 + pixels);
    // BITMAPFILEHEADER
    out.push_back('B'); out.push_back('M');
    put32le(out, (uint32_t)(54 + pixels));               // bfSize
    put16le(out, 0); put16le(out, 0);                    // bfReserved1/2
    put32le(out, 54);                                    // bfOffBits
    // BITMAPINFOHEADER
    put32le(out, 40);                                    // biSize
    put32le(out, (uint32_t)w);                           // biWidth
    put32le(out, (uint32_t)h);                           // biHeight（正 = bottom-up）
    put16le(out, 1);                                     // biPlanes
    put16le(out, 24);                                    // biBitCount
    put32le(out, 0);                                     // biCompression = BI_RGB
    put32le(out, (uint32_t)pixels);                      // biSizeImage
    put32le(out, 2835); put32le(out, 2835);              // 72 DPI
    put32le(out, 0); put32le(out, 0);                    // biClrUsed / biClrImportant
    // 像素：bottom-up，BGR；横向渐变 + 纵向亮度，保证编码器有真实内容可压
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const unsigned char b = (unsigned char)((x * 255) / (w > 1 ? w - 1 : 1));
            const unsigned char g = (unsigned char)((y * 255) / (h > 1 ? h - 1 : 1));
            const unsigned char r = (unsigned char)(64 + ((x + y) % 128));
            out.push_back(b); out.push_back(g); out.push_back(r);
        }
        for (int pad = w * 3; pad < stride; ++pad) out.push_back(0);
    }
    return out;
}

// ---------------------------------------------------------------------------
// 极简 JPEG SOF0/SOF2 扫描器：只解析 marker 段长与长宽，不依赖任何解码库。
// 返回 false = 不是可解析的 JPEG 或没有 SOFn。
// ---------------------------------------------------------------------------
static bool jpegDims(const std::vector<unsigned char>& j, int& imgW, int& imgH) {
    imgW = imgH = 0;
    if (j.size() < 4 || j[0] != 0xFF || j[1] != 0xD8) return false;
    size_t pos = 2;
    while (pos + 1 < j.size()) {
        if (j[pos] != 0xFF) { ++pos; continue; }        // 段间填充字节
        while (pos + 1 < j.size() && j[pos + 1] == 0xFF) ++pos;   // 连续 FF 填充
        if (pos + 1 >= j.size()) return false;
        const unsigned char marker = j[pos + 1];
        pos += 2;
        // 无长度的独立 marker
        if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
        if (marker == 0xD9) return false;               // EOI，未见 SOFn
        if (pos + 2 > j.size()) return false;
        const size_t len = ((size_t)j[pos] << 8) | (size_t)j[pos + 1];
        if (len < 2 || pos + len > j.size()) return false;
        const bool sof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 &&
                         marker != 0xCC;
        if (sof) {
            if (len < 7) return false;                  // len(2)+精度(1)+高(2)+宽(2)
            imgH = ((int)j[pos + 3] << 8) | (int)j[pos + 4];
            imgW = ((int)j[pos + 5] << 8) | (int)j[pos + 6];
            return imgW > 0 && imgH > 0;
        }
        pos += len;
    }
    return false;
}

int main() {
    std::printf("== 封面缩略图（ImageIO + 缩略图磁盘缓存）验证 ==\n");

    // =====================================================================
    // [F] 第一件事：缓存根必须指向全新临时目录。
    //     RLPLAYER_COVER_DIR 优先级高于 STATE_DIR（会绕过它指到真实用户缓存），先清掉。
    // =====================================================================
    ::unsetenv("RLPLAYER_COVER_DIR");
    std::error_code ec;
    const fs::path tmp = fs::temp_directory_path() /
                         ("rta_cover_thumb_test." + std::to_string((long long)::getpid()));
    fs::remove_all(tmp, ec);
    ec.clear();
    fs::create_directories(tmp / "state", ec);
    const std::string stateDir = U8(tmp / "state");
    ::setenv("RLPLAYER_STATE_DIR", stateDir.c_str(), 1);
    std::printf("临时 STATE_DIR：%s\n", stateDir.c_str());
    ck(!ec && fs::is_directory(tmp / "state"), "[F] 全新临时 STATE_DIR 创建成功", stateDir);
    {
        const std::string rootDir = lc::root();
        const std::string thumbDir = lc::thumb_root();
        ck(rootDir == (fs::path(stateDir) / "covercache" / "embed").string(),
           "[F] root() 落在临时 STATE_DIR 下（不碰真实缓存）", rootDir);
        ck(thumbDir == (fs::path(stateDir) / "covercache" / "thumb").string(),
           "[F] thumb_root() = coverdir/thumb（root() 的兄弟目录）", thumbDir);
    }

    // =====================================================================
    // [A] 800x600 BMP -> <=512px JPEG，尺寸 512x384，且比源图小
    // =====================================================================
    const std::vector<unsigned char> bmp800 = makeBmp(800, 600);
    std::vector<unsigned char> jpeg512;
    const bool okA = lc::make_thumb(bmp800, jpeg512);
    std::printf("     [A] 源 BMP %zu B -> JPEG %zu B\n", bmp800.size(), jpeg512.size());
    ck(okA, "[A] 800x600 BMP -> make_thumb() 成功");
    ck(jpeg512.size() >= 3 && jpeg512[0] == 0xFF && jpeg512[1] == 0xD8 && jpeg512[2] == 0xFF,
       "[A] 输出是 JPEG（FF D8 FF）", std::to_string(jpeg512.size()) + " B");
    {
        int w = 0, h = 0;
        const bool parsed = jpegDims(jpeg512, w, h);
        ck(parsed, "[A] 能从输出 JPEG 解析出 SOF0/SOF2 尺寸");
        ck(w == 512 && h == 384, "[A] 长边缩到 512：尺寸 == 512x384",
           std::to_string(w) + "x" + std::to_string(h));
        ck(jpeg512.size() < bmp800.size(), "[A] 缩略图比源图小（网格要的是小字节）",
           std::to_string(jpeg512.size()) + " B vs " + std::to_string(bmp800.size()) + " B");
        ck(lc::mime_of(jpeg512) == "image/jpeg", "[A] mime_of(缩略图) == image/jpeg");
    }

    // =====================================================================
    // [B] 40x40 BMP -> 仍 40x40（永不放大）
    // =====================================================================
    const std::vector<unsigned char> bmp40 = makeBmp(40, 40);
    std::vector<unsigned char> jpeg40;
    const bool okB = lc::make_thumb(bmp40, jpeg40);
    ck(okB, "[B] 40x40 BMP -> make_thumb() 成功");
    {
        int w = 0, h = 0;
        const bool parsed = jpegDims(jpeg40, w, h);
        ck(parsed && w == 40 && h == 40, "[B] 不放大：40x40 保持 40x40",
           std::to_string(w) + "x" + std::to_string(h));
    }

    // =====================================================================
    // [C] 垃圾输入：false、不崩溃、输出清空
    // =====================================================================
    {
        std::vector<unsigned char> garbage;
        uint32_t x = 0x12345678u;
        for (int i = 0; i < 4096; ++i) {
            x = x * 1664525u + 1013904223u;
            garbage.push_back((unsigned char)(x >> 24));
        }
        std::vector<unsigned char> dirty(7, 0xAA);              // 预置脏值：失败必须清空
        ck(!lc::make_thumb(garbage, dirty), "[C] 4 KB 随机垃圾字节 -> false（不崩溃）",
           std::to_string(garbage.size()) + " B");
        ck(dirty.empty(), "[C] 失败时输出被清空（不返回脏值）", std::to_string(dirty.size()) + " B");
        std::vector<unsigned char> emptyOut(7, 0xAA);
        ck(!lc::make_thumb({}, emptyOut) && emptyOut.empty(), "[C] 0 字节输入 -> false 且输出清空");
        const std::vector<unsigned char> cut = {0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10};  // 截断的 JPEG 头
        std::vector<unsigned char> cutOut;
        ck(!lc::make_thumb(cut, cutOut), "[C] 只有 JPEG 文件头、无图像数据 -> false");
    }

    // =====================================================================
    // [D] source_stamp：缺失/目录 false；普通文件 true；改写后 token 变化
    // =====================================================================
    {
        const fs::path src = tmp / "state" / "song.flac";
        std::string tok = "dirty";
        ck(!lc::source_stamp(U8(tmp / "nope.flac"), tok) && tok.empty(),
           "[D] 不存在的路径 -> false 且 token 清空", tok);
        std::string dirTok = "dirty";
        ck(!lc::source_stamp(U8(tmp), dirTok) && dirTok.empty(),
           "[D] 目录（非普通文件）-> false 且 token 清空", dirTok);
        ck(writeFile(src, {'F', 'L', 'A', 'C', 1, 2, 3}), "[D] 夹具源文件写入成功");
        std::string t1;
        const bool ok1 = lc::source_stamp(U8(src), t1);
        ck(ok1 && !t1.empty(), "[D] 普通文件 -> true 且 token 非空", t1);
        // 追加字节改变 size（同一秒内 mtime 可能相同，size 必变 => token 必变）
        ck(writeFile(src, {'F', 'L', 'A', 'C', 1, 2, 3, 4, 5, 6, 7}), "[D] 夹具源文件改写成功");
        std::string t2;
        const bool ok2 = lc::source_stamp(U8(src), t2);
        ck(ok2 && t2 != t1, "[D] 文件被改写后 token 发生变化", t1 + " -> " + t2);
    }

    // =====================================================================
    // [E] write_thumb/read_thumb：往返相等 + 各种失配必须 false
    // =====================================================================
    {
        const std::string key = "0123456789abcdef";             // hex 字符 = 通过 valid_key
        const std::string token = "1700000000:123456789:1048576";
        const std::string base = (fs::path(lc::thumb_root()) / key).string();
        ck(lc::write_thumb(key, token, jpeg512), "[E] write_thumb 成功");
        lc::ThumbEntry got;
        const bool ok = lc::read_thumb(key, token, got);
        ck(ok, "[E] read_thumb 命中");
        ck(got.token == token, "[E] 命中项 token 回读一致", got.token);
        ck(got.mime == "image/jpeg", "[E] 命中项 mime == image/jpeg", got.mime);
        ck(got.bytes == jpeg512, "[E] 往返字节逐字节相同",
           std::to_string(got.bytes.size()) + " B vs " + std::to_string(jpeg512.size()) + " B");
        ck(fs::is_regular_file(base + ".jpg") && fs::is_regular_file(base + ".meta"),
           "[E] 缓存文件 <key>.jpg / <key>.meta 落在 thumb_root()");
        lc::ThumbEntry wrong;
        ck(!lc::read_thumb(key, "1700000000:123456789:1048577", wrong),
           "[E] 错误 token -> false（源文件换过就必须重新生成）");
        lc::ThumbEntry badKey;
        ck(!lc::read_thumb("../x", token, badKey), "[E] 非法 key \"../x\" -> read false（路径穿越被挡）");
        ck(!lc::write_thumb("../x", token, jpeg512), "[E] 非法 key \"../x\" -> write false");
        // 截断 <key>.jpg -> false（尺寸/JPEG 头校验）
        {
            std::ofstream f(base + ".jpg", std::ios::binary | std::ios::trunc);
            f.write("short", 5);
        }
        lc::ThumbEntry truncated;
        ck(!lc::read_thumb(key, token, truncated), "[E] 截断 <key>.jpg 后 -> false");
        // 恢复后篡改中间一个字节（size 不变 => 只有 hash 能发现）
        ck(lc::write_thumb(key, token, jpeg512), "[E] 重新 write_thumb 恢复成功");
        {
            std::vector<unsigned char> altered = readFile(base + ".jpg");
            ck(altered.size() == jpeg512.size(), "[E] 篡改前尺寸与写入一致",
               std::to_string(altered.size()) + " B");
            altered[altered.size() / 2] ^= 0xFF;
            ck(writeFile(base + ".jpg", altered), "[E] 篡改 <key>.jpg 中间 1 字节并写回");
        }
        lc::ThumbEntry altered;
        ck(!lc::read_thumb(key, token, altered),
           "[E] 篡改 <key>.jpg（size 不变）-> false（fnv hash 校验生效）");
        // 篡改 meta 第一行版本号 -> false
        ck(lc::write_thumb(key, token, jpeg512), "[E] 再次恢复成功");
        {
            const std::vector<unsigned char> meta = readFile(base + ".meta");
            const auto nl = std::find(meta.begin(), meta.end(), (unsigned char)'\n');
            std::vector<unsigned char> broken;
            const std::string bad = "RLPlayerCoverThumb0\n";
            broken.insert(broken.end(), bad.begin(), bad.end());
            if (nl != meta.end()) broken.insert(broken.end(), nl + 1, meta.end());
            ck(writeFile(base + ".meta", broken), "[E] 篡改 meta 版本行");
        }
        lc::ThumbEntry badMeta;
        ck(!lc::read_thumb(key, token, badMeta), "[E] meta 版本行不对 -> false（不误解旧格式）");
    }

    // =====================================================================
    // [F] 清理临时目录
    // =====================================================================
    fs::remove_all(tmp, ec);
    ck(!ec, "[F] 临时目录已清理", ec ? ec.message() : "");

    std::printf("\n%s（通过 %d 项，失败 %d 项）\n",
                g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
