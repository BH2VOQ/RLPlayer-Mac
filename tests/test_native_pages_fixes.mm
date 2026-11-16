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
#import "RLPKnowledgeView.mm"
#import "RLPStreamingViewController.mm"
#import "RLPAlbumDetailViewController.mm"
#import "RLPArtistDetailViewController.mm"
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

@interface RLPAlbumDetailViewController (PagesFixesAudit)
- (void)reloadData;
- (void)onRowDoubleClick:(id)sender;
- (void)onRowAdd:(NSButton *)sender;
@end

@interface RLPArtistDetailViewController (PagesFixesAudit)
- (void)activate;
@end

@interface RLPTrackActionTableView (PagesFixesAudit)
- (nullable NSMenu *)rlp_menuForRow:(NSInteger)row;
@end

#pragma mark - 桩客户端（只记录，不发任何请求）

static NSMutableArray<NSDictionary *> *g_gets;
static NSMutableArray<NSDictionary *> *g_posts;
static NSMutableArray<NSString *> *g_getDatas;
static NSInteger g_mode;    // 桩里的播放模式（GET /api/playmode 的真相）
static BOOL g_favListBackslash = NO;
static BOOL g_addShouldFail = NO;
static NSInteger g_knowPollCount = 0;
static BOOL g_holdArtistB = NO;
static RLPJSONCompletion g_heldArtistBKnowDone = nil;
static RLPJSONCompletion g_heldArtistBSumDone = nil;
static RLPJSONCompletion g_heldArtistASumDone = nil;
static BOOL g_browseShouldFail = NO;
static BOOL g_srcConfigShouldFail = NO;
static NSString *g_activeServerId = @"srv2";
static BOOL g_artistImageShouldSucceed = NO;
static BOOL g_coverShouldFail = NO;

