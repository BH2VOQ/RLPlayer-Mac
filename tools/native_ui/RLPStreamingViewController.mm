// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPStreamingViewController.mm — 流媒体浏览（对齐 web 远程页）
//
// web 口径（ui_script.h remoteCardHtml / REMOTE_VIEW）：
//   * 默认**网格**（封面卡片），可切列表；偏好写 /api/settings remoteview（白名单已有）。
//   * 卡片 = 封面（/api/src/cover?id=cv）+ 标题 + 副标题（艺术家 · 专辑；目录显示「文件夹」）。
//   * 没封面（cv 空）**不发请求**，直接首字母占位（web 同口径，避免破图闪烁）。
//   * 单击：目录进下一层，曲目起播；只有曲目画播放角标（目录不该有播放键）。
//   * 返回上一级 + 面包屑。
#import "RLPStreamingViewController.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#pragma mark - 网格卡片（与专辑页同款观感）

@class RLPStreamItem;

@interface RLPStreamCardView : NSView
@property (nonatomic, weak) RLPStreamItem *item;
@end

@interface RLPStreamItem : NSCollectionViewItem
@property (nonatomic, strong) NSImageView *coverView;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *subLabel;
@property (nonatomic, strong) NSTextField *placeholderLabel;
@property (nonatomic, strong) NSButton *playBadge;
@property (nonatomic, copy) NSString *itemId;
@property (nonatomic, assign) BOOL isDir;
@property (nonatomic, copy, nullable) void (^onOpen)(NSString *itemId, BOOL isDir);
- (void)setEntry:(NSDictionary *)entry;
- (void)applyTheme;
- (void)cardHoverChanged:(BOOL)on;
@end

@implementation RLPStreamCardView {
    NSTrackingArea *_area;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_area) { [self removeTrackingArea:_area]; _area = nil; }
    _area = [[NSTrackingArea alloc] initWithRect:self.bounds
                                        options:(NSTrackingMouseEnteredAndExited |
                                                 NSTrackingActiveInKeyWindow |
                                                 NSTrackingInVisibleRect)
                                          owner:self userInfo:nil];
    [self addTrackingArea:_area];
}
- (void)mouseEntered:(NSEvent *)e { (void)e; [self.item cardHoverChanged:YES]; }
- (void)mouseExited:(NSEvent *)e { (void)e; [self.item cardHoverChanged:NO]; }
// 单击 = 打开（web 行 onclick 同语义）。
- (void)mouseDown:(NSEvent *)e {
    (void)e;
    RLPStreamItem *it = (RLPStreamItem *)self.item;
    if (it.onOpen) it.onOpen(it.itemId, it.isDir);
}
@end

@implementation RLPStreamItem {
    BOOL _hovered;
}
- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    RLPStreamCardView *v = [[RLPStreamCardView alloc] initWithFrame:NSMakeRect(0, 0, 168, 214)];
    v.item = self;
    v.wantsLayer = YES;
    self.view = v;

    _coverView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _coverView.wantsLayer = YES;
    _coverView.layer.cornerRadius = 8;
    _coverView.layer.masksToBounds = YES;
    _coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _coverView.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_coverView];

    _placeholderLabel = [NSTextField labelWithString:@"♪"];
    _placeholderLabel.font = [NSFont systemFontOfSize:30 weight:NSFontWeightLight];
    _placeholderLabel.textColor = t.mut;
    _placeholderLabel.alignment = NSTextAlignmentCenter;
    _placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_placeholderLabel];

    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _nameLabel.textColor = t.text;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.maximumNumberOfLines = 1;
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_nameLabel];

    _subLabel = [NSTextField labelWithString:@""];
    _subLabel.font = [NSFont systemFontOfSize:11.5];
    _subLabel.textColor = t.mut;
    _subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _subLabel.maximumNumberOfLines = 1;
    _subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_subLabel];

    // 播放角标只给曲目（目录点了是进入下一层，web 同口径）。
    _playBadge = [[NSButton alloc] initWithFrame:NSZeroRect];
    _playBadge.bordered = NO;
    _playBadge.imagePosition = NSImageOnly;
    _playBadge.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:RLPTr(@"播放")];
    _playBadge.contentTintColor = NSColor.whiteColor;
    _playBadge.wantsLayer = YES;
    _playBadge.layer.cornerRadius = 16;
    _playBadge.layer.backgroundColor = t.accent.CGColor;
    _playBadge.hidden = YES;
    _playBadge.target = self;
    _playBadge.action = @selector(onBadge:);
    _playBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_playBadge];

    [NSLayoutConstraint activateConstraints:@[
        [_coverView.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_coverView.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_coverView.topAnchor constraintEqualToAnchor:v.topAnchor],
        // 封面 1:1 正方形（对齐专辑卡与 web aspect-ratio:1，消除非正方形裁切与底部 6pt 截断）
        [_coverView.heightAnchor constraintEqualToAnchor:_coverView.widthAnchor],
        [_placeholderLabel.centerXAnchor constraintEqualToAnchor:_coverView.centerXAnchor],
        [_placeholderLabel.centerYAnchor constraintEqualToAnchor:_coverView.centerYAnchor],
        [_playBadge.trailingAnchor constraintEqualToAnchor:_coverView.trailingAnchor constant:-8],
        [_playBadge.bottomAnchor constraintEqualToAnchor:_coverView.bottomAnchor constant:-8],
        [_playBadge.widthAnchor constraintEqualToConstant:32],
        [_playBadge.heightAnchor constraintEqualToConstant:32],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-2],
        [_nameLabel.topAnchor constraintEqualToAnchor:_coverView.bottomAnchor constant:8],
        [_subLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_subLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_subLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
    ]];
}

