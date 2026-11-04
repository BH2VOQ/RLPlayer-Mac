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

#include "meta/llm.h"
#include <cstdio>
#include <string>
#include <vector>
#include <atomic>

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

    std::printf("\n========================================\n");
    if (g_fail == 0) {
        std::printf("  全部用例通过！0 失败。\n");
        return 0;
    } else {
        std::printf("  存在 %d 处失败！\n", g_fail);
        return 1;
    }
}
