// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPQuickStartViewController.mm — 聆听室（1.1.7.1 合并页 · 分区卡片与自适应网格重设计）
//
// 设计原则（对齐 Windows/Web 同源信息架构，保留全量就地交互，不增网络请求）：
//   ① 页头：聆听室标题 +「音乐文件夹」就地管理入口（窄窗自动换行防碰撞）。
//   ② 控制区：四张等宽响应式控制卡（当前设备 / 输出 / 播放 / 听音风格）
//            + 下方硬件能力与状态条卡（实时呈报 /api/preset/caps 与切档提示，取代悬空裸文本）。
//   ③ 聆听舞台：正在播放主卡（1:1 封面裁切 / 状态与音频规格徽标 / 进度条与时间 / 播放与详情按钮）
//                + 播放队列预览卡（最多 4 行、当前曲高亮、时长/艺术家信息、无嵌套滚动）。
//   ④ 专辑陈列：响应式多列正方形封面网格（悬停播放角标 + 艺术家/年份/格式副标题 + 完整空态卡）。
//   ⑤ 底部能力区：本地音乐库管理卡（根目录摘要 + 格式芯片 + 扫描/选目录）
//                + 扩展与流媒体伴随卡（「更多」就地弹层，严格不放「设置」按钮）。
//
// 真相源全部来自既有后端，UI 不发明第二套状态：
//   /api/devices /api/settings /api/filters /api/preset/caps /api/lib/roots
//   /api/status /api/queue?meta=1 /api/lib/albums (/api/meta /api/cover /api/lib/cover)
#import "RLPQuickStartViewController.h"
#import "RLPCoreClient.h"
#import "RLPListeningRoom.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <cmath>
#include <cstdio>

#pragma mark - 内部轻量组件：进度条与专辑封面卡

@interface RLPRoomCoverImageView : RLPCoverImageView
@end

@implementation RLPRoomCoverImageView
- (NSSize)intrinsicContentSize { return NSZeroSize; }
- (void)setImage:(NSImage *)image {
    [super setImage:image];
    [self invalidateIntrinsicContentSize];
}
@end

@interface RLPRoomProgressView : NSView
@property (nonatomic, assign) double progress;
@end

@implementation RLPRoomProgressView

- (void)setProgress:(double)progress {
    double clamped = (std::isfinite(progress) && progress > 0.0) ? MIN(1.0, progress) : 0.0;
    if (std::fabs(_progress - clamped) < 0.0005 && _progress == clamped) return;
    _progress = clamped;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    RLPTheme *t = [RLPTheme current];
    NSRect b = self.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return;
    const CGFloat r = b.size.height * 0.5;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:b xRadius:r yRadius:r];
    [t.track setFill];
    [track fill];
    if (_progress > 0.001) {
        CGFloat fw = MAX(b.size.height, b.size.width * (CGFloat)_progress);
        if (fw > b.size.width) fw = b.size.width;
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(b.origin.x, b.origin.y, fw, b.size.height)
                                                             xRadius:r yRadius:r];
        [t.accent setFill];
        [fill fill];
    }
}

@end

@interface RLPRoomAlbumCardView : NSView {
    NSTrackingArea *_hoverArea;
    BOOL _hovered;
}
@property (nonatomic, copy) NSString *albumKey;
@property (nonatomic, strong) NSView *coverBox;
@property (nonatomic, strong) RLPCoverImageView *coverView;
@property (nonatomic, strong) NSTextField *placeholderLabel;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *metaLabel;
@property (nonatomic, strong) NSButton *hitButton;
@property (nonatomic, strong) NSButton *playBadge;
- (instancetype)initWithAlbum:(RLPAlbum *)album
                        index:(NSInteger)idx
                       target:(id)target
                   openAction:(SEL)openAction
                   playAction:(SEL)playAction;
- (void)updateCover:(NSImage * _Nullable)image;
- (void)applyTheme;
- (void)refreshLanguageFromAlbum:(RLPAlbum *)album;
@end

@implementation RLPRoomAlbumCardView

- (instancetype)initWithAlbum:(RLPAlbum *)album
                        index:(NSInteger)idx
                       target:(id)target
                   openAction:(SEL)openAction
                   playAction:(SEL)playAction {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    RLPTheme *t = [RLPTheme current];
    _albumKey = [album.key copy] ?: @"";
    self.identifier = [NSString stringWithFormat:@"room.albumcard.%ld", (long)idx];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.wantsLayer = YES;
    self.layer.cornerRadius = t.rMd;
    self.layer.backgroundColor = t.bg2.CGColor;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = t.line.CGColor;

    _coverBox = [[NSView alloc] initWithFrame:NSZeroRect];
    _coverBox.translatesAutoresizingMaskIntoConstraints = NO;
    _coverBox.wantsLayer = YES;
    _coverBox.layer.cornerRadius = t.rSm;
    _coverBox.layer.masksToBounds = YES;
    _coverBox.layer.backgroundColor = t.cvBg.CGColor;
    _coverBox.layer.borderWidth = 1.0;
    _coverBox.layer.borderColor = t.line.CGColor;
    [_coverBox setContentCompressionResistancePriority:40
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_coverBox];

    _coverView = [[RLPRoomCoverImageView alloc] initWithFrame:NSZeroRect];
    _coverView.translatesAutoresizingMaskIntoConstraints = NO;
    _coverView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _coverView.identifier = [NSString stringWithFormat:@"room.albumcover.%ld", (long)idx];
    [_coverView setContentCompressionResistancePriority:40
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_coverView setContentCompressionResistancePriority:40
                                         forOrientation:NSLayoutConstraintOrientationVertical];
    [_coverView setContentHuggingPriority:40
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_coverView setContentHuggingPriority:40
                             forOrientation:NSLayoutConstraintOrientationVertical];
    [_coverBox addSubview:_coverView];

    NSString *glyph = album.name.length ? [album.name substringToIndex:1] : @"♪";
    _placeholderLabel = RLPLabel(glyph, [NSFont systemFontOfSize:26 weight:NSFontWeightLight], t.mut);
    _placeholderLabel.alignment = NSTextAlignmentCenter;
    _placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_coverBox addSubview:_placeholderLabel];

    _nameLabel = [NSTextField labelWithString:(album.name.length ? album.name : RLPTr(@"未知专辑"))];
    _nameLabel.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    _nameLabel.textColor = t.text;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.maximumNumberOfLines = 1;
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_nameLabel setContentCompressionResistancePriority:40
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_nameLabel];

    _metaLabel = [NSTextField labelWithString:@""];
    _metaLabel.font = [NSFont systemFontOfSize:11];
    _metaLabel.textColor = t.mut;
    _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _metaLabel.maximumNumberOfLines = 1;
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_metaLabel setContentCompressionResistancePriority:40
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_metaLabel];
    [self refreshLanguageFromAlbum:album];

    _hitButton = [NSButton buttonWithTitle:@"" target:target action:openAction];
    _hitButton.bordered = NO;
    _hitButton.identifier = _albumKey;
    _hitButton.toolTip = album.name ?: @"";
    _hitButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_hitButton];

    _playBadge = [[NSButton alloc] initWithFrame:NSZeroRect];
    _playBadge.bordered = NO;
    _playBadge.imagePosition = NSImageOnly;
    _playBadge.imageScaling = NSImageScaleProportionallyDown;
    _playBadge.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:RLPTr(@"播放整张")];
    _playBadge.contentTintColor = NSColor.whiteColor;
    _playBadge.toolTip = RLPTr(@"播放整张");
    _playBadge.target = target;
    _playBadge.action = playAction;
    _playBadge.identifier = _albumKey;
    _playBadge.wantsLayer = YES;
    _playBadge.layer.cornerRadius = 15;
    _playBadge.layer.backgroundColor = t.accent.CGColor;
    _playBadge.hidden = YES;
    _playBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [_playBadge setContentCompressionResistancePriority:40
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_playBadge];

    [NSLayoutConstraint activateConstraints:@[
        [_coverBox.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [_coverBox.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
        [_coverBox.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [_coverBox.heightAnchor constraintEqualToAnchor:_coverBox.widthAnchor],

        [_coverView.leadingAnchor constraintEqualToAnchor:_coverBox.leadingAnchor],
        [_coverView.trailingAnchor constraintEqualToAnchor:_coverBox.trailingAnchor],
        [_coverView.topAnchor constraintEqualToAnchor:_coverBox.topAnchor],
        [_coverView.bottomAnchor constraintEqualToAnchor:_coverBox.bottomAnchor],

        [_placeholderLabel.centerXAnchor constraintEqualToAnchor:_coverBox.centerXAnchor],
        [_placeholderLabel.centerYAnchor constraintEqualToAnchor:_coverBox.centerYAnchor],
        [_placeholderLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_coverBox.leadingAnchor constant:6],
        [_placeholderLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_coverBox.trailingAnchor constant:-6],

        [_playBadge.trailingAnchor constraintEqualToAnchor:_coverBox.trailingAnchor constant:-7],
        [_playBadge.bottomAnchor constraintEqualToAnchor:_coverBox.bottomAnchor constant:-7],
        [_playBadge.widthAnchor constraintEqualToConstant:30],
        [_playBadge.heightAnchor constraintEqualToConstant:30],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_coverBox.leadingAnchor],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:_coverBox.trailingAnchor],
        [_nameLabel.topAnchor constraintEqualToAnchor:_coverBox.bottomAnchor constant:8],

        [_metaLabel.leadingAnchor constraintEqualToAnchor:_coverBox.leadingAnchor],
        [_metaLabel.trailingAnchor constraintEqualToAnchor:_coverBox.trailingAnchor],
        [_metaLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
        [_metaLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],

        [_hitButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_hitButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_hitButton.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_hitButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    return self;
}

- (void)refreshLanguageFromAlbum:(RLPAlbum *)album {
    _nameLabel.stringValue = album.name.length ? album.name : RLPTr(@"未知专辑");
    NSMutableArray<NSString *> *sub = [NSMutableArray array];
    if (album.artist.length) [sub addObject:album.artist];
    if (album.year > 0) [sub addObject:[NSString stringWithFormat:@"%ld", (long)album.year]];
    if (album.sampleRate > 0) {
        NSString *sr = (album.sampleRate % 1000 == 0)
            ? [NSString stringWithFormat:@"%ldk", (long)(album.sampleRate / 1000)]
            : [NSString stringWithFormat:@"%.1fk", album.sampleRate / 1000.0];
        [sub addObject:(album.bits > 0 ? [NSString stringWithFormat:@"%@/%ld", sr, (long)album.bits] : sr)];
    }
    _metaLabel.stringValue = sub.count ? [sub componentsJoinedByString:@" · "] : RLPTr(@"未知艺术家");
    _playBadge.toolTip = RLPTr(@"播放整张");
}

- (void)updateCover:(NSImage * _Nullable)image {
    _coverView.image = image;
    _placeholderLabel.hidden = (image != nil);
}

- (void)ensureTrackingArea {
    if (NSWidth(self.bounds) <= 0.0 || NSHeight(self.bounds) <= 0.0) return;
    if (!_hoverArea || !NSEqualRects(_hoverArea.rect, self.bounds)) {
        [self updateTrackingAreas];
    }
}

- (void)layout {
    [super layout];
    [self ensureTrackingArea];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self ensureTrackingArea];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) { [self removeTrackingArea:_hoverArea]; _hoverArea = nil; }
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveInKeyWindow |
                                                       NSTrackingInVisibleRect)
                                                owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    _playBadge.hidden = NO;
    [self refreshHoverStyle];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    _playBadge.hidden = YES;
    [self refreshHoverStyle];
}

- (void)refreshHoverStyle {
    RLPTheme *t = [RLPTheme current];
    self.layer.borderWidth = _hovered ? 1.5 : 1.0;
    self.layer.borderColor = (_hovered ? t.accent : t.line).CGColor;
    self.layer.backgroundColor = (_hovered ? t.bg3 : t.bg2).CGColor;
    _coverBox.layer.borderWidth = _hovered ? 1.5 : 1.0;
    _coverBox.layer.borderColor = (_hovered ? t.accent : t.line).CGColor;
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    _coverBox.layer.backgroundColor = t.cvBg.CGColor;
    _playBadge.layer.backgroundColor = t.accent.CGColor;
    _nameLabel.textColor = t.text;
    _metaLabel.textColor = t.mut;
    _placeholderLabel.textColor = t.mut;
    [self refreshHoverStyle];
}

@end

#pragma mark - 交互按钮、可点卡片与下拉控件

@class RLPRoomInteractiveCardView;

@interface RLPRoomSilentButtonCell : NSButtonCell
@end

@implementation RLPRoomSilentButtonCell
- (void)drawBezelWithFrame:(NSRect)frame inView:(NSView *)controlView {
    (void)frame; (void)controlView;
}
- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    (void)cellFrame; (void)controlView;
}
@end

@interface RLPRoomActionButton : NSButton {
    NSTrackingArea *_hoverArea;
    BOOL _hovered;
    BOOL _pressed;
    NSImageView *_iconView;
    NSTextField *_labelField;
    NSTextField *_chevronLabel;
    NSLayoutConstraint *_labelLeadingNoIcon;
    NSLayoutConstraint *_labelLeadingWithIcon;
    NSLayoutConstraint *_labelTrailingNoChevron;
    NSLayoutConstraint *_labelTrailingWithChevron;
    NSLayoutConstraint *_minHeightConstraint;
}
@property (nonatomic, assign) BOOL showsChevron;
@property (nonatomic, assign) BOOL iconOnly;
@property (nonatomic, assign) BOOL primaryAccent;
@property (nonatomic, assign) CGFloat minHeight;
@property (nonatomic, strong, readonly) NSTextField *chevronLabel;
+ (instancetype)actionButtonWithTitle:(NSString *)title
                               target:(nullable id)target
                               action:(nullable SEL)action
                         showsChevron:(BOOL)showsChevron
                        primaryAccent:(BOOL)primaryAccent
                            minHeight:(CGFloat)minHeight;
+ (instancetype)iconButtonWithSymbol:(NSString *)symbol
                                desc:(NSString *)desc
                              target:(nullable id)target
                              action:(nullable SEL)action
                                size:(CGFloat)size;
- (void)applyTheme;
- (void)setChevronIdentifier:(NSString *)ident;
@end

@implementation RLPRoomActionButton

+ (Class)cellClass {
    return [RLPRoomSilentButtonCell class];
}

+ (instancetype)actionButtonWithTitle:(NSString *)title
                               target:(nullable id)target
                               action:(nullable SEL)action
                         showsChevron:(BOOL)showsChevron
                        primaryAccent:(BOOL)primaryAccent
                            minHeight:(CGFloat)minHeight {
    RLPRoomActionButton *b = [[self alloc] initWithFrame:NSZeroRect];
    b.showsChevron = showsChevron;
    b.primaryAccent = primaryAccent;
    b.minHeight = MAX(28.0, minHeight);
    b.target = target;
    b.action = action;
    b.title = title ?: @"";
    [b rebuildInternalLayout];
    [b applyTheme];
    return b;
}

+ (instancetype)iconButtonWithSymbol:(NSString *)symbol
                                desc:(NSString *)desc
                              target:(nullable id)target
                              action:(nullable SEL)action
                                size:(CGFloat)size {
    RLPRoomActionButton *b = [[self alloc] initWithFrame:NSZeroRect];
    b.iconOnly = YES;
    b.showsChevron = NO;
    b.minHeight = MAX(28.0, size);
    b.target = target;
    b.action = action;
    b.toolTip = desc ?: @"";
    b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:desc];
    [b rebuildInternalLayout];
    [b applyTheme];
    return b;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    _minHeight = 28.0;
    self.bordered = NO;
    self.wantsLayer = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    self.focusRingType = NSFocusRingTypeNone;

    _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _iconView.imageScaling = NSImageScaleProportionallyDown;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.hidden = YES;
    [self addSubview:_iconView];

    _labelField = [NSTextField labelWithString:@""];
    _labelField.font = self.font;
    _labelField.lineBreakMode = NSLineBreakByTruncatingTail;
    _labelField.maximumNumberOfLines = 1;
    _labelField.translatesAutoresizingMaskIntoConstraints = NO;
    [_labelField setContentCompressionResistancePriority:40
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_labelField];

    _chevronLabel = [NSTextField labelWithString:@"›"];
    _chevronLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    _chevronLabel.alignment = NSTextAlignmentCenter;
    _chevronLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _chevronLabel.hidden = YES;
    [_chevronLabel setContentHuggingPriority:NSLayoutPriorityRequired
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_chevronLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_chevronLabel];

    _minHeightConstraint = [self.heightAnchor constraintGreaterThanOrEqualToConstant:_minHeight];
    _minHeightConstraint.active = YES;
    return self;
}

- (void)rebuildInternalLayout {
    if (_minHeightConstraint) _minHeightConstraint.constant = MAX(28.0, _minHeight);
    [NSLayoutConstraint deactivateConstraints:self.constraints];
    if (_minHeightConstraint) _minHeightConstraint.active = YES;

    if (_iconOnly) {
        _labelField.hidden = YES;
        _chevronLabel.hidden = YES;
        _iconView.hidden = NO;
        const CGFloat sz = MAX(28.0, _minHeight);
        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintGreaterThanOrEqualToConstant:sz],
            [_iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:14],
            [_iconView.heightAnchor constraintEqualToConstant:14],
        ]];
        [self invalidateIntrinsicContentSize];
        return;
    }

    _labelField.hidden = NO;
    _chevronLabel.hidden = !_showsChevron;
    _iconView.hidden = (self.image == nil);

    _labelLeadingNoIcon = [_labelField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12];
    _labelLeadingWithIcon = [_labelField.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:6];
    _labelTrailingNoChevron = [_labelField.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-12];
    _labelTrailingWithChevron = [_labelField.trailingAnchor constraintLessThanOrEqualToAnchor:_chevronLabel.leadingAnchor constant:-5];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:11],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:13],
        [_iconView.heightAnchor constraintEqualToConstant:13],

        [_labelField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

        [_chevronLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [_chevronLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-0.5],
        [_chevronLabel.widthAnchor constraintEqualToConstant:12],
    ]];
    _labelLeadingNoIcon.active = (self.image == nil);
    _labelLeadingWithIcon.active = (self.image != nil);
    _labelTrailingNoChevron.active = !_showsChevron;
    _labelTrailingWithChevron.active = _showsChevron;
    [self invalidateIntrinsicContentSize];
}

- (void)setChevronIdentifier:(NSString *)ident {
    _chevronLabel.identifier = ident;
}

- (void)setShowsChevron:(BOOL)showsChevron {
    _showsChevron = showsChevron;
    if (!_iconOnly && _labelTrailingNoChevron && _labelTrailingWithChevron) {
        _chevronLabel.hidden = !showsChevron;
        _labelTrailingNoChevron.active = !showsChevron;
        _labelTrailingWithChevron.active = showsChevron;
        [self invalidateIntrinsicContentSize];
    }
}

- (void)setMinHeight:(CGFloat)minHeight {
    _minHeight = MAX(28.0, minHeight);
    if (_minHeightConstraint) _minHeightConstraint.constant = _minHeight;
    [self invalidateIntrinsicContentSize];
}

- (void)setTitle:(NSString *)title {
    [super setTitle:title ?: @""];
    _labelField.stringValue = title ?: @"";
    [self invalidateIntrinsicContentSize];
}

- (void)setFont:(NSFont *)font {
    [super setFont:font];
    _labelField.font = font;
    [self invalidateIntrinsicContentSize];
}

- (void)setImage:(NSImage *)image {
    [super setImage:image];
    _iconView.image = image;
    if (!_iconOnly) {
        const BOOL hasImg = (image != nil);
        _iconView.hidden = !hasImg;
        if (_labelLeadingNoIcon && _labelLeadingWithIcon) {
            _labelLeadingNoIcon.active = !hasImg;
            _labelLeadingWithIcon.active = hasImg;
        }
    }
    [self invalidateIntrinsicContentSize];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self applyTheme];
    [self.window invalidateCursorRectsForView:self];
}

- (NSSize)intrinsicContentSize {
    const CGFloat h = MAX(28.0, _minHeight);
    if (_iconOnly) return NSMakeSize(h, h);
    const NSSize lblSz = _labelField.intrinsicContentSize;
    CGFloat labelW = (lblSz.width != NSViewNoIntrinsicMetric) ? ceil(lblSz.width) : 0.0;
    CGFloat labelH = (lblSz.height != NSViewNoIntrinsicMetric) ? ceil(lblSz.height) : 16.0;
    if (labelW <= 0.0 && _labelField.stringValue.length) {
        NSFont *f = _labelField.font ?: [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
        NSSize tSz = [_labelField.stringValue sizeWithAttributes:@{NSFontAttributeName: f}];
        labelW = ceil(tSz.width) + 4.0;
        labelH = MAX(labelH, ceil(tSz.height));
    }
    const CGFloat leadingPad = self.image ? 30.0 : 12.0;
    const CGFloat trailingPad = _showsChevron ? 25.0 : 12.0;
    const CGFloat w = leadingPad + labelW + trailingPad + 2.0;
    return NSMakeSize(MAX(48.0, w), MAX(h, labelH + 12.0));
}

- (NSView *)hitTest:(NSPoint)point {
    if (self.hidden || self.alphaValue <= 0.01 || !self.superview) return nil;
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return NSPointInRect(local, self.bounds) ? self : nil;
}

- (void)ensureTrackingArea {
    if (NSWidth(self.bounds) <= 0.0 || NSHeight(self.bounds) <= 0.0) return;
    if (!_hoverArea || !NSEqualRects(_hoverArea.rect, self.bounds)) {
        [self updateTrackingAreas];
    }
}

- (void)layout {
    [super layout];
    [self ensureTrackingArea];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self ensureTrackingArea];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) { [self removeTrackingArea:_hoverArea]; _hoverArea = nil; }
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveInKeyWindow |
                                                       NSTrackingInVisibleRect)
                                                owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.enabled) {
        [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    [self applyTheme];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    _pressed = NO;
    [self applyTheme];
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) { [super mouseDown:event]; return; }
    _pressed = YES;
    [self applyTheme];
    [super mouseDown:event];
    _pressed = NO;
    if (self.window) {
        NSPoint loc = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        _hovered = NSPointInRect(loc, self.bounds);
    } else {
        _hovered = NO;
    }
    [self applyTheme];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.layer.cornerRadius = t.rSm;
    self.alphaValue = self.enabled ? 1.0 : 0.52;
    const BOOL hot = _hovered && self.enabled;
    const BOOL active = _pressed && self.enabled;
    self.layer.borderWidth = active ? 1.5 : 1.0;

    if (_primaryAccent) {
        self.layer.borderWidth = (hot || active) ? 1.5 : 1.0;
        if (active) {
            self.layer.backgroundColor = [t.accent colorWithAlphaComponent:0.36].CGColor;
            self.layer.borderColor = t.accent.CGColor;
        } else if (hot) {
            self.layer.backgroundColor = [t.accent colorWithAlphaComponent:0.26].CGColor;
            self.layer.borderColor = t.accent.CGColor;
        } else {
            self.layer.backgroundColor = t.accentWeak.CGColor;
            self.layer.borderColor = t.accent.CGColor;
        }
        _labelField.textColor = t.accentText;
        _iconView.contentTintColor = t.accentText;
        _chevronLabel.textColor = t.accentText;
        self.contentTintColor = t.accentText;
    } else {
        if (active) {
            self.layer.backgroundColor = t.hov2.CGColor;
            self.layer.borderColor = t.accent.CGColor;
        } else if (hot) {
            self.layer.backgroundColor = t.hov.CGColor;
            self.layer.borderColor = t.accent.CGColor;
        } else {
            self.layer.backgroundColor = t.bg3.CGColor;
            self.layer.borderColor = t.line2.CGColor;
        }
        _labelField.textColor = t.text;
        _iconView.contentTintColor = (hot || active) ? t.accentText : t.text2;
        _chevronLabel.textColor = (hot || active) ? t.accentText : t.text2;
        self.contentTintColor = t.text;
    }
}

@end

@interface RLPRoomPopUpButtonCell : NSPopUpButtonCell
@end

@implementation RLPRoomPopUpButtonCell

- (NSRect)titleRectForBounds:(NSRect)bounds {
    NSRect r = bounds;
    r.origin.x += 10.0;
    r.size.width = MAX(0.0, r.size.width - 36.0);
    NSFont *f = self.font ?: [NSFont systemFontOfSize:13];
    const CGFloat lineH = ceil([@"Ag" sizeWithAttributes:@{NSFontAttributeName: f}].height);
    if (lineH > 0.0 && lineH < r.size.height) {
        r.origin.y += floor((r.size.height - lineH) * 0.5);
        r.size.height = lineH;
    }
    return r;
}

- (void)drawBezelWithFrame:(NSRect)frame inView:(NSView *)controlView {
    (void)frame; (void)controlView;
}

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    (void)controlView;
    RLPTheme *t = [RLPTheme current];
    NSString *txt = self.selectedItem.title.length ? self.selectedItem.title : (self.title ?: @"");
    if (!txt.length) return;
    NSRect r = [self titleRectForBounds:cellFrame];
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    ps.alignment = NSTextAlignmentLeft;
    NSFont *f = self.font ?: t.body;
    NSDictionary *attrs = @{
        NSFontAttributeName: f,
        NSForegroundColorAttributeName: self.enabled ? t.text : t.mut,
        NSParagraphStyleAttributeName: ps,
    };
    [txt drawInRect:r withAttributes:attrs];
}

@end

@interface RLPRoomPopUpButton : NSPopUpButton {
    NSTrackingArea *_hoverArea;
    BOOL _hovered;
    BOOL _pressed;
    NSImageView *_chevronView;
}
@property (nonatomic, strong, readonly) NSImageView *chevronView;
- (void)applyTheme;
@end

@implementation RLPRoomPopUpButton

+ (Class)cellClass {
    return [RLPRoomPopUpButtonCell class];
}

- (instancetype)initWithFrame:(NSRect)buttonFrame pullsDown:(BOOL)flag {
    self = [super initWithFrame:buttonFrame pullsDown:flag];
    if (!self) return nil;
    self.bordered = NO;
    self.wantsLayer = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.focusRingType = NSFocusRingTypeNone;
    NSPopUpButtonCell *c = (NSPopUpButtonCell *)self.cell;
    c.arrowPosition = NSPopUpNoArrow;
    c.lineBreakMode = NSLineBreakByTruncatingTail;

    _chevronView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _chevronView.identifier = @"room.devicePopup.chevron";
    _chevronView.image = [NSImage imageWithSystemSymbolName:@"chevron.up.chevron.down"
                                accessibilityDescription:RLPTr(@"选择设备")];
    _chevronView.imageScaling = NSImageScaleProportionallyDown;
    _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_chevronView];

    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:30.0],
        [_chevronView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-9.0],
        [_chevronView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_chevronView.widthAnchor constraintEqualToConstant:12.0],
        [_chevronView.heightAnchor constraintEqualToConstant:12.0],
    ]];
    [self applyTheme];
    return self;
}

- (NSSize)intrinsicContentSize {
    NSSize sz = [super intrinsicContentSize];
    return NSMakeSize(sz.width, MAX(30.0, sz.height));
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self applyTheme];
    [self.window invalidateCursorRectsForView:self];
}

- (NSView *)hitTest:(NSPoint)point {
    if (self.hidden || self.alphaValue <= 0.01 || !self.superview) return nil;
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return NSPointInRect(local, self.bounds) ? self : nil;
}

- (void)ensureTrackingArea {
    if (NSWidth(self.bounds) <= 0.0 || NSHeight(self.bounds) <= 0.0) return;
    if (!_hoverArea || !NSEqualRects(_hoverArea.rect, self.bounds)) {
        [self updateTrackingAreas];
    }
}

