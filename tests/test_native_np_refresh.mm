// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_np_refresh.mm — 正在播放页两条「状态没跟上真相」的判据
//
// ============================ 这条判据在证明什么 ============================
// D3（审计 C，S）：web 投放成功后立刻把芯片画成 on 态（castPush 里 applyCastUi 乐观态 +
//   随后的 pollCastState(true)，ui_script.h:8849-8878）。旧原生 /api/cast/start 的成功回调
//   **只在失败时** toast（RLPNowPlayingViewController.mm:2728）⟹ 芯片要等 2s 的
//   /api/cast/state 轮询才变「已推送到 <设备>」。
// D4（审计 C，S）：循环/随机是**全局**状态，页面每次打开都该读最新值。旧原生只在
//   「换曲」分支里拉 /api/queue（:3970-3979），activate 不拉（:3303-3306）⟹
//   「播放中关掉正在播放页 → 改成单曲循环 → 再打开」显示的还是旧档位。
//
// 铁律②：桩客户端；不启动核心、不碰音频设备、不创建可见窗口、不出声。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>
#include <cmath>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

#pragma mark - 桩客户端

static NSMutableArray<NSDictionary *> *g_gets;
static NSMutableArray<NSDictionary *> *g_posts;
static BOOL g_castRunning = NO;      // /api/cast/state 回报的运行态（模拟后端真相）
static BOOL g_castStartOk = YES;    // /api/cast/start 的返回
static NSInteger g_mode = 0;         // /api/queue?meta=1 的播放模式（0..3）
static NSString *g_curPath = @"/Music/A.flac";

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [g_gets addObject:@{ @"path": path ?: @"" }];
    if (!done) return;
    if ([path hasPrefix:@"/api/status"]) {
        done(@{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                @"current": g_curPath, @"pos": @10, @"dur": @100, @"volDb": @(-120) });
        return;
    }
    if ([path hasPrefix:@"/api/queue"]) {
        done(@{ @"ok": @YES, @"mode": @(g_mode), @"index": @0,
                @"items": @[ g_curPath ] });
        return;
    }
    if ([path hasPrefix:@"/api/cast/state"]) {
        done(@{ @"ok": @YES, @"running": @(g_castRunning),
                @"device": (g_castRunning ? @"upnp://192.168.1.10:8200/desc.xml" : @""),
                @"phase": @"serving" });
        return;
    }
    done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if (!done) return;
    if ([path hasPrefix:@"/api/cast/start"]) {
        if (g_castStartOk) { g_castRunning = YES; done(@{ @"ok": @YES }); }   // 后端真的起来了
        else done(@{ @"ok": @NO, @"error": @"设备无响应" });
        return;
    }
    if ([path hasPrefix:@"/api/cast/stop"]) { g_castRunning = NO; done(@{ @"ok": @YES }); return; }
    done(@{ @"ok": @YES });
}
@end
#pragma mark clang diagnostic pop

#pragma mark - 工具

