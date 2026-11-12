// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_llm_endpoint.mm — AI 接入 / 联网检索端点的真链路判据（2026-11-12 用户实测反馈）
//
// 用户报的两个真故障（离线判据抓不到，必须真核心）：
//   ① 「点保存就切成默认模型」：原生保存时把 model= 一起发，且模型框可能是空/过期值
//      ⟹ 覆盖用户已选模型。web llmSave **只发 base_url / key**，模型由下拉单独保存。
//   ② 「测试连接失灵」：原生发 api_key=，后端只认 key= ⟹ 密钥从未落盘 ⟹ 测试必然 not_configured。
//   ③ fetch / search 端点选项缺失：后端 search_provider / search_base_url / search_key 三键
//      原生完全没有 UI。
//
// 纪律：隔离 state/library、backend=null、volume=-120；**绝不发真实网络请求**
// （只验配置落盘与读回，不调 /api/llm/test 去连外网）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPSettingsViewController.h"

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void CK(BOOL ok, const char *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what); }
    else { ++gFail; std::printf("  [FAIL] %s — %s\n", what, detail.UTF8String ?: ""); }
}
static void CollectViews(NSView *v, NSMutableArray<NSView *> *out) {
    if (!v) return;
    [out addObject:v];
    for (NSView *s in v.subviews) CollectViews(s, out);
}
static NSView *FindById(NSView *root, NSString *ident) {
    NSMutableArray<NSView *> *all = [NSMutableArray array];
    CollectViews(root, all);
    for (NSView *v in all) if ([v.identifier isEqualToString:ident]) return v;
    return nil;
}
static void Pump(NSTimeInterval s) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_llm_endpoint（真核心 · 隔离目录 · 不连外网）===\n");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-llm-%d", (int)getpid()]];
        NSString *state = [root stringByAppendingPathComponent:@"state"];
        NSString *lib = [root stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);
        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) { std::printf("  [FAIL] 核心启动失败\n"); return 1; }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        // ---- L1 后端契约基线：key= 才被接受，api_key= 是无效字段 ----
        NSDictionary *bad = [core jsonWithMethod:@"POST" path:@"/api/llm" body:@"api_key=sk-bad-only"];
        CK(bad && ![bad[@"ok"] boolValue],
           "L1a 只发 api_key= 被后端拒绝（证明原生旧写法从未保存成功）", bad.description ?: @"nil");
        NSDictionary *good = [core jsonWithMethod:@"POST" path:@"/api/llm" body:@"key=sk-test-123456"];
        CK(good && [good[@"ok"] boolValue], "L1b key= 被接受", good.description ?: @"nil");
        NSDictionary *st1 = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
        CK([st1[@"configured"] boolValue], "L1c key= 落盘后 configured=true", st1.description ?: @"nil");
        CK(st1[@"key"] == nil && [st1[@"masked"] isKindOfClass:[NSString class]],
           "L1d GET 只回掩码不回明文（红线）", @"");

        // ---- L2 保存端点不许动模型（用户故障①）----
        [core jsonWithMethod:@"POST" path:@"/api/llm" body:@"model=my-chosen-model"];
        NSDictionary *before = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
        CK([before[@"model"] isEqualToString:@"my-chosen-model"], "L2a 先设一个用户选的模型",
           before[@"model"] ?: @"nil");
        // 模拟 web llmSave：只发 base_url（+可选 key），**不带 model**
        [core jsonWithMethod:@"POST" path:@"/api/llm" body:@"base_url=https://api.example.com"];
        NSDictionary *after = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
        CK([after[@"model"] isEqualToString:@"my-chosen-model"],
           "L2b 只保存端点后模型保持不变（不被重置成默认）", after[@"model"] ?: @"nil");

        // ---- L3 原生保存路径必须与 web 同口径（真 UI 驱动）----
        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        [settings.view layoutSubtreeIfNeeded];
        [settings selectPane:@"meta"];
        [settings.view layoutSubtreeIfNeeded];
        [settings activate];
        Pump(0.8);

        // 先把模型设成用户选择，再点「保存端点」，模型必须不变。
        [core jsonWithMethod:@"POST" path:@"/api/llm" body:@"model=ui-chosen-model"];
        NSButton *saveBtn = (NSButton *)FindById(settings.view, @"llm.save");
        CK(saveBtn != nil, "L3a 保存端点按钮带 identifier（判据可驱动）", @"");
        NSTextField *baseField = (NSTextField *)FindById(settings.view, @"llm.base");
        CK(baseField != nil, "L3b 接口地址框带 identifier", @"");
        if (baseField) baseField.stringValue = @"https://api.another.com";
        if (saveBtn) { [saveBtn performClick:nil]; Pump(1.0); }
        NSDictionary *afterUi = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
        CK([afterUi[@"model"] isEqualToString:@"ui-chosen-model"],
           "L3c 点「保存端点」后模型不被重置（用户故障①已修）", afterUi[@"model"] ?: @"nil");
        CK([afterUi[@"baseUrl"] isEqualToString:@"https://api.another.com"],
           "L3d 接口地址确实保存了", afterUi[@"baseUrl"] ?: @"nil");

        // 密钥框填值 → 保存 → configured 必须为 true（用户故障②的根因）
        NSSecureTextField *keyField = (NSSecureTextField *)FindById(settings.view, @"llm.key");
        CK(keyField != nil, "L3e 密钥框带 identifier", @"");
        [core jsonWithMethod:@"POST" path:@"/api/llm" body:@"clear=1"];   // 先清掉，确保是 UI 存进去的
        NSDictionary *cleared = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
        CK(![cleared[@"configured"] boolValue], "L3f 先清空密钥（确保下面由 UI 存入）", @"");
        if (keyField) keyField.stringValue = @"sk-ui-saved-key";
        if (saveBtn) { [saveBtn performClick:nil]; Pump(1.0); }
        NSDictionary *afterKey = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
        CK([afterKey[@"configured"] boolValue],
           "L3g 点保存后密钥真的落盘（configured=true，测试连接才可能成功）",
           afterKey.description ?: @"nil");
        CK(keyField.stringValue.length == 0, "L3h 保存后密钥输入框清空（不留明文）", @"");

        // 手填模型回车必须能存（拉不到列表时这是唯一入口；web sp_llmmodeltext Enter 同口径）
        NSTextField *modelText = (NSTextField *)FindById(settings.view, @"llm.modeltext");
        CK(modelText != nil, "L3i 手填模型框带 identifier", @"");
        if (modelText) {
            modelText.stringValue = @"typed-model-x";
            [modelText sendAction:modelText.action to:modelText.target];
            Pump(0.8);
            NSDictionary *mt = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
            CK([mt[@"model"] isEqualToString:@"typed-model-x"],
               "L3j 手填模型回车后真的落盘", mt[@"model"] ?: @"nil");
        }

        // ---- L3.5 接口预设下拉（web sp_llmprovider：只填地址，不判连通）----
        NSView *presetView = FindById(settings.view, @"llm.provider");
        CK([presetView isKindOfClass:[NSPopUpButton class]], "L3k 有接口预设下拉", @"");
        if ([presetView isKindOfClass:[NSPopUpButton class]]) {
            NSPopUpButton *pp = (NSPopUpButton *)presetView;
            CK(pp.numberOfItems == 6, "L3l 六个预设（DeepSeek/OpenAI/OpenRouter/SiliconFlow/Ollama/自定义）",
               [NSString stringWithFormat:@"n=%ld", (long)pp.numberOfItems]);
            [pp selectItemAtIndex:1];   // OpenAI
            [pp sendAction:pp.action to:pp.target];
            CK([baseField.stringValue isEqualToString:@"https://api.openai.com/v1"],
               "L3m 选预设只填地址", baseField.stringValue ?: @"nil");
            // 自定义绝不覆盖用户已填地址
            baseField.stringValue = @"https://my-own.example.com";
            [pp selectItemAtIndex:5];
            [pp sendAction:pp.action to:pp.target];
            CK([baseField.stringValue isEqualToString:@"https://my-own.example.com"],
               "L3n 选「自定义」不覆盖已填地址", baseField.stringValue ?: @"nil");
        }

        // ---- L4 联网检索端点（用户故障③：fetch / search 选项缺失）----
        NSView *provPopup = FindById(settings.view, @"search.provider");
        NSView *searchBase = FindById(settings.view, @"search.base");
        NSView *searchKey = FindById(settings.view, @"search.key");
        NSView *searchSave = FindById(settings.view, @"search.save");
        NSView *searchClear = FindById(settings.view, @"search.clear");
        CK([provPopup isKindOfClass:[NSPopUpButton class]], "L4a 有检索端点下拉（search/fetch）", @"");
        CK(searchBase != nil, "L4b 有检索地址输入框", @"");
        CK([searchKey isKindOfClass:[NSSecureTextField class]], "L4c 检索 Key 是安全输入框", @"");
        CK(searchSave != nil, "L4d 有保存端点按钮", @"");
        CK(searchClear != nil, "L4e 有清除检索 Key 按钮", @"");
        if ([provPopup isKindOfClass:[NSPopUpButton class]]) {
            NSPopUpButton *p = (NSPopUpButton *)provPopup;
            // web SEARCH_PROVIDERS 三项：deepseek / anysearch / tavily
            CK(p.numberOfItems == 3, "L4f 三个检索端点选项（DeepSeek/AnySearch/Tavily）",
               [NSString stringWithFormat:@"n=%ld", (long)p.numberOfItems]);
        }
        // 真写：切 tavily + base + key → 读回
        if ([provPopup isKindOfClass:[NSPopUpButton class]]) {
            NSPopUpButton *p = (NSPopUpButton *)provPopup;
            [p selectItemAtIndex:2];   // tavily
            if ([searchBase isKindOfClass:[NSTextField class]])
                ((NSTextField *)searchBase).stringValue = @"https://api.tavily.com";
            if ([searchKey isKindOfClass:[NSTextField class]])
                ((NSTextField *)searchKey).stringValue = @"tvly-test-key";
            if ([searchSave isKindOfClass:[NSButton class]]) { [(NSButton *)searchSave performClick:nil]; Pump(1.0); }
            NSDictionary *s = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
            CK([s[@"searchProvider"] isEqualToString:@"tavily"], "L4g 检索端点切换落盘",
               s[@"searchProvider"] ?: @"nil");
            CK([s[@"searchBaseUrl"] isEqualToString:@"https://api.tavily.com"], "L4h 检索地址落盘",
               s[@"searchBaseUrl"] ?: @"nil");
            CK([s[@"searchMasked"] isKindOfClass:[NSString class]] && [s[@"searchMasked"] length] > 0,
               "L4i 检索 Key 落盘且只回掩码", s[@"searchMasked"] ?: @"nil");
            CK(s[@"searchKey"] == nil, "L4j GET 不回检索 Key 明文（红线）", @"");
            // 清除检索 Key
            if ([searchClear isKindOfClass:[NSButton class]]) { [(NSButton *)searchClear performClick:nil]; Pump(1.0); }
            NSDictionary *s2 = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
            CK(![s2[@"searchMasked"] length], "L4k 清除后检索 Key 掩码为空", s2[@"searchMasked"] ?: @"(空)");
            // 改端点不清 key：先存 key，再只改 provider
            if ([searchKey isKindOfClass:[NSTextField class]])
                ((NSTextField *)searchKey).stringValue = @"tvly-keep-me";
            if ([searchSave isKindOfClass:[NSButton class]]) { [(NSButton *)searchSave performClick:nil]; Pump(1.0); }
            [core jsonWithMethod:@"POST" path:@"/api/llm" body:@"search_provider=anysearch&search_base_url="];
            NSDictionary *s3 = [core jsonWithMethod:@"GET" path:@"/api/llm" body:nil];
            CK([s3[@"searchMasked"] length] > 0, "L4l 改端点不清检索 Key（keepPass 语义）", @"");
        }

        // ---- L5 GPU 后端（web 设置·通用页 sgroup('GPU') + /api/gpu 真实状态）----
        {
            [settings selectPane:@"adv"];
            [settings.view layoutSubtreeIfNeeded];
            [settings activate];
            Pump(0.8);
            NSView *gpuView = FindById(settings.view, @"gpu.vendor");
            CK([gpuView isKindOfClass:[NSPopUpButton class]], "L5a 有 GPU 后端下拉", @"");
            NSView *gpuMsg = FindById(settings.view, @"gpu.status");
            CK([gpuMsg isKindOfClass:[NSTextField class]], "L5b 有 GPU 真实状态行", @"");
            if ([gpuView isKindOfClass:[NSPopUpButton class]]) {
                NSPopUpButton *g = (NSPopUpButton *)gpuView;
                CK(g.numberOfItems == 3, "L5c 三项（自动/Apple Metal/关闭）",
                   [NSString stringWithFormat:@"n=%ld", (long)g.numberOfItems]);
                [g selectItemAtIndex:2];   // off
                [g sendAction:g.action to:g.target];
                Pump(0.8);
                NSDictionary *kv = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
                CK([kv[@"gpuvendor"] isEqualToString:@"off"], "L5d 选「关闭」落盘 gpuvendor=off",
                   kv[@"gpuvendor"] ?: @"nil");
                [g selectItemAtIndex:0];
                [g sendAction:g.action to:g.target];
                Pump(0.6);
                NSDictionary *kv2 = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
                CK([kv2[@"gpuvendor"] isEqualToString:@"auto"], "L5e 选「自动」落盘 gpuvendor=auto",
                   kv2[@"gpuvendor"] ?: @"nil");
            }
            // /api/gpu 真字段（metal 与 metalUsable 必须分开报）
            NSDictionary *gj = [core jsonWithMethod:@"GET" path:@"/api/gpu" body:nil];
            CK(gj[@"metal"] != nil && gj[@"metalUsable"] != nil,
               "L5f /api/gpu 分开报 metal 与 metalUsable（不把「文件在」说成「能用」）",
               gj.description ?: @"nil");
        }

        [core shutdown];
        [fm removeItemAtPath:root error:nil];
        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "llm_endpoint 全部通过" : "llm_endpoint 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}