- (void)layout {
    [super layout];
    [self ensureTrackingArea];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self ensureTrackingArea];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) { [self removeTrackingArea:_hoverArea]; _hoverArea = nil; }
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveInKeyWindow |
                                                       NSTrackingInVisibleRect)
                                                owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.enabled) {
        [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    [self applyTheme];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    _pressed = NO;
    [self applyTheme];
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) { [super mouseDown:event]; return; }
    _pressed = YES;
    [self applyTheme];
    [super mouseDown:event];
    _pressed = NO;
    if (self.window) {
        NSPoint loc = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        _hovered = NSPointInRect(loc, self.bounds);
    } else {
        _hovered = NO;
    }
    [self applyTheme];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    self.alphaValue = self.enabled ? 1.0 : 0.52;
    const BOOL hot = _hovered && self.enabled;
    const BOOL active = _pressed && self.enabled;
    self.layer.cornerRadius = t.rSm;
    self.layer.borderWidth = active ? 1.5 : 1.0;
    if (active) {
        self.layer.backgroundColor = t.hov2.CGColor;
        self.layer.borderColor = t.accent.CGColor;
    } else if (hot) {
        self.layer.backgroundColor = t.hov.CGColor;
        self.layer.borderColor = t.accent.CGColor;
    } else {
        self.layer.backgroundColor = t.bg3.CGColor;
        self.layer.borderColor = t.line2.CGColor;
    }
    _chevronView.contentTintColor = (hot || active) ? t.accentText : t.text2;
    [self setNeedsDisplay:YES];
}

@end

@interface RLPRoomCardPillButton : NSButton {
    NSTrackingArea *_hoverArea;
    BOOL _hovered;
    BOOL _pressed;
    BOOL _cardHovered;
    BOOL _cardPressed;
}
@property (nonatomic, weak, nullable) RLPRoomInteractiveCardView *parentCard;
@property (nonatomic, weak, nullable) NSTextField *valueLabel;
@property (nonatomic, weak, nullable) NSTextField *chevronLabel;
- (void)setCardHovered:(BOOL)hovered cardPressed:(BOOL)pressed;
- (void)applyTheme;
@end

@interface RLPRoomInteractiveCardView : NSView {
    NSTrackingArea *_hoverArea;
    BOOL _hovered;
    BOOL _pressed;
    BOOL _externalHover;
    BOOL _externalPressed;
}
@property (nonatomic, weak, nullable) RLPRoomCardPillButton *pillButton;
@property (nonatomic, weak, nullable) id target;
@property (nonatomic, assign) SEL action;
- (void)setExternalHover:(BOOL)hover externalPressed:(BOOL)pressed;
- (void)applyTheme;
@end

@implementation RLPRoomCardPillButton

+ (Class)cellClass {
    return [RLPRoomSilentButtonCell class];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.title = @"";
    self.bordered = NO;
    self.wantsLayer = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.focusRingType = NSFocusRingTypeNone;
    [self.heightAnchor constraintGreaterThanOrEqualToConstant:30.0].active = YES;
    [self applyTheme];
    return self;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, 30.0);
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self applyTheme];
    [self.window invalidateCursorRectsForView:self];
    [self.parentCard.window invalidateCursorRectsForView:self.parentCard];
}

- (NSView *)hitTest:(NSPoint)point {
    if (self.hidden || self.alphaValue <= 0.01 || !self.superview) return nil;
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return NSPointInRect(local, self.bounds) ? self : nil;
}

- (void)ensureTrackingArea {
    if (NSWidth(self.bounds) <= 0.0 || NSHeight(self.bounds) <= 0.0) return;
    if (!_hoverArea || !NSEqualRects(_hoverArea.rect, self.bounds)) {
        [self updateTrackingAreas];
    }
}

- (void)layout {
    [super layout];
    [self ensureTrackingArea];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self ensureTrackingArea];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) { [self removeTrackingArea:_hoverArea]; _hoverArea = nil; }
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveInKeyWindow |
                                                       NSTrackingInVisibleRect)
                                                owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.enabled) {
        [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    [self.parentCard setExternalHover:YES externalPressed:_pressed];
    [self applyTheme];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    _pressed = NO;
    [self.parentCard setExternalHover:NO externalPressed:NO];
    [self applyTheme];
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) { [super mouseDown:event]; return; }
    _pressed = YES;
    [self.parentCard setExternalHover:_hovered externalPressed:YES];
    [self applyTheme];
    [super mouseDown:event];
    _pressed = NO;
    if (self.window) {
        NSPoint loc = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        _hovered = NSPointInRect(loc, self.bounds);
    } else {
        _hovered = NO;
    }
    [self.parentCard setExternalHover:_hovered externalPressed:NO];
    [self applyTheme];
}

- (void)setCardHovered:(BOOL)hovered cardPressed:(BOOL)pressed {
    _cardHovered = hovered;
    _cardPressed = pressed;
    [self applyTheme];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    const BOOL enabled = self.enabled;
    const BOOL active = enabled && (_pressed || _cardPressed);
    const BOOL hot = enabled && (_hovered || _cardHovered);
    self.layer.cornerRadius = t.rSm;
    self.layer.borderWidth = active ? 1.5 : 1.0;
    if (active) {
        self.layer.backgroundColor = t.hov2.CGColor;
        self.layer.borderColor = t.accent.CGColor;
    } else if (hot) {
        self.layer.backgroundColor = t.hov.CGColor;
        self.layer.borderColor = t.accent.CGColor;
    } else {
        self.layer.backgroundColor = t.bg3.CGColor;
        self.layer.borderColor = t.line2.CGColor;
    }
    if (self.valueLabel) self.valueLabel.textColor = t.text;
    if (self.chevronLabel) self.chevronLabel.textColor = (hot || active) ? t.accentText : t.text2;
}

@end

@implementation RLPRoomInteractiveCardView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self applyTheme];
    return self;
}

- (void)ensureTrackingArea {
    if (NSWidth(self.bounds) <= 0.0 || NSHeight(self.bounds) <= 0.0) return;
    if (!_hoverArea || !NSEqualRects(_hoverArea.rect, self.bounds)) {
        [self updateTrackingAreas];
    }
}

- (void)layout {
    [super layout];
    [self ensureTrackingArea];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self ensureTrackingArea];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) { [self removeTrackingArea:_hoverArea]; _hoverArea = nil; }
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveInKeyWindow |
                                                       NSTrackingInVisibleRect)
                                                owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    if (!self.pillButton || self.pillButton.enabled) {
        [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    [self applyTheme];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    _pressed = NO;
    [self applyTheme];
}

- (void)mouseDown:(NSEvent *)event {
    // 若点击命中内部下拉或独立按钮（非静态 NSTextField 标签），则绝不误触整卡点击。
    NSPoint inSuper = self.superview
        ? [self.superview convertPoint:event.locationInWindow fromView:nil]
        : [self convertPoint:event.locationInWindow fromView:nil];
    NSView *hit = [super hitTest:inSuper];
    for (NSView *v = hit; v && v != self; v = v.superview) {
        if ([v isKindOfClass:[NSPopUpButton class]] || [v isKindOfClass:[NSButton class]]) {
            [super mouseDown:event];
            return;
        }
    }
    if (self.pillButton && !self.pillButton.enabled) return;
    _pressed = YES;
    [self applyTheme];
    BOOL inside = YES;
    if (self.window) {
        while (YES) {
            NSEvent *next = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
            if (!next) break;
            NSPoint p = [self convertPoint:next.locationInWindow fromView:nil];
            inside = NSPointInRect(p, self.bounds);
            if (_pressed != inside) {
                _pressed = inside;
                [self applyTheme];
            }
            if (next.type == NSEventTypeLeftMouseUp) break;
        }
    }
    _pressed = NO;
    if (self.window) {
        NSPoint loc = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        _hovered = NSPointInRect(loc, self.bounds);
    }
    [self applyTheme];
    if (inside && self.action && self.target) {
        [NSApp sendAction:self.action to:self.target from:(self.pillButton ?: (id)self)];
    }
}

- (void)setExternalHover:(BOOL)hover externalPressed:(BOOL)pressed {
    _externalHover = hover;
    _externalPressed = pressed;
    [self applyTheme];
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    const BOOL active = _pressed || _externalPressed;
    const BOOL hot = _hovered || _externalHover;
    self.layer.cornerRadius = t.rMd;
    if (active) {
        self.layer.backgroundColor = t.hov2.CGColor;
        self.layer.borderColor = t.accent.CGColor;
        self.layer.borderWidth = 1.5;
    } else if (hot) {
        self.layer.backgroundColor = t.hov.CGColor;
        self.layer.borderColor = t.accent.CGColor;
        self.layer.borderWidth = 1.5;
    } else {
        self.layer.backgroundColor = t.bg2.CGColor;
        self.layer.borderColor = t.line2.CGColor;
        self.layer.borderWidth = 1.0;
    }
    [self.pillButton setCardHovered:hot cardPressed:active];
}

@end

@interface RLPRoomQueueHitButton : NSButton {
    NSTrackingArea *_hoverArea;
    BOOL _hovered;
    BOOL _pressed;
}
@property (nonatomic, weak, nullable) NSView *rowSurface;
@property (nonatomic, assign) BOOL isCurrentRow;
@end

@implementation RLPRoomQueueHitButton

- (void)ensureTrackingArea {
    if (NSWidth(self.bounds) <= 0.0 || NSHeight(self.bounds) <= 0.0) return;
    if (!_hoverArea || !NSEqualRects(_hoverArea.rect, self.bounds)) {
        [self updateTrackingAreas];
    }
}

- (void)layout {
    [super layout];
    [self ensureTrackingArea];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self ensureTrackingArea];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) { [self removeTrackingArea:_hoverArea]; _hoverArea = nil; }
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveInKeyWindow |
                                                       NSTrackingInVisibleRect)
                                                owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

- (void)refreshRowSurface {
    if (!self.rowSurface) return;
    RLPTheme *t = [RLPTheme current];
    self.rowSurface.layer.borderWidth = (_hovered || _pressed) ? 1.5 : 1.0;
    if (_pressed) {
        self.rowSurface.layer.backgroundColor = t.hov2.CGColor;
        self.rowSurface.layer.borderColor = t.accent.CGColor;
    } else if (_hovered) {
        self.rowSurface.layer.backgroundColor = (self.isCurrentRow ? t.accentWeak : t.hov).CGColor;
        self.rowSurface.layer.borderColor = t.accent.CGColor;
    } else {
        self.rowSurface.layer.backgroundColor = (self.isCurrentRow ? t.accentWeak : t.bg3).CGColor;
        self.rowSurface.layer.borderColor = (self.isCurrentRow ? t.accent : t.line).CGColor;
    }
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _hovered = YES;
    [self refreshRowSurface];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _hovered = NO;
    _pressed = NO;
    [self refreshRowSurface];
}

- (void)mouseDown:(NSEvent *)event {
    _pressed = YES;
    [self refreshRowSurface];
    [super mouseDown:event];
    _pressed = NO;
    [self refreshRowSurface];
}

@end

#pragma mark - 聆听室主控制器

@interface RLPQuickStartViewController ()
@property (nonatomic, strong) NSStackView *stack;
@property (nonatomic, strong) NSView *headerRow;
@property (nonatomic, strong) NSTextField *headerTitle;
@property (nonatomic, strong) NSTextField *headerSubtitle;
@property (nonatomic, strong) NSButton *foldersButton;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *headerLayoutConstraints;
@property (nonatomic, assign) BOOL headerLayoutInitialized;
@property (nonatomic, assign) BOOL currentHeaderStacked;

// 主题追踪容器
@property (nonatomic, strong) NSMutableArray<NSView *> *cardSurfaces;
@property (nonatomic, strong) NSMutableArray<RLPRoomInteractiveCardView *> *interactiveCards;
@property (nonatomic, strong) NSMutableArray<RLPRoomActionButton *> *actionButtons;
@property (nonatomic, strong) NSMutableArray<NSView *> *subSurfaces;
@property (nonatomic, strong) NSMutableArray<NSView *> *iconBadges;
@property (nonatomic, strong) NSMutableArray<NSView *> *dividerLines;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *dynamicLabels;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *queueDynamicLabels;
@property (nonatomic, strong) NSMutableArray<NSView *> *queueRowSurfaces;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *queueRowCurrentFlags;
@property (nonatomic, strong) NSMutableArray<RLPRoomAlbumCardView *> *albumCardViews;

// ① 四张快速设置卡 + 响应式布局
@property (nonatomic, strong) NSView *cardsContainer;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *cardsLayoutConstraints;
@property (nonatomic, assign) NSInteger currentCardColumns;
@property (nonatomic, strong) NSView *deviceCard;
@property (nonatomic, strong) NSView *outputCard;
@property (nonatomic, strong) NSView *playCard;
@property (nonatomic, strong) NSView *styleCard;
@property (nonatomic, strong) NSPopUpButton *devicePopup;
@property (nonatomic, strong) NSTextField *deviceSub;
@property (nonatomic, strong) NSTextField *outputValue;
@property (nonatomic, strong) NSTextField *outputSub;
@property (nonatomic, strong) NSTextField *playValue;
@property (nonatomic, strong) NSTextField *playSub;
@property (nonatomic, strong) NSTextField *styleValue;
@property (nonatomic, strong) NSTextField *styleSub;
@property (nonatomic, strong) NSTextField *deviceCaption;
@property (nonatomic, strong) NSTextField *outputCaption;
@property (nonatomic, strong) NSTextField *playCaption;
@property (nonatomic, strong) NSTextField *styleCaption;
@property (nonatomic, strong) NSTextField *outputChevron;
@property (nonatomic, strong) NSTextField *playChevron;
@property (nonatomic, strong) NSTextField *styleChevron;
@property (nonatomic, strong) NSButton *devRefreshButton;
@property (nonatomic, strong) NSButton *outCardButton;
@property (nonatomic, strong) NSButton *playCardButton;
@property (nonatomic, strong) NSButton *styleCardButton;

// ①b 硬件能力与状态条卡
@property (nonatomic, strong) NSView *capsCard;
@property (nonatomic, strong) NSTextField *capsTitleLabel;
@property (nonatomic, strong) NSTextField *capsInfoLabel;
@property (nonatomic, strong) NSStackView *capsPillsStack;
@property (nonatomic, strong) NSView *capsPcmPill;
@property (nonatomic, strong) NSTextField *capsPcmBadge;
@property (nonatomic, strong) NSView *capsDsdPill;
@property (nonatomic, strong) NSTextField *capsDsdBadge;
@property (nonatomic, strong) NSView *capsDivider;
@property (nonatomic, strong) NSTextField *presetNotes;
@property (nonatomic, assign) BOOL hasCustomPresetNote;
@property (nonatomic, assign) BOOL presetCapsKnown;
@property (nonatomic, assign) BOOL presetPcmReady;
@property (nonatomic, assign) BOOL presetDsdReady;
@property (nonatomic, copy, nullable) NSString *presetCapsDevice;

// ② 正在播放 + 队列预览响应式容器
@property (nonatomic, strong) NSView *npQueueRow;
@property (nonatomic, strong) NSView *npCard;
@property (nonatomic, strong) NSView *queueCard;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *npQueueConstraints;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *npCardConstraints;
@property (nonatomic, assign) BOOL npQueueLayoutInitialized;
@property (nonatomic, assign) BOOL currentNpStacked;
@property (nonatomic, assign) BOOL currentNpWideRail;
@property (nonatomic, assign) BOOL currentNpQueueCompact;
@property (nonatomic, assign) BOOL npCardLayoutInitialized;
@property (nonatomic, assign) BOOL currentNpCompact;
@property (nonatomic, strong) RLPCoverImageView *npCover;
@property (nonatomic, strong) NSTextField *npPlaceholder;
@property (nonatomic, strong) NSView *npStatePill;
@property (nonatomic, strong) NSTextField *npState;
@property (nonatomic, strong) NSView *npFormatPill;
@property (nonatomic, strong) NSTextField *npFormatLabel;
@property (nonatomic, strong) NSTextField *npTitle;
@property (nonatomic, strong) NSTextField *npSub;
@property (nonatomic, strong) RLPRoomProgressView *npProgressBar;
@property (nonatomic, strong) NSTextField *npTimeLabel;
@property (nonatomic, strong) NSButton *npToggle;
@property (nonatomic, strong) NSButton *npOpenButton;
@property (nonatomic, strong) NSTextField *queueCaption;
@property (nonatomic, strong) NSTextField *queueCountLabel;
@property (nonatomic, strong) NSButton *queueAllButton;
@property (nonatomic, strong) NSStackView *queueList;
@property (nonatomic, weak, nullable) NSTextField *queueEmptyLabel;

// ③ 专辑响应式网格
@property (nonatomic, strong) NSTextField *albumCaption;
@property (nonatomic, strong) NSTextField *albumCountLabel;
@property (nonatomic, strong) NSButton *openLibButton;
@property (nonatomic, strong) NSStackView *albumRow;
@property (nonatomic, assign) NSInteger currentAlbumColumns;
@property (nonatomic, copy) NSArray<RLPAlbum *> *albumsData;
@property (nonatomic, weak, nullable) NSView *albumEmptyCard;
@property (nonatomic, weak, nullable) NSView *albumEmptyIconBadge;
@property (nonatomic, weak, nullable) NSTextField *albumEmptyLabel;
@property (nonatomic, weak, nullable) NSTextField *albumEmptyHintLabel;
@property (nonatomic, weak, nullable) NSButton *albumEmptyButton;

// ④ 音乐库 + 扩展卡片区
@property (nonatomic, strong) NSView *libraryRow;
@property (nonatomic, strong) NSView *libraryCard;
@property (nonatomic, strong) NSView *moreCard;
@property (nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *libraryLayoutConstraints;
@property (nonatomic, assign) BOOL libraryLayoutInitialized;
@property (nonatomic, assign) BOOL currentLibraryStacked;
@property (nonatomic, assign) BOOL currentLibraryWideRail;
@property (nonatomic, strong) NSTextField *libTitleLabel;
@property (nonatomic, strong) NSView *libFormatPill;
@property (nonatomic, strong) NSTextField *libFormatBadge;
@property (nonatomic, strong) NSLayoutConstraint *libTitleToPillConstraint;
@property (nonatomic, strong) NSLayoutConstraint *libTitleToEdgeConstraint;
@property (nonatomic, strong) NSTextField *libDesc;
@property (nonatomic, strong) NSTextField *libRootLabel;
@property (nonatomic, strong) NSButton *libButton;
@property (nonatomic, strong) NSTextField *moreTitleLabel;
@property (nonatomic, strong) NSTextField *moreDescLabel;
@property (nonatomic, strong) NSButton *moreButton;

// 数据缓存（全部来自后端）
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *castDevices;
@property (nonatomic, copy) NSArray<NSDictionary *> *filters;
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy, nullable) NSString *localDevice;
@property (nonatomic, copy, nullable) NSDictionary *presetCapsJSON;
@property (nonatomic, copy, nullable) NSString *presetCapsKey;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, copy, nullable) NSString *defaultDeviceName;
@property (nonatomic, copy) NSArray<NSString *> *lastRoots;
@property (nonatomic, copy, nullable) NSDictionary *lastMetaDict;
@property (nonatomic, copy, nullable) NSDictionary *lastQueueJSON;
@property (nonatomic, copy, nullable) NSDictionary *lastStatus;
@property (nonatomic, assign) NSUInteger queueSeq;
@property (nonatomic, assign) NSUInteger queueInflightSeq;
@property (nonatomic, assign) NSInteger queueCurrentIndex;
@property (nonatomic, copy) NSArray<NSString *> *queuePaths;
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *queueCues;
@property (nonatomic, assign) double npLastPos;
@property (nonatomic, assign) double npLastDur;
@property (nonatomic, copy) NSString *npBitPerfect;
@property (nonatomic, assign) BOOL npGpuUsed;
@property (nonatomic, assign) double npOutRate;
@property (nonatomic, assign) NSInteger npOutBits;
@property (nonatomic, assign) BOOL hasLoadedLibrary;
@property (nonatomic, assign) BOOL hasLoadedStatus;
@property (nonatomic, assign) BOOL hasRoots;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) BOOL pausedNow;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, copy) NSString *outputDraftBackend;
@property (nonatomic, copy) NSString *outputDraftUpnpDev;
@property (nonatomic, weak, nullable) NSPopUpButton *outputUpnpPopup;
@property (nonatomic, weak, nullable) NSButton *outputUpnpScanButton;
@property (nonatomic, weak, nullable) NSButton *outputUpnpApplyButton;
@property (nonatomic, weak, nullable) NSTextField *outputUpnpStatusLabel;
@property (nonatomic, weak, nullable) NSButton *outputHogCheck;
@property (nonatomic, copy) NSArray<NSButton *> *outputBackendButtons;
@property (nonatomic, assign) NSUInteger castDiscoverSeq;
@property (nonatomic, assign) BOOL castDiscoverInflight;
@property (nonatomic, assign) BOOL castDiscoverFailed;
@property (nonatomic, copy) NSString *castDiscoverError;
@property (nonatomic, assign) NSTimeInterval castDiscoverTimeout;
@property (nonatomic, assign) NSUInteger coverSeq;
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic, assign) NSUInteger statusEpoch;
@property (nonatomic, assign) BOOL statusInflight;
@property (nonatomic, assign) NSUInteger settingsSeq;
@property (nonatomic, assign) NSUInteger settingsWriteSeq;
@property (nonatomic, strong, nullable) NSNumber *lastHogAcquired;
@property (nonatomic, copy) NSString *lastFallbackWhy;
@property (nonatomic, assign) BOOL roomFrameUpdateGuard;
- (void)updateResponsiveLayoutForWidth:(CGFloat)availWidth;
@end

@implementation RLPQuickStartViewController

- (instancetype)init {
    self = [super initWithTitle:RLPTr(@"聆听室")];
    if (self) {
        _cardSurfaces = [NSMutableArray array];
        _interactiveCards = [NSMutableArray array];
        _actionButtons = [NSMutableArray array];
        _subSurfaces = [NSMutableArray array];
        _iconBadges = [NSMutableArray array];
        _dividerLines = [NSMutableArray array];
        _dynamicLabels = [NSMutableArray array];
        _queueDynamicLabels = [NSMutableArray array];
        _queueRowSurfaces = [NSMutableArray array];
        _queueRowCurrentFlags = [NSMutableArray array];
        _albumCardViews = [NSMutableArray array];
        _headerLayoutConstraints = [NSMutableArray array];
        _cardsLayoutConstraints = [NSMutableArray array];
        _npQueueConstraints = [NSMutableArray array];
        _npCardConstraints = [NSMutableArray array];
        _libraryLayoutConstraints = [NSMutableArray array];
        _castDevices = @[];
        _castDiscoverError = @"";
        _castDiscoverTimeout = 12.0;
        _albumsData = @[];
        _lastRoots = @[];
        _queuePaths = @[];
        _queueCues = @[];
        _queueCurrentIndex = -1;
        _npBitPerfect = @"";
        _lastFallbackWhy = @"";
        _currentCardColumns = 0;
        _currentAlbumColumns = 0;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onPlaybackActionCompleted:)
                                                     name:@"RLPPlaybackActionCompletedNotification"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onPlaybackStatusNotification:)
                                                     name:@"RLPPlaybackStatusNotification"
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onExternalQueueChanged:)
                                                     name:RLPQueueChangedNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onExternalSettingsChanged:)
                                                     name:RLPSettingsChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [_poll invalidate];
    _poll = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

static NSDictionary * _Nullable RLPRoomStatusDictionaryFromNotification(NSNotification *note) {
    NSDictionary *raw = nil;
    if ([note.object isKindOfClass:[NSDictionary class]]) {
        raw = (NSDictionary *)note.object;
    } else if ([note.object isKindOfClass:[RLPPlaybackStatus class]]) {
        RLPPlaybackStatus *ps = (RLPPlaybackStatus *)note.object;
        return @{
            @"ok": @YES,
            @"playing": @(ps.playing),
            @"paused": @(ps.paused),
            @"pos": @(ps.position),
            @"dur": @(ps.duration),
            @"current": ps.currentPath ?: @"",
            @"currentPath": ps.currentPath ?: @"",
        };
    } else {
        NSDictionary *ui = note.userInfo;
        if ([ui isKindOfClass:[NSDictionary class]]) {
            if ([ui[@"status"] isKindOfClass:[NSDictionary class]]) {
                raw = (NSDictionary *)ui[@"status"];
            } else if (ui[@"currentPath"] || ui[@"path"] || ui[@"file"] ||
                       ui[@"playing"] || ui[@"paused"] ||
                       ui[@"index"] || ui[@"queueIndex"] || ui[@"current"] || ui[@"cur"]) {
                raw = ui;
            }
        }
    }
    if (!raw) return nil;
    if (raw[@"ok"] != nil) return raw;
    NSMutableDictionary *patched = [raw mutableCopy];
    patched[@"ok"] = @YES;
    return patched;
}

static NSString *RLPRoomStatusPath(NSDictionary * _Nullable json, RLPPlaybackStatus * _Nullable st) {
    if (st.currentPath.length) return st.currentPath;
    if ([json isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in @[ @"current", @"currentPath", @"path", @"file" ]) {
            id v = json[k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return (NSString *)v;
        }
    }
    return @"";
}

static BOOL RLPRoomStatusValueChanged(id _Nullable a, id _Nullable b) {
    if (a == [NSNull null]) a = nil;
    if (b == [NSNull null]) b = nil;
    if (!a && !b) return NO;
    if (!a || !b) return YES;
    return ![a isEqual:b];
}

static BOOL RLPRoomStatusQueueHintChanged(NSDictionary * _Nullable prev, NSDictionary * _Nullable cur) {
    if (!prev || !cur) return NO;
    NSArray<NSString *> *keys = @[
        @"index", @"queueIndex", @"qIndex", @"currentIndex", @"current", @"cur",
        @"currentPath", @"path", @"file",
        @"cueStart", @"cue_start", @"cueEnd", @"cue_end",
        @"queueVersion", @"queueSeq", @"qver", @"queueCount", @"qCount"
    ];
    for (NSString *k in keys) {
        if (RLPRoomStatusValueChanged(prev[k], cur[k])) return YES;
    }
    return NO;
}

static NSInteger RLPRoomResolveQueueCurrentIndex(NSDictionary * _Nullable json, NSArray<NSString *> *paths) {
    if (![json isKindOfClass:[NSDictionary class]] || !paths.count) return -1;
    NSArray<NSString *> *keys = @[ @"current", @"cur", @"index" ];
    id raw = nil;
    for (NSString *k in keys) {
        id v = json[k];
        if (v != nil && v != [NSNull null]) {
            raw = v;
            break;
        }
    }
    if (!raw || raw == [NSNull null]) return -1;
    if ([raw isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)raw;
        if (d[@"index"] != nil && d[@"index"] != [NSNull null]) raw = d[@"index"];
        else if (d[@"path"] != nil && d[@"path"] != [NSNull null]) raw = d[@"path"];
        else if (d[@"file"] != nil && d[@"file"] != [NSNull null]) raw = d[@"file"];
        else return -1;
    }
    if ([raw isKindOfClass:[NSNumber class]]) {
        if (CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID()) return -1;
        const NSInteger idx = [raw integerValue];
        return (idx >= 0 && idx < (NSInteger)paths.count) ? idx : -1;
    }
    if ([raw isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)raw;
        if (!s.length) return -1;
        NSUInteger exact = [paths indexOfObject:s];
        if (exact != NSNotFound) return (NSInteger)exact;
        NSString *norm = RLPFavNormalizePath(s);
        if (norm.length) {
            for (NSUInteger i = 0; i < paths.count; ++i) {
                if (paths[i].length && [RLPFavNormalizePath(paths[i]) isEqualToString:norm]) {
                    return (NSInteger)i;
                }
            }
        }
        const char *utf8 = s.UTF8String;
        if (utf8 && utf8[0] >= '0' && utf8[0] <= '9') {
            char *end = NULL;
            long parsed = strtol(utf8, &end, 10);
            if (end != utf8 && *end == '\0' && parsed >= 0 && parsed < (long)paths.count) {
                return (NSInteger)parsed;
            }
        }
        return -1;
    }
    return -1;
}

- (void)onExternalSettingsChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (![RLPCoreClient shared].started) return;
    [self reloadSettings];
}

