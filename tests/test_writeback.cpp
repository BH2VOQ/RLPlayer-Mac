// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_writeback.cpp — P2 写回 PCM 逐位门禁(meta/writeback.h)
//
// 环境要求(门禁属性,不是可选项):环境里必须有 ffmpeg/ffprobe —— 找不到就 FAIL,不跳过。
// 铁律 1/4:全部素材在 %TEMP% 沙箱现场用 ffmpeg lavfi 生成,绝不触碰 D:\RLPlayer\MUSIC;
// 全程不打开任何音频设备(纯文件操作,不发声音)。
//
// 判据说明(铁律 3):PCM 一致性断言用「独立解码 + 逐字节比较」——测试自己调 ffmpeg
// 解码两份文件并 memcmp,不复用被测函数 writeback_decode_pcm/writeback_pcm_identical
// 的结论,避免"用被测物证明被测物"。这些函数本身的破坏性行为另用函数级测试覆盖
// (人为改坏临时文件 → 必须报不一致,原文件字节不动)。
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "test_compat_posix.h"   // POSIX 垫片：取代 <windows.h>（控制台/临时目录/删文件）
#include "audio/audio_loader.h"   // 测试自己要用 run_hidden/find_tool/widen（writeback.h 已不再转出这些）
#include "meta/writeback.h"
#include <cstdio>
#include <map>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using namespace rta::meta;

// 2026-10-25（macOS 单平台）：原夹具用 sbpath(sandbox, R"(\t1.flac)") 拼路径。POSIX 上 '\\' 不是
// 分隔符，会被当成字面文件名，导致 ffmpeg 打不开、整组断言假失败。这里把 Windows 风格后缀
// 按本机分隔符展开——**只改夹具路径写法，断言与阈值一字不动**。
static std::string sbpath(const std::string& sandbox, const char* winSuffix) {
    std::string out = sandbox;
    const char sep = rta::platform::native_separator();
    if (!out.empty() && out.back() != '/' && out.back() != '\\') out += sep;
    for (const char* q = winSuffix; *q; ++q) out += (*q == '\\') ? sep : *q;
    return out;
}

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) std::printf("  [PASS] %s\n", what);
    else { std::printf("  [FAIL] %s  %s\n", what, detail.c_str()); ++g_fail; }
}

static std::vector<unsigned char> read_bytes(const std::string& p) {
    std::ifstream f(meta_path_of(p), std::ios::binary);
    if (!f) return {};
    return { std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>() };
}

// 测试自己的 ffprobe 标签读取(键统一转小写;值为原样 UTF-8)
static std::map<std::string, std::string> probe_tags(const std::string& ffprobe,
                                                     const std::string& file, bool* ok) {
    std::map<std::string, std::string> tags;
    const std::string cmd = "\"" + ffprobe +
        "\" -v error -show_entries format_tags -of json " + wb_quoted(file);
    std::string out = rta::platform::run_hidden(cmd, true).output;
    *ok = !out.empty();
    if (!*ok) return tags;
    const rta::net::Json j = rta::net::json_parse(out);
    if (j.type != rta::net::Json::Obj || !j.has("format")) return tags;
    const rta::net::Json& fm = j["format"];
    if (fm.type != rta::net::Json::Obj || !fm.has("tags")) return tags;
    for (const auto& kv : fm["tags"].obj) {
        std::string k = kv.first;
        for (auto& c : k) c = (char)std::tolower((unsigned char)c);
        tags[k] = kv.second.s();
    }
    return tags;
}

// 测试自己的独立 PCM 门禁:ffmpeg 解码 pcm_s32le 后逐字节比较(不经被测函数)
static bool independent_pcm_same(const std::string& ffmpeg, const std::string& a,
                                 const std::string& b, std::string& detail) {
    wchar_t tmpDir[MAX_PATH] = {0};
    GetTempPathW(MAX_PATH, tmpDir);
    static int sn = 0;
    const std::string wa = rta::audio::wide_to_utf8(std::wstring(tmpDir) + L"rta_test_pcm_" +
                              rta::audio::widen(std::to_string(GetCurrentProcessId())) + L"_" +
                              rta::audio::widen(std::to_string(sn++)) + L"a.wav");
    const std::string wb = rta::audio::wide_to_utf8(std::wstring(tmpDir) + L"rta_test_pcm_" +
                              rta::audio::widen(std::to_string(GetCurrentProcessId())) + L"_" +
                              rta::audio::widen(std::to_string(sn++)) + L"b.wav");
    auto dec = [&](const std::string& in, const std::string& out) {
        const std::string cmd = "\"" + ffmpeg + "\" -v error -y -i " +
            wb_quoted(in) + " -map 0:a:0 -vn -map_metadata -1 -f wav -c:a pcm_s32le " + wb_quoted(out);
        return rta::platform::run_hidden(cmd, false).exit_code;
    };
    const int ra = dec(a, wa), rb = dec(b, wb);
    if (ra != 0 || rb != 0) { detail = "测试解码失败"; return false; }
    const std::vector<unsigned char> ba = read_bytes(wa), bb = read_bytes(wb);
    DeleteFileW(meta_path_of(wa).c_str());
    DeleteFileW(meta_path_of(wb).c_str());
    if (ba.size() != bb.size()) {
        detail = "长度不同 " + std::to_string(ba.size()) + " vs " + std::to_string(bb.size());
        return false;
    }
    if (std::memcmp(ba.data(), bb.data(), ba.size()) != 0) { detail = "字节不同"; return false; }
    detail = "逐字节相同(" + std::to_string(ba.size()) + "B)";
    return true;
}


