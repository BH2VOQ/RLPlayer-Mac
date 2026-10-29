// SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
// SPDX-License-Identifier: GPL-3.0-or-later
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
#pragma once
#include "diag/diag.h"
#include <fstream>
#include <cstdint>
#include <stdexcept>
#include <string>
namespace rta::audio {
class DecodeFailure : public std::runtime_error {
public:
    std::string code;
    uint64_t declared = 0, decoded = 0;
    DecodeFailure(std::string stableCode, std::string message, uint64_t expected=0, uint64_t got=0)
      :std::runtime_error(std::move(message)),code(std::move(stableCode)),declared(expected),decoded(got){}
};
// STREAMINFO encodes total interchannel frames in its low 36 bits. Zero means unknown.
// This is file-header evidence, not a duration rounded by ffprobe or a guessed error string.
inline uint64_t flac_declared_frames(const std::string& path) {
    std::ifstream f(path,std::ios::binary); unsigned char h[8];
    if(!f.read(reinterpret_cast<char*>(h),8)||std::string(reinterpret_cast<char*>(h),4)!="fLaC") return 0;
    for(unsigned blocks=0;blocks<128;++blocks){
        const unsigned len=(unsigned(h[5])<<16)|(unsigned(h[6])<<8)|h[7];
        if((h[4]&0x7f)==0){
            if(len!=34)return 0;unsigned char data[34];
            if(!f.read(reinterpret_cast<char*>(data),34))return 0;
            uint64_t bits=0;for(int i=10;i<18;++i)bits=(bits<<8)|data[i];
            return bits&0xfffffffffull;
        }
        if(h[4]&0x80)return 0;
        f.seekg(len,std::ios::cur);if(!f.read(reinterpret_cast<char*>(h+4),4))return 0;
    }
    return 0;
}
inline void validate_flac_decoded_frames(const std::string& path, uint64_t decoded) {
    const auto declared=flac_declared_frames(path);
    if(!declared || decoded>=declared)return;
    rta::diag::Event event;event.evt="decode.failed";
    event.set_code(rta::diag::find_code("decode.truncated_flac"));
    event.str("format","flac").str("path",path).num("frames_declared",declared).num("frames_read",decoded);
    rta::diag::diag_emit(event);
    throw DecodeFailure("decode.truncated_flac","FLAC 解码帧数少于 STREAMINFO 声明（"+
        std::to_string(decoded)+"/"+std::to_string(declared)+"），拒绝把不完整音频当作成功",declared,decoded);
}
} // namespace rta::audio
