// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_search_endpoints.cpp — 1.1.4-beta4 联网检索端点（纯离线单测）
//
// 判据说明（铁律 3：测试通过 ≠ 测对了东西）：
//   本文件只测 src/meta/llm.h 新增的端点纯函数 —— provider 归一化 / URL 拼装 /
//   请求体构造 / 响应解析 / 认证头 / config 读写往返，全部是内存字符串运算与
//   临时文件，**零网络、零真实第三方响应**。写死的报文取自 2026-11-07 公开文档；
//   真机联调（尤其 AnySearch /v1/extract 正文字段名）由用户最后一次性实测负责。
//   本测试不证明「第三方端点真能连通」，只证明「按文档构造与解析的契约正确」。
//
// 三条硬判据（默认行为等价，保证既有 137 条测试不回归）：
//   ① provider=deepseek（默认/空/未知）时一切分派回落到旧函数，URL/body 逐字不变；
//   ② 第三方 search 结果映射到 DsHit 且过既有 filter_hits 的数值闸（白名单仍是主闸）；
//   ③ keyless（searchKey 空）时不带认证头、不因 apiKey 空报错、URL 不含 key。
#include "meta/llm.h"
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using namespace rta::meta;

static int g_pass = 0;
static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = std::string()) {
    if (cond) { std::printf("  [PASS] %s\n", what.c_str()); ++g_pass; }
    else { std::printf("  [FAIL] %s  %s\n", what.c_str(), detail.c_str()); ++g_fail; }
}

// mock transport：记录最后一次请求的 (url, body, headers)，返回写死报文，绝不联网。
struct Capture {
    std::string url, body, bodyOut;
    std::vector<std::string> headers;
    int status = 200;
};
static Capture g_cap;

static rta::net::HttpResponse fakePost(const std::string& url, const std::string& body,
                                       const std::vector<std::string>& headers) {
    g_cap.url = url; g_cap.body = body; g_cap.headers = headers;
    rta::net::HttpResponse r;
    r.status = g_cap.status;
    const std::string& s = g_cap.bodyOut;
    r.body.assign(s.begin(), s.end());
    return r;
}

static bool hasHeader(const std::vector<std::string>& h, const std::string& needle) {
    for (const auto& x : h) if (x.find(needle) != std::string::npos) return true;
    return false;
}

