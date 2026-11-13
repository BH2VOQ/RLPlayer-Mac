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

static id ResponseForPath(NSString *path) {
    if ([path hasPrefix:@"/api/meta"]) return g_meta ?: @{ @"ok": @NO };
    if ([path hasPrefix:@"/api/lib/albums"]) return g_albumsList ?: @{ @"ok": @YES, @"albums": @[] };
    if ([path hasPrefix:@"/api/lib/album?"]) return g_albumDetail ?: @{ @"ok": @NO };
    if ([path hasPrefix:@"/api/entity/summary"]) return SummaryResponse(path);
    if ([path hasPrefix:@"/api/status"]) return @{ @"ok": @YES, @"playing": @YES, @"current": @"", @"dur": @0 };
    return @{ @"ok": @NO };
}

static void ResetFixtures(void) {
    [g_urls removeAllObjects];
    g_meta = nil;
    g_albumsList = nil;
    g_albumDetail = nil;
    [g_summaryQueues removeAllObjects];
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
- (BOOL)started { return NO; }
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
                             @"artist": artist ?: @"" }];
}
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

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_urls = [NSMutableArray array];
        g_summaryQueues = [NSMutableDictionary dictionary];
        std::printf("=== test_native_rail_preview（内容级 · 离屏 · 不出声 · 不发真请求）===\n");
        std::printf("--- 基准: ui_script.h npRailPreview(12927-13040) / npSummUrl(13230-13260) ---\n");

        ScenarioPreviewAndClicks();
        ScenarioGatingOff();
        ScenarioInsufficient();
        ScenarioSectionsFallback();

        std::printf("结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
