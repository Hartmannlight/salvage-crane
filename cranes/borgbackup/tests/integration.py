#!/usr/bin/env python3
"""Real Borg backups/restores in disposable bind mounts; no external repository."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

image = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='borg-safety-') as tmp:
    root = Path(tmp)
    for name in ('source', 'meta', 'cache', 'restore'):
        (root / name).mkdir()
    (root / 'source/payload').write_bytes(bytes(range(256)) * 4096)
    (root / 'source/payload').chmod(0o640)
    (root / 'source/link').symlink_to('payload')
    (root / 'meta/meta.json').write_text('{"test":true}\n')
    common = ['docker', 'run', '--rm', '--network', 'none', '--user', f'{os.getuid()}:{os.getgid()}',
              '-v', f'{root}:/test', '-e', 'USER=fixture', '-e', 'BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes',
              '-e', 'BORG_CACHE_DIR=/tmp/cache', '-e', 'BORG_CONFIG_DIR=/tmp/config']

    def run(args, success=True):
        p = subprocess.run(args, capture_output=True, text=True)
        if success and p.returncode != 0:
            raise AssertionError(p.stdout + p.stderr)
        return p

    def borg(*args):
        return run(common + ['--entrypoint', 'borg', image, *args])

    def archives():
        return {a['name'] for a in json.loads(borg('list', '--json', '/test/repo').stdout)['archives']}

    def backup(machine='a', volume='data', crane='borg', **extra):
        env = dict(SALVAGE_MACHINE_NAME=machine, SALVAGE_VOLUME_NAME=volume,
                   SALVAGE_CRANE_NAME=crane, SALVAGE_TIDE_TIMESTAMP='1720000000',
                   REPO_BASE_LOCATION='/test/repo', SINGLE_REPO='true', ENCRYPTION='none',
                   DO_COMPACT='true', **extra)
        opts = [x for k, v in env.items() for x in ('-e', k + '=' + v)]
        return run(common + ['-v', f'{root}/source:/salvage/volume:ro',
                             '-v', f'{root}/meta:/salvage/meta:ro', '-v', f'{root}/cache:/borg',
                             *opts, image], success=False)

    for identity in ({'machine':'b'}, {'volume':'data-child'}, {'crane':'other'}):
        result = backup(**identity)
        assert result.returncode == 0, result.stdout + result.stderr
    borg('create', '/test/repo::v_data-legacy', '/test/source')
    protected = archives()
    assert len(protected) == 4
    assert backup().returncode == 0
    old = archives() - protected
    assert len(old) == 1
    result = backup(PRUNE_ARGS='--keep-last 1')
    assert result.returncode == 0, result.stdout + result.stderr
    remaining = archives()
    assert protected <= remaining, 'Retention deleted another identity or a legacy archive'
    assert not old & remaining, 'Retention did not remove the superseded current-identity archive'
    current = remaining - protected
    assert len(current) == 1
    archive = current.pop()
    run(common + ['-w', '/test/restore', '--entrypoint', 'borg', image,
                  'extract', '/test/repo::' + archive])
    assert (root / 'restore/volume/payload').read_bytes() == (root / 'source/payload').read_bytes()
    assert (root / 'restore/volume/payload').stat().st_mode & 0o777 == 0o640
    assert os.readlink(root / 'restore/volume/link') == 'payload'
    borg('check', '--verify-data', '/test/repo')
    before = archives()
    for extra in ({'PRUNE_ARGS': '--glob-archives * --keep-last 1'},
                  {'PRUNE_ARGS': '--keep-last 0'},
                  {'CUSTOM_PREFIX': '$(touch /test/EXECUTED)'}):
        assert backup(**extra).returncode != 0, 'Unsafe argument accepted'
        assert archives() == before
    assert not (root / 'EXECUTED').exists()
    assert backup(CUSTOM_PREFIX='${SALVAGE_MACHINE_NAME}_${SALVAGE_VOLUME_NAME}').returncode == 0
    print('PASS: backup, exact restore, integrity, machine/volume/crane isolation, legacy preservation, argument rejection')