- (void)onExternalQueueChanged:(NSNotification *)note {
    if (note.object == self) return;
    if (!self.isViewLoaded || ![RLPCoreClient shared].started) return;
    [self reloadQueue];
}

- (void)onPlaybackStatusNotification:(NSNotification *)note {
    if (!self.isViewLoaded || ![RLPCoreClient shared].started) return;
    NSDictionary *st = RLPRoomStatusDictionaryFromNotification(note);
    if (st) {
        [self applyStatusJSON:st];
    } else if (!self.statusInflight) {
        [self reloadStatus];
    }
}

- (void)onPlaybackActionCompleted:(NSNotification *)note {
    (void)note;
    if (!self.isViewLoaded || ![RLPCoreClient shared].started) return;
    [self reloadStatus];
    [self reloadQueue];
}

#pragma mark - 组件构建助手

/// 常驻或可追踪文本（role: 0=正文 t.text, 1=次要 t.mut, 2=警示 t.warn, 3=次级 t.text2, 4=强调 t.accentText）。
/// ⚠️ A6 浅/深主题自检要求：常驻深色文本仅使用 0/1/3/4 档色值，切浅色后务必统一按 role 刷新。
- (NSTextField *)trackedLabel:(NSString *)text font:(NSFont *)font role:(NSInteger)role {
    RLPTheme *t = [RLPTheme current];
    NSColor *c = t.text;
    if (role == 1) c = t.mut;
    else if (role == 2) c = t.warn;
    else if (role == 3) c = t.text2;
    else if (role == 4) c = t.accentText;
    NSTextField *l = RLPLabel(text, font, c);
    l.tag = role;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    if (!self.dynamicLabels) self.dynamicLabels = [NSMutableArray array];
    [self.dynamicLabels addObject:l];
    return l;
}

- (NSColor *)colorForLabelRole:(NSInteger)role theme:(RLPTheme *)t {
    if (role == 1) return t.mut;
    if (role == 2) return t.warn;
    if (role == 3) return t.text2;
    if (role == 4) return t.accentText;
    return t.text;
}

/// 卡片外壳（圆角 + 边框，颜色在 applyTheme 里重刷）。
- (NSView *)cardWithIdentifier:(NSString *)ident {
    RLPTheme *t = [RLPTheme current];
    NSView *c = [[NSView alloc] initWithFrame:NSZeroRect];
    c.identifier = ident;
    c.wantsLayer = YES;
    c.layer.cornerRadius = t.rMd;
    c.layer.backgroundColor = t.bg2.CGColor;
    c.layer.borderWidth = 1.0;
    c.layer.borderColor = t.line.CGColor;
    c.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardSurfaces addObject:c];
    return c;
}

- (NSView *)subSurfaceWithRadius:(CGFloat)radius {
    RLPTheme *t = [RLPTheme current];
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    v.wantsLayer = YES;
    v.layer.cornerRadius = radius;
    v.layer.backgroundColor = t.bg3.CGColor;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = t.line.CGColor;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.subSurfaces addObject:v];
    return v;
}

- (NSView *)iconBadgeWithSymbol:(NSString *)symbol desc:(NSString *)desc size:(CGFloat)size {
    return [self iconBadgeWithSymbol:symbol desc:desc size:size tracked:YES];
}

- (NSView *)iconBadgeWithSymbol:(NSString *)symbol desc:(NSString *)desc size:(CGFloat)size tracked:(BOOL)tracked {
    RLPTheme *t = [RLPTheme current];
    NSView *box = [[NSView alloc] initWithFrame:NSZeroRect];
    box.wantsLayer = YES;
    box.layer.cornerRadius = MAX(6.0, size * 0.28);
    box.layer.backgroundColor = t.accentWeak.CGColor;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iv.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:RLPTr(desc)];
    iv.imageScaling = NSImageScaleProportionallyDown;
    iv.contentTintColor = t.accentText;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:iv];
    [NSLayoutConstraint activateConstraints:@[
        [box.widthAnchor constraintEqualToConstant:size],
        [box.heightAnchor constraintEqualToConstant:size],
        [iv.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:size * 0.56],
        [iv.heightAnchor constraintEqualToConstant:size * 0.56],
    ]];
    if (tracked) [self.iconBadges addObject:box];
    return box;
}

- (NSView *)dividerLineView {
    RLPTheme *t = [RLPTheme current];
    NSView *line = [[NSView alloc] initWithFrame:NSZeroRect];
    line.wantsLayer = YES;
    line.layer.backgroundColor = t.line.CGColor;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dividerLines addObject:line];
    return line;
}

#pragma mark - 骨架

// 页面缓存重入（removeFromSuperview → addSubview）不保证会走 viewDidLayout；
// 监听自身 frame 变化，在宿主宽度一变就按新宽重算断点，避免旧列数把内容撑宽。
- (void)loadView {
    [super loadView];
    self.view.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onRoomFrameChanged:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:self.view];
}

- (void)onRoomFrameChanged:(NSNotification *)note {
    if (note.object != self.view || self.roomFrameUpdateGuard) return;
    const CGFloat w = self.view.bounds.size.width;
    if (w <= 48.0) return;
    self.roomFrameUpdateGuard = YES;
    [self updateResponsiveLayoutForWidth:w - 48.0];
    self.roomFrameUpdateGuard = NO;
}

