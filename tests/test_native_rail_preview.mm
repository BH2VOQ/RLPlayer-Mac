// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_rail_preview.mm — 正在播放页「AI 整理」右栏三卡的内容级判据
//
// ============================ 这条判据在证明什么 ============================
// 用户诉求：原生右栏不能再是「本地曲目事实 + 点开查看」，必须像 web `npRailPreview`
// 一样显示每个实体的**精简已整理资料**（歌曲/专辑/艺术家），点击卡片要打开
// **对应实体类型**的知识浮层（旧码 onRailCard 读从未赋值的 b.tag ⟹ 专辑/艺术家都开成 track）。
//
// 数据链（与 web 同源，全部来自 src/net/ui_script.h）：
//   /api/meta（summaryEnabled / summaryAvailable / summaryCached / summaryCacheOk / hasLlmKey）
//     → 只有开关开且有可用性才允许请求（关时零请求，只留本地事实兜底）
//   /api/entity/summary?kind=track|release|person&name=…&artist=…&lang=zh
//     （track 额外 album/file/genre，顺序与 web npSummUrl 逐字一致）
//   pending 按 retryAfterMs（150..2000ms）轮询，120s 预算；世代号 + 实体指纹丢弃过期响应
//   /api/lib/albums?q= + /api/lib/album?k= → release 卡的「年份 · N 首 · 总时长」
//
// 红→绿纪律：本文件先对未修改的生产码跑（旧码根本没有 summary 请求、p1=标题、
// p2=流派、status=点开查看、kind 恒为 track）⟹ 必须红；改完再跑必须绿。
// 证据：evidence/native-rail-preview-red-20261114.log、native-rail-preview-green-20261114.log
//
// ============================ 铁律②：绝不出声 ============================
// 不启动核心、不碰音频设备、不打开任何可见窗口：RLPCoreClient 用桩（只记录 URL，
// 按夹具回 JSON）；知识浮层用 RLPKnowledgeView 子类记录 loadKind，不联网。
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPKnowledgeView.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cstdio>

static int g_fail = 0, g_pass = 0;

static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) { std::printf("  [PASS] %s\n", what); ++g_pass; }
    else { std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); ++g_fail; }
}
static void EqStr(NSString *got, NSString *want, const char *what) {
    Ck([got isEqualToString:want], what,
       [NSString stringWithFormat:@"got=「%@」 want=「%@」", got ?: @"", want ?: @""]);
}
static void HasStr(NSString *got, NSString *needle, const char *what) {
    Ck([got containsString:needle], what,
       [NSString stringWithFormat:@"got=「%@」 缺少「%@」", got ?: @"", needle ?: @""]);
}
static void NotHasStr(NSString *got, NSString *needle, const char *what) {
    Ck(![got containsString:needle], what,
       [NSString stringWithFormat:@"got=「%@」 不应含「%@」", got ?: @"", needle ?: @""]);
}

#pragma mark - 桩客户端（不发任何真实请求）

static NSMutableArray<NSString *> *g_urls = nil;
static NSDictionary *g_meta = nil;
static NSDictionary *g_albumsList = nil;
static NSDictionary *g_albumDetail = nil;
static NSMutableDictionary<NSString *, NSMutableArray *> *g_summaryQueues = nil;

/// 每条 summary 队列里：>=2 条时先弹第 1 条（用来造 pending），否则重复返回最后一条。
static id SummaryResponse(NSString *path) {
    NSURLComponents *c = [NSURLComponents componentsWithString:
        [@"http://localhost" stringByAppendingString:path]];
    NSString *kind = @"", *name = @"";
    for (NSURLQueryItem *it in c.queryItems) {
        if ([it.name isEqualToString:@"kind"]) kind = it.value ?: @"";
        if ([it.name isEqualToString:@"name"]) name = it.value ?: @"";
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@", kind, name];
    NSMutableArray *q = g_summaryQueues[key];
    if (q.count >= 2) {
        id first = q[0];
        [q removeObjectAtIndex:0];
        return first;
    }
    return q.lastObject ?: @{ @"ok": @NO, @"error": @"no fixture" };
}

/// /api/entity/versions 的夹具队列：key = `work|作品名|作曲家`（与 native 的实体指纹同口径）。
static NSMutableDictionary<NSString *, id> *g_versionsFixtures = nil;
static id VersionsResponse(NSString *path) {
    NSURLComponents *c = [NSURLComponents componentsWithString:
        [@"http://localhost" stringByAppendingString:path]];
    NSString *name = @"", *composer = @"";
    for (NSURLQueryItem *it in c.queryItems) {
        if ([it.name isEqualToString:@"name"]) name = it.value ?: @"";
        if ([it.name isEqualToString:@"composer"]) composer = it.value ?: @"";
    }
    NSString *key = [NSString stringWithFormat:@"work|%@|%@", name, composer];
    id fx = g_versionsFixtures[key];
    return fx ?: @{ @"ok": @NO, @"error": @"no fixture" };
}

static id ResponseForPath(NSString *path) {
    if ([path hasPrefix:@"/api/meta"]) return g_meta ?: @{ @"ok": @NO };
    if ([path hasPrefix:@"/api/lib/albums"]) return g_albumsList ?: @{ @"ok": @YES, @"albums": @[] };
    if ([path hasPrefix:@"/api/lib/album?"]) return g_albumDetail ?: @{ @"ok": @NO };
    if ([path hasPrefix:@"/api/entity/summary"]) return SummaryResponse(path);
    if ([path hasPrefix:@"/api/entity/versions"]) return VersionsResponse(path);
    if ([path hasPrefix:@"/api/status"]) return @{ @"ok": @YES, @"playing": @YES, @"current": @"", @"dur": @0 };
    return @{ @"ok": @NO };
}

static void ResetFixtures(void) {
    [g_urls removeAllObjects];
    g_meta = nil;
    g_albumsList = nil;
    g_albumDetail = nil;
    [g_summaryQueues removeAllObjects];
    [g_versionsFixtures removeAllObjects];
}

static NSMutableArray<NSString *> *SummaryURLs(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *u in g_urls)
        if ([u hasPrefix:@"/api/entity/summary"]) [out addObject:u];
    return out;
}

