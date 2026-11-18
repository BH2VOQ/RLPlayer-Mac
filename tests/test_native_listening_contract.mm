// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_listening_contract.mm — 原生聆听室重设计契约判据（v3.3.11 对齐）
//
// 覆盖：
//   C1 真实 /api/filters 注册表 + Windows 语义听音风格映射（不按最大 gauss taps 碰运气）
//   C2 切风格同一次 POST 清除 taps/mintapsperinput/atten/transition/phase/filterNx 并写后读回
//   C3 presetStatusForCapsJSON / gatingForCapsJSON 按 CoreAudio/DoP/shared/AirPlay/UPnP/null 与播放态给出结果与禁用原因
//   C4 bitperfect 下风格禁用且有说明，不偷偷破坏直通
//   C5 真实几何自适应（宽 4 列 / 中 2 列 / 窄 1 列，四卡等宽；队列预览 ≤4 行且内部无嵌套滚动；页头音乐文件夹入口）
//
// 纪律：隔离 state/library；backend=null、volume=-120；不启动真实 app 服务、不碰 8899、不模拟键鼠。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPListeningRoom.h"
#import "RLPModels.h"
#import "RLPQuickStartViewController.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#import <objc/runtime.h>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}

static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectViews(s, out);
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

@interface RLPQuickStartViewController (ContractTest)
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, strong) NSTextField *styleValue;
@property (nonatomic, strong) NSTextField *styleSub;
@property (nonatomic, strong) NSView *styleCard;
@property (nonatomic, strong) NSTextField *outputValue;
@property (nonatomic, strong) NSTextField *presetNotes;
@property (nonatomic, copy, nullable) NSString *localDevice;
@property (nonatomic, strong, nullable) NSPopover *popover;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) BOOL pausedNow;
@property (nonatomic, strong) NSView *cardsContainer;
@property (nonatomic, strong) NSStackView *albumRow;
@property (nonatomic, strong) RLPCoverImageView *npCover;
@property (nonatomic, strong) NSTextField *npTitle;
@property (nonatomic, strong) NSTextField *npSub;
@property (nonatomic, strong) NSButton *npOpenButton;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, copy, nullable) NSDictionary *lastMetaDict;
@property (nonatomic, copy) NSArray<RLPAlbum *> *albumsData;
@property (nonatomic, assign) NSInteger currentCardColumns;
@property (nonatomic, assign) NSInteger currentAlbumColumns;
@property (nonatomic, strong) NSStackView *queueList;
@property (nonatomic, strong) NSMutableArray<NSView *> *queueRowSurfaces;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *queueRowCurrentFlags;
@property (nonatomic, weak, nullable) NSTextField *queueEmptyLabel;
@property (nonatomic, copy) NSArray<NSString *> *queuePaths;
@property (nonatomic, assign) NSInteger queueCurrentIndex;
+ (NSDictionary<NSString *, NSString *> *)playModeFeedbackForNotes:(NSArray * _Nullable)notes
                                                  playbackActive:(BOOL)active;
- (void)syncPlayAndStyleCards;
- (void)onPickStyle:(NSButton *)sender;
- (void)onPickPlayMode:(NSButton *)sender;
- (void)onOpenOutput:(id)sender;
- (void)onPickBackend:(NSButton *)sender;
- (void)onApplyUpnpOutput:(id)sender;
- (void)applyCastDevicesPayload:(NSDictionary * _Nullable)json;
- (void)reloadSettings;
- (void)reloadQueue;
- (void)applyStatusJSON:(NSDictionary *)json;
- (void)activate;
- (void)viewDidDisappear;
- (void)rebuildAlbumGrid;
- (void)renderQueueFromJSON:(NSDictionary * _Nullable)json;
- (void)updateResponsiveLayoutForWidth:(CGFloat)availWidth;
- (void)applyLanguage;
- (void)onOpenCurrentAlbum:(id)sender;
@end

// Keep output selection tests offline: discovery is explicitly stubbed.
@interface RLPOfflineOutputController : RLPQuickStartViewController
@end
@implementation RLPOfflineOutputController
- (void)discoverCastDevicesForce:(BOOL)force { (void)force; }
- (void)showPopoverFrom:(NSView *)anchor withCard:(NSView *)card width:(CGFloat)width minH:(CGFloat)height {
    (void)anchor;
    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = RLPCardController(card, width, height);
    [self.popover.contentViewController.view layoutSubtreeIfNeeded];
}
@end

