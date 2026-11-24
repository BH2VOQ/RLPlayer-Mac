// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_pages_900_contract.mm — 900x600 主窗下全侧栏页宽度 + 滚动容器 + 专辑网格列数契约（P1–P5）
//
// 验证目标（纯 AppKit 离线，Accessory，backend=null，volume=-120，不出声、不碰 8899、不动键鼠）：
//   P1 每个侧栏页（albums/artists/tracks/folders/streaming/queue/recent/favorites/playlists/station/settings）：
//      pageVC.view.bounds.width == pageHost.bounds.width ±1，且 pageVC.view.frame 不超出 pageHost。
//   P2 有 NSScrollView 的页面：scroll.documentView.frame.width <= scroll.contentView.bounds.width +1。
//   P3 albums：collection.frame.width <= pageHost.width；flowLayout.itemSize.width 按 avail=host-36, gap=16, minW=152
//      计算列数 cols=floor((avail+16)/168)（674→3），断言实际 itemSize 与 cols 一致，每列卡 maxX <= collection 宽。
//   P4 settings EQ / 流媒体 / 输入 / 输出 / 诊断 pane 在 900x600 下无横向溢出。
//   P5 页面切换 3 轮（albums → queue → station → albums）及缩窗缓存重入后宽度与列数仍正确。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPAlbumsViewController.h"
#import "RLPFoldersViewController.h"
#import "RLPWorksViewController.h"
#import "RLPFeedbackWindowController.h"
#import "RLPPlaylistsViewController.h"
#import "RLPUpdateWindowController.h"
#import "RLPSettingsViewController.h"
#import "RLPSettingsLayout.h"
#import "RLPCastView.h"
#import "RLPInputView.h"
#import "RLPLibStatsView.h"
#import "RLPEqualizerView.h"
#import "RLPEQFaderView.h"
#import "RLPEQFaderInspector.h"
#import "RLPMetaSourcesView.h"
#import "RLPVolumeSliderView.h"
#import "RLPWorkbenchViewController.h"
#import "RLPTheme.h"
#import "RLPSupport.h"
#import "RLPPlaybackBarView.h"
#import "RLPKnowledgeView.h"
#import "RLPRightDrawer.h"
#import "RLPServersView.h"
#import "RLPCalibrationView.h"
#import "RLPTracksViewController.h"
#import "RLPArtistDetailViewController.h"
#import "RLPAlbumDetailViewController.h"
#import "RLPQueueViewController.h"
#import "RLPPageViewController.h"
#import "RLPNowPlayingViewController.h"
#import "RLPQuickStartViewController.h"
#import "RLPRecentViewController.h"
#import "RLPFavoritesViewController.h"
#import "RLPStreamingViewController.h"
#import "RLPArtistsViewController.h"

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

@interface RLPPages900SpyClient : NSObject
@property (nonatomic, copy) NSString *uiMode;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *settingsKv;
@property (nonatomic, copy, nullable) NSDictionary *castStateOverride;
@property (nonatomic, copy, nullable) NSDictionary *inputStateOverride;
@property (nonatomic, copy, nullable) NSDictionary *libStatsOverride;
@property (nonatomic, copy, nullable) NSDictionary *peqOverride;
@property (nonatomic, copy, nullable) NSDictionary *providersOverride;
@property (nonatomic, copy, nullable) NSDictionary *entityVersionsOverride;
@property (nonatomic, copy, nullable) NSDictionary *lyricsOverride;
@property (nonatomic, copy, nullable) NSDictionary *queueOverride;
@property (nonatomic, copy, nullable) NSDictionary *serversOverride;
@property (nonatomic, copy, nullable) NSDictionary *micCalOverride;
@property (nonatomic, copy, nullable) NSDictionary *albumsOverride;
@property (nonatomic, copy, nullable) NSDictionary *recentOverride;
@property (nonatomic, copy, nullable) NSDictionary *favoritesOverride;
@property (nonatomic, copy, nullable) NSDictionary *searchOverride;
@property (nonatomic, copy, nullable) NSDictionary *filesOverride;
@property (nonatomic, copy, nullable) NSDictionary *srcBrowseOverride;
@property (nonatomic, copy, nullable) NSDictionary *albumDetailOverride;
@property (nonatomic, copy, nullable) NSDictionary *sqListOverride;
@property (nonatomic, copy, nullable) NSDictionary *sqInfoOverride;
@property (nonatomic, strong) NSMutableArray<NSString *> *getCalls;
@end

@implementation RLPPages900SpyClient
- (instancetype)init {
    self = [super init];
    if (self) {
        _uiMode = @"listen";
        _getCalls = [NSMutableArray array];
        _settingsKv = [@{
            @"uimode": @"listen",
            @"backend": @"null",
            @"volume": @"-120",
            @"theme": @"light",
            @"channels": @"0",
            @"metaon": @"1",
            @"metallm": @"0",
            @"metasummary": @"0",
            @"rate": @"src",
            @"directsdm": @"0",
            @"cast_upsample": @"0",
            @"cast_upsample_ceiling": @"auto",
            @"cast_upsample_force": @"0",
        } mutableCopy];
    }
    return self;
}
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
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
    if (path) [self.getCalls addObject:path];
    if (!done) return;
    NSDictionary *json = [self fixtureForPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    if ([path isEqualToString:@"/api/settings"] && body.length > 0) {
        for (NSString *part in [body componentsSeparatedByString:@"&"]) {
            NSRange eq = [part rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *k = [[part substringToIndex:eq.location] stringByRemovingPercentEncoding]
                ?: [part substringToIndex:eq.location];
            NSString *v = [[part substringFromIndex:eq.location + 1] stringByRemovingPercentEncoding]
                ?: [part substringFromIndex:eq.location + 1];
            if (k.length) self.settingsKv[k] = v ?: @"";
            if ([k isEqualToString:@"uimode"]) {
                self.uiMode = [v isEqualToString:@"pro"] ? @"pro" : @"listen";
            }
        }
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
        NSMutableDictionary *kv = [self.settingsKv mutableCopy];
        kv[@"uimode"] = self.uiMode ?: @"listen";
        return @{ @"ok": @YES, @"kv": kv };
    }
    if ([path hasPrefix:@"/api/status"]) return @{ @"ok": @YES, @"playing": @NO, @"paused": @NO, @"volDb": @(-120) };
    if ([path hasPrefix:@"/api/playmode"]) return @{ @"ok": @YES, @"mode": @1 };
    if ([path hasPrefix:@"/api/writeback/status"]) return @{ @"ok": @YES, @"running": @NO };
    if ([path hasPrefix:@"/api/queue"]) return self.queueOverride ?: @{ @"ok": @YES, @"items": @[], @"index": @0, @"mode": @0 };
    if ([path hasPrefix:@"/api/lib/albums"]) {
        if (self.albumsOverride) return self.albumsOverride;
        NSMutableArray *a = [NSMutableArray array];
        for (int i = 0; i < 24; ++i) {
            [a addObject:@{
                @"k": [NSString stringWithFormat:@"a%03d", i],
                @"name": [NSString stringWithFormat:@"Album %03d", i],
                @"artist": @"Artist Name",
                @"year": @(2000 + i % 20),
                @"n": @10, @"dur": @(2400.0), @"sr": @44100, @"bits": @16, @"cv": @NO
            }];
        }
        return @{ @"ok": @YES, @"albums": a };
    }
    if ([path hasPrefix:@"/api/lib/album?"]) {
        return self.albumDetailOverride ?: @{ @"ok": @YES, @"name": @"Mock Album", @"artist": @"Mock Artist", @"tracks": @[] };
    }
    if ([path hasPrefix:@"/api/lib/artists"]) return @{ @"ok": @YES, @"artists": @[] };
    if ([path hasPrefix:@"/api/lib/search"]) return self.searchOverride ?: @{ @"ok": @YES, @"tracks": @[], @"total": @0, @"n": @0 };
    if ([path hasPrefix:@"/api/files"]) return self.filesOverride ?: @{ @"ok": @YES, @"dir": @"/Music", @"dirs": @[], @"files": @[] };
    if ([path hasPrefix:@"/api/lib/stats"]) {
        return self.libStatsOverride ?: @{ @"ok": @YES, @"roots": @[@"/Music"] };
    }
    if ([path hasPrefix:@"/api/lib/roots"]) return @{ @"ok": @YES, @"roots": @[@"/Music"] };
    if ([path hasPrefix:@"/api/sq/list"]) return self.sqListOverride ?: @{ @"ok": @YES, @"queues": @[] };
    if ([path hasPrefix:@"/api/sq/info"]) return self.sqInfoOverride ?: @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/input/devices"]) {
        return @{ @"ok": @YES, @"devices": @[@{ @"id": @"mic-1", @"name": @"USB Mic", @"channels": @2, @"loopback": @NO }] };
    }
    if ([path hasPrefix:@"/api/input/state"]) {
        return self.inputStateOverride ?: @{ @"ok": @YES, @"running": @NO };
    }
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/preset/caps"]) return @{ @"ok": @YES, @"known": @YES, @"pcmReady": @YES, @"dsdReady": @YES };
    if ([path hasPrefix:@"/api/cast/devices"]) return @{ @"ok": @YES, @"devices": @[], @"hint": @"" };
    if ([path hasPrefix:@"/api/cast/state"]) {
        return self.castStateOverride ?: @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    }
    if ([path hasPrefix:@"/api/profiles"]) return @{ @"ok": @YES, @"profiles": @[] };
    if ([path hasPrefix:@"/api/peq"]) return self.peqOverride ?: @{ @"ok": @YES, @"enabled": @NO, @"bands": @[] };
    if ([path hasPrefix:@"/api/opra/index"]) return @{ @"ok": @YES, @"items": @[ @[ @"p1", @"Sennheiser", @"HD 650" ] ] };
    if ([path hasPrefix:@"/api/opra/presets"]) return @{ @"ok": @YES, @"items": @[ @{ @"id": @"pr1", @"author": @"oratory1990", @"details": @"Harman Target", @"gainDb": @(-5.5), @"bandsCount": @10 } ] };
    if ([path hasPrefix:@"/api/providers"]) return self.providersOverride ?: @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/llm/models"]) return @{ @"ok": @NO, @"models": @[] };
    if ([path hasPrefix:@"/api/llm"]) return @{ @"ok": @YES, @"configured": @NO };
    if ([path hasPrefix:@"/api/entity/versions"]) return self.entityVersionsOverride ?: @{ @"ok": @YES, @"performances": @[], @"work": @"Test Work", @"composer": @"Bach" };
    if ([path hasPrefix:@"/api/lyrics"]) return self.lyricsOverride ?: @{ @"ok": @NO };
    if ([path hasPrefix:@"/api/src/config"]) return self.serversOverride ?: @{ @"ok": @YES, @"servers": @[] };
    if ([path hasPrefix:@"/api/src/browse"]) return self.srcBrowseOverride ?: @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/miccal"]) return self.micCalOverride ?: @{ @"ok": @YES, @"active": @NO };
    if ([path hasPrefix:@"/api/recent"]) return self.recentOverride ?: @{ @"ok": @YES, @"tracks": @[] };
    if ([path hasPrefix:@"/api/fav/list"]) return self.favoritesOverride ?: @{ @"ok": @YES, @"files": @[] };
    return @{ @"ok": @YES };
}
@end

static RLPPages900SpyClient *g_spy = nil;
static id FakeSharedClient(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }
static void NoopProbe(id self, SEL sel) { (void)self; (void)sel; }

static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static void ResizeWindow(RLPMainWindowController *wc, CGFloat w, CGFloat h) {
    NSRect f = wc.window.frame;
    f.size = NSMakeSize(w, h);
    [wc.window setFrame:f display:NO];
    [wc.window.contentView layoutSubtreeIfNeeded];
    Pump(0.15);
    [wc.window.contentView layoutSubtreeIfNeeded];
}

static BOOL IsHiddenInHierarchy(NSView *v, NSView *stopAt) {
    for (NSView *cur = v; cur && cur != stopAt; cur = cur.superview) {
        if (cur.hidden) return YES;
    }
    return NO;
}

static void CollectScrollViews(NSView *root, NSMutableArray<NSScrollView *> *out) {
    if (!root) return;
    if ([root isKindOfClass:[NSScrollView class]]) {
        [out addObject:(NSScrollView *)root];
    }
    for (NSView *sub in root.subviews) {
        CollectScrollViews(sub, out);
    }
}

static void CollectSettingsGroups(NSView *root, NSMutableArray<NSView *> *out) {
    if (!root) return;
    if ([root isKindOfClass:[RLPSettingsGroup class]]) {
        [out addObject:root];
    }
    for (NSView *sub in root.subviews) {
        CollectSettingsGroups(sub, out);
    }
}

static NSView *FindStationViewById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *sub in root.subviews) {
        NSView *r = FindStationViewById(sub, ident);
        if (r) return r;
    }
    return nil;
}

static NSString *FormatStationColor(CGColorRef cg) {
    if (!cg) return @"nil";
    NSColor *c = [[NSColor colorWithCGColor:cg] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!c) return @"non-srgb";
    return [NSString stringWithFormat:@"rgba(%d,%d,%d,%.2f)",
            (int)std::lround(c.redComponent * 255.0),
            (int)std::lround(c.greenComponent * 255.0),
            (int)std::lround(c.blueComponent * 255.0),
            c.alphaComponent];
}

