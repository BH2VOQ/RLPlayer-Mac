// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// hp_real.h — double-double 高精度实数/复数算术（约 106 位二进制尾数）
//
// 为什么需要它（PLATFORM.md §13.5 / §13.11）：
//   NTF（噪声传递函数）设计的根/系数对精度敏感。x87 有 80 位 long double（64 位尾数）
//   够用；但两个现实平台都只有 53 位——macOS arm64 的 long double == double（Apple ABI
//   选择，实测 sizeof==8/LDBL_MANT_DIG==53），MSVC x64 的 long double 也是 double。
//   53 位下 1-bit 5 阶带内 SNR 从 >80 dB 掉到 51.6 dB。
//   Apple clang 无 __float128（实测报 "not supported on this target"），libc++ 无 <stdfloat>；
//   NSDecimal 只有 +−×÷ 且是苹果专属（会造成两平台系数分歧）。
//   double-double 只用 double + std::fma，MSVC/clang/gcc 全平台可编译且【同一套代码
//   同一套答案】——比 x87 80 位更精确（106 > 64），也让 Windows/macOS 的 NTF 系数
//   首次逐位一致。
//
// 算法出处（经典，非原创）：
//   * two-sum：Knuth（TAOCP vol.2，误差项推导）
//   * two-product：Dekker 1971；FMA 版 err = fma(a,b,-a*b)（一次指令免 17 项拆分）
//   * renormalization / 除法三步法：Bailey QD 库的 double-double 运算规则
//   * 三角函数：Cody-Waite 辅元 + Taylor 级数（dd 域求和）
//
// 适用范围：离线设计期运算（每个 NTF 配置只算一次），不是逐样本路径——
// 每条 dd 运算约 10~20 条 double 指令，别往 process() 里塞。
// 精度声明：加减乘达到接近 106 位；除法/三角按 QD 惯例接近 106 位。
// 未实现：sqrt/exp/log（NTF 设计不需要；要加先补测试）。
#pragma once
#include <cmath>
#include <cstdint>

