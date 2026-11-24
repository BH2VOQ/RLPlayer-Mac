// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPPageViewController.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@implementation RLPPageViewController {
    NSView *_root;
    NSView *_content;
    NSTextField *_title;
    NSTextField *_subtitle;
    BOOL _clampingScrollViews;
    BOOL _clampScheduled;
    NSHashTable<NSView *> *_observedLayoutViews;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithNibName:nil bundle:nil];
    if (self) _pageTitle = [title copy];
    return self;
}

/// 兜底：子类若走 [super initWithNibName:bundle:]（而不是 initWithTitle:），
/// _pageTitle 会是 nil，loadView 里 RLPLabel(nil, …) 直接抛异常把进程带走。
/// 页面基础类不该因为子类选错初始化器就崩，所以这里补一个空串默认值。
/// （--selftest 的"每个页面可离线构建"断言就是这么抓到这个问题的。）
- (instancetype)initWithNibName:(NSNibName)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self && !_pageTitle) _pageTitle = @"";
    return self;
}

- (NSTextField *)titleLabel { return _title; }
- (NSTextField *)subtitleLabel { return _subtitle; }
- (NSView *)contentView { return _content; }

/// P8：标题在页面加载后变化（歌单名 / 搜索词）时，顶栏必须立即跟随 —— 旧实现 pageTitle
/// 只读，歌单页的标题于是永远是 init 时的「歌单」，web 的 head(name, …) 语义丢失。
/// 顶栏由主窗口绘制（web #pth），这里通过窗口控制器上的 syncTopbarTitle 接缝刷新；
/// 页面没有 windowController（单测/离屏）时静默跳过，绝不因标题变化强行找窗口。
- (void)setPageTitle:(NSString *)title {
    _pageTitle = [title copy] ?: @"";
    if (_title) _title.stringValue = RLPTr(_pageTitle);
    if (!self.isViewLoaded) return;
    NSWindowController *wc = self.view.window.windowController;
    if ([wc respondsToSelector:@selector(syncTopbarTitle)])
        [(id)wc performSelector:@selector(syncTopbarTitle)];
}

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    _root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 674, 520)];
    _root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _root.wantsLayer = YES;
    _root.layer.backgroundColor = t.bg.CGColor;
    self.view = _root;

    _title = RLPLabel(_pageTitle, [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold], t.text);
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _title.maximumNumberOfLines = 1;
    [_title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    _title.translatesAutoresizingMaskIntoConstraints = NO;
    // 标题统一由主窗口顶栏承载（web #pth 同口径）；页内不再画大标题，
    // 但保留 18+17+12 的顶部留白，内容起始位置与 web 一致。
    _title.hidden = YES;
    [_root addSubview:_title];

    _subtitle = RLPLabel(@"", t.small, t.mut);
    _subtitle.alignment = NSTextAlignmentRight;
    _subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    _subtitle.maximumNumberOfLines = 1;
    [_subtitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    _subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [_root addSubview:_subtitle];

    _content = [[NSView alloc] initWithFrame:NSZeroRect];
    _content.translatesAutoresizingMaskIntoConstraints = NO;
    [_root addSubview:_content];

    [NSLayoutConstraint activateConstraints:@[
        [_title.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:24],
        [_title.topAnchor constraintEqualToAnchor:_root.topAnchor constant:18],
        [_subtitle.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-24],
        [_subtitle.firstBaselineAnchor constraintEqualToAnchor:_title.firstBaselineAnchor],
        [_subtitle.leadingAnchor constraintGreaterThanOrEqualToAnchor:_title.trailingAnchor constant:12],
        [_content.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor],
        [_content.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor],
        [self usesPageHeaderSpacing] ? [_content.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:12] : [_content.topAnchor constraintEqualToAnchor:_root.topAnchor],
        [_content.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor],
    ]];

    [self buildContent];
}

- (BOOL)usesPageHeaderSpacing { return YES; }
- (void)buildContent {}

- (void)ensureContentScrollViewsLayout {
    if (!_content) return;
    const NSSize contentSize = _content.bounds.size;
    if (contentSize.width <= 1.0 || contentSize.height <= 1.0) return;
    for (NSView *sub in _content.subviews) {
        if ([sub isKindOfClass:[NSScrollView class]] && !sub.hidden &&
            sub.translatesAutoresizingMaskIntoConstraints &&
            sub.autoresizingMask == NSViewNotSizable &&
            sub.frame.size.width <= 1.0 && sub.frame.size.height <= 1.0) {
            sub.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            sub.frame = _content.bounds;
            [sub layoutSubtreeIfNeeded];
        }
    }
}

- (void)observeScrollView:(NSScrollView *)sv {
    if (!sv) return;
    if (!_observedLayoutViews) {
        _observedLayoutViews = [NSHashTable weakObjectsHashTable];
    }
    NSView *clip = sv.contentView;
    if (clip && ![_observedLayoutViews containsObject:clip]) {
        [_observedLayoutViews addObject:clip];
        clip.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(observedScrollChildFrameDidChange:)
                                                     name:NSViewFrameDidChangeNotification
                                                   object:clip];
    }
    NSView *doc = sv.documentView;
    if (doc && ![_observedLayoutViews containsObject:doc]) {
        [_observedLayoutViews addObject:doc];
        doc.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(observedScrollChildFrameDidChange:)
                                                     name:NSViewFrameDidChangeNotification
                                                   object:doc];
    }
}