static void TestMountedRoomGeometry() {
    RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 620)
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
    NSView *host = win.contentView;
    [host addSubview:vc.view];
    vc.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [vc.view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [vc.view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [vc.view.topAnchor constraintEqualToAnchor:host.topAnchor],
        [vc.view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    CollectViews(vc.view, views);
    NSScrollView *scroll = nil;
    for (NSView *view in views) {
        if ([view isKindOfClass:[NSScrollView class]]) { scroll = (NSScrollView *)view; break; }
    }
    NSView *first = FindById(vc.view, @"room.device");
    NSView *last = FindById(vc.view, @"room.style");
    CK(scroll && first && last, "Mounted room has a scroll view and control cards", @"");
    if (!scroll || !first || !last) return;
    for (NSNumber *width in @[@1180, @674, @954, @574, @820, @360, @1180]) {
        const CGFloat w = width.doubleValue;
        [win setContentSize:NSMakeSize(w, 620)];
        [host layoutSubtreeIfNeeded];
        [host layoutSubtreeIfNeeded];
        NSRect a = [first convertRect:first.bounds toView:scroll.documentView];
        NSRect b = [last convertRect:last.bounds toView:scroll.documentView];
        const BOOL sameRow = std::fabs(NSMaxY(a) - NSMaxY(b)) < 1.5;
        const CGFloat clipWidth = NSWidth(scroll.contentView.bounds);
        CK(std::fabs(NSWidth(scroll.frame) - w) < 1.5 &&
           std::fabs(NSWidth(scroll.documentView.frame) - clipWidth) < 1.5 &&
           NSWidth(a) > 0 && NSWidth(b) > 0 && NSMaxX(a) <= clipWidth + 1 && NSMaxX(b) <= clipWidth + 1 &&
           sameRow == (w > 798.0), "Mounted room resize fits viewport and selects expected card rows",
           [NSString stringWithFormat:@"requested=%.1f host=%@ page=%@ scroll=%@ clip=%.1f doc=%@ first=%@ last=%@",
            w, NSStringFromRect(host.frame), NSStringFromRect(vc.view.frame), NSStringFromRect(scroll.frame), clipWidth, NSStringFromRect(scroll.documentView.frame),
            NSStringFromRect(a), NSStringFromRect(b)]);
    }
}

static void CollectByIdPrefix(NSView *root, NSString *prefix, NSMutableArray<NSView *> *out) {
    if (!root) return;
    if ([root.identifier hasPrefix:prefix]) [out addObject:root];
    for (NSView *s in root.subviews) CollectByIdPrefix(s, prefix, out);
}

static NSScrollView *FindRoomScrollView(NSView *root) {
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    CollectViews(root, views);
    for (NSView *v in views) {
        if ([v isKindOfClass:[NSScrollView class]]) return (NSScrollView *)v;
    }
    return nil;
}

static NSImage *MakeTestCover512() {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(512, 512)];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:512
                      pixelsHigh:512
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    if (rep) {
        [img addRepresentation:rep];
    } else {
        [img lockFocus];
        [[NSColor systemBlueColor] setFill];
        NSRectFill(NSMakeRect(0, 0, 512, 512));
        [img unlockFocus];
    }
    return img;
}

static NSArray<RLPAlbum *> *MakeTestAlbums(NSInteger count) {
    NSMutableArray<NSDictionary *> *raw = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (NSInteger i = 0; i < count; ++i) {
        [raw addObject:@{
            @"key": [NSString stringWithFormat:@"alb-%ld", (long)i],
            @"name": [NSString stringWithFormat:@"Very Long Classical Symphony Album Title Number %ld With Extra Words For Tail Truncation", (long)i],
            @"album": [NSString stringWithFormat:@"Very Long Classical Symphony Album Title Number %ld With Extra Words For Tail Truncation", (long)i],
            @"artist": @"Very Long Philharmonic Orchestra & Conductor Name That Should Not Overflow",
            @"year": @(2000 + (i % 24)),
            @"sampleRate": @192000,
            @"bits": @24,
        }];
    }
    NSArray<RLPAlbum *> *parsed = [RLPAlbum albumsFromJSON:@{@"ok": @YES, @"albums": raw, @"items": raw}];
    if (parsed.count >= (NSUInteger)count) return parsed;
    NSMutableArray<RLPAlbum *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (NSInteger i = 0; i < count; ++i) {
        RLPAlbum *a = [[RLPAlbum alloc] init];
        @try {
            [a setValue:raw[(NSUInteger)i][@"key"] forKey:@"key"];
            [a setValue:raw[(NSUInteger)i][@"name"] forKey:@"name"];
            [a setValue:raw[(NSUInteger)i][@"artist"] forKey:@"artist"];
            [a setValue:raw[(NSUInteger)i][@"year"] forKey:@"year"];
            [a setValue:raw[(NSUInteger)i][@"sampleRate"] forKey:@"sampleRate"];
            [a setValue:raw[(NSUInteger)i][@"bits"] forKey:@"bits"];
        } @catch (NSException *ex) {
            (void)ex;
        }
        [out addObject:a];
    }
    return out;
}

static NSDictionary *SampleLongQueueJSON() {
    return @{
        @"items": @[@"/tmp/track1.flac", @"/tmp/track2.flac", @"/tmp/track3.flac", @"/tmp/track4.flac"],
        @"metas": @[
            @{@"t": @"Symphony No. 9 in D Minor Op. 125 Movement IV Presto Allegro Assai Very Long Title",
              @"a": @"Berliner Philharmoniker & Long Conductor Name", @"d": @1452.0},
            @{@"t": @"Goldberg Variations BWV 988 Aria da Capo Very Long Title For Narrow Queue Preview",
              @"a": @"Glenn Gould", @"d": @312.0},
            @{@"t": @"Kind of Blue So What Remastered Ultra High Definition Long Title",
              @"a": @"Miles Davis Quintet", @"d": @562.0},
            @{@"t": @"The Well-Tempered Clavier Book I Prelude and Fugue No. 1 in C Major",
              @"a": @"Sviatoslav Richter", @"d": @285.0},
        ],
        @"index": @0,
    };
}

static NSUInteger ApplyCoversToRoom(RLPQuickStartViewController *vc, NSImage * _Nullable cover) {
    vc.npCover.image = cover;
    NSMutableArray<NSView *> *covers = [NSMutableArray array];
    CollectByIdPrefix(vc.view, @"room.albumcover.", covers);
    for (NSView *v in covers) {
        if ([v isKindOfClass:[NSImageView class]]) {
            ((NSImageView *)v).image = cover;
        }
    }
    return covers.count;
}

static void MountVCInWindow(RLPQuickStartViewController *vc, NSWindow *win) {
    NSView *host = win.contentView;
    [host addSubview:vc.view];
    vc.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [vc.view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [vc.view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [vc.view.topAnchor constraintEqualToAnchor:host.topAnchor],
        [vc.view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
}

static void VerifyRoomFit(RLPQuickStartViewController *vc, NSWindow *win, CGFloat expectedW,
                          NSString *tag, BOOL expectCover) {
    NSScrollView *scroll = FindRoomScrollView(vc.view);
    NSView *cDev = FindById(vc.view, @"room.device");
    NSView *cOut = FindById(vc.view, @"room.output");
    NSView *cPlay = FindById(vc.view, @"room.play");
    NSView *cStyle = FindById(vc.view, @"room.style");
    NSView *cardsContainer = vc.cardsContainer ?: cDev.superview;
    NSView *albumRowView = FindById(vc.view, @"room.albums") ?: vc.albumRow;
    NSView *npCard = FindById(vc.view, @"room.nowplaying");
    NSView *qCard = FindById(vc.view, @"room.queue");

    const CGFloat docW = scroll ? NSWidth(scroll.documentView.frame) : -1.0;
    const CGFloat clipW = scroll ? NSWidth(scroll.contentView.bounds) : -1.0;
    const CGFloat hostW = NSWidth(win.contentView.bounds);
    const CGFloat pageW = NSWidth(vc.view.bounds);

    CK(scroll && docW <= clipW + 1.0 && hostW <= expectedW + 1.0 && pageW <= expectedW + 1.0,
       [[NSString stringWithFormat:@"%@ scroll doc<=clip and host/page<=expected", tag] UTF8String],
       [NSString stringWithFormat:@"expected=%.1f host=%.1f page=%.1f clip=%.1f doc=%.1f",
        expectedW, hostW, pageW, clipW, docW]);

    BOOL fourCardsOk = (cardsContainer != nil && cDev && cOut && cPlay && cStyle);
    NSString *cardsDetail = @"";
    if (fourCardsOk) {
        const CGFloat ccW = NSWidth(cardsContainer.bounds);
        for (NSView *card in @[cDev, cOut, cPlay, cStyle]) {
            NSRect cr = [card convertRect:card.bounds toView:cardsContainer];
            NSRect pr = [card convertRect:card.bounds toView:vc.view];
            if (NSWidth(cr) <= 0 || NSMaxX(cr) > ccW + 1.0 || NSMaxX(pr) > pageW + 1.0) {
                fourCardsOk = NO;
                cardsDetail = [NSString stringWithFormat:@"id=%@ cr=%@ ccW=%.1f pr=%@ pageW=%.1f",
                               card.identifier, NSStringFromRect(cr), ccW, NSStringFromRect(pr), pageW];
                break;
            }
        }
    }
    CK(fourCardsOk, [[NSString stringWithFormat:@"%@ four cards maxX <= cardsContainer/page", tag] UTF8String], cardsDetail);

    BOOL albumsOk = ([albumRowView isKindOfClass:[NSStackView class]]);
    NSString *albumsDetail = @"";
    NSUInteger foundAlbumCards = 0;
    if (albumsOk) {
        NSStackView *ar = (NSStackView *)albumRowView;
        const CGFloat arW = NSWidth(ar.bounds);
        for (NSView *rowView in ar.arrangedSubviews) {
            if (![rowView isKindOfClass:[NSStackView class]]) continue;
            NSStackView *rs = (NSStackView *)rowView;
            NSRect rr = [rs convertRect:rs.bounds toView:ar];
            if (NSMaxX(rr) > arW + 1.0) {
                albumsOk = NO;
                albumsDetail = [NSString stringWithFormat:@"rowStack=%@ arW=%.1f", NSStringFromRect(rr), arW];
                break;
            }
            for (NSView *item in rs.arrangedSubviews) {
                NSRect ir = [item convertRect:item.bounds toView:ar];
                if (NSWidth(ir) <= 0 || NSMaxX(ir) > arW + 1.0) {
                    albumsOk = NO;
                    albumsDetail = [NSString stringWithFormat:@"item=%@ ir=%@ arW=%.1f", item.identifier ?: @"", NSStringFromRect(ir), arW];
                    break;
                }
                if ([item.identifier hasPrefix:@"room.albumcard."]) {
                    ++foundAlbumCards;
                    NSMutableArray<NSView *> *ivs = [NSMutableArray array];
                    CollectByIdPrefix(item, @"room.albumcover.", ivs);
                    for (NSView *v in ivs) {
                        if (![v isKindOfClass:[NSImageView class]]) continue;
                        NSImageView *iv = (NSImageView *)v;
                        NSRect ivr = [iv convertRect:iv.bounds toView:ar];
                        if (NSMaxX(ivr) > arW + 1.0) {
                            albumsOk = NO;
                            albumsDetail = [NSString stringWithFormat:@"cover=%@ ivr=%@ arW=%.1f", iv.identifier, NSStringFromRect(ivr), arW];
                            break;
                        }
                        if (expectCover && (!iv.image || iv.image.size.width < 512.0)) {
                            albumsOk = NO;
                            albumsDetail = [NSString stringWithFormat:@"cover=%@ missing 512 image", iv.identifier];
                            break;
                        }
                    }
                    if (!albumsOk) break;
                }
            }
            if (!albumsOk) break;
        }
    }
    CK(albumsOk && foundAlbumCards > 0,
       [[NSString stringWithFormat:@"%@ album cards maxX <= albumRow", tag] UTF8String],
       [NSString stringWithFormat:@"cards=%lu %@", (unsigned long)foundAlbumCards, albumsDetail]);

    BOOL npqOk = (npCard != nil && qCard != nil);
    NSString *npqDetail = @"";
    if (npqOk) {
        NSRect npr = [npCard convertRect:npCard.bounds toView:vc.view];
        NSRect qr = [qCard convertRect:qCard.bounds toView:vc.view];
        if (NSWidth(npr) <= 0 || NSMaxX(npr) > pageW + 1.0 ||
            NSWidth(qr) <= 0 || NSMaxX(qr) > pageW + 1.0) {
            npqOk = NO;
            npqDetail = [NSString stringWithFormat:@"np=%@ q=%@ pageW=%.1f",
                         NSStringFromRect(npr), NSStringFromRect(qr), pageW];
        }
    }
    CK(npqOk, [[NSString stringWithFormat:@"%@ nowplaying/queue maxX <= pageW", tag] UTF8String], npqDetail);
}

static void TestRoomCoverAndCacheFitB1B2B3() {
    // ---------- B1 & B3: 四档窗宽 × 封面未加载/512x512 加载后 ----------
    RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
    (void)vc.view;
    vc.albumsData = MakeTestAlbums(10);
    vc.npTitle.stringValue = @"Very Long Track Title In Listening Room That Must Truncate Cleanly Without Expanding Window Width";
    vc.npSub.stringValue = @"Very Long Orchestra & Soloist · Very Long Classical Album Title · 2024";
    [vc renderQueueFromJSON:SampleLongQueueJSON()];
    [vc rebuildAlbumGrid];

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1394, 880)
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
    MountVCInWindow(vc, win);

    NSArray<NSArray<NSNumber *> *> *sizes = @[
        @[@1394, @880],
        @[@1180, @760],
        @[@900, @600],
        @[@800, @600],
    ];
    NSImage *cover512 = MakeTestCover512();

    // B3a: 封面未加载状态
    for (NSArray<NSNumber *> *sz in sizes) {
        const CGFloat w = sz[0].doubleValue, h = sz[1].doubleValue;
        [win setContentSize:NSMakeSize(w, h)];
        [win.contentView layoutSubtreeIfNeeded];
        ApplyCoversToRoom(vc, nil);
        [win.contentView layoutSubtreeIfNeeded];
        VerifyRoomFit(vc, win, w, [NSString stringWithFormat:@"B3_nocover_%dx%d", (int)w, (int)h], NO);
    }

    // B1 & B3b: 加载 512x512 NSImage 封面后（先设 512x512 封面，再按四档检测）
    for (NSArray<NSNumber *> *sz in sizes) {
        const CGFloat w = sz[0].doubleValue, h = sz[1].doubleValue;
        [win setContentSize:NSMakeSize(w, h)];
        [win.contentView layoutSubtreeIfNeeded];
        const NSUInteger covCount = ApplyCoversToRoom(vc, cover512);
        [win.contentView layoutSubtreeIfNeeded];
        CK(covCount >= 8, [[NSString stringWithFormat:@"B1_%dx%d album covers populated", (int)w, (int)h] UTF8String],
           [NSString stringWithFormat:@"count=%lu", (unsigned long)covCount]);
        VerifyRoomFit(vc, win, w, [NSString stringWithFormat:@"B1_cover512_%dx%d", (int)w, (int)h], YES);
    }

    // ---------- B2: 同一缓存 VC 1180 挂载 -> 改宿主 900 -> remove/add 到新宿主 ----------
    RLPQuickStartViewController *cachedVC = [[RLPQuickStartViewController alloc] init];
    (void)cachedVC.view;
    cachedVC.albumsData = MakeTestAlbums(10);
    cachedVC.npTitle.stringValue = @"Very Long Cached Listening Room Title That Must Reflow On Host Reentry";
    cachedVC.npSub.stringValue = @"Long Artist · Long Album";
    [cachedVC renderQueueFromJSON:SampleLongQueueJSON()];
    [cachedVC rebuildAlbumGrid];

    NSWindow *w1180 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 760)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
    MountVCInWindow(cachedVC, w1180);
    [w1180.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w1180.contentView layoutSubtreeIfNeeded];
    CK(cachedVC.currentCardColumns == 4 && cachedVC.currentAlbumColumns == 5,
       "B2a cached VC at 1180 adopts 4 card cols / 5 album cols",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    VerifyRoomFit(cachedVC, w1180, 1180.0, @"B2a_1180", YES);

    // 改宿主 900
    [w1180 setContentSize:NSMakeSize(900, 600)];
    [w1180.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w1180.contentView layoutSubtreeIfNeeded];
    CK(cachedVC.currentCardColumns == 4 && cachedVC.currentAlbumColumns == 4,
       "B2b host resized to 900 adopts 4 card cols / 4 album cols",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    VerifyRoomFit(cachedVC, w1180, 900.0, @"B2b_resize_900", YES);

    // 复位到 1180 后 remove/add 到新宿主 900（先触发 viewWillMoveToSuperview:/viewDidMoveToWindow）
    [w1180 setContentSize:NSMakeSize(1180, 760)];
    [w1180.contentView layoutSubtreeIfNeeded];
    [cachedVC.view removeFromSuperview];

    NSWindow *w900 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered defer:NO];
    cachedVC.view.frame = w900.contentView.bounds;
    MountVCInWindow(cachedVC, w900);
    CK(cachedVC.currentCardColumns == 4 && cachedVC.currentAlbumColumns == 4,
       "B2c remove/add to 900 host updates responsive layout immediately on mount",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    [w900.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w900.contentView layoutSubtreeIfNeeded];
    VerifyRoomFit(cachedVC, w900, 900.0, @"B2c_reenter_900", YES);

    // 再验证 remove/add 到 2x2（720）与 1 列（380）新宿主，确保四卡 2x2/1 列与专辑列数对应且 doc<=clip
    [cachedVC.view removeFromSuperview];
    NSWindow *w720 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 600)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered defer:NO];
    cachedVC.view.frame = w720.contentView.bounds;
    MountVCInWindow(cachedVC, w720);
    CK(cachedVC.currentCardColumns == 2 && cachedVC.currentAlbumColumns == 3,
       "B2d remove/add to 720 host adopts 2x2 cards / 3 album cols immediately",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    [w720.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w720.contentView layoutSubtreeIfNeeded];
    VerifyRoomFit(cachedVC, w720, 720.0, @"B2d_reenter_720", YES);

    [cachedVC.view removeFromSuperview];
    NSWindow *w380 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 380, 600)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered defer:NO];
    cachedVC.view.frame = w380.contentView.bounds;
    MountVCInWindow(cachedVC, w380);
    CK(cachedVC.currentCardColumns == 1 && cachedVC.currentAlbumColumns == 2,
       "B2e remove/add to 380 host adopts 1x4 cards / 2 album cols immediately",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    [w380.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w380.contentView layoutSubtreeIfNeeded];
    VerifyRoomFit(cachedVC, w380, 380.0, @"B2e_reenter_380", YES);

    // 额外验证：保持旧 1180 frame 直接 remove/add 到 900 新宿主（不预设 frame），单次 layoutSubtreeIfNeeded 必须完成收敛
    [cachedVC.view removeFromSuperview];
    cachedVC.view.frame = NSMakeRect(0, 0, 1180, 760);
    NSWindow *w900b = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
    MountVCInWindow(cachedVC, w900b);
    [w900b.contentView layoutSubtreeIfNeeded];
    ApplyCoversToRoom(cachedVC, cover512);
    [w900b.contentView layoutSubtreeIfNeeded];
    CK(cachedVC.currentCardColumns == 4 && cachedVC.currentAlbumColumns == 4,
       "B2f stale 1180 frame remove/add to 900 host converges on layout",
       [NSString stringWithFormat:@"cards=%ld albums=%ld", (long)cachedVC.currentCardColumns, (long)cachedVC.currentAlbumColumns]);
    VerifyRoomFit(cachedVC, w900b, 900.0, @"B2f_stale_reenter_900", YES);
}

typedef void (*RLPContractGetJSONImp)(id, SEL, NSString *, RLPJSONCompletion);
static RLPContractGetJSONImp gContractOrigGetJSONImp = NULL;
static NSDictionary *gContractQueueMock = nil;
static NSDictionary *gContractStatusMock = nil;

static void RLPContractMockGetJSON(id self, SEL _cmd, NSString *path, RLPJSONCompletion done) {
    if ([path hasPrefix:@"/api/queue?meta=1"] && gContractQueueMock) {
        if (done) done(gContractQueueMock);
        return;
    }
    if ([path hasPrefix:@"/api/status"] && gContractStatusMock) {
        if (done) done(gContractStatusMock);
        return;
    }
    if (gContractOrigGetJSONImp) {
        gContractOrigGetJSONImp(self, _cmd, path, done);
    } else if (done) {
        done(@{@"ok": @NO});
    }
}

static void PumpContract(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static NSDictionary *MakeContractQueueJSON(NSArray<NSString *> *paths, NSString *curKey, id curVal) {
    NSMutableArray *metas = [NSMutableArray arrayWithCapacity:paths.count];
    NSMutableArray *cues = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSUInteger i = 0; i < paths.count; ++i) {
        [metas addObject:@{
            @"t": [NSString stringWithFormat:@"Song %c", (char)('A' + i)],
            @"a": @"Contract Artist",
            @"d": @(180.0 + i * 15.0),
        }];
        [cues addObject:@[@(-1), @(-1)]];
    }
    NSMutableDictionary *d = [@{
        @"ok": @YES,
        @"items": paths,
        @"metas": metas,
        @"cues": cues,
    } mutableCopy];
    if (curKey.length && curVal) d[curKey] = curVal;
    return d;
}

static void InspectQueueListState(RLPQuickStartViewController *vc,
                                  NSInteger *outRowCount,
                                  NSInteger *outHighlightedCount,
                                  NSInteger *outHighlightedIdx,
                                  NSString **outHighlightedPath) {
    NSArray<NSView *> *rows = vc.queueList.arrangedSubviews;
    *outRowCount = (NSInteger)rows.count;
    *outHighlightedCount = 0;
    *outHighlightedIdx = -1;
    *outHighlightedPath = nil;
    if (vc.queueEmptyLabel != nil) return;

    RLPTheme *t = [RLPTheme current];
    NSColor *accWeakSRGB = [t.accentWeak colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    for (NSUInteger k = 0; k < rows.count; ++k) {
        NSView *row = rows[k];
        NSButton *hit = nil;
        for (NSView *sub in row.subviews) {
            if ([sub isKindOfClass:[NSButton class]]) { hit = (NSButton *)sub; break; }
        }
        const BOOL flag = (k < vc.queueRowCurrentFlags.count) && vc.queueRowCurrentFlags[k].boolValue;
        BOOL bgMatches = NO;
        if (row.layer && row.layer.backgroundColor && accWeakSRGB) {
            NSColor *bg = [[NSColor colorWithCGColor:row.layer.backgroundColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (bg) {
                bgMatches = fabs(bg.redComponent - accWeakSRGB.redComponent) < 0.02 &&
                            fabs(bg.greenComponent - accWeakSRGB.greenComponent) < 0.02 &&
                            fabs(bg.blueComponent - accWeakSRGB.blueComponent) < 0.02;
            }
        }
        if (flag && bgMatches && hit) {
            ++(*outHighlightedCount);
            *outHighlightedIdx = hit.tag;
            *outHighlightedPath = hit.toolTip;
        }
    }
}

static void TestListeningQueueFollow() {
    Method m = class_getInstanceMethod([RLPCoreClient class], @selector(getJSON:completion:));
    gContractOrigGetJSONImp = (RLPContractGetJSONImp)method_getImplementation(m);
    method_setImplementation(m, (IMP)RLPContractMockGetJSON);

    NSArray<NSString *> *tracks5 = @[
        @"/tmp/rlp_q_A.flac",
        @"/tmp/rlp_q_B.flac",
        @"/tmp/rlp_q_C.flac",
        @"/tmp/rlp_q_D.flac",
        @"/tmp/rlp_q_E.flac",
    ];

    RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
    vc.view.frame = NSMakeRect(0, 0, 1100, 760);
    [vc.view layoutSubtreeIfNeeded];

    // 初始在曲 A（index=0）
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"index", @0);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[0]};
    [vc reloadQueue];
    [vc applyStatusJSON:gContractStatusMock];
    PumpContract(0.05);

    NSInteger rowCount = 0, hiCount = 0, hiIdx = -1;
    NSString *hiPath = nil;
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 0 && [hiPath isEqualToString:tracks5[0]],
       "Q1-precondition: 聆听室 queueList 初始高亮曲 A (index=0, 4行)",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);

    // Q1: 模拟状态从曲 A 切到曲 B（队列 JSON 使用 current=B）
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"current", tracks5[1]);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[1]};
    [vc applyStatusJSON:gContractStatusMock];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    std::printf("  [INFO] Q1 highlighted index=%ld path=%s (rows=%ld)\n",
                (long)hiIdx, hiPath.UTF8String ?: "(nil)", (long)rowCount);
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 1 && [hiPath isEqualToString:tracks5[1]] &&
       [vc.queuePaths isEqualToArray:tracks5],
       "Q1 切歌到 B 后聆听室 queueList 高亮行=B、行数不变且队列顺序不变",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);

    // Q3: 连续切 3 首（C -> D -> 轮询 E）仍跟随
    // 1) RLPPlaybackStatusNotification -> C (cur=C)
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"cur", tracks5[2]);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[2]};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackStatusNotification"
                                                        object:gContractStatusMock];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    std::printf("  [INFO] Q3-1 highlighted index=%ld path=%s\n", (long)hiIdx, hiPath.UTF8String ?: "(nil)");
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 2 && [hiPath isEqualToString:tracks5[2]] &&
       [vc.queuePaths isEqualToArray:tracks5],
       "Q3a 聆听室连续第 1 次切歌跟随到 C (index=2)",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);

    // 2) applyStatusJSON -> D (index=3)
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"index", @3);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[3]};
    [vc applyStatusJSON:gContractStatusMock];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    std::printf("  [INFO] Q3-2 highlighted index=%ld path=%s\n", (long)hiIdx, hiPath.UTF8String ?: "(nil)");
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 3 && [hiPath isEqualToString:tracks5[3]] &&
       [vc.queuePaths isEqualToArray:tracks5],
       "Q3b 聆听室连续第 2 次切歌跟随到 D (index=3)",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);

    // 3) activate + 1s 轮询定时器自动发现切到 E (current=@4，预览窗应滑到 1..4)
    [vc activate];
    PumpContract(0.05);
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"current", @4);
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": tracks5[4]};
    PumpContract(1.15);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    std::printf("  [INFO] Q3-3 (poll) highlighted index=%ld path=%s\n", (long)hiIdx, hiPath.UTF8String ?: "(nil)");
    CK(rowCount == 4 && hiCount == 1 && hiIdx == 4 && [hiPath isEqualToString:tracks5[4]] &&
       [vc.queuePaths isEqualToArray:tracks5],
       "Q3c 聆听室连续第 3 次通过轮询跟随到 E (index=4)",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld path=%@",
        (long)rowCount, (long)hiCount, (long)hiIdx, hiPath ?: @"nil"]);
    [vc viewDidDisappear];

    // Q4: 当前不在队列 / 越界 / 空队列 -> 不崩、不高亮错行
    gContractQueueMock = MakeContractQueueJSON(tracks5, @"current", @"/tmp/rlp_q_NOT_IN_QUEUE.flac");
    gContractStatusMock = @{@"ok": @YES, @"playing": @YES, @"paused": @NO, @"currentPath": @"/tmp/rlp_q_NOT_IN_QUEUE.flac"};
    [vc applyStatusJSON:gContractStatusMock];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    CK(rowCount == 4 && hiCount == 0 && hiIdx == -1 && vc.queueCurrentIndex == -1,
       "Q4a 聆听室当前曲目不在队列时不崩且不高亮任何行",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld curIdx=%ld",
        (long)rowCount, (long)hiCount, (long)hiIdx, (long)vc.queueCurrentIndex]);

    gContractQueueMock = MakeContractQueueJSON(tracks5, @"index", @99);
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:nil];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    CK(rowCount == 4 && hiCount == 0 && hiIdx == -1 && vc.queueCurrentIndex == -1,
       "Q4b 聆听室队列越界 index=99 时不崩且不高亮错行",
       [NSString stringWithFormat:@"rows=%ld hi=%ld idx=%ld curIdx=%ld",
        (long)rowCount, (long)hiCount, (long)hiIdx, (long)vc.queueCurrentIndex]);

    gContractQueueMock = @{@"ok": @YES, @"items": @[], @"metas": @[], @"cues": @[], @"current": tracks5[0]};
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPQueueChangedNotification object:nil];
    PumpContract(0.05);
    InspectQueueListState(vc, &rowCount, &hiCount, &hiIdx, &hiPath);
    CK(vc.queueEmptyLabel != nil && rowCount == 1 && hiCount == 0 && vc.queueCurrentIndex == -1,
       "Q4c 聆听室空队列时显示空态且不高亮错行",
       [NSString stringWithFormat:@"empty=%d rows=%ld curIdx=%ld",
        vc.queueEmptyLabel != nil, (long)rowCount, (long)vc.queueCurrentIndex]);

    gContractQueueMock = nil;
    gContractStatusMock = nil;
    method_setImplementation(m, (IMP)gContractOrigGetJSONImp);
    gContractOrigGetJSONImp = NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        TestMountedRoomGeometry();
        if (argc == 2 && std::strcmp(argv[1], "--geometry-only") == 0) return gFail ? 1 : 0;
        std::printf("=== test_native_listening_contract（聆听室 v3.3.11 契约 · 离线/null 核心）===\n");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-listen-contract-%d", (int)getpid()]];
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        NSString *lib = [root stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);

        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) {
            std::printf("  [FAIL] 核心启动失败\n");
            return 1;
        }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        // ---------- C1 真实注册表 + Windows 语义风格映射 ----------
        NSDictionary *fj = [core jsonWithMethod:@"GET" path:@"/api/filters" body:nil];
        NSArray<NSDictionary *> *items = [fj[@"items"] isKindOfClass:[NSArray class]] ? fj[@"items"] : @[];
        CK(items.count >= 50, "C1a /api/filters 返回真实注册表",
           [NSString stringWithFormat:@"count=%lu", (unsigned long)items.count]);

        NSString *warm = RLPFilterForToneStyle(RLPToneStyleWarm, items);
        NSString *bal  = RLPFilterForToneStyle(RLPToneStyleBalanced, items);
        NSString *sharp = RLPFilterForToneStyle(RLPToneStyleSharp, items);
        CK([warm isEqualToString:@"poly-sinc-gauss-long"],
           "C1b 温和档选用真实条目 poly-sinc-gauss-long（不再碰运气选 524k gauss-xl）", warm ?: @"nil");
        CK([bal isEqualToString:@"poly-sinc-short-lp"],
           "C1c 均衡档选用 Windows 语义 poly-sinc-short-lp", bal ?: @"nil");
        CK(sharp.length > 0 &&
           [sharp.lowercaseString rangeOfString:@"gauss"].location == NSNotFound &&
           ([sharp.lowercaseString rangeOfString:@"long"].location != NSNotFound ||
            [sharp.lowercaseString rangeOfString:@"ext"].location != NSNotFound ||
            [sharp.lowercaseString rangeOfString:@"tight"].location != NSNotFound),
           "C1d 锐利档选用注册表真实非 gauss 滤波（long/ext/tight）", sharp ?: @"nil");

        // ---------- C2 切风格同一次 POST 清旧手动覆盖 + 写后读回 ----------
        [core jsonWithMethod:@"POST" path:@"/api/settings"
            body:@"filter=poly-sinc-xl&filterNx=poly-sinc-gauss-hires-lp&taps=65535&mintapsperinput=512&atten=180&transition=0.05&phase=min"];
        NSDictionary<NSString *, NSString *> *patch = RLPSettingsPatchForToneStyle(RLPToneStyleWarm, items);
        CK(patch != nil &&
           [patch[@"filter"] isEqualToString:@"poly-sinc-gauss-long"] &&
           [patch[@"filterNx"] isEqualToString:@""] &&
           [patch[@"taps"] isEqualToString:@"0"] &&
           [patch[@"mintapsperinput"] isEqualToString:@"0"] &&
           [patch[@"atten"] isEqualToString:@"0"] &&
           [patch[@"transition"] isEqualToString:@"0"] &&
           [patch[@"phase"] isEqualToString:@""],
           "C2a 风格补丁同一次含 filter 与全部清除键", patch.description ?: @"nil");

        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in patch) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(patch[k])]];
        NSDictionary *postRes = [core jsonWithMethod:@"POST" path:@"/api/settings"
                                              body:[parts componentsJoinedByString:@"&"]];
        CK([postRes[@"ok"] boolValue], "C2b 单次 POST /api/settings 成功", postRes.description ?: @"nil");

        NSDictionary *kv = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
        CK([kv[@"filter"] isEqualToString:@"poly-sinc-gauss-long"], "C2c 读回 filter=poly-sinc-gauss-long", kv[@"filter"] ?: @"nil");
        CK([kv[@"taps"] isEqualToString:@"0"], "C2d 读回 taps 已清 0", kv[@"taps"] ?: @"nil");
        CK(!kv[@"mintapsperinput"] || [kv[@"mintapsperinput"] isEqualToString:@"0"],
           "C2e 读回 mintapsperinput 已清 0（或未写入旧覆盖）", kv[@"mintapsperinput"] ?: @"nil");
        CK([kv[@"atten"] isEqualToString:@"0"], "C2f 读回 atten 已清 0", kv[@"atten"] ?: @"nil");
        CK([kv[@"transition"] isEqualToString:@"0"], "C2g 读回 transition 已清 0", kv[@"transition"] ?: @"nil");
        CK(![kv[@"phase"] length], "C2h 读回 phase 已清空", kv[@"phase"] ?: @"nil");

        CK([RLPPlayModeFromSettings(@{@"rate": @"src", @"dsd": @"0", @"filter": @""}) isEqualToString:@"bitperfect"],
           "C2i PlayModeFromSettings: bitperfect", @"");
        CK([RLPPlayModeFromSettings(@{@"rate": @"176400", @"dsd": @"0"}) isEqualToString:@"pcm"],
           "C2j PlayModeFromSettings: pcm", @"");
        CK([RLPPlayModeFromSettings(@{@"rate": @"src", @"dsd": @"dop128"}) isEqualToString:@"dsd"],
           "C2k PlayModeFromSettings: dop128 -> dsd", @"");

        // ---------- C3 能力门控与禁用原因 ----------
        NSDictionary *caFull = @{
            @"ok": @YES,
            @"device": @{@"name": @"USB DAC", @"backend": @"coreaudio",
                         @"rates": @[@44100, @96000, @192000, @384000],
                         @"maxRate": @384000, @"dsdNative": @NO, @"dop": @YES, @"dopMax": @"dsd128"}
        };
        NSDictionary *stFull = [RLPQuickStartViewController presetStatusForCapsJSON:caFull
                                                                            settings:@{@"backend": @"coreaudio"}
                                                                             playing:NO paused:NO];
        CK([stFull[@"bitperfect"][@"enabled"] boolValue] &&
           [stFull[@"pcm"][@"enabled"] boolValue] &&
           [stFull[@"dsd"][@"enabled"] boolValue] &&
           [stFull[@"pcm2dsd"][@"enabled"] boolValue],
           "C3a CoreAudio+DoP 全四档可用", @"");

        NSDictionary *caShared = @{
            @"ok": @YES,
            @"device": @{@"name": @"Speakers", @"backend": @"coreaudio-shared",
                         @"rates": @[@44100, @48000], @"maxRate": @48000, @"dsdNative": @NO, @"dop": @NO}
        };
        NSDictionary *gShared = [RLPQuickStartViewController gatingForCapsJSON:caShared];
        CK(![gShared[@"pcmReady"] boolValue] && ![gShared[@"dsdReady"] boolValue],
           "C3b coreaudio-shared gating 禁用 PCM/DSD 升频", @"");
        NSDictionary *stShared = [RLPQuickStartViewController presetStatusForCapsJSON:caShared
                                                                              settings:@{@"backend": @"coreaudio-shared"}
                                                                               playing:NO paused:NO];
        CK([stShared[@"bitperfect"][@"enabled"] boolValue] &&
           ![stShared[@"pcm"][@"enabled"] boolValue] &&
           [stShared[@"pcm"][@"reason"] length] > 0 &&
           ![stShared[@"dsd"][@"enabled"] boolValue] &&
           [stShared[@"dsd"][@"reason"] length] > 0,
           "C3c shared 下 PCM/DSD 禁用且有原因说明", stShared[@"pcm"][@"reason"] ?: @"nil");

        NSDictionary *stBusy = [RLPQuickStartViewController presetStatusForCapsJSON:caFull
                                                                            settings:@{@"backend": @"coreaudio"}
                                                                             playing:YES paused:NO];
        CK([stBusy[@"bitperfect"][@"enabled"] boolValue] &&
           [stBusy[@"pcm"][@"enabled"] boolValue] &&
           [stBusy[@"dsd"][@"enabled"] boolValue] &&
           [stBusy[@"pcm2dsd"][@"enabled"] boolValue] &&
           ![stBusy[@"bitperfect"][@"reason"] length] &&
           ![stBusy[@"pcm"][@"reason"] length] &&
           ![stBusy[@"dsd"][@"reason"] length],
           "C3d 播放中硬件支持的全部预设仍可选（不因播放中全部禁用）", @"");

        NSDictionary *stPaused = [RLPQuickStartViewController presetStatusForCapsJSON:caFull
                                                                              settings:@{@"backend": @"coreaudio"}
                                                                               playing:NO paused:YES];
        CK([stPaused[@"bitperfect"][@"enabled"] boolValue] &&
           [stPaused[@"pcm"][@"enabled"] boolValue] &&
           [stPaused[@"dsd"][@"enabled"] boolValue] &&
           [stPaused[@"pcm2dsd"][@"enabled"] boolValue],
           "C3e 暂停中硬件支持的全部预设仍可选", @"");

        NSDictionary *stBusyShared = [RLPQuickStartViewController presetStatusForCapsJSON:caShared
                                                                                  settings:@{@"backend": @"coreaudio-shared"}
                                                                                   playing:YES paused:NO];
        CK([stBusyShared[@"bitperfect"][@"enabled"] boolValue] &&
           ![stBusyShared[@"pcm"][@"enabled"] boolValue] &&
           [stBusyShared[@"pcm"][@"reason"] length] > 0 &&
           ![stBusyShared[@"dsd"][@"enabled"] boolValue] &&
           [stBusyShared[@"dsd"][@"reason"] length] > 0,
           "C3f 播放中仍保留设备能力限制（shared 下禁用 PCM/DSD 升频）",
           stBusyShared[@"pcm"][@"reason"] ?: @"nil");

        NSDictionary *fbActive = [RLPQuickStartViewController playModeFeedbackForNotes:@[@"说明A"] playbackActive:YES];
        NSDictionary *fbStopped = [RLPQuickStartViewController playModeFeedbackForNotes:@[@"说明A"] playbackActive:NO];
        CK([fbActive[@"toast"] rangeOfString:@"下一首或重新播放时生效"].location != NSNotFound &&
           [fbActive[@"notes"] rangeOfString:@"下一首或重新播放时生效"].location != NSNotFound &&
           [fbActive[@"notes"] rangeOfString:@"说明A"].location != NSNotFound &&
           [fbStopped[@"toast"] isEqualToString:RLPTr(@"已应用")] &&
           [fbStopped[@"notes"] isEqualToString:@"说明A"],
           "C3g 播放/暂停时反馈明确提示下一首或重新播放生效，停播时提示已应用",
           fbActive.description ?: @"nil");

        // ---------- C4 bitperfect 下风格禁用且不破坏直通 ----------
        RLPQuickStartViewController *vc = [[RLPQuickStartViewController alloc] init];
        vc.view.frame = NSMakeRect(0, 0, 1100, 760);
        vc.filters = items;
        vc.settings = @{@"backend": @"null", @"rate": @"src", @"dsd": @"0", @"filter": @"", @"directsdm": @"1"};
        [vc syncPlayAndStyleCards];
        CK([vc.styleValue.stringValue isEqualToString:RLPTr(@"保持原音")],
           "C4a bitperfect 下风格卡显示「保持原音」", vc.styleValue.stringValue ?: @"nil");
        CK(vc.styleCard.alphaValue < 0.9, "C4b bitperfect 下风格卡视觉置灰", @"");

        // C4c: 播放中切播放方式不中断播放、不改音量(-120)，且提示下一首/重新播放生效
        vc.playing = YES;
        vc.pausedNow = NO;
        NSButton *pickBpBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
        pickBpBtn.identifier = @"0";
        [vc onPickPlayMode:pickBpBtn];
        NSString *inflightNote = vc.presetNotes.stringValue ?: @"";
        for (int spin = 0; spin < 40; ++spin) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
            if ([vc.presetNotes.stringValue rangeOfString:@"正在保存"].location == NSNotFound) break;
        }
        NSDictionary *kvAfterPick = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
        CK(vc.playing && !vc.pausedNow &&
           [inflightNote rangeOfString:@"下一首或重新播放时生效"].location != NSNotFound &&
           [vc.presetNotes.stringValue rangeOfString:@"下一首或重新播放时生效"].location != NSNotFound &&
           [kvAfterPick[@"volume"] isEqualToString:@"-120"],
           "C4c 播放中 onPickPlayMode 不停播不改音量且明确提示下一首或重新播放生效",
           [NSString stringWithFormat:@"inflight=%@ final=%@ vol=%@",
            inflightNote, vc.presetNotes.stringValue ?: @"nil", kvAfterPick[@"volume"] ?: @"nil"]);

        // ---------- C5 真实几何自适应（宽4/中2/窄1 等宽 + 单层滚动 + 页头入口）----------
        CK(FindById(vc.view, @"room.folders") != nil, "C5a 页头存在音乐文件夹入口 room.folders", @"");

        // 统计垂直 NSScrollView 数量（必须恰好 1 个）
        NSMutableArray<NSView *> *allViews = [NSMutableArray array];
        CollectViews(vc.view, allViews);
        int vertScrolls = 0;
        for (NSView *v in allViews) {
            if ([v isKindOfClass:[NSScrollView class]] && ((NSScrollView *)v).hasVerticalScroller)
                ++vertScrolls;
        }
        CK(vertScrolls == 1, "C5b 页面只有一个垂直滚动容器（单层滚动）",
           [NSString stringWithFormat:@"vertScrolls=%d", vertScrolls]);

        NSView *c1 = FindById(vc.view, @"room.device");
        NSView *c2 = FindById(vc.view, @"room.output");
        NSView *c3 = FindById(vc.view, @"room.play");
        NSView *c4 = FindById(vc.view, @"room.style");

        // 宽窗：4 列等宽一行
        vc.view.frame = NSMakeRect(0, 0, 1100, 760);
        [vc updateResponsiveLayoutForWidth:1052.0];
        [vc.view layoutSubtreeIfNeeded];
        CK(std::fabs(c1.frame.size.width - c2.frame.size.width) <= 1.5 &&
           std::fabs(c2.frame.size.width - c3.frame.size.width) <= 1.5 &&
           std::fabs(c3.frame.size.width - c4.frame.size.width) <= 1.5 &&
           c1.frame.size.width > 150.0 &&
           std::fabs(c1.frame.origin.y - c4.frame.origin.y) <= 1.5,
           "C5c 宽窗 1100px -> 4 列等宽一行",
           [NSString stringWithFormat:@"w=[%.1f,%.1f,%.1f,%.1f]",
            c1.frame.size.width, c2.frame.size.width, c3.frame.size.width, c4.frame.size.width]);

        // 中窗：2 列等宽两行
        vc.view.frame = NSMakeRect(0, 0, 620, 760);
        [vc updateResponsiveLayoutForWidth:572.0];
        [vc.view layoutSubtreeIfNeeded];
        CK(std::fabs(c1.frame.size.width - c2.frame.size.width) <= 1.5 &&
           std::fabs(c1.frame.size.width - c3.frame.size.width) <= 1.5 &&
           std::fabs(c1.frame.origin.y - c2.frame.origin.y) <= 1.5 &&
           c3.frame.origin.y < c1.frame.origin.y - 10.0,
           "C5d 中窗 620px -> 2x2 等宽两行",
           [NSString stringWithFormat:@"y1=%.1f y2=%.1f y3=%.1f",
            c1.frame.origin.y, c2.frame.origin.y, c3.frame.origin.y]);

        // 窄窗：1 列四行等宽
        vc.view.frame = NSMakeRect(0, 0, 340, 760);
        [vc updateResponsiveLayoutForWidth:292.0];
        [vc.view layoutSubtreeIfNeeded];
        CK(std::fabs(c1.frame.size.width - c4.frame.size.width) <= 1.5 &&
           c1.frame.origin.y > c2.frame.origin.y + 10.0 &&
           c2.frame.origin.y > c3.frame.origin.y + 10.0 &&
           c3.frame.origin.y > c4.frame.origin.y + 10.0,
           "C5e 窄窗 340px -> 1 列四行等宽",
           [NSString stringWithFormat:@"y=[%.1f,%.1f,%.1f,%.1f]",
            c1.frame.origin.y, c2.frame.origin.y, c3.frame.origin.y, c4.frame.origin.y]);

        CK([RLPPlayModeFromSettings(@{@"dsd": @"dop256"}) isEqualToString:@"dsd"],
           "C6a legacy dop256 派生 dsd 播放方式", @"");
        CK([RLPPlayModeFromSettings(@{@"dsd": @"native128"}) isEqualToString:@"dsd"],
           "C6b legacy native128 派生 dsd 播放方式", @"");

        // C7 680/820/1180 几何防重叠（聆听室四卡）
        for (NSNumber *wn in @[@680, @820, @1180]) {
            const CGFloat w = wn.doubleValue;
            RLPQuickStartViewController *qvc = [[RLPQuickStartViewController alloc] init];
            qvc.view.frame = NSMakeRect(0, 0, w, 800);
            [qvc updateResponsiveLayoutForWidth:(w - 48.0)];
            [qvc.view layoutSubtreeIfNeeded];
            NSView *q1 = FindById(qvc.view, @"room.device");
            NSView *q2 = FindById(qvc.view, @"room.output");
            NSView *q3 = FindById(qvc.view, @"room.play");
            NSView *q4 = FindById(qvc.view, @"room.style");
            NSArray<NSView *> *cards = @[q1 ?: [NSView new], q2 ?: [NSView new], q3 ?: [NSView new], q4 ?: [NSView new]];
            BOOL overlap = NO;
            for (NSUInteger i = 0; i < cards.count; ++i) {
                NSRect r1 = [cards[i] convertRect:cards[i].bounds toView:qvc.view];
                for (NSUInteger j = i + 1; j < cards.count; ++j) {
                    NSRect r2 = [cards[j] convertRect:cards[j].bounds toView:qvc.view];
                    NSRect inter = NSIntersectionRect(r1, r2);
                    if (inter.size.width > 1.0 && inter.size.height > 1.0) overlap = YES;
                }
            }
            CK(!overlap && q1 && q2 && q3 && q4,
               [[NSString stringWithFormat:@"C7_%d 聆听室四卡无几何重叠", (int)w] UTF8String], @"");
        }

        // C8 聆听室 Hog 回退标签（hogAcquired=NO / fallbackWhy 非空时不得声称 · Hog）
        {
            RLPQuickStartViewController *qvc = [[RLPQuickStartViewController alloc] init];
            (void)qvc.view;
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=coreaudio&hogexcl=1"];
            [qvc reloadSettings];
            for (int spin = 0; spin < 30; ++spin) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            SEL applySel = NSSelectorFromString(@"applyStatusJSON:");
            BOOL hasApply = [qvc respondsToSelector:applySel];
            if (hasApply) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [qvc performSelector:applySel withObject:@{@"ok": @YES, @"hogAcquired": @NO, @"fallbackWhy": @"Device busy"}];
#pragma clang diagnostic pop
            }
            NSTextField *outVal = [qvc valueForKey:@"outputValue"];
            NSString *txt = outVal.stringValue ?: @"";
            CK(hasApply && [txt containsString:@"Hog（已回退）"],
               "C8a 快速开始在 hogAcquired=NO/fallbackWhy 非空时显示 Hog（已回退）", txt);

            if (hasApply) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [qvc performSelector:applySel withObject:@{@"ok": @YES, @"hogAcquired": @YES, @"fallbackWhy": @""}];
