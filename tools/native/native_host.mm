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
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include "native/core_bridge.h"
#include "native/native_host.h"
#include "mac_feedback.h"
#include "mac_update.h"
#include "net/i18n_table.h"
#include "net/json.h"
#include "net/webui.h"
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
// ⚠️ Theme 里是 __unsafe_unretained 颜色指针（ARC 不允许 C++ 结构里强引用对象），
// 必须额外强持有这些 NSColor，否则自动释放池一空就变悬垂指针 —— 实测崩溃表现为
// -[NSConcretePointerArray CGColor] unrecognized selector（随机对象收到 CGColor）。
static Theme g_theme;
static NSArray<NSColor*>* g_themeKeepAlive = nil;
static void nm_set_theme_by_name(NSString* name) {
    Theme t;
    if ([name isEqualToString:@"dark"]) t = theme_dark();
    else if ([name isEqualToString:@"blue"]) t = theme_blue();
    else t = theme_light();
    g_themeKeepAlive = @[t.bg, t.sidebar, t.content, t.card, t.text, t.muted,
                         t.accent, t.separator, t.selection, t.playerBar, t.hover, t.badge];
    g_theme = t;
}
static Theme nm_theme(void) { return g_theme; }

// NSControl/NSImageView 在成为 layer-backed 之前，-layer 可能返回私有代理对象；
// 直接给 .layer 属性赋值会抛 -[NSControlAuxiliary CGColor] unrecognized selector（真实崩溃）。
// 统一走这个守卫：只有拿到真正的 CALayer 才设置，绝不假定 -layer 的类型。
static void nm_layer_config(NSView* v, void (^cfg)(CALayer*)) {
    if (!v || !cfg) return;
    [v setWantsLayer:YES];
    id l = v.layer;
    if ([l isKindOfClass:[CALayer class]]) cfg((CALayer*)l);
}
static void nm_round_view(NSView* v, CGFloat radius, NSColor* bg) {
    nm_layer_config(v, ^(CALayer* l) {
        l.cornerRadius = radius;
        l.masksToBounds = YES;
        if (bg) l.backgroundColor = bg.CGColor;
    });
}
static void nm_set_background(NSView* v, NSColor* bg) {
    nm_layer_config(v, ^(CALayer* l) { l.backgroundColor = bg.CGColor; });
}
static void nm_set_border(NSView* v, CGFloat width, NSColor* color) {
    nm_layer_config(v, ^(CALayer* l) { l.borderWidth = width; l.borderColor = color.CGColor; });
}

// ---------------------------------------------------------------------------
// 语言：复用 1.1.6 的 i18n 词表（中文源串 → 英文），再加原生界面补充词条。
// 界面字符串仍以中文为源；切英文时对已建好的视图树做一次精确匹配替换，重建页面时再翻一次。
// ---------------------------------------------------------------------------
static BOOL g_langEn = NO;
static NSDictionary<NSString*, NSString*>* g_i18nDict(void) {
    static NSMutableDictionary* d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [NSMutableDictionary dictionary];
        std::size_t n = 0;
        const auto* table = rta::net::i18n_table(&n);
        for (std::size_t i = 0; i < n; ++i) {
            NSString* zh = [NSString stringWithUTF8String:table[i].zh];
            NSString* en = [NSString stringWithUTF8String:table[i].en];
            if (zh && en) d[zh] = en;
        }
        NSDictionary* extra = @{
            @"快速开始": @"Quick Start", @"资料库": @"Library", @"播放列表": @"Playlists",
            @"音频引擎": @"Audio Engine", @"正在播放": @"Now Playing", @"音频分析": @"Audio Analysis",
            @"曲目信息": @"Track Info", @"分析当前曲目": @"Analyze Current Track",
            @"尚未分析": @"Not analyzed", @"立即播放": @"Play Now", @"从队列删除": @"Remove from Queue",
            @"上移": @"Move Up", @"下移": @"Move Down", @"在 Finder 中显示": @"Reveal in Finder",
            @"复制文件路径": @"Copy File Path", @"载入": @"Load", @"重命名…": @"Rename…",
            @"服务器配置": @"Server Settings", @"上一级": @"Up", @"刷新": @"Refresh",
            @"增量扫描": @"Scan", @"全量重扫": @"Full Rescan", @"看看刚听过的曲目": @"Recently played",
            @"生成 zip 供排查": @"Export diagnostics zip", @"邮件 + 诊断附件": @"Email + diagnostics",
            @"播放全部": @"Play All", @"随机播放": @"Shuffle", @"返回": @"Back",
            @"当前播放": @"Now Playing", @"收藏 / 取消收藏": @"Favorite / Unfavorite",
            @"重置缓冲": @"Reset Buffer", @"复位缓冲 (buffer/reset)": @"Reset Buffer (buffer/reset)",
            @"导出诊断 zip": @"Export diagnostics zip", @"撰写反馈邮件（附诊断）": @"Compose feedback email",
            @"开始测量（会发声）": @"Start measurement (audible)", @"取消测量": @"Cancel measurement",
            @"开始采集": @"Start capture", @"停止采集": @"Stop capture", @"开始投放当前曲目": @"Cast current track",
            @"停止投放": @"Stop casting", @"重新扫描设备": @"Rescan devices",
            @"分析当前曲目（CPU 密集）": @"Analyze current track (CPU heavy)",
            @"补全当前曲目元数据": @"Enrich current track metadata",
            @"打开流媒体浏览页": @"Open streaming browser", @"保存并测试连接": @"Save & test connection",
            @"搜索 OPRA 预设": @"Search OPRA presets", @"应用所选 OPRA 预设": @"Apply selected OPRA preset",
            @"保存 PEQ": @"Save PEQ", @"设为默认": @"Set as default",
            @"诊断包": @"Diagnostics bundle", @"反馈": @"Feedback", @"关于": @"About",
            @"通用": @"General", @"输出": @"Output", @"升频 (PCM)": @"Upsampling (PCM)", @"DSD": @"DSD",
            @"PEQ / EQ": @"PEQ / EQ", @"耳机 EQ (OPRA)": @"Headphone EQ (OPRA)", @"流媒体": @"Streaming",
            @"分析 / AI": @"Analysis / AI", @"设备投放": @"Cast Devices", @"输入采集": @"Input Capture",
            @"房间校正": @"Room Correction", @"更新": @"Updates", @"诊断与反馈": @"Diagnostics & Feedback",
        };
        [d addEntriesFromDictionary:extra];
    });
    return d;
}
static NSString* NMTR(NSString* zh) {
    if (!g_langEn || zh.length == 0) return zh;
    NSString* en = g_i18nDict()[zh];
    return en.length ? en : zh;
}
static void nm_translate_menu(NSMenu* menu) {
    if (!g_langEn || !menu) return;
    for (NSMenuItem* it in menu.itemArray) {
        if (it.title.length) it.title = NMTR(it.title);
        if (it.submenu) nm_translate_menu(it.submenu);
    }
}
static void nm_translate_view(NSView* v) {
    if (!g_langEn || !v) return;
    if ([v isKindOfClass:[NSTextField class]]) {
        NSTextField* t = (NSTextField*)v;
        if (t.stringValue.length) t.stringValue = NMTR(t.stringValue);
        if (t.placeholderString.length) t.placeholderString = NMTR(t.placeholderString);
    } else if ([v isKindOfClass:[NSButton class]]) {
        NSButton* b = (NSButton*)v;
        if (b.title.length) b.title = NMTR(b.title);
        if (b.toolTip.length) b.toolTip = NMTR(b.toolTip);
    } else if ([v isKindOfClass:[NSPopUpButton class]]) {
        NSPopUpButton* p = (NSPopUpButton*)v;
        for (NSMenuItem* it in p.itemArray) if (it.title.length) it.title = NMTR(it.title);
    } else if ([v isKindOfClass:[NSTableView class]]) {
        [(NSTableView*)v reloadData];
    }
    for (NSView* sub in v.subviews) nm_translate_view(sub);
}

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
    ShowRecent, ShowFavorites, ShowFolders, ShowStreaming, ShowStation, Rescan, Scan,
    PlayAlbum, ToggleLyrics, OpenCast, OpenInput, OpenRoom, ExportDiag, SendFeedback, ToggleMini,
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
    NMPageQueue, NMPageSavedQueue, NMPageSearch, NMPageStation, NMPageArtistDetail, NMPageRemoteDetail,
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
@property (nonatomic, strong) NSTableView* filesTable;
@property (nonatomic, strong) NSTableView* remoteTable;
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
@property (nonatomic, copy) NSString* filesPath;
@property (nonatomic, copy) NSString* remotePath;
@property (nonatomic, copy) NSString* artistWho;
@property (nonatomic, strong) NSMutableArray<NSString*>* remoteTrail;
@property (nonatomic, copy) NSString* remoteQuery;
@property (nonatomic, strong) NSWindow* miniPlayer;
@property (nonatomic, strong) NSTableView* settingsSections;
@property (nonatomic, strong) NSMutableArray<NSView*>* settingsPages;
@property (nonatomic, assign) NSInteger settingsSectionIndex;
@property (nonatomic, strong) NSScrollView* settingsScroll;
@property (nonatomic, strong) NSView* npAnalysisPanel;
@property (nonatomic, strong) NSView* npInfoPanel;
@property (nonatomic, strong) NSTextField* npInfoLabel;
@property (nonatomic, strong) NSTextField* npAnalysisLabel;
@property (nonatomic, strong) NSPopUpButton* settingsDevicePopup;
@property (nonatomic, strong) NSPopUpButton* settingsCastPopup;
@property (nonatomic, strong) NSPopUpButton* settingsInputPopup;
@property (nonatomic, strong) NSTextView* settingsPeqEditor;
@property (nonatomic, strong) NSTableView* settingsPresetTable;
@property (nonatomic, strong) NSMutableArray<NSString*>* settingsPresets;
@property (nonatomic, strong) NSMutableArray<NSString*>* folderNames;
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

@interface NMPeqCurveView : NSView
@property (nonatomic, assign) std::vector<std::pair<double, double>> points;
@end
@implementation NMPeqCurveView
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [[g_theme.card colorWithAlphaComponent:0.6] setFill];
    NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8];
    [bg fill];
    if (_points.size() < 2) return;
    double mn = 0, mx = 0;
    for (const auto& p : _points) { mn = std::min(mn, p.second); mx = std::max(mx, p.second); }
    mn = std::min(mn, -6.0); mx = std::max(mx, 6.0);
    NSBezierPath* path = [NSBezierPath bezierPath];
    for (size_t i = 0; i < _points.size(); ++i) {
        const double x = self.bounds.size.width * (double)i / (double)(_points.size() - 1);
        const double y = self.bounds.size.height * (_points[i].second - mn) / (mx - mn);
        if (i == 0) [path moveToPoint:NSMakePoint(x, y)];
        else [path lineToPoint:NSMakePoint(x, y)];
    }
    [g_theme.accent setStroke];
    path.lineWidth = 1.8;
    [path stroke];
    [[g_theme.separator colorWithAlphaComponent:0.5] setStroke];
    NSBezierPath* zero = [NSBezierPath bezierPath];
    const double zy = self.bounds.size.height * (0 - mn) / (mx - mn);
    [zero moveToPoint:NSMakePoint(0, zy)];
    [zero lineToPoint:NSMakePoint(self.bounds.size.width, zy)];
    [zero stroke];
}
@end

@implementation NMAlbumItem
- (void)loadView {
    NSView* v = [[NSView alloc] init];
    v.wantsLayer = YES;
    self.view = v;
    _cover = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 158, 158)];
    _cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    nm_round_view(_cover, 10, g_theme.card);
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
    nm_round_view(_cover, 48, g_theme.card);
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
    std::vector<rlnative::RemoteEntry> _remoteItems;
    std::vector<rlnative::AlbumDetail> _artistAlbums;
    std::vector<rlnative::PeqBand> _peqBands;
    std::vector<rlnative::CastDevice> _castDevices;
    std::vector<rlnative::DeviceInfo> _outputDevices;
    std::vector<rlnative::DeviceInfo> _inputDevices;
    std::string _filesDir;
    std::map<std::string,std::string> _uiValues;
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
        _remoteTrail = [NSMutableArray array];
        _settingsPresets = [NSMutableArray array];
        _settingsPages = [NSMutableArray array];
        _folderNames = [NSMutableArray array];
    }
    return self;
}

