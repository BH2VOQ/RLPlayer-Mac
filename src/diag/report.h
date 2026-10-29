// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// ============================================================================
// report.h — 离线结论引擎（ROADMAP 1.1.1 · D5）：基于包内证据给**唯一明确结论**
// ============================================================================
//
// 这个文件存在的唯一理由：把"看着日志猜原因"换成"按证据判定，猜不出来就说不知道"。
//
// ---------------------------- 三条硬规矩 ----------------------------
//   ① **只认证据**。每条结论都必须指到具体条目 + 行号 + 字段（citation）。没有 citation
//      的结论不允许输出；包里没有的东西不许"根据经验推断"。
//   ② **结论唯一或明说没结论**。verdict 只有三种：
//        known      唯一结论（其它候选按"证据具体性"排序且不并列）
//        ambiguous  多条同等优先级的规则同时命中 ⇒ 并列，拒绝挑一个
//        unknown    证据不足 / 校验未通过 ⇒ 列出缺什么
//   ③ **不把模拟当真实诊断**。case.simulated=true 的包（夹具/回放数据）一律显著标注
//      "不是真实运行证据"，JSON 里 as_real=false；rtadiag --require-real 直接拒绝（退出 1）。
//      这条路是给盲测准备的：夹具的"答案"绝不能从包里读出来。
//
// ---------------------------- 场景 → 信号（与后端代理的约定）----------------------------
// 判定用的是**证据事实**，不是错误码表的文案 —— 码表改了不会让结论漂移。信号词表：
//   截断 FLAC         code/evt 含 TRUNC      | kv truncated=true | kv frames_declared > frames_read
//   采样率不支持       code/evt 含 RATE       | kv rate_supported=false | kv requested_rate ∉ kv device_rates
//   欠载/写入停滞      kv underrun>0 / dry>0 / starve>0 / write_stall_ms>0 | evt 含 UNDERRUN/STARVING
//   元数据超时         stage=meta 且 code/evt 含 TIMEOUT | kv timed_out=true 且 stage=meta
//   LLM 配置错         stage=llm 且 kv http_status∈{401,403,404} | kv config_invalid=true
//                     | evt/code 含 LLM_AUTH/LLM_CONF/NO_KEY/MODEL_NOT_FOUND
//   无投放设备         stage∈{upnp,cast} 且 kv devices=0 | (sent>0 且 replies=0)
//                     | evt/code 含 NO_DEVICE/NO_RENDERER
//   非正常退出         manifest.run.clean_exit=false 且 没有 crash/kill 证据
//   房间测量取消       stage=room 且 kv cancelled=true | evt/code 含 CANCEL
// 兼容：事件可用 `evt` 或 `event`；kv 可以嵌在 `kv` 对象里，也可以平铺在事件顶层。
// 证据不足时要报"缺什么"，所以每条规则都声明它希望看到、但可以缺席的子证据（soft）。
//
// ---------------------------- 错误码表（不建第二张）----------------------------
// 结论**不依赖**码表。码表只用于 Q4 的"人话说明"。与基础 event 代理约定的接口是
//     namespace rta::diag { struct ErrorCodeInfo {std::string_view code, stage, name_zh, hint_zh;};
//                            const ErrorCodeInfo* find_error_code(std::string_view);
//                            std::span<const ErrorCodeInfo> error_codes(); }
// 这里用可注入的 CodeLookup 承接，未注入时 Q4 显示"说明缺失（未链接错误码表）"，绝不猜文案。
#pragma once

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "diag/bundle.h"

namespace rta::diag {

// ================================ 错误码表桥 ================================
struct CodeInfo {
    std::string code;
    std::string stage;
    std::string name_zh;
    std::string hint_zh;
};

// 返回 false = 码表里没有这个码（不是错误，只是"说明缺失"）。
using CodeLookup = std::function<bool(const std::string& code, CodeInfo& out)>;

// ================================ 事件解析 ==================================
struct DiagEvent {
    long long   seq = 0;
    std::string ts;
    std::string sid;
    std::string rid;
    std::string evt;
    std::string stage;
    std::string code;
    std::map<std::string, std::string> kv;
    std::size_t line = 0;     // 1-based 行号（引用用）
};

struct EventStream {
    std::vector<DiagEvent> ev;
    std::size_t lines = 0;
    std::size_t bad_lines = 0;
    bool        head_partial = false;   // 首行不完整（裁剪裁在行中间）
    bool        tail_partial = false;   // 末行不完整（写入被切断 / 裁剪）
    bool        empty_file = true;

    bool usable() const { return !ev.empty(); }
};

namespace detail_rep {

inline std::string num_to_text(double v) {
    char buf[40];
    if (v == (double)(long long)v && std::fabs(v) < 1e15) {
        std::snprintf(buf, sizeof buf, "%lld", (long long)v);
    } else {
        std::snprintf(buf, sizeof buf, "%.6g", v);
    }
    return std::string(buf);
}

inline std::string scalar_text(const rta::net::Json& j) {
    switch (j.type) {
        case rta::net::Json::Str:  return j.str;
        case rta::net::Json::Num:  return num_to_text(j.num);
        case rta::net::Json::Bool: return j.b ? "true" : "false";
        case rta::net::Json::Null: return "";
        default: return std::string();
    }
}

}  // namespace detail_rep

inline EventStream parse_events_jsonl(const std::string& text) {
    EventStream st;
    st.empty_file = text.empty();
    if (text.empty()) return st;

    std::size_t pos = 0;
    std::size_t line_no = 0;
    bool any = false;
    while (pos < text.size()) {
        std::size_t nl = text.find('\n', pos);
        const bool last_line = (nl == std::string::npos);
        const std::string raw = text.substr(pos, (last_line ? text.size() : nl) - pos);
        pos = last_line ? text.size() : nl + 1;

        ++line_no;
        std::string line = raw;
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t'))
            line.pop_back();
        if (line.empty()) continue;          // 空行不算坏行（日志拼接常见）
        ++st.lines;

        const rta::net::Json j = rta::net::json_parse(line);
        const bool is_obj = (j.type == rta::net::Json::Obj);
        if (!is_obj) {
            ++st.bad_lines;
            if (!any) st.head_partial = true;
            if (last_line) st.tail_partial = true;
            continue;
        }
        DiagEvent e;
        e.line = line_no;
        e.seq  = (long long)j["seq"].n();
        e.ts   = j["ts"].s();
        e.sid  = j["sid"].s();
        e.rid  = j["rid"].s();
        e.evt  = j["evt"].s();               // 别名：event
        if (e.evt.empty()) e.evt = j["event"].s();
        e.stage = j["stage"].s();
        e.code  = j["code"].s();

        // kv：先铺平 kv 对象，再补顶层标量（顶层同名字段以 kv 为准，因为 kv 是规范位置）。
        const rta::net::Json& kv = j["kv"];
        if (kv.type == rta::net::Json::Obj) {
            for (const auto& p : kv.obj) {
                const std::string v = detail_rep::scalar_text(p.second);
                if (p.second.type != rta::net::Json::Arr && p.second.type != rta::net::Json::Obj)
                    e.kv[p.first] = v;
            }
        }
        for (const auto& p : j.obj) {
            if (p.first == "kv") continue;
            if (p.second.type == rta::net::Json::Arr || p.second.type == rta::net::Json::Obj) continue;
            if (e.kv.count(p.first)) continue;
            e.kv[p.first] = detail_rep::scalar_text(p.second);
        }
        any = true;
        st.ev.push_back(std::move(e));
    }
    return st;
}

// ================================ 证据 ======================================
struct Evidence {
    // 身份（来自 manifest / 打包时 spec）
    std::string case_id;
    std::string app_version;
    std::string app_build;
    std::string created_utc;
    std::string generator;
    std::string os, arch, cpu;

    // 运行标记（D6）：have_run=false ⇒ 包内没有任何退出状态信息
    bool        have_run = false;
    bool        clean_exit = true;
    std::string exit_reason;

    // 数据性质
    bool        simulated = false;
    std::string scenario;
    std::string source_desc;        // "目录 /path" / "zip /path" / "打包时（内存）"

    // 包完整性
    bool        verify_ok = true;
    std::string verify_summary;
    std::vector<std::string> verify_issues;

    // 包内容
    std::vector<std::string> present_files;
    bool        truncated = false;
    std::vector<std::string> truncated_entries;
    std::vector<std::string> dropped_entries;
    long long   dropped_head_bytes = 0;

    // 证据本体
    rta::net::Json diag;            // diag.json（或旧包 rlplayer-diag.json）
    bool        diag_ok = false;
    std::string diag_source;        // "diag.json" / "rlplayer-diag.json（旧 v1 包）"
    EventStream events;
    EventStream uievents;
    bool        report_in_bundle = false;

