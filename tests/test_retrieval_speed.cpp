// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_retrieval_speed.cpp — 1.1.4-beta7 AI 检索速度（离线，零网络）
//
// 背景（用户 beta7 #1「AI 检索太慢」，实测证据见交付报告）：
//   旧实现把 ds_fetch 丢进 4 个 std::async，然后**按序 futs[i].get()** —— 整个 fetch
//   阶段的耗时等于**最慢那一页**（用户日志里实测 fetch=10215ms），把 AI 整理硬拖到 30s。
//   本用例覆盖替代实现 retrieval_fetch_pages()：
//     * 软截止：到点还没回来的页直接丢弃（正文只是提示词材料，丢页不产生错误数据）；
//     * 已回来的页一个都不能少、顺序必须与入参一致（材料编号 [M1]/[M2] 依赖顺序）；
//     * 空输入、全快、混合快慢三种组合；
//     * detached 线程只写自己的槽：软截止返回后慢线程自然结束，不崩溃/不越界。
//
// 另含：分阶段预算字段的默认值契约（speed fix 的配置面必须稳定，防止以后被人改回 60s）。
#define WIN32_LEAN_AND_MEAN
#include "platform/console.h"
#include "meta/retrieval.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

using namespace rta::meta;

static int g_fail = 0;
static int g_pass = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    if (cond) { ++g_pass; std::printf("  [PASS] %s\n", what.c_str()); }
    else { std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); ++g_fail; }
}

