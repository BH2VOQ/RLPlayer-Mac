// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// native_host.mm — 纯 AppKit（Objective-C++，ARC）原生界面（1.1.7）
//
// 设计依据：docs/ui-redo/UI_REDESIGN_PLAN.md（基于 QQ 音乐 macOS 11.11.0 的静态逆向，
// 只取机制与信息架构，不复制其素材/文案/图标）。界面取法：
//   · 左侧全高侧栏（资料库 / 播放列表 / 音频引擎）+ 顶部搜索条 + 主内容区 + 右侧队列栏；
//   · 底部常驻播放条（圆形主色播放键、进度/音量、模式、队列、正在播放）；
//   · 沉浸「正在播放」页（模糊封面背景 + 封面 + 滚动歌词）；
//   · 独立设置窗口（分类页签）与独立更新窗口；
//   · 浅色为默认主题，主题只在设置里改（用户 2026-11-11 明确）。
//
// 状态真相源全部在 C++ 核心；本文件只经 rlnative:: 桥读写，不复制播放/队列状态。
// 明确不做：WKWebView 主内容区、Swift/SwiftUI、XIB/Storyboard。
#import <AppKit/AppKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <chrono>
#include <map>
#include <string>
#include <vector>

#include "native/core_bridge.h"
#include "native/native_host.h"
#include "mac_update.h"
#include "rlapp_core.h"

// ===========================================================================
// 基础工具 / 主题（文件级静态，非命名空间：ObjC 类声明不能放进 C++ namespace）
// ===========================================================================

struct Theme {
    __unsafe_unretained NSColor* bg;
    __unsafe_unretained NSColor* sidebar;
    __unsafe_unretained NSColor* content;
    __unsafe_unretained NSColor* card;
    __unsafe_unretained NSColor* text;
    __unsafe_unretained NSColor* muted;
    __unsafe_unretained NSColor* accent;
    __unsafe_unretained NSColor* separator;
    __unsafe_unretained NSColor* selection;
    __unsafe_unretained NSColor* playerBar;
    __unsafe_unretained NSColor* hover;
    __unsafe_unretained NSColor* badge;
};

// 强调色取 QQ 音乐品牌绿（浅色/深色），浅蓝主题用蓝。
Theme theme_light() {
    return Theme{
        [NSColor colorWithSRGBRed:0.976 green:0.980 blue:0.984 alpha:1],
        [NSColor colorWithSRGBRed:0.945 green:0.953 blue:0.961 alpha:1],
        [NSColor colorWithSRGBRed:0.980 green:0.984 blue:0.988 alpha:1],
        [NSColor whiteColor],
        [NSColor colorWithSRGBRed:0.075 green:0.086 blue:0.098 alpha:1],
        [NSColor colorWithSRGBRed:0.435 green:0.459 blue:0.490 alpha:1],
        [NSColor colorWithSRGBRed:0.192 green:0.760 blue:0.486 alpha:1],
        [NSColor colorWithSRGBRed:0.882 green:0.894 blue:0.906 alpha:1],
        [NSColor colorWithSRGBRed:0.886 green:0.949 blue:0.914 alpha:1],
        [NSColor colorWithSRGBRed:0.996 green:0.996 blue:0.996 alpha:0.96],
        [NSColor colorWithSRGBRed:0.925 green:0.937 blue:0.949 alpha:1],
        [NSColor colorWithSRGBRed:0.902 green:0.957 blue:0.925 alpha:1],
    };
}
Theme theme_dark() {
    return Theme{
        [NSColor colorWithSRGBRed:0.098 green:0.102 blue:0.110 alpha:1],
        [NSColor colorWithSRGBRed:0.125 green:0.133 blue:0.145 alpha:1],
        [NSColor colorWithSRGBRed:0.110 green:0.118 blue:0.129 alpha:1],
        [NSColor colorWithSRGBRed:0.165 green:0.176 blue:0.192 alpha:1],
        [NSColor colorWithSRGBRed:0.925 green:0.933 blue:0.945 alpha:1],
        [NSColor colorWithSRGBRed:0.600 green:0.624 blue:0.655 alpha:1],
        [NSColor colorWithSRGBRed:0.231 green:0.804 blue:0.541 alpha:1],
        [NSColor colorWithSRGBRed:0.224 green:0.239 blue:0.259 alpha:1],
        [NSColor colorWithSRGBRed:0.153 green:0.282 blue:0.220 alpha:1],
        [NSColor colorWithSRGBRed:0.137 green:0.145 blue:0.157 alpha:0.96],
        [NSColor colorWithSRGBRed:0.204 green:0.220 blue:0.239 alpha:1],
        [NSColor colorWithSRGBRed:0.145 green:0.263 blue:0.204 alpha:1],
    };
}
Theme theme_blue() {
    return Theme{
        [NSColor colorWithSRGBRed:0.941 green:0.965 blue:0.996 alpha:1],
        [NSColor colorWithSRGBRed:0.910 green:0.941 blue:0.988 alpha:1],
        [NSColor colorWithSRGBRed:0.965 green:0.980 blue:1.000 alpha:1],
        [NSColor whiteColor],
        [NSColor colorWithSRGBRed:0.047 green:0.118 blue:0.216 alpha:1],
        [NSColor colorWithSRGBRed:0.361 green:0.435 blue:0.541 alpha:1],
        [NSColor colorWithSRGBRed:0.086 green:0.475 blue:0.945 alpha:1],
        [NSColor colorWithSRGBRed:0.820 green:0.871 blue:0.941 alpha:1],
        [NSColor colorWithSRGBRed:0.851 green:0.906 blue:0.988 alpha:1],
        [NSColor colorWithSRGBRed:0.957 green:0.973 blue:0.996 alpha:0.96],
        [NSColor colorWithSRGBRed:0.886 green:0.922 blue:0.972 alpha:1],
        [NSColor colorWithSRGBRed:0.867 green:0.918 blue:0.988 alpha:1],
    };
}

NSImage* nm_symbol(NSString* name, CGFloat pt) {
    NSImage* img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!img) return nil;
    NSImageSymbolConfiguration* cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:pt weight:NSFontWeightMedium];
    return [img imageWithSymbolConfiguration:cfg];
}

NSTextField* nm_label(NSString* text, CGFloat size, NSFontWeight weight, NSColor* color) {
    NSTextField* l = [NSTextField labelWithString:text ?: @""];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

NSButton* nm_symbol_button(NSString* symbol, id target, SEL action, NSString* tip) {
    NSButton* b = [NSButton buttonWithImage:nm_symbol(symbol, 15) target:target action:action];
    b.bezelStyle = NSBezelStyleInline;
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.toolTip = tip;
    b.accessibilityLabel = tip;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintEqualToConstant:28].active = YES;
    [b.heightAnchor constraintEqualToConstant:28].active = YES;
    return b;
}

NSString* nm_time(double sec) {
    if (!(sec > 0)) return @"0:00";
    const int total = (int)(sec + 0.5);
    return [NSString stringWithFormat:@"%d:%02d", total / 60, total % 60];
}

NSString* nm_quality(int sr, int bits) {
    if (sr <= 0 && bits <= 0) return @"";
    NSString* khz = [NSString stringWithFormat:@"%.1f kHz", sr / 1000.0];
    if (sr % 1000 == 0) khz = [NSString stringWithFormat:@"%d kHz", sr / 1000];
    return bits > 0 ? [NSString stringWithFormat:@"%@ / %d bit", khz, bits] : khz;
}

BOOL nm_file_exists(NSString* path) {
    return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

// 主内容页容器：翻转坐标，子视图从顶部排版。
@interface NMFlippedView : NSView
@end
@implementation NMFlippedView
- (BOOL)isFlipped { return YES; }
@end

// 专辑网格单元
@interface NMAlbumItem : NSCollectionViewItem
@property (nonatomic, strong) NSImageView* cover;
@property (nonatomic, strong) NSTextField* name;
@property (nonatomic, strong) NSTextField* artist;
@property (nonatomic, copy) NSString* albumKey;
- (void)configure:(const rlnative::Album&)a theme:(const Theme&)t;
@end

// 歌手网格单元
@interface NMArtistItem : NSCollectionViewItem
@property (nonatomic, strong) NSImageView* cover;
@property (nonatomic, strong) NSTextField* name;
@property (nonatomic, strong) NSTextField* count;
@property (nonatomic, copy) NSString* albumKey;
- (void)configureName:(NSString*)name count:(int)n albumKey:(NSString*)key theme:(const Theme&)t;
@end

// 通用表格单元
@interface NMTrackCell : NSTableCellView
@property (nonatomic, strong) NSTextField* idxLabel;
@property (nonatomic, strong) NSTextField* titleLabel;
@property (nonatomic, strong) NSTextField* subLabel;
@property (nonatomic, strong) NSTextField* durLabel;
@property (nonatomic, strong) NSTextField* qualLabel;
@property (nonatomic, strong) NSButton* favButton;
- (void)configureIndex:(NSInteger)idx title:(NSString*)title sub:(NSString*)sub
                   dur:(NSString*)dur qual:(NSString*)qual theme:(const Theme&)t;
@end

// 主题只能按值临时传递；用全局当前主题避免跨文件生命周期问题。
static Theme g_theme;
static void nm_set_theme_by_name(NSString* name) {
    if ([name isEqualToString:@"dark"]) g_theme = theme_dark();
    else if ([name isEqualToString:@"blue"]) g_theme = theme_blue();
    else g_theme = theme_light();
}
static Theme nm_theme(void) { return g_theme; }

// 封面缓存：key -> NSImage；nil 占位避免重复请求。
static NSCache<NSString*, NSImage*>* nm_cover_cache(void) {
    static NSCache<NSString*, NSImage*>* cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 400; });
    return cache;
}
static dispatch_queue_t nm_cover_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("rlplayer.cover", DISPATCH_QUEUE_CONCURRENT);
        dispatch_set_target_queue(q, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return q;
}

// ===========================================================================
// 命令
// ===========================================================================
enum class Cmd : int {
    PlayPause = 1, Next, Previous, Stop, VolumeUp, VolumeDown,
    SeekForward, SeekBackward,
    ModeSequential, ModeListLoop, ModeSingleLoop, ModeShuffle, CycleMode,
    ToggleSidebar, ToggleQueueRail, FocusSearch, OpenSettings, CheckUpdate,
    ShowNowPlaying, ShowQueue, ShowAlbums, ShowArtists, ShowTracks,
    ShowRecent, ShowFavorites, ShowFolders, ShowStreaming, Rescan, Scan,
    AddFavorites, RemoveFavorites, SaveQueue, ClearQueue, SortQueue,
    MiniPlayer, FullScreen,
};

static NSString* nm_mode_title(int m) {
    switch (m) {
        case 0: return @"顺序播放";
        case 1: return @"列表循环";
        case 2: return @"单曲循环";
        case 3: return @"随机播放";
        default: return @"顺序播放";
    }
}
static NSString* nm_mode_symbol(int m) {
    switch (m) {
        case 1: return @"repeat";
        case 2: return @"repeat.1";
        case 3: return @"shuffle";
        default: return @"arrow.right";
    }
}

// ===========================================================================
// App delegate
// ===========================================================================
typedef NS_ENUM(NSInteger, NMPage) {
    NMPageAlbums = 0, NMPageAlbumDetail, NMPageArtists, NMPageTracks,
    NMPageRecent, NMPageFavorites, NMPageFolders, NMPageStreaming,
    NMPageQueue, NMPageSavedQueue, NMPageSearch,
};

@interface RLNativeAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate,
                                           NSTableViewDataSource, NSTableViewDelegate,
                                           NSCollectionViewDataSource, NSCollectionViewDelegate,
                                           NSMenuItemValidation, NSSearchFieldDelegate,
                                           NSTextFieldDelegate>
// 外壳
@property (nonatomic, strong) NSWindow* window;
@property (nonatomic, strong) NSView* sidebar;
@property (nonatomic, strong) NSView* topbar;
@property (nonatomic, strong) NSView* contentHost;
@property (nonatomic, strong) NSScrollView* contentScroll;
@property (nonatomic, strong) NSView* queueRail;
@property (nonatomic, strong) NSView* playerBar;
@property (nonatomic, strong) NSView* nowPlayingOverlay;
// 顶栏
@property (nonatomic, strong) NSSearchField* searchField;
@property (nonatomic, strong) NSButton* backButton;
@property (nonatomic, strong) NSButton* queueToggle;
// 侧栏
@property (nonatomic, strong) NSMutableArray<NSButton*>* sideRows;
@property (nonatomic, strong) NSStackView* savedQueueStack;
// 内容
@property (nonatomic, strong) NSCollectionView* albumGrid;
@property (nonatomic, strong) NSTableView* trackTable;
@property (nonatomic, strong) NSTableView* queueTable;
@property (nonatomic, strong) NSTableView* railTable;
@property (nonatomic, strong) NSTextField* contentTitle;
@property (nonatomic, strong) NSTextField* contentSubtitle;
@property (nonatomic, strong) NSView* contentBody;
@property (nonatomic, strong) NSView* gridHost;
// 播放条
@property (nonatomic, strong) NSImageView* barCover;
@property (nonatomic, strong) NSTextField* barTitle;
@property (nonatomic, strong) NSTextField* barArtist;
@property (nonatomic, strong) NSButton* barPlay;
@property (nonatomic, strong) NSButton* barMode;
@property (nonatomic, strong) NSSlider* barSeek;
@property (nonatomic, strong) NSTextField* barElapsed;
@property (nonatomic, strong) NSTextField* barDuration;
@property (nonatomic, strong) NSSlider* barVolume;
@property (nonatomic, strong) NSButton* barFav;
// 正在播放
@property (nonatomic, strong) NSImageView* npCover;
@property (nonatomic, strong) NSTextField* npTitle;
@property (nonatomic, strong) NSTextField* npArtist;
@property (nonatomic, strong) NSTableView* npLyrics;
// 设置
@property (nonatomic, strong) NSWindow* settingsWindow;
@property (nonatomic, strong) NSWindow* updateWindow;
@property (nonatomic, strong) NSTextField* updateStatus;
@property (nonatomic, strong) NSProgressIndicator* updateProgress;
@property (nonatomic, strong) NSButton* updateAction;
// 菜单
@property (nonatomic, strong) NSMutableArray<NSMenuItem*>* modeMenuItems;
// 数据
@property (nonatomic, strong) NSTimer* pollTimer;
@property (nonatomic, assign) NMPage page_;
@property (nonatomic, assign) NSInteger themeIndex;
@property (nonatomic, assign) NSInteger selectedRow;
@property (nonatomic, assign) BOOL queueRailVisible;
@property (nonatomic, assign) BOOL nowPlayingVisible;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL scanRunning;
@property (nonatomic, copy) NSString* albumDetailKey;
@property (nonatomic, copy) NSString* savedQueueName;
@property (nonatomic, copy) NSString* query;
@end

