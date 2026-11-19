// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_feedback_live.cpp — 反馈后台（rlplayer.rainlain.com）端到端联调
//
// ============================ 为什么默认 SKIP ============================
// 这是**唯一**会真的往用户后台写数据的测试：它会建一张工单、再把它删掉。
// 全量 ctest 必须能在离线/无网环境跑绿，所以默认打印 SKIP 直接返回 0；
// 只有显式设置 RLPLAYER_FEEDBACK_LIVE=1 才执行。
//
// ============================ 它证明了什么（本层证明不了的事） ============================
// 纯逻辑层（test_feedback_api.cpp）只能证明"我们生成的 JSON 长这样"；
// 这个测试拿**同一份 build_feedback_upload() 产物**去问真后台，证明：
//   ① 请求体的字段名/长度/编码后台真的接受（201 + 工单号）；
//   ② 同一幂等键重放返回同一个工单号（200 幂等，不重复建单）；
//   ③ client（安装 ID）能查状态、能取回诊断包且**逐字节**一致；
//   ④ 7 天内自助删除可用，删完再查是 404。
// 这四条任何一条不成立，客户端接上了也是假的。
//
// ============================ 安全/卫生 ============================
//   * 使用**临时生成的安装 ID**，绝不读写 App 的 rlplayer-feedback-client-id；
//   * 正文明确标注是自动测试，便于后台识别；结束时删除工单，不留垃圾；
//   * 不打印任何 token（本接口本来也不需要 token）；不碰用户数据。
#include "net/feedback_api.h"
#include "net/http_client.h"
#include "net/install_id.h"
#include "net/json.h"

#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <string>
#include <vector>

