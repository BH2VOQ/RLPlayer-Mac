// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_listening_async_contract.mm — QuickStart 异步状态与失败回滚契约判据
//
// 覆盖：
//   A1 onDeviceChanged 在 POST 失败前不应污染已确认 localDevice
//   A2 onDeviceChanged POST 失败后，devicePopup 下拉与摘要应回滚真实设备并提示 backend error
//   B1 postSettings 连续快速修改时，旧回包（无论成功或失败）不能覆盖新状态、不能触发 reloadSettings 或误报成功/失败
//   C1 输出选择（onPickBackend / onApplyUpnpOutput）POST 失败时不应装作已应用，且提示 backend error
//
// 纪律：纯 AppKit + 可控异步 mock（swizzle RLPCoreClient，不启真正 core、不碰 8899、不做真实设备发现、不显示窗口/浮层）。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "RLPCoreClient.h"
#import "RLPListeningRoom.h"
#import "RLPQuickStartViewController.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <cstdio>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) {
        ++gPass;
        std::printf("  [PASS] %s\n", what);
    } else {
        ++gFail;
        std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: "");
    }
}

static NSView *FindById(NSView *root, NSString *ident) {
    if (!root) return nil;
    if ([root.identifier isEqualToString:ident]) return root;
    for (NSView *s in root.subviews) {
        NSView *r = FindById(s, ident);
        if (r) return r;
    }
    return nil;
}

static NSString *LatestToastText(NSWindow *win) {
    NSView *toast = FindById(win.contentView, @"rlp.toast");
    if (!toast) return @"";
    for (NSView *sub in toast.subviews) {
        if ([sub isKindOfClass:[NSTextField class]]) {
            return ((NSTextField *)sub).stringValue ?: @"";
        }
    }
    return @"";
}

static void ClearToasts(NSWindow *win) {
    for (NSView *sub in [win.contentView.subviews copy]) {
        if ([sub.identifier isEqualToString:@"rlp.toast"]) {
            [sub removeFromSuperview];
        }
    }
}

@interface RLPQuickStartViewController (AsyncContractTest)
@property (nonatomic, strong) NSPopUpButton *devicePopup;
@property (nonatomic, strong) NSTextField *outputValue;
@property (nonatomic, strong) NSTextField *presetNotes;
@property (nonatomic, copy) NSArray<NSDictionary *> *devices;
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy, nullable) NSString *localDevice;
@property (nonatomic, strong) NSPopover *popover;
- (void)onDeviceChanged:(NSPopUpButton *)sender;
- (void)postSettings:(NSDictionary<NSString *, NSString *> *)kv;
- (void)reloadSettings;
- (void)reloadDevices;
- (void)syncDeviceSelection;
- (void)syncOutputSummary;
- (void)onOpenOutput:(id)sender;
- (void)onPickBackend:(NSButton *)sender;
- (void)onApplyUpnpOutput:(id)sender;
- (void)applyCastDevicesPayload:(NSDictionary * _Nullable)json;
@end

// 测试子类：禁止真实网络/蓝牙设备发现，浮层仅构造不 show
@interface RLPOfflineAsyncQuickStartController : RLPQuickStartViewController
@end
@implementation RLPOfflineAsyncQuickStartController
- (void)discoverCastDevicesForce:(BOOL)force { (void)force; }
- (void)showPopoverFrom:(NSView *)anchor withCard:(NSView *)card width:(CGFloat)width minH:(CGFloat)height {
    (void)anchor;
    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = RLPCardController(card, width, height);
    [self.popover.contentViewController.view layoutSubtreeIfNeeded];
}
@end

// ---- 可控异步 Mock RLPCoreClient ----
@interface RLPMockRequest : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy, nullable) NSString *body;
@property (nonatomic, copy, nullable) RLPJSONCompletion completion;
@end
@implementation RLPMockRequest
@end

static NSMutableArray<RLPMockRequest *> *gPendingGets = nil;
static NSMutableArray<RLPMockRequest *> *gPendingPosts = nil;

static BOOL MockStarted(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return YES;
}

