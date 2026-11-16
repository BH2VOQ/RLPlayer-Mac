// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_pages_fixes.mm — 收藏页/歌单页的交互与模式守卫（P1 / P3）
//
// ============================ 判据在证明什么 ============================
// P1 我的最爱页「单击就整列开播」：
//   web 真源：ui_script.h 最爱页行是普通列表行，单击只做选中；整列播放是**双击**语义
//   （favhint：双击任意一首，从这首开始顺序播放整个最爱列表）。
//   旧原生 RLPDavoritesViewController.mm:72 同时设了 action（单击）与 doubleAction（双击），
//   两者都指向 onDoubleClick: ⟹ 单击一下就把整个收藏列表建成队列并起播，与 web 的单击选中相悖。
//   判据：NSTableView.action == NULL（单击没有动作）、doubleAction == onDoubleClick:（双击保留）；
//        双击的真实落点 playRowAtIndex: 仍然 /api/queue/set 建整列并从该行起播。
//
// P3 歌单页在单曲循环（mode==2）下整列播成一首：
//   web 真源：ensureSequentialMode —— 整列播放前若 mode==2 先切列表循环(1)，否则第一首播完
//   就一直重复，用户看到的是"点了第 2 首却还在唱第 1 首"。
//   RLPPlaylistsViewController.mm playFromIndex: 直接 /api/sq/play + /api/play，没有这道守卫。
//   判据：先令 GET /api/playmode 回 mode=2，再 playFromIndex:1
//        ⟹ POST 里出现 mode=1 且发生在 /api/play 之前；事后 mode==1。
//        负向：mode==1 时不得多写一次 playmode（不覆盖用户的随机/顺序设置）。
//
// ============================ 铁律②：绝不出声 ============================
// 桩 RLPCoreClient：只记录 GET/POST 与 body，不启动核心、不碰音频设备、不创建可见窗口。
#import <AppKit/AppKit.h>
#import "RLPFavoritesViewController.h"
#import "RLPPlaylistsViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#import "RLPSupport.h"
#import "RLPTrackActions.h"

#include <cstdio>

static int g_pass = 0, g_fail = 0;

static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
#pragma mark - 生产接缝（判据直接调，依赖鼠标事件的入口不参与判据）

@interface RLPFavoritesViewController (PagesFixesAudit)
- (void)reloadData;
- (void)onDoubleClick:(id)sender;
- (void)playRowAtIndex:(NSInteger)row;
@end

@interface RLPPlaylistsViewController (PagesFixesAudit)
- (void)openPlaylist:(NSString *)name;
- (void)playFromIndex:(NSInteger)index;
@end

#pragma mark - 桩客户端（只记录，不发任何请求）

static NSMutableArray<NSDictionary *> *g_gets;
static NSMutableArray<NSDictionary *> *g_posts;
static NSInteger g_mode;    // 桩里的播放模式（GET /api/playmode 的真相）
static BOOL g_favListBackslash = NO;
static BOOL g_addShouldFail = NO;

static NSArray<NSDictionary *> *FavFixture(void) {
    return @[
        @{ @"path": @"/Music/Fav/One.flac", @"title": @"One", @"artist": @"A",
           @"album": @"Fav", @"dur": @180, @"year": @2001 },
        @{ @"path": @"/Music/Fav/Two.flac", @"title": @"Two", @"artist": @"B",
           @"album": @"Fav", @"dur": @200, @"year": @2005 },
        @{ @"path": @"/Music/Fav/Three.flac", @"title": @"Three", @"artist": @"C",
           @"album": @"Fav", @"dur": @220, @"year": @2010 },
    ];
}

