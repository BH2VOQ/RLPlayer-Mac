// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// test_native_settings_cards.mm — 设置页「卡片外散落控件」系统性判据（task-3 A/B）
//
// ============================ 这条判据在证明什么 ============================
// 用户 2026-11-13 的 7 张截图指出：原生设置页的卡片只画了标题/说明，真正的控件
// 被直接 add 到页面级 stack ⟹ 卡片外散落一套控件（输入页整套采集控件重复出现、
// 输出页发现/重新发现/空的声道微调块、流媒体页全部文字、元数据页模型与按钮…）。
//
// 判据不是「看截图顺眼」，而是**结构**：
//   ① 逐页遍历全部 10 个设置页签；
//   ② 页面里每一个控件（按钮 / 下拉 / 开关 / 输入框 / 文本域 / 滑杆 / 进度条）
//      都必须能找到**同一个卡片容器（RLPSettingsGroup）作为祖先** —— 不是与卡片并列的兄弟；
//   ③ 页面层不得存在孤立控件（直接挂在页签 stack / scroll document 上的控件）；
//   ④ 每张卡片必须有真实的卡体内容（标题条 + 空卡体 = 用户截图里的空灰块）；
//   ⑤ 点名页逐项归位：输入（不再重复一套采集控件）、输出（UPnP 发现控件在「输出后端」卡、
//      「声道音量微调」里有按声道数生成的真实控件）、流媒体（服务器/投放都在各自卡片里）、
//      元数据（AI 接入 / 联网检索端点两组控件都在各自卡）、诊断（导出/更新/反馈）。
//   ⑧ U12（2026-11-16）：SDM 拐点准入提示（sp_sdmcorner_note）—— 文案必须由
//      GET /api/settings 的 sdm 对象驱动（admitted=false → 后端 note 原文；合法 → 收起）。
//
// 红→绿：旧码 ④③② 大面积红（卡片空壳 + 页面并列控件），改完必须全绿。
// 证据：evidence/native-3-settings-cards-red.log / -green.log；离屏截图 RLP_SETTINGS_SNAP_DIR。
//
// 纪律：隔离 state/library；backend=null、volume=-120；**不播放任何音频**（铁律②）。
#import <AppKit/AppKit.h>
#import "RLPCoreClient.h"
#import "RLPSupport.h"
#import "RLPSettingsViewController.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

