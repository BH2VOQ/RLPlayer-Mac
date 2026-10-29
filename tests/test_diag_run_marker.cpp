// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_diag_run_marker.cpp — 1.1.1 D6：运行标记、clean/unclean 判定、
//                            「不把 unclean 直接说成 crash」
//
// ===========================================================================
// 这条判据怎么证明事（铁律 3）
//
//   本任务最容易骗过自己的写法是：把「标记还在」直接翻译成「上次崩溃了」。
//   所以下面每条都断言**两件事**：
//     ① 机器可读字段（found / clean / kind / reason_class）；
//     ② 面向用户的说明里**不含**「崩溃」「crash」——除非真的传了证据。
//   没有证据的 unclean 一律落在 unclean_unknown，说明里必须出现 "unclean"
//   与「证据不足」。谁把文案改成 "上次崩溃"，B/C 段立刻红。
//
//   A 段：无标记 = 首次运行（None），不是 unclean。
//   B 段：正常退出 → 下一次看到 clean。
//   C 段：标记留在 running（进程被强行结束/掉电/被系统回收）→ unclean，
//         且**不升级为 crash**；pid_alive 只是事实，不是崩溃证据。
//   D 段：仅在有证据时细分 —— 崩溃转储 → crash；监管进程记录到信号 → killed。
//         同一份标记文本，证据不同 → 结论不同（证明判据真的依赖证据）。
//   E 段：标记损坏 → 按 unclean_unknown 处理并标注 marker_corrupt，不崩、不猜。
//   F 段：写入原子（无 .tmp 残留）、可被独立进程读回合法 JSON。
//   G 段：心跳节流真的生效（计数可证），长跑不写爆磁盘。
//   H 段：与事件日志联动 —— session.start/session.end 落盘，上一轮结论进事件。
//
// 全部故障注入只作用于本进程创建的隔离临时目录里的标记文件；不杀任何进程，
// 只用 ::kill(pid, 0) 之外的手段（本测试连 kill 都不用，pid 存活靠参数注入）。
// ===========================================================================
#include "diag/diag.h"
#include "diag/event_log.h"
#include "diag/run_marker.h"

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <sys/wait.h>
#include <unistd.h>

static int g_fail = 0;
static int g_pass = 0;

static void ck(bool cond, const char* what, const std::string& detail = std::string()) {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

static void ck_eq(const std::string& got, const std::string& want, const char* what) {
    if (got == want) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s\n         期望: %s\n         实际: %s\n", what, want.c_str(),
                    got.c_str());
        ++g_fail;
    }
}

static std::vector<std::string> g_dirs;   // 测试结束统一清理，避免污染 /tmp

static std::string fresh_dir(const std::string& tag) {
    std::error_code ec;
    auto p = std::filesystem::temp_directory_path(ec);
    if (ec) p = "/tmp";
    const auto dir = p / ("rlplayer-runmarker-test-" + tag + "-" + std::to_string((long)::getpid()));
    std::filesystem::remove_all(dir, ec);
    std::filesystem::create_directories(dir, ec);
    g_dirs.push_back(dir.string());
    return dir.string();
}

static std::string read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return std::string();
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

static bool has(const std::string& h, const std::string& n) {
    return h.find(n) != std::string::npos;
}

