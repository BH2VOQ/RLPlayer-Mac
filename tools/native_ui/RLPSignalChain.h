// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPSignalChain.h — 信号链详情（对齐 web showChain 的 /api/signal 渲染）
//
// web 版信号链弹窗（ui_script.h showChain）按真实播放路径 p=/api/signal.path
// 逐节点展示：源文件 / 解码 / 采样率转换 / EQ·卷积 / DSD·DoP / 抖动 / ISP / 响度 /
// 音量 / 输出 / 耗时统计，外加 bit-perfect 结论。
// 这里把"JSON → 节点数组"做成**纯函数**（不碰 AppKit、不碰网络），判据可直接钉住每一种分支；
// UI 层只负责把节点排版出来，不许自己再算一遍语义。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 节点种类（与 web .cnode 的 lossless/dsp/gpu/tel 着色一一对应）。
typedef NS_ENUM(NSInteger, RLPSignalNodeKind) {
    RLPSignalNodeLossless = 0,   // 逐位无损（绿）
    RLPSignalNodeDsp,            // 64-Bit DSP 处理（蓝）
    RLPSignalNodeGpu,            // GPU 参与计算（绿蓝）
    RLPSignalNodeTel,            // 实时遥测
};

@interface RLPSignalNode : NSObject
@property (nonatomic, copy) NSString *key;     // 节点名（源文件 / 解码 / …）
@property (nonatomic, copy) NSString *value;   // 节点值（真实数据拼出来的说明）
@property (nonatomic, copy) NSString *badge;   // 徽标（无损源 / GPU 升频 / …）
@property (nonatomic, assign) RLPSignalNodeKind kind;
@end

@interface RLPSignalChain : NSObject

/// /api/signal 的顶层响应 → bit-perfect 结论（hero 标题）。
/// 返回 @"yes"/@"no"/@"unknown" 对应的中文标题；why 回填 bitPerfectWhy。
+ (NSString *)heroTitleForResponse:(NSDictionary *)response why:(NSString * _Nullable * _Nullable)why;

/// 纯函数：/api/signal 的顶层响应 → 节点数组（顺序与 web showChain 一致）。
/// ok:false / 无 path 时返回 @[]（UI 显示"还没有开始播放"，不填假节点）。
+ (NSArray<RLPSignalNode *> *)nodesForResponse:(NSDictionary *)response;

/// 节点种类 → 颜色语义字符串（判据与 UI 共用，避免两处各写一套）。
+ (NSString *)kindName:(RLPSignalNodeKind)kind;

@end

NS_ASSUME_NONNULL_END