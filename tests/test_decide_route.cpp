// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_decide_route.cpp — src/platform/audio_out.h：路由判定纯函数
//
// 为什么要有这个测试（PLATFORM.md §11.7 明确列为未做项）：
//   decide_route 是 bit-perfect 判定的【唯一实现】。它错了，UI 就会把"重采样后的声音"
//   标成"逐位直通"——这是本项目的核心承诺，不能只靠代码评审。
//
// 判据（铁律 3）：被测对象是纯函数，逐条断言 输入(源格式+设备能力+是否允许转换) -> 输出(路由+理由)。
//   * 不打开声卡、不写文件、不发声音（铁律 1：本测试全程无声）
//   * 断言的重点不是"没崩"，而是【具体路由种类 + 具体输出格式 + reason 非空且提到关键信息】
//   * 特别覆盖"必须拒绝而不是静默替换"的四个分支（§5.3），因为静默降级是最危险的失败模式
//
// ⚠️ 未解决项（铁律 4）：
//   1) 本测试只覆盖 decide_route 这一个纯函数；CoreAudio 后端（audio_out_coreaudio.h）
//      的真实 open/start/write 没有自动化测试 —— 那需要真实声卡且会改变系统音频状态。
//   2) "设备实际支持哪些位深"在 caps() 里是保守假设（16/24/32 全部报告为可请求），
//      不是实测。真机验证需要逐格式 open() 一次（会占用设备），本轮未做。
#include "platform/audio_out.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace rta::platform;

static int g_failed = 0;
static int g_total = 0;

static void check(bool cond, const char* what) {
    ++g_total;
    if (!cond) {
        ++g_failed;
        std::printf("  [FAIL] %s\n", what);
    }
}

// 构造一个"标准 USB DAC"能力：支持到 768k、独占、能 bit-perfect
static DeviceCaps dac_caps() {
    DeviceCaps c;
    c.rates = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    c.bitDepths = {16, 24, 32};
    c.maxChannels = 2;
    c.exclusiveMode = true;
    c.bitPerfectCapable = true;
    c.dsd = DsdTransport::DoP;
    c.dopCarrierRate = 176400;
    return c;
}

// 构造一个"受限设备"：只有 48k、共享模式（类似内置扬声器被系统混音）
static DeviceCaps limited_caps() {
    DeviceCaps c;
    c.rates = {48000};
    c.bitDepths = {16, 24};
    c.maxChannels = 2;
    c.exclusiveMode = false;
    c.bitPerfectCapable = false;
    c.dsd = DsdTransport::None;
    return c;
}

static void case_pcm_bit_perfect() {
    std::printf("[1] PCM 源格式设备支持且独占 -> PcmBitPerfect\n");
    SourceSpec s; s.isDsd = false; s.rate = 44100; s.bits = 16;
    const auto d = decide_route(s, dac_caps(), false);
    check(d.kind == RouteKind::PcmBitPerfect, "44100/16 应为逐位直通");
    check(d.outRate == 44100 && d.outBits == 16, "输出格式应等于源格式");
    check(d.bitPerfect(), "bitPerfect() 应为 true");
    check(!d.reason.empty(), "reason 必须非空（不许静默）");
}

static void case_pcm_converted_allowed() {
    std::printf("[2] 设备不支持源格式 + 允许转换 -> PcmConverted 且非 bit-perfect\n");
    SourceSpec s; s.isDsd = false; s.rate = 44100; s.bits = 16;
    const auto d = decide_route(s, limited_caps(), true);
    check(d.kind == RouteKind::PcmConverted, "应转为 PcmConverted");
    check(!d.bitPerfect(), "转换路径 bitPerfect() 必须为 false");
    check(d.outRate == 48000, "应选不小于源率的最小支持率 48000");
    check(d.reason.find("非 bit-perfect") != std::string::npos,
          "reason 必须挑明非 bit-perfect（用户要能看见）");
}

static void case_pcm_refused() {
    std::printf("[3] 设备不支持源格式 + 不允许转换 -> Refused（绝不静默替换）\n");
    SourceSpec s; s.isDsd = false; s.rate = 44100; s.bits = 16;
    const auto d = decide_route(s, limited_caps(), false);
    check(d.kind == RouteKind::Refused, "必须拒绝而不是静默换成 48000");
    check(!d.bitPerfect(), "拒绝时 bitPerfect() 必须为 false");
    check(d.reason.find("44100") != std::string::npos, "reason 要点名不支持的格式");
    check(d.reason.find("拒绝") != std::string::npos, "reason 要说明已拒绝");
}

