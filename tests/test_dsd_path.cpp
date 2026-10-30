// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_dsd_path.cpp — DSD 通路：DirectSDM（P0-3）+ 抽取器（P0-4）+ 素材闭环（P0-2）
//
// 判据（全部来自 ROADMAP，每条都可被别人的数字复现）：
//   1. DirectSDM：1-bit 流装进 DoP 再解出来，**逐位**等于源；且与既有 dop_pack(double)
//      路径的 24-bit 载波**逐样本**相同（不新造一套语义不同的 DoP）。
//   2. 抽取器通带平坦度：0…20 kHz 内 ≤ ±0.05 dB。
//   3. 抽取器混叠抑制：镜像频率（outRate − 20 kHz 附近）折叠回音频带后 > 100 dB。
//   4. THD+N：三种抽取器与 4001 抽头参考 FIR 的带内结果一致（差 < 0.3 dB），
//      且都优于 80 dB（DSD64 / 5 阶 1-bit / −6 dBFS 素材）。
//   5. 素材闭环：调制器 → DSF → 读回 → 抽取 → THD+N 有明确数值，且读回的位流逐位一致。
#include "test_compat_posix.h"   // POSIX 垫片：取代 <windows.h>（控制台/临时目录/删文件）
#include "audio/dsd_reader.h"
#include "audio/audio_loader.h"
#include "dsp/direct_sdm.h"
#include "dsp/dsd_integrator.h"
#include "dsp/dop.h"
#include "dsp/fft.h"
#include "dsp/modulator.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <array>
#include <memory>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <sys/types.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <cerrno>
#include <set>

// Port probing is read-only: a successful TCP connect proves reachability, not ownership.
struct CommandRead {
    int status = -1;
    std::string text;
};

static CommandRead read_command(const std::string& command) {
    CommandRead result;
    FILE* pipe = ::popen(command.c_str(), "r");
    if (!pipe) return result;
    std::array<char, 512> buffer{};
    while (::fgets(buffer.data(), buffer.size(), pipe)) result.text += buffer.data();
    const int status = ::pclose(pipe);
    if (status >= 0 && WIFEXITED(status)) result.status = WEXITSTATUS(status);
    return result;
}

struct ListenerRead {
    bool valid = false;
    std::set<pid_t> pids;
};

static ListenerRead read_listeners(uint16_t port) {
    const auto result = read_command("/usr/sbin/lsof -nP -a -iTCP:" +
        std::to_string(port) + " -sTCP:LISTEN -Fp 2>&1");
    ListenerRead listeners;
    if (result.status == 1 && result.text.empty()) {
        listeners.valid = true;  // lsof's documented no-match result, not an error.
        return listeners;
    }
    if (result.status != 0) return listeners;
    std::istringstream lines(result.text);
    std::string line;
    while (std::getline(lines, line)) {
        // lsof -Fp also emits file descriptor records (for example f3).
        if (line.size() > 1 && line.front() == 'f' &&
            line.find_first_not_of("0123456789", 1) == std::string::npos) continue;
        if (line.size() < 2 || line.front() != 'p' ||
            line.find_first_not_of("0123456789", 1) != std::string::npos) return {};
        try {
            const long value = std::stol(line.substr(1));
            if (value <= 0 || value > INT32_MAX) return {};
            listeners.pids.insert(static_cast<pid_t>(value));
        } catch (...) { return {}; }
    }
    listeners.valid = !listeners.pids.empty();
    return listeners;
}

struct OwnedChild {
    pid_t pid;
    uid_t uid;
    pid_t parent;
    std::string basename;
    bool reaped = false;
    bool waitError = false;
    int status = 0;

