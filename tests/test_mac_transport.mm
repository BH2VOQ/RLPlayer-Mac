// test_mac_transport.mm — 单进程 transport 离线门禁
//
// 覆盖（与 tools/mac_host.mm 真实实现共用 ExtractRequestBody / HostMessage 表）：
//   1) /api/ping 响应契约
//   2) query + UTF-8 路径原样进入 dispatch
//   3) POST 原始二进制含 0x00 不截断，MIME 原样
//   4) 多请求并发（峰值在途 >= 2，证明没有全局请求锁）
//   5) HostMessage 9 条消息不回归
//   6) kShim 回归：必须含换行、不得含 "//" 行注释（2026-10-25 致命 BUG：
//      ObjC 相邻字面量拼接不插换行，第一条 // 注释把整段脚本吞成一行，导致
//      machost/webview2 类与 window.chrome.webview 垫片全部不执行）；
//      并在 JavaScriptCore 里**真实执行**一遍，证明 machost/webview2 已挂上、
//      postMessage 真的转发到 rlhost、DOMContentLoaded 兜底真的会再挂一次。
//
// 用 rlapp mock，不链接真实 rlapp_core：不初始化曲库、不触碰音频设备、不开窗口。
#define RL_TEST_RUNNER 1
#define GL_SILENCE_DEPRECATION 1

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <JavaScriptCore/JavaScriptCore.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <string>
#include <thread>
#include <vector>

#include "net/webui.h"

namespace rlapp {
static std::atomic<int> g_inFlight{0};
static std::atomic<int> g_maxInFlight{0};
static std::atomic<bool> g_exitReq{false};

bool start_embedded() { return true; }
void stop_embedded() {}
bool exit_requested() { return g_exitReq.load(); }

std::string dispatch(const rta::net::HttpRequest& req, std::string& ct) {
    const int cur = ++g_inFlight;
    int prev = g_maxInFlight.load();
    while (cur > prev && !g_maxInFlight.compare_exchange_weak(prev, cur)) {}
    std::string res;
    if (req.path == "/api/ping") {
        ct = "application/json; charset=utf-8";
        res = "{\"ok\":true,\"pong\":true}";
    } else if (req.path.rfind("/api/utf8_test", 0) == 0) {
        ct = "application/json; charset=utf-8";
        res = "{\"ok\":true,\"received_path\":\"" + req.path + "\"}";
    } else if (req.path == "/api/binary_echo") {
        ct = "application/octet-stream";
        res = req.body;                     // 原样回显，含 NUL
    } else if (req.path.rfind("/api/sleep_test", 0) == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        ct = "application/json; charset=utf-8";
        res = "{\"ok\":true}";
    } else {
        ct = "application/json; charset=utf-8";
        res = "{\"ok\":false,\"error\":\"not found\"}";
    }
    --g_inFlight;
    return res;
}
} // namespace rlapp

#include "../tools/mac_host.mm"

static int g_fail = 0;
static void ck(bool ok, const char* what, const std::string& detail = "") {
    if (ok) std::printf("  [PASS] %s\n", what);
    else { std::printf("  [FAIL] %s %s\n", what, detail.c_str()); ++g_fail; }
}

// ---------------------------------------------------------------------------
// kShim 回归辅助：JavaScriptCore 运行时加载
//
// ⚠️ 本测试目标（CMakeLists.txt:150）只链 "-framework AppKit" "-framework WebKit"，
//    而 CMakeLists.txt 不在本次改动的白名单内 ⟹ 不能新增 -framework JavaScriptCore。
//    实测：静态引用 JSContext 类会报 _OBJC_CLASS_$_JSContext 未定义（WebKit 不重导出它）。
//    因此这里**运行时 dlopen** 该 framework，再按名字取类；消息全部走 objc_msgSend，
//    编译期不产生任何 JavaScriptCore 符号引用。
// ---------------------------------------------------------------------------
static Class RLJSContextClass() {
    static dispatch_once_t once;
    static Class cls = Nil;
    dispatch_once(&once, ^{
        (void)dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
                     RTLD_NOW | RTLD_GLOBAL);
        cls = NSClassFromString(@"JSContext");
    });
    return cls;
}

