# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 BH2VOQ <https://github.com/BH2VOQ>
#
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
#
cmake_minimum_required(VERSION 3.20)

# ---------------- macOS 部署目标（2026-10-25 补） ----------------
# ⚠️ 必须在 project() **之前**设置：project() 会在 cache 里预先定义
# CMAKE_OSX_DEPLOYMENT_TARGET（空字符串），之后再 set(... CACHE ...) 会被忽略
# ——主控实测踩到过：放在 project() 后面写，configure 后 cache 里仍是空值，minos 还是 27.0。
#
# 为什么要设：之前完全没设 ⟹ 默认取**编译机**的系统版本。本机 macOS 27.0.1，
# 实测产物 `otool -l | grep minos` = **27.0**，而 Info.plist 里却写着 LSMinimumSystemVersion 13.0
# ⟹ 声明与事实不符：在 macOS 13~26 上双击会被 dyld 直接拒绝（built for newer macOS）。
# 只有自己一台机器时发现不了，一旦给别人用就是必炸。
# 13.0 的选择依据：实测用 -mmacosx-version-min=13.0 完整编译 rtaweb 零 error、零可用性告警，
# 产物 minos=13.0 且实跑正常（/api/lib/stats 返回 ok）。产品二进制（rtaweb / rlplayer_mac）
# 只用了 AppKit + WebKit + CoreAudio 的长期存在 API；Process Tap（CATapDescription，
# macOS 14.2+）只在测试工具 rtaloop 里用，不进 .app。
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "macOS 最低系统版本（必须与 Info.plist 的 LSMinimumSystemVersion 一致）")
endif()

# 单进程 / Apple Silicon 分发基线（2026-10-25 用户明确）：主程序、壳与工具均只出
# arm64，不做 Universal，也不在 Intel/Rosetta 上继续承诺支持。缓存里若残留旧架构
# 设置，configure 直接失败，防止无声地重新产出双架构包。
if(NOT APPLE)
  message(FATAL_ERROR "RLPlayer 当前只支持 macOS arm64")
endif()
if(DEFINED CMAKE_OSX_ARCHITECTURES AND NOT CMAKE_OSX_ARCHITECTURES STREQUAL "" AND
   NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
  message(FATAL_ERROR "只支持 CMAKE_OSX_ARCHITECTURES=arm64，当前='${CMAKE_OSX_ARCHITECTURES}'")
endif()
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "仅 Apple Silicon（无 x86_64 / Universal）" FORCE)

project(RLPlayer LANGUAGES CXX)


set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# ---------------- 编译选项（2026-10-25：已改为 macOS 单平台）----------------
# 原文件此处是 if(MSVC) / elseif(APPLE) / else() 三分支：
#   - MSVC 分支（/W4 /permissive- /Zc:__cplusplus /utf-8 /O2）随 Windows 平台删除；
#   - 最后的通用 else() 分支（-march=${RTA_ARCH}，x86 分发基线）一并删除——
#     RTA_ARCH 是 x86-64-v2 的 CPU 基线，arm64 macOS 上既无意义也会直接报错；
#   - 只保留 APPLE 分支，并拉平为无条件选项。
# macOS：分发基线是 Apple Silicon + Intel 通用二进制，按架构给基线（armv8 / x86-64-v2 各自成立）。
# ⚠️ -ffp-contract=off（PLATFORM.md §13.11，2026-10-24）：原 Windows 基线 x86-64-v2
#   无 FMA 指令（乘/加各自舍入），arm64 有 FMA 且 -ffast-math 会把 a*b+c 收缩成
#   fmadd（一次舍入）。1-bit SDM 环路对轨迹比特级敏感：实测一个收缩差异就足以
#   让 65536 样本中翻转 1 个 ±1，无窗相干 FFT 分析把它摊成全带 -60.7 dB 平地板，
#   SNR 从 86.5 掉到 51.6（test_modulator FAIL）。关闭收缩 = 保持既有的确定性算术基线。
#   需要 FMA 的热点以后用显式 std::fma（跨平台确定性）补回。
add_compile_options(-Wall -Wextra -Wno-unused-parameter)
add_compile_options(-O3 -ffast-math -fno-finite-math-only
                    -fhonor-nans -fhonor-infinities -fno-math-errno
                    -ffp-contract=off)
add_compile_options(-fno-strict-aliasing)
add_compile_options($<$<CONFIG:Release>:-DNDEBUG>)


# ---------------- 平台库清单 ----------------
# 2026-10-25：项目改为 macOS 单平台，原 if(WIN32) / elseif(APPLE) / else() 三分支拉平。
# 删除的 Windows 依赖：winhttp ws2_32 winmm avrt dbghelp iphlpapi ole32 uuid mmdevapi
# （这些库在 macOS 上不存在，留着只会让 configure 报错）；通用 else() 的 curl 兜底也删除。
# libcurl：http.h 的 macOS 实现（系统自带，零第三方依赖）
# CoreAudio/AudioToolbox/CoreFoundation：audio_out_coreaudio.h
# SystemConfiguration（2026-10-26）：http_posix.h 读系统代理用 SCDynamicStoreCopyProxies
#   —— libcurl 在 macOS 上不读系统代理，必须自己问；不加这个框架会 link error。
set(RL_PLATFORM_LIBS curl iconv
    "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreFoundation"
    "-framework SystemConfiguration")

