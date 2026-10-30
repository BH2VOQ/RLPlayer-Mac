#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分，以 GNU GPL 第 3 版（或更新版本）发布。
"""Real busy-port red/green check. Sentinel records quit but never acts on it.

Run only with the lead's exclusive 19106 slot. No device opening, HTTP cleanup,
foreign process signals, force kill, or production configuration changes.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

PORT = 19106


def ps_identity(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "uid=,ppid=,comm="],
                            capture_output=True, text=True)
    fields = result.stdout.strip().split(None, 2)
    if result.returncode or len(fields) != 3:
        return None
    return (int(fields[0]), int(fields[1]), Path(fields[2]).name)


def listeners():
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", f"-iTCP:{PORT}",
                             "-sTCP:LISTEN", "-Fp"], capture_output=True, text=True)
    if result.returncode == 1 and not result.stdout and not result.stderr:
        return set()
    # -Fp includes f<descriptor> records on macOS; only p<PID> owns a listener.
    lines = [line for line in result.stdout.splitlines()
             if not (line.startswith("f") and line[1:].isdigit())]
    if (result.returncode or result.stderr or not lines or
            any(not line.startswith("p") or not line[1:].isdigit() for line in lines)):
        raise RuntimeError(f"listener ownership unreadable: {result}")
    return {int(line[1:]) for line in lines}


def stop_owned(process, basename):
    if process.poll() is not None:
        return
    expected = (os.getuid(), os.getpid(), basename)
    actual = ps_identity(process.pid)
    if actual != expected:
        raise RuntimeError(f"No TERM: identity mismatch pid={process.pid}: {actual} != {expected}")
    os.kill(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Owned PID {process.pid} did not exit after TERM; no force kill")


def sentinel(log):
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            with log.open("a", encoding="utf-8") as output:
                output.write(json.dumps({"method": "POST", "path": self.path}) + "\n")
            self.send_response(200)
            self.send_header("Content-Length", "11")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            # Deliberately no shutdown, including /api/quit.

        def do_GET(self):
            with log.open("a", encoding="utf-8") as output:
                output.write(json.dumps({"method": "GET", "path": self.path}) + "\n")
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *args):
            pass

    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


def requests(log):
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def run_case(binary, label, root, output, interpreter):
    if listeners():
        raise RuntimeError("19106 busy before sentinel; no requests or signals sent")
    request_log = output / f"{label}-requests.jsonl"
    request_log.write_text("")
    sentinel_log = (output / f"{label}-sentinel.log").open("w")
    server = subprocess.Popen([interpreter, str(Path(__file__).resolve()),
                               "--sentinel", str(request_log)], stdout=sentinel_log,
                              stderr=subprocess.STDOUT)
    test = None
    try:
        expected = (os.getuid(), os.getpid(), Path(interpreter).name)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if server.poll() is not None:
                raise RuntimeError("sentinel exited before ready")
            if ps_identity(server.pid) == expected and listeners() == {server.pid}:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("sentinel identity/listener not proven")
        with (output / f"{label}-test.log").open("w") as stream:
            test = subprocess.Popen([str(binary)], cwd=root, stdout=stream, stderr=subprocess.STDOUT)
            try:
                code = test.wait(timeout=45)
            except subprocess.TimeoutExpired:
                stop_owned(test, binary.name)
                raise RuntimeError(f"{label} exceeded 45 seconds")
        recorded = requests(request_log)
        alive = server.poll() is None and ps_identity(server.pid) == expected and listeners() == {server.pid}
        result = {"binary": str(binary), "exit": code, "requests": recorded,
                  "request_count": len(recorded), "sentinel_alive_before_TERM": alive,
                  "sentinel_identity": list(expected), "sentinel_pid": server.pid}
        if label == "old":
            result["pass"] = alive and any(item["path"] == "/api/quit" for item in recorded)
        else:
            text = (output / f"{label}-test.log").read_text()
            result["pass"] = alive and code != 0 and not recorded and "no spawn, no HTTP" in text
        return result
    finally:
        if test is not None:
            stop_owned(test, binary.name)
        stop_owned(server, Path(interpreter).name)
        sentinel_log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sentinel", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--old", type=Path)
    parser.add_argument("--fixed", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.sentinel:
        sentinel(args.sentinel)
        return 0
    if not all((args.old, args.fixed, args.output)):
        parser.error("--old, --fixed and --output are required")
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Framework Python execs this actual binary; ps comm is Python, not python3.14.
    framework = Path(sys.base_prefix) / "Resources/Python.app/Contents/MacOS/Python"
    interpreter = str(framework if framework.is_file() else Path(sys.executable).resolve())
    results = {label: run_case(binary.resolve(), label, root, output, interpreter)
               for label, binary in (("old", args.old), ("fixed", args.fixed))}
    results["port_empty_after_cleanup"] = not listeners()
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    return 0 if all(results[label]["pass"] for label in ("old", "fixed")) and results["port_empty_after_cleanup"] else 1


if __name__ == "__main__":
    sys.exit(main())
