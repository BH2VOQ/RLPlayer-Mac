// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// ============================================================================
// bundle.h — 诊断包 v2（ROADMAP 1.1.1 · D4）：组装、预算裁剪、校验
// ============================================================================
//
// 这一层为什么是**纯逻辑**（无 ObjC、无网络、无 CoreAudio）：
//   诊断包里真正会出错的判断全是纯函数 —— 谁该被裁剪、裁剪后怎么证明、包被改过能不能看出来。
//   放在 rtaweb.cpp 里只能靠肉眼审查；抽到这里可以被 tests/test_diag_bundle.cpp 逐条断言。
//   抽样验收（打包解包、对照 sha256、故意改一个字节）也全都离线可跑。
//
// ---------------------------- v1 → v2 到底多了什么 ----------------------------
// v1（现行 /api/diagzip，tools/rtaweb.cpp）：STORE zip + diag.json + 3 份日志 +
//   README.txt。**没有任何自我描述**：不知道包里应该有什么、不知道字节有没有被改过、
//   不知道日志是不是被截过。于是「用户发来的包少了 events」和「events 本来就是空」
//   在收包端无法区分 —— 这正是 ROADMAP Q1~Q10 要求「资料不足要明确显示未知」的落点。
//
// v2 增加四件东西，每件都对应一个可判定的问题：
//   ① manifest.json —— 包里**声明**自己有什么：schema、case_id、每个条目的 bytes+sha256、
//      运行标记（clean_exit）、截断标记。没有它就只能靠猜（见 verify_issue 的 legacy 分支）。
//   ② checksums.txt —— sha256sum 兼容（`<hex>  <name>`），覆盖 manifest.json 本身 + 全部条目。
//      manifest 描述 payload，checksums 描述 manifest，形成一条可验证的链。
//   ③ case_id —— `RLP-YYYYMMDD-HHMMSS-XXXXXX`。同一份包里所有条目、报告、日志引用同一个
//      案例号，用户/开发者对账时不会再把两个包搞混（v1 里完全没有稳定标识）。
//   ④ truncated / dropped_head_bytes —— 包有 12 MB 上限，**裁剪必须显式**：
//      哪一条被裁、原有多大、丢了头部多少字节。收包端看到 events.jsonl 里少了开头，
//      必须能从 manifest 知道「这是裁剪，不是应用没写」。
//
// ---------------------------- 预算与裁剪策略（唯一口径）----------------------------
// 目标：整包 ≤ 12 MB（ROADMAP D6）。超额时**保留最近事件**，并明确标记。
//   1) pinned 条目（diag.json 这类几 KB 的刚性证据）整条保留，不参与裁剪；
//   2) 其余条目按 priority 从高到低依次分配剩余预算，每条取「尾部」（keep-tail，
//      因为诊断看的是最近发生了什么）；
//   3) 若某条只能分到 < 16 KiB，认为这条尾部已无信息量，**整条丢弃**并把预算让给
//      后面的条目，同时记进 truncation.dropped（不是悄悄消失）；
//   4) required 条目（diag/events/uievents/report）永不被整条丢弃，但允许被裁尾部；
//   5) 裁头之后对齐到行首（只对齐很近的下一行，避免超长行导致整窗报废），
//      于是 events.jsonl 里每一行仍然是完整 JSON —— 半行 JSON 会污染下游解析。
//   6) 256 KiB 预留给 manifest/checksums/report 自身开销，避免"条目没超、整包超了"。
//
// ---------------------------- 判据（怎么证明它对）----------------------------
//   * 结构自洽：tests 里 assemble → 目录 / zip → 反解 → 逐条目 sha256 复核；
//   * 篡改可发现：翻一个字节 → HashMismatch；删一个文件 → FileMissing；
//     改 manifest 里的 sha → HashMismatch；只有 v1 文件 → legacy/UnsupportedFormat；
//   * 裁剪可核对：小预算下断言「保留了最后 N 字节」「dropped_head_bytes == 原大小-保留大小」
//     「首行是完整 JSON」「整包 ≤ 预算」；
//   * 与 rtaweb 的 zip 互操作：复用 rta::zip（STORE），所以 v1 包也能被本文件读进来
//     （读得进 ≠ 能定论：v1 会走 legacy 分支，明确报"缺 manifest，无法核验"）。
//
// ---------------------------- 边界（不许越界）----------------------------
//   * **不做脱敏**：脱敏是 rtaweb 侧的硬红线（src/net/feedback_redact.h），本层只负责
//     装进包里的字节。传进来的内容按"已脱敏"对待，调用方负责（README.txt 里写明）。
//   * **不猜结论**：本层只回答"包完不完整、能不能信"，诊断结论在 report.h。
//   * **不读整目录**：条目白名单由调用方给出，本层绝不 fs 扫描整个用户目录去"顺手打包"。
//   * **不外链**：只依赖 net/{zipstore,json,update_check}.h（sha256 用 update_check.h 那一份，
//     全项目唯一，且已对 FIPS 官方向量测过）。
#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cctype>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <sstream>
#include <string>
#include <system_error>
#include <unistd.h>   // getpid（case_id 混合进 pid）
#include <utility>
#include <vector>

#include "net/json.h"
#include "net/update_check.h"   // rta::update::sha256_hex（全项目唯一实现）
#include "net/zipstore.h"

namespace rta::diag {

namespace fsys = std::filesystem;

// ================================ schema 常量 ================================
inline constexpr const char* kBundleSchema  = "rlplayer.diag.bundle/2";
inline constexpr int         kBundleVersion = 2;

inline constexpr const char* kManifestName  = "manifest.json";
inline constexpr const char* kChecksumsName = "checksums.txt";
inline constexpr const char* kReportName    = "report.txt";
inline constexpr const char* kDiagName      = "diag.json";
inline constexpr const char* kEventsName    = "events.jsonl";
inline constexpr const char* kUiEventsName  = "uievents.jsonl";

// 12 MB = ROADMAP D6 的整包目标；256 KiB 预留给 manifest/checksums/report；
// 16 KiB 是"尾部还值得留"的下限（再小就只能看到半条日志，不如把预算让给别的条目）。
inline constexpr std::size_t kDefaultBudgetBytes = 12u * 1024u * 1024u;
inline constexpr std::size_t kMetaReserveBytes   = 256u * 1024u;
inline constexpr std::size_t kMinUsefulTailBytes = 16u * 1024u;

// 条目类型只影响两件事：manifest 里的 kind 字符串，以及"裁剪后是否对齐到行首"。
enum class EntryKind { Json, Jsonl, Log, Text, Binary };

inline const char* entry_kind_name(EntryKind k) {
    switch (k) {
        case EntryKind::Json:   return "json";
        case EntryKind::Jsonl:  return "jsonl";
        case EntryKind::Log:    return "log";
        case EntryKind::Text:   return "text";
        case EntryKind::Binary: return "binary";
    }
    return "text";
}

inline EntryKind entry_kind_from_name(const std::string& s) {
    if (s == "json")  return EntryKind::Json;
    if (s == "jsonl") return EntryKind::Jsonl;
    if (s == "log")   return EntryKind::Log;
    if (s == "binary") return EntryKind::Binary;
    return EntryKind::Text;
}

// 行结构化（JSONL / 日志 / 文本）才有"对齐到行首"的意义；二进制不许动一个字节。
inline bool entry_kind_is_line_based(EntryKind k) {
    return k == EntryKind::Json || k == EntryKind::Jsonl || k == EntryKind::Log || k == EntryKind::Text;
}

// ================================ 小工具 ====================================
inline std::string json_escape(const std::string& s) {
    std::string o;
    o.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n";  break;
            case '\r': o += "\\r";  break;
            case '\t': o += "\\t";  break;
            case '\b': o += "\\b";  break;
            case '\f': o += "\\f";  break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", (unsigned)c);
                    o += buf;
                } else {
                    o.push_back((char)c);
                }
        }
    }
    return o;
}