static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}
static BOOL SameColor(NSColor *a, NSColor *b) {
    if (!a || !b) return NO;
    NSColor *ca = [a colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *cb = [b colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!ca || !cb) return NO;
    return fabs(ca.redComponent - cb.redComponent) < 0.02 &&
           fabs(ca.greenComponent - cb.greenComponent) < 0.02 &&
           fabs(ca.blueComponent - cb.blueComponent) < 0.02;
}
static BOOL LayerBgEq(NSButton *b, NSColor *c) {
    CGColorRef bg = b.layer.backgroundColor;
    if (!bg) return NO;
    return SameColor([NSColor colorWithCGColor:bg], c);
}
static NSInteger CountPaths(NSArray<NSDictionary *> *arr, NSString *prefix) {
    NSInteger n = 0;
    for (NSDictionary *d in arr) if ([d[@"path"] hasPrefix:prefix]) ++n;
    return n;
}
static NSDictionary *LastPost(NSString *prefix) {
    NSDictionary *hit = nil;
    for (NSDictionary *d in g_posts) if ([d[@"path"] hasPrefix:prefix]) hit = d;
    return hit;
}
static NSString *ChipTitle(NSButton *chip) {
    return chip.attributedTitle.string.length ? chip.attributedTitle.string : chip.title;
}

@interface RLPNowPlayingViewController (RefreshTestSeam)
- (void)refreshCastChipState;
- (void)castStartToDevice:(NSDictionary *)device;
- (void)refreshPlayMode;
- (void)applyPlayModeUI;
@end

/// 旧码没有这些入口：先 respondsToSelector 守卫，红阶段干净退出而不是 SIGABRT。
/// （ARC 下对未知 selector 用 performSelector 会报「可能泄漏」；这里的入口都是 void/无返回对象的方法。）
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
static BOOL CallSeam(id target, SEL sel, id arg) {
    if (![target respondsToSelector:sel]) return NO;
    if (arg) (void)[target performSelector:sel withObject:arg];
    else [target performSelector:sel];
    return YES;
}
#pragma clang diagnostic pop

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_gets = [NSMutableArray array];
        g_posts = [NSMutableArray array];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        std::printf("=== test_native_np_refresh（投放成功即刷芯片 · 重开页面同步循环模式 · 离屏 · 不出声）===\n");

        RLPNowPlayingViewController *vc = [RLPNowPlayingViewController new];
        NSView *v = vc.view;
        v.frame = NSMakeRect(0, 0, 1400, 900);
        [v layoutSubtreeIfNeeded];
        NSButton *chip = (NSButton *)FindById(v, @"npCastBtn");
        NSButton *rep = (NSButton *)FindById(v, @"np.rep");
        NSView *repBadge = FindById(v, @"npRepOne");
        Ck(chip != nil && rep != nil, "找得到投放芯片 npCastBtn 与循环键 np.rep", @"控件缺失");
        if (!chip || !rep) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }

        RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:
            @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
               @"current": g_curPath, @"pos": @10, @"dur": @100, @"volDb": @(-120) }];
        [vc setValue:st forKey:@"webStatus"];
        [vc setValue:g_curPath forKey:@"currentPath"];
        Ck(CallSeam(vc, NSSelectorFromString(@"refreshCastChipState"), nil),
           "生产码有 refreshCastChipState 入口", @"旧码没有该方法");
        Pump(0.05);
        Ck([ChipTitle(chip) isEqualToString:RLPTr(@"推送到设备")],
           "未投放时芯片文案 = 推送到设备", ChipTitle(chip));

        // ---- D3：/api/cast/start 返回 ok ⟹ **不等 2s 轮询**，芯片立刻变「已推送到」----
        const NSInteger stateBefore = CountPaths(g_gets, @"/api/cast/state");
        Ck(CallSeam(vc, NSSelectorFromString(@"castStartToDevice:"), @{ @"name": @"Living Room",
                                                                      @"location": @"upnp://192.168.1.10:8200/desc.xml" }),
           "生产码把「点推送」抽成 castStartToDevice:（判据可驱动到的落库入口）",
           @"旧码只有内联在 NSAlert 分支里的请求，无法驱动");
        Pump(0.12);      // 远小于 2s 的 /api/cast/state 轮询间隔
        NSDictionary *startPost = LastPost(@"/api/cast/start");
        Ck(startPost != nil, "发出 /api/cast/start", [g_posts componentsJoinedByString:@" | "]);
        Ck(startPost && [startPost[@"body"] containsString:@"192.168.1.10"],
           "投放请求带设备地址（dev=）", startPost[@"body"] ?: @"");
        Ck(startPost && [startPost[@"body"] containsString:@"file="],
           "投放请求带当前曲目（file=）", startPost[@"body"] ?: @"");
        Ck(CountPaths(g_gets, @"/api/cast/state") > stateBefore,
           "成功后立刻请求 /api/cast/state（不等 2s 轮询）",
           [NSString stringWithFormat:@"before=%ld after=%ld", (long)stateBefore,
            (long)CountPaths(g_gets, @"/api/cast/state")]);
        NSString *title = ChipTitle(chip);
        RLPTheme *t = [RLPTheme current];
        Ck([title containsString:RLPTr(@"已推送到")],
           "推送成功后芯片立刻显示「已推送到…」", title);
        Ck([title containsString:@"192.168.1.10"], "芯片显示设备 host（web castDevNameOf）", title);
        Ck(LayerBgEq(chip, t.okBg), "on 态背景 = --ok-bg（web .npcast.on）", @"背景不是 ok-bg");

        // ---- D3 负向：后端拒绝时不许假装已推送 ----
        g_castRunning = NO;
        g_castStartOk = NO;
        CallSeam(vc, NSSelectorFromString(@"refreshCastChipState"), nil);
        Pump(0.05);
        Ck([ChipTitle(chip) isEqualToString:RLPTr(@"推送到设备")],
           "未投放时芯片回到「推送到设备」", ChipTitle(chip));
        [g_posts removeAllObjects];
        CallSeam(vc, NSSelectorFromString(@"castStartToDevice:"), @{ @"name": @"Living Room",
                                                                    @"location": @"upnp://192.168.1.10:8200/desc.xml" });
        Pump(0.12);
        Ck(LastPost(@"/api/cast/start") != nil, "拒绝路径也发了 /api/cast/start",
           [g_posts componentsJoinedByString:@" | "]);
        Ck([ChipTitle(chip) isEqualToString:RLPTr(@"推送到设备")],
           "投放失败不把芯片画成已推送（不许撒谎）", ChipTitle(chip));
        g_castStartOk = YES;

        // ---- D4：播放中关掉页面 → 别处改成单曲循环 → 再打开，循环键必须显示单曲循环 ----
        g_mode = 0;
        [vc activate];                 // 第一次打开：读 /api/status（当前曲 A）
        Pump(0.1);
        Ck([rep.toolTip isEqualToString:RLPTr(@"顺序播放（播到末尾停止）")] ||
           rep.toolTip.length > 0, "首次打开时循环键是顺序播放", rep.toolTip ?: @"");
        [vc viewDidDisappear];         // 关掉正在播放页
        Pump(0.02);
        const NSInteger queueBefore = CountPaths(g_gets, @"/api/queue");
        g_mode = 2;                    // 别处（底栏/菜单）改成了单曲循环
        [vc activate];                 // 重新打开
        Pump(0.12);
        Ck(CountPaths(g_gets, @"/api/queue") > queueBefore,
           "重新打开页面会重读 /api/queue 同步播放模式", @"没有发 /api/queue");
        Ck([rep.toolTip isEqualToString:RLPTr(@"单曲循环（重复当前这首）")],
           "循环键显示单曲循环（不是旧档位）", rep.toolTip ?: @"");
        Ck([(NSString *)[vc valueForKey:@"playModeSymbol"] isEqualToString:@"repeat.1"],
           "循环键图标 = repeat.1（web REP_ICON 四档）",
           (NSString *)[vc valueForKey:@"playModeSymbol"] ?: @"(nil)");
        Ck(repBadge != nil && !repBadge.hidden, "「1」角标显示（web #npRepOne 只在单曲循环）",
           @"角标不可见");
        Ck(SameColor(rep.contentTintColor, t.accentText),
           "单曲循环档位色 = --acc-text（web applyRep）", @"");

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
