#!/bin/zsh
# build_ffmpeg_lite_mac.sh — macOS 精简静态 ffmpeg（对齐 Windows 的 build_ffmpeg_lite.ps1 思路）
#
# 为什么：播放器只需要【音频解码 + WAV 写出 + ffprobe 探测】。Homebrew ffmpeg 链
# 一大堆外部库（x265/x264/…），任何一环断裂就是 dyld 启动失败（2026-10-25 实测：
# x265 soname 216→217 断裂，退出码 134）。本脚本：
#   * --disable-autodetect：绝不探测/链接任何 Homebrew 库（自包含，复制即用）
#   * 只开音频解码器/音频容器 demuxer + wav muxer + file/pipe 协议
#   * 静态单文件 ffmpeg / ffprobe（arm64）
# 产物：build-mac/ffmpeg-lite/{ffmpeg,ffprobe}（make_app_mac.sh 优先收录这里）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-mac/ffmpeg-lite-build"
OUT="$ROOT/build-mac/ffmpeg-lite"
# 自建 arm64 静态 lame（见文件上方说明）。不存在时自动降级为「不含 MP3 编码」。
LAME_DIR="$ROOT/third_party/lame-arm64"
if [ -f "$LAME_DIR/lib/libmp3lame.a" ]; then
  # ⚠️ 不要把 flags 拼进变量再 $VAR 展开：shell 的 word-splitting 会把
  # `--extra-cflags=-I<path>` 当成两个参数，塞错位置（实测 configure 报
  # "syntax error near unexpected token"）。改为在 configure 行里直接写两个独立参数。
  LAME_ENABLE="--enable-libmp3lame"
  LAME_CFLAGS="-I$LAME_DIR/include"
  LAME_LDFLAGS="-L$LAME_DIR/lib"
  echo "== 使用自建 arm64 lame: $LAME_DIR =="
else
  LAME_ENABLE=""
  LAME_CFLAGS=""
  LAME_LDFLAGS=""
  echo "⚠ 未找到 $LAME_DIR/lib/libmp3lame.a ⟹ 本次构建不含 MP3 编码能力（播放不受影响）"
fi
VER="8.1.2"
SRC="$WORK/ffmpeg-$VER"

mkdir -p "$WORK" "$OUT"
cd "$WORK"
if [[ ! -d "$SRC" ]]; then
  curl -fsSL -o "ffmpeg-$VER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
  tar xf "ffmpeg-$VER.tar.xz"
fi
cd "$SRC"

# 音频解码器全家桶（内置实现，无外部库）+ 对应 parser/demuxer；pcm_* 全保
DECODERS="pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_u8,pcm_s8,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32be,pcm_alaw,pcm_mulaw,pcm_lxf,pcm_vidc,adpcm_g722,adpcm_ima_qt,adpcm_ima_wav,adpcm_ms,adpcm_yamaha,flac,alac,mp3float,mp3adufloat,mp3on4float,mp3,mp3adu,mp3on4,aac,aac_latm,vorbis,opus,wmapro,wmav2,wmav1,wmavoice,cook,atrac1,atrac3,atrac3al,atrac3plus,atrac3plusal,atrac9,dca,ac3,ac3_fixed,eac3,truehd,mlp,tak,ape,shorten,wavpack,tta,qdm2,qdm2_at?x,qdmc,imc,musepack7,musepack8,mpc8?x,amrnb,amrwb,ilbc,g723_1,g729,speex?x,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,dst,dolby_e,metasound?x,truespeech,codec2?x,comfortnoise,sbc,msnsiren,siren,ons2avc?x,paf_audio?x,westwood_aud1?x,ws_snd1,xan_dpcm,roq_dpcm,interplay_dpcm,sol_dpcm,_derl_dpcm?x,bergc?x"
# 清掉试探性的 ?x 项（写成保守清单）
DECODERS=$(echo "$DECODERS" | tr ',' '\n' | grep -v '?x$' | paste -sd, -)

DEMUXERS="wav,flac,mp3,ogg,mov,mp4,m4v,matroska,webm,ape,wv,tta,aac,ac3,dts,eac3,mlp,caf,aiff,au,amr,asf,avi,mpc,mpc8,dsf,iff,rawaudio,xwma,oma,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,smacker,bink,vividas?x"
DEMUXERS=$(echo "$DEMUXERS" | tr ',' '\n' | grep -v '?x$' | paste -sd, -)

PARSERS="flac,aac,ac3,dca,mpegaudio,opus,vorbis,xma,vorbis_alias?x"
PARSERS=$(echo "$PARSERS" | tr ',' '\n' | grep -v '?x$' | paste -sd, -)

# 2026-10-25：原配置只编了 wav 一个 muxer（纯解码用途），但「写回元数据」功能
# （src/meta/writeback.h）需要 **ffmpeg remux**：把音频流原样重新封装并写入新标签。
# 实测缺 muxer 时 ffmpeg 报 "Requested output format 'flac' is not known"（退出码 234），
# 导致 tests/test_writeback.cpp 全红。flac/alac/aac/vorbis/opus 编码器都是 ffmpeg
# 内置实现，零外部库依赖，体积增量很小。
# 这不是「新增功能」，是补齐写回能力本就需要的东西（铁律：功能不能删）。
# MP3 编码：FFmpeg 8.x 已**移除原生 mp3 编码器**，只剩 libmp3lame 一途。
#   本机 /usr/local 的 lame 4.0 是 **x86_64**（Rosetta Homebrew），arm64 原生构建链不上。
#   ⟹ 用自建的 arm64 静态 lame：third_party/lame-arm64/（LAME 3.100 源码编译，
#     --enable-static --disable-shared --host=aarch64-apple-darwin，423K）。
#     含 COPYING（LGPL-2.1）。构建方法见 third_party/lame-arm64/README.md。
echo "== configure（解码 + 元数据写回，零外部库）=="
./configure \
  --cc=clang --objcc=clang --disable-shared --enable-static \
  --disable-debug --disable-doc --disable-programs \
  --enable-ffmpeg --enable-ffprobe \
  --disable-autodetect --disable-network \
  --disable-everything \
  --enable-protocol=file,pipe \
  --enable-demuxer="$DEMUXERS" \
  --enable-decoder="$DECODERS" \
  --enable-parser="$PARSERS" \
  --enable-muxer=wav,flac,mp3,ipod,ogg,opus,matroska,aiff,caf \
  $LAME_ENABLE --extra-cflags="$LAME_CFLAGS" --extra-ldflags="$LAME_LDFLAGS" \
  --enable-encoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,flac,alac,aac,vorbis,opus${LAME_ENABLE:+\,libmp3lame} \
  --enable-bsf=pcm_rechunk,flac_picture,aac_adtstoasc \
  --enable-filter=aresample,anull,aformat \
  > configure.log 2>&1 || { tail -20 configure.log; exit 1; }

echo "== make（$(sysctl -n hw.ncpu) 并发）=="
make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -20 make.log; exit 1; }

cp ffmpeg ffprobe "$OUT/"
echo "✓ $OUT/ffmpeg $(du -h "$OUT/ffmpeg" | cut -f1) / ffprobe $(du -h "$OUT/ffprobe" | cut -f1)"
"$OUT/ffmpeg" -hide_banner -decoders 2>/dev/null | wc -l | awk '{print "  解码器条目:", $1}'
