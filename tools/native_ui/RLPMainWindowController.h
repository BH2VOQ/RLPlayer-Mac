// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

@class RLPSidebarViewController;
@class RLPAlbumsViewController;
@class RLPPlaybackBarView;

NS_ASSUME_NONNULL_BEGIN

/// 主窗口：侧栏 + 内容区 + 底部播放条（纯 AppKit，无 WKWebView）。
@interface RLPMainWindowController : NSWindowController

@property (nonatomic, strong, readonly) RLPSidebarViewController *sidebar;
@property (nonatomic, strong, readonly) RLPAlbumsViewController *albums;
@property (nonatomic, strong, readonly) RLPPlaybackBarView *playbackBar;

/// 当前显示的内容页（功能审计断言"点进去到底换了没有"用）。
@property (nonatomic, strong, readonly, nullable) NSViewController *currentContent;

/// 核心启动后调用：加载首批数据（专辑）并启动播放条轮询。
- (void)loadInitialData;

/// 窗口关闭/退出前停掉一切轮询（避免定时器在 dealloc 后打到野对象）。
- (void)stopAllActivity;

@end

NS_ASSUME_NONNULL_END
