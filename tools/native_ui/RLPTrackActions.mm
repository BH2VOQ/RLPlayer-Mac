// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPTrackActions.h"
#import "RLPCoreClient.h"
#import "RLPAnalysisSummary.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import <objc/runtime.h>

/// 一次性弹层的按钮目标：用 block 承载动作，避免为每个弹层再建一个控制器类。
/// 生命周期用 associated object 挂在按钮上（按钮活着它就活着）。
@interface RLPActionTarget : NSObject
- (instancetype)initWithBlock:(void (^)(void))block;
- (void)fire;
@end
@implementation RLPActionTarget {
    void (^_block)(void);
}
- (instancetype)initWithBlock:(void (^)(void))block {
    if ((self = [super init])) _block = [block copy];
    return self;
}
- (void)fire { if (_block) _block(); }
@end

static BOOL IsLocal(NSString *p) {
    return p.length && [p hasPrefix:@"/"] && ![p hasPrefix:@"//"];
}

/// 弹层里的滚动文本区（体检/对比结果都用它）。
static NSTextView *MakeResultView(CGFloat w, CGFloat h) {
    RLPTheme *t = [RLPTheme current];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    tv.editable = NO;
    tv.selectable = YES;
    tv.drawsBackground = NO;
    tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    tv.textColor = t.text;
    tv.textContainerInset = NSMakeSize(4, 6);
    return tv;
}

static NSStackView *SheetStack(NSString *title, NSString *note) {
    RLPTheme *t = [RLPTheme current];
    NSStackView *s = [[NSStackView alloc] init];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 8;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *ti = RLPLabel(title, [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], t.text);
    [s addArrangedSubview:ti];
    if (note.length) {
        NSTextField *no = RLPLabel(note, t.small, t.mut);
        no.maximumNumberOfLines = 0;
        no.lineBreakMode = NSLineBreakByWordWrapping;
        no.preferredMaxLayoutWidth = 420;
        [[no.widthAnchor constraintEqualToConstant:420] setActive:YES];
        [s addArrangedSubview:no];
    }
    return s;
}

#pragma mark - 通用表格

@implementation RLPTrackActionTableView
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    if (row < 0 || row >= self.numberOfRows) return nil;
    if (![self isRowSelected:row])
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    NSString *path = self.pathForRow ? self.pathForRow(row) : nil;
    NSMenu *m = RLPTrackMenuForPath(path, self.removeTarget, nil, self.removeAction);
    return m ?: self.menu;
}
@end

#pragma mark - 菜单

NSMenu *RLPTrackMenuForPath(NSString *path, id target, SEL playAction, SEL removeAction) {
    if (!path.length) return nil;
    NSMenu *m = [[NSMenu alloc] init];
    m.autoenablesItems = NO;

    void (^add)(NSString *, RLPTrackActionTag) = ^(NSString *title, RLPTrackActionTag tag) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:RLPTr(title)
                                                   action:@selector(rlp_trackMenuAction:)
                                            keyEquivalent:@""];
        it.tag = tag;
        it.representedObject = path;
        it.target = nil;              // 走 responder chain，最终由 RLPHandleTrackAction 处理
        [m addItem:it];
    };

    add(@"播放", RLPTrackActionPlay);
    add(@"加入播放队列", RLPTrackActionEnqueue);
    add(@"收藏", RLPTrackActionFavorite);
    [m addItem:[NSMenuItem separatorItem]];
    add(@"保存到歌单…", RLPTrackActionSaveToSQ);
    // 体检与对比只对本地文件有意义（web 同口径：网络曲目没有本地路径）
    if (IsLocal(path)) {
        add(@"音质体检…", RLPTrackActionQuality);
        add(@"对比同目录版本…", RLPTrackActionCompare);
        add(@"AI 补全资料", RLPTrackActionEnrich);
    }
    if (removeAction) {
        [m addItem:[NSMenuItem separatorItem]];
        NSMenuItem *rm = [[NSMenuItem alloc] initWithTitle:RLPTr(@"从队列移除") action:removeAction keyEquivalent:@""];
        rm.tag = RLPTrackActionRemove;
        rm.representedObject = path;
        rm.target = target;
        [m addItem:rm];
    }
    (void)playAction;   // 播放统一走 RLPTrackActionPlay，保留参数以兼容既有调用签名
    return m;
}

