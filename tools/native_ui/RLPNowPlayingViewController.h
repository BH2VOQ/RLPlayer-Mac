// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 正在播放页：封面 / 曲目信息 / 歌词 / 音质体检 / 文件定位。
/// 状态来源 = /api/status 轮询（与播放条同一真相源）。
@interface RLPNowPlayingViewController : RLPPageViewController
- (void)startPolling;
- (void)stopPolling;
@end

NS_ASSUME_NONNULL_END