- (void)clampTableColumns:(NSTableView *)tv toBudget:(CGFloat)budget {
    NSArray<NSTableColumn *> *cols = tv.tableColumns;
    if (cols.count == 0 || budget <= 1.0) return;

    CGFloat sumMin = 0.0;
    for (NSTableColumn *col in cols) sumMin += col.minWidth;
    if (sumMin > budget && sumMin > 0.0) {
        const CGFloat scale = budget / sumMin;
        for (NSTableColumn *col in cols) {
            col.minWidth = floor(col.minWidth * scale);
        }
    }

    CGFloat sumW = 0.0;
    CGFloat totalReducible = 0.0;
    for (NSTableColumn *col in cols) {
        sumW += col.width;
        if (col.width > col.minWidth) {
            totalReducible += (col.width - col.minWidth);
        }
    }
    if (sumW > budget && sumW > 0.0) {
        const CGFloat excess = sumW - budget;
        if (totalReducible >= excess && totalReducible > 0.0) {
            const CGFloat ratio = excess / totalReducible;
            for (NSTableColumn *col in cols) {
                const CGFloat reducible = MAX(0.0, col.width - col.minWidth);
                if (reducible > 0.0) {
                    col.width = MAX(col.minWidth, floor(col.width - reducible * ratio));
                }
            }
        } else {
            const CGFloat scale = budget / sumW;
            for (NSTableColumn *col in cols) {
                const CGFloat nw = floor(col.width * scale);
                if (col.minWidth > nw) col.minWidth = nw;
                col.width = nw;
            }
        }
    }
}

- (void)clampSingleScrollView:(NSScrollView *)sv allowTile:(BOOL)allowTile {
    if (!sv || sv.hidden || !sv.contentView || !sv.documentView) return;
    [self observeScrollView:sv];
    const CGFloat clipW = sv.contentView.bounds.size.width;
    if (clipW <= 1.0) return;
    NSView *doc = sv.documentView;
    if ([doc isKindOfClass:[NSCollectionView class]]) return;

    if ([doc isKindOfClass:[NSTableView class]]) {
        // 宽窗保持表格自身列宽契约（tracks_rows 断言 1500 宽内容）；只对 900/940 等窄宿主收口。
        if (clipW >= 1000.0) return;
        NSTableView *tv = (NSTableView *)doc;
        const CGFloat spacing = tv.intercellSpacing.width * (CGFloat)tv.tableColumns.count;
        CGFloat colSum = 0.0;
        for (NSTableColumn *col in tv.tableColumns) colSum += col.width;
        const BOOL needClamp = (tv.frame.size.width > clipW + 1.0) || (colSum + spacing > clipW + 1.0);
        if (!needClamp) return;

        CGFloat budget = MAX(1.0, clipW - spacing);
        [self clampTableColumns:tv toBudget:budget];

        NSRect tf = tv.frame;
        tf.size.width = clipW;
        tv.frame = tf;

        if (allowTile) {
            [tv sizeLastColumnToFit];
            [tv tile];
            if (tv.frame.size.width > clipW + 0.5) {
                CGFloat actualColSum = 0.0;
                for (NSTableColumn *col in tv.tableColumns) actualColSum += col.width;
                const CGFloat extra = tv.frame.size.width - clipW;
                budget = MAX(1.0, MIN(budget, actualColSum) - extra - 1.0);
                [self clampTableColumns:tv toBudget:budget];
                tf = tv.frame;
                tf.size.width = clipW;
                tv.frame = tf;
                [tv sizeLastColumnToFit];
                [tv tile];
            }
            if (tv.frame.size.width > clipW + 0.5) {
                tf = tv.frame;
                tf.size.width = clipW;
                tv.frame = tf;
            }
        }
        return;
    }

    if (sv.hasHorizontalScroller) return;
    if (doc.frame.size.width <= clipW + 1.0) return;

    if (doc.translatesAutoresizingMaskIntoConstraints) {
        doc.autoresizingMask |= NSViewWidthSizable;
        NSRect df = doc.frame;
        df.size.width = clipW;
        doc.frame = df;
    } else {
        BOOL hasCap = NO;
        for (NSLayoutConstraint *c in sv.contentView.constraints) {
            if ([c.identifier isEqualToString:@"rlp.page.docWidthCap"] &&
                (c.firstItem == doc || c.secondItem == doc)) {
                hasCap = YES;
                break;
            }
        }
        if (!hasCap) {
            NSLayoutConstraint *cap = [doc.widthAnchor constraintLessThanOrEqualToAnchor:sv.contentView.widthAnchor];
            cap.priority = 999;
            cap.identifier = @"rlp.page.docWidthCap";
            cap.active = YES;
        }
        [sv.contentView layoutSubtreeIfNeeded];
    }
}