BOOL RLPHandleTrackAction(NSMenuItem *item, NSView *anchor) {
    NSString *path = [item.representedObject isKindOfClass:[NSString class]] ? item.representedObject : nil;
    if (!path.length) return NO;
    switch (item.tag) {
        case RLPTrackActionPlay:
            RLPPlayPath(path);
            return YES;
        case RLPTrackActionEnqueue:
            RLPEnqueuePath(path);
            RLPToast(RLPTr(@"已加入队列"));
            return YES;
        case RLPTrackActionFavorite: {
            // web toggleFav / 行尾心形（ui_script.h:1869-1905）是**双向开关**：
            // 已收藏再点 = 取消（on=0），未收藏 = 加（on=1）。旧码恒发 on=1 ⟹ 右键「收藏」
            // 只能加不能取消，与 web 行尾心形相悖。当前态以 /api/fav/list 为真相源（不凭本地缓存猜）。
            [[RLPCoreClient shared] getJSON:@"/api/fav/list" completion:^(NSDictionary * _Nullable list) {
                BOOL isFav = NO;
                NSArray *files = [list[@"files"] isKindOfClass:[NSArray class]] ? list[@"files"] : @[];
                for (id f in files) {
                    NSString *fp = nil;
                    if ([f isKindOfClass:[NSString class]]) fp = (NSString *)f;
                    else if ([f isKindOfClass:[NSDictionary class]] && [f[@"file"] isKindOfClass:[NSString class]])
                        fp = (NSString *)f[@"file"];
                    if ([fp isEqualToString:path]) { isFav = YES; break; }
                }
                NSString *u = [NSString stringWithFormat:@"/api/fav?file=%@&on=%d", RLPEnc(path), isFav ? 0 : 1];
                [[RLPCoreClient shared] postJSON:u body:@"" completion:^(NSDictionary * _Nullable j) {
                    const BOOL ok = (j && [j[@"ok"] boolValue]);
                    if (!ok) { RLPToast(isFav ? RLPTr(@"取消收藏失败") : RLPTr(@"收藏失败")); return; }
                    RLPToast(isFav ? RLPTr(@"已取消收藏") : RLPTr(@"已收藏"));
                }];
            }];
            return YES;
        }
        case RLPTrackActionSaveToSQ:
            RLPShowSaveToPlaylist(path, anchor);
            return YES;
        case RLPTrackActionQuality:
            RLPShowQualitySheet(path, anchor);
            return YES;
        case RLPTrackActionCompare:
            RLPShowCompareSheet(path, anchor);
            return YES;
        case RLPTrackActionEnrich: {
            // AI 资料补全：后端跑检索并回填标签，UI 只如实转达结果（不自己编"已优化"）。
            RLPToast(RLPTr(@"正在补全资料…"));
            NSString *u = [NSString stringWithFormat:@"/api/enrich?file=%@", RLPEnc(path)];
            [[RLPCoreClient shared] getJSON:u completion:^(NSDictionary * _Nullable j) {
                if (!j || ![j[@"ok"] boolValue]) {
                    NSString *note = [j[@"note"] isKindOfClass:[NSString class]] ? j[@"note"] : nil;
                    RLPToast(note.length ? note : RLPTr(@"补全失败"));
                    return;
                }
                if ([j[@"skipped"] boolValue]) { RLPToast(RLPTr(@"已跳过（资料已完整或未开启补全）")); return; }
                NSArray *fields = [j[@"fields"] isKindOfClass:[NSArray class]] ? j[@"fields"] : @[];
                NSString *note = [j[@"note"] isKindOfClass:[NSString class]] ? j[@"note"] : @"";
                NSString *msg = fields.count
                    ? [NSString stringWithFormat:@"%@%@%@", RLPTr(@"已补全："),
                       [fields componentsJoinedByString:@"、"], note.length ? [@" · " stringByAppendingString:note] : @""]
                    : (note.length ? note : RLPTr(@"没有可补全的字段"));
                RLPToast(msg);
            }];
            return YES;
        }
        default:
            return NO;   // Remove 由页面自己处理（它知道行号）
    }
}

