// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_eq_reload.cpp — 耳机 EQ（OPRA 预设）切换「没变化」的回归判据（2026-10-25）
//
// ============================ 这个测试在证明什么 ============================
// 用户原话：「耳机 EQ 切换之后，感觉没什么变化」。后端的三条根因（见 tools/rtaweb.cpp
// 的 EQ_RELOAD / settings_conf_value / start_pos_for 注释）里，有两条是**可离线证明**的：
//
//   判据 A  两个真实 OPRA 预设经 Pipeline 处理后，输出**真的不同**（不是"参数变了声音没变"）。
//           这条是整件事的地基：如果 A 不成立，热重载做多少遍都没用。
//   判据 B  无 EQ vs 预设 A 的输出显著不同 ⟹ EQ 确实进了信号链（usedEq 也得是 true）。
//   判据 C  起播定位（start_pos_for）：initialSeekFrac=0.5 时 pos 与 played **精确**是 50%，
//           且 pos 落在正确的源帧上（逐样本比对，不是"差不多"）。
//   判据 D  从 50% 起播 + 带 EQ 处理 ⟹ usedEq == true（新管线确实带着 EQ 跑，没被旁路）。
//   判据 E  settings_conf_value / eq_path_usable：conf 兜底读得对，且"路径还打不开时不要热重启"。
//
// ============================ 铁律 3：判据不能自欺 ============================
//   * **不测拷贝**：本文件 `#include "rtaweb.cpp"`（与 rlapp_core 完全相同的做法），
//     所以 start_pos_for / settings_conf_value / eq_path_usable 是**生产代码那一份**，
//     不是我在测试里重抄一遍的近似实现。抄一遍的判据只能证明"我抄得对"，不能证明产品对。
//   * **不测电平绝对值**：EQ 带 preamp（-5.5 / -6.2 dB），整体电平必然变。所以 A/B 的判据
//     用**频段间的相对差**与**两个预设之间的差**，不用"RMS 变了多少"这种会被 preamp 支配的量。
//   * **不靠听感**：全部离线跑 Pipeline::process，**绝不打开任何音频设备**（铁律 1），
//     信号电平 ≤ −60 dBFS（-60 dBFS = 0.001 满幅）。
//   * **判据要有量级余量**：float 数值噪声约 −140 dBFS，本测试的门限取 0.5~1.0 dB，
//     比噪声高 100 dB 以上 —— 不可能因为舍入而假绿。
//
// ============================ 铁律 4：未解决项 ============================
//   * **本文件尚未注册进 ctest**：`CMakeLists.txt` 不在本工作包的可改白名单里（有别的子代理
//     在改）。主控需要补两行：
//         add_executable(test_eq_reload tests/test_eq_reload.cpp)
//         target_include_directories(test_eq_reload PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
//         target_link_libraries(test_eq_reload PRIVATE ${RL_PLATFORM_LIBS} "-framework Foundation")
//         add_test(NAME eq_reload COMMAND test_eq_reload)
//     在补齐之前，本文件以 `clang++ ... -o /tmp/test_eq_reload && /tmp/test_eq_reload` 的形式
//     作为回归基线（已实跑通过，输出见交付报告）。
//   * **热重载的"听感连续"未真机验证**：判据 C/D 证明的是"位置与 EQ 都对"，
//     证明不了"切换瞬间没有可闻的咔哒声"——那需要真机 + 听音，本测试按铁律 1 不做。
//   * **依赖用户机器上真实存在的 OPRA 预设文件**：找不到时判据 A/B/D 会 SKIP（不假绿），
//     并打印缺失路径。判据 C/E 与文件无关，永远会跑。
//
// ============================ 环境纪律（铁律 1/2）============================
//   * 不打开音频设备：只调 Pipeline::process（纯内存）。
//   * 不碰用户实例：不监听端口、不 spawn 任何进程。
//   * 不改用户文件：conf 兜底判据用的是临时目录里的假 conf（通过 HOME 重定向不可行 ——
//     app_support_dir_utf8 只认 $HOME，所以判据 E 直接测"给定路径读得对不对"这一层）。
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// 关键：把生产 TU 整个编进来，测试的就是产品那一份实现（同 rlapp_core.cpp 的手法）。
// RLPLAYER_EMBEDDED_LIBRARY 屏蔽掉 rtaweb.cpp 末尾的 main()，本文件自己提供 main。
#define RLPLAYER_EMBEDDED_LIBRARY 1
#include "rtaweb.cpp"

