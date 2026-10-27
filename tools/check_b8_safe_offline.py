#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 August
# 
# check_b8_safe_offline.py — B8 后台任务生命周期确定性离线安全判据
#
# 验证目标：
#   1. 退出时必须确认所有 bg 任务归零再允许核心销毁，超时不能当成功；
#   2. metadata 和 summary 线程在收到退出信号 (g_shutdown) 后协作取消网络/耗时工作并快速归零；
#   3. 全离线测试：生成 2.0s 静音 WAV 素材（不依赖用户 Music 或外网）；
#   4. 启动本地慢 HTTP Mock 服务（支持 GET/POST/CONNECT，延迟 8s 模拟慢元数据源与 LLM 检索）；
#   5. backend=null，音量 -60dB，空 music 根，不开物理音频设备（铁律 1：绝不出声）；
#   6. 证明至少 1 个真实网络请求到达并挂在 8s 慢服务器后才发送 SIGTERM；
#   7. 验证退出时日志输出结构化指标：SHUTDOWN bg=0 inflight=0 waitMs=...，且不含未收完告警，绝不虚报完成；
#   8. 验证整个退出收敛时间远小于 Mock 的 8s 延迟 (<= 2.5s)；
#   9. 遵循铁律：绝不 process.kill / kill9 / 强杀，超时只报告不 kill；
#  10. 严格隔离：空 music 根 + state/lib 全隔离 (.p19188 隔离区)；
#  11. 二进制查找明确：仅接受 --binary 参数或本 worktree build-mac/rtaweb，禁 fallback 别 worktree。

import argparse
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

DEFAULT_PORT = 19188
DEFAULT_MOCK_PORT = 19189
MAX_QUIT_SECONDS = 2.5


class SlowMockHandler(http.server.BaseHTTPRequestHandler):
    """模拟极慢的元数据源与 LLM 接口（延迟 8 秒或等待客户端主动断开）"""
    def log_message(self, format, *args):
        pass  # 静默测试输出

    def do_CONNECT(self):
        self.handle_slow(is_connect=True)

    def do_GET(self):
        self.handle_slow(is_connect=False)

    def do_POST(self):
        self.handle_slow(is_connect=False)

    def handle_slow(self, is_connect: bool = False):
        try:
            with self.server.lock:
                self.server.request_count += 1
                req_desc = f"{self.command} {self.path}"
                self.server.request_log.append(req_desc)
                self.server.request_event.set()
            print(f"  [Mock] 捕获网络请求 #{self.server.request_count}: {self.command} {self.path}，挂起 8s 模拟慢服务器...")
        except Exception:
            pass

        slept = 0
        while slept < 80 and not getattr(self.server, "stop_requested", False):
            time.sleep(0.1)
            slept += 1

        try:
            if is_connect:
                self.send_response(200, "Connection Established")
                self.end_headers()
            else:
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.end_headers()
                self.wfile.write(b'{"ok":true,"mock":true,"result":"slow_data"}')
        except Exception:
            pass  # 客户端在挂起期间断连或取消属于正常预期


def create_silence_wav(path: str, duration_sec: float = 2.0):
    sample_rate = 44100
    channels = 2
    sampwidth = 2
    n_frames = int(sample_rate * duration_sec)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(sampwidth)
        wf.setframerate(sample_rate)
        wf.writeframes(b"\x00" * (n_frames * channels * sampwidth))


def find_rtaweb_bin(base_dir: str, binary_arg: str = None) -> str:
    if binary_arg:
        p = os.path.abspath(binary_arg)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
        print(f"ERROR: 指定的 --binary 参数不存在或不可执行: {binary_arg}", file=sys.stderr)
        return ""

    # 严禁 fallback 别的 worktree，只查找本 worktree 构建目录
    candidates = [
        os.path.join(base_dir, "build-mac", "rtaweb"),
        os.path.join(base_dir, "build", "rtaweb"),
        os.path.join(base_dir, "build-mac", "tools", "rtaweb"),
    ]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return ""


