#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August
# 
# check_b8_safe_offline.py — B8 后台任务生命周期确定性离线测试与判据
#
# 验证目标：
#   1. 退出时必须确认所有 bg 任务归零再允许核心销毁，超时不能当成功；
#   2. metadata 和 summary 线程在收到退出信号 (g_shutdown) 后协作取消网络/耗时工作并快速归零；
#   3. 全离线测试：生成 1s 静音 WAV 素材（不依赖用户 Music 或外网）；
#   4. 启动本地慢 HTTP Mock 服务（延迟 8s 模拟慢元数据源与 LLM 检索）；
#   5. backend=null，音量 -60dB，不开物理音频设备（铁律 1：绝不出声）；
#   6. 验证退出时日志输出结构化指标：SHUTDOWN bg=0 inflight=0 waitMs=...，绝不虚报完成；
#   7. 验证整个退出收敛时间远小于 Mock 的 8s 延迟（<= 2.5s）。

import http.server
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import wave

PORT = 19188
MOCK_PORT = 19189
MAX_QUIT_SECONDS = 2.5


class SlowMockHandler(http.server.BaseHTTPRequestHandler):
    """模拟极慢的元数据源与 LLM 接口（延迟 8 秒或等待客户端主动断开）"""
    def log_message(self, format, *args):
        pass  # 静默测试输出

    def do_GET(self):
        self.handle_slow()

    def do_POST(self):
        self.handle_slow()

    def handle_slow(self):
        # 保持连接阻塞 8 秒，模拟慢网络/慢接口
        # 客户端如果发起了取消并断连，sleep 会在退出或被中断时结束
        slept = 0
        while slept < 80 and not getattr(self.server, "stop_requested", False):
            time.sleep(0.1)
            slept += 1
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(b'{"ok":true,"mock":true,"result":"slow_data"}')
        except Exception:
            pass  # 客户端主动取消或断开属于正常现象


def create_silence_wav(path: str, duration_sec: float = 1.0):
    sample_rate = 44100
    channels = 2
    sampwidth = 2
    n_frames = int(sample_rate * duration_sec)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(sampwidth)
        wf.setframerate(sample_rate)
        wf.writeframes(b"\x00" * (n_frames * channels * sampwidth))


def find_rtaweb_bin(base_dir: str) -> str:
    candidates = [
        os.path.join(base_dir, "build-mac", "rtaweb"),
        os.path.join(base_dir, "build", "rtaweb"),
        os.path.join(base_dir, "build-mac", "tools", "rtaweb"),
        "/tmp/rlw/i8/build-mac/rtaweb",
        "/Users/august/Downloads/DQ/RLPlayer/build-mac/rtaweb",
    ]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return ""


