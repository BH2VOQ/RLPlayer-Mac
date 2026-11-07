// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_llm_models.cpp — LLM 模型列表解析与拉取测试（全部离线，零真实网络）
//
// 判据说明（铁律 3）：
//   * 解析链路：喂写死的合法/畸形报文，断言返回结构、空 id 过滤、name/model 兜底、去重保序；
//   * 脱敏链路：模拟 401 报错带回显 key，断言输出 error 绝对不含原始 apiKey；
//   * 缓存链路：断言成功缓存 60s、force 绕过、换 key 不命中，以及「失败绝不缓存」（重试递增计数）；
//   * URL 规整：断言带/不带尾部 /、已含 /v1 时，发出的 URL 严格准确；空 key 零网络。
//
// 261107 追加（任意 OpenAI 兼容端点 + 多路径回退，§11-§19）：
//   * llm_normalize_base / llm_base_candidates / llm_tools_base 三条纯函数逐条断言；
//   * models 回退：404 后试 /v1、401 快速失败（只发一次且不泄 key）、全失败报已尝试路径，
//     以及 2xx 但报文不是模型列表时继续试下一条；
//   * chat 回退：只有 404/405 换路径，且用量账本只增 1；401 只发一次；
//   * 端点解析缓存：命中后 chat 直接打解析出来的 base，llm_endpoint_cache_clear() 后重新按候选顺序试。

#include "meta/llm.h"
#include <cstdio>
#include <string>
#include <vector>
#include <atomic>
#include <filesystem>
#include <system_error>

using namespace rta::meta;

static int g_fail = 0;
static void ck(bool cond, const char* what, const std::string& detail = "") {
    if (cond) {
        std::printf("  [PASS] %s\n", what);
    } else {
        std::printf("  [FAIL] %s  %s\n", what, detail.c_str());
        ++g_fail;
    }
}

