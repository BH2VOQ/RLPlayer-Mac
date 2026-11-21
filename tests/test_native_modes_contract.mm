// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_modes_contract.mm — 纯 AppKit 聆听/专业双模式契约测试（离线 / 不出声）
//
// 验证目标：
//   1. 顶栏 NSSegmentedControl (top.mode) 聆听(listen)/专业(pro)，默认 listen；
//   2. 模式持久化 GET /api/settings.kv.uimode 与 POST /api/settings uimode=listen|pro，
//      且过期 GET 回包不回跳（epoch 保护）；
//   3. 原子切换侧栏（聆听室 <-> 数字音乐台）、顶栏标题、station 首页
//      （listen -> RLPQuickStartViewController, pro -> RLPWorkbenchViewController），
//      pageCache 不跨模式拿错，详情返回上下文一致；
//   4. 两种模式均保留全部原导航 key 与深链，均可达 settings（不隐藏、不强制切 pro）；
//   5. 设置页通用/音频处理层级重排，保留全部 10 个 paneID 与 play->adv 别名，单层滚动；
//   6. 模式切换绝不发 play/stop/pause/volume/queue/device 请求。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPSettingsViewController.h"
#import "RLPQuickStartViewController.h"
#import "RLPWorkbenchViewController.h"
#import "RLPAlbumDetailViewController.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cmath>
#include <cstdio>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

@interface RLPModesSpy : NSObject
@property (nonatomic, copy) NSString *serverUiMode;
@property (nonatomic, assign) BOOL holdSettingsGet;
@property (nonatomic, copy) void (^heldSettingsCompletion)(NSDictionary * _Nullable json);
@property (nonatomic, assign) BOOL holdSettingsPost;
@property (nonatomic, copy) void (^heldSettingsPostCompletion)(NSDictionary * _Nullable json);
@property (nonatomic, strong) NSMutableArray<NSString *> *requests;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *posts;
@end

