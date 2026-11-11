// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// AI 资料面板（知识卡 + 简介），可嵌进单曲页 / 专辑详情 / 艺术家详情。
/// 后端 job 语义：pending 时按 retryAfterMs 轮询（夹 150..2000ms）。
@interface RLPKnowledgeView : NSView
/// kind: track / release / person / work；name 必填；artist 可空。
- (void)loadKind:(NSString *)kind name:(NSString *)name artist:(nullable NSString *)artist;
- (void)cancelLoading;
- (void)applyTheme;
@end

NS_ASSUME_NONNULL_END
