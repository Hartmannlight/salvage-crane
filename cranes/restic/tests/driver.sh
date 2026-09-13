#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../binary.sh
source "$TEST_DIR/../binary.sh"
# shellcheck source=mock-restic.sh
source "$TEST_DIR/mock-restic.sh"
validate_runtime_mounts() { :; }
validate_sftp_runtime_inputs() { :; }
run_restic() { run_testing_restic "$@"; }
main
