// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
#include "engine/pipeline.h"
#include <cmath>
#include <cstdio>
// Offline signal processing only: no sink, service, or audio device.
// Before the fix, configuring apodizing produces exactly the ordinary FIR output.
template<class C> static void set_apod(C& c, const rta::dsp::FilterPreset& p, bool on) {
    if constexpr (requires { c.apodizing; c.apodF1; c.apodF2; }) {
        c.apodizing=on; c.apodF1=p.apodF1; c.apodF2=p.apodF2;
    }
}
static double measure(double hz, bool apod) {
    auto p=rta::dsp::find_preset("apod-20k");
    rta::engine::PipelineConfig c;
    c.outRate=88200; c.gpuResample=false; c.twoStage=false;
    c.taps=p->taps; c.transition=p->transition; c.attenDb=p->attenDb;
    c.filterWindow=p->window; c.filterPhase=p->phase; set_apod(c,*p,apod);
    rta::audio::AudioBuffer in; in.rate=44100; in.channels=1; in.bits=32;
    in.raw.resize(22050);
    constexpr double pi=3.14159265358979323846;
    for(size_t n=0;n<in.raw.size();++n)
        in.raw[n]=(int32_t)std::llround(1000000.0*std::sin(2*pi*hz*n/in.rate));
    rta::engine::Pipeline pipe(c); auto out=pipe.process(in);
    double sum=0; size_t first=out.raw.size()/2;
    for(size_t n=first;n<out.raw.size();++n) { double v=out.raw[n]; sum+=v*v; }
    return std::sqrt(sum/(out.raw.size()-first));
}
int main() {
    double low=20*std::log10(measure(1000,true)/measure(1000,false));
    double high=20*std::log10(measure(19000,true)/measure(19000,false));
    // 19k is inside the preset roll-off (18.4k..21.8k), while 1k is below it.
    // The ideal raised-cosine amplitude at 19k is about -0.68 dB.
    bool ok=std::isfinite(low)&&std::isfinite(high)&&std::abs(low)<0.05&&high < -0.25;
    std::printf("apod vs ordinary: 1k=%f dB, 19k=%f dB: %s\n",low,high,ok?"PASS":"FAIL");
    return ok?0:1;
}
