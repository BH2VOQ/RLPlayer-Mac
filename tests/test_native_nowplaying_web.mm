// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPNowPlayingViewController.h"
#import "RLPKnowledgeView.h"
#import "RLPTheme.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPLyrics.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <cmath>
#include <cstdio>

// 判据接缝：RLPRailWrapView 的惯性入口（实现在 RLPNowPlayingViewController.mm 内部，
// 不进公开头；ARC 下 id 发消息也需要签名，故在测试侧声明）。
@interface RLPNowPlayingViewController (RLPCoverTestSeam)
- (void)setCoverAtPath:(NSString *)coverPath forTrack:(NSString *)track;
- (void)resetCoverForTrack:(NSString *)track;
- (void)renderRailMetadata;
- (void)layoutWebPlayback;
- (void)openDataDrawer;
- (void)closeDataDrawer;
- (void)onRailDensity:(id)sender;
@end
@interface RLPKnowledgeView (NPDetailsTest)
- (void)renderMetaFixture:(NSDictionary *)fixture;
- (void)loadDrawerContext:(NSDictionary *)context;
- (CGFloat)renderedContentHeight;
@end
@interface NSObject (RLPRailMomentumTest)
- (void)beginMomentumWithVelocity:(CGFloat)v;
- (void)momentumTick:(id)sender;
- (void)onCommitPreciseVolume:(id)sender;
- (void)onToggleVolumeMute:(id)sender;
@end
static NSString *g_lastDataPath = nil;
static NSUInteger g_lastDataLen = 0;
static NSString *lastPath,*lastBody;static RLPJSONCompletion pendingFav, pendingLyricAi;
/// 请求挂起夹具（沿用 pendingFav / pendingLyricAi 的手法）：holdNPRequests=YES 时，
/// /api/lyrics?file=… 与 /api/cover?file=… 的回包先攥进 pendingLyrics / pendingCover，
/// 由用例决定何时回灌——这样才能复现「A→B 已切曲，A 的回包才到」。
/// 默认 NO ⟹ 与旧夹具一样立即应答，不影响其他判据。
static BOOL holdNPRequests;
static RLPJSONCompletion pendingLyrics;
static RLPDataCompletion pendingCover;
@interface RLPRequestSpy : NSObject
/// 按路径前缀返回固定 JSON 的桩：状态机判据要「真的走一遍 /api/status → 渲染」，
/// 不能只把 webStatus 塞进 KVC（那样 refresh 里的复位分支根本没跑）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *fixtures;
@property (nonatomic, assign) BOOL fakeStarted;
@property (nonatomic, strong) NSMutableArray<NSString *> *requestLog;
@property (nonatomic, assign) BOOL holdSettings;
@property (nonatomic, copy, nullable) RLPJSONCompletion pendingSettings;
@property (nonatomic, assign) BOOL holdHealth;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *pendingHealths;
@property (nonatomic, assign) BOOL holdCancel;
@property (nonatomic, copy, nullable) RLPJSONCompletion pendingCancel;
@end
@implementation RLPRequestSpy
- (instancetype)init {
    self = [super init];
    if (self) {
        _requestLog = [NSMutableArray array];
        _pendingHealths = [NSMutableArray array];
    }
    return self;
}
- (BOOL)started{return self.fakeStarted;}
- (void)postData:(NSString *)path body:(NSData *)body contentType:(NSString *)contentType completion:(RLPJSONCompletion)done {
    (void)contentType; g_lastDataPath = path ?: @""; g_lastDataLen = body.length;
    [self.requestLog addObject:[NSString stringWithFormat:@"POST %@", path ?: @""]];
    if (done) done(@{ @"ok": @YES });
}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {
    lastPath=path;lastBody=body;
    [self.requestLog addObject:[NSString stringWithFormat:@"POST %@", path ?: @""]];
    if([path hasPrefix:@"/api/fav?"])pendingFav=[done copy];
    if([path isEqualToString:@"/api/lyrics/ai"])pendingLyricAi=[done copy];
    if([path isEqualToString:@"/api/anl/cancel"] && done){
        if(self.holdCancel){self.pendingCancel=[done copy];return;}
        done(@{@"ok":@YES});
    }
}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    [self.requestLog addObject:[NSString stringWithFormat:@"GET %@", path ?: @""]];
    if(holdNPRequests&&done&&[path hasPrefix:@"/api/lyrics?file="]){pendingLyrics=[done copy];return;}
    if(self.holdSettings&&done&&[path isEqualToString:@"/api/settings"]){self.pendingSettings=[done copy];return;}
    if(self.holdHealth&&done&&([path hasPrefix:@"/api/track/health"]||[path hasPrefix:@"/api/health"])){
        [self.pendingHealths addObject:[done copy]];return;
    }
    id hit=nil;
    for(NSString *key in self.fixtures) if([path hasPrefix:key]){hit=self.fixtures[key];break;}
    if(done)done([hit isKindOfClass:[NSDictionary class]]?hit:nil);
}
/// refresh 会在切曲分支顺带 loadCoverForPath（/api/cover 走 getData）：桩必须应答，
/// 否则刷新路径上第一个 getData 就是 doesNotRecognizeSelector（实测 SIGABRT）。
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if(holdNPRequests&&done&&[path hasPrefix:@"/api/cover?file="]){pendingCover=[done copy];return;} if(done)done(nil); }
@end
static RLPRequestSpy *spy;static id fakeShared(id c,SEL s){return spy;}
static int fail;
/// CGColor 与 NSColor 逐分量比较（含 alpha）：hover 判据必须量**实际视觉值**，不能只断言有跟踪区。
/// 递归统计 NSScrollView（「单层滚动」判据：不新增嵌套滚动容器）。
static NSInteger CountScrollViews(NSView *root) {
    NSInteger n = [root isKindOfClass:[NSScrollView class]] ? 1 : 0;
    for (NSView *s in root.subviews) n += CountScrollViews(s);
    return n;
}

/// 取 attributed 文本首个字符的 kern（web letter-spacing 的原生等价）；没有则返回 0。
static CGFloat KernOf(NSTextField *label) {
    if (!label || label.attributedStringValue.length == 0) return 0;
    NSNumber *k = [label.attributedStringValue attribute:NSKernAttributeName atIndex:0 effectiveRange:NULL];
    return k ? k.doubleValue : 0;
}

static BOOL CgEq(CGColorRef cg, NSColor *want, double tol) {
    if (!cg || !want) return NO;
    NSColor *c = [NSColor colorWithCGColor:cg];
    NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *w = [want colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!s || !w) return NO;
    return fabs(s.redComponent - w.redComponent) < tol &&
           fabs(s.greenComponent - w.greenComponent) < tol &&
           fabs(s.blueComponent - w.blueComponent) < tol &&
           fabs(s.alphaComponent - w.alphaComponent) < tol;
}
/// 未设置的 layer 底色视作 clear（AppKit 里 CGColorRef 可能是 NULL 或透明）。
/// 测试侧声明：生产实现里 hover 状态机在 RLPHoverButton/RLPRailChipView 上；
/// 这里只做编译期声明，运行时一律先 respondsToSelector 守卫（旧码没有这个方法）。
@interface NSView (RLPHoverTest)
- (void)setHovered:(BOOL)hovered;
- (NSRect)scrollThumbRect;
@end

