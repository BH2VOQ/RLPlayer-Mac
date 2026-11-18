// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_settings_draft_contract.mm — 设置页草稿保留与延迟回包竞争契约判据
//
// 证明：
//   1. 实时切语言清空 paneCache 会丢失非当前页签的未提交草稿：
//      - meta 页签：llm.key（NSSecureTextField）、llm.base（NSTextField）
//      - diag 页签：sp_fbtext（NSTextView）
//   2. 实时切语言清空 paneCache 会丢失 EQ 页签的非当前页签状态与草稿：
//      - eq.inspector 选中频段（bandIndex）
//      - opra.query（NSTextField）与 presetName（NSTextField）
//   3. 当前页签同步恢复草稿后，由 reloadData 触发的延迟 /api/settings 与 /api/llm 旧回包
//      会覆盖非焦点草稿（out 页签 sp_buffer；meta 页签 llm.base / llm.modeltext）。
//
// 纪律：
//   - 仅 swizzle +[RLPCoreClient shared] 与 -[RLPSettingsViewController probeFeedbackChannel]；
//   - 不启动核心、不碰 8899、不连设备、不扫描网络、不出声（全部 mock）。
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#import "RLPCoreClient.h"
#import "RLPSettingsViewController.h"
#import "RLPEqualizerView.h"
#import "RLPEQFaderView.h"
#import "RLPEQFaderInspector.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

#include <cstdio>

@interface RLPSettingsViewController (DraftSaveContractAccess)
- (void)postKey:(NSString *)key value:(NSString *)value;
- (void)applyKV:(NSDictionary *)kv toTextField:(NSTextField *)field key:(NSString *)key;
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

#pragma mark - 延迟 Mock 客户端（swizzle +[RLPCoreClient shared]）

@interface RLPDraftMockClient : NSObject
@property (nonatomic, assign) BOOL holdSettingsGet;
@property (nonatomic, assign) BOOL holdLlmGet;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldSettingsGets;
@property (nonatomic, strong) NSMutableArray<RLPJSONCompletion> *heldLlmGets;
@property (nonatomic, copy) NSDictionary *serverSettingsKV;
@property (nonatomic, copy) NSDictionary *serverLlmPayload;
@end

@implementation RLPDraftMockClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _heldSettingsGets = [NSMutableArray array];
        _heldLlmGets = [NSMutableArray array];
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
    if ([path hasPrefix:@"/api/settings"] && self.holdSettingsGet) {
        [self.heldSettingsGets addObject:[completion copy]];
        return;
    }
    if ([path isEqualToString:@"/api/llm"] && self.holdLlmGet) {
        [self.heldLlmGets addObject:[completion copy]];
        return;
    }
    NSDictionary *json = [self fixtureForPath:path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(json); });
}

