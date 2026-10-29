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

 return fails?1:0;
}
