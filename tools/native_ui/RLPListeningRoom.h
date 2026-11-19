// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RLPListeningRoom.h — 聆听室的纯决策层（可离线单测）
//
// 为什么抽出来：用户要求「听音风格」让不懂滤波的人也能挑一个听着舒服的，
// 而它本质是**一组预设滤波**。档位→滤波名的映射必须可单测，且**只能选后端真实存在的滤波**
// （/api/filters 是唯一真相源，不许硬编码第二份表、不许凭空造名字）。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 播放三档（人话）→ 官方预设 profile。
typedef NS_ENUM(NSInteger, RLPPlayMode3) {
    RLPPlayMode3Direct = 0,   // 原音直通
    RLPPlayMode3Pcm    = 1,   // PCM 升频
    RLPPlayMode3Dsd    = 2,   // DSD 升频（覆盖 PCM→DSD 与 DSD→DSD）
};

/// 三档 → profile。**DSD 档要看源类型**：源是 DSD ⟹ dsd（DSD→DSD）；源是 PCM ⟹ pcm2dsd。
/// 源未知（未播放）时按 pcm2dsd，并在 UI 说明"播放 DSD 文件时会自动改用 DSD→DSD"。
NSString *RLPProfileForPlayMode(RLPPlayMode3 mode, BOOL sourceIsDsd);

/// 从文件路径判断是否 DSD 源（.dsf/.dff/.dsd）。判不了返回 NO。
BOOL RLPPathIsDsd(NSString *_Nullable path);

/// 听音风格档位（人话，从锐利到温和）。往温和走就是 gauss 那一类。
typedef NS_ENUM(NSInteger, RLPToneStyle) {
    RLPToneStyleSharp   = 0,   // 清亮锐利
    RLPToneStyleBalanced= 1,   // 均衡自然
    RLPToneStyleWarm    = 2,   // 柔和温润
};
/// 档位的人话名字（已翻译）。
NSString *RLPToneStyleName(RLPToneStyle style);

/// 从 /api/filters 的 items 里为某档位挑一个**真实存在**的滤波名。
/// 规则：温和档优先 gauss 族；锐利档优先非 gauss 的 poly-sinc/tight 类；均衡档取中间。
/// 找不到合适项时回退到列表里第一个可用项（绝不返回不存在的名）。空列表返回 nil。
NSString *_Nullable RLPFilterForToneStyle(RLPToneStyle style, NSArray<NSDictionary *> *filterItems);

/// 反查：当前滤波名属于哪个档位（用于回显）。匹配不到返回 -1（UI 显示"自定义"）。
NSInteger RLPToneStyleForFilter(NSString *_Nullable filterName, NSArray<NSDictionary *> *filterItems);

/// 该滤波项是否该写 filterNx 键（forNx=true）而不是 filter。
BOOL RLPFilterUsesNxKey(NSString *_Nullable filterName, NSArray<NSDictionary *> *filterItems);

/// 切听音风格时构造同一次 POST /api/settings 的补丁：
/// 写入真实存在的 filter（或 filterNx），并清除会覆盖预设的旧手动覆盖键
/// （taps=0, mintapsperinput=0, atten=0, transition=0, phase=""；写 filter 时同时清 filterNx）。
/// 无可用滤波时返回 nil。
NSDictionary<NSString *, NSString *> *_Nullable RLPSettingsPatchForToneStyle(
    RLPToneStyle style, NSArray<NSDictionary *> *filterItems);

/// 从 /api/settings 的 kv 派生当前播放方式（与 Windows ui_listening_home.h 同口径）：
/// 返回 @"bitperfect" / @"pcm" / @"dsd" / @"pcm2dsd" / @"custom"。
NSString *RLPPlayModeFromSettings(NSDictionary *_Nullable kv);

/// 响应式快捷卡列数（与 Windows ui_listening_home.h @container 断点一致）：
/// <= 350 -> 1 列；<= 750 -> 2 列；> 750 -> 4 列。
NSInteger RLPQuickStartColumnsForWidth(double width);

/// 规范化 /api/cast/devices 的 devices 数组为 @{ @"id", @"name", @"kind", @"host" } 列表。
/// id 取 location > friendlyName > name > host（均为空则跳过）；与后端 rtaweb.cpp / Windows 一致。
NSArray<NSDictionary<NSString *, NSString *> *> *RLPNormalizeCastDevices(NSArray * _Nullable rawDevices);

/// 从 /api/settings 的 kv 记忆本地设备 id：
/// 仅当 backend 为本地后端（非 upnp 且非 null）时更新；处于 upnp/null 时保留 previousLocalDevice。
NSString *RLPRememberedLocalDevice(NSDictionary * _Nullable kv, NSString * _Nullable previousLocalDevice);

/// 构造输出切换的 POST /api/settings 补丁：
/// - targetBackend == @"upnp"：写入 backend=upnp 与 upnpdev；
/// - targetBackend == @"coreaudio" / @"coreaudio-shared"：写入 backend 并恢复 localDevice（不写 @"null"）；
/// - targetBackend == @"null"：写入 backend=null 与 device=null。
NSDictionary<NSString *, NSString *> *RLPOutputSettingsPatchForBackend(
    NSString *targetBackend, NSString * _Nullable upnpDev, NSString * _Nullable localDevice);

NS_ASSUME_NONNULL_END