inline std::string iso8601_utc(std::time_t t) {
    std::tm tm{};
    gmtime_r(&t, &tm);
    char buf[64];
    std::strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return std::string(buf);
}

inline std::string iso8601_local(std::time_t t) {
    std::tm tm{};
    localtime_r(&t, &tm);
    char buf[64];
    std::strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%S%z", &tm);
    std::string s(buf);
    // %z 给 "+0800"，ISO-8601 要 "+08:00"
    if (s.size() >= 5) {
        const char sign = s[s.size() - 5];
        if (sign == '+' || sign == '-') s.insert(s.size() - 2, ":");
    }
    return s;
}

inline uint64_t mix64(uint64_t x) {
    x += 0x9E3779B97F4A7C15ull;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
    return x ^ (x >> 31);
}

// 同进程内连续生成也不允许重复：nonce 单调递增，再与时间/pid 混合。
inline uint64_t next_case_nonce() {
    static std::atomic<uint64_t> n{0};
    return n.fetch_add(1, std::memory_order_relaxed) + 1;
}

// case_id: RLP-YYYYMMDD-HHMMSS-XXXXXX（6 位小写 hex）。
// 之所以要人类可读的前缀：用户口头报"昨天下午那个包"时，case_id 本身就带日期时间。
inline std::string make_case_id(std::time_t now, uint64_t salt = 0) {
    std::tm tm{};
    localtime_r(&now, &tm);
    char stamp[32];
    std::strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", &tm);

    // 不把递增 salt 与 nonce 异或：调用方若同时递增，两者会抵消成少量重复值。
    // 低 24 位使用单调 nonce；同秒内 2^24 次调用前不重复，时间/PID 只平移起点。
    (void)salt;
    uint64_t h = mix64((uint64_t)now ^ ((uint64_t)::getpid() << 32)) + next_case_nonce();
    static const char* hx = "0123456789abcdef";
    std::string tail;
    for (int i = 0; i < 6; ++i) {
        tail.push_back(hx[h & 0xF]);
        h >>= 4;
    }
    return std::string("RLP-") + stamp + "-" + tail;
}

// ================================ 规格 ======================================
struct BundleRun {
    long long   pid = 0;
    bool        clean_exit = true;      // false = 运行标记未清除（D6）
    bool        known = true;           // false = 没有上次运行标记；不能当作正常退出证据
    std::string exit_reason;            // 只在**有证据**时填："signal:9"/"timeout"/...，空 = 未知
    std::string run_id;                 // 每次启动一个 id，用于对齐 run 标记与日志
    std::string started_utc;
};

struct BundlePlatform {
    std::string os;      // "macOS 27.0.1"
    std::string arch;    // "arm64"
    std::string cpu;     // "Apple M4"
    std::string kernel;  // Darwin 版本，可空
};

struct BundleCase {
    std::string scenario;           // 夹具用："truncated_flac"/...（真实包留空）
    std::string origin;             // "rtaweb" / "fixture" / "manual"
    std::string blind_id;           // 盲测编号（可空）
    bool        simulated = false;  // true ⇒ 报告必须显著标注"不是真实诊断"
};

struct BundleSpec {
    std::string case_id;        // 空 ⇒ 自动生成
    std::string created_utc;    // 空 ⇒ 取当前时间
    std::string created_local;

    std::string generator_tool = "rtaweb";
    std::string generator_version;
    std::string generator_build;

    std::string app_version;
    std::string app_build;

    BundlePlatform platform;
    BundleRun      run;
    BundleCase     cs;

    std::size_t budget_bytes = kDefaultBudgetBytes;

    // v2 的必需条目。缺任何一个 ⇒ assemble 直接失败（不产出"看起来正常"的包）。
    std::vector<std::string> required = {kDiagName, kEventsName, kUiEventsName, kReportName};

    // 脱敏边界的一句话说明（由 rtaweb 侧生成，本层照抄进 manifest）。
    std::string redaction_note;
    std::vector<std::string> notes;
};

// 一个待打包条目。data 必须**已经**由调用方脱敏。
struct BundleEntry {
    std::string name;
    std::string data;
    EntryKind   kind = EntryKind::Text;
    int         priority = 50;      // 越大越先分配预算
    bool        pinned = false;     // 整条保留，不参与裁剪
    bool        keep_tail = true;   // 裁剪时保留尾部（诊断看最近发生了什么）
};

// 便捷构造：priority ≥ 100 视为 pinned（diag.json 这类几 KB 的刚性证据）。
inline BundleEntry make_entry(std::string name, std::string data, EntryKind kind, int priority) {
    BundleEntry e;
    e.name = std::move(name);
    e.data = std::move(data);
    e.kind = kind;
    e.priority = priority;
    e.pinned = (priority >= 100);
    e.keep_tail = entry_kind_is_line_based(kind);
    return e;
}

// ================================ 组装结果 ==================================
struct EntryRecord {
    std::string name;
    std::string sha256;
    EntryKind   kind = EntryKind::Text;
    int         priority = 0;
    std::size_t bytes = 0;
    std::size_t original_bytes = 0;
    std::size_t dropped_head_bytes = 0;
    bool        truncated = false;
    bool        newline_aligned = false;
    bool        pinned = false;
};

struct MaterializedEntry {
    EntryRecord rec;
    std::string data;   // 最终字节（裁剪后）
};

struct AssembleResult {
    bool        ok = false;
    std::string err;

    // 回填：spec.case_id 为空时由 assemble 生成，调用方从这里取（日志/邮件主题要与包内一致）。
    std::string case_id;
    std::string created_utc;

    std::vector<MaterializedEntry> entries;   // payload（含 report.txt）
    std::string manifest_json;
    std::string checksums_txt;
    std::string report_txt;