def main():
    print("================================================================")
    print("  B8 后台任务生命周期离线安全判据 (check_b8_safe_offline.py)")
    print("================================================================")

    base_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    rtaweb_bin = find_rtaweb_bin(base_dir)
    if not rtaweb_bin:
        print(f"ERROR: 找不到 rtaweb 可执行文件，请先构建或提供二进制路径", file=sys.stderr)
        return 2

    print(f"  使用二进制: {rtaweb_bin}")

    # 1. 启动本地慢 HTTP Mock 服务
    mock_server = http.server.ThreadingHTTPServer(("127.0.0.1", MOCK_PORT), SlowMockHandler)
    mock_server.stop_requested = False
    mock_thread = threading.Thread(target=mock_server.serve_forever, daemon=True)
    mock_thread.start()
    print(f"  慢 HTTP Mock 已启动: http://127.0.0.1:{MOCK_PORT}/ (延迟 8s)")

    # 2. 准备隔离测试沙箱
    tmp_dir = tempfile.mkdtemp(prefix="rlplayer_b8_safe_")
    lib_dir = os.path.join(tmp_dir, "lib")
    os.makedirs(lib_dir, exist_ok=True)

    wav_path = os.path.join(tmp_dir, "silence_1s.wav")
    create_silence_wav(wav_path, 1.0)
    print(f"  短静音 WAV 素材已生成: {wav_path} (时长: 1.0s, 44.1kHz 16-bit)")

    # 注入代理配置指向 Mock，使 rtaweb 所有的外部元数据/LLM 均走慢 Mock
    conf_path = os.path.join(tmp_dir, "rlplayer-llm.conf")
    with open(conf_path, "w", encoding="utf-8") as f:
        f.write(f"proxy=http://127.0.0.1:{MOCK_PORT}\n")

    # 3. 启动 rtaweb 实例
    env = os.environ.copy()
    env["RLPLAYER_STATE_DIR"] = tmp_dir
    env["RLPLAYER_LIBRARY_DIR"] = lib_dir
    env["RLPLAYER_PORT"] = str(PORT)

    log_path = os.path.join(tmp_dir, "rtaweb_stdout.log")
    log_file = open(log_path, "w", encoding="utf-8")

    server_proc = subprocess.Popen(
        [rtaweb_bin, "--port", str(PORT), "--no-browser"],
        stdout=log_file,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=tmp_dir,
    )

    try:
        # 等待服务器就绪
        ready = False
        api_settings_url = f"http://127.0.0.1:{PORT}/api/settings"
        for _ in range(50):
            try:
                with urllib.request.urlopen(api_settings_url, timeout=0.2) as resp:
                    if resp.status == 200:
                        ready = True
                        break
            except Exception:
                time.sleep(0.1)

        if not ready:
            print("ERROR: rtaweb 未能在 5 秒内就绪", file=sys.stderr)
            return 1

        print("  rtaweb 实例就绪，开始配置测试参数...")

        # 4. 配置 backend=null 与 metaon=1, metasummary=1
        set_data = urllib.parse.urlencode({"backend": "null", "metaon": "1", "metasummary": "1"}).encode("utf-8")
        req = urllib.request.Request(api_settings_url, data=set_data, method="POST")
        with urllib.request.urlopen(req, timeout=3.0) as resp:
            assert resp.status == 200

        # 5. 触发播放静音文件（发起后台元数据补全 meta_on_play）
        play_url = f"http://127.0.0.1:{PORT}/api/play"
        play_data = urllib.parse.urlencode({
            "file": wav_path,
            "volume": "-60.0",
            "backend": "null",
        }).encode("utf-8")
        req_play = urllib.request.Request(play_url, data=play_data, method="POST")
        with urllib.request.urlopen(req_play, timeout=3.0) as resp:
            play_res = json.loads(resp.read().decode("utf-8"))
            print(f"  /api/play 响应: {play_res}")

        # 6. 同时触发 summary 异步后台整理任务 (kind=person)
        summary_url = f"http://127.0.0.1:{PORT}/api/entity/summary?kind=person&name=OfflineSlowArtist"
        try:
            with urllib.request.urlopen(summary_url, timeout=3.0) as resp:
                summ_res = json.loads(resp.read().decode("utf-8"))
                print(f"  /api/entity/summary 响应: {summ_res}")
        except Exception as e:
            print(f"  /api/entity/summary 调用异常: {e}")

        # 等待 0.5s 让后台任务切实挂起在网络连接上
        time.sleep(0.5)

        # 7. 记录 T0 并发送 SIGTERM 触发优雅退出
        print("  发送 SIGTERM 触发优雅收尾...")
        t0 = time.time()
        server_proc.send_signal(signal.SIGTERM)

        # 8. 等待进程完全退出
        try:
            ret = server_proc.wait(timeout=10.0)
            t1 = time.time()
            elapsed = t1 - t0
        except subprocess.TimeoutExpired:
            server_proc.kill()
            server_proc.wait()
            print("FAIL: rtaweb 进程在 10s 内未退出（死锁或未正常响应退出信号）")
            return 1

        print(f"  进程退出耗时: {elapsed:.3f}s (退出码: {ret})")

        # 9. 检查日志与指标
        playback_log_path = os.path.join(tmp_dir, "rlplayer-playback.log")
        shutdown_metric_found = False
        shutdown_all_done_found = False
        shutdown_joinable_found = False

        if os.path.isfile(playback_log_path):
            with open(playback_log_path, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if "SHUTDOWN joinable:" in line:
                        shutdown_joinable_found = True
                    if "SHUTDOWN bg=0 inflight=0" in line:
                        shutdown_metric_found = True
                        print(f"  捕获结构化指标行: {line.strip()}")
                    if "SHUTDOWN 后台任务已全部收完" in line:
                        shutdown_all_done_found = True

        print(f"  指标核验:")
        print(f"    - SHUTDOWN joinable 日志存在: {shutdown_joinable_found}")
        print(f"    - SHUTDOWN bg=0 inflight=0 结构化指标存在: {shutdown_metric_found}")
        print(f"    - SHUTDOWN 后台任务已全部收完 日志存在: {shutdown_all_done_found}")
        print(f"    - 退出耗时 ({elapsed:.3f}s) <= 预算上限 ({MAX_QUIT_SECONDS}s): {elapsed <= MAX_QUIT_SECONDS}")

        if ret != 0:
            print(f"FAIL: 进程退出码非 0: {ret}")
            return 1

        if not shutdown_metric_found:
            print("FAIL: 日志中未找到 SHUTDOWN bg=0 inflight=0 确认归零指标")
            return 1

        if elapsed > MAX_QUIT_SECONDS:
            print(f"FAIL: 退出时间超时 ({elapsed:.3f}s > {MAX_QUIT_SECONDS}s)")
            return 1

        print("================================================================")
        print("  RESULT: PASS (所有后台任务均确认归零，无 UAF 风险，快速退出)")
        print("================================================================")
        return 0

    finally:
        log_file.close()
        mock_server.stop_requested = True
        mock_server.shutdown()
        mock_server.server_close()


if __name__ == "__main__":
    sys.exit(main())
