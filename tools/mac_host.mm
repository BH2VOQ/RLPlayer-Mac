// mac_host.mm — RLPlayer macOS 原生壳（PLATFORM.md §9 第 9 条 / §10 契约）
//
// 对齐 Windows 形态（tools/launcher.cpp + WebView2）：
//   壳进程（本文件，NSWindow + WKWebView）
//     └─ posix_spawn 子进程 rtaweb（HTTP 服务 + CoreAudio 播放，--no-browser）
//   界面与壳之间【只有】HTTP + 一条 postMessage 通道（§10.1/10.2），
//   消息名与语义逐字照 §10 的表（9 条），UI 一行不改。
//
// window.chrome.webview 垫片（§10.2）：
//   UI 侧只认 window.chrome.webview（WebView2 的对象）。WKWebView 的原生通道是
//   window.webkit.messageHandlers.<name>.postMessage —— 在 documentStart 注入垫片，
//   把前者桥到后者；宿主→UI 用 evaluateJavaScript 调垫片的 __emit（ev.data 为字符串）。
//
// 窗口形态：titlebar + FullSizeContentView + hiddenTitle（内容贴满、红绿灯保留在
// 左上角 overlay）——页面自带顶栏按钮（右上有 min/max/close），与红绿灯并存都可用。
//
// 2026-10-25 首版实测注记：
//   * drag 消息在 WKWebView 内拿不到原生鼠标事件，用 [NSApp currentEvent] 最近一次
//     鼠标 down 调 performWindowDragWithEvent（页面顶栏 mousedown 后立即发消息，事件
//     仍有效——WebView2 侧 ReleaseCapture+HTCAPTION 的等价物）。
//   * max 语义 = Windows「占满工作区/还原」切换（不是 mac 全屏，绿色按钮才是全屏）。
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string>

extern char **environ;

static const uint16_t kPortBase = 8899;     // launcher 语义：从 8899 起找可用端口
static const int    kPortSpan = 12;         // 8899..8910（HANDOVER：8910 留给测试实例）

// ---------------------------------------------------------------------------
// 服务子进程管理
// ---------------------------------------------------------------------------
@interface ServiceChild : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic) uint16_t port;
@end
@implementation ServiceChild
- (void)launchFromBundle {
    // 服务二进制 = 同 bundle 的 Contents/MacOS/rtaweb（make_app_mac.sh 布局）
    NSString *svc = [[[NSBundle mainBundle] bundleURL]
                     URLByAppendingPathComponent:@"Contents/MacOS/rtaweb"].path;
    if (![[NSFileManager defaultManager] fileExistsAtPath:svc]) {
        [self alertFatal:[NSString stringWithFormat:
            @"找不到服务程序：%@\n（重新运行 tools/make_app_mac.sh 打包）", svc]];
        return;
    }
    // 端口：从 8899 往上找第一个能 bind 的（探测方式 = 起服务后 curl /api/ping 重试；
    // 端口冲突时服务自己会退出码 1，壳递增重试）
    for (int attempt = 0; attempt < kPortSpan; ++attempt) {
        const uint16_t port = (uint16_t)(kPortBase + attempt);
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        char argPort[16], argNb[16];
        std::snprintf(argPort, sizeof argPort, "--port=%u", (unsigned)port);
        std::snprintf(argNb, sizeof argNb, "--no-browser");
        char *const argv[] = { (char*)svc.fileSystemRepresentation, argPort, argNb, nullptr };
        pid_t pid = 0;
        const int rc = ::posix_spawn(&pid, svc.fileSystemRepresentation, nullptr, &attr, argv, environ);
        posix_spawnattr_destroy(&attr);
        if (rc != 0) continue;
        // 服务就绪探测：/api/ping（最多 ~4s）
        for (int i = 0; i < 80; ++i) {
            if (::kill(pid, 0) != 0) break;    // 已退出（端口被占）→ 换下一个端口
            char cmd[128];
            std::snprintf(cmd, sizeof cmd,
                          "curl -s -m 1 http://127.0.0.1:%u/api/ping >/dev/null 2>&1", (unsigned)port);
            if (::system(cmd) == 0) { self.pid = pid; self.port = port; return; }
            ::usleep(50 * 1000);
        }
        ::kill(pid, SIGKILL);                  // 没就绪/已退出的清理
        ::waitpid(pid, nullptr, 0);
    }
    [self alertFatal:@"无法启动播放服务（8899..8910 都不可用）"];
}
- (void)terminateGracefully {
    if (self.pid <= 0) return;
    ::kill(self.pid, SIGTERM);                 // rtaweb 已实现优雅收尾（铁律 2）
    for (int i = 0; i < 40; ++i) {             // 最多 2s
        if (::kill(self.pid, 0) != 0 || ::waitpid(self.pid, nullptr, WNOHANG) == self.pid) return;
        ::usleep(50 * 1000);
    }
    ::kill(self.pid, SIGKILL);                 // 兜底（服务已无响应）
    ::waitpid(self.pid, nullptr, 0);
}
- (void)alertFatal:(NSString *)msg {
    // 致命错误必须可见（§7：不许静默失败）——系统弹窗 + 退出
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"RLPlayer 无法启动";
        a.informativeText = msg;
        [a runModal];
        [NSApp terminate:nil];
    });
}
@end

