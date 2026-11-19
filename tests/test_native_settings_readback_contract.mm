// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_settings_readback_contract.mm — 设置页 reloadData 全量回填契约判据
//
// 证明：
//   1. reloadData 对 buffer/ramp/phase/taps/transition/twostage/shaper/sdmfilt/sdmfiltnx/
//      modcut/moddith/dsdkind/dsdconv/scanthreads 的真实控件回读；
//   2. 播放模式（/api/playmode → sp_rep + sp_shuf）与音乐目录（/api/lib/roots → sp_roots）回读；
//   3. /api/filters 与 /api/settings 乱序到达（settings先/filters后、filters先/settings后）；
//   4. 空串跟随（filterNx="" / sdmfilt="" / sdmfiltnx="" / phase="" 选回首项）；
//   5. 惰性页签创建（adv -> out -> pcm -> sdm）；
//   6. 主题重建（paneCache 清空重建后各页签仍回读真实 kv）。
//
// 纪律：隔离 state/library；backend=null、volume=-120；不播放、不联网。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPTheme.h"
#import "RLPSettingsViewController.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void Ck(BOOL ok, NSString *what, NSString *detail) {
    if (ok) {
        ++gPass;
        std::printf("  [PASS] %s\n", what.UTF8String);
    } else {
        ++gFail;
        std::printf("  [FAIL] %s — %s\n", what.UTF8String, detail.UTF8String ?: "");
    }
}

static void Pump(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^pred)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0) {
        if (pred()) return YES;
        Pump(0.03);
    }
    return pred();
}

static void Collect(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) Collect(s, out);
}

static NSArray<NSView *> *Descendants(NSView *v) {
    NSMutableArray<NSView *> *a = [NSMutableArray array];
    Collect(v, a);
    return a;
}

static NSView *FindId(NSView *root, NSString *ident) {
    for (NSView *v in Descendants(root))
        if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}

static NSString *PopupValue(NSPopUpButton *p) {
    if (!p || !p.selectedItem) return @"";
    id ro = p.selectedItem.representedObject;
    if ([ro isKindOfClass:[NSString class]]) return (NSString *)ro;
    return p.titleOfSelectedItem ?: @"";
}

// ---- 测试专用：确定性控制 /api/filters 与 /api/settings 的完成块到达顺序 ----
typedef void (^RLPJsonDone)(NSDictionary * _Nullable json);
static IMP gOrigGetJSON = NULL;
static NSString *gDelayPathPrefix = nil;
static RLPJsonDone gDelayedBlock = nil;
static NSDictionary *gDelayedPayload = nil;
static BOOL gDelayDone = NO;

static void SwizzledGetJSON(id self, SEL _cmd, NSString *path, RLPJsonDone completion) {
    // 只扣第一次匹配的 GET；在途保存本身也可能再发 GET，若覆盖该槽，flush 时送出的
    // 就不是原本要验证的旧回包（A2 曾因此把 POST 的空响应当成读回结果）。
    if (gDelayPathPrefix.length && gDelayedBlock == nil && [path hasPrefix:gDelayPathPrefix]) {
        void (*orig)(id, SEL, NSString *, RLPJsonDone) = (void (*)(id, SEL, NSString *, RLPJsonDone))gOrigGetJSON;
        orig(self, _cmd, path, ^(NSDictionary * _Nullable json) {
            gDelayedPayload = json;
            gDelayedBlock = [completion copy];
            gDelayDone = YES;
        });
        return;
    }
    void (*orig)(id, SEL, NSString *, RLPJsonDone) = (void (*)(id, SEL, NSString *, RLPJsonDone))gOrigGetJSON;
    orig(self, _cmd, path, completion);
}

static void InstallOrderHook(void) {
    if (gOrigGetJSON) return;
    Method m = class_getInstanceMethod([RLPCoreClient class], @selector(getJSON:completion:));
    gOrigGetJSON = method_setImplementation(m, (IMP)SwizzledGetJSON);
}

static void FlushDelayed(void) {
    RLPJsonDone blk = gDelayedBlock;
    NSDictionary *payload = gDelayedPayload;
    gDelayedBlock = nil;
    gDelayedPayload = nil;
    gDelayDone = NO;
    gDelayPathPrefix = nil;
    if (blk) blk(payload);
}

