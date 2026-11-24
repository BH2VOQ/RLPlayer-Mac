// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_window_fit_contract.mm — 主窗口尺寸不被页面内容 fitting 宽撑大/锁死 + 900x600 顶栏几何契约
//
// 验证目标（纯 AppKit 离线，Accessory，backend=null，volume=-120，不出声、不碰 8899、不动键鼠）：
//   R1 起始 1180x760，切 albums → station（聆听室）→ settings(meta) → station，每次 pump 后 frame 仍 1180x760 ±1；
//   R2 setFrame 900x600，pump 后 frame 仍 900x600；contentView 宽高 == 900x600（FullSize 保留标题栏 32pt）；
//   R3 900x600 下进入 meta（含展开高级选项）、再回 station，frame 仍 900x600；再 set 1180x760 仍 1180x760；
//   R4 1394x880 下切换聆听室 / 专业工作台（setUiMode），frame 不变；
//   R5 覆盖 orderFront 可见路径（Accessory，不 makeKey），可见后 frame 仍不被内容改变；
//   R6 900x600 下顶栏控件（search / top.mode / top.queue / top.scan / top.np 及标题区）都在 topbar bounds 内且两两不交叠；
//   R7 900x600 与 1180x760 下进入 pro 工作台：window frame 不被撑大，Hero >=120pt、封面 96/116、首屏可见、信号链/A-B/机架无溢出不重叠。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPSettingsViewController.h"
#import "RLPQuickStartViewController.h"
#import "RLPWorkbenchViewController.h"
#import "RLPTheme.h"
#import "RLPSupport.h"
#import "RLPPlaybackBarView.h"

#include <cmath>
#include <cstdio>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) {
        std::printf("  [PASS] %s\n", what);
        ++g_pass;
    } else {
        std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: "");
        ++g_fail;
    }
}

#pragma mark - Spy 客户端（backend=null, volume=-120, 不起核/不出声）

@interface RLPFitSpyClient : NSObject
@property (nonatomic, copy) NSString *uiMode;
@property (nonatomic, copy) NSArray<NSDictionary *> *savedQueuesFixture;
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *customDevicesFixture;
@property (nonatomic, copy, nullable) NSDictionary *customStatusFixture;
@property (nonatomic, assign) NSInteger prepareForShutdownCalls;
@end

@interface RLPWorkbenchViewController (FitContractAccess)
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSImageView *trackCover;
@property (nonatomic, strong) NSTextField *trackTitle;
@property (nonatomic, strong) NSTextField *heroSpecLabel;
@property (nonatomic, strong) NSStackView *topDeviceBar;
@property (nonatomic, strong) NSPopUpButton *topDevicePopup;
@property (nonatomic, strong) NSView *chainCard;
@property (nonatomic, strong) NSStackView *rackStack;
@property (nonatomic, strong) NSView *rackPCM;
@property (nonatomic, strong) NSView *rackDSD;
@property (nonatomic, strong) NSView *rackOutput;
@property (nonatomic, assign) NSInteger rackColumns;
@property (nonatomic, assign) BOOL abCompact;
@property (nonatomic, strong) NSMutableArray<NSView *> *abSlotCards;
@end

@implementation RLPFitSpyClient
- (instancetype)init {
    self = [super init];
    if (self) {
        _uiMode = @"listen";
        _savedQueuesFixture = @[];
    }
    return self;
}
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)prepareForShutdown { ++self.prepareForShutdownCalls; }
- (void)shutdown {}
- (id)jsonWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body {
    (void)body;
    if ([method isEqualToString:@"POST"]) return @{ @"ok": @YES };
    return [self fixtureForPath:path ?: @""];
}
- (NSData *)dataWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body
               contentType:(NSString **)contentType {
    (void)method; (void)path; (void)body; (void)contentType;
    return nil;
}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    NSDictionary *json = [self fixtureForPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    if ([path isEqualToString:@"/api/settings"] && [body containsString:@"uimode="]) {
        if ([body containsString:@"uimode=pro"]) self.uiMode = @"pro";
        else if ([body containsString:@"uimode=listen"]) self.uiMode = @"listen";
    }
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
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
                @"uimode": self.uiMode ?: @"listen",
                @"backend": @"null",
                @"volume": @"-120",
                @"theme": @"light",
                @"channels": @"0",
            }
        };
    }
    if ([path hasPrefix:@"/api/status"]) {
        if (self.customStatusFixture) return self.customStatusFixture;
        return @{ @"ok": @YES, @"playing": @NO, @"paused": @NO, @"volDb": @(-120) };
    }
    if ([path hasPrefix:@"/api/queue"]) {
        return @{ @"ok": @YES, @"items": @[], @"index": @0, @"mode": @0 };
    }
    if ([path hasPrefix:@"/api/lib/albums"]) {
        NSMutableArray *a = [NSMutableArray array];
        for (int i = 0; i < 60; ++i) {
            [a addObject:@{
                @"k": [NSString stringWithFormat:@"a%03d", i],
                @"name": [NSString stringWithFormat:@"Album %03d with a fairly long title", i],
                @"artist": @"Artist Name",
                @"year": @(2000 + i % 20),
                @"n": @12, @"dur": @(3600.0), @"sr": @44100, @"bits": @16, @"cv": @NO
            }];
        }
        return @{ @"ok": @YES, @"albums": a };
    }
    if ([path hasPrefix:@"/api/lib/album?"]) {
        return @{
            @"ok": @YES,
            @"album": @{
                @"k": @"a000",
                @"name": @"Album 000 with a fairly long title for topbar fit verification",
                @"artist": @"Artist Name",
                @"year": @2000,
                @"tracks": @[
                    @{ @"path": @"/Music/a000/01.flac", @"title": @"Track 1", @"artist": @"Artist Name",
                       @"dur": @240, @"sr": @44100, @"bits": @16 }
                ]
            }
        };
    }
    if ([path hasPrefix:@"/api/lib/artists"]) return @{ @"ok": @YES, @"artists": @[] };
    if ([path hasPrefix:@"/api/lib/search"]) return @{ @"ok": @YES, @"tracks": @[], @"total": @0, @"n": @0 };
    if ([path hasPrefix:@"/api/lib/stats"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/lib/roots"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/sq/list"]) return @{ @"ok": @YES, @"queues": self.savedQueuesFixture ?: @[] };
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": self.customDevicesFixture ?: @[] };
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/preset/caps"]) return @{ @"ok": @YES, @"known": @YES, @"pcmReady": @YES, @"dsdReady": @YES };
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    if ([path hasPrefix:@"/api/profiles"]) return @{ @"ok": @YES, @"profiles": @[] };
    if ([path hasPrefix:@"/api/peq"]) return @{ @"ok": @YES, @"enabled": @NO, @"bands": @[] };
    return @{ @"ok": @YES };
}
@end

static RLPFitSpyClient *g_spy;
static id FakeSharedClient(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }
static void NoopProbe(id self, SEL sel) { (void)self; (void)sel; }

static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
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

static BOOL Near(CGFloat a, CGFloat b, CGFloat tol = 1.0) {
    return std::fabs((double)a - (double)b) <= (double)tol;
}

static BOOL SizeMatches(NSSize actual, CGFloat w, CGFloat h, CGFloat tol = 1.0) {
    return Near(actual.width, w, tol) && Near(actual.height, h, tol);
}

static NSString *FrameSummary(NSWindow *w) {
    return [NSString stringWithFormat:@"win=%.1fx%.1f content=%.1fx%.1f min=%.1fx%.1f contentMin=%.1fx%.1f vis=%d",
            w.frame.size.width, w.frame.size.height,
            w.contentView.frame.size.width, w.contentView.frame.size.height,
            w.minSize.width, w.minSize.height,
            w.contentMinSize.width, w.contentMinSize.height,
            (int)w.isVisible];
}

static void ResizeWindow(RLPMainWindowController *wc, CGFloat w, CGFloat h) {
    NSRect f = wc.window.frame;
    f.size = NSMakeSize(w, h);
    [wc.window setFrame:f display:wc.window.isVisible];
    [wc.window.contentView layoutSubtreeIfNeeded];
}

static NSScrollView *CheckStationTopVisible(RLPMainWindowController *wc, const char *stage) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    RLPQuickStartViewController *qs = [wc.currentContent isKindOfClass:RLPQuickStartViewController.class]
        ? (RLPQuickStartViewController *)wc.currentContent : nil;
    NSScrollView *sv = nil;
    for (NSView *v in qs.contentView.subviews) {
        if ([v isKindOfClass:NSScrollView.class]) { sv = (NSScrollView *)v; break; }
    }
    NSView *doc = sv.documentView;
    NSClipView *clip = sv.contentView;
    NSView *hdr = qs ? (NSView *)[qs valueForKey:@"headerRow"] : nil;
    const NSRect clipB = clip ? clip.bounds : NSZeroRect;
    const NSRect docF = doc ? doc.frame : NSZeroRect;
    const NSRect hdrInClip = (hdr && clip) ? [hdr convertRect:hdr.bounds toView:clip] : NSZeroRect;
    const NSRect hdrVis = (hdr && clip) ? NSIntersectionRect(hdrInClip, clipB) : NSZeroRect;
    const CGFloat expectedTopY = doc ? -sv.contentInsets.top : 0.0;
    const BOOL ok = (qs != nil && sv != nil && doc != nil && clip != nil && hdr != nil &&
                     doc.isFlipped &&
                     docF.origin.y >= -0.5 &&
                     fabs(clipB.origin.y - expectedTopY) <= 0.5 &&
                     NSContainsRect(NSInsetRect(clipB, -0.5, -0.5), hdrInClip) &&
                     hdrInClip.origin.y <= 32.0 &&
                     hdrVis.size.width > 100.0 && hdrVis.size.height > 20.0);
    Ck(ok,
       [[NSString stringWithFormat:@"S-%s 聆听室切换后文档顶对齐且页头位于可视区顶部无空白", stage] UTF8String],
       [NSString stringWithFormat:@"flipped=%d docF=%@ clipB=%@ hdrInClip=%@ topInset=%.1f",
        doc ? (int)doc.isFlipped : -1, NSStringFromRect(docF), NSStringFromRect(clipB),
        NSStringFromRect(hdrInClip), sv ? sv.contentInsets.top : -1.0]);
    return sv;
}