    bool        truncated = false;
    bool        over_budget = false;
    std::size_t entries_bytes = 0;
    std::size_t total_bytes = 0;
    std::size_t budget_bytes = 0;

    std::vector<std::string> dropped;      // 被整条丢弃的条目名
    std::vector<std::string> shrunk;       // 被裁掉头部的条目名
    std::size_t dropped_head_total = 0;
};

namespace detail {

// 条目名体检：ZIP 里放 `../` 或绝对路径 = 解包穿越（收包方一解就写到包外）。
// 硬拒，不给"以后再修"的余地。
inline bool entry_name_ok(const std::string& n, std::string& why) {
    if (n.empty()) { why = "名字为空"; return false; }
    if (n.size() > 200) { why = "名字过长（>200）"; return false; }
    if (n[0] == '/') { why = "不许绝对路径"; return false; }
    if (n.find('\\') != std::string::npos) { why = "不许含反斜杠（ZIP 内一律用 '/'）"; return false; }
    if (n.find("..") != std::string::npos) { why = "不许含 '..'（解包穿越）"; return false; }
    if (n.find(':') != std::string::npos) { why = "不许含 ':'"; return false; }
    for (unsigned char c : n) {
        if (c < 0x20 || c == 0x7F) { why = "不许含控制字符"; return false; }
    }
    return true;
}

// 裁头之后把偏移推到 UTF-8 字符边界上，避免半截多字节字符（JSON 解析器会报非法 UTF-8）。
inline std::size_t utf8_head_align(const std::string& s, std::size_t off) {
    while (off < s.size() && ((unsigned char)s[off] & 0xC0u) == 0x80u) ++off;
    return off;
}

// 期望值明确写全，避免"看起来对齐了其实丢了两行"。
inline constexpr std::size_t kMaxLineAlignSkip = 4096;

// 把裁头偏移对齐到下一行行首。只跳过很近的一个换行；若下一行行首在 4 KiB 之外
// （超长行 / 二进制伪装成文本），宁可保留半行也不整窗丢弃 —— 保守优先。
inline std::size_t line_head_align(const std::string& s, std::size_t off, bool enable) {
    if (!enable || off == 0 || off >= s.size()) return off;
    off = utf8_head_align(s, off);
    const std::size_t nl = s.find('\n', off);
    if (nl == std::string::npos) return off;
    if (nl + 1 - off > kMaxLineAlignSkip) return off;
    return nl + 1;
}

inline bool is_required(const BundleSpec& spec, const std::string& name) {
    for (const auto& r : spec.required) if (r == name) return true;
    return false;
}

inline std::string json_array(const std::vector<std::string>& v, bool escape = true) {
    std::string o = "[";
    for (std::size_t i = 0; i < v.size(); ++i) {
        if (i) o += ",";
        o += "\"";
        o += escape ? json_escape(v[i]) : v[i];
        o += "\"";
    }
    o += "]";
    return o;
}

}  // namespace detail

// ================================ manifest ==================================
inline std::string build_manifest(const BundleSpec& spec,
                                  const std::vector<MaterializedEntry>& ents,
                                  bool truncated,
                                  const AssembleResult& ar,
                                  std::size_t entries_bytes,
                                  bool over_budget) {
    std::ostringstream o;
    o << "{";
    o << "\"schema\":\"" << kBundleSchema << "\"";
    o << ",\"schema_version\":" << kBundleVersion;
    o << ",\"case_id\":\"" << json_escape(spec.case_id) << "\"";
    o << ",\"created_utc\":\"" << json_escape(spec.created_utc) << "\"";
    o << ",\"created_local\":\"" << json_escape(spec.created_local) << "\"";

    o << ",\"generator\":{\"tool\":\"" << json_escape(spec.generator_tool)
      << "\",\"version\":\"" << json_escape(spec.generator_version)
      << "\",\"build\":\"" << json_escape(spec.generator_build) << "\"}";

    o << ",\"app\":{\"version\":\"" << json_escape(spec.app_version)
      << "\",\"build\":\"" << json_escape(spec.app_build) << "\"}";

    o << ",\"platform\":{\"os\":\"" << json_escape(spec.platform.os)
      << "\",\"arch\":\"" << json_escape(spec.platform.arch)
      << "\",\"cpu\":\"" << json_escape(spec.platform.cpu)
      << "\",\"kernel\":\"" << json_escape(spec.platform.kernel) << "\"}";

    o << ",\"run\":{\"pid\":" << spec.run.pid
      << ",\"known\":" << (spec.run.known ? "true" : "false")
      << ",\"clean_exit\":" << (spec.run.known ? (spec.run.clean_exit ? "true" : "false") : "null")
      << ",\"exit_reason\":\"" << json_escape(spec.run.exit_reason) << "\""
      << ",\"run_id\":\"" << json_escape(spec.run.run_id) << "\""
      << ",\"started_utc\":\"" << json_escape(spec.run.started_utc) << "\"}";

    o << ",\"case\":{\"scenario\":\"" << json_escape(spec.cs.scenario)
      << "\",\"origin\":\"" << json_escape(spec.cs.origin)
      << "\",\"blind_id\":\"" << json_escape(spec.cs.blind_id)
      << "\",\"simulated\":" << (spec.cs.simulated ? "true" : "false") << "}";

    o << ",\"budget\":{\"target_bytes\":" << (long long)spec.budget_bytes
      << ",\"reserved_meta_bytes\":" << (long long)kMetaReserveBytes
      << ",\"entries_bytes\":" << (long long)entries_bytes
      << ",\"over_budget\":" << (over_budget ? "true" : "false") << "}";

    o << ",\"truncation\":{\"applied\":" << (truncated ? "true" : "false")
      << ",\"policy\":\"keep-newest-by-priority\""
      << ",\"min_tail_bytes\":" << (long long)kMinUsefulTailBytes
      << ",\"dropped\":" << detail::json_array(ar.dropped)
      << ",\"shrunk\":" << detail::json_array(ar.shrunk)
      << ",\"dropped_head_bytes\":" << (long long)ar.dropped_head_total
      << ",\"note\":\"" << json_escape(truncated
             ? "整包超预算：高优先级条目先分配，按 keep-tail 保留最近内容，裁头已对齐到行首；"
               "dropped 里的条目是被整条丢弃（不足最小尾部），不是没产生"
             : "未裁剪：全部条目完整进包")
      << "\"}";

    if (!spec.redaction_note.empty())
        o << ",\"redaction\":{\"applied\":true,\"note\":\"" << json_escape(spec.redaction_note) << "\"}";

    o << ",\"required\":" << detail::json_array(spec.required, false);

    o << ",\"entries\":[";
    for (std::size_t i = 0; i < ents.size(); ++i) {
        const EntryRecord& r = ents[i].rec;
        if (i) o << ",";
        o << "{\"name\":\"" << json_escape(r.name) << "\""
          << ",\"bytes\":" << (long long)r.bytes
          << ",\"sha256\":\"" << json_escape(r.sha256) << "\""
          << ",\"kind\":\"" << entry_kind_name(r.kind) << "\""
          << ",\"priority\":" << r.priority
          << ",\"truncated\":" << (r.truncated ? "true" : "false")
          << ",\"original_bytes\":" << (long long)r.original_bytes
          << ",\"dropped_head_bytes\":" << (long long)r.dropped_head_bytes
          << ",\"newline_aligned\":" << (r.newline_aligned ? "true" : "false")
          << ",\"pinned\":" << (r.pinned ? "true" : "false")
          << "}";
    }
    o << "]";

    if (!spec.notes.empty()) o << ",\"notes\":" << detail::json_array(spec.notes);

    o << "}";
    return o.str();
}

