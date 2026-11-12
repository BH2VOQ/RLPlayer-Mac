// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import "RLPSupport.h"
#import "RLPCoreClient.h"
#import "RLPTheme.h"

static NSString *gLang = @"zh";

NSString *RLPLanguage(void) { return gLang; }

void RLPSetLanguage(NSString *lang) {
    if ([lang isEqualToString:@"en"] || [lang isEqualToString:@"zh"]) gLang = [lang copy];
    else gLang = @"zh";
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

void RLPPlayPath(NSString *path) {
    if (!path.length) return;
    RLPPostJSON(@"/api/play", [NSString stringWithFormat:@"file=%@", RLPEnc(path)]);
}

void RLPPlayAlbum(NSString *albumKey, NSInteger startIndex) {
    if (!albumKey.length) return;
    RLPPostJSON(@"/api/lib/play", [NSString stringWithFormat:@"k=%@&i=%ld", RLPEnc(albumKey), (long)startIndex]);
}

void RLPEnqueuePath(NSString *path) {
    if (!path.length) return;
    RLPPostJSON(@"/api/add", [NSString stringWithFormat:@"file=%@", RLPEnc(path)]);
}

/// 建队列并从 start 起播（RLPPlayWholeListFrom 的后半段；独立函数避免 block 自捕循环引用）。
static void RLPSetQueueAndPlay(NSArray<NSString *> *clean, NSInteger i) {
    NSString *body = [NSString stringWithFormat:@"files=%@",
                      RLPEnc([clean componentsJoinedByString:@"\n"])];
    [[RLPCoreClient shared] postJSON:@"/api/queue/set" body:body
                          completion:^(NSDictionary * _Nullable j) {
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
    [[RLPCoreClient shared] getJSON:@"/api/playmode" completion:^(NSDictionary * _Nullable modeJson) {
        NSInteger mode = [modeJson[@"mode"] respondsToSelector:@selector(integerValue)]
                       ? [modeJson[@"mode"] integerValue] : 0;
        if (mode == 2) {
            [[RLPCoreClient shared] postJSON:@"/api/playmode?mode=1" body:nil
                                  completion:^(NSDictionary * _Nullable) { RLPSetQueueAndPlay(clean, i); }];
        } else {
            RLPSetQueueAndPlay(clean, i);
        }
    }];
}
