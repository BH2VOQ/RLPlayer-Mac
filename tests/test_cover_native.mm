// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
// Opt-in real WKWebView + rlapp_core cover probe. No API mock, playback or input.
// Caller supplies isolated existing HOME/STATE/LIBRARY/COVER (all under /tmp).
// argv[1]: existing output directory; argv[2]: sample label (e.g. smb-cold).
// No configuration/cache deletion: the caller decides whether initial state is cold.
#define main rlplayer_host_main
#include "../tools/mac_host.mm"
#undef main
#include "platform/path.h"
#include <filesystem>
#include <functional>
#include <fstream>
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
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
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
    return until([&] { return finished(); }, 5) ? result : nil;
}
static bool truth(WKWebView* web, NSString* source) {
    id value = js(web, source);
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}
static bool isolatedDirectory(const char* name, std::string& out) {
    const char* raw = std::getenv(name);
    if (!raw || !*raw) return false;
    std::error_code ec;
    out = std::filesystem::canonical(raw, ec).string();
    return !ec && std::filesystem::is_directory(out) &&
        out.rfind("/private/tmp/", 0) == 0;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        std::string home, state, library, cover;
        if (!isolatedDirectory("HOME", home) ||
            !isolatedDirectory("RLPLAYER_STATE_DIR", state) ||
            !isolatedDirectory("RLPLAYER_LIBRARY_DIR", library) ||
            !isolatedDirectory("RLPLAYER_COVER_DIR", cover)) {
            std::fprintf(stderr, "Supply existing isolated HOME/STATE/LIBRARY/COVER directories under /tmp.\n");
            return 2;
        }
        if (rta::platform::module_dir_utf8().find("/build") == std::string::npos) {
            std::fprintf(stderr, "Run from a CMake build directory (avoid legacy install config migration).\n");
            return 2;
        }
        std::string output = argc > 1 ? std::filesystem::absolute(argv[1]).string() : "";
        if (!output.empty() && !std::filesystem::is_directory(output)) return 2;
        NSString* label = [NSString stringWithUTF8String:argc > 2 ? argv[2] : "unspecified-cache-state"];
        char cwd[PATH_MAX];
        if (!::getcwd(cwd, sizeof(cwd)) || ::chdir(home.c_str()) != 0) return 2;
        ::setenv("CFFIXED_USER_HOME", home.c_str(), 1);

        NSApplication* app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app finishLaunching];
        HostAppDelegate* host = [[HostAppDelegate alloc] init];
        app.delegate = host;
        [host applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
        [host.exitPollTimer invalidate]; host.exitPollTimer = nil;
        const bool ready = until([&] {
            return truth(host.web, @"location.href==='rlplayer://app/' && typeof coverImageLoad==='function' && !!window.webkit.messageHandlers.rltransport");
        }, 30);
        check(ready, "real native document, helper and RPC shim loaded");
        if (ready) {
            // Instrument only: forward every original fetch unchanged, record actual
            // WK transport statuses/header values and ping latency. No mock replies.
            js(host.web, @R"JS((function(){
              window.__coverProbe={done:false,phases:[],statuses:{},retryAfter:[],pings:[],errors:[]};
              const p=window.__coverProbe, original=window.fetch;
              window.fetch=function(){const args=arguments,t=performance.now();
                return original.apply(this,args).then(r=>{
                  const u=String(args[0]);
                  if(u.indexOf('/api/lib/cover?')>=0){p.statuses[r.status]=(p.statuses[r.status]||0)+1;
                    if(r.status===503)p.retryAfter.push(r.headers.get('Retry-After'));}
                  if(u==='/api/ping')p.pings.push(performance.now()-t);
                  return r;
                });
              };
              (async function(){
                const response=await fetch('/api/lib/albums');
                if(!response.ok)throw new Error('albums status '+response.status);
                const j=await response.json(), albums=(j.albums||[]).slice(0,60);
                p.albums=albums.length;
                if(albums.length!==60)throw new Error('need 60 albums, received '+albums.length);
                const old=document.getElementById('list'); if(old)old.remove();
                const panel=document.createElement('div');panel.id='native-cover-probe';
                panel.style.cssText='position:fixed;inset:0;z-index:99999;background:#181818;display:grid;grid-template-columns:repeat(10,1fr);gap:8px;padding:20px;overflow:auto';
                document.body.appendChild(panel);
                for(const phase of ['first','hot']){
                  panel.querySelectorAll('img').forEach(img=>{coverImageCancel(img);img.remove();});
                  const result={phase:phase,loaded:0,failed:0,elapsedMs:0};p.phases.push(result);
                  const start=performance.now(), ping=setInterval(()=>fetch('/api/ping').catch(e=>p.errors.push(String(e))),100);
                  try{
                    await Promise.all(albums.map(a=>new Promise(resolve=>{
                      const img=document.createElement('img');img.style.cssText='width:100%;aspect-ratio:1;object-fit:contain';
                      let settled=false;
                      function finish(ok){if(settled)return;settled=true;clearTimeout(timer);if(ok)++result.loaded;else ++result.failed;resolve();}
                      img.onload=()=>finish(img.naturalWidth>0);img.onerror=()=>finish(false);
                      const timer=setTimeout(()=>{coverImageCancel(img);finish(false);},120000);
                      panel.appendChild(img);coverImageLoad(img,a.cvUrl||('/api/lib/cover?k='+encodeURIComponent(a.k)));
                    })));
                  }finally{clearInterval(ping);result.elapsedMs=performance.now()-start;}
                }
                const missing=await fetch('/api/lib/cover?k=__native_probe_missing_album__');
                p.missingStatus=missing.status;p.missingRetry=missing.headers.get('Retry-After');
                const ok=await fetch('/api/ping');p.afterErrorStatus=ok.status;
                p.pingMaxMs=p.pings.length?Math.max.apply(null,p.pings):null;
                p.done=true;
              })().catch(e=>{p.errors.push(String(e));p.done=true;});
            })();void 0;)JS");
            check(until([&] { return truth(host.web, @"!!window.__coverProbe.done"); }, 260),
                  "60-cover first/hot native runs completed");
            check(truth(host.web, @"window.__coverProbe.albums===60"), "60 real albums selected");
            check(truth(host.web, @"window.__coverProbe.phases.length===2 && window.__coverProbe.phases.every(p=>p.loaded===60&&p.failed===0)"),
                  "all 60 images decode in both first/hot runs");
            check(truth(host.web, @"window.__coverProbe.retryAfter.every(v=>v==='2')"),
                  "every observed real native 503 carries Retry-After: 2 (count reported)");
            check(truth(host.web, @"window.__coverProbe.missingStatus===404 && !window.__coverProbe.missingRetry && window.__coverProbe.afterErrorStatus===200"),
                  "real cover404 stays404 and subsequent ping stays200");
            check(truth(host.web, @"window.__coverProbe.errors.length===0"), "no native fetch exceptions");
            check(truth(host.web, @"window.__coverProbe.pings.length>0"), "ping latency sampled during image loading");
            id json = js(host.web, @"JSON.stringify(window.__coverProbe)");
            NSString* report = [json isKindOfClass:[NSString class]] ? json : @"{}";
            std::printf("Native cover [%s]: %s\n", label.UTF8String, report.UTF8String);
            if (!output.empty()) {
                NSString* file = [NSString stringWithUTF8String:(output + "/cover-native.json").c_str()];
                check([report writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil], "native measurement JSON written");
                __block bool captured = false, saved = false;
                NSString* png = [NSString stringWithUTF8String:(output + "/cover-native.png").c_str()];
                [host.web takeSnapshotWithConfiguration:nil completionHandler:^(NSImage* image, NSError* error) {
                    if (image && !error) {
                        NSBitmapImageRep* bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
                        saved = [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:png atomically:YES];
                    }
                    captured = true;
                }];
                bool (^finished)(void) = ^{ return captured; };
                check(until([&] { return finished(); }, 5) && saved, "native cover PNG snapshot written");
            }
        }
        [host.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]];
        check(until([&] { return !host.web.loading && [host.web.URL.absoluteString isEqualToString:@"about:blank"]; }, 5),
              "page polling stopped before shutdown");
        rlapp::request_shutdown();
        bool drained = false;
        for (int i = 0; i < 100 && !drained; ++i) {
            drained = [host.schemeHandler waitForInFlightTasksWithTimeout:0.02];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        check(drained, "native workers drained before core shutdown");
        rlapp::stop_embedded();
        host.web.navigationDelegate = nil;
        [host.web.configuration.userContentController removeAllScriptMessageHandlers];
        host.window.delegate = nil; app.delegate = nil;
        [host.window close];
        // Same deliberate process-lifetime ownership as test_source_native:
        // asynchronous WebKit teardown must not outlive the test's host owner.
        static HostAppDelegate* keepAliveUntilExit = nil;
        keepAliveUntilExit = host;
        ::chdir(cwd);
        std::printf("Native cover: %d assertions, %d failures\n", checks, failures);
        return failures ? 1 : 0;
    }
}
