// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTracksViewController.h — 曲目列表页（纯 AppKit / NSTableView）
//
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface RLPTracksViewController : RLPPageViewController

/// 外部或主窗口发起的按关键词检索（重置 limit 并立即执行）。
- (void)searchWithQuery:(NSString *)query;
- (void)applyLanguage;

@end

NS_ASSUME_NONNULL_END