#pragma mark clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return YES; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [g_urls addObject:path];
    id resp = ResponseForPath(path);
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(resp); });
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if (done) done(nil); }
- (void)postJSON:(NSString *)p body:(NSString *)b completion:(RLPJSONCompletion)d { if (d) d(@{ @"ok": @NO }); }
@end
#pragma mark clang diagnostic pop

#pragma mark - 记录 loadKind 的知识视图

@interface RLPRecordingKnowledge : RLPKnowledgeView
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *calls;
@end
@implementation RLPRecordingKnowledge
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) _calls = [NSMutableArray array];
    return self;
}
- (void)loadKind:(NSString *)kind name:(NSString *)name artist:(NSString *)artist {
    [self.calls addObject:@{ @"kind": kind ?: @"", @"name": name ?: @"",
                             @"artist": artist ?: @"", @"composer": @"" }];
}
/// web npDataActivate('work') → /api/entity/versions。生产码新增入口，这里只记录不联网。
- (void)loadWorkName:(NSString *)name composer:(NSString *)composer {
    [self.calls addObject:@{ @"kind": @"work", @"name": name ?: @"",
                             @"artist": @"", @"composer": composer ?: @"" }];
}
@end

/// 测试用的方法声明（生产实现由本包新增；旧码没有 ⟹ 判据必须红而不是编译失败）。
@interface RLPKnowledgeView (WorkTest)
- (void)loadWorkName:(NSString * _Nullable)name composer:(NSString * _Nullable)composer;
@end

/// 测试专用入口（生产里都是私有方法；category 声明避免改生产头文件）。
@interface RLPNowPlayingViewController (RailPreviewTest)
- (void)renderRailMetadata;
- (void)layoutWebPlayback;
- (void)loadMetaAndKnowledgeForPath:(NSString *)path;
- (void)onRailCard:(id)chip;
- (void)onRailDensity:(id)sender;
@end

#pragma mark - 视图查找 / 夹具

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}

static NSDictionary *MetaJSON(BOOL enabled, NSString *title, NSString *artist, NSString *album,
                              NSString *albumArtist, NSString *genre, BOOL available, BOOL cached,
                              BOOL hasKey) {
    return @{
        @"ok": @YES, @"title": title, @"artist": artist, @"album": album,
        @"albumArtist": albumArtist, @"year": @"2019", @"genre": genre,
        @"codec": @"flac", @"sampleRate": @96000, @"bits": @24,
        @"summaryArtist": albumArtist, @"summaryAvailable": @(available),
        @"summaryCached": @(cached), @"summaryCacheOk": @(cached), @"summaryKind": @"track",
        @"hasLlmKey": @(hasKey), @"summaryEnabled": @(enabled),
    };
}

static NSDictionary *TrackFieldsFixture(void) {
    return @{ @"ok": @YES, @"fields": @{
        @"演唱": @"Aimer", @"作曲": @"梶浦由記",
        @"歌曲风格": @"J-POP", @"发行时间": @"2019",
    }, @"sections": @[], @"from_cache": @YES, @"summaryCached": @YES };
}

static NSDictionary *ReleaseFieldsFixture(void) {
    return @{ @"ok": @YES, @"fields": @{
        @"出版方": @"Sony Music", @"专辑类型": @"专辑", @"语种": @"日语", @"发行时间": @"2019",
    }, @"sections": @[], @"from_cache": @NO, @"summaryCached": @NO };
}

static NSDictionary *PersonFieldsFixture(void) {
    return @{ @"ok": @YES, @"fields": @{
        @"简介": @"AQUAPLUS 是日本的美少女游戏品牌，以《传颂之物》系列闻名，成立于 1994 年。",
        @"风格": @"J-POP", @"代表作品": @"传颂之物",
    }, @"sections": @[], @"from_cache": @NO };
}

static NSDictionary *PersonSectionsFixture(void) {
    return @{ @"ok": @YES, @"fields": @{},
      @"sections": @[ @{ @"heading": @"简介", @"paragraphs": @[
          @{ @"text": @"以《传颂之物》系列闻名的日本美少女游戏品牌，成立于 1994 年。",
             @"citations": @[] } ] } ],
      @"from_cache": @NO };
}

static RLPNowPlayingViewController *NewVC(NSMutableArray<NSDictionary *> *callsOut) {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPRailHidden"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPAnalysisHidden"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"RLPNPRailDetail"];
    RLPNowPlayingViewController *vc = [RLPNowPlayingViewController new];
    NSView *v = vc.view;                     // loadView → buildContent（离屏视图树）
    v.frame = NSMakeRect(0, 0, 1400, 900);
    RLPRecordingKnowledge *k = [[RLPRecordingKnowledge alloc] initWithFrame:NSMakeRect(0, 0, 420, 380)];
    [vc setValue:k forKey:@"knowledge"];
    if (callsOut) [callsOut addObjectsFromArray:k.calls];
    return vc;
}

static void Pump(double seconds) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static RLPPlaybackStatus *StatusWithPath(NSString *path, double duration) {
    return [RLPPlaybackStatus statusFromJSON:@{ @"ok": @YES, @"playing": @YES,
        @"current": path, @"dur": @(duration), @"volDb": @(-120) }];
}