int main() {
    std::printf("== test_diag_run_marker: 运行标记与 clean/unclean ==\n");

    // ---------------------------------------------------------------- A
    std::printf("\n-- A. 无标记 = 首次运行（None），不是 unclean --\n");
    {
        const std::string dir = fresh_dir("fresh");
        rta::diag::RunMarker m({dir, "run.json", true});
        std::string err;
        const auto prev = m.begin("sid-a", "1.1.1-test", &err);
        ck(err.empty(), "A1 begin 无错误", err);
        ck(!prev.found, "A2 首次运行 found=false");
        ck_eq(prev.reason_class(), "none", "A3 reason_class=none");
        ck(!has(prev.zh_summary(), "崩溃") && !has(prev.zh_summary(), "crash"),
           "A4 首次运行的说明里没有崩溃话术", prev.zh_summary());

        const std::string raw = read_file(dir + "/run.json");
        ck(has(raw, "\"state\":\"running\""), "A5 标记写入 state=running", raw);
        ck(has(raw, "\"sid\":\"sid-a\""), "A6 标记含本会话 sid", raw);
        ck(has(raw, "\"pid\":"), "A7 标记含 pid（供异常退出后核对）", raw);
        m.end_clean("quit");
        const std::string raw2 = read_file(dir + "/run.json");
        ck(has(raw2, "\"state\":\"clean\""), "A8 正常退出写 state=clean", raw2);
        ck(has(raw2, "\"exit_reason\":\"quit\""), "A9 记下退出原因", raw2);
    }

    // ---------------------------------------------------------------- B
    std::printf("\n-- B. 正常退出 → 下一次看到 clean --\n");
    {
        const std::string dir = fresh_dir("clean");
        {
            rta::diag::RunMarker m({dir, "run.json", true});
            m.begin("sid-b1", "1.1.1-test");
            m.end_clean("user_quit");
        }
        rta::diag::RunMarker m2({dir, "run.json", true});
        const auto prev = m2.begin("sid-b2", "1.1.1-test");
        ck(prev.found, "B1 找到上一份标记");
        ck(prev.clean, "B2 clean=true");
        ck_eq(prev.reason_class(), "clean", "B3 reason_class=clean");
        ck_eq(prev.sid, "sid-b1", "B4 记得上一会话 sid");
        ck_eq(prev.exit_reason, "user_quit", "B5 记得上一会话退出原因");
        ck(!has(prev.zh_summary(), "崩溃"), "B6 clean 的说明没有崩溃话术", prev.zh_summary());
        m2.end_clean("quit");
    }

    // ---------------------------------------------------------------- C
    std::printf("\n-- C. 标记停在 running（无任何证据）→ unclean，不说 crash --\n");
    {
        const std::string dir = fresh_dir("unclean");
        {
            rta::diag::RunMarker m({dir, "run.json", true});
            m.begin("sid-c1", "1.1.1-test");
            // 故意不调用 end_clean：等效于进程被系统回收/掉电/被强行结束
        }
        rta::diag::RunMarker m2({dir, "run.json", true});
        const auto prev = m2.begin("sid-c2", "1.1.1-test");
        ck(prev.found, "C1 找到上一份标记");
        ck(!prev.clean, "C2 clean=false");
        ck(prev.kind == rta::diag::UncleanKind::Unknown, "C3 kind=Unknown（无证据不细分）");
        ck_eq(prev.reason_class(), "unclean_unknown", "C4 reason_class=unclean_unknown");
        ck(has(prev.zh_summary(), "unclean"), "C5 说明里明确写 unclean", prev.zh_summary());
        ck(has(prev.zh_summary(), "证据不足"), "C6 说明里明确写证据不足", prev.zh_summary());
        ck(!has(prev.zh_summary(), "崩溃") && !has(prev.zh_summary(), "crash"),
           "C7 ★ 没有证据时绝不说崩溃", prev.zh_summary());
        ck(!prev.zh_summary().empty(), "C8 说明非空");

        // pid_alive 只是事实，不是崩溃证据
        const std::string raw = read_file(dir + "/run.json");
        const auto alive = rta::diag::classify_marker(raw, rta::diag::CrashEvidence{}, true);
        ck(alive.kind == rta::diag::UncleanKind::Unknown, "C9 pid 存活不升级为 crash");
        ck(alive.pid_alive, "C10 pid_alive 如实记录");
        ck(!has(alive.zh_summary(), "崩溃"), "C11 pid 存活时也不说崩溃", alive.zh_summary());
        m2.end_clean("quit");
    }

    // ---------------------------------------------------------------- D
    std::printf("\n-- D. 只有拿到证据才细分 crash / killed --\n");
    {
        const std::string dir = fresh_dir("evidence");
        {
            rta::diag::RunMarker m({dir, "run.json", true});
            m.begin("sid-d1", "1.1.1-test");
        }
        const std::string raw = read_file(dir + "/run.json");
        ck(has(raw, "\"state\":\"running\""), "D1 前置：标记停在 running", raw);

        rta::diag::CrashEvidence dump;
        dump.crash_dump = true;
        dump.crash_dump_path = "/Users/august/Library/Logs/DiagnosticReports/RLPlayer-1.ips";
        const auto crashed = rta::diag::classify_marker(raw, dump, false);
        ck(crashed.kind == rta::diag::UncleanKind::Crashed, "D2 有崩溃转储 → Crashed");
        ck_eq(crashed.reason_class(), "unclean_crashed", "D3 reason_class=unclean_crashed");
        ck(has(crashed.zh_summary(), "崩溃转储"), "D4 说明里给出证据来源",
           crashed.zh_summary());
        ck(!has(crashed.zh_summary(), "august"), "D5 证据路径也过脱敏（无用户名）",
           crashed.zh_summary());

        rta::diag::CrashEvidence sig;
        sig.supervisor_signal = true;
        sig.signal_number = 15;
        sig.signal_name = "SIGTERM";
        const auto killed = rta::diag::classify_marker(raw, sig, false);
        ck(killed.kind == rta::diag::UncleanKind::Killed, "D6 监管记录到信号 → Killed");
        ck_eq(killed.reason_class(), "unclean_killed", "D7 reason_class=unclean_killed");
        ck(has(killed.zh_summary(), "SIGTERM"), "D8 说明里写明信号", killed.zh_summary());

        // 同一份标记，无证据 → 仍然只能 unknown（证明结论依赖证据而不是标记本身）
        const auto none = rta::diag::classify_marker(raw, rta::diag::CrashEvidence{}, false);
        ck(none.kind == rta::diag::UncleanKind::Unknown, "D9 同一标记无证据仍是 Unknown");
        ck(!has(none.zh_summary(), "崩溃"), "D10 ★ 无证据绝不出现崩溃字样");
        ck_eq(none.reason_class(), "unclean_unknown", "D11 reason_class 稳定");

        // 崩溃证据里也不能把用户路径打出去（证据本身要过脱敏）
        ck(!has(crashed.evidence, "august"), "D12 证据串本身已脱敏", crashed.evidence);
    }

    // ---------------------------------------------------------------- E
    std::printf("\n-- E. 标记损坏：不崩、不猜，按 unclean_unknown --\n");
    {
        const std::string dir = fresh_dir("corrupt");
        {
            std::ofstream f(dir + "/run.json", std::ios::binary);
            f << "{ this is not json";
        }
        rta::diag::RunMarker m({dir, "run.json", true});
        std::string err;
        const auto prev = m.begin("sid-e1", "1.1.1-test", &err);
        ck(prev.found, "E1 损坏的标记仍然算「上一轮存在」");
        ck(!prev.clean, "E2 损坏标记不得当作 clean");
        ck(prev.marker_corrupt, "E3 marker_corrupt=true");
        ck_eq(prev.reason_class(), "unclean_unknown", "E4 按 unclean_unknown 归类");
        ck(!has(prev.zh_summary(), "崩溃"), "E5 损坏不等于崩溃", prev.zh_summary());
        m.end_clean("quit");
        ck(has(read_file(dir + "/run.json"), "\"state\":\"clean\""), "E6 修复路径：重新写 clean 标记");
    }

    // ---------------------------------------------------------------- F
    std::printf("\n-- F. 原子写入与可读回 --\n");
    {
        const std::string dir = fresh_dir("atomic");
        rta::diag::RunMarker m({dir, "run.json", true});
        m.begin("sid-f1", "1.1.1-test");
        m.beat();
        m.end_clean("quit");
        size_t n_tmp = 0;
        for (const auto& e : std::filesystem::directory_iterator(dir)) {
            const std::string nm = e.path().filename().string();
            if (has(nm, ".tmp") || has(nm, "~")) ++n_tmp;
        }
        ck(n_tmp == 0, "F1 目录内无 .tmp/临时文件残留", std::to_string(n_tmp));
        const std::string raw = read_file(dir + "/run.json");
        rta::diag::RunMarker probe({dir, "run.json", true});
        const auto prev = probe.begin("sid-f2", "1.1.1-test");
        ck(!prev.marker_corrupt, "F2 写出的标记可被完整读回（未撕裂）");
        ck(prev.clean, "F3 读回判定与写入一致", raw);
        probe.end_clean("quit");
    }

    // ---------------------------------------------------------------- G
    std::printf("\n-- G. 心跳节流 --\n");
    {
        const std::string dir = fresh_dir("beat");
        rta::diag::RunMarker m({dir, "run.json", true});
        m.begin("sid-g1", "1.1.1-test");
        const int64_t t0 = m.last_beat_ms();
        ck(t0 > 0, "G1 begin 记下首次心跳时间", std::to_string(t0));
        m.beat(t0 + 100);   // 间隔 100ms < 2000ms → 跳过
        m.beat(t0 + 200);
        ck(m.stats().beats_written == 0, "G2 短间隔心跳不落盘",
           std::to_string(m.stats().beats_written));
        ck(m.stats().beats_skipped == 2, "G3 被节流的心跳被计数",
           std::to_string(m.stats().beats_skipped));
        m.beat(t0 + 5000);
        ck(m.stats().beats_written == 1, "G4 超过间隔后真写一次",
           std::to_string(m.stats().beats_written));
        ck(m.last_beat_ms() == t0 + 5000, "G5 心跳时间前进",
           std::to_string(m.last_beat_ms()));
        // 心跳不得改 state：还在 running
        ck(has(read_file(dir + "/run.json"), "\"state\":\"running\""), "G6 心跳不动 state");
        m.end_clean("quit");
    }

    // ---------------------------------------------------------------- H
    std::printf("\n-- H. 与事件日志联动（主控接入面）--\n");
    {
        const std::string dir = fresh_dir("session");
        rta::diag::DiagConfig cfg;
        cfg.dir = dir;
        cfg.app_version = "1.1.1-test";
        cfg.enabled = true;
        std::string err;
        auto st = rta::diag::diag_start(cfg);
        ck(st.ok, "H1 diag_start 成功", st.error);
        ck(!st.sid.empty(), "H2 自动生成 sid", st.sid);
        ck(!st.previous.found, "H3 首启：没有上一轮");

        {
            rta::diag::ScopedRid rid("req-h1");
            rta::diag::diag_emit("play.start", rta::diag::Stage::Io, nullptr,
                                 {{"rate", "44100", rta::diag::KvKind::Num}});
        }
        rta::diag::diag_stop("user_quit");

        const std::string ev = read_file(dir + "/rlplayer-events.jsonl");
        ck(has(ev, "\"evt\":\"session.start\""), "H4 落盘 session.start", ev);
        ck(has(ev, "\"evt\":\"play.start\""), "H5 rid 上下文内的事件落盘", ev);
        ck(has(ev, "\"rid\":\"req-h1\""), "H6 rid 随事件写入", ev);
        ck(has(ev, "\"evt\":\"session.end\""), "H7 落盘 session.end", ev);
        ck(has(ev, "\"reason\":\"user_quit\""), "H8 session.end 带退出原因", ev);
        ck(has(read_file(dir + "/rlplayer-run.json"), "\"state\":\"clean\""),
           "H9 正常退出写 clean 标记");

        auto st2 = rta::diag::diag_start(cfg);
        ck(st2.ok, "H10 第二次 diag_start 成功", st2.error);
        ck(st2.previous.found && st2.previous.clean, "H11 第二次看到上一轮 clean");
        ck(!has(st2.previous.zh_summary(), "崩溃"), "H12 联动路径也不说崩溃",
           st2.previous.zh_summary());
        rta::diag::diag_stop("quit");
    }

    // ---------------------------------------------------------------- I
    std::printf("\n-- I. 多进程隔离与所有权保护（双 RunMarker / 隔离子进程）--\n");
    {
        // I1-I4: 同进程双 RunMarker 实例，第二实例不会替第一实例改 clean，且不会误将第一实例判为异常
        const std::string dir1 = fresh_dir("multi-marker");
        rta::diag::RunMarker::Config c1{dir1, "run.json", true, 0};
        {
            rta::diag::RunMarker m1(c1);
            rta::diag::RunMarker m2(c1);
            auto p1 = m1.begin("sid-m1", "1.1.1");
            ck(!p1.found, "I1 第一实例首启 found=false");
            ck_eq(p1.reason_class(), "none", "I2 第一实例首启 reason_class=none");

            // 第二实例在第一实例仍处于 running 时启动，应将第一实例的 running 视为正在运行，而非上次崩溃
            auto p2 = m2.begin("sid-m2", "1.1.1");
            ck(!p2.found, "I3 第二实例并发启动时不把第一实例判为 crash/unclean");
            ck_eq(p2.reason_class(), "none", "I4 第二实例首启 reason_class=none");

            // 第二实例尝试正常退出，不应污染/伪造第一实例的 clean 状态
            m2.end_clean("m2_done");
            // 第一实例仍在 running
            ck_eq(m1.sid(), "sid-m1", "I5 第一实例保留自己 sid 所有权");
            m1.end_clean("m1_done");
        }

        // I6-I10: 真实双子进程隔离测试：后一个实例崩溃，不得被前一个实例的 clean 覆盖
        const std::string dir2 = fresh_dir("multiprocess-proc");
        rta::diag::RunMarker::Config c2{dir2, "run.json", true, 0};

        pid_t pid1 = fork();
        if (pid1 == 0) {
            rta::diag::RunMarker p1(c2);
            p1.begin("sid_proc1", "1.1.1");
            usleep(250000); // 0.25s
            p1.end_clean("user_quit");
            _exit(0);
        }

        usleep(50000); // 确保 pid1 先启动并持有标记

        pid_t pid2 = fork();
        if (pid2 == 0) {
            rta::diag::RunMarker p2(c2);
            auto prev_in_p2 = p2.begin("sid_proc2", "1.1.1");
            // 此时 pid1 仍在运行，p2 不得将其视作崩溃
            bool p2_saw_none = (prev_in_p2.reason_class() == "none");
            usleep(350000); // 0.35s: 存活至 pid1 正常退出之后
            // 模拟真实崩溃/强杀：不调用 end_clean，直接退出
            _exit(p2_saw_none ? 42 : 1);
        }

        int status1 = 0, status2 = 0;
        waitpid(pid1, &status1, 0);
        waitpid(pid2, &status2, 0);

        ck(WIFEXITED(status1) && WEXITSTATUS(status1) == 0, "I6 子进程 1 正常退出 (0)");
        ck(WIFEXITED(status2) && WEXITSTATUS(status2) == 42,
           "I7 子进程 2 并发启动时未把运行中的进程 1 误判为崩溃 (exit=42)");

        // 下一次启动（子进程 3）：此时进程 1 虽已正常 end_clean，但进程 2 随后崩溃
        // 门禁判定：必须检出 unclean_unknown，绝不能被进程 1 的 clean 掩盖！
        rta::diag::RunMarker p3(c2);
        auto prev_in_p3 = p3.begin("sid_proc3", "1.1.1");
        ck(prev_in_p3.found, "I8 下一次启动检出上一轮存在标记");
        ck(!prev_in_p3.clean, "I9 ★ 崩溃实例未被前一实例的 clean 覆盖 (clean=false)");
        ck_eq(prev_in_p3.reason_class(), "unclean_unknown", "I10 结论正确落在 unclean_unknown");
        ck_eq(prev_in_p3.sid, "sid_proc2", "I11 准确溯源到崩溃的实例 sid");
        ck(!has(prev_in_p3.zh_summary(), "崩溃"), "I12 无崩溃转储证据时不宣称崩溃");
        p3.end_clean("p3_quit");
    }

    // ---------------------------------------------------------------- J
    std::printf("\n-- J. 诊断副实例事件隔离接线与失败码区分 --\n");
    // J1: 主实例 diag_start：secondary==false、dir==cfg.dir、code 为空串
    {
        const std::string dir1 = fresh_dir("j1-primary");
        rta::diag::DiagConfig cfg1;
        cfg1.dir = dir1;
        cfg1.app_version = "1.1.1-test";
        cfg1.enabled = true;

        auto st1 = rta::diag::diag_start(cfg1);
        ck(st1.ok, "J1-1 diag_start 成功");
        ck(!st1.secondary, "J1 主实例 secondary==false");
        ck_eq(st1.dir, cfg1.dir, "J1 主实例 dir==cfg.dir");
        ck_eq(st1.code, "", "J1 主实例 code 为空串");
        rta::diag::diag_stop("j1_quit");
    }

    // J2: 同进程再次 diag_start（新的 isol_dir）：secondary 必须仍为 false（重入不是副实例）
    {
        const std::string dir2 = fresh_dir("j2-reentry-isol");
        rta::diag::DiagConfig cfg2;
        cfg2.dir = dir2;
        cfg2.app_version = "1.1.1-test";
        cfg2.enabled = true;

        auto st2 = rta::diag::diag_start(cfg2);
        ck(st2.ok, "J2 新 isol_dir 再次 diag_start 成功");
        ck(!st2.secondary, "J2 重入不是副实例 (secondary==false)");
        ck_eq(st2.dir, cfg2.dir, "J2 dir==cfg.dir");
        ck_eq(st2.code, "", "J2 code 为空串");

        // 未 diag_stop 时同目录热重入，依然视为主实例
        auto st2_hot = rta::diag::diag_start(cfg2);
        ck(st2_hot.ok, "J2 未 stop 同目录再次 diag_start 成功");
        ck(!st2_hot.secondary, "J2 热重入 secondary==false");
        ck_eq(st2_hot.dir, cfg2.dir, "J2 热重入 dir==cfg.dir");
        ck_eq(st2_hot.code, "", "J2 热重入 code 为空串");

        rta::diag::diag_stop("j2_quit");
    }

    // J3, J4, J5, J6: 真 fork 子进程测试副实例隔离、事件分流与运行标记所有权
    {
        const std::string shared_dir = fresh_dir("j-shared-proc");
        rta::diag::DiagConfig cfg_main;
        cfg_main.dir = shared_dir;
        cfg_main.app_version = "1.1.1-test";
        cfg_main.enabled = true;

        auto st_main = rta::diag::diag_start(cfg_main);
        ck(st_main.ok, "J3-pre 主实例 diag_start 成功");
        ck(!st_main.secondary, "J3-pre 主实例 secondary==false");
        const std::string main_sid = st_main.sid;

        // 主实例写入独有事件
        {
            rta::diag::ScopedRid rid("rid-main-j4");
            rta::diag::diag_emit("evt.main.unique", rta::diag::Stage::Io, nullptr, {{"source", "main_process"}});
        }

        // 管道传回子进程 diag_start 结果
        int pfd[2];
        ck(::pipe(pfd) == 0, "J3-pre pipe 建立成功");

        pid_t pid = fork();
        if (pid == 0) {
            ::close(pfd[0]);

            auto st_sub = rta::diag::diag_start(cfg_main);

            // 子进程写一条专属事件
            {
                rta::diag::ScopedRid rid("rid-sub-j4");
                rta::diag::diag_emit("evt.sub.unique", rta::diag::Stage::Io, nullptr, {{"source", "sub_process"}});
            }

            // J5 前置：子进程调用 diag_stop
            rta::diag::diag_stop("sub_done");

            // 将关键字段格式化发回：ok;secondary;code;sid;dir\n
            std::string payload;
            payload += (st_sub.ok ? "1;" : "0;");
            payload += (st_sub.secondary ? "1;" : "0;");
            payload += st_sub.code + ";";
            payload += st_sub.sid + ";";
            payload += st_sub.dir + "\n";
            ssize_t w = ::write(pfd[1], payload.data(), payload.size());
            (void)w;
            ::close(pfd[1]);
            _exit(0);
        }

        ::close(pfd[1]);
        char pbuf[1024];
        std::memset(pbuf, 0, sizeof(pbuf));
        ssize_t nr = ::read(pfd[0], pbuf, sizeof(pbuf) - 1);
        ::close(pfd[0]);

        int wstatus = 0;
        waitpid(pid, &wstatus, 0);
        ck(WIFEXITED(wstatus) && WEXITSTATUS(wstatus) == 0, "J3-1 子进程正常退出 (0)");
        ck(nr > 0, "J3-2 父进程成功从管道读取子进程结果");

        std::string raw_line(pbuf);
        std::vector<std::string> parts;
        std::size_t pos_cur = 0;
        while (pos_cur < raw_line.size()) {
            auto pos_sc = raw_line.find(';', pos_cur);
            if (pos_sc == std::string::npos) {
                auto pos_nl = raw_line.find('\n', pos_cur);
                if (pos_nl == std::string::npos) pos_nl = raw_line.size();
                parts.push_back(raw_line.substr(pos_cur, pos_nl - pos_cur));
                break;
            }
            parts.push_back(raw_line.substr(pos_cur, pos_sc - pos_cur));
            pos_cur = pos_sc + 1;
        }

        ck(parts.size() >= 5, "J3-3 字段解析完整");
        const bool sub_ok = (parts.size() > 0 && parts[0] == "1");
        const bool sub_secondary = (parts.size() > 1 && parts[1] == "1");
        const std::string sub_code = (parts.size() > 2 ? parts[2] : "");
        const std::string sub_sid = (parts.size() > 3 ? parts[3] : "");
        const std::string sub_dir = (parts.size() > 4 ? parts[4] : "");

        ck(sub_ok, "J3-4 子进程 diag_start ok==true");
        ck(sub_secondary, "J3 子进程 secondary==true");
        ck_eq(sub_code, "", "J3 子进程 code 为空串");
        ck(has(sub_dir, "/instances/"), "J3 子进程 dir 包含 /instances/", sub_dir);
        ck(has(sub_dir, sub_sid), "J3 子进程 dir 包含子进程 sid", sub_dir);

        // J4: 子进程事件落盘在 instances/<sid>/rlplayer-events.jsonl；主实例 rlplayer-events.jsonl 里不得出现子进程事件
        const std::string sub_ev_path = sub_dir + "/rlplayer-events.jsonl";
        const std::string sub_ev_raw = read_file(sub_ev_path);
        ck(has(sub_ev_raw, "\"evt\":\"evt.sub.unique\""), "J4 子进程事件落盘在 instances/<sid>/rlplayer-events.jsonl", sub_ev_raw);
        ck(has(sub_ev_raw, "\"rid\":\"rid-sub-j4\""), "J4 子进程事件带 sub rid");

        const std::string main_ev_path = shared_dir + "/rlplayer-events.jsonl";
        const std::string main_ev_raw = read_file(main_ev_path);
        ck(has(main_ev_raw, "\"evt\":\"evt.main.unique\""), "J4 主实例包含主实例专属事件", main_ev_raw);
        ck(!has(main_ev_raw, "evt.sub.unique"), "J4 主实例 rlplayer-events.jsonl 里不得出现子进程事件 evt.sub.unique");
        ck(!has(main_ev_raw, "rid-sub-j4"), "J4 主实例中不得出现子进程 rid");

        // J5: 子进程 diag_stop 之后，主实例的 rlplayer-run.json 必须仍是主实例的 state=running/sid（不许被副实例改成 clean）
        const std::string main_run_json = read_file(shared_dir + "/rlplayer-run.json");
        ck(has(main_run_json, "\"state\":\"running\""), "J5 主实例 rlplayer-run.json 仍为 running", main_run_json);
        ck(has(main_run_json, "\"sid\":\"" + main_sid + "\""), "J5 主实例仍持有自己 sid", main_run_json);
        ck(!has(main_run_json, "\"sid\":\"" + sub_sid + "\""), "J5 主实例 run.json 未被副实例 sid 篡改");
        ck(!has(main_run_json, "\"state\":\"clean\""), "J5 主实例 run.json 未被副实例改成 clean");

        // J6: 主实例 diag_stop 后，新一次 diag_start 的 previous.clean==true（原有语义不退化）
        rta::diag::diag_stop("main_done");
        const std::string main_run_clean = read_file(shared_dir + "/rlplayer-run.json");
        ck(has(main_run_clean, "\"state\":\"clean\""), "J6-pre 主实例 stop 后写出 clean 标记");

        auto st_main_next = rta::diag::diag_start(cfg_main);
        ck(st_main_next.ok, "J6-1 主实例再次启动成功");
        ck(!st_main_next.secondary, "J6-2 再次启动仍为主实例 (secondary==false)");
        ck(st_main_next.previous.found, "J6-3 发现上一轮标记");
        ck(st_main_next.previous.clean, "J6 主实例 diag_stop 后新一次 diag_start 的 previous.clean==true");
        ck_eq(st_main_next.previous.sid, main_sid, "J6 准确关联上一轮主实例 sid");
        rta::diag::diag_stop("main_next_done");
    }

    // J7 & J8: run marker 写失败单独可测
    {
        const std::string dir_marker_fail = fresh_dir("j7-marker-fail");
        // 把 <dir>/rlplayer-run.json 先 mkdir 成目录
        std::error_code ec_mkdir;
        std::filesystem::create_directories(dir_marker_fail + "/rlplayer-run.json", ec_mkdir);

        rta::diag::DiagConfig cfg_fail;
        cfg_fail.dir = dir_marker_fail;
        cfg_fail.app_version = "1.1.1-test";
        cfg_fail.enabled = true;

        auto st_fail = rta::diag::diag_start(cfg_fail);
        ck(!st_fail.ok, "J7-1 run marker 写失败时 ok==false");
        ck_eq(st_fail.code, "diag.run_marker_unwritable", "J7 run marker 写失败时 code==diag.run_marker_unwritable");
        ck(st_fail.code != "diag.event_log_unwritable", "J8 反例：event log 正常时 code 不得是 diag.event_log_unwritable");
        rta::diag::diag_stop("j7_quit");
    }

    // J9 & J10: 优先级 3（目录锁不可用）与优先级 1（事件日志不可写）
    {
        // J9: 目录锁文件无法创建/加锁 → "diag.dir_lock_unwritable"，但仍按主实例继续，ok 不置 false
        const std::string dir_lock_fail = fresh_dir("j9-lock-fail");
        std::error_code ec_mkdir;
        std::filesystem::create_directories(dir_lock_fail + "/diag-primary.lock", ec_mkdir);

        rta::diag::DiagConfig cfg_lf;
        cfg_lf.dir = dir_lock_fail;
        cfg_lf.app_version = "1.1.1-test";
        cfg_lf.enabled = true;

        auto st_lf = rta::diag::diag_start(cfg_lf);
        ck(st_lf.ok, "J9 目录锁无法加锁时 ok 仍为 true (不把诊断通道关掉)");
        ck_eq(st_lf.code, "diag.dir_lock_unwritable", "J9 目录锁无法加锁时 code==diag.dir_lock_unwritable");
        ck(!st_lf.secondary, "J9 仍按主实例继续 (secondary==false)");
        ck_eq(st_lf.dir, cfg_lf.dir, "J9 dir 仍为主目录");
        rta::diag::diag_stop("j9_quit");

        // J10: 事件日志打不开 → "diag.event_log_unwritable"（优先级 1）
        const std::string dir_ev_fail = fresh_dir("j10-ev-fail");
        std::filesystem::create_directories(dir_ev_fail + "/rlplayer-events.jsonl", ec_mkdir);

        rta::diag::DiagConfig cfg_ef;
        cfg_ef.dir = dir_ev_fail;
        cfg_ef.app_version = "1.1.1-test";
        cfg_ef.enabled = true;

        auto st_ef = rta::diag::diag_start(cfg_ef);
        ck(!st_ef.ok, "J10 事件日志打不开时 ok==false");
        ck_eq(st_ef.code, "diag.event_log_unwritable", "J10 事件日志打不开时 code==diag.event_log_unwritable");
        rta::diag::diag_stop("j10_quit");
    }

    // 清理：只删本进程自己造的那些目录（名字带 pid，绝不触及真实用户目录）
    for (const auto& d : g_dirs) {
        std::error_code ec;
        std::filesystem::remove_all(d, ec);
    }

    std::printf("\n== 结果: %d passed, %d failed ==\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