- (void)buildContent {
    NSView *host = self.contentView;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    // 覆盖式滚动条不占 contentView 宽度：否则滚动条出现时 clip 比 doc 窄 17pt，
    // 整页会横向溢出、右侧卡片被裁（2026-11-18 用户反馈）。
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:scroll];

    self.stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.stack.alignment = NSLayoutAttributeLeading;
    self.stack.spacing = 16;
    self.stack.edgeInsets = NSEdgeInsetsMake(6, 24, 24, 24);
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = self.stack;

    // ⚠️ documentView 只钉 leading/trailing/top/width，不钉 bottom（防内容不足一屏时卡片间距被撑裂）。
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:host.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];

    RLPTheme *t = [RLPTheme current];

    // ---- 顶栏英雄标题区 ----
    self.headerRow = [[NSView alloc] initWithFrame:NSZeroRect];
    self.headerRow.translatesAutoresizingMaskIntoConstraints = NO;

    self.headerTitle = [self trackedLabel:RLPTr(@"聆听室") font:t.display role:0];
    self.headerTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    self.headerSubtitle = [self trackedLabel:RLPTr(@"安静听歌，常用设置就在卡片里") font:t.body role:1];
    self.headerSubtitle.identifier = @"room.subtitle";
    self.headerSubtitle.maximumNumberOfLines = 2;
    self.headerSubtitle.lineBreakMode = NSLineBreakByWordWrapping;

    RLPRoomActionButton *foldersBtn = [RLPRoomActionButton actionButtonWithTitle:RLPTr(@"音乐文件夹")
                                                                          target:self
                                                                          action:@selector(onOpenFolders:)
                                                                    showsChevron:YES
                                                                   primaryAccent:NO
                                                                       minHeight:30.0];
    foldersBtn.identifier = @"room.folders";
    [foldersBtn setChevronIdentifier:@"room.folders.chevron"];
    foldersBtn.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:RLPTr(@"音乐文件夹")];
    foldersBtn.toolTip = RLPTr(@"管理本地音乐文件夹");
    [foldersBtn setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    [foldersBtn setContentHuggingPriority:NSLayoutPriorityRequired
                           forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.foldersButton = foldersBtn;
    [self.actionButtons addObject:foldersBtn];

    [self.headerRow addSubview:self.headerTitle];
    [self.headerRow addSubview:self.headerSubtitle];
    [self.headerRow addSubview:self.foldersButton];
    [self.stack addArrangedSubview:self.headerRow];
    [[self.headerRow.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48] setActive:YES];

    [self buildFourCards];
    [self buildNowPlayingAndQueue];
    [self buildAlbumRow];
    [self buildLibraryCard];
    [self updateResponsiveLayoutForWidth:1052.0];
}

#pragma mark - ① 四张快速设置卡 + 硬件能力栏

- (void)buildFourCards {
    RLPTheme *t = [RLPTheme current];
    NSFont *capFont = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    NSFont *valFont = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];

    // ---- 卡 1：当前设备（就地下拉 + 设备规格摘要，容器本身不整卡可点，避免误触下拉）----
    self.deviceCard = [self cardWithIdentifier:@"room.device"];
    NSView *devIcon = [self iconBadgeWithSymbol:@"speaker.wave.2.fill" desc:@"当前设备" size:24];
    self.deviceCaption = [self trackedLabel:RLPTr(@"当前设备") font:capFont role:1];
    self.deviceCaption.lineBreakMode = NSLineBreakByTruncatingTail;
    RLPRoomActionButton *refreshBtn = [RLPRoomActionButton iconButtonWithSymbol:@"arrow.clockwise"
                                                                           desc:RLPTr(@"重新检测设备")
                                                                         target:self
                                                                         action:@selector(onReloadDevices:)
                                                                           size:28.0];
    refreshBtn.identifier = @"room.deviceRefresh";
    self.devRefreshButton = refreshBtn;
    [self.actionButtons addObject:refreshBtn];

    RLPRoomPopUpButton *devPopup = [[RLPRoomPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    devPopup.identifier = @"room.devicePopup";
    devPopup.translatesAutoresizingMaskIntoConstraints = NO;
    devPopup.target = self;
    devPopup.action = @selector(onDeviceChanged:);
    devPopup.font = t.body;
    devPopup.toolTip = RLPTr(@"点击切换播放设备");
    [devPopup setContentCompressionResistancePriority:40
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [devPopup addItemWithTitle:RLPTr(@"系统默认")];
    self.devicePopup = devPopup;

    self.deviceSub = [self trackedLabel:RLPTr(@"检测中…") font:t.caption role:1];
    self.deviceSub.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSView *v in @[devIcon, self.deviceCaption, self.devRefreshButton, self.devicePopup, self.deviceSub]) {
        [self.deviceCard addSubview:v];
    }

    // ---- 卡 2：输出（整卡可点 + 内嵌按钮感选择条 + chevron）----
    RLPRoomInteractiveCardView *outCard = [[RLPRoomInteractiveCardView alloc] initWithFrame:NSZeroRect];
    outCard.identifier = @"room.output";
    self.outputCard = outCard;
    [self.interactiveCards addObject:outCard];
    NSView *outIcon = [self iconBadgeWithSymbol:@"hifispeaker.2.fill" desc:@"输出" size:24];
    self.outputCaption = [self trackedLabel:RLPTr(@"输出") font:capFont role:1];
    self.outputCaption.lineBreakMode = NSLineBreakByTruncatingTail;
    self.outputChevron = [self trackedLabel:@"›" font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] role:3];
    self.outputChevron.identifier = @"room.output.chevron";
    self.outputChevron.alignment = NSTextAlignmentCenter;
    self.outputValue = [self trackedLabel:RLPTr(@"读取中…") font:valFont role:0];
    self.outputValue.lineBreakMode = NSLineBreakByTruncatingTail;
    self.outputSub = [self trackedLabel:RLPTr(@"点击选择输出方式") font:t.caption role:1];
    self.outputSub.lineBreakMode = NSLineBreakByTruncatingTail;

    RLPRoomCardPillButton *outBtn = [[RLPRoomCardPillButton alloc] initWithFrame:NSZeroRect];
    outBtn.identifier = @"room.output.button";
    outBtn.target = self;
    outBtn.action = @selector(onOpenOutput:);
    outBtn.toolTip = RLPTr(@"点击选择输出方式");
    outBtn.parentCard = outCard;
    outBtn.valueLabel = self.outputValue;
    outBtn.chevronLabel = self.outputChevron;
    [outBtn addSubview:self.outputValue];
    [outBtn addSubview:self.outputChevron];
    outCard.pillButton = outBtn;
    outCard.target = self;
    outCard.action = @selector(onOpenOutput:);
    self.outCardButton = outBtn;
    for (NSView *v in @[outIcon, self.outputCaption, outBtn, self.outputSub]) {
        [self.outputCard addSubview:v];
    }

    // ---- 卡 3：播放（三档，整卡可点 + 内嵌按钮感选择条 + chevron）----
    RLPRoomInteractiveCardView *playCard = [[RLPRoomInteractiveCardView alloc] initWithFrame:NSZeroRect];
    playCard.identifier = @"room.play";
    self.playCard = playCard;
    [self.interactiveCards addObject:playCard];
    NSView *playIcon = [self iconBadgeWithSymbol:@"waveform.path.ecg" desc:@"播放" size:24];
    self.playCaption = [self trackedLabel:RLPTr(@"播放") font:capFont role:1];
    self.playCaption.lineBreakMode = NSLineBreakByTruncatingTail;
    self.playChevron = [self trackedLabel:@"›" font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] role:3];
    self.playChevron.identifier = @"room.play.chevron";
    self.playChevron.alignment = NSTextAlignmentCenter;
    self.playValue = [self trackedLabel:RLPTr(@"原音直通") font:valFont role:0];
    self.playValue.lineBreakMode = NSLineBreakByTruncatingTail;
    self.playSub = [self trackedLabel:RLPTr(@"文件是什么就播什么，不做任何加工") font:t.caption role:1];
    self.playSub.lineBreakMode = NSLineBreakByTruncatingTail;

    RLPRoomCardPillButton *playBtn = [[RLPRoomCardPillButton alloc] initWithFrame:NSZeroRect];
    playBtn.identifier = @"room.play.button";
    playBtn.target = self;
    playBtn.action = @selector(onOpenPlay:);
    playBtn.toolTip = RLPTr(@"点击选择播放方式");
    playBtn.parentCard = playCard;
    playBtn.valueLabel = self.playValue;
    playBtn.chevronLabel = self.playChevron;
    [playBtn addSubview:self.playValue];
    [playBtn addSubview:self.playChevron];
    playCard.pillButton = playBtn;
    playCard.target = self;
    playCard.action = @selector(onOpenPlay:);
    self.playCardButton = playBtn;
    for (NSView *v in @[playIcon, self.playCaption, playBtn, self.playSub]) {
        [self.playCard addSubview:v];
    }

    // ---- 卡 4：听音风格（整卡可点 + 内嵌按钮感选择条 + chevron）----
    RLPRoomInteractiveCardView *styleCard = [[RLPRoomInteractiveCardView alloc] initWithFrame:NSZeroRect];
    styleCard.identifier = @"room.style";
    self.styleCard = styleCard;
    [self.interactiveCards addObject:styleCard];
    NSView *styleIcon = [self iconBadgeWithSymbol:@"slider.horizontal.3" desc:@"听音风格" size:24];
    self.styleCaption = [self trackedLabel:RLPTr(@"听音风格") font:capFont role:1];
    self.styleCaption.lineBreakMode = NSLineBreakByTruncatingTail;
    self.styleChevron = [self trackedLabel:@"›" font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] role:3];
    self.styleChevron.identifier = @"room.style.chevron";
    self.styleChevron.alignment = NSTextAlignmentCenter;
    self.styleValue = [self trackedLabel:RLPTr(@"均衡自然") font:valFont role:0];
    self.styleValue.lineBreakMode = NSLineBreakByTruncatingTail;
    self.styleSub = [self trackedLabel:RLPTr(@"点击选择听感风格") font:t.caption role:1];
    self.styleSub.lineBreakMode = NSLineBreakByTruncatingTail;

    RLPRoomCardPillButton *styleBtn = [[RLPRoomCardPillButton alloc] initWithFrame:NSZeroRect];
    styleBtn.identifier = @"room.style.button";
    styleBtn.target = self;
    styleBtn.action = @selector(onOpenStyle:);
    styleBtn.toolTip = RLPTr(@"点击选择听感风格");
    styleBtn.parentCard = styleCard;
    styleBtn.valueLabel = self.styleValue;
    styleBtn.chevronLabel = self.styleChevron;
    [styleBtn addSubview:self.styleValue];
    [styleBtn addSubview:self.styleChevron];
    styleCard.pillButton = styleBtn;
    styleCard.target = self;
    styleCard.action = @selector(onOpenStyle:);
    self.styleCardButton = styleBtn;
    for (NSView *v in @[styleIcon, self.styleCaption, styleBtn, self.styleSub]) {
        [self.styleCard addSubview:v];
    }

    self.cardsContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    self.cardsContainer.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *c in @[self.deviceCard, self.outputCard, self.playCard, self.styleCard]) {
        [self.cardsContainer addSubview:c];
    }
    [self.stack addArrangedSubview:self.cardsContainer];
    [[self.cardsContainer.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48] setActive:YES];

    // 卡内统一 3 段式排版：顶栏(图标+小标题+刷新) → 30pt 按钮感选择条/下拉 → 技术副标题
    NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
    [cs addObjectsFromArray:@[
        [devIcon.leadingAnchor constraintEqualToAnchor:self.deviceCard.leadingAnchor constant:12],
        [devIcon.topAnchor constraintEqualToAnchor:self.deviceCard.topAnchor constant:12],
        [self.deviceCaption.leadingAnchor constraintEqualToAnchor:devIcon.trailingAnchor constant:8],
        [self.deviceCaption.centerYAnchor constraintEqualToAnchor:devIcon.centerYAnchor],
        [self.deviceCaption.trailingAnchor constraintLessThanOrEqualToAnchor:self.devRefreshButton.leadingAnchor constant:-6],
        [self.devRefreshButton.trailingAnchor constraintEqualToAnchor:self.deviceCard.trailingAnchor constant:-10],
        [self.devRefreshButton.centerYAnchor constraintEqualToAnchor:devIcon.centerYAnchor],
        [self.devRefreshButton.widthAnchor constraintEqualToConstant:28],
        [self.devRefreshButton.heightAnchor constraintEqualToConstant:28],

        [self.devicePopup.leadingAnchor constraintEqualToAnchor:self.deviceCard.leadingAnchor constant:12],
        [self.devicePopup.trailingAnchor constraintEqualToAnchor:self.deviceCard.trailingAnchor constant:-12],
        [self.devicePopup.topAnchor constraintEqualToAnchor:devIcon.bottomAnchor constant:8],

        [self.deviceSub.leadingAnchor constraintEqualToAnchor:self.deviceCard.leadingAnchor constant:12],
        [self.deviceSub.trailingAnchor constraintEqualToAnchor:self.deviceCard.trailingAnchor constant:-12],
        [self.deviceSub.bottomAnchor constraintEqualToAnchor:self.deviceCard.bottomAnchor constant:-10],
    ]];

    NSArray *interactiveSpecs = @[
        @[self.outputCard, outIcon, self.outputCaption, self.outputChevron, self.outputValue, self.outputSub, self.outCardButton],
        @[self.playCard,   playIcon, self.playCaption,   self.playChevron,   self.playValue,   self.playSub,   self.playCardButton],
        @[self.styleCard,  styleIcon, self.styleCaption, self.styleChevron,  self.styleValue,  self.styleSub,  self.styleCardButton],
    ];
    for (NSArray *sp in interactiveSpecs) {
        NSView *card = sp[0], *ico = sp[1];
        NSTextField *cap = sp[2], *chev = sp[3], *val = sp[4], *sub = sp[5];
        NSButton *btn = sp[6];
        [val setContentCompressionResistancePriority:40
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];
        [chev setContentHuggingPriority:NSLayoutPriorityRequired
                         forOrientation:NSLayoutConstraintOrientationHorizontal];
        [chev setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        [cs addObjectsFromArray:@[
            [ico.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [ico.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
            [cap.leadingAnchor constraintEqualToAnchor:ico.trailingAnchor constant:8],
            [cap.centerYAnchor constraintEqualToAnchor:ico.centerYAnchor],
            [cap.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-12],

            [btn.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [btn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [btn.topAnchor constraintEqualToAnchor:ico.bottomAnchor constant:8],
            [btn.heightAnchor constraintGreaterThanOrEqualToConstant:30],

            [val.leadingAnchor constraintEqualToAnchor:btn.leadingAnchor constant:10],
            [val.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor],
            [val.trailingAnchor constraintLessThanOrEqualToAnchor:chev.leadingAnchor constant:-5],
            [chev.trailingAnchor constraintEqualToAnchor:btn.trailingAnchor constant:-8],
            [chev.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor constant:-0.5],
            [chev.widthAnchor constraintEqualToConstant:12],

            [sub.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [sub.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [sub.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
        ]];
    }
    [NSLayoutConstraint activateConstraints:cs];

    // ---- 硬件能力与预设状态栏卡（把 /api/preset/caps 与 presetNotes 收进结构化条卡）----
    self.capsCard = [self cardWithIdentifier:@"room.caps"];
    NSView *capsIcon = [self iconBadgeWithSymbol:@"checkmark.seal.fill" desc:@"官方推荐预设" size:22];
    self.capsTitleLabel = [self trackedLabel:RLPTr(@"官方推荐预设")
                                        font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
                                        role:0];
    self.capsTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.capsPcmPill = [self subSurfaceWithRadius:6];
    self.capsPcmBadge = [self trackedLabel:@"PCM —" font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold] role:1];
    [self.capsPcmBadge setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.capsPcmBadge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.capsPcmPill addSubview:self.capsPcmBadge];
    [self.capsPcmPill setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.capsPcmPill setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.capsDsdPill = [self subSurfaceWithRadius:6];
    self.capsDsdBadge = [self trackedLabel:@"DSD —" font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold] role:1];
    [self.capsDsdBadge setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.capsDsdBadge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.capsDsdPill addSubview:self.capsDsdBadge];
    [self.capsDsdPill setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.capsDsdPill setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.capsPillsStack = [[NSStackView alloc] init];
    self.capsPillsStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.capsPillsStack.alignment = NSLayoutAttributeCenterY;
    self.capsPillsStack.spacing = 6;
    self.capsPillsStack.detachesHiddenViews = YES;
    self.capsPillsStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.capsPillsStack setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.capsPillsStack setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.capsPillsStack addArrangedSubview:self.capsPcmPill];
    [self.capsPillsStack addArrangedSubview:self.capsDsdPill];

    self.capsInfoLabel = [self trackedLabel:[NSString stringWithFormat:@"%@%@", RLPTr(@"当前设备："), RLPTr(@"检测中…")]
                                       font:t.small
                                       role:3];
    self.capsInfoLabel.maximumNumberOfLines = 2;
    self.capsInfoLabel.lineBreakMode = NSLineBreakByWordWrapping;

    self.capsDivider = [self dividerLineView];

    self.presetNotes = [self trackedLabel:RLPTr(@"不确定就选「原音直通」：文件是什么就播什么。") font:t.small role:1];
    self.presetNotes.maximumNumberOfLines = 2;
    self.presetNotes.lineBreakMode = NSLineBreakByWordWrapping;

    for (NSView *v in @[capsIcon, self.capsTitleLabel, self.capsPillsStack,
                        self.capsInfoLabel, self.capsDivider, self.presetNotes]) {
        [self.capsCard addSubview:v];
    }
    [self.stack addArrangedSubview:self.capsCard];

    [NSLayoutConstraint activateConstraints:@[
        [self.capsCard.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],

        [capsIcon.leadingAnchor constraintEqualToAnchor:self.capsCard.leadingAnchor constant:14],
        [capsIcon.topAnchor constraintEqualToAnchor:self.capsCard.topAnchor constant:11],
        [self.capsTitleLabel.leadingAnchor constraintEqualToAnchor:capsIcon.trailingAnchor constant:8],
        [self.capsTitleLabel.centerYAnchor constraintEqualToAnchor:capsIcon.centerYAnchor],
        [self.capsTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.capsPillsStack.leadingAnchor constant:-8],

        [self.capsPillsStack.trailingAnchor constraintEqualToAnchor:self.capsCard.trailingAnchor constant:-14],
        [self.capsPillsStack.centerYAnchor constraintEqualToAnchor:capsIcon.centerYAnchor],
        [self.capsDsdBadge.leadingAnchor constraintEqualToAnchor:self.capsDsdPill.leadingAnchor constant:8],
        [self.capsDsdBadge.trailingAnchor constraintEqualToAnchor:self.capsDsdPill.trailingAnchor constant:-8],
        [self.capsDsdBadge.topAnchor constraintEqualToAnchor:self.capsDsdPill.topAnchor constant:3],
        [self.capsDsdBadge.bottomAnchor constraintEqualToAnchor:self.capsDsdPill.bottomAnchor constant:-3],

        [self.capsPcmBadge.leadingAnchor constraintEqualToAnchor:self.capsPcmPill.leadingAnchor constant:8],
        [self.capsPcmBadge.trailingAnchor constraintEqualToAnchor:self.capsPcmPill.trailingAnchor constant:-8],
        [self.capsPcmBadge.topAnchor constraintEqualToAnchor:self.capsPcmPill.topAnchor constant:3],
        [self.capsPcmBadge.bottomAnchor constraintEqualToAnchor:self.capsPcmPill.bottomAnchor constant:-3],

        [self.capsInfoLabel.leadingAnchor constraintEqualToAnchor:self.capsCard.leadingAnchor constant:14],
        [self.capsInfoLabel.trailingAnchor constraintEqualToAnchor:self.capsCard.trailingAnchor constant:-14],
        [self.capsInfoLabel.topAnchor constraintEqualToAnchor:capsIcon.bottomAnchor constant:8],

        [self.capsDivider.leadingAnchor constraintEqualToAnchor:self.capsCard.leadingAnchor constant:14],
        [self.capsDivider.trailingAnchor constraintEqualToAnchor:self.capsCard.trailingAnchor constant:-14],
        [self.capsDivider.topAnchor constraintEqualToAnchor:self.capsInfoLabel.bottomAnchor constant:8],
        [self.capsDivider.heightAnchor constraintEqualToConstant:1],

        [self.presetNotes.leadingAnchor constraintEqualToAnchor:self.capsCard.leadingAnchor constant:14],
        [self.presetNotes.trailingAnchor constraintEqualToAnchor:self.capsCard.trailingAnchor constant:-14],
        [self.presetNotes.topAnchor constraintEqualToAnchor:self.capsDivider.bottomAnchor constant:7],
        [self.presetNotes.bottomAnchor constraintEqualToAnchor:self.capsCard.bottomAnchor constant:-10],
    ]];
}

#pragma mark - ② 正在播放 + 队列预览

- (void)buildNowPlayingAndQueue {
    RLPTheme *t = [RLPTheme current];
    NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    self.npQueueRow = row;

    // ---- 正在播放主卡 ----
    NSView *np = [self cardWithIdentifier:@"room.nowplaying"];
    self.npCard = np;

    self.npCover = [[RLPRoomCoverImageView alloc] initWithFrame:NSZeroRect];
    self.npCover.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.npCover.wantsLayer = YES;
    self.npCover.layer.cornerRadius = t.rSm;
    self.npCover.layer.masksToBounds = YES;
    self.npCover.layer.backgroundColor = t.cvBg.CGColor;
    self.npCover.layer.borderWidth = 1.0;
    self.npCover.layer.borderColor = t.line.CGColor;
    self.npCover.translatesAutoresizingMaskIntoConstraints = NO;
    [self.npCover setContentCompressionResistancePriority:40
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.npCover setContentCompressionResistancePriority:40
                                           forOrientation:NSLayoutConstraintOrientationVertical];
    [self.npCover setContentHuggingPriority:40
                               forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.npCover setContentHuggingPriority:40
                               forOrientation:NSLayoutConstraintOrientationVertical];

    self.npPlaceholder = [self trackedLabel:@"♪" font:[NSFont systemFontOfSize:34 weight:NSFontWeightLight] role:1];
    self.npPlaceholder.alignment = NSTextAlignmentCenter;

    self.npStatePill = [self subSurfaceWithRadius:6];
    self.npState = [self trackedLabel:RLPTr(@"未播放")
                                font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
                                role:1];
    [self.npState setContentHuggingPriority:NSLayoutPriorityRequired
                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.npState setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.npStatePill addSubview:self.npState];

    self.npFormatPill = [self subSurfaceWithRadius:6];
    self.npFormatLabel = [self trackedLabel:@"" font:t.mono role:1];
    self.npFormatLabel.maximumNumberOfLines = 1;
    self.npFormatLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.npFormatPill addSubview:self.npFormatLabel];
    self.npFormatPill.hidden = YES;

    self.npTitle = [self trackedLabel:RLPTr(@"还没有在播放的音乐") font:t.heading role:0];
    self.npTitle.maximumNumberOfLines = 2;
    self.npTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.npTitle setContentCompressionResistancePriority:40
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.npSub = [self trackedLabel:RLPTr(@"从下面的专辑挑一张开始") font:t.body role:1];
    self.npSub.maximumNumberOfLines = 1;
    self.npSub.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.npSub setContentCompressionResistancePriority:40
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.npProgressBar = [[RLPRoomProgressView alloc] initWithFrame:NSZeroRect];
    self.npProgressBar.translatesAutoresizingMaskIntoConstraints = NO;

    self.npTimeLabel = [self trackedLabel:@"0:00 / 0:00" font:t.mono role:1];
    [self.npTimeLabel setContentHuggingPriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.npTimeLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                               forOrientation:NSLayoutConstraintOrientationHorizontal];

    RLPRoomActionButton *toggleBtn = [RLPRoomActionButton actionButtonWithTitle:RLPTr(@"继续播放")
                                                                         target:self
                                                                         action:@selector(onTogglePlay:)
                                                                   showsChevron:NO
                                                                  primaryAccent:YES
                                                                      minHeight:30.0];
    toggleBtn.identifier = @"room.playToggle";
    toggleBtn.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:RLPTr(@"继续播放")];
    [toggleBtn setContentCompressionResistancePriority:40
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.npToggle = toggleBtn;
    [self.actionButtons addObject:toggleBtn];

    RLPRoomActionButton *npOpen = [RLPRoomActionButton actionButtonWithTitle:RLPTr(@"打开专辑页")
                                                                      target:self
                                                                      action:@selector(onOpenCurrentAlbum:)
                                                                showsChevron:YES
                                                               primaryAccent:NO
                                                                   minHeight:30.0];
    npOpen.identifier = @"room.openAlbum";
    [npOpen setChevronIdentifier:@"room.openAlbum.chevron"];
    npOpen.toolTip = RLPTr(@"打开当前曲目所属专辑页");
    [npOpen setContentCompressionResistancePriority:40
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.npOpenButton = npOpen;
    [self.actionButtons addObject:npOpen];

    for (NSView *v in @[self.npCover, self.npPlaceholder, self.npStatePill, self.npFormatPill,
                        self.npTitle, self.npSub, self.npProgressBar, self.npTimeLabel,
                        self.npToggle, npOpen]) {
        [np addSubview:v];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.npCover.heightAnchor constraintEqualToAnchor:self.npCover.widthAnchor],
        [self.npPlaceholder.centerXAnchor constraintEqualToAnchor:self.npCover.centerXAnchor],
        [self.npPlaceholder.centerYAnchor constraintEqualToAnchor:self.npCover.centerYAnchor],

        [self.npState.leadingAnchor constraintEqualToAnchor:self.npStatePill.leadingAnchor constant:8],
        [self.npState.trailingAnchor constraintEqualToAnchor:self.npStatePill.trailingAnchor constant:-8],
        [self.npState.topAnchor constraintEqualToAnchor:self.npStatePill.topAnchor constant:3],
        [self.npState.bottomAnchor constraintEqualToAnchor:self.npStatePill.bottomAnchor constant:-3],

        [self.npFormatLabel.leadingAnchor constraintEqualToAnchor:self.npFormatPill.leadingAnchor constant:8],
        [self.npFormatLabel.trailingAnchor constraintEqualToAnchor:self.npFormatPill.trailingAnchor constant:-8],
        [self.npFormatLabel.topAnchor constraintEqualToAnchor:self.npFormatPill.topAnchor constant:3],
        [self.npFormatLabel.bottomAnchor constraintEqualToAnchor:self.npFormatPill.bottomAnchor constant:-3],

        [self.npProgressBar.heightAnchor constraintEqualToConstant:4],
    ]];
    [self showCoverPlaceholder];

    // ---- 队列预览卡 ----
    NSView *qcard = [self cardWithIdentifier:@"room.queue"];
    self.queueCard = qcard;
    self.queueCaption = [self trackedLabel:RLPTr(@"播放队列") font:t.heading role:0];
    self.queueCaption.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.queueCaption setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.queueCountLabel = [self trackedLabel:@"0" font:t.small role:1];

    RLPRoomActionButton *qAll = [RLPRoomActionButton actionButtonWithTitle:RLPTr(@"查看全部")
                                                                    target:self
                                                                    action:@selector(onOpenQueue:)
                                                              showsChevron:YES
                                                             primaryAccent:NO
                                                                 minHeight:28.0];
    qAll.identifier = @"room.queueAll";
    [qAll setChevronIdentifier:@"room.queueAll.chevron"];
    qAll.toolTip = RLPTr(@"打开播放队列页");
    [qAll setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [qAll setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.queueAllButton = qAll;
    [self.actionButtons addObject:qAll];

    self.queueList = [[NSStackView alloc] init];
    self.queueList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.queueList.alignment = NSLayoutAttributeLeading;
    self.queueList.spacing = 6;
    self.queueList.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[self.queueCaption, self.queueCountLabel, qAll, self.queueList]) {
        [qcard addSubview:v];
    }

    [row addSubview:np];
    [row addSubview:qcard];
    [self.stack addArrangedSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [row.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],

        [self.queueCaption.leadingAnchor constraintEqualToAnchor:qcard.leadingAnchor constant:14],
        [self.queueCaption.topAnchor constraintEqualToAnchor:qcard.topAnchor constant:14],
        [self.queueCountLabel.leadingAnchor constraintEqualToAnchor:self.queueCaption.trailingAnchor constant:8],
        [self.queueCountLabel.firstBaselineAnchor constraintEqualToAnchor:self.queueCaption.firstBaselineAnchor],
        [self.queueCountLabel.trailingAnchor constraintLessThanOrEqualToAnchor:qAll.leadingAnchor constant:-8],
        [qAll.trailingAnchor constraintEqualToAnchor:qcard.trailingAnchor constant:-14],
        [qAll.centerYAnchor constraintEqualToAnchor:self.queueCaption.centerYAnchor],

        [self.queueList.leadingAnchor constraintEqualToAnchor:qcard.leadingAnchor constant:14],
        [self.queueList.trailingAnchor constraintEqualToAnchor:qcard.trailingAnchor constant:-14],
        [self.queueList.topAnchor constraintEqualToAnchor:self.queueCaption.bottomAnchor constant:12],
        [self.queueList.bottomAnchor constraintLessThanOrEqualToAnchor:qcard.bottomAnchor constant:-14],
    ]];

    [self renderQueueEmptyState];
}

#pragma mark - ③ 专辑网格

- (void)buildAlbumRow {
    RLPTheme *t = [RLPTheme current];
    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    self.albumCaption = [self trackedLabel:RLPTr(@"专辑") font:t.heading role:0];
    self.albumCaption.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.albumCaption setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.albumCountLabel = [self trackedLabel:@"0" font:t.small role:1];

    RLPRoomActionButton *openLib = [RLPRoomActionButton actionButtonWithTitle:RLPTr(@"打开音乐库")
                                                                       target:self
                                                                       action:@selector(onOpenAlbums:)
                                                                 showsChevron:YES
                                                                primaryAccent:NO
                                                                    minHeight:28.0];
    openLib.identifier = @"room.openAlbums";
    [openLib setChevronIdentifier:@"room.openAlbums.chevron"];
    openLib.toolTip = RLPTr(@"查看全部专辑");
    [openLib setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [openLib setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.openLibButton = openLib;
    [self.actionButtons addObject:openLib];
    [head addSubview:self.albumCaption];
    [head addSubview:self.albumCountLabel];
    [head addSubview:openLib];
    [self.stack addArrangedSubview:head];

    self.albumRow = [[NSStackView alloc] init];
    self.albumRow.identifier = @"room.albums";
    self.albumRow.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.albumRow.alignment = NSLayoutAttributeLeading;
    self.albumRow.spacing = 12;
    self.albumRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.albumRow setContentCompressionResistancePriority:40
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.stack addArrangedSubview:self.albumRow];

    [NSLayoutConstraint activateConstraints:@[
        [head.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
        [head.heightAnchor constraintGreaterThanOrEqualToConstant:28],
        [self.albumCaption.leadingAnchor constraintEqualToAnchor:head.leadingAnchor],
        [self.albumCaption.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [self.albumCountLabel.leadingAnchor constraintEqualToAnchor:self.albumCaption.trailingAnchor constant:8],
        [self.albumCountLabel.firstBaselineAnchor constraintEqualToAnchor:self.albumCaption.firstBaselineAnchor],
        [self.albumCountLabel.trailingAnchor constraintLessThanOrEqualToAnchor:openLib.leadingAnchor constant:-8],
        [openLib.trailingAnchor constraintEqualToAnchor:head.trailingAnchor],
        [openLib.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [self.albumRow.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],
    ]];
}

#pragma mark - ④ 音乐库 + 扩展伴随卡（就地弹层，不放设置按钮）

- (void)buildLibraryCard {
    RLPTheme *t = [RLPTheme current];
    self.libraryRow = [[NSView alloc] initWithFrame:NSZeroRect];
    self.libraryRow.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- 左侧主卡：本地音乐库 ----
    self.libraryCard = [self cardWithIdentifier:@"room.library"];
    NSView *libIcon = [self iconBadgeWithSymbol:@"music.note.house.fill" desc:@"本地音乐库" size:24];
    self.libTitleLabel = [self trackedLabel:RLPTr(@"本地音乐库")
                                       font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                                       role:0];
    self.libTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    self.libFormatPill = [self subSurfaceWithRadius:6];
    self.libFormatBadge = [self trackedLabel:@"FLAC · DSD · ALAC · WAV"
                                        font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium]
                                        role:1];
    [self.libFormatBadge setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.libFormatBadge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.libFormatPill setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.libFormatPill setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.libFormatPill addSubview:self.libFormatBadge];

    self.libDesc = [self trackedLabel:RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE") font:t.small role:1];
    self.libDesc.maximumNumberOfLines = 2;
    self.libDesc.lineBreakMode = NSLineBreakByWordWrapping;

    self.libRootLabel = [self trackedLabel:RLPTr(@"还没有添加音乐目录") font:t.caption role:1];
    self.libRootLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    RLPRoomActionButton *libBtn = [RLPRoomActionButton actionButtonWithTitle:RLPTr(@"添加音乐目录")
                                                                      target:self
                                                                      action:@selector(onLibraryAction:)
                                                                showsChevron:YES
                                                               primaryAccent:NO
                                                                   minHeight:30.0];
    libBtn.identifier = @"room.libraryAction";
    [libBtn setChevronIdentifier:@"room.libraryAction.chevron"];
    libBtn.toolTip = RLPTr(@"管理或重新扫描本地音乐库");
    [libBtn setContentCompressionResistancePriority:40
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.libButton = libBtn;
    [self.actionButtons addObject:libBtn];

    for (NSView *v in @[libIcon, self.libTitleLabel, self.libFormatPill, self.libDesc, self.libRootLabel, self.libButton]) {
        [self.libraryCard addSubview:v];
    }

    // ---- 右侧伴随卡：流媒体与扩展（「更多」就地弹层）----
    self.moreCard = [self cardWithIdentifier:@"room.extensions"];
    NSView *moreIcon = [self iconBadgeWithSymbol:@"icloud.and.arrow.down.fill" desc:@"流媒体" size:24];
    self.moreTitleLabel = [self trackedLabel:RLPTr(@"流媒体")
                                        font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                                        role:0];
    self.moreTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.moreDescLabel = [self trackedLabel:RLPTr(@"流媒体在这里挂载；AI 资料与音频输入在左侧「设置」里调整。")
                                       font:t.small
                                       role:1];
    self.moreDescLabel.maximumNumberOfLines = 3;
    self.moreDescLabel.lineBreakMode = NSLineBreakByWordWrapping;

    // 更多入口：功能不能删，且聆听室里绝不出现含「设置」的 NSButton。
    RLPRoomActionButton *moreBtn = [RLPRoomActionButton actionButtonWithTitle:RLPTr(@"更多")
                                                                       target:self
                                                                       action:@selector(onOpenMore:)
                                                                 showsChevron:YES
                                                                primaryAccent:NO
                                                                    minHeight:30.0];
    moreBtn.identifier = @"room.more";
    [moreBtn setChevronIdentifier:@"room.more.chevron"];
    moreBtn.toolTip = RLPTr(@"流媒体挂载与扩展入口");
    [moreBtn setContentCompressionResistancePriority:40
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.moreButton = moreBtn;
    [self.actionButtons addObject:moreBtn];

    for (NSView *v in @[moreIcon, self.moreTitleLabel, self.moreDescLabel, self.moreButton]) {
        [self.moreCard addSubview:v];
    }

    [self.libraryRow addSubview:self.libraryCard];
    [self.libraryRow addSubview:self.moreCard];
    [self.stack addArrangedSubview:self.libraryRow];

    self.libTitleToPillConstraint = [self.libTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.libFormatPill.leadingAnchor constant:-8];
    self.libTitleToEdgeConstraint = [self.libTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.libraryCard.trailingAnchor constant:-14];

    [NSLayoutConstraint activateConstraints:@[
        [self.libraryRow.widthAnchor constraintEqualToAnchor:self.stack.widthAnchor constant:-48],

        [libIcon.leadingAnchor constraintEqualToAnchor:self.libraryCard.leadingAnchor constant:14],
        [libIcon.topAnchor constraintEqualToAnchor:self.libraryCard.topAnchor constant:13],
        [self.libTitleLabel.leadingAnchor constraintEqualToAnchor:libIcon.trailingAnchor constant:8],
        [self.libTitleLabel.centerYAnchor constraintEqualToAnchor:libIcon.centerYAnchor],
        self.libTitleToPillConstraint,

        [self.libFormatPill.trailingAnchor constraintEqualToAnchor:self.libraryCard.trailingAnchor constant:-14],
        [self.libFormatPill.centerYAnchor constraintEqualToAnchor:libIcon.centerYAnchor],
        [self.libFormatBadge.leadingAnchor constraintEqualToAnchor:self.libFormatPill.leadingAnchor constant:8],
        [self.libFormatBadge.trailingAnchor constraintEqualToAnchor:self.libFormatPill.trailingAnchor constant:-8],
        [self.libFormatBadge.topAnchor constraintEqualToAnchor:self.libFormatPill.topAnchor constant:3],
        [self.libFormatBadge.bottomAnchor constraintEqualToAnchor:self.libFormatPill.bottomAnchor constant:-3],

        [self.libDesc.leadingAnchor constraintEqualToAnchor:self.libraryCard.leadingAnchor constant:14],
        [self.libDesc.trailingAnchor constraintEqualToAnchor:self.libraryCard.trailingAnchor constant:-14],
        [self.libDesc.topAnchor constraintEqualToAnchor:libIcon.bottomAnchor constant:10],

        [self.libRootLabel.leadingAnchor constraintEqualToAnchor:self.libraryCard.leadingAnchor constant:14],
        [self.libRootLabel.trailingAnchor constraintEqualToAnchor:self.libraryCard.trailingAnchor constant:-14],
        [self.libRootLabel.topAnchor constraintEqualToAnchor:self.libDesc.bottomAnchor constant:4],

        [self.libButton.leadingAnchor constraintEqualToAnchor:self.libraryCard.leadingAnchor constant:14],
        [self.libButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.libraryCard.trailingAnchor constant:-14],
        [self.libButton.topAnchor constraintEqualToAnchor:self.libRootLabel.bottomAnchor constant:10],
        [self.libButton.bottomAnchor constraintEqualToAnchor:self.libraryCard.bottomAnchor constant:-13],

        [moreIcon.leadingAnchor constraintEqualToAnchor:self.moreCard.leadingAnchor constant:14],
        [moreIcon.topAnchor constraintEqualToAnchor:self.moreCard.topAnchor constant:13],
        [self.moreTitleLabel.leadingAnchor constraintEqualToAnchor:moreIcon.trailingAnchor constant:8],
        [self.moreTitleLabel.centerYAnchor constraintEqualToAnchor:moreIcon.centerYAnchor],
        [self.moreTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.moreCard.trailingAnchor constant:-14],

        [self.moreDescLabel.leadingAnchor constraintEqualToAnchor:self.moreCard.leadingAnchor constant:14],
        [self.moreDescLabel.trailingAnchor constraintEqualToAnchor:self.moreCard.trailingAnchor constant:-14],
        [self.moreDescLabel.topAnchor constraintEqualToAnchor:moreIcon.bottomAnchor constant:10],

        [self.moreButton.leadingAnchor constraintEqualToAnchor:self.moreCard.leadingAnchor constant:14],
        [self.moreButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.moreCard.trailingAnchor constant:-14],
        [self.moreButton.topAnchor constraintGreaterThanOrEqualToAnchor:self.moreDescLabel.bottomAnchor constant:10],
        [self.moreButton.bottomAnchor constraintEqualToAnchor:self.moreCard.bottomAnchor constant:-13],
    ]];
}

#pragma mark - 响应式自适应布局

- (void)viewWillLayout {
    [super viewWillLayout];
    const CGFloat w = self.view.bounds.size.width;
    if (w > 48.0) [self updateResponsiveLayoutForWidth:w - 48.0];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    const CGFloat w = self.view.bounds.size.width;
    if (w > 48.0) [self updateResponsiveLayoutForWidth:w - 48.0];
}

- (void)updateResponsiveLayoutForWidth:(CGFloat)availWidth {
    const CGFloat w = availWidth > 100.0 ? availWidth : 1052.0;

    // 0) 页头窄屏折行防重叠
    const BOOL headerStacked = (w <= 460.0);
    if ((!self.headerLayoutInitialized || headerStacked != self.currentHeaderStacked) && self.headerRow) {
        [NSLayoutConstraint deactivateConstraints:self.headerLayoutConstraints];
        [self.headerLayoutConstraints removeAllObjects];
        self.headerLayoutInitialized = YES;
        self.currentHeaderStacked = headerStacked;

        if (!headerStacked) {
            [self.headerLayoutConstraints addObjectsFromArray:@[
                [self.headerTitle.leadingAnchor constraintEqualToAnchor:self.headerRow.leadingAnchor],
                [self.headerTitle.topAnchor constraintEqualToAnchor:self.headerRow.topAnchor],
                [self.headerTitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.foldersButton.leadingAnchor constant:-12],
                [self.headerSubtitle.leadingAnchor constraintEqualToAnchor:self.headerRow.leadingAnchor],
                [self.headerSubtitle.topAnchor constraintEqualToAnchor:self.headerTitle.bottomAnchor constant:4],
                [self.headerSubtitle.trailingAnchor constraintLessThanOrEqualToAnchor:self.foldersButton.leadingAnchor constant:-12],
                [self.headerSubtitle.bottomAnchor constraintEqualToAnchor:self.headerRow.bottomAnchor],
                [self.foldersButton.trailingAnchor constraintEqualToAnchor:self.headerRow.trailingAnchor],
                [self.foldersButton.centerYAnchor constraintEqualToAnchor:self.headerTitle.centerYAnchor],
            ]];
        } else {
            [self.headerLayoutConstraints addObjectsFromArray:@[
                [self.headerTitle.leadingAnchor constraintEqualToAnchor:self.headerRow.leadingAnchor],
                [self.headerTitle.trailingAnchor constraintEqualToAnchor:self.headerRow.trailingAnchor],
                [self.headerTitle.topAnchor constraintEqualToAnchor:self.headerRow.topAnchor],
                [self.headerSubtitle.leadingAnchor constraintEqualToAnchor:self.headerRow.leadingAnchor],
                [self.headerSubtitle.trailingAnchor constraintEqualToAnchor:self.headerRow.trailingAnchor],
                [self.headerSubtitle.topAnchor constraintEqualToAnchor:self.headerTitle.bottomAnchor constant:4],
                [self.foldersButton.leadingAnchor constraintEqualToAnchor:self.headerRow.leadingAnchor],
                [self.foldersButton.topAnchor constraintEqualToAnchor:self.headerSubtitle.bottomAnchor constant:10],
                [self.foldersButton.bottomAnchor constraintEqualToAnchor:self.headerRow.bottomAnchor],
            ]];
        }
        [NSLayoutConstraint activateConstraints:self.headerLayoutConstraints];
    }

    // 1) 四张快捷卡：>750 -> 4 列；<=750 -> 2x2；<=350 -> 1x4
    const NSInteger cols = RLPQuickStartColumnsForWidth(w);
    if (cols != self.currentCardColumns && self.cardsContainer) {
        [NSLayoutConstraint deactivateConstraints:self.cardsLayoutConstraints];
        [self.cardsLayoutConstraints removeAllObjects];
        self.currentCardColumns = cols;

        NSView *c = self.cardsContainer;
        NSView *c1 = self.deviceCard, *c2 = self.outputCard, *c3 = self.playCard, *c4 = self.styleCard;
        if (cols == 4) {
            [self.cardsLayoutConstraints addObjectsFromArray:@[
                [c1.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c1.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c1.heightAnchor constraintEqualToConstant:118],
                [c2.leadingAnchor constraintEqualToAnchor:c1.trailingAnchor constant:12],
                [c2.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c2.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c2.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c3.leadingAnchor constraintEqualToAnchor:c2.trailingAnchor constant:12],
                [c3.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c3.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c3.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c4.leadingAnchor constraintEqualToAnchor:c3.trailingAnchor constant:12],
                [c4.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c4.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c4.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c4.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c.bottomAnchor constraintEqualToAnchor:c1.bottomAnchor],
            ]];
        } else if (cols == 2) {
            [self.cardsLayoutConstraints addObjectsFromArray:@[
                [c1.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c1.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c1.heightAnchor constraintEqualToConstant:114],
                [c2.leadingAnchor constraintEqualToAnchor:c1.trailingAnchor constant:12],
                [c2.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c2.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c2.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c2.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c3.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c3.topAnchor constraintEqualToAnchor:c1.bottomAnchor constant:12],
                [c3.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c3.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c4.leadingAnchor constraintEqualToAnchor:c3.trailingAnchor constant:12],
                [c4.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c4.topAnchor constraintEqualToAnchor:c3.topAnchor],
                [c4.widthAnchor constraintEqualToAnchor:c1.widthAnchor],
                [c4.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c.bottomAnchor constraintEqualToAnchor:c3.bottomAnchor],
            ]];
        } else {
            [self.cardsLayoutConstraints addObjectsFromArray:@[
                [c1.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c1.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c1.topAnchor constraintEqualToAnchor:c.topAnchor],
                [c1.heightAnchor constraintEqualToConstant:108],
                [c2.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c2.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c2.topAnchor constraintEqualToAnchor:c1.bottomAnchor constant:10],
                [c2.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c3.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c3.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c3.topAnchor constraintEqualToAnchor:c2.bottomAnchor constant:10],
                [c3.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c4.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
                [c4.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
                [c4.topAnchor constraintEqualToAnchor:c3.bottomAnchor constant:10],
                [c4.heightAnchor constraintEqualToAnchor:c1.heightAnchor],
                [c.bottomAnchor constraintEqualToAnchor:c4.bottomAnchor],
            ]];
        }
        [NSLayoutConstraint activateConstraints:self.cardsLayoutConstraints];
    }

    // 能力条胶囊：窄窗适度收缩、防止挤掉小标题（隐藏时同步放开标题右边距）
    if (self.capsPcmPill && self.capsDsdPill) {
        self.capsPcmPill.hidden = (w <= 400.0);
        self.capsDsdPill.hidden = (w <= 340.0);
    }
    if (self.libFormatPill) {
        const BOOL hideLibPill = (w <= 420.0);
        self.libFormatPill.hidden = hideLibPill;
        self.libTitleToPillConstraint.active = !hideLibPill;
        self.libTitleToEdgeConstraint.active = hideLibPill;
    }

    const BOOL stacked = (w <= 750.0);
    const BOOL wideRail = (w >= 940.0);
    const CGFloat railW = wideRail ? 360.0 : 300.0;
    const CGFloat npW = stacked ? w : (w - railW - 14.0);

    // 2) 正在播放卡内部排版（依据卡片自身可用宽 npW 判定：>490 左封面右信息；<=490 紧凑顶头+下方全宽进度与按钮）
    const BOOL compactNp = (npW <= 490.0);
    if ((!self.npCardLayoutInitialized || compactNp != self.currentNpCompact) && self.npCard) {
        [NSLayoutConstraint deactivateConstraints:self.npCardConstraints];
        [self.npCardConstraints removeAllObjects];
        self.npCardLayoutInitialized = YES;
        self.currentNpCompact = compactNp;

        NSView *np = self.npCard;
        if (!compactNp) {
            [self.npCardConstraints addObjectsFromArray:@[
                [self.npCover.leadingAnchor constraintEqualToAnchor:np.leadingAnchor constant:18],
                [self.npCover.centerYAnchor constraintEqualToAnchor:np.centerYAnchor],
                [self.npCover.widthAnchor constraintEqualToConstant:164],

                [self.npStatePill.leadingAnchor constraintEqualToAnchor:self.npCover.trailingAnchor constant:18],
                [self.npStatePill.topAnchor constraintEqualToAnchor:np.topAnchor constant:20],
                [self.npFormatPill.leadingAnchor constraintEqualToAnchor:self.npStatePill.trailingAnchor constant:8],
                [self.npFormatPill.centerYAnchor constraintEqualToAnchor:self.npStatePill.centerYAnchor],
                [self.npFormatPill.trailingAnchor constraintLessThanOrEqualToAnchor:np.trailingAnchor constant:-18],

                [self.npTitle.leadingAnchor constraintEqualToAnchor:self.npStatePill.leadingAnchor],
                [self.npTitle.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-18],
                [self.npTitle.topAnchor constraintEqualToAnchor:self.npStatePill.bottomAnchor constant:10],

                [self.npSub.leadingAnchor constraintEqualToAnchor:self.npStatePill.leadingAnchor],
                [self.npSub.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-18],
                [self.npSub.topAnchor constraintEqualToAnchor:self.npTitle.bottomAnchor constant:5],

                [self.npProgressBar.leadingAnchor constraintEqualToAnchor:self.npStatePill.leadingAnchor],
                [self.npProgressBar.centerYAnchor constraintEqualToAnchor:self.npTimeLabel.centerYAnchor],
                [self.npProgressBar.trailingAnchor constraintEqualToAnchor:self.npTimeLabel.leadingAnchor constant:-10],
                [self.npTimeLabel.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-18],
                [self.npTimeLabel.topAnchor constraintEqualToAnchor:self.npSub.bottomAnchor constant:14],

                [self.npToggle.leadingAnchor constraintEqualToAnchor:self.npStatePill.leadingAnchor],
                [self.npToggle.topAnchor constraintEqualToAnchor:self.npTimeLabel.bottomAnchor constant:14],
                [self.npOpenButton.leadingAnchor constraintEqualToAnchor:self.npToggle.trailingAnchor constant:10],
                [self.npOpenButton.centerYAnchor constraintEqualToAnchor:self.npToggle.centerYAnchor],
                [self.npOpenButton.trailingAnchor constraintLessThanOrEqualToAnchor:np.trailingAnchor constant:-18],
                [self.npToggle.bottomAnchor constraintLessThanOrEqualToAnchor:np.bottomAnchor constant:-18],
            ]];
        } else {
            NSLayoutConstraint *pinTime = [self.npTimeLabel.topAnchor constraintEqualToAnchor:self.npCover.bottomAnchor constant:12];
            pinTime.priority = NSLayoutPriorityDefaultLow;
            NSLayoutConstraint *hugBottom = [self.npToggle.bottomAnchor constraintEqualToAnchor:np.bottomAnchor constant:-14];
            hugBottom.priority = NSLayoutPriorityDefaultLow - 10;
            [self.npCardConstraints addObjectsFromArray:@[
                [self.npCover.leadingAnchor constraintEqualToAnchor:np.leadingAnchor constant:14],
                [self.npCover.topAnchor constraintEqualToAnchor:np.topAnchor constant:14],
                [self.npCover.widthAnchor constraintEqualToConstant:72],

                [self.npStatePill.leadingAnchor constraintEqualToAnchor:self.npCover.trailingAnchor constant:12],
                [self.npStatePill.topAnchor constraintEqualToAnchor:self.npCover.topAnchor],
                [self.npFormatPill.leadingAnchor constraintEqualToAnchor:self.npStatePill.trailingAnchor constant:6],
                [self.npFormatPill.centerYAnchor constraintEqualToAnchor:self.npStatePill.centerYAnchor],
                [self.npFormatPill.trailingAnchor constraintLessThanOrEqualToAnchor:np.trailingAnchor constant:-14],

                [self.npTitle.leadingAnchor constraintEqualToAnchor:self.npCover.trailingAnchor constant:12],
                [self.npTitle.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-14],
                [self.npTitle.topAnchor constraintEqualToAnchor:self.npStatePill.bottomAnchor constant:6],

                [self.npSub.leadingAnchor constraintEqualToAnchor:self.npCover.trailingAnchor constant:12],
                [self.npSub.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-14],
                [self.npSub.topAnchor constraintEqualToAnchor:self.npTitle.bottomAnchor constant:3],

                [self.npProgressBar.leadingAnchor constraintEqualToAnchor:np.leadingAnchor constant:14],
                [self.npProgressBar.centerYAnchor constraintEqualToAnchor:self.npTimeLabel.centerYAnchor],
                [self.npProgressBar.trailingAnchor constraintEqualToAnchor:self.npTimeLabel.leadingAnchor constant:-8],
                [self.npTimeLabel.trailingAnchor constraintEqualToAnchor:np.trailingAnchor constant:-14],
                [self.npTimeLabel.topAnchor constraintGreaterThanOrEqualToAnchor:self.npCover.bottomAnchor constant:12],
                [self.npTimeLabel.topAnchor constraintGreaterThanOrEqualToAnchor:self.npSub.bottomAnchor constant:10],
                pinTime,

                [self.npToggle.leadingAnchor constraintEqualToAnchor:np.leadingAnchor constant:14],
                [self.npToggle.topAnchor constraintEqualToAnchor:self.npTimeLabel.bottomAnchor constant:12],
                [self.npOpenButton.leadingAnchor constraintEqualToAnchor:self.npToggle.trailingAnchor constant:8],
                [self.npOpenButton.centerYAnchor constraintEqualToAnchor:self.npToggle.centerYAnchor],
                [self.npOpenButton.trailingAnchor constraintLessThanOrEqualToAnchor:np.trailingAnchor constant:-14],
                [self.npToggle.bottomAnchor constraintLessThanOrEqualToAnchor:np.bottomAnchor constant:-14],
                hugBottom,
            ]];
        }
        [NSLayoutConstraint activateConstraints:self.npCardConstraints];
    }

    // 2b) 正在播放 + 队列容器并排/堆叠
    if ((!self.npQueueLayoutInitialized || stacked != self.currentNpStacked ||
         wideRail != self.currentNpWideRail ||
         (stacked && compactNp != self.currentNpQueueCompact)) && self.npQueueRow) {
        [NSLayoutConstraint deactivateConstraints:self.npQueueConstraints];
        [self.npQueueConstraints removeAllObjects];
        self.npQueueLayoutInitialized = YES;
        self.currentNpStacked = stacked;
        self.currentNpWideRail = wideRail;
        self.currentNpQueueCompact = compactNp;

        NSView *row = self.npQueueRow, *np = self.npCard, *qcard = self.queueCard;
        if (!stacked) {
            [self.npQueueConstraints addObjectsFromArray:@[
                [np.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                [np.topAnchor constraintEqualToAnchor:row.topAnchor],
                [np.heightAnchor constraintGreaterThanOrEqualToConstant:236],
                [np.trailingAnchor constraintEqualToAnchor:qcard.leadingAnchor constant:-14],
                [qcard.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                [qcard.topAnchor constraintEqualToAnchor:row.topAnchor],
                [qcard.widthAnchor constraintEqualToConstant:railW],
                [qcard.heightAnchor constraintEqualToAnchor:np.heightAnchor],
                [row.bottomAnchor constraintEqualToAnchor:np.bottomAnchor],
            ]];
        } else {
            [self.npQueueConstraints addObjectsFromArray:@[
                [np.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                [np.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                [np.topAnchor constraintEqualToAnchor:row.topAnchor],
                [np.heightAnchor constraintGreaterThanOrEqualToConstant:compactNp ? 180 : 214],
                [qcard.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                [qcard.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                [qcard.topAnchor constraintEqualToAnchor:np.bottomAnchor constant:12],
                [qcard.heightAnchor constraintGreaterThanOrEqualToConstant:110],
                [row.bottomAnchor constraintEqualToAnchor:qcard.bottomAnchor],
            ]];
        }
        [NSLayoutConstraint activateConstraints:self.npQueueConstraints];
    }

    // 3) 专辑网格动态列数（2 / 3 / 4 / 5 列等宽平铺）
    const NSInteger albCols = (w >= 980.0) ? 5 : ((w >= 720.0) ? 4 : ((w >= 480.0) ? 3 : 2));
    if (albCols != self.currentAlbumColumns && self.albumRow) {
        self.currentAlbumColumns = albCols;
        [self rebuildAlbumGrid];
    }

    // 4) 底部音乐库 + 扩展卡片自适应（>750 并排，右卡与右列同宽对齐）
    if ((!self.libraryLayoutInitialized || stacked != self.currentLibraryStacked || wideRail != self.currentLibraryWideRail) && self.libraryRow) {
        [NSLayoutConstraint deactivateConstraints:self.libraryLayoutConstraints];
        [self.libraryLayoutConstraints removeAllObjects];
        self.libraryLayoutInitialized = YES;
        self.currentLibraryStacked = stacked;
        self.currentLibraryWideRail = wideRail;

        NSView *lrow = self.libraryRow, *lcard = self.libraryCard, *mcard = self.moreCard;
        if (!stacked) {
            [self.libraryLayoutConstraints addObjectsFromArray:@[
                [lcard.leadingAnchor constraintEqualToAnchor:lrow.leadingAnchor],
                [lcard.topAnchor constraintEqualToAnchor:lrow.topAnchor],
                [lcard.trailingAnchor constraintEqualToAnchor:mcard.leadingAnchor constant:-14],
                [mcard.trailingAnchor constraintEqualToAnchor:lrow.trailingAnchor],
                [mcard.topAnchor constraintEqualToAnchor:lrow.topAnchor],
                [mcard.widthAnchor constraintEqualToConstant:railW],
                [mcard.heightAnchor constraintEqualToAnchor:lcard.heightAnchor],
                [lrow.bottomAnchor constraintEqualToAnchor:lcard.bottomAnchor],
            ]];
        } else {
            [self.libraryLayoutConstraints addObjectsFromArray:@[
                [lcard.leadingAnchor constraintEqualToAnchor:lrow.leadingAnchor],
                [lcard.trailingAnchor constraintEqualToAnchor:lrow.trailingAnchor],
                [lcard.topAnchor constraintEqualToAnchor:lrow.topAnchor],
                [mcard.leadingAnchor constraintEqualToAnchor:lrow.leadingAnchor],
                [mcard.trailingAnchor constraintEqualToAnchor:lrow.trailingAnchor],
                [mcard.topAnchor constraintEqualToAnchor:lcard.bottomAnchor constant:12],
                [lrow.bottomAnchor constraintEqualToAnchor:mcard.bottomAnchor],
            ]];
        }
        [NSLayoutConstraint activateConstraints:self.libraryLayoutConstraints];
    }
}

#pragma mark - 卡片式弹层（就地改设置，不跳设置页）

/// 弹层里的一个可选行（标题 + 说明 + 勾选态）。
- (NSButton *)popRowWithTitle:(NSString *)title note:(NSString *)note on:(BOOL)on action:(SEL)action ident:(NSString *)ident {
    RLPTheme *t = [RLPTheme current];
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.bordered = NO;
    b.identifier = ident;
    b.alignment = NSTextAlignmentLeft;
    b.font = [NSFont systemFontOfSize:13 weight:on ? NSFontWeightSemibold : NSFontWeightRegular];
    b.contentTintColor = on ? t.accentText : t.text;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.toolTip = note;
    return b;
}

- (void)showPopoverFrom:(NSView *)anchor withCard:(NSView *)card width:(CGFloat)w minH:(CGFloat)h {
    [self.popover close];
    NSViewController *vc = RLPCardController(card, w, h);
    self.popover = RLPShowCardPopover(anchor, vc, w);
}

/// 弹层内容骨架：标题 + 说明 + 纵向选项容器。
- (NSStackView *)popStackWithTitle:(NSString *)title note:(NSString *)note {
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
        no.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:no];
    }
    return s;
}

#pragma mark 输出弹层

- (void)onOpenOutput:(id)sender {
    (void)sender;
    RLPTheme *t = [RLPTheme current];
    NSString *bk = [self str:@"backend" def:@"coreaudio"];
    NSString *upnpDev = [self str:@"upnpdev" def:@""];
    ++self.castDiscoverSeq;
    self.castDiscoverInflight = NO;
    self.castDiscoverFailed = NO;
    self.castDiscoverError = @"";
    self.outputDraftBackend = bk;
    self.outputDraftUpnpDev = upnpDev;
    const BOOL hog = [self str:@"hogexcl" def:@"1"].boolValue;

    NSStackView *s = [self popStackWithTitle:RLPTr(@"输出方式")
        note:RLPTr(@"独占播放音质最稳；共享播放和其它 App 一起出声。")];
    NSArray *opts = @[
        @[@"coreaudio", RLPTr(@"本机 · 独占播放"), RLPTr(@"独占设备，音质最稳（推荐）")],
        @[@"coreaudio-shared", RLPTr(@"本机 · 共享播放"), RLPTr(@"和其它 App 一起出声，兼容性最好")],
        @[@"upnp", RLPTr(@"投放到局域网设备"), RLPTr(@"投到支持 UPnP/DLNA 的播放器")],
    ];
    NSMutableArray<NSButton *> *bkBtns = [NSMutableArray array];
    for (NSArray *o in opts) {
        NSButton *b = [self popRowWithTitle:o[1] note:o[2] on:[bk isEqualToString:o[0]]
                                     action:@selector(onPickBackend:) ident:o[0]];
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        [bkBtns addObject:b];
        NSTextField *sub = RLPLabel(o[2], t.small, t.mut);
        sub.maximumNumberOfLines = 0;
        sub.lineBreakMode = NSLineBreakByWordWrapping;
        sub.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    self.outputBackendButtons = bkBtns;

    // ---- UPnP 发现与具体设备选择（同一浮层内完成，不嵌套浮层）----
    NSTextField *upnpTitle = RLPLabel(RLPTr(@"局域网投放设备"), t.small, t.mut);
    [s addArrangedSubview:upnpTitle];
    [[upnpTitle.widthAnchor constraintEqualToConstant:330] setActive:YES];

    NSPopUpButton *upnpPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    upnpPopup.identifier = @"output.upnpDevice";
    upnpPopup.font = t.body;
    upnpPopup.target = self;
    upnpPopup.action = @selector(onUpnpDevicePopupChanged:);
    upnpPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:upnpPopup];
    [[upnpPopup.widthAnchor constraintEqualToConstant:330] setActive:YES];
    self.outputUpnpPopup = upnpPopup;

    NSStackView *upnpActions = [[NSStackView alloc] init];
    upnpActions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    upnpActions.spacing = 8;
    upnpActions.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *scanBtn = [NSButton buttonWithTitle:RLPTr(@"发现网络播放器") target:self action:@selector(onScanUpnpDevices:)];
    scanBtn.identifier = @"output.upnpScan";
    scanBtn.bezelStyle = NSBezelStyleRounded;
    NSButton *applyBtn = [NSButton buttonWithTitle:RLPTr(@"应用投放设备") target:self action:@selector(onApplyUpnpOutput:)];
    applyBtn.identifier = @"output.upnpApply";
    applyBtn.bezelStyle = NSBezelStyleRounded;
    [upnpActions addArrangedSubview:scanBtn];
    [upnpActions addArrangedSubview:applyBtn];
    [s addArrangedSubview:upnpActions];
    self.outputUpnpScanButton = scanBtn;
    self.outputUpnpApplyButton = applyBtn;

    NSTextField *upnpStatus = RLPLabel(@"", t.small, t.mut);
    upnpStatus.identifier = @"output.upnpStatus";
    upnpStatus.maximumNumberOfLines = 0;
    upnpStatus.lineBreakMode = NSLineBreakByWordWrapping;
    upnpStatus.preferredMaxLayoutWidth = 330;
    [s addArrangedSubview:upnpStatus];
    [[upnpStatus.widthAnchor constraintEqualToConstant:330] setActive:YES];
    self.outputUpnpStatusLabel = upnpStatus;

    // 严格独占：副作用必须如实写清（macOS Hog 机制限制，实测确认）
    NSButton *hogBtn = [NSButton checkboxWithTitle:RLPTr(@"严格独占（抢 Hog Mode）") target:self action:@selector(onToggleHog:)];
    hogBtn.identifier = @"output.hogexcl";
    hogBtn.state = hog ? NSControlStateValueOn : NSControlStateValueOff;
    hogBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:hogBtn];
    self.outputHogCheck = hogBtn;

    NSTextField *hogNote = RLPLabel(RLPTr(@"开启后系统音量条与音量键会失效，只能用本程序的音量条；它不能阻止其它 App 播放。"),
        t.small, t.warn);
    hogNote.maximumNumberOfLines = 0;
    hogNote.lineBreakMode = NSLineBreakByWordWrapping;
    hogNote.preferredMaxLayoutWidth = 330;
    [s addArrangedSubview:hogNote];
    [[hogNote.widthAnchor constraintEqualToConstant:330] setActive:YES];

    [self syncOutputPopoverState];
    [self showPopoverFrom:self.outputCard withCard:s width:360 minH:370];
    if ([bk isEqualToString:@"upnp"] && [RLPCoreClient shared].started && !self.castDevices.count) {
        [self discoverCastDevicesForce:NO];
    }
}

- (void)syncOutputPopoverState {
    RLPTheme *t = [RLPTheme current];
    NSString *bk = self.outputDraftBackend.length ? self.outputDraftBackend : [self str:@"backend" def:@"coreaudio"];
    for (NSButton *b in self.outputBackendButtons) {
        const BOOL on = [b.identifier isEqualToString:bk];
        b.font = [NSFont systemFontOfSize:13 weight:on ? NSFontWeightSemibold : NSFontWeightRegular];
        b.contentTintColor = on ? t.accentText : t.text;
    }
    if (self.outputHogCheck) {
        self.outputHogCheck.enabled = [bk isEqualToString:@"coreaudio"];
    }
    if (self.outputUpnpScanButton) {
        self.outputUpnpScanButton.enabled = !self.castDiscoverInflight;
    }
    if (self.outputUpnpStatusLabel) {
        if (self.castDiscoverInflight) {
            self.outputUpnpStatusLabel.textColor = t.mut;
            self.outputUpnpStatusLabel.stringValue = RLPTr(@"正在发现网络播放器…");
        } else if (self.castDiscoverFailed && self.castDiscoverError.length) {
            self.outputUpnpStatusLabel.textColor = t.warn;
            self.outputUpnpStatusLabel.stringValue = self.castDiscoverError;
        }
    }
    NSPopUpButton *pop = self.outputUpnpPopup;
    if (pop) {
        [pop removeAllItems];
        NSString *wanted = self.outputDraftUpnpDev ?: @"";
        NSInteger selectIdx = -1;
        for (NSUInteger i = 0; i < self.castDevices.count; ++i) {
            NSDictionary<NSString *, NSString *> *d = self.castDevices[i];
            NSString *name = d[@"name"].length ? d[@"name"] : RLPTr(@"网络播放器");
            NSString *devId = d[@"id"] ?: @"";
            [pop addItemWithTitle:name];
            [[pop lastItem] setRepresentedObject:devId];
            if (wanted.length && [devId isEqualToString:wanted]) {
                selectIdx = (NSInteger)i;
            }
        }
        if (selectIdx < 0 && wanted.length) {
            [pop addItemWithTitle:wanted];
            [[pop lastItem] setRepresentedObject:wanted];
            selectIdx = pop.numberOfItems - 1;
        }
        if (pop.numberOfItems == 0) {
            [pop addItemWithTitle:RLPTr(@"（尚未发现设备）")];
            [[pop lastItem] setRepresentedObject:@""];
            pop.enabled = NO;
        } else {
            pop.enabled = (!self.castDiscoverInflight && !self.castDiscoverFailed && self.castDevices.count > 0);
            if (selectIdx < 0) selectIdx = 0;
            [pop selectItemAtIndex:selectIdx];
            NSString *picked = [pop.selectedItem.representedObject isKindOfClass:[NSString class]]
                ? pop.selectedItem.representedObject : @"";
            if (!self.outputDraftUpnpDev.length && picked.length && self.castDevices.count > 0) {
                self.outputDraftUpnpDev = picked;
            }
        }
    }
    if (self.outputUpnpApplyButton) {
        NSString *picked = [self.outputUpnpPopup.selectedItem.representedObject isKindOfClass:[NSString class]]
            ? self.outputUpnpPopup.selectedItem.representedObject : @"";
        BOOL pickedLive = NO;
        if (picked.length > 0) {
            for (NSDictionary<NSString *, NSString *> *d in self.castDevices) {
                if ([d[@"id"] isEqualToString:picked]) {
                    pickedLive = YES;
                    break;
                }
            }
        }
        self.outputUpnpApplyButton.enabled = (!self.castDiscoverInflight &&
                                              !self.castDiscoverFailed &&
                                              pickedLive);
    }
}

- (void)applyCastDevicesPayload:(NSDictionary * _Nullable)json {
    RLPTheme *t = [RLPTheme current];
    ++self.castDiscoverSeq;
    self.castDiscoverInflight = NO;
    if (self.outputUpnpScanButton) self.outputUpnpScanButton.enabled = YES;
    NSDictionary *dict = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    const BOOL ok = dict &&
                    [dict[@"ok"] respondsToSelector:@selector(boolValue)] &&
                    [dict[@"ok"] boolValue];
    NSString *confirmed = [self str:@"upnpdev" def:@""] ?: @"";
    if (!ok) {
        NSString *rawErr = [dict[@"error"] isKindOfClass:[NSString class]] ? dict[@"error"] : @"";
        if (!rawErr.length && [dict[@"message"] isKindOfClass:[NSString class]]) {
            rawErr = dict[@"message"];
        }
        const BOOL timedOut = [dict[@"timeout"] respondsToSelector:@selector(boolValue)] &&
                              [dict[@"timeout"] boolValue];
        NSString *err = rawErr.length
            ? rawErr
            : (timedOut ? RLPTr(@"设备发现超时（/api/cast/devices 无响应）")
                        : RLPTr(@"设备发现失败（/api/cast/devices 无响应）"));
        self.castDevices = @[];
        self.outputDraftUpnpDev = confirmed;
        self.castDiscoverFailed = YES;
        self.castDiscoverError = err;
        if (self.outputUpnpStatusLabel) {
            self.outputUpnpStatusLabel.stringValue = err;
            self.outputUpnpStatusLabel.textColor = t.warn;
        }
        [self syncOutputPopoverState];
        [self syncOutputSummary];
        RLPToast(err);
        return;
    }
    self.castDiscoverFailed = NO;
    self.castDiscoverError = @"";
    self.castDevices = RLPNormalizeCastDevices(dict[@"devices"]);
    BOOL draftLive = NO;
    if (self.outputDraftUpnpDev.length) {
        for (NSDictionary<NSString *, NSString *> *d in self.castDevices) {
            if ([d[@"id"] isEqualToString:self.outputDraftUpnpDev]) {
                draftLive = YES;
                break;
            }
        }
    }
    if (self.outputDraftUpnpDev.length && !draftLive && ![self.outputDraftUpnpDev isEqualToString:confirmed]) {
        self.outputDraftUpnpDev = confirmed;
    }
    if (!self.outputDraftUpnpDev.length && self.castDevices.count) {
        self.outputDraftUpnpDev = self.castDevices.firstObject[@"id"] ?: @"";
    }
    if (self.outputUpnpStatusLabel) {
        self.outputUpnpStatusLabel.textColor = t.mut;
        if (self.castDevices.count) {
            self.outputUpnpStatusLabel.stringValue = [NSString stringWithFormat:RLPTr(@"共发现 %lu 台设备"),
                (unsigned long)self.castDevices.count];
        } else {
            NSString *hint = [dict[@"hint"] isKindOfClass:[NSString class]] ? dict[@"hint"] : @"";
            self.outputUpnpStatusLabel.stringValue = hint.length ? hint
                : RLPTr(@"暂未发现网络播放器，请确认它已开启并连接同一网络。");
        }
    }
    [self syncOutputPopoverState];
    [self syncOutputSummary];
}

- (void)discoverCastDevicesForce:(BOOL)force {
    if (![RLPCoreClient shared].started) return;
    const NSUInteger seq = ++self.castDiscoverSeq;
    self.castDiscoverInflight = YES;
    self.castDiscoverFailed = NO;
    self.castDiscoverError = @"";
    self.castDevices = @[];
    [self syncOutputPopoverState];
    NSString *url = force ? @"/api/cast/devices?scan=1" : @"/api/cast/devices";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.castDiscoverSeq) return;
        [self_ applyCastDevicesPayload:json];
    }];
    const NSTimeInterval timeoutSec = self.castDiscoverTimeout > 0.0 ? self.castDiscoverTimeout : 12.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * (double)NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.castDiscoverSeq || !self_.castDiscoverInflight) return;
        [self_ applyCastDevicesPayload:@{
            @"ok": @NO,
            @"timeout": @YES,
            @"error": RLPTr(@"设备发现超时（/api/cast/devices 无响应）"),
        }];
    });
}

- (void)onScanUpnpDevices:(id)sender {
    (void)sender;
    [self discoverCastDevicesForce:YES];
}

- (void)onUpnpDevicePopupChanged:(NSPopUpButton *)sender {
    NSString *devId = [sender.selectedItem.representedObject isKindOfClass:[NSString class]]
        ? sender.selectedItem.representedObject : @"";
    self.outputDraftUpnpDev = devId;
    [self syncOutputPopoverState];
}

- (void)onApplyUpnpOutput:(id)sender {
    (void)sender;
    if (self.castDiscoverInflight || self.castDiscoverFailed ||
        (self.outputUpnpApplyButton && !self.outputUpnpApplyButton.enabled)) {
        NSString *err = self.castDiscoverError.length
            ? self.castDiscoverError : RLPTr(@"请先发现并选择可用的网络播放器");
        RLPToast(err);
        return;
    }
    NSString *devId = self.outputDraftUpnpDev.length ? self.outputDraftUpnpDev
        : ([self.outputUpnpPopup.selectedItem.representedObject isKindOfClass:[NSString class]]
           ? self.outputUpnpPopup.selectedItem.representedObject : @"");
    BOOL devLive = NO;
    if (devId.length) {
        for (NSDictionary<NSString *, NSString *> *d in self.castDevices) {
            if ([d[@"id"] isEqualToString:devId]) {
                devLive = YES;
                break;
            }
        }
    }
    if (!devId.length || !devLive) {
        RLPToast(RLPTr(@"请先选择网络播放器"));
        return;
    }
    ++self.castDiscoverSeq;
    self.castDiscoverInflight = NO;
    [self postSettings:RLPOutputSettingsPatchForBackend(@"upnp", devId, self.localDevice)];
    [self.popover close];
}

- (void)onPickBackend:(NSButton *)sender {
    NSString *bk = sender.identifier;
    if (!bk.length) return;
    if ([bk isEqualToString:@"upnp"]) {
        self.outputDraftBackend = @"upnp";
        [self syncOutputPopoverState];
        if (!self.castDevices.count && !self.castDiscoverInflight && [RLPCoreClient shared].started) {
            [self discoverCastDevicesForce:NO];
        }
        return;
    }
    ++self.castDiscoverSeq;
    self.castDiscoverInflight = NO;
    [self postSettings:RLPOutputSettingsPatchForBackend(bk, nil, self.localDevice)];
    [self.popover close];
}

- (void)onToggleHog:(NSButton *)sender {
    [self postSettings:@{@"hogexcl": (sender.state == NSControlStateValueOn ? @"1" : @"0")}];
}

#pragma mark 播放弹层（三档）

- (void)onOpenPlay:(id)sender {
    (void)sender;
    const BOOL isDsd = RLPPathIsDsd(self.currentPath);
    const BOOL active = [self playbackIsActive];
    NSString *popNote = active
        ? RLPTr(@"当前正在播放或暂停：切换播放方式只保存设置，将于下一首或重新播放时生效（不会中断当前播放）。")
        : RLPTr(@"不确定就选「原音直通」：文件是什么就播什么。");
    NSStackView *s = [self popStackWithTitle:RLPTr(@"播放方式") note:popNote];
    NSDictionary<NSString *, NSDictionary *> *statuses =
        [[self class] presetStatusForCapsJSON:self.presetCapsJSON
                                     settings:self.settings
                                      playing:self.playing
                                       paused:self.pausedNow];
    NSString *curProf = RLPPlayModeFromSettings(self.settings);
    NSArray *opts = @[
        @[@0, @"bitperfect", RLPTr(@"原音直通"), RLPTr(@"文件是什么就播什么，不做任何加工")],
        @[@1, @"pcm",        RLPTr(@"PCM 升频"), RLPTr(@"把普通高清音源提升到设备支持的更高采样率")],
        @[@2, isDsd ? @"dsd" : @"pcm2dsd", RLPTr(@"DSD 升频"), RLPTr(@"转换成 DSD 信号输出，声音更绵密（需要设备支持 DoP）")],
    ];
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    for (NSArray *o in opts) {
        NSString *pkey = o[1];
        NSDictionary *st = statuses[pkey];
        const BOOL enabled = [st[@"enabled"] boolValue];
        NSString *reason = [st[@"reason"] isKindOfClass:[NSString class]] ? st[@"reason"] : @"";
        NSString *result = [st[@"result"] isKindOfClass:[NSString class]] ? st[@"result"] : @"";
        const BOOL isCurrent = ([curProf isEqualToString:pkey] ||
                                ([pkey isEqualToString:@"pcm2dsd"] && [curProf isEqualToString:@"dsd"]));
        NSButton *b = [self popRowWithTitle:o[2] note:o[3] on:isCurrent action:@selector(onPickPlayMode:) ident:[o[0] stringValue]];
        b.enabled = enabled;
        if (!enabled && reason.length) {
            b.toolTip = reason;
            if (![reasons containsObject:reason]) [reasons addObject:reason];
        }
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        NSString *subText = enabled ? (result.length ? result : o[3])
                                    : (reason.length ? [NSString stringWithFormat:@"%@ · %@", o[3], reason] : o[3]);
        NSTextField *sub = RLPLabel(subText, [RLPTheme current].small,
                                    enabled ? [RLPTheme current].mut : [RLPTheme current].warn);
        sub.maximumNumberOfLines = 0;
        sub.lineBreakMode = NSLineBreakByWordWrapping;
        sub.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    if (reasons.count) {
        NSTextField *gate = RLPLabel([reasons componentsJoinedByString:@" "],
                                     [RLPTheme current].small, [RLPTheme current].mut2);
        gate.identifier = @"quickstart.presetGate";
        gate.maximumNumberOfLines = 0;
        gate.lineBreakMode = NSLineBreakByWordWrapping;
        gate.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:gate];
        [[gate.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    NSTextField *dsdNote = RLPLabel(isDsd
        ? RLPTr(@"当前是 DSD 文件：DSD 升频会走 DSD→DSD。")
        : RLPTr(@"播放 DSD 文件时，DSD 升频会自动改用 DSD→DSD。"),
        [RLPTheme current].small, [RLPTheme current].mut);
    dsdNote.maximumNumberOfLines = 0;
    dsdNote.lineBreakMode = NSLineBreakByWordWrapping;
    dsdNote.preferredMaxLayoutWidth = 330;
    [s addArrangedSubview:dsdNote];
    [[dsdNote.widthAnchor constraintEqualToConstant:330] setActive:YES];

    NSButton *retryCaps = [NSButton buttonWithTitle:RLPTr(@"重新读取设备能力") target:self action:@selector(onRetryCaps:)];
    retryCaps.bezelStyle = NSBezelStyleRounded;
    retryCaps.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:retryCaps];

    [self showPopoverFrom:self.playCard withCard:s width:360 minH:290];
}

- (void)onRetryCaps:(id)sender {
    (void)sender;
    [self loadPresetCaps:YES];
    RLPToast(RLPTr(@"正在重新读取设备能力…"));
    [self.popover close];
}

/// 是否正在播放或暂停（上游 S.playing || S.paused）。
- (BOOL)playbackIsActive {
    return self.playing || self.pausedNow;
}

+ (NSDictionary<NSString *, NSString *> *)playModeFeedbackForNotes:(NSArray * _Nullable)notes
                                                  playbackActive:(BOOL)active {
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    if ([notes isKindOfClass:[NSArray class]]) {
        for (id item in notes) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length]) {
                [clean addObject:(NSString *)item];
            }
        }
    }
    NSString *joined = clean.count ? [clean componentsJoinedByString:@"；"] : @"";
    if (active) {
        NSString *prefix = RLPTr(@"已保存设置，将在下一首或重新播放时生效");
        NSString *banner = joined.length ? [NSString stringWithFormat:@"%@ · %@", prefix, joined] : prefix;
        return @{ @"toast": prefix, @"notes": banner };
    }
    return @{
        @"toast": RLPTr(@"已应用"),
        @"notes": joined.length ? joined : RLPTr(@"已应用"),
    };
}

- (void)onPickPlayMode:(NSButton *)sender {
    const RLPPlayMode3 mode = (RLPPlayMode3)sender.identifier.integerValue;
    NSString *profile = RLPProfileForPlayMode(mode, RLPPathIsDsd(self.currentPath));
    const BOOL active = [self playbackIsActive];
    [self.popover close];
    self.playValue.stringValue = (mode == RLPPlayMode3Direct ? RLPTr(@"原音直通")
                                 : mode == RLPPlayMode3Pcm ? RLPTr(@"PCM 升频") : RLPTr(@"DSD 升频"));
    self.hasCustomPresetNote = YES;
    self.presetNotes.stringValue = active
        ? RLPTr(@"正在保存设置（下一首或重新播放时生效）…")
        : RLPTr(@"正在应用…");
    NSString *path = [NSString stringWithFormat:@"/api/preset/apply?profile=%@", RLPEnc(profile)];
    const NSUInteger writeSeq = ++self.settingsWriteSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:path body:nil completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || writeSeq != self_.settingsWriteSeq) return;
        if (json && [json[@"ok"] boolValue]) {
            NSArray *notes = [json[@"notes"] isKindOfClass:[NSArray class]] ? json[@"notes"] : @[];
            const BOOL deferred = active || [self_ playbackIsActive];
            NSDictionary<NSString *, NSString *> *fb =
                [[self_ class] playModeFeedbackForNotes:notes playbackActive:deferred];
            self_.presetNotes.stringValue = fb[@"notes"];
            RLPToast(fb[@"toast"]);
            [self_ reloadSettings];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification
                                                                object:self_];
        } else {
            NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [(NSString *)json[@"error"] length])
                ? json[@"error"] : RLPTr(@"应用失败");
            self_.presetNotes.stringValue = err;
            RLPToast(err);
            [self_ syncPlayAndStyleCards];
        }
    }];
}

#pragma mark 听音风格弹层

- (void)onOpenStyle:(id)sender {
    (void)sender;
    const BOOL straight = [RLPPlayModeFromSettings(self.settings) isEqualToString:@"bitperfect"];
    NSStackView *s = [self popStackWithTitle:RLPTr(@"听音风格")
        note:RLPTr(@"不用懂滤波：往温和走声音更柔顺，往锐利走更清亮。")];
    if (straight) {
        NSTextField *bpNote = RLPLabel(
            RLPTr(@"当前保持原音直通，听音风格暂不可用（不偷偷破坏直通）。如需调整听音风格，请先在「播放」中选择 PCM 升频或 DSD 升频。"),
            [RLPTheme current].small, [RLPTheme current].warn);
        bpNote.identifier = @"quickstart.styleBitperfectNote";
        bpNote.maximumNumberOfLines = 0;
        bpNote.lineBreakMode = NSLineBreakByWordWrapping;
        bpNote.preferredMaxLayoutWidth = 330;
        [s addArrangedSubview:bpNote];
        [[bpNote.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    if (!self.filters.count) {
        NSTextField *na = RLPLabel(RLPTr(@"滤波列表读取失败，请稍后重试"), [RLPTheme current].small, [RLPTheme current].warn);
        [s addArrangedSubview:na];
        [[na.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    NSString *curFilter = [self str:@"filter" def:@""];
    for (NSInteger i = RLPToneStyleSharp; i <= RLPToneStyleWarm; ++i) {
        NSString *name = RLPFilterForToneStyle((RLPToneStyle)i, self.filters);
        NSButton *b = [self popRowWithTitle:RLPToneStyleName((RLPToneStyle)i) note:name ?: @""
                                          on:(!straight && [curFilter isEqualToString:name ?: @""])
                                      action:@selector(onPickStyle:) ident:[@(i) stringValue]];
        b.enabled = !straight && (name.length > 0);
        [s addArrangedSubview:b];
        [[b.widthAnchor constraintEqualToConstant:330] setActive:YES];
        NSTextField *sub = RLPLabel(name ?: RLPTr(@"无可用滤波"), [RLPTheme current].small, [RLPTheme current].mut);
        [s addArrangedSubview:sub];
        [[sub.widthAnchor constraintEqualToConstant:330] setActive:YES];
    }
    [self showPopoverFrom:self.styleCard withCard:s width:360 minH:straight ? 270 : 230];
}

- (void)onPickStyle:(NSButton *)sender {
    if ([RLPPlayModeFromSettings(self.settings) isEqualToString:@"bitperfect"]) {
        RLPToast(RLPTr(@"原音直通模式下听音风格不可用"));
        [self.popover close];
        return;
    }
    const RLPToneStyle st = (RLPToneStyle)sender.identifier.integerValue;
    NSDictionary<NSString *, NSString *> *patch = RLPSettingsPatchForToneStyle(st, self.filters);
    if (!patch.count) { RLPToast(RLPTr(@"没有可用滤波")); return; }
    [self postSettings:patch];
    [self.popover close];
}

#pragma mark 音乐文件夹弹层

- (void)onOpenFolders:(id)sender {
    (void)sender;
    RLPTheme *t = [RLPTheme current];
    NSStackView *s = [self popStackWithTitle:RLPTr(@"音乐文件夹")
        note:RLPTr(@"选择保存音乐的文件夹，添加后会自动整理歌曲。")];
    NSStackView *listStack = [[NSStackView alloc] init];
    listStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    listStack.alignment = NSLayoutAttributeLeading;
    listStack.spacing = 6;
    listStack.translatesAutoresizingMaskIntoConstraints = NO;
    [s addArrangedSubview:listStack];
    [[listStack.widthAnchor constraintEqualToConstant:360] setActive:YES];

    NSTextField *loading = RLPLabel(RLPTr(@"正在读取音乐文件夹…"), t.small, t.mut);
    [listStack addArrangedSubview:loading];

    NSStackView *actions = [[NSStackView alloc] init];
    actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actions.spacing = 8;
    NSButton *addBtn = [NSButton buttonWithTitle:RLPTr(@"添加文件夹…") target:self action:@selector(onFoldersAdd:)];
    addBtn.bezelStyle = NSBezelStyleRounded;
    NSButton *scanBtn = [NSButton buttonWithTitle:RLPTr(@"刷新音乐库") target:self action:@selector(onFoldersScan:)];
    scanBtn.bezelStyle = NSBezelStyleRounded;
    [actions addArrangedSubview:addBtn];
    [actions addArrangedSubview:scanBtn];
    [s addArrangedSubview:actions];

    NSTextField *statsLabel = RLPLabel(@"", t.small, t.mut);
    statsLabel.maximumNumberOfLines = 2;
    statsLabel.lineBreakMode = NSLineBreakByWordWrapping;
    statsLabel.preferredMaxLayoutWidth = 360;
    [s addArrangedSubview:statsLabel];
    [[statsLabel.widthAnchor constraintEqualToConstant:360] setActive:YES];

    NSTextField *keepNote = RLPLabel(RLPTr(@"移除只会更改音乐库列表，音乐文件会保留。"), t.small, t.mut2);
    keepNote.maximumNumberOfLines = 0;
    keepNote.lineBreakMode = NSLineBreakByWordWrapping;
    keepNote.preferredMaxLayoutWidth = 360;
    [s addArrangedSubview:keepNote];
    [[keepNote.widthAnchor constraintEqualToConstant:360] setActive:YES];

    [self showPopoverFrom:(self.foldersButton ?: self.libButton) withCard:s width:392 minH:230];

    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/stats" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        for (NSView *v in [listStack.arrangedSubviews copy]) {
            [listStack removeArrangedSubview:v];
            [v removeFromSuperview];
        }
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        if (!roots.count) {
            NSTextField *empty = RLPLabel(RLPTr(@"还没有添加音乐文件夹。"), t.small, t.mut);
            [listStack addArrangedSubview:empty];
        } else {
            for (id r in roots) {
                if (![r isKindOfClass:[NSString class]] || ![(NSString *)r length]) continue;
                NSString *path = (NSString *)r;
                NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
                row.translatesAutoresizingMaskIntoConstraints = NO;
                NSTextField *pl = RLPLabel(path, t.small, t.text);
                pl.lineBreakMode = NSLineBreakByTruncatingMiddle;
                pl.translatesAutoresizingMaskIntoConstraints = NO;
                NSButton *rm = [NSButton buttonWithTitle:RLPTr(@"移除") target:self_ action:@selector(onFoldersRemove:)];
                rm.identifier = path;
                rm.bezelStyle = NSBezelStyleRounded;
                rm.translatesAutoresizingMaskIntoConstraints = NO;
                [row addSubview:pl];
                [row addSubview:rm];
                [listStack addArrangedSubview:row];
                [NSLayoutConstraint activateConstraints:@[
                    [row.widthAnchor constraintEqualToConstant:360],
                    [row.heightAnchor constraintEqualToConstant:26],
                    [pl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                    [pl.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
                    [pl.trailingAnchor constraintLessThanOrEqualToAnchor:rm.leadingAnchor constant:-8],
                    [rm.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
                    [rm.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
                ]];
            }
        }
        const BOOL scanning = [json[@"scanning"] boolValue];
        const NSInteger tracks = [json[@"tracks"] integerValue];
        statsLabel.stringValue = scanning
            ? [NSString stringWithFormat:RLPTr(@"正在整理音乐：%ld / %ld"),
               (long)[json[@"scanned"] integerValue], (long)[json[@"total"] integerValue]]
            : [NSString stringWithFormat:RLPTr(@"音乐库共有 %ld 首曲目"), (long)tracks];
    }];
}

- (void)onFoldersAdd:(id)sender {
    (void)sender;
    [self.popover close];
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.allowsMultipleSelection = NO;
    p.prompt = RLPTr(@"选择");
    p.message = RLPTr(@"选择存放音乐的目录");
    __weak __typeof__(self) weakSelf = self;
    [p beginWithCompletionHandler:^(NSInteger result) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || result != NSModalResponseOK) return;
        NSString *path = p.URL.path;
        if (!path.length) return;
        [[RLPCoreClient shared] postJSON:@"/api/lib/roots"
                                    body:[NSString stringWithFormat:@"add=%@", RLPEnc(path)]
                              completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) s2 = weakSelf;
            if (!s2) return;
            if (json && [json[@"ok"] boolValue]) {
                RLPPostJSON(@"/api/lib/scan?full=1", nil);
                RLPToast(RLPTr(@"已添加目录，开始扫描"));
                [s2 reloadLibrary];
                [s2 reloadAlbums];
            } else {
                NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"添加失败");
                RLPToast(err);
            }
        }];
    }];
}

- (void)onFoldersRemove:(NSButton *)sender {
    NSString *path = sender.identifier;
    if (!path.length) return;
    [self.popover close];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/lib/roots"
                                body:[NSString stringWithFormat:@"remove=%@", RLPEnc(path)]
                          completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPPostJSON(@"/api/lib/scan", nil);
            RLPToast(RLPTr(@"已移除目录"));
            [self_ reloadLibrary];
            [self_ reloadAlbums];
        } else {
            NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"移除失败");
            RLPToast(err);
        }
    }];
}

- (void)onFoldersScan:(id)sender {
    (void)sender;
    [self.popover close];
    RLPPostJSON(@"/api/lib/scan?full=1", nil);
    RLPToast(RLPTr(@"已开始全量重扫"));
}

#pragma mark 更多入口（功能不删，且不放「设置」按钮）

- (void)onOpenMore:(id)sender {
    (void)sender;
    NSStackView *s = [self popStackWithTitle:RLPTr(@"更多")
        note:RLPTr(@"流媒体在这里挂载；AI 资料与音频输入在左侧「设置」里调整。")];
    NSButton *stream = [self popRowWithTitle:RLPTr(@"挂载流媒体服务") note:RLPTr(@"打开流媒体页") on:NO
                                       action:@selector(onOpenStreaming:) ident:@"more.stream"];
    [s addArrangedSubview:stream];
    [[stream.widthAnchor constraintEqualToConstant:330] setActive:YES];
    NSTextField *ro = RLPLabel(RLPTr(@"AI 资料补全与音频输入采集：在左侧「设置」里调整。"),
        [RLPTheme current].small, [RLPTheme current].mut);
    ro.maximumNumberOfLines = 0;
    ro.lineBreakMode = NSLineBreakByWordWrapping;
    ro.preferredMaxLayoutWidth = 330;
    [s addArrangedSubview:ro];
    [[ro.widthAnchor constraintEqualToConstant:330] setActive:YES];
    [self showPopoverFrom:(self.moreButton ?: self.libButton) withCard:s width:360 minH:150];
}

#pragma mark - 动作

- (NSString *)str:(NSString *)key def:(NSString *)def {
    id v = self.settings[key];
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return def;
}

/// 写设置：一次 POST 多个键，然后读回校验（不维护第二套状态）。
- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv {
    if (!kv.count) return;
    const NSUInteger writeSeq = ++self.settingsWriteSeq;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in kv) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLPEnc(kv[k])]];
    NSString *body = [parts componentsJoinedByString:@"&"];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] postJSON:@"/api/settings" body:body completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || writeSeq != self_.settingsWriteSeq) return;
        if (json && [json[@"ok"] boolValue]) {
            RLPToast(RLPTr(@"已生效"));
            [self_ reloadSettings];
            [[NSNotificationCenter defaultCenter] postNotificationName:RLPSettingsChangedNotification
                                                                object:self_];
        } else {
            NSString *err = ([json[@"error"] isKindOfClass:[NSString class]] && [(NSString *)json[@"error"] length])
                ? json[@"error"] : RLPTr(@"保存失败");
            [self_ syncDeviceSelection];
            [self_ syncOutputSummary];
            [self_ syncPlayAndStyleCards];
            if (self_.outputHogCheck) {
                self_.outputHogCheck.state = [self_ str:@"hogexcl" def:@"0"].boolValue
                    ? NSControlStateValueOn : NSControlStateValueOff;
            }
            RLPToast(err);
        }
    }];
}