    bool has_file(const std::string& n) const {
        for (const auto& f : present_files) if (f == n) return true;
        return false;
    }
};

// 从已组装的条目构造（rtaweb 在打包过程中生成 report.txt 时用这条）
inline Evidence evidence_from_entries(const std::vector<MaterializedEntry>& ents, const BundleSpec& spec) {
    Evidence ev;
    ev.case_id = spec.case_id;
    ev.app_version = spec.app_version;
    ev.app_build = spec.app_build;
    ev.created_utc = spec.created_utc;
    ev.generator = spec.generator_tool;
    ev.os = spec.platform.os;
    ev.arch = spec.platform.arch;
    ev.cpu = spec.platform.cpu;
    ev.have_run = spec.run.known;       // 首次运行无历史标记时必须 unknown
    ev.clean_exit = spec.run.clean_exit;
    ev.exit_reason = spec.run.exit_reason;
    ev.simulated = spec.cs.simulated;
    ev.scenario = spec.cs.scenario;
    ev.source_desc = "打包时（内存）";
    ev.verify_ok = true;
    ev.verify_summary = "打包时生成（收包端仍须自行校验 manifest/checksums）";

    for (const auto& m : ents) {
        ev.present_files.push_back(m.rec.name);
        if (m.rec.truncated) {
            ev.truncated = true;
            ev.truncated_entries.push_back(m.rec.name);
            ev.dropped_head_bytes += (long long)m.rec.dropped_head_bytes;
        }
        if (m.rec.name == kDiagName) {
            ev.diag = rta::net::json_parse(m.data);
            ev.diag_ok = (ev.diag.type != rta::net::Json::Null);
            ev.diag_source = kDiagName;
        } else if (m.rec.name == kEventsName) {
            ev.events = parse_events_jsonl(m.data);
        } else if (m.rec.name == kUiEventsName) {
            ev.uievents = parse_events_jsonl(m.data);
        } else if (m.rec.name == kReportName) {
            ev.report_in_bundle = true;
        }
    }
    return ev;
}

// 从读到的包构造（rtadiag 用这条）。旧 v1 包会把 rlplayer-diag.json 当 diag 源。
inline Evidence evidence_from_bundle(const Bundle& b) {
    Evidence ev;
    ev.case_id = b.meta.case_id;
    ev.app_version = b.meta.app_version;
    ev.app_build = b.meta.app_build;
    ev.created_utc = b.meta.created_utc;
    ev.generator = b.meta.generator_tool;
    ev.os = b.meta.platform.os;
    ev.arch = b.meta.platform.arch;
    ev.cpu = b.meta.platform.cpu;
    if (b.meta.present) {
        ev.have_run = b.meta.run.known;
        ev.clean_exit = b.meta.run.clean_exit;
        ev.exit_reason = b.meta.run.exit_reason;
        ev.simulated = b.meta.cs.simulated;
        ev.scenario = b.meta.cs.scenario;
    }
    ev.source_desc = (b.verify.is_zip ? "zip " : "目录 ") + b.verify.source;
    ev.verify_ok = b.verify.ok;
    ev.verify_summary = b.verify.summary();
    ev.verify_issues = b.verify.issue_lines();

    for (const auto& f : b.files) ev.present_files.push_back(f.first);
    ev.truncated = b.meta.truncated;
    ev.truncated_entries = b.meta.shrunk;
    ev.dropped_entries = b.meta.dropped;
    ev.dropped_head_bytes = b.meta.dropped_head_bytes;

    if (const std::string* d = b.find(kDiagName)) {
        ev.diag = rta::net::json_parse(*d);
        ev.diag_ok = (ev.diag.type != rta::net::Json::Null);
        ev.diag_source = kDiagName;
    } else if (const std::string* d1 = b.find("rlplayer-diag.json")) {
        // 旧 v1 包：同样的静态信息，字段名不同但够回答 Q1。明确标注来源，不假装是 v2。
        ev.diag = rta::net::json_parse(*d1);
        ev.diag_ok = (ev.diag.type != rta::net::Json::Null);
        ev.diag_source = "rlplayer-diag.json（旧 v1 包）";
    }
    if (const std::string* e = b.find(kEventsName)) ev.events = parse_events_jsonl(*e);
    if (const std::string* e = b.find(kUiEventsName)) ev.uievents = parse_events_jsonl(*e);
    ev.report_in_bundle = b.has(kReportName);
    return ev;
}

// ================================ 结论 ======================================
enum class Verdict { Known, Unknown, Ambiguous };

inline const char* verdict_name(Verdict v) {
    switch (v) {
        case Verdict::Known:     return "known";
        case Verdict::Unknown:   return "unknown";
        case Verdict::Ambiguous: return "ambiguous";
    }
    return "unknown";
}

struct Conclusion {
    Verdict     verdict = Verdict::Unknown;
    std::string id;                    // 机器可读；unknown/ambiguous 时为空
    std::string title;                 // 中文一句话结论
    std::string detail;                // 为什么是这个结论
    double      confidence = 0.0;
    std::vector<std::string> evidence;      // 具体的 file:line + 字段
    std::vector<std::string> alternatives;  // 其它候选（"id: title"）
    std::vector<std::string> missing;       // 这条结论还缺的子证据
};

enum class QStatus { Known, Partial, Missing };

inline const char* qstatus_name(QStatus s) {
    switch (s) {
        case QStatus::Known:   return "known";
        case QStatus::Partial: return "partial";
        case QStatus::Missing: return "missing";
    }
    return "missing";
}

struct QuestionStatus {
    int         q = 0;
    std::string title;
    QStatus     status = QStatus::Missing;
    std::string detail;
    std::vector<std::string> sources;
};

struct Report {
    Verdict     verdict = Verdict::Unknown;
    Conclusion  conclusion;
    std::vector<QuestionStatus> questions;
    std::vector<std::string> missing;     // 汇总：所有"缺什么"
    std::vector<std::string> warnings;
    bool        simulated = false;
    bool        verify_ok = false;
    std::string case_id;
    std::string text;                     // render_report_text 的结果
    std::string to_json() const;
};

// ================================ 规则引擎 ==================================
namespace detail_rep {

inline bool contains_ci(const std::string& hay, const std::string& needle) {
    if (needle.empty() || hay.empty()) return false;
    std::string a, b;
    a.reserve(hay.size());
    b.reserve(needle.size());
    for (unsigned char c : hay) a.push_back((char)std::tolower(c));
    for (unsigned char c : needle) b.push_back((char)std::tolower(c));
    return a.find(b) != std::string::npos;
}

inline std::string lower(std::string s) {
    for (auto& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

struct Hit {
    const char* file = "";
    const DiagEvent* e = nullptr;
};

// 引用格式：`events.jsonl:41 seq=7 evt=decode.fail code=DEC_FLAC_TRUNCATED kv{...}`。
// 只列短字段，最多 6 个 —— 报告是给人看的，不是 dump。
inline std::string cite(const char* file, const DiagEvent& e) {
    std::ostringstream o;
    o << file << ":" << e.line;
    if (!e.ts.empty()) o << " ts=" << e.ts;
    if (e.seq) o << " seq=" << e.seq;
    if (!e.evt.empty()) o << " evt=" << e.evt;
    if (!e.stage.empty()) o << " stage=" << e.stage;
    if (!e.code.empty()) o << " code=" << e.code;
    std::size_t n = 0;
    std::string kv;
    for (const auto& p : e.kv) {
        if (p.first == "ts" || p.first == "seq" || p.first == "evt" || p.first == "event" ||
            p.first == "stage" || p.first == "code" || p.first == "sid" || p.first == "rid")
            continue;
        if (p.second.empty() || p.second.size() > 60) continue;
        if (n >= 6) { kv += ",…"; break; }
        if (n) kv += ",";
        kv += p.first + "=" + p.second;
        ++n;
    }
    if (!kv.empty()) o << " kv{" << kv << "}";
    return o.str();
}

template <class Fn>
inline void for_each_event(const Evidence& ev, Fn fn) {
    for (const auto& e : ev.events.ev) fn(kEventsName, e);
    for (const auto& e : ev.uievents.ev) fn(kUiEventsName, e);
}

inline bool stage_is(const DiagEvent& e, std::initializer_list<const char*> names) {
    const std::string s = lower(e.stage);
    for (const char* n : names) if (s == lower(n)) return true;
    return false;
}

inline bool evt_or_code_has(const DiagEvent& e, std::initializer_list<const char*> toks) {
    for (const char* t : toks) {
        if (contains_ci(e.evt, t) || contains_ci(e.code, t)) return true;
    }
    return false;
}

inline std::string kv(const DiagEvent& e, const char* key) {
    auto it = e.kv.find(key);
    return it == e.kv.end() ? std::string() : it->second;
}

inline bool kv_bool(const DiagEvent& e, const char* key, bool& out) {
    auto it = e.kv.find(key);
    if (it == e.kv.end()) return false;
    const std::string v = lower(it->second);
    if (v == "true" || v == "1" || v == "yes") { out = true; return true; }
    if (v == "false" || v == "0" || v == "no") { out = false; return true; }
    return false;
}

inline bool kv_num_val(const DiagEvent& e, const char* key, double& out) {
    auto it = e.kv.find(key);
    if (it == e.kv.end()) return false;
    char* end = nullptr;
    const double v = std::strtod(it->second.c_str(), &end);
    if (end == it->second.c_str()) return false;
    out = v;
    return true;
}

// 最近一次出现的 key 值（日志语义："最后状态"）。
inline const DiagEvent* last_with_key(const EventStream& st, const char* key) {
    for (std::size_t i = st.ev.size(); i-- > 0;) if (st.ev[i].kv.count(key)) return &st.ev[i];
    return nullptr;
}

inline bool list_contains_int(const std::string& list, double v) {
    std::size_t p = 0;
    while (p < list.size()) {
        std::size_t q = p;
        while (q < list.size() && !std::isdigit((unsigned char)list[q])) ++q;
        if (q == p) { ++p; continue; }
        std::size_t r = q;
        while (r < list.size() && (std::isdigit((unsigned char)list[r]) || list[r] == '.')) ++r;
        char* end = nullptr;
        const std::string tok = list.substr(q, r - q);
        const double x = std::strtod(tok.c_str(), &end);
        if (std::fabs(x - v) < 0.5) return true;
        p = r;
    }
    return false;
}

struct Match {
    bool hit = false;
    std::vector<std::string> evidence;
    std::vector<std::string> missing;    // 这条规则还想看到、但包里没有的子证据
    std::vector<std::string> facts;      // 关键事实（中文短句，进 detail）
    std::set<std::string> rids;          // 命中的非空 rid 集合
};

struct RuleDef {
    const char* id;
    const char* title;
    int priority;                        // 只表示"证据具体性/定位精度"，不是概率
    double base_confidence;
    std::function<bool(const Evidence&, Match&)> match;
};

// ---- 各场景的判定函数（每条都只做"证据匹配"，不做推测）----

inline bool rule_flac_truncated(const Evidence& ev, Match& m) {
    for_each_event(ev, [&](const char* file, const DiagEvent& e) {
        // A truncated log/ZIP/UI record is not evidence of truncated FLAC audio.
        if (!stage_is(e, {"decode"})) return;
        const bool flac = contains_ci(kv(e, "format"), "flac") || contains_ci(e.code, "flac");
        if (!flac) return;
        if (evt_or_code_has(e, {"TRUNC"})) { m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return; }
        bool b = false;
        if (kv_bool(e, "truncated", b) && b) { m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return; }
        if (kv_bool(e, "flac_truncated", b) && b) { m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return; }
        // 声明帧数/字节数 > 实际读出 ⇒ 文件本身不完整（这是"文件被截断"的硬证据）
        static const std::pair<const char*, const char*> kPairs[] = {
            {"frames_declared", "frames_read"},
            {"flac_frames_declared", "flac_frames_read"},
            {"bytes_declared", "bytes_read"},
            {"flac_bytes_declared", "flac_bytes_read"},
        };
        for (const auto& pair : kPairs) {
            double a = 0, b2 = 0;
            if (kv_num_val(e, pair.first, a) && kv_num_val(e, pair.second, b2) && a > b2) {
                m.hit = true;
                m.evidence.push_back(cite(file, e));
                if (!e.rid.empty()) m.rids.insert(e.rid);
                m.facts.push_back(std::string(pair.first) + "=" + num_to_text(a) + " > " +
                                  pair.second + "=" + num_to_text(b2) + "（声明量大于实际读出量）");
                return;
            }
        }
        // 有 decode 失败但没给具体量：记下"缺数值证据"，不进结论
        if (e.code.empty() && e.stage.empty()) return;
    });
    if (m.hit && !ev.diag_ok)
        m.missing.push_back("diag.json（无法确认解码格式/路径，结论只靠事件）");
    return m.hit;
}

inline bool rule_rate_unsupported(const Evidence& ev, Match& m) {
    for_each_event(ev, [&](const char* file, const DiagEvent& e) {
        bool b = false;
        if (evt_or_code_has(e, {"RATE_UNSUPPORTED", "RATE_NOT_SUPPORTED", "UNSUPPORTED_RATE",
                                "DEV_RATE_UNSUPPORTED", "SAMPLE_RATE_UNSUPPORTED"})) {
            m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return;
        }
        if (kv_bool(e, "rate_supported", b) && !b) { m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return; }
        double req = 0;
        auto it_rates = e.kv.find("device_rates");
        if (it_rates != e.kv.end() && kv_num_val(e, "requested_rate", req)) {
            // 设备报出的采样率清单里没有请求值，且没有任何回退记录 ⇒ 就是"不支持"
            if (!list_contains_int(it_rates->second, req)) {
                const bool fallback = e.kv.count("actual_rate") > 0 || e.kv.count("fallback") > 0;
                if (!fallback) {
                    m.hit = true;
                    m.evidence.push_back(cite(file, e));
                    if (!e.rid.empty()) m.rids.insert(e.rid);
                    m.facts.push_back("请求 " + num_to_text(req) + " Hz 不在设备清单 [" +
                                      it_rates->second + "] 内，且无回退记录");
                } else {
                    m.facts.push_back("请求 " + num_to_text(req) + " Hz 被回退（见 actual_rate/fallback）");
                }
            }
            return;
        }
    });
    // diag.json 里若有 device.rates 与请求率也可以判（没有 events 时兜底）
    if (!m.hit && ev.diag_ok) {
        const std::string req = detail_rep::scalar_text(ev.diag["device"]["requested_rate"]);
        const std::string rates = detail_rep::scalar_text(ev.diag["device"]["rates"]);
        if (!req.empty() && !rates.empty()) {
            const double v = std::strtod(req.c_str(), nullptr);
            if (!list_contains_int(rates, v)) {
                m.hit = true;
                m.evidence.push_back(ev.diag_source + ": device.requested_rate=" + req +
                                     "，device.rates=[" + rates + "]");
            }
        }
    }
    if (m.hit && !ev.diag_ok) m.missing.push_back("diag.json（缺设备能力清单，只有事件侧证据）");
    return m.hit;
}

inline bool rule_underrun(const Evidence& ev, Match& m) {
    for_each_event(ev, [&](const char* file, const DiagEvent& e) {
        if (stage_is(e, {"io"}) && evt_or_code_has(e, {"UNDERRUN", "STARVING", "WRITE_STALL"})) {
            m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return;
        }
        for (const char* key : {"underrun", "dry", "starve", "starving", "write_stall_ms", "late_frames"}) {
            double v = 0;
            if (kv_num_val(e, key, v) && v > 0) {
                m.hit = true;
                m.evidence.push_back(cite(file, e));
                if (!e.rid.empty()) m.rids.insert(e.rid);
                m.facts.push_back(std::string(key) + "=" + num_to_text(v) + "（>0 表示确实发生了）");
                return;
            }
        }
    });
    // 统计量在 diag.json 里也算证据
    if (!m.hit && ev.diag_ok) {
        const std::string u = detail_rep::scalar_text(ev.diag["io"]["underrun"]);
        if (!u.empty() && std::strtod(u.c_str(), nullptr) > 0) {
            m.hit = true;
            m.evidence.push_back(ev.diag_source + ": io.underrun=" + u);
        }
    }
    if (m.hit && !last_with_key(ev.events, "buffer") && !last_with_key(ev.events, "outRate"))
        m.missing.push_back("缓冲/输出格式字段（缺 outRate/buffer，欠载成因无法进一步定位）");
    return m.hit;
}

inline bool rule_meta_timeout(const Evidence& ev, Match& m) {
    for_each_event(ev, [&](const char* file, const DiagEvent& e) {
        if (!stage_is(e, {"meta", "metadata"})) return;
        if (evt_or_code_has(e, {"TIMEOUT", "TIMED_OUT"})) { m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return; }
        bool b = false;
        if (kv_bool(e, "timed_out", b) && b) { m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return; }
        double ms = 0;
        bool timedOut = false;
        if (kv_num_val(e, "timeout_ms", ms) && ms > 0 && kv_bool(e, "timed_out", timedOut) && timedOut) {
            m.hit = true; m.evidence.push_back(cite(file, e));
            if (!e.rid.empty()) m.rids.insert(e.rid);
            m.facts.push_back("timeout_ms=" + num_to_text(ms));
        }
    });
    if (m.hit && !ev.diag_ok) m.missing.push_back("diag.json（缺元数据源/超时配置，无法判断是本地还是远端超时）");
    return m.hit;
}

inline bool rule_llm_config(const Evidence& ev, Match& m) {
    for_each_event(ev, [&](const char* file, const DiagEvent& e) {
        if (!stage_is(e, {"llm", "ai", "knowledge"})) return;
        if (evt_or_code_has(e, {"LLM_AUTH", "LLM_CONF", "NO_KEY", "MODEL_NOT_FOUND",
                                "CONFIG_INVALID", "UNAUTHORIZED"})) {
            m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return;
        }
        double code = 0;
        if (kv_num_val(e, "http_status", code) &&
            (code == 401 || code == 403)) {
            m.hit = true; m.evidence.push_back(cite(file, e));
            if (!e.rid.empty()) m.rids.insert(e.rid);
            m.facts.push_back("http_status=" + num_to_text(code) + "（鉴权/端点/模型名一类配置问题）");
            return;
        }
        bool b = false;
        if (kv_bool(e, "config_invalid", b) && b) { m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return; }
        if (kv_bool(e, "key_present", b) && !b) {
            m.hit = true; m.evidence.push_back(cite(file, e));
            if (!e.rid.empty()) m.rids.insert(e.rid);
            m.facts.push_back("key_present=false（未配置密钥）");
        }
    });
    if (m.hit && !ev.diag_ok) m.missing.push_back("diag.json（缺 LLM 端点/模型名摘要，无法指出具体哪个字段错）");
    else if (m.hit && ev.diag_ok && !ev.diag.has("llm"))
        m.missing.push_back("diag.json 的 llm 段（端点/模型/是否配 key —— 本包未包含）");
    return m.hit;
}

// Transport failures have their own conclusions; do not guess that the user's key/base is wrong.
inline bool rule_llm_network(const Evidence& ev, Match& m) {
    for_each_event(ev,[&](const char* file,const DiagEvent& e){
        if(stage_is(e,{"llm"}) && e.code=="llm.network_failed") {m.hit=true;m.evidence.push_back(cite(file,e));if (!e.rid.empty()) m.rids.insert(e.rid);}
    });return m.hit;
}
inline bool rule_llm_rate_limit(const Evidence& ev, Match& m) {
    for_each_event(ev,[&](const char* file,const DiagEvent& e){
        double status=0;
        if(stage_is(e,{"llm"}) && (e.code=="llm.rate_limited" || (kv_num_val(e,"http_status",status)&&status==429))) {m.hit=true;m.evidence.push_back(cite(file,e));if (!e.rid.empty()) m.rids.insert(e.rid);}
    });return m.hit;
}
inline bool rule_cast_no_device(const Evidence& ev, Match& m) {
    for_each_event(ev, [&](const char* file, const DiagEvent& e) {
        if (!stage_is(e, {"upnp", "cast", "airplay"})) return;
        if (evt_or_code_has(e, {"NO_DEVICE", "NO_RENDERER", "NO_TARGET", "DISCOVERY_EMPTY"})) {
            m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return;
        }
        double devices = 0;
        if (kv_num_val(e, "devices", devices) && devices == 0) {
            m.hit = true; m.evidence.push_back(cite(file, e));
            if (!e.rid.empty()) m.rids.insert(e.rid);
            m.facts.push_back("devices=0（发现阶段没有任何可选渲染器）");
            return;
        }
        double sent = 0, replies = 0;
        if (kv_num_val(e, "sent", sent) && kv_num_val(e, "replies", replies) && sent > 0 && replies == 0) {
            m.hit = true; m.evidence.push_back(cite(file, e));
            if (!e.rid.empty()) m.rids.insert(e.rid);
            m.facts.push_back("sent=" + num_to_text(sent) + " replies=0（发了请求但没有设备应答）");
        }
    });
    // 也可由 diag.json 的 cast/upnp 段给出
    if (!m.hit && ev.diag_ok) {
        const std::string n = detail_rep::scalar_text(ev.diag["cast"]["devices"]);
        if (!n.empty() && std::strtod(n.c_str(), nullptr) == 0) {
            m.hit = true;
            m.evidence.push_back(ev.diag_source + ": cast.devices=0");
        }
    }
    if (m.hit)
        m.missing.push_back("投放发现细节（ifaces / multicast / replies）—— 缺了就分不清"
                            "「本来就没有设备」与「设备在但发现包发不出去」");
    return m.hit;
}

inline bool rule_room_cancelled(const Evidence& ev, Match& m) {
    for_each_event(ev, [&](const char* file, const DiagEvent& e) {
        if (!stage_is(e, {"room", "room_measure"})) return;
        if (evt_or_code_has(e, {"CANCEL"})) { m.hit = true; m.evidence.push_back(cite(file, e)); if (!e.rid.empty()) m.rids.insert(e.rid); return; }
        bool b = false;
        if (kv_bool(e, "cancelled", b) && b) {
            m.hit = true; m.evidence.push_back(cite(file, e));
            if (!e.rid.empty()) m.rids.insert(e.rid);
            m.facts.push_back("cancelled=true（用户或界面取消）");
        }
    });
    if (m.hit) {
        double frames = 0;
        const DiagEvent* fr = last_with_key(ev.events, "captured_frames");
        if (fr && kv_num_val(*fr, "captured_frames", frames) && frames == 0)
            m.facts.push_back("captured_frames=0（采集未写入任何帧，属取消而非测量失败）");
    }
    return m.hit;
}

inline bool rule_unclean_exit(const Evidence& ev, Match& m) {
    if (!ev.have_run || ev.clean_exit) return false;
    m.hit = true;
    m.evidence.push_back("manifest.json: run.clean_exit=false" +
                         (ev.exit_reason.empty() ? std::string("，exit_reason 为空")
                                                 : "，exit_reason=" + ev.exit_reason));
    if (ev.exit_reason.empty())
        m.facts.push_back("没有退出原因字段 ⇒ 只能判「未正常退出」，不能判崩溃或被杀");
    return true;
}

// crash/killed：只有包内**明确写了**信号/原因才下这两个结论（D6 红线：不猜）。
inline bool rule_crash_evidence(const Evidence& ev, Match& m) {
    if (!ev.have_run || ev.clean_exit) return false;
    if (ev.exit_reason.rfind("crash_dump:", 0) != 0 &&
        ev.exit_reason != "signal:SIGSEGV" && ev.exit_reason != "signal:SIGABRT" &&
        ev.exit_reason != "signal:SIGBUS" && ev.exit_reason != "signal:SIGILL")
        return false;
    m.hit = true;
    m.evidence.push_back("manifest.json: run.exit_reason=\"" + ev.exit_reason + "\"");
    return true;
}

inline bool rule_killed_evidence(const Evidence& ev, Match& m) {
    if (!ev.have_run || ev.clean_exit) return false;
    if (ev.exit_reason != "signal:SIGKILL" && ev.exit_reason != "supervisor:killed")
        return false;
    m.hit = true;
    m.evidence.push_back("manifest.json: run.exit_reason=\"" + ev.exit_reason + "\"");
    return true;
}

inline const std::vector<RuleDef>& rules() {
    static const std::vector<RuleDef> k = {
        // priority = 证据具体性：能指到"哪一步、哪个量"的排前面；
        // run.unclean 只说明"没正常收尾"，是最弱的证据，所以垫底。
        {"decode.flac_truncated", "FLAC 数据被截断：文件本身不完整，解码到的帧数少于头部声明", 92, 0.92,
         rule_flac_truncated},
        {"negotiate.rate_unsupported", "输出设备不支持请求的采样率，且没有可用的回退", 90, 0.90,
         rule_rate_unsupported},
        {"io.underrun", "输出欠载：渲染跟不上实时（写空/停顿计数大于 0）", 86, 0.88, rule_underrun},
        {"meta.timeout", "元数据环节超时（meta 阶段等待超时）", 82, 0.88, rule_meta_timeout},
        {"llm.config_error", "LLM 未配置或鉴权被拒绝（其余配置字段需结合上下文核查）", 82, 0.87, rule_llm_config},
        {"llm.network_failed", "LLM 网络传输失败，未取得 HTTP 响应；网络、代理或地址成因尚未区分", 82, 0.87, rule_llm_network},
        {"llm.rate_limited", "LLM 服务返回限流状态（HTTP 429）", 82, 0.90, rule_llm_rate_limit},
        {"cast.no_device", "没有任何可投放设备（发现阶段为空）", 82, 0.86, rule_cast_no_device},
        {"room.cancelled", "房间测量被取消（不是测量失败）", 82, 0.88, rule_room_cancelled},
        {"run.crash", "进程崩溃退出（包内写明了崩溃信号）", 20, 0.80, rule_crash_evidence},
        {"run.killed", "进程被外部终止（包内写明了终止原因）", 20, 0.80, rule_killed_evidence},
        {"run.unclean_exit", "上次运行没有正常退出（运行标记未清除）；现有证据不能判定为崩溃或被强杀", 10,
         0.75, rule_unclean_exit},
    };
    return k;
}

}  // namespace detail_rep

// ================================ 分析 ======================================
namespace detail_rep {

inline bool diag_str(const Evidence& ev, const char* a, std::string& out) {
    if (!ev.diag_ok) return false;
    const std::string v = scalar_text(ev.diag[a]);
    if (v.empty()) return false;
    out = v;
    return true;
}

inline void set_q(QuestionStatus& q, QStatus s, std::string detail,
                  std::vector<std::string> sources = {}) {
    q.status = s;
    q.detail = std::move(detail);
    // 同一个事件常被多个字段引用（device / requested_rate / actual_rate 同在一行），
    // 报告里只列一次 —— 重复行会让人以为有多条独立证据。
    q.sources.clear();
    for (const auto& x : sources) {
        bool dup = false;
        for (const auto& y : q.sources) if (y == x) { dup = true; break; }
        if (!dup) q.sources.push_back(x);
    }
}

// 十问（ROADMAP 1.1.1「诊断目标」表）。每一问都回答"known / partial / missing"，
// 并写清来源；missing 就是「缺失报告」的正文。
inline void fill_questions(const Evidence& ev, std::vector<QuestionStatus>& out,
                           const CodeLookup& lookup) {
    out.clear();
    out.resize(10);
    for (int i = 0; i < 10; ++i) { out[(std::size_t)i].q = i + 1; }

    // Q1 版本与运行环境
    {
        auto& q = out[0];
        q.title = "什么版本和运行环境？";
        std::vector<std::string> src;
        std::string ver = ev.app_version;
        if (ver.empty() && ev.diag_ok) diag_str(ev, "version", ver);
        if (!ver.empty()) src.push_back("version=" + ver);

        std::string os = ev.os;
        if (os.empty() && ev.diag_ok) diag_str(ev, "os", os);
        if (!os.empty()) src.push_back("os=" + os);

        std::string arch = ev.arch;
        if (arch.empty() && ev.diag_ok) diag_str(ev, "arch", arch);
        if (!arch.empty()) src.push_back("arch=" + arch);

        std::string cpu = ev.cpu;
        if (cpu.empty() && ev.diag_ok) diag_str(ev, "cpu", cpu);
        if (!cpu.empty()) src.push_back("cpu=" + cpu);

        std::vector<std::string> missing_fields;
        if (ver.empty()) missing_fields.push_back("版本号(version)");
        if (os.empty()) missing_fields.push_back("操作系统(os)");
        if (arch.empty()) missing_fields.push_back("架构(arch)");
        if (cpu.empty()) missing_fields.push_back("CPU型号(cpu)");

        if (missing_fields.empty()) {
            set_q(q, QStatus::Known, "版本与运行环境（OS/Arch/CPU）均有完整记录", src);
        } else if (src.empty()) {
            set_q(q, QStatus::Missing, "包内缺少版本及运行环境信息", src);
        } else {
            std::string miss_desc = "部分环境信息缺失（缺 ";
            for (std::size_t i = 0; i < missing_fields.size(); ++i) {
                if (i) miss_desc += ", ";
                miss_desc += missing_fields[i];
            }
            miss_desc += "）";
            set_q(q, QStatus::Partial, miss_desc, src);
        }
    }
    // Q2 素材与解码路径
    {
        auto& q = out[1];
        q.title = "什么素材和解码路径？";
        std::vector<std::string> src;

        struct DecodeInfo {
            std::string format;
            std::string rate;
            std::vector<std::string> cites;
        };
        std::map<std::string, DecodeInfo> by_rid;
        bool has_decode_event = false;
        std::set<std::string> formats_seen, rates_seen;

        for (const auto& e : ev.events.ev) {
            const bool is_decode = stage_is(e, {"decode"}) || contains_ci(e.evt, "DECODE");
            std::string f = kv(e, "format");
            std::string r = kv(e, "rate");
            if (f.empty()) {
                bool b = false;
                if (kv_bool(e, "flac", b) && b) f = "flac";
            }
            if (!f.empty()) formats_seen.insert(f);
            if (!r.empty()) rates_seen.insert(r);

            if (is_decode || !f.empty() || !r.empty()) {
                has_decode_event = true;
                std::string k = e.rid;
                auto& di = by_rid[k];
                if (!f.empty() && di.format.empty()) di.format = f;
                if (!r.empty() && di.rate.empty()) di.rate = r;
                di.cites.push_back(cite(kEventsName, e));
            }
        }

        bool known_found = false;
        for (const auto& pair : by_rid) {
            if (!pair.first.empty() && !pair.second.format.empty() && !pair.second.rate.empty()) {
                known_found = true;
                for (const auto& c : pair.second.cites) {
                    if (src.size() < 3) src.push_back(c);
                }
                break;
            }
        }
        if (!known_found) {
            for (const auto& e : ev.events.ev) {
                if (e.rid.empty()) {
                    std::string f = kv(e, "format");
                    std::string r = kv(e, "rate");
                    if (!f.empty() && !r.empty()) {
                        known_found = true;
                        src.push_back(cite(kEventsName, e));
                        break;
                    }
                }
            }
        }

        if (!known_found && ev.diag_ok && ev.diag.has("decode")) {
            const auto& dj = ev.diag["decode"];
            std::string df = scalar_text(dj["format"]);
            std::string dr = scalar_text(dj["rate"]);
            if (dr.empty()) dr = scalar_text(dj["sample_rate"]);
            if (!df.empty() && !dr.empty()) {
                known_found = true;
                src.push_back(ev.diag_source + ": decode.format=" + df + ", rate=" + dr);
            }
        }

        if (known_found) {
            set_q(q, QStatus::Known, "同一解码请求中具备格式与采样率完整记录", src);
        } else if (has_decode_event || (ev.diag_ok && ev.diag.has("decode"))) {
            if (ev.diag_ok && ev.diag.has("decode") && src.empty())
                src.push_back(ev.diag_source + ": decode 段");
            if (src.empty()) {
                for (const auto& pair : by_rid) {
                    for (const auto& c : pair.second.cites) {
                        src.push_back(c);
                        if (src.size() >= 2) break;
                    }
                    if (src.size() >= 2) break;
                }
            }

            if (!formats_seen.empty() && !rates_seen.empty()) {
                set_q(q, QStatus::Partial, "格式与采样率来自不同请求 (rid)，不能拼凑为当前解码路径", src);
            } else if (!formats_seen.empty()) {
                set_q(q, QStatus::Partial, "有解码格式记录但缺少采样率 (rate)", src);
            } else if (!rates_seen.empty()) {
                set_q(q, QStatus::Partial, "有采样率记录但缺少格式 (format)", src);
            } else {
                set_q(q, QStatus::Partial, "有解码事件但缺少格式与采样率字段", src);
            }
        } else {
            set_q(q, QStatus::Missing, "没有 decode 阶段事件，也没有 diag.json 的 decode 段", src);
        }
    }
    // Q3 失败在哪个阶段
    {
        auto& q = out[2];
        q.title = "失败在哪个阶段？";
        std::vector<std::string> src;

        const DiagEvent* last_fail = nullptr;
        std::set<std::string> stages;
        for (std::size_t i = ev.events.ev.size(); i-- > 0;) {
            const auto& e = ev.events.ev[i];
            if (!e.stage.empty()) stages.insert(e.stage);
            if (!last_fail && !e.code.empty() && !e.stage.empty() && e.stage != "unknown") {
                last_fail = &e;
            }
        }

        if (last_fail) {
            src.push_back(cite(kEventsName, *last_fail));
            src.push_back("失败阶段=" + last_fail->stage + " (code=" + last_fail->code + ")");
            // 只有 init 阶段不能简单判定为 Known（缺少进一步失败定位，仅知在启动阶段）
            if (last_fail->stage == "init") {
                set_q(q, QStatus::Partial, "事件仅停留在 init 阶段（缺少后续阶段定位），不能确定具体失败阶段", src);
            } else {
                set_q(q, QStatus::Known, "失败事件指明阶段为 " + last_fail->stage + "（错误码 " + last_fail->code + "）", src);
            }
        } else if (!stages.empty()) {
            for (const auto& s : stages) src.push_back("stage=" + s);
            set_q(q, QStatus::Partial, "只有运行阶段记录（无失败错误码），不能确定失败阶段", src);
        } else {
            set_q(q, QStatus::Missing, "事件里没有 stage 字段（无法回答失败落在哪一步）", src);
        }
    }
    // Q4 错误原因
    {
        auto& q = out[3];
        q.title = "错误原因是什么？";
        std::vector<std::string> src;
        const DiagEvent* with_code = nullptr;
        for (std::size_t i = ev.events.ev.size(); i-- > 0;) {
            if (!ev.events.ev[i].code.empty()) { with_code = &ev.events.ev[i]; break; }
        }
        std::string last_err;
        if (ev.diag_ok) {
            last_err = scalar_text(ev.diag["last_error"]);
            if (last_err.empty()) last_err = scalar_text(ev.diag["lastError"]);
        }

        if (with_code) {
            src.push_back(cite(kEventsName, *with_code));
            if (lookup) {
                CodeInfo ci;
                if (lookup(with_code->code, ci) && !ci.name_zh.empty()) {
                    src.push_back("错误码表: " + with_code->code + " = " + ci.name_zh);
                    set_q(q, QStatus::Known, "有错误码且码表给出了可读说明", src);
                } else {
                    set_q(q, QStatus::Partial,
                          "有错误码 " + with_code->code + "，但错误码表里没有它（说明缺失）", src);
                }
            } else {
                set_q(q, QStatus::Partial,
                          "有错误码 " + with_code->code + "，但未链接错误码表（说明缺失；"
                          "rtadiag 当前没有 --codes 表）", src);
            }
        } else if (!last_err.empty()) {
            src.push_back(ev.diag_source + ": " + (ev.diag.has("lastError") ? "lastError" : "last_error") + "=" + last_err);
            set_q(q, QStatus::Partial, "只有自由文本 last_error，没有稳定错误码", src);
        } else {
            set_q(q, QStatus::Missing, "包内没有错误码，也没有 last_error", src);
        }
    }
    // Q5 设备与格式协商
    {
        auto& q = out[4];
        q.title = "设备与格式如何协商？";
        std::vector<std::string> src;

        struct NegotiateInfo {
            std::string device;
            std::string requested_rate;
            std::string actual_rate;
            std::vector<std::string> cites;
        };
        std::map<std::string, NegotiateInfo> by_rid;
        bool has_neg_fields = false;
        std::set<std::string> dev_seen, req_seen, act_seen;

        for (const auto& e : ev.events.ev) {
            std::string d = kv(e, "device");
            std::string r = kv(e, "requested_rate");
            std::string a = kv(e, "actual_rate");
            if (a.empty()) a = kv(e, "rate_supported");

            if (!d.empty()) dev_seen.insert(d);
            if (!r.empty()) req_seen.insert(r);
            if (!a.empty()) act_seen.insert(a);

            if (!d.empty() || !r.empty() || !a.empty()) {
                has_neg_fields = true;
                std::string k = e.rid;
                auto& ni = by_rid[k];
                if (!d.empty() && ni.device.empty()) ni.device = d;
                if (!r.empty() && ni.requested_rate.empty()) ni.requested_rate = r;
                if (!a.empty() && ni.actual_rate.empty()) ni.actual_rate = a;
                ni.cites.push_back(cite(kEventsName, e));
            }
        }

        bool known_found = false;
        for (const auto& pair : by_rid) {
            if (!pair.first.empty() && !pair.second.device.empty() &&
                !pair.second.requested_rate.empty() && !pair.second.actual_rate.empty()) {
                known_found = true;
                for (const auto& c : pair.second.cites) {
                    if (src.size() < 3) src.push_back(c);
                }
                break;
            }
        }
        if (!known_found) {
            for (const auto& e : ev.events.ev) {
                if (e.rid.empty()) {
                    std::string d = kv(e, "device");
                    std::string r = kv(e, "requested_rate");
                    std::string a = kv(e, "actual_rate");
                    if (a.empty()) a = kv(e, "rate_supported");
                    if (!d.empty() && !r.empty() && !a.empty()) {
                        known_found = true;
                        src.push_back(cite(kEventsName, e));
                        break;
                    }
                }
            }
        }

        if (!known_found && ev.diag_ok && ev.diag.has("device")) {
            const auto& dj = ev.diag["device"];
            std::string dn = scalar_text(dj["name"]);
            if (dn.empty()) dn = scalar_text(dj["device"]);
            std::string dr = scalar_text(dj["requested_rate"]);
            std::string da = scalar_text(dj["actual_rate"]);
            if (da.empty()) da = scalar_text(dj["rates"]);
            if (!dn.empty() && !dr.empty() && !da.empty()) {
                known_found = true;
                src.push_back(ev.diag_source + ": device=" + dn + ", requested=" + dr + ", actual=" + da);
            }
        }

        if (known_found) {
            set_q(q, QStatus::Known, "同一请求中设备、请求值与实际值协商齐全", src);
        } else if (has_neg_fields || (ev.diag_ok && ev.diag.has("device"))) {
            if (ev.diag_ok && ev.diag.has("device") && src.empty())
                src.push_back(ev.diag_source + ": device 段");
            if (src.empty()) {
                for (const auto& pair : by_rid) {
                    for (const auto& c : pair.second.cites) {
                        src.push_back(c);
                        if (src.size() >= 2) break;
                    }
                    if (src.size() >= 2) break;
                }
            }

            if (!dev_seen.empty() && (!req_seen.empty() || !act_seen.empty())) {
                set_q(q, QStatus::Partial, "设备信息与协商参数来自不同请求 (rid)，旧请求能力不能证明当前协商", src);
            } else {
                set_q(q, QStatus::Partial, "协商信息不完整（缺 device/requested/actual 之一）", src);
            }
        } else {
            set_q(q, QStatus::Missing, "没有设备协商记录", src);
        }
    }
    // Q6 实际生效了什么设置
    {
        auto& q = out[5];
        q.title = "实际生效了什么设置？";
        std::vector<std::string> src;
        if (ev.diag_ok && ev.diag.has("settings")) src.push_back(ev.diag_source + ": saved settings 段（偏好，不代表已生效）");
        const bool effective=ev.diag_ok && ev.diag["effective_settings"].type==rta::net::Json::Obj && !scalar_text(ev.diag["settings_fingerprint"]).empty();
        if(effective) src.push_back(ev.diag_source+": effective_settings + settings_fingerprint");
        const DiagEvent* p = last_with_key(ev.events, "outRate");
        if (p) src.push_back(cite(kEventsName, *p));
        if(effective) set_q(q,QStatus::Known,"有实际管线快照及设置指纹",src);
        else if (!src.empty()) set_q(q, QStatus::Partial, "只有保存偏好（saved settings）或零散输出信息，尚无完整生效快照", src);
        else set_q(q, QStatus::Missing, "没有设置摘要（diag.json 的 settings 段与 PLAY 事件都没有）", src);
    }
    // Q7 欠载或写入停滞
    {
        auto& q = out[6];
        q.title = "是否欠载或写入停滞？";
        std::vector<std::string> src;

        bool has_io_stats = false;
        bool has_isolated_metric = false;

        for (const auto& e : ev.events.ev) {
            const bool is_io = stage_is(e, {"io"}) || contains_ci(e.evt, "UNDERRUN") || contains_ci(e.evt, "STARVING");
            bool metric_in_event = false;
            for (const char* key : {"underrun", "dry", "starve", "starving", "write_stall_ms", "late_frames"}) {
                if (e.kv.count(key)) {
                    metric_in_event = true;
                    break;
                }
            }
            if (is_io && metric_in_event) {
                has_io_stats = true;
                src.push_back(cite(kEventsName, e));
            } else if (metric_in_event) {
                has_isolated_metric = true;
                if (src.empty()) src.push_back(cite(kEventsName, e));
            }
        }

        if (!has_io_stats && ev.diag_ok && ev.diag.has("io")) {
            has_io_stats = true;
            src.push_back(ev.diag_source + ": io 监控段");
        }

        if (has_io_stats) {
            set_q(q, QStatus::Known, "有明确的 IO 阶段渲染监控统计（含 underrun/dry/starve 计数）", src);
        } else if (has_isolated_metric) {
            set_q(q, QStatus::Partial, "仅有零星指标（如孤立 dry 计数），缺少完整 IO 阶段渲染统计", src);
        } else {
            set_q(q, QStatus::Missing, "没有任何欠载/写入停滞计数（因此不能回答「是否欠载」）", src);
        }
    }
    // Q8 用户此前做了什么
    {
        auto& q = out[7];
        q.title = "用户此前做了什么？";
        std::vector<std::string> src;
        if (ev.uievents.usable()) {
            src.push_back("uievents.jsonl: " + std::to_string(ev.uievents.ev.size()) + " 条");
            if (!ev.uievents.ev.empty()) src.push_back(cite(kUiEventsName, ev.uievents.ev.back()));
            set_q(q, QStatus::Known, "有界面事件轨迹", src);
        } else if (ev.has_file(kUiEventsName)) {
            src.push_back("uievents.jsonl 存在但没有可用行");
            set_q(q, QStatus::Partial, "uievents.jsonl 是空的（界面动作没有记录）", src);
        } else {
            set_q(q, QStatus::Missing, "没有 uievents.jsonl（界面动作无记录）", src);
        }
    }
    // Q9 上次是否正常退出
    {
        auto& q = out[8];
        q.title = "上次是否正常退出？";
        std::vector<std::string> src;
        if (ev.have_run) {
            src.push_back(std::string("manifest.json: run.clean_exit=") + (ev.clean_exit ? "true" : "false"));
            if (!ev.exit_reason.empty()) src.push_back("run.exit_reason=" + ev.exit_reason);
            set_q(q, QStatus::Known,
                  ev.clean_exit ? "运行标记已正常清除"
                                : (ev.exit_reason.empty()
                                       ? "运行标记未清除；没有退出原因，不能判崩溃/被杀"
                                       : "运行标记未清除，exit_reason=" + ev.exit_reason),
                  src);
        } else {
            set_q(q, QStatus::Missing, "首次运行或缺少运行标记（run.known=false），无法判断退出状态", src);
        }
    }
    // Q10 缓存、网络还是服务异常
    {
        auto& q = out[9];
        q.title = "缓存、网络还是服务异常？";
        std::vector<std::string> src;

        bool has_discriminator = false;
        bool has_only_http_status = false;

        for (const auto& e : ev.events.ev) {
            bool has_status = e.kv.count("http_status") > 0;
            bool has_cache = e.kv.count("cache_hit") > 0;
            bool has_net = e.kv.count("net_error") > 0 || e.code == "llm.network_failed";
            bool has_source = e.kv.count("source") > 0;

            if (has_cache || has_net || (has_status && has_source)) {
                has_discriminator = true;
                src.push_back(cite(kEventsName, e));
            } else if (has_status) {
                has_only_http_status = true;
                if (src.empty()) src.push_back(cite(kEventsName, e));
            }
        }

        if (has_discriminator) {
            set_q(q, QStatus::Known, "具备区分缓存、网络与服务异常的上下文记录", src);
        } else if (has_only_http_status) {
            set_q(q, QStatus::Partial, "仅有单个 HTTP 状态码，缺少缓存命中或网络传输状态，无法明确区分异常源", src);
        } else {
            set_q(q, QStatus::Missing, "包内没有 HTTP 状态、缓存命中或网络传输字段", src);
        }
    }
}

}  // namespace detail_rep

// 先声明后定义：analyze 结束时要顺手把正文渲染好（默认参数只在定义处给一次）。
inline std::string render_report_text(const Report& r, const Evidence* ev);

inline Report analyze(const Evidence& ev, const CodeLookup& lookup = nullptr) {
    Report rep;
    rep.simulated = ev.simulated;
    rep.verify_ok = ev.verify_ok;
    rep.case_id = ev.case_id;

    detail_rep::fill_questions(ev, rep.questions, lookup);

    // ---- ① 包本身不可信 ⇒ 不给结论（这是"不猜"的第一道闸）----
    if (!ev.verify_ok) {
        rep.verdict = Verdict::Unknown;
        rep.conclusion.verdict = Verdict::Unknown;
        rep.conclusion.title = "无法给出结论：诊断包完整性校验未通过";
        rep.conclusion.detail =
            "包内字节与 manifest/checksums 对不上，或缺少 v2 必需条目。"
            "在这种情况下任何结论都不可信，因此只报缺失项，不做推断。";
        rep.conclusion.confidence = 0.0;
        rep.missing = ev.verify_issues;
        if (ev.verify_issues.empty()) rep.missing.push_back("校验失败但未给出原因（异常状态）");
        // 旧 v1 包补一句人话
        bool v1 = false;
        for (const auto& i : ev.verify_issues)
            if (i.find("v1") != std::string::npos) v1 = true;
        if (v1) {
            rep.missing.push_back("manifest.json / checksums.txt（v2 才要求；旧包因此无法核验）");
            rep.missing.push_back("events.jsonl / uievents.jsonl（v1 没有结构化事件，Q2/Q3/Q4/Q5/Q7/Q8/Q10 无法回答）");
            rep.warnings.push_back("这是 v1 诊断包的正常表现：不是包坏了，而是格式不足以定论。"
                                   "请用 1.1.1 及以后的「导出诊断」重新生成 v2 包。");
        }
    } else {
        // ---- ② 逐规则匹配 ----
        std::vector<std::pair<const detail_rep::RuleDef*, detail_rep::Match>> hits;
        for (const auto& r : detail_rep::rules()) {
            detail_rep::Match m;
            if (r.match(ev, m) && m.hit) hits.emplace_back(&r, std::move(m));
        }

        if (hits.empty()) {
            rep.verdict = Verdict::Unknown;
            rep.conclusion.verdict = Verdict::Unknown;
            rep.conclusion.title = "包内没有可判定的失败证据，不能给出结论";
            rep.conclusion.detail =
                "所有已知场景的信号都没有命中。这可能是「没有失败」，也可能是「失败路径没打点」。";
            rep.conclusion.confidence = 0.0;
            if (!ev.events.usable())
                rep.missing.push_back("events.jsonl 里没有可解析事件（0 条），失败路径无从取证");
            if (!ev.diag_ok) rep.missing.push_back("diag.json（缺环境/设置/解码摘要）");
            rep.missing.push_back("失败场景需要至少一条带 stage+code 的事件（见 report.h 的信号词表）");
        } else {
            std::stable_sort(hits.begin(), hits.end(), [](const auto& a, const auto& b) {
                return a.first->priority > b.first->priority;
            });
            const int top = hits.front().first->priority;
            const auto& top_rids = hits.front().second.rids;
            const auto& best = hits.front();

            Conclusion c;
            c.confidence = best.first->base_confidence;
            for (const auto& mi : best.second.missing) c.missing.push_back(mi);
            c.confidence -= 0.06 * (double)c.missing.size();
            if (c.confidence < 0.5) c.confidence = 0.5;
            if (c.confidence > 0.98) c.confidence = 0.98;
            c.title = best.first->title;
            c.evidence = best.second.evidence;

            std::ostringstream why;
            why << "按证据判定：" << c.title << "。依据是下面 " << c.evidence.size()
                << " 条可核对的事实";
            if (!best.second.facts.empty()) {
                why << "：";
                for (std::size_t i = 0; i < best.second.facts.size(); ++i) {
                    if (i) why << "；";
                    why << best.second.facts[i];
                }
            } else {
                why << "。";
            }
            c.detail = why.str();

            // 其它候选：并列的同优先级 = 冲突；低优先级 = 只作备选说明。
            // 关键：若多个独立失败来自不同 rid（且两者 rid 集合均非空且不相交），
            // 说明属于不同请求的独立失败，不能拍脑袋挑一个作为“总根因”，必须保守判为 ambiguous！
            bool diff_rid_conflict = false;
            std::vector<std::string> others_same, others_lower;
            for (std::size_t i = 1; i < hits.size(); ++i) {
                const std::string s = std::string(hits[i].first->id) + ": " + hits[i].first->title;
                const auto& cur_rids = hits[i].second.rids;
                bool disjoint_rid = false;
                if (!top_rids.empty() && !cur_rids.empty()) {
                    bool has_common = false;
                    for (const auto& r1 : top_rids) {
                        if (cur_rids.count(r1)) { has_common = true; break; }
                    }
                    if (!has_common) disjoint_rid = true;
                }

                if (hits[i].first->priority == top || disjoint_rid) {
                    others_same.push_back(s);
                    if (disjoint_rid) diff_rid_conflict = true;
                } else {
                    others_lower.push_back(s);
                }
            }
            if (!others_same.empty()) {
                rep.verdict = Verdict::Ambiguous;
                c.verdict = Verdict::Ambiguous;
                c.id.clear();
                if (diff_rid_conflict) {
                    c.title = "证据指向多个不同请求的独立失败，无法归结为单一总根因";
                    c.detail = std::string("检测到多个不同请求 (rid) 发生了不同类型的失败，"
                                           "按现有证据无法排定单一总根因，因此并列列出，拒绝挑选：\n  - ") +
                               best.first->id + ": " + best.first->title;
                } else {
                    c.title = "证据同时指向多个同等具体的失败原因，不能给唯一结论";
                    c.detail = std::string("以下规则命中的证据具体程度相同（都能指到具体量/具体阶段），"
                                           "按现有证据无法排序，因此并列列出，不做挑选：\n  - ") +
                               best.first->id + ": " + best.first->title;
                }
                for (const auto& s : others_same) c.detail += "\n  - " + s;
                c.confidence = 0.0;
                c.alternatives = others_same;
                c.alternatives.insert(c.alternatives.begin(),
                                      std::string(best.first->id) + ": " + best.first->title);
            } else {
                rep.verdict = Verdict::Known;
                c.verdict = Verdict::Known;
                c.id = best.first->id;
                if (!others_lower.empty()) {
                    c.alternatives = others_lower;
                    c.detail += "（另有更低具体性的信号同时存在，按具体性排序未作为主结论：";
                    for (std::size_t i = 0; i < others_lower.size(); ++i) {
                        if (i) c.detail += "；";
                        c.detail += others_lower[i];
                    }
                    c.detail += "）";
                }
            }
            rep.conclusion = c;
        }
    }

    // ---- ③ 汇总缺失项（去重，保持顺序）----
    auto push_missing = [&](const std::string& s) {
        if (s.empty()) return;
        for (const auto& x : rep.missing) if (x == s) return;
        rep.missing.push_back(s);
    };
    for (const auto& m : rep.conclusion.missing) push_missing(m);
    for (const auto& q : rep.questions) {
        if (q.status == QStatus::Missing) push_missing("Q" + std::to_string(q.q) + " " + q.title + "：" + q.detail);
    }
    if (ev.truncated) {
        push_missing("事件被裁剪（" + std::to_string(ev.truncated_entries.size()) +
                     " 条保留尾部，共丢弃头部 " + std::to_string(ev.dropped_head_bytes) +
                     " 字节）：更早的证据看不到，结论只基于最近的部分");
    }
    for (const auto& d : ev.dropped_entries) push_missing("条目被整条丢弃：" + d + "（体积预算）");
    if (ev.events.head_partial) push_missing("events.jsonl 首行不完整（裁剪点落在行中间），已跳过该行");
    if (ev.events.tail_partial) push_missing("events.jsonl 末行不完整（写入被切断），已跳过该行");
    if (ev.events.bad_lines > 0)
        rep.warnings.push_back("events.jsonl 有 " + std::to_string(ev.events.bad_lines) +
                               " 行不是合法 JSON 对象（已跳过，未当作证据）");
    if (ev.simulated)
        rep.warnings.push_back("本包 case.simulated=true：内容为模拟/夹具证据，**不能**当作真实运行诊断");

    // 报告正文随结论一起产出：调用方（rtadiag / rtaweb 打包回调）不必再记得渲染一次。
    rep.text = render_report_text(rep, &ev);
    return rep;
}

// ================================ 渲染 ======================================
inline std::string render_report_text(const Report& r, const Evidence* ev = nullptr) {
    std::ostringstream o;
    o << "RLPlayer 诊断报告（rtadiag · bundle schema " << kBundleSchema << "）\n";
    o << "=================================================\n";
    o << "案例 ID : " << (r.case_id.empty() ? "（无：包内没有 case_id）" : r.case_id) << "\n";
    if (ev) {
        o << "数据来源: " << ev->source_desc << "\n";
        if (!ev->app_version.empty()) o << "应用版本: " << ev->app_version << "\n";
        if (!ev->os.empty()) o << "运行环境: " << ev->os;
        if (!ev->arch.empty()) o << " / " << ev->arch;
        if (!ev->cpu.empty()) o << " / " << ev->cpu;
        if (!ev->os.empty() || !ev->arch.empty() || !ev->cpu.empty()) o << "\n";
        if (!ev->created_utc.empty()) o << "导出时间: " << ev->created_utc << "（UTC）\n";
        if (!ev->scenario.empty()) o << "场景标记: " << ev->scenario << "\n";
    }
    o << "包完整性: " << (r.verify_ok ? "通过（manifest + checksums 与字节一致）"
                                      : "**未通过**（详见下方缺失清单）") << "\n";
    if (r.simulated)
        o << "数据性质: ⚠ 模拟/夹具证据（simulated=true）—— 这不是真实运行诊断，"
             "只能用于验证工具行为\n";
    else
        o << "数据性质: 真实运行证据\n";
    o << "\n";

    // ---- 结论 ----
    switch (r.verdict) {
        case Verdict::Known:     o << "结论（唯一）: " << r.conclusion.title << "\n"; break;
        case Verdict::Ambiguous: o << "结论（并列，无法唯一）: " << r.conclusion.title << "\n"; break;
        case Verdict::Unknown:   o << "结论（无）: " << r.conclusion.title << "\n"; break;
    }
    if (r.verdict == Verdict::Known) {
        o << "结论代码: " << r.conclusion.id << "\n";
        char buf[32];
        std::snprintf(buf, sizeof buf, "%.2f", r.conclusion.confidence);
        o << "置信度  : " << buf << "（依据条目数 " << r.conclusion.evidence.size()
          << "；越低表示关键子证据越缺）\n";
    }
    if (!r.conclusion.detail.empty()) o << "判定依据: " << r.conclusion.detail << "\n";
    if (!r.conclusion.evidence.empty()) {
        o << "证据:\n";
        for (const auto& e : r.conclusion.evidence) o << "  - " << e << "\n";
    }
    if (!r.conclusion.alternatives.empty()) {
        o << "其它候选:\n";
        for (const auto& a : r.conclusion.alternatives) o << "  - " << a << "\n";
    }
    o << "\n";

    // ---- 缺失清单（= 10 问缺失报告）----
    o << "缺失与限制（证据不足就在这里，不做推测）：\n";
    if (r.missing.empty()) {
        o << "  （无：包内证据足以回答全部十问）\n";
    } else {
        for (const auto& m : r.missing) o << "  - " << m << "\n";
    }
    if (!r.warnings.empty()) {
        o << "提醒:\n";
        for (const auto& w : r.warnings) o << "  ! " << w << "\n";
    }
    o << "\n";

    // ---- 十问 ----
    o << "十问清单（known=能回答 / partial=只能答一部分 / missing=缺证据）\n";
    for (const auto& q : r.questions) {
        const char* tag = q.status == QStatus::Known ? "known  "
                        : q.status == QStatus::Partial ? "partial" : "missing";
        o << "  Q" << q.q << " [" << tag << "] " << q.title << "\n";
        if (!q.detail.empty()) o << "        " << q.detail << "\n";
        for (const auto& s : q.sources) o << "        来源: " << s << "\n";
    }
    o << "\n";
    o << "本报告由 rtadiag 依据包内字节生成；只写证据支持的内容，"
         "证据不足处已在「缺失与限制」中标明，不做原因猜测。\n";
    return o.str();
}

// 便捷：给 rtaweb 打包用（回调里只有最终条目 + spec）
inline std::string render_report_text_for_bundle(const std::vector<MaterializedEntry>& ents,
                                                 const BundleSpec& spec,
                                                 const CodeLookup& lookup = nullptr) {
    const Evidence ev = evidence_from_entries(ents, spec);
    Report r = analyze(ev, lookup);
    return render_report_text(r, &ev);
}

inline std::string render_for_evidence(const Evidence& ev, const CodeLookup& lookup = nullptr) {
    Report r = analyze(ev, lookup);
    return render_report_text(r, &ev);
}

// ================================ JSON ======================================
inline std::string Report::to_json() const {
    std::ostringstream o;
    o << "{";
    o << "\"tool\":\"rtadiag\"";
    o << ",\"report_schema\":\"rlplayer.diag.report/1\"";
    o << ",\"bundle_schema\":\"" << kBundleSchema << "\"";
    o << ",\"case_id\":\"" << json_escape(case_id) << "\"";
    o << ",\"verdict\":\"" << verdict_name(verdict) << "\"";
    o << ",\"simulated\":" << (simulated ? "true" : "false");
    o << ",\"as_real_diagnosis\":" << ((!simulated && verify_ok && verdict == Verdict::Known) ? "true" : "false");
    o << ",\"verify\":{\"ok\":" << (verify_ok ? "true" : "false") << "}";

    o << ",\"conclusion\":{";
    o << "\"id\":\"" << json_escape(conclusion.id) << "\"";
    o << ",\"title\":\"" << json_escape(conclusion.title) << "\"";
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.2f", conclusion.confidence);
    o << ",\"confidence\":" << buf;
    o << ",\"detail\":\"" << json_escape(conclusion.detail) << "\"";
    o << ",\"evidence\":[";
    for (std::size_t i = 0; i < conclusion.evidence.size(); ++i) {
        if (i) o << ",";
        o << "\"" << json_escape(conclusion.evidence[i]) << "\"";
    }
    o << "]";
    o << ",\"alternatives\":[";
    for (std::size_t i = 0; i < conclusion.alternatives.size(); ++i) {
        if (i) o << ",";
        o << "\"" << json_escape(conclusion.alternatives[i]) << "\"";
    }
    o << "]}";

    o << ",\"missing\":[";
    for (std::size_t i = 0; i < missing.size(); ++i) {
        if (i) o << ",";
        o << "\"" << json_escape(missing[i]) << "\"";
    }
    o << "]";
    o << ",\"warnings\":[";
    for (std::size_t i = 0; i < warnings.size(); ++i) {
        if (i) o << ",";
        o << "\"" << json_escape(warnings[i]) << "\"";
    }
    o << "]";
    o << ",\"questions\":[";
    for (std::size_t i = 0; i < questions.size(); ++i) {
        const auto& q = questions[i];
        if (i) o << ",";
        o << "{\"q\":" << q.q << ",\"title\":\"" << json_escape(q.title) << "\""
          << ",\"status\":\"" << qstatus_name(q.status) << "\""
          << ",\"detail\":\"" << json_escape(q.detail) << "\""
          << ",\"sources\":[";
        for (std::size_t j = 0; j < q.sources.size(); ++j) {
            if (j) o << ",";
            o << "\"" << json_escape(q.sources[j]) << "\"";
        }
        o << "]}";
    }
    o << "]";
    o << "}";
    return o.str();
}

// ================================ 退出码 ====================================
// 0 = 唯一明确结论；1 = 证据不足/冲突；2 = 包不可信（校验失败/旧包）。
// 与 rtadiag 的 --expect / --require-real 组合规则见 tools/rtadiag.cpp。
inline int report_exit_code(const Report& r) {
    if (!r.verify_ok) return 2;
    if (r.verdict == Verdict::Known) return 0;
    return 1;
}

}  // namespace rta::diag
