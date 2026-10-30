// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#include "analysis/quality.h"
#include <vector>
#include <cmath>
#include <cstdio>
int main(){
 int fails=0; auto ck=[&](bool v,const char* n){printf("%s %s\n",v?"PASS":"FAIL",n);fails+=!v;};
 auto measure_res=[](const std::vector<std::vector<double>>& x,double fs,rta::analysis::QualityAccumulator* accOut=nullptr){
   std::vector<const double*> p;for(auto& c:x)p.push_back(c.data());
   rta::analysis::QualityAccumulator acc;
   acc.begin(x[0].size(),(int)x.size(),fs);
   acc.add_planar(p.data(),x[0].size());
   if(accOut)*accOut=acc;
   return acc.finalize();
 };
 auto measure=[&](const std::vector<std::vector<double>>& x,double fs){
   return measure_res(x,fs,nullptr);
 };
 std::vector<std::vector<double>> alternating(1,std::vector<double>(4800));for(size_t i=0;i<4800;++i)alternating[0][i]=i%2?1:-1;
 auto a=measure(alternating,48000);ck(a.clippedRuns==0&&a.longestClipRun==1,"alternating full-scale samples are not a flat clipped run");
 std::vector<std::vector<double>> plateau(1,std::vector<double>(4800,1));auto p=measure(plateau,48000);ck(p.clippedRuns==1&&p.longestClipRun==4800,"EOF clipped run is counted");
 std::vector<std::vector<double>> anti(2,std::vector<double>(4800));for(size_t i=0;i<4800;++i){anti[0][i]=.1;anti[1][i]=-.1;}
 auto b=measure(anti,48000);ck(b.silencePct==0&&b.noiseFloorDbfs < -19.9&&b.noiseFloorDbfs > -20.1,"anti-phase stereo is not silence");
 auto low=measure(alternating,16000);ck(low.hfRatio10kDb<=-120,"Nyquist below 10k has no >10k energy");
 std::vector<std::vector<double>> shortMulti(6,std::vector<double>(32,.00001));auto c=measure(shortMulti,48000);ck(c.note.find("多声道")!=std::string::npos,"short note preserves multichannel applicability");
 std::vector<std::vector<double>> quiet(1,std::vector<double>(4800,1e-18));auto q=measure(quiet,48000);ck(std::abs(q.noiseFloorDbfs+360)<.1,"extremely quiet power not clamped to -300 dBFS");

 // 新增 2s 1kHz 反相对照同相测试
 const double fs2 = 48000.0;
 const size_t n2 = (size_t)fs2 * 2;
 std::vector<std::vector<double>> inPhase(2, std::vector<double>(n2)), antiPhase(2, std::vector<double>(n2));
 for(size_t i=0;i<n2;++i){
   double s = 0.1 * std::sin(2.0 * M_PI * 1000.0 * (double)i / fs2);
   inPhase[0][i] = s; inPhase[1][i] = s;
   antiPhase[0][i] = s; antiPhase[1][i] = -s;
 }
 // 空声道指针（add_planar 传 nullptr = 该声道不存在）必须让「有效声道数」跟着减：
 // 谱域按 nActCh 求平均，若错用了 channels_，静音谱会整体低 3.01 dB（判据失明）。
 {
   std::vector<const double*> pMono{ inPhase[0].data() };
   rta::analysis::QualityAccumulator aMono;
   aMono.begin(n2, 1, fs2);
   aMono.add_planar(pMono.data(), n2);
   auto rMono = aMono.finalize();
   std::vector<const double*> pNullCh{ inPhase[0].data(), nullptr };   // 声道 1 不存在
   rta::analysis::QualityAccumulator aNull;
   aNull.begin(n2, 2, fs2);
   aNull.add_planar(pNullCh.data(), n2);
   auto rNull = aNull.finalize();
   ck(std::abs(rNull.centroidHz - rMono.centroidHz) < 0.5, "null 声道不改变重心（平均只除有效声道）");
   ck(std::abs(rNull.spectralMinDbfs - rMono.spectralMinDbfs) < 0.01,
      "null 声道不让本底噪声低 3 dB（nActCh 而非 channels_）");
   ck(std::abs(rNull.rmsDbfs - rMono.rmsDbfs) < 0.01, "null 声道不改变 RMS 基准");
   rta::analysis::QualityAccumulator aTwo;
   auto rTwo = measure_res(inPhase, fs2, &aTwo);
   ck(aTwo.windowBytes() == 2 * aMono.windowBytes(), "windowBytes 按声道数计（内存报告不撒谎）");
   (void)rTwo;
 }

 rta::analysis::QualityAccumulator accIn, accAnti;
 auto resIn = measure_res(inPhase, fs2, &accIn);
 auto resAnti = measure_res(antiPhase, fs2, &accAnti);
 ck(std::abs(resAnti.centroidHz - 1000.0) < 5.0, "anti-phase 1kHz centroid is ~1000 Hz");
 ck(std::abs(resAnti.centroidHz - resIn.centroidHz) < 1.0, "anti-phase centroid matches in-phase");
 ck(std::abs(resAnti.spectralMinDbfs - resIn.spectralMinDbfs) < 0.1, "anti-phase spectral min matches in-phase");
 ck(std::abs(resAnti.noiseFloorDbfs - resIn.noiseFloorDbfs) < 0.1, "anti-phase noise floor matches in-phase");
 ck(std::abs(resAnti.channelCorr + 1.0) < 1e-6, "anti-phase channel correlation is -1.0");
 ck(resAnti.monoLossDb > 100.0, "anti-phase monoLoss is high");
 ck(!accAnti.envelope().empty(), "anti-phase envelope is non-empty");
 double envMax = 0.0;
 for(float v : accAnti.envelope()) if (v > envMax) envMax = v;
 ck(envMax > 0.05, "anti-phase envelope is non-zero (channelPower averaged)");

 // ============================================================================================
 // 生产红例（函数级复现）：tools/check_111_closeout_backend.py 的 16.4 / 16.4b / 16.3c
 // 真脚本证据 /private/tmp/rlp-closeout-final/results.json：
 //   16.4  纯音 −91.507 dB vs 「5 s 纯音 + 5 s −90 dB 尾」−0.011 dB（delta 91.496）
 //   16.4b 数字零尾对照 delta 0.000
 //   16.3c 同相 / 反相 side_mid_db 都是 −120（反相时 mid=0、side>0，按定义应为大正值）
 // 下面的夹具与脚本逐项对齐：44.1 kHz、16-bit 量化（i16(amp·sin)）、amp 0.5 的 997 Hz 纯音、
 // 尾段 = 同种子 LCG 的 ±1 LSB 白噪、10 s 长度（8 个谱窗，其中 4 窗落在尾段）。
 // ⚠️ 这是「判据本身的定义」测试：THD+N 只统计有效活动窗，side/mid 的哨兵按成分分开。
 // ============================================================================================
 const double fsF = 44100.0;
 auto i16q = [](double x, double amp) {                 // 与脚本 i16() 同口径（未除 32768 前的整数）
   const double v = amp * 32767.0 * x;
   long r = (long)std::llround(v);
   if (r < -32768) r = -32768;
   if (r > 32767) r = 32767;
   return (double)r / 32768.0;
 };
 const size_t nF = (size_t)(fsF * 10.0);
 auto lcgTail = [&](std::vector<double>& v, size_t from) {   // ±1 LSB 白噪（峰值/有效值 ≈ −90.3 dBFS）
   unsigned long long st = 20261030ull & 0x7FFFFFFFull;
   for (size_t i = from; i < v.size(); ++i) {
     st = (st * 1103515245ull + 12345ull) & 0x7FFFFFFFull;
     v[i] = (((st >> 16) & 1) ? 1.0 : -1.0) / 32768.0;
   }
 };
 auto toneFixture = [&](int tailMode) {   // 0 = 纯音；1 = ±1 LSB 尾；2 = 数字零尾
   std::vector<std::vector<double>> x(1, std::vector<double>(nF));
   for (size_t i = 0; i < nF; ++i) x[0][i] = i16q(std::sin(2.0 * M_PI * 997.0 * (double)i / fsF), 0.5);
   if (tailMode == 1) lcgTail(x[0], (size_t)(fsF * 5.0));
   if (tailMode == 2) for (size_t i = (size_t)(fsF * 5.0); i < nF; ++i) x[0][i] = 0.0;
   return x;
 };
 {
   auto pure = measure(toneFixture(0), fsF);
   auto t90 = measure(toneFixture(1), fsF);
   auto tsil = measure(toneFixture(2), fsF);
   ck(pure.spectralWindows == 8 && t90.spectralWindows == 8,
      "红例夹具与真脚本同一窗布局（8 窗、4 窗落在尾段）");
   ck(pure.thdnAvailable && pure.thdnDb < -85.0, "10 s 997 Hz 纯音 THD+N 仍 < −85 dB（判据没有放宽）");
   ck(t90.thdnDb < -85.0 && std::abs(t90.thdnDb - pure.thdnDb) < 1.0,
      "等长红例：纯音 vs 纯音 + 5 s −90 dB 尾，THD+N 差 <1 dB（原红 −91.507 vs −0.011）");
   ck(tsil.thdnDb < -85.0 && std::abs(tsil.thdnDb - pure.thdnDb) < 1.0,
      "对照：5 s 纯音 + 5 s 数字零尾，THD+N 差 <1 dB（两种尾必须给同一答案）");
   ck(std::abs(t90.nonTonalDb - pure.nonTonalDb) < 1.0,
      "非谐波残留同样只统计有效窗（±1 dB，原红 −0.01 dB）");
 }
 {
   // 极低电平边界：整段都在 −70 dBFS 绝对门以下 ⟹ 绝对门判掉全部窗，必须退回纯相对门，
   // 否则要么 THD+N 变成不可用（错），要么近静音窗重新污染中位数（原缺陷复现）。
   const double amp = 2e-4;                       // 峰值 −74 dBFS
   auto build = [&](bool withTail) {
     std::vector<std::vector<double>> x(1, std::vector<double>(nF));
     for (size_t i = 0; i < nF; ++i) x[0][i] = amp * std::sin(2.0 * M_PI * 997.0 * (double)i / fsF);
     if (withTail) for (size_t i = (size_t)(fsF * 5.0); i < nF; ++i) x[0][i] = (i & 1) ? 5e-8 : -5e-8;
     return x;
   };
   auto lo = measure(build(false), fsF);
   auto loT = measure(build(true), fsF);
   ck(lo.thdnAvailable && loT.thdnAvailable, "极低电平纯音仍报 THD+N（能量门不会把它变成不可用）");
   ck(std::abs(loT.thdnDb - lo.thdnDb) < 1.0, "极低电平素材的近静音尾同样被排除（差 <1 dB）");
 }
 {
   // 真全零：不能报 THD+N，也不能把 side/mid 报成 +120（那是「只有 side」的意思）
   std::vector<std::vector<double>> z(2, std::vector<double>(nF, 0.0));
   auto r = measure(z, fsF);
   ck(!r.thdnAvailable, "真全零素材不报 THD+N（不是给个 0 冒充）");
   ck(std::isfinite(r.thdnDb) && std::isfinite(r.nonTonalDb) && std::isfinite(r.noiseFloorDbfs)
      && std::isfinite(r.sideMidDb) && std::isfinite(r.monoLossDb), "全零素材的各指标都是有限值（无 NaN/inf）");
   ck(r.sideMidDb == -120.0, "全零立体声的 side/mid 不报 +120（两端都没有成分 ⟹ −120）");
 }
 {
   // 同相 / 反相 / 接近反相 / 正常比值：一个哨兵不能既表示「没有 side」又表示「没有 mid」
   const size_t mF = (size_t)(fsF * 2.0);
   auto stereoOf = [&](double k) {                // ch1 = k · ch0
     std::vector<std::vector<double>> x(2, std::vector<double>(mF));
     for (size_t i = 0; i < mF; ++i) {
       const double s = i16q(std::sin(2.0 * M_PI * 1000.0 * (double)i / fsF), 0.5);
       x[0][i] = s; x[1][i] = k * s;
     }
     return x;
   };
   auto ip = measure(stereoOf(1.0), fsF);
   auto ap = measure(stereoOf(-1.0), fsF);
   auto nearAp = measure(stereoOf(-0.98), fsF);
   auto mild = measure(stereoOf(0.9), fsF);
   ck(ip.sideMidDb <= -100.0, "同相 L==R：side/mid 落在下限（没有 side 分量）");
   ck(std::isfinite(ap.sideMidDb) && ap.sideMidDb >= 100.0,
      "反相 L==−R：side/mid 报 +120（mid=0 且 side>0，原红报 −120）");
   ck(std::abs(ap.channelCorr + 1.0) < 1e-6 && ap.monoLossDb >= 100.0,
      "反相：相关系数 −1、单声道损失仍为上限（旧判据不降）");
   ck(nearAp.sideMidDb > 10.0 && nearAp.sideMidDb < 60.0,
      "接近反相（ch1=−0.98·ch0）：side/mid 是有限正值，不是哨兵");
   ck(mild.sideMidDb < 0.0 && mild.sideMidDb > -60.0,
      "正常立体声（ch1=0.9·ch0）：side/mid 仍是普通负值（旧语义兼容）");
   ck(std::abs(ap.sideMidDb - ip.sideMidDb) > 1.0, "「没有 mid」与「没有 side」不再共用同一个 −120");
 }
 {
   // 分块一致性：新增的能量门只依赖窗内容，必须与块边界无关（整段 vs 任意分块逐位一致）
   auto whole = measure(toneFixture(1), fsF);
   bool same = true;
   for (size_t bs : { size_t(1000), size_t(65536), size_t(300001) }) {
     auto x = toneFixture(1);
     rta::analysis::QualityAccumulator acc;
     acc.begin(nF, 1, fsF);
     size_t pos = 0;
     while (pos < nF) {
       const size_t m = std::min(bs, nF - pos);
       const double* p[1] = { x[0].data() + pos };
       acc.add_planar(p, m);
       pos += m;
     }
     const auto c = acc.finalize();
     same = same && c.thdnDb == whole.thdnDb && c.nonTonalDb == whole.nonTonalDb
            && c.noiseFloorDbfs == whole.noiseFloorDbfs && c.spectralMinDbfs == whole.spectralMinDbfs;
   }
   ck(same, "分块 1000 / 65536 / 300001 与整段的 THD+N/残留/本底逐位一致（==）");
   // 立体声侧同样：分块喂入不得改变 side/mid 的哨兵语义
   const size_t mF = (size_t)(fsF * 2.0);
   std::vector<std::vector<double>> xap(2, std::vector<double>(mF));
   for (size_t i = 0; i < mF; ++i) {
     const double s = i16q(std::sin(2.0 * M_PI * 1000.0 * (double)i / fsF), 0.5);
     xap[0][i] = s; xap[1][i] = -s;
   }
   const auto wholeAp = measure(xap, fsF);
   rta::analysis::QualityAccumulator accAp;
   accAp.begin(mF, 2, fsF);
   for (size_t pos = 0; pos < mF; pos += 4096) {
     const size_t m = std::min<size_t>(4096, mF - pos);
     const double* c2[2] = { xap[0].data() + pos, xap[1].data() + pos };
     accAp.add_planar(c2, m);
   }
   const auto chunkAp = accAp.finalize();
   ck(chunkAp.sideMidDb == wholeAp.sideMidDb && chunkAp.channelCorr == wholeAp.channelCorr,
      "分块喂入的反相素材 side/mid 与相关系数逐位一致（哨兵不依赖块边界）");
 }

 return fails?1:0;
}
