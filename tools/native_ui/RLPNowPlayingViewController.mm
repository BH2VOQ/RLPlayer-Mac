// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPNowPlayingViewController.mm — 正在播放（纯 AppKit）
//
// 只读展示 + 少量动作（播放/暂停、收藏、体检）。歌词来自 /api/lyrics?file=…，
// 音质体检来自 /api/health?file=…（都是既有端点，UI 不重复实现分析）。
#import "RLPNowPlayingViewController.h"
#import "RLPCoreClient.h"
#import "RLPModels.h"
#import "RLPSupport.h"
#import "RLPTheme.h"

@interface RLPNowPlayingViewController ()
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic) BOOL polling;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) NSImageView *cover;
@property (nonatomic, strong) NSTextField *titleLabel2;
@property (nonatomic, strong) NSTextField *artistLabel2;
@property (nonatomic, strong) NSTextField *metaLabel;
@property (nonatomic, strong) NSTextView *lyricsView;
@property (nonatomic, strong) NSTextField *lyricsEmpty;
@property (nonatomic, strong) NSTextView *healthView;
@property (nonatomic, strong) NSTextField *healthEmpty;
/// 封面请求序号：快速切歌时用它丢弃过期回调（慢请求回来不能盖掉新封面）。
@property (nonatomic, assign) NSUInteger coverSeq;
@end

@implementation RLPNowPlayingViewController

- (instancetype)init {
    self = [super initWithTitle:@"正在播放"];
    return self;
}

