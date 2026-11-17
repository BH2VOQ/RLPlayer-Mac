// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSupport.h — 原生 UI 的公共小工具（翻译/格式化/封面/提示/按钮/动作）
//
// 统一放在这里的目的：页面之间不各写一套格式化与封面缓存；i18n 只有一个入口
// （RLPTr），将来把 docs/i18n 的词表生成为原生表时，所有已包 RLPTr 的文案自动生效。
#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// 中文原文 → 当前语言。词表未命中时原样返回中文（与 web 版"回落中文"同口径）。
NSString *RLPTr(NSString *zh);
/// 设置语言（"zh"/"en"）。原生 UI 在设置读取后调用；未设置时按中文。
void RLPSetLanguage(NSString * _Nullable lang);
NSString *RLPLanguage(void);

/// 读**已落盘**的界面语言（state 目录 rlplayer-settings.conf 的 lang，"zh"/"en"）。
/// 缺失或非法返回 nil。与 web 同口径（src/net/ui_page.h 的 read_conf_value）：
/// 配置文件是语言优先级的唯一真相源，不靠后端 GET。
NSString * _Nullable RLPLanguageFromConf(void);
/// 启动早期（建菜单/建窗口之前）调用：把落盘语言应用到 RLPTr。
/// 那时核心还没起来，所以只读 conf —— 这也是"每次 RLPTr 都不打后端"的保证。
void RLPApplyLanguageFromConf(void);

/// 时长："m:ss" / "h:mm:ss"；非有限值返回 "0:00"。
NSString *RLPFmtDuration(double seconds);
/// 字节数："12.3 MB"。
NSString *RLPFmtBytes(double bytes);
/// URL query 编码（key/路径进 URL 时统一走这里）。
NSString *RLPEnc(NSString *s);

/// 专辑封面共享缓存（512px 缩略图由后端 /api/lib/cover 提供）。
@interface RLPCoverLoader : NSObject
+ (instancetype)shared;
/// completion 在主线程；失败回 nil（不重试、不阻塞）。
- (void)coverForAlbumKey:(NSString *)key completion:(void (^)(NSImage * _Nullable image))completion;
- (nullable NSImage *)cachedCoverForAlbumKey:(NSString *)key;
/// 流媒体封面（/api/src/cover?id=coverId）。与专辑封面同一缓存，key 加 src: 前缀避免撞。
- (void)coverForSourceId:(NSString *)coverId completion:(void (^)(NSImage * _Nullable image))completion;
@end

/// 封面视图：按 web `object-fit:cover` 语义绘制 —— 等比放大铺满并裁掉溢出，绝不 letterbox。
/// NSImageView 默认的 NSImageScaleProportionallyUpOrDown 在非正方形容器里会留白边
/// （用户实测：原生专辑页封面四边白条，web 版铺满无白边）。
@interface RLPCoverImageView : NSImageView
@end

/// 内层滚动容器：当自身在该方向上不可滚动时，把滚轮事件交给外层整页滚动。
/// 用户实测：专辑页鼠标停在曲目列表/其他作品条上时滚轮失灵 —— 内层 NSScrollView
/// 吃掉了事件却无处可滚。web 只有一个整页滚动容器（.main{overflow:auto}）。
@interface RLPForwardingScrollView : NSScrollView
@end

/// 轻提示（非模态，1.8s 淡出）。用于"已加入队列""已收藏"这类反馈。
void RLPToast(NSString *message);
/// 播放错误显示短摘要，完整诊断按需查看/复制。
void RLPPlaybackErrorToast(NSString *error);

/// 模态提示（必须让用户看见的失败；例如更新失败）。主线程调用。
void RLPAlert(NSString *title, NSString *message);

/// 文本输入对话框（web 版 askText 的原生对应：标题 / 输入框 + 占位符 / 提示小字 / 确定·取消）。
/// 返回 nil = 取消或输入为空（两侧都 trim）。主线程调用。
NSString * _Nullable RLPAskText(NSString *title, NSString *okTitle, NSString *value,
                                NSString * _Nullable placeholder, NSString * _Nullable hint);

/// 行悬停底色（web `.trow:hover`）：NSTableRowView 自己收 mouseEntered/Exited 并绘制底色。
/// 表格页只需在 `-tableView:rowViewForRow:` 返回它、给 hoverColor。
@interface RLPHoverRowView : NSTableRowView
@property (nonatomic, strong, nullable) NSColor *hoverColor;
/// 判据入口：直接设悬停态（真实路径是 tracking area 的 mouseEntered/Exited）。
- (void)setHoveredForAudit:(BOOL)hovered;
@property (nonatomic, readonly) BOOL hoveredForAudit;
@end

