// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPRightDrawer.h — 右侧悬浮抽屉（队列 / 歌词），对齐 web #right。
//
// web 的形态（ui_page.h:223）：
//   position:fixed; top:68px; right:18px; bottom:92px; width:320px;
//   border-radius:14px; border:1px solid var(--bar-border); background:var(--barbg);
//   backdrop-filter:blur(32px) saturate(190%); box-shadow:var(--bar-shadow)
// 头部（.rhead）：队列 / 歌词 两个 .rtab + 计数 + 「清除」文字按钮，min-height:42px。
// 队列行（.qi）：序号 20px + 标题 + 悬停才出现的 ×；当前行左侧 3px 强调色竖条。
// 歌词行（.ly）：13.5px / line-height 2.1；当前行 15px 加粗提亮。
//
// 为什么原生必须有它：web 的「边听边看队列/歌词」是主交互之一，
// 之前原生完全没有这个面板（只有一个独立的队列页），属功能缺失。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLPRightDrawer : NSView
/// 当前页签：@"q"（队列）/ @"l"（歌词），与 web RTAB 同值。
@property (nonatomic, copy, readonly) NSString *tab;
@property (nonatomic, assign, readonly) BOOL polling;

- (void)showTab:(NSString *)tab;
/// 进前台：拉一次数据并按 web 节奏轮询（队列 1s）。
- (void)activate;
/// 离开前台：停轮询（不在后台空转）。
- (void)deactivate;
- (void)applyTheme;
- (void)applyLanguage;
/// 播放位置变化时更新歌词高亮（由播放条的状态轮询驱动）。
- (void)updatePosition:(double)pos duration:(double)dur;
@end

NS_ASSUME_NONNULL_END