static void case_dsd_dop() {
    std::printf("[4] DSD64 + 设备支持 176400 承载 -> DoP（仍是 bit-perfect）\n");
    SourceSpec s; s.isDsd = true; s.rate = 2822400; s.bits = 0;   // DSD64
    const auto d = decide_route(s, dac_caps(), false);
    check(d.kind == RouteKind::Dop, "应为 DoP");
    check(d.outRate == 176400, "承载率应为 2822400/16 = 176400");
    check(d.outBits == 24, "DoP 容器应为 24 bit");
    check(d.bitPerfect(), "DoP 是 bit-perfect（只是换容器，DSD 位不丢）");
}

static void case_dsd_native() {
    std::printf("[5] DSD + 设备支持 Native 且速率匹配 -> NativeDsd\n");
    DeviceCaps c = dac_caps();
    c.dsd = DsdTransport::Native;
    c.nativeDsdRate = 2822400;
    SourceSpec s; s.isDsd = true; s.rate = 2822400; s.bits = 0;
    const auto d = decide_route(s, c, false);
    check(d.kind == RouteKind::NativeDsd, "应为 Native DSD");
    check(d.outRate == 2822400, "输出率应等于 DSD 比特率");
    check(d.bitPerfect(), "Native DSD 是 bit-perfect");
}

static void case_dsd_refused() {
    std::printf("[6] DSD + 设备无 DSD 能力 + 不允许转换 -> Refused\n");
    SourceSpec s; s.isDsd = true; s.rate = 2822400; s.bits = 0;
    const auto d = decide_route(s, limited_caps(), false);
    check(d.kind == RouteKind::Refused, "必须拒绝 DSD（不许静默降成 PCM）");
    check(d.reason.find("176400") != std::string::npos,
          "reason 要写清需要 176400 Hz 的 DoP 承载");
    check(d.reason.find("DSD") != std::string::npos, "reason 要点明是 DSD 问题");
}

static void case_dsd_converted() {
    std::printf("[7] DSD + 无 DSD 能力 + 显式允许转换 -> PcmConverted\n");
    SourceSpec s; s.isDsd = true; s.rate = 2822400; s.bits = 0;
    const auto d = decide_route(s, limited_caps(), true);
    check(d.kind == RouteKind::PcmConverted, "显式允许时才可转 PCM");
    check(!d.bitPerfect(), "DSD->PCM 不是 bit-perfect");
    check(d.outRate == 48000, "应落到设备支持的最低率 48000");
}

// 边界：设备能力为空（未枚举到设备）时必须拒绝，不能崩
static void case_empty_caps() {
    std::printf("[8] 设备能力为空 -> Refused（且不崩）\n");
    DeviceCaps empty;
    SourceSpec s; s.isDsd = false; s.rate = 44100; s.bits = 16;
    const auto d = decide_route(s, empty, false);
    check(d.kind == RouteKind::Refused, "空能力必须拒绝");
    check(!d.reason.empty(), "reason 必须非空");

    SourceSpec dsd; dsd.isDsd = true; dsd.rate = 2822400;
    const auto d2 = decide_route(dsd, empty, false);
    check(d2.kind == RouteKind::Refused, "空能力下 DSD 也必须拒绝");
}

// 边界：独占但 bitPerfectCapable=false（如 WASAPI 共享）不得判成 bit-perfect
static void case_shared_not_bitperfect() {
    std::printf("[9] 共享模式（exclusive=false）-> 即使格式支持也不许 bit-perfect\n");
    DeviceCaps c = dac_caps();
    c.exclusiveMode = false;
    c.bitPerfectCapable = false;
    SourceSpec s; s.isDsd = false; s.rate = 44100; s.bits = 16;
    const auto d = decide_route(s, c, true);
    check(d.kind != RouteKind::PcmBitPerfect, "共享模式绝不能标成逐位直通");
    check(!d.bitPerfect(), "共享模式 bitPerfect() 必须 false");
}

int main() {
    std::printf("== decide_route 单元测试（纯函数，全程无声）==\n");
    case_pcm_bit_perfect();
    case_pcm_converted_allowed();
    case_pcm_refused();
    case_dsd_dop();
    case_dsd_native();
    case_dsd_refused();
    case_dsd_converted();
    case_empty_caps();
    case_shared_not_bitperfect();

    std::printf("\n%d/%d 断言通过\n", g_total - g_failed, g_total);
    if (g_failed) {
        std::printf("FAILED: %d 条断言不成立\n", g_failed);
        return 1;
    }
    std::printf("PASS\n");
    return 0;
}