// ---------------------------------------------------------------------------
// 启动 / 退出
// ---------------------------------------------------------------------------
- (void)applicationDidFinishLaunching:(NSNotification*)n {
    (void)n;
    const auto settings0 = rlnative::settings();
    const auto langIt = settings0.find("lang");
    g_langEn = (langIt != settings0.end() && langIt->second == "en");
    const std::string theme = rlnative::get_theme();
    nm_set_theme_by_name([NSString stringWithUTF8String:theme.c_str()]);
    if (theme == "dark") _themeIndex = 0;
    else if (theme == "blue") _themeIndex = 2;
    else _themeIndex = 1;
    _window.appearance = [NSAppearance appearanceNamed:(_themeIndex == 0 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)];

    [self buildMenu];
    [self buildWindow];
    if (g_langEn) { nm_translate_menu(NSApp.mainMenu); nm_translate_view(self.window.contentView); }
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
        NSSetUncaughtExceptionHandler([](NSException* e) {
            std::fprintf(stderr, "SELFTEST uncaught %s: %s\n",
                         e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
            std::fflush(stderr);
        });
        if (s.window.contentView) scan(s.window.contentView);
        // 页面级自检：逐个切页并打开设置各分区，任何一步抛异常/空页都算失败。
        NSInteger pageFails = 0;
        NSArray<NSNumber*>* pages = @[@(NMPageAlbums), @(NMPageArtists), @(NMPageTracks),
            @(NMPageRecent), @(NMPageFavorites), @(NMPageFolders), @(NMPageStreaming),
            @(NMPageQueue), @(NMPageStation), @(NMPageSearch)];
        for (NSNumber* pn in pages) {
            @try {
                [s showPage:(NMPage)pn.integerValue pushHistory:NO];
                if (!s.contentScroll.documentView) pageFails++;
            } @catch (NSException* e) {
                std::fprintf(stderr, "SELFTEST page exception %ld: %s / %s\n", (long)pn.integerValue,
                             e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
                std::fflush(stderr);
                pageFails++;
            }
        }
        NSInteger sectionFails = 0;
        @try {
            [s openSettings];
            for (NSInteger i = 0; i < 15; ++i) {
                @try { [s showSettingsSection:i]; if (!s.settingsScroll.documentView) sectionFails++;
                }
                @catch (NSException* e) {
                    std::fprintf(stderr, "SELFTEST section exception %ld: %s / %s\n", (long)i,
                                 e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
                    std::fflush(stderr);
                    sectionFails++;
                }
            }
        } @catch (NSException* e) { (void)e; sectionFails = 15; }
        // 收尾回到专辑页，避免自检改变最终界面
        [s showPage:NMPageAlbums pushHistory:NO];

        NSMutableArray<NSNumber*>* checks = [NSMutableArray array];
        [checks addObject:@(s.window != nil && s.window.visible)];
        [checks addObject:@(s.sidebar != nil && s.sidebar.superview != nil)];
        [checks addObject:@(s.playerBar != nil && s.playerBar.superview != nil)];
        [checks addObject:@(s.queueRail != nil && s.queueRail.superview != nil)];
        [checks addObject:@(s.contentScroll.documentView != nil)];
        [checks addObject:@(webviews == 0)];
        [checks addObject:@(pageFails == 0)];
        [checks addObject:@(sectionFails == 0)];
        NSInteger pass = 0;
        for (NSNumber* n in checks) if (n.boolValue) pass++;
        std::fprintf(stderr,
                     "NATIVE_SELFTEST {\"pass\":%ld,\"total\":%lu,\"window\":%s,"
                     "\"sidebar\":%s,\"player\":%s,\"queue\":%s,\"page\":%s,"
                     "\"webviews\":%ld,\"albums\":%zu,\"queueItems\":%zu,"
                     "\"pageFails\":%ld,\"sectionFails\":%ld}\n",
                     (long)pass, (unsigned long)checks.count,
                     (s.window && s.window.visible) ? "true" : "false",
                     (s.sidebar.superview != nil) ? "true" : "false",
                     (s.playerBar.superview != nil) ? "true" : "false",
                     (s.queueRail.superview != nil) ? "true" : "false",
                     (s.contentScroll.documentView != nil) ? "true" : "false",
                     (long)webviews, s->_albums.size(), s->_queue.size(),
                     (long)pageFails, (long)sectionFails);
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

    NSMenuItem* helpItem = [[NSMenuItem alloc] initWithTitle:@"帮助" action:nil keyEquivalent:@""];
    NSMenu* help = [[NSMenu alloc] initWithTitle:@"帮助"];
    NSMenuItem* shortcuts = [help addItemWithTitle:@"键盘快捷键" action:@selector(cmdShowShortcuts:) keyEquivalent:@"/"];
    shortcuts.target = self;
    [help addItem:[NSMenuItem separatorItem]];
    NSMenuItem* fb = [help addItemWithTitle:@"反馈问题…" action:@selector(dispatchCmd:) keyEquivalent:@""];
    fb.target = self; fb.tag = (NSInteger)Cmd::SendFeedback;
    NSMenuItem* diag = [help addItemWithTitle:@"导出诊断包" action:@selector(dispatchCmd:) keyEquivalent:@""];
    diag.target = self; diag.tag = (NSInteger)Cmd::ExportDiag;
    [help addItem:[NSMenuItem separatorItem]];
    [help addItemWithTitle:@"关于 RLPlayer" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    helpItem.submenu = help;
    [bar addItem:helpItem];

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
    nm_round_view(b, 7.0, nil);
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

    [stack addArrangedSubview:[self sideRow:@"快速开始" symbol:@"sparkles" tag:(NSInteger)Cmd::ShowStation indent:NO]];
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
        nm_set_background(b, on ? g_theme.selection : nil);
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
        case NMPageStation: return (NSInteger)Cmd::ShowStation;
        case NMPageArtistDetail: return (NSInteger)Cmd::ShowArtists;
        case NMPageRemoteDetail: return (NSInteger)Cmd::ShowStreaming;
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
    nm_set_border(bar, 1.0, g_theme.separator);

    // 左：封面 + 信息
    _barCover = [[NSImageView alloc] init];
    _barCover.translatesAutoresizingMaskIntoConstraints = NO;
    _barCover.imageScaling = NSImageScaleProportionallyUpOrDown;
    nm_round_view(_barCover, 6.0, g_theme.card);
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
    nm_round_view(_barPlay, 17, g_theme.accent);
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
    NSButton* lyricsBtn = nm_symbol_button(@"quote.bubble", self, @selector(dispatchCmd:), @"歌词 / 正在播放");
    lyricsBtn.tag = (NSInteger)Cmd::ToggleLyrics;
    NSButton* queueBtn = nm_symbol_button(@"list.bullet", self, @selector(dispatchCmd:), @"显示 / 隐藏队列");
    queueBtn.tag = (NSInteger)Cmd::ToggleQueueRail;
    NSButton* miniBtn = nm_symbol_button(@"pip", self, @selector(dispatchCmd:), @"迷你播放器");
    miniBtn.tag = (NSInteger)Cmd::ToggleMini;
    NSButton* castBtn = nm_symbol_button(@"airplayvideo", self, @selector(dispatchCmd:), @"投放到设备");
    castBtn.tag = (NSInteger)Cmd::OpenCast;
    [bar addSubview:lyricsBtn];
    [bar addSubview:queueBtn];
    [bar addSubview:miniBtn];
    [bar addSubview:castBtn];
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
        [lyricsBtn.trailingAnchor constraintEqualToAnchor:volIcon.leadingAnchor constant:-4],
        [lyricsBtn.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [queueBtn.trailingAnchor constraintEqualToAnchor:lyricsBtn.leadingAnchor constant:-2],
        [queueBtn.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [miniBtn.trailingAnchor constraintEqualToAnchor:queueBtn.leadingAnchor constant:-2],
        [miniBtn.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [castBtn.trailingAnchor constraintEqualToAnchor:miniBtn.leadingAnchor constant:-2],
        [castBtn.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];

    return bar;
}

// ---------------------------------------------------------------------------
// 队列栏
// ---------------------------------------------------------------------------
- (NSMenu*)queueMenu {
    NSMenu* m = [[NSMenu alloc] init];
    NSMenuItem* play = [m addItemWithTitle:@"立即播放" action:@selector(queuePlayNow:) keyEquivalent:@""];
    play.target = self;
    NSMenuItem* del = [m addItemWithTitle:@"从队列删除" action:@selector(queueDelete:) keyEquivalent:@""];
    del.target = self;
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem* up = [m addItemWithTitle:@"上移" action:@selector(queueMoveUp:) keyEquivalent:@""];
    up.target = self;
    NSMenuItem* down = [m addItemWithTitle:@"下移" action:@selector(queueMoveDown:) keyEquivalent:@""];
    down.target = self;
    return m;
}

- (NSMenu*)trackMenu {
    NSMenu* m = [[NSMenu alloc] init];
    NSMenuItem* play = [m addItemWithTitle:@"播放" action:@selector(trackPlayMenu:) keyEquivalent:@""];
    play.target = self;
    NSMenuItem* fav = [m addItemWithTitle:@"收藏 / 取消收藏" action:@selector(trackFavMenu:) keyEquivalent:@""];
    fav.target = self;
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem* reveal = [m addItemWithTitle:@"在 Finder 中显示" action:@selector(trackRevealMenu:) keyEquivalent:@""];
    reveal.target = self;
    NSMenuItem* copy = [m addItemWithTitle:@"复制文件路径" action:@selector(trackCopyMenu:) keyEquivalent:@""];
    copy.target = self;
    return m;
}

- (NSView*)buildQueueRail {
    NSVisualEffectView* v = [[NSVisualEffectView alloc] init];
    v.material = NSVisualEffectMaterialSidebar;
    v.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    nm_set_border(v, 1.0, g_theme.separator);

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
    _railTable.menu = [self queueMenu];
    [_railTable registerForDraggedTypes:@[NSPasteboardTypeString]];
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
        case Cmd::ShowStation: [self showPage:NMPageStation pushHistory:YES]; break;
        case Cmd::ToggleLyrics: [self toggleNowPlaying]; break;
        case Cmd::PlayAlbum: break;
        case Cmd::OpenCast: [self showSettingsSection:9]; break;
        case Cmd::OpenInput: [self showSettingsSection:10]; break;
        case Cmd::OpenRoom: [self showSettingsSection:11]; break;
        case Cmd::ExportDiag: [self exportDiagnostics]; break;
        case Cmd::SendFeedback: [self sendFeedback]; break;
        case Cmd::ToggleMini: [self toggleMiniPlayer]; break;
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
- (void)cmdShowShortcuts:(id)s {
    (void)s;
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"键盘快捷键";
    a.informativeText = @"空格 播放/暂停\n← / → 上一首 / 下一首\n⌘F 搜索\n⌘, 设置\n⌘P 正在播放\n⌘2 队列\n⌘S 侧栏\n⌘R 重新扫描\n⌘1 专辑  ⌘3 艺术家  ⌘4 曲目  ⌘5 最近  ⌘6 最爱\n⌘0 快速开始";
    [a addButtonWithTitle:@"好"];
    [a runModal];
}
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
        NSMenu* qm = [[NSMenu alloc] init];
        NSMenuItem* mi1 = [qm addItemWithTitle:@"载入" action:@selector(savedQueueMenuLoad:) keyEquivalent:@""];
        mi1.target = self; mi1.representedObject = name;
        NSMenuItem* mi2 = [qm addItemWithTitle:@"重命名…" action:@selector(savedQueueMenuRename:) keyEquivalent:@""];
        mi2.target = self; mi2.representedObject = name;
        NSMenuItem* mi3 = [qm addItemWithTitle:@"删除" action:@selector(savedQueueMenuDelete:) keyEquivalent:@""];
        mi3.target = self; mi3.representedObject = name;
        b.menu = qm;
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

- (void)savedQueueMenuLoad:(NSMenuItem*)mi {
    const bool ok = rlnative::saved_queue_play(std::string([mi.representedObject UTF8String]), 0);
    if (ok) { _savedQueueName = mi.representedObject; [self loadQueue]; [self showPage:NMPageSavedQueue pushHistory:YES]; }
}
- (void)savedQueueMenuRename:(NSMenuItem*)mi {
    NSString* old = mi.representedObject;
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"重命名歌单：%@", old];
    [a addButtonWithTitle:@"重命名"];
    [a addButtonWithTitle:@"取消"];
    NSTextField* f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    f.stringValue = old;
    a.accessoryView = f;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSString* nn = [f.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (nn.length == 0 || [nn isEqualToString:old]) return;
    rta::net::HttpRequest rq; rq.method = "POST";
    rq.path = "/api/sq/rename?from=" + std::string([old UTF8String]) + "&to=" + std::string([nn UTF8String]);
    std::string ct; (void)rlapp::dispatch(rq, ct);
    [self reloadSavedQueues];
}
- (void)savedQueueMenuDelete:(NSMenuItem*)mi {
    rlnative::saved_queue_delete(std::string([mi.representedObject UTF8String]));
    [self reloadSavedQueues];
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
    [page addSubview:[self headerWithTitle:@"艺术家"
                                 subtitle:[NSString stringWithFormat:@"%zu 位艺术家", _artists.size()]
                                  actions:@[] width:w]];
    const CGFloat itemW = 126, itemH = 152, gap = 16;
    const NSInteger cols = MAX(1, (NSInteger)((w - 52 + gap) / (itemW + gap)));
    NSInteger idx = 0;
    for (const auto& a : _artists) {
        const NSInteger col = idx % cols, row = idx / cols;
        const CGFloat x = 26 + col * (itemW + gap);
        const CGFloat y = 100 + row * (itemH + gap);
        NSString* name = [NSString stringWithUTF8String:a.first.c_str()];
        NSString* key = (std::size_t)idx < _artistKeys.size()
            ? [NSString stringWithUTF8String:_artistKeys[(std::size_t)idx].c_str()] : @"";
        NSButton* hit = [NSButton buttonWithTitle:@"" target:self action:@selector(artistCardClicked:)];
        hit.bordered = NO; hit.bezelStyle = NSBezelStyleInline; hit.tag = idx;
        hit.frame = NSMakeRect(x, y, itemW, itemH);
        hit.toolTip = [NSString stringWithFormat:@"%@ · %d 张专辑", name, a.second];
        [page addSubview:hit];
        NSImageView* avatar = [[NSImageView alloc] initWithFrame:NSMakeRect(x + (itemW - 92) / 2, y, 92, 92)];
        avatar.imageScaling = NSImageScaleProportionallyUpOrDown;
        nm_round_view(avatar, 46, g_theme.card);
        if (key.length) nm_load_cover(key, avatar);
        else avatar.image = nm_placeholder(name, NSMakeSize(92, 92));
        [page addSubview:avatar];
        NSTextField* n = nm_label(name, 12.5, NSFontWeightSemibold, g_theme.text);
        n.alignment = NSTextAlignmentCenter;
        n.frame = NSMakeRect(x, y + 100, itemW, 18);
        [page addSubview:n];
        NSTextField* c = nm_label([NSString stringWithFormat:@"%d 张专辑", a.second], 10.5,
                                  NSFontWeightRegular, g_theme.muted);
        c.alignment = NSTextAlignmentCenter;
        c.frame = NSMakeRect(x, y + 120, itemW, 15);
        [page addSubview:c];
        idx++;
    }
    const NSInteger rows = (idx + cols - 1) / cols;
    if (idx == 0) [page addSubview:[self emptyState:@"还没有艺术家信息" width:w]];
    page.frame = NSMakeRect(0, 0, w, 100 + MAX(0, rows) * (itemH + gap) + 20);
    return page;
}

- (void)artistCardClicked:(NSButton*)sender {
    const NSInteger i = sender.tag;
    if (i < 0 || (std::size_t)i >= _artists.size()) return;
    _artistWho = [NSString stringWithUTF8String:_artists[(std::size_t)i].first.c_str()];
    [self showPage:NMPageArtistDetail pushHistory:YES];
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
    _trackTable.menu = [self trackMenu];
    [_trackTable registerForDraggedTypes:@[NSPasteboardTypeString]];
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
    nm_round_view(cover, 10, g_theme.card);
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
    _trackTable.menu = [self trackMenu];
    [_trackTable registerForDraggedTypes:@[NSPasteboardTypeString]];
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
    _queueTable.menu = [self queueMenu];
    [_queueTable registerForDraggedTypes:@[NSPasteboardTypeString]];
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
    _queueTable.menu = [self queueMenu];
    [_queueTable registerForDraggedTypes:@[NSPasteboardTypeString]];
    [page addSubview:[self scrollForTable:_queueTable frame:NSMakeRect(20, 100, w - 40, tableH)]];
    page.frame = NSMakeRect(0, 0, w, 100 + tableH + 30);
    return page;
}

- (NSView*)pageFolders {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 460)];
    NSButton* up = [self pillButton:@"上一级" symbol:@"arrow.up" action:@selector(cmdFilesUp:)];
    NSButton* inc = [self pillButton:@"增量扫描" symbol:@"arrow.triangle.2.circlepath" action:@selector(cmdScanLibrary:)];
    NSButton* full = [self pillButton:@"全量重扫" symbol:@"arrow.clockwise" action:@selector(cmdRescanLibrary:)];
    [page addSubview:[self headerWithTitle:@"文件夹" subtitle:@"按目录浏览本地音乐库（与网页端同一目录树）" actions:@[inc, full, up] width:w]];

    const auto listing = rlnative::list_files(std::string(_filesPath.UTF8String ?: ""));
    _filesDir = listing.dir;
    NSTextField* path = nm_label([NSString stringWithUTF8String:listing.dir.c_str()], 10.5,
                                NSFontWeightRegular, g_theme.muted);
    path.frame = NSMakeRect(26, 96, w - 52, 16);
    [page addSubview:path];

    NSMutableArray* names = [NSMutableArray array];
    for (const auto& d : listing.dirs) [names addObject:[NSString stringWithFormat:@"📁 %s", d.name.c_str()]];
    for (const auto& f : listing.files) [names addObject:[NSString stringWithUTF8String:f.name.c_str()]];
    _folderNames = names;

    const CGFloat tableH = MIN(MAX((CGFloat)names.count * 30 + 8, 120), 520);
    _filesTable = [self makeTable:NSMakeRect(0, 0, w - 40, tableH) rowHeight:30];
    _filesTable.doubleAction = @selector(filesDoubleClick:);
    _filesTable.target = self;
    _filesTable.dataSource = self;
    [page addSubview:[self scrollForTable:_filesTable frame:NSMakeRect(20, 118, w - 40, tableH)]];
    if (names.count == 0) [page addSubview:[self emptyState:@"目录为空或不可读" width:w]];
    page.frame = NSMakeRect(0, 0, w, 118 + tableH + 30);
    return page;
}

- (void)cmdFilesUp:(id)s {
    (void)s;
    std::string p = std::string(_filesPath.UTF8String ?: "");
    if (p.empty()) return;
    const size_t slash = p.find_last_of('/');
    p = slash == std::string::npos ? "" : p.substr(0, slash);
    _filesPath = [NSString stringWithUTF8String:p.c_str()];
    [self showPage:NMPageFolders pushHistory:NO];
}

- (void)filesDoubleClick:(id)s {
    (void)s;
    const NSInteger row = _filesTable.clickedRow;
    if (row < 0 || (NSUInteger)row >= _folderNames.count) return;
    NSString* name = _folderNames[(NSUInteger)row];
    const auto listing = rlnative::list_files(std::string(_filesPath.UTF8String ?: ""));
    NSString* dir = [NSString stringWithUTF8String:listing.dir.c_str()];
    if ([name hasPrefix:@"📁 "]) {
        NSString* sub = [name substringFromIndex:3];
        _filesPath = dir.length ? [dir stringByAppendingPathComponent:sub] : sub;
        [self showPage:NMPageFolders pushHistory:NO];
    } else {
        NSString* full = dir.length ? [dir stringByAppendingPathComponent:name] : name;
        rlnative::play_path(std::string(full.UTF8String));
    }
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
    NSString* sub = [NSString stringWithFormat:@"%zu 项 · 与网页端共用同一条源配置", _remoteItems.size()];
    NSButton* cfg = [self pillButton:@"服务器配置" symbol:@"gearshape" action:@selector(cmdOpenStreamingSettings:)];
    NSButton* addAll = [self pillButton:@"全部加入队列" symbol:@"text.badge.plus" action:@selector(cmdRemoteAddAll:)];
    NSButton* up = [self pillButton:@"上一级" symbol:@"arrow.up" action:@selector(cmdRemoteUp:)];
    [page addSubview:[self headerWithTitle:@"流媒体" subtitle:sub actions:@[cfg, addAll, up] width:w]];

    if (_remoteItems.empty()) {
        NSTextField* hint = nm_label(@"未配置或未连接流媒体服务器。点「服务器配置」填写地址/账号，保存后点刷新。",
                                     12, NSFontWeightRegular, g_theme.muted);
        hint.frame = NSMakeRect(26, 130, w - 52, 40);
        hint.maximumNumberOfLines = 2;
        [page addSubview:hint];
        NSButton* refresh = [self pillButton:@"刷新" symbol:@"arrow.clockwise" action:@selector(cmdRemoteRefresh:)];
        refresh.frame = NSMakeRect(26, 186, 110, 28);
        [page addSubview:refresh];
        page.frame = NSMakeRect(0, 0, w, 420);
        return page;
    }
    const CGFloat tableH = MIN(MAX((CGFloat)_remoteItems.size() * 44 + 8, 120), 600);
    _remoteTable = [self makeTable:NSMakeRect(0, 0, w - 40, tableH) rowHeight:44];
    _remoteTable.doubleAction = @selector(remoteDoubleClick:);
    _remoteTable.target = self;
    _remoteTable.dataSource = self;
    [page addSubview:[self scrollForTable:_remoteTable frame:NSMakeRect(20, 100, w - 40, tableH)]];
    page.frame = NSMakeRect(0, 0, w, 100 + tableH + 30);
    return page;
}

- (void)cmdOpenStreamingSettings:(id)s { (void)s; [self showSettingsSection:6]; }
- (void)cmdRemoteAddAll:(id)s {
    (void)s;
    NSInteger n = 0;
    for (const auto& e : _remoteItems) if (!e.dir && rlnative::enqueue_remote(e)) n++;
    [self loadQueue];
    [self toast:[NSString stringWithFormat:@"已加入 %ld 首", (long)n]];
}
- (void)cmdRemoteRefresh:(id)s {
    (void)s;
    _remoteItems = rlnative::remote_browse("", false, "");
    [self showPage:NMPageStreaming pushHistory:NO];
}
- (void)cmdRemoteUp:(id)s {
    (void)s;
    if (_remoteTrail.count > 0) [_remoteTrail removeLastObject];
    NSString* parent = _remoteTrail.lastObject ?: @"";
    _remoteItems = rlnative::remote_browse(std::string(parent.UTF8String), false, "");
    [self showPage:NMPageStreaming pushHistory:NO];
}
- (void)remoteDoubleClick:(id)s {
    (void)s;
    const NSInteger row = _remoteTable.clickedRow;
    if (row < 0 || (NSUInteger)row >= _remoteItems.size()) return;
    const auto& e = _remoteItems[(NSUInteger)row];
    if (e.dir) {
        [_remoteTrail addObject:[NSString stringWithUTF8String:e.id.c_str()]];
        _remoteItems = rlnative::remote_browse(e.id, false, "");
        [self showPage:NMPageStreaming pushHistory:NO];
    } else {
        rlnative::play_remote(e);
        [self loadQueue];
    }
}

- (NSView*)pageStation {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 560)];
    [page addSubview:[self headerWithTitle:@"快速开始" subtitle:@"常用操作与系统状态" actions:@[] width:w]];
    const auto st = rlnative::library_stats();
    NSString* nowPlaying = _snap.current.empty() ? @"未播放" :
        [[NSString stringWithUTF8String:_snap.current.c_str()] lastPathComponent];
    NSArray* cards = @[
        @[@"继续播放", nowPlaying, @"play.circle", @((int)Cmd::PlayPause)],
        @[@"最近播放", @"看看刚听过的曲目", @"clock.arrow.circlepath", @((int)Cmd::ShowRecent)],
        @[@"我的最爱", [NSString stringWithFormat:@"%zu 首", rlnative::favorite_tracks().size()], @"heart", @((int)Cmd::ShowFavorites)],
        @[@"重新扫描", [NSString stringWithFormat:@"%d 首 · %d 张专辑", st.tracks, st.albums], @"arrow.triangle.2.circlepath", @((int)Cmd::Rescan)],
        @[@"检查更新", [NSString stringWithFormat:@"当前 %s", RLPLAYER_VERSION_STR], @"arrow.down.circle", @((int)Cmd::CheckUpdate)],
        @[@"导出诊断包", @"生成 zip 供排查", @"stethoscope", @((int)Cmd::ExportDiag)],
        @[@"反馈问题", @"邮件 + 诊断附件", @"envelope", @((int)Cmd::SendFeedback)],
        @[@"设置", @"输出 / 升频 / DSD / EQ", @"gearshape", @((int)Cmd::OpenSettings)],
    ];
    const CGFloat cardW = (w - 52 - 18) / 2.0;
    for (NSUInteger i = 0; i < cards.count; ++i) {
        NSArray* c = cards[i];
        const CGFloat x = 26 + (i % 2) * (cardW + 18);
        const CGFloat y = 104 + (i / 2) * 96;
        NSButton* b = [NSButton buttonWithTitle:@"" target:self action:@selector(stationCardClicked:)];
        b.bordered = NO;
        b.bezelStyle = NSBezelStyleInline;
        nm_round_view(b, 10, g_theme.card);
        b.frame = NSMakeRect(x, y, cardW, 84);
        b.tag = [c[3] integerValue];
        b.toolTip = c[1];
        [page addSubview:b];
        NSImageView* icon = [[NSImageView alloc] initWithFrame:NSMakeRect(x + 16, y + 26, 30, 30)];
        icon.image = nm_symbol(c[2], 24);
        icon.contentTintColor = g_theme.accent;
        [page addSubview:icon];
        NSTextField* t = nm_label(c[0], 14, NSFontWeightSemibold, g_theme.text);
        t.frame = NSMakeRect(x + 58, y + 34, cardW - 74, 20);
        [page addSubview:t];
        NSTextField* d = nm_label(c[1], 11, NSFontWeightRegular, g_theme.muted);
        d.frame = NSMakeRect(x + 58, y + 54, cardW - 74, 16);
        [page addSubview:d];
    }
    NSTextField* status = nm_label([NSString stringWithFormat:
        @"模式 %@ · 音量 %.1f dB · 队列 %zu 首 · 曲库 %d 首/%d 专辑",
        nm_mode_title(_snap.mode), _snap.volDb, _queue.size(), st.tracks, st.albums],
        11, NSFontWeightRegular, g_theme.muted);
    status.frame = NSMakeRect(26, 104 + ((cards.count + 1) / 2) * 96 + 4, w - 52, 18);
    [page addSubview:status];
    page.frame = NSMakeRect(0, 0, w, 104 + ((cards.count + 1) / 2) * 96 + 40);
    return page;
}

- (void)stationCardClicked:(NSButton*)sender { [self handleCmd:(Cmd)(int)sender.tag]; }

- (void)toggleMiniPlayer {
    if (_miniPlayer) {
        [_miniPlayer orderOut:nil];
        _miniPlayer = nil;
        return;
    }
    NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 132)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"迷你播放器";
    w.level = NSFloatingWindowLevel;
    w.backgroundColor = g_theme.card;
    NSView* v = w.contentView;
    NSImageView* cover = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 34, 64, 64)];
    cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    nm_round_view(cover, 6, nil);
    [self loadCoverForPath:(_snap.current.empty() ? @"" : [NSString stringWithUTF8String:_snap.current.c_str()]) into:cover];
    [v addSubview:cover];
    NSTextField* t = nm_label(_barTitle.stringValue, 13, NSFontWeightSemibold, g_theme.text);
    t.frame = NSMakeRect(90, 74, 250, 18);
    [v addSubview:t];
    NSTextField* a = nm_label(_barArtist.stringValue, 11, NSFontWeightRegular, g_theme.muted);
    a.frame = NSMakeRect(90, 56, 250, 16);
    [v addSubview:a];
    NSButton* prev = nm_symbol_button(@"backward.fill", self, @selector(dispatchCmd:), @"上一首");
    prev.tag = (NSInteger)Cmd::Previous;
    prev.frame = NSMakeRect(90, 16, 28, 28);
    [v addSubview:prev];
    NSButton* pp = [NSButton buttonWithImage:nm_symbol(@"play.fill", 14) target:self action:@selector(dispatchCmd:)];
    pp.tag = (NSInteger)Cmd::PlayPause; pp.bordered = NO;
    pp.frame = NSMakeRect(126, 14, 32, 32);
    [v addSubview:pp];
    NSButton* next = nm_symbol_button(@"forward.fill", self, @selector(dispatchCmd:), @"下一首");
    next.tag = (NSInteger)Cmd::Next;
    next.frame = NSMakeRect(166, 16, 28, 28);
    [v addSubview:next];
    NSButton* close = nm_symbol_button(@"xmark", self, @selector(cmdCloseMini:), @"关闭迷你窗");
    close.frame = NSMakeRect(322, 100, 24, 24);
    [v addSubview:close];
    _miniPlayer = w;
    [w makeKeyAndOrderFront:nil];
}

- (void)cmdCloseMini:(id)s { (void)s; [_miniPlayer orderOut:nil]; _miniPlayer = nil; }

- (NSView*)pageArtistDetail {
    const CGFloat w = [self contentWidth];
    NMFlippedView* page = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 520)];
    NSString* who = _artistWho ?: @"";
    _tracks = rlnative::search_tracks(std::string(who.UTF8String ?: ""), 200);
    _artistAlbums.clear();
    for (const auto& a : _albums) if (a.artist == std::string(who.UTF8String ?: "")) {
        _artistAlbums.push_back(rlnative::album_detail(a.key));
    }
    NSButton* back = [self pillButton:@"返回" symbol:@"chevron.left" action:@selector(cmdBack:)];
    [page addSubview:[self headerWithTitle:who
                                 subtitle:[NSString stringWithFormat:@"%zu 张专辑 · %zu 首曲目",
                                           _artistAlbums.size(), _tracks.size()]
                                  actions:@[back] width:w]];
    CGFloat y = 96;
    NSInteger shown = 0;
    for (const auto& ad : _artistAlbums) {
        if (shown >= 8) break;
        NSButton* b = [NSButton buttonWithTitle:@"" target:self action:@selector(artistAlbumClicked:)];
        b.bordered = NO; b.bezelStyle = NSBezelStyleInline;
        b.frame = NSMakeRect(26 + shown * 112, y, 100, 130);
        b.tag = shown;
        b.toolTip = [NSString stringWithUTF8String:ad.album.name.c_str()];
        [page addSubview:b];
        NSImageView* cover = [[NSImageView alloc] initWithFrame:NSMakeRect(26 + shown * 112, y, 100, 100)];
        cover.imageScaling = NSImageScaleProportionallyUpOrDown;
        nm_round_view(cover, 8, nil);
        nm_load_cover([NSString stringWithUTF8String:ad.album.key.c_str()], cover);
        [page addSubview:cover];
        NSTextField* n = nm_label([NSString stringWithUTF8String:ad.album.name.c_str()], 10.5,
                                 NSFontWeightMedium, g_theme.text);
        n.frame = NSMakeRect(26 + shown * 112, y + 104, 100, 16);
        [page addSubview:n];
        shown++;
    }
    if (shown > 0) y += 150;
    if (!_tracks.empty()) {
        const CGFloat tableH = MIN((CGFloat)_tracks.size() * 42 + 8, 380);
        _trackTable = [self makeTable:NSMakeRect(0, 0, w - 40, tableH) rowHeight:42];
        _trackTable.doubleAction = @selector(trackDoubleClick:);
    _trackTable.menu = [self trackMenu];
    [_trackTable registerForDraggedTypes:@[NSPasteboardTypeString]];
        _trackTable.target = self;
        _trackTable.dataSource = self;
        [page addSubview:[self scrollForTable:_trackTable frame:NSMakeRect(20, y, w - 40, tableH)]];
        y += tableH + 20;
    } else {
        [page addSubview:[self emptyState:@"没有该艺术家的曲目" width:w]];
        y += 80;
    }
    page.frame = NSMakeRect(0, 0, w, y + 20);
    return page;
}

