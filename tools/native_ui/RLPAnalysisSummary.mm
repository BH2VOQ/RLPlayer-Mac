// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPAnalysisSummary.h"
#import "RLPSupport.h"

BOOL RLPAnlHas(id v) {
    if (![v isKindOfClass:[NSNumber class]]) return NO;
    // NSNull / 字符串都不算数字；NaN/Inf 也不算（后端探测失败时会给 null）。
    double d = [(NSNumber *)v doubleValue];
    return isfinite(d);
}

NSString *RLPAnlFmt(id v, NSInteger digits, NSString *unit) {
    if (!RLPAnlHas(v)) return @"NA";
    double d = [(NSNumber *)v doubleValue];
    NSString *s = [NSString stringWithFormat:@"%.*f", (int)digits, d];
    return unit.length ? [s stringByAppendingString:unit] : s;
}

static NSDictionary *Qual(NSDictionary *h) {
    id q = h[@"quality"];
    return [q isKindOfClass:[NSDictionary class]] ? q : nil;
}

NSString *RLPAnlSumDyn(NSDictionary *h) {
    if (![h isKindOfClass:[NSDictionary class]]) return RLPTr(@"未分析");
    // dr_available 显式 false ⟹ 后端明确说"不适用"，不能拿缺失当 0。
    id avail = h[@"dr_available"];
    if ([avail isKindOfClass:[NSNumber class]] && ![avail boolValue])
        return RLPTr(@"素材过短 · 动态不适用");
    if (!RLPAnlHas(h[@"dr_db"])) return RLPTr(@"素材过短 · 动态不适用");
    const double dr = [h[@"dr_db"] doubleValue];
    if (dr >= 14) return RLPTr(@"良好动态 · 古典/爵士常见");
    if (dr >= 11) return RLPTr(@"中等动态 · 摇滚/原声常见");
    if (dr >= 8)  return RLPTr(@"动态偏紧 · 流行母带常见");
    return RLPTr(@"低动态 · 高压缩母带");
}

NSString *RLPAnlSumQual(NSDictionary *h) {
    if (![h isKindOfClass:[NSDictionary class]]) return RLPTr(@"未分析");
    NSDictionary *q = Qual(h);
    id avail = q[@"available"];
    if (![avail isKindOfClass:[NSNumber class]] || ![avail boolValue])
        return RLPTr(@"不适用 · 样本不足");
    // 数字静音/无有效音频：clipped_samples=0 在静音里没有意义，不能说"干净"。
    if (!RLPAnlHas(q[@"peak_dbfs_q"]) || !RLPAnlHas(q[@"rms_dbfs"]))
        return RLPTr(@"无有效音频 · 指标不适用");
    const double n = RLPAnlHas(q[@"clipped_samples"]) ? [q[@"clipped_samples"] doubleValue] : 0;
    if (n <= 0) return RLPTr(@"干净 · 无明显削波");
    const double runs = RLPAnlHas(q[@"clipped_runs"]) ? [q[@"clipped_runs"] doubleValue] : 0;
    const double longest = RLPAnlHas(q[@"longest_clip_run"]) ? [q[@"longest_clip_run"] doubleValue] : 0;
    if (runs > 0 && longest >= 3)
        return [NSString stringWithFormat:@"%@ %ld %@", RLPTr(@"有削波 · 最长"), (long)longest, RLPTr(@"样本")];
    return [NSString stringWithFormat:@"%@ %ld %@", RLPTr(@"轻微削波 ·"), (long)n, RLPTr(@"样本")];
}

NSString *RLPAnlSumFake(NSDictionary *h) {
    if (![h isKindOfClass:[NSDictionary class]]) return RLPTr(@"未分析");
    id st = h[@"status"];
    if ([st isKindOfClass:[NSString class]] && [(NSString *)st length] && ![st isEqualToString:@"ready"])
        return RLPTr(@"分析未完成");
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    const BOOL suspected = [h[@"lossless_suspected"] isKindOfClass:[NSNumber class]] &&
                           [h[@"lossless_suspected"] boolValue];
    if (suspected) {
        [parts addObject:RLPTr(@"疑似有损转码")];
        if (RLPAnlHas(h[@"cutoff_hz"]))
            [parts addObject:[NSString stringWithFormat:@"%@ %.1f kHz", RLPTr(@"截止"),
                              [h[@"cutoff_hz"] doubleValue] / 1000.0]];
    } else {
        [parts addObject:RLPTr(@"未发现")];
        // 「满带宽」必须有证据：截止接近 fs/2 才敢这么说，否则如实写百分比或"未检出"。
        if (RLPAnlHas(h[@"cutoff_hz"]) && [h[@"cutoff_hz"] doubleValue] > 0 && RLPAnlHas(h[@"fs"]) && [h[@"fs"] doubleValue] > 0) {
            const double ratio = [h[@"cutoff_hz"] doubleValue] / ([h[@"fs"] doubleValue] / 2.0);
            if (ratio >= 0.93) [parts addObject:RLPTr(@"满带宽")];
            else [parts addObject:[NSString stringWithFormat:@"%@ %ld%%", RLPTr(@"带宽仅"), (long)lround(ratio * 100)]];
        } else {
            [parts addObject:RLPTr(@"未检出截止")];
        }
    }
    if ([h[@"fake24"] isKindOfClass:[NSNumber class]] && [h[@"fake24"] boolValue])
        [parts addObject:RLPTr(@"24bit 实为低位深")];
    return [parts componentsJoinedByString:@" · "];
}

BOOL RLPAnlIsLocalPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || !path.length) return NO;
    // 只认绝对本地路径；http(s)/流媒体协议一律不可分析（与 web 版 anlIsLocal 同口径）。
    if (![path hasPrefix:@"/"]) return NO;
    if ([path hasPrefix:@"//"]) return NO;
    return YES;
}

BOOL RLPAnlShouldAutoAnalyze(NSString *path, BOOL playing, BOOL autoEnabled,
                             NSString *alreadyDonePath, BOOL busy, BOOL cached) {
    if (!autoEnabled) return NO;
    if (!playing) return NO;                       // 暂停/停止不触发
    if (!RLPAnlIsLocalPath(path)) return NO;
    if (alreadyDonePath.length && [alreadyDonePath isEqualToString:path]) return NO;  // 每曲一次
    if (busy || cached) return NO;
    return YES;
}