inline std::string build_checksums(const std::string& manifest,
                                   const std::vector<MaterializedEntry>& ents) {
    std::ostringstream o;
    // sha256sum 兼容格式（两个空格）；`sha256sum -c` 可直接核。
    o << rta::update::sha256_hex(manifest) << "  " << kManifestName << "\n";
    for (const auto& e : ents) o << e.rec.sha256 << "  " << e.rec.name << "\n";
    return o.str();
}

// ================================ 组装 ======================================
namespace detail {

struct Allocation {
    std::vector<std::size_t> keep;      // 每个条目实际保留的字节数（0 = 丢弃）
    bool truncated = false;
    bool over_budget_hint = false;
};

inline Allocation allocate(const BundleSpec& spec, const std::vector<BundleEntry>& items) {
    Allocation a;
    a.keep.assign(items.size(), 0);

    const std::size_t budget = spec.budget_bytes ? spec.budget_bytes : kDefaultBudgetBytes;
    std::size_t avail = budget > kMetaReserveBytes ? budget - kMetaReserveBytes : budget;

    // 分配顺序：priority 降序；同优先级按名字升序（"log" 在 "log.1" 之前 —— 新的先拿），
    // 再按输入下标升序兜底，保证完全确定（同一输入永远得到同一结果，便于对账）。
    std::vector<std::size_t> order(items.size());
    for (std::size_t i = 0; i < items.size(); ++i) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](std::size_t x, std::size_t y) {
        if (items[x].priority != items[y].priority) return items[x].priority > items[y].priority;
        if (items[x].name != items[y].name) return items[x].name < items[y].name;
        return x < y;
    });

    for (std::size_t idx : order) {
        const BundleEntry& e = items[idx];
        const std::size_t need = e.data.size();

        if (e.pinned) {
            // 刚性证据整条保留；它吃掉预算（但预算再紧也不裁它 —— 裁了就没有定论依据了）。
            a.keep[idx] = need;
            if (need <= avail) avail -= need; else { avail = 0; a.over_budget_hint = true; }
            continue;
        }
        if (need <= avail) {
            a.keep[idx] = need;
            avail -= need;
            continue;
        }
        // 需要裁剪（或整条丢弃）
        const bool req = is_required(spec, e.name);
        if (avail >= kMinUsefulTailBytes) {
            a.keep[idx] = avail;
            avail = 0;
            a.truncated = true;
        } else if (req && avail > 0) {
            // required 但预算只剩一点点：留下这一点，不整条丢（否则等于"包不合格"）
            a.keep[idx] = avail;
            avail = 0;
            a.truncated = true;
        } else if (req) {
            a.keep[idx] = std::min(kMinUsefulTailBytes, need);
            avail = 0;
            a.truncated = true;
            a.over_budget_hint = true;
        } else {
            a.keep[idx] = 0;   // 整条丢弃，不消耗预算
            a.truncated = true;
        }
    }
    return a;
}

}  // namespace detail

// 核心实现。report_fn 会拿到**裁剪之后**的条目，于是报告里的"已裁剪"与事实一致。
inline AssembleResult assemble_impl(
        const BundleSpec& spec_in,
        std::vector<BundleEntry> items,
        const std::function<std::string(const std::vector<MaterializedEntry>&)>& report_fn,
        const std::string& fixed_report) {
    AssembleResult r;
    r.budget_bytes = spec_in.budget_bytes ? spec_in.budget_bytes : kDefaultBudgetBytes;

    BundleSpec spec = spec_in;   // 补默认值只改副本，调用方的对象保持原样

    // ---- 1. 条目名体检 + 去重 ----
    for (auto& e : items) {
        std::string why;
        if (!detail::entry_name_ok(e.name, why)) {
            r.err = "条目名非法「" + e.name + "」：" + why;
            return r;
        }
    }
    for (std::size_t i = 0; i < items.size(); ++i)
        for (std::size_t j = i + 1; j < items.size(); ++j)
            if (items[i].name == items[j].name) {
                r.err = "条目名重复：「" + items[i].name + "」";
                return r;
            }

    // ---- 2. 时间/case_id 默认值 ----
    const std::time_t now = std::time(nullptr);
    if (spec.created_utc.empty())   spec.created_utc = iso8601_utc(now);
    if (spec.created_local.empty()) spec.created_local = iso8601_local(now);
    if (spec.case_id.empty())       spec.case_id = make_case_id(now);
    r.case_id = spec.case_id;
    r.created_utc = spec.created_utc;

    // ---- 3. 预算分配 ----
    const detail::Allocation alloc = detail::allocate(spec, items);

    // ---- 4. 物化 ----
    for (std::size_t i = 0; i < items.size(); ++i) {
        const BundleEntry& src = items[i];
        const std::size_t keep = alloc.keep[i];
        if (keep == 0 && !src.data.empty()) {
            r.dropped.push_back(src.name);
            continue;   // 整条不进包
        }
        MaterializedEntry m;
        m.rec.name = src.name;
        m.rec.kind = src.kind;
        m.rec.priority = src.priority;
        m.rec.pinned = src.pinned;
        m.rec.original_bytes = src.data.size();

        if (keep >= src.data.size()) {
            m.data = src.data;
        } else {
            const std::size_t raw_off = src.data.size() - keep;
            const std::size_t off = detail::line_head_align(
                    src.data, raw_off, src.keep_tail && entry_kind_is_line_based(src.kind));
            m.data = src.data.substr(off);
            m.rec.dropped_head_bytes = off;
            m.rec.newline_aligned = (off != raw_off);
            r.shrunk.push_back(src.name);
            r.dropped_head_total += off;
        }
        m.rec.bytes = m.data.size();
        m.rec.truncated = (m.rec.dropped_head_bytes > 0);
        m.rec.sha256 = rta::update::sha256_hex(m.data);
        r.entries_bytes += m.data.size();
        r.entries.push_back(std::move(m));
    }

    // ---- 5. report.txt ----
    // 三种来源，优先级：调用方已放进 items 的 report.txt > 回调生成 > 固定字符串。
    bool have_report = false;
    for (const auto& e : r.entries) if (e.rec.name == kReportName) have_report = true;
    if (!have_report) {
        std::string text = fixed_report;
        if (text.empty() && report_fn) text = report_fn(r.entries);
        if (!text.empty()) {
            MaterializedEntry m;
            m.rec.name = kReportName;
            m.rec.kind = EntryKind::Text;
            m.rec.priority = 90;
            m.rec.pinned = true;            // 报告不允许被裁：它就是给人看的结论
            m.data = text;
            m.rec.bytes = text.size();
            m.rec.original_bytes = text.size();
            m.rec.sha256 = rta::update::sha256_hex(text);
            r.entries_bytes += text.size();
            r.entries.push_back(std::move(m));
            r.report_txt = text;
            have_report = true;
        }
    } else {
        for (const auto& e : r.entries) if (e.rec.name == kReportName) r.report_txt = e.data;
    }

    // ---- 6. 必需条目齐不齐（缺一个就失败，不产出"看起来正常"的包）----
    for (const auto& req : spec.required) {
        bool found = false;
        for (const auto& e : r.entries) if (e.rec.name == req) found = true;
        if (!found) {
            r.err = "缺少必需条目「" + req + "」（v2 schema 要求 diag.json / events.jsonl / "
                    "uievents.jsonl / report.txt 齐全；缺了就说明打包调用点漏了）";
            return r;
        }
    }

    // ---- 7. manifest + checksums（两趟：第二趟把 over_budget 写实）----
    r.truncated = alloc.truncated;
    bool over = alloc.over_budget_hint;
    for (int pass = 0; pass < 2; ++pass) {
        r.manifest_json = build_manifest(spec, r.entries, r.truncated, r, r.entries_bytes, over);
        r.checksums_txt = build_checksums(r.manifest_json, r.entries);
        r.total_bytes = r.entries_bytes + r.manifest_json.size() + r.checksums_txt.size();
        const bool now_over = (r.total_bytes > r.budget_bytes);
        if (now_over == over) break;
        over = now_over;
    }
    r.over_budget = over;
    r.ok = true;
    return r;
}