- (void)artistAlbumClicked:(NSButton*)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= _artistAlbums.size()) return;
    g_detail = _artistAlbums[(NSUInteger)sender.tag];
    [self showPage:NMPageAlbumDetail pushHistory:YES];
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
    _trackTable.menu = [self trackMenu];
    [_trackTable registerForDraggedTypes:@[NSPasteboardTypeString]];
    _trackTable.target = self;
    [page addSubview:[self scrollForTable:_trackTable frame:NSMakeRect(20, 100, w - 40, tableH)]];
    page.frame = NSMakeRect(0, 0, w, 100 + tableH + 30);
    return page;
}

// ---------------------------------------------------------------------------
// 页面切换
// ---------------------------------------------------------------------------
- (void)showPage:(NMPage)p pushHistory:(BOOL)push {
    if ((p == NMPageStreaming || p == NMPageRemoteDetail) && _remoteItems.empty() && _remoteTrail.count == 0) {
        _remoteItems = rlnative::remote_browse("", false, "");
    }
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
        case NMPageStation: page = [self pageStation]; break;
        case NMPageArtistDetail: page = [self pageArtistDetail]; break;
        case NMPageRemoteDetail: page = [self pageStreaming]; break;
    }
    _contentScroll.documentView = page;
    if (g_langEn) nm_translate_view(page);
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
- (NSInteger)queueRowForMenu {
    if (_queueTable.clickedRow >= 0) return _queueTable.clickedRow;
    if (_railTable.clickedRow >= 0) return _railTable.clickedRow;
    return -1;
}
- (void)queuePlayNow:(id)s { (void)s; const NSInteger r = [self queueRowForMenu]; if (r >= 0) rlnative::queue_play_index((std::size_t)r); }
- (void)queueDelete:(id)s {
    (void)s;
    const NSInteger r = [self queueRowForMenu];
    if (r < 0) return;
    rlnative::queue_remove((std::size_t)r);
    [self loadQueue];
    [self reloadVisibleQueue];
}
- (void)queueMoveUp:(id)s {
    (void)s;
    const NSInteger r = [self queueRowForMenu];
    if (r <= 0) return;
    rlnative::queue_move((std::size_t)r, (std::size_t)(r - 1));
    [self loadQueue];
    [self reloadVisibleQueue];
}
- (void)queueMoveDown:(id)s {
    (void)s;
    const NSInteger r = [self queueRowForMenu];
    if (r < 0 || (std::size_t)(r + 1) >= _queue.size()) return;
    rlnative::queue_move((std::size_t)r, (std::size_t)(r + 1));
    [self loadQueue];
    [self reloadVisibleQueue];
}