static void CheckTopbarGeometry(RLPMainWindowController *wc, const char *stage) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    NSView *topbar = (NSView *)[wc valueForKey:@"topbar"];
    NSSearchField *search = (NSSearchField *)[wc valueForKey:@"search"];
    NSSegmentedControl *mode = wc.modeControl;
    NSButton *queueBtn = (NSButton *)[wc valueForKey:@"topQueueBtn"];
    NSButton *scanBtn = (NSButton *)[wc valueForKey:@"topScanBtn"];
    NSButton *npBtn = (NSButton *)[wc valueForKey:@"topNpBtn"];
    NSTextField *pageTitle = (NSTextField *)[wc valueForKey:@"pageTitle"];
    NSTextField *pageCount = (NSTextField *)[wc valueForKey:@"pageCount"];
    NSButton *backBtn = (NSButton *)[wc valueForKey:@"webBackButton"];

    if (!topbar || !search || !mode || !queueBtn || !scanBtn || !npBtn) {
        Ck(NO, [[NSString stringWithFormat:@"R6 %s 顶栏关键控件齐备", stage] UTF8String], @"有控件为 nil");
        return;
    }

    NSArray<NSDictionary *> *items = @[
        @{ @"name": @"search",    @"view": search },
        @{ @"name": @"top.mode",  @"view": mode },
        @{ @"name": @"top.scan",  @"view": scanBtn },
        @{ @"name": @"top.queue", @"view": queueBtn },
        @{ @"name": @"top.np",    @"view": npBtn },
    ];

    NSMutableArray<NSDictionary *> *visibleItems = [NSMutableArray array];
    NSMutableArray<NSString *> *oob = [NSMutableArray array];
    NSMutableArray<NSString *> *hiddenRequired = [NSMutableArray array];
    NSMutableArray<NSString *> *dump = [NSMutableArray array];

    const NSRect bounds = topbar.bounds;
    const NSRect tolBounds = NSInsetRect(bounds, -0.5, -0.5);
    for (NSDictionary *entry in items) {
        NSString *name = entry[@"name"];
        NSView *v = entry[@"view"];
        NSRect r = [v convertRect:v.bounds toView:topbar];
        [dump addObject:[NSString stringWithFormat:@"%@(%.1f,%.1f %.1fx%.1f%s)",
                         name, r.origin.x, r.origin.y, r.size.width, r.size.height,
                         v.hidden ? " HIDDEN" : ""]];
        if (v.hidden) {
            [hiddenRequired addObject:name];
            continue;
        }
        if (r.size.width < 1.0 || r.size.height < 1.0 || !NSContainsRect(tolBounds, r)) {
            [oob addObject:[NSString stringWithFormat:@"%@=%@", name, NSStringFromRect(r)]];
        }
        [visibleItems addObject:@{ @"name": name, @"rect": [NSValue valueWithRect:r] }];
    }

    // Also include visible left-side title/count/back when checking collisions against search & bounds.
    NSMutableArray<NSDictionary *> *allVisible = [visibleItems mutableCopy];
    for (NSDictionary *left in @[
        @{ @"name": @"top.back",  @"view": backBtn ?: (id)[NSNull null] },
        @{ @"name": @"pageTitle", @"view": pageTitle ?: (id)[NSNull null] },
        @{ @"name": @"pageCount", @"view": pageCount ?: (id)[NSNull null] },
    ]) {
        id obj = left[@"view"];
        if (obj == [NSNull null]) continue;
        NSView *v = (NSView *)obj;
        if (v.hidden) continue;
        if ([v isKindOfClass:NSTextField.class] && ((NSTextField *)v).stringValue.length == 0) continue;
        NSRect r = [v convertRect:v.bounds toView:topbar];
        if (r.size.width <= 0.5 || r.size.height <= 0.5) continue;
        [dump addObject:[NSString stringWithFormat:@"%@(%.1f,%.1f %.1fx%.1f)",
                         left[@"name"], r.origin.x, r.origin.y, r.size.width, r.size.height]];
        if (!NSContainsRect(tolBounds, r)) {
            [oob addObject:[NSString stringWithFormat:@"%@=%@", left[@"name"], NSStringFromRect(r)]];
        }
        [allVisible addObject:@{ @"name": left[@"name"], @"rect": [NSValue valueWithRect:r] }];
    }

    NSMutableArray<NSString *> *overlaps = [NSMutableArray array];
    for (NSUInteger i = 0; i < allVisible.count; ++i) {
        NSRect a = [allVisible[i][@"rect"] rectValue];
        NSRect aIn = NSInsetRect(a, 0.25, 0.25);
        for (NSUInteger j = i + 1; j < allVisible.count; ++j) {
            NSRect b = [allVisible[j][@"rect"] rectValue];
            NSRect bIn = NSInsetRect(b, 0.25, 0.25);
            if (NSIntersectsRect(aIn, bIn)) {
                [overlaps addObject:[NSString stringWithFormat:@"%@∩%@ (%@ vs %@)",
                                     allVisible[i][@"name"], allVisible[j][@"name"],
                                     NSStringFromRect(a), NSStringFromRect(b)]];
            }
        }
    }

    std::printf("  [topbar %s] bounds=%.1fx%.1f | %s\n",
                stage, bounds.size.width, bounds.size.height,
                [dump componentsJoinedByString:@" "].UTF8String);

    Ck(hiddenRequired.count == 0,
       [[NSString stringWithFormat:@"R6-%s 五个核心顶栏控件在 900x600 下均可见", stage] UTF8String],
       [hiddenRequired componentsJoinedByString:@", "]);
    Ck(oob.count == 0,
       [[NSString stringWithFormat:@"R6-%s 顶栏控件均在 topbar bounds 内", stage] UTF8String],
       [NSString stringWithFormat:@"bounds=%@ oob=%@", NSStringFromRect(bounds), [oob componentsJoinedByString:@"; "]]);
    Ck(overlaps.count == 0,
       [[NSString stringWithFormat:@"R6-%s 顶栏控件两两不交叠", stage] UTF8String],
       [overlaps componentsJoinedByString:@"; "]);
}

static CGFloat RelativeSRGBLuminance(NSColor *color) {
    if (!color) return -1.0;
    NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!c) return -1.0;
    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent;
}

static void CheckFloatingBarAndPageExtension(RLPMainWindowController *wc, const char *stage,
                                             CGFloat expectedWinW, CGFloat expectedWinH) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    NSView *mainHost = (NSView *)[wc valueForKey:@"mainHost"];
    NSView *topbar = (NSView *)[wc valueForKey:@"topbar"];
    NSView *pageHost = (NSView *)[wc valueForKey:@"pageHost"];
    RLPPlaybackBarView *bar = wc.playbackBar;

    Ck(mainHost != nil && topbar != nil && pageHost != nil && bar != nil,
       [[NSString stringWithFormat:@"B0-%s mainHost/topbar/pageHost/playbackBar 齐备", stage] UTF8String],
       @"nil");
    if (!mainHost || !topbar || !pageHost || !bar) return;

    const BOOL winOk = SizeMatches(wc.window.frame.size, expectedWinW, expectedWinH) &&
                       SizeMatches(wc.window.contentView.frame.size, expectedWinW, expectedWinH);
    Ck(winOk,
       [[NSString stringWithFormat:@"B1-%s 窗口不被撑大 (%.0fx%.0f)", stage, expectedWinW, expectedWinH] UTF8String],
       FrameSummary(wc.window));

    const NSRect mainB = mainHost.bounds;
    const NSRect pageInMain = [pageHost convertRect:pageHost.bounds toView:mainHost];
    const NSRect topInMain = [topbar convertRect:topbar.bounds toView:mainHost];
    const NSRect barInMain = [bar convertRect:bar.bounds toView:mainHost];

    const NSUInteger pageIdx = [mainHost.subviews indexOfObjectIdenticalTo:pageHost];
    const NSUInteger barIdx = [mainHost.subviews indexOfObjectIdenticalTo:bar];
    const BOOL zOrderOk = (pageIdx != NSNotFound && barIdx != NSNotFound && barIdx > pageIdx);

    // AppKit default non-flipped coordinates: minY==0 is bottom of mainHost, maxY of pageHost aligns with topbar bottom.
    const BOOL pageExtendsToBottom = Near(NSMinY(pageInMain), NSMinY(mainB), 1.0) &&
                                     Near(NSMaxY(pageInMain), NSMinY(topInMain), 1.0) &&
                                     NSIntersectsRect(pageInMain, barInMain) &&
                                     NSContainsRect(NSInsetRect(pageInMain, -0.5, -0.5), barInMain);
    Ck(pageExtendsToBottom && zOrderOk,
       [[NSString stringWithFormat:@"B2-%s pageHost 延伸至 mainHost 底部且位于播放条下方 (旧码 minY=barTop+14 红)", stage] UTF8String],
       [NSString stringWithFormat:@"main=%@ page=%@ top=%@ bar=%@ pageIdx=%lu barIdx=%lu",
        NSStringFromRect(mainB), NSStringFromRect(pageInMain), NSStringFromRect(topInMain),
        NSStringFromRect(barInMain), (unsigned long)pageIdx, (unsigned long)barIdx]);

    const BOOL barFloatingOk = Near(NSMinY(barInMain), 14.0, 1.0) &&
                               Near(NSHeight(barInMain), 66.0, 1.0) &&
                               Near(NSMidX(barInMain), NSMidX(mainB), 1.5) &&
                               NSMinX(barInMain) >= NSMinX(mainB) - 0.5 &&
                               NSMaxX(barInMain) <= NSMaxX(mainB) + 0.5 &&
                               bar.layer.cornerRadius >= 15.5 &&
                               bar.layer.borderWidth >= 0.9 &&
                               bar.layer.shadowOpacity > 0.05;
    Ck(barFloatingOk,
       [[NSString stringWithFormat:@"B3-%s playbackBar 悬浮(底14/高66/居中/不越界/圆角16/阴影)", stage] UTF8String],
       [NSString stringWithFormat:@"bar=%@ main=%@ cr=%.1f bw=%.1f sh=%.2f",
        NSStringFromRect(barInMain), NSStringFromRect(mainB),
        bar.layer.cornerRadius, bar.layer.borderWidth, bar.layer.shadowOpacity]);

    NSVisualEffectView *glass = (NSVisualEffectView *)FindById(bar, @"pb.glass");
    const BOOL isGlass = [glass isKindOfClass:[NSVisualEffectView class]] && !glass.hidden;
    const BOOL glassBelowContent = isGlass && (bar.subviews.firstObject == glass);
    const BOOL glassMaterialOk = isGlass &&
        (glass.material != NSVisualEffectMaterialHUDWindow) &&
        (glass.material == NSVisualEffectMaterialUnderWindowBackground ||
         glass.material == NSVisualEffectMaterialSidebar) &&
        (glass.blendingMode == NSVisualEffectBlendingModeWithinWindow) &&
        SizeMatches(glass.frame.size, NSWidth(bar.bounds), NSHeight(bar.bounds));

    const CGFloat bgAlpha = bar.layer.backgroundColor ? CGColorGetAlpha(bar.layer.backgroundColor) : 0.0;
    NSColor *bgColor = bar.layer.backgroundColor ? [NSColor colorWithCGColor:bar.layer.backgroundColor] : nil;
    NSTextField *titleLab = (NSTextField *)[bar valueForKey:@"titleLabel"];
    NSTextField *subLab = (NSTextField *)[bar valueForKey:@"subLabel"];
    const CGFloat bgLum = RelativeSRGBLuminance(bgColor);
    const CGFloat titleLum = RelativeSRGBLuminance(titleLab ? titleLab.textColor : nil);
    const CGFloat subLum = RelativeSRGBLuminance(subLab ? subLab.textColor : nil);

    RLPTheme *theme = [RLPTheme current];
    const BOOL alphaAndReadabilityOk = theme.isLight
        ? (bgAlpha <= 0.35 + 1e-3 && bgAlpha < 0.6 && titleLum >= 0.0 && titleLum <= 0.35)
        : (bgAlpha < 0.6 && bgLum >= 0.0 && bgLum <= 0.35 && titleLum >= 0.65 && subLum >= 0.35);

    std::printf("  [bar-glass %-18s] win=%.0fx%.0f main=%s page=%s bar=%s glassMat=%ld below=%d alpha=%.2f bgLum=%.2f titleLum=%.2f\n",
                stage, expectedWinW, expectedWinH,
                NSStringFromRect(mainB).UTF8String,
                NSStringFromRect(pageInMain).UTF8String,
                NSStringFromRect(barInMain).UTF8String,
                isGlass ? (long)glass.material : -1L,
                glassBelowContent, bgAlpha, bgLum, titleLum);

    Ck(isGlass && glassBelowContent && glassMaterialOk && alphaAndReadabilityOk,
       [[NSString stringWithFormat:@"B4-%s pb.glass 半透明磨砂(非HUDWindow/alpha<0.6/内容在玻璃之上/主题可读)", stage] UTF8String],
       [NSString stringWithFormat:@"isGlass=%d below=%d mat=%ld blend=%ld alpha=%.2f bgLum=%.2f titleLum=%.2f subLum=%.2f",
        isGlass, glassBelowContent, isGlass ? (long)glass.material : -1L,
        isGlass ? (long)glass.blendingMode : -1L, bgAlpha, bgLum, titleLum, subLum]);
}

