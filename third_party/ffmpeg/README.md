# Bundled FFmpeg / FFprobe

The app includes standalone FFmpeg and FFprobe 8.1.2 executables. RLPlayer invokes them as subprocesses; its main executable does not link against libavcodec or other FFmpeg libraries.

- License: **LGPL-2.1-or-later**, see [COPYING.LGPLv2.1](COPYING.LGPLv2.1).
- Copyright: the FFmpeg developers; individual source files retain their respective notices.
- Source: <https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz>.
- Build recipe: [build_ffmpeg_lite_mac.sh](https://github.com/BH2VOQ/RLPlayer-Mac/blob/main/tools/build_ffmpeg_lite_mac.sh), using an unmodified FFmpeg release with selected audio features enabled and GPL/nonfree options disabled.
- The executables statically include LAME 3.100 (**LGPL-2.0-or-later**); its source/build instructions and license are in [the LAME source/build directory](https://github.com/BH2VOQ/RLPlayer-Mac/tree/main/third_party/lame-arm64).
- The app bundles these notices and license texts in `Contents/Resources/third_party/`.

To replace the bundled tools, build compatible arm64 executables from the cited sources, replace `Contents/MacOS/ffmpeg` and `ffprobe`, and re-sign your modified app with `codesign --force --deep --sign - RLPlayer.app`. No DRM or signature restriction in RLPlayer prevents use of modified builds.

## 中文

应用内置独立的 FFmpeg / FFprobe 8.1.2 可执行文件，主程序通过子进程调用，不链接 FFmpeg 库。它们适用 **LGPL-2.1-or-later**；静态包含的 LAME 3.100 适用 **LGPL-2.0-or-later**。对应源码、构建脚本和完整许可链接见上文，应用包内同样保留这些材料的获取方式。用户可自行构建、替换工具并重新签名修改后的应用。
