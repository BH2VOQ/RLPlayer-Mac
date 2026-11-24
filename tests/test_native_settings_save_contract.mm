// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_settings_save_contract.mm — 设置页保存回调与草稿/dirty 竞争契约判据
//
// 证明两个可达漏口：
//   1. adv 页签 rootField（sp_root）+ onAddRoot：
//      - 1a. 保存成功后 dirty 必须释放，后端 /api/settings 可重新回显 root；
//      - 1b. POST /api/lib/roots 回包前若用户又输入新路径，旧成功回调不可抹掉新草稿与 dirty。
//   2. meta 页签 llm.key / search.key + onLlmSave / onSearchSave：
//      - 2a. llm.key 写 key1 并 onLlmSave（mock 扣留 POST /api/llm），回包前改成 key2 并触发编辑通知，
//            旧成功回调不可清空 key2 与 llm.key dirty；
//      - 2b. search.key 写 key1 并 onSearchSave（mock 扣留 POST /api/llm），回包前改成 key2 并触发编辑通知，
//            旧成功回调不可清空 key2 与 search.key dirty。
//
// 纪律：
//   - 仅 swizzle +[RLPCoreClient shared] 与 -[RLPSettingsViewController probeFeedbackChannel]；
//   - 不启动核心、不碰 8899、不连设备、不扫描网络、不出声（全部 mock / null / -120）；
//   - 构造 key 仅 fake，不在输出中打印任何 key 明文，只输出长度与布尔状态。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#import "RLPCoreClient.h"
#import "RLPSettingsViewController.h"
#import "RLPSupport.h"

#include <cstdio>

@interface RLPSettingsViewController (SaveContractAccess)
- (void)onAddRoot:(id)sender;
- (void)onLlmSave:(id)sender;
- (void)onSearchSave:(id)sender;
- (void)reloadData;
@end

static int gPass = 0, gFail = 0;

static void Ck(BOOL ok, const char *what, NSString *detail) {
    if (ok) {
        ++gPass;
        std::printf("  [PASS] %s\n", what);
    } else {
        ++gFail;
        std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: "");
    }
}

static void Pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *sub in v.subviews) CollectViews(sub, out);
}

static NSView *FindById(NSView *root, NSString *ident) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    CollectViews(root, all);
    for (NSView *v in all) {
        if ([v.identifier isEqualToString:ident]) return v;
    }
    return nil;
}

static BOOL IsDirtyId(RLPSettingsViewController *settings, NSString *ident) {
    NSSet *dirty = [settings valueForKey:@"dirtyControlIds"];
    return [dirty isKindOfClass:[NSSet class]] && [dirty containsObject:ident];
}

static void SimulateTextEdit(NSTextField *field, NSString *value) {
    field.stringValue = value ?: @"";
    [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification
                                                        object:field];
}

#pragma mark - 延迟 Mock 客户端（swizzle +[RLPCoreClient shared]）

@interface RLPSaveMockClient : NSObject
@property (nonatomic, assign) BOOL holdLibRootsPost;
@property (nonatomic, assign) BOOL holdLlmPost;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldLibRootsPosts;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldLlmPosts;
@property (nonatomic, copy) NSDictionary *serverSettingsKV;
@property (nonatomic, copy) NSDictionary *serverLlmPayload;
@property (nonatomic, strong) NSMutableArray<NSString *> *postedSettingsBodies;
@property (nonatomic, strong) NSMutableArray<NSString *> *postedInputStartBodies;
@end

@implementation RLPSaveMockClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _heldLibRootsPosts = [NSMutableArray array];
        _heldLlmPosts = [NSMutableArray array];
        _postedSettingsBodies = [NSMutableArray array];
        _postedInputStartBodies = [NSMutableArray array];
        _serverSettingsKV = @{
            @"backend": @"null",
            @"volume": @(-120),
            @"buffer": @"50",
            @"ramp": @"0",
            @"uimode": @"listen"
        };
        _serverLlmPayload = @{
            @"ok": @YES,
            @"baseUrl": @"https://api.deepseek.com",
            @"model": @"deepseek-chat",
            @"configured": @YES,
            @"masked": @"sk-****1234"
        };
    }
    return self;
}

- (BOOL)started { return YES; }
- (BOOL)startEmbedded { return NO; }
- (void)shutdown {}

