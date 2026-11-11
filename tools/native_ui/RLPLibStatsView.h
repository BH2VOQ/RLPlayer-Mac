// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPLibStatsView.h — 本地音乐库统计卡（设置·高级页内嵌）
//
// 对齐 web 设置页 sp_libstats / renderLibStats（ui_script.h）：
//   GET /api/lib/stats → {tracks, albums, scanThreads, lastScanMs, scanning, scanned, total}
//   显示「曲目 / 专辑 / 扫描线程（生效） / 上次扫描」，扫描中额外显示「进度 scanned/total」。
//   扫描进行中定时刷新（web pollSchedule 同口径），停下来就不再轮询。
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLPLibStatsView : NSView
/// 开始/刷新统计（核心未启动时如实提示，不填假数字）。
- (void)reload;
/// 页面离开时停掉轮询（避免后台空转）。
- (void)stopPolling;
- (void)applyTheme;
@end

NS_ASSUME_NONNULL_END