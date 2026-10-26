# third_party/lame-arm64 —— 自建 arm64 静态 libmp3lame

## 为什么有这个目录

FFmpeg 8.x **已移除原生 MP3 编码器**（`configure` 里只剩 `libmp3lame` 与 `libshine` 两个外部实现）。
而本机 `/usr/local` 的 Homebrew lame 4.0 是 **x86_64**（Rosetta 安装），
arm64 原生构建时链接会失败：

```
Undefined symbols for architecture arm64:
  "_lame_set_VBR_quality", referenced from: _check_lame_set_VBR_quality in test.o
ERROR: libmp3lame >= 3.98.3 not found
```

⟹ 从源码编一份 **arm64 静态库** 放进仓库，保证 `tools/build_ffmpeg_lite_mac.sh`
在任何 arm64 mac 上都能构建出带 MP3 编码能力的 ffmpeg。

**没有 MP3 编码能力的影响**：播放不受影响（解码器一直在），只影响「把元数据写回 MP3 文件」
这一条路径（写回 FLAC / M4A / OGG 等不受影响）。

## 内容

| 文件 | 说明 |
|---|---|
| `lib/libmp3lame.a` | arm64 静态库，423 KB |
| `include/lame/lame.h` | 公开头文件 |
| `COPYING` | LAME 的 GNU Library GPL v2 许可证原文（LGPL-2.0-or-later：`lame.h` 头写明「either version 2 … or any later version」） |

版本：**LAME 3.100**（LAME 官方最后一个正式发布版）
架构：`arm64`（`lipo -info` 确认 Non-fat）

## 怎么重新生成

```bash
cd /tmp && rm -rf lame-arm64 && mkdir lame-arm64 && cd lame-arm64

# 下载源码（SourceForge 在国内常超时，用 Debian 镜像更稳）
curl -sL -o lame.tar.gz https://deb.debian.org/debian/pool/main/l/lame/lame_3.100.orig.tar.gz
tar xzf lame.tar.gz && cd lame-3.100

./configure --prefix=/tmp/lame-arm64/install \
  --enable-static --disable-shared --disable-frontend --disable-gtktest \
  --host=aarch64-apple-darwin \
  CFLAGS="-O2 -arch arm64" LDFLAGS="-arch arm64"

make -j8 && make install

# 拷回仓库
cp /tmp/lame-arm64/install/lib/libmp3lame.a  <repo>/third_party/lame-arm64/lib/
cp /tmp/lame-arm64/install/include/lame/lame.h <repo>/third_party/lame-arm64/include/lame/
```

验证：

```bash
lipo -info third_party/lame-arm64/lib/libmp3lame.a
# 期望：Non-fat file: ... is architecture: arm64

nm third_party/lame-arm64/lib/libmp3lame.a | grep "T _lame_set_VBR_quality"
# 期望：有一行输出（ffmpeg 的 configure 会探测这个符号）
```

## 构建脚本怎么用它

`tools/build_ffmpeg_lite_mac.sh` 会：

1. 检查 `third_party/lame-arm64/lib/libmp3lame.a` 是否存在
2. 存在 ⟹ 加 `--enable-libmp3lame --extra-cflags=-I<dir>/include --extra-ldflags=-L<dir>/lib`，
   并在 `--enable-encoder` 列表里追加 `libmp3lame`
3. 不存在 ⟹ 打印警告并跳过，构建出「不含 MP3 编码」的 ffmpeg（**不会失败**）

⟹ 这个目录是可选的加速项：删掉它构建仍能成功，只是失去 MP3 写回能力。

## 许可

LAME 是 **LGPL-2.1**。本仓库以静态库形式链接进 ffmpeg 二进制，
分发时须遵守 LGPL 的相应条款（提供源码获取途径 / 允许替换该库）。
`COPYING` 已随目录一并保留。