/// 第 2 项是 CUE 分轨（cs=10 / ce=20），用来钉住起播参数没有丢。
static NSArray<NSDictionary *> *PlaylistItemsFixture(void) {
    return @[
        @{ @"file": @"/Music/PL/01.flac", @"cs": @(-1), @"ce": @(-1) },
        @{ @"file": @"/Music/PL/02.flac", @"cs": @(10), @"ce": @(20) },
        @{ @"file": @"/Music/PL/03.flac", @"cs": @(-1), @"ce": @(-1) },
    ];
}

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    [g_gets addObject:@{ @"path": path ?: @"" }];
    if ([path hasPrefix:@"/api/fav/list"]) {
        if (g_favListBackslash) {
            done(@{ @"ok": @YES, @"files": @[ @"\\Music\\Fav\\Two.flac" ] });
            return;
        }
        done(@{ @"ok": @YES, @"files": FavFixture() });
        return;
    }
    if ([path hasPrefix:@"/api/playmode"]) { done(@{ @"ok": @YES, @"mode": @(g_mode) }); return; }
    if ([path hasPrefix:@"/api/sq/info"]) {
        done(@{ @"ok": @YES, @"name": @"Night Drive", @"items": PlaylistItemsFixture() });
        return;
    }
    if ([path hasPrefix:@"/api/sq/list"]) { done(@{ @"ok": @YES, @"queues": @[] }); return; }
    // 整列开播（/api/queue/set）之后列队成功；其它 GET 一律失败（不让测试偷偷连真实数据）。
    done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { (void)path; if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    // ⚠️ 顺序：/api/playmode 与 /api/play 同前缀，先判 playmode（与后端路由坑同款）。
    if ([path hasPrefix:@"/api/playmode?mode="]) {
        g_mode = [[path substringFromIndex:@"/api/playmode?mode=".length] integerValue];
        if ([path hasPrefix:@"/api/add"] && g_addShouldFail) {
        if (done) done(@{ @"ok": @NO, @"error": @"mock add failed" });
        return;
    }
    if (done) done(@{ @"ok": @YES });
        return;
    }
    if ([path hasPrefix:@"/api/add"] && g_addShouldFail) {
        if (done) done(@{ @"ok": @NO, @"error": @"mock add failed" });
        return;
    }
    if (done) done(@{ @"ok": @YES });
}
@end
#pragma mark clang diagnostic pop

#pragma mark - 小工具

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
static NSArray<NSDictionary *> *PostsWithPrefix(NSString *prefix) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in g_posts) if ([p[@"path"] hasPrefix:prefix]) [out addObject:p];
    return out;
}
static NSDictionary *LastPostExact(NSString *path) {
    NSDictionary *hit = nil;
    for (NSDictionary *p in g_posts) if ([p[@"path"] isEqualToString:path]) hit = p;
    return hit;
}
static BOOL PostBefore(NSString *firstPath, NSString *secondPath) {
    NSInteger first = -1, second = -1;
    for (NSInteger i = 0; i < (NSInteger)g_posts.count; ++i) {
        NSString *p = g_posts[(NSUInteger)i][@"path"];
        if (first < 0 && [p hasPrefix:firstPath]) first = i;
        if (second < 0 && [p isEqualToString:secondPath]) second = i;
    }
    return first >= 0 && second >= 0 && first < second;
}