- (id<NSPasteboardWriting>)tableView:(NSTableView*)tv pasteboardWriterForRow:(NSInteger)row {
    if (tv != _railTable && tv != _queueTable) return nil;
    NSPasteboardItem* it = [[NSPasteboardItem alloc] init];
    [it setString:[NSString stringWithFormat:@"%ld", (long)row] forType:NSPasteboardTypeString];
    return it;
}
- (NSDragOperation)tableView:(NSTableView*)tv validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op {
    (void)info; (void)op;
    return (tv == _railTable || tv == _queueTable) ? NSDragOperationMove : NSDragOperationNone;
}
- (BOOL)tableView:(NSTableView*)tv acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row
   dropOperation:(NSTableViewDropOperation)op {
    (void)op;
    if (tv != _railTable && tv != _queueTable) return NO;
    NSString* s = [[info draggingPasteboard] stringForType:NSPasteboardTypeString];
    if (s.length == 0) return NO;
    NSInteger from = s.integerValue;
    NSInteger to = row;
    if (to > from) to -= 1;
    if (from < 0 || to < 0 || from == to) return NO;
    rlnative::queue_move((std::size_t)from, (std::size_t)to);
    [self loadQueue];
    [self reloadVisibleQueue];
    return YES;
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
- (NSInteger)trackRowForMenu {
    if (_trackTable.clickedRow >= 0) return _trackTable.clickedRow;
    return _trackTable.selectedRow;
}
- (void)trackPlayMenu:(id)s {
    (void)s;
    const NSInteger r = [self trackRowForMenu];
    if (r < 0) return;
    if (_page_ == NMPageAlbumDetail) rlnative::play_album(g_detail.album.key, (int)r);
    else if ((std::size_t)r < _tracks.size()) rlnative::play_path(_tracks[(std::size_t)r].path);
}
- (void)trackFavMenu:(id)s {
    (void)s;
    const NSInteger r = [self trackRowForMenu];
    if (r < 0) return;
    std::string path = (_page_ == NMPageAlbumDetail && (std::size_t)r < g_detail.tracks.size())
        ? g_detail.tracks[(std::size_t)r].path
        : ((std::size_t)r < _tracks.size() ? _tracks[(std::size_t)r].path : std::string());
    if (!path.empty()) rlnative::favorite_toggle(path);
}
- (void)trackRevealMenu:(id)s {
    (void)s;
    const NSInteger r = [self trackRowForMenu];
    if (r < 0) return;
    std::string path = (_page_ == NMPageAlbumDetail && (std::size_t)r < g_detail.tracks.size())
        ? g_detail.tracks[(std::size_t)r].path
        : ((std::size_t)r < _tracks.size() ? _tracks[(std::size_t)r].path : std::string());
    if (path.empty()) return;
    NSString* p = [NSString stringWithUTF8String:path.c_str()];
    [[NSWorkspace sharedWorkspace] selectFile:p inFileViewerRootedAtPath:@""];
}
- (void)trackCopyMenu:(id)s {
    (void)s;
    const NSInteger r = [self trackRowForMenu];
    if (r < 0) return;
    std::string path = (_page_ == NMPageAlbumDetail && (std::size_t)r < g_detail.tracks.size())
        ? g_detail.tracks[(std::size_t)r].path
        : ((std::size_t)r < _tracks.size() ? _tracks[(std::size_t)r].path : std::string());
    if (path.empty()) return;
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[NSString stringWithUTF8String:path.c_str()] forType:NSPasteboardTypeString];
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
    if (tv == _filesTable) return (NSInteger)_folderNames.count;
    if (tv == _remoteTable) return (NSInteger)_remoteItems.size();
    if (tv == _settingsSections) return [self settingsSectionTitles].count;
    if (tv == _settingsPresetTable) return (NSInteger)_settingsPresets.count;
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
    if (tv == _filesTable) {
        NSTableCellView* cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, w, 30)];
        NSString* name = (row >= 0 && (NSUInteger)row < _folderNames.count) ? _folderNames[(NSUInteger)row] : @"";
        NSTextField* l = nm_label(name, 12.5, NSFontWeightRegular, g_theme.text);
        l.frame = NSMakeRect(8, 6, w - 20, 18);
        [cell addSubview:l];
        return cell;
    }
    if (tv == _remoteTable) {
        if (row < 0 || (NSUInteger)row >= _remoteItems.size()) return nil;
        const auto& e = _remoteItems[(NSUInteger)row];
        NSString* title = [NSString stringWithUTF8String:e.title.c_str()];
        NSString* sub = e.dir ? @"目录" : [NSString stringWithFormat:@"%s · %s",
            e.artist.c_str(), e.album.c_str()];
        NSTableCellView* cell = [self cellWithTitle:title sub:sub right:nm_time(e.dur) width:w];
        NSTextField* icon = nm_label(e.dir ? @"📁" : @"♪", 12, NSFontWeightRegular, g_theme.muted);
        icon.frame = NSMakeRect(6, 12, 18, 18);
        [cell addSubview:icon];
        for (NSView* v in cell.subviews) {
            if ([v isKindOfClass:[NSTextField class]] && v.frame.origin.x == 8) v.frame = NSMakeRect(28, v.frame.origin.y, v.frame.size.width - 20, v.frame.size.height);
        }
        return cell;
    }
    if (tv == _settingsSections) {
        NSString* title = [self settingsSectionTitles][(NSUInteger)row];
        NSTableCellView* cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, w, 34)];
        NSTextField* l = nm_label(title, 12.5, NSFontWeightMedium, g_theme.text);
        l.frame = NSMakeRect(12, 8, w - 20, 18);
        [cell addSubview:l];
        return cell;
    }
    if (tv == _settingsPresetTable) {
        NSTableCellView* cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, w, 26)];
        NSTextField* l = nm_label(_settingsPresets[(NSUInteger)row], 12, NSFontWeightRegular, g_theme.text);
        l.frame = NSMakeRect(8, 4, w - 16, 18);
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
        NMArtistItem* item = nil;
        @try {
            item = [cv makeItemWithIdentifier:@"artist" forIndexPath:ip];
        } @catch (NSException* e) {
            std::fprintf(stderr, "ARTITEM make exception: %s / %s\n",
                         e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
            std::fflush(stderr);
        }
        if (!item) {
            item = [[NMArtistItem alloc] init];
            item.identifier = @"artist";
            [item loadView];
        }
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
        if ((std::size_t)ip.item < _artists.size()) {
            _artistWho = [NSString stringWithUTF8String:_artists[(size_t)ip.item].first.c_str()];
            [self showPage:NMPageArtistDetail pushHistory:YES];
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
    if (_page_ == NMPageStreaming || _page_ == NMPageRemoteDetail) {
        _remoteItems = _query.length ? rlnative::remote_browse("", true, std::string(_query.UTF8String))
                                     : rlnative::remote_browse("", false, "");
        [self showPage:NMPageStreaming pushHistory:NO];
        return;
    }
    if (_page_ == NMPageFolders) return;
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
    nm_set_background(overlay, g_theme.bg);

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

    // 左：音频分析 + 曲目信息（1.1.6 单曲页左栏）
    _npAnalysisPanel = [[NSView alloc] initWithFrame:NSMakeRect(24, 90, 216, 420)];
    _npAnalysisPanel.wantsLayer = YES;
    nm_round_view(_npAnalysisPanel, 10, [g_theme.card colorWithAlphaComponent:0.7]);
    _npAnalysisPanel.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [overlay addSubview:_npAnalysisPanel];
    NSTextField* anlTitle = nm_label(@"音频分析", 13, NSFontWeightSemibold, g_theme.text);
    anlTitle.frame = NSMakeRect(14, 386, 180, 18);
    [_npAnalysisPanel addSubview:anlTitle];
    NSButton* anlRun = [NSButton buttonWithTitle:@"分析当前曲目" target:self action:@selector(cmdNpAnalyze:)];
    anlRun.bezelStyle = NSBezelStyleRounded;
    anlRun.frame = NSMakeRect(12, 350, 140, 28);
    [_npAnalysisPanel addSubview:anlRun];
    NSButton* anlDetail = [NSButton buttonWithTitle:@"详细" target:self action:@selector(cmdNpAnalyzeDetailed:)];
    anlDetail.bezelStyle = NSBezelStyleRounded;
    anlDetail.frame = NSMakeRect(158, 350, 46, 28);
    [_npAnalysisPanel addSubview:anlDetail];
    NSButton* autoBtn = [NSButton buttonWithTitle:@"播放即分析" target:self action:@selector(cmdNpAutoToggle:)];
    autoBtn.bezelStyle = NSBezelStyleRounded;
    autoBtn.frame = NSMakeRect(12, 318, 140, 26);
    [_npAnalysisPanel addSubview:autoBtn];
    NSButton* aiBtn = [NSButton buttonWithTitle:@"AI 资料" target:self action:@selector(cmdNpEntity:)];
    aiBtn.bezelStyle = NSBezelStyleRounded;
    aiBtn.frame = NSMakeRect(158, 318, 60, 26);
    [_npAnalysisPanel addSubview:aiBtn];
    NSTextField* anlHint = nm_label(@"分析只读文件；不写标签。", 10, NSFontWeightRegular, g_theme.muted);
    anlHint.frame = NSMakeRect(12, 330, 190, 14);
    [_npAnalysisPanel addSubview:anlHint];
    _npAnalysisLabel = nm_label(@"尚未分析", 10.5, NSFontWeightRegular, g_theme.text);
    _npAnalysisLabel.frame = NSMakeRect(12, 220, 192, 100);
    _npAnalysisLabel.maximumNumberOfLines = 6;
    _npAnalysisLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [_npAnalysisPanel addSubview:_npAnalysisLabel];
    NSTextField* infoTitle = nm_label(@"曲目信息", 13, NSFontWeightSemibold, g_theme.text);
    infoTitle.frame = NSMakeRect(14, 190, 180, 18);
    [_npAnalysisPanel addSubview:infoTitle];
    _npInfoLabel = nm_label(@"", 10.5, NSFontWeightRegular, g_theme.muted);
    _npInfoLabel.frame = NSMakeRect(12, 40, 192, 140);
    _npInfoLabel.maximumNumberOfLines = 8;
    _npInfoLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [_npAnalysisPanel addSubview:_npInfoLabel];

    _npCover = [[NSImageView alloc] initWithFrame:NSMakeRect(320, 150, 280, 280)];
    _npCover.imageScaling = NSImageScaleProportionallyUpOrDown;
    nm_round_view(_npCover, 14, g_theme.card);
    _npCover.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [overlay addSubview:_npCover];

    _npTitle = nm_label(@"未播放", 24, NSFontWeightBold, g_theme.text);
    _npTitle.frame = NSMakeRect(320, 448, 420, 32);
    _npTitle.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [overlay addSubview:_npTitle];
    _npArtist = nm_label(@"", 14, NSFontWeightRegular, g_theme.muted);
    _npArtist.frame = NSMakeRect(322, 482, 420, 20);
    _npArtist.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [overlay addSubview:_npArtist];

    _npLyrics = [[NSTableView alloc] initWithFrame:NSMakeRect(640, 120, 360, 420)];
    _npLyrics.headerView = nil;
    _npLyrics.rowHeight = 34;
    _npLyrics.backgroundColor = [NSColor clearColor];
    _npLyrics.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _npLyrics.dataSource = self;
    _npLyrics.delegate = self;
    _npLyrics.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTableColumn* lc = [[NSTableColumn alloc] initWithIdentifier:@"lyric"];
    lc.width = 380;
    [_npLyrics addTableColumn:lc];
    NSScrollView* lscroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(640, 120, 360, 420)];
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
    prev.frame = NSMakeRect(320, 52, 28, 28);
    [overlay addSubview:prev];
    NSButton* pp = [NSButton buttonWithImage:nm_symbol(@"play.fill", 20) target:self action:@selector(dispatchCmd:)];
    pp.tag = (NSInteger)Cmd::PlayPause;
    pp.bezelStyle = NSBezelStyleCircular;
    pp.bordered = NO;
    nm_round_view(pp, 22, g_theme.accent);
    pp.contentTintColor = NSColor.whiteColor;
    pp.frame = NSMakeRect(356, 44, 44, 44);
    [overlay addSubview:pp];
    NSButton* next = nm_symbol_button(@"forward.fill", self, @selector(dispatchCmd:), @"下一首");
    next.tag = (NSInteger)Cmd::Next;
    next.frame = NSMakeRect(408, 52, 28, 28);
    [overlay addSubview:next];
    return overlay;
}

