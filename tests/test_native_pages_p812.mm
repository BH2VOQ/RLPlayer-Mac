// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_pages_p812.mm — 页面 P8–P12 的行为判据（离屏 · 不启动核心 · 不出声）
//
// P12 收藏 / 最近列结构 = web 列集：
//   web 我的最爱（ui_script.h:3703-3721）：34px # / 1fr 标题 / 180px 艺术家 / 200px 专辑 / 34px 心
//     —— **没有**时长列；表头行 .favhead 仍在。
//   web 最近播放（ui_script.h:3595-3599）：34px # / 1fr 标题 / 160px 艺术家 / 92px 专辑
//     —— 没有时长列，列表**没有表头行**（行模板直接进 #list）。
//   旧原生：收藏 6 列（多「时长」）、最近 5 列（多「时长」）且挂了表头视图。
//
// ============================ 铁律②：绝不出声 ============================
// 记录型桩 RLPPages812Spy 替换 +[RLPCoreClient shared]：只记录 / 返回 fixture，
// 不启动核心、不碰音频设备、不创建可见窗口（离屏 NSWindow 承载页面）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPFavoritesViewController.h"
#import "RLPRecentViewController.h"
#import "RLPTheme.h"
#import "RLPSupport.h"
#import <objc/runtime.h>

#include <cstdio>
#include <cmath>

static int g_pass = 0, g_fail = 0;
static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}

#pragma mark - 记录型桩客户端

@interface RLPPages812Spy : NSObject
@property (nonatomic, strong) NSMutableArray<NSString *> *gets;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *posts;
@end

@implementation RLPPages812Spy

- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown { }

