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

#pragma mark - 歌词 AI（翻译 / 音译 / 日语假名 / 简转繁）

// 表单值编码：只保留 RFC3986 的 unreserved 字符，其余全部百分号编码。
// 为什么不用 URLQueryAllowedCharacterSet：它**不**编码 & = + ? / 这些在表单里有语义的字符，
// 歌词里一句 "rock & roll" 就会把请求体劈成另一个参数（上游 web 侧用 encodeURIComponent 同口径）。
static NSString *RLPLyricsFormEscape(NSString *s) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"];
    });
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

@implementation RLPLyrics (AI)

+ (NSArray<NSString *> *)aiMenuTitles {
    // 六项与上游 v3.3.11 的歌词右键菜单同口径（翻译…/音译/日语假名/转繁体 + 恢复原文/复制歌词）。
    return @[ @"翻译…", @"音译", @"日语假名", @"转繁体", @"恢复原文", @"复制歌词" ];
}

+ (NSString *)aiTaskForMenuTitle:(NSString *)title {
    if ([title isEqualToString:@"翻译…"]) return @"translate";
    if ([title isEqualToString:@"音译"])   return @"translit";
    if ([title isEqualToString:@"日语假名"]) return @"furigana";
    if ([title isEqualToString:@"转繁体"]) return @"trad";
    return nil;
}

+ (NSString *)aiRequestBodyTask:(NSString *)task
                           lang:(NSString *)lang
                     sourceLang:(NSString *)sourceLang
                          lines:(NSArray<NSString *> *)lines {
    NSArray<NSString *> *safe = lines ?: @[];
    NSData *json = [NSJSONSerialization dataWithJSONObject:safe options:0 error:nil];
    NSString *jsonText = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"[]";
    return [NSString stringWithFormat:@"task=%@&lang=%@&srclang=%@&lines=%@",
            RLPLyricsFormEscape(task ?: @""),
            RLPLyricsFormEscape(lang ?: @""),
            RLPLyricsFormEscape(sourceLang ?: @""),
            RLPLyricsFormEscape(jsonText ?: @"[]")];
}

+ (NSArray<RLPLyricLine *> *)applyAiLines:(NSArray<NSString *> *)aiLines
                                       to:(NSArray<RLPLyricLine *> *)originals {
    if (![aiLines isKindOfClass:[NSArray class]] || ![originals isKindOfClass:[NSArray class]]) return nil;
    // 行数守恒：少一行就是整首歌错位（后端也按这条拒绝），这里再挡一道。
    if (aiLines.count != originals.count) return nil;
    NSMutableArray<RLPLyricLine *> *out = [NSMutableArray arrayWithCapacity:originals.count];
    for (NSUInteger i = 0; i < originals.count; ++i) {
        id v = aiLines[i];
        if (![v isKindOfClass:[NSString class]]) return nil;
        RLPLyricLine *l = [RLPLyricLine new];
        l.t = originals[i].t;        // 时间戳原样保留 ⟹ 高亮/滚动/点行跳转全部不受影响
        l.text = (NSString *)v;
        [out addObject:l];
    }
    return out;
}

+ (NSArray<RLPLyricLine *> *)linesFromAiResponse:(NSDictionary *)json
                                       appliedTo:(NSArray<RLPLyricLine *> *)originals
                                           error:(NSString **)error {
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) *error = @"没有响应（核心未启动或请求失败）";
        return nil;
    }
    if (![json[@"ok"] boolValue]) {
        id msg = json[@"error"];
        if (error) *error = [msg isKindOfClass:[NSString class]] ? (NSString *)msg : @"处理失败";
        return nil;
    }
    id lines = json[@"lines"];
    if (![lines isKindOfClass:[NSArray class]]) {
        if (error) *error = @"响应缺少 lines";
        return nil;
    }
    NSArray<RLPLyricLine *> *out = [self applyAiLines:(NSArray *)lines to:originals];
    if (!out && error) *error = @"行数与原文不符（为避免错行，已丢弃）";
    return out;
}

@end

