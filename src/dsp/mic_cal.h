// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// mic_cal.h — 测量麦克风校准曲线（U4 第一步：纯算法头，零框架依赖）
//
// 上游原文已取到：okhuoyanyan/RLPlayer2 v3.3.11 · src/dsp/mic_cal.h（云端 MCP 读取，未截断）。
// 本文件按其解析容忍度与插值语义移植，只保留第一步需要的三层：
//   上游 MicCalCurve / mic_cal_parse(text,name) / MicCalCurve::db_at
//     → 这里 MicCalTable / mic_cal_parse(text, out) / mic_cal_interp
//   上游 mic_cal_load(path) -> MicCalCurve
//     → 这里 mic_cal_load(path, &out) -> bool
//   上游频域补偿 mic_cal_apply_ir(ir, fs, cal)（依赖 fft.h / fp_strict.h）
//     → 本步骤只做标量 mic_cal_apply(table, hz, measuredDb)，频域补偿留给后续步骤
//
// 为什么补偿是「读数减校准」：房间校正测到的是「房间 + 话筒」的合成响应。话筒自身频响
// （典型 ±2~5 dB）不扣掉，就会被当成房间的峰谷写进校正 FIR —— 用户听到的是「把话筒的误差
// 反向加进房间」。补偿 = 读数 − 校准值（话筒在某频点更灵敏 ⟹ 读数偏高 ⟹ 减掉）。
// 负向对照由单测守住：无校准表时 mic_cal_apply 原样返回读数，绝不因为缺数据把响应改掉。
//
// 解析容忍的真实文件形态（每条都有单测）：
//   20.0 -1.23                空格/制表符两列
//   20.0,-1.23                逗号两列（CSV）
//   20.0, -1.23, 0.0          逗号三列：第三列相位**忽略**（校准只有幅度信息）
//   *1000.0 0.0               miniDSP 文件首行（灵敏度/注释行，整行跳过）
//   # ... / ; ... / // ...    注释行
//   "freq" "dB"               表头行（非数字 ⟹ 整行跳过，不算错误）
//   1.0e3 -1.23               科学计数法（strtod 直接吃，但 token 必须整段是数字：「12dB」不算）
//   \r\n 行尾、UTF-8 BOM      Windows 记事本存出来的文件
// 规则：按 hz 升序；hz<=0 或非有限值丢弃；同频**取文件中后者**；点数 < 3 判无效（同上游）。
//
// 插值语义（mic_cal_interp）：对数频率线性插值；范围外取端点值（**不外推成 0**，也不外推
// 斜率 —— 校准文件两端本来就没有可信数据，REW 的默认做法就是保持端点）。
//
// 分层（与 room_correction.h / room_measurement.h 同一约定）：本文件只做纯算法 —— 解析文本
// → 曲线 → 插值 → 标量补偿。不碰设备、不开线程、不 include src/audio/* 或 src/net/*；
// 唯一 IO 是 mic_cal_load() 读取一个 ≤4 MB 的文本文件。
#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

namespace rta::dsp {

// 校准文件大小上限（UMIK 文件典型 10~100 KB，4 MB 已是两个数量级的余量）
inline constexpr std::size_t kMicCalMaxBytes = 4u * 1024u * 1024u;

struct MicCalPoint {
    double hz = 0.0;
    double db = 0.0;
};

// 一份校准曲线。points 在解析成功后保证：按 hz 升序、hz>0、有限、无重复。
struct MicCalTable {
    std::vector<MicCalPoint> points;
    double minDb = 0.0, maxDb = 0.0;   // 幅度统计，供 UI 显示（如「−4.2 ~ +3.1 dB」）
    std::string source;                // 来源路径（mic_cal_load 填；mic_cal_parse 不填）
    std::string how;                   // 解析形态摘要（列数/分隔符），供日志与 UI 显示