static void MockGetJSON(id self, SEL _cmd, NSString *path, RLPJSONCompletion completion) {
    (void)self; (void)_cmd;
    RLPMockRequest *req = [[RLPMockRequest alloc] init];
    req.method = @"GET";
    req.path = path ?: @"";
    req.completion = completion;
    [gPendingGets addObject:req];
}

static void MockPostJSON(id self, SEL _cmd, NSString *path, NSString * _Nullable body, RLPJSONCompletion completion) {
    (void)self; (void)_cmd;
    RLPMockRequest *req = [[RLPMockRequest alloc] init];
    req.method = @"POST";
    req.path = path ?: @"";
    req.body = body;
    req.completion = completion;
    [gPendingPosts addObject:req];
}

static void InstallMockCoreClient(void) {
    gPendingGets = [NSMutableArray array];
    gPendingPosts = [NSMutableArray array];
    Class cls = [RLPCoreClient class];
    method_setImplementation(class_getInstanceMethod(cls, @selector(started)), (IMP)MockStarted);
    method_setImplementation(class_getInstanceMethod(cls, @selector(getJSON:completion:)), (IMP)MockGetJSON);
    method_setImplementation(class_getInstanceMethod(cls, @selector(postJSON:body:completion:)), (IMP)MockPostJSON);
}

static RLPMockRequest * _Nullable PopFirstRequest(NSMutableArray<RLPMockRequest *> *queue, NSString *pathPrefix) {
    for (NSUInteger i = 0; i < queue.count; ++i) {
        if ([queue[i].path hasPrefix:pathPrefix]) {
            RLPMockRequest *req = queue[i];
            [queue removeObjectAtIndex:i];
            return req;
        }
    }
    return nil;
}

