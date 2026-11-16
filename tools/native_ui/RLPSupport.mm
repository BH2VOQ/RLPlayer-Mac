// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPSupport.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"

#include <atomic>
#include <cstdlib>

static NSString *gLang = @"zh";

NSString *RLPLanguage(void) { return gLang; }

void RLPSetLanguage(NSString *lang) {
    if ([lang isEqualToString:@"en"] || [lang isEqualToString:@"zh"]) gLang = [lang copy];
    else gLang = @"zh";
}

/// state 目录口径必须与后端 read_conf_value 一致（src/net/ui_page.h）：
///   ① RLPLAYER_STATE_DIR（测试/独立实例）；② ~/Library/Application Support/RLPlayer
///   （= platform/macos/path_posix.h 的 config_dir_utf8()）。
static NSString *RLPSettingsConfPath(void) {
    const char *env = std::getenv("RLPLAYER_STATE_DIR");
    NSString *dir = (env && *env)
        ? [NSString stringWithUTF8String:env]
        : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/RLPlayer"];
    return [dir stringByAppendingPathComponent:@"rlplayer-settings.conf"];
}

NSString * _Nullable RLPLanguageFromConf(void) {
    NSString *text = [NSString stringWithContentsOfFile:RLPSettingsConfPath()
                                               encoding:NSUTF8StringEncoding error:NULL];
    if (!text.length) return nil;
    // 与后端 read_conf_value 的口径一致：按 '=' 切成键/值，两侧去空格与 Tab，值转小写。
    NSCharacterSet *ws = [NSCharacterSet characterSetWithCharactersInString:@" \t"];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        if (![key isEqualToString:@"lang"]) continue;
        return [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws].lowercaseString;
    }
    return nil;
}

void RLPApplyLanguageFromConf(void) {
    // nil / 非法值 ⟹ RLPSetLanguage 回落 zh（空 state 目录不能把界面卡在英文）。
    RLPSetLanguage(RLPLanguageFromConf());
}

NSString *RLPTr(NSString *zh) {
    if (!zh.length || ![gLang isEqualToString:@"en"]) return zh;
    // 词表由 tools/gen_native_i18n.py 生成（RLPNativeI18n.mm）；未生成时函数返回 nil ⟹ 回落中文。
    extern NSDictionary * _Nullable RLPNativeI18nTable(void);
    NSDictionary *table = RLPNativeI18nTable();
    NSString *en = table[zh];
    return en.length ? en : zh;
}

NSString *RLPFmtDuration(double seconds) {
    if (!(seconds > 0) || !isfinite(seconds)) seconds = 0;
    long total = lround(seconds);
    long h = total / 3600, m = (total % 3600) / 60, s = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, s];
    return [NSString stringWithFormat:@"%ld:%02ld", m, s];
}

NSString *RLPFmtBytes(double bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%.0f B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    if (bytes < 1024.0 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024)];
    return [NSString stringWithFormat:@"%.2f GB", bytes / (1024.0 * 1024 * 1024)];
}

NSString *RLPEnc(NSString *s) {
    // Web uses encodeURIComponent, not URLQueryAllowedCharacterSet. The latter
    // leaves &, +, =, ? and / intact, corrupting form fields and filenames.
    static NSCharacterSet *componentSafe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ componentSafe = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"]; });
    return [(s ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:componentSafe] ?: @"";
}

#pragma mark - 封面缓存

@implementation RLPCoverLoader {
    NSCache<NSString *, NSImage *> *_cache;
    dispatch_queue_t _loadQueue;
}
+ (instancetype)shared {
    static RLPCoverLoader *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RLPCoverLoader alloc] init]; });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) {
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 500;
        _loadQueue = dispatch_queue_create("rlplayer.native.covers", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}
- (nullable NSImage *)cachedCoverForAlbumKey:(NSString *)key {
    return key.length ? [_cache objectForKey:key] : nil;
}
- (void)coverForAlbumKey:(NSString *)key completion:(void (^)(NSImage * _Nullable))completion {
    if (!key.length) { if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); }); return; }
    NSImage *hit = [_cache objectForKey:key];
    if (hit) { if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(hit); }); return; }
    NSString *path = [NSString stringWithFormat:@"/api/lib/cover?k=%@", RLPEnc(key)];
    [[RLPCoreClient shared] getData:path completion:^(NSData * _Nullable data) {
        NSImage *img = data.length ? [[NSImage alloc] initWithData:data] : nil;
        if (img) [self->_cache setObject:img forKey:key];
        if (completion) completion(img);
    }];
}
- (void)coverForSourceId:(NSString *)coverId completion:(void (^)(NSImage * _Nullable))completion {
    if (!coverId.length) { if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); }); return; }
    NSString *key = [@"src:" stringByAppendingString:coverId];
    NSImage *hit = [_cache objectForKey:key];
    if (hit) { if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(hit); }); return; }
    NSString *path = [NSString stringWithFormat:@"/api/src/cover?id=%@", RLPEnc(coverId)];
    [[RLPCoreClient shared] getData:path completion:^(NSData * _Nullable data) {
        NSImage *img = data.length ? [[NSImage alloc] initWithData:data] : nil;
        if (img) [self->_cache setObject:img forKey:key];
        if (completion) completion(img);
    }];
}
@end

