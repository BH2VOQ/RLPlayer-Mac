// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPArtistsViewController.h — 艺术家网格（从专辑派生）
//
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface RLPArtistsViewController : RLPPageViewController
- (void)searchWithQuery:(NSString *)query;
- (void)applyLanguage;
@end

NS_ASSUME_NONNULL_END
