// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_navigation_contract.mm — 原生导航契约（空态跳转 / 顶栏返回栈 / 嵌套详情返回）
//
// ============================ 这条判据在证明什么 ============================
// 1. 专辑空态「打开快速开始」：onEmptyStation 必须发 RLPNavigateKeyNotification("station")，
//    命中侧栏「快速开始」（page.station / RLPQuickStartViewController），而非不存在的 "sq"。
// 2. 切顶级侧栏页：从详情页（rowStack 非空）切到任意顶级侧栏页（selectKey / RLPNavigateKeyNotification /
//    RLPOpenSettingsPaneNotification / 点回原列表页）必须清空 rowStack 并隐藏顶栏返回按钮 top.back。
// 3. 嵌套详情返回：artists -> artistDetail -> albumDetail、albums -> albumA -> albumB、
//    albums -> albumA -> worksPage 逐层返回必须回到真实上层详情页（不跳层），
//    回到顶级页后返回栈归零、top.back 隐藏；重复打开 worksPage 不重复压栈；
//    正在播放覆盖页打开时 RLPRequestBack 先关覆盖页而不误弹详情栈。
//
// 纪律：不启动核心（RLPNavSpy 桩客户端）；不碰音频设备；不创建可见窗口。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPAlbumsViewController.h"
#import "RLPArtistsViewController.h"
#import "RLPTracksViewController.h"
#import "RLPQueueViewController.h"
#import "RLPQuickStartViewController.h"
#import "RLPAlbumDetailViewController.h"
#import "RLPArtistDetailViewController.h"
#import "RLPWorksViewController.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

#pragma mark - 桩客户端（替换 +[RLPCoreClient shared]）

@interface RLPNavSpy : NSObject
@property (nonatomic, assign) BOOL albumsEmpty;
@end

