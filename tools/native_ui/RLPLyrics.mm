// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPLyrics.h"

@implementation RLPLyricLine
@end

@implementation RLPLyrics

+ (NSArray<RLPLyricLine *> *)parse:(NSString *)lrc {
    if (![lrc isKindOfClass:[NSString class]] || !lrc.length) return @[];
    NSString *clean = [lrc stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    NSArray<NSString *> *rows = [clean componentsSeparatedByString:@"\n"];

    // [offset:±ms]：正值 = 歌词整体提前 ⟹ 时间戳减掉它
    double offsetSec = 0;
    NSRegularExpression *offRe = [NSRegularExpression
        regularExpressionWithPattern:@"^\\s*\\[offset:\\s*([+-]?\\d+)\\s*\\]"
        options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSString *row in rows) {
        NSTextCheckingResult *m = [offRe firstMatchInString:row options:0
                                                     range:NSMakeRange(0, row.length)];
        if (m) {
            NSString *num = [row substringWithRange:[m rangeAtIndex:1]];
            offsetSec = num.integerValue / 1000.0;
        }
    }

    // [mm:ss] / [mm:ss.x] / [mm:ss.xx] / [mm:ss.xxx]
    NSRegularExpression *stampRe = [NSRegularExpression
        regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]"
        options:0 error:nil];
    NSRegularExpression *tagRe = [NSRegularExpression
        regularExpressionWithPattern:@"\\[[^\\]]*\\]" options:0 error:nil];
    NSRegularExpression *metaRe = [NSRegularExpression
        regularExpressionWithPattern:@"^\\[[a-z]+:" options:NSRegularExpressionCaseInsensitive error:nil];

    NSMutableArray<RLPLyricLine *> *out = [NSMutableArray array];
    BOOL timed = NO;
    for (NSString *row in rows) {
        NSArray<NSTextCheckingResult *> *ms = [stampRe matchesInString:row options:0
                                                                range:NSMakeRange(0, row.length)];
        NSMutableArray<NSNumber *> *stamps = [NSMutableArray array];
        for (NSTextCheckingResult *m in ms) {
            NSInteger mm = [[row substringWithRange:[m rangeAtIndex:1]] integerValue];
            NSInteger ss = [[row substringWithRange:[m rangeAtIndex:2]] integerValue];
            NSRange fr = [m rangeAtIndex:3];
            double fracSec = 0;
            if (fr.location != NSNotFound) {
                NSString *fs = [row substringWithRange:fr];
                NSInteger fv = fs.integerValue;
                // 位数决定量纲：1 位=十分之一秒，2 位=百分之一秒，3 位=毫秒
                if (fs.length == 1)      fracSec = fv / 10.0;
                else if (fs.length == 2) fracSec = fv / 100.0;
                else                     fracSec = fv / 1000.0;
            }
            [stamps addObject:@(mm * 60 + ss + fracSec)];
        }
        NSString *text = [[tagRe stringByReplacingMatchesInString:row options:0
              range:NSMakeRange(0, row.length) withTemplate:@""]
              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!stamps.count || !text.length) continue;   // 元信息行/空行跳过
        timed = YES;
        for (NSNumber *s in stamps) {
            RLPLyricLine *l = [RLPLyricLine new];
            l.t = MAX(0.0, s.doubleValue - offsetSec);
            l.text = text;
            [out addObject:l];
        }
    }

    if (timed) {
        [out sortUsingComparator:^NSComparisonResult(RLPLyricLine *a, RLPLyricLine *b) {
            if (a.t < b.t) return NSOrderedAscending;
            if (a.t > b.t) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        return out;
    }

    // 纯文本歌词：保留行但 t=-1 ⟹ 不高亮、不跟随（web 同口径）
    for (NSString *raw in rows) {
        NSString *x = [raw stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!x.length) continue;
        if ([metaRe firstMatchInString:x options:0 range:NSMakeRange(0, x.length)]) continue;
        RLPLyricLine *l = [RLPLyricLine new];
        l.t = -1;
        l.text = x;
        [out addObject:l];
    }
    return out;
}

+ (BOOL)isTimed:(NSArray<RLPLyricLine *> *)lines {
    return lines.count > 0 && lines.firstObject.t >= 0;
}

+ (NSInteger)activeIndex:(NSArray<RLPLyricLine *> *)lines position:(double)pos {
    if (![self isTimed:lines]) return -1;
    NSInteger hit = -1;
    for (NSInteger i = 0; i < (NSInteger)lines.count; ++i) {
        if (lines[(NSUInteger)i].t <= pos) hit = i;
        else break;
    }
    return hit;
}

@end