- (void)clampScrollViewsInView:(NSView *)root {
    if (!root) return;
    for (NSView *sub in root.subviews) {
        if ([sub isKindOfClass:[NSScrollView class]]) {
            [self clampSingleScrollView:(NSScrollView *)sub allowTile:YES];
        }
        [self clampScrollViewsInView:sub];
    }
}

- (void)ensureAndClampScrollViews {
    if (_clampingScrollViews || !self.isViewLoaded) return;
    _clampingScrollViews = YES;
    [self ensureContentScrollViewsLayout];
    [self clampScrollViewsInView:self.view];
    _clampingScrollViews = NO;
}

- (void)schedulePostLayoutClamp {
    if (_clampScheduled) return;
    _clampScheduled = YES;
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_->_clampScheduled = NO;
        if (!self_.isViewLoaded || !self_.view.superview) return;
        [self_ ensureAndClampScrollViews];
    });
}

- (void)observedScrollChildFrameDidChange:(NSNotification *)note {
    if (_clampingScrollViews || !self.isViewLoaded) return;
    NSView *sender = [note.object isKindOfClass:[NSView class]] ? (NSView *)note.object : nil;
    if (!sender) return;
    NSScrollView *sv = [sender.superview isKindOfClass:[NSScrollView class]]
        ? (NSScrollView *)sender.superview
        : sender.enclosingScrollView;
    if (!sv || sv.hidden || !sv.contentView || !sv.documentView) return;
    _clampingScrollViews = YES;
    [self clampSingleScrollView:sv allowTile:NO];
    _clampingScrollViews = NO;
    [self schedulePostLayoutClamp];
}

- (void)reloadData {
    [self ensureAndClampScrollViews];
    [self schedulePostLayoutClamp];
}

- (void)activate {
    [self.view setNeedsLayout:YES];
    [self ensureAndClampScrollViews];
    [self reloadData];
    [self ensureAndClampScrollViews];
    [self schedulePostLayoutClamp];
}

- (void)viewWillLayout {
    [super viewWillLayout];
    [self ensureAndClampScrollViews];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    [self ensureAndClampScrollViews];
    [self schedulePostLayoutClamp];
}

- (void)setSubtitle:(NSString *)text {
    _subtitle.stringValue = text.length ? RLPTr(text) : @"";
    if (self.isViewLoaded && self.view.superview) {
        [self schedulePostLayoutClamp];
    }
}

- (void)applyTheme {
    if (!self.isViewLoaded) return;
    RLPTheme *t = [RLPTheme current];
    _root.layer.backgroundColor = t.bg.CGColor;
    _title.textColor = t.text;
    _subtitle.textColor = t.mut;
    [_root setNeedsDisplay:YES];
}

@end
