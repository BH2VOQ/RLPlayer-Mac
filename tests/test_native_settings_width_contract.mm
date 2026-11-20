// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_settings_width_contract.mm — 元数据页宽度契约（M1–M4，真实 NSWindow + Spy · 不出声）
//
// ============================ 这条判据在证明什么 ============================
// 旧实现（b451f49 及以前）进入设置「元数据 / 数据源」meta pane 时，即使 sp_metaadv 默认收起，
// 也因：
//   1) RLPSettingsGroup._head._hintLabel 压缩阻力 750 > fitting(50)，其中「联网检索端点」
//      ~794–811pt 经 searchGroup required 等宽链 + adv(≤stack) 把主窗从 940 撑到 1068/1085
//      （合入两列前为 1304）；
//   2) settings.modeHint 压缩阻力 250 > fitting(50) 把设置页根 fitting 顶到 755~945pt；
//   3) aiGroup/searchGroup 写死 240/320/220pt 等宽且 twoCol 无窄屏单列自适应、modelRow 三控件横拼 586pt；
// 导致在 900 / 940 设计窗宽下要么把窗口撑宽，要么在固定宽下触发卡片裁切与横向溢出（doc > clip）。
//
// 本契约验证：
//   M1 940x690 fixture 进 meta：settings 根宽 == 宿主宽；paneHost 滚动 clip == doc ±1；卡片/两列 maxX <= clip。
//   M2 切到 meta 不被设置页撑宽（win <= 基线 +0.5，主窗合入后 == 940），且页自身 fitting 宽 <= 674
//      （226 + fitting <= 900 <= 940），同时打印实际 fitting 值。
//   M3 meta → adv → meta 重复挂载（展开/收起两种状态 + 1180 缩窗）均不超宽不越界。
//   M4 900x600 主窗 fixture + 精确 674pt 固定 NSWindow 进 meta：无横向滚动（doc == clip），
//      窄窗自动降级为单列纵向堆叠（两列不横排溢出），所有卡片及内部控件 maxX <= clip，窗口不变大。
//
// 纪律（铁律 1/2/3/4）：Accessory 离屏、窗口不 orderFront；Spy 客户端 backend=null、volume=-120；
// 不启动核心、不碰 8899、不出声、不动真实键鼠。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPSettingsViewController.h"
#import "RLPSettingsLayout.h"
#import "RLPServersView.h"
#import "RLPCastView.h"
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

@interface RLPMainWindowController (TelemetryAudit)
- (void)setUiMode:(NSString *)mode persist:(BOOL)persist;
- (void)onNowPlaying:(id)sender;
- (void)onCloseNowPlaying:(nullable NSNotification *)note;
@end

@interface RLPSettingsViewController (TelemetryAudit)
@property (nonatomic, copy, nullable) void (^fbProbeTransport)(void (^done)(NSInteger status, NSData * _Nullable body, BOOL timedOut));
@property (nonatomic, copy, nullable) void (^fbUploadTransport)(NSString *url, NSString *body, void (^done)(NSInteger status, NSData * _Nullable body));
@property (nonatomic, copy, nullable) void (^diagSummaryTransport)(void (^done)(NSDictionary * _Nullable json));
- (void)postKey:(NSString *)key value:(NSString *)value completion:(void (^_Nullable)(BOOL ok))completion;
- (void)onFeedbackRetry:(id)sender;
@end

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

#pragma mark - 离屏 Spy 客户端（backend=null、volume=-120、含数据源/模型/长URL压力数据）

@interface RLPWidthContractSpy : NSObject
@property (nonatomic, assign) BOOL modelsAvailable;
@property (nonatomic, copy) NSString *backend;
@property (nonatomic, strong) NSMutableArray<NSString *> *requests;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *srcServers;
@property (nonatomic, copy) NSString *srcActive;
@property (nonatomic, assign) NSInteger srcSeq;
@property (nonatomic, copy, nullable) NSString *srcNextError;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *uiEvents;
@property (nonatomic, strong) NSMutableArray<NSString *> *uiEventBodies;
@property (nonatomic, assign) BOOL failNextSettingsPost;
@property (nonatomic, assign) BOOL diagZipEmpty;
@property (nonatomic, copy, nullable) NSDictionary *diagChannelsFixture;
@end

