// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// test_startup_native.mm — 原生冷启动逐帧测试 harness
//
// 目标与规范：
// 1. 复用真实 HostAppDelegate + rlapp_core + rlplayer:// scheme，不走端口，不启动独立子进程；
// 2. 隔离 HOME / CFFIXED_USER_HOME / STATE / LIB / COVER / TMP，空曲库、禁用元数据，backend=null 绝不出声；
// 3. 支持 --theme dark|light|blue 启动主题测试，通过 localStorage 预种与 WebKit 隔离实现可信冷启动；
// 4. 采样窗口创建 -> 首次可见 -> DOM 加载 -> 主题应用 -> 稳定就绪 各阶段的真实窗口图像；
// 5. 图像捕获采用梯级能力：优先 ScreenCaptureKit / WindowServer CGWindowListCreateImage，
//    若只能走 WK takeSnapshot 则如实标明 "proves_native_first_frame: false"（绝不假通过，铁律 3）；
// 6. 输出结构化时间线 JSON 与每帧 PNG 到 --output 目录；
// 7. 标准输出打印确定性就绪、PID 与 Window ID 信息，便于主控/Cua 截取真实桌面窗口。

#define RL_TEST_RUNNER 1
#define main rlplayer_host_main_unused

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "../tools/mac_host.mm"
#undef main

#include "version.h"
#include "platform/path.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>
#include <unistd.h>

// ---------------------------------------------------------------------------
// 结构体与辅助类型
// ---------------------------------------------------------------------------
struct PixelSample {
    double r = 0, g = 0, b = 0, a = 1;
    std::string hex = "#000000";
    std::string classification = "unknown"; // dark_bg, light_white, blue_tint, transparent, intermediate
};

struct FrameRecord {
    int index = 0;
    std::string stage;
    long long timestamp_ms = 0;
    long long elapsed_ms = 0;
    std::string capture_method; // screencapturekit, cg_window_list, appkit_cache_display, wk_snapshot, none
    bool proves_native_first_frame = false;
    std::string png_path;
    std::string relative_png;
    size_t width = 0;
    size_t height = 0;
    PixelSample pixel_center;
    PixelSample pixel_corner;
    std::string notes;
};

struct StartupTimeline {
    std::string theme = "dark";
    std::string data_store_mode = "persistent_preseeded";
    pid_t pid = 0;
    uint32_t window_id = 0;
    NSRect window_bounds = NSZeroRect;
    long long t0_epoch_ms = 0;
    long long t_window_created_ms = 0;
    long long t_window_visible_ms = 0;
    long long t_head_parsed_ms = 0;
    long long t_dom_ready_ms = 0;
    long long t_theme_applied_ms = 0;
    long long t_stable_idle_ms = 0;
    std::vector<FrameRecord> frames;
    bool screencapturekit_available = false;
    bool cg_window_list_available = false;
    bool wk_snapshot_available = false;
    bool native_first_frame_proven = false;
    std::string final_theme_detected;
    bool theme_matches_expected = false;
    bool assertions_passed = false;
};

// ---------------------------------------------------------------------------
// 派生宿主委托：支持可选 nonPersistentDataStore 模式与 DocumentStart 预种
// ---------------------------------------------------------------------------
@interface StartupHarnessAppDelegate : HostAppDelegate
@property (nonatomic, copy) NSString *harnessTheme;
@property (nonatomic, assign) BOOL forceNonPersistent;
@end

