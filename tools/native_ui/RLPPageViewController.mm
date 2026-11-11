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

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    _root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 640)];
    _root.wantsLayer = YES;
    _root.layer.backgroundColor = t.bg.CGColor;
    self.view = _root;

    _title = RLPLabel(_pageTitle, [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold], t.text);
    _title.translatesAutoresizingMaskIntoConstraints = NO;
    // 标题统一由主窗口顶栏承载（web #pth 同口径）；页内不再画大标题，
    // 但保留 18+17+12 的顶部留白，内容起始位置与 web 一致。
    _title.hidden = YES;
    [_root addSubview:_title];

    _subtitle = RLPLabel(@"", t.small, t.mut);
    _subtitle.alignment = NSTextAlignmentRight;
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
        [_content.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:12],
        [_content.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor],
    ]];

    [self buildContent];
}

- (void)buildContent {}
- (void)reloadData {}
- (void)activate { [self reloadData]; }

- (void)setSubtitle:(NSString *)text {
    _subtitle.stringValue = text.length ? RLPTr(text) : @"";
}

- (void)applyTheme {
    RLPTheme *t = [RLPTheme current];
    _root.layer.backgroundColor = t.bg.CGColor;
    _title.textColor = t.text;
    _subtitle.textColor = t.mut;
    [_root setNeedsDisplay:YES];
}

@end
