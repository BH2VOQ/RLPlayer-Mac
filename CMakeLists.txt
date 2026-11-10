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
  target_link_libraries(rlplayer_mac PRIVATE rlapp_core "-framework AppKit" "-framework WebKit")
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
foreach(_diag_test diag_bundle diag_http diag_questions rtadiag float_decode quality_edges health_store lyrics_cache ir_resample)
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
  target_link_libraries(test_mac_update PRIVATE ${RL_PLATFORM_LIBS} "-framework AppKit" "-framework Foundation")
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
  # （本机规则：禁止自起无头浏览器；能离线证明的先证明，几何量测改为侧边栏目视验收）
  add_test(NAME b10_logic COMMAND ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/check_b10_logic.js)
  set_tests_properties(b10_logic PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 30)
  # 1.1.5-beta2：UI 资料检索契约（album/file 传参、knowledge 轮询单飞、资料不足态）——纯逻辑
  add_test(NAME retrieval_ui COMMAND ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/check_115_logic.js)
  set_tests_properties(retrieval_ui PROPERTIES WORKING_DIRECTORY ${CMAKE_SOURCE_DIR} TIMEOUT 30)
endif()

# i18n 门禁：docs/i18n/*.en.tsv → src/net/i18n_table.h 必须与生成物一致