def main():
    parser = argparse.ArgumentParser(description="B8 后台任务生命周期离线安全判据")
    parser.add_argument("--binary", help="指定 rtaweb 可执行文件路径")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"rtaweb 服务端口 (默认 {DEFAULT_PORT})")
    parser.add_argument("--mock-port", type=int, default=DEFAULT_MOCK_PORT, help=f"慢 HTTP Mock 端口 (默认 {DEFAULT_MOCK_PORT})")
    args = parser.parse_args()

    port = args.port
    mock_port = args.mock_port

    print("================================================================")
    print("  B8 后台任务生命周期离线安全判据 (check_b8_safe_offline.py)")
    print("================================================================")

    base_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    rtaweb_bin = find_rtaweb_bin(base_dir, args.binary)
    if not rtaweb_bin:
        print("ERROR: 找不到 rtaweb 可执行文件（已检查本 worktree 构建目录，禁止跨 worktree 回退）。请使用 --binary 指定或先构建本工程。", file=sys.stderr)
        return 2

    print(f"  使用二进制: {rtaweb_bin}")

    # 1. 启动本地慢 HTTP Mock 服务（支持 GET/POST/CONNECT 并在首个请求到达时通知 Event）
    try:
        mock_server = http.server.ThreadingHTTPServer(("127.0.0.1", mock_port), SlowMockHandler)
    except Exception as e:
        print(f"ERROR: 启动本地慢 HTTP Mock 失败 (端口 {mock_port}): {e}", file=sys.stderr)
        return 2

    mock_server.daemon_threads = True
    mock_server.stop_requested = False
    mock_server.lock = threading.Lock()
    mock_server.request_count = 0
    mock_server.request_log = []
    mock_server.request_event = threading.Event()

    mock_thread = threading.Thread(target=mock_server.serve_forever, daemon=True)
    mock_thread.start()
    print(f"  慢 HTTP Mock 已启动: http://127.0.0.1:{mock_port}/ (支持 GET/POST/CONNECT, 延迟 8s)")

    # 2. 准备隔离测试沙箱（.p{port} 全隔离：空 music 根，独立 state_dir 与 lib_dir）
    tmp_root = tempfile.mkdtemp(prefix=f"rlplayer_b8_p{port}_")
    state_dir = os.path.join(tmp_root, f".p{port}_state")
    lib_dir = os.path.join(tmp_root, f".p{port}_lib")
    music_dir = os.path.join(tmp_root, f".p{port}_music")
    os.makedirs(state_dir, exist_ok=True)
    os.makedirs(lib_dir, exist_ok=True)
    os.makedirs(music_dir, exist_ok=True)

    wav_path = os.path.join(state_dir, "silence_2s.wav")
    create_silence_wav(wav_path, 2.0)
    print(f"  短静音 WAV 素材已生成: {wav_path} (时长: 2.0s, 44.1kHz 16-bit, 隔离无声)")

    # 注入代理配置指向 Mock，使 rtaweb 所有的外部元数据/LLM 均走慢 Mock
    conf_path = os.path.join(state_dir, "rlplayer-llm.conf")
    with open(conf_path, "w", encoding="utf-8") as f:
        f.write(f"proxy=http://127.0.0.1:{mock_port}\n")
        f.write("api_key=sk-offline-mock-test-key-for-b8-safe\n")
        f.write("model=deepseek-chat\n")

    # 3. 启动 rtaweb 实例
    env = os.environ.copy()
    env["RLPLAYER_STATE_DIR"] = state_dir
    env["RLPLAYER_LIBRARY_DIR"] = lib_dir
    env["RLPLAYER_PORT"] = str(port)

    log_path = os.path.join(state_dir, "rtaweb_stdout.log")
    log_file = open(log_path, "w", encoding="utf-8")

    server_proc = subprocess.Popen(
        [rtaweb_bin, "--port", str(port), "--no-browser", "--music-dir", music_dir],
        stdout=log_file,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=state_dir,
    )
    print(f"  rtaweb 进程已启动，PID: {server_proc.pid}")

    try:
        # 等待服务器就绪
        ready = False
        api_settings_url = f"http://127.0.0.1:{port}/api/settings"
        for _ in range(50):
            try:
                with urllib.request.urlopen(api_settings_url, timeout=0.2) as resp:
                    if resp.status == 200:
                        ready = True
                        break
            except Exception:
                time.sleep(0.1)

        if not ready:
            print(f"ERROR: rtaweb (PID: {server_proc.pid}) 未能在 5 秒内就绪", file=sys.stderr)
            return 1

        print("  rtaweb 实例就绪，开始配置测试参数...")

        # 4. 配置 backend=null, metaon=1, metasummary=1, volume=-60.0（禁真实音频）
        set_data = urllib.parse.urlencode({
            "backend": "null",
            "metaon": "1",
            "metasummary": "1",
            "volume": "-60.0",
        }).encode("utf-8")
        req = urllib.request.Request(api_settings_url, data=set_data, method="POST")
        with urllib.request.urlopen(req, timeout=3.0) as resp:
            assert resp.status == 200, f"POST /api/settings HTTP 状态码为 {resp.status}"
            set_res = json.loads(resp.read().decode("utf-8"))
            assert set_res.get("ok") is True, f"POST /api/settings 返回 ok 不为 true: {set_res}"
            print(f"  POST /api/settings 响应 ok: {set_res.get('ok')}")

        # 读取并断言 settings 中的 kv/backend 确认生效
        with urllib.request.urlopen(api_settings_url, timeout=3.0) as resp:
            assert resp.status == 200, f"GET /api/settings HTTP 状态码为 {resp.status}"
            settings_response = json.loads(resp.read().decode("utf-8"))
            assert settings_response.get("ok") is True
            get_res = settings_response.get("kv", {})
            print(f"  GET /api/settings 校验: backend={get_res.get('backend')}, metaon={get_res.get('metaon')}, metasummary={get_res.get('metasummary')}")
            assert get_res.get("backend") == "null", f"断言失败: backend 应为 null，实际为 {get_res.get('backend')}"
            assert str(get_res.get("metaon")) in ("1", "true", "True"), f"断言失败: metaon 应为 1，实际为 {get_res.get('metaon')}"
            assert str(get_res.get("metasummary")) in ("1", "true", "True"), f"断言失败: metasummary 应为 1，实际为 {get_res.get('metasummary')}"

        # 5. 触发播放静音文件（发起后台元数据补全 meta_on_play，backend=null 绝不出声）
        play_url = f"http://127.0.0.1:{port}/api/play"
        play_data = urllib.parse.urlencode({
            "file": wav_path,
            "volume": "-60.0",
            "backend": "null",
        }).encode("utf-8")
        req_play = urllib.request.Request(play_url, data=play_data, method="POST")
        with urllib.request.urlopen(req_play, timeout=3.0) as resp:
            assert resp.status == 200, f"POST /api/play HTTP 状态码为 {resp.status}"
            play_res = json.loads(resp.read().decode("utf-8"))
            assert play_res.get("ok") is True, f"POST /api/play 返回 ok 不为 true: {play_res}"
            print(f"  /api/play 响应: {play_res}")

        # 6. 同时触发 summary 异步后台整理任务 (kind=person, refresh=1 触发外网检索)
        summary_url = f"http://127.0.0.1:{port}/api/entity/summary?kind=person&name=OfflineSlowArtist&refresh=1"
        try:
            with urllib.request.urlopen(summary_url, timeout=3.0) as resp:
                assert resp.status == 200, f"GET /api/entity/summary HTTP 状态码为 {resp.status}"
                summ_res = json.loads(resp.read().decode("utf-8"))
                print(f"  /api/entity/summary 响应: {summ_res}")
        except Exception as e:
            print(f"  /api/entity/summary 调用异常: {e}")

        # 7. 等待并断言代理实际命中，证明至少 1 个真实网络请求到达并挂在 8s 慢服务器上
        print("  等待后台任务发起真实网络请求并挂在慢 Mock 代理上...")
        hit = mock_server.request_event.wait(timeout=5.0)
        if not hit or mock_server.request_count < 1:
            print(f"FAIL: 未能在 5.0s 内检测到真实网络请求到达 Mock 代理 (hit={hit}, count={mock_server.request_count})", file=sys.stderr)
            server_proc.send_signal(signal.SIGTERM)
            return 1

        with mock_server.lock:
            req_summary = list(mock_server.request_log)
        print(f"  [验证成功] 慢 Mock 代理捕获真实网络请求 (共 {len(req_summary)} 个): {req_summary}")
        print(f"  请求当前正在 8s 慢挂起中，此时发送 SIGTERM 测试退出收敛性 (PID: {server_proc.pid})...")

        # 额外微量缓冲 0.2s，保证后台线程切实处于网络 I/O 阻塞状态
        time.sleep(0.2)

        # 8. 记录 T0 并发送 SIGTERM 触发优雅收尾
        t0 = time.time()
        server_proc.send_signal(signal.SIGTERM)

        # 9. 等待进程完全退出（铁律：绝不 force-kill，超时只报告不 kill）
        try:
            ret = server_proc.wait(timeout=10.0)
            t1 = time.time()
            elapsed = t1 - t0
        except subprocess.TimeoutExpired:
            print(f"FAIL: rtaweb 进程 (PID: {server_proc.pid}) 在 10s 内未退出（死锁或未正常响应退出信号，按铁律绝不 force-kill）", file=sys.stderr)
            server_proc.send_signal(signal.SIGTERM)
            return 1

        print(f"  进程退出耗时: {elapsed:.3f}s (退出码: {ret}, PID: {server_proc.pid})")

        # 10. 检查日志与指标
        playback_log_path = os.path.join(state_dir, "rlplayer-playback.log")
        stdout_log_path = os.path.join(state_dir, "rtaweb_stdout.log")

        shutdown_metric_found = False
        shutdown_all_done_found = False
        shutdown_joinable_found = False
        has_unclosed_jobs = False
        metric_line = ""

        all_log_lines = []
        if os.path.isfile(playback_log_path):
            with open(playback_log_path, "r", encoding="utf-8", errors="ignore") as f:
                all_log_lines.extend(f.readlines())
        if os.path.isfile(stdout_log_path):
            with open(stdout_log_path, "r", encoding="utf-8", errors="ignore") as f:
                all_log_lines.extend(f.readlines())

        for line in all_log_lines:
            if "SHUTDOWN joinable:" in line:
                shutdown_joinable_found = True
            if "SHUTDOWN bg=0 inflight=0" in line:
                shutdown_metric_found = True
                metric_line = line.strip()
            if "SHUTDOWN 后台任务已全部收完" in line:
                shutdown_all_done_found = True
            if "未收完" in line:
                has_unclosed_jobs = True
                print(f"  [告警行] 发现未收完日志: {line.strip()}", file=sys.stderr)

        print(f"  指标核验:")
        print(f"    - Proxy 命中真实请求计数 >= 1: {mock_server.request_count >= 1} (实际: {mock_server.request_count})")
        print(f"    - SHUTDOWN joinable 日志存在: {shutdown_joinable_found}")
        print(f"    - SHUTDOWN bg=0 inflight=0 结构化指标存在: {shutdown_metric_found} ({metric_line})")
        print(f"    - SHUTDOWN 后台任务已全部收完 日志存在: {shutdown_all_done_found}")
        print(f"    - 退出日志不含'未收完': {not has_unclosed_jobs}")
        print(f"    - 进程退出码 exit 0: {ret == 0} (实际: {ret})")
        print(f"    - 退出耗时 ({elapsed:.3f}s) <= 预算上限 ({MAX_QUIT_SECONDS}s): {elapsed <= MAX_QUIT_SECONDS}")

        if ret != 0:
            print(f"FAIL: 进程退出码非 0: {ret} (PID: {server_proc.pid})", file=sys.stderr)
            return 1

        if not shutdown_metric_found:
            print("FAIL: 日志中未找到 SHUTDOWN bg=0 inflight=0 确认归零指标", file=sys.stderr)
            return 1

        if has_unclosed_jobs:
            print("FAIL: 日志中包含未收完后台任务告警", file=sys.stderr)
            return 1

        if not shutdown_all_done_found:
            print("FAIL: 日志中未找到 'SHUTDOWN 后台任务已全部收完'", file=sys.stderr)
            return 1

        if elapsed > MAX_QUIT_SECONDS:
            print(f"FAIL: 退出时间超时 ({elapsed:.3f}s > {MAX_QUIT_SECONDS}s)", file=sys.stderr)
            return 1

        print("================================================================")
        print("  RESULT: PASS (所有后台任务均确认归零，当前场景计数归零，快速退出)")
        print("================================================================")
        return 0

    finally:
        if log_file and not log_file.closed:
            try:
                log_file.close()
            except Exception:
                pass
        mock_server.stop_requested = True
        try:
            mock_server.shutdown()
        except Exception:
            pass
        try:
            mock_server.server_close()
        except Exception:
            pass

        if server_proc and server_proc.poll() is None:
            print(f"  [清理提示] rtaweb 进程仍存活 (PID: {server_proc.pid})，发送 SIGTERM 提醒退出，按铁律绝不 force-kill")
            try:
                server_proc.send_signal(signal.SIGTERM)
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