- (void)setEntry:(NSDictionary *)entry {
    RLPTheme *t = [RLPTheme current];
    self.itemId = [entry[@"id"] isKindOfClass:[NSString class]] ? entry[@"id"] : @"";
    self.isDir = [entry[@"dir"] respondsToSelector:@selector(boolValue)] && [entry[@"dir"] boolValue];
    NSString *name = [entry[@"t"] isKindOfClass:[NSString class]] ? entry[@"t"] : @"?";
    self.nameLabel.stringValue = name;
    // 副标题：目录 = 「文件夹」；曲目 = 艺术家 · 专辑（缺的段不拼空串，web 同口径）。
    if (self.isDir) {
        self.subLabel.stringValue = RLPTr(@"文件夹");
    } else {
        NSMutableArray<NSString *> *sub = [NSMutableArray array];
        NSString *ar = [entry[@"ar"] isKindOfClass:[NSString class]] ? entry[@"ar"] : @"";
        NSString *al = [entry[@"al"] isKindOfClass:[NSString class]] ? entry[@"al"] : @"";
        if (ar.length) [sub addObject:ar];
        if (al.length) [sub addObject:al];
        self.subLabel.stringValue = [sub componentsJoinedByString:@" · "];
    }
    self.playBadge.hidden = YES;   // 悬停才浮起；目录永远不显示
    self.coverView.image = nil;
    self.coverView.layer.backgroundColor = t.bg2.CGColor;
    self.placeholderLabel.hidden = NO;
    self.placeholderLabel.stringValue = name.length ? [[name substringToIndex:1] uppercaseString] : @"♪";
    // 封面：cv 为空不发请求（web 同口径）。异步回填时校验 itemId 仍是当前条目（复用防错位）。
    NSString *cv = [entry[@"cv"] isKindOfClass:[NSString class]] ? entry[@"cv"] : @"";
    if (cv.length) {
        NSString *wantId = self.itemId;
        __weak __typeof__(self) weakSelf = self;
        [[RLPCoverLoader shared] coverForSourceId:cv completion:^(NSImage * _Nullable img) {
            __typeof__(self) self_ = weakSelf;
            if (!self_ || ![self_.itemId isEqualToString:wantId] || !img) return;
            self_.coverView.image = img;
            self_.placeholderLabel.hidden = YES;
        }];
    }
    [self applyTheme];
}

- (void)onBadge:(id)sender {
    (void)sender;
    if (!self.isDir && self.onOpen) self.onOpen(self.itemId, NO);
}

- (void)cardHoverChanged:(BOOL)on {
    _hovered = on;
    self.playBadge.hidden = self.isDir || !on;
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.nameLabel.textColor = t.text;
    self.subLabel.textColor = t.mut;
    self.placeholderLabel.textColor = t.mut;
    self.coverView.layer.backgroundColor = t.bg2.CGColor;
    self.playBadge.layer.backgroundColor = t.accent.CGColor;
}
@end

#pragma mark - 控制器

@interface RLPStreamingViewController () <NSTableViewDelegate, NSTableViewDataSource,
                                          NSCollectionViewDataSource, NSCollectionViewDelegate> {
    NSTableView *_tableView;
    NSScrollView *_listScroll;
    NSCollectionView *_grid;
    NSScrollView *_gridScroll;
    NSPopUpButton *_serverPicker;
    NSSegmentedControl *_viewToggle;
    NSTextField *_pathBreadcrumb;
    NSButton *_backButton;

    NSArray<NSDictionary *> *_servers;
    NSMutableArray *_breadcrumbStack;
    NSArray<NSDictionary *> *_items;
    NSUInteger _requestSeq;
    BOOL _gridMode;
    // 未配置服务器时的整页空态卡（web loadRemote 的 err 分支：标题 + 说明 + 去设置 + 重试）。
    NSView *_emptyCard;
    NSTextField *_emptyHint;
    NSTextField *_emptyTitle;
    NSButton *_emptyGoBtn;
    NSButton *_emptyRetryBtn;
    NSButton *_refreshBtn;
    NSButton *_pingBtn;
    NSString *_lastEmptyReason;
    NSString *_lastEmptyReasonZhKey;
    NSString *_lastSubtitleZhKey;
    BOOL _hasLoaded;
    CGFloat _lastLayoutWidth;
    BOOL _relayouting;
}
@end

@implementation RLPStreamingViewController

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"流媒体")];
    if (self) {
        _breadcrumbStack = [NSMutableArray array];
        _gridMode = YES;   // web 缺省 = 网格
    }
    return self;
}