// 在给定 JSContext 里求值；返回是否没有抛异常
static bool RLEvalJS(id ctx, NSString *src, std::string& errOut) {
    [ctx evaluateScript:src];
    id ex = [ctx exception];
    if (ex && ![ex isKindOfClass:[NSNull class]]) {
        id desc = [ex toString];
        errOut = desc ? [desc UTF8String] : "<unknown JS exception>";
        return false;
    }
    return true;
}

// 取全局变量，转成 std::string（失败返回空）
static std::string RLJSString(id ctx, NSString *expr) {
    id v = [ctx evaluateScript:expr];
    id s = [v toString];
    if (!s || [s isKindOfClass:[NSNull class]]) return "";
    const char *p = [s UTF8String];
    return p ? p : "";
}

int main() {
    @autoreleasepool {
        std::printf("=== mac transport 离线门禁 ===\n");

        // 1. /api/ping
        {
            rta::net::HttpRequest r; r.method = "GET"; r.path = "/api/ping";
            std::string ct;
            const std::string b = rlapp::dispatch(r, ct);
            ck(ct == "application/json; charset=utf-8", "/api/ping Content-Type");
            ck(b == "{\"ok\":true,\"pong\":true}", "/api/ping body");
        }

        // 2. query/UTF-8：与 startURLSchemeTask 同一段 percentEncodedPath + Query 拼接。
        {
            NSURL *u = [NSURL URLWithString:@"rlplayer://app/api/utf8_test%20dir?name=%E6%B5%8B%E8%AF%95&rate=96000"];
            NSURLComponents *comp = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
            NSString *rawPath = comp.percentEncodedPath;
            if (comp.percentEncodedQuery.length) rawPath = [rawPath stringByAppendingFormat:@"?%@", comp.percentEncodedQuery];
            std::string path([rawPath UTF8String]);
            ck(path == "/api/utf8_test%20dir?name=%E6%B5%8B%E8%AF%95&rate=96000",
               "percentEncodedPath + query 原样保留", path);
            rta::net::HttpRequest r; r.method = "GET"; r.path = path;
            std::string ct;
            const std::string b = rlapp::dispatch(r, ct);
            ck(b.find("name=%E6%B5%8B%E8%AF%95") != std::string::npos, "UTF-8 query 进入 dispatch", b);
        }

        // 3. 二进制 body（含 NUL）与 MIME
        {
            const unsigned char raw[16] = {0x50,0x4B,0x03,0x04,0x00,0x00,0xFF,0x00,
                                           0x12,0x34,0x00,0x56,0x78,0x9A,0x00,0xEF};
            NSData *data = [NSData dataWithBytes:raw length:sizeof(raw)];
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"rlplayer://app/api/binary_echo"]];
            req.HTTPMethod = @"POST"; req.HTTPBody = data;
            const std::string body = ExtractRequestBody(req);
            ck(body.size() == 16, "HTTPBody 保留 16 字节（无 NUL 截断）", std::to_string(body.size()));
            ck(std::memcmp(body.data(), raw, 16) == 0, "HTTPBody 字节一致");
            rta::net::HttpRequest r; r.method = "POST"; r.path = "/api/binary_echo"; r.body = body;
            std::string ct;
            const std::string out = rlapp::dispatch(r, ct);
            ck(ct == "application/octet-stream", "二进制 MIME 原样");
            ck(out.size() == 16 && std::memcmp(out.data(), raw, 16) == 0, "二进制响应含 NUL 且一致");
        }

        // 4. 并发：证明 dispatch 没被主控加全局串行锁
        {
            rlapp::g_maxInFlight.store(0);
            dispatch_group_t g = dispatch_group_create();
            for (int i = 0; i < 4; ++i) {
                dispatch_group_enter(g);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    rta::net::HttpRequest r; r.method = "GET"; r.path = "/api/sleep_test";
                    std::string ct; (void)rlapp::dispatch(r, ct);
                    dispatch_group_leave(g);
                });
            }
            dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
            ck(rlapp::g_maxInFlight.load() >= 2, "4 个请求并发（峰值 >= 2，非串行）",
               std::to_string(rlapp::g_maxInFlight.load()));
        }

        // 5. HostMessage 契约
        {
            using namespace rta::platform;
            ck(parse_host_message("min").action == HostAction::Minimize, "min");
            ck(parse_host_message("max").action == HostAction::Maximize, "max");
            ck(parse_host_message("close").action == HostAction::Close, "close");
            ck(parse_host_message("drag").action == HostAction::Drag, "drag");
            ck(parse_host_message("theme:dark").action == HostAction::Theme, "theme");
            ck(parse_host_message("resize:bottomright").action == HostAction::Resize, "resize");
            ck(parse_host_message("openurl:https://example.com").allowed, "openurl https 放行");
            ck(!parse_host_message("openurl:file:///etc/passwd").allowed, "openurl file 拒绝");
        }

        // 6. kShim 回归（2026-10-25 致命 BUG）
        //    BUG 现象：kShim 由相邻 ObjC 字面量拼接，拼接**不插换行**，而脚本里带
        //    `// …` 行注释 ⟹ 编译后整段 JS 变成一行，被第一条行注释全部吃掉。
        //    后果（实测）：documentElement 上没有 machost/webview2 ⟹ 页面隐藏窗口按钮与
        //    红绿灯安全区的 CSS 全部不命中；window.chrome.webview 垫片不存在 ⟹ 9 条宿主
        //    消息（min/max/close/drag/theme/openurl/resize）全失效。
        //    判据不是"看起来像"，而是：字符串形态 + 在 JavaScriptCore 里真执行一遍。
        {
            const std::string shim([kShim UTF8String]);

            // 6.1 必须含换行（否则所有 // 注释都会吞掉后续代码）
            ck(shim.find('\n') != std::string::npos, "kShim 含换行（不是单行拼接）",
               "newline count = " + std::to_string(std::count(shim.begin(), shim.end(), '\n')));

            // 6.2 不得含 "//"：一旦出现就说明有人又写回了行注释，整段脚本随时可能被吞。
            //     注意脚本里也不能有 URL / 除号误判——当前实现没有任何 "//"，这是硬约束。
            ck(shim.find("//") == std::string::npos, "kShim 不含 \"//\"（禁用行注释）",
               "first at offset " + std::to_string(shim.find("//")));

            // 6.3 括号配平自检（廉价的结构性证明：截断/吞行会立刻失衡）
            int paren = 0, brace = 0, brack = 0;
            bool inStr = false; char q = 0;
            bool okBalance = true;
            for (size_t i = 0; i < shim.size(); ++i) {
                char c = shim[i];
                if (inStr) {
                    if (c == '\\') { ++i; continue; }
                    if (c == q) inStr = false;
                    continue;
                }
                if (c == '\'' || c == '"') { inStr = true; q = c; continue; }
                if (c == '(') ++paren; else if (c == ')') { if (--paren < 0) okBalance = false; }
                else if (c == '{') ++brace; else if (c == '}') { if (--brace < 0) okBalance = false; }
                else if (c == '[') ++brack; else if (c == ']') { if (--brack < 0) okBalance = false; }
            }
            ck(okBalance && paren == 0 && brace == 0 && brack == 0,
               "kShim 括号配平（未被吞行/截断）",
               "() " + std::to_string(paren) + " {} " + std::to_string(brace) +
               " [] " + std::to_string(brack));

            // 6.4 JavaScriptCore 真执行：证明脚本语法完整且**真的生效**。
            //     用运行时 dlopen 拿 JSContext（测试目标只链 AppKit/WebKit，见文件头说明）。
            Class ctxCls = RLJSContextClass();
            ck(ctxCls != Nil, "JavaScriptCore 可用（运行时 dlopen）");
            if (ctxCls != Nil) {
                id ctx = [[ctxCls alloc] init];

                // 6.4.1 造一个最小 DOM/WebKit 环境，供 shim 打桩
                //       ⚠️ 必须自带 fetch / XMLHttpRequest / Blob / File 桩：
                //       纯 JavaScriptCore 里没有 DOM 的这些 API，缺了它们 shim 的
                //       `if (origFetch)` / `if (origXHR)` 分支会被整体跳过，
                //       断言就变成"没测到东西也 PASS"（铁律 3）。
                const char* bootstrap =
                    "var __msgs = [];"
                    "var __dcl = [];"
                    "var document = {"
                    "  documentElement: { classList: { __c: {},"
                    "      add: function() { for (var i = 0; i < arguments.length; i++) this.__c[arguments[i]] = 1; },"
                    "      contains: function(n) { return !!this.__c[n]; } } },"
                    "  addEventListener: function(t, fn) { if (t === 'DOMContentLoaded') __dcl.push(fn); }"
                    "};"
                    "var window = this;"
                    "window.webkit = { messageHandlers: {"
                    "  rlhost: { postMessage: function(m) { __msgs.push(String(m)); } },"
                    "  rltransport: { postMessage: function(p) { __msgs.push('transport:' + String(p.method));"
                    "                                             return Promise.resolve({ status: 200, body: 'ok' }); } }"
                    "} };"
                    "function Blob() {}"
                    "function File() {}"
                    "window.Blob = Blob; window.File = File;"
                    "var __origFetch = function(u, i) {"
                    "  return { catch: function(fn) { return 'orig-catch:' + String(u); } };"
                    "};"
                    "window.fetch = __origFetch;"
                    "function XMLHttpRequest() {}"
                    "var __origOpen = function(m, u) { this._m = m; };"
                    "var __origSend = function(b) { this._sent = b; };"
                    "XMLHttpRequest.prototype.open = __origOpen;"
                    "XMLHttpRequest.prototype.send = __origSend;"
                    "window.XMLHttpRequest = XMLHttpRequest;";
                std::string err;
                ck(RLEvalJS(ctx, [NSString stringWithUTF8String:bootstrap], err),
                   "JS 桩环境建立（document + webkit.messageHandlers + fetch/XHR/Blob）", err);

                // 6.4.2 语法 + 执行：吞行会让这段直接抛 SyntaxError，正是本回归要拦的
                err.clear();
                const bool ran = RLEvalJS(ctx, kShim, err);
                ck(ran, "kShim 在 JavaScriptCore 中语法完整且可执行", err);

                if (ran) {
                    // 6.4.3 machost + webview2 两个类必须都挂上（页面 CSS 全靠它们）
                    ck(RLJSString(ctx, @"String(document.documentElement.classList.contains('machost'))") == "true",
                       "kShim 挂上 machost 类");
                    ck(RLJSString(ctx, @"String(document.documentElement.classList.contains('webview2'))") == "true",
                       "kShim 挂上 webview2 类");

                    // 6.4.4 window.chrome.webview 垫片存在，且 postMessage 真的到 rlhost
                    ck(RLJSString(ctx, @"String(!!(window.chrome && window.chrome.webview && window.chrome.webview.postMessage))") == "true",
                       "kShim 建立 window.chrome.webview 垫片");
                    ck(RLJSString(ctx, @"(function(){ window.chrome.webview.postMessage('min'); return __msgs.join(','); })()") == "min",
                       "chrome.webview.postMessage 转发到 rlhost（消息不是空转）");

                    // 6.4.5 宿主 → UI 方向：__emit 必须派发到 addEventListener 注册的监听器
                    ck(RLJSString(ctx,
                        @"(function(){"
                        "  var got = '';"
                        "  window.chrome.webview.addEventListener('message', function(ev) { got = ev.data; });"
                        "  window.chrome.webview.__emit('max');"
                        "  return got;"
                        "})()") == "max",
                       "chrome.webview.__emit 派发到 message 监听器");

                    // 6.4.6 DOMContentLoaded 兜底：清掉类名后触发监听器，必须重新挂上
                    ck(RLJSString(ctx,
                        @"(function(){"
                        "  document.documentElement.classList.__c = {};"
                        "  for (var i = 0; i < __dcl.length; i++) __dcl[i]();"
                        "  return String(document.documentElement.classList.contains('machost') &&"
                        "                document.documentElement.classList.contains('webview2'));"
                        "})()") == "true",
                       "DOMContentLoaded 兜底再次挂上 machost + webview2",
                       "listeners = " + RLJSString(ctx, @"String(__dcl.length)"));

                    // 6.4.7 fetch / XHR 包装：必须证明**确实替换过**（而不是原始桩还留着）。
                    //       只断言 typeof === 'function' 会在包装分支被跳过时假通过。
                    ck(RLJSString(ctx, @"String(window.fetch !== __origFetch)") == "true",
                       "kShim 替换了 window.fetch（不是原始桩）");
                    ck(RLJSString(ctx, @"String(window.XMLHttpRequest.prototype.send !== __origSend)") == "true",
                       "kShim 替换了 XHR.prototype.send（Blob 上传走 rltransport）");
                    ck(RLJSString(ctx, @"String(window.XMLHttpRequest.prototype.open !== __origOpen)") == "true",
                       "kShim 替换了 XHR.prototype.open（记录 method/url 供转发用）");

                    // 6.4.8 非 Blob 的普通 fetch 必须**原样透传**给原实现，不能被垫片吞掉。
                    //       __origFetch 返回带 catch 的对象并回传 url ⟹ 断言能证明
                    //       "垫片走到了 origFetch.apply 且参数原样"。
                    ck(RLJSString(ctx, @"String(window.fetch('/api/ping'))") == "orig-catch:/api/ping",
                       "普通 fetch 原样透传给原实现（参数未被改写）",
                       RLJSString(ctx, @"String(window.fetch('/api/ping'))"));
                }

                // 6.4.9 ⚠️ 最关键的时序场景：**documentStart 时 documentElement 还不存在**。
                //       WKUserScriptInjectionTimeAtDocumentStart 注入时，documentElement
                //       完全可能是 null（页面还没开始解析）。若 shim 直接
                //       `document.documentElement.classList.add(...)` 就会抛 TypeError，
                //       后面的 window.chrome.webview 垫片**全部不执行** —— 与吞行 BUG 同症状。
                //       这正是任务要求"监听 DOMContentLoaded 再兜底一次"的原因，
                //       所以必须用一个**全新的干净上下文**从 null 状态起跑，而不是复用上面那个。
                {
                    id ctx2 = [[ctxCls alloc] init];
                    const char* bootstrapNull =
                        "var __msgs = [];"
                        "var __dcl = [];"
                        "var document = {"
                        "  documentElement: null,"      // ← 关键：模拟 documentStart
                        "  addEventListener: function(t, fn) { if (t === 'DOMContentLoaded') __dcl.push(fn); }"
                        "};"
                        "var window = this;"
                        "window.webkit = { messageHandlers: {"
                        "  rlhost: { postMessage: function(m) { __msgs.push(String(m)); } },"
                        "  rltransport: { postMessage: function(p) { return Promise.resolve({status:200,body:'ok'}); } }"
                        "} };"
                        "function Blob() {} function File() {}"
                        "window.Blob = Blob; window.File = File;"
                        "window.fetch = function(u) { return { catch: function() { return 'orig'; } }; };"
                        "function XMLHttpRequest() {}"
                        "XMLHttpRequest.prototype.open = function() {};"
                        "XMLHttpRequest.prototype.send = function() {};"
                        "window.XMLHttpRequest = XMLHttpRequest;";
                    std::string err2;
                    ck(RLEvalJS(ctx2, [NSString stringWithUTF8String:bootstrapNull], err2),
                       "null-documentElement 桩环境建立", err2);

                    err2.clear();
                    const bool ranNull = RLEvalJS(ctx2, kShim, err2);
                    ck(ranNull, "documentElement=null 时 kShim 不抛异常（注入时机安全）", err2);

                    // 即便 documentElement 还没有，DOMContentLoaded 监听也必须已注册
                    ck(RLJSString(ctx2, @"String(__dcl.length)") == "1",
                       "documentElement=null 时仍注册了 DOMContentLoaded 兜底",
                       "listeners = " + RLJSString(ctx2, @"String(__dcl.length)"));

                    // 垫片不能因为 DOM 没就绪就丢掉（消息通道必须立刻可用）
                    ck(RLJSString(ctx2, @"String(!!(window.chrome && window.chrome.webview))") == "true",
                       "documentElement=null 时 window.chrome.webview 仍已建立");

                    // 然后 DOM 就绪 → 触发 DOMContentLoaded → 两个类必须挂上
                    ck(RLJSString(ctx2,
                        @"(function(){"
                        "  document.documentElement = { classList: { __c: {},"
                        "    add: function() { for (var i = 0; i < arguments.length; i++) this.__c[arguments[i]] = 1; },"
                        "    contains: function(n) { return !!this.__c[n]; } } };"
                        "  for (var i = 0; i < __dcl.length; i++) __dcl[i]();"
                        "  return String(document.documentElement.classList.contains('machost') &&"
                        "                document.documentElement.classList.contains('webview2'));"
                        "})()") == "true",
                       "DOM 就绪后兜底挂上 machost + webview2（documentStart 晚挂场景）");

                    // 消息通道在晚挂场景下也必须真能发出去
                    ck(RLJSString(ctx2,
                        @"(function(){ window.chrome.webview.postMessage('max'); return __msgs.join(','); })()") == "max",
                       "documentElement=null 场景下 postMessage 仍转发到 rlhost");
                }
            }
        }

        std::printf("=== %d 项失败 ===\n", g_fail);
    }
    return g_fail == 0 ? 0 : 1;
}