- (void)postJSON:(NSString *)path body:(nullable NSString *)body completion:(nullable RLPJSONCompletion)completion {
    (void)path; (void)body;
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

- (void)flushHeldSettingsGets {
    NSArray<RLPJSONCompletion> *cbs = [self.heldSettingsGets copy];
    [self.heldSettingsGets removeAllObjects];
    NSDictionary *payload = @{ @"ok": @YES, @"kv": self.serverSettingsKV ?: @{} };
    for (RLPJSONCompletion cb in cbs) cb(payload);
}

- (void)flushHeldLlmGets {
    NSArray<RLPJSONCompletion> *cbs = [self.heldLlmGets copy];
    [self.heldLlmGets removeAllObjects];
    NSDictionary *payload = self.serverLlmPayload ?: @{ @"ok": @YES };
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
    if ([path hasPrefix:@"/api/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/input/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/filters"]) return @{ @"ok": @YES, @"items": @[] };
    if ([path hasPrefix:@"/api/playmode"]) return @{ @"ok": @YES, @"repeat": @0, @"shuffle": @NO };
    if ([path hasPrefix:@"/api/lib/roots"]) return @{ @"ok": @YES, @"roots": @[] };
    if ([path hasPrefix:@"/api/lib/stats"]) return @{ @"ok": @YES, @"roots": @[], @"tracks": @0 };
    if ([path hasPrefix:@"/api/upnp/devices"]) return @{ @"ok": @YES, @"devices": @[] };
    if ([path hasPrefix:@"/api/gpu"]) return @{ @"ok": @YES, @"backends": @[] };
    if ([path hasPrefix:@"/api/net"]) return @{ @"ok": @YES, @"urls": @[] };
    if ([path hasPrefix:@"/api/diag"]) return @{ @"ok": @YES };
    if ([path hasPrefix:@"/api/writeback/status"]) return @{ @"ok": @YES, @"busy": @NO };
    if ([path isEqualToString:@"/api/peq"]) {
        NSMutableArray *bands = [NSMutableArray arrayWithCapacity:20];
        const double freqs[20] = {
            31, 44, 62, 88, 125, 175, 250, 350, 500, 700,
            1000, 1400, 2000, 2800, 4000, 5600, 8000, 11200, 16000, 20000
        };
        for (int i = 0; i < 20; ++i) {
            [bands addObject:@{ @"f": @(freqs[i]), @"g": @(0.0), @"q": @(1.0), @"type": @"PK", @"on": @YES }];
        }
        return @{ @"ok": @YES, @"bypass": @NO, @"preamp": @(0.0), @"bands": bands, @"points": @[] };
    }
    if ([path hasPrefix:@"/api/opra/index"]) {
        return @{ @"ok": @YES, @"models": @[], @"count": @0 };
    }
    return @{ @"ok": @YES };
}

@end

static RLPDraftMockClient *gMockClient = nil;
static id MockSharedCoreClient(id cls, SEL sel) {
    (void)cls; (void)sel;
    return gMockClient;
}

static void NoOpProbeFeedbackChannel(id self, SEL sel) {
    (void)self; (void)sel;
}

static void TriggerLanguageSwitch(NSString *lang) {
    RLPSetLanguage(lang);
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPLanguageDidChangeNotification
                                                        object:nil];
    Pump(0.05);
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_settings_draft_contract（设置页草稿与延迟回包契约 · 纯 Mock）===\n");

        gMockClient = [[RLPDraftMockClient alloc] init];

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
        // 1. 非当前页签草稿在实时切语言清空 paneCache 时丢失（LLM key/base + 诊断 feedback）
        // =========================================================================
        [settings selectPane:@"meta"];
        Pump(0.05);
        Ck([[settings currentPaneKey] isEqualToString:@"meta"],
           "前置：selectPane('meta') 切到元数据页签",
           [settings currentPaneKey]);

        NSTextField *llmBase = (NSTextField *)FindById(root, @"llm.base");
        NSSecureTextField *llmKey = (NSSecureTextField *)FindById(root, @"llm.key");
        Ck(llmBase != nil && llmKey != nil,
           "前置：找到真实控件 llm.base 与 llm.key",
           [NSString stringWithFormat:@"base=%p key=%p", llmBase, llmKey]);

        NSString *const kDraftLlmBase = @"https://custom-draft.example/v1";
        NSString *const kDraftLlmKey = @"sk-draft-secret-1234";
        llmBase.stringValue = kDraftLlmBase;
        llmKey.stringValue = kDraftLlmKey;
        [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:llmBase];
        [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:llmKey];

        [settings selectPane:@"diag"];
        Pump(0.05);
        Ck([[settings currentPaneKey] isEqualToString:@"diag"],
           "前置：selectPane('diag') 切到诊断页签",
           [settings currentPaneKey]);

        NSTextView *fbText = (NSTextView *)FindById(root, @"sp_fbtext");
        Ck(fbText != nil, "前置：找到真实控件 sp_fbtext", @"nil");

        NSString *const kDraftFeedback = @"unsaved diagnostic feedback draft";
        fbText.string = kDraftFeedback;

        // 切到无关页签 adv，使 meta 与 diag 均处于非当前页签
        [settings selectPane:@"adv"];
        Pump(0.05);
        Ck([[settings currentPaneKey] isEqualToString:@"adv"],
           "前置：selectPane('adv') 使 meta 与 diag 成为非当前页签",
           [settings currentPaneKey]);

        TriggerLanguageSwitch(@"en");

        // 切回 meta 与 diag 断言草稿是否保留
        [settings selectPane:@"meta"];
        Pump(0.05);
        NSTextField *llmBaseAfter = (NSTextField *)FindById(root, @"llm.base");
        NSSecureTextField *llmKeyAfter = (NSSecureTextField *)FindById(root, @"llm.key");
        Ck(llmKeyAfter && [llmKeyAfter.stringValue isEqualToString:kDraftLlmKey],
           "1a. 切语言后切回 meta：未提交的 llm.key（NSSecureTextField）草稿保留",
           [NSString stringWithFormat:@"got='%@'", llmKeyAfter.stringValue ?: @"nil"]);
        Ck(llmBaseAfter && [llmBaseAfter.stringValue isEqualToString:kDraftLlmBase],
           "1b. 切语言后切回 meta：未提交的 llm.base 草稿保留",
           [NSString stringWithFormat:@"got='%@'", llmBaseAfter.stringValue ?: @"nil"]);

        [settings selectPane:@"diag"];
        Pump(0.05);
        NSTextView *fbTextAfter = (NSTextView *)FindById(root, @"sp_fbtext");
        Ck(fbTextAfter && [fbTextAfter.string isEqualToString:kDraftFeedback],
           "1c. 切语言后切回 diag：未提交的 sp_fbtext（NSTextView）诊断草稿保留",
           [NSString stringWithFormat:@"got='%@'", fbTextAfter.string ?: @"nil"]);

        // =========================================================================
        // 2. 非当前页签 EQ inspector 选中频段与 presetName / opraQuery 草稿保留
        // =========================================================================
        [settings selectPane:@"eq"];
        Pump(0.05);
        Ck([[settings currentPaneKey] isEqualToString:@"eq"],
           "前置：selectPane('eq') 切到 EQ 页签",
           [settings currentPaneKey]);

        RLPEqualizerView *eqView = [settings valueForKey:@"eqView"];
        RLPEQFaderView *fader = (RLPEQFaderView *)FindById(root, @"eq.fader");
        RLPEQFaderInspector *inspector = (RLPEQFaderInspector *)FindById(root, @"eq.inspector");
        NSTextField *opraQuery = (NSTextField *)FindById(root, @"opra.query");
        NSTextField *presetName = eqView ? [eqView valueForKey:@"presetName"] : nil;
        Ck(eqView && fader && inspector && opraQuery && presetName,
           "前置：找到 eqView / eq.fader / eq.inspector / opra.query / presetName",
           [NSString stringWithFormat:@"eq=%p fader=%p insp=%p opra=%p preset=%p",
            eqView, fader, inspector, opraQuery, presetName]);

        // 通过真实推子数值框提交选中第 3 段
        NSTextField *band3Field = [fader valueFieldForBand:3];
        if (band3Field) {
            band3Field.stringValue = @"1.5";
            [fader onValueFieldCommitted:band3Field];
        }
        Pump(0.02);
        Ck(inspector.bandIndex == 3,
           "前置：通过 eq.fader 选中频段 3 反映到 eq.inspector",
           [NSString stringWithFormat:@"bandIndex=%ld", (long)inspector.bandIndex]);

        NSString *const kDraftOpraQuery = @"HD650 draft";
        NSString *const kDraftPresetName = @"MyDraftPreset";
        opraQuery.stringValue = kDraftOpraQuery;
        presetName.stringValue = kDraftPresetName;

        [settings selectPane:@"adv"];
        Pump(0.05);
        TriggerLanguageSwitch(@"zh");

        [settings selectPane:@"eq"];
        Pump(0.05);
        RLPEqualizerView *eqViewAfter = [settings valueForKey:@"eqView"];
        RLPEQFaderInspector *inspectorAfter = (RLPEQFaderInspector *)FindById(root, @"eq.inspector");
        NSTextField *opraQueryAfter = (NSTextField *)FindById(root, @"opra.query");
        NSTextField *presetNameAfter = eqViewAfter ? [eqViewAfter valueForKey:@"presetName"] : nil;

        Ck(inspectorAfter && inspectorAfter.bandIndex == 3,
           "2a. 切语言后切回 eq：eq.inspector 选中频段 3 保留",
           [NSString stringWithFormat:@"bandIndex=%ld", (long)(inspectorAfter ? inspectorAfter.bandIndex : -99)]);
        Ck(opraQueryAfter && [opraQueryAfter.stringValue isEqualToString:kDraftOpraQuery],
           "2b. 切语言后切回 eq：opra.query 草稿保留",
           [NSString stringWithFormat:@"got='%@'", opraQueryAfter.stringValue ?: @"nil"]);
        Ck(presetNameAfter && [presetNameAfter.stringValue isEqualToString:kDraftPresetName],
           "2c. 切语言后切回 eq：presetName 草稿保留",
           [NSString stringWithFormat:@"got='%@'", presetNameAfter.stringValue ?: @"nil"]);

        // 2d. 普通切 tab（不切语言）时，Q 输入期已写回模型
        {
            RLPEQFaderInspector *inspQ = (RLPEQFaderInspector *)FindById(root, @"eq.inspector");
            NSTextField *qField = [inspQ qField];
            [win makeFirstResponder:qField];
            [qField selectText:nil];
            qField.stringValue = @"1.8";
            [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification
                                                                object:qField];
            Ck(qField.currentEditor != nil && [qField.stringValue isEqualToString:@"1.8"],
               "2d-pre. Q 输入框进入编辑并写入 1.8",
               [NSString stringWithFormat:@"editor=%p value='%@'", qField.currentEditor, qField.stringValue]);
            [settings selectPane:@"adv"];
            Pump(0.05);
            [settings selectPane:@"eq"];
            Pump(0.05);
            RLPEQFaderInspector *inspQ2 = (RLPEQFaderInspector *)FindById(root, @"eq.inspector");
            RLPEqualizerView *eqQ2 = [settings valueForKey:@"eqView"];
            NSArray<NSDictionary *> *bandsQ = eqQ2 ? [eqQ2 valueForKey:@"bands"] : nil;
            NSDictionary *b3 = (bandsQ.count > 3 && [bandsQ[3] isKindOfClass:[NSDictionary class]]) ? bandsQ[3] : nil;
            const double qModel = b3 && [b3[@"q"] respondsToSelector:@selector(doubleValue)]
                ? [b3[@"q"] doubleValue] : -1.0;
            Ck(inspQ2 && inspQ2.bandIndex == 3 && qModel > 1.79 && qModel < 1.81,
               "2d. 普通切 tab 后 Q 模型仍为 1.8（不是退回 1.00）",
               [NSString stringWithFormat:@"band=%ld q=%.2f", (long)(inspQ2 ? inspQ2.bandIndex : -99), qModel]);
        }

        // =========================================================================
        // 3. 当前页签恢复草稿后，延迟 /api/settings 与 /api/llm 旧回包覆盖非焦点草稿
        // =========================================================================
        // 3a: out 页签 sp_buffer（非焦点）被延迟 /api/settings 回包覆盖
        [settings selectPane:@"out"];
        Pump(0.05);
        NSTextField *bufField = (NSTextField *)FindById(root, @"sp_buffer");
        Ck(bufField != nil, "前置：找到 out 页签 sp_buffer", @"nil");

        gMockClient.holdSettingsGet = YES;
        NSString *const kDraftBuffer = @"250";
        bufField.stringValue = kDraftBuffer;
        [win makeFirstResponder:nil];

        TriggerLanguageSwitch(@"en");
        NSTextField *bufAfterLang = (NSTextField *)FindById(root, @"sp_buffer");
        Ck(bufAfterLang && [bufAfterLang.stringValue isEqualToString:kDraftBuffer],
           "3a-pre. 切语言同步恢复当前页签 out 的 sp_buffer 草稿",
           [NSString stringWithFormat:@"got='%@'", bufAfterLang.stringValue ?: @"nil"]);
        Ck(gMockClient.heldSettingsGets.count > 0,
           "3a-pre. 切语言重建当前页签触发了 /api/settings 异步读回",
           [NSString stringWithFormat:@"held=%lu", (unsigned long)gMockClient.heldSettingsGets.count]);

        [gMockClient flushHeldSettingsGets];
        gMockClient.holdSettingsGet = NO;
        Pump(0.05);
        Ck(bufAfterLang && [bufAfterLang.stringValue isEqualToString:kDraftBuffer],
           "3a. 延迟 /api/settings 旧回包到达后，当前页签非焦点 sp_buffer 草稿不被覆盖",
           [NSString stringWithFormat:@"got='%@' expected='%@'", bufAfterLang.stringValue ?: @"nil", kDraftBuffer]);

        // 3b: meta 页签 llm.base / llm.modeltext（非焦点）被延迟 /api/llm 回包覆盖
        [settings selectPane:@"meta"];
        Pump(0.05);
        NSTextField *metaLlmBase = (NSTextField *)FindById(root, @"llm.base");
        NSTextField *metaLlmModel = (NSTextField *)FindById(root, @"llm.modeltext");
        Ck(metaLlmBase != nil && metaLlmModel != nil,
           "前置：找到 meta 页签 llm.base 与 llm.modeltext",
           [NSString stringWithFormat:@"base=%p model=%p", metaLlmBase, metaLlmModel]);

        gMockClient.holdLlmGet = YES;
        NSString *const kDraftMetaBase = @"https://draft-llm.local/v1";
        NSString *const kDraftMetaModel = @"draft-model-x";
        metaLlmBase.stringValue = kDraftMetaBase;
        metaLlmModel.stringValue = kDraftMetaModel;
        [win makeFirstResponder:nil];

        TriggerLanguageSwitch(@"zh");
        NSTextField *metaLlmBaseAfter = (NSTextField *)FindById(root, @"llm.base");
        NSTextField *metaLlmModelAfter = (NSTextField *)FindById(root, @"llm.modeltext");
        Ck(metaLlmBaseAfter && [metaLlmBaseAfter.stringValue isEqualToString:kDraftMetaBase] &&
           metaLlmModelAfter && [metaLlmModelAfter.stringValue isEqualToString:kDraftMetaModel],
           "3b-pre. 切语言同步恢复当前页签 meta 的 llm.base / llm.modeltext 草稿",
           [NSString stringWithFormat:@"base='%@' model='%@'",
            metaLlmBaseAfter.stringValue ?: @"nil", metaLlmModelAfter.stringValue ?: @"nil"]);
        Ck(gMockClient.heldLlmGets.count > 0,
           "3b-pre. 切语言重建当前页签触发了 /api/llm 异步读回",
           [NSString stringWithFormat:@"held=%lu", (unsigned long)gMockClient.heldLlmGets.count]);

        [gMockClient flushHeldLlmGets];
        gMockClient.holdLlmGet = NO;
        Pump(0.05);
        Ck(metaLlmBaseAfter && [metaLlmBaseAfter.stringValue isEqualToString:kDraftMetaBase],
           "3b-1. 延迟 /api/llm 旧回包到达后，当前页签非焦点 llm.base 草稿不被覆盖",
           [NSString stringWithFormat:@"got='%@' expected='%@'",
            metaLlmBaseAfter.stringValue ?: @"nil", kDraftMetaBase]);
        Ck(metaLlmModelAfter && [metaLlmModelAfter.stringValue isEqualToString:kDraftMetaModel],
           "3b-2. 延迟 /api/llm 旧回包到达后，当前页签非焦点 llm.modeltext 草稿不被覆盖",
           [NSString stringWithFormat:@"got='%@' expected='%@'",
            metaLlmModelAfter.stringValue ?: @"nil", kDraftMetaModel]);

        // A saved draft must release its guard so legitimate later backend values can appear.
        [settings selectPane:@"out"];
        Pump(0.05);
        NSTextField *savedBuffer = (NSTextField *)FindById(root, @"sp_buffer");
        savedBuffer.stringValue = @"300";
        [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:savedBuffer];
        [settings postKey:@"buffer" value:@"300"];
        Pump(0.05);
        [settings applyKV:@{@"buffer": @"400"} toTextField:savedBuffer key:@"buffer"];
        Ck([savedBuffer.stringValue isEqualToString:@"400"],
           "4. 保存成功后解除草稿保护，后端新值可正常回显", savedBuffer.stringValue);

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
