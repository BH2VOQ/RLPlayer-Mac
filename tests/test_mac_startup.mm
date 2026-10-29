// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include "net/ui_page.h"
#include <cstdio>
#include <chrono>
// Manual opt-in: own off-screen nonpersistent WebKit, no desktop input or audio.
int main(){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 auto config=[WKWebViewConfiguration new];config.websiteDataStore=[WKWebsiteDataStore nonPersistentDataStore];
 WKWebView* web=[[WKWebView alloc]initWithFrame:NSMakeRect(0,0,320,240) configuration:config];
 web.underPageBackgroundColor=[NSColor colorWithSRGBRed:22./255 green:22./255 blue:24./255 alpha:1];
 NSWindow* win=[[NSWindow alloc]initWithContentRect:NSMakeRect(-10000,-10000,320,240) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
 win.contentView=web;[win orderBack:nil];
 std::string html=rta::net::rta_ui_page();
 // Stop external app.js loading: test only first HTML/theme paint and an offline marker.
 auto script=html.find("<script src=");if(script!=std::string::npos)html.erase(script);
 html+="<script>window.startupReady=true;</script></body></html>";
 [web loadHTMLString:[NSString stringWithUTF8String:html.c_str()] baseURL:[NSURL URLWithString:@"https://startup.invalid/"]];
 __block bool ready=false;int samples=0;bool white=false;bool valid=false;
 const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(8);
 while(std::chrono::steady_clock::now()<deadline && samples<10){
  [[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
  [web evaluateJavaScript:@"window.startupReady===true" completionHandler:^(id value,NSError* error){if(!error)ready=[value boolValue];}];
  if(!ready)continue;
  __block bool done=false;__block NSImage* image=nil;
  [web takeSnapshotWithConfiguration:nil completionHandler:^(NSImage* i,NSError* e){image=i;done=true;}];
  NSDate* until=[NSDate dateWithTimeIntervalSinceNow:1];
  while(!done&&until.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
  if(!image)continue;
  NSBitmapImageRep* pixels=[NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
  if(!pixels)continue;
  NSColor* color=[[pixels colorAtX:310 y:230]colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if(color){++samples;valid=true;white=white||(color.redComponent>.98&&color.greenComponent>.98&&color.blueComponent>.98);printf("sample=%d rgb=%.4f,%.4f,%.4f\n",samples,color.redComponent,color.greenComponent,color.blueComponent);}
 }
 [win orderOut:nil];
 printf("%s own offscreen WebKit painted dark background (%d samples); this does not prove WindowServer prepaint frames\n",valid&&!white?"PASS":"UNVERIFIED",samples);
 return valid&&!white?0:2;
}}