- (void)buildContent {
    [super buildContent];

    NSStackView *toolbar = [NSStackView stackViewWithViews:@[]];
    toolbar.edgeInsets = NSEdgeInsetsMake(0, 0, 10, 0);

    _serverPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_serverPicker setTarget:self];
    [_serverPicker setAction:@selector(serverChanged:)];
    [toolbar addView:_serverPicker inGravity:NSStackViewGravityLeading];

    NSButton *refreshBtn = RLPSymbolButton(@"arrow.clockwise", RLPTr(@"刷新"), self, @selector(refresh:));
    _refreshBtn = refreshBtn;
    [toolbar addView:refreshBtn inGravity:NSStackViewGravityLeading];

    NSButton *pingBtn = [NSButton buttonWithTitle:RLPTr(@"测试连接") target:self action:@selector(onPing:)];
    pingBtn.bezelStyle = NSBezelStyleRounded;
    _pingBtn = pingBtn;
    [toolbar addView:pingBtn inGravity:NSStackViewGravityLeading];

    _backButton = RLPSymbolButton(@"arrow.left", RLPTr(@"上一级"), self, @selector(goBack:));
    _backButton.enabled = NO;
    [toolbar addView:_backButton inGravity:NSStackViewGravityLeading];

    // 网格 / 列表两档（web remoteToolsHtml 同语义）。
    _viewToggle = [NSSegmentedControl segmentedControlWithLabels:@[RLPTr(@"网格"), RLPTr(@"列表")]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(viewToggleChanged:)];
    _viewToggle.selectedSegment = _gridMode ? 0 : 1;
    [toolbar addView:_viewToggle inGravity:NSStackViewGravityLeading];

    _pathBreadcrumb = RLPLabel(@"", [NSFont systemFontOfSize:12], RLPTheme.current.mut);
    _pathBreadcrumb.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _pathBreadcrumb.maximumNumberOfLines = 1;
    [_pathBreadcrumb setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [toolbar addView:_pathBreadcrumb inGravity:NSStackViewGravityLeading];

    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:toolbar];

    // ---- 列表视图 ----
    _tableView = [[NSTableView alloc] initWithFrame:self.contentView.bounds];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.headerView = nil;
    _tableView.rowHeight = 40;
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.backgroundColor = RLPTheme.current.bg;
    if (@available(macOS 11.0, *)) _tableView.style = NSTableViewStylePlain;
    _tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    // 单击即触发（web 行 onclick 同语义）；双击保留兼容。
    _tableView.action = @selector(rowClicked:);
    _tableView.doubleAction = @selector(rowClicked:);
    _tableView.target = self;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:col];
    _listScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _listScroll.documentView = _tableView;
    _listScroll.hasVerticalScroller = YES;
    _listScroll.drawsBackground = NO;
    _listScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_listScroll];
    if (_listScroll.contentView) {
        _listScroll.contentView.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clipViewFrameDidChange:)
                                                     name:NSViewFrameDidChangeNotification
                                                   object:_listScroll.contentView];
    }

    // ---- 网格视图 ----
    NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
    layout.itemSize = NSMakeSize(152, 194);
    layout.minimumInteritemSpacing = 16;
    layout.minimumLineSpacing = 16;
    layout.sectionInset = NSEdgeInsetsMake(4, 4, 16, 4);
    _grid = [[NSCollectionView alloc] initWithFrame:NSMakeRect(0, 0, 674, 520)];
    _grid.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _grid.collectionViewLayout = layout;
    _grid.dataSource = self;
    _grid.delegate = self;
    _grid.backgroundColors = @[[NSColor clearColor]];
    [_grid registerClass:[RLPStreamItem class] forItemWithIdentifier:@"StreamCard"];
    _gridScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _gridScroll.documentView = _grid;
    _gridScroll.hasVerticalScroller = YES;
    _gridScroll.autohidesScrollers = YES;
    _gridScroll.drawsBackground = NO;
    _gridScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_gridScroll];
    if (_gridScroll.contentView) {
        _gridScroll.contentView.postsFrameChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clipViewFrameDidChange:)
                                                     name:NSViewFrameDidChangeNotification
                                                   object:_gridScroll.contentView];
    }

    // ---- 未配置服务器的空态卡（web：'还没有可浏览的流媒体服务器' + 说明 + 去设置里配置/重试）----
    _emptyCard = [[NSView alloc] initWithFrame:NSZeroRect];
    _emptyCard.identifier = @"remote.empty";
    _emptyCard.wantsLayer = YES;
    _emptyCard.hidden = YES;
    _emptyCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_emptyCard];
    {
        NSTextField *title = RLPLabel(RLPTr(@"还没有可浏览的流媒体服务器"),
                                      [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
                                      RLPTheme.current.text);
        title.identifier = @"remote.empty.title";
        title.maximumNumberOfLines = 0;
        title.lineBreakMode = NSLineBreakByWordWrapping;
        [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *hint = RLPLabel(@"", [NSFont systemFontOfSize:12.5], RLPTheme.current.mut);
        hint.identifier = @"remote.empty.hint";
        hint.maximumNumberOfLines = 0;
        hint.lineBreakMode = NSLineBreakByWordWrapping;
        [hint setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        hint.translatesAutoresizingMaskIntoConstraints = NO;
        NSButton *go = [NSButton buttonWithTitle:RLPTr(@"去设置里配置") target:self action:@selector(onGoConfigureServer:)];
        go.bezelStyle = NSBezelStyleRounded;
        go.identifier = @"remote.empty.goset";
        go.translatesAutoresizingMaskIntoConstraints = NO;
        NSButton *retry = [NSButton buttonWithTitle:RLPTr(@"重试") target:self action:@selector(onRetryRemote:)];
        retry.bezelStyle = NSBezelStyleRounded;
        retry.identifier = @"remote.empty.retry";
        retry.translatesAutoresizingMaskIntoConstraints = NO;
        for (NSView *v in @[title, hint, go, retry]) [_emptyCard addSubview:v];
        _emptyTitle = title;
        _emptyHint = hint;
        _emptyGoBtn = go;
        _emptyRetryBtn = retry;
        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor constraintEqualToAnchor:_emptyCard.leadingAnchor constant:26],
            [title.trailingAnchor constraintEqualToAnchor:_emptyCard.trailingAnchor constant:-26],
            [title.topAnchor constraintEqualToAnchor:_emptyCard.topAnchor constant:24],
            [hint.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [hint.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
            [hint.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
            [go.leadingAnchor constraintEqualToAnchor:hint.leadingAnchor],
            [go.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:14],
            [retry.leadingAnchor constraintEqualToAnchor:go.trailingAnchor constant:8],
            [retry.centerYAnchor constraintEqualToAnchor:go.centerYAnchor],
            [_emptyCard.bottomAnchor constraintEqualToAnchor:go.bottomAnchor constant:20],
        ]];
    }
    NSLayoutConstraint *emptyPrefW = [_emptyCard.widthAnchor constraintEqualToConstant:560];
    emptyPrefW.priority = 450; // 低于 NSLayoutPriorityWindowSizeStayPut(500)，窄窗下收窄不顶窗
    [NSLayoutConstraint activateConstraints:@[
        emptyPrefW,
        [_emptyCard.widthAnchor constraintLessThanOrEqualToConstant:560],
        [_emptyCard.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_emptyCard.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_emptyCard.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_emptyCard.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:40],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [toolbar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [toolbar.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [toolbar.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [_listScroll.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_listScroll.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_listScroll.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:10],
        [_listScroll.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
        [_gridScroll.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_gridScroll.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_gridScroll.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:10],
        [_gridScroll.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
    ]];
    [self applyViewMode];
}

/// web 的空态卡：未配置时整页给「还没有可浏览的流媒体服务器」+ 说明 + 去设置 + 重试。
/// 旧实现只弹一个 toast、内容区留白 —— 用户看不出下一步该做什么（评审 #7 在 web 侧修过同样的问题）。
- (void)showEmptyStateForConfigured:(BOOL)configured reason:(NSString *)reason {
    _emptyCard.hidden = configured;
    _gridScroll.hidden = !configured || !_gridMode;
    _listScroll.hidden = !configured || _gridMode;
    // 没有服务器时，工具栏上的「服务器下拉 / 刷新 / 测试连接 / 上一级」全是**无对象**的操作：
    // 下拉是空的、测试连接点不动、上一级本来就 disabled。留着只会让页面顶层看起来
    // 是一排坏掉的控件（离屏截图实测）。空态卡里已经有「去设置里配置 / 重试」两个真入口，
    // 所以这台面上不需要这些。网格/列表切换同理由空态接管。
    if (!configured) {
        _serverPicker.hidden = YES;
        _refreshBtn.hidden = YES;
        _pingBtn.hidden = YES;
        _backButton.hidden = YES;
        _viewToggle.hidden = YES;
    } else {
        _serverPicker.hidden = NO;
        _refreshBtn.hidden = NO;
        _pingBtn.hidden = NO;
        _backButton.hidden = NO;
        _viewToggle.hidden = NO;
    }
    if (configured) {
        _lastEmptyReason = nil;
        _lastEmptyReasonZhKey = nil;
        return;
    }
    _lastEmptyReason = [reason copy];
    _emptyHint.stringValue = [NSString stringWithFormat:@"%@\n%@",
        reason.length ? reason : RLPTr(@"还没有流媒体服务器"),
        RLPTr(@"支持 Navidrome / Subsonic / Emby（只取原始文件，不转码）。先在「设置 → 流媒体」添加并启用一台服务器，保存后回到这里即可浏览。")];
}

/// 判据入口：空态卡当前是否可见（运行时探针用，不改业务状态）。
- (BOOL)emptyStateVisible { return _emptyCard != nil && !_emptyCard.hidden; }

- (void)onGoConfigureServer:(id)sender {
    (void)sender;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPOpenSettingsPaneNotification"
                                                        object:@"stream"];
}

- (void)onRetryRemote:(id)sender {
    (void)sender;
    [self reloadData];
}

- (CGFloat)effectiveGridWidth {
    if (_gridScroll && _gridScroll.contentView && _gridScroll.contentView.bounds.size.width > 1.0) {
        return _gridScroll.contentView.bounds.size.width;
    }
    const CGFloat viewW = self.contentView.bounds.size.width;
    if (viewW > 33.0) return viewW - 32.0;
    return 0.0;
}

- (void)relayoutGridForWidth:(CGFloat)w {
    if (w <= 1.0 || ![_grid.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]) return;
    NSCollectionViewFlowLayout *l = (NSCollectionViewFlowLayout *)_grid.collectionViewLayout;
    const CGFloat pad = 4.0, gap = 16.0, minW = 152.0;
    const CGFloat avail = MAX(80.0, w - pad * 2.0);
    NSInteger cols = (avail >= minW) ? (NSInteger)floor((avail + gap) / (minW + gap)) : 1;
    if (cols < 1) cols = 1;
    const CGFloat itemW = (avail >= minW) ? floor((avail - gap * (cols - 1)) / cols) : floor(avail);
    const CGFloat itemH = itemW + 42.0;
    const BOOL widthChanged = fabs(_lastLayoutWidth - w) >= 0.5;
    const BOOL itemChanged = fabs(l.itemSize.width - itemW) >= 0.5 || fabs(l.itemSize.height - itemH) >= 0.5;
    const BOOL colWidthMismatch = fabs(_grid.frame.size.width - w) >= 0.5;
    if (!widthChanged && !itemChanged && !colWidthMismatch) return;
    _lastLayoutWidth = w;
    l.itemSize = NSMakeSize(itemW, itemH);
    if (colWidthMismatch) {
        NSRect cf = _grid.frame;
        cf.size.width = w;
        _grid.frame = cf;
    }
    [l invalidateLayout];
}

- (void)syncListColumnWidth {
    if (!_tableView || !_listScroll || _tableView.tableColumns.count == 0) return;
    CGFloat avail = NSWidth(_listScroll.contentView.bounds);
    if (avail <= 1.0 && NSWidth(self.contentView.bounds) > 33.0) {
        avail = NSWidth(self.contentView.bounds) - 32.0;
    }
    if (avail <= 1.0) return;
    NSTableColumn *col = _tableView.tableColumns[0];
    BOOL changed = NO;
    if (fabs(col.width - avail) >= 0.5) {
        col.width = avail;
        changed = YES;
    }
    NSRect tf = _tableView.frame;
    if (fabs(tf.size.width - avail) >= 0.5) {
        tf.size.width = avail;
        _tableView.frame = tf;
        changed = YES;
    }
    if (changed) [_tableView tile];
}

- (void)clipViewFrameDidChange:(NSNotification *)note {
    (void)note;
    if (_relayouting) return;
    _relayouting = YES;
    if (_listScroll && !_listScroll.hidden) {
        [self syncListColumnWidth];
    }
    if (_gridScroll && !_gridScroll.hidden && _gridScroll.contentView) {
        const CGFloat w = _gridScroll.contentView.bounds.size.width;
        if (w > 1.0) {
            [self relayoutGridForWidth:w];
            [_grid setNeedsLayout:YES];
            [self.view setNeedsLayout:YES];
        }
    }
    _relayouting = NO;
}

- (void)viewWillLayout {
    [super viewWillLayout];
    [self syncListColumnWidth];
    const CGFloat w = [self effectiveGridWidth];
    if (w > 1.0) [self relayoutGridForWidth:w];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    if (_relayouting) return;
    _relayouting = YES;
    [self syncListColumnWidth];
    for (int pass = 0; pass < 2; ++pass) {
        const CGFloat w = [self effectiveGridWidth];
        if (w <= 1.0) break;
        NSCollectionViewFlowLayout *l = [_grid.collectionViewLayout isKindOfClass:[NSCollectionViewFlowLayout class]]
            ? (NSCollectionViewFlowLayout *)_grid.collectionViewLayout : nil;
        const CGFloat prevItemW = l ? l.itemSize.width : 0.0;
        const CGFloat prevColW = _grid.frame.size.width;
        const CGFloat prevLastW = _lastLayoutWidth;
        [self relayoutGridForWidth:w];
        const BOOL changed = (l && fabs(l.itemSize.width - prevItemW) >= 0.5) ||
                             fabs(_grid.frame.size.width - prevColW) >= 0.5 ||
                             fabs(_lastLayoutWidth - prevLastW) >= 0.5;
        if (!_gridScroll || _gridScroll.hidden) break;
        if (changed || pass == 0) {
            [_gridScroll layoutSubtreeIfNeeded];
        } else {
            break;
        }
        const CGFloat nextW = [self effectiveGridWidth];
        if (fabs(nextW - w) < 0.5) break;
    }
    _relayouting = NO;
}

- (void)applyViewMode {
    _gridScroll.hidden = !_gridMode;
    _listScroll.hidden = _gridMode;
    _viewToggle.selectedSegment = _gridMode ? 0 : 1;
    if (_gridMode) {
        const CGFloat w = [self effectiveGridWidth];
        if (w > 1.0) [self relayoutGridForWidth:w];
    } else {
        [self syncListColumnWidth];
    }
}

- (void)viewToggleChanged:(NSSegmentedControl *)sender {
    _gridMode = (sender.selectedSegment == 0);
    [self applyViewMode];
    // 偏好落配置文件（web remoteViewSet 同口径：remoteview 键已在后端白名单）。
    [[RLPCoreClient shared] postJSON:@"/api/settings"
        body:[NSString stringWithFormat:@"remoteview=%@", _gridMode ? @"grid" : @"list"]
        completion:nil];
    [self reloadItems];
}

- (void)reloadItems {
    [_tableView reloadData];
    [_grid reloadData];
}

- (void)updateBreadcrumbDisplay {
    _backButton.enabled = _breadcrumbStack.count > 0;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSDictionary *it in _breadcrumbStack) {
        NSString *t = [it[@"t"] isKindOfClass:[NSString class]] ? it[@"t"] : @"";
        NSString *i = [it[@"id"] isKindOfClass:[NSString class]] ? it[@"id"] : @"";
        if (t.length) [parts addObject:t];
        else if (i.length) [parts addObject:i];
    }
    _pathBreadcrumb.stringValue = [parts componentsJoinedByString:@" / "];
}

- (void)reloadData {
    [super reloadData];
    _lastSubtitleZhKey = nil;
    _lastEmptyReasonZhKey = nil;
    NSUInteger seq = ++_requestSeq;
    __weak __typeof__(self) weakSelf = self;
    [RLPCoreClient.shared getJSON:@"/api/src/config" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_->_requestSeq) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_->_items = nil;
            [self_ reloadItems];
            NSString *rawErr = ([json[@"error"] isKindOfClass:[NSString class]] && [json[@"error"] length])
                          ? json[@"error"] : nil;
            self_->_lastSubtitleZhKey = rawErr ? nil : @"浏览失败";
            self_->_lastEmptyReasonZhKey = rawErr ? nil : @"浏览失败";
            NSString *err = rawErr ?: RLPTr(@"浏览失败");
            [self_ setSubtitle:err];
            [self_ showEmptyStateForConfigured:NO reason:err];
            return;
        }

        self_->_servers = [json[@"servers"] isKindOfClass:[NSArray class]] ? json[@"servers"] : @[];
        [self_->_serverPicker removeAllItems];
        NSString *activeId = [json[@"active"] isKindOfClass:[NSString class]] ? json[@"active"] : @"";
        NSInteger activeIdx = -1;
        for (NSInteger i = 0; i < (NSInteger)self_->_servers.count; ++i) {
            NSDictionary *s = self_->_servers[(NSUInteger)i];
            [self_->_serverPicker addItemWithTitle:s[@"name"] ?: @""];
            if (activeIdx < 0) {
                BOOL isAct = [s[@"active"] respondsToSelector:@selector(boolValue)] && [s[@"active"] boolValue];
                NSString *sid = [s[@"id"] isKindOfClass:[NSString class]] ? s[@"id"] : @"";
                if (isAct || (activeId.length && [sid isEqualToString:activeId])) {
                    activeIdx = i;
                }
            }
        }
        if (activeIdx >= 0 && activeIdx < self_->_serverPicker.numberOfItems) {
            [self_->_serverPicker selectItemAtIndex:activeIdx];
        }

        if (![json[@"configured"] boolValue] || self_->_servers.count == 0) {
            self_->_items = nil;
            [self_ reloadItems];
            self_->_lastSubtitleZhKey = @"未配置服务器";
            self_->_lastEmptyReasonZhKey = @"还没有流媒体服务器";
            [self_ setSubtitle:RLPTr(@"未配置服务器")];
            [self_ showEmptyStateForConfigured:NO reason:RLPTr(@"还没有流媒体服务器")];
            return;
        }
        [self_ showEmptyStateForConfigured:YES reason:@""];
        [self_->_breadcrumbStack removeAllObjects];
        [self_ updateBreadcrumbDisplay];

        [self_ browseId:@""];
    }];
    // 显示偏好：读 remoteview（web 同一键），读不到保持网格缺省。
    [RLPCoreClient.shared getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSDictionary *kv = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : nil;
        NSString *rv = [kv[@"remoteview"] isKindOfClass:[NSString class]] ? kv[@"remoteview"] : nil;
        if (!rv.length) return;
        BOOL wantGrid = ![rv isEqualToString:@"list"];
        if (wantGrid != self_->_gridMode) {
            self_->_gridMode = wantGrid;
            [self_ applyViewMode];
            [self_ reloadItems];
        }
    }];
}

- (void)browseId:(NSString *)key {
    NSUInteger seq = ++_requestSeq;
    _lastSubtitleZhKey = nil;
    _lastEmptyReasonZhKey = nil;
    NSString *url = [NSString stringWithFormat:@"/api/src/browse?id=%@", RLPEnc(key ?: @"")];
    __weak __typeof__(self) weakSelf = self;
    [RLPCoreClient.shared getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_->_requestSeq) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_->_items = nil;
            [self_ reloadItems];
            NSString *rawErr = ([json[@"error"] isKindOfClass:[NSString class]] && [json[@"error"] length])
                          ? json[@"error"] : nil;
            self_->_lastSubtitleZhKey = rawErr ? nil : @"浏览失败";
            self_->_lastEmptyReasonZhKey = rawErr ? nil : @"浏览失败";
            NSString *err = rawErr ?: RLPTr(@"浏览失败");
            [self_ setSubtitle:err];
            [self_ showEmptyStateForConfigured:NO reason:err];
            return;
        }

        NSString *err = [json[@"err"] isKindOfClass:[NSString class]] ? json[@"err"] : @"";
        NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        if (err.length > 0 && items.count == 0) {
            self_->_items = nil;
            [self_ reloadItems];
            self_->_lastSubtitleZhKey = nil;
            self_->_lastEmptyReasonZhKey = nil;
            [self_ setSubtitle:err];
            [self_ showEmptyStateForConfigured:NO reason:err];
            return;
        }
        self_->_lastSubtitleZhKey = nil;
        self_->_lastEmptyReasonZhKey = nil;
        self_->_items = items;
        [self_ showEmptyStateForConfigured:YES reason:@""];
        [self_ setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 项"), (long)self_->_items.count]];
        [self_ reloadItems];
    }];
}