#pragma mark - 轻提示

void RLPToast(NSString *message) {
    if (!message.length) return;
    // 取窗口的兜底顺序：key → main → 任何带 contentView 的可见窗口 → 任何窗口。
    // 只有前两级的话，「应用不在前台 / 离屏审计（窗口没有 orderFront）」时轻提示会被**静默丢掉** ——
    // 用户看不到反馈，判据也抓不到（本仓库用离屏审计验 toast 文案时就踩到）。
    NSWindow *win = NSApp.keyWindow ?: NSApp.mainWindow;
    if (!win) {
        for (NSWindow *w in NSApp.windows) if (w.isVisible && w.contentView) { win = w; break; }
    }
    if (!win) for (NSWindow *w in NSApp.windows) if (w.contentView) { win = w; break; }
    if (!win) return;
    RLPTheme *t = [RLPTheme current];
    NSTextField *label = [NSTextField labelWithString:RLPTr(message)];
    label.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    label.textColor = t.text;
    [label sizeToFit];
    const CGFloat padX = 14, padY = 8;
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, label.frame.size.width + padX * 2, label.frame.size.height + padY * 2)];
    box.wantsLayer = YES;
    box.identifier = @"rlp.toast";     // 判据/审计按 identifier 找，不靠文案匹配（文案会本地化）
    box.layer.backgroundColor = [t.bg2 colorWithAlphaComponent:0.96].CGColor;
    box.layer.cornerRadius = 9;
    box.layer.borderWidth = 1;
    box.layer.borderColor = t.line.CGColor;
    label.frame = NSMakeRect(padX, padY, label.frame.size.width, label.frame.size.height);
    [box addSubview:label];
    NSView *content = win.contentView;
    box.frame = NSMakeRect((content.bounds.size.width - box.frame.size.width) / 2,
                           content.bounds.size.height - box.frame.size.height - 96,
                           box.frame.size.width, box.frame.size.height);
    box.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:box];
    box.alphaValue = 0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.12;
        box.animator.alphaValue = 1;
    } completionHandler:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.25;
            box.animator.alphaValue = 0;
        } completionHandler:^{ [box removeFromSuperview]; }];
    });
}

void RLPAlert(NSString *title, NSString *message) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = RLPTr(title);
    a.informativeText = RLPTr(message);
    [a addButtonWithTitle:RLPTr(@"好")];
    [a runModal];
}