static NSView *Chip(NSView *rail, NSString *label) {
    return FindById(rail, [@"npChip." stringByAppendingString:label]);
}
static NSTextField *ChipP1(NSView *rail, NSString *label) {
    NSView *c = Chip(rail, label);
    return (NSTextField *)FindById(c, @"npChip.p1");
}
static NSTextField *ChipP2(NSView *rail, NSString *label) {
    NSView *c = Chip(rail, label);
    return (NSTextField *)FindById(c, @"npChip.p2");
}
static NSTextField *ChipSt(NSView *rail, NSString *label) {
    NSView *c = Chip(rail, label);
    return (NSTextField *)FindById(c, @"npChip.st");
}

static void ClickChip(RLPNowPlayingViewController *vc, NSView *chip) {
    // 旧码会在无窗口的 NSPopover 上抛「view has no window」；这不是被断言的
    // 行为，捕获后继续，让 loadKind 记录和后续判据都能量到。
    @try {
        [vc onRailCard:(id)chip];
    } @catch (NSException *e) {
        std::printf("  (popover without window caught: %s)\n", e.reason.UTF8String ?: "");
    }
}

#pragma mark - 场景

static NSString *const kPath = @"/Music/夜想曲.m4a";

static void ScenarioPreviewAndClicks(void) {
    std::printf("--- 场景1：track/release/person 预览 + 两档 + 点击实体类型 ---\n");
    ResetFixtures();
    g_meta = MetaJSON(YES, @"夜想曲", @"Aimer", @"Album Y", @"Aimer", @"J-POP", YES, NO, YES);
    g_summaryQueues[@"track|夜想曲"] = [@[ @{ @"ok": @NO, @"pending": @YES,
        @"retryAfterMs": @150, @"error": @"正在整理资料", @"summaryKind": @"track" },
        TrackFieldsFixture() ] mutableCopy];
    g_summaryQueues[@"release|Album Y"] = [@[ ReleaseFieldsFixture() ] mutableCopy];
    g_summaryQueues[@"person|Aimer"] = [@[ PersonFieldsFixture() ] mutableCopy];
    g_albumsList = @{ @"ok": @YES, @"albums": @[ @{
        @"k": @"alb_y", @"name": @"Album Y", @"artist": @"Aimer", @"year": @2019,
        @"n": @3, @"dur": @585, @"sr": @96000, @"bits": @24 } ] };
    g_albumDetail = @{ @"ok": @YES, @"k": @"alb_y", @"name": @"Album Y", @"artist": @"Aimer",
        @"year": @2019, @"dur": @585, @"tracks": @[
            @{ @"dur": @180 }, @{ @"dur": @200 }, @{ @"dur": @205 } ] };

    NSMutableArray<NSDictionary *> *calls = [NSMutableArray array];
    RLPNowPlayingViewController *vc = NewVC(calls);
    [vc setValue:kPath forKey:@"currentPath"];
    [vc setValue:StatusWithPath(kPath, 225) forKey:@"webStatus"];
    [vc loadMetaAndKnowledgeForPath:kPath];
    Pump(1.0);
    [vc layoutWebPlayback];
    NSView *rail = FindById(vc.view, @"npRail");
    Ck(rail != nil, "找得到 AI 整理栏 #npRail", @"npRail 缺失");

    // ---- (a) 歌曲卡：字段预览优先；状态按 from_cache ----
    NSTextField *tP1 = ChipP1(rail, @"歌曲");
    NSTextField *tP2 = ChipP2(rail, @"歌曲");
    NSTextField *tSt = ChipSt(rail, @"歌曲");
    EqStr(tP1.stringValue, @"演唱 Aimer · 作曲 梶浦由記",
          "(a) 歌曲 p1 = 演唱/作曲字段（不是标题）");
    HasStr(tP2.stringValue ?: @"", @"歌曲风格 J-POP", "(a) 歌曲 p2 含 歌曲风格 J-POP");
    HasStr(tP2.stringValue ?: @"", @"发行时间 2019", "(a) 歌曲 p2 含 发行时间 2019");
    EqStr(tSt.stringValue, RLPTr(@"已缓存"), "(a) 歌曲状态 = 已缓存（from_cache）");

    // ---- (b) 专辑卡：本地曲库年份 / 曲目数 / 总时长 + 字段 p2 ----
    NSTextField *rP1 = ChipP1(rail, @"专辑");
    NSTextField *rP2 = ChipP2(rail, @"专辑");
    NSTextField *rSt = ChipSt(rail, @"专辑");
    std::printf("  (release p1=「%s」 p2=「%s」)\n", rP1.stringValue.UTF8String,
                rP2.stringValue.UTF8String);
    HasStr(rP1.stringValue ?: @"", @"2019", "(b) 专辑 p1 含年份 2019");
    HasStr(rP1.stringValue ?: @"", @"3 首", "(b) 专辑 p1 含 3 首");
    HasStr(rP1.stringValue ?: @"", @"9:45", "(b) 专辑 p1 含总时长 9:45");
    HasStr(rP2.stringValue ?: @"", @"出版方 Sony Music", "(b) 专辑 p2 = 出版方字段");
    EqStr(rSt.stringValue, RLPTr(@"已整理"), "(b) 专辑状态 = 已整理");

    // ---- (c) 艺术家卡：简略档 = 「名字：简介」≤40字 + … ----
    NSTextField *pP1 = ChipP1(rail, @"艺术家");
    NSTextField *pP2 = ChipP2(rail, @"艺术家");
    std::printf("  (person p1=「%s」 len=%lu)\n", pP1.stringValue.UTF8String,
                (unsigned long)pP1.stringValue.length);
    Ck([pP1.stringValue hasPrefix:@"Aimer："], "(c) 艺术家 p1 以「Aimer：」开头", pP1.stringValue);
    Ck([pP1.stringValue containsString:@"AQUAPLUS"], "(c) 艺术家 p1 含简介正文", pP1.stringValue);
    Ck(pP1.stringValue.length <= 40, "(c) 简略档简介 ≤40 字",
       [NSString stringWithFormat:@"len=%lu", (unsigned long)pP1.stringValue.length]);
    Ck([pP1.stringValue hasSuffix:@"…"], "(c) 简略档截断补 …", pP1.stringValue);
    HasStr(pP2.stringValue ?: @"", @"风格 J-POP", "(c) 艺术家 p2 = 风格字段");

    // ---- (g) summary URL 形状与 web npSummUrl 逐字一致 ----
    NSArray<NSString *> *urls = SummaryURLs();
    std::printf("  summary URLs:\n");
    for (NSString *u in urls) std::printf("    %s\n", u.UTF8String);
    NSString *wantTrack = @"/api/entity/summary?kind=track&name=%E5%A4%9C%E6%83%B3%E6%9B%B2"
        @"&artist=Aimer&album=Album%20Y&file=%2FMusic%2F%E5%A4%9C%E6%83%B3%E6%9B%B2.m4a"
        @"&genre=J-POP&lang=zh";
    NSString *wantRelease = @"/api/entity/summary?kind=release&name=Album%20Y&artist=Aimer&lang=zh";
    NSString *wantPerson = @"/api/entity/summary?kind=person&name=Aimer&lang=zh";
    Ck(urls.count >= 3, "(g) 三个实体都发了 summary 请求",
       [NSString stringWithFormat:@"n=%lu", (unsigned long)urls.count]);
    Ck([urls containsObject:wantTrack], "(g) track URL = web npSummUrl（含 album/file/genre/编码）",
       [urls componentsJoinedByString:@"\n"]);
    Ck([urls containsObject:wantRelease], "(g) release URL = web npSummUrl（含 artist/编码）",
       [urls componentsJoinedByString:@"\n"]);
    Ck([urls containsObject:wantPerson], "(g) person URL = web npSummUrl（无 artist）",
       [urls componentsJoinedByString:@"\n"]);
    Ck([urls filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSString *u, NSDictionary *b) {
            (void)b; return [u containsString:@"kind=track"]; }]].count == 2,
       "(g) pending 后按 retryAfterMs 轮询一次（track 共 2 请求）",
       [NSString stringWithFormat:@"track n=%lu",
        (unsigned long)[urls filteredArrayUsingPredicate:
         [NSPredicate predicateWithBlock:^BOOL(NSString *u, NSDictionary *b) {
             (void)b; return [u containsString:@"kind=track"]; }]].count]);

    // ---- (c detail) 切换详细档：不重新取数，简介不截断，5/2 行 ----
    NSUInteger before = SummaryURLs().count;
    NSSegmentedControl *seg = (NSSegmentedControl *)[vc valueForKey:@"railDensity"];
    seg.selectedSegment = 1;
    [vc onRailDensity:seg];
    [vc layoutWebPlayback];
    Pump(0.2);
    NSUInteger after = SummaryURLs().count;
    Ck(after == before, "(c) 切详细档不重新取数",
       [NSString stringWithFormat:@"before=%lu after=%lu", (unsigned long)before, (unsigned long)after]);
    NSTextField *dP1 = ChipP1(rail, @"艺术家");
    NSTextField *dP2 = ChipP2(rail, @"艺术家");
    Ck([dP1.stringValue containsString:@"成立于 1994 年"],
       "(c) 详细档简介不截断到 40 字（完整正文）", dP1.stringValue);
    Ck(![dP1.stringValue hasSuffix:@"…"], "(c) 详细档不再补省略号", dP1.stringValue);
    Ck(dP1.maximumNumberOfLines == 5, "(c) 详细档 p1 maximumNumberOfLines == 5",
       [NSString stringWithFormat:@"%ld", (long)dP1.maximumNumberOfLines]);
    Ck(dP2.maximumNumberOfLines == 2, "(c) 详细档 p2 maximumNumberOfLines == 2",
       [NSString stringWithFormat:@"%ld", (long)dP2.maximumNumberOfLines]);
    Ck(dP1.font.pointSize >= 11.0 && dP1.font.pointSize <= 12.0,
       "(c) 详细档 p1 字号仍是 11.5", [NSString stringWithFormat:@"%.1f", dP1.font.pointSize]);
    Ck(dP2.font.pointSize >= 10.0 && dP2.font.pointSize <= 11.0,
       "(c) 详细档 p2 字号仍是 10.5", [NSString stringWithFormat:@"%.1f", dP2.font.pointSize]);

    // ---- 恢复简略档，供点击判据在正常档位下跑 ----
    seg.selectedSegment = 0;
    [vc onRailDensity:seg];
    Pump(0.1);

    // ---- (d) 点击卡片 = 打开对应实体类型的知识浮层 ----
    RLPRecordingKnowledge *k = (RLPRecordingKnowledge *)[vc valueForKey:@"knowledge"];
    [k.calls removeAllObjects];
    ClickChip(vc, Chip(rail, @"专辑"));
    NSDictionary *relCall = k.calls.lastObject;
    EqStr(relCall[@"kind"], @"release", "(d) 点专辑卡 → loadKind release");
    EqStr(relCall[@"name"], @"Album Y", "(d) 专辑卡 name = 专辑名");
    [k.calls removeAllObjects];
    ClickChip(vc, Chip(rail, @"艺术家"));
    NSDictionary *perCall = k.calls.lastObject;
    EqStr(perCall[@"kind"], @"person", "(d) 点艺术家卡 → loadKind person");
    EqStr(perCall[@"name"], @"Aimer", "(d) 艺术家卡 name = 艺术家名");
    [k.calls removeAllObjects];
    ClickChip(vc, Chip(rail, @"歌曲"));
    NSDictionary *trCall = k.calls.lastObject;
    EqStr(trCall[@"kind"], @"track", "(d) 点歌曲卡 → loadKind track");
}