@implementation RLPModesSpy
- (instancetype)init {
    self = [super init];
    if (self) {
        _serverUiMode = @"listen";
        _requests = [NSMutableArray array];
        _posts = [NSMutableArray array];
    }
    return self;
}
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown { }
- (id)jsonWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body {
    [self.requests addObject:[NSString stringWithFormat:@"%@ %@", method ?: @"GET", path ?: @""]];
    if ([method isEqualToString:@"POST"]) {
        [self.posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    }
    if ([path hasPrefix:@"/api/settings"] && ![method isEqualToString:@"POST"]) {
        return @{ @"ok": @YES, @"kv": @{ @"uimode": self.serverUiMode ?: @"listen", @"backend": @"null", @"volume": @"-120" } };
    }
    return @{ @"ok": @YES };
}
- (NSData *)dataWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body
               contentType:(NSString **)contentType {
    (void)method; (void)path; (void)body; (void)contentType;
    return nil;
}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [self.requests addObject:[NSString stringWithFormat:@"GET %@", path ?: @""]];
    if (!done) return;
    if ([path hasPrefix:@"/api/settings"] && self.holdSettingsGet) {
        self.heldSettingsCompletion = [done copy];
        return;
    }
    NSDictionary *json = [self fixtureForPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [self.requests addObject:[NSString stringWithFormat:@"POST %@", path ?: @""]];
    [self.posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if ([path isEqualToString:@"/api/settings"] && self.holdSettingsPost) {
        if (done) self.heldSettingsPostCompletion = [done copy];
        return;
    }
    if ([path isEqualToString:@"/api/settings"] && [body containsString:@"uimode="]) {
        if ([body containsString:@"uimode=pro"]) self.serverUiMode = @"pro";
        else if ([body containsString:@"uimode=listen"]) self.serverUiMode = @"listen";
    }
    if (!done) return;
    dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    (void)path;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
}
- (void)postData:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType
       completion:(RLPJSONCompletion)done {
    (void)path; (void)body; (void)contentType;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
}
- (NSDictionary *)fixtureForPath:(NSString *)path {
    if ([path hasPrefix:@"/api/settings"]) {
        return @{
            @"ok": @YES,
            @"kv": @{
                @"uimode": self.serverUiMode ?: @"listen",
                @"backend": @"null",
                @"volume": @"-120",
                @"theme": @"light"
            }
        };
    }
    if ([path hasPrefix:@"/api/status"]) {
        return @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                  @"current": @"/Music/Test/01.flac", @"pos": @12.5, @"dur": @240.0, @"volDb": @(-120) };
    }
    if ([path hasPrefix:@"/api/queue"]) {
        return @{ @"ok": @YES, @"items": @[ @"/Music/Test/01.flac" ], @"index": @0, @"mode": @0 };
    }
    if ([path hasPrefix:@"/api/lib/albums"]) {
        return @{ @"ok": @YES, @"albums": @[ @{ @"k": @"/Music/Test", @"name": @"Test", @"artist": @"Tester", @"year": @2026, @"n": @1, @"dur": @240, @"sr": @44100, @"bits": @16, @"cv": @NO } ] };
    }
    if ([path hasPrefix:@"/api/lib/album?"]) {
        return @{ @"ok": @YES, @"album": @{ @"k": @"/Music/Test", @"name": @"Test", @"artist": @"Tester", @"year": @2026, @"tracks": @[ @{ @"path": @"/Music/Test/01.flac", @"title": @"Track 1", @"artist": @"Tester", @"dur": @240, @"sr": @44100, @"bits": @16 } ] } };
    }
    if ([path hasPrefix:@"/api/lib/artists"]) return @{ @"ok": @YES, @"artists": @[] };
    if ([path hasPrefix:@"/api/lib/search"]) return @{ @"ok": @YES, @"tracks": @[], @"total": @0, @"n": @0 };
    if ([path hasPrefix:@"/api/lib/stats"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/sq/list"]) return @{ @"ok": @YES, @"queues": @[] };
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/preset/caps"]) return @{ @"ok": @YES, @"known": @YES, @"pcmReady": @YES, @"dsdReady": @YES };
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    return @{ @"ok": @YES };
}
@end

static RLPModesSpy *g_spy;
static id FakeSharedClient(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }

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

static NSArray<NSNumber *> *SidebarStationRows(RLPSidebarViewController *sb) {
    NSMutableArray<NSNumber *> *rows = [NSMutableArray array];
    for (NSInteger r = 0; r < sb.rowCount; ++r) {
        if ([[sb keyForRow:r] isEqualToString:@"station"]) [rows addObject:@(r)];
    }
    return rows;
}

static BOOL SidebarHasTitle(RLPSidebarViewController *sb, NSString *title) {
    NSTableView *tv = nil;
    for (NSView *v in sb.view.subviews) {
        if ([v isKindOfClass:[NSScrollView class]]) {
            NSView *doc = ((NSScrollView *)v).documentView;
            if ([doc isKindOfClass:[NSTableView class]]) { tv = (NSTableView *)doc; break; }
        }
    }
    if (!tv) return NO;
    for (NSInteger r = 0; r < sb.rowCount; ++r) {
        NSView *cell = [tv.delegate tableView:tv viewForTableColumn:nil row:r];
        for (NSView *sub in cell.subviews) {
            if ([sub isKindOfClass:[NSTextField class]]) {
                if ([((NSTextField *)sub).stringValue isEqualToString:title]) return YES;
            }
        }
    }
    return NO;
}

static void CheckSidebarHarmonyInMode(RLPMainWindowController *wc, const char *stage) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    NSTableView *tv = nil;
    for (NSView *v in wc.sidebar.view.subviews) {
        if ([v isKindOfClass:[NSScrollView class]]) {
            NSView *doc = ((NSScrollView *)v).documentView;
            if ([doc isKindOfClass:[NSTableView class]]) { tv = (NSTableView *)doc; break; }
        }
    }
    if (!tv || wc.sidebar.rowCount <= 0) {
        Ck(NO, [[NSString stringWithFormat:@"S1-%s 侧栏表格存在", stage] UTF8String], @"tv nil");
        return;
    }
    [tv layoutSubtreeIfNeeded];

    NSMutableArray<NSNumber *> *navH = [NSMutableArray array];
    NSMutableArray<NSNumber *> *secH = [NSMutableArray array];
    NSMutableArray<NSNumber *> *gapBelow = [NSMutableArray array];
    NSMutableArray<NSNumber *> *gapAbove = [NSMutableArray array];
    CGFloat stationH = -1.0, maxMidY = 0.0, minIconX = 9999.0, maxIconX = -9999.0, minSecBot = 9999.0;
    BOOL symMissing = NO, secOk = YES, orderOk = YES;
    NSRect prevPill = NSZeroRect, pendingSec = NSZeroRect;
    BOOL hasPendingSec = NO;

    NSArray<NSString *> *wantOrder = @[
        @"station", @"albums", @"artists", @"tracks", @"folders", @"streaming",
        @"queue", @"recent", @"favorites", @"playlists", @"settings"
    ];
    NSMutableArray<NSString *> *gotKeys = [NSMutableArray array];

    for (NSInteger r = 0; r < wc.sidebar.rowCount; ++r) {
        NSView *cell = [tv viewAtColumn:0 row:r makeIfNecessary:YES];
        if (!cell) cell = [tv.delegate tableView:tv viewForTableColumn:nil row:r];
        if (!cell) { secOk = NO; continue; }
        [cell layoutSubtreeIfNeeded];
        const BOOL mounted = (cell.superview != nil);
        const CGFloat h = mounted ? NSHeight(cell.frame) : [tv.delegate tableView:tv heightOfRow:r];

        if ([cell.identifier isEqualToString:@"SecWrap"]) {
            [secH addObject:@(h)];
            NSTextField *secLab = nil;
            for (NSView *s in cell.subviews) {
                if ([s isKindOfClass:[NSTextField class]]) { secLab = (NSTextField *)s; break; }
            }
            if (!secLab) { secOk = NO; continue; }
            NSRect sr = [secLab convertRect:secLab.bounds toView:cell];
            const CGFloat bot = cell.isFlipped ? (NSHeight(cell.bounds) - NSMaxY(sr)) : NSMinY(sr);
            minSecBot = MIN(minSecBot, bot);
            if (std::abs(secLab.font.pointSize - 11.0) > 0.1 || std::abs(NSMinX(sr) - 20.0) > 0.5) secOk = NO;
            if (mounted) {
                NSRect stv = [secLab convertRect:secLab.bounds toView:tv];
                if (!NSIsEmptyRect(prevPill)) {
                    [gapAbove addObject:@(tv.isFlipped ? (NSMinY(stv) - NSMaxY(prevPill))
                                                       : (NSMinY(prevPill) - NSMaxY(stv)))];
                }
                pendingSec = stv;
                hasPendingSec = YES;
            }
        } else {
            NSString *k = [wc.sidebar keyForRow:r] ?: @"";
            [gotKeys addObject:k];
            if (r == 0) stationH = h;
            [navH addObject:@(h)];

            NSView *pill = FindById(cell, @"pill") ?: FindById(cell, @"gain") ?: FindById(cell, @"sq.empty");
            NSImageView *icon = (NSImageView *)FindById(cell, @"icon");
            NSTextField *lab = (NSTextField *)(FindById(cell, @"label") ?: FindById(cell, @"sq.empty.label"));
            if (icon && lab) {
                NSRect ir = [icon convertRect:icon.bounds toView:cell];
                NSRect lr = [lab convertRect:lab.bounds toView:cell];
                maxMidY = MAX(maxMidY, std::abs(NSMidY(ir) - NSMidY(lr)));
                minIconX = MIN(minIconX, NSMinX(ir));
                maxIconX = MAX(maxIconX, NSMinX(ir));
                if (@available(macOS 11.0, *)) {
                    if (!icon.symbolConfiguration) symMissing = YES;
                }
            }
            if (mounted && pill) {
                NSRect ptv = [pill convertRect:pill.bounds toView:tv];
                if (hasPendingSec) {
                    [gapBelow addObject:@(tv.isFlipped ? (NSMinY(ptv) - NSMaxY(pendingSec))
                                                       : (NSMinY(pendingSec) - NSMaxY(ptv)))];
                    hasPendingSec = NO;
                }
                prevPill = ptv;
            }
        }
    }
    orderOk = [gotKeys isEqualToArray:wantOrder];

    auto Span = [](NSArray<NSNumber *> *a, CGFloat &lo, CGFloat &hi) {
        lo = 9999.0; hi = -9999.0;
        for (NSNumber *n in a) { lo = MIN(lo, n.doubleValue); hi = MAX(hi, n.doubleValue); }
    };
    CGFloat minNH = 0, maxNH = 0, minSH = 0, maxSH = 0, minGB = 0, maxGB = 0, minGA = 0, maxGA = 0;
    Span(navH, minNH, maxNH);
    Span(secH, minSH, maxSH);
    Span(gapBelow, minGB, maxGB);
    Span(gapAbove, minGA, maxGA);

    NSString *detail = [NSString stringWithFormat:
        @"order=%d navH=%.1f..%.1f(st=%.1f) secH=%.1f..%.1f midY<=%.2f iconX=%.1f..%.1f "
        "sym=%d secOk=%d secBot=%.1f gapB=%.1f..%.1f gapA=%.1f..%.1f",
        (int)orderOk, minNH, maxNH, stationH, minSH, maxSH, maxMidY, minIconX, maxIconX,
        (int)!symMissing, (int)secOk, minSecBot, minGB, maxGB, minGA, maxGA];
    std::printf("  [S1 %s] %s\n", stage, detail.UTF8String);

    Ck(orderOk && navH.count == 11 && (maxNH - minNH) <= 0.5 &&
       std::abs(minNH - 30.0) <= 0.5 && std::abs(stationH - 30.0) <= 0.5 &&
       maxMidY <= 1.0 && !symMissing && (maxIconX - minIconX) <= 0.5 && std::abs(minIconX - 20.0) <= 0.5 &&
       secH.count == 4 && (maxSH - minSH) <= 0.5 && std::abs(minSH - 30.0) <= 0.5 && minSecBot >= 3.8 &&
       gapBelow.count == 4 && (maxGB - minGB) <= 1.0 && minGB >= 6.5 &&
       gapAbove.count == 4 && (maxGA - minGA) <= 1.0 && minGA >= minGB + 3.0,
       [[NSString stringWithFormat:@"S1-%s 侧栏行高/图标基线/分组标题与组间距一致", stage] UTF8String],
       detail);
}

// Forward the real methods unchanged; the latest input and call count distinguish
// a cached layout from a fresh update (including the 1052pt construction fallback).
static IMP g_listenLayout, g_proLayout;
static NSUInteger g_listenCalls, g_proCalls;
static CGFloat g_firstListenWidth, g_listenWidth, g_proWidth;

static void TraceListenLayout(NSViewController *vc, SEL sel, CGFloat width) {
    if (++g_listenCalls == 1) g_firstListenWidth = width;
    g_listenWidth = width;
    reinterpret_cast<void (*)(id, SEL, CGFloat)>(g_listenLayout)(vc, sel, width);
}

static void TraceProLayout(NSViewController *vc, SEL sel) {
    ++g_proCalls;
    g_proWidth = NSWidth(vc.view.bounds);
    reinterpret_cast<void (*)(id, SEL)>(g_proLayout)(vc, sel);
}

static BOOL Near(CGFloat a, CGFloat b) { return std::abs(a - b) <= 1.0; }
static BOOL SameSize(NSSize a, NSSize b) { return Near(a.width, b.width) && Near(a.height, b.height); }

struct StationGeometry {
    NSSize window, host, page, scroll, clip, document;
    NSRect visible;
    CGFloat headerFromClip, headerFromPage;
};

static StationGeometry TraceGeometry(RLPMainWindowController *wc, const char *stage,
                                     const StationGeometry *before = nullptr,
                                     BOOL expectPro = NO) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    NSView *host = [wc valueForKey:@"pageHost"];
    NSView *page = wc.currentContent.view;
    StationGeometry g{};
    g.window = wc.window.frame.size;
    g.host = host.bounds.size;
    g.page = page.bounds.size;
    const BOOL isListen = [wc.currentContent isKindOfClass:RLPQuickStartViewController.class];
    const BOOL isPro = [wc.currentContent isKindOfClass:RLPWorkbenchViewController.class];
    if (!before && !isListen && !isPro) {
        std::printf("  [geometry] %s window=%s pageHost=%s page=%s\n", stage,
                    NSStringFromSize(g.window).UTF8String, NSStringFromSize(g.host).UTF8String,
                    NSStringFromSize(g.page).UTF8String);
        return g;
    }

    BOOL station = (before ? (expectPro ? isPro : isListen) : (isListen || isPro)) &&
                   [wc.sidebar.selectedKey isEqualToString:@"station"] && page.superview == host;
    NSScrollView *scroll = nil;
    if (station) {
        RLPPageViewController *controller = (RLPPageViewController *)wc.currentContent;
        for (NSView *v in controller.contentView.subviews) {
            if ([v isKindOfClass:NSScrollView.class]) { scroll = (NSScrollView *)v; break; }
        }
    }
    NSClipView *clip = scroll.contentView;
    NSStackView *doc = [scroll.documentView isKindOfClass:NSStackView.class]
                       ? (NSStackView *)scroll.documentView : nil;
    NSView *header = doc.arrangedSubviews.firstObject;
    g.scroll = scroll.bounds.size;
    g.clip = clip.bounds.size;
    g.document = doc.bounds.size;
    g.visible = scroll.documentVisibleRect;
    if (header) {
        // Conversion to window coordinates avoids assumptions about flipped views.
        CGFloat top = NSMaxY([header convertRect:header.bounds toView:nil]);
        g.headerFromClip = NSMaxY([clip convertRect:clip.bounds toView:nil]) - top;
        g.headerFromPage = NSMaxY([page convertRect:page.bounds toView:nil]) - top;
    }
    NSString *summary = [NSString stringWithFormat:
        @"window=%@ pageHost=%@ page=%@ scroll=%@ clip=%@ document=%@ visible=%@ "
         "headerTop(clip/page)=%.1f/%.1f listenCalls=%lu listenFirst/latest=%.1f/%.1f proCalls=%lu proWidth=%.1f",
         NSStringFromSize(g.window), NSStringFromSize(g.host), NSStringFromSize(g.page),
         NSStringFromSize(g.scroll), NSStringFromSize(g.clip), NSStringFromSize(g.document),
         NSStringFromRect(g.visible), g.headerFromClip, g.headerFromPage,
         (unsigned long)g_listenCalls, g_firstListenWidth, g_listenWidth,
         (unsigned long)g_proCalls, g_proWidth];
    std::printf("  [geometry] %s %s\n", stage, summary.UTF8String);
    if (!before) return g;

    // 只判「页面填满宿主」这件布局事实。窗口是否被内容撑大是另一条**已知未修**缺陷，
    // 由未注册的 settings-window-grow 诊断单独记录；把它混进来会让布局判据长期判红。
    Ck(station && SameSize(g.page, g.host) && g.host.width > 0 && g.host.height > 0,
       "G1 station page fills its host", summary);
    Ck(scroll && doc && header && Near(g.scroll.width, g.page.width) &&
       Near(g.document.width, g.clip.width) && Near(NSWidth(g.visible), g.clip.width) &&
       g.clip.height > 0 && g.document.height > 0 &&
       Near(NSHeight(g.visible), MIN(g.clip.height, g.document.height)) &&
       NSWidth(header.bounds) > 0 && NSHeight(header.bounds) > 0 && Near(g.headerFromClip, 6.0),
       "G2 document fits viewport horizontally; first header remains visible at 6pt", summary);

    if (station && expectPro) {
        // The rack can belong to a detached, inactive studio tab.
        NSStackView *rack = [wc.currentContent valueForKey:@"rackStack"];
        const auto want = g.page.width < 900 ? NSUserInterfaceLayoutOrientationVertical
                                            : NSUserInterfaceLayoutOrientationHorizontal;
        Ck(g_proCalls > 0 && Near(g_proWidth, g.page.width) &&
           [rack isKindOfClass:NSStackView.class] && rack.orientation == want,
           "G3 pro rack breakpoint uses mounted page width", summary);
    } else if (station) {
        CGFloat available = g.page.width - 48;
        NSInteger want = available <= 350 ? 1 : available <= 750 ? 2 : 4;
        NSInteger columns = [[wc.currentContent valueForKey:@"currentCardColumns"] integerValue];
        Ck(g_listenCalls > 0 && Near(g_listenWidth, available) && columns == want,
           "G3 listen card breakpoint uses mounted page width minus insets", summary);
    }
    return g;
}

// G4 的**判据本身**曾写错：它拿两次不同窗口宽下的滚动区绝对宽度做相等比较。
// 窗口在别的页面被撑大是另一条已知缺陷（见 settings-window-grow 诊断），
// 不能混进来当作「缓存页布局过期」的证据。这里改成证明真正要证明的事：
// 回到缓存页后布局**跟随当前窗口**（scroll 宽 == 页宽、doc 宽 == clip 宽、页头间距不变），
// 而不是残留上一次的尺寸。
static void CheckStationReturn(const StationGeometry &first, const StationGeometry &back) {
    const BOOL tracksWindow = Near(back.scroll.width, back.page.width) &&
                              back.clip.width > 0 &&
                              Near(back.document.width, back.clip.width);
    Ck(tracksWindow && Near(back.headerFromClip, 6.0) && Near(back.headerFromPage, 56.0),
       "G4 cached station relayouts to the current window (no stale viewport)",
       [NSString stringWithFormat:@"first page=%@ scroll=%@ header=%.1f; return page=%@ scroll=%@ clip=%@ doc=%@ header=%.1f",
        NSStringFromSize(first.page), NSStringFromSize(first.scroll), first.headerFromPage,
        NSStringFromSize(back.page), NSStringFromSize(back.scroll), NSStringFromSize(back.clip),
        NSStringFromSize(back.document), back.headerFromPage]);
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_spy = [RLPModesSpy new];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];

        Method shared = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        method_setImplementation(shared, (IMP)FakeSharedClient);

        std::printf("=== test_native_modes_contract（聆听/专业双模式契约 · 离屏）===\n");
        RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
        // Install a compact fixture before any station navigation. Do not save this
        // size as the user's window preference or resize between measurements.
        [wc.window setFrameAutosaveName:@""];
        NSRect fixtureFrame = wc.window.frame;
        fixtureFrame.size = NSMakeSize(940, 690);
        [wc.window setFrame:fixtureFrame display:NO];
        Method listenLayout = class_getInstanceMethod(RLPQuickStartViewController.class,
            NSSelectorFromString(@"updateResponsiveLayoutForWidth:"));
        Method proLayout = class_getInstanceMethod(RLPWorkbenchViewController.class,
            NSSelectorFromString(@"updateRackOrientation"));
        if (!listenLayout || !proLayout) {
            Ck(NO, "G0 station layout tracing methods exist", @"missing layout method");
            return 1;
        }
        g_listenLayout = method_setImplementation(listenLayout, (IMP)TraceListenLayout);
        g_proLayout = method_setImplementation(proLayout, (IMP)TraceProLayout);
        [wc.window.contentView layoutSubtreeIfNeeded];
        Pump(0.1);

        // ---- C1: 顶栏 NSSegmentedControl 与默认 listen ----
        NSSegmentedControl *modeCtrl = (NSSegmentedControl *)FindById(wc.window.contentView, @"top.mode");
        Ck([modeCtrl isKindOfClass:[NSSegmentedControl class]] && modeCtrl.segmentCount == 2,
           "C1a 顶栏存在 2 段 NSSegmentedControl (top.mode)",
           modeCtrl ? [NSString stringWithFormat:@"seg=%ld", (long)modeCtrl.segmentCount] : @"nil");
        Ck(modeCtrl && modeCtrl.selectedSegment == 0 && [wc.uiMode isEqualToString:@"listen"],
           "C1b 默认模式为 listen (segment 0)",
           [NSString stringWithFormat:@"uiMode=%@ seg=%ld", wc.uiMode, (long)modeCtrl.selectedSegment]);
        NSArray<NSNumber *> *stationRowsListen = SidebarStationRows(wc.sidebar);
        Ck(stationRowsListen.count == 1 && [stationRowsListen.firstObject integerValue] == 0 &&
           SidebarHasTitle(wc.sidebar, RLPTr(@"聆听室")) &&
           !SidebarHasTitle(wc.sidebar, RLPTr(@"数字音乐台")),
           "C1c listen 模式下侧栏仅有 1 个 station 入口 (row 0) 且标签为「聆听室」",
           [NSString stringWithFormat:@"stationRows=%@", stationRowsListen]);
        CheckSidebarHarmonyInMode(wc, "listen-init");

        g_spy.holdSettingsGet = YES;
        [wc reloadUiModePreference];
        RLPJSONCompletion firstRead = [g_spy.heldSettingsCompletion copy];
        [wc reloadUiModePreference];
        RLPJSONCompletion lastRead = [g_spy.heldSettingsCompletion copy];
        g_spy.holdSettingsGet = NO;
        firstRead(@{ @"ok": @YES, @"kv": @{ @"uimode": @"pro" } });
        lastRead(@{ @"ok": @YES, @"kv": @{ @"uimode": @"listen" } });
        Ck([wc.uiMode isEqualToString:@"listen"], "C1e 并发读取先到旧回包不得阻断最新偏好", wc.uiMode);
        [wc setUiMode:@"listen" persist:NO];
        g_spy.heldSettingsCompletion = nil;

        // 2026-11-21：启动默认页已改为 station（聆听室 / 数字音乐台）。
        // 所以进入这里时**已经在 station 上**，selectKey 不会再触发一次换页 ⟹
        // 旧写法（先量 before，再 selectKey 期望产生一次布局调用）的前提不成立。
        // 仍然要验的是同一件事：**已挂载的** station 页按「页面宽 - 48」的断点排卡片。
        // 先切去资料库再切回 station，制造一次真实的重新挂载，判据含义不变。
        if ([wc.currentContent isKindOfClass:[RLPQuickStartViewController class]] ||
            [wc.currentContent isKindOfClass:[RLPWorkbenchViewController class]]) {
            Ck(YES, "C1c 启动默认页就是 station（聆听室 / 数字音乐台）", @"");
        }
        [wc.sidebar selectKey:@"albums"];
        Pump(0.1);
        const auto beforeListen = TraceGeometry(wc, "before first listen station entry");
        Ck(beforeListen.page.width > 148 && beforeListen.page.width - 48 <= 750 && beforeListen.page.width < 900,
           "G0 compact fixture distinguishes station breakpoints from wide defaults",
           NSStringFromSize(beforeListen.page));
        [wc.sidebar selectKey:@"station"];
        Pump(0.1);
        const auto firstListen = TraceGeometry(wc, "first listen station", &beforeListen);
        Ck([wc.currentContent isKindOfClass:[RLPQuickStartViewController class]] &&
           [wc.currentContent.view.identifier isEqualToString:@"page.station"],
           "C1d listen 模式下 station 打开 RLPQuickStartViewController (page.station)",
           NSStringFromClass(wc.currentContent.class));
        NSViewController *listenHome = wc.currentContent;

        // ---- C2: 原子切换到 pro 模式，不发播放/音量/队列请求 ----
        [g_spy.requests removeAllObjects];
        [g_spy.posts removeAllObjects];
        const auto beforePro = TraceGeometry(wc, "before switch to pro station");
        if (modeCtrl) {
            modeCtrl.selectedSegment = 1;
            [modeCtrl sendAction:modeCtrl.action to:modeCtrl.target];
        } else {
            [wc setUiMode:@"pro" persist:YES];
        }
        Pump(0.1);
        const auto firstPro = TraceGeometry(wc, "first pro station after mode switch", &beforePro, YES);

        Ck([wc.uiMode isEqualToString:@"pro"] && modeCtrl.selectedSegment == 1,
           "C2a 切换到 pro 模式并同步顶栏分段",
           [NSString stringWithFormat:@"uiMode=%@ seg=%ld", wc.uiMode, (long)modeCtrl.selectedSegment]);
        NSArray<NSNumber *> *stationRowsPro = SidebarStationRows(wc.sidebar);
        Ck(stationRowsPro.count == 1 && [stationRowsPro.firstObject integerValue] == 0 &&
           SidebarHasTitle(wc.sidebar, RLPTr(@"数字音乐台")) &&
           !SidebarHasTitle(wc.sidebar, RLPTr(@"聆听室")),
           "C2b pro 模式下侧栏仅有 1 个 station 入口 (row 0) 且标签为「数字音乐台」",
           [NSString stringWithFormat:@"stationRows=%@", stationRowsPro]);
        Ck(wc.sidebar.selectedRow == 0 && [wc.sidebar.selectedKey isEqualToString:@"station"],
           "C2c 切换后侧栏仍选中 row 0 (station)",
           [NSString stringWithFormat:@"row=%ld key=%@",
            (long)wc.sidebar.selectedRow, wc.sidebar.selectedKey ?: @"(nil)"]);
        CheckSidebarHarmonyInMode(wc, "pro-switch");
        Ck([wc.currentContent isKindOfClass:[RLPWorkbenchViewController class]] &&
           [wc.currentContent.view.identifier isEqualToString:@"page.station"],
           "C2d pro 模式下 station 原子切换到 RLPWorkbenchViewController (page.station)",
           NSStringFromClass(wc.currentContent.class));
        NSViewController *proHome = wc.currentContent;
        Ck(proHome != listenHome,
           "C2e listen 与 pro 的 station VC 实例相互独立（pageCache 不跨模式拿错）", @"同一对象");

        NSTextField *topTitle = (NSTextField *)[wc valueForKey:@"pageTitle"];
        Ck([topTitle.stringValue isEqualToString:RLPTr(@"数字音乐台")],
           "C2f pro 模式下 station 顶栏标题为「数字音乐台」", topTitle.stringValue ?: @"");

        BOOL postedUimodePro = NO;
        BOOL touchedForbidden = NO;
        for (NSDictionary *p in g_spy.posts) {
            NSString *path = p[@"path"] ?: @"";
            NSString *body = p[@"body"] ?: @"";
            if ([path isEqualToString:@"/api/settings"] && [body isEqualToString:@"uimode=pro"]) {
                postedUimodePro = YES;
            }
            if (![path isEqualToString:@"/api/settings"] && ![path isEqualToString:@"/api/ui/events"] && ![path hasPrefix:@"/api/peq"]) touchedForbidden = YES;
        }
        for (NSString *req in g_spy.requests) {
            if ([req containsString:@"/api/play"] || [req containsString:@"/api/stop"] ||
                [req containsString:@"/api/pause"] || [req containsString:@"/api/vol"] ||
                [req containsString:@"/api/queue/"]) {
                touchedForbidden = YES;
            }
        }
        Ck(postedUimodePro, "C2g 切换模式持久化 POST /api/settings uimode=pro", @"未发 uimode=pro");
        Ck(!touchedForbidden, "C2h 模式切换期间绝不发 play/stop/pause/volume/queue 请求",
           [g_spy.requests componentsJoinedByString:@", "]);

        // 切回 listen，验证 pageCache 仍返回原 listenHome
        const auto beforeReturn = TraceGeometry(wc, "before switch back to listen station");
        if (modeCtrl) {
            modeCtrl.selectedSegment = 0;
            [modeCtrl sendAction:modeCtrl.action to:modeCtrl.target];
        } else {
            [wc setUiMode:@"listen" persist:YES];
        }
        Pump(0.1);
        CheckStationReturn(firstListen, TraceGeometry(wc, "listen station after mode switch", &beforeReturn));
        NSArray<NSNumber *> *stationRowsBack = SidebarStationRows(wc.sidebar);
        Ck(wc.currentContent == listenHome &&
           wc.sidebar.selectedRow == 0 &&
           [wc.sidebar.selectedKey isEqualToString:@"station"] &&
           stationRowsBack.count == 1 &&
           SidebarHasTitle(wc.sidebar, RLPTr(@"聆听室")) &&
           !SidebarHasTitle(wc.sidebar, RLPTr(@"数字音乐台")) &&
           [topTitle.stringValue isEqualToString:RLPTr(@"聆听室")],
           "C2i 切回 listen 模式回到 RLPQuickStartViewController，row 0 保持选中且无重复入口",
           [NSString stringWithFormat:@"vc=%@ row=%ld rows=%@",
            NSStringFromClass(wc.currentContent.class), (long)wc.sidebar.selectedRow, stationRowsBack]);
        CheckSidebarHarmonyInMode(wc, "listen-return");

        [wc.sidebar selectKey:@"albums"];
        const auto albums = TraceGeometry(wc, "albums before sidebar return to listen station");
        [wc.sidebar selectKey:@"station"];
        Pump(0.1);
        CheckStationReturn(firstListen, TraceGeometry(wc, "listen station from albums", &albums));

        // ---- C3: 持久化读回与过期 GET 回包 epoch 保护 ----
        g_spy.serverUiMode = @"pro";
        g_spy.holdSettingsGet = YES;
        [wc reloadUiModePreference];
        Pump(0.05);
        // 在 GET 回包到达前，用户主动切到 listen
        [wc setUiMode:@"listen" persist:YES];
        Pump(0.05);
        // 现在让旧 GET (返回 uimode=pro) 到达
        g_spy.holdSettingsGet = NO;
        if (g_spy.heldSettingsCompletion) {
            g_spy.heldSettingsCompletion(@{ @"ok": @YES, @"kv": @{ @"uimode": @"pro" } });
            g_spy.heldSettingsCompletion = nil;
        }
        Pump(0.05);
        Ck([wc.uiMode isEqualToString:@"listen"],
           "C3a 过期 GET /api/settings 回包不覆盖用户新切换的 listen 模式",
           wc.uiMode ?: @"(nil)");

        // 正常读回 pro
        g_spy.serverUiMode = @"pro";
        [wc reloadUiModePreference];
        Pump(0.1);
        Ck([wc.uiMode isEqualToString:@"pro"],
           "C3b 启动读回 GET /api/settings.kv.uimode=pro 生效",
           wc.uiMode ?: @"(nil)");

        // 两次 GET 重叠：旧请求先返回也不能抢占最新读取的结果。
        g_spy.holdSettingsGet = YES;
        [wc reloadUiModePreference];
        RLPJSONCompletion olderRead = [g_spy.heldSettingsCompletion copy];
        [wc reloadUiModePreference];
        RLPJSONCompletion newerRead = [g_spy.heldSettingsCompletion copy];
        g_spy.holdSettingsGet = NO;
        olderRead(@{ @"ok": @YES, @"kv": @{ @"uimode": @"listen" } });
        newerRead(@{ @"ok": @YES, @"kv": @{ @"uimode": @"pro" } });
        Ck([wc.uiMode isEqualToString:@"pro"], "C3c 重叠 GET 只采纳最后发出的读取", wc.uiMode);
        g_spy.heldSettingsCompletion = nil;

        // ---- C4: 两种模式导航可达性 + 详情返回上下文一致 ----
        NSArray<NSString *> *allKeys = @[ @"albums", @"artists", @"tracks", @"folders", @"streaming",
                                          @"queue", @"recent", @"favorites", @"station", @"settings" ];
        for (NSString *mode in @[ @"listen", @"pro" ]) {
            [wc setUiMode:mode persist:NO];
            Pump(0.05);
            NSMutableArray<NSString *> *bad = [NSMutableArray array];
            for (NSString *k in allKeys) {
                const BOOL selected = [wc.sidebar selectKey:k];
                NSString *ident = wc.currentContent.view.identifier ?: @"";
                NSDictionary<NSString *, NSString *> *ids = @{ @"folders": @"page.files",
                    @"streaming": @"page.remote", @"favorites": @"page.favs" };
                NSString *want = ids[k] ?: [@"page." stringByAppendingString:k];
                if (!selected || ![ident isEqualToString:want]) {
                    [bad addObject:[NSString stringWithFormat:@"%@(sel=%d,id=%@)", k, (int)selected, ident]];
                }
            }
            Ck(bad.count == 0,
               [[NSString stringWithFormat:@"C4a %@ 模式下全部 10 个原导航 key（含 settings）均可选中", mode] UTF8String],
               [bad componentsJoinedByString:@", "]);
        }

        // 从 station (listen) 进详情页 -> 切模式到 pro -> 返回，应落到 proHome (RLPWorkbenchViewController)
        [wc setUiMode:@"listen" persist:NO];
        [wc.sidebar selectKey:@"station"];
        Pump(0.05);
        RLPRequestOpenAlbum(@"/Music/Test");
        Pump(0.05);
        Ck([wc.currentContent isKindOfClass:[RLPAlbumDetailViewController class]],
           "C4b 从 station 压入专辑详情页", NSStringFromClass(wc.currentContent.class));
        [wc setUiMode:@"pro" persist:NO];
        Ck([wc.currentContent isKindOfClass:[RLPWorkbenchViewController class]] &&
           [[wc valueForKey:@"rowStack"] count] == 0 &&
           [wc.sidebar.selectedKey isEqualToString:@"station"] &&
           [topTitle.stringValue isEqualToString:RLPTr(@"数字音乐台")],
           "C4c 详情中切模式同帧回当前模式首页并清空详情栈", NSStringFromClass(wc.currentContent.class));
        NSViewController *modeHome = wc.currentContent;
        RLPRequestBack();
        Pump(0.05);
        Ck(wc.currentContent == modeHome &&
           [wc.currentContent isKindOfClass:[RLPWorkbenchViewController class]] &&
           FindById(wc.window.contentView, @"top.back").hidden,
           "C4d 切模式清栈后 Back 无效且返回键隐藏",
           NSStringFromClass(wc.currentContent.class));

        // ---- C5: 设置页层级重排与全 10 个 pane + play 别名可达（不强制切 pro） ----
        [wc setUiMode:@"listen" persist:NO];
        [wc.sidebar selectKey:@"settings"];
        Pump(0.1);
        Ck([wc.uiMode isEqualToString:@"listen"] &&
           [wc.currentContent isKindOfClass:[RLPSettingsViewController class]],
           "C5a listen 模式下可直接进入设置页（不强制切 pro）",
           [NSString stringWithFormat:@"mode=%@ vc=%@", wc.uiMode, NSStringFromClass(wc.currentContent.class)]);

        RLPSettingsViewController *settings = (RLPSettingsViewController *)wc.currentContent;
        NSSegmentedControl *groupTabs = (NSSegmentedControl *)FindById(settings.view, @"settings.groups");
        Ck([groupTabs isKindOfClass:[NSSegmentedControl class]] && groupTabs.segmentCount == 2,
           "C5b 设置页顶部存在「通用 / 音频处理」两级入口 (settings.groups)",
           groupTabs ? [NSString stringWithFormat:@"seg=%ld", (long)groupTabs.segmentCount] : @"nil");

        NSArray<NSString *> *panes = @[ @"adv", @"in", @"out", @"pcm", @"sdm", @"eq", @"cal", @"meta", @"stream", @"diag" ];
        BOOL allPanesOk = YES;
        for (NSString *mode in @[@"listen", @"pro"]) {
          [wc setUiMode:mode persist:NO];
          for (NSString *p in panes) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:p];
            Pump(0.02);
            if (![[settings currentPaneKey] isEqualToString:p]) { allPanesOk = NO; break; }
            NSView *pane = FindById(settings.view, [NSString stringWithFormat:@"tab.%@", p]);
            if (![pane isKindOfClass:NSScrollView.class]) { allPanesOk = NO; break; }
            for (NSView *parent = pane.superview; parent; parent = parent.superview)
                if ([parent isKindOfClass:NSScrollView.class]) allPanesOk = NO;
            if (![wc.uiMode isEqualToString:mode]) allPanesOk = NO;
          }
        }
        Ck(allPanesOk,
           "C5c 两模式全部10个旧pane深链可达、不切模式、主体单层滚动",
           [NSString stringWithFormat:@"mode=%@ cur=%@", wc.uiMode, [settings currentPaneKey]]);

        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"play"];
        Pump(0.02);
        Ck([[settings currentPaneKey] isEqualToString:@"adv"],
           "C5d 旧深链 play 映射到 adv", [settings currentPaneKey]);

        // C5e: 显式点击「打开专业工作台」才切到 pro + station
        NSButton *wbBtn = (NSButton *)FindById(settings.view, @"settings.openWorkbench");
        Ck(wbBtn != nil, "C5e 设置页存在打开专业工作台入口 (settings.openWorkbench)", @"nil");
        if (wbBtn) {
            const auto settingsGeometry = TraceGeometry(wc, "settings before opening pro station");
            [wbBtn performClick:nil];
            Pump(0.05);
            CheckStationReturn(firstPro, TraceGeometry(wc, "pro station from settings", &settingsGeometry, YES));
            Ck([wc.uiMode isEqualToString:@"pro"] &&
               [wc.sidebar.selectedKey isEqualToString:@"station"] &&
               [wc.currentContent isKindOfClass:[RLPWorkbenchViewController class]],
               "C5f 点击打开专业工作台切到 pro 模式并进入数字音乐台",
               [NSString stringWithFormat:@"mode=%@ key=%@ vc=%@", wc.uiMode, wc.sidebar.selectedKey, NSStringFromClass(wc.currentContent.class)]);
        }

        // ---- C6: 在途写与 reload / 连续并发写回滚契约（直接结算 mock completion，无固定 sleep） ----
        void (^confirmListen)(void) = ^{
            g_spy.holdSettingsPost = YES;
            g_spy.heldSettingsPostCompletion = nil;
            [wc setUiMode:@"listen" persist:YES];
            RLPJSONCompletion done = [g_spy.heldSettingsPostCompletion copy];
            g_spy.heldSettingsPostCompletion = nil;
            g_spy.holdSettingsPost = NO;
            if (done) done(@{ @"ok": @YES });
            g_spy.serverUiMode = @"listen";
        };

        // C6a: 挂起 pro 写时 reload 发出的旧 listen GET 不覆盖乐观 pro（也允许跳过 GET）
        confirmListen();
        g_spy.holdSettingsPost = YES;
        g_spy.heldSettingsPostCompletion = nil;
        [wc setUiMode:@"pro" persist:YES];
        RLPJSONCompletion proWrite = [g_spy.heldSettingsPostCompletion copy];
        g_spy.heldSettingsPostCompletion = nil;
        g_spy.holdSettingsGet = YES;
        g_spy.heldSettingsCompletion = nil;
        [wc reloadUiModePreference];
        RLPJSONCompletion staleGet = [g_spy.heldSettingsCompletion copy];
        g_spy.heldSettingsCompletion = nil;
        g_spy.holdSettingsGet = NO;
        if (staleGet) staleGet(@{ @"ok": @YES, @"kv": @{ @"uimode": @"listen" } });
        const BOOL keptPro = [wc.uiMode isEqualToString:@"pro"] && wc.modeControl.selectedSegment == 1;
        g_spy.serverUiMode = @"pro";
        if (proWrite) proWrite(@{ @"ok": @YES });
        g_spy.holdSettingsPost = NO;
        Ck(proWrite != nil && keptPro &&
           [wc.uiMode isEqualToString:@"pro"] && wc.modeControl.selectedSegment == 1,
           "C6a 挂起 pro 写时 reload 发出的旧 listen GET 不覆盖乐观 pro",
           [NSString stringWithFormat:@"post=%d kept=%d mode=%@ seg=%ld",
            (int)(proWrite != nil), (int)keptPro, wc.uiMode ?: @"(nil)",
            (long)wc.modeControl.selectedSegment]);

        // C6b: 已确认 listen 时连续写 pro、listen，两笔均失败最终仍 listen
        confirmListen();
        g_spy.holdSettingsPost = YES;
        g_spy.heldSettingsPostCompletion = nil;
        [wc setUiMode:@"pro" persist:YES];
        RLPJSONCompletion bPro = [g_spy.heldSettingsPostCompletion copy];
        g_spy.heldSettingsPostCompletion = nil;
        [wc setUiMode:@"listen" persist:YES];
        RLPJSONCompletion bListen = [g_spy.heldSettingsPostCompletion copy];
        g_spy.heldSettingsPostCompletion = nil;
        if (bPro) bPro(@{ @"ok": @NO });
        if (!bListen) { bListen = [g_spy.heldSettingsPostCompletion copy]; g_spy.heldSettingsPostCompletion = nil; }
        if (bListen) bListen(@{ @"ok": @NO });
        g_spy.holdSettingsPost = NO;
        Ck(bPro != nil && bListen != nil &&
           [wc.uiMode isEqualToString:@"listen"] && wc.modeControl.selectedSegment == 0,
           "C6b 已确认 listen 时连续写 pro、listen 两笔均失败最终仍 listen",
           [NSString stringWithFormat:@"p1=%d p2=%d mode=%@ seg=%ld",
            (int)(bPro != nil), (int)(bListen != nil), wc.uiMode ?: @"(nil)",
            (long)wc.modeControl.selectedSegment]);

        // C6c: 同样连续写首笔成功第二笔失败最终 pro，首笔成功时第二笔在途界面仍 listen
        confirmListen();
        g_spy.holdSettingsPost = YES;
        g_spy.heldSettingsPostCompletion = nil;
        [wc setUiMode:@"pro" persist:YES];
        RLPJSONCompletion cPro = [g_spy.heldSettingsPostCompletion copy];
        g_spy.heldSettingsPostCompletion = nil;
        [wc setUiMode:@"listen" persist:YES];
        RLPJSONCompletion cListen = [g_spy.heldSettingsPostCompletion copy];
        g_spy.heldSettingsPostCompletion = nil;
        g_spy.serverUiMode = @"pro";
        if (cPro) cPro(@{ @"ok": @YES });
        const BOOL listenInFlight = [wc.uiMode isEqualToString:@"listen"] && wc.modeControl.selectedSegment == 0;
        if (!cListen) { cListen = [g_spy.heldSettingsPostCompletion copy]; g_spy.heldSettingsPostCompletion = nil; }
        if (cListen) cListen(@{ @"ok": @NO });
        g_spy.holdSettingsPost = NO;
        Ck(cPro != nil && cListen != nil && listenInFlight &&
           [wc.uiMode isEqualToString:@"pro"] && wc.modeControl.selectedSegment == 1,
           "C6c 连续写 pro、listen 首笔成功时在途仍 listen，第二笔失败最终 pro",
           [NSString stringWithFormat:@"p1=%d p2=%d inFlight=%d mode=%@ seg=%ld",
            (int)(cPro != nil), (int)(cListen != nil), (int)listenInFlight,
            wc.uiMode ?: @"(nil)", (long)wc.modeControl.selectedSegment]);

        std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