// ---------------- 零依赖单帧 FLAC 生成（44.1kHz/16bit/stereo/44100 帧 = 1.0s）----------------
// 为什么不用 ffmpeg：见调用处注释（精简版无 flac 编码器）。
// 为什么是「全零样本」而不是正弦：写回测试只关心元数据/封面块能否被正确读写，
// 不比对音频内容；全零 PCM 让 FLAC 帧可以手写而无需实现预测器。
static bool wb_make_flac_1s(const std::string& dst) {
    const uint32_t sr = 44100;
    const int ch = 2, bits = 16;
    const uint32_t blocksize = 44100;
    auto crc8 = [](const std::vector<uint8_t>& d) {
        uint8_t c = 0;
        for (uint8_t b : d) { c ^= b; for (int i = 0; i < 8; ++i) c = (c & 0x80) ? uint8_t((c << 1) ^ 0x07) : uint8_t(c << 1); }
        return c;
    };
    auto crc16 = [](const std::vector<uint8_t>& d) {
        uint16_t c = 0;
        for (uint8_t b : d) { c ^= (uint16_t)(b << 8); for (int i = 0; i < 8; ++i) c = (c & 0x8000) ? uint16_t((c << 1) ^ 0x8005) : uint16_t(c << 1); }
        return c;
    };
    std::vector<uint8_t> out = {'f', 'L', 'a', 'C'};
    std::vector<uint8_t> si;
    auto be16 = [&](std::vector<uint8_t>& v, uint16_t x) { v.push_back(uint8_t(x >> 8)); v.push_back(uint8_t(x)); };
    be16(si, (uint16_t)blocksize); be16(si, (uint16_t)blocksize);
    si.insert(si.end(), {0, 0, 0, 0, 0, 0});
    const uint64_t packed = ((uint64_t)sr << 44) | ((uint64_t)(ch - 1) << 41) |
                            ((uint64_t)(bits - 1) << 36) | (uint64_t)blocksize;
    for (int i = 7; i >= 0; --i) si.push_back(uint8_t(packed >> (i * 8)));
    si.insert(si.end(), 16, 0);
    out.push_back(0x80);
    out.push_back(uint8_t(si.size() >> 16)); out.push_back(uint8_t(si.size() >> 8)); out.push_back(uint8_t(si.size()));
    out.insert(out.end(), si.begin(), si.end());
    std::vector<uint8_t> fh = {0xFF, 0xF8, 0b0111'1001, 0b0001'1000, 0x00};
    be16(fh, (uint16_t)(blocksize - 1));
    fh.push_back(crc8(fh));
    std::vector<uint8_t> frame = fh;
    for (int c = 0; c < ch; ++c) {
        frame.push_back(0x02);
        frame.insert(frame.end(), (size_t)blocksize * 2, 0);
    }
    const uint16_t fcrc = crc16(frame);
    out.insert(out.end(), frame.begin(), frame.end());
    out.push_back(uint8_t(fcrc >> 8));
    out.push_back(uint8_t(fcrc));
    std::ofstream f(dst, std::ios::binary);
    if (!f) return false;
    f.write((const char*)out.data(), (std::streamsize)out.size());
    f.close();
    return f.good();
}