// ===========================================================================
// 专辑/歌手网格单元
// ===========================================================================
static NSImage* nm_placeholder(NSString* key, NSSize size) {
    if (size.width < 2 || size.height < 2) size = NSMakeSize(160, 160);
    NSImage* img = [[NSImage alloc] initWithSize:size];
    [img lockFocus];
    [g_theme.card setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, size.width, size.height) xRadius:10 yRadius:10] fill];
    NSString* letter = key.length ? [[key.lastPathComponent substringToIndex:1] uppercaseString] : @"♪";
    NSDictionary* attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:size.width * 0.30 weight:NSFontWeightBold],
                            NSForegroundColorAttributeName: g_theme.muted};
    NSSize ts = [letter sizeWithAttributes:attrs];
    [letter drawAtPoint:NSMakePoint((size.width - ts.width) / 2, (size.height - ts.height) / 2) withAttributes:attrs];
    [img unlockFocus];
    return img;
}

static void nm_load_cover(NSString* key, NSImageView* iv) {
    if (!iv || key.length == 0) return;
    NSImage* cached = [nm_cover_cache() objectForKey:key];
    if (cached) { iv.image = cached; return; }
    iv.image = nm_placeholder(key, iv.bounds.size);
    NSString* k = [key copy];
    __weak NSImageView* weakIv = iv;
    dispatch_async(nm_cover_queue(), ^{
        const std::string bytes = rlnative::cover_bytes(std::string(k.UTF8String ?: ""));
        if (bytes.empty()) return;
        NSImage* img = [[NSImage alloc] initWithData:[NSData dataWithBytes:bytes.data() length:bytes.size()]];
        if (!img) return;
        [nm_cover_cache() setObject:img forKey:k];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSImageView* strongIv = weakIv;
            if (strongIv) strongIv.image = img;
        });
    });
}

@implementation NMAlbumItem
- (void)loadView {
    NSView* v = [[NSView alloc] init];
    v.wantsLayer = YES;
    self.view = v;
    _cover = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 158, 158)];
    _cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    _cover.wantsLayer = YES;
    _cover.layer.cornerRadius = 10;
    _cover.layer.masksToBounds = YES;
    _cover.layer.backgroundColor = g_theme.card.CGColor;
    [v addSubview:_cover];
    _name = nm_label(@"", 12.5, NSFontWeightSemibold, g_theme.text);
    _artist = nm_label(@"", 11, NSFontWeightRegular, g_theme.muted);
    [v addSubview:_name];
    [v addSubview:_artist];
    _name.frame = NSMakeRect(2, 168, 154, 18);
    _artist.frame = NSMakeRect(2, 188, 154, 15);
}
- (void)configure:(const rlnative::Album&)a theme:(const Theme&)t {
    (void)t;
    self.albumKey = [NSString stringWithUTF8String:a.key.c_str()];
    _name.stringValue = [NSString stringWithUTF8String:a.name.c_str()];
    _artist.stringValue = [NSString stringWithUTF8String:a.artist.c_str()];
    [self.view setFrame:NSMakeRect(0, 0, 158, 212)];
    nm_load_cover(self.albumKey, _cover);
}
@end

@implementation NMArtistItem
- (void)loadView {
    NSView* v = [[NSView alloc] init];
    self.view = v;
    _cover = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 0, 96, 96)];
    _cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    _cover.wantsLayer = YES;
    _cover.layer.cornerRadius = 48;
    _cover.layer.masksToBounds = YES;
    _cover.layer.backgroundColor = g_theme.card.CGColor;
    [v addSubview:_cover];
    _name = nm_label(@"", 12.5, NSFontWeightSemibold, g_theme.text);
    _count = nm_label(@"", 10.5, NSFontWeightRegular, g_theme.muted);
    _name.alignment = NSTextAlignmentCenter;
    _count.alignment = NSTextAlignmentCenter;
    _name.frame = NSMakeRect(0, 104, 136, 18);
    _count.frame = NSMakeRect(0, 123, 136, 14);
    [v addSubview:_name];
    [v addSubview:_count];
}
- (void)configureName:(NSString*)name count:(int)n albumKey:(NSString*)key theme:(const Theme&)t {
    (void)t;
    self.albumKey = key;
    _name.stringValue = name;
    _count.stringValue = [NSString stringWithFormat:@"%d 张专辑", n];
    [self.view setFrame:NSMakeRect(0, 0, 136, 140)];
    if (key.length) nm_load_cover(key, _cover);
    else _cover.image = nm_placeholder(name, NSMakeSize(96, 96));
}
@end

// ===========================================================================
// 页面数据与构建
// ===========================================================================
static rlnative::AlbumDetail g_detail;

@implementation RLNativeAppDelegate {
    rlnative::PlaybackSnapshot _snap;
    std::vector<rlnative::Album> _albums;
    std::vector<rlnative::Album> _albumsShown;
    std::vector<rlnative::Track> _tracks;
    std::vector<rlnative::QueueItem> _queue;
    std::vector<rlnative::SavedQueue> _saved;
    std::vector<rlnative::LyricLine> _lyrics;
    std::map<std::string, std::string> _settings;
    std::vector<std::pair<std::string, int>> _artists;   // 名字, 专辑数
    std::vector<std::string> _artistKeys;                // 代表专辑 key
    NSMutableArray<NSNumber*>* _navStack;
    NSInteger _lyricHighlight;
    NSInteger _activeLyricRow;
}

static const CGFloat kSidebarWidth = 224.0;
static const CGFloat kQueueWidth = 300.0;
static const CGFloat kTopbarHeight = 54.0;
static const CGFloat kPlayerHeight = 78.0;

- (instancetype)init {
    if ((self = [super init])) {
        _page_ = NMPageAlbums;
        _themeIndex = 1;
        _selectedRow = 0;
        _queueRailVisible = YES;
        _sideRows = [NSMutableArray array];
        _modeMenuItems = [NSMutableArray array];
        _navStack = [NSMutableArray array];
    }
    return self;
}

// ---------------------------------------------------------------------------
// 启动 / 退出
// ---------------------------------------------------------------------------
- (void)applicationDidFinishLaunching:(NSNotification*)n {
    (void)n;
    const std::string theme = rlnative::get_theme();
    nm_set_theme_by_name([NSString stringWithUTF8String:theme.c_str()]);
    if (theme == "dark") _themeIndex = 0;
    else if (theme == "blue") _themeIndex = 2;
    else _themeIndex = 1;
    _window.appearance = [NSAppearance appearanceNamed:(_themeIndex == 0 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)];

    [self buildMenu];
    [self buildWindow];
    [self setupMediaKeys];
    [self reloadSettings];
    [self reloadAlbums];
    [self loadQueue];
    [self showPage:NMPageAlbums pushHistory:NO];

    __weak RLNativeAppDelegate* weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* t) {
        (void)t;
        RLNativeAppDelegate* s = weakSelf;
        if (s) [s tick];
    }];
    [self tick];
    [self nativeSelfTestIfRequested];
}

// 原生 UI 自检（无鼠标/键盘自动化）：RLPLAYER_NATIVE_SELFTEST=1 时启动后核对
// 窗口真的建起来、三栏/播放条/页面都在、没有 WKWebView，然后退出并打印一行 JSON。
// 这不是"看起来能跑"，而是进程内可复核的启动判据（见项目铁律 4/5）。
- (void)nativeSelfTestIfRequested {
    if (!getenv("RLPLAYER_NATIVE_SELFTEST")) return;
    __weak RLNativeAppDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RLNativeAppDelegate* s = weakSelf;
        if (!s) return;
        __block NSInteger webviews = 0;
        __block void (^scan)(NSView*) = nil;
        scan = ^(NSView* v) {
            if ([v isKindOfClass:NSClassFromString(@"WKWebView")]) webviews++;
            for (NSView* sub in v.subviews) scan(sub);
        };
        if (s.window.contentView) scan(s.window.contentView);
        NSMutableArray<NSNumber*>* checks = [NSMutableArray array];
        [checks addObject:@(s.window != nil && s.window.visible)];
        [checks addObject:@(s.sidebar != nil && s.sidebar.superview != nil)];
        [checks addObject:@(s.playerBar != nil && s.playerBar.superview != nil)];
        [checks addObject:@(s.queueRail != nil && s.queueRail.superview != nil)];
        [checks addObject:@(s.contentScroll.documentView != nil)];
        [checks addObject:@(webviews == 0)];
        NSInteger pass = 0;
        for (NSNumber* n in checks) if (n.boolValue) pass++;
        std::fprintf(stderr,
                     "NATIVE_SELFTEST {\"pass\":%ld,\"total\":%lu,\"window\":%s,"
                     "\"sidebar\":%s,\"player\":%s,\"queue\":%s,\"page\":%s,"
                     "\"webviews\":%ld,\"albums\":%zu,\"queueItems\":%zu}\n",
                     (long)pass, (unsigned long)checks.count,
                     (s.window && s.window.visible) ? "true" : "false",
                     (s.sidebar.superview != nil) ? "true" : "false",
                     (s.playerBar.superview != nil) ? "true" : "false",
                     (s.queueRail.superview != nil) ? "true" : "false",
                     (s.contentScroll.documentView != nil) ? "true" : "false",
                     (long)webviews, s->_albums.size(), s->_queue.size());
        std::fflush(stderr);
        [NSApp terminate:nil];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)a { (void)a; return YES; }

- (void)applicationWillTerminate:(NSNotification*)n {
    (void)n;
    rlapp::request_shutdown();
    rlapp::stop_embedded();
}

// ---------------------------------------------------------------------------
// 菜单
// ---------------------------------------------------------------------------
- (NSMenuItem*)menuItem:(NSMenu*)m title:(NSString*)title key:(NSString*)key cmd:(Cmd)c {
    NSMenuItem* mi = [m addItemWithTitle:title action:@selector(dispatchCmd:) keyEquivalent:key];
    mi.target = self; mi.tag = (NSInteger)c;
    if (key.length > 0) mi.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    return mi;
}

