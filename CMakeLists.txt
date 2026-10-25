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
set(RL_PLATFORM_LIBS curl
    "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreFoundation")

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
if(APPLE)
  # 2026-10-25（系统混音回环）：Process Tap 是 ObjC++ 门控（CATapDescription /
  # AudioHardwareCreateProcessTap 只在 __OBJC__ 下可见），拆成薄包装给纯 C++ 的
  # audio_in_coreaudio.h 用。rlapp_core 通过 #include "rtaweb.cpp" 共享同一份业务代码，
  # 所以这个 .mm 必须进 rlapp_core 的源列表，否则 App 侧会缺符号。
  enable_language(OBJCXX)
  set(RL_LOOPBACK_SRC src/platform/macos/process_tap_bridge.mm)
  set_source_files_properties(${RL_LOOPBACK_SRC} PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

  add_library(rlapp_core STATIC tools/rlapp_core.cpp ${RL_LOOPBACK_SRC})
  target_include_directories(rlapp_core PUBLIC ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
  target_link_libraries(rlapp_core PUBLIC ${RL_PLATFORM_LIBS} "-framework Foundation")

  add_executable(rtaweb tools/rtaweb.cpp ${RL_LOOPBACK_SRC})
  target_include_directories(rtaweb PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_link_libraries(rtaweb PRIVATE ${RL_PLATFORM_LIBS} "-framework Foundation")

  # macOS 原生壳（§9 第 9 条 / §10 契约）：单进程内直连 |rlapp::dispatch|。
  # mac_host.mm 用 ARC 语义（WKURLSchemeTask/block 对象生命周期不能被 MRR 误释放）。
  # 实测未开 ARC 时在 startURLSchemeTask 的 objc_msgSend 崩 SIGSEGV，开 ARC 后同场景通过。
  add_executable(rlplayer_mac tools/mac_host.mm)
  set_source_files_properties(tools/mac_host.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_link_libraries(rlplayer_mac PRIVATE rlapp_core "-framework AppKit" "-framework WebKit")
endif()

# ---------------- 测试 ----------------
enable_testing()

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
  add_test(NAME embedded_api COMMAND test_embedded_api)
  set_tests_properties(embedded_api PROPERTIES
    ENVIRONMENT "PATH=${CMAKE_SOURCE_DIR}/build-mac/ffmpeg-lite:/usr/bin:/bin:/usr/sbin:/sbin")
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

add_executable(test_host_msg tests/test_host_msg.cpp)
target_link_libraries(test_host_msg PRIVATE rtadsp)
add_test(NAME host_msg COMMAND test_host_msg)

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
add_executable(test_eq_reload tests/test_eq_reload.cpp ${RL_LOOPBACK_SRC})
target_include_directories(test_eq_reload PRIVATE ${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/tools)
target_link_libraries(test_eq_reload PRIVATE rtadsp ${RL_PLATFORM_LIBS} "-framework Foundation")
add_test(NAME eq_reload COMMAND test_eq_reload)

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
# 归一化与 id 是纯函数；落盘到 %TEMP%；真实曲库样本只读 D:\RLPlayer\MUSIC
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
#      （libx265 缺失，`ffmpeg -version` 退出码 134，AGENTS.md §1 已记录）。测试本身
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
add_executable(test_dsd_two_stage tests/test_dsd_two_stage.cpp)
target_include_directories(test_dsd_two_stage PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_dsd_two_stage PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME dsd_two_stage COMMAND test_dsd_two_stage)
add_executable(test_entities tests/test_entities.cpp)
target_include_directories(test_entities PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME entities COMMAND test_entities)
add_executable(test_library tests/test_library.cpp)
target_include_directories(test_library PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME library COMMAND test_library)
add_executable(test_tags_native tests/test_tags_native.cpp)
target_include_directories(test_tags_native PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME tags_native COMMAND test_tags_native)
add_executable(test_metastore tests/test_metastore.cpp)
target_include_directories(test_metastore PRIVATE ${CMAKE_SOURCE_DIR}/src)
add_test(NAME metastore COMMAND test_metastore)
add_executable(test_render_loop_dry tests/test_render_loop_dry.cpp)
target_link_libraries(test_render_loop_dry PRIVATE rtadsp)
add_test(NAME render_loop_dry COMMAND test_render_loop_dry)
add_executable(test_scanpool tests/test_scanpool.cpp)
target_include_directories(test_scanpool PRIVATE ${CMAKE_SOURCE_DIR}/src)
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
# 导致它们长期假红（AGENTS.md §1 已记录该环境事实）。
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

add_executable(test_cast_service tests/test_cast_service.cpp)
target_include_directories(test_cast_service PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(test_cast_service PRIVATE ${RL_PLATFORM_LIBS})
add_test(NAME cast_service COMMAND test_cast_service)

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
