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

    // ================= 3) 设备列表只读查询与接口健壮性 =================
    std::printf("\n-- 3. 设备列表查询接口 --\n");
    {
        // forceRescan = false，不触发阻塞式全网扫描
        auto devs = mgr.get_devices(false);
        ck(true, "get_devices 接口调用正常且不崩潰");
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

    std::printf("\n=== 测试总结: %s (失败: %d) ===\n", g_fail ? "FAIL" : "PASS", g_fail);
    return g_fail ? 1 : 0;
}
