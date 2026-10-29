// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// event.h — 1.1.1 D1：统一事件信封 ts/seq/sid/rid/evt/stage/code/kv
//
// ===========================================================================
// 契约
//
//   * 一行一条 JSON 对象（JSONL）。字段顺序固定：
//        {"ts":<ms>,"seq":<n>,"sid":"…","rid":"…","evt":"…","stage":"…","code":"…","kv":{…}}
//     固定顺序的理由：事件文件是给人看的（tail -f / grep 也能读），也是对外的诊断
//     格式；顺序稳定才能用肉眼比对两份包。解析侧不依赖顺序（按名字找键）。
//   * ts  = Unix epoch 毫秒（UTC 语义），本地时区只在展示层加。
//   * seq = 本会话内单调递增，从 1 开始；跨会话不连续（sid 变了就是新会话）。
//   * sid = 会话 id，由 EventLog 生成；rid = 请求 id，可为空串（不为空时同一次
//     用户动作的所有事件共享）。
//   * kv  = 有序键值对，值可以是字符串/数字/布尔（KvKind）。**不会**有嵌套对象：
//     嵌套会让诊断包的 grep/比对变难，也会给脱敏留缝。
//   * evt/stage/code 是受控短词，不放自由文本；自由文本只允许出现在 kv，且写盘前
//     由 redact_policy.h 统一脱敏 + 截断。
//
// 本文件只做「结构 + 序列化 + 解析」，不做 IO、不碰脱敏、不持锁 —— 便于单独测试。
// ===========================================================================
#pragma once

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>
#include <vector>

#include "diag/error_codes.h"

namespace rta::diag {

enum class KvKind : int { Str = 0, Num = 1, Bool = 2 };

struct Kv {
    std::string k;
    std::string v;
    KvKind kind = KvKind::Str;
};

struct Event {
    int64_t ts = 0;          // epoch ms
    uint64_t seq = 0;        // 会话内单调，从 1 开始
    std::string sid;         // 会话 id
    std::string rid;         // 请求 id（可空）
    std::string evt;         // 事件名，如 "play.start"
    std::string stage;       // 阶段名，见 stage_name()
    std::string code;        // 稳定错误码，见 error_codes.h（无错误时为空）
    std::vector<Kv> kv;

    // ---- 构造辅助（链式，便于一行写完）----
    Event& str(std::string k, std::string v) {
        kv.push_back({std::move(k), std::move(v), KvKind::Str});
        return *this;
    }
    Event& num(std::string k, int64_t v) {
        kv.push_back({std::move(k), std::to_string(v), KvKind::Num});
        return *this;
    }
    Event& numf(std::string k, double v) {
        char buf[32];
        if (!std::isfinite(v)) {
            // JSON 没有 NaN/Inf。写成字符串，别写坏整行 JSON（诊断包要能被任何解析器读）
            std::snprintf(buf, sizeof(buf), "%s", std::isnan(v) ? "nan" : (v > 0 ? "inf" : "-inf"));
            kv.push_back({std::move(k), buf, KvKind::Str});
        } else {
            std::snprintf(buf, sizeof(buf), "%.6g", v);
            kv.push_back({std::move(k), buf, KvKind::Num});
        }
        return *this;
    }
    Event& boolean(std::string k, bool v) {
        kv.push_back({std::move(k), v ? "true" : "false", KvKind::Bool});
        return *this;
    }
    Event& set_stage(Stage s) { stage = stage_name(s); return *this; }
    Event& set_code(const ErrorCode* c) {
        if (c) {
            code = c->code;
            stage = stage_name(c->stage);
        }
        return *this;
    }