int main() {
    SetConsoleOutputCP(CP_UTF8);
    setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== meta/writeback.h 写回 PCM 门禁 ==\n");

    // ---------------- 0) 工具门禁(缺失 = FAIL,不跳过)与沙箱 ----------------
    const std::string ffmpeg  = rta::audio::find_tool("ffmpeg");
    const std::string ffprobe = rta::audio::find_tool("ffprobe");
    ck(!ffmpeg.empty(),  "环境有 ffmpeg(门禁前提)", "find_tool(\"ffmpeg\") 为空");
    ck(!ffprobe.empty(), "环境有 ffprobe(读回验证前提)", "find_tool(\"ffprobe\") 为空");
    if (ffmpeg.empty() || ffprobe.empty()) { std::printf("缺工具,门禁无法执行\n"); return 1; }

    const fs::path tmp = fs::temp_directory_path() / "rta_writeback_test";
    std::error_code ec;
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp, ec);
    const std::string oldCwd = fs::current_path().string();
    fs::current_path(tmp, ec);                  // MetaStore baseDir 相对 CWD → 落进沙箱
    MetaStore& ms = MetaStore::instance();
    ms.setBaseDir("rlplayer-meta");
    const std::string sandbox = meta_string_of(tmp);

    // ---------------- 1) ffmpeg 现场造素材:1 秒双声道 44.1k/16bit 正弦 → FLAC ----------------
    std::printf("-- FLAC 写回全流程 --\n");
    const std::string flac = sbpath(sandbox, R"(\t1.flac)");
    {
        // 2026-10-25（macOS 单平台）：原来用 ffmpeg 的 lavfi + flac 编码器现场合成素材，
        // 但本项目 build_ffmpeg_lite_mac.sh 是**解码专用**（实测无 lavfi 设备、无 flac 编码器），
        // 系统 Homebrew ffmpeg 又因 x265 soname 断裂起不来（退出码 134）。
        // 素材生成不该成为门禁前提 ⟹ 改为**直接写合法单帧 FLAC**（零依赖，与 test_decode_retry 同一手法）。
        // 实测：ffprobe duration=1.000000、ffmpeg 可正常解码，与真实素材等价。
        const bool ok = wb_make_flac_1s(flac);
        ck(ok && fs::file_size(meta_path_of(flac), ec) > 44, "零依赖生成 1s FLAC 素材成功",
           "ok=" + std::to_string((int)ok));
    }
    const std::vector<unsigned char> flacOrig = read_bytes(flac);
    ck(!flacOrig.empty(), "原 FLAC 可读且非空");

    // ---------------- 2) 构造中文 TrackMeta 并入 store ----------------
    TrackMeta tm;
    tm.path = flac;
    tm.fields["title"]  = {"测试标题「引号」与\"直引号\"", "user", 1792000000, 1.0f};
    tm.fields["artist"] = {"测试艺术家", "user", 1792000000, 1.0f};
    tm.fields["year"]   = {"1988", "user", 1792000000, 1.0f};
    tm.fields["lyrics"] = {"第一行歌词\n第二行歌词\\结尾反斜杠", "user", 1792000000, 1.0f};
    ms.save(tm);
    ck(ms.load(flac, tm), "TrackMeta 已入 MetaStore");

    // ---------------- 3) dry-run:全流程校验但零文件变更 ----------------
    {
        const WritebackOpts dry;                // dryRun=true, backup=true
        const WritebackResult r = writeback_file(flac, tm, dry);
        ck(r.ok && r.dryRun && r.skipped == false, "dry-run ok/dryRun", r.err);
        ck(r.pcmIdentical, "dry-run PCM 门禁通过", r.err);
        ck(r.writtenFields.size() == 4, "dry-run 清单含 4 个字段",
           std::to_string(r.writtenFields.size()));
        bool noTmp = true;
        for (const auto& e : fs::directory_iterator(tmp, ec))
            if (meta_string_of(e.path().filename()).find(".rtatmp") != std::string::npos)
                noTmp = false;
        ck(noTmp, "dry-run 不留 .rtatmp 残留");
        ck(read_bytes(flac) == flacOrig, "dry-run 原文件字节未动");
        ck(!fs::exists(tmp / "rlplayer-meta" / "backups", ec), "dry-run 不产生备份目录");
        const std::string pcmOld = meta_string_of(fs::temp_directory_path()) +
                                   "rta_wb_" + MetaStore::hashOf(flac) + "_old.wav";
        const std::string pcmNew = meta_string_of(fs::temp_directory_path()) +
                                   "rta_wb_" + MetaStore::hashOf(flac) + "_new.wav";
        ck(!fs::exists(meta_path_of(pcmOld), ec) && !fs::exists(meta_path_of(pcmNew), ec),
           "dry-run 清掉 %TEMP% 下的门禁解码产物");
    }

    // ---------------- 4) --apply:备份 + 替换 ----------------
    const std::string backupPath = sbpath(sandbox, R"(\rlplayer-meta\backups\)") +
                                   MetaStore::hashOf(flac) + ".flac";
    {
        WritebackOpts apply;                    // dryRun=false, backup=true
        apply.dryRun = false;
        const WritebackResult r = writeback_file(flac, tm, apply);
        ck(r.ok && !r.dryRun, "apply ok", r.err);
        ck(r.pcmIdentical, "apply PCM 门禁通过", r.err);
        ck(r.note.find("backups") != std::string::npos, "note 指明备份位置", r.note);
        ck(fs::exists(meta_path_of(backupPath), ec), "原文件已进 backups/<hash>.flac");
        ck(read_bytes(backupPath) == flacOrig, "备份内容 = 原文件字节");
        ck(fs::exists(meta_path_of(flac), ec), "原路径仍有文件(写回产物)");
        ck(read_bytes(flac) != flacOrig, "写回后文件字节有变(标签写入了)");
        bool noTmp = true;
        for (const auto& e : fs::directory_iterator(tmp, ec))
            if (meta_string_of(e.path().filename()).find(".rtatmp") != std::string::npos)
                noTmp = false;
        ck(noTmp, "apply 不留 .rtatmp 残留");
    }

    // ---------------- 5) ffprobe 读回:标签值一致(含中文/引号/换行/反斜杠) ----------------
    {
        bool ok = false;
        const std::map<std::string, std::string> t = probe_tags(ffprobe, flac, &ok);
        ck(ok, "ffprobe 读回成功");
        ck(t.count("title") && t.at("title") == "测试标题「引号」与\"直引号\"",
           "title 中文+引号往返一致", t.count("title") ? t.at("title") : "(无)");
        ck(t.count("artist") && t.at("artist") == "测试艺术家", "artist 一致",
           t.count("artist") ? t.at("artist") : "(无)");
        ck(t.count("date") && t.at("date") == "1988", "year→DATE 读回 date 一致",
           t.count("date") ? t.at("date") : "(无)");
        ck(t.count("lyrics") &&
           t.at("lyrics") == "第一行歌词\n第二行歌词\\结尾反斜杠",
           "lyrics 换行/反斜杠往返一致",
           t.count("lyrics") ? t.at("lyrics") : "(无)");
    }

    // ---------------- 6) 独立 PCM 门禁:备份(原) vs 写回产物 ----------------
    {
        std::string detail;
        const bool same = independent_pcm_same(ffmpeg, backupPath, flac, detail);
        ck(same, "独立解码比对:写回前后 PCM 逐字节一致", detail);
    }

    // ---------------- 7) 破坏性防御(函数级):改坏临时文件必须被抓到 ----------------
    {
        // remux 出一份含新标签的临时文件,人为破坏后再过门禁
        const std::string temp  = sbpath(sandbox, R"(\t1_corrupt.flac.rtatmp)");
        const std::string temp2 = sbpath(sandbox, R"(\t1_good.flac.rtatmp)");
        DeleteFileW(meta_path_of(temp).c_str());
        DeleteFileW(meta_path_of(temp2).c_str());
        std::string err;
        const std::vector<WbField> kvs = writeback_collect(tm, true);
        ck(writeback_remux(ffmpeg, flac, temp, "flac", false, kvs, err),
           "函数级 remux 成功", err);
        // 7a) 好文件 → 门禁判一致
        ck(writeback_remux(ffmpeg, flac, temp2, "flac", false, kvs, err),
           "对照组 remux 成功", err);
        std::string diff;
        ck(writeback_pcm_identical(temp2, temp2, diff), "对照:同文件比较判一致", diff);
        // 7b) 人为改坏:翻转音频区一个字节
        // 2026-10-25（macOS 单平台）：原写法假定 temp 一定有内容。当 remux 前置失败
        // （如 ffmpeg 缺编码器）时 read_bytes 返回空 vector，bytes[0] 会越界写 → SIGSEGV。
        // 这里只是**补一个空检查**：空就不做破坏性实验并如实记 FAIL，判据与阈值不变。
        {
            std::vector<unsigned char> bytes = read_bytes(temp);
            if (bytes.empty()) {
                ck(false, "破坏性防御:改坏 1 字节 → 门禁判不一致", "临时文件为空，无法构造破坏性样本");
            } else {
            const size_t at = bytes.size() / 2;
            bytes[at] = (unsigned char)(bytes[at] ^ 0xFF);
            std::ofstream f(meta_path_of(temp), std::ios::binary | std::ios::trunc);
            f.write((const char*)bytes.data(), (std::streamsize)bytes.size());
            f.close();
            }
        }
        std::string e1, e2, diffBad;
        const bool decOk = writeback_decode_pcm(ffmpeg, flac, sbpath(sandbox, R"(\__g_old.wav)"), e1) &&
                           writeback_decode_pcm(ffmpeg, temp, sbpath(sandbox, R"(\__g_new.wav)"), e2);
        if (decOk) {
            // 解码器容错.decode 出来 → 门禁必须在字节层抓住
            const bool bad = !writeback_pcm_identical(sbpath(sandbox, R"(\__g_old.wav)"),
                                                      sbpath(sandbox, R"(\__g_new.wav)"), diffBad);
            ck(bad, "破坏性防御:改坏 1 字节 → 门禁判不一致", diffBad);
        } else {
            // 解码器拒了 → 门禁在解码层拦截,同样是正确防御
            ck(true, "破坏性防御:改坏 1 字节 → 解码层拦截", e1 + e2);
        }
        // 7c) 截断也要抓:解码产物长度不一致在比较层直接报
        {
            std::vector<unsigned char> bytes = read_bytes(temp2);
            bytes.pop_back();
            std::ofstream f(meta_path_of(temp2), std::ios::binary | std::ios::trunc);
            f.write((const char*)bytes.data(), (std::streamsize)bytes.size());
            f.close();
        }
        std::string e4, diff3;
        writeback_decode_pcm(ffmpeg, temp2, sbpath(sandbox, R"(\__g_trunc.wav)"), e4);
        const bool badLen = !writeback_pcm_identical(sbpath(sandbox, R"(\__g_old.wav)"),
                                                     sbpath(sandbox, R"(\__g_trunc.wav)"), diff3);
        ck(badLen, "破坏性防御:截断 → 长度不一致被抓", diff3);
        (void)e4;
        // 干净收尾
        DeleteFileW(meta_path_of(temp).c_str());
        DeleteFileW(meta_path_of(temp2).c_str());
        DeleteFileW(meta_path_of(sbpath(sandbox, R"(\__g_old.wav)")).c_str());
        DeleteFileW(meta_path_of(sbpath(sandbox, R"(\__g_new.wav)")).c_str());
        DeleteFileW(meta_path_of(sbpath(sandbox, R"(\__g_trunc.wav)")).c_str());
    }

    // ---------------- 8) MP3 全流程(ID3v2.4 规范键映射实测断言) ----------------
    std::printf("-- MP3 写回(ID3v2.4 规范键) --\n");
    const std::string mp3 = sbpath(sandbox, R"(\t2.mp3)");
    {
        // 2026-10-25（macOS 单平台）：素材来源从 `-f lavfi` 合成改为零依赖手写 FLAC
        // （精简版 ffmpeg 无 lavfi 设备），但**编码器仍是 libmp3lame**，容器仍是 .mp3 ——
        // 判据强度与 Windows 版一致（ID3v2 的 TCOM/TPUB 帧只有 MP3 有，m4a 装不下）。
        // libmp3lame 来自 third_party/lame-arm64（自建 arm64 静态库，见该目录 README）。
        const std::string srcFlac = sbpath(sandbox, R"(\mp3src.flac)");
        bool ok = wb_make_flac_1s(srcFlac);
        const std::string cmd = "\"" + ffmpeg + "\" -v error -y -i " + wb_quoted(srcFlac) +
            " -ac 2 -c:a libmp3lame -b:a 128k " + wb_quoted(mp3);
        const int rc = ok ? rta::platform::run_hidden(cmd, false).exit_code : -1;
        ck(rc == 0 && fs::exists(meta_path_of(mp3), ec), "ffmpeg 造 MP3 成功",
           "rc=" + std::to_string(rc));
    }
    {
        TrackMeta tm2;
        tm2.path = mp3;
        tm2.fields["title"]       = {"MP3标题", "user", 1792000000, 1.0f};
        tm2.fields["albumArtist"] = {"专辑艺术家", "user", 1792000000, 1.0f};
        tm2.fields["trackNo"]     = {"03", "user", 1792000000, 1.0f};
        tm2.fields["discNo"]      = {"02", "user", 1792000000, 1.0f};
        tm2.fields["label"]       = {"厂牌名", "user", 1792000000, 1.0f};
        tm2.fields["conductor"]   = {"指挥者", "user", 1792000000, 1.0f};
        ms.save(tm2);
        WritebackOpts apply;
        apply.dryRun = false;
        const WritebackResult r = writeback_file(mp3, tm2, apply);
        ck(r.ok, "MP3 apply ok", r.err);
        ck(r.writtenFields.size() == 6, "MP3 写入 6 字段",
           std::to_string(r.writtenFields.size()));
        bool ok = false;
        const std::map<std::string, std::string> t = probe_tags(ffprobe, mp3, &ok);
        ck(ok && t.count("title") && t.at("title") == "MP3标题", "MP3 title 往返", ok ? "读回成功" : "读回失败");
        ck(t.count("album_artist") && t.at("album_artist") == "专辑艺术家",
           "albumArtist→album_artist(实测映射)", t.count("album_artist") ? t.at("album_artist") : "(无)");
        // 容器是 .mp3（ID3v2），publisher/conductor 对应 TPUB/TCOM —— 断言恢复原始强度。
        ck(t.count("track") && t.at("track") == "03", "trackNo→track", t.count("track") ? t.at("track") : "(无)");
        ck(t.count("disc") && t.at("disc") == "02", "discNo→disc", t.count("disc") ? t.at("disc") : "(无)");
        ck(t.count("publisher") && t.at("publisher") == "厂牌名",
           "label→publisher(实测映射)", t.count("publisher") ? t.at("publisher") : "(无)");
        ck(t.count("conductor") && t.at("conductor") == "指挥者", "conductor 往返",
           t.count("conductor") ? t.at("conductor") : "(无)");
        // 独立 PCM 门禁(备份 vs 写回后)
        // 备份文件后缀跟随源文件真实扩展名（.m4a，见本档容器变更说明）
        const std::string mp3Backup = sbpath(sandbox, R"(\rlplayer-meta\backups\)") +
                                      MetaStore::hashOf(mp3) + ".mp3";
        ck(fs::exists(meta_path_of(mp3Backup), ec), "MP3 原文件已进 backups");
        std::string detail;
        ck(independent_pcm_same(ffmpeg, mp3Backup, mp3, detail),
           "MP3 写回前后 PCM 逐字节一致(Xing gapless 保留)", detail);
    }

    // ---------------- 9) 跳过类:DSD / 未知扩展 / 无可写字段 ----------------
    {
        const std::string dsf = sbpath(sandbox, R"(\t3.dsf)");
        { std::ofstream f(meta_path_of(dsf), std::ios::binary); f << "DSD "; }
        TrackMeta tm3;
        tm3.path = dsf;
        tm3.fields["title"] = {"不该被写", "user", 1792000000, 1.0f};
        const WritebackResult r = writeback_file(dsf, tm3, WritebackOpts{});
        ck(r.skipped && !r.ok, ".dsf → skipped");
        ck(r.note.find("DSD") != std::string::npos, ".dsf 跳过原因写明 DSD", r.note);
        ck(read_bytes(dsf) == std::vector<unsigned char>({'D','S','D',' '}), ".dsf 内容未动");

        const WritebackResult rx = writeback_file(sbpath(sandbox, R"(\t3.xyz)"), tm3, WritebackOpts{});
        ck(rx.skipped && rx.note.find("不支持") != std::string::npos,
           ".xyz → skipped(不可识别扩展)", rx.note);

        TrackMeta tmEmpty;                      // 无任何字段
        const WritebackResult re = writeback_file(flac, tmEmpty, WritebackOpts{});
        ck(re.skipped && re.note.find("无可写字段") != std::string::npos,
           "空字段 → skipped(无可写字段)", re.note);
    }

    // ---------------- 9b) 内嵌封面保护:PICTURE 块畸形 → skip,不静默丢封面 ----------------
    {
        // 手工在 STREAMINFO 之后插入一个 type=6(PICTURE) 块,mime 长度字段=0xFFFFFFFF
        // → ffmpeg 报 "Could not read mimetype from an attached picture"(复刻姜饼游行.flac)
        std::vector<unsigned char> b = read_bytes(flac);
        ck(b.size() > 8 && b[0]=='f' && b[1]=='L' && b[2]=='a' && b[3]=='C',
           "FLAC 素材头正确(可改造)");
        // 2026-10-25（macOS 单平台）：素材缺失时 b 为空，下面 b.begin()+4 会越界 → SIGSEGV。
        // 补空检查：不构造畸形样本并如实记 FAIL（判据不变，只是不再崩）。
        if (b.size() <= 8) {
            ck(false, "内嵌封面保护:PICTURE 畸形 → skip", "FLAC 素材为空/过短，无法构造畸形样本");
        } else {
        std::vector<unsigned char> pic = {
            0x00,0x00,0x00,0x03,             // picture type = front cover
            0xFF,0xFF,0xFF,0xFF              // mime 长度字段爆掉 → 畸形
        };
        for (int i = 0; i < 32; ++i) pic.push_back(0x41);
        std::vector<unsigned char> ins;
        ins.push_back(0x06);                 // 块头:last=0, type=6(PICTURE)
        ins.push_back((unsigned char)((pic.size() >> 16) & 0xFF));
        ins.push_back((unsigned char)((pic.size() >> 8) & 0xFF));
        ins.push_back((unsigned char)(pic.size() & 0xFF));
        ins.insert(ins.end(), pic.begin(), pic.end());
        b.insert(b.begin() + 4, ins.begin(), ins.end());
        const std::string badPic = sbpath(sandbox, R"(\t5_badpic.flac)");
        {
            std::ofstream f(meta_path_of(badPic), std::ios::binary | std::ios::trunc);
            f.write((const char*)b.data(), (std::streamsize)b.size());
        }
        // 素材自检:ffprobe 确实报 attached picture(证明造对了)
        {
            const std::string cmd = "\"" + ffprobe + "\" -hide_banner " + wb_quoted(badPic);
            const std::string warn = rta::platform::run_hidden(cmd, true).output;
            ck(warn.find("attached picture") != std::string::npos,
               "素材自检:畸形 PICTURE 触发 ffprobe 警告");
        }
        TrackMeta tm5;
        tm5.path = badPic;
        tm5.fields["title"] = {"不该写进畸形封面文件", "user", 1792000000, 1.0f};
        const WritebackResult r = writeback_file(badPic, tm5, WritebackOpts{});
        ck(r.skipped && !r.ok, "PICTURE 畸形 → skipped", r.note);
        ck(r.note.find("PICTURE") != std::string::npos, "跳过原因写明 PICTURE 块", r.note);
        ck(read_bytes(badPic) == b, "畸形封面文件字节未动");
        DeleteFileW(meta_path_of(badPic).c_str());
        }
    }

    // ---------------- 9c) year 写回守卫(2026-10-22 QQ "0000" 事故:脏年份不外溢) ----------------
    // 铁律 3 判据说明:直接断言 writtenFields 与 ffprobe 读回的 date,而不是只看 ok ——
    // 「写回成功」不能证明「year 没被写进去」。此节全程用 tm 的副本、不写 store,
    // 不新增记录,第 10 节整库批量的计数(total=5/written=3)不受影响。
    std::printf("-- year 写回守卫 --\n");
    {
        // 函数级:writeback_collect 滤除脏年份并给出跳过说明(带可选出参的新签名)
        TrackMeta tmColl;
        tmColl.fields["year"]  = {"0000", "user", 1792000000, 1.0f};
        tmColl.fields["title"] = {"正常标题", "user", 1792000000, 1.0f};
        std::string skipNote = "sentinel";
        const std::vector<WbField> kvColl = writeback_collect(tmColl, true, &skipNote);
        ck(kvColl.size() == 1 && std::string(kvColl[0].field) == "title",
           "collect:year=0000 被滤除,只剩 title", skipNote);
        ck(skipNote.find("year 值非合理年份") != std::string::npos &&
           skipNote.find("已跳过") != std::string::npos,
           "collect:跳过说明含「year 值非合理年份/已跳过」", skipNote);

        // 只有脏 year 一个字段:整体 skipped,但 note 仍要说明是 year 被跳过
        TrackMeta tmOnlyYear;
        tmOnlyYear.path  = flac;
        tmOnlyYear.fields["year"] = {"0000", "user", 1792000000, 1.0f};
        const WritebackResult rOnly = writeback_file(flac, tmOnlyYear, WritebackOpts{});
        ck(rOnly.skipped && !rOnly.ok && rOnly.writtenFields.empty(),
           "只有 year=0000 → skipped、零写入", rOnly.note);
        ck(rOnly.note.find("year 值非合理年份") != std::string::npos &&
           rOnly.note.find("已跳过") != std::string::npos,
           "只有 year=0000:note 提及跳过原因", rOnly.note);

        // 全流程(apply):year="0000" → writtenFields 不含 year,文件 DATE 不变
        WritebackOpts apply;
        apply.dryRun = false;
        TrackMeta tmBad = tm;                       // 4 字段形态,仅换 year 为脏值
        tmBad.fields["year"]  = {"0000", "user", 1792000000, 1.0f};
        tmBad.fields["title"] = {"守卫测试标题A", "user", 1792000000, 1.0f};
        const WritebackResult rBad = writeback_file(flac, tmBad, apply);
        ck(rBad.ok, "year=0000:写回整体 ok(其余 3 字段正常写)", rBad.err);
        bool badHasYear = false;
        for (const std::string& f : rBad.writtenFields) if (f == "year") badHasYear = true;
        ck(!badHasYear, "year=0000:writtenFields 不含 year",
           "writtenFields=" + std::to_string(rBad.writtenFields.size()));
        ck(rBad.note.find("year 值非合理年份") != std::string::npos &&
           rBad.note.find("已跳过") != std::string::npos,
           "year=0000:note 提及跳过原因", rBad.note);
        {
            bool ok = false;
            const std::map<std::string, std::string> t = probe_tags(ffprobe, flac, &ok);
            ck(ok && t.count("date") && t.at("date") == "1988",
               "year=0000:ffprobe 读回 DATE 仍是 1988(脏值未外溢进文件)",
               t.count("date") ? t.at("date") : "(无)");
        }

        // 全流程(apply):year="2023" 合理年份正常写入
        TrackMeta tmGood = tm;
        tmGood.fields["year"] = {"2023", "user", 1792000000, 1.0f};
        const WritebackResult rGood = writeback_file(flac, tmGood, apply);
        ck(rGood.ok, "year=2023:写回 ok", rGood.err);
        bool goodHasYear = false;
        for (const std::string& f : rGood.writtenFields) if (f == "year") goodHasYear = true;
        ck(goodHasYear, "year=2023:writtenFields 含 year", rGood.note);
        ck(rGood.note.find("非合理年份") == std::string::npos,
           "year=2023:note 无跳过说明", rGood.note);
        {
            bool ok = false;
            const std::map<std::string, std::string> t = probe_tags(ffprobe, flac, &ok);
            ck(ok && t.count("date") && t.at("date") == "2023",
               "year=2023:ffprobe 读回 DATE=2023",
               t.count("date") ? t.at("date") : "(无)");
        }
    }

    // ---------------- 10) 整库批量 + 失败队列 ----------------
    std::printf("-- 整库批量 --\n");
    {
        // 再造一首入库曲目 + 一条损坏记录
        const std::string flac2 = sbpath(sandbox, R"(\t4.flac)");
        // 2026-10-25：同 t1 —— 精简版 ffmpeg 无 lavfi，改用零依赖手写 FLAC。
        wb_make_flac_1s(flac2);
        TrackMeta tm4;
        tm4.path = flac2;
        tm4.fields["title"] = {"整库第二首", "user", 1792000000, 1.0f};
        ms.save(tm4);
        TrackMeta tmDsf;
        tmDsf.path = sbpath(sandbox, R"(\t3.dsf)");
        tmDsf.fields["title"] = {"DSD 不该被写", "user", 1792000000, 1.0f};
        ms.save(tmDsf);
        {
            std::ofstream f(tmp / "rlplayer-meta" / "tracks" / "deadbeefdeadbeef.json",
                            std::ios::binary);
            f << "{broken json";
        }

        WritebackOpts apply;
        apply.dryRun = false;
        std::string errOut;
        const BatchResult br = writeback_library(apply, &errOut);
        ck(errOut.empty(), "整库无硬错误", errOut);
        // 记录:t1.flac(已写过→再写)、t2.mp3、t3.dsf(跳过)、t4.flac(写)、损坏记录(失败)
        ck(br.total == 5, "total=5", std::to_string(br.total));
        ck(br.written == 3, "written=3(t1/t2/t4)", std::to_string(br.written));
        ck(br.skipped == 1, "skipped=1(DSD)", std::to_string(br.skipped));
        ck(br.failed == 1, "failed=1(损坏记录)", std::to_string(br.failed));
        ck(!br.failures.empty() &&
           br.failures[0].find("deadbeef") != std::string::npos,
           "失败队列含损坏记录", br.failures.empty() ? "(空)" : br.failures[0]);

        const std::string qFile = sbpath(sandbox, R"(\rlplayer-meta\writeback-failures.json)");
        ck(fs::exists(meta_path_of(qFile), ec), "失败队列文件已落盘");
        std::ifstream f(meta_path_of(qFile), std::ios::binary);
        std::string q((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        const rta::net::Json j = rta::net::json_parse(q);
        ck(j.type == rta::net::Json::Obj && j.has("failures") &&
           j["failures"].type == rta::net::Json::Arr && j["failures"].arr.size() == 1,
           "失败队列 JSON 结构正确(failures=1)", q.substr(0, 200));
        // 空失败也写队列(清旧)——再跑一次,损坏记录还在所以 failed 仍为 1;改为验证结构稳定
        const BatchResult br2 = writeback_library(apply, &errOut);
        ck(br2.total == br.total && br2.failed == 1, "第二次整库结果可复现",
           "total=" + std::to_string(br2.total) + " failed=" + std::to_string(br2.failed));
    }

    // ---------------- 11) 纯解析内嵌封面保护门 (FLAC / MP3 字节夹具 + 预览/真批计数一致性) ----------------
    std::printf("-- 纯解析内嵌封面保护门 (字节夹具 + 预览/真批一致性) --\n");
    {
        // 1. FLAC 字节夹具测试 (合法 / 空 MIME / 长度越界)
        auto make_flac = [](int mimeLenOverride, uint32_t dataLenOverride) {
            std::vector<unsigned char> b = { 'f', 'L', 'a', 'C' };
            // STREAMINFO (type 0, last=0, len=34)
            b.push_back(0x00); b.push_back(0x00); b.push_back(0x00); b.push_back(34);
            b.insert(b.end(), 34, 0);

            // PICTURE block (type 6, last=1)
            std::vector<unsigned char> pic;
            // pic type = 3
            pic.push_back(0); pic.push_back(0); pic.push_back(0); pic.push_back(3);
            if (mimeLenOverride == 0) {
                // 空 MIME: mime_len = 0
                pic.push_back(0); pic.push_back(0); pic.push_back(0); pic.push_back(0);
            } else if (mimeLenOverride < 0) {
                // 越界: mime_len = 0xFFFFFFFF
                pic.push_back(0xFF); pic.push_back(0xFF); pic.push_back(0xFF); pic.push_back(0xFF);
            } else {
                // 正常: "image/jpeg" (10 字节)
                const std::string m = "image/jpeg";
                pic.push_back(0); pic.push_back(0); pic.push_back(0); pic.push_back((unsigned char)m.size());
                pic.insert(pic.end(), m.begin(), m.end());
            }
            // desc len = 0
            pic.push_back(0); pic.push_back(0); pic.push_back(0); pic.push_back(0);
            // width(4), height(4), depth(4), colors(4)
            for (int i = 0; i < 16; ++i) pic.push_back(0);
            // data len
            pic.push_back((unsigned char)((dataLenOverride >> 24) & 0xFF));
            pic.push_back((unsigned char)((dataLenOverride >> 16) & 0xFF));
            pic.push_back((unsigned char)((dataLenOverride >> 8) & 0xFF));
            pic.push_back((unsigned char)(dataLenOverride & 0xFF));
            // 4 字节图片数据
            pic.push_back(0xFF); pic.push_back(0xD8); pic.push_back(0xFF); pic.push_back(0xE0);

            const uint32_t picLen = (uint32_t)pic.size();
            b.push_back(0x86); // last=1, type=6
            b.push_back((unsigned char)((picLen >> 16) & 0xFF));
            b.push_back((unsigned char)((picLen >> 8) & 0xFF));
            b.push_back((unsigned char)(picLen & 0xFF));
            b.insert(b.end(), pic.begin(), pic.end());
            return b;
        };

        std::string reason;
        // FLAC 正常
        const auto fGood = make_flac(10, 4);
        ck(!writeback_detect_picture_malformed_bytes(fGood.data(), fGood.size(), ".flac", &reason),
           "FLAC 夹具: 正常 PICTURE 块判定为合法 (false)");

        // FLAC 空 MIME
        const auto fEmptyMime = make_flac(0, 4);
        ck(writeback_detect_picture_malformed_bytes(fEmptyMime.data(), fEmptyMime.size(), ".flac", &reason),
           "FLAC 夹具: 空 MIME 判定为畸形 (true)");
        ck(reason.find("PICTURE") != std::string::npos && reason.find("空") != std::string::npos,
           "FLAC 夹具说明写明 MIME 为空", reason);

        // FLAC 长度越界
        const auto fBadLen = make_flac(-1, 4);
        ck(writeback_detect_picture_malformed_bytes(fBadLen.data(), fBadLen.size(), ".flac", &reason),
           "FLAC 夹具: MIME 长度越界判定为畸形 (true)");
        ck(reason.find("PICTURE") != std::string::npos && reason.find("越界") != std::string::npos,
           "FLAC 夹具说明写明长度越界", reason);

        // 2. MP3 字节夹具测试 (合法 / 空 MIME / 长度越界)
        auto make_mp3 = [](int mimeMode, uint32_t frameSizeOverride) {
            std::vector<unsigned char> fData;
            fData.push_back(0); // enc = ISO-8859-1
            if (mimeMode == 0) {
                // 空 MIME: 单个 \0
                fData.push_back(0);
            } else {
                const std::string m = "image/jpeg";
                fData.insert(fData.end(), m.begin(), m.end());
                fData.push_back(0); // null terminator
            }
            fData.push_back(3); // pic type = front cover
            fData.push_back(0); // desc = \0
            fData.push_back(0xFF); fData.push_back(0xD8); fData.push_back(0xFF); fData.push_back(0xE0); // 4 字节数据

            const uint32_t fsize = (frameSizeOverride > 0) ? frameSizeOverride : (uint32_t)fData.size();
            std::vector<unsigned char> frame = { 'A', 'P', 'I', 'C' };
            frame.push_back((unsigned char)((fsize >> 24) & 0xFF));
            frame.push_back((unsigned char)((fsize >> 16) & 0xFF));
            frame.push_back((unsigned char)((fsize >> 8) & 0xFF));
            frame.push_back((unsigned char)(fsize & 0xFF));
            frame.push_back(0); frame.push_back(0); // flags
            frame.insert(frame.end(), fData.begin(), fData.end());

            const uint32_t tagSize = (uint32_t)frame.size();
            std::vector<unsigned char> full = { 'I', 'D', '3', 3, 0, 0 };
            full.push_back((unsigned char)((tagSize >> 21) & 0x7F));
            full.push_back((unsigned char)((tagSize >> 14) & 0x7F));
            full.push_back((unsigned char)((tagSize >> 7) & 0x7F));
            full.push_back((unsigned char)(tagSize & 0x7F));
            full.insert(full.end(), frame.begin(), frame.end());
            return full;
        };

        // MP3 正常
        const auto mGood = make_mp3(1, 0);
        ck(!writeback_detect_picture_malformed_bytes(mGood.data(), mGood.size(), ".mp3", &reason),
           "MP3 夹具: 正常 APIC 帧判定为合法 (false)");

        // MP3 空 MIME
        const auto mEmptyMime = make_mp3(0, 0);
        ck(writeback_detect_picture_malformed_bytes(mEmptyMime.data(), mEmptyMime.size(), ".mp3", &reason),
           "MP3 夹具: 空 MIME 判定为畸形 (true)");
        ck(reason.find("PICTURE") != std::string::npos && reason.find("空") != std::string::npos,
           "MP3 夹具说明写明 MIME 为空", reason);

        // MP3 帧长越界
        const auto mBadLen = make_mp3(1, 65536);
        ck(writeback_detect_picture_malformed_bytes(mBadLen.data(), mBadLen.size(), ".mp3", &reason),
           "MP3 夹具: 帧长越界判定为畸形 (true)");
        ck(reason.find("PICTURE") != std::string::npos && reason.find("越界") != std::string::npos,
           "MP3 夹具说明写明帧长越界", reason);

        // 3. 在 %TEMP% 造 1 正常 + 1 畸形封面文件，断言【预览计数 == 真批计数】
        const fs::path p2Box = tmp / "parity_test";
        fs::create_directories(p2Box, ec);
        const std::string normFile = meta_string_of(p2Box / "parity_normal.flac");
        const std::string badPicFile = meta_string_of(p2Box / "parity_badpic.flac");

        // 写出正常音频 FLAC（来自本测试生成的真实音频素材）
        std::vector<unsigned char> baseFlac = read_bytes(flac);
        {
            std::ofstream f(meta_path_of(normFile), std::ios::binary | std::ios::trunc);
            f.write((const char*)baseFlac.data(), (std::streamsize)baseFlac.size());
        }
        // 写出畸形封面 FLAC（在有效音频素材 STREAMINFO 之后插入畸形 PICTURE 块）
        // 2026-10-25（macOS 单平台）：素材缺失时 baseFlac 为空，badFlac.begin()+4 越界 → SIGSEGV。
        // 用 lambda 隔离这段构造：空素材时只记 FAIL 并跳过构造，不改动后面任何判据。
        [&] {
            if (baseFlac.size() <= 8) {
                ck(false, "预览/真批一致性夹具", "FLAC 素材为空，无法构造畸形封面样本");
                return;
            }
            std::vector<unsigned char> badFlac = baseFlac;
            std::vector<unsigned char> pic = {
                0x00,0x00,0x00,0x03,             // picture type = front cover
                0xFF,0xFF,0xFF,0xFF              // mime 长度字段爆掉 → 畸形
            };
            for (int i = 0; i < 32; ++i) pic.push_back(0x41);
            std::vector<unsigned char> ins;
            ins.push_back(0x06);                 // last=0, type=6(PICTURE)
            ins.push_back((unsigned char)((pic.size() >> 16) & 0xFF));
            ins.push_back((unsigned char)((pic.size() >> 8) & 0xFF));
            ins.push_back((unsigned char)(pic.size() & 0xFF));
            ins.insert(ins.end(), pic.begin(), pic.end());
            badFlac.insert(badFlac.begin() + 4, ins.begin(), ins.end());

            std::ofstream f(meta_path_of(badPicFile), std::ios::binary | std::ios::trunc);
            f.write((const char*)badFlac.data(), (std::streamsize)badFlac.size());
        }();

        // 隔离专属 MetaStore
        MetaStore& pms = MetaStore::instance();
        const std::string oldBase = pms.baseDir();
        pms.setBaseDir(meta_string_of(p2Box / "meta"));

        TrackMeta tmNorm;
        tmNorm.path = normFile;
        tmNorm.fields["title"] = { "Normal Track", "user", 1792000000, 1.0f };
        pms.save(tmNorm);

        TrackMeta tmBad;
        tmBad.path = badPicFile;
        tmBad.fields["title"] = { "Bad Picture Track", "user", 1792000000, 1.0f };
        pms.save(tmBad);

        // 预览扫描模拟（复刻 writeback_preview_scan 逻辑，使用纯容器头解析写回门）
        int prevTotal = 0, prevWritable = 0, prevSkipped = 0;
        const fs::path pTracks = meta_path_of(pms.baseDir()) / "tracks";
        for (fs::directory_iterator it(pTracks, ec), end; !ec && it != end; it.increment(ec)) {
            TrackMeta tm;
            if (!writeback_load_store_record(it->path(), tm)) continue;
            ++prevTotal;
            const std::string ext = rta::platform::lower_extension(tm.path);
            std::string why;
            if (ext == ".dsf" || ext == ".dff") why = "DSD 跳过";
            else if (!writeback_muxer(ext)) why = "不支持格式";
            else if (writeback_collect(tm, writeback_vorbis_family(ext)).empty()) why = "无可写字段";
            else if (writeback_detect_picture_malformed(tm.path, &why)) {
                // 封面畸形门拦截！
            }
            if (why.empty()) ++prevWritable;
            else ++prevSkipped;
        }

        ck(prevTotal == 2, "预览扫描总数 = 2", std::to_string(prevTotal));
        ck(prevWritable == 1, "预览可写数 = 1", std::to_string(prevWritable));
        ck(prevSkipped == 1, "预览跳过数 = 1 (畸形封面)", std::to_string(prevSkipped));

        // 真批执行（dry-run 批）
        WritebackOpts opts;
        opts.dryRun = true;
        std::string bErr;
        const BatchResult br = writeback_library(opts, &bErr);
        ck(bErr.empty(), "真批执行无硬错误", bErr);
        ck(br.total == 2, "真批总数 = 2", std::to_string(br.total));
        ck(br.written == 1, "真批写入数 = 1", std::to_string(br.written));
        ck(br.skipped == 1, "真批跳过数 = 1", std::to_string(br.skipped));
        ck(br.failed == 0, "真批失败数 = 0", std::to_string(br.failed));

        // ★ 核心断言：预览可写数 == 真批计数，跳过数对齐
        ck(prevWritable == br.written, "★ 预览可写数 == 真批计数 (1 == 1)");
        ck(prevSkipped == br.skipped, "★ 预览跳过数 == 真批跳过数 (1 == 1)");

        pms.setBaseDir(oldBase);
    }
    return g_fail == 0 ? 0 : 1;
}
