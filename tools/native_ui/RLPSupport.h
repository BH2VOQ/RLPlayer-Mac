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
@end

/// 轻提示（非模态，1.8s 淡出）。用于"已加入队列""已收藏"这类反馈。
void RLPToast(NSString *message);

/// 模态提示（必须让用户看见的失败；例如更新失败）。主线程调用。
void RLPAlert(NSString *title, NSString *message);

/// 系统符号按钮（无边框、模板着色）。
NSButton *RLPSymbolButton(NSString *symbol, NSString *tooltip, id _Nullable target, SEL _Nullable action);
/// 单行标签（默认 13px；颜色/字体可后改）。
NSTextField *RLPLabel(NSString *text, NSFont *font, NSColor *color);

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