inline AssembleResult assemble(const BundleSpec& spec,
                               std::vector<BundleEntry> items,
                               const std::string& report_text = std::string()) {
    return assemble_impl(spec, std::move(items), nullptr, report_text);
}

inline AssembleResult assemble_with_report(
        const BundleSpec& spec,
        std::vector<BundleEntry> items,
        const std::function<std::string(const std::vector<MaterializedEntry>&)>& report_fn) {
    return assemble_impl(spec, std::move(items), report_fn, std::string());
}

// ================================ 落盘 ======================================
inline std::string zip_of(const AssembleResult& r) {
    std::vector<rta::zip::Entry> z;
    {
        rta::zip::Entry e;
        e.name = kManifestName;
        e.data = r.manifest_json;
        z.push_back(std::move(e));
    }
    for (const auto& m : r.entries) {
        rta::zip::Entry e;
        e.name = m.rec.name;
        e.data = m.data;
        z.push_back(std::move(e));
    }
    {
        rta::zip::Entry e;
        e.name = kChecksumsName;
        e.data = r.checksums_txt;
        z.push_back(std::move(e));
    }
    return rta::zip::build(z);
}

inline bool write_bundle_dir(const std::string& dir, const AssembleResult& r, std::string& err) {
    std::error_code ec;
    fsys::create_directories(fsys::path(dir), ec);
    if (ec) { err = "无法创建目录：" + ec.message(); return false; }
    auto put = [&](const std::string& name, const std::string& data) -> bool {
        const fsys::path p = fsys::path(dir) / name;
        std::ofstream f(p, std::ios::binary | std::ios::trunc);
        if (!f) { err = "无法写入 " + name; return false; }
        f.write(data.data(), (std::streamsize)data.size());
        if (!f) { err = "写入不完整 " + name; return false; }
        return true;
    };
    if (!put(kManifestName, r.manifest_json)) return false;
    for (const auto& m : r.entries) if (!put(m.rec.name, m.data)) return false;
    if (!put(kChecksumsName, r.checksums_txt)) return false;
    return true;
}

inline bool write_bundle_zip(const std::string& path, const AssembleResult& r, std::string& err) {
    const fsys::path p(path);
    if (p.has_parent_path()) {
        std::error_code ec;
        fsys::create_directories(p.parent_path(), ec);
    }
    std::ofstream f(p, std::ios::binary | std::ios::trunc);
    if (!f) { err = "无法写入 " + path; return false; }
    const std::string z = zip_of(r);
    f.write(z.data(), (std::streamsize)z.size());
    if (!f) { err = "写入不完整 " + path; return false; }
    return true;
}

// ================================ 读取 / 校验 ===============================
struct ManifestEntry {
    std::string name;
    std::string sha256;
    std::string kind;
    long long   bytes = 0;
    long long   original_bytes = 0;
    long long   dropped_head_bytes = 0;
    int         priority = 0;
    bool        truncated = false;
    bool        newline_aligned = false;
    bool        pinned = false;
};

struct BundleMeta {
    bool        present = false;         // manifest.json 存在且解析成功
    std::string schema;
    int         schema_version = 0;
    std::string case_id;
    std::string created_utc;
    std::string created_local;

    std::string generator_tool;
    std::string generator_version;
    std::string generator_build;

    std::string app_version;
    std::string app_build;

    BundlePlatform platform;
    BundleRun      run;
    BundleCase     cs;

    long long   target_bytes = 0;
    long long   entries_bytes = 0;
    bool        over_budget = false;

    bool        truncated = false;
    std::string truncation_policy;
    std::vector<std::string> dropped;
    std::vector<std::string> shrunk;
    long long   dropped_head_bytes = 0;
    std::string truncation_note;

    std::string redaction_note;
    std::vector<std::string> required;
    std::vector<std::string> notes;
    std::vector<ManifestEntry> entries;
};

enum class IssueKind {
    NotAZip,            // 不是可解析的 STORE zip
    CorruptEntry,       // zip 内某条目 CRC 不符（字节被改过）
    DirectoryMissing,   // 路径不存在 / 不是目录
    EmptyBundle,        // 一个文件都没有
    ManifestMissing,    // 缺 manifest.json
    ManifestBadJson,    // manifest.json 不是合法对象
    SchemaUnsupported,  // schema 不是 v2（含旧 v1 包）
    ChecksumsMissing,   // 缺 checksums.txt
    ChecksumsBadLine,   // checksums.txt 行格式非法
    ChecksumsMismatch,  // checksums.txt 里的值与实际文件不符
    RequiredMissing,    // manifest 未声明必需条目
    FileMissing,        // manifest 声明了但文件不在
    SizeMismatch,
    HashMismatch,
    ExtraFile,          // 包里有、manifest 没声明（warn）
    PathUnsafe,         // 条目名带穿越/绝对路径
};