static NSTableView *SidebarTableView(RLPSidebarViewController *sb, NSScrollView **outScroll) {
    for (NSView *v in sb.view.subviews) {
        if ([v isKindOfClass:NSScrollView.class]) {
            NSScrollView *sv = (NSScrollView *)v;
            if ([sv.documentView isKindOfClass:NSTableView.class]) {
                if (outScroll) *outScroll = sv;
                return (NSTableView *)sv.documentView;
            }
        }
    }
    if (outScroll) *outScroll = nil;
    return nil;
}

static NSTextField *FirstTextFieldInCell(NSView *cell) {
    for (NSView *sub in cell.subviews) {
        if ([sub.identifier isEqualToString:@"label"] && [sub isKindOfClass:NSTextField.class]) {
            return (NSTextField *)sub;
        }
    }
    for (NSView *sub in cell.subviews) {
        if ([sub isKindOfClass:NSTextField.class]) return (NSTextField *)sub;
    }
    return nil;
}

static void CheckSidebarTopEntry(RLPMainWindowController *wc, const char *stage,
                                 NSInteger *outStationRow) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    NSScrollView *scroll = nil;
    NSTableView *tv = SidebarTableView(wc.sidebar, &scroll);
    NSView *search = (NSView *)[wc valueForKey:@"search"];
    NSView *root = wc.window.contentView;
    const CGFloat sidebarH = wc.sidebar.view.bounds.size.height;
    const CGFloat thirdH = sidebarH / 3.0;

    NSInteger stationRow = -1, firstSecRow = -1;
    NSInteger stationCount = 0, stationBeforeSec = 0, stationAfterSec = 0, stationTitleCount = 0;
    NSMutableSet<NSString *> *uniqueTitles = [NSMutableSet set];
    NSMutableArray<NSString *> *dupTitles = [NSMutableArray array];

    NSView *stationCell = nil, *firstSecCell = nil;
    NSString *stationTitle = @"", *firstSecTitle = @"";
    for (NSInteger r = 0; r < wc.sidebar.rowCount; ++r) {
        NSView *cell = [tv viewAtColumn:0 row:r makeIfNecessary:YES];
        if (!cell) cell = [tv.delegate tableView:tv viewForTableColumn:nil row:r];
        NSTextField *lab = FirstTextFieldInCell(cell);
        NSString *txt = lab.stringValue ?: @"";
        NSString *key = [wc.sidebar keyForRow:r];
        const BOOL isSec = ([cell.identifier isEqualToString:@"SecWrap"] || !key.length);
        if (isSec) {
            if (firstSecRow < 0) {
                firstSecRow = r;
                firstSecCell = cell;
                firstSecTitle = txt;
            }
            continue;
        }
        if (![cell.identifier isEqualToString:@"SQRow"] && txt.length) {
            if ([uniqueTitles containsObject:txt]) [dupTitles addObject:txt];
            [uniqueTitles addObject:txt];
        }
        if ([txt isEqualToString:RLPTr(@"聆听室")] ||
            [txt isEqualToString:RLPTr(@"数字音乐台")] ||
            [txt isEqualToString:RLPTr(@"专业工作台")]) {
            ++stationTitleCount;
        }
        if ([key isEqualToString:@"station"]) {
            ++stationCount;
            if (firstSecRow < 0) ++stationBeforeSec;
            else ++stationAfterSec;
            if (stationRow < 0) {
                stationRow = r;
                stationCell = cell;
                stationTitle = txt;
            }
        }
    }

    if (outStationRow) *outStationRow = stationRow;

    const NSRect stationRowRect = (stationRow >= 0) ? [tv rectOfRow:stationRow] : NSZeroRect;
    const NSRect secRowRect = (firstSecRow >= 0) ? [tv rectOfRow:firstSecRow] : NSZeroRect;

    const NSRect stationInSidebar = (stationRow >= 0) ? [tv convertRect:stationRowRect toView:wc.sidebar.view] : NSZeroRect;
    const NSRect stationInScroll = (stationRow >= 0) ? [tv convertRect:stationRowRect toView:scroll] : NSZeroRect;

    const NSRect stationInWin = (stationRow >= 0) ? [tv convertRect:stationRowRect toView:root] : NSZeroRect;
    const NSRect secInWin = (firstSecRow >= 0) ? [tv convertRect:secRowRect toView:root] : NSZeroRect;
    const NSRect searchInWin = search ? [search convertRect:search.bounds toView:root] : NSZeroRect;

    const CGFloat stationTopDist = NSMaxY(wc.sidebar.view.bounds) - NSMaxY(stationInSidebar);
    const CGFloat stationBottomDist = NSMaxY(wc.sidebar.view.bounds) - NSMinY(stationInSidebar);

    NSString *expectedTitle = [wc.uiMode isEqualToString:@"pro"] ? RLPTr(@"数字音乐台") : RLPTr(@"聆听室");

    std::printf("  [sidebar %s] mode=%s sidebarH=%.1f third=%.1f | station(count=%ld row=%ld title='%s' frame=%s top=%.1f..%.1f) | "
                "sec0(row=%ld title='%s' frame=%s) | search=%s\n",
                stage, wc.uiMode.UTF8String ?: "", sidebarH, thirdH,
                (long)stationCount, (long)stationRow, stationTitle.UTF8String,
                NSStringFromRect(stationInSidebar).UTF8String, stationTopDist, stationBottomDist,
                (long)firstSecRow, firstSecTitle.UTF8String, NSStringFromRect(secInWin).UTF8String,
                NSStringFromRect(searchInWin).UTF8String);

    const BOOL scrolledToTop = (scroll != nil && scroll.contentView.bounds.origin.y <= 0.5);
    const NSRect scrollTol = NSInsetRect(scroll.bounds, -0.5, -0.5);
    const BOOL inTopThird = (stationCount == 1 && stationRow == 0 && firstSecRow == 1 &&
                             [stationTitle isEqualToString:expectedTitle] &&
                             scrolledToTop &&
                             stationTopDist >= 0 && stationBottomDist <= thirdH &&
                             NSContainsRect(scrollTol, stationInScroll));
    Ck(inTopThird,
       [[NSString stringWithFormat:@"V1-%s 侧栏顶部仅保留唯一 station 入口 (row 0) 且位于前 1/3 可视区内", stage] UTF8String],
       [NSString stringWithFormat:@"count=%ld row=%ld title='%@'(expect='%@') sec0=%ld top=%.1f..%.1f scrollY=%.1f third=%.1f",
        (long)stationCount, (long)stationRow, stationTitle, expectedTitle, (long)firstSecRow,
        stationTopDist, stationBottomDist,
        scroll ? scroll.contentView.bounds.origin.y : -1.0, thirdH]);

    const BOOL cellsMounted = (stationCell.superview != nil && firstSecCell.superview != nil);
    const NSRect stationCellInWin = cellsMounted ? [stationCell convertRect:stationCell.bounds toView:root] : NSZeroRect;
    const NSRect secCellInWin = cellsMounted ? [firstSecCell convertRect:firstSecCell.bounds toView:root] : NSZeroRect;
    // NSTableView rectOfRow: returns contiguous row bands (sharing the border between adjacent rows),
    // while the cell views inside them are separated by intercellSpacing (2pt).
    const BOOL noOverlap = (stationCount == 1 && stationRow == 0 && firstSecRow == 1 && search != nil &&
                            cellsMounted &&
                            !NSIntersectsRect(NSInsetRect(stationInWin, 0.5, 0.5), NSInsetRect(secInWin, 0.5, 0.5)) &&
                            !NSIntersectsRect(NSInsetRect(stationInWin, 0.5, 0.5), NSInsetRect(searchInWin, 0.5, 0.5)) &&
                            NSMaxX(stationInWin) <= NSMinX(searchInWin) &&
                            NSMinY(stationInWin) >= NSMaxY(secInWin) - 0.5 &&
                            NSMinY(stationInWin) > NSMinY(secInWin) &&
                            NSMinY(stationCellInWin) > NSMaxY(secCellInWin));
    Ck(noOverlap,
       [[NSString stringWithFormat:@"V4-%s 侧栏顶部入口不与搜索框及首分组标题重叠且位于分组标题之上", stage] UTF8String],
       [NSString stringWithFormat:@"station=%@ sec0=%@ search=%@",
        NSStringFromRect(stationInWin), NSStringFromRect(secInWin), NSStringFromRect(searchInWin)]);

    Ck(stationCount == 1 && stationBeforeSec == 1 && stationAfterSec == 0 &&
       stationTitleCount == 1 && dupTitles.count == 0,
       [[NSString stringWithFormat:@"V5-%s 无数字音乐台/聆听室重复行且无重复侧栏标题", stage] UTF8String],
       [NSString stringWithFormat:@"count=%ld beforeSec=%ld afterSec=%ld titleCount=%ld dups=%@",
        (long)stationCount, (long)stationBeforeSec, (long)stationAfterSec,
        (long)stationTitleCount, [dupTitles componentsJoinedByString:@","]]);
}

static void CheckSidebarEnglishLabel(RLPMainWindowController *wc, const char *stage,
                                     NSInteger stationRow, NSString *expectedText) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    NSTableView *tv = SidebarTableView(wc.sidebar, nil);
    NSView *cell = (stationRow >= 0) ? [tv viewAtColumn:0 row:stationRow makeIfNecessary:YES] : nil;
    if (cell) [cell layoutSubtreeIfNeeded];
    NSTextField *lab = FirstTextFieldInCell(cell);
    const CGFloat needW = lab ? lab.attributedStringValue.size.width : 9999.0;
    const BOOL ok = (lab &&
                     [lab.stringValue isEqualToString:expectedText] &&
                     lab.bounds.size.height <= 22.0 &&
                     needW <= lab.bounds.size.width + 1.0 &&
                     NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5),
                                    [lab convertRect:lab.bounds toView:cell]));
    std::printf("  [sidebar-en %s] mode=%s row=%ld title='%s' needW=%.1f box=%s\n",
                stage, wc.uiMode.UTF8String ?: "", (long)stationRow,
                lab.stringValue.UTF8String ?: "", needW, NSStringFromRect(lab.frame).UTF8String);
    Ck(ok,
       [[NSString stringWithFormat:@"V4-%s 英文模式下 row0 文案 '%@' 完整、单行不换行且不截断", stage, expectedText] UTF8String],
       [NSString stringWithFormat:@"actual='%@' expect='%@' (%.1f/%.1f h=%.1f)",
        lab.stringValue, expectedText, needW, lab.bounds.size.width, lab.bounds.size.height]);
}