/// 系统符号按钮（无边框、模板着色）。
NSButton *RLPSymbolButton(NSString *symbol, NSString *tooltip, id _Nullable target, SEL _Nullable action);
/// 单行标签（默认 13px；颜色/字体可后改）。
NSTextField *RLPLabel(NSString *text, NSFont *font, NSColor *color);

/// 卡片式弹层（NSPopover 封装）：从 anchorView 下方弹出一张卡片，选完即时生效。
/// 用户要求「全部就在这一栏里用卡片式弹层完成」——不是模态 sheet、不是跳设置页。
/// content 由调用方搭好（自己负责约束与主题）；返回 popover 以便调用方主动关闭。
NSPopover *RLPShowCardPopover(NSView *anchorView, NSViewController *content, CGFloat width);
/// 便捷：把一个普通 NSView 包成弹层内容控制器（高度按约束自适应，给定最小高度）。
NSViewController *RLPCardController(NSView *card, CGFloat width, CGFloat minHeight);

/// 页面间导航（广播）：专辑详情 / 艺术家详情 / 返回。
/// 用通知而不是互相持有：页面只发意图，主窗口负责路由与返回栈。
extern NSNotificationName const RLPOpenAlbumNotification;   // object = album key(NSString)
extern NSNotificationName const RLPOpenArtistNotification;  // object = artist name(NSString)
extern NSNotificationName const RLPBackNotification;
/// 设置/预设/配置档成功保存后的跨页面同步通知（object = 发起保存的控制器，接收方忽略 object == self 防环）。
extern NSNotificationName const RLPSettingsChangedNotification;
/// 运行时界面语言变更通知（object = 发起切换的控制器或 nil）。
extern NSNotificationName const RLPLanguageDidChangeNotification;
/// 播放控制动作（play/lib/play/skip/pause/stop）开始通知：用于作废在途 /api/status 轮询。
extern NSNotificationName const RLPPlaybackActionStartedNotification;
/// 收藏状态变更后的跨页面同步通知（object = 发起变更的控制器或锚点视图，接收方忽略 object == self 防环）。
extern NSNotificationName const RLPFavoritesChangedNotification;
/// 队列内容变更后的跨页面同步通知（如单曲入队成功）。
extern NSNotificationName const RLPQueueChangedNotification;
/// 收藏路径规范化：统一 "\\" 与 "/" 以便与 /api/fav/list 准确比对。
NSString *RLPFavNormalizePath(NSString * _Nullable path);

/// 解析设置中的 dsd 值（支持纯数字 "0"/"64"/"256" 与 legacy "dop256"/"nat128"/"native64"）。
NSInteger RLPParseDsdRate(id _Nullable raw);
/// 判断文本框是否正在被用户编辑（通知刷新时跳过覆写，避免打断输入）。
BOOL RLPTextFieldIsEditing(NSTextField * _Nullable tf);
void RLPRequestOpenAlbum(NSString *albumKey);
void RLPRequestOpenArtist(NSString *artistName);
void RLPRequestBack(void);

/// 播放/入队动作（与 web 版同一 /api 契约，不复制播放逻辑）。
uint64_t RLPBeginPlaybackAction(void);
uint64_t RLPPlaybackActionEpoch(void);
BOOL RLPHandlePlaybackActionResponse(NSDictionary * _Nullable json, NSString * _Nullable fallbackError);
void RLPReportPlaybackStatusError(NSString * _Nullable error);
void RLPReportPlaybackStatusErrorForTrack(NSString * _Nullable error, NSString * _Nullable path);
void RLPResetPlaybackErrorState(void);
void RLPPlayPath(NSString *path);
/// CUE 分轨：cs/ce >= 0 时带区间（web playPath(file, cs, ce) 同契约），否则退化为整轨。
void RLPPlayPathCue(NSString *path, double cs, double ce);
void RLPPlayAlbum(NSString *albumKey, NSInteger startIndex);
void RLPEnqueuePath(NSString *path);
/// CUE 分轨（tools/rtaweb.cpp parseForm 契约：cue_start / cue_end）。cs < 0 时退化为整首。
void RLPPlayPathCueRange(NSString *path, double cs, double ce);
void RLPPlayAlbumCue(NSString *albumKey, NSInteger startIndex, double cs, double ce);
void RLPEnqueuePathCue(NSString *path, double cs, double ce);
void RLPPostJSON(NSString *path, NSString * _Nullable body);

