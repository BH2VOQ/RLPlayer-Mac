// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_cast_service.cpp — UPnP 媒体投放后台服务与编排单元测试 (ROADMAP P5b)
#include "net/cast_service.h"
#include "audio/wav.h"
#include <cstdio>
#include <string>
#include <vector>
#include <fstream>
#include <filesystem>
#include <thread>
#include <atomic>
#include <mutex>
#include <chrono>
#include <functional>

#ifdef _WIN32
extern "C" __declspec(dllimport) int __stdcall SetConsoleOutputCP(unsigned int);
#endif

using namespace rta::net;
namespace fs = std::filesystem;

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

// 英文字符串里出现「非 ASCII」就一定没译干净：UTF-8 三字节序列的首字节 ≥ 0xE3
// 覆盖 CJK 汉字（E4..E9）、中日韩标点（E3 80）、全角标点（EF BC）。
// 这里只看首字节，不做 UTF-8 解码 —— 判据只用来抓「英文分支里还夹着中文」，
// 不需要知道具体是哪个字。（英文文案里的 ASCII 引号/连字符都 < 0x80，不会误报。）
static bool has_cjk(const std::string& s) {
    for (unsigned char c : s) {
        if (c >= 0xE3) return true;
    }
    return false;
}

// 一条「中文 / 英文」文案对的最基本断言：中文非空、英文非空、英文不含中文。
// 铁律 3：判据要能证明「用户切到英文时不会看到中文，也不会看到空串」。
static void ck_pair(const char* what, const std::string& zh, const std::string& en,
                    const std::string& mustZh = "", const std::string& mustEn = "") {
    ck(!zh.empty(), (std::string(what) + "：中文非空").c_str(), zh);
    ck(!en.empty(), (std::string(what) + "：英文非空").c_str(), en);
    ck(!has_cjk(en), (std::string(what) + "：英文不含中文").c_str(), en);
    ck(zh != en, (std::string(what) + "：英文与中文不同").c_str(), en);
    if (!mustZh.empty())
        ck(zh.find(mustZh) != std::string::npos,
           (std::string(what) + "：中文保留关键内容 " + mustZh).c_str(), zh);
    if (!mustEn.empty())
        ck(en.find(mustEn) != std::string::npos,
           (std::string(what) + "：英文保留关键内容 " + mustEn).c_str(), en);
}

