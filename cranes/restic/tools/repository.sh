#!/usr/bin/env bash
# Inspect and restore using the same image, credentials and SSH policy as backups.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "[repository][ERROR] $*" >&2; exit 1; }

main() {
  local config
  for config in "${ENV_FILE:-$SCRIPT_DIR/.env}" "${RUNTIME_ENV_FILE:-$SCRIPT_DIR/.runtime.env}"; do
    if [[ -f "$config" ]]; then
      set -a
      # shellcheck disable=SC1090
      source "$config"
      set +a
    fi
  done
  local action="${1:-}" volume="${2:-}" snapshot="${3:-}" target="${4:-}"
  case "$action" in
    snapshots|check) [[ $# -eq 2 ]] || die "Usage: $0 $action <volume>" ;;
    restore) [[ $# -eq 4 ]] || die "Usage: $0 restore <volume> <snapshot-id|latest> <empty-directory>" ;;
    *) die "Usage: $0 {snapshots|check} <volume> OR restore <volume> <snapshot-id|latest> <empty-directory>" ;;
  esac
  [[ -n "$volume" ]] || die "Volume name is required."
  local name
  for name in MACHINE REPO_BASE_LOCATION RESTIC_CRANE_IMAGE RESTIC_SSH_VOLUME RESTIC_SECRETS_VOLUME RESTIC_CACHE_VOLUME RESTIC_PASSWORD_FILENAME; do
    [[ -n "${!name:-}" ]] || die "Missing $name; run install.sh first."
  done
  local repo="${REPOSITORY_BASE_OVERRIDE:-$REPO_BASE_LOCATION}"
  [[ "$repo" != *';'* ]] || die "For rotated repositories, set REPOSITORY_BASE_OVERRIDE to one base location. Inspect each repository separately."
  local -a args=(--rm
    --mount "type=volume,src=$RESTIC_SSH_VOLUME,dst=/root/.ssh,readonly"
    --mount "type=volume,src=$RESTIC_SECRETS_VOLUME,dst=/run/secrets,readonly"
    --mount "type=volume,src=$RESTIC_CACHE_VOLUME,dst=/cache"
    -e "SALVAGE_MACHINE_NAME=$MACHINE" -e "SALVAGE_CRANE_NAME=${CRANE_NAME:-restic}"
    -e "SALVAGE_VOLUME_NAME=$volume" -e "SALVAGE_TIDE_TIMESTAMP=$(date +%s)"
    -e "REPO_BASE_LOCATION=$repo" -e "SINGLE_REPO=${SINGLE_REPO:-true}"
    -e "RESTIC_PASSWORD_FILE=/run/secrets/$RESTIC_PASSWORD_FILENAME" -e RESTIC_CACHE_DIR=/cache
    -e "RESTIC_HOST=${RESTIC_HOST:-}" -e "RESTIC_RETRY_LOCK=${RESTIC_RETRY_LOCK:-2h}"
    -e "RESTIC_ARGS=${RESTIC_ARGS:-}" -e "STRICT_HOST_KEY_CHECKING=${STRICT_HOST_KEY_CHECKING:-true}")
  if [[ "$action" == restore ]]; then
    [[ "$snapshot" == latest || "$snapshot" =~ ^[a-f0-9]{8,64}$ ]] || die "Expected a snapshot ID or latest."
    [[ ! -L "$target" ]] || die "Restore target must not be a symlink."
    mkdir -p -- "$target"
    target="$(cd "$target" && pwd -P)"
    [[ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "Restore target must be empty."
    args+=(--mount "type=bind,src=$target,dst=/restore")
  fi
  # Fail on misspelled credential volumes instead of silently creating empty ones.
  docker volume inspect "$RESTIC_SSH_VOLUME" "$RESTIC_SECRETS_VOLUME" "$RESTIC_CACHE_VOLUME" >/dev/null
  docker run "${args[@]}" --entrypoint bash "$RESTIC_CRANE_IMAGE" -euc '
    source /bin/binary.sh
    configure_crane
    validate_sftp_runtime_inputs
    configure_sftp
    filter="$TAG_MAIN,$TAG_VOL,$TAG_MACHINE,$TAG_CRANE"
    case "$1" in
      snapshots) run_restic "${GLOBAL_ARGS[@]}" snapshots --json --host "$RESTIC_HOST" --tag "$filter" ;;
      check) run_restic "${GLOBAL_ARGS[@]}" check --read-data ;;
      restore)
        if [[ "$2" == latest ]]; then
          run_restic "${GLOBAL_ARGS[@]}" restore latest --host "$RESTIC_HOST" --tag "$filter" --target /restore --verify
          exit
        fi
        snapshots="$(run_restic "${GLOBAL_ARGS[@]}" snapshots --json --host "$RESTIC_HOST" --tag "$filter")"
        id="$(printf "%s" "$snapshots" | jq -er --arg requested "$2" '\''
          [.[] | select(.id | startswith($requested))] |
            if length == 1 then .[0].id else empty end
        '\'')" || die "Snapshot not found or ambiguous for this volume, machine and crane."
        run_restic "${GLOBAL_ARGS[@]}" restore "$id" --target /restore --verify
        ;;
    esac
  ' repository "$action" "$snapshot"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
