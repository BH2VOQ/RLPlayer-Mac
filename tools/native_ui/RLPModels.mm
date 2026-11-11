// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPModels.h"

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

@implementation RLPAlbumTrack
+ (NSArray<RLPAlbumTrack *> *)tracksFromAlbumJSON:(NSDictionary *)json {
    NSMutableArray *out = [NSMutableArray array];
    id arr = json[@"tracks"];
    if (![arr isKindOfClass:[NSArray class]]) return out;
    for (id row in (NSArray *)arr) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = row;
        RLPAlbumTrack *t = [[RLPAlbumTrack alloc] init];
        t.index = (NSInteger)Num(d, @"i");
        t.number = (NSInteger)Num(d, @"n");
        t.disc = (NSInteger)Num(d, @"d");
        t.title = Str(d, @"title");
        t.artist = Str(d, @"artist");
        t.duration = Num(d, @"dur");
        t.path = Str(d, @"path");
        t.cueStart = Num(d, @"cs");
        t.cueEnd = Num(d, @"ce");
        [out addObject:t];
    }
    return out;
}
@end

@implementation RLPPlaybackStatus
+ (nullable instancetype)statusFromJSON:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    RLPPlaybackStatus *s = [[RLPPlaybackStatus alloc] init];
    s.playing = Bool(json, @"playing");
    s.paused = Bool(json, @"paused");
    s.currentPath = Str(json, @"current");
    s.position = Num(json, @"pos");
    s.duration = Num(json, @"dur");
    s.volumeDb = Num(json, @"volDb");
    s.error = Str(json, @"error");
    s.bitPerfect = Str(json, @"bitPerfect");
    if (![json[@"ok"] respondsToSelector:@selector(boolValue)] || ![json[@"ok"] boolValue]) return nil;
    return s;
}
@end