    // Never signal a PID which has already been reaped (and may have been reused).
    bool poll() {
        if (reaped || waitError) return false;
        pid_t result;
        do { result = ::waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
        if (result == pid) reaped = true;
        else if (result < 0) waitError = true;
        return !reaped && !waitError;
    }

    bool identity() {
        if (!poll()) return false;
        const auto result = read_command("/bin/ps -p " + std::to_string(pid) +
                                        " -o uid=,ppid=,comm= 2>&1");
        if (result.status != 0) return false;
        std::istringstream row(result.text);
        unsigned long actualUid = 0;
        long actualParent = 0;
        if (!(row >> actualUid >> actualParent)) return false;
        std::string comm;
        std::getline(row >> std::ws, comm);
        const auto end = comm.find_last_not_of(" \t\r\n");
        if (end == std::string::npos) return false;
        comm.erase(end + 1);
        return actualUid == uid && actualParent == parent &&
               std::filesystem::path(comm).filename().string() == basename && poll();
    }

    bool owns_listener(uint16_t port) {
        if (!identity()) return false;
        const auto listeners = read_listeners(port);
        return listeners.valid && listeners.pids == std::set<pid_t>{pid} && identity();
    }

    bool wait_for_exit(int milliseconds) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
        while (poll() && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        poll();
        return reaped;
    }

    bool stop() {
        if (!poll()) return reaped;
        // Same strict UID/PPID/basename check for cleanup as for the HTTP gate.
        if (!identity()) {
            printf("  [WARN] PID %d identity unproven; no SIGTERM; preserve isolation directory\n", (int)pid);
            return reaped;
        }
        if (::kill(pid, SIGTERM) != 0 && errno != ESRCH)
            printf("  [WARN] SIGTERM failed for owned child %d: %s\n", (int)pid, ::strerror(errno));
        return wait_for_exit(5000);  // No SIGKILL and no unbounded waitpid.
    }
};

namespace fs = std::filesystem;

#ifndef NOMINMAX
#define NOMINMAX
#endif

using namespace rta::dsp;
using rta::audio::DsdStream;

static int fails = 0;
static void check(bool ok, const std::string& what, const std::string& detail = "") {
    printf("  [%s] %s %s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++fails;
}

static std::string temp_path(const char* name) {
    char dir[MAX_PATH] = {0};
    GetTempPathA(MAX_PATH, dir);
    return std::string(dir) + name;
}

// 用我们的 5 阶调制器把正弦变成真正的 DSD 位流（这就是"测试素材"的生成方式）
static DsdStream modulate(uint32_t rate, int channels, size_t nBits,
                          double toneHz, double amp, int order, double ditherLsb = 0.0) {
    DsdStream s;
    s.rate = rate;
    s.channels = channels;
    s.bits = nBits;
    s.container = "mod";
    s.data.assign((size_t)channels, std::vector<uint8_t>((nBits + 7) / 8, 0));
    for (int c = 0; c < channels; ++c) {
        SdmConfig cfg;
        cfg.fs = (double)rate;
        cfg.order = order;
        cfg.cutoffHz = 100000.0;
        cfg.levels = 2;
        cfg.ditherLsb = ditherLsb;
        SdmModulator m(cfg);
        for (size_t n = 0; n < nBits; ++n) {
            const double x = amp * std::sin(2.0 * kPi * toneHz * (double)n / (double)rate);
            if (m.process(x) > 0.0) s.setBit((size_t)c, n, true);
        }
    }
    return s;
}

static bool same_bits(const DsdStream& a, const DsdStream& b, uint64_t bits, std::string* why) {
    if (a.channels != b.channels) { *why = "声道数不同"; return false; }
    for (int c = 0; c < a.channels; ++c)
        for (uint64_t n = 0; n < bits; ++n)
            if (a.bit((size_t)c, n) != b.bit((size_t)c, n)) {
                char buf[160];
                std::snprintf(buf, sizeof(buf), "声道 %d 第 %llu 位不同", c, (unsigned long long)n);
                *why = buf;
                return false;
            }
    return true;
}

static std::vector<double> skip_front(const std::vector<double>& v, size_t n) {
    if (v.size() <= n) return v;
    return std::vector<double>(v.begin() + (long long)n, v.end());
}

// ---------------- THD+N：时域最小二乘去基波 + Hann 窗带限功率（20 Hz…20 kHz） ----------------
//
// 判据陷阱记录：第一版用「FFT 挖掉 ±1 bin」的写法，看起来 THD+N = 98 dB，
// 实际把 2f/3f… 谐波对应的 bin 也一起挖掉了 —— 那测的是"去谐波后的 SNR"，
// 不是 THD+N。改成先在时域拟合并减掉**基波**，谐波留在残差里（正是 THD+N 的定义）；
// 同一素材的诚实时值是 94 dB 左右（失真约 −103 dB）。
struct Thdn {
    double signalDb = -999.0;
    double noiseDb  = -999.0;
    double thdnDb   = -999.0;
};

static Thdn measure_thdn(const std::vector<double>& xIn, double fs, double f0, double bandTop = 20000.0) {
    Thdn r;
    const size_t N = 65536;
    if (xIn.size() < N) return r;
    const double w0 = 2.0 * kPi * f0 / fs;
    double cc = 0.0, ss = 0.0, cs = 0.0, xc = 0.0, xs = 0.0;
    for (size_t n = 0; n < N; ++n) {
        const double c = std::cos(w0 * (double)n), s = std::sin(w0 * (double)n);
        cc += c * c; ss += s * s; cs += c * s; xc += xIn[n] * c; xs += xIn[n] * s;
    }
    const double det = cc * ss - cs * cs;
    if (std::fabs(det) < 1e-300) return r;
    const double A = (xc * ss - xs * cs) / det;
    const double B = (xs * cc - xc * cs) / det;

    std::vector<cplx> x(N);
    double sumW2 = 0.0;
    for (size_t n = 0; n < N; ++n) {
        const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * (double)n / (double)(N - 1));
        sumW2 += w * w;
        const double resid = xIn[n] - (A * std::cos(w0 * (double)n) + B * std::sin(w0 * (double)n));
        x[n] = cplx(resid * w, 0.0);
    }
    fft(x);
    const double binHz = fs / (double)N;
    const double norm = (double)N * sumW2;
    const size_t kLo = (size_t)std::ceil(20.0 / binHz);
    const size_t kTop = (size_t)std::floor(bandTop / binHz);
    double pnoise = 0.0;
    for (size_t k = kLo; k <= kTop && k < N / 2; ++k) pnoise += std::norm(x[k]) / norm;
    const double psig = (A * A + B * B) / 2.0;
    r.signalDb = 10.0 * std::log10(psig + 1e-300);
    r.noiseDb  = 10.0 * std::log10(2.0 * pnoise + 1e-300);
    r.thdnDb   = 10.0 * std::log10(psig / (2.0 * pnoise + 1e-300));
    return r;
}

// 1-bit 方波探针：**按整数样本相位**生成（period = rate/freq），保证 50% 占空比与
// 严格的 18 样本周期。早期版本用 sin(...) >= 0 判定：sin(2πk) 在 double 里是 ±1e-16，
// 符号随 k 乱跳，导致个别样本翻转 → 探针自己带上宽带杂散，实测把 19.6 kHz 抬到 −90 dBFS，
// 被误读成"滤波器泄漏只有 90 dB"。这类坑正是「测试要测对东西」的典型。
static DsdStream square_probe(uint32_t rate, int channels, size_t nBits, double freqHz) {
    const long period = (long)std::llround((double)rate / freqHz);
    DsdStream s;
    s.rate = rate;
    s.channels = channels;
    s.bits = nBits;
    s.container = "probe";
    s.data.assign((size_t)channels, std::vector<uint8_t>((nBits + 7) / 8, 0));
    for (int c = 0; c < channels; ++c)
        for (size_t n = 0; n < nBits; ++n)
            if ((long)(n % (size_t)period) * 2 < period)
                s.setBit((size_t)c, n, true);
    return s;
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    SetConsoleOutputCP(CP_UTF8);

    printf("=== 1. DirectSDM：1-bit → DoP → 1-bit 逐位一致 ===\n");
    {
        const uint64_t bits = 16ull * 4096ull;               // 4096 个 DoP 帧
        DsdStream a = modulate(2822400u, 2, bits, 1000.0, 0.5, 5);
        std::vector<int32_t> packed;
        DopPackState st;
        const size_t groups = dsd_to_dop(a, packed, st);
        check(groups == bits / 16 && packed.size() == groups * 2, "载波帧数 = 位数/16 × 声道数",
              std::to_string(groups) + " 帧/声道");

        // 标记必须逐样本交替 05 / FA（每声道独立）
        bool marks = true;
        for (int c = 0; c < 2; ++c)
            for (size_t n = 0; n < groups; ++n) {
                const uint32_t m = ((uint32_t)packed[n * 2 + (size_t)c] >> 16) & 0xFF;
                const uint32_t want = (n & 1) ? DOP_MARKER_B : DOP_MARKER_A;
                if (m != want) marks = false;
            }
        check(marks, "DoP 标记逐样本交替 05/FA（每声道独立）");

        DsdStream back;
        check(dop_to_dsd_bits(packed.data(), groups, 2, back), "DoP 解包标记校验通过");
        std::string why;
        check(same_bits(a, back, bits, &why), "解包后的 1-bit 流与源逐位一致", why);

        // 与既有 dop_pack(double) 路径交叉验证：载波必须逐样本相同
        std::vector<std::vector<double>> planes(2, std::vector<double>((size_t)bits));
        for (int c = 0; c < 2; ++c)
            for (uint64_t n = 0; n < bits; ++n) planes[(size_t)c][(size_t)n] = a.bit((size_t)c, n) ? 1.0 : -1.0;
        std::vector<const double*> ptrs = { planes[0].data(), planes[1].data() };
        std::vector<int32_t> ref;
        dop_pack(ptrs.data(), 2, (size_t)bits, ref);
        check(ref == packed, "与既有 dop_pack(double) 的 24-bit 载波逐样本相同",
              "样本数 " + std::to_string(ref.size()));

        // 分块打包：相位必须跨块保持（否则接收端在块边界看到 A,A）
        DopPackState st2;
        std::vector<int32_t> chunked;
        const size_t chunkGroups = 300;
        for (size_t g = 0; g < groups; g += chunkGroups) {
            const size_t take = std::min(chunkGroups, groups - g);
            DsdStream sub;
            sub.rate = a.rate; sub.channels = 2; sub.bits = (uint64_t)take * 16;
            sub.data.assign(2, std::vector<uint8_t>(take * 2));
            for (int c = 0; c < 2; ++c)
                std::memcpy(sub.data[(size_t)c].data(),
                            a.data[(size_t)c].data() + g * 2, take * 2);
            std::vector<int32_t> one;
            dsd_to_dop(sub, one, st2);
            chunked.insert(chunked.end(), one.begin(), one.end());
        }
        check(chunked == packed, "分 14 块打包与一次性打包逐样本相同（标记相位跨块保持）");

        // 3 声道
        DsdStream a3 = modulate(2822400u, 3, 16ull * 1024ull, 997.0, 0.4, 5);
        std::vector<int32_t> p3; DopPackState s3;
        dsd_to_dop(a3, p3, s3);
        DsdStream b3;
        check(dop_to_dsd_bits(p3.data(), p3.size() / 3, 3, b3), "3 声道 DoP 解包");
        check(same_bits(a3, b3, a3.bits, &why), "3 声道逐位一致", why);

        // 不足 16 位的尾巴：返回的帧数应向下取整
        DsdStream t = a;
        t.bits = 16ull * 100ull + 7ull;
        std::vector<int32_t> pt; DopPackState stt;
        check(dsd_to_dop(t, pt, stt) == 100, "不足 16 位的尾巴被丢弃（帧数向下取整）");

        // 直通判定
        check(direct_sdm_decision(2822400, 2822400, false, false).enabled, "同速率、无处理、0 dB → 可直通");
        check(!direct_sdm_decision(2822400, 5644800, false, false).enabled, "速率不同 → 不可直通");
        check(!direct_sdm_decision(2822400, 2822400, true, false).enabled, "有 PCM 处理 → 不可直通");
        check(!direct_sdm_decision(2822400, 2822400, false, true).enabled, "音量非 0 dB → 不可直通");
        printf("  [注] 不可直通时给出的原因：%s\n",
               direct_sdm_decision(2822400, 5644800, false, false).reason.c_str());
    }

    printf("\n=== 2. 抽取器设计指标（解析响应：平坦度 / 阻带）===\n");
    const uint32_t fs = 2822400, outRate = 176400;
    const double P = 20000.0;
    struct KindCase { IntegratorKind kind; const char* label; };
    const KindCase kinds[] = {
        { IntegratorKind::Fir, "FIR" },
        { IntegratorKind::Iir, "IIR" },
        { IntegratorKind::Cic, "CIC" },
    };
    double attenuation[3] = { 0, 0, 0 };
    {
        printf("  %-4s %-10s %8s %12s %12s %12s\n", "类型", "参数", "抽取比", "带内最差(dB)", "阻带@156.4k", "80k 处");
        for (int i = 0; i < 3; ++i) {
            IntegratorConfig cfg;
            cfg.kind = kinds[i].kind;
            cfg.dsdRate = fs; cfg.outRate = outRate; cfg.passbandHz = P;
            cfg.attenDb = 120.0; cfg.order = 10; cfg.cicStages = 6;
            DsdDecimator dec(cfg);
            double worst = 0.0;
            for (int k = 0; k <= 400; ++k) {
                const double f = P * (double)k / 400.0;
                worst = std::max(worst, std::fabs(dec.response_db(f)));
            }
            char param[64];
            if (kinds[i].kind == IntegratorKind::Fir)
                std::snprintf(param, sizeof(param), "%zu taps", dec.firTaps().size());
            else if (kinds[i].kind == IntegratorKind::Iir)
                std::snprintf(param, sizeof(param), "order %d", cfg.order);
            else
                std::snprintf(param, sizeof(param), "%d 级 + 17 taps", cfg.cicStages);
            const double att = -dec.response_db((double)outRate - P);
            const double att80 = -dec.response_db(80000.0);
            attenuation[i] = att;
            printf("  %-4s %-10s %8u %12.4f %12.1f %12.1f\n",
                   kinds[i].label, param, dec.decimation(), worst, att, att80);
            check(worst <= 0.05, std::string(kinds[i].label) + " 通带平坦度 ≤ 0.05 dB",
                  std::to_string(worst) + " dB");
            check(att >= 100.0, std::string(kinds[i].label) + " 镜像处衰减 ≥ 100 dB",
                  std::to_string(att) + " dB");
        }
    }

    printf("\n=== 3. 混叠实测：fs/18 (156.8 kHz) 方波探针 → 折叠到 19.6 kHz ===\n");
    {
        // 为什么探针取 fs/18 而不是任意高音：
        //   1) 每周期正好 18 个样本 → 真正的 50% 占空比，频谱只有奇次谐波（DC = 0）；
        //   2) 第 p 次谐波折叠后在离散域落在 156.8 kHz×(p mod 18)，全部 ≥ 156.8 kHz，
        //      即全部落在抽取器阻带里 —— 不会像"随便取个高音"那样把谐波折进音频带，
        //      让人误把探针自身的带内杂散当成滤波器泄漏（本轮踩过这个坑）。
        //   3) 156.8 kHz 只比阻带起点 156.4 kHz 高 400 Hz，是**最苛刻**的测试点；
        //      折叠到 19.6 kHz，紧贴 20 kHz 通带边缘。
        const size_t nIn = 1'048'320;               // = 16×65,520 = 18×58,240，整周期且能整除 16
        const double fProbe = (double)fs / 18.0;    // 156,800 Hz
        const double fAlias = (double)outRate - fProbe;   // 19,600 Hz
        printf("  探针 %.1f Hz（每周期 18 样本，50%% 占空比）→ 折叠到 %.1f Hz\n", fProbe, fAlias);
        DsdStream probe = square_probe(fs, 1, nIn, fProbe);
        for (int i = 0; i < 3; ++i) {
            IntegratorConfig cfg;
            cfg.kind = kinds[i].kind;
            cfg.dsdRate = fs; cfg.outRate = outRate; cfg.passbandHz = P;
            cfg.attenDb = 120.0; cfg.order = 10; cfg.cicStages = 6;
            DsdDecimator dec(cfg);
            std::vector<double> out;
            dec.process_bits(probe.data[0].data(), nIn, out);
            // 丢掉滤波器启动瞬态；测量长度取 19.6 kHz 的整周期（9 个输出样本一轮），
            // 否则第 9 次谐波折叠成的直流会经相关泄漏进结果（实测把 19.6 kHz 抬到 −90 dBFS）。
            const size_t skip = 1024;
            const size_t len = ((out.size() - skip) / 9) * 9;
            const std::vector<double> tail(out.begin() + (long long)skip, out.begin() + (long long)(skip + len));
            const double aliasDb = tone_magnitude_db(tail, fAlias, (double)outRate);
            const double supp = 20.0 * std::log10(4.0 / kPi) - aliasDb;
            printf("  %-4s 折叠残留 %9.2f dBFS → 抑制 %6.1f dB（解析值 %.1f dB，%zu 输出样本）\n",
                   kinds[i].label, aliasDb, supp, attenuation[i], tail.size());
            check(supp >= 100.0, std::string(kinds[i].label) + " 实测混叠抑制 ≥ 100 dB",
                  std::to_string(supp) + " dB");
        }
    }

    printf("\n=== 4. THD+N：DSD64 / 5 阶 1-bit / -6 dBFS / 998.5 Hz（FFT 整 bin）===\n");
    {
        const double f0 = 371.0 * (double)outRate / 65536.0;    // 998.5 Hz，落在整数 bin
        const size_t nBits = (size_t)(0.8 * (double)fs);        // 0.8 s
        DsdStream src = modulate(fs, 2, nBits, f0, 0.5, 5);
        printf("  素材：%zu 位/声道（%.3f s），测试音 %.3f Hz\n",
               nBits, (double)nBits / (double)fs, f0);

        double thdn[3] = { 0, 0, 0 };
        double refThdn = 0.0;
        for (int i = 0; i < 3; ++i) {
            IntegratorConfig cfg;
            cfg.kind = kinds[i].kind;
            cfg.dsdRate = fs; cfg.outRate = outRate; cfg.passbandHz = P;
            cfg.attenDb = 120.0; cfg.order = 10; cfg.cicStages = 6;
            DsdDecimator dec(cfg);
            auto planes = dec.process(src);
            const auto tail = skip_front(planes[0], 4096);   // 丢掉滤波器启动瞬态
            Thdn r = measure_thdn(tail, (double)outRate, f0, P);
            thdn[i] = r.thdnDb;
            printf("  %-4s 信号 %7.2f dB  带内噪声 %7.2f dB  THD+N %6.2f dB\n",
                   kinds[i].label, r.signalDb, r.noiseDb, r.thdnDb);
            check(r.thdnDb > 80.0, std::string(kinds[i].label) + " THD+N > 80 dB",
                  std::to_string(r.thdnDb) + " dB");
        }
        {
            IntegratorConfig cfg;
            cfg.kind = IntegratorKind::Fir;
            cfg.dsdRate = fs; cfg.outRate = outRate; cfg.passbandHz = P;
            cfg.attenDb = 180.0; cfg.taps = 4001;                // 参考：远长于默认 FIR
            DsdDecimator ref(cfg);
            auto planes = ref.process(src);
            const auto tail = skip_front(planes[0], 4096);
            Thdn r = measure_thdn(tail, (double)outRate, f0, P);
            refThdn = r.thdnDb;
            printf("  REF  4001 taps     THD+N %6.2f dB（%zu 抽头）\n", r.thdnDb, ref.firTaps().size());
        }
        for (int i = 0; i < 3; ++i) {
            const double d = std::fabs(thdn[i] - refThdn);
            check(d < 0.3, std::string(kinds[i].label) + " 与参考 FIR 的带内结果相差 < 0.3 dB",
                  std::to_string(d) + " dB");
        }
    }

    printf("\n=== 5. 素材闭环：调制器 → DSF 文件 → 读回 → 抽取（P0-2）===\n");
    {
        const double f0 = 371.0 * (double)outRate / 65536.0;
        const size_t nBits = (size_t)(0.5 * (double)fs);
        DsdStream src = modulate(fs, 2, nBits, f0, 0.5, 5);
        const std::string path = temp_path("rta_dsd_path_loop.dsf");
        rta::audio::write_dsf(path, src, 4096);

        DsdStream back = rta::audio::read_dsf(path);
        std::string why;
        check(back.rate == fs && back.channels == 2 && back.bits == nBits,
              "生成的 DSF 读回元数据正确",
              std::to_string(back.rate) + " Hz / " + std::to_string(back.channels) + " ch / " +
              std::to_string(back.bits) + " 位");
        check(same_bits(src, back, nBits, &why), "生成的文件逐位还原调制器输出", why);

        IntegratorConfig cfg;
        cfg.kind = IntegratorKind::Fir;
        cfg.dsdRate = fs; cfg.outRate = outRate; cfg.passbandHz = P;
        DsdDecimator dec(cfg);
        auto planes = dec.process(back);
        Thdn r = measure_thdn(skip_front(planes[0], 4096), (double)outRate, f0, P);
        printf("  解调 PCM 帧数 %zu，THD+N = %.2f dB（信号 %.2f dB / 带内噪声 %.2f dB）\n",
               planes[0].size(), r.thdnDb, r.signalDb, r.noiseDb);
        check(r.thdnDb > 80.0, "解调出的 PCM 与原正弦 THD+N > 80 dB", std::to_string(r.thdnDb) + " dB");

        // DirectSDM 走文件：源 == 目标 DSD64，逐位确认
        std::vector<int32_t> packed;
        DopPackState st;
        dsd_to_dop(back, packed, st);
        DsdStream rt;
        const bool ok = dop_to_dsd_bits(packed.data(), packed.size() / 2, 2, rt);
        check(ok && same_bits(back, rt, back.bits - back.bits % 16, &why),
              "同一文件 DirectSDM 直通后逐位一致（含 16 位对齐尾部）", why);

        // ---- 播放器入口：read_any 必须走原生 DSD，而不是 ffmpeg ----
        rta::audio::LoadNote note;
        rta::audio::AudioBuffer pcm = rta::audio::read_any(path, &note);
        check(pcm.rate == outRate && pcm.channels == 2 && pcm.bits == 32,
              "read_any 输出 176400 Hz / 2ch / 32bit",
              std::to_string(pcm.rate) + " Hz / " + std::to_string(pcm.channels) + " ch / " +
              std::to_string(pcm.bits) + " bit");
        check(note.text.find("DSD 原生解码") != std::string::npos,
              "read_any 说明走的是原生 DSD 抽取（不是 ffmpeg）", note.text);
        check(pcm.frames() == (size_t)(nBits / 16), "PCM 帧数 = DSD 位数/16",
              std::to_string(pcm.frames()));
        DeleteFileA(path.c_str());
    }


    printf("\n=== 6. Conversion 预设：narrow / wide / XFi 的频响数值表（P0-5）===\n");
    {
        const DsdConversion convs[] = { DsdConversion::Narrow, DsdConversion::Wide, DsdConversion::Xfi };
        printf("  %-7s %9s %10s %11s %7s %11s %10s\n",
               "预设", "通带kHz", "阻带kHz", "过渡带kHz", "抽头", "带内最差dB", "镜像衰减dB");
        size_t prevTaps = 0;
        bool tapsGrow = true, transShrink = true;
        double prevTrans = 1e30;
        for (auto c : convs) {
            const IntegratorConfig cfg = conversion_integrator(IntegratorKind::Fir, c, fs, outRate);
            DsdDecimator dec(cfg);
            const double pass = cfg.passbandHz;
            const double stop = dec.stopbandStartHz();
            const double trans = stop - pass;
            double worst = 0.0;
            for (int k = 0; k <= 400; ++k)
                worst = std::max(worst, std::fabs(dec.response_db(pass * (double)k / 400.0)));
            const double att = -dec.response_db(stop);
            printf("  %-9s %9.1f %10.1f %11.1f %7zu %11.4f %10.1f\n",
                   conversion_name(c), pass / 1000.0, stop / 1000.0, trans / 1000.0,
                   dec.firTaps().size(), worst, att);
            check(std::fabs(pass - conversion_passband(c)) < 1e-9,
                  std::string("预设 ") + conversion_name(c) + " 的通带确实是设定值",
                  std::to_string(pass) + " Hz");
            check(worst <= 0.05, std::string(conversion_name(c)) + " 通带平坦度 ≤ 0.05 dB",
                  std::to_string(worst) + " dB");
            check(att >= 100.0, std::string(conversion_name(c)) + " 镜像处衰减 ≥ 100 dB",
                  std::to_string(att) + " dB");
            if (prevTaps && dec.firTaps().size() <= prevTaps) tapsGrow = false;
            if (trans >= prevTrans) transShrink = false;
            prevTaps = dec.firTaps().size();
            prevTrans = trans;
        }
        // 「真参数」判据：三组预设在物理量上必须不同，不能只是换标签
        check(tapsGrow, "通带越宽、抽头越多（narrow < wide < xfi）",
              "抽头 " + std::to_string(prevTaps));
        check(transShrink, "通带越宽、过渡带越窄", "依次 " +
              std::to_string((int)(outRate - 2 * conversion_passband(DsdConversion::Narrow))) + " Hz 起");
        // IIR / CIC 也接受同一套通带定义
        for (auto k : { IntegratorKind::Iir, IntegratorKind::Cic }) {
            const IntegratorConfig cfg = conversion_integrator(k, DsdConversion::Xfi, fs, outRate);
            check(std::fabs(cfg.passbandHz - 40000.0) < 1e-9,
                  std::string(integrator_name(k)) + " 也支持 XFi 通带",
                  std::to_string(cfg.passbandHz) + " Hz");
        }
    }

    printf("\n=== 7. 原生 DSD 采样率判定（A-5）与 rtaweb 退出收尾取证 ===\n");
    {
        fs::path exeDir = fs::current_path();
        fs::path rtawebBin = exeDir / "rtaweb";
        if (!fs::exists(rtawebBin)) rtawebBin = exeDir / "build-mac" / "rtaweb";
        if (!fs::exists(rtawebBin)) rtawebBin = exeDir / "RLPlayer" / "build-mac" / "rtaweb";
        if (!fs::exists(rtawebBin)) {
            fs::path srcDir = fs::path(__FILE__).parent_path().parent_path();
            rtawebBin = srcDir / "build-mac" / "rtaweb";
        }

        if (!fs::exists(rtawebBin)) {
            check(false, "找不到 rtaweb 可执行文件: " + rtawebBin.string());
        } else {
            // 固定测试服务端口使用 19106 允许范围并串行复用
            const uint16_t testPort = 19106;
            const auto before = read_listeners(testPort);
            if (!before.valid || !before.pids.empty()) {
                check(false, "DSD ownership preflight: port 19106 busy or ownership unreadable; no spawn, no HTTP");
                return 1;
            }
            rtawebBin = fs::absolute(rtawebBin);

            // 独立 mkdtemp 根目录，全隔离 HOME / CFFIXED_USER_HOME / STATE / LIBRARY / COVER
            char tempTemplate[] = "/tmp/rta_dsd_path_iso_XXXXXX";
            char* tempDir = ::mkdtemp(tempTemplate);
            if (!tempDir) {
                check(false, "mkdtemp 创建隔离目录失败");
            } else {
                fs::path isoRoot(tempDir);
                fs::path isoHome = isoRoot / "home";
                fs::path isoState = isoRoot / "state";
                fs::path isoLib = isoRoot / "lib";
                fs::path isoCover = isoRoot / "cover";
                fs::path isoLogs = isoRoot / "logs";

                std::error_code isoEc;
                fs::create_directories(isoHome / "Library" / "Application Support" / "RLPlayer", isoEc);
                fs::create_directories(isoState, isoEc);
                fs::create_directories(isoLib, isoEc);
                fs::create_directories(isoCover, isoEc);
                fs::create_directories(isoLogs, isoEc);

                // 预写入隔离的 rlplayer-settings.conf：backend=null / metaon=0 / metallm=0 / volume=-120
                const std::string confContent =
                    "backend=null\n"
                    "metaon=0\n"
                    "metallm=0\n"
                    "volume=-120\n";
                {
                    std::ofstream cf(isoState / "rlplayer-settings.conf");
                    cf << confContent;
                }
                {
                    std::ofstream cf(isoHome / "Library" / "Application Support" / "RLPlayer" / "rlplayer-settings.conf");
                    cf << confContent;
                }

                const std::string isoHomeS = isoHome.string();
                const std::string isoStateS = isoState.string();
                const std::string isoLibS = isoLib.string();
                const std::string isoCoverS = isoCover.string();
                const std::string outLogFile = (isoLogs / "rtaweb_stdout_stderr.log").string();

                pid_t pid = fork();
                if (pid == 0) {
                    ::setsid();
                    ::chdir(isoRoot.c_str());
                    ::setenv("HOME", isoHomeS.c_str(), 1);
                    ::setenv("CFFIXED_USER_HOME", isoHomeS.c_str(), 1);
                    ::setenv("RLPLAYER_STATE_DIR", isoStateS.c_str(), 1);
                    ::setenv("RLPLAYER_LIBRARY_DIR", isoLibS.c_str(), 1);
                    ::setenv("RLPLAYER_COVER_DIR", isoCoverS.c_str(), 1);

                    int fd = ::open(outLogFile.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
                    if (fd >= 0) {
                        ::dup2(fd, STDOUT_FILENO);
                        ::dup2(fd, STDERR_FILENO);
                        if (fd > 2) ::close(fd);
                    }

                    std::string pStr = std::to_string(testPort);
                    execl(rtawebBin.c_str(), rtawebBin.c_str(),
                          "--port", pStr.c_str(),
                          "--music-dir", "./data",
                          "--no-browser", nullptr);
                    _exit(127);
                } else if (pid < 0) {
                    check(false, "fork() 启动 rtaweb 失败");
                    fs::remove_all(isoRoot, isoEc);
                } else {
                    OwnedChild child{pid, ::getuid(), ::getpid(), rtawebBin.filename().string()};
                    bool ready = false;
                    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(6);
                    while (child.poll() && std::chrono::steady_clock::now() < deadline) {
                        // The child may still be between fork and exec. Never HTTP-probe readiness.
                        const auto listeners = read_listeners(testPort);
                        if (!listeners.valid || (!listeners.pids.empty() &&
                            listeners.pids != std::set<pid_t>{pid})) break;
                        if (child.owns_listener(testPort)) { ready = true; break; }
                        std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    }
                    check(ready, "rtaweb readiness requires exact spawned UID/PPID/basename and sole listener PID",
                          "pid=" + std::to_string(pid));
                    if (!ready) {
                        check(child.stop(), "failed-start child safely reaped without HTTP or force kill");
                        if (child.reaped) fs::remove_all(isoRoot, isoEc);
                        else printf("  [WARN] isolation directory preserved: %s\n", isoRoot.c_str());
                        return 1;
                    }

                    // ---- 判据 B：POST /api/quit 退出收尾取证 ----
                    {
                        // Revalidate immediately before every HTTP operation, not only once at startup.
                        const bool owned = child.owns_listener(testPort);
                        check(owned, "POST /api/quit ownership gate: exact child identity and listener");
                        CommandRead response;
                        if (owned) response = read_command(
                            "/usr/bin/curl --noproxy '*' --connect-timeout 1 --max-time 3 -s -X POST http://127.0.0.1:" +
                            std::to_string(testPort) + "/api/quit");
                        check(owned && response.status == 0 && response.text.find("\"ok\":true") != std::string::npos,
                              "POST /api/quit 返回 ok:true", response.text);

                        bool exited = child.wait_for_exit(5000);
                        if (!exited) exited = child.stop();
                        const bool normal = exited && WIFEXITED(child.status);
                        check(normal && WEXITSTATUS(child.status) == 0,
                              "rtaweb 正常退出且退出码为 0（非 SIGABRT）",
                              normal ? "exit=" + std::to_string(WEXITSTATUS(child.status)) :
                                       "no normal reaped exit (raw status=" + std::to_string(child.status) + ")");

                        // 读取隔离 state 的日志，断言必须读此次隔离 state 的日志与本次 pid / 本次 SHUTDOWN 关联
                        bool foundShutdownLog = false;
                        bool foundStartupPid = false;
                        std::string expectedPidStr = "pid=" + std::to_string(pid);
                        std::string stateLogPath = (isoState / "rlplayer-playback.log").string();
                        std::ifstream lf(stateLogPath);
                        if (!lf) {
                            // 若降级至 home 支持目录，读取隔离 home
                            stateLogPath = (isoHome / "Library" / "Application Support" / "RLPlayer" / "rlplayer-playback.log").string();
                            lf.open(stateLogPath);
                        }
                        if (lf) {
                            std::string line;
                            while (std::getline(lf, line)) {
                                if (line.find("STARTUP") != std::string::npos && line.find(expectedPidStr) != std::string::npos) {
                                    foundStartupPid = true;
                                }
                                if (line.find("SHUTDOWN joinable") != std::string::npos) {
                                    foundShutdownLog = true;
                                }
                            }
                        }
                        check(foundStartupPid && foundShutdownLog,
                              "隔离日志中包含本次 PID 启动记录且包含本次 SHUTDOWN joinable 取证行",
                              "pid=" + std::to_string(pid) + " log=" + stateLogPath);
                    }

                    // A live or unaccounted child may still use this directory: preserve it.
                    if (child.reaped) fs::remove_all(isoRoot, isoEc);
                    else {
                        check(false, "child not reaped; isolation directory must be preserved", isoRoot.string());
                    }
                }
            }
        }
    }

    printf("\n%s (失败项 %d)\n", fails == 0 ? "全部通过" : "存在失败", fails);
    return fails == 0 ? 0 : 1;
}
