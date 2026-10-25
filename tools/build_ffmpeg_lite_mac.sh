#!/bin/zsh
# build_ffmpeg_lite_mac.sh — macOS 精简静态 ffmpeg（对齐 Windows 的 build_ffmpeg_lite.ps1 思路）
#
# 为什么：播放器只需要【音频解码 + WAV 写出 + ffprobe 探测】。Homebrew ffmpeg 链
# 一大堆外部库（x265/x264/…），任何一环断裂就是 dyld 启动失败（2026-10-25 实测：
# x265 soname 216→217 断裂，退出码 134）。本脚本：
#   * --disable-autodetect：绝不探测/链接任何 Homebrew 库（自包含，复制即用）
#   * 只开音频解码器/音频容器 demuxer + wav muxer + file/pipe 协议
#   * 静态单文件 ffmpeg / ffprobe
# 产物：build-mac/ffmpeg-lite/{ffmpeg,ffprobe}（原生架构）
#       build-mac/ffmpeg-lite/{ffmpeg-x86_64,ffprobe-x86_64}（Intel 架构，可选）
#       运行时由 platform::find_executable 按本机架构挑原生那套（缺失则回退另一套）。
#       ⟹ 「优先 arm」策略：Apple Silicon 上永远跑 arm64 原生，Intel Mac 也能用。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build-mac/ffmpeg-lite-build"
OUT="$ROOT/build-mac/ffmpeg-lite"
VER="8.1.2"
SRC="$WORK/ffmpeg-$VER"

mkdir -p "$WORK" "$OUT"
# 源码包只需下载一次（放在 $WORK，两个架构共用同一个 .tar.xz）
if [ ! -f "$WORK/ffmpeg-$VER.tar.xz" ]; then
  echo "== 下载 ffmpeg $VER 源码 =="
  curl -fsSL -o "$WORK/ffmpeg-$VER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz" || {
    echo "✗ 下载失败。可手动放到 $WORK/ffmpeg-$VER.tar.xz"; exit 1; }
fi

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
# ---------------------------------------------------------------------------
# 构建单一架构的 ffmpeg/ffprobe
#   $1 = 架构名（arm64 / x86_64）
# ---------------------------------------------------------------------------
build_one_arch() {
  ARCH="$1"
  echo ""
  echo "===== 构建 $ARCH ====="

  # 每种架构用独立的工作目录（configure 会写 config.mak，混用会串味）
  WORK_ARCH="$WORK-$ARCH"
  rm -rf "$WORK_ARCH"
  mkdir -p "$WORK_ARCH"
  cd "$WORK_ARCH"
  if [ ! -d ffmpeg-8.1.2 ]; then
    # 源码包复用已有的（首次由旧脚本下载到 $WORK），也支持放在 third_party
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

  # x86_64 需要 nasm 编手写汇编；本机没装 nasm ⟹ 关掉 x86asm（纯 C 实现，
  # 解码速度略降但功能完全一致）。arm64 没有这个依赖，不需要该标志。
  if [ "$ARCH" = "x86_64" ]; then X86ASM_FLAG="--disable-x86asm"; else X86ASM_FLAG=""; fi

  # lame 按架构选（见上）
  LAME_ARCH_DIR="$ROOT/third_party/lame-${ARCH}"
  if [ -f "$LAME_ARCH_DIR/lib/libmp3lame.a" ]; then
    LAME_ENABLE="--enable-libmp3lame"
    LAME_CFLAGS="-I$LAME_ARCH_DIR/include"
    LAME_LDFLAGS="-L$LAME_ARCH_DIR/lib"
    echo "== 使用 $ARCH 静态 lame: $LAME_ARCH_DIR =="
  else
    LAME_ENABLE=""
    LAME_CFLAGS=""
    LAME_LDFLAGS=""
    echo "⚠ 未找到 $LAME_ARCH_DIR/lib/libmp3lame.a ⟹ $ARCH 版不含 MP3 编码（播放不受影响）"
  fi

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
    --arch="$ARCH" --target-os=darwin \
    $X86ASM_FLAG \
  $LAME_ENABLE --extra-cflags="$LAME_CFLAGS -arch $ARCH" --extra-ldflags="$LAME_LDFLAGS -arch $ARCH" \
    --enable-encoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,flac,alac,aac,vorbis,opus${LAME_ENABLE:+\,libmp3lame} \
    --enable-bsf=pcm_rechunk,flac_picture,aac_adtstoasc \
    --enable-filter=aresample,anull,aformat \
    > configure.log 2>&1 || { tail -20 configure.log; exit 1; }

  echo "== make（$(sysctl -n hw.ncpu) 并发）=="
  make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -20 make.log; exit 1; }

  local out_name="ffmpeg"
  local probe_name="ffprobe"
  if [ "$ARCH" = "x86_64" ]; then out_name="ffmpeg-x86_64"; probe_name="ffprobe-x86_64"; fi
  cp ffmpeg "$OUT/$out_name"
  cp ffprobe "$OUT/$probe_name"
  echo "✓ $OUT/$out_name $(du -h "$OUT/$out_name" | cut -f1) / $probe_name $(du -h "$OUT/$probe_name" | cut -f1)"
  "$OUT/$out_name" -hide_banner -decoders 2>/dev/null | wc -l | awk '{print "  解码器条目:", $1}'

}

# 主流程：arm64 优先（本机原生），再补 x86_64（Intel Mac 用）
mkdir -p "$OUT"
build_one_arch arm64 || { echo "✗ arm64 构建失败"; exit 1; }

# x86_64 是可选的：失败不阻断出包（Apple Silicon 用户不受影响）
if build_one_arch x86_64; then
  echo ""
  echo "✓ 双架构产物就绪："
  ls -lh "$OUT" | awk 'NR>1{print "   "$9" ("$5")"}'
else
  echo ""
  echo "⚠ x86_64 构建失败 ⟹ 只出 arm64 包（Apple Silicon 正常，Intel Mac 需 Rosetta 跑 arm64 版）"
fi
