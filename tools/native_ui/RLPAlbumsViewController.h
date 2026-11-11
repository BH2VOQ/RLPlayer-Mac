// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 专辑网格（对应 /api/lib/albums）。数据/封面全部走 RLPCoreClient，不阻塞主线程。
@interface RLPAlbumsViewController : NSViewController

/// 双击专辑（或点“播放全部”）时回调，参数是专辑 key（/api/lib/play 的 k=）。
@property (nonatomic, copy, nullable) void (^onPlayAlbum)(NSString *key);

/// 重新拉取专辑列表（核心未启动时安全空转）。
- (void)reload;

/// 切到本页时调用：重新上报计数（顶栏标题旁的"N 张专辑"）。
/// 主窗口每次路由都会调 activate；只有 reload 时上报会让计数在换页后被清空。
- (void)activate;

/// 已有专辑数（selftest/自检用）。
@property (nonatomic, readonly) NSInteger albumCount;

/// 页标题（顶栏承载；与 RLPPageViewController.pageTitle 同语义）。
@property (nonatomic, copy, readonly) NSString *pageTitle;

@end

NS_ASSUME_NONNULL_END
