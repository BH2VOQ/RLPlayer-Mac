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
//   R6 900x600 下顶栏控件（search / top.mode / top.queue / top.scan / top.np 及标题区）都在 topbar bounds 内且两两不交叠。
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
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
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

static void CheckSidebarTopEntries(RLPMainWindowController *wc, const char *stage,
                                   NSInteger *outListenRow, NSInteger *outProRow) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    NSScrollView *scroll = nil;
    NSTableView *tv = SidebarTableView(wc.sidebar, &scroll);
    NSView *search = (NSView *)[wc valueForKey:@"search"];
    NSView *root = wc.window.contentView;
    const CGFloat sidebarH = wc.sidebar.view.bounds.size.height;
    const CGFloat thirdH = sidebarH / 3.0;

    NSInteger listenRow = -1, proRow = -1, firstSecRow = -1;
    NSInteger stationBeforeSec = 0, stationAfterSec = 0;
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableSet<NSString *> *uniqueTitles = [NSMutableSet set];
    NSMutableArray<NSString *> *dupTitles = [NSMutableArray array];

    NSView *listenCell = nil, *proCell = nil, *firstSecCell = nil;
    NSString *listenTitle = @"", *proTitle = @"", *firstSecTitle = @"";
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
            [titles addObject:txt];
        }
        if ([key isEqualToString:@"station"]) {
            if (firstSecRow < 0) ++stationBeforeSec;
            else ++stationAfterSec;
            if ([cell.identifier isEqualToString:@"side.station.listen"] ||
                [txt isEqualToString:RLPTr(@"聆听室")]) {
                listenRow = r;
                listenCell = cell;
                listenTitle = txt;
            } else if ([cell.identifier isEqualToString:@"side.station.pro"] ||
                       [txt isEqualToString:RLPTr(@"数字音乐台")] ||
                       [txt isEqualToString:RLPTr(@"专业工作台")]) {
                proRow = r;
                proCell = cell;
                proTitle = txt;
            }
        }
    }

    if (outListenRow) *outListenRow = listenRow;
    if (outProRow) *outProRow = proRow;

    const NSRect listenRowRect = (listenRow >= 0) ? [tv rectOfRow:listenRow] : NSZeroRect;
    const NSRect proRowRect = (proRow >= 0) ? [tv rectOfRow:proRow] : NSZeroRect;
    const NSRect secRowRect = (firstSecRow >= 0) ? [tv rectOfRow:firstSecRow] : NSZeroRect;

    const NSRect listenInSidebar = (listenRow >= 0) ? [tv convertRect:listenRowRect toView:wc.sidebar.view] : NSZeroRect;
    const NSRect proInSidebar = (proRow >= 0) ? [tv convertRect:proRowRect toView:wc.sidebar.view] : NSZeroRect;
    const NSRect listenInScroll = (listenRow >= 0) ? [tv convertRect:listenRowRect toView:scroll] : NSZeroRect;
    const NSRect proInScroll = (proRow >= 0) ? [tv convertRect:proRowRect toView:scroll] : NSZeroRect;

    const NSRect listenInWin = (listenRow >= 0) ? [tv convertRect:listenRowRect toView:root] : NSZeroRect;
    const NSRect proInWin = (proRow >= 0) ? [tv convertRect:proRowRect toView:root] : NSZeroRect;
    const NSRect secInWin = (firstSecRow >= 0) ? [tv convertRect:secRowRect toView:root] : NSZeroRect;
    const NSRect searchInWin = search ? [search convertRect:search.bounds toView:root] : NSZeroRect;

    const CGFloat listenTopDist = NSMaxY(wc.sidebar.view.bounds) - NSMaxY(listenInSidebar);
    const CGFloat listenBottomDist = NSMaxY(wc.sidebar.view.bounds) - NSMinY(listenInSidebar);
    const CGFloat proTopDist = NSMaxY(wc.sidebar.view.bounds) - NSMaxY(proInSidebar);
    const CGFloat proBottomDist = NSMaxY(wc.sidebar.view.bounds) - NSMinY(proInSidebar);

    std::printf("  [sidebar %s] sidebarH=%.1f third=%.1f | listen(row=%ld title='%s' frame=%s top=%.1f..%.1f) | "
                "pro(row=%ld title='%s' frame=%s top=%.1f..%.1f) | sec0(row=%ld title='%s' frame=%s) | search=%s\n",
                stage, sidebarH, thirdH,
                (long)listenRow, listenTitle.UTF8String, NSStringFromRect(listenInSidebar).UTF8String,
                listenTopDist, listenBottomDist,
                (long)proRow, proTitle.UTF8String, NSStringFromRect(proInSidebar).UTF8String,
                proTopDist, proBottomDist,
                (long)firstSecRow, firstSecTitle.UTF8String, NSStringFromRect(secInWin).UTF8String,
                NSStringFromRect(searchInWin).UTF8String);

    const NSRect scrollTol = NSInsetRect(scroll.bounds, -0.5, -0.5);
    const BOOL inTopThird = (listenRow >= 0 && proRow >= 0 &&
                             firstSecRow >= 0 && listenRow < firstSecRow && proRow < firstSecRow &&
                             listenTopDist >= 0 && listenBottomDist <= thirdH &&
                             proTopDist >= 0 && proBottomDist <= thirdH &&
                             NSContainsRect(scrollTol, listenInScroll) &&
                             NSContainsRect(scrollTol, proInScroll));
    Ck(inTopThird,
       [[NSString stringWithFormat:@"V1-%s 侧栏顶部存在聆听室与数字音乐台入口且均在前 1/3 可视区内", stage] UTF8String],
       [NSString stringWithFormat:@"listenRow=%ld(%.1f..%.1f) proRow=%ld(%.1f..%.1f) sec0=%ld third=%.1f",
        (long)listenRow, listenTopDist, listenBottomDist,
        (long)proRow, proTopDist, proBottomDist, (long)firstSecRow, thirdH]);

    const BOOL noOverlap = (listenRow >= 0 && proRow >= 0 && firstSecRow >= 0 && search != nil &&
                            !NSIntersectsRect(NSInsetRect(listenInWin, 0.5, 0.5), NSInsetRect(proInWin, 0.5, 0.5)) &&
                            !NSIntersectsRect(NSInsetRect(listenInWin, 0.5, 0.5), NSInsetRect(secInWin, 0.5, 0.5)) &&
                            !NSIntersectsRect(NSInsetRect(proInWin, 0.5, 0.5), NSInsetRect(secInWin, 0.5, 0.5)) &&
                            !NSIntersectsRect(NSInsetRect(listenInWin, 0.5, 0.5), NSInsetRect(searchInWin, 0.5, 0.5)) &&
                            !NSIntersectsRect(NSInsetRect(proInWin, 0.5, 0.5), NSInsetRect(searchInWin, 0.5, 0.5)) &&
                            NSMaxX(listenInWin) <= NSMinX(searchInWin) &&
                            NSMaxX(proInWin) <= NSMinX(searchInWin) &&
                            NSMinY(listenInWin) > NSMinY(proInWin) &&
                            NSMinY(proInWin) > NSMaxY(secInWin));
    Ck(noOverlap,
       [[NSString stringWithFormat:@"V3-%s 两顶部入口不互相重叠、不与搜索框及首分组标题重叠且位于分组标题之上", stage] UTF8String],
       [NSString stringWithFormat:@"listen=%@ pro=%@ sec0=%@ search=%@",
        NSStringFromRect(listenInWin), NSStringFromRect(proInWin),
        NSStringFromRect(secInWin), NSStringFromRect(searchInWin)]);

    Ck(stationBeforeSec == 2 && stationAfterSec == 0 && dupTitles.count == 0,
       [[NSString stringWithFormat:@"V5-%s 无底部重复 station 入口且无重复侧栏标题", stage] UTF8String],
       [NSString stringWithFormat:@"beforeSec=%ld afterSec=%ld dups=%@",
        (long)stationBeforeSec, (long)stationAfterSec, [dupTitles componentsJoinedByString:@","]]);
    (void)listenCell; (void)proCell; (void)firstSecCell;
}