int main() {
#ifdef _WIN32
    SetConsoleOutputCP(65001);
#endif
    std::printf("=== test_cast_service: UPnP 投放后台服务与编排测试 ===\n\n");

    auto& mgr = CastManager::instance();

    // ================= 1) 初始状态契约 =================
    std::printf("-- 1. 初始状态与字段契约 --\n");
    {
        CastState st = mgr.get_state();
        ck(!st.running, "初始 running 必须为 false");
        ck(st.phase == "stopped", "初始 phase 必须为 stopped", st.phase);
        ck(st.positionSec == 0.0, "初始 positionSec 必须为 0", std::to_string(st.positionSec));
        ck(st.transportState == "STOPPED", "初始 transportState 必须为 STOPPED", st.transportState);
        ck(st.servedBytes == 0, "初始 servedBytes 必须为 0", std::to_string(st.servedBytes));
        ck(st.requestCount == 0, "初始 requestCount 必须为 0", std::to_string(st.requestCount));
        ck(st.rateMatch == "unknown", "初始 rateMatch 必须为 unknown", st.rateMatch);
        ck(st.warning.empty(), "初始 warning 为空");
        ck(st.error.empty(), "初始 error 为空");
        // 英文错误字段必须与中文同进同退：初始两者都为空
        ck(st.errorEn.empty(), "初始 errorEn 为空");
    }

    // ================= 2) 参数校验与硬安全红线 =================
    std::printf("\n-- 2. 参数校验与安全门禁 --\n");
    {
        // 2.1 空文件路径
        CastStartParams p1;
        p1.file = "";
        auto r1 = mgr.start(p1);
        ck(!r1.ok, "空文件路径被拒绝");
        ck(r1.error.find("未指定") != std::string::npos, "返回明确提示：未指定音频文件路径", r1.error);

        // 2.2 不存在的文件
        CastStartParams p2;
        p2.file = "C:\\nonexistent_test_audio_file_12345.wav";
        auto r2 = mgr.start(p2);
        ck(!r2.ok, "不存在的文件被拒绝");
        ck(r2.error.find("不存在") != std::string::npos, "返回明确提示：文件不存在", r2.error);

        // 2.3 创建临时虚拟 DSD 文件，测试未开启 DoP 时的拒绝（铁律 3）
        std::string dsfPath = "build_test_temp_cast.dsf";
        {
            std::ofstream f(dsfPath, std::ios::binary);
            f.write("DSD ", 4);
        }
        CastStartParams p3;
        p3.file = dsfPath;
        p3.dop = false;
        auto r3 = mgr.start(p3);
        ck(!r3.ok, "DSD 源文件未开启 DoP 必须被拒绝（铁律 3：绝不擅自降质重采样）");
        ck(r3.error.find("DoP") != std::string::npos && r3.error.find("DSD") != std::string::npos,
           "DSD 错误提示明确包含 DSD 与 DoP 要求", r3.error);

        // 同样测试 .dff 后缀
        std::string dffPath = "build_test_temp_cast.dff";
        {
            std::ofstream f(dffPath, std::ios::binary);
            f.write("FRM8", 4);
        }
        CastStartParams p3b;
        p3b.file = dffPath;
        p3b.dop = false;
        auto r3b = mgr.start(p3b);
        ck(!r3b.ok, ".dff 文件未开启 DoP 同样必须被拒绝");
        ck(r3b.error.find("DoP") != std::string::npos, "dff 错误提示包含 DoP", r3b.error);

        std::remove(dsfPath.c_str());
        std::remove(dffPath.c_str());
    }

    // ================= 3) 设备标识 / 发现缓存的只读查询（不做真实网络发现） =================
    //
    // 纪律：本测试**不发起任何真实发现**（不发 SSDP M-SEARCH、不跑 mDNS 浏览）。
    // 历史上这里调 get_devices(false)，缓存为空时会真的去发一轮 SSDP —— 既是未声明的
    // 网络副作用，也让「离线可跑」这个前提在无网/受限环境里不成立。
    // 现在只读缓存/诊断（last_discovery_diag），并断言 AirPlay 标识判定这一纯函数。
    std::printf("\n-- 3. 设备标识与发现缓存只读查询（无网络副作用） --\n");
    {
        // 只读：不触发扫描，仅取上一次诊断（可能为空）
        auto diag = mgr.last_discovery_diag();
        (void)diag;   // 只要求可读、不崩
        ck(true, "last_discovery_diag 只读查询正常且不触发扫描");

        ck(CastManager::is_airplay_dev("airplay://192.0.2.10:5000/synthetic"),
           "AirPlay 设备标识判定为真");
        ck(!CastManager::is_airplay_dev("http://192.0.2.10:1400/desc.xml"),
           "HTTP 描述 URL 不被误判为 AirPlay");
        std::string h;
        uint16_t p = 0;
        ck(CastManager::parse_airplay_dev("airplay://192.0.2.10:5000/synthetic", h, p) &&
               h == "192.0.2.10" && p == 5000,
           "AirPlay 标识解析出 host/port", h + ":" + std::to_string(p));

        // 注入式设备列表（离线）：只改缓存，不联网
        rta::net::AirPlayDevice synthetic;
        synthetic.id = "synthetic-1";
        synthetic.name = "Synthetic Speaker";
        synthetic.host = "192.0.2.11";
        synthetic.port = 5000;
        mgr.set_airplay_devices_for_test({synthetic});
        auto aps = mgr.get_airplay_devices(false);
        ck(aps.size() == 1 && aps[0].name == "Synthetic Speaker",
           "注入的合成 AirPlay 设备可被读取（不触发 mDNS）", std::to_string(aps.size()));
        mgr.set_airplay_devices_for_test({});
    }

    // ================= 4) 停止与回位 =================
    std::printf("\n-- 4. 停止与回位状态一致性 --\n");
    {
        bool stopped = mgr.stop();
        ck(stopped, "stop 正常返回");
        CastState st = mgr.get_state();
        ck(!st.running, "stop 后 running 状态为 false");
        ck(st.phase == "stopped", "stop 后 phase 状态为 stopped", st.phase);
    }

    // ================= 5) 错误文案：中文/英文成对，且插值真的进去了 =================
    //
    // 这一段的判据针对的是**判据本身曾经失效**的那一类缺陷：
    //   · 上一版「未找到名称/型号包含 "" + p.dev + "" 的 UPnP 渲染器」是行内拼接的字面量，
    //     测试只断言了 start() 返回 false，谁也没检查那句话里到底有没有查询串 ——
    //     所以「插值坏了/变成空引号」这类事故一路活到交付。
    //   · 英文分支同样必须可证：英文非空、不含中文、且保留同一批数值。
    // 全程不联网、不发现设备、不开音频设备（纯函数断言）。
    std::printf("\n-- 5. 错误文案（中文/英文成对，纯函数） --\n");
    {
        // 5.1 名称/型号未命中：插值必须在引号里，且不允许残留空引号对 ""
        const std::string q = "Living Room";
        const std::string zhNotFound = cast_err::dev_not_found(q);
        const std::string enNotFound = cast_err::dev_not_found_en(q);
        ck(zhNotFound.find("\"" + q + "\"") != std::string::npos,
           "中文未找到文案：查询串被引号包住且真的插值进去", zhNotFound);
        ck(enNotFound.find("\"" + q + "\"") != std::string::npos,
           "英文未找到文案：查询串被引号包住且真的插值进去", enNotFound);
        ck(zhNotFound.find("\"\"") == std::string::npos,
           "中文未找到文案：没有残留空引号对 \"\"（历史坏字面量的形态）", zhNotFound);
        ck(enNotFound.find("\"\"") == std::string::npos,
           "英文未找到文案：没有残留空引号对 \"\"", enNotFound);
        ck(zhNotFound.find("未找到名称/型号包含") == 0, "中文未找到文案：句式未被改动", zhNotFound);
        ck_pair("未找到名称/型号", zhNotFound, enNotFound, q, q);

        // 5.2 描述 URL 失败：URL 原样保留（它是用户排查的唯一线索）
        const std::string url = "http://192.0.2.10:1400/desc.xml";
        const std::string zhUrl = cast_err::dev_desc_url_failed(url);
        const std::string enUrl = cast_err::dev_desc_url_failed_en(url);
        ck(zhUrl.find(url) != std::string::npos, "中文 URL 失败文案：URL 原样保留", zhUrl);
        ck_pair("描述 URL 失败", zhUrl, enUrl, url, url);

        // 5.3 一个都没搜到 / 端口段全被占
        ck_pair("未发现渲染器", cast_err::no_renderer_found(), cast_err::no_renderer_found_en());
        const std::string zhBind = cast_err::http_server_bind_failed(8912u, 8921u);
        const std::string enBind = cast_err::http_server_bind_failed_en(8912u, 8921u);
        ck(zhBind.find("8912") != std::string::npos && zhBind.find("8921") != std::string::npos,
           "中文端口占用文案：端口段两端都在", zhBind);
        ck(enBind.find("8912") != std::string::npos && enBind.find("8921") != std::string::npos,
           "英文端口占用文案：端口段两端都在", enBind);
        ck_pair("端口占用", zhBind, enBind);

        // 5.4 解码/打包类：底层原因（可能是英文 curl/系统串）原样保留
        const std::string why = "sample rate 2822400 not supported by container";
        const std::string zhDsd = cast_err::dsd_read_invalid("/tmp/a.dsf");
        const std::string enDsd = cast_err::dsd_read_invalid_en("/tmp/a.dsf");
        ck(enDsd.find("/tmp/a.dsf") != std::string::npos, "英文 DSD 文案：文件路径原样保留", enDsd);
        ck_pair("DSD 读取失败", zhDsd, enDsd);
        ck_pair("DSD 打包失败", cast_err::dsd_pack_failed(why), cast_err::dsd_pack_failed_en(why), why, why);
        ck_pair("源 WAV 读取失败", cast_err::wav_read_failed(why), cast_err::wav_read_failed_en(why), why, why);
        ck_pair("临时 WAV 写出失败", cast_err::temp_wav_write_failed(why),
                cast_err::temp_wav_write_failed_en(why), why, why);

        // 5.5 SOAP 动作失败：底层原因自带「请求失败: 」前缀时必须去重，不许逐词翻译
        UpnpError eConn;
        eConn.code = -1;
        eConn.description = "请求失败: Couldn't connect to server";
        const std::string zhSet = cast_err::action_failed("SetAVTransportURI", eConn);
        const std::string enSet = cast_err::action_failed_en("SetAVTransportURI", eConn);
        ck(zhSet.find("SetAVTransportURI") == 0, "中文 SOAP 文案：动作名在句首", zhSet);
        ck(zhSet.find("UPnPError -1") != std::string::npos, "中文 SOAP 文案：错误码保留", zhSet);
        ck(enSet.find("Couldn't connect to server") != std::string::npos,
           "英文 SOAP 文案：底层原因原样保留", enSet);
        ck(enSet.find("请求失败") == std::string::npos, "英文 SOAP 文案：已去掉重复中文前缀", enSet);
        ck(!has_cjk(enSet), "英文 SOAP 文案：不含中文", enSet);

        // 5.6 「控制 URL 为空，无法执行 Play」是可枚举原因 → 映射成英文，而不是原样留中文
        UpnpError eNoUrl;
        eNoUrl.code = -1;
        eNoUrl.description = "控制 URL 为空，无法执行 Play";
        const std::string enPlay = cast_err::action_failed_en("Play", eNoUrl);
        ck(enPlay.find("control URL is empty") != std::string::npos,
           "英文 Play 失败文案：控制 URL 为空已映射为英文", enPlay);
        ck(enPlay.find("Play") != std::string::npos, "英文 Play 失败文案：动作名保留", enPlay);
        ck(!has_cjk(enPlay), "英文 Play 失败文案：不含中文", enPlay);
        // 无错误时 str() 返回 "OK"，英文分支也不能崩/不能空
        UpnpError eOk;
        ck(cast_err::action_failed_en("Play", eOk).find("Play") != std::string::npos,
           "英文 SOAP 文案：无底层错误时仍给出动作名", cast_err::action_failed_en("Play", eOk));

        // 5.7 前缀去重：只剥可枚举前缀，不碰原因本体
        ck(cast_err::strip_dup_cn_prefix("请求失败: timeout") == "timeout",
           "前缀去重：多个已知前缀", cast_err::strip_dup_cn_prefix("请求失败: timeout"));
        ck(cast_err::strip_dup_cn_prefix("timeout") == "timeout",
           "前缀去重：无前缀时原样返回", cast_err::strip_dup_cn_prefix("timeout"));
        ck(cast_err::strip_dup_cn_prefix("请求失败") == "",
           "前缀去重：只有前缀时返回空（调用方必须回落整句）",
           cast_err::strip_dup_cn_prefix("请求失败"));

        // 5.8 底层只给了「请求失败」前缀、没给原因：英文分支必须写 no detail，而不是空括号
        UpnpError eBare;
        eBare.code = -1;
        eBare.description = "请求失败";
        const std::string enBare = cast_err::action_failed_en("Play", eBare);
        ck(enBare.find("no detail") != std::string::npos, "英文 SOAP 文案：无原因时写 no detail", enBare);
        ck(enBare.find("()") == std::string::npos, "英文 SOAP 文案：不输出空括号", enBare);
        ck(!has_cjk(enBare), "英文 SOAP 文案：无原因分支不含中文", enBare);

        // 5.9 本地底层中文异常（read_wav/DSD）结构化映射为英文，保留路径与数值且不残留中文
        const std::string realBadWavWhy = "不是合法的 WAV 文件(文件=/home/user/music/坏 WAV 用户路径.wav, 实际字节=17, 需 RIFF/WAVE 头且≥44 字节)";
        const std::string enBadWav = cast_err::wav_read_failed_en(realBadWavWhy);
        ck(enBadWav.find("Failed to read the source WAV: not a valid WAV file") != std::string::npos,
           "真实 read_wav 非法头异常成功映射为英文", enBadWav);
        ck(enBadWav.find("/home/user/music/坏 WAV 用户路径.wav") != std::string::npos,
           "真实 read_wav 异常文件路径完整保留", enBadWav);
        ck(enBadWav.find("actual bytes=17") != std::string::npos && enBadWav.find(">= 44 bytes") != std::string::npos,
           "真实 read_wav 异常关键数值准确保留", enBadWav);

        const std::string realTruncWavWhy = "WAV data 块被截断(声明 dataLen=88200 字节, 块体实际可用=4 字节)(文件=/tmp/trunc.wav, fmtTag=1, ch=1, bps=16, rate=44100, dataLen=0, 实际文件字节=48)";
        const std::string enTruncWav = cast_err::wav_read_failed_en(realTruncWavWhy);
        ck(enTruncWav.find("data chunk truncated") != std::string::npos, "截断 WAV 异常结构化映射为英文", enTruncWav);
        ck(enTruncWav.find("declared dataLen=88200 bytes") != std::string::npos && enTruncWav.find("chunk body available=4 bytes") != std::string::npos,
           "截断 WAV 异常数值保留", enTruncWav);
        ck(!has_cjk(enTruncWav), "截断 WAV 英文文案不含中文", enTruncWav);

        const std::string realDsfWhy = "不是 DSF 文件（缺少 \"DSD \" 头）: /tmp/bad.dsf";
        const std::string enDsf = cast_err::dsd_pack_failed_en(realDsfWhy);
        ck(enDsf.find("not a DSF file") != std::string::npos, "DSF 异常结构化映射为英文", enDsf);
        ck(enDsf.find("/tmp/bad.dsf") != std::string::npos, "DSF 异常路径保留", enDsf);
        ck(!has_cjk(enDsf), "DSF 英文文案不含中文", enDsf);
    }

    // ================= 5b) 纯函数：可听位置（含 2^32 回绕）与自然结束判据 =================
    //
    // 这两条是「判据本身最容易写错」的地方，所以抽成纯函数单独断言：
    //   · 可听位置 = current − latency，且差值必须是模 2^32 的；用 `current >= start` 判断
    //     在时间戳回绕后永久失效（一首歌播不到 27 小时测不出来，但纯函数能测）。
    //   · 自然结束 = finish 成功 ∧ 全部源帧已发 ∧ 未被 stop；历史实现漏掉第一条。
    std::printf("\n-- 5b. 可听位置（模 2^32）与自然结束判据（纯函数） --\n");
    {
        const uint32_t kLat = 88200;
        const uint32_t base = 1000;
        ck(cast_audible_frames(base, base, kLat) == 0, "刚起播：可听位置为 0（latency 未走完）");
        ck(cast_audible_frames(base + kLat / 2, base, kLat) == 0, "latency 未走完前一律为 0（不报负进度）");
        ck(cast_audible_frames(base + kLat, base, kLat) == 0, "恰好走完 latency：可听位置仍为 0");
        ck(cast_audible_frames(base + kLat + 5000, base, kLat) == 5000,
           "可听位置 = (current − start) − latency",
           std::to_string(cast_audible_frames(base + kLat + 5000, base, kLat)));
        ck(cast_audible_frames(base + kLat + 5000, base, 0) == kLat + 5000,
           "latency=0 时可听位置等于源时钟差");

        // 回绕：start 靠近 2^32 顶端，current 已经绕到低地址；差值仍是 0x20000 帧
        const uint32_t wrapBase = 0xFFFFFF00u;                    // start
        const uint32_t wrapCurrent = 0x00010000u;                 // 已回绕：数值上 < start
        const uint64_t wrapElapsed = static_cast<uint32_t>(wrapCurrent - wrapBase);  // 0x10100 = 65792
        ck(wrapElapsed == 65792u, "回绕后模 2^32 差值 = 65792 帧（不是 0）", std::to_string(wrapElapsed));
        ck(cast_audible_frames(wrapCurrent, wrapBase, 0) == wrapElapsed,
           "回绕后 latency=0 的可听位置正确（`current>=start` 写法在这里会得 0）",
           std::to_string(cast_audible_frames(wrapCurrent, wrapBase, 0)));
        ck(cast_audible_frames(wrapCurrent, wrapBase, 88200) == 0,
           "回绕 + latency 未走完：钳到 0，不产生天文数字");

        // 自然结束判据：三者必须同时成立
        ck(cast_natural_end(true, true, false), "finish 成功 + 全部发出 + 未停止 ⟹ 自然结束");
        ck(!cast_natural_end(false, true, false), "finish 失败 ⟹ 绝不报自然结束（历史漏洞）");
        ck(!cast_natural_end(true, false, false), "未发出全部帧 ⟹ 不报自然结束");
        ck(!cast_natural_end(true, true, true), "用户 stop ⟹ 不报自然结束");
        ck(!cast_natural_end(false, true, true), "finish 失败 + 用户 stop ⟹ 不报自然结束");
    }

    // ================= 6) Loopback Mock UPnP AVTransport 生命周期与 endedNaturally 契约测试 =================
    std::printf("\n-- 6. Loopback Mock UPnP AVTransport 生命周期与 endedNaturally 契约测试 --\n");
    enum class MockMode {
        NormalNaturalEnd = 0, // Play 时拉流 + PLAYING 保持 350ms 后转 STOPPED
        ContinuousPlay   = 1, // Play 时拉流 + 始终保持 PLAYING（供测试主动 stop）
        BogusStopped     = 2  // Play 时不拉流 + 状态始终保持 STOPPED（未起播即 STOPPED）
    };

    class LoopbackMockUpnpRenderer {
    public:
        ~LoopbackMockUpnpRenderer() { stop(); }

        bool start() {
            if (!upnp_os::wsa_init()) return false;
            wsaStarted_ = true;
            listen_ = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (listen_ == upnp_os::kInvalidSocket) return false;
            int yes = 1;
            upnp_os::set_opt(listen_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

            sockaddr_in a{};
            a.sin_family = AF_INET;
            a.sin_port = htons(0);
            a.sin_addr.s_addr = ::inet_addr("127.0.0.1");
            if (upnp_os::io_bind(listen_, (sockaddr*)&a, sizeof(a)) != 0) {
                upnp_os::close_socket(listen_);
                listen_ = upnp_os::kInvalidSocket;
                return false;
            }
            if (upnp_os::io_listen(listen_, 16) != 0) {
                upnp_os::close_socket(listen_);
                listen_ = upnp_os::kInvalidSocket;
                return false;
            }
            sockaddr_in got{};
            int gl = sizeof(got);
            if (upnp_os::io_getsockname(listen_, (sockaddr*)&got, &gl) != 0) {
                upnp_os::close_socket(listen_);
                listen_ = upnp_os::kInvalidSocket;
                return false;
            }
            port_ = ntohs(got.sin_port);
            stop_.store(false);
            th_ = std::thread([this]() { accept_loop(); });
            return port_ > 0;
        }

        void stop() {
            stop_.store(true);
            if (listen_ != upnp_os::kInvalidSocket) {
                upnp_os::close_socket(listen_);
                listen_ = upnp_os::kInvalidSocket;
            }
            if (th_.joinable()) th_.join();
            if (wsaStarted_) {
                upnp_os::wsa_cleanup();
                wsaStarted_ = false;
            }
        }

        uint16_t port() const { return port_; }

        void reset_mode(MockMode m) {
            std::lock_guard<std::mutex> lk(mu_);
            mode_ = m;
            currentUri_.clear();
            playStarted_ = false;
            sink_ = "http-get:*:audio/wav:*";
        }

        void set_sink(const std::string& sink) {
            std::lock_guard<std::mutex> lk(mu_);
            sink_ = sink;
        }

        std::string get_current_uri() {
            std::lock_guard<std::mutex> lk(mu_);
            return currentUri_;
        }

    private:
        static void fetch_stream_once(const std::string& uri) {
            if (uri.rfind("http://", 0) != 0) return;
            const size_t hs = 7;
            const size_t slash = uri.find('/', hs);
            const std::string hostport = uri.substr(hs, (slash == std::string::npos ? uri.size() : slash) - hs);
            const std::string path = (slash == std::string::npos) ? "/" : uri.substr(slash);
            const size_t colon = hostport.find(':');
            const std::string host = (colon == std::string::npos) ? hostport : hostport.substr(0, colon);
            const int port = (colon == std::string::npos) ? 80 : std::atoi(hostport.substr(colon + 1).c_str());
            std::string dummyOut;
            // 只走 loopback 拉取本地 UpnpHttpServer 的静音 WAV 流
            (void)upnp_detail::http_get("127.0.0.1", port, path, dummyOut, 0, 1000);
        }

        static void send_http(upnp_os::socket_t c, const std::string& body) {
            char hdr[256];
            std::snprintf(hdr, sizeof(hdr),
                          "HTTP/1.1 200 OK\r\n"
                          "Content-Type: text/xml; charset=\"utf-8\"\r\n"
                          "Content-Length: %zu\r\n"
                          "Connection: close\r\n\r\n",
                          body.size());
            upnp_os::io_send(c, hdr, (int)std::strlen(hdr));
            if (!body.empty()) {
                upnp_os::io_send(c, body.data(), (int)body.size());
            }
        }

        void handle_conn(upnp_os::socket_t c) {
            upnp_os::set_timeout(c, SO_RCVTIMEO, 2000);
            upnp_os::set_timeout(c, SO_SNDTIMEO, 2000);

            std::string req;
            char buf[4096];
            size_t hdrEnd = std::string::npos;
            size_t contentLen = 0;

            while (req.size() < 65536) {
                int r = upnp_os::io_recv(c, buf, sizeof(buf));
                if (r <= 0) break;
                req.append(buf, (size_t)r);
                if (hdrEnd == std::string::npos) {
                    hdrEnd = req.find("\r\n\r\n");
                    if (hdrEnd != std::string::npos) {
                        std::string clStr = upnp_detail::header_of(req.substr(0, hdrEnd), "content-length");
                        if (!clStr.empty()) contentLen = (size_t)std::strtoul(clStr.c_str(), nullptr, 10);
                    }
                }
                if (hdrEnd != std::string::npos && req.size() >= hdrEnd + 4 + contentLen) {
                    break;
                }
            }

            if (req.rfind("GET /desc.xml", 0) == 0) {
                const std::string descXml =
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
                    "<root xmlns=\"urn:schemas-upnp-org:device-1-0\">"
                    "<device>"
                    "<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>"
                    "<friendlyName>LoopbackMockRenderer</friendlyName>"
                    "<modelName>RLPlayerMock</modelName>"
                    "<UDN>uuid:rlplayer-mock-cast-renderer</UDN>"
                    "<serviceList>"
                    "<service>"
                    "<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>"
                    "<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>"
                    "<controlURL>/upnp/control/AVTransport1</controlURL>"
                    "</service>"
                    "</serviceList>"
                    "</device>"
                    "</root>";
                send_http(c, descXml);
                upnp_os::close_socket(c);
                return;
            }

            const std::string soapAction = upnp_detail::header_of(req, "SOAPAction");
            const std::string body = (hdrEnd != std::string::npos) ? req.substr(hdrEnd + 4) : req;
            auto has_action = [&](const char* act) {
                return soapAction.find(act) != std::string::npos ||
                       body.find(std::string("<u:") + act) != std::string::npos;
            };

            if (has_action("SetAVTransportURI")) {
                std::string uri = xml_unescape(xml_extract_tag(body, "CurrentURI"));
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    currentUri_ = uri;
                }
                send_http(c, build_soap_envelope(kServiceAVTransport, "SetAVTransportURIResponse", {}));
            } else if (has_action("Play")) {
                std::string uriToFetch;
                MockMode m;
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    m = mode_;
                    if (m != MockMode::BogusStopped) {
                        uriToFetch = currentUri_;
                        playStarted_ = true;
                        playStartTp_ = std::chrono::steady_clock::now();
                    }
                }
                if (!uriToFetch.empty()) {
                    fetch_stream_once(uriToFetch);
                }
                send_http(c, build_soap_envelope(kServiceAVTransport, "PlayResponse", {}));
            } else if (has_action("GetTransportInfo")) {
                std::string stateStr = "STOPPED";
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    if (mode_ == MockMode::ContinuousPlay) {
                        stateStr = playStarted_ ? "PLAYING" : "STOPPED";
                    } else if (mode_ == MockMode::NormalNaturalEnd) {
                        if (playStarted_) {
                            double ms = std::chrono::duration<double, std::milli>(
                                std::chrono::steady_clock::now() - playStartTp_).count();
                            stateStr = (ms < 350.0) ? "PLAYING" : "STOPPED";
                        } else {
                            stateStr = "STOPPED";
                        }
                    } else {
                        // BogusStopped: 假停模式下始终返回 STOPPED
                        stateStr = "STOPPED";
                    }
                }
                send_http(c, build_soap_envelope(kServiceAVTransport, "GetTransportInfoResponse", {
                    {"CurrentTransportState", stateStr},
                    {"CurrentTransportStatus", "OK"},
                    {"CurrentSpeed", "1"}
                }));
            } else if (has_action("GetPositionInfo")) {
                std::string uri;
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    uri = currentUri_;
                }
                send_http(c, build_soap_envelope(kServiceAVTransport, "GetPositionInfoResponse", {
                    {"Track", "1"},
                    {"TrackDuration", "00:00:01"},
                    {"TrackMetaData", ""},
                    {"TrackURI", xml_escape(uri)},
                    {"RelTime", "00:00:00"},
                    {"AbsTime", "00:00:00"}
                }));
            } else if (has_action("GetMediaInfo")) {
                std::string uri;
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    uri = currentUri_;
                }
                send_http(c, build_soap_envelope(kServiceAVTransport, "GetMediaInfoResponse", {
                    {"NrTracks", "1"},
                    {"MediaDuration", "00:00:01"},
                    {"CurrentURI", xml_escape(uri)},
                    {"CurrentURIMetaData", ""},
                    {"NextURI", ""}
                }));
            } else if (has_action("Stop")) {
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    playStarted_ = false;
                }
                send_http(c, build_soap_envelope(kServiceAVTransport, "StopResponse", {}));
            } else {
                std::string currentSink;
                {
                    std::lock_guard<std::mutex> lk(mu_);
                    currentSink = sink_;
                }
                send_http(c, build_soap_envelope(kServiceConnectionManager, "GetProtocolInfoResponse", {
                    {"Source", ""},
                    {"Sink", currentSink}
                }));
            }

            upnp_os::close_socket(c);
        }

        void accept_loop() {
            while (!stop_.load()) {
                sockaddr_in cli{};
                int clen = sizeof(cli);
                upnp_os::socket_t c = upnp_os::io_accept(listen_, (sockaddr*)&cli, &clen);
                if (c == upnp_os::kInvalidSocket) {
                    if (stop_.load()) break;
                    const int e = upnp_os::last_error();
                    if (e == EBADF || e == EINVAL || e == ENOTSOCK) break;
                    continue;
                }
                handle_conn(c);
            }
        }

        upnp_os::socket_t listen_ = upnp_os::kInvalidSocket;
        uint16_t port_ = 0;
        bool wsaStarted_ = false;
        std::atomic<bool> stop_{true};
        std::thread th_;

        std::mutex mu_;
        MockMode mode_ = MockMode::NormalNaturalEnd;
        std::string currentUri_;
        std::string sink_ = "http-get:*:audio/wav:*";
        bool playStarted_ = false;
        std::chrono::steady_clock::time_point playStartTp_{};
    };

    {

        // 生成 0.35 秒全零静音（≤ -60 dBFS）临时 WAV 文件（44100 Hz, 16-bit, 2ch）
        const std::string silentWavPath = make_cast_temp_wav_path("mock_silent_test");
        {
            rta::audio::AudioBuffer ab;
            ab.rate = 44100;
            ab.channels = 2;
            ab.bits = 16;
            ab.isFloat = false;
            const size_t frames = (size_t)(44100 * 0.35);
            ab.raw.assign(frames * 2u, 0); // 全零静音
            rta::audio::write_wav(silentWavPath, ab);
        }

        LoopbackMockUpnpRenderer mock;
        const bool mockStarted = mock.start();
        ck(mockStarted, "Loopback Mock UPnP Renderer 启动成功 (127.0.0.1 随机端口)",
           "port=" + std::to_string(mock.port()));

        if (mockStarted) {
            const std::string descUrl = "http://127.0.0.1:" + std::to_string(mock.port()) + "/desc.xml";

            // 判据 1：初始状态 st.endedNaturally == false
            {
                CastState st0 = mgr.get_state();
                ck(!st0.endedNaturally, "初始状态 endedNaturally 必须为 false");
            }

            // 判据 2：自然播完（正常模式下 Play 拉流 + 350ms PLAYING 后转 STOPPED）
            {
                mock.reset_mode(MockMode::NormalNaturalEnd);
                CastStartParams cp;
                cp.dev = descUrl;
                cp.file = silentWavPath;
                cp.port = 19220;
                CastStartResult sr = mgr.start(cp);
                ck(sr.ok, "正常模式 start() 成功", sr.error);

                auto t0 = std::chrono::steady_clock::now();
                while (mgr.get_state().running) {
                    double waited = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                    if (waited > 5.0) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(30));
                }
                CastState st = mgr.get_state();
                if (st.running) mgr.stop();
                ck(!st.running, "自然播完后会话自动结束 (!running)");
                ck(st.endedNaturally, "自然播完后 endedNaturally 必须为 true");
                ck(st.error.empty(), "自然播完后 error 为空", st.error);
                ck(st.servedBytes > 0, "自然播完时 UpnpHttpServer 已供源字节 > 0",
                   "servedBytes=" + std::to_string(st.servedBytes));
            }

            // 判据 3：主动停止（持续播放模式下等到 phase == "playing" 后调用 mgr.stop()）
            {
                mock.reset_mode(MockMode::ContinuousPlay);
                CastStartParams cp;
                cp.dev = descUrl;
                cp.file = silentWavPath;
                cp.port = 19220;
                CastStartResult sr = mgr.start(cp);
                ck(sr.ok, "持续播放模式 start() 成功", sr.error);

                auto t0 = std::chrono::steady_clock::now();
                while (mgr.get_state().running && mgr.get_state().phase != "playing") {
                    double waited = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                    if (waited > 5.0) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
                ck(mgr.get_state().phase == "playing", "持续播放模式进入 playing 阶段", mgr.get_state().phase);
                mgr.stop();
                CastState st = mgr.get_state();
                ck(!st.running, "主动 stop() 后 running 为 false");
                ck(!st.endedNaturally, "主动 stop() 后 endedNaturally 必须为 false");
            }

            // 判据 4：未起播即 STOPPED（防死循环保护：从未进 PLAYING 且 servedBytes == 0）
            {
                mock.reset_mode(MockMode::BogusStopped);
                CastStartParams cp;
                cp.dev = descUrl;
                cp.file = silentWavPath;
                cp.port = 19220;
                CastStartResult sr = mgr.start(cp);
                ck(sr.ok, "假停模式 start() 成功", sr.error);

                auto t0 = std::chrono::steady_clock::now();
                while (mgr.get_state().running) {
                    double waited = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                    if (waited > 5.0) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(30));
                }
                CastState st = mgr.get_state();
                if (st.running) mgr.stop();
                ck(!st.running, "假停模式下超过 2s 未起播后会话自动退出 (!running)");
                ck(st.servedBytes == 0, "假停模式下 servedBytes == 0", std::to_string(st.servedBytes));
                ck(!st.endedNaturally, "未起播即 STOPPED 时 endedNaturally 必须为 false（防死循环切歌）");
            }
        }

        // 5. 清理临时 WAV 文件与 Mock 线程
        mock.stop();
        std::remove(silentWavPath.c_str());
    }

    // ================= 7) Loopback Mock AirPlay (RAOP) 完整端到端生命周期 =================
    std::printf("\n-- 7. Loopback Mock AirPlay (RAOP) 生命周期契约与捕获测试 --\n");
    {
        // 构造简单的假 RAOP 接收端，监听 127.0.0.1 随机端口
        struct MiniRaopReceiver {
            int listenFd = -1;
            uint16_t port = 0;
            int audioFd = -1;
            uint16_t audioPort = 0;
            int controlFd = -1;
            uint16_t controlPort = 0;
            int timingFd = -1;
            uint16_t timingPort = 0;

            std::atomic<bool> stop{false};
            std::thread acceptTh;
            std::thread udpTh;

            // 接收端播放缓冲（帧）＝ RECORD 回包里的 Audio-Latency。
            // 2 s = RaopSession::kRaopDefaultLatencyFrames：必须与发送端用于进度/排空的时间轴**同一个数**，
            // 否则测的是两套不同的假设（旧测试只数包，根本发现不了这件事）。
            uint32_t latencyFrames = 88200;
            // 发送端 prebuffer（协议层默认 0.35 s）：决定 RTP 时间轴何时真正开始走。
            uint32_t prebufferFrames = 15435;
            // 让 SET_PARAMETER volume 返回 453：验证「初始音量失败必须在发声前中止」。
            std::atomic<bool> failVolume{false};

            std::mutex mtx;
            std::vector<std::string> rtspMethods;
            std::vector<std::string> rtspBodies;
            size_t audioPackets = 0;
            size_t controlPackets = 0;
            bool recorded = false;
            std::chrono::steady_clock::time_point recordTp{};

            size_t audio_packet_count() {
                std::lock_guard<std::mutex> lk(mtx);
                return audioPackets;
            }
            size_t control_packet_count() {
                std::lock_guard<std::mutex> lk(mtx);
                return controlPackets;
            }
            bool saw_method(const std::string& m) {
                std::lock_guard<std::mutex> lk(mtx);
                for (const auto& x : rtspMethods) if (x == m) return true;
                return false;
            }
            // 假接收端的**播放模型**（不是包计数）：
            //   RTP 时间轴自 RECORD 起 +prebuffer 开始走，对端再压一个 latency 才轮到第一个样本出声；
            //   之后按 1× 速率推进。已收帧数是上限（喂不满就播不满）。
            // 用它断言「发送端真的等到了可听终点」，而不是只等到「包都发完了」。
            double model_audible_frames(std::chrono::steady_clock::time_point now) {
                std::lock_guard<std::mutex> lk(mtx);
                if (!recorded) return 0.0;
                const double elapsed = std::chrono::duration<double>(now - recordTp).count();
                const double delay =
                    static_cast<double>(latencyFrames) + static_cast<double>(prebufferFrames);
                const double advanced = std::max(0.0, elapsed * 44100.0 - delay);
                const double received = static_cast<double>(audioPackets) * 352.0;
                return std::min(advanced, received);
            }
            bool recorded_once() {
                std::lock_guard<std::mutex> lk(mtx);
                return recorded;
            }
            // 每个子用例开头清一次捕获：判据里会断言「这次一条音频都没发」之类的绝对数量。
            void reset_capture() {
                std::lock_guard<std::mutex> lk(mtx);
                rtspMethods.clear();
                rtspBodies.clear();
                audioPackets = 0;
                controlPackets = 0;
                recorded = false;
                recordTp = std::chrono::steady_clock::time_point{};
            }

            static int bind_udp_random(uint16_t& p) {
                int s = ::socket(AF_INET, SOCK_DGRAM, 0);
                if (s < 0) return -1;
                sockaddr_in a{};
                a.sin_family = AF_INET;
                a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                a.sin_port = 0;
                if (::bind(s, (sockaddr*)&a, sizeof(a)) < 0) { ::close(s); return -1; }
                socklen_t len = sizeof(a);
                ::getsockname(s, (sockaddr*)&a, &len);
                p = ntohs(a.sin_port);
                return s;
            }

            bool start() {
                listenFd = ::socket(AF_INET, SOCK_STREAM, 0);
                if (listenFd < 0) return false;
                int one = 1;
                ::setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
                sockaddr_in a{};
                a.sin_family = AF_INET;
                a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                a.sin_port = 0;
                if (::bind(listenFd, (sockaddr*)&a, sizeof(a)) < 0) return false;
                socklen_t len = sizeof(a);
                ::getsockname(listenFd, (sockaddr*)&a, &len);
                port = ntohs(a.sin_port);
                if (::listen(listenFd, 8) < 0) return false;

                audioFd = bind_udp_random(audioPort);
                controlFd = bind_udp_random(controlPort);
                timingFd = bind_udp_random(timingPort);
                if (audioFd < 0 || controlFd < 0 || timingFd < 0) return false;

                acceptTh = std::thread([this]() {
                    while (!stop.load()) {
                        pollfd pfd{};
                        pfd.fd = listenFd;
                        pfd.events = POLLIN;
                        if (::poll(&pfd, 1, 20) <= 0) continue;
                        sockaddr_in ca{};
                        socklen_t cl = sizeof(ca);
                        int c = ::accept(listenFd, (sockaddr*)&ca, &cl);
                        if (c < 0) continue;

                        std::thread([this, c]() {
                            char buf[4096];
                            std::string inBuf;
                            while (!stop.load()) {
                                pollfd cfd{};
                                cfd.fd = c;
                                cfd.events = POLLIN;
                                if (::poll(&cfd, 1, 20) <= 0) continue;
                                ssize_t n = ::recv(c, buf, sizeof(buf), 0);
                                if (n <= 0) break;
                                inBuf.append(buf, n);

                                size_t pos = 0;
                                while ((pos = inBuf.find("\r\n\r\n")) != std::string::npos) {
                                    std::string req = inBuf.substr(0, pos + 4);
                                    inBuf.erase(0, pos + 4);

                                    std::string method;
                                    size_t sp = req.find(' ');
                                    if (sp != std::string::npos) method = req.substr(0, sp);

                                    std::string cseq = "1";
                                    size_t csp = req.find("CSeq: ");
                                    if (csp != std::string::npos) {
                                        size_t cr = req.find("\r\n", csp);
                                        cseq = req.substr(csp + 6, cr - (csp + 6));
                                    }

                                    std::string clenStr;
                                    size_t clp = req.find("Content-Length: ");
                                    if (clp != std::string::npos) {
                                        size_t cr = req.find("\r\n", clp);
                                        clenStr = req.substr(clp + 16, cr - (clp + 16));
                                    }
                                    size_t clen = clenStr.empty() ? 0 : std::stoul(clenStr);
                                    std::string body;
                                    if (clen > 0) {
                                        while (inBuf.size() < clen && !stop.load()) {
                                            ssize_t rn = ::recv(c, buf, sizeof(buf), 0);
                                            if (rn <= 0) break;
                                            inBuf.append(buf, rn);
                                        }
                                        if (inBuf.size() >= clen) {
                                            body = inBuf.substr(0, clen);
                                            inBuf.erase(0, clen);
                                        }
                                    }

                                    {
                                        std::lock_guard<std::mutex> lk(mtx);
                                        rtspMethods.push_back(method);
                                        if (!body.empty()) rtspBodies.push_back(body);
                                    }

                                    // 可注入的 SET_PARAMETER volume 失败：发送端必须据此在发声前中止。
                                    const bool volFail = (method == "SET_PARAMETER") &&
                                                         failVolume.load() &&
                                                         body.find("volume:") != std::string::npos;

                                    std::ostringstream resp;
                                    if (volFail) {
                                        resp << "RTSP/1.0 453 Not Enough Bandwidth\r\nCSeq: " << cseq << "\r\n";
                                    } else {
                                        resp << "RTSP/1.0 200 OK\r\nCSeq: " << cseq << "\r\n";
                                    }
                                    if (!volFail) {
                                        if (method == "SETUP") {
                                            resp << "Transport: RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;"
                                                 << "server_port=" << audioPort << ";control_port=" << controlPort
                                                 << ";timing_port=" << timingPort << "\r\n"
                                                 << "Session: 11223344\r\n";
                                        } else if (method == "RECORD") {
                                            resp << "Audio-Latency: " << latencyFrames << "\r\n"
                                                 << "Session: 11223344\r\n";
                                            std::lock_guard<std::mutex> lk(mtx);
                                            recorded = true;
                                            recordTp = std::chrono::steady_clock::now();
                                        }
                                    }
                                    resp << "\r\n";
                                    std::string s = resp.str();
                                    ::send(c, s.data(), s.size(), 0);
                                }
                            }
                            ::close(c);
                        }).detach();
                    }
                });

                udpTh = std::thread([this]() {
                    pollfd pfds[2]{};
                    pfds[0].fd = audioFd; pfds[0].events = POLLIN;
                    pfds[1].fd = controlFd; pfds[1].events = POLLIN;
                    uint8_t ubuf[4096];
                    while (!stop.load()) {
                        if (::poll(pfds, 2, 20) <= 0) continue;
                        if (pfds[0].revents & POLLIN) {
                            sockaddr_storage from{};
                            socklen_t flen = sizeof(from);
                            ssize_t n = ::recvfrom(audioFd, ubuf, sizeof(ubuf), 0, (sockaddr*)&from, &flen);
                            if (n > 0) {
                                std::lock_guard<std::mutex> lk(mtx);
                                audioPackets++;
                            }
                        }
                        if (pfds[1].revents & POLLIN) {
                            sockaddr_storage from{};
                            socklen_t flen = sizeof(from);
                            ssize_t n = ::recvfrom(controlFd, ubuf, sizeof(ubuf), 0, (sockaddr*)&from, &flen);
                            if (n > 0) {
                                std::lock_guard<std::mutex> lk(mtx);
                                controlPackets++;
                            }
                        }
                    }
                });
                return true;
            }

            void shutdown() {
                stop.store(true);
                if (acceptTh.joinable()) acceptTh.join();
                if (udpTh.joinable()) udpTh.join();
                if (listenFd >= 0) { ::close(listenFd); listenFd = -1; }
                if (audioFd >= 0) { ::close(audioFd); audioFd = -1; }
                if (controlFd >= 0) { ::close(controlFd); controlFd = -1; }
                if (timingFd >= 0) { ::close(timingFd); timingFd = -1; }
            }
        };

        MiniRaopReceiver raopMock;
        ck(raopMock.start(), "MiniRaopReceiver 假接收端本地启动成功");

        // 构造 0.2 秒静音 WAV（44100 / 16 / 2）。全零 ⟹ 即使有人误开设备也完全无声（铁律 1）。
        // 时长选短是因为真实协议默认播放缓冲 = 2 s（kRaopDefaultLatencyFrames）：
        // 自然结束必须等到「可听终点」= prebuffer 0.35 s + latency 2 s + 时长，一个用例 ≈ 2.6 s。
        const std::string apWavPath = make_cast_temp_wav_path("raop_test");
        const size_t kTotalFrames = 8820;                          // 0.2 s
        const size_t kTotalPackets = (kTotalFrames + 351) / 352;   // 26（含 EOS 补齐包）
        const double kDurationSec = static_cast<double>(kTotalFrames) / 44100.0;
        const double kLatencySec = static_cast<double>(raopMock.latencyFrames) / 44100.0;
        const double kPrebufferSec = static_cast<double>(raopMock.prebufferFrames) / 44100.0;
        const double kNominalEndSec = kPrebufferSec + kLatencySec + kDurationSec;
        {
            rta::audio::AudioBuffer ab;
            ab.rate = 44100;
            ab.channels = 2;
            ab.bits = 16;
            ab.isFloat = false;
            ab.raw.assign(kTotalFrames * 2, 0);
            rta::audio::write_wav(apWavPath, ab);
        }

        auto now_tp = []() { return std::chrono::steady_clock::now(); };
        auto secs_since = [](std::chrono::steady_clock::time_point t0) {
            return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        };
        auto wait_until = [&](const std::function<bool()>& pred, double timeoutSec) -> bool {
            auto t0 = now_tp();
            while (!pred()) {
                if (secs_since(t0) > timeoutSec) return false;
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            return true;
        };
        auto wait_session_end = [&](double timeoutSec) -> bool {
            return wait_until([]() { return !CastManager::instance().get_state().running; }, timeoutSec);
        };
        auto airplay_dev_url = [&](const char* extra) {
            return "airplay://127.0.0.1:" + std::to_string(raopMock.port) + "/spk" + (extra ? extra : "");
        };

        // ─────────────────────────────────────────────────────────────────────
        // 7.1 预检：密码 / 只支持加密 / 不支持 ALAC / 仅公布 pk= / 显式 enc=1 / DoP
        // ─────────────────────────────────────────────────────────────────────
        // 需要密码的设备
        {
            raopMock.reset_capture();
            CastStartParams cp;
            cp.dev = airplay_dev_url("?pw=1");
            cp.file = apWavPath;
            auto sr = mgr.start(cp);
            ck(sr.ok, "密码设备：start() 接收请求并在后台 worker 中做预检");
            wait_session_end(3.0);
            auto st = mgr.get_state();
            if (st.running) mgr.stop();
            ck(st.phase == "error", "密码设备预检进入 error phase", st.phase);
            ck(st.error.find("密码") != std::string::npos, "正确报出不支持密码提示", st.error);
            ck(raopMock.audio_packet_count() == 0, "密码设备在发任何音频之前就被拒绝",
               std::to_string(raopMock.audio_packet_count()));
        }

        // 只支持加密（et 明确不含明文 0）＋ 同时公布 pk=：
        // 判定必须看 needsEncryption（et），不能把「有 pk=」当成「必须加密」，也不能漏掉真要求。
        {
            raopMock.reset_capture();
            AirPlayDevice encOnly;
            encOnly.id = "synthetic-enc-only";
            encOnly.name = "Synthetic Enc Only";
            encOnly.host = "127.0.0.1";
            encOnly.port = raopMock.port;
            encOnly.password = false;
            encOnly.supportsPlaintext = false;
            encOnly.needsEncryption = true;
            encOnly.hasPublicKey = true;
            encOnly.supportsAlac = true;
            mgr.set_airplay_devices_for_test({encOnly});

            CastStartParams cp;
            cp.dev = airplay_dev_url("");
            cp.file = apWavPath;
            auto sr = mgr.start(cp);
            ck(sr.ok, "加密专用设备：start() 成功受理（判定在 worker 预检）");
            wait_session_end(3.0);
            auto st = mgr.get_state();
            if (st.running) mgr.stop();
            ck(st.phase == "error", "只支持加密（et 无 0）的接收端被拒绝", st.phase + " / " + st.error);
            ck(st.error.find("加密") != std::string::npos, "错误文案指出「要求 RSA 加密」", st.error);
            ck(raopMock.audio_packet_count() == 0, "加密专用接收端未收到任何音频包");
            ck(!st.volumeSupported, "失败会话不残留 volumeSupported（界面不会给出音量控件）");
            ck(!st.errorEn.empty() && !has_cjk(st.errorEn), "加密专用拒绝：英文文案齐全且不含中文", st.errorEn);
            mgr.set_airplay_devices_for_test({});
        }

        // 不支持 ALAC（cn 不含 1）：本版本只发 ALAC，必须在握手前拒绝
        {
            raopMock.reset_capture();
            AirPlayDevice noAlac;
            noAlac.id = "synthetic-no-alac";
            noAlac.name = "Synthetic No ALAC";
            noAlac.host = "127.0.0.1";
            noAlac.port = raopMock.port;
            noAlac.supportsPlaintext = true;
            noAlac.needsEncryption = false;
            noAlac.supportsAlac = false;
            mgr.set_airplay_devices_for_test({noAlac});

            CastStartParams cp;
            cp.dev = airplay_dev_url("");
            cp.file = apWavPath;
            auto sr = mgr.start(cp);
            ck(sr.ok, "不支持 ALAC：start() 成功受理");
            wait_session_end(3.0);
            auto st = mgr.get_state();
            if (st.running) mgr.stop();
            ck(st.phase == "error", "cn 不含 1 的接收端被拒绝", st.phase + " / " + st.error);
            ck(st.error.find("ALAC") != std::string::npos, "错误文案明确指出缺 ALAC 能力", st.error);
            ck(!raopMock.recorded_once(), "不支持 ALAC 时连 ANNOUNCE/RECORD 都不发（未浪费一次握手）");
            mgr.set_airplay_devices_for_test({});
        }

        // 仅公布 pk=（hasPublicKey=true、needsEncryption=false）：必须**允许**明文尝试
        {
            raopMock.reset_capture();
            AirPlayDevice pkOnly;
            pkOnly.id = "synthetic-pk-only";
            pkOnly.name = "Synthetic PK Only";
            pkOnly.host = "127.0.0.1";
            pkOnly.port = raopMock.port;
            pkOnly.supportsPlaintext = true;
            pkOnly.needsEncryption = false;
            pkOnly.hasPublicKey = true;
            pkOnly.supportsAlac = true;
            mgr.set_airplay_devices_for_test({pkOnly});

            CastStartParams cp;
            cp.dev = airplay_dev_url("");
            cp.file = apWavPath;
            auto sr = mgr.start(cp);
            ck(sr.ok, "仅有 pk= 的设备：start() 成功");
            const bool reachedPlaying =
                wait_until([&]() { return mgr.get_state().phase == "playing"; }, 4.0);
            auto st = mgr.get_state();
            ck(reachedPlaying && st.error.empty(),
               "仅有 pk= 不代表必须加密：连接与起播不被拒绝", st.phase + " / " + st.error);
            ck(st.warning.find("pk=") != std::string::npos,
               "警告里如实记录「公布 pk=，仍按明文尝试」", st.warning);
            mgr.stop();
            mgr.set_airplay_devices_for_test({});
        }

        // URL 显式 enc=1：拒绝（这一次是真的「调用方确证要求加密」）
        {
            raopMock.reset_capture();
            CastStartParams cp;
            cp.dev = airplay_dev_url("?enc=1");
            cp.file = apWavPath;
            auto sr = mgr.start(cp);
            ck(sr.ok, "enc=1：start() 成功受理");
            wait_session_end(3.0);
            auto st = mgr.get_state();
            if (st.running) mgr.stop();
            ck(st.error.find("加密") != std::string::npos, "URL 显式 enc=1 被拒绝并说明原因", st.error);
            ck(raopMock.audio_packet_count() == 0, "enc=1 拒绝路径未发音频");
        }

        // DoP + AirPlay：必须在 start() 同步拒绝（RAOP 没有 DoP 载体）
        {
            CastStartParams cp;
            cp.dev = airplay_dev_url("");
            cp.file = apWavPath;
            cp.dop = true;
            auto sr = mgr.start(cp);
            ck(!sr.ok, "AirPlay + DoP 被同步拒绝");
            ck(sr.error.find("DoP") != std::string::npos, "拒绝文案包含 DoP", sr.error);
            ck(!mgr.get_state().running, "DoP 拒绝后没有留下半启动会话");
        }

        // ─────────────────────────────────────────────────────────────────────
        // 7.2 初始音量下发失败：必须在**发出任何音频之前**中止
        // ─────────────────────────────────────────────────────────────────────
        {
            raopMock.reset_capture();
            raopMock.failVolume.store(true);
            CastStartParams cp;
            cp.dev = airplay_dev_url("");
            cp.file = apWavPath;
            cp.initialVolumeDb = -20.0;
            auto sr = mgr.start(cp);
            ck(sr.ok, "音量失败用例：start() 成功受理");
            const bool ended = wait_session_end(4.0);
            auto st = mgr.get_state();
            if (st.running) mgr.stop();
            raopMock.failVolume.store(false);
            ck(ended && st.phase == "error", "SET_PARAMETER volume 失败 ⟹ 会话进入 error", st.phase);
            ck(st.error.find("音量") != std::string::npos,
               "错误文案指出「初始音量设置失败」", st.error);
            ck(raopMock.recorded_once(), "中止发生在 RECORD 之后（握手完成，证明不是连不上）");
            ck(raopMock.audio_packet_count() == 0,
               "音量未知时一条音频都没发（避免以未知音量起播）",
               std::to_string(raopMock.audio_packet_count()));
            ck(st.currentVolume == -1, "失败后不谎报已设置音量（currentVolume == -1）",
               std::to_string(st.currentVolume));
            ck(!st.volumeSupported, "音量失败后不残留 volumeSupported");
        }

        // ─────────────────────────────────────────────────────────────────────
        // 7.3 正常生命周期：初始音量、运行期音量、可听进度、延迟排空后的自然结束
        // ─────────────────────────────────────────────────────────────────────
        {
            raopMock.reset_capture();
            CastStartParams cp;
            cp.dev = airplay_dev_url("");
            cp.file = apWavPath;
            cp.initialVolumeDb = -20.0; // 保守初始音量，绝不 0 dB 爆音
            auto tStart = now_tp();
            auto sr = mgr.start(cp);
            ck(sr.ok, "正常 AirPlay start() 成功", sr.error);

            ck(wait_until([&]() { return mgr.get_state().phase == "playing"; }, 4.0),
               "成功进入 playing 阶段", mgr.get_state().phase);
            ck(mgr.get_state().volumeSupported, "AirPlay 报告 volumeSupported 为 true");
            ck(mgr.get_state().currentVolume > 0 && mgr.get_state().currentVolume < 100,
               "初始音量已下发并映射到合理百分比", std::to_string(mgr.get_state().currentVolume));
            ck(mgr.get_state().lastVolumeError.empty(), "初始音量成功时 lastVolumeError 为空",
               mgr.get_state().lastVolumeError);

            // 运行期音量：成功后更新百分比；这里顺带验证 -15 dB 比 -20 dB 更响
            const int volBefore = mgr.get_state().currentVolume;
            mgr.set_volume_db(-15.0);
            ck(wait_until([&]() { return mgr.get_state().currentVolume != volBefore; }, 1.0),
               "SetVolume 后音量百分比已更新",
               std::to_string(volBefore) + " -> " + std::to_string(mgr.get_state().currentVolume));
            ck(mgr.get_state().currentVolume > volBefore, "更小的衰减（-15 dB）映射出更大的百分比");

            // 运行期音量失败：不得把「没发出去」显示成「已设为 −30 dB / X%」
            {
                raopMock.failVolume.store(true);
                const int volConfirmed = mgr.get_state().currentVolume;
                mgr.set_volume_db(-30.0);
                ck(wait_until([&]() { return !mgr.get_state().lastVolumeError.empty(); }, 2.5),
                   "运行期音量失败被如实记录（lastVolumeError 非空）",
                   mgr.get_state().lastVolumeError);
                ck(mgr.get_state().currentVolume == volConfirmed,
                   "运行期音量失败不更新百分比（保持上次已确认值）",
                   std::to_string(volConfirmed) + " -> " + std::to_string(mgr.get_state().currentVolume));
                raopMock.failVolume.store(false);
            }

            // 进度必须是「可听位置」：延迟 2 s + prebuffer 0.35 s 之后才应动起来
            std::this_thread::sleep_for(std::chrono::milliseconds(300));
            ck(mgr.get_state().positionSec < 0.01,
               "起播 0.3 s 后进度仍 ≈ 0（可听位置尚未越过播放缓冲）",
               std::to_string(mgr.get_state().positionSec));

            // 自然结束：必须等到可听终点（≈ prebuffer + latency + 时长）
            const bool ended = wait_session_end(6.0);
            auto tEnd = now_tp();
            auto st = mgr.get_state();
            if (st.running) mgr.stop();
            ck(ended, "AirPlay 自然播完后会话退出");
            ck(st.endedNaturally, "AirPlay 自然播完后 endedNaturally 必须为 true");
            ck(st.error.empty(), "AirPlay 自然播完后无错误", st.error);
            ck(std::abs(st.positionSec - kDurationSec) < 1e-6,
               "自然结束后 positionSec 落在曲目末尾",
               std::to_string(st.positionSec) + " vs " + std::to_string(kDurationSec));

            // ① 假接收端的播放模型必须已经播到终点（证明等的是「可听位置」而不是「包都发完了」）
            const double modelAudible = raopMock.model_audible_frames(tEnd);
            ck(modelAudible >= static_cast<double>(kTotalFrames) - 220.0,
               "发送端等到了接收端播放模型的终点（不是按包数提前结束）",
               "audible=" + std::to_string(modelAudible) + " total=" + std::to_string(kTotalFrames));
            // ② 结束时刻必须晚于 prebuffer+latency+时长（旧实现会在 ≈0.2 s 就宣称播完）
            const double elapsed = std::chrono::duration<double>(tEnd - tStart).count();
            const double nominalSec = kNominalEndSec;
            ck(elapsed >= nominalSec - 0.15,
               "结束时刻不早于 prebuffer+latency+时长（延迟尾巴没被切掉）",
               "elapsed=" + std::to_string(elapsed) + " nominal=" + std::to_string(nominalSec));
            ck(elapsed <= nominalSec + 2.5, "结束时刻有界（不会无限等待）",
               std::to_string(elapsed));

            // ③ 包与控制面事实
            const size_t audioPkts = raopMock.audio_packet_count();
            const size_t ctrlPkts = raopMock.control_packet_count();
            ck(audioPkts >= kTotalPackets,
               "假接收端捕获到全部 RTP 音频包（含 EOS 补齐包）",
               "audio=" + std::to_string(audioPkts) + " expected>=" + std::to_string(kTotalPackets));
            ck(ctrlPkts > 0, "假接收端捕获到 Control (sync) 包", std::to_string(ctrlPkts));
            ck(raopMock.saw_method("TEARDOWN"), "自然结束后发出了 TEARDOWN");

            bool hasVolParam = false;
            {
                std::lock_guard<std::mutex> lk(raopMock.mtx);
                for (const auto& b : raopMock.rtspBodies) {
                    if (b.find("volume: ") != std::string::npos) hasVolParam = true;
                }
            }
            ck(hasVolParam, "假接收端捕获到 SET_PARAMETER volume 指令");
        }

        // ─────────────────────────────────────────────────────────────────────
        // 7.4 暂停发生在「所有包已发完之后」（drain 阶段）：
        //     ① 暂停期间不得推进位置、不得结束后台会话；
        //     ② 结束后台排空预算不能被「暂停时长」耗尽（旧实现会在暂停中把歌播完）；
        //     ③ 恢复后进度不得回跳。
        // ─────────────────────────────────────────────────────────────────────
        {
            raopMock.reset_capture();
            CastStartParams cp;
            cp.dev = airplay_dev_url("");
            cp.file = apWavPath;
            auto tStart = now_tp();
            auto sr = mgr.start(cp);
            ck(sr.ok, "暂停用例：start() 成功", sr.error);

            ck(wait_until([&]() { return mgr.get_state().phase == "playing"; }, 4.0),
               "暂停用例：进入 playing");
            // 等所有包发完（含 EOS 补齐）且接收端已经开始出声
            const bool allSent = wait_until([&]() { return raopMock.audio_packet_count() >= kTotalPackets; }, 3.0);
            ck(allSent, "暂停用例：全部音频包已发出（暂停将发生在 drain 阶段）",
               std::to_string(raopMock.audio_packet_count()));
            const bool playingStarted = wait_until([&]() {
                return raopMock.model_audible_frames(now_tp()) > 0.03 * 44100.0;
            }, 4.0);
            ck(playingStarted, "暂停用例：接收端已开始出声（可听位置 > 0）");

            const double posBefore = mgr.get_state().positionSec;
            ck(posBefore > 0.0 && posBefore < kDurationSec,
               "暂停前进度处于曲目中间", std::to_string(posBefore));

            mgr.set_paused(true);
            auto tPause = now_tp();
            ck(wait_until([&]() { return mgr.get_state().paused; }, 1.0), "set_paused(true) 生效");
            ck(raopMock.saw_method("FLUSH"), "暂停通过 RTSP FLUSH 让对端静音（协议层契约）");

            std::this_thread::sleep_for(std::chrono::milliseconds(400));
            {
                auto st = mgr.get_state();
                ck(st.running, "暂停 0.4 s 后会话仍在运行（没有在暂停里把歌「播完」）");
                ck(st.paused, "暂停 0.4 s 后 paused 仍为 true");
                ck(std::abs(st.positionSec - posBefore) <= 0.03,
                   "暂停期间进度冻结（不前进、不跳变）",
                   std::to_string(posBefore) + " -> " + std::to_string(st.positionSec));
                ck(st.positionSec < kDurationSec - 0.005,
                   "暂停期间进度未到达曲目末尾", std::to_string(st.positionSec));
            }

            mgr.set_paused(false);
            std::this_thread::sleep_for(std::chrono::milliseconds(150));
            {
                auto st = mgr.get_state();
                ck(!st.paused, "set_paused(false) 恢复播放");
                ck(st.positionSec >= posBefore - 0.015,
                   "恢复后进度不回跳（时间轴重锚带来的小幅回退被单调钳位吸收）",
                   std::to_string(posBefore) + " -> " + std::to_string(st.positionSec));
            }

            const bool ended = wait_session_end(6.0);
            auto tEnd = now_tp();
            auto st = mgr.get_state();
            if (st.running) mgr.stop();
            ck(ended, "暂停/恢复后仍能自然结束（drain 预算未被暂停耗尽）");
            ck(st.endedNaturally, "暂停/恢复后 endedNaturally 为 true", st.error);
            ck(st.error.empty(), "暂停/恢复后无错误", st.error);

            const double pauseSec = std::chrono::duration<double>(now_tp() - tPause).count();
            const double sincePause = std::chrono::duration<double>(tEnd - tPause).count();
            ck(sincePause >= 0.30, "结束时刻晚于暂停开始（暂停没有被排空截止时间吞掉）",
               "sincePause=" + std::to_string(sincePause) + " pauseSec≈" + std::to_string(pauseSec));
            const double totalElapsed = std::chrono::duration<double>(tEnd - tStart).count();
            ck(totalElapsed >= kNominalEndSec + 0.30,
               "总时长 ≥ prebuffer+latency+时长+暂停（暂停真的被等过了）",
               std::to_string(totalElapsed));
        }

        // ─────────────────────────────────────────────────────────────────────
        // 7.5 暂停状态下 stop()：必须有界返回（不能等到歌自然结束）
        // ─────────────────────────────────────────────────────────────────────
        {
            raopMock.reset_capture();
            CastStartParams cp;
            cp.dev = airplay_dev_url("");
            cp.file = apWavPath;
            auto sr = mgr.start(cp);
            ck(sr.ok, "暂停中 stop：start() 成功", sr.error);
            ck(wait_until([&]() { return mgr.get_state().phase == "playing"; }, 4.0),
               "暂停中 stop：进入 playing");
            mgr.set_paused(true);
            ck(wait_until([&]() { return mgr.get_state().paused; }, 1.0), "暂停中 stop：已暂停");
            const auto t0 = now_tp();
            mgr.stop();
            const double stopSec = std::chrono::duration<double>(now_tp() - t0).count();
            ck(stopSec < 1.5, "暂停状态下 stop() 有界返回（< 1.5 s）", std::to_string(stopSec));
            auto st = mgr.get_state();
            ck(!st.running, "暂停中 stop() 后 running == false");
            ck(!st.endedNaturally, "暂停中 stop() 不算自然结束");
            ck(st.phase == "stopped", "暂停中 stop() 后 phase == stopped", st.phase);
        }

        // ─────────────────────────────────────────────────────────────────────
        // 7.6 并发 start / 快速 start-stop：不重复 join、不互等整首歌
        // ─────────────────────────────────────────────────────────────────────
        {
            raopMock.reset_capture();
            CastStartParams cp;
            cp.dev = airplay_dev_url("");
            cp.file = apWavPath;
            auto sr = mgr.start(cp);
            ck(sr.ok, "并发 start：首个会话启动成功", sr.error);
            ck(wait_until([&]() { return mgr.get_state().phase == "playing"; }, 4.0),
               "并发 start：首个会话已进入 playing");

            // 4 个线程同时 start：必须全部被拒绝（不能有第二个 thread 覆盖 workerThread_）
            std::atomic<int> accepted{0};
            std::atomic<int> rejected{0};
            std::vector<std::thread> ths;
            for (int r = 0; r < 4; ++r) {
                ths.emplace_back([&]() {
                    auto rr = mgr.start(cp);
                    if (rr.ok) accepted.fetch_add(1);
                    else rejected.fetch_add(1);
                });
            }
            for (auto& t : ths) t.join();
            ck(accepted.load() == 0, "并发 start：没有任何一个请求被接受（running 会话保护）",
               "accepted=" + std::to_string(accepted.load()));
            ck(rejected.load() == 4, "并发 start：4 个请求全部明确拒绝",
               "rejected=" + std::to_string(rejected.load()));
            ck(mgr.get_state().running, "并发 start 后原会话仍在运行（未被覆盖）");
            mgr.stop();
            ck(!mgr.get_state().running, "并发 start 用例收尾正常");

            // 空闲状态下的并发 start：这是历史 bug 的精确形态 ——
            // 两个 start() 同时通过 running==false 检查后，第二个会去 join 第一个的 worker，
            // 于是一次「开始投放」要等到**整首歌播完**才返回，而且可能起出两条会话。
            // 现在 start()/stop() 由 lifecycleMtx_ 串行化 ⟹ 恰好 1 个被接受，其余立即拒绝。
            {
                raopMock.reset_capture();
                CastStartParams cp3;
                cp3.dev = airplay_dev_url("");
                cp3.file = apWavPath;

                std::mutex resMtx;
                int acceptedIdle = 0, rejectedIdle = 0;
                double maxSec = 0.0;
                std::vector<std::thread> ths2;
                for (int i = 0; i < 4; ++i) {
                    ths2.emplace_back([&]() {
                        const auto tc = now_tp();
                        auto rr = mgr.start(cp3);
                        const double sec = std::chrono::duration<double>(now_tp() - tc).count();
                        std::lock_guard<std::mutex> lk(resMtx);
                        if (rr.ok) ++acceptedIdle; else ++rejectedIdle;
                        if (sec > maxSec) maxSec = sec;
                    });
                }
                for (auto& t : ths2) t.join();
                ck(acceptedIdle == 1, "空闲并发 start：恰好 1 个被接受（不会起两条会话）",
                   std::to_string(acceptedIdle));
                ck(rejectedIdle == 3, "空闲并发 start：其余 3 个立即明确拒绝",
                   std::to_string(rejectedIdle));
                ck(maxSec < 1.5, "空闲并发 start：没有请求等待整首歌（旧实现会 join 到曲终）",
                   std::to_string(maxSec));
                mgr.stop();
                ck(!mgr.get_state().running, "空闲并发 start 用例收尾正常");
            }

            // 连击快速 start/stop：不重复 join、不抛异常、不死锁
            bool raceOk = true;
            for (int r = 0; r < 5; ++r) {
                try {
                    CastStartParams cp2;
                    cp2.dev = airplay_dev_url("");
                    cp2.file = apWavPath;
                    mgr.start(cp2);
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    mgr.stop();
                } catch (...) {
                    raceOk = false;
                }
            }
            ck(raceOk && !mgr.get_state().running, "连击快速 start/stop 稳健收尾无死锁");
        }

        raopMock.shutdown();
        std::remove(apWavPath.c_str());
    }

    // ================= 8) 1.1.3 UPnP 投放升频与流式供源测试 =================
    std::printf("\n-- 8. 1.1.3 UPnP 投放升频与流式供源完整契约测试 --\n");
    {
        // 8.0 parse_sink_formats 纯函数覆盖
        {
            auto f0 = parse_sink_formats("");
            ck(f0.empty(), "parse_sink_formats: 空串返回空列表");

            auto f1 = parse_sink_formats("http-get:*:audio/wav:*");
            ck(f1.empty(), "parse_sink_formats: 无 rate 通配 WAV 返回空列表 (视为未声明)");

            auto f2 = parse_sink_formats("http-get:*:audio/wav:DLNA.ORG_PN=WAV;rate=88200");
            ck(f2.size() == 1 && f2[0].rate == 88200 && f2[0].bits == 0,
               "parse_sink_formats: audio/wav 指定 rate=88200 解析正确");

            auto f3 = parse_sink_formats("http-get:*:audio/x-wav:rate=96000;bitspersample=24");
            ck(f3.size() == 1 && f3[0].rate == 96000 && f3[0].bits == 24,
               "parse_sink_formats: audio/x-wav 识别 96000 Hz / 24 bit");

            auto f4 = parse_sink_formats("http-get:*:audio/L16:rate=44100,http-get:*:audio/L24:rate=192000,http-get:*:audio/L32:rate=384000");
            ck(f4.size() == 3 &&
               f4[0].rate == 44100 && f4[0].bits == 16 &&
               f4[1].rate == 192000 && f4[1].bits == 24 &&
               f4[2].rate == 384000 && f4[2].bits == 32,
               "parse_sink_formats: L16/L24/L32 复合能力列表完整解析");
        }

        // 辅助结构与函数
        struct HttpFetchResult {
            int statusCode = 0;
            std::string headers;
            std::string body;
        };

        auto fetch_http_data = [](const std::string& uri, const std::string& rangeHeader = "") -> HttpFetchResult {
            HttpFetchResult res;
            if (uri.rfind("http://", 0) != 0) return res;
            const size_t hs = 7;
            const size_t slash = uri.find('/', hs);
            const std::string hostport = uri.substr(hs, (slash == std::string::npos ? uri.size() : slash) - hs);
            const std::string path = (slash == std::string::npos) ? "/" : uri.substr(slash);
            const size_t colon = hostport.find(':');
            const std::string host = (colon == std::string::npos) ? hostport : hostport.substr(0, colon);
            const int port = (colon == std::string::npos) ? 80 : std::atoi(hostport.substr(colon + 1).c_str());

            upnp_os::socket_t s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (s == upnp_os::kInvalidSocket) return res;
            upnp_os::set_timeout(s, SO_RCVTIMEO, 3000);
            upnp_os::set_timeout(s, SO_SNDTIMEO, 3000);

            sockaddr_in a{};
            a.sin_family = AF_INET;
            a.sin_port = htons((uint16_t)port);
            a.sin_addr.s_addr = ::inet_addr(host.c_str());
            if (::connect(s, (sockaddr*)&a, sizeof(a)) != 0) {
                upnp_os::close_socket(s);
                return res;
            }

            std::string req = "GET " + path + " HTTP/1.1\r\nHost: " + hostport + "\r\n";
            if (!rangeHeader.empty()) {
                req += "Range: " + rangeHeader + "\r\n";
            }
            req += "Connection: close\r\n\r\n";
            upnp_os::io_send(s, req.data(), (int)req.size());

            std::string raw;
            char buf[8192];
            int r = 0;
            while ((r = upnp_os::io_recv(s, buf, sizeof(buf))) > 0) {
                raw.append(buf, (size_t)r);
            }
            upnp_os::close_socket(s);

            size_t hdrEnd = raw.find("\r\n\r\n");
            if (hdrEnd != std::string::npos) {
                res.headers = raw.substr(0, hdrEnd);
                res.body = raw.substr(hdrEnd + 4);
                size_t sp1 = res.headers.find(' ');
                if (sp1 != std::string::npos) {
                    res.statusCode = std::atoi(res.headers.c_str() + sp1 + 1);
                }
            } else {
                res.body = raw;
            }
            return res;
        };

        auto read_file_binary = [](const std::string& path) -> std::string {
            std::ifstream in(path, std::ios::binary);
            return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        };

        auto count_temp_rtacast = []() -> size_t {
            size_t c = 0;
            std::error_code ec;
            for (const auto& entry : fs::directory_iterator(fs::temp_directory_path(ec), ec)) {
                if (entry.path().filename().string().rfind("rtacast_", 0) == 0) ++c;
            }
            return c;
        };

        // 构造测试源文件：44100 Hz, 16 bit, 2 声道, 4410 帧 (0.1秒), 振幅 ≤ -60 dBFS (铁律 1)
        const std::string srcWavPath = make_cast_temp_wav_path("upsample_test_src");
        rta::audio::AudioBuffer srcBuf;
        srcBuf.rate = 44100;
        srcBuf.channels = 2;
        srcBuf.bits = 16;
        srcBuf.isFloat = false;
        const size_t kSrcFrames = 4410;
        srcBuf.raw.resize(kSrcFrames * 2);
        for (size_t i = 0; i < kSrcFrames; ++i) {
            // -60 dBFS 极微弱正弦波，绝对不可听
            double v = std::sin(2.0 * M_PI * 440.0 * (double)i / 44100.0) * 0.0009;
            srcBuf.setSample(i, 0, v);
            srcBuf.setSample(i, 1, -v);
        }
        rta::audio::write_wav(srcWavPath, srcBuf);

        // 启动 Loopback Mock 渲染器
        LoopbackMockUpnpRenderer mock;
        mock.start();
        mock.reset_mode(MockMode::ContinuousPlay);
        mock.set_sink("http-get:*:audio/wav:DLNA.ORG_PN=WAV;rate=88200,http-get:*:audio/L24:rate=88200");
        const std::string descUrl = "http://127.0.0.1:" + std::to_string(mock.port()) + "/desc.xml";

        // ================= 判据 1, 2, 3, 4, 5: 升频生效 / 逐字节相等 / 帧数守恒 / Range / 状态一致 =================
        {
            CastStartParams p;
            p.dev = descUrl;
            p.file = srcWavPath;
            p.applyUpsample = true;
            p.requestedRate = "88200";
            p.filterName = "poly-sinc-lp";

            auto startRes = mgr.start(p);
            ck(startRes.ok, "判据 1-5: 投放升频起播请求受理成功");

            // 等待进入 playing
            CastState st;
            for (int i = 0; i < 60; ++i) {
                st = mgr.get_state();
                if (st.phase == "playing") break;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            ck(st.phase == "playing", "判据 1-5: 顺利进入 playing 阶段", "当前=" + st.phase);

            // 判据 5: 状态一致性断言
            // 依据：UI 与外部状态必须如实反映实际生效的升频参数、源格式与是否重采样，不得谎报
            ck(st.upsampleApplied == true, "判据 5(状态一致): upsampleApplied 为 true");
            ck(st.resampled == true, "判据 5(状态一致): resampled 为 true (88200 != 44100)");
            ck(st.servedRate == 88200, "判据 5(状态一致): servedRate 精确为 88200");
            ck(st.servedBits == 16, "判据 5(状态一致): servedBits 为 16 (源位深)");
            // 1.1.3 集成补：界面显示的是**实际用的**滤波器（servedFilter），
            // 它必须非空且等于本次真正喂给重采样器的预设名，否则 UI 只能回落到"用户填的名字"——
            // 一旦发生回退（名字不存在），界面就会显示一个没被用上的名字（假信息）。
            ck(st.servedFilter == "poly-sinc-lp",
               "判据 5(状态一致): servedFilter 记录实际使用的预设名 poly-sinc-lp", st.servedFilter);
            ck(st.sampleRate == 88200, "判据 5(状态一致): sampleRate 为 88200");
            ck(st.bits == 16, "判据 5(状态一致): bits 为 16");
            ck(st.sourceRate == 44100, "判据 5(状态一致): sourceRate 为源率 44100");
            ck(st.sourceBits == 16, "判据 5(状态一致): sourceBits 为源位深 16");
            ck(st.sourceChannels == 2, "判据 5(状态一致): sourceChannels 为 2");

            std::string streamUri = mock.get_current_uri();
            ck(!streamUri.empty(), "Mock 接收端捕获到投放 streamUri", streamUri);

            HttpFetchResult fullRes = fetch_http_data(streamUri);
            ck(fullRes.statusCode == 200, "HTTP GET 获取完整 WAV 流返回 200 OK");
            ck(fullRes.body.size() >= 44, "HTTP GET 获取数据体大于 44 字节头大小");

            // 判据 1: WAV 头结构精确断言
            // 依据：只有 RIFF/fmt/data 44 字节头与真实目标采样率、位深、声道及 data 大小完全自洽，DLNA 渲染器才能无误解码
            if (fullRes.body.size() >= 44) {
                const uint8_t* h = reinterpret_cast<const uint8_t*>(fullRes.body.data());
                bool riffOk = (std::memcmp(h, "RIFF", 4) == 0);
                uint32_t riffSz = (uint32_t)h[4] | ((uint32_t)h[5] << 8) | ((uint32_t)h[6] << 16) | ((uint32_t)h[7] << 24);
                bool waveOk = (std::memcmp(h + 8, "WAVE", 4) == 0);
                bool fmtOk = (std::memcmp(h + 12, "fmt ", 4) == 0);
                uint32_t fmtSz = (uint32_t)h[16] | ((uint32_t)h[17] << 8) | ((uint32_t)h[18] << 16) | ((uint32_t)h[19] << 24);
                uint16_t tag = (uint16_t)h[20] | ((uint16_t)h[21] << 8);
                uint16_t ch = (uint16_t)h[22] | ((uint16_t)h[23] << 8);
                uint32_t rate = (uint32_t)h[24] | ((uint32_t)h[25] << 8) | ((uint32_t)h[26] << 16) | ((uint32_t)h[27] << 24);
                uint32_t byteRate = (uint32_t)h[28] | ((uint32_t)h[29] << 8) | ((uint32_t)h[30] << 16) | ((uint32_t)h[31] << 24);
                uint16_t blockAlign = (uint16_t)h[32] | ((uint16_t)h[33] << 8);
                uint16_t bits = (uint16_t)h[34] | ((uint16_t)h[35] << 8);
                bool dataTagOk = (std::memcmp(h + 36, "data", 4) == 0);
                uint32_t dataSz = (uint32_t)h[40] | ((uint32_t)h[41] << 8) | ((uint32_t)h[42] << 16) | ((uint32_t)h[43] << 24);

                ck(riffOk && waveOk && fmtOk && dataTagOk, "判据 1(WAV头): 包含合法的 RIFF / WAVE / fmt / data 块标头");
                ck(fmtSz == 16 && tag == 1, "判据 1(WAV头): fmtSz=16 且 tag=1 (标准线性 PCM)");
                ck(ch == 2 && rate == 88200 && bits == 16, "判据 1(WAV头): 声道=2, 采样率=88200, 位深=16");
                ck(byteRate == 88200 * 4 && blockAlign == 4, "判据 1(WAV头): byteRate 与 blockAlign 精确匹配");
                ck(riffSz == 36 + dataSz, "判据 1(WAV头): RIFF 总大小字段等于 36 + data 大小",
                   "riffSz=" + std::to_string(riffSz) + " 36+dataSz=" + std::to_string(36 + dataSz));
                ck(fullRes.body.size() == 44 + dataSz, "判据 1(WAV头): 文件实际字节大小精确等于 44 + data 大小",
                   "body=" + std::to_string(fullRes.body.size()) + " 44+dataSz=" + std::to_string(44 + dataSz));
            }

            // 判据 3: 帧数守恒断言
            // 依据：总输出帧数必须精确守恒于 llround(srcFrames * targetRate / sourceRate)，不多也不少一帧
            const uint64_t expectedFrames = (uint64_t)std::llround((double)kSrcFrames * 88200.0 / 44100.0); // 8820
            const size_t actualDataBytes = fullRes.body.size() >= 44 ? (fullRes.body.size() - 44) : 0;
            const size_t actualFrames = actualDataBytes / 4;
            ck(actualFrames == expectedFrames,
               "判据 3(帧数守恒): 实际输出帧数精确等于理论计算",
               "actual=" + std::to_string(actualFrames) + " expected=" + std::to_string(expectedFrames));
            ck(actualDataBytes == expectedFrames * 4,
               "判据 3(帧数守恒): 数据块末尾无任何溢出或截断的残留字节");

            // 判据 2: 逐字节相等断言
            // 依据：同一 PolyphaseResampler 配置与命名滤波器下，流式分块写盘与离线独立计算产出的 PCM 逐字节一致
            std::vector<uint8_t> expectedPcmBytes;
            {
                rta::dsp::ResamplerConfig rcfg;
                rcfg.inRate = 44100;
                rcfg.outRate = 88200;
                rcfg.channels = 2;
                const auto* fp = rta::dsp::find_preset("poly-sinc-lp", false);
                rcfg.totalTaps = fp->taps;
                rcfg.transition = fp->transition;
                rcfg.attenDb = fp->attenDb;
                rcfg.window = fp->window;
                rcfg.phase = fp->phase;
                rcfg.twoStage = fp->twoStage;
                rcfg.minTapsPerInput = fp->tapsPerInput;

                rta::dsp::PolyphaseResampler testResampler(rcfg);
                uint64_t refWritten = 0;

                auto append_ref_frames = [&](const std::vector<std::vector<double>>& outCh, size_t nOut) {
                    if (nOut == 0) return;
                    if (refWritten + nOut > expectedFrames) nOut = (size_t)(expectedFrames - refWritten);
                    if (nOut == 0) return;
                    for (size_t i = 0; i < nOut; ++i) {
                        for (int c = 0; c < 2; ++c) {
                            double x = outCh[c][i];
                            if (!rta::audio::audio_finite(x)) x = 0.0;
                            double s = x * 32768.0;
                            s = std::floor(s + 0.5);
                            if (s > 32767.0) s = 32767.0;
                            if (s < -32768.0) s = -32768.0;
                            int16_t v = static_cast<int16_t>(s);
                            expectedPcmBytes.push_back((uint8_t)(v & 0xFF));
                            expectedPcmBytes.push_back((uint8_t)((v >> 8) & 0xFF));
                        }
                    }
                    refWritten += nOut;
                };

                size_t srcOffset = 0;
                const size_t kChunk = 1 << 16;
                while (srcOffset < srcBuf.frames()) {
                    size_t thisChunk = std::min(kChunk, (size_t)(srcBuf.frames() - srcOffset));
                    std::vector<std::vector<double>> inCh(2, std::vector<double>(thisChunk));
                    for (int c = 0; c < 2; ++c) {
                        for (size_t i = 0; i < thisChunk; ++i) inCh[c][i] = srcBuf.sample(srcOffset + i, c);
                    }
                    srcOffset += thisChunk;
                    size_t maxOut = testResampler.maxOutFrames(thisChunk);
                    std::vector<std::vector<double>> outCh(2, std::vector<double>(maxOut));
                    std::vector<const double*> inPtrs = {inCh[0].data(), inCh[1].data()};
                    std::vector<double*> outPtrs = {outCh[0].data(), outCh[1].data()};
                    size_t nOut = testResampler.process(inPtrs.data(), thisChunk, outPtrs.data());
                    append_ref_frames(outCh, nOut);
                }

                const size_t drainChunk = 1024;
                std::vector<std::vector<double>> zeroIn(2, std::vector<double>(drainChunk, 0.0));
                std::vector<const double*> zeroPtrs = {zeroIn[0].data(), zeroIn[1].data()};
                size_t maxDrainOut = testResampler.maxOutFrames(drainChunk);
                std::vector<std::vector<double>> drainOut(2, std::vector<double>(maxDrainOut));
                std::vector<double*> drainOutPtrs = {drainOut[0].data(), drainOut[1].data()};
                const size_t maxDrainIn = (size_t)std::ceil(testResampler.latencyInputSamples() * 2.0) + 2048;
                size_t drainedIn = 0;
                while (refWritten < expectedFrames && drainedIn < maxDrainIn) {
                    size_t nOut = testResampler.process(zeroPtrs.data(), drainChunk, drainOutPtrs.data());
                    drainedIn += drainChunk;
                    if (nOut > 0) append_ref_frames(drainOut, nOut);
                }
                if (refWritten < expectedFrames) {
                    size_t pad = (size_t)(expectedFrames - refWritten);
                    std::vector<std::vector<double>> padCh(2, std::vector<double>(pad, 0.0));
                    append_ref_frames(padCh, pad);
                }
            }

            std::string actualPcmBytes = fullRes.body.substr(44);
            ck(actualPcmBytes.size() == expectedPcmBytes.size(),
               "判据 2(逐字节相等): PCM 字节大小与离线独立计算完全一致",
               std::to_string(actualPcmBytes.size()) + " bytes");
            ck(actualPcmBytes == std::string(reinterpret_cast<const char*>(expectedPcmBytes.data()), expectedPcmBytes.size()),
               "判据 2(逐字节相等): HTTP 供出的 PCM 样本与离线独立重采样算出的 PCM 逐字节完全相等");

            // 判据 4: Range 请求断言
            // 依据：UPnP 渲染器在 Seek 或预缓冲时高频使用 HTTP Range 206，必须精确返回指定范围字节切片与 Content-Range
            HttpFetchResult rangeRes = fetch_http_data(streamUri, "bytes=1000-1999");
            ck(rangeRes.statusCode == 206, "判据 4(Range): Range 请求返回 206 Partial Content");
            std::string expectedContentRange = "Content-Range: bytes 1000-1999/" + std::to_string(fullRes.body.size());
            ck(rangeRes.headers.find(expectedContentRange) != std::string::npos,
               "判据 4(Range): 响应头中包含正确的 Content-Range", expectedContentRange);
            ck(rangeRes.body.size() == 1000, "判据 4(Range): Range 响应数据体恰好为 1000 字节");
            ck(rangeRes.body == fullRes.body.substr(1000, 1000),
               "判据 4(Range): Range 数据体与全量流对应位置切片逐字节完全相同");

            mgr.stop();
        }

        // ================= 判据 6: 关开关，原文件直供 =================
        // 依据：用户关闭升频开关时，供源必须是源文件的逐字节镜像，不得发生任何重采样或额外包装
        {
            CastStartParams pOff;
            pOff.dev = descUrl;
            pOff.file = srcWavPath;
            pOff.applyUpsample = false;

            auto rOff = mgr.start(pOff);
            ck(rOff.ok, "判据 6(关开关): 关开关起播成功");
            for (int i = 0; i < 60; ++i) {
                if (mgr.get_state().phase == "playing") break;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            CastState stOff = mgr.get_state();
            ck(stOff.phase == "playing", "判据 6(关开关): 顺利进入 playing");
            ck(!stOff.upsampleApplied, "判据 6(关开关): upsampleApplied 保持 false");
            ck(!stOff.resampled, "判据 6(关开关): resampled 保持 false");
            ck(stOff.servedRate == 44100, "判据 6(关开关): servedRate 为 44100");

            std::string offUri = mock.get_current_uri();
            HttpFetchResult offRes = fetch_http_data(offUri);
            std::string srcFileBytes = read_file_binary(srcWavPath);
            ck(offRes.body.size() == srcFileBytes.size(),
               "判据 6(关开关): 供出的字节数与源文件完全相同", std::to_string(offRes.body.size()));
            ck(offRes.body == srcFileBytes, "判据 6(关开关): 供出的全部字节与源文件逐字节完全相等");

            mgr.stop();
        }

        // ================= 判据 7: 磁盘不足 (注入 seam) =================
        // 依据：当临时目录磁盘容量不足时，必须提前防御性拒绝并给出可读原因，严禁留下半截或损坏的临时文件
        {
            size_t beforeCount = count_temp_rtacast();
            cast_test_hooks().freeBytesOverride = 1024; // 模拟仅剩 1 KB 可用

            CastStartParams pDisk;
            pDisk.dev = descUrl;
            pDisk.file = srcWavPath;
            pDisk.applyUpsample = true;
            pDisk.requestedRate = "88200";

            mgr.start(pDisk);
            for (int i = 0; i < 40; ++i) {
                if (mgr.get_state().phase == "error") break;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            CastState stDisk = mgr.get_state();
            ck(stDisk.phase == "error", "判据 7(磁盘不足): 空间不足时会话进入 error 状态");
            ck(stDisk.error.find("磁盘空间不足") != std::string::npos,
               "判据 7(磁盘不足): 中文提示包含「磁盘空间不足」", stDisk.error);
            ck(!stDisk.errorEn.empty() && !has_cjk(stDisk.errorEn),
               "判据 7(磁盘不足): 英文提示非空且不含中文", stDisk.errorEn);
            ck(count_temp_rtacast() == beforeCount,
               "判据 7(磁盘不足): 临时目录 rtacast_* 计数未增加，无残留孤儿文件");

            cast_test_hooks().freeBytesOverride = -1; // 恢复
            mgr.stop();
        }

        // ================= 判据 8: 准备阶段取消 =================
        // 依据：准备升频大文件耗时较长，若用户在此期间点击停止，必须有界响应、及时退出并清理临时文件
        {
            size_t beforeCount = count_temp_rtacast();
            cast_test_hooks().prepTick = []() -> bool {
                return true; // 模拟在重采样首块触发取消信号
            };

            CastStartParams pCancel;
            pCancel.dev = descUrl;
            pCancel.file = srcWavPath;
            pCancel.applyUpsample = true;
            pCancel.requestedRate = "88200";

            auto t0 = std::chrono::steady_clock::now();
            mgr.start(pCancel);

            for (int i = 0; i < 40; ++i) {
                if (!mgr.get_state().running) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            CastState stCancel = mgr.get_state();

            ck(!stCancel.running, "判据 8(取消): 取消后 running 为 false");
            ck(stCancel.phase == "stopped", "判据 8(取消): 取消后 phase 为 stopped");
            ck(elapsed < 1.5, "判据 8(取消): 准备阶段取消在有界时间内退出", std::to_string(elapsed) + "s");
            ck(count_temp_rtacast() == beforeCount,
               "判据 8(取消): 临时生成的未完成 WAV 文件被彻底删除，临时目录计数不变");

            cast_test_hooks().prepTick = nullptr; // 恢复
            mgr.stop();
        }

        // ================= 判据 9: 渲染器未声明格式 (默认 Sink) =================
        // 依据：DLNA 常见通配 Sink 未声明支持的具体采样率，此时必须退回本机上限策略并在 note 中说明渲染器未声明
        {
            mock.set_sink("http-get:*:audio/wav:*"); // 默认未声明格式

            CastStartParams pUndecl;
            pUndecl.dev = descUrl;
            pUndecl.file = srcWavPath;
            pUndecl.applyUpsample = true;
            pUndecl.requestedRate = "max";
            pUndecl.ceilingRate = 88200;

            mgr.start(pUndecl);
            for (int i = 0; i < 60; ++i) {
                if (mgr.get_state().phase == "playing") break;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            CastState stUndecl = mgr.get_state();
            ck(stUndecl.phase == "playing", "判据 9(未声明Sink): 起播进入 playing");
            ck(stUndecl.upsampleApplied == true, "判据 9(未声明Sink): 依本机上限策略升频生效");
            ck(stUndecl.servedRate == 88200, "判据 9(未声明Sink): 目标采样率取 ceiling 88200");
            ck(stUndecl.upsampleNote.find("渲染器未声明接收格式") != std::string::npos,
               "判据 9(未声明Sink): 中文 note 说明「渲染器未声明接收格式」");
            ck(stUndecl.upsampleNoteEn.find("renderer declared no receive format") != std::string::npos ||
               stUndecl.upsampleNoteEn.find("renderer undeclared") != std::string::npos,
               "判据 9(未声明Sink): 英文 note 包含未声明说明", stUndecl.upsampleNoteEn);

            mgr.stop();
        }

        // ================= 判据 10: DSD 源 + 开关开 =================
        // 依据：DSD 源文件通过 DoP 直通，绝不参与投放升频转码，并在 note 中如实陈述
        {
            const std::string dsfTestPath = make_cast_temp_wav_path("dsd_upsample_test") + ".dsf";
            // 构造合法的极小 DSF 文件
            std::vector<uint8_t> d;
            auto wr32 = [&](uint32_t v) {
                d.push_back(v & 0xff); d.push_back((v >> 8) & 0xff);
                d.push_back((v >> 16) & 0xff); d.push_back((v >> 24) & 0xff);
            };
            auto wr64 = [&](uint64_t v) {
                for (int i = 0; i < 8; ++i) d.push_back((v >> (i * 8)) & 0xff);
            };
            d.insert(d.end(), {'D','S','D',' '});
            wr64(28); wr64(0); wr64(0);
            d.insert(d.end(), {'f','m','t',' '});
            wr64(52); wr32(1); wr32(0); wr32(2); wr32(2); wr32(2822400); wr32(1);
            wr64(32); wr32(4096); wr32(0);
            d.insert(d.end(), {'d','a','t','a'});
            uint64_t dSize = 4096 * 2;
            wr64(12 + dSize);
            d.resize(d.size() + dSize, 0x55);
            uint64_t tot = d.size();
            for (int i = 0; i < 8; ++i) d[12 + i] = (tot >> (i * 8)) & 0xff;

            {
                std::ofstream out(dsfTestPath, std::ios::binary);
                out.write((char*)d.data(), d.size());
            }

            CastStartParams pDsd;
            pDsd.dev = descUrl;
            pDsd.file = dsfTestPath;
            pDsd.dop = true;
            pDsd.applyUpsample = true;
            pDsd.requestedRate = "88200";

            mgr.start(pDsd);
            for (int i = 0; i < 60; ++i) {
                if (mgr.get_state().phase == "playing") break;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            CastState stDsd = mgr.get_state();
            ck(stDsd.phase == "playing", "判据 10(DSD源): DSD 源起播进入 playing");
            ck(!stDsd.upsampleApplied, "判据 10(DSD源): upsampleApplied 保持 false");
            ck(stDsd.upsampleNote.find("DSD 源不参与投放升频") != std::string::npos,
               "判据 10(DSD源): 中文 note 说明「DSD 源不参与投放升频，保持 DoP 直通」");
            ck(stDsd.upsampleNoteEn.find("DSD source does not participate in cast upsampling") != std::string::npos,
               "判据 10(DSD源): 英文 note 说明 DSD 保持 DoP 直通");

            mgr.stop();
            std::remove(dsfTestPath.c_str());
        }

        // ================= 判据 11: 4 GiB 上限超限拒绝 (注入 seam) =================
        // 依据：WAV(RIFF) data 块长度为 32-bit uint，超过 4 GiB 必须直接拒绝，严禁产出谎报长度或截断损坏的假文件
        {
            size_t beforeCount = count_temp_rtacast();
            // 模拟将上限压到 500 字节，预计生成的 35KB 文件立刻触发防御门禁
            cast_test_hooks().maxWavBytesOverride = 500;

            CastStartParams pOver;
            pOver.dev = descUrl;
            pOver.file = srcWavPath;
            pOver.applyUpsample = true;
            pOver.requestedRate = "88200";

            mgr.start(pOver);
            for (int i = 0; i < 40; ++i) {
                if (mgr.get_state().phase == "error") break;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            CastState stOver = mgr.get_state();
            ck(stOver.phase == "error", "判据 11(4GiB上限): 超过上限时会话进入 error 状态");
            ck(stOver.error.find("超过 WAV(RIFF) 4 GiB 上限") != std::string::npos,
               "判据 11(4GiB上限): 中文错误提示明确指出超过 WAV(RIFF) 4 GiB 上限");
            ck(!stOver.errorEn.empty() && !has_cjk(stOver.errorEn),
               "判据 11(4GiB上限): 英文错误提示非空且不含中文", stOver.errorEn);
            ck(count_temp_rtacast() == beforeCount,
               "判据 11(4GiB上限): 拒绝后未落盘，临时目录无残留文件");

            cast_test_hooks().maxWavBytesOverride = -1; // 恢复
            mgr.stop();
        }

        // 清理测试源文件与 Mock
        mock.stop();
        std::remove(srcWavPath.c_str());
    }

    std::printf("\n=== 测试总结: %s (失败: %d) ===\n", g_fail ? "FAIL" : "PASS", g_fail);
    return g_fail ? 1 : 0;
}
