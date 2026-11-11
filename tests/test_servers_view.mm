// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_servers_view.mm — 流媒体服务器管理的真链路判据（2026-11-12 对齐 web SRC 区块）
//
// 触发原因：原生设置·流媒体页此前**只读**（交接单 §2.2 挂账），web 版能增删改/启用/测试。
// 离线判据抓不到"写了没落盘"，所以这里起真核心（隔离目录、backend=null、不出声）：
//   S1 表单骨架在位（添加按钮 + 名称/类型/地址/用户/密码 + 保存/测试/取消）
//   S2 校验与 web srcSave 同口径（地址必填、http(s) 前缀、用户名必填）
//   S3 add → GET 读回（含 kind/base/user，密码不回明文）
//   S4 update 留空密码 = 保持原密码（后端 keepPass 语义）
//   S5 active 切换 → 读回 active 标记
//   S6 remove → 读回消失
//   S7 设置·流媒体页真的嵌了管理视图（不是只读文本）
#import <AppKit/AppKit.h>
#import "RLPServersView.h"
#import "RLPMetaSourcesView.h"
#import "RLPLibStatsView.h"
#import "RLPSettingsViewController.h"
#import "RLPCoreClient.h"
#import "RLPSupport.h"

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
/// 主线程 runloop 转一会儿，等异步回调落地。
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
        std::printf("=== test_servers_view（真核心 · 隔离目录 · 不出声）===\n");

        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-servers-%d", (int)getpid()]];
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

        // ---- S1 表单骨架 ----
        RLPServersView *sv = [[RLPServersView alloc] initWithFrame:NSMakeRect(0, 0, 640, 400)];
        [sv layoutSubtreeIfNeeded];
        CK(FindById(sv, @"srv.add") != nil, "S1a 有「添加服务器」按钮", @"");
        // 点开表单（新增态）
        NSButton *add = (NSButton *)FindById(sv, @"srv.add");
        [add performClick:nil];
        for (NSString *ident in @[ @"srv.form.name", @"srv.form.kind", @"srv.form.base",
                                   @"srv.form.user", @"srv.form.pass", @"srv.form.save",
                                   @"srv.form.test", @"srv.form.cancel" ]) {
            CK(FindById(sv, ident) != nil,
               [[NSString stringWithFormat:@"S1b 表单含 %@", ident] UTF8String], @"缺失");
        }
        NSView *form = FindById(sv, @"srv.form");
        CK(form && !form.isHidden, "S1c 点添加后表单展开", @"");
        NSSecureTextField *pass = (NSSecureTextField *)FindById(sv, @"srv.form.pass");
        CK([pass isKindOfClass:[NSSecureTextField class]], "S1d 密码是安全输入框", @"");

        // ---- S2 校验（与 web srcSave 同口径）----
        // 用 KVC 取私有校验方法会脆；改为直接驱动保存按钮看 formMsg。
        NSTextField *base = (NSTextField *)FindById(sv, @"srv.form.base");
        NSTextField *user = (NSTextField *)FindById(sv, @"srv.form.user");
        NSTextField *msg = (NSTextField *)FindById(sv, @"srv.form.msg");
        NSButton *save = (NSButton *)FindById(sv, @"srv.form.save");
        base.stringValue = @""; user.stringValue = @"u";
        [save performClick:nil];
        CK([msg.stringValue isEqualToString:RLPTr(@"请填写服务器地址")],
           "S2a 空地址被拦（与 web 同文案）", msg.stringValue ?: @"nil");
        base.stringValue = @"ftp://x"; user.stringValue = @"u";
        [save performClick:nil];
        CK([msg.stringValue isEqualToString:RLPTr(@"地址要以 http:// 或 https:// 开头")],
           "S2b 非 http(s) 地址被拦", msg.stringValue ?: @"nil");
        base.stringValue = @"https://x"; user.stringValue = @"";
        [save performClick:nil];
        CK([msg.stringValue isEqualToString:RLPTr(@"请填写用户名")],
           "S2c 空用户名被拦", msg.stringValue ?: @"nil");

        // ---- S3 add → 读回 ----
        base.stringValue = @"https://music.example.com";
        user.stringValue = @"alice";
        pass.stringValue = @"secret-pass";
        NSTextField *name = (NSTextField *)FindById(sv, @"srv.form.name");
        name.stringValue = @"测试服";
        [save performClick:nil];
        Pump(0.8);
        NSDictionary *cfg = [core jsonWithMethod:@"GET" path:@"/api/src/config" body:nil];
        NSArray *servers = [cfg[@"servers"] isKindOfClass:[NSArray class]] ? cfg[@"servers"] : @[];
        CK(servers.count == 1, "S3a add 后读回 1 台",
           [NSString stringWithFormat:@"n=%lu", (unsigned long)servers.count]);
        NSDictionary *s0 = servers.firstObject;
        CK([s0[@"base"] isEqualToString:@"https://music.example.com"], "S3b base 落盘", s0[@"base"] ?: @"nil");
        CK([s0[@"user"] isEqualToString:@"alice"], "S3c user 落盘", s0[@"user"] ?: @"nil");
        CK([s0[@"hasPass"] boolValue], "S3d 密码已存（hasPass=true）", @"");
        CK(s0[@"pass"] == nil, "S3e GET 不回密码明文（红线）", @"");
        CK(form.isHidden, "S3f 保存成功后表单收起", @"");
        NSString *sid = [s0[@"id"] isKindOfClass:[NSString class]] ? s0[@"id"] : @"";
        CK(sid.length > 0, "S3g 拿到服务器 id", @"");

        // ---- S4 update：留空密码 = 保持原密码 ----
        // 直接走后端契约（UI 的 update 路径与 add 共用 formBody，这里钉后端语义 + UI 编辑回填）。
        [core jsonWithMethod:@"POST" path:@"/api/src/config"
                        body:[NSString stringWithFormat:@"action=update&id=%@&kind=subsonic&name=%@&base=%@&user=%@&pass=",
                              RLPEnc(sid), RLPEnc(@"改名服"), RLPEnc(@"https://music.example.com"), RLPEnc(@"alice")]];
        NSDictionary *cfg2 = [core jsonWithMethod:@"GET" path:@"/api/src/config" body:nil];
        NSArray *ss2 = cfg2[@"servers"];
        NSDictionary *u0 = ss2.firstObject;
        CK([u0[@"name"] isEqualToString:@"改名服"], "S4a update 改名落盘", u0[@"name"] ?: @"nil");
        CK([u0[@"hasPass"] boolValue], "S4b 留空密码后原密码仍在（keepPass）", @"");
        // UI 编辑态：密码框必须清空、占位符提示"留空 = 保持原密码"
        [sv reload]; Pump(0.6);
        NSButton *editBtn = nil;
        NSMutableArray<NSView *> *all = [NSMutableArray array];
        CollectViews(sv, all);
        for (NSView *v in all)
            if ([v isKindOfClass:[NSButton class]] && [v.identifier isEqualToString:sid] &&
                [((NSButton *)v).title isEqualToString:RLPTr(@"编辑")]) editBtn = (NSButton *)v;
        CK(editBtn != nil, "S4c 列表行有「编辑」按钮", @"");
        [editBtn performClick:nil];
        CK([pass.stringValue isEqualToString:@""], "S4d 编辑时密码框不回填", pass.stringValue ?: @"nil");
        CK([pass.placeholderString isEqualToString:RLPTr(@"留空 = 保持原密码")],
           "S4e 编辑时密码占位符提示保持原密码", pass.placeholderString ?: @"nil");
        NSButton *cancel = (NSButton *)FindById(sv, @"srv.form.cancel");
        [cancel performClick:nil];

        // ---- S5 active ----
        [core jsonWithMethod:@"POST" path:@"/api/src/config"
                        body:[@"action=active&id=" stringByAppendingString:RLPEnc(sid)]];
        NSDictionary *cfg3 = [core jsonWithMethod:@"GET" path:@"/api/src/config" body:nil];
        CK([cfg3[@"active"] isEqualToString:sid], "S5a active 切换落盘", cfg3[@"active"] ?: @"nil");

        // ---- S6 remove ----
        [core jsonWithMethod:@"POST" path:@"/api/src/config"
                        body:[@"action=remove&id=" stringByAppendingString:RLPEnc(sid)]];
        NSDictionary *cfg4 = [core jsonWithMethod:@"GET" path:@"/api/src/config" body:nil];
        NSArray *ss4 = [cfg4[@"servers"] isKindOfClass:[NSArray class]] ? cfg4[@"servers"] : @[];
        CK(ss4.count == 0, "S6a remove 后读回 0 台",
           [NSString stringWithFormat:@"n=%lu", (unsigned long)ss4.count]);

        // ---- S7 设置·流媒体页嵌了管理视图 ----
        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        // 先触发 loadView（App 里 addSubview 时才建视图树）；paneHost 未建时 selectPane 会崩。
        [settings.view layoutSubtreeIfNeeded];
        [settings selectPane:@"stream"];
        [settings.view layoutSubtreeIfNeeded];
        NSMutableArray<NSView *> *sall = [NSMutableArray array];
        CollectViews(settings.view, sall);
        BOOL hasServersView = NO;
        for (NSView *v in sall) if ([v isKindOfClass:[RLPServersView class]]) hasServersView = YES;
        CK(hasServersView, "S7 设置·流媒体页嵌入服务器管理视图（不再只读）", @"");

        // ---- S8 标签写回：忙态/轮询骨架（对齐 web WB_BUSY/wbPoll/wbSyncBusy）----
        // 旧实现没有 wbPoll/wbSyncBusy，执行后不轮询、按钮不禁用 —— 这里钉住方法在位。
        [settings selectPane:@"adv"];
        [settings.view layoutSubtreeIfNeeded];
        CK([settings respondsToSelector:@selector(wbPoll)], "S8a 有写回轮询（wbPoll）", @"");
        CK([settings respondsToSelector:@selector(wbSyncBusy)], "S8b 进页同步在跑状态（wbSyncBusy）", @"");
        NSMutableArray<NSView *> *aall = [NSMutableArray array];
        CollectViews(settings.view, aall);
        NSButton *dry = nil, *apply = nil;
        for (NSView *v in aall) {
            if (![v isKindOfClass:[NSButton class]]) continue;
            if ([v.identifier isEqualToString:@"wb.dry"]) dry = (NSButton *)v;
            if ([v.identifier isEqualToString:@"wb.apply"]) apply = (NSButton *)v;
        }
        CK(dry != nil && apply != nil, "S8c 预览/执行按钮带标识（忙态要禁用它们）", @"");
        // 空 MetaBase 下预览：必须走 writable/skipped 口径（旧实现读不存在的 count/note）。
        if (dry) {
            [dry performClick:nil];
            Pump(1.0);
            NSMutableArray<NSView *> *aall2 = [NSMutableArray array];
            CollectViews(settings.view, aall2);
            NSTextField *wbMsg = nil;
            for (NSView *v in aall2) {
                if (![v isKindOfClass:[NSTextField class]]) continue;
                NSString *s = ((NSTextField *)v).stringValue;
                if ([s rangeOfString:RLPTr(@"首可写")].location != NSNotFound ||
                    [s rangeOfString:RLPTr(@"预览失败")].location != NSNotFound) wbMsg = (NSTextField *)v;
            }
            CK(wbMsg != nil, "S8d 预览结果用「N 首可写，M 首跳过」口径（或如实报错）",
               wbMsg.stringValue ?: @"未找到结果文案");
            CK(dry.enabled && apply.enabled, "S8e 预览结束后按钮恢复可用", @"");
        }

        // ---- S9 元数据数据源：动态注册表 + 优先级排序（对齐 web sp_metasrc）----
        // 旧实现只有 4 个固定开关，没有逐源开关/排序。这里钉住真核心读注册表 + 写后读回。
        {
            RLPMetaSourcesView *mv = [[RLPMetaSourcesView alloc] initWithFrame:NSMakeRect(0, 0, 640, 300)];
            [mv layoutSubtreeIfNeeded];
            [mv reload];
            Pump(0.8);
            NSMutableArray<NSView *> *mall = [NSMutableArray array];
            CollectViews(mv, mall);
            NSInteger switches = 0, rows = 0;
            NSButton *reset = nil;
            for (NSView *v in mall) {
                if ([v isKindOfClass:[NSSwitch class]]) ++switches;
                if ([v.identifier hasPrefix:@"metasrc.row."]) ++rows;
                if ([v.identifier isEqualToString:@"metasrc.reset"]) reset = (NSButton *)v;
            }
            // 后端注册表至少有几个源（qq/netease/…）；逐源开关数 == 行数 == 注册表大小。
            NSDictionary *prov = [core jsonWithMethod:@"GET" path:@"/api/providers" body:nil];
            NSArray *pitems = [prov[@"items"] isKindOfClass:[NSArray class]] ? prov[@"items"] : @[];
            CK(pitems.count > 0, "S9a 后端注册表非空",
               [NSString stringWithFormat:@"n=%lu", (unsigned long)pitems.count]);
            CK(rows == (NSInteger)pitems.count, "S9b 逐源行数 == 注册表大小（动态渲染）",
               [NSString stringWithFormat:@"rows=%ld want=%lu", (long)rows, (unsigned long)pitems.count]);
            CK(switches == (NSInteger)pitems.count, "S9c 每源一个开关",
               [NSString stringWithFormat:@"switches=%ld", (long)switches]);
            CK(reset != nil, "S9d 有「恢复默认」按钮", @"");

            // 关掉第一个源 → 读回 metasrc_<id>=0
            NSString *firstId = [pitems.firstObject[@"id"] isKindOfClass:[NSString class]] ? pitems.firstObject[@"id"] : @"";
            NSSwitch *firstSw = nil;
            for (NSView *v in mall)
                if ([v isKindOfClass:[NSSwitch class]] && [v.identifier isEqualToString:firstId]) firstSw = (NSSwitch *)v;
            CK(firstSw != nil, "S9e 找到第一源开关", firstId);
            if (firstSw) {
                // performClick 会自己翻转 state 并触发 action；不要预先设 state（否则会翻回去）。
                // 注册表默认 on=1 ⟹ 点一下变 off。
                [firstSw performClick:nil];
                Pump(0.6);
                NSDictionary *kv = [core jsonWithMethod:@"GET" path:@"/api/settings" body:nil][@"kv"];
                NSString *key = [@"metasrc_" stringByAppendingString:firstId];
                CK([kv[key] isEqualToString:@"0"], "S9f 关源后 metasrc_<id>=0 落盘",
                   [NSString stringWithFormat:@"%@=%@", key, kv[key] ?: @"nil"]);
            }

            // 设置·元数据页真的嵌了数据源视图
            [settings selectPane:@"meta"];
            [settings.view layoutSubtreeIfNeeded];
            NSMutableArray<NSView *> *metaAll = [NSMutableArray array];
            CollectViews(settings.view, metaAll);
            BOOL hasMetaSources = NO;
            for (NSView *v in metaAll) if ([v isKindOfClass:[RLPMetaSourcesView class]]) hasMetaSources = YES;
            CK(hasMetaSources, "S9g 设置·元数据页嵌入数据源视图（不再只有固定开关）", @"");

            // ---- S10 AI 模型下拉（对齐 web llmModelRender：拉不到降级手填、不崩）----
            // 旧实现只有手填框、没有 /api/llm/models 下拉。这里钉住控件在位 + 降级路径可跑。
            NSView *popup = nil, *refresh = nil, *modelMsg = nil;
            for (NSView *v in metaAll) {
                if ([v.identifier isEqualToString:@"llm.modelpopup"]) popup = v;
                if ([v.identifier isEqualToString:@"llm.modelrefresh"]) refresh = v;
                if ([v.identifier isEqualToString:@"llm.modelmsg"]) modelMsg = v;
            }
            CK([popup isKindOfClass:[NSPopUpButton class]], "S10a 模型下拉控件在位", @"");
            CK([refresh isKindOfClass:[NSButton class]], "S10b 有刷新模型列表按钮", @"");
            CK([modelMsg isKindOfClass:[NSTextField class]], "S10c 有模型列表状态文案", @"");
            // 未配置 key 时 /api/llm/models 会 ok:false；降级路径必须隐藏下拉、保留手填。
            [settings loadLlmModels:NO];
            Pump(1.0);
            CK(popup.isHidden == YES, "S10d 拉不到列表时下拉隐藏（降级手填，不崩）",
               @"下拉仍显示");
            NSTextField *mm = (NSTextField *)modelMsg;
            CK(mm.stringValue.length > 0, "S10e 降级时如实写出原因", mm.stringValue ?: @"空");
            // 手填框仍然可编辑（功能不因降级消失）。
            NSTextField *modelField = nil;
            for (NSView *v in metaAll)
                if ([v isKindOfClass:[NSTextField class]] &&
                    [((NSTextField *)v).placeholderString isEqualToString:@"deepseek-chat"])
                    modelField = (NSTextField *)v;
            CK(modelField != nil && modelField.isEditable, "S10f 降级时手填模型框仍可用", @"");
        }

        // ---- S11 本地音乐库统计卡（对齐 web sp_libstats / renderLibStats）----
        // 旧原生设置·高级页只有"音乐目录/扫描"按钮，没有曲目/专辑/线程/上次扫描数字。
        {
            // 后端真值：夹具曲库已被核心读到（本测试启动核心时为空库，写一条再读）。
            NSDictionary *stats = [core jsonWithMethod:@"GET" path:@"/api/lib/stats" body:nil];
            CK([stats[@"ok"] boolValue] && [stats[@"tracks"] respondsToSelector:@selector(integerValue)],
               "S11a /api/lib/stats 返回真字段", stats.description ?: @"nil");

            // 设置·高级页嵌入统计卡，且卡内显示来自后端的数字。
            [settings selectPane:@"adv"];
            [settings.view layoutSubtreeIfNeeded];
            [settings activate];   // 触发 reloadData，统计卡拉真值
            Pump(0.8);
            NSMutableArray<NSView *> *advAll = [NSMutableArray array];
            CollectViews(settings.view, advAll);
            RLPLibStatsView *statsView = nil;
            for (NSView *v in advAll) if ([v isKindOfClass:[RLPLibStatsView class]]) statsView = (RLPLibStatsView *)v;
            CK(statsView != nil, "S11b 设置·高级页嵌入曲库统计卡", @"");
            if (statsView) {
                // 卡里至少 4 行（曲目/专辑/扫描线程/上次扫描），值不是占位"—"或空。
                NSMutableArray<NSView *> *inner = [NSMutableArray array];
                CollectViews(statsView, inner);
                NSInteger valueLabels = 0;
                BOOL hasRealNumber = NO;
                for (NSView *v in inner) {
                    if (![v isKindOfClass:[NSTextField class]]) continue;
                    NSString *s = ((NSTextField *)v).stringValue;
                    if (!s.length) continue;
                    ++valueLabels;
                    if ([s rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound &&
                        ![s isEqualToString:@"—"]) hasRealNumber = YES;
                }
                CK(valueLabels >= 4, "S11c 统计卡有 >= 4 行数字/标签",
                   [NSString stringWithFormat:@"labels=%ld", (long)valueLabels]);
                CK(hasRealNumber, "S11d 统计卡显示来自后端的真实数字（不是全占位）", @"");
            }
        }

        // ---- S12 整列顺序播放（对齐 web playWholeListFrom / /api/queue/set）----
        // 旧原生最爱页双击只播单曲。这里验证：给定路径列表 → 队列被建立为整列。
        {
            NSArray<NSString *> *list = @[
                @"/music/a.flac", @"/music/b.flac", @"/music/c.flac"
            ];
            // 起播会用 backend=null（夹具已设），不会出声；RlpPlayWholeListFrom 先读 playmode。
            RLPPlayWholeListFrom(list, 1);
            Pump(1.0);
            NSDictionary *q = [core jsonWithMethod:@"GET" path:@"/api/queue?meta=1" body:nil];
            NSArray *items = [q[@"items"] isKindOfClass:[NSArray class]] ? q[@"items"] : @[];
            CK(items.count == 3, "S12a /api/queue/set 用整列建立了队列（3 首）",
               [NSString stringWithFormat:@"n=%lu", (unsigned long)items.count]);
            // 队列里第 2 首应是 b.flac（items 是路径字符串数组，顺序保持）。
            NSString *second = items.count >= 2 && [items[1] isKindOfClass:[NSString class]] ? items[1] : nil;
            CK([second containsString:@"b.flac"], "S12b 队列顺序与传入列表一致", second ?: @"nil");
            // 空列表/越界 start 不崩、不建空队列（防御分支）。
            NSUInteger before = items.count;
            RLPPlayWholeListFrom(@[], 0);
            RLPPlayWholeListFrom(list, 99);   // 越界夹到最后一首
            Pump(0.6);
            NSDictionary *q2 = [core jsonWithMethod:@"GET" path:@"/api/queue?meta=1" body:nil];
            NSArray *items2 = [q2[@"items"] isKindOfClass:[NSArray class]] ? q2[@"items"] : @[];
            CK(items2.count == before, "S12c 空列表不发建队列请求（越界 start 被夹取仍建整列）",
               [NSString stringWithFormat:@"before=%lu after=%lu", (unsigned long)before, (unsigned long)items2.count]);
        }

        [core shutdown];
        [fm removeItemAtPath:root error:nil];
        std::printf("\n%s（%d 项失败）\n", gFail == 0 ? "servers_view 全部通过" : "servers_view 有失败", gFail);
        return gFail == 0 ? 0 : 1;
    }
}