/// v3.3.11 `toggleVolumeMute` 的**唯一状态**（web `volumeRestore` 是全局单例）。
/// 播放页与底栏两个静音键必须共用同一份记忆值，否则「在播放页静音、到底栏取消静音」会恢复成错误值。
/// 返回应下发的 dB；返回 **NAN** 表示上游语义的「什么都不做」（当前已 -120 且无恢复值）。
double RLPVolumeMuteNextDb(double currentDb);
/// 把窗口 frame 收敛到当前屏幕可见区：超宽/超高的历史 frame（换屏或拖拽越界）会导致
/// 内容被屏幕边缘裁掉。纯函数，便于离线判据；minSize 大于可见区时以可见区为准。
static inline NSRect RLPClampWindowFrameToVisible(NSRect frame, NSRect visible, NSSize minSize) {
    if (visible.size.width <= 1.0 || visible.size.height <= 1.0) return frame;
    NSSize min = minSize;
    if (min.width <= 0 || min.width > visible.size.width) min.width = visible.size.width;
    if (min.height <= 0 || min.height > visible.size.height) min.height = visible.size.height;
    frame.size.width = MAX(MIN(frame.size.width, visible.size.width), min.width);
    frame.size.height = MAX(MIN(frame.size.height, visible.size.height), min.height);
    if (NSMinX(frame) < NSMinX(visible)) frame.origin.x = NSMinX(visible);
    if (NSMaxX(frame) > NSMaxX(visible)) frame.origin.x = NSMaxX(visible) - frame.size.width;
    if (NSMinY(frame) < NSMinY(visible)) frame.origin.y = NSMinY(visible);
    if (NSMaxY(frame) > NSMaxY(visible)) frame.origin.y = NSMaxY(visible) - frame.size.height;
    return frame;
}

/// 多屏下「用哪块屏收敛」的唯一判据（纯函数，便于离线判据）。
/// 窗口**完全落在某一块屏**的可见区时用该屏；窗口跨屏（多显示器并排时 2400–3400pt 宽的合法摆放）
/// 时改用所有屏 visibleFrame 的并集包围盒 —— 否则会被单屏收敛压窄并写回 autosave，
/// 用户下次启动就永远丢掉跨屏宽度（2026-11-18 夜间评审 B1）。
static inline NSRect RLPWindowUsableScreenRect(NSRect windowFrame, const NSRect *visibles, size_t count) {
    if (!visibles || count == 0) return NSZeroRect;
    for (size_t i = 0; i < count; ++i) {
        if (NSContainsRect(visibles[i], windowFrame)) return visibles[i];
    }
    NSRect usable = visibles[0];
    for (size_t i = 1; i < count; ++i) usable = NSUnionRect(usable, visibles[i]);
    return usable;
}

/// 解析 NSWindow autosave 的 frame 字符串（"x y w h"，末尾可能带空格）。
/// 纯 C 解析：不依赖 locale、不做本地化数字格式猜测；任何一段读不出来就判无效（不猜默认值）。
static inline BOOL RLPParseSavedWindowFrame(const char *saved, NSRect *outRect) {
    if (!saved || !outRect) return NO;
    const char *p = saved;
    double v[4] = { 0, 0, 0, 0 };
    for (int i = 0; i < 4; ++i) {
        while (*p == ' ' || *p == '\t') ++p;
        if (!*p) return NO;
        char *end = NULL;
        v[i] = strtod(p, &end);
        if (end == p || v[i] != v[i]) return NO;   // NaN 也要判无效（autosave 可能被写坏）
        p = end;
    }
    *outRect = NSMakeRect((CGFloat)v[0], (CGFloat)v[1], (CGFloat)v[2], (CGFloat)v[3]);
    return YES;
}

/// 启动时的窗口 frame 决策（纯函数）：
/// 有合法保存值 → 用它并向可见区收敛、**不居中**（居中会把副屏/任意位置的 origin 覆盖成主屏中心）；
/// 没有保存值（首次启动或记录损坏）→ 默认尺寸 + 居中。
typedef struct {
    NSRect frame;
    BOOL center;
} RLPWindowStartupFrame;

static inline RLPWindowStartupFrame RLPWindowStartupFrameForSavedState(const char *savedFrame,
                                                                      NSRect defaultFrame,
                                                                      const NSRect *visibles,
                                                                      size_t count,
                                                                      NSSize minSize) {
    RLPWindowStartupFrame out;
    out.frame = defaultFrame;
    out.center = YES;
    NSRect saved = NSZeroRect;
    if (!RLPParseSavedWindowFrame(savedFrame, &saved)) return out;
    out.center = NO;
    out.frame = count > 0
        ? RLPClampWindowFrameToVisible(saved, RLPWindowUsableScreenRect(saved, visibles, count), minSize)
        : saved;
    return out;
}