// ---------------------------------------------------------------------------
// 垫片：window.chrome.webview ⇄ WKScriptMessageHandler
// ---------------------------------------------------------------------------
static NSString *const kShim = @
"(function() {"
 "  if (window.chrome && window.chrome.webview) return;           // 已注入（导航重入）"
 "  function emit(data) {"
 "    var ev = { data: data };                                    // §10.2：ev.data 是字符串"
 "    (window.chrome.webview.__l || []).forEach(function(fn) { try { fn(ev); } catch (e) {} });"
 "  }"
 "  window.chrome = window.chrome || {};"
 "  window.chrome.webview = {"
 "    __l: [],"
 "    postMessage: function(msg) {                                // UI → 宿主（字符串）"
 "      try { window.webkit.messageHandlers.rlhost.postMessage(String(msg)); } catch (e) {}"
 "    },"
 "    addEventListener: function(type, fn) {                      // 宿主 → UI（'message'）"
 "      if (type === 'message' && typeof fn === 'function') this.__l.push(fn);"
 "    },"
 "    removeEventListener: function(type, fn) {"
 "      if (type !== 'message') return;"
 "      this.__l = this.__l.filter(function(f) { return f !== fn; });"
 "    },"
 "    __emit: emit"
 "  };"
 "})();";

// ---------------------------------------------------------------------------
// 应用委托 + 窗口 + 消息处理
// ---------------------------------------------------------------------------
@interface HostAppDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandler,
                                       WKNavigationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) ServiceChild *svc;
@property (nonatomic) NSRect savedFrame;       // max 前的窗口 frame（还原用）
@property (nonatomic) bool zoomed;
@end

@implementation HostAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    // 服务子进程（先起：窗口加载的 URL 依赖它）
    _svc = [[ServiceChild alloc] init];
    [_svc launchFromBundle];
    if (_svc.pid <= 0) return;                 // 弹窗后 terminate

    [self buildMenu];

    NSRect frame = NSMakeRect(0, 0, 1180, 760);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                    NSWindowStyleMaskFullSizeContentView
                            backing:NSBackingStoreBuffered defer:NO];
    self.window.titleVisibility = NSWindowTitleHidden;      // 无标题文字（页面自带顶栏）
    self.window.titlebarAppearsTransparent = YES;
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.backgroundColor = [NSColor colorWithCalibratedRed:0.047 green:0.055 blue:0.075 alpha:1.0];
    [self.window center];
    self.window.delegate = self;

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:kShim
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:YES]];
    [ucc addScriptMessageHandler:self name:@"rlhost"];
    cfg.userContentController = ucc;

    self.web = [[WKWebView alloc] initWithFrame:frame configuration:cfg];
    self.web.navigationDelegate = self;
    self.web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window setContentView:self.web];

    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%u/", (unsigned)_svc.port];
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)buildMenu {
    // 最小 App 菜单：保证 Cmd+Q / 关窗语义存在（无 NIB 时的标准做法）
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"退出 RLPlayer" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];
    [NSApp setMainMenu:bar];
}

// ---------------- §10.2 消息表：UI → 宿主（逐字对齐 Windows onMessage）----------------
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)msg {
    (void)ucc;
    NSString *m = [msg.body isKindOfClass:[NSString class]] ? (NSString *)msg.body : nil;
    if (!m) return;
    if ([m isEqualToString:@"min"]) {
        [self.window miniaturize:nil];                        // ShowWindow(SW_MINIMIZE)
    } else if ([m isEqualToString:@"max"]) {
        // Windows 语义：最大化/还原切换（占满工作区，不是 mac 全屏）
        if (!self.zoomed) {
            self.savedFrame = self.window.frame;
            NSRect full = self.window.screen.visibleFrame;
            [self.window setFrame:full display:YES animate:YES];
            self.zoomed = YES;
            [self emitToPage:@"max"];
        } else {
            [self.window setFrame:self.savedFrame display:YES animate:YES];
            self.zoomed = NO;
            [self emitToPage:@"normal"];
        }
    } else if ([m isEqualToString:@"close"]) {
        [NSApp terminate:nil];                                // PostMessage(WM_CLOSE)
    } else if ([m isEqualToString:@"drag"]) {
        // 页面顶栏拖动（§10.2 表）：最近一次鼠标事件发起窗口拖拽
        NSEvent *ev = [NSApp currentEvent];
        if (ev && (ev.type == NSEventTypeLeftMouseDown || ev.type == NSEventTypeLeftMouseDragged))
            [self.window performWindowDragWithEvent:ev];
    } else if ([m isEqualToString:@"theme:dark"]) {
        self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    } else if ([m isEqualToString:@"theme:light"] || [m isEqualToString:@"theme:blue"]) {
        self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    }
}

// 宿主 → UI：max/normal 在窗口尺寸变化时发（§10.2：Windows 在 WM_SIZE 里发）
- (void)emitToPage:(NSString *)s {
    NSString *js = [NSString stringWithFormat:@"window.chrome.webview && window.chrome.webview.__emit('%@');", s];
    [self.web evaluateJavaScript:js completionHandler:nil];
}
- (void)windowDidResize:(NSNotification *)n {
    (void)n;
    // 只在非程序化 setFrame 时回发，避免与 max 处理器重复发（那儿已手动发过）
    if (self.zoomed != (self.window.frame.size.width >= self.window.screen.visibleFrame.size.width - 1 &&
                        self.window.frame.size.height >= self.window.screen.visibleFrame.size.height - 1)) {
        self.zoomed = !self.zoomed;
        [self emitToPage:self.zoomed ? @"max" : @"normal"];
    }
}

// ---------------- 生命周期 ----------------
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a {
    (void)a; return YES;                                      // 关窗 = 退出（Windows 壳同语义）
}
- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    [_svc terminateGracefully];                               // 停子进程（优雅→兜底）
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        HostAppDelegate *del = [[HostAppDelegate alloc] init];
        NSApplication *app = [NSApplication sharedApplication];
        app.delegate = del;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
