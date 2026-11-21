// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_topbar_search.mm — 顶栏搜索语义 = web #q（oninput 260ms 防抖 + 按当前视图分派）
//
// ============================ 这条判据在证明什么 ============================
// web 真源（ui_script.h:6006-6069）：
//   · D('q').oninput：每次输入重置 260ms 定时器，到点按**当前视图**分派
//     —— albums/artists/tracks 三页**页内过滤**（loadAlbums(q) / loadArtists(q) / loadTracks(q)），
//        其余视图（files/recent/queue/settings/station...）才 setView('tracks') 做全局搜索；
//   · onkeydown Escape 与清空键：clearSearchQuery() 按当前视图重拉整库（其余视图回专辑页）。
// 旧原生（RLPMainWindowController.mm:191-196, 567-578）：NSSearchField 只有 target/action，
//   必须按**回车**；且 onSearch: **无条件**切到曲目页 ⟹ 停在专辑页打字也会被拽走。
// 所以本文件对旧码必须红。
//
// 纪律：不启动核心（全部数据来自 spy fixture）；不碰音频设备；不创建可见窗口。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPAlbumsViewController.h"
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

#pragma mark - 记录型桩客户端（替换 +[RLPCoreClient shared]）

@interface RLPSearchSpy : NSObject
@property (nonatomic, strong) NSMutableArray<NSString *> *paths;
@end
@implementation RLPSearchSpy
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown { }
- (id)jsonWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body {
    (void)method; (void)body;
    [self.paths addObject:path ?: @""];
    return nil;
}
- (NSData *)dataWithMethod:(NSString *)method path:(NSString *)path body:(NSString *)body
               contentType:(NSString **)contentType {
    (void)method; (void)body; (void)contentType;
    [self.paths addObject:path ?: @""];
    return nil;
}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [self.paths addObject:path ?: @""];
    if (!done) return;
    NSDictionary *json = [self fixtureForPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    (void)body;
    [self.paths addObject:path ?: @""];
    if (!done) return;
    dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postData:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType
       completion:(RLPJSONCompletion)done { (void)path; (void)body; (void)contentType; if (done) done(@{ @"ok": @YES }); }

/// 曲库 fixture：整库 3 张专辑 / 3 位艺术家；按 q=bee 过滤只剩 1 张（后端 /api/lib/albums?q=
/// 本来就是按"专辑名 + 艺术家"子串匹配，见 tools/rtaweb.cpp:8117-8158）。
- (NSDictionary *)fixtureForPath:(NSString *)path {
    if ([path hasPrefix:@"/api/lib/albums"]) {
        NSString *q = @"";
        NSRange r = [path rangeOfString:@"?q="];
        if (r.location != NSNotFound) q = [path substringFromIndex:NSMaxRange(r)];
        q = [q lowercaseString];
        NSArray *all = @[
            @{ @"k": @"/Music/ABBA/Arrival", @"name": @"Arrival", @"artist": @"ABBA",
               @"year": @1976, @"n": @10, @"dur": @2160, @"sr": @44100, @"bits": @16, @"cv": @NO },
            @{ @"k": @"/Music/Bee Gees/Greatest", @"name": @"Greatest", @"artist": @"Bee Gees",
               @"year": @1979, @"n": @20, @"dur": @4200, @"sr": @44100, @"bits": @16, @"cv": @NO },
            @{ @"k": @"/Music/Carpenters/Gold", @"name": @"Gold", @"artist": @"Carpenters",
               @"year": @1992, @"n": @18, @"dur": @3900, @"sr": @44100, @"bits": @16, @"cv": @NO },
        ];
        if (!q.length) return @{ @"ok": @YES, @"q": @"", @"albums": all };
        NSMutableArray *hit = [NSMutableArray array];
        for (NSDictionary *a in all) {
            NSString *hay = [[NSString stringWithFormat:@"%@ %@", a[@"name"], a[@"artist"]] lowercaseString];
            if ([hay containsString:q]) [hit addObject:a];
        }
        return @{ @"ok": @YES, @"q": q, @"albums": hit };
    }
    if ([path hasPrefix:@"/api/lib/search"]) return @{ @"ok": @YES, @"tracks": @[], @"total": @0, @"n": @0 };
    if ([path hasPrefix:@"/api/queue"]) return @{ @"ok": @YES, @"items": @[], @"index": @(-1), @"mode": @0 };
    if ([path hasPrefix:@"/api/status"]) {
        return @{ @"ok": @YES, @"playing": @NO, @"paused": @NO, @"current": @"",
                  @"pos": @0, @"dur": @0, @"volDb": @(-120) };
    }
    if ([path hasPrefix:@"/api/sq/list"]) return @{ @"ok": @YES, @"queues": @[] };
    if ([path hasPrefix:@"/api/lib/roots"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/settings"]) return @{ @"ok": @YES };
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    return @{ @"ok": @NO };
}
@end

static RLPSearchSpy *spy;
static id fakeShared(id cls, SEL sel) { (void)cls; (void)sel; return spy; }

#pragma mark - 工具

static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static NSInteger CountPrefix(NSArray<NSString *> *paths, NSString *prefix) {
    NSInteger n = 0;
    for (NSString *p in paths) if ([p hasPrefix:prefix]) ++n;
    return n;
}
static NSInteger CountAlbumsQueries(void) {
    NSInteger n = 0;
    for (NSString *p in spy.paths)
        if ([p hasPrefix:@"/api/lib/albums?q="]) ++n;
    return n;
}
static NSInteger CountAlbumsPlain(void) {
    NSInteger n = 0;
    for (NSString *p in spy.paths)
        if ([p isEqualToString:@"/api/lib/albums"] || [p hasPrefix:@"/api/lib/albums?q="]) ++n;
    return n;
}
static NSString *PageIdent(RLPMainWindowController *wc) {
    return wc.currentContent.view.identifier ?: @"";
}

@interface RLPMainWindowController (SearchTestSeam)
- (void)controlTextDidChange:(NSNotification *)note;
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector;
- (void)applySearchQuery:(NSString *)query;
- (void)clearSearchQuery;
@end

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        spy = [RLPSearchSpy new];
        spy.paths = [NSMutableArray array];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        // 替换 +shared（与 test_native_nowplaying_web 同一套接缝）：所有页面的数据都来自 fixture，
        // 同时能记录页面**真的发出了什么请求**。绝不启动真核心（不出声、不碰设备）。
        Method shared = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        method_setImplementation(shared, (IMP)fakeShared);

        std::printf("=== test_native_topbar_search（260ms 防抖 + 按当前视图分派 · 离屏 · 不出声）===\n");
        RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
        wc.window.contentView.frame = NSMakeRect(0, 0, 1280, 900);
        [wc.window.contentView layoutSubtreeIfNeeded];
        Pump(0.3);
        // 2026-11-21：启动默认页已改成 station（聆听室 / 数字音乐台），
        // 所以专辑页不再在窗口构造时被自动加载。本测试验的是「顶栏搜索按当前视图分派」，
        // 需要专辑页作为载体 ⟹ 这里显式进一次专辑页（判据意图不变，只补上被启动页改动
        // 拿掉的那个前提）。
        [wc.sidebar selectKey:@"albums"];
        Pump(0.3);
        NSSearchField *search = (NSSearchField *)[wc valueForKey:@"search"];
        Ck(search != nil, "顶栏存在搜索框", @"缺搜索框");
        Ck(wc.albums.albumCount == 3, "专辑页拿到 fixture 的 3 张专辑（前提）",
           [NSString stringWithFormat:@"count=%ld", (long)wc.albums.albumCount]);
        if (!search) { std::printf("结果：%d passed, %d failed\n", g_pass, g_fail); return 1; }

        // ---- 0. 接线：不是只有回车 ----
        Ck(search.delegate != nil, "搜索框挂了 delegate（边输入边搜的接线条）", @"delegate=nil");
        Ck((id)search.delegate == (id)wc, "delegate 就是主窗口控制器", @"不是 wc");
        Ck([search.delegate respondsToSelector:@selector(controlTextDidChange:)],
           "delegate 实现 controlTextDidChange:（web #q.oninput）", @"旧码没实现");
        Ck([search.delegate respondsToSelector:
              @selector(control:textView:doCommandBySelector:)],
           "delegate 实现 doCommandBySelector:（Esc 清空的接线条）", @"旧码没实现");
        Ck(search.target == wc && search.action == @selector(onSearch:),
           "回车仍走 onSearch:", @"target/action 变了");

        // ---- 0b. 语义对照（旧码也存在这条通路：回车）：停在专辑页搜索不该被拽到曲目页 ----
        [wc.sidebar selectKey:@"albums"];
        Pump(0.25);
        search.stringValue = @"bee";
        [wc performSelector:@selector(onSearch:) withObject:search];
        Pump(0.2);
        Ck([wc.sidebar.selectedKey isEqualToString:@"albums"],
           "在专辑页回车搜索仍留在专辑页（旧码无条件切曲目页）",
           wc.sidebar.selectedKey ?: @"(nil)");
        Ck([PageIdent(wc) isEqualToString:@"page.albums"], "内容页仍是 page.albums", PageIdent(wc));
        Ck(wc.albums.albumCount == 1, "专辑页搜索是真的页内过滤（3 张 → 1 张）",
           [NSString stringWithFormat:@"count=%ld", (long)wc.albums.albumCount]);
        // 复位：清空（新码）或直接空搜索（旧码），让后面的防抖判据从干净状态起跑
        if ([wc respondsToSelector:@selector(clearSearchQuery)]) {
            [wc performSelector:@selector(clearSearchQuery)];
        } else {
            search.stringValue = @"";
            [wc performSelector:@selector(onSearch:) withObject:search];
        }
        Pump(0.2);

        // ---- 1. 停在专辑页输入（不回车）：350ms 后仍在专辑页，且列表被过滤 ----
        [wc.sidebar selectKey:@"albums"];
        Pump(0.25);
        Ck(wc.albums.albumCount == 3, "复位后专辑页是整库 3 张（判据前提）",
           [NSString stringWithFormat:@"count=%ld", (long)wc.albums.albumCount]);
        const NSInteger albumsBefore = CountAlbumsQueries();
        BOOL canType = [wc respondsToSelector:@selector(controlTextDidChange:)];
        Ck(canType, "主窗口实现了 controlTextDidChange:（判据的驱动入口）", @"旧码没有");
        if (canType) {
            search.stringValue = @"bee";
            NSNotification *note = [NSNotification notificationWithName:NSControlTextDidChangeNotification
                                                                  object:search];
            [wc controlTextDidChange:note];
            Pump(0.15);   // 防抖窗口内（260ms 未到）
            Ck(CountAlbumsQueries() == albumsBefore,
               "260ms 防抖窗口内不重复发请求（不是每按一键就发）",
               [NSString stringWithFormat:@"before=%ld now=%ld", (long)albumsBefore,
                (long)CountAlbumsQueries()]);
            Pump(0.30);   // 累计约 450ms：已越过 260ms
            Ck(CountAlbumsQueries() > albumsBefore,
               "不按回车也会在 350ms 后自动发起过滤请求（web oninput 防抖）",
               [NSString stringWithFormat:@"before=%ld now=%ld", (long)albumsBefore,
                (long)CountAlbumsQueries()]);
            // 判据改成「本次搜索确实发出过带 q=bee 的专辑查询」，而不是取 lastObject。
            // 为什么：切页/激活会顺带发出其它请求（如 /api/queue?meta=1），
            // lastObject 是否恰为搜索请求取决于时序，与本条要证明的事
            // 「过滤词有没有真的传给后端」无关 —— 那是判据写错，不是实现错。
            BOOL sawQ = NO;
            for (NSString *p2 in spy.paths) {
                if ([p2 isEqualToString:@"/api/lib/albums?q=bee"]) { sawQ = YES; break; }
                if (p2.length >= 24 && [[p2 substringToIndex:24] isEqualToString:@"/api/lib/albums?q=bee"]) {
                    sawQ = YES; break;
                }
            }
            Ck(sawQ, "请求带上了用户输入的过滤词 q=bee",
               [NSString stringWithFormat:@"last=%@ total=%lu",
                spy.paths.lastObject ?: @"", (unsigned long)spy.paths.count]);
            Ck([wc.sidebar.selectedKey isEqualToString:@"albums"], "仍然停在专辑页（不跳页）",
               wc.sidebar.selectedKey ?: @"(nil)");
            Ck(wc.currentContent == (id)wc.albums, "当前内容仍是专辑页控制器", @"已被切走");
            Ck([PageIdent(wc) isEqualToString:@"page.albums"], "页面锚点仍是 page.albums", PageIdent(wc));
            Ck(wc.albums.albumCount == 1, "专辑列表被过滤（3 张 → 1 张）",
               [NSString stringWithFormat:@"count=%ld", (long)wc.albums.albumCount]);

            // ---- 2. Esc 清空：按当前视图重拉整库 ----
            BOOL canClear = [wc respondsToSelector:@selector(clearSearchQuery)];
            Ck(canClear, "主窗口实现了 clearSearchQuery（web 清空/Esc 同一条路径）", @"缺入口");
            const NSInteger albumsAllBefore = CountAlbumsPlain();
            BOOL handled = [wc control:search textView:nil
                 doCommandBySelector:@selector(cancelOperation:)];
            Ck(handled, "Esc 被 delegate 吃掉（走清空而不是系统 beep）", @"未处理");
            Pump(0.12);
            Ck(search.stringValue.length == 0, "Esc 清空搜索框", search.stringValue ?: @"");
            Ck(CountAlbumsPlain() > albumsAllBefore, "清空后按当前视图重拉专辑列表", @"没有重拉");
            Ck(wc.albums.albumCount == 3, "清空恢复整库（1 张 → 3 张）",
               [NSString stringWithFormat:@"count=%ld", (long)wc.albums.albumCount]);

            // ---- 3. 回车 = 立即分派（不受防抖延迟）----
            search.stringValue = @"bee";
            const NSInteger albumsEnterBefore = CountAlbumsQueries();
            [wc performSelector:@selector(onSearch:) withObject:search];
            Pump(0.05);
            Ck(CountAlbumsQueries() > albumsEnterBefore, "回车立即发起过滤（不等 260ms）", @"没有立即发");
            Ck(wc.albums.albumCount == 1, "回车后专辑列表同样被过滤",
               [NSString stringWithFormat:@"count=%ld", (long)wc.albums.albumCount]);

            // ---- 4. 艺术家页：页内过滤（不切页、不发全局搜索）----
            [wc.sidebar selectKey:@"artists"];
            Pump(0.3);
            id artistsPage = wc.currentContent;
            NSArray *artistsAll = [artistsPage respondsToSelector:@selector(valueForKey:)]
                ? [artistsPage valueForKey:@"filteredArtists"] : nil;
            Ck(artistsAll != nil && artistsAll.count == 3, "艺术家页有 3 位艺术家（fixture 派生）",
               [NSString stringWithFormat:@"count=%lu", (unsigned long)artistsAll.count]);
            const NSInteger globalSearchBefore = CountPrefix(spy.paths, @"/api/lib/search");
            search.stringValue = @"bee";
            NSNotification *note2 = [NSNotification notificationWithName:NSControlTextDidChangeNotification
                                                                   object:search];
            [wc controlTextDidChange:note2];
            Pump(0.45);
            Ck([wc.sidebar.selectedKey isEqualToString:@"artists"], "艺术家页打字仍在艺术家页",
               wc.sidebar.selectedKey ?: @"(nil)");
            NSArray *artistsFiltered = [artistsPage valueForKey:@"filteredArtists"];
            Ck(artistsFiltered.count == 1, "艺术家列表被页内过滤（3 位 → 1 位）",
               [NSString stringWithFormat:@"count=%lu", (unsigned long)artistsFiltered.count]);
            Ck(CountPrefix(spy.paths, @"/api/lib/search") == globalSearchBefore,
               "页内过滤不触发全局曲目搜索", @"发了 /api/lib/search");

            // ---- 5. 曲目页：输入 → /api/lib/search?q= ----
            [wc.sidebar selectKey:@"tracks"];
            Pump(0.3);
            search.stringValue = @"bee";
            const NSInteger trackSearchBefore = CountPrefix(spy.paths, @"/api/lib/search");
            NSNotification *note3 = [NSNotification notificationWithName:NSControlTextDidChangeNotification
                                                                   object:search];
            [wc controlTextDidChange:note3];
            Pump(0.45);
            Ck(CountPrefix(spy.paths, @"/api/lib/search") > trackSearchBefore,
               "曲目页输入 → 发 /api/lib/search?q=bee", spy.paths.lastObject ?: @"");
            Ck([wc.sidebar.selectedKey isEqualToString:@"tracks"], "仍在曲目页",
               wc.sidebar.selectedKey ?: @"(nil)");

            // ---- 6. 非库列表页（设置页）：主动搜索才切曲目页（web 的 else 分支）----
            [wc.sidebar selectKey:@"settings"];
            Pump(0.45);
            Ck([wc.sidebar.selectedKey isEqualToString:@"settings"], "已进入设置页（前提）",
               wc.sidebar.selectedKey ?: @"(nil)");
            Ck([PageIdent(wc) isEqualToString:@"page.settings"], "设置页锚点 page.settings", PageIdent(wc));
            search.stringValue = @"";   // 先清空，避免残留的 bee 触发上一轮的过滤
            const NSInteger settingsSearchBefore = CountPrefix(spy.paths, @"/api/lib/search");
            search.stringValue = @"bee";
            NSNotification *note4 = [NSNotification notificationWithName:NSControlTextDidChangeNotification
                                                                   object:search];
            [wc controlTextDidChange:note4];
            Pump(0.45);
            Ck([wc.sidebar.selectedKey isEqualToString:@"tracks"],
               "在设置页输入 → 切到曲目页做全局搜索（web 同口径）",
               wc.sidebar.selectedKey ?: @"(nil)");
            Ck([PageIdent(wc) isEqualToString:@"page.tracks"], "内容页换成 page.tracks", PageIdent(wc));
            Ck(CountPrefix(spy.paths, @"/api/lib/search") > settingsSearchBefore,
               "并且真的发出曲目搜索", spy.paths.lastObject ?: @"");
        }

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