@interface RLPSettingsViewController (CoreParityTest)
- (void)applyUpnpDevicesPayload:(NSDictionary *)json;
- (void)postKey:(NSString *)key value:(NSString *)value completion:(void (^ _Nullable)(BOOL ok))completion;
@property (nonatomic, copy) NSString *savedUpnpDev;
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_settings_readback_contract（隔离目录 · backend=null · volume=-120）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-readback-%d", (int)getpid()]];
        NSString *state = [rootDir stringByAppendingPathComponent:@"state"];
        NSString *lib = [rootDir stringByAppendingPathComponent:@"lib"];
        NSString *musicDir = [rootDir stringByAppendingPathComponent:@"music"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:musicDir withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);

        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) {
            std::printf("  [FAIL] 核心启动失败\n");
            return 1;
        }

        // 先取真实 /api/filters 列表里的两个滤波器名，不臆造
        NSDictionary *filtResp = [core jsonWithMethod:@"GET" path:@"/api/filters" body:nil];
        NSArray *filtItems = [filtResp[@"items"] isKindOfClass:[NSArray class]] ? filtResp[@"items"] : @[];
        NSString *f1 = nil, *f2 = nil;
        for (id it in filtItems) {
            NSString *n = [it isKindOfClass:[NSDictionary class]] ? it[@"name"] : ([it isKindOfClass:[NSString class]] ? it : nil);
            if (!n.length) continue;
            if (!f1) f1 = n;
            else if (![n isEqualToString:f1]) { f2 = n; break; }
        }
        Ck(f1.length > 0 && f2.length > 0, @"前置：从 /api/filters 取得两个真实滤波器",
           [NSString stringWithFormat:@"f1=%@ f2=%@", f1, f2]);
        if (!f1.length) f1 = @"poly-sinc-lp";
        if (!f2.length) f2 = @"poly-sinc-mp";

        // 写入全量非默认设置到真实后端
        NSString *postBody = [NSString stringWithFormat:
            @"backend=null&volume=-120&buffer=120&ramp=35&phase=minimum&taps=2048"
             "&transition=0.08&twostage=1&shaper=LNS15"
             "&filter=%@&filterNx=%@&sdmfilt=%@&sdmfiltnx=%@"
             "&modcut=125&moddith=0.5&dsdkind=iir&dsdconv=wide&scanthreads=3",
            f1, f2, f2, f1];
        NSDictionary *setRes = [core jsonWithMethod:@"POST" path:@"/api/settings" body:postBody];
        Ck([setRes[@"ok"] boolValue], @"前置：POST /api/settings 成功", [setRes description]);

        // 设置播放模式 mode=2（单曲循环）
        NSDictionary *pmRes = [core jsonWithMethod:@"POST" path:@"/api/playmode?mode=2" body:@""];
        Ck([pmRes[@"ok"] boolValue] && [pmRes[@"mode"] integerValue] == 2,
           @"前置：POST /api/playmode?mode=2 成功", [pmRes description]);

        // 添加真实音乐目录
        NSString *encDir = [musicDir stringByAddingPercentEncodingWithAllowedCharacters:
                            [NSCharacterSet URLQueryAllowedCharacterSet]];
        NSDictionary *rootRes = [core jsonWithMethod:@"POST" path:@"/api/lib/roots"
                                              body:[@"add=" stringByAppendingString:encDir]];
        Ck([rootRes[@"ok"] boolValue], @"前置：POST /api/lib/roots 添加音乐目录成功", [rootRes description]);

        // 创建离屏窗口与设置页（初始停在默认页签 adv）
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 900)
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        win.releasedWhenClosed = NO;
        win.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 900)];
        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        NSView *v = settings.view;
        [win.contentView addSubview:v];
        v.frame = win.contentView.bounds;
        [settings activate];

        // ---- 1. 默认页签 adv（通用）：scanthreads / rep / shuf / roots ----
        BOOL advReady = WaitUntil(6.0, ^BOOL {
            NSTextField *st = (NSTextField *)FindId(v, @"sp_scanthreads");
            NSPopUpButton *rep = (NSPopUpButton *)FindId(v, @"sp_rep");
            NSStackView *rb = (NSStackView *)FindId(v, @"sp_roots");
            return st && [st.stringValue isEqualToString:@"3"] &&
                   rep && rep.indexOfSelectedItem == 1 &&
                   rb && rb.arrangedSubviews.count > 0;
        });
        (void)advReady;
        NSTextField *scanField = (NSTextField *)FindId(v, @"sp_scanthreads");
        NSPopUpButton *repPop = (NSPopUpButton *)FindId(v, @"sp_rep");
        NSSwitch *shufSw = (NSSwitch *)FindId(v, @"sp_shuf");
        NSStackView *rootsBox = (NSStackView *)FindId(v, @"sp_roots");
        Ck([scanField.stringValue isEqualToString:@"3"], @"adv: scanthreads 回读 = 3", scanField.stringValue);
        Ck(repPop.indexOfSelectedItem == 1, @"adv: sp_rep 回读 mode=2 -> 单曲循环(index 1)",
           [NSString stringWithFormat:@"idx=%ld title=%@", (long)repPop.indexOfSelectedItem, repPop.titleOfSelectedItem]);
        Ck(shufSw.state == NSControlStateValueOff, @"adv: sp_shuf 回读 mode=2 -> Off",
           [NSString stringWithFormat:@"state=%ld", (long)shufSw.state]);
        NSString *resolvedMusicDir = [musicDir stringByResolvingSymlinksInPath];
        BOOL foundMusicRoot = NO;
        NSMutableArray<NSString *> *rootTexts = [NSMutableArray array];
        for (NSView *sub in rootsBox.arrangedSubviews) {
            if ([sub isKindOfClass:[NSTextField class]]) {
                NSString *txt = ((NSTextField *)sub).stringValue ?: @"";
                [rootTexts addObject:txt];
                if ([txt isEqualToString:musicDir] || [txt isEqualToString:resolvedMusicDir]) {
                    foundMusicRoot = YES;
                }
            }
        }
        Ck(foundMusicRoot, @"adv: sp_roots 回读真实音乐目录",
           [NSString stringWithFormat:@"count=%lu items=%@", (unsigned long)rootsBox.arrangedSubviews.count,
            [rootTexts componentsJoinedByString:@","]]);

        // ---- 2. 惰性创建 out 页签：buffer / ramp ----
        [settings selectPane:@"out"];
        WaitUntil(6.0, ^BOOL {
            NSTextField *bf = (NSTextField *)FindId(v, @"sp_buffer");
            NSTextField *rf = (NSTextField *)FindId(v, @"sp_ramp");
            return bf && [bf.stringValue isEqualToString:@"120"] && rf && [rf.stringValue isEqualToString:@"35"];
        });
        NSTextField *bufField = (NSTextField *)FindId(v, @"sp_buffer");
        NSTextField *rampField = (NSTextField *)FindId(v, @"sp_ramp");
        Ck([bufField.stringValue isEqualToString:@"120"], @"out(惰性): buffer 回读 = 120", bufField.stringValue);
        Ck([rampField.stringValue isEqualToString:@"35"], @"out(惰性): ramp 回读 = 35", rampField.stringValue);

        // ---- 3. 惰性创建 pcm 页签：phase / taps / transition / twostage / shaper / filter / filterNx ----
        [settings selectPane:@"pcm"];
        WaitUntil(6.0, ^BOOL {
            NSTextField *tp = (NSTextField *)FindId(v, @"sp_taps");
            NSPopUpButton *f1p = (NSPopUpButton *)FindId(v, @"sp_filt");
            return tp && [tp.stringValue isEqualToString:@"2048"] && f1p && f1p.numberOfItems > 2;
        });
        NSPopUpButton *phasePop = (NSPopUpButton *)FindId(v, @"sp_phase");
        NSTextField *tapsField = (NSTextField *)FindId(v, @"sp_taps");
        NSTextField *transField = (NSTextField *)FindId(v, @"sp_transition");
        NSSwitch *twoStageSw = (NSSwitch *)FindId(v, @"sp_2s");
        NSPopUpButton *shaperPop = (NSPopUpButton *)FindId(v, @"sp_shaper");
        NSPopUpButton *filt1Pop = (NSPopUpButton *)FindId(v, @"sp_filt");
        NSPopUpButton *filtNxPop = (NSPopUpButton *)FindId(v, @"sp_filtNx");
        Ck([phasePop.titleOfSelectedItem isEqualToString:@"minimum"], @"pcm(惰性): phase 回读 = minimum", phasePop.titleOfSelectedItem);
        Ck([tapsField.stringValue isEqualToString:@"2048"], @"pcm(惰性): taps 回读 = 2048", tapsField.stringValue);
        Ck([transField.stringValue isEqualToString:@"0.08"], @"pcm(惰性): transition 回读 = 0.08", transField.stringValue);
        Ck(twoStageSw.state == NSControlStateValueOn, @"pcm(惰性): twostage 回读 = On",
           [NSString stringWithFormat:@"state=%ld", (long)twoStageSw.state]);
        Ck([shaperPop.titleOfSelectedItem isEqualToString:@"LNS15"], @"pcm(惰性): shaper 回读 = LNS15", shaperPop.titleOfSelectedItem);
        Ck([PopupValue(filt1Pop) isEqualToString:f1], @"pcm(惰性): filter 回读真实名", PopupValue(filt1Pop));
        Ck([PopupValue(filtNxPop) isEqualToString:f2], @"pcm(惰性): filterNx 回读真实名", PopupValue(filtNxPop));

        // ---- 4. 惰性创建 sdm 页签：sdmfilt / sdmfiltnx / modcut / moddith / dsdkind / dsdconv ----
        [settings selectPane:@"sdm"];
        WaitUntil(6.0, ^BOOL {
            NSTextField *mc = (NSTextField *)FindId(v, @"sp_modcut");
            NSPopUpButton *so1 = (NSPopUpButton *)FindId(v, @"sp_sdmo1");
            return mc && [mc.stringValue isEqualToString:@"125"] && so1 && so1.numberOfItems > 2;
        });
        NSPopUpButton *sdmO1Pop = (NSPopUpButton *)FindId(v, @"sp_sdmo1");
        NSPopUpButton *sdmONxPop = (NSPopUpButton *)FindId(v, @"sp_sdmoNx");
        NSTextField *modCutField = (NSTextField *)FindId(v, @"sp_modcut");
        NSTextField *modDithField = (NSTextField *)FindId(v, @"sp_moddith");
        NSPopUpButton *dsdKindPop = (NSPopUpButton *)FindId(v, @"sp_dsdkind");
        NSPopUpButton *dsdConvPop = (NSPopUpButton *)FindId(v, @"sp_dsdconv");
        Ck([PopupValue(sdmO1Pop) isEqualToString:f2], @"sdm(惰性): sdmfilt 回读真实名", PopupValue(sdmO1Pop));
        Ck([PopupValue(sdmONxPop) isEqualToString:f1], @"sdm(惰性): sdmfiltnx 回读真实名", PopupValue(sdmONxPop));
        Ck([modCutField.stringValue isEqualToString:@"125"], @"sdm(惰性): modcut 回读 = 125", modCutField.stringValue);
        Ck([modDithField.stringValue isEqualToString:@"0.5"], @"sdm(惰性): moddith 回读 = 0.5", modDithField.stringValue);
        Ck([dsdKindPop.titleOfSelectedItem isEqualToString:@"iir"], @"sdm(惰性): dsdkind 回读 = iir", dsdKindPop.titleOfSelectedItem);
        Ck([dsdConvPop.titleOfSelectedItem isEqualToString:@"wide"], @"sdm(惰性): dsdconv 回读 = wide", dsdConvPop.titleOfSelectedItem);

        // ---- 5. 空串跟随 + 随机模式(mode=3) + 乱序到达（settings先 / filters后）----
        [core jsonWithMethod:@"POST" path:@"/api/settings"
                      body:@"filterNx=&sdmfilt=&sdmfiltnx=&phase=&twostage=0"];
        [core jsonWithMethod:@"POST" path:@"/api/playmode?mode=3" body:@""];

        InstallOrderHook();
        // 5a: 强制 /api/settings 先到，/api/filters 后到
        gDelayPathPrefix = @"/api/filters";
        gDelayDone = NO;
        [settings reloadData];
        WaitUntil(5.0, ^BOOL { return gDelayDone; });
        Pump(0.15);
        FlushDelayed();
        Pump(0.15);

        Ck(sdmO1Pop.indexOfSelectedItem == 0 && [PopupValue(sdmO1Pop) isEqualToString:@""],
           @"乱序(settings先)+空串跟随: sdmfilt=\"\" 选中首项",
           [NSString stringWithFormat:@"idx=%ld val=%@", (long)sdmO1Pop.indexOfSelectedItem, PopupValue(sdmO1Pop)]);
        Ck(sdmONxPop.indexOfSelectedItem == 0 && [PopupValue(sdmONxPop) isEqualToString:@""],
           @"乱序(settings先)+空串跟随: sdmfiltnx=\"\" 选中首项",
           [NSString stringWithFormat:@"idx=%ld val=%@", (long)sdmONxPop.indexOfSelectedItem, PopupValue(sdmONxPop)]);
        Ck(filtNxPop.indexOfSelectedItem == 0 && [PopupValue(filtNxPop) isEqualToString:@""],
           @"乱序(settings先)+空串跟随: filterNx=\"\" 选中首项",
           [NSString stringWithFormat:@"idx=%ld val=%@", (long)filtNxPop.indexOfSelectedItem, PopupValue(filtNxPop)]);
        Ck(phasePop.indexOfSelectedItem == 0,
           @"空串跟随: phase=\"\" 选中首项",
           [NSString stringWithFormat:@"idx=%ld", (long)phasePop.indexOfSelectedItem]);
        Ck(twoStageSw.state == NSControlStateValueOff, @"twostage=0 回读 Off",
           [NSString stringWithFormat:@"state=%ld", (long)twoStageSw.state]);
        Ck(repPop.indexOfSelectedItem == 2 && shufSw.state == NSControlStateValueOn,
           @"playmode=3(随机): sp_rep=关闭循环(2) 且 sp_shuf=On",
           [NSString stringWithFormat:@"rep=%ld shuf=%ld", (long)repPop.indexOfSelectedItem, (long)shufSw.state]);

        // 5b: 再写回非空 sdmfilt / sdmfiltnx / filterNx，强制 /api/filters 先到，/api/settings 后到
        [core jsonWithMethod:@"POST" path:@"/api/settings"
                      body:[NSString stringWithFormat:@"filterNx=%@&sdmfilt=%@&sdmfiltnx=%@", f2, f1, f2]];
        gDelayPathPrefix = @"/api/settings";
        gDelayDone = NO;
        [settings reloadData];
        WaitUntil(5.0, ^BOOL { return gDelayDone; });
        Pump(0.15);
        FlushDelayed();
        Pump(0.15);

        Ck([PopupValue(filtNxPop) isEqualToString:f2], @"乱序(filters先): filterNx 回读真实名", PopupValue(filtNxPop));
        Ck([PopupValue(sdmO1Pop) isEqualToString:f1], @"乱序(filters先): sdmfilt 回读真实名", PopupValue(sdmO1Pop));
        Ck([PopupValue(sdmONxPop) isEqualToString:f2], @"乱序(filters先): sdmfiltnx 回读真实名", PopupValue(sdmONxPop));

        // ---- 6. 主题重建：切到 light，当前 sdm 页签及后续切换的 pcm / adv 页签均回读真实 kv ----
        [RLPTheme setThemeName:@"light"];
        Pump(0.2);
        WaitUntil(6.0, ^BOOL {
            NSTextField *mc = (NSTextField *)FindId(v, @"sp_modcut");
            NSPopUpButton *so1 = (NSPopUpButton *)FindId(v, @"sp_sdmo1");
            return mc && [mc.stringValue isEqualToString:@"125"] && so1 && so1.numberOfItems > 2;
        });
        NSPopUpButton *sdmO1AfterTheme = (NSPopUpButton *)FindId(v, @"sp_sdmo1");
        NSTextField *modCutAfterTheme = (NSTextField *)FindId(v, @"sp_modcut");
        Ck([PopupValue(sdmO1AfterTheme) isEqualToString:f1],
           @"主题重建(sdm): sdmfilt 仍回读真实名", PopupValue(sdmO1AfterTheme));
        Ck([modCutAfterTheme.stringValue isEqualToString:@"125"],
           @"主题重建(sdm): modcut 仍回读 125", modCutAfterTheme.stringValue);

        [settings selectPane:@"adv"];
        WaitUntil(6.0, ^BOOL {
            NSTextField *st = (NSTextField *)FindId(v, @"sp_scanthreads");
            NSSwitch *sh = (NSSwitch *)FindId(v, @"sp_shuf");
            return st && [st.stringValue isEqualToString:@"3"] && sh && sh.state == NSControlStateValueOn;
        });
        NSTextField *scanAfterTheme = (NSTextField *)FindId(v, @"sp_scanthreads");
        NSSwitch *shufAfterTheme = (NSSwitch *)FindId(v, @"sp_shuf");
        NSStackView *rootsAfterTheme = (NSStackView *)FindId(v, @"sp_roots");
        WaitUntil(3.0, ^BOOL { return rootsAfterTheme && rootsAfterTheme.arrangedSubviews.count > 0; });
        BOOL foundRootAfterTheme = NO;
        for (NSView *sub in rootsAfterTheme.arrangedSubviews) {
            if ([sub isKindOfClass:[NSTextField class]]) {
                NSString *txt = ((NSTextField *)sub).stringValue ?: @"";
                if ([txt isEqualToString:musicDir] || [txt isEqualToString:resolvedMusicDir])
                    foundRootAfterTheme = YES;
            }
        }
        Ck([scanAfterTheme.stringValue isEqualToString:@"3"],
           @"主题重建(adv): scanthreads 仍回读 3", scanAfterTheme.stringValue);
        Ck(shufAfterTheme.state == NSControlStateValueOn,
           @"主题重建(adv): shufSwitch 仍回读 On",
           [NSString stringWithFormat:@"state=%ld", (long)shufAfterTheme.state]);
        Ck(foundRootAfterTheme, @"主题重建(adv): sp_roots 仍回读真实音乐目录",
           [NSString stringWithFormat:@"count=%lu", (unsigned long)rootsAfterTheme.arrangedSubviews.count]);

        // ---- 7. 目标1/3/5：纯数字 dsd+dsdnative=0、channels=0 原样回显、680/820/1180 几何防重叠 ----
        [settings selectPane:@"out"];
        Pump(0.1);
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"channels=0&dsd=dop128&dsdnative=0"];
        [settings reloadData];
        WaitUntil(4.0, ^BOOL {
            NSPopUpButton *chPop = (NSPopUpButton *)FindId(v, @"sp_ch");
            return chPop && chPop.indexOfSelectedItem == 0;
        });
        NSPopUpButton *chPop = (NSPopUpButton *)FindId(v, @"sp_ch");
        Ck(chPop && chPop.indexOfSelectedItem == 0, @"channels=0 原样回显第 0 项（跟随源）",
           [NSString stringWithFormat:@"idx=%ld", (long)(chPop ? chPop.indexOfSelectedItem : -1)]);

        [settings selectPane:@"sdm"];
        Pump(0.1);
        NSPopUpButton *dsdRatePop = (NSPopUpButton *)FindId(v, @"sp_dsdrate");
        NSPopUpButton *dsdPkPop = (NSPopUpButton *)FindId(v, @"sp_dsdpk");
        Ck(dsdRatePop && [dsdRatePop.titleOfSelectedItem isEqualToString:@"128"],
           @"legacy dop128 回显比特率 128", dsdRatePop.titleOfSelectedItem ?: @"nil");
        Ck(dsdPkPop && dsdPkPop.numberOfItems == 1 && [dsdPkPop.titleOfSelectedItem isEqualToString:@"dop"],
           @"macOS 只提供 DoP 不提供 Native", dsdPkPop.titleOfSelectedItem ?: @"nil");

        // 改选 256，校验写回核心为纯数字 dsd=256 且 dsdnative=0
        if (dsdRatePop) {
            [dsdRatePop selectItemWithTitle:@"256"];
            [dsdRatePop sendAction:dsdRatePop.action to:dsdRatePop.target];
            WaitUntil(3.0, ^BOOL {
                NSDictionary *s = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
                NSDictionary *skv = [s[@"kv"] isKindOfClass:[NSDictionary class]] ? s[@"kv"] : @{};
                return [[NSString stringWithFormat:@"%@", skv[@"dsd"] ?: @""] isEqualToString:@"256"] &&
                       [[NSString stringWithFormat:@"%@", skv[@"dsdnative"] ?: @""] isEqualToString:@"0"];
            });
            NSDictionary *sNow = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil];
            NSDictionary *skvNow = [sNow[@"kv"] isKindOfClass:[NSDictionary class]] ? sNow[@"kv"] : @{};
            Ck([[NSString stringWithFormat:@"%@", skvNow[@"dsd"] ?: @""] isEqualToString:@"256"] &&
               [[NSString stringWithFormat:@"%@", skvNow[@"dsdnative"] ?: @""] isEqualToString:@"0"],
               @"设置页 DSD 保存纯数字 dsd=256 与 dsdnative=0",
               [NSString stringWithFormat:@"dsd=%@ dsdnative=%@", skvNow[@"dsd"], skvNow[@"dsdnative"]]);
        }

        // 680/820/1180 几何验证：设置页窗口缩放不崩溃、核心控件不超出容器
        for (NSNumber *wn in @[@680, @820, @1180]) {
            v.frame = NSMakeRect(0, 0, wn.doubleValue, 760);
            [v layoutSubtreeIfNeeded];
            NSView *tabsV = FindId(v, @"settings.tabs");
            Ck(tabsV && NSWidth(tabsV.frame) <= wn.doubleValue,
               [NSString stringWithFormat:@"settings_%d 页签栏不超出容器", wn.intValue],
               [NSString stringWithFormat:@"tabsW=%.1f", tabsV ? NSWidth(tabsV.frame) : -1.0]);
        }

        [settings selectPane:@"out"];
        Pump(0.1);
        settings.savedUpnpDev = @"uuid:second";
        [settings applyUpnpDevicesPayload:@{@"devices": @[
            @{@"id": @"uuid:first", @"friendlyName": @"Same room", @"kind": @"upnp"},
            @{@"id": @"uuid:second", @"friendlyName": @"Same room", @"kind": @"upnp"},
            @{@"friendlyName": @"No stable ID"}
        ]}];
        NSPopUpButton *renderer = [settings valueForKey:@"upnpPop"];
        Ck(renderer.numberOfItems == 2 && [renderer.selectedItem.representedObject isEqualToString:@"uuid:second"],
           @"同名渲染器按ID回选，缺失ID条目不可选", renderer.itemTitles.description);
        [renderer selectItemAtIndex:0];
        [renderer sendAction:renderer.action to:renderer.target];
        WaitUntil(3.0, ^BOOL {
            return [[core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"][@"upnpdev"] isEqualToString:@"uuid:first"];
        });
        Ck([[core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"][@"upnpdev"] isEqualToString:@"uuid:first"],
           @"投放目标保存真实ID而非显示名称", @"");

        // ---- 8. 声道音量微调 (trim) 回读 & 切换声道数保留 ----
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"channels=6&trim=-3.5,1.5,0,2.0,-1.5,0.5,0,0"];
        [settings reloadData];
        WaitUntil(4.0, ^BOOL {
            NSSlider *s0 = (NSSlider *)FindId(v, @"sp_trim0");
            return s0 && fabs(s0.doubleValue - (-3.5)) < 0.05;
        });
        NSSlider *trim0 = (NSSlider *)FindId(v, @"sp_trim0");
        NSSlider *trim1 = (NSSlider *)FindId(v, @"sp_trim1");
        NSSlider *trim3 = (NSSlider *)FindId(v, @"sp_trim3");
        NSSlider *trim4 = (NSSlider *)FindId(v, @"sp_trim4");
        NSTextField *trim0Val = (NSTextField *)FindId(v, @"sp_trim0.val");
        Ck(trim0 && fabs(trim0.doubleValue - (-3.5)) < 0.05 &&
           trim1 && fabs(trim1.doubleValue - 1.5) < 0.05 &&
           trim3 && fabs(trim3.doubleValue - 2.0) < 0.05 &&
           trim4 && fabs(trim4.doubleValue - (-1.5)) < 0.05 &&
           trim0Val && [trim0Val.stringValue containsString:@"-3.5"],
           @"channels=6 时 trim 滑杆与 dB 标签正确回读 kv.trim",
           [NSString stringWithFormat:@"t0=%.2f val=%@", trim0 ? trim0.doubleValue : 99.0, trim0Val.stringValue ?: @"nil"]);

        NSPopUpButton *chPop2 = (NSPopUpButton *)FindId(v, @"sp_ch");
        if (chPop2 && chPop2.numberOfItems >= 4) {
            [chPop2 selectItemAtIndex:3]; // 8 声道
            [chPop2 sendAction:chPop2.action to:chPop2.target];
            Pump(0.15);
            NSSlider *trim0AfterCh = (NSSlider *)FindId(v, @"sp_trim0");
            Ck(trim0AfterCh && fabs(trim0AfterCh.doubleValue - (-3.5)) < 0.05,
               @"切换输出声道数后已加载的 trim 值不丢失",
               [NSString stringWithFormat:@"t0=%.2f", trim0AfterCh ? trim0AfterCh.doubleValue : 99.0]);
        }

        // ---- 9. onBitPerfectFix: 提交后同步刷新设置页自身控件 ----
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"rate=192000&hogexcl=0&bits=24"];
        [settings reloadData];
        WaitUntil(4.0, ^BOOL {
            NSSwitch *h = (NSSwitch *)FindId(v, @"sp_hogexcl");
            return h && h.state == NSControlStateValueOff;
        });
        // 直通按钮在真机上会先弹确认（模态会卡死无界面测试）；这里显式关掉确认策略。
        [(id)[settings class] setRlp_confirmsBitPerfectFix:NO];
        [(id)settings performSelector:@selector(onBitPerfectFix:) withObject:nil];
        WaitUntil(4.0, ^BOOL {
            NSSwitch *h = (NSSwitch *)FindId(v, @"sp_hogexcl");
            NSPopUpButton *bPop = (NSPopUpButton *)FindId(v, @"sp_bits");
            return h && h.state == NSControlStateValueOn &&
                   bPop && [bPop.selectedItem.representedObject isEqualToString:@"-1"];
        });
        NSSwitch *hogAfterBP = (NSSwitch *)FindId(v, @"sp_hogexcl");
        NSPopUpButton *bitsAfterBP = (NSPopUpButton *)FindId(v, @"sp_bits");
        NSPopUpButton *rPopAfterBP = (NSPopUpButton *)FindId(v, @"sp_rate");
        Ck(rPopAfterBP && [rPopAfterBP.selectedItem.representedObject isEqualToString:@"src"] &&
           hogAfterBP && hogAfterBP.state == NSControlStateValueOn &&
           bitsAfterBP && [bitsAfterBP.selectedItem.representedObject isEqualToString:@"-1"],
           @"点击 bit-perfect 直通后设置页自身控件同步更新",
           [NSString stringWithFormat:@"rPop=%p rate=%@ hog=%ld bits=%@",
            rPopAfterBP, rPopAfterBP.selectedItem.representedObject,
            (long)(hogAfterBP ? hogAfterBP.state : -1),
            bitsAfterBP.selectedItem.representedObject]);
        // 恢复默认确认策略，避免静态状态残留影响同进程后续用例。
        [(id)[settings class] setRlp_confirmsBitPerfectFix:YES];

        // ---- 10. 缺口2 onRepeat: 走 POST /api/playmode?mode=N，并在失败时提示且回读恢复 ----
        [settings selectPane:@"adv"];
        [core jsonWithMethod:@"POST" path:@"/api/playmode?mode=0" body:@""];
        [settings reloadData];
        WaitUntil(4.0, ^BOOL {
            NSPopUpButton *rp = (NSPopUpButton *)FindId(v, @"sp_rep");
            return rp && rp.indexOfSelectedItem == 2; // 0(顺序) -> index 2(关闭循环)
        });
        NSPopUpButton *repPop2 = (NSPopUpButton *)FindId(v, @"sp_rep");
        if (repPop2) {
            // 选 index 1（单曲循环 mode=2）
            [repPop2 selectItemAtIndex:1];
            [repPop2 sendAction:repPop2.action to:repPop2.target];
            WaitUntil(3.0, ^BOOL {
                NSDictionary *pm = [core jsonWithMethod:@"GET" path:@"/api/playmode" body:nil];
                return [pm[@"mode"] integerValue] == 2;
            });
            NSDictionary *pmAfter = [core jsonWithMethod:@"GET" path:@"/api/playmode" body:nil];
            Ck([pmAfter[@"mode"] integerValue] == 2,
               @"缺口2 onRepeat 选单曲循环(index 1) 真实写入后端 mode=2（不走 /api/repeat 归零）",
               [pmAfter description]);

            // 失败分支：拦截 POST /api/playmode 返回 ok=NO -> 状态行报错且控件回读恢复为 mode=2 (index 1)
            Method pmMethod = class_getInstanceMethod([RLPCoreClient class], @selector(postJSON:body:completion:));
            IMP origPost = method_getImplementation(pmMethod);
            __block BOOL failNextPlaymode = YES;
            IMP failPostImp = imp_implementationWithBlock(^(id _self, NSString *path, NSString *body, RLPJsonDone completion) {
                if (failNextPlaymode && [path hasPrefix:@"/api/playmode"]) {
                    failNextPlaymode = NO;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(@{ @"ok": @NO, @"error": @"mock playmode fail" });
                    });
                    return;
                }
                ((void (*)(id, SEL, NSString *, NSString *, RLPJsonDone))origPost)(_self, @selector(postJSON:body:completion:), path, body, completion);
            });
            method_setImplementation(pmMethod, failPostImp);

            [repPop2 selectItemAtIndex:0]; // 试图切到列表循环
            [repPop2 sendAction:repPop2.action to:repPop2.target];
            WaitUntil(3.0, ^BOOL {
                NSTextField *sl = [settings valueForKey:@"statusLine"];
                return sl && [sl.stringValue containsString:@"mock playmode fail"] && repPop2.indexOfSelectedItem == 1;
            });
            method_setImplementation(pmMethod, origPost);
            NSTextField *sl = [settings valueForKey:@"statusLine"];
            Ck(sl && [sl.stringValue containsString:@"mock playmode fail"] && repPop2.indexOfSelectedItem == 1,
               @"缺口2 onRepeat 失败时提示错误且回读恢复为真实后端 mode=2 (index 1)",
               [NSString stringWithFormat:@"status=%@ idx=%ld", sl ? sl.stringValue : @"nil", (long)repPop2.indexOfSelectedItem]);
        }

        // ---- 11. 缺口3：updChannelPopup 回读 / metaLlmSwitch 校验 metasummary / loadLlmConfig 同步 llmProviderPopup ----
        {
            // 11a: kv[@"channel"] = "cn" -> updChannelPopup=cn (在 diag 页签)
            Method getM = class_getInstanceMethod([RLPCoreClient class], @selector(getJSON:completion:));
            IMP origGet = method_getImplementation(getM);
            __block NSString *mockLlmBase = @"https://api.openai.com/v1";
            __block BOOL injectChannelCn = YES;
            IMP mockGetImp = imp_implementationWithBlock(^(id _self, NSString *path, RLPJsonDone completion) {
                if (injectChannelCn && [path isEqualToString:@"/api/settings"]) {
                    ((void (*)(id, SEL, NSString *, RLPJsonDone))origGet)(_self, @selector(getJSON:completion:), path, ^(NSDictionary * _Nullable json) {
                        if (json && [json[@"kv"] isKindOfClass:[NSDictionary class]]) {
                            NSMutableDictionary *copy = [json mutableCopy];
                            NSMutableDictionary *kv = [json[@"kv"] mutableCopy];
                            kv[@"channel"] = @"cn";
                            copy[@"kv"] = kv;
                            if (completion) completion(copy);
                            return;
                        }
                        if (completion) completion(json);
                    });
                    return;
                }
                if ([path isEqualToString:@"/api/llm"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(@{
                            @"ok": @YES,
                            @"baseUrl": mockLlmBase,
                            @"model": @"gpt-4o",
                            @"configured": @YES,
                            @"masked": @"sk-***"
                        });
                    });
                    return;
                }
                if ([path hasPrefix:@"/api/llm/models"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(@{ @"ok": @YES, @"models": @[] });
                    });
                    return;
                }
                ((void (*)(id, SEL, NSString *, RLPJsonDone))origGet)(_self, @selector(getJSON:completion:), path, completion);
            });
            method_setImplementation(getM, mockGetImp);

            [settings selectPane:@"diag"];
            [settings reloadData];
            WaitUntil(1.5, ^BOOL {
                NSPopUpButton *cp = (NSPopUpButton *)FindId(v, @"sp_updchannel");
                return cp && [PopupValue(cp) isEqualToString:@"cn"];
            });
            NSPopUpButton *chPop = (NSPopUpButton *)FindId(v, @"sp_updchannel");
            Ck(chPop && [PopupValue(chPop) isEqualToString:@"cn"],
               @"缺口3 reloadData 从 kv[@\"channel\"] 回读 updChannelPopup=cn",
               [NSString stringWithFormat:@"got=%@", chPop ? PopupValue(chPop) : @"nil"]);
            injectChannelCn = NO;

            // 11b: metallm=1, metasummary=0 -> metaLlmSwitch=Off; metallm=1, metasummary=1 -> On (在 meta 页签)
            [settings selectPane:@"meta"];
            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"metallm=1&metasummary=0"];
            [settings reloadData];
            NSSwitch *llmSw = (NSSwitch *)FindId(v, @"sp_metallm");
            Pump(0.2);
            Ck(llmSw && llmSw.state == NSControlStateValueOff,
               @"缺口3 metaLlmSwitch 在 metallm=1 且 metasummary=0 时为 Off",
               [NSString stringWithFormat:@"state=%ld", (long)(llmSw ? llmSw.state : -1)]);

            [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"metallm=1&metasummary=1"];
            [settings reloadData];
            WaitUntil(1.5, ^BOOL {
                return llmSw && llmSw.state == NSControlStateValueOn;
            });
            Ck(llmSw && llmSw.state == NSControlStateValueOn,
               @"缺口3 metaLlmSwitch 在 metallm=1 且 metasummary=1 时为 On",
               [NSString stringWithFormat:@"state=%ld", (long)(llmSw ? llmSw.state : -1)]);

            // 11c: loadLlmConfig 回填 baseUrl 后同步 llmProviderPopup 选中项
            NSPopUpButton *provPop = (NSPopUpButton *)FindId(v, @"llm.provider");
            [provPop selectItemAtIndex:0];
            [settings performSelector:@selector(loadLlmConfig)];
            WaitUntil(1.5, ^BOOL {
                return provPop && provPop.indexOfSelectedItem == 1;
            });
            Ck(provPop && provPop.indexOfSelectedItem == 1,
               @"缺口3 loadLlmConfig 回填 OpenAI baseUrl 后同步 llmProviderPopup=1(OpenAI)",
               [NSString stringWithFormat:@"idx=%ld", (long)(provPop ? provPop.indexOfSelectedItem : -1)]);

            mockLlmBase = @"https://custom-gateway.example.com/v1";
            [settings performSelector:@selector(loadLlmConfig)];
            WaitUntil(1.5, ^BOOL {
                return provPop && provPop.indexOfSelectedItem == 5;
            });
            method_setImplementation(getM, origGet);
            Ck(provPop && provPop.indexOfSelectedItem == 5,
               @"缺口3 loadLlmConfig 回填自定义 baseUrl 后同步 llmProviderPopup=5(自定义)",
               [NSString stringWithFormat:@"idx=%ld", (long)(provPop ? provPop.indexOfSelectedItem : -1)]);
        }

        // 12. 投放面板（RLPCastView）设置回显 + loadUpnpDevices 同步 + 状态框按内容显隐
        {
            [core jsonWithMethod:@"POST" path:@"/api/settings"
                body:@"cast_upsample=1&cast_upsample_ceiling=384000&cast_upsample_force=1&upnpdev=upnp://192.168.1.99/desc.xml"];
            [settings selectPane:@"stream"];
            Pump(0.2);
            NSView *castView = [settings valueForKey:@"castView"];
            if ([castView respondsToSelector:NSSelectorFromString(@"reload")]) {
                [castView performSelector:NSSelectorFromString(@"reload")];
            }
            NSSwitch *upSw = (NSSwitch *)FindId(v, @"cast_up");
            NSPopUpButton *ceilPop = (NSPopUpButton *)FindId(v, @"cast_ceil");
            NSSwitch *forceSw = (NSSwitch *)FindId(v, @"cast_force");
            WaitUntil(1.5, ^BOOL {
                return upSw && upSw.state == NSControlStateValueOn &&
                       ceilPop && [ceilPop.titleOfSelectedItem isEqualToString:@"384000"] &&
                       forceSw && forceSw.state == NSControlStateValueOn;
            });
            Ck(upSw && upSw.state == NSControlStateValueOn,
               @"12a RLPCastView reload 回显 cast_upsample=1",
               [NSString stringWithFormat:@"state=%ld", (long)(upSw ? upSw.state : -1)]);
            Ck(ceilPop && [ceilPop.titleOfSelectedItem isEqualToString:@"384000"],
               @"12b RLPCastView reload 回显 cast_upsample_ceiling=384000",
               ceilPop ? ceilPop.titleOfSelectedItem : @"nil");
            Ck(forceSw && forceSw.state == NSControlStateValueOn,
               @"12c RLPCastView reload 回显 cast_upsample_force=1",
               [NSString stringWithFormat:@"state=%ld", (long)(forceSw ? forceSw.state : -1)]);

            // 12d: loadUpnpDevices 填充 sp_cast_dev 并保留/同步 saved upnpdev
            Method getM2 = class_getInstanceMethod([RLPCoreClient class], @selector(getJSON:completion:));
            IMP origGet2 = method_getImplementation(getM2);
            __block NSDictionary *mockCastState = @{
                @"ok": @YES, @"running": @NO, @"prep": @0, @"warn": @"", @"error": @""
            };
            IMP mockGetImp2 = imp_implementationWithBlock(^(id _self, NSString *path, RLPJsonDone completion) {
                if ([path isEqualToString:@"/api/upnp"] || [path hasPrefix:@"/api/cast/devices"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(@{
                            @"ok": @YES,
                            @"devices": @[
                                @{ @"id": @"upnp://192.168.1.99/desc.xml", @"name": @"LivingRoom", @"kind": @"upnp" },
                                @{ @"id": @"upnp://192.168.1.100/desc.xml", @"name": @"Study", @"kind": @"upnp" }
                            ]
                        });
                    });
                    return;
                }
                if ([path isEqualToString:@"/api/cast/state"]) {
                    NSDictionary *st = mockCastState;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion(st);
                    });
                    return;
                }
                ((void (*)(id, SEL, NSString *, RLPJsonDone))origGet2)(_self, @selector(getJSON:completion:), path, completion);
            });
            method_setImplementation(getM2, mockGetImp2);

            if ([castView respondsToSelector:NSSelectorFromString(@"loadUpnpDevices")]) {
                [castView performSelector:NSSelectorFromString(@"loadUpnpDevices")];
            }
            NSPopUpButton *castDevPop = (NSPopUpButton *)FindId(v, @"sp_cast_dev");
            WaitUntil(1.5, ^BOOL {
                return castDevPop && castDevPop.numberOfItems >= 2 &&
                       [castDevPop.titleOfSelectedItem containsString:@"LivingRoom"];
            });
            Ck(castDevPop && castDevPop.numberOfItems >= 2 &&
               [castDevPop.titleOfSelectedItem containsString:@"LivingRoom"],
               @"12d loadUpnpDevices 填充 sp_cast_dev 并按 upnpdev 选中 LivingRoom",
               castDevPop ? castDevPop.titleOfSelectedItem : @"nil");

            // 12e: 状态框空值隐藏，有值显示
            NSView *prepBox = FindId(v, @"sp_cast_stat_prep_box");
            NSView *warnBox = FindId(v, @"sp_cast_stat_warn_box");
            NSView *errBox = FindId(v, @"sp_cast_stat_err_box");
            if ([castView respondsToSelector:NSSelectorFromString(@"refreshState")]) {
                [castView performSelector:NSSelectorFromString(@"refreshState")];
            }
            WaitUntil(1.0, ^BOOL {
                return prepBox && warnBox && errBox && prepBox.hidden && warnBox.hidden && errBox.hidden;
            });
            Ck(prepBox && warnBox && errBox && prepBox.hidden && warnBox.hidden && errBox.hidden,
               @"12e prep=0/warn='' /error='' 时三个状态框均隐藏",
               [NSString stringWithFormat:@"prep=%d warn=%d err=%d",
                prepBox ? prepBox.hidden : -1, warnBox ? warnBox.hidden : -1, errBox ? errBox.hidden : -1]);

            mockCastState = @{
                @"ok": @YES, @"running": @YES, @"prep": @0.45,
                @"warn": @"Sample rate capped", @"error": @"Connection refused"
            };
            if ([castView respondsToSelector:NSSelectorFromString(@"refreshState")]) {
                [castView performSelector:NSSelectorFromString(@"refreshState")];
            }
            WaitUntil(1.0, ^BOOL {
                return prepBox && warnBox && errBox && !prepBox.hidden && !warnBox.hidden && !errBox.hidden;
            });
            method_setImplementation(getM2, origGet2);
            Ck(prepBox && warnBox && errBox && !prepBox.hidden && !warnBox.hidden && !errBox.hidden,
               @"12f prep>0/warn 非空/error 非空时状态框显示",
               [NSString stringWithFormat:@"prep=%d warn=%d err=%d",
                prepBox ? prepBox.hidden : -1, warnBox ? warnBox.hidden : -1, errBox ? errBox.hidden : -1]);
        }

        // ---- A2：设置读回在途期间发生保存，回包不得整包作废 ----
        // 现状（单计数器 settingsSeq）：GET 取号 N，之后任何 POST 取号 N+1 ⟹ GET 回包因
        // 「seq 已过期」被整包丢弃 ⟹ 开关/文本框停在上一次的值（切主题重建后看起来像"设置被重置"）。
        {
            [settings selectPane:@"out"];
            WaitUntil(4.0, ^BOOL { return FindId(v, @"sp_buffer") != nil; });
            NSTextField *bf = (NSTextField *)FindId(v, @"sp_buffer");
            Ck(bf != nil, @"A2-前置：out 页有 buffer 输入框", @"缺失");
            if (bf) {
                // 后端真值改成 4096（页面显示 120），让「GET 是否被应用」可观测
                [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"buffer=4096"];
                [settings reloadData];
                WaitUntil(4.0, ^BOOL { return [bf.stringValue isEqualToString:@"4096"]; });
                Ck([bf.stringValue isEqualToString:@"4096"], @"A2-前置：buffer 已回读 4096", bf.stringValue);

                // 后端真值改回 120；扣住这次 GET，并在在途期间发一次保存（推进设置页序号）
                [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"buffer=120"];
                InstallOrderHook();
                gDelayPathPrefix = @"/api/settings";
                gDelayedBlock = nil;
                gDelayedPayload = nil;
                gDelayDone = NO;
                [settings reloadData];
                Pump(0.2);
                Ck(gDelayDone, @"A2-前置：/api/settings GET 被扣住（读回在途）", @"");
                std::printf("  (diag) before POST held=%d block=%p payload=%p\n", (int)gDelayDone, (void *)gDelayedBlock, (__bridge void *)gDelayedPayload);
                [settings postKey:@"hogexcl" value:@"1" completion:nil];
                Pump(0.3);
                std::printf("  (diag) after POST held=%d block=%p payload=%p\n", (int)gDelayDone, (void *)gDelayedBlock, (__bridge void *)gDelayedPayload);

                std::printf("  (diag) flushing block=%p payload=%@\n", (void *)gDelayedBlock, (gDelayedPayload[@"kv"][@"buffer"] ?: @"(nil)"));
                FlushDelayed();   // 放行 GET 回包（kv.buffer = 120）
                Pump(0.3);
                Ck([bf.stringValue isEqualToString:@"120"],
                   @"A2 读回在途期间的保存不得让整包回读作废（buffer 仍应回读 120）",
                   [NSString stringWithFormat:@"buffer=%@", bf.stringValue]);
                gDelayPathPrefix = nil;
            }
        }

        [RLPTheme setThemeName:@"dark"];
        [core shutdown];
        [fm removeItemAtPath:rootDir error:nil];

        std::printf("\n结果: %d 通过, %d 失败\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
