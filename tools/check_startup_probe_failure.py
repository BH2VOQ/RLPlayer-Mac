#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 BH2VOQ <https://github.com/BH2VOQ>
# SPDX-License-Identifier: GPL-3.0-or-later
# 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
# 完整条款见仓库根目录的 LICENSE 文件。
"""Real unreadable-tag regression: copied index, read-only media, isolated restart.

A readable audio file with failed metadata probing must remain indexed, but must
not make every future startup rescan an unchanged library. Genuine directory or
file access failures remain dirty (covered by library fingerprint unit tests).
This script never synthesizes IO/probe failures, touches source media, plays
sound, starts a browser, or operates on the user's running application.

Example:
  python3 tools/check_startup_probe_failure.py --binary build-mac/rtaweb \
    --index "$HOME/Library/Application Support/RLPlayer/rlplayer-index.tsv" \
    --music /path/to/Music --out /tmp/rlplayer-probe-regression --skip-covers

⚠ Boundaries: this exercises real CLI/service scan and restart, not native .app
installation or playback. Output contains private paths and stays outside git.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import time

# Do not create an import cache in the repository during private acceptance.
sys.dont_write_bytecode = True
from check_startup_cover_cache import REPO, RESULTS, Service, check, listeners


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(part)
    return h.hexdigest()


def snapshot(path):
    stat = path.stat()
    return {'size': stat.st_size, 'mtime_ns': stat.st_mtime_ns,
            'sha256': digest(path)}


def incomplete_rows(path):
    """Evidence only: byte-copy is authoritative; tolerate historic bad UTF-8."""
    rows = []
    for line in path.read_bytes().splitlines():
        if line.startswith(b'#'):
            continue
        fields = line.split(b'\t')
        if len(fields) < 16:
            continue
        if fields[10] in (b'', b'0') or fields[12] in (b'', b'0'):
            rows.append({'path': fields[0].decode('utf-8', errors='replace'),
                         'sr': fields[10].decode('ascii', errors='replace'),
                         'ch': fields[12].decode('ascii', errors='replace')})
    return rows


def settled(service, out, phase, seconds):
    deadline = time.monotonic() + seconds
    history = []
    while True:
        status = service.api('/api/lib/status')
        history.append({'elapsed_s': round(seconds - (deadline - time.monotonic()), 3),
                        'status': status})
        (out / f'{phase}-status-history.json').write_text(
            json.dumps(history, ensure_ascii=False, indent=2))
        if not status.get('scanning'):
            return status
        if time.monotonic() >= deadline:
            raise RuntimeError(f'{phase}: scan exceeded {seconds}s bound')
        time.sleep(0.5)


def cleanup_evidence(service, source, before, out):
    """Preserve every cleanup failure without masking another or losing results."""
    proc = service.proc
    pid = proc.pid if proc is not None else None
    try:
        service.stop()
    except Exception as error:
        check(False, 'owned service cleanup failed', {
            'pid': pid, 'error': repr(error),
            'action': 'no force kill; verify retained PID before further action'})
    try:
        unchanged = snapshot(source)
        check(before == unchanged, 'user index remains byte-for-byte unchanged',
              {'before': before, 'after': unchanged})
        (out / 'source-after.json').write_text(json.dumps(unchanged, indent=2))
    except Exception as error:
        check(False, 'source index final snapshot failed', {
            'error': repr(error), 'source': str(source),
            'boundary': 'source change/removal may be external; no source write attempted'})
    finally:
        # A cleanup/snapshot error must not erase the previous test evidence.
        # If the evidence directory itself is unwritable this raises naturally,
        # still yielding nonzero rather than reporting a false successful run.
        (out / 'results.json').write_text(json.dumps(RESULTS, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--index', type=Path, required=True)
    parser.add_argument('--music', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--skip-covers', action='store_true',
                        help='Only scan/restart; do not request any covers')
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    source = args.index.resolve(strict=True)
    music = args.music.resolve(strict=True)
    out = args.out.resolve()
    if not music.is_dir():
        parser.error('--music must be an existing directory')
    # Evidence/cache/config writes must never land in the real library or state.
    if out == source.parent or source.parent in out.parents or out == music or music in out.parents:
        parser.error('--out must be separate from source state and music')
    if out == REPO or REPO in out.parents:
        parser.error('--out must be outside repository (private evidence)')
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error('--out must be empty; state reuse invalidates this test')
    if listeners(19123):
        parser.error('19123 is occupied; no HTTP sent, no process signalled')
    RESULTS.clear()
    before = snapshot(source)
    (out / 'source-before.json').write_text(json.dumps(before, indent=2))
    (out / 'binary.json').write_text(json.dumps({'binary': str(binary), 'sha256': digest(binary)}, indent=2))
    print(f'ARTIFACTS {out}\nBINARY {binary}\nSOURCE index copied byte-for-byte; media read-only', flush=True)
    service = Service(out / 'isolated', binary, 19123)
    fingerprint = service.lib / 'rlplayer-index.dirs.tsv.p19123'
    # Override Service's synthetic cover tool: this case uses only real tools.
    service.env.update(RLPLAYER_FFMPEG=str(REPO / 'build-mac/ffmpeg-lite/ffmpeg'),
                       RLPLAYER_FFPROBE=str(REPO / 'build-mac/ffmpeg-lite/ffprobe'),
                       RLPLAYER_COVER_HOST='http://127.0.0.1:1')
    service.env.pop('RLPLAYER_NATIVE_TAGS', None)
    for attempt in range(2):
        before = snapshot(source)
        shutil.copyfile(source, service.index)
        copied = snapshot(service.index)
        after_copy = snapshot(source)
        if before == after_copy and copied['sha256'] == before['sha256'] and copied['size'] == before['size']:
            break
        if attempt == 1:
            raise RuntimeError('user index changed during both copy attempts; no service launched')
        print('[INFO] source changed while copying; retrying once', flush=True)
    (out / 'source-before.json').write_text(json.dumps(before, indent=2))
    source_incomplete = incomplete_rows(service.index)
    (out / 'source-incomplete-rows.json').write_text(json.dumps(source_incomplete, ensure_ascii=False, indent=2))
    print(f'INPUT incomplete sr/ch rows={len(source_incomplete)}', flush=True)
    if not source_incomplete:
        print('[BOUNDARY] input contains no sr/ch-zero rows; a green result proves unchanged-startup behavior only, not reproduction of metadata-probe failure', flush=True)
    (service.lib / 'rlplayer-library.conf.p19123').write_text(str(music) + '\n')
    settings = 'backend=null\nmetaon=0\nmetallm=0\n'
    service.settings.write_text(settings + 'scanonstartup=0\n')
    try:
        service.start()
        initial = service.api('/api/lib/status')
        (out / 'initial-status.json').write_text(json.dumps(initial, ensure_ascii=False, indent=2))
        started = service.api('/api/lib/scan', b'')
        check(started.get('ok') and started.get('started'), 'real incremental scan started explicitly', started)
        status = settled(service, out, 'manual', 600)
        (out / 'probe-failure-observation.json').write_text(json.dumps({
            'input_incomplete_rows': len(source_incomplete),
            'dirty_probe_failed_observed': 'dirty=probe-failed' in status.get('msg', ''),
            'msg': status.get('msg', ''),
            'boundary': 'No forced failures: absence of input sr/ch-zero rows does not reproduce the reported probe-failure case.'
        }, ensure_ascii=False, indent=2))
        # directoryComplete is independent of metadata health in the fix. A failed
        # file stays explicitly pending; do not falsely claim the entire scan healthy.
        directory_complete = status.get('directoryComplete', status.get('complete'))
        check(directory_complete is True, 'directory traversal settles independently of metadata failures', status)
        if status.get('metadataPending', 0):
            check(status.get('metadataHealthy') is False and status.get('complete') is False,
                  'pending metadata failures remain explicitly visible', status)
        check(fingerprint.exists() and fingerprint.read_bytes().startswith(b'#libDirsV\t1\t') and b'\n#end\t' in fingerprint.read_bytes(),
              'completed scan persists directory fingerprint', {'exists': fingerprint.exists(), 'msg': status.get('msg')})
        (out / 'manual-status.json').write_text(json.dumps(status, ensure_ascii=False, indent=2))
        (out / 'scanned-incomplete-rows.json').write_text(json.dumps(incomplete_rows(service.index), ensure_ascii=False, indent=2))
        if fingerprint.exists():
            shutil.copyfile(fingerprint, out / 'manual-fingerprint.tsv')
        if not args.skip_covers:
            albums = service.api('/api/lib/albums').get('albums', [])
            for album in [a for a in albums if a.get('cv')][:3]:
                code, headers, data = service.get('/api/lib/cover?k=' + album['k'])
                check(code == 200 and len(data) > 64, 'local cover remains readable',
                      {'key': album['k'], 'status': code, 'bytes': len(data), 'mime': headers.get('Content-Type')})
        else:
            print('[SKIP] cover requests explicitly disabled (--skip-covers)', flush=True)
        service.stop()
        old = snapshot(service.index)
        log_start = len(service.playback_lines())
        service.settings.write_text(settings + 'scanonstartup=1\n')
        service.start()
        restart = settled(service, out, 'restart', 600)
        after = snapshot(service.index)
        lines = service.playback_lines()[log_start:]
        (out / 'restart-playback.txt').write_text('\n'.join(lines) + '\n')
        check(any('LIBSCAN startup skip reason=unchanged' in line for line in lines),
              'restart skips unchanged library', '\n'.join(lines))
        check(old == after, 'restart leaves index bytes and mtime unchanged', {'before': old, 'after': after})
        check(restart.get('scanned', 0) == 0 and not restart.get('scanning'),
              'restart has no rescan work', restart)
    except Exception as error:
        check(False, 'probe-failure regression completed', repr(error))
    finally:
        cleanup_evidence(service, source, before, out)
    failed = sum(not row['ok'] for row in RESULTS)
    print(f'SUMMARY {len(RESULTS)-failed} passed / {failed} failed; artifacts={out}', flush=True)
    return int(failed > 0)


if __name__ == '__main__':
    sys.exit(main())
