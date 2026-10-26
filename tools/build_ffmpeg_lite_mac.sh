#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August Hu <BH2VOQ@163.com>
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
# build_ffmpeg_lite_mac.sh — macOS 精简静态 ffmpeg（对齐 Windows 的 build_ffmpeg_lite.ps1 思路）
#
# 为什么：播放器只需要【音频解码 + WAV 写出 + ffprobe 探测 + 元数据写回】。Homebrew ffmpeg 链
# 一大堆外部库（x265/x264/…），任何一环断裂就是 dyld 启动失败（2026-10-25 实测：
# x265 soname 216→217 断裂，退出码 134）。本脚本：
#   * --disable-autodetect：绝不探测/链接任何 Homebrew 库（自包含，复制即用）
#   * 只开音频解码器/音频容器 demuxer + wav/flac/mp3/ipod/ogg 等 muxer + file/pipe 协议
#   * 静态单文件 ffmpeg / ffprobe（arm64 纯架构）
#   * MP3 编码基于自建 arm64 静态 lame: third_party/lame-arm64/lib/libmp3lame.a
# 产物：build-mac/ffmpeg-lite/{ffmpeg,ffprobe}（纯 arm64 原生架构）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-mac/ffmpeg-lite-build"
OUT="$ROOT/build-mac/ffmpeg-lite"
VER="8.1.2"
SRC="$WORK/ffmpeg-$VER"

mkdir -p "$WORK" "$OUT"
if [ ! -f "$WORK/ffmpeg-$VER.tar.xz" ]; then
  echo "== 下载 ffmpeg $VER 源码 =="
  curl -fsSL -o "$WORK/ffmpeg-$VER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz" || {
    echo "✗ 下载失败。可手动放到 $WORK/ffmpeg-$VER.tar.xz"; exit 1; }
fi

# 音频解码器全家桶（内置实现，无外部库）+ 对应 parser/demuxer；pcm_* 全保
DECODERS="pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_u8,pcm_s8,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32be,pcm_alaw,pcm_mulaw,pcm_lxf,pcm_vidc,adpcm_g722,adpcm_ima_qt,adpcm_ima_wav,adpcm_ms,adpcm_yamaha,flac,alac,mp3float,mp3adufloat,mp3on4float,mp3,mp3adu,mp3on4,aac,aac_latm,vorbis,opus,wmapro,wmav2,wmav1,wmavoice,cook,atrac1,atrac3,atrac3al,atrac3plus,atrac3plusal,atrac9,dca,ac3,ac3_fixed,eac3,truehd,mlp,tak,ape,shorten,wavpack,tta,als,speex,wmalossless,pcm_s32le_planar,mjpeg,png,mpc7,mpc8,atrac3p,qdm2,qdm2_at?x,qdmc,imc,musepack7,musepack8,mpc8?x,amrnb,amrwb,ilbc,g723_1,g729,speex?x,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,dst,dolby_e,metasound?x,truespeech,codec2?x,comfortnoise,sbc,msnsiren,siren,ons2avc?x,paf_audio?x,westwood_aud1?x,ws_snd1,xan_dpcm,roq_dpcm,interplay_dpcm,sol_dpcm,_derl_dpcm?x,bergc?x"
# 清掉试探性的 ?x 项（写成保守清单）
DECODERS=$(echo "$DECODERS" | tr ',' '\n' | grep -v '?x$' | paste -sd, -)

DEMUXERS="wav,flac,mp3,ogg,mov,mp4,m4v,matroska,webm,ape,wv,tta,aac,ac3,dts,eac3,mlp,caf,aiff,au,amr,asf,avi,mpc,mpc8,dsf,iff,rawaudio,xwma,oma,image2,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,smacker,bink,vividas?x"
DEMUXERS=$(echo "$DEMUXERS" | tr ',' '\n' | grep -v '?x$' | paste -sd, -)

PARSERS="flac,aac,ac3,dca,mpegaudio,opus,vorbis,xma,vorbis_alias?x"
PARSERS=$(echo "$PARSERS" | tr ',' '\n' | grep -v '?x$' | paste -sd, -)

