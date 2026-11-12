// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// Offline AppKit objects only. No embedded core, devices, ports, or input automation.
#import <AppKit/AppKit.h>
#import "RLPPlaybackBarView.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPTheme.h"
#include <cstdio>
#include <cmath>
static NSDictionary *statusJSON;
static NSMutableArray<NSString *> *posts;
static BOOL online = NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RLPCoreClient
+ (instancetype)shared { static RLPCoreClient *c; if (!c) c = [self new]; return c; }
- (BOOL)started { return online; }
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    if (!done) return;
    if ([path hasPrefix:@"/api/meta"]) done(@{@"title":@"Real title", @"artist":@"Real artist", @"album":@"Real album"});
    else if ([path isEqual:@"/api/status"]) done(statusJSON);
    else done(@{@"mode":@0});
}
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if (done) done(nil); }
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    [posts addObject:path]; if (done) done(@{@"ok":@YES});
}
@end
#pragma clang diagnostic pop
@interface RLPPlaybackBarView (Criterion)
- (void)fetchStatus;
- (void)toggleRepeat:(id)sender;
- (void)toggleShuffle:(id)sender;
- (void)commitVolume;
@end
static int failures = 0, checks = 0;
static void check(BOOL ok, const char *what) { ++checks; printf("[%s] %s\n", ok ? "PASS" : "FAIL", what); if (!ok) ++failures; }
static id field(id bar, NSString *key) { return [bar valueForKey:key]; }
int main() { @autoreleasepool {
    [NSApplication sharedApplication]; posts = [NSMutableArray array];
    RLPPlaybackBarView *bar = [[RLPPlaybackBarView alloc] initWithFrame:NSMakeRect(0,0,1120,66)];
    statusJSON = @{@"ok":@YES,@"playing":@YES,@"current":@"/offline/file.flac",@"volDb":@(-120),@"bitPerfect":@"yes",@"outRate":@44100,@"outBits":@24};
    [bar fetchStatus]; [bar layout];
    NSArray *keys = @[@"repeatBtn",@"prevBtn",@"playBtn",@"nextBtn",@"stopBtn"];
    CGFloat end = -1;
    for (NSString *key in keys) { NSView *v=field(bar,key); check(!v.hidden && v.frame.origin.x > end, "five controls ordered repeat/prev/play/next/stop"); end=NSMaxX(v.frame); }
    NSView *shuffle=field(bar,@"shuffleBtn"); check(shuffle.hidden || shuffle.superview == nil, "no sixth shuffle control; API remains available");
    check(fabs([field(bar,@"playBtn") frame].size.width-34)<.01, "web main key is 34pt");
    check(fabs([field(bar,@"coverView") frame].size.width-44)<.01, "web cover is 44pt");
    for (NSNumber *width in @[@1120,@980,@860]) {
        bar.frame=NSMakeRect(0,0,width.doubleValue,66); [bar layout];
        NSArray *right=@[@"lyricBtn",@"chainBtn",@"bpBadge",@"fmtBadge",@"volIconView",@"volume"];
        CGFloat edge=NSMaxX([field(bar,@"stopBtn") frame]);
        for (NSString *key in right) { NSView *v=field(bar,key); check(!v.hidden && v.frame.size.width>0 && NSMinX(v.frame)>=edge && NSMaxX(v.frame)<=width.doubleValue, "right controls and badges visible inside right column in one or two rows"); }
        for (NSUInteger i=0;i<right.count;++i) for(NSUInteger j=i+1;j<right.count;++j)
            check(!NSIntersectsRect([field(bar,right[i]) frame],[field(bar,right[j]) frame]), "right status cluster controls never overlap after wrapping");
    }
    for (NSNumber *width in @[@1180,@1120,@980,@860,@626]) {
        bar.frame=NSMakeRect(0,0,width.doubleValue,66); [bar layout];
        check(fabs(NSMidX([field(bar,@"playBtn") frame])-width.doubleValue/2)<.01, "play key stays centered on entire bar with symmetric side columns");
    }
    NSTextField *bp=field(bar,@"bpBadge");
    for (NSString *state in @[@"yes",@"no",@"direct",@""]) {
        NSMutableDictionary *d=[statusJSON mutableCopy]; d[@"bitPerfect"]=state; statusJSON=d; [bar fetchStatus]; [bar layout];
        NSString *expected=[state isEqual:@"yes"]?@"BIT-PERFECT":[state isEqual:@"direct"]?@"BIT-PERFECT·1bit":[state isEqual:@"no"]?@"非 bit-perfect":@"待播放验证";
        check(!bp.hidden && [bp.stringValue isEqual:expected], "badge reflects real yes/no/direct/idle state");
    }
    check([[field(bar,@"titleLabel") stringValue] isEqual:@"Real title"], "metadata title survives subsequent polls");
    check([[field(bar,@"subLabel") stringValue] isEqual:@"Real artist · Real album"], "real artist and album shown");
    NSSlider *volume=field(bar,@"volume"); check(![volume.cell isMemberOfClass:NSSliderCell.class], "custom theme-colored slider cell, not system blue track");
    for (NSString *key in @[@"prevBtn",@"playBtn",@"nextBtn",@"stopBtn",@"repeatBtn"]) {
        NSButton *button=field(bar,key); check(button.target==bar && button.action!=NULL, "transport controls have real target-action wiring");
    }
    NSArray *cases=@[
        @{@"bitPerfect":@"direct",@"dsd":@256,@"current":@"/offline/test.dsf",@"expect":@"BIT-PERFECT·1bit"},
        @{@"bitPerfect":@"no",@"dsd":@128,@"expect":@"PCM-DSD 升频"},
        @{@"bitPerfect":@"no",@"dsd":@256,@"current":@"/offline/test.dsf",@"expect":@"DSD-DSD 升频"},
        @{@"bitPerfect":@"no",@"inRate":@96000,@"outRate":@44100,@"expect":@"PCM 降采样"},
        @{@"bitPerfect":@"no",@"inRate":@44100,@"outRate":@96000,@"expect":@"PCM-PCM 升频"},
        @{@"bitPerfect":@"no",@"transport":@"upnp",@"inRate":@44100,@"outRate":@96000,@"expect":@"非 bit-perfect"},
        @{@"bitPerfect":@"no",@"transport":@"airplay",@"resampled":@YES,@"inRate":@96000,@"outRate":@44100,@"expect":@"PCM 降采样"},
        @{@"bitPerfect":@"no",@"bitPerfectWhy":@"物理格式未锁定",@"inRate":@44100,@"outRate":@96000,@"expect":@"非 bit-perfect"}
    ];
    NSDictionary *base=statusJSON;
    for (NSDictionary *c in cases) {
        NSMutableDictionary *d=[base mutableCopy]; [d addEntriesFromDictionary:c]; statusJSON=d;
        [bar fetchStatus]; [bar layout]; check([bp.stringValue isEqual:c[@"expect"]], "badge direction and direct/cast negative controls use backend evidence");
    }
    NSMutableDictionary *gpu=[base mutableCopy]; gpu[@"gpuUsed"]=@YES; statusJSON=gpu; [bar fetchStatus]; [bar layout];
    check(![field(bar,@"gpuBadge") isHidden], "GPU badge follows real gpuUsed status");
    gpu[@"bitPerfect"]=@"direct"; gpu[@"gpuUsed"]=@YES; statusJSON=gpu;
    bar.frame=NSMakeRect(0,0,626,66); [bar fetchStatus]; [bar layout];
    NSArray *all=@[@"coverView",@"titleLabel",@"subLabel",@"repeatBtn",@"prevBtn",@"playBtn",@"nextBtn",@"stopBtn",@"posLabel",@"progress",@"durLabel",@"lyricBtn",@"chainBtn",@"bpBadge",@"fmtBadge",@"gpuBadge",@"volIconView",@"volume"];
    for (NSUInteger i=0;i<all.count;++i) {
        NSView *a=field(bar,all[i]); check(!a.hidden && NSContainsRect(bar.bounds,a.frame), "minimum supported 626pt bar contains every real control/badge");
        for (NSUInteger j=i+1;j<all.count;++j) {
            NSView *b=field(bar,all[j]); check(!NSIntersectsRect(a.frame,b.frame), "minimum bar controls do not overlap");
        }
    }
    gpu[@"gpuUsed"]=@NO; statusJSON=gpu; [bar fetchStatus]; check([field(bar,@"gpuBadge") isHidden], "GPU badge clears when unused");
    NSBitmapImageRep *pixels=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:100 pixelsHigh:16 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:pixels]];
    volume.doubleValue=500; [volume.cell drawBarInside:NSMakeRect(0,0,100,16) flipped:NO];
    [NSGraphicsContext restoreGraphicsState];
    NSColor *ink=[[pixels colorAtX:20 y:8] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    NSColor *accent=[RLPTheme.current.accent colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    check(fabs(ink.redComponent-accent.redComponent)<.02 && fabs(ink.greenComponent-accent.greenComponent)<.02, "drawn slider fill uses web accent rather than macOS blue");
    online=YES; [bar startPolling];
    for (NSNumber *pos in @[@0,@5,@500,@1000]) {
        volume.doubleValue=pos.doubleValue; [bar commitVolume];
        double expected=pos.doubleValue<=5?-120:-55*pow(1-pos.doubleValue/1000,1.6);
        NSString *request=[NSString stringWithFormat:@"/api/volume?db=%.1f",expected];
        check([posts.lastObject isEqual:request], "volume curve matches frozen web including true silent notch");
    }
    [bar setValue:@0 forKey:@"playMode"];
    for (NSInteger mode=1;mode<=4;++mode) { [bar toggleRepeat:nil]; check([posts.lastObject isEqual:[NSString stringWithFormat:@"/api/playmode?mode=%ld",(long)(mode%4)]], "mode button cycles all four modes including shuffle"); }
    [bar stopPolling]; check(!bar.polling, "polling lifecycle preserved");
    printf("native_bar_web: %d checks, %d failures\n",checks,failures); return failures?1:0;
} }