- (nullable NSDictionary *)jsonWithMethod:(NSString *)method
                                     path:(NSString *)path
                                     body:(nullable NSString *)body {
    (void)method; (void)path; (void)body;
    return nil;
}

- (nullable NSData *)dataWithMethod:(NSString *)method
                               path:(NSString *)path
                               body:(nullable NSString *)body
                        contentType:(NSString * _Nullable * _Nullable)contentType {
    (void)method; (void)path; (void)body; (void)contentType;
    return nil;
}

- (void)getJSON:(NSString *)path completion:(nullable RLPJSONCompletion)completion {
    if (!completion) return;
    NSDictionary *json = [self fixtureForPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(json); });
}

- (void)postJSON:(NSString *)path body:(nullable NSString *)body completion:(nullable RLPJSONCompletion)completion {
    if ([path isEqualToString:@"/api/settings"] && body) [self.postedSettingsBodies addObject:body];
    if ([path isEqualToString:@"/api/input/start"] && body) [self.postedInputStartBodies addObject:body];
    if ([path isEqualToString:@"/api/lib/roots"] && self.holdLibRootsPost) {
        if (completion) [self.heldLibRootsPosts addObject:[completion copy]];
        return;
    }
    if ([path isEqualToString:@"/api/llm"] && self.holdLlmPost) {
        if (completion) [self.heldLlmPosts addObject:[completion copy]];
        return;
    }
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@{ @"ok": @YES }); });
    }
}

- (void)getData:(NSString *)path completion:(nullable RLPDataCompletion)completion {
    (void)path;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
}

- (void)postData:(NSString *)path
            body:(NSData *)body
     contentType:(NSString *)contentType
      completion:(nullable RLPJSONCompletion)completion {
    (void)path; (void)body; (void)contentType;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@{ @"ok": @YES }); });
}

- (void)flushHeldLibRootsPostsWithOK:(BOOL)ok {
    NSArray<RLPJSONCompletion> *cbs = [self.heldLibRootsPosts copy];
    [self.heldLibRootsPosts removeAllObjects];
    NSDictionary *payload = ok ? @{ @"ok": @YES } : @{ @"ok": @NO, @"error": @"mock error" };
    for (RLPJSONCompletion cb in cbs) cb(payload);
}

- (void)flushHeldLlmPostsWithOK:(BOOL)ok {
    NSArray<RLPJSONCompletion> *cbs = [self.heldLlmPosts copy];
    [self.heldLlmPosts removeAllObjects];
    NSDictionary *payload = ok ? @{ @"ok": @YES } : @{ @"ok": @NO, @"error": @"mock error" };
    for (RLPJSONCompletion cb in cbs) cb(payload);
}