static void ScenarioGatingOff(void) {
    std::printf("--- 场景2：summaryEnabled=false → 零 summary 请求 + 本地事实兜底 ---\n");
    ResetFixtures();
    g_meta = MetaJSON(NO, @"夜想曲", @"Aimer", @"Album Y", @"Aimer", @"J-POP", NO, NO, YES);
    // 夹具就位：哪怕代码误开请求也能被记录到（判据量的是「一条都没发」）。
    g_summaryQueues[@"track|夜想曲"] = [@[ TrackFieldsFixture() ] mutableCopy];
    g_summaryQueues[@"release|Album Y"] = [@[ ReleaseFieldsFixture() ] mutableCopy];
    g_summaryQueues[@"person|Aimer"] = [@[ PersonFieldsFixture() ] mutableCopy];

    RLPNowPlayingViewController *vc = NewVC(nil);
    [vc setValue:kPath forKey:@"currentPath"];
    [vc setValue:StatusWithPath(kPath, 225) forKey:@"webStatus"];
    [vc loadMetaAndKnowledgeForPath:kPath];
    Pump(0.6);
    [vc layoutWebPlayback];
    NSView *rail = FindById(vc.view, @"npRail");

    Ck(SummaryURLs().count == 0, "(e) 开关关闭时零 summary 请求",
       [NSString stringWithFormat:@"n=%lu", (unsigned long)SummaryURLs().count]);
    NSTextField *tP1 = ChipP1(rail, @"歌曲");
    NSTextField *tP2 = ChipP2(rail, @"歌曲");
    NSTextField *tSt = ChipSt(rail, @"歌曲");
    EqStr(tP1.stringValue, @"Aimer · Album Y", "(e) 歌曲卡回本地事实（艺术家 · 专辑）");
    HasStr(tP2.stringValue ?: @"", @"FLAC", "(e) 歌曲 p2 本地格式含 FLAC");
    HasStr(tP2.stringValue ?: @"", @"96k", "(e) 歌曲 p2 本地格式含 96k");
    HasStr(tP2.stringValue ?: @"", @"24bit", "(e) 歌曲 p2 本地格式含 24bit");
    HasStr(tP2.stringValue ?: @"", @"3:45", "(e) 歌曲 p2 本地格式含时长 3:45");
    EqStr(tSt.stringValue, @"", "(e) 未取资料时状态为空（不是「点开查看」）");
}