- (void)buildContent {
    RLPTheme *t = [RLPTheme current];
    NSView *host = self.contentView;

    self.cover = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.cover.wantsLayer = YES;
    self.cover.layer.cornerRadius = 12;
    self.cover.layer.masksToBounds = YES;
    self.cover.layer.backgroundColor = t.bg2.CGColor;
    self.cover.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.cover];

    self.titleLabel2 = RLPLabel(@"", [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold], t.text);
    self.titleLabel2.maximumNumberOfLines = 2;
    self.titleLabel2.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.titleLabel2];

    self.artistLabel2 = RLPLabel(@"", [NSFont systemFontOfSize:14], t.mut);
    self.artistLabel2.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.artistLabel2];

    self.metaLabel = RLPLabel(@"", t.mono, t.mut);
    self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.metaLabel];

    NSButton *fav = [NSButton buttonWithTitle:RLPTr(@"收藏") target:self action:@selector(onFav:)];
    fav.bezelStyle = NSBezelStyleRounded;
    fav.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:fav];

    NSButton *health = [NSButton buttonWithTitle:RLPTr(@"音质体检") target:self action:@selector(onHealth:)];
    health.bezelStyle = NSBezelStyleRounded;
    health.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:health];

    NSTextField *lyricsTitle = RLPLabel(@"歌词", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
    lyricsTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:lyricsTitle];

    self.lyricsView = [self makeTextView];
    NSScrollView *lyScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    lyScroll.drawsBackground = NO;
    lyScroll.hasVerticalScroller = YES;
    lyScroll.autohidesScrollers = YES;
    lyScroll.documentView = self.lyricsView;
    lyScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:lyScroll];

    self.lyricsEmpty = RLPLabel(@"", t.small, t.mut);
    self.lyricsEmpty.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.lyricsEmpty];

    NSTextField *healthTitle = RLPLabel(@"音质体检", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], t.text);
    healthTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:healthTitle];

    self.healthView = [self makeTextView];
    NSScrollView *hScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    hScroll.drawsBackground = NO;
    hScroll.hasVerticalScroller = YES;
    hScroll.autohidesScrollers = YES;
    hScroll.documentView = self.healthView;
    hScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:hScroll];

    self.healthEmpty = RLPLabel(@"", t.small, t.mut);
    self.healthEmpty.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:self.healthEmpty];

    [NSLayoutConstraint activateConstraints:@[
        [self.cover.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [self.cover.topAnchor constraintEqualToAnchor:host.topAnchor constant:8],
        [self.cover.widthAnchor constraintEqualToConstant:180],
        [self.cover.heightAnchor constraintEqualToConstant:180],

        [self.titleLabel2.leadingAnchor constraintEqualToAnchor:self.cover.trailingAnchor constant:20],
        [self.titleLabel2.topAnchor constraintEqualToAnchor:self.cover.topAnchor constant:6],
        [self.titleLabel2.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [self.artistLabel2.leadingAnchor constraintEqualToAnchor:self.titleLabel2.leadingAnchor],
        [self.artistLabel2.topAnchor constraintEqualToAnchor:self.titleLabel2.bottomAnchor constant:8],
        [self.artistLabel2.trailingAnchor constraintEqualToAnchor:self.titleLabel2.trailingAnchor],
        [self.metaLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel2.leadingAnchor],
        [self.metaLabel.topAnchor constraintEqualToAnchor:self.artistLabel2.bottomAnchor constant:6],
        [self.metaLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel2.trailingAnchor],
        [fav.leadingAnchor constraintEqualToAnchor:self.titleLabel2.leadingAnchor],
        [fav.topAnchor constraintEqualToAnchor:self.metaLabel.bottomAnchor constant:14],
        [health.leadingAnchor constraintEqualToAnchor:fav.trailingAnchor constant:10],
        [health.centerYAnchor constraintEqualToAnchor:fav.centerYAnchor],

        [lyricsTitle.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [lyricsTitle.topAnchor constraintEqualToAnchor:self.cover.bottomAnchor constant:18],
        [lyScroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:24],
        [lyScroll.topAnchor constraintEqualToAnchor:lyricsTitle.bottomAnchor constant:6],
        [lyScroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-12],
        [lyScroll.widthAnchor constraintEqualToAnchor:host.widthAnchor multiplier:0.5 constant:-36],
        [self.lyricsEmpty.leadingAnchor constraintEqualToAnchor:lyScroll.leadingAnchor],
        [self.lyricsEmpty.topAnchor constraintEqualToAnchor:lyScroll.topAnchor constant:4],

        [healthTitle.leadingAnchor constraintEqualToAnchor:lyScroll.trailingAnchor constant:24],
        [healthTitle.topAnchor constraintEqualToAnchor:lyricsTitle.topAnchor],
        [hScroll.leadingAnchor constraintEqualToAnchor:healthTitle.leadingAnchor],
        [hScroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-24],
        [hScroll.topAnchor constraintEqualToAnchor:healthTitle.bottomAnchor constant:6],
        [hScroll.bottomAnchor constraintEqualToAnchor:lyScroll.bottomAnchor],
        [self.healthEmpty.leadingAnchor constraintEqualToAnchor:hScroll.leadingAnchor],
        [self.healthEmpty.topAnchor constraintEqualToAnchor:hScroll.topAnchor constant:4],
    ]];
}

- (NSTextView *)makeTextView {
    RLPTheme *t = [RLPTheme current];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 240)];
    tv.editable = NO;
    tv.selectable = YES;
    tv.drawsBackground = NO;
    tv.font = t.body;
    tv.textColor = t.text;
    tv.textContainerInset = NSMakeSize(2, 6);
    tv.string = @"";
    return tv;
}

- (void)activate {
    [self startPolling];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self stopPolling];
}

- (void)startPolling {
    if (self.polling) return;
    if (![RLPCoreClient shared].started) {
        [self setSubtitle:@"核心未启动"];
        return;
    }
    self.polling = YES;
    __weak __typeof__(self) weakSelf = self;
    self.poll = [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf refresh];
    }];
    [self refresh];
}

- (void)stopPolling {
    [self.poll invalidate];
    self.poll = nil;
    self.polling = NO;
}

- (void)refresh {
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:@"/api/status" completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        RLPPlaybackStatus *st = [RLPPlaybackStatus statusFromJSON:json];
        if (!st) return;
        NSString *path = st.currentPath ?: @"";
        self_.titleLabel2.stringValue = path.length ? path.lastPathComponent.stringByDeletingPathExtension : RLPTr(@"未播放");
        self_.artistLabel2.stringValue = st.error.length ? st.error
            : (st.bitPerfect.length ? [NSString stringWithFormat:@"bit-perfect: %@", st.bitPerfect] : @"");
        self_.artistLabel2.textColor = st.error.length ? [RLPTheme current].danger : [RLPTheme current].mut;
        self_.metaLabel.stringValue = [NSString stringWithFormat:@"%@ / %@",
            RLPFmtDuration(st.position), RLPFmtDuration(st.duration)];
        if (![path isEqualToString:self_.currentPath ?: @""]) {
            self_.currentPath = path;
            [self_ loadLyricsForPath:path];
            [self_ loadCoverForPath:path];
            self_.healthView.string = @"";
            self_.healthEmpty.stringValue = RLPTr(@"点击「音质体检」分析当前曲目");
        }
    }];
}

