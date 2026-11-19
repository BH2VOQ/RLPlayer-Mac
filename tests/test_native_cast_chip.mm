// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_cast_chip.mm — 投放芯片运行态 = web `npCastBtnHtml`
//
// ============================ 这条判据在证明什么 ============================
// web 真源：
//   ui_script.h:8918-8927  npCastBtnHtml：running → chip class `on` + 「已推送到 <device>」
//                          （tooltip「点击停止投放并恢复本机输出」）；否则「推送到设备」。
//   ui_script.h:13518 点击 = castToggle：running 时停止（POST /api/cast/stop），否则弹设备列表。
//   ui_page.h:770-772 `.npcast`/`.npcast.on`：on 用 --ok-bg/--ok-text/--ok-line、font-weight:600。
// 旧原生（1.1.7.31）：npCastBtn 永远写死「推送到设备」，从不读 /api/cast/state；
//   投放中点它还是弹设备列表（不能停）。所以本文件对旧码必须红。
//
// 铁律②：桩客户端；不启动核心、不碰音频设备、不创建可见窗口（也不会触发 NSAlert）。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"
#import "RLPSupport.h"
#import "RLPModels.h"

#include <cstdio>
#include <cmath>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
static void EqStr(NSString *got, NSString *want, const char *what) {
    Ck([got isEqualToString:want], what,
       [NSString stringWithFormat:@"got=%@ want=%@", got ?: @"(nil)", want ?: @"(nil)"]);
}

static BOOL g_casting = YES;
static NSMutableArray<NSDictionary *> *g_gets;
static NSMutableArray<NSDictionary *> *g_posts;

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [g_gets addObject:@{ @"path": path ?: @"" }];
    if (!done) return;
    if ([path isEqualToString:@"/api/cast/state"]) {
        done(@{ @"ok": @YES, @"running": @(g_casting),
                @"device": (g_casting ? @"upnp://192.168.1.10:8200/desc.xml" : @""),
                @"phase": @"serving" });
        return;
    }
    done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma mark clang diagnostic pop

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
    return ca && cb && fabs(ca.redComponent - cb.redComponent) < 0.02 &&
           fabs(ca.greenComponent - cb.greenComponent) < 0.02 &&
           fabs(ca.blueComponent - cb.blueComponent) < 0.02;
}
static CGFloat LayerBgR(NSButton *b) { return b.layer.backgroundColor ? 0 : 0; }
static BOOL LayerBgEq(NSButton *b, NSColor *c) {
    CGColorRef bg = b.layer.backgroundColor;
    if (!bg) return NO;
    NSColor *got = [NSColor colorWithCGColor:bg];
    return SameColor(got, c);
}

@interface RLPNowPlayingViewController (CastChipTest)
- (void)refreshCastChipState;
- (void)applyMetaChipVisibility;
- (NSString *)castBodyForDevice:(NSDictionary *)device;
@end

