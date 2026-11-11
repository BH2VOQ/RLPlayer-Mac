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
/// 是否本地文件（可分析）。流媒体/远端路径不可分析。
BOOL RLPAnlIsLocalPath(NSString *_Nullable path);

NS_ASSUME_NONNULL_END