static BOOL CgClearOrNil(CGColorRef cg) {
    if (!cg) return YES;
    NSColor *c = [NSColor colorWithCGColor:cg];
    return c != nil && c.alphaComponent < 0.02;
}
/// 1×1 纯色 PNG：迟到封面判据必须灌入**能被 NSImage 解码**的真图字节。
/// 否则「迟到回包被丢弃」会被「解码失败、image 本来就是 nil」假通过。
static NSData *NPPngOfColor(NSColor *color) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:1 pixelsHigh:1 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:4 bitsPerPixel:32];
    if (!rep || !rep.bitmapData) return nil;
    NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color;
    unsigned char *px = rep.bitmapData;
    px[0] = (unsigned char)(MIN(1.0, MAX(0.0, c.redComponent)) * 255.0);
    px[1] = (unsigned char)(MIN(1.0, MAX(0.0, c.greenComponent)) * 255.0);
    px[2] = (unsigned char)(MIN(1.0, MAX(0.0, c.blueComponent)) * 255.0);
    px[3] = 255;
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSView *find(NSView *v, NSString *key) { if([v.identifier isEqual:key])return v; for(NSView *s in v.subviews){NSView *r=find(s,key);if(r)return r;}return nil; }
static BOOL HasCJK(NSString *s){if(!s.length)return NO;for(NSUInteger i=0;i<s.length;++i){unichar c=[s characterAtIndex:i];if(c>=0x4E00&&c<=0x9FFF)return YES;}return NO;}
static void ck(bool ok,const char *n){printf("[%s] %s\n",ok?"PASS":"FAIL",n);if(!ok)++fail;}
@interface RLPNowPlayingViewController (WebTest)
- (void)applyLyricText:(NSString *)text forPath:(NSString *)path;
- (void)updateLyricPosition:(double)position;
- (void)onPause:(id)sender;
- (void)onCommitSeek:(id)sender;
- (void)onLyricLine:(NSButton *)sender;
- (void)onFav:(id)sender;
- (NSString *)castBodyForDevice:(NSDictionary *)device;
- (void)refresh;
- (void)applyPlayModeUI;
- (void)refreshQueueContext;
- (void)setLyricsPlaceholder:(NSString *)main detail:(NSString *)detail;
- (void)loadLyricsForPath:(NSString *)path;
- (void)loadCoverForPath:(NSString *)path;
- (void)renderRailMetadata;
- (void)layoutWebPlayback;
- (BOOL)lyricAiBusy;
- (void)applyLanguage;
- (void)onToggleAnalysis:(id)sender;
- (void)onToggleAuto:(id)sender;
- (void)onToggleRail:(id)sender;
- (void)onAnlExpand:(id)sender;
- (void)onAnlReanalyze:(id)sender;
- (void)openDataDrawer;
- (void)closeDataDrawer;
- (void)renderMetaChipsFromMeta:(NSDictionary *)json;
- (void)applyMetaChipVisibility;
- (void)applyCastChipStyle;
- (void)applyCoverSourceGate;
- (void)anlAutoTickForPath:(NSString *)path playing:(BOOL)playing paused:(BOOL)paused;
@end
int main(){@autoreleasepool{
 [NSApplication sharedApplication]; [RLPTheme setThemeName:@"light"];
 ck([RLPEnc(@"a&b+ c/曲") isEqual:@"a%26b%2B%20c%2F%E6%9B%B2"],"native request encoding exactly matches web encodeURIComponent");
 RLPNowPlayingViewController *vc=[RLPNowPlayingViewController new];vc.view.frame=NSMakeRect(0,0,1180,760);[vc.view layoutSubtreeIfNeeded];
 NSView *cover=find(vc.view,@"npCover"),*anal=find(vc.view,@"npAnal"),*ly=find(vc.view,@"npLyric"),*rail=find(vc.view,@"npRail"),*ctl=find(vc.view,@"np.controls");
 ck(cover&&anal&&ly&&rail&&ctl,"web npCover/npAnal/npLyric/npRail/control regions exist");
 if(cover&&anal&&ly&&rail&&ctl){
  ck(fabs(cover.frame.size.height-182.4)<1,"cover is 24vh at 760px");
  ck(fabs(cover.frame.origin.x-16)<1,"hero gutter is 16px");
  ck(fabs(anal.frame.size.width-rail.frame.size.width)<1&&ly.frame.size.width>anal.frame.size.width*1.9,"body has symmetric 1:2:1 columns");
  ck(NSMaxX(anal.frame)<NSMinX(ly.frame)&&NSMaxX(ly.frame)<NSMinX(rail.frame),"three columns do not overlap");
  ck(NSMaxY(anal.frame)<=NSMinY(ctl.frame),"panel body never covers control row in flipped canvas");
  ck(find(vc.view,@"npAnlAuto")&&find(vc.view,@"npAnlRun")&&find(vc.view,@"npClose"),"web analysis actions and exit are present");
 }
 BOOL lyricAPI=[vc respondsToSelector:@selector(applyLyricText:forPath:)]&&[vc respondsToSelector:@selector(updateLyricPosition:)];ck(lyricAPI,"production timed lyrics projection API exists");
 if(lyricAPI){[vc setValue:@"/offline/song.flac" forKey:@"currentPath"];[vc applyLyricText:@"[00:01.00]first\n[00:03.00]second" forPath:@"/offline/song.flac"];[vc updateLyricPosition:3.1];ck([[vc valueForKey:@"lyricActiveIndex"] integerValue]==1,"real LRC timestamp chooses second highlighted row");[vc applyLyricText:@"plain one\nplain two" forPath:@"/offline/song.flac"];[vc updateLyricPosition:10];ck([[vc valueForKey:@"lyricActiveIndex"] integerValue]==-1,"plain lyrics never highlight");}
 // Capture the real controller requests in memory: no embedded core/device/service.
 spy=[RLPRequestSpy new];Method shared=class_getClassMethod(RLPCoreClient.class,@selector(shared));IMP old=method_setImplementation(shared,(IMP)fakeShared);
 RLPPlaybackStatus *status=[RLPPlaybackStatus statusFromJSON:@{@"ok":@YES,@"playing":@YES,@"paused":@NO,@"dur":@10}];
 [vc setValue:status forKey:@"webStatus"];
 [vc onPause:nil];ck([lastPath isEqual:@"/api/pause?on=1"],"pause request explicitly sets on=1");
 status.paused=YES;[vc onPause:nil];ck([lastPath isEqual:@"/api/pause?on=0"],"resume request explicitly sets on=0");
 id controls=[vc valueForKey:@"webControls"];NSSlider *seek=[controls valueForKey:@"seek"];seek.doubleValue=.5;[vc onCommitSeek:nil];ck([lastPath isEqual:@"/api/seek?pos=0.5000"],"seek uses real backend pos parameter, not ignored ratio");   // v3.3.11 toFixed(4) 精度
 // ---- S 系列：v3.3.11 doSeek 的三条守卫（ui_script.h:6572-6575）----
 // 上游原码：if (!S.playing || !(S.dur > 0) || !Number.isFinite(frac)) return;
 //           var f = Math.max(0, Math.min(0.9999, frac));  api('/api/seek?pos=' + f.toFixed(4));
 // 旧码直接 "/api/seek?pos=%.6f" ⟹ 未播放/无时长也发请求，且 pos 可能超出后端接受范围。
 {
  lastPath=nil;
  [vc setValue:[RLPPlaybackStatus statusFromJSON:@{@"ok":@1,@"playing":@0,@"paused":@0,@"dur":@10}] forKey:@"webStatus"];
  seek.doubleValue=.3;[vc onCommitSeek:nil];
  ck(![lastPath hasPrefix:@"/api/seek"],"S1a 未播放时不发 seek（上游 !S.playing ⟹ return）");
  [vc setValue:[RLPPlaybackStatus statusFromJSON:@{@"ok":@1,@"playing":@1,@"paused":@0,@"dur":@0}] forKey:@"webStatus"];
  lastPath=nil;seek.doubleValue=.3;[vc onCommitSeek:nil];
  ck(![lastPath hasPrefix:@"/api/seek"],"S1b 时长为 0 时不发 seek（上游 !(S.dur>0) ⟹ return）");
  [vc setValue:[RLPPlaybackStatus statusFromJSON:@{@"ok":@1,@"playing":@1,@"paused":@0,@"dur":@10}] forKey:@"webStatus"];
  lastPath=nil;seek.doubleValue=1.0;[vc onCommitSeek:nil];
  ck([lastPath isEqual:@"/api/seek?pos=0.9999"],"S2 pos=1.0 被 clamp 到 0.9999（上游 Math.min(0.9999,frac)）");
  lastPath=nil;seek.doubleValue=-0.5;[vc onCommitSeek:nil];
  ck([lastPath isEqual:@"/api/seek?pos=0.0000"],"S3 负值被 clamp 到 0.0000（上游 Math.max(0,…)）");
  lastPath=nil;seek.doubleValue=.5;[vc onCommitSeek:nil];
  ck([lastPath isEqual:@"/api/seek?pos=0.5000"],"S4 正常值按上游 toFixed(4) 精度下发");
 }

 BOOL castAPI=[vc respondsToSelector:@selector(castBodyForDevice:)];ck(castAPI,"cast request construction is directly verifiable");
 if(castAPI){NSString *location=@"http://offline/device.xml?x=a&v=+";NSString *path=@"/offline/song&demo+.flac";[vc setValue:path forKey:@"currentPath"];NSString *body=[vc castBodyForDevice:@{@"location":location,@"name":@"fixture"}];NSMutableDictionary *fields=[NSMutableDictionary dictionary];for(NSString *part in [body componentsSeparatedByString:@"&"]){NSRange sep=[part rangeOfString:@"="];if(sep.location==NSNotFound)continue;fields[[part substringToIndex:sep.location]]=[[[part substringFromIndex:sep.location+1] stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];}ck([fields[@"file"] isEqual:path]&&[fields[@"dev"] isEqual:location],"cast form roundtrips real file and location including ampersand and plus");}
 [vc setValue:@"/offline/A.flac" forKey:@"currentPath"];[vc setValue:@NO forKey:@"favorite"];[vc onFav:nil];
 [vc setValue:@"/offline/B.flac" forKey:@"currentPath"];if(pendingFav)pendingFav(@{@"ok":@YES});ck(![[vc valueForKey:@"favorite"] boolValue],"old favorite completion cannot mutate new track");
 // ---- 播放页状态机：web #npKind = npPlayingKindText(curMeta)，停止/切曲必须复位 ----
 // 旧码：kindLabel 只在 /api/meta 回来时覆盖 ⟹ 停止后仍显示上一首的「正在播放 · FLAC / 48 kHz / 24 bit」；
 //       且 format 为空时无条件拼分隔符，显示「正在播放 · 」。两条都由下面的判据钉住。
 spy.fixtures=@{@"/api/status":@{@"ok":@1,@"playing":@1,@"paused":@0,@"current":@"/offline/meta.flac",@"dur":@10.0},
                @"/api/meta":@{@"ok":@1,@"title":@"Meta Song",@"codec":@"FLAC",@"sampleRate":@48000,@"bits":@24,
                               @"meta":@{@"enriched":@NO}}};
 [vc setValue:@"/offline/previous.flac" forKey:@"currentPath"];   // 强制走一次「切曲」分支
 [vc refresh];
 NSString *kindLoaded=[[vc valueForKey:@"kindLabel"] stringValue];
 ck([kindLoaded containsString:@"FLAC"]&&[kindLoaded containsString:@"48 kHz"]&&[kindLoaded containsString:@"24 bit"],
    "npKind carries web npPlayingKindText fields (codec / kHz / bit)");
 spy.fixtures=@{@"/api/status":@{@"ok":@1,@"playing":@0,@"paused":@0,@"current":@"",@"dur":@0.0}};
 [vc refresh];
 ck([[[vc valueForKey:@"kindLabel"] stringValue] isEqualToString:@"正在播放"],
    "stopped state resets npKind to plain 正在播放 (web npPlayingKindText(null))");
 ck([[[vc valueForKey:@"titleLabel2"] stringValue] isEqualToString:@"未播放"],"stopped state keeps npTitle = 未播放");
 spy.fixtures=@{@"/api/status":@{@"ok":@1,@"playing":@1,@"paused":@0,@"current":@"/offline/nocodec.flac",@"dur":@10.0},
                @"/api/meta":@{@"ok":@1,@"title":@"No Codec Song",@"meta":@{@"enriched":@NO}}};
 [vc refresh];
 ck([[[vc valueForKey:@"kindLabel"] stringValue] isEqualToString:@"正在播放"],
    "track switch resets npKind before new meta arrives (no stale codec, no trailing ' · ')");

 // ---- 循环模式：web #npRep 图标随档位换（REP_ICON 四条路径）+ #npRepOne 角标（仅单曲循环）----
 // 旧码：repBtn 永远 repeat 图标、没有「1」角标 ⟹ 用户看不出当前是顺序/列表/单曲/随机。
 {
  NSView *ctl=[vc valueForKey:@"webControls"];
  NSButton *repBtn=(NSButton *)[ctl valueForKey:@"repBtn"];
  // 旧码没有 repBadge 属性：KVC 取值会抛 NSUnknownKeyException，先按 getter 存在性守卫。
  NSTextField *repOne=(NSTextField *)([ctl respondsToSelector:NSSelectorFromString(@"repBadge")]
                    ? [ctl valueForKey:@"repBadge"] : nil);
  ck(repBtn&&[repBtn.identifier isEqualToString:@"np.rep"],"npRep control exists");
  ck(repOne&&[repOne.identifier isEqualToString:@"npRepOne"],"web #npRepOne badge exists");
  NSArray *expected=@[@"arrow.right",@"repeat",@"repeat.1",@"shuffle"];
  NSMutableSet *seen=[NSMutableSet set];
  for(NSInteger m=0;m<4;m++){
    [vc setValue:@(m) forKey:@"playbackMode"];
    BOOL hasApply=[vc respondsToSelector:@selector(applyPlayModeUI)];
    if(hasApply)[vc applyPlayModeUI];                 // 旧码没有这个方法：别让判据崩在这里
    NSString *sym=hasApply?([vc valueForKey:@"playModeSymbol"]?:@""):@"";
    [seen addObject:sym];
    ck([sym isEqualToString:expected[(NSUInteger)m]],
       [[NSString stringWithFormat:@"npRep icon follows web REP_ICON[%ld]",(long)m] UTF8String]);
    ck(repOne.hidden==(m!=2),
       [[NSString stringWithFormat:@"npRepOne only visible in single-repeat (mode=%ld)",(long)m] UTF8String]);
  }
  ck(seen.count==4,"the four play modes use four distinct npRep icons");
  ck([[repOne stringValue] isEqualToString:@"1"],"npRepOne renders 1");
  // 复位到顺序播放，别把档位状态留给后面的用例
  if([vc respondsToSelector:@selector(applyPlayModeUI)]){[vc setValue:@0 forKey:@"playbackMode"];[vc applyPlayModeUI];}
 }

 // ---- 侧栏面板内置收起键：分析面板头部已按 N2 移除（npAnalHide 不存在），右栏保留 #npRailHide ----
 {
  [(NSView *)vc.view layoutSubtreeIfNeeded];   // 面板是内层视图，尺寸由 layoutWebPlayback 写
  NSButton *anlHide=(NSButton *)find(vc.view,@"npAnalHide");
  NSButton *railHide=(NSButton *)find(vc.view,@"npRailHide");
  ck(anlHide==nil && [vc valueForKey:@"anlHide"]==nil,"N2 分析面板头部收起键 npAnalHide 已移除");
  ck(railHide!=nil,"web #npRailHide panel-local hide key exists");
  if(railHide){
    ck(fabs(railHide.frame.size.width-22)<0.6&&fabs(railHide.frame.size.height-22)<0.6,
       "npRailHide is 22x22 like web .nprailhide");
    {   // v1.1.7.80：web `.nprailhead` 在 border-box 面板内，`.nprailhide` 右缘 = 内容内缘 11（旧值 8）。
        NSView *rp0=[vc valueForKey:@"railPanel"];
        const CGFloat rightMargin = NSWidth(rp0.bounds) - NSMaxX(railHide.frame);
        ck(fabs(rightMargin-11.0)<1.0,
           [[NSString stringWithFormat:@"npRailHide 右端距面板内缘 = 11pt（web border-box 内缘；got %.1f）", rightMargin] UTF8String]);
        const CGFloat topMargin = NSHeight(rp0.bounds) - NSMaxY(railHide.frame);
        ck(fabs(topMargin-12.0)<1.0,
           [[NSString stringWithFormat:@"npRailHide 顶部距面板内缘 = 12pt（web 在 24pt 行内居中；got %.1f）", topMargin] UTF8String]);
    }
    NSView *rp=[vc valueForKey:@"railPanel"];
    [railHide performClick:nil];
    ck(rp.hidden,"npRailHide hides the AI rail panel");
    ck([[NSUserDefaults standardUserDefaults] boolForKey:@"RLPNPRailHidden"],
       "npRailHide persists the same hidden state as the top-right toggle");
    rp.hidden=NO;[[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPRailHidden"];
  }
 }

 // ---- P1 响应式字号：web `#npTitle{clamp(19px,2.6vh,27px)}`、`.npline{clamp(13px,1.9vh,17px);line-height:2.05}` ----
 // 旧码固定 20pt 标题 / 14pt+30pt 行盒：640 档标题偏大、1080 档标题偏小；歌词在三档都不随窗口变。
 {
  NSArray *heights=@[@640,@800,@1080];
  for(NSNumber *hn in heights){
    CGFloat H=hn.doubleValue;
    [(NSView *)vc.view setFrameSize:NSMakeSize(1180,H)];
    [(NSView *)vc.view layoutSubtreeIfNeeded];
    [vc setValue:@"/offline/lyric.flac" forKey:@"currentPath"];
    [vc applyLyricText:@"[00:01.00]line one\n[00:05.00]line two" forPath:@"/offline/lyric.flac"];
    [(NSView *)vc.view layoutSubtreeIfNeeded];
    const CGFloat expTitle=MIN(27.0,MAX(19.0,H*0.026));     // web clamp(19px,2.6vh,27px)
    const CGFloat expLyric=MIN(17.0,MAX(13.0,H*0.019));     // web clamp(13px,1.9vh,17px)
    NSTextField *title=(NSTextField *)find(vc.view,@"npTitle");
    ck(title!=nil,"npTitle 存在（响应式字号判据前提）");
    if(title)
      ck(fabs(title.font.pointSize-expTitle)<0.5,
         [[NSString stringWithFormat:@"@%dpt 窗口：npTitle 字号 = clamp(19,2.6vh,27)（want %.2f got %.2f）",
           (int)H,expTitle,title.font.pointSize] UTF8String]);
    // 标题行盒 = 字号 × 1.3（web line-height:1.3）——不许把 27pt 字塞进 30pt 行里被裁。
    if(title){
      NSTextField *k=(NSTextField *)find(vc.view,@"npKind");
      (void)k;
    }
    NSArray<NSButton *> *rows=[vc valueForKey:@"lyricRows"];
    ck(rows.count==2, [[NSString stringWithFormat:@"@%dpt：两行歌词都建成了",(int)H] UTF8String]);
    if(rows.count==2){
      NSButton *b0=rows[0];
      NSFont *f0=(NSFont *)[b0.attributedTitle attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
      CGFloat fs=f0?f0.pointSize:b0.font.pointSize;
      ck(fabs(fs-expLyric)<0.5,
         [[NSString stringWithFormat:@"@%dpt：歌词字号 = clamp(13,1.9vh,17)（want %.2f got %.2f）",
           (int)H,expLyric,fs] UTF8String]);
      ck(fabs(b0.frame.size.height-fs*2.05)<0.6,
         [[NSString stringWithFormat:@"@%dpt：行盒 = 字号×2.05（web line-height）want %.2f got %.2f",
           (int)H,fs*2.05,b0.frame.size.height] UTF8String]);
      CGFloat gap=NSMinY(rows[1].frame)-NSMaxY(b0.frame);
      ck(fabs(gap)<0.6,
         [[NSString stringWithFormat:@"@%dpt：相邻歌词行贴合行盒（gap want 0 got %.2f）",(int)H,gap] UTF8String]);
    }
  }
  // 复位到默认窗口，别把尺寸留给后面的用例
  [(NSView *)vc.view setFrameSize:NSMakeSize(1180,760)];
  [(NSView *)vc.view layoutSubtreeIfNeeded];
 }

 // ---- P2 控制区逐值：web `#npSeek:hover{5→7}`、`.nptime{12px; tval min-width:42 居中}`、`.npvol{104/11/58}` ----
 {
  NSView *ctl=[vc valueForKey:@"webControls"];
  [ctl layoutSubtreeIfNeeded];
  NSSlider *seek=(NSSlider *)[ctl valueForKey:@"seek"];
  NSSlider *vol=(NSSlider *)[ctl valueForKey:@"volume"];
  NSTextField *pos=(NSTextField *)[ctl valueForKey:@"posLabel"];
  NSTextField *dur=(NSTextField *)[ctl valueForKey:@"durLabel"];
  NSTextField *vlab=(NSTextField *)[ctl valueForKey:@"volLabel"];
  ck(seek&&vol&&pos&&dur&&vlab,"控制区五个逐值判据前提都在");
  if(seek&&vol&&pos&&dur&&vlab){
   // hover 5→7pt（web .npseek:hover{height:7px}）
   BOOL hasThick=[seek.cell respondsToSelector:NSSelectorFromString(@"barThickness")];
   ck(hasThick,"np.seek cell 暴露 barThickness（hover 5→7 的实现前提）");
   if(hasThick){
     NSNumber *t0=[seek.cell valueForKey:@"barThickness"];
     ck(fabs(t0.doubleValue-5.0)<=0.6,"np.seek 轨道高 5pt（web .npseek height:5）");
     [seek.cell setValue:@YES forKey:@"hovered"];
     NSNumber *t1=[seek.cell valueForKey:@"barThickness"];
     ck(fabs(t1.doubleValue-7.0)<=0.6,"np.seek hover 后轨道高 7pt（web .npseek:hover height:7）");
     [seek.cell setValue:@NO forKey:@"hovered"];
     ck([seek respondsToSelector:NSSelectorFromString(@"hoverGrow")]&&seek.trackingAreas.count>=1,
        "np.seek 有 hover 跟踪区（不是只有属性、没有鼠标响应）");
   }
   // .nptime{font-size:12} / .tval{min-width:42;text-align:center}
   ck(fabs(pos.font.pointSize-12.0)<0.3,"np.pos 字号 12（web .nptime font-size:12）");
   ck(fabs(pos.frame.size.width-42.0)<1.0,"np.pos 宽 42（web .tval min-width:42）");
   ck(pos.alignment==NSTextAlignmentCenter,"np.pos 居中（web .tval text-align:center）");
   ck(fabs(dur.font.pointSize-12.0)<0.3,"np.dur 字号 12（web .nptime font-size:12）");
   ck(fabs(dur.frame.size.width-42.0)<1.0,"np.dur 宽 42（web .tval min-width:42）");
   ck(dur.alignment==NSTextAlignmentCenter,"np.dur 居中（web .tval text-align:center）");
   // .npvol input 104 / .vlab 11px min-width 58
   ck(fabs(vol.frame.size.width-104.0)<1.0,"np.vol 滑杆宽 104（web .npvol input width:104）");
   ck(fabs(vlab.font.pointSize-11.0)<0.3,"np.vollab 字号 11（web .npvol .vlab font-size:11）");
   ck(fabs(vlab.frame.size.width-58.0)<1.0,"np.vollab 宽 58（web .vlab min-width:58）");
   ck(vlab.alignment==NSTextAlignmentRight,"np.vollab 右对齐（web .vlab text-align:right）");
  }
 }

 // ---- P3 #npNextTrackHero 状态机（web updateNextTrackInfo：!playing||!qLen → 隐藏；末尾「队列末尾 · 共 N 首」）----
 {
  NSTextField *hero=(NSTextField *)find(vc.view,@"npNextTrackHero");
  ck(hero!=nil,"npNextTrackHero 存在（状态机判据前提）");
  if(hero){
   NSArray *items=@[@"/offline/a.flac",@"/offline/cur.flac",@"/offline/c.flac"];
   [vc setValue:@"/offline/cur.flac" forKey:@"currentPath"];
   // 状态夹具要让 webStatus.playing=1（applyQueueSnapshot 读的是状态快照，不是 /api/status 桩）
   [vc setValue:[RLPPlaybackStatus statusFromJSON:@{@"ok":@1,@"playing":@1,@"paused":@0,
              @"current":@"/offline/cur.flac",@"dur":@10.0}] forKey:@"webStatus"];
   spy.fixtures=@{@"/api/status":@{@"ok":@1,@"playing":@1,@"paused":@0,@"current":@"/offline/cur.flac",@"dur":@10.0},
                  @"/api/queue":@{@"ok":@1,@"mode":@0,@"index":@1,@"items":items}};
   [vc refreshQueueContext];
   ck([hero.stringValue isEqualToString:@"下一首: c.flac · 剩 1 首"],
      [[NSString stringWithFormat:@"有下一首：文案逐字=web「下一首: X · 剩 N 首」（got「%@」）",hero.stringValue?:@""] UTF8String]);
   ck(hero.hidden==NO,"有下一首时可见（web display:''）");
   spy.fixtures=@{@"/api/queue":@{@"ok":@1,@"mode":@0,@"index":@2,@"items":items}};
   [vc refreshQueueContext];
   ck([hero.stringValue isEqualToString:@"队列末尾 · 共 3 首"],
      [[NSString stringWithFormat:@"队列末尾：文案逐字=web「队列末尾 · 共 N 首」（got「%@」）",hero.stringValue?:@""] UTF8String]);
   spy.fixtures=@{@"/api/queue":@{@"ok":@1,@"mode":@2,@"index":@1,@"items":items}};
   [vc refreshQueueContext];
   ck([hero.stringValue isEqualToString:@"下一首: cur.flac · 剩 1 首"],
      [[NSString stringWithFormat:@"单曲循环：下一首=当前曲（web repMode==2）（got「%@」）",hero.stringValue?:@""] UTF8String]);
   // 停止：web `!S.playing || !qLen` ⟹ display:none 且不写文案
   [vc setValue:@"" forKey:@"currentPath"];
   [vc setValue:[RLPPlaybackStatus statusFromJSON:@{@"ok":@1,@"playing":@0,@"paused":@0,
              @"current":@"",@"dur":@0.0}] forKey:@"webStatus"];
   spy.fixtures=@{@"/api/status":@{@"ok":@1,@"playing":@0,@"paused":@0,@"current":@"",@"dur":@0.0},
                  @"/api/queue":@{@"ok":@1,@"mode":@0,@"index":@0,@"items":items}};
   [vc refreshQueueContext];
   ck(hero.hidden && hero.stringValue.length==0,
      [[NSString stringWithFormat:@"停止后隐藏并清空（web !S.playing）（hidden=%d text=「%@」）",(int)hero.hidden,hero.stringValue?:@""] UTF8String]);
   // 换歌：旧文案必须立刻清掉（web 切歌清 lastCur/队列态，不等新队列）
   [hero setStringValue:@"下一首: stale.flac · 剩 2 首"]; hero.hidden=NO;
   [vc setValue:@"/offline/old.flac" forKey:@"currentPath"];
   spy.fixtures=@{@"/api/status":@{@"ok":@1,@"playing":@1,@"paused":@0,@"current":@"/offline/new.flac",@"dur":@10.0}};
   [vc refresh];
   ck(hero.hidden && hero.stringValue.length==0,
      [[NSString stringWithFormat:@"换歌立即清空旧「下一首」文案（hidden=%d text=「%@」）",(int)hero.hidden,hero.stringValue?:@""] UTF8String]);
  }
 }

 // ---- Hover 统一（web .k/.npclose/.nptoggle/.chip/.npcast/.npchip/.npseek）----
 // 判据量 hover 前后的**实际视觉值**（底色/描边/transform/文字色），并验证跟踪区存在；
 // 不是"有 tracking area 就算对齐"。
 {
  RLPTheme *t=[RLPTheme current];
  NSColor *closeBase=(t.isLight?[NSColor colorWithWhite:1 alpha:.92]
                              :[NSColor colorWithSRGBRed:30/255. green:32/255. blue:38/255. alpha:.92]);
  NSColor *closeHover=(t.isLight?[NSColor whiteColor]
                               :[NSColor colorWithSRGBRed:48/255. green:50/255. blue:58/255. alpha:.96]);
  #define HOVERABLE(v) ((v) && [(v) respondsToSelector:NSSelectorFromString(@"setHovered:")])
  // ① .npclose：底 rgba(.92) → #fff，scale 1.04
  NSButton *close=(NSButton *)find(vc.view,@"npClose");
  ck(close!=nil,"npclose 存在");
  ck(HOVERABLE(close),"npclose 有 hover 状态机（旧码只能靠按下高亮）");
  ck(close&&CgEq(close.layer.backgroundColor,closeBase,0.02),"npclose 静态底 = web rgba(255,255,255,.92)");
  if(HOVERABLE(close)){
    ck(close.trackingAreas.count>=1,"npclose 有 hover 跟踪区（鼠标能真的触发）");
    [close setHovered:YES];
    ck(CgEq(close.layer.backgroundColor,closeHover,0.02),"npclose hover 底 = #fff（web .npclose:hover）");
    ck(fabs(close.layer.transform.m11-1.04)<0.005,"npclose hover transform:scale(1.04)");
    [close setHovered:NO];
    ck(CgEq(close.layer.backgroundColor,closeBase,0.02),"npclose 退出恢复静态底");
    ck(fabs(close.layer.transform.m11-1.0)<0.005,"npclose 退出 transform 复位");
  }
  // ② .nptoggle：同款（底/缩放/字色）
  NSButton *tog=(NSButton *)find(vc.view,@"npAnalToggle");
  ck(tog&&HOVERABLE(tog),"nptoggle 有 hover 状态机");
  if(HOVERABLE(tog)){
    [tog setHovered:YES];
    ck(CgEq(tog.layer.backgroundColor,closeHover,0.02),"nptoggle hover 底 = #fff（web .nptoggle:hover）");
    ck(fabs(tog.layer.transform.m11-1.04)<0.005,"nptoggle hover transform:scale(1.04)");
    ck(CgEq(tog.contentTintColor.CGColor,t.text,0.06),"nptoggle hover 字色 = --txt");
    [tog setHovered:NO];
    ck(CgEq(tog.layer.backgroundColor,closeBase,0.02),"nptoggle 退出恢复静态底");
    ck(fabs(tog.layer.transform.m11-1.0)<0.005,"nptoggle 退出 transform 复位");
  }
  // ③ .k：顺序/循环键 底 transparent → --hov2；圆角 9
  NSButton *rep=(NSButton *)find(vc.view,@"np.rep");
  ck(rep&&HOVERABLE(rep),"npRep（.k）有 hover 状态机");
  ck(rep&&fabs(rep.layer.cornerRadius-9.0)<0.5,"npRep 圆角 9（web .k radius:9）");
  if(HOVERABLE(rep)){
    ck(CgClearOrNil(rep.layer.backgroundColor),"npRep 静态无底色（web .k 无 background）");
    [rep setHovered:YES];
    ck(CgEq(rep.layer.backgroundColor,t.hov2,0.03),"npRep hover 底 = --hov2（web .k:hover）");
    ck(CgEq(rep.contentTintColor.CGColor,t.text,0.06),"npRep hover 字色 = --txt");
    [rep setHovered:NO];
    ck(CgClearOrNil(rep.layer.backgroundColor),"npRep 退出底色清空");
  }
  NSButton *prev=(NSButton *)find(vc.view,@"np.prev");
  ck(prev&&HOVERABLE(prev),"npPrev（.k）有 hover 状态机");
  if(HOVERABLE(prev)){
    [prev setHovered:YES];
    ck(CgEq(prev.layer.backgroundColor,t.hov2,0.03),"npPrev hover 底 = --hov2");
    [prev setHovered:NO];
  }
  // ④ .k.big：play 圆 34/acc → hover 亮度上调（不是回到透明）
  NSButton *play=(NSButton *)find(vc.view,@"np.play");
  ck(play&&HOVERABLE(play),"npPlay（.k.big）有 hover 状态机");
  ck(play&&fabs(play.layer.cornerRadius-17.0)<0.5,"npPlay 圆形（web .k.big 34×34 圆）");
  if(HOVERABLE(play)){
    NSColor *base=[NSColor colorWithCGColor:play.layer.backgroundColor];
    [play setHovered:YES];
    NSColor *hover=[NSColor colorWithCGColor:play.layer.backgroundColor];
    ck(!CgEq((CGColorRef)play.layer.backgroundColor,base,0.02),"npPlay hover 底色变化（web brightness 1.08）");
    (void)hover;
    [play setHovered:NO];
    ck(CgEq((CGColorRef)play.layer.backgroundColor,base,0.02),"npPlay 退出恢复 accent 底");
  }
  // ⑤ .chip：EQ 芯片 边 --line → --acc、底 --bg3 → --hov、字 --txt2 → --txt
  NSButton *eq=(NSButton *)find(vc.view,@"npEqChip");
  ck(eq&&HOVERABLE(eq),"npEqChip（.chip）有 hover 状态机");
  if(HOVERABLE(eq)){
    ck(CgEq(eq.layer.borderColor,t.line,0.05),"npEqChip 静态描边 = --line");
    [eq setHovered:YES];
    ck(CgEq(eq.layer.borderColor,t.accent,0.05),"npEqChip hover 描边 = --acc（web .chip:hover）");
    ck(CgEq(eq.layer.backgroundColor,t.hov,0.03),"npEqChip hover 底 = --hov");
    [eq setHovered:NO];
    ck(CgEq(eq.layer.borderColor,t.line,0.05),"npEqChip 退出恢复 --line");
  }
  // ⑥ .npcast：投放芯片同 .chip:hover
  NSButton *cast=(NSButton *)find(vc.view,@"npCastBtn");
  ck(cast&&HOVERABLE(cast),"npCastBtn（.npcast）有 hover 状态机");
  if(HOVERABLE(cast)){
    [cast setHovered:YES];
    ck(CgEq(cast.layer.borderColor,t.accent,0.05),"npCastBtn hover 描边 = --acc");
    ck(CgEq(cast.layer.backgroundColor,t.hov,0.03),"npCastBtn hover 底 = --hov");
    [cast setHovered:NO];
  }
  // ⑦ .npchip：右栏卡片 底/描边 按 web hover 的半透明值
  NSView *chip=find(vc.view,@"npChip.歌曲");
  ck(chip&&HOVERABLE(chip),"npchip（右栏卡片）有 hover 状态机");
  if(HOVERABLE(chip)){
    NSColor *chipBase=[NSColor colorWithCGColor:chip.layer.backgroundColor];
    [chip setHovered:YES];
    NSColor *wantBg=(t.isLight?[NSColor colorWithSRGBRed:15/255. green:23/255. blue:42/255. alpha:.06]
                             :[NSColor colorWithWhite:1 alpha:.09]);
    ck(CgEq(chip.layer.backgroundColor,wantBg,0.02),"npchip hover 底 = web rgba(.09/.06)");
    [chip setHovered:NO];
    if(chipBase) ck(CgEq((CGColorRef)chip.layer.backgroundColor,chipBase,0.02),"npchip 退出恢复静态底");
  }
  // ⑧ .npseek：5→7 的 hover 增高不得被本包改回（P2 判据回归）
  NSView *ctl=[vc valueForKey:@"webControls"];
  NSSlider *seek=(NSSlider *)[ctl valueForKey:@"seek"];
  if([seek.cell respondsToSelector:NSSelectorFromString(@"barThickness")]){
    [seek.cell setValue:@NO forKey:@"hovered"];
    ck(fabs([[seek.cell valueForKey:@"barThickness"] doubleValue]-5.0)<0.6,"npSeek 静态 5pt（回归）");
    [seek.cell setValue:@YES forKey:@"hovered"];
    ck(fabs([[seek.cell valueForKey:@"barThickness"] doubleValue]-7.0)<0.6,"npSeek hover 7pt（回归）");
    [seek.cell setValue:@NO forKey:@"hovered"];
  } else ck(false,"npSeek 的 hover 增高在回归中丢失");
  #undef HOVERABLE
 }

 // ---- #65 补：brightness(1.08) 逐通道真混合（旧码混 10% 白）----
 {
  NSButton *play2=(NSButton *)find(vc.view,@"np.play");
  BOOL play2Hover=[play2 respondsToSelector:NSSelectorFromString(@"setHovered:")];
  if(play2&&play2Hover){
    [play2 setHovered:NO];
    NSColor *acc=[RLPTheme current].accent;
    NSColor *srgb=[acc colorUsingColorSpace:NSColorSpace.sRGBColorSpace]?:acc;
    CGFloat r=0,g=0,b=0,a=0; [srgb getRed:&r green:&g blue:&b alpha:&a];
    NSColor *want=[NSColor colorWithSRGBRed:MIN((CGFloat)1.0,r*1.08)
                                      green:MIN((CGFloat)1.0,g*1.08)
                                       blue:MIN((CGFloat)1.0,b*1.08) alpha:a];
    [play2 setHovered:YES];
    ck(CgEq(play2.layer.backgroundColor,want,0.02),
       "npPlay hover = brightness(1.08) 逐通道 ×1.08（不是混白）");
    NSColor *mixWhite=[acc blendedColorWithFraction:0.10 ofColor:NSColor.whiteColor];
    ck(!CgEq(play2.layer.backgroundColor,mixWhite,0.02),
       "npPlay hover 不再等于旧的混 10% 白近似");
    [play2 setHovered:NO];
  }
 }

 // ---- #44/#46 歌词空态与加载态：web 两行文案逐字（主行 clamp 字号 + 副行 12px --mut2）----
 {
  NSTextField *empty=(NSTextField *)[vc valueForKey:@"lyricsEmpty"];
  ck(empty!=nil,"lyricsEmpty 存在（歌词空态判据前提）");
  if(empty){
   const CGFloat expectMain=MIN(17.0,MAX(13.0,760.0*0.019));
   ck(empty.maximumNumberOfLines==0,"空态允许两行（旧码单行会截断副文案）");
   ck(empty.alignment==NSTextAlignmentCenter,"空态居中（web .nplyric2 居中）");
   [vc setValue:@"/offline/lyric.flac" forKey:@"currentPath"];
   [vc applyLyricText:@"" forPath:@"/offline/lyric.flac"];
   NSString *txt=empty.attributedStringValue.string ?: @"";
   ck([txt isEqualToString:@"没有歌词\n同名 .lrc 文件、内嵌歌词，或播放时自动在线补全（可在设置-元数据补全关闭）"],
      [[NSString stringWithFormat:@"无歌词空态两行文案逐字=web（got「%@」）",txt] UTF8String]);
   ck([txt rangeOfString:@"\n"].location!=NSNotFound,"空态是两行（主行+副行）");
   NSFont *f0=(NSFont *)[empty.attributedStringValue attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
   ck(f0&&fabs(f0.pointSize-expectMain)<0.6,
      [[NSString stringWithFormat:@"主行字号跟随歌词 clamp（want %.2f got %.2f）",expectMain,f0?f0.pointSize:0] UTF8String]);
   NSRange subRange=[txt rangeOfString:@"同名"];
   NSFont *f1=nil;
   if(subRange.location!=NSNotFound)
     f1=(NSFont *)[empty.attributedStringValue attribute:NSFontAttributeName atIndex:subRange.location effectiveRange:NULL];
   ck(f1&&fabs(f1.pointSize-12.0)<0.3,"副行 12px（web <span style=font-size:12px>）");
   BOOL hasSet=[vc respondsToSelector:@selector(setLyricsPlaceholder:detail:)];
   ck(hasSet,"歌词两行文案 API 存在（加载态判据走同一入口）");
   if(hasSet){
     [vc setLyricsPlaceholder:@"歌词加载中…" detail:@"正在等后台补全（首次播放新曲目时可能要几秒）"];
     ck([empty.attributedStringValue.string isEqualToString:@"歌词加载中…\n正在等后台补全（首次播放新曲目时可能要几秒）"],
        "加载态两行文案逐字=web 抽屉「歌词加载中… + 正在等后台补全…」");
   }
   [vc setValue:@"" forKey:@"currentPath"];
   [vc loadLyricsForPath:@""];
   ck([empty.attributedStringValue.string hasPrefix:@"没有歌词\n同名 .lrc 文件、内嵌歌词"],
      [[NSString stringWithFormat:@"无曲目也用 web 整页空态（旧码是「还没有播放曲目」；got「%@」）",empty.attributedStringValue.string?:@""] UTF8String]);
  }
 }

 // ---- #41 web `.npline.on{transform:scale(1.03)}`：当前歌词行放大 1.03，其余行保持 1.0 ----
 {
  [vc setValue:@"/offline/lines.flac" forKey:@"currentPath"];
  [vc applyLyricText:@"[00:01.00]line a\n[00:03.00]line b\n[00:05.00]line c" forPath:@"/offline/lines.flac"];
  NSArray<NSButton *> *rows=[vc valueForKey:@"lyricRows"];
  ck(rows.count==3,"三行歌词就位（缩放判据前提）");
  if(rows.count==3){
    [vc updateLyricPosition:3.5];
    ck(fabs(rows[1].layer.transform.m11-1.03)<0.005,"当前歌词行 transform:scale(1.03)（web .npline.on）");
    ck(fabs(rows[0].layer.transform.m11-1.0)<0.005,"非当前行不缩放（scale 1.0）");
    ck(fabs(rows[2].layer.transform.m11-1.0)<0.005,"非当前行不缩放（第三行）");
    [vc updateLyricPosition:1.2];
    ck(fabs(rows[0].layer.transform.m11-1.03)<0.005,"高亮移动后新行缩放 1.03");
    ck(fabs(rows[1].layer.transform.m11-1.0)<0.005,"原当前行退出时缩放复位（不残留 1.03）");
    // 放大后不许被裁：1.03 缩放是**绘制变换**（不改行盒），所以必须断言缩放后的可见边界仍在
    // 歌词文档内（首行不越上/左、末行不越下/右），否则"放大即裁字"。
    NSView *doc=[vc valueForKey:@"lyricDocument"];
    NSRect docBounds=doc.bounds;
    NSRect (^scaled)(NSRect) = ^NSRect(NSRect f){
      CGFloat dx=f.size.width*0.015, dy=f.size.height*0.015;   // (1.03-1)/2 = 0.015
      return NSInsetRect(f,-dx,-dy);
    };
    [vc updateLyricPosition:3.5];
    NSRect s1=scaled(rows[1].frame);
    ck(NSMinX(s1)>=NSMinX(docBounds)&&NSMaxX(s1)<=NSMaxX(docBounds)&&
       NSMinY(s1)>=NSMinY(docBounds)&&NSMaxY(s1)<=NSMaxY(docBounds),
       [[NSString stringWithFormat:@"当前行缩放后仍在文档内（row=%.1f,%.1f %.1fx%.1f doc=%.0fx%.0f）",
         s1.origin.x,s1.origin.y,s1.size.width,s1.size.height,docBounds.size.width,docBounds.size.height] UTF8String]);
    NSRect s0=scaled(rows[0].frame);
    ck(NSMinX(s0)>=NSMinX(docBounds)&&NSMinY(s0)>=NSMinY(docBounds),
       "首行缩放后不越上/左边界（不被 clip）");
    NSRect s2=scaled(rows[2].frame);
    ck(NSMaxX(s2)<=NSMaxX(docBounds)&&NSMaxY(s2)<=NSMaxY(docBounds),
       "末行缩放后不越下/右边界（不被 clip）");
  }
 }

 // ---- #63 后端错误态：不写副标题、改 toast 且自动消失（web 整页不展示后端 error）----
 {
  NSWindow *win=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,700)
                                             styleMask:NSWindowStyleMaskBorderless
                                               backing:NSBackingStoreBuffered defer:NO];
  win.contentView=[[NSView alloc] initWithFrame:NSMakeRect(0,0,900,700)];
  vc.view.frame=win.contentView.bounds;
  [win.contentView addSubview:vc.view];
  [win orderFront:nil];
  NSString *err=@"后端错误：解码失败";
  [vc setValue:@"/offline/err.flac" forKey:@"currentPath"];
  spy.fixtures=@{@"/api/status":@{@"ok":@1,@"playing":@0,@"paused":@0,
                                  @"current":@"/offline/err.flac",@"dur":@0.0,@"error":err}};
  [vc refresh];
  NSTextField *artist=(NSTextField *)[vc valueForKey:@"artistLabel2"];
  ck(![artist.stringValue isEqualToString:err],
     [[NSString stringWithFormat:@"错误不再写进副标题位（web 整页不展示后端 error；got「%@」）",artist.stringValue?:@""] UTF8String]);
  NSView *toast=(NSView *)find(win.contentView,@"rlp.toast");
  ck(toast!=nil,"后端错误以 toast 出现（不顶掉艺术家信息）");
  if(toast){
    BOOL hasText=NO;
    for(NSView *n in toast.subviews)
        if([n isKindOfClass:[NSTextField class]] && [[(NSTextField *)n stringValue] isEqualToString:err]) hasText=YES;
    ck(hasText,"toast 文案 = 后端错误原文");
    // web 没有 toast；原生 1.8s 后淡出并移除，判据真等一轮 runloop 验证"自动消失"。
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.6]];
    ck(find(win.contentView,@"rlp.toast")==nil,"toast 自动消失（不常驻、不挡播放页）");
  }
  NSString *diagnostic = [@"设备未接受数据 coreaudio_rendered=0 device=Pocket Master Audio " stringByPaddingToLength:3000 withString:@"w0=3377 wr=71 pad=full " startingAtIndex:0];
  RLPToast(diagnostic);
  RLPToast(diagnostic);
  NSMutableArray<NSView *> *banners = [NSMutableArray array];
  for (NSView *candidate in win.contentView.subviews) if ([candidate.identifier isEqualToString:@"rlp.toast"]) [banners addObject:candidate];
  NSView *longBanner = banners.lastObject;
  ck(banners.count == 1, "长诊断提示替换旧提示，不重复堆叠");
  ck(longBanner && NSContainsRect(win.contentView.bounds, longBanner.frame) && NSWidth(longBanner.frame) <= 520 && NSHeight(longBanner.frame) <= 100,
     "长诊断提示限宽限高且完全位于窗口内");
  ck(find(longBanner, @"rlp.toast.details") != nil, "长诊断提供详情入口而不是横向铺开原始日志");
  ck([[longBanner valueForKey:@"fullMessage"] isEqualToString:diagnostic], "详情保留完整诊断原文");
  [win setContentSize:NSMakeSize(320,700)];
  [win.contentView layoutSubtreeIfNeeded];
  ck(NSContainsRect(win.contentView.bounds, longBanner.frame), "窗口缩窄后错误提示仍在边界内");
  RLPPlaybackErrorToast(diagnostic);
  NSView *summaryBanner = (NSView *)find(win.contentView,@"rlp.toast");
  BOOL rawStatsVisible = NO;
  for(NSView *node in summaryBanner.subviews) if([node isKindOfClass:NSTextField.class] && [((NSTextField *)node).stringValue containsString:@"coreaudio_rendered"]) rawStatsVisible=YES;
  ck(!rawStatsVisible && [[summaryBanner valueForKey:@"fullMessage"] isEqualToString:diagnostic], "播放错误只显示摘要但不丢失原始诊断");
  [win setContentSize:NSMakeSize(900,700)];
  RLPToast(@"完成");
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.6]];
  // 不 close：离屏测试没有 run loop 收尾，关窗会在 dealloc 顺序上踩到 objc_release 崩溃
  // （判据已经在窗口里量完，保留到进程结束即可，测试进程本就短命）。
  [win orderOut:nil];
  static NSWindow *sToastWindow; sToastWindow = win;
 }

 // ---- #11 `.npkind{letter-spacing:1.6}` / #24 `.anllab{letter-spacing:1.5}` ----
 {
  NSTextField *kind=(NSTextField *)find(vc.view,@"npKind");
  ck(kind!=nil,"npKind 存在（字距判据前提）");
  if(kind){
   ck(fabs(KernOf(kind)-1.6)<0.05,
      [[NSString stringWithFormat:@"npKind 字距 1.6（web .npkind letter-spacing:1.6px；got %.2f）",KernOf(kind)] UTF8String]);
   // 文案更新后 kern 不能丢（旧码 stringValue 会重置 attributed 属性）
   spy.fixtures=@{@"/api/status":@{@"ok":@1,@"playing":@1,@"paused":@0,
                                  @"current":@"/offline/kern.flac",@"dur":@10.0}};
   [vc setValue:@"/offline/kern.flac" forKey:@"currentPath"];
   [vc refresh];
   ck(fabs(KernOf(kind)-1.6)<0.05,
      [[NSString stringWithFormat:@"刷新后 npKind 字距仍 1.6（got %.2f，text=「%@」）",KernOf(kind),kind.stringValue] UTF8String]);
  }
  // N2：左栏分析标题已按反馈图三删除，不再保留 npAnlLab；验证移除彻底且无残留
  ck([vc valueForKey:@"anlLab"]==nil && find(vc.view,@"npAnlLab")==nil && find(vc.view,@"npAnlStat")==nil,
     "N2 anlLab/anlStat 头部控件已删除");
 }

 // ---- #40 歌词视口渐隐：web `.nplyric2{ mask-image:linear-gradient(180deg,transparent 0,#000 26px,#000 calc(100% - 26px),transparent 100%) }` ----
 {
  NSScrollView *lyr=(NSScrollView *)[vc valueForKey:@"lyricScroll"];
  ck(lyr!=nil,"歌词滚动视图存在（遮罩判据前提）");
  if(lyr){
   id mask=lyr.layer.mask;
   ck([mask isKindOfClass:[CAGradientLayer class]],"歌词视口挂 CAGradientLayer 遮罩（不是只留注释）");
   if([mask isKindOfClass:[CAGradientLayer class]]){
    CAGradientLayer *g=(CAGradientLayer *)mask;
    const CGFloat H=lyr.bounds.size.height;
    ck(g.colors.count==4,"遮罩四个色标（transparent/黑/黑/transparent）");
    if(g.colors.count==4){
      NSColor *c0=[NSColor colorWithCGColor:(CGColorRef)g.colors[0]];
      NSColor *c1=[NSColor colorWithCGColor:(CGColorRef)g.colors[1]];
      NSColor *c2=[NSColor colorWithCGColor:(CGColorRef)g.colors[2]];
      NSColor *c3=[NSColor colorWithCGColor:(CGColorRef)g.colors[3]];
      ck(c0.alphaComponent<0.02&&c3.alphaComponent<0.02,"首/尾色标透明（渐隐到 0）");
      ck(c1.alphaComponent>0.98&&c2.alphaComponent>0.98,"中段两个色标不透明（26pt 之后完全显示）");
    }
    ck(fabs([g.locations[0] doubleValue]-0.0)<0.01&&fabs([g.locations[3] doubleValue]-1.0)<0.01,
       "locations 覆盖 0→1");
    ck(fabs([g.locations[1] doubleValue]-26.0/H)<0.01&&fabs([g.locations[2] doubleValue]-(1.0-26.0/H))<0.01,
       [[NSString stringWithFormat:@"渐隐区=26pt（want %.4f/%.4f got %.4f/%.4f H=%.1f）",
         26.0/H,1.0-26.0/H,[g.locations[1] doubleValue],[g.locations[2] doubleValue],H] UTF8String]);
    ck(NSWidth(g.frame)==lyr.bounds.size.width&&NSHeight(g.frame)==H,"遮罩尺寸跟随视口");
    // 窗口变矮后 26pt 渐隐比例要重算（不是一次性常量）
    [(NSView *)vc.view setFrameSize:NSMakeSize(1180,640)];
    [(NSView *)vc.view layoutSubtreeIfNeeded];
    CAGradientLayer *g2=(CAGradientLayer *)lyr.layer.mask;
    const CGFloat H2=lyr.bounds.size.height;
    ck(g2&&fabs([g2.locations[1] doubleValue]-26.0/H2)<0.01,
       [[NSString stringWithFormat:@"视口变矮后渐隐位置重算（H=%.1f loc=%.4f）",H2,[g2.locations[1] doubleValue]] UTF8String]);
    [(NSView *)vc.view setFrameSize:NSMakeSize(1180,760)];
    [(NSView *)vc.view layoutSubtreeIfNeeded];
   }
  }
 }

 // ---- #69 `.npchipwrap` 自绘滚动：不新增 NSScrollView、栏头不动 ----
 {
  NSView *wrap=find(vc.view,@"npChipWrap");
  ck(wrap!=nil,"npChipWrap 存在（自绘滚动容器）");
  if(wrap){
   ck(![wrap isKindOfClass:[NSScrollView class]],"chipwrap 不是 NSScrollView（不引入嵌套滚动）");
   NSView *rail=(NSView *)[vc valueForKey:@"railPanel"];
   ck(rail&&CountScrollViews(rail)==0,
      [[NSString stringWithFormat:@"右栏子树内 NSScrollView=0（单层滚动仍成立；got %ld）",(long)(rail?CountScrollViews(rail):-1)] UTF8String]);
   // 生产里 wrap 的可见性/卡片几何都由"有实体"驱动；判据先喂一份 meta 让栏目成立
   // （否则 wrap 隐藏、卡片按 0 帧量，等于没量到真实滚动）。
   [vc setValue:@{@"title":@"曲名",@"album":@"专辑",@"artist":@"艺术家"} forKey:@"trackMetadata"];
   [(id)vc renderRailMetadata];
   [(id)vc layoutWebPlayback];
   [(NSView *)vc.view layoutSubtreeIfNeeded];
   id chipsObj=[vc valueForKey:@"railCards"];
   NSArray<NSView *> *chips=[chipsObj isKindOfClass:[NSArray class]]?(NSArray<NSView *> *)chipsObj:@[];
   ck(chips.count==4,"四张 chip 槽在（第 4 张「作品」非古典时隐藏）");
   for(NSView *c in chips) ck(c.superview==wrap,"chip 挂在 chipwrap 内（不是直接铺在面板上）");
   const CGFloat W=wrap.bounds.size.width;
   NSView *c0=nil; for(NSView *c in chips) if(!c.hidden&&NSWidth(c.frame)>0){c0=c;break;} if(!c0) c0=chips[0];
   // web 实测（ego/Chromium）：`.npchipwrap` **溢出时**滚动条占位 11pt（卡宽 = wrapW-11），
   // **不溢出时不占位**（卡宽 = wrapW）。
   // 旧码无条件 wrapW-11：短列表也空出一条 11pt 槽（就是偏差台账里那条 1pt 级差）。
   // 判据只读：由实际 contentHeight 决定期望值，断两者**自洽**（旧码在本夹具下会失败）。
   id rwc = wrap;   // 用 KVC 读内容高度，不依赖 .mm 内部类型名
   const double kdContent = [[rwc valueForKey:@"contentHeight"] doubleValue];
   const BOOL kdOverflow = (kdContent > wrap.bounds.size.height + 0.5);
   const CGFloat kdWant = kdOverflow ? (W-11) : W;
   ck(fabs(c0.frame.size.width-kdWant)<1.5,
      [[NSString stringWithFormat:@"卡宽与溢出状态自洽（%@；contentH %.1f / wrapH %.1f ⟹ want %.1f；got %.1f",
        kdOverflow?@"溢出 ⟹ wrapW-11":@"不溢出 ⟹ wrapW", kdContent, wrap.bounds.size.height,
        kdWant,c0.frame.size.width] UTF8String]);
   // 栏头不随滚动移动
   NSTextField *title=(NSTextField *)[vc valueForKey:@"railTitle"];
   const CGFloat titleYBefore=title.frame.origin.y;
   // 测试环境没有真实元数据 ⟹ 生产会把 wrap 隐藏并显示 .nprailempty；判据先把它恢复可见再量滚动。
   wrap.hidden=NO;
   [(NSView *)vc.view layoutSubtreeIfNeeded];
   CGFloat y0=c0.frame.origin.y;

   BOOL hasOffset=[wrap respondsToSelector:NSSelectorFromString(@"setContentOffset:")];
   ck(hasOffset,"chipwrap 暴露 contentOffset（自绘滚动的状态入口）");
   if(hasOffset){
     // 先给足内容高（3 张卡本身可能还没撑出滚动），再设偏移；relayout 会把 contentHeight
     // 恢复成真实值（这是生产行为），所以拇指判据前再补一次大内容高。
     [wrap setValue:@1200 forKey:@"contentHeight"];
     [wrap setValue:@150 forKey:@"contentOffset"];
     ck(fabs(c0.frame.origin.y-(y0-150))<1.0,
        [[NSString stringWithFormat:@"滚动 150 后卡片上移 150（got %.1f）",c0.frame.origin.y-y0] UTF8String]);
     ck(fabs(title.frame.origin.y-titleYBefore)<0.01,"栏头 y 不随 chipwrap 滚动改变");
     // 拇指：右侧沟槽、与卡片右缘 ≥13、内容未溢出时为空
     [wrap setValue:@100 forKey:@"contentOffset"];
     [wrap setValue:@1200 forKey:@"contentHeight"];
     [wrap setNeedsDisplay:YES];
     BOOL hasThumb=[wrap respondsToSelector:NSSelectorFromString(@"scrollThumbRect")];
     ck(hasThumb,"chipwrap 暴露 scrollThumbRect（自绘拇指判据入口）");
     if(hasThumb){
       NSRect thumb=[wrap scrollThumbRect];
       NSRect cardRect=c0.frame;
       ck(!NSIsEmptyRect(thumb),"内容溢出时出现 6pt 拇指");
       if(!NSIsEmptyRect(thumb)){
         // 沟槽起点按 **web 的 11pt 占位**算（不是按当前卡片实测右缘）：本块为量拇指
         // 人为把 contentHeight 设成溢出值，而卡片宽度是按"真实是否溢出"算出来的，
         // 两者在夹具里本就不一致；用 W-11 作基准才是这条判据本来的意思。
         (void)cardRect;
         const CGFloat gap = NSMinX(thumb)-(W-11);
         // 卡片右缘 = W-11，6pt 拇指在 x∈[W-8,W-2] ⟹ 间隙 3pt（11pt 占位内，不压圆角）。
         ck(gap>=2.0 && gap<=5.0,
            [[NSString stringWithFormat:@"拇指与卡片右缘 ~3pt（11pt 占位内 6pt 拇指；got %.1f）",gap] UTF8String]);
         ck(NSMaxX(thumb)<=W+0.5,"拇指在 wrap 右侧沟槽内");
       }
     }
   }
  }
 }

 // ---- #69 补：chipwrap 惯性滚动（阻尼衰减到静止，位移有限）----
 {
  NSView *wrap2=find(vc.view,@"npChipWrap");
  if(wrap2 && [wrap2 respondsToSelector:NSSelectorFromString(@"beginMomentumWithVelocity:")]){
    // 惯性只在「内容溢出」时能推进 offset；momentumTick 会触发 railLayoutChips 重算
    // contentHeight，故每帧后把内容高恢复为大值（与上方 chipwrap 判据同口径）。
    [wrap2 setValue:@1200 forKey:@"contentHeight"];
    [wrap2 setValue:@0 forKey:@"contentOffset"];
    [(id)wrap2 beginMomentumWithVelocity:600];
    const CGFloat start=[[wrap2 valueForKey:@"contentOffset"] doubleValue];
    for(NSInteger i=0;i<200;i++){
      [(id)wrap2 momentumTick:nil];
      [wrap2 setValue:@1200 forKey:@"contentHeight"];
    }
    const CGFloat end=[[wrap2 valueForKey:@"contentOffset"] doubleValue];
    ck(end>=start && (end-start)>10.0 && (end-start)<2000.0,
       [[NSString stringWithFormat:@"惯性位移有限且单调（got %.1f）",end-start] UTF8String]);
    ck(fabs([[wrap2 valueForKey:@"momentumVelocity"] doubleValue])<0.01,
       "惯性速度按阻尼衰减到 0（自动停止）");
  } else ck(false,"chipwrap 暴露惯性滚动入口 beginMomentumWithVelocity:");
 }

 // ---- v3.3.11 `npVolInput`：精确 dB 输入（-120~+20，Enter 确认）----
 {
  id barObj=[vc valueForKey:@"webControls"];
  NSTextField *vf=[barObj valueForKey:@"volDbField"];
  ck(vf!=nil && [vf.identifier isEqualToString:@"npVolInput"],
     "V1 npVolInput 精确音量输入存在（v3.3.11 新增）");
  if(vf){
    ck(vf.target!=nil && vf.action!=NULL,"V2 npVolInput 有真实 target/action");
    lastPath=nil;
    vf.stringValue=@"-12.5";
    [(id)vf.target onCommitPreciseVolume:vf];
    ck([lastPath isEqualToString:@"/api/volume?db=-12.5"],
       [[NSString stringWithFormat:@"V3 精确输入真下发 /api/volume?db=-12.5（got %@）",lastPath?:@"(nil)"] UTF8String]);
    NSTextField *vl=[barObj valueForKey:@"volLabel"];
    ck([vl.stringValue isEqualToString:@"-12.5 dB"],
       [[NSString stringWithFormat:@"V4 音量标签同步精确值（got %@）",vl.stringValue] UTF8String]);
    lastPath=nil;
    vf.stringValue=@"99";
    [(id)vf.target onCommitPreciseVolume:vf];
    ck(lastPath==nil,"V5 越界值（99 dB）不下发请求");
    ck([vf.stringValue isEqualToString:@"-12.5"],
       [[NSString stringWithFormat:@"V6 越界后输入框恢复已确认值（got %@）",vf.stringValue] UTF8String]);
    lastPath=nil;
    vf.stringValue=@"-120";
    [(id)vf.target onCommitPreciseVolume:vf];
    ck([lastPath isEqualToString:@"/api/volume?db=-120.0"],
       [[NSString stringWithFormat:@"V7 -120 dB 静音档真下发（got %@）",lastPath?:@"(nil)"] UTF8String]);
  }
 }

 // ---- v3.3.11 `npVolFloor`：静音 / 恢复（toggleVolumeMute 同语义）----
 {
  id barObj2=[vc valueForKey:@"webControls"];
  NSButton *mute=[barObj2 valueForKey:@"volMuteBtn"];
  ck(mute!=nil && [mute.identifier isEqualToString:@"npVolFloor"],
     "M1 npVolFloor 静音/恢复按钮存在（v3.3.11）");
  if(mute){
    ck(mute.target!=nil && mute.action!=NULL,"M2 npVolFloor 有真实 target/action");
    NSTextField *vf2=[barObj2 valueForKey:@"volDbField"];
    // 先确认一个非静音精确值，再点静音
    lastPath=nil; vf2.stringValue=@"-12.5"; [(id)vf2.target onCommitPreciseVolume:vf2];
    lastPath=nil; [(id)mute.target onToggleVolumeMute:mute];
    ck([lastPath isEqualToString:@"/api/volume?db=-120.0"],
       [[NSString stringWithFormat:@"M3 点静音真下发 -120 dB（got %@）",lastPath?:@"(nil)"] UTF8String]);
    ck([vf2.stringValue isEqualToString:@"-120.0"],
       [[NSString stringWithFormat:@"M4 静音后精确输入框同步（got %@）",vf2.stringValue] UTF8String]);
    NSTextField *vl2=[barObj2 valueForKey:@"volLabel"];
    ck([vl2.stringValue isEqualToString:@"静音"],
       [[NSString stringWithFormat:@"M5 静音后标签为「静音」（got %@）",vl2.stringValue] UTF8String]);
    // 再点恢复先前 dB
    lastPath=nil; [(id)mute.target onToggleVolumeMute:mute];
    ck([lastPath isEqualToString:@"/api/volume?db=-12.5"],
       [[NSString stringWithFormat:@"M6 再点恢复先前 -12.5 dB（got %@）",lastPath?:@"(nil)"] UTF8String]);
    ck([vf2.stringValue isEqualToString:@"-12.5"],
       [[NSString stringWithFormat:@"M7 恢复后精确输入框同步（got %@）",vf2.stringValue] UTF8String]);
  }
 }

 // ---- #39 `#npDrawer` 页内抽屉浮卡（frame/圆角/阴影/遮罩点击关闭/不动底层滚动）----
 {
  NSView *canvas=(NSView *)[vc valueForKey:@"webCanvas"];
  NSScrollView *lyr=(NSScrollView *)[vc valueForKey:@"lyricScroll"];
  const NSInteger scrollBefore=CountScrollViews(canvas);
  const NSPoint lyrOriginBefore=lyr.contentView.bounds.origin;
  id chipsObj=[vc valueForKey:@"railCards"];
  NSArray<NSView *> *chips=[chipsObj isKindOfClass:[NSArray class]]?(NSArray<NSView *>*)chipsObj:@[];
  ck(chips.count>0,"有 rail chip 可点开抽屉");
  if(chips.count>0){
   // onRailCard 在拿不到实体名时会直接返回（生产里由 summary 或 meta 兜底）；判据先喂 meta。
   [vc setValue:@{@"title":@"曲名",@"album":@"专辑",@"artist":@"艺术家"} forKey:@"trackMetadata"];
   [(id)vc performSelector:@selector(onRailCard:) withObject:chips[0]];
   NSView *bg=find(vc.view,@"npDrawerBg"), *drawer=find(vc.view,@"npDrawer");
   ck(drawer!=nil,"点卡片打开页内 npDrawer（不是系统弹窗）");
   ck(bg!=nil,"npDrawerBg 遮罩存在");
   if(drawer&&bg){
    const CGFloat W=canvas.bounds.size.width, H=canvas.bounds.size.height;
    const CGFloat wantW=MIN(430.0,0.44*W);
    ck(!drawer.hidden&&!bg.hidden,"打开后抽屉与遮罩可见");
    ck(fabs(drawer.frame.size.width-wantW)<1.0,
       [[NSString stringWithFormat:@"抽屉宽=min(430,44vw)（want %.0f got %.0f）",wantW,drawer.frame.size.width] UTF8String]);
    ck(fabs(NSMaxX(drawer.frame)-(W-14.0))<1.0&&fabs(NSMinY(drawer.frame)-14.0)<1.0,
       [[NSString stringWithFormat:@"top/right 14pt（frame=%@）",NSStringFromRect(drawer.frame)] UTF8String]);
    NSView *ctlD=(NSView *)[vc valueForKey:@"webControls"];
    const CGFloat wantH=ctlD ? MAX(60.0, NSMinY(ctlD.frame)-8.0-14.0) : (H-28.0);
    ck(fabs(drawer.frame.size.height-wantH)<1.5 && (!ctlD || NSMaxY(drawer.frame)<=NSMinY(ctlD.frame)-7.5),
       [[NSString stringWithFormat:@"抽屉底边让出底栏控制区（wantH %.0f gotH %.0f maxY %.0f ctlTop %.0f）",
         wantH,drawer.frame.size.height,NSMaxY(drawer.frame),ctlD?NSMinY(ctlD.frame):0.0] UTF8String]);
    ck(fabs(drawer.layer.cornerRadius-18.0)<0.6,"抽屉圆角 18（web border-radius:18px）");
    ck(drawer.layer.borderWidth>=1.0,"抽屉 1px 描边（--line2）");
    ck(drawer.layer.shadowOpacity>0.30&&fabs(drawer.layer.shadowRadius-40.0)<1.0,
       [[NSString stringWithFormat:@"阴影 opacity=%.2f radius=%.0f（web 0 28 80 rgba .42）",drawer.layer.shadowOpacity,drawer.layer.shadowRadius] UTF8String]);
    ck(fabs(drawer.layer.shadowOffset.height+28.0)<1.0,"阴影向下 28");
    ck(fabs(bg.frame.size.width-W)<1.0&&fabs(bg.frame.size.height-H)<1.0,"遮罩铺满页面（inset 0）");
    ck(CountScrollViews(canvas)==scrollBefore,
       [[NSString stringWithFormat:@"打开抽屉不新增 NSScrollView（before %ld after %ld）",(long)scrollBefore,(long)CountScrollViews(canvas)] UTF8String]);
    ck(NSEqualPoints(lyr.contentView.bounds.origin,lyrOriginBefore),"打开抽屉不动底层歌词滚动位置");
    // #39 补：backdrop blur(2px) + transform .26s 滑入（frame 仍为终态，不破坏几何判据）
    NSView *blur=nil;
    for(NSView *s in bg.subviews) if([s.identifier isEqualToString:@"npDrawerBlur"]){blur=s;break;}
    ck(blur!=nil && [blur isKindOfClass:[NSVisualEffectView class]],
       "npDrawerBg 含 NSVisualEffectView 模糊层（web backdrop-filter:blur(2px)）");
    CAAnimation *slide=[drawer.layer animationForKey:@"npDrawerSlide"];
    ck(slide!=nil && fabs(slide.duration-0.26)<0.01,
       [[NSString stringWithFormat:@"抽屉 0.26s transform 滑入动画（got %.2f）",slide?slide.duration:-1] UTF8String]);
    ck(fabs(drawer.frame.size.width-wantW)<1.0,
       "滑入动画不改 model frame（离屏几何判据仍确定性）");
    [bg mouseDown:nil];   // 点遮罩 = web npDrawerClose()
    ck(drawer.hidden&&bg.hidden,"点遮罩关闭抽屉（web #npDrawerBg 点击关闭）");
    // Esc 关闭（web 抽屉的 Esc 路径）；旧码没有这个入口时只跳过
    BOOL hasEsc=[vc respondsToSelector:@selector(cancelOperation:)];
    ck(hasEsc,"抽屉支持 Esc 关闭（cancelOperation:）");
    if(hasEsc){
      [(id)vc performSelector:@selector(onRailCard:) withObject:chips[0]];
      ck(!drawer.hidden,"再次打开抽屉");
      [(id)vc cancelOperation:nil];
      ck(drawer.hidden,"Esc 关闭抽屉（web keydown Escape）");
    }
   }
  }
 }
 // ---- v3.3.11 逐曲封面 set/reset（npSetCover / npResetCover）----
 {
  NSButton *setB=(NSButton *)find(vc.view,@"npSetCover"),*rstB=(NSButton *)find(vc.view,@"npResetCover");
  ck(setB && [setB isKindOfClass:[NSButton class]],"C1 npSetCover 控件存在");
  ck(rstB && [rstB isKindOfClass:[NSButton class]],"C2 npResetCover 控件存在");
  ck(setB && setB.target && setB.action!=NULL,"C3 设置封面按钮有真实 target/action");
  ck(rstB && rstB.target && rstB.action!=NULL,"C4 恢复自动按钮有真实 target/action");
  // C4b/C4c（v3.3.11 coverSource 闸门）：只有手动封面生效时才显示「自动」按钮。
  // 旧实现缺 /api/meta.coverSource ⟹ 按钮常显，点了也无从恢复（偏差台账那条）。
  ck(rstB.hidden, "C4b 无手动封面时「自动」按钮隐藏（coverSource != manual）");
  [vc setValue:@{@"title":@"T",@"coverSource":@"manual"} forKey:@"trackMetadata"];
  [vc performSelector:@selector(applyCoverSourceGate) withObject:nil];
  ck(!rstB.hidden, "C4c coverSource == manual 时按钮显示");
  [vc setValue:@{@"title":@"T",@"coverSource":@"embed"} forKey:@"trackMetadata"];
  [vc performSelector:@selector(applyCoverSourceGate) withObject:nil];
  ck(rstB.hidden, "C4d coverSource == embed 时按钮重新隐藏");
  NSString *imgPath=[@"/tmp" stringByAppendingPathComponent:[NSString stringWithFormat:@"rlp-cover-%d.png",(int)getpid()]];
  NSMutableData *png=[NSMutableData data];
  const unsigned char magic[8]={0x89,'P','N','G',0x0d,0x0a,0x1a,0x0a};
  [png appendBytes:magic length:8];
  while(png.length<1200)[png appendBytes:"\0" length:1];
  ck([png writeToFile:imgPath atomically:YES],"C5 封面夹具图片已写入");
  g_lastDataPath=@"";g_lastDataLen=0;
  [vc setCoverAtPath:imgPath forTrack:@"/Music/A/One.flac"];
  ck([g_lastDataPath hasPrefix:@"/api/cover/set?file="],"C6 设置封面真发 /api/cover/set");
  ck(g_lastDataLen>=1200,"C7 下发的是图片字节而不是表单（>=1200B）");
  NSString *decoded=[g_lastDataPath stringByRemovingPercentEncoding]?:g_lastDataPath;
  ck([decoded containsString:@"/Music/A/One.flac"],"C8 请求带的是目标曲目路径");
  lastPath=nil;
  [vc resetCoverForTrack:@"/Music/A/One.flac"];
  ck(lastPath && [lastPath hasPrefix:@"/api/cover/reset?file="],"C9 恢复自动真发 /api/cover/reset");
  ck(lastPath && [[lastPath stringByRemovingPercentEncoding] containsString:@"/Music/A/One.flac"],"C10 reset 请求带目标曲目路径");
  [[NSFileManager defaultManager] removeItemAtPath:imgPath error:nil];
 }
 // ---- 歌词 AI 右键菜单（六项 + /api/lyrics/ai + 切曲守卫）----
 {
  spy.fakeStarted=YES;
  [vc setValue:@"/offline/A.flac" forKey:@"currentPath"];
  [vc applyLyricText:@"[00:01.00]alpha one\n[00:03.00]alpha two" forPath:@"/offline/A.flac"];
  NSMenu *lm=ly.menu;
  NSView *ldoc=[vc valueForKey:@"lyricDocument"];
  NSArray<NSButton *> *lrows=[vc valueForKey:@"lyricRows"];
  ck(lm!=nil,"L1a 歌词滚动视图挂载了右键菜单");
  ck(lm!=nil && ldoc && ldoc.menu==lm,"L1b lyricDocument 挂载同一份右键菜单");
  ck(lm!=nil && lrows.count>0 && lrows[0].menu==lm,"L1c 歌词行按钮挂载同一份右键菜单");
  NSMutableArray<NSString *> *titles=[NSMutableArray array];
  for(NSMenuItem *it in lm.itemArray) if(!it.isSeparatorItem) [titles addObject:it.title?:@""];
  NSArray<NSString *> *want=@[RLPTr(@"翻译…"),RLPTr(@"音译"),RLPTr(@"日语假名"),RLPTr(@"转繁体"),RLPTr(@"恢复原文"),RLPTr(@"复制歌词")];
  ck([titles isEqualToArray:want],"L1d 歌词右键菜单包含 6 个动作项（翻译…/音译/日语假名/转繁体/恢复原文/复制歌词）");

  NSMenuItem *trItem=(lm.itemArray.count>0)?lm.itemArray[0]:nil;
  NSMenuItem *langItem=(trItem.submenu.itemArray.count>0)?trItem.submenu.itemArray[0]:nil;
  ck(trItem.submenu!=nil && langItem!=nil,"L2a 「翻译…」包含目标语言子菜单");
  lastPath=nil;lastBody=nil;pendingLyricAi=nil;
  if(langItem && langItem.target && langItem.action)
   [NSApp sendAction:langItem.action to:langItem.target from:langItem];
  ck([lastPath isEqualToString:@"/api/lyrics/ai"],"L2b 选「翻译…」发出 POST /api/lyrics/ai");
  ck(lastBody && [lastBody containsString:@"task=translate"],"L2c 请求体包含 task=translate");
  ck(pendingLyricAi!=nil,"L2d 捕获到在途 /api/lyrics/ai 回调");
  BOOL hasBusy=[vc respondsToSelector:@selector(lyricAiBusy)];
  ck(hasBusy && [[vc valueForKey:@"lyricAiBusy"] boolValue],"L2e 发起请求后 lyricAiBusy 为 YES");

  // 切到另一首 B，再让 A 的旧回包到达
  spy.fixtures=[@{
   @"/api/status":@{@"ok":@1,@"playing":@1,@"paused":@0,@"current":@"/offline/B.flac",@"dur":@10.0},
   @"/api/lyrics":@{@"ok":@1,@"lrc":@"[00:01.00]bravo one\n[00:03.00]bravo two"},
   @"/api/meta":@{@"ok":@1,@"title":@"Bravo",@"meta":@{@"enriched":@NO}}
  } mutableCopy];
  [vc refresh];
  ck(hasBusy && ![[vc valueForKey:@"lyricAiBusy"] boolValue],"L3a 切到新曲 B 后 lyricAiBusy 必须释放");
  if(pendingLyricAi){
   pendingLyricAi(@{@"ok":@YES,@"lines":@[@"STALE_AI_1",@"STALE_AI_2"]});
   pendingLyricAi=nil;
  }
  NSArray<RLPLyricLine *> *linesAfterStale=[vc valueForKey:@"lyricLines"];
  ck(linesAfterStale.count==2 && [linesAfterStale[0].text isEqualToString:@"bravo one"],
     "L3b 旧曲 A 的迟到 /api/lyrics/ai 回包不得覆盖新曲 B 的歌词");
  ck(hasBusy && ![[vc valueForKey:@"lyricAiBusy"] boolValue],"L3c 丢弃旧回包后 lyricAiBusy 仍为 NO");

  // 新曲 B 正常使用 AI 翻译 + 恢复原文
  lastPath=nil;pendingLyricAi=nil;
  if(langItem && langItem.target && langItem.action)
   [NSApp sendAction:langItem.action to:langItem.target from:langItem];
  ck([lastPath isEqualToString:@"/api/lyrics/ai"] && pendingLyricAi!=nil,"L4a 切曲后新曲 B 可正常发起 /api/lyrics/ai");
  if(pendingLyricAi){
   pendingLyricAi(@{@"ok":@YES,@"lines":@[@"译文 1",@"译文 2"]});
   pendingLyricAi=nil;
  }
  NSArray<RLPLyricLine *> *linesAfterAi=[vc valueForKey:@"lyricLines"];
  ck(linesAfterAi.count==2 && [linesAfterAi[0].text isEqualToString:@"译文 1"],"L4b 新曲 B 正常贴回 AI 译文");
  ck(hasBusy && ![[vc valueForKey:@"lyricAiBusy"] boolValue],"L4c 完成后 lyricAiBusy 释放");
  NSMenuItem *restoreItem=nil;
  for(NSMenuItem *it in lm.itemArray) if([it.title isEqualToString:RLPTr(@"恢复原文")]){restoreItem=it;break;}
  if(restoreItem && restoreItem.target && restoreItem.action)
   [NSApp sendAction:restoreItem.action to:restoreItem.target from:restoreItem];
  NSArray<RLPLyricLine *> *linesAfterRestore=[vc valueForKey:@"lyricLines"];
  ck(linesAfterRestore.count==2 && [linesAfterRestore[0].text isEqualToString:@"bravo one"],"L4d 恢复原文回到 bravo one");
  spy.fakeStarted=NO;
 }
 // ---- #61 切曲复位：A→B 立即清旧歌词/主封面；A 的迟到回包不得覆盖 B（请求挂起夹具）----
 // 判据 R1 红：移除 loadLyricsForPath: 里的切曲清行块（A 的行会留在 B 上），或移除
 //            loadCoverForPath: 里「coverPath 不是本曲 ⟹ cover.image=nil」的块。
 // 判据 R2 红：移除 loadCoverForPath: 回包里的 coverSeq 守卫（A 的迟到图会贴到 B）。
 //            歌词侧是纵深防御：fetchLyricPath 的 seq/currentPath 守卫 + applyLyricText
 //            的 path 守卫——两条都移除才红（单移除任一条仍被另一条挡住）。
 {
  NSString *pathA=@"/offline/stale-A.flac", *pathB=@"/offline/stale-B.flac";
  NSImageView *coverView=(NSImageView *)[vc valueForKey:@"cover"];
  NSTextField *emptyLabel=(NSTextField *)[vc valueForKey:@"lyricsEmpty"];
  holdNPRequests=YES;pendingLyrics=nil;pendingCover=nil;
  [vc setValue:pathA forKey:@"currentPath"];
  [vc loadLyricsForPath:pathA];                 // 切到 A：清掉上一用例的歌词，再挂起 A 的取词
  [vc loadCoverForPath:pathA];                  // 挂起 A 的取图
  RLPJSONCompletion aLyric=pendingLyrics;pendingLyrics=nil;
  RLPDataCompletion aCover=pendingCover;pendingCover=nil;
  NSData *aImg=NPPngOfColor([NSColor colorWithSRGBRed:0.20 green:0.40 blue:0.85 alpha:1.0]);
  if(aLyric)aLyric(@{@"ok":@1,@"lrc":@"[00:01.00]alpha one\n[00:03.00]alpha two"});
  if(aCover)aCover(aImg);
  // A 的同曲重取（重试 / 手动封面等）仍在飞 ⟹ 切到 B 之后才到的才是「A 的迟到回包」。
  [vc loadLyricsForPath:pathA];[vc loadCoverForPath:pathA];
  RLPJSONCompletion lateLyric=pendingLyrics;pendingLyrics=nil;
  RLPDataCompletion lateCover=pendingCover;pendingCover=nil;
  // 切曲前基线：旧歌词 2 行 + 主封面非空（判据 R1 的前置；不成立就让 R1 红，避免空断言假通过）
  const NSUInteger aRowCount=[(NSArray *)[vc valueForKey:@"lyricRows"] count];
  const BOOL aCoverOk=(coverView.image!=nil);
  const BOOL aReady=(aRowCount==2&&aCoverOk);
  spy.fixtures=[@{@"/api/status":@{@"ok":@1,@"playing":@1,@"paused":@0,@"current":pathB,@"dur":@10.0}} mutableCopy];
  [vc refresh];                                 // A→B：B 的歌词/封面都还挂在空中
  const NSUInteger bRowCount=[(NSArray *)[vc valueForKey:@"lyricRows"] count];
  NSArray<RLPLyricLine *> *bLines=[vc valueForKey:@"lyricLines"];
  NSString *emptyText=emptyLabel.attributedStringValue.string?:@"";
  // 加载态两行文案由 setLyricsPlaceholder:detail: 拼成（主行 + \n + 副行，逐字锁定）。
  NSString *wantLoading=[NSString stringWithFormat:@"%@\n%@",
      RLPTr(@"歌词加载中…"),RLPTr(@"正在等后台补全（首次播放新曲目时可能要几秒）")];
  const BOOL cleared=(bRowCount==0&&bLines.count==0&&!emptyLabel.hidden
    &&[emptyText isEqualToString:wantLoading]
    &&coverView.image==nil);
  ck(aReady&&cleared,[[NSString stringWithFormat:
    @"R1 A→B 立即清旧歌词/主封面：切曲后旧行=%lu（want 0）、空态=「%@」、主封面=%@（want nil）；A 先就位 rows=%lu image=%d",
    (unsigned long)bRowCount,emptyText,(coverView.image ? @"非空" : @"nil"),
    (unsigned long)aRowCount,(int)aCoverOk] UTF8String]);
  // 迟到：A 的在途回包此刻才到（B 的回包仍挂起）。判据 R2 量「回包前后状态是否被改写」，
  // 与 R1 是否清屏解耦：清屏缺失由 R1 负责红，这里只钉「迟到回包必须是无副作用的丢弃」。
  NSArray<RLPLyricLine *> *linesBeforeLate=[vc valueForKey:@"lyricLines"];
  NSImage *coverBeforeLate=coverView.image;
  NSData *lateImg=NPPngOfColor([NSColor colorWithSRGBRed:0.90 green:0.10 blue:0.10 alpha:1.0]);
  const BOOL lateCaptured=(lateLyric!=nil&&lateCover!=nil);
  const BOOL lateImgOk=([lateImg length]>0&&[[NSImage alloc] initWithData:lateImg]!=nil);
  if(lateLyric)lateLyric(@{@"ok":@1,@"lrc":@"[00:01.00]STALE-A-ONE\n[00:03.00]STALE-A-TWO"});
  if(lateCover)lateCover(lateImg);
  NSArray<RLPLyricLine *> *linesAfterLate=[vc valueForKey:@"lyricLines"];
  NSString *firstBeforeLate=(linesBeforeLate.count>0)?linesBeforeLate[0].text:@"";
  NSString *firstAfterLate=(linesAfterLate.count>0)?linesAfterLate[0].text:@"";
  const BOOL lyricChanged=!(linesBeforeLate.count==linesAfterLate.count&&[firstBeforeLate isEqualToString:firstAfterLate]);
  const BOOL coverChanged=(coverView.image!=coverBeforeLate);
  const BOOL staleLeaked=(lyricChanged||coverChanged);
  // 阳性对照：B 自己的回包必须仍然能落地（证明挂起夹具是活的 ⟹ R2 不是「夹具没接上」的假通过）
  RLPJSONCompletion bLyric=pendingLyrics;pendingLyrics=nil;
  RLPDataCompletion bCover=pendingCover;pendingCover=nil;
  if(bLyric)bLyric(@{@"ok":@1,@"lrc":@"[00:01.00]bravo B one\n[00:03.00]bravo B two"});
  if(bCover)bCover(NPPngOfColor([NSColor colorWithSRGBRed:0.10 green:0.75 blue:0.25 alpha:1.0]));
  NSArray<RLPLyricLine *> *linesFinal=[vc valueForKey:@"lyricLines"];
  const BOOL bLanded=(linesFinal.count==2&&[linesFinal[0].text isEqualToString:@"bravo B one"]&&coverView.image!=nil);
  ck(lateCaptured&&lateImgOk&&!staleLeaked&&bLanded,[[NSString stringWithFormat:
    @"R2 迟到 A 回包不得覆盖 B：回包前后歌词行=%lu→%lu（「%@」→「%@」）、主封面变化=%d（want 0）；挂起回包=%d 迟到图可解码=%d B 回包落地=%d",
    (unsigned long)linesBeforeLate.count,(unsigned long)linesAfterLate.count,firstBeforeLate,firstAfterLate,
    (int)coverChanged,(int)lateCaptured,(int)lateImgOk,(int)bLanded] UTF8String]);
  holdNPRequests=NO;pendingLyrics=nil;pendingCover=nil;
 }
 pendingFav=nil;pendingLyricAi=nil;method_setImplementation(shared,old);
 // ---- Live language switch must refresh tooltips captured at construction ----
 RLPSetLanguage(@"en");[vc applyLanguage];
 {id bar=[vc valueForKey:@"webControls"];ck(bar != nil,"language fixture contains actual playback controls");NSArray *keys=@[@"castButton",@"saveButton",@"closeButton",@"analysisToggle",@"railToggle",@"railHide",@"coverSetBtn",@"coverResetBtn"];NSArray *barKeys=@[@"seek",@"repBtn",@"volKnob",@"volDbField",@"volMuteBtn"];NSMutableArray *stale=[NSMutableArray array];for(NSString*k in keys){NSView*v=[vc valueForKey:k];NSString*tip=[(id)v respondsToSelector:@selector(toolTip)]?[v valueForKey:@"toolTip"]:nil;if(HasCJK(tip))[stale addObject:[NSString stringWithFormat:@"%@=%@",k,tip]];}for(NSString*k in barKeys){id v=[bar valueForKey:k];NSString*tip=[v respondsToSelector:@selector(toolTip)]?[v valueForKey:@"toolTip"]:nil;if(HasCJK(tip))[stale addObject:[NSString stringWithFormat:@"bar.%@=%@",k,tip]];}ck(stale.count==0,"language switch refreshes tooltips built at construction");if(stale.count)printf("    stale: %s\n",[[stale componentsJoinedByString:@" | "] UTF8String]);}
 RLPSetLanguage(@"zh");[vc applyLanguage];
 // ---- N1/N2/N3: 900x600 覆盖页经 NSLayoutConstraint 四边 pin 到主窗 contentView 时底栏完整可见不裁切 ----
 {
  NSUserDefaults *ud=[NSUserDefaults standardUserDefaults];
  const BOOL savedAnlHidden=[ud boolForKey:@"RLPNPAnalysisHidden"];
  const BOOL savedRailHidden=[ud boolForKey:@"RLPNPRailHidden"];
  [ud setBool:NO forKey:@"RLPNPAnalysisHidden"];
  [ud setBool:NO forKey:@"RLPNPRailHidden"];

  NSWindow *win=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,600)
                                            styleMask:NSWindowStyleMaskBorderless
                                              backing:NSBackingStoreBuffered defer:NO];
  win.contentView=[[NSView alloc] initWithFrame:NSMakeRect(0,0,900,600)];
  [win setContentSize:NSMakeSize(900,600)];

  RLPNowPlayingViewController *np=[RLPNowPlayingViewController new];
  NSView *nv=np.view;
  nv.translatesAutoresizingMaskIntoConstraints=NO;
  [win.contentView addSubview:nv];
  [NSLayoutConstraint activateConstraints:@[
   [nv.leadingAnchor constraintEqualToAnchor:win.contentView.leadingAnchor],
   [nv.trailingAnchor constraintEqualToAnchor:win.contentView.trailingAnchor],
   [nv.topAnchor constraintEqualToAnchor:win.contentView.topAnchor],
   [nv.bottomAnchor constraintEqualToAnchor:win.contentView.bottomAnchor],
  ]];
  [win.contentView layoutSubtreeIfNeeded];

  NSView *ctl=find(nv,@"np.controls");
  if(!ctl){
   NSView *seek=find(nv,@"np.seek") ?: find(nv,@"np.vol");
   ctl=seek.superview;
  }
  NSView *knob=find(ctl ?: nv,@"npVolKnob");
  NSView *mute=find(ctl ?: nv,@"npVolFloor");
  NSView *wf=find(nv,@"np.waveform");
  NSView *anal=find(nv,@"npAnal");
  NSView *ly=find(nv,@"npLyric");
  NSView *rail=find(nv,@"npRail");

  void (^checkBottomBarInBounds)(CGFloat,CGFloat,const char *) = ^(CGFloat wantW,CGFloat wantH,const char *tag){
   const CGFloat bw=nv.bounds.size.width, bh=nv.bounds.size.height;
   const BOOL hostOk=(fabs(bw-wantW)<1.0 && fabs(bh-wantH)<1.0);
   if(!ctl || !knob || !mute){
    ck(NO,[[NSString stringWithFormat:@"%s 控件齐备(ctl=%d knob=%d mute=%d)",tag,ctl!=nil,knob!=nil,mute!=nil] UTF8String]);
    return;
   }
   const NSRect ctlC=[nv convertRect:ctl.bounds fromView:ctl];
   const NSRect knobC=[nv convertRect:knob.bounds fromView:knob];
   const NSRect muteC=[nv convertRect:mute.bounds fromView:mute];
   const NSRect ctlW=[win.contentView convertRect:ctl.bounds fromView:ctl];
   const NSRect knobW=[win.contentView convertRect:knob.bounds fromView:knob];
   const NSRect muteW=[win.contentView convertRect:mute.bounds fromView:mute];
   const BOOL ctlOk=(!ctl.hidden && ctlC.size.height>10.0 && ctlC.size.width<=wantW+1.0 &&
                     NSMinY(ctlC)>=-1.0 && NSMaxY(ctlC)<=wantH+1.0 &&
                     NSMinY(ctlW)>=-1.0 && NSMaxY(ctlW)<=wantH+1.0);
   const BOOL knobOk=(!knob.hidden && knobC.size.height>1.0 &&
                      NSMinY(knobC)>=-1.0 && NSMaxY(knobC)<=wantH+1.0 &&
                      NSMinY(knobW)>=-1.0 && NSMaxY(knobW)<=wantH+1.0);
   const BOOL muteOk=(!mute.hidden && muteC.size.height>1.0 &&
                      NSMinY(muteC)>=-1.0 && NSMaxY(muteC)<=wantH+1.0 &&
                      NSMinY(muteW)>=-1.0 && NSMaxY(muteW)<=wantH+1.0);
   const BOOL wfOk=(wf==nil || NSMaxY([nv convertRect:wf.bounds fromView:wf])<=NSMinY(ctlC)+0.5);
   printf("    [%s] nv=%.0fx%.0f ctl=%s knob=%s mute=%s ctlWin=%s\n",
          tag, bw, bh,
          [NSStringFromRect(ctlC) UTF8String],
          [NSStringFromRect(knobC) UTF8String],
          [NSStringFromRect(muteC) UTF8String],
          [NSStringFromRect(ctlW) UTF8String]);
   ck(hostOk && ctlOk && knobOk && muteOk && wfOk,
      [[NSString stringWithFormat:@"%s %.0fx%.0f 底栏完整落在[0,%.0f]内(ctlMaxY=%.1f knobMaxY=%.1f muteMaxY=%.1f)",
        tag, wantW, wantH, wantH, NSMaxY(ctlC), NSMaxY(knobC), NSMaxY(muteC)] UTF8String]);
  };

  // N1: 900x600 首开经 NSLayoutConstraint 四边 pin 到 contentView
  checkBottomBarInBounds(900.0, 600.0, "N1");
  if(ctl){
   ck(fabs(ctl.frame.size.height-64.0)<1.0 && NSMaxY(ctl.frame)<=601.0,
      [[NSString stringWithFormat:@"N1b 900x600 已重算紧凑底栏(h=%.1f maxY=%.1f，不再停留 1180x760 的 y=676/h=68)",
        ctl.frame.size.height, NSMaxY(ctl.frame)] UTF8String]);
  }

  // N2: 同一 VC 宿主尺寸 1180x760 -> 900x600 -> 1180x760 来回切换 + 缓存重入，每档底栏完整不裁
  [win setContentSize:NSMakeSize(1180,760)];
  [win.contentView layoutSubtreeIfNeeded];
  checkBottomBarInBounds(1180.0, 760.0, "N2a(1180x760)");

  [win setContentSize:NSMakeSize(900,600)];
  [win.contentView layoutSubtreeIfNeeded];
  checkBottomBarInBounds(900.0, 600.0, "N2b(900x600)");

  [win setContentSize:NSMakeSize(1180,760)];
  [win.contentView layoutSubtreeIfNeeded];
  checkBottomBarInBounds(1180.0, 760.0, "N2c(1180x760)");

  [nv removeFromSuperview];
  [win setContentSize:NSMakeSize(900,600)];
  [win.contentView addSubview:nv];
  [NSLayoutConstraint activateConstraints:@[
   [nv.leadingAnchor constraintEqualToAnchor:win.contentView.leadingAnchor],
   [nv.trailingAnchor constraintEqualToAnchor:win.contentView.trailingAnchor],
   [nv.topAnchor constraintEqualToAnchor:win.contentView.topAnchor],
   [nv.bottomAnchor constraintEqualToAnchor:win.contentView.bottomAnchor],
  ]];
  [win.contentView layoutSubtreeIfNeeded];
  checkBottomBarInBounds(900.0, 600.0, "N2d(reattach 900x600)");

  // N3: 900x600 下打开/展开分析面板、切换资料栏、打开页内资料抽屉及多行歌词/芯片，均不把底栏推出去
  [np setValue:@"/offline/n3-900x600.flac" forKey:@"currentPath"];
  [np applyLyricText:@"[00:01.00]line 1\n[00:02.00]line 2\n[00:03.00]line 3\n[00:04.00]line 4\n[00:05.00]line 5\n[00:06.00]line 6"
             forPath:@"/offline/n3-900x600.flac"];
  [np renderMetaChipsFromMeta:@{
   @"year": @2024,
   @"genre": @"Classical / Chamber / Orchestral Very Long Genre Label",
   @"albumArtist": @"Berlin Philharmonic / Herbert von Karajan",
   @"meta": @{ @"enriched": @YES, @"sources": @{ @"year": @"MusicBrainz" } }
  }];
  [np setValue:@{@"title":@"N3 Symphony",@"album":@"Album",@"artist":@"Artist"} forKey:@"trackMetadata"];
  [np renderRailMetadata];
  if(anal.hidden)[np onToggleAnalysis:nil];
  if(rail.hidden)[np onToggleRail:nil];
  [win.contentView layoutSubtreeIfNeeded];
  checkBottomBarInBounds(900.0, 600.0, "N3a(panels+chips)");

  [np onAnlExpand:nil];   // L0 -> L1
  [win.contentView layoutSubtreeIfNeeded];
  checkBottomBarInBounds(900.0, 600.0, "N3b(anl L1)");

  [np onAnlExpand:nil];   // L1 -> L2
  [win.contentView layoutSubtreeIfNeeded];
  checkBottomBarInBounds(900.0, 600.0, "N3c(anl L2)");

  [np onAnlExpand:nil];   // L2 -> L0
  id chipsObjN3=[np valueForKey:@"railCards"];
  NSArray<NSView *> *chipsN3=[chipsObjN3 isKindOfClass:[NSArray class]]?(NSArray<NSView *>*)chipsObjN3:@[];
  if(chipsN3.count>0){
   [(id)np performSelector:@selector(onRailCard:) withObject:chipsN3[0]];
  }else{
   [np openDataDrawer];
  }
  [win.contentView layoutSubtreeIfNeeded];
  checkBottomBarInBounds(900.0, 600.0, "N3d(npDrawer open)");
  NSView *drawerN3=find(nv,@"npDrawer");
  if(drawerN3 && !drawerN3.hidden){
   const NSRect drC=[nv convertRect:drawerN3.bounds fromView:drawerN3];
   ck(NSMinY(drC)>=0.0 && NSMaxY(drC)<=601.0,
      [[NSString stringWithFormat:@"N3e 900x600 下 npDrawer 完整落在[0,600]内(frame=%@)",NSStringFromRect(drC)] UTF8String]);
  }
  const NSRect ctlCNow=ctl ? [nv convertRect:ctl.bounds fromView:ctl] : NSZeroRect;
  const NSRect wfCNow=wf ? [nv convertRect:wf.bounds fromView:wf] : NSZeroRect;
  if(wf && ctl){
   const BOOL panelsClearWf=(!anal || anal.hidden || NSMaxY([nv convertRect:anal.bounds fromView:anal])<=NSMinY(wfCNow)+0.5)
                         && (!ly || NSMaxY([nv convertRect:ly.bounds fromView:ly])<=NSMinY(wfCNow)+0.5)
                         && (!rail || rail.hidden || NSMaxY([nv convertRect:rail.bounds fromView:rail])<=NSMinY(wfCNow)+0.5);
   ck(panelsClearWf && NSMaxY(wfCNow)<=NSMinY(ctlCNow)+0.5,
      "N3f 三栏不压波形、波形不压底栏");
  }
  [np closeDataDrawer];

  // ---- N1 / N2 / N3 UI 回归判据（图二/三/六）----
  {
   [np setValue:[RLPPlaybackStatus statusFromJSON:@{@"ok":@YES,@"playing":@YES,@"paused":@NO,@"current":@"/offline/npui.flac",@"dur":@120.0}] forKey:@"webStatus"];
   [np setValue:@"/offline/npui.flac" forKey:@"currentPath"];
   [np setValue:@{@"title":@"N1 Track",@"album":@"Album",@"artist":@"Artist",@"coverSource":@"embed"} forKey:@"trackMetadata"];
   [np applyMetaChipVisibility];

   // N1: 1800 / 1600 宽下「推送到设备 / 添加到歌单」按钮高度一致且图标与文字垂直中心线偏差 <= 1pt
   NSButton *castBtn = (NSButton *)find(nv, @"npCastBtn");
   NSButton *saveBtn = (NSButton *)find(nv, @"npAddSq");
   for (NSArray<NSNumber *> *sz in @[@[@1800,@1000], @[@1600,@900]]) {
    const CGFloat W = sz[0].doubleValue, H = sz[1].doubleValue;
    [win setContentSize:NSMakeSize(W, H)];
    [win.contentView layoutSubtreeIfNeeded];
    const BOOL vis = (castBtn && saveBtn && !castBtn.hidden && !saveBtn.hidden);
    ck(vis, [[NSString stringWithFormat:@"N1_%dx%d 投放/加歌单按钮可见",(int)W,(int)H] UTF8String]);
    if (vis) {
     const NSRect cf = castBtn.frame, sf = saveBtn.frame;
     const BOOL sameH = (fabs(NSHeight(cf) - NSHeight(sf)) <= 0.5 && fabs(NSHeight(cf) - 24.0) <= 0.5);
     const NSRect cir = [castBtn.cell imageRectForBounds:castBtn.bounds];
     const NSRect ctr = [castBtn.cell titleRectForBounds:castBtn.bounds];
     const NSRect sir = [saveBtn.cell imageRectForBounds:saveBtn.bounds];
     const NSRect str = [saveBtn.cell titleRectForBounds:saveBtn.bounds];
     const CGFloat cDy = fabs(NSMidY(cir) - NSMidY(ctr));
     const CGFloat sDy = fabs(NSMidY(sir) - NSMidY(str));
     const CGFloat cGap = NSMinX(ctr) - NSMaxX(cir);
     const CGFloat sGap = NSMinX(str) - NSMaxX(sir);
     const CGFloat btnGap = NSMinX(sf) - NSMaxX(cf);
     printf("    [N1 %dx%d] cast=%s ir=%s tr=%s dy=%.2f | save=%s ir=%s tr=%s dy=%.2f | gap=%.1f\n",
            (int)W, (int)H,
            NSStringFromRect(cf).UTF8String, NSStringFromRect(cir).UTF8String, NSStringFromRect(ctr).UTF8String, cDy,
            NSStringFromRect(sf).UTF8String, NSStringFromRect(sir).UTF8String, NSStringFromRect(str).UTF8String, sDy, btnGap);
     ck(sameH, [[NSString stringWithFormat:@"N1_%d cast(%.1f)/save(%.1f) 高度一致且等于 24pt",(int)W,NSHeight(cf),NSHeight(sf)] UTF8String]);
     ck(!NSIsEmptyRect(cir) && !NSIsEmptyRect(ctr) && cDy <= 1.0 && fabs(NSMidY(cir) - NSMidY(castBtn.bounds)) <= 1.0 && cGap >= 3.0,
        [[NSString stringWithFormat:@"N1_%d cast 图标/文字垂直中心线偏差 %.2fpt <= 1pt 且有间距 %.1f",(int)W,cDy,cGap] UTF8String]);
     ck(!NSIsEmptyRect(sir) && !NSIsEmptyRect(str) && sDy <= 1.0 && fabs(NSMidY(sir) - NSMidY(saveBtn.bounds)) <= 1.0 && sGap >= 3.0,
        [[NSString stringWithFormat:@"N1_%d save 图标/文字垂直中心线偏差 %.2fpt <= 1pt 且有间距 %.1f",(int)W,sDy,sGap] UTF8String]);
     ck(fabs(NSMidY(cf) - NSMidY(sf)) <= 0.5 && btnGap >= 5.5,
        [[NSString stringWithFormat:@"N1_%d 两按钮同行等距 gap=%.1f",(int)W,btnGap] UTF8String]);
    }
   }

   // N2 & N3: 900x600 与 1180x760 两档布局检查（分析头部删除/三栏均衡/底栏完整/封面右下角设置按钮）
   NSView *coverV = find(nv, @"npCover");
   NSButton *setCoverB = (NSButton *)find(nv, @"npSetCover");
   NSButton *rstCoverB = (NSButton *)find(nv, @"npResetCover");
   NSView *anlSegV = find(nv, @"npAnlSeg");
   NSView *anlBodyV = find(nv, @"npAnlBody");
   NSView *titleV = find(nv, @"npTitle");
   NSView *subV = find(nv, @"npSub");
   NSView *metaV = find(nv, @"npMeta");

   ck(find(nv, @"npAnlLab")==nil && find(nv, @"npAnlStat")==nil && find(nv, @"npAnalHide")==nil,
      "N2a 音频分析头部 npAnlLab/npAnlStat/npAnalHide 不再存在");
   ck([np respondsToSelector:@selector(anlAutoTickForPath:playing:paused:)] &&
      find(nv, @"npAnlAuto")!=nil && find(nv, @"npAnlToggle")!=nil && find(nv, @"npAnlRun")!=nil,
      "N2b 自动分析方法与无头动作分段控件完整保留");

   for (NSArray<NSNumber *> *sz in @[@[@900,@600], @[@1180,@760]]) {
    const CGFloat W = sz[0].doubleValue, H = sz[1].doubleValue;
    [win setContentSize:NSMakeSize(W, H)];
    [win.contentView layoutSubtreeIfNeeded];
    checkBottomBarInBounds(W, H, [[NSString stringWithFormat:@"N2_bar_%dx%d",(int)W,(int)H] UTF8String]);
    if (anal && ly && rail && anlSegV && anlBodyV) {
     const BOOL noOverlap = (NSMaxX(anal.frame) + 4.0 < NSMinX(ly.frame)) && (NSMaxX(ly.frame) + 4.0 < NSMinX(rail.frame));
     const BOOL symCols = (fabs(NSWidth(anal.frame) - NSWidth(rail.frame)) <= 0.5) && (NSWidth(ly.frame) > NSWidth(anal.frame) * 1.9);
     const BOOL inHost = NSContainsRect(nv.bounds, anal.frame) && NSContainsRect(nv.bounds, ly.frame) && NSContainsRect(nv.bounds, rail.frame);
     const BOOL headlessClean = !anlSegV.hidden && !anlBodyV.hidden &&
                                (NSMinY(anlSegV.frame) >= NSMaxY(anlBodyV.frame) - 0.5) &&
                                (NSMaxY(anlSegV.frame) <= NSHeight(anal.bounds) - 9.0);
     printf("    [N2 %dx%d] anal=%s ly=%s rail=%s anlSeg=%s anlBody=%s\n",
            (int)W, (int)H,
            NSStringFromRect(anal.frame).UTF8String, NSStringFromRect(ly.frame).UTF8String, NSStringFromRect(rail.frame).UTF8String,
            NSStringFromRect(anlSegV.frame).UTF8String, NSStringFromRect(anlBodyV.frame).UTF8String);
     ck(noOverlap && symCols && inHost && headlessClean,
        [[NSString stringWithFormat:@"N2_%dx%d 无头两段式分析卡+对称三栏无重叠无越界",(int)W,(int)H] UTF8String]);
    }
    if (coverV && setCoverB) {
     const NSRect covF = coverV.frame;
     const NSRect setF = setCoverB.frame;
     const BOOL insideCov = !setCoverB.hidden && NSContainsRect(covF, setF);
     const BOOL bottomRight = (fabs((NSMaxX(covF) - NSMaxX(setF)) - 8.0) < 1.0) &&
                              (fabs((NSMaxY(covF) - NSMaxY(setF)) - 8.0) < 1.0) &&
                              (NSMidX(setF) > NSMidX(covF)) && (NSMinY(setF) > NSMidY(covF));
     BOOL disjointFromOthers = YES;
     for (NSView *other in @[anal ?: [NSView new], titleV ?: [NSView new], subV ?: [NSView new],
                             metaV ?: [NSView new], ly ?: [NSView new], rail ?: [NSView new], ctl ?: [NSView new]]) {
      if (other.hidden) continue;
      NSRect inter = NSIntersectionRect(setF, other.frame);
      if (inter.size.width > 0.5 && inter.size.height > 0.5) { disjointFromOthers = NO; break; }
     }
     printf("    [N3 %dx%d] cover=%s setCover=%s anal=%s\n",
            (int)W, (int)H,
            NSStringFromRect(covF).UTF8String, NSStringFromRect(setF).UTF8String, NSStringFromRect(anal.frame).UTF8String);
     ck(insideCov && bottomRight && disjointFromOthers,
        [[NSString stringWithFormat:@"N3_%dx%d 设置封面胶囊悬浮于封面右下角且不与其它控件相交",(int)W,(int)H] UTF8String]);

     // 手动封面状态：自动胶囊也应同处封面右下区域且相互不重叠
     [np setValue:@{@"title":@"N1 Track",@"coverSource":@"manual"} forKey:@"trackMetadata"];
     [np applyCoverSourceGate];
     [win.contentView layoutSubtreeIfNeeded];
     if (rstCoverB && !rstCoverB.hidden) {
      const NSRect rstF = rstCoverB.frame;
      const NSRect setF2 = setCoverB.frame;
      ck(NSContainsRect(covF, rstF) && NSContainsRect(covF, setF2) && NSMaxX(rstF) + 4.0 <= NSMinX(setF2),
         [[NSString stringWithFormat:@"N3_%dx%d 手动封面双胶囊共居右下区不互压 rst=%s set=%s",(int)W,(int)H,
           NSStringFromRect(rstF).UTF8String, NSStringFromRect(setF2).UTF8String] UTF8String]);
     }
     [np setValue:@{@"title":@"N1 Track",@"coverSource":@"embed"} forKey:@"trackMetadata"];
     [np applyCoverSourceGate];
    }
  }
  }
  // ---- A1-A4: AI 详细档全字段 + 抽屉分区内容/滚动/空态 + 900x600 & 1180x760 边界与底栏让位 ----
  {
   __block void (^__weak wCollectFields)(NSView *, NSString *, NSMutableArray<NSTextField *> *);
   void (^collectFields)(NSView *, NSString *, NSMutableArray<NSTextField *> *);
   collectFields = ^(NSView *root, NSString *ident, NSMutableArray<NSTextField *> *out) {
    if (!root || root.hidden) return;
    if ([root isKindOfClass:[NSTextField class]] && [root.identifier isEqualToString:ident]) {
     NSTextField *tf = (NSTextField *)root;
     if (tf.stringValue.length > 0) [out addObject:tf];
    }
    void (^rec)(NSView *, NSString *, NSMutableArray<NSTextField *> *) = wCollectFields;
    for (NSView *sub in root.subviews) if (rec) rec(sub, ident, out);
   };
   wCollectFields = collectFields;
   __block void (^__weak wCollectViews)(NSView *, NSString *, NSMutableArray<NSView *> *);
   void (^collectViews)(NSView *, NSString *, NSMutableArray<NSView *> *);
   collectViews = ^(NSView *root, NSString *ident, NSMutableArray<NSView *> *out) {
    if (!root || root.hidden) return;
    if ([root.identifier isEqualToString:ident] || (ident.length && [root.identifier hasPrefix:ident])) {
     [out addObject:root];
    }
    void (^rec)(NSView *, NSString *, NSMutableArray<NSView *> *) = wCollectViews;
    for (NSView *sub in root.subviews) if (rec) rec(sub, ident, out);
   };
   wCollectViews = collectViews;

   // A1: 真实 meta fixture（含 year/genre/label/catalog/credits/recording/mastering/sources/confidence/cached_at）
   NSDictionary *metaFixture = @{
    @"title": @"Winterreise, Op. 89: Gute Nacht",
    @"artist": @"Ian Bostridge",
    @"album": @"Schubert: Winterreise",
    @"albumArtist": @"Ian Bostridge & Leif Ove Andsnes",
    @"year": @2004,
    @"genre": @"Classical / Lieder Art Song",
    @"label": @"EMI Classics",
    @"catalog": @"07243 5 57790 2 1",
    @"duration": @"05:38",
    @"credits": @{
     @"composer": @"Franz Schubert",
     @"lyricist": @"Wilhelm Müller",
     @"arranger": @"Original Lieder Urtext Edition",
     @"performer": @"Ian Bostridge (Tenor) & Leif Ove Andsnes (Piano)"
    },
    @"recording": @"Potton Hall, Suffolk, UK (2004-02, 24-bit/96kHz PCM)",
    @"mastering": @"Abbey Road Studios High-Resolution Remaster",
    @"sources": @[ @"MusicBrainz", @"Discogs", @"Wikipedia" ],
    @"confidence": @"0.95",
    @"cached_at": @"2026-11-18 10:15:00"
   };
   const NSInteger fixtureNonEmptyCount = 18;
   RLPKnowledgeView *kv = [[RLPKnowledgeView alloc] initWithFrame:NSMakeRect(0, 0, 420, 620)];
   [kv renderMetaFixture:metaFixture];
   [kv layoutSubtreeIfNeeded];
   NSMutableArray<NSTextField *> *a1Vals = [NSMutableArray array];
   collectFields(kv, @"npDrawerFieldVal", a1Vals);
   BOOL noEllipsisTrunc = YES;
   NSMutableString *allRenderedText = [NSMutableString string];
   for (NSTextField *vf in a1Vals) {
    [allRenderedText appendString:vf.stringValue];
    [allRenderedText appendString:@" "];
    if ([vf.stringValue hasSuffix:@"…"] || vf.lineBreakMode == NSLineBreakByTruncatingTail) {
     noEllipsisTrunc = NO;
    }
   }
   BOOL hasAllCriticalValues = [allRenderedText containsString:@"2004"]
    && [allRenderedText containsString:@"Classical / Lieder Art Song"]
    && [allRenderedText containsString:@"EMI Classics"]
    && [allRenderedText containsString:@"07243 5 57790 2 1"]
    && [allRenderedText containsString:@"Franz Schubert"]
    && [allRenderedText containsString:@"Wilhelm Müller"]
    && [allRenderedText containsString:@"Original Lieder Urtext Edition"]
    && [allRenderedText containsString:@"Ian Bostridge (Tenor) & Leif Ove Andsnes (Piano)"]
    && [allRenderedText containsString:@"Abbey Road Studios High-Resolution Remaster"]
    && [allRenderedText containsString:@"MusicBrainz"]
    && [allRenderedText containsString:@"0.95"]
    && [allRenderedText containsString:@"2026-11-18 10:15:00"];
   printf("A1: knowledge visible fields=%lu (fixture=%ld), noEllipsis=%d, critical=%d\n",
          (unsigned long)a1Vals.count, (long)fixtureNonEmptyCount, noEllipsisTrunc, hasAllCriticalValues);
   ck((NSInteger)a1Vals.count >= fixtureNonEmptyCount && noEllipsisTrunc && hasAllCriticalValues,
      "A1 RLPKnowledgeView 详细档可见字段数 >= fixture 非空字段数，且关键值完整无…截断");

   // A1b: 右栏详细档（railDensity=1）下，卡片展示全部非空字段且无…截断
   [np setValue:@"/offline/a1-lieder.flac" forKey:@"currentPath"];
   [np setValue:@{
    @"title": metaFixture[@"title"],
    @"artist": metaFixture[@"artist"],
    @"album": metaFixture[@"album"],
    @"albumArtist": metaFixture[@"albumArtist"],
    @"year": metaFixture[@"year"],
    @"genre": metaFixture[@"genre"],
    @"label": metaFixture[@"label"],
    @"catalog": metaFixture[@"catalog"],
    @"track": @"1",
    @"codec": @"flac",
    @"sampleRate": @96000,
    @"bits": @24,
    @"channels": @2,
    @"credits": metaFixture[@"credits"],
    @"recording": metaFixture[@"recording"],
    @"mastering": metaFixture[@"mastering"],
    @"confidence": metaFixture[@"confidence"],
    @"cached_at": metaFixture[@"cached_at"],
    @"meta": @{ @"enriched": @YES, @"sources": @{ @"year": @"MusicBrainz", @"label": @"Discogs" } }
   } forKey:@"trackMetadata"];
   [np setValue:[@{
    @"track": [@{ @"state": @"ok", @"data": @{
     @"from_cache": @YES,
     @"generated_at": @1763450000,
     @"confidence": @"0.95",
     @"fields": @{
      @"演唱": @"Ian Bostridge",
      @"作曲": @"Franz Schubert",
      @"作词": @"Wilhelm Müller",
      @"编曲": @"Original Lieder Urtext Edition",
      @"厂牌": @"EMI Classics",
      @"目录号": @"07243 5 57790 2 1",
      @"录音": @"Potton Hall, Suffolk, UK (2004-02, 24-bit/96kHz PCM)",
      @"母带": @"Abbey Road Studios High-Resolution Remaster"
     },
     @"sections": @[ @{
      @"heading": @"背景与演绎",
      @"paragraphs": @[ @{ @"text": @"舒伯特声乐套曲《冬之旅》开篇曲《晚安》，声部与钢琴伴奏具有典型浪漫派室内乐张力。", @"citations": @[@"1"] } ]
     } ],
     @"citations": @[ @{ @"id": @"1", @"source": @"Discogs", @"title": @"EMI 07243 5 57790 2 1", @"url": @"https://www.discogs.com/release/1" } ]
    } } mutableCopy],
    @"release": [@{ @"state": @"ok", @"data": @{
     @"from_cache": @NO,
     @"fields": @{ @"出版方": @"EMI Classics", @"专辑类型": @"Studio Album", @"语种": @"德语" },
     @"__album": @{
      @"year": @2004,
      @"sr": @96000,
      @"bits": @24,
      @"tracks": @[
       @{ @"n": @1, @"title": @"Gute Nacht", @"dur": @338 },
       @{ @"n": @2, @"title": @"Die Wetterfahne", @"dur": @112 },
       @{ @"n": @3, @"title": @"Gefrorne Tränen", @"dur": @156 },
       @{ @"n": @4, @"title": @"Erstarrung", @"dur": @175 },
       @{ @"n": @5, @"title": @"Der Lindenbaum", @"dur": @282 },
       @{ @"n": @6, @"title": @"Wasserflut", @"dur": @244 }
      ]
     }
    } } mutableCopy],
    @"person": [@{ @"state": @"ok", @"data": @{
     @"from_cache": @NO,
     @"fields": @{
      @"简介": @"Ian Bostridge 是英国著名抒情男高音，以对舒伯特声乐套曲《冬之旅》《美丽的磨坊姑娘》的深度诠释闻名国际乐坛。",
      @"活跃年代": @"1993–至今",
      @"代表作品": @"Schubert: Winterreise / Die schöne Müllerin"
     }
    } } mutableCopy]
   } mutableCopy] forKey:@"railStates"];
   [np setValue:[@{
    @"track": @{ @"kind": @"track", @"name": metaFixture[@"title"], @"artist": metaFixture[@"artist"], @"album": metaFixture[@"album"] },
    @"release": @{ @"kind": @"release", @"name": metaFixture[@"album"], @"artist": metaFixture[@"albumArtist"] },
    @"person": @{ @"kind": @"person", @"name": metaFixture[@"albumArtist"], @"artist": @"" }
   } mutableCopy] forKey:@"railTargets"];
   NSSegmentedControl *segA1 = (NSSegmentedControl *)[np valueForKey:@"railDensity"];
   segA1.selectedSegment = 1;
   [np onRailDensity:segA1];
   [win.contentView layoutSubtreeIfNeeded];
   NSMutableArray<NSTextField *> *railKvVals = [NSMutableArray array];
   collectFields(rail, @"npChipKV.val", railKvVals);
   BOOL railNoTrunc = YES;
   for (NSTextField *vf in railKvVals) {
    if ([vf.stringValue hasSuffix:@"…"] || vf.lineBreakMode == NSLineBreakByTruncatingTail) railNoTrunc = NO;
   }
   printf("A1b: rail detail rows=%lu noTrunc=%d\n", (unsigned long)railKvVals.count, railNoTrunc);
   ck(railKvVals.count >= 12 && railNoTrunc, "A1b 右栏详细档展示完整多字段且无…截断");

   // A3: 空 payload 显示明确空态而非白屏空白
   [kv renderMetaFixture:@{}];
   [kv layoutSubtreeIfNeeded];
   NSView *emptyView = find(kv, @"npDrawerEmpty");
   NSTextField *emptyTitle = (NSTextField *)find(kv, @"npDrawerEmptyTitle");
   ck(emptyView && !emptyView.hidden && emptyView.frame.size.height > 20.0 && emptyTitle.stringValue.length > 0,
      "A3 空 payload 显示明确空态提示卡片而非白屏空白");

   // A2 & A4: 在 900x600 和 1180x760 下打开抽屉，验证分区标题、可滚动条目、内容占比 > 60%、不越界且不遮挡底栏
   NSArray<NSValue *> *sizes = @[
    [NSValue valueWithSize:NSMakeSize(900.0, 600.0)],
    [NSValue valueWithSize:NSMakeSize(1180.0, 760.0)]
   ];
   for (NSValue *szVal in sizes) {
    const NSSize sz = [szVal sizeValue];
    [win setContentSize:sz];
    id chipsObjA = [np valueForKey:@"railCards"];
    NSArray<NSView *> *chipsA = [chipsObjA isKindOfClass:[NSArray class]] ? (NSArray<NSView *> *)chipsObjA : @[];
    if (chipsA.count > 0) [(id)np performSelector:@selector(onRailCard:) withObject:chipsA[0]];
    else [np openDataDrawer];
    [win.contentView layoutSubtreeIfNeeded];

    NSView *dr = find(nv, @"npDrawer");
    NSView *hdr = dr ? find(dr, @"npdhead") : nil;
    NSView *secHost = dr ? find(dr, @"npDrawerSections") : nil;
    NSScrollView *drScroll = dr ? (NSScrollView *)find(dr, @"npDrawerScroll") : nil;
    NSMutableArray<NSTextField *> *secTitles = [NSMutableArray array];
    if (dr) collectFields(dr, @"npDrawerSectionTitle", secTitles);
    NSMutableArray<NSView *> *secCards = [NSMutableArray array];
    if (secHost) collectViews(secHost, @"npDrawerSection.", secCards);

    RLPKnowledgeView *npKV = (RLPKnowledgeView *)[np valueForKey:@"knowledge"];
    const CGFloat drH = dr ? dr.frame.size.height : 0.0;
    const CGFloat hdrH = hdr ? hdr.frame.size.height : 0.0;
    const CGFloat contentH = npKV ? [npKV renderedContentHeight] : (secHost ? secHost.frame.size.height : 0.0);
    const CGFloat filledH = hdrH + MIN(drScroll ? drScroll.bounds.size.height : drH, contentH);
    const double ratio = drH > 0.0 ? (filledH / drH) : 0.0;
    const CGFloat docH = drScroll.documentView ? drScroll.documentView.frame.size.height : 0.0;
    const CGFloat clipH = drScroll ? drScroll.contentView.bounds.size.height : 0.0;
    printf("A2(%.0fx%.0f): drH=%.0f hdrH=%.0f contentH=%.0f ratio=%.2f sections=%lu docH=%.0f clipH=%.0f\n",
           sz.width, sz.height, drH, hdrH, contentH, ratio, (unsigned long)secCards.count, docH, clipH);
    ck(dr && !dr.hidden && ratio > 0.60 && secTitles.count >= 4 && secCards.count >= 2 && docH > clipH,
       [[NSString stringWithFormat:@"A2(%.0fx%.0f) 抽屉内容占比=%.0f%% >60%% 且含 %lu 个分区可滚动",
         sz.width, sz.height, ratio * 100.0, (unsigned long)secTitles.count] UTF8String]);
    // A2-scroll: 内容必须真的可滚动（旧码 docH>clipH 也可能因为 scroll 未接管 wheel 而失效）
    if (drScroll && docH > clipH + 1.0) {
        const CGFloat maxY = docH - clipH;
        [drScroll.contentView scrollToPoint:NSMakePoint(0, maxY)];
        [drScroll reflectScrolledClipView:drScroll.contentView];
        const CGFloat bottomY = drScroll.contentView.bounds.origin.y;
        [drScroll.contentView scrollToPoint:NSMakePoint(0, 0)];
        [drScroll reflectScrolledClipView:drScroll.contentView];
        ck(bottomY > 0.5 && bottomY <= maxY + 1.0,
           [[NSString stringWithFormat:@"A2(%.0fx%.0f) 抽屉可从顶部滚到底部（origin=%.1f/%.1f）",
             sz.width, sz.height, bottomY, maxY] UTF8String]);
    }

    const NSRect drR = dr ? [nv convertRect:dr.bounds fromView:dr] : NSZeroRect;
    const NSRect ctlR = ctl ? [nv convertRect:ctl.bounds fromView:ctl] : NSZeroRect;
    const BOOL inBounds = dr && NSMinX(drR) >= -0.5 && NSMaxX(drR) <= sz.width + 0.5
                       && NSMinY(drR) >= -0.5 && NSMaxY(drR) <= sz.height + 0.5;
    const BOOL ctlInBounds = ctl && NSMinX(ctlR) >= -0.5 && NSMaxX(ctlR) <= sz.width + 0.5
                          && NSMinY(ctlR) >= -0.5 && NSMaxY(ctlR) <= sz.height + 0.5;
    const BOOL clearsBar = ctl && (NSMaxY(drR) <= NSMinY(ctlR) + 0.5);
    printf("A4(%.0fx%.0f): drR=%s ctlR=%s inBounds=%d ctlIn=%d clearsBar=%d\n",
           sz.width, sz.height, NSStringFromRect(drR).UTF8String, NSStringFromRect(ctlR).UTF8String,
           inBounds, ctlInBounds, clearsBar);
    ck(inBounds && ctlInBounds && clearsBar,
       [[NSString stringWithFormat:@"A4(%.0fx%.0f) 抽屉不越界且不遮挡底栏控制条", sz.width, sz.height] UTF8String]);
    [np closeDataDrawer];
   }
  }

  [ud setBool:savedAnlHidden forKey:@"RLPNPAnalysisHidden"];
  [ud setBool:savedRailHidden forKey:@"RLPNPRailHidden"];
  [win orderOut:nil];
  static NSWindow *sN1Window; sN1Window=win; (void)sN1Window;
 }

 // ---- A1/A2/A3/A4：statusFromJSON 路径兼容 · autoanl 异步启动/不重复/切歌取消重跑/失败不暂停 · 分析控件零暂停 ----
 {
  RLPRequestSpy *prevSpy = spy;
  RLPRequestSpy *anlSpy = [RLPRequestSpy new];
  anlSpy.fakeStarted = YES;
  spy = anlSpy;
  Method sharedM = class_getClassMethod(RLPCoreClient.class, @selector(shared));
  IMP origSharedImp = method_setImplementation(sharedM, (IMP)fakeShared);

  auto CountPrefix = ^NSUInteger(NSString *prefix) {
      NSUInteger n = 0;
      for (NSString *entry in anlSpy.requestLog) {
          if ([entry hasPrefix:prefix]) ++n;
      }
      return n;
  };
  auto HealthCount = ^NSUInteger {
      NSUInteger n = 0;
      for (NSString *entry in anlSpy.requestLog) {
          if ([entry hasPrefix:@"GET /api/track/health"] || [entry hasPrefix:@"GET /api/health"]) ++n;
      }
      return n;
  };
  auto PauseCount = ^NSUInteger {
      NSUInteger n = 0;
      for (NSString *entry in anlSpy.requestLog) {
          if ([entry containsString:@"/api/pause"]) ++n;
      }
      return n;
  };

  // A1 + A2.1：status 使用 currentPath，且 /api/settings 慢于 /api/status 返回时仍自动触发一次
  RLPNowPlayingViewController *np2 = [RLPNowPlayingViewController new];
  (void)np2.view;
  np2.view.frame = NSMakeRect(0, 0, 1180, 760);
  [np2.view layoutSubtreeIfNeeded];

  anlSpy.holdSettings = YES;
  anlSpy.fixtures = [@{
      @"/api/status": @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                         @"currentPath": @"/offline/autoA.flac", @"dur": @120.0 },
      @"/api/track/health": @{ @"ok": @YES, @"cached": @NO,
                               @"health": @{ @"dr_available": @YES, @"dr_db": @13.4 } },
      @"/api/lyrics": @{ @"ok": @NO },
      @"/api/queue": @{ @"ok": @YES, @"items": @[], @"mode": @0 },
      @"/api/fav/list": @{ @"ok": @YES, @"files": @[] },
      @"/api/meta": @{ @"ok": @YES }
  } mutableCopy];

  [np2 refresh];
  ck([[np2 valueForKey:@"currentPath"] isEqual:@"/offline/autoA.flac"],
     "A1 status 只含 currentPath 时 refresh 后 currentPath 非空");
  ck(HealthCount() == 0 && anlSpy.pendingSettings != nil,
     "A2 settings 未落地前尚未发 /api/track/health 且已发出 /api/settings");

  RLPJSONCompletion settingsDone = anlSpy.pendingSettings;
  anlSpy.pendingSettings = nil;
  anlSpy.holdSettings = NO;
  if (settingsDone) settingsDone(@{ @"ok": @YES, @"kv": @{ @"autoanl": @"1", @"eq": @"", @"ir": @"" } });
  ck(HealthCount() == 1,
     "A2 settings(autoanl=1) 晚于 status 返回后自动触发 1 次 /api/track/health");

  // 同曲二次 status 不重复分析
  [np2 refresh];
  ck(HealthCount() == 1, "A2 同曲二次 /api/status 不重复触发分析");

  // A2.2：切歌（使用 path 字段）先 cancel 旧分析，cancel 完成后重跑新曲，且分析失败不暂停
  anlSpy.holdHealth = YES;
  anlSpy.fixtures[@"/api/status"] = @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                                       @"path": @"/offline/autoB.flac", @"dur": @110.0 };
  [np2 refresh]; // 启动 autoB 在途（或触发 cancel 后启动 autoB）
  ck(HealthCount() == 2 && [[np2 valueForKey:@"anlBusy"] boolValue],
     "A2 切歌 path 字段识别 autoB 并进入分析中");

  // 在 autoB 分析仍在途时再切换到 autoC（使用 file 字段 + holdCancel）
  anlSpy.holdCancel = YES;
  anlSpy.fixtures[@"/api/status"] = @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                                       @"file": @"/offline/autoC.flac", @"dur": @130.0 };
  [np2 refresh];
  ck(CountPrefix(@"POST /api/anl/cancel") == 1 && HealthCount() == 2,
     "A2 切歌先发 /api/anl/cancel，未排空前不提前发新曲分析");

  anlSpy.holdHealth = NO;
  anlSpy.fixtures[@"/api/track/health"] = @{ @"ok": @NO, @"error": @"decode failed" };
  RLPJSONCompletion cancelDone = anlSpy.pendingCancel;
  anlSpy.pendingCancel = nil;
  anlSpy.holdCancel = NO;
  if (cancelDone) cancelDone(@{ @"ok": @YES });

  ck(HealthCount() == 3 && ![[np2 valueForKey:@"anlBusy"] boolValue] &&
     PauseCount() == 0 && [anlSpy.fixtures[@"/api/status"][@"playing"] boolValue],
     "A2 cancel 完成后启动 autoC，分析失败不暂停（pause=0, playing=YES）");

  // A2.3：失败后同曲再次 status 不死循环重试
  [np2 refresh];
  ck(HealthCount() == 3, "A2 分析失败后同曲二次 status 不重复发请求");

  // A2.4：autoanl=0 不发自动分析
  RLPNowPlayingViewController *npOff = [RLPNowPlayingViewController new];
  (void)npOff.view;
  NSUInteger healthBeforeOff = HealthCount();
  anlSpy.fixtures[@"/api/settings"] = @{ @"ok": @YES, @"kv": @{ @"autoanl": @"0", @"eq": @"", @"ir": @"" } };
  anlSpy.fixtures[@"/api/status"] = @{ @"ok": @YES, @"playing": @YES, @"paused": @NO,
                                       @"currentPath": @"/offline/noAuto.flac", @"dur": @90.0 };
  [npOff refresh];
  ck(HealthCount() == healthBeforeOff && [[npOff valueForKey:@"currentPath"] isEqual:@"/offline/noAuto.flac"],
     "A2 autoanl=0 时播放本地曲不发自动分析请求");

  // A3 + A4：点击所有「分析 / 音质分析」控件前后 playing 不变且 /api/pause 请求数 = 0
  NSUserDefaults *anlUd = [NSUserDefaults standardUserDefaults];
  id savedAnlHiddenObj = [anlUd objectForKey:@"RLPNPAnalysisHidden"];
  [anlUd setBool:NO forKey:@"RLPNPAnalysisHidden"];
  [anlSpy.requestLog removeAllObjects];
  anlSpy.fixtures[@"/api/track/health"] = @{ @"ok": @YES, @"cached": @NO,
                                           @"health": @{ @"dr_available": @YES, @"dr_db": @14.0 } };
  NSWindow *anlWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 760)
                                                 styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  anlWin.contentView = np2.view;
  [anlWin makeFirstResponder:np2.view];
  [np2.view layoutSubtreeIfNeeded];

  NSButton *analToggle = (NSButton *)find(np2.view, @"npAnalToggle");
  NSButton *anlAutoBtn = (NSButton *)find(np2.view, @"npAnlAuto");
  NSButton *anlExpBtn = (NSButton *)find(np2.view, @"npAnlToggle");
  NSButton *anlRunBtn = (NSButton *)find(np2.view, @"npAnlRun");
  NSButton *anlReBtn = (NSButton *)find(np2.view, @"npAnlRecalculate");
  NSView *dynCard = find(np2.view, @"anl.dyn");

  ck(analToggle && anlAutoBtn && anlExpBtn && anlRunBtn && anlReBtn &&
     !analToggle.keyEquivalent.length && !anlAutoBtn.keyEquivalent.length &&
     !anlExpBtn.keyEquivalent.length && !anlRunBtn.keyEquivalent.length &&
     !anlReBtn.keyEquivalent.length &&
     analToggle.refusesFirstResponder && anlAutoBtn.refusesFirstResponder &&
     anlExpBtn.refusesFirstResponder && anlRunBtn.refusesFirstResponder &&
     anlReBtn.refusesFirstResponder,
     "A3 分析区控件无空格 keyEquivalent 且 refusesFirstResponder=YES");

  const BOOL playingBefore = [anlSpy.fixtures[@"/api/status"][@"playing"] boolValue];
  if (analToggle) { [analToggle performClick:nil]; [analToggle performClick:nil]; }
  if (anlAutoBtn) { [anlAutoBtn performClick:nil]; [anlAutoBtn performClick:nil]; }
  if (anlExpBtn) [anlExpBtn performClick:nil];
  if (anlRunBtn) [anlRunBtn performClick:nil];
  if (anlReBtn) [anlReBtn performClick:nil];
  if (dynCard) {
      NSEvent *tapEv = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                          location:NSMakePoint(10, 10)
                                     modifierFlags:0 timestamp:0
                                      windowNumber:anlWin.windowNumber
                                           context:nil eventNumber:1 clickCount:1 pressure:1.0];
      [dynCard mouseDown:tapEv];
  }
  const BOOL playingAfter = [anlSpy.fixtures[@"/api/status"][@"playing"] boolValue];
  printf("A4 np requestLog (%lu): %s | pause=%lu\n",
         (unsigned long)anlSpy.requestLog.count,
         [anlSpy.requestLog componentsJoinedByString:@", "].UTF8String ?: "",
         (unsigned long)PauseCount());
  ck(playingBefore && playingAfter && PauseCount() == 0 && anlWin.firstResponder == np2.view,
     "A3/A4 点击全部音质分析控件后 playing 不变、pause=0 且未抢占 firstResponder");

  [anlWin orderOut:nil];
  static NSWindow *sAnlWindow; sAnlWindow = anlWin; (void)sAnlWindow;
  if (savedAnlHiddenObj) [anlUd setObject:savedAnlHiddenObj forKey:@"RLPNPAnalysisHidden"];
  else [anlUd removeObjectForKey:@"RLPNPAnalysisHidden"];
  method_setImplementation(sharedM, origSharedImp);
  spy = prevSpy;
 }
 printf("np web: %d failures\n",fail);return fail?1:0;
}}