/// 测试当前选中服务器的连通性。POST /api/src/ping?id=N。
- (void)onPing:(id)sender {
    if (![RLPCoreClient shared].started) { RLPToast(RLPTr(@"核心未启动")); return; }
    const NSInteger idx = _serverPicker.indexOfSelectedItem;
    if (idx < 0 || idx >= (NSInteger)_servers.count) { RLPToast(RLPTr(@"请先选择一台服务器")); return; }
    NSString *sid = [_servers[idx][@"id"] isKindOfClass:[NSString class]] ? _servers[idx][@"id"] : @"";
    if (!sid.length) { RLPToast(RLPTr(@"这台服务器没有可用标识")); return; }
    NSString *url = [NSString stringWithFormat:@"/api/src/ping?id=%@", RLPEnc(sid)];
    RLPToast(RLPTr(@"正在测试连接…"));
    [[RLPCoreClient shared] postJSON:url body:nil completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) {
            NSString *note = [json[@"note"] isKindOfClass:[NSString class]] ? json[@"note"] : @"";
            RLPToast(note.length ? note : RLPTr(@"连接正常"));
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"连接失败");
            RLPToast(err);
        }
    }];
}

- (void)serverChanged:(id)sender {
    (void)sender;
    NSInteger idx = [_serverPicker indexOfSelectedItem];
    if (idx < 0 || idx >= (NSInteger)_servers.count) return;
    NSDictionary *s = _servers[(NSUInteger)idx];
    NSString *sid = [s[@"id"] isKindOfClass:[NSString class]] ? s[@"id"] : @"";
    NSString *body = [NSString stringWithFormat:@"action=active&id=%@", RLPEnc(sid)];
    __weak __typeof__(self) weakSelf = self;
    [RLPCoreClient.shared postJSON:@"/api/src/config" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [json[@"error"] length])
                          ? json[@"error"] : RLPTr(@"切换服务器失败");
            RLPToast(err);
            [self_ setSubtitle:err];
            [self_ reloadData];
            return;
        }
        [self_->_breadcrumbStack removeAllObjects];
        [self_ updateBreadcrumbDisplay];
        self_->_items = nil;
        [self_ reloadItems];
        [self_ reloadData];
    }];
}

