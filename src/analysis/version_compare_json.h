// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分；完整条款见根目录 LICENSE。
#pragma once
#include "version_compare.h"
#include <cmath>
#include <iomanip>
#include <sstream>

namespace rta::analysis {
namespace compare_json_detail {
inline std::string quote(const std::string& value) {
    std::ostringstream out;
    out << '"';
    static const char hex[] = "0123456789abcdef";
    for (unsigned char c : value) {
        if (c == '"' || c == '\\') out << '\\' << static_cast<char>(c);
        else if (c < 0x20) out << "\\u00" << hex[c >> 4] << hex[c & 15];
        else out << static_cast<char>(c);
    }
    out << '"';
    return out.str();
}
inline std::string number(double value) {
    if (!std::isfinite(value)) return "null";
    std::ostringstream out;
    out << std::setprecision(12) << value;
    return out.str();
}
}

// Do not serialize nonfinite analysis values as invalid JSON NaN/Infinity.
inline std::string version_compare_json(const VersionCompare& vc) {
    using compare_json_detail::quote;
    using compare_json_detail::number;
    std::ostringstream out;
    out << "{\"ok\":" << (vc.ok ? "true" : "false")
        << ",\"error\":" << quote(vc.error)
        << ",\"sameTrack\":" << (vc.sameTrack ? "true" : "false")
        << ",\"sameTrackCorr\":" << number(vc.sameTrackCorr)
        << ",\"windowSec\":" << number(vc.windowSec)
        << ",\"explanation\":" << quote(vc.explanation)
        << ",\"versions\":[";
    for (size_t i=0; i<vc.versions.size(); ++i) {
        if (i) out << ',';
        const auto& v = vc.versions[i];
        size_t rank = 0;
        for (size_t k=0; k<vc.ranking.size(); ++k) if (vc.ranking[k] == i) rank = k+1;
        out << "{\"path\":" << quote(v.path) << ",\"label\":" << quote(v.label)
            << ",\"error\":" << quote(v.error) << ",\"fs\":" << v.fs
            << ",\"channels\":" << v.channels << ",\"bits\":" << v.bits
            << ",\"lagSec\":" << number(v.lagSec)
            << ",\"analyzed\":" << (v.analyzed ? "true" : "false")
            << ",\"score\":" << (i < vc.scores.size() ? number(vc.scores[i]) : "null")
            << ",\"rank\":" << rank << '}';
    }
    out << "],\"rows\":[";
    for (size_t i=0; i<vc.rows.size(); ++i) {
        if (i) out << ',';
        const auto& r = vc.rows[i];
        out << "{\"key\":" << quote(r.key) << ",\"label\":" << quote(r.label)
            << ",\"unit\":" << quote(r.unit)
            << ",\"comparable\":" << (r.comparable ? "true" : "false")
            << ",\"informational\":" << (r.informational ? "true" : "false")
            << ",\"why\":" << quote(r.why) << ",\"bestIndex\":" << r.bestIndex
            << ",\"values\":[";
        for (size_t j=0; j<r.values.size(); ++j) { if (j) out << ','; out << number(r.values[j]); }
        out << "]}";
    }
    out << "],\"ranking\":[";
    for (size_t i=0; i<vc.ranking.size(); ++i) { if (i) out << ','; out << vc.ranking[i]; }
    out << "]}";
    return out.str();
}
}