int main() {
    std::printf("== 1.1.4-beta4 联网检索端点（纯离线）==\n");

    // -- 1) provider 归一化：只认三种，其余回落 deepseek --------------------
    std::printf("-- 1) provider 归一化 --\n");
    ck(ds_provider_norm("") == "deepseek", "空 = deepseek（默认）");
    ck(ds_provider_norm("deepseek") == "deepseek", "deepseek 原样");
    ck(ds_provider_norm("AnySearch") == "anysearch", "大小写/空格归一 anysearch");
    ck(ds_provider_norm(" TAVILY ") == "tavily", "tavily 去空格");
    ck(ds_provider_norm("google") == "deepseek", "未知 provider 回落 deepseek（不会误发第三方）");
    {
        LlmConfig c;
        ck(!ds_is_external(c), "默认 LlmConfig 是内部(deepseek)路径");
        c.searchProvider = "tavily";
        ck(ds_is_external(c), "searchProvider=tavily 走外部路径");
    }

    // -- 2) URL：host-only 收敛 + 各厂商固定路径 + 自定义 base --------------
    std::printf("-- 2) 端点 URL --\n");
    {
        LlmConfig c; c.searchProvider = "anysearch";
        ck(ds_search_url(c, "anysearch") == "https://api.anysearch.com/v1/search",
           "AnySearch 默认 search URL", ds_search_url(c, "anysearch"));
        ck(ds_fetch_url(c, "anysearch") == "https://api.anysearch.com/v1/extract",
           "AnySearch 默认 fetch URL", ds_fetch_url(c, "anysearch"));
        c.searchBaseUrl = "https://gw.example.com/v1/";   // 带 /v1 和尾斜杠
        ck(ds_search_url(c, "anysearch") == "https://gw.example.com/v1/search",
           "自定义 base 收敛到 host 再拼路径（不会 /v1/v1/search）", ds_search_url(c, "anysearch"));
        LlmConfig t; t.searchProvider = "tavily";
        ck(ds_search_url(t, "tavily") == "https://api.tavily.com/search", "Tavily 默认 search URL");
        ck(ds_fetch_url(t, "tavily") == "https://api.tavily.com/extract", "Tavily 默认 fetch URL");
        LlmConfig s; s.searchProvider = "tavily"; s.searchBaseUrl = "my.proxy.local";
        ck(ds_search_url(s, "tavily") == "https://my.proxy.local/search", "无 scheme 自动补 https");
    }

    // -- 3) 请求体：字段/转义/clamp；key 只进 body 或 header，绝不进 URL ----
    std::printf("-- 3) 请求体构造 --\n");
    {
        LlmConfig d;  // deepseek
        ck(ds_build_search_body_for(d, "deepseek", "晴天", 5) == ds_build_search_body("晴天", 5),
           "deepseek search body 逐字等于旧函数（零回归）");
        ck(ds_build_fetch_body_for(d, "deepseek", "https://x") == ds_build_fetch_body("https://x"),
           "deepseek fetch body 逐字等于旧函数（零回归）");

        LlmConfig a; a.searchProvider = "anysearch";
        ck(ds_build_search_body_for(a, "anysearch", "周杰伦 晴天", 5) ==
           "{\"query\":\"周杰伦 晴天\",\"max_results\":5}", "AnySearch search body 字段正确");
        ck(ds_build_fetch_body_for(a, "anysearch", "https://x/y") == "{\"url\":\"https://x/y\"}",
           "AnySearch extract body 是单 url 对象");
        ck(ds_build_search_body_for(a, "anysearch", "q", 999) ==
           "{\"query\":\"q\",\"max_results\":10}", "max_results 上限 clamp 到 10");
        ck(ds_build_search_body_for(a, "anysearch", "q", 0) ==
           "{\"query\":\"q\",\"max_results\":1}", "max_results 下限 clamp 到 1");
        ck(ds_build_search_body_for(a, "anysearch", "a\"b\\c", 3) ==
           "{\"query\":\"a\\\"b\\\\c\",\"max_results\":3}", "query 中的引号/反斜杠正确转义");

        LlmConfig t; t.searchProvider = "tavily"; t.searchKey = "tvly-SECRET";
        const std::string tb = ds_build_search_body_for(t, "tavily", "q", 3);
        ck(tb.find("\"api_key\":\"tvly-SECRET\"") != std::string::npos, "Tavily search body 带 api_key");
        ck(tb.find("\"query\":\"q\"") != std::string::npos && tb.find("\"max_results\":3") != std::string::npos,
           "Tavily search body 有 query/max_results");
        ck(ds_build_fetch_body_for(t, "tavily", "https://x") ==
           "{\"urls\":[\"https://x\"],\"api_key\":\"tvly-SECRET\"}",
           "Tavily extract body 用 urls 数组 + api_key");
        // keyless：key 为空时 body 里不能有 api_key
        t.searchKey.clear();
        ck(ds_build_search_body_for(t, "tavily", "q", 3).find("api_key") == std::string::npos,
           "keyless Tavily search body 不含 api_key");
    }

    // -- 4) 认证头 + secret：deepseek 用 apiKey，第三方用 searchKey --------
    std::printf("-- 4) 认证头 / redact secret --\n");
    {
        LlmConfig d; d.apiKey = "sk-DEEP";
        const auto dh = ds_headers_for(d, "deepseek");
        ck(dh.size() == 1 && dh[0] == "Authorization: Bearer sk-DEEP", "deepseek 用 apiKey Bearer");
        ck(ds_secret_of(d, "deepseek") == "sk-DEEP", "deepseek secret = apiKey");

        LlmConfig a; a.searchProvider = "anysearch"; a.apiKey = "sk-DEEP"; a.searchKey = "as-KEY";
        const auto ah = ds_headers_for(a, "anysearch");
        ck(ah.size() == 1 && ah[0] == "Authorization: Bearer as-KEY", "anysearch 用 searchKey Bearer");
        ck(ds_secret_of(a, "anysearch") == "as-KEY", "anysearch secret = searchKey（不是 apiKey）");
        a.searchKey.clear();
        ck(ds_headers_for(a, "anysearch").empty(), "keyless anysearch 不带认证头");
        LlmConfig t; t.searchProvider = "tavily"; t.searchKey = "tvly-KEY";
        ck(ds_headers_for(t, "tavily").empty(), "tavily 认证走 body，头部为空");
    }

    // -- 5) search 响应解析：deepseek 不变 + anysearch + tavily ------------
    std::printf("-- 5) search 响应解析 --\n");
    {
        const std::string ds = "{\"results\":[{\"title\":\"T\",\"url\":\"https://x\",\"snippet\":\"S\","
            "\"summary\":\"M\",\"rerank_score\":2.5,\"authority\":3,\"date\":\"2024\"}]}";
        DsSearchReply a = ds_parse_external_search("deepseek", ds);
        DsSearchReply b = ds_parse_search_response(ds);
        ck(a.ok == b.ok && a.hits.size() == b.hits.size() &&
           a.hits[0].rerankScore == 2.5 && a.hits[0].authority == 3,
           "deepseek 解析逐字复用旧函数（零回归）");

        DsSearchReply as = ds_parse_external_search("anysearch",
            "{\"code\":0,\"message\":\"success\",\"data\":{\"results\":["
            "{\"title\":\"晴天\",\"url\":\"https://zh.wikipedia.org/wiki/晴天\",\"snippet\":\"周杰伦\","
            "\"content\":\"2003 年发行\"}]}}");
        ck(as.ok && as.hits.size() == 1, "AnySearch 成功解析 1 条");
        ck(as.hits[0].title == "晴天" && as.hits[0].url.find("wikipedia") != std::string::npos,
           "AnySearch title/url 映射正确");
        ck(as.hits[0].snippet == "周杰伦" && as.hits[0].summary == "2003 年发行",
           "AnySearch snippet←snippet / summary←content 映射正确");
        ck(as.hits[0].rerankScore >= 0.8 && as.hits[0].authority >= 2,
           "第三方命中过既有 filter_hits 数值闸（白名单仍是主闸）");
        DsSearchReply emptyAs = ds_parse_external_search("anysearch",
            "{\"code\":0,\"message\":\"success\",\"data\":{\"results\":[]}}");
        ck(emptyAs.ok && emptyAs.hits.empty(), "AnySearch 0 命中是合法空结果（ok=true）");
        DsSearchReply errAs = ds_parse_external_search("anysearch",
            "{\"code\":1001,\"message\":\"rate limited\",\"data\":{}}");
        ck(!errAs.ok && errAs.error.find("rate limited") != std::string::npos,
           "AnySearch code!=0 → 业务错误带 message");

        DsSearchReply tv = ds_parse_external_search("tavily",
            "{\"results\":[{\"title\":\"ZARD\",\"url\":\"https://discogs.com/x\","
            "\"content\":\"Japanese rock band\",\"score\":0.95}]}");
        ck(tv.ok && tv.hits.size() == 1 && tv.hits[0].summary == "Japanese rock band",
           "Tavily content 同时作 snippet/summary");
        ck(tv.hits[0].rerankScore >= 0.8 && tv.hits[0].authority >= 2,
           "Tavily 命中过数值闸（score 0~1 与闸 0.8 不同量纲，已归一化）");
        DsSearchReply bad = ds_parse_external_search("tavily", "not json");
        ck(!bad.ok, "非法 JSON → 解析失败（不假绿）");
        DsSearchReply noRes = ds_parse_external_search("tavily", "{}");
        ck(!noRes.ok, "缺 results → 解析失败（不假绿）");
    }

    // -- 6) fetch/extract 响应解析 ----------------------------------------
    std::printf("-- 6) fetch/extract 响应解析 --\n");
    {
        DsFetchReply d = ds_parse_external_fetch("deepseek", "{\"title\":\"T\",\"content\":\"C\"}");
        DsFetchReply d2 = ds_parse_fetch_response("{\"title\":\"T\",\"content\":\"C\"}");
        ck(d.ok == d2.ok && d.content == d2.content, "deepseek fetch 解析复用旧函数（零回归）");

        // AnySearch extract：正文多候选键（字段名未定，取第一个非空）
        DsFetchReply a = ds_parse_external_fetch("anysearch",
            "{\"url\":\"https://x\",\"title\":\"标题\",\"content\":\"正文内容\"}");
        ck(a.ok && a.content == "正文内容" && a.title == "标题", "AnySearch extract 顶层 content/title");
        DsFetchReply a2 = ds_parse_external_fetch("anysearch",
            "{\"code\":0,\"data\":{\"url\":\"https://x\",\"markdown\":\"MD 正文\"}}");
        ck(a2.ok && a2.content == "MD 正文", "AnySearch extract data.markdown 多候选键命中");
        DsFetchReply a3 = ds_parse_external_fetch("anysearch",
            "{\"code\":0,\"data\":{\"url\":\"https://x\"}}");
        ck(!a3.ok, "AnySearch extract 无正文 → 失败（不假绿）");

        DsFetchReply t = ds_parse_external_fetch("tavily",
            "{\"results\":[{\"url\":\"https://x\",\"raw_content\":\"页面正文\"}],\"failed_results\":[]}");
        ck(t.ok && t.content == "页面正文", "Tavily extract results[0].raw_content");
        DsFetchReply tf = ds_parse_external_fetch("tavily",
            "{\"results\":[],\"failed_results\":[{\"url\":\"https://x\",\"error\":\"blocked\"}]}");
        ck(!tf.ok && tf.error.find("blocked") != std::string::npos,
           "Tavily extract failed_results → 错误带原因");
    }

    // -- 7) 早返回分派：外部走 mock transport，deepseek 不受影响 -----------
    std::printf("-- 7) ds_search/ds_fetch 端点分派（mock transport）--\n");
    {
        LlmConfig a; a.searchProvider = "anysearch"; a.searchKey = "as-KEY";
        a.transport = fakePost;
        g_cap.bodyOut = "{\"code\":0,\"data\":{\"results\":[{\"title\":\"T\",\"url\":\"https://zh.wikipedia.org/a\",\"snippet\":\"s\",\"content\":\"c\"}]}}";
        g_cap.status = 200;
        DsSearchReply r = ds_search(a, "query", 5);
        ck(r.ok && r.hits.size() == 1, "外部 ds_search 走 transport 且解析成功");
        ck(g_cap.url == "https://api.anysearch.com/v1/search", "外部请求打到 AnySearch /v1/search", g_cap.url);
        ck(g_cap.body.find("\"query\":\"query\"") != std::string::npos, "分派后 body 用第三方字段");
        ck(g_cap.url.find("as-KEY") == std::string::npos, "key 不进 URL");
        ck(!hasHeader(g_cap.headers, "sk-") , "外部请求不带 DeepSeek apiKey");
        ck(hasHeader(g_cap.headers, "as-KEY"), "anysearch 请求带 searchKey Bearer");

        g_cap.bodyOut = "{\"url\":\"https://x\",\"content\":\"页面\"}";
        DsFetchReply f = ds_fetch(a, "https://x", 10000);
        ck(f.ok && f.content == "页面", "外部 ds_fetch 走 /v1/extract 且解析成功");
        ck(g_cap.url == "https://api.anysearch.com/v1/extract", "外部 fetch 打到 /v1/extract", g_cap.url);

        // keyless 且 apiKey 为空：不能报「未配置 api_key」
        LlmConfig k; k.searchProvider = "tavily"; k.apiKey.clear(); k.searchKey.clear();
        k.transport = fakePost;
        g_cap.bodyOut = "{\"results\":[]}"; g_cap.status = 200;
        DsSearchReply kr = ds_search(k, "q");
        ck(kr.ok, "keyless 第三方（apiKey 空）不报未配置 api_key");
        ck(g_cap.headers.empty(), "keyless 请求无任何认证头");
    }

    // -- 8) config load/save/merge 往返（临时文件）------------------------
    std::printf("-- 8) config 读写往返 --\n");
    {
        const std::string path = "/tmp/b4_llm_test.conf";
        std::remove(path.c_str());
        LlmConfig c;
        c.apiKey = "sk-DEEP"; c.model = "m";
        c.searchProvider = "tavily"; c.searchBaseUrl = "https://gw.example.com"; c.searchKey = "tvly-K";
        ck(llm_config_save(c, path), "llm_config_save 写成功");
        LlmConfig g = llm_config_load(path);
        ck(g.searchProvider == "tavily" && g.searchBaseUrl == "https://gw.example.com" && g.searchKey == "tvly-K",
           "load 读回 3 个新字段");
        ck(g.apiKey == "sk-DEEP" && g.model == "m", "load 旧字段不受影响");
        // merge：保留 proxy= 行和注释，替换新字段，切回 deepseek 时清掉新字段行
        {
            std::ofstream f(path, std::ios::binary | std::ios::trunc);
            f << "# 注释\nproxy=127.0.0.1:7890\nbase_url=https://api.deepseek.com\n"
              << "api_key=sk-OLD\nmodel=old\nsearch_provider=tavily\n"
              << "search_base_url=https://old.gw\nsearch_key=oldK\n";
        }
        LlmConfig back; back.apiKey = "sk-NEW"; back.model = "new"; back.searchProvider = "deepseek";
        ck(llm_config_save_merge(back, path), "llm_config_save_merge 写成功");
        LlmConfig m = llm_config_load(path);
        ck(m.searchProvider == "deepseek", "merge 切回 deepseek 后不再带第三方字段");
        ck(m.apiKey == "sk-NEW" && m.model == "new", "merge 替换旧字段");
        std::ifstream in(path); std::string all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        ck(all.find("proxy=127.0.0.1:7890") != std::string::npos, "merge 保留 proxy= 行");
        ck(all.find("# 注释") != std::string::npos, "merge 保留注释");
        ck(all.find("oldK") == std::string::npos, "merge 清除旧的第三方 key 行");
        std::remove(path.c_str());
    }

    std::printf("\nRESULT: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail > 0 ? 1 : 0;
}