@implementation StartupHarnessAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    if (!self.forceNonPersistent) {
        [super applicationDidFinishLaunching:n];
        return;
    }
    // 非持久化独立模式：复用真实宿主核心与 scheme，但采用 nonPersistentDataStore
    if (!rlapp::start_embedded()) {
        std::fprintf(stderr, "StartupHarness: rlapp::start_embedded() failed\n");
        return;
    }
    [self buildMenu];

    NSRect frame = NSMakeRect(0, 0, 1180, 760);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                    NSWindowStyleMaskFullSizeContentView
                            backing:NSBackingStoreBuffered defer:NO];
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.titlebarAppearsTransparent = YES;
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.backgroundColor = [NSColor colorWithSRGBRed:22.0/255 green:22.0/255 blue:24.0/255 alpha:1.0];
    self.window.minSize = NSMakeSize(600, 400);
    [self.window center];
    self.window.delegate = self;

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"rlplayer.main.toolbar"];
    toolbar.showsBaselineSeparator = NO;
    self.window.toolbar = toolbar;
    if (@available(macOS 11.0, *)) {
        self.window.toolbarStyle = NSWindowToolbarStyleUnified;
    }

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];

    self.schemeHandler = [[RLURLSchemeHandler alloc] init];
    [cfg setURLSchemeHandler:self.schemeHandler forURLScheme:@"rlplayer"];

    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:kShim
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:YES]];
    if (self.harnessTheme.length > 0) {
        NSString *seedJS = [NSString stringWithFormat:
            @"try { localStorage.setItem('rta-theme', '%@'); localStorage.setItem('rta-uistyle', 'apple'); } catch(e){}",
            self.harnessTheme];
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:seedJS
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:YES]];
    }
    [ucc addScriptMessageHandler:self name:@"rlhost"];

    self.transportHandler = [[RLTransportHandler alloc] init];
    [ucc addScriptMessageHandlerWithReply:self.transportHandler
                             contentWorld:[WKContentWorld pageWorld]
                                     name:@"rltransport"];
    cfg.userContentController = ucc;

    self.web = [[WKWebView alloc] initWithFrame:frame configuration:cfg];
    self.web.navigationDelegate = self;
    if (@available(macOS 12.0, *)) self.web.underPageBackgroundColor = self.window.backgroundColor;
    self.web.UIDelegate = self;
    self.web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window setContentView:self.web];

    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"rlplayer://app/"]]];
    [self.window makeKeyAndOrderFront:nil];
}

@end

// ---------------------------------------------------------------------------
// 辅助函数
// ---------------------------------------------------------------------------
static long long now_ms() {
    return (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (char c : s) {
        if (c == '"') out += "\\\"";
        else if (c == '\\') out += "\\\\";
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else out += c;
    }
    return out;
}

static bool runloop_until(const std::function<bool()>& pred, double timeout_sec = 10.0) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_sec];
    while (!pred() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return pred();
}

static id evaluate_js(WKWebView* web, NSString* source, double timeout_sec = 2.0) {
    __block bool done = false;
    __block id result = nil;
    [web evaluateJavaScript:source completionHandler:^(id val, NSError* err) {
        if (!err) result = val;
        done = true;
    }];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_sec];
    while (!done && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return done ? result : nil;
}

static bool js_truth(WKWebView* web, NSString* source) {
    id val = evaluate_js(web, source);
    return [val respondsToSelector:@selector(boolValue)] && [val boolValue];
}

static std::string js_string(WKWebView* web, NSString* source) {
    id val = evaluate_js(web, source);
    if ([val isKindOfClass:[NSString class]]) {
        return [(NSString*)val UTF8String];
    }
    return "";
}

// ---------------------------------------------------------------------------
// 像素采样与颜色分析
// ---------------------------------------------------------------------------
static PixelSample inspect_cgimage_pixel(CGImageRef image, int x, int y) {
    PixelSample p;
    if (!image) return p;
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0) return p;
    if (x < 0 || (size_t)x >= width) x = (int)width / 2;
    if (y < 0 || (size_t)y >= height) y = (int)height / 2;

    uint8_t rgba[4] = {0, 0, 0, 0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!colorSpace) return p;
    CGContextRef ctx = CGBitmapContextCreate(
        rgba, 1, 1, 8, 4, colorSpace,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(-x, -(int)(height - 1 - y), width, height), image);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(colorSpace);

    p.r = rgba[0] / 255.0;
    p.g = rgba[1] / 255.0;
    p.b = rgba[2] / 255.0;
    p.a = rgba[3] / 255.0;

    char hexbuf[16];
    std::snprintf(hexbuf, sizeof(hexbuf), "#%02x%02x%02x", rgba[0], rgba[1], rgba[2]);
    p.hex = hexbuf;

    if (p.a < 0.1) {
        p.classification = "transparent";
    } else if (p.r > 0.90 && p.g > 0.90 && p.b > 0.90) {
        p.classification = "light_white";
    } else if (p.b > p.r + 0.04 && p.b > 0.70) {
        p.classification = "blue_tint";
    } else if (p.r < 0.25 && p.g < 0.25 && p.b < 0.25) {
        p.classification = "dark_bg";
    } else {
        p.classification = "intermediate";
    }
    return p;
}

static bool save_cgimage_png(CGImageRef image, const std::string& path) {
    if (!image) return false;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
    if (!dest) return false;
    CGImageDestinationAddImage(dest, image, nullptr);
    bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok;
}