static void CheckSidebarHarmony(RLPMainWindowController *wc, const char *stage,
                                BOOL expectStationSelected, BOOL checkFirstScreenFit) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    NSScrollView *scroll = nil;
    NSTableView *tv = SidebarTableView(wc.sidebar, &scroll);
    if (tv) [tv layoutSubtreeIfNeeded];

    if (!tv || !scroll || wc.sidebar.rowCount <= 0) {
        Ck(NO, [[NSString stringWithFormat:@"V8-%s 侧栏表格存在", stage] UTF8String], @"table/scroll nil");
        return;
    }

    NSArray<NSString *> *expectNonSQKeys = @[
        @"station", @"albums", @"artists", @"tracks", @"folders", @"streaming",
        @"queue", @"recent", @"favorites", @"settings"
    ];
    NSArray<NSString *> *expectSections = @[
        RLPTr(@"资料库"), RLPTr(@"播放列表"), RLPTr(@"我的歌单"), RLPTr(@"音频引擎")
    ];
    NSMutableArray<NSString *> *actualNonSQKeys = [NSMutableArray array];
    NSMutableArray<NSString *> *actualSections = [NSMutableArray array];

    NSMutableArray<NSNumber *> *navHeights = [NSMutableArray array];
    NSMutableArray<NSNumber *> *secHeights = [NSMutableArray array];
    NSMutableArray<NSNumber *> *gapsBelowSec = [NSMutableArray array];
    NSMutableArray<NSNumber *> *gapsAboveSec = [NSMutableArray array];
    NSMutableArray<NSString *> *truncErrs = [NSMutableArray array];

    CGFloat stationH = -1.0;
    CGFloat maxMidYDiff = 0.0;
    CGFloat minIconX = 9999.0, maxIconX = -9999.0;
    CGFloat minLabelX = 9999.0, maxLabelX = -9999.0;
    CGFloat minSecBottomPad = 9999.0;
    BOOL symConfigMissing = NO;
    BOOL iconBoxBad = NO;
    BOOL secStyleOk = YES;
    BOOL overlapErr = NO;
    BOOL cellOverlapErr = NO;
    BOOL firstScreenOk = YES;

    CGFloat prevRowMaxY = -1.0;
    NSView *prevCell = nil;
    NSRect prevCellInTv = NSZeroRect;
    NSRect prevPillInTv = NSZeroRect;
    BOOL hasPendingSec = NO;
    NSRect pendingSecInTv = NSZeroRect;
    NSRect stationCellFrame = NSZeroRect;
    NSRect firstSecCellFrame = NSZeroRect;
    NSRect firstItemCellFrame = NSZeroRect;
    NSInteger favoritesRow = -1;

    const NSRect vis = scroll.documentVisibleRect;
    const NSInteger nRows = wc.sidebar.rowCount;
    for (NSInteger r = 0; r < nRows; ++r) {
        NSRect rowRect = [tv rectOfRow:r];
        if (r > 0 && NSMinY(rowRect) < prevRowMaxY - 0.5) overlapErr = YES;
        prevRowMaxY = NSMaxY(rowRect);

        NSView *cell = [tv viewAtColumn:0 row:r makeIfNecessary:YES];
        if (!cell) cell = [tv.delegate tableView:tv viewForTableColumn:nil row:r];
        if (!cell) { secStyleOk = NO; continue; }
        [cell layoutSubtreeIfNeeded];

        const BOOL mounted = (cell.superview != nil);
        const CGFloat h = mounted ? NSHeight(cell.frame) : [tv.delegate tableView:tv heightOfRow:r];
        NSRect cellInTv = mounted ? [cell convertRect:cell.bounds toView:tv] : NSZeroRect;
        if (mounted && prevCell && prevCell.superview) {
            if (NSMinY(cellInTv) <= NSMaxY(prevCellInTv) + 0.5) cellOverlapErr = YES;
        }

        if ([cell.identifier isEqualToString:@"SecWrap"]) {
            if (NSIsEmptyRect(firstSecCellFrame)) firstSecCellFrame = cellInTv;
            [secHeights addObject:@(h)];
            NSTextField *secLab = FirstTextFieldInCell(cell);
            if (!secLab) {
                secStyleOk = NO;
            } else {
                [actualSections addObject:secLab.stringValue ?: @""];
                NSRect secInCell = [secLab convertRect:secLab.bounds toView:cell];
                const CGFloat bottomPad = cell.isFlipped
                    ? (NSHeight(cell.bounds) - NSMaxY(secInCell))
                    : (NSMinY(secInCell) - NSMinY(cell.bounds));
                minSecBottomPad = MIN(minSecBottomPad, bottomPad);
                if (std::fabs((double)secLab.font.pointSize - 11.0) > 1.0 ||
                    std::fabs((double)NSMinX(secInCell) - 20.0) > 2.0 ||
                    !NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5), secInCell)) {
                    secStyleOk = NO;
                }
                const CGFloat needW = secLab.attributedStringValue.size.width;
                if (needW > NSWidth(secLab.bounds) + 1.0) {
                    [truncErrs addObject:[NSString stringWithFormat:@"sec:%@(%.1f/%.1f)",
                                          secLab.stringValue, needW, NSWidth(secLab.bounds)]];
                }
                if ([secLab.stringValue isEqualToString:RLPTr(@"我的歌单")]) {
                    NSButton *plus = (NSButton *)FindById(cell, @"sq.new");
                    if (!plus) {
                        secStyleOk = NO;
                    } else {
                        NSRect plusInCell = [plus convertRect:plus.bounds toView:cell];
                        if (!NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5), plusInCell) ||
                            std::fabs((double)NSMidY(plusInCell) - (double)NSMidY(secInCell)) > 3.0 ||
                            std::fabs((double)plus.font.pointSize - 11.0) > 1.0) {
                            secStyleOk = NO;
                        }
                    }
                }
                if (mounted) {
                    NSRect secInTv = [secLab convertRect:secLab.bounds toView:tv];
                    if (!NSIsEmptyRect(prevPillInTv)) {
                        const CGFloat gapAbove = tv.isFlipped
                            ? (NSMinY(secInTv) - NSMaxY(prevPillInTv))
                            : (NSMinY(prevPillInTv) - NSMaxY(secInTv));
                        [gapsAboveSec addObject:@(gapAbove)];
                    }
                    pendingSecInTv = secInTv;
                    hasPendingSec = YES;
                }
            }
        } else {
            NSString *k = [wc.sidebar keyForRow:r] ?: @"";
            if (![k isEqualToString:@"playlists"]) [actualNonSQKeys addObject:k];
            if ([k isEqualToString:@"favorites"]) favoritesRow = r;
            if (r == 0) {
                stationH = h;
                stationCellFrame = cellInTv;
            } else if (NSIsEmptyRect(firstItemCellFrame) && !NSIsEmptyRect(firstSecCellFrame)) {
                firstItemCellFrame = cellInTv;
            }
            [navHeights addObject:@(h)];

            NSView *pill = FindById(cell, @"pill") ?: FindById(cell, @"gain") ?: FindById(cell, @"sq.empty");
            NSImageView *icon = (NSImageView *)FindById(cell, @"icon");
            NSTextField *lab = (NSTextField *)(FindById(cell, @"label") ?: FindById(cell, @"sq.empty.label"));
            if (!lab) {
                [truncErrs addObject:[NSString stringWithFormat:@"row%ld:nil-label", (long)r]];
            } else {
                NSRect labInCell = [lab convertRect:lab.bounds toView:cell];
                const CGFloat needW = lab.attributedStringValue.size.width;
                const BOOL textClips = (needW > NSWidth(lab.bounds) + 1.0) ||
                                       (NSHeight(lab.bounds) > h + 0.5) ||
                                       !NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5), labInCell);
                if (textClips && ![k isEqualToString:@"playlists"]) {
                    [truncErrs addObject:[NSString stringWithFormat:@"%@(%.1f/%.1f h=%.1f)",
                                          lab.stringValue, needW, NSWidth(lab.bounds), NSHeight(lab.bounds)]];
                }
                if (icon) {
                    NSRect iconInCell = [icon convertRect:icon.bounds toView:cell];
                    const CGFloat diff = std::fabs((double)NSMidY(iconInCell) - (double)NSMidY(labInCell));
                    maxMidYDiff = MAX(maxMidYDiff, diff);
                    minIconX = MIN(minIconX, NSMinX(iconInCell));
                    maxIconX = MAX(maxIconX, NSMinX(iconInCell));
                    minLabelX = MIN(minLabelX, NSMinX(labInCell));
                    maxLabelX = MAX(maxLabelX, NSMinX(labInCell));
                    if (std::fabs((double)NSWidth(iconInCell) - 16.0) > 4.0 ||
                        std::fabs((double)NSHeight(iconInCell) - 16.0) > 4.0 ||
                        !NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5), iconInCell)) {
                        iconBoxBad = YES;
                    }
                    if (@available(macOS 11.0, *)) {
                        if (!icon.symbolConfiguration) symConfigMissing = YES;
                    }
                } else {
                    if (std::fabs((double)NSMinX(labInCell) - 20.0) > 0.5) iconBoxBad = YES;
                }
            }
            if (mounted && pill) {
                NSRect pillInTv = [pill convertRect:pill.bounds toView:tv];
                if (hasPendingSec) {
                    const CGFloat gapBelow = tv.isFlipped
                        ? (NSMinY(pillInTv) - NSMaxY(pendingSecInTv))
                        : (NSMinY(pendingSecInTv) - NSMaxY(pillInTv));
                    [gapsBelowSec addObject:@(gapBelow)];
                    hasPendingSec = NO;
                }
                prevPillInTv = pillInTv;
            }
        }
        prevCell = cell;
        prevCellInTv = cellInTv;
    }

    if (checkFirstScreenFit) {
        const CGFloat winW = wc.window.frame.size.width;
        if (winW >= 1100.0 && wc.sidebar.savedQueueRowCount == 0) {
            const NSRect lastR = [tv rectOfRow:nRows - 1];
            if (NSMaxY(lastR) > NSMaxY(vis) + 0.5) firstScreenOk = NO;
        } else if (favoritesRow >= 0) {
            const NSRect favR = [tv rectOfRow:favoritesRow];
            if (NSMaxY(favR) > NSMaxY(vis) + 0.5) firstScreenOk = NO;
        }
    }

    auto MinMax = [](NSArray<NSNumber *> *arr, CGFloat &outMin, CGFloat &outMax) {
        outMin = 9999.0; outMax = -9999.0;
        for (NSNumber *n in arr) {
            const CGFloat v = n.doubleValue;
            outMin = MIN(outMin, v);
            outMax = MAX(outMax, v);
        }
    };
    CGFloat minNavH = 0, maxNavH = 0, minSecH = 0, maxSecH = 0;
    CGFloat minGapBelow = 0, maxGapBelow = 0, minGapAbove = 0, maxGapAbove = 0;
    MinMax(navHeights, minNavH, maxNavH);
    MinMax(secHeights, minSecH, maxSecH);
    MinMax(gapsBelowSec, minGapBelow, maxGapBelow);
    MinMax(gapsAboveSec, minGapAbove, maxGapAbove);

    const BOOL orderOk = [actualNonSQKeys isEqualToArray:expectNonSQKeys] &&
                         [actualSections isEqualToArray:expectSections] &&
                         [[wc.sidebar keyForRow:0] isEqualToString:@"station"];
    const BOOL stationSelOk = !expectStationSelected ||
                              (wc.sidebar.selectedRow == 0 && [wc.sidebar.selectedKey isEqualToString:@"station"]);

    std::printf("  [V8 %s] navH=%.1f..%.1f(station=%.1f) secH=%.1f..%.1f midY<=%.2f iconX=%.1f..%.1f "
                "secBot=%.1f gapBelow=%.1f..%.1f gapAbove=%.1f..%.1f station=%s sec0=%s first=%s visH=%.1f\n",
                stage, minNavH, maxNavH, stationH, minSecH, maxSecH, maxMidYDiff, minIconX, maxIconX,
                minSecBottomPad, minGapBelow, maxGapBelow, minGapAbove, maxGapAbove,
                NSStringFromRect(stationCellFrame).UTF8String,
                NSStringFromRect(firstSecCellFrame).UTF8String,
                NSStringFromRect(firstItemCellFrame).UTF8String,
                vis.size.height);

    Ck(orderOk && stationSelOk && navHeights.count >= 11 &&
       (maxNavH - minNavH) <= 0.5 && Near(minNavH, 30.0, 0.5) && Near(stationH, 30.0, 0.5),
       [[NSString stringWithFormat:@"V8a-%s 侧栏行顺序/key/选中不变且所有导航行与顶部 station 高度统一为 30pt", stage] UTF8String],
       [NSString stringWithFormat:@"order=%d sel=%d(row=%ld key=%@) navH=%.1f..%.1f stationH=%.1f",
        (int)orderOk, (int)stationSelOk, (long)wc.sidebar.selectedRow, wc.sidebar.selectedKey ?: @"",
        minNavH, maxNavH, stationH]);

    Ck(maxMidYDiff <= 1.0 && !symConfigMissing &&
       (maxIconX - minIconX) <= 0.5 && Near(minIconX, 20.0, 0.5) &&
       (maxLabelX - minLabelX) <= 0.5 && truncErrs.count == 0 &&
       !overlapErr && !cellOverlapErr && firstScreenOk,
       [[NSString stringWithFormat:@"V8b-%s 图标/文字 midY 差<=1、左 padding 与符号配置一致、无重叠且首屏不截断", stage] UTF8String],
       [NSString stringWithFormat:@"midY=%.2f symCfg=%d iconBad=%d iconX=%.1f..%.1f labX=%.1f..%.1f ov=%d/%d fs=%d trunc=%@",
        maxMidYDiff, (int)!symConfigMissing, (int)iconBoxBad, minIconX, maxIconX, minLabelX, maxLabelX,
        (int)overlapErr, (int)cellOverlapErr, (int)firstScreenOk, [truncErrs componentsJoinedByString:@","]]);

    Ck(secHeights.count == 4 && (maxSecH - minSecH) <= 0.5 && Near(minSecH, 30.0, 0.5) &&
       minSecBottomPad >= 3.8 &&
       gapsBelowSec.count == 4 && (maxGapBelow - minGapBelow) <= 1.0 && minGapBelow >= 6.5,
       [[NSString stringWithFormat:@"V8c-%s 分组标题字号/对齐/下边距一致且标题与首行间距统一", stage] UTF8String],
       [NSString stringWithFormat:@"secH=%.1f..%.1f style=%d botPad=%.1f gapBelow=%.1f..%.1f",
        minSecH, maxSecH, (int)secStyleOk, minSecBottomPad, minGapBelow, maxGapBelow]);

    Ck(gapsAboveSec.count == 4 && (maxGapAbove - minGapAbove) <= 1.0 && minGapAbove >= minGapBelow + 3.0,
       [[NSString stringWithFormat:@"V8d-%s 各分组间呼吸距统一且明显大于组内标题与首行间距", stage] UTF8String],
       [NSString stringWithFormat:@"gapAbove=%.1f..%.1f gapBelow=%.1f..%.1f",
        minGapAbove, maxGapAbove, minGapBelow, maxGapBelow]);
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        static NSString *const kAutosaveDefaultsKey = @"NSWindow Frame RLPNativeMainWindow.v2";
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAutosaveDefaultsKey];

        g_spy = [RLPFitSpyClient new];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        [RLPSettingsViewController setRlp_confirmsBitPerfectFix:NO];

        Method shared = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        method_setImplementation(shared, (IMP)FakeSharedClient);
        Method probe = class_getInstanceMethod(RLPSettingsViewController.class, @selector(probeFeedbackChannel));
        if (probe) method_setImplementation(probe, (IMP)NoopProbe);

        std::printf("=== test_native_window_fit_contract（主窗不被内容 fitting 撑大 + 900x600 顶栏几何）===\n");
        for (NSUInteger i = 0; i < NSScreen.screens.count; ++i) {
            NSRect vf = NSScreen.screens[i].visibleFrame;
            std::printf("  [screen %lu] visible=%.0f,%.0f %.0fx%.0f\n",
                        (unsigned long)i, vf.origin.x, vf.origin.y, vf.size.width, vf.size.height);
        }

        RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
        [wc.window setFrameAutosaveName:@""];

        // ---- R1: 起始 1180x760，albums → station → settings(meta) → station ----
        [wc.window.contentView layoutSubtreeIfNeeded];
        Pump(0.15);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R1 init] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 1180, 760),
           "R1a 起始窗口 frame 为 1180x760 ±1", FrameSummary(wc.window));

        [wc.sidebar selectKey:@"albums"];
        Pump(0.2);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R1 albums] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 1180, 760),
           "R1b 切 albums 并 pump 后仍为 1180x760 ±1", FrameSummary(wc.window));

        [wc.sidebar selectKey:@"station"];
        NSScrollView *stationScroll = CheckStationTopVisible(wc, "R1c-0ms");
        Pump(0.3);
        [wc.window.contentView layoutSubtreeIfNeeded];
        CheckStationTopVisible(wc, "R1c-300ms");
        if (stationScroll && stationScroll.contentView) {
            [stationScroll.contentView scrollToPoint:NSMakePoint(0, 260)];
            [stationScroll reflectScrolledClipView:stationScroll.contentView];
        }
        std::printf("  [R1 station] %s\n", FrameSummary(wc.window).UTF8String);
        Ck([wc.currentContent isKindOfClass:RLPQuickStartViewController.class] &&
           SizeMatches(wc.window.frame.size, 1180, 760),
           "R1c 切 station（聆听室）并 pump 后仍为 1180x760 ±1", FrameSummary(wc.window));

        [wc.sidebar selectKey:@"settings"];
        Pump(0.15);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"meta"];
        Pump(0.25);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R1 settings(meta)] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 1180, 760),
           "R1d 切 settings(meta) 并 pump 后仍为 1180x760 ±1", FrameSummary(wc.window));

        NSButton *moreMeta = (NSButton *)FindById(wc.currentContent.view, @"sp_metamore");
        if ([moreMeta isKindOfClass:NSButton.class]) {
            [moreMeta performClick:nil];
            Pump(0.2);
            [wc.window.contentView layoutSubtreeIfNeeded];
            std::printf("  [R1 settings(meta+adv)] %s\n", FrameSummary(wc.window).UTF8String);
            Ck(SizeMatches(wc.window.frame.size, 1180, 760),
               "R1e settings(meta) 展开高级选项后仍为 1180x760 ±1", FrameSummary(wc.window));
            [moreMeta performClick:nil];
            Pump(0.1);
        }

        [wc.sidebar selectKey:@"station"];
        CheckStationTopVisible(wc, "R1f-reenter-0ms");
        Pump(0.25);
        [wc.window.contentView layoutSubtreeIfNeeded];
        CheckStationTopVisible(wc, "R1f-reenter-250ms");
        std::printf("  [R1 back-station] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 1180, 760),
           "R1f 切回 station 并 pump 后仍为 1180x760 ±1", FrameSummary(wc.window));

        // ---- R2: setFrame 900x600，pump 后仍 900x600；contentView 宽高 == 900x600（FullSize 含标题栏）----
        ResizeWindow(wc, 900, 600);
        Pump(0.3);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R2 shrink 900x600] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 900, 600),
           "R2a setFrame 900x600 并 pump 后 frame 仍为 900x600（旧码会被顶到 980）",
           FrameSummary(wc.window));
        Ck(SizeMatches(wc.window.contentView.frame.size, 900, 600) &&
           SizeMatches(wc.window.contentView.bounds.size, 900, 600),
           "R2b 900x600 下 contentView 宽高 == 900x600（保留 FullSizeContentView 标题栏高度）",
           FrameSummary(wc.window));

        // ---- R3: 900x600 下进 meta、回 station，仍 900x600；再 set 1180x760 仍 1180x760 ----
        [wc.sidebar selectKey:@"settings"];
        Pump(0.15);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"meta"];
        Pump(0.25);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R3 meta@900] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 900, 600),
           "R3a 900x600 下进入 settings(meta) 后 frame 仍为 900x600",
           FrameSummary(wc.window));

        moreMeta = (NSButton *)FindById(wc.currentContent.view, @"sp_metamore");
        if ([moreMeta isKindOfClass:NSButton.class]) {
            [moreMeta performClick:nil];
            Pump(0.2);
            [wc.window.contentView layoutSubtreeIfNeeded];
            std::printf("  [R3 meta+adv@900] %s\n", FrameSummary(wc.window).UTF8String);
            Ck(SizeMatches(wc.window.frame.size, 900, 600),
               "R3b 900x600 下展开 meta 高级选项后 frame 仍为 900x600",
               FrameSummary(wc.window));
            [moreMeta performClick:nil];
            Pump(0.1);
        }

        [wc.sidebar selectKey:@"station"];
        CheckStationTopVisible(wc, "R3c-900-0ms");
        Pump(0.25);
        [wc.window.contentView layoutSubtreeIfNeeded];
        CheckStationTopVisible(wc, "R3c-900-250ms");
        std::printf("  [R3 station@900] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 900, 600),
           "R3c 900x600 下从 meta 切回 station 后 frame 仍为 900x600",
           FrameSummary(wc.window));

        ResizeWindow(wc, 1180, 760);
        Pump(0.25);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R3 restore 1180x760] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 1180, 760) &&
           SizeMatches(wc.window.contentView.frame.size, 1180, 760),
           "R3d 再 setFrame 1180x760 并 pump 后仍为 1180x760",
           FrameSummary(wc.window));

        // ---- R4: 1394x880 下切换聆听室 / 专业工作台（setUiMode），frame 不变 ----
        ResizeWindow(wc, 1394, 880);
        Pump(0.2);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R4 base 1394x880] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 1394, 880),
           "R4a 1394x880 基线生效", FrameSummary(wc.window));

        [wc setUiMode:@"pro" persist:NO];
        Pump(0.3);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R4 pro@1394] %s\n", FrameSummary(wc.window).UTF8String);
        Ck([wc.currentContent isKindOfClass:RLPWorkbenchViewController.class] &&
           SizeMatches(wc.window.frame.size, 1394, 880),
           "R4b 1394x880 下切专业工作台（pro）frame 保持 1394x880",
           FrameSummary(wc.window));

        [wc setUiMode:@"listen" persist:NO];
        Pump(0.3);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R4 listen@1394] %s\n", FrameSummary(wc.window).UTF8String);
        Ck([wc.currentContent isKindOfClass:RLPQuickStartViewController.class] &&
           SizeMatches(wc.window.frame.size, 1394, 880),
           "R4c 1394x880 下切回聆听室（listen）frame 保持 1394x880",
           FrameSummary(wc.window));

        // ---- R5: orderFront 可见路径（Accessory，不 makeKey），可见后 frame 不被内容改变 ----
        ResizeWindow(wc, 900, 600);
        Pump(0.15);
        [wc.window orderFront:nil];
        Pump(0.4);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R5 orderFront@900] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(wc.window.isVisible &&
           SizeMatches(wc.window.frame.size, 900, 600) &&
           SizeMatches(wc.window.contentView.frame.size, 900, 600),
           "R5a orderFront（Accessory 不抢焦点）后 900x600 frame 与 contentView 保持不变",
           FrameSummary(wc.window));

        [wc.sidebar selectKey:@"albums"];
        Pump(0.2);
        [wc.sidebar selectKey:@"station"];
        Pump(0.25);
        [wc.sidebar selectKey:@"settings"];
        Pump(0.15);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"meta"];
        Pump(0.25);
        [wc setUiMode:@"pro" persist:NO];
        Pump(0.25);
        [wc setUiMode:@"listen" persist:NO];
        Pump(0.25);
        [wc.window.contentView layoutSubtreeIfNeeded];
        std::printf("  [R5 visible tour@900] %s\n", FrameSummary(wc.window).UTF8String);
        Ck(SizeMatches(wc.window.frame.size, 900, 600) &&
           SizeMatches(wc.window.contentView.frame.size, 900, 600),
           "R5b 可见态下切 albums/station/meta/pro/listen 后仍保持 900x600",
           FrameSummary(wc.window));

        // ---- R6: 900x600 下顶栏控件不越界、不互相重叠 ----
        ResizeWindow(wc, 900, 600);
        Pump(0.15);
        [wc.sidebar selectKey:@"albums"];
        Pump(0.15);
        CheckTopbarGeometry(wc, "albums@900");

        [wc.sidebar selectKey:@"station"];
        Pump(0.2);
        CheckTopbarGeometry(wc, "listen-station@900");

        [wc setUiMode:@"pro" persist:NO];
        Pump(0.2);
        CheckTopbarGeometry(wc, "pro-station@900");

        // 详情页带 top.back 返回按钮 + 长标题场景
        [wc setUiMode:@"listen" persist:NO];
        [wc.sidebar selectKey:@"albums"];
        Pump(0.15);
        RLPRequestOpenAlbum(@"a000");
        Pump(0.2);
        CheckTopbarGeometry(wc, "detail-back@900");
        RLPRequestBack();
        Pump(0.1);

        // 超长艺术家名详情页（带 top.back + pageCount 通知）必须在 900x600 下被夹紧在搜索框之前
        [wc.sidebar selectKey:@"artists"];
        Pump(0.1);
        RLPRequestOpenArtist(@"Ludwig van Beethoven — Berliner Philharmoniker Complete Live Edition");
        Pump(0.15);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPageCountNotification" object:@"24 张专辑 · 120 首"];
        Pump(0.1);
        CheckTopbarGeometry(wc, "long-artist-back@900");
        RLPRequestBack();
        Pump(0.1);

        // 英文界面标签更宽（Listening / Professional, Listening Room, Digital Music Console）也不可越界/重叠
        RLPSetLanguage(@"en");
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
        [wc.sidebar selectKey:@"station"];
        Pump(0.2);
        CheckTopbarGeometry(wc, "en-station@900");
        [wc setUiMode:@"pro" persist:NO];
        Pump(0.2);
        CheckTopbarGeometry(wc, "en-pro-station@900");

        [wc setUiMode:@"listen" persist:NO];
        RLPSetLanguage(@"zh");
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
        Pump(0.15);

        // 遍历设置全部 10 个 pane + 右抽屉 / NowPlaying 覆盖层：900x600 绝不被撑大
        [wc.sidebar selectKey:@"settings"];
        Pump(0.15);
        BOOL allPanesOk = YES;
        NSMutableArray<NSString *> *badPanes = [NSMutableArray array];
        for (NSString *pane in @[ @"adv", @"in", @"out", @"pcm", @"sdm", @"eq", @"cal", @"meta", @"stream", @"diag" ]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:pane];
            Pump(0.12);
            [wc.window.contentView layoutSubtreeIfNeeded];
            if (!SizeMatches(wc.window.frame.size, 900, 600) ||
                !SizeMatches(wc.window.contentView.frame.size, 900, 600)) {
                allPanesOk = NO;
                [badPanes addObject:[NSString stringWithFormat:@"%@=%.1fx%.1f",
                                     pane, wc.window.frame.size.width, wc.window.frame.size.height]];
            }
        }
        Ck(allPanesOk, "R3e 900x600 下遍历设置全部 10 个 pane 仍保持 900x600",
           [badPanes componentsJoinedByString:@", "]);

        [wc.sidebar selectKey:@"station"];
        Pump(0.15);
        [wc toggleDrawer];
        Pump(0.15);
        [wc.window.contentView layoutSubtreeIfNeeded];
        Ck(wc.drawerOpen && SizeMatches(wc.window.frame.size, 900, 600) &&
           SizeMatches(wc.window.contentView.frame.size, 900, 600),
           "R5c 900x600 下打开右侧抽屉 frame 与 contentView 保持 900x600",
           FrameSummary(wc.window));
        [wc toggleDrawer];
        Pump(0.1);

        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenNowPlayingNotification" object:nil];
        Pump(0.2);
        [wc.window.contentView layoutSubtreeIfNeeded];
        Ck(wc.nowPlayingOverlayVisible && SizeMatches(wc.window.frame.size, 900, 600) &&
           SizeMatches(wc.window.contentView.frame.size, 900, 600),
           "R5d 900x600 下打开 NowPlaying 覆盖层 frame 与 contentView 保持 900x600",
           FrameSummary(wc.window));
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPCloseNowPlayingNotification" object:nil];
        Pump(0.1);

        // classic 风格（topH=52）也在 900x600 下核对顶栏几何（全部 10 个 pane 均已访问过，可安全切样式）
        RLPSetLanguage(@"en");
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
        [RLPTheme setUiStyle:@"classic"];
        [wc setUiMode:@"pro" persist:NO];
        Pump(0.2);
        CheckTopbarGeometry(wc, "en-pro-classic@900");
        [RLPTheme setUiStyle:@"apple"];
        [wc setUiMode:@"listen" persist:NO];
        RLPSetLanguage(@"zh");
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
        Pump(0.1);

        // ---- V1..V5: 侧栏顶部单入口（聆听室 / 数字音乐台随模式切换）、路由、布局与同步契约 ----
        {
            NSInteger stationRow = -1;
            NSView *pageHost = (NSView *)[wc valueForKey:@"pageHost"];
            NSTextField *topTitle = (NSTextField *)[wc valueForKey:@"pageTitle"];

            // 900x600 空歌单与溢出 12 歌单两档下验证 V1/V4/V5
            ResizeWindow(wc, 900, 600);
            [wc setUiMode:@"listen" persist:NO];
            [wc.sidebar selectKey:@"albums"];
            Pump(0.15);
            CheckSidebarTopEntry(wc, "zh-listen@900", &stationRow);

            // 溢出 12 个歌单（把设置/音频引擎挤到滚动视口之外）时，顶部单入口仍必须留在视口前 1/3
            NSMutableArray *manyQueues = [NSMutableArray array];
            for (int qi = 0; qi < 12; ++qi) {
                [manyQueues addObject:@{ @"name": [NSString stringWithFormat:@"Playlist %02d", qi], @"n": @5 }];
            }
            g_spy.savedQueuesFixture = manyQueues;
            [wc.sidebar reloadSavedQueues];
            Pump(0.15);
            CheckSidebarTopEntry(wc, "zh-overflow@900", &stationRow);

            // V2a: listen 模式下点击 row 0 -> RLPQuickStartViewController + pageHost + topTitle「聆听室」
            NSScrollView *sbScroll = nil;
            NSTableView *sbTable = SidebarTableView(wc.sidebar, &sbScroll);
            if (sbTable && stationRow >= 0) {
                [sbTable deselectAll:nil];
                [sbTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)stationRow] byExtendingSelection:NO];
            } else {
                [wc.sidebar selectRow:stationRow];
            }
            Pump(0.2);
            std::printf("  [V2a] mode=%s row=%ld title='%s' currentContent=%s\n",
                        wc.uiMode.UTF8String ?: "", (long)wc.sidebar.selectedRow,
                        topTitle.stringValue.UTF8String ?: "",
                        NSStringFromClass(wc.currentContent.class).UTF8String);
            Ck([wc.uiMode isEqualToString:@"listen"] &&
               wc.modeControl.selectedSegment == 0 &&
               wc.sidebar.selectedRow == 0 &&
               [wc.sidebar.selectedKey isEqualToString:@"station"] &&
               [wc.currentContent isKindOfClass:RLPQuickStartViewController.class] &&
               [wc.currentContent.view.identifier isEqualToString:@"page.station"] &&
               wc.currentContent.view.superview == pageHost &&
               pageHost.subviews.count == 1 &&
               [topTitle.stringValue isEqualToString:RLPTr(@"聆听室")],
               "V2a listen 模式下点击 row 0 进入 RLPQuickStartViewController 并同步 modeControl/pageHost/标题",
               [NSString stringWithFormat:@"mode=%@ seg=%ld row=%ld/%ld key=%@ vc=%@ hostCount=%lu title=%@",
                wc.uiMode, (long)wc.modeControl.selectedSegment, (long)wc.sidebar.selectedRow, (long)stationRow,
                wc.sidebar.selectedKey ?: @"(nil)", NSStringFromClass(wc.currentContent.class),
                (unsigned long)pageHost.subviews.count, topTitle.stringValue ?: @""]);

            // V3a: 顶栏 modeControl 切到 pro -> 自动切到 RLPWorkbenchViewController 且 row 0 选中不变
            wc.modeControl.selectedSegment = 1;
            [wc.modeControl sendAction:wc.modeControl.action to:wc.modeControl.target];
            Pump(0.15);
            std::printf("  [V3a->pro] mode=%s row=%ld title='%s' currentContent=%s\n",
                        wc.uiMode.UTF8String ?: "", (long)wc.sidebar.selectedRow,
                        topTitle.stringValue.UTF8String ?: "",
                        NSStringFromClass(wc.currentContent.class).UTF8String);
            Ck([wc.uiMode isEqualToString:@"pro"] &&
               wc.modeControl.selectedSegment == 1 &&
               wc.sidebar.selectedRow == 0 &&
               [wc.sidebar.selectedKey isEqualToString:@"station"] &&
               [wc.currentContent isKindOfClass:RLPWorkbenchViewController.class] &&
               [wc.currentContent.view.identifier isEqualToString:@"page.station"] &&
               wc.currentContent.view.superview == pageHost &&
               pageHost.subviews.count == 1 &&
               [topTitle.stringValue isEqualToString:RLPTr(@"数字音乐台")],
               "V3a 顶栏 modeControl 切 pro 自动切页到 RLPWorkbenchViewController 且 row 0 选中不变",
               [NSString stringWithFormat:@"mode=%@ row=%ld key=%@ vc=%@ title=%@",
                wc.uiMode, (long)wc.sidebar.selectedRow, wc.sidebar.selectedKey ?: @"(nil)",
                NSStringFromClass(wc.currentContent.class), topTitle.stringValue ?: @""]);
            CheckSidebarTopEntry(wc, "zh-pro-after-mode@900", &stationRow);

            // V3b: 顶栏 modeControl 切回 listen -> 自动切回 RLPQuickStartViewController 且 row 0 选中不变
            wc.modeControl.selectedSegment = 0;
            [wc.modeControl sendAction:wc.modeControl.action to:wc.modeControl.target];
            Pump(0.15);
            std::printf("  [V3b->listen] mode=%s row=%ld title='%s' currentContent=%s\n",
                        wc.uiMode.UTF8String ?: "", (long)wc.sidebar.selectedRow,
                        topTitle.stringValue.UTF8String ?: "",
                        NSStringFromClass(wc.currentContent.class).UTF8String);
            Ck([wc.uiMode isEqualToString:@"listen"] &&
               wc.modeControl.selectedSegment == 0 &&
               wc.sidebar.selectedRow == 0 &&
               [wc.sidebar.selectedKey isEqualToString:@"station"] &&
               [wc.currentContent isKindOfClass:RLPQuickStartViewController.class] &&
               [wc.currentContent.view.identifier isEqualToString:@"page.station"] &&
               wc.currentContent.view.superview == pageHost &&
               pageHost.subviews.count == 1 &&
               [topTitle.stringValue isEqualToString:RLPTr(@"聆听室")],
               "V3b 顶栏 modeControl 切回 listen 自动切回 RLPQuickStartViewController 且 row 0 选中不变",
               [NSString stringWithFormat:@"mode=%@ row=%ld key=%@ vc=%@ title=%@",
                wc.uiMode, (long)wc.sidebar.selectedRow, wc.sidebar.selectedKey ?: @"(nil)",
                NSStringFromClass(wc.currentContent.class), topTitle.stringValue ?: @""]);

            // V2b: pro 模式下从 albums 点击 row 0 -> RLPWorkbenchViewController + pageHost + topTitle「数字音乐台」
            [wc setUiMode:@"pro" persist:NO];
            [wc.sidebar selectKey:@"albums"];
            Pump(0.15);
            if (sbTable && stationRow >= 0) {
                [sbTable deselectAll:nil];
                [sbTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)stationRow] byExtendingSelection:NO];
            } else {
                [wc.sidebar selectRow:stationRow];
            }
            Pump(0.2);
            std::printf("  [V2b] mode=%s row=%ld title='%s' currentContent=%s\n",
                        wc.uiMode.UTF8String ?: "", (long)wc.sidebar.selectedRow,
                        topTitle.stringValue.UTF8String ?: "",
                        NSStringFromClass(wc.currentContent.class).UTF8String);
            Ck([wc.uiMode isEqualToString:@"pro"] &&
               wc.modeControl.selectedSegment == 1 &&
               wc.sidebar.selectedRow == 0 &&
               [wc.sidebar.selectedKey isEqualToString:@"station"] &&
               [wc.currentContent isKindOfClass:RLPWorkbenchViewController.class] &&
               [wc.currentContent.view.identifier isEqualToString:@"page.station"] &&
               wc.currentContent.view.superview == pageHost &&
               pageHost.subviews.count == 1 &&
               [topTitle.stringValue isEqualToString:RLPTr(@"数字音乐台")],
               "V2b pro 模式下点击 row 0 进入 RLPWorkbenchViewController 并同步 modeControl/pageHost/标题",
               [NSString stringWithFormat:@"mode=%@ seg=%ld row=%ld/%ld key=%@ vc=%@ hostCount=%lu title=%@",
                wc.uiMode, (long)wc.modeControl.selectedSegment, (long)wc.sidebar.selectedRow, (long)stationRow,
                wc.sidebar.selectedKey ?: @"(nil)", NSStringFromClass(wc.currentContent.class),
                (unsigned long)pageHost.subviews.count, topTitle.stringValue ?: @""]);

            // V3c: 设置页 RLPSwitchToProWorkbenchNotification 切到 pro 且选中 row 0
            [wc setUiMode:@"listen" persist:NO];
            [wc.sidebar selectKey:@"albums"];
            Pump(0.1);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSwitchToProWorkbenchNotification" object:nil];
            Pump(0.15);
            Ck(wc.sidebar.selectedRow == 0 &&
               [wc.sidebar.selectedKey isEqualToString:@"station"] &&
               wc.modeControl.selectedSegment == 1 &&
               [wc.currentContent isKindOfClass:RLPWorkbenchViewController.class],
               "V3c 设置页通知切 pro 工作台同步停在 row 0 且显示 RLPWorkbenchViewController",
               [NSString stringWithFormat:@"row=%ld key=%@ seg=%ld vc=%@",
                (long)wc.sidebar.selectedRow, wc.sidebar.selectedKey ?: @"(nil)",
                (long)wc.modeControl.selectedSegment, NSStringFromClass(wc.currentContent.class)]);

            // 切回 1180x760 与 900x600，分别在中文与英文（listen / pro）下核对 V1/V4/V5
            g_spy.savedQueuesFixture = @[];
            [wc.sidebar reloadSavedQueues];
            ResizeWindow(wc, 1180, 760);
            [wc setUiMode:@"listen" persist:NO];
            [wc.sidebar selectKey:@"albums"];
            Pump(0.2);
            CheckSidebarTopEntry(wc, "zh-listen@1180", &stationRow);

            [wc setUiMode:@"pro" persist:NO];
            [wc.sidebar selectKey:@"albums"];
            Pump(0.15);
            CheckSidebarTopEntry(wc, "zh-pro@1180", &stationRow);

            RLPSetLanguage(@"en");
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
            [wc setUiMode:@"listen" persist:NO];
            Pump(0.15);
            CheckSidebarTopEntry(wc, "en-listen@1180", &stationRow);
            CheckSidebarEnglishLabel(wc, "en-listen@1180", stationRow, @"Listening Room");

            [wc setUiMode:@"pro" persist:NO];
            Pump(0.15);
            CheckSidebarTopEntry(wc, "en-pro@1180", &stationRow);
            CheckSidebarEnglishLabel(wc, "en-pro@1180", stationRow, @"Digital Music Console");

            ResizeWindow(wc, 900, 600);
            Pump(0.15);
            CheckSidebarTopEntry(wc, "en-pro@900", &stationRow);
            CheckSidebarEnglishLabel(wc, "en-pro@900", stationRow, @"Digital Music Console");

            [wc setUiMode:@"listen" persist:NO];
            Pump(0.15);
            CheckSidebarTopEntry(wc, "en-listen@900", &stationRow);
            CheckSidebarEnglishLabel(wc, "en-listen@900", stationRow, @"Listening Room");

            RLPSetLanguage(@"zh");
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
            Pump(0.1);

            // V8: 900x600 / 1180x760 × 中英文 × listen/pro 侧栏布局谐和契约（station 在 row0 且选中）
            g_spy.savedQueuesFixture = @[];
            [wc.sidebar reloadSavedQueues];
            for (NSDictionary *cfg in @[
                @{ @"name": @"zh-listen@900",  @"w": @900,  @"h": @600, @"lang": @"zh", @"mode": @"listen" },
                @{ @"name": @"zh-pro@900",     @"w": @900,  @"h": @600, @"lang": @"zh", @"mode": @"pro" },
                @{ @"name": @"en-listen@900",  @"w": @900,  @"h": @600, @"lang": @"en", @"mode": @"listen" },
                @{ @"name": @"en-pro@900",     @"w": @900,  @"h": @600, @"lang": @"en", @"mode": @"pro" },
                @{ @"name": @"zh-listen@1180", @"w": @1180, @"h": @760, @"lang": @"zh", @"mode": @"listen" },
                @{ @"name": @"en-pro@1180",    @"w": @1180, @"h": @760, @"lang": @"en", @"mode": @"pro" },
            ]) {
                RLPSetLanguage(cfg[@"lang"]);
                [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
                ResizeWindow(wc, [cfg[@"w"] doubleValue], [cfg[@"h"] doubleValue]);
                [wc setUiMode:cfg[@"mode"] persist:NO];
                [wc.sidebar selectKey:@"station"];
                Pump(0.15);
                CheckSidebarHarmony(wc, [cfg[@"name"] UTF8String], YES, YES);
            }
            g_spy.savedQueuesFixture = @[
                @{ @"name": @"Sleep Mix", @"n": @3 },
                @{ @"name": @"Jazz Hi-Res", @"n": @8 },
            ];
            [wc.sidebar reloadSavedQueues];
            RLPSetLanguage(@"zh");
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
            ResizeWindow(wc, 900, 600);
            [wc setUiMode:@"listen" persist:NO];
            [wc.sidebar selectKey:@"station"];
            Pump(0.15);
            CheckSidebarHarmony(wc, "zh-playlists@900", YES, YES);
            g_spy.savedQueuesFixture = @[];
            [wc.sidebar reloadSavedQueues];
            Pump(0.1);
        }

        // ---- R7: pro 模式真实主窗下 900x600 / 1180x760 工作台重设计几何契约 ----
        {
            g_spy.customDevicesFixture = @[
                @{ @"id": @"dev-ref", @"name": @"Reference USB DAC (CoreAudio Exclusive 32-bit)", @"default": @YES },
                @{ @"id": @"dev-alt", @"name": @"Studio Monitor Output", @"default": @NO },
            ];
            g_spy.customStatusFixture = @{
                @"ok": @YES, @"playing": @YES, @"paused": @NO, @"volDb": @(-120),
                @"current": @"/Music/ref/01.flac",
                @"title": @"Symphony No. 9 in D Minor — Adagio molto e cantabile",
                @"artist": @"Berlin Philharmonic",
                @"album": @"High Resolution Reference",
                @"inRate": @192000, @"outBits": @24, @"bitPerfect": @"yes",
            };

            NSView *pageHost = (NSView *)[wc valueForKey:@"pageHost"];
            [wc setUiMode:@"pro" persist:NO];
            [wc.sidebar selectKey:@"station"];
            Pump(0.2);

            for (NSDictionary *stageCfg in @[
                @{ @"name": @"pro-zh-light@900",  @"w": @900,  @"h": @600, @"lang": @"zh", @"theme": @"light", @"cov": @96,  @"cols": @2 },
                @{ @"name": @"pro-en-dark@900",   @"w": @900,  @"h": @600, @"lang": @"en", @"theme": @"dark",  @"cov": @96,  @"cols": @2 },
                @{ @"name": @"pro-zh-light@1180", @"w": @1180, @"h": @760, @"lang": @"zh", @"theme": @"light", @"cov": @116, @"cols": @3 },
                @{ @"name": @"pro-en-dark@1180",  @"w": @1180, @"h": @760, @"lang": @"en", @"theme": @"dark",  @"cov": @116, @"cols": @3 },
            ]) {
                const CGFloat winW = [stageCfg[@"w"] doubleValue];
                const CGFloat winH = [stageCfg[@"h"] doubleValue];
                const CGFloat expCov = [stageCfg[@"cov"] doubleValue];
                const NSInteger expCols = [stageCfg[@"cols"] integerValue];
                RLPSetLanguage(stageCfg[@"lang"]);
                [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
                [RLPTheme setThemeName:stageCfg[@"theme"]];
                [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
                ResizeWindow(wc, winW, winH);
                Pump(0.2);
                [wc.window.contentView layoutSubtreeIfNeeded];

                RLPWorkbenchViewController *wb = [wc.currentContent isKindOfClass:RLPWorkbenchViewController.class]
                    ? (RLPWorkbenchViewController *)wc.currentContent : nil;
                NSView *heroCard = wb ? FindById(wb.view, @"wb.trackcard") : nil;
                NSView *chainCard = wb ? (wb.chainCard ?: FindById(wb.view, @"wb.chaincard")) : nil;
                NSView *tabsBar = wb ? FindById(wb.view, @"wb.tabs") : nil;
                NSView *abCard = wb ? FindById(wb.view, @"wb.ab") : nil;
                NSView *profCard = wb ? FindById(wb.view, @"wb.profiles") : nil;
                NSView *rackHdr = wb ? FindById(wb.view, @"wb.rack.header") : nil;
                NSView *rackView = wb ? (wb.rackStack ?: FindById(wb.view, @"wb.rack")) : nil;
                NSView *rackPCM = wb ? (wb.rackPCM ?: FindById(wb.view, @"wb.rack.pcm")) : nil;
                NSView *rackDSD = wb ? (wb.rackDSD ?: FindById(wb.view, @"wb.rack.dsd")) : nil;
                NSView *rackOut = wb ? (wb.rackOutput ?: FindById(wb.view, @"wb.rack.output")) : nil;
                NSView *quickEq = wb ? FindById(wb.view, @"wb.quickeq") : nil;

                NSView *clipView = (wb && wb.scroll.contentView) ? wb.scroll.contentView : pageHost;
                const CGFloat clipW = clipView ? clipView.bounds.size.width : 0.0;
                const CGFloat clipH = pageHost ? pageHost.bounds.size.height : winH;

                const BOOL winFitOk = SizeMatches(wc.window.frame.size, winW, winH) &&
                                      SizeMatches(wc.window.contentView.frame.size, winW, winH);
                const BOOL covOk = wb && wb.trackCover &&
                                   Near(wb.trackCover.frame.size.width, expCov, 4.0) &&
                                   Near(wb.trackCover.frame.size.height, expCov, 14.0);
                const BOOL heroH = heroCard && heroCard.frame.size.height >= 120.0;

                BOOL allMaxXOk = (wb != nil) && (wb.stack.frame.size.width <= clipW + 1.0);
                NSMutableArray<NSString *> *clipErrs = [NSMutableArray array];
                for (NSView *v in @[ heroCard ?: (id)[NSNull null], chainCard ?: (id)[NSNull null],
                                     tabsBar ?: (id)[NSNull null], abCard ?: (id)[NSNull null],
                                     profCard ?: (id)[NSNull null], rackHdr ?: (id)[NSNull null],
                                     rackView ?: (id)[NSNull null], rackPCM ?: (id)[NSNull null],
                                     rackDSD ?: (id)[NSNull null], rackOut ?: (id)[NSNull null],
                                     quickEq ?: (id)[NSNull null] ]) {
                    if ((id)v == [NSNull null]) { allMaxXOk = NO; continue; }
                    NSRect rc = [v convertRect:v.bounds toView:clipView];
                    if (v.isHiddenOrHasHiddenAncestor || rc.size.width <= 0.5 ||
                        NSMinX(rc) < -0.5 || NSMaxX(rc) > clipW + 0.5) {
                        allMaxXOk = NO;
                        [clipErrs addObject:[NSString stringWithFormat:@"%@=%@", v.identifier, NSStringFromRect(rc)]];
                    }
                }

                BOOL abOk = wb && (wb.abSlotCards.count == 4);
                NSMutableArray<NSValue *> *abRects = [NSMutableArray array];
                NSRect abInset = abCard ? NSInsetRect(abCard.bounds, -0.5, -0.5) : NSZeroRect;
                for (NSView *slot in wb.abSlotCards) {
                    NSRect sr = [slot convertRect:slot.bounds toView:abCard];
                    NSRect sc = [slot convertRect:slot.bounds toView:clipView];
                    if (slot.isHiddenOrHasHiddenAncestor || !NSContainsRect(abInset, sr) || NSMaxX(sc) > clipW + 0.5) {
                        abOk = NO;
                        [clipErrs addObject:[NSString stringWithFormat:@"%@=%@", slot.identifier, NSStringFromRect(sc)]];
                    }
                    [abRects addObject:[NSValue valueWithRect:sr]];
                }
                for (NSUInteger i = 0; i < abRects.count; ++i) {
                    for (NSUInteger j = i + 1; j < abRects.count; ++j) {
                        if (NSIntersectsRect(NSInsetRect([abRects[i] rectValue], 0.5, 0.5),
                                             NSInsetRect([abRects[j] rectValue], 0.5, 0.5))) {
                            abOk = NO;
                        }
                    }
                }

                NSRect heroInStack = (wb && heroCard) ? [heroCard convertRect:heroCard.bounds toView:wb.stack] : NSZeroRect;
                NSRect chainInStack = (wb && chainCard) ? [chainCard convertRect:chainCard.bounds toView:wb.stack] : NSZeroRect;
                NSRect rackInStack = (wb && rackView) ? [rackView convertRect:rackView.bounds toView:wb.stack] : NSZeroRect;
                NSRect pcmInStack = (wb && rackPCM) ? [rackPCM convertRect:rackPCM.bounds toView:wb.stack] : NSZeroRect;
                NSRect dsdInStack = (wb && rackDSD) ? [rackDSD convertRect:rackDSD.bounds toView:wb.stack] : NSZeroRect;
                NSRect outInStack = (wb && rackOut) ? [rackOut convertRect:rackOut.bounds toView:wb.stack] : NSZeroRect;
                const BOOL nonOverlap = wb &&
                    !NSIntersectsRect(NSInsetRect(heroInStack, 0.5, 0.5), NSInsetRect(chainInStack, 0.5, 0.5)) &&
                    !NSIntersectsRect(NSInsetRect(heroInStack, 0.5, 0.5), NSInsetRect(rackInStack, 0.5, 0.5)) &&
                    !NSIntersectsRect(NSInsetRect(chainInStack, 0.5, 0.5), NSInsetRect(rackInStack, 0.5, 0.5)) &&
                    !NSIntersectsRect(NSInsetRect(pcmInStack, 0.5, 0.5), NSInsetRect(dsdInStack, 0.5, 0.5)) &&
                    !NSIntersectsRect(NSInsetRect(pcmInStack, 0.5, 0.5), NSInsetRect(outInStack, 0.5, 0.5)) &&
                    !NSIntersectsRect(NSInsetRect(dsdInStack, 0.5, 0.5), NSInsetRect(outInStack, 0.5, 0.5)) &&
                    (wb.rackColumns == expCols);

                CGFloat heroDistBottom = 9999.0;
                if (wb && heroCard) {
                    heroDistBottom = wb.stack.isFlipped
                        ? NSMaxY(heroInStack)
                        : (NSMaxY(wb.stack.bounds) - NSMinY(heroInStack));
                }
                const BOOL firstScreenHero = wb && !wb.trackTitle.isHiddenOrHasHiddenAncestor &&
                                             !wb.topDevicePopup.isHiddenOrHasHiddenAncestor &&
                                             heroDistBottom <= clipH + 0.5;

                std::printf("  [R7 %s] win=%.0fx%.0f clip=%.1fx%.1f cover=%.1fx%.1f hero=%.1fx%.1f bottom=%.1f rackCols=%ld\n",
                            [stageCfg[@"name"] UTF8String],
                            wc.window.frame.size.width, wc.window.frame.size.height,
                            clipW, clipH,
                            wb ? wb.trackCover.frame.size.width : 0.0,
                            wb ? wb.trackCover.frame.size.height : 0.0,
                            heroCard ? heroCard.frame.size.width : 0.0,
                            heroCard ? heroCard.frame.size.height : 0.0,
                            heroDistBottom,
                            wb ? (long)wb.rackColumns : -1L);

                Ck(winFitOk && covOk && heroH && allMaxXOk && abOk && nonOverlap && firstScreenHero,
                   [[NSString stringWithFormat:@"R7-%@ pro 工作台主窗 fit + Hero/封面/设备/信号链/A-B/机架几何正确",
                     stageCfg[@"name"]] UTF8String],
                   [NSString stringWithFormat:@"fit=%d cov=%d(%.1f) heroH=%d allX=%d ab=%d nonOv=%d cols=%ld/%ld fs=%d(%.1f/%.1f) errs=%@",
                    winFitOk, covOk, wb ? wb.trackCover.frame.size.width : 0.0, heroH,
                    allMaxXOk, abOk, nonOverlap, wb ? (long)wb.rackColumns : -1L, (long)expCols,
                    firstScreenHero, heroDistBottom, clipH, [clipErrs componentsJoinedByString:@"; "]]);
            }

            g_spy.customDevicesFixture = nil;
            g_spy.customStatusFixture = nil;
            [RLPTheme setThemeName:@"light"];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
            RLPSetLanguage(@"zh");
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
            Pump(0.1);
        }

        // ---- B1..B4: 900x600 / 1180x760 × 浅/深主题 播放条悬浮磨砂 + pageHost 延伸至底部 ----
        {
            [wc.sidebar selectKey:@"albums"];
            Pump(0.2);
            for (NSDictionary *cfg in @[
                @{ @"name": @"light@900",  @"w": @900,  @"h": @600,  @"theme": @"light" },
                @{ @"name": @"dark@900",   @"w": @900,  @"h": @600,  @"theme": @"dark" },
                @{ @"name": @"light@1180", @"w": @1180, @"h": @760,  @"theme": @"light" },
                @{ @"name": @"dark@1180",  @"w": @1180, @"h": @760,  @"theme": @"dark" },
            ]) {
                [RLPTheme setThemeName:cfg[@"theme"]];
                [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
                ResizeWindow(wc, [cfg[@"w"] doubleValue], [cfg[@"h"] doubleValue]);
                Pump(0.15);
                CheckFloatingBarAndPageExtension(wc, [cfg[@"name"] UTF8String],
                                                 [cfg[@"w"] doubleValue], [cfg[@"h"] doubleValue]);
            }
            [RLPTheme setThemeName:@"light"];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
            Pump(0.1);
        }

        // ---- R8: 播放期间点关闭（windowShouldClose:）必须立即隐藏窗口、停表、并发出非阻塞 prepareForShutdown ----
        {
            [wc.playbackBar startPolling];
            [wc.sidebar selectKey:@"albums"];
            Pump(0.1);
            g_spy.prepareForShutdownCalls = 0;
            wc.window.alphaValue = 1.0;
            BOOL delegateOk = (wc.window.delegate == (id)wc);
            BOOL shouldClose = [wc windowShouldClose:wc.window];
            BOOL hiddenNow = (wc.window.alphaValue == 0.0);
            BOOL barStopped = !wc.playbackBar.polling;
            BOOL prepared = (g_spy.prepareForShutdownCalls == 1);
            Ck(delegateOk && shouldClose && hiddenNow && barStopped && prepared,
               "R8 windowShouldClose 立即隐藏窗口、停表并触发 prepareForShutdown",
               [NSString stringWithFormat:@"del=%d should=%d alpha=%.2f barPoll=%d prep=%ld",
                delegateOk, shouldClose, wc.window.alphaValue, wc.playbackBar.polling,
                (long)g_spy.prepareForShutdownCalls]);
        }

        [wc.window orderOut:nil];
        [wc stopAllActivity];
        [wc close];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAutosaveDefaultsKey];

        std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
