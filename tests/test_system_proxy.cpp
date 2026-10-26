// test_system_proxy.cpp — 「有代理走代理、没代理直连」的判据（2026-10-26）
//
// 为什么要有这条测试（铁律 3：先问"这个指标真能证明我要证明的事吗"）：
//   用户真机症状是「检查更新永远报网络不可用」。根因是 macOS 上 libcurl **不读系统代理**，
//   而 .app 双击启动时环境里没有 http_proxy/https_proxy ⟹ 系统代理开着也照样直连。
//   所以这里要证明的是**选择逻辑本身**，不是"本机现在能不能上网"：
//     · 系统没开代理  ⟹ 必须返回空串（= 直连，改造前行为不变，不许强行塞代理）
//     · 系统开了代理  ⟹ 必须返回 host:port，且 https 请求用 HTTPSProxy、http 请求用 HTTPProxy
//     · 端口非法/主机为空 ⟹ 必须返回空串（配了但不完整 ≠ 可以瞎猜默认端口）
//     · 非 http(s) scheme ⟹ 不代理
//
// ⚠️ 这条测试**不依赖本机是否真的开着代理**（那是环境的属性，不是代码的属性）。
//    它把 read_system_proxy() 的结果当作输入喂给纯函数 pick_proxy_for_url，
//    所以无论在有代理还是没代理的机器上都能跑出确定的结论。
//
// 另有一条**真机联调**（run_live_probe）：打印本机实际读到的系统代理，供人工核对。
// 它不参与 pass/fail —— 因为"本机没开代理"不该算代码失败。

#include "platform/http.h"

#include <cstdio>
#include <string>

static int g_fail = 0;
static void ck(bool cond, const std::string& what, const std::string& detail = "") {
    std::printf("  [%s] %s%s%s\n", cond ? "PASS" : "FAIL", what.c_str(),
                detail.empty() ? "" : "  ⟶ ", detail.c_str());
    if (!cond) ++g_fail;
}