#pragma clang diagnostic pop
            }
            NSString *txtOk = outVal.stringValue ?: @"";
            CK(hasApply && [txtOk containsString:@"· Hog"] && ![txtOk containsString:@"已回退"],
               "C8b 快速开始在 hogAcquired=YES 时显示 · Hog", txtOk);
        }

        // ---------- C9 输出浮层 UPnP 发现/具体设备选择 + 切回本地保留本地设备 ----------
        {
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=coreaudio&device=USB-DAC-TEST&volume=-120"];
            RLPQuickStartViewController *ovc = [[RLPOfflineOutputController alloc] init];
            (void)ovc.view;
            [ovc reloadSettings];
            for (int spin = 0; spin < 30; ++spin) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            CK([ovc.localDevice isEqualToString:@"USB-DAC-TEST"],
               "C9a reloadSettings 记忆当前本地设备 USB-DAC-TEST", ovc.localDevice ?: @"nil");

            NSTextField *sub = (NSTextField *)FindById(ovc.view, @"room.subtitle");
            CK(sub != nil && [sub.stringValue rangeOfString:@"微调每一组声音"].location == NSNotFound,
               "C9b 聆听室副标题不是工作台文案", sub.stringValue ?: @"nil");

            [ovc onOpenOutput:nil];
            NSView *popView = ovc.popover.contentViewController.view;
            [popView layoutSubtreeIfNeeded];
            NSPopUpButton *upnpPop = (NSPopUpButton *)FindById(popView, @"output.upnpDevice");
            NSButton *upnpScan = (NSButton *)FindById(popView, @"output.upnpScan");
            NSButton *upnpApply = (NSButton *)FindById(popView, @"output.upnpApply");
            NSButton *hogChk = (NSButton *)FindById(popView, @"output.hogexcl");
            NSButton *caBtn = (NSButton *)FindById(popView, @"coreaudio");
            NSButton *upnpBtn = (NSButton *)FindById(popView, @"upnp");
            CK(popView != nil && upnpPop && upnpScan && upnpApply && hogChk && caBtn && upnpBtn,
               "C9c 输出浮层包含后端选项、UPnP 设备下拉、扫描/应用按钮与 Hog 开关（单层浮层不删功能）", @"");

            // 检查浮层内交互控件无几何重叠
            NSArray<NSView *> *popControls = @[caBtn ?: [NSView new], upnpBtn ?: [NSView new],
                                               upnpPop ?: [NSView new], upnpScan ?: [NSView new],
                                               upnpApply ?: [NSView new], hogChk ?: [NSView new]];
            BOOL popOverlap = NO;
            for (NSUInteger i = 0; i < popControls.count; ++i) {
                NSRect r1 = [popControls[i] convertRect:popControls[i].bounds toView:popView];
                for (NSUInteger j = i + 1; j < popControls.count; ++j) {
                    NSRect r2 = [popControls[j] convertRect:popControls[j].bounds toView:popView];
                    NSRect inter = NSIntersectionRect(r1, r2);
                    if (inter.size.width > 1.0 && inter.size.height > 1.0) popOverlap = YES;
                }
            }
            CK(!popOverlap, "C9d 输出浮层控件无几何重叠", @"");

            // 模拟点击「投放到局域网设备」并注入 /api/cast/devices 真实格式载荷（不触发真实网络扫描）
            [ovc onPickBackend:upnpBtn];
            [ovc applyCastDevicesPayload:@{
                @"ok": @YES,
                @"devices": @[
                    @{@"friendlyName": @"Living Room", @"model": @"Marantz", @"host": @"192.168.1.50",
                      @"location": @"http://192.168.1.50:49152/desc.xml", @"kind": @"upnp"},
                ]
            }];
            CK(upnpPop.enabled && upnpApply.enabled &&
               [[upnpPop.selectedItem representedObject] isEqualToString:@"http://192.168.1.50:49152/desc.xml"],
               "C9e 发现列表填充具体 UPnP 设备并选中 location", [upnpPop.selectedItem representedObject] ?: @"nil");

            [ovc onApplyUpnpOutput:upnpApply];
            for (int spin = 0; spin < 40; ++spin) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            NSDictionary *kvUpnp = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
            CK([kvUpnp[@"backend"] isEqualToString:@"upnp"] &&
               [kvUpnp[@"upnpdev"] isEqualToString:@"http://192.168.1.50:49152/desc.xml"] &&
               [ovc.outputValue.stringValue containsString:@"Living Room"],
               "C9f 应用后 /api/settings 落盘 backend=upnp 与 upnpdev，摘要显示设备名",
               [NSString stringWithFormat:@"bk=%@ upnpdev=%@ out=%@",
                kvUpnp[@"backend"] ?: @"nil", kvUpnp[@"upnpdev"] ?: @"nil", ovc.outputValue.stringValue ?: @"nil"]);

            // 切回本地（coreaudio-shared）：必须保留先前的本地设备 USB-DAC-TEST
            NSButton *sharedBtn = (NSButton *)FindById(popView, @"coreaudio-shared");
            [ovc onPickBackend:sharedBtn];
            for (int spin = 0; spin < 40; ++spin) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            NSDictionary *kvBack = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
            CK([kvBack[@"backend"] isEqualToString:@"coreaudio-shared"] &&
               [kvBack[@"device"] isEqualToString:@"USB-DAC-TEST"],
               "C9g 切回本地后保留先前本地设备 USB-DAC-TEST",
               [NSString stringWithFormat:@"bk=%@ dev=%@", kvBack[@"backend"] ?: @"nil", kvBack[@"device"] ?: @"nil"]);

            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];
        }

        // ---------- N4 聆听室底部入口改成「打开专辑页」，点击进入当前曲所属专辑详情而非曲目详情 ----------
        {
            RLPQuickStartViewController *n4vc = [[RLPQuickStartViewController alloc] init];
            (void)n4vc.view;
            NSButton *openBtn = (NSButton *)FindById(n4vc.view, @"room.openAlbum");
            CK(openBtn != nil && openBtn == n4vc.npOpenButton,
               "N4a 聆听室按钮暴露 room.openAlbum（并与 npOpenButton 一致）",
               openBtn.identifier ?: @"nil");
            CK(openBtn && [openBtn.title isEqualToString:RLPTr(@"打开专辑页")] &&
               ![openBtn.title isEqualToString:RLPTr(@"打开曲目详情")],
               "N4b 按钮标题为「打开专辑页」而非「打开曲目详情」",
               openBtn.title ?: @"nil");
            [n4vc applyLanguage];
            CK(openBtn && [openBtn.title isEqualToString:RLPTr(@"打开专辑页")],
               "N4c 语言刷新后标题仍为「打开专辑页」",
               openBtn.title ?: @"nil");

            __block NSInteger npFired = 0;
            NSMutableArray<NSString *> *openedAlbums = [NSMutableArray array];
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            id obNP = [nc addObserverForName:@"RLPOpenNowPlayingNotification" object:nil queue:nil
                                  usingBlock:^(NSNotification *note) {
                (void)note;
                ++npFired;
            }];
            id obAlb = [nc addObserverForName:RLPOpenAlbumNotification object:nil queue:nil
                                   usingBlock:^(NSNotification *note) {
                if ([note.object isKindOfClass:[NSString class]]) [openedAlbums addObject:note.object];
            }];

            n4vc.currentPath = @"/offline/ArtistA/SymphonyB/01.flac";
            n4vc.lastMetaDict = @{@"title": @"Mov I", @"album": @"Symphony Album B", @"artist": @"Conductor A"};
            RLPAlbum *alb0 = [[RLPAlbum alloc] init];
            alb0.key = @"alb-other"; alb0.name = @"Other Album"; alb0.artist = @"Someone";
            RLPAlbum *alb1 = [[RLPAlbum alloc] init];
            alb1.key = @"alb-sym-b"; alb1.name = @"Symphony Album B"; alb1.artist = @"Conductor A";
            n4vc.albumsData = @[alb0, alb1];

            CK(openBtn && openBtn.enabled && openBtn.target == n4vc && openBtn.action == @selector(onOpenCurrentAlbum:),
               "N4d openBtn 绑定 onOpenCurrentAlbum:",
               NSStringFromSelector(openBtn.action ?: NULL));
            [NSApp sendAction:openBtn.action to:openBtn.target from:openBtn];
            CK(npFired == 0 && openedAlbums.count == 1 && [openedAlbums.lastObject isEqualToString:@"alb-sym-b"],
               "N4e 点击打开当前曲所属专辑页（key=alb-sym-b）且不再打开 track detail",
               [NSString stringWithFormat:@"np=%ld albums=%@", (long)npFired, openedAlbums]);

            // direct albumKey 路径
            n4vc.albumsData = @[];
            n4vc.lastMetaDict = @{@"title": @"Mov I", @"album": @"Direct", @"albumKey": @"alb-direct-key"};
            [NSApp sendAction:openBtn.action to:openBtn.target from:openBtn];
            CK(npFired == 0 && openedAlbums.count == 2 && [openedAlbums.lastObject isEqualToString:@"alb-direct-key"],
               "N4f metadata 含 albumKey 时直接打开对应专辑详情",
               [NSString stringWithFormat:@"np=%ld albums=%@", (long)npFired, openedAlbums]);

            // albumsData 为空时走 /api/lib/albums?q= 查询回落
            n4vc.albumsData = @[];
            n4vc.lastMetaDict = @{@"title": @"Mov II", @"album": @"Fallback Album", @"artist": @"Fallback Artist"};
            Method getM = class_getInstanceMethod(RLPCoreClient.class, @selector(getJSON:completion:));
            IMP origGet = method_getImplementation(getM);
            __block NSString *queriedURL = nil;
            IMP mockGet = imp_implementationWithBlock(^(id selfObj, NSString *path, RLPJSONCompletion done) {
                (void)selfObj;
                queriedURL = path;
                if (done) {
                    done(@{@"ok": @YES,
                           @"albums": @[@{@"k": @"alb-fallback-k", @"name": @"Fallback Album", @"artist": @"Fallback Artist"}]});
                }
            });
            method_setImplementation(getM, mockGet);
            @try {
                [NSApp sendAction:openBtn.action to:openBtn.target from:openBtn];
            } @finally {
                method_setImplementation(getM, origGet);
                imp_removeBlock(mockGet);
            }
            CK(npFired == 0 && queriedURL && [queriedURL hasPrefix:@"/api/lib/albums?q="] &&
               openedAlbums.count == 3 && [openedAlbums.lastObject isEqualToString:@"alb-fallback-k"],
               "N4g 本地列表未命中时查询 /api/lib/albums?q= 并进入匹配专辑详情（key=alb-fallback-k）",
               [NSString stringWithFormat:@"url=%@ np=%ld albums=%@", queriedURL ?: @"nil", (long)npFired, openedAlbums]);

            [nc removeObserver:obNP];
            [nc removeObserver:obAlb];
        }

        // 隔离：B1/B2/B3 会在离屏主窗里创建额外 VC，放在核心契约全部跑完后避免污染 C9 的设备/设置状态。
        TestRoomCoverAndCacheFitB1B2B3();
        TestListeningQueueFollow();

        [core shutdown];
        [fm removeItemAtPath:root error:nil];
        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "native_listening_contract 全部通过" : "native_listening_contract 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}
