// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPModels.h"
#import "RLPSupport.h"   // RLPTr（多语言）

static NSString *Str(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v isKindOfClass:[NSString class]] ? v : @"";
}
static double Num(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0.0;
}
static BOOL Bool(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
}

NSArray<NSString *> *RLPSplitArtistNames(NSString *raw) {
    NSString *s = [raw ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return @[RLPTr(@"未知艺术家")];
    // 括号内不拆：先把 (...) / （...） 里的分隔符暂时换成占位符。
    NSMutableString *masked = [s mutableCopy];
    NSRegularExpression *paren = [NSRegularExpression regularExpressionWithPattern:@"[\\(（][^\\)）]*[\\)）]" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [paren matchesInString:masked options:0 range:NSMakeRange(0, masked.length)];
    for (NSTextCheckingResult *m in matches.reverseObjectEnumerator) {
        [masked replaceCharactersInRange:m.range withString:@"\u0001"];
    }
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSArray<NSString *> *parts = [masked componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"&,;、"]];
    for (NSString *p in parts) {
        for (NSString *q in [p componentsSeparatedByString:@" feat. "]) {
            for (NSString *r in [q componentsSeparatedByString:@" featuring "]) {
                NSString *name = [r stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (name.length && ![out containsObject:name] && ![name isEqualToString:@"\u0001"]) [out addObject:name];
            }
        }
    }
    return out.count ? out : @[s];
}

@implementation RLPAlbum
+ (nullable instancetype)albumFromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    RLPAlbum *a = [[RLPAlbum alloc] init];
    a.key = Str(json, @"k");
    a.name = Str(json, @"name");
    a.artist = Str(json, @"artist");
    a.year = (NSInteger)Num(json, @"year");
    a.trackCount = (NSInteger)Num(json, @"n");
    a.duration = Num(json, @"dur");
    a.sampleRate = (NSInteger)Num(json, @"sr");
    a.bits = (NSInteger)Num(json, @"bits");
    a.hasCover = Bool(json, @"cv");
    a.coverSrc = Str(json, @"cvSrc");
    return a.key.length ? a : nil;
}
+ (NSArray<RLPAlbum *> *)albumsFromJSON:(NSDictionary *)json {
    NSMutableArray *out = [NSMutableArray array];
    id arr = json[@"albums"];
    if (![arr isKindOfClass:[NSArray class]]) return out;
    for (id row in (NSArray *)arr) {
        RLPAlbum *a = [self albumFromJSON:row];
        if (a) [out addObject:a];
    }
    return out;
}
@end

@implementation RLPArtist
+ (NSArray<RLPArtist *> *)artistsFromAlbums:(NSArray<RLPAlbum *> *)albums {
    NSMutableDictionary<NSString *, RLPArtist *> *map = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (RLPAlbum *a in albums) {
        for (NSString *name in RLPSplitArtistNames(a.artist)) {
            RLPArtist *artist = map[name];
            if (!artist) {
                artist = [[RLPArtist alloc] init];
                artist.name = name;
                map[name] = artist;
                [order addObject:name];
            }
            artist.albumCount += 1;
            artist.trackCount += a.trackCount;
        }
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in order) [out addObject:map[name]];
    return out;
}
@end

@implementation RLPTrack
+ (nullable instancetype)trackFromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    RLPTrack *t = [[RLPTrack alloc] init];
    t.index = (NSInteger)Num(json, @"i");
    t.number = (NSInteger)Num(json, @"n");
    t.disc = (NSInteger)Num(json, @"d");
    t.title = Str(json, @"title");
    t.artist = Str(json, @"artist");
    t.album = Str(json, @"album");
    t.path = Str(json, @"path");
    if (!t.path.length) t.path = Str(json, @"file");
    t.duration = Num(json, @"dur");
    t.cueStart = Num(json, @"cs");
    t.cueEnd = Num(json, @"ce");
    t.sampleRate = (NSInteger)Num(json, @"sr");
    t.bits = (NSInteger)Num(json, @"bits");
    t.channels = (NSInteger)Num(json, @"ch");
    t.codec = Str(json, @"codec");
    if (!t.title.length && t.path.length) t.title = t.path.lastPathComponent.stringByDeletingPathExtension;
    return t;
}
+ (NSArray<RLPTrack *> *)tracksFromJSON:(NSDictionary *)json key:(NSString *)key {
    NSMutableArray *out = [NSMutableArray array];
    id arr = key ? json[key] : json[@"tracks"];
    if (![arr isKindOfClass:[NSArray class]]) arr = json[@"items"];
    if (![arr isKindOfClass:[NSArray class]]) return out;
    for (id row in (NSArray *)arr) {
        RLPTrack *t = [self trackFromJSON:row];
        if (t) [out addObject:t];
    }
    return out;
}
@end

@implementation RLPQueueSnapshot
+ (nullable instancetype)snapshotFromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]] || ![json[@"ok"] boolValue]) return nil;
    RLPQueueSnapshot *q = [[RLPQueueSnapshot alloc] init];
    q.index = (NSInteger)Num(json, @"index");
    q.mode = (NSInteger)Num(json, @"mode");
    q.paths = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
    q.cues = [json[@"cues"] isKindOfClass:[NSArray class]] ? json[@"cues"] : @[];
    q.metas = [json[@"metas"] isKindOfClass:[NSArray class]] ? json[@"metas"] : @[];
    return q;
}
@end

@implementation RLPPlaybackStatus
+ (nullable instancetype)statusFromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    if (![json[@"ok"] respondsToSelector:@selector(boolValue)] || ![json[@"ok"] boolValue]) return nil;
    RLPPlaybackStatus *s = [[RLPPlaybackStatus alloc] init];
    s.playing = Bool(json, @"playing");
    s.paused = Bool(json, @"paused");
    s.currentPath = Str(json, @"current");
    s.position = Num(json, @"pos");
    s.duration = Num(json, @"dur");
    s.volumeDb = Num(json, @"volDb");
    s.error = Str(json, @"error");
    s.bitPerfect = Str(json, @"bitPerfect");
    s.bitPerfectWhy = Str(json, @"bitPerfectWhy");
    s.outRate = Num(json, @"outRate");
    s.outBits = (NSInteger)Num(json, @"outBits");
    s.gpuUsed = Bool(json, @"gpuUsed");
    return s;
}
@end