/// 旧码没有 refreshCastChipState：用 respondsToSelector 守卫，红阶段干净退出而不是 SIGABRT。
static BOOL CallRefreshCastChipState(RLPNowPlayingViewController *vc) {
    SEL sel = NSSelectorFromString(@"refreshCastChipState");
    if (![vc respondsToSelector:sel]) return NO;
    [vc performSelector:sel];
    return YES;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_gets = [NSMutableArray array];
        g_posts = [NSMutableArray array];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        std::printf("=== test_native_cast_chip（投放芯片 on/off 状态 · 离屏 · 不出声）===\n");

        RLPNowPlayingViewController *vc = [RLPNowPlayingViewController new];
        NSView *v = vc.view;
        v.frame = NSMakeRect(0, 0, 1400, 900);
        [v layoutSubtreeIfNeeded];
        NSButton *chip = (NSButton *)FindById(v, @"npCastBtn");
        Ck(chip != nil, "找得到投放芯片 npCastBtn", @"缺 npCastBtn");
        if (!chip) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }

        // Request generation is offline: an unknown volume must never serialize NaN.
        id priorStatus = [vc valueForKey:@"webStatus"];
        NSString *priorPath = [vc valueForKey:@"currentPath"];
        [vc setValue:@"/tmp/cast-volume-fixture.flac" forKey:@"currentPath"];
        [vc setValue:[RLPPlaybackStatus statusFromJSON:@{@"ok": @YES}] forKey:@"webStatus"];
        NSDictionary *device = @{@"location": @"http://renderer.invalid/device.xml"};
        NSString *unknownBody = [vc castBodyForDevice:device];
        Ck([unknownBody containsString:@"volume=-120.0"] && ![unknownBody.lowercaseString containsString:@"nan"],
           "unknown cast volume uses finite silent fallback", unknownBody);
        [vc setValue:[RLPPlaybackStatus statusFromJSON:@{@"ok": @YES, @"volDb": @0}] forKey:@"webStatus"];
        Ck([[vc castBodyForDevice:device] containsString:@"volume=0.0"], "explicit zero cast volume remains valid", @"");
        // A just-confirmed volume must win over the older status snapshot.
        id controls = [vc valueForKey:@"webControls"];
        [vc setValue:[RLPPlaybackStatus statusFromJSON:@{@"ok": @YES, @"volDb": @(-40)}] forKey:@"webStatus"];
        if (controls) {
            [controls setValue:@(-15.0) forKey:@"confirmedVolumeDb"];
            [controls setValue:@YES forKey:@"hasConfirmedVolume"];
            Ck([[vc castBodyForDevice:device] containsString:@"volume=-15.0"],
               "confirmed volume overrides stale cast snapshot", [vc castBodyForDevice:device]);
        }
        [vc setValue:priorStatus forKey:@"webStatus"];
        [vc setValue:priorPath forKey:@"currentPath"];

        // ---- 1. 投放中：读 /api/cast/state，chip「已推送到 <host>」+ ok 三令牌 ----
        g_casting = YES;
        Ck(CallRefreshCastChipState(vc),
           "生产码实现了 refreshCastChipState（读 /api/cast/state）", @"旧码没有该方法");
        Pump(0.05);
        if (![vc respondsToSelector:NSSelectorFromString(@"refreshCastChipState")]) {
            std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
            return 1;
        }
        Ck([g_gets count] > 0 && [g_gets.lastObject[@"path"] isEqualToString:@"/api/cast/state"],
           "refeshCastChipState 请求 /api/cast/state（web castRunning）",
           g_gets.lastObject[@"path"] ?: @"");
        RLPTheme *t = [RLPTheme current];
        NSString *title = chip.attributedTitle.string.length ? chip.attributedTitle.string : chip.title;
        Ck([title containsString:RLPTr(@"已推送到")],
           "投放中 chip 文案含「已推送到」", title);
        Ck([title containsString:@"192.168.1.10"],
           "chip 显示设备 host（web castDevNameOf）", title);
        Ck(LayerBgEq(chip, t.okBg), "on 态背景 = --ok-bg（web .npcast.on）",
           @"背景不是 ok-bg");
        Ck(fabs(chip.font.pointSize - 11.0) < 0.01, "chip 字号 11（web .npcast 11.5 近似）",
           [NSString stringWithFormat:@"pt=%.2f", chip.font.pointSize]);

        // ---- 2. 投放中点芯片 = 停止（POST /api/cast/stop），不是弹设备列表 ----
        [g_posts removeAllObjects];
        g_casting = NO;   // 停止后后端状态
        @try { [NSApp sendAction:chip.action to:chip.target from:chip]; }
        @catch (NSException *e) { std::printf("  (sendAction caught: %s)\n", e.reason.UTF8String ?: ""); }
        Pump(0.05);
        BOOL sawStop = NO;
        for (NSDictionary *p in g_posts)
            if ([p[@"path"] isEqualToString:@"/api/cast/stop"]) sawStop = YES;
        Ck(sawStop, "投放中点 chip 发 /api/cast/stop（web castToggle）",
           [g_posts componentsJoinedByString:@" | "]);
        // 停止后的状态刷新（测试里桩状态已改成 not running）
        CallRefreshCastChipState(vc);
        Pump(0.05);
        title = chip.attributedTitle.string.length ? chip.attributedTitle.string : chip.title;
        EqStr(title, RLPTr(@"推送到设备"), "不在投放时 chip 文案 = 推送到设备");
        Ck(LayerBgEq(chip, t.bg3), "off 态背景 = --bg3（web .npcast）", @"背景不是 bg3");

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