// ---------------------------------------------------------------------------
// 梯级窗口图像捕获：ScreenCaptureKit -> CGWindowList -> AppKit -> WKWebView
// ---------------------------------------------------------------------------
struct CaptureAttempt {
    CGImageRef image = nullptr;
    std::string method;
    bool proves_native_first_frame = false;
    std::string notes;
};

static CGImageRef capture_screencapturekit_window(CGWindowID winId, CGRect bounds, double timeout_sec = 0.4) {
    if (@available(macOS 14.0, *)) {
        __block bool finished = false;
        __block CGImageRef captured = nil;
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                  onScreenWindowsOnly:NO
                                                    completionHandler:^(SCShareableContent *content, NSError *err) {
            if (!err && content) {
                SCWindow *target = nil;
                for (SCWindow *w in content.windows) {
                    if (w.windowID == winId) {
                        target = w;
                        break;
                    }
                }
                if (target) {
                    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];
                    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
                    cfg.width = bounds.size.width > 0 ? (size_t)bounds.size.width : (size_t)target.frame.size.width;
                    cfg.height = bounds.size.height > 0 ? (size_t)bounds.size.height : (size_t)target.frame.size.height;
                    cfg.showsCursor = NO;
                    [SCScreenshotManager captureImageWithFilter:filter
                                                  configuration:cfg
                                              completionHandler:^(CGImageRef img, NSError *sErr) {
                        if (img && !sErr) {
                            captured = CGImageRetain(img);
                        }
                        finished = true;
                    }];
                    return;
                }
            }
            finished = true;
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_sec];
        while (!finished && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        return captured;
    }
    return nil;
}

static CGImageRef capture_cgwindowlist_window(CGWindowID winId, CGRect bounds) {
    if (winId == 0) return nil;
    CGImageRef img = CGWindowListCreateImage(
        bounds,
        kCGWindowListOptionIncludingWindow,
        winId,
        kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution
    );
    return img;
}

static CGImageRef capture_appkit_view_hierarchy(NSWindow *win) {
    if (!win || !win.contentView) return nil;
    NSView *view = win.contentView;
    NSRect r = view.bounds;
    if (r.size.width <= 0 || r.size.height <= 0) return nil;
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:r];
    if (!rep) return nil;
    [view cacheDisplayInRect:r toBitmapImageRep:rep];
    return [rep CGImage];
}

