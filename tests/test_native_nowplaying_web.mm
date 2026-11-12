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
@end
@implementation RLPRequestSpy
- (BOOL)started{return NO;}
- (void)postJSON:(NSString *)path body:(NSString *)body completion:(RLPJSONCompletion)done {lastPath=path;lastBody=body;if([path hasPrefix:@"/api/fav?"])pendingFav=[done copy];}
- (void)getJSON:(NSString *)path completion:(RLPJSONCompletion)done {if(done)done(nil);}
@end
static id spy;static id fakeShared(id c,SEL s){return spy;}
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
 pendingFav=nil;method_setImplementation(shared,old);
 printf("np web: %d failures\n",fail);return fail?1:0;
}}