NSString *RLPAskText(NSString *title, NSString *okTitle, NSString *value,
                     NSString *placeholder, NSString *hint) {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = RLPTr(title);
    // web askText 的 hint 在输入框下方；NSAlert 只有 informativeText 一个位置，
    // 放这里与 web 的视觉层级一致（标题 → 输入 → 说明 → 按钮）。
    if (hint.length) a.informativeText = RLPTr(hint);
    // 按钮顺序：web 是 [取消][创建]，mac 惯例把主操作放右边；NSAlert 第一个按钮在右边 ⟹
    // 先加 okTitle。判据只看"两个按钮都在、主按钮是 okTitle"。
    [a addButtonWithTitle:RLPTr(okTitle)];
    [a addButtonWithTitle:RLPTr(@"取消")];
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    tf.stringValue = value ?: @"";
    tf.placeholderString = RLPTr(placeholder ?: @"");
    a.accessoryView = tf;
    a.window.initialFirstResponder = tf;   // 打开即可输入（web 同：输入框自动聚焦）
    if ([a runModal] != NSAlertFirstButtonReturn) return nil;
    NSString *v = [tf.stringValue stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return v.length ? v : nil;
}

#pragma mark - 封面视图（object-fit: cover）

@implementation RLPCoverImageView

- (void)setImage:(NSImage *)image {
    [super setImage:image];
    self.needsDisplay = YES;   // layer-backed 的视图也要重画（Cover 会被复用）
}

// 不用 NSImageView 默认的 letterbox 绘制，按 web `object-fit:cover`：等比放大铺满，
// 超出的部分裁掉（由上层 layer 的 masksToBounds / cornerRadius 负责裁切）。
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSImage *img = self.image;
    if (!img || img.size.width <= 0 || img.size.height <= 0) return;
    NSRect b = self.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return;
    NSSize is = img.size;
    CGFloat scale = MAX(b.size.width / is.width, b.size.height / is.height);
    NSSize ds = NSMakeSize(is.width * scale, is.height * scale);
    NSRect dst = NSMakeRect(NSMidX(b) - ds.width / 2.0, NSMidY(b) - ds.height / 2.0,
                            ds.width, ds.height);
    [img drawInRect:dst fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
             fraction:1.0 respectFlipped:YES hints:nil];
}

@end

#pragma mark - 内层滚动转发（整页滚动）

@implementation RLPForwardingScrollView

- (void)scrollWheel:(NSEvent *)event {
    BOOL canV = self.documentView.frame.size.height > self.contentView.bounds.size.height + 0.5;
    BOOL canH = self.documentView.frame.size.width > self.contentView.bounds.size.width + 0.5;
    CGFloat dx = fabs(event.scrollingDeltaX), dy = fabs(event.scrollingDeltaY);
    BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    BOOL wantsH = shift || dx > dy;
    BOOL scrollable = wantsH ? canH : canV;
    if (!scrollable) {
        // 自己滚不动 ⟹ 顺着响应者链交给外层页面滚动（不能吞掉事件）。
        [(NSView *)self.nextResponder scrollWheel:event];
        return;
    }
    [super scrollWheel:event];
}

@end

#pragma mark - 行悬停底色

@implementation RLPHoverRowView {
    NSTrackingArea *_hoverArea;
    BOOL _hovered;
}

- (BOOL)hoveredForAudit { return _hovered; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea) { [self removeTrackingArea:_hoverArea]; _hoverArea = nil; }
    _hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                              options:(NSTrackingMouseEnteredAndExited |
                                                       NSTrackingActiveInKeyWindow |
                                                       NSTrackingInVisibleRect)
                                                owner:self userInfo:nil];
    [self addTrackingArea:_hoverArea];
}

- (void)mouseEntered:(NSEvent *)event { (void)event; [self setHoveredForAudit:YES]; }
- (void)mouseExited:(NSEvent *)event { (void)event; [self setHoveredForAudit:NO]; }

- (void)setHoveredForAudit:(BOOL)hovered {
    if (_hovered == hovered) return;
    _hovered = hovered;
    self.needsDisplay = YES;
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    [super drawBackgroundInRect:dirtyRect];
    // 悬停底色画在选中态之下：选中行由 NSTableView 自己画高亮，不抢它。
    if (!_hovered || self.selected || !self.hoverColor) return;
    [self.hoverColor setFill];
    NSRectFill(dirtyRect);
}

@end

NSButton *RLPSymbolButton(NSString *symbol, NSString *tooltip, id target, SEL action) {
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tooltip];
    b.contentTintColor = [RLPTheme current].text;
    b.toolTip = RLPTr(tooltip);
    if (target && action) { b.target = target; b.action = action; }
    return b;
}

NSTextField *RLPLabel(NSString *text, NSFont *font, NSColor *color) {
    // nil 必须挡在这里：+[NSTextField labelWithString:] 传 nil 会抛
    // NSInternalInconsistencyException（"stringValue != nil"）直接崩进程。
    // 触发场景很自然——比如空态文案来自后端字段、某个分支里写成了 nil。
    // 一个 UI 辅助函数不该因为少判一次 nil 就把整个 app 带走，所以统一归零成空串。
    NSString *safe = text ?: @"";
    NSTextField *l = [NSTextField labelWithString:RLPTr(safe)];
    l.font = font;
    l.textColor = color;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.maximumNumberOfLines = 1;
    return l;
}

#pragma mark - 卡片式弹层