enum class IssueSeverity { Fail, Warn };

struct VerifyIssue {
    IssueKind       kind = IssueKind::ManifestMissing;
    IssueSeverity   sev = IssueSeverity::Fail;
    std::string     name;
    std::string     detail;

    std::string line() const {
        std::string k;
        switch (kind) {
            case IssueKind::NotAZip:           k = "not_a_zip"; break;
            case IssueKind::CorruptEntry:      k = "corrupt_entry"; break;
            case IssueKind::DirectoryMissing:  k = "directory_missing"; break;
            case IssueKind::EmptyBundle:       k = "empty_bundle"; break;
            case IssueKind::ManifestMissing:   k = "manifest_missing"; break;
            case IssueKind::ManifestBadJson:   k = "manifest_bad_json"; break;
            case IssueKind::SchemaUnsupported: k = "schema_unsupported"; break;
            case IssueKind::ChecksumsMissing:  k = "checksums_missing"; break;
            case IssueKind::ChecksumsBadLine:  k = "checksums_bad_line"; break;
            case IssueKind::ChecksumsMismatch: k = "checksums_mismatch"; break;
            case IssueKind::RequiredMissing:   k = "required_missing"; break;
            case IssueKind::FileMissing:       k = "file_missing"; break;
            case IssueKind::SizeMismatch:      k = "size_mismatch"; break;
            case IssueKind::HashMismatch:      k = "hash_mismatch"; break;
            case IssueKind::ExtraFile:         k = "extra_file"; break;
            case IssueKind::PathUnsafe:        k = "path_unsafe"; break;
        }
        std::string o = std::string(sev == IssueSeverity::Fail ? "[FAIL] " : "[warn] ") + k;
        if (!name.empty()) o += " " + name;
        if (!detail.empty()) o += "：" + detail;
        return o;
    }
};

struct VerifyResult {
    bool        ok = false;          // 没有 Fail 级问题
    bool        legacy = false;      // 旧 v1 包（有 rlplayer-diag.json 但没有 manifest.json）
    bool        is_zip = false;
    std::string source;              // 路径或标签
    std::size_t files = 0;
    std::size_t verified = 0;        // sha256 复核通过的条目数
    std::vector<VerifyIssue> issues;

    bool has_fail() const {
        for (const auto& i : issues) if (i.sev == IssueSeverity::Fail) return true;
        return false;
    }
    std::size_t fail_count() const {
        std::size_t n = 0;
        for (const auto& i : issues) if (i.sev == IssueSeverity::Fail) ++n;
        return n;
    }
    std::string summary() const {
        if (ok) {
            std::string s = "通过：payload " + std::to_string(verified) + " 条的 sha256 与 checksums.txt "
                            "一致，共 " + std::to_string(files) + " 个文件";
            for (const auto& i : issues) if (i.sev == IssueSeverity::Warn) { s += "，有警告"; break; }
            return s;
        }
        if (legacy) return "不通过：旧 v1 诊断包（无 manifest.json / checksums.txt，无法核验完整性）";
        return "不通过（" + std::to_string(fail_count()) + " 项失败）";
    }
    std::vector<std::string> issue_lines() const {
        std::vector<std::string> v;
        v.reserve(issues.size());
        for (const auto& i : issues) v.push_back(i.line());
        return v;
    }
};

struct Bundle {
    VerifyResult verify;
    BundleMeta   meta;
    std::vector<std::pair<std::string, std::string>> files;   // 包内顺序（目录：按名字排序）

    const std::string* find(const std::string& name) const {
        for (const auto& f : files) if (f.first == name) return &f.second;
        return nullptr;
    }
    bool has(const std::string& name) const { return find(name) != nullptr; }
    std::string text(const std::string& name) const {
        const std::string* p = find(name);
        return p ? *p : std::string();
    }
    std::size_t total_bytes() const {
        std::size_t n = 0;
        for (const auto& f : files) n += f.second.size();
        return n;
    }
};

namespace detail {

inline const std::vector<std::string>& default_required() {
    static const std::vector<std::string> k = {kDiagName, kEventsName, kUiEventsName, kReportName};
    return k;
}

inline bool parse_manifest(const std::string& text, BundleMeta& m, std::string& err) {
    const rta::net::Json j = rta::net::json_parse(text);
    if (j.type != rta::net::Json::Obj) { err = "manifest.json 不是 JSON 对象"; return false; }

    m.present = true;
    m.schema         = j["schema"].s();
    m.schema_version = (int)j["schema_version"].n();
    m.case_id        = j["case_id"].s();
    m.created_utc    = j["created_utc"].s();
    m.created_local  = j["created_local"].s();

    m.generator_tool    = j["generator"]["tool"].s();
    m.generator_version = j["generator"]["version"].s();
    m.generator_build   = j["generator"]["build"].s();

    m.app_version = j["app"]["version"].s();
    m.app_build   = j["app"]["build"].s();

    m.platform.os     = j["platform"]["os"].s();
    m.platform.arch   = j["platform"]["arch"].s();
    m.platform.cpu    = j["platform"]["cpu"].s();
    m.platform.kernel = j["platform"]["kernel"].s();

    m.run.pid         = (long long)j["run"]["pid"].n();
    m.run.known = j["run"]["clean_exit"].type == rta::net::Json::Bool;
    if (m.run.known) m.run.clean_exit = j["run"]["clean_exit"].b;
    m.run.exit_reason = j["run"]["exit_reason"].s();
    m.run.run_id      = j["run"]["run_id"].s();
    m.run.started_utc = j["run"]["started_utc"].s();

    m.cs.scenario  = j["case"]["scenario"].s();
    m.cs.origin    = j["case"]["origin"].s();
    m.cs.blind_id  = j["case"]["blind_id"].s();
    m.cs.simulated = j["case"]["simulated"].b;

    m.target_bytes  = (long long)j["budget"]["target_bytes"].n();
    m.entries_bytes = (long long)j["budget"]["entries_bytes"].n();
    m.over_budget   = j["budget"]["over_budget"].b;

    m.truncated          = j["truncation"]["applied"].b;
    m.truncation_policy  = j["truncation"]["policy"].s();
    m.dropped_head_bytes = (long long)j["truncation"]["dropped_head_bytes"].n();
    m.truncation_note    = j["truncation"]["note"].s();
    for (std::size_t i = 0; i < j["truncation"]["dropped"].size(); ++i)
        m.dropped.push_back(j["truncation"]["dropped"].at(i).s());
    for (std::size_t i = 0; i < j["truncation"]["shrunk"].size(); ++i)
        m.shrunk.push_back(j["truncation"]["shrunk"].at(i).s());

    m.redaction_note = j["redaction"]["note"].s();

    for (std::size_t i = 0; i < j["required"].size(); ++i) m.required.push_back(j["required"].at(i).s());
    for (std::size_t i = 0; i < j["notes"].size(); ++i) m.notes.push_back(j["notes"].at(i).s());

    const rta::net::Json& es = j["entries"];
    if (es.type != rta::net::Json::Arr) { err = "manifest.json 缺少 entries 数组"; return false; }
    for (std::size_t i = 0; i < es.size(); ++i) {
        const rta::net::Json& e = es.at(i);
        ManifestEntry me;
        me.name  = e["name"].s();
        me.sha256 = e["sha256"].s();
        me.kind  = e["kind"].s();
        me.bytes = (long long)e["bytes"].n();
        me.original_bytes = (long long)e["original_bytes"].n();
        me.dropped_head_bytes = (long long)e["dropped_head_bytes"].n();
        me.priority = (int)e["priority"].n();
        me.truncated = e["truncated"].b;
        me.newline_aligned = e["newline_aligned"].b;
        me.pinned = e["pinned"].b;
        if (me.name.empty()) { err = "manifest.json entries 里有空名字"; return false; }
        if (me.sha256.size() != 64) { err = "manifest.json entries「" + me.name + "」的 sha256 不是 64 位"; return false; }
        m.entries.push_back(std::move(me));
    }
    return true;
}

}  // namespace detail

