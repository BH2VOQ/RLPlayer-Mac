// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 功能级验收：真的驱动导航与数据，并把每个页面离屏渲染成 PNG。
/// 与 --selftest 的区别：selftest 只问"能不能构造"，这里问"点进去有没有东西、长什么样"。
/// 返回失败项数（0 = 全过）。outDir 里会留下 PNG，供人眼复核。
int RLPRunFunctionalAudit(NSString *outDir);

NS_ASSUME_NONNULL_END
