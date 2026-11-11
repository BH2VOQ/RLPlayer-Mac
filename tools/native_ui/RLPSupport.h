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

/// 轻提示（非模态，1.8s 淡出）。用于"已加入队列""已收藏"这类反馈。
void RLPToast(NSString *message);

/// 模态提示（必须让用户看见的失败；例如更新失败）。主线程调用。
void RLPAlert(NSString *title, NSString *message);

/// 系统符号按钮（无边框、模板着色）。
NSButton *RLPSymbolButton(NSString *symbol, NSString *tooltip, id _Nullable target, SEL _Nullable action);
/// 单行标签（默认 13px；颜色/字体可后改）。
NSTextField *RLPLabel(NSString *text, NSFont *font, NSColor *color);

/// ── 界面模式（1.1.7.1）─────────────────────────────────────────────
/// 聆听模式 = 只想安静听歌的人；专业模式 = 发烧友。
/// 差别体现在**能做什么**（侧栏项、页内能力），不是换皮。
/// 这是模式的唯一真相源：UI 各处只读它，不各自存一份 BOOL。
typedef NS_ENUM(NSInteger, RLPAppMode) {
    RLPAppModeListening = 0,   // 聆听模式（默认）
    RLPAppModePro       = 1,   // 专业模式
};
extern NSNotificationName const RLPAppModeDidChangeNotification;
/// 当前模式（持久化在 NSUserDefaults，属 UI 偏好，不是业务真相）。
RLPAppMode RLPCurrentAppMode(void);
/// 切换模式（同值不发通知）。会广播 RLPAppModeDidChangeNotification。
void RLPSetAppMode(RLPAppMode mode);
/// 模式的人话名字（已翻译）。
NSString *RLPAppModeName(RLPAppMode mode);

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
void RLPRequestOpenAlbum(NSString *albumKey);
void RLPRequestOpenArtist(NSString *artistName);
void RLPRequestBack(void);

/// 播放/入队动作（与 web 版同一 /api 契约，不复制播放逻辑）。
void RLPPlayPath(NSString *path);
void RLPPlayAlbum(NSString *albumKey, NSInteger startIndex);
void RLPEnqueuePath(NSString *path);
void RLPPostJSON(NSString *path, NSString * _Nullable body);

NS_ASSUME_NONNULL_END
