// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPArtistDetailViewController.h — 艺术家详情（纯 AppKit）
//
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 艺术家详情：返回 + 圆形头像 + 名字 + 专辑统计 + 专辑网格。
@interface RLPArtistDetailViewController : RLPPageViewController

@property (nonatomic, copy, readonly) NSString *artistName;
@property (nonatomic, readonly) NSInteger albumCount;
@property (nonatomic, readonly) NSInteger totalTracks;
@property (nonatomic, readonly) double totalDuration;

- (instancetype)initWithArtistName:(NSString *)name;
- (void)applyLanguage;

@end

NS_ASSUME_NONNULL_END
