// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// update_channel.h — F-4 自动更新「更新通道（中国大陆 / 全球）」纯逻辑层
//                    （无 IO、无 ObjC、零项目依赖、可离线单测）
//
// ============================ 这一层为什么单独存在 ============================
// 1.1.5.1 新增「更新通道」选项。本轮**只做框架**（后台 dmg 尚未适配，用户明确要求
// 先做框架、等后台适配好再正式接入）：
//    · 全球(Global)           = 现有 GitHub 路径（latest.json + release dmg），行为一字不变；
//    · 中国大陆(ChinaMainland) = rlplayer.rainlain.com 后台（签名清单 + files[] 对象）。
// 本层**不发起任何网络请求**、不验签、不解包、不重组整包、不碰断点续传。
// 把「通道选择 / 解析 / 清单来源 / 清单形状」抽成纯函数，是为了：
//    ① 缺省即安全可被单测证明（非法值绝不静默选到未知通道）；
//    ② 等后台就绪后只需在 tools/mac_update.mm 的 check_china_channel() 里填实，
//       配置与 UI 契约都不用再动；
//    ③ 「验签必须在解包 / 安装之前」这条顺序约束用类型(ChannelManifest)钉住，
//       不靠口头约定（同 tools/mac_update.h 里「verify 必须在 mount 之前」的做法）。
//
// ============================ 安全边界 ============================
//   * 本层不含任何 token / URL 凭据 / 公钥 DER；常量只有两个公开主机名与清单路径。
//   * 页面只发「用户选了哪个通道」的抽象枚举命令（update:channel:global|cn），
//     绝不把 URL / token 下发给宿主（见 tools/mac_host.mm:788 的硬边界注释）。
//   * 中国大陆通道在框架阶段**永远不可判定为「已是最新」**：后台未就绪时返回
//     FailedNetwork 等价的诚实失败态，绝不冒充成功、绝不引导百度网盘。
#pragma once

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