- (void)onDeviceChanged:(NSPopUpButton *)sender {
    const NSInteger idx = sender.indexOfSelectedItem;
    if (idx < 0) return;
    NSString *devId = @"";
    if (idx > 0 && (idx - 1) < (NSInteger)self.devices.count) {
        NSDictionary *d = self.devices[idx - 1];
        devId = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : @"";
    }
    [self postSettings:@{@"device": devId}];
}

- (void)onReloadDevices:(id)sender {
    (void)sender;
    [self reloadDevices];
    RLPToast(RLPTr(@"已重新检测设备"));
}

- (void)onTogglePlay:(id)sender {
    (void)sender;
    ++self.statusEpoch;
    self.statusInflight = NO; // Empty-queue no-op has no completion callback.
    RLPPlaybackToggle(self.playing, self.pausedNow, self.currentPath);
}

- (void)onOpenCurrentAlbum:(id)sender {
    (void)sender;
    if (!self.currentPath.length) {
        RLPToast(RLPTr(@"还没有在播放的音乐"));
        return;
    }
    NSDictionary *meta = [self.lastMetaDict isKindOfClass:[NSDictionary class]] ? self.lastMetaDict : nil;
    NSString *directKey = nil;
    for (NSString *kName in @[@"albumKey", @"album_key", @"albumK"]) {
        id v = meta[kName];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
            directKey = (NSString *)v;
            break;
        }
    }
    if (directKey.length) {
        RLPRequestOpenAlbum(directKey);
        return;
    }

    NSString *albumName = [meta[@"album"] isKindOfClass:[NSString class]] ? meta[@"album"] : @"";
    NSString *artistName = [meta[@"albumArtist"] isKindOfClass:[NSString class]] ? meta[@"albumArtist"] : @"";
    if (!artistName.length && [meta[@"artist"] isKindOfClass:[NSString class]]) artistName = meta[@"artist"];

    if (!albumName.length && [self.lastQueueJSON isKindOfClass:[NSDictionary class]]) {
        NSArray *qItems = [self.lastQueueJSON[@"items"] isKindOfClass:[NSArray class]] ? self.lastQueueJSON[@"items"] : nil;
        NSArray *qMetas = [self.lastQueueJSON[@"metas"] isKindOfClass:[NSArray class]] ? self.lastQueueJSON[@"metas"] : nil;
        NSInteger idx = [self.lastQueueJSON[@"index"] respondsToSelector:@selector(integerValue)]
            ? [self.lastQueueJSON[@"index"] integerValue] : -1;
        if (idx >= 0 && qMetas && (NSUInteger)idx < qMetas.count &&
            (!qItems || ((NSUInteger)idx < qItems.count && [qItems[(NSUInteger)idx] isEqual:self.currentPath]))) {
            NSDictionary *qm = [qMetas[(NSUInteger)idx] isKindOfClass:[NSDictionary class]] ? qMetas[(NSUInteger)idx] : nil;
            if ([qm[@"al"] isKindOfClass:[NSString class]]) albumName = qm[@"al"];
            if (!artistName.length && [qm[@"a"] isKindOfClass:[NSString class]]) artistName = qm[@"a"];
        }
    }

    if (albumName.length && self.albumsData.count) {
        RLPAlbum *hit = nil;
        for (RLPAlbum *a in self.albumsData) {
            if (!a.key.length || ![a.name isEqualToString:albumName]) continue;
            if (!artistName.length || !a.artist.length || [a.artist isEqualToString:artistName]) {
                hit = a;
                break;
            }
        }
        if (!hit) {
            for (RLPAlbum *a in self.albumsData) {
                if (a.key.length && [a.name isEqualToString:albumName]) {
                    hit = a;
                    break;
                }
            }
        }
        if (hit.key.length) {
            RLPRequestOpenAlbum(hit.key);
            return;
        }
    }

    if (!albumName.length) {
        RLPToast(RLPTr(@"未找到当前曲目的所属专辑"));
        return;
    }

    NSString *targetPath = [self.currentPath copy];
    NSString *targetAlbum = [albumName copy];
    NSString *targetArtist = [artistName copy];
    NSString *url = [NSString stringWithFormat:@"/api/lib/albums?q=%@", RLPEnc(targetAlbum)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![targetPath isEqualToString:self_.currentPath ?: @""]) return;
        NSArray *list = [json[@"albums"] isKindOfClass:[NSArray class]] ? json[@"albums"]
            : ([json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[]);
        NSDictionary *hit = nil;
        for (NSDictionary *d in list) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSString *nm = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"]
                : ([d[@"album"] isKindOfClass:[NSString class]] ? d[@"album"] : @"");
            if (![nm isEqualToString:targetAlbum]) continue;
            NSString *ar = [d[@"artist"] isKindOfClass:[NSString class]] ? d[@"artist"] : @"";
            if (!targetArtist.length || !ar.length || [ar isEqualToString:targetArtist]) {
                hit = d;
                break;
            }
        }
        if (!hit) {
            for (NSDictionary *d in list) {
                if (![d isKindOfClass:[NSDictionary class]]) continue;
                NSString *nm = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"]
                    : ([d[@"album"] isKindOfClass:[NSString class]] ? d[@"album"] : @"");
                if ([nm isEqualToString:targetAlbum]) {
                    hit = d;
                    break;
                }
            }
        }
        NSString *key = [hit[@"k"] isKindOfClass:[NSString class]] ? hit[@"k"]
            : ([hit[@"key"] isKindOfClass:[NSString class]] ? hit[@"key"] : @"");
        if (key.length) {
            RLPRequestOpenAlbum(key);
        } else {
            RLPToast(RLPTr(@"未找到当前曲目的所属专辑"));
        }
    }];
}