- (NSDictionary *)fixtureForPath:(NSString *)path {
    if ([path hasPrefix:@"/api/fav/list"]) {
        return @{ @"ok": @YES, @"files": @[
            @{ @"file": @"/Music/Fav/One.flac", @"title": @"One", @"artist": @"A",
               @"album": @"Fav", @"dur": @180, @"year": @2001 },
            @{ @"file": @"/Music/Fav/Two.flac", @"title": @"Two", @"artist": @"B",
               @"album": @"Fav", @"dur": @200, @"year": @2005 },
            @{ @"file": @"/Music/Fav/Three.flac", @"title": @"Three", @"artist": @"C",
               @"album": @"Fav", @"dur": @220, @"year": @2010 },
        ] };
    }
    if ([path hasPrefix:@"/api/recent"]) {
        return @{ @"ok": @YES, @"items": @[
            @{ @"path": @"/Music/R/One.flac", @"title": @"One", @"artist": @"A", @"album": @"R", @"dur": @180 },
            @{ @"path": @"/Music/R/Two.flac", @"title": @"Two", @"artist": @"B", @"album": @"/Music/R", @"dur": @200 },
            @{ @"path": @"/Music/R/Three.flac", @"title": @"Three", @"artist": @"C", @"album": @"R", @"dur": @220 },
        ] };
    }
    if ([path hasPrefix:@"/api/sq/list"]) {
        return @{ @"ok": @YES, @"queues": @[ @{ @"name": @"Night Drive", @"n": @3 } ] };
    }
    if ([path hasPrefix:@"/api/sq/info"]) {
        return @{ @"ok": @YES, @"name": @"Night Drive", @"items": @[
            @{ @"file": @"/Music/PL/01.flac", @"cs": @(-1), @"ce": @(-1) },
            @{ @"file": @"/Music/PL/02.flac", @"cs": @(-1), @"ce": @(-1) },
            @{ @"file": @"/Music/PL/03.flac", @"cs": @(-1), @"ce": @(-1) },
        ] };
    }
    if ([path hasPrefix:@"/api/lib/search"]) {
        // 空查询回 3 首；带 q 一律 0 首（P9 空态判据从这里来）。
        if ([path rangeOfString:@"q="].location == NSNotFound ||
            [path hasPrefix:@"/api/lib/search?q=&"] ||
            [path isEqualToString:@"/api/lib/search?q=&limit=300"]) {
            return @{ @"ok": @YES, @"tracks": @[
                @{ @"path": @"/Music/T/One.flac", @"title": @"One", @"artist": @"A", @"album": @"T", @"dur": @180, @"sr": @44100, @"bits": @16 },
                @{ @"path": @"/Music/T/Two.flac", @"title": @"Two", @"artist": @"B", @"album": @"T", @"dur": @200, @"sr": @44100, @"bits": @16 },
                @{ @"path": @"/Music/T/Three.flac", @"title": @"Three", @"artist": @"C", @"album": @"T", @"dur": @220, @"sr": @44100, @"bits": @16 },
            ], @"total": @3 };
        }
        return @{ @"ok": @YES, @"tracks": @[], @"total": @0 };
    }
    if ([path hasPrefix:@"/api/lib/albums"]) {
        return @{ @"ok": @YES, @"albums": @[
            @{ @"k": @"/Music/A/One", @"name": @"One", @"artist": @"A", @"year": @2001, @"n": @1, @"dur": @180, @"sr": @44100, @"bits": @16 },
            @{ @"k": @"/Music/A/Two", @"name": @"Two", @"artist": @"B", @"year": @2005, @"n": @1, @"dur": @200, @"sr": @44100, @"bits": @16 },
        ] };
    }
    if ([path hasPrefix:@"/api/queue"]) {
        return @{ @"ok": @YES, @"items": @[], @"index": @(-1), @"mode": @0 };
    }
    if ([path hasPrefix:@"/api/playmode"]) return @{ @"ok": @YES, @"mode": @0 };
    if ([path hasPrefix:@"/api/status"]) {
        return @{ @"ok": @YES, @"playing": @NO, @"paused": @NO, @"current": @"",
                  @"pos": @0, @"dur": @0, @"volDb": @(-120) };
    }
    if ([path hasPrefix:@"/api/lib/roots"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/settings"]) return @{ @"ok": @YES };
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    if ([path hasPrefix:@"/api/lib/stats"]) return @{ @"ok": @YES, @"tracks": @0, @"albums": @0 };
    return @{ @"ok": @NO };
}

- (id)jsonWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body {
    (void)method; (void)body;
    [self.gets addObject:path ?: @""];
    return [self fixtureForPath:path ?: @""];
}
- (NSData *)dataWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body
               contentType:(NSString **)contentType {
    (void)method; (void)body; (void)contentType;
    [self.gets addObject:path ?: @""];
    return nil;
}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [self.gets addObject:path ?: @""];
    if (!done) return;
    NSDictionary *json = [self fixtureForPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [self.posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    if (!done) return;
    dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    (void)path; if (done) done(nil);
}
- (void)postData:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType
       completion:(RLPJSONCompletion)done {
    (void)path; (void)body; (void)contentType; if (done) done(@{ @"ok": @YES });
}
@end

static RLPPages812Spy *g_spy;
static id PageP812FakeShared(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }

#pragma mark - 工具

static void CollectAll(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectAll(s, out);
}
static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static NSTableView *TableOf(NSViewController *vc) {
    return [vc valueForKey:@"tableView"];
}
static NSString *ColTitle(NSTableView *tv, NSInteger i) {
    if (i < 0 || i >= (NSInteger)tv.numberOfColumns) return @"(out of range)";
    return [tv tableColumns][(NSUInteger)i].title ?: @"";
}
static CGFloat ColWidth(NSTableView *tv, NSInteger i) {
    if (i < 0 || i >= (NSInteger)tv.numberOfColumns) return -1;
    return [tv tableColumns][(NSUInteger)i].width;
}

#pragma mark - 主流程

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_spy = [RLPPages812Spy new];
        g_spy.gets = [NSMutableArray array];
        g_spy.posts = [NSMutableArray array];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        Method shared = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        method_setImplementation(shared, (IMP)PageP812FakeShared);

        std::printf("=== test_native_pages_p812（P8–P12 · 离屏 · 不出声）===\n");

        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 860)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 860)];
        static NSWindow *sWindow; sWindow = win;

        // ---- P12 收藏列结构（web .favhead：34 / 1fr / 180 / 200 / 34）----
        {
            RLPFavoritesViewController *fav = [RLPFavoritesViewController new];
            fav.view.frame = NSMakeRect(0, 0, 1000, 700);
            [win.contentView addSubview:fav.view];
            [fav.view layoutSubtreeIfNeeded];
            [fav reloadData];
            Pump(0.1);
            NSTableView *tv = TableOf(fav);
            Ck(tv != nil, "P12 找得到收藏表格（判据前提）", @"tableView 缺失");
            if (tv) {
                Ck(tv.numberOfColumns == 5,
                   "P12 收藏列数 = 5（#/标题/艺术家/专辑/心，去掉时长）",
                   [NSString stringWithFormat:@"columns=%ld", (long)tv.numberOfColumns]);
                Ck([ColTitle(tv, 0) isEqualToString:RLPTr(@"#")] &&
                   [ColTitle(tv, 1) isEqualToString:RLPTr(@"标题")] &&
                   [ColTitle(tv, 2) isEqualToString:RLPTr(@"艺术家")] &&
                   [ColTitle(tv, 3) isEqualToString:RLPTr(@"专辑")] &&
                   [ColTitle(tv, 4) isEqualToString:@""],
                   "P12 收藏列标题 = #/标题/艺术家/专辑/心（无「时长」）",
                   [NSString stringWithFormat:@"titles=%@ | %@ | %@ | %@ | %@",
                    ColTitle(tv,0), ColTitle(tv,1), ColTitle(tv,2), ColTitle(tv,3), ColTitle(tv,4)]);
                Ck(tv.numberOfColumns >= 1 && std::fabs(ColWidth(tv, 0) - 34.0) < 0.5,
                   "P12 收藏 # 列宽 = 34px（web 34px）",
                   [NSString stringWithFormat:@"w0=%.1f", ColWidth(tv, 0)]);
                Ck(ColWidth(tv, 1) > 150.0,
                   "P12 收藏标题列吃剩余宽度（web 1fr）",
                   [NSString stringWithFormat:@"w1=%.1f", ColWidth(tv, 1)]);
                Ck(tv.numberOfColumns >= 3 && std::fabs(ColWidth(tv, 2) - 180.0) < 0.5,
                   "P12 收藏艺术家列宽 = 180px（web 180px）",
                   [NSString stringWithFormat:@"w2=%.1f", ColWidth(tv, 2)]);
                Ck(tv.numberOfColumns >= 4 && std::fabs(ColWidth(tv, 3) - 200.0) < 0.5,
                   "P12 收藏专辑列宽 = 200px（web 200px）",
                   [NSString stringWithFormat:@"w3=%.1f", ColWidth(tv, 3)]);
                Ck(tv.numberOfColumns >= 5 && std::fabs(ColWidth(tv, 4) - 34.0) < 0.5,
                   "P12 收藏心列宽 = 34px（web 34px）",
                   [NSString stringWithFormat:@"w4=%.1f", ColWidth(tv, 4)]);
            }
        }

        // ---- P12 最近列结构（web：34 / 1fr / 160 / 92，无表头行）----
        {
            RLPRecentViewController *recent = [RLPRecentViewController new];
            recent.view.frame = NSMakeRect(0, 0, 1000, 700);
            [win.contentView addSubview:recent.view];
            [recent.view layoutSubtreeIfNeeded];
            [recent reloadData];
            Pump(0.1);
            NSTableView *tv = TableOf(recent);
            Ck(tv != nil, "P12 找得到最近表格（判据前提）", @"tableView 缺失");
            if (tv) {
                Ck(tv.numberOfColumns == 4,
                   "P12 最近列数 = 4（#/标题/艺术家/专辑，去掉时长）",
                   [NSString stringWithFormat:@"columns=%ld", (long)tv.numberOfColumns]);
                Ck([ColTitle(tv, 0) isEqualToString:RLPTr(@"#")] &&
                   [ColTitle(tv, 1) isEqualToString:RLPTr(@"标题")] &&
                   [ColTitle(tv, 2) isEqualToString:RLPTr(@"艺术家")] &&
                   [ColTitle(tv, 3) isEqualToString:RLPTr(@"专辑")],
                   "P12 最近列标题 = #/标题/艺术家/专辑（无「时长」）",
                   [NSString stringWithFormat:@"titles=%@ | %@ | %@ | %@",
                    ColTitle(tv,0), ColTitle(tv,1), ColTitle(tv,2), ColTitle(tv,3)]);
                Ck(tv.headerView == nil,
                   "P12 最近列表没有表头行（web 行模板直接进列表）",
                   [NSString stringWithFormat:@"headerView=%@", tv.headerView]);
                Ck(std::fabs(ColWidth(tv, 0) - 34.0) < 0.5,
                   "P12 最近 # 列宽 = 34px（web 34px）",
                   [NSString stringWithFormat:@"w0=%.1f", ColWidth(tv, 0)]);
                Ck(ColWidth(tv, 1) > 150.0,
                   "P12 最近标题列吃剩余宽度（web 1fr）",
                   [NSString stringWithFormat:@"w1=%.1f", ColWidth(tv, 1)]);
                Ck(tv.numberOfColumns >= 3 && std::fabs(ColWidth(tv, 2) - 160.0) < 0.5,
                   "P12 最近艺术家列宽 = 160px（web 160px）",
                   [NSString stringWithFormat:@"w2=%.1f", ColWidth(tv, 2)]);
                Ck(tv.numberOfColumns >= 4 && std::fabs(ColWidth(tv, 3) - 92.0) < 0.5,
                   "P12 最近专辑列宽 = 92px（web 92px）",
                   [NSString stringWithFormat:@"w3=%.1f", ColWidth(tv, 3)]);
            }
        }

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