- (void)refresh:(id)sender { [self browseId:_breadcrumbStack.lastObject[@"id"] ?: @""]; }

- (void)goBack:(id)sender {
    [_breadcrumbStack removeLastObject];
    [self updateBreadcrumbDisplay];
    [self browseId:_breadcrumbStack.lastObject[@"id"] ?: @""];
}

/// 打开条目：目录进下一层，曲目起播（网格单击 / 列表单击 / 播放角标共用）。
- (void)openItemId:(NSString *)itemId isDir:(BOOL)isDir {
    if (!itemId.length) return;
    if (isDir) {
        NSString *title = @"";
        for (NSDictionary *it in _items)
            if ([it[@"id"] isEqualToString:itemId]) { title = it[@"t"] ?: @""; break; }
        [_breadcrumbStack addObject:@{@"id": itemId, @"t": title}];
        [self updateBreadcrumbDisplay];
        [self browseId:itemId];
    } else {
        RLPPlayPath(itemId);
    }
}

- (void)rowClicked:(id)sender {
    NSInteger row = [_tableView clickedRow];
    if (row < 0 || row >= (NSInteger)_items.count) return;
    NSDictionary *item = _items[row];
    [self openItemId:item[@"id"] isDir:[item[@"dir"] boolValue]];
}

#pragma mark - 列表数据

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_items.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    RLPTheme *t = [RLPTheme current];
    NSDictionary *item = _items[row];
    // 行 = 小封面 + 标题/副标题（web 列表档同口径）。
    NSStackView *cell = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 600, 40)];
    cell.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    cell.alignment = NSLayoutAttributeCenterY;
    cell.spacing = 10;

    NSImageView *cv = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    cv.wantsLayer = YES;
    cv.layer.cornerRadius = 5;
    cv.layer.masksToBounds = YES;
    cv.layer.backgroundColor = t.bg2.CGColor;
    cv.imageScaling = NSImageScaleProportionallyUpOrDown;
    [cv.widthAnchor constraintEqualToConstant:32].active = YES;
    [cv.heightAnchor constraintEqualToConstant:32].active = YES;
    NSString *coverId = [item[@"cv"] isKindOfClass:[NSString class]] ? item[@"cv"] : @"";
    if (coverId.length) {
        [[RLPCoverLoader shared] coverForSourceId:coverId completion:^(NSImage * _Nullable img) {
            if (img) cv.image = img;
        }];
    }
    [cell addArrangedSubview:cv];

    NSStackView *text = [[NSStackView alloc] initWithFrame:NSZeroRect];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 1;
    [text setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *name = RLPLabel(item[@"t"] ?: @"", [NSFont systemFontOfSize:13], t.text);
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    name.maximumNumberOfLines = 1;
    [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSString *sub;
    if ([item[@"dir"] boolValue]) {
        sub = RLPTr(@"文件夹");
    } else {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if ([item[@"ar"] length]) [parts addObject:item[@"ar"]];
        if ([item[@"al"] length]) [parts addObject:item[@"al"]];
        sub = [parts componentsJoinedByString:@" · "];
    }
    NSTextField *subLabel = RLPLabel(sub, [NSFont systemFontOfSize:11], t.mut);
    subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    subLabel.maximumNumberOfLines = 1;
    [subLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [text addArrangedSubview:name];
    [text addArrangedSubview:subLabel];
    [cell addArrangedSubview:text];
    return cell;
}

#pragma mark - 网格数据

- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)_items.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView
     itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    RLPStreamItem *item = [collectionView makeItemWithIdentifier:@"StreamCard" forIndexPath:indexPath];
    NSInteger idx = indexPath.item;
    if (idx >= 0 && idx < (NSInteger)_items.count) {
        [item setEntry:_items[idx]];
        __weak __typeof__(self) weakSelf = self;
        item.onOpen = ^(NSString *itemId, BOOL isDir) {
            [weakSelf openItemId:itemId isDir:isDir];
        };
    }
    return item;
}