static void ScenarioInsufficient(void) {
    std::printf("--- 场景3：insufficient 是终局结论（资料不足，无本地假内容） ---\n");
    ResetFixtures();
    g_meta = MetaJSON(YES, @"夜想曲", @"Aimer", @"Album Y", @"Aimer", @"J-POP", YES, NO, YES);
    g_summaryQueues[@"track|夜想曲"] = [@[ @{ @"ok": @NO, @"insufficient": @YES,
        @"error": @"资料不足：缺少艺术家与曲名", @"summaryKind": @"track" } ] mutableCopy];
    g_summaryQueues[@"release|Album Y"] = [@[ @{ @"ok": @NO, @"error": @"boom" } ] mutableCopy];
    g_summaryQueues[@"person|Aimer"] = [@[ @{ @"ok": @NO, @"error": @"boom" } ] mutableCopy];

    RLPNowPlayingViewController *vc = NewVC(nil);
    [vc setValue:kPath forKey:@"currentPath"];
    [vc setValue:StatusWithPath(kPath, 225) forKey:@"webStatus"];
    [vc loadMetaAndKnowledgeForPath:kPath];
    Pump(0.6);
    [vc layoutWebPlayback];
    NSView *rail = FindById(vc.view, @"npRail");
    NSTextField *tP1 = ChipP1(rail, @"歌曲");
    NSTextField *tP2 = ChipP2(rail, @"歌曲");
    NSTextField *tSt = ChipSt(rail, @"歌曲");
    std::printf("  (insufficient p1=「%s」 st=「%s」)\n", tP1.stringValue.UTF8String,
                tSt.stringValue.UTF8String);
    EqStr(tSt.stringValue, @"资料不足", "(f) 状态 = 资料不足");
    HasStr(tP1.stringValue ?: @"", @"缺少", "(f) p1 写明缺少艺术家与曲名");
    Ck(tP2.stringValue.length == 0, "(f) insufficient 时 p2 为空（不显示本地兜底）",
       [NSString stringWithFormat:@"p2=「%@」", tP2.stringValue ?: @""]);
    NotHasStr(tP1.stringValue ?: @"", @"Aimer", "(f) insufficient 不拿本地艺术家冒充资料");
}