    // 取 kv 值（不存在返回 nullptr）。用于测试与主控侧“确认写对了没有”。
    const std::string* get(std::string_view key) const {
        for (const auto& p : kv)
            if (p.k == key) return &p.v;
        return nullptr;
    }
};

inline int64_t now_epoch_ms() {
    using namespace std::chrono;
    return (int64_t)duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

namespace detail {

// UTF-8 合法性检查：非法字节一律替换成 '?'。
// 为什么必须做：JSONL 的判据是"每行可解析"，一个坏字节会让整条事件在读取侧
// 变成不可解析行（被跳过），等于现场证据消失；宁可丢一个字节，不能丢一条事件。
inline size_t utf8_seq_len(std::string_view s, size_t i) {
    const unsigned char c = (unsigned char)s[i];
    size_t need = 0;                 // 后续续字节个数
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) need = 1;
    else if ((c & 0xF0) == 0xE0) need = 2;
    else if ((c & 0xF8) == 0xF0) need = 3;
    else return 0;                   // 孤立续字节 / 非法前导字节
    if (i + need >= s.size()) return 0;                 // 被截断的序列
    for (size_t k = 1; k <= need; ++k)
        if (((unsigned char)s[i + k] & 0xC0) != 0x80) return 0;
    return need + 1;
}

inline void append_json_string(std::string& out, std::string_view in) {
    static const char* kHex = "0123456789abcdef";
    out.push_back('"');
    for (size_t i = 0; i < in.size();) {
        const unsigned char c = (unsigned char)in[i];
        if (c == '"') { out += "\\\""; ++i; continue; }
        if (c == '\\') { out += "\\\\"; ++i; continue; }
        if (c == '\n') { out += "\\n"; ++i; continue; }
        if (c == '\r') { out += "\\r"; ++i; continue; }
        if (c == '\t') { out += "\\t"; ++i; continue; }
        if (c == '\b') { out += "\\b"; ++i; continue; }
        if (c == '\f') { out += "\\f"; ++i; continue; }
        if (c < 0x20) {
            out += "\\u00";
            out.push_back(kHex[(c >> 4) & 0xF]);
            out.push_back(kHex[c & 0xF]);
            ++i;
            continue;
        }
        if (c < 0x80) { out.push_back((char)c); ++i; continue; }
        const size_t n = utf8_seq_len(in, i);
        if (n == 0) { out.push_back('?'); ++i; continue; }
        out.append(in.substr(i, n));
        i += n;
    }
    out.push_back('"');
}

// ---- 极简 JSON 解析（只覆盖本模块自己写出的形态 + 容忍未知键）----
struct Cursor {
    std::string_view s;
    size_t i = 0;
    std::string* err;

    void ws() {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) ++i;
    }
    bool eof() {
        ws();
        return i >= s.size();
    }
    bool fail(const char* m) {
        if (err && err->empty()) *err = m;
        return false;
    }
    bool lit(std::string_view t) {
        ws();
        if (s.size() - i < t.size() || s.substr(i, t.size()) != t) return false;
        i += t.size();
        return true;
    }
    bool eat(char c) {
        ws();
        if (i < s.size() && s[i] == c) { ++i; return true; }
        return false;
    }

    static int hexval(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    static void append_utf8(std::string& o, unsigned cp) {
        if (cp < 0x80) { o.push_back((char)cp); }
        else if (cp < 0x800) {
            o.push_back((char)(0xC0 | (cp >> 6)));
            o.push_back((char)(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            o.push_back((char)(0xE0 | (cp >> 12)));
            o.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            o.push_back((char)(0x80 | (cp & 0x3F)));
        } else {
            o.push_back((char)(0xF0 | (cp >> 18)));
            o.push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
            o.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            o.push_back((char)(0x80 | (cp & 0x3F)));
        }
    }

    bool parse_string(std::string* out) {
        ws();
        if (i >= s.size() || s[i] != '"') return fail("expected string");
        ++i;
        out->clear();
        while (i < s.size()) {
            const char c = s[i];
            if (c == '"') { ++i; return true; }
            if (c == '\\') {
                ++i;
                if (i >= s.size()) return fail("bad escape");
                const char e = s[i++];
                switch (e) {
                    case '"': out->push_back('"'); break;
                    case '\\': out->push_back('\\'); break;
                    case '/': out->push_back('/'); break;
                    case 'b': out->push_back('\b'); break;
                    case 'f': out->push_back('\f'); break;
                    case 'n': out->push_back('\n'); break;
                    case 'r': out->push_back('\r'); break;
                    case 't': out->push_back('\t'); break;
                    case 'u': {
                        if (i + 4 > s.size()) return fail("bad \\u");
                        unsigned cp = 0;
                        for (int k = 0; k < 4; ++k) {
                            const int h = hexval(s[i + k]);
                            if (h < 0) return fail("bad \\u hex");
                            cp = (cp << 4) | (unsigned)h;
                        }
                        i += 4;
                        if (cp >= 0xD800 && cp <= 0xDBFF && i + 6 <= s.size() && s[i] == '\\' &&
                            s[i + 1] == 'u') {
                            unsigned lo = 0;
                            bool ok = true;
                            for (int k = 0; k < 4; ++k) {
                                const int h = hexval(s[i + 2 + k]);
                                if (h < 0) { ok = false; break; }
                                lo = (lo << 4) | (unsigned)h;
                            }
                            if (ok && lo >= 0xDC00 && lo <= 0xDFFF) {
                                i += 6;
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            }
                        }
                        append_utf8(*out, cp);
                        break;
                    }
                    default: return fail("bad escape char");
                }
                continue;
            }
            if ((unsigned char)c < 0x20) return fail("raw control char in string");
            out->push_back(c);
            ++i;
        }
        return fail("unterminated string");
    }

    bool parse_number_text(std::string* out) {
        ws();
        const size_t b = i;
        while (i < s.size()) {
            const char c = s[i];
            if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E')
                ++i;
            else
                break;
        }
        if (i == b) return fail("expected number");
        *out = std::string(s.substr(b, i - b));
        return true;
    }

    // 跳过任意值（用于未知键，保证向前兼容：新字段不会让旧读取侧解析失败）
    bool skip_value(int depth = 0) {
        if (depth > 8) return fail("nesting too deep");
        ws();
        if (i >= s.size()) return fail("eof in value");
        if (s[i] == '"') {
            std::string tmp;
            return parse_string(&tmp);
        }
        if (s[i] == '{' || s[i] == '[') {
            const char close = s[i] == '{' ? '}' : ']';
            const char open = s[i];
            ++i;
            ws();
            if (i < s.size() && s[i] == close) { ++i; return true; }
            for (;;) {
                if (open == '{') {
                    std::string k;
                    if (!parse_string(&k)) return false;
                    ws();
                    if (i >= s.size() || s[i] != ':') return fail("expected :");
                    ++i;
                    if (!skip_value(depth + 1)) return false;
                } else {
                    if (!skip_value(depth + 1)) return false;
                }
                ws();
                if (i < s.size() && s[i] == ',') { ++i; continue; }
                if (i < s.size() && s[i] == close) { ++i; return true; }
                return fail("expected , or close");
            }
        }
        if (lit("true") || lit("false") || lit("null")) return true;
        std::string n;
        return parse_number_text(&n);
    }
};

}  // namespace detail

// 序列化：一行（不含换行符）。不含 nac 值做兜底，见 Event::numf。
inline std::string event_to_json(const Event& e) {
    std::string o;
    o.reserve(256 + e.kv.size() * 48);
    o += "{\"ts\":";
    o += std::to_string((long long)e.ts);
    o += ",\"seq\":";
    o += std::to_string((unsigned long long)e.seq);
    o += ",\"sid\":";
    detail::append_json_string(o, e.sid);
    o += ",\"rid\":";
    detail::append_json_string(o, e.rid);
    o += ",\"evt\":";
    detail::append_json_string(o, e.evt);
    o += ",\"stage\":";
    detail::append_json_string(o, e.stage);
    o += ",\"code\":";
    detail::append_json_string(o, e.code);
    o += ",\"kv\":{";
    for (size_t i = 0; i < e.kv.size(); ++i) {
        const Kv& p = e.kv[i];
        if (i) o.push_back(',');
        detail::append_json_string(o, p.k);
        o.push_back(':');
        if (p.kind == KvKind::Num || p.kind == KvKind::Bool) {
            o += p.v;   // 数字/布尔原样输出；值本身由 Event::num/boolean 保证合法
        } else {
            detail::append_json_string(o, p.v);
        }
    }
    o += "}}";
    return o;
}

// 解析一行。失败时 *err 写原因（供 recent() 统计跳过行）。
// 判据：必须是对象，且至少含 seq/evt —— 缺字段的行按不可解析处理，
// 不让半条事件冒充一条事件（否则"最近事件"会静默丢字段）。
inline bool event_from_json(std::string_view line, Event* out, std::string* err) {
    std::string local_err;
    std::string* e = err ? err : &local_err;
    e->clear();
    if (!out) return false;
    *out = Event{};

    detail::Cursor c{line, 0, e};
    c.ws();
    if (!c.eat('{')) return c.fail("expected object");
    bool sawSeq = false, sawEvt = false;
    c.ws();
    if (c.eat('}')) return c.fail("empty object");
    for (;;) {
        std::string key;
        if (!c.parse_string(&key)) return false;
        c.ws();
        if (c.i >= c.s.size() || c.s[c.i] != ':') return c.fail("expected :");
        ++c.i;
        c.ws();
        if (key == "ts" || key == "seq") {
            std::string n;
            if (!c.parse_number_text(&n)) return false;
            const long long v = std::atoll(n.c_str());
            if (key == "ts") out->ts = (int64_t)v;
            else { out->seq = (uint64_t)(v < 0 ? 0 : v); sawSeq = true; }
        } else if (key == "sid" || key == "rid" || key == "evt" || key == "stage" || key == "code") {
            std::string v;
            if (!c.parse_string(&v)) return false;
            if (key == "sid") out->sid = v;
            else if (key == "rid") out->rid = v;
            else if (key == "evt") { out->evt = v; sawEvt = true; }
            else if (key == "stage") out->stage = v;
            else out->code = v;
        } else if (key == "kv") {
            if (!c.eat('{')) return c.fail("kv must be object");
            if (!c.eat('}')) {
                for (;;) {
                    std::string k;
                    if (!c.parse_string(&k)) return false;
                    c.ws();
                    if (c.i >= c.s.size() || c.s[c.i] != ':') return c.fail("expected : in kv");
                    ++c.i;
                    c.ws();
                    Kv p;
                    p.k = k;
                    if (c.i < c.s.size() && c.s[c.i] == '"') {
                        if (!c.parse_string(&p.v)) return false;
                        p.kind = KvKind::Str;
                    } else if (c.lit("true")) {
                        p.v = "true";
                        p.kind = KvKind::Bool;
                    } else if (c.lit("false")) {
                        p.v = "false";
                        p.kind = KvKind::Bool;
                    } else if (c.lit("null")) {
                        p.v = "";
                        p.kind = KvKind::Str;
                    } else {
                        if (!c.parse_number_text(&p.v)) return false;
                        p.kind = KvKind::Num;
                    }
                    out->kv.push_back(std::move(p));
                    c.ws();
                    if (c.i < c.s.size() && c.s[c.i] == ',') { ++c.i; continue; }
                    if (c.i < c.s.size() && c.s[c.i] == '}') { ++c.i; break; }
                    return c.fail("expected , or } in kv");
                }
            }
        } else {
            if (!c.skip_value()) return false;
        }
        c.ws();
        if (c.i < c.s.size() && c.s[c.i] == ',') { ++c.i; continue; }
        if (c.i < c.s.size() && c.s[c.i] == '}') { ++c.i; break; }
        return c.fail("expected , or }");
    }
    c.ws();
    if (c.i != c.s.size()) return c.fail("trailing bytes");
    if (!sawSeq) return c.fail("missing seq");
    if (!sawEvt) return c.fail("missing evt");
    return true;
}

}  // namespace rta::diag