static CGImageRef capture_wk_snapshot(WKWebView *web, double timeout_sec = 0.5) {
    if (!web) return nil;
    __block bool finished = false;
    __block CGImageRef captured = nil;
    [web takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image, NSError *error) {
        if (image && !error) {
            NSData *tiff = [image TIFFRepresentation];
            if (tiff) {
                NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
                if (rep && [rep CGImage]) {
                    captured = CGImageRetain([rep CGImage]);
                }
            }
        }
        finished = true;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_sec];
    while (!finished && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return captured;
}

static CaptureAttempt capture_window_frame(NSWindow *win, WKWebView *web, CGWindowID winId, CGRect bounds) {
    CaptureAttempt res;
    // 1. 梯级 1：ScreenCaptureKit（macOS 14+ 原生合成器窗口流截图，最高真实度）
    res.image = capture_screencapturekit_window(winId, bounds, 0.4);
    if (res.image && CGImageGetWidth(res.image) > 0) {
        res.method = "screencapturekit";
        res.proves_native_first_frame = true;
        res.notes = "True WindowServer composited window frame via ScreenCaptureKit";
        return res;
    }
    if (res.image) { CGImageRelease(res.image); res.image = nullptr; }

    // 2. 梯级 2：CGWindowListCreateImage（WindowServer 原生窗口抓取）
    res.image = capture_cgwindowlist_window(winId, bounds);
    if (res.image && CGImageGetWidth(res.image) > 0 && CGImageGetHeight(res.image) > 0) {
        res.method = "cg_window_list";
        res.proves_native_first_frame = true;
        res.notes = "Native WindowServer window image via CGWindowListCreateImage";
        return res;
    }
    if (res.image) { CGImageRelease(res.image); res.image = nullptr; }

    // 3. 梯级 3：AppKit 进程内视图光栅化（反映 AppKit 树与 underPageBackgroundColor，但非 WindowServer 合成）
    CGImageRef appkitImg = capture_appkit_view_hierarchy(win);
    if (appkitImg && CGImageGetWidth(appkitImg) > 0) {
        res.image = CGImageRetain(appkitImg);
        res.method = "appkit_cache_display";
        res.proves_native_first_frame = false;
        res.notes = "In-process NSView cacheDisplayInRect; proves view hierarchy paint, but not compositor frame";
        return res;
    }

    // 4. 梯级 4：WKWebView takeSnapshot（WebKit 离屏渲染截图；根据铁律 3 绝不谎报证明原生首帧）
    res.image = capture_wk_snapshot(web, 0.5);
    if (res.image && CGImageGetWidth(res.image) > 0) {
        res.method = "wk_snapshot";
        res.proves_native_first_frame = false;
        res.notes = "WK takeSnapshot reflects WebContent process rendering only; does NOT prove WindowServer native prepaint";
        return res;
    }

    res.method = "none";
    res.proves_native_first_frame = false;
    res.notes = "All capture rungs unavailable (no ScreenCaptureKit/CGWindowList/AppKit/WK capture)";
    return res;
}

// ---------------------------------------------------------------------------
// 预种函数：在隔离的 WebKit 数据存储中写入目标主题，模拟真实持久冷启动
// ---------------------------------------------------------------------------
static bool preseed_localstorage(const std::string& theme, const std::string& uistyle = "apple") {
    @autoreleasepool {
        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        RLURLSchemeHandler *handler = [[RLURLSchemeHandler alloc] init];
        [cfg setURLSchemeHandler:handler forURLScheme:@"rlplayer"];
        WKWebView *web = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200) configuration:cfg];
        [web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"rlplayer://app/"]]];

        __block bool done = false;
        __block bool success = false;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4.0];
        while (!done && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            [web evaluateJavaScript:[NSString stringWithFormat:
                @"try { localStorage.setItem('rta-theme', '%s'); localStorage.setItem('rta-uistyle', '%s'); true; } catch(e) { false; }",
                theme.c_str(), uistyle.c_str()]
                  completionHandler:^(id res, NSError *err) {
                if (!err && [res respondsToSelector:@selector(boolValue)] && [res boolValue]) {
                    success = true;
                    done = true;
                }
            }];
        }
        [web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]];
        NSDate *drainUntil = [NSDate dateWithTimeIntervalSinceNow:0.2];
        while (drainUntil.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        [handler waitForInFlightTasksWithTimeout:0.2];
        web.navigationDelegate = nil;
        return success;
    }
}

// ---------------------------------------------------------------------------
// 命令行参数
// ---------------------------------------------------------------------------
struct CmdOptions {
    std::string theme = "dark";
    std::string output_dir = "/tmp/rlplayer-startup-evidence";
    int max_samples = 10;
    int sample_interval_ms = 40;
    int hold_ms = 400;
    bool non_persistent = false;
    bool regular_activation = false;
    bool print_json = false;
};

static void print_usage(const char* prog) {
    std::printf(
        "Usage: %s [options]\n"
        "RLPlayer Native Startup Frame-by-Frame Test Harness\n\n"
        "Options:\n"
        "  --theme <dark|light|blue>    Target startup theme (default: dark)\n"
        "  --output <dir>               Directory for PNG frames and timeline.json (default: /tmp/rlplayer-startup-evidence)\n"
        "  --samples <N>                Maximum frame samples across startup (default: 10, range: 3-30)\n"
        "  --interval-ms <ms>           Sampling interval between frames in ms (default: 40)\n"
        "  --hold-ms <ms>               Hold time at stable state before teardown (default: 400)\n"
        "  --non-persistent             Use in-memory nonPersistentDataStore + DocumentStart injection\n"
        "  --regular-activation         Activate as regular app (default: accessory to preserve focus)\n"
        "  --json                       Print JSON timeline to stdout on completion\n"
        "  --help, -h                   Show this help message\n\n"
        "Examples:\n"
        "  %s --theme light --output /tmp/startup-light --hold-ms 800\n"
        "  %s --theme blue --output /tmp/startup-blue\n",
        prog, prog, prog
    );
}