static void ScenarioSectionsFallback(void) {
    std::printf("--- 场景4：艺术家 sections 首段兜底（AI 只给段落没给字段） ---\n");
    ResetFixtures();
    g_meta = MetaJSON(YES, @"夜想曲", @"Aimer", @"Album Y", @"AQUAPLUS", @"J-POP", YES, NO, YES);
    g_summaryQueues[@"track|夜想曲"] = [@[ @{ @"ok": @YES, @"fields": @{ @"演唱": @"Aimer" } } ] mutableCopy];
    g_summaryQueues[@"release|Album Y"] = [@[ ReleaseFieldsFixture() ] mutableCopy];
    g_summaryQueues[@"person|AQUAPLUS"] = [@[ PersonSectionsFixture() ] mutableCopy];

    RLPNowPlayingViewController *vc = NewVC(nil);
    [vc setValue:kPath forKey:@"currentPath"];
    [vc setValue:StatusWithPath(kPath, 225) forKey:@"webStatus"];
    [vc loadMetaAndKnowledgeForPath:kPath];
    Pump(0.6);
    [vc layoutWebPlayback];
    NSView *rail = FindById(vc.view, @"npRail");
    NSTextField *pP1 = ChipP1(rail, @"艺术家");
    std::printf("  (sections person p1=「%s」)\n", pP1.stringValue.UTF8String);
    Ck([pP1.stringValue hasPrefix:@"AQUAPLUS："], "(c) sections 兜底：p1 以「AQUAPLUS：」开头", pP1.stringValue);
    HasStr(pP1.stringValue ?: @"", @"传颂之物", "(c) sections 兜底含首段正文");
}


#pragma mark - 场景5/6：第 4 张卡「作品（古典曲目）」

/// 卡片视图收集（递归：卡片在 `.npchipwrap` 内）。
static NSArray<NSView *> *AllRailChips(NSView *rail) {
    NSMutableArray<NSView *> *out = [NSMutableArray array];
    __block void (^collect)(NSView *);
    collect = ^(NSView *root){
        for (NSView *v in root.subviews) {
            NSString *cid = v.identifier;
            BOOL isChild = [cid isEqualToString:@"npChip.dot"] || [cid isEqualToString:@"npChip.name"] ||
                           [cid isEqualToString:@"npChip.st"] || [cid isEqualToString:@"npChip.p1"] ||
                           [cid isEqualToString:@"npChip.p2"];
            if ([cid hasPrefix:@"npChip."] && !isChild) [out addObject:v];
            collect(v);
        }
    };
    collect(rail);
    return out;
}
/// 沿 superview 链判断真实可见（web「tab 不在 tabs 里」⟺ 卡片隐藏）。
static BOOL VisibleUp(NSView *v) {
    for (NSView *x = v; x; x = x.superview) {
        if (x.hidden || x.alphaValue < 0.05) return NO;
        if (x.frame.size.width < 1 || x.frame.size.height < 1) return NO;
    }
    return YES;
}
/// 数抽屉里的演绎版本行（web .npdwork）。
static NSInteger WorkRowCount(NSView *root) {
    __block NSInteger n = 0;
    __block void (^walk)(NSView *);
    walk = ^(NSView *r){
        if ([r.identifier isEqualToString:@"npWorkRow"]) ++n;
        for (NSView *s in r.subviews) walk(s);
    };
    walk(root);
    return n;
}
static NSDictionary *WorkMeta(NSString *title, NSString *album, NSString *genre, NSString *composer) {
    NSMutableDictionary *m = [MetaJSON(YES, title, @"Wiener Philharmoniker", album,
                                       @"Wiener Philharmoniker", genre, YES, NO, YES) mutableCopy];
    if (composer.length) m[@"composer"] = composer;
    return m;
}
static NSDictionary *WorkPerformancesFixture(BOOL fromCache, NSNumber *generatedAt) {
    NSMutableDictionary *d = [@{
        @"ok": @YES,
        @"performances": @[
            @{ @"year": @1962, @"title": @"Symphony No. 5", @"conductor": @"Karajan",
               @"ensemble": @"Berliner Philharmoniker", @"label": @"DG", @"format": @"CD",
               @"url": @"https://www.discogs.com/release/1" },
            @{ @"year": @1987, @"title": @"Symphony No. 5", @"conductor": @"Abbado",
               @"orchestra": @"Wiener Philharmoniker", @"label": @"DG", @"format": @"CD",
               @"url": @"https://www.discogs.com/release/2" } ],
        @"distinctCount": @2, @"releaseCount": @2,
    } mutableCopy];
    d[@"from_cache"] = @(fromCache);
    if (generatedAt) d[@"generated_at"] = generatedAt;
    return d;
}