- (void)onOpenQueue:(id)sender {
    (void)sender;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"queue"];
}

- (void)onOpenAlbums:(id)sender {
    (void)sender;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"albums"];
}

- (void)onOpenStreaming:(id)sender {
    (void)sender;
    [self.popover close];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPNavigateKeyNotification" object:@"streaming"];
}

- (void)onQueuePreviewClicked:(NSButton *)sender {
    const NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)self.queuePaths.count) {
        [self onOpenQueue:sender];
        return;
    }
    NSString *path = self.queuePaths[(NSUInteger)idx];
    if (!path.length) return;
    double cs = -1.0, ce = -1.0;
    if (idx < (NSInteger)self.queueCues.count) {
        NSArray<NSNumber *> *cue = self.queueCues[(NSUInteger)idx];
        if ([cue isKindOfClass:[NSArray class]] && cue.count >= 2) {
            cs = cue[0].doubleValue;
            ce = cue[1].doubleValue;
        }
    }
    RLPPlayPathCue(path, cs, ce);
}

- (void)onAlbumClicked:(NSButton *)sender {
    RLPRequestOpenAlbum(sender.identifier);
}

- (void)onAlbumPlayClicked:(NSButton *)sender {
    if (sender.identifier.length) RLPPlayAlbum(sender.identifier, 0);
}

/// 音乐库：无目录时就地选目录（NSOpenPanel），已有目录时全量重扫。
- (void)onLibraryAction:(id)sender {
    (void)sender;
    if (self.hasRoots) {
        RLPPostJSON(@"/api/lib/scan?full=1", nil);
        RLPToast(RLPTr(@"已开始全量重扫"));
        return;
    }
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.allowsMultipleSelection = NO;
    p.prompt = RLPTr(@"选择");
    p.message = RLPTr(@"选择存放音乐的目录");
    __weak __typeof__(self) weakSelf = self;
    [p beginWithCompletionHandler:^(NSInteger result) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || result != NSModalResponseOK) return;
        NSString *path = p.URL.path;
        if (!path.length) return;
        [[RLPCoreClient shared] postJSON:@"/api/lib/roots"
            body:[NSString stringWithFormat:@"add=%@", RLPEnc(path)]
            completion:^(NSDictionary * _Nullable json) {
            __typeof__(self) s2 = weakSelf;
            if (!s2) return;
            if (json && [json[@"ok"] boolValue]) {
                RLPPostJSON(@"/api/lib/scan?full=1", nil);
                RLPToast(RLPTr(@"已添加目录，开始扫描"));
                [s2 reloadLibrary];
                [s2 reloadAlbums];
            } else {
                NSString *err = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : RLPTr(@"添加失败");
                RLPToast(err);
            }
        }];
    }];
}

#pragma mark - 数据

- (void)activate {
    [self reloadAll];
    if (!self.poll && [RLPCoreClient shared].started) {
        __weak __typeof__(self) weakSelf = self;
        self.poll = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            (void)t;
            [weakSelf reloadStatusFromTimer];
            [weakSelf reloadQueueFromTimer];
        }];
    }
}

- (void)reloadStatusFromTimer {
    if (self.statusInflight) return;
    [self reloadStatus];
}

- (void)reloadQueueFromTimer {
    if (self.queueInflightSeq != 0 && self.queueInflightSeq == self.queueSeq) return;
    [self reloadQueue];
}

- (void)viewDidDisappear {
    [self.popover close];
    self.popover = nil;
    [self.poll invalidate];
    self.poll = nil;
    ++self.statusEpoch;
    self.statusInflight = NO;
    ++self.queueSeq;
    self.queueInflightSeq = 0;
    ++self.castDiscoverSeq;
    self.castDiscoverInflight = NO;
    [super viewDidDisappear];
}

- (void)reloadData { [self reloadAll]; }

- (void)reloadAll {
    if (![RLPCoreClient shared].started) { [self setSubtitle:RLPTr(@"核心未启动")]; return; }
    [self reloadDevices];
    [self reloadSettings];
    [self reloadFilters];
    [self reloadPresetCaps:NO];
    [self reloadLibrary];
    [self reloadStatus];
    [self reloadQueue];
    [self reloadAlbums];
}

- (void)reloadPresetCaps:(BOOL)force {
    [self loadPresetCaps:force];
}

- (void)reloadDevices {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/devices" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.devices = [json[@"devices"] isKindOfClass:[NSArray class]] ? json[@"devices"] : @[];
        [self_.devicePopup removeAllItems];
        [self_.devicePopup addItemWithTitle:RLPTr(@"系统默认")];
        NSString *defName = nil;
        for (NSDictionary *d in self_.devices) {
            NSString *n = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : RLPTr(@"未知设备");
            [self_.devicePopup addItemWithTitle:n];
            if ([d[@"default"] boolValue]) defName = n;
        }
        if (defName.length) {
            [[self_.devicePopup itemAtIndex:0] setTitle:[NSString stringWithFormat:@"%@（%@）", RLPTr(@"系统默认"), defName]];
        }
        self_.defaultDeviceName = defName;
        [self_ syncDeviceSelection];
    }];
}

- (void)syncDeviceSelection {
    NSString *bk = [self str:@"backend" def:@"coreaudio"];
    NSString *cur = ([bk isEqualToString:@"upnp"] || [bk isEqualToString:@"null"])
        ? (self.localDevice ?: @"")
        : [self str:@"device" def:@""];
    NSDictionary *activeDev = nil;
    if (!cur.length || [cur isEqualToString:@"null"]) {
        [self.devicePopup selectItemAtIndex:0];
        for (NSDictionary *d in self.devices) {
            if ([d[@"default"] boolValue]) { activeDev = d; break; }
        }
    } else {
        BOOL matched = NO;
        for (NSInteger i = 0; i < (NSInteger)self.devices.count; ++i) {
            if ([self.devices[i][@"id"] isEqualToString:cur]) {
                [self.devicePopup selectItemAtIndex:i + 1];
                activeDev = self.devices[(NSUInteger)i];
                matched = YES;
                break;
            }
        }
        if (!matched) [self.devicePopup selectItemAtIndex:0];
    }
    [self syncDeviceSubWithDevice:activeDev];
}