NSViewController *RLPCardController(NSView *card, CGFloat width, CGFloat minHeight) {
    NSViewController *vc = [[NSViewController alloc] initWithNibName:nil bundle:nil];
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, minHeight)];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [root.widthAnchor constraintEqualToConstant:width],
        [root.heightAnchor constraintGreaterThanOrEqualToConstant:minHeight],
        [card.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:14],
        [card.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-14],
        [card.topAnchor constraintEqualToAnchor:root.topAnchor constant:14],
        [card.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-14],
    ]];
    vc.view = root;
    return vc;
}

NSPopover *RLPShowCardPopover(NSView *anchorView, NSViewController *content, CGFloat width) {
    if (!anchorView || !content) return nil;
    (void)width;   // 宽度由 content 自己的约束决定（RLPCardController 已钉）
    NSPopover *p = [[NSPopover alloc] init];
    p.behavior = NSPopoverBehaviorTransient;      // 点外面自动关，符合"卡片弹层"心智
    p.animates = YES;
    p.contentViewController = content;
    [p showRelativeToRect:anchorView.bounds ofView:anchorView preferredEdge:NSRectEdgeMaxY];
    return p;
}

#pragma mark - 导航

NSNotificationName const RLPOpenAlbumNotification = @"RLPOpenAlbumNotification";
NSNotificationName const RLPOpenArtistNotification = @"RLPOpenArtistNotification";
NSNotificationName const RLPBackNotification = @"RLPBackNotification";

void RLPRequestOpenAlbum(NSString *albumKey) {
    if (!albumKey.length) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPOpenAlbumNotification object:albumKey];
}
void RLPRequestOpenArtist(NSString *artistName) {
    if (!artistName.length) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPOpenArtistNotification object:artistName];
}
void RLPRequestBack(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:RLPBackNotification object:nil];
}

#pragma mark - 播放动作

void RLPPostJSON(NSString *path, NSString *body) {
    [[RLPCoreClient shared] postJSON:path body:body ?: @"" completion:nil];
}

static void RLPPostPlaybackAction(NSString *path, NSString * _Nullable body) {
    [[RLPCoreClient shared] postJSON:path body:body ?: @"" completion:^(NSDictionary * _Nullable json) {
        (void)json;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RLPPlaybackActionCompletedNotification" object:nil];
    }];
}

void RLPPlayPath(NSString *path) {
    if (!path.length) return;
    RLPPostPlaybackAction(@"/api/play", [NSString stringWithFormat:@"file=%@", RLPEnc(path)]);
}

/// CUE 分轨播放：与 web `playPath(file, cs, ce)` 同一条后端契约（POST /api/play
/// body `file=&cs=&ce=`）。cs<0 或 ce<=cs 时按整轨处理，不编造区间。
void RLPPlayPathCue(NSString *path, double cs, double ce) {
    if (!path.length) return;
    NSMutableString *body = [NSMutableString stringWithFormat:@"file=%@", RLPEnc(path)];
    if (cs >= 0) [body appendFormat:@"&cs=%.3f", cs];
    if (ce > cs) [body appendFormat:@"&ce=%.3f", ce];
    RLPPostPlaybackAction(@"/api/play", body);
}

void RLPPlaybackToggle(BOOL playing, BOOL paused, NSString *currentPath) {
    if (playing && !paused) { RLPPostPlaybackAction(@"/api/pause?on=1", nil); return; }
    if (paused) { RLPPostPlaybackAction(@"/api/pause?on=0", nil); return; }
    // 已停止：与 web playOrPause 相同 —— 只发 /api/pause?on=0 是 no-op（本轮用户报过的原话）。
    if (currentPath.length) { RLPPlayPath(currentPath); return; }
    RLPToast(RLPTr(@"队列是空的"));
}

void RLPPlaybackPauseExplicit(void) {
    RLPPostPlaybackAction(@"/api/pause?on=1", nil);
}

void RLPPlaybackResumeOrReplay(BOOL playing, BOOL paused, NSString *currentPath) {
    if (playing && !paused) return;              // 已在播：playCommand 等幂，不打断
    if (paused) { RLPPostPlaybackAction(@"/api/pause?on=0", nil); return; }
    if (currentPath.length) { RLPPlayPath(currentPath); return; }
}