static BOOL StationColorsClose(CGColorRef a, CGColorRef b) {
    if (!a && !b) return YES;
    if (!a || !b) return NO;
    NSColor *ca = [[NSColor colorWithCGColor:a] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *cb = [[NSColor colorWithCGColor:b] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!ca || !cb) return CGColorEqualToColor(a, b);
    return std::fabs(ca.redComponent - cb.redComponent) < 0.01 &&
           std::fabs(ca.greenComponent - cb.greenComponent) < 0.01 &&
           std::fabs(ca.blueComponent - cb.blueComponent) < 0.01 &&
           std::fabs(ca.alphaComponent - cb.alphaComponent) < 0.01;
}

typedef void (*RLP900AddCursorRectImp)(id, SEL, NSRect, NSCursor *);
static RLP900AddCursorRectImp g900OrigAddCursorRect = NULL;
static BOOL g900CapturedHandCursor = NO;
static NSView *g900CursorTarget = nil;

static void RLP900TestAddCursorRect(id self, SEL _cmd, NSRect rect, NSCursor *cursor) {
    if (self == g900CursorTarget && cursor == [NSCursor pointingHandCursor] &&
        rect.size.width > 0.0 && rect.size.height > 0.0) {
        g900CapturedHandCursor = YES;
    }
    if (g900OrigAddCursorRect) g900OrigAddCursorRect(self, _cmd, rect, cursor);
}

static BOOL StationViewHasHandCursor(NSView *view) {
    Method m = class_getInstanceMethod([NSView class], @selector(addCursorRect:cursor:));
    g900OrigAddCursorRect = (RLP900AddCursorRectImp)method_getImplementation(m);
    g900CapturedHandCursor = NO;
    g900CursorTarget = view;
    method_setImplementation(m, (IMP)RLP900TestAddCursorRect);
    @try {
        [view resetCursorRects];
    } @finally {
        method_setImplementation(m, (IMP)g900OrigAddCursorRect);
        g900OrigAddCursorRect = NULL;
        g900CursorTarget = nil;
    }
    return g900CapturedHandCursor;
}

static void VerifyStationControls(const char *stage, RLPMainWindowController *wc) {
    NSViewController *pageVC = wc.currentContent;
    NSView *pageHost = [wc valueForKey:@"pageHost"];
    if (!pageVC || !pageVC.view || !pageHost) return;
    NSView *root = pageVC.view;
    const CGFloat hostW = NSWidth(pageHost.bounds);

    NSArray<NSArray *> *specs = @[
        @[@"room.folders",       @"room.folders.chevron",       @YES],
        @[@"room.deviceRefresh", @"",                           @NO],
        @[@"room.devicePopup",   @"room.devicePopup.chevron",   @YES],
        @[@"room.output.button", @"room.output.chevron",        @YES],
        @[@"room.play.button",   @"room.play.chevron",          @YES],
        @[@"room.style.button",  @"room.style.chevron",         @YES],
        @[@"room.playToggle",    @"",                           @NO],
        @[@"room.openAlbum",     @"room.openAlbum.chevron",     @YES],
        @[@"room.queueAll",      @"room.queueAll.chevron",      @YES],
        @[@"room.openAlbums",    @"room.openAlbums.chevron",    @YES],
        @[@"room.libraryAction", @"room.libraryAction.chevron", @YES],
        @[@"room.more",          @"room.more.chevron",          @YES],
    ];

    for (NSArray *sp in specs) {
        NSString *bid = sp[0];
        NSString *cid = sp[1];
        const BOOL needChev = [sp[2] boolValue];
        NSView *ctrl = FindStationViewById(root, bid);
        Ck(ctrl != nil && !ctrl.hidden,
           [[NSString stringWithFormat:@"STATION %s [%@] 按钮控件存在且可见", stage, bid] UTF8String],
           @"nil or hidden");
        if (!ctrl) continue;

        NSRect frInHost = [ctrl convertRect:ctrl.bounds toView:pageHost];
        CGColorRef bg = ctrl.layer ? ctrl.layer.backgroundColor : NULL;
        CGColorRef bd = ctrl.layer ? ctrl.layer.borderColor : NULL;
        const CGFloat bw = ctrl.layer ? ctrl.layer.borderWidth : 0.0;
        const CGFloat cr = ctrl.layer ? ctrl.layer.cornerRadius : 0.0;
        const BOOL sizeOk = NSHeight(ctrl.frame) >= 28.0 && NSWidth(ctrl.frame) >= 28.0;
        const BOOL fitsHost = NSMinX(frInHost) >= -1.0 && NSMaxX(frInHost) <= hostW + 1.0;
        const BOOL styleOk = ctrl.wantsLayer && bg != NULL && CGColorGetAlpha(bg) > 0.01 &&
                             bw >= 1.0 && bd != NULL && CGColorGetAlpha(bd) > 0.01 && cr >= 4.0;
        const BOOL trackOk = ctrl.trackingAreas.count >= 1;
        const BOOL handOk = StationViewHasHandCursor(ctrl);

        BOOL chevOk = YES;
        if (needChev) {
            NSView *chev = FindStationViewById(ctrl, cid);
            chevOk = chev != nil && !chev.hidden && chev.alphaValue > 0.5 &&
                     NSWidth(chev.frame) > 0.0 && NSHeight(chev.frame) > 0.0;
        }

        std::printf("  [station %-12s %-20s] frame=%s h=%.1f hostMaxX=%.1f/%.1f bg=%s bd=%s(w=%.1f) track=%lu hand=%d chev=%d\n",
                    stage, bid.UTF8String, NSStringFromRect(ctrl.frame).UTF8String,
                    NSHeight(ctrl.frame), NSMaxX(frInHost), hostW,
                    FormatStationColor(bg).UTF8String, FormatStationColor(bd).UTF8String, bw,
                    (unsigned long)ctrl.trackingAreas.count, handOk, chevOk);

        Ck(sizeOk && fitsHost && styleOk && trackOk && handOk && chevOk,
           [[NSString stringWithFormat:@"STATION %s [%@] 高度>=28/不溢出/背景描边/hover与手型/chevron", stage, bid] UTF8String],
           [NSString stringWithFormat:@"h=%.1f fits=%d style=%d track=%lu hand=%d chev=%d",
            NSHeight(ctrl.frame), fitsHost, styleOk, (unsigned long)ctrl.trackingAreas.count, handOk, chevOk]);
    }

    NSView *capsCard = FindStationViewById(root, @"room.caps");
    NSView *devCard  = FindStationViewById(root, @"room.device");
    NSView *outCard  = FindStationViewById(root, @"room.output");
    NSView *playCard = FindStationViewById(root, @"room.play");
    NSView *styCard  = FindStationViewById(root, @"room.style");
    if (capsCard && devCard && outCard && playCard && styCard) {
        const BOOL passiveOk = (capsCard.trackingAreas.count == 0 && !StationViewHasHandCursor(capsCard) &&
                                devCard.trackingAreas.count == 0 && !StationViewHasHandCursor(devCard));
        BOOL interactiveCardsOk = YES;
        for (NSView *ic in @[outCard, playCard, styCard]) {
            CGColorRef restBd = ic.layer.borderColor;
            const BOOL trackOk = ic.trackingAreas.count >= 1;
            const BOOL handOk = StationViewHasHandCursor(ic);
            const BOOL distinct = !StationColorsClose(restBd, capsCard.layer.borderColor);
            [ic mouseEntered:[NSEvent enterExitEventWithType:NSEventTypeMouseEntered
                                                    location:NSZeroPoint
                                               modifierFlags:0
                                                   timestamp:0
                                                windowNumber:wc.window.windowNumber
                                                     context:nil
                                                 eventNumber:0
                                              trackingNumber:0
                                                    userData:NULL]];
            const BOOL hovOk = (ic.layer.borderWidth >= 1.4) && !StationColorsClose(restBd, ic.layer.borderColor);
            [ic mouseExited:[NSEvent enterExitEventWithType:NSEventTypeMouseExited
                                                   location:NSZeroPoint
                                              modifierFlags:0
                                                  timestamp:0
                                               windowNumber:wc.window.windowNumber
                                                    context:nil
                                                eventNumber:0
                                             trackingNumber:0
                                                   userData:NULL]];
            const BOOL resOk = (ic.layer.borderWidth <= 1.1) && StationColorsClose(restBd, ic.layer.borderColor);
            std::printf("  [station-card %-10s %-12s] bd=%s(w=%.1f) capsBd=%s(w=%.1f) track=%lu hand=%d hov=%d/%d\n",
                        stage, ic.identifier.UTF8String,
                        FormatStationColor(restBd).UTF8String, ic.layer.borderWidth,
                        FormatStationColor(capsCard.layer.borderColor).UTF8String, capsCard.layer.borderWidth,
                        (unsigned long)ic.trackingAreas.count, handOk, hovOk, resOk);
            if (!trackOk || !handOk || !distinct || !hovOk || !resOk) {
                interactiveCardsOk = NO;
            }
        }
        Ck(passiveOk && interactiveCardsOk,
           [[NSString stringWithFormat:@"STATION %s 可点卡片与纯展示/下拉容器区分明显且 hover 可反馈/恢复", stage] UTF8String],
           [NSString stringWithFormat:@"passive=%d interactive=%d", passiveOk, interactiveCardsOk]);
    }

    NSView *devRefresh = FindStationViewById(root, @"room.deviceRefresh");
    NSView *devPopup = FindStationViewById(root, @"room.devicePopup");
    NSView *npCard = FindStationViewById(root, @"room.nowplaying");
    NSView *npTog = FindStationViewById(root, @"room.playToggle");
    NSView *npOpn = FindStationViewById(root, @"room.openAlbum");
    if (devCard && devRefresh && devPopup && npCard && npTog && npOpn) {
        NSRect rRef = [devRefresh convertRect:devRefresh.bounds toView:devCard];
        NSRect rPop = [devPopup convertRect:devPopup.bounds toView:devCard];
        NSRect rTog = [npTog convertRect:npTog.bounds toView:npCard];
        NSRect rOpn = [npOpn convertRect:npOpn.bounds toView:npCard];
        const BOOL layoutSafe = NSIsEmptyRect(NSIntersectionRect(rRef, rPop)) &&
                                NSIsEmptyRect(NSIntersectionRect(rTog, rOpn)) &&
                                NSMaxX(rRef) <= NSWidth(devCard.bounds) + 1.0 &&
                                NSMaxX(rPop) <= NSWidth(devCard.bounds) + 1.0 &&
                                NSMaxX(rOpn) <= NSWidth(npCard.bounds) + 1.0;
        Ck(layoutSafe,
           [[NSString stringWithFormat:@"STATION %s 强化按钮后无重叠且不溢出所属卡片", stage] UTF8String],
           [NSString stringWithFormat:@"ref=%@ pop=%@ tog=%@ opn=%@",
            NSStringFromRect(rRef), NSStringFromRect(rPop), NSStringFromRect(rTog), NSStringFromRect(rOpn)]);
    }
}

static void VerifyPageP1AndP2(const char *stage, RLPMainWindowController *wc, NSString *key, CGFloat expectedWinW, CGFloat expectedWinH) {
    NSViewController *pageVC = wc.currentContent;
    NSView *mainHost = [wc valueForKey:@"mainHost"];
    NSView *topbar = [wc valueForKey:@"topbar"];
    NSView *pageHost = [wc valueForKey:@"pageHost"];
    RLPPlaybackBarView *bar = wc.playbackBar;
    const NSSize winSz = wc.window.frame.size;

    Ck(std::fabs(winSz.width - expectedWinW) <= 1.0 && std::fabs(winSz.height - expectedWinH) <= 1.0,
       [[NSString stringWithFormat:@"%s [%@] 窗口尺寸保持 %.0fx%.0f", stage, key, expectedWinW, expectedWinH] UTF8String],
       [NSString stringWithFormat:@"win=%.1fx%.1f", winSz.width, winSz.height]);

    Ck(pageVC != nil && pageVC.view != nil && pageHost != nil && mainHost != nil && topbar != nil && bar != nil,
       [[NSString stringWithFormat:@"%s [%@] pageVC 与 pageHost/mainHost/bar 存在", stage, key] UTF8String],
       @"nil");
    if (!pageVC || !pageVC.view || !pageHost || !mainHost || !topbar || !bar) return;

    const NSRect pageInMain = [pageHost convertRect:pageHost.bounds toView:mainHost];
    const NSRect topInMain = [topbar convertRect:topbar.bounds toView:mainHost];
    const NSRect barInMain = [bar convertRect:bar.bounds toView:mainHost];
    const BOOL hostExtendedToBottom =
        std::fabs(NSMinY(pageInMain) - NSMinY(mainHost.bounds)) <= 1.0 &&
        std::fabs(NSMaxY(pageInMain) - NSMinY(topInMain)) <= 1.0 &&
        NSIntersectsRect(pageInMain, barInMain);
    Ck(hostExtendedToBottom,
       [[NSString stringWithFormat:@"P1-ext %s [%@] pageHost 延伸至 mainHost 底部 (top=topbar.bottom)", stage, key] UTF8String],
       [NSString stringWithFormat:@"page=%@ main=%@ top=%@ bar=%@",
        NSStringFromRect(pageInMain), NSStringFromRect(mainHost.bounds),
        NSStringFromRect(topInMain), NSStringFromRect(barInMain)]);

    const CGFloat hostW = pageHost.bounds.size.width;
    const CGFloat hostH = pageHost.bounds.size.height;
    const CGFloat pageW = pageVC.view.bounds.size.width;
    const NSRect pf = pageVC.view.frame;

    Ck(std::fabs(pageW - hostW) <= 1.0,
       [[NSString stringWithFormat:@"P1 %s [%@] pageVC.view.bounds.width == pageHost.width (±1)", stage, key] UTF8String],
       [NSString stringWithFormat:@"page=%.1f host=%.1f", pageW, hostW]);

    Ck(pf.origin.x >= -1.0 && NSMaxX(pf) <= hostW + 1.0 &&
       pf.origin.y >= -1.0 && NSMaxY(pf) <= hostH + 1.0,
       [[NSString stringWithFormat:@"P1 %s [%@] pageVC.view.frame 不超出 pageHost", stage, key] UTF8String],
       [NSString stringWithFormat:@"frame=%@ hostBounds=%.1fx%.1f", NSStringFromRect(pf), hostW, hostH]);

    NSMutableArray<NSScrollView *> *scrolls = [NSMutableArray array];
    CollectScrollViews(pageVC.view, scrolls);
    CGFloat maxOverflow = 0.0;
    NSMutableArray<NSString *> *badScrolls = [NSMutableArray array];
    NSMutableArray<NSString *> *badInsets = [NSMutableArray array];
    const CGFloat barClearTop = NSMaxY(barInMain) + 14.0;
    const BOOL checkInsetStrict = (stage != NULL && ![@(stage) hasPrefix:@"P4-pane"]);
    for (NSScrollView *sv in scrolls) {
        if (IsHiddenInHierarchy(sv, pageVC.view)) continue;
        if (!sv.contentView || !sv.documentView) continue;
        const CGFloat clipW = sv.contentView.bounds.size.width;
        const CGFloat docW = sv.documentView.frame.size.width;
        const CGFloat overflow = docW - clipW;
        if (overflow > maxOverflow) maxOverflow = overflow;
        if (docW > clipW + 1.0) {
            [badScrolls addObject:[NSString stringWithFormat:@"%@(doc=%.1f clip=%.1f)",
                                   NSStringFromClass(sv.documentView.class), docW, clipW]];
        }
        if (checkInsetStrict && sv.enclosingScrollView == nil &&
            NSHeight(sv.bounds) >= 120.0 && !(sv.hasHorizontalScroller && !sv.hasVerticalScroller)) {
            const NSRect svInHost = [sv convertRect:sv.bounds toView:pageHost];
            const CGFloat svMinY = NSMinY(svInHost);
            if (svMinY < barClearTop - 0.5) {
                const CGFloat needBottom = barClearTop - svMinY;
                if (sv.contentInsets.bottom < needBottom - 1.0) {
                    [badInsets addObject:[NSString stringWithFormat:@"%@(minY=%.1f bottom=%.1f<%.1f)",
                                          NSStringFromClass(sv.documentView.class),
                                          svMinY, sv.contentInsets.bottom, needBottom]];
                }
            }
        }
    }
    std::printf("  [page %-12s %s] host=%.1fx%.1f page=%.1f frameMaxX=%.1f scrolls=%lu maxDocOverflow=%.1f\n",
                key.UTF8String, stage, hostW, hostH, pageW, NSMaxX(pf),
                (unsigned long)scrolls.count, maxOverflow);

    if (scrolls.count > 0) {
        Ck(badScrolls.count == 0,
           [[NSString stringWithFormat:@"P2 %s [%@] NSScrollView doc.width <= clip.width +1", stage, key] UTF8String],
           [badScrolls componentsJoinedByString:@"; "]);
        if (checkInsetStrict) {
            Ck(badInsets.count == 0,
               [[NSString stringWithFormat:@"P2-inset %s [%@] 顶层 NSScrollView 底部预留内边距避让悬浮条", stage, key] UTF8String],
               [badInsets componentsJoinedByString:@"; "]);
        }
    }
}

static void VerifyAlbumsP3(const char *stage, RLPMainWindowController *wc) {
    NSView *pageHost = [wc valueForKey:@"pageHost"];
    RLPAlbumsViewController *albumsVC = [wc.currentContent isKindOfClass:[RLPAlbumsViewController class]]
        ? (RLPAlbumsViewController *)wc.currentContent : nil;
    Ck(albumsVC != nil, [[NSString stringWithFormat:@"P3 %s 当前为 RLPAlbumsViewController", stage] UTF8String],
       NSStringFromClass(wc.currentContent.class));
    if (!albumsVC || !pageHost) return;

    NSCollectionView *col = (NSCollectionView *)[albumsVC valueForKey:@"collection"];
    NSCollectionViewFlowLayout *flow = [col.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]
        ? (NSCollectionViewFlowLayout *)col.collectionViewLayout : nil;
    Ck(col != nil && flow != nil,
       [[NSString stringWithFormat:@"P3 %s collection 与 FlowLayout 存在", stage] UTF8String], @"nil");
    if (!col || !flow) return;

    const CGFloat hostW = pageHost.bounds.size.width;
    const CGFloat pageW = albumsVC.view.bounds.size.width;
    const CGFloat clipW = col.enclosingScrollView ? col.enclosingScrollView.contentView.bounds.size.width : col.bounds.size.width;
    const CGFloat colFrameW = col.frame.size.width;
    const CGFloat colBoundsW = col.bounds.size.width;

    const CGFloat availHost = hostW - 36.0;
    NSInteger expectedCols = (NSInteger)std::floor((availHost + 16.0) / 168.0);
    if (expectedCols < 1) expectedCols = 1;

    const CGFloat availClip = clipW - 36.0;
    NSInteger colsFromClip = (NSInteger)std::floor((availClip + 16.0) / 168.0);
    if (colsFromClip < 1) colsFromClip = 1;
    const CGFloat expectedItemW = std::floor((availClip - 16.0 * (colsFromClip - 1)) / colsFromClip);

    const NSInteger itemCount = [col numberOfItemsInSection:0];
    CGFloat row0MaxX = 0.0;
    NSInteger actualRow0Cols = 0;
    BOOL row0Fits = YES;
    BOOL itemWidthMatches = YES;
    NSMutableArray<NSString *> *badItems = [NSMutableArray array];

    if (itemCount >= expectedCols + 1) {
        NSCollectionViewLayoutAttributes *a0 = [col layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
        const CGFloat y0 = a0 ? a0.frame.origin.y : 0.0;
        for (NSInteger i = 0; i < itemCount && i < expectedCols + 2; ++i) {
            NSCollectionViewLayoutAttributes *ai = [col layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]];
            if (!ai) { row0Fits = NO; break; }
            if (std::fabs(ai.frame.origin.y - y0) <= 1.0) {
                ++actualRow0Cols;
                if (NSMaxX(ai.frame) > row0MaxX) row0MaxX = NSMaxX(ai.frame);
                if (NSMaxX(ai.frame) > colBoundsW + 0.5 || NSMaxX(ai.frame) > hostW + 0.5) {
                    row0Fits = NO;
                    [badItems addObject:[NSString stringWithFormat:@"#%ld maxX=%.1f", (long)i, NSMaxX(ai.frame)]];
                }
                if (std::fabs(ai.frame.size.width - flow.itemSize.width) > 1.0) {
                    itemWidthMatches = NO;
                    [badItems addObject:[NSString stringWithFormat:@"#%ld w=%.1f!=%.1f", (long)i, ai.frame.size.width, flow.itemSize.width]];
                }
            } else {
                break;
            }
        }
    }

    std::printf("  [P3 %-16s] host=%.1f page=%.1f clip=%.1f collection=%.1f item=%.1fx%.1f expectedCols=%ld actualRow0Cols=%ld row0MaxX=%.1f\n",
                stage, hostW, pageW, clipW, colFrameW, flow.itemSize.width, flow.itemSize.height,
                (long)expectedCols, (long)actualRow0Cols, row0MaxX);

    Ck(colFrameW <= hostW + 1.0 && colBoundsW <= hostW + 1.0,
       [[NSString stringWithFormat:@"P3 %s collection.frame.width <= pageHost.width", stage] UTF8String],
       [NSString stringWithFormat:@"col=%.1f host=%.1f", colFrameW, hostW]);

    Ck(colsFromClip == expectedCols && std::fabs(flow.itemSize.width - expectedItemW) <= 1.0 && flow.itemSize.width >= 152.0,
       [[NSString stringWithFormat:@"P3 %s flowLayout.itemSize 与计算列数 (%ld) 一致", stage, (long)expectedCols] UTF8String],
       [NSString stringWithFormat:@"item=%.1f expected=%.1f cols=%ld/%ld host=%.1f clip=%.1f",
        flow.itemSize.width, expectedItemW, (long)colsFromClip, (long)expectedCols, hostW, clipW]);

    Ck(itemCount >= expectedCols + 1 && actualRow0Cols == expectedCols && row0Fits && itemWidthMatches,
       [[NSString stringWithFormat:@"P3 %s 首行实际列数=%ld 且每列卡 maxX <= collection 宽", stage, (long)expectedCols] UTF8String],
       [NSString stringWithFormat:@"count=%ld row0Cols=%ld row0MaxX=%.1f colW=%.1f bad=[%@]",
        (long)itemCount, (long)actualRow0Cols, row0MaxX, colBoundsW, [badItems componentsJoinedByString:@", "]]);
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        static NSString *const kAutosaveDefaultsKey = @"NSWindow Frame RLPNativeMainWindow.v2";
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAutosaveDefaultsKey];

        g_spy = [[RLPPages900SpyClient alloc] init];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        RLPSetLanguage(@"zh");
        [RLPSettingsViewController setRlp_confirmsBitPerfectFix:NO];

        Method sharedM = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        method_setImplementation(sharedM, (IMP)FakeSharedClient);
        Method probeM = class_getInstanceMethod(RLPSettingsViewController.class, @selector(probeFeedbackChannel));
        if (probeM) method_setImplementation(probeM, (IMP)NoopProbe);

        std::printf("=== test_native_pages_900_contract（900x600 全侧栏页 + 专辑网格 + 设置页 + 缓存重入）===\n");

        RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
        wc.window.releasedWhenClosed = NO;
        [wc.window setFrameAutosaveName:@""];
        ResizeWindow(wc, 900.0, 600.0);

        NSArray<NSString *> *keys = @[
            @"albums", @"artists", @"tracks", @"folders", @"streaming",
            @"queue", @"recent", @"favorites", @"playlists", @"station", @"settings"
        ];

        // ---- P1 / P2 / P3: 遍历全部 11 个侧栏页 ----
        for (NSString *key in keys) {
            [wc.sidebar selectKey:key];
            Pump(0.2);
            [wc.window.contentView layoutSubtreeIfNeeded];
            VerifyPageP1AndP2("tour@900", wc, key, 900.0, 600.0);
            if ([key isEqualToString:@"albums"]) {
                VerifyAlbumsP3("tour@900", wc);
            } else if ([key isEqualToString:@"station"]) {
                VerifyStationControls("tour@900", wc);
            }
        }

        // ---- P4: settings EQ / 流媒体 / 输入 / 输出 / 诊断 pane 在 900x600 下无横向溢出 ----
        [wc.sidebar selectKey:@"settings"];
        Pump(0.2);
        [wc.window.contentView layoutSubtreeIfNeeded];
        RLPSettingsViewController *settings = [wc.currentContent isKindOfClass:[RLPSettingsViewController class]]
            ? (RLPSettingsViewController *)wc.currentContent : nil;
        Ck(settings != nil, "P4 进入 settings 成功", NSStringFromClass(wc.currentContent.class));
        if (settings) {
            NSView *paneHost = [settings valueForKey:@"paneHost"];
            for (NSString *pane in @[ @"eq", @"cal", @"stream", @"in", @"out", @"diag" ]) {
                [settings selectPane:pane];
                Pump(0.15);
                [wc.window.contentView layoutSubtreeIfNeeded];
                VerifyPageP1AndP2([[NSString stringWithFormat:@"P4-pane(%@)", pane] UTF8String], wc, @"settings", 900.0, 600.0);

                NSScrollView *paneScroll = nil;
                for (NSView *sub in paneHost.subviews) {
                    if ([sub isKindOfClass:[NSScrollView class]]) { paneScroll = (NSScrollView *)sub; break; }
                }
                Ck(paneScroll != nil && !paneScroll.hasHorizontalScroller,
                   [[NSString stringWithFormat:@"P4 [%@] paneScroll 存在且无横向滚动条", pane] UTF8String],
                   paneScroll ? @"hasHorizontalScroller=YES" : @"nil");
                if (paneScroll && paneScroll.contentView && paneScroll.documentView) {
                    const CGFloat clipW = paneScroll.contentView.bounds.size.width;
                    NSMutableArray<NSView *> *cards = [NSMutableArray array];
                    CollectSettingsGroups(paneScroll.documentView, cards);
                    NSMutableArray<NSString *> *badCards = [NSMutableArray array];
                    for (NSView *card in cards) {
                        if (IsHiddenInHierarchy(card, paneScroll.documentView)) continue;
                        const NSRect cr = [card convertRect:card.bounds toView:paneScroll.contentView];
                        if (NSMinX(cr) < -1.0 || NSMaxX(cr) > clipW + 1.0) {
                            [badCards addObject:[NSString stringWithFormat:@"[%.1f..%.1f]", NSMinX(cr), NSMaxX(cr)]];
                        }
                    }
                    Ck(badCards.count == 0,
                       [[NSString stringWithFormat:@"P4 [%@] 设置卡片 maxX <= clip (%.1f)", pane, clipW] UTF8String],
                       [badCards componentsJoinedByString:@", "]);
                }
            }
        }

        // ---- P5: 页面切换 3 轮（albums -> queue -> station -> albums）+ 缩窗缓存重入 ----
        for (int round = 1; round <= 3; ++round) {
            for (NSString *k in @[ @"albums", @"queue", @"station", @"albums" ]) {
                [wc.sidebar selectKey:k];
                Pump(0.2);
                [wc.window.contentView layoutSubtreeIfNeeded];
                NSString *tag = [NSString stringWithFormat:@"P5-r%d", round];
                VerifyPageP1AndP2(tag.UTF8String, wc, k, 900.0, 600.0);
                if ([k isEqualToString:@"albums"]) {
                    VerifyAlbumsP3(tag.UTF8String, wc);
                }
            }
        }

        // 缓存重入宽度变化：900 切走 -> 放大 1180 进 albums (954->5列) -> 切走 -> 缩回 900 重入 albums (674->3列)
        [wc.sidebar selectKey:@"station"];
        Pump(0.2);
        ResizeWindow(wc, 1180.0, 760.0);
        VerifyPageP1AndP2("P5-station1180", wc, @"station", 1180.0, 760.0);
        VerifyStationControls("P5-station1180", wc);
        [wc.sidebar selectKey:@"albums"];
        Pump(0.2);
        [wc.window.contentView layoutSubtreeIfNeeded];
        VerifyPageP1AndP2("P5-wide1180", wc, @"albums", 1180.0, 760.0);
        VerifyAlbumsP3("P5-wide1180", wc);

        [wc.sidebar selectKey:@"station"];
        Pump(0.2);
        ResizeWindow(wc, 900.0, 600.0);
        [wc.sidebar selectKey:@"albums"];
        Pump(0.2);
        [wc.window.contentView layoutSubtreeIfNeeded];
        VerifyPageP1AndP2("P5-reenter900", wc, @"albums", 900.0, 600.0);
        VerifyAlbumsP3("P5-reenter900", wc);

        // ---- P6: 900x600 / 1180x760 × light / dark 悬浮播放条半透明磨砂与专辑滚过区契约 ----
        for (NSDictionary *cfg in @[
            @{ @"name": @"P6-light@900",  @"w": @900,  @"h": @600, @"theme": @"light" },
            @{ @"name": @"P6-dark@900",   @"w": @900,  @"h": @600, @"theme": @"dark" },
            @{ @"name": @"P6-light@1180", @"w": @1180, @"h": @760, @"theme": @"light" },
            @{ @"name": @"P6-dark@1180",  @"w": @1180, @"h": @760, @"theme": @"dark" },
        ]) {
            [RLPTheme setThemeName:cfg[@"theme"]];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
            ResizeWindow(wc, [cfg[@"w"] doubleValue], [cfg[@"h"] doubleValue]);
            NSView *mainHost = [wc valueForKey:@"mainHost"];
            NSView *pageHost = [wc valueForKey:@"pageHost"];
            RLPPlaybackBarView *bar = wc.playbackBar;
            NSVisualEffectView *glass = (NSVisualEffectView *)FindStationViewById(bar, @"pb.glass");
            const NSRect pageInMain = [pageHost convertRect:pageHost.bounds toView:mainHost];
            const NSRect barInMain = [bar convertRect:bar.bounds toView:mainHost];
            const CGFloat bgAlpha = bar.layer.backgroundColor ? CGColorGetAlpha(bar.layer.backgroundColor) : 0.0;
            const BOOL themeLight = [RLPTheme current].isLight;
            RLPAlbumsViewController *albumsVC = [wc.currentContent isKindOfClass:[RLPAlbumsViewController class]]
                ? (RLPAlbumsViewController *)wc.currentContent : nil;
            NSCollectionView *col = albumsVC ? (NSCollectionView *)[albumsVC valueForKey:@"collection"] : nil;
            NSScrollView *colScroll = col ? col.enclosingScrollView : nil;

            const BOOL barOk =
                [glass isKindOfClass:[NSVisualEffectView class]] &&
                bar.subviews.firstObject == glass &&
                glass.material != NSVisualEffectMaterialHUDWindow &&
                (glass.material == NSVisualEffectMaterialUnderWindowBackground ||
                 glass.material == NSVisualEffectMaterialSidebar) &&
                std::fabs(NSMinY(barInMain) - 14.0) <= 1.0 &&
                std::fabs(NSHeight(barInMain) - 66.0) <= 1.0 &&
                std::fabs(NSMidX(barInMain) - NSMidX(mainHost.bounds)) <= 1.5 &&
                NSMaxX(barInMain) <= NSMaxX(mainHost.bounds) + 0.5 &&
                (themeLight ? (bgAlpha <= 0.35 + 1e-3 && bgAlpha < 0.6) : (bgAlpha < 0.6)) &&
                std::fabs(NSMinY(pageInMain) - NSMinY(mainHost.bounds)) <= 1.0 &&
                colScroll != nil && colScroll.contentInsets.bottom >= 93.0;

            std::printf("  [%s] page=%s bar=%s mat=%ld alpha=%.2f albumBottomInset=%.1f\n",
                        [cfg[@"name"] UTF8String],
                        NSStringFromRect(pageInMain).UTF8String,
                        NSStringFromRect(barInMain).UTF8String,
                        [glass isKindOfClass:[NSVisualEffectView class]] ? (long)glass.material : -1L,
                        bgAlpha,
                        colScroll ? colScroll.contentInsets.bottom : -1.0);

            Ck(barOk,
               [[NSString stringWithFormat:@"%s 半透明玻璃播放条 + pageHost 延底 + 专辑滚动底部留白",
                 [cfg[@"name"] UTF8String]] UTF8String],
               [NSString stringWithFormat:@"page=%@ bar=%@ mat=%ld alpha=%.2f inset=%.1f",
                NSStringFromRect(pageInMain), NSStringFromRect(barInMain),
                [glass isKindOfClass:[NSVisualEffectView class]] ? (long)glass.material : -1L,
                bgAlpha, colScroll ? colScroll.contentInsets.bottom : -1.0]);
        }
        [RLPTheme setThemeName:@"light"];
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
        Pump(0.1);

        // ---- P7 (v2.0.2): Works 窄窗自适应 + Chips 换行 + 主题更新 / Folders Plain 表格列宽 / 反馈窗主题响应 ----
        {
            // 1) RLPFoldersViewController 在 900 与 1180 下的 Plain 样式及列宽适配
            ResizeWindow(wc, 900.0, 600.0);
            [wc.sidebar selectKey:@"folders"];
            Pump(0.15);
            [wc.window.contentView layoutSubtreeIfNeeded];
            RLPFoldersViewController *fvc = [wc.currentContent isKindOfClass:[RLPFoldersViewController class]]
                ? (RLPFoldersViewController *)wc.currentContent : nil;
            NSTableView *ftv = fvc ? [fvc valueForKey:@"table"] : nil;
            NSScrollView *fsv = fvc ? [fvc valueForKey:@"scrollView"] : nil;
            BOOL fPlainOk = YES;
            if (@available(macOS 11.0, *)) {
                fPlainOk = (ftv != nil && ftv.style == NSTableViewStylePlain);
            }
            const CGFloat fClip900 = fsv ? NSWidth(fsv.contentView.bounds) : 0.0;
            CGFloat fSum900 = 0.0;
            for (NSTableColumn *c in ftv.tableColumns) fSum900 += c.width;
            Ck(fPlainOk && fClip900 > 0.0 && fSum900 + ftv.intercellSpacing.width <= fClip900 + 1.0,
               "P7-Folders 900x600 Plain 样式且列宽总和不超出视口（告别 640pt 硬编码溢宽）",
               [NSString stringWithFormat:@"plain=%d sum=%.1f clip=%.1f", fPlainOk, fSum900, fClip900]);

            ResizeWindow(wc, 1180.0, 760.0);
            const CGFloat fClip1180 = fsv ? NSWidth(fsv.contentView.bounds) : 0.0;
            CGFloat fSum1180 = 0.0;
            for (NSTableColumn *c in ftv.tableColumns) fSum1180 += c.width;
            Ck(fClip1180 > fClip900 + 100.0 && std::fabs((double)fSum1180 + ftv.intercellSpacing.width - fClip1180) <= 2.0,
               "P7-Folders 1180x760 扩容后 name 列随之铺满视口",
               [NSString stringWithFormat:@"sum=%.1f clip=%.1f", fSum1180, fClip1180]);
            ResizeWindow(wc, 900.0, 600.0);
        }

        {
            // 2) RLPWorksViewController 窄窗 454pt 下输入框缩放 + 示例按钮自动换行 + 主题更新
            NSWindow *worksWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 454, 640)
                                                             styleMask:NSWindowStyleMaskBorderless
                                                               backing:NSBackingStoreBuffered defer:NO];
            worksWin.releasedWhenClosed = NO;
            worksWin.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 454, 640)];
            RLPWorksViewController *wvc = [[RLPWorksViewController alloc] init];
            wvc.view.frame = NSMakeRect(0, 0, 454, 640);
            [worksWin.contentView addSubview:wvc.view];
            [wvc.view layoutSubtreeIfNeeded];
            Pump(0.1);
            [wvc.view layoutSubtreeIfNeeded];

            NSView *searchCard = [wvc valueForKey:@"searchCard"];
            NSTextField *titleField = [wvc valueForKey:@"titleField"];
            NSTextField *compField = [wvc valueForKey:@"composerField"];
            NSView *chipsContainer = [wvc valueForKey:@"chipsContainer"];
            NSArray<NSButton *> *samples = [wvc valueForKey:@"sampleButtons"];

            const NSRect titleInCard = [titleField convertRect:titleField.bounds toView:searchCard];
            const NSRect compInCard = [compField convertRect:compField.bounds toView:searchCard];
            const BOOL fieldsFit = searchCard && titleField && compField &&
                                   NSMaxX(titleInCard) <= NSWidth(searchCard.bounds) - 10.0 &&
                                   NSMaxX(compInCard) <= NSWidth(searchCard.bounds) - 10.0;
            Ck(fieldsFit,
               "P7-Works 454pt 窄窗下标题与作曲家输入框缩放并落在 searchCard 内",
               [NSString stringWithFormat:@"cardW=%.1f title=%@ comp=%@",
                NSWidth(searchCard.bounds), NSStringFromRect(titleInCard), NSStringFromRect(compInCard)]);

            BOOL chipsWrapOk = (chipsContainer != nil && NSHeight(chipsContainer.bounds) > 30.0 && samples.count == 5);
            for (NSButton *b in samples) {
                if (NSMinX(b.frame) < -0.5 || NSMaxX(b.frame) > NSWidth(chipsContainer.bounds) + 1.0 ||
                    NSMinY(b.frame) < -0.5 || NSMaxY(b.frame) > NSHeight(chipsContainer.bounds) + 1.0) {
                    chipsWrapOk = NO;
                }
            }
            Ck(chipsWrapOk,
               "P7-Works 454pt 窄窗下 5 个示例作品按钮自动换行且无一裁切溢出",
               chipsContainer ? NSStringFromRect(chipsContainer.bounds) : @"nil");

            [RLPTheme setThemeName:@"dark"];
            [(id)wvc applyTheme];
            Pump(0.05);
            const BOOL cardDarkOk = StationColorsClose(searchCard.layer.backgroundColor, [RLPTheme current].bg3.CGColor) &&
                                    [titleField.textColor isEqual:[RLPTheme current].text];
            [RLPTheme setThemeName:@"light"];
            [(id)wvc applyTheme];
            Pump(0.05);
            const BOOL cardLightOk = StationColorsClose(searchCard.layer.backgroundColor, [RLPTheme current].bg3.CGColor) &&
                                     [titleField.textColor isEqual:[RLPTheme current].text];
            Ck(cardDarkOk && cardLightOk,
               "P7-Works dark <-> light 切换实时刷新 searchCard 背景色与输入框文字色",
               [NSString stringWithFormat:@"dark=%d light=%d", cardDarkOk, cardLightOk]);
            [wvc.view removeFromSuperview];
        }

        {
            // 3) RLPFeedbackWindowController 离屏响应 RLPThemeDidChangeNotification
            [RLPTheme setThemeName:@"light"];
            RLPFeedbackWindowController *fb = [[RLPFeedbackWindowController alloc] init];
            NSTextView *fbBody = [fb valueForKey:@"body"];
            NSTextField *fbHint = [fb valueForKey:@"hintLabel"];
            const BOOL initLight = fb.window.appearance.name == NSAppearanceNameAqua &&
                                   [fb.window.backgroundColor isEqual:[RLPTheme current].bg] &&
                                   [fbBody.backgroundColor isEqual:[RLPTheme current].bg2];

            [RLPTheme setThemeName:@"dark"];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
            Pump(0.05);
            const BOOL syncedDark = fb.window.appearance.name == NSAppearanceNameDarkAqua &&
                                    [fb.window.backgroundColor isEqual:[RLPTheme current].bg] &&
                                    [fbBody.backgroundColor isEqual:[RLPTheme current].bg2] &&
                                    [fbBody.textColor isEqual:[RLPTheme current].text] &&
                                    [fbHint.textColor isEqual:[RLPTheme current].mut];

            [RLPTheme setThemeName:@"light"];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPThemeDidChangeNotification object:nil];
            Pump(0.05);
            const BOOL syncedBackLight = fb.window.appearance.name == NSAppearanceNameAqua &&
                                         [fb.window.backgroundColor isEqual:[RLPTheme current].bg] &&
                                         [fbBody.backgroundColor isEqual:[RLPTheme current].bg2];
            [fb.window.contentView layoutSubtreeIfNeeded];
            NSScrollView *fbScroll = [fb valueForKey:@"bodyScroll"];
            const BOOL bodySizedOk = (!fbBody.richText &&
                                      fbBody.textContainer.widthTracksTextView &&
                                      fbScroll != nil &&
                                      NSWidth(fbBody.frame) >= 480.0);
            Ck(initLight && syncedDark && syncedBackLight && bodySizedOk,
               "P7-FeedbackWindow 响应主题切换同步 appearance / 背景 / 输入框纯文本与宽度自适应",
               [NSString stringWithFormat:@"init=%d dark=%d back=%d rich=%d track=%d bodyW=%.1f",
                initLight, syncedDark, syncedBackLight, fbBody.richText,
                fbBody.textContainer.widthTracksTextView, NSWidth(fbBody.frame)]);
            [fb.window orderOut:nil];
        }

        {
            // P8: RLPCastView / RLPInputView / RLPLibStatsView 语言、主题、轮询生命周期与 900x600 多行不溢出契约
            RLPSetLanguage(@"zh");
            [RLPTheme setThemeName:@"light"];
            g_spy.castStateOverride = @{
                @"ok": @YES, @"running": @YES, @"device": @"TestRenderer",
                @"pos": @(42.0), @"transport": @"PLAYING", @"bytes": @(1048576),
                @"reqs": @(3), @"port": @(8912), @"sourceRate": @(44100), @"servedRate": @(192000),
                @"warn": @"A very long cast warning explanation string that must wrap inside the 900x600 settings card without pushing the row wider than its container.",
                @"error": @"A very long cast error diagnostic message that wraps cleanly inside sp_cast_stat_err_box.",
            };
            g_spy.inputStateOverride = @{
                @"ok": @YES, @"running": @YES, @"frames": @(48000), @"rate": @(96000),
                @"channels": @(2), @"water": @(0.5), @"overflow": @(2), @"underflow": @(1),
                @"posClips": @(4), @"rmsDb": @(-18.5), @"peakDb": @(-3.0),
                @"outFile": @"/Users/august/Library/Application Support/RLPlayer/recordings/session-2026-11-24-very-long-output-filename-for-layout-check.wav",
                @"error": @"Input device buffer error: detailed diagnostic message that should expand statErrBox height without clipping or horizontal overflow.",
            };
            g_spy.libStatsOverride = @{
                @"ok": @YES, @"tracks": @(321), @"albums": @(45), @"scanThreads": @(4),
                @"lastScanMs": @(2300.0), @"scanning": @YES, @"scanned": @(120), @"total": @(321),
            };
            [wc.sidebar selectKey:@"settings"];
            [wc.window.contentView layoutSubtreeIfNeeded];
            Pump(0.12);
            RLPSettingsViewController *svc = (RLPSettingsViewController *)wc.currentContent;

            // 1) Stream tab (RLPCastView)
            [svc selectPane:@"stream"];
            Pump(0.15);
            [wc.window.contentView layoutSubtreeIfNeeded];
            RLPCastView *castView = [svc valueForKey:@"castView"];
            const BOOL castPollingWhenAttached = castView && castView.polling;
            NSButton *scanBtn = [castView valueForKey:@"scanBtn"];
            NSTextField *forceLabel = [castView valueForKey:@"forceLabel"];
            NSTextField *upInfo = [castView valueForKey:@"upInfo"];
            NSTextField *statPhase = [castView valueForKey:@"statPhase"];
            NSTextField *statWarn = [castView valueForKey:@"statWarn"];
            NSTextField *statErr = [castView valueForKey:@"statErr"];
            NSView *warnBox = [castView valueForKey:@"warnBox"];
            NSView *errBox = [castView valueForKey:@"errBox"];
            NSArray<NSDictionary *> *castLabels = [castView valueForKey:@"statLabelEntries"];
            NSSwitch *upSwitch = [castView valueForKey:@"upSwitch"];
            upSwitch.state = NSControlStateValueOn;
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [castView performSelector:NSSelectorFromString(@"onCastUpsample:") withObject:upSwitch];
            #pragma clang diagnostic pop
            Pump(0.12);
            [wc.window.contentView layoutSubtreeIfNeeded];
            const BOOL castUpInfoSynced = [upInfo.stringValue containsString:@"auto"] &&
                                          [g_spy.settingsKv[@"cast_upsample"] isEqualToString:@"1"];
            RLPSetLanguage(@"en");
            [castView applyLanguage];
            [wc.window.contentView layoutSubtreeIfNeeded];
            NSTextField *firstCastLbl = castLabels.firstObject[@"label"];
            const BOOL castEnOk = [scanBtn.title isEqualToString:RLPTr(@"重新发现")] &&
                                  [forceLabel.stringValue isEqualToString:RLPTr(@"强制目标率（忽略渲染器声明）")] &&
                                  [firstCastLbl.stringValue isEqualToString:RLPTr(@"运行阶段")] &&
                                  [statPhase.stringValue isEqualToString:RLPTr(@"投放中")] &&
                                  [upInfo.stringValue isEqualToString:[NSString stringWithFormat:
                                      RLPTr(@"已按投放设置独立升频：目标率取上限与设备声明的最低者（上限 %@ Hz）"), @"auto"]];
            [RLPTheme setThemeName:@"dark"];
            [castView applyTheme];
            const BOOL castDarkOk = [forceLabel.textColor isEqual:[RLPTheme current].text] &&
                                    [firstCastLbl.textColor isEqual:[RLPTheme current].mut] &&
                                    [statWarn.textColor isEqual:[RLPTheme current].warn] &&
                                    [statErr.textColor isEqual:[RLPTheme current].danger];
            [RLPTheme setThemeName:@"light"];
            [castView applyTheme];
            NSView *castGroup = [castView superview];
            while (castGroup && ![castGroup isKindOfClass:[RLPSettingsGroup class]]) castGroup = castGroup.superview;
            const NSRect warnAlign = [statWarn convertRect:[statWarn alignmentRectForFrame:statWarn.bounds] toView:castView];
            const NSRect errAlign = [statErr convertRect:[statErr alignmentRectForFrame:statErr.bounds] toView:castView];
            const BOOL castNoOverflow = (castView != nil && castGroup != nil &&
                                         !warnBox.hidden && !errBox.hidden &&
                                         NSMaxX([castView convertRect:castView.bounds toView:castGroup]) <= NSWidth(castGroup.bounds) + 1.0 &&
                                         NSMaxX(warnAlign) <= NSWidth(castView.bounds) + 1.0 &&
                                         NSMaxX(errAlign) <= NSWidth(castView.bounds) + 1.0);
            Ck(castPollingWhenAttached && castUpInfoSynced && castEnOk && castDarkOk && castNoOverflow,
               "P8-CastView 900x600 下多行告警/错误不溢宽、投放升频联动、i18n 与主题全字段同步",
               [NSString stringWithFormat:@"poll=%d up=%d en=%d dark=%d fit=%d castW=%.1f warn=%@ err=%@ warnAlign=%.1f",
                castPollingWhenAttached, castUpInfoSynced, castEnOk, castDarkOk, castNoOverflow,
                NSWidth(castView.bounds), NSStringFromRect([statWarn convertRect:statWarn.bounds toView:castView]), NSStringFromRect([statErr convertRect:statErr.bounds toView:castView]), statWarn.alignmentRectInsets.right]);
            RLPSetLanguage(@"zh");
            // 2) Input tab (RLPInputView embedded)
            [svc selectPane:@"in"];
            Pump(0.15);
            [wc.window.contentView layoutSubtreeIfNeeded];
            const BOOL castStoppedOnTabSwitch = !castView.polling;
            RLPInputView *inputView = [svc valueForKey:@"inputView"];
            NSTextField *inHeader = [inputView valueForKey:@"statHeader"];
            NSTextField *inLbHint = [inputView valueForKey:@"lbHint"];
            NSTextField *inSpec = [inputView valueForKey:@"statSpec"];
            NSTextField *inXrun = [inputView valueForKey:@"statXrun"];
            NSTextField *inClips = [inputView valueForKey:@"statClips"];
            NSTextField *inOut = [inputView valueForKey:@"statOut"];
            NSTextField *inErr = [inputView valueForKey:@"statErr"];
            NSView *inErrBox = [inputView valueForKey:@"statErrBox"];
            NSArray<NSDictionary *> *inLabels = [inputView valueForKey:@"rowLabelEntries"];
            NSTimer *inTimerBeforeTheme = [inputView valueForKey:@"pollTimer"];
            RLPSetLanguage(@"en");
            [inputView applyLanguage];
            [wc.window.contentView layoutSubtreeIfNeeded];
            NSTextField *firstInLbl = inLabels.firstObject[@"label"];
            const BOOL inEnOk = (inputView.statusOnly ? (inHeader == nil) : [inHeader.stringValue isEqualToString:RLPTr(@"采集实时状态")]) &&
                                [inLbHint.stringValue isEqualToString:RLPTr(@"选择带「回环」标记的端点可采集系统混音（需 macOS 14.2+ 与录音权限）；输出处于独占模式时无法抓取系统混音。")] &&
                                [firstInLbl.stringValue isEqualToString:inLabels.firstObject[@"key"] ? RLPTr(inLabels.firstObject[@"key"]) : @""] &&
                                [inSpec.stringValue containsString:RLPTr(@"声道")];
            [RLPTheme setThemeName:@"dark"];
            [inputView applyTheme];
            const BOOL inDarkOk = [inLbHint.textColor isEqual:[RLPTheme current].mut] &&
                                  [inOut.textColor isEqual:[RLPTheme current].mut] &&
                                  [inErr.textColor isEqual:[RLPTheme current].danger] &&
                                  [inXrun.textColor isEqual:[RLPTheme current].danger] &&
                                  [inClips.textColor isEqual:[RLPTheme current].danger];
            [RLPTheme setThemeName:@"light"];
            [inputView applyTheme];
            const NSRect errBoxInView = [inErrBox convertRect:inErrBox.bounds toView:inputView];
            const NSRect outAlign = [inOut convertRect:[inOut alignmentRectForFrame:inOut.bounds] toView:inputView];
            const BOOL inFitOk = (inputView != nil && inErrBox && !inErrBox.hidden &&
                                  NSMaxX(outAlign) <= NSWidth(inputView.bounds) + 1.0 &&
                                  NSMaxX(errBoxInView) <= NSWidth(inputView.bounds) + 1.0 &&
                                  NSMaxY(errBoxInView) <= NSHeight(inputView.bounds) + 1.0);
            Ck(castStoppedOnTabSwitch && inTimerBeforeTheme != nil && inEnOk && inDarkOk && inFitOk,
               "P8-InputView 切走流媒体即停轮询 + 900x600 嵌入高度扩展/长路径不溢宽 + i18n/主题同步",
               [NSString stringWithFormat:@"castStop=%d inTimer=%d en=%d dark=%d fit=%d view=%.1fx%.1f out=%@ err=%@ spec=%@",
                castStoppedOnTabSwitch, (inTimerBeforeTheme != nil), inEnOk, inDarkOk, inFitOk,
                NSWidth(inputView.bounds), NSHeight(inputView.bounds), NSStringFromRect([inOut convertRect:inOut.bounds toView:inputView]), NSStringFromRect(errBoxInView), inSpec.stringValue]);
            RLPSetLanguage(@"zh");

            // 3) Advanced tab (RLPLibStatsView) + Settings applyTheme/applyLanguage timer cleanup
            [svc selectPane:@"adv"];
            Pump(0.15);
            [wc.window.contentView layoutSubtreeIfNeeded];
            const BOOL inStoppedOnTabSwitch = ([inputView valueForKey:@"pollTimer"] == nil);
            RLPLibStatsView *libStats = [svc valueForKey:@"libStatsView"];
            NSTimer *libTimerBeforeSwitch = [libStats valueForKey:@"timer"];
            RLPSetLanguage(@"en");
            [libStats applyLanguage];
            NSStackView *libGrid = [libStats valueForKey:@"grid"];
            NSMutableString *gridTextEn = [NSMutableString string];
            for (NSView *row in libGrid.arrangedSubviews) {
                for (NSView *sub in row.subviews) {
                    if ([sub isKindOfClass:[NSTextField class]]) {
                        [gridTextEn appendString:((NSTextField *)sub).stringValue ?: @""];
                        [gridTextEn appendString:@"|"];
                    }
                }
            }
            const BOOL libEnOk = [gridTextEn containsString:RLPTr(@"曲目")] &&
                                 [gridTextEn containsString:RLPTr(@"进度")] &&
                                 [gridTextEn containsString:@"321"];
            [(id)svc applyLanguage];
            Pump(0.05);
            const BOOL libTimerClearedOnLang = ([libStats valueForKey:@"timer"] == nil);
            RLPSetLanguage(@"zh");
            [(id)svc applyLanguage];
            [RLPTheme setThemeName:@"dark"];
            [(id)svc applyTheme];
            [RLPTheme setThemeName:@"light"];
            [(id)svc applyTheme];
            Pump(0.05);
            Ck(inStoppedOnTabSwitch && libTimerBeforeSwitch != nil && libEnOk && libTimerClearedOnLang,
               "P8-LibStatsView 中英互切 + 切页/刷新语言自动停旧轮询定时器",
               [NSString stringWithFormat:@"inStop=%d libTimer=%d en=%d cleared=%d",
                inStoppedOnTabSwitch, (libTimerBeforeSwitch != nil), libEnOk, libTimerClearedOnLang]);
            g_spy.castStateOverride = nil;
            g_spy.inputStateOverride = nil;
            g_spy.libStatsOverride = nil;
            [RLPTheme setThemeName:@"light"];
            RLPSetLanguage(@"zh");
        }

        {
            NSMutableArray *bands = [NSMutableArray array];
            const double freqs[20] = {20,31.5,40,50,63,80,100,125,160,200,250,315,400,500,630,800,1000,2000,4000,8000};
            for (int i = 0; i < 20; ++i) [bands addObject:@{ @"f": @(freqs[i]), @"g": @0.0, @"q": @1.41, @"type": @"PK", @"on": @YES }];
            g_spy.peqOverride = @{ @"ok": @YES, @"bypass": @NO, @"preamp": @0.0, @"fs": @48000, @"bands": bands, @"points": @[ @[ @20, @0 ], @[ @20000, @0 ] ] };
            g_spy.providersOverride = @{ @"ok": @YES, @"defaultOrder": @"qq,netease", @"items": @[
                @{ @"id": @"qq", @"name": @"QQ Music", @"on": @YES, @"canSearch": @YES, @"canLyric": @YES },
                @{ @"id": @"netease", @"name": @"NetEase", @"on": @YES, @"canSearch": @NO, @"canLyric": @YES } ] };
            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            RLPWorkbenchViewController *wb = [[RLPWorkbenchViewController alloc] init];
            wb.view.frame = NSMakeRect(0, 0, 900, 720);
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [wb performSelector:NSSelectorFromString(@"selectStudioTab:") withObject:@"eq"];
            Pump(0.15);
            RLPEqualizerView *eq = [wb valueForKey:@"eqView"];
            [eq reload];
            NSTextField *opraQ = [eq valueForKey:@"opraQuery"];
            opraQ.stringValue = @"HD 650";
            [eq performSelector:NSSelectorFromString(@"onOpraSearch:") withObject:nil];
            Pump(0.15);
            NSArray<NSView *> *modelCards0 = [eq valueForKey:@"opraModelCardViews"];
            if (modelCards0.count > 0) { [modelCards0.firstObject performSelector:NSSelectorFromString(@"click")]; Pump(0.15); }
            NSArray<NSView *> *modelCards = [eq valueForKey:@"opraModelCardViews"];
            #pragma clang diagnostic pop
            RLPEQFaderView *fader = [eq valueForKey:@"fader"];
            RLPEQFaderInspector *insp = [eq valueForKey:@"inspector"];
            if (fader.onBandGainEdited) fader.onBandGainEdited(0, 1.5);
            [wb.view layoutSubtreeIfNeeded];
            NSTextField *bypassLbl = [eq valueForKey:@"bypassLabel"], *preampLbl = [eq valueForKey:@"preampLabel"], *preampDbLbl = [eq valueForKey:@"preampDbLabel"];
            NSTextField *presetSecLbl = [eq valueForKey:@"presetSectionLabel"], *opraTitleLbl = [eq valueForKey:@"opraTitleLabel"], *opraDescLbl = [eq valueForKey:@"opraDescLabel"];
            NSTextField *opraGuideLbl = [eq valueForKey:@"opraGuide"], *opraSelTitle = [eq valueForKey:@"opraSelectedTitle"];
            NSTextField *inspFreq = [insp valueForKey:@"_freqLabel"], *inspQ = [insp valueForKey:@"_qLabel"], *inspType = [insp valueForKey:@"_typeLabel"];
            NSArray<NSView *> *presetCards = [eq valueForKey:@"opraPresetCardViews"];
            NSTextField *band0Field = [fader valueFieldForBand:0];
            [RLPTheme setThemeName:@"dark"]; [(id)wb applyTheme];
            RLPTheme *dark = [RLPTheme current];
            NSTextField *presetTitle = nil;
            for (NSView *sv in presetCards.firstObject.subviews) if ([sv.identifier isEqualToString:@"opra.preset.title"]) { presetTitle = (NSTextField *)sv; break; }
            const BOOL eqDarkOk = [bypassLbl.textColor isEqual:dark.text] && [preampLbl.textColor isEqual:dark.text] && [preampDbLbl.textColor isEqual:dark.mut] &&
                [presetSecLbl.textColor isEqual:dark.text] && [opraTitleLbl.textColor isEqual:dark.text] && [opraDescLbl.textColor isEqual:dark.mut] &&
                [opraGuideLbl.textColor isEqual:dark.mut] && [opraSelTitle.textColor isEqual:dark.text] && [band0Field.textColor isEqual:dark.text] &&
                [inspFreq.textColor isEqual:dark.text] && [inspQ.textColor isEqual:dark.mut] && [inspType.textColor isEqual:dark.mut] &&
                presetCards.count > 0 && [presetTitle.textColor isEqual:dark.text] && modelCards.count > 0 && CGColorEqualToColor(modelCards.firstObject.layer.borderColor, dark.accent.CGColor);
            [RLPTheme setThemeName:@"light"]; [(id)wb applyTheme];
            RLPTheme *light = [RLPTheme current];
            const BOOL eqLightOk = [bypassLbl.textColor isEqual:light.text] && [preampDbLbl.textColor isEqual:light.mut] &&
                [band0Field.textColor isEqual:light.text] && [inspQ.textColor isEqual:light.mut];
            RLPSetLanguage(@"en"); [wb applyLanguage];
            const BOOL eqEnOk = [bypassLbl.stringValue isEqualToString:RLPTr(@"旁路（不改声音）")] &&
                [band0Field.toolTip isEqualToString:RLPTr(@"直接输入该段的增益，范围 ±24 dB")] && [inspType.stringValue isEqualToString:RLPTr(@"类型")];
            Ck(eqDarkOk && eqLightOk && eqEnOk, "P9-Equalizer 工作台切深/浅主题与中英切换全组件同步（Fader/Inspector/OPRA 卡片）",
               [NSString stringWithFormat:@"dark=%d light=%d en=%d cards=%lu/%lu", eqDarkOk, eqLightOk, eqEnOk, (unsigned long)modelCards.count, (unsigned long)presetCards.count]);
            RLPSetLanguage(@"zh");
            RLPMetaSourcesView *msv = [[RLPMetaSourcesView alloc] initWithFrame:NSMakeRect(0, 0, 520, 200)];
            [msv reload]; Pump(0.1);
            [RLPTheme setThemeName:@"dark"]; [msv applyTheme];
            NSTextField *msTitle = [msv valueForKey:@"titleLabel"], *msMsg = [msv valueForKey:@"msg"]; NSButton *msReset = [msv valueForKey:@"resetBtn"];
            const BOOL msDarkOk = [msTitle.textColor isEqual:[RLPTheme current].text] && [msMsg.textColor isEqual:[RLPTheme current].mut];
            RLPSetLanguage(@"en"); [msv applyLanguage];
            const BOOL msEnOk = [msTitle.stringValue isEqualToString:RLPTr(@"数据源优先级")] && [msReset.title isEqualToString:RLPTr(@"恢复默认")] &&
                [msMsg.stringValue isEqualToString:RLPTr(@"越靠上优先级越高")];
            RLPVolumeSliderView *vs = [[RLPVolumeSliderView alloc] initWithFrame:NSMakeRect(0, 0, 220, 28)];
            vs.db = -120.0; [vs applyTheme]; [vs applyLanguage];
            const BOOL vsOk = [vs.valueLabel.textColor isEqual:[RLPTheme current].mut] && [vs.muteButton.toolTip isEqualToString:RLPTr(@"静音 / 取消静音")] &&
                [vs.valueLabel.stringValue isEqualToString:RLPTr(@"静音")];
            Ck(msDarkOk && msEnOk && vsOk, "P9-MetaSources/VolumeSlider 主题色与中英切换即时同步",
               [NSString stringWithFormat:@"msDark=%d msEn=%d vs=%d", msDarkOk, msEnOk, vsOk]);
            g_spy.peqOverride = nil; g_spy.providersOverride = nil;
            [wb viewDidDisappear];
            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
        }
        {
            // P10：KnowledgeView(work)、RightDrawer(歌词提示/暂停高亮)、ServersView、CalibrationView、TracksViewController(空搜索主题)
            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            g_spy.entityVersionsOverride = @{
                @"ok": @YES, @"source": @"discogs", @"cached": @NO, @"fetched_at": @"2026-11-24",
                @"performances": @[ @{ @"year": @"1959", @"title": @"Goldberg Variations", @"artists": @[@"Glenn Gould"], @"labels": @[@"Columbia"], @"formats": @[@"LP"] } ],
                @"performanceCount": @1, @"total": @1
            };
            RLPKnowledgeView *kv = [[RLPKnowledgeView alloc] initWithFrame:NSMakeRect(0, 0, 420, 420)];
            [kv loadWorkName:@"BWV 988" composer:@"Bach"];
            Pump(0.1);
            [RLPTheme setThemeName:@"dark"]; [kv applyTheme];
            RLPTheme *dark = [RLPTheme current];
            NSTextField *kvStatus = [kv valueForKey:@"status"], *kvWorkSub = [kv valueForKey:@"workHintSub"];
            NSStackView *kvStack = [kv valueForKey:@"fieldStack"];
            NSTextField *wkTitle = nil;
            for (NSView *row in kvStack.arrangedSubviews) {
                for (NSView *sv in row.subviews) {
                    if ([sv.identifier isEqualToString:@"npWorkTitle"]) { wkTitle = (NSTextField *)sv; break; }
                }
            }
            NSColor *expTitle = dark.text2 ?: dark.text;
            const BOOL kvDarkOk = wkTitle && [wkTitle.textColor isEqual:expTitle] && [kvStatus.textColor isEqual:dark.mut] && [kvWorkSub.textColor isEqual:dark.mut2];
            RLPSetLanguage(@"en"); [kv applyLanguage];
            const BOOL kvEnOk = [kvStatus.stringValue hasPrefix:RLPTr(@"Discogs 实时")] && [[kv valueForKey:@"refreshBtn"] title].length > 0 &&
                [[[kv valueForKey:@"refreshBtn"] title] isEqualToString:RLPTr(@"重新查询")];
            Ck(kvDarkOk && kvEnOk, "P10-KnowledgeView(work) 主题色与中英切换更新",
               [NSString stringWithFormat:@"dark=%d en=%d status=%@", kvDarkOk, kvEnOk, kvStatus.stringValue]);

            RLPSetLanguage(@"zh"); [RLPTheme setThemeName:@"light"];
            g_spy.queueOverride = @{ @"ok": @YES, @"items": @[ @"/Music/A/A.flac" ], @"cues": @[ @"" ], @"index": @0, @"mode": @0 };
            g_spy.lyricsOverride = @{ @"ok": @YES, @"timed": @YES, @"lrc": @"[00:01.00]Line 1\n[00:10.00]Line 2\n" };
            RLPRightDrawer *drw = [[RLPRightDrawer alloc] initWithFrame:NSMakeRect(0, 0, 320, 480)];
            [drw showTab:@"l"]; [drw activate]; Pump(0.1);
            [drw updatePosition:12.0 duration:120.0];
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [drw performSelector:NSSelectorFromString(@"lyricCopyAll:") withObject:nil];
            #pragma clang diagnostic pop
            NSTextField *lHint = [drw valueForKey:@"lHint"];
            [RLPTheme setThemeName:@"dark"]; [drw applyTheme];
            const BOOL drwKeepOk = [lHint.stringValue containsString:@"复制"];
            RLPSetLanguage(@"en"); [drw applyLanguage];
            const BOOL drwEnOk = [lHint.stringValue isEqualToString:RLPTr(@"歌词已复制")] && [[drw valueForKey:@"activeLine"] integerValue] == 1;
            [drw deactivate];
            Ck(drwKeepOk && drwEnOk, "P10-RightDrawer 歌词复制提示保留、英文化及暂停高亮",
               [NSString stringWithFormat:@"keep=%d en=%d hint=%@", drwKeepOk, drwEnOk, lHint.stringValue]);

            RLPSetLanguage(@"zh"); [RLPTheme setThemeName:@"light"];
            g_spy.serversOverride = @{ @"ok": @YES, @"servers": @[] };
            RLPServersView *srv = [[RLPServersView alloc] initWithFrame:NSMakeRect(0, 0, 560, 260)];
            [srv reload]; Pump(0.1);
            [srv setValue:@1 forKey:@"formMsgState"];
            [RLPTheme setThemeName:@"dark"]; [srv applyTheme];
            NSTextField *srvMsg = [srv valueForKey:@"formMsg"];
            const BOOL srvColorOk = [srvMsg.textColor isEqual:[RLPTheme current].ok];
            RLPSetLanguage(@"en"); [srv applyLanguage];
            NSButton *srvAdd = [srv valueForKey:@"addBtn"];
            const BOOL srvEnOk = [srvAdd.title isEqualToString:RLPTr(@"添加服务器")];
            Ck(srvColorOk && srvEnOk, "P10-ServersView 状态颜色与语言即时更新",
               [NSString stringWithFormat:@"color=%d en=%d title=%@", srvColorOk, srvEnOk, srvAdd.title]);

            RLPCalibrationView *cal = [[RLPCalibrationView alloc] initWithFrame:NSMakeRect(0, 0, 560, 480)];
            [cal reload]; Pump(0.1);
            [cal applyTheme]; [cal applyLanguage];
            NSButton *calPlanBtn = [cal valueForKey:@"planBtn"];
            NSTextField *calNote = [cal valueForKey:@"micCalNote"];
            const BOOL calEnOk = [calPlanBtn.title isEqualToString:RLPTr(@"生成计划并确认")] && [calNote.stringValue isEqualToString:RLPTr(@"未导入")];
            Ck(calEnOk, "P10-CalibrationView 语言即时切换更新", calPlanBtn.title);

            RLPSetLanguage(@"zh");
            RLPTracksViewController *tvc = [[RLPTracksViewController alloc] init];
            tvc.view.frame = NSMakeRect(0, 0, 680, 480);
            [tvc searchWithQuery:@"__no_match__"]; Pump(0.1);
            [RLPTheme setThemeName:@"dark"]; [tvc applyTheme];
            NSTextField *seTitle = [tvc valueForKey:@"_searchEmptyTitle"], *seHint = [tvc valueForKey:@"_searchEmptyHint"];
            const BOOL tvcOk = [seTitle.textColor isEqual:[RLPTheme current].text] && [seHint.textColor isEqual:[RLPTheme current].mut2];
            Ck(tvcOk, "P10-TracksViewController 空搜索主题切换更新", seTitle.stringValue);

            g_spy.entityVersionsOverride = nil; g_spy.lyricsOverride = nil; g_spy.queueOverride = nil; g_spy.serversOverride = nil;
            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
        }
        {
            // P11：Albums 空态卡主题/按钮中英、Folders 空态主题、ArtistDetail bioToggle、AlbumDetail/Queue 未加载守卫
            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            RLPAlbumsViewController *albUnloaded = [[RLPAlbumsViewController alloc] init];
            [albUnloaded applyTheme];
            RLPAlbumDetailViewController *adUnloaded = [[RLPAlbumDetailViewController alloc] initWithAlbumKey:@"k1"];
            [adUnloaded applyTheme]; [(id)adUnloaded applyLanguage];
            RLPQueueViewController *qUnloaded = [[RLPQueueViewController alloc] init];
            [qUnloaded applyTheme];
            const BOOL unloadedOk = !albUnloaded.isViewLoaded && !adUnloaded.isViewLoaded && !qUnloaded.isViewLoaded;
            Ck(unloadedOk, "P11-未加载视图调用 applyTheme/applyLanguage 不提前触发 loadView",
               [NSString stringWithFormat:@"alb=%d ad=%d q=%d", albUnloaded.isViewLoaded, adUnloaded.isViewLoaded, qUnloaded.isViewLoaded]);

            g_spy.albumsOverride = @{ @"ok": @YES, @"albums": @[] };
            RLPAlbumsViewController *av = [[RLPAlbumsViewController alloc] init];
            av.view.frame = NSMakeRect(0, 0, 680, 520);
            [av reload]; Pump(0.1);
            [RLPTheme setThemeName:@"dark"]; [av applyTheme];
            RLPTheme *dark = [RLPTheme current];
            NSView *ec = [av valueForKey:@"emptyCard"];
            NSTextField *et = [av valueForKey:@"emptyTitleLabel"], *eh = [av valueForKey:@"emptyHintLabel"];
            NSButton *eb1 = [av valueForKey:@"emptyAddBtn"], *eb2 = [av valueForKey:@"emptyScanBtn"];
            const BOOL albDarkOk = ec && !ec.hidden && CGColorEqualToColor(ec.layer.backgroundColor, dark.bg2.CGColor) &&
                CGColorEqualToColor(ec.layer.borderColor, dark.line.CGColor) &&
                [et.textColor isEqual:dark.text] && [eh.textColor isEqual:dark.mut2];
            RLPSetLanguage(@"en"); [av applyLanguage];
            const BOOL albEnOk = [eb1.title isEqualToString:RLPTr(@"管理音乐目录")] && [eb2.title isEqualToString:RLPTr(@"重新扫描")];
            Ck(albDarkOk && albEnOk, "P11-AlbumsViewController 空态卡深浅主题与三按钮英文化同步",
               [NSString stringWithFormat:@"dark=%d en=%d b1=%@ b2=%@", albDarkOk, albEnOk, eb1.title, eb2.title]);
            g_spy.albumsOverride = nil;

            RLPFoldersViewController *fv = [[RLPFoldersViewController alloc] init];
            fv.view.frame = NSMakeRect(0, 0, 680, 480);
            [RLPTheme setThemeName:@"dark"]; [fv applyTheme];
            NSTextField *fe = [fv valueForKey:@"emptyLabel"];
            Ck([fe.textColor isEqual:dark.mut2], "P11-FoldersViewController emptyLabel 主题色同步", @"");

            RLPSetLanguage(@"zh"); [RLPTheme setThemeName:@"light"];
            RLPArtistDetailViewController *art = [[RLPArtistDetailViewController alloc] initWithArtistName:@"Bach"];
            art.view.frame = NSMakeRect(0, 0, 760, 620);
            [art setValue:@YES forKey:@"bioExpanded"];
            RLPSetLanguage(@"en"); [art applyLanguage];
            NSButton *bioBtn = [art valueForKey:@"bioToggle"];
            Ck([bioBtn.title isEqualToString:RLPTr(@"收起简介")], "P11-ArtistDetailViewController bioToggle 切英文即时更新", bioBtn.title);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
        }
        {
            // P12：Sidebar 品牌区主题色+滚动保持、Playlists/Works 未加载守卫、UpdateWindow 动态状态中英切换与主题
            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            RLPSidebarViewController *sbUnloaded = [[RLPSidebarViewController alloc] init];
            [sbUnloaded applyTheme]; [sbUnloaded applyLanguage];
            RLPPlaylistsViewController *plUnloaded = [[RLPPlaylistsViewController alloc] init];
            [plUnloaded applyTheme]; [plUnloaded applyLanguage];
            RLPWorksViewController *wkUnloaded = [[RLPWorksViewController alloc] init];
            [wkUnloaded applyTheme];
            const BOOL p12Unloaded = !sbUnloaded.isViewLoaded && !plUnloaded.isViewLoaded && !wkUnloaded.isViewLoaded;
            Ck(p12Unloaded, "P12-Sidebar/Playlists/Works 未加载时不提前触发 loadView",
               [NSString stringWithFormat:@"sb=%d pl=%d wk=%d", sbUnloaded.isViewLoaded, plUnloaded.isViewLoaded, wkUnloaded.isViewLoaded]);

            RLPSidebarViewController *sb = [[RLPSidebarViewController alloc] init];
            sb.view.frame = NSMakeRect(0, 0, 232, 700);
            [RLPTheme setThemeName:@"dark"]; [sb applyTheme];
            RLPTheme *dark = [RLPTheme current];
            NSView *bh = [sb valueForKey:@"_brandHair"];
            NSImageView *bl = [sb valueForKey:@"_brandLogo"];
            NSTextField *bt = [sb valueForKey:@"_brandTitle"], *bv = [sb valueForKey:@"_brandVer"], *bs = [sb valueForKey:@"_brandSub"];
            const BOOL sbDarkOk = CGColorEqualToColor(bh.layer.backgroundColor, dark.line.CGColor) &&
                [bl.contentTintColor isEqual:dark.accent] && [bt.textColor isEqual:dark.text] &&
                [bv.textColor isEqual:dark.mut] && CGColorEqualToColor(bv.layer.backgroundColor, dark.hov.CGColor) &&
                [bs.textColor isEqual:dark.mut];
            Ck(sbDarkOk, "P12-Sidebar 底部品牌区深浅主题切换同步", @"");

            RLPUpdateWindowController *uwc = [[RLPUpdateWindowController alloc] init];
            [(id)uwc applyTheme];
            NSTextView *notesV = [uwc valueForKey:@"notesView"];
            NSTextField *titleF = [uwc valueForKey:@"titleField"];
            const BOOL uwcThemeOk = CGColorEqualToColor(uwc.window.contentView.layer.backgroundColor, dark.bg.CGColor) &&
                [notesV.insertionPointColor isEqual:dark.accent];
            [uwc setValue:@(5) forKey:@"displayState"]; // RLPUpdateDisplayAvailable
            [uwc setValue:@"9.9.9" forKey:@"remoteVersion"];
            [uwc setValue:@YES forKey:@"hasPlan"];
            titleF.stringValue = [NSString stringWithFormat:RLPTr(@"发现新版本 %@"), @"9.9.9"];
            RLPSetLanguage(@"en"); [(id)uwc applyLanguage];
            const BOOL uwcAvailEn = [titleF.stringValue isEqualToString:[NSString stringWithFormat:RLPTr(@"发现新版本 %@"), @"9.9.9"]];
            [uwc setValue:@(6) forKey:@"displayState"]; // RLPUpdateDisplayInstalled
            [uwc setValue:@YES forKey:@"installed"];
            [uwc setValue:@YES forKey:@"installedNotesUsesFallback"];
            RLPSetLanguage(@"zh"); [(id)uwc applyLanguage];
            const BOOL uwcInstZh = [titleF.stringValue isEqualToString:RLPTr(@"更新已安装")] &&
                [notesV.string isEqualToString:RLPTr(@"更新已安装")];
            [uwc close];
            Ck(uwcThemeOk && uwcAvailEn && uwcInstZh, "P12-UpdateWindow 动态状态语言切换与主题光标色同步",
               [NSString stringWithFormat:@"thm=%d availEn=%d instZh=%d title=%@", uwcThemeOk, uwcAvailEn, uwcInstZh, titleF.stringValue]);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
        }
        {
            // P13：v2.0.10 契约 — 未加载 VC 守卫、Recent/Favorites 失败态语言切换、
            //      rowStack/worksPage 主题穿透、Works statusMessageZh + 响应式宽度、NPControlBar 主题/tooltip
            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            RLPPageViewController *pgU = [[RLPPageViewController alloc] initWithTitle:@"T"];
            [pgU applyTheme];
            RLPNowPlayingViewController *npU = [[RLPNowPlayingViewController alloc] init];
            [npU applyTheme]; [(id)npU applyLanguage];
            RLPQuickStartViewController *qsU = [[RLPQuickStartViewController alloc] init];
            [qsU applyTheme]; [qsU applyLanguage];
            RLPSettingsViewController *stU = [[RLPSettingsViewController alloc] init];
            [stU applyTheme]; [(id)stU applyLanguage];
            RLPTracksViewController *trU = [[RLPTracksViewController alloc] init];
            [trU applyTheme];
            RLPWorkbenchViewController *wbU = [[RLPWorkbenchViewController alloc] init];
            [wbU applyTheme];
            const BOOL p13Unloaded = !pgU.isViewLoaded && !npU.isViewLoaded && !qsU.isViewLoaded &&
                                     !stU.isViewLoaded && !trU.isViewLoaded && !wbU.isViewLoaded;
            Ck(p13Unloaded, "P13-Page/NP/QuickStart/Settings/Tracks/Workbench 未加载时不提前触发 loadView",
               [NSString stringWithFormat:@"pg=%d np=%d qs=%d st=%d tr=%d wb=%d",
                   pgU.isViewLoaded, npU.isViewLoaded, qsU.isViewLoaded,
                   stU.isViewLoaded, trU.isViewLoaded, wbU.isViewLoaded]);

            g_spy.recentOverride = @{ @"ok": @NO };
            RLPRecentViewController *rec = [[RLPRecentViewController alloc] init];
            rec.view.frame = NSMakeRect(0, 0, 760, 520);
            [rec reloadData];
            Pump(0.08);
            NSTextField *recEmpty = [rec valueForKey:@"_emptyLabel"];
            const BOOL recFailZh = [[rec valueForKey:@"lastLoadFailed"] boolValue] &&
                [recEmpty.stringValue isEqualToString:RLPTr(@"加载失败")];
            RLPSetLanguage(@"en"); [rec applyLanguage];
            const BOOL recFailEn = [[rec valueForKey:@"lastLoadFailed"] boolValue] &&
                [recEmpty.stringValue isEqualToString:RLPTr(@"加载失败")] &&
                ![recEmpty.stringValue isEqualToString:RLPTr(@"还没有播放记录")];
            g_spy.recentOverride = nil;
            Ck(recFailZh && recFailEn, "P13-Recent 加载失败态中英切换保留加载失败文案而不被空列表覆盖",
               [NSString stringWithFormat:@"zh=%d en=%d text=%@", recFailZh, recFailEn, recEmpty.stringValue]);

            RLPSetLanguage(@"zh");
            g_spy.favoritesOverride = @{ @"ok": @NO };
            RLPFavoritesViewController *fav = [[RLPFavoritesViewController alloc] init];
            fav.view.frame = NSMakeRect(0, 0, 760, 520);
            [fav reloadData];
            Pump(0.08);
            NSTextField *favEmpty = [fav valueForKey:@"_emptyLabel"];
            const BOOL favFailZh = [[fav valueForKey:@"lastLoadFailed"] boolValue] &&
                [favEmpty.stringValue isEqualToString:RLPTr(@"加载失败")];
            RLPSetLanguage(@"en"); [fav applyLanguage];
            const BOOL favFailEn = [[fav valueForKey:@"lastLoadFailed"] boolValue] &&
                [favEmpty.stringValue isEqualToString:RLPTr(@"加载失败")];
            g_spy.favoritesOverride = nil;
            Ck(favFailZh && favFailEn, "P13-Favorites 加载失败态中英切换保留加载失败文案",
               [NSString stringWithFormat:@"zh=%d en=%d text=%@", favFailZh, favFailEn, favEmpty.stringValue]);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            RLPPageViewController *stackedPage = [[RLPPageViewController alloc] initWithTitle:@"Stacked"];
            (void)stackedPage.view;
            RLPWorksViewController *wkStacked = [[RLPWorksViewController alloc] init];
            wkStacked.view.frame = NSMakeRect(0, 0, 760, 520);
            NSMutableArray *rowStack = [wc valueForKey:@"rowStack"];
            id prevWorks = [wc valueForKey:@"worksPage"];
            NSDictionary *dummyEntry = @{ @"key": @"albums", @"vc": stackedPage, @"root": @NO };
            [rowStack addObject:dummyEntry];
            [wc setValue:wkStacked forKey:@"worksPage"];
            [RLPTheme setThemeName:@"dark"];
            Pump(0.05);
            RLPTheme *darkTheme = [RLPTheme current];
            const BOOL rowStackThemed = CGColorEqualToColor(stackedPage.view.layer.backgroundColor, darkTheme.bg.CGColor);
            const BOOL worksThemed = CGColorEqualToColor(wkStacked.view.layer.backgroundColor, darkTheme.bg.CGColor);
            [rowStack removeObject:dummyEntry];
            [wc setValue:prevWorks forKey:@"worksPage"];
            Ck(rowStackThemed && worksThemed, "P13-MainWindow onThemeChanged 同步 rowStack 返回栈与 worksPage 主题色",
               [NSString stringWithFormat:@"row=%d works=%d", rowStackThemed, worksThemed]);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            RLPWorksViewController *wks = [[RLPWorksViewController alloc] init];
            wks.view.frame = NSMakeRect(0, 0, 480, 500);
            [wks loadWork:@"BWV 1001" composer:@"Bach" fromNowPlaying:NO];
            NSStackView *wksResultStack = [wks valueForKey:@"resultStack"];
            NSTextField *wksMsg = [wksResultStack.arrangedSubviews.firstObject isKindOfClass:[NSTextField class]]
                ? (NSTextField *)wksResultStack.arrangedSubviews.firstObject : nil;
            const BOOL wksKeyOk = [[wks valueForKey:@"statusMessageZh"] isEqualToString:@"正在从 Discogs 检索版本…"];
            RLPSetLanguage(@"en"); [wks applyLanguage];
            wksMsg = [wksResultStack.arrangedSubviews.firstObject isKindOfClass:[NSTextField class]]
                ? (NSTextField *)wksResultStack.arrangedSubviews.firstObject : nil;
            const BOOL wksEnOk = [wksMsg.stringValue isEqualToString:RLPTr(@"正在从 Discogs 检索版本…")];
            BOOL hasFixed560 = NO;
            for (NSLayoutConstraint *c in wksMsg.constraints) {
                if (c.firstItem == wksMsg && c.firstAttribute == NSLayoutAttributeWidth &&
                    c.relation == NSLayoutRelationEqual && std::fabs(c.constant - 560.0) < 0.5) {
                    hasFixed560 = YES;
                }
            }
            Pump(0.05);
            Ck(wksKeyOk && wksEnOk && !hasFixed560, "P13-Works 状态文案中英切换重译且不写死 560pt 宽度",
               [NSString stringWithFormat:@"key=%d en=%d fixed560=%d msg=%@", wksKeyOk, wksEnOk, hasFixed560, wksMsg.stringValue]);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            RLPNowPlayingViewController *npBarHost = [[RLPNowPlayingViewController alloc] init];
            npBarHost.view.frame = NSMakeRect(0, 0, 760, 620);
            id ctrlBar = [npBarHost valueForKey:@"webControls"];
            [RLPTheme setThemeName:@"dark"]; [npBarHost applyTheme];
            NSButton *playBtn = [ctrlBar valueForKey:@"playBtn"];
            NSButton *prevBtn = [ctrlBar valueForKey:@"prevBtn"];
            NSButton *nextBtn = [ctrlBar valueForKey:@"nextBtn"];
            NSButton *stopBtn = [ctrlBar valueForKey:@"stopBtn"];
            RLPTheme *npDark = [RLPTheme current];
            const BOOL npThemeOk = [playBtn.contentTintColor isEqual:NSColor.whiteColor] &&
                CGColorEqualToColor(playBtn.layer.backgroundColor, npDark.accent.CGColor) &&
                [prevBtn.contentTintColor isEqual:npDark.text];
            RLPSetLanguage(@"en"); [(id)npBarHost applyLanguage];
            const BOOL npTipOk = [playBtn.toolTip isEqualToString:RLPTr(@"播放 / 暂停")] &&
                [prevBtn.toolTip isEqualToString:RLPTr(@"上一首")] &&
                [nextBtn.toolTip isEqualToString:RLPTr(@"下一首")] &&
                [stopBtn.toolTip isEqualToString:RLPTr(@"停止")];
            Ck(npThemeOk && npTipOk, "P13-NPControlBar 主题切换保留播放主色与白字，切语言同步按钮 tooltip",
               [NSString stringWithFormat:@"thm=%d tip=%d playTip=%@", npThemeOk, npTipOk, playBtn.toolTip]);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
        }
        {
            // P14：v2.0.11 契约 — NowPlaying 双行歌词占位保持与主题色同步、Tracks/Folders/Albums/Queue
            //      失败态切语言不被空态覆盖、Streaming browseId 弱引用与失败文案切语言重译
            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            RLPNowPlayingViewController *np = [[RLPNowPlayingViewController alloc] init];
            np.view.frame = NSMakeRect(0, 0, 760, 620);
            typedef void (*SetPhIMP)(id, SEL, NSString *, NSString *);
            SEL phSel = NSSelectorFromString(@"setLyricsPlaceholder:detail:");
            ((SetPhIMP)[np methodForSelector:phSel])(np, phSel, @"歌词加载中…", @"正在等后台补全…");
            NSTextField *lyrEmpty = [np valueForKey:@"lyricsEmpty"];
            RLPSetLanguage(@"en"); [(id)np applyLanguage];
            const BOOL lyrKeepTwoLineEn = [lyrEmpty.stringValue containsString:RLPTr(@"歌词加载中…")] &&
                                          [lyrEmpty.stringValue containsString:RLPTr(@"正在等后台补全…")];
            [RLPTheme setThemeName:@"dark"]; [np applyTheme];
            NSAttributedString *lyrAttr = lyrEmpty.attributedStringValue;
            NSColor *mainDarkCol = lyrAttr.length ? [lyrAttr attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] : nil;
            const BOOL lyrThemeOk = [mainDarkCol isEqual:[RLPTheme current].mut];
            Ck(lyrKeepTwoLineEn && lyrThemeOk, "P14-NowPlaying lyricsEmpty 切语言保留两行加载态且切主题重染主色",
               [NSString stringWithFormat:@"en=%d thm=%d str=%@", lyrKeepTwoLineEn, lyrThemeOk, lyrEmpty.stringValue]);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            g_spy.searchOverride = @{ @"ok": @NO };
            RLPTracksViewController *tr = [[RLPTracksViewController alloc] init];
            tr.view.frame = NSMakeRect(0, 0, 760, 520);
            [tr reloadData];
            Pump(0.08);
            NSTextField *trEmpty = [tr valueForKey:@"_emptyLabel"];
            const BOOL trFailZh = [tr.subtitleLabel.stringValue isEqualToString:RLPTr(@"读取失败")] &&
                                  [trEmpty.stringValue isEqualToString:RLPTr(@"读取失败")];
            RLPSetLanguage(@"en"); [(id)tr applyLanguage];
            const BOOL trFailEn = [tr.subtitleLabel.stringValue isEqualToString:RLPTr(@"读取失败")] &&
                                  [trEmpty.stringValue isEqualToString:RLPTr(@"读取失败")] &&
                                  ![trEmpty.stringValue isEqualToString:RLPTr(@"没有匹配的曲目")];
            g_spy.searchOverride = nil;
            NSSearchField *trSearch = [tr valueForKey:@"_searchField"];
            trSearch.stringValue = @"Bach";
            [tr reloadData];
            Pump(0.08);
            RLPSetLanguage(@"zh"); [(id)tr applyLanguage];
            const BOOL trSearchTitleZh = [tr.pageTitle isEqualToString:[NSString stringWithFormat:RLPTr(@"搜索：%@"), @"Bach"]];
            Ck(trFailZh && trFailEn && trSearchTitleZh, "P14-Tracks 失败态中英切换不覆盖读取失败，搜索页保留搜索标题",
               [NSString stringWithFormat:@"zh=%d en=%d title=%d (%@)", trFailZh, trFailEn, trSearchTitleZh, tr.pageTitle]);

            RLPSetLanguage(@"zh");
            g_spy.filesOverride = @{ @"ok": @NO };
            RLPFoldersViewController *fld = [[RLPFoldersViewController alloc] init];
            fld.view.frame = NSMakeRect(0, 0, 760, 520);
            [fld reloadData];
            Pump(0.08);
            NSTextField *fldEmpty = [fld valueForKey:@"emptyLabel"];
            const BOOL fldFailZh = [[fld valueForKey:@"lastLoadFailed"] boolValue] &&
                                   [fld.subtitleLabel.stringValue isEqualToString:RLPTr(@"读取失败")] &&
                                   [fldEmpty.stringValue isEqualToString:RLPTr(@"目录读取失败")];
            RLPSetLanguage(@"en"); [(id)fld applyLanguage];
            const BOOL fldFailEn = [[fld valueForKey:@"lastLoadFailed"] boolValue] &&
                                   [fld.subtitleLabel.stringValue isEqualToString:RLPTr(@"读取失败")] &&
                                   [fldEmpty.stringValue isEqualToString:RLPTr(@"目录读取失败")];
            g_spy.filesOverride = nil;
            Ck(fldFailZh && fldFailEn, "P14-Folders 目录读取失败态切语言保留读取失败与目录错误提示",
               [NSString stringWithFormat:@"zh=%d en=%d sub=%@ emp=%@", fldFailZh, fldFailEn, fld.subtitleLabel.stringValue, fldEmpty.stringValue]);

            RLPSetLanguage(@"zh");
            g_spy.albumsOverride = @{ @"ok": @NO };
            RLPAlbumsViewController *alb = [[RLPAlbumsViewController alloc] init];
            alb.view.frame = NSMakeRect(0, 0, 760, 520);
            [(id)alb reload];
            Pump(0.08);
            NSTextField *albCnt = [alb valueForKey:@"countLabel"];
            const BOOL albFailZh = [[alb valueForKey:@"lastLoadFailed"] boolValue] &&
                                   [albCnt.stringValue isEqualToString:RLPTr(@"加载失败")];
            RLPSetLanguage(@"en"); [(id)alb applyLanguage];
            const BOOL albFailEn = [[alb valueForKey:@"lastLoadFailed"] boolValue] &&
                                   [albCnt.stringValue isEqualToString:RLPTr(@"加载失败")];
            g_spy.albumsOverride = nil;
            Ck(albFailZh && albFailEn, "P14-Albums 加载失败态切语言保留加载失败",
               [NSString stringWithFormat:@"zh=%d en=%d cnt=%@", albFailZh, albFailEn, albCnt.stringValue]);

            RLPSetLanguage(@"zh");
            g_spy.queueOverride = @{ @"ok": @NO };
            RLPQueueViewController *q = [[RLPQueueViewController alloc] init];
            q.view.frame = NSMakeRect(0, 0, 760, 520);
            [q reloadData];
            Pump(0.08);
            const BOOL qFailZh = [[q valueForKey:@"lastLoadFailed"] boolValue] &&
                                 [q.subtitleLabel.stringValue isEqualToString:RLPTr(@"读取失败")];
            RLPSetLanguage(@"en"); [(id)q applyLanguage];
            const BOOL qFailEn = [[q valueForKey:@"lastLoadFailed"] boolValue] &&
                                 [q.subtitleLabel.stringValue isEqualToString:RLPTr(@"读取失败")];
            g_spy.queueOverride = nil;
            Ck(qFailZh && qFailEn, "P14-Queue 读取失败态切语言保留读取失败",
               [NSString stringWithFormat:@"zh=%d en=%d sub=%@", qFailZh, qFailEn, q.subtitleLabel.stringValue]);

            RLPSetLanguage(@"zh");
            g_spy.serversOverride = @{ @"ok": @NO };
            RLPStreamingViewController *st = [[RLPStreamingViewController alloc] init];
            st.view.frame = NSMakeRect(0, 0, 760, 520);
            [st reloadData];
            Pump(0.08);
            NSTextField *stHint = [st valueForKey:@"_emptyHint"];
            RLPSetLanguage(@"en"); [(id)st applyLanguage];
            const BOOL stFailEn = [st.subtitleLabel.stringValue isEqualToString:RLPTr(@"浏览失败")] &&
                                  [stHint.stringValue containsString:RLPTr(@"浏览失败")];
            g_spy.serversOverride = nil;

            __weak id weakSt = nil;
            @autoreleasepool {
                RLPStreamingViewController *tmpSt = [[RLPStreamingViewController alloc] init];
                tmpSt.view.frame = NSMakeRect(0, 0, 640, 480);
                weakSt = tmpSt;
                [tmpSt performSelector:@selector(browseId:) withObject:@"r1"];
            }
            const BOOL stDeallocatedBeforeCallback = (weakSt == nil);
            Pump(0.08);
            Ck(stFailEn && stDeallocatedBeforeCallback, "P14-Streaming browseId 弱引用不滞留宿主且失败态切语言同步重译",
               [NSString stringWithFormat:@"failEn=%d weakNil=%d sub=%@", stFailEn, stDeallocatedBeforeCallback, st.subtitleLabel.stringValue]);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");

            // P15: ArtistDetail / Artists 失败态与搜索零匹配 + AlbumDetail kindLabel 主题 + MainWin Tracks 搜索标题 + RightDrawer 歌词重译不重复请求
            g_spy.albumsOverride = @{ @"ok": @NO };
            RLPArtistDetailViewController *artD = [[RLPArtistDetailViewController alloc] initWithArtistName:@"Bach"];
            artD.view.frame = NSMakeRect(0, 0, 760, 520);
            [artD reloadData];
            Pump(0.08);
            NSTextField *artDEmpty = [artD valueForKey:@"emptyLabel"];
            const BOOL artDFailZh = [[artD valueForKey:@"lastLoadFailed"] boolValue] &&
                                    ![[artD valueForKey:@"loaded"] boolValue] &&
                                    [artD.subtitleLabel.stringValue isEqualToString:RLPTr(@"读取失败")];
            RLPSetLanguage(@"en"); [(id)artD applyLanguage];
            const BOOL artDFailEn = [[artD valueForKey:@"lastLoadFailed"] boolValue] &&
                                    [artD.subtitleLabel.stringValue isEqualToString:RLPTr(@"读取失败")] &&
                                    [artDEmpty.stringValue isEqualToString:RLPTr(@"读取失败")];
            g_spy.albumsOverride = nil;
            Ck(artDFailZh && artDFailEn, "P15-ArtistDetail 读取失败态中英切换保留读取失败不误标 0 张专辑",
               [NSString stringWithFormat:@"zh=%d en=%d sub=%@ emp=%@", artDFailZh, artDFailEn, artD.subtitleLabel.stringValue, artDEmpty.stringValue]);

            RLPSetLanguage(@"zh");
            g_spy.albumsOverride = @{ @"ok": @NO };
            RLPArtistsViewController *arts = [[RLPArtistsViewController alloc] init];
            arts.view.frame = NSMakeRect(0, 0, 760, 520);
            [arts reloadData];
            Pump(0.08);
            NSTextField *artsCnt = [arts valueForKey:@"countLabel"];
            const BOOL artsFailZh = [[arts valueForKey:@"lastLoadFailed"] boolValue] &&
                                    [artsCnt.stringValue isEqualToString:RLPTr(@"读取失败")];
            RLPSetLanguage(@"en"); [(id)arts applyLanguage];
            const BOOL artsFailEn = [[arts valueForKey:@"lastLoadFailed"] boolValue] &&
                                    [artsCnt.stringValue isEqualToString:RLPTr(@"读取失败")];
            g_spy.albumsOverride = nil;
            [arts reloadData];
            Pump(0.08);
            [(id)arts searchWithQuery:@"__NoSuchArtistXYZ__"];
            const BOOL artsSearchZeroEn = [artsCnt.stringValue isEqualToString:[NSString stringWithFormat:RLPTr(@"%ld 位艺术家"), 0L]];
            Ck(artsFailZh && artsFailEn && artsSearchZeroEn, "P15-Artists 失败态切语言保留读取失败，有曲库搜索零匹配显示 0 位艺术家",
               [NSString stringWithFormat:@"zh=%d en=%d zero=%d cnt=%@", artsFailZh, artsFailEn, artsSearchZeroEn, artsCnt.stringValue]);

            RLPSetLanguage(@"zh"); [RLPTheme setThemeName:@"light"];
            RLPAlbumDetailViewController *ad = [[RLPAlbumDetailViewController alloc] initWithAlbumKey:@"a000"];
            ad.view.frame = NSMakeRect(0, 0, 760, 520);
            [ad reloadData];
            Pump(0.08);
            [RLPTheme setThemeName:@"dark"]; [(id)ad applyTheme];
            NSTextField *adKind = [ad valueForKey:@"kindLabel"];
            NSColor *adKindFg = adKind.attributedStringValue.length
                ? [adKind.attributedStringValue attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]
                : nil;
            const BOOL adKindDarkOk = (adKindFg != nil && [adKindFg isEqual:[RLPTheme current].mut2]);
            Ck(adKindDarkOk, "P15-AlbumDetail kindLabel 切暗色主题重染 mut2 主色",
               [NSString stringWithFormat:@"fg=%@ expect=%@", adKindFg, [RLPTheme current].mut2]);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
            [wc.sidebar selectKey:@"tracks"];
            Pump(0.08);
            RLPTracksViewController *mwTracks = [wc.currentContent isKindOfClass:[RLPTracksViewController class]]
                ? (RLPTracksViewController *)wc.currentContent : nil;
            NSSearchField *mwTrSearch = mwTracks ? [mwTracks valueForKey:@"_searchField"] : nil;
            mwTrSearch.stringValue = @"Bach";
            [mwTracks reloadData];
            Pump(0.08);
            RLPSetLanguage(@"en");
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
            Pump(0.05);
            NSTextField *mwPageTitle = [wc valueForKey:@"pageTitle"];
            const BOOL mwTracksSearchEn = [mwPageTitle.stringValue isEqualToString:[NSString stringWithFormat:RLPTr(@"搜索：%@"), @"Bach"]];
            Ck(mwTracksSearchEn, "P15-MainWindow 曲目搜索态切语言保留搜索标题",
               [NSString stringWithFormat:@"title=%@", mwPageTitle.stringValue]);

            RLPSetLanguage(@"zh");
            g_spy.queueOverride = @{ @"ok": @YES, @"items": @[ @"/Music/t.flac" ], @"index": @0 };
            RLPRightDrawer *rd = [[RLPRightDrawer alloc] initWithFrame:NSMakeRect(0, 0, 340, 560)];
            [rd showTab:@"l"];
            [rd activate];
            Pump(0.08);
            NSUInteger lyrCallsBefore = 0;
            for (NSString *u in g_spy.getCalls) if ([u hasPrefix:@"/api/lyrics"]) ++lyrCallsBefore;
            RLPSetLanguage(@"en");
            [rd applyLanguage];
            NSUInteger lyrCallsAfter = 0;
            for (NSString *u in g_spy.getCalls) if ([u hasPrefix:@"/api/lyrics"]) ++lyrCallsAfter;
            NSStackView *rdLStack = [rd valueForKey:@"lStack"];
            NSString *rdMsg = @"";
            for (NSView *sv in rdLStack.arrangedSubviews) {
                if ([sv isKindOfClass:[NSTextField class]] && [sv.identifier isEqualToString:@"right.ly.none"]) {
                    rdMsg = ((NSTextField *)sv).stringValue ?: @"";
                }
            }
            [rd deactivate];
            g_spy.queueOverride = nil;
            const BOOL rdOk = (lyrCallsBefore >= 1 && lyrCallsAfter == lyrCallsBefore && [rdMsg containsString:RLPTr(@"歌词加载中…")]);
            Ck(rdOk, "P15-RightDrawer 歌词空态切语言就地重译且不重发请求",
               [NSString stringWithFormat:@"before=%lu after=%lu msg=%@", (unsigned long)lyrCallsBefore, (unsigned long)lyrCallsAfter, rdMsg]);

            // P16: Playlists 列表读取失败 / 歌单不存在态切语言保留错误语义
            RLPSetLanguage(@"zh");
            g_spy.sqListOverride = @{ @"ok": @NO };
            RLPPlaylistsViewController *pl = [[RLPPlaylistsViewController alloc] init];
            pl.view.frame = NSMakeRect(0, 0, 760, 520);
            [pl reloadData];
            Pump(0.08);
            const BOOL plListFailZh = [pl.subtitleLabel.stringValue isEqualToString:RLPTr(@"歌单读取失败")];
            RLPSetLanguage(@"en"); [(id)pl applyLanguage];
            const BOOL plListFailEn = [pl.subtitleLabel.stringValue isEqualToString:RLPTr(@"歌单读取失败")];
            g_spy.sqListOverride = nil;
            g_spy.sqInfoOverride = @{ @"ok": @NO };
            [pl performSelector:@selector(openPlaylist:) withObject:@"MyList"];
            Pump(0.08);
            const BOOL plMissingEn = [pl.subtitleLabel.stringValue isEqualToString:RLPTr(@"歌单不存在（可能已被删除）")];
            RLPSetLanguage(@"zh"); [(id)pl applyLanguage];
            const BOOL plMissingZh = [pl.subtitleLabel.stringValue isEqualToString:RLPTr(@"歌单不存在（可能已被删除）")];
            g_spy.sqInfoOverride = nil;
            Ck(plListFailZh && plListFailEn && plMissingEn && plMissingZh,
               "P16-Playlists 读取失败与歌单不存在态切语言保留对应错误副标题",
               [NSString stringWithFormat:@"listZh=%d listEn=%d missEn=%d missZh=%d sub=%@",
                plListFailZh, plListFailEn, plMissingEn, plMissingZh, pl.subtitleLabel.stringValue]);

            [RLPTheme setThemeName:@"light"]; RLPSetLanguage(@"zh");
        }
        [wc.window orderOut:nil];
        [wc stopAllActivity];
        [wc close];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAutosaveDefaultsKey];

        std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