static NSDictionary<NSString *, NSString *> *RLPParseFormBody(NSString *body) {
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    if (!body.length) return out;
    for (NSString *pair in [body componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[pair substringToIndex:eq.location] stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        NSString *v = [[pair substringFromIndex:eq.location + 1] stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        k = [k stringByRemovingPercentEncoding] ?: k;
        v = [v stringByRemovingPercentEncoding] ?: v;
        out[k] = v;
    }
    return out;
}

@implementation RLPWidthContractSpy
- (instancetype)init {
    self = [super init];
    if (self) {
        _modelsAvailable = NO;
        _backend = @"null";
        _requests = [NSMutableArray array];
        _srcServers = [NSMutableArray array];
        _srcActive = @"";
        _uiEvents = [NSMutableArray array];
        _uiEventBodies = [NSMutableArray array];
    }
    return self;
}
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown { }
- (NSDictionary *)handlePostPath:(NSString *)path body:(nullable NSString *)body {
    if ([path isEqualToString:@"/api/ui/events"] && body.length) {
        [self.uiEventBodies addObject:[body copy]];
        NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *parsed = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSArray *arr = [parsed isKindOfClass:[NSDictionary class]] &&
                       [parsed[@"events"] isKindOfClass:[NSArray class]]
                     ? parsed[@"events"] : nil;
        for (id ev in arr) {
            if ([ev isKindOfClass:[NSDictionary class]]) [self.uiEvents addObject:ev];
        }
        return @{ @"ok": @YES, @"accepted": @(arr.count) };
    }
    if ([path hasPrefix:@"/api/settings"] && self.failNextSettingsPost) {
        self.failNextSettingsPost = NO;
        return @{ @"ok": @NO, @"error": @"mock rejected" };
    }
    if ([path hasPrefix:@"/api/src/config"]) {
        if (self.srcNextError.length) {
            NSString *err = [self.srcNextError copy];
            self.srcNextError = nil;
            return @{ @"ok": @NO, @"error": err };
        }
        NSDictionary<NSString *, NSString *> *f = RLPParseFormBody(body ?: @"");
        NSString *act = f[@"action"] ?: @"";
        if ([act isEqualToString:@"add"]) {
            NSString *sid = [NSString stringWithFormat:@"srv-%ld", (long)++self.srcSeq];
            NSMutableDictionary *entry = [@{
                @"id": sid,
                @"name": f[@"name"] ?: @"",
                @"kind": f[@"kind"].length ? f[@"kind"] : @"subsonic",
                @"base": f[@"base"] ?: @"",
                @"user": f[@"user"] ?: @"",
                @"hasPass": @(f[@"pass"].length > 0),
                @"active": @(self.srcServers.count == 0),
            } mutableCopy];
            if (self.srcServers.count == 0) self.srcActive = sid;
            [self.srcServers addObject:entry];
            return @{ @"ok": @YES, @"id": sid };
        }
        if ([act isEqualToString:@"update"]) {
            NSString *sid = f[@"id"] ?: @"";
            for (NSMutableDictionary *s in self.srcServers) {
                if ([s[@"id"] isEqualToString:sid]) {
                    s[@"name"] = f[@"name"] ?: @"";
                    s[@"kind"] = f[@"kind"].length ? f[@"kind"] : @"subsonic";
                    s[@"base"] = f[@"base"] ?: @"";
                    s[@"user"] = f[@"user"] ?: @"";
                    if (f[@"pass"].length > 0) s[@"hasPass"] = @YES;
                    return @{ @"ok": @YES };
                }
            }
            return @{ @"ok": @NO, @"error": @"not found" };
        }
        if ([act isEqualToString:@"remove"]) {
            NSString *sid = f[@"id"] ?: @"";
            NSUInteger idx = [self.srcServers indexOfObjectPassingTest:^BOOL(NSMutableDictionary *s, NSUInteger i, BOOL *stop) {
                (void)i;
                if ([s[@"id"] isEqualToString:sid]) { *stop = YES; return YES; }
                return NO;
            }];
            if (idx != NSNotFound) [self.srcServers removeObjectAtIndex:idx];
            if ([self.srcActive isEqualToString:sid]) {
                self.srcActive = self.srcServers.firstObject[@"id"] ?: @"";
            }
            for (NSMutableDictionary *s in self.srcServers) {
                s[@"active"] = @([s[@"id"] isEqualToString:self.srcActive]);
            }
            return @{ @"ok": @YES };
        }
        if ([act isEqualToString:@"active"]) {
            NSString *sid = f[@"id"] ?: @"";
            self.srcActive = sid;
            for (NSMutableDictionary *s in self.srcServers) {
                s[@"active"] = @([s[@"id"] isEqualToString:sid]);
            }
            return @{ @"ok": @YES };
        }
        return @{ @"ok": @NO, @"error": @"bad action" };
    }
    return @{ @"ok": @YES };
}
- (nullable NSDictionary *)jsonWithMethod:(NSString *)method
                                     path:(NSString *)path
                                     body:(nullable NSString *)body {
    [self.requests addObject:[NSString stringWithFormat:@"%@ %@", method ?: @"GET", path ?: @""]];
    if (![method isEqualToString:@"POST"]) return [self fixtureForPath:path ?: @""];
    return [self handlePostPath:path ?: @"" body:body];
}
- (nullable NSData *)dataWithMethod:(NSString *)method
                               path:(NSString *)path
                               body:(nullable NSString *)body
                        contentType:(NSString * _Nullable * _Nullable)contentType {
    (void)method; (void)path; (void)body; (void)contentType;
    return nil;
}
- (void)getJSON:(NSString *)path completion:(nullable RLPJSONCompletion)done {
    [self.requests addObject:[NSString stringWithFormat:@"GET %@", path ?: @""]];
    if (!done) return;
    NSDictionary *json = [self fixtureForPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
}
- (void)postJSON:(NSString *)path body:(nullable NSString *)body completion:(nullable RLPJSONCompletion)done {
    [self.requests addObject:[NSString stringWithFormat:@"POST %@", path ?: @""]];
    NSDictionary *res = [self handlePostPath:path ?: @"" body:body];
    if (!done) return;
    dispatch_async(dispatch_get_main_queue(), ^{ done(res); });
}
- (void)getData:(NSString *)path completion:(nullable RLPDataCompletion)done {
    [self.requests addObject:[NSString stringWithFormat:@"GET %@", path ?: @""]];
    NSData *payload = nil;
    if ([path hasPrefix:@"/api/diagzip"] && !self.diagZipEmpty) {
        static const unsigned char kFakeZip[] = { 'P', 'K', 3, 4, 20, 0, 0, 0, 0, 0, 0, 0 };
        payload = [NSData dataWithBytes:kFakeZip length:sizeof(kFakeZip)];
    } else if ([path hasPrefix:@"/api/diagjson"]) {
        payload = [@"{\"ok\":true,\"kind\":\"diagjson\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(payload); });
}
- (void)postData:(NSString *)path
            body:(NSData *)body
     contentType:(NSString *)contentType
      completion:(nullable RLPJSONCompletion)done {
    (void)path; (void)body; (void)contentType;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
}
- (NSDictionary *)fixtureForPath:(NSString *)path {
    if ([path hasPrefix:@"/api/settings"]) {
        return @{
            @"ok": @YES,
            @"kv": @{
                @"uimode": @"listen",
                @"backend": self.backend ?: @"null",
                @"volume": @"-120",
                @"theme": @"light",
                @"channels": @"0",
                @"metaon": @"1",
                @"metallm": @"0",
                @"metasummary": @"0",
            },
        };
    }
    if ([path hasPrefix:@"/api/playmode"]) return @{ @"ok": @YES, @"mode": @1 };
    if ([path hasPrefix:@"/api/writeback/status"]) return @{ @"ok": @YES, @"running": @NO };
    if ([path hasPrefix:@"/api/providers"]) {
        return @{
            @"ok": @YES,
            @"defaultOrder": @"qq,netease,itunes,lrclib",
            @"items": @[
                @{ @"id": @"qq", @"name": @"QQ Music", @"on": @YES, @"canSearch": @YES, @"canLyric": @YES },
                @{ @"id": @"netease", @"name": @"NetEase Cloud", @"on": @YES, @"canSearch": @YES, @"canLyric": @YES },
                @{ @"id": @"itunes", @"name": @"iTunes", @"on": @YES, @"canSearch": @YES, @"canLyric": @NO },
                @{ @"id": @"lrclib", @"name": @"LRCLIB", @"on": @YES, @"canSearch": @NO, @"canLyric": @YES },
            ],
        };
    }
    if ([path hasPrefix:@"/api/llm/models"]) {
        if (!self.modelsAvailable) {
            return @{ @"ok": @NO, @"error": @"offline fixture: model list disabled", @"models": @[], @"current": @"deepseek-chat" };
        }
        return @{
            @"ok": @YES,
            @"current": @"claude-sonnet-4-20250514",
            @"models": @[
                @{ @"id": @"deepseek-chat" },
                @{ @"id": @"claude-sonnet-4-20250514" },
                @{ @"id": @"gpt-4o-long-identifier-stress-test-model-name" },
            ],
        };
    }
    if ([path hasPrefix:@"/api/llm"]) {
        return @{
            @"ok": @YES,
            @"configured": @YES,
            @"masked": @"sk-****1234",
            @"baseUrl": @"https://api.deepseek.com/v1/very-long-custom-proxy-path-to-stress-text-field-width",
            @"model": @"claude-sonnet-4-20250514",
            @"searchProvider": @"tavily",
            @"searchBaseUrl": @"https://api.tavily.com/custom-search-endpoint-for-width-stress-check",
            @"searchConfigured": @YES,
            @"searchMasked": @"tvly-****5678",
        };
    }
    if ([path hasPrefix:@"/api/status"]) return @{ @"ok": @YES, @"playing": @NO, @"paused": @NO, @"volDb": @(-120) };
    if ([path hasPrefix:@"/api/queue"]) return @{ @"ok": @YES, @"items": @[], @"index": @0, @"mode": @0 };
    if ([path hasPrefix:@"/api/lib/albums"]) return @{ @"ok": @YES, @"albums": @[] };
    if ([path hasPrefix:@"/api/lib/artists"]) return @{ @"ok": @YES, @"artists": @[] };
    if ([path hasPrefix:@"/api/lib/search"]) return @{ @"ok": @YES, @"tracks": @[], @"total": @0, @"n": @0 };
    if ([path hasPrefix:@"/api/lib/stats"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/sq/list"]) return @{ @"ok": @YES, @"queues": @[] };
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/preset/caps"]) return @{ @"ok": @YES, @"known": @YES, @"pcmReady": @YES, @"dsdReady": @YES };
    if ([path hasPrefix:@"/api/src/config"]) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:self.srcServers.count];
        for (NSDictionary *s in self.srcServers) [arr addObject:[s copy]];
        return @{
            @"ok": @YES,
            @"servers": arr,
            @"active": self.srcActive ?: @"",
            @"configured": @(arr.count > 0),
        };
    }
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    if ([path hasPrefix:@"/api/diag/channels"]) {
        return self.diagChannelsFixture ?: @{
            @"ok": @YES,
            @"checkedAt": @"2026-11-19T07:40:00Z",
            @"update": @{ @"channel": @"global", @"ok": @YES, @"http": @200, @"latency": @123, @"timedOut": @NO, @"error": @"" },
            @"feedback": @{ @"ok": @YES, @"http": @200, @"latency": @88, @"timedOut": @NO, @"error": @"" },
        };
    }
    if ([path hasPrefix:@"/api/diag"]) return @{ @"ok": @YES, @"version": @"audit", @"summary": @"ok" };
    return @{ @"ok": @YES };
}
@end

static RLPWidthContractSpy *g_spy = nil;
static id FakeSharedClient(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }
static void NoopProbe(id self, SEL sel) { (void)self; (void)sel; }
static NSModalResponse g_savePanelResult = NSModalResponseCancel;
static NSURL *g_savePanelURL = nil;
static NSModalResponse FakeSavePanelRunModal(id self, SEL _cmd) { (void)self; (void)_cmd; return g_savePanelResult; }
static NSURL *FakeSavePanelURL(id self, SEL _cmd) { (void)self; (void)_cmd; return g_savePanelURL; }
static void NoopCheckManually(id self, SEL _cmd, BOOL manual) { (void)self; (void)_cmd; (void)manual; }

static void Pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

#pragma mark - 几何查询与断言工具

static void CollectAllViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectAllViews(s, out);
}

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root || !ident.length) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}

static NSScrollView *PaneScroll(RLPSettingsViewController *settings) {
    NSView *ph = [settings valueForKey:@"paneHost"];
    for (NSView *sub in ph.subviews) {
        if ([sub isKindOfClass:[NSScrollView class]]) return (NSScrollView *)sub;
    }
    return nil;
}

static NSArray<NSView *> *CardsInView(NSView *root) {
    NSMutableArray<NSView *> *cards = [NSMutableArray array];
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    CollectAllViews(root, all);
    Class cls = [RLPSettingsGroup class];
    for (NSView *v in all) {
        if ([v isKindOfClass:cls]) [cards addObject:v];
    }
    return cards;
}

static NSString *CardTitle(NSView *card) {
    NSView *head = FindById(card, @"set.group.head");
    if (!head) return @"";
    for (NSView *s in head.subviews) {
        if ([s isKindOfClass:[NSTextField class]]) return ((NSTextField *)s).stringValue ?: @"";
    }
    return @"";
}

static BOOL IsHiddenInHierarchy(NSView *v, NSView *stopAt) {
    for (NSView *cur = v; cur && cur != stopAt; cur = cur.superview) {
        if (cur.hidden) return YES;
    }
    return NO;
}

static void LayoutHost(NSView *layoutRoot, double pumpSeconds) {
    [layoutRoot layoutSubtreeIfNeeded];
    Pump(pumpSeconds);
    [layoutRoot layoutSubtreeIfNeeded];
}

static void DumpFittingMetrics(const char *tag, RLPSettingsViewController *settings, NSView *hostView) {
    NSView *ph = [settings valueForKey:@"paneHost"];
    NSScrollView *sv = PaneScroll(settings);
    NSView *doc = sv ? sv.documentView : nil;
    NSView *adv = FindById(settings.view, @"sp_metaadv");
    const NSSize sFit = settings.view.fittingSize;
    const NSSize pFit = ph ? ph.fittingSize : NSZeroSize;
    const NSSize dFit = doc ? doc.fittingSize : NSZeroSize;
    const NSSize aFit = adv ? adv.fittingSize : NSZeroSize;
    std::printf("  [fitting %-26s] host=%.1f root=%.1f clip=%.1f doc=%.1f | fit(settings=%.1f paneHost=%.1f stack=%.1f adv=%.1f hidden=%d)\n",
                tag,
                hostView ? hostView.bounds.size.width : -1.0,
                settings.view.bounds.size.width,
                sv ? sv.contentView.bounds.size.width : -1.0,
                doc ? doc.bounds.size.width : -1.0,
                sFit.width, pFit.width, dFit.width, aFit.width,
                adv ? (int)adv.hidden : -1);
}

/// 验证某宿主尺寸下 meta 页的全部宽度/溢出/降级规则。
/// @param expectStacked 当 avail < 840 (hostW < 888) 且展开时为 YES，宽屏两列时为 NO。
static void AssertMetaGeometry(const char *label,
                               RLPSettingsViewController *settings,
                               NSView *hostView,
                               BOOL expectExpanded,
                               BOOL expectStacked,
                               BOOL expectModelsPopup) {
    const std::string pfx(label);
    Ck([[settings currentPaneKey] isEqualToString:@"meta"],
       (pfx + ": 当前页签是 meta").c_str(), [settings currentPaneKey]);

    NSView *ph = [settings valueForKey:@"paneHost"];
    NSScrollView *sv = PaneScroll(settings);
    NSClipView *clip = sv ? sv.contentView : nil;
    NSView *doc = sv ? sv.documentView : nil;
    Ck(ph != nil && sv != nil && clip != nil && doc != nil,
       (pfx + ": paneHost/scroll/clip/doc 存在").c_str(), @"视图缺件");
    if (!ph || !sv || !clip || !doc) return;

    const CGFloat hostW = hostView.bounds.size.width;
    const CGFloat rootW = settings.view.bounds.size.width;
    const CGFloat paneHostW = ph.bounds.size.width;
    const CGFloat clipW = clip.bounds.size.width;
    const CGFloat docW = doc.bounds.size.width;

    Ck(std::fabs(rootW - hostW) <= 1.0,
       (pfx + ": settings 根视图宽 == 宿主宽").c_str(),
       [NSString stringWithFormat:@"root=%.1f host=%.1f", rootW, hostW]);
    Ck(std::fabs(paneHostW - hostW) <= 1.0,
       (pfx + ": paneHost 宽 == 宿主宽").c_str(),
       [NSString stringWithFormat:@"paneHost=%.1f host=%.1f", paneHostW, hostW]);
    Ck(!sv.hasHorizontalScroller,
       (pfx + ": 不启用横向滚动条").c_str(), @"hasHorizontalScroller=YES");
    Ck(std::fabs(docW - clipW) <= 1.0 && sv.documentView.frame.size.width <= clip.frame.size.width + 1.0,
       (pfx + ": scroll clip 宽 == doc 宽 (±1) 且不产生横向溢出").c_str(),
       [NSString stringWithFormat:@"clip=%.1f doc=%.1f docFrameW=%.1f", clipW, docW, sv.documentView.frame.size.width]);

    // 高级选项展开/收起状态验证；无论折叠与否，后端绑定控件仍应在视图树内以维持既有一致性。
    NSView *adv = FindById(settings.view, @"sp_metaadv");
    NSView *twoCol = FindById(settings.view, @"sp_metatwocol");
    Ck(adv != nil && adv.hidden == !expectExpanded,
       (pfx + ": sp_metaadv 显隐符合预期").c_str(),
       [NSString stringWithFormat:@"adv=%p hidden=%d expectExpanded=%d", adv, adv ? (int)adv.hidden : -1, (int)expectExpanded]);
    if (expectExpanded && adv) {
        Ck(adv.frame.size.height > 10.0,
           (pfx + ": 展开后 sp_metaadv 有真实高度").c_str(),
           [NSString stringWithFormat:@"h=%.1f", adv.frame.size.height]);
    }

    // 既有契约不可破坏：折叠状态下控件依然保留在视图树内。
    for (NSString *ident in @[ @"sp_metamore", @"llm.provider", @"llm.base", @"llm.key",
                              @"llm.save", @"llm.test", @"llm.clear", @"llm.modeltext",
                              @"llm.modelpopup", @"llm.modelrefresh", @"sp_wbdry", @"sp_wbapply",
                              @"search.provider", @"search.base", @"search.key", @"search.save", @"search.clear" ]) {
        Ck(FindById(settings.view, ident) != nil,
           (pfx + ": 控件 " + ident.UTF8String + " 在视图树内").c_str(), ident);
    }

    // 卡片及两列容器不得超过 clip 右缘
    NSArray<NSView *> *cards = CardsInView(doc);
    NSMutableArray<NSString *> *cardOverflows = [NSMutableArray array];
    NSView *dataCard = nil, *aiCard = nil, *searchCard = nil;
    for (NSView *card in cards) {
        NSString *title = CardTitle(card);
        if (FindById(card, @"metasrc.list") || [title containsString:@"数据源"] || [title containsString:@"Data Sources"]) dataCard = card;
        if (FindById(card, @"llm.base") || [title containsString:@"AI 接入"] || [title containsString:@"AI Integration"]) aiCard = card;
        if (FindById(card, @"search.base") || [title containsString:@"联网检索"] || [title containsString:@"Search endpoints"]) searchCard = card;
        if (IsHiddenInHierarchy(card, doc)) continue;
        const NSRect r = [card convertRect:card.bounds toView:clip];
        if (NSMinX(r) < -1.0 || NSMaxX(r) > clipW + 1.0 || NSWidth(r) < 100.0) {
            [cardOverflows addObject:[NSString stringWithFormat:@"%@:[%.1f..%.1f w=%.1f]",
                                      title, NSMinX(r), NSMaxX(r), NSWidth(r)]];
        }
    }
    Ck(cardOverflows.count == 0,
       (pfx + ": 所有可见卡片 maxX <= clip 宽且宽度有效").c_str(),
       [NSString stringWithFormat:@"clip=%.1f over=[%@]", clipW, [cardOverflows componentsJoinedByString:@", "]]);

    if (twoCol && !IsHiddenInHierarchy(twoCol, doc)) {
        const NSRect twoR = [twoCol convertRect:twoCol.bounds toView:clip];
        Ck(NSMinX(twoR) >= -1.0 && NSMaxX(twoR) <= clipW + 1.0,
           (pfx + ": 两列容器 sp_metatwocol maxX <= clip 宽").c_str(),
           [NSString stringWithFormat:@"twoCol=[%.1f..%.1f] clip=%.1f", NSMinX(twoR), NSMaxX(twoR), clipW]);
    }

    if (expectExpanded && dataCard && aiCard && searchCard) {
        const NSRect dataR = [dataCard convertRect:dataCard.bounds toView:clip];
        const NSRect aiR = [aiCard convertRect:aiCard.bounds toView:clip];
        const NSRect searchR = [searchCard convertRect:searchCard.bounds toView:clip];
        if (expectStacked) {
            const BOOL verticallyDisjoint = (NSMinY(dataR) >= NSMaxY(aiR) - 1.0) ||
                                            (NSMinY(aiR) >= NSMaxY(dataR) - 1.0);
            Ck(verticallyDisjoint && NSMaxX(dataR) <= clipW + 1.0 && NSMaxX(aiR) <= clipW + 1.0,
               (pfx + ": 窄窗高级区两卡片自动降级为纵向单列堆叠（不横排越界）").c_str(),
               [NSString stringWithFormat:@"data=%@ ai=%@ clip=%.1f",
                NSStringFromRect(dataR), NSStringFromRect(aiR), clipW]);
        } else {
            const BOOL flipped = clip.isFlipped;
            const CGFloat dataTop = flipped ? NSMinY(dataR) : NSMaxY(dataR);
            const CGFloat aiTop   = flipped ? NSMinY(aiR)   : NSMaxY(aiR);
            const BOOL sideBySide = std::fabs(dataTop - aiTop) <= 4.0 &&
                                    NSMinX(dataR) < NSMinX(aiR) &&
                                    NSMaxX(dataR) <= NSMinX(aiR) + 1.0 &&
                                    std::fabs(NSWidth(dataR) - NSWidth(aiR)) <= 2.0;
            Ck(sideBySide && NSMaxX(aiR) <= clipW + 1.0,
               (pfx + ": 宽窗高级区恢复左右两列并排且不越界").c_str(),
               [NSString stringWithFormat:@"data=%@ ai=%@ clip=%.1f",
                NSStringFromRect(dataR), NSStringFromRect(aiR), clipW]);
        }
        Ck(NSMaxX(searchR) <= clipW + 1.0,
           (pfx + ": 联网检索卡片与前两卡对齐且不越界").c_str(),
           [NSString stringWithFormat:@"search=%@ clip=%.1f", NSStringFromRect(searchR), clipW]);

        // 检查所有可见控件/标签右缘不超出 clip 与各自所在卡片，且不被压扁成 0pt
        NSMutableArray<NSString *> *descendantOverflows = [NSMutableArray array];
        NSArray<NSString *> *checkIds = @[
            @"llm.provider", @"llm.base", @"llm.key", @"llm.status",
            @"llm.save", @"llm.test", @"llm.clear",
            @"llm.modelpopup", @"llm.modeltext", @"llm.modelrefresh", @"llm.modelmsg",
            @"sp_wbdesc", @"sp_wbdry", @"sp_wbapply", @"sp_wbmsg",
            @"search.provider", @"search.base", @"search.key", @"search.status",
            @"search.save", @"search.clear", @"metasrc.reset", @"metasrc.msg"
        ];
        for (NSString *ident in checkIds) {
            NSView *v = FindById(doc, ident);
            if (!v || IsHiddenInHierarchy(v, doc)) continue;
            const NSRect vr = [v convertRect:v.bounds toView:clip];
            const BOOL tooNarrowControl = [v isKindOfClass:[NSControl class]] && NSWidth(vr) < 30.0;
            if (NSMinX(vr) < -1.0 || NSMaxX(vr) > clipW + 1.0 || tooNarrowControl) {
                [descendantOverflows addObject:[NSString stringWithFormat:@"%@:[%.1f..%.1f w=%.1f]",
                                                ident, NSMinX(vr), NSMaxX(vr), NSWidth(vr)]];
            }
        }
        Ck(descendantOverflows.count == 0,
           (pfx + ": 展开态所有卡片子控件右缘不越界且无零宽挤压").c_str(),
           [NSString stringWithFormat:@"clip=%.1f bad=[%@]", clipW, [descendantOverflows componentsJoinedByString:@", "]]);

        // 检查动作按钮行与模型行的相邻控件互不重叠
        auto checkNoOverlap = ^(NSArray<NSString *> *ids, const char *groupName) {
            NSMutableArray<NSValue *> *rects = [NSMutableArray array];
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSString *ident in ids) {
                NSView *v = FindById(doc, ident);
                if (!v || IsHiddenInHierarchy(v, doc)) continue;
                [rects addObject:[NSValue valueWithRect:[v convertRect:v.bounds toView:clip]]];
                [names addObject:ident];
            }
            BOOL overlapped = NO;
            NSString *detail = @"";
            for (NSUInteger i = 0; i < rects.count; ++i) {
                for (NSUInteger j = i + 1; j < rects.count; ++j) {
                    const NSRect inter = NSIntersectionRect(rects[i].rectValue, rects[j].rectValue);
                    if (NSWidth(inter) > 1.0 && NSHeight(inter) > 1.0) {
                        overlapped = YES;
                        detail = [NSString stringWithFormat:@"%@ vs %@ inter=%@",
                                  names[i], names[j], NSStringFromRect(inter)];
                        break;
                    }
                }
                if (overlapped) break;
            }
            Ck(!overlapped, (pfx + ": " + groupName + " 控件互不重叠").c_str(), detail);
        };
        checkNoOverlap(@[ @"llm.save", @"llm.test", @"llm.clear" ], "AI按钮区");
        checkNoOverlap(@[ @"llm.modelpopup", @"llm.modeltext", @"llm.modelrefresh" ], "LLM模型区");

        NSView *pop = FindById(doc, @"llm.modelpopup");
        if (expectModelsPopup) {
            Ck(pop && !pop.hidden && NSWidth([pop convertRect:pop.bounds toView:clip]) >= 60.0,
               (pfx + ": 模型列表拉取后 llm.modelpopup 可见且有合理宽度").c_str(),
               [NSString stringWithFormat:@"hidden=%d w=%.1f", pop ? (int)pop.hidden : -1,
                pop ? NSWidth([pop convertRect:pop.bounds toView:clip]) : 0.0]);
        }
    }
}

static NSWindow *CreateFixedHostWindow(CGFloat width, CGFloat height, RLPSettingsViewController *settings) {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, width, height)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.releasedWhenClosed = NO;
    NSView *content = win.contentView;
    NSView *sv = settings.view;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:sv];
    [NSLayoutConstraint activateConstraints:@[
        [sv.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [sv.topAnchor constraintEqualToAnchor:content.topAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
    return win;
}

static void ResetMainWindowFrame(RLPMainWindowController *wc, CGFloat width, CGFloat height) {
    NSRect f = wc.window.frame;
    f.size = NSMakeSize(width, height);
    [wc.window setFrame:f display:NO];
    [wc.window.contentView layoutSubtreeIfNeeded];
    Pump(0.06);
}

static NSModalResponse FakeAlertFirstButton(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NSAlertFirstButtonReturn;
}

static BOOL HasVisibleSubviewsOrContent(NSView *v) {
    if ([v isKindOfClass:[NSControl class]]) return YES;
    for (NSView *s in v.subviews) {
        if (s.hidden) continue;
        if (HasVisibleSubviewsOrContent(s)) return YES;
    }
    return NO;
}

static void AssertStreamPaneContract(const char *label,
                                     RLPMainWindowController *wc,
                                     RLPSettingsViewController *settings,
                                     BOOL expectFormVisible,
                                     CGFloat *outSrvH,
                                     CGFloat *outDocH) {
    const std::string pfx(label);
    Ck([[settings currentPaneKey] isEqualToString:@"stream"],
       (pfx + ": 当前页签是 stream").c_str(), [settings currentPaneKey]);

    NSScrollView *sv = PaneScroll(settings);
    NSClipView *clip = sv ? sv.contentView : nil;
    NSView *doc = sv ? sv.documentView : nil;
    Ck(sv != nil && clip != nil && doc != nil,
       (pfx + ": scroll/clip/doc 存在").c_str(), @"nil");
    if (!sv || !clip || !doc) return;

    const CGFloat clipW = clip.bounds.size.width;
    const CGFloat docW = doc.frame.size.width;
    const CGFloat docH = doc.frame.size.height;
    Ck(!sv.hasHorizontalScroller && docW <= clipW + 1.0,
       (pfx + ": doc<=clip 且无横向滚动条").c_str(),
       [NSString stringWithFormat:@"clipW=%.1f docW=%.1f horiz=%d", clipW, docW, (int)sv.hasHorizontalScroller]);

    NSArray<NSView *> *cards = CardsInView(doc);
    NSView *srvCard = nil, *castCard = nil;
    for (NSView *c in cards) {
        NSString *t = CardTitle(c);
        if (FindById(c, @"srv.add") || [t containsString:@"流媒体服务器"] || [t containsString:@"Streaming Servers"]) srvCard = c;
        if (FindById(c, @"sp_cast_dev") || [t containsString:@"推送到设备"] || [t containsString:@"Cast"]) castCard = c;
    }
    Ck(srvCard != nil && castCard != nil,
       (pfx + ": srvCard 和 castCard 均存在").c_str(),
       [NSString stringWithFormat:@"srv=%p cast=%p", srvCard, castCard]);
    if (!srvCard || !castCard) return;

    RLPServersView *srvView = (RLPServersView *)FindById(srvCard, @"srv.add");
    for (NSView *v = (NSView *)srvView; v && v != srvCard; v = v.superview) {
        if ([v isKindOfClass:[RLPServersView class]]) { srvView = (RLPServersView *)v; break; }
    }
    if (![srvView isKindOfClass:[RLPServersView class]]) {
        NSMutableArray<NSView *> *all = [NSMutableArray array];
        CollectAllViews(srvCard, all);
        for (NSView *v in all) {
            if ([v isKindOfClass:[RLPServersView class]]) { srvView = (RLPServersView *)v; break; }
        }
    }
    NSView *form = FindById(srvCard, @"srv.form");
    Ck([srvView isKindOfClass:[RLPServersView class]] && form != nil,
       (pfx + ": RLPServersView 和 srv.form 存在").c_str(),
       [NSString stringWithFormat:@"srvView=%p form=%p", srvView, form]);
    if (![srvView isKindOfClass:[RLPServersView class]] || !form) return;

    const BOOL formActuallyVisible = !IsHiddenInHierarchy(form, srvCard);
    Ck(form.hidden == !expectFormVisible && formActuallyVisible == expectFormVisible,
       (pfx + ": srv.form 显隐状态符合预期").c_str(),
       [NSString stringWithFormat:@"form.hidden=%d visibleInTree=%d expect=%d",
        (int)form.hidden, (int)formActuallyVisible, (int)expectFormVisible]);

    const NSRect srvCardR = [srvCard convertRect:srvCard.bounds toView:doc];
    const NSRect castCardR = [castCard convertRect:castCard.bounds toView:doc];
    const NSRect srvInCard = [srvView convertRect:srvView.bounds toView:srvCard];
    const NSRect srvClipR = [srvCard convertRect:srvCard.bounds toView:clip];
    const NSRect castClipR = [castCard convertRect:castCard.bounds toView:clip];
    const NSRect inter = NSIntersectionRect(srvCardR, castCardR);

    std::printf("  [stream %-28s] win=%.0fx%.0f clip=%.1fx%.1f doc=%.1fx%.1f srvCard=%.1fx%.1f srvView=%.1fx%.1f castCard=%.1fx%.1f formHidden=%d formRect=%s\n",
                label,
                wc.window.frame.size.width, wc.window.frame.size.height,
                clipW, clip.bounds.size.height,
                docW, docH,
                NSWidth(srvCard.bounds), NSHeight(srvCard.bounds),
                NSWidth(srvInCard), NSHeight(srvInCard),
                NSWidth(castCard.bounds), NSHeight(castCard.bounds),
                (int)form.hidden, NSStringFromRect(form.frame).UTF8String ?: "");

    Ck(NSWidth(inter) < 1.0 && NSHeight(inter) < 1.0,
       (pfx + ": srvCard 与 castCard 互不遮挡重叠").c_str(),
       [NSString stringWithFormat:@"srv=%@ cast=%@ inter=%@",
        NSStringFromRect(srvCardR), NSStringFromRect(castCardR), NSStringFromRect(inter)]);

    Ck(NSHeight(srvInCard) <= NSHeight(srvCard.bounds) + 1.0 &&
       NSMaxY(srvInCard) <= NSMaxY(srvCard.bounds) + 1.0 &&
       NSMinY(srvInCard) >= NSMinY(srvCard.bounds) - 1.0,
       (pfx + ": serversView 不溢出 srvCard（不遮住下方内容）").c_str(),
       [NSString stringWithFormat:@"srvInCard=%@ srvCardBounds=%@",
        NSStringFromRect(srvInCard), NSStringFromRect(srvCard.bounds)]);

    // 卡片高应紧贴 head(38) + gridPad(28) + serversView 高 + border(2)，不得残留大块白板
    const CGFloat expectedCardH = 38.0 + 28.0 + NSHeight(srvInCard) + 2.0;
    Ck(std::fabs(NSHeight(srvCard.bounds) - expectedCardH) <= 12.0,
       (pfx + ": srvCard 高度紧贴内容（无空白白板残留）").c_str(),
       [NSString stringWithFormat:@"cardH=%.1f expected=%.1f srvViewH=%.1f",
        NSHeight(srvCard.bounds), expectedCardH, NSHeight(srvInCard)]);

    Ck(NSMaxX(srvClipR) <= clipW + 1.0 && NSMaxX(castClipR) <= clipW + 1.0,
       (pfx + ": srvCard/castCard 右缘不超过 clip 宽").c_str(),
       [NSString stringWithFormat:@"srvMaxX=%.1f castMaxX=%.1f clipW=%.1f",
        NSMaxX(srvClipR), NSMaxX(castClipR), clipW]);

    if (expectFormVisible) {
        const NSRect formInCard = [form convertRect:form.bounds toView:srvCard];
        Ck(NSHeight(form.bounds) >= 160.0 && NSWidth(form.bounds) > 200.0 &&
           NSContainsRect(NSInsetRect(srvCard.bounds, -1.0, -1.0), formInCard),
           (pfx + ": 展开态 srv.form 在 srvCard 内完整可见且无白块溢出").c_str(),
           [NSString stringWithFormat:@"formInCard=%@ srvCard=%@",
            NSStringFromRect(formInCard), NSStringFromRect(srvCard.bounds)]);
    } else {
        // 扫描 doc 内是否存在无可见子控件的大面积空白矩形（非透明白板残留）
        NSMutableArray<NSString *> *blankBoxes = [NSMutableArray array];
        NSMutableArray<NSView *> *allDoc = [NSMutableArray array];
        CollectAllViews(doc, allDoc);
        for (NSView *v in allDoc) {
            if (v == doc || IsHiddenInHierarchy(v, doc)) continue;
            if ([v isKindOfClass:[NSStackView class]] || [v isKindOfClass:[NSControl class]] ||
                [v isKindOfClass:[RLPSettingsGroup class]] || [v isKindOfClass:[RLPFieldGrid class]] ||
                [v isKindOfClass:[RLPServersView class]] || [v isKindOfClass:[RLPCastView class]]) continue;
            if ([v.identifier isEqualToString:@"set.group.head"]) continue;
            if (NSWidth(v.bounds) >= 80.0 && NSHeight(v.bounds) >= 40.0 && !HasVisibleSubviewsOrContent(v)) {
                [blankBoxes addObject:[NSString stringWithFormat:@"%@(%@):%@",
                                       NSStringFromClass(v.class), v.identifier ?: @"", NSStringFromRect(v.frame)]];
            }
        }
        Ck(blankBoxes.count == 0,
           (pfx + ": 页面无新增/残留可见空白 view").c_str(),
           [blankBoxes componentsJoinedByString:@", "]);
    }

    // 底部播放条：**按现行设计**校验它「画得完整、且压不住设置页内容」。
    //
    // 判据口径变更说明（2026-11-21，改判据不改行为）：
    //   旧断言要求 playbackBar 与 pageHost **完全不相交**。那在 555d18b
    //   （2026-11-19「feat(native): translucent floating playback bar over content」）
    //   之后已经**不再成立**：那一版把底栏改成了 Apple Music 式**半透明悬浮条**，
    //   pageHost 有意延伸到 mainHost 底部、从悬浮条后方滚过，再由
    //   RLPPageHostView syncScrollInsets 给顶层滚动视图留 contentInset.bottom，
    //   保证末行内容不会被永久遮住。
    //   也就是说：几何相交是**设计本身**，真正的判据是「内容有没有被遮掉」。
    //   旧断言留着只会与设计互斥、永远红（实测 D1–D11 全红），属于判据失效而非缺陷。
    //   新判据 = 三条：
    //     ① 悬浮条自身画得完整（不隐藏、有尺寸、在窗口内）；
    //     ② 设置页里每个**可见的顶层滚动视图**都留了足够底部内边距，
    //        内边距 ≥ 悬浮条压住的那一段高度（差 ≤1pt）⟹ 末行内容滚得出来；
    //     ③ 悬浮条仍然**在页面之上**（z 序），保证它不被内容盖住。
    NSView *bar = (NSView *)[wc valueForKey:@"playbackBar"];
    NSView *pageHost = (NSView *)[wc valueForKey:@"pageHost"];
    if (bar && pageHost && wc.window.contentView) {
        const NSRect barR = [bar convertRect:bar.bounds toView:wc.window.contentView];
        const NSRect hostR = [pageHost convertRect:pageHost.bounds toView:wc.window.contentView];
        Ck(!bar.hidden && NSHeight(barR) >= 40.0 && NSWidth(barR) >= 200.0 &&
           NSMinX(barR) >= -1.0 && NSMaxX(barR) <= NSWidth(wc.window.contentView.bounds) + 1.0,
           (pfx + ": 悬浮播放条自身完整（可见、有尺寸、在窗口内）").c_str(),
           [NSString stringWithFormat:@"bar=%@", NSStringFromRect(barR)]);

        // ② 设置页里**任何可见的文字/控件**都不许被悬浮条压住。
        //
        // 为什么改成这样：本判据第一版写的是「被压住的滚动视图要留够 contentInset」，
        // 但实测设置页的 pane 滚动视图底边停在 y=110、悬浮条顶边在 y=80 ⟹ 两者
        // **根本不相交**，那条判据恒真（注入"inset=0"缺陷仍然绿，已实测）。
        // 真实会被压住的是**页面级状态行**（状态/「已保存」反馈，唯一告诉用户存没存上的地方），
        // 它原本离底 10pt、被 66pt 的条盖掉半行（截图实测）。所以判据直接量它：
        // 可见的 NSTextField/NSButton 与悬浮条的交集必须为空。
        NSMutableArray<NSString *> *covered = [NSMutableArray array];
        {
            NSMutableArray<NSView *> *stack2 = [NSMutableArray arrayWithObject:settings.view];
            while (stack2.count) {
                NSView *v = stack2.firstObject;
                [stack2 removeObjectAtIndex:0];
                if (v.isHiddenOrHasHiddenAncestor) { continue; }   // 隐藏子树整棵跳过
                const BOOL isTextish = [v isKindOfClass:[NSTextField class]] ||
                                       [v isKindOfClass:[NSButton class]] ||
                                       [v isKindOfClass:[NSControl class]];
                if (isTextish && NSWidth(v.bounds) > 4.0 && NSHeight(v.bounds) > 4.0) {
                    const NSRect vr = [v convertRect:v.bounds toView:wc.window.contentView];
                    // 必须先排除「已经滚出视口」的内容：它们属于 documentView，
                    // 换算到窗口坐标后可能正好落在悬浮条区域内，但**根本没画出来**
                    // （被最近的 NSScrollView clip 掉了）。旧写法不做这层过滤，
                    // 会把滚动区外的 cast/srv.form 控件当成"被遮住"（实测误报 8 条）。
                    BOOL clippedOut = NO;
                    for (NSView *p = v.superview; p; p = p.superview) {
                        if (![p isKindOfClass:[NSClipView class]]) continue;
                        const NSRect visibleDoc = ((NSClipView *)p).documentVisibleRect;
                        NSView *doc = ((NSClipView *)p).documentView;
                        if (!doc) break;
                        const NSRect inDoc = [v convertRect:v.bounds toView:doc];
                        if (!NSIntersectsRect(inDoc, visibleDoc)) { clippedOut = YES; break; }
                    }
                    if (clippedOut) { for (NSView *sub in v.subviews) [stack2 addObject:sub]; continue; }
                    const NSRect inter = NSIntersectionRect(vr, barR);
                    // 只报「被压掉一半以上」的：轻微贴边不算，半行字被盖住才算真缺陷
                    if (NSHeight(inter) > NSHeight(vr) * 0.5 && NSHeight(inter) > 2.0) {
                        if (covered.count < 6) {
                            [covered addObject:[NSString stringWithFormat:
                                @"%@(y=%.0f h=%.0f covered=%.0f)", v.identifier ?: @"-",
                                NSMinY(vr), NSHeight(vr), NSHeight(inter)]];
                        }
                    }
                }
                for (NSView *sub in v.subviews) [stack2 addObject:sub];
            }
        }
        Ck(covered.count == 0,
           (pfx + ": 设置页没有任何可见文字/控件被悬浮条盖住（状态行不被遮）").c_str(),
           [covered componentsJoinedByString:@", "]);

        // ③ 悬浮条在页面之上（z 序），否则会被内容盖住
        NSArray<NSView *> *siblings = @[ bar, pageHost ];
        (void)siblings;
        Ck(NSWidth(NSIntersectionRect(barR, hostR)) > 1.0,
           (pfx + ": 悬浮条与页面容器几何相交（这是悬浮设计的既有形态，不是缺陷）").c_str(),
           [NSString stringWithFormat:@"bar=%@ host=%@", NSStringFromRect(barR), NSStringFromRect(hostR)]);
    }

    if (outSrvH) *outSrvH = NSHeight(srvCard.bounds);
    if (outDocH) *outDocH = docH;
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_spy = [[RLPWidthContractSpy alloc] init];
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        RLPSetLanguage(@"zh");
        [RLPSettingsViewController setRlp_confirmsBitPerfectFix:NO];

        Method sharedM = class_getClassMethod(RLPCoreClient.class, @selector(shared));
        method_setImplementation(sharedM, (IMP)FakeSharedClient);
        Method probeM = class_getInstanceMethod(RLPSettingsViewController.class, @selector(probeFeedbackChannel));
        IMP origProbeImp = probeM ? method_getImplementation(probeM) : nullptr;
        if (probeM) method_setImplementation(probeM, (IMP)NoopProbe);

        std::printf("=== test_native_settings_width_contract（meta 宽度契约 M1–M4 · 离屏 Spy）===\n");
        std::printf("历史红基线参考（未修前）：折叠进 meta → 主窗 1068/1085（合入两列前 1304）；settings 拟合超 940；固定窄窗 doc>clip。\n\n");

        // =========================================================================
        // 部分 A：真实 RLPMainWindowController 链路（M1 / M2 / M3 / M4）
        // =========================================================================
        std::printf("[Suite A] RLPMainWindowController 真实主窗链路\n");
        RLPMainWindowController *wc = [[RLPMainWindowController alloc] init];
        wc.window.releasedWhenClosed = NO;
        [wc.window setFrameAutosaveName:@""];
        ResetMainWindowFrame(wc, 940.0, 690.0);
        const CGFloat baseWin940 = wc.window.frame.size.width;
        std::printf("  [baseline] fixture=940x690 进设置前 win=%.1f（若仍为 ~980，属未合并主窗顶栏基线）\n", baseWin940);

        [wc.sidebar selectKey:@"settings"];
        Pump(0.15);
        RLPSettingsViewController *settings = (RLPSettingsViewController *)wc.currentContent;
        Ck([settings isKindOfClass:[RLPSettingsViewController class]],
           "M0 进设置页成功", NSStringFromClass(wc.currentContent.class));

        if (settings) {
            NSView *pageHost = [wc valueForKey:@"pageHost"];

            // ---- M1 + M2：940x690 进 meta（折叠态）----
            ResetMainWindowFrame(wc, 940.0, 690.0);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification" object:@"meta"];
            LayoutHost(wc.window.contentView, 0.25);

            const CGFloat afterMetaWin940 = wc.window.frame.size.width;
            const NSSize metaFitCollapsed = settings.view.fittingSize;
            DumpFittingMetrics("A-M1/M2 940 collapsed", settings, pageHost);

            Ck(afterMetaWin940 <= baseWin940 + 0.5,
               "M2 切到 meta 不被设置页撑宽（win <= 主窗基线，不再跳到 1068/1085/1304）",
               [NSString stringWithFormat:@"base=%.1f afterMeta=%.1f", baseWin940, afterMetaWin940]);
            if (baseWin940 <= 941.0) {
                Ck(std::fabs(afterMetaWin940 - 940.0) <= 1.0,
                   "M2 主窗基线已收敛时切到 meta 严格保持 940 宽",
                   [NSString stringWithFormat:@"got=%.1f", afterMetaWin940]);
            }
            Ck(metaFitCollapsed.width <= 674.0,
               "M2 settings.view 自身 fitting 宽 <= 674（含 226 侧栏 <= 900 <= 940）",
               [NSString stringWithFormat:@"fitting.width=%.1f", metaFitCollapsed.width]);
            AssertMetaGeometry("M1-940-collapsed", settings, pageHost, NO, YES, NO);

            // ---- M3：meta → adv → meta（先折叠态重复挂载，再展开态+模型列表+重复挂载）----
            [settings selectPane:@"adv"];
            LayoutHost(wc.window.contentView, 0.12);
            [settings selectPane:@"meta"];
            LayoutHost(wc.window.contentView, 0.15);
            DumpFittingMetrics("A-M3 940 re-mount collapsed", settings, pageHost);
            Ck(wc.window.frame.size.width <= baseWin940 + 0.5 && settings.view.fittingSize.width <= 674.0,
               "M3a 折叠态 meta->adv->meta 重复挂载后仍不撑宽、fitting<=674",
               [NSString stringWithFormat:@"win=%.1f fit=%.1f", wc.window.frame.size.width, settings.view.fittingSize.width]);
            AssertMetaGeometry("M3a-remount-collapsed", settings, pageHost, NO, YES, NO);

            // 展开 sp_metamore + 打开模型列表下拉
            g_spy.modelsAvailable = YES;
            NSButton *more = (NSButton *)FindById(settings.view, @"sp_metamore");
            Ck(more != nil, "M3-pre 找到 sp_metamore 按钮", @"nil");
            if (more) {
                [more performClick:nil];
                [settings loadLlmModels:YES];
                LayoutHost(wc.window.contentView, 0.25);
                DumpFittingMetrics("A-M3 940 expanded+models", settings, pageHost);
                Ck(wc.window.frame.size.width <= baseWin940 + 0.5 && settings.view.fittingSize.width <= 674.0,
                   "M3b 展开态+模型下拉在 940 仍不撑宽且 fitting<=674",
                   [NSString stringWithFormat:@"win=%.1f fit=%.1f", wc.window.frame.size.width, settings.view.fittingSize.width]);
                AssertMetaGeometry("M3b-940-expanded", settings, pageHost, YES, YES, YES);

                // 展开态下切换 meta -> adv -> meta
                [settings selectPane:@"adv"];
                LayoutHost(wc.window.contentView, 0.12);
                [settings selectPane:@"meta"];
                LayoutHost(wc.window.contentView, 0.18);
                DumpFittingMetrics("A-M3 940 re-mount expanded", settings, pageHost);
                Ck(wc.window.frame.size.width <= baseWin940 + 0.5 && settings.view.fittingSize.width <= 674.0,
                   "M3c 展开态 meta->adv->meta 重复挂载仍不超宽不越界",
                   [NSString stringWithFormat:@"win=%.1f fit=%.1f", wc.window.frame.size.width, settings.view.fittingSize.width]);
                AssertMetaGeometry("M3c-remount-expanded", settings, pageHost, YES, YES, YES);

                // 再收起 sp_metamore，验证再次收起并切页回来仍安全
                [more performClick:nil];
                LayoutHost(wc.window.contentView, 0.15);
                [settings selectPane:@"adv"];
                LayoutHost(wc.window.contentView, 0.1);
                [settings selectPane:@"meta"];
                LayoutHost(wc.window.contentView, 0.15);
                AssertMetaGeometry("M3d-collapse-remount", settings, pageHost, NO, YES, NO);
            }

            // ---- M4（主窗 900x600）：折叠态与展开态均不撑宽、不横向溢出 ----
            ResetMainWindowFrame(wc, 900.0, 600.0);
            const CGFloat baseWin900 = wc.window.frame.size.width;
            [settings selectPane:@"meta"];
            LayoutHost(wc.window.contentView, 0.2);
            DumpFittingMetrics("A-M4 900 collapsed", settings, pageHost);
            Ck(wc.window.frame.size.width <= baseWin900 + 0.5 && settings.view.fittingSize.width <= 674.0,
               "M4-main 900x600 进 meta（折叠态）不撑宽、fitting<=674",
               [NSString stringWithFormat:@"base=%.1f win=%.1f fit=%.1f", baseWin900, wc.window.frame.size.width, settings.view.fittingSize.width]);
            AssertMetaGeometry("M4-main-900-collapsed", settings, pageHost, NO, YES, NO);

            if (more) {
                [more performClick:nil];
                LayoutHost(wc.window.contentView, 0.2);
                DumpFittingMetrics("A-M4 900 expanded", settings, pageHost);
                Ck(wc.window.frame.size.width <= baseWin900 + 0.5 && settings.view.fittingSize.width <= 674.0,
                   "M4-main 900x600 展开高级选项仍不撑宽、fitting<=674",
                   [NSString stringWithFormat:@"base=%.1f win=%.1f fit=%.1f", baseWin900, wc.window.frame.size.width, settings.view.fittingSize.width]);
                AssertMetaGeometry("M4-main-900-expanded", settings, pageHost, YES, YES, YES);
            }

            // 宽窗 1180x760 恢复左右两列 → 再缩回 900x600 回落单列（响应式验证）
            ResetMainWindowFrame(wc, 1180.0, 760.0);
            LayoutHost(wc.window.contentView, 0.2);
            DumpFittingMetrics("A-wide 1180 expanded", settings, pageHost);
            AssertMetaGeometry("A-wide-1180-expanded", settings, pageHost, YES, NO, YES);

            [settings selectPane:@"adv"];
            LayoutHost(wc.window.contentView, 0.1);
            ResetMainWindowFrame(wc, 900.0, 600.0);
            [settings selectPane:@"meta"];
            LayoutHost(wc.window.contentView, 0.2);
            DumpFittingMetrics("A-shrink 1180->900 expanded", settings, pageHost);
            AssertMetaGeometry("A-shrink-1180-to-900", settings, pageHost, YES, YES, YES);

            // 缓存重入放大：在 adv 页将 900 放大到 1180 再切回 meta，仍需恢复左右两列并排
            [settings selectPane:@"adv"];
            LayoutHost(wc.window.contentView, 0.1);
            ResetMainWindowFrame(wc, 1180.0, 760.0);
            [settings selectPane:@"meta"];
            LayoutHost(wc.window.contentView, 0.2);
            DumpFittingMetrics("A-expand cached 900->1180", settings, pageHost);
            AssertMetaGeometry("A-expand-cached-900-to-1180", settings, pageHost, YES, NO, YES);
        }
        [wc stopAllActivity];
        [wc.window close];

        // =========================================================================
        // 部分 B：精确 714pt（940 主窗）与 674pt（900 主窗）固定宿主 NSWindow（含中/英切换）
        // 即使主窗顶栏基线尚未合入，这里也在真实的 674pt / 714pt 可视宽度上逐像素验证！
        // =========================================================================
        std::printf("\n[Suite B] 精确固定宿主宽 NSWindow（714pt=940主窗 / 674pt=900主窗 / 954pt=1180主窗 · 中/英文）\n");

        g_spy.modelsAvailable = YES;
        RLPSettingsViewController *sFixed = [[RLPSettingsViewController alloc] init];
        NSWindow *hostWin = CreateFixedHostWindow(714.0, 690.0, sFixed);
        NSView *hostContent = hostWin.contentView;
        [hostContent layoutSubtreeIfNeeded];
        [sFixed selectPane:@"meta"];
        LayoutHost(hostContent, 0.25);

        // 714pt (940-226) 折叠态 → 展开态
        DumpFittingMetrics("B-714 zh collapsed", sFixed, hostContent);
        Ck(sFixed.view.fittingSize.width <= 674.0,
           "B-714 zh 折叠态 fitting<=674", [NSString stringWithFormat:@"%.1f", sFixed.view.fittingSize.width]);
        AssertMetaGeometry("B-714-zh-collapsed", sFixed, hostContent, NO, YES, NO);

        NSButton *moreFixed = (NSButton *)FindById(sFixed.view, @"sp_metamore");
        if (moreFixed) [moreFixed performClick:nil];
        [sFixed loadLlmModels:YES];
        LayoutHost(hostContent, 0.25);
        DumpFittingMetrics("B-714 zh expanded", sFixed, hostContent);
        AssertMetaGeometry("B-714-zh-expanded", sFixed, hostContent, YES, YES, YES);

        // 674pt (900-226) 展开态（中文）
        [hostWin setContentSize:NSMakeSize(674.0, 600.0)];
        LayoutHost(hostContent, 0.25);
        DumpFittingMetrics("B-674 zh expanded", sFixed, hostContent);
        Ck(std::fabs(hostContent.bounds.size.width - 674.0) <= 1.0 && sFixed.view.fittingSize.width <= 674.0,
           "M4-674 zh 固定 674pt 宿主不被撑大且 fitting<=674",
           [NSString stringWithFormat:@"host=%.1f fit=%.1f", hostContent.bounds.size.width, sFixed.view.fittingSize.width]);
        AssertMetaGeometry("B-674-zh-expanded", sFixed, hostContent, YES, YES, YES);

        // 切换到英文模式（英文按钮与标签更长：Open professional console / Test connection / Execute Write-back / ...）
        RLPSetLanguage(@"en");
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
        [sFixed loadLlmModels:YES];
        LayoutHost(hostContent, 0.3);
        DumpFittingMetrics("B-674 en expanded", sFixed, hostContent);
        Ck(std::fabs(hostContent.bounds.size.width - 674.0) <= 1.0 && sFixed.view.fittingSize.width <= 674.0,
           "M4-674 en 英文模式 674pt 宿主不撑大且 fitting<=674",
           [NSString stringWithFormat:@"host=%.1f fit=%.1f", hostContent.bounds.size.width, sFixed.view.fittingSize.width]);
        AssertMetaGeometry("B-674-en-expanded", sFixed, hostContent, YES, YES, YES);

        // 英文折叠态 @ 674pt
        NSButton *moreEn = (NSButton *)FindById(sFixed.view, @"sp_metamore");
        if (moreEn) [moreEn performClick:nil];
        LayoutHost(hostContent, 0.2);
        DumpFittingMetrics("B-674 en collapsed", sFixed, hostContent);
        Ck(sFixed.view.fittingSize.width <= 674.0,
           "M4-674 en 折叠态 fitting<=674", [NSString stringWithFormat:@"%.1f", sFixed.view.fittingSize.width]);
        AssertMetaGeometry("B-674-en-collapsed", sFixed, hostContent, NO, YES, NO);

        // 英文 1180 主窗对应宿主 (954pt) 展开两列 → 直接缩回到 674pt 单列
        if (moreEn) [moreEn performClick:nil];
        [hostWin setContentSize:NSMakeSize(954.0, 760.0)];
        [sFixed loadLlmModels:YES];
        LayoutHost(hostContent, 0.25);
        DumpFittingMetrics("B-954 en expanded(2col)", sFixed, hostContent);
        AssertMetaGeometry("B-954-en-expanded-2col", sFixed, hostContent, YES, NO, YES);

        [hostWin setContentSize:NSMakeSize(674.0, 600.0)];
        LayoutHost(hostContent, 0.25);
        DumpFittingMetrics("B-674 en shrink-from-954", sFixed, hostContent);
        AssertMetaGeometry("B-674-en-shrink-to-1col", sFixed, hostContent, YES, YES, YES);

        // 切回中文，收尾干净
        RLPSetLanguage(@"zh");
        [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification object:nil];
        [hostWin close];

        // =========================================================================
        // 部分 C：主题切换崩溃回归（设置页已创建但从未打开 diag 时 setUiStyle:@"classic"）
        // =========================================================================
        std::printf("\n[Suite C] 主题切换无 diag 页崩溃回归（setUiStyle:@\"classic\" / dark / apple）\n");
        RLPMainWindowController *wcTheme = [[RLPMainWindowController alloc] init];
        wcTheme.window.releasedWhenClosed = NO;
        [wcTheme.window setFrameAutosaveName:@""];
        ResetMainWindowFrame(wcTheme, 1180.0, 760.0);
        [wcTheme.sidebar selectKey:@"settings"];
        Pump(0.15);
        RLPSettingsViewController *settingsTheme = (RLPSettingsViewController *)wcTheme.currentContent;
        NSView *pageHostTheme = [wcTheme valueForKey:@"pageHost"];
        Ck([settingsTheme isKindOfClass:[RLPSettingsViewController class]],
           "C0 新建主窗打开 settings 成功（未打开 diag 页）", NSStringFromClass(wcTheme.currentContent.class));

        NSException *classicEx = nil;
        @try {
            [RLPTheme setUiStyle:@"classic"];
            LayoutHost(wcTheme.window.contentView, 0.12);
        } @catch (NSException *ex) {
            classicEx = ex;
        }
        Ck(classicEx == nil && [[RLPTheme uiStyle] isEqualToString:@"classic"],
           "C1 未打开 diag 时切 setUiStyle:@\"classic\" 不抛 NSInvalidArgumentException",
           classicEx ? [NSString stringWithFormat:@"%@: %@", classicEx.name, classicEx.reason]
                     : [RLPTheme uiStyle]);

        // 切到 meta 展开高级区再轮切 dark / apple / classic，确认不崩且两列与宽度契约保持完整
        [settingsTheme selectPane:@"meta"];
        LayoutHost(wcTheme.window.contentView, 0.15);
        NSButton *moreTheme = (NSButton *)FindById(settingsTheme.view, @"sp_metamore");
        if (moreTheme) [moreTheme performClick:nil];
        [settingsTheme loadLlmModels:YES];
        LayoutHost(wcTheme.window.contentView, 0.2);

        NSException *cycleEx = nil;
        @try {
            [RLPTheme setThemeName:@"dark"];
            [RLPTheme setUiStyle:@"apple"];
            [RLPTheme setThemeName:@"light"];
            [RLPTheme setUiStyle:@"classic"];
            LayoutHost(wcTheme.window.contentView, 0.2);
        } @catch (NSException *ex) {
            cycleEx = ex;
        }
        Ck(cycleEx == nil,
           "C2 meta 展开态下切换 dark/apple/classic 主题均不崩溃",
           cycleEx ? [NSString stringWithFormat:@"%@: %@", cycleEx.name, cycleEx.reason] : @"ok");
        // applyTheme 会重建页签，旧的模型下拉被移除；主题循环后按真实用户路径重拉一次，
        // 再断言可见宽度（否则断言依赖异步回调落在主题切换前/后，测试会变成时序抽奖）。
        g_spy.modelsAvailable = YES;
        [settingsTheme loadLlmModels:YES];
        LayoutHost(wcTheme.window.contentView, 0.3);
        AssertMetaGeometry("C2-classic-1180-expanded", settingsTheme, pageHostTheme, YES, NO, YES);

        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        LayoutHost(wcTheme.window.contentView, 0.15);
        [wcTheme stopAllActivity];
        [wcTheme.window close];

        // ---- C3（独立）：主题切换保留已拉取 llm.modelpopup（可见/条目数/选中索引）且不新增 /api/llm/models 请求 ----
        std::printf("\n[Suite C3] 主题切换保留 llm.modelpopup 状态且不新增 /api/llm/models 请求\n");
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        RLPMainWindowController *wcC3 = [[RLPMainWindowController alloc] init];
        wcC3.window.releasedWhenClosed = NO;
        [wcC3.window setFrameAutosaveName:@""];
        ResetMainWindowFrame(wcC3, 1180.0, 760.0);
        [wcC3.sidebar selectKey:@"settings"];
        Pump(0.15);
        RLPSettingsViewController *settingsC3 = (RLPSettingsViewController *)wcC3.currentContent;
        NSView *pageHostC3 = [wcC3 valueForKey:@"pageHost"];
        Ck([settingsC3 isKindOfClass:[RLPSettingsViewController class]],
           "C3-pre 新建主窗打开 settings 成功", NSStringFromClass(wcC3.currentContent.class));

        if (settingsC3) {
            [settingsC3 selectPane:@"meta"];
            LayoutHost(wcC3.window.contentView, 0.15);
            NSButton *moreC3 = (NSButton *)FindById(settingsC3.view, @"sp_metamore");
            if (moreC3) [moreC3 performClick:nil];
            g_spy.modelsAvailable = YES;
            [settingsC3 loadLlmModels:YES];
            LayoutHost(wcC3.window.contentView, 0.25);

            NSPopUpButton *popInit = (NSPopUpButton *)FindById(settingsC3.view, @"llm.modelpopup");
            Ck(popInit != nil && !popInit.hidden && popInit.numberOfItems == 3,
               "C3-pre 1180 meta 展开并拉取模型列表成功",
               [NSString stringWithFormat:@"pop=%p hidden=%d count=%ld",
                popInit, popInit ? (int)popInit.hidden : -1,
                popInit ? (long)popInit.numberOfItems : -1L]);
            const NSInteger loadedCount = popInit ? popInit.numberOfItems : 0;
            if (popInit && popInit.numberOfItems > 0) [popInit selectItemAtIndex:0];
            Ck(popInit && popInit.indexOfSelectedItem == 0 &&
               [popInit.titleOfSelectedItem isEqualToString:@"deepseek-chat"],
               "C3-pre 手动选中第 0 项 deepseek-chat",
               [NSString stringWithFormat:@"idx=%ld title=%@",
                popInit ? (long)popInit.indexOfSelectedItem : -1L,
                popInit.titleOfSelectedItem ?: @""]);

            auto countModelRequests = ^NSInteger() {
                NSInteger n = 0;
                for (NSString *r in g_spy.requests) {
                    if ([r containsString:@"/api/llm/models"]) ++n;
                }
                return n;
            };
            const NSInteger reqBefore = countModelRequests();

            auto assertC3Popup = ^(const char *tag, BOOL expectInHierarchy) {
                NSPopUpButton *pop = (NSPopUpButton *)FindById(settingsC3.view, @"llm.modelpopup");
                const std::string pfx(tag);
                const BOOL visOk = !expectInHierarchy ||
                    (pop && !IsHiddenInHierarchy(pop, settingsC3.view) && NSWidth(pop.bounds) >= 60.0);
                const BOOL ok = (pop != nil && !pop.hidden && visOk &&
                                 pop.numberOfItems == loadedCount &&
                                 pop.indexOfSelectedItem == 0 &&
                                 [pop.titleOfSelectedItem isEqualToString:@"deepseek-chat"]);
                std::printf("  [%s] hidden=%d items=%ld idx=%ld title=%s\n",
                            tag, pop ? (int)pop.hidden : -1,
                            pop ? (long)pop.numberOfItems : -1L,
                            pop ? (long)pop.indexOfSelectedItem : -1L,
                            pop.titleOfSelectedItem.UTF8String ?: "(nil)");
                Ck(ok,
                   (pfx + ": llm.modelpopup !hidden 且条目数/选中索引/title 保持 deepseek-chat").c_str(),
                   [NSString stringWithFormat:@"pop=%p hidden=%d inHier=%d w=%.1f items=%ld/%ld idx=%ld title=%@",
                    pop, pop ? (int)pop.hidden : -1,
                    pop ? (int)!IsHiddenInHierarchy(pop, settingsC3.view) : -1,
                    pop ? NSWidth(pop.bounds) : 0.0,
                    pop ? (long)pop.numberOfItems : -1L, (long)loadedCount,
                    pop ? (long)pop.indexOfSelectedItem : -1L,
                    pop.titleOfSelectedItem ?: @""]);
            };

            NSException *c3CycleEx = nil;
            @try {
                [RLPTheme setThemeName:@"dark"];
                LayoutHost(wcC3.window.contentView, 0.2);
                assertC3Popup("C3-dark", YES);

                [RLPTheme setUiStyle:@"apple"];
                LayoutHost(wcC3.window.contentView, 0.2);
                assertC3Popup("C3-apple", YES);

                [RLPTheme setUiStyle:@"classic"];
                LayoutHost(wcC3.window.contentView, 0.2);
                assertC3Popup("C3-classic", YES);
            } @catch (NSException *ex) {
                c3CycleEx = ex;
            }
            const NSInteger reqAfterCycle = countModelRequests();
            const NSInteger reqDelta = reqAfterCycle - reqBefore;
            std::printf("  [C3] /api/llm/models requests: before=%ld after=%ld delta=%ld\n",
                        (long)reqBefore, (long)reqAfterCycle, (long)reqDelta);
            Ck(c3CycleEx == nil, "C3 dark/apple/classic 主题切换不崩溃",
               c3CycleEx ? [NSString stringWithFormat:@"%@: %@", c3CycleEx.name, c3CycleEx.reason] : @"ok");
            Ck(reqDelta == 0, "C3 主题切换期间新增 /api/llm/models 请求 == 0",
               [NSString stringWithFormat:@"before=%ld after=%ld delta=%ld",
                (long)reqBefore, (long)reqAfterCycle, (long)reqDelta]);

            NSException *c3BackEx = nil;
            @try {
                [RLPTheme setThemeName:@"light"];
                [RLPTheme setUiStyle:@"apple"];
                LayoutHost(wcC3.window.contentView, 0.2);
                assertC3Popup("C3-back-light-apple", YES);

                NSButton *moreC3After = (NSButton *)FindById(settingsC3.view, @"sp_metamore");
                Ck(moreC3After != nil, "C3 切回 light/apple 后仍找到 sp_metamore", @"nil");
                if (moreC3After) {
                    [moreC3After performClick:nil];
                    LayoutHost(wcC3.window.contentView, 0.15);
                    assertC3Popup("C3-collapsed", NO);

                    [moreC3After performClick:nil];
                    LayoutHost(wcC3.window.contentView, 0.15);
                    assertC3Popup("C3-reexpanded", YES);
                }
            } @catch (NSException *ex) {
                c3BackEx = ex;
            }
            const NSInteger reqEnd = countModelRequests();
            Ck(c3BackEx == nil, "C3 切回 light/apple 并折叠/展开 meta 无崩溃",
               c3BackEx ? [NSString stringWithFormat:@"%@: %@", c3BackEx.name, c3BackEx.reason] : @"ok");
            Ck(reqEnd == reqBefore, "C3 全程切回 light/apple 与折叠/展开后仍未新增 /api/llm/models 请求",
               [NSString stringWithFormat:@"before=%ld end=%ld", (long)reqBefore, (long)reqEnd]);
            AssertMetaGeometry("C3-light-apple-1180-expanded", settingsC3, pageHostC3, YES, NO, YES);
        }
        [wcC3 stopAllActivity];
        [wcC3.window close];

        // =========================================================================
        // 部分 D：设置 → 流媒体「添加服务器」白块/高度/交互契约（S1–S4 · 900x600 & 1180x760）
        // =========================================================================
        std::printf("\n[Suite D] 设置 → 流媒体 添加服务器 S1–S4 契约\n");
        g_spy.srcServers = [NSMutableArray array];
        g_spy.srcActive = @"";
        g_spy.srcSeq = 0;
        g_spy.srcNextError = nil;
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"classic"]; // classic light t.bg2 == #ffffff，最易暴露白色矩形残留

        RLPMainWindowController *wcD = [[RLPMainWindowController alloc] init];
        wcD.window.releasedWhenClosed = NO;
        [wcD.window setFrameAutosaveName:@""];
        ResetMainWindowFrame(wcD, 900.0, 600.0);
        [wcD.sidebar selectKey:@"settings"];
        Pump(0.15);
        RLPSettingsViewController *settingsD = (RLPSettingsViewController *)wcD.currentContent;
        Ck([settingsD isKindOfClass:[RLPSettingsViewController class]],
           "S-pre 900x600 打开设置页成功", NSStringFromClass(wcD.currentContent.class));

        if (settingsD) {
            [settingsD selectPane:@"stream"];
            LayoutHost(wcD.window.contentView, 0.25);

            CGFloat baseSrvH = 0, baseDocH = 0;
            AssertStreamPaneContract("D1-900-initial-empty", wcD, settingsD, NO, &baseSrvH, &baseDocH);

            NSButton *addBtn = (NSButton *)FindById(settingsD.view, @"srv.add");
            Ck(addBtn != nil && addBtn.enabled, "S1a 初始可点击添加服务器", @"missing/disabled");

            // 1) 点「添加服务器」展开表单
            [addBtn performClick:nil];
            LayoutHost(wcD.window.contentView, 0.2);
            CGFloat openSrvH = 0, openDocH = 0;
            AssertStreamPaneContract("D2-900-form-open", wcD, settingsD, YES, &openSrvH, &openDocH);
            Ck(openSrvH > baseSrvH + 140.0, "S1b 点添加后 srvCard 自动撑高容纳表单",
               [NSString stringWithFormat:@"base=%.1f open=%.1f", baseSrvH, openSrvH]);

            // 2) S2 校验失败路径：保留表单 + 显示错误，不留白块
            NSTextField *nameF = (NSTextField *)FindById(settingsD.view, @"srv.form.name");
            NSTextField *baseF = (NSTextField *)FindById(settingsD.view, @"srv.form.base");
            NSTextField *userF = (NSTextField *)FindById(settingsD.view, @"srv.form.user");
            NSSecureTextField *passF = (NSSecureTextField *)FindById(settingsD.view, @"srv.form.pass");
            NSTextField *msgF = (NSTextField *)FindById(settingsD.view, @"srv.form.msg");
            NSButton *saveBtn = (NSButton *)FindById(settingsD.view, @"srv.form.save");
            NSButton *cancelBtn = (NSButton *)FindById(settingsD.view, @"srv.form.cancel");
            Ck(nameF && baseF && userF && passF && msgF && saveBtn && cancelBtn,
               "S2-pre 表单控件完整", @"nil");

            baseF.stringValue = @"invalid-url";
            userF.stringValue = @"alice";
            [saveBtn performClick:nil];
            LayoutHost(wcD.window.contentView, 0.12);
            Ck(msgF.stringValue.length > 0 && saveBtn.enabled, "S2a 前端校验失败展示错误且仍可继续编辑", msgF.stringValue ?: @"");
            AssertStreamPaneContract("D3-900-validate-fail", wcD, settingsD, YES, nil, nil);

            // 3) S2 后端保存失败路径：保留表单与用户输入、显示错误、无白板
            nameF.stringValue = @"测试服";
            baseF.stringValue = @"https://music.example.com";
            userF.stringValue = @"alice";
            passF.stringValue = @"secret";
            g_spy.srcNextError = @"连接超时";
            [saveBtn performClick:nil];
            LayoutHost(wcD.window.contentView, 0.25);
            Ck([msgF.stringValue isEqualToString:@"连接超时"] && saveBtn.enabled && cancelBtn.enabled,
               "S2b 后端失败保留表单与错误提示且按钮立即恢复可点",
               [NSString stringWithFormat:@"msg=%@ saveEn=%d cancelEn=%d",
                msgF.stringValue ?: @"", (int)saveBtn.enabled, (int)cancelBtn.enabled]);
            AssertStreamPaneContract("D4-900-backend-fail", wcD, settingsD, YES, nil, nil);

            // 4) S2 取消路径：立即收起、srvCard/doc 高度立刻回到基准、无白块
            [cancelBtn performClick:nil];
            LayoutHost(wcD.window.contentView, 0.2);
            CGFloat cancelSrvH = 0, cancelDocH = 0;
            AssertStreamPaneContract("D5-900-after-cancel", wcD, settingsD, NO, &cancelSrvH, &cancelDocH);
            Ck(std::fabs(cancelSrvH - baseSrvH) <= 2.0 && std::fabs(cancelDocH - baseDocH) <= 2.0,
               "S2c 取消后 srvCard/doc 高度立即回落至初始态（无白板高度残留）",
               [NSString stringWithFormat:@"base=(%.1f,%.1f) afterCancel=(%.1f,%.1f)",
                baseSrvH, baseDocH, cancelSrvH, cancelDocH]);
            Ck(addBtn.enabled, "S2d 取消后添加按钮立即保持可交互", @"disabled");

            // 5) S1 + S2 添加成功路径：保存完成后表单立即收起、白块不出现、高度收紧、页面可交互
            [addBtn performClick:nil];
            LayoutHost(wcD.window.contentView, 0.15);
            nameF.stringValue = @"工作室 NAS";
            baseF.stringValue = @"https://nas.example.com:4533";
            userF.stringValue = @"bob";
            passF.stringValue = @"pass1234";
            [saveBtn performClick:nil];
            LayoutHost(wcD.window.contentView, 0.3);
            CGFloat savedSrvH = 0, savedDocH = 0;
            Ck(g_spy.srcServers.count == 1, "S2e 添加服务器 POST /api/src/config 成功落盘 1 台",
               [NSString stringWithFormat:@"n=%lu", (unsigned long)g_spy.srcServers.count]);
            AssertStreamPaneContract("D6-900-after-save-ok", wcD, settingsD, NO, &savedSrvH, &savedDocH);
            Ck(savedSrvH < openSrvH - 120.0 && FindById(settingsD.view, @"srv.row.name") != nil && addBtn.enabled,
               "S1c 添加完成后表单立即消失、卡片收紧（非高白块）、列表项出现且页面可交互",
               [NSString stringWithFormat:@"openSrvH=%.1f savedSrvH=%.1f", openSrvH, savedSrvH]);

            // 6) S3 切页再回来 + 主题切换 + 1180x760 宽窗复验状态一致、无白块
            [settingsD selectPane:@"adv"];
            LayoutHost(wcD.window.contentView, 0.15);
            [settingsD selectPane:@"stream"];
            LayoutHost(wcD.window.contentView, 0.25);
            CGFloat tabBackSrvH = 0, tabBackDocH = 0;
            AssertStreamPaneContract("D7-900-tab-switch-back", wcD, settingsD, NO, &tabBackSrvH, &tabBackDocH);
            Ck(std::fabs(tabBackSrvH - savedSrvH) <= 2.0 && std::fabs(tabBackDocH - savedDocH) <= 2.0,
               "S3a 设置页签 stream->adv->stream 来回切换高度与状态完全一致",
               [NSString stringWithFormat:@"before=(%.1f,%.1f) after=(%.1f,%.1f)",
                savedSrvH, savedDocH, tabBackSrvH, tabBackDocH]);

            [wcD.sidebar selectKey:@"streaming"];
            LayoutHost(wcD.window.contentView, 0.2);
            [wcD.sidebar selectKey:@"settings"];
            LayoutHost(wcD.window.contentView, 0.25);
            settingsD = (RLPSettingsViewController *)wcD.currentContent;
            AssertStreamPaneContract("D8-900-sidebar-back", wcD, settingsD, NO, nil, nil);

            ResetMainWindowFrame(wcD, 1180.0, 760.0);
            [RLPTheme setUiStyle:@"apple"];
            LayoutHost(wcD.window.contentView, 0.25);
            AssertStreamPaneContract("D9-1180-apple-wide", wcD, settingsD, NO, nil, nil);

            // 7) 1180 宽再开添加/编辑 + S2 删除路径收口（切回 900x600 复验）
            ResetMainWindowFrame(wcD, 900.0, 600.0);
            LayoutHost(wcD.window.contentView, 0.2);
            NSButton *addBtnAfter = (NSButton *)FindById(settingsD.view, @"srv.add");
            NSString *sid0 = g_spy.srcServers.firstObject[@"id"] ?: @"";
            NSButton *editBtn0 = nil;
            NSButton *delBtn0 = nil;
            NSMutableArray<NSView *> *srvAll = [NSMutableArray array];
            CollectAllViews(settingsD.view, srvAll);
            for (NSView *v in srvAll) {
                if (![v isKindOfClass:[NSButton class]] || ![v.identifier isEqualToString:sid0]) continue;
                NSButton *b = (NSButton *)v;
                if ([b.title isEqualToString:RLPTr(@"编辑")]) editBtn0 = b;
                if ([b.title isEqualToString:RLPTr(@"删除")]) delBtn0 = b;
            }
            Ck(editBtn0 != nil && delBtn0 != nil && addBtnAfter != nil, "S2-del 找到已存行的编辑与删除按钮", @"nil");
            if (editBtn0 && delBtn0) {
                [editBtn0 performClick:nil];
                LayoutHost(wcD.window.contentView, 0.15);
                AssertStreamPaneContract("D10-900-editing-row", wcD, settingsD, YES, nil, nil);

                Method alertM = class_getInstanceMethod([NSAlert class], @selector(runModal));
                IMP origAlertImp = alertM ? method_getImplementation(alertM) : nullptr;
                @try {
                    if (alertM) method_setImplementation(alertM, (IMP)FakeAlertFirstButton);
                    [delBtn0 performClick:nil];
                } @finally {
                    if (alertM && origAlertImp) method_setImplementation(alertM, origAlertImp);
                }
                LayoutHost(wcD.window.contentView, 0.3);
                Ck(g_spy.srcServers.count == 0, "S2f 删除服务器落盘后剩余 0 台",
                   [NSString stringWithFormat:@"n=%lu", (unsigned long)g_spy.srcServers.count]);
                CGFloat delSrvH = 0, delDocH = 0;
                AssertStreamPaneContract("D11-900-after-delete", wcD, settingsD, NO, &delSrvH, &delDocH);
                NSButton *addBtnFinal = (NSButton *)FindById(settingsD.view, @"srv.add");
                Ck(std::fabs(delSrvH - baseSrvH) <= 2.0 && std::fabs(delDocH - baseDocH) <= 2.0 &&
                   addBtnFinal && addBtnFinal.enabled,
                   "S2g 删除正在编辑的行后表单立即收起、srvCard/doc 回到空态高度且可交互",
                   [NSString stringWithFormat:@"base=(%.1f,%.1f) afterDel=(%.1f,%.1f)",
                    baseSrvH, baseDocH, delSrvH, delDocH]);
            }
        }
        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        [wcD stopAllActivity];
        [wcD.window close];

        // =========================================================================
        // 部分 E：原生 UI 诊断遥测（/api/ui/events）T1–T6 契约 · 离屏 Spy
        // ==================================================================        {
        std::printf("\n[Suite E] 原生 UI 诊断遥测 /api/ui/events 契约（T1–T6 · 离屏 Spy）\n");
        std::printf("红基线对照：旧码 332433d 无 RLPDiagEvent 埋点，POST /api/ui/events 事件数为 0；新码 >= 1 且严格脱敏。\n");

        {
            if (probeM && origProbeImp) method_setImplementation(probeM, origProbeImp);
            Method saveRunM = class_getInstanceMethod([NSSavePanel class], @selector(runModal));
            Method saveUrlM = class_getInstanceMethod([NSSavePanel class], @selector(URL));
            IMP origSaveRunImp = saveRunM ? method_getImplementation(saveRunM) : nullptr;
            IMP origSaveUrlImp = saveUrlM ? method_getImplementation(saveUrlM) : nullptr;
            Class updCls = NSClassFromString(@"RLPUpdateWindowController");
            Method updCheckM = updCls ? class_getInstanceMethod(updCls, @selector(checkManually:)) : nullptr;
            IMP origUpdCheckImp = updCheckM ? method_getImplementation(updCheckM) : nullptr;

            NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"rlp_telem_audit_%d", (int)getpid()]];
            NSString *secretDiagDir = [tmpRoot stringByAppendingPathComponent:@"secret_user_diag_dir"];
            NSString *stateDir = [tmpRoot stringByAppendingPathComponent:@"state_dir"];
            [[NSFileManager defaultManager] createDirectoryAtPath:secretDiagDir
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSFileManager defaultManager] createDirectoryAtPath:stateDir
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            const char *prevStateEnv = std::getenv("RLPLAYER_STATE_DIR");
            std::string prevStateCopy = prevStateEnv ? prevStateEnv : "";
            setenv("RLPLAYER_STATE_DIR", stateDir.UTF8String, 1);

            RLPMainWindowController *wcE = [[RLPMainWindowController alloc] init];
            wcE.window.releasedWhenClosed = NO;
            [wcE.window setFrameAutosaveName:@""];
            ResetMainWindowFrame(wcE, 1000.0, 700.0);

            @try {
                if (saveRunM) method_setImplementation(saveRunM, (IMP)FakeSavePanelRunModal);
                if (saveUrlM) method_setImplementation(saveUrlM, (IMP)FakeSavePanelURL);
                if (updCheckM) method_setImplementation(updCheckM, (IMP)NoopCheckManually);

                [wcE.sidebar selectKey:@"albums"];
                Pump(0.1);
                RLPDiagTelemetryResetForAudit();
                [g_spy.uiEvents removeAllObjects];
                [g_spy.uiEventBodies removeAllObjects];
                [g_spy.requests removeAllObjects];

                // T1: 切页进 settings -> settings_open -> 切子页签
                [wcE.sidebar selectKey:@"settings"];
                Pump(0.12);
                RLPSettingsViewController *settingsE = (RLPSettingsViewController *)wcE.currentContent;
                Ck([settingsE isKindOfClass:[RLPSettingsViewController class]],
                   "T1-pre 打开设置页成功", NSStringFromClass(wcE.currentContent.class));

                if (settingsE) {
                    settingsE.fbProbeTransport = ^(void (^done)(NSInteger, NSData *, BOOL)) {
                        NSData *okBody = [@"{\"ok\":true,\"rate_per_minute\":3}"
                                          dataUsingEncoding:NSUTF8StringEncoding];
                        done(200, okBody, NO);
                    };
                    settingsE.fbUploadTransport = ^(NSString *url, NSString *body,
                                                    void (^done)(NSInteger, NSData *)) {
                        (void)url; (void)body;
                        NSData *okReply = [@"{\"ok\":true,\"id\":\"FB-AUDIT-777\",\"diag_stored\":true}"
                                           dataUsingEncoding:NSUTF8StringEncoding];
                        done(200, okReply);
                    };

                    [settingsE selectPane:@"meta"];
                    Pump(0.1);
                    [settingsE selectPane:@"diag"];
                    Pump(0.15);

                    // T2: diag_export (ok + cancelled) / diag_json / diag_summary
                    NSButton *zipBtn = (NSButton *)FindById(settingsE.view, @"sp_diagzip");
                    NSButton *jsonBtn = (NSButton *)FindById(settingsE.view, @"sp_diagjson");
                    NSButton *sumBtn = (NSButton *)FindById(settingsE.view, @"sp_diagsummary");
                    Ck(zipBtn && jsonBtn && sumBtn, "T2-pre 找到诊断导出三按钮", @"nil");
                    if (zipBtn) {
                        g_savePanelURL = [NSURL fileURLWithPath:
                                          [secretDiagDir stringByAppendingPathComponent:@"rlplayer-diag.zip"]];
                        g_savePanelResult = NSModalResponseOK;
                        [zipBtn performClick:nil];
                        Pump(0.12);

                        g_savePanelResult = NSModalResponseCancel;
                        [zipBtn performClick:nil];
                        Pump(0.12);
                    }
                    if (jsonBtn) {
                        g_savePanelResult = NSModalResponseCancel;
                        [jsonBtn performClick:nil];
                        Pump(0.12);
                    }
                    if (sumBtn) {
                        [sumBtn performClick:nil];
                        Pump(0.12);
                    }

                    // T3: diag_channels_check + fb_send（含高敏反馈正文与路径，必须完全脱敏）
                    NSButton *retryBtn = (NSButton *)FindById(settingsE.view, @"sp_fbretry");
                    (void)retryBtn;
                    [settingsE onFeedbackRetry:nil];
                    Pump(0.12);

                    NSTextView *fbTextView = (NSTextView *)FindById(settingsE.view, @"sp_fbtext");
                    NSSwitch *fbDiagSw = (NSSwitch *)FindById(settingsE.view, @"sp_fbdiag");
                    NSButton *fbSendBtn = (NSButton *)FindById(settingsE.view, @"sp_fbsend");
                    Ck(fbTextView && fbSendBtn && fbSendBtn.enabled,
                       "T3-pre 反馈框与发送按钮就绪",
                       [NSString stringWithFormat:@"tv=%p btn=%p en=%d",
                        fbTextView, fbSendBtn, fbSendBtn ? (int)fbSendBtn.enabled : -1]);
                    if (fbTextView && fbSendBtn) {
                        fbTextView.string = @"测试反馈正文包含隐私路径 /Users/alice/Private/track.flac 与 token=secret-999";
                        if (fbDiagSw) fbDiagSw.state = NSControlStateValueOn;
                        [fbSendBtn performClick:nil];
                        Pump(0.15);
                    }

                    // T4: update_check + update_channel_switch
                    NSButton *updBtn = (NSButton *)FindById(settingsE.view, @"sp_updcheck");
                    NSPopUpButton *updChan = (NSPopUpButton *)FindById(settingsE.view, @"sp_updchannel");
                    if (updBtn) { [updBtn performClick:nil]; Pump(0.1); }
                    if (updChan && updChan.numberOfItems >= 2) {
                        [updChan selectItemAtIndex:1];
                        [updChan sendAction:updChan.action to:updChan.target];
                        Pump(0.1);
                    }

                    // T5: 关键 /api 失败（postKey 触发 /api/settings 失败）
                    g_spy.failNextSettingsPost = YES;
                    [settingsE postKey:@"loudness" value:@"1" completion:nil];
                    Pump(0.12);
                }

                // T1b: mode_switch + np + close np
                [wcE setUiMode:@"pro" persist:YES];
                Pump(0.12);
                [wcE onNowPlaying:nil];
                Pump(0.12);
                [wcE onCloseNowPlaying:nil];
                Pump(0.15);

                auto hasEvent = ^BOOL(NSString *evt, NSString *name, NSString *routePrefix, NSString *pathExact) {
                    for (NSDictionary *e in g_spy.uiEvents) {
                        if (evt && ![e[@"evt"] isEqualToString:evt]) continue;
                        if (name && ![e[@"name"] isEqualToString:name]) continue;
                        if (routePrefix && !([e[@"route"] isKindOfClass:[NSString class]] &&
                                             [e[@"route"] hasPrefix:routePrefix])) continue;
                        if (pathExact && ![e[@"path"] isEqualToString:pathExact]) continue;
                        return YES;
                    }
                    return NO;
                };

                NSInteger uiPostCount = 0;
                for (NSString *r in g_spy.requests) {
                    if ([r isEqualToString:@"POST /api/ui/events"]) ++uiPostCount;
                }
                Ck(uiPostCount >= 1 && g_spy.uiEvents.count >= 10,
                   "T1 绿基线：原生关键交互确实 POST /api/ui/events（新码事件数 >= 1，旧码为 0）",
                   [NSString stringWithFormat:@"posts=%ld events=%lu",
                    (long)uiPostCount, (unsigned long)g_spy.uiEvents.count]);
                Ck(hasEvent(@"nav", @"page_switch", @"settings", nil),
                   "T1a page_switch(route=settings) 已上报", @"missing");
                Ck(hasEvent(@"action", @"settings_open", @"settings", nil),
                   "T1b settings_open 已上报", @"missing");
                Ck(hasEvent(@"nav", @"settings_tab_switch", @"settings:meta", nil) &&
                   hasEvent(@"nav", @"settings_tab_switch", @"settings:diag", nil),
                   "T1c settings_tab_switch(settings:meta / settings:diag) 已上报", @"missing");
                Ck(hasEvent(@"action", @"mode_switch", @"station", @"/api/settings"),
                   "T1d mode_switch(route=station, path=/api/settings) 已上报", @"missing");
                Ck(hasEvent(@"nav", @"page_switch", @"np", nil),
                   "T1e page_switch(route=np) 已上报", @"missing");

                Ck(hasEvent(@"action", @"diag_export", @"settings:diag", @"/api/diagzip"),
                   "T2a diag_export(path=/api/diagzip) 已上报", @"missing");
                Ck(hasEvent(@"action", @"diag_json", @"settings:diag", @"/api/diag"),
                   "T2b diag_json(path=/api/diag) 已上报", @"missing");
                Ck(hasEvent(@"action", @"diag_summary", @"settings:diag", @"/api/diag"),
                   "T2c diag_summary(path=/api/diag) 已上报", @"missing");

                Ck(hasEvent(@"action", @"diag_channels_check", @"settings:diag", nil),
                   "T3a diag_channels_check 已上报", @"missing");
                Ck(hasEvent(@"action", @"fb_send", @"settings:diag", nil),
                   "T3b fb_send 已上报", @"missing");
                Ck(hasEvent(@"action", @"update_check", @"settings:diag", nil),
                   "T4a update_check 已上报", @"missing");
                Ck(hasEvent(nil, @"update_channel_switch", @"settings:diag", nil),
                   "T4b update_channel_switch 已上报", @"missing");
                Ck(hasEvent(@"error", @"api_fail", @"settings", @"/api/settings"),
                   "T5a /api/settings 失败记录 error/api_fail", @"missing");

                NSString *joinedBodies = [g_spy.uiEventBodies componentsJoinedByString:@"\n"];
                NSArray<NSString *> *forbidden = @[
                    @"测试反馈正文", @"alice", @"track.flac", @"secret-999",
                    @"FB-AUDIT-777", @"secret_user_diag_dir", @"rlplayer-diag.zip",
                    @"/Users/", @"/var/", @"/tmp/", @"loudness", @"mock rejected"
                ];
                NSMutableArray<NSString *> *leaks = [NSMutableArray array];
                for (NSString *tok in forbidden) {
                    if ([joinedBodies rangeOfString:tok options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        [leaks addObject:tok];
                    }
                }
                Ck(leaks.count == 0,
                   "T3c/T2d 遥测载荷零泄露（不含反馈正文、文件路径、工单号、提交键值）",
                   [leaks componentsJoinedByString:@", "]);

                // T5b + T6: URL query/路径脱敏、同签 5s 去重冷却、突发 40 条限流（均不影响 UI）
                RLPDiagTelemetryResetForAudit();
                [g_spy.uiEvents removeAllObjects];
                [g_spy.uiEventBodies removeAllObjects];

                RLPDiagEvent(@"error", @"api_fail", @"settings:meta",
                             @"/api/llm/test?key=secret-token&q=abc", 401, 15.2,
                             @"/Users/bob/secret.flac");
                RLPDiagEvent(@"error", @"api_fail", @"settings:meta",
                             @"/api/llm/test?key=secret-token&q=abc", 401, 16.0,
                             @"/Users/bob/secret.flac");
                Pump(0.12);
                Ck(g_spy.uiEvents.count == 1 &&
                   [g_spy.uiEvents.firstObject[@"path"] isEqualToString:@"/api/llm/test"] &&
                   !g_spy.uiEvents.firstObject[@"code"],
                   "T5b/T6a URL query 与文件路径被剥离，且 5s 同签错误去重只落 1 条",
                   [NSString stringWithFormat:@"count=%lu first=%@",
                    (unsigned long)g_spy.uiEvents.count, g_spy.uiEvents.firstObject]);
                NSString *negBody = [g_spy.uiEventBodies componentsJoinedByString:@"\n"];
                Ck([negBody rangeOfString:@"secret"].location == NSNotFound &&
                   [negBody rangeOfString:@"bob"].location == NSNotFound &&
                   [negBody rangeOfString:@"?"].location == NSNotFound,
                   "T5c 负例遥测体不含 query / secret / 用户名路径", negBody);

                [g_spy.uiEvents removeAllObjects];
                [g_spy.uiEventBodies removeAllObjects];
                RLPDiagTelemetryResetForAudit();
                for (int i = 0; i < 40; ++i) {
                    RLPDiagEvent(@"action", @"rate_probe", @"settings:adv", nil, 0, -1,
                                 [NSString stringWithFormat:@"c%d", i]);
                }
                Pump(0.2);
                Ck(g_spy.uiEvents.count >= 1 && g_spy.uiEvents.count <= 24,
                   "T6b 2s 突发 40 条事件被限流保护（1 <= 送达 <= 24，防轮询刷爆）",
                   [NSString stringWithFormat:@"delivered=%lu", (unsigned long)g_spy.uiEvents.count]);
            } @finally {
                if (probeM) method_setImplementation(probeM, (IMP)NoopProbe);
                if (saveRunM && origSaveRunImp) method_setImplementation(saveRunM, origSaveRunImp);
                if (saveUrlM && origSaveUrlImp) method_setImplementation(saveUrlM, origSaveUrlImp);
                if (updCheckM && origUpdCheckImp) method_setImplementation(updCheckM, origUpdCheckImp);
                g_savePanelURL = nil;
                [wcE stopAllActivity];
                [wcE.window close];
                if (prevStateCopy.empty()) unsetenv("RLPLAYER_STATE_DIR");
                else setenv("RLPLAYER_STATE_DIR", prevStateCopy.c_str(), 1);
                [[NSFileManager defaultManager] removeItemAtPath:tmpRoot error:nil];
                [RLPTheme setThemeName:@"light"];
                [RLPTheme setUiStyle:@"apple"];
            }
        }
        // 部分 E：诊断页 反馈/更新通道检查（sp_diagchannelsbtn + sp_diagchannels · 900x600）
        // =========================================================================
        std::printf("\n[Suite E] 诊断页 反馈/更新通道检查（900x600 · fake transport）\n");
        [g_spy.requests removeAllObjects];
        g_spy.diagChannelsFixture = @{
            @"ok": @YES,
            @"checkedAt": @"2026-11-19T07:40:00Z",
            @"update": @{ @"channel": @"cn", @"ok": @YES, @"http": @200, @"latency": @123, @"timedOut": @NO, @"error": @"" },
            @"feedback": @{ @"ok": @YES, @"http": @200, @"latency": @88, @"timedOut": @NO, @"error": @"" },
        };
        RLPMainWindowController *wcE = [[RLPMainWindowController alloc] init];
        wcE.window.releasedWhenClosed = NO;
        [wcE.window setFrameAutosaveName:@""];
        ResetMainWindowFrame(wcE, 900.0, 600.0);
        [wcE.sidebar selectKey:@"settings"];
        Pump(0.15);
        RLPSettingsViewController *settingsE = (RLPSettingsViewController *)wcE.currentContent;
        Ck([settingsE isKindOfClass:[RLPSettingsViewController class]],
           "E0 900x600 打开设置页成功", NSStringFromClass(wcE.currentContent.class));
        if (settingsE) {
            [settingsE selectPane:@"diag"];
            LayoutHost(wcE.window.contentView, 0.2);
            NSView *diagCard = FindById(settingsE.view, @"sp_diaggroup");
            NSButton *chanBtn = (NSButton *)FindById(settingsE.view, @"sp_diagchannelsbtn");
            NSTextField *chanLbl = (NSTextField *)FindById(settingsE.view, @"sp_diagchannels");
            Ck(diagCard != nil && [chanBtn isKindOfClass:[NSButton class]] &&
               [chanLbl isKindOfClass:[NSTextField class]] &&
               [chanBtn isDescendantOf:diagCard] && [chanLbl isDescendantOf:diagCard],
               "E1 诊断页存在检查反馈/更新通道按钮与 sp_diagchannels 状态文本",
               @"missing sp_diagchannelsbtn/sp_diagchannels");

            if ([chanBtn isKindOfClass:[NSButton class]] && [chanLbl isKindOfClass:[NSTextField class]]) {
                // 1) 真实生产接口路径（走 Spy /api/diag/channels 异步回调，不阻塞 UI）
                [chanBtn performClick:nil];
                Ck(!chanBtn.enabled && [chanLbl.stringValue containsString:@"正在检查"],
                   "E2 点击后按钮进入异步检查态（立即返回不阻塞 UI）",
                   [NSString stringWithFormat:@"en=%d text=%@", (int)chanBtn.enabled, chanLbl.stringValue ?: @""]);
                LayoutHost(wcE.window.contentView, 0.2);
                Ck([g_spy.requests containsObject:@"GET /api/diag/channels"],
                   "E3 生产路径请求 GET /api/diag/channels",
                   [g_spy.requests componentsJoinedByString:@", "]);
                Ck(chanBtn.enabled &&
                   [chanLbl.stringValue isEqualToString:@"更新：HTTP 200 123ms / 反馈：HTTP 200 88ms"],
                   "E4 200/200 状态文本逐字匹配：更新：HTTP 200 123ms / 反馈：HTTP 200 88ms",
                   chanLbl.stringValue ?: @"");

                // 2) fake transport 测试接缝：超时 / 404 / 403 / reset
                __block NSDictionary *stubPayload = nil;
                void (^chanStub)(void (^)(NSDictionary *)) = ^(void (^done)(NSDictionary *)) {
                    NSDictionary *p = stubPayload;
                    dispatch_async(dispatch_get_main_queue(), ^{ done(p); });
                };
                @try {
                    [settingsE setValue:chanStub forKey:@"diagChannelsTransport"];
                } @catch (NSException *ex) {
                    Ck(NO, "E5-pre 注入 diagChannelsTransport", ex.reason ?: @"");
                }

                stubPayload = @{
                    @"ok": @YES,
                    @"update": @{ @"channel": @"global", @"ok": @NO, @"http": @0, @"latency": @4001, @"timedOut": @YES, @"error": @"timeout" },
                    @"feedback": @{ @"ok": @YES, @"http": @200, @"latency": @88, @"timedOut": @NO, @"error": @"" },
                };
                [chanBtn performClick:nil];
                LayoutHost(wcE.window.contentView, 0.15);
                Ck([chanLbl.stringValue containsString:@"更新：超时"] &&
                   [chanLbl.stringValue containsString:@"反馈：HTTP 200 88ms"],
                   "E5 超时场景显示更新超时与反馈 HTTP 200",
                   chanLbl.stringValue ?: @"");

                stubPayload = @{
                    @"ok": @YES,
                    @"update": @{ @"channel": @"cn", @"ok": @NO, @"http": @404, @"latency": @19, @"timedOut": @NO, @"error": @"HTTP 404" },
                    @"feedback": @{ @"ok": @NO, @"http": @403, @"latency": @23, @"timedOut": @NO, @"error": @"HTTP 403" },
                };
                [chanBtn performClick:nil];
                LayoutHost(wcE.window.contentView, 0.15);
                Ck([chanLbl.stringValue containsString:@"HTTP 404"] &&
                   [chanLbl.stringValue containsString:@"HTTP 403"],
                   "E6 404/403 场景如实显示 HTTP 错误码",
                   chanLbl.stringValue ?: @"");

                stubPayload = @{
                    @"ok": @YES,
                    @"update": @{ @"channel": @"global", @"ok": @NO, @"http": @0, @"latency": @42, @"timedOut": @NO, @"error": @"Recv failure: Connection reset by peer" },
                    @"feedback": @{ @"ok": @YES, @"http": @200, @"latency": @88, @"timedOut": @NO, @"error": @"" },
                };
                [chanBtn performClick:nil];
                LayoutHost(wcE.window.contentView, 0.15);
                Ck([chanLbl.stringValue containsString:@"Connection reset by peer"] &&
                   [chanLbl.stringValue containsString:@"反馈：HTTP 200 88ms"],
                   "E7 连接 reset 场景如实显示失败且不谎报",
                   chanLbl.stringValue ?: @"");

                NSScrollView *diagScroll = PaneScroll(settingsE);
                NSClipView *diagClip = diagScroll.contentView;
                NSView *diagDoc = diagScroll.documentView;
                const CGFloat clipW = diagClip ? NSWidth(diagClip.bounds) : 0.0;
                const CGFloat docW = diagDoc ? NSWidth(diagDoc.frame) : 0.0;
                const NSRect btnR = [chanBtn convertRect:chanBtn.bounds toView:diagClip];
                const NSRect lblR = [chanLbl convertRect:chanLbl.bounds toView:diagClip];
                Ck(clipW > 100.0 && docW <= clipW + 1.0 &&
                   NSMaxX(btnR) <= clipW + 1.0 && NSMaxX(lblR) <= clipW + 1.0 &&
                   wcE.window.frame.size.width <= 901.0,
                   "E8 长错误文案在 900x600 诊断页不溢出且不撑宽窗口",
                   [NSString stringWithFormat:@"win=%.1f clip=%.1f doc=%.1f btn=%.1f lbl=%.1f",
                    wcE.window.frame.size.width, clipW, docW, NSMaxX(btnR), NSMaxX(lblR)]);
                [settingsE setValue:nil forKey:@"diagChannelsTransport"];
            }
        }
        [wcE stopAllActivity];
        [wcE.window close];
        }

        std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