static int g_fail = 0;
static void ck(bool ok, const char* what, const std::string& detail = std::string()) {
    if (ok) std::printf("  [PASS] %s\n", what);
    else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

static std::string body_of(const rta::net::HttpResponse& r) {
    return std::string(r.body.begin(), r.body.end());
}

int main() {
    if (!std::getenv("RLPLAYER_FEEDBACK_LIVE")) {
        std::printf("SKIP: 设置 RLPLAYER_FEEDBACK_LIVE=1 才跑真实后台端到端"
                    "（会在后台建一张工单并在结束时删除）\n");
        return 0;
    }
    namespace fb = rta::feedback;
    std::printf("=== test_feedback_live: 真实后台端到端（会建单→查→取诊断→删除）===\n");

    // 独立安装 ID（不碰 App 的持久化文件）
    unsigned char entropy[16];
    arc4random_buf(entropy, sizeof entropy);
    const std::string client = fb::install_id_new(entropy);
    ck(fb::install_id_valid(client), "临时安装 ID 形态合法", client);

    const long long now = (long long)std::time(nullptr);
    unsigned int rnd = 0;
    arc4random_buf(&rnd, sizeof rnd);
    const std::string key = fb::make_feedback_idempotency_key(now, rnd);
    ck(fb::feedback_idempotency_key_valid(key), "幂等键形态合法", key);

    const std::string text =
        "RLPlayer 1.1.7 反馈通道端到端自动测试（本条由 tests/test_feedback_live.cpp 创建，"
        "测试结束会自动删除）。时间=" + std::to_string(now);
    const std::string diag =
        "{\"schema\":\"rlplayer.feedback.selftest\",\"note\":\"自动化联调\",\"ts\":" +
        std::to_string(now) + ",\"中文\":\"诊断包内容\"}";

    fb::FeedbackUploadInput in;
    in.text = text;
    in.version = "1.1.7";
    in.os = "macOS · RLPlayer selftest";
    in.client = client;
    in.diag_json = diag;
    in.attach_diag = true;
    in.idempotency_key = key;
    const auto body = fb::build_feedback_upload(in);
    ck(body.ok, "请求体构建成功", body.error);
    if (!body.ok) return 1;

    const std::vector<std::string> headers = {"X-RLPlayer-Platform: mac",
                                              "X-RLPlayer-Client: " + client};

    // ---- ① watchdog ----
    {
        const auto r = rta::net::http_get(fb::kFeedbackWatchdogUrl, {}, fb::kFeedbackWatchdogTimeoutMs);
        const auto wd = fb::parse_feedback_watchdog(r.status, body_of(r));
        ck(wd.reachable, "watchdog 可达（200 + ok:true）", wd.error);
        ck(wd.text_bytes == 16384, "watchdog textBytes=16384",
           std::to_string(wd.text_bytes));
        ck(wd.diag_bytes == 8u * 1024u * 1024u, "watchdog diagBytes=8 MiB",
           std::to_string(wd.diag_bytes));
        ck(wd.rate_per_minute == 5, "watchdog ratePerMinute=5", std::to_string(wd.rate_per_minute));
    }

    // ---- ② 上传（201 新建）----
    const auto r1 = rta::net::http_post(fb::kFeedbackUploadUrl, body.json, headers,
                                        "application/json", fb::kFeedbackUploadTimeoutMs);
    const std::string b1 = body_of(r1);
    const auto rep1 = fb::parse_feedback_upload_reply(r1.status, b1);
    ck(rep1.ok && !rep1.id.empty(), "上传成功且拿到工单号", b1);
    if (!rep1.ok) {
        std::printf("  汇总：%d 项失败（上传未成功，后续用例跳过）\n", g_fail);
        return 1;
    }
    ck(rep1.diag_stored, "后台保存了诊断包（diagStored=true）", b1);

    // ---- ③ 幂等重放：同 key 必须返回同一工单号 ----
    {
        const auto r2 = rta::net::http_post(fb::kFeedbackUploadUrl, body.json, headers,
                                            "application/json", fb::kFeedbackUploadTimeoutMs);
        const std::string b2 = body_of(r2);
        const auto rep2 = fb::parse_feedback_upload_reply(r2.status, b2);
        ck(rep2.ok && rep2.id == rep1.id, "同一幂等键重放返回同一工单号", b2);
    }

    const std::string ticket = std::string(fb::kFeedbackTicketUrlPrefix) + rep1.id;
    const std::string q_client = "?client=" + client;

    // ---- ④ 查状态 ----
    {
        const auto r = rta::net::http_get(ticket + q_client, {}, 20000);
        ck(r.status == 200, "查状态 HTTP 200", std::to_string(r.status));
        const auto j = rta::net::json_parse(body_of(r));
        ck(j["ok"].b == true, "查状态 ok:true");
        ck(j["id"].s() == rep1.id, "查状态返回同一工单号", j["id"].s());
        ck(j["diagStored"].b == true, "查状态 diagStored=true");
        ck(j["canDelete"].b == true, "查状态 canDelete=true（7 天窗口内）");
    }

    // ---- ⑤ 取回诊断包：逐字节一致 ----
    {
        const auto r = rta::net::http_get(ticket + "/diag" + q_client, {}, 20000);
        ck(r.status == 200, "取诊断包 HTTP 200", std::to_string(r.status));
        ck(body_of(r) == diag, "诊断包与上传内容逐字节一致",
           "got=" + body_of(r).substr(0, 80));
    }

    // ---- ⑥ 自助删除 ----
    {
        const std::string del_body = "{\"client\":\"" + client + "\"}";
        const auto r = rta::net::http_post(ticket + "/delete", del_body, headers,
                                           "application/json", 20000);
        const auto j = rta::net::json_parse(body_of(r));
        ck(r.status == 200 && j["ok"].b == true && j["deleted"].b == true,
           "7 天内自助删除成功", body_of(r));
    }

    // ---- ⑦ 删除后不可再查 ----
    {
        const auto r = rta::net::http_get(ticket + q_client, {}, 20000);
        ck(r.status == 404, "删除后工单不存在（404）", std::to_string(r.status));
    }

    std::printf("\n%s（%d 项失败）\n", g_fail == 0 ? "反馈后台端到端全部通过" : "反馈后台端到端有失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}