namespace rta::update {

// ---------------------------------------------------------------------------
// 0. 通道枚举与默认值（唯一真相源）
// ---------------------------------------------------------------------------
enum class UpdateChannel {
    Global,         // 全球：现有 GitHub 路径（清单 + release dmg），行为一字不变
    ChinaMainland   // 中国大陆：rlplayer.rainlain.com 后台（本轮只做框架）
};

// ⚠️ 框架阶段默认**仍为全球**：后台 dmg 未适配，默认切大陆会立刻不可用，
//    也会改变现有用户升级后的行为。后台适配完成后，把这一行改成
//    `kDefaultChannel = UpdateChannel::ChinaMainland` 即可（用户 2026-11-09 定的
//    最终产品语义：中国大陆默认走后台）。默认值只在这里定义一次，
//    parse_channel / Config / 模板 / UI 全部从它派生，别在别处再写一遍。
inline constexpr UpdateChannel kDefaultChannel = UpdateChannel::Global;

// ---------------------------------------------------------------------------
// 1. 后台通道常量（本轮只用于「解析出来源」，不发起请求）
// ---------------------------------------------------------------------------
inline constexpr const char kChinaHost[] = "rlplayer.rainlain.com";

inline constexpr const char kChinaManifestUrl[] =
    "https://rlplayer.rainlain.com/api/v1/update/macos/latest";

// 配置键取值。global / cn 为主，china 作为容错别名（大小写不敏感）。
inline constexpr const char kChannelValueGlobal[] = "global";
inline constexpr const char kChannelValueCn[] = "cn";
inline constexpr const char kChannelValueChina[] = "china";

// ---------------------------------------------------------------------------
// 2. 通道解析 —— 缺省即安全
//
// 语义：
//   * 空 / 纯空白        → 「未配置」，回退 kDefaultChannel，valid=true，无 warning
//                          （首次运行没有 channel= 是常态，不报错）
//   * global/cn/china    → 对应通道（大小写不敏感），valid=true
//   * 其它非空值         → 回退 kDefaultChannel，valid=false，warning 说明原因
//                          （绝不静默选一个未知通道；warning 不含任何凭据）
// ---------------------------------------------------------------------------
struct ChannelParseResult {
    UpdateChannel channel = kDefaultChannel;
    bool valid = true;          // false = 输入非法且已安全回退
    std::string warning;        // 非法时的提示（不含任何凭据）
};

namespace detail_channel {
inline std::string ch_trim(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && std::isspace((unsigned char)s[b])) ++b;
    while (e > b && std::isspace((unsigned char)s[e - 1])) --e;
    return s.substr(b, e - b);
}
inline std::string ch_lower(const std::string& s) {
    std::string o = s;
    std::transform(o.begin(), o.end(), o.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    return o;
}
} // namespace detail_channel

inline ChannelParseResult parse_channel(const std::string& raw) {
    ChannelParseResult r;
    const std::string v = detail_channel::ch_lower(detail_channel::ch_trim(raw));
    if (v.empty()) return r;                       // 未配置 → 默认，无警告
    if (v == kChannelValueGlobal) { r.channel = UpdateChannel::Global; return r; }
    if (v == kChannelValueCn || v == kChannelValueChina) {
        r.channel = UpdateChannel::ChinaMainland;
        return r;
    }
    r.valid = false;
    r.channel = kDefaultChannel;                  // 安全回退，绝不落到未知通道
    r.warning = "update.conf: channel 取值非法，已安全回退到默认通道";
    return r;
}

// 枚举 → 配置键（写回 update.conf / 生成模板用）。
inline const char* channel_config_value(UpdateChannel ch) {
    return ch == UpdateChannel::ChinaMainland ? kChannelValueCn : kChannelValueGlobal;
}

// 枚举 → 稳定 code（UI 命令 / 回显用，与配置键同形但语义独立）。
inline const char* channel_code(UpdateChannel ch) { return channel_config_value(ch); }

// ---------------------------------------------------------------------------
// 3. 通道 → 清单来源（**本轮只返回常量/结构，不发起请求**）
//
// global 的清单地址沿用现有 kDefaultManifestUrl（在 update_check.h），由调用方传入
// globalManifestUrl —— 避免在两个头里各写一遍同一字面量（唯一真相源在 update_check.h）。
// cn 返回后台签名清单地址常量。
// ---------------------------------------------------------------------------
inline std::string channel_manifest_url(UpdateChannel ch,
                                        const std::string& globalManifestUrl) {
    return ch == UpdateChannel::ChinaMainland
        ? std::string(kChinaManifestUrl)
        : globalManifestUrl;
}

// ---------------------------------------------------------------------------
// 4. 后台签名清单形状（框架阶段只定义形状，不解析 / 不验签 / 不解包）
//
// 与现有 Manifest（单 dmg + download_url）形状**不同**：后台清单是
//   PS256 签名清单 + files[]（每个文件一个确定性 ZIP 对象，服务端不托管整包 dmg 直链）。
// 本结构把「后台清单 → 与现有 Manifest 等价的 version/sha256/size/notes + 对象列表」
// 表达出来；等后台就绪后填实的顺序**用字段和 ready() 钉死**：
//
//   固定顺序（顺序本身就是安全边界，不许重排；同 install_from_local_dmg）：
//     ① 取签名清单           GET /api/v1/update/macos/latest
//     ② 验签(PS256)         ← 必须先于 ③④；signatureVerified=true 才能继续
//     ③ 按 files[] 取对象   GET /api/v1/update/macos/objects/<sha256>.zip
//     ④ deflate 解包 + 整包重组（全量更新，不做本地 sha 差异）→ 得到完整 .dmg；
//                          objectsAssembled=true 才能继续
//     ⑤ verify(sha256+size) = 现有 verify_downloaded_file（**必须在 mount 之前**）
//     ⑥ mount_image → install_app_bundle → unmount_image（现有 install_from_local_dmg）
//
// 本轮 ①②③④ 都未实现：signatureVerified / objectsAssembled 默认 false，
// ready()==false ⟹ 任何调用方都不得进入 ⑤⑥，也不得判「已是最新 / 可安装」。
// 这样「切到大陆后既有链路的调用形状与失败语义保持一致」由类型保证，而非注释约定。
// ---------------------------------------------------------------------------
struct ChannelObject {
    std::string sha256;     // 对象标识 = /objects/<sha256>.zip
    long long   size = 0;
    std::string path;       // 解包后在整包内的相对路径
};

struct ChannelManifest {
    // —— 与现有 Manifest 等价的判定字段（版本比较 / 校验全复用 update_check.h 的纯函数）——
    std::string version;
    std::string sha256;     // 重组后整包 dmg 的 sha256（最终校验用）
    long long   size = 0;
    std::string notes;

    // —— 后台特有 ——
    std::string signature;                   // PS256 签名（本轮不验）
    std::string kid;                         // 验签公钥 id（本轮不用）
    std::vector<ChannelObject> objects;      // files[] 等价：对象列表

    // 顺序闸门：只有后台接入并真实完成后才允许置 true。
    bool signatureVerified = false;          // ② 验签完成
    bool objectsAssembled  = false;          // ④ 解包 + 整包重组完成

    // 「整包已就绪、可以进入既有 verify→mount→replace 链路」的唯一判据。
    // 框架阶段永远返回 false（未验签 / 未重组 / 摘要为空）。
    bool ready() const {
        return signatureVerified && objectsAssembled &&
               !version.empty() && !sha256.empty() && size > 0;
    }
};

// ---------------------------------------------------------------------------
// 5. 框架阶段：中国大陆通道不可用的诚实提示
//
// 绝不冒充「已是最新」，绝不引导百度网盘（用户 2026-11-09 定的语义）。
// 这条文案是 cn 分支 check() 唯一的对外结论，等后台就绪后由真实结果取代。
// ---------------------------------------------------------------------------
inline constexpr const char kChinaChannelUnavailableMessage[] =
    "中国大陆更新通道后台准备中，暂不可用，请稍后重试，或切换为全球通道";

} // namespace rta::update