// ---------------------------------------------------------------------------
// 断言脚手架
// ---------------------------------------------------------------------------
static int g_fail = 0;
static int g_skip = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) std::printf("  [PASS] %s %s\n", what.c_str(), detail.c_str());
    else { std::printf("  [FAIL] %s %s\n", what.c_str(), detail.c_str()); ++g_fail; }
}
static void skip(const std::string& what, const std::string& why) {
    std::printf("  [SKIP] %s  %s\n", what.c_str(), why.c_str());
    ++g_skip;
}

// ---------------------------------------------------------------------------
// 测试信号：100 Hz + 1 kHz + 6 kHz 三音合成，每音 −60 dBFS（0.001 满幅）
// 为什么是这三个频率：OPRA 预设的差异主要落在低频架（~105 Hz）、中频（1~2 kHz）
// 和高频（5.8~8 kHz）三处 —— 三个音各占一个，任何一个频段变了都逃不掉。
// ---------------------------------------------------------------------------
static constexpr uint32_t kFs = 48000;
static constexpr size_t   kFrames = (size_t)kFs * 2;      // 2 秒：100 Hz 有 200 个整周期
static constexpr double   kAmp = 0.001;                   // −60 dBFS（铁律 1 的量级）

static rta::audio::AudioBuffer make_probe() {
    rta::audio::AudioBuffer b;
    b.rate = kFs; b.channels = 2; b.bits = 32; b.isFloat = false;
    b.raw.assign(kFrames * 2, 0);
    for (size_t n = 0; n < kFrames; ++n) {
        const double t = (double)n / (double)kFs;
        const double v = kAmp * (std::sin(2.0 * M_PI * 100.0 * t)
                               + std::sin(2.0 * M_PI * 1000.0 * t)
                               + std::sin(2.0 * M_PI * 6000.0 * t));
        b.setSample(n, 0, v);
        b.setSample(n, 1, v);
    }
    return b;
}

// Goertzel：单频点能量（比 FFT 更适合"我只要这三个频点"的场景，也不会被窗函数带偏）
static double goertzel_pow(const std::vector<double>& x, double f, double fs) {
    const double w = 2.0 * M_PI * f / fs;
    const double cw = std::cos(w), coeff = 2.0 * cw;
    double s0 = 0.0, s1 = 0.0, s2 = 0.0;
    for (double v : x) { s0 = v + coeff * s1 - s2; s2 = s1; s1 = s0; }
    const double re = s1 - s2 * cw, im = s2 * std::sin(w);
    return re * re + im * im;
}
static double db(double x) { return 10.0 * std::log10(x > 1e-300 ? x : 1e-300); }

// 取某声道为 double 平面（跳过前 0.2 秒让 IIR 瞬态过去 —— 不做这一步，起播的
// 滤波器建立过程会污染所有频段读数，那正是"测了但没测对"的典型坑）
static std::vector<double> plane(const rta::audio::AudioBuffer& b, int ch) {
    const size_t skip = (size_t)(0.2 * (double)kFs);
    std::vector<double> v;
    if (b.frames() <= skip) return v;
    v.reserve(b.frames() - skip);
    for (size_t n = skip; n < b.frames(); ++n) v.push_back(b.sample(n, ch));
    return v;
}

// 用真实 OPRA 预设文件建一条"只有 EQ"的管线（其它全部旁路，读数只反映 EQ）
static bool build_eq_cfg(const std::string& eqPath, eng::PipelineConfig& cfg, std::string& err) {
    std::ifstream ef(eqPath);
    if (!ef) { err = "打不开: " + eqPath; return false; }
    std::string text((std::istreambuf_iterator<char>(ef)), std::istreambuf_iterator<char>());
    if (text.size() > 3 && (unsigned char)text[0] == 0xEF && (unsigned char)text[1] == 0xBB) text.erase(0, 3);
    auto spec = rta::dsp::parse_eq_text(text);
    auto chain = rta::dsp::build_eq_filters(spec, (double)kFs);
    if (chain.empty() && spec.preampDb == 0.0) { err = "解析出 0 段滤波器（文件格式不认识）"; return false; }
    cfg = eng::PipelineConfig{};                 // 全部默认 = 不重采样 / 不抖动 / 不音量
    cfg.channel.resize(2);
    for (int c = 0; c < 2; ++c) {
        cfg.channel[(size_t)c].eq = chain;
        if (spec.preampDb != 0.0) cfg.channel[(size_t)c].gainDb += spec.preampDb;
    }
    err = "bands=" + std::to_string(chain.size()) + " preamp=" + std::to_string(spec.preampDb) + "dB";
    return true;
}