static void CheckSidebarEnglishLabels(RLPMainWindowController *wc, const char *stage,
                                      NSInteger listenRow, NSInteger proRow) {
    [wc.window.contentView layoutSubtreeIfNeeded];
    NSTableView *tv = SidebarTableView(wc.sidebar, nil);
    NSView *listenCell = (listenRow >= 0) ? [tv viewAtColumn:0 row:listenRow makeIfNecessary:YES] : nil;
    NSView *proCell = (proRow >= 0) ? [tv viewAtColumn:0 row:proRow makeIfNecessary:YES] : nil;
    if (listenCell) [listenCell layoutSubtreeIfNeeded];
    if (proCell) [proCell layoutSubtreeIfNeeded];
    NSTextField *listenLab = FirstTextFieldInCell(listenCell);
    NSTextField *proLab = FirstTextFieldInCell(proCell);
    const CGFloat listenNeedW = listenLab ? listenLab.attributedStringValue.size.width : 9999.0;
    const CGFloat proNeedW = proLab ? proLab.attributedStringValue.size.width : 9999.0;
    const BOOL ok = (listenLab && proLab &&
                     [listenLab.stringValue isEqualToString:@"Listening Room"] &&
                     [proLab.stringValue isEqualToString:@"Digital Music Console"] &&
                     listenLab.bounds.size.height <= 22.0 &&
                     proLab.bounds.size.height <= 22.0 &&
                     listenNeedW <= listenLab.bounds.size.width + 1.0 &&
                     proNeedW <= proLab.bounds.size.width + 1.0 &&
                     NSContainsRect(NSInsetRect(listenCell.bounds, -0.5, -0.5),
                                    [listenLab convertRect:listenLab.bounds toView:listenCell]) &&
                     NSContainsRect(NSInsetRect(proCell.bounds, -0.5, -0.5),
                                    [proLab convertRect:proLab.bounds toView:proCell]));
    std::printf("  [sidebar-en %s] listen='%s' needW=%.1f box=%s | pro='%s' needW=%.1f box=%s\n",
                stage,
                listenLab.stringValue.UTF8String ?: "", listenNeedW, NSStringFromRect(listenLab.frame).UTF8String,
                proLab.stringValue.UTF8String ?: "", proNeedW, NSStringFromRect(proLab.frame).UTF8String);
    Ck(ok,
       [[NSString stringWithFormat:@"V4-%s 英文模式下顶部两入口文案完整、单行不换行且不截断", stage] UTF8String],
       [NSString stringWithFormat:@"listen='%@'(%.1f/%.1f h=%.1f) pro='%@'(%.1f/%.1f h=%.1f)",
        listenLab.stringValue, listenNeedW, listenLab.bounds.size.width, listenLab.bounds.size.height,
        proLab.stringValue, proNeedW, proLab.bounds.size.width, proLab.bounds.size.height]);
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
        Pump(0.3);
        [wc.window.contentView layoutSubtreeIfNeeded];
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
        Pump(0.25);
        [wc.window.contentView layoutSubtreeIfNeeded];
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
        Pump(0.25);
        [wc.window.contentView layoutSubtreeIfNeeded];
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

        // ---- V1..V5: 侧栏顶部「聆听室 / 数字音乐台」入口、路由、布局与同步契约 ----
        {
            NSInteger listenRow = -1, proRow = -1;
            NSView *pageHost = (NSView *)[wc valueForKey:@"pageHost"];
            NSTextField *topTitle = (NSTextField *)[wc valueForKey:@"pageTitle"];

            // 900x600 空歌单与溢出 12 歌单两档下验证 V1/V3/V5
            ResizeWindow(wc, 900, 600);
            [wc.sidebar selectKey:@"albums"];
            Pump(0.15);
            CheckSidebarTopEntries(wc, "zh@900", &listenRow, &proRow);

            // 溢出 12 个歌单（把设置/音频引擎挤到滚动视口之外）时，顶部入口仍必须留在视口前 1/3
            NSMutableArray *manyQueues = [NSMutableArray array];
            for (int qi = 0; qi < 12; ++qi) {
                [manyQueues addObject:@{ @"name": [NSString stringWithFormat:@"Playlist %02d", qi], @"n": @5 }];
            }
            g_spy.savedQueuesFixture = manyQueues;
            [wc.sidebar reloadSavedQueues];
            Pump(0.15);
            CheckSidebarTopEntries(wc, "zh-overflow@900", &listenRow, &proRow);

            // V2: 通过 NSTableView 选中切到 pro -> RLPWorkbenchViewController + pageHost + top.mode 同步
            NSScrollView *sbScroll = nil;
            NSTableView *sbTable = SidebarTableView(wc.sidebar, &sbScroll);
            if (sbTable && proRow >= 0) {
                [sbTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)proRow] byExtendingSelection:NO];
            } else {
                [wc.sidebar selectRow:proRow];
            }
            Pump(0.2);
            Ck([wc.uiMode isEqualToString:@"pro"] &&
               wc.modeControl.selectedSegment == 1 &&
               wc.sidebar.selectedRow == proRow &&
               [wc.currentContent isKindOfClass:RLPWorkbenchViewController.class] &&
               [wc.currentContent.view.identifier isEqualToString:@"page.station"] &&
               wc.currentContent.view.superview == pageHost &&
               pageHost.subviews.count == 1 &&
               [topTitle.stringValue isEqualToString:RLPTr(@"数字音乐台")],
               "V2a 点击顶部专业入口进入 RLPWorkbenchViewController 并同步 modeControl/pageHost/标题",
               [NSString stringWithFormat:@"mode=%@ seg=%ld row=%ld/%ld vc=%@ hostCount=%lu title=%@",
                wc.uiMode, (long)wc.modeControl.selectedSegment, (long)wc.sidebar.selectedRow, (long)proRow,
                NSStringFromClass(wc.currentContent.class), (unsigned long)pageHost.subviews.count,
                topTitle.stringValue ?: @""]);

            // V2b: 点击顶部聆听室入口进入 RLPQuickStartViewController + pageHost + top.mode 同步
            if (sbTable && listenRow >= 0) {
                [sbTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)listenRow] byExtendingSelection:NO];
            } else {
                [wc.sidebar selectRow:listenRow];
            }
            Pump(0.2);
            Ck([wc.uiMode isEqualToString:@"listen"] &&
               wc.modeControl.selectedSegment == 0 &&
               wc.sidebar.selectedRow == listenRow &&
               [wc.currentContent isKindOfClass:RLPQuickStartViewController.class] &&
               [wc.currentContent.view.identifier isEqualToString:@"page.station"] &&
               wc.currentContent.view.superview == pageHost &&
               pageHost.subviews.count == 1 &&
               [topTitle.stringValue isEqualToString:RLPTr(@"聆听室")],
               "V2b 点击顶部聆听室入口进入 RLPQuickStartViewController 并同步 modeControl/pageHost/标题",
               [NSString stringWithFormat:@"mode=%@ seg=%ld row=%ld/%ld vc=%@ hostCount=%lu title=%@",
                wc.uiMode, (long)wc.modeControl.selectedSegment, (long)wc.sidebar.selectedRow, (long)listenRow,
                NSStringFromClass(wc.currentContent.class), (unsigned long)pageHost.subviews.count,
                topTitle.stringValue ?: @""]);

            // V5b: 顶栏 modeControl 与设置页 RLPSwitchToProWorkbenchNotification 反向同步侧栏选中行
            wc.modeControl.selectedSegment = 1;
            [wc.modeControl sendAction:wc.modeControl.action to:wc.modeControl.target];
            Pump(0.15);
            const BOOL syncFromTopPro = (wc.sidebar.selectedRow == proRow && [wc.uiMode isEqualToString:@"pro"]);
            wc.modeControl.selectedSegment = 0;
            [wc.modeControl sendAction:wc.modeControl.action to:wc.modeControl.target];
            Pump(0.15);
            const BOOL syncFromTopListen = (wc.sidebar.selectedRow == listenRow && [wc.uiMode isEqualToString:@"listen"]);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPSwitchToProWorkbenchNotification" object:nil];
            Pump(0.15);
            const BOOL syncFromSettingsNote = (wc.sidebar.selectedRow == proRow &&
                                               wc.modeControl.selectedSegment == 1 &&
                                               [wc.currentContent isKindOfClass:RLPWorkbenchViewController.class]);
            Ck(syncFromTopPro && syncFromTopListen && syncFromSettingsNote,
               "V5b 顶栏 modeControl 与设置工作台通知与侧栏顶部两入口共用同一状态且双向同步",
               [NSString stringWithFormat:@"topPro=%d topListen=%d settingsNote=%d row=%ld seg=%ld",
                (int)syncFromTopPro, (int)syncFromTopListen, (int)syncFromSettingsNote,
                (long)wc.sidebar.selectedRow, (long)wc.modeControl.selectedSegment]);

            // 切回 1180x760 并检查 V1/V3/V5 + V4 英文模式文案完整
            g_spy.savedQueuesFixture = @[];
            [wc.sidebar reloadSavedQueues];
            [wc setUiMode:@"listen" persist:NO];
            [wc.sidebar selectKey:@"albums"];
            ResizeWindow(wc, 1180, 760);
            Pump(0.2);
            CheckSidebarTopEntries(wc, "zh@1180", &listenRow, &proRow);

            RLPSetLanguage(@"en");
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
            Pump(0.15);
            CheckSidebarTopEntries(wc, "en@1180", &listenRow, &proRow);
            CheckSidebarEnglishLabels(wc, "en@1180", listenRow, proRow);

            ResizeWindow(wc, 900, 600);
            Pump(0.15);
            CheckSidebarTopEntries(wc, "en@900", &listenRow, &proRow);
            CheckSidebarEnglishLabels(wc, "en@900", listenRow, proRow);

            RLPSetLanguage(@"zh");
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
            Pump(0.1);
        }

        [wc.window orderOut:nil];
        [wc stopAllActivity];
        [wc close];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAutosaveDefaultsKey];

        std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
