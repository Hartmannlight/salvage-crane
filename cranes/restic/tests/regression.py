#!/usr/bin/env python3
"""Failure-path and helper regressions; no Docker or live repository required."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENV = {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/tmp"),
       "SALVAGE_MACHINE_NAME": "machine", "SALVAGE_CRANE_NAME": "restic",
       "SALVAGE_VOLUME_NAME": "volume", "SALVAGE_TIDE_TIMESTAMP": "1626262626",
       "REPO_BASE_LOCATION": "/repo", "RESTIC_PASSWORD": "test-only"}


def run_script(code, **env):
    return subprocess.run(["bash", "-c", code], env=ENV | env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def crane(**env):
    return run_script('bash "$CRANE_DRIVER"', CRANE_DRIVER=str(ROOT / "tests/driver.sh"), **env)


class RegressionTests(unittest.TestCase):
    def test_retention_requires_all_tags(self):
        result = crane(FORGET_ARGS="--keep-last 1")
        self.assertEqual(result.returncode, 0, result.stdout)
        forget = next(line for line in result.stdout.splitlines() if "[TESTING]" in line and " forget " in line)
        self.assertEqual(forget.count("--tag "), 1, forget)
        self.assertIn("--tag salvage,vol-volume,machine-machine,crane-restic", forget)

    def test_retention_rejects_filter_bypasses_before_backup(self):
        for args in ("--keep-last 1 deadbeef", "--keep-last 1 --host other", "--tag salvage --keep-last 1",
                     "--keep-last 1 --repo /other", "--keep-last 1 --prune", "--unsafe-allow-remove-all",
                     "--keep-last 0", "--keep-last", "--keep-within 0d", "--keep-last 1\n--prune"):
            with self.subTest(args=args):
                result = crane(FORGET_ARGS=args)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("[TESTING]", result.stdout)

    def test_failures_never_reach_retention(self):
        for failure in ({"TESTING_BACKUP_RC": "3"}, {"TESTING_BACKUP_RC": "1"},
                        {"TESTING_BACKUP_NO_SNAPSHOT": "true"}, {"TESTING_SNAPSHOT_EXISTS": "false"},
                        {"TESTING_DUMP_RC": "1"}, {"VERIFY_REPOSITORY_CHECK": "true", "TESTING_CHECK_RC": "1"}):
            with self.subTest(failure=failure):
                result = crane(FORGET_ARGS="--keep-last 1", DO_PRUNE="true", **failure)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn(" forget ", result.stdout)

    def test_forget_failure_propagates(self):
        result = crane(FORGET_ARGS="--keep-last 1", TESTING_FORGET_RC="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("Done.", result.stdout)

    def test_sftp_absolute_and_relative_paths_in_all_entrypoints(self):
        for script in (ROOT / "binary.sh", ROOT / "tools/install.sh", ROOT / "tools/preflight.sh"):
            result = run_script('source "$SCRIPT"; build_sftp_repo_location host user 23 /absolute; echo; '
                                'build_sftp_repo_location host user 23 relative', SCRIPT=str(script))
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(result.stdout, 'sftp://user@host:23//absolute\nsftp://user@host:23/relative')

    def test_ssh_options_are_passed_for_both_sftp_syntaxes(self):
        for repo in ("sftp://user@host:23/repo", "sftp:user@host:repo"):
            result = crane(REPO_BASE_LOCATION=repo, SSH_KEY_FILE="/key with spaces", SSH_KNOWN_HOSTS_FILE="/known hosts")
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("StrictHostKeyChecking=yes", result.stdout)
            self.assertIn("BatchMode=yes", result.stdout)
            self.assertIn('/key with spaces', result.stdout)
            self.assertIn('UserKnownHostsFile=', result.stdout)
            self.assertIn('/known hosts', result.stdout)
        result = crane(REPO_BASE_LOCATION=repo, STRICT_HOST_KEY_CHECKING="false")
        self.assertIn("StrictHostKeyChecking=no", result.stdout)

    def test_global_args_cannot_disable_locking_or_change_scope(self):
        for args in ("--no-lock", "--tag salvage", "--host other", "--repo /other", "-o sftp.command=ssh"):
            result = crane(RESTIC_ARGS=args)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertNotIn("[TESTING]", result.stdout)

    def test_backup_args_cannot_bypass_crane_sources(self):
        for args in ("--repo /other", "--host other", "--stdin", "--stdin-from-command", "--no-lock",
                     "--time=2020-01-01", "--files-from /list", "--exclude", "--exclude a\n--repo /other"):
            result = crane(BACKUP_ARGS=args, VERIFY_SNAPSHOT="false", FORGET_ARGS="--keep-last 1")
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertNotIn("[TESTING]", result.stdout)

    def test_sftp_helpers_detect_rotating_mixed_targets(self):
        for script in (ROOT / "tools/install.sh", ROOT / "tools/preflight.sh"):
            result = run_script('source "$SCRIPT"; is_sftp_repo "/local; sftp:user@host:repo"', SCRIPT=str(script))
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_strict_install_requires_verified_host_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script('source "$SCRIPT"; prepare_known_hosts_file sftp://user@host:23/repo "$TMPDIR"',
                                SCRIPT=str(ROOT / "tools/install.sh"), TMPDIR=tmp)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("independently verified host keys", result.stdout)

    def test_globs_remain_literal(self):
        result = crane(BACKUP_ARGS="--exclude *")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("--exclude * /salvage/meta", result.stdout)

    def test_rotation_and_decimal_timestamp(self):
        for stamp, repo in (("000000086400", "/b"), ("172800", "/c"), ("259200", "/a")):
            result = crane(SALVAGE_TIDE_TIMESTAMP=stamp, REPO_BASE_LOCATION="/a;/b;/c")
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn(f"Repository: {repo} ", result.stdout)
        for bad in (";;;", "/a\n/b"):
            result = crane(REPO_BASE_LOCATION=bad)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("[TESTING]", result.stdout)
            self.assertNotIn("division by 0", result.stdout)

    def test_identity_cannot_change_tag_or_repository_scope(self):
        for name in ("SALVAGE_VOLUME_NAME", "SALVAGE_MACHINE_NAME", "SALVAGE_CRANE_NAME"):
            for value in ("a,b", "../other", ".."):
                result = crane(**{name: value})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("[TESTING]", result.stdout)

    def test_testing_flag_cannot_report_fake_success(self):
        result = run_script('bash "$SCRIPT"', SCRIPT=str(ROOT / "binary.sh"), TESTING="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("[TESTING]", result.stdout)

    def test_env_example_is_valid_shell(self):
        result = run_script('source "$SCRIPT"; printf "%s" "$TIDE_CRON"', SCRIPT=str(ROOT / "tools/.env.example"))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "0 3 * * *")

    def test_runtime_env_roundtrip_is_literal(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script('source "$SCRIPT"; write_runtime_env_file "$REPO_BASE_LOCATION"; '
                                'source "$RUNTIME_ENV_FILE"; printf "%s\\n" "$TIDE_CRON" "$FORGET_ARGS" "$REPO_BASE_LOCATION"',
                                SCRIPT=str(ROOT / "tools/install.sh"), RUNTIME_ENV_FILE=f"{tmp}/runtime.env",
                                MACHINE="host", TIDE_NAME="nightly", TIDE_CRON="0 3 * * *", TIDE_GROUPING="project",
                                TIDE_MAX_CONCURRENT="1", RESTIC_SSH_VOLUME="ssh", RESTIC_SECRETS_VOLUME="secrets",
                                RESTIC_CACHE_VOLUME="cache", RESTIC_PASSWORD_FILENAME="password",
                                FORGET_ARGS="--keep-last 7", REPO_BASE_LOCATION='/a;/b/$literal/$(false)')
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(result.stdout, '0 3 * * *\n--keep-last 7\n/a;/b/$literal/$(false)\n')

    def test_installer_cleanup_on_success_and_failure(self):
        for docker_rc in (0, 1):
            with self.subTest(docker_rc=docker_rc), tempfile.TemporaryDirectory() as tmp:
                docker = Path(tmp) / "docker"
                docker.write_text(f"#!/bin/sh\nexit {docker_rc}\n")
                docker.chmod(0o755)
                config = Path(tmp) / "config"
                config.touch()
                result = run_script('bash "$SCRIPT"', SCRIPT=str(ROOT / "tools/install.sh"),
                                    PATH=f'{tmp}:{ENV["PATH"]}', TMPDIR=tmp, ENV_FILE=str(config),
                                    RUNTIME_ENV_FILE=f"{tmp}/runtime", MACHINE="host", TIDE_NAME="nightly",
                                    TIDE_CRON="0 3 * * *", TIDE_GROUPING="project", TIDE_MAX_CONCURRENT="1",
                                    RESTIC_SSH_VOLUME="ssh", RESTIC_SECRETS_VOLUME="secrets",
                                    RESTIC_CACHE_VOLUME="cache", RESTIC_PASSWORD_FILENAME="password", BUILD_RESTIC_IMAGE="false")
                self.assertEqual(result.returncode, docker_rc, result.stdout)
                self.assertFalse(any(p.is_dir() for p in Path(tmp).iterdir()), "Secret temp directory leaked")

    def test_smoke_disables_retention_and_cleans_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            docker = Path(tmp) / "docker"
            docker.write_text('#!/bin/sh\nprintf "DOCKER %s\\n" "$@"\n')
            docker.chmod(0o755)
            result = run_script('bash "$SCRIPT" existing', SCRIPT=str(ROOT / "tools/run-crane-smoke.sh"),
                                PATH=f'{tmp}:{ENV["PATH"]}', TMPDIR=tmp, ENV_FILE=f"{tmp}/missing", RUNTIME_ENV_FILE=f"{tmp}/missing",
                                MACHINE='host"quoted', RESTIC_CRANE_IMAGE="image", RESTIC_SSH_VOLUME="ssh",
                                RESTIC_SECRETS_VOLUME="secrets", RESTIC_CACHE_VOLUME="cache", RESTIC_PASSWORD_FILENAME="password",
                                FORGET_ARGS="--keep-last 1", DO_PRUNE="true")
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("DOCKER FORGET_ARGS=\n", result.stdout)
            self.assertIn("DOCKER DO_PRUNE=false\n", result.stdout)
            self.assertNotIn("--keep-last", result.stdout)
            self.assertFalse(any(p.is_dir() for p in Path(tmp).iterdir()), "Metadata temp directory leaked")

    def repository_env(self, tmp):
        return dict(SCRIPT=str(ROOT / "tools/repository.sh"), ENV_FILE=f"{tmp}/missing", RUNTIME_ENV_FILE=f"{tmp}/missing",
                    MACHINE="host", RESTIC_CRANE_IMAGE="image", RESTIC_SSH_VOLUME="ssh", RESTIC_SECRETS_VOLUME="secrets",
                    RESTIC_CACHE_VOLUME="cache", RESTIC_PASSWORD_FILENAME="password")

    def test_repository_refuses_nonempty_restore_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "restore"
            target.mkdir()
            (target / "valuable.txt").write_text("keep me")
            result = run_script('bash "$SCRIPT" restore volume latest "$TARGET"', TARGET=str(target), **self.repository_env(tmp))
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("Restore target must be empty", result.stdout)
            self.assertEqual((target / "valuable.txt").read_text(), "keep me")

    def test_repository_refuses_symlink_restore_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "link"
            target.symlink_to(tmp)
            result = run_script('bash "$SCRIPT" restore volume latest "$TARGET"', TARGET=str(target), **self.repository_env(tmp))
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("must not be a symlink", result.stdout)

    def test_repository_rotation_requires_explicit_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = run_script('bash "$SCRIPT" snapshots volume', REPO_BASE_LOCATION="/repo/a;/repo/b", **self.repository_env(tmp))
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("REPOSITORY_BASE_OVERRIDE", result.stdout)

    def test_repository_does_not_create_missing_credential_volumes(self):
        with tempfile.TemporaryDirectory() as tmp:
            docker = Path(tmp) / "docker"
            docker.write_text('#!/bin/sh\nprintf "DOCKER %s\\n" "$@" >&2\nexit 1\n')
            docker.chmod(0o755)
            result = run_script('bash "$SCRIPT" snapshots volume', PATH=f'{tmp}:{ENV["PATH"]}', **self.repository_env(tmp))
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("DOCKER inspect", result.stdout)
            self.assertNotIn("DOCKER run", result.stdout)

    def test_hetzner_setup_does_not_overwrite_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config"
            config.write_text("existing config")
            result = run_script('bash "$SCRIPT" u12345-sub1', SCRIPT=str(ROOT / "tools/setup-hetzner.sh"), ENV_FILE=str(config))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already exists", result.stdout)
            self.assertEqual(config.read_text(), "existing config")

    def test_hetzner_setup_rejects_unverified_host_before_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name, body in {"ssh-keyscan": "echo fake-key", "ssh-keygen": "echo 256 SHA256:wrong hostname",
                               "docker": "exit 1", "ssh": "echo UNEXPECTED-AUTH; exit 1"}.items():
                path = Path(tmp) / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            setup = Path(tmp) / "setup"
            result = run_script('bash "$SCRIPT" u12345-sub1', SCRIPT=str(ROOT / "tools/setup-hetzner.sh"),
                                ENV_FILE=f"{tmp}/config", HETZNER_SETUP_DIR=str(setup), PATH=f'{tmp}:{ENV["PATH"]}')
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("Host fingerprint mismatch", result.stdout)
            self.assertNotIn("UNEXPECTED-AUTH", result.stdout)
            self.assertFalse((setup / "id_ed25519").exists())
            self.assertFalse((setup / "known_hosts").exists())

    def test_smoke_missing_volume_stops_before_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            docker = Path(tmp) / "docker"
            docker.write_text('#!/bin/sh\necho "DOCKER $*"\nexit 1\n')
            docker.chmod(0o755)
            result = run_script('bash "$SCRIPT" nonexistent', SCRIPT=str(ROOT / "tools/run-crane-smoke.sh"),
                                PATH=f'{tmp}:{ENV["PATH"]}', ENV_FILE=f"{tmp}/missing", RUNTIME_ENV_FILE=f"{tmp}/missing",
                                MACHINE="host", RESTIC_CRANE_IMAGE="image", RESTIC_SSH_VOLUME="ssh",
                                RESTIC_SECRETS_VOLUME="secrets", RESTIC_CACHE_VOLUME="cache", RESTIC_PASSWORD_FILENAME="password")
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("DOCKER run", result.stdout)
            self.assertIn("Source volume does not exist", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