- (void)applyTheme {
    [super applyTheme];
    if (!self.isViewLoaded) return;
    RLPTheme *t = [RLPTheme current];
    _tableView.backgroundColor = t.bg;
    _listScroll.backgroundColor = t.bg;
    _grid.backgroundColors = @[[NSColor clearColor]];
    _pathBreadcrumb.textColor = t.mut;
    _emptyTitle.textColor = t.text;
    _emptyHint.textColor = t.mut;
    NSIndexSet *tSel = [_tableView.selectedRowIndexes copy];
    NSPoint tOrigin = _listScroll ? _listScroll.contentView.bounds.origin : NSZeroPoint;
    NSSet<NSIndexPath *> *gSel = [_grid.selectionIndexPaths copy];
    NSPoint gOrigin = _gridScroll ? _gridScroll.contentView.bounds.origin : NSZeroPoint;
    [self reloadItems];
    if (tSel.count) [_tableView selectRowIndexes:tSel byExtendingSelection:NO];
    if (_listScroll) {
        [_listScroll.contentView scrollToPoint:tOrigin];
        [_listScroll reflectScrolledClipView:_listScroll.contentView];
    }
    if (gSel.count) _grid.selectionIndexPaths = gSel;
    if (_gridScroll) {
        [_gridScroll.contentView scrollToPoint:gOrigin];
        [_gridScroll reflectScrolledClipView:_gridScroll.contentView];
    }
}

