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
#import "RLPTheme.h"
#import "RLPSupport.h"

#include <cmath>
#include <cstdio>
#include <string>

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
@end

@implementation RLPWidthContractSpy
- (instancetype)init {
    self = [super init];
    if (self) {
        _modelsAvailable = NO;
        _backend = @"null";
        _requests = [NSMutableArray array];
    }
    return self;
}
- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown { }
- (nullable NSDictionary *)jsonWithMethod:(NSString *)method
                                     path:(NSString *)path
                                     body:(nullable NSString *)body {
    (void)body;
    [self.requests addObject:[NSString stringWithFormat:@"%@ %@", method ?: @"GET", path ?: @""]];
    if (![method isEqualToString:@"POST"]) return [self fixtureForPath:path ?: @""];
    return @{ @"ok": @YES };
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
    (void)body;
    [self.requests addObject:[NSString stringWithFormat:@"POST %@", path ?: @""]];
    if (!done) return;
    dispatch_async(dispatch_get_main_queue(), ^{ done(@{ @"ok": @YES }); });
}
- (void)getData:(NSString *)path completion:(nullable RLPDataCompletion)done {
    (void)path;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
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
    if ([path hasPrefix:@"/api/cast/state"]) return @{ @"ok": @YES, @"running": @NO, @"device": @"" };
    return @{ @"ok": @YES };
}
@end

static RLPWidthContractSpy *g_spy = nil;
static id FakeSharedClient(id cls, SEL sel) { (void)cls; (void)sel; return g_spy; }
static void NoopProbe(id self, SEL sel) { (void)self; (void)sel; }

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
        AssertMetaGeometry("C2-classic-1180-expanded", settingsTheme, pageHostTheme, YES, NO, YES);

        [RLPTheme setThemeName:@"light"];
        [RLPTheme setUiStyle:@"apple"];
        LayoutHost(wcTheme.window.contentView, 0.15);
        [wcTheme stopAllActivity];
        [wcTheme.window close];

        std::printf("\n结果：%d passed, %d failed\n", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }
}