int main() {
    std::printf("=== 1. 系统没开代理 ⟹ 直连（改造前行为必须保持不变）===\n");
    {
        rta::platform::SystemProxySettings none;      // 全默认 = 没开代理
        ck(rta::platform::pick_proxy_for_url(none, "https://raw.githubusercontent.com/a/b").empty(),
           "全关 ⟹ https 直连");
        ck(rta::platform::pick_proxy_for_url(none, "http://example.com/a").empty(),
           "全关 ⟹ http 直连");
    }

    std::printf("\n=== 2. 系统开了代理 ⟹ 自动走代理（本次修复的核心）===\n");
    {
        rta::platform::SystemProxySettings s;
        s.httpEnabled = true;   s.httpHost = "127.0.0.1";   s.httpPort = 7897;
        s.httpsEnabled = true;  s.httpsHost = "127.0.0.1";  s.httpsPort = 7897;

        ck(rta::platform::pick_proxy_for_url(s, "https://raw.githubusercontent.com/BH2VOQ/x") == "127.0.0.1:7897",
           "https 请求 ⟹ 用 HTTPSProxy", rta::platform::pick_proxy_for_url(s, "https://raw.githubusercontent.com/x"));
        ck(rta::platform::pick_proxy_for_url(s, "http://example.com/x") == "127.0.0.1:7897",
           "http 请求 ⟹ 用 HTTPProxy");
        // scheme 大小写不敏感：URL 里出现 HTTPS:// 也必须认
        ck(rta::platform::pick_proxy_for_url(s, "HTTPS://raw.githubusercontent.com/x") == "127.0.0.1:7897",
           "scheme 大小写不敏感");
    }

    std::printf("\n=== 3. http/https 各自独立（不许拿错端口）===\n");
    {
        rta::platform::SystemProxySettings s;
        s.httpEnabled = true;   s.httpHost = "10.0.0.9";  s.httpPort = 3128;
        s.httpsEnabled = true;  s.httpsHost = "127.0.0.1"; s.httpsPort = 7897;
        ck(rta::platform::pick_proxy_for_url(s, "https://a.com/x") == "127.0.0.1:7897",
           "https 用 7897");
        ck(rta::platform::pick_proxy_for_url(s, "http://a.com/x") == "10.0.0.9:3128",
           "http 用 3128");
    }

    std::printf("\n=== 4. 配了但不完整/非法 ⟹ 直连（不猜默认端口）===\n");
    {
        rta::platform::SystemProxySettings noPort;
        noPort.httpsEnabled = true; noPort.httpsHost = "127.0.0.1"; noPort.httpsPort = 0;
        ck(rta::platform::pick_proxy_for_url(noPort, "https://a.com/x").empty(),
           "有主机没端口 ⟹ 直连");

        rta::platform::SystemProxySettings badPort;
        badPort.httpsEnabled = true; badPort.httpsHost = "127.0.0.1"; badPort.httpsPort = 70000;
        ck(rta::platform::pick_proxy_for_url(badPort, "https://a.com/x").empty(),
           "端口越界 ⟹ 直连");

        rta::platform::SystemProxySettings noHost;
        noHost.httpsEnabled = true; noHost.httpsHost = ""; noHost.httpsPort = 7897;
        ck(rta::platform::pick_proxy_for_url(noHost, "https://a.com/x").empty(),
           "开了但没主机 ⟹ 直连");

        rta::platform::SystemProxySettings off;
        off.httpsEnabled = false; off.httpsHost = "127.0.0.1"; off.httpsPort = 7897;
        ck(rta::platform::pick_proxy_for_url(off, "https://a.com/x").empty(),
           "主机端口都在但开关关着 ⟹ 直连");
    }

    std::printf("\n=== 5. 非 http(s) scheme 不代理 ===\n");
    {
        rta::platform::SystemProxySettings s;
        s.httpEnabled = true; s.httpHost = "127.0.0.1"; s.httpPort = 7897;
        s.httpsEnabled = true; s.httpsHost = "127.0.0.1"; s.httpsPort = 7897;
        ck(rta::platform::pick_proxy_for_url(s, "ftp://a.com/x").empty(), "ftp ⟹ 不代理");
        ck(rta::platform::pick_proxy_for_url(s, "file:///etc/passwd").empty(), "file ⟹ 不代理");
        ck(rta::platform::pick_proxy_for_url(s, "").empty(), "空 URL ⟹ 不代理");
    }

    std::printf("\n=== 6. 真机联调（只打印，不参与判定）===\n");
    {
        // read_system_proxy 在 platform/macos/http_posix.h 的 detail 命名空间里，
        // 这里通过一个公开的探测入口拿结果 —— 见 http.h 底部的 system_proxy_snapshot()。
        const rta::platform::SystemProxySettings s = rta::platform::system_proxy_snapshot();
        std::printf("  本机 HTTP  代理: %s %s:%d\n", s.httpEnabled ? "开" : "关",
                    s.httpHost.c_str(), s.httpPort);
        std::printf("  本机 HTTPS 代理: %s %s:%d\n", s.httpsEnabled ? "开" : "关",
                    s.httpsHost.c_str(), s.httpsPort);
        std::printf("  本机 例外表    : %s\n", s.exceptions.empty() ? "(空)" : s.exceptions.c_str());
        const std::string picked =
            rta::platform::pick_proxy_for_url(s, "https://raw.githubusercontent.com/BH2VOQ/RLPlayer-Mac/main/latest.json");
        std::printf("  清单请求会走    : %s\n", picked.empty() ? "直连" : picked.c_str());
        ck(true, "真机联调信息已打印（不判定，避免把'本机没开代理'算成代码失败）");
    }

    std::printf("\n=== 汇总：%s ===\n", g_fail == 0 ? "全部通过" : "有失败");
    return g_fail == 0 ? 0 : 1;
}