static NSData *TestPngData(void) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1
                   bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:4 bitsPerPixel:32];
    uint8_t *px = rep.bitmapData;
    if (px) { px[0] = 255; px[1] = 0; px[2] = 0; px[3] = 255; }
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

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
    if ([path hasPrefix:@"/api/entity/knowledge"]) {
        if ([path containsString:@"name=ArtistA"]) {
            if (g_knowPollCount++ == 0) {
                done(@{ @"ok": @YES, @"pending": @YES });
            } else {
                done(@{
                    @"ok": @YES,
                    @"pending": @NO,
                    @"entity": @{ @"id": @"p:ArtistA", @"kind": @"person", @"name": @"ArtistA" },
                    @"materials": @[
                        @{ @"source": @"musicbrainz", @"kind": @"biography", @"title": @"生平", @"text": @"ArtistA bio text" },
                        @{ @"source": @"discogs", @"kind": @"genre", @"title": @"风格", @"text": @"Classical" }
                    ],
                    @"errors": @[]
                });
            }
            return;
        }
        if ([path containsString:@"name=ArtistB"] && g_holdArtistB) {
            g_heldArtistBKnowDone = [done copy];
            return;
        }
        if ([path containsString:@"name=ArtistC"]) {
            done(@{
                @"ok": @YES,
                @"pending": @NO,
                @"entity": @{ @"id": @"p:ArtistC", @"kind": @"person", @"name": @"ArtistC" },
                @"materials": @[ @{ @"source": @"wiki", @"kind": @"biography", @"title": @"生平", @"text": @"ArtistC bio text" } ],
                @"errors": @[]
            });
            return;
        }
    }
    if ([path hasPrefix:@"/api/entity/summary"]) {
        if ([path containsString:@"name=ArtistA"]) {
            g_heldArtistASumDone = [done copy];
            return;
        }
        if ([path containsString:@"name=ArtistB"] && g_holdArtistB) {
            g_heldArtistBSumDone = [done copy];
            return;
        }
        if ([path containsString:@"name=ArtistC"]) {
            done(@{ @"ok": @YES, @"summary": @"ArtistC summary text" });
            return;
        }
    }
    if ([path isEqualToString:@"/api/src/config"]) {
        done(@{
            @"ok": @YES,
            @"configured": @YES,
            @"active": g_activeServerId ?: @"srv2",
            @"servers": @[
                @{ @"id": @"srv1", @"name": @"Server One", @"active": @([g_activeServerId isEqualToString:@"srv1"]) },
                @{ @"id": @"srv2", @"name": @"Server Two", @"active": @([g_activeServerId isEqualToString:@"srv2"]) }
            ]
        });
        return;
    }
    if ([path hasPrefix:@"/api/src/browse"]) {
        if (g_browseShouldFail) {
            done(@{ @"ok": @NO, @"error": @"server unreachable" });
            return;
        }
        if ([path isEqualToString:@"/api/src/browse?id="]) {
            done(@{ @"ok": @YES, @"items": @[ @{ @"id": @"dir/a b&c", @"t": @"Folder ABC", @"dir": @YES } ] });
            return;
        }
        if ([path isEqualToString:@"/api/src/browse?id=dir%2Fa%20b%26c"]) {
            done(@{ @"ok": @YES, @"items": @[ @{ @"id": @"trk1", @"t": @"Track 1", @"dir": @NO } ] });
            return;
        }
        done(@{ @"ok": @NO, @"error": [NSString stringWithFormat:@"unexpected browse path: %@", path] });
        return;
    }
    if ([path hasPrefix:@"/api/lib/album?"]) {
        done(@{
            @"ok": @YES,
            @"k": @"alb-cue",
            @"name": @"Cue Album",
            @"artist": @"CueArtist",
            @"year": @2022,
            @"dur": @600,
            @"cv": @YES,
            @"tracks": @[
                @{ @"i": @0, @"n": @1, @"title": @"Normal Track", @"artist": @"CueArtist",
                   @"path": @"/Music/Normal/01.flac", @"dur": @180, @"cs": @(-1), @"ce": @(-1) },
                @{ @"i": @1, @"n": @2, @"title": @"Cue Track 2", @"artist": @"CueArtist",
                   @"path": @"/Music/Cue/Album.flac", @"dur": @184.75, @"cs": @(125.5), @"ce": @(310.25) },
                @{ @"i": @2, @"n": @3, @"title": @"Cue Track 3", @"artist": @"CueArtist",
                   @"path": @"/Music/Cue/Album.flac", @"dur": @235.25, @"cs": @(310.25), @"ce": @(-1) }
            ]
        });
        return;
    }
    if ([path isEqualToString:@"/api/lib/albums"]) {
        done(@{
            @"ok": @YES,
            @"albums": @[
                @{ @"k": @"alb-cue-1", @"name": @"No Cover First", @"artist": @"CueArtist", @"year": @2020, @"n": @5, @"dur": @900, @"cv": @NO },
                @{ @"k": @"alb-cue-2", @"name": @"With Cover Second", @"artist": @"CueArtist", @"year": @2022, @"n": @8, @"dur": @1800, @"cv": @YES },
                @{ @"k": @"alb-nocov", @"name": @"Only No Cover", @"artist": @"NoCoverArtist", @"year": @2021, @"n": @4, @"dur": @700, @"cv": @NO }
            ]
        });
        return;
    }
    // 整列开播（/api/queue/set）之后列队成功；其它 GET 一律失败（不让测试偷偷连真实数据）。
    done(@{ @"ok": @NO });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done {
    [g_getDatas addObject:path ?: @""];
    if (!done) return;
    if ([path hasPrefix:@"/api/artist/image"]) {
        done(g_artistImageShouldSucceed ? TestPngData() : nil);
        return;
    }
    if ([path hasPrefix:@"/api/lib/cover"]) {
        done(g_coverShouldFail ? nil : TestPngData());
        return;
    }
    done(nil);
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [g_posts addObject:@{ @"path": path ?: @"", @"body": body ?: @"" }];
    // ⚠️ 顺序：/api/playmode 与 /api/play 同前缀，先判 playmode（与后端路由坑同款）。
    if ([path hasPrefix:@"/api/playmode?mode="]) {
        g_mode = [[path substringFromIndex:@"/api/playmode?mode=".length] integerValue];
        if (done) done(@{ @"ok": @YES });
        return;
    }
    if ([path isEqualToString:@"/api/src/config"]) {
        if (g_srcConfigShouldFail) {
            if (done) done(@{ @"ok": @NO, @"error": @"invalid server" });
            return;
        }
        if ([body containsString:@"id=srv1"]) g_activeServerId = @"srv1";
        else if ([body containsString:@"id=srv2"]) g_activeServerId = @"srv2";
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
        g_getDatas = [NSMutableArray array];
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

        // ---- 缺口1 艺术家知识卡：独立序列号 + 按 materials 渲染 + 丢弃旧实体回包 ----
        {
            RLPKnowledgeView *kv = [[RLPKnowledgeView alloc] initWithFrame:NSMakeRect(0, 0, 520, 400)];
            [win.contentView addSubview:kv];
            g_knowPollCount = 0;
            g_heldArtistASumDone = nil;
            [kv loadKind:@"person" name:@"ArtistA" artist:nil];
            // 等待 knowledge 的 pending poll (0.4s) 触发并完成
            Pump(0.55);
            // 此时 knowledge 已经历一次 poll（seq 自增）；summary 回包到达时不得被丢弃
            if (g_heldArtistASumDone) g_heldArtistASumDone(@{ @"ok": @YES, @"summary": @"ArtistA summary text" });
            Pump(0.05);

            Ck(kv.fieldStack.arrangedSubviews.count == 2,
               "缺口1 knowledge 按 materials 渲染出 2 行资料",
               [NSString stringWithFormat:@"rows=%lu status=%@",
                (unsigned long)kv.fieldStack.arrangedSubviews.count, kv.status.stringValue]);
            Ck([kv.status.stringValue containsString:@"2"],
               "缺口1 knowledge 状态显示 2 项已确认资料",
               kv.status.stringValue ?: @"nil");
            Ck([kv.summaryView.string isEqualToString:@"ArtistA summary text"],
               "缺口1 summary 不因 knowledge 轮询自增 seq 而被丢弃",
               kv.summaryView.string ?: @"nil");

            // 切实体时旧实体(ArtistB)的在途 knowledge 与 summary 回包必须被丢弃
            g_holdArtistB = YES;
            g_heldArtistBKnowDone = nil;
            g_heldArtistBSumDone = nil;
            [kv loadKind:@"person" name:@"ArtistB" artist:nil];
            Pump(0.02);
            g_holdArtistB = NO;
            [kv loadKind:@"person" name:@"ArtistC" artist:nil];
            Pump(0.05);
            if (g_heldArtistBKnowDone) {
                g_heldArtistBKnowDone(@{
                    @"ok": @YES,
                    @"materials": @[
                        @{ @"title": @"Old1", @"text": @"ArtistB stale 1" },
                        @{ @"title": @"Old2", @"text": @"ArtistB stale 2" },
                        @{ @"title": @"Old3", @"text": @"ArtistB stale 3" }
                    ]
                });
            }
            if (g_heldArtistBSumDone) {
                g_heldArtistBSumDone(@{ @"ok": @YES, @"summary": @"ArtistB stale summary" });
            }
            Pump(0.05);
            Ck(kv.fieldStack.arrangedSubviews.count == 1,
               "缺口1 切实体后旧实体 knowledge 回包被丢弃（保留 ArtistC 的 1 行）",
               [NSString stringWithFormat:@"rows=%lu", (unsigned long)kv.fieldStack.arrangedSubviews.count]);
            Ck([kv.summaryView.string isEqualToString:@"ArtistC summary text"],
               "缺口1 切实体后旧实体 summary 回包被丢弃（保留 ArtistC summary）",
               kv.summaryView.string ?: @"nil");
        }

        // ---- 缺口3 流媒体页：active 选中、目录 id 编码、切服清面包屑与校验、!ok 清旧项并显错误空态 ----
        {
            g_activeServerId = @"srv2";
            g_browseShouldFail = NO;
            g_srcConfigShouldFail = NO;
            RLPStreamingViewController *st = [[RLPStreamingViewController alloc] init];
            st.view.frame = NSMakeRect(0, 0, 900, 640);
            [win.contentView addSubview:st.view];
            [st.view layoutSubtreeIfNeeded];
            [st reloadData];
            Pump(0.05);

            NSPopUpButton *picker = [st valueForKey:@"_serverPicker"];
            NSButton *backBtn = [st valueForKey:@"_backButton"];
            NSMutableArray *crumb = [st valueForKey:@"_breadcrumbStack"];
            Ck(picker && picker.indexOfSelectedItem == 1 && [picker.titleOfSelectedItem isEqualToString:@"Server Two"],
               "缺口3 reloadData 按 active 选中服务器 (srv2 / index 1)",
               [NSString stringWithFormat:@"idx=%ld title=%@", (long)picker.indexOfSelectedItem, picker.titleOfSelectedItem]);

            // 打开含特殊字符的目录 id：必须 URL 编码
            [g_gets removeAllObjects];
            [st openItemId:@"dir/a b&c" isDir:YES];
            Pump(0.05);
            BOOL hasEncodedBrowse = NO;
            for (NSDictionary *g in g_gets) {
                if ([g[@"path"] isEqualToString:@"/api/src/browse?id=dir%2Fa%20b%26c"]) hasEncodedBrowse = YES;
            }
            Ck(hasEncodedBrowse,
               "缺口3 browseId 对目录 id 做 URL 编码",
               [g_gets componentsJoinedByString:@" | "]);
            Ck(crumb.count == 1 && backBtn.enabled,
               "缺口3 进入子目录后面包屑入栈且返回按钮可用",
               [NSString stringWithFormat:@"crumb=%lu back=%d", (unsigned long)crumb.count, (int)backBtn.enabled]);

            // 切换服务器失败：不得假装成功，且应回读恢复原 active 服务器
            g_srcConfigShouldFail = YES;
            [picker selectItemAtIndex:0];
            [st serverChanged:picker];
            Pump(0.05);
            Ck(picker.indexOfSelectedItem == 1,
               "缺口3 serverChanged 失败时不假装成功，回读恢复 active 服务器 (srv2)",
               [NSString stringWithFormat:@"idx=%ld", (long)picker.indexOfSelectedItem]);

            // 切换服务器成功：必须清面包屑并禁用返回按钮
            g_srcConfigShouldFail = NO;
            [picker selectItemAtIndex:0];
            [st serverChanged:picker];
            Pump(0.05);
            Ck(crumb.count == 0 && !backBtn.enabled,
               "缺口3 serverChanged 成功后清空面包屑并禁用返回按钮",
               [NSString stringWithFormat:@"crumb=%lu back=%d", (unsigned long)crumb.count, (int)backBtn.enabled]);

            // browseId 返回 !ok：必须清空旧 _items 并显示错误空态
            g_browseShouldFail = YES;
            [st browseId:@""];
            Pump(0.05);
            NSArray *itemsNow = [st valueForKey:@"_items"];
            Ck(itemsNow.count == 0 && [st emptyStateVisible],
               "缺口3 browseId !ok 时清空旧 _items 并显示错误空态",
               [NSString stringWithFormat:@"items=%lu emptyVisible=%d", (unsigned long)itemsNow.count, (int)[st emptyStateVisible]]);
        }

        // ---- 审计缺口1：专辑详情 CUE 区间播放、入队、右键菜单 ----
        {
            RLPAlbumDetailViewController *alb = [[RLPAlbumDetailViewController alloc] initWithAlbumKey:@"alb-cue"];
            alb.view.frame = win.contentView.bounds;
            [win.contentView addSubview:alb.view];
            [alb.view layoutSubtreeIfNeeded];
            [alb reloadData];
            Pump(0.05);

            NSTableView *tv = [alb valueForKey:@"_table"];
            Ck(tv != nil && tv.numberOfRows == 3,
               "审计缺口1 专辑 3 首曲目已载入（含非 CUE 与 CUE 分轨）",
               [NSString stringWithFormat:@"rows=%ld", (long)tv.numberOfRows]);

            // 1) 双击 CUE 行（row 1）：走 /api/lib/play，带 k、i=1、cue_start、cue_end
            [g_posts removeAllObjects];
            [tv selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
            [alb onRowDoubleClick:nil];
            Pump(0.05);
            NSDictionary *libPlayCue = LastPostExact(@"/api/lib/play");
            NSString *cuePlayBody = [libPlayCue[@"body"] stringByRemovingPercentEncoding] ?: libPlayCue[@"body"] ?: @"";
            Ck(libPlayCue != nil &&
               [cuePlayBody containsString:@"k=alb-cue"] &&
               [cuePlayBody containsString:@"i=1"] &&
               [cuePlayBody containsString:@"cue_start=125.5"] &&
               [cuePlayBody containsString:@"cue_end=310.25"],
               "审计缺口1 双击 CUE 行走 /api/lib/play 并带 k/i/cue_start/cue_end",
               cuePlayBody);

            // 2) 双击非 CUE 行（row 0）：走 /api/lib/play，带 k、i=0，不带 cue_start/cue_end
            [g_posts removeAllObjects];
            [tv selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            [alb onRowDoubleClick:nil];
            Pump(0.05);
            NSDictionary *libPlayNormal = LastPostExact(@"/api/lib/play");
            NSString *normalPlayBody = [libPlayNormal[@"body"] stringByRemovingPercentEncoding] ?: libPlayNormal[@"body"] ?: @"";
            Ck(libPlayNormal != nil &&
               [normalPlayBody containsString:@"k=alb-cue"] &&
               [normalPlayBody containsString:@"i=0"] &&
               ![normalPlayBody containsString:@"cue_start"] &&
               ![normalPlayBody containsString:@"cue_end"],
               "审计缺口1 双击非 CUE 行走 /api/lib/play(k,i) 且不带 cue_start/cue_end",
               normalPlayBody);

            // 3) 行内「+」入队 CUE 行（row 1）：走 /api/add 并带 cue_start/cue_end
            [g_posts removeAllObjects];
            NSButton *addBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
            addBtn.tag = 1;
            [alb onRowAdd:addBtn];
            Pump(0.05);
            NSDictionary *addCue = LastPostExact(@"/api/add");
            NSString *addCueBody = [addCue[@"body"] stringByRemovingPercentEncoding] ?: addCue[@"body"] ?: @"";
            Ck(addCue != nil &&
               [addCueBody containsString:@"/Music/Cue/Album.flac"] &&
               [addCueBody containsString:@"cue_start=125.5"] &&
               [addCueBody containsString:@"cue_end=310.25"],
               "审计缺口1 + 入队 CUE 行带 file/cue_start/cue_end",
               addCueBody);

            // 4) 行内「+」入队非 CUE 行（row 0）：走 /api/add 且不带 cue_start/cue_end
            [g_posts removeAllObjects];
            addBtn.tag = 0;
            [alb onRowAdd:addBtn];
            Pump(0.05);
            NSDictionary *addNormal = LastPostExact(@"/api/add");
            NSString *addNormalBody = [addNormal[@"body"] stringByRemovingPercentEncoding] ?: addNormal[@"body"] ?: @"";
            Ck(addNormal != nil &&
               [addNormalBody containsString:@"/Music/Normal/01.flac"] &&
               ![addNormalBody containsString:@"cue_start"] &&
               ![addNormalBody containsString:@"cue_end"],
               "审计缺口1 + 入队非 CUE 行只带 file 不带 cue 参数",
               addNormalBody);

            // 5) 右键菜单 CUE 行（row 1）：播放与加入队列均携带 cue_start/cue_end
            RLPTrackActionTableView *atv = (RLPTrackActionTableView *)tv;
            NSMenu *cueMenu = [atv respondsToSelector:@selector(rlp_menuForRow:)] ? [atv rlp_menuForRow:1] : nil;
            NSMenuItem *playItem = [cueMenu itemWithTag:RLPTrackActionPlay];
            NSMenuItem *enqItem = [cueMenu itemWithTag:RLPTrackActionEnqueue];
            [g_posts removeAllObjects];
            if (playItem) RLPHandleTrackAction(playItem, alb.view);
            if (enqItem) RLPHandleTrackAction(enqItem, alb.view);
            Pump(0.05);
            NSDictionary *menuPlay = LastPostExact(@"/api/play");
            NSDictionary *menuEnq = LastPostExact(@"/api/add");
            NSString *menuPlayBody = [menuPlay[@"body"] stringByRemovingPercentEncoding] ?: menuPlay[@"body"] ?: @"";
            NSString *menuEnqBody = [menuEnq[@"body"] stringByRemovingPercentEncoding] ?: menuEnq[@"body"] ?: @"";
            Ck(cueMenu != nil &&
               [menuPlayBody containsString:@"cue_start=125.5"] &&
               [menuPlayBody containsString:@"cue_end=310.25"] &&
               [menuEnqBody containsString:@"cue_start=125.5"] &&
               [menuEnqBody containsString:@"cue_end=310.25"],
               "审计缺口1 右键菜单 CUE 行播放/入队均带 cue_start/cue_end",
               [NSString stringWithFormat:@"play=%@ | add=%@", menuPlayBody, menuEnqBody]);

            // 6) 右键菜单非 CUE 行（row 0）：播放/入队保持不带 cue 参数
            NSMenu *normalMenu = [atv respondsToSelector:@selector(rlp_menuForRow:)] ? [atv rlp_menuForRow:0] : nil;
            NSMenuItem *nPlayItem = [normalMenu itemWithTag:RLPTrackActionPlay];
            NSMenuItem *nEnqItem = [normalMenu itemWithTag:RLPTrackActionEnqueue];
            [g_posts removeAllObjects];
            if (nPlayItem) RLPHandleTrackAction(nPlayItem, alb.view);
            if (nEnqItem) RLPHandleTrackAction(nEnqItem, alb.view);
            Pump(0.05);
            NSDictionary *nMenuPlay = LastPostExact(@"/api/play");
            NSDictionary *nMenuEnq = LastPostExact(@"/api/add");
            NSString *nMenuPlayBody = [nMenuPlay[@"body"] stringByRemovingPercentEncoding] ?: nMenuPlay[@"body"] ?: @"";
            NSString *nMenuEnqBody = [nMenuEnq[@"body"] stringByRemovingPercentEncoding] ?: nMenuEnq[@"body"] ?: @"";
            Ck(normalMenu != nil &&
               [nMenuPlayBody containsString:@"/Music/Normal/01.flac"] &&
               ![nMenuPlayBody containsString:@"cue_start"] &&
               [nMenuEnqBody containsString:@"/Music/Normal/01.flac"] &&
               ![nMenuEnqBody containsString:@"cue_start"],
               "审计缺口1 右键菜单非 CUE 行不带 cue 参数",
               [NSString stringWithFormat:@"play=%@ | add=%@", nMenuPlayBody, nMenuEnqBody]);
        }

        // ---- 审计缺口2：艺术家详情头像三级回退 + 单击进专辑 ----
        {
            // 1) /api/artist/image 404 → 回退 /api/lib/cover?k=<有封面的专辑>
            [g_getDatas removeAllObjects];
            g_artistImageShouldSucceed = NO;
            g_coverShouldFail = NO;
            RLPArtistDetailViewController *art = [[RLPArtistDetailViewController alloc] initWithArtistName:@"CueArtist"];
            art.view.frame = win.contentView.bounds;
            [win.contentView addSubview:art.view];
            [art.view layoutSubtreeIfNeeded];
            [art activate];
            Pump(0.05);

            NSCollectionView *col = [art valueForKey:@"_collection"];
            NSClickGestureRecognizer *clickGR = nil;
            for (NSGestureRecognizer *gr in col.gestureRecognizers) {
                if ([gr isKindOfClass:[NSClickGestureRecognizer class]] &&
                    gr.action == @selector(onDoubleClick:)) {
                    clickGR = (NSClickGestureRecognizer *)gr;
                    break;
                }
            }
            Ck(clickGR != nil && clickGR.numberOfClicksRequired == 1,
               "审计缺口2 艺术家详情专辑网格改为单击进入（numberOfClicksRequired == 1）",
               [NSString stringWithFormat:@"clicks=%ld", (long)(clickGR ? clickGR.numberOfClicksRequired : -1)]);

            NSImageView *avatarImg = [art valueForKey:@"_avatarImage"];
            NSTextField *initialLbl = [art valueForKey:@"_initialLabel"];
            BOOL askedArtistImg = NO, askedCoverFallback = NO;
            for (NSString *u in g_getDatas) {
                if ([u isEqualToString:@"/api/artist/image?who=CueArtist"]) askedArtistImg = YES;
                if ([u isEqualToString:@"/api/lib/cover?k=alb-cue-2"]) askedCoverFallback = YES;
            }
            Ck(askedArtistImg && askedCoverFallback &&
               avatarImg.image != nil && !avatarImg.hidden && initialLbl.hidden,
               "审计缺口2 头像 404 时回退到有封面专辑 /api/lib/cover?k=alb-cue-2 并隐藏首字母",
               [NSString stringWithFormat:@"gets=%@ img=%d hidden=%d initHidden=%d",
                [g_getDatas componentsJoinedByString:@","],
                avatarImg.image != nil, (int)avatarImg.hidden, (int)initialLbl.hidden]);

            // 2) 两层都失败 → 露出首字母
            [g_getDatas removeAllObjects];
            g_artistImageShouldSucceed = NO;
            g_coverShouldFail = YES;
            [art activate];
            Pump(0.05);
            Ck(avatarImg.image == nil && avatarImg.hidden && !initialLbl.hidden,
               "审计缺口2 头像与封面均失败时退回首字母",
               [NSString stringWithFormat:@"img=%d hidden=%d initHidden=%d",
                avatarImg.image != nil, (int)avatarImg.hidden, (int)initialLbl.hidden]);

            // 3) /api/artist/image 成功 → 直接显示真头像，不再请求专辑封面
            [g_getDatas removeAllObjects];
            g_artistImageShouldSucceed = YES;
            g_coverShouldFail = NO;
            [art activate];
            Pump(0.05);
            BOOL askedCoverWhenAvatarOk = NO;
            for (NSString *u in g_getDatas) {
                if ([u hasPrefix:@"/api/lib/cover"]) askedCoverWhenAvatarOk = YES;
            }
            Ck(!askedCoverWhenAvatarOk && avatarImg.image != nil && !avatarImg.hidden && initialLbl.hidden,
               "审计缺口2 真头像成功时直接显示，不触发封面兜底请求",
               [g_getDatas componentsJoinedByString:@","]);
        }

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