- (void)activate { [super activate]; }

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"流媒体");
    if (!self.isViewLoaded) return;
    _refreshBtn.toolTip = RLPTr(@"刷新");
    _pingBtn.title = RLPTr(@"测试连接");
    _backButton.toolTip = RLPTr(@"上一级");
    [_viewToggle setLabel:RLPTr(@"网格") forSegment:0];
    [_viewToggle setLabel:RLPTr(@"列表") forSegment:1];
    _emptyTitle.stringValue = RLPTr(@"还没有可浏览的流媒体服务器");
    _emptyGoBtn.title = RLPTr(@"去设置里配置");
    _emptyRetryBtn.title = RLPTr(@"重试");
    if (!_emptyCard.hidden) {
        NSString *r = _lastEmptyReasonZhKey.length
            ? RLPTr(_lastEmptyReasonZhKey)
            : (_lastEmptyReason.length ? _lastEmptyReason : RLPTr(@"还没有流媒体服务器"));
        _emptyHint.stringValue = [NSString stringWithFormat:@"%@\n%@", r,
            RLPTr(@"支持 Navidrome / Subsonic / Emby（只取原始文件，不转码）。先在「设置 → 流媒体」添加并启用一台服务器，保存后回到这里即可浏览。")];
    }
    if (_lastSubtitleZhKey.length) {
        [self setSubtitle:RLPTr(_lastSubtitleZhKey)];
    } else if (_servers.count == 0 && !_emptyCard.hidden) {
        [self setSubtitle:RLPTr(@"未配置服务器")];
    } else if (_items.count > 0) {
        [self setSubtitle:[NSString stringWithFormat:RLPTr(@"%ld 项"), (long)_items.count]];
    }
    NSIndexSet *tSel = [_tableView.selectedRowIndexes copy];
    NSPoint tOrigin = _listScroll ? _listScroll.contentView.bounds.origin : NSZeroPoint;
    [_tableView reloadData];
    if (tSel.count) [_tableView selectRowIndexes:tSel byExtendingSelection:NO];
    if (_listScroll) {
        [_listScroll.contentView scrollToPoint:tOrigin];
        [_listScroll reflectScrolledClipView:_listScroll.contentView];
    }
    NSSet<NSIndexPath *> *gSel = [_grid.selectionIndexPaths copy];
    NSPoint gOrigin = _gridScroll ? _gridScroll.contentView.bounds.origin : NSZeroPoint;
    [_grid reloadData];
    if (gSel.count) _grid.selectionIndexPaths = gSel;
    if (_gridScroll) {
        [_gridScroll.contentView scrollToPoint:gOrigin];
        [_gridScroll reflectScrolledClipView:_gridScroll.contentView];
    }
}

@end