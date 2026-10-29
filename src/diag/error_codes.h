// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// error_codes.h — 1.1.1 D1：稳定错误码表（界面 / 日志 / 诊断包共用同一套码）
//
// ===========================================================================
// 契约（改动这里的规则，不是"风格问题"）
//
//   1) id 与 code 字符串**一经发布就冻结**。改名 = 破坏历史诊断包的可比对性，
//      只能新增条目（新 id 从各阶段分段的空位或段尾继续取）。
//   2) code 的第一段**必须**等于 stage 名（`decode.*` ↔ Stage::Decode），
//      这样界面可以只按前缀分组，不必认识每一条码。tests 逐条断言这一点。
//   3) 新增/删除/改名后必须把 kErrorCodeTableVersion +1，并同步
//      tests/test_diag_event.cpp 的 G 段（否则测试会红 —— 故意的）。
//   4) 码表只表达「失败在哪个阶段、属于哪一类」，不表达具体变量值；
//      具体上下文写进事件的 kv，不塞进 code。
//
// id 分段（每段 10 个，留位给后续补码）：
//    1-9 init | 10-19 decode | 20-29 negotiate | 30-39 dsp | 40-49 io
//    50-59 meta | 60-69 llm | 70-79 upnp | 80-89 library | 90-99 update
//    100-109 room | 110-119 ui | 120-129 diag
// ===========================================================================
#pragma once

#include <cstddef>
#include <string>
#include <string_view>

