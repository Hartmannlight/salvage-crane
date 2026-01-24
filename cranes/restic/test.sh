#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/binary.sh"

run_case() {
  local name="$1"
  local expected="$2"
  shift 2

  echo ""
  echo "=== ${name} ==="
  set +e
  env TESTING=true "$@" bash "$SCRIPT_PATH" >/dev/null 2>&1
  local rc=$?
  set -e

  if [[ "$rc" -ne "$expected" ]]; then
    echo "FAIL: expected exit ${expected}, got ${rc}"
    return 1
  fi
  echo "OK (exit ${rc})"
}

BASE_ENV=(
  "SALVAGE_MACHINE_NAME=testmachine"
  "SALVAGE_CRANE_NAME=restic"
  "SALVAGE_VOLUME_NAME=testvolume"
  "SALVAGE_TIDE_TIMESTAMP=1626262626"
  "REPO_BASE_LOCATION=/repo/a;/repo/b;/repo/c"
  "RESTIC_PASSWORD=secret"
)

run_case "Basic single repo" 0 "${BASE_ENV[@]}" "SINGLE_REPO=true"
run_case "Multi repo mode" 0 "${BASE_ENV[@]}" "SINGLE_REPO=false"
run_case "Repo rotation (different day)" 0 "${BASE_ENV[@]}" "SALVAGE_TIDE_TIMESTAMP=1626349026"
run_case "Retention enabled" 0 "${BASE_ENV[@]}" "FORGET_ARGS=--keep-last 1"

run_case "Missing SALVAGE_TIDE_TIMESTAMP" 1 \
  "SALVAGE_MACHINE_NAME=testmachine" "SALVAGE_CRANE_NAME=restic" "SALVAGE_VOLUME_NAME=testvolume" \
  "REPO_BASE_LOCATION=/repo/a" "RESTIC_PASSWORD=secret"

run_case "Empty REPO_BASE_LOCATION" 1 "${BASE_ENV[@]}" "REPO_BASE_LOCATION=;;;"
run_case "Missing password" 1 "${BASE_ENV[@]}" "RESTIC_PASSWORD="
run_case "Invalid SINGLE_REPO" 1 "${BASE_ENV[@]}" "SINGLE_REPO=maybe"

echo ""
echo "All tests done"