// mock transport：按请求体里的关键字决定延迟，返回合法的 /v1/tools/fetch 响应。
// slow  = 1200ms（故意超过 500ms 软截止）
// medium= 400ms（截止内应该能回来）
// fast  = 立即
static LlmConfig make_cfg(std::atomic<int>* calls) {
    LlmConfig cfg;
    cfg.apiKey = "test-key-not-real";
    cfg.baseUrl = "https://mock.invalid/v1";
    cfg.transport = [calls](const std::string&, const std::string& body,
                            const std::vector<std::string>&) {
        if (calls) ++*calls;
        int sleep_ms = 0;
        std::string tag = "fast";
        if (body.find("slow") != std::string::npos) { sleep_ms = 1200; tag = "slow"; }
        else if (body.find("medium") != std::string::npos) { sleep_ms = 400; tag = "medium"; }
        if (sleep_ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
        rta::net::HttpResponse r;
        r.status = 200;
        const std::string js = "{\"title\":\"T-" + tag + "\",\"content\":\"CONTENT-" + tag + "\"}";
        r.body.assign(js.begin(), js.end());
        return r;
    };
    return cfg;
}

static long long ms_since(std::chrono::steady_clock::time_point t0) {
    return (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();
}

int main() {
    std::printf("== test_retrieval_speed（离线；mock transport，不发任何网络请求）==\n");

    // =====================================================================
    // [A] 配置面契约：分阶段预算默认值必须稳定（防止以后被改回 60s 造成"莫名卡死"）
    // =====================================================================
    {
        RetrievalOptions o;
        ck(o.search_timeout_ms == 12000, "[A] search_timeout_ms 默认 12s（旧实现硬编码 60s）",
           std::to_string(o.search_timeout_ms));
        ck(o.fetch_deadline_ms == 6000, "[A] fetch_deadline_ms 默认 6s（软截止）",
           std::to_string(o.fetch_deadline_ms));
        ck(o.fetch_page_timeout_ms == 10000, "[A] fetch_page_timeout_ms 默认 10s",
           std::to_string(o.fetch_page_timeout_ms));
        ck(o.llm_timeout_ms == 45000, "[A] llm_timeout_ms 默认 45s（旧实现硬编码 60s）",
           std::to_string(o.llm_timeout_ms));
    }

    // =====================================================================
    // [B] 空输入：直接返回空，不能起线程、不能等
    // =====================================================================
    {
        std::atomic<int> calls{0};
        const LlmConfig cfg = make_cfg(&calls);
        const auto t0 = std::chrono::steady_clock::now();
        const auto out = retrieval_fetch_pages({}, cfg, 1000, 500);
        ck(out.empty(), "[B] 空 URL 列表 → 空结果");
        ck(calls.load() == 0, "[B] 空列表不发起任何 fetch 调用", std::to_string(calls.load()));
        ck(ms_since(t0) < 100, "[B] 空列表立即返回（不等 deadline）", std::to_string(ms_since(t0)) + "ms");
    }

    // =====================================================================
    // [C] 全部在截止内返回：一个都不能少，顺序与入参一致
    // =====================================================================
    {
        std::atomic<int> calls{0};
        const LlmConfig cfg = make_cfg(&calls);
        const auto t0 = std::chrono::steady_clock::now();
        const auto out = retrieval_fetch_pages({"https://a/fast1", "https://a/fast2"}, cfg, 2000, 2000);
        const long long ms = ms_since(t0);
        ck(out.size() == 2, "[C] 两个 URL → 两个槽位", std::to_string(out.size()));
        ck(out.size() >= 1 && out[0].ok && out[0].content == "CONTENT-fast",
           "[C] 第 1 页抓到正文");
        ck(out.size() >= 2 && out[1].ok && out[1].content == "CONTENT-fast",
           "[C] 第 2 页抓到正文（顺序与入参一致，材料编号 [M1]/[M2] 依赖它）");
        ck(calls.load() == 2, "[C] 恰好 2 次 fetch（不重复抓）", std::to_string(calls.load()));
        ck(ms < 1500, "[C] 全快路径总耗时接近 0（<1.5s）", std::to_string(ms) + "ms");
    }

    // =====================================================================
    // [D] 软截止：slow 页（1200ms）超过 500ms 截止 → 丢弃；fast 页照常返回
    //     这是本次速度修复的核心行为 —— 旧实现会在这里等满 1200ms。
    // =====================================================================
    {
        std::atomic<int> calls{0};
        const LlmConfig cfg = make_cfg(&calls);
        const auto t0 = std::chrono::steady_clock::now();
        const auto out = retrieval_fetch_pages({"https://a/fast", "https://a/slow"}, cfg, 5000, 500);
        const long long ms = ms_since(t0);
        ck(ms < 1000, "[D] 软截止 500ms：总耗时 <1s（慢页不再拖满 1200ms）", std::to_string(ms) + "ms");
        ck(out.size() == 2, "[D] 槽位数量不变（丢弃 ≠ 上层少一条 URL）", std::to_string(out.size()));
        ck(out.size() >= 1 && out[0].ok && out[0].content == "CONTENT-fast",
           "[D] 快页结果保留");
        ck(out.size() >= 2 && !out[1].ok && out[1].content.empty(),
           "[D] 超时慢页被丢弃（ok=false，content 空，不是假数据）");
        // 慢线程仍在后台自然结束：睡够 1.5s 再走，避免退出时线程还在写共享槽（验证不崩即可）
        std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    }

    // =====================================================================
    // [E] 截止内完成的"中速页"必须保留（软截止不是一刀切；400ms < 1000ms）
    // =====================================================================
    {
        std::atomic<int> calls{0};
        const LlmConfig cfg = make_cfg(&calls);
        const auto t0 = std::chrono::steady_clock::now();
        const auto out = retrieval_fetch_pages({"https://a/medium"}, cfg, 5000, 1500);
        const long long ms = ms_since(t0);
        ck(out.size() == 1 && out[0].ok && out[0].content == "CONTENT-medium",
           "[E] 400ms 的页在 1500ms 截止内完成 → 保留");
        ck(ms >= 350 && ms < 1400, "[E] 耗时落在页自身延迟附近（说明真的等到了结果）",
           std::to_string(ms) + "ms");
    }

    // =====================================================================
    // [F] 缓存 TTL 语义不回归：7 天有效；expires_at 缺失按 generated_at+7d 推算
    //     （stale-while-revalidate 依赖这个判据，改错会把"新鲜"内容当过期）
    // =====================================================================
    {
        SummaryResult sr;
        sr.ok = true;
        sr.generated_at = 1000;
        sr.expires_at = 1000 + 7 * 86400;
        ck(!summary_is_expired(sr, 1000 + 6 * 86400), "[F] 第 6 天仍未过期");
        ck(summary_is_expired(sr, 1000 + 7 * 86400), "[F] 第 7 天过期（TTL 边界）");
        SummaryResult no_exp;
        no_exp.generated_at = 2000;   // expires_at = 0 → 按 generated_at + 7d 推算
        ck(!summary_is_expired(no_exp, 2000 + 3 * 86400), "[F] expires_at 缺失时按 7 天 TTL 推算");
        ck(summary_is_expired(no_exp, 2000 + 8 * 86400), "[F] 推算 TTL 同样会过期");
    }

    std::printf("\n%s（通过 %d 项，失败 %d 项）\n",
                g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