static NSUInteger CountRequests(NSMutableArray<RLPMockRequest *> *queue, NSString *pathPrefix) {
    NSUInteger n = 0;
    for (RLPMockRequest *req in queue) {
        if ([req.path hasPrefix:pathPrefix]) ++n;
    }
    return n;
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_listening_async_contract（QuickStart 真实对象 + 可控异步 mock）===\n");

        InstallMockCoreClient();

        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 760)
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        win.releasedWhenClosed = NO;
        win.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1100, 760)];

        RLPOfflineAsyncQuickStartController *vc = [[RLPOfflineAsyncQuickStartController alloc] init];
        vc.view.frame = win.contentView.bounds;
        [win.contentView addSubview:vc.view];

        __block NSInteger settingsChangedNotifCount = 0;
        id notifToken = [[NSNotificationCenter defaultCenter]
            addObserverForName:RLPSettingsChangedNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            (void)note;
            ++settingsChangedNotifCount;
        }];

        // 初始化：通过真实 reloadDevices / reloadSettings 回调建立已确认基线
        [vc reloadDevices];
        RLPMockRequest *devReq = PopFirstRequest(gPendingGets, @"/api/devices");
        if (devReq && devReq.completion) {
            devReq.completion(@{
                @"ok": @YES,
                @"devices": @[
                    @{@"id": @"dev-a", @"name": @"DAC A", @"default": @YES},
                    @{@"id": @"dev-b", @"name": @"DAC B", @"default": @NO},
                ]
            });
        }
        [vc reloadSettings];
        RLPMockRequest *setReq = PopFirstRequest(gPendingGets, @"/api/settings");
        if (setReq && setReq.completion) {
            setReq.completion(@{
                @"ok": @YES,
                @"kv": @{
                    @"backend": @"coreaudio",
                    @"device": @"dev-a",
                    @"hogexcl": @"1",
                    @"filter": @"poly-sinc-short-lp",
                }
            });
        }
        [gPendingGets removeAllObjects];
        [gPendingPosts removeAllObjects];
        ClearToasts(win);
        settingsChangedNotifCount = 0;

        // ---------- A. onDeviceChanged 在 POST 失败前不污染 localDevice，失败后回滚并提示 backend error ----------
        [vc.devicePopup selectItemAtIndex:2]; // 选择 DAC B (dev-b)
        [vc onDeviceChanged:vc.devicePopup];

        CK([vc.localDevice isEqualToString:@"dev-a"],
           "A1 onDeviceChanged 在 POST 完成前不提前污染已确认 localDevice",
           vc.localDevice ?: @"nil");

        RLPMockRequest *devPost = PopFirstRequest(gPendingPosts, @"/api/settings");
        CK(devPost != nil && [devPost.body containsString:@"device=dev-b"],
           "A1b onDeviceChanged 发起 device=dev-b 的 POST",
           devPost.body ?: @"nil");

        if (devPost && devPost.completion) {
            devPost.completion(@{@"ok": @NO, @"error": @"Device busy: dev-b"});
        }
        NSString *toastAfterDevFail = LatestToastText(win);
        CK([vc.localDevice isEqualToString:@"dev-a"] && vc.devicePopup.indexOfSelectedItem == 1,
           "A2a POST 失败后 localDevice 保持 dev-a 且 devicePopup 下拉回滚至 DAC A (index 1)",
           [NSString stringWithFormat:@"localDevice=%@ selectedIdx=%ld title=%@",
            vc.localDevice ?: @"nil", (long)vc.devicePopup.indexOfSelectedItem, vc.devicePopup.titleOfSelectedItem ?: @"nil"]);
        CK([toastAfterDevFail containsString:@"Device busy: dev-b"] ||
           [vc.presetNotes.stringValue containsString:@"Device busy: dev-b"],
           "A2b POST 失败后提示后端具体 error（Device busy: dev-b）",
           [NSString stringWithFormat:@"toast=%@ notes=%@", toastAfterDevFail, vc.presetNotes.stringValue ?: @"nil"]);
        CK(settingsChangedNotifCount == 0,
           "A2c POST 失败后不发送 RLPSettingsChangedNotification",
           [NSString stringWithFormat:@"count=%ld", (long)settingsChangedNotifCount]);

        // ---------- B. postSettings 连续快速修改：旧回包不能覆盖新状态或误报成功/失败 ----------
        [gPendingGets removeAllObjects];
        [gPendingPosts removeAllObjects];
        ClearToasts(win);
        settingsChangedNotifCount = 0;

        // 连续两次修改：先发 POST #1 (filter=poly-sinc-gauss-long)，未回包前再发 POST #2 (filter=poly-sinc-ext2)
        [vc postSettings:@{@"filter": @"poly-sinc-gauss-long"}];
        [vc postSettings:@{@"filter": @"poly-sinc-ext2"}];
        RLPMockRequest *post1 = PopFirstRequest(gPendingPosts, @"/api/settings");
        RLPMockRequest *post2 = PopFirstRequest(gPendingPosts, @"/api/settings");
        CK(post1 != nil && post2 != nil,
           "B0 连续两次 postSettings 均已入队",
           [NSString stringWithFormat:@"p1=%@ p2=%@", post1.body ?: @"nil", post2.body ?: @"nil"]);

        // 场景 B1：旧回包 post1 先到达且返回 ok=YES（此时 post2 仍未完成），不应误报已生效或发 reloadSettings
        if (post1 && post1.completion) {
            post1.completion(@{@"ok": @YES});
        }
        NSString *toastAfterStaleOk = LatestToastText(win);
        const NSUInteger getsAfterStaleOk = CountRequests(gPendingGets, @"/api/settings");
        CK(getsAfterStaleOk == 0 && settingsChangedNotifCount == 0 && toastAfterStaleOk.length == 0,
           "B1 新请求在途时，旧 POST 成功回包不得误报已生效、不得触发 reloadSettings 或广播变更",
           [NSString stringWithFormat:@"gets=%lu notif=%ld toast=%@",
            (unsigned long)getsAfterStaleOk, (long)settingsChangedNotifCount, toastAfterStaleOk]);

        // 场景 B2：最新请求 post2 成功并完成 reloadSettings 写入新状态；随后若还有更旧的请求延迟失败回包，不能覆盖或报错
        [gPendingGets removeAllObjects];
        [gPendingPosts removeAllObjects];
        ClearToasts(win);
        settingsChangedNotifCount = 0;

        [vc postSettings:@{@"filter": @"poly-sinc-gauss-long"}]; // postOld
        [vc postSettings:@{@"filter": @"poly-sinc-ext2"}];        // postNew
        RLPMockRequest *postOld = PopFirstRequest(gPendingPosts, @"/api/settings");
        RLPMockRequest *postNew = PopFirstRequest(gPendingPosts, @"/api/settings");

        if (postNew && postNew.completion) {
            postNew.completion(@{@"ok": @YES});
        }
        RLPMockRequest *reloadNew = PopFirstRequest(gPendingGets, @"/api/settings");
        if (reloadNew && reloadNew.completion) {
            reloadNew.completion(@{
                @"ok": @YES,
                @"kv": @{
                    @"backend": @"coreaudio",
                    @"device": @"dev-a",
                    @"hogexcl": @"1",
                    @"filter": @"poly-sinc-ext2",
                }
            });
        }
        ClearToasts(win);
        settingsChangedNotifCount = 0;

        // 延迟的旧回包 postOld 失败到达
        if (postOld && postOld.completion) {
            postOld.completion(@{@"ok": @NO, @"error": @"stale timeout"});
        }
        NSString *toastAfterStaleFail = LatestToastText(win);
        CK([vc.settings[@"filter"] isEqualToString:@"poly-sinc-ext2"] &&
           toastAfterStaleFail.length == 0 &&
           settingsChangedNotifCount == 0,
           "B2 新状态落盘后，延迟到达的旧 POST 失败回包不得报错或覆盖新状态",
           [NSString stringWithFormat:@"filter=%@ toast=%@ notif=%ld",
            vc.settings[@"filter"] ?: @"nil", toastAfterStaleFail, (long)settingsChangedNotifCount]);

        // ---------- C. 输出选择未成功时不应装作已应用 ----------
        [gPendingGets removeAllObjects];
        [gPendingPosts removeAllObjects];
        ClearToasts(win);
        settingsChangedNotifCount = 0;
        [vc syncOutputSummary];
        NSString *confirmedOutput = vc.outputValue.stringValue ?: @"";

        [vc onOpenOutput:nil];
        NSView *popView = vc.popover.contentViewController.view;
        NSButton *sharedBtn = (NSButton *)FindById(popView, @"coreaudio-shared");
        [vc onPickBackend:sharedBtn];

        RLPMockRequest *outPost = PopFirstRequest(gPendingPosts, @"/api/settings");
        CK(outPost != nil && [outPost.body containsString:@"backend=coreaudio-shared"],
           "C0 onPickBackend 发起 backend=coreaudio-shared POST",
           outPost.body ?: @"nil");

        if (outPost && outPost.completion) {
            outPost.completion(@{@"ok": @NO, @"error": @"CoreAudio switch failed"});
        }
        NSString *toastAfterOutFail = LatestToastText(win);
        CK([vc.outputValue.stringValue isEqualToString:confirmedOutput] &&
           ![vc.outputValue.stringValue containsString:RLPTr(@"共享播放")] &&
           settingsChangedNotifCount == 0 &&
           ([toastAfterOutFail containsString:@"CoreAudio switch failed"] ||
            [vc.presetNotes.stringValue containsString:@"CoreAudio switch failed"]),
           "C1 输出选择 POST 失败时不装作已应用，保留原摘要并提示 backend error",
           [NSString stringWithFormat:@"out=%@ toast=%@ notes=%@ notif=%ld",
            vc.outputValue.stringValue ?: @"nil", toastAfterOutFail,
            vc.presetNotes.stringValue ?: @"nil", (long)settingsChangedNotifCount]);

        [[NSNotificationCenter defaultCenter] removeObserver:notifToken];
        [gPendingGets removeAllObjects];
        [gPendingPosts removeAllObjects];

        std::printf("\n%s（通过 %d / 失败 %d）\n",
                    gFail == 0 ? "native_listening_async_contract 全部通过" : "native_listening_async_contract 有失败",
                    gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
