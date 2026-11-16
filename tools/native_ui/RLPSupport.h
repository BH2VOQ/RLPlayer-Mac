// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSupport.h — 原生 UI 的公共小工具（翻译/格式化/封面/提示/按钮/动作）
//
// 统一放在这里的目的：页面之间不各写一套格式化与封面缓存；i18n 只有一个入口
// （RLPTr），将来把 docs/i18n 的词表生成为原生表时，所有已包 RLPTr 的文案自动生效。
#import <AppKit/AppKit.h>

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
void RLPPlayPath(NSString *path);
/// CUE 分轨：cs/ce >= 0 时带区间（web playPath(file, cs, ce) 同契约），否则退化为整轨。
void RLPPlayPathCue(NSString *path, double cs, double ce);
void RLPPlayAlbum(NSString *albumKey, NSInteger startIndex);
void RLPEnqueuePath(NSString *path);
void RLPPostJSON(NSString *path, NSString * _Nullable body);

/// v3.3.11 `toggleVolumeMute` 的**唯一状态**（web `volumeRestore` 是全局单例）。
/// 播放页与底栏两个静音键必须共用同一份记忆值，否则「在播放页静音、到底栏取消静音」会恢复成错误值。
/// 返回应下发的 dB；返回 **NAN** 表示上游语义的「什么都不做」（当前已 -120 且无恢复值）。
double RLPVolumeMuteNextDb(double currentDb);
/// 当前是否有可恢复的记忆值（判据与 UI 可用；对应 web `volumeRestore !== null`）。
BOOL RLPVolumeMuteHasRestore(void);
/// 清空记忆值（上游在「重置/丢弃」路径上会置 null）。
void RLPVolumeMuteReset(void);
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
