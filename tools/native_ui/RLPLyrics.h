// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPLyrics.h — LRC 解析与高亮选行，**逐行对照 web 的 parseLrc / lyricTimed**。
//
// 为什么抽成纯函数：web 的解析有几个不显眼但必须一致的规则 ——
//   * [offset:±ms] 正值表示歌词整体提前（时间戳要减掉）
//   * [mm:ss.x] 是十分之一秒、[mm:ss.xx] 百分之一秒、三位才是毫秒
//   * 一行多时间戳要展开成多行
//   * [ti:]/[ar:]/[by:] 这类元信息行与空行跳过
//   * 没有时间轴时保留纯文本行但 t=-1 ⟹ 不高亮、不跟随滚动
// 这些规则写在 UI 里就没法单测，所以放这里，判据见 tests/test_native_lyrics.mm。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一行歌词。t < 0 表示纯文本（无时间轴）。
@interface RLPLyricLine : NSObject
@property (nonatomic, assign) double t;
@property (nonatomic, copy) NSString *text;
@end

@interface RLPLyrics : NSObject
/// 解析 LRC 文本 → 按时间升序的行数组（与 web parseLrc 同口径）。
+ (NSArray<RLPLyricLine *> *)parse:(nullable NSString *)lrc;
/// 是否有时间轴（web lyricTimed：第一行 t >= 0）。
+ (BOOL)isTimed:(NSArray<RLPLyricLine *> *)lines;
/// 当前播放位置应高亮的行下标；没有匹配返回 -1（web syncLyrics 同口径）。
+ (NSInteger)activeIndex:(NSArray<RLPLyricLine *> *)lines position:(double)pos;
@end

/// 歌词 AI（翻译 / 音译 / 日语假名 / 简转繁）：右键菜单六项 + 请求体 + 结果贴回。
/// 移植上游 v3.3.11 的歌词 AI（后端 /api/lyrics/ai）。
/// 为什么放在这里而不是 UI 里：这三步（菜单名、表单编码、按行贴回）都有判据，
/// 写进视图代码就没法单测了（判据见 tests/test_native_lyrics.mm 的 A1~A4）。
@interface RLPLyrics (AI)
/// 右键菜单六项（顺序固定：翻译… / 音译 / 日语假名 / 转繁体 / 恢复原文 / 复制歌词）。
+ (NSArray<NSString *> *)aiMenuTitles;
/// 菜单名 → 后端任务名（translate / translit / furigana / trad）；不是 AI 项返回 nil。
+ (nullable NSString *)aiTaskForMenuTitle:(NSString *)title;
/// 表单请求体（POST /api/lyrics/ai）：lines 走 JSON（时间轴留在 UI，后端只换文本）。
+ (NSString *)aiRequestBodyTask:(NSString *)task
                           lang:(nullable NSString *)lang
                     sourceLang:(nullable NSString *)sourceLang
                          lines:(NSArray<NSString *> *)lines;
/// 按行贴回译文：时间戳 t 原样保留；行数不符返回 nil（宁可不贴，也不错位）。
+ (nullable NSArray<RLPLyricLine *> *)applyAiLines:(NSArray<NSString *> *)aiLines
                                               to:(NSArray<RLPLyricLine *> *)originals;
/// 解析 /api/lyrics/ai 回包并贴回；失败时回填 error 并返回 nil。
+ (nullable NSArray<RLPLyricLine *> *)linesFromAiResponse:(nullable NSDictionary *)json
                                                appliedTo:(NSArray<RLPLyricLine *> *)originals
                                                    error:(NSString * _Nullable * _Nullable)error;
@end


NS_ASSUME_NONNULL_END