- (void)syncDeviceSubWithDevice:(NSDictionary * _Nullable)d {
    if (!self.deviceSub) return;
    if (!d) {
        self.deviceSub.stringValue = self.devices.count ? RLPTr(@"默认设备") : RLPTr(@"检测中…");
        return;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    const NSInteger ch = [d[@"channels"] respondsToSelector:@selector(integerValue)] ? [d[@"channels"] integerValue] : 0;
    const NSInteger rate = [d[@"mixRate"] respondsToSelector:@selector(integerValue)] ? [d[@"mixRate"] integerValue] : 0;
    const NSInteger bits = [d[@"mixBits"] respondsToSelector:@selector(integerValue)] ? [d[@"mixBits"] integerValue] : 0;
    NSString *transport = [d[@"transport"] isKindOfClass:[NSString class]] ? d[@"transport"] : @"";
    NSString *dsd = [d[@"dsd"] isKindOfClass:[NSString class]] ? d[@"dsd"] : @"";
    if (ch > 0) [parts addObject:[NSString stringWithFormat:@"%ld %@", (long)ch, RLPTr(@"声道")]];
    if (rate > 0) {
        NSString *rStr = (rate % 1000 == 0)
            ? [NSString stringWithFormat:@"%ld kHz", (long)(rate / 1000)]
            : [NSString stringWithFormat:@"%.1f kHz", rate / 1000.0];
        [parts addObject:rStr];
    }
    if (bits > 0) [parts addObject:[NSString stringWithFormat:@"%ld bit", (long)bits]];
    if ([transport isEqualToString:@"airplay"]) [parts addObject:@"AirPlay"];
    else if ([dsd isEqualToString:@"native"]) [parts addObject:@"DSD Native"];
    else if ([dsd isEqualToString:@"dop"]) [parts addObject:@"DoP"];
    self.deviceSub.stringValue = parts.count ? [parts componentsJoinedByString:@" · "] : RLPTr(@"默认设备");
}

- (void)reloadSettings {
    const NSUInteger seq = ++self.settingsSeq;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/settings" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.settingsSeq) return;
        self_.settings = [json[@"kv"] isKindOfClass:[NSDictionary class]] ? json[@"kv"] : @{};
        self_.localDevice = RLPRememberedLocalDevice(self_.settings, self_.localDevice);
        [self_ syncDeviceSelection];
        NSString *bk = [self_ str:@"backend" def:@"coreaudio"];
        NSString *dev = [self_ str:@"device" def:@""];
        NSString *capsKey = [NSString stringWithFormat:@"%@|%@", bk, dev];
        if (![capsKey isEqualToString:self_.presetCapsKey ?: @""]) {
            self_.presetCapsKey = capsKey;
            [self_ loadPresetCaps:YES];
        }
        [self_ syncOutputSummary];
        [self_ syncPlayAndStyleCards];
        [self_ syncCapabilitiesUI];
    }];
}

- (void)syncOutputSummary {
    NSString *bk = [self str:@"backend" def:@"coreaudio"];
    if ([bk isEqualToString:@"upnp"]) {
        NSString *upnpDev = [self str:@"upnpdev" def:@""];
        NSString *devLabel = nil;
        for (NSDictionary<NSString *, NSString *> *d in self.castDevices) {
            if ([d[@"id"] isEqualToString:upnpDev]) { devLabel = d[@"name"]; break; }
        }
        if (!devLabel.length && upnpDev.length) devLabel = upnpDev;
        self.outputValue.stringValue = devLabel.length
            ? [NSString stringWithFormat:@"%@ · %@", RLPTr(@"局域网投放"), devLabel]
            : RLPTr(@"局域网投放");
        self.outputSub.stringValue = RLPTr(@"投到支持 UPnP/DLNA 的播放器");
        return;
    }
    NSString *bkName = [bk isEqualToString:@"coreaudio-shared"] ? RLPTr(@"共享播放")
                     : [bk isEqualToString:@"null"] ? RLPTr(@"不出声（仅分析）") : RLPTr(@"独占播放");
    const BOOL hog = [self str:@"hogexcl" def:@"1"].boolValue;
    const BOOL hogFallback = (self.lastFallbackWhy.length > 0) ||
                             (self.lastHogAcquired != nil && !self.lastHogAcquired.boolValue);
    NSString *hogSuffix = ([bk isEqualToString:@"coreaudio"] && hog)
        ? (hogFallback ? RLPTr(@" · Hog（已回退）") : @" · Hog")
        : @"";
    self.outputValue.stringValue = [NSString stringWithFormat:@"%@%@", bkName, hogSuffix];

    if ([bk isEqualToString:@"coreaudio-shared"]) {
        self.outputSub.stringValue = RLPTr(@"系统混音（共享）");
    } else if ([bk isEqualToString:@"null"]) {
        self.outputSub.stringValue = RLPTr(@"不出声（仅分析）");
    } else if (self.lastFallbackWhy.length) {
        self.outputSub.stringValue = self.lastFallbackWhy;
    } else {
        self.outputSub.stringValue = hog ? RLPTr(@"硬件直通（独占）") : RLPTr(@"CoreAudio（硬件直通）");
    }
}

- (void)syncPlayAndStyleCards {
    NSString *prof = RLPPlayModeFromSettings(self.settings);
    NSDictionary *dev = [self.presetCapsJSON[@"device"] isKindOfClass:[NSDictionary class]]
        ? self.presetCapsJSON[@"device"] : nil;
    if ([prof isEqualToString:@"bitperfect"]) {
        self.playValue.stringValue = RLPTr(@"原音直通");
        self.playSub.stringValue = RLPTr(@"文件是什么就播什么，不做任何加工");
        self.styleValue.stringValue = RLPTr(@"保持原音");
        self.styleSub.stringValue = RLPTr(@"原音直通时听音风格不参与");
        self.styleCard.alphaValue = 0.65;
    } else {
        self.styleCard.alphaValue = 1.0;
        if ([prof isEqualToString:@"pcm"]) {
            self.playValue.stringValue = RLPTr(@"PCM 升频");
            NSString *rateSet = [self str:@"rate" def:@""];
            double maxRate = [dev[@"maxRate"] respondsToSelector:@selector(doubleValue)]
                ? [dev[@"maxRate"] doubleValue] : 0.0;
            if ([rateSet isEqualToString:@"max"] && maxRate > 0) {
                double capped = maxRate > 384000.0 ? 384000.0 : maxRate;
                self.playSub.stringValue = [NSString stringWithFormat:@"%.1f kHz", capped / 1000.0];
            } else if (rateSet.doubleValue > 0) {
                self.playSub.stringValue = [NSString stringWithFormat:@"%.1f kHz", rateSet.doubleValue / 1000.0];
            } else {
                self.playSub.stringValue = RLPTr(@"按设备能力匹配 PCM 升频规格");
            }
        } else if ([prof isEqualToString:@"dsd"] || [prof isEqualToString:@"pcm2dsd"]) {
            self.playValue.stringValue = RLPTr(@"DSD 升频");
            NSString *dsdVal = [self str:@"dsd" def:@""];
            NSString *dopMax = [dev[@"dopMax"] isKindOfClass:[NSString class]] ? dev[@"dopMax"] : @"";
            NSString *shaper = [self str:@"shaper" def:@""];
            NSString *rateTag = dsdVal.length ? dsdVal.uppercaseString
                              : (dopMax.length ? dopMax.uppercaseString : RLPTr(@"支持 DoP 输出"));
            self.playSub.stringValue = shaper.length
                ? [NSString stringWithFormat:@"%@ · %@", rateTag, shaper]
                : rateTag;
        } else {
            self.playValue.stringValue = RLPTr(@"自定义播放方式");
            NSString *rateSet = [self str:@"rate" def:@""];
            self.playSub.stringValue = rateSet.length ? rateSet : RLPTr(@"自定义");
        }
        NSString *f = [self str:@"filter" def:@""];
        NSInteger st = RLPToneStyleForFilter(f, self.filters);
        self.styleValue.stringValue = (st >= 0) ? RLPToneStyleName((RLPToneStyle)st) : RLPTr(@"自定义");
        self.styleSub.stringValue = f.length ? f : RLPTr(@"跟随默认");
    }
}

- (void)reloadFilters {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/filters" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.filters = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
        [self_ syncPlayAndStyleCards];
    }];
}

- (void)reloadLibrary {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/roots" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSArray *roots = [json[@"roots"] isKindOfClass:[NSArray class]] ? json[@"roots"] : @[];
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        for (id r in roots) {
            if ([r isKindOfClass:[NSString class]] && [(NSString *)r length]) [clean addObject:(NSString *)r];
        }
        self_.lastRoots = clean;
        self_.hasLoadedLibrary = YES;
        self_.hasRoots = clean.count > 0;
        [self_ syncLibrarySummaryUI];
        if (!self_.albumsData.count && self_.albumEmptyCard) {
            [self_ syncAlbumEmptyCardCopy];
        }
    }];
}

- (void)syncLibrarySummaryUI {
    self.libTitleLabel.stringValue = RLPTr(@"本地音乐库");
    if (self.hasLoadedLibrary) {
        self.libDesc.stringValue = self.hasRoots
            ? RLPTr(@"音乐目录已就绪 · 可重新扫描更新专辑与封面")
            : RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE");
        [self.libButton setTitle:self.hasRoots ? RLPTr(@"重新扫描音乐库") : RLPTr(@"添加音乐目录")];
        if (self.lastRoots.count == 1) {
            self.libRootLabel.stringValue = self.lastRoots.firstObject;
        } else if (self.lastRoots.count > 1) {
            self.libRootLabel.stringValue = [NSString stringWithFormat:@"%@ (+%lu)",
                self.lastRoots.firstObject, (unsigned long)(self.lastRoots.count - 1)];
        } else {
            self.libRootLabel.stringValue = RLPTr(@"还没有添加音乐目录");
        }
    } else {
        self.libDesc.stringValue = RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE");
        self.libRootLabel.stringValue = RLPTr(@"读取中…");
        [self.libButton setTitle:RLPTr(@"添加音乐目录")];
    }
}

- (void)applyStatusJSON:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return;
    self.lastHogAcquired = [json[@"hogAcquired"] respondsToSelector:@selector(boolValue)]
        ? @([json[@"hogAcquired"] boolValue]) : nil;
    self.lastFallbackWhy = [json[@"fallbackWhy"] isKindOfClass:[NSString class]] ? json[@"fallbackWhy"] : @"";
    [self syncOutputSummary];
    RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
    if (!st) return;

    NSDictionary *prevStatus = self.lastStatus;
    NSString *prevPath = self.currentPath ?: @"";
    const BOOL wasActive = self.playing || self.pausedNow;

    self.hasLoadedStatus = YES;
    self.playing = st.playing && !st.paused;
    self.pausedNow = st.paused;
    self.npLastPos = st.position;
    self.npLastDur = st.duration;
    self.npBitPerfect = st.bitPerfect ?: @"";
    self.npGpuUsed = st.gpuUsed;
    self.npOutRate = st.outRate;
    self.npOutBits = st.outBits;
    self.lastStatus = json;

    NSString *path = RLPRoomStatusPath(json, st);
    const BOOL isActive = self.playing || self.pausedNow;
    const BOOL pathChanged = ![path isEqualToString:prevPath];
    const BOOL statusHintChanged = RLPRoomStatusQueueHintChanged(prevStatus, json);
    const BOOL activeChanged = (prevStatus != nil) && (wasActive != isActive);
    NSString *curQueuePath = (self.queueCurrentIndex >= 0 && self.queueCurrentIndex < (NSInteger)self.queuePaths.count)
        ? self.queuePaths[(NSUInteger)self.queueCurrentIndex] : @"";
    const BOOL pathMismatchWithQueue = (path.length > 0 && self.lastQueueJSON != nil &&
                                        prevStatus == nil && ![path isEqualToString:curQueuePath]);

    [self syncNowPlayingStateAndProgressForPath:path];
    if (pathChanged) {
        self.currentPath = path;
        self.lastMetaDict = nil;
        self.npTitle.stringValue = path.length ? path.lastPathComponent.stringByDeletingPathExtension : RLPTr(@"还没有在播放的音乐");
        self.npSub.stringValue = path.length ? RLPTr(@"读取中…") : RLPTr(@"从下面的专辑挑一张开始");
        [self loadCoverForPath:path];
        [self loadMetaForPath:path];
    }
    [self syncNowPlayingSpec];

    // 状态变化/切歌后同步重拉 /api/queue?meta=1 并重建聆听室 queueList，
    // 以 /api/queue 的 current/cur/index 为准（不凭曲目路径在旧缓存里猜）。
    if ([RLPCoreClient shared].started &&
        (pathChanged || statusHintChanged || activeChanged ||
         pathMismatchWithQueue || (!self.lastQueueJSON && path.length > 0))) {
        [self reloadQueue];
    }
}

- (void)syncNowPlayingStateAndProgressForPath:(NSString *)path {
    RLPTheme *t = [RLPTheme current];
    const BOOL activePlaying = path.length > 0 && self.playing;
    [self.npToggle setTitle:activePlaying ? RLPTr(@"暂停") : RLPTr(@"继续播放")];
    self.npToggle.image = [NSImage imageWithSystemSymbolName:(activePlaying ? @"pause.fill" : @"play.fill")
                                      accessibilityDescription:self.npToggle.title];
    self.npState.stringValue = path.length ? (activePlaying ? RLPTr(@"正在播放") : RLPTr(@"已暂停")) : RLPTr(@"未播放");
    self.npState.tag = activePlaying ? 4 : 1;
    self.npState.textColor = activePlaying ? t.accentText : t.mut;
    if (self.npStatePill) {
        self.npStatePill.layer.backgroundColor = (activePlaying ? t.accentWeak : t.bg3).CGColor;
        self.npStatePill.layer.borderColor = (activePlaying ? t.accent : t.line).CGColor;
    }

    if (self.npLastDur > 0) {
        self.npTimeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@",
            RLPFmtDuration(self.npLastPos), RLPFmtDuration(self.npLastDur)];
        self.npProgressBar.progress = self.npLastPos / self.npLastDur;
    } else if (path.length) {
        self.npTimeLabel.stringValue = RLPFmtDuration(self.npLastPos);
        self.npProgressBar.progress = 0.0;
    } else {
        self.npTimeLabel.stringValue = @"0:00 / 0:00";
        self.npProgressBar.progress = 0.0;
    }
}

- (void)syncNowPlayingSpec {
    if (!self.currentPath.length) {
        self.npFormatLabel.stringValue = @"";
        self.npFormatPill.hidden = YES;
        return;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *codec = [self.lastMetaDict[@"codec"] isKindOfClass:[NSString class]] ? self.lastMetaDict[@"codec"] : @"";
    if (codec.length) [parts addObject:codec.uppercaseString];

    const double sr = self.npOutRate > 0 ? self.npOutRate
        : ([self.lastMetaDict[@"sampleRate"] respondsToSelector:@selector(doubleValue)] ? [self.lastMetaDict[@"sampleRate"] doubleValue] : 0.0);
    const NSInteger bits = self.npOutBits > 0 ? self.npOutBits
        : ([self.lastMetaDict[@"bits"] respondsToSelector:@selector(integerValue)] ? [self.lastMetaDict[@"bits"] integerValue] : 0);
    if (sr > 0) {
        NSString *rText = (std::fmod(sr, 1000.0) == 0.0)
            ? [NSString stringWithFormat:@"%ldk", (long)(sr / 1000.0)]
            : [NSString stringWithFormat:@"%.1fk", sr / 1000.0];
        [parts addObject:(bits > 0 ? [NSString stringWithFormat:@"%@/%ld", rText, (long)bits] : rText)];
    }
    if ([self.npBitPerfect isEqualToString:@"direct"] || [self.npBitPerfect isEqualToString:@"1"] || [self.npBitPerfect isEqualToString:@"true"]) {
        [parts addObject:RLPTr(@"逐位无损")];
    }
    if (self.npGpuUsed) [parts addObject:@"GPU"];

    self.npFormatLabel.stringValue = [parts componentsJoinedByString:@" · "];
    self.npFormatPill.hidden = (parts.count == 0);
}

- (void)reloadStatus {
    const NSUInteger seq = ++self.statusEpoch;
    self.statusInflight = YES;
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (seq == self_.statusEpoch) self_.statusInflight = NO;
        if (seq != self_.statusEpoch) return;
        [self_ applyStatusJSON:json ?: @{}];
    }];
}

/// 无封面时用居中音符占位（避免 RLPCoverImageView 把小符号拉伸撑满）。
- (void)showCoverPlaceholder {
    self.npCover.image = nil;
    self.npPlaceholder.hidden = NO;
}

- (void)loadCoverForPath:(NSString *)path {
    if (!path.length) { [self showCoverPlaceholder]; return; }
    const NSUInteger seq = ++self.coverSeq;
    NSString *url = [NSString stringWithFormat:@"/api/cover?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:url completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.coverSeq) return;
        if (data.length) {
            NSImage *img = [[NSImage alloc] initWithData:data];
            if (img) {
                self_.npCover.image = img;
                self_.npPlaceholder.hidden = YES;
                return;
            }
        }
        [self_ showCoverPlaceholder];
    }];
}

- (void)loadMetaForPath:(NSString *)path {
    if (!path.length) return;
    NSString *url = [NSString stringWithFormat:@"/api/meta?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || ![path isEqualToString:self_.currentPath ?: @""]) return;
        self_.lastMetaDict = [json isKindOfClass:[NSDictionary class]] ? json : nil;
        [self_ applyMetaToNowPlaying];
    }];
}

- (void)applyMetaToNowPlaying {
    if (!self.currentPath.length) {
        self.npTitle.stringValue = RLPTr(@"还没有在播放的音乐");
        self.npSub.stringValue = RLPTr(@"从下面的专辑挑一张开始");
        [self syncNowPlayingSpec];
        return;
    }
    NSDictionary *json = self.lastMetaDict;
    if (!json) return;
    NSString *title = [json[@"title"] isKindOfClass:[NSString class]] ? json[@"title"] : @"";
    NSString *artist = [json[@"artist"] isKindOfClass:[NSString class]] ? json[@"artist"] : @"";
    NSString *album = [json[@"album"] isKindOfClass:[NSString class]] ? json[@"album"] : @"";
    NSInteger year = [json[@"year"] respondsToSelector:@selector(integerValue)] ? [json[@"year"] integerValue] : 0;
    if (title.length) self.npTitle.stringValue = title;
    NSMutableArray *p = [NSMutableArray array];
    if (artist.length) [p addObject:artist];
    if (album.length) [p addObject:album];
    if (year > 0) [p addObject:[NSString stringWithFormat:@"%ld", (long)year]];
    self.npSub.stringValue = p.count ? [p componentsJoinedByString:@" · "] : @"";
    [self syncNowPlayingSpec];
}

#pragma mark 队列预览（最多 4 行，无嵌套滚动）

- (void)reloadQueue {
    const NSUInteger seq = ++self.queueSeq;
    self.queueInflightSeq = seq;
    // TODO(debug): remove before commit
    __weak __typeof__(self) weakSelf = self;
    // 队列契约：GET /api/queue?meta=1 → {items:[路径…], cues:[[cs,ce]…], metas:[{t,a,al,d}…], index/current/cur}
    [[RLPCoreClient shared] getJSON:@"/api/queue?meta=1" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (seq == self_.queueInflightSeq) self_.queueInflightSeq = 0;
        if (seq != self_.queueSeq) return;
        if (![json isKindOfClass:[NSDictionary class]]) return;
        if (json[@"ok"] && [json[@"ok"] respondsToSelector:@selector(boolValue)] && ![json[@"ok"] boolValue]) return;
        if (self_.lastQueueJSON && [self_.lastQueueJSON isEqualToDictionary:json] &&
            self_.queueList.arrangedSubviews.count > 0) {
            NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
            const BOOL emptyMatches = (items.count == 0) == (self_.queueEmptyLabel != nil);
            const NSInteger resolvedIdx = items.count ? RLPRoomResolveQueueCurrentIndex(json, self_.queuePaths) : -1;
            if (emptyMatches && resolvedIdx == self_.queueCurrentIndex) {
                return;
            }
        }
        self_.lastQueueJSON = json;
        [self_ renderQueueFromJSON:self_.lastQueueJSON];
    }];
}

