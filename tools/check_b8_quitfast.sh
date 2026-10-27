#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August
# 判据脚本：验证 RLPlayer 播放触发后台元数据补全时，退出能否在 1.5 秒内协作收尾（check_b8_quitfast.sh）
# 判据来源：用户反馈「关闭软件的时候很卡顿」，主控实测定位根因为后台元数据补全在退出时未协作取消并无脑等待5秒。
# 判定标准：elapsed <= 1.5s -> PASS，否则 FAIL。

set -u

PORT=19108
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${BASE_DIR}/debug/20261027-04-实测反馈7条/b8-quitfast/run"
BIN="${BASE_DIR}/build-mac/rtaweb"
TARGET_AIFF="/Users/august/Music/Music/Media.localized/Music/LOSE/爱上火车OST/原野绽芳华.aiff"
MAX_ELAPSED=1.5

if [ ! -x "$BIN" ]; then
    echo "ERROR: $BIN 不存在或不可执行，请先构建" >&2
    exit 1
fi

if [ ! -f "$TARGET_AIFF" ]; then
    echo "ERROR: 测试音频不存在: $TARGET_AIFF" >&2
    exit 1
fi

# 确保端口无残留
PID_ON_PORT=$(lsof -nP -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null || true)
if [ -n "$PID_ON_PORT" ]; then
    echo "ERROR: 端口 ${PORT} 已被占用 (PID: $PID_ON_PORT)，退出以保护进程" >&2
    exit 1
fi

# 清理并创建隔离状态目录
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"

LOG_FILE="${RUN_DIR}/rtaweb.log"

export RLPLAYER_STATE_DIR="$RUN_DIR"
export RLPLAYER_LIBRARY_DIR="${RUN_DIR}/lib"
mkdir -p "$RLPLAYER_LIBRARY_DIR"

"$BIN" --port "$PORT" --no-browser > "$LOG_FILE" 2>&1 &
SERVER_PID=$!

cleanup() {
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# 等待 /api/settings 可用（最多等 5s）
READY=0
for i in $(seq 1 50); do
    if curl -s -f "http://127.0.0.1:${PORT}/api/settings" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 0.1
done

if [ "$READY" -ne 1 ]; then
    echo "ERROR: rtaweb 未能在 5s 内就绪，查看日志:" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

# 设置 backend=null（铁律 1：绝不出声）与 metaon=1
curl -s -X POST "http://127.0.0.1:${PORT}/api/settings" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "backend=null&metaon=1" >/dev/null

# 播放指定的 aiff（form 格式，volume=-60, backend=null）
PLAY_FORM=$(python3 -c "import urllib.parse; print(urllib.parse.urlencode({'file': '$TARGET_AIFF', 'volume': -60.0, 'backend': 'null'}))")
PLAY_RESP=$(curl -s -X POST "http://127.0.0.1:${PORT}/api/play" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "$PLAY_FORM")
echo "PLAY_RESP: $PLAY_RESP"

# 等待 2 秒让元数据补全后台任务跑起来
sleep 2

# 记录 T0 并发送 SIGTERM
T0=$(python3 -c "import time; print(time.time())")
kill -TERM "$SERVER_PID"

# 轮询直到进程消失
while kill -0 "$SERVER_PID" 2>/dev/null; do
    sleep 0.05
done
T1=$(python3 -c "import time; print(time.time())")

# 取消 trap 中的 cleanup（因为已经退出了）
trap - EXIT INT TERM

ELAPSED=$(python3 -c "print(f'{$T1 - $T0:.3f}')")
echo "ELAPSED: ${ELAPSED}s"

echo "--- SHUTDOWN 日志片段 ---"
grep "SHUTDOWN" "${RUN_DIR}/rlplayer-playback.log" | tail -n 5 || true
echo "-------------------------"

PASS=$(python3 -c "print(1 if float('$ELAPSED') <= $MAX_ELAPSED else 0)")
if [ "$PASS" -eq 1 ]; then
    echo "RESULT: PASS (elapsed: ${ELAPSED}s <= ${MAX_ELAPSED}s)"
    exit 0
else
    echo "RESULT: FAIL (elapsed: ${ELAPSED}s > ${MAX_ELAPSED}s)"
    exit 1
fi
