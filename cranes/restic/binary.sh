#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[restic-crane] $*" >&2; }
warn() { echo "[restic-crane][WARN] $*" >&2; }
die()  { echo "[restic-crane][ERROR] $*" >&2; exit 1; }

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "Missing required environment variable: $name"
  fi
}

require_int() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "$value" ]]; then
    die "Missing required environment variable: $name"
  fi
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die "Environment variable '$name' must be an integer (epoch seconds)."
  fi
}

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    0|false|no|n|off|"") return 1 ;;
    *) die "Invalid boolean value: '$1' (expected true/false)" ;;
  esac
}

split_repos() {
  local raw="$1"
  local -a out=()
  local IFS=';'
  read -ra parts <<< "$raw"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    if [[ -n "$p" ]]; then
      out+=("$p")
    fi
  done
  if [[ "${#out[@]}" -eq 0 ]]; then
    die "REPO_BASE_LOCATION is empty (or only contains separators)."
  fi
  printf '%s\0' "${out[@]}"
}

join_path() {
  local base="$1"
  local add="$2"
  if [[ "$base" == */ ]]; then
    printf '%s%s' "$base" "$add"
  else
    printf '%s/%s' "$base" "$add"
  fi
}

# Required by Salvage interface
require_env SALVAGE_MACHINE_NAME
require_env SALVAGE_CRANE_NAME
require_env SALVAGE_VOLUME_NAME
require_int SALVAGE_TIDE_TIMESTAMP

# Crane configuration
require_env REPO_BASE_LOCATION

if [[ -z "${RESTIC_PASSWORD_FILE:-}" && -z "${RESTIC_PASSWORD:-}" ]]; then
  die "Either RESTIC_PASSWORD_FILE or RESTIC_PASSWORD must be set."
fi

SINGLE_REPO="${SINGLE_REPO:-true}"
RETRY_LOCK="${RESTIC_RETRY_LOCK:-1h}"
FORGET_ARGS="${FORGET_ARGS:-}"
DO_PRUNE="${DO_PRUNE:-false}"
RESTIC_GLOBAL_ARGS="${RESTIC_ARGS:-}"
BACKUP_ARGS="${BACKUP_ARGS:-}"

DEFAULT_HOST="${SALVAGE_MACHINE_NAME}-${SALVAGE_VOLUME_NAME}"
RESTIC_HOST="${RESTIC_HOST:-$DEFAULT_HOST}"

TAG_MAIN="salvage"
TAG_VOL="vol-${SALVAGE_VOLUME_NAME}"
TAG_MACHINE="machine-${SALVAGE_MACHINE_NAME}"
TAG_CRANE="crane-${SALVAGE_CRANE_NAME}"