void RLPPlayAlbum(NSString *albumKey, NSInteger startIndex) {
    if (!albumKey.length) return;
    RLPPostPlaybackAction(@"/api/lib/play", [NSString stringWithFormat:@"k=%@&i=%ld", RLPEnc(albumKey), (long)startIndex]);
}

void RLPEnqueuePath(NSString *path) {
    if (!path.length) return;
    RLPPostJSON(@"/api/add", [NSString stringWithFormat:@"file=%@", RLPEnc(path)]);
}

static std::atomic<uint64_t> gWholeListGen{0};

static void RLPEnsureSequentialModeIf(BOOL (^ _Nullable shouldContinue)(void), void (^ _Nullable then)(void)) {
    [[RLPCoreClient shared] getJSON:@"/api/playmode" completion:^(NSDictionary * _Nullable modeJson) {
        if (shouldContinue && !shouldContinue()) return;
        NSInteger mode = [modeJson[@"mode"] respondsToSelector:@selector(integerValue)]
                       ? [modeJson[@"mode"] integerValue] : 0;
        if (mode == 2) {
            [[RLPCoreClient shared] postJSON:@"/api/playmode?mode=1" body:nil
                                  completion:^(NSDictionary * _Nullable ignored) {
                (void)ignored;
                if (shouldContinue && !shouldContinue()) return;
                if (then) then();
            }];
        } else if (then) {
            then();
        }
    }];
}

/// 建队列并从 start 起播（RLPPlayWholeListFrom 的后半段；独立函数避免 block 自捕循环引用）。
static void RLPSetQueueAndPlay(NSArray<NSString *> *clean, NSInteger i, uint64_t gen) {
    if (gen != gWholeListGen.load()) return;
    NSString *body = [NSString stringWithFormat:@"files=%@",
                      RLPEnc([clean componentsJoinedByString:@"\n"])];
    [[RLPCoreClient shared] postJSON:@"/api/queue/set" body:body
                          completion:^(NSDictionary * _Nullable j) {
        if (gen != gWholeListGen.load()) return;
        if (!j || [j[@"ok"] boolValue] == NO) {
            NSString *err = [j[@"error"] isKindOfClass:[NSString class]] ? j[@"error"] : RLPTr(@"建立队列失败");
            RLPToast(err);
            return;
        }
        RLPPlayPath(clean[(NSUInteger)i]);
    }];
}

void RLPPlayWholeListFrom(NSArray<NSString *> *files, NSInteger start) {
    if (!files.count) return;
    // 过滤空串（web playWholeListFrom 的 filter），夹取 start 到合法范围。
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *f in files) if ([f isKindOfClass:[NSString class]] && f.length) [clean addObject:f];
    if (!clean.count) return;
    NSInteger i = start;
    if (i < 0) i = 0;
    if (i >= (NSInteger)clean.count) i = (NSInteger)clean.count - 1;

    // 单曲循环（mode=2）会让"播放整列"卡在第一首：先读当前模式，是 2 就切回列表循环 1。
    // 读到 mode 之前不盲目写，避免把用户的随机/顺序设置也改掉。
    // 每次发起整列播放递增 generation，后续每一段异步回调都校验最新意图，防止旧流程覆盖新流程。
    const uint64_t gen = ++gWholeListGen;
    RLPEnsureSequentialModeIf(^BOOL { return gen == gWholeListGen.load(); }, ^{
        RLPSetQueueAndPlay(clean, i, gen);
    });
}

void RLPEnsureSequentialMode(void (^then)(void)) {
    RLPEnsureSequentialModeIf(nil, then);
}


#pragma mark - 古典作品判定（web npIsClassical / npGuessComposer / npWorkTarget）

static NSString *RLPNPMetaStr(NSDictionary *meta, NSString *key) {
    id v = meta[key];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : @"";
}
static BOOL RLPNPRegex(NSString *pattern, NSString *text) {
    if (!text.length) return NO;
    static NSMutableDictionary<NSString *, NSRegularExpression *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSRegularExpression *re = cache[pattern];
    if (!re) {
        re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:NULL];
        if (!re) return NO;
        cache[pattern] = re;
    }
    return [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}
static NSString *RLPNPTrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

