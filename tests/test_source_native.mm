// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
// 真宿主/真 rlapp_core/真 WK transport；仅远程 Navidrome 是本机 HTTP fixture。
// 可选 argv[1] 是已有截图目录。不得定义 RL_WITH_UPDATE（本测试不验证更新服务）。
// 不 play、不模拟鼠标键盘、不安装 app；仅自有临时 HOME/状态/空音乐库。
#define main rlplayer_host_main
#include "../tools/mac_host.mm"
#undef main
#include "net/http_client.h"
#include "version.h"
#include "platform/path.h"
#include <atomic>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <functional>
#include <unistd.h>

static int failures = 0, checks = 0;
static void check(bool ok, const char* what) {
    ++checks;
    if (!ok) ++failures;
    std::printf("[%s] %s\n", ok ? "PASS" : "FAIL", what);
}
static bool until(const std::function<bool()>& pred, double seconds = 15) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!pred() && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return pred();
}
static id js(WKWebView* web, NSString* source) {
    __block bool done = false;
    __block id result = nil;
    [web evaluateJavaScript:source completionHandler:^(id value, NSError* error) {
        if (!error) result = value;
        done = true;
    }];
    bool (^finished)(void) = ^{ return done; };
    return until([&] { return finished(); }, 4) ? result : nil;
}
static bool truth(WKWebView* web, NSString* source) {
    id value = js(web, source);
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}
static std::string text(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), {});
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // 移植的真实 init 会扫描旧安装目录：仅允许 CMake build 路径，避免读真实旧配置。
        std::string module = rta::platform::module_dir_utf8();
        if (module.find("/build") == std::string::npos) {
            std::fprintf(stderr, "Run this test from a CMake build directory only.\n");
            return 2;
        }
        std::string output = argc > 1 ? std::filesystem::absolute(argv[1]).string() : "";
        if (!output.empty() && !std::filesystem::is_directory(output)) return 2;
        char pattern[] = "/tmp/rlplayer-source-native-XXXXXX", cwd[PATH_MAX];
        char* made = ::mkdtemp(pattern);
        if (!made || !::getcwd(cwd, sizeof(cwd))) return 2;
        const std::string root = made, state = root + "/state", lib = root + "/library";
        for (const auto& dir : {state, lib, root + "/music"}) std::filesystem::create_directories(dir);
        ::setenv("HOME", root.c_str(), 1);
        ::setenv("CFFIXED_USER_HOME", root.c_str(), 1);
        ::setenv("RLPLAYER_STATE_DIR", state.c_str(), 1);
        ::setenv("RLPLAYER_LIBRARY_DIR", lib.c_str(), 1);
        ::setenv("no_proxy", "127.0.0.1,localhost", 1);
        ::setenv("NO_PROXY", "127.0.0.1,localhost", 1);
        ::chdir(root.c_str()); // metabase 工作目录回退也必须隔离。
        std::atomic<int> indexes{0}, browse{0}, unexpected{0};
        rta::net::WebUi remote;
        const bool started = remote.start(0, [&](const rta::net::HttpRequest& req, std::string& ct) {
            ct = "application/json; charset=utf-8";
            if (req.path.rfind("/rest/getIndexes.view?", 0) == 0) {
                ++indexes;
                return std::string(R"({"subsonic-response":{"status":"ok","indexes":{"index":[{"artist":[{"id":"native-artist","name":"Native fixture artist"}]}]}}})");
            }
            if (req.path.rfind("/rest/getMusicDirectory.view?", 0) == 0 && req.path.find("id=native-artist") != std::string::npos) {
                ++browse;
                return std::string(R"({"subsonic-response":{"status":"ok","directory":{"child":[{"id":"native-track","title":"Native fixture track","suffix":"flac","isDir":false}]}}})");
            }
            ++unexpected; // 显式代理兜底捕获意外外网请求；绝不转发。
            return std::string(R"({"subsonic-response":{"status":"failed","error":{"message":"unexpected fixture request"}}})");
        }, true);
        check(started, "loopback WebUi port 0 started");
        if (!started) { ::chdir(cwd); std::filesystem::remove_all(root); return 1; }
        const std::string base = "http://127.0.0.1:" + std::to_string(remote.port());
        rta::net::set_http_proxy(base); // 非loopback请求只能进入本机拒绝桩，不能出网。
        const std::string secret = "native-fixture-secret-7391";
        const std::string conf = "version=2\nnextid=3\nactive=1\nsrv1.kind=subsonic\nsrv1.base=\nsrv1.user=\n"
            "srv2.kind=subsonic\nsrv2.base=" + base + "\nsrv2.user=fixture\nsrv2.pass=" + secret + "\n";
        const std::string confPath = state + "/rlplayer-sources.conf";
        std::ofstream(confPath) << conf;
        std::ofstream(lib + "/rlplayer-library.conf") << root + "/music\n";
        std::ofstream(state + "/rlplayer-settings.conf") << "backend=null\nmetaon=0\n";
        std::ofstream(state + "/rlplayer-llm.conf") << "proxy=" + base + "\n";
        NSApplication* app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app finishLaunching];
        HostAppDelegate* host = [[HostAppDelegate alloc] init];
        app.delegate = host;
        [host applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
        [host.exitPollTimer invalidate]; host.exitPollTimer = nil; // harness不能terminate提前exit。
        bool ready = until([&] { return truth(host.web, @"typeof setView==='function' && typeof loadRemote==='function' && !!document.getElementById('list')"); });
        check(ready, "real rlplayer://app document and app.js loaded");
        // 2026-10-28（用户「之前保存的无法删除」）：WKWebView 没有 UIDelegate 时
        // confirm() 恒返回 false ⟹ 删除/重置按钮静默失效。这里断言宿主真的挂上了
        // UIDelegate，并且实现了 confirm 回调（方法存在性用 respondsToSelector 证明）。
        check(host.web.UIDelegate == host, "web view has UIDelegate wired (JS confirm works)");
        check([host respondsToSelector:@selector(webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:)],
              "host implements runJavaScriptConfirmPanelWithMessage");
        if (ready) {
            check(truth(host.web, @"location.href==='rlplayer://app/' && document.documentElement.classList.contains('machost') && !!window.webkit.messageHandlers.rltransport"), "real native origin, shim and rltransport present");
            // evaluateJavaScript 不等待 Promise；把异步完成标记留在页面，再真实轮询。
            js(host.web, @"window.__nativeProbe={}; Promise.all([fetch('/api/src/config').then(r=>r.text()),fetch('/api/ping').then(r=>r.json())]).then(([t,p])=>{let c=JSON.parse(t);window.__nativeProbe={done:true,config:c.ok&&c.configured&&c.active==='2'&&c.servers.length===2&&!t.includes('native-fixture-secret-7391')&&!('pass' in c)&&c.servers.every(s=>!('pass' in s)),version:p.ok&&p.app==='RLPlayer'?p.version:''};}).catch(()=>{window.__nativeProbe={done:true};}); void 0;");
            check(until([&] { return truth(host.web, @"!!window.__nativeProbe.done"); }), "native fetch config/ping completed");
            check(truth(host.web, @"window.__nativeProbe.config===true"), "real config API recovers active2 without password echo");
            NSString* versionJS = [NSString stringWithFormat:@"window.__nativeProbe.version==='%s'", RLPLAYER_VERSION];
            check(truth(host.web, versionJS), "real ping API reports compiled product version");
            js(host.web, @"setView('remote');loadRemote('');void 0;");
            check(until([&] { return truth(host.web, @"!!Array.from(document.querySelectorAll('#list .rowdir .nm')).find(e=>e.textContent==='Native fixture artist'&&e.getBoundingClientRect().height>0)"); }), "remote DOM visibly renders fixture artist");
            check(indexes.load() > 0, "native transport reached real loopback indexes endpoint");
            check(truth(host.web, @"(()=>{let e=Array.from(document.querySelectorAll('#list .rowdir')).find(e=>e.querySelector('.nm')?.textContent==='Native fixture artist');if(!e)return false;e.click();return true;})()"), "directory DOM click dispatched without mouse input");
            // 2026-10-28：进入「全是曲目」的目录现在渲染成**专辑详情页**（用户要求），
            // 曲目在 .trow 表格里而不是 .row 行。判据跟着换选择器，但仍然证明同一件事：
            // 点目录之后真的看到了那首曲目，而且是在专辑详情页结构里（.ahead 头部存在）。
            check(until([&] { return truth(host.web, @"!!document.querySelector('#list .ahead') && !!Array.from(document.querySelectorAll('#list .trow .tt')).find(e=>e.textContent==='Native fixture track'&&e.getBoundingClientRect().height>0)"); }), "directory click visibly renders fixture track (album detail page)");
            check(browse.load() > 0, "native transport reached real loopback directory endpoint");
            if (!output.empty()) {
                __block bool captured = false, saved = false;
                NSString* file = [NSString stringWithUTF8String:(output + "/source-native.png").c_str()];
                [host.web takeSnapshotWithConfiguration:nil completionHandler:^(NSImage* image, NSError* error) {
                    if (image && !error) {
                        NSBitmapImageRep* bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
                        saved = [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:file atomically:YES];
                    }
                    captured = true;
                }];
                bool (^finished)(void) = ^{ return captured; };
                check(until([&] { return finished(); }, 5) && saved, "WKWebView PNG snapshot written");
            }
        }
        check(text(confPath) == conf, "native startup/browsing preserve original synthetic config bytes");
        // 导航空页销毁JS轮询，再停入站与核心；不走NSApplication terminate/_exit。
        [host.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]];
        check(until([&] { return !host.web.loading && [host.web.URL.absoluteString isEqualToString:@"about:blank"]; }, 5), "page polling stopped by about:blank navigation");
        rlapp::request_shutdown();
        bool drained = false;
        for (int i = 0; i < 100 && !drained; ++i) {
            drained = [host.schemeHandler waitForInFlightTasksWithTimeout:0.02];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        check(drained, "real scheme workers drained before core shutdown");
        rlapp::stop_embedded();
        host.web.navigationDelegate = nil;
        [host.web.configuration.userContentController removeAllScriptMessageHandlers];
        host.window.delegate = nil; app.delegate = nil; // 最后窗口关闭不可触发产品 terminate。
        [host.window close];
        // WKWebView 的拆除是跨进程异步的：真实产品随后就 terminate 退出，不会等到
        // HostAppDelegate/WKWebView 走完 ObjC dealloc。本 harness 若让局部强引用在 main 返回时
        // 释放，会在 autorelease pool 出栈处崩在 .cxx_destruct（实测 SIGSEGV，见 evidence）。
        // 因此**故意**把宿主保留到进程退出（与产品退出语义一致）；这是 harness 的所有权决定，
        // 不是生产泄漏 —— 全部断言统计已在下面照常打印，退出码仍按 failures 给出。
        static HostAppDelegate* g_keepAliveUntilExit = nil;
        g_keepAliveUntilExit = host;
        remote.stop();
        check(unexpected.load() == 0, "no unexpected request or external network proxy attempt");
        ::chdir(cwd);
        std::error_code ec;
        std::filesystem::remove_all(root, ec);
        check(!ec && !std::filesystem::exists(root), "owned temporary state and HOME removed");
        std::printf("Native source: %d assertions, %d failures\n", checks, failures);
        return failures ? 1 : 0;
    }
}