- (void)buildMenu {
    NSMenu* bar = [[NSMenu alloc] init];

    NSMenuItem* appItem = [[NSMenuItem alloc] init];
    NSMenu* app = [[NSMenu alloc] init];
    [app addItemWithTitle:@"关于 RLPlayer" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [app addItem:[NSMenuItem separatorItem]];
    [self menuItem:app title:@"设置…" key:@"," cmd:Cmd::OpenSettings];
    [self menuItem:app title:@"检查更新…" key:@"" cmd:Cmd::CheckUpdate];
    [app addItem:[NSMenuItem separatorItem]];
    [app addItemWithTitle:@"隐藏 RLPlayer" action:@selector(hide:) keyEquivalent:@"h"];
    [app addItemWithTitle:@"退出 RLPlayer" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = app;
    [bar addItem:appItem];

    NSMenuItem* editItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    NSMenu* edit = [[NSMenu alloc] initWithTitle:@"编辑"];
    for (NSArray* row in @[@[@"撤销", @"undo:", @"z"], @[@"重做", @"redo:", @"Z"],
                           @[@"剪切", @"cut:", @"x"], @[@"拷贝", @"copy:", @"c"],
                           @[@"粘贴", @"paste:", @"v"], @[@"全选", @"selectAll:", @"a"]]) {
        NSMenuItem* it = [edit addItemWithTitle:row[0] action:NSSelectorFromString(row[1]) keyEquivalent:row[2]];
        it.target = nil;
        it.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    }
    [edit addItem:[NSMenuItem separatorItem]];
    NSMenuItem* find = [edit addItemWithTitle:@"查找" action:@selector(cmdFocusSearch:) keyEquivalent:@"f"];
    find.target = self;
    editItem.submenu = edit;
    [bar addItem:editItem];

    NSMenuItem* playItem = [[NSMenuItem alloc] initWithTitle:@"播放" action:nil keyEquivalent:@""];
    NSMenu* play = [[NSMenu alloc] initWithTitle:@"播放"];
    [self menuItem:play title:@"播放 / 暂停" key:@" " cmd:Cmd::PlayPause];
    [play addItem:[NSMenuItem separatorItem]];
    [self menuItem:play title:@"下一首" key:@"\u2192" cmd:Cmd::Next];
    [self menuItem:play title:@"上一首" key:@"\u2190" cmd:Cmd::Previous];
    [self menuItem:play title:@"停止" key:@"." cmd:Cmd::Stop];
    [play addItem:[NSMenuItem separatorItem]];
    NSMenuItem* modeItem = [[NSMenuItem alloc] initWithTitle:@"播放模式" action:nil keyEquivalent:@""];
    NSMenu* mode = [[NSMenu alloc] initWithTitle:@"播放模式"];
    for (int m = 0; m < 4; ++m) {
        NSMenuItem* mi = [mode addItemWithTitle:nm_mode_title(m) action:@selector(cmdSetMode:) keyEquivalent:@""];
        mi.target = self; mi.tag = m;
        [_modeMenuItems addObject:mi];
    }
    modeItem.submenu = mode;
    [play addItem:modeItem];
    [self menuItem:play title:@"切换播放模式" key:@"m" cmd:Cmd::CycleMode];
    playItem.submenu = play;
    [bar addItem:playItem];

    NSMenuItem* viewItem = [[NSMenuItem alloc] initWithTitle:@"显示" action:nil keyEquivalent:@""];
    NSMenu* view = [[NSMenu alloc] initWithTitle:@"显示"];
    [self menuItem:view title:@"显示 / 隐藏侧栏" key:@"s" cmd:Cmd::ToggleSidebar];
    [self menuItem:view title:@"显示 / 隐藏播放队列" key:@"2" cmd:Cmd::ToggleQueueRail];
    [self menuItem:view title:@"正在播放" key:@"p" cmd:Cmd::ShowNowPlaying];
    [view addItem:[NSMenuItem separatorItem]];
    [self menuItem:view title:@"专辑" key:@"1" cmd:Cmd::ShowAlbums];
    [self menuItem:view title:@"艺术家" key:@"3" cmd:Cmd::ShowArtists];
    [self menuItem:view title:@"曲目" key:@"4" cmd:Cmd::ShowTracks];
    [self menuItem:view title:@"最近播放" key:@"5" cmd:Cmd::ShowRecent];
    [self menuItem:view title:@"我的最爱" key:@"6" cmd:Cmd::ShowFavorites];
    [view addItem:[NSMenuItem separatorItem]];
    [self menuItem:view title:@"重新扫描音乐库" key:@"r" cmd:Cmd::Rescan];
    [view addItem:[NSMenuItem separatorItem]];
    NSMenuItem* full = [view addItemWithTitle:@"进入全屏" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    full.target = nil;
    full.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    viewItem.submenu = view;
    [bar addItem:viewItem];

    NSMenuItem* windowItem = [[NSMenuItem alloc] initWithTitle:@"窗口" action:nil keyEquivalent:@""];
    NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"窗口"];
    [windowMenu addItemWithTitle:@"最小化" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"关闭" action:@selector(performClose:) keyEquivalent:@"w"];
    windowItem.submenu = windowMenu;
    [bar addItem:windowItem];

    [NSApp setMainMenu:bar];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if (item.action == @selector(cmdSetMode:)) item.state = (item.tag == _snap.mode) ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}

// ---------------------------------------------------------------------------
// 主窗口
// ---------------------------------------------------------------------------
- (void)buildWindow {
    NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1240, 800)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"RLPlayer";
    w.titleVisibility = NSWindowTitleHidden;
    w.titlebarAppearsTransparent = YES;
    w.minSize = NSMakeSize(1040, 620);
    w.delegate = self;
    w.backgroundColor = g_theme.bg;
    [w setFrameAutosaveName:@"RLPlayerMainWindow"];
    [w center];
    _window = w;

    NSView* root = w.contentView;

    // 侧栏（全高，视觉材质，红绿灯直接落在栏内）
    _sidebar = [self buildSidebar];
    [root addSubview:_sidebar];
    // 队列栏
    _queueRail = [self buildQueueRail];
    [root addSubview:_queueRail];
    // 播放条（横跨全宽，QQ 音乐式底栏）
    _playerBar = [self buildPlayerBar];
    [root addSubview:_playerBar];
    // 主列（顶栏 + 内容）
    _topbar = [self buildTopbar];
    [root addSubview:_topbar];
    _contentScroll = [[NSScrollView alloc] init];
    _contentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _contentScroll.hasVerticalScroller = YES;
    _contentScroll.drawsBackground = NO;
    _contentScroll.scrollerStyle = NSScrollerStyleOverlay;
    [root addSubview:_contentScroll];
    _contentHost = [[NMFlippedView alloc] init];
    _contentHost.translatesAutoresizingMaskIntoConstraints = NO;
    _contentScroll.documentView = _contentHost;

    [NSLayoutConstraint activateConstraints:@[
        [_sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_sidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_sidebar.bottomAnchor constraintEqualToAnchor:_playerBar.topAnchor],
        [_sidebar.widthAnchor constraintEqualToConstant:kSidebarWidth],

        [_topbar.leadingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor],
        [_topbar.trailingAnchor constraintEqualToAnchor:_queueRail.leadingAnchor],
        [_topbar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_topbar.heightAnchor constraintEqualToConstant:kTopbarHeight],

        [_contentScroll.leadingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor],
        [_contentScroll.trailingAnchor constraintEqualToAnchor:_queueRail.leadingAnchor],
        [_contentScroll.topAnchor constraintEqualToAnchor:_topbar.bottomAnchor],
        [_contentScroll.bottomAnchor constraintEqualToAnchor:_playerBar.topAnchor],

        [_queueRail.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_queueRail.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_queueRail.bottomAnchor constraintEqualToAnchor:_playerBar.topAnchor],
        [_queueRail.widthAnchor constraintEqualToConstant:kQueueWidth],

        [_playerBar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_playerBar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_playerBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [_playerBar.heightAnchor constraintEqualToConstant:kPlayerHeight],
    ]];

    // 正在播放覆盖层（盖住主区域与队列栏，侧栏与播放条保持可见）
    _nowPlayingOverlay = [self buildNowPlaying];
    _nowPlayingOverlay.hidden = YES;
    [root addSubview:_nowPlayingOverlay];
    [NSLayoutConstraint activateConstraints:@[
        [_nowPlayingOverlay.leadingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor],
        [_nowPlayingOverlay.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_nowPlayingOverlay.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_nowPlayingOverlay.bottomAnchor constraintEqualToAnchor:_playerBar.topAnchor],
    ]];

    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// ---------------------------------------------------------------------------
// 侧栏
// ---------------------------------------------------------------------------
- (NSButton*)sideRow:(NSString*)title symbol:(NSString*)symbol tag:(NSInteger)tag indent:(BOOL)indent {
    NSButton* b = [NSButton buttonWithTitle:title target:self action:@selector(sideRowClicked:)];
    b.bezelStyle = NSBezelStyleInline;
    b.bordered = NO;
    b.alignment = NSTextAlignmentLeft;
    b.image = nm_symbol(symbol, 14);
    b.imagePosition = NSImageLeading;
    b.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    b.contentTintColor = g_theme.text;
    b.tag = tag;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 7.0;
    b.layer.backgroundColor = [NSColor clearColor].CGColor;
    if (indent) b.title = [@"   " stringByAppendingString:title];
    [b.heightAnchor constraintEqualToConstant:30].active = YES;
    [b.widthAnchor constraintEqualToConstant:(indent ? 196 : 208)].active = YES;
    [_sideRows addObject:b];
    return b;
}

- (NSTextField*)sideSection:(NSString*)text {
    NSTextField* l = nm_label(text, 11, NSFontWeightSemibold, g_theme.muted);
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (NSView*)buildSidebar {
    NSVisualEffectView* side = [[NSVisualEffectView alloc] init];
    side.material = NSVisualEffectMaterialSidebar;
    side.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    side.translatesAutoresizingMaskIntoConstraints = NO;
    side.wantsLayer = YES;

    NSTextField* brand = nm_label(@"RLPlayer", 17, NSFontWeightBold, g_theme.text);
    NSTextField* ver = nm_label([NSString stringWithFormat:@"v%s", RLPLAYER_VERSION_STR], 10, NSFontWeightMedium, g_theme.muted);
    NSImageView* logo = [[NSImageView alloc] init];
    logo.image = nm_symbol(@"waveform", 16);
    logo.contentTintColor = g_theme.accent;
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [logo.widthAnchor constraintEqualToConstant:18].active = YES;
    [logo.heightAnchor constraintEqualToConstant:18].active = YES;
    NSStackView* brandRow = [NSStackView stackViewWithViews:@[logo, brand]];
    brandRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    brandRow.spacing = 8;
    brandRow.translatesAutoresizingMaskIntoConstraints = NO;
    [side addSubview:brandRow];
    [side addSubview:ver];
    [NSLayoutConstraint activateConstraints:@[
        [brandRow.leadingAnchor constraintEqualToAnchor:side.leadingAnchor constant:78],
        [brandRow.topAnchor constraintEqualToAnchor:side.topAnchor constant:15],
        [ver.leadingAnchor constraintEqualToAnchor:brandRow.trailingAnchor constant:6],
        [ver.centerYAnchor constraintEqualToAnchor:brandRow.centerYAnchor],
    ]];

    NSScrollView* scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = NO;
    scroll.drawsBackground = NO;
    [side addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:side.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:side.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:side.topAnchor constant:52],
        [scroll.bottomAnchor constraintEqualToAnchor:side.bottomAnchor constant:-44],
    ]];

    NSStackView* stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 1;
    stack.edgeInsets = NSEdgeInsetsMake(4, 8, 8, 8);
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField* libTitle = [self sideSection:@"资料库"];
    [stack addArrangedSubview:libTitle];
    [stack setCustomSpacing:4 afterView:libTitle];
    [stack addArrangedSubview:[self sideRow:@"专辑" symbol:@"square.grid.2x2" tag:(NSInteger)Cmd::ShowAlbums indent:NO]];
    [stack addArrangedSubview:[self sideRow:@"艺术家" symbol:@"person.2" tag:(NSInteger)Cmd::ShowArtists indent:NO]];
    [stack addArrangedSubview:[self sideRow:@"曲目" symbol:@"music.note.list" tag:(NSInteger)Cmd::ShowTracks indent:NO]];
    [stack addArrangedSubview:[self sideRow:@"最近播放" symbol:@"clock.arrow.circlepath" tag:(NSInteger)Cmd::ShowRecent indent:NO]];
    [stack addArrangedSubview:[self sideRow:@"我的最爱" symbol:@"heart" tag:(NSInteger)Cmd::ShowFavorites indent:NO]];
    [stack addArrangedSubview:[self sideRow:@"文件夹" symbol:@"folder" tag:(NSInteger)Cmd::ShowFolders indent:NO]];
    [stack addArrangedSubview:[self sideRow:@"流媒体" symbol:@"dot.radiowaves.left.and.right" tag:(NSInteger)Cmd::ShowStreaming indent:NO]];

    NSTextField* plTitle = [self sideSection:@"播放列表"];
    [stack addArrangedSubview:plTitle];
    [stack setCustomSpacing:4 afterView:plTitle];
    [stack addArrangedSubview:[self sideRow:@"播放队列" symbol:@"list.bullet" tag:(NSInteger)Cmd::ShowQueue indent:NO]];
    _savedQueueStack = [[NSStackView alloc] init];
    _savedQueueStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _savedQueueStack.alignment = NSLayoutAttributeLeading;
    _savedQueueStack.spacing = 1;
    [stack addArrangedSubview:_savedQueueStack];

    NSTextField* engTitle = [self sideSection:@"音频引擎"];
    [stack addArrangedSubview:engTitle];
    [stack setCustomSpacing:4 afterView:engTitle];
    [stack addArrangedSubview:[self sideRow:@"设置" symbol:@"gearshape" tag:(NSInteger)Cmd::OpenSettings indent:NO]];
    [stack addArrangedSubview:[self sideRow:@"检查更新" symbol:@"arrow.down.circle" tag:(NSInteger)Cmd::CheckUpdate indent:NO]];

    scroll.documentView = stack;
    [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor].active = YES;

    // 底部音质/状态
    NSTextField* foot = nm_label(@"本地 HiFi 播放 · arm64", 10, NSFontWeightRegular, g_theme.muted);
    [side addSubview:foot];
    [NSLayoutConstraint activateConstraints:@[
        [foot.leadingAnchor constraintEqualToAnchor:side.leadingAnchor constant:14],
        [foot.bottomAnchor constraintEqualToAnchor:side.bottomAnchor constant:-14],
    ]];
    return side;
}

- (void)updateSidebarSelection {
    const NSInteger active = [self cmdForPage:_page_];
    for (NSButton* b in _sideRows) {
        const BOOL on = (active != 0 && b.tag == active);
        b.layer.backgroundColor = on ? g_theme.selection.CGColor : [NSColor clearColor].CGColor;
        b.contentTintColor = on ? g_theme.accent : g_theme.text;
        b.font = [NSFont systemFontOfSize:13 weight:on ? NSFontWeightSemibold : NSFontWeightRegular];
    }
}

- (NSInteger)cmdForPage:(NMPage)p {
    switch (p) {
        case NMPageAlbums: case NMPageSearch: return (NSInteger)Cmd::ShowAlbums;
        case NMPageArtists: return (NSInteger)Cmd::ShowArtists;
        case NMPageTracks: case NMPageAlbumDetail: return (NSInteger)Cmd::ShowTracks;
        case NMPageRecent: return (NSInteger)Cmd::ShowRecent;
        case NMPageFavorites: return (NSInteger)Cmd::ShowFavorites;
        case NMPageFolders: return (NSInteger)Cmd::ShowFolders;
        case NMPageStreaming: return (NSInteger)Cmd::ShowStreaming;
        case NMPageQueue: case NMPageSavedQueue: return (NSInteger)Cmd::ShowQueue;
        default: return 0;
    }
}

- (void)sideRowClicked:(NSButton*)sender {
    [self dispatchCmd:sender];
}

// ---------------------------------------------------------------------------
// 顶栏
// ---------------------------------------------------------------------------
- (NSView*)buildTopbar {
    NSView* v = [[NSView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.wantsLayer = YES;

    _backButton = nm_symbol_button(@"chevron.left", self, @selector(cmdBack:), @"返回");
    _backButton.enabled = NO;
    [v addSubview:_backButton];

    _searchField = [[NSSearchField alloc] init];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = @"搜索专辑、艺术家或曲目";
    _searchField.delegate = self;
    _searchField.continuous = YES;
    _searchField.accessibilityLabel = @"搜索";
    [v addSubview:_searchField];

    NSButton* scan = nm_symbol_button(@"arrow.triangle.2.circlepath", self, @selector(dispatchCmd:), @"重新扫描音乐库");
    scan.tag = (NSInteger)Cmd::Rescan;
    [v addSubview:scan];

    _queueToggle = nm_symbol_button(@"list.bullet.rectangle", self, @selector(dispatchCmd:), @"显示或隐藏播放队列");
    _queueToggle.tag = (NSInteger)Cmd::ToggleQueueRail;
    [v addSubview:_queueToggle];

    NSButton* settings = nm_symbol_button(@"gearshape", self, @selector(dispatchCmd:), @"设置");
    settings.tag = (NSInteger)Cmd::OpenSettings;
    [v addSubview:settings];

    NSButton* np = nm_symbol_button(@"play.rectangle", self, @selector(dispatchCmd:), @"正在播放");
    np.tag = (NSInteger)Cmd::ShowNowPlaying;
    [v addSubview:np];

    [NSLayoutConstraint activateConstraints:@[
        [_backButton.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:18],
        [_backButton.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [_searchField.leadingAnchor constraintEqualToAnchor:_backButton.trailingAnchor constant:10],
        [_searchField.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [_searchField.widthAnchor constraintEqualToConstant:260],
        [np.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16],
        [np.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [settings.trailingAnchor constraintEqualToAnchor:np.leadingAnchor constant:-2],
        [settings.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [_queueToggle.trailingAnchor constraintEqualToAnchor:settings.leadingAnchor constant:-2],
        [_queueToggle.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [scan.trailingAnchor constraintEqualToAnchor:_queueToggle.leadingAnchor constant:-2],
        [scan.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
    ]];
    return v;
}

// ---------------------------------------------------------------------------
// 播放条
// ---------------------------------------------------------------------------
- (NSView*)buildPlayerBar {
    NSVisualEffectView* bar = [[NSVisualEffectView alloc] init];
    bar.material = NSVisualEffectMaterialHeaderView;
    bar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.wantsLayer = YES;
    bar.layer.borderWidth = 1.0;
    bar.layer.borderColor = g_theme.separator.CGColor;

    // 左：封面 + 信息
    _barCover = [[NSImageView alloc] init];
    _barCover.translatesAutoresizingMaskIntoConstraints = NO;
    _barCover.imageScaling = NSImageScaleProportionallyUpOrDown;
    _barCover.wantsLayer = YES;
    _barCover.layer.cornerRadius = 6.0;
    _barCover.layer.masksToBounds = YES;
    _barCover.layer.backgroundColor = g_theme.card.CGColor;
    [bar addSubview:_barCover];
    [NSLayoutConstraint activateConstraints:@[
        [_barCover.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:16],
        [_barCover.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_barCover.widthAnchor constraintEqualToConstant:46],
        [_barCover.heightAnchor constraintEqualToConstant:46],
    ]];

    _barTitle = nm_label(@"未播放", 13, NSFontWeightSemibold, g_theme.text);
    _barArtist = nm_label(@"", 11, NSFontWeightRegular, g_theme.muted);
    NSStackView* info = [NSStackView stackViewWithViews:@[_barTitle, _barArtist]];
    info.orientation = NSUserInterfaceLayoutOrientationVertical;
    info.alignment = NSLayoutAttributeLeading;
    info.spacing = 2;
    info.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:info];
    [NSLayoutConstraint activateConstraints:@[
        [info.leadingAnchor constraintEqualToAnchor:_barCover.trailingAnchor constant:12],
        [info.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [info.widthAnchor constraintEqualToConstant:170],
    ]];

    _barFav = nm_symbol_button(@"heart", self, @selector(cmdToggleFavorite:), @"收藏当前曲目");
    [bar addSubview:_barFav];
    [NSLayoutConstraint activateConstraints:@[
        [_barFav.leadingAnchor constraintEqualToAnchor:info.trailingAnchor constant:4],
        [_barFav.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];

    // 中：控制 + 进度
    NSButton* prev = nm_symbol_button(@"backward.fill", self, @selector(dispatchCmd:), @"上一首");
    prev.tag = (NSInteger)Cmd::Previous;
    _barPlay = [NSButton buttonWithImage:nm_symbol(@"play.fill", 17) target:self action:@selector(dispatchCmd:)];
    _barPlay.tag = (NSInteger)Cmd::PlayPause;
    _barPlay.bezelStyle = NSBezelStyleCircular;
    _barPlay.bordered = NO;
    _barPlay.translatesAutoresizingMaskIntoConstraints = NO;
    _barPlay.wantsLayer = YES;
    _barPlay.layer.cornerRadius = 17;
    _barPlay.layer.backgroundColor = g_theme.accent.CGColor;
    _barPlay.contentTintColor = NSColor.whiteColor;
    _barPlay.accessibilityLabel = @"播放或暂停";
    [bar addSubview:_barPlay];
    [NSLayoutConstraint activateConstraints:@[
        [_barPlay.widthAnchor constraintEqualToConstant:34],
        [_barPlay.heightAnchor constraintEqualToConstant:34],
    ]];
    NSButton* next = nm_symbol_button(@"forward.fill", self, @selector(dispatchCmd:), @"下一首");
    next.tag = (NSInteger)Cmd::Next;
    _barMode = nm_symbol_button(@"arrow.right", self, @selector(dispatchCmd:), @"播放模式");
    _barMode.tag = (NSInteger)Cmd::CycleMode;

    NSStackView* keys = [NSStackView stackViewWithViews:@[prev, _barPlay, next]];
    keys.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    keys.spacing = 14;
    keys.alignment = NSLayoutAttributeCenterY;
    keys.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:keys];

    _barElapsed = nm_label(@"0:00", 10, NSFontWeightRegular, g_theme.muted);
    _barDuration = nm_label(@"0:00", 10, NSFontWeightRegular, g_theme.muted);
    _barSeek = [NSSlider sliderWithTarget:self action:@selector(cmdSeek:)];
    _barSeek.minValue = 0; _barSeek.maxValue = 1; _barSeek.doubleValue = 0;
    _barSeek.continuous = NO;
    _barSeek.controlSize = NSControlSizeSmall;
    _barSeek.translatesAutoresizingMaskIntoConstraints = NO;
    _barSeek.accessibilityLabel = @"播放进度";
    [bar addSubview:_barElapsed];
    [bar addSubview:_barSeek];
    [bar addSubview:_barDuration];
    [NSLayoutConstraint activateConstraints:@[
        [keys.centerXAnchor constraintEqualToAnchor:bar.centerXAnchor],
        [keys.topAnchor constraintEqualToAnchor:bar.topAnchor constant:12],
        [keys.heightAnchor constraintEqualToConstant:34],
        [_barElapsed.leadingAnchor constraintEqualToAnchor:keys.leadingAnchor],
        [_barElapsed.topAnchor constraintEqualToAnchor:keys.bottomAnchor constant:2],
        [_barSeek.leadingAnchor constraintEqualToAnchor:_barElapsed.trailingAnchor constant:8],
        [_barSeek.widthAnchor constraintEqualToConstant:260],
        [_barSeek.centerYAnchor constraintEqualToAnchor:_barElapsed.centerYAnchor],
        [_barDuration.leadingAnchor constraintEqualToAnchor:_barSeek.trailingAnchor constant:8],
        [_barDuration.centerYAnchor constraintEqualToAnchor:_barElapsed.centerYAnchor],
        [_barDuration.widthAnchor constraintEqualToConstant:40],
    ]];

    // 右：模式、音量、队列、正在播放
    _barVolume = [NSSlider sliderWithTarget:self action:@selector(cmdVolume:)];
    _barVolume.minValue = -60; _barVolume.maxValue = 0; _barVolume.doubleValue = -12;
    _barVolume.continuous = NO;
    _barVolume.controlSize = NSControlSizeSmall;
    _barVolume.translatesAutoresizingMaskIntoConstraints = NO;
    _barVolume.accessibilityLabel = @"音量";
    NSButton* volIcon = nm_symbol_button(@"speaker.wave.2", self, @selector(dispatchCmd:), @"音量");
    volIcon.tag = (NSInteger)Cmd::VolumeUp;
    [bar addSubview:_barMode];
    [bar addSubview:volIcon];
    [bar addSubview:_barVolume];
    [NSLayoutConstraint activateConstraints:@[
        [_barMode.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-14],
        [_barMode.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_barVolume.trailingAnchor constraintEqualToAnchor:_barMode.leadingAnchor constant:-8],
        [_barVolume.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_barVolume.widthAnchor constraintEqualToConstant:90],
        [volIcon.trailingAnchor constraintEqualToAnchor:_barVolume.leadingAnchor constant:-2],
        [volIcon.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];

    return bar;
}

// ---------------------------------------------------------------------------
// 队列栏
// ---------------------------------------------------------------------------
- (NSView*)buildQueueRail {
    NSVisualEffectView* v = [[NSVisualEffectView alloc] init];
    v.material = NSVisualEffectMaterialSidebar;
    v.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.wantsLayer = YES;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = g_theme.separator.CGColor;

    NSTextField* title = nm_label(@"当前播放", 13, NSFontWeightSemibold, g_theme.text);
    NSTextField* count = nm_label(@"0 首", 10, NSFontWeightRegular, g_theme.muted);
    count.tag = 7001;
    NSButton* clear = nm_symbol_button(@"trash", self, @selector(cmdClearQueue:), @"清空队列");
    NSButton* save = nm_symbol_button(@"square.and.arrow.down", self, @selector(cmdSaveQueue:), @"保存为歌单");
    NSStackView* head = [NSStackView stackViewWithViews:@[title, count, [NSView new], clear, save]];
    head.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    head.spacing = 6;
    head.alignment = NSLayoutAttributeCenterY;
    head.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:head];

    _railTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _railTable.headerView = nil;
    _railTable.rowHeight = 44;
    _railTable.backgroundColor = [NSColor clearColor];
    _railTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _railTable.style = NSTableViewStyleInset;
    NSTableColumn* c = [[NSTableColumn alloc] initWithIdentifier:@"q"];
    c.width = 280;
    [_railTable addTableColumn:c];
    _railTable.dataSource = self;
    _railTable.delegate = self;
    _railTable.target = self;
    _railTable.doubleAction = @selector(railDoubleClick:);
    NSScrollView* scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.documentView = _railTable;
    [v addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [head.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:14],
        [head.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-10],
        [head.topAnchor constraintEqualToAnchor:v.topAnchor constant:12],
        [head.heightAnchor constraintEqualToConstant:26],
        [scroll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:8],
        [scroll.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
    ]];
    return v;
}

// ---------------------------------------------------------------------------
// 轮询刷新
// ---------------------------------------------------------------------------
- (void)tick {
    const auto s = rlnative::snapshot();
    const bool changed = s.revision != _snap.revision;
    _snap = s;

    // 播放条
    if (!s.current.empty() && changed) {
        const std::string& p = s.current;
        NSString* path = [NSString stringWithUTF8String:p.c_str()];
        _barTitle.stringValue = path.lastPathComponent.stringByDeletingPathExtension ?: @"未播放";
        _barArtist.stringValue = @"";
        // 队列里有 meta 就用 meta 校正显示
        for (const auto& it : _queue) {
            if (it.path == p) {
                if (!it.title.empty()) _barTitle.stringValue = [NSString stringWithUTF8String:it.title.c_str()];
                if (!it.artist.empty()) _barArtist.stringValue = [NSString stringWithUTF8String:it.artist.c_str()];
                break;
            }
        }
        [self loadCoverForPath:path into:_barCover];
        [self updateMediaKeys];
    }
    _barPlay.image = nm_symbol(s.playing && !s.paused ? @"pause.fill" : @"play.fill", 17);
    _barElapsed.stringValue = nm_time(s.pos);
    _barDuration.stringValue = nm_time(s.dur);
    if (!_barSeek.cell.isHighlighted) _barSeek.doubleValue = s.dur > 0 ? (s.pos / s.dur) : 0;
    if (!_barVolume.cell.isHighlighted) _barVolume.doubleValue = s.volDb;
    _barMode.image = nm_symbol(nm_mode_symbol(s.mode), 15);
    _barMode.toolTip = nm_mode_title(s.mode);
    [_modeMenuItems enumerateObjectsUsingBlock:^(NSMenuItem* it, NSUInteger i, BOOL* stop) {
        it.state = (i == (NSUInteger)s.mode) ? NSControlStateValueOn : NSControlStateValueOff;
    }];

    // 队列栏计数
    for (NSView* v in _queueRail.subviews) {
        if (v.tag == 7001 && [v isKindOfClass:[NSTextField class]])
            ((NSTextField*)v).stringValue = [NSString stringWithFormat:@"%zu 首", s.count];
    }

    // 正在播放歌词跟随
    if (_nowPlayingVisible) [self syncLyricsToPos:s.pos];

    // 扫描进度（2 秒一次，避免每 tick 打库）
    static NSUInteger tickCount = 0;
    if (++tickCount % 20 == 0 && _page_ == NMPageFolders) [self refreshFoldersStats];
    if (changed) {
        [self reloadVisibleQueue];
        if (_nowPlayingVisible) [self refreshNowPlaying];
    }
}

- (void)loadCoverForPath:(NSString*)path into:(NSImageView*)iv {
    if (!iv || path.length == 0) return;
    // 队列 meta 没有专辑 key，用所在目录的专辑封面近似：通过专辑列表找共同目录
    NSString* dir = path.stringByDeletingLastPathComponent;
    for (const auto& a : _albums) {
        // 专辑 key 是相对路径；目录尾段匹配即可
        NSString* k = [NSString stringWithUTF8String:a.key.c_str()];
        if (k.length && ([dir hasSuffix:k] || [dir.lastPathComponent isEqualToString:k.lastPathComponent])) {
            [self loadCoverForKey:k into:iv];
            return;
        }
    }
}

- (void)loadCoverForKey:(NSString*)key into:(NSImageView*)iv {
    if (!iv || key.length == 0) return;
    NSImage* cached = [nm_cover_cache() objectForKey:key];
    if (cached) { iv.image = cached; return; }
    iv.image = [self placeholderCover:key size:iv.bounds.size];
    NSString* k = [key copy];
    __weak NSImageView* weakIv = iv;
    dispatch_async(nm_cover_queue(), ^{
        const std::string bytes = rlnative::cover_bytes(std::string(k.UTF8String ?: ""));
        if (bytes.empty()) return;
        NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
        NSImage* img = [[NSImage alloc] initWithData:data];
        if (!img) return;
        [nm_cover_cache() setObject:img forKey:k];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSImageView* strongIv = weakIv;
            if (strongIv) strongIv.image = img;
        });
    });
}

- (NSImage*)placeholderCover:(NSString*)key size:(NSSize)size {
    if (size.width < 2 || size.height < 2) size = NSMakeSize(160, 160);
    NSImage* img = [[NSImage alloc] initWithSize:size];
    [img lockFocus];
    [g_theme.card setFill];
    NSBezierPath* r = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, size.width, size.height) xRadius:8 yRadius:8];
    [r fill];
    NSString* letter = key.length ? [[key.lastPathComponent substringToIndex:1] uppercaseString] : @"♪";
    NSDictionary* attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:size.width * 0.32 weight:NSFontWeightBold],
                            NSForegroundColorAttributeName: g_theme.muted};
    NSSize ts = [letter sizeWithAttributes:attrs];
    [letter drawAtPoint:NSMakePoint((size.width - ts.width) / 2, (size.height - ts.height) / 2) withAttributes:attrs];
    [img unlockFocus];
    return img;
}

- (void)dispatchCmd:(id)sender {
    const Cmd c = (Cmd)[sender tag];
    [self handleCmd:c];
}

- (void)handleCmd:(Cmd)c {
    switch (c) {
        case Cmd::PlayPause: rlnative::toggle_pause(); break;
        case Cmd::Next: rlnative::next_track(); break;
        case Cmd::Previous: rlnative::previous_track(); break;
        case Cmd::Stop: rlnative::stop(); break;
        case Cmd::VolumeUp: rlnative::set_volume_db(std::min(0.0, _snap.volDb + 3.0)); break;
        case Cmd::VolumeDown: rlnative::set_volume_db(std::max(-60.0, _snap.volDb - 3.0)); break;
        case Cmd::SeekForward: rlnative::seek(std::min(1.0, (_snap.dur > 0 ? _snap.pos / _snap.dur : 0) + 0.05)); break;
        case Cmd::SeekBackward: rlnative::seek(std::max(0.0, (_snap.dur > 0 ? _snap.pos / _snap.dur : 0) - 0.05)); break;
        case Cmd::ModeSequential: rlnative::set_mode(0); break;
        case Cmd::ModeListLoop: rlnative::set_mode(1); break;
        case Cmd::ModeSingleLoop: rlnative::set_mode(2); break;
        case Cmd::ModeShuffle: rlnative::set_mode(3); break;
        case Cmd::CycleMode: rlnative::set_mode((_snap.mode + 1) % 4); break;
        case Cmd::ToggleSidebar: _sidebar.hidden = !_sidebar.hidden; break;
        case Cmd::ToggleQueueRail:
            _queueRailVisible = !_queueRailVisible;
            _queueRail.hidden = !_queueRailVisible;
            break;
        case Cmd::FocusSearch: [_window makeFirstResponder:_searchField]; break;
        case Cmd::OpenSettings: [self openSettings]; break;
        case Cmd::CheckUpdate: [self openUpdateWindow]; break;
        case Cmd::ShowNowPlaying: [self toggleNowPlaying]; break;
        case Cmd::ShowAlbums: [self showPage:NMPageAlbums pushHistory:YES]; break;
        case Cmd::ShowArtists: [self showPage:NMPageArtists pushHistory:YES]; break;
        case Cmd::ShowTracks: [self showPage:NMPageTracks pushHistory:YES]; break;
        case Cmd::ShowRecent: [self showPage:NMPageRecent pushHistory:YES]; break;
        case Cmd::ShowFavorites: [self showPage:NMPageFavorites pushHistory:YES]; break;
        case Cmd::ShowFolders: [self showPage:NMPageFolders pushHistory:YES]; break;
        case Cmd::ShowStreaming: [self showPage:NMPageStreaming pushHistory:YES]; break;
        case Cmd::ShowQueue: [self showPage:NMPageQueue pushHistory:YES]; break;
        case Cmd::Rescan:
            rlnative::scan_library(true);
            [self toast:@"已开始重新扫描音乐库"];
            break;
        case Cmd::Scan:
            rlnative::scan_library(false);
            [self toast:@"已开始增量扫描"];
            break;
        case Cmd::AddFavorites:
            if (!_snap.current.empty()) rlnative::favorite_set(_snap.current, true);
            break;
        case Cmd::RemoveFavorites:
            if (!_snap.current.empty()) rlnative::favorite_set(_snap.current, false);
            break;
        case Cmd::SaveQueue: [self cmdSaveQueue:nil]; break;
        case Cmd::ClearQueue: [self cmdClearQueue:nil]; break;
        case Cmd::SortQueue: rlnative::queue_sort_default(); [self loadQueue]; [self reloadVisibleQueue]; break;
        case Cmd::MiniPlayer: [self toast:@"迷你窗在后续版本提供"]; break;
        case Cmd::FullScreen: [_window toggleFullScreen:nil]; break;
    }
    [self tick];
}

- (void)cmdSetMode:(NSMenuItem*)sender { rlnative::set_mode((int)sender.tag); [self tick]; }
- (void)cmdFocusSearch:(id)s { (void)s; [_window makeFirstResponder:_searchField]; }
- (void)cmdBack:(id)s {
    if (_navStack.count == 0) return;
    NSNumber* n = _navStack.lastObject;
    [_navStack removeLastObject];
    [self showPage:(NMPage)n.integerValue pushHistory:NO];
}
- (void)cmdSeek:(NSSlider*)s { rlnative::seek(s.doubleValue); }
- (void)cmdVolume:(NSSlider*)s { rlnative::set_volume_db(s.doubleValue); }
- (void)cmdToggleFavorite:(id)s {
    (void)s;
    if (_snap.current.empty()) return;
    rlnative::favorite_toggle(_snap.current);
    [self tick];
}
- (void)toast:(NSString*)text {
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = text;
    [a addButtonWithTitle:@"好"];
    [a runModal];
}

// 菜单里的模式命令
- (BOOL)isNowPlayingShowing { return _nowPlayingVisible; }

// ---------------------------------------------------------------------------
// 数据装载
// ---------------------------------------------------------------------------
- (void)reloadSettings { _settings = rlnative::settings(); }

- (void)reloadAlbums {
    _albums = rlnative::albums(std::string(_query.UTF8String ?: ""));
    _albumsShown = _albums;
    // 歌手索引（按专辑 artist 归并，取第一张专辑做头像）
    _artists.clear();
    _artistKeys.clear();
    std::map<std::string, std::pair<int, std::string>> agg;
    for (const auto& a : _albums) {
        if (a.artist.empty()) continue;
        auto& e = agg[a.artist];
        e.first += 1;
        if (e.second.empty()) e.second = a.key;
    }
    for (const auto& kv : agg) { _artists.emplace_back(kv.first, kv.second.first); _artistKeys.push_back(kv.second.second); }
    [self reloadSavedQueues];
}

- (void)loadQueue {
    _queue = rlnative::queue(true).items;
    [_railTable reloadData];
    [_queueTable reloadData];
}

- (void)reloadVisibleQueue {
    [_railTable reloadData];
    if (_page_ == NMPageQueue) [_queueTable reloadData];
}

- (void)reloadSavedQueues {
    _saved = rlnative::saved_queues();
    for (NSView* v in _savedQueueStack.arrangedSubviews) [v removeFromSuperview];
    NSUInteger n = MIN(_saved.size(), (size_t)12);
    for (NSUInteger i = 0; i < n; ++i) {
        NSString* name = [NSString stringWithUTF8String:_saved[i].name.c_str()];
        NSButton* b = [NSButton buttonWithTitle:[NSString stringWithFormat:@"%@  (%d)", name, _saved[i].n]
                                         target:self action:@selector(savedQueueClicked:)];
        b.bezelStyle = NSBezelStyleInline;
        b.bordered = NO;
        b.alignment = NSTextAlignmentLeft;
        b.image = nm_symbol(@"music.note.list", 12);
        b.imagePosition = NSImageLeading;
        b.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        b.contentTintColor = g_theme.muted;
        b.identifier = name;
        b.toolTip = @"载入这个歌单";
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b.heightAnchor constraintEqualToConstant:26].active = YES;
        [b.widthAnchor constraintEqualToConstant:200].active = YES;
        [_savedQueueStack addArrangedSubview:b];
    }
    if (_saved.empty()) {
        NSTextField* empty = nm_label(@"暂无保存的歌单", 11, NSFontWeightRegular, g_theme.muted);
        [_savedQueueStack addArrangedSubview:empty];
    }
}

- (void)savedQueueClicked:(NSButton*)sender {
    NSString* name = sender.identifier;
    if (name.length == 0) return;
    _savedQueueName = name;
    if (rlnative::saved_queue_play(std::string(name.UTF8String), 0)) {
        [self loadQueue];
        [self showPage:NMPageSavedQueue pushHistory:YES];
    }
}

// ---------------------------------------------------------------------------
// 页面框架
// ---------------------------------------------------------------------------
- (CGFloat)contentWidth {
    CGFloat w = _contentScroll.contentSize.width;
    if (w < 320) w = 780;
    return w;
}

- (NSTextField*)heading:(NSString*)text x:(CGFloat)x y:(CGFloat)y {
    NSTextField* l = nm_label(text, 26, NSFontWeightBold, g_theme.text);
    [l sizeToFit];
    l.frame = NSMakeRect(x, y, MAX(l.frame.size.width, 80), 32);
    return l;
}

- (NSTextField*)subheading:(NSString*)text x:(CGFloat)x y:(CGFloat)y {
    NSTextField* l = nm_label(text, 11.5, NSFontWeightRegular, g_theme.muted);
    [l sizeToFit];
    l.frame = NSMakeRect(x, y, MAX(l.frame.size.width, 60), 16);
    return l;
}

- (NSButton*)pillButton:(NSString*)title symbol:(NSString*)symbol action:(SEL)action {
    NSButton* b = [NSButton buttonWithTitle:title target:self action:action];
    b.bezelStyle = NSBezelStyleRoundRect;
    b.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    b.image = nm_symbol(symbol, 12);
    b.imagePosition = NSImageLeading;
    b.contentTintColor = g_theme.accent;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:28].active = YES;
    [b.widthAnchor constraintEqualToConstant:110].active = YES;
    return b;
}

- (NSTextField*)emptyState:(NSString*)text width:(CGFloat)w {
    NSTextField* l = nm_label(text, 13, NSFontWeightRegular, g_theme.muted);
    l.alignment = NSTextAlignmentCenter;
    l.frame = NSMakeRect(20, 160, w - 40, 22);
    return l;
}

- (NSView*)headerWithTitle:(NSString*)title subtitle:(NSString*)sub actions:(NSArray<NSView*>*)actions width:(CGFloat)w {
    NMFlippedView* head = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 92)];
    NSTextField* t = [self heading:title x:26 y:20];
    [head addSubview:t];
    NSTextField* s = [self subheading:sub x:27 y:56];
    [head addSubview:s];
    CGFloat ax = w - 26;
    for (NSView* a in actions.reverseObjectEnumerator) {
        a.frame = NSMakeRect(ax - a.frame.size.width, 42, a.frame.size.width, 28);
        [head addSubview:a];
        ax -= a.frame.size.width + 10;
    }
    return head;
}

- (NSTableView*)makeTable:(NSRect)frame rowHeight:(CGFloat)rh {
    NSTableView* t = [[NSTableView alloc] initWithFrame:frame];
    t.headerView = nil;
    t.rowHeight = rh;
    t.backgroundColor = [NSColor clearColor];
    t.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    t.style = NSTableViewStyleInset;
    t.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
    t.gridColor = [g_theme.separator colorWithAlphaComponent:0.35];
    NSTableColumn* c = [[NSTableColumn alloc] initWithIdentifier:@"c"];
    c.width = frame.size.width - 20;
    c.resizingMask = NSTableColumnAutoresizingMask;
    [t addTableColumn:c];
    t.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    t.dataSource = self;
    t.delegate = self;
    t.target = self;
    t.doubleAction = @selector(trackDoubleClick:);
    return t;
}

- (NSScrollView*)scrollForTable:(NSTableView*)t frame:(NSRect)frame {
    NSScrollView* s = [[NSScrollView alloc] initWithFrame:frame];
    s.hasVerticalScroller = YES;
    s.drawsBackground = NO;
    s.scrollerStyle = NSScrollerStyleOverlay;
    s.autoresizingMask = NSViewWidthSizable;
    s.documentView = t;
    return s;
}

// ---------------------------------------------------------------------------
// 各页面
// ---------------------------------------------------------------------------
- (NSView*)pageAlbums {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 400)];
    NSString* sub = [NSString stringWithFormat:@"%zu 张专辑 · 按专辑归并", _albumsShown.size()];
    NSView* head = [self headerWithTitle:@"专辑" subtitle:sub actions:@[] width:w];
    [page addSubview:head];

    const CGFloat itemW = 158, itemH = 212, gap = 18;
    const NSInteger cols = MAX(1, (NSInteger)((w - 52 + gap) / (itemW + gap)));
    const NSInteger n = (NSInteger)_albumsShown.size();
    const NSInteger rows = (n + cols - 1) / cols;
    const CGFloat gridH = MAX(1, rows) * itemH + MAX(0, rows - 1) * gap;
    NSCollectionViewFlowLayout* flow = [[NSCollectionViewFlowLayout alloc] init];
    flow.itemSize = NSMakeSize(itemW, itemH);
    flow.minimumInteritemSpacing = gap;
    flow.minimumLineSpacing = gap;
    flow.sectionInset = NSEdgeInsetsMake(0, 0, 0, 0);
    NSCollectionView* grid = [[NSCollectionView alloc] initWithFrame:NSMakeRect(26, 100, w - 52, gridH)];
    grid.collectionViewLayout = flow;
    grid.dataSource = self;
    grid.delegate = self;
    grid.wantsLayer = YES;
    [grid registerClass:[NMAlbumItem class] forItemWithIdentifier:@"album"];
    [page addSubview:grid];
    _albumGrid = grid;
    if (n == 0) [page addSubview:[self emptyState:@"音乐库为空。点「重新扫描音乐库」或在设置里添加目录。" width:w]];
    page.frame = NSMakeRect(0, 0, w, 100 + gridH + 30);
    return page;
}

