// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPMainWindowController.h"
#import "RLPSidebarViewController.h"
#import "RLPAlbumsViewController.h"
#import "RLPPlaybackBarView.h"
#import "RLPPlaceholderViewController.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"

static const CGFloat kSidebarWidth = 232.0;
static const CGFloat kPlaybackHeight = 76.0;

@interface RLPMainWindowController ()
@property (nonatomic, strong, readwrite) RLPSidebarViewController *sidebar;
@property (nonatomic, strong, readwrite) RLPAlbumsViewController *albums;
@property (nonatomic, strong, readwrite) RLPPlaybackBarView *playbackBar;
@property (nonatomic, strong) NSView *contentHost;
@property (nonatomic, strong) NSViewController *currentContent;
@property (nonatomic, strong) RLPPlaceholderViewController *placeholder;
@end

@implementation RLPMainWindowController

- (instancetype)init {
    RLPTheme *t = [RLPTheme current];
    NSRect frame = NSMakeRect(0, 0, 1180, 760);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                   NSWindowStyleMaskFullSizeContentView)
          backing:NSBackingStoreBuffered defer:NO];
    win.title = @"RLPlayer";
    win.titlebarAppearsTransparent = YES;
    win.titleVisibility = NSWindowTitleHidden;
    win.backgroundColor = t.bg;
    win.minSize = NSMakeSize(900, 600);
    win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [win center];

    self = [super initWithWindow:win];
    if (!self) return nil;

    NSView *root = win.contentView;
    root.wantsLayer = YES;
    root.layer.backgroundColor = t.bg.CGColor;

    _sidebar = [[RLPSidebarViewController alloc] init];
    _albums = [[RLPAlbumsViewController alloc] init];
    _playbackBar = [[RLPPlaybackBarView alloc] init];
    _placeholder = [[RLPPlaceholderViewController alloc] initWithTitle:@"迁移中"];

    _contentHost = [[NSView alloc] initWithFrame:NSZeroRect];
    _contentHost.wantsLayer = YES;
    _contentHost.layer.backgroundColor = t.bg.CGColor;

    for (NSView *v in @[_sidebar.view, _contentHost, _playbackBar]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:v];
    }

    [NSLayoutConstraint activateConstraints:@[
        [_sidebar.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_sidebar.view.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_sidebar.view.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_sidebar.view.widthAnchor constraintEqualToConstant:kSidebarWidth],

        [_playbackBar.leadingAnchor constraintEqualToAnchor:_sidebar.view.trailingAnchor],
        [_playbackBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_playbackBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_playbackBar.heightAnchor constraintEqualToConstant:kPlaybackHeight],

        [_contentHost.leadingAnchor constraintEqualToAnchor:_sidebar.view.trailingAnchor],
        [_contentHost.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_contentHost.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_contentHost.bottomAnchor constraintEqualToAnchor:_playbackBar.topAnchor],
    ]];

    __weak __typeof__(self) weakSelf = self;
    _sidebar.onSelect = ^(NSInteger row) { [weakSelf showContentForRow:row]; };
    _albums.onPlayAlbum = ^(NSString *key) {
        [[RLPCoreClient shared] postJSON:@"/api/lib/play" body:[NSString stringWithFormat:@"k=%@&i=0", key] completion:^(NSDictionary *json) {
            if (!json || ![json[@"ok"] boolValue]) {
                NSLog(@"RLP: 播放专辑失败：%@", json[@"error"] ?: @"未知错误");
            }
        }];
    };

    [self showContentForRow:0];
    [_sidebar selectRow:0];
    return self;
}

- (void)showContentForRow:(NSInteger)row {
    NSViewController *vc = nil;
    switch (row) {
        case 0: vc = self.albums; break;                 // 专辑（已实现）
        case 1: vc = [self placeholderWithTitle:@"艺术家"]; break;
        case 2: vc = [self placeholderWithTitle:@"曲目"]; break;
        case 3: vc = [self placeholderWithTitle:@"文件夹"]; break;
        case 4: vc = [self placeholderWithTitle:@"流媒体"]; break;
        case 5: vc = [self placeholderWithTitle:@"播放队列"]; break;
        case 6: vc = [self placeholderWithTitle:@"最近播放"]; break;
        case 7: vc = [self placeholderWithTitle:@"我的最爱"]; break;
        case 8: vc = [self placeholderWithTitle:@"快速开始"]; break;
        case 9: vc = [self placeholderWithTitle:@"设置"]; break;
        default: vc = self.albums; break;
    }
    if (vc == self.currentContent) return;
    if (self.currentContent) {
        [self.currentContent.view removeFromSuperview];
    }
    self.currentContent = vc;
    NSView *v = vc.view;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentHost addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:self.contentHost.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:self.contentHost.trailingAnchor],
        [v.topAnchor constraintEqualToAnchor:self.contentHost.topAnchor],
        [v.bottomAnchor constraintEqualToAnchor:self.contentHost.bottomAnchor],
    ]];
}

- (RLPPlaceholderViewController *)placeholderWithTitle:(NSString *)title {
    return [[RLPPlaceholderViewController alloc] initWithTitle:title];
}

- (void)loadInitialData {
    if (![RLPCoreClient shared].started) return;
    [self.albums reload];
    [self.playbackBar startPolling];
}

- (void)stopAllActivity {
    [self.playbackBar stopPolling];
}

@end