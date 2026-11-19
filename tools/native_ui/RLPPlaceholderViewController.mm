// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPPlaceholderViewController.h"
#import "RLPTheme.h"

@implementation RLPPlaceholderViewController {
    NSString *_title;
}

- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super initWithNibName:nil bundle:nil])) _title = [title copy];
    return self;
}

- (void)loadView {
    RLPTheme *t = [RLPTheme current];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    v.wantsLayer = YES;
    v.layer.backgroundColor = t.bg.CGColor;

    NSTextField *title = [NSTextField labelWithString:_title ?: @""];
    title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    title.textColor = t.text;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *hint = [NSTextField labelWithString:@"此页的原生 AppKit 实现仍在迁移中。当前版本请使用 web 界面，功能不删减。"];
    hint.font = t.body;
    hint.textColor = t.mut;
    hint.translatesAutoresizingMaskIntoConstraints = NO;

    [v addSubview:title];
    [v addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:v.centerYAnchor constant:-16],
        [hint.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [hint.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
    ]];
    self.view = v;
}

@end
