# 判据：.app 默认主可执行必须是 rlplayer_native（原生版为默认与最终形态）。
# 用户 2026-11-15 原话「默认开原生版 原生版是要替代 web 版的」；web 版只作显式对照。
# 走 tools/make_app_mac.sh 的只读自省入口，不打包、不写任何文件。
set(SCRIPT "${CMAKE_CURRENT_LIST_DIR}/../tools/make_app_mac.sh")

function(run_probe var)
  execute_process(COMMAND /bin/zsh "${SCRIPT}" --print-default-bin
    OUTPUT_VARIABLE got OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE rc)
  set(${var} "${got}" PARENT_SCOPE)
  set(${var}_RC "${rc}" PARENT_SCOPE)
endfunction()

run_probe(DEFAULT_BIN)
set(ENV{RL_WEB_APP} "1")
run_probe(WEB_BIN)
unset(ENV{RL_WEB_APP})
set(ENV{RL_NATIVE_APP} "1")
run_probe(NATIVE_BIN)
unset(ENV{RL_NATIVE_APP})

if(NOT DEFAULT_BIN_RC EQUAL 0 OR NOT DEFAULT_BIN STREQUAL "rlplayer_native")
  message(FATAL_ERROR "默认主可执行应为 rlplayer_native，实际 '${DEFAULT_BIN}' rc=${DEFAULT_BIN_RC}")
endif()
if(NOT WEB_BIN_RC EQUAL 0 OR NOT WEB_BIN STREQUAL "rlplayer_mac")
  message(FATAL_ERROR "RL_WEB_APP=1 应出 web 对照包 rlplayer_mac，实际 '${WEB_BIN}' rc=${WEB_BIN_RC}")
endif()
if(NOT NATIVE_BIN_RC EQUAL 0 OR NOT NATIVE_BIN STREQUAL "rlplayer_native")
  message(FATAL_ERROR "RL_NATIVE_APP=1 兼容用法仍应为 rlplayer_native，实际 '${NATIVE_BIN}' rc=${NATIVE_BIN_RC}")
endif()
message(STATUS "native default app: default=${DEFAULT_BIN} web=${WEB_BIN} native-flag=${NATIVE_BIN} OK")
