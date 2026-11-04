// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_cast_audio.cpp — Cast/AirPlay 音频转换离线精度、往返、下混、重采样与群延迟测试
//
// 测试纪律：
//   * 绝不连接真实音频设备或网络接收器（铁律 1）；
//   * 严格验证 44.1k/16bit 双声道 bit-exact 逐样本直通；
//   * 验证重采样输出时长与理论精确帧数严格一致（无截断或过度填充）；
//   * 验证单声道复制与多声道下混规则与诚实警告。
//   * 验证「格式声明与实际输出一致」：非 44100/2/16 的 CastAudioSpec 必须被拒绝（不得静默错位）。
//   * 验证 8bit 负样本转换不再依赖有符号左移（UB）；单独用 UBSan 构建复跑一次。
#include "audio/cast_pcm_convert.h"
#include "net/cast_url_parser.h"
#include <cstdio>
#include <cmath>
#include <vector>
#include <string>
#include <limits>
#include <stdexcept>
#include <cstring>

using namespace rta::audio;
using namespace rta::net;

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s %s\n", what, detail.c_str());
        ++g_fail;
    }
}

int main() {
    std::printf("=== test_cast_audio: Cast/AirPlay 音频转换与 URL 解析测试 ===\n\n");

    // =========================================================================
    // 1. URL 解析与 IPv6 括弧边界
    // =========================================================================
    std::printf("-- 1. AirPlay URL 与设备解析 --\n");
    {
        std::string host;
        uint16_t port = 0;

        ck(is_airplay_dev("airplay://192.168.1.10:5000/dev1"), "is_airplay_dev IPv4 正例");
        ck(is_airplay_dev("airplay://[fe80::1]:7000/dev2"), "is_airplay_dev IPv6 正例");
        ck(!is_airplay_dev("http://192.168.1.10:1400/desc.xml"), "is_airplay_dev HTTP 反例");

        // IPv4 标准 host:port
        ck(parse_airplay_dev("airplay://192.168.1.50:5000/my_speaker", host, port), "parse IPv4 host:port");
        ck(host == "192.168.1.50", "IPv4 host 正确", host);
        ck(port == 5000, "IPv4 port 正确", std::to_string(port));

        // IPv4 默认端口 5000
        ck(parse_airplay_dev("airplay://192.168.1.60/speaker", host, port), "parse IPv4 default port");
        ck(host == "192.168.1.60" && port == 5000, "IPv4 default 5000", host + ":" + std::to_string(port));

        // IPv6 括弧格式 [2001:db8::1]:7000
        ck(parse_airplay_dev("airplay://[2001:db8::1]:7000/dev_id", host, port), "parse bracketed IPv6 with port");
        ck(host == "2001:db8::1", "IPv6 host unbracketed", host);
        ck(port == 7000, "IPv6 port 正确", std::to_string(port));

        // IPv6 括弧无端口 [fe80::2]
        ck(parse_airplay_dev("airplay://[fe80::2]/dev", host, port), "parse bracketed IPv6 default port");
        ck(host == "fe80::2" && port == 5000, "IPv6 default 5000", host + ":" + std::to_string(port));

        // 畸形与非法输入
        ck(!parse_airplay_dev("airplay://[fe80::2:bad/dev", host, port), "未闭合括弧拒绝");
        ck(!parse_airplay_dev("airplay://192.168.1.1:abc/dev", host, port), "非法非数字端口拒绝");
        ck(!parse_airplay_dev("airplay://192.168.1.1:99999/dev", host, port), "端口越界拒绝");
    }

    // =========================================================================
    // 2. 音量转换与防爆音映射
    // =========================================================================
    std::printf("\n-- 2. AirPlay 音量标度与静音映射 --\n");
    {
        ck(airplay_db_to_percent(0.0) == 100, "0 dB 映射为 100%");
        ck(airplay_db_to_percent(-120.0) == 0, "-120 dB 静音映射为 0%");
        ck(airplay_db_to_percent(-150.0) == 0, "超低 dB 映射为 0%");
        ck(airplay_db_to_percent(5.0) == 100, "正 dB 夹紧为 100%");
        ck(airplay_db_to_percent(-20.0) > 0 && airplay_db_to_percent(-20.0) < 100, "-20 dB 落在正常听音范围");
        ck(airplay_db_to_percent(-10.0) > airplay_db_to_percent(-20.0), "音量单调性成立");
        ck(airplay_db_to_percent(std::numeric_limits<double>::quiet_NaN()) == 0,
           "NaN 不产生「已设置」的假音量（映射为 0%）");

        // 初始音量合法化：非有限值回落保守默认，越界夹紧，绝不放大
        const double nanv = std::numeric_limits<double>::quiet_NaN();
        const double infv = std::numeric_limits<double>::infinity();
        ck(sanitize_cast_volume_db(nanv) == kCastVolumeDefaultDb, "NaN 音量回落保守默认 -20 dB",
           std::to_string(sanitize_cast_volume_db(nanv)));
        ck(sanitize_cast_volume_db(infv) == kCastVolumeDefaultDb, "+Inf 音量回落保守默认");
        ck(sanitize_cast_volume_db(-infv) == kCastVolumeDefaultDb, "-Inf 音量回落保守默认");
        ck(sanitize_cast_volume_db(6.0) == 0.0, "正 dB 夹到 0 dB 上限（不放大）");
        ck(sanitize_cast_volume_db(-1000.0) == -144.0, "超低 dB 夹到 -144");
        ck(sanitize_cast_volume_db(-20.0) == -20.0, "合法值原样保留");

        // 设备标识查询串开关：键名必须精确匹配，避免 path/id 里的字样改变安全判定
        ck(airplay_dev_query_flag("airplay://192.0.2.10:5000/spk?pw=1", "pw"), "查询串 pw=1 判定为真");
        ck(airplay_dev_query_flag("airplay://192.0.2.10:5000/spk?PW=TRUE", "pw"), "键/值大小写不敏感");
        ck(airplay_dev_query_flag("airplay://192.0.2.10:5000/spk?pw", "pw"), "裸键视为真");
        ck(!airplay_dev_query_flag("airplay://192.0.2.10:5000/spk?pw=0", "pw"), "pw=0 为假");
        ck(!airplay_dev_query_flag("airplay://192.0.2.10:5000/spk?cpw=1", "pw"), "cpw=1 不得误命中 pw");
        ck(!airplay_dev_query_flag("airplay://192.0.2.10:5000/spk?enc=1", "pw"), "enc=1 不得误命中 pw");
        ck(!airplay_dev_query_flag("airplay://192.0.2.10:5000/spk-enc=1", "enc"), "id 里的 enc=1 不参与判定");
        ck(airplay_dev_query_flag("airplay://192.0.2.10:5000/spk?a=1&enc=1#frag", "enc"),
           "多键查询串 + 片段仍能取到 enc=1");
    }

    // =========================================================================
    // 3. 44.1k/16bit 立体声：Bit-Exact 逐样本直通测试
    // =========================================================================
    std::printf("\n-- 3. 44.1k/16bit 双声道 Bit-Exact 直通 --\n");
    {
        AudioBuffer buf;
        buf.rate = 44100;
        buf.channels = 2;
        buf.bits = 16;
        buf.isFloat = false;

        const size_t testFrames = 1000;
        buf.raw.resize(testFrames * 2);
        // 构造特定的特征测试序列（包含正负满幅、零、奇偶样本）
        for (size_t i = 0; i < testFrames; ++i) {
            int16_t s0 = static_cast<int16_t>((i * 12345) & 0xFFFF);
            int16_t s1 = static_cast<int16_t>((-static_cast<int>(i) * 54321) & 0xFFFF);
            if (i == 0) { s0 = 32767; s1 = -32768; }
            if (i == 1) { s0 = 0; s1 = 0; }
            buf.raw[i * 2 + 0] = static_cast<int32_t>(s0);
            buf.raw[i * 2 + 1] = static_cast<int32_t>(s1);
        }

        CastAudioConversionResult res = convert_audio_for_cast(buf);
        ck(res.bitExactDirect, "44.1k/16bit 2ch 触发 bitExactDirect 标志");
        ck(res.frames == testFrames, "输出帧数严格相等", std::to_string(res.frames));
        ck(res.pcm.size() == testFrames * 2, "PCM 样本数严格匹配");

        bool identical = true;
        for (size_t i = 0; i < testFrames * 2; ++i) {
            if (res.pcm[i] != static_cast<int16_t>(buf.raw[i])) {
                identical = false;
                break;
            }
        }
        ck(identical, "逐样本逐比特逐符号严格无损相等 (Bit-Exact)");
        ck(std::abs(res.durationSec - (static_cast<double>(testFrames) / 44100.0)) < 1e-6, "时长换算精确");
    }

    // =========================================================================
    // 4. 单声道与多声道下混诚实性测试
    // =========================================================================
    std::printf("\n-- 4. 声道提取与诚实下混 --\n");
    {
        // 单声道复制
        AudioBuffer mono;
        mono.rate = 44100;
        mono.channels = 1;
        mono.bits = 16;
        mono.isFloat = false;
        mono.raw = { 1000, -2000, 3000, -4000 };

        auto resMono = convert_audio_for_cast(mono);
        ck(!resMono.bitExactDirect, "单声道不走 direct 旁路");
        ck(resMono.frames == 4, "单声道帧数保留", std::to_string(resMono.frames));
        ck(!resMono.warningZh.empty(), "单声道输出保留明确中文提示", resMono.warningZh);
        ck(!resMono.warningEn.empty(), "单声道输出保留明确英文提示", resMono.warningEn);
        ck(resMono.pcm.size() == 8, "单声道扩展为双声道");

        // 单声道复制必须是**逐样本精确**的（不是「差不多」）：
        // 44.1k/16bit 单声道走 float 平面通路，若标度写错（32767/32768 之争）会掉 1 LSB。
        {
            const int16_t expect[4] = { 1000, -2000, 3000, -4000 };
            bool exact = true;
            for (size_t i = 0; i < 4; ++i) {
                if (resMono.pcm[i * 2 + 0] != expect[i] || resMono.pcm[i * 2 + 1] != expect[i]) {
                    exact = false;
                }
            }
            ck(exact, "单声道复制逐样本精确（含负值），左右声道相同",
               std::to_string(resMono.pcm[2]) + "/" + std::to_string(resMono.pcm[3]));
        }

        // 5.1 六声道：警告必须写出「按默认顺序假设 + 不宣称 ITU 一致性」，不能只说 BS.775
        AudioBuffer multi;
        multi.rate = 44100;
        multi.channels = 6;
        multi.bits = 16;
        multi.isFloat = false;
        const size_t mFrames = 200;
        multi.raw.resize(mFrames * 6, 0);
        // L=0.5, R=0.5, C=0.2
        for (size_t i = 0; i < mFrames; ++i) {
            multi.raw[i * 6 + 0] = 16384; // L
            multi.raw[i * 6 + 1] = 16384; // R
            multi.raw[i * 6 + 2] = 6553;  // C
        }
        auto resMulti = convert_audio_for_cast(multi);
        ck(resMulti.frames == mFrames, "6声道帧数保留");
        ck(resMulti.warningZh.find("5.1") != std::string::npos &&
               resMulti.warningZh.find("LFE") != std::string::npos,
           "6声道中文警告写明 5.1 顺序假设与 LFE 丢弃", resMulti.warningZh);
        ck(resMulti.warningZh.find("不宣称") != std::string::npos,
           "6声道中文警告明确不宣称 ITU-R BS.775 一致性", resMulti.warningZh);
        ck(resMulti.warningEn.find("not claimed") != std::string::npos,
           "6声道英文警告明确 not claimed（不宣称一致性）", resMulti.warningEn);
        // 下混数值：L' = (0.5 + 0.7071*0.2) / 2.4142 ≈ 0.2657 → ≈ 8706
        ck(resMulti.pcm[0] > 8000 && resMulti.pcm[0] < 9400,
           "6声道下混幅度落在预期区间（未满幅、未归零）", std::to_string(resMulti.pcm[0]));

        // 8 声道：不得静默丢弃、不得假装下混 —— 必须写明第 3..8 声道不会出现在输出里
        AudioBuffer surround8;
        surround8.rate = 44100;
        surround8.channels = 8;
        surround8.bits = 16;
        surround8.isFloat = false;
        const size_t s8Frames = 32;
        surround8.raw.assign(s8Frames * 8, 0);
        for (size_t i = 0; i < s8Frames; ++i) {
            surround8.raw[i * 8 + 0] = 1000;                    // FL
            surround8.raw[i * 8 + 1] = -1000;                   // FR
            for (int c = 2; c < 8; ++c) surround8.raw[i * 8 + (size_t)c] = 30000; // 其余声道
        }
        auto res8 = convert_audio_for_cast(surround8);
        ck(res8.frames == s8Frames, "8声道帧数保留");
        ck(res8.warningZh.find("第 3..8") != std::string::npos,
           "8声道中文警告明确写出被忽略的声道范围", res8.warningZh);
        ck(res8.warningZh.find("未下混") != std::string::npos, "8声道中文警告声明未下混", res8.warningZh);
        ck(res8.pcm[0] == 1000 && res8.pcm[1] == -1000,
           "8声道只取前两声道，后置/高度声道未被混入（不再静默忽略）",
           std::to_string(res8.pcm[0]) + "/" + std::to_string(res8.pcm[1]));

        // 3 声道：未知布局 → 前 2 声道 + 明确提示
        AudioBuffer three;
        three.rate = 44100;
        three.channels = 3;
        three.bits = 16;
        three.isFloat = false;
        three.raw.assign(8 * 3, 7);
        auto res3 = convert_audio_for_cast(three);
        ck(res3.frames == 8 && res3.pcm.size() == 16, "3声道帧数/样本数正确");
        ck(res3.warningZh.find("非标布局") != std::string::npos && res3.warningZh.find("未做下混") != std::string::npos,
           "3声道中文警告写明非标布局且未下混", res3.warningZh);
    }

    // =========================================================================
    // 4b. 8bit 负样本：不再用有符号左移（UB）
    // =========================================================================
    std::printf("\n-- 4b. 8bit 负样本精确转换（左移 UB 修复）--\n");
    {
        ck(sample_to_int16_exact(-128, 8, false) == -32768, "8bit -128 → -32768");
        ck(sample_to_int16_exact(-1, 8, false) == -256, "8bit -1 → -256");
        ck(sample_to_int16_exact(0, 8, false) == 0, "8bit 0 → 0");
        ck(sample_to_int16_exact(127, 8, false) == 32512, "8bit 127 → 32512");
        ck(sample_to_int16_exact(-32768, 16, false) == -32768, "16bit 负满幅保持不变");
        ck(sample_to_int16_exact(-8388608, 24, false) == -32768, "24bit 负满幅 → -32768");
        ck(sample_to_int16_exact(8388607, 24, false) == 32767, "24bit 正满幅 → 32767");
        ck(sample_to_int16_exact(-2147483647 - 1, 32, false) == -32768, "32bit 负满幅 → -32768");
        ck(sample_to_int16_exact(2147483647, 32, false) == 32767, "32bit 正满幅 → 32767");
        float f = 0.5f;
        int32_t fbits = 0;
        std::memcpy(&fbits, &f, 4);
        ck(sample_to_int16_exact(fbits, 32, true) == 16384, "float 0.5 → 16384");
        float fOver = 1.5f;
        std::memcpy(&fbits, &fOver, 4);
        ck(sample_to_int16_exact(fbits, 32, true) == 32767, "float 1.5 饱和到 32767");
    }

    // =========================================================================
    // 4c. 目标格式白名单：声明与实际必须一致
    // =========================================================================
    std::printf("\n-- 4c. CastAudioSpec 目标格式白名单 --\n");
    {
        AudioBuffer buf;
        buf.rate = 44100;
        buf.channels = 2;
        buf.bits = 16;
        buf.raw.assign(64, 0);

        auto expect_reject = [](const char* what, uint32_t rate, int ch, int bits) {
            CastAudioSpec spec;
            spec.targetRate = rate;
            spec.targetChannels = ch;
            spec.targetBits = bits;
            bool threw = false;
            std::string msg;
            try {
                (void)convert_audio_for_cast(AudioBuffer{}, spec);  // 空缓冲也要先过白名单
            } catch (const std::invalid_argument& e) {
                threw = true;
                msg = e.what();
            } catch (...) {
                threw = false;
            }
            ck(threw, what, msg);
        };
        expect_reject("48000 Hz 目标被拒绝（不会产出「自称 48k」的 44.1k PCM）", 48000, 2, 16);
        expect_reject("3 声道目标被拒绝（输出缓冲永远是 2ch）", 44100, 3, 16);
        expect_reject("32 bit 目标被拒绝（输出永远是 int16）", 44100, 2, 32);

        bool okDefault = true;
        try {
            CastAudioSpec ok;
            auto r = convert_audio_for_cast(buf, ok);
            okDefault = (r.frames == 32 && r.pcm.size() == 64);
        } catch (...) {
            okDefault = false;
        }
        ck(okDefault, "默认 44100/2/16 白名单通过并正常输出");
    }

    // =========================================================================
    // 5. 重采样时长、延迟补偿与精确帧数测试 (48k / 96k / 176.4k -> 44.1k)
    // =========================================================================
    std::printf("\n-- 5. 重采样帧数守恒与群延迟排空 (48k/96k/176.4k -> 44.1k) --\n");
    {
        uint32_t rates[] = { 48000, 96000, 176400 };
        for (uint32_t inRate : rates) {
            AudioBuffer buf;
            buf.rate = inRate;
            buf.channels = 2;
            buf.bits = 16;
            buf.isFloat = false;

            // 设定 0.5 秒的音频
            const size_t inFrames = inRate / 2;
            buf.raw.resize(inFrames * 2, 0);

            // 在第 100 帧放置脉冲，测试延迟补偿
            buf.raw[100 * 2 + 0] = 30000;
            buf.raw[100 * 2 + 1] = 30000;

            auto res = convert_audio_for_cast(buf);
            const size_t expectedOutFrames = static_cast<size_t>(std::llround(static_cast<double>(inFrames) * 44100.0 / inRate));
            ck(res.frames == expectedOutFrames,
               ("重采样帧数严格守恒 (" + std::to_string(inRate) + " -> 44100)").c_str(),
               "got=" + std::to_string(res.frames) + ", expected=" + std::to_string(expectedOutFrames));
            ck(res.pcm.size() == expectedOutFrames * 2, "交错 PCM 样本数匹配");

            // 检查脉冲峰值位置：100 * (44100 / inRate)
            const size_t expectedPeakFrame = static_cast<size_t>(std::llround(100.0 * 44100.0 / inRate));
            size_t maxFrame = 0;
            int16_t maxVal = 0;
            for (size_t f = 0; f < res.frames; ++f) {
                int16_t v = res.pcm[f * 2 + 0];
                if (v > maxVal) {
                    maxVal = v;
                    maxFrame = f;
                }
            }
            int diff = static_cast<int>(maxFrame) - static_cast<int>(expectedPeakFrame);
            ck(std::abs(diff) <= 1,
               ("重采样群延迟已精确补偿 (" + std::to_string(inRate) + ") 峰值对齐").c_str(),
               "peakFrame=" + std::to_string(maxFrame) + " expected=" + std::to_string(expectedPeakFrame));
        }
    }

    // =========================================================================
    // 6. 96 kHz 尾部脉冲 + 零尾：证明「最后几个源样本没有被丢掉」
    //
    // 为什么单独测：旧实现只喂了 inFrames 个输入、没有补零排空，滤波器的拖尾被截断，
    // 于是「最后 ≤ group-delay 的那一段」直接消失。判据必须是**尾部脉冲出现在预期位置**
    // 且其后再无能量 —— 只看总帧数守恒抓不到这个问题（帧数守恒但内容提前截断）。
    // =========================================================================
    std::printf("\n-- 6. 96 kHz 尾部脉冲与零尾（不丢尾）--\n");
    {
        const uint32_t inRate = 96000;
        const size_t inFrames = 24000;                  // 0.25 s
        AudioBuffer buf;
        buf.rate = inRate;
        buf.channels = 2;
        buf.bits = 16;
        buf.isFloat = false;
        buf.raw.assign(inFrames * 2, 0);

        // 脉冲放在**倒数第二个**源样本：任何尾部截断都会让它变弱或消失
        const size_t impulseIn = inFrames - 2;
        buf.raw[impulseIn * 2 + 0] = 30000;
        buf.raw[impulseIn * 2 + 1] = 30000;

        auto res = convert_audio_for_cast(buf);
        const size_t expectedOutFrames =
            static_cast<size_t>(std::llround(static_cast<double>(inFrames) * 44100.0 / inRate));
        const size_t expectedPeakFrame =
            static_cast<size_t>(std::llround(static_cast<double>(impulseIn) * 44100.0 / inRate));
        ck(res.frames == expectedOutFrames, "96k 尾部脉冲：输出帧数仍严格守恒",
           "got=" + std::to_string(res.frames) + ", expected=" + std::to_string(expectedOutFrames));

        size_t maxFrame = 0;
        int maxAbs = 0;
        for (size_t f = 0; f < res.frames; ++f) {
            int v = std::abs(static_cast<int>(res.pcm[f * 2 + 0]));
            if (v > maxAbs) { maxAbs = v; maxFrame = f; }
        }
        const int diff = static_cast<int>(maxFrame) - static_cast<int>(expectedPeakFrame);
        ck(std::abs(diff) <= 2,
           "96k 尾部脉冲出现在预期输出位置（未被截断/未提前）",
           "peakFrame=" + std::to_string(maxFrame) + " expected=" + std::to_string(expectedPeakFrame));
        ck(maxAbs > 3000, "96k 尾部脉冲幅度未被排空过程吃掉（>3000）", std::to_string(maxAbs));

        // 零尾：脉冲之后（留 24 帧给插值拖尾）不应再有能量；量化抖动只允许 ±1 LSB
        int tailMax = 0;
        for (size_t f = expectedPeakFrame + 24; f < res.frames; ++f) {
            tailMax = std::max(tailMax, std::abs(static_cast<int>(res.pcm[f * 2 + 0])));
        }
        ck(tailMax <= 1, "96k 尾部脉冲之后是零尾（仅 ±1 LSB 抖动）", std::to_string(tailMax));
        // 同时确认脉冲之前是静音（没有把拖尾/垃圾提前混进来）
        int headMax = 0;
        for (size_t f = 0; f + 64 < expectedPeakFrame; ++f) {
            headMax = std::max(headMax, std::abs(static_cast<int>(res.pcm[f * 2 + 0])));
        }
        ck(headMax <= 1, "96k 脉冲之前为静音（无预振铃/无错位）", std::to_string(headMax));
    }

    std::printf("\n=== test_cast_audio 测试总结: %s (失败: %d) ===\n", g_fail ? "FAIL" : "PASS", g_fail);
    return g_fail ? 1 : 0;
}
