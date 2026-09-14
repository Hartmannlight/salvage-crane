#!/usr/bin/env python3
"""Real restic tests in a disposable Linux namespace (requires bubblewrap)."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = {"PATH": "/usr/bin:/bin", "HOME": "/tmp", "RESTIC_PASSWORD": "integration-test-only",
        "RESTIC_BIN": "/restic", "SALVAGE_MACHINE_NAME": "machine", "SALVAGE_VOLUME_NAME": "volume-a",
        "SALVAGE_CRANE_NAME": "restic", "SALVAGE_TIDE_TIMESTAMP": "1626262626", "RESTIC_HOST": "shared-host"}


class RealResticTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = BASE | {"REPO_BASE_LOCATION": self.tmp.name + "/repo", "RESTIC_REPOSITORY": self.tmp.name + "/repo"}

    def command(self, args, success=True, **env):
        result = subprocess.run(args, env=self.env | env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def restic(self, *args, **env):
        return self.command(["/restic", *args], **env)

    def crane(self, **env):
        return self.command(["bash", "/crane"], **env)

    def snapshots(self):
        return json.loads(self.restic("snapshots", "--json").stdout)

    def seed(self, volume, crane="restic", machine="machine"):
        self.restic("backup", "--host", "shared-host", "--time", "2020-01-01 00:00:00",
                    "--tag", f"salvage,vol-{volume},machine-{machine},crane-{crane}", "/salvage/meta", "/salvage/volume")
        return next(s["id"] for s in self.snapshots() if f"vol-{volume}" in s["tags"] and
                    f"crane-{crane}" in s["tags"] and f"machine-{machine}" in s["tags"])

    def test_retention_isolated_and_restore_exact(self):
        self.restic("init")
        old_a = self.seed("volume-a")
        protected = {self.seed("volume-b"), self.seed("volume-a", crane="other"),
                     self.seed("volume-a", machine="other-machine")}
        self.crane(FORGET_ARGS="--keep-last 1", DO_PRUNE="true", VERIFY_REPOSITORY_CHECK="true",
                   VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET="")
        snapshots = self.snapshots()
        remaining = {s["id"] for s in snapshots}
        self.assertTrue(protected <= remaining, "Retention deleted a different backup unit")
        self.assertNotIn(old_a, remaining)
        self.assertEqual(len(remaining), 4)
        current = (remaining - protected).pop()
        target = self.tmp.name + "/restore"
        self.restic("restore", current, "--target", target, "--verify")
        restored = Path(target) / "salvage/volume"
        self.assertEqual((restored / "payload.bin").read_bytes(), Path("/salvage/volume/payload.bin").read_bytes())
        self.assertEqual((restored / "empty").read_bytes(), b"")
        self.assertEqual(os.readlink(restored / "link"), "payload.bin")
        self.assertEqual((restored / "payload.bin").stat().st_mode & 0o777, 0o640)
        self.assertEqual((Path(target) / "salvage/meta/meta.json").read_bytes(), Path("/salvage/meta/meta.json").read_bytes())
        self.restic("check", "--read-data")

    def test_init_and_wrong_password_preserve_repository(self):
        self.crane()
        original = self.snapshots()
        result = self.crane(success=False, RESTIC_PASSWORD="wrong", FORGET_ARGS="--keep-last 1", DO_PRUNE="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Initializing", result.stderr)
        self.assertEqual(self.snapshots(), original)

    def test_failed_check_preserves_old_snapshots(self):
        self.restic("init")
        old = self.seed("volume-a")
        # A genuinely invalid check request must stop before retention.
        result = self.crane(success=False, FORGET_ARGS="--keep-last 1", DO_PRUNE="true",
                            VERIFY_REPOSITORY_CHECK="true", VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET="invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(old, {s["id"] for s in self.snapshots()})
        self.assertNotIn("Running forget", result.stderr)

    def test_excluded_volume_cannot_trigger_retention(self):
        self.restic("init")
        old = self.seed("volume-a")
        result = self.crane(success=False, BACKUP_ARGS="--exclude /salvage/volume", FORGET_ARGS="--keep-last 1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(old, {s["id"] for s in self.snapshots()})
        self.assertNotIn("Running forget", result.stderr)

    def test_ssh_uses_configured_paths_and_strict_policy(self):
        fakebin = Path(self.tmp.name) / "bin"
        fakebin.mkdir()
        ssh = fakebin / "ssh"
        ssh.write_text('#!/usr/bin/python3\nimport json, os, sys\nopen(os.environ["SSH_LOG"], "w").write(json.dumps(sys.argv[1:]))\nsys.exit(1)\n')
        ssh.chmod(0o755)
        key = Path(self.tmp.name) / "key with 'quote"
        known = Path(self.tmp.name) / "known hosts"
        key.write_text("fake-test-key")
        known.write_text("fake-test-host")
        log = Path(self.tmp.name) / "ssh.json"
        result = self.crane(success=False, REPO_BASE_LOCATION="sftp://user@host:23//absolute",
                            SSH_KEY_FILE=str(key), SSH_KNOWN_HOSTS_FILE=str(known), SSH_LOG=str(log),
                            PATH=f"{fakebin}:/usr/bin:/bin")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(log.exists(), result.stdout + result.stderr)
        args = json.loads(log.read_text())
        self.assertIn(str(key), args)
        self.assertIn(f'UserKnownHostsFile="{known}"', args)
        self.assertIn("-oStrictHostKeyChecking=yes", args)
        self.assertIn("-oBatchMode=yes", args)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--restic", default=shutil.which("restic"))
    parser.add_argument("--crane", default=str(ROOT / "binary.sh"))
    args = parser.parse_args()
    if args.inside:
        unittest.main(argv=[sys.argv[0]], verbosity=2)
        return
    if not args.restic or not shutil.which("bwrap"):
        parser.error("Install restic and bubblewrap, or pass --restic /path/to/restic")
    with tempfile.TemporaryDirectory(prefix="restic-crane-integration-") as tmp:
        # Namespace root cannot traverse a runner-owned private home directory.
        # Stage only the test inputs under our own temporary directory instead
        # of weakening checkout permissions or disabling namespace isolation.
        work = Path(tmp) / "work"
        shutil.copytree(ROOT, work)
        crane = Path(tmp) / "crane"
        restic = Path(tmp) / "restic"
        shutil.copy2(Path(args.crane).resolve(), crane)
        shutil.copy2(Path(args.restic).resolve(), restic)
        volume = Path(tmp) / "volume"
        meta = Path(tmp) / "meta"
        volume.mkdir()
        meta.mkdir()
        (volume / "payload.bin").write_bytes(bytes(range(256)) * 4096)
        (volume / "payload.bin").chmod(0o640)
        (volume / "empty").touch()
        (volume / "link").symlink_to("payload.bin")
        (meta / "meta.json").write_text('{"test": "metadata"}\n')
        command = ["bwrap", "--unshare-all", "--die-with-parent", "--tmpfs", "/",
                   "--ro-bind", "/usr", "/usr", "--symlink", "usr/bin", "/bin",
                   "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
                   "--ro-bind", "/etc", "/etc", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
                   "--ro-bind", str(work), "/work", "--ro-bind", str(crane), "/crane",
                   "--ro-bind", str(restic), "/restic",
                   "--ro-bind", str(volume), "/salvage/volume", "--ro-bind", str(meta), "/salvage/meta",
                   "--chdir", "/work", "/usr/bin/python3", "/work/tests/integration.py", "--inside"]
        sys.exit(subprocess.call(command))


if __name__ == "__main__":
    main()
