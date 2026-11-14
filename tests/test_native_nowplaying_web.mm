// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "RLPNowPlayingViewController.h"
#import "RLPTheme.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import <objc/runtime.h>
#include <cmath>
#include <cstdio>
static NSString *lastPath,*lastBody;static RLPJSONCompletion pendingFav;
@interface RLPRequestSpy : NSObject
/// 按路径前缀返回固定 JSON 的桩：状态机判据要「真的走一遍 /api/status → 渲染」，
/// 不能只把 webStatus 塞进 KVC（那样 refresh 里的复位分支根本没跑）。
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *fixtures;
@end
@implementation RLPRequestSpy
- (BOOL)started{return NO;}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {lastPath=path;lastBody=body;if([path hasPrefix:@"/api/fav?"])pendingFav=[done copy];}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {
    id hit=nil;
    for(NSString *key in self.fixtures) if([path hasPrefix:key]){hit=self.fixtures[key];break;}
    if(done)done([hit isKindOfClass:[NSDictionary class]]?hit:nil);
}
/// refresh 会在切曲分支顺带 loadCoverForPath（/api/cover 走 getData）：桩必须应答，
/// 否则刷新路径上第一个 getData 就是 doesNotRecognizeSelector（实测 SIGABRT）。
- (void)getData:(NSString *)path completion:(RLPDataCompletion)done { if(done)done(nil); }
@end
static RLPRequestSpy *spy;static id fakeShared(id c,SEL s){return spy;}
static int fail;
static NSView *find(NSView *v, NSString *key) { if([v.identifier isEqual:key])return v; for(NSView *s in v.subviews){NSView *r=find(s,key);if(r)return r;}return nil; }
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
 id controls=[vc valueForKey:@"webControls"];NSSlider *seek=[controls valueForKey:@"seek"];seek.doubleValue=.5;[vc onCommitSeek:nil];ck([lastPath isEqual:@"/api/seek?pos=0.500000"],"seek uses real backend pos parameter, not ignored ratio");
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

 // ---- 侧栏面板内置收起键：web #npAnalHide / #npRailHide（22x22 圆形，与顶栏开关同源状态）----
 // 旧码只有右上角两个总开关，面板头部没有 web 的那枚收起键（元素缺失）。
 {
  [(NSView *)vc.view layoutSubtreeIfNeeded];   // 面板是内层视图，尺寸由 layoutWebPlayback 写
  NSButton *anlHide=(NSButton *)find(vc.view,@"npAnalHide");
  NSButton *railHide=(NSButton *)find(vc.view,@"npRailHide");
  ck(anlHide!=nil,"web #npAnalHide panel-local hide key exists");
  ck(railHide!=nil,"web #npRailHide panel-local hide key exists");
  if(anlHide&&railHide){
    ck(fabs(anlHide.frame.size.width-22)<0.6&&fabs(anlHide.frame.size.height-22)<0.6,
       "npAnalHide is 22x22 like web .anlhide");
    ck(fabs(railHide.frame.size.width-22)<0.6&&fabs(railHide.frame.size.height-22)<0.6,
       "npRailHide is 22x22 like web .nprailhide");
    ck(anlHide.wantsLayer&&anlHide.layer.cornerRadius>=10.5, "npAnalHide is a circle (web border-radius:50%)");
    NSView *ap=[vc valueForKey:@"analysisPanel"];NSView *rp=[vc valueForKey:@"railPanel"];
    [anlHide performClick:nil];
    ck(ap.hidden,"npAnalHide hides the analysis panel");
    ck([[NSUserDefaults standardUserDefaults] boolForKey:@"RLPNPAnalysisHidden"],
       "npAnalHide persists the same hidden state as the top-right toggle");
    ap.hidden=NO;[[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"RLPNPAnalysisHidden"];
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
 pendingFav=nil;method_setImplementation(shared,old);
 printf("np web: %d failures\n",fail);return fail?1:0;
}}