- (void)toggleNowPlaying {
    _nowPlayingVisible = !_nowPlayingVisible;
    _nowPlayingOverlay.hidden = !_nowPlayingVisible;
    if (_nowPlayingVisible) [self refreshNowPlaying];
}

- (void)cmdNpEntity:(id)s {
    (void)s;
    NSString* artist = _barArtist.stringValue;
    if (artist.length == 0) { [self toast:@"当前曲目没有艺术家信息"]; return; }
    const auto doc = rta::net::json_parse(rlnative::entity_summary("person", std::string(artist.UTF8String)));
    NSString* text = [NSString stringWithUTF8String:(doc["summary"].s().empty() ? doc["error"].s() : doc["summary"].s()).c_str()];
    _npInfoLabel.stringValue = text.length ? text : @"没有返回资料";
}
- (void)cmdNpAnalyzeDetailed:(id)s { (void)s; [self cmdNpAnalyze:nil]; }
- (void)cmdNpAutoToggle:(id)s {
    (void)s;
    const bool on = [[self uiValue:@"autoanl"] isEqualToString:@"1"];
    rlnative::settings_save({{"autoanl", on ? "0" : "1"}});
    _uiValues["autoanl"] = on ? "0" : "1";
    [self toast:on ? @"已关闭播放即分析" : @"已开启播放即分析"];
}
- (void)cmdNpAnalyze:(id)s {
    (void)s;
    if (_snap.current.empty()) return;
    const auto doc = rta::net::json_parse(rlnative::health_report_json(_snap.current));
    const auto h = doc["health"];
    _npAnalysisLabel.stringValue = [NSString stringWithFormat:
        @"LRA %.1f LU · 峰值 %.2f dBFS\nRMS %.2f dBFS · 响度 %.1f LUFS\n削波 %.2f%% · DR %.1f dB\n%@",
        h["lra"].n(), h["peak_dbfs"].n(), h["rms_dbfs"].n(), h["lufs"].n(),
        h["clipped_pct"].n(), h["dr_db"].n(),
        h["lossless_suspected"].b ? @"疑似假无损" : @"未发现假无损迹象"];
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
    _npInfoLabel.stringValue = [NSString stringWithFormat:@"%@\n时长 %@\n艺术家 %@",
                                path.length ? path.lastPathComponent : @"未播放",
                                nm_time(_snap.dur),
                                _barArtist.stringValue.length ? _barArtist.stringValue : @"—"];
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
    if (_barCover.image) {
        info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithBoundsSize:_barCover.image.size
            requestHandler:^NSImage*(CGSize size) { (void)size; return _barCover.image; }];
    }
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

- (NSString*)uiValue:(NSString*)key {
    auto it = _uiValues.find(std::string(key.UTF8String));
    if (it != _uiValues.end()) return [NSString stringWithUTF8String:it->second.c_str()];
    auto sit = _settings.find(std::string(key.UTF8String));
    return sit == _settings.end() ? @"" : [NSString stringWithUTF8String:sit->second.c_str()];
}

- (NSTextField*)formField:(NSString*)key width:(CGFloat)w {
    NSTextField* f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, w, 24)];
    const auto it = _uiValues.find(std::string(key.UTF8String));
    if (it != _uiValues.end()) {
        f.stringValue = [NSString stringWithUTF8String:it->second.c_str()];
    } else {
        const auto sit = _settings.find(std::string(key.UTF8String));
        f.stringValue = sit == _settings.end() ? @"" : [NSString stringWithUTF8String:sit->second.c_str()];
    }
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
    NSString* cur = [self uiValue:key];
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

- (NSArray<NSString*>*)settingsSectionTitles {
    return @[@"通用", @"输出", @"升频 (PCM)", @"DSD", @"PEQ / EQ", @"耳机 EQ (OPRA)",
             @"资料库", @"流媒体", @"分析 / AI", @"设备投放", @"输入采集",
             @"房间校正", @"更新", @"诊断与反馈", @"关于"];
}

