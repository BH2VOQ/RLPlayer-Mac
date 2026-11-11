// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPModels.h — /api 返回 JSON 的只读模型（纯 Foundation，可离线单测）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLPAlbum : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic) NSInteger year;
@property (nonatomic) NSInteger trackCount;
@property (nonatomic) double duration;
@property (nonatomic) NSInteger sampleRate;
@property (nonatomic) NSInteger bits;
@property (nonatomic) BOOL hasCover;
@property (nonatomic, copy) NSString *coverSrc;   // embed / net / none
+ (nullable instancetype)albumFromJSON:(NSDictionary *)json;
+ (NSArray<RLPAlbum *> *)albumsFromJSON:(NSDictionary *)json;
@end

@interface RLPAlbumTrack : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic) NSInteger number;
@property (nonatomic) NSInteger disc;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic) double duration;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) double cueStart;
@property (nonatomic) double cueEnd;
+ (NSArray<RLPAlbumTrack *> *)tracksFromAlbumJSON:(NSDictionary *)json;
@end

@interface RLPPlaybackStatus : NSObject
@property (nonatomic) BOOL playing;
@property (nonatomic) BOOL paused;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic) double position;
@property (nonatomic) double duration;
@property (nonatomic) double volumeDb;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *error;
@property (nonatomic, copy) NSString *bitPerfect;
+ (nullable instancetype)statusFromJSON:(NSDictionary *)json;
@end

NS_ASSUME_NONNULL_END