static bool parse_options(int argc, const char* argv[], CmdOptions& opt) {
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--theme" && i + 1 < argc) {
            opt.theme = argv[++i];
            if (opt.theme != "dark" && opt.theme != "light" && opt.theme != "blue") {
                std::fprintf(stderr, "Error: Invalid theme '%s'. Allowed: dark, light, blue.\n", opt.theme.c_str());
                return false;
            }
        } else if (arg == "--output" && i + 1 < argc) {
            opt.output_dir = argv[++i];
        } else if (arg == "--samples" && i + 1 < argc) {
            opt.max_samples = std::clamp(std::atoi(argv[++i]), 3, 50);
        } else if (arg == "--interval-ms" && i + 1 < argc) {
            opt.sample_interval_ms = std::clamp(std::atoi(argv[++i]), 10, 500);
        } else if (arg == "--hold-ms" && i + 1 < argc) {
            opt.hold_ms = std::clamp(std::atoi(argv[++i]), 0, 10000);
        } else if (arg == "--non-persistent") {
            opt.non_persistent = true;
        } else if (arg == "--regular-activation") {
            opt.regular_activation = true;
        } else if (arg == "--json") {
            opt.print_json = true;
        } else if (arg == "--help" || arg == "-h") {
            print_usage(argv[0]);
            std::exit(0);
        } else {
            std::fprintf(stderr, "Unknown option: %s\n", arg.c_str());
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// 主函数
// ---------------------------------------------------------------------------
int main(int argc, const char *argv[]) {
    ::signal(SIGPIPE, SIG_IGN);
    CmdOptions opts;
    if (!parse_options(argc, argv, opts)) {
        return 2;
    }

    @autoreleasepool {
        const std::string module = rta::platform::module_dir_utf8();
        if (module.find("/build") == std::string::npos && module.find("/dist") == std::string::npos) {
            std::fprintf(stderr, "Note: Running outside build directory; ensuring full temporary isolation.\n");
        }

        // 1. 创建隔离根目录与家目录/状态库环境
        char pattern[] = "/tmp/rlplayer-startup-native-XXXXXX";
        char* made = ::mkdtemp(pattern);
        char cwd[PATH_MAX];
        if (!made || !::getcwd(cwd, sizeof(cwd))) {
            std::fprintf(stderr, "Failed to create isolated temp root directory.\n");
            return 2;
        }
        const std::string root = made;
        const std::string home = root + "/home";
        const std::string state = root + "/state";
        const std::string lib = root + "/library";
        const std::string cover = root + "/cover";
        const std::string music = root + "/music";
        const std::string tmp = root + "/tmp";

        for (const auto& d : {home, state, lib, cover, music, tmp, opts.output_dir}) {
            std::filesystem::create_directories(d);
        }

        ::setenv("HOME", home.c_str(), 1);
        ::setenv("CFFIXED_USER_HOME", home.c_str(), 1);
        ::setenv("RLPLAYER_STATE_DIR", state.c_str(), 1);
        ::setenv("RLPLAYER_LIBRARY_DIR", lib.c_str(), 1);
        ::setenv("RLPLAYER_COVER_DIR", cover.c_str(), 1);
        ::setenv("TMPDIR", tmp.c_str(), 1);
        ::setenv("no_proxy", "127.0.0.1,localhost", 1);
        ::setenv("NO_PROXY", "127.0.0.1,localhost", 1);
        ::chdir(root.c_str());

        // 2. 写入配置：backend=null 绝不出声，metaon=0 禁用在线元数据，空曲库
        std::ofstream(state + "/rlplayer-settings.conf") << "backend=null\nmetaon=0\n";
        std::ofstream(lib + "/rlplayer-library.conf") << music << "\n";
        std::ofstream(state + "/rlplayer-sources.conf") << "version=2\nnextid=1\nactive=0\n";
        std::ofstream(state + "/rlplayer-llm.conf") << "enabled=0\n";

        StartupTimeline timeline;
        timeline.theme = opts.theme;
        timeline.data_store_mode = opts.non_persistent ? "non_persistent_userscript" : "persistent_preseeded";
        timeline.t0_epoch_ms = now_ms();
        timeline.pid = ::getpid();

        // 3. 启动嵌入式核心（idempotent，供 scheme handler 服务）
        if (!rlapp::start_embedded()) {
            std::fprintf(stderr, "Fatal: rlapp::start_embedded() failed\n");
            ::chdir(cwd);
            std::filesystem::remove_all(root);
            return 1;
        }

        // 4. 持久模式下预种 localStorage，实现完全真实的冷启动环境
        if (!opts.non_persistent) {
            const bool seeded = preseed_localstorage(opts.theme, "apple");
            if (!seeded) {
                std::fprintf(stderr, "Warning: localStorage pre-seed returned false; continuing.\n");
            }
        }

        // 5. 初始化 AppKit 应用程序
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = opts.regular_activation ?
            NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory;
        [app finishLaunching];

        StartupHarnessAppDelegate *host = [[StartupHarnessAppDelegate alloc] init];
        host.harnessTheme = [NSString stringWithUTF8String:opts.theme.c_str()];
        host.forceNonPersistent = opts.non_persistent;
        app.delegate = host;

        timeline.t_window_created_ms = now_ms();
        [host applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:app]];
        [host.exitPollTimer invalidate];
        host.exitPollTimer = nil; // harness 自主管理退出

        // Hidden construction is not a visible compositor frame. Wait for production reveal.
        const bool becameVisible=runloop_until([&]{return host.window.isVisible;},6.0);
        if(!becameVisible)std::fprintf(stderr,"Native window was not revealed within startup budget\n");
        timeline.t_window_visible_ms = now_ms();
        timeline.window_id = (uint32_t)[host.window windowNumber];
        timeline.window_bounds = host.window.frame;

        // 6. 打印确定性就绪标头，供主控与 Cua driver 工具精确锚定
        std::printf("\n======================================================\n");
        std::printf("=== RLPLAYER STARTUP HARNESS READY ===\n");
        std::printf("PID: %ld\n", (long)timeline.pid);
        std::printf("WINDOW_ID: %u\n", timeline.window_id);
        std::printf("THEME: %s\n", opts.theme.c_str());
        std::printf("DATA_STORE: %s\n", timeline.data_store_mode.c_str());
        std::printf("BOUNDS: %.0f,%.0f,%.0f,%.0f\n",
                    timeline.window_bounds.origin.x, timeline.window_bounds.origin.y,
                    timeline.window_bounds.size.width, timeline.window_bounds.size.height);
        std::printf("OUTPUT_DIR: %s\n", opts.output_dir.c_str());
        std::printf("======================================================\n\n");
        std::fflush(stdout);

        // 7. 逐帧/分阶段采样执行循环
        int frame_idx = 0;
        auto sample_and_record = [&](const std::string& stage_name) {
            ++frame_idx;
            FrameRecord rec;
            rec.index = frame_idx;
            rec.stage = stage_name;
            rec.timestamp_ms = now_ms();
            rec.elapsed_ms = rec.timestamp_ms - timeline.t0_epoch_ms;

            CaptureAttempt cap = capture_window_frame(host.window, host.web, timeline.window_id, host.window.frame);
            rec.capture_method = cap.method;
            rec.proves_native_first_frame = cap.proves_native_first_frame;
            rec.notes = cap.notes;

            if (cap.method == "screencapturekit") timeline.screencapturekit_available = true;
            if (cap.method == "cg_window_list") timeline.cg_window_list_available = true;
            if (cap.method == "wk_snapshot") timeline.wk_snapshot_available = true;
            // A late native image proves only that sample, not the unseen first frame.
            if(frame_idx==1 && cap.proves_native_first_frame && host.window.isVisible)
                timeline.native_first_frame_proven = true;

            char fname[128];
            std::snprintf(fname, sizeof(fname), "frame-%02d-%s.png", frame_idx, stage_name.c_str());
            rec.relative_png = fname;
            rec.png_path = opts.output_dir + "/" + fname;

            if (cap.image) {
                rec.width = CGImageGetWidth(cap.image);
                rec.height = CGImageGetHeight(cap.image);
                save_cgimage_png(cap.image, rec.png_path);
                rec.pixel_center = inspect_cgimage_pixel(cap.image, (int)rec.width / 2, (int)rec.height / 2);
                rec.pixel_corner = inspect_cgimage_pixel(cap.image, 20, 20);
                CGImageRelease(cap.image);
            }

            timeline.frames.push_back(rec);
            std::printf("[FRAME %02d] t=+%4lldms stage=%-24s method=%-18s native=%-3s center=%s (%s)\n",
                        rec.index, rec.elapsed_ms, rec.stage.c_str(), rec.capture_method.c_str(),
                        rec.proves_native_first_frame ? "YES" : "NO",
                        rec.pixel_center.hex.c_str(), rec.pixel_center.classification.c_str());
            std::fflush(stdout);
        };

        // 采样 1：窗口创建与首次 orderFront 瞬间（最关键的原生首帧/底色阶段）
        sample_and_record("window_visible_immediate");

        // 采样 2：短暂轮询，记录文档请求发起与 head 阶段
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
        sample_and_record("request_in_flight");

        // 轮询等待 head 脚本执行并完成主题识别
        bool head_done = runloop_until([&] {
            return js_truth(host.web, @"document.documentElement && document.documentElement.dataset && !!document.documentElement.dataset.theme");
        }, 5.0);
        if (head_done) timeline.t_head_parsed_ms = now_ms();
        sample_and_record(head_done ? "head_theme_parsed" : "head_theme_timeout");

        // 轮询等待 DOM 容器挂载与 app.js 加载
        bool dom_ready = runloop_until([&] {
            return js_truth(host.web, @"typeof setView === 'function' && !!document.getElementById('list')");
        }, 8.0);
        if (dom_ready) timeline.t_dom_ready_ms = now_ms();
        sample_and_record(dom_ready ? "dom_ready_app_loaded" : "dom_ready_timeout");

        // 轮询等待主题完全结算与稳定
        bool theme_applied = runloop_until([&] {
            std::string t = js_string(host.web, @"document.documentElement.dataset.theme || ''");
            return !t.empty() && t == opts.theme;
        }, 4.0);
        if (theme_applied) timeline.t_theme_applied_ms = now_ms();
        sample_and_record("theme_settled");

        // 补充采集直至达到用户指定的样本数
        while ((int)timeline.frames.size() < opts.max_samples) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:opts.sample_interval_ms / 1000.0]];
            char stage_buf[64];
            std::snprintf(stage_buf, sizeof(stage_buf), "transition_%02d", (int)timeline.frames.size() + 1);
            sample_and_record(stage_buf);
        }

        // 采样末尾：稳定就绪状态
        timeline.t_stable_idle_ms = now_ms();
        sample_and_record("stable_idle");

        // 检查最终页面主题与断言
        timeline.final_theme_detected = js_string(host.web, @"document.documentElement.dataset.theme || ''");
        timeline.theme_matches_expected = (timeline.final_theme_detected == opts.theme);

        // 如果用户指定了 hold_ms，在就绪状态保持指定时间，便于宿主/主控 Cua 外部截图核验
        if (opts.hold_ms > 0) {
            std::printf("Harness holding at stable state for %d ms for external inspection...\n", opts.hold_ms);
            std::fflush(stdout);
            NSDate *hold_until = [NSDate dateWithTimeIntervalSinceNow:opts.hold_ms / 1000.0];
            while (hold_until.timeIntervalSinceNow > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            }
        }

        // 8. 写入时间线 JSON 文件
        const std::string json_path = opts.output_dir + "/timeline.json";
        std::ofstream jf(json_path);
        jf << "{\n";
        jf << "  \"test\": \"test_startup_native\",\n";
        jf << "  \"version\": \"" << RLPLAYER_VERSION << "\",\n";
        jf << "  \"theme\": \"" << json_escape(timeline.theme) << "\",\n";
        jf << "  \"data_store_mode\": \"" << json_escape(timeline.data_store_mode) << "\",\n";
        jf << "  \"pid\": " << timeline.pid << ",\n";
        jf << "  \"window_id\": " << timeline.window_id << ",\n";
        jf << "  \"window_bounds\": {\"x\": " << timeline.window_bounds.origin.x
           << ", \"y\": " << timeline.window_bounds.origin.y
           << ", \"width\": " << timeline.window_bounds.size.width
           << ", \"height\": " << timeline.window_bounds.size.height << "},\n";
        jf << "  \"timestamps_ms\": {\n";
        jf << "    \"start\": " << timeline.t0_epoch_ms << ",\n";
        jf << "    \"window_created\": " << timeline.t_window_created_ms << ",\n";
        jf << "    \"window_visible\": " << timeline.t_window_visible_ms << ",\n";
        jf << "    \"head_parsed\": " << timeline.t_head_parsed_ms << ",\n";
        jf << "    \"dom_ready\": " << timeline.t_dom_ready_ms << ",\n";
        jf << "    \"theme_applied\": " << timeline.t_theme_applied_ms << ",\n";
        jf << "    \"stable_idle\": " << timeline.t_stable_idle_ms << "\n";
        jf << "  },\n";
        jf << "  \"capabilities\": {\n";
        jf << "    \"screencapturekit_available\": " << (timeline.screencapturekit_available ? "true" : "false") << ",\n";
        jf << "    \"cg_window_list_available\": " << (timeline.cg_window_list_available ? "true" : "false") << ",\n";
        jf << "    \"wk_snapshot_available\": " << (timeline.wk_snapshot_available ? "true" : "false") << ",\n";
        jf << "    \"native_first_frame_proven\": " << (timeline.native_first_frame_proven ? "true" : "false") << "\n";
        jf << "  },\n";
        jf << "  \"theme_check\": {\n";
        jf << "    \"expected\": \"" << json_escape(opts.theme) << "\",\n";
        jf << "    \"detected\": \"" << json_escape(timeline.final_theme_detected) << "\",\n";
        jf << "    \"matches\": " << (timeline.theme_matches_expected ? "true" : "false") << "\n";
        jf << "  },\n";
        jf << "  \"frames\": [\n";
        for (size_t i = 0; i < timeline.frames.size(); ++i) {
            const auto& f = timeline.frames[i];
            jf << "    {\n";
            jf << "      \"index\": " << f.index << ",\n";
            jf << "      \"stage\": \"" << json_escape(f.stage) << "\",\n";
            jf << "      \"timestamp_ms\": " << f.timestamp_ms << ",\n";
            jf << "      \"elapsed_ms\": " << f.elapsed_ms << ",\n";
            jf << "      \"capture_method\": \"" << json_escape(f.capture_method) << "\",\n";
            jf << "      \"proves_native_first_frame\": " << (f.proves_native_first_frame ? "true" : "false") << ",\n";
            jf << "      \"png_file\": \"" << json_escape(f.relative_png) << "\",\n";
            jf << "      \"width\": " << f.width << ",\n";
            jf << "      \"height\": " << f.height << ",\n";
            jf << "      \"center_pixel\": {\"hex\": \"" << f.pixel_center.hex
               << "\", \"r\": " << f.pixel_center.r
               << ", \"g\": " << f.pixel_center.g
               << ", \"b\": " << f.pixel_center.b
               << ", \"classification\": \"" << f.pixel_center.classification << "\"},\n";
            jf << "      \"corner_pixel\": {\"hex\": \"" << f.pixel_corner.hex
               << "\", \"r\": " << f.pixel_corner.r
               << ", \"g\": " << f.pixel_corner.g
               << ", \"b\": " << f.pixel_corner.b
               << ", \"classification\": \"" << f.pixel_corner.classification << "\"},\n";
            jf << "      \"notes\": \"" << json_escape(f.notes) << "\"\n";
            jf << "    }" << (i + 1 < timeline.frames.size() ? ",\n" : "\n");
        }
        jf << "  ]\n";
        jf << "}\n";
        jf.close();

        // 9. 优雅协作拆除与清理
        [host.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]];
        runloop_until([&] {
            return !host.web.loading && [host.web.URL.absoluteString isEqualToString:@"about:blank"];
        }, 4.0);

        rlapp::request_shutdown();
        bool drained = false;
        for (int i = 0; i < 100 && !drained; ++i) {
            drained = [host.schemeHandler waitForInFlightTasksWithTimeout:0.02];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        rlapp::stop_embedded();

        host.web.navigationDelegate = nil;
        [host.web.configuration.userContentController removeAllScriptMessageHandlers];
        host.window.delegate = nil;
        app.delegate = nil;
        [host.window close];

        // 保持局部宿主引用至退出，规避 WKWebView 跨进程异步 dealloc 崩溃（见 test_source_native.mm）
        static HostAppDelegate* g_keepAliveUntilExit = nil;
        g_keepAliveUntilExit = host;

        ::chdir(cwd);
        std::error_code ec;
        std::filesystem::remove_all(root, ec);

        bool wrongTheme=false;
        for(const auto& f:timeline.frames){
            if(f.capture_method!="screencapturekit" && f.capture_method!="cg_window_list")continue;
            const bool dark=f.pixel_center.classification=="dark_bg";
            if((opts.theme=="dark"&&!dark)||(opts.theme!="dark"&&dark))wrongTheme=true;
        }
        timeline.assertions_passed = (timeline.window_id > 0) && dom_ready && timeline.theme_matches_expected && !wrongTheme;

        std::printf("\n======================================================\n");
        std::printf("=== RLPLAYER STARTUP HARNESS FINISHED ===\n");
        std::printf("Result: %s\n", timeline.assertions_passed ? "PASS" : "FAIL");
        std::printf("Frames Captured: %zu\n", timeline.frames.size());
        std::printf("Native First Frame Proven: %s\n", timeline.native_first_frame_proven ? "YES" : "NO (Fallback)");
        std::printf("Timeline JSON: %s\n", json_path.c_str());
        std::printf("======================================================\n\n");
        std::fflush(stdout);

        if (opts.print_json) {
            std::ifstream rj(json_path);
            std::string line;
            while (std::getline(rj, line)) {
                std::printf("%s\n", line.c_str());
            }
        }

        return timeline.assertions_passed ? 0 : 1;
    }
}
