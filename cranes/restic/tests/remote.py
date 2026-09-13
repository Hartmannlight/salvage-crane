#!/usr/bin/env python3
"""Opt-in live backup/restore test. Only generated volumes and a NEW subrepository.

Usage: python3 cranes/restic/tests/remote.py --output cranes/restic/tools/.local/live-run
Requires a completed tools/install.sh setup and a reachable SFTP target.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def manifest(root):
    entries = {}
    for path in sorted(root.rglob('*')):
        key = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode & 0o777
        if path.is_symlink():
            entries[key] = {'link': os.readlink(path)}
        elif path.is_file():
            entries[key] = {'size': path.stat().st_size, 'mode': mode,
                            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        elif path.is_dir():
            entries[key] = {'directory': True, 'mode': mode}
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=False)
    out.chmod(0o700)
    runtime = Path(os.environ.get('RUNTIME_ENV_FILE', ROOT / 'tools/.runtime.env')).resolve()
    config = subprocess.run(['bash', '-c', 'set -a; source "$1"; env -0', 'config', str(runtime)],
                            check=True, capture_output=True).stdout
    config = dict(part.decode().split('=', 1) for part in config.split(b'\0') if b'=' in part)
    base = config['REPO_BASE_LOCATION']
    if not base.startswith('sftp:') or ';' in base:
        raise SystemExit('Live test requires one SFTP base repository, no rotation.')
    run_id = time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8]
    repo = base.rstrip('/') + '/live-' + run_id
    image = config['RESTIC_CRANE_IMAGE']
    volumes = ['salvage-restic-live-' + run_id + '-' + name for name in ('a', 'b')]
    temp_runtime = out / 'runtime.env'
    # Base file is generated and shell-quoted by install.sh. Append test overrides.
    if "'" in repo:
        raise SystemExit('Single quotes are not supported in repository URLs.')
    temp_runtime.write_text(runtime.read_text() + f"\nREPO_BASE_LOCATION='{repo}'\nVERIFY_REPOSITORY_CHECK='false'\nFORGET_ARGS=''\nDO_PRUNE='false'\n")
    temp_runtime.chmod(0o600)
    env = os.environ | {'RUNTIME_ENV_FILE': str(temp_runtime)}
    log_index = 0

    def run(name, command, expected=0):
        nonlocal log_index
        log_index += 1
        print(f'[{log_index}] {name}', flush=True)
        result = subprocess.run(command, env=env, text=True, capture_output=True)
        (out / f'{log_index:02d}-{name}.log').write_text(result.stdout + result.stderr)
        if (expected == 0 and result.returncode != 0) or (expected != 0 and result.returncode == 0):
            raise RuntimeError(f'{name}: unexpected exit {result.returncode}; see logs in {out}')
        return result.stdout

    def repository(action, volume, *extra, expected=0):
        return run(action, ['bash', str(ROOT / 'tools/repository.sh'), action, volume, *map(str, extra)], expected)

    def snapshots(volume):
        return json.loads(repository('snapshots', volume))

    fixture = out / 'source'
    fixture.mkdir()
    (fixture / 'nested').mkdir()
    (fixture / 'empty-dir').mkdir()
    (fixture / 'payload.bin').write_bytes(random.Random(42).randbytes(2 * 1024 * 1024))
    (fixture / 'payload.bin').chmod(0o640)
    (fixture / 'empty.txt').touch()
    (fixture / 'changed.txt').write_text('version one\n')
    (fixture / 'deleted.txt').write_text('present in the first snapshot\n')
    (fixture / 'nested' / 'Grüße mit Leerzeichen.txt').write_text('Grüße aus dem Restic-Test!\n')
    for i in range(32):
        (fixture / 'nested' / f'item-{i:02d}.txt').write_text(f'fixture {i}\n' * 100)
    (fixture / 'link').symlink_to('payload.bin')
    expected_v1 = manifest(fixture)
    (out / 'manifest-v1.json').write_text(json.dumps(expected_v1, indent=2, ensure_ascii=False))
    report = {'repository': repo, 'volumes': volumes, 'image': image, 'started': run_id}
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    for volume in volumes:
        run('create-volume', ['docker', 'volume', 'create', '--label', 'salvage.restic.live-test=' + run_id, volume])
        run('seed-volume', ['docker', 'run', '--rm', '--network', 'none',
                           '--mount', f'type=bind,src={fixture},dst=/fixture,readonly',
                           '--mount', f'type=volume,src={volume},dst=/data', '--entrypoint', 'sh', image,
                           '-euc', 'cp -a /fixture/. /data/'])
    for volume in volumes:
        run('backup', ['bash', str(ROOT / 'tools/run-crane-smoke.sh'), volume])
    first_a = snapshots(volumes[0])[0]['id']
    first_b = snapshots(volumes[1])[0]['id']
    (fixture / 'changed.txt').write_text('version TWO\n')
    (fixture / 'deleted.txt').unlink()
    (fixture / 'new.txt').write_text('added after the first backup\n')
    expected_v2 = manifest(fixture)
    (out / 'manifest-v2.json').write_text(json.dumps(expected_v2, indent=2, ensure_ascii=False))
    run('change-volume', ['docker', 'run', '--rm', '--network', 'none',
                         '--mount', f'type=bind,src={fixture},dst=/fixture,readonly',
                         '--mount', f'type=volume,src={volumes[0]},dst=/data', '--entrypoint', 'sh', image,
                         '-euc', 'rm /data/deleted.txt; cp -a /fixture/. /data/'])
    run('backup-v2', ['bash', str(ROOT / 'tools/run-crane-smoke.sh'), volumes[0]])
    second_a = next(s['id'] for s in snapshots(volumes[0]) if s['id'] != first_a)
    for label, volume, snapshot, expected in (
            ('v1', volumes[0], first_a, expected_v1), ('v2', volumes[0], 'latest', expected_v2),
            ('volume-b', volumes[1], 'latest', expected_v1)):
        target = out / ('restore-' + label)
        repository('restore', volume, snapshot, target)
        actual = manifest(target / 'salvage/volume')
        if actual != expected:
            raise AssertionError(f'Restore mismatch: {label}')
        metadata = json.loads((target / 'salvage/meta/meta.json').read_text())
        assert metadata['volumeMeta']['name'] == volume, metadata
        print(f'Verified {label}: {len(actual)} entries; bytes, modes, names, symlinks and metadata match.', flush=True)
    # A foreign snapshot ID must be rejected, even when the repository is shared.
    repository('restore', volumes[0], first_b, out / 'reject-foreign', expected=1)
    repository('restore', volumes[0], 'latest', out / 'restore-v2', expected=1)
    repository('check', volumes[0])
    # Exercise production retention against this generated repository only.
    meta = out / 'retention-meta'
    meta.mkdir()
    (meta / 'meta.json').write_text(json.dumps({'volumeMeta': {'name': volumes[0]}, 'test': 'retention'}))
    docker_args = ['docker', 'run', '--rm',
                   '--mount', f'type=volume,src={volumes[0]},dst=/salvage/volume,readonly',
                   '--mount', f'type=bind,src={meta},dst=/salvage/meta,readonly',
                   '--mount', f'type=volume,src={config["RESTIC_SSH_VOLUME"]},dst=/root/.ssh,readonly',
                   '--mount', f'type=volume,src={config["RESTIC_SECRETS_VOLUME"]},dst=/run/secrets,readonly',
                   '--mount', f'type=volume,src={config["RESTIC_CACHE_VOLUME"]},dst=/cache']
    for key, value in {'REPO_BASE_LOCATION': repo, 'RESTIC_PASSWORD_FILE': '/run/secrets/' + config['RESTIC_PASSWORD_FILENAME'],
                       'RESTIC_CACHE_DIR': '/cache', 'SALVAGE_MACHINE_NAME': config['MACHINE'], 'SALVAGE_CRANE_NAME': 'restic',
                       'SALVAGE_VOLUME_NAME': volumes[0], 'SALVAGE_TIDE_TIMESTAMP': str(int(time.time())),
                       'FORGET_ARGS': '--keep-last 1', 'DO_PRUNE': 'true', 'VERIFY_REPOSITORY_CHECK': 'true',
                       'VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET': '100%', 'RESTIC_RETRY_LOCK': '2m'}.items():
        docker_args += ['-e', key + '=' + value]
    run('retention', docker_args + [image])
    remaining_a, remaining_b = snapshots(volumes[0]), snapshots(volumes[1])
    assert len(remaining_a) == 1, remaining_a
    assert [s['id'] for s in remaining_b] == [first_b], remaining_b
    repository('restore', volumes[0], 'latest', out / 'restore-after-prune')
    assert manifest(out / 'restore-after-prune/salvage/volume') == expected_v2
    repository('check', volumes[0])
    report.update({'status': 'passed', 'first_a': first_a, 'second_a': second_a, 'first_b': first_b,
                   'remaining_a': remaining_a[0]['id'], 'manifest_entries': len(expected_v1),
                   'restored_versions': ['v1', 'v2', 'volume-b', 'after-prune'],
                   'checks': ['SHA256 contents', 'permissions', 'symlinks', 'metadata', 'scope isolation', 'full remote data check'],
                   'finished_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Live test PASSED. Evidence and restored data:', out, flush=True)
    print('Generated remote repository and source volumes retained for inspection.', flush=True)


if __name__ == '__main__':
    main()
