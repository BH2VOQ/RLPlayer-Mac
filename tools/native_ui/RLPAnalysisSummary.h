// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPAnalysisSummary.h — 音频分析「一行摘要」的纯判读层
//
// 为什么单独一个文件：摘要文字必须**由后端字段推导**，不许写死文案，也不许 UI 自己算指标。
// 抽成纯函数（NSDictionary → NSString）才能离线单测边界值（铁律：测试通过≠测对了东西）。
// 语义与 web 版 src/net/ui_script.h 的 anlSumDyn / anlSumQual / anlSumFake 一一对应。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 动态摘要：DR 分档。dr_available=false 或 dr_db 缺失 ⟹ 素材过短·动态不适用。
NSString *RLPAnlSumDyn(NSDictionary *_Nullable h);
/// 音质摘要：削波判读。**绝不使用 snr_db**（压缩过的流行乐天然 15~20 dB，那是动态小不是噪声大）。
NSString *RLPAnlSumQual(NSDictionary *_Nullable h);
/// 假无损摘要：疑似有损转码 / 截止频率 / 带宽证据 / 24bit 实为低位深。
NSString *RLPAnlSumFake(NSDictionary *_Nullable h);

/// 数值可用性（与 web 版 anlHas 同口径：必须是有限数字）。
BOOL RLPAnlHas(id _Nullable v);
/// 格式化：不可用返回 "NA"（不是 "不适用 dB" 这种拼接垃圾）。
NSString *RLPAnlFmt(id _Nullable v, NSInteger digits, NSString *_Nullable unit);

/// 展开层级：0=只留一行摘要，1=关键指标，2=全量+原始证据。
typedef NS_ENUM(NSInteger, RLPAnlLevel) {
    RLPAnlLevelCollapsed = 0,
    RLPAnlLevelMetrics   = 1,
    RLPAnlLevelFull      = 2,
};

/// 自动分析去重（与 web 版 anlTick 同口径）：
/// 只在 autoanl=1 且正在播放且本地文件且该曲未跑过时返回 YES；每曲一次。
/// state 是调用方持有的可变字典（存 autoDone 的 path），切歌由调用方重置。
BOOL RLPAnlShouldAutoAnalyze(NSString *_Nullable path,
                             BOOL playing,
                             BOOL autoEnabled,
                             NSString *_Nullable alreadyDonePath,
                             BOOL busy,
                             BOOL cached);
// ---------------------------------------------------------------------------
// 数值口径（铁律 3）：后端用 -300 表示"不适用哨兵"（src/analysis/dynamics.h:266/301，
// src/analysis/track_health.h:346），而 RLPAnlHas 只判"是不是有限数字" ⟹ 单靠它会把这个哨兵
// 原样排成 "-300.00 dB"，看上去像一次真实测量。另外 *_available=false 时数值即使存在也不可信
// （dr_available=false ⟹ 动态不适用）。下面几个函数就是"哨兵 + 可用性"双判的唯一出口。
BOOL RLPAnlAvail(id _Nullable v);                            // 有限且 > -299
NSString *RLPAnlVal(id _Nullable v, NSInteger digits, NSString *_Nullable unit);
// flagKey 非空时该旗标必须为 true；否则只看哨兵。
NSString *RLPAnlValFlag(NSDictionary *_Nullable h, NSString *key, NSString *_Nullable flagKey,
                        NSInteger digits, NSString *_Nullable unit);
// 计数类：0 是真实值，缺失才 NA。
NSString *RLPAnlCount(id _Nullable v);

// 解开 /api/health 的外层。
// 后端返回的是 {ok, usable, cached, ms, stats, health:{…}}（tools/rtaweb.cpp 的
// handle_health_analysis，缓存命中与实算两条路径都这样）。摘要函数要的是 health 里面的扁平字段；
// 直接把外层当 health 会让 dr_db / quality 全部读不到 ⟹ 一首 DR 14.2、零削波的歌
// 被显示成「素材过短 · 动态不适用 / 不适用 · 样本不足」。inner 缺失时退回外层。
NSDictionary *_Nullable RLPAnlUnwrapHealth(NSDictionary *_Nullable json);

// 展开后的详情文本（纯函数：同一份 health 永远得到同一份输出，便于单测）。
// 数字全部来自后端；不可用一律 NA。error 只用于"没有结果"时的如实解释。
NSString *RLPAnlDetailText(NSDictionary *_Nullable health, NSInteger level, BOOL cached,
                           NSString *_Nullable error, NSString *_Nullable path);

// ---------------------------------------------------------------------------
// 展开档「每张卡」的指标行模型（web anlCardDyn / anlCardQual / anlCardFake 的移植）
//
// 为什么要有这个 API：web 的展开档不是一块纯文本，而是**三张卡各自长出 2 列指标网格**。
// 行模型是「health → 行」的唯一出口，UI 只负责排版（不自己算指标、不写死文案），
// 这样同一份 health 的行内容可以在离线单测里逐条钉住。
//
// 返回值元素是 NSDictionary，k 区分四类：
//   sec  @{k:"sec",  t:分组标题}                       —— web .anlsec（带顶部 1px 规则）
//   row  @{k:"row",  l:标签, v:值, na:BOOL, warn:BOOL, wide:BOOL}
//                                                     —— web .anlml（wide = NA 长原因整行独占）
//   warn @{k:"warn", t:主文, h:提示}                    —— web .anlwarn（真峰过载）
//   note @{k:"note", t:文本}                            —— web .anlnote / .anlwh
// 值全部由 health 字段推导；不可用一律 NA（带原因），绝不编造数值。
//
// cardKey ∈ "dyn" / "qual" / "fake"；level 0 = 收起档（只有 dyn 的真峰警告），
// 1 = 关键指标，2 = 全量 + 原始证据（与 web anlSetLvl 的三档同口径）。
NSArray<NSDictionary *> *_Nonnull RLPAnlRowsForCard(NSDictionary *_Nullable health,
                                                    NSString *_Nonnull cardKey,
                                                    NSInteger level);

/// 是否本地文件（可分析）。流媒体/远端路径不可分析。
BOOL RLPAnlIsLocalPath(NSString *_Nullable path);

NS_ASSUME_NONNULL_END