# ---- 跨平台工具 ----
# 2026-10-25：已改为 macOS 单平台，故不再有「Windows 用 winhttp/ws2_32」这一半说明。
# macOS 用 libcurl + CoreAudio 等框架，清单见上方 RL_PLATFORM_LIBS。
add_executable(httptest tools/httptest.cpp)
target_include_directories(httptest PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(httptest PRIVATE ${RL_PLATFORM_LIBS})

# ---------------- DoP 校验工具 ----------------
# 注：原注释写的是「桌面启动器（Win32 GUI，双击即用）」，与 dopinfo 实际用途不符，
# 该 Win32 启动器是 tools/launcher.cpp（已随 Windows 平台删除），mac 壳为 tools/mac_host.mm。
add_executable(dopinfo tools/dopinfo.cpp)
target_include_directories(dopinfo PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(dopinfo PRIVATE ${RL_PLATFORM_LIBS})

# ---------------- 逐位比对工具 ----------------
add_executable(wavcmp tools/wavcmp.cpp)
target_include_directories(wavcmp PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(wavcmp PRIVATE ${RL_PLATFORM_LIBS})

# ---------------- 滤波器变体对比报告生成器（ROADMAP P2） ----------------
add_executable(filter_report tools/filter_report.cpp)
target_include_directories(filter_report PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(filter_report PRIVATE ${RL_PLATFORM_LIBS})

add_library(rtadsp INTERFACE)
target_include_directories(rtadsp INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/src)

# ---------------- macOS：单进程 App + 保留独立 CLI（PLATFORM.md §13.12）----------------
# 2026-10-25 用户立项：单进程合并（保留程序内多线程），只留 arm64。
#   * rlapp_core = rtaweb.cpp 的库构建形态（同一个 handle()，同一份播放/扫描/网络线程）；
#   * rlplayer_mac = NSWindow + WKWebView + 进程内 WKURLSchemeHandler，**不再 posix_spawn**；
#   * rtaweb = 原有独立 HTTP/浏览器 CLI，功能不删；只是不再被 .app 打包或启动。
# 只编译一份业务代码：rtaweb 目标直接编 rtaweb.cpp；App 目标链接 rlapp_core（其 TU
# 用 RLPLAYER_EMBEDDED_LIBRARY 屏蔽 main）。两个目标互不依赖，可并行构建。
# 2026-10-26 邮件反馈通道：版本号的唯一真相源是 src/version.h。
# 在 configure 期读一次 #define RLPLAYER_VERSION "x.y.z"，供 mac_feedback.mm 的
# 反馈主题使用（避免在那个 TU 里再抄一份版本字符串）。
if(APPLE)
  file(STRINGS "${CMAKE_SOURCE_DIR}/src/version.h" _rl_ver_line
       REGEX "^#define[ \t]+RLPLAYER_VERSION[ \t]+\"")
  if(_rl_ver_line)
    string(REGEX REPLACE "^#define[ \t]+RLPLAYER_VERSION[ \t]+\"([^\"]*)\".*$" "\\1"
           RLPLAYER_VERSION_FOR_APP "${_rl_ver_line}")
    message(STATUS "RLPlayer 版本（来自 src/version.h）：${RLPLAYER_VERSION_FOR_APP}")
  else()
    set(RLPLAYER_VERSION_FOR_APP "unknown")
    message(WARNING "无法从 src/version.h 读取 RLPLAYER_VERSION —— 反馈邮件主题会显示 unknown")
  endif()
endif()

if(APPLE)
  # 2026-10-25（系统混音回环）：Process Tap 是 ObjC++ 门控（CATapDescription /
  # AudioHardwareCreateProcessTap 只在 __OBJC__ 下可见），拆成薄包装给纯 C++ 的
  # audio_in_coreaudio.h 用。rlapp_core 通过 #include "rtaweb.cpp" 共享同一份业务代码，
  # 所以这个 .mm 必须进 rlapp_core 的源列表，否则 App 侧会缺符号。
  enable_language(OBJCXX)
  set(RL_LOOPBACK_SRC src/platform/macos/process_tap_bridge.mm)
  set_source_files_properties(${RL_LOOPBACK_SRC} PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  # 1.1.4-beta9：封面缩略图（ImageIO 下采样，~10-25 ms/张，进程内、不起子进程）。
  # App 与 CLI 共用同一份实现（rlapp_core 通过 #include rtaweb.cpp 共享业务代码）。
  set(RL_IMAGE_THUMB_SRC src/platform/macos/image_thumb.mm)
  set_source_files_properties(${RL_IMAGE_THUMB_SRC} PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  set(RL_IMAGE_FRAMEWORKS "-framework ImageIO" "-framework CoreGraphics" "-framework UniformTypeIdentifiers")

  add_library(rlapp_core STATIC tools/rlapp_core.cpp ${RL_LOOPBACK_SRC} ${RL_IMAGE_THUMB_SRC})
  target_include_directories(rlapp_core PUBLIC ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
  target_link_libraries(rlapp_core PUBLIC ${RL_PLATFORM_LIBS} "-framework Foundation" ${RL_IMAGE_FRAMEWORKS})

  add_executable(rtaweb tools/rtaweb.cpp ${RL_LOOPBACK_SRC} ${RL_IMAGE_THUMB_SRC})
  target_include_directories(rtaweb PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(rtaweb PRIVATE ${RL_PLATFORM_LIBS} "-framework Foundation" ${RL_IMAGE_FRAMEWORKS})

  # macOS 原生壳（§9 第 9 条 / §10 契约）：单进程内直连 |rlapp::dispatch|。
  # mac_host.mm 用 ARC 语义（WKURLSchemeTask/block 对象生命周期不能被 MRR 误释放）。
  # 实测未开 ARC 时在 startURLSchemeTask 的 objc_msgSend 崩 SIGSEGV，开 ARC 后同场景通过。
  # 2026-10-26 F-4 自动更新：原生执行层（下载/校验/挂载/替换 .app）单独一个 TU。
  # 只加进 rlplayer_mac，不进 rlapp_core / rtaweb（CLI 不需要装 .app，也不该有 AppKit 依赖）。
  # 必须开 ARC（与 mac_host.mm 同理：block 捕获的对象生命周期）。
  add_executable(rlplayer_mac tools/mac_host.mm tools/mac_update.mm)
  set_source_files_properties(tools/mac_host.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  set_source_files_properties(tools/mac_update.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  # 2026-10-26 邮件反馈通道：原生层（NSSharingService 打开系统邮件撰写窗口）。
  # 用 target_sources **追加**而不是改上面那行 add_executable（保持"CMakeLists 只新增行"）。
  # 只加进 rlplayer_mac（CLI 不需要，也不该有 AppKit 依赖），必须开 ARC（block/对象生命周期）。
  target_sources(rlplayer_mac PRIVATE tools/mac_feedback.mm)
  set_source_files_properties(tools/mac_feedback.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  # 只有 rlplayer_mac 真正链接更新引擎；test_mac_transport 复用 mac_host.mm 但不带引擎，
  # 靠这个宏走「unsupported」回退分支（否则会 undefined symbols）。
  target_compile_definitions(rlplayer_mac PRIVATE RL_WITH_UPDATE=1)
  # 邮件反馈：只有 rlplayer_mac 链接 mac_feedback.mm；test_mac_transport 复用 mac_host.mm
  # 但不带该 TU，靠这个宏走 "unsupported" 回退分支（与 RL_WITH_UPDATE 同一套路）。
  target_compile_definitions(rlplayer_mac PRIVATE RL_WITH_FEEDBACK=1)
  # 主题里的版本号必须来自唯一真相源 src/version.h —— 编译期传进去，
  # 免得 mac_feedback.mm 里再抄一份版本字符串（抄了迟早不同步）。
  target_compile_definitions(rlplayer_mac PRIVATE
    RLPLAYER_VERSION_STR="${RLPLAYER_VERSION_FOR_APP}")
  # 1.1.5.1：中国大陆更新通道用 Security.framework 做 PS256 验签
  target_link_libraries(rlplayer_mac PRIVATE rlapp_core "-framework AppKit" "-framework WebKit" "-framework Security")

  # ---------------- 2026-11-11：纯 AppKit 原生客户端（1.1.7.1 起，从零实现） ----------------
  # 与 web 版并行：rlplayer_mac 保持默认/回退；rlplayer_native 是新的原生客户端，
  # 主内容区**没有任何 WKWebView**（--selftest 会断言 webviews=0）。
  # 业务核心复用 rlapp_core（同一份 /api dispatch），UI 层不复制播放/曲库真相。
  add_executable(rlplayer_native
    tools/native_ui/main.mm
    tools/native_ui/RLPAppDelegate.mm
    tools/native_ui/RLPShortcuts.mm
    tools/native_ui/RLPEQGeometry.mm
    tools/native_ui/RLPMainWindowController.mm
    tools/native_ui/RLPSidebarViewController.mm
    tools/native_ui/RLPAlbumsViewController.mm
    tools/native_ui/RLPPlaybackBarView.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPPlaceholderViewController.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPAlbumDetailViewController.mm
    tools/native_ui/RLPArtistDetailViewController.mm
    tools/native_ui/RLPArtistsViewController.mm
    tools/native_ui/RLPTracksViewController.mm
    tools/native_ui/RLPFoldersViewController.mm
    tools/native_ui/RLPQueueViewController.mm
    tools/native_ui/RLPRecentViewController.mm
    tools/native_ui/RLPFavoritesViewController.mm
    tools/native_ui/RLPSettingsViewController.mm
    tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPNowPlayingViewController.mm tools/native_ui/RLPWorksViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPUpdateWindowController.mm
    tools/native_ui/RLPStreamingViewController.mm
    tools/native_ui/RLPQuickStartViewController.mm
    tools/native_ui/RLPPlaylistsViewController.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPInputView.mm
    tools/native_ui/RLPCastView.mm
    tools/native_ui/RLPCalibrationView.mm
    tools/native_ui/RLPServersView.mm
    tools/native_ui/RLPMetaSourcesView.mm tools/native_ui/RLPLibStatsView.mm
    tools/native_ui/RLPRemoveDir.mm
    tools/native_ui/RLPFeedbackWindowController.mm
    tools/native_ui/RLPKnowledgeView.mm
    tools/native_ui/RLPFunctionalAudit.mm
    tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPLyrics.mm tools/native_ui/RLPRightDrawer.mm
    tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPListeningRoom.mm
    tools/native_ui/RLPTrackActions.mm
    tools/native_ui/RLPWorkbench.mm
    tools/native_ui/RLPWorkbenchViewController.mm tools/native_ui/RLPSignalChain.mm
    tools/native_ui/RLPTargetCurve.mm
    tools/mac_update.mm)
  set_source_files_properties(
    tools/mac_update.mm
    tools/native_ui/main.mm tools/native_ui/RLPAppDelegate.mm
    tools/native_ui/RLPMainWindowController.mm tools/native_ui/RLPSidebarViewController.mm
    tools/native_ui/RLPAlbumsViewController.mm tools/native_ui/RLPPlaybackBarView.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPPlaceholderViewController.mm tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPModels.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPAlbumDetailViewController.mm tools/native_ui/RLPArtistDetailViewController.mm
    tools/native_ui/RLPArtistsViewController.mm tools/native_ui/RLPTracksViewController.mm
    tools/native_ui/RLPFoldersViewController.mm tools/native_ui/RLPQueueViewController.mm
    tools/native_ui/RLPRecentViewController.mm tools/native_ui/RLPFavoritesViewController.mm
    tools/native_ui/RLPSettingsViewController.mm tools/native_ui/RLPNowPlayingViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPWorksViewController.mm
    tools/native_ui/RLPUpdateWindowController.mm
    tools/native_ui/RLPStreamingViewController.mm tools/native_ui/RLPQuickStartViewController.mm
    tools/native_ui/RLPPlaylistsViewController.mm tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPPlaylistsViewController.mm tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPInputView.mm tools/native_ui/RLPCastView.mm
    tools/native_ui/RLPLyrics.mm tools/native_ui/RLPRightDrawer.mm
    tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPCalibrationView.mm tools/native_ui/RLPServersView.mm
    tools/native_ui/RLPMetaSourcesView.mm tools/native_ui/RLPLibStatsView.mm
    tools/native_ui/RLPRemoveDir.mm
    tools/native_ui/RLPFeedbackWindowController.mm
    tools/native_ui/RLPKnowledgeView.mm tools/native_ui/RLPFunctionalAudit.mm
    tools/native_ui/RLPAnalysisSummary.mm tools/native_ui/RLPListeningRoom.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPWorkbench.mm
    tools/native_ui/RLPWorkbenchViewController.mm tools/native_ui/RLPSignalChain.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(rlplayer_native PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_compile_definitions(rlplayer_native PRIVATE
    RL_WITH_UPDATE=1
    RLPLAYER_VERSION_STR="${RLPLAYER_VERSION_FOR_APP}")
  # MediaPlayer：媒体键（MPRemoteCommandCenter）与锁屏正在播放信息。原生客户端的必备能力，
  # web 版做不到（页面 JS 拿不到系统媒体键）。
  target_link_libraries(rlplayer_native PRIVATE rlapp_core
    "-framework AppKit" "-framework Security" "-framework MediaPlayer"
    "-framework AVFoundation" "-framework CoreMedia")   # --audit 夹具读真实时长（索引 dur 不许自欺；CMTimeGetSeconds 在 CoreMedia）

  # Offline contracts for the frozen web album and mini bar.
  add_executable(test_native_album_web tests/test_native_album_web.mm
    tools/native_ui/RLPAlbumDetailViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPModels.mm tools/native_ui/RLPSupport.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm tools/native_ui/RLPTrackActions.mm
    tools/native_ui/RLPAnalysisSummary.mm tools/native_ui/RLPCoreClient.mm)
  # 全程序「每页只有一层滚动」（用户 2026-11-15 明确：不要大框架套小框架）。
  # 判据遍历左导航全部 key，统计每页"真的能滚"的容器数量，必须恰好 1（页面根那根）。
  add_executable(test_native_single_scroll tests/test_native_single_scroll.mm
    tools/native_ui/RLPShortcuts.mm
    tools/native_ui/RLPMainWindowController.mm tools/native_ui/RLPSidebarViewController.mm
    tools/native_ui/RLPAlbumsViewController.mm tools/native_ui/RLPAlbumDetailViewController.mm
    tools/native_ui/RLPArtistDetailViewController.mm tools/native_ui/RLPArtistsViewController.mm
    tools/native_ui/RLPTracksViewController.mm tools/native_ui/RLPQueueViewController.mm
    tools/native_ui/RLPPlaylistsViewController.mm tools/native_ui/RLPFoldersViewController.mm
    tools/native_ui/RLPRecentViewController.mm tools/native_ui/RLPFavoritesViewController.mm
    tools/native_ui/RLPStreamingViewController.mm tools/native_ui/RLPQuickStartViewController.mm
    tools/native_ui/RLPListeningRoom.mm
    tools/native_ui/RLPNowPlayingViewController.mm tools/native_ui/RLPWorksViewController.mm
    tools/native_ui/RLPSettingsViewController.mm tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPServersView.mm tools/native_ui/RLPMetaSourcesView.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPRemoveDir.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPInputView.mm tools/native_ui/RLPCastView.mm
    tools/native_ui/RLPCalibrationView.mm
    tools/native_ui/RLPUpdateWindowController.mm tools/mac_update.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPPlaceholderViewController.mm tools/native_ui/RLPRightDrawer.mm
    tools/native_ui/RLPPlaybackBarView.mm tools/native_ui/RLPVolumeKnobView.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPKnowledgeView.mm tools/native_ui/RLPLyrics.mm
    tools/native_ui/RLPAnalysisSummary.mm tools/native_ui/RLPSignalChain.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPCoreClient.mm)
  set_source_files_properties(tools/mac_update.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_compile_options(test_native_single_scroll PRIVATE -fobjc-arc)
  target_compile_definitions(test_native_single_scroll PRIVATE RL_WITH_UPDATE=1)
  target_include_directories(test_native_single_scroll PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_single_scroll PRIVATE rlapp_core
    "-framework AppKit" "-framework QuartzCore" "-framework WebKit" "-framework Security"
    "-framework MediaPlayer" "-framework AVFoundation" "-framework CoreMedia")
  add_test(NAME native_single_scroll COMMAND test_native_single_scroll)
  set_tests_properties(native_single_scroll PROPERTIES TIMEOUT 240)

  # EQ 页端到端（真 embedded 核心 / 真数据 / 真拖动）。上一轮那批"全绿"的单测与审计
  # 与产品共用同一套错误假设，于是"JSON 键读错 + bands 格式全错"两条真故障双双假绿。
  # 这条判据只认核心状态里的事实：哪一段的 gain 真的变了。
  add_executable(test_native_eq_contract tests/test_native_eq_contract.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPEQGeometry.mm
    tools/native_ui/RLPTargetCurve.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPModels.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm tools/native_ui/RLPTrackActions.mm
    tools/native_ui/RLPAnalysisSummary.mm tools/native_ui/RLPCoreClient.mm
    # E12 走设置页的真实刷新入口（reloadData），所以需要整套设置页。
    tools/native_ui/RLPSettingsViewController.mm tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPServersView.mm tools/native_ui/RLPMetaSourcesView.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPInputView.mm
    tools/native_ui/RLPCastView.mm tools/native_ui/RLPCalibrationView.mm
    tools/native_ui/RLPUpdateWindowController.mm tools/native_ui/RLPFeedbackWindowController.mm
    tools/native_ui/RLPPageViewController.mm tools/mac_update.mm)
  target_compile_options(test_native_eq_contract PRIVATE -fobjc-arc)
  target_include_directories(test_native_eq_contract PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_eq_contract PRIVATE rlapp_core
    "-framework AppKit" "-framework QuartzCore" "-framework Security")
  add_test(NAME native_eq_contract COMMAND test_native_eq_contract)
  set_tests_properties(native_eq_contract PROPERTIES TIMEOUT 180)

  add_executable(test_native_eq_geometry tests/test_native_eq_geometry.mm
    tools/native_ui/RLPEQGeometry.mm)
  target_compile_options(test_native_eq_geometry PRIVATE -fobjc-arc)
  target_include_directories(test_native_eq_geometry PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_eq_geometry PRIVATE "-framework AppKit" "-framework Foundation")
  add_test(NAME native_eq_geometry COMMAND test_native_eq_geometry)
  add_executable(test_native_shortcuts tests/test_native_shortcuts.mm
    tools/native_ui/RLPShortcuts.mm)
  target_compile_options(test_native_shortcuts PRIVATE -fobjc-arc)
  target_include_directories(test_native_shortcuts PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_shortcuts PRIVATE "-framework AppKit" "-framework Foundation")
  add_test(NAME native_shortcuts COMMAND test_native_shortcuts)
  add_executable(test_native_bar_web tests/test_native_bar_web.mm
    tools/native_ui/RLPPlaybackBarView.mm tools/native_ui/RLPSignalChain.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm  tools/native_ui/RLPVolumeKnobView.mm
)
  foreach(t IN ITEMS test_native_album_web test_native_bar_web)
    target_compile_options(${t} PRIVATE -fobjc-arc)
    target_include_directories(${t} PRIVATE src tools tools/native_ui)
    # QuartzCore：第14项的半透明判据要造两层渐变背景（CAGradientLayer）来证明
    # 「换背景后条内像素真的变化」，这是"真磨砂"唯一有意义的证明方式。
    target_link_libraries(${t} PRIVATE "-framework AppKit" "-framework QuartzCore")
  endforeach()
  target_link_libraries(test_native_album_web PRIVATE rlapp_core)
  add_test(NAME native_album_web COMMAND test_native_album_web)
  add_test(NAME native_bar_web COMMAND test_native_bar_web)

  # 底栏 × 真实 embedded 核心（第2项判据的快速版：秒级，不必等一轮 13 分钟的 --audit）。
  # 为什么单独建一个可执行文件：--audit 是整窗离屏审计，跑一轮十几分钟；
  # 而「播放中底栏图标是否切成暂停」是一个三段异步（轮询→回调→应用状态）的不变量，
  # 改一行判据就要重跑整窗是不可接受的反馈周期。这里只装底栏 + 核心。
  # 纪律：backend=null + volume=-120 —— 只跑 DSP，绝不打开设备（铁律②）。
  add_executable(test_native_bar_core tests/test_native_bar_core.mm
    tools/native_ui/RLPPlaybackBarView.mm tools/native_ui/RLPSignalChain.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPCoreClient.mm)
  target_compile_options(test_native_bar_core PRIVATE -fobjc-arc)
  target_include_directories(test_native_bar_core PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_bar_core PRIVATE rlapp_core
    "-framework AppKit" "-framework MediaPlayer")

  # 播放/暂停三入口请求契约（P0-1）：底栏 / 播放页 / 菜单·媒体键显式命令。
  # 桩核心只记录请求路径，不启动播放核心、不打开音频设备。
  # 对 1.1.7.32 先跑红：停止态只发 /api/pause?on=0（no-op）、媒体键沿用 isPlaying 快照。
  add_executable(test_native_pause_paths tests/test_native_pause_paths.mm
    tools/native_ui/RLPPlaybackBarView.mm tools/native_ui/RLPSignalChain.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPNowPlayingViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPKnowledgeView.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPLyrics.mm tools/native_ui/RLPTrackActions.mm)
  target_compile_options(test_native_pause_paths PRIVATE -fobjc-arc)
  target_include_directories(test_native_pause_paths PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_pause_paths PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_pause_paths COMMAND test_native_pause_paths)
  set_tests_properties(native_pause_paths PROPERTIES TIMEOUT 120)
  # 单层滚动 + EQ 曲线拖动（第6/7项）。**必须真实窗口响应链**：
  # 上一轮的 EQ 拖动判据只调 applyDragEvent:（等于只测换算函数），
  # 完全证明不了「真实鼠标事件能走到这个视图」——本轮换成 NSWindow sendEvent。
  add_executable(test_native_scroll_eq tests/test_native_scroll_eq.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPSupport.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPSupport.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPModels.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm tools/native_ui/RLPTrackActions.mm
    tools/native_ui/RLPAnalysisSummary.mm)
  target_compile_options(test_native_scroll_eq PRIVATE -fobjc-arc)
  target_include_directories(test_native_scroll_eq PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_scroll_eq PRIVATE
    "-framework AppKit" "-framework QuartzCore")
  add_test(NAME native_scroll_eq COMMAND test_native_scroll_eq)
  set_tests_properties(native_scroll_eq PROPERTIES TIMEOUT 120)

  # OPRA 卡片墙（P1）：型号卡片 + 预设卡片墙 + 目标曲线小图 + 当前态 + 应用请求。
  # 对 1.1.7.34 先跑红（旧码是型号下拉 + 预设下拉，没有卡片/曲线小图/当前态）。
  add_executable(test_native_opra_cards tests/test_native_opra_cards.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTargetCurve.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPAnalysisSummary.mm)
  target_compile_options(test_native_opra_cards PRIVATE -fobjc-arc)
  target_include_directories(test_native_opra_cards PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_opra_cards PRIVATE
    "-framework AppKit" "-framework QuartzCore")
  add_test(NAME native_opra_cards COMMAND test_native_opra_cards)

  add_executable(test_native_volume_knob tests/test_native_volume_knob.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPTheme.mm)
  target_compile_options(test_native_volume_knob PRIVATE -fobjc-arc)
  target_include_directories(test_native_volume_knob PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_volume_knob PRIVATE rlapp_core
    "-framework AppKit" "-framework QuartzCore" "-framework Security")
  add_test(NAME native_volume_knob COMMAND test_native_volume_knob)
  set_tests_properties(native_opra_cards PROPERTIES TIMEOUT 120)

  # 「AI 整理」栏三张卡片的几何判据（第5项）：离屏量真实视图树，不开窗、不出声。
  # 旧码没有 dot/name/status/p1/p2 子视图（NSButton 多行标题），先跑红再改绿。
  add_executable(test_native_rail_cards tests/test_native_rail_cards.mm
    tools/native_ui/RLPNowPlayingViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPKnowledgeView.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPLyrics.mm tools/native_ui/RLPTrackActions.mm)
  target_compile_options(test_native_rail_cards PRIVATE -fobjc-arc)
  target_include_directories(test_native_rail_cards PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_rail_cards PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_rail_cards COMMAND test_native_rail_cards)
  set_tests_properties(native_rail_cards PROPERTIES TIMEOUT 120)

  # 「AI 整理」栏内容级判据：三卡的 summary 预览/两档/点击实体类型/URL 形状。
  # 对旧码先跑红（旧码只显示本地事实 + 点开查看、点击 kind 恒为 track），改完再跑绿。
  add_executable(test_native_rail_preview tests/test_native_rail_preview.mm
    tools/native_ui/RLPNowPlayingViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPKnowledgeView.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPLyrics.mm tools/native_ui/RLPTrackActions.mm)
  target_compile_options(test_native_rail_preview PRIVATE -fobjc-arc)
  target_include_directories(test_native_rail_preview PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_rail_preview PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_rail_preview COMMAND test_native_rail_preview)
  set_tests_properties(native_rail_preview PROPERTIES TIMEOUT 120)

  # 「正在播放 · 音频分析面板」web #npAnal 对齐判据：头部独立标题/右对齐状态/单一边框
  # 分段控件（C1 同源几何）+ L0 摘要卡（标题 10.5/摘要 11.5/内边距 7-9-8/多声道徽标
  # + 高度随内容生长）+ 展开档 L1/L2 仍保留三卡并在卡内长出 2 列指标网格（旧码是
  # 「隐藏三卡 + 一块纯文本 blob」）。对 1.1.7.24 先跑红，改完再跑绿。
  add_executable(test_native_analysis_panel tests/test_native_analysis_panel.mm
    tools/native_ui/RLPNowPlayingViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPKnowledgeView.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPLyrics.mm tools/native_ui/RLPTrackActions.mm)
  target_compile_options(test_native_analysis_panel PRIVATE -fobjc-arc)
  target_include_directories(test_native_analysis_panel PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_analysis_panel PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_analysis_panel COMMAND test_native_analysis_panel)
  set_tests_properties(native_analysis_panel PROPERTIES TIMEOUT 120)

  # 正在播放页 #npMeta 芯片行 = web `.npmline` + `.badge` + `.chip`：
  # 徽标逐值（9.5/600/kern.3/radius5/acc-weak/ok-bg）+ EQ/IR 芯片（settings.kv.eq/ir）
  # + 投放/加歌单同处一行 + flex-wrap（窄宽不重叠、行高增长、按钮行下移）。
  # 对 1.1.7.26 先跑红（旧码只有 4 个 11pt/radius10 徽标，整行受 meta.enriched 闸门，
  # EQ/IR/投放/加歌单根本不在这一行，也没有换行）。改完再跑绿。
  add_executable(test_native_npmeta_chips tests/test_native_npmeta_chips.mm
    tools/native_ui/RLPNowPlayingViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPKnowledgeView.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPLyrics.mm tools/native_ui/RLPTrackActions.mm)
  target_compile_options(test_native_npmeta_chips PRIVATE -fobjc-arc)
  target_include_directories(test_native_npmeta_chips PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_npmeta_chips PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_npmeta_chips COMMAND test_native_npmeta_chips)
  set_tests_properties(native_npmeta_chips PROPERTIES TIMEOUT 120)

  # 播放队列页排序 = web #qSort：8 档（默认/标题/艺术家/专辑/时长/年份/随机打乱/反转）、
  # queueItemLine 的 CUE 区间保真（path \t cs \t ce）、行播放入口 playPath(file,cs,ce)。
  # 对 1.1.7.27 先跑红（旧码只有 3 档、qorder 只发路径、播放不带区间）。改完再跑绿。
  add_executable(test_native_queue_sort tests/test_native_queue_sort.mm
    tools/native_ui/RLPQueueViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPAnalysisSummary.mm)
  target_compile_options(test_native_queue_sort PRIVATE -fobjc-arc)
  target_include_directories(test_native_queue_sort PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_queue_sort PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_queue_sort COMMAND test_native_queue_sort)
  set_tests_properties(native_queue_sort PROPERTIES TIMEOUT 120)

  # 播放队列页行布局 = web `.qrow`：4 列（序号/标题/文件夹/×）、行高 38、无列头、
  # 当前行 accent-weak + 标题 accent、× 仅行悬停可见、底部分隔线。对 1.1.7.28 先跑红。
  add_executable(test_native_queue_rows tests/test_native_queue_rows.mm
    tools/native_ui/RLPQueueViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPAnalysisSummary.mm)
  target_compile_options(test_native_queue_rows PRIVATE -fobjc-arc)
  target_include_directories(test_native_queue_rows PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_queue_rows PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_queue_rows COMMAND test_native_queue_rows)
  set_tests_properties(native_queue_rows PROPERTIES TIMEOUT 120)

  # 专辑页 / 文件夹页空态 = web emptyStateHtml（非 classic）：0 张专辑时空态卡
  # （有/无 roots 两套文案 + 三个入口）与「此目录没有音频文件」。对 1.1.7.29 先跑红。
  add_executable(test_native_empty_states tests/test_native_empty_states.mm
    tools/native_ui/RLPAlbumsViewController.mm tools/native_ui/RLPFoldersViewController.mm
    tools/native_ui/RLPPageViewController.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPModels.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm tools/native_ui/RLPRemoveDir.mm)
  target_compile_options(test_native_empty_states PRIVATE -fobjc-arc)
  target_include_directories(test_native_empty_states PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_empty_states PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_empty_states COMMAND test_native_empty_states)
  set_tests_properties(native_empty_states PROPERTIES TIMEOUT 120)

  # AI 整理栏 nprailempty / npSummHint 状态：无实体时三卡不显示并出空态说明；
  # loading/insufficient/error（可重试）/ok 状态行。对 1.1.7.30 先跑红。
  add_executable(test_native_rail_states tests/test_native_rail_states.mm
    tools/native_ui/RLPNowPlayingViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPKnowledgeView.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPLyrics.mm tools/native_ui/RLPTrackActions.mm)
  target_compile_options(test_native_rail_states PRIVATE -fobjc-arc)
  target_include_directories(test_native_rail_states PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_rail_states PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_rail_states COMMAND test_native_rail_states)
  set_tests_properties(native_rail_states PROPERTIES TIMEOUT 120)

  # 投放芯片运行态 = web npCastBtnHtml：/api/cast/state running → 「已推送到 <device>」+ ok 三令牌，
  # 点击 = /api/cast/stop（不是弹设备列表）；否则「推送到设备」。对 1.1.7.31 先跑红。
  add_executable(test_native_cast_chip tests/test_native_cast_chip.mm
    tools/native_ui/RLPNowPlayingViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPKnowledgeView.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPLyrics.mm tools/native_ui/RLPTrackActions.mm)
  target_compile_options(test_native_cast_chip PRIVATE -fobjc-arc)
  target_include_directories(test_native_cast_chip PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_cast_chip PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_cast_chip COMMAND test_native_cast_chip)
  set_tests_properties(native_cast_chip PROPERTIES TIMEOUT 120)

  # 曲目页行几何/内容 = web `.trow-track`：7 列（无独立专辑列、有规格列）、响应式
  # 1.6/1.8/1:0.9、无列头、rowHeight 34、artist — album 单格。对 1.1.7.25 先跑红。
  add_executable(test_native_tracks_rows tests/test_native_tracks_rows.mm
    tools/native_ui/RLPTracksViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPAnalysisSummary.mm)
  target_compile_options(test_native_tracks_rows PRIVATE -fobjc-arc)
  target_include_directories(test_native_tracks_rows PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_tracks_rows PRIVATE
    "-framework AppKit" "-framework QuartzCore" "-framework CoreImage")
  add_test(NAME native_tracks_rows COMMAND test_native_tracks_rows)
  set_tests_properties(native_tracks_rows PROPERTIES TIMEOUT 120)

  # 第12项「标签写回」结构+几何判据：真设置页（隔离目录、backend=null）、离屏、不出声。
  add_executable(test_native_writeback_card tests/test_native_writeback_card.mm
    tools/native_ui/RLPSettingsViewController.mm tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPServersView.mm tools/native_ui/RLPMetaSourcesView.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPInputView.mm tools/native_ui/RLPCastView.mm
    tools/native_ui/RLPCalibrationView.mm tools/native_ui/RLPUpdateWindowController.mm
    tools/native_ui/RLPFeedbackWindowController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPTargetCurve.mm tools/mac_update.mm)
  target_compile_options(test_native_writeback_card PRIVATE -fobjc-arc)
  target_include_directories(test_native_writeback_card PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_writeback_card PRIVATE rlapp_core
    "-framework AppKit" "-framework Security")
  add_test(NAME native_writeback_card COMMAND test_native_writeback_card)
  set_tests_properties(native_writeback_card PROPERTIES TIMEOUT 180)

  # task-3 A/B：设置页「卡片外散落控件」逐页结构判据。
  # 判据断言每个控件的最近卡片祖先存在（共同容器），且每张卡片都有真实卡体内容；
  # 另断言输入页不再出现第二套采集控件、输出页声道微调有按声道数生成的真实控件、
  # 元数据两组控件各自归卡、流媒体/诊断控件全部归卡。
  add_executable(test_native_settings_cards tests/test_native_settings_cards.mm
    tools/native_ui/RLPSettingsViewController.mm tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPServersView.mm tools/native_ui/RLPMetaSourcesView.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPInputView.mm tools/native_ui/RLPCastView.mm
    tools/native_ui/RLPCalibrationView.mm tools/native_ui/RLPUpdateWindowController.mm
    tools/native_ui/RLPFeedbackWindowController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPTargetCurve.mm tools/mac_update.mm)
  target_compile_options(test_native_settings_cards PRIVATE -fobjc-arc)
  target_include_directories(test_native_settings_cards PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_settings_cards PRIVATE rlapp_core
    "-framework AppKit" "-framework Security")
  add_test(NAME native_settings_cards COMMAND test_native_settings_cards)
  set_tests_properties(native_settings_cards PROPERTIES TIMEOUT 300)

  # task-3 C/D：反馈就地发送（不弹窗、真 POST 到 web 同款端点）+ 诊断摘要只复制不弹面板。
  # 网络层用测试接缝注入：断言的是 feedback_api.h 的端点/六字段/成功判定，不联网。
  add_executable(test_native_feedback_inline tests/test_native_feedback_inline.mm
    tools/native_ui/RLPSettingsViewController.mm tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPServersView.mm tools/native_ui/RLPMetaSourcesView.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPInputView.mm tools/native_ui/RLPCastView.mm
    tools/native_ui/RLPCalibrationView.mm tools/native_ui/RLPUpdateWindowController.mm
    tools/native_ui/RLPFeedbackWindowController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPTargetCurve.mm tools/mac_update.mm)
  target_compile_options(test_native_feedback_inline PRIVATE -fobjc-arc)
  target_include_directories(test_native_feedback_inline PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_feedback_inline PRIVATE rlapp_core
    "-framework AppKit" "-framework Security")
  add_test(NAME native_feedback_inline COMMAND test_native_feedback_inline)
  set_tests_properties(native_feedback_inline PROPERTIES TIMEOUT 300)

  # 设置页「卡片粒度 + cal 页真控件」判据（task-4）：
  # ① EQ 页两卡（web 参数均衡 / 耳机 EQ）且各自控件归属正确；
  # ② cal 页三卡（web 测量向导 / EQ 文件 / 房间校正 IR）；
  # ③ sp_eq / sp_ir / sp_irgpu 必须是真控件（旧码只有 identifier 映射 ⟹ parity 假绿）；
  # ④ 行为：改 sp_eq / sp_irgpu 后 /api/settings 对应字段真的落盘；⑤ 页签内无嵌套滚动。
  add_executable(test_native_settings_granularity tests/test_native_settings_granularity.mm
    tools/native_ui/RLPSettingsViewController.mm tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPServersView.mm tools/native_ui/RLPMetaSourcesView.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPLibStatsView.mm tools/native_ui/RLPEQGeometry.mm
    tools/native_ui/RLPTargetCurve.mm tools/native_ui/RLPInputView.mm
    tools/native_ui/RLPCastView.mm tools/native_ui/RLPCalibrationView.mm
    tools/native_ui/RLPUpdateWindowController.mm tools/native_ui/RLPFeedbackWindowController.mm
    tools/native_ui/RLPPageViewController.mm tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm tools/mac_update.mm)
  target_compile_options(test_native_settings_granularity PRIVATE -fobjc-arc)
  target_include_directories(test_native_settings_granularity PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_settings_granularity PRIVATE rlapp_core
    "-framework AppKit" "-framework Security")
  add_test(NAME native_settings_granularity COMMAND test_native_settings_granularity)
  set_tests_properties(native_settings_granularity PROPERTIES TIMEOUT 180)



  # 更新检查结果「跨线程所有权」判据：done 回调的 const CheckResult& 是生产者的对象，
  # 跨 dispatch_async 必须自带拷贝。旧实现引用捕获 ⟹ 主线程读已释放堆缓冲（偶发 SIGBUS）。
  add_executable(test_native_update_result_lifetime tests/test_native_update_result_lifetime.mm
    tools/native_ui/RLPUpdateWindowController.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm tools/mac_update.mm)
  target_compile_options(test_native_update_result_lifetime PRIVATE -fobjc-arc)
  target_include_directories(test_native_update_result_lifetime PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_update_result_lifetime PRIVATE rlapp_core
    "-framework AppKit" "-framework Security")
  add_test(NAME native_update_result_lifetime COMMAND test_native_update_result_lifetime)
  set_tests_properties(native_update_result_lifetime PROPERTIES TIMEOUT 120)

  # 第8项耳机目标曲线：桥层（数组三元组/预设字段）+ 请求逐字段（web diff）+ 图上图层（像素）。
  add_executable(test_native_target_curve tests/test_native_target_curve.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPAnalysisSummary.mm)
  target_compile_options(test_native_target_curve PRIVATE -fobjc-arc)
  target_include_directories(test_native_target_curve PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_target_curve PRIVATE
    "-framework AppKit" "-framework QuartzCore")
  add_test(NAME native_target_curve COMMAND test_native_target_curve)
  set_tests_properties(native_target_curve PROPERTIES TIMEOUT 180)

  add_test(NAME native_bar_core COMMAND test_native_bar_core)
  set_tests_properties(native_bar_core PROPERTIES
    ENVIRONMENT "PATH=${CMAKE_SOURCE_DIR}/build-mac/ffmpeg-lite:/usr/bin:/bin:/usr/sbin:/sbin"
    TIMEOUT 180)

  # 原生 UI 的两条离线门禁（不联网、不开窗口、不发声）：
  #   native_ui_selftest = 视图树契约（10 项，含 webviews=0）
  #   native_ui_smoke    = ObjC 桥 → C++ 核心的真实链路（隔离 state/library，拉 ping/albums/status）
  add_test(NAME native_default_app
           COMMAND ${CMAKE_COMMAND} -P ${CMAKE_SOURCE_DIR}/tests/check_native_default_app.cmake)
  add_test(NAME native_ui_selftest COMMAND rlplayer_native --selftest)
  set_tests_properties(native_ui_selftest PROPERTIES
    ENVIRONMENT "RLPLAYER_STATE_DIR=${CMAKE_BINARY_DIR}/native-selftest-state" TIMEOUT 60)
  add_test(NAME native_ui_smoke COMMAND rlplayer_native --smoke)
  set_tests_properties(native_ui_smoke PROPERTIES TIMEOUT 120)

  # 2026-11-11：功能级验收（真数据 + 真导航 + 像素级主题判定 + 离屏截图）。
  # native_ui_selftest 只问"页面能不能构造"，抓不到
  # "专辑页双击直接播放、永远进不去详情"和"选了浅色主页还是黑的"这两类故障。
  # 这条会真的点进去、真的量渲染出来的颜色。
  add_test(NAME native_ui_functional
           COMMAND rlplayer_native --audit ${CMAKE_BINARY_DIR}/native-audit-shots)
  set_tests_properties(native_ui_functional PROPERTIES TIMEOUT 300)

  # 2026-11-12：原生 vs web 的**机器生成**对照表门禁。
  # 判据只有一条：missing 必须为 0，且每条 na 都要能在 web 前端源码里复核
  # （web 真的没调用那个端点）。手抄清单不算数 —— 这张表由脚本从两侧源码抽出来。
  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_Interpreter_FOUND)
    add_test(NAME native_ui_parity
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/native_ui/parity_scan.py --check)
    set_tests_properties(native_ui_parity PROPERTIES TIMEOUT 120)
    # 2026-11-12：主题令牌逐值核对 web CSS（色值/圆角/侧栏宽）。
    # 上一轮只验"identifier 存在"，验不出"dark 底色是墨绿而 web 是近黑"这类真偏差。
    add_test(NAME native_ui_theme
             COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/native_ui/theme_parity.py
                     --bin $<TARGET_FILE:rlplayer_native> --check)
    set_tests_properties(native_ui_theme PROPERTIES TIMEOUT 120)

  # 2026-11-12：设置键「能读能写」的真核心判据。
  # 控件在界面上 ≠ 值能落盘：/api/settings 是白名单 + 合并写，白名单外的键被**静默丢弃**
  # （回 ok:true 但 conf 里没有），界面一切正常、重启后回到默认值。
  # 这条对 web 设置页真实使用的键逐个写 → 读回，有一个被吞掉就红。
  add_executable(test_native_settings_keys tests/test_native_settings_keys.mm
    tools/native_ui/RLPCoreClient.mm)
  set_source_files_properties(tests/test_native_settings_keys.mm
    tools/native_ui/RLPCoreClient.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_native_settings_keys PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_native_settings_keys PRIVATE rlapp_core
    "-framework AppKit" "-framework Security")
  add_test(NAME native_settings_keys COMMAND test_native_settings_keys)
  set_tests_properties(native_settings_keys PROPERTIES TIMEOUT 180)

  # 2026-11-12：LRC 解析必须与 web parseLrc 逐条一致（offset 量纲/多时间戳/纯文本 t=-1）。
  # 纯函数判据，不启核心、不联网、不出声。
  add_executable(test_native_lyrics tests/test_native_lyrics.mm
    tools/native_ui/RLPLyrics.mm)
  set_source_files_properties(tests/test_native_lyrics.mm
    tools/native_ui/RLPLyrics.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_native_lyrics PRIVATE ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_native_lyrics PRIVATE "-framework Foundation")
  add_test(NAME native_lyrics COMMAND test_native_lyrics)
  set_tests_properties(native_lyrics PROPERTIES TIMEOUT 60)
  endif()

  # 2026-11-11（1.1.7.1）：播放页音频分析「一行」的判据。
  # 摘要判读是纯函数（构造 health 字典钉边界，含"不许用 snr_db"负向判据）；
  # 一行几何先断言"量到了"再断言"同一行"，避免未布局时 frame 全 0 假红。
  add_executable(test_analysis_row tests/test_analysis_row.mm
    tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPNowPlayingViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPModels.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPKnowledgeView.mm
    tools/native_ui/RLPNativeI18n.mm)
  set_source_files_properties(tests/test_analysis_row.mm
    tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPNowPlayingViewController.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPModels.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPKnowledgeView.mm
    tools/native_ui/RLPNativeI18n.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_analysis_row PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_analysis_row PRIVATE rlapp_core "-framework AppKit")
  add_test(NAME analysis_row COMMAND test_analysis_row)
  target_sources(test_analysis_row PRIVATE tools/native_ui/RLPLyrics.mm tools/native_ui/RLPTrackActions.mm)
  target_link_libraries(test_analysis_row PRIVATE "-framework CoreImage" "-framework QuartzCore")
  target_link_libraries(rlplayer_native PRIVATE "-framework CoreImage" "-framework QuartzCore")
  get_target_property(_np_web_sources test_analysis_row SOURCES)
  list(FILTER _np_web_sources EXCLUDE REGEX "tests/test_analysis_row.mm$")
  add_executable(test_native_nowplaying_web tests/test_native_nowplaying_web.mm ${_np_web_sources})
  target_compile_options(test_native_nowplaying_web PRIVATE -fobjc-arc)
  target_include_directories(test_native_nowplaying_web PRIVATE src tools tools/native_ui)
  target_link_libraries(test_native_nowplaying_web PRIVATE rlapp_core "-framework AppKit" "-framework CoreImage" "-framework QuartzCore")
  add_test(NAME native_nowplaying_web COMMAND test_native_nowplaying_web)

  set_tests_properties(analysis_row PROPERTIES TIMEOUT 120)

  # 2026-11-11（1.1.7.1）：聆听室合并页的判据。
  # A3「没有跳设置页的入口」在旧快速开始页上必然红（旧页有四个跳设置按钮）；
  # A4/A5 是纯函数：档位只能选后端真实存在的滤波、DSD 档按源类型分流。
  add_executable(test_listening_room tests/test_listening_room.mm
    tools/native_ui/RLPListeningRoom.mm
    tools/native_ui/RLPQuickStartViewController.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPModels.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPNativeI18n.mm
  )
  set_source_files_properties(tests/test_listening_room.mm
    tools/native_ui/RLPListeningRoom.mm
    tools/native_ui/RLPQuickStartViewController.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPModels.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPNativeI18n.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_listening_room PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_listening_room PRIVATE rlapp_core "-framework AppKit")
  add_test(NAME listening_room COMMAND test_listening_room)
  set_tests_properties(listening_room PROPERTIES TIMEOUT 120)

  # 2026-11-11（1.1.7.1）：专业工作台的判据。
  # B3a/B3d 是**安全性判据**：A/B 快照绝不能含 device/backend/hogexcl，
  # 否则 A/B 对比时会切输出设备、抢独占、爆音。
  # B2 钉住"不适用的信号链节点必须真的灰掉"（PCM 下的 SDM、DoP 下的 shaper）。
  add_executable(test_workbench tests/test_workbench.mm
    tools/native_ui/RLPWorkbench.mm
    tools/native_ui/RLPWorkbenchViewController.mm tools/native_ui/RLPSignalChain.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPModels.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPNativeI18n.mm
  )
  set_source_files_properties(tests/test_workbench.mm
    tools/native_ui/RLPWorkbench.mm
    tools/native_ui/RLPWorkbenchViewController.mm tools/native_ui/RLPSignalChain.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPModels.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPNativeI18n.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_workbench PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_workbench PRIVATE rlapp_core "-framework AppKit")
  add_test(NAME workbench COMMAND test_workbench)
  set_tests_properties(workbench PROPERTIES TIMEOUT 120)

  # 2026-11-11（1.1.7.1）：双模式页面的「设置读回」真链路判据。
  # 触发原因是真 BUG：/api/settings 的值在 kv 子对象里，而新页面最初读顶层
  # ⟹ 全部静默回落默认值、A/B 快照抓空。三条离线判据都不启动核心，抓不到它。
  # 纪律：隔离 state/library + backend=null + volume=-120，不开设备、不出声。
  add_executable(test_mode_settings_readback tests/test_mode_settings_readback.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPWorkbench.mm
    tools/native_ui/RLPListeningRoom.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm)
  set_source_files_properties(tests/test_mode_settings_readback.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPWorkbench.mm
    tools/native_ui/RLPListeningRoom.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_mode_settings_readback PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_mode_settings_readback PRIVATE rlapp_core "-framework AppKit")
  add_test(NAME mode_settings_readback COMMAND test_mode_settings_readback)
  set_tests_properties(mode_settings_readback PROPERTIES TIMEOUT 180)

  # 2026-11-12：流媒体服务器增删改/启用/测试（对齐 web SRC 区块，补交接单 §2.2 只读挂账）。
  # 真核心判据：add/update(keepPass)/active/remove 全部写后读回；密码红线（GET 不回明文、
  # 编辑不回填）。设置页依赖闭包较大（均衡/输入/投放/校准/更新/反馈子视图），逐一列出。
  # 纪律：隔离 state/library + backend=null + volume=-120，不开设备、不出声。
  add_executable(test_servers_view tests/test_servers_view.mm
    tools/native_ui/RLPServersView.mm
    tools/native_ui/RLPMetaSourcesView.mm tools/native_ui/RLPLibStatsView.mm
    tools/native_ui/RLPSettingsViewController.mm
    tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPInputView.mm
    tools/native_ui/RLPCastView.mm
    tools/native_ui/RLPCalibrationView.mm
    tools/native_ui/RLPUpdateWindowController.mm
    tools/native_ui/RLPFeedbackWindowController.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm
    tools/mac_update.mm)
  set_source_files_properties(tests/test_servers_view.mm
    tools/native_ui/RLPServersView.mm tools/native_ui/RLPMetaSourcesView.mm
    tools/native_ui/RLPLibStatsView.mm
    tools/native_ui/RLPSettingsViewController.mm
    tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPInputView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPInputView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPCastView.mm tools/native_ui/RLPCalibrationView.mm
    tools/native_ui/RLPUpdateWindowController.mm tools/native_ui/RLPFeedbackWindowController.mm
    tools/native_ui/RLPPageViewController.mm tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm tools/mac_update.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_servers_view PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_servers_view PRIVATE rlapp_core
    "-framework AppKit" "-framework Security")
  add_test(NAME servers_view COMMAND test_servers_view)
  set_tests_properties(servers_view PROPERTIES TIMEOUT 180)

  # 2026-11-12：信号链详情（对齐 web showChain 的 /api/signal 语义）。
  # JSON→节点是纯函数（不碰 AppKit/网络），逐分支钉住升/降采样方向、GPU、DSD、AirPlay、
  # bit-perfect 结论、空响应不填假节点。UI 只排版，不再自己算语义。
  add_executable(test_signal_chain tests/test_signal_chain.mm
    tools/native_ui/RLPSignalChain.mm)
  set_source_files_properties(tests/test_signal_chain.mm
    tools/native_ui/RLPSignalChain.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_signal_chain PRIVATE ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_signal_chain PRIVATE "-framework Foundation")
  add_test(NAME signal_chain COMMAND test_signal_chain)
  set_tests_properties(signal_chain PROPERTIES TIMEOUT 60)

  # 2026-11-12：删除磁盘目录的安全判据（用户授权移植）。**绝不真删磁盘**：
  # 纯函数钉确认文案（路径/数量/不可恢复/移出库提示），真核心钉库外目录被
  # rmdirinfo/rmdir 双重拒绝（后端 checkRemovableDirLocked 防线）。
  add_executable(test_remove_dir tests/test_remove_dir.mm
    tools/native_ui/RLPRemoveDir.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm)
  set_source_files_properties(tests/test_remove_dir.mm
    tools/native_ui/RLPRemoveDir.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_remove_dir PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_remove_dir PRIVATE rlapp_core "-framework AppKit")
  add_test(NAME remove_dir COMMAND test_remove_dir)
  set_tests_properties(remove_dir PROPERTIES TIMEOUT 120)

  # 2026-11-12：AI 接入 / 联网检索端点真链路判据（用户实测报的两个真故障）。
  # ① 保存端点把模型重置成默认（原生多发 model=，web 只发 base_url/key）；
  # ② 测试连接失灵（原生发 api_key=，后端只认 key= ⟹ 密钥从未落盘）；
  # ③ fetch/search 端点选项缺失（search_provider/search_base_url/search_key）。
  # 纪律：隔离目录 + backend=null，**不连外网**（只验配置落盘与读回）。
  add_executable(test_llm_endpoint tests/test_llm_endpoint.mm
    tools/native_ui/RLPSettingsViewController.mm
    tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPServersView.mm
    tools/native_ui/RLPMetaSourcesView.mm tools/native_ui/RLPLibStatsView.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPInputView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPInputView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPCastView.mm tools/native_ui/RLPCalibrationView.mm
    tools/native_ui/RLPUpdateWindowController.mm tools/native_ui/RLPFeedbackWindowController.mm
    tools/native_ui/RLPPageViewController.mm tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm tools/mac_update.mm)
  set_source_files_properties(tests/test_llm_endpoint.mm
    tools/native_ui/RLPSettingsViewController.mm tools/native_ui/RLPServersView.mm
    tools/native_ui/RLPSettingsLayout.mm
    tools/native_ui/RLPMetaSourcesView.mm tools/native_ui/RLPLibStatsView.mm
    tools/native_ui/RLPEqualizerView.mm tools/native_ui/RLPEQFaderView.mm tools/native_ui/RLPEQFaderInspector.mm tools/native_ui/RLPVolumeSliderView.mm tools/native_ui/RLPInputView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPEQGeometry.mm tools/native_ui/RLPInputView.mm tools/native_ui/RLPTargetCurve.mm
    tools/native_ui/RLPCastView.mm tools/native_ui/RLPCalibrationView.mm
    tools/native_ui/RLPUpdateWindowController.mm tools/native_ui/RLPFeedbackWindowController.mm
    tools/native_ui/RLPPageViewController.mm tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPSupport.mm tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm tools/mac_update.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_llm_endpoint PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_llm_endpoint PRIVATE rlapp_core
    "-framework AppKit" "-framework Security")
  add_test(NAME llm_endpoint COMMAND test_llm_endpoint)
  set_tests_properties(llm_endpoint PROPERTIES TIMEOUT 180)

  # 2026-11-12：古典作品页（补齐 web setView('works') / Discogs 演绎版本）。
  # 只验 UI 契约与输入校验，**不连外网**（离线也必须跑绿）。
  add_executable(test_works_view tests/test_works_view.mm
    tools/native_ui/RLPWorksViewController.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm
    tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm
    tools/native_ui/RLPNativeI18n.mm)
  set_source_files_properties(tests/test_works_view.mm
    tools/native_ui/RLPWorksViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_works_view PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_works_view PRIVATE rlapp_core "-framework AppKit")
  add_test(NAME works_view COMMAND test_works_view)
  set_tests_properties(works_view PROPERTIES TIMEOUT 120)

  # 2026-11-12：艺术家网格 / 专辑曲目表 / 播放条的**几何**判据。
  # 这三处都是「能构造但布局错」，只有量 frame 才抓得住（前两版列宽修法都改坏了）。
  add_executable(test_artist_grid tests/test_artist_grid.mm
    tools/native_ui/RLPArtistsViewController.mm
    tools/native_ui/RLPAlbumDetailViewController.mm
    tools/native_ui/RLPPlaybackBarView.mm tools/native_ui/RLPSignalChain.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm)
  set_source_files_properties(tests/test_artist_grid.mm
    tools/native_ui/RLPArtistsViewController.mm tools/native_ui/RLPAlbumDetailViewController.mm
    tools/native_ui/RLPPlaybackBarView.mm tools/native_ui/RLPSignalChain.mm tools/native_ui/RLPVolumeSliderView.mm
    tools/native_ui/RLPVolumeKnobView.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPModels.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_artist_grid PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_artist_grid PRIVATE rlapp_core "-framework AppKit")
  add_test(NAME artist_grid COMMAND test_artist_grid)
  set_tests_properties(artist_grid PROPERTIES TIMEOUT 120)

  # 2026-11-11：曲目右键菜单完整性（对齐 web trackActionMenu 四项核心动作）。
  # 触发原因：原生曲目页只有两项、专辑详情完全没有右键菜单、队列只有两项。
  # 2026-11-12：歌单页曲目表也接共享菜单（T14），故把歌单页与基类编进本测试。
  add_executable(test_track_actions tests/test_track_actions.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPPlaylistsViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm)
  set_source_files_properties(tests/test_track_actions.mm
    tools/native_ui/RLPTrackActions.mm tools/native_ui/RLPAnalysisSummary.mm
    tools/native_ui/RLPPlaylistsViewController.mm tools/native_ui/RLPPageViewController.mm
    tools/native_ui/RLPCoreClient.mm tools/native_ui/RLPSupport.mm
    tools/native_ui/RLPTheme.mm tools/native_ui/RLPNativeI18n.mm
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_track_actions PRIVATE
    ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools ${CMAKE_SOURCE_DIR}/tools/native_ui)
  target_link_libraries(test_track_actions PRIVATE rlapp_core "-framework AppKit")
  add_test(NAME track_actions COMMAND test_track_actions)
  set_tests_properties(track_actions PROPERTIES TIMEOUT 120)

  # 2026-11-11（1.1.7.1）：/api/settings 的"写了就是写了"判据。
  # 触发原因是一个真 BUG：白名单漏了 hogexcl ⟹ POST 回 ok:true 却不落盘、读回为空，
  # web 版设置页的「严格独占」勾选因此从不保存。判据是黑盒三连（回显/读回/conf 原文），
  # 只断言 ok:true 会漏掉它 —— 见 tests/test_settings_persist.cpp 头注释。
  add_executable(test_settings_persist tests/test_settings_persist.cpp)
  target_include_directories(test_settings_persist PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
  target_link_libraries(test_settings_persist PRIVATE rlapp_core)
  add_test(NAME settings_persist COMMAND test_settings_persist)
  set_tests_properties(settings_persist PROPERTIES TIMEOUT 120)
endif()

# ---------------- 测试 ----------------
enable_testing()

# 1.1.1 诊断基础：真实 JSONL/轮转/脱敏与隔离子进程退出标记。
add_executable(test_diag_event tests/test_diag_event.cpp)
target_link_libraries(test_diag_event PRIVATE rtadsp)
add_test(NAME diag_event COMMAND test_diag_event)
add_executable(test_diag_run_marker tests/test_diag_run_marker.cpp)
target_link_libraries(test_diag_run_marker PRIVATE rtadsp)
add_test(NAME diag_run_marker COMMAND test_diag_run_marker)
add_executable(rtadiag tools/rtadiag.cpp)
target_link_libraries(rtadiag PRIVATE rtadsp)
foreach(_diag_test diag_bundle diag_bundle_json diag_http diag_questions rtadiag float_decode quality_edges health_store lyrics_cache ir_resample)
  add_executable(test_${_diag_test} tests/test_${_diag_test}.cpp)
  target_link_libraries(test_${_diag_test} PRIVATE rtadsp ${RL_PLATFORM_LIBS})
  add_test(NAME ${_diag_test} COMMAND test_${_diag_test})
endforeach()

# 流媒体启用配置：真实 loopback Subsonic 请求 + 隔离配置持久化。
add_executable(test_source_manager tests/test_source_manager.cpp)
target_include_directories(test_source_manager PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_source_manager PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME source_manager COMMAND test_source_manager)

# Subsonic 协议语义（含「Index.artist[] 没有 isDir，必须按目录处理」这条真实形状判据）。
add_executable(test_subsonic tests/test_subsonic.cpp)
target_include_directories(test_subsonic PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_subsonic PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME subsonic COMMAND test_subsonic)

# 手动 opt-in 原生验收：真 WKWebView/真 embedded 核心，不进入自动 CTest（会开自有窗口）。
# Opt-in real WKWebView cover acceptance against explicitly isolated existing state.
add_executable(test_cover_native tests/test_cover_native.mm)
set_source_files_properties(tests/test_cover_native.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_include_directories(test_cover_native PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
target_link_libraries(test_cover_native PRIVATE rlapp_core "-framework AppKit" "-framework WebKit")

add_executable(test_source_native tests/test_source_native.mm)
set_source_files_properties(tests/test_source_native.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_include_directories(test_source_native PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
target_link_libraries(test_source_native PRIVATE rlapp_core "-framework AppKit" "-framework WebKit")

# 手动原生首绘验收（会开隔离窗口，不进入自动CTest）。
add_executable(test_startup_native tests/test_startup_native.mm)
set_source_files_properties(tests/test_startup_native.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_include_directories(test_startup_native PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
target_link_libraries(test_startup_native PRIVATE rlapp_core "-framework AppKit" "-framework WebKit"
    "-framework ScreenCaptureKit" "-framework ImageIO" "-framework UniformTypeIdentifiers")

# ---- 跨平台测试（macOS 也跑）----
# CoreAudio 后端端到端（macOS 真机；铁律 1：默认 -60 dBFS，几乎不可闻）
# 必须显式传 --device 才碰物理声卡；不带参数时只跑只读能力查询。
if(APPLE)
  add_executable(test_coreaudio tests/test_coreaudio.cpp)
  target_include_directories(test_coreaudio PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(test_coreaudio PRIVATE ${RL_PLATFORM_LIBS})
  add_test(NAME coreaudio COMMAND test_coreaudio --no-open)

  # 回环逐位比对工具（Aggregate Tap / 虚拟设备输入侧；默认电平 -60 dBFS）
  # rtaloop_tap.mm：CATapDescription/AudioHardwareCreateProcessTap 是 ObjC++ 门控，
  # 拆成薄包装给纯 C++ 主文件用（见该文件头注）
  enable_language(OBJCXX)
  add_executable(rtaloop tools/rtaloop.cpp tools/rtaloop_tap.mm)
  target_include_directories(rtaloop PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(rtaloop PRIVATE ${RL_PLATFORM_LIBS} "-framework Foundation")

  # 单进程 transport 离线门禁：WKURLSchemeHandler 的二进制安全/并发语义，以及
  # 壳的 HostMessage 9 条契约。测试文件自己 include mac_host.mm 并定义独立 rlapp mock，
  # 不链接真实核心，不会初始化曲库、不会触碰音频设备。
  add_executable(test_mac_transport tests/test_mac_transport.mm)
  set_source_files_properties(tests/test_mac_transport.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_mac_transport PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
  target_compile_options(test_mac_transport PRIVATE -DGL_SILENCE_DEPRECATION)
  target_link_libraries(test_mac_transport PRIVATE "-framework AppKit" "-framework WebKit" "-framework JavaScriptCore")
  add_test(NAME mac_transport COMMAND test_mac_transport)

  # 进程内核心门禁：真实 rlapp::start_embedded/dispatch/stop_embedded。
  # 曲库/配置由测试写入临时目录；不监听端口、不开设备；并发判据是 handle 内峰值探针。
  add_executable(test_embedded_api tests/test_embedded_api.cpp)
  target_include_directories(test_embedded_api PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
  target_link_libraries(test_embedded_api PRIVATE rlapp_core)
  # 2026-10-26 F-4 自动更新：安装流水线**真跑**门禁（造真 dmg / 真挂载 / 真 ditto 安装）。
  # 所有路径都在 /tmp 隔离目录，绝不触碰用户正在使用的 .app。
  # 判据：篡改必拒绝且不挂载、正确摘要能真装进去（内容可核对）、截断必拒绝、token 脱敏。
  add_executable(test_mac_update tests/test_mac_update.mm tools/mac_update.mm)
  set_source_files_properties(tests/test_mac_update.mm tools/mac_update.mm
                              PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_include_directories(test_mac_update PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
  target_link_libraries(test_mac_update PRIVATE ${RL_PLATFORM_LIBS} "-framework AppKit" "-framework Foundation" "-framework Security")
  add_test(NAME mac_update COMMAND test_mac_update)

  add_test(NAME embedded_api COMMAND test_embedded_api)
  set_tests_properties(embedded_api PROPERTIES
    ENVIRONMENT "PATH=${CMAKE_SOURCE_DIR}/build-mac/ffmpeg-lite:/usr/bin:/bin:/usr/sbin:/sbin")

  # 1.1.2 AirPlay 平台策略门禁（AP-1.1/1.2/1.3/1.4/1.6）。
  # 全离线：FourCC 识别、能力收敛、DoP 前置拒绝、延迟来源、存活判定；
  # 不 open 任何设备、不出声、不改系统音量（铁律 1）。
  add_executable(test_airplay_policy tests/test_airplay_policy.cpp)
  target_include_directories(test_airplay_policy PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(test_airplay_policy PRIVATE ${RL_PLATFORM_LIBS})
  add_test(NAME airplay_policy COMMAND test_airplay_policy)

  # 1.1.2 P0-3：DoP 欠载/尾块补全必须是合法静音帧（0x05/0xFA 交替），不能裸补 0。
  # 判据含反例自证：全零缓冲必须被判非法 —— 否则这个测试证明不了任何事。
  add_executable(test_dop_underrun_fill tests/test_dop_underrun_fill.cpp)
  target_include_directories(test_dop_underrun_fill PRIVATE ${CMAKE_SOURCE_DIR}/src)
  add_test(NAME dop_underrun_fill COMMAND test_dop_underrun_fill)

  # 1.1.2 P0-3（引擎侧）：render_loop 的 EOS 尾块在 DoP 下必须补合法静音帧。
  # 判据：①纯函数标记严格交替；②真实 render_loop 在 h.dop=true 下最后一帧仍合法；
  # ③PCM 对照仍补 0（零回归）；④钩子缺失时必须告警且置位诊断标志（不许静默）。
  add_executable(test_dop_padding tests/test_dop_padding.cpp)
  target_include_directories(test_dop_padding PRIVATE ${CMAKE_SOURCE_DIR}/src)
  add_test(NAME dop_padding COMMAND test_dop_padding)
endif()

add_executable(test_knowledge tests/test_knowledge.cpp)
target_include_directories(test_knowledge PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_knowledge PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME knowledge COMMAND test_knowledge)

# P3 资料层③ 检索层：DeepSeek search/fetch + rerank/authority/白名单过滤 + 引用纪律
add_executable(test_retrieval tests/test_retrieval.cpp)
target_include_directories(test_retrieval PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_retrieval PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME retrieval COMMAND test_retrieval)

# 2026-11-08（1.1.4-beta7 #1 AI 检索速度）：并行 fetch 软截止的行为契约（离线 mock transport）
add_executable(test_retrieval_speed tests/test_retrieval_speed.cpp)
target_include_directories(test_retrieval_speed PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_retrieval_speed PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME retrieval_speed COMMAND test_retrieval_speed)

# 1.1.5-beta2（U5 专辑上下文 / #21a 页面类型分类 / #21b 归属与引用校验 / #21c 缓存 v6 /
# M-12 异步 job 状态机 / M-13 文件名兜底）。每个 target 的判据见 tests/*.cpp 头注释与
# 工作区 PLAN-1.1.5-beta2.md。骨架期由 Lead 预置为必红（exit 1），实现后转绿。
foreach(_t115 entity_classify retrieval_v6 track_identity knowledge_v6 async_job)
  add_executable(test_${_t115} tests/test_${_t115}.cpp)
  target_include_directories(test_${_t115} PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(test_${_t115} PRIVATE ${RL_PLATFORM_LIBS})
  add_test(NAME ${_t115} COMMAND test_${_t115})
endforeach()

# 2026-10-24（用户 261024-04 #6/#4 后端侧）：实体资料缓存是否**共用**、第二次是否**零 LLM 调用**、
# 命中是否 ≤300ms。全离线：L2 材料直接写缓存，chat/search/fetch 走计数型 mock transport
# （LlmConfig::transport 钩子），判据是"调用计数不变"而不是"耗时不抖"。
add_executable(test_metacache tests/test_metacache.cpp)
target_include_directories(test_metacache PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_metacache PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME metacache COMMAND test_metacache)

# 2026-10-24（用户 261024-04 #8）：/api/status 的 gpu（可用性）与 gpuUsed（本次真的参与）
# 组合语义真值表。纯函数（src/meta/statusflags.h），不碰 GPU、不开设备。
add_executable(test_opra_eq tests/test_opra_eq.cpp)
target_include_directories(test_opra_eq PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_opra_eq PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME opra_eq COMMAND test_opra_eq)

# P3 资料层④b：Discogs L4 古典作品版本推荐（令牌桶/熔断 + 缓存 + 版本推荐列表）
add_executable(test_decide_route tests/test_decide_route.cpp)
target_include_directories(test_decide_route PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME decide_route COMMAND test_decide_route)

# 2026-11-09（用户反馈「共享模式必然不是 bit-perfect，程序却显示是」）：
# bit-perfect 结论的唯一实现 src/audio/bp_verdict.h。纯函数、不开设备、不发声。
# 判据含一条「先跑红」用例：把旧判据逐字复刻，断言它在共享场景下返回 yes（BUG 复现），
# 同一段再断言新判据返回 no —— 证明这条判据真能抓住那个错误，而不是"看起来更严"。
add_executable(test_bp_verdict tests/test_bp_verdict.cpp)
target_include_directories(test_bp_verdict PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME bp_verdict COMMAND test_bp_verdict)

# 物理格式选择判据 src/audio/phys_format.h：真 bit-perfect 的前提
# （锁不上硬件物理格式时 HAL 一定在转换，此时不可能逐位直通）。纯函数、不开设备。
add_executable(test_phys_format tests/test_phys_format.cpp)
target_include_directories(test_phys_format PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME phys_format COMMAND test_phys_format)

# 真机：物理格式锁定是否真的生效（不启动 IOProc、不写样本，open 后立即 close）。
# 用 --device 显式指定端点；不带参数时测默认设备（可能是内置扬声器，那时判据是"如实报否"）。
# 三层查询在独占/共享/停止三态下的回归（不启 IOProc、不写样本）
add_executable(test_three_layer_states tests/test_three_layer_states.cpp)
target_include_directories(test_three_layer_states PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_three_layer_states PRIVATE
    "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreFoundation")
add_test(NAME three_layer_states COMMAND test_three_layer_states --device 101)

add_executable(test_physlock_device tests/test_physlock_device.cpp)
target_include_directories(test_physlock_device PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_physlock_device PRIVATE
    "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreFoundation")

add_executable(test_host_msg tests/test_host_msg.cpp)
target_link_libraries(test_host_msg PRIVATE rtadsp)
add_test(NAME host_msg COMMAND test_host_msg)

# 2026-10-26 邮件反馈通道：**纯逻辑层**离线门禁（不含任何系统副作用）。
# 判据（铁律 3，每条都对应真实会出事的场景，对抗用例是真塞进去看被拦）：
#   * header 注入：正文/主题里塞 "\r\nBcc: attacker@evil.com" → 整封 .eml 的 header 区
#     必须不存在任何伪造行；主题里不许有 \r/\n（含 U+2028）；
#   * 正文截断按**字符**不按字节（9000 个中文字符 → 正好留 8000 字 = 24000 字节）；
#   * 诊断包路径："../" 逃逸、"~/.ssh" 前缀碰撞（/tmp/x-evil 不能命中 /tmp/x）、含 NUL/CRLF
#     一律拒绝；只有临时目录内的 .zip 放行；
#   * MIME：附件 base64 解回来必须与原始字节**逐字节相等**；
#   * 不打开邮件客户端、不写磁盘、不发任何网络请求（可以进 ctest 全量跑）。
add_executable(test_mac_feedback tests/test_mac_feedback.cpp)
target_include_directories(test_mac_feedback PRIVATE ${CMAKE_SOURCE_DIR}/tools)
# 源码根传进去：凭据扫描那条判据要真读源码文件，不能靠相对路径（换个 cwd 就静默跳过）
target_compile_definitions(test_mac_feedback PRIVATE RL_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
add_test(NAME mac_feedback COMMAND test_mac_feedback)

# 2026-10-26 F-4 自动更新：纯逻辑层离线门禁（不联网、不开窗口、不碰音频设备）
# 判据：版本比较真值表（1.0.10>1.0.9 能区分数值比较与字符串比较）、sha256 用 NIST 官方向量、
# 下载 URL 白名单对抗用例、「篡改/截断必失败」安装门禁、五种失败分支都不得等于「已是最新」。
add_executable(test_update_check tests/test_update_check.cpp)
target_link_libraries(test_update_check PRIVATE rtadsp)
add_test(NAME update_check COMMAND test_update_check)

# 1.1.5.1：更新通道（中国大陆 / 全球）纯逻辑层离线门禁
# 判据：默认值 Global、通道解析真值表（含 URL 冒充通道值的对抗用例）、通道→清单来源、
# 后台域名白名单（形近/端口/userinfo/非 https 全拒 + 原有两条规则不放宽）、
# cn 不可用绝不等于「已是最新」、两套通道版本/sha256 比较一致、ChannelManifest::ready() 顺序闸门。
add_executable(test_update_channel tests/test_update_channel.cpp)
target_link_libraries(test_update_channel PRIVATE rtadsp)
add_test(NAME update_channel COMMAND test_update_channel)

# B-8：真实回环慢 HTTP 的取消/线程隔离/嵌套作用域验证，不访问外网或音频设备。
if(APPLE)
  add_executable(test_http_cancel tests/test_http_cancel.cpp)
  target_include_directories(test_http_cancel PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(test_http_cancel PRIVATE ${RL_PLATFORM_LIBS})
  add_test(NAME http_cancel COMMAND test_http_cancel)
  set_tests_properties(http_cancel PROPERTIES TIMEOUT 30)
  add_executable(test_bitdepth_negotiation tests/test_bitdepth_negotiation.cpp)
  target_include_directories(test_bitdepth_negotiation PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(test_bitdepth_negotiation PRIVATE ${RL_PLATFORM_LIBS})
  add_test(NAME bitdepth_negotiation COMMAND test_bitdepth_negotiation)
  # 「停止投放」500 的根因判据（离线、无网络、无声）：自己 join 自己 / 重复 join / 并发 join
  add_executable(test_thread_join_safe tests/test_thread_join_safe.cpp)
  target_include_directories(test_thread_join_safe PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(test_thread_join_safe PRIVATE ${RL_PLATFORM_LIBS})
  add_test(NAME thread_join_safe COMMAND test_thread_join_safe)
  set_tests_properties(thread_join_safe PROPERTIES TIMEOUT 60)
  add_executable(test_output_bit_depth tests/test_output_bit_depth.cpp)
  target_include_directories(test_output_bit_depth PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(test_output_bit_depth PRIVATE ${RL_PLATFORM_LIBS})
  add_test(NAME output_bit_depth COMMAND test_output_bit_depth)
endif()

add_executable(test_resampler tests/test_resampler.cpp)
target_link_libraries(test_resampler PRIVATE rtadsp)
add_test(NAME resampler COMMAND test_resampler)

add_executable(test_dither tests/test_dither.cpp)
target_link_libraries(test_dither PRIVATE rtadsp)
add_test(NAME dither COMMAND test_dither)

add_executable(test_modulator tests/test_modulator.cpp)
target_link_libraries(test_modulator PRIVATE rtadsp)
add_test(NAME modulator COMMAND test_modulator)

add_executable(test_modulator_families tests/test_modulator_families.cpp)
target_link_libraries(test_modulator_families PRIVATE rtadsp)
add_test(NAME modulator_families COMMAND test_modulator_families)

add_executable(test_filters tests/test_filters.cpp)
target_link_libraries(test_filters PRIVATE rtadsp)
add_test(NAME filters COMMAND test_filters)

# PCM 回放质量量测报告工具（离线客观量测，不打开音频设备）
add_executable(pcm_quality_report tests/pcm_quality_report.cpp)
target_link_libraries(pcm_quality_report PRIVATE rtadsp)

add_executable(test_pipeline tests/test_pipeline.cpp)
target_link_libraries(test_pipeline PRIVATE rtadsp)
add_test(NAME pipeline COMMAND test_pipeline)

add_executable(test_conv_matrix tests/test_conv_matrix.cpp)
target_link_libraries(test_conv_matrix PRIVATE rtadsp)
add_test(NAME conv_matrix COMMAND test_conv_matrix)

# 卷积 IR 预处理：超 Nyquist 外推 + 自动增益。
add_executable(test_conv_ir_prep tests/test_conv_ir_prep.cpp)
target_link_libraries(test_conv_ir_prep PRIVATE rtadsp)
add_test(NAME conv_ir_prep COMMAND test_conv_ir_prep)

add_executable(test_volume_eq tests/test_volume_eq.cpp)
target_link_libraries(test_volume_eq PRIVATE rtadsp)
add_test(NAME volume_eq COMMAND test_volume_eq)

# ---------------- 2026-10-25：设备输出层增益应用门禁（音量失效事故回归）----------------
# 事故：用户报「音量不好使」。根因是两处叠加：
#   ① render_loop 每 tick 调 OutSink::set_live_gain_db()，但基类是**空实现**
#      （render_loop.h:43），没有任何 sink 覆盖它 ⟹ 音量请求被静默丢弃；
#   ② 即使接通，CoreAudioOutput::write() 也直接 memcpy 原始 PCM、**从不读 gain_**
#      （gain_ 只被 bit_perfect() 用来判「增益是否 1.0」）⟹ 数据一个字节都没变。
# 症状还自相矛盾：声音没变，但 bit_perfect() 因 gain_!=1 报「非位完美」。
#
# 原 tests/test_volume_eq 只覆盖 DSP 层（浮点域乘增益），**设备输出层从来没测过** ——
# 这就是 bug 藏身之处。本测试补上设备输出层（与 audio_out_coreaudio.h::write() 的
# 缩放分支逐行同构），判据含「4 档增益输出严格递减」+「不得全部相等」的反证，
# 纯离线不碰设备（铁律 1）。红→绿演示见测试文件末尾注释。
add_executable(test_output_gain tests/test_output_gain.cpp)
target_include_directories(test_output_gain PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME output_gain COMMAND test_output_gain)

# ---------------- 2026-10-25：DoP/DSD 输出时软件音量必须锁 0 dB ----------------
# 为什么是硬门禁而不是"记得别动"：
#   DoP 把 DSD 位流装进 24-bit PCM 容器，靠高 8 位交替的 0x05/0xFA 标记让 DAC 识别。
#   任何软件增益都会改写这些字节 ⟹ 标记失效 ⟹ DAC 把 DSD 当普通 PCM 播
#   ⟹ 输出**刺耳白噪音**（不是"声音变小"，是彻底坏掉）。
#   修音量失效时发现 render_loop 无条件调 set_live_gain_db，DoP 路径没有保护 ——
#   音量一旦真的生效，DoP + 非 0 dB 就会炸。两者必须同时存在。
# 本测试用**真实 render_loop**（mock sink 记录增益），不打开设备（铁律 1）。
# 判据含对照（PCM 路径必须正常应用 -20 dB），防止"一律清零"也能过。
add_executable(test_dop_gain_guard tests/test_dop_gain_guard.cpp)
target_include_directories(test_dop_gain_guard PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME dop_gain_guard COMMAND test_dop_gain_guard)

# ---------------- 2026-10-25：设备硬件音量接管/归还 ----------------
# 事故：用户报「要接管设备就全接管，要用系统的音量级别，现在接管之后最高音量是之前
#       系统设置的最高音量，还无法修改」。
# 根因：本项目**从未读写过设备硬件音量**（全仓 grep 零命中）。独占(Hog)模式下系统音量 UI
#       被挡住，硬件音量标量停在接管那一刻的旧值（本机实测 0.152 ≈ −16 dB），播放器只做
#       软件增益 ⟹ 天花板就是这个陈旧值，且用户无法修改。
# 修复：接管时存原值 → 硬件音量置满 1.0 → 解除静音；close() 时恢复原值。
# 门禁默认**只读**（零副作用）；真实读写需手动 `test_hw_volume --allow-hw-touch`
# （会短暂改动默认输出设备音量，但**不播放任何声音** —— 铁律 1）。
add_executable(test_hw_volume tests/test_hw_volume.cpp)
target_include_directories(test_hw_volume PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_hw_volume PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME hw_volume COMMAND test_hw_volume)

# ---------------- 2026-10-25：Hog 独占开关（方案 C）与系统音量可用性 ----------------
# 用户诉求演进：①「接管后音量锁死」→ 我做"接管硬件音量"（错）；
#              ②「音量爆炸，能不能独占时让系统调音量」→ 查清 macOS Hog 会阻断其它进程改音量，
#                 「严格独占」与「系统音量可用」物理互斥；
#              ③ 用户拍板：做成开关让用户自己选。
#
# 本轮还发现并修掉一个**真 bug**：set_hog_mode 的读写语义写反了 ——
#   该属性的 set 值不是"设成谁"，而是"本进程是否继续持有"：
#     写 0        → 请求独占（内核回填真实持有者 pid）
#     写 getpid() → 释放
#   原实现 `on ? getpid() : 0` 正好反了：true 在释放、false 在抢 ⟹
#   ① 独占从未真正生效；② close 的"释放"反而去抢，退出后设备被残留占用。
#
# 判据：exclusive 默认 false；不抢 Hog 时系统音量可用；抢 Hog 时被阻断；
#       释放后恢复。默认只读（零副作用），真实抢占需 --allow-hw-touch。
add_executable(test_hog_exclusive tests/test_hog_exclusive.cpp)
target_include_directories(test_hog_exclusive PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_hog_exclusive PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME hog_exclusive COMMAND test_hog_exclusive)

# ---------------- 2026-10-25：耳机 EQ（OPRA 预设）切换实时生效与热重载回归 ----------------
add_executable(test_eq_reload tests/test_eq_reload.cpp ${RL_LOOPBACK_SRC} ${RL_IMAGE_THUMB_SRC})
target_include_directories(test_eq_reload PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
target_link_libraries(test_eq_reload PRIVATE rtadsp ${RL_PLATFORM_LIBS} "-framework Foundation" ${RL_IMAGE_FRAMEWORKS})
add_test(NAME eq_reload COMMAND test_eq_reload)

# ---------------- 1.1.2 DSD 播放可靠性热修（P0-1 / P0-2）----------------
# P0-2：直通资格不得被"同族速率计划可用"覆盖（EQ/IR/音量/响度/RG/trim/声道变化）。
# P0-1：速率转换后必须以**实际**位率算载波、DoP 帧数与 CUE 区间。
# 都是纯规划逻辑 → 独立单元测试；生产 TU 回归测试嵌入 rtaweb.cpp + null sink（不开设备）。
add_executable(test_direct_dsd_plan tests/test_direct_dsd_plan.cpp)
target_include_directories(test_direct_dsd_plan PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME direct_dsd_plan COMMAND test_direct_dsd_plan)

add_executable(test_dsd_production tests/test_dsd_production.cpp ${RL_LOOPBACK_SRC} ${RL_IMAGE_THUMB_SRC})
target_include_directories(test_dsd_production PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
target_link_libraries(test_dsd_production PRIVATE rtadsp ${RL_PLATFORM_LIBS} "-framework Foundation" ${RL_IMAGE_FRAMEWORKS})
add_test(NAME dsd_production COMMAND test_dsd_production)

# ---------------- 20 段参数均衡 PEQ（261024-02 #6）：0dB 直通 / 6dB@fc / Q 带宽 /
#                  采样率重建 / 满幅过载恢复 / 热更新交叉淡入（铁律 7）----------------
add_executable(test_peq tests/test_peq.cpp)
target_link_libraries(test_peq PRIVATE rtadsp)
add_test(NAME peq COMMAND test_peq)

add_executable(test_chain tests/test_chain.cpp)
target_link_libraries(test_chain PRIVATE rtadsp)
add_test(NAME chain COMMAND test_chain)

add_executable(test_drift tests/test_drift.cpp)
target_link_libraries(test_drift PRIVATE rtadsp)
add_test(NAME drift COMMAND test_drift)

add_executable(test_clock_loop tests/test_clock_loop.cpp)
target_link_libraries(test_clock_loop PRIVATE rtadsp)
add_test(NAME clock_loop COMMAND test_clock_loop)

add_executable(test_status tests/test_status.cpp)
target_link_libraries(test_status PRIVATE rtadsp)
add_test(NAME status COMMAND test_status)

add_executable(test_loudness tests/test_loudness.cpp)
target_link_libraries(test_loudness PRIVATE rtadsp)
add_test(NAME loudness COMMAND test_loudness)

add_executable(test_md5 tests/test_md5.cpp)
target_include_directories(test_md5 PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME md5 COMMAND test_md5)

add_executable(test_dop tests/test_dop.cpp)
target_link_libraries(test_dop PRIVATE rtadsp)
add_test(NAME dop COMMAND test_dop)

add_executable(test_dop_stream tests/test_dop_stream.cpp)
target_link_libraries(test_dop_stream PRIVATE rtadsp)
add_test(NAME dop_stream COMMAND test_dop_stream)

add_executable(test_parallel tests/test_parallel.cpp)
target_link_libraries(test_parallel PRIVATE rtadsp)
add_test(NAME parallel COMMAND test_parallel)

add_executable(test_two_stage tests/test_two_stage.cpp)
target_link_libraries(test_two_stage PRIVATE rtadsp)
add_test(NAME two_stage COMMAND test_two_stage)

add_executable(test_isp tests/test_isp.cpp)
target_link_libraries(test_isp PRIVATE rtadsp)
add_test(NAME isp COMMAND test_isp)

add_executable(test_stream_baseline tests/test_stream_baseline.cpp)
target_link_libraries(test_stream_baseline PRIVATE rtadsp)
add_test(NAME stream_baseline COMMAND test_stream_baseline)

# 每声道增益 / 多声道路由
add_executable(test_channel_gain tests/test_channel_gain.cpp)
target_link_libraries(test_channel_gain PRIVATE rtadsp)
add_test(NAME channel_gain COMMAND test_channel_gain)

# GPU 卷积桥接：DLL 里的符号必须真的被取到（Windows 分支曾漏 GetProcAddress）
add_executable(test_gpu_bridge tests/test_gpu_bridge.cpp)
target_link_libraries(test_gpu_bridge PRIVATE rtadsp)
add_test(NAME gpu_bridge COMMAND test_gpu_bridge)

# DSF / DFF 原生读取（ROADMAP P0-1）：写回读逐位一致 + 文件布局独立校验
add_executable(test_fullscale tests/test_fullscale.cpp)
target_link_libraries(test_fullscale PRIVATE rtadsp)
add_test(NAME fullscale COMMAND test_fullscale)

add_executable(test_playback_edges tests/test_playback_edges.cpp)
target_link_libraries(test_playback_edges PRIVATE rtadsp)
target_include_directories(test_playback_edges PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME playback_edges COMMAND test_playback_edges)

# DSD 通路（P0-2 素材生成 / P0-3 DirectSDM / P0-4 抽取器）
add_executable(test_metaparse tests/test_metaparse.cpp)
target_include_directories(test_metaparse PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME metaparse COMMAND test_metaparse)

add_executable(test_metamatch tests/test_metamatch.cpp)
target_include_directories(test_metamatch PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME metamatch COMMAND test_metamatch)

add_executable(test_buffer_policy tests/test_buffer_policy.cpp)
target_link_libraries(test_buffer_policy PRIVATE rtadsp)
add_test(NAME buffer_policy COMMAND test_buffer_policy)

add_executable(test_ratepick tests/test_ratepick.cpp)
target_include_directories(test_ratepick PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME ratepick COMMAND test_ratepick)

# 最小 ZIP（STORE）打包结构（2026-10-22 功能3「导出诊断 = 一个压缩包」）。
# 纯内存、零外部依赖、不调 PowerShell（理由见 src/net/zipstore.h 头注）。
add_executable(test_zipstore tests/test_zipstore.cpp)
target_include_directories(test_zipstore PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME zipstore COMMAND test_zipstore)

# P3① 实体模型（schema/归一化/显式边/落盘）：全离线，不调任何网络 API ——
# 归一化与 id 是纯函数；临时目录落盘；真实曲库样本只读访问
#（缺失时打 [SKIP]，不伪造成通过）。铁律 3：断言「全半角不折叠必然 FAIL」有反向验证。
add_executable(test_year tests/test_year.cpp)
target_include_directories(test_year PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME year COMMAND test_year)

# probe_media 的 duration 字段（2026-10-22 跨模块缺陷）：ffprobe 原参数只有 format_tags，
# MediaInfo::duration 恒 0 → enrich 的 fileSec 恒 0 → match 的「时长差 ±3s」强信号从未生效。
# 本测试需要环境里的 ffprobe（工具缺失即失败，不跳过，与 writeback 同类门禁）；
# 已知时长的合成 WAV 落在 %TEMP%，不碰 MUSIC；真实 FLAC 素材缺失时打 [SKIP]。
add_executable(test_playback_gpu tests/test_playback_gpu.cpp)
target_include_directories(test_playback_gpu PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME playback_gpu COMMAND test_playback_gpu)

# OPRA 耳机 EQ 适配门禁（离线纯函数 + RTA_NET_TESTS=1 真网 opt-in）


# ---- Windows 专属测试段已整体删除（2026-10-25 平台改造）----
# 原文件此处是一个 if(WIN32) 守卫，里面 15 条测试全部依赖 Windows API（WASAPI / WebView2 /
# winsock / windows.h 传递依赖），随 Windows 平台层一起删除：
#   test_rtanet, test_rtanet_e2e, test_emby, test_subsonic, test_metallm,
#   test_metaproviders, test_enrich, test_dizzylab, test_wasapi_shared,
#   test_classical_e2e, test_discogs, test_capture, test_upnp_control,
#   test_wv2_version, test_cast_service
# 注：其中几条只差 POSIX 垫片（CP_UTF8 / MAX_PATH / _dupenv_s），真实移植另立任务；
# 本轮按「macOS 单平台」要求先删干净，不留 Windows 构建路径。

# ---------------- 待移植的旧测试（临时开关，默认 OFF）----------------
# ⚠️ 2026-10-25 实测（铁律 4：如实挂账，不许假装修好）
# 下面这批测试原本被一个一直没关的 if(WIN32) 守卫挡在 macOS 之外——实测 build-mac 里连
# test_library 目标都不存在，而注释明写着「macOS 也跑」。本轮删掉守卫、把它们移到跨平台
# 区域后，用真实构建（不是 -fsyntax-only）逐目标 `cmake --build --target <t>` 实测了 17 条：
#
#   ✅ 编译且运行通过（8 条）：test_library、test_scanpool、test_dsd_reader、test_dsd_path、
#      test_metastore、test_entities、test_dsd_two_stage、test_render_loop_dry
#      —— 这 8 条只缺 POSIX 垫片，wp-d2-tests 补完后即可直接打开，无需再改本文件。
#   ⚠️ 编译通过但运行 FAIL（2 条，**不是平台问题**）：
#      test_writeback / test_media_duration —— 失败真因是本机 Homebrew ffmpeg 坏链
#      （libx265 缺失，`ffmpeg -version` 退出码 134，项目开发铁律 §1 已记录）。测试本身
#      判据正确（「ffmpeg 造 1s 正弦 FLAC」rc=134），换到 ffmpeg 正常的环境即可。
#   ❌ 编译失败（7 条）：
#      windows.h  → test_hotfix_guard、test_renderfail、test_decode_retry、test_stream_decode、
#                   make_dsd、dsdconv
#      MAX_PATH   → test_ffmpeg_matrix（另缺 DWORD/SearchPathW/GetCurrentProcessId）
#
# ⚠️ 勘误：上一轮用 `clang -fsyntax-only` 预判「17 条里只有 2 条能编过」是**错的**——
# 该方式没带 CMake 的 include 路径与 -D 定义，把 6 条本可编译的测试误判为失败。
# 上面的清单以真实构建为准。
#
# 因此用这个开关把整块包起来，默认 OFF（与改造前行为一致：macOS 上仍不构建这些目标，
# 不把 macOS 构建打红）。等 wp-d2-tests 把 platform/console.h + path.h 的 POSIX 等价实现
# 补进来后，由主控统一 -DRTA_BUILD_LEGACY_TESTS=ON 打开。
# ---------------- 2026-10-25 平台移植：原先被 if(WIN32) 挡住、现已移植到 macOS ----------------
# 这三条原本依赖 Windows 独占语义，随「Windows 部分彻底删除」被暂时挡在守卫外。
# 按用户铁律「功能不能删除，只做全量移植」，它们的能力已全部在 macOS 侧实现：
#   renderfail   —— ZeroAttrib 归因本体提取到 audio/write_attrib.h（跨平台），
#                   CoreAudioOutput 补了 zero_pad_full/zero_starved/last_zero_reason
#   hotfix_guard —— FormatProbe/OpenFail 提取到 audio/write_attrib.h，
#                   CoreAudioOutput 补了 probe_formats()
#   decode_retry —— 独占占用故障态改为 POSIX 等价的 EACCES（chmod 000），
#                   进程快照改 sysctl KERN_PROC_ALL，素材改零依赖手写 FLAC
# 三者均已实测实跑全绿，故放进常规测试区（不再受 RTA_BUILD_LEGACY_TESTS 控制）。
add_executable(test_hotfix_guard tests/test_hotfix_guard.cpp)
target_include_directories(test_hotfix_guard PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_hotfix_guard PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME hotfix_guard COMMAND test_hotfix_guard)

add_executable(test_renderfail tests/test_renderfail.cpp)
target_include_directories(test_renderfail PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_renderfail PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME renderfail COMMAND test_renderfail)

add_executable(test_decode_retry tests/test_decode_retry.cpp)
target_include_directories(test_decode_retry PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_decode_retry PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME decode_retry COMMAND test_decode_retry)

# stream_decode：流式读取 ffmpeg 输出（免临时 WAV，ROADMAP P6b）
# 2026-10-25：POSIX 侧原本未移植（is_stream_decode_enabled 恒 false）。
# 按用户铁律「功能不能删除，只做全量移植」，已用 pipe()+poll() 实现等价路径，
# 实测逐位一致 + 回退路径均通过，故放进常规测试区。
add_executable(test_stream_decode tests/test_stream_decode.cpp)
target_include_directories(test_stream_decode PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_stream_decode PRIVATE rtadsp)
add_test(NAME stream_decode COMMAND test_stream_decode)

# ---------------- 2026-10-25 平台移植：从 RTA_BUILD_LEGACY_TESTS 开关移出 ----------------
# 这些测试原本因缺 POSIX 垫片被挡在开关内（默认 OFF ⟹ mac 上根本不构建）。
# 现在 tests/test_compat_posix.h 已补齐垫片，实测全部可编译且实跑通过，故放进常规区。
# 逐条实测结果见 PLATFORM.md §13.15.3。
add_executable(test_dsd_path tests/test_dsd_path.cpp)
target_link_libraries(test_dsd_path PRIVATE rtadsp)
add_test(NAME dsd_path COMMAND test_dsd_path)
add_executable(test_dsd_reader tests/test_dsd_reader.cpp)
target_link_libraries(test_dsd_reader PRIVATE rtadsp)
add_test(NAME dsd_reader COMMAND test_dsd_reader)
# 1.1.2 P0-3：DSD 抽取目标采样率必须按 44.1k / 48k **族**取上限。
# 旧实现一律 705600 ⟹ 48k 族 DSD256(12.288M) 不能整除，直接播不了。
# 1.1.2 AirPlay 投放基础件：ALAC 编码回环逐样本一致 + RAOP 发现/TXT 解析对抗用例
add_executable(test_alac_encoder tests/test_alac_encoder.cpp)
target_include_directories(test_alac_encoder PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_alac_encoder PRIVATE "-framework AudioToolbox" "-framework CoreFoundation")
add_test(NAME alac_encoder COMMAND test_alac_encoder)

add_executable(test_airplay_discovery tests/test_airplay_discovery.cpp)
target_include_directories(test_airplay_discovery PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME airplay_discovery COMMAND test_airplay_discovery)

add_executable(test_cast_audio tests/test_cast_audio.cpp)
target_include_directories(test_cast_audio PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME cast_audio COMMAND test_cast_audio)
set_tests_properties(cast_audio PROPERTIES TIMEOUT 60)

# AirPlay 发送端「源 PCM → 网络包」逐位一致：用 FFmpeg 的 ALAC 解码器做独立交叉验证
# （不能用 Apple 编码器 + Apple 解码器自证）。没装 ffmpeg 时该用例明确 SKIP，不冒充通过。
add_executable(test_cast_bit_exact tests/test_cast_bit_exact.cpp)
target_include_directories(test_cast_bit_exact PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_cast_bit_exact PRIVATE "-framework AudioToolbox" "-framework CoreFoundation")
add_test(NAME cast_bit_exact COMMAND test_cast_bit_exact)
set_tests_properties(cast_bit_exact PROPERTIES TIMEOUT 60)

# 1.1.2 AirPlay UI：用 Node 的 vm 直接跑 ui_script.h 的生产逻辑（不复制逻辑）
find_program(NODE_EXECUTABLE node)
if(NODE_EXECUTABLE)
  add_test(NAME airplay_ui COMMAND ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/test_airplay_ui.js)
  set_tests_properties(airplay_ui PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 30)
  add_test(NAME cast_ui COMMAND ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/test_cast_ui.js)
  set_tests_properties(cast_ui PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 30)
  add_test(NAME cast_contract COMMAND ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/check_cast_contract.js)
  set_tests_properties(cast_contract PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 30)
  # 1.1.3 LLM 模型下拉：有列表 → 下拉标「（当前）」；拉不到 → 手填降级且不改配置；
  # 选中 → POST /api/llm model=… 。全部 mock fetch，绝不连真实网关。
  add_test(NAME llm_ui COMMAND ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/test_llm_ui.js)
  set_tests_properties(llm_ui PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 30)
  # 1.1.4-beta10：合作艺术家拆分 / 艺术家卡简介 / 首页艺术家归属 —— 纯逻辑，不需要浏览器
  # （本机规则：不要自起浏览器进程；能离线证明的先证明，几何量测改为 ego 页面内自检）
  add_test(NAME b10_logic COMMAND ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/check_b10_logic.js)
  set_tests_properties(b10_logic PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 30)
  # 1.1.5-beta2：UI 资料检索契约（album/file 传参、knowledge 轮询单飞、资料不足态）——纯逻辑
  add_test(NAME retrieval_ui COMMAND ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/check_115_logic.js)
  set_tests_properties(retrieval_ui PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 30)
endif()

# i18n 门禁：docs/i18n/*.en.tsv → src/net/i18n_table.h 必须与生成物一致
#（计划书 §7.2.4 要求 --check 通过；把它变成常驻测试，避免"改了文案忘了重生成"）
find_program(PYTHON3_EXECUTABLE python3)
if(PYTHON3_EXECUTABLE)
  add_test(NAME i18n_table_check
           COMMAND ${PYTHON3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/gen_i18n_table.py --check)
  set_tests_properties(i18n_table_check PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 60)
  # 原生 UI 词表同步：tools/native_ui/RLPNativeI18n.mm 由 gen_native_i18n.py 生成，
  # 改过 docs/i18n 却忘了重生成时英文界面会回落中文（2026-11-14 实测已漂移 2 条）。
  add_test(NAME native_i18n_table_check
           COMMAND ${PYTHON3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/gen_native_i18n.py --check)
  set_tests_properties(native_i18n_table_check PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 60)
  # 原生 UI 文案覆盖：源码里每个 RLPTr(@"中文") 都必须有英文译文。
  # 为什么不靠人眼：原生一路加控件，新增短文案很容易绕过词表（英文界面中英混排）。
  add_test(NAME native_i18n_coverage
           COMMAND ${PYTHON3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/check_native_i18n_coverage.py)
  set_tests_properties(native_i18n_coverage PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 60)
endif()

add_executable(test_raop_session tests/test_raop_session.cpp)
target_include_directories(test_raop_session PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_raop_session PRIVATE "-framework AudioToolbox" "-framework CoreFoundation")
add_test(NAME raop_session COMMAND test_raop_session)
# Loopback protocol tests must fail bounded instead of wedging a release run.
set_tests_properties(raop_session PROPERTIES TIMEOUT 60)

add_executable(test_dsd_decimate_rate tests/test_dsd_decimate_rate.cpp)
target_include_directories(test_dsd_decimate_rate PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME dsd_decimate_rate COMMAND test_dsd_decimate_rate)
add_executable(test_dsd_two_stage tests/test_dsd_two_stage.cpp)
target_include_directories(test_dsd_two_stage PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_dsd_two_stage PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME dsd_two_stage COMMAND test_dsd_two_stage)
add_executable(test_entities tests/test_entities.cpp)
target_include_directories(test_entities PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME entities COMMAND test_entities)
add_executable(test_library tests/test_library.cpp)
target_include_directories(test_library PRIVATE ${CMAKE_SOURCE_DIR}/src)
if(APPLE)
    target_link_libraries(test_library PRIVATE iconv)
endif()
add_test(NAME library COMMAND test_library)

# ---------------- 2026-10-26：库根绝对路径不变量 + --music-dir 写盘顺序（BUG 回归）----------------
# 用户报「点侧栏『文件夹』显示目录不存在」。根因链：--music-dir 处理早于 setenv(RLPLAYER_PORT)
# ⟹ 非默认实例把相对根 "./data" 写进**默认实例**的 rlplayer-library.conf ⟹ .app 双击 cwd=/
# ⟹ ./data 解析成 /data ⟹ /api/files 默认目录恒不存在。
# 判据：相对根被拒（含"绝对目录仍可加"的对照）、默认 conf 逐字节不被非默认实例改动、
#       /api/files 跳过坏根挑真实目录、显式坏 dir 的错误必须带路径。
add_executable(test_libroot_regress tests/test_libroot_regress.cpp)
target_include_directories(test_libroot_regress PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_libroot_regress PRIVATE ${RL_PLATFORM_LIBS})
if(APPLE)
    target_link_libraries(test_libroot_regress PRIVATE iconv)
endif()
add_test(NAME libroot_regress COMMAND test_libroot_regress)

add_executable(test_cue tests/test_cue.cpp)
target_include_directories(test_cue PRIVATE ${CMAKE_SOURCE_DIR}/src)
if(APPLE)
    target_link_libraries(test_cue PRIVATE iconv)
endif()
add_test(NAME cue COMMAND test_cue)
add_executable(test_tags_native tests/test_tags_native.cpp)
target_include_directories(test_tags_native PRIVATE ${CMAKE_SOURCE_DIR}/src)
if(APPLE)
    target_link_libraries(test_tags_native PRIVATE iconv)
endif()
add_test(NAME tags_native COMMAND test_tags_native)

# ---------------- 2026-10-26（debug/20261026-02）：上游 v1.5.2 移植 ----------------
# B-1 专辑封面多曲重试 + 1x1 占位图不当封面（上游 fb77a0b，mac 独立分支重写）
#   判据：首曲无图+次曲有图 ⟹ 返回真图；全无图 ⟹ ok=0（不是 67B 占位图）；负缓存不串味。
#   传 ${CMAKE_SOURCE_DIR} 用于定位 build-mac/ffmpeg-lite/ffmpeg（本机系统 ffmpeg 坏链）。
add_executable(test_album_cover tests/test_album_cover.cpp)
target_include_directories(test_album_cover PRIVATE ${CMAKE_SOURCE_DIR}/src)
if(APPLE)
    target_link_libraries(test_album_cover PRIVATE iconv)
endif()
add_test(NAME album_cover COMMAND test_album_cover ${CMAKE_SOURCE_DIR})
# 本地封面落盘（2026-11-01）后，任何调用 albumCover() 的用例都会写 covercache/embed。
# 这两个用例没有自带 setenv 隔离 ⟹ 在 ctest 里显式指到构建目录，绝不写用户
# ~/Library/Application Support/RLPlayer（实测未隔离时确实写进去了）。
set_tests_properties(album_cover PROPERTIES ENVIRONMENT
  "HOME=${CMAKE_BINARY_DIR}/test-env/album_cover/home;RLPLAYER_STATE_DIR=${CMAKE_BINARY_DIR}/test-env/album_cover/state;RLPLAYER_LIBRARY_DIR=${CMAKE_BINARY_DIR}/test-env/album_cover/library;RLPLAYER_COVER_DIR=${CMAKE_BINARY_DIR}/test-env/album_cover/covers")
set_tests_properties(library PROPERTIES ENVIRONMENT
  "HOME=${CMAKE_BINARY_DIR}/test-env/library/home;RLPLAYER_STATE_DIR=${CMAKE_BINARY_DIR}/test-env/library/state;RLPLAYER_LIBRARY_DIR=${CMAKE_BINARY_DIR}/test-env/library/library;RLPLAYER_COVER_DIR=${CMAKE_BINARY_DIR}/test-env/library/covers")

# Startup directory fingerprint and persistent local covers: isolated filesystem/process regressions.
add_executable(test_library_fingerprint tests/test_library_fingerprint.cpp)
target_include_directories(test_library_fingerprint PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_library_fingerprint PRIVATE iconv)
add_test(NAME library_fingerprint COMMAND test_library_fingerprint)
add_executable(test_library_probe_retry tests/test_library_probe_retry.cpp)
target_include_directories(test_library_probe_retry PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_library_probe_retry PRIVATE iconv)
add_test(NAME library_probe_retry COMMAND test_library_probe_retry)
add_executable(test_local_cover_cache tests/test_local_cover_cache.cpp)
target_include_directories(test_local_cover_cache PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_local_cover_cache PRIVATE iconv)
add_test(NAME local_cover_cache COMMAND test_local_cover_cache)
add_executable(test_http_response_state tests/test_http_response_state.cpp)
target_include_directories(test_http_response_state PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME http_response_state COMMAND test_http_response_state)

# F-1 封面抓取纯逻辑（上游 c41ce97 的 mac 重做）：目录穿越 / Dice 负向对照 / 图片头校验 / 负缓存过期。
#   判据全部离线（不联网、不开设备、不写用户目录），不需要 ffmpeg 与真实曲库。
#   include 路径要加 tools/ —— cover_fetch.h 在 tools/ 下（与 naa_discover.h 同一口径）。
add_executable(test_cover_fetch tests/test_cover_fetch.cpp)
target_include_directories(test_cover_fetch PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
add_test(NAME cover_fetch COMMAND test_cover_fetch)

# 1.1.4-beta9：封面缩略图（ImageIO 下采样 + 磁盘缓存 token 校验 + meta 指纹）。
# 判据全部离线自生成夹具（BMP -> JPEG），不依赖 ffmpeg/真实曲库；ENVIRONMENT 显式隔离，
# 绝不写用户 ~/Library/Application Support/RLPlayer 的封面缓存。
if(APPLE)
  add_executable(test_cover_thumb tests/test_cover_thumb.cpp ${RL_IMAGE_THUMB_SRC})
  target_include_directories(test_cover_thumb PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(test_cover_thumb PRIVATE ${RL_PLATFORM_LIBS} "-framework Foundation" ${RL_IMAGE_FRAMEWORKS})
  add_test(NAME cover_thumb COMMAND test_cover_thumb)
  set_tests_properties(cover_thumb PROPERTIES ENVIRONMENT
    "HOME=${CMAKE_BINARY_DIR}/test-env/cover_thumb/home;RLPLAYER_STATE_DIR=${CMAKE_BINARY_DIR}/test-env/cover_thumb/state;RLPLAYER_COVER_DIR=${CMAKE_BINARY_DIR}/test-env/cover_thumb/covers")
endif()

# F-2 音频体检（上游 8001dbb + 99dd012，mac 移植：health_store 文件 IO 按 POSIX 重写）
add_executable(test_dynamics tests/test_dynamics.cpp)
target_include_directories(test_dynamics PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME dynamics COMMAND test_dynamics)

add_executable(test_fake_lossless tests/test_fake_lossless.cpp)
target_include_directories(test_fake_lossless PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME fake_lossless COMMAND test_fake_lossless)
# ⚠️ 必须在 add_test 之后；PATH 指到 ffmpeg-lite（系统 ffmpeg 坏链，退出码 134）
set_tests_properties(fake_lossless PROPERTIES
  ENVIRONMENT "PATH=${CMAKE_SOURCE_DIR}/build-mac/ffmpeg-lite:/usr/bin:/bin:/usr/sbin:/sbin")

add_executable(test_track_health tests/test_track_health.cpp)
target_include_directories(test_track_health PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME track_health COMMAND test_track_health)

# F-3 房间校正 + 测量编排（上游 f26ca3d + 8d80e17，纯 header，零平台依赖）
add_executable(test_room_correction tests/test_room_correction.cpp)
target_include_directories(test_room_correction PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME room_correction COMMAND test_room_correction)

add_executable(test_room_measurement tests/test_room_measurement.cpp)
target_include_directories(test_room_measurement PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME room_measurement COMMAND test_room_measurement)

add_executable(rtahealth tools/rtahealth.cpp)
target_include_directories(rtahealth PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(rtahealth PRIVATE ${RL_PLATFORM_LIBS})

add_executable(test_metastore tests/test_metastore.cpp)
target_include_directories(test_metastore PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME metastore COMMAND test_metastore)
# test_enrich —— 原先随 Windows 专属段被整体删除（cmake 里只剩注释里的名字），
# 但它在 mac 上是**纯离线纯函数**测试（enrich_detail:: 里的决策逻辑，不发网络、不碰设备）。
# 2026-10-27（E-2）：封面候选链与收图判定的断言加在这里；不重新注册 == 加了没人跑的测试，
# 故按「功能不能删除」铁律把它放回常规测试区。实测：编译通过 + 全绿。
add_executable(test_enrich tests/test_enrich.cpp)
target_include_directories(test_enrich PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME enrich COMMAND test_enrich)

# ---------------- 2026-10-27 P1：上游分析类新模块（F-1 / F-2 / F-3 / F-6）----------------
# 这四条都是**纯离线**（不发网络、不开音频设备），按「功能不能删除」登记进常规测试区。
# 链接需求差异（实测得出，别想当然）：
#   · quality        —— 纯头文件，无需额外链接
#   · quality_ai     —— 走 platform/http.h（llm 调用）⟹ 需要 RL_PLATFORM_LIBS，
#                       否则 _curl_easy_init / SCDynamicStoreCopyProxies 一堆 undefined
#   · version_compare—— 同上
#   · replaygain / dsd_rate_convert —— 纯 DSP，无需额外链接
add_executable(test_quality tests/test_quality.cpp)
target_include_directories(test_quality PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME quality COMMAND test_quality)

add_executable(test_quality_ai tests/test_quality_ai.cpp)
target_include_directories(test_quality_ai PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_quality_ai PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME quality_ai COMMAND test_quality_ai)

add_executable(test_version_compare tests/test_version_compare.cpp)
target_include_directories(test_version_compare PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_version_compare PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME version_compare COMMAND test_version_compare)

add_executable(test_replaygain tests/test_replaygain.cpp)
target_include_directories(test_replaygain PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME replaygain COMMAND test_replaygain)

add_executable(test_dsd_rate_convert tests/test_dsd_rate_convert.cpp)
target_include_directories(test_dsd_rate_convert PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME dsd_rate_convert COMMAND test_dsd_rate_convert)

# F-7：诊断包脱敏（纯函数）。A 段故意保留旧实现作永久红基线，谁把 legacy 修好它就变红。
add_executable(test_feedback_redact tests/test_feedback_redact.cpp)
target_include_directories(test_feedback_redact PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME feedback_redact COMMAND test_feedback_redact)

# 2026-11-11：反馈接入 rlplayer.rainlain.com 后台的纯逻辑层（零网络 / 零磁盘 / 零 ObjC）。
# 判据：请求体字段与上限（字节不是字符）、JSON 转义往返、诊断 base64 往返、
#       响应解析（HTTP 200 + ok:false 必须判失败）、错误码→中文与可重试性、
#       幂等键格式、安装 ID 形态（宿主侧持久化另由 mac_transport/实机覆盖）。
add_executable(test_feedback_api tests/test_feedback_api.cpp)
target_include_directories(test_feedback_api PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME feedback_api COMMAND test_feedback_api)
add_executable(test_install_id tests/test_install_id.cpp)
target_include_directories(test_install_id PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME install_id COMMAND test_install_id)

# 1.1.7.1：随机播放排列（一轮不重复 / 重洗不立刻重复上一首 / 均匀性）。
add_executable(test_shuffle_order tests/test_shuffle_order.cpp)
target_include_directories(test_shuffle_order PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME shuffle_order COMMAND test_shuffle_order)

# 真实后台端到端（默认 SKIP，不联网；RLPLAYER_FEEDBACK_LIVE=1 才建单，结束自动删除）。
# 证明的是纯逻辑层证明不了的四件事：后台真的接受这份请求体、幂等重放同号、
# client 能取回诊断包且逐字节一致、7 天内自助删除可用。
add_executable(test_feedback_live tests/test_feedback_live.cpp)
target_include_directories(test_feedback_live PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_feedback_live PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME feedback_live COMMAND test_feedback_live)

# R-1：房间测量的 mac 传输层（CoreAudio）。
# §1 算法链零设备（默认跑）；§2/§3 真开设备需 RTA_ROOM_HW=1，§3 真出声还需 RTA_ROOM_AUDIBLE=1
# （铁律 1：扫频本质可闻，绝不默认播）。链接 process_tap_bridge.mm 是因为 CoreAudioInput
# 的 loopback 枚举引用了它的 C 接口。
add_executable(test_room_transport_coreaudio
               tests/test_room_transport_coreaudio.cpp
               src/platform/macos/process_tap_bridge.mm)
target_include_directories(test_room_transport_coreaudio PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_room_transport_coreaudio PRIVATE ${RL_PLATFORM_LIBS} "-framework Foundation")
add_test(NAME room_transport_coreaudio COMMAND test_room_transport_coreaudio)

add_executable(test_render_loop_dry tests/test_render_loop_dry.cpp)
target_link_libraries(test_render_loop_dry PRIVATE rtadsp)
add_test(NAME render_loop_dry COMMAND test_render_loop_dry)
add_executable(test_scanpool tests/test_scanpool.cpp)
target_include_directories(test_scanpool PRIVATE ${CMAKE_SOURCE_DIR}/src)
if(APPLE)
    target_link_libraries(test_scanpool PRIVATE iconv)
endif()
add_test(NAME scanpool COMMAND test_scanpool)
add_executable(test_media_duration tests/test_media_duration.cpp)
target_include_directories(test_media_duration PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME media_duration COMMAND test_media_duration)
add_executable(test_ffmpeg_matrix tests/test_ffmpeg_matrix.cpp)
target_include_directories(test_ffmpeg_matrix PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_definitions(test_ffmpeg_matrix PRIVATE RTA_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
add_test(NAME ffmpeg_matrix COMMAND test_ffmpeg_matrix)
add_executable(test_writeback tests/test_writeback.cpp)
target_include_directories(test_writeback PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME writeback COMMAND test_writeback)

# 2026-10-25（门禁基线修正）：这 4 条测试依赖 ffmpeg 造/解素材，而本机 PATH 里的
# Homebrew ffmpeg 是坏链（缺 libx265.216.dylib，`ffmpeg -version` 退出码 134），
# 导致它们长期假红（项目开发铁律 §1 已记录该环境事实）。
# 项目自建的 build-mac/ffmpeg-lite/ffmpeg 是可用的（实测 8.1.2，rc=0）。
# 用 ENVIRONMENT 把 ffmpeg-lite 放到 PATH 最前 —— 与 embedded_api 的既有手法一致，
# 不改变测试判据本身（判据强度不动，只修环境）。实测 4/4 全绿。
set(RL_FFMPEG_LITE_PATH "${CMAKE_SOURCE_DIR}/build-mac/ffmpeg-lite:/usr/bin:/bin:/usr/sbin:/sbin")
set_tests_properties(decode_retry stream_decode media_duration writeback tags_native PROPERTIES
  ENVIRONMENT "PATH=${RL_FFMPEG_LITE_PATH}")


# ---------------- 2026-10-25：UPnP / DLNA 投放（macOS 已全量 POSIX 移植）----------------
# 这两条原先被删掉的「Windows 专属测试段」注释里点名过（test_upnp_control / test_cast_service）。
# 按用户铁律「功能不能删除，只做全量移植」：upnp.h / upnp_control.h / cast_service.h 已完整
# POSIX 化（winsock→BSD socket、WinHTTP→libcurl），本轮实测两条在 macOS 上独立编译运行全绿：
#   test_upnp_control —— 含真实本地 HTTP 供源回环实测（端口 8910，Range 200/206/416 逐字节校验）
#   test_cast_service —— 投放会话编排 + 安全门禁（DSD 未开 DoP 必须拒绝）
# 真网 SSDP 探测仍是 opt-in（RTA_NET_TESTS=1），默认跳过，不打扰局域网。
add_executable(test_upnp_control tests/test_upnp_control.cpp)
target_include_directories(test_upnp_control PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_upnp_control PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME upnp_control COMMAND test_upnp_control)

# 2026-10-28（用户「UPnP 搜不到设备」）：发现链路专项回归。
# 判据 = 网卡选择 / 子网工具 / 回源地址 / 假设备端到端（广播 + 描述解析 + 去重 + 不假阳性）。
# 全程离线、绑内核临时端口（不碰 1900，不需要 root），**不打开任何音频设备**。
add_executable(test_upnp_discovery tests/test_upnp_discovery.cpp)
target_include_directories(test_upnp_discovery PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_upnp_discovery PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME upnp_discovery COMMAND test_upnp_discovery)

# 系统代理选择逻辑（2026-10-26）：libcurl 在 macOS 上不读系统代理 ⟹ 更新检查永远超时。
# 判据是**选择逻辑**本身（没代理必须直连、有代理必须走），与本机是否真开代理无关。
add_executable(test_system_proxy tests/test_system_proxy.cpp)
target_include_directories(test_system_proxy PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_system_proxy PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME system_proxy COMMAND test_system_proxy)

add_executable(test_cast_service tests/test_cast_service.cpp)
target_include_directories(test_cast_service PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_cast_service PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME cast_service COMMAND test_cast_service)
set_tests_properties(cast_service PROPERTIES TIMEOUT 90)

# Actual embedded dispatcher + loopback RAOP worker: no physical output.
add_executable(test_cast_status tests/test_cast_status.cpp ${RL_LOOPBACK_SRC} ${RL_IMAGE_THUMB_SRC})
target_include_directories(test_cast_status PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
target_link_libraries(test_cast_status PRIVATE rtadsp ${RL_PLATFORM_LIBS} "-framework Foundation" ${RL_IMAGE_FRAMEWORKS})
add_test(NAME cast_status COMMAND test_cast_status)
set_tests_properties(cast_status PROPERTIES TIMEOUT 45)

# ---------------- 2026-10-25：系统混音回环（Process Tap）----------------
# macOS 没有 WASAPI Loopback 那样的系统混音回环端点，官方机制是 macOS 14.2+ 的
# Process Tap（CATapDescription → AudioHardwareCreateProcessTap → private 聚合设备）。
# 纯 C++ 的 audio_in_coreaudio.h 无法直接 include ObjC 头，故拆出 process_tap_bridge.mm 薄包装。
# 判据（铁律 1：默认不碰任何物理设备，只做只读 enumerate）：
#   * enumerate_capture(false) 不含回环条目；enumerate_capture(true) 含且仅含一条
#   * 回环条目排在物理设备之前，id/name/mixRate/mixChannels/mixBits 契约正确
#   * open() 不存在的 deviceId 必须失败且 last_error() 非空（错误路径不许假装成功）
#   * 真开回环采集默认跳过，仅 RTA_LOOPBACK_TESTS=1 时执行
add_executable(test_loopback_capture tests/test_loopback_capture.cpp src/platform/macos/process_tap_bridge.mm)
target_include_directories(test_loopback_capture PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_loopback_capture PRIVATE ${RL_PLATFORM_LIBS} "-framework Foundation")
add_test(NAME loopback_capture COMMAND test_loopback_capture)

# ---------------- 2026-10-25：Apple Metal GPU 加速（librtagpu.dylib）----------------
# Windows 时代的 AMD HIP / NVIDIA CUDA / DX12 在 macOS 上都不存在；Apple Silicon 唯一的
# 通用计算接口是 Metal。本测试用 dlopen 加载 librtagpu.dylib（不链接），缺库时 [SKIP]。
# 判据：4 个导出符号齐全、rta_gpu_available()==1、卷积/升频与 CPU 双精度参考的
# 最大相对误差 < 1e-6、invalidate 前后结果严格一致。
# 构建 dylib：bash tools/build_gpu_metal_mac.sh（产物在仓库根 librtagpu.dylib）
add_executable(test_gpu_metal tests/test_gpu_metal.cpp)
target_include_directories(test_gpu_metal PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_gpu_metal PRIVATE ${CMAKE_DL_LIBS})
add_test(NAME gpu_metal COMMAND test_gpu_metal)
# dylib 定位：测试自己用 __FILE__ 反推仓库根（ctest 的 cwd 是 build-mac，不是仓库根），
# 不需要额外环境变量；也可 `test_gpu_metal <path-to-librtagpu.dylib>` 显式指定。

# ---------------- 2026-10-26：GPU 卷积逐块流式正确性（IR 拖尾丢失 BUG 回归）----------------
# 判据：δ@0/IR=65536/16×4096 必须每一块都有输出（修前只有第 0 块有，65410/65536 样点错，
#       相对 RMS −1.63 dB）；GPU 逐块 vs CPU StreamingConvolver ≤ −120 dB；换 IR 清历史；
#       irLen=1/2/512/1024/2048 边界；2 声道历史隔离；GPU 不可用回落 CPU 逐样点相同。
# 缺 librtagpu.dylib 时打印 [SKIP] 而非假绿（铁律 4）。
add_executable(test_gpu_conv_streaming tests/test_gpu_conv_streaming.cpp)
target_link_libraries(test_gpu_conv_streaming PRIVATE rtadsp)
add_test(NAME gpu_conv_streaming COMMAND test_gpu_conv_streaming)

# ---------------- 2026-10-26：GPU 精度实测（F-6，mac / Metal 口径）----------------
# 探针：手动跑，不进 ctest（打印整张矩阵，依赖本机 GPU；无卡机器 exit 2）
add_executable(gpu_precision tools/gpu_precision.cpp)
target_include_directories(gpu_precision PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(gpu_precision PRIVATE ${CMAKE_DL_LIBS})

# 门禁：把本机实测阈值固化（缺 dylib / GPU 不可用 → [SKIP] + return 0，不算失败）
add_executable(test_gpu_precision tests/test_gpu_precision.cpp)
target_include_directories(test_gpu_precision PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_gpu_precision PRIVATE ${CMAKE_DL_LIBS})
add_test(NAME gpu_precision COMMAND test_gpu_precision)

# ---------------- 2026-10-26：WebUi 传输层安全加固测试 ----------------
add_executable(test_webui_hardening tests/test_webui_hardening.cpp)
target_include_directories(test_webui_hardening PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_webui_hardening PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME webui_hardening COMMAND test_webui_hardening)

# ---------------- 2026-10-26：副作用端点 405 验证测试 ----------------
add_executable(test_net_405 tests/test_net_405.cpp)
target_include_directories(test_net_405 PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_net_405 PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME net_405 COMMAND test_net_405)

# ---------------- 2026-10-26：DeepSeek 客户端及用量并发记账测试 (A-4) ----------------
add_executable(test_metallm tests/test_metallm.cpp)
target_include_directories(test_metallm PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_metallm PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME metallm COMMAND test_metallm)

# ---------------- 大 DSD 流式解码（261024-06 #2 / B-5）----------------
add_executable(test_dsd_stream_decode tests/test_dsd_stream_decode.cpp)
target_include_directories(test_dsd_stream_decode PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_dsd_stream_decode PRIVATE rtadsp ${RL_PLATFORM_LIBS})
add_test(NAME dsd_stream_decode COMMAND test_dsd_stream_decode)

# ---------------- 三档官方推荐预设的决策纯函数（2026-10-25）----------------
# 只 include engine/preset_profiles.h：不开设备、不读文件 ⟹ 无声卡/无驱动也能跑。
# 探测侧（CoreAudio caps / DoP 载波推算）在 rtaweb 里，
# 由 GET /api/preset/caps 的实测输出验证 —— 探针与决策分开测，判据才不互相污染。
add_executable(test_preset_profiles tests/test_preset_profiles.cpp)
target_include_directories(test_preset_profiles PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME preset_profiles COMMAND test_preset_profiles)

# ---------------- 1.1.3：投放升频目标率决策（2026-11-04）----------------
# 纯头文件（src/audio/cast_upsample_plan.h）：表驱动断言「开关/上限/渲染器声明/同族约束/
# 非法输入/只升不降」的每一种组合，不开设备、不读文件、不碰网络。
add_executable(test_cast_upsample_plan tests/test_cast_upsample_plan.cpp)
target_include_directories(test_cast_upsample_plan PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME cast_upsample_plan COMMAND test_cast_upsample_plan)

# ---------------- 1.1.3：LLM 模型列表（2026-11-04）----------------
# 只测 src/meta/llm.h 的解析 / 缓存 / 脱敏：请求全部走 LlmConfig.transport 的 mock，
# 绝不连真实网关（用户 key 不进测试、不出网）。
add_executable(test_llm_models tests/test_llm_models.cpp)
target_include_directories(test_llm_models PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_llm_models PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME llm_models COMMAND test_llm_models)

# ---------------- 1.1.4-beta3：数据源可手动排序（2026-11-07）----------------
# 只测 src/meta/provider.h 的纯函数（默认顺序 / csv 解析 / 顺序生效），零网络。
add_executable(test_provider_order tests/test_provider_order.cpp)
target_include_directories(test_provider_order PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_provider_order PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME provider_order COMMAND test_provider_order)

# 1.1.4-beta4 联网检索端点（纯离线，零网络）
add_executable(test_search_endpoints tests/test_search_endpoints.cpp)
target_include_directories(test_search_endpoints PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_search_endpoints PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME search_endpoints COMMAND test_search_endpoints)

# 1.1.4-beta4 AI 辅助爬取封面歌词（纯离线，零网络）
add_executable(test_ai_fill tests/test_ai_fill.cpp)
target_include_directories(test_ai_fill PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_ai_fill PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME ai_fill COMMAND test_ai_fill)

option(RTA_BUILD_LEGACY_TESTS "构建尚未移植到 macOS 的旧测试（缺 POSIX 垫片，默认关闭）" OFF)
if(RTA_BUILD_LEGACY_TESTS)

# ---- 跨平台测试（macOS 也跑）----
# decide_route：bit-perfect 判定的唯一实现（PLATFORM.md §11.7 列为未做项，本轮补上）
# 满幅 PCM 走完整管线的稳定性（2026-10-21 现场"播几秒变噪音"回归）
# 元数据三件套（P0）：store / parse / llm —— 全离线（llm 只测纯函数链路与空 key 快速失败，不发网络）
# P1 精简 ffmpeg 的音频格式矩阵门禁（2026-10-22）：
# 用产品自己的 rta::audio::read_any 逐格式断言 rate/channels/frames/电平，样本由 ffmpeg
# 现场合成（−60 dBFS，不打开任何音频设备）。被测二进制是 build/ffmpeg-lite/（自建精简版）；
# 该目录不存在时打印 [SKIP] 不判失败（CI 云机没有 MSYS2，编不出精简版）。
# RTA_SOURCE_DIR 用于读取 tools/ffmpeg_lite_required.txt（与出包守卫同一份白名单）。
# 热修复守卫（HF-03 解码/临时WAV/分配加固 + HF-01/02 probe/OpenFail 地基）：全离线，不开设备

# WASAPI 共享后端（2026-10-22 VM 事故）：§1 纯离线（int32→float32 边界 / 可写帧数钳制），
# §2 设备 smoke 只写【数字静音】≤1 秒（输出先打印醒目横幅，铁律 1）

# 2026-10-24（N300 欠载方案 C4）：C1 缓冲策略 + C2/C3 遥测/端点消失，全部 mock 驱动，
# 绝不打开音频设备（铁律 1）。被测实现：src/audio/buffer_policy.h、src/audio/render_loop.h。
# 输出采样率选择纯逻辑（2026-10-22 事故：第二首 44.1k 按 44100 开流，因 rate=max 探测瞬时为空
# 被当成「跟随源率」）—— 全离线，不开设备（铁律 1）
# E-15: 古典 COMPOSER→Work 四层端到端（合成样本 + 真实批量入口）
# ffmpeg 解码失败归因 + 瞬时故障重试（反馈 20261022-01 现象 B：日文名 FLAC 间歇性
# "Illegal byte sequence" / 退出码 -42）。判据：-42 是 ffmpeg 在非 ASCII 路径上回退 ANSI
# 代码页后的【掩码】，真实原因必须由 Win32 探针给出（ERROR_SHARING_VIOLATION 等），
# 且瞬时占用释放后应自动重试成功。素材全在 %TEMP%（含日文名），不碰 MUSIC；不开音频设备。

# P3 资料层② 直连层：实体 -> 权威文本材料（维基/萌娘百科 + 缓存/离线回退 + 令牌桶限频/熔断）
add_executable(make_dsd tools/make_dsd.cpp)
target_link_libraries(make_dsd PRIVATE rtadsp)

# DSD 域转换：抽取 / DirectSDM / 信息（命令行闭环验证）
add_executable(dsdconv tools/dsdconv.cpp)
target_link_libraries(dsdconv PRIVATE rtadsp)

# WASAPI 采集核心（ROADMAP P4a）：环形缓冲 / 格式转换 / 离线分析 / --src null 门禁


# ---------------- 解码免临时 WAV（流式读 ffmpeg 输出，ROADMAP P6b） ----------------
# 2026-10-25：本条原在 Windows 守卫块里，但它是跨平台测试（任务书明确要求保留），
# 已移出守卫。⚠️ 实测它能编译并运行通过，只是依赖 windows.h 之外的垫片——
# 仍放在 RTA_BUILD_LEGACY_TESTS 开关内，等 wp-d2-tests 的 POSIX 垫片合并后随整块打开。
endif()   # RTA_BUILD_LEGACY_TESTS


