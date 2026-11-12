// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPModels.h — /api 返回 JSON 的只读模型（纯 Foundation，可离线单测）
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 合作署名拆分（与 web 版 npAlbumArtists 同口径：括号内不拆；& 、 ; feat. 拆；去重）。
NSArray<NSString *> *RLPSplitArtistNames(NSString * _Nullable raw);

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
@property (nonatomic, copy) NSString *coverSrc;
+ (nullable instancetype)albumFromJSON:(NSDictionary *)json;
+ (NSArray<RLPAlbum *> *)albumsFromJSON:(NSDictionary *)json;
@end

@interface RLPArtist : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSInteger albumCount;
@property (nonatomic) NSInteger trackCount;
/// 从专辑列表派生（一张合作专辑同时计入每位参与者）。
+ (NSArray<RLPArtist *> *)artistsFromAlbums:(NSArray<RLPAlbum *> *)albums;
@end

@interface RLPTrack : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic) NSInteger number;
@property (nonatomic) NSInteger disc;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) double duration;
@property (nonatomic) double cueStart;
@property (nonatomic) double cueEnd;
@property (nonatomic) NSInteger sampleRate;
@property (nonatomic) NSInteger bits;
@property (nonatomic) NSInteger channels;
@property (nonatomic, copy) NSString *codec;
/// /api/lib/search、/api/lib/album、/api/recent、/api/fav/list 的行都能吃。
+ (nullable instancetype)trackFromJSON:(NSDictionary *)json;
+ (NSArray<RLPTrack *> *)tracksFromJSON:(NSDictionary *)json key:(nullable NSString *)key;
@end

@interface RLPQueueSnapshot : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic) NSInteger mode;
@property (nonatomic, copy) NSArray<NSString *> *paths;
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *cues;
@property (nonatomic, copy) NSArray<NSDictionary *> *metas;
+ (nullable instancetype)snapshotFromJSON:(NSDictionary *)json;
@end

@interface RLPPlaybackStatus : NSObject
@property (nonatomic) BOOL playing;
@property (nonatomic) BOOL paused;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic) double position;
@property (nonatomic) double duration;
@property (nonatomic) double volumeDb;
@property (nonatomic, copy) NSString *error;
@property (nonatomic, copy) NSString *bitPerfect;
/// 后端给的位完美判定原因（照实显示，不自己编）。
@property (nonatomic, copy) NSString *bitPerfectWhy;
/// 本次播放的实际输出格式（/api/status 的 outRate / outBits，底栏 #fmt 徽标用；
/// 与 web 同字段：还没有开始播放时后端不回这两个键 ⟹ 0 ⟹ 徽标显示 "--"）。
@property (nonatomic) double outRate;
@property (nonatomic) NSInteger outBits;
/// 本次播放 GPU 是否真的参与（web #gpub 同口径；没上线/未参与时 false）。
@property (nonatomic) BOOL gpuUsed;
+ (nullable instancetype)statusFromJSON:(NSDictionary *)json;
@end

NS_ASSUME_NONNULL_END