mapfile -d '' REPOS < <(split_repos "$REPO_BASE_LOCATION")
DAY_INDEX=$(( SALVAGE_TIDE_TIMESTAMP / 86400 ))
REPO_INDEX=$(( DAY_INDEX % ${#REPOS[@]} ))
REPO_BASE="${REPOS[$REPO_INDEX]}"

if is_true "$SINGLE_REPO"; then
  RESTIC_REPOSITORY="$REPO_BASE"
  MODE_DESC="single repo"
else
  RESTIC_REPOSITORY="$(join_path "$REPO_BASE" "${SALVAGE_MACHINE_NAME}/${SALVAGE_VOLUME_NAME}")"
  MODE_DESC="multi repo (per-volume repository)"
fi

export RESTIC_REPOSITORY

if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
  export RESTIC_PASSWORD_FILE
fi
if [[ -n "${RESTIC_PASSWORD:-}" ]]; then
  export RESTIC_PASSWORD
fi
if [[ -n "${RESTIC_CACHE_DIR:-}" ]]; then
  export RESTIC_CACHE_DIR
fi

RESTIC_BIN="${RESTIC_BIN:-restic}"

log "Crane: ${SALVAGE_CRANE_NAME}"
log "Machine: ${SALVAGE_MACHINE_NAME}"
log "Volume: ${SALVAGE_VOLUME_NAME}"
log "Tide timestamp: ${SALVAGE_TIDE_TIMESTAMP}"
log "Repository: ${RESTIC_REPOSITORY} (${MODE_DESC})"
log "Host: ${RESTIC_HOST}"
log "Tags: ${TAG_MAIN}, ${TAG_VOL}, ${TAG_MACHINE}, ${TAG_CRANE}"

run_restic() {
  if is_true "${TESTING:-false}"; then
    echo "[TESTING] restic $*" >&2
    return 0
  fi
  "$RESTIC_BIN" "$@"
}

build_global_args() {
  local -a args=()
  args+=(--retry-lock "$RETRY_LOCK")
  if [[ -n "$RESTIC_GLOBAL_ARGS" ]]; then
    # shellcheck disable=SC2206
    args+=( $RESTIC_GLOBAL_ARGS )
  fi
  printf '%s\0' "${args[@]}"
}

mapfile -d '' GLOBAL_ARGS < <(build_global_args)

if ! is_true "${TESTING:-false}"; then
  [[ -d /salvage/volume ]] || die "/salvage/volume not found (mount missing?)"
  [[ -d /salvage/meta ]] || die "/salvage/meta not found (mount missing?)"
fi

ensure_repo() {
  log "Checking repository..."
  set +e
  local output rc
  output="$(run_restic "${GLOBAL_ARGS[@]}" cat config 2>&1)"
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    log "Repository exists."
    return 0
  fi

  if [[ $rc -eq 10 ]] || echo "$output" | grep -qi "Is there a repository at the following location"; then
    log "Repository not found. Initializing..."
    run_restic "${GLOBAL_ARGS[@]}" init
    log "Repository initialized."
    return 0
  fi

  echo "$output" >&2
  die "Repository check failed (rc=$rc). Not initializing because it does not look like a missing-repo case."
}

do_backup() {
  log "Starting backup..."
  local -a tag_args=(
    --tag "$TAG_MAIN"
    --tag "$TAG_VOL"
    --tag "$TAG_MACHINE"
    --tag "$TAG_CRANE"
  )

  local -a cmd=( "${GLOBAL_ARGS[@]}" backup
    --host "$RESTIC_HOST"
    "${tag_args[@]}"
  )

  if [[ -n "$BACKUP_ARGS" ]]; then
    # shellcheck disable=SC2206
    cmd+=( $BACKUP_ARGS )
  fi

  cmd+=( /salvage/meta /salvage/volume )

  set +e
  run_restic "${cmd[@]}"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    log "Backup completed."
    return 0
  fi

  if [[ $rc -eq 3 ]]; then
    die "Backup returned exit code 3 (incomplete snapshot). Treating as failure."
  fi

  die "Backup failed with exit code ${rc}."
}

do_forget_if_configured() {
  if [[ -z "$FORGET_ARGS" ]]; then
    log "Retention disabled (FORGET_ARGS empty)."
    return 0
  fi

  local -a tag_args=(
    --tag "$TAG_VOL"
    --tag "$TAG_MACHINE"
    --tag "$TAG_CRANE"
    --tag "$TAG_MAIN"
  )

  log "Running forget (scoped to this volume via host and tags)..."
  # shellcheck disable=SC2206
  local -a args=( "${GLOBAL_ARGS[@]}" forget
    --host "$RESTIC_HOST"
    "${tag_args[@]}"
    $FORGET_ARGS
  )

  if is_true "$DO_PRUNE"; then
    args+=( --prune )
    warn "Prune is enabled (DO_PRUNE=true). This is heavier and needs exclusive locks."
  fi

  run_restic "${args[@]}"
  log "Forget completed."
}

main() {
  ensure_repo
  do_backup
  do_forget_if_configured
  log "Done."
}

main