- (NSView*)pageArtists {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 400)];
    NSString* sub = [NSString stringWithFormat:@"%zu 位艺术家", _artists.size()];
    [page addSubview:[self headerWithTitle:@"艺术家" subtitle:sub actions:@[] width:w]];
    const CGFloat itemW = 136, itemH = 140, gap = 18;
    const NSInteger cols = MAX(1, (NSInteger)((w - 52 + gap) / (itemW + gap)));
    const NSInteger n = (NSInteger)_artists.size();
    const NSInteger rows = (n + cols - 1) / cols;
    const CGFloat gridH = MAX(1, rows) * itemH + MAX(0, rows - 1) * gap;
    NSCollectionViewFlowLayout* flow = [[NSCollectionViewFlowLayout alloc] init];
    flow.itemSize = NSMakeSize(itemW, itemH);
    flow.minimumInteritemSpacing = gap;
    flow.minimumLineSpacing = gap;
    NSCollectionView* grid = [[NSCollectionView alloc] initWithFrame:NSMakeRect(26, 100, w - 52, gridH)];
    grid.collectionViewLayout = flow;
    grid.dataSource = self;
    grid.delegate = self;
    [grid registerClass:[NMArtistItem class] forItemWithIdentifier:@"artist"];
    [page addSubview:grid];
    _albumGrid = grid;
    if (n == 0) [page addSubview:[self emptyState:@"还没有艺术家信息" width:w]];
    page.frame = NSMakeRect(0, 0, w, 100 + gridH + 30);
    return page;
}