- (NSDictionary *)fixtureForPath:(NSString *)path {
    if ([path hasPrefix:@"/api/settings"]) {
        return @{ @"ok": @YES, @"kv": self.serverSettingsKV ?: @{} };
    }
    if ([path isEqualToString:@"/api/llm"]) {
        return self.serverLlmPayload ?: @{ @"ok": @YES };
    }
    if ([path hasPrefix:@"/api/llm/models"]) {
        return @{ @"ok": @YES, @"models": @[ @"deepseek-chat" ] };
    }
    if ([path hasPrefix:@"/api/llm/test"]) {
        return @{ @"ok": @YES, @"model": @"deepseek-chat", @"latencyMs": @12 };
    }
    if ([path hasPrefix:@"/api/devices"]) {
        return @{ @"ok": @YES, @"devices": @[ @{ @"id": @"76", @"name": @"MockOutputSpeaker" } ] };
    }
    if ([path hasPrefix:@"/api/input/devices"]) {
        return @{
            @"ok": @YES,
            @"devices": @[
                @{ @"id": @"__system_loopback__", @"name": @"系统混音回环（本机正在播放的声音）", @"loopback": @YES, @"default": @NO },
                @{ @"id": @"106", @"name": @"MockPhysicalMic", @"loopback": @NO, @"default": @YES }
            ]
        };
    }
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/playmode"]) return @{ @"ok": @YES, @"repeat": @0, @"shuffle": @NO };
    if ([path hasPrefix:@"/api/lib/roots"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/lib/stats"]) return @{ @"ok": @YES, @"roots": @[], @"tracks": @0 };
    if ([path hasPrefix:@"/api/upnp/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/gpu"]) return @{ @"ok": @YES, @"backends": @[] };
    if ([path hasPrefix:@"/api/net"]) return @{ @"ok": @YES, @"urls": @[] };
    if ([path hasPrefix:@"/api/diag"]) return @{ @"ok": @YES };
    if ([path hasPrefix:@"/api/writeback/status"]) return @{ @"ok": @YES, @"busy": @NO };
    return @{ @"ok": @YES };
}

@end

static RLPSaveMockClient *gMockClient = nil;
static id MockSharedCoreClient(id cls, SEL sel) {
    (void)cls; (void)sel;
    return gMockClient;
}

static void NoOpProbeFeedbackChannel(id self, SEL sel) {
    (void)self; (void)sel;
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_settings_save_contract（设置页保存回调与草稿/dirty 竞争契约 · 纯 Mock）===\n");

        gMockClient = [[RLPSaveMockClient alloc] init];

        // Swizzle +[RLPCoreClient shared] 与 -[RLPSettingsViewController probeFeedbackChannel]
        Method sharedMethod = class_getClassMethod([RLPCoreClient class], @selector(shared));
        method_setImplementation(sharedMethod, (IMP)MockSharedCoreClient);
        Method probeMethod = class_getInstanceMethod([RLPSettingsViewController class],
                                                     @selector(probeFeedbackChannel));
        if (probeMethod) {
            method_setImplementation(probeMethod, (IMP)NoOpProbeFeedbackChannel);
        }

        [RLPSettingsViewController setRlp_confirmsBitPerfectFix:NO];
        RLPSetLanguage(@"zh");

        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 900)
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        NSView *root = settings.view;
        root.frame = win.contentView.bounds;
        [win.contentView addSubview:root];
        [root layoutSubtreeIfNeeded];
        Pump(0.05);

        // =========================================================================
        // 1. adv 页签 rootField (sp_root) + onAddRoot：
        //    1a. 保存成功后 dirty 释放、后端可重新回显
        //    1b. 回包前用户又输入新路径，旧成功回调不可抹掉新草稿与 dirty
        // =========================================================================
        [settings selectPane:@"adv"];
        Pump(0.05);
        Ck([[settings currentPaneKey] isEqualToString:@"adv"],
           "前置：selectPane('adv') 切到通用页签",
           [settings currentPaneKey]);

        NSTextField *rootField = (NSTextField *)FindById(root, @"sp_root");
        Ck(rootField != nil, "前置：找到真实控件 sp_root", @"nil");

        // 1a: 输入路径 -> onAddRoot 成功 -> dirty 释放 -> 后端新值可回显
        NSString *const kRoot1 = @"/tmp/mock-music-root-1";
        SimulateTextEdit(rootField, kRoot1);
        Ck(IsDirtyId(settings, @"sp_root"),
           "1a-pre. 模拟 NSControlTextDidChange 后 sp_root 标记为 dirty",
           @"dirty=0");

        [settings onAddRoot:nil];
        Pump(0.05);

        Ck(rootField.stringValue.length == 0,
           "1a-1. onAddRoot 保存成功后无新草稿时清空 rootField",
           [NSString stringWithFormat:@"len=%lu", (unsigned long)rootField.stringValue.length]);
        Ck(!IsDirtyId(settings, @"sp_root"),
           "1a-2. onAddRoot 保存成功后必须释放 sp_root dirty",
           [NSString stringWithFormat:@"dirty=%d", IsDirtyId(settings, @"sp_root")]);

        NSString *const kRootEchoed = @"/tmp/mock-music-echoed";
        gMockClient.serverSettingsKV = @{
            @"backend": @"null",
            @"volume": @(-120),
            @"buffer": @"50",
            @"ramp": @"0",
            @"uimode": @"listen",
            @"root": kRootEchoed
        };
        [settings reloadData];
        Pump(0.05);
        Ck([rootField.stringValue isEqualToString:kRootEchoed],
           "1a-3. onAddRoot 保存成功后，后端 /api/settings 回显 root 不再被残留 dirty 拦截",
           [NSString stringWithFormat:@"got='%@' expected='%@'",
            rootField.stringValue ?: @"nil", kRootEchoed]);

        // 1b: 扣留 POST /api/lib/roots，回包前用户输入新路径，旧成功回调不可抹掉新草稿与 dirty
        gMockClient.holdLibRootsPost = YES;
        NSString *const kRootOld = @"/tmp/mock-music-old";
        NSString *const kRootNew = @"/tmp/mock-music-new-draft";
        SimulateTextEdit(rootField, kRootOld);
        [settings onAddRoot:nil];
        Ck(gMockClient.heldLibRootsPosts.count == 1,
           "1b-pre. onAddRoot 触发 POST /api/lib/roots 并被 mock 扣留",
           [NSString stringWithFormat:@"held=%lu", (unsigned long)gMockClient.heldLibRootsPosts.count]);

        SimulateTextEdit(rootField, kRootNew);
        [gMockClient flushHeldLibRootsPostsWithOK:YES];
        gMockClient.holdLibRootsPost = NO;
        Pump(0.05);

        Ck([rootField.stringValue isEqualToString:kRootNew],
           "1b-1. POST /api/lib/roots 旧成功回调到达后，不可抹掉回包前新输入的 rootField 草稿",
           [NSString stringWithFormat:@"got='%@' expected='%@'",
            rootField.stringValue ?: @"nil", kRootNew]);
        Ck(IsDirtyId(settings, @"sp_root"),
           "1b-2. POST /api/lib/roots 旧成功回调到达后，新草稿的 sp_root dirty 必须保留",
           [NSString stringWithFormat:@"dirty=%d", IsDirtyId(settings, @"sp_root")]);

        // =========================================================================
        // 2. meta 页签 llm.key / search.key + onLlmSave / onSearchSave：
        //    写 key1 并保存（mock 扣留 POST /api/llm），回包前改成 key2 并发编辑通知，
        //    旧成功回调不可清空 key2 与 dirty。
        // =========================================================================
        [settings selectPane:@"meta"];
        Pump(0.05);
        Ck([[settings currentPaneKey] isEqualToString:@"meta"],
           "前置：selectPane('meta') 切到元数据页签",
           [settings currentPaneKey]);

        NSSecureTextField *llmKey = (NSSecureTextField *)FindById(root, @"llm.key");
        NSSecureTextField *searchKey = (NSSecureTextField *)FindById(root, @"search.key");
        Ck(llmKey != nil && searchKey != nil,
           "前置：找到真实控件 llm.key 与 search.key",
           [NSString stringWithFormat:@"llmKey=%p searchKey=%p", llmKey, searchKey]);

        // 2a: llm.key
        NSString *const kFakeLlmKey1 = @"fake-llm-key-one-0001";
        NSString *const kFakeLlmKey2 = @"fake-llm-key-two-00002";
        gMockClient.holdLlmPost = YES;
        SimulateTextEdit(llmKey, kFakeLlmKey1);
        Ck(IsDirtyId(settings, @"llm.key"),
           "2a-pre. 模拟 NSControlTextDidChange 后 llm.key 标记为 dirty",
           [NSString stringWithFormat:@"dirty=%d", IsDirtyId(settings, @"llm.key")]);

        [settings onLlmSave:nil];
        Ck(gMockClient.heldLlmPosts.count == 1,
           "2a-pre. onLlmSave 触发 POST /api/llm 并被 mock 扣留",
           [NSString stringWithFormat:@"held=%lu", (unsigned long)gMockClient.heldLlmPosts.count]);

        SimulateTextEdit(llmKey, kFakeLlmKey2);
        [gMockClient flushHeldLlmPostsWithOK:YES];
        gMockClient.holdLlmPost = NO;
        Pump(0.05);

        Ck([llmKey.stringValue isEqualToString:kFakeLlmKey2],
           "2a-1. POST /api/llm 旧成功回调不可清空回包前新输入的 llm.key (key2)",
           [NSString stringWithFormat:@"curLen=%lu expectedLen=%lu match=%d",
            (unsigned long)llmKey.stringValue.length,
            (unsigned long)kFakeLlmKey2.length,
            [llmKey.stringValue isEqualToString:kFakeLlmKey2]]);
        Ck(IsDirtyId(settings, @"llm.key"),
           "2a-2. POST /api/llm 旧成功回调不可清除新草稿的 llm.key dirty",
           [NSString stringWithFormat:@"dirty=%d", IsDirtyId(settings, @"llm.key")]);

        // 2b: search.key
        NSString *const kFakeSearchKey1 = @"fake-search-key-one-0001";
        NSString *const kFakeSearchKey2 = @"fake-search-key-two-00002";
        gMockClient.holdLlmPost = YES;
        SimulateTextEdit(searchKey, kFakeSearchKey1);
        Ck(IsDirtyId(settings, @"search.key"),
           "2b-pre. 模拟 NSControlTextDidChange 后 search.key 标记为 dirty",
           [NSString stringWithFormat:@"dirty=%d", IsDirtyId(settings, @"search.key")]);

        [settings onSearchSave:nil];
        Ck(gMockClient.heldLlmPosts.count == 1,
           "2b-pre. onSearchSave 触发 POST /api/llm 并被 mock 扣留",
           [NSString stringWithFormat:@"held=%lu", (unsigned long)gMockClient.heldLlmPosts.count]);

        SimulateTextEdit(searchKey, kFakeSearchKey2);
        [gMockClient flushHeldLlmPostsWithOK:YES];
        gMockClient.holdLlmPost = NO;
        Pump(0.05);

        Ck([searchKey.stringValue isEqualToString:kFakeSearchKey2],
           "2b-1. POST /api/llm 旧成功回调不可清空回包前新输入的 search.key (key2)",
           [NSString stringWithFormat:@"curLen=%lu expectedLen=%lu match=%d",
            (unsigned long)searchKey.stringValue.length,
            (unsigned long)kFakeSearchKey2.length,
            [searchKey.stringValue isEqualToString:kFakeSearchKey2]]);
        Ck(IsDirtyId(settings, @"search.key"),
           "2b-2. POST /api/llm 旧成功回调不可清除新草稿的 search.key dirty",
           [NSString stringWithFormat:@"dirty=%d", IsDirtyId(settings, @"search.key")]);

        // 3. 输入页：/api/devices 不可覆盖 sp_indev；回环端点可选且保存/启动传 __system_loopback__
        [settings selectPane:@"in"];
        Pump(0.1);
        [settings reloadData];
        Pump(0.1);
        NSPopUpButton *inDev = (NSPopUpButton *)FindById(settings.view, @"sp_indev");
        NSInteger lbIdx = NSNotFound;
        BOOL pollutedByOut = NO;
        for (NSInteger i = 0; i < (NSInteger)inDev.numberOfItems; ++i) {
            NSMenuItem *it = [inDev itemAtIndex:i];
            if ([it.title containsString:@"MockOutputSpeaker"]) pollutedByOut = YES;
            if ([it.representedObject isKindOfClass:[NSString class]] &&
                [(NSString *)it.representedObject isEqualToString:@"__system_loopback__"]) {
                lbIdx = i;
            }
        }
        Ck(inDev && !pollutedByOut,
           "3-1. /api/devices 输出设备不得覆盖输入设备下拉 sp_indev",
           [NSString stringWithFormat:@"polluted=%d count=%ld", pollutedByOut, (long)inDev.numberOfItems]);
        Ck(lbIdx != NSNotFound && [inDev itemAtIndex:lbIdx].isEnabled &&
           [[inDev itemAtIndex:lbIdx].title containsString:@"回环"],
           "3-2. sp_indev 包含已启用的 __system_loopback__ 回环项",
           [NSString stringWithFormat:@"lbIdx=%ld", (long)lbIdx]);
        if (lbIdx != NSNotFound) {
            [gMockClient.postedSettingsBodies removeAllObjects];
            [gMockClient.postedInputStartBodies removeAllObjects];
            [inDev selectItemAtIndex:lbIdx];
            [settings performSelector:@selector(onInDevice:) withObject:inDev];
            [settings performSelector:@selector(onInputStart:) withObject:nil];
            Pump(0.05);
            BOOL savedLb = NO, startedLb = NO;
            for (NSString *b in gMockClient.postedSettingsBodies)
                if ([b containsString:@"indev=__system_loopback__"]) savedLb = YES;
            for (NSString *b in gMockClient.postedInputStartBodies)
                if ([b containsString:@"dev=__system_loopback__"] && [b containsString:@"mode=record"]) startedLb = YES;
            Ck(savedLb, "3-3. 选中回环项保存设置 POST indev=__system_loopback__",
               [gMockClient.postedSettingsBodies componentsJoinedByString:@" | "]);
            Ck(startedLb, "3-4. 点击开始采集 POST mode=record&dev=__system_loopback__",
               [gMockClient.postedInputStartBodies componentsJoinedByString:@" | "]);
        }

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