/// 当前是否有可恢复的记忆值（判据与 UI 可用；对应 web `volumeRestore !== null`）。
BOOL RLPVolumeMuteHasRestore(void);
/// 清空记忆值（上游在「重置/丢弃」路径上会置 null）。
void RLPVolumeMuteReset(void);
/// 静音记忆快照（仅主线程使用）。
typedef struct {
    double restoreDb;
    uint64_t revision;
} RLPVolumeMuteSnapshot;
/// 捕获当前静音恢复记忆（restoreDb 允许为 NAN）与单调 revision（仅主线程使用）。
RLPVolumeMuteSnapshot RLPVolumeMuteCapture(void);
/// 当前全局静音状态 revision（仅主线程使用）。
uint64_t RLPVolumeMuteRevision(void);
/// 条件回滚静音记忆：仅当当前 revision == expectedRevision 且快照不来自未来时，
/// 恢复 snapshot.restoreDb 并递增 revision 返回 YES；否则不修改并返回 NO。
/// 仅恢复内存中的静音记忆状态，不写音频设备、不发网络请求（仅主线程使用）。
BOOL RLPVolumeMuteRollback(RLPVolumeMuteSnapshot snapshot, uint64_t expectedRevision);
/// 播放/暂停的**唯一决策**（与 web playOrPause 同语义）：
///   播放中（playing && !paused）→ /api/pause?on=1
///   暂停中（paused）             → /api/pause?on=0
///   已停止但知道当前曲目         → /api/play（只发 pause 不会有任何反应，web 同口径重播）
///   以上都不是                   → 不发请求
/// 底栏、播放页、菜单/媒体键三入口都必须走这里，避免各自维护一份会漂移的判定。
void RLPPlaybackToggle(BOOL playing, BOOL paused, NSString * _Nullable currentPath);
/// 显式暂停（系统 pauseCommand 的语义）：永远发 /api/pause?on=1，不看 UI 状态快照。
/// 为什么不能用复选框判定：状态轮询 0.5s 一拍，后台被 App Nap 降频/某次请求丢失时快照可能是旧的，
/// 「用户明确要求暂停」不能因为旧快照而静默不发请求。
void RLPPlaybackPauseExplicit(void);
/// 显式继续/重播（系统 playCommand 的语义）：已在播→什么都不做；暂停中→on=0；已停止且有曲目→重播。
void RLPPlaybackResumeOrReplay(BOOL playing, BOOL paused, NSString * _Nullable currentPath);

/// 整列顺序播放（对齐 web playWholeListFrom）：先用 /api/queue/set 以给定路径列表建队列，
/// 成功后从 start 起播。files 为空不做任何事；单曲循环模式（2）先切回列表循环（1），
/// 否则播完第一首会一直重复，与"顺序播放整列"的心智相悖（web ensureSequentialMode 同口径）。
/// 供「我的最爱」双击等"从某行起播整个列表"的场景使用。
void RLPPlayWholeListFrom(NSArray<NSString *> *files, NSInteger start);

/// web ensureSequentialMode 的共享守卫：起播整列之前先读 /api/playmode，
/// 是单曲循环（mode==2）就切回列表循环（mode=1）；其余模式原样不动。
/// then 在主线程恰好回调一次（无需回调时传 nil）。最爱页/队列页/歌单页共用同一实现，
/// 避免各页面各写一套导致某页漏掉（P3：歌单页在单曲循环下整列播成一首）。
void RLPEnsureSequentialMode(void (^ _Nullable then)(void));
/// 带意图守卫的 ensureSequentialMode：每次异步回调前先问 shouldContinue()，
/// 为 NO 时立刻中止后续 /api/playmode?mode=1 与 then()，防止旧意图在被取代后抢跑。
void RLPEnsureSequentialModeWhile(BOOL (^ _Nullable shouldContinue)(void), void (^ _Nullable then)(void));

/// 「古典作品」判定与检索参数（web ui_script.h npIsClassical / npGuessComposer / npWorkTarget 的逐条移植）。
/// 为什么放在公共层：播放页第 4 张卡、作品抽屉、整页入口、右键菜单四处都要用同一套判定，
/// 各写一份必然漂移（web 也只有一个真源）。
BOOL RLPNPIsClassical(NSDictionary * _Nullable meta);
NSString *RLPNPGuessComposer(NSDictionary * _Nullable meta);
/// 返回 @{@"title": 去译名后的作品名, @"composer": 作曲家}；两者都可为空串。
NSDictionary<NSString *, NSString *> *RLPNPWorkTarget(NSDictionary * _Nullable meta);

/// v3.3.11 `parseTransportM3u` 的 macOS/POSIX 适配（上游是 Windows 反斜杠路径）。
/// 返回 @{@"items": NSArray<NSString*>, @"needsFolder": NSNumber(BOOL)}；
/// 非法歌单（HLS / 孤立 CUE / 空 / 控制字符）返回 nil。folder 传 nil 表示未知。
/// 纯函数：不读文件、不弹面板，供队列页与判据共用同一份解析。
NSDictionary<NSString *, id> * _Nullable RLPParseM3U(NSString *text, NSString * _Nullable folder);

NS_ASSUME_NONNULL_END