- (NSView*)sectionPage:(NSArray<NSView*>*)rows {
    CGFloat h = 20;
    for (NSView* r in rows) h += r.frame.size.height + 4;
    NMFlippedView* v = [[NMFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 620, MAX(h, 380))];
    CGFloat y = 16;
    for (NSView* r in rows) {
        r.frame = NSMakeRect(24, y, 572, r.frame.size.height);
        [v addSubview:r];
        y += r.frame.size.height + 4;
    }
    return v;
}

- (NSButton*)sectionButton:(NSString*)title action:(SEL)action {
    NSButton* b = [NSButton buttonWithTitle:title target:self action:action];
    b.bezelStyle = NSBezelStyleRounded;
    b.frame = NSMakeRect(0, 0, 150, 28);
    return b;
}

- (NSTextField*)infoText:(NSString*)text {
    NSTextField* l = nm_label(text, 11.5, NSFontWeightRegular, g_theme.muted);
    l.frame = NSMakeRect(0, 0, 560, 18);
    return l;
}

- (NSArray<NSView*>*)settingsRowsForSection:(NSInteger)idx {
    NSMutableArray<NSView*>* rows = [NSMutableArray array];
    [self reloadSettings];
    switch (idx) {
        case 0: {
            [rows addObject:[self formRow:@"主题色" control:[self formPopup:@"theme" values:@[@"light", @"dark", @"blue"] titles:@[@"白色（默认）", @"深色", @"浅蓝色"] width:220] y:0 width:572]];
            [rows addObject:[self formRow:@"语言" control:[self formPopup:@"lang" values:@[@"zh", @"en"] titles:@[@"中文", @"English"] width:220] y:0 width:572]];
            [rows addObject:[self formRow:@"界面风格" control:[self formPopup:@"uistyle" values:@[@"apple", @"classic"] titles:@[@"Apple Music 风格", @"经典 Hi-Fi 工作台"] width:220] y:0 width:572]];
            [rows addObject:[self infoText:@"主题即时生效；语言在网页界面重启后生效（原生文案当前为中文）。"]];
            break;
        }
        case 1: {
            if (_uiValues["backend"].empty()) _uiValues["backend"] = [self selectedSettingsValue:@"backend" fallback:@"coreaudio"].UTF8String;
            _outputDevices = rlnative::output_devices();
            NSMutableArray* names = [NSMutableArray array];
            NSMutableArray* ids = [NSMutableArray array];
            for (const auto& d : _outputDevices) {
                [names addObject:[NSString stringWithFormat:@"%s%@", d.name.c_str(), d.isDefault ? @"（默认）" : @""]];
                [ids addObject:[NSString stringWithUTF8String:d.id.c_str()]];
            }
            if (names.count == 0) { [names addObject:@"（未枚举到输出设备）"]; [ids addObject:@""]; }
            NSPopUpButton* dev = [self formPopup:@"device" values:ids titles:names width:300];
            [rows addObject:[self formRow:@"输出设备" control:dev y:0 width:572]];
            [rows addObject:[self formRow:@"输出后端" control:[self formPopup:@"backend" values:@[@"coreaudio", @"hog", @"null", @"upnp"] titles:@[@"CoreAudio", @"独占 (Hog)", @"静音 (null)", @"UPnP 投放"] width:220] y:0 width:572]];
            [rows addObject:[self formRow:@"缓冲 (ms)" control:[self formField:@"buffer" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"音量 (dB)" control:[self formField:@"volume" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"响度" control:[self formPopup:@"loudness" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"声道数" control:[self formField:@"channels" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"声道微调" control:[self formField:@"trim" width:300] y:0 width:572]];
            [rows addObject:[self formRow:@"ReplayGain" control:[self formPopup:@"rgmode" values:@[@"off", @"track", @"album"] titles:@[@"关闭", @"按曲目", @"按专辑"] width:200] y:0 width:572]];
            [rows addObject:[self formRow:@"RG 前级 (dB)" control:[self formField:@"rgpreamp" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"RG 防削波" control:[self formPopup:@"rgpreventclip" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"GPU 后端" control:[self formPopup:@"gpuvendor" values:@[@"auto", @"metal", @"cpu"] titles:@[@"自动", @"Metal GPU", @"CPU"] width:200] y:0 width:572]];
            [rows addObject:[self formRow:@"缓冲" control:[self sectionButton:@"复位缓冲 (buffer/reset)" action:@selector(cmdResetBuffer:)] y:0 width:572]];
            break;
        }
        case 2: {
            [rows addObject:[self formRow:@"目标采样率" control:[self formField:@"rate" width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"滤波器" control:[self formField:@"filter" width:260] y:0 width:572]];
            [rows addObject:[self formRow:@"滤波器 (Nx)" control:[self formField:@"filterNx" width:260] y:0 width:572]];
            [rows addObject:[self formRow:@"taps" control:[self formField:@"taps" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"衰减 (dB)" control:[self formField:@"atten" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"过渡带" control:[self formField:@"transition" width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"相位" control:[self formField:@"phase" width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"噪声整形" control:[self formField:@"shaper" width:200] y:0 width:572]];
            [rows addObject:[self formRow:@"两段式" control:[self formPopup:@"twostage" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"ISP" control:[self formPopup:@"isp" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"流式解码" control:[self formPopup:@"streamdecode" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"流式阈值 (MB)" control:[self formField:@"stream_threshold_mb" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"峰值预扫 (s)" control:[self formField:@"isp_prescan_sec" width:120] y:0 width:572]];
            break;
        }
        case 3: {
            [rows addObject:[self formRow:@"DSD 输出" control:[self formPopup:@"dsd" values:@[@"0", @"1", @"2"] titles:@[@"关闭", @"DoP", @"Native"] width:200] y:0 width:572]];
            [rows addObject:[self formRow:@"调制器阶数" control:[self formField:@"modorder" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"调制器族" control:[self formField:@"modfamily" width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"out-of-band 增益" control:[self formField:@"oobgain" width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"AHM 位深" control:[self formField:@"ahmbits" width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"调制器 cut" control:[self formField:@"modcut" width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"调制器抖动" control:[self formField:@"moddith" width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"ramp" control:[self formField:@"ramp" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"DSD Native" control:[self formPopup:@"dsdnative" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"DirectSDM" control:[self formPopup:@"directsdm" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"DSD 类型" control:[self formField:@"dsdkind" width:200] y:0 width:572]];
            [rows addObject:[self formRow:@"DSD 转换" control:[self formField:@"dsdconv" width:200] y:0 width:572]];
            [rows addObject:[self formRow:@"两段式 DSD" control:[self formPopup:@"dsd2stage" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"SDM 源滤波" control:[self formField:@"sdmfilt" width:220] y:0 width:572]];
            [rows addObject:[self formRow:@"SDM 源滤波 (Nx)" control:[self formField:@"sdmfiltnx" width:220] y:0 width:572]];
            break;
        }
        case 4: {
            const auto peq = rlnative::peq_state();
            _peqBands = peq.bands;
            [rows addObject:[self formRow:@"PEQ 旁路" control:[self formPopup:@"peqbypass" values:@[@"0", @"1"] titles:@[@"启用", @"旁路"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"前级 (dB)" control:[self formField:@"peqpreamp" width:120] y:0 width:572]];
            NSMutableArray* presets = [NSMutableArray arrayWithObject:@"—"];
            for (const auto& n : peq.presets) [presets addObject:[NSString stringWithUTF8String:n.c_str()]];
            NSPopUpButton* pp = [self formPopup:@"peqpreset" values:presets titles:presets width:260];
            pp.target = self;
            pp.action = @selector(cmdPeqApplyPreset:);
            [rows addObject:[self formRow:@"预设" control:pp y:0 width:572]];
            NSMutableString* text = [NSMutableString string];
            for (const auto& b : _peqBands) {
                [text appendFormat:@"%d,%s,%.2f,%.2f,%.3f,%s\n", b.index, b.type.c_str(), b.freq,
                 b.gain, b.q, b.on ? "on" : "off"];
            }
            _settingsPeqEditor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 552, 220)];
            _settingsPeqEditor.string = text.length ? text : @"（当前没有 PEQ 频段）";
            _settingsPeqEditor.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
            NSScrollView* es = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 552, 220)];
            es.hasVerticalScroller = YES;
            es.documentView = _settingsPeqEditor;
            [rows addObject:[self formRow:@"频段" control:es y:0 width:572]];
            NMPeqCurveView* curve = [[NMPeqCurveView alloc] initWithFrame:NSMakeRect(0, 0, 552, 150)];
            curve.points = rlnative::peq_curve();
            NSView* curveRow = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 572, 170)];
            NSTextField* cl = nm_label(@"频响曲线（只读；改频段用下方文本）", 11.5, NSFontWeightMedium, g_theme.muted);
            cl.frame = NSMakeRect(0, 152, 400, 18);
            [curveRow addSubview:cl];
            curve.frame = NSMakeRect(0, 0, 552, 148);
            [curveRow addSubview:curve];
            [rows addObject:curveRow];
            [rows addObject:[self formRow:@"保存" control:[self sectionButton:@"保存 PEQ" action:@selector(cmdPeqSave:)] y:0 width:572]];
            [rows addObject:[self formRow:@"EQ 文件" control:[self formField:@"eq" width:400] y:0 width:572]];
            [rows addObject:[self formRow:@"卷积 IR" control:[self formField:@"ir" width:400] y:0 width:572]];
            [rows addObject:[self formRow:@"IR 用 GPU" control:[self formPopup:@"irgpu" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self infoText:@"格式：序号,类型,频率,增益,Q,on/off；每行一段。"]];
            break;
        }
        case 5: {
            [rows addObject:[self formRow:@"耳机型号 (productId)" control:[self formField:@"opraproduct" width:300] y:0 width:572]];
            [rows addObject:[self formRow:@"搜索" control:[self sectionButton:@"搜索 OPRA 预设" action:@selector(cmdOpraSearch:)] y:0 width:572]];
            _settingsPresetTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 552, 160)];
            _settingsPresetTable.headerView = nil;
            _settingsPresetTable.rowHeight = 26;
            _settingsPresetTable.dataSource = self;
            _settingsPresetTable.delegate = self;
            NSTableColumn* c = [[NSTableColumn alloc] initWithIdentifier:@"p"];
            c.width = 540;
            [_settingsPresetTable addTableColumn:c];
            NSScrollView* ps = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 552, 160)];
            ps.hasVerticalScroller = YES;
            ps.documentView = _settingsPresetTable;
            [rows addObject:[self formRow:@"预设列表" control:ps y:0 width:572]];
            [rows addObject:[self formRow:@"应用" control:[self sectionButton:@"应用所选 OPRA 预设" action:@selector(cmdOpraApply:)] y:0 width:572]];
            [rows addObject:[self infoText:@"应用后会写入 EQ 配置；OPRA 数据来自内置 opra_index.json。"]];
            break;
        }
        case 6: {
            const auto st = rlnative::library_stats();
            [rows addObject:[self infoText:[NSString stringWithFormat:@"曲目 %d · 专辑 %d · 扫描 %s · 失败目录 %d",
                                            st.tracks, st.albums, st.scanning ? "进行中" : "空闲", st.failedDirs]]];
            [rows addObject:[self formRow:@"扫描线程" control:[self formField:@"scanthreads" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"增量扫描" control:[self sectionButton:@"开始增量扫描" action:@selector(cmdScanLibrary:)] y:0 width:572]];
            [rows addObject:[self formRow:@"全量重扫" control:[self sectionButton:@"开始全量重扫" action:@selector(cmdRescanLibrary:)] y:0 width:572]];
            [rows addObject:[self formRow:@"元数据补全" control:[self formPopup:@"metaon" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"LLM 整理" control:[self formPopup:@"metallm" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"AI 综合" control:[self formPopup:@"metasummary" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"AI 填充" control:[self formPopup:@"metaaifill" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"源顺序" control:[self formField:@"metasrcorder" width:400] y:0 width:572]];
            [rows addObject:[self formRow:@"根目录" control:[self sectionButton:@"添加根目录…" action:@selector(cmdAddRoot:)] y:0 width:572]];
            [rows addObject:[self formRow:@"清理" control:[self sectionButton:@"清理缺失曲目" action:@selector(cmdPrune:)] y:0 width:572]];
            [rows addObject:[self formRow:@"封面" control:[self sectionButton:@"预热全部专辑封面" action:@selector(cmdPrefetchCovers:)] y:0 width:572]];
            {
                const auto prov = rta::net::json_parse(rlnative::providers_json());
                for (const auto& it : prov["items"].arr) {
                    NSString* key = [NSString stringWithFormat:@"metasrc_%s", it["id"].s().c_str()];
                    NSString* label = [NSString stringWithFormat:@"数据源：%s", it["name"].s().c_str()];
                    if (_uiValues[std::string(key.UTF8String)] .empty())
                        _uiValues[std::string(key.UTF8String)] = it["on"].b ? "1" : "0";
                    [rows addObject:[self formRow:label
                                          control:[self formPopup:key values:@[@"1", @"0"] titles:@[@"开启", @"关闭"] width:160]
                                                y:0 width:572]];
                }
            }
            break;
        }
        case 7: {
            if (_uiValues["srckind"].empty()) {
                const auto cfg = rlnative::source_config();
                _uiValues["srckind"] = cfg.kind.empty() ? "subsonic" : cfg.kind;
                _uiValues["srcbase"] = cfg.base;
                _uiValues["srcuser"] = cfg.user;
                _uiValues["srcpass"] = "";
            }
            [rows addObject:[self formRow:@"类型" control:[self formField:@"srckind" width:180] y:0 width:572]];
            [rows addObject:[self formRow:@"服务器地址" control:[self formField:@"srcbase" width:320] y:0 width:572]];
            [rows addObject:[self formRow:@"用户名" control:[self formField:@"srcuser" width:220] y:0 width:572]];
            [rows addObject:[self formRow:@"密码" control:[self formField:@"srcpass" width:220] y:0 width:572]];
            [rows addObject:[self formRow:@"保存" control:[self sectionButton:@"保存并测试连接" action:@selector(cmdSourceSave:)] y:0 width:572]];
            [rows addObject:[self formRow:@"浏览" control:[self sectionButton:@"打开流媒体浏览页" action:@selector(cmdOpenRemotePage:)] y:0 width:572]];
            [rows addObject:[self infoText:@"支持 Subsonic / Emby（与网页端同一 SourceManager）。"]];
            break;
        }
        case 8: {
            const auto stats = rta::net::json_parse(rlnative::health_stats_json());
            [rows addObject:[self infoText:[NSString stringWithFormat:@"分析缓存 %d · 命中 %d · 运行 %d · 取消 %d",
                                            (int)stats["cache"].n(), (int)stats["hits"].n(),
                                            (int)stats["runs"].n(), (int)stats["cancelled"].n()]]];
            [rows addObject:[self formRow:@"播放即分析" control:[self formPopup:@"autoanl" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"分析当前曲目" control:[self sectionButton:@"分析当前曲目（CPU 密集）" action:@selector(cmdAnalyzeCurrent:)] y:0 width:572]];
            _npAnalysisLabel = nm_label(@"", 11.5, NSFontWeightRegular, g_theme.muted);
            _npAnalysisLabel.frame = NSMakeRect(0, 0, 552, 80);
            _npAnalysisLabel.maximumNumberOfLines = 4;
            [rows addObject:[self formRow:@"结果" control:_npAnalysisLabel y:0 width:572]];
            [rows addObject:[self formRow:@"元数据补全" control:[self sectionButton:@"补全当前曲目元数据" action:@selector(cmdEnrichCurrent:)] y:0 width:572]];
            [rows addObject:[self formRow:@"LLM 月配额" control:[self formField:@"llmmonthlycap" width:140] y:0 width:572]];
            [rows addObject:[self infoText:@"分析只读取文件、不写标签；结果只进内存缓存。"]];
            break;
        }
        case 9: {
            _castDevices = rlnative::cast_devices();
            NSMutableArray* names = [NSMutableArray array];
            NSMutableArray* ids = [NSMutableArray array];
            for (const auto& d : _castDevices) {
                [names addObject:[NSString stringWithFormat:@"%s%s", d.name.c_str(), d.airplay ? @" (AirPlay)" : @" (UPnP)"]];
                [ids addObject:[NSString stringWithUTF8String:d.id.c_str()]];
            }
            if (names.count == 0) { [names addObject:@"（未发现投放设备）"]; [ids addObject:@""]; }
            [rows addObject:[self formRow:@"设备" control:[self formPopup:@"castdev" values:ids titles:names width:320] y:0 width:572]];
            [rows addObject:[self formRow:@"操作" control:[self sectionButton:@"开始投放当前曲目" action:@selector(cmdCastStart:)] y:0 width:572]];
            [rows addObject:[self formRow:@"停止" control:[self sectionButton:@"停止投放" action:@selector(cmdCastStop:)] y:0 width:572]];
            [rows addObject:[self formRow:@"扫描" control:[self sectionButton:@"重新扫描设备" action:@selector(cmdCastScan:)] y:0 width:572]];
            [rows addObject:[self formRow:@"状态" control:[self infoText:[[NSString alloc] initWithUTF8String:rlnative::cast_state_json().c_str()]] y:0 width:572]];
            [rows addObject:[self formRow:@"投放升频" control:[self formPopup:@"cast_upsample" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            [rows addObject:[self formRow:@"NAA 主机" control:[self formField:@"naahost" width:300] y:0 width:572]];
            [rows addObject:[self formRow:@"UPnP 设备" control:[self formField:@"upnpdev" width:300] y:0 width:572]];
            break;
        }
        case 10: {
            if (_uiValues["inmode"].empty()) _uiValues["inmode"] = "record";
            _inputDevices = rlnative::input_devices();
            NSMutableArray* names = [NSMutableArray array];
            NSMutableArray* ids = [NSMutableArray array];
            for (const auto& d : _inputDevices) {
                [names addObject:[NSString stringWithFormat:@"%s%@", d.name.c_str(), d.loopback ? @"（回环）" : @""]];
                [ids addObject:[NSString stringWithUTF8String:d.id.c_str()]];
            }
            if (names.count == 0) { [names addObject:@"（未枚举到输入设备）"]; [ids addObject:@""]; }
            [rows addObject:[self formRow:@"输入设备" control:[self formPopup:@"indev" values:ids titles:names width:300] y:0 width:572]];
            [rows addObject:[self formRow:@"模式" control:[self formPopup:@"inmode" values:@[@"record", @"monitor", @"null"] titles:@[@"录制", @"监听（会出声）", @"空跑"] width:220] y:0 width:572]];
            [rows addObject:[self formRow:@"时长 (s)" control:[self formField:@"inseconds" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"开始" control:[self sectionButton:@"开始采集" action:@selector(cmdInputStart:)] y:0 width:572]];
            [rows addObject:[self formRow:@"停止" control:[self sectionButton:@"停止采集" action:@selector(cmdInputStop:)] y:0 width:572]];
            [rows addObject:[self formRow:@"输出" control:[self formField:@"inout" width:300] y:0 width:572]];
            [rows addObject:[self formRow:@"后端" control:[self formField:@"inbackend" width:220] y:0 width:572]];
            [rows addObject:[self formRow:@"缓冲" control:[self formField:@"inbuf" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"偏移" control:[self formField:@"inoffset" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"监听" control:[self formPopup:@"inmon" values:@[@"0", @"1"] titles:@[@"关闭", @"开启"] width:160] y:0 width:572]];
            break;
        }
        case 11: {
            const auto layouts = rta::net::json_parse(rlnative::room_layouts_json());
            NSMutableArray* names = [NSMutableArray array];
            for (const auto& l : layouts["layouts"].arr) {
                NSString* n = [NSString stringWithUTF8String:l["name"].s().c_str()];
                [names addObject:[NSString stringWithFormat:@"%@ (%d ch)", n, (int)l["ch"].n()]];
            }
            if (names.count == 0) [names addObject:@"（无可用布局）"];
            if (_uiValues["roomlayout"].empty()) _uiValues["roomlayout"] = ((NSString*)names.firstObject).UTF8String ?: "";
            if (_uiValues["roomsec"].empty()) _uiValues["roomsec"] = "6";
            [rows addObject:[self formRow:@"布局" control:[self formPopup:@"roomlayout" values:names titles:names width:260] y:0 width:572]];
            [rows addObject:[self formRow:@"扫频时长 (s)" control:[self formField:@"roomsec" width:120] y:0 width:572]];
            [rows addObject:[self formRow:@"开始测量" control:[self sectionButton:@"开始测量（会发声）" action:@selector(cmdRoomMeasure:)] y:0 width:572]];
            [rows addObject:[self formRow:@"取消" control:[self sectionButton:@"取消测量" action:@selector(cmdRoomCancel:)] y:0 width:572]];
            const auto st = rta::net::json_parse(rlnative::room_status_json());
            [rows addObject:[self formRow:@"状态" control:[self infoText:[NSString stringWithFormat:@"%s/%s · %d/%d",
                st["phase"].s().c_str(), st["currentChannel"].s().c_str(),
                (int)st["channelsDone"].n(), (int)st["channelsTotal"].n()]] y:0 width:572]];
            [rows addObject:[self infoText:@"测量会通过扬声器播放扫频，测试前请确认音量。"]];
            break;
        }
        case 12: {
            [rows addObject:[self infoText:[NSString stringWithFormat:@"当前版本 %s（arm64）", RLPLAYER_VERSION_STR]]];
            [rows addObject:[self formRow:@"更新通道" control:[self formPopup:@"updatechannel" values:@[@"global", @"cn"] titles:@[@"全球通道（GitHub）", @"中国大陆通道"] width:240] y:0 width:572]];
            [rows addObject:[self formRow:@"预发布" control:[self formPopup:@"updbeta" values:@[@"0", @"1"] titles:@[@"不接收 beta", @"接收 beta"] width:200] y:0 width:572]];
            [rows addObject:[self formRow:@"检查" control:[self sectionButton:@"检查更新…" action:@selector(cmdCheckUpdate:)] y:0 width:572]];
            [rows addObject:[self infoText:@"更新会下载 DMG → 校验 sha256/size → 挂载 → 替换 .app。"]];
            break;
        }
        case 13: {
            [rows addObject:[self formRow:@"诊断包" control:[self sectionButton:@"导出诊断 zip" action:@selector(cmdExportDiag:)] y:0 width:572]];
            [rows addObject:[self formRow:@"反馈" control:[self sectionButton:@"撰写反馈邮件（附诊断）" action:@selector(cmdSendFeedback:)] y:0 width:572]];
            [rows addObject:[self infoText:@"诊断包含版本、系统、日志与设置快照；不包含音乐文件内容。"]];
            break;
        }
        default: {
            [rows addObject:[self infoText:[NSString stringWithFormat:@"RLPlayer %s · arm64 · GPL-3.0-or-later", RLPLAYER_VERSION_STR]]];
            [rows addObject:[self infoText:@"上游 rainlain（okhuoyanyan）/ macOS 分支 BH2VOQ"]];
            [rows addObject:[self infoText:@"纯 AppKit 原生界面；播放核心与网页端共用同一 C++ 实现。"]];
            [rows addObject:[self formRow:@"项目主页" control:[self infoText:@"github.com/BH2VOQ/RLPlayer-Mac"] y:0 width:572]];
            break;
        }
    }
    return rows;
}

- (void)showSettingsSection:(NSInteger)idx {
    if (!_settingsWindow) { [self openSettings]; idx = MAX(0, MIN(idx, 14)); }
    _settingsSectionIndex = MAX(0, MIN(idx, 14));
    [_settingsSections selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)_settingsSectionIndex]
                  byExtendingSelection:NO];
    NSView* page = [self sectionPage:[self settingsRowsForSection:_settingsSectionIndex]];
    _settingsScroll.documentView = page;
}

- (void)tableViewSelectionDidChange:(NSNotification*)note {
    if (note.object == _settingsSections) {
        const NSInteger row = _settingsSections.selectedRow;
        if (row >= 0 && row != _settingsSectionIndex) { _settingsSectionIndex = row; [self showSettingsSection:row]; }
        return;
    }
}

- (void)settingsSectionSelected:(id)s {
    (void)s;
    const NSInteger row = _settingsSections.selectedRow;
    if (row < 0) return;
    _settingsSectionIndex = row;
    [self showSettingsSection:row];
}

- (void)openSettings {
    if (_settingsWindow) { [_settingsWindow makeKeyAndOrderFront:nil]; [self showSettingsSection:_settingsSectionIndex]; return; }
    [self reloadSettings];
    NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 880, 620)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"设置";
    w.minSize = NSMakeSize(760, 520);
    [w center];
    _settingsWindow = w;
    NSView* root = w.contentView;

    _settingsSections = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 190, 620)];
    _settingsSections.headerView = nil;
    _settingsSections.rowHeight = 34;
    _settingsSections.style = NSTableViewStyleSourceList;
    _settingsSections.dataSource = self;
    _settingsSections.delegate = self;
    _settingsSections.target = self;
    _settingsSections.action = @selector(settingsSectionSelected:);
    NSTableColumn* c = [[NSTableColumn alloc] initWithIdentifier:@"s"];
    c.width = 180;
    [_settingsSections addTableColumn:c];
    NSScrollView* ls = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 190, 620)];
    ls.hasVerticalScroller = YES;
    ls.drawsBackground = NO;
    ls.documentView = _settingsSections;
    [root addSubview:ls];

    _settingsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(190, 0, 690, 620)];
    _settingsScroll.hasVerticalScroller = YES;
    _settingsScroll.drawsBackground = NO;
    [root addSubview:_settingsScroll];

    [w makeKeyAndOrderFront:nil];
    [self showSettingsSection:0];
}

- (NSString*)selectedSettingsValue:(NSString*)key fallback:(NSString*)fb {
    const auto it = _settings.find(std::string(key.UTF8String));
    return it == _settings.end() ? fb : [NSString stringWithUTF8String:it->second.c_str()];
}

- (void)cmdResetBuffer:(id)s {
    (void)s;
    rta::net::HttpRequest rq; rq.method = "POST"; rq.path = "/api/buffer/reset";
    std::string ct; (void)rlapp::dispatch(rq, ct);
    [self toast:@"缓冲已复位"];
}

- (void)cmdPeqApplyPreset:(NSPopUpButton*)sender {
    NSString* name = [sender.titleOfSelectedItem stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (name.length && ![name isEqualToString:@"—"]) {
        rlnative::peq_apply_preset(std::string(name.UTF8String));
        [self showSettingsSection:4];
    }
}
- (void)cmdPeqSave:(id)s {
    (void)s;
    std::vector<rlnative::PeqBand> bands;
    NSString* text = _settingsPeqEditor.string;
    for (NSString* line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0 || [line hasPrefix:@"（"]) continue;
        char type[16] = {0};
        int idx = 0; double f = 1000, g = 0, q = 1.41; char tail[16] = {0};
        if (std::sscanf(line.UTF8String, "%d,%15[^,],%lf,%lf,%lf,%15s", &idx, type, &f, &g, &q, tail) >= 4) {
            rlnative::PeqBand b;
            b.index = idx > 0 ? idx : (int)bands.size() + 1;
            b.type = type;
            b.freq = f; b.gain = g; b.q = q;
            b.on = std::string(tail).find("off") == std::string::npos;
            bands.push_back(b);
        }
    }
    if (bands.empty()) { [self toast:@"没有可解析的 PEQ 频段"]; return; }
    const bool bypass = [[self uiValue:@"peqbypass"] isEqualToString:@"1"];
    const bool ok = rlnative::peq_save(bands, bypass, [[self uiValue:@"peqpreamp"] doubleValue], "native");
    [self toast:ok ? @"PEQ 已保存" : @"PEQ 保存失败"];
    [self showSettingsSection:4];
}
- (void)cmdOpraSearch:(id)s {
    (void)s;
    rlnative::settings_save({{"opraproduct", std::string([self selectedSettingsValue:@"opraproduct" fallback:@"" ].UTF8String)}});
    NSString* product = [self selectedSettingsValue:@"opraproduct" fallback:@""];
    const auto presets = rlnative::opra_presets(std::string(product.UTF8String));
    [_settingsPresets removeAllObjects];
    for (const auto& p : presets) [_settingsPresets addObject:[NSString stringWithFormat:@"%s  (%s)", p.name.c_str(), p.id.c_str()]];
    if (_settingsPresets.count == 0) [_settingsPresets addObject:@"（没有匹配的 OPRA 预设）"];
    [self showSettingsSection:5];
}
- (void)cmdOpraApply:(id)s {
    const NSInteger row = _settingsPresetTable.selectedRow;
    if (row < 0 || (NSUInteger)row >= _settingsPresets.count) return;
    NSString* line = _settingsPresets[(NSUInteger)row];
    NSRange r = [line rangeOfString:@"("];
    if (r.location == NSNotFound) { [self toast:@"请选择一个 OPRA 预设"]; return; }
    NSString* pid = [[line substringFromIndex:r.location + 1] stringByReplacingOccurrencesOfString:@")" withString:@""];
    pid = [pid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString* product = [self uiValue:@"opraproduct"];
    const bool ok = rlnative::opra_apply(std::string(product.UTF8String), std::string(pid.UTF8String));
    [self toast:ok ? @"已应用 OPRA 预设" : @"应用失败"];
}
- (void)cmdSourceSave:(id)s {
    (void)s;
    NSString* kind = [self selectedSettingsValue:@"srckind" fallback:@"subsonic"];
    NSString* base = [self selectedSettingsValue:@"srcbase" fallback:@""];
    NSString* user = [self selectedSettingsValue:@"srcuser" fallback:@""];
    NSString* pass = [self selectedSettingsValue:@"srcpass" fallback:@""];
    const bool ok = rlnative::source_save(std::string(kind.UTF8String), std::string(base.UTF8String),
                                          std::string(user.UTF8String), std::string(pass.UTF8String));
    [self toast:ok ? @"流媒体配置已保存" : @"保存失败"];
}
- (void)cmdOpenRemotePage:(id)s { (void)s; [self showPage:NMPageStreaming pushHistory:YES]; }
- (void)cmdAnalyzeCurrent:(id)s {
    (void)s;
    if (_snap.current.empty()) { [self toast:@"当前没有播放曲目"]; return; }
    const std::string j = rlnative::health_report_json(_snap.current);
    const auto doc = rta::net::json_parse(j);
    const auto h = doc["health"];
    _npAnalysisLabel.stringValue = [NSString stringWithFormat:
        @"LRA %.1f LU · 峰值 %.2f dBFS · RMS %.2f dBFS\n响度 %.1f LUFS · 削波 %.2f%% · DR %.1f dB%\n%@",
        h["lra"].n(), h["peak_dbfs"].n(), h["rms_dbfs"].n(), h["lufs"].n(),
        h["clipped_pct"].n(), h["dr_db"].n(),
        h["lossless_suspected"].b ? @"疑似假无损" : @""];
}
- (void)cmdEnrichCurrent:(id)s {
    if (_snap.current.empty()) { [self toast:@"当前没有播放曲目"]; return; }
    const bool ok = rlnative::enrich_track(_snap.current);
    [self toast:ok ? @"已请求元数据补全" : @"补全失败"];
}
- (void)cmdCastStart:(id)s {
    NSString* dev = [self selectedSettingsValue:@"castdev" fallback:@""];
    if (dev.length == 0) { [self toast:@"先选择一个投放设备"]; return; }
    std::string err;
    [self toast:rlnative::cast_start(std::string(dev.UTF8String), err) ?
        @"投放已开始（本地播放已停止）" : [NSString stringWithFormat:@"投放失败：%s", err.c_str()]];
    [self showSettingsSection:9];
}
- (void)cmdCastStop:(id)s { (void)s; rlnative::cast_stop(); [self showSettingsSection:9]; }
- (void)cmdCastScan:(id)s { (void)s; _castDevices = rlnative::cast_devices(); [self showSettingsSection:9]; }
- (void)cmdInputStart:(id)s {
    NSString* dev = [self selectedSettingsValue:@"indev" fallback:@""];
    NSString* mode = [self selectedSettingsValue:@"inmode" fallback:@"record"];
    if ([mode isEqualToString:@"monitor"]) {
        NSAlert* a = [[NSAlert alloc] init];
        a.messageText = @"监听模式会把输入直接送到输出设备（可能出声）";
        [a addButtonWithTitle:@"继续"];
        [a addButtonWithTitle:@"取消"];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
    }
    std::string err;
    [self toast:rlnative::input_start(std::string(dev.UTF8String), std::string(mode.UTF8String), err) ?
        @"采集已开始" : [NSString stringWithFormat:@"采集失败：%s", err.c_str()]];
}
- (void)cmdInputStop:(id)s { (void)s; rlnative::input_stop(); [self showSettingsSection:10]; }
- (void)cmdRoomMeasure:(id)s {
    NSString* layout = [self selectedSettingsValue:@"roomlayout" fallback:@""];
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"房间测量会通过扬声器播放扫频";
    a.informativeText = @"请确认当前音量可接受；测量期间请保持安静。";
    [a addButtonWithTitle:@"开始测量"];
    [a addButtonWithTitle:@"取消"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    std::string err;
    const bool ok = rlnative::room_measure(std::string(layout.UTF8String), 6.0, err);
    [self toast:ok ? @"测量已开始" : [NSString stringWithFormat:@"测量失败：%s", err.c_str()]];
    [self showSettingsSection:11];
}
- (void)cmdRoomCancel:(id)s { (void)s; rlnative::room_cancel(); [self showSettingsSection:11]; }
- (void)cmdAddRoot:(id)s {
    (void)s;
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"添加音乐库根目录";
    [a addButtonWithTitle:@"添加"];
    [a addButtonWithTitle:@"取消"];
    NSTextField* f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 24)];
    f.placeholderString = @"/Users/you/Music";
    a.accessoryView = f;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSString* path = [f.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (path.length == 0) return;
    rta::net::HttpRequest rq; rq.method = "POST"; rq.path = "/api/lib/roots";
    rq.body = "add=" + std::string(path.UTF8String);
    std::string ct; (void)rlapp::dispatch(rq, ct);
    rlnative::scan_library(false);
    [self toast:@"已添加根目录并开始扫描"];
}
- (void)cmdPrefetchCovers:(id)s {
    (void)s;
    [self toast:rlnative::cover_prefetch_all() ? @"已开始后台抓取封面" : @"启动失败"];
}
- (void)cmdPrune:(id)s {
    (void)s;
    rta::net::HttpRequest rq; rq.method = "POST"; rq.path = "/api/lib/prune";
    std::string ct; const auto j = rta::net::json_parse(rlapp::dispatch(rq, ct));
    [self toast:[NSString stringWithFormat:@"已清理 %d 首缺失曲目", (int)j["removed"].n()]];
}

- (void)cmdExportDiag:(id)s { (void)s; [self exportDiagnostics]; }
- (void)cmdSendFeedback:(id)s { (void)s; [self sendFeedback]; }
- (void)exportDiagnostics {
    std::string path;
    if (rlnative::diag_export(path).empty()) { [self toast:@"诊断包导出失败"]; return; }
    NSString* p = [NSString stringWithUTF8String:path.c_str()];
    [[NSWorkspace sharedWorkspace] selectFile:p inFileViewerRootedAtPath:@""];
    [self toast:[NSString stringWithFormat:@"诊断包已导出：%@", p]];
}
- (void)sendFeedback {
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText = @"反馈问题";
    a.informativeText = @"描述问题与复现步骤；可附上诊断包（不含音乐内容）。";
    [a addButtonWithTitle:@"打开发送窗口"];
    [a addButtonWithTitle:@"取消"];
    NSView* box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 150)];
    NSTextField* subject = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 118, 460, 24)];
    subject.stringValue = [NSString stringWithFormat:@"RLPlayer %s 反馈", RLPLAYER_VERSION_STR];
    [box addSubview:subject];
    NSTextView* body = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 34, 460, 78)];
    body.string = @"请描述：\\n1) 发生了什么\\n2) 复现步骤\\n3) 期望结果\\n";
    NSScrollView* bs = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 34, 460, 78)];
    bs.hasVerticalScroller = YES;
    bs.documentView = body;
    [box addSubview:bs];
    NSButton* attach = [NSButton checkboxWithTitle:@"附上诊断包" target:nil action:nil];
    attach.frame = NSMakeRect(0, 6, 200, 20);
    attach.state = NSControlStateValueOn;
    [box addSubview:attach];
    a.accessoryView = box;
    if ([a runModal] != NSAlertFirstButtonReturn) return;

    std::string zip;
    std::vector<std::string> atts;
    if (attach.state == NSControlStateValueOn && !rlnative::diag_export(zip).empty()) atts.push_back(zip);
    const auto r = rta::feedback::open_compose_window(std::string(subject.stringValue.UTF8String),
                                                     std::string(body.string.UTF8String), atts, "");
    [self toast:r.outcome == rta::feedback::ComposeOutcome::Opened ? @"已打开发送窗口（不会自动发送）"
            : r.outcome == rta::feedback::ComposeOutcome::FellBackToEml ? @"已保存 .eml 兜底文件"
            : @"无法打开邮件窗口"];
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
        } else if ([key isEqualToString:@"lang"]) {
            g_langEn = [value isEqualToString:@"en"];
            rlnative::settings_save({{"lang", std::string(value.UTF8String)}});
            nm_translate_menu(NSApp.mainMenu);
            nm_translate_view(self.window.contentView);
            [self showPage:_page_ pushHistory:NO];
            if (_settingsWindow) nm_translate_view(_settingsWindow.contentView);
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
    _uiValues[std::string(key.UTF8String)] = std::string(value.UTF8String);
    if ([key hasPrefix:@"peq"] || [key hasPrefix:@"src"] || [key isEqualToString:@"castdev"] ||
        [key isEqualToString:@"indev"] || [key isEqualToString:@"inmode"] ||
        [key isEqualToString:@"inseconds"] || [key isEqualToString:@"inout"] ||
        [key isEqualToString:@"roomlayout"] || [key isEqualToString:@"roomsec"] ||
        [key hasPrefix:@"room"]) {
        return;   // 伪键：由各自动作保存，不写 rlplayer-settings.conf
    }
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
        nm_set_border(_playerBar, 1.0, g_theme.separator);
        _playerBar.needsDisplay = YES;
    }
    if (_queueRail) {
        nm_set_border(_queueRail, 1.0, g_theme.separator);
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