static void ScenarioWorkCard(void) {
    std::printf("--- 场景5：古典曲目的第 4 张卡「作品」（rail + versions + 点击实体）---\n");
    ResetFixtures();
    // 古典判定走专辑名前缀：「Beethoven: Symphony No. 5」⟹ composer=Beethoven、作品名=曲名
    g_meta = WorkMeta(@"Symphony No. 5", @"Beethoven: Symphony No. 5", @"Classical", nil);
    g_summaryQueues[@"track|Symphony No. 5"] = [@[ TrackFieldsFixture() ] mutableCopy];
    g_summaryQueues[@"release|Beethoven: Symphony No. 5"] = [@[ ReleaseFieldsFixture() ] mutableCopy];
    g_summaryQueues[@"person|Wiener Philharmoniker"] = [@[ PersonFieldsFixture() ] mutableCopy];
    g_versionsFixtures[@"work|Symphony No. 5|Beethoven"] = WorkPerformancesFixture(NO, nil);

    RLPNowPlayingViewController *vc = NewVC(nil);
    [vc setValue:@"/Music/symph5.flac" forKey:@"currentPath"];
    [vc setValue:StatusWithPath(@"/Music/symph5.flac", 400) forKey:@"webStatus"];
    [vc loadMetaAndKnowledgeForPath:@"/Music/symph5.flac"];
    Pump(1.0);
    [vc layoutWebPlayback];
    NSView *rail = FindById(vc.view, @"npRail");
    Ck(rail != nil, "找得到 AI 整理栏 #npRail", @"npRail 缺失");
    if (!rail) return;

    NSArray<NSView *> *chips = AllRailChips(rail);
    Ck(chips.count == 4, "古典曲目右栏是 4 张卡（歌曲/专辑/艺术家/作品）",
       [NSString stringWithFormat:@"cards=%lu", (unsigned long)chips.count]);
    NSView *workChip = Chip(rail, @"作品");
    Ck(workChip != nil, "第 4 张卡 identifier = npChip.作品（web npDataTargets 的 work tab）",
       @"找不到 npChip.作品");
    if (!workChip) return;
    Ck(VisibleUp(workChip), "作品卡可见（古典判定命中）", @"作品卡不可见");
    NSTextField *wname = (NSTextField *)FindById(workChip, @"npChip.name");
    EqStr(wname.stringValue, @"作品", "作品卡名 = web npDataTargets label「作品」");

    // ---- 数据：/api/entity/versions?kind=work&name=…&composer=… ----
    NSMutableArray<NSString *> *vurls = [NSMutableArray array];
    for (NSString *u in g_urls) if ([u hasPrefix:@"/api/entity/versions"]) [vurls addObject:u];
    std::printf("  versions URLs:\n");
    for (NSString *u in vurls) std::printf("    %s\n", u.UTF8String);
    NSString *want = @"/api/entity/versions?kind=work&name=Symphony%20No.%205&composer=Beethoven";
    Ck([vurls containsObject:want],
       "作品卡发 /api/entity/versions?kind=work&name=…&composer=…（web npDataEnsure work 分支）",
       [vurls componentsJoinedByString:@"\n"]);
    Ck(vurls.count == 1, "同一实体只请求一次（web npDataEnsure 的 in-flight 合并）",
       [NSString stringWithFormat:@"n=%lu", (unsigned long)vurls.count]);

    // ---- 预览：p1 = 作曲家（无 fields 时兜底）、p2 = 体裁、st = 已整理 ----
    NSTextField *wp1 = ChipP1(rail, @"作品");
    NSTextField *wp2 = ChipP2(rail, @"作品");
    NSTextField *wst = ChipSt(rail, @"作品");
    std::printf("  (work p1=「%s」 p2=「%s」 st=「%s」)\n", wp1.stringValue.UTF8String,
                wp2.stringValue.UTF8String, wst.stringValue.UTF8String);
    EqStr(wp1.stringValue, @"Beethoven", "作品 p1 = 作曲家（web npRailPreview work 分支）");
    Ck(wp2.stringValue.length == 0, "无 fields 时作品 p2 为空（不拿本地字段冒充）",
       [NSString stringWithFormat:@"p2=「%@」", wp2.stringValue ?: @""]);
    EqStr(wst.stringValue, RLPTr(@"已整理"), "作品状态 = 已整理（非缓存）");

    // ---- 点击第 4 张卡 → work 实体（web npDataActivate('work')）----
    RLPRecordingKnowledge *k = (RLPRecordingKnowledge *)[vc valueForKey:@"knowledge"];
    [k.calls removeAllObjects];
    ClickChip(vc, workChip);
    NSDictionary *call = k.calls.lastObject;
    EqStr(call[@"kind"], @"work", "点作品卡 → work 实体");
    EqStr(call[@"name"], @"Symphony No. 5", "作品实体 name = 曲名");
    EqStr(call[@"composer"], @"Beethoven", "作品实体带 composer（Discogs 检索要用）");

    // ---- 非古典：作品卡不出现、零 versions 请求（web 只给古典曲目加这一栏）----
    ResetFixtures();
    g_meta = WorkMeta(@"夜想曲", @"Album Y", @"J-POP", nil);
    g_summaryQueues[@"track|夜想曲"] = [@[ TrackFieldsFixture() ] mutableCopy];
    g_summaryQueues[@"release|Album Y"] = [@[ ReleaseFieldsFixture() ] mutableCopy];
    g_summaryQueues[@"person|Wiener Philharmoniker"] = [@[ PersonFieldsFixture() ] mutableCopy];
    RLPNowPlayingViewController *vc2 = NewVC(nil);
    [vc2 setValue:@"/Music/夜想曲.m4a" forKey:@"currentPath"];
    [vc2 setValue:StatusWithPath(@"/Music/夜想曲.m4a", 225) forKey:@"webStatus"];
    [vc2 loadMetaAndKnowledgeForPath:@"/Music/夜想曲.m4a"];
    Pump(0.8);
    [vc2 layoutWebPlayback];
    NSView *rail2 = FindById(vc2.view, @"npRail");
    NSView *workChip2 = Chip(rail2, @"作品");
    Ck(workChip2 == nil || !VisibleUp(workChip2), "非古典曲目作品卡不显示（web 无 work tab）",
       @"非古典时作品卡可见");
    NSMutableArray<NSString *> *u2 = [NSMutableArray array];
    for (NSString *u in g_urls) if ([u hasPrefix:@"/api/entity/versions"]) [u2 addObject:u];
    Ck(u2.count == 0, "非古典曲目零 versions 请求（不给流行曲发 Discogs）",
       [u2 componentsJoinedByString:@"\n"]);
}