BOOL RLPNPIsClassical(NSDictionary *meta) {
    if (![meta isKindOfClass:[NSDictionary class]]) return NO;
    // ① 后端直接给了 composer ⟹ 就是古典（web 同一优先级）
    if (RLPNPTrim(RLPNPMetaStr(meta, @"composer")).length) return YES;
    NSString *genre = RLPNPMetaStr(meta, @"genre");
    NSString *album = RLPNPMetaStr(meta, @"album");
    NSString *title = RLPNPMetaStr(meta, @"title");
    // ② 风格/流派命中（classical / 古典 / 巴洛克 / opera …）
    if (RLPNPRegex(@"classical|古典|classique|baroque|巴洛克|opera|オペラ", genre)) return YES;
    // ③ 专辑名带「古典」
    if ([album rangeOfString:@"古典"].location != NSNotFound) return YES;
    // ④ 专辑名 + 曲名的体裁特征兜底（Symphony / Concerto / 奏鸣曲 / 交响 ……）
    NSString *both = [NSString stringWithFormat:@"%@ %@", album, title];
    return RLPNPRegex(@"symphon|concerto|sonata|caprice|capriccio|nocturne|prelude|overture|"
                      @"string quartet|requiem|mass in|opus\\s*\\d|op\\.\\s*\\d+|kv\\.?\\s*\\d+|"
                      @"bwv\\s*\\d+|symphonie|konzert|奏鸣曲|交响|协奏|练习曲|夜曲|前奏曲|序曲|组曲|"
                      @"安魂曲|作品\\s*\\d+", both);
}

NSString *RLPNPGuessComposer(NSDictionary *meta) {
    if (![meta isKindOfClass:[NSDictionary class]]) return @"";
    NSString *c = RLPNPTrim(RLPNPMetaStr(meta, @"composer"));
    if (c.length) return c;
    NSString *album = RLPNPMetaStr(meta, @"album");
    NSString *title = RLPNPMetaStr(meta, @"title");
    // ① 曲名末尾括号：(Tchaikovsky) / (Beethoven) —— 只认拉丁字母的名字
    if (title.length) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"\\(([A-Z][A-Za-z\\u00c0-\\u024f.' -]{2,40})\\)\\s*$" options:0 error:NULL];
        NSTextCheckingResult *m = [re firstMatchInString:title options:0
                                                   range:NSMakeRange(0, title.length)];
        if (m && m.numberOfRanges > 1) {
            NSString *g = RLPNPTrim([title substringWithRange:[m rangeAtIndex:1]]);
            if (g.length) return g;
        }
    }
    // ② 专辑名冒号前缀：「Beethoven: Symphony No. 5」→ Beethoven（最多 3 个词、纯拉丁）
    NSRange colon = [album rangeOfString:@":"];
    if (colon.location != NSNotFound && colon.location > 1) {
        NSString *pre = RLPNPTrim([album substringToIndex:colon.location]);
        NSArray<NSString *> *words = [pre componentsSeparatedByCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        NSUInteger n = 0;
        for (NSString *w in words) if (w.length) ++n;
        if (pre.length && n <= 3 && RLPNPRegex(@"^[A-Za-z\\u00c0-\\u024f.' -]+$", pre)) return pre;
    }
    return @"";
}

NSDictionary<NSString *, NSString *> *RLPNPWorkTarget(NSDictionary *meta) {
    NSString *t = RLPNPMetaStr(meta, @"title");
    // 在线补全有时把曲名写成「原文 (中文译名)」；Discogs 要用原文 ⟹ 去掉末尾 CJK 括号译名。
    if (t.length) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"^(.*?)\\s*[（(]([^()（）]*)[）)]\\s*$" options:0 error:NULL];
        NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
        if (m && m.numberOfRanges > 2) {
            NSString *g1 = RLPNPTrim([t substringWithRange:[m rangeAtIndex:1]]);
            NSString *g2 = [t substringWithRange:[m rangeAtIndex:2]];
            if (g1.length && RLPNPRegex(@"[\\u4e00-\\u9fff]", g2)) t = g1;
        }
    }
    return @{ @"title": t ?: @"", @"composer": RLPNPGuessComposer(meta) ?: @"" };
}