# ---------------------------------------------------------------------------
# 构建 arm64 架构的 ffmpeg/ffprobe
# ---------------------------------------------------------------------------
build_arm64() {
  local ARCH="arm64"
  echo ""
  echo "===== 构建 $ARCH ====="

  WORK_ARCH="$WORK-$ARCH"
  rm -rf "$WORK_ARCH"
  mkdir -p "$WORK_ARCH"
  cd "$WORK_ARCH"
  if [ ! -d ffmpeg-8.1.2 ]; then
    SRC_TAR=""
    for cand in "$WORK/ffmpeg-8.1.2.tar.xz" "$ROOT/third_party/ffmpeg-8.1.2.tar.xz"; do
      [ -f "$cand" ] && { SRC_TAR="$cand"; break; }
    done
    if [ -z "$SRC_TAR" ]; then
      echo "✗ 找不到 ffmpeg-8.1.2.tar.xz（应放在 $WORK/ 或 third_party/）"; return 1
    fi
    tar xzf "$SRC_TAR" || { echo "✗ 解包失败: $SRC_TAR"; return 1; }
  fi
  cd ffmpeg-8.1.2

  # 铁律：正式发布版必须自包含，功能不能借精简之名删除。
  # FFmpeg 8.x 已移除原生 mp3 编码器，必须依赖 libmp3lame。
  # 必须存在 third_party/lame-arm64/lib/libmp3lame.a，缺失则直接报错退出。
  LAME_ARCH_DIR="$ROOT/third_party/lame-arm64"
  if [ ! -f "$LAME_ARCH_DIR/lib/libmp3lame.a" ]; then
    echo "✗ 致命错误：未找到 $LAME_ARCH_DIR/lib/libmp3lame.a"
    echo "  铁律要求正式发布版自包含且不得削减 MP3 编码能力，禁止静默缺失 libmp3lame。"
    return 1
  fi

  local LAME_ENABLE="--enable-libmp3lame"
  local LAME_CFLAGS="-I$LAME_ARCH_DIR/include"
  local LAME_LDFLAGS="-L$LAME_ARCH_DIR/lib"
  echo "== 使用 $ARCH 静态 lame: $LAME_ARCH_DIR =="

  # 写回能力必须与 src/meta/writeback.h 的 writeback_muxer 全覆盖：
  # wma→asf、WavPack→wv，不能因「精简」丢掉；image2 供封面原字节提取。
  echo "== configure（arm64 解码 + 元数据写回 + libmp3lame，零外部动态库）=="
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
    --enable-muxer=wav,flac,mp3,ipod,ogg,opus,matroska,aiff,caf,asf,wv,image2 \
    --arch="$ARCH" --target-os=darwin \
    --enable-zlib \
    $LAME_ENABLE --extra-cflags="$LAME_CFLAGS -arch $ARCH" --extra-ldflags="$LAME_LDFLAGS -arch $ARCH" \
    --enable-encoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,flac,alac,aac,vorbis,opus,libmp3lame \
    --enable-bsf=pcm_rechunk,flac_picture,aac_adtstoasc \
    --enable-filter=aresample,anull,aformat \
    > configure.log 2>&1 || { tail -20 configure.log; exit 1; }

  echo "== make（$(sysctl -n hw.ncpu) 并发）=="
  make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -20 make.log; exit 1; }

  cp ffmpeg "$OUT/ffmpeg"
  cp ffprobe "$OUT/ffprobe"
  # 清理双架构版本遗留的生成物；产品包和开发目录都不再保留 x86_64 工具。
  rm -f "$OUT/ffmpeg-x86_64" "$OUT/ffprobe-x86_64"
  echo "✓ $OUT/ffmpeg $(du -h "$OUT/ffmpeg" | cut -f1) / ffprobe $(du -h "$OUT/ffprobe" | cut -f1)"
  "$OUT/ffmpeg" -hide_banner -decoders 2>/dev/null | wc -l | awk '{print "  解码器条目:", $1}'
}

# 主流程：纯 arm64 构建
mkdir -p "$OUT"
build_arm64 || { echo "✗ arm64 构建失败"; exit 1; }

echo ""
echo "✓ arm64 产物就绪："
ls -lh "$OUT" | awk 'NR>1{print "   "$9" ("$5")"}'