#pragma mark - 音质体检

void RLPShowQualitySheet(NSString *path, NSView *anchor) {
    if (!IsLocal(path)) { RLPToast(RLPTr(@"仅本地文件可分析")); return; }
    NSStackView *s = SheetStack(RLPTr(@"音质体检"), path.lastPathComponent);
    NSTextView *out = MakeResultView(430, 260);
    out.string = RLPTr(@"正在分析…");
    NSScrollView *sc = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sc.drawsBackground = NO; sc.hasVerticalScroller = YES; sc.documentView = out;
    sc.translatesAutoresizingMaskIntoConstraints = NO;
    [[sc.widthAnchor constraintEqualToConstant:430] setActive:YES];
    [[sc.heightAnchor constraintEqualToConstant:260] setActive:YES];
    [s addArrangedSubview:sc];

    NSViewController *vc = RLPCardController(s, 460, 320);
    NSView *a = anchor ?: NSApp.keyWindow.contentView;
    if (a) RLPShowCardPopover(a, vc, 460);

    NSString *u = [NSString stringWithFormat:@"/api/health?file=%@", RLPEnc(path)];
    [[RLPCoreClient shared] getJSON:u completion:^(NSDictionary * _Nullable j) {
        if (!j || ![j[@"ok"] boolValue]) {
            out.string = [j[@"error"] isKindOfClass:[NSString class]] ? j[@"error"] : RLPTr(@"分析失败");
            return;
        }
        // 后端返回的是**外层** {ok, usable, cached, ms, stats, health:{…}}；摘要与完整性提示
        // 都住在 health 内层 ⟹ 先解外层（旧代码直接把外层传给摘要函数，指标会被读成"缺失"）。
        NSDictionary *hh = RLPAnlUnwrapHealth(j) ?: j;
        // 摘要三行 + 明细：数字全部来自后端，UI 只排版（铁律 3）
        NSMutableString *txt = [NSMutableString string];
        // U10：半截文件的提示摆在摘要**之前**（后端 note 原样，绝不写死文案）
        if (RLPAnlIncomplete(hh) && [hh[@"note"] isKindOfClass:[NSString class]] &&
            [(NSString *)hh[@"note"] length])
            [txt appendFormat:@"%@\n\n", hh[@"note"]];
        [txt appendFormat:@"%@：%@\n", RLPTr(@"动态"), RLPAnlSumDyn(hh)];
        [txt appendFormat:@"%@：%@\n", RLPTr(@"音质"), RLPAnlSumQual(hh)];
        [txt appendFormat:@"%@：%@\n\n", RLPTr(@"假无损"), RLPAnlSumFake(hh)];
        [txt appendString:RLPAnlDetailText(hh, RLPAnlLevelFull, NO, nil, path)];
        out.string = txt;
    }];
}

#pragma mark - 保存到歌单