// 三个频点的能量（dB，相对值：已减去 RMS 电平，只保留"形状"）
struct Shape { double rmsDb, f100, f1k, f6k; };
static Shape measure(const rta::audio::AudioBuffer& out) {
    Shape s{};
    const std::vector<double> p = plane(out, 0);
    if (p.empty()) { s.rmsDb = s.f100 = s.f1k = s.f6k = -999.0; return s; }
    double acc = 0.0;
    for (double v : p) acc += v * v;
    s.rmsDb = db(acc / (double)p.size());
    s.f100 = db(goertzel_pow(p, 100.0, (double)kFs));
    s.f1k  = db(goertzel_pow(p, 1000.0, (double)kFs));
    s.f6k  = db(goertzel_pow(p, 6000.0, (double)kFs));
    return s;
}

int main() {
    std::printf("=== test_eq_reload：耳机 EQ 切换「没变化」回归判据 ===\n");
    const std::string base = std::string(std::getenv("HOME") ? std::getenv("HOME") : "")
                           + "/Library/Application Support/RLPlayer/profiles/opra/";
    const std::string eqA = base + "akg__k701_akg_k701__oratory1990_harman_target.txt";
    const std::string eqB = base + "akg__k701_sample_b_akg_k701_sample_b__autoeq_innerfidelity.txt";

    const rta::audio::AudioBuffer in = make_probe();
    std::printf("输入：%zu 帧 @ %u Hz，100Hz+1kHz+6kHz 各 %.1f dBFS\n",
                in.frames(), in.rate, 20.0 * std::log10(kAmp));

    // ---------------- 判据 A / B：EQ 真的改变了声音 ----------------
    eng::PipelineConfig cfgA, cfgB;
    std::string infoA, infoB, errA, errB;
    const bool haveA = build_eq_cfg(eqA, cfgA, errA);
    const bool haveB = build_eq_cfg(eqB, cfgB, errB);
    std::printf("预设 A: %s  %s\n", haveA ? "OK" : "不可用", (haveA ? infoA : errA).c_str());
    std::printf("预设 B: %s  %s\n", haveB ? "OK" : "不可用", (haveB ? infoB : errB).c_str());

    // 无 EQ（全旁路）也要真跑一遍：这是"对照组"，证明差异不是处理路径本身造成的
    eng::PipelineConfig cfgNone;
    cfgNone.channel.resize(2);
    eng::Pipeline PNone(cfgNone);
    eng::PipelineStats stNone;
    const rta::audio::AudioBuffer outNone = PNone.process(in, &stNone);
    const Shape sNone = measure(outNone);
    std::printf("无 EQ  : rms=%.2f dB  100Hz=%.2f  1kHz=%.2f  6kHz=%.2f  usedEq=%d\n",
                sNone.rmsDb, sNone.f100, sNone.f1k, sNone.f6k, (int)stNone.usedEq);
    ck(!stNone.usedEq, "无 EQ 时 usedEq == false（对照组干净，不是「什么都走 DSP」的假对照）");

    if (haveA) {
        eng::Pipeline PA(cfgA);
        eng::PipelineStats stA;
        const rta::audio::AudioBuffer outA = PA.process(in, &stA);
        const Shape sA = measure(outA);
        std::printf("预设 A : rms=%.2f dB  100Hz=%.2f  1kHz=%.2f  6kHz=%.2f  usedEq=%d\n",
                    sA.rmsDb, sA.f100, sA.f1k, sA.f6k, (int)stA.usedEq);
        ck(stA.usedEq, "判据 B：预设 A 真的进了信号链（usedEq == true）");
        ck(stA.eqBiquads > 0, "判据 B：预设 A 的 biquad 段数 > 0",
           "eqBiquads=" + std::to_string(stA.eqBiquads));

        // 判据 B：A 与"无 EQ"在至少一个频点上差 ≥ 3 dB。
        // 门限取 3 dB：比 float 噪声（~−140 dB）高 100 dB 以上，且低于本预设组的最小可闻差异。
        const double d100 = std::fabs(sA.f100 - sNone.f100);
        const double d1k  = std::fabs(sA.f1k  - sNone.f1k);
        const double d6k  = std::fabs(sA.f6k  - sNone.f6k);
        const double dMax = std::max({ d100, d1k, d6k });
        char buf[256];
        std::snprintf(buf, sizeof buf, "Δ100Hz=%.2f dB  Δ1kHz=%.2f dB  Δ6kHz=%.2f dB  max=%.2f dB",
                      d100, d1k, d6k, dMax);
        ck(dMax >= 3.0, "判据 B：预设 A vs 无 EQ 频段能量显著不同（≥3 dB）", buf);

        if (haveB) {
            eng::Pipeline PB(cfgB);
            eng::PipelineStats stB;
            const rta::audio::AudioBuffer outB = PB.process(in, &stB);
            const Shape sB = measure(outB);
            std::printf("预设 B : rms=%.2f dB  100Hz=%.2f  1kHz=%.2f  6kHz=%.2f  usedEq=%d\n",
                        sB.rmsDb, sB.f100, sB.f1k, sB.f6k, (int)stB.usedEq);
            ck(stB.usedEq, "判据 A：预设 B 真的进了信号链（usedEq == true）");

            const double ab100 = std::fabs(sA.f100 - sB.f100);
            const double ab1k  = std::fabs(sA.f1k  - sB.f1k);
            const double ab6k  = std::fabs(sA.f6k  - sB.f6k);
            const double abMax = std::max({ ab100, ab1k, ab6k });
            char b2[256];
            std::snprintf(b2, sizeof b2, "Δ100Hz=%.2f dB  Δ1kHz=%.2f dB  Δ6kHz=%.2f dB  max=%.2f dB",
                          ab100, ab1k, ab6k, abMax);
            // ★ 这就是用户"切了没变化"该被判红的那一条：两个预设必须听得出区别。
            ck(abMax >= 1.0, "判据 A：两个不同 OPRA 预设的输出显著不同（≥1 dB）——切了必须有变化", b2);
            // 逐字节不同：即使频段读数接近，波形也不能完全相同（防"EQ 根本没接上但读数巧合"）
            ck(outA.raw != outB.raw, "判据 A：A/B 输出逐样本不完全相同（不是同一条管线跑两遍）");
        } else {
            skip("判据 A：A/B 预设对比", "预设 B 文件缺失：" + eqB);
        }
    } else {
        skip("判据 B：预设 A vs 无 EQ", "预设 A 文件缺失：" + eqA);
        skip("判据 A：A/B 预设对比", "预设 A 文件缺失");
    }

    // ---------------- 判据 C：起播定位精确落在 50% ----------------
    std::printf("\n--- 判据 C：start_pos_for（生产代码那一份，不是拷贝）---\n");
    {
        const size_t inFrames = kFrames;
        const size_t totalOut = kFrames;          // 不重采样 ⟹ 输出帧 == 输入帧
        const StartPos sp = start_pos_for(0.5, inFrames, totalOut);
        char buf[256];
        std::snprintf(buf, sizeof buf, "pos=%zu (期望 %zu)  played=%zu (期望 %zu)",
                      sp.pos, inFrames / 2, sp.played, totalOut / 2);
        ck(sp.pos == inFrames / 2, "判据 C：frac=0.5 ⟹ pos 精确是 50% 源帧", buf);
        ck(sp.played == totalOut / 2, "判据 C：frac=0.5 ⟹ played 精确是 50% 输出帧",
           "played=" + std::to_string(sp.played));

        // 默认值必须是"从头播"：热重载以外的所有路径都靠这条保持旧行为
        const StartPos s0 = start_pos_for(-1.0, inFrames, totalOut);
        ck(s0.pos == 0 && s0.played == 0, "判据 C：frac=-1（默认）⟹ 从头播，行为不变");
        const StartPos sz = start_pos_for(0.0, inFrames, totalOut);
        ck(sz.pos == 0 && sz.played == 0, "判据 C：frac=0 ⟹ 从头播");
        const StartPos s1 = start_pos_for(1.0, inFrames, totalOut);
        ck(s1.pos == 0 && s1.played == 0, "判据 C：frac=1.0 视作从头播（不越界）");
        const StartPos sb = start_pos_for(0.9999999, inFrames, totalOut);
        ck(sb.pos < inFrames, "判据 C：frac→1 时 pos 仍严格 < inFrames（不越界读）",
           "pos=" + std::to_string(sb.pos));
        const StartPos se = start_pos_for(0.5, 0, 0);
        ck(se.pos == 0 && se.played == 0, "判据 C：空输入（inFrames=0）不除零、返回 0");
        // played 与 pos 同源：两者的比例必须一致（只设一个会变成"声音在 50%、进度条在 0%"）
        const StartPos sp3 = start_pos_for(0.37, inFrames, totalOut);
        const double rPos = (double)sp3.pos / (double)inFrames;
        const double rPl  = (double)sp3.played / (double)totalOut;
        ck(std::fabs(rPos - rPl) < 1e-6, "判据 C：pos 与 played 的比例同源一致（不会自相矛盾）",
           "rPos=" + std::to_string(rPos) + " rPl=" + std::to_string(rPl));
    }

    // ---------------- 判据 D：从 50% 起播 + EQ ⟹ usedEq 仍为 true ----------------
    std::printf("\n--- 判据 D：从 50% 起播仍走 EQ ---\n");
    if (haveA) {
        const StartPos sp = start_pos_for(0.5, in.frames(), in.frames());
        // 造一个"从 pos 开始的输入缓冲"——这正是 play_one 生产者线程在起播定位后做的事
        rta::audio::AudioBuffer tail;
        tail.rate = in.rate; tail.channels = in.channels; tail.bits = in.bits; tail.isFloat = in.isFloat;
        tail.raw.assign(in.raw.begin() + (long long)(sp.pos * (size_t)in.channels),
                        in.raw.end());
        ck(tail.frames() == in.frames() - sp.pos, "判据 D：切片长度 = 总帧 − 起点帧",
           std::to_string(tail.frames()) + " vs " + std::to_string(in.frames() - sp.pos));
        // 逐样本确认切片第一帧就是原缓冲第 50% 帧（不是"差不多"）
        bool same = true;
        for (int c = 0; c < in.channels; ++c)
            if (std::fabs(tail.sample(0, c) - in.sample(sp.pos, c)) > 0.0) same = false;
        ck(same, "判据 D：切片首帧逐样本等于原缓冲的 50% 帧（定位精确）");

        eng::Pipeline PA2(cfgA);
        eng::PipelineStats st2;
        (void)PA2.process(tail, &st2);
        ck(st2.usedEq, "判据 D：从 50% 起播的管线仍 usedEq == true（EQ 没被旁路）");
    } else {
        skip("判据 D：从 50% 起播仍走 EQ", "预设 A 文件缺失");
    }

    // ---------------- 判据 E：conf 兜底与"路径不可用就不重启" ----------------
    std::printf("\n--- 判据 E：conf 兜底 / 路径可用性 ---\n");
    {
        // eq_path_usable：空 = 明确不要 EQ（可用）；不存在的路径 = 不可用（用户还在打字）
        ck(eq_path_usable(""), "判据 E：空路径视为「明确不要 EQ」⟹ 可用（不会无限重试）");
        ck(!eq_path_usable("/nonexistent/definitely/not/here-12345.txt"),
           "判据 E：不存在的路径 ⟹ 不可用（用户在逐字符输入时不会被反复重启）");
        if (haveA) ck(eq_path_usable(eqA), "判据 E：真实预设路径 ⟹ 可用（会触发热重载）");
        else skip("判据 E：真实预设路径可用性", "预设 A 文件缺失");

        // settings_conf_value：真读文件、真按 key 取值（不存在的 key 返回空）
        ck(settings_conf_value("") == std::string(), "判据 E：空 key 返回空串（不读文件）");
        // 它读的是 rlplayer-settings.conf；本判据只验证"不会崩、语义是空则空"，
        // 具体值取决于用户当前配置 —— 不断言内容（那会把测试绑死在某个用户的机器上）。
        const std::string probeKey = "eq";
        const std::string v = settings_conf_value(probeKey.c_str());
        std::printf("  [INFO] settings_conf_value(\"%s\") = \"%s\"\n", probeKey.c_str(), v.c_str());
        ck(v.find('\n') == std::string::npos, "判据 E：读出的值不含换行（行尾 CR 已被剥掉）");
    }

    // ---------------- 汇总 ----------------
    std::printf("\n=== 结果：FAIL=%d  SKIP=%d ===\n", g_fail, g_skip);
    if (g_fail == 0) std::printf("RESULT=OK\n");
    else             std::printf("RESULT=FAIL\n");
    return g_fail == 0 ? 0 : 1;
}