- (NSView*)pageTracks {
    _tracks = rlnative::search_tracks("", 800);
    return [self pageTrackList:@"曲目" subtitle:[NSString stringWithFormat:@"最多显示 800 首（实际 %d 首）", (int)_tracks.size()]];
}

- (NSView*)pageRecent {
    _tracks = rlnative::recent_tracks();
    return [self pageTrackList:@"最近播放" subtitle:[NSString stringWithFormat:@"%zu 首", _tracks.size()]];
}

- (NSView*)pageFavorites {
    _tracks = rlnative::favorite_tracks();
    return [self pageTrackList:@"我的最爱" subtitle:[NSString stringWithFormat:@"%zu 首", _tracks.size()]];
}

- (NSView*)pageTrackList:(NSString*)title subtitle:(NSString*)sub {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 400)];
    NSButton* playAll = [self pillButton:@"播放全部" symbol:@"play.fill" action:@selector(cmdPlayVisible:)];
    [page addSubview:[self headerWithTitle:title subtitle:sub actions:@[playAll] width:w]];
    if (_tracks.empty()) {
        [page addSubview:[self emptyState:@"暂无内容" width:w]];
        page.frame = NSMakeRect(0, 0, w, 360);
        return page;
    }
    const CGFloat tableH = MIN((CGFloat)_tracks.size() * 42 + 8, 560);
    _trackTable = [self makeTable:NSMakeRect(0, 0, w - 40, tableH) rowHeight:42];
    _trackTable.doubleAction = @selector(trackDoubleClick:);
    _trackTable.target = self;
    NSScrollView* scroll = [self scrollForTable:_trackTable frame:NSMakeRect(20, 100, w - 40, tableH)];
    [page addSubview:scroll];
    page.frame = NSMakeRect(0, 0, w, 100 + tableH + 30);
    return page;
}

- (NSView*)pageAlbumDetail {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 500)];
    NSImageView* cover = [[NSImageView alloc] initWithFrame:NSMakeRect(26, 18, 168, 168)];
    cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    cover.wantsLayer = YES;
    cover.layer.cornerRadius = 10;
    cover.layer.masksToBounds = YES;
    cover.layer.backgroundColor = g_theme.card.CGColor;
    [page addSubview:cover];
    NSString* key = [NSString stringWithUTF8String:g_detail.album.key.c_str()];
    nm_load_cover(key, cover);

    NSTextField* name = nm_label([NSString stringWithUTF8String:g_detail.album.name.c_str()], 22, NSFontWeightBold, g_theme.text);
    [name sizeToFit];
    name.frame = NSMakeRect(214, 26, w - 240, 28);
    [page addSubview:name];
    NSString* meta = [NSString stringWithFormat:@"%s · %d 年 · %zu 首 · %@",
                      g_detail.album.artist.c_str(), g_detail.album.year,
                      g_detail.tracks.size(), nm_time(g_detail.album.dur)];
    NSTextField* metaL = nm_label(meta, 11.5, NSFontWeightRegular, g_theme.muted);
    metaL.frame = NSMakeRect(215, 60, w - 240, 18);
    [page addSubview:metaL];

    NSButton* playAll = [NSButton buttonWithTitle:@"播放全部" target:self action:@selector(cmdPlayAlbumAll:)];
    playAll.bezelStyle = NSBezelStyleRoundRect;
    playAll.contentTintColor = g_theme.accent;
    playAll.frame = NSMakeRect(215, 92, 96, 28);
    [page addSubview:playAll];
    NSButton* shuffle = [NSButton buttonWithTitle:@"随机播放" target:self action:@selector(cmdShuffleAlbum:)];
    shuffle.bezelStyle = NSBezelStyleRoundRect;
    shuffle.frame = NSMakeRect(319, 92, 96, 28);
    [page addSubview:shuffle];
    NSButton* back = [NSButton buttonWithTitle:@"返回" target:self action:@selector(cmdBack:)];
    back.bezelStyle = NSBezelStyleInline;
    back.frame = NSMakeRect(w - 88, 26, 62, 24);
    [page addSubview:back];

    if (g_detail.tracks.empty()) {
        [page addSubview:[self emptyState:@"这张专辑没有可播放的曲目" width:w]];
        page.frame = NSMakeRect(0, 0, w, 380);
        return page;
    }
    const CGFloat tableH = MIN((CGFloat)g_detail.tracks.size() * 42 + 8, 460);
    _trackTable = [self makeTable:NSMakeRect(0, 0, w - 40, tableH) rowHeight:42];
    _trackTable.doubleAction = @selector(trackDoubleClick:);
    _trackTable.target = self;
    NSScrollView* scroll = [self scrollForTable:_trackTable frame:NSMakeRect(20, 200, w - 40, tableH)];
    [page addSubview:scroll];
    page.frame = NSMakeRect(0, 0, w, 200 + tableH + 24);
    return page;
}