- (void)loadLyricsForPath:(NSString *)path {
    if (!path.length) {
        self.lyricsView.string = @"";
        self.lyricsEmpty.stringValue = RLPTr(@"未在播放");
        return;
    }
    self.lyricsEmpty.stringValue = RLPTr(@"正在读取歌词…");
    NSString *url = [NSString stringWithFormat:@"/api/lyrics?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        NSString *lrc = [json[@"lrc"] isKindOfClass:[NSString class]] ? json[@"lrc"] : @"";
        BOOL ok = json && [json[@"ok"] boolValue];
        if (ok && lrc.length) {
            self_.lyricsView.string = lrc;
            self_.lyricsEmpty.stringValue = @"";
        } else {
            self_.lyricsView.string = @"";
            self_.lyricsEmpty.stringValue = RLPTr(@"这首曲目没有歌词");
        }
    }];
}

/// 按**文件路径**取封面：/api/cover?file=… 是既有端点（与 web 版单曲页同一个），
/// 内部走「内嵌图 → 同目录图 → 所属专辑封面」三级兜底，因此不需要先解析专辑 key。
/// 用单调递增的请求序号丢弃过期结果：快速切歌时慢请求回来不能盖掉新封面。
- (void)loadCoverForPath:(NSString *)path {
    if (!path.length) {
        self.cover.image = nil;
        return;
    }
    const NSUInteger seq = ++self.coverSeq;
    NSString *url = [NSString stringWithFormat:@"/api/cover?file=%@", RLPEnc(path)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getData:url completion:^(NSData * _Nullable data) {
        __typeof__(self) self_ = weakSelf;
        if (!self_ || seq != self_.coverSeq) return;   // 过期结果直接丢
        self_.cover.image = data.length ? [[NSImage alloc] initWithData:data] : nil;
    }];
}

- (void)onFav:(id)sender {
    if (!self.currentPath.length) { RLPToast(RLPTr(@"没有正在播放的曲目")); return; }
    NSString *url = [NSString stringWithFormat:@"/api/fav?file=%@&on=1", RLPEnc(self.currentPath)];
    [[RLPCoreClient shared] postJSON:url body:@"" completion:^(NSDictionary * _Nullable json) {
        if (json && [json[@"ok"] boolValue]) RLPToast(RLPTr(@"已收藏"));
        else RLPToast(RLPTr(@"收藏失败"));
    }];
}

- (void)onHealth:(id)sender {
    if (!self.currentPath.length) { RLPToast(RLPTr(@"没有正在播放的曲目")); return; }
    self.healthEmpty.stringValue = RLPTr(@"正在分析…");
    NSString *url = [NSString stringWithFormat:@"/api/health?file=%@", RLPEnc(self.currentPath)];
    __weak __typeof__(self) weakSelf = self;
    [[RLPCoreClient shared] getJSON:url completion:^(NSDictionary * _Nullable json) {
        __typeof__(self) self_ = weakSelf;
        if (!self_) return;
        if (!json || ![json[@"ok"] boolValue]) {
            self_.healthEmpty.stringValue = RLPTr(@"分析失败");
            return;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:json
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:nil];
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
        self_.healthView.string = text ?: @"";
        self_.healthEmpty.stringValue = @"";
    }];
}

- (void)applyTheme {
    [super applyTheme];
    RLPTheme *t = [RLPTheme current];
    self.cover.layer.backgroundColor = t.bg2.CGColor;
    self.titleLabel2.textColor = t.text;
    self.artistLabel2.textColor = t.mut;
    self.metaLabel.textColor = t.mut;
    for (NSTextView *tv in @[self.lyricsView, self.healthView]) {
        tv.textColor = t.text;
        tv.font = t.body;
    }
    self.lyricsEmpty.textColor = t.mut;
    self.healthEmpty.textColor = t.mut;
}

@end