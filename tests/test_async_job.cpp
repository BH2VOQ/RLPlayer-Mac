// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_async_job.cpp — 1.1.5-beta2 M-12：异步 job 去重状态机（纯逻辑，不起线程/不联网）
//
// 判据（PLAN §1.5 / §3）：
//   1. 同 key 5 连点只有 1 次 tryStart 成功；不同 key 互不合并。
//   2. done 一次性交付（takeDone 首次 true、第二次 false），交付后同 key 能重新 tryStart。
//   3. shutdown 后 tryStart 拒绝新任务（已在跑的任务仍可 finish，协作收尾）。
//   4. 迟到 finish（旧 generation）不得覆盖新结果。
#include "meta/async_job.h"

#include <cstdio>
#include <string>

using rta::meta::JobRegistry;

static int g_fail = 0;
static void ck(bool ok, const std::string& what, const std::string& extra = std::string()) {
    std::printf("  [%s] %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(),
                extra.empty() ? "" : " — ", extra.c_str());
    if (!ok) ++g_fail;
}

int main() {
    std::printf("== test_async_job: M-12 去重状态机（5 连点 1 任务 / 迟到结果丢弃 / 退出拒绝）==\n");

    // ---- 1) 同 key 5 连点只起 1 个任务；不同 key 互不合并 ----
    std::printf("-- 1. 5 连点 1 任务 + 不同 key 独立 --\n");
    {
        JobRegistry reg;
        const std::string key = "eid_abc|zh";
        int started = 0;
        std::uint64_t firstGen = 0;
        for (int i = 0; i < 5; ++i) {
            std::uint64_t gen = 0;
            if (reg.tryStart(key, gen)) {
                ++started;
                if (i == 0) firstGen = gen;
            }
        }
        ck(started == 1, "同一 key 连点 5 次只有 1 次 tryStart 成功",
           "started=" + std::to_string(started));
        ck(firstGen != 0, "首次 tryStart 回传非零 generation");
        ck(reg.isRunning(key), "该 key 处于 running");
        ck(reg.size() == 1, "job 表里只有 1 条记录");

        std::uint64_t gen2 = 0;
        ck(reg.tryStart("eid_other|zh", gen2), "不同 key 的 tryStart 成功（互不合并）");
        ck(gen2 != firstGen, "不同 key 的 generation 也不同");
        ck(reg.size() == 2, "job 表里有 2 条独立记录");
        ck(reg.isRunning("eid_other|zh"), "另一个 key 独立 running");

        // 不同 lang 也是不同 key（key = eid|lang）
        std::uint64_t gen3 = 0;
        ck(reg.tryStart("eid_abc|en", gen3), "同 eid 不同 lang 也是独立 job");
        ck(reg.size() == 3, "job 表里有 3 条记录");

        // 完成并交付：一次性
        ck(reg.finish(key, firstGen, "RESULT-ZH"), "第一个 job finish 成功");
        ck(!reg.isRunning(key) && reg.hasDone(key), "finish 后 running=false / done=true");
        std::string got;
        ck(reg.takeDone(key, got) && got == "RESULT-ZH", "takeDone 首次拿到完整结果", got);
        ck(!reg.takeDone(key, got), "takeDone 第二次返回 false（一次性交付）");
        ck(!reg.hasDone(key) && !reg.isRunning(key), "交付后记录从 job 表移除");
        ck(reg.size() == 2, "交付后只剩 2 条其它 key 的记录");

        // 交付后同 key 能重新开始（之后走 fresh 缓存；job 表本身不阻塞新请求）
        std::uint64_t gen4 = 0;
        ck(reg.tryStart(key, gen4), "交付后重新 tryStart 成功");
        ck(gen4 != firstGen, "新一轮 generation 与旧轮不同");
        ck(reg.finish(key, gen4, "RESULT-ZH-2"), "新一轮 finish 成功");
        std::string got2;
        ck(reg.takeDone(key, got2) && got2 == "RESULT-ZH-2", "新一轮结果独立交付", got2);
    }

    // ---- 2) shutdown 后拒绝新任务；在途任务仍可收尾 ----
    std::printf("-- 2. shutdown 拒绝新任务 / 在途任务可收尾 --\n");
    {
        JobRegistry reg;
        std::uint64_t genRunning = 0;
        ck(reg.tryStart("k_inflight|zh", genRunning), "shutdown 前起 1 个在途任务");
        reg.shutdown();
        ck(reg.isShutdown(), "isShutdown=true");
        ck(!reg.tryStart("k_new|zh"), "shutdown 后新 key 的 tryStart 被拒绝");
        ck(!reg.tryStart("k_inflight|zh"), "shutdown 后同 key 也不重复起任务");
        ck(reg.size() == 1, "shutdown 没有凭空增加记录");
        // 已在跑的任务必须仍能 finish（协作收尾，绝不 force-kill）
        ck(reg.finish("k_inflight|zh", genRunning, "LATE-BUT-MINE"),
           "已在跑的任务 shutdown 后仍能 finish");
        std::string got;
        ck(reg.takeDone("k_inflight|zh", got) && got == "LATE-BUT-MINE",
           "在途任务结果可交付", got);
        ck(!reg.tryStart("k_after|zh"), "shutdown 后交付完成也不再接受新任务");
    }

    // ---- 3) 迟到结果丢弃（旧 generation 不覆盖新结果）----
    std::printf("-- 3. 迟到 finish（旧 generation）不覆盖新结果 --\n");
    {
        JobRegistry reg;
        const std::string key = "eid_late|zh";
        std::uint64_t gen1 = 0;
        ck(reg.tryStart(key, gen1), "第一轮 tryStart");
        ck(reg.finish(key, gen1, "R1"), "第一轮 finish");
        std::string got;
        ck(reg.takeDone(key, got) && got == "R1", "第一轮交付 R1", got);

        std::uint64_t gen2 = 0;
        ck(reg.tryStart(key, gen2), "第二轮 tryStart（同 key 重新开工）");
        ck(gen2 != gen1, "第二轮 generation 大于第一轮");

        // 第一轮线程的迟到结果：key 相同但 generation 过期 → 必须丢弃
        ck(!reg.finish(key, gen1, "STALE-R1"), "旧 generation 的迟到 finish 被拒绝");
        ck(reg.isRunning(key) && !reg.hasDone(key), "迟到结果没有把新 job 标成 done");
        std::string empty;
        ck(!reg.takeDone(key, empty), "迟到结果没有进 job 表（取不到 done）");

        ck(reg.finish(key, gen2, "R2"), "第二轮正常 finish");
        std::string got2;
        ck(reg.takeDone(key, got2) && got2 == "R2",
           "交付的是第二轮结果 R2，不是被覆盖的 R1", got2);

        // 不存在的 key / 错误 generation 同样拒绝
        ck(!reg.finish("never_started|zh", 1, "ORPHAN"), "未登记 key 的 finish 被拒绝");
        ck(!reg.tryStart(""), "空 key 拒绝起任务");
        std::uint64_t genBad = 0;
        ck(reg.tryStart("k_bad|zh", genBad), "再起一个任务测错误 generation");
        ck(!reg.finish("k_bad|zh", genBad + 9999, "WRONG"), "错误 generation 的 finish 被拒绝");
        ck(reg.isRunning("k_bad|zh"), "错误 finish 不影响 job 仍在跑");
    }

    std::printf("\n%s（失败 %d 项）\n", g_fail ? "FAILED" : "ALL PASS", g_fail);
    return g_fail ? 1 : 0;
}
