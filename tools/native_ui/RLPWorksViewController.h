// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPPageViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// 古典作品 · 演绎版本（对齐 web loadWorksView / openWorkVersions）。
/// 按「作品名 + 作曲家」查 Discogs 不同录音版本（指挥/乐团/年代/厂牌）。
/// 只从单曲页「作品」入口进入（web 261023-04 #9：左导航不放入口）。
@interface RLPWorksViewController : RLPPageViewController
/// 打开并检索指定作品（composer 可空）。fromNowPlaying=YES 时给「返回正在播放」按钮。
- (void)loadWork:(NSString *)title composer:(nullable NSString *)composer fromNowPlaying:(BOOL)fromNp;
- (void)applyLanguage;
@end

NS_ASSUME_NONNULL_END