@implementation RLPNavSpy
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown { }
- (id)jsonWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body {
    (void)method; (void)path; (void)body;
    return nil;
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
    (void)path; (void)body;
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
    if ([path hasPrefix:@"/api/lib/albums"]) {
        if (self.albumsEmpty) return @{ @"ok": @YES, @"albums": @[] };
        return @{
            @"ok": @YES,
            @"albums": @[
                @{ @"k": @"/Music/ABBA/Arrival", @"name": @"Arrival", @"artist": @"ABBA",
                   @"year": @1976, @"n": @2, @"dur": @400, @"sr": @44100, @"bits": @16, @"cv": @NO },
                @{ @"k": @"/Music/ABBA/VoulezVous", @"name": @"Voulez-Vous", @"artist": @"ABBA",
                   @"year": @1979, @"n": @2, @"dur": @420, @"sr": @44100, @"bits": @16, @"cv": @NO },
            ]
        };
    }
    if ([path hasPrefix:@"/api/lib/album?"]) {
        NSString *k = @"";
        NSRange r = [path rangeOfString:@"k="];
        if (r.location != NSNotFound) k = [path substringFromIndex:NSMaxRange(r)];
        k = [k stringByRemovingPercentEncoding] ?: k;
        return @{
            @"ok": @YES,
            @"album": @{
                @"k": k,
                @"name": [k containsString:@"VoulezVous"] ? @"Voulez-Vous" : @"Arrival",
                @"artist": @"ABBA",
                @"year": @1976,
                @"tracks": @[
                    @{ @"path": [k stringByAppendingString:@"/01.flac"],
                       @"title": @"Track 1", @"artist": @"ABBA", @"dur": @200, @"sr": @44100, @"bits": @16 }
                ]
            }
        };
    }
    if ([path hasPrefix:@"/api/lib/artists"]) {
        return @{ @"ok": @YES, @"artists": @[ @{ @"name": @"ABBA", @"albums": @2, @"tracks": @4 } ] };
    }
    if ([path hasPrefix:@"/api/lib/search"]) return @{ @"ok": @YES, @"tracks": @[], @"total": @0, @"n": @0 };
    if ([path hasPrefix:@"/api/lib/stats"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/queue"]) return @{ @"ok": @YES, @"items": @[], @"index": @(-1), @"mode": @0 };
    if ([path hasPrefix:@"/api/status"]) {
        return @{ @"ok": @YES, @"playing": @NO, @"paused": @NO, @"current": @"",
                  @"pos": @0, @"dur": @0, @"volDb": @(-120) };
    }
    if ([path hasPrefix:@"/api/sq/list"]) return @{ @"ok": @YES, @"queues": @[] };
    if ([path hasPrefix:@"/api/entity/versions"]) {
        return @{ @"ok": @YES, @"performances": @[], @"distinctCount": @0, @"releaseCount": @0 };
    }
    if ([path hasPrefix:@"/api/settings"]) return @{ @"ok": @YES };
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    return @{ @"ok": @YES };
}
@end

static RLPNavSpy *g_spy;
static id FakeSharedClient(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }

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

static NSButton *TopbarBackButton(RLPMainWindowController *wc) {
    return (NSButton *)FindById(wc.window.contentView, @"top.back");
}

static NSUInteger StackCount(RLPMainWindowController *wc) {
    id stack = [wc valueForKey:@"rowStack"];
    return [stack isKindOfClass:[NSArray class]] ? [(NSArray *)stack count] : 0;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_spy = [RLPNavSpy new];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];

        Method shared = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        method_setImplementation(shared, (IMP)FakeSharedClient);

        std::printf("=== test_native_navigation_contract（空态路由 / 切页清栈 / 嵌套详情返回 · 离屏）===\n");
        RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
        wc.window.contentView.frame = NSMakeRect(0, 0, 1280, 900);
        [wc.window.contentView layoutSubtreeIfNeeded];
        Pump(0.15);

        NSButton *backBtn = TopbarBackButton(wc);
        Ck(backBtn != nil, "顶栏存在 top.back 返回按钮", @"backBtn=nil");
        Ck(backBtn.hidden == YES && StackCount(wc) == 0,
           "初始在专辑页时 top.back 隐藏且返回栈为空",
           [NSString stringWithFormat:@"hidden=%d stack=%lu", backBtn.hidden, (unsigned long)StackCount(wc)]);

        // ---- 1. onEmptyStation -> @"station" ----
        g_spy.albumsEmpty = YES;
        [wc.albums reload];
        Pump(0.1);
        NSButton *emptyStationBtn = (NSButton *)FindById(wc.albums.view, @"albums.emptyStation");
        Ck(emptyStationBtn != nil, "专辑空态卡存在 albums.emptyStation 按钮", @"nil");
        [emptyStationBtn performClick:nil];
        Pump(0.1);
        Ck([wc.sidebar.selectedKey isEqualToString:@"station"],
           "点击空态「打开快速开始」后 sidebar.selectedKey == \"station\"",
           [NSString stringWithFormat:@"selectedKey=%@", wc.sidebar.selectedKey]);
        Ck([wc.currentContent isKindOfClass:[RLPQuickStartViewController class]] &&
           [wc.currentContent.view.identifier isEqualToString:@"page.station"],
           "点击空态「打开快速开始」后当前页为 RLPQuickStartViewController (page.station)",
           [NSString stringWithFormat:@"vc=%@ id=%@", NSStringFromClass(wc.currentContent.class), wc.currentContent.view.identifier]);
        Ck(backBtn.hidden == YES && StackCount(wc) == 0,
           "跳到快速开始页后 top.back 仍隐藏且栈为空",
           [NSString stringWithFormat:@"hidden=%d stack=%lu", backBtn.hidden, (unsigned long)StackCount(wc)]);

        g_spy.albumsEmpty = NO;
        [wc.sidebar selectKey:@"albums"];
        [wc.albums reload];
        Pump(0.1);

        // ---- 2. 切顶级侧栏页清 rowStack 且隐藏返回按钮 ----
        RLPRequestOpenAlbum(@"/Music/ABBA/Arrival");
        Pump(0.1);
        Ck([wc.currentContent isKindOfClass:[RLPAlbumDetailViewController class]],
           "从专辑页进入专辑详情", NSStringFromClass(wc.currentContent.class));
        Ck(backBtn.hidden == NO && StackCount(wc) == 1,
           "进入专辑详情后 top.back 可见且 stack=1",
           [NSString stringWithFormat:@"hidden=%d stack=%lu", backBtn.hidden, (unsigned long)StackCount(wc)]);

        [wc.sidebar selectKey:@"tracks"];
        Pump(0.1);
        Ck([wc.currentContent isKindOfClass:[RLPTracksViewController class]] &&
           [wc.currentContent.view.identifier isEqualToString:@"page.tracks"],
           "切到顶级侧栏页 tracks 后显示曲目页",
           [NSString stringWithFormat:@"vc=%@ id=%@", NSStringFromClass(wc.currentContent.class), wc.currentContent.view.identifier]);
        Ck(backBtn.hidden == YES && StackCount(wc) == 0,
           "切到顶级侧栏页 tracks 后 rowStack 清空且 top.back 隐藏",
           [NSString stringWithFormat:@"hidden=%d stack=%lu", backBtn.hidden, (unsigned long)StackCount(wc)]);

        RLPRequestBack();
        Pump(0.05);
        Ck([wc.currentContent isKindOfClass:[RLPTracksViewController class]],
           "清空后触发返回不会跳回旧列表页", NSStringFromClass(wc.currentContent.class));

        // 2b. 从专辑详情点回同一顶级侧栏页 albums 也必须清栈隐藏返回键
        [wc.sidebar selectKey:@"albums"];
        Pump(0.05);
        RLPRequestOpenAlbum(@"/Music/ABBA/Arrival");
        Pump(0.05);
        Ck(backBtn.hidden == NO && StackCount(wc) == 1, "再次进专辑详情 stack=1", @"");
        [wc.sidebar selectKey:@"albums"];
        Pump(0.05);
        Ck(wc.currentContent == wc.albums && backBtn.hidden == YES && StackCount(wc) == 0,
           "在详情页点回同侧栏顶级页 albums 后清栈并隐藏 top.back",
           [NSString stringWithFormat:@"same=%d hidden=%d stack=%lu",
            wc.currentContent == wc.albums, backBtn.hidden, (unsigned long)StackCount(wc)]);

        // ---- 3a. 嵌套详情返回：artists -> artistDetail -> albumDetail ----
        [wc.sidebar selectKey:@"artists"];
        Pump(0.1);
        RLPRequestOpenArtist(@"ABBA");
        Pump(0.1);
        NSViewController *artistVC = wc.currentContent;
        Ck([artistVC isKindOfClass:[RLPArtistDetailViewController class]],
           "从艺术家页进入艺术家详情", NSStringFromClass(artistVC.class));
        Ck(backBtn.hidden == NO && StackCount(wc) == 1,
           "艺术家详情页 top.back 可见且 stack=1",
           [NSString stringWithFormat:@"hidden=%d stack=%lu", backBtn.hidden, (unsigned long)StackCount(wc)]);

        RLPRequestOpenAlbum(@"/Music/ABBA/Arrival");
        Pump(0.1);
        NSViewController *albumVC = wc.currentContent;
        Ck([albumVC isKindOfClass:[RLPAlbumDetailViewController class]] && albumVC != artistVC,
           "从艺术家详情嵌套进入专辑详情", NSStringFromClass(albumVC.class));
        Ck(backBtn.hidden == NO && StackCount(wc) == 2,
           "嵌套专辑详情页 top.back 可见且 stack=2",
           [NSString stringWithFormat:@"hidden=%d stack=%lu", backBtn.hidden, (unsigned long)StackCount(wc)]);

        [backBtn performClick:nil];
        Pump(0.1);
        Ck(wc.currentContent == artistVC,
           "嵌套第 1 次返回回到真实上层艺术家详情（不跳层回列表）",
           [NSString stringWithFormat:@"got=%@ want=%@",
            NSStringFromClass(wc.currentContent.class), NSStringFromClass(artistVC.class)]);
        Ck(backBtn.hidden == NO && StackCount(wc) == 1 && [wc.sidebar.selectedKey isEqualToString:@"artists"],
           "回到上层艺术家详情后 top.back 仍可见、stack=1 且侧栏保持 artists",
           [NSString stringWithFormat:@"hidden=%d stack=%lu key=%@",
            backBtn.hidden, (unsigned long)StackCount(wc), wc.sidebar.selectedKey]);

        RLPRequestBack();
        Pump(0.1);
        Ck([wc.currentContent isKindOfClass:[RLPArtistsViewController class]] &&
           [wc.currentContent.view.identifier isEqualToString:@"page.artists"],
           "嵌套第 2 次返回回到艺术家列表页", NSStringFromClass(wc.currentContent.class));
        Ck(backBtn.hidden == YES && StackCount(wc) == 0,
           "回到艺术家列表页后 top.back 隐藏且 stack=0",
           [NSString stringWithFormat:@"hidden=%d stack=%lu", backBtn.hidden, (unsigned long)StackCount(wc)]);

        // ---- 3b. 嵌套详情返回：albums -> albumA -> albumB -> albumA -> albums ----
        [wc.sidebar selectKey:@"albums"];
        Pump(0.05);
        RLPRequestOpenAlbum(@"/Music/ABBA/Arrival");
        Pump(0.05);
        NSViewController *albumA = wc.currentContent;
        RLPRequestOpenAlbum(@"/Music/ABBA/VoulezVous");
        Pump(0.05);
        NSViewController *albumB = wc.currentContent;
        Ck(albumA != albumB && [albumB isKindOfClass:[RLPAlbumDetailViewController class]] && StackCount(wc) == 2,
           "专辑详情内跳另一张专辑构成 2 层详情栈",
           [NSString stringWithFormat:@"stack=%lu", (unsigned long)StackCount(wc)]);

        [backBtn performClick:nil];
        Pump(0.05);
        Ck(wc.currentContent == albumA && backBtn.hidden == NO && StackCount(wc) == 1,
           "albumB 返回回到 albumA 实例且 stack=1",
           [NSString stringWithFormat:@"same=%d hidden=%d stack=%lu",
            wc.currentContent == albumA, backBtn.hidden, (unsigned long)StackCount(wc)]);

        [backBtn performClick:nil];
        Pump(0.05);
        Ck(wc.currentContent == wc.albums && backBtn.hidden == YES && StackCount(wc) == 0,
           "albumA 返回回到专辑网格页且 top.back 隐藏",
           [NSString stringWithFormat:@"same=%d hidden=%d stack=%lu",
            wc.currentContent == wc.albums, backBtn.hidden, (unsigned long)StackCount(wc)]);

        // ---- 3c. 嵌套作品页 + 重复打开 worksPage 不重复压栈 + NowPlaying 覆盖层优先级 ----
        RLPRequestOpenAlbum(@"/Music/ABBA/Arrival");
        Pump(0.05);
        NSViewController *albumC = wc.currentContent;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenWorksNotification"
                                                            object:@{ @"title": @"Bolero", @"composer": @"Ravel" }];
        Pump(0.05);
        Ck([wc.currentContent isKindOfClass:[RLPWorksViewController class]] && StackCount(wc) == 2,
           "从专辑详情打开作品页 stack=2",
           [NSString stringWithFormat:@"vc=%@ stack=%lu", NSStringFromClass(wc.currentContent.class), (unsigned long)StackCount(wc)]);

        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenWorksNotification"
                                                            object:@{ @"title": @"Symphony No. 5", @"composer": @"Beethoven" }];
        Pump(0.05);
        Ck([wc.currentContent isKindOfClass:[RLPWorksViewController class]] && StackCount(wc) == 2,
           "已在作品页时再次触发 RLPOpenWorksNotification 不重复压栈",
           [NSString stringWithFormat:@"stack=%lu", (unsigned long)StackCount(wc)]);

        RLPRequestBack();
        Pump(0.05);
        Ck(wc.currentContent == albumC && StackCount(wc) == 1,
           "作品页返回回到上层专辑详情 albumC",
           [NSString stringWithFormat:@"same=%d stack=%lu", wc.currentContent == albumC, (unsigned long)StackCount(wc)]);

        // NowPlaying 覆盖层打开时，RLPRequestBack 先关覆盖层，不动详情栈
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenNowPlayingNotification" object:nil];
        Pump(0.05);
        Ck(wc.nowPlayingOverlayVisible == YES, "打开正在播放覆盖层", @"");
        RLPRequestBack();
        Pump(0.05);
        Ck(wc.nowPlayingOverlayVisible == NO && wc.currentContent == albumC && StackCount(wc) == 1 && backBtn.hidden == NO,
           "覆盖层打开时 RLPRequestBack 只关覆盖层，保留当前详情与 stack=1",
           [NSString stringWithFormat:@"np=%d same=%d stack=%lu hidden=%d",
            wc.nowPlayingOverlayVisible, wc.currentContent == albumC, (unsigned long)StackCount(wc), backBtn.hidden]);

        // 从嵌套详情直接发 RLPNavigateKeyNotification("queue") 必须清栈隐藏返回按钮
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenWorksNotification"
                                                            object:@{ @"title": @"Bolero", @"composer": @"Ravel" }];
        Pump(0.05);
        Ck(StackCount(wc) == 2, "再压入作品页 stack=2", @"");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"queue"];
        Pump(0.05);
        Ck([wc.currentContent isKindOfClass:[RLPQueueViewController class]] &&
           backBtn.hidden == YES && StackCount(wc) == 0,
           "从深层详情发 RLPNavigateKeyNotification(\"queue\") 清栈并隐藏 top.back",
           [NSString stringWithFormat:@"vc=%@ hidden=%d stack=%lu",
            NSStringFromClass(wc.currentContent.class), backBtn.hidden, (unsigned long)StackCount(wc)]);

        [wc stopAllActivity];
        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
