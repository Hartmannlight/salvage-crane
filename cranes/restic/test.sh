#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/tests/driver.sh"

run_case() {
  local name="$1"
  local expected="$2"
  shift 2

  echo
  echo "=== ${name} ==="
  set +e
  local output
  output="$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" "$@" bash "$SCRIPT_PATH" 2>&1)"
  local rc=$?
  set -e

  if [[ "$rc" -ne "$expected" ]]; then
    echo "FAIL: expected exit ${expected}, got ${rc}"
    echo "Output:"
    echo "$output"
    return 1
  fi
  echo "OK (exit ${rc})"
}

COMMON_ENV=(
  "SALVAGE_MACHINE_NAME=testmachine"
  "SALVAGE_CRANE_NAME=restic"
  "SALVAGE_VOLUME_NAME=testvolume"
  "SALVAGE_TIDE_TIMESTAMP=1626262626"
)

run_case "Basic single repo" 0 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a;/repo/b;/repo/c" \
  "RESTIC_PASSWORD=secret" \
  "SINGLE_REPO=true"

run_case "Multi repo mode" 0 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a;/repo/b;/repo/c" \
  "RESTIC_PASSWORD=secret" \
  "SINGLE_REPO=false"

run_case "Repo rotation (different day)" 0 "${COMMON_ENV[@]}" \
  "SALVAGE_TIDE_TIMESTAMP=1626349026" \
  "REPO_BASE_LOCATION=/repo/a;/repo/b;/repo/c" \
  "RESTIC_PASSWORD=secret"

run_case "SFTP env based repo config" 0 "${COMMON_ENV[@]}" \
  "SFTP_HOST=storagebox.example.net" \
  "SFTP_USER=u12345-sub1" \
  "SFTP_PORT=23" \
  "SFTP_PATH=salvage" \
  "RESTIC_PASSWORD=secret"

run_case "Retention enabled with prune" 0 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a" \
  "RESTIC_PASSWORD=secret" \
  "FORGET_ARGS=--keep-last 1" \
  "DO_PRUNE=true"

run_case "Missing repo configuration" 1 "${COMMON_ENV[@]}" \
  "RESTIC_PASSWORD=secret"

run_case "Incomplete SFTP configuration" 1 "${COMMON_ENV[@]}" \
  "SFTP_HOST=storagebox.example.net" \
  "RESTIC_PASSWORD=secret"

run_case "Invalid SFTP_PORT" 1 "${COMMON_ENV[@]}" \
  "SFTP_HOST=storagebox.example.net" \
  "SFTP_USER=u12345-sub1" \
  "SFTP_PORT=abc" \
  "SFTP_PATH=salvage" \
  "RESTIC_PASSWORD=secret"

run_case "Missing password" 1 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a"

run_case "Empty REPO_BASE_LOCATION" 1 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=;;;" \
  "RESTIC_PASSWORD=secret"

run_case "Invalid SINGLE_REPO" 1 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a" \
  "RESTIC_PASSWORD=secret" \
  "SINGLE_REPO=maybe"

run_case "Backup incomplete snapshot (rc=3)" 1 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a" \
  "RESTIC_PASSWORD=secret" \
  "TESTING_BACKUP_RC=3"

run_case "Backup without snapshot id is rejected" 1 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a" \
  "RESTIC_PASSWORD=secret" \
  "TESTING_BACKUP_NO_SNAPSHOT=true"

run_case "Snapshot verification failure is rejected" 1 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a" \
  "RESTIC_PASSWORD=secret" \
  "TESTING_SNAPSHOT_EXISTS=false"

run_case "Metadata verification failure is rejected" 1 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a" \
  "RESTIC_PASSWORD=secret" \
  "TESTING_DUMP_RC=1"

run_case "Repository init failure is rejected" 1 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a" \
  "RESTIC_PASSWORD=secret" \
  "TESTING_REPO_EXISTS=false" \
  "TESTING_INIT_RC=1"

run_case "Optional repository check failure is rejected" 1 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a" \
  "RESTIC_PASSWORD=secret" \
  "VERIFY_REPOSITORY_CHECK=true" \
  "TESTING_CHECK_RC=1"

run_case "Snapshot verification can be disabled explicitly" 0 "${COMMON_ENV[@]}" \
  "REPO_BASE_LOCATION=/repo/a" \
  "RESTIC_PASSWORD=secret" \
  "VERIFY_SNAPSHOT=false" \
  "TESTING_SNAPSHOT_EXISTS=false" \
  "TESTING_DUMP_RC=1"

echo
python3 "$SCRIPT_DIR/tests/regression.py"
echo "All tests done"