- (void)renderQueueEmptyState {
    RLPTheme *t = [RLPTheme current];
    self.queuePaths = @[];
    self.queueCues = @[];
    self.queueCurrentIndex = -1;
    // TODO(debug): remove before commit
    for (NSView *v in [self.queueList.arrangedSubviews copy]) {
        [self.queueList removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.queueDynamicLabels removeAllObjects];
    [self.queueRowSurfaces removeAllObjects];
    [self.queueRowCurrentFlags removeAllObjects];

    self.queueCountLabel.stringValue = @"0";
    NSView *box = [[NSView alloc] initWithFrame:NSZeroRect];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.wantsLayer = YES;
    box.layer.cornerRadius = t.rSm;
    box.layer.backgroundColor = t.bg3.CGColor;
    box.layer.borderWidth = 1.0;
    box.layer.borderColor = t.line.CGColor;
    [self.queueRowSurfaces addObject:box];
    [self.queueRowCurrentFlags addObject:@NO];

    NSTextField *e = RLPLabel(RLPTr(@"队列是空的"), t.small, t.mut);
    e.tag = 1;
    e.alignment = NSTextAlignmentCenter;
    e.lineBreakMode = NSLineBreakByTruncatingTail;
    e.translatesAutoresizingMaskIntoConstraints = NO;
    [e setContentCompressionResistancePriority:40
                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.queueDynamicLabels addObject:e];
    self.queueEmptyLabel = e;
    [box addSubview:e];
    [self.queueList addArrangedSubview:box];

    [NSLayoutConstraint activateConstraints:@[
        [box.widthAnchor constraintEqualToAnchor:self.queueList.widthAnchor],
        [box.heightAnchor constraintEqualToConstant:44],
        [e.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [e.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        [e.leadingAnchor constraintGreaterThanOrEqualToAnchor:box.leadingAnchor constant:10],
        [e.trailingAnchor constraintLessThanOrEqualToAnchor:box.trailingAnchor constant:-10],
    ]];
}

- (void)renderQueueFromJSON:(NSDictionary * _Nullable)json {
    RLPTheme *t = [RLPTheme current];
    if (json && json != self.lastQueueJSON && [json isKindOfClass:[NSDictionary class]]) {
        self.lastQueueJSON = json;
    } else if (!json) {
        self.lastQueueJSON = nil;
    }
    NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
    NSArray *metas = [json[@"metas"] isKindOfClass:[NSArray class]] ? json[@"metas"] : @[];
    NSArray *cues = [json[@"cues"] isKindOfClass:[NSArray class]] ? json[@"cues"] : @[];

    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:items.count];
    for (id it in items) {
        if ([it isKindOfClass:[NSString class]]) [paths addObject:(NSString *)it];
        else if ([it isKindOfClass:[NSDictionary class]]) {
            NSString *p = [it[@"path"] isKindOfClass:[NSString class]] ? it[@"path"] : ([it[@"file"] isKindOfClass:[NSString class]] ? it[@"file"] : @"");
            [paths addObject:p];
        } else {
            [paths addObject:@""];
        }
    }
    self.queuePaths = paths;
    self.queueCues = cues;

    if (!items.count) {
        [self renderQueueEmptyState];
        return;
    }

    const NSInteger curIdx = RLPRoomResolveQueueCurrentIndex(json, paths);
    self.queueCurrentIndex = curIdx;
    // TODO(debug): remove before commit
     
    for (NSView *v in [self.queueList.arrangedSubviews copy]) {
        [self.queueList removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.queueDynamicLabels removeAllObjects];
    [self.queueRowSurfaces removeAllObjects];
    [self.queueRowCurrentFlags removeAllObjects];
    self.queueEmptyLabel = nil;

    self.queueCountLabel.stringValue = [NSString stringWithFormat:@"%lu%@",
        (unsigned long)items.count, RLPTr(@"首曲目")];

    // 预览起点尽量围绕当前曲目（最多显示 4 行，满足 C5 队列预览 ≤4 行无嵌套滚动）
    NSInteger start = 0;
    if (curIdx > 0 && (NSInteger)items.count > 4) {
        start = MIN(curIdx, (NSInteger)items.count - 4);
    }
    const NSInteger end = MIN((NSInteger)items.count, start + 4);

    for (NSInteger i = start; i < end; ++i) {
        NSDictionary *m = (i < (NSInteger)metas.count && [metas[(NSUInteger)i] isKindOfClass:[NSDictionary class]])
            ? metas[(NSUInteger)i] : nil;
        NSString *name = [m[@"t"] isKindOfClass:[NSString class]] ? m[@"t"] : @"";
        if (!name.length && i < (NSInteger)paths.count) {
            name = paths[(NSUInteger)i].lastPathComponent.stringByDeletingPathExtension;
        }
        NSString *artist = [m[@"a"] isKindOfClass:[NSString class]] ? m[@"a"] : @"";
        const double dur = [m[@"d"] respondsToSelector:@selector(doubleValue)] ? [m[@"d"] doubleValue] : 0.0;
        const BOOL isCurrent = (i == curIdx);

        NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
        row.identifier = [NSString stringWithFormat:@"room.queue.row.%ld", (long)i];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.wantsLayer = YES;
        row.layer.cornerRadius = t.rSm;
        row.layer.backgroundColor = (isCurrent ? t.accentWeak : t.bg3).CGColor;
        row.layer.borderWidth = 1.0;
        row.layer.borderColor = (isCurrent ? t.accent : t.line).CGColor;
        [self.queueRowSurfaces addObject:row];
        [self.queueRowCurrentFlags addObject:@(isCurrent)];

        NSTextField *idxLab = RLPLabel([NSString stringWithFormat:@"%ld", (long)(i + 1)],
                                       t.mono,
                                       isCurrent ? t.accentText : t.mut);
        idxLab.tag = isCurrent ? 4 : 1;
        idxLab.alignment = NSTextAlignmentRight;
        idxLab.translatesAutoresizingMaskIntoConstraints = NO;
        [idxLab setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.queueDynamicLabels addObject:idxLab];

        NSString *titleLine = artist.length
            ? [NSString stringWithFormat:@"%@ · %@", name ?: @"", artist]
            : (name ?: @"");
        NSTextField *titleLab = RLPLabel(titleLine,
                                         [NSFont systemFontOfSize:12 weight:isCurrent ? NSFontWeightSemibold : NSFontWeightRegular],
                                         isCurrent ? t.accentText : t.text);
        titleLab.tag = isCurrent ? 4 : 0;
        titleLab.lineBreakMode = NSLineBreakByTruncatingTail;
        titleLab.translatesAutoresizingMaskIntoConstraints = NO;
        [titleLab setContentCompressionResistancePriority:40
                                           forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.queueDynamicLabels addObject:titleLab];

        NSTextField *durLab = RLPLabel(dur > 0 ? RLPFmtDuration(dur) : @"", t.mono, t.mut);
        durLab.tag = 1;
        durLab.alignment = NSTextAlignmentRight;
        durLab.translatesAutoresizingMaskIntoConstraints = NO;
        [durLab setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [durLab setContentCompressionResistancePriority:40
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.queueDynamicLabels addObject:durLab];

        RLPRoomQueueHitButton *hit = [RLPRoomQueueHitButton buttonWithTitle:@"" target:self action:@selector(onQueuePreviewClicked:)];
        hit.bordered = NO;
        hit.tag = i;
        hit.rowSurface = row;
        hit.isCurrentRow = isCurrent;
        hit.toolTip = i < (NSInteger)paths.count ? paths[(NSUInteger)i] : @"";
        hit.translatesAutoresizingMaskIntoConstraints = NO;

        for (NSView *v in @[idxLab, titleLab, durLab, hit]) [row addSubview:v];
        [self.queueList addArrangedSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.widthAnchor constraintEqualToAnchor:self.queueList.widthAnchor],
            [row.heightAnchor constraintEqualToConstant:36],
            [idxLab.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:8],
            [idxLab.widthAnchor constraintEqualToConstant:22],
            [idxLab.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [titleLab.leadingAnchor constraintEqualToAnchor:idxLab.trailingAnchor constant:8],
            [titleLab.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [titleLab.trailingAnchor constraintLessThanOrEqualToAnchor:durLab.leadingAnchor constant:-8],
            [durLab.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
            [durLab.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [hit.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [hit.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [hit.topAnchor constraintEqualToAnchor:row.topAnchor],
            [hit.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        ]];
    }
}

#pragma mark 专辑网格重排

- (void)reloadAlbums {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/lib/albums" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        self_.albumsData = [RLPAlbum albumsFromJSON:json ?: @{}];
        self_.albumCountLabel.stringValue = [NSString stringWithFormat:@"%lu %@",
            (unsigned long)self_.albumsData.count, RLPTr(@"张专辑")];
        [self_ rebuildAlbumGrid];
    }];
}

- (void)syncAlbumEmptyCardCopy {
    if (!self.albumEmptyLabel || !self.albumEmptyHintLabel || !self.albumEmptyButton) return;
    self.albumEmptyLabel.stringValue = RLPTr(@"还没有专辑 · 先添加音乐目录");
    self.albumEmptyHintLabel.stringValue = self.hasRoots
        ? RLPTr(@"音乐目录已就绪 · 可重新扫描更新专辑与封面")
        : RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE");
    [self.albumEmptyButton setTitle:self.hasRoots ? RLPTr(@"重新扫描音乐库") : RLPTr(@"添加音乐目录")];
}

- (void)rebuildAlbumGrid {
    if (!self.albumRow) return;
    [self.albumRow setContentCompressionResistancePriority:40
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    RLPTheme *t = [RLPTheme current];
    for (NSView *v in [self.albumRow.arrangedSubviews copy]) {
        [self.albumRow removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.albumCardViews removeAllObjects];

    const NSInteger cols = MAX(2, self.currentAlbumColumns);
    const NSInteger limit = MIN((NSInteger)self.albumsData.count, cols * 2);

    if (limit == 0) {
        self.albumCountLabel.stringValue = [NSString stringWithFormat:@"0 %@", RLPTr(@"张专辑")];

        // 移除空态可能残留的旧卡片引用后重建一个自包含空态卡
        NSView *empty = [[NSView alloc] initWithFrame:NSZeroRect];
        empty.identifier = @"room.albumempty";
        empty.wantsLayer = YES;
        empty.layer.cornerRadius = t.rMd;
        empty.layer.backgroundColor = t.bg2.CGColor;
        empty.layer.borderWidth = 1.0;
        empty.layer.borderColor = t.line.CGColor;
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        self.albumEmptyCard = empty;

        NSView *eIcon = [self iconBadgeWithSymbol:@"square.stack.fill" desc:@"专辑" size:32 tracked:NO];
        self.albumEmptyIconBadge = eIcon;
        NSTextField *eTitle = RLPLabel(RLPTr(@"还没有专辑 · 先添加音乐目录"),
                                       [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold], t.text);
        eTitle.tag = 0;
        eTitle.alignment = NSTextAlignmentCenter;
        eTitle.lineBreakMode = NSLineBreakByTruncatingTail;
        eTitle.translatesAutoresizingMaskIntoConstraints = NO;
        [eTitle setContentCompressionResistancePriority:40
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSTextField *eHint = RLPLabel(RLPTr(@"支持 FLAC · DSD (DSF/DFF) · ALAC · WAV · APE"), t.small, t.mut);
        eHint.tag = 1;
        eHint.alignment = NSTextAlignmentCenter;
        eHint.maximumNumberOfLines = 2;
        eHint.lineBreakMode = NSLineBreakByWordWrapping;
        eHint.translatesAutoresizingMaskIntoConstraints = NO;

        RLPRoomActionButton *cta = [RLPRoomActionButton actionButtonWithTitle:RLPTr(@"添加音乐目录")
                                                                       target:self
                                                                       action:@selector(onLibraryAction:)
                                                                 showsChevron:YES
                                                                primaryAccent:NO
                                                                    minHeight:30.0];
        cta.identifier = @"room.albumEmptyAction";
        [cta setChevronIdentifier:@"room.albumEmptyAction.chevron"];

        self.albumEmptyLabel = eTitle;
        self.albumEmptyHintLabel = eHint;
        self.albumEmptyButton = cta;
        [self syncAlbumEmptyCardCopy];

        for (NSView *v in @[eIcon, eTitle, eHint, cta]) [empty addSubview:v];
        [self.albumRow addArrangedSubview:empty];

        [NSLayoutConstraint activateConstraints:@[
            [empty.widthAnchor constraintEqualToAnchor:self.albumRow.widthAnchor],
            [eIcon.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
            [eIcon.topAnchor constraintEqualToAnchor:empty.topAnchor constant:20],
            [eTitle.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
            [eTitle.leadingAnchor constraintGreaterThanOrEqualToAnchor:empty.leadingAnchor constant:16],
            [eTitle.trailingAnchor constraintLessThanOrEqualToAnchor:empty.trailingAnchor constant:-16],
            [eTitle.topAnchor constraintEqualToAnchor:eIcon.bottomAnchor constant:10],
            [eHint.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
            [eHint.leadingAnchor constraintGreaterThanOrEqualToAnchor:empty.leadingAnchor constant:16],
            [eHint.trailingAnchor constraintLessThanOrEqualToAnchor:empty.trailingAnchor constant:-16],
            [eHint.topAnchor constraintEqualToAnchor:eTitle.bottomAnchor constant:4],
            [cta.centerXAnchor constraintEqualToAnchor:empty.centerXAnchor],
            [cta.topAnchor constraintEqualToAnchor:eHint.bottomAnchor constant:12],
            [cta.bottomAnchor constraintEqualToAnchor:empty.bottomAnchor constant:-20],
        ]];
        return;
    }

    self.albumEmptyCard = nil;
    self.albumEmptyIconBadge = nil;
    self.albumEmptyLabel = nil;
    self.albumEmptyHintLabel = nil;
    self.albumEmptyButton = nil;
    self.albumCountLabel.stringValue = [NSString stringWithFormat:@"%lu %@",
        (unsigned long)self.albumsData.count, RLPTr(@"张专辑")];

    for (NSInteger offset = 0; offset < limit; offset += cols) {
        NSStackView *rowStack = [[NSStackView alloc] init];
        rowStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        rowStack.distribution = NSStackViewDistributionFillEqually;
        rowStack.alignment = NSLayoutAttributeTop;
        rowStack.spacing = 12;
        rowStack.translatesAutoresizingMaskIntoConstraints = NO;
        [rowStack setContentCompressionResistancePriority:40
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];

        for (NSInteger c = 0; c < cols; ++c) {
            const NSInteger idx = offset + c;
            if (idx < limit) {
                RLPAlbum *alb = self.albumsData[(NSUInteger)idx];
                RLPRoomAlbumCardView *card = [[RLPRoomAlbumCardView alloc] initWithAlbum:alb
                                                                                   index:idx
                                                                                  target:self
                                                                              openAction:@selector(onAlbumClicked:)
                                                                              playAction:@selector(onAlbumPlayClicked:)];
                [self.albumCardViews addObject:card];
                [rowStack addArrangedSubview:card];
                __weak RLPRoomAlbumCardView *weakCard = card;
                NSString *key = alb.key;
                [[RLPCoverLoader shared] coverForAlbumKey:key completion:^(NSImage * _Nullable image) {
                    if (weakCard && [weakCard.albumKey isEqualToString:key]) {
                        [weakCard updateCover:image];
                    }
                }];
            } else {
                // 不满一行的尾槽补透明占位，保证前几个格宽与上面完整行严格一致。
                NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
                spacer.translatesAutoresizingMaskIntoConstraints = NO;
                [rowStack addArrangedSubview:spacer];
            }
        }
        [self.albumRow addArrangedSubview:rowStack];
        [[rowStack.widthAnchor constraintEqualToAnchor:self.albumRow.widthAnchor] setActive:YES];
    }
}

#pragma mark - 主题

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];

    for (NSView *c in self.cardSurfaces) {
        c.layer.backgroundColor = t.bg2.CGColor;
        c.layer.borderColor = t.line.CGColor;
    }
    for (NSView *s in self.subSurfaces) {
        s.layer.backgroundColor = t.bg3.CGColor;
        s.layer.borderColor = t.line.CGColor;
    }
    for (NSView *b in self.iconBadges) {
        b.layer.backgroundColor = t.accentWeak.CGColor;
        for (NSView *sub in b.subviews) {
            if ([sub isKindOfClass:[NSImageView class]]) {
                ((NSImageView *)sub).contentTintColor = t.accentText;
            }
        }
    }
    for (NSView *d in self.dividerLines) {
        d.layer.backgroundColor = t.line.CGColor;
    }

    self.npCover.layer.backgroundColor = t.cvBg.CGColor;
    self.npCover.layer.borderColor = t.line.CGColor;
    [self.npProgressBar setNeedsDisplay:YES];

    const BOOL activePlaying = self.currentPath.length > 0 && self.playing;
    if (self.npStatePill) {
        self.npStatePill.layer.backgroundColor = (activePlaying ? t.accentWeak : t.bg3).CGColor;
        self.npStatePill.layer.borderColor = (activePlaying ? t.accent : t.line).CGColor;
    }

    for (NSTextField *l in self.dynamicLabels) {
        l.textColor = [self colorForLabelRole:l.tag theme:t];
    }
    for (RLPRoomInteractiveCardView *ic in self.interactiveCards) {
        [ic applyTheme];
    }
    for (RLPRoomActionButton *ab in self.actionButtons) {
        [ab applyTheme];
    }
    if ([self.devicePopup isKindOfClass:[RLPRoomPopUpButton class]]) {
        [(RLPRoomPopUpButton *)self.devicePopup applyTheme];
    }
    if ([self.albumEmptyButton isKindOfClass:[RLPRoomActionButton class]]) {
        [(RLPRoomActionButton *)self.albumEmptyButton applyTheme];
    }
    for (NSTextField *l in self.queueDynamicLabels) {
        l.textColor = [self colorForLabelRole:l.tag theme:t];
    }
    for (NSUInteger i = 0; i < self.queueRowSurfaces.count; ++i) {
        NSView *rv = self.queueRowSurfaces[i];
        const BOOL cur = (i < self.queueRowCurrentFlags.count) && self.queueRowCurrentFlags[i].boolValue;
        rv.layer.backgroundColor = (cur ? t.accentWeak : t.bg3).CGColor;
        rv.layer.borderColor = (cur ? t.accent : t.line).CGColor;
    }

    if (self.albumEmptyCard) {
        self.albumEmptyCard.layer.backgroundColor = t.bg2.CGColor;
        self.albumEmptyCard.layer.borderColor = t.line.CGColor;
    }
    if (self.albumEmptyIconBadge) {
        self.albumEmptyIconBadge.layer.backgroundColor = t.accentWeak.CGColor;
        for (NSView *sub in self.albumEmptyIconBadge.subviews) {
            if ([sub isKindOfClass:[NSImageView class]]) {
                ((NSImageView *)sub).contentTintColor = t.accentText;
            }
        }
    }
    if (self.albumEmptyLabel) self.albumEmptyLabel.textColor = t.text;
    if (self.albumEmptyHintLabel) self.albumEmptyHintLabel.textColor = t.mut;

    for (RLPRoomAlbumCardView *card in self.albumCardViews) {
        [card applyTheme];
    }
}

#pragma mark - 能力探测与纯决策

/// /api/preset/caps：探测本机对官方推荐预设的支持能力（web loadPresetCaps 同源）。
- (void)loadPresetCaps:(BOOL)force {
    if (![RLPCoreClient shared].started) return;
    NSString *url = force ? @"/api/preset/caps?refresh=1" : @"/api/preset/caps";
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        [self_ applyPresetCaps:json];
    }];
}

/// 纯函数：`/api/preset/caps` 响应 → @{known, pcmReady, dsdReady}。
+ (NSDictionary<NSString *, NSNumber *> *)gatingForCapsJSON:(NSDictionary * _Nullable)json {
    const id okv = json[@"ok"];
    const BOOL ok = [okv respondsToSelector:@selector(boolValue)] && [okv boolValue];
    NSDictionary *dev = [json[@"device"] isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
    NSString *backend = [dev[@"backend"] isKindOfClass:[NSString class]] ? dev[@"backend"] : @"";
    NSString *name = [dev[@"name"] isKindOfClass:[NSString class]] ? dev[@"name"] : @"";
    NSArray *rates = [dev[@"rates"] isKindOfClass:[NSArray class]] ? dev[@"rates"] : @[];
    double maxRate = [dev[@"maxRate"] respondsToSelector:@selector(doubleValue)]
                     ? [dev[@"maxRate"] doubleValue] : 0.0;
    const BOOL offline = [backend isEqualToString:@"null"];
    const BOOL remote = [backend isEqualToString:@"upnp"];
    const BOOL shared = [backend isEqualToString:@"wasapi-shared"] || [backend isEqualToString:@"coreaudio-shared"];
    const BOOL known = ok && !offline && !remote && name.length > 0 && rates.count > 0 && maxRate > 0;
    const BOOL dsdNative = [dev[@"dsdNative"] respondsToSelector:@selector(boolValue)] &&
                           [dev[@"dsdNative"] boolValue];
    const BOOL dop = [dev[@"dop"] respondsToSelector:@selector(boolValue)] && [dev[@"dop"] boolValue];
    return @{ @"known": @(known),
              @"pcmReady": @(known && !remote && !shared),
              @"dsdReady": @(known && !remote && !shared && (dsdNative || dop)) };
}

+ (NSDictionary<NSString *, NSDictionary *> *)presetStatusForCapsJSON:(NSDictionary * _Nullable)json
                                                           settings:(NSDictionary * _Nullable)kv
                                                            playing:(BOOL)playing
                                                             paused:(BOOL)paused {
    (void)playing;
    (void)paused;
    NSDictionary<NSString *, NSNumber *> *g = [self gatingForCapsJSON:json];
    const BOOL known = [g[@"known"] boolValue];
    const BOOL pcmReady = [g[@"pcmReady"] boolValue];
    const BOOL dsdReady = [g[@"dsdReady"] boolValue];

    NSDictionary *dev = [json[@"device"] isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
    NSString *capBackend = [dev[@"backend"] isKindOfClass:[NSString class]] ? dev[@"backend"] : @"";
    NSString *kvBackend = [kv[@"backend"] isKindOfClass:[NSString class]] ? kv[@"backend"] : @"";
    NSString *backend = kvBackend.length ? kvBackend : (capBackend.length ? capBackend : @"coreaudio");
    const BOOL isShared = [backend isEqualToString:@"coreaudio-shared"] || [backend isEqualToString:@"wasapi-shared"];
    const BOOL isOffline = [backend isEqualToString:@"null"];
    const BOOL isRemote = [backend isEqualToString:@"upnp"];
    const BOOL isAirPlay = [backend isEqualToString:@"airplay"];

    double maxRate = [dev[@"maxRate"] respondsToSelector:@selector(doubleValue)] ? [dev[@"maxRate"] doubleValue] : 0.0;
    NSString *dopMax = [dev[@"dopMax"] isKindOfClass:[NSString class]] ? dev[@"dopMax"] : @"";
    const BOOL dsdNative = [dev[@"dsdNative"] respondsToSelector:@selector(boolValue)] && [dev[@"dsdNative"] boolValue];

    NSString *pcmWhy = @"";
    if (isShared || isAirPlay) pcmWhy = RLPTr(@"共享/隔空播放不支持升频，请在「输出」中开启独占设备。");
    else if (isOffline) pcmWhy = RLPTr(@"离线处理模式不连接设备，不支持设备升频。");
    else if (isRemote) pcmWhy = RLPTr(@"网络播放器由远端负责输出，不支持本机升频。");
    else if (!known) pcmWhy = RLPTr(@"能力尚未确认，请先选择输出设备。");
    else if (!pcmReady) pcmWhy = RLPTr(@"当前设备不支持 PCM 升频。");

    NSString *dsdWhy = @"";
    if (isShared || isAirPlay) dsdWhy = RLPTr(@"共享/隔空播放不支持 DSD/DoP，请在「输出」中开启独占设备。");
    else if (isOffline) dsdWhy = RLPTr(@"离线处理模式不连接设备，不支持 DSD 升频。");
    else if (isRemote) dsdWhy = RLPTr(@"网络播放器不支持本机 DoP 升频。");
    else if (!known) dsdWhy = RLPTr(@"能力尚未确认，请先选择输出设备。");
    else if (!dsdReady) dsdWhy = RLPTr(@"当前设备不支持 DoP，无法输出 DSD。");

    NSString *pcmResult = (pcmReady && maxRate > 0)
        ? [NSString stringWithFormat:RLPTr(@"目标采样率最高 %.1f kHz（封顶 384 kHz）"),
           (maxRate > 384000.0 ? 384000.0 : maxRate) / 1000.0]
        : RLPTr(@"按设备能力匹配 PCM 升频规格");
    NSString *dsdResult = dsdReady
        ? (dopMax.length
            ? [NSString stringWithFormat:RLPTr(@"DoP 最高 %@"), dopMax.uppercaseString]
            : (dsdNative ? RLPTr(@"支持 DSD 输出") : RLPTr(@"支持 DoP 输出")))
        : RLPTr(@"需要设备支持 DoP");

    NSDictionary *bpEntry = @{
        @"enabled": @YES,
        @"reason": @"",
        @"result": RLPTr(@"保持源采样率与原始声音（禁用 EQ/IR 与听音风格）"),
    };
    NSDictionary *pcmEntry = @{
        @"enabled": @(pcmReady && !isShared && !isOffline && !isRemote && !isAirPlay),
        @"reason": pcmWhy,
        @"result": pcmResult,
    };
    NSDictionary *dsdEntry = @{
        @"enabled": @(dsdReady && !isShared && !isOffline && !isRemote && !isAirPlay),
        @"reason": dsdWhy,
        @"result": dsdResult,
    };
    return @{
        @"bitperfect": bpEntry,
        @"pcm": pcmEntry,
        @"dsd": dsdEntry,
        @"pcm2dsd": dsdEntry,
    };
}

- (void)applyPresetCaps:(NSDictionary * _Nullable)json {
    self.presetCapsJSON = json;
    NSDictionary<NSString *, NSNumber *> *g = [[self class] gatingForCapsJSON:json];
    self.presetCapsKnown = [g[@"known"] boolValue];
    self.presetPcmReady = [g[@"pcmReady"] boolValue];
    self.presetDsdReady = [g[@"dsdReady"] boolValue];
    NSDictionary *dev = [json[@"device"] isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
    self.presetCapsDevice = [dev[@"name"] isKindOfClass:[NSString class]] ? dev[@"name"] : nil;
    [self syncCapabilitiesUI];
    [self syncPlayAndStyleCards];
}

- (void)syncCapabilitiesUI {
    RLPTheme *t = [RLPTheme current];
    NSDictionary *dev = [self.presetCapsJSON[@"device"] isKindOfClass:[NSDictionary class]]
        ? self.presetCapsJSON[@"device"] : nil;
    NSDictionary<NSString *, NSDictionary *> *statuses =
        [[self class] presetStatusForCapsJSON:self.presetCapsJSON
                                     settings:self.settings
                                      playing:self.playing
                                       paused:self.pausedNow];
    const BOOL pcmEnabled = [statuses[@"pcm"][@"enabled"] boolValue];
    const BOOL dsdEnabled = [statuses[@"dsd"][@"enabled"] boolValue];

    NSString *name = [dev[@"name"] isKindOfClass:[NSString class]] && [dev[@"name"] length]
        ? dev[@"name"] : (self.defaultDeviceName.length ? self.defaultDeviceName : RLPTr(@"检测中…"));
    double maxRate = [dev[@"maxRate"] respondsToSelector:@selector(doubleValue)] ? [dev[@"maxRate"] doubleValue] : 0.0;
    NSString *maxRateStr = maxRate > 0 ? [NSString stringWithFormat:@"%ld Hz", (long)maxRate] : @"—";
    NSString *dsdStr = @"—";
    if ([dev[@"dsdNative"] respondsToSelector:@selector(boolValue)]) {
        if ([dev[@"dsdNative"] boolValue]) {
            NSString *nmax = [dev[@"dsdNativeMax"] isKindOfClass:[NSString class]] && [dev[@"dsdNativeMax"] length]
                ? dev[@"dsdNativeMax"] : @"dsd256";
            dsdStr = [NSString stringWithFormat:@"%@ (%@)", RLPTr(@"是"), nmax.uppercaseString];
        } else if ([dev[@"dop"] respondsToSelector:@selector(boolValue)] && [dev[@"dop"] boolValue]) {
            NSString *dmax = [dev[@"dopMax"] isKindOfClass:[NSString class]] && [dev[@"dopMax"] length]
                ? dev[@"dopMax"] : @"DoP";
            dsdStr = [NSString stringWithFormat:@"%@ · DoP %@", RLPTr(@"否"), dmax.uppercaseString];
        } else {
            dsdStr = RLPTr(@"否");
        }
    }
    self.capsInfoLabel.stringValue = [NSString stringWithFormat:@"%@%@ · %@ %@ · %@ %@",
        RLPTr(@"当前设备："), name, RLPTr(@"最高"), maxRateStr, RLPTr(@"DSD 原生"), dsdStr];

    if (pcmEnabled && maxRate > 0) {
        double capped = maxRate > 384000.0 ? 384000.0 : maxRate;
        self.capsPcmBadge.stringValue = [NSString stringWithFormat:@"PCM %.1fk", capped / 1000.0];
    } else {
        self.capsPcmBadge.stringValue = pcmEnabled ? RLPTr(@"PCM 升频") : @"PCM —";
    }
    self.capsPcmBadge.tag = pcmEnabled ? 4 : 1;
    self.capsPcmBadge.textColor = pcmEnabled ? t.accentText : t.mut;

    NSString *dopMax = [dev[@"dopMax"] isKindOfClass:[NSString class]] ? dev[@"dopMax"] : @"";
    self.capsDsdBadge.stringValue = dsdEnabled
        ? (dopMax.length ? dopMax.uppercaseString : @"DoP / DSD")
        : @"DSD —";
    self.capsDsdBadge.tag = dsdEnabled ? 4 : 1;
    self.capsDsdBadge.textColor = dsdEnabled ? t.accentText : t.mut;
}

#pragma mark - 多语言原地切换

- (void)applyLanguage {
    self.pageTitle = RLPTr(@"聆听室");
    if (!self.isViewLoaded) return;
    if (self.popover.isShown) {
        [self.popover close];
        ++self.castDiscoverSeq;
        self.castDiscoverInflight = NO;
    }

    self.headerTitle.stringValue = RLPTr(@"聆听室");
    self.headerSubtitle.stringValue = RLPTr(@"安静听歌，常用设置就在卡片里");
    self.foldersButton.title = RLPTr(@"音乐文件夹");
    self.foldersButton.toolTip = RLPTr(@"管理本地音乐文件夹");

    self.deviceCaption.stringValue = RLPTr(@"当前设备");
    self.devRefreshButton.toolTip = RLPTr(@"重新检测设备");
    self.devicePopup.toolTip = RLPTr(@"点击切换播放设备");
    if (self.devicePopup.numberOfItems > 0) {
        NSString *defTitle = self.defaultDeviceName.length
            ? [NSString stringWithFormat:@"%@（%@）", RLPTr(@"系统默认"), self.defaultDeviceName]
            : RLPTr(@"系统默认");
        [self.devicePopup itemAtIndex:0].title = defTitle;
        [self.devicePopup synchronizeTitleAndSelectedItem];
        [self.devicePopup setNeedsDisplay:YES];
    }

    self.outputCaption.stringValue = RLPTr(@"输出");
    self.outCardButton.toolTip = RLPTr(@"点击选择输出方式");
    self.playCaption.stringValue = RLPTr(@"播放");
    self.playCardButton.toolTip = RLPTr(@"点击选择播放方式");
    self.styleCaption.stringValue = RLPTr(@"听音风格");
    self.styleCardButton.toolTip = RLPTr(@"点击选择听感风格");
    self.capsTitleLabel.stringValue = RLPTr(@"官方推荐预设");
    if (!self.hasCustomPresetNote) {
        self.presetNotes.stringValue = RLPTr(@"不确定就选「原音直通」：文件是什么就播什么。");
    }

    if (self.settings) {
        [self syncDeviceSelection];
        [self syncOutputSummary];
        [self syncPlayAndStyleCards];
    } else {
        [self syncDeviceSubWithDevice:nil];
        self.outputValue.stringValue = RLPTr(@"读取中…");
        self.outputSub.stringValue = RLPTr(@"点击选择输出方式");
        self.playValue.stringValue = RLPTr(@"原音直通");
        self.playSub.stringValue = RLPTr(@"文件是什么就播什么，不做任何加工");
        self.styleValue.stringValue = RLPTr(@"均衡自然");
        self.styleSub.stringValue = RLPTr(@"点击选择听感风格");
    }
    [self syncCapabilitiesUI];

    if (!self.currentPath.length) {
        self.npTitle.stringValue = RLPTr(@"还没有在播放的音乐");
        self.npSub.stringValue = RLPTr(@"从下面的专辑挑一张开始");
    } else if (self.lastMetaDict) {
        [self applyMetaToNowPlaying];
    }
    [self syncNowPlayingStateAndProgressForPath:(self.currentPath ?: @"")];
    [self syncNowPlayingSpec];
    self.npOpenButton.title = RLPTr(@"打开专辑页");
    self.npOpenButton.toolTip = RLPTr(@"打开当前曲目所属专辑页");

    self.queueCaption.stringValue = RLPTr(@"播放队列");
    self.queueAllButton.title = RLPTr(@"查看全部");
    self.queueAllButton.toolTip = RLPTr(@"打开播放队列页");
    if (self.lastQueueJSON) {
        [self renderQueueFromJSON:self.lastQueueJSON];
    } else {
        [self renderQueueEmptyState];
    }

    self.albumCaption.stringValue = RLPTr(@"专辑");
    self.openLibButton.title = RLPTr(@"打开音乐库");
    self.openLibButton.toolTip = RLPTr(@"查看全部专辑");
    for (NSUInteger i = 0; i < self.albumCardViews.count && i < self.albumsData.count; ++i) {
        [self.albumCardViews[i] refreshLanguageFromAlbum:self.albumsData[i]];
    }
    self.albumCountLabel.stringValue = [NSString stringWithFormat:@"%lu %@",
        (unsigned long)self.albumsData.count, RLPTr(@"张专辑")];
    if (self.albumEmptyCard) {
        [self syncAlbumEmptyCardCopy];
    }

    [self syncLibrarySummaryUI];
    self.libButton.toolTip = RLPTr(@"管理或重新扫描本地音乐库");
    self.moreTitleLabel.stringValue = RLPTr(@"流媒体");
    self.moreDescLabel.stringValue = RLPTr(@"流媒体在这里挂载；AI 资料与音频输入在左侧「设置」里调整。");
    self.moreButton.title = RLPTr(@"更多");
    self.moreButton.toolTip = RLPTr(@"流媒体挂载与扩展入口");
}

@end
