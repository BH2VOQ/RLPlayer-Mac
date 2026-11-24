// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

@class RLPSidebarViewController;
@class RLPAlbumsViewController;
@class RLPPlaybackBarView;
@class RLPRightDrawer;

NS_ASSUME_NONNULL_BEGIN

/// 主窗口：侧栏 + 内容区 + 底部播放条（纯 AppKit，无 WKWebView）。
@interface RLPMainWindowController : NSWindowController <NSWindowDelegate>

@property (nonatomic, strong, readonly) RLPSidebarViewController *sidebar;
@property (nonatomic, strong, readonly) RLPAlbumsViewController *albums;
@property (nonatomic, strong, readonly) RLPPlaybackBarView *playbackBar;

/// 当前显示的内容页（功能审计断言"点进去到底换了没有"用）。
@property (nonatomic, strong, readonly, nullable) NSViewController *currentContent;

/// 右侧抽屉（web #right）：队列 / 歌词。判据要能拿到它核对几何与页签。
@property (nonatomic, strong, readonly) RLPRightDrawer *rightDrawer;
@property (nonatomic, assign, readonly) BOOL drawerOpen;
/// 切换抽屉（顶栏队列键 = web #bQueue 切 #app.qopen）。
- (void)toggleDrawer;
/// 打开抽屉并切到歌词页（底栏歌词键 = web #bLyric）。
- (void)openLyricDrawer;

/// 全屏「正在播放」覆盖页当前是否打开（判据：点播放条封面 → 必须变成 YES）。
@property (nonatomic, assign, readonly) BOOL nowPlayingOverlayVisible;
/// 当前正在播放覆盖页（未打开时 nil）。
@property (nonatomic, strong, readonly, nullable) NSViewController *nowPlayingPage;

/// 界面模式（"listen" 聆听模式 / "pro" 专业模式，默认 "listen"）。
@property (nonatomic, copy, readonly) NSString *uiMode;
/// 顶栏模式切换分段控件（identifier = @"top.mode"）。
@property (nonatomic, strong, readonly) NSSegmentedControl *modeControl;
/// 切换界面模式；persist=YES 时写入 POST /api/settings uimode=...，绝不中断播放或改音量/队列/设备。
- (void)setUiMode:(NSString *)mode persist:(BOOL)persist;
/// 从 GET /api/settings.kv.uimode 读取模式偏好（带 epoch 保护，过期回包不回跳）。
- (void)reloadUiModePreference;

/// 核心启动后调用：加载首批数据（专辑）并启动播放条轮询。
- (void)loadInitialData;

/// 窗口关闭/退出前停掉一切轮询（避免定时器在 dealloc 后打到野对象）。
- (void)stopAllActivity;

@end

NS_ASSUME_NONNULL_END
