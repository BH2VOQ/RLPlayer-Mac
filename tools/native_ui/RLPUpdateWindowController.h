// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 更新窗口：一个窗口 + 两个内容视图（信息态 / 下载态）+ 五个出口。
///
/// 结构借鉴 QQ 音乐 11.11.0 的 Update.nib（一窗两视图五按钮），但**只用机制**：
///   * 不用它的资源、不照抄文案、不引入提权（它用 privilegedRemove）；
///   * 下载/校验/安装全部复用 tools/mac_update.mm 的既有实现；
///   * 忽略与稍后都落盘：同一版本不再反复打扰（RLPUpdateDecision）。
@interface RLPUpdateWindowController : NSWindowController

+ (instancetype)shared;

/// 手动检查（用户点「检查更新」）或启动自动检查（延迟调用）。
- (void)checkManually:(BOOL)manually;

/// 当前版本是否被用户忽略（供启动检查判断；NULL version 返回 NO）。
+ (BOOL)isVersionIgnored:(NSString *)version;

@end

NS_ASSUME_NONNULL_END