// 解析 checksums.txt 的一行：`<64 hex>  <name>` 或 `<64 hex> *<name>`。
inline bool parse_checksum_line(const std::string& line, std::string& hex, std::string& name) {
    if (line.size() < 67) return false;
    for (int i = 0; i < 64; ++i) {
        const char c = line[(std::size_t)i];
        const bool ishex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!ishex) return false;
    }
    hex = line.substr(0, 64);
    for (auto& c : hex) c = (char)std::tolower((unsigned char)c);
    std::size_t p = 64;
    if (line[p] != ' ' && line[p] != '\t') return false;
    while (p < line.size() && (line[p] == ' ' || line[p] == '\t')) ++p;
    if (p < line.size() && line[p] == '*') ++p;       // sha256sum -b 的二进制标记
    if (p >= line.size()) return false;
    name = line.substr(p);
    while (!name.empty() && (name.back() == '\r' || name.back() == '\n')) name.pop_back();
    return !name.empty();
}

namespace detail {

inline void add_issue(VerifyResult& v, IssueKind k, IssueSeverity s, const std::string& name,
                      const std::string& detail) {
    // 同一 (kind,name) 只报一次：required 检查与 entries 检查会看到同一个缺失文件。
    for (const auto& i : v.issues)
        if (i.kind == k && i.name == name) return;
    VerifyIssue i;
    i.kind = k;
    i.sev = s;
    i.name = name;
    i.detail = detail;
    v.issues.push_back(std::move(i));
}

inline bool verify_bundle(Bundle& b) {
    b.verify.files = b.files.size();
    if (b.files.empty()) {
        add_issue(b.verify, IssueKind::EmptyBundle, IssueSeverity::Fail, "", "包里一个文件都没有");
        b.verify.ok = false;
        return false;
    }
    // 条目名安全：穿越/绝对路径直接 FAIL（解包即写包外）
    for (const auto& f : b.files) {
        std::string why;
        if (!entry_name_ok(f.first, why))
            add_issue(b.verify, IssueKind::PathUnsafe, IssueSeverity::Fail, f.first, why);
    }

    // ---- ① manifest ----
    const std::string* mf = b.find(kManifestName);
    if (!mf) {
        const bool v1_like = b.has("rlplayer-diag.json");
        b.verify.legacy = v1_like;
        add_issue(b.verify, IssueKind::ManifestMissing, IssueSeverity::Fail, kManifestName,
                  v1_like ? "旧 v1 诊断包只有 rlplayer-diag.json，没有 v2 的 manifest.json"
                          : "没有 manifest.json（v2 要求包自我描述：case_id / sha256 / 截断标记）");
        b.verify.ok = false;
        return false;
    }
    std::string perr;
    if (!parse_manifest(*mf, b.meta, perr)) {
        add_issue(b.verify, IssueKind::ManifestBadJson, IssueSeverity::Fail, kManifestName, perr);
        b.verify.ok = false;
        return false;
    }
    if (b.meta.schema != kBundleSchema) {
        add_issue(b.verify, IssueKind::SchemaUnsupported, IssueSeverity::Fail, kManifestName,
                  "schema=\"" + b.meta.schema + "\"，本工具只认 \"" + kBundleSchema + "\"");
        b.verify.ok = false;
        return false;
    }
    if (b.meta.case_id.empty())
        add_issue(b.verify, IssueKind::ManifestBadJson, IssueSeverity::Fail, "case_id", "case_id 为空（v2 要求稳定案例号）");

    // ---- ② checksums.txt（覆盖 manifest 自身 + 全部 payload）----
    const std::string* cs = b.find(kChecksumsName);
    if (!cs) {
        add_issue(b.verify, IssueKind::ChecksumsMissing, IssueSeverity::Fail, kChecksumsName,
                  "缺 checksums.txt：无法证明包内字节未被改动");
    } else {
        std::istringstream in(*cs);
        std::string line;
        std::vector<std::pair<std::string, std::string>> listed;   // hex, name
        while (std::getline(in, line)) {
            while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
            if (line.empty() || line[0] == '#') continue;
            std::string hex, name;
            if (!parse_checksum_line(line, hex, name)) {
                add_issue(b.verify, IssueKind::ChecksumsBadLine, IssueSeverity::Fail, kChecksumsName,
                          "无法解析的行：" + line.substr(0, 80));
                continue;
            }
            listed.emplace_back(hex, name);
        }
        bool saw_manifest = false;
        for (const auto& pr : listed) {
            const std::string* d = b.find(pr.second);
            if (!d) {
                add_issue(b.verify, IssueKind::FileMissing, IssueSeverity::Fail, pr.second,
                          "checksums.txt 列出了，但包里没有这个文件");
                continue;
            }
            if (rta::update::sha256_hex(*d) != pr.first) {
                add_issue(b.verify, IssueKind::ChecksumsMismatch, IssueSeverity::Fail, pr.second,
                          "checksums.txt 的 sha256 与实际字节不符");
            } else if (pr.second == kManifestName) {
                saw_manifest = true;
            }
        }
        if (!saw_manifest)
            add_issue(b.verify, IssueKind::ChecksumsMissing, IssueSeverity::Fail, kManifestName,
                      "checksums.txt 没有覆盖 manifest.json 本身（这条链断了就无法自证）");
        // 包里存在但 checksums 未列出的（checksums.txt 自己当然不算）
        for (const auto& f : b.files) {
            if (f.first == kChecksumsName) continue;
            bool found = false;
            for (const auto& pr : listed) if (pr.second == f.first) { found = true; break; }
            if (!found)
                add_issue(b.verify, IssueKind::ExtraFile, IssueSeverity::Warn, f.first,
                          "未被 checksums.txt 覆盖");
        }
    }

    // ---- ③ required ----
    const std::vector<std::string>& reqs = b.meta.required.empty() ? default_required() : b.meta.required;
    for (const auto& req : reqs) {
        bool declared = false;
        for (const auto& me : b.meta.entries) if (me.name == req) declared = true;
        if (!declared)
            add_issue(b.verify, IssueKind::RequiredMissing, IssueSeverity::Fail, req,
                      "manifest 的 entries 未声明这个必需条目");
        if (!b.has(req))
            add_issue(b.verify, IssueKind::FileMissing, IssueSeverity::Fail, req,
                      "必需条目不在包内");
    }

    // ---- ④ 每条目：大小 + sha256 ----
    for (const auto& me : b.meta.entries) {
        const std::string* d = b.find(me.name);
        if (!d) {
            add_issue(b.verify, IssueKind::FileMissing, IssueSeverity::Fail, me.name,
                      "manifest 声明了但包内没有");
            continue;
        }
        if ((long long)d->size() != me.bytes) {
            add_issue(b.verify, IssueKind::SizeMismatch, IssueSeverity::Fail, me.name,
                      "manifest bytes=" + std::to_string(me.bytes) + "，实际=" +
                      std::to_string((long long)d->size()));
            continue;
        }
        const std::string got = rta::update::sha256_hex(*d);
        if (got != me.sha256) {
            add_issue(b.verify, IssueKind::HashMismatch, IssueSeverity::Fail, me.name,
                      "manifest sha256 与实际字节不符（包被改过）");
            continue;
        }
        ++b.verify.verified;
    }

    // ---- ⑤ manifest 未声明的多余文件（warn：不影响结论，但要说出来）----
    for (const auto& f : b.files) {
        if (f.first == kManifestName || f.first == kChecksumsName) continue;
        bool declared = false;
        for (const auto& me : b.meta.entries) if (me.name == f.first) { declared = true; break; }
        if (!declared)
            add_issue(b.verify, IssueKind::ExtraFile, IssueSeverity::Warn, f.first,
                      "包内有这个文件，但 manifest 未声明");
    }

    b.verify.ok = !b.verify.has_fail();
    return b.verify.ok;
}

inline bool read_file_bytes(const std::string& path, std::string& out, std::string& err) {
    std::ifstream f(fsys::path(path), std::ios::binary);
    if (!f) { err = "无法打开文件"; return false; }
    f.seekg(0, std::ios::end);
    const std::streamoff sz = f.tellg();
    if (sz < 0) { err = "无法读取大小"; return false; }
    f.seekg(0, std::ios::beg);
    out.resize((std::size_t)sz);
    if (sz > 0) {
        f.read(&out[0], sz);
        if (!f) { err = "读取失败"; return false; }
        out.resize((std::size_t)f.gcount());
    }
    return true;
}

}  // namespace detail