static void ScenarioWorkDrawer(void) {
    std::printf("--- 场景6：作品抽屉正文（加载态 / 空态 / 缓存 · N 个版本 / 打开整页）---\n");
    if (![RLPKnowledgeView instancesRespondToSelector:@selector(loadWorkName:composer:)]) {
        Ck(NO, "RLPKnowledgeView 有 loadWorkName:composer:（web npDataActivate work 分支）",
           @"方法不存在（旧码）");
        return;
    }
    ResetFixtures();
    g_versionsFixtures[@"work|Symphony No. 5|Beethoven"] = WorkPerformancesFixture(NO, nil);
    RLPKnowledgeView *kv = [[RLPKnowledgeView alloc] initWithFrame:NSMakeRect(0, 0, 420, 500)];
    [kv loadWorkName:@"Symphony No. 5" composer:@"Beethoven"];
    NSTextField *status = (NSTextField *)FindById(kv, @"knowledgeStatus");
    Ck(status != nil, "作品抽屉有状态行 identification=knowledgeStatus", @"缺 knowledgeStatus");
    HasStr(status.stringValue ?: @"", @"正在整理资料",
           "加载态文案 = web npDataSkeleton「正在整理资料…」");
    Pump(0.4);
    Ck(WorkRowCount(kv) == 2, "演绎版本行数 = performances 条数（2）",
       [NSString stringWithFormat:@"rows=%ld", (long)WorkRowCount(kv)]);
    HasStr(status.stringValue ?: @"", @"Discogs 实时", "来源行 = web「Discogs 实时」");
    HasStr(status.stringValue ?: @"", @"不同演绎 2 / 发行版本 2",
           "来源行含「不同演绎 N / 发行版本 N」（web npDataWorkBody sub）");
    NSView *row0 = FindById(kv, @"npWorkRow");
    Ck(row0 != nil, "有 npdwork 行（web .npdwork）", @"缺 npWorkRow");
    if (row0) {
        EqStr(((NSTextField *)FindById(row0, @"npWorkYear")).stringValue, @"1962",
              "行首年份 = web .npdwork .wy（p.year）");
        EqStr(((NSTextField *)FindById(row0, @"npWorkTitle")).stringValue, @"Symphony No. 5",
              "行标题 = p.title");
        HasStr(((NSTextField *)FindById(row0, @"npWorkMeta")).stringValue ?: @"",
               @"Karajan · Berliner Philharmoniker · DG · CD",
               "行右侧 = conductor · ensemble · label · format（web meta 拼法）");
    }
    // ---- 空态：Discogs 没查到 / 网络不可达（web npDataWorkBody 首两行 + 重试）----
    g_versionsFixtures[@"work|Symphony No. 5|Beethoven"] = @{ @"ok": @NO, @"error": @"网络不可达" };
    [kv loadWorkName:@"Symphony No. 5" composer:@"Beethoven"];
    Pump(0.4);
    HasStr(status.stringValue ?: @"", @"未在 Discogs 检索到该作品的演绎版本",
           "空态文案 = web npDataWorkBody 首行（逐字）");
    NSTextField *subline = (NSTextField *)FindById(kv, @"npWorkHintSub");
    HasStr(subline.stringValue ?: @"", @"作品：Symphony No. 5 · Beethoven",
           "空态第二行 =「作品：名 · 作曲家」（web npDataWorkBody）");
    NSButton *refresh = (NSButton *)FindById(kv, @"knowledgeRefresh");
    HasStr(refresh.title ?: @"", @"重试", "空态给「重试查询」按钮（web npWorkRetry）");
    Ck(WorkRowCount(kv) == 0, "空态不残留上一轮的行",
       [NSString stringWithFormat:@"rows=%ld", (long)WorkRowCount(kv)]);
    // ---- 缓存态：来源行以「缓存」开头 ----
    g_versionsFixtures[@"work|Symphony No. 5|Beethoven"] = WorkPerformancesFixture(YES, @1730000000);
    [kv loadWorkName:@"Symphony No. 5" composer:@"Beethoven"];
    Pump(0.4);
    HasStr(status.stringValue ?: @"", @"缓存", "缓存态来源行以「缓存」开头（web from_cache 分支）");
    Ck(WorkRowCount(kv) == 2, "缓存态仍有 2 行",
       [NSString stringWithFormat:@"rows=%ld", (long)WorkRowCount(kv)]);

    // ---- 「查看 Discogs 版本推荐 →」= web npWorkOpen → 原生古典作品整页 ----
    __block NSDictionary *notified = nil;
    id token = [[NSNotificationCenter defaultCenter] addObserverForName:@"RLPOpenWorksNotification"
        object:nil queue:nil usingBlock:^(NSNotification *n){ notified = n.object; }];
    NSButton *openBtn = (NSButton *)FindById(kv, @"npWorkOpen");
    Ck(openBtn != nil, "作品抽屉有「查看 Discogs 版本推荐」入口", @"缺 npWorkOpen");
    if (openBtn) [openBtn performClick:nil];
    Ck([notified[@"title"] isEqualToString:@"Symphony No. 5"], "打开整页带作品名",
       notified.description ?: @"未发出通知");
    Ck([notified[@"composer"] isEqualToString:@"Beethoven"], "打开整页带作曲家",
       notified.description ?: @"未发出通知");
    [[NSNotificationCenter defaultCenter] removeObserver:token];
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_urls = [NSMutableArray array];
        g_summaryQueues = [NSMutableDictionary dictionary];
        g_versionsFixtures = [NSMutableDictionary dictionary];
        std::printf("=== test_native_rail_preview（内容级 · 离屏 · 不出声 · 不发真请求）===\n");
        std::printf("--- 基准: ui_script.h npRailPreview(12927-13040) / npSummUrl(13230-13260) ---\n");

        ScenarioPreviewAndClicks();
        ScenarioGatingOff();
        ScenarioInsufficient();
        ScenarioSectionsFallback();
        ScenarioWorkCard();
        ScenarioWorkDrawer();

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
