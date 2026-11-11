// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 底部播放条：播放/暂停、上一首/下一首、曲名、进度、音量。
/// 状态来源 = 每 500 ms 轮询 /api/status（与 web 版同一真相源）。
@interface RLPPlaybackBarView : NSView

- (void)startPolling;
- (void)stopPolling;

/// 菜单/快捷键入口（等幂：playing 时暂停，否则播放/继续）。
- (void)playPause;
- (void)nextTrack;
- (void)previousTrack;

/// selftest 用：是否已挂上状态轮询。
@property (nonatomic, readonly) BOOL polling;

@end

NS_ASSUME_NONNULL_END