inline bool load_from_dir(const std::string& dir, Bundle& out) {
    out = Bundle{};
    out.verify.source = dir;
    out.verify.is_zip = false;
    std::error_code ec;
    if (!fsys::is_directory(fsys::path(dir), ec)) {
        detail::add_issue(out.verify, IssueKind::DirectoryMissing, IssueSeverity::Fail, dir,
                          "路径不存在或不是目录");
        return false;
    }
    // 平铺目录（v2 就是这样）；子目录不参与 —— 免得把用户的整个音乐目录带进来。
    for (const auto& de : fsys::directory_iterator(fsys::path(dir),
                                                   fsys::directory_options::skip_permission_denied, ec)) {
        if (ec) break;
        std::error_code fec;
        if (!de.is_regular_file(fec)) continue;
        std::string data, err;
        if (!detail::read_file_bytes(de.path().string(), data, err)) {
            detail::add_issue(out.verify, IssueKind::FileMissing, IssueSeverity::Fail,
                              de.path().filename().string(), "读取失败：" + err);
            continue;
        }
        out.files.emplace_back(de.path().filename().string(), std::move(data));
    }
    std::sort(out.files.begin(), out.files.end(),
              [](const auto& a, const auto& b) { return a.first < b.first; });
    return detail::verify_bundle(out);
}

inline bool load_from_zip_bytes(const std::string& zip, const std::string& label, Bundle& out) {
    out = Bundle{};
    out.verify.source = label;
    out.verify.is_zip = true;
    std::vector<rta::zip::Parsed> ps;
    std::string err;
    if (!rta::zip::parse(zip, ps, err)) {
        // zip::parse 会对每个条目校验 CRC32：数据被改过 ⇒ "CRC 不符: name"。
        // 这是**包级损坏**，与"manifest 里的 sha 对不上"分开报，定位更快。
        const bool crc = err.find("CRC") != std::string::npos;
        detail::add_issue(out.verify,
                          crc ? IssueKind::CorruptEntry : IssueKind::NotAZip,
                          IssueSeverity::Fail, "", err);
        return false;
    }
    if (ps.empty()) {
        detail::add_issue(out.verify, IssueKind::EmptyBundle, IssueSeverity::Fail, "", "zip 里没有条目");
        return false;
    }
    out.files.reserve(ps.size());
    for (auto& p : ps) out.files.emplace_back(std::move(p.name), std::move(p.data));
    return detail::verify_bundle(out);
}

// 一个入口：目录或 zip 都行。返回"是否通过校验"（读得到但校验没过 = false，且 issues 有话说）。
inline bool load_bundle(const std::string& path, Bundle& out) {
    out = Bundle{};
    std::error_code ec;
    if (fsys::is_directory(fsys::path(path), ec)) return load_from_dir(path, out);
    if (fsys::is_regular_file(fsys::path(path), ec)) {
        std::string bytes, err;
        if (!detail::read_file_bytes(path, bytes, err)) {
            out = Bundle{};
            out.verify.source = path;
            detail::add_issue(out.verify, IssueKind::FileMissing, IssueSeverity::Fail, path,
                              "读取失败：" + err);
            return false;
        }
        if (bytes.size() >= 4 && (unsigned char)bytes[0] == 0x50 && (unsigned char)bytes[1] == 0x4B &&
            (unsigned char)bytes[2] == 0x03 && (unsigned char)bytes[3] == 0x04)
            return load_from_zip_bytes(bytes, path, out);
        out = Bundle{};
        out.verify.source = path;
        detail::add_issue(out.verify, IssueKind::NotAZip, IssueSeverity::Fail, path,
                          "既不是目录也不是 ZIP（应以 PK\\3\\4 开头）。若是其它工具压的 DEFLATE zip，"
                          "先解压成本目录再喂给 rtadiag");
        return false;
    }
    out = Bundle{};
    out.verify.source = path;
    detail::add_issue(out.verify, IssueKind::DirectoryMissing, IssueSeverity::Fail, path,
                      "路径不存在");
    return false;
}

}  // namespace rta::diag
