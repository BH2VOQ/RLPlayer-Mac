// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// AI 资料面板（知识卡 + 简介），可嵌进单曲页 / 专辑详情 / 艺术家详情。
/// 后端 job 语义：pending 时按 retryAfterMs 轮询（夹 150..2000ms）。
@interface RLPKnowledgeView : NSView
/// kind: track / release / person / work；name 必填；artist 可空。
- (void)loadKind:(NSString *)kind name:(NSString *)name artist:(nullable NSString *)artist;

/// web `npDataActivate('work')` / `npDataWorkBody`：古典作品的 Discogs 演绎版本。
/// 端点与 web 逐字一致：GET /api/entity/versions?kind=work&name=…[&composer=…][&refresh=1]。
/// 正文结构按 web：来源行（Discogs 实时 / 缓存 · 日期 · 不同演绎 N / 发行版本 M）→
/// 每条 `年份 · 标题 · 指挥·乐团·厂牌·格式`；查不到时给 web 的空态文案 + 「重试查询」。
- (void)loadWorkName:(nullable NSString *)name composer:(nullable NSString *)composer;
- (void)cancelLoading;
- (void)applyTheme;
- (void)applyLanguage;
@end

NS_ASSUME_NONNULL_END
