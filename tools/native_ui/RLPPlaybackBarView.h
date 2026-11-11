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

/// 当前是否在播（取自最近一次 /api/status）。媒体键的 play/pause 幂等语义要用它。
@property (nonatomic, readonly) BOOL isPlaying;

/// 媒体键/锁屏拖动进度：跳到指定秒数（内部换算成 0..1 的比例再走 /api/seek）。
/// 没有正在播放的曲目时安全空转（不崩、不发请求）。
- (void)seekToSeconds:(double)seconds;

/// 主题切换后刷新自建颜色。
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