void RLPShowSaveToPlaylist(NSString *path, NSView *anchor) {
    NSStackView *s = SheetStack(RLPTr(@"保存到歌单"), RLPTr(@"选一个歌单，或新建一个。"));
    RLPTheme *t = [RLPTheme current];
    NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    pop.translatesAutoresizingMaskIntoConstraints = NO;
    pop.font = t.body;
    [[pop.widthAnchor constraintEqualToConstant:300] setActive:YES];
    [pop addItemWithTitle:RLPTr(@"读取中…")];
    [s addArrangedSubview:pop];

    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *newName = [[NSTextField alloc] initWithFrame:NSZeroRect];
    newName.placeholderString = RLPTr(@"新歌单名");
    newName.translatesAutoresizingMaskIntoConstraints = NO;
    [[newName.widthAnchor constraintEqualToConstant:180] setActive:YES];
    NSButton *ok = [NSButton buttonWithTitle:RLPTr(@"保存") target:nil action:nil];
    ok.bezelStyle = NSBezelStyleRounded;
    ok.keyEquivalent = @"\r";
    [row addArrangedSubview:newName];
    [row addArrangedSubview:ok];
    [s addArrangedSubview:row];

    NSViewController *vc = RLPCardController(s, 340, 170);
    NSView *a = anchor ?: NSApp.keyWindow.contentView;
    NSPopover *pop2 = a ? RLPShowCardPopover(a, vc, 340) : nil;

    [[RLPCoreClient shared] getJSON:@"/api/sq/list" completion:^(NSDictionary * _Nullable j) {
        NSArray *qs = [j[@"queues"] isKindOfClass:[NSArray class]] ? j[@"queues"] : @[];
        [pop removeAllItems];
        if (!qs.count) [pop addItemWithTitle:RLPTr(@"（还没有歌单，请在下面新建）")];
        for (id q in qs) {
            if (![q isKindOfClass:[NSDictionary class]]) continue;
            NSString *n = [q[@"name"] isKindOfClass:[NSString class]] ? q[@"name"] : nil;
            if (!n.length) continue;
            NSNumber *cnt = [q[@"n"] isKindOfClass:[NSNumber class]] ? q[@"n"] : @0;
            [pop addItemWithTitle:[NSString stringWithFormat:@"%@（%@）", n, cnt]];
            [[pop lastItem] setRepresentedObject:n];
        }
    }];

    // 用 block 包装保存动作（避免为一次性弹层再建一个控制器类）
    RLPActionTarget *tgt = [[RLPActionTarget alloc] initWithBlock:^{
        NSString *name = newName.stringValue.length ? newName.stringValue
                        : [pop.selectedItem.representedObject isKindOfClass:[NSString class]] ? pop.selectedItem.representedObject : nil;
        if (!name.length) { RLPToast(RLPTr(@"请先选歌单或填新名字")); return; }
        NSString *u = [NSString stringWithFormat:@"/api/sq/add?name=%@&file=%@", RLPEnc(name), RLPEnc(path)];
        [[RLPCoreClient shared] postJSON:u body:@"" completion:^(NSDictionary * _Nullable j) {
            if (j && [j[@"ok"] boolValue]) {
                RLPToast([NSString stringWithFormat:@"%@「%@」", RLPTr(@"已加入歌单"), name]);
                [pop2 close];
            } else if (j && [j[@"duplicate"] boolValue]) {
                RLPToast(RLPTr(@"已在歌单中"));
            } else {
                RLPToast([j[@"error"] isKindOfClass:[NSString class]] ? j[@"error"] : RLPTr(@"添加失败"));
            }
        }];
    }];
    ok.target = tgt;
    ok.action = @selector(fire);
    objc_setAssociatedObject(ok, "rlp_target", tgt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - 版本对比

void RLPShowCompareSheet(NSString *path, NSView *anchor) {
    if (!IsLocal(path)) { RLPToast(RLPTr(@"仅本地文件可对比")); return; }
    NSString *dir = path.stringByDeletingLastPathComponent;
    RLPTheme *t = [RLPTheme current];
    NSStackView *s = SheetStack(RLPTr(@"对比同目录版本"), RLPTr(@"勾选 2–8 个版本，分数与排名由后端算出。"));
    NSStackView *list = [[NSStackView alloc] init];
    list.orientation = NSUserInterfaceLayoutOrientationVertical;
    list.alignment = NSLayoutAttributeLeading;
    list.spacing = 3;
    list.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:list];
    NSTextView *out = MakeResultView(430, 200);
    NSScrollView *sc = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sc.drawsBackground = NO; sc.hasVerticalScroller = YES; sc.documentView = out;
    sc.translatesAutoresizingMaskIntoConstraints = NO;
    [[sc.widthAnchor constraintEqualToConstant:430] setActive:YES];
    [[sc.heightAnchor constraintEqualToConstant:200] setActive:YES];
    [s addArrangedSubview:sc];
    NSButton *go = [NSButton buttonWithTitle:RLPTr(@"开始对比") target:nil action:nil];
    go.bezelStyle = NSBezelStyleRounded;
    [s addArrangedSubview:go];

    NSViewController *vc = RLPCardController(s, 460, 380);
    NSView *a = anchor ?: NSApp.keyWindow.contentView;
    if (a) RLPShowCardPopover(a, vc, 460);

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableArray<NSButton *> *checks = [NSMutableArray array];
    [[RLPCoreClient shared] getJSON:[NSString stringWithFormat:@"/api/files?dir=%@", RLPEnc(dir)]
        completion:^(NSDictionary * _Nullable j) {
        NSArray *names = [j[@"files"] isKindOfClass:[NSArray class]] ? j[@"files"] : @[];
        NSString *base = path.lastPathComponent;
        for (id n in names) {
            if (![n isKindOfClass:[NSString class]]) continue;
            NSButton *c = [NSButton checkboxWithTitle:n target:nil action:nil];
            c.font = t.small;
            c.state = [n isEqualToString:base] ? NSControlStateValueOn : NSControlStateValueOff;
            [list addArrangedSubview:c];
            [checks addObject:c];
            [paths addObject:[dir stringByAppendingPathComponent:n]];
        }
        if (!names.count) out.string = RLPTr(@"该目录下没有可对比的音频文件");
    }];

    RLPActionTarget *tgt = [[RLPActionTarget alloc] initWithBlock:^{
        NSMutableArray *sel = [NSMutableArray array];
        for (NSUInteger i = 0; i < checks.count; ++i)
            if (checks[i].state == NSControlStateValueOn) [sel addObject:paths[i]];
        if (sel.count < 2) { RLPToast(RLPTr(@"至少勾选 2 个版本")); return; }
        if (sel.count > 8) { RLPToast(RLPTr(@"一次最多 8 个版本")); return; }
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *p in sel) [parts addObject:[NSString stringWithFormat:@"file=%@", RLPEnc(p)]];
        out.string = RLPTr(@"正在对齐并分析…");
        [[RLPCoreClient shared] postJSON:@"/api/compare" body:[parts componentsJoinedByString:@"&"]
            completion:^(NSDictionary * _Nullable r) {
            if (!r || ![r[@"ok"] boolValue]) {
                out.string = [r[@"error"] isKindOfClass:[NSString class]] ? r[@"error"] : RLPTr(@"对比失败");
                return;
            }
            NSMutableString *o = [NSMutableString string];
            if (![r[@"sameTrack"] boolValue])
                [o appendFormat:@"%@\n", RLPTr(@"⚠ 包络相关偏低，这些文件可能不是同一首曲子")];
            [o appendFormat:@"%@\n", RLPTr(@"排序（好 → 差）")];
            NSArray *vs = [r[@"versions"] isKindOfClass:[NSArray class]] ? r[@"versions"] : @[];
            for (id idx in ([r[@"ranking"] isKindOfClass:[NSArray class]] ? r[@"ranking"] : @[])) {
                NSInteger i = [idx integerValue];
                if (i < 0 || i >= (NSInteger)vs.count) continue;
                NSDictionary *v = vs[i];
                [o appendFormat:@"  %@  %@ — %@\n", v[@"label"] ?: @"",
                    [v[@"path"] lastPathComponent] ?: @"",
                    [v[@"score"] isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%.1f", [v[@"score"] doubleValue]] : @"NA"];
            }
            [o appendString:@"\n"];
            for (NSDictionary *row in ([r[@"rows"] isKindOfClass:[NSArray class]] ? r[@"rows"] : @[])) {
                [o appendFormat:@"%@:", row[@"label"] ?: @""];
                NSArray *vals = [row[@"values"] isKindOfClass:[NSArray class]] ? row[@"values"] : @[];
                for (NSUInteger k = 0; k < vals.count; ++k) {
                    NSString *num = [vals[k] isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%.2f", [vals[k] doubleValue]] : @"NA";
                    const BOOL best = ([row[@"bestIndex"] integerValue] == (NSInteger)k) && [row[@"comparable"] boolValue];
                    [o appendFormat:@"  %@%@", num, best ? @"*" : @""];
                }
                [o appendString:@"\n"];
            }
            if ([r[@"explanation"] length]) [o appendFormat:@"\n%@\n", r[@"explanation"]];
            out.string = o;
        }];
    }];
    go.target = tgt;
    go.action = @selector(fire);
    objc_setAssociatedObject(go, "rlp_target", tgt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