- (NSView*)pageQueue {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 400)];
    NSButton* clear = [self pillButton:@"清空" symbol:@"trash" action:@selector(cmdClearQueue:)];
    NSButton* sort = [self pillButton:@"恢复默认顺序" symbol:@"arrow.up.arrow.down" action:@selector(cmdSortQueue:)];
    [page addSubview:[self headerWithTitle:@"播放队列"
                                 subtitle:[NSString stringWithFormat:@"%zu 首 · %@", _queue.size(), nm_mode_title(_snap.mode)]
                                  actions:@[sort, clear] width:w]];
    if (_queue.empty()) {
        [page addSubview:[self emptyState:@"队列为空。从专辑或曲目开始播放。" width:w]];
        page.frame = NSMakeRect(0, 0, w, 360);
        return page;
    }
    const CGFloat tableH = MIN((CGFloat)_queue.size() * 42 + 8, 620);
    _queueTable = [self makeTable:NSMakeRect(0, 0, w - 40, tableH) rowHeight:42];
    _queueTable.doubleAction = @selector(queueDoubleClick:);
    _queueTable.target = self;
    NSScrollView* scroll = [self scrollForTable:_queueTable frame:NSMakeRect(20, 100, w - 40, tableH)];
    [page addSubview:scroll];
    page.frame = NSMakeRect(0, 0, w, 100 + tableH + 30);
    return page;
}

- (NSView*)pageSavedQueue {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 400)];
    NSString* name = _savedQueueName ?: @"";
    [page addSubview:[self headerWithTitle:name
                                 subtitle:[NSString stringWithFormat:@"%zu 首 · 已载入当前队列", _queue.size()]
                                  actions:@[] width:w]];
    if (_queue.empty()) {
        [page addSubview:[self emptyState:@"歌单为空" width:w]];
        page.frame = NSMakeRect(0, 0, w, 360);
        return page;
    }
    const CGFloat tableH = MIN((CGFloat)_queue.size() * 42 + 8, 620);
    _queueTable = [self makeTable:NSMakeRect(0, 0, w - 40, tableH) rowHeight:42];
    _queueTable.doubleAction = @selector(queueDoubleClick:);
    _queueTable.target = self;
    [page addSubview:[self scrollForTable:_queueTable frame:NSMakeRect(20, 100, w - 40, tableH)]];
    page.frame = NSMakeRect(0, 0, w, 100 + tableH + 30);
    return page;
}

- (NSView*)pageFolders {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 420)];
    NSButton* inc = [self pillButton:@"增量扫描" symbol:@"arrow.triangle.2.circlepath" action:@selector(cmdScanLibrary:)];
    NSButton* full = [self pillButton:@"全量重扫" symbol:@"arrow.clockwise" action:@selector(cmdRescanLibrary:)];
    [page addSubview:[self headerWithTitle:@"文件夹" subtitle:@"资料库根目录与扫描状态" actions:@[inc, full] width:w]];
    NMFlippedView* body = [[NMFlippedView alloc] initWithFrame:NSMakeRect(24, 100, w - 48, 280)];
    body.identifier = @"foldersBody";
    [page addSubview:body];
    page.frame = NSMakeRect(0, 0, w, 420);
    return page;
}

- (void)refreshFoldersStats {
    NMFlippedView* body = nil;
    for (NSView* v in _contentScroll.documentView.subviews) if ([v.identifier isEqualToString:@"foldersBody"]) body = (NMFlippedView*)v;
    if (!body) return;
    for (NSView* v in body.subviews) [v removeFromSuperview];
    const auto st = rlnative::library_stats();
    CGFloat y = 0;
    NSArray* rows = @[
        @[@"曲目", [NSString stringWithFormat:@"%d 首", st.tracks]],
        @[@"专辑", [NSString stringWithFormat:@"%d 张", st.albums]],
        @[@"扫描状态", st.scanning ? [NSString stringWithFormat:@"进行中 %d/%d", st.scanned, st.total] : @"空闲"],
        @[@"目录完整", st.complete ? @"是" : @"否"],
        @[@"失败目录", [NSString stringWithFormat:@"%d", st.failedDirs]],
    ];
    for (NSArray* r in rows) {
        NSTextField* k = nm_label(r[0], 12, NSFontWeightMedium, g_theme.muted);
        k.frame = NSMakeRect(0, y, 220, 18);
        [body addSubview:k];
        NSTextField* val = nm_label(r[1], 12.5, NSFontWeightSemibold, g_theme.text);
        val.frame = NSMakeRect(220, y, body.frame.size.width - 220, 18);
        [body addSubview:val];
        y += 30;
    }
    NSTextField* hint = nm_label(@"根目录由 rlplayer-library.conf 管理；扫描不删除文件。", 11, NSFontWeightRegular, g_theme.muted);
    hint.frame = NSMakeRect(0, y + 16, body.frame.size.width, 18);
    [body addSubview:hint];
}

- (NSView*)pageStreaming {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 460)];
    [page addSubview:[self headerWithTitle:@"流媒体" subtitle:@"Subsonic / Emby 服务器（与网页端共用同一配置）" actions:@[] width:w]];
    const auto cfg = rlnative::source_config();
    CGFloat y = 120;
    NSArray* labels = @[@"类型", @"服务器地址", @"用户名"];
    NSArray* values = @[[NSString stringWithUTF8String:cfg.kind.c_str()],
                       [NSString stringWithUTF8String:cfg.base.c_str()],
                       [NSString stringWithUTF8String:cfg.user.c_str()]];
    for (NSUInteger i = 0; i < labels.count; ++i) {
        NSTextField* k = nm_label(labels[i], 12, NSFontWeightMedium, g_theme.muted);
        k.frame = NSMakeRect(26, y, 90, 18);
        [page addSubview:k];
        NSTextField* f = nm_label(((NSString*)values[i]).length ? (NSString*)values[i] : @"未配置", 12.5, NSFontWeightMedium, g_theme.text);
        f.frame = NSMakeRect(130, y, w - 170, 18);
        [page addSubview:f];
        y += 32;
    }
    NSTextField* pass = nm_label(cfg.hasPass ? @"密码：已保存（不回显）" : @"密码：未设置", 12, NSFontWeightRegular, g_theme.muted);
    pass.frame = NSMakeRect(26, y, w - 60, 18);
    [page addSubview:pass];
    y += 36;
    NSTextField* hint = nm_label(@"在网页端设置页完成登录与浏览。原生页只展示当前配置，不重写流媒体协议。",
                                 11, NSFontWeightRegular, g_theme.muted);
    hint.frame = NSMakeRect(26, y, w - 60, 18);
    [page addSubview:hint];
    page.frame = NSMakeRect(0, 0, w, 460);
    return page;
}

- (NSView*)pageSearch {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 400)];
    NSString* q = _query ?: @"";
    _tracks = rlnative::search_tracks(std::string(q.UTF8String ?: ""), 500);
    NSString* sub = [NSString stringWithFormat:@"“%@” · %zu 个结果", q, _tracks.size()];
    [page addSubview:[self headerWithTitle:@"搜索结果" subtitle:sub actions:@[] width:w]];
    if (_tracks.empty()) {
        [page addSubview:[self emptyState:@"没有匹配的曲目" width:w]];
        page.frame = NSMakeRect(0, 0, w, 340);
        return page;
    }
    const CGFloat tableH = MIN((CGFloat)_tracks.size() * 42 + 8, 560);
    _trackTable = [self makeTable:NSMakeRect(0, 0, w - 40, tableH) rowHeight:42];
    _trackTable.doubleAction = @selector(trackDoubleClick:);
    _trackTable.target = self;
    [page addSubview:[self scrollForTable:_trackTable frame:NSMakeRect(20, 100, w - 40, tableH)]];
    page.frame = NSMakeRect(0, 0, w, 100 + tableH + 30);
    return page;
}

// ---------------------------------------------------------------------------
// 页面切换
// ---------------------------------------------------------------------------
- (void)showPage:(NMPage)p pushHistory:(BOOL)push {
    if (push && p != _page_) [_navStack addObject:@(_page_)];
    _page_ = p;
    _backButton.enabled = _navStack.count > 0;
    [self.window layoutIfNeeded];

    NSView* page = nil;
    switch (p) {
        case NMPageAlbums: page = [self pageAlbums]; break;
        case NMPageAlbumDetail: page = [self pageAlbumDetail]; break;
        case NMPageArtists: page = [self pageArtists]; break;
        case NMPageTracks: page = [self pageTracks]; break;
        case NMPageRecent: page = [self pageRecent]; break;
        case NMPageFavorites: page = [self pageFavorites]; break;
        case NMPageFolders: page = [self pageFolders]; break;
        case NMPageStreaming: page = [self pageStreaming]; break;
        case NMPageQueue: [self loadQueue]; page = [self pageQueue]; break;
        case NMPageSavedQueue: [self loadQueue]; page = [self pageSavedQueue]; break;
        case NMPageSearch: page = [self pageSearch]; break;
    }
    _contentScroll.documentView = page;
    if (p == NMPageFolders) [self refreshFoldersStats];
    [_contentScroll.contentView scrollToPoint:NSZeroPoint];
    [_contentScroll reflectScrolledClipView:_contentScroll.contentView];
    [self updateSidebarSelection];
}

- (void)windowDidResize:(NSNotification*)n {
    (void)n;
    // 网格列数依赖宽度：重建当前页（只重排，不重新请求数据）
    if (_page_ == NMPageAlbums || _page_ == NMPageArtists) [self showPage:_page_ pushHistory:NO];
}

// ---------------------------------------------------------------------------
// 命令：播放整页 / 专辑 / 队列
// ---------------------------------------------------------------------------
- (void)cmdPlayVisible:(id)s {
    (void)s;
    if (!_tracks.empty()) rlnative::play_path(_tracks.front().path);
}
- (void)cmdPlayAlbumAll:(id)s {
    (void)s;
    if (!g_detail.tracks.empty()) rlnative::play_album(g_detail.album.key, 0);
}
- (void)cmdShuffleAlbum:(id)s {
    (void)s;
    if (g_detail.tracks.empty()) return;
    // 用核心既有随机模式 + 从第一首起播，保持单一随机实现（不在 UI 里自造随机序列）
    rlnative::set_mode(3);
    rlnative::play_album(g_detail.album.key, 0);
}
- (void)cmdScanLibrary:(id)s { (void)s; rlnative::scan_library(false); [self refreshFoldersStats]; }
- (void)cmdRescanLibrary:(id)s { (void)s; rlnative::scan_library(true); [self refreshFoldersStats]; }
- (void)cmdSortQueue:(id)s { (void)s; rlnative::queue_sort_default(); [self loadQueue]; [self showPage:NMPageQueue pushHistory:NO]; }
- (void)cmdClearQueue:(id)s {
    (void)s;
    rlnative::queue_clear();
    [self loadQueue];
    [self reloadVisibleQueue];
}
- (void)cmdSaveQueue:(id)s {
    (void)s;
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"保存当前队列为歌单";
    a.informativeText = @"输入歌单名（同名覆盖）";
    [a addButtonWithTitle:@"保存"];
    [a addButtonWithTitle:@"取消"];
    NSTextField* input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    input.placeholderString = @"歌单名";
    a.accessoryView = input;
    if ([a runModal] == NSAlertFirstButtonReturn) {
        NSString* name = [input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (name.length) {
            rlnative::saved_queue_save(std::string(name.UTF8String));
            [self reloadSavedQueues];
        }
    }
}
- (void)queueDoubleClick:(id)s {
    const NSInteger row = _queueTable.clickedRow;
    if (row < 0) return;
    rlnative::queue_play_index((std::size_t)row);
}
- (void)railDoubleClick:(id)s {
    const NSInteger row = _railTable.clickedRow;
    if (row < 0) return;
    rlnative::queue_play_index((std::size_t)row);
}
- (void)trackDoubleClick:(id)s {
    (void)s;
    NSInteger row = _trackTable.clickedRow;
    if (row < 0) row = _trackTable.selectedRow;
    if (row < 0) return;
    if (_page_ == NMPageAlbumDetail) {
        rlnative::play_album(g_detail.album.key, (int)row);
        return;
    }
    if ((std::size_t)row < _tracks.size()) rlnative::play_path(_tracks[(size_t)row].path);
}
- (void)toggleFavInList:(NSButton*)sender {
    NSString* path = sender.identifier;
    if (path.length == 0) return;
    rlnative::favorite_toggle(std::string(path.UTF8String));
    const bool now = [sender.image.name isEqualToString:@"heart.fill"];
    sender.image = nm_symbol(now ? @"heart" : @"heart.fill", 13);
}

// ---------------------------------------------------------------------------
// 表格数据源
// ---------------------------------------------------------------------------
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv {
    if (tv == _npLyrics) return (NSInteger)_lyrics.size();
    if (tv == _railTable || tv == _queueTable) return (NSInteger)_queue.size();
    if (tv == _trackTable) {
        if (_page_ == NMPageAlbumDetail) return (NSInteger)g_detail.tracks.size();
        return (NSInteger)_tracks.size();
    }
    return 0;
}

- (NSTableCellView*)cellWithTitle:(NSString*)title sub:(NSString*)sub right:(NSString*)right width:(CGFloat)w {
    NSTableCellView* cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, w, 42)];
    NSTextField* t = nm_label(title, 12.5, NSFontWeightMedium, g_theme.text);
    t.frame = NSMakeRect(8, 5, w - 150, 17);
    [cell addSubview:t];
    if (sub.length) {
        NSTextField* s = nm_label(sub, 10.5, NSFontWeightRegular, g_theme.muted);
        s.frame = NSMakeRect(8, 23, w - 150, 14);
        [cell addSubview:s];
    }
    if (right.length) {
        NSTextField* r = nm_label(right, 10.5, NSFontWeightRegular, g_theme.muted);
        r.alignment = NSTextAlignmentRight;
        r.frame = NSMakeRect(w - 120, 12, 108, 16);
        [cell addSubview:r];
    }
    return cell;
}

