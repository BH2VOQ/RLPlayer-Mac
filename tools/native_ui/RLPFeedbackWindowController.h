// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 反馈窗口：写正文 + 可选附诊断包 → 上传到 rlplayer.rainlain.com。
/// 协议实现全部复用 src/net/feedback_api.h（纯逻辑、有离线单测），UI 不重写协议。
@interface RLPFeedbackWindowController : NSWindowController
+ (instancetype)shared;
- (void)showAndFocus;
@end

NS_ASSUME_NONNULL_END
