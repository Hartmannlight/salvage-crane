#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
RUNTIME_ENV_FILE="${RUNTIME_ENV_FILE:-${SCRIPT_DIR}/.runtime.env}"

log()  { echo "[smoke] $*"; }
die()  { echo "[smoke][ERROR] $*" >&2; exit 1; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

require_non_empty() {
  local name="$1"
  local value
  value="$(trim "${!name:-}")"
  [[ -n "$value" ]] || die "Missing required variable: $name"
}

load_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  fi
}

main() {
  require_cmd docker
  require_cmd date

  load_if_exists "$ENV_FILE"
  load_if_exists "$RUNTIME_ENV_FILE"

  local target_volume="${1:-${TARGET_VOLUME:-}}"
  [[ -n "$(trim "$target_volume")" ]] || die "Usage: $0 <docker-volume-name> (or set TARGET_VOLUME)"

  require_non_empty MACHINE
  require_non_empty REPO_BASE_LOCATION
  require_non_empty RESTIC_CRANE_IMAGE
  require_non_empty RESTIC_SSH_VOLUME
  require_non_empty RESTIC_SECRETS_VOLUME
  require_non_empty RESTIC_CACHE_VOLUME
  require_non_empty RESTIC_PASSWORD_FILENAME

  local tide_timestamp
  tide_timestamp="$(date +%s)"

  local tmp_meta
  tmp_meta="$(mktemp -d)"
  trap 'rm -rf "$tmp_meta"' EXIT

  cat > "${tmp_meta}/meta.json" <<EOF
{
  "hostMeta": {
    "startTime": ${tide_timestamp}000,
    "executionStart": ${tide_timestamp}000,
    "host": "${MACHINE}"
  },
  "volumeMeta": {
    "name": "${target_volume}"
  },
  "crane": "restic-smoke",
  "image": "${RESTIC_CRANE_IMAGE}"
}
EOF

  log "Running smoke backup for volume: ${target_volume}"
  docker run --rm \
    -v "${target_volume}:/salvage/volume:ro" \
    -v "${tmp_meta}:/salvage/meta:ro" \
    -v "${RESTIC_SSH_VOLUME}:/root/.ssh:ro" \
    -v "${RESTIC_SECRETS_VOLUME}:/run/secrets:ro" \
    -v "${RESTIC_CACHE_VOLUME}:/cache" \
    -e SALVAGE_MACHINE_NAME="${MACHINE}" \
    -e SALVAGE_CRANE_NAME="restic" \
    -e SALVAGE_VOLUME_NAME="${target_volume}" \
    -e SALVAGE_TIDE_TIMESTAMP="${tide_timestamp}" \
    -e REPO_BASE_LOCATION="${REPO_BASE_LOCATION}" \
    -e RESTIC_PASSWORD_FILE="/run/secrets/${RESTIC_PASSWORD_FILENAME}" \
    -e RESTIC_CACHE_DIR="/cache" \
    -e SINGLE_REPO="${SINGLE_REPO:-true}" \
    -e RESTIC_RETRY_LOCK="${RESTIC_RETRY_LOCK:-2h}" \
    -e FORGET_ARGS="${FORGET_ARGS:-}" \
    -e DO_PRUNE="${DO_PRUNE:-false}" \
    -e VERIFY_SNAPSHOT="${VERIFY_SNAPSHOT:-true}" \
    -e VERIFY_REPOSITORY_CHECK="${VERIFY_REPOSITORY_CHECK:-false}" \
    -e VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET="${VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET:-1/200}" \
    -e STRICT_HOST_KEY_CHECKING="${STRICT_HOST_KEY_CHECKING:-true}" \
    "${RESTIC_CRANE_IMAGE}"

  log "Smoke backup completed successfully."
}

main "$@"