- (NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
    const CGFloat w = tv.bounds.size.width;
    if (tv == _npLyrics) {
        NSTableCellView* cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, w, 34)];
        NSString* text = (row >= 0 && (std::size_t)row < _lyrics.size())
            ? [NSString stringWithUTF8String:_lyrics[(size_t)row].text.c_str()] : @"";
        NSTextField* l = nm_label(text, 15, (row == _activeLyricRow) ? NSFontWeightSemibold : NSFontWeightRegular,
                                  (row == _activeLyricRow) ? g_theme.accent : g_theme.text);
        l.alignment = NSTextAlignmentCenter;
        l.frame = NSMakeRect(10, 7, w - 20, 20);
        [cell addSubview:l];
        return cell;
    }
    if (tv == _railTable || tv == _queueTable) {
        if ((std::size_t)row >= _queue.size()) return nil;
        const auto& q = _queue[(size_t)row];
        NSString* title = q.title.empty() ? [[NSString stringWithUTF8String:q.path.c_str()] lastPathComponent] : [NSString stringWithUTF8String:q.title.c_str()];
        NSString* sub = q.artist.empty() ? @"" : [NSString stringWithUTF8String:q.artist.c_str()];
        NSTableCellView* cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, w, 44)];
        NSTextField* idx = nm_label([NSString stringWithFormat:@"%ld", (long)row + 1], 10, NSFontWeightRegular,
                                    ((std::size_t)row == _snap.index) ? g_theme.accent : g_theme.muted);
        idx.frame = NSMakeRect(4, 13, 22, 16);
        [cell addSubview:idx];
        NSTextField* t = nm_label(title, 12, NSFontWeightMedium,
                                  ((std::size_t)row == _snap.index) ? g_theme.accent : g_theme.text);
        t.frame = NSMakeRect(28, 4, w - 70, 18);
        [cell addSubview:t];
        NSTextField* a = nm_label(sub, 10, NSFontWeightRegular, g_theme.muted);
        a.frame = NSMakeRect(28, 22, w - 70, 14);
        [cell addSubview:a];
        return cell;
    }
    if (tv == _trackTable) {
        NSString* title = @""; NSString* sub = @""; NSString* dur = @""; NSString* qual = @"";
        NSString* path = @"";
        if (_page_ == NMPageAlbumDetail) {
            if ((std::size_t)row >= g_detail.tracks.size()) return nil;
            const auto& t = g_detail.tracks[(size_t)row];
            title = [NSString stringWithUTF8String:t.title.c_str()];
            sub = [NSString stringWithFormat:@"%s · %s", t.artist.c_str(), t.album.c_str()];
            dur = nm_time(t.dur);
            qual = nm_quality(t.sr, t.bits);
            path = [NSString stringWithUTF8String:t.path.c_str()];
        } else {
            if ((std::size_t)row >= _tracks.size()) return nil;
            const auto& t = _tracks[(size_t)row];
            title = [NSString stringWithUTF8String:t.title.c_str()];
            sub = [NSString stringWithFormat:@"%s · %s", t.artist.c_str(), t.album.c_str()];
            dur = nm_time(t.dur);
            qual = nm_quality(t.sr, t.bits);
            path = [NSString stringWithUTF8String:t.path.c_str()];
        }
        NSTableCellView* cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, w, 42)];
        NSTextField* idx = nm_label([NSString stringWithFormat:@"%ld", (long)row + 1], 10, NSFontWeightRegular, g_theme.muted);
        idx.frame = NSMakeRect(4, 12, 24, 16);
        [cell addSubview:idx];
        NSTextField* t = nm_label(title, 12.5, NSFontWeightMedium, g_theme.text);
        t.frame = NSMakeRect(30, 4, w - 190, 18);
        [cell addSubview:t];
        NSTextField* s = nm_label(sub, 10.5, NSFontWeightRegular, g_theme.muted);
        s.frame = NSMakeRect(30, 22, w - 190, 14);
        [cell addSubview:s];
        NSTextField* q = nm_label(qual, 9.5, NSFontWeightRegular, g_theme.muted);
        q.alignment = NSTextAlignmentRight;
        q.frame = NSMakeRect(w - 150, 12, 80, 16);
        [cell addSubview:q];
        NSTextField* d = nm_label(dur, 10.5, NSFontWeightRegular, g_theme.muted);
        d.alignment = NSTextAlignmentRight;
        d.frame = NSMakeRect(w - 64, 12, 40, 16);
        [cell addSubview:d];
        NSButton* fav = nm_symbol_button(@"heart", self, @selector(toggleFavInList:), @"收藏 / 取消收藏");
        fav.identifier = path;
        fav.frame = NSMakeRect(w - 34, 9, 24, 24);
        [cell addSubview:fav];
        return cell;
    }
    return nil;
}

// ---------------------------------------------------------------------------
// 集合视图数据源
// ---------------------------------------------------------------------------
- (NSInteger)collectionView:(NSCollectionView*)cv numberOfItemsInSection:(NSInteger)section {
    (void)section;
    if (cv != _albumGrid) return 0;
    if (_page_ == NMPageArtists) return (NSInteger)_artists.size();
    return (NSInteger)_albumsShown.size();
}

- (NSCollectionViewItem*)collectionView:(NSCollectionView*)cv itemForRepresentedObjectAtIndexPath:(NSIndexPath*)ip {
    if (_page_ == NMPageArtists) {
        NMArtistItem* item = [cv makeItemWithIdentifier:@"artist" forIndexPath:ip];
        const NSInteger i = ip.item;
        if (i >= 0 && (std::size_t)i < _artists.size()) {
            NSString* name = [NSString stringWithUTF8String:_artists[(size_t)i].first.c_str()];
            NSString* key = (std::size_t)i < _artistKeys.size()
                ? [NSString stringWithUTF8String:_artistKeys[(size_t)i].c_str()] : @"";
            [item configureName:name count:_artists[(size_t)i].second albumKey:key theme:g_theme];
        }
        return item;
    }
    NMAlbumItem* item = [cv makeItemWithIdentifier:@"album" forIndexPath:ip];
    const NSInteger i = ip.item;
    if (i >= 0 && (std::size_t)i < _albumsShown.size()) [item configure:_albumsShown[(size_t)i] theme:g_theme];
    return item;
}

- (void)collectionView:(NSCollectionView*)cv didSelectItemsAtIndexPaths:(NSSet<NSIndexPath*>*)paths {
    if (cv != _albumGrid) return;
    NSIndexPath* ip = paths.anyObject;
    if (!ip) return;
    if (_page_ == NMPageArtists) {
        if ((std::size_t)ip.item < _artistKeys.size()) {
            g_detail = rlnative::album_detail(_artistKeys[(size_t)ip.item]);
            [self showPage:NMPageAlbumDetail pushHistory:YES];
        }
        return;
    }
    if ((std::size_t)ip.item < _albumsShown.size()) {
        g_detail = rlnative::album_detail(_albumsShown[(size_t)ip.item].key);
        [self showPage:NMPageAlbumDetail pushHistory:YES];
    }
}

// 双击网格 = 播放整张专辑第一首
- (void)collectionView:(NSCollectionView*)cv didDoubleClickItemsAtIndexPaths:(NSSet<NSIndexPath*>*)paths {
    (void)cv; (void)paths;
}

// ---------------------------------------------------------------------------
// 搜索
// ---------------------------------------------------------------------------
- (void)controlTextDidChange:(NSNotification*)note {
    if (note.object != _searchField) return;
    _query = _searchField.stringValue;
    if (_query.length == 0) {
        [self showPage:NMPageAlbums pushHistory:NO];
        return;
    }
    [self showPage:NMPageSearch pushHistory:NO];
}

- (void)searchFieldDidEndSearching:(NSSearchField*)field {
    (void)field;
    _query = @"";
    [self showPage:NMPageAlbums pushHistory:NO];
}

// ---------------------------------------------------------------------------
// 正在播放
// ---------------------------------------------------------------------------
- (NSView*)buildNowPlaying {
    NSView* overlay = [[NSView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.wantsLayer = YES;
    overlay.layer.backgroundColor = g_theme.bg.CGColor;

    NSImageView* backdrop = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 700)];
    backdrop.imageScaling = NSImageScaleAxesIndependently;
    backdrop.alphaValue = 0.22;
    backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [overlay addSubview:backdrop];
    overlay.identifier = @"npOverlay";   // 用 identifier 找回 backdrop

    NSVisualEffectView* veil = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 700)];
    veil.material = NSVisualEffectMaterialUnderWindowBackground;
    veil.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    veil.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [overlay addSubview:veil];

    _npCover = [[NSImageView alloc] initWithFrame:NSMakeRect(90, 150, 300, 300)];
    _npCover.imageScaling = NSImageScaleProportionallyUpOrDown;
    _npCover.wantsLayer = YES;
    _npCover.layer.cornerRadius = 14;
    _npCover.layer.masksToBounds = YES;
    _npCover.layer.backgroundColor = g_theme.card.CGColor;
    _npCover.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [overlay addSubview:_npCover];

    _npTitle = nm_label(@"未播放", 26, NSFontWeightBold, g_theme.text);
    _npTitle.frame = NSMakeRect(90, 470, 460, 34);
    _npTitle.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [overlay addSubview:_npTitle];
    _npArtist = nm_label(@"", 15, NSFontWeightRegular, g_theme.muted);
    _npArtist.frame = NSMakeRect(92, 506, 460, 22);
    _npArtist.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [overlay addSubview:_npArtist];

    _npLyrics = [[NSTableView alloc] initWithFrame:NSMakeRect(560, 120, 420, 420)];
    _npLyrics.headerView = nil;
    _npLyrics.rowHeight = 34;
    _npLyrics.backgroundColor = [NSColor clearColor];
    _npLyrics.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _npLyrics.dataSource = self;
    _npLyrics.delegate = self;
    _npLyrics.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTableColumn* lc = [[NSTableColumn alloc] initWithIdentifier:@"lyric"];
    lc.width = 400;
    [_npLyrics addTableColumn:lc];
    NSScrollView* lscroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(560, 120, 420, 420)];
    lscroll.drawsBackground = NO;
    lscroll.hasVerticalScroller = YES;
    lscroll.scrollerStyle = NSScrollerStyleOverlay;
    lscroll.documentView = _npLyrics;
    lscroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    lscroll.identifier = @"npLyricsScroll";
    [overlay addSubview:lscroll];

    NSButton* close = nm_symbol_button(@"xmark", self, @selector(cmdCloseNowPlaying:), @"关闭正在播放");
    close.frame = NSMakeRect(960, 660, 28, 28);
    close.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [overlay addSubview:close];

    NSButton* prev = nm_symbol_button(@"backward.fill", self, @selector(dispatchCmd:), @"上一首");
    prev.tag = (NSInteger)Cmd::Previous;
    prev.frame = NSMakeRect(90, 60, 28, 28);
    [overlay addSubview:prev];
    NSButton* pp = [NSButton buttonWithImage:nm_symbol(@"play.fill", 20) target:self action:@selector(dispatchCmd:)];
    pp.tag = (NSInteger)Cmd::PlayPause;
    pp.bezelStyle = NSBezelStyleCircular;
    pp.bordered = NO;
    pp.wantsLayer = YES;
    pp.layer.cornerRadius = 22;
    pp.layer.backgroundColor = g_theme.accent.CGColor;
    pp.contentTintColor = NSColor.whiteColor;
    pp.frame = NSMakeRect(132, 52, 44, 44);
    [overlay addSubview:pp];
    NSButton* next = nm_symbol_button(@"forward.fill", self, @selector(dispatchCmd:), @"下一首");
    next.tag = (NSInteger)Cmd::Next;
    next.frame = NSMakeRect(190, 60, 28, 28);
    [overlay addSubview:next];
    return overlay;
}

- (void)toggleNowPlaying {
    _nowPlayingVisible = !_nowPlayingVisible;
    _nowPlayingOverlay.hidden = !_nowPlayingVisible;
    if (_nowPlayingVisible) [self refreshNowPlaying];
}

- (void)cmdCloseNowPlaying:(id)s {
    (void)s;
    _nowPlayingVisible = NO;
    _nowPlayingOverlay.hidden = YES;
}

- (void)refreshNowPlaying {
    NSString* path = _snap.current.empty() ? @"" : [NSString stringWithUTF8String:_snap.current.c_str()];
    NSString* title = path.length ? path.lastPathComponent.stringByDeletingPathExtension : @"未播放";
    NSString* artist = @"";
    for (const auto& q : _queue) if (q.path == _snap.current) {
        if (!q.title.empty()) title = [NSString stringWithUTF8String:q.title.c_str()];
        if (!q.artist.empty()) artist = [NSString stringWithUTF8String:q.artist.c_str()];
        break;
    }
    _npTitle.stringValue = title;
    _npArtist.stringValue = artist;
    NSImageView* backdrop = nil;
    for (NSView* v in _nowPlayingOverlay.subviews) if ([v.identifier isEqualToString:@"npOverlay"]) backdrop = (NSImageView*)v;
    _lyrics = rlnative::lyrics(_snap.current);
    [_npLyrics reloadData];
    _activeLyricRow = -1;
    if (path.length) {
        [self loadCoverForPath:path into:_npCover];
        if (backdrop) backdrop.image = _npCover.image;
    }
    [self syncLyricsToPos:_snap.pos];
}

- (void)syncLyricsToPos:(double)pos {
    if (_lyrics.empty()) return;
    NSInteger active = -1;
    for (size_t i = 0; i < _lyrics.size(); ++i) {
        if (_lyrics[i].t >= 0 && _lyrics[i].t <= pos) active = (NSInteger)i;
        else if (_lyrics[i].t > pos) break;
    }
    if (active == _activeLyricRow) return;
    _activeLyricRow = active;
    [_npLyrics reloadData];
    if (active >= 0) {
        [_npLyrics scrollRowToVisible:active];
    }
}

// ---------------------------------------------------------------------------
// 媒体键 / Now Playing 系统集成
// ---------------------------------------------------------------------------
- (void)setupMediaKeys {
    MPRemoteCommandCenter* cc = [MPRemoteCommandCenter sharedCommandCenter];
    __weak RLNativeAppDelegate* weakSelf = self;
    [cc.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent* e) {
        (void)e; rlnative::toggle_pause(); return MPRemoteCommandHandlerStatusSuccess;
    }];
    [cc.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent* e) {
        (void)e; rlnative::toggle_pause(); return MPRemoteCommandHandlerStatusSuccess;
    }];
    [cc.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent* e) {
        (void)e; rlnative::toggle_pause(); return MPRemoteCommandHandlerStatusSuccess;
    }];
    [cc.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent* e) {
        (void)e; rlnative::next_track(); return MPRemoteCommandHandlerStatusSuccess;
    }];
    [cc.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent* e) {
        (void)e; rlnative::previous_track(); return MPRemoteCommandHandlerStatusSuccess;
    }];
    [cc.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent* ev) {
        MPChangePlaybackPositionCommandEvent* e = (MPChangePlaybackPositionCommandEvent*)ev;
        RLNativeAppDelegate* s = weakSelf;
        if (s && s->_snap.dur > 0) rlnative::seek(e.positionTime / s->_snap.dur);
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)updateMediaKeys {
    NSMutableDictionary* info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = _barTitle.stringValue ?: @"RLPlayer";
    info[MPMediaItemPropertyArtist] = _barArtist.stringValue ?: @"";
    info[MPMediaItemPropertyPlaybackDuration] = @(_snap.dur);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(_snap.pos);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(_snap.playing && !_snap.paused ? 1.0 : 0.0);
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

// ---------------------------------------------------------------------------
// 设置窗口
// ---------------------------------------------------------------------------
- (NSTextField*)formLabel:(NSString*)text {
    NSTextField* l = nm_label(text, 12, NSFontWeightMedium, g_theme.muted);
    l.frame = NSMakeRect(0, 0, 140, 18);
    return l;
}

- (NSTextField*)formField:(NSString*)key width:(CGFloat)w {
    const auto it = _settings.find(std::string(key.UTF8String));
    NSTextField* f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, w, 24)];
    f.stringValue = it == _settings.end() ? @"" : [NSString stringWithUTF8String:it->second.c_str()];
    f.identifier = key;
    f.target = self;
    f.action = @selector(settingChanged:);
    f.font = [NSFont systemFontOfSize:12];
    f.delegate = self;
    return f;
}