#pragma mark - 主流程

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        g_gets = [NSMutableArray array];
        g_posts = [NSMutableArray array];
        g_mode = 0;
        std::printf("=== test_native_pages_fixes（P1 单击不播 / P3 单曲循环守卫 · 离屏 · 不出声）===\n");

        // 同 RLPToast/窗口的既有审计口径：离屏窗口承载页面，不激活、不显示给用户。
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 700)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 700)];
        static NSWindow *sWindow; sWindow = win;   // 不 close：离屏测试不承担 dealloc 顺序

        // ---- P1 我的最爱：单击只选中，不整列开播 ----
        {
            RLPFavoritesViewController *fav = [RLPFavoritesViewController new];
            fav.view.frame = win.contentView.bounds;
            [win.contentView addSubview:fav.view];
            [fav.view layoutSubtreeIfNeeded];
            [fav reloadData];
            Pump(0.05);

            NSTableView *table = [fav valueForKey:@"_tableView"];
            Ck([table isKindOfClass:[NSTableView class]], "P1 找得到收藏表格（判据前提）", @"_tableView 缺失");
            if (table) {
                Ck(table.action == NULL,
                   "P1 单击 action 已删除（单击只选中；web 行单击不整列开播）",
                   [NSString stringWithFormat:@"action=%@（旧码指向 onDoubleClick:）",
                    NSStringFromSelector(table.action)]);
                Ck(table.doubleAction == @selector(onDoubleClick:),
                   "P1 双击 action 保留（web 双击整列顺序播放）",
                   [NSString stringWithFormat:@"doubleAction=%@", NSStringFromSelector(table.doubleAction)]);
                Ck(table.target == fav, "P1 双击 target 仍是收藏页", @"target 不指向页面");

                // 单击路径 = NSTableView.action。action 为 NULL 时没有任何 action 会被派发；
                // 这里仍走一遍真实 sendAction，确认"点了不会建队列"（离屏无法伪造 clickedRow，
                // 所以根因断言是 action==NULL 这一条）。
                [g_posts removeAllObjects];
                if (table.action && table.target) [NSApp sendAction:table.action to:table.target from:table];
                Pump(0.05);
                Ck(PostsWithPrefix(@"/api/queue/set").count == 0,
                   "P1 单击不发 /api/queue/set（队列不变、未起播）",
                   [g_posts componentsJoinedByString:@" | "]);

                // 回归保护：双击的真实落点仍然建整列并从被点行起播（不要连双击一起删）。
                [g_posts removeAllObjects];
                [fav playRowAtIndex:1];
                Pump(0.1);
                NSDictionary *setPost = LastPostExact(@"/api/queue/set");
                Ck(setPost != nil, "P1 双击路径仍建整列队列（/api/queue/set）",
                   [g_posts componentsJoinedByString:@" | "]);
                if (setPost) {
                    NSString *decoded = [setPost[@"body"] stringByRemovingPercentEncoding] ?: setPost[@"body"];
                    BOOL allThree = YES;
                    for (NSDictionary *t in FavFixture())
                        if (![decoded containsString:t[@"path"]]) allThree = NO;
                    Ck(allThree, "P1 队列 = 整个收藏列表（3 首都进 files）", decoded);
                }
                NSDictionary *playPost = LastPostExact(@"/api/play");
                Ck(playPost != nil, "P1 双击后从被点行起播（/api/play）",
                   [g_posts componentsJoinedByString:@" | "]);
                if (playPost) {
                    NSString *decoded = [playPost[@"body"] stringByRemovingPercentEncoding] ?: playPost[@"body"];
                    Ck([decoded containsString:@"/Music/Fav/Two.flac"],
                       "P1 起播路径 = 第 2 行（playRowAtIndex:1）", decoded);
                }
            }
        }

        // ---- P3 歌单页：单曲循环(2) 下起播前先切列表循环(1) ----
        {
            RLPPlaylistsViewController *pl = [RLPPlaylistsViewController new];
            pl.view.frame = NSMakeRect(0, 0, 900, 640);
            [pl.view layoutSubtreeIfNeeded];
            [win.contentView addSubview:pl.view];
            [pl openPlaylist:@"Night Drive"];
            Pump(0.05);
            Ck([pl valueForKey:@"selectedName"] != nil &&
               [[pl valueForKey:@"selectedName"] isEqualToString:@"Night Drive"],
               "P3 歌单页选中「Night Drive」（判据前提）", @"selectedName 不对");
            Ck([[pl valueForKey:@"items"] count] == 3, "P3 歌单 3 首已载入（判据前提）",
               [NSString stringWithFormat:@"items=%lu", (unsigned long)[[pl valueForKey:@"items"] count]]);

            // 正向：先 mode=2，再点第 2 首
            g_mode = 2;
            [g_posts removeAllObjects];
            [pl playFromIndex:1];
            Pump(0.1);
            Ck(g_mode == 1,
               "P3 单曲循环(2) 下起播后播放模式已切到列表循环(1)，不再卡在同一首",
               [NSString stringWithFormat:@"mode=%ld", (long)g_mode]);
            Ck(PostsWithPrefix(@"/api/playmode?mode=1").count > 0,
               "P3 发出了 /api/playmode?mode=1（ensureSequentialMode 守卫）",
               [g_posts componentsJoinedByString:@" | "]);
            Ck(PostBefore(@"/api/playmode?mode=1", @"/api/play"),
               "P3 mode=1 在 /api/play 之前（先守卫后起播）",
               [g_posts componentsJoinedByString:@" | "]);

            // 起播本身仍然带 CUE 区间（P3 不碰原有契约）
            NSDictionary *play = LastPostExact(@"/api/play");
            Ck(play != nil, "P3 起播发出 /api/play", [g_posts componentsJoinedByString:@" | "]);
            if (play) {
                NSString *decoded = [play[@"body"] stringByRemovingPercentEncoding] ?: play[@"body"];
                Ck([decoded containsString:@"/Music/PL/02.flac"] &&
                   [decoded containsString:@"cs=10.000"] &&
                   [decoded containsString:@"ce=20.000"],
                   "P3 CUE 分轨起播带 file/cs/ce（不丢区间）", decoded);
            }
            NSDictionary *sqPlay = [PostsWithPrefix(@"/api/sq/play") firstObject];
            Ck(sqPlay != nil && [sqPlay[@"path"] containsString:@"i=1"],
               "P3 起播前 /api/sq/play 用 i=1 换队列",
               [g_posts componentsJoinedByString:@" | "]);

            // 负向：已经是列表循环(1) 时不得再写一次 playmode（不覆盖用户的随机/顺序设置）
            g_mode = 1;
            [g_posts removeAllObjects];
            [pl playFromIndex:1];
            Pump(0.05);
            Ck(PostsWithPrefix(@"/api/playmode").count == 0,
               "P3 mode==1 时不额外下发 playmode（只在 mode==2 切档）",
               [g_posts componentsJoinedByString:@" | "]);
        }

        // ---- P4 右键收藏路径规范化(\ vs /) + 跨页同步 + 入队真实回执 ----
        {
            RLPFavoritesViewController *fav2 = [RLPFavoritesViewController new];
            fav2.view.frame = NSMakeRect(0, 0, 900, 640);
            [fav2.view layoutSubtreeIfNeeded];
            [fav2 reloadData];
            Pump(0.05);

            g_favListBackslash = YES;
            [g_gets removeAllObjects];
            [g_posts removeAllObjects];
            NSMenuItem *favItem = [[NSMenuItem alloc] initWithTitle:@"收藏" action:nil keyEquivalent:@""];
            favItem.tag = RLPTrackActionFavorite;
            favItem.representedObject = @"/Music/Fav/Two.flac";
            RLPHandleTrackAction(favItem, fav2.view);
            Pump(0.1);
            NSDictionary *favPost = [PostsWithPrefix(@"/api/fav?") firstObject];
            Ck(favPost != nil && [favPost[@"path"] containsString:@"on=0"],
               "P4 /api/fav/list 返回反斜杠路径时右键收藏仍识别为已收藏并发 on=0",
               favPost[@"path"] ?: @"nil");

            // fav2 应通过 RLPFavoritesChangedNotification 自动再拉一次 /api/fav/list?meta=1
            BOOL favReloaded = NO;
            for (NSDictionary *g in g_gets) {
                if ([g[@"path"] isEqualToString:@"/api/fav/list?meta=1"]) favReloaded = YES;
            }
            Ck(favReloaded, "P4 右键收藏成功后最爱页自动收到跨页通知并刷新",
               [g_gets componentsJoinedByString:@" | "]);
            g_favListBackslash = NO;

            // 入队：成功时发 RLPQueueChangedNotification，失败时不发
            __block NSInteger qNotifs = 0;
            id obs = [[NSNotificationCenter defaultCenter] addObserverForName:RLPQueueChangedNotification
                                                                       object:nil
                                                                        queue:nil
                                                                   usingBlock:^(NSNotification * _Nonnull note) {
                (void)note;
                ++qNotifs;
            }];
            g_addShouldFail = YES;
            RLPEnqueuePath(@"/Music/Fav/One.flac");
            Pump(0.05);
            Ck(qNotifs == 0, "P4 /api/add 失败时不发 RLPQueueChangedNotification",
               [NSString stringWithFormat:@"qNotifs=%ld", (long)qNotifs]);
            g_addShouldFail = NO;
            RLPEnqueuePath(@"/Music/Fav/One.flac");
            Pump(0.05);
            Ck(qNotifs == 1, "P4 /api/add 成功后发 RLPQueueChangedNotification",
               [NSString stringWithFormat:@"qNotifs=%ld", (long)qNotifs]);
            [[NSNotificationCenter defaultCenter] removeObserver:obs];
        }

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