namespace rta::diag {

// 码表版本：任何增删改都必须 +1（见文件头契约 3）
inline constexpr int kErrorCodeTableVersion = 2;

// 阶段（对应 1.1.1 诊断目标 Q3 的 8 类 + 生命周期/诊断自身）
// 顺序即 stage 名表顺序，别随意重排 —— 有测试按整数往返。
enum class Stage : int {
    Unknown = 0,
    Init,
    Decode,
    Negotiate,
    Dsp,
    Io,
    Meta,
    Llm,
    Upnp,
    Library,
    Update,
    Room,
    Ui,
    Diag,
};
inline constexpr int kStageCount = 14;

inline const char* stage_name(Stage s) {
    switch (s) {
        case Stage::Init: return "init";
        case Stage::Decode: return "decode";
        case Stage::Negotiate: return "negotiate";
        case Stage::Dsp: return "dsp";
        case Stage::Io: return "io";
        case Stage::Meta: return "meta";
        case Stage::Llm: return "llm";
        case Stage::Upnp: return "upnp";
        case Stage::Library: return "library";
        case Stage::Update: return "update";
        case Stage::Room: return "room";
        case Stage::Ui: return "ui";
        case Stage::Diag: return "diag";
        case Stage::Unknown: break;
    }
    return "unknown";
}

// 名 → 枚举。未知名返回 Stage::Unknown 且 ok=false（不猜成 Init）
inline Stage stage_from_name(std::string_view n, bool* ok = nullptr) {
    for (int i = 0; i < kStageCount; ++i) {
        const auto s = static_cast<Stage>(i);
        if (n == stage_name(s)) {
            if (ok) *ok = true;
            return s;
        }
    }
    if (ok) *ok = false;
    return Stage::Unknown;
}

// 一条稳定错误码。zh 是给用户看的短说明（界面与诊断包共用，别写成开发注释）。
struct ErrorCode {
    int id;
    const char* code;   // 稳定字符串，第一段 == stage 名
    Stage stage;
    const char* zh;
};

// ★ 冻结表：只许在段内追加，不许改名/复用 id（文件头契约 1）
inline constexpr ErrorCode kErrorCodes[] = {
    // ---- init 1-9 ----
    {1, "init.config_invalid", Stage::Init, "配置无法解析，已使用默认值"},
    {2, "init.storage_unwritable", Stage::Init, "诊断目录不可写"},
    {3, "init.already_running", Stage::Init, "已有实例在运行"},
    // ---- decode 10-19 ----
    {10, "decode.truncated_flac", Stage::Decode, "FLAC 数据被截断或校验失败"},
    {11, "decode.unsupported_format", Stage::Decode, "解码器不支持该格式"},
    {12, "decode.bad_header", Stage::Decode, "文件头损坏，无法确定格式"},
    {13, "decode.read_failed", Stage::Decode, "读取素材失败"},
    {14, "decode.dsd_unsupported", Stage::Decode, "该 DSD 变体或封装不受支持"},
    {15, "decode.frame_count_short", Stage::Decode, "实际解码帧数少于头部声明"},
    // ---- negotiate 20-29 ----
    {20, "negotiate.rate_unsupported", Stage::Negotiate, "设备不支持该采样率"},
    {21, "negotiate.channels_unsupported", Stage::Negotiate, "设备不支持该声道数"},
    {22, "negotiate.bit_depth_unsupported", Stage::Negotiate, "设备不支持该位深"},
    {23, "negotiate.device_not_found", Stage::Negotiate, "找不到目标输出设备"},
    {24, "negotiate.format_rejected", Stage::Negotiate, "设备拒绝了请求的格式"},
    // ---- dsp 30-39 ----
    {30, "dsp.ir_load_failed", Stage::Dsp, "IR 文件加载或重采样失败"},
    {31, "dsp.eq_parse_failed", Stage::Dsp, "EQ/PEQ 设置无法解析"},
    {32, "dsp.non_finite_output", Stage::Dsp, "DSP 输出出现 NaN/Inf"},
    {33, "dsp.clipped_overload", Stage::Dsp, "DSP 链路过载或长时间削波"},
    // ---- io 40-49 ----
    {40, "io.open_failed", Stage::Io, "打开输出端点失败"},
    {41, "io.write_failed", Stage::Io, "写入输出设备失败"},
    {42, "io.underrun", Stage::Io, "输出欠载（缓冲供给不足）"},
    {43, "io.device_lost", Stage::Io, "输出设备已断开"},
    {44, "io.stalled", Stage::Io, "写入停滞（长时间无进展）"},
    {45, "io.hog_denied", Stage::Io, "独占模式申请被拒绝"},
    // ---- meta 50-59 ----
    {50, "meta.timeout", Stage::Meta, "元数据请求超时"},
    {51, "meta.network_failed", Stage::Meta, "元数据网络请求失败"},
    {52, "meta.parse_failed", Stage::Meta, "元数据响应无法解析"},
    {53, "meta.not_found", Stage::Meta, "未找到可用的元数据"},
    // ---- llm 60-69 ----
    {60, "llm.not_configured", Stage::Llm, "未配置 LLM 服务"},
    {61, "llm.auth_failed", Stage::Llm, "LLM 鉴权失败"},
    {62, "llm.rate_limited", Stage::Llm, "LLM 触发限流"},
    {63, "llm.invalid_response", Stage::Llm, "LLM 响应格式不可用"},
    {64, "llm.timeout", Stage::Llm, "LLM 请求超时"},
    {65, "llm.network_failed", Stage::Llm, "LLM 网络传输失败，尚未取得 HTTP 响应"},
    {66, "llm.http_failed", Stage::Llm, "LLM 服务返回非成功 HTTP 状态"},
    // ---- upnp 70-79 ----
    {70, "upnp.no_renderer", Stage::Upnp, "未发现可用的投放设备"},
    {71, "upnp.control_failed", Stage::Upnp, "投放控制请求失败"},
    {72, "upnp.discovery_failed", Stage::Upnp, "设备发现失败"},
    // ---- library 80-89 ----
    {80, "library.scan_failed", Stage::Library, "曲库扫描失败"},
    {81, "library.path_missing", Stage::Library, "曲库目录不存在或不可读"},
    {82, "library.db_corrupt", Stage::Library, "曲库索引损坏"},
    // ---- update 90-99 ----
    {90, "update.check_failed", Stage::Update, "检查更新失败"},
    {91, "update.download_failed", Stage::Update, "更新包下载失败"},
    {92, "update.verify_failed", Stage::Update, "更新包校验失败"},
    // ---- room 100-109 ----
    {100, "room.no_input_device", Stage::Room, "没有可用的测量输入设备"},
    {101, "room.capture_failed", Stage::Room, "测量采集失败"},
    {102, "room.cancelled", Stage::Room, "测量被取消"},
    {103, "room.calibration_failed", Stage::Room, "校准或反卷积失败"},
    // ---- ui 110-119 ----
    {110, "ui.request_failed", Stage::Ui, "界面请求失败"},
    {111, "ui.internal_error", Stage::Ui, "界面内部错误"},
    {112, "ui.script_error", Stage::Ui, "页面脚本异常"},
    // ---- diag 120-129 ----
    {120, "diag.package_incomplete", Stage::Diag, "诊断包缺少应有条目"},
    {121, "diag.insufficient_evidence", Stage::Diag, "现有证据不足以得出结论"},
    {122, "diag.event_log_unwritable", Stage::Diag, "事件日志不可写"},
};

inline constexpr std::size_t kErrorCodeCount =
    sizeof(kErrorCodes) / sizeof(kErrorCodes[0]);

// 按 code 字符串查（未知返回 nullptr —— 调用方必须能处理"不认识的码"，
// 例如读旧版本诊断包时；不猜、不兜底成某个默认码）
inline const ErrorCode* find_code(std::string_view code) {
    for (std::size_t i = 0; i < kErrorCodeCount; ++i)
        if (code == kErrorCodes[i].code) return &kErrorCodes[i];
    return nullptr;
}

inline const ErrorCode* find_code_by_id(int id) {
    for (std::size_t i = 0; i < kErrorCodeCount; ++i)
        if (kErrorCodes[i].id == id) return &kErrorCodes[i];
    return nullptr;
}

// 中文说明；未知码返回空串（界面应显示"未知错误（码：xxx）"，不要编造原因）
inline std::string_view zh_of(std::string_view code) {
    const ErrorCode* c = find_code(code);
    return c ? std::string_view(c->zh) : std::string_view();
}

}  // namespace rta::diag