namespace rta::dsp::hp {

// ---------------------------------------------------------------------------
// double-double 实数
// ---------------------------------------------------------------------------
struct DD {
    double hi = 0.0;
    double lo = 0.0;
    DD() = default;
    DD(double x) : hi(x), lo(0.0) {}
    DD(double h, double l) : hi(h), lo(l) {}
    double to_double() const { return hi + lo; }
};

// Knuth two-sum：s = a+b 的双分量表示（含精确误差项）
inline DD two_sum(double a, double b) {
    const double s = a + b;
    const double bb = s - a;
    const double err = (a - (s - bb)) + (b - bb);
    return DD(s, err);
}

// 快速 two-sum：仅当 |a| >= |b| 时可用（renorm 路径保证）
inline DD quick_two_sum(double a, double b) {
    const double s = a + b;
    return DD(s, b - (s - a));
}

// Dekker two-product（FMA 版）：p = a*b 的双分量表示
inline DD two_prod(double a, double b) {
    const double p = a * b;
    const double err = std::fma(a, b, -p);
    return DD(p, err);
}

inline DD renorm(double hi, double lo) { return quick_two_sum(hi, lo); }

inline DD operator+(DD a, DD b) {
    DD s = two_sum(a.hi, b.hi);
    s.lo += a.lo + b.lo;
    return quick_two_sum(s.hi, s.lo);
}
inline DD operator-(DD a, DD b) {
    DD s = two_sum(a.hi, -b.hi);
    s.lo += a.lo - b.lo;
    return quick_two_sum(s.hi, s.lo);
}
inline DD operator-(DD a) { return DD(-a.hi, -a.lo); }
inline DD operator*(DD a, DD b) {
    DD p = two_prod(a.hi, b.hi);
    p.lo += a.hi * b.lo + a.lo * b.hi;
    return quick_two_sum(p.hi, p.lo);
}
// 三步长除（Bailey QD）：三次双精度试商把余数打干净
inline DD operator/(DD a, DD b) {
    const double q1 = a.hi / b.hi;
    DD r = a - b * DD(q1);
    const double q2 = r.hi / b.hi;
    r = r - b * DD(q2);
    const double q3 = r.hi / b.hi;
    DD q = quick_two_sum(q1, q2);
    return quick_two_sum(q.hi, q.lo + q3);
}
inline DD& operator+=(DD& a, DD b) { a = a + b; return a; }
inline DD& operator-=(DD& a, DD b) { a = a - b; return a; }
inline bool operator==(DD a, DD b) { return a.hi == b.hi && a.lo == b.lo; }
inline bool operator!=(DD a, DD b) { return !(a == b); }

// ---------------------------------------------------------------------------
// 三角函数（Cody-Waite 辅元 + Taylor）
// ---------------------------------------------------------------------------
// π 的 dd 表示（PI_HI/PI_LO 由 60 位十进制 π 正确舍入而来）
inline DD pi() { return DD(3.14159265358979312e+00, 1.22464679914735321e-16); }
// π/2 三段拆分：P1 低 33 位清零（20 位有效尾数）→ |k| < 2^33 时 k*P1 精确
inline double pi2_p1() { return 1.57079505920410156e+00; }
inline double pi2_p2() { return 1.26759079505673142e-06; }
inline double pi2_p3() { return -9.53161193398001103e-23; }

// sin/cos 的 dd Taylor。
// 递推：term_n = r^(2n)/(2n)!；cos 项 n 直接累加；
//       sin 项 m = term_m · r/(2m+1)（不是下一阶 cos 项——第一版就写错过，
//       加进去的是 r^(2n+2)/(2n+2)! = cos 的下一项，结果 sin 变成了 cos-1）
inline void sincos_dd(DD x, DD* s, DD* c) {
    // 辅元：x = k·(π/2) + r。设计场景 |x| < π（theta/wc），k ∈ {0,1,2}，
    // 但保留一般性（k 用双精度估计足够）
    const double k_est = std::floor(x.hi / 1.5707963267948966 + 0.5);
    const DD kd(k_est);
    DD r = x - kd * DD(pi2_p1());
    r = r - kd * DD(pi2_p2());
    r = r - kd * DD(pi2_p3());
    const int64_t k = (int64_t)k_est;

    DD ss = r;          // sin 第 0 项 r^1/1!
    DD cc(1.0);         // cos 第 0 项
    const DD r2 = r * r;
    DD term(1.0);       // r^(2n)/(2n)!
    for (int n = 0; n < 40; ++n) {
        // 推进：term_{n+1} = term_n · r²/((2n+1)(2n+2))
        term = term * r2 / DD((double)((2 * n + 1) * (2 * n + 2)));
        if (term.hi == 0.0) break;
        const DD sign((n & 1) ? 1.0 : -1.0);   // 第 n+1 项符号 = (-1)^(n+1)
        cc += sign * term;
        const DD t2 = term * r / DD((double)(2 * n + 3));
        ss += sign * t2;
        if (t2.hi == 0.0) break;
    }
    const int m = (int)(((k % 4) + 4) % 4);
    switch (m) {
        case 0: *s = ss; *c = cc; break;
        case 1: *s = cc; *c = -ss; break;
        case 2: *s = -ss; *c = -cc; break;
        default: *s = -cc; *c = ss; break;
    }
}

inline DD sin(DD x) { DD s, c; sincos_dd(x, &s, &c); return s; }
inline DD cos(DD x) { DD s, c; sincos_dd(x, &s, &c); return c; }
inline DD tan(DD x) { DD s, c; sincos_dd(x, &s, &c); return s / c; }

// ---------------------------------------------------------------------------
// double-double 复数（NTF 设计的极点多项式累加用）
// ---------------------------------------------------------------------------
struct CDD {
    DD re, im;
    CDD() = default;
    CDD(DD r, DD i) : re(r), im(i) {}
    CDD(double r, double i) : re(r), im(i) {}
};
inline CDD operator+(CDD a, CDD b) { return CDD(a.re + b.re, a.im + b.im); }
inline CDD operator-(CDD a, CDD b) { return CDD(a.re - b.re, a.im - b.im); }
inline CDD operator-(CDD a) { return CDD(-a.re, -a.im); }
inline CDD operator*(CDD a, CDD b) {
    return CDD(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re);
}
inline CDD& operator+=(CDD& a, CDD b) { a = a + b; return a; }
// 复数除法（Smith 算法思想的 dd 化：分母先算模方）
inline CDD operator/(CDD a, CDD b) {
    const DD den = b.re * b.re + b.im * b.im;
    return CDD((a.re * b.re + a.im * b.im) / den, (a.im * b.re - a.re * b.im) / den);
}
// 实数 / 复数（design 里的 Wc / p_lp）
inline CDD operator/(DD a, CDD b) { return CDD(a, DD(0.0)) / b; }
inline CDD operator*(DD a, CDD b) { return CDD(a * b.re, a * b.im); }

} // namespace rta::dsp::hp