int main() {
    std::printf("== meta/llm.h LLM 模型列表（离线单测）==\n");

    // ---------------- 1) 三种 JSON 形态解析 ----------------
    std::printf("-- 1. 三种 JSON 形态解析 --\n");
    {
        // 形态 A: OpenAI 标准 {"object":"list","data":[...]}
        const std::string jsonA = R"({
            "object": "list",
            "data": [
                {"id": "gpt-4", "owned_by": "openai", "created": 1687882411},
                {"id": "deepseek-chat", "owned_by": "deepseek", "created": 1700000000}
            ]
        })";
        LlmModelList resA = llm_parse_models_response(jsonA);
        ck(resA.ok, "形态 A 解析成功");
        ck(resA.count() == 2, "形态 A 包含 2 个模型");
        ck(resA.has("gpt-4") && resA.has("deepseek-chat") && !resA.has("claude"), "形态 A has() 判据准确");
        ck(resA.ids() == std::vector<std::string>{"gpt-4", "deepseek-chat"}, "形态 A ids() 列表匹配");
        ck(resA.models[0].ownedBy == "openai" && resA.models[0].created == 1687882411, "形态 A 字段解析 (ownedBy/created)");

        // 形态 B: {"models":[...]}
        const std::string jsonB = R"({
            "models": [
                {"id": "model-b1"},
                {"id": "model-b2"}
            ]
        })";
        LlmModelList resB = llm_parse_models_response(jsonB);
        ck(resB.ok, "形态 B (models键) 解析成功");
        ck(resB.count() == 2, "形态 B 包含 2 个模型");
        ck(resB.ids() == std::vector<std::string>{"model-b1", "model-b2"}, "形态 B ids() 匹配");

        // 形态 C: 顶层纯数组 ["...", "..."]
        const std::string jsonC = R"(["model-c1", "model-c2", "model-c3"])";
        LlmModelList resC = llm_parse_models_response(jsonC);
        ck(resC.ok, "形态 C (顶层纯数组) 解析成功");
        ck(resC.count() == 3, "形态 C 包含 3 个模型");
        ck(resC.ids() == std::vector<std::string>{"model-c1", "model-c2", "model-c3"}, "形态 C ids() 匹配");
    }

    // ---------------- 2) name/model 兜底与优先级 ----------------
    std::printf("-- 2. name/model 兜底与优先级 --\n");
    {
        const std::string jsonFallback = R"({
            "data": [
                {"name": "fallback-by-name"},
                {"model": "fallback-by-model"},
                {"id": "primary-id", "name": "ignored-name", "model": "ignored-model"},
                {"id": "   ", "name": "fallback-when-id-whitespace"}
            ]
        })";
        LlmModelList res = llm_parse_models_response(jsonFallback);
        ck(res.ok, "兜底用例解析成功");
        ck(res.count() == 4, "兜底 4 个有效条目");
        ck(res.models[0].id == "fallback-by-name", "无 id 时退至 name");
        ck(res.models[1].id == "fallback-by-model", "无 id/name 时退至 model");
        ck(res.models[2].id == "primary-id", "优先使用非空 id");
        ck(res.models[3].id == "fallback-when-id-whitespace", "id 为纯空白时退至 name");
    }

    // ---------------- 3) 去重保序 ----------------
    std::printf("-- 3. 去重保序 --\n");
    {
        const std::string jsonDedupe = R"(["m1", "m2", "m1", "m3", "m2", "m4"])";
        LlmModelList res = llm_parse_models_response(jsonDedupe);
        ck(res.ok, "去重用例解析成功");
        ck(res.count() == 4, "重复项被去除 (5->4)");
        ck(res.ids() == std::vector<std::string>{"m1", "m2", "m3", "m4"}, "去重同时保持服务端首次出现顺序");
    }

    // ---------------- 4) 空 id 跳过 ----------------
    std::printf("-- 4. 空 id 跳过 --\n");
    {
        const std::string jsonEmpty = R"([
            "m1",
            "",
            "   ",
            {"id": ""},
            {"id": "   "},
            {},
            "m2"
        ])";
        LlmModelList res = llm_parse_models_response(jsonEmpty);
        ck(res.ok, "空条目用例解析成功");
        ck(res.ids() == std::vector<std::string>{"m1", "m2"}, "所有空/全空白条目均被跳过");
    }

    // ---------------- 5) 错误与畸形输入解析 ----------------
    std::printf("-- 5. 错误与畸形输入解析 --\n");
    {
        // 非 JSON
        LlmModelList rBad1 = llm_parse_models_response("not json at all");
        ck(!rBad1.ok && !rBad1.error.empty(), "非 JSON 字符串报 ok=false 且有 error", rBad1.error);

        LlmModelList rBad2 = llm_parse_models_response("");
        ck(!rBad2.ok && !rBad2.error.empty(), "空字符串报 ok=false 且有 error", rBad2.error);

        LlmModelList rBad3 = llm_parse_models_response("{invalid json syntax");
        ck(!rBad3.ok && !rBad3.error.empty(), "残缺 JSON 语法报 ok=false 且有 error", rBad3.error);

        // 服务端错误结构 {"error":{"message":"..."}}
        const std::string jsonErrObj = R"({"error":{"message":"Invalid token specified"}})";
        LlmModelList rErr1 = llm_parse_models_response(jsonErrObj);
        ck(!rErr1.ok, "服务端 error 对象解析出 ok=false");
        ck(rErr1.error.find("Invalid token specified") != std::string::npos, "error 提取出 message 内容", rErr1.error);

        // 服务端错误结构 {"error":"Direct error"}
        const std::string jsonErrStr = R"({"error":"Direct error string"})";
        LlmModelList rErr2 = llm_parse_models_response(jsonErrStr);
        ck(!rErr2.ok, "服务端 error 字符串解析出 ok=false");
        ck(rErr2.error.find("Direct error string") != std::string::npos, "error 提取出直接字符串", rErr2.error);

        // 缺 data/models 数组
        const std::string jsonNoArr = R"({"object":"list","something_else":123})";
        LlmModelList rNoArr = llm_parse_models_response(jsonNoArr);
        ck(!rNoArr.ok, "缺少 data/models 数组解析出 ok=false");
        ck(rNoArr.error.find("缺少 data/models 数组") != std::string::npos, "error 提示缺少数组", rNoArr.error);
    }

    // ---------------- 6) 敏感信息脱敏 (redact) ----------------
    std::printf("-- 6. 敏感信息脱敏 (redact) --\n");
    {
        llm_models_cache_clear();
        const std::string sensitiveKey = "sk-live-secret-key-998877665544";
        LlmConfig cfg;
        cfg.baseUrl = "https://api.gateway.example";
        cfg.apiKey  = sensitiveKey;
        cfg.transport = [&](const std::string&, const std::string&, const std::vector<std::string>&) {
            rta::net::HttpResponse resp;
            resp.status = 401;
            // 模拟网关把 key 原样回显进 message
            const std::string echoBody = "{\"error\":{\"message\":\"Invalid key: " + sensitiveKey + "\"}}";
            resp.body.assign(echoBody.begin(), echoBody.end());
            return resp;
        };

        LlmModelList res = llm_models_fetch(cfg);
        ck(!res.ok, "401 请求返回 ok=false");
        ck(res.error.find(sensitiveKey) == std::string::npos, "error 中绝对不含原始 apiKey (已脱敏)");
        ck(res.error.find("****") != std::string::npos, "error 中敏感 key 已被 **** 遮盖", res.error);
    }

    // ---------------- 7) 缓存与重试机制 ----------------
    std::printf("-- 7. 缓存与重试机制 --\n");
    {
        llm_models_cache_clear();
        std::atomic<int> callCount{0};
        LlmConfig cfg;
        cfg.baseUrl = "https://api.gateway.example";
        cfg.apiKey  = "sk-cache-test-key";
        cfg.transport = [&](const std::string&, const std::string&, const std::vector<std::string>&) {
            ++callCount;
            rta::net::HttpResponse resp;
            resp.status = 200;
            const std::string b = R"({"data":[{"id":"m1"}]})";
            resp.body.assign(b.begin(), b.end());
            return resp;
        };

        // 第一次调用：真正发请求
        bool cached1 = true;
        LlmModelList r1 = llm_models_fetch(cfg, 15000, false, &cached1);
        ck(r1.ok, "第 1 次 fetch 成功");
        ck(!r1.fromCache && !cached1, "第 1 次 fromCache=false, outCached=false");
        ck(callCount == 1, "第 1 次发起网络请求 (callCount == 1)");

        // 第二次调用：命中进程内缓存，不发起网络请求
        bool cached2 = false;
        LlmModelList r2 = llm_models_fetch(cfg, 15000, false, &cached2);
        ck(r2.ok, "第 2 次 fetch 成功");
        ck(r2.fromCache && cached2, "第 2 次命中缓存 (fromCache=true, outCached=true)");
        ck(callCount == 1, "第 2 次未触发网络请求 (callCount 仍为 1)");
        ck(r2.ids() == r1.ids(), "缓存结果内容一致");

        // force = true：绕过缓存，触发新请求
        bool cached3 = true;
        LlmModelList r3 = llm_models_fetch(cfg, 15000, true, &cached3);
        ck(r3.ok, "第 3 次 (force) fetch 成功");
        ck(!r3.fromCache && !cached3, "第 3 次 (force) 绕过缓存");
        ck(callCount == 2, "第 3 次 (force) 触发网络请求 (callCount == 2)");

        // 换 key 不命中
        cfg.apiKey = "sk-different-key";
        bool cached4 = true;
        LlmModelList r4 = llm_models_fetch(cfg, 15000, false, &cached4);
        ck(r4.ok, "换 key fetch 成功");
        ck(!r4.fromCache && !cached4, "换 key 未命中旧缓存");
        ck(callCount == 3, "换 key 触发网络请求 (callCount == 3)");

        // llm_models_cache_clear 复位测试
        llm_models_cache_clear();
        bool cached5 = true;
        LlmModelList r5 = llm_models_fetch(cfg, 15000, false, &cached5);
        ck(r5.ok, "cache_clear 后 fetch 成功");
        ck(!r5.fromCache && !cached5, "cache_clear 后未命中缓存");
        ck(callCount == 4, "cache_clear 后触发网络请求 (callCount == 4)");
    }

    // ---------------- 8) 失败绝不缓存 (重试验证) ----------------
    std::printf("-- 8. 失败绝不缓存 (重试验证) --\n");
    {
        llm_models_cache_clear();
        std::atomic<int> failCallCount{0};
        LlmConfig cfg;
        cfg.baseUrl = "https://api.gateway.example";
        cfg.apiKey  = "sk-fail-no-cache";
        cfg.transport = [&](const std::string&, const std::string&, const std::vector<std::string>&) {
            ++failCallCount;
            rta::net::HttpResponse resp;
            resp.status = 500;
            const std::string b = R"({"error":{"message":"Internal server error"}})";
            resp.body.assign(b.begin(), b.end());
            return resp;
        };

        // 第一次失败
        LlmModelList rf1 = llm_models_fetch(cfg, 15000, false);
        ck(!rf1.ok, "第 1 次 fetch 500 失败");
        ck(failCallCount == 1, "第 1 次发起请求 (callCount == 1)");

        // 第二次在没有设置 force 的情况下重试：因为失败不缓存，必须再次发起网络请求
        LlmModelList rf2 = llm_models_fetch(cfg, 15000, false);
        ck(!rf2.ok, "第 2 次 fetch 500 失败");
        ck(failCallCount == 2, "失败不缓存：第 2 次真实发起重试 (callCount == 2)");
    }

    // ---------------- 9) URL 规整与空 key 拦截 ----------------
    std::printf("-- 9. URL 规整与空 key 拦截 --\n");
    {
        llm_models_cache_clear();
        std::vector<std::string> requestedUrls;
        LlmConfig cfg;
        cfg.apiKey = "sk-test-key";
        cfg.transport = [&](const std::string& url, const std::string&, const std::vector<std::string>&) {
            requestedUrls.push_back(url);
            rta::net::HttpResponse resp;
            resp.status = 200;
            const std::string b = R"(["m1"])";
            resp.body.assign(b.begin(), b.end());
            return resp;
        };

        // base 不带尾部 /
        cfg.baseUrl = "https://api.deepseek.com";
        llm_models_fetch(cfg, 15000, true);
        ck(!requestedUrls.empty() && requestedUrls.back() == "https://api.deepseek.com/models",
           "base 不带尾部 / -> 请求 URL 精确为 https://api.deepseek.com/models", requestedUrls.back());

        // base 带尾部 /
        cfg.baseUrl = "https://api.deepseek.com/";
        llm_models_fetch(cfg, 15000, true);
        ck(requestedUrls.back() == "https://api.deepseek.com/models",
           "base 带尾部 / -> 请求 URL 精确为 https://api.deepseek.com/models", requestedUrls.back());

        // base 已含 /v1
        cfg.baseUrl = "https://api.deepseek.com/v1";
        llm_models_fetch(cfg, 15000, true);
        ck(requestedUrls.back() == "https://api.deepseek.com/v1/models",
           "base 已含 /v1 -> 请求 URL 精确为 https://api.deepseek.com/v1/models", requestedUrls.back());

        // base 已含 /v1/
        cfg.baseUrl = "https://api.deepseek.com/v1/";
        llm_models_fetch(cfg, 15000, true);
        ck(requestedUrls.back() == "https://api.deepseek.com/v1/models",
           "base 已含 /v1/ -> 请求 URL 精确为 https://api.deepseek.com/v1/models", requestedUrls.back());

        // 空 apiKey 快速失败且零网络
        std::atomic<int> emptyKeyCalls{0};
        cfg.apiKey = "";
        cfg.transport = [&](const std::string&, const std::string&, const std::vector<std::string>&) {
            ++emptyKeyCalls;
            rta::net::HttpResponse resp;
            resp.status = 200;
            return resp;
        };
        LlmModelList rEmpty = llm_models_fetch(cfg);
        ck(!rEmpty.ok, "空 apiKey 返回 ok=false");
        ck(rEmpty.error == "未配置 api_key（rlplayer-llm.conf）", "空 apiKey error 正确匹配", rEmpty.error);
        ck(emptyKeyCalls == 0, "空 apiKey 零网络请求 (mock 计数 == 0)");
    }

    // ---------------- 10) 状态码 0 与网络底层失败 ----------------
    std::printf("-- 10. 状态码 0 与网络底层失败 --\n");
    {
        llm_models_cache_clear();
        LlmConfig cfg;
        cfg.baseUrl = "https://api.deepseek.com";
        cfg.apiKey  = "sk-net-fail-key";
        cfg.transport = [&](const std::string&, const std::string&, const std::vector<std::string>&) {
            rta::net::HttpResponse resp;
            resp.status = 0;
            resp.error = "Connection refused";
            return resp;
        };
        LlmModelList res = llm_models_fetch(cfg, 15000, true);
        ck(!res.ok, "状态码 0 返回 ok=false");
        ck(res.error.find("网络请求失败: Connection refused") != std::string::npos,
           "状态码 0 给出可读网络错误", res.error);
    }

    // =====================================================================
    // 用户 261107：任意 OpenAI 兼容端点 + 模型清单多路径回退
    // =====================================================================

    // ---------------- 11) base 规整 ----------------
    std::printf("-- 11. base 规整（llm_normalize_base）--\n");
    {
        auto eq = [](const std::string& got, const char* want, const char* what) {
            ck(got == want, what, "got=[" + got + "] want=[" + want + "]");
        };
        eq(llm_normalize_base(""), "https://api.deepseek.com", "空串 → 默认端点");
        eq(llm_normalize_base("   "), "https://api.deepseek.com", "纯空白 → 默认端点");
        eq(llm_normalize_base("https://api.deepseek.com/"), "https://api.deepseek.com", "1 个尾斜杠被剥");
        eq(llm_normalize_base("https://api.deepseek.com///"), "https://api.deepseek.com", "多个尾斜杠全剥");
        eq(llm_normalize_base("  https://api.openai.com/v1/  "), "https://api.openai.com/v1",
           "trim + 尾斜杠，保留 /v1");
        eq(llm_normalize_base("api.openai.com/v1"), "https://api.openai.com/v1", "缺 scheme 自动补 https://");
        eq(llm_normalize_base("api.openai.com"), "https://api.openai.com", "只贴主机 → 补 scheme");
        eq(llm_normalize_base("https://api.deepseek.com/chat/completions"), "https://api.deepseek.com",
           "剥误粘的 /chat/completions");
        eq(llm_normalize_base("https://api.deepseek.com/v1/chat/completions"), "https://api.deepseek.com/v1",
           "剥 /chat/completions 且保留 /v1");
        eq(llm_normalize_base("https://api.deepseek.com/completions"), "https://api.deepseek.com",
           "剥误粘的 /completions");
        eq(llm_normalize_base("https://api.openai.com/v1/models"), "https://api.openai.com/v1",
           "剥误粘的 /models 且保留 /v1");
        eq(llm_normalize_base("https://api.deepseek.com/models/"), "https://api.deepseek.com",
           "尾斜杠与 /models 一起剥");
        const std::string degen = llm_normalize_base("https://");
        ck(degen == "https://" && degen != "https:", "退化的 https:// 不被剥成 https:", degen);
        const std::string degen2 = llm_normalize_base("http://");
        ck(degen2 == "http://", "退化的 http:// 原样保留", degen2);
        bool same = true;
        for (const char* in : {"", "https://api.deepseek.com/", "api.openai.com/v1",
                               "https://x.example/chat/completions"}) {
            same = same && (llm_base_url(in) == llm_normalize_base(in));
        }
        ck(same, "llm_base_url 与 llm_normalize_base 语义一致（旧名字向后兼容）");
    }

    // ---------------- 12) 候选列表与顺序 ----------------
    std::printf("-- 12. 候选列表（llm_base_candidates）--\n");
    {
        const std::vector<std::string> c1 = llm_base_candidates("https://api.gateway.example");
        ck(c1.size() == 2, "不带版本 → 2 条候选", std::to_string(c1.size()));
        ck(c1.size() == 2 && c1[0] == "https://api.gateway.example",
           "★ 第 1 条是不带版本的 base（顺序不能反）", c1.empty() ? std::string() : c1[0]);
        ck(c1.size() == 2 && c1[1] == "https://api.gateway.example/v1",
           "第 2 条是 /v1 兜底", c1.size() > 1 ? c1[1] : std::string());

        const std::vector<std::string> c2 = llm_base_candidates("https://api.deepseek.com/v1");
        ck(c2.size() == 1 && c2[0] == "https://api.deepseek.com/v1",
           "带 /v1 → 只有一条", c2.empty() ? std::string() : c2[0]);

        const std::vector<std::string> c3 = llm_base_candidates("https://api.deepseek.com/v1/");
        ck(c3.size() == 1 && c3[0] == "https://api.deepseek.com/v1",
           "带 /v1/ → 只有一条且先规整", c3.empty() ? std::string() : c3[0]);

        const std::vector<std::string> c4 = llm_base_candidates("https://gw.example/v1beta");
        ck(c4.size() == 1 && c4[0] == "https://gw.example/v1beta",
           "带 /v1beta → 只有一条", c4.empty() ? std::string() : c4[0]);

        // 空串 → 默认端点的两条候选
        const std::vector<std::string> c5 = llm_base_candidates("");
        ck(c5.size() == 2 && c5[0] == "https://api.deepseek.com" &&
           c5[1] == "https://api.deepseek.com/v1",
           "空串 → 默认端点 + /v1 两条", c5.size() == 2 ? c5[1] : std::string());
    }

    // ---------------- 13) models 多路径回退 ----------------
    std::printf("-- 13. models 多路径回退（/models 404 → /v1/models 200）--\n");
    {
        llm_models_cache_clear();
        llm_endpoint_cache_clear();
        std::atomic<int> calls{0};
        std::vector<std::string> urls;
        LlmConfig cfg;
        cfg.baseUrl = "https://api.fallback4411.example";
        cfg.apiKey  = "sk-fallback-models-key";
        cfg.transport = [&](const std::string& url, const std::string&,
                            const std::vector<std::string>&) {
            ++calls;
            urls.push_back(url);
            rta::net::HttpResponse resp;
            if (url == cfg.baseUrl + "/v1/models") {
                resp.status = 200;
                const std::string b = R"({"data":[{"id":"fallback-model"}]})";
                resp.body.assign(b.begin(), b.end());
            } else {
                resp.status = 404;
                const std::string b = R"({"error":{"message":"Not Found"}})";
                resp.body.assign(b.begin(), b.end());
            }
            return resp;
        };

        const LlmModelList r = llm_models_fetch(cfg);
        ck(r.ok, "第 1 条 404 后第 2 条 200 → ok", r.error);
        ck(r.has("fallback-model"), "回退后拿到模型列表内容");
        ck(r.modelsPath == "/v1/models", "modelsPath == /v1/models", r.modelsPath);
        ck(r.resolvedBase == cfg.baseUrl + "/v1", "resolvedBase 指向 /v1 候选", r.resolvedBase);
        ck(r.triedPaths.size() == 2, "triedPaths 记录 2 条", std::to_string(r.triedPaths.size()));
        ck(r.triedPaths.size() == 2 && r.triedPaths[0] == "/models" && r.triedPaths[1] == "/v1/models",
           "triedPaths 顺序 = 候选顺序");
        ck(calls == 2, "共发 2 次请求", std::to_string(calls.load()));
        ck(!urls.empty() && urls[0] == cfg.baseUrl + "/models",
           "第 1 次请求先打不带版本的 /models", urls.empty() ? std::string() : urls[0]);
    }

    // ---------------- 13b) 2xx 但报文不是模型列表 → 继续试下一条 ----------------
    std::printf("-- 13b. models 2xx 解析失败 → 试下一条候选 --\n");
    {
        llm_models_cache_clear();
        llm_endpoint_cache_clear();
        std::atomic<int> calls{0};
        LlmConfig cfg;
        cfg.baseUrl = "https://api.badbody4417.example";
        cfg.apiKey  = "sk-badbody-key";
        cfg.transport = [&](const std::string& url, const std::string&,
                            const std::vector<std::string>&) {
            ++calls;
            rta::net::HttpResponse resp;
            resp.status = 200;
            const std::string b = (url == cfg.baseUrl + "/v1/models")
                ? std::string(R"({"data":[{"id":"after-html"}]})")
                : std::string("<html>gateway error page</html>");
            resp.body.assign(b.begin(), b.end());
            return resp;
        };
        const LlmModelList r = llm_models_fetch(cfg);
        ck(r.ok && r.has("after-html"), "2xx 非法报文后回退到 /v1/models 成功", r.error);
        ck(r.modelsPath == "/v1/models", "modelsPath 记的是 /v1/models", r.modelsPath);
        ck(calls == 2, "解析失败也继续试下一条（2 次请求）", std::to_string(calls.load()));
    }

    // ---------------- 14) models 401 快速失败 ----------------
    std::printf("-- 14. models 401 快速失败（只发一次且不泄 key）--\n");
    {
        llm_models_cache_clear();
        const std::string k = "sk-auth-boom-key-5566778899";
        std::atomic<int> calls{0};
        LlmConfig cfg;
        cfg.baseUrl = "https://api.authfail4412.example";
        cfg.apiKey  = k;
        cfg.transport = [&](const std::string&, const std::string&,
                            const std::vector<std::string>&) {
            ++calls;
            rta::net::HttpResponse resp;
            resp.status = 401;
            const std::string b = "{\"error\":{\"message\":\"Invalid key: " + k + "\"}}";
            resp.body.assign(b.begin(), b.end());
            return resp;
        };
        const LlmModelList r = llm_models_fetch(cfg);
        ck(!r.ok, "401 → ok=false");
        ck(calls == 1, "★ 401 只发一次请求（不再试 /v1/models）", std::to_string(calls.load()));
        ck(r.triedPaths.size() == 1, "triedPaths 只有 1 条", std::to_string(r.triedPaths.size()));
        ck(r.error.find(k) == std::string::npos, "error 不含明文 key", r.error);
        ck(r.error.find("****") != std::string::npos, "error 里 key 已被 **** 遮盖", r.error);
    }

    // ---------------- 15) models 全失败：error 要带已尝试路径 ----------------
    std::printf("-- 15. models 两条候选都 404 --\n");
    {
        llm_models_cache_clear();
        std::atomic<int> calls{0};
        LlmConfig cfg;
        cfg.baseUrl = "https://api.all404-4413.example";
        cfg.apiKey  = "sk-all404-key";
        cfg.transport = [&](const std::string&, const std::string&,
                            const std::vector<std::string>&) {
            ++calls;
            rta::net::HttpResponse resp;
            resp.status = 404;
            const std::string b = R"({"error":{"message":"Not Found"}})";
            resp.body.assign(b.begin(), b.end());
            return resp;
        };
        const LlmModelList r = llm_models_fetch(cfg);
        ck(!r.ok, "两条候选都 404 → ok=false");
        ck(calls == 2, "两条候选都试过（2 次请求）", std::to_string(calls.load()));
        ck(r.error.find("已尝试") != std::string::npos, "error 明确写出「已尝试」", r.error);
        ck(r.error.find("/models") != std::string::npos, "error 含 /models", r.error);
        ck(r.error.find("/v1/models") != std::string::npos, "error 含 /v1/models", r.error);
    }

    // ---------------- 15b) 5xx 不换路径（既有纪律：服务端坏了再试另一条没意义） ----------------
    std::printf("-- 15b. models 500 不换路径 --\n");
    {
        llm_models_cache_clear();
        std::atomic<int> calls{0};
        LlmConfig cfg;
        cfg.baseUrl = "https://api.boom4418.example";
        cfg.apiKey  = "sk-500-key";
        cfg.transport = [&](const std::string&, const std::string&,
                            const std::vector<std::string>&) {
            ++calls;
            rta::net::HttpResponse resp;
            resp.status = 500;
            const std::string b = R"({"error":{"message":"Internal server error"}})";
            resp.body.assign(b.begin(), b.end());
            return resp;
        };
        const LlmModelList r = llm_models_fetch(cfg);
        ck(!r.ok, "500 → ok=false");
        ck(calls == 1, "500 只发一次请求（不换路径）", std::to_string(calls.load()));
        ck(r.triedPaths.size() == 1, "triedPaths 只有 1 条", std::to_string(r.triedPaths.size()));
    }

    // ---------------- 16) chat 回退且用量只记一次 ----------------
    std::printf("-- 16. chat 回退（/chat/completions 404 → /v1 200）且用量只增 1 --\n");
    {
        llm_endpoint_cache_clear();
        std::error_code uec;
        const std::string usagePath =
            (std::filesystem::temp_directory_path(uec) / "rta_llm_models_test" / "chat-usage.json").string();
        std::filesystem::remove(usagePath, uec);
        std::filesystem::remove(usagePath + ".bak", uec);   // 上一轮遗留的 .bak 会被误当成"主文件缺失，回退备份"

        std::atomic<int> calls{0};
        std::vector<std::string> urls;
        LlmConfig cfg;
        cfg.baseUrl = "https://api.chatfb4414.example";
        cfg.apiKey  = "sk-chat-fallback-key";
        cfg.model   = "gpt-4o-mini";
        cfg.monthOverride = "202610";
        cfg.usagePath = usagePath;
        cfg.transport = [&](const std::string& url, const std::string&,
                            const std::vector<std::string>&) {
            ++calls;
            urls.push_back(url);
            rta::net::HttpResponse resp;
            if (url == cfg.baseUrl + "/v1/chat/completions") {
                resp.status = 200;
                const std::string b =
                    R"({"choices":[{"message":{"content":"回退成功"}}],"usage":{"total_tokens":12}})";
                resp.body.assign(b.begin(), b.end());
            } else {
                resp.status = 404;
                const std::string b = R"({"error":{"message":"Not Found"}})";
                resp.body.assign(b.begin(), b.end());
            }
            return resp;
        };

        const int before = llm_get_monthly_count("202610", usagePath);
        const LlmReply r = llm_chat(cfg, {{"user", "hi"}});
        const int after = llm_get_monthly_count("202610", usagePath);

        ck(before == 0, "临时用量账本从 0 开始（上一轮残留已清理）", std::to_string(before));
        ck(r.ok && r.content == "回退成功", "第 1 条 404 后第 2 条 200 → chat 成功", r.error);
        ck(calls == 2, "共 2 次请求（先不带版本、再 /v1）", std::to_string(calls.load()));
        ck(!urls.empty() && urls[0] == cfg.baseUrl + "/chat/completions",
           "先试不带版本的 /chat/completions", urls.empty() ? std::string() : urls[0]);
        ck(urls.size() == 2 && urls[1] == cfg.baseUrl + "/v1/chat/completions",
           "回退到 /v1/chat/completions", urls.size() > 1 ? urls[1] : std::string());
        ck(after == before + 1, "★ 用量账本只增 1（回退不重复记账）",
           std::to_string(before) + " -> " + std::to_string(after));
    }

    // ---------------- 17) chat 401 不回退 ----------------
    std::printf("-- 17. chat 401 不回退（只发一次）--\n");
    {
        llm_endpoint_cache_clear();
        std::error_code uec;
        const std::string usagePath =
            (std::filesystem::temp_directory_path(uec) / "rta_llm_models_test" / "chat401-usage.json").string();
        std::filesystem::remove(usagePath, uec);
        std::filesystem::remove(usagePath + ".bak", uec);   // 上一轮遗留的 .bak 会被误当成"主文件缺失，回退备份"

        std::atomic<int> calls{0};
        LlmConfig cfg;
        cfg.baseUrl = "https://api.chat401-4415.example";
        cfg.apiKey  = "sk-chat-401-key";
        cfg.monthOverride = "202610";
        cfg.usagePath = usagePath;
        cfg.transport = [&](const std::string&, const std::string&,
                            const std::vector<std::string>&) {
            ++calls;
            rta::net::HttpResponse resp;
            resp.status = 401;
            const std::string b = R"({"error":{"message":"Unauthorized"}})";
            resp.body.assign(b.begin(), b.end());
            return resp;
        };
        const int before = llm_get_monthly_count("202610", usagePath);
        const LlmReply r = llm_chat(cfg, {{"user", "hi"}});
        const int after = llm_get_monthly_count("202610", usagePath);
        ck(!r.ok, "401 → ok=false");
        ck(calls == 1, "★ 401 只发一次请求（不换路径重试）", std::to_string(calls.load()));
        ck(r.error.find("HTTP 401") != std::string::npos, "错误含 HTTP 401", r.error);
        ck(after == before, "失败调用不计入用量", std::to_string(before) + " -> " + std::to_string(after));
    }

    // ---------------- 18) tools URL：base 带 /v1 不许拼出 /v1/v1 ----------------
    std::printf("-- 18. tools 接口 URL（llm_tools_base）--\n");
    {
        std::error_code uec;
        const std::string usagePath =
            (std::filesystem::temp_directory_path(uec) / "rta_llm_models_test" / "tools-usage.json").string();
        std::filesystem::remove(usagePath, uec);
        std::filesystem::remove(usagePath + ".bak", uec);   // 上一轮遗留的 .bak 会被误当成"主文件缺失，回退备份"

        std::vector<std::string> urls;
        LlmConfig cfg;
        cfg.apiKey = "sk-tools-url-key";
        cfg.monthOverride = "202610";
        cfg.usagePath = usagePath;
        cfg.transport = [&](const std::string& url, const std::string&,
                            const std::vector<std::string>&) {
            urls.push_back(url);
            rta::net::HttpResponse resp;
            resp.status = 200;
            const std::string b = (url.find("/tools/search") != std::string::npos)
                ? std::string(R"({"results":[]})")
                : std::string(R"({"title":"t","content":"c"})");
            resp.body.assign(b.begin(), b.end());
            return resp;
        };

        ck(llm_tools_base("https://api.deepseek.com") == "https://api.deepseek.com",
           "llm_tools_base：默认 base 逐字不变", llm_tools_base("https://api.deepseek.com"));
        ck(llm_tools_base("https://api.deepseek.com/v1") == "https://api.deepseek.com",
           "llm_tools_base：剥掉结尾 /v1", llm_tools_base("https://api.deepseek.com/v1"));
        ck(llm_tools_base("https://api.deepseek.com/v1beta") == "https://api.deepseek.com",
           "llm_tools_base：剥掉结尾 /v1beta", llm_tools_base("https://api.deepseek.com/v1beta"));

        cfg.baseUrl = "https://api.deepseek.com/v1";
        const DsSearchReply s = ds_search(cfg, "q");
        ck(s.ok, "base 带 /v1 的 search 成功", s.error);
        ck(!urls.empty() && urls.back() == "https://api.deepseek.com/v1/tools/search",
           "★ base 带 /v1 → search URL 恰为 https://api.deepseek.com/v1/tools/search（无 /v1/v1）",
           urls.empty() ? std::string() : urls.back());
        const DsFetchReply f = ds_fetch(cfg, "https://example.com");
        ck(f.ok, "base 带 /v1 的 fetch 成功", f.error);
        ck(!urls.empty() && urls.back() == "https://api.deepseek.com/v1/tools/fetch",
           "★ base 带 /v1 → fetch URL 恰为 https://api.deepseek.com/v1/tools/fetch（无 /v1/v1）",
           urls.empty() ? std::string() : urls.back());

        cfg.baseUrl = "https://api.deepseek.com";     // 回归护栏：默认 base 下的 URL 必须逐字不变
        ds_search(cfg, "q2");
        ck(!urls.empty() && urls.back() == "https://api.deepseek.com/v1/tools/search",
           "默认 base → search URL 逐字不变", urls.empty() ? std::string() : urls.back());

        cfg.baseUrl = "https://api.deepseek.com/v1/";
        ds_fetch(cfg, "https://example.com/2");
        ck(!urls.empty() && urls.back() == "https://api.deepseek.com/v1/tools/fetch",
           "base 带 /v1/ → 也不重复 /v1", urls.empty() ? std::string() : urls.back());
    }

    // ---------------- 19) 端点解析缓存 ----------------
    std::printf("-- 19. 端点解析缓存（命中直接用 / 清空后重新按候选顺序试）--\n");
    {
        llm_models_cache_clear();
        llm_endpoint_cache_clear();
        std::error_code uec;
        const std::string usagePath =
            (std::filesystem::temp_directory_path(uec) / "rta_llm_models_test" / "cache-usage.json").string();
        std::filesystem::remove(usagePath, uec);
        std::filesystem::remove(usagePath + ".bak", uec);   // 上一轮遗留的 .bak 会被误当成"主文件缺失，回退备份"

        std::atomic<int> modelCalls{0};
        std::atomic<int> chatCalls{0};
        std::vector<std::string> chatUrls;
        LlmConfig cfg;
        cfg.baseUrl = "https://api.cache4416.example";
        cfg.apiKey  = "sk-endpoint-cache-key";
        cfg.monthOverride = "202610";
        cfg.usagePath = usagePath;
        cfg.transport = [&](const std::string& url, const std::string&,
                            const std::vector<std::string>&) {
            rta::net::HttpResponse resp;
            const std::string v1 = cfg.baseUrl + "/v1";
            if (url == v1 + "/models") {
                ++modelCalls;
                resp.status = 200;
                const std::string b = R"({"data":[{"id":"m-cached"}]})";
                resp.body.assign(b.begin(), b.end());
            } else if (url == v1 + "/chat/completions") {
                ++chatCalls;
                chatUrls.push_back(url);
                resp.status = 200;
                const std::string b = R"({"choices":[{"message":{"content":"cached"}}]})";
                resp.body.assign(b.begin(), b.end());
            } else if (url == cfg.baseUrl + "/chat/completions") {
                ++chatCalls;
                chatUrls.push_back(url);
                resp.status = 404;
                const std::string b = R"({"error":{"message":"Not Found"}})";
                resp.body.assign(b.begin(), b.end());
            } else {
                resp.status = 404;
                const std::string b = R"({"error":{"message":"Not Found"}})";
                resp.body.assign(b.begin(), b.end());
            }
            return resp;
        };

        const LlmModelList ml = llm_models_fetch(cfg);
        ck(ml.ok && ml.modelsPath == "/v1/models",
           "models 试出 /v1/models（并写入端点解析缓存）", ml.error);

        // 缓存期内：chat 直接打解析出来的 base，不再吃一次 404
        const LlmReply c1 = llm_chat(cfg, {{"user", "a"}});
        ck(c1.ok, "chat 命中端点缓存后成功", c1.error);
        ck(chatCalls == 1, "★ 缓存期 chat 只发 1 次请求（不再探测不带版本的路径）",
           std::to_string(chatCalls.load()));
        ck(chatUrls.size() == 1 && chatUrls[0] == cfg.baseUrl + "/v1/chat/completions",
           "缓存期 chat 直接打 /v1/chat/completions",
           chatUrls.empty() ? std::string() : chatUrls[0]);

        // 清缓存：必须重新按候选顺序试（先不带版本 → 404 → /v1）
        llm_endpoint_cache_clear();
        const LlmReply c2 = llm_chat(cfg, {{"user", "b"}});
        ck(c2.ok, "清缓存后 chat 仍成功", c2.error);
        ck(chatCalls == 3, "★ 清缓存后重新按候选顺序试（1 + 2 = 3 次）",
           std::to_string(chatCalls.load()));
        ck(chatUrls.size() == 3 &&
           chatUrls[1] == cfg.baseUrl + "/chat/completions" &&
           chatUrls[2] == cfg.baseUrl + "/v1/chat/completions",
           "清缓存后的请求顺序 = 候选顺序",
           chatUrls.size() > 2 ? chatUrls[1] + " | " + chatUrls[2] : std::string());
    }

    std::printf("\n========================================\n");
    if (g_fail == 0) {
        std::printf("  全部用例通过！0 失败。\n");
        return 0;
    } else {
        std::printf("  存在 %d 处失败！\n", g_fail);
        return 1;
    }
}