static int gFail = 0, gPass = 0;
static void Ck(BOOL ok, NSString *what, NSString *detail) {
    if (ok) { ++gPass; std::printf("  [PASS] %s\n", what.UTF8String); }
    else {
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
static BOOL IsCard(NSView *v) {
    return v && [NSStringFromClass(v.class) isEqualToString:@"RLPSettingsGroup"];
}
static NSView *CardFor(NSView *v) {
    for (NSView *p = v.superview; p; p = p.superview) if (IsCard(p)) return p;
    return nil;
}
static NSArray<NSView *> *CardsIn(NSView *pane) {
    NSMutableArray<NSView *> *a = [NSMutableArray array];
    for (NSView *v in Descendants(pane)) if (IsCard(v)) [a addObject:v];
    return a;
}
static NSString *CardTitle(NSView *card) {
    NSView *head = FindId(card, @"set.group.head");
    if (!head) return @"";
    for (NSView *s in head.subviews)
        if ([s isKindOfClass:[NSTextField class]]) return ((NSTextField *)s).stringValue;
    return @"";
}
static NSView *CardTitled(NSArray<NSView *> *cards, NSString *title) {
    for (NSView *c in cards) if ([CardTitle(c) containsString:title]) return c;
    return nil;
}
/// 卡片体内的真实项数（set.group.body = RLPFieldGrid）。
static NSInteger CardBodyItems(NSView *card) {
    NSView *body = FindId(card, @"set.group.body");
    return body ? (NSInteger)body.subviews.count : 0;
}
static NSRect VisRectIn(NSView *sub, NSView *container) {
    NSRect r = [sub convertRect:sub.bounds toView:container];
    if (!container.isFlipped) r.origin.y = container.bounds.size.height - NSMaxY(r);
    return r;
}
static NSArray<NSTextField *> *CardNotesIn(NSView *card) {
    NSMutableArray<NSTextField *> *out = [NSMutableArray array];
    for (NSView *sub in Descendants(card)) {
        if ([sub isKindOfClass:[NSTextField class]] && [sub.identifier isEqualToString:@"set.note"]) {
            [out addObject:(NSTextField *)sub];
        }
    }
    return out;
}
static CGFloat SingleLineHeightForFont(NSFont *font) {
    NSTextField *probe = RLPLabel(@"Ag", font ?: [NSFont systemFontOfSize:11], NSColor.labelColor);
    return ceil(probe.intrinsicContentSize.height);
}
static BOOL IsControl(NSView *v) {
    return [v isKindOfClass:[NSButton class]] ||      // 含 NSSwitch / NSPopUpButton
           [v isKindOfClass:[NSTextField class]] ||
           [v isKindOfClass:[NSTextView class]] ||
           [v isKindOfClass:[NSSlider class]] ||
           [v isKindOfClass:[NSProgressIndicator class]] ||
           [v isKindOfClass:[NSSegmentedControl class]];
}
/// 页签根视图（identifier = tab.<key>）。
static NSView *PaneRoot(NSView *root, NSString *key) {
    NSString *ident = [@"tab." stringByAppendingString:key];
    return FindId(root, ident);
}
static void Snap(NSView *pane, NSString *dir, NSString *name) {
    if (!dir.length || !pane) return;
    NSView *stack = pane;
    if ([pane isKindOfClass:[NSScrollView class]]) stack = ((NSScrollView *)pane).documentView ?: pane;
    [stack layoutSubtreeIfNeeded];
    NSRect b = stack.bounds;
    if (b.size.width < 40 || b.size.height < 40) return;
    NSBitmapImageRep *rep = [stack bitmapImageRepForCachingDisplayInRect:b];
    [stack cacheDisplayInRect:b toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [dir stringByAppendingPathComponent:name];
    [png writeToFile:path atomically:YES];
}

int main() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        std::printf("=== test_native_settings_cards（task-3 A/B · 逐页结构判据 · 不出声）===\n");

        NSString *rootDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"rlp-cards-%d", (int)getpid()]];
        NSString *state = [rootDir stringByAppendingPathComponent:@"state"];
        NSString *lib = [rootDir stringByAppendingPathComponent:@"lib"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("RLPLAYER_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("RLPLAYER_LIBRARY_DIR", lib.fileSystemRepresentation, 1);
        RLPCoreClient *core = [RLPCoreClient shared];
        if (![core startEmbedded]) { std::printf("  [FAIL] 核心启动失败\n"); return 1; }
        [core jsonWithMethod:@"POST" path:@"/api/settings" body:@"backend=null&volume=-120"];

        RLPSettingsViewController *settings = [[RLPSettingsViewController alloc] init];
        NSView *v = settings.view;
        // 放进真实 NSWindow（不 orderFront，仍然离屏）：
        // 没有 window 时 NSScrollView/NSStackView 的 layout 不会真正解算，
        // 卡片 frame 恒为 0，任何"卡体 vs 内容"的几何判据都会变成恒真。
        NSWindow *hostWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 900)
                                                        styleMask:NSWindowStyleMaskBorderless
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
        hostWin.releasedWhenClosed = NO;
        hostWin.contentView = v;
        v.frame = NSMakeRect(0, 0, 1280, 900);
        [v layoutSubtreeIfNeeded];

        NSString *snapDir = nil;
        const char *snapEnv = getenv("RLP_SETTINGS_SNAP_DIR");
        if (snapEnv && *snapEnv) snapDir = [NSString stringWithUTF8String:snapEnv];

        // ---- ① 逐页遍历：页面层不得有孤立控件；卡片不得是空壳 ----
        NSArray<NSString *> *keys = @[ @"adv", @"in", @"out", @"pcm", @"sdm", @"eq",
                                       @"cal", @"meta", @"stream", @"diag" ];
        for (NSString *key in keys) {
            [settings selectPane:key];
            [v layoutSubtreeIfNeeded];
            Pump(0.45);
            [v layoutSubtreeIfNeeded];
            NSView *pane = PaneRoot(v, key);
            Ck(pane != nil, [NSString stringWithFormat:@"页签 %@ 存在根视图", key], @"找不到 tab.");
            if (!pane) continue;
            [pane layoutSubtreeIfNeeded];

            NSMutableArray<NSString *> *leaks = [NSMutableArray array];
            for (NSView *x in Descendants(pane)) {
                if (!IsControl(x)) continue;
                if (!CardFor(x)) {
                    NSString *desc = [NSString stringWithFormat:@"%@(%@)", x.className, x.identifier ?: @"-"];
                    if ([x isKindOfClass:[NSButton class]])
                        desc = [NSString stringWithFormat:@"%@(%@,\"%@\")", x.className,
                                x.identifier ?: @"-", ((NSButton *)x).title ?: @""];
                    if (leaks.count < 12) [leaks addObject:desc];
                }
            }
            Ck(leaks.count == 0, [NSString stringWithFormat:@"【%@】页面层不存在孤立控件（全部有卡片祖先）", key],
               [NSString stringWithFormat:@"leaks=%lu: %@", (unsigned long)leaks.count,
                [leaks componentsJoinedByString:@" | "]]);

            NSArray<NSView *> *cards = CardsIn(pane);
            NSMutableArray<NSString *> *emptyCards = [NSMutableArray array];
            for (NSView *card in cards) {
                if (CardBodyItems(card) < 1) {
                    NSString *t = CardTitle(card);
                    [emptyCards addObject:t.length ? t : @"(无标题)"];
                }
            }
            Ck(cards.count > 0, [NSString stringWithFormat:@"【%@】页面至少有卡片容器", key],
               @"cards=0");
            Ck(emptyCards.count == 0, [NSString stringWithFormat:@"【%@】每张卡片都有真实卡体内容（无空壳卡片）", key],
               [emptyCards componentsJoinedByString:@" | "]);

            if (snapDir) Snap(pane, snapDir, [NSString stringWithFormat:@"native-pane-%@.png", key]);
        }

        // ---- ② 元数据页（B）：展开高级选项，两组控件必须各自归卡 ----
        [settings selectPane:@"meta"];
        [v layoutSubtreeIfNeeded];
        Pump(0.3);
        NSButton *more = (NSButton *)FindId(PaneRoot(v, @"meta"), @"sp_metamore");
        Ck(more != nil, @"元数据页有「高级选项」按钮", @"sp_metamore 缺失");
        if (more) { [more performClick:nil]; Pump(0.35); [v layoutSubtreeIfNeeded]; }
        NSView *metaPane = PaneRoot(v, @"meta");
        NSArray<NSView *> *metaCards = CardsIn(metaPane);
        NSView *aiCard = CardTitled(metaCards, @"AI 接入");
        NSView *searchCard = CardTitled(metaCards, @"联网检索端点");
        Ck(aiCard != nil && searchCard != nil, @"元数据页有「AI 接入」与「联网检索端点」两张卡",
           [NSString stringWithFormat:@"ai=%d search=%d", !!aiCard, !!searchCard]);

        NSArray<NSString *> *aiIds = @[ @"llm.modelpopup", @"llm.modelrefresh", @"llm.modelmsg",
                                        @"llm.save", @"llm.test", @"llm.clear", @"llm.status",
                                        @"llm.provider", @"llm.base", @"llm.key" ];
        NSMutableArray<NSString *> *aiMissing = [NSMutableArray array];
        for (NSString *ident in aiIds) {
            NSView *x = FindId(metaPane, ident);
            if (!x || !aiCard || !CardFor(x) || CardFor(x) != aiCard) [aiMissing addObject:ident];
        }
        Ck(aiMissing.count == 0,
           @"【B】模型下拉/刷新/模型状态/保存端点/测试连通/清除密钥全部在「AI 接入」卡体内",
           [aiMissing componentsJoinedByString:@" | "]);

        NSArray<NSString *> *searchIds = @[ @"search.provider", @"search.base", @"search.key",
                                            @"search.save", @"search.clear", @"search.status" ];
        NSMutableArray<NSString *> *searchMissing = [NSMutableArray array];
        for (NSString *ident in searchIds) {
            NSView *x = FindId(metaPane, ident);
            if (!x || !searchCard || !CardFor(x) || CardFor(x) != searchCard) [searchMissing addObject:ident];
        }
        Ck(searchMissing.count == 0,
           @"【B】检索端点/地址/Key/保存端点/清除检索 Key/掩码状态全部在「联网检索端点」卡体内",
           [searchMissing componentsJoinedByString:@" | "]);
        // 标签写回继续留在 AI 卡（上一轮第12项，本轮不得回退）
        Ck(FindId(metaPane, @"sp_wbdry") && CardFor(FindId(metaPane, @"sp_wbdry")) == aiCard,
           @"标签写回的按钮仍在「AI 接入」卡体内（不回退）", @"sp_wbdry 不在 AI 卡");
        if (snapDir) Snap(metaPane, snapDir, @"native-pane-meta-advanced.png");

        // ---- ③ 输入页（A）：不得再出现第二套采集控件 ----
        [settings selectPane:@"in"];
        [v layoutSubtreeIfNeeded];
        Pump(0.4);
        NSView *inPane = PaneRoot(v, @"in");
        NSArray<NSView *> *inCards = CardsIn(inPane);
        NSInteger startButtons = 0;
        NSInteger backendPopups = 0;
        for (NSView *x in Descendants(inPane)) {
            if ([x isKindOfClass:[NSButton class]] &&
                [((NSButton *)x).title isEqualToString:RLPTr(@"开始采集")]) ++startButtons;
            if ([x isKindOfClass:[NSPopUpButton class]]) {
                NSPopUpButton *p = (NSPopUpButton *)x;
                if ([p indexOfItemWithTitle:@"none"] >= 0 &&
                    [p indexOfItemWithTitle:@"coreaudio"] >= 0) ++backendPopups;
            }
        }
        Ck(startButtons == 1, @"【A】输入页只有一套「开始采集」按钮（旧码卡片内外各一套）",
           [NSString stringWithFormat:@"count=%ld", (long)startButtons]);
        Ck(backendPopups == 1, @"【A】输入页只有一套输入后端下拉", 
           [NSString stringWithFormat:@"count=%ld", (long)backendPopups]);
        NSView *statusCard = CardTitled(inCards, @"采集实时状态");
        NSView *statRunning = FindId(inPane, @"sp_stat_running");
        Ck(statusCard && statRunning && CardFor(statRunning) == statusCard,
           @"【A】采集实时状态行在「采集实时状态」卡体内", @"sp_stat_running 归卡失败");
        NSView *startBtn = FindId(inPane, @"sp_instart");
        Ck(startBtn && CardFor(startBtn) != nil,
           @"【A】「开始采集 / 停止采集」按钮在输入卡片体内", @"sp_instart 无卡片祖先");

        // ---- ④ 输出页（A）：UPnP 发现控件归「输出后端」卡；声道微调必须有真实控件 ----
        [settings selectPane:@"out"];
        [v layoutSubtreeIfNeeded];
        Pump(0.4);
        NSView *outPane = PaneRoot(v, @"out");
        NSArray<NSView *> *outCards = CardsIn(outPane);
        NSView *outCard = CardTitled(outCards, @"输出后端");
        NSView *trimCard = CardTitled(outCards, @"声道音量微调");
        NSView *upnpDev = FindId(outPane, @"sp_upnp_dev");
        NSView *upnpScan = FindId(outPane, @"sp_upnp_scan");
        Ck(outCard && upnpDev && CardFor(upnpDev) == outCard && upnpScan && CardFor(upnpScan) == outCard,
           @"【A】UPnP 目标渲染器/重新发现在「输出后端」卡片体内",
           [NSString stringWithFormat:@"dev=%d scan=%d", !!upnpDev, !!upnpScan]);
        NSInteger trimCount = 0;
        for (NSString *ident in @[ @"sp_trim0", @"sp_trim1", @"sp_trim2", @"sp_trim3",
                                   @"sp_trim4", @"sp_trim5", @"sp_trim6", @"sp_trim7" ]) {
            NSView *x = FindId(outPane, ident);
            if (x) {
                ++trimCount;
                if (!trimCard || CardFor(x) != trimCard) {
                    Ck(NO, @"【A】声道微调控件必须在「声道音量微调」卡体内", ident);
                }
            }
        }
        Ck(trimCount == 2, @"【A】声道音量微调按 2 声道（跟随源默认）生成真实控件（旧码空块）",
           [NSString stringWithFormat:@"count=%ld", (long)trimCount]);
        Ck(FindId(outPane, @"sp_trimchmsg") && CardFor(FindId(outPane, @"sp_trimchmsg")) == trimCard,
           @"【A】声道说明行在「声道音量微调」卡体内", @"sp_trimchmsg 归卡失败");
        // 改成 6 声道后必须重建出 6 个真实控件（按输出声道数，不是写死）
        NSPopUpButton *chPopup = (NSPopUpButton *)FindId(outPane, @"sp_ch");
        if (chPopup) {
            [chPopup selectItemAtIndex:2];   // 5.1（6 声道）
            if ([settings respondsToSelector:@selector(onChannels:)])
                [settings performSelector:@selector(onChannels:) withObject:chPopup];
            Pump(0.35); [v layoutSubtreeIfNeeded];
            NSInteger n6 = 0;
            for (NSView *x in Descendants(outPane))
                if ([x.identifier isKindOfClass:[NSString class]] && [x.identifier hasPrefix:@"sp_trim"]
                    && ![x.identifier isEqualToString:@"sp_trimwrap"]
                    && ![x.identifier isEqualToString:@"sp_trimchmsg"]) ++n6;
            Ck(n6 >= 6, @"【A】输出声道数改成 5.1 后重建为 6 声道控件", 
               [NSString stringWithFormat:@"count=%ld", (long)n6]);
        }

        // ---- ⑤ 流媒体页（A） ----
        [settings selectPane:@"stream"];
        [v layoutSubtreeIfNeeded];
        Pump(0.4);
        NSView *streamPane = PaneRoot(v, @"stream");
        NSArray<NSView *> *streamCards = CardsIn(streamPane);
        NSView *srvCard = CardTitled(streamCards, @"流媒体服务器");
        NSView *castCard = CardTitled(streamCards, @"推送到设备");
        NSView *srvAdd = FindId(streamPane, @"srv.add");
        NSView *castDev = FindId(streamPane, @"sp_cast_dev");
        Ck(srvCard && srvAdd && CardFor(srvAdd) == srvCard,
           @"【A】「添加服务器」在「流媒体服务器」卡体内（旧码文字全在卡外）",
           @"srv.add 归卡失败");
        Ck(castCard && castDev && CardFor(castDev) == castCard,
           @"【A】投放设备/重新发现/实时状态在「推送到设备」卡体内",
           @"sp_cast_dev 归卡失败");

        // ---- ⑥ 诊断页（A） ----
        [settings selectPane:@"diag"];
        [v layoutSubtreeIfNeeded];
        Pump(0.4);
        NSView *diagPane = PaneRoot(v, @"diag");
        NSArray<NSView *> *diagCards = CardsIn(diagPane);
        NSView *diagCard = CardTitled(diagCards, @"导出诊断包");
        NSView *updCard = CardTitled(diagCards, @"软件更新");
        NSView *fbCard = CardTitled(diagCards, @"反馈问题");
        NSArray<NSString *> *diagIds = @[ @"sp_diagzip", @"sp_diagjson", @"sp_diagsummary", @"sp_diagmsg" ];
        for (NSString *ident in diagIds) {
            NSView *x = FindId(diagPane, ident);
            Ck(x && diagCard && CardFor(x) == diagCard,
               [NSString stringWithFormat:@"【A】%@ 在「导出诊断包」卡体内", ident], @"归卡失败");
        }
        NSArray<NSString *> *updIds = @[ @"sp_updchannel", @"sp_vercur", @"sp_updcheck",
                                         @"sp_updbeta", @"sp_updmsg", @"sp_updnote" ];
        for (NSString *ident in updIds) {
            NSView *x = FindId(diagPane, ident);
            Ck(x && updCard && CardFor(x) == updCard,
               [NSString stringWithFormat:@"【A】%@ 在「软件更新」卡体内", ident], @"归卡失败");
        }
        NSArray<NSString *> *fbIds = @[ @"sp_fbtext", @"sp_fbcount", @"sp_fbchan",
                                        @"sp_fbdiag", @"sp_fbpreview", @"sp_fbpreviewbox",
                                        @"sp_fbresult", @"sp_fbsend", @"sp_fbmsg" ];
        for (NSString *ident in fbIds) {
            NSView *x = FindId(diagPane, ident);
            Ck(x && fbCard && CardFor(x) == fbCard,
               [NSString stringWithFormat:@"【A】%@ 在「反馈问题」卡体内", ident], @"归卡失败");
        }
        // D 的前置：诊断摘要不得再有任何 JSON 面板 / 文本视图
        Ck(FindId(diagPane, @"sp_diagsummarytext") == nil && FindId(diagPane, @"sp_diagscroll") == nil,
           @"【D】诊断页不存在摘要 JSON 面板（sp_diagsummarytext / sp_diagscroll）", @"旧面板还在");
        if (snapDir) Snap(diagPane, snapDir, @"native-pane-diag.png");
        // 点预览后预览框按 ≥5 行伸展，且不与任何 set.note 说明行相交
        {
            NSButton *pvBtn = (NSButton *)FindId(diagPane, @"sp_fbpreview");
            NSTextField *pvBox = (NSTextField *)FindId(diagPane, @"sp_fbpreviewbox");
            if (pvBtn && pvBox && fbCard) {
                [pvBtn performClick:nil];
                Pump(0.15);
                [v layoutSubtreeIfNeeded];
                Pump(0.15);
                [v layoutSubtreeIfNeeded];
                const NSRect rPv = VisRectIn(pvBox, fbCard);
                const CGFloat lineH = SingleLineHeightForFont(pvBox.font);
                NSArray<NSTextField *> *notes = CardNotesIn(fbCard);
                std::printf("  [FRAMES cards_diag_preview] pv={x=%.1f,y=%.1f,w=%.1f,h=%.1f} lineH=%.1f notes=%lu\n",
                            rPv.origin.x, rPv.origin.y, rPv.size.width, rPv.size.height,
                            lineH, (unsigned long)notes.count);
                Ck(!pvBox.hidden && rPv.size.height >= 5.0 * lineH - 2.0,
                   @"【A】点「先看会发送什么」后 sp_fbpreviewbox 展平≥5行",
                   [NSString stringWithFormat:@"h=%.1f lineH=%.1f hidden=%d",
                    rPv.size.height, lineH, pvBox.hidden]);
                BOOL hitNote = NO;
                for (NSTextField *note in notes) {
                    const NSRect rN = VisRectIn(note, fbCard);
                    std::printf("    [FRAME note] {x=%.1f,y=%.1f,w=%.1f,h=%.1f}\n",
                                rN.origin.x, rN.origin.y, rN.size.width, rN.size.height);
                    if (NSIntersectsRect(rPv, rN)) hitNote = YES;
                }
                Ck(!hitNote && notes.count >= 2,
                   @"【A】sp_fbpreviewbox 与反馈卡片底部说明行两两不相交",
                   [NSString stringWithFormat:@"hitNote=%d notes=%lu", hitNote, (unsigned long)notes.count]);
            } else {
                Ck(NO, @"【A】反馈预览框与卡片存在", @"缺 sp_fbpreview / sp_fbpreviewbox / fbCard");
            }
        }

        // ---- ⑦ 其余页签的结构兜底（逐页已遍历，这里补各自的点名控件） ----
        [settings selectPane:@"adv"];
        [v layoutSubtreeIfNeeded];
        Pump(0.3);
        NSView *advPane = PaneRoot(v, @"adv");
        NSArray<NSView *> *advCards = CardsIn(advPane);
        for (NSString *ident in @[ @"sp_gpumsg", @"sp_libstats", @"sp_netbtn", @"sp_netmsg" ]) {
            NSView *x = FindId(advPane, ident);
            Ck(x && CardFor(x) != nil, [NSString stringWithFormat:@"【A】%@ 在卡片体内", ident], @"无卡片祖先");
        }
        [settings selectPane:@"pcm"];
        [v layoutSubtreeIfNeeded];
        Pump(0.3);
        Ck(CardFor(FindId(PaneRoot(v, @"pcm"), @"sp_phasemsg")) != nil,
           @"【A】PCM 相位说明在卡片体内", @"sp_phasemsg 无卡片祖先");
        [settings selectPane:@"sdm"];
        [v layoutSubtreeIfNeeded];
        Pump(0.3);
        Ck(CardFor(FindId(PaneRoot(v, @"sdm"), @"sp_dsdmsg")) != nil &&
           CardFor(FindId(PaneRoot(v, @"sdm"), @"sp_dsdmodenote")) != nil,
           @"【A】SDM 说明行都在卡片体内", @"缺卡片祖先");
        // ---- ⑧ U12（2026-11-16）：1-bit SDM 拐点准入提示必须由 GET 的 sdm 对象驱动 ----
        // 判据不是"控件存在"（那只能证明 parity），而是"后端判不合格时它真的显示后端给的文案"：
        //   ① 把 conf 直接写成不合法组合（dsd=64 / dsd 族 / 20 kHz）。为什么不用 POST 造：
        //      保存闸门已经会 422 拒绝 —— 这正是本轮新增的闸门，所以只能改文件模拟历史配置；
        //   ② GET 的 sdm.admitted=false、note 带稳定子串与 100 kHz 出路 ⟹ 控件可见且文案含 note；
        //   ③ 换回合法组合（100 kHz）⟹ 提示收起（不是"永远挂一条红字"）。
        {
            NSString *confPath = [state stringByAppendingPathComponent:@"rlplayer-settings.conf"];
            NSData *origConf = [NSData dataWithContentsOfFile:confPath];
            NSString *badConf = @"backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n"
                                 "dsd=64\nmodfamily=dsd\nmodcut=20\n";
            [badConf writeToFile:confPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [settings reloadData];
            Pump(1.0);
            [settings selectPane:@"sdm"];
            [v layoutSubtreeIfNeeded];
            Pump(0.4);
            [v layoutSubtreeIfNeeded];
            NSTextField *cornerNote = (NSTextField *)FindId(PaneRoot(v, @"sdm"), @"sp_sdmcorner_note");
            Ck(cornerNote != nil, @"【U12】SDM 页存在 sp_sdmcorner_note 提示控件", @"控件缺失");
            Ck(cornerNote != nil && !cornerNote.hidden,
               @"【U12】后端 admitted=false 时提示控件可见",
               cornerNote.hidden ? @"hidden" : @"");
            Ck([cornerNote.stringValue containsString:@"SDM_CORNER_QUALITY"] &&
               [cornerNote.stringValue containsString:@"100 kHz"],
               @"【U12】提示文案来自后端 sdm.note（稳定子串 + 100 kHz 出路；前端不写死阈值）",
               cornerNote.stringValue ?: @"nil");
            NSString *goodConf = @"backend=null\nvolume=-120\nscanonstartup=0\nmetaon=0\nmetallm=0\n"
                                  "dsd=64\nmodfamily=dsd\nmodcut=100\n";
            [goodConf writeToFile:confPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [settings reloadData];
            Pump(1.0);
            [v layoutSubtreeIfNeeded];
            Ck(cornerNote != nil && cornerNote.hidden,
               @"【U12】拐点合法（100 kHz）时提示收起",
               cornerNote.hidden ? @"" : (cornerNote.stringValue ?: @""));
            // 恢复原始 conf：本测试只借用这一小段状态，不改后续用例的环境。
            if (origConf) [origConf writeToFile:confPath atomically:YES];
            else [[NSFileManager defaultManager] removeItemAtPath:confPath error:nil];
            [settings reloadData];
            Pump(0.8);
        }

        [settings selectPane:@"eq"];
        [v layoutSubtreeIfNeeded];
        Pump(0.3);
        NSView *eqPane = PaneRoot(v, @"eq");
        Ck(CardFor(FindId(eqPane, @"eq.fader")) != nil &&
           CardFor(FindId(eqPane, @"peqBypass")) != nil &&
           CardFor(FindId(eqPane, @"opra.query")) != nil,
           @"【A】EQ 页全部控件在卡片体内（旧码整页无卡片）", @"EQ 控件无卡片祖先");
        [settings selectPane:@"cal"];
        [v layoutSubtreeIfNeeded];
        Pump(0.3);
        NSView *calPane = PaneRoot(v, @"cal");
        Ck(CardsIn(calPane).count > 0, @"【A】声音校准页有卡片容器", @"cards=0");
        if (snapDir) Snap(eqPane, snapDir, @"native-pane-eq.png");
        if (snapDir) Snap(calPane, snapDir, @"native-pane-cal.png");

        // ---- 【E】校准卡不得在标题下方留大片空白（本轮实测 130pt）----
        //
        // 现象：设置·声音校准页「房间校正」卡里，标题下方空出约 130pt 纯空白。
        // 根因：calView 的高度是**建卡那一刻**按 preferredContentHeight 定死的常量
        // （当时算成 450），而首次显示时实际内容只要 320；且 fillCalibration 只在
        // 首次建 pane 时跑，重进校准页用的是缓存 pane，高度再没机会重算。
        // 判据直接量：calView 高度 - 其内部可见控件的最低点 ≤ 24pt。
        {
            [settings selectPane:@"cal"];
            NSView *pane = PaneRoot(v, @"cal");
            NSView *doc = [pane isKindOfClass:[NSScrollView class]] ? ((NSScrollView *)pane).documentView : pane;
            [doc layoutSubtreeIfNeeded];
            [pane layoutSubtreeIfNeeded];
            Pump(0.4);
            [doc layoutSubtreeIfNeeded];

            NSView *cal = nil;
            for (NSView *d in Descendants(pane)) {
                if ([NSStringFromClass(d.class) isEqualToString:@"RLPCalibrationView"]) { cal = d; break; }
            }
            Ck(cal != nil, @"【E】声音校准页能定位到校准视图", @"找不到 RLPCalibrationView");
            if (cal) {
                CGFloat maxBottom = 0;
                for (NSView *d in Descendants(cal)) {
                    if (d == cal || d.isHiddenOrHasHiddenAncestor) continue;
                    if (!IsControl(d)) continue;
                    const NSRect r = [d convertRect:d.bounds toView:cal];
                    maxBottom = MAX(maxBottom, NSMaxY(r));
                }
                const CGFloat slack = NSHeight(cal.bounds) - maxBottom;
                Ck(slack <= 24.0,
                   @"【E】校准卡内没有大片空白（视图高 - 内容底 ≤ 24pt）",
                   [NSString stringWithFormat:@"calH=%.0f content=%.0f slack=%.0f",
                    NSHeight(cal.bounds), maxBottom, slack]);
            }
        }

        std::printf("结果：%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
