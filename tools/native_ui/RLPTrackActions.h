// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPTrackActions.h — 曲目动作的**唯一实现**（右键菜单 + 音质体检 + 版本对比 + 存歌单）
//
// 为什么抽成共享模块：web 版任何曲目右键都是同一套四项
// （加入播放队列 / 保存到歌单… / 音质体检… / 对比同目录版本…），
// 而原生此前只有曲目页两项、专辑详情与队列各写一套 ⟹ 功能不齐且行为不一致。
// 这里统一提供，曲目页 / 专辑详情 / 队列 / 最近 / 最爱都调它，避免再各写一份。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 给某个曲目构造右键菜单（与 web trackActionMenu 同口径）。
/// path 为空返回 nil；网络曲目（http/https）自动省略"音质体检/对比版本"
/// ——后端没有本地路径，摆出来只会失败。
NSMenu *_Nullable RLPTrackMenuForPath(NSString *_Nullable path,
                                     id target,
                                     SEL playAction,
                                     SEL _Nullable removeAction);

/// 音质体检弹层（/api/health?file=…）：19 项指标，数字全部来自后端。
void RLPShowQualitySheet(NSString *path, NSView *_Nullable anchor);

/// 版本对比弹层（/api/files?dir=… 列同目录 → /api/compare）。
void RLPShowCompareSheet(NSString *path, NSView *_Nullable anchor);

/// 保存到歌单（/api/sq/list 选单 → /api/sq/add?name=&file=）。
void RLPShowSaveToPlaylist(NSString *path, NSView *_Nullable anchor);

/// 通用曲目表格：右键时按**被点那一行**动态生成完整菜单。
/// 各页面只需设 pathForRow 与 removeAction（不需要移除就传 nil）。
@interface RLPTrackActionTableView : NSTableView
@property (nonatomic, copy) NSString *_Nullable (^pathForRow)(NSInteger row);
@property (nonatomic, assign) SEL _Nullable removeAction;
@property (nonatomic, weak) id _Nullable removeTarget;
@end

/// 这三个动作的菜单项 tag（菜单回调按 tag 分派，避免每个页面各写一套 selector）。
typedef NS_ENUM(NSInteger, RLPTrackActionTag) {
    RLPTrackActionPlay      = 1001,
    RLPTrackActionEnqueue   = 1002,
    RLPTrackActionSaveToSQ  = 1003,
    RLPTrackActionQuality   = 1004,
    RLPTrackActionCompare   = 1005,
    RLPTrackActionRemove    = 1006,
    RLPTrackActionFavorite  = 1007,
    RLPTrackActionEnrich    = 1008,   // AI 资料补全（/api/enrich）
};

/// 统一处理菜单动作。representedObject 必须是曲目路径。
/// 返回 YES 表示已处理（调用方不必再自己分派）。
BOOL RLPHandleTrackAction(NSMenuItem *item, NSView *_Nullable anchor);

NS_ASSUME_NONNULL_END