    bool ok() const { return points.size() >= 3; }
    double min_hz() const { return points.empty() ? 0.0 : points.front().hz; }
    double max_hz() const { return points.empty() ? 0.0 : points.back().hz; }
};

// ---------------- 解析细节（纯函数，不碰文件） ----------------

namespace mic_cal_detail {

inline bool is_sep(char ch) {
    return ch == ' ' || ch == '\t' || ch == ',' || ch == ';' || ch == '\r';
}

// 一个 token 严格转 double：必须整 token 被吃掉（"1.0e3" 可以，"12dB" 不行），且必须有限。
inline bool to_double(const char* b, const char* e, double& out) {
    if (b == e) return false;
    const std::string tok(b, static_cast<std::size_t>(e - b));
    char* end = nullptr;
    const double v = std::strtod(tok.c_str(), &end);
    if (!end || end != tok.c_str() + tok.size()) return false;
    if (!std::isfinite(v)) return false;
    out = v;
    return true;
}

// 取一行里的前两个数值（第 3 列及以后一律忽略：相位、注释、额外列）。
// 任何 token 不是数字 ⟹ 整行不是数据行（表头 "freq" "dB" 走这里被跳过）。
inline bool parse_pair(const std::string& s, double& hz, double& db) {
    double v[2] = {0.0, 0.0};
    int nv = 0;
    std::size_t i = 0;
    while (i < s.size() && nv < 2) {
        while (i < s.size() && is_sep(s[i])) ++i;
        const std::size_t b = i;
        while (i < s.size() && !is_sep(s[i])) ++i;
        if (i == b) break;
        if (!to_double(s.data() + b, s.data() + i, v[nv])) return false;
        ++nv;
    }
    if (nv < 2) return false;
    hz = v[0];
    db = v[1];
    return true;
}

inline std::size_t count_tokens(const std::string& s) {
    std::size_t n = 0, i = 0;
    while (i < s.size()) {
        while (i < s.size() && is_sep(s[i])) ++i;
        if (i >= s.size()) break;
        ++n;
        while (i < s.size() && !is_sep(s[i])) ++i;
    }
    return n;
}

// 人话形态摘要：列数与分隔符（第三列起忽略）。
inline std::string describe_line(const std::string& s) {
    const std::size_t n = count_tokens(s);
    const bool comma = s.find(',') != std::string::npos;
    std::string r = (n >= 3 ? "3+ 列" : "2 列");
    r += comma ? "（逗号分隔" : "（空格/制表符分隔";
    if (n >= 3) r += "，第三列起忽略";
    r += "）";
    return r;
}

} // namespace mic_cal_detail

// text → 表。成功返回 true；失败返回 false 且 out 被清成空表（调用方拿到的「无表」永远安全）。
//
// 设计原则：先收集 raw，再排序/去重，全部检查通过才写 out —— 半成品绝不外泄，
// 否则一个坏文件可能让 mic_cal_apply 拿着两个残点去改读数。
inline bool mic_cal_parse(const std::string& text, MicCalTable& out) {
    out = MicCalTable{};
    if (text.empty()) return false;

    std::size_t pos = 0;
    if (text.size() >= 3 && static_cast<unsigned char>(text[0]) == 0xEF &&
        static_cast<unsigned char>(text[1]) == 0xBB &&
        static_cast<unsigned char>(text[2]) == 0xBF)
        pos = 3;   // UTF-8 BOM（Windows 记事本另存为 UTF-8 会带）

    std::vector<MicCalPoint> raw;
    std::string how;

    while (pos <= text.size()) {
        std::size_t eol = text.find('\n', pos);
        if (eol == std::string::npos) eol = text.size();
        std::string line = text.substr(pos, eol - pos);
        pos = eol + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();

        std::size_t b = 0, e = line.size();
        while (b < e && (line[b] == ' ' || line[b] == '\t')) ++b;
        while (e > b && (line[e - 1] == ' ' || line[e - 1] == '\t')) --e;
        if (b >= e) continue;                                    // 空行

        const char c0 = line[b];
        if (c0 == '#' || c0 == ';' || c0 == '*' || c0 == '/') continue;   // 注释（含 miniDSP 的 * 行）

        double hz = 0.0, db = 0.0;
        const std::string body = line.substr(b, e - b);
        if (!mic_cal_detail::parse_pair(body, hz, db)) continue;  // 表头 / 坏行：整行跳过
        if (!std::isfinite(hz) || !std::isfinite(db) || !(hz > 0.0)) continue;
        if (how.empty()) how = mic_cal_detail::describe_line(body);
        raw.push_back(MicCalPoint{hz, db});
    }

    // 升序 + 同频取后者：stable_sort 保留文件次序，等频段里**最后出现**的那条覆盖前面的。
    std::stable_sort(raw.begin(), raw.end(),
                     [](const MicCalPoint& a, const MicCalPoint& b) { return a.hz < b.hz; });
    std::vector<MicCalPoint> pts;
    for (const MicCalPoint& p : raw) {
        if (!pts.empty() && pts.back().hz == p.hz) pts.back() = p;
        else pts.push_back(p);
    }

    if (pts.size() < 3) return false;   // 少于 3 点判无效（同上游）

    out.points = std::move(pts);
    out.how = std::move(how);
    out.minDb = out.maxDb = out.points.front().db;
    for (const MicCalPoint& p : out.points) {
        out.minDb = std::min(out.minDb, p.db);
        out.maxDb = std::max(out.maxDb, p.db);
    }
    return true;
}

// 读文件 → 解析（唯一 IO；只读、有大小上限、失败后 out 保持空表）。
inline bool mic_cal_load(const std::string& path, MicCalTable& out) {
    out = MicCalTable{};
    if (path.empty()) return false;

    std::error_code ec;
    const std::filesystem::path p(path);
    const std::filesystem::file_status st = std::filesystem::status(p, ec);
    if (ec || !std::filesystem::is_regular_file(st)) return false;
    const std::uintmax_t sz = std::filesystem::file_size(p, ec);
    if (ec || sz == 0 || sz > kMicCalMaxBytes) return false;

    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    std::string text(static_cast<std::size_t>(sz), '\0');
    f.read(&text[0], static_cast<std::streamsize>(sz));
    text.resize(static_cast<std::size_t>(f.gcount() > 0 ? f.gcount() : 0));
    if (text.empty()) return false;

    if (!mic_cal_parse(text, out)) { out = MicCalTable{}; return false; }
    out.source = path;   // 只有成功才记来源（日志/UI 要显示「这个表从哪个文件来」）
    return true;
}

// 在 hz 处插值：对数频率线性插值；超出 [min_hz, max_hz] 取端点值，不外推成 0。
// 空表返回 0 dB（= 不补偿，绝不因为缺数据把整条响应改掉）。
inline double mic_cal_interp(const MicCalTable& t, double hz) {
    if (t.points.empty()) return 0.0;
    const MicCalPoint& first = t.points.front();
    const MicCalPoint& last = t.points.back();
    if (t.points.size() == 1) return first.db;
    if (!(hz > 0.0)) return first.db;    // hz<=0 / NaN ⟹ 按最低端处理
    if (hz <= first.hz) return first.db;
    if (hz >= last.hz) return last.db;   // 含 +Inf
    // 二分：找最后一个 hz_i <= hz 的下标（points 已升序）
    std::size_t lo = 0, hi = t.points.size() - 1;
    while (hi - lo > 1) {
        const std::size_t mid = lo + (hi - lo) / 2;
        if (t.points[mid].hz <= hz) lo = mid; else hi = mid;
    }
    const double a = t.points[lo].hz, b = t.points[hi].hz;
    if (!(b > a)) return t.points[hi].db;
    const double u = (std::log(hz) - std::log(a)) / (std::log(b) - std::log(a));
    return t.points[lo].db + (t.points[hi].db - t.points[lo].db) * u;
}

// 单点补偿：读数 − 校准值。**无表（points 为空）⟹ 原样返回读数**（负向对照）。
// 注意顺序：校准值在 dB 域是「话筒比理想更灵敏多少」，所以是减，不是加。
inline double mic_cal_apply(const MicCalTable& t, double hz, double measuredDb) {
    if (t.points.empty()) return measuredDb;
    return measuredDb - mic_cal_interp(t, hz);
}

} // namespace rta::dsp
