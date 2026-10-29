// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。

#include "diag/report.h"
#include "diag/event.h"
#include <cstdio>
#include <string>
#include <vector>

int main() {
    using namespace rta::diag;
    int fail = 0;

    auto ck = [&](bool cond, const std::string& desc) {
        if (!cond) {
            std::printf("FAIL: %s\n", desc.c_str());
            fail++;
        } else {
            std::printf("PASS: %s\n", desc.c_str());
        }
    };

    // -------------------------------------------------------------
    // 对抗 1：Q2 不同 rid 分别包含 format 与 rate，不可判为 Known
    // -------------------------------------------------------------
    {
        BundleSpec spec;
        spec.case_id = "test-q2-diff-rid";
        spec.cs.simulated = true;
        spec.run.known = true;
        spec.run.clean_exit = true;

        std::string ev =
            "{\"ts\":1,\"seq\":1,\"sid\":\"s1\",\"rid\":\"rid-1\",\"evt\":\"decode.start\",\"stage\":\"decode\",\"code\":\"\",\"kv\":{\"format\":\"flac\"}}\n"
            "{\"ts\":2,\"seq\":2,\"sid\":\"s1\",\"rid\":\"rid-2\",\"evt\":\"decode.rate\",\"stage\":\"decode\",\"code\":\"\",\"kv\":{\"rate\":44100}}\n";

        std::vector<BundleEntry> items{
            make_entry("diag.json", "{\"version\":\"1.1.1\",\"os\":\"macOS\"}", EntryKind::Json, 100),
            make_entry("events.jsonl", ev, EntryKind::Jsonl, 80),
            make_entry("uievents.jsonl", "", EntryKind::Jsonl, 60)
        };
        auto bundle = assemble(spec, std::move(items), "test q2");
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));

        ck(rep.questions.size() >= 2, "Q2 present");
        ck(rep.questions[1].q == 2, "Q2 index verified");
        ck(rep.questions[1].status != QStatus::Known, "Q2 不同 rid 分别 format/rate 不可为 Known (got " + std::string(qstatus_name(rep.questions[1].status)) + ")");
    }

    // -------------------------------------------------------------
    // 对抗 2：Q5 旧 device (rid-1) + 当前请求 (rid-2)，不可判为 Known
    // -------------------------------------------------------------
    {
        BundleSpec spec;
        spec.case_id = "test-q5-diff-rid";
        spec.cs.simulated = true;
        spec.run.known = true;
        spec.run.clean_exit = true;

        std::string ev =
            "{\"ts\":1,\"seq\":1,\"sid\":\"s1\",\"rid\":\"rid-old\",\"evt\":\"device.init\",\"stage\":\"negotiate\",\"code\":\"\",\"kv\":{\"device\":\"Built-in\"}}\n"
            "{\"ts\":2,\"seq\":2,\"sid\":\"s1\",\"rid\":\"rid-cur\",\"evt\":\"rate.req\",\"stage\":\"negotiate\",\"code\":\"\",\"kv\":{\"requested_rate\":96000,\"actual_rate\":96000}}\n";

        std::vector<BundleEntry> items{
            make_entry("diag.json", "{\"version\":\"1.1.1\",\"os\":\"macOS\"}", EntryKind::Json, 100),
            make_entry("events.jsonl", ev, EntryKind::Jsonl, 80),
            make_entry("uievents.jsonl", "", EntryKind::Jsonl, 60)
        };
        auto bundle = assemble(spec, std::move(items), "test q5");
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));

        ck(rep.questions.size() >= 5, "Q5 present");
        ck(rep.questions[4].q == 5, "Q5 index verified");
        ck(rep.questions[4].status != QStatus::Known, "Q5 旧 device+当前请求不可为 Known (got " + std::string(qstatus_name(rep.questions[4].status)) + ")");
    }

    // -------------------------------------------------------------
    // 对抗 3：Q6 仅有保存偏好（saved settings），没有 effective_settings + fingerprint，不可判为 Known
    // -------------------------------------------------------------
    {
        BundleSpec spec;
        spec.case_id = "test-q6-saved-only";
        spec.cs.simulated = true;
        spec.run.known = true;
        spec.run.clean_exit = true;

        // diag.json 只有 settings（保存偏好），缺少 effective_settings 与 settings_fingerprint
        std::vector<BundleEntry> items{
            make_entry("diag.json", "{\"version\":\"1.1.1\",\"settings\":{\"exclusive\":true}}", EntryKind::Json, 100),
            make_entry("events.jsonl", "", EntryKind::Jsonl, 80),
            make_entry("uievents.jsonl", "", EntryKind::Jsonl, 60)
        };
        auto bundle = assemble(spec, std::move(items), "test q6");
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));

        ck(rep.questions.size() >= 6, "Q6 present");
        ck(rep.questions[5].q == 6, "Q6 index verified");
        ck(rep.questions[5].status != QStatus::Known, "Q6 仅保存偏好不可为 Known (got " + std::string(qstatus_name(rep.questions[5].status)) + ")");
    }

    // -------------------------------------------------------------
    // 对抗 4：Q3 只有 init 阶段事件，不可判为 Known
    // -------------------------------------------------------------
    {
        BundleSpec spec;
        spec.case_id = "test-q3-init-only";
        spec.cs.simulated = true;
        spec.run.known = true;
        spec.run.clean_exit = true;

        std::string ev =
            "{\"ts\":1,\"seq\":1,\"sid\":\"s1\",\"rid\":\"r1\",\"evt\":\"init.err\",\"stage\":\"init\",\"code\":\"init.config_invalid\",\"kv\":{}}\n";

        std::vector<BundleEntry> items{
            make_entry("diag.json", "{\"version\":\"1.1.1\"}", EntryKind::Json, 100),
            make_entry("events.jsonl", ev, EntryKind::Jsonl, 80),
            make_entry("uievents.jsonl", "", EntryKind::Jsonl, 60)
        };
        auto bundle = assemble(spec, std::move(items), "test q3");
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));

        ck(rep.questions.size() >= 3, "Q3 present");
        ck(rep.questions[2].q == 3, "Q3 index verified");
        ck(rep.questions[2].status != QStatus::Known, "Q3 只有 init 不可为 Known (got " + std::string(qstatus_name(rep.questions[2].status)) + ")");
    }

    // -------------------------------------------------------------
    // 对抗 5：Q9 run.known=false 时必须为 Missing
    // -------------------------------------------------------------
    {
        BundleSpec spec;
        spec.case_id = "test-q9-unknown";
        spec.cs.simulated = true;
        spec.run.known = false; // 首次运行，缺少标记

        std::vector<BundleEntry> items{
            make_entry("diag.json", "{\"version\":\"1.1.1\"}", EntryKind::Json, 100),
            make_entry("events.jsonl", "", EntryKind::Jsonl, 80),
            make_entry("uievents.jsonl", "", EntryKind::Jsonl, 60)
        };
        auto bundle = assemble(spec, std::move(items), "test q9");
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));

        ck(rep.questions.size() >= 9, "Q9 present");
        ck(rep.questions[8].q == 9, "Q9 index verified");
        ck(rep.questions[8].status == QStatus::Missing, "Q9 run.known=false 必须为 Missing (got " + std::string(qstatus_name(rep.questions[8].status)) + ")");
    }

    // -------------------------------------------------------------
    // 对抗 6：多个独立失败来自不同 rid，不可按 priority 猜唯一根因，必须判为 ambiguous
    // -------------------------------------------------------------
    {
        BundleSpec spec;
        spec.case_id = "test-diff-rid-ambiguous";
        spec.cs.simulated = true;
        spec.run.known = true;
        spec.run.clean_exit = true;

        // rid-A: decode 截断 (priority 92)
        // rid-B: rate_unsupported (priority 90)
        std::string ev =
            "{\"ts\":1,\"seq\":1,\"sid\":\"s1\",\"rid\":\"rid-A\",\"evt\":\"failure\",\"stage\":\"decode\",\"code\":\"decode.truncated_flac\",\"kv\":{\"format\":\"flac\",\"truncated\":true}}\n"
            "{\"ts\":2,\"seq\":2,\"sid\":\"s1\",\"rid\":\"rid-B\",\"evt\":\"failure\",\"stage\":\"negotiate\",\"code\":\"negotiate.rate_unsupported\",\"kv\":{\"rate_supported\":false}}\n";

        std::vector<BundleEntry> items{
            make_entry("diag.json", "{\"version\":\"1.1.1\",\"os\":\"macOS\"}", EntryKind::Json, 100),
            make_entry("events.jsonl", ev, EntryKind::Jsonl, 80),
            make_entry("uievents.jsonl", "", EntryKind::Jsonl, 60)
        };
        auto bundle = assemble(spec, std::move(items), "test ambiguous rids");
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));

        ck(rep.verdict == Verdict::Ambiguous, "多个独立失败不同 rid 不可猜唯一根因，必须为 ambiguous (got verdict=" + std::to_string((int)rep.verdict) + ")");
    }

    // 额外兼容检查：lastError 与 last_error 兼容解析
    {
        BundleSpec spec;
        spec.case_id = "test-lastError-compat";
        spec.cs.simulated = true;
        spec.run.known = true;
        spec.run.clean_exit = true;

        std::vector<BundleEntry> items{
            make_entry("diag.json", "{\"version\":\"1.1.1\",\"lastError\":\"some legacy error\"}", EntryKind::Json, 100),
            make_entry("events.jsonl", "", EntryKind::Jsonl, 80),
            make_entry("uievents.jsonl", "", EntryKind::Jsonl, 60)
        };
        auto bundle = assemble(spec, std::move(items), "test lastError");
        auto rep = analyze(evidence_from_entries(bundle.entries, spec));

        ck(rep.questions.size() >= 4, "Q4 present");
        ck(rep.questions[3].status == QStatus::Partial, "lastError 兼容解析并正确回答 Q4 Partial");
    }

    return fail ? 1 : 0;
}