- (NSPopUpButton*)formPopup:(NSString*)key values:(NSArray<NSString*>*)values titles:(NSArray<NSString*>*)titles width:(CGFloat)w {
    NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, w, 26) pullsDown:NO];
    for (NSUInteger i = 0; i < values.count; ++i) {
        [p addItemWithTitle:(i < titles.count ? titles[i] : values[i])];
        p.lastItem.representedObject = values[i];
    }
    const auto it = _settings.find(std::string(key.UTF8String));
    NSString* cur = it == _settings.end() ? @"" : [NSString stringWithUTF8String:it->second.c_str()];
    NSInteger idx = 0;
    for (NSInteger i = 0; i < p.numberOfItems; ++i) {
        if ([[p itemAtIndex:i].representedObject isEqualToString:cur]) { idx = i; break; }
    }
    [p selectItemAtIndex:idx];
    p.identifier = key;
    p.target = self;
    p.action = @selector(settingChanged:);
    return p;
}

- (NSView*)formRow:(NSString*)label control:(NSView*)control y:(CGFloat)y width:(CGFloat)w {
    NSView* row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, w, 34)];
    NSTextField* l = [self formLabel:label];
    l.frame = NSMakeRect(0, 8, 140, 18);
    [row addSubview:l];
    control.translatesAutoresizingMaskIntoConstraints = YES;
    control.frame = NSMakeRect(146, 4, w - 146, 26);
    [row addSubview:control];
    return row;
}

- (NSTabViewItem*)settingsTab:(NSString*)title rows:(NSArray<NSView*>*)rows {
    NSTabViewItem* item = [[NSTabViewItem alloc] initWithIdentifier:title];
    item.label = title;
    NMFlippedView* v = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 640, 380)];
    CGFloat y = 16;
    for (NSView* r in rows) {
        r.frame = NSMakeRect(24, y, 592, r.frame.size.height);
        [v addSubview:r];
        y += r.frame.size.height + 2;
    }
    item.view = v;
    return item;
}

- (void)openSettings {
    if (_settingsWindow) { [_settingsWindow makeKeyAndOrderFront:nil]; return; }
    [self reloadSettings];
    NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 480)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    w.title = @"设置";
    [w center];
    _settingsWindow = w;

    NSTabView* tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(16, 16, 668, 448)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSArray* appearance = @[
        [self formRow:@"主题色" control:[self formPopup:@"theme" values:@[@"light", @"dark", @"blue"] titles:@[@"白色（默认）", @"深色", @"浅蓝色"] width:200] y:0 width:592],
        [self formRow:@"语言" control:[self formPopup:@"lang" values:@[@"zh", @"en"] titles:@[@"中文", @"English"] width:200] y:0 width:592],
        [self formRow:@"说明" control:nm_label(@"原生界面目前为中文；语言设置影响网页界面。", 11, NSFontWeightRegular, g_theme.muted) y:0 width:592],
    ];
    NSArray* output = @[
        [self formRow:@"输出后端" control:[self formPopup:@"backend" values:@[@"coreaudio", @"hog", @"null", @"upnp"] titles:@[@"CoreAudio", @"独占 (Hog)", @"静音 (null)", @"UPnP 投放"] width:200] y:0 width:592],
        [self formRow:@"输出设备" control:[self formField:@"device" width:360] y:0 width:592],
        [self formRow:@"缓冲 (ms)" control:[self formField:@"buffer" width:120] y:0 width:592],
        [self formRow:@"音量 (dB)" control:[self formField:@"volume" width:120] y:0 width:592],
    ];
    NSArray* pcm = @[
        [self formRow:@"目标采样率" control:[self formField:@"rate" width:160] y:0 width:592],
        [self formRow:@"滤波器" control:[self formField:@"filter" width:260] y:0 width:592],
        [self formRow:@"taps" control:[self formField:@"taps" width:120] y:0 width:592],
        [self formRow:@"衰减 (dB)" control:[self formField:@"atten" width:120] y:0 width:592],
        [self formRow:@"相位" control:[self formField:@"phase" width:160] y:0 width:592],
        [self formRow:@"噪声整形" control:[self formField:@"shaper" width:200] y:0 width:592],
    ];
    NSArray* dsd = @[
        [self formRow:@"DSD 开关" control:[self formPopup:@"dsd" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:592],
        [self formRow:@"调制器阶数" control:[self formField:@"modorder" width:120] y:0 width:592],
        [self formRow:@"调制器族" control:[self formField:@"modfamily" width:160] y:0 width:592],
        [self formRow:@"DirectSDM" control:[self formPopup:@"directsdm" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:592],
        [self formRow:@"DSD 类型" control:[self formField:@"dsdkind" width:160] y:0 width:592],
        [self formRow:@"DSD 转换" control:[self formField:@"dsdconv" width:160] y:0 width:592],
    ];
    NSArray* library = @[
        [self formRow:@"资料库" control:nm_label(@"在「文件夹」页查看统计并触发增量/全量扫描。", 12, NSFontWeightRegular, g_theme.muted) y:0 width:592],
        [self formRow:@"EQ 预设" control:[self formField:@"eq" width:360] y:0 width:592],
        [self formRow:@"卷积 IR" control:[self formField:@"ir" width:360] y:0 width:592],
    ];
    NSArray* about = @[
        [self formRow:@"版本" control:nm_label([NSString stringWithFormat:@"%s（arm64）", RLPLAYER_VERSION_STR], 12, NSFontWeightMedium, g_theme.text) y:0 width:592],
        [self formRow:@"更新通道" control:[self formPopup:@"updatechannel" values:@[@"global", @"china"] titles:@[@"全球通道（GitHub）", @"中国大陆通道"] width:220] y:0 width:592],
        [self formRow:@"许可" control:nm_label(@"GPL-3.0-or-later · 上游 rainlain / macOS BH2VOQ", 12, NSFontWeightRegular, g_theme.muted) y:0 width:592],
    ];

    [tabs addTabViewItem:[self settingsTab:@"外观" rows:appearance]];
    [tabs addTabViewItem:[self settingsTab:@"输出" rows:output]];
    [tabs addTabViewItem:[self settingsTab:@"升频 (PCM)" rows:pcm]];
    [tabs addTabViewItem:[self settingsTab:@"DSD" rows:dsd]];
    [tabs addTabViewItem:[self settingsTab:@"资料库与 EQ" rows:library]];
    [tabs addTabViewItem:[self settingsTab:@"更新与关于" rows:about]];
    w.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 480)];
    [w.contentView addSubview:tabs];
    [w makeKeyAndOrderFront:nil];
}

- (void)settingChanged:(id)sender {
    NSString* key = [sender identifier];
    if (key.length == 0) return;
    NSString* value = nil;
    if ([sender isKindOfClass:[NSPopUpButton class]]) {
        NSPopUpButton* p = sender;
        value = [p.selectedItem representedObject] ?: p.titleOfSelectedItem;
        if ([key isEqualToString:@"theme"]) {
            std::string theme(value.UTF8String ?: "light");
            rlnative::set_theme(theme);
            nm_set_theme_by_name(value);
            _themeIndex = [value isEqualToString:@"dark"] ? 0 : [value isEqualToString:@"blue"] ? 2 : 1;
            [self applyThemeToViews];
            return;
        } else if ([key isEqualToString:@"updatechannel"]) {
            std::string err;
            rta::update::set_update_channel(std::string(value.UTF8String ?: "global"), err);
            return;
        }
    } else if ([sender isKindOfClass:[NSTextField class]]) {
        value = ((NSTextField*)sender).stringValue;
    }
    if (value.length == 0) return;
    rlnative::settings_save({{std::string(key.UTF8String), std::string(value.UTF8String)}});
}

- (void)controlTextDidEndEditing:(NSNotification*)note {
    if (note.object == _searchField) return;
    if ([note.object isKindOfClass:[NSTextField class]]) [self settingChanged:note.object];
}

- (void)applyThemeToViews {
    _window.appearance = [NSAppearance appearanceNamed:(_themeIndex == 0 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)];
    _window.backgroundColor = g_theme.bg;
    if (_playerBar) {
        _playerBar.layer.borderColor = g_theme.separator.CGColor;
        _playerBar.needsDisplay = YES;
    }
    if (_queueRail) {
        _queueRail.layer.borderColor = g_theme.separator.CGColor;
        _queueRail.needsDisplay = YES;
    }
    [_contentScroll.documentView setNeedsDisplay:YES];
    [self showPage:_page_ pushHistory:NO];
}

// ---------------------------------------------------------------------------
// 更新窗口
// ---------------------------------------------------------------------------
- (void)openUpdateWindow {
    if (_updateWindow) { [_updateWindow makeKeyAndOrderFront:nil]; return; }
    NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 340)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    w.title = @"软件更新";
    [w center];
    _updateWindow = w;
    NSView* v = w.contentView;

    NSTextField* cur = nm_label([NSString stringWithFormat:@"当前版本：%s · arm64", RLPLAYER_VERSION_STR], 13, NSFontWeightSemibold, g_theme.text);
    cur.frame = NSMakeRect(24, 296, 460, 20);
    [v addSubview:cur];

    _updateStatus = nm_label(@"尚未检查更新", 12, NSFontWeightRegular, g_theme.muted);
    _updateStatus.frame = NSMakeRect(24, 150, 460, 120);
    _updateStatus.maximumNumberOfLines = 6;
    _updateStatus.lineBreakMode = NSLineBreakByWordWrapping;
    [v addSubview:_updateStatus];

    _updateProgress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 128, 460, 14)];
    _updateProgress.style = NSProgressIndicatorStyleBar;
    _updateProgress.indeterminate = NO;
    _updateProgress.minValue = 0; _updateProgress.maxValue = 1;
    _updateProgress.hidden = YES;
    [v addSubview:_updateProgress];

    NSButton* check = [NSButton buttonWithTitle:@"检查更新" target:self action:@selector(doUpdateCheck:)];
    check.bezelStyle = NSBezelStyleRounded;
    check.frame = NSMakeRect(24, 60, 110, 30);
    [v addSubview:check];
    _updateAction = [NSButton buttonWithTitle:@"下载并安装" target:self action:@selector(doUpdateInstall:)];
    _updateAction.bezelStyle = NSBezelStyleRounded;
    _updateAction.frame = NSMakeRect(144, 60, 140, 30);
    _updateAction.enabled = NO;
    [v addSubview:_updateAction];
    NSButton* close = [NSButton buttonWithTitle:@"关闭" target:self action:@selector(closeUpdateWindow:)];
    close.bezelStyle = NSBezelStyleRounded;
    close.frame = NSMakeRect(390, 60, 100, 30);
    [v addSubview:close];
    [w makeKeyAndOrderFront:nil];
}

- (void)closeUpdateWindow:(id)s { (void)s; [_updateWindow orderOut:nil]; }

static rta::update::CheckResult g_updatePlan;

- (void)doUpdateCheck:(id)s {
    (void)s;
    _updateStatus.stringValue = @"正在检查更新…";
    _updateAction.enabled = NO;
    _updateProgress.hidden = NO;
    _updateProgress.indeterminate = YES;
    [_updateProgress startAnimation:nil];
    __weak RLNativeAppDelegate* weakSelf = self;
    rta::update::begin_check(^(const rta::update::NativeProgress& p) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RLNativeAppDelegate* s = weakSelf;
            if (!s) return;
            s.updateStatus.stringValue = [NSString stringWithFormat:@"%s%s%s", p.stage.c_str(),
                                          p.detail.empty() ? "" : " · ", p.detail.c_str()];
        });
    }, ^(const rta::update::CheckResult& r) {
        g_updatePlan = r;
        dispatch_async(dispatch_get_main_queue(), ^{
            RLNativeAppDelegate* s = weakSelf;
            if (!s) return;
            [s.updateProgress stopAnimation:nil];
            s.updateProgress.hidden = YES;
            if (r.up_to_date()) {
                s.updateStatus.stringValue = @"已是最新版本。";
                s.updateAction.enabled = NO;
            } else if (r.available()) {
                NSString* notes = [NSString stringWithUTF8String:r.notes.c_str()];
                s.updateStatus.stringValue = [NSString stringWithFormat:@"发现新版本 %s\n\n%@",
                                              r.remoteVersion.c_str(), notes.length ? notes : @"（无更新说明）"];
                s.updateAction.enabled = YES;
            } else {
                s.updateStatus.stringValue = [NSString stringWithFormat:@"检查失败：%s%s",
                                              r.error.c_str(), r.status ? [NSString stringWithFormat:@" (HTTP %d)", r.status].UTF8String : ""];
                s.updateAction.enabled = NO;
            }
        });
    });
}

- (void)doUpdateInstall:(id)s {
    (void)s;
    if (!g_updatePlan.available()) return;
    _updateAction.enabled = NO;
    _updateStatus.stringValue = @"开始下载并安装…";
    _updateProgress.hidden = NO;
    _updateProgress.indeterminate = NO;
    _updateProgress.doubleValue = 0;
    __weak RLNativeAppDelegate* weakSelf = self;
    rta::update::begin_install(g_updatePlan, ^(const rta::update::NativeProgress& p) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RLNativeAppDelegate* s = weakSelf;
            if (!s) return;
            s.updateStatus.stringValue = [NSString stringWithFormat:@"%s%s%s", p.stage.c_str(),
                                          p.detail.empty() ? "" : " · ", p.detail.c_str()];
            if (p.percent >= 0) s.updateProgress.doubleValue = p.percent / 100.0;
        });
    }, ^(bool ok, NSString* message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RLNativeAppDelegate* s = weakSelf;
            if (!s) return;
            s.updateProgress.hidden = YES;
            s.updateStatus.stringValue = message ?: (ok ? @"安装完成" : @"安装失败");
        });
    });
}

// ---------------------------------------------------------------------------
// 入口：由 tools/mac_host.mm 在 RLPLAYER_UI=native 时调用
// ---------------------------------------------------------------------------
@end

static RLNativeAppDelegate* g_nativeDelegate = nil;

int rlnative_start(void) {
    @autoreleasepool {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            g_nativeDelegate = [[RLNativeAppDelegate alloc] init];
            [g_nativeDelegate applicationDidFinishLaunching:nil];
        });
    }
    return 1;
}

int rlnative_should_terminate(void) { return 0; }
