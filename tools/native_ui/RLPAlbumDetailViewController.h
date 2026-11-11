// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 专辑详情：大封面 + 元信息 + 曲目表（双击播放）。
@interface RLPAlbumDetailViewController : RLPPageViewController
- (instancetype)initWithAlbumKey:(NSString *)key;
@end

NS_ASSUME_NONNULL_END
