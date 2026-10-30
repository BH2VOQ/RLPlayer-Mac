#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
"""验证体检分析缓存代际契约 (analysis_generation)。

断言与流程：
1. 真实 CLI 合成真实 WAV 信号（离线分析，绝不打开音频设备）。
2. 使用旧 rtahealth 二进制对同文件生成缺 analysis_generation 的旧版哨兵缓存。
3. 验证旧 rtahealth 运行该文件时命中旧缓存 (cached=true) 且读出旧指标。
4. 验证修后 rtahealth-patched 运行该文件时因为缺少 analysis_generation 判定为 miss (cached=false)，
   重新计算并与 --force 逐字段一致。
5. 验证修后 rtahealth-patched 再次运行该文件时能够命中已升级的缓存 (cached=true)。
6. 验证未知/未来/非法 analysis_generation 的缓存条目在修后 rtahealth-patched 下必定 miss。
7. 验证损坏的缓存文件不会被破坏覆盖。
"""

import argparse
import json
import os
import pathlib
import struct
import subprocess
import sys
import wave

def make_wav(path, sample_rate=44100, duration_sec=1.0, freq=440.0):
    n_samples = int(sample_rate * duration_sec)
    with wave.open(str(path), 'wb') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        frames = bytearray()
        import math
        for i in range(n_samples):
            val = int(32767.0 * 0.5 * math.sin(2.0 * math.pi * freq * (i / sample_rate)))
            frames.extend(struct.pack('<h', val))
        wf.writeframes(frames)

def run_health(binary, args):
    cmd = [str(binary)] + args
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)
    if res.returncode != 0:
        raise RuntimeError(f"Command failed (exit {res.returncode}): {' '.join(cmd)}\nStderr: {res.stderr}")
    rows = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.startswith('{') and line.endswith('}'):
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    if not rows:
        raise RuntimeError(f"No JSON output from command: {' '.join(cmd)}\nStdout: {res.stdout}\nStderr: {res.stderr}")
    return rows[0]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--old-binary', required=True, help='Path to old rtahealth binary')
    parser.add_argument('--new-binary', required=True, help='Path to patched rtahealth binary')
    parser.add_argument('--workdir', required=True, help='Working test directory')
    args = parser.parse_args()

    workdir = pathlib.Path(args.workdir).resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    old_bin = pathlib.Path(args.old_binary).resolve()
    new_bin = pathlib.Path(args.new_binary).resolve()

    wav_file = workdir / "test_tone.wav"
    make_wav(wav_file, sample_rate=44100, duration_sec=1.5, freq=1000.0)

    cache_file = workdir / "health_cache.json"
    if cache_file.exists():
        cache_file.unlink()

    print("[Step 1] Running old rtahealth to populate initial cache (without analysis_generation)...")
    res_old_init = run_health(old_bin, ['--json', '--cache', str(cache_file), str(wav_file)])
    assert res_old_init.get('cached') is False, f"Expected initial cached=false, got {res_old_init.get('cached')}"
    assert cache_file.exists(), "Cache file was not created by old rtahealth"

    # Verify the cache file lacks analysis_generation
    cache_data_raw = json.loads(cache_file.read_text())
    assert len(cache_data_raw) == 1
    assert 'analysis_generation' not in cache_data_raw[0], "Old cache unexpectedly contains analysis_generation"
    print("PASS: Old cache created without analysis_generation.")

    # Only alter synthetic cache metrics, not the WAV identity: prove old results can persist.
    cache_data_raw[0]['health']['quality']['thdn_db'] = -1.234
    cache_data_raw[0]['health']['quality']['side_mid_db'] = 77.0
    cache_file.write_text(json.dumps(cache_data_raw))
    print("[Step 2] Running old rtahealth against stale metric sentinels...")
    res_old_second = run_health(old_bin, ['--json', '--cache', str(cache_file), str(wav_file)])
    assert res_old_second.get('cached') is True, f"Expected old rtahealth cached=true, got {res_old_second.get('cached')}"
    assert res_old_second['quality']['thdn_db'] == -1.234 and res_old_second['quality']['side_mid_db'] == 77.0
    print("PASS: Old binary hits unchanged-file cache and returns stale THD+N/side-mid sentinels.")

    print("[Step 3] Running patched rtahealth against old sentinel cache: must MISS (cached=false)...")
    res_new_first = run_health(new_bin, ['--json', '--cache', str(cache_file), str(wav_file)])
    assert res_new_first.get('cached') is False, f"Expected patched rtahealth cached=false on missing generation, got {res_new_first.get('cached')}"
    assert res_new_first['quality']['thdn_db'] != -1.234 and res_new_first['quality']['side_mid_db'] != 77.0
    print("PASS: Patched binary misses and replaces stale sentinels with actual recomputed metrics.")

    print("[Step 4] Checking --force consistency...")
    res_new_force = run_health(new_bin, ['--json', '--cache', str(cache_file), '--force', str(wav_file)])
    assert res_new_force.get('cached') is False, "Expected --force cached=false"
    # Compare metrics (excluding timestamp/cached/timing)
    ignore_keys = {'cached', 'analysis_ms', 'analyzed_at_ms'}
    for k in res_new_first:
        if k not in ignore_keys:
            assert res_new_first.get(k) == res_new_force.get(k), f"Mismatch for key {k}: {res_new_first.get(k)} vs {res_new_force.get(k)}"
    print("PASS: Recomputed values on generation miss match --force output exactly.")

    print("[Step 5] Running patched rtahealth again: should now HIT updated cache (cached=true)...")
    res_new_second = run_health(new_bin, ['--json', '--cache', str(cache_file), str(wav_file)])
    assert res_new_second.get('cached') is True, f"Expected patched rtahealth cached=true after update, got {res_new_second.get('cached')}"
    new_cache_data = json.loads(cache_file.read_text())
    assert len(new_cache_data) == 1
    assert new_cache_data[0].get('analysis_generation') == 'health-analysis-v2', f"Unexpected generation: {new_cache_data[0].get('analysis_generation')}"
    print("PASS: Cache successfully updated with analysis_generation='health-analysis-v2' and hits on subsequent run.")

    print("[Step 6] Testing stale / unknown / future generation in cache...")
    for bad_gen in ["health-analysis-v1", "health-analysis-unknown", "health-analysis-9999", "", 123, True, None]:
        entry = dict(new_cache_data[0])
        entry['analysis_generation'] = bad_gen
        cache_file.write_text(json.dumps([entry]))
        res_bad = run_health(new_bin, ['--json', '--cache', str(cache_file), str(wav_file)])
        assert res_bad.get('cached') is False, f"Expected bad generation {bad_gen} to miss, but got cached={res_bad.get('cached')}"
    print("PASS: Stale/unknown/future/malformed analysis generations all miss.")

    print("[Step 7] Testing damaged cache file protection...")
    corrupted_content = "NOT A JSON"
    cache_file.write_text(corrupted_content)
    # Patched rtahealth should report error and not overwrite the corrupted file
    proc = subprocess.run([str(new_bin), '--json', '--cache', str(cache_file), str(wav_file)],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)
    assert proc.returncode == 0, f"Damaged-cache analysis unexpectedly failed: {proc.returncode}"
    assert '缓存文件损坏' in proc.stdout, 'Damaged cache was not explicitly reported'
    assert cache_file.read_text() == corrupted_content, "Corrupted cache file was overwritten!"
    print("PASS: Damaged cache is explicitly reported and never overwritten.")

    print("\nALL CACHE GENERATION CHECKS PASSED.")

if __name__ == '__main__':
    main()