/// v3.3.11 `parseTransportM3u` 的 macOS/POSIX 适配（上游 `m3uWindowsPath` 是
/// Windows 反斜杠路径，macOS 分支必须换成 POSIX；CUE / BOM / 注释 / 拒绝规则逐条照搬）。
/// 返回 @{@"items": @[路径(\tcs\tce)], @"needsFolder": @(BOOL)}；非法歌单返回 nil。
NSDictionary<NSString *, id> *RLPParseM3U(NSString *text, NSString *folder) {
    if (!text) return nil;
    NSString *s = text;
    if ([s hasPrefix:@"\uFEFF"]) s = [s substringFromIndex:1];       // BOM
    NSArray *lines = [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    NSString *cue = nil;
    BOOL needsFolder = NO;
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) continue;
        // 控制字符（换行已分行）→ 拒绝，与上游 /[\u0000-\u001f]/ 同义。
        for (NSUInteger i = 0; i < line.length; ++i)
            if ([line characterAtIndex:i] < 0x20) return nil;
        if ([line.uppercaseString hasPrefix:@"#EXT-X-"]) return nil;   // HLS 不是本地歌单
        if ([line.lowercaseString hasPrefix:@"#rta-cue"]) {
            NSMutableArray<NSString *> *pp = [NSMutableArray array];
            for (NSString *x in [line componentsSeparatedByCharactersInSet:
                                 [NSCharacterSet whitespaceCharacterSet]]) if (x.length) [pp addObject:x];
            double a = 0, b = 0;
            if (pp.count != 3 || cue ||
                ![[NSScanner scannerWithString:pp[1]] scanDouble:&a] ||
                ![[NSScanner scannerWithString:pp[2]] scanDouble:&b] ||
                a < 0 || (b != -1 && b <= a)) return nil;
            cue = [NSString stringWithFormat:@"\t%@\t%@", pp[1], pp[2]];
            continue;
        }
        if ([line hasPrefix:@"#"]) continue;                            // 注释
        NSString *path = line;
        if ([path.lowercaseString hasPrefix:@"file:"]) {                // file:// URL → 路径
            NSURL *u = [NSURL URLWithString:path];
            if (!u || u.query.length || u.fragment.length) return nil;
            path = u.path ?: @"";
        }
        if (![path hasPrefix:@"/"]) {
            if (folder.length) path = [folder stringByAppendingPathComponent:path];
            else needsFolder = YES;                                       // 需追问文件夹
        }
        if (folder.length || [path hasPrefix:@"/"])
            path = [path stringByStandardizingPath];                    // 处理 .. / .
        [items addObject:[NSString stringWithFormat:@"%@%@", path, cue ?: @""]];
        cue = nil;
    }
    if (!items.count || cue) return nil;                                // 空歌单 / 孤立 CUE
    return @{ @"items": items, @"needsFolder": @(needsFolder) };
}

// ---- v3.3.11 静音/恢复的唯一状态 ----
static double gVolumeRestoreDb = NAN;   // NAN = web volumeRestore === null

double RLPVolumeMuteNextDb(double currentDb) {
    if (!isfinite(currentDb)) currentDb = -120.0;
    if (currentDb <= -120.0) {
        if (isnan(gVolumeRestoreDb)) return NAN;   // 上游：无恢复值直接 return，不发请求
        const double restored = gVolumeRestoreDb;
        gVolumeRestoreDb = NAN;
        return restored;
    }
    gVolumeRestoreDb = currentDb;
    return -120.0;
}

BOOL RLPVolumeMuteHasRestore(void) { return !isnan(gVolumeRestoreDb); }

void RLPVolumeMuteReset(void) { gVolumeRestoreDb = NAN; }

NSNotificationName const RLPSettingsChangedNotification = @"RLPSettingsChangedNotification";

NSInteger RLPParseDsdRate(id _Nullable raw) {
    NSString *s = [raw isKindOfClass:[NSString class]] ? (NSString *)raw
                : ([raw respondsToSelector:@selector(stringValue)] ? [raw stringValue] : @"");
    s = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (!s.length || [s isEqualToString:@"0"]) return 0;
    if ([s hasPrefix:@"native"]) s = [s substringFromIndex:6];
    else if ([s hasPrefix:@"nat"]) s = [s substringFromIndex:3];
    else if ([s hasPrefix:@"dop"]) s = [s substringFromIndex:3];
    // Keep legacy 1024 readable, but never accept a partial numeric prefix.
    for (NSNumber *rate in @[@64, @128, @256, @512, @1024]) {
        if ([s isEqualToString:rate.stringValue]) return rate.integerValue;
    }
    return 0;
}

BOOL RLPTextFieldIsEditing(NSTextField * _Nullable tf) {
    if (!tf || !tf.window) return NO;
    NSText *fe = tf.currentEditor;
    return (fe != nil && tf.window.firstResponder == fe);
}
