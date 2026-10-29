// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#include "audio/audio_loader.h"
#include <filesystem>
#include <fstream>
#include <cmath>
#include <cstdio>
#include <unistd.h>
int main() {
    namespace fs = std::filesystem;
    using namespace rta::audio;
    const auto root = fs::temp_directory_path() / ("rlp-float-" + std::to_string(getpid()));
    fs::create_directories(root);
    const auto src = (root / "source.wav").string(), mp3 = (root / "peak.mp3").string();
    const auto ref = (root / "reference.wav").string();
    const auto ff = find_tool("ffmpeg");
    if (ff.empty() || !tool_runnable(ff)) { std::fprintf(stderr,"ffmpeg unavailable\n"); return 2; }
    // Deliberately >full scale offline only: encoder reconstruction can overshoot.
    std::ofstream f(src, std::ios::binary);
    auto u16=[&](unsigned n){char b[2]={(char)n,(char)(n>>8)};f.write(b,2);};
    auto u32=[&](unsigned n){char b[4]={(char)n,(char)(n>>8),(char)(n>>16),(char)(n>>24)};f.write(b,4);};
    constexpr unsigned n=44100;
    f.write("RIFF",4);u32(36+n*4);f.write("WAVEfmt ",8);u32(16);u16(3);u16(1);u32(44100);u32(44100*4);u16(4);u16(32);f.write("data",4);u32(n*4);
    for(unsigned i=0;i<n;++i){float x=(i%80<40?1.0f:-1.0f);f.write((char*)&x,4);} f.close();
    auto run=[&](const std::string& args){std::string out;return run_hidden(widen("\""+ff+"\" -v error -y "+args),&out);};
    if(run("-i \""+src+"\" -c:a libmp3lame -b:a 320k \""+mp3+"\"") || run("-i \""+mp3+"\" -c:a pcm_f32le \""+ref+"\""))return 2;
    const auto reference=read_wav(ref);
    double rp=0;for(size_t i=0;i<reference.frames();++i)rp=std::max(rp,std::abs(reference.sample(i,0)));
    bool ok=rp>1.01;
    for(bool stream:{false,true}){
        LoadNote note;
        const auto got=stream?read_via_ffmpeg_stream(mp3,&note):read_via_ffmpeg_file(mp3,&note);
        double peak=0,delta=0;for(size_t i=0;i<got.frames();++i)peak=std::max(peak,std::abs(got.sample(i,0)));
        if(got.frames()==reference.frames()) for(size_t i=0;i<got.frames();++i)delta=std::max(delta,std::abs(got.sample(i,0)-reference.sample(i,0))); else delta=1;
        const bool pass=got.isFloat && std::abs(peak-rp)<1e-7 && delta<1e-7;
        std::printf("%s float=%d reference_peak=%.9f got_peak=%.9f max_delta=%.9g %s\n",stream?"pipe":"file",got.isFloat,rp,peak,delta,pass?"PASS":"FAIL");
        ok=ok&&pass;
    }
    // Real FLAC truncation: ffmpeg may exit 0 while silently producing a partial track.
    const auto flac=(root/"full.flac").string(), shortFlac=(root/"short.flac").string();
    if(run("-i \""+src+"\" -c:a flac \""+flac+"\"")) return 2;
    { std::ifstream in(flac,std::ios::binary);std::string bytes((std::istreambuf_iterator<char>(in)),{});
      std::ofstream out(shortFlac,std::ios::binary);out.write(bytes.data(),bytes.size()/2); }
    for(bool stream:{false,true}) {
        bool rejected=false;
        try { (void)(stream?read_via_ffmpeg_stream(shortFlac):read_via_ffmpeg_file(shortFlac)); }
        catch(const DecodeFailure& e) { rejected=e.code=="decode.truncated_flac" && e.declared>e.decoded; }
        catch(const std::exception&) { rejected=true; } // malformed compressed data is also a valid rejection
        std::printf("%s truncated FLAC rejected=%d\n",stream?"pipe":"file",rejected);ok=ok&&rejected;
    }
    fs::remove_all(root);
    return ok?0:1;
}
