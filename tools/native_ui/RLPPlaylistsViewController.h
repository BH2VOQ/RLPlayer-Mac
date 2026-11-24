// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 歌单页（原生）：左侧歌单列表 + 右侧曲目表。
/// /api/sq/* 是真相源，UI 不另存一份歌单。
@interface RLPPlaylistsViewController : RLPPageViewController
- (void)applyTheme;
- (void)applyLanguage;
@end

NS_ASSUME_NONNULL_END
