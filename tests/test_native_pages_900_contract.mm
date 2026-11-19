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
#import "RLPSettingsViewController.h"
#import "RLPSettingsLayout.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

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
@end

@implementation RLPPages900SpyClient
- (instancetype)init {
    self = [super init];
    if (self) _uiMode = @"listen";
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
                @"metaon": @"1",
                @"metallm": @"0",
                @"metasummary": @"0",
            }
        };
    }
    if ([path hasPrefix:@"/api/status"]) return @{ @"ok": @YES, @"playing": @NO, @"paused": @NO, @"volDb": @(-120) };
    if ([path hasPrefix:@"/api/playmode"]) return @{ @"ok": @YES, @"mode": @1 };
    if ([path hasPrefix:@"/api/writeback/status"]) return @{ @"ok": @YES, @"running": @NO };
    if ([path hasPrefix:@"/api/queue"]) return @{ @"ok": @YES, @"items": @[], @"index": @0, @"mode": @0 };
    if ([path hasPrefix:@"/api/lib/albums"]) {
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
    if ([path hasPrefix:@"/api/lib/artists"]) return @{ @"ok": @YES, @"artists": @[] };
    if ([path hasPrefix:@"/api/lib/search"]) return @{ @"ok": @YES, @"tracks": @[], @"total": @0, @"n": @0 };
    if ([path hasPrefix:@"/api/lib/stats"]) return @{ @"ok": @YES, @"roots": @[@"/Music"] };
    if ([path hasPrefix:@"/api/lib/roots"]) return @{ @"ok": @YES, @"roots": @[@"/Music"] };
    if ([path hasPrefix:@"/api/sq/list"]) return @{ @"ok": @YES, @"queues": @[] };
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/preset/caps"]) return @{ @"ok": @YES, @"known": @YES, @"pcmReady": @YES, @"dsdReady": @YES };
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    if ([path hasPrefix:@"/api/profiles"]) return @{ @"ok": @YES, @"profiles": @[] };
    if ([path hasPrefix:@"/api/peq"]) return @{ @"ok": @YES, @"enabled": @NO, @"bands": @[] };
    if ([path hasPrefix:@"/api/providers"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/llm/models"]) return @{ @"ok": @NO, @"models": @[] };
    if ([path hasPrefix:@"/api/llm"]) return @{ @"ok": @YES, @"configured": @NO };
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
    NSView *pageHost = [wc valueForKey:@"pageHost"];
    const NSSize winSz = wc.window.frame.size;

    Ck(std::fabs(winSz.width - expectedWinW) <= 1.0 && std::fabs(winSz.height - expectedWinH) <= 1.0,
       [[NSString stringWithFormat:@"%s [%@] 窗口尺寸保持 %.0fx%.0f", stage, key, expectedWinW, expectedWinH] UTF8String],
       [NSString stringWithFormat:@"win=%.1fx%.1f", winSz.width, winSz.height]);

    Ck(pageVC != nil && pageVC.view != nil && pageHost != nil,
       [[NSString stringWithFormat:@"%s [%@] pageVC 与 pageHost 存在", stage, key] UTF8String],
       @"nil");
    if (!pageVC || !pageVC.view || !pageHost) return;

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
    }
    std::printf("  [page %-12s %s] host=%.1f page=%.1f frameMaxX=%.1f scrolls=%lu maxDocOverflow=%.1f\n",
                key.UTF8String, stage, hostW, pageW, NSMaxX(pf),
                (unsigned long)scrolls.count, maxOverflow);

    if (scrolls.count > 0) {
        Ck(badScrolls.count == 0,
           [[NSString stringWithFormat:@"P2 %s [%@] NSScrollView doc.width <= clip.width +1", stage, key] UTF8String],
           [badScrolls componentsJoinedByString:@"; "]);
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
            for (NSString *pane in @[ @"eq", @"stream", @"in", @"out", @"diag" ]) {
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

        [wc.window orderOut:nil];
        [wc stopAllActivity];
        [wc close];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAutosaveDefaultsKey];

        std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
