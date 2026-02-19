#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[restic-crane] $*" >&2; }
warn() { echo "[restic-crane][WARN] $*" >&2; }
die()  { echo "[restic-crane][ERROR] $*" >&2; exit 1; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_env() {
  local name="$1"
  local value
  value="$(trim "${!name:-}")"
  if [[ -z "$value" ]]; then
    die "Missing required environment variable: $name"
  fi
}

require_int() {
  local name="$1"
  local value
  value="$(trim "${!name:-}")"
  if [[ -z "$value" ]]; then
    die "Missing required environment variable: $name"
  fi
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die "Environment variable '$name' must be an integer (epoch seconds)."
  fi
}

require_bool() {
  local name="$1"
  local value="$2"
  case "${value,,}" in
    1|true|yes|y|on|0|false|no|n|off|"") return 0 ;;
    *) die "Environment variable '$name' must be a boolean (true/false)." ;;
  esac
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

build_sftp_repo_location() {
  local host="$1"
  local user="$2"
  local port="$3"
  local path="$4"

  if [[ "$path" == /* ]]; then
    printf 'sftp://%s@%s:%s%s' "$user" "$host" "$port" "$path"
  else
    printf 'sftp://%s@%s:%s/%s' "$user" "$host" "$port" "$path"
  fi
}

resolve_repo_base_location() {
  local direct
  direct="$(trim "${REPO_BASE_LOCATION:-}")"
  local sftp_host
  sftp_host="$(trim "${SFTP_HOST:-}")"
  local sftp_user
  sftp_user="$(trim "${SFTP_USER:-}")"
  local sftp_path
  sftp_path="$(trim "${SFTP_PATH:-}")"

  if [[ -n "$direct" ]]; then
    if [[ -n "$sftp_host$sftp_user$sftp_path" ]]; then
      warn "REPO_BASE_LOCATION is set; SFTP_* variables are ignored."
    fi
    printf '%s' "$direct"
    return 0
  fi

  if [[ -z "$sftp_host" && -z "$sftp_user" && -z "$sftp_path" ]]; then
    die "Either REPO_BASE_LOCATION or all of SFTP_HOST/SFTP_USER/SFTP_PATH must be set."
  fi
  if [[ -z "$sftp_host" || -z "$sftp_user" || -z "$sftp_path" ]]; then
    die "SFTP_HOST, SFTP_USER, and SFTP_PATH must all be set together."
  fi

  local sftp_port
  sftp_port="$(trim "${SFTP_PORT:-23}")"
  if ! [[ "$sftp_port" =~ ^[0-9]+$ ]]; then
    die "SFTP_PORT must be an integer."
  fi

  printf '%s' "$(build_sftp_repo_location "$sftp_host" "$sftp_user" "$sftp_port" "$sftp_path")"
}

is_sftp_repository() {
  local repo="$1"
  [[ "$repo" == sftp://* ]]
}

validate_password_inputs() {
  local password_file
  password_file="$(trim "${RESTIC_PASSWORD_FILE:-}")"
  local password
  password="$(trim "${RESTIC_PASSWORD:-}")"

  if [[ -z "$password_file" && -z "$password" ]]; then
    die "Either RESTIC_PASSWORD_FILE or RESTIC_PASSWORD must be set."
  fi
  if [[ -n "$password_file" && -n "$password" ]]; then
    warn "Both RESTIC_PASSWORD_FILE and RESTIC_PASSWORD are set. RESTIC_PASSWORD_FILE is preferred."
  fi

  if ! is_true "${TESTING:-false}"; then
    if [[ -n "$password_file" ]]; then
      [[ -f "$password_file" ]] || die "RESTIC_PASSWORD_FILE does not exist: $password_file"
      [[ -s "$password_file" ]] || die "RESTIC_PASSWORD_FILE is empty: $password_file"
    fi
  fi
}

validate_runtime_mounts() {
  if is_true "${TESTING:-false}"; then
    return 0
  fi

  [[ -d /salvage/volume ]] || die "/salvage/volume not found (mount missing?)"
  [[ -d /salvage/meta ]] || die "/salvage/meta not found (mount missing?)"
}

validate_sftp_runtime_inputs() {
  if is_true "${TESTING:-false}"; then
    return 0
  fi
  if ! is_sftp_repository "$RESTIC_REPOSITORY"; then
    return 0
  fi

  local strict_host_key_checking="${STRICT_HOST_KEY_CHECKING:-true}"
  require_bool "STRICT_HOST_KEY_CHECKING" "$strict_host_key_checking"

  local key_file="${SSH_KEY_FILE:-/root/.ssh/id_ed25519}"
  local known_hosts_file="${SSH_KNOWN_HOSTS_FILE:-/root/.ssh/known_hosts}"

  [[ -f "$key_file" ]] || die "SSH key file not found: $key_file"
  [[ -s "$key_file" ]] || die "SSH key file is empty: $key_file"

  if is_true "$strict_host_key_checking"; then
    [[ -f "$known_hosts_file" ]] || die "SSH known_hosts file not found: $known_hosts_file"
    [[ -s "$known_hosts_file" ]] || die "SSH known_hosts file is empty: $known_hosts_file"
  else
    warn "STRICT_HOST_KEY_CHECKING=false; this weakens SSH authenticity checks."
  fi
}

run_testing_restic() {
  local joined=" $* "
  echo "[TESTING] restic $*" >&2

  if [[ "$joined" == *" cat config"* ]]; then
    if is_true "${TESTING_REPO_EXISTS:-true}"; then
      return 0
    fi
    echo "Is there a repository at the following location?" >&2
    return 10
  fi

  if [[ "$joined" == *" init"* ]]; then
    return "${TESTING_INIT_RC:-0}"
  fi

  if [[ "$joined" == *" backup"* ]]; then
    local backup_rc="${TESTING_BACKUP_RC:-0}"
    if [[ "$backup_rc" -eq 0 ]]; then
      if is_true "${TESTING_BACKUP_NO_SNAPSHOT:-false}"; then
        echo "{\"message_type\":\"summary\"}"
      else
        local snapshot_id="${TESTING_SNAPSHOT_ID:-deadbeef}"
        echo "{\"message_type\":\"summary\",\"snapshot_id\":\"${snapshot_id}\"}"
      fi
    fi
    return "$backup_rc"
  fi

  if [[ "$joined" == *" snapshots "* ]]; then
    if is_true "${TESTING_SNAPSHOT_EXISTS:-true}"; then
      return 0
    fi
    return "${TESTING_SNAPSHOTS_RC:-1}"
  fi

  if [[ "$joined" == *" dump "* ]]; then
    return "${TESTING_DUMP_RC:-0}"
  fi

  if [[ "$joined" == *" forget "* ]]; then
    return "${TESTING_FORGET_RC:-0}"
  fi

  if [[ "$joined" == *" check"* ]]; then
    return "${TESTING_CHECK_RC:-0}"
  fi

  return 0
}

run_restic() {
  if is_true "${TESTING:-false}"; then
    run_testing_restic "$@"
    return $?
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

extract_snapshot_id() {
  local output="$1"
  printf '%s\n' "$output" | sed -n 's/.*"snapshot_id":"\([^"]\+\)".*/\1/p' | tail -n 1
}

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
    --json
    --host "$RESTIC_HOST"
    "${tag_args[@]}"
  )

  if [[ -n "$BACKUP_ARGS" ]]; then
    # shellcheck disable=SC2206
    cmd+=( $BACKUP_ARGS )
  fi

  cmd+=( /salvage/meta /salvage/volume )

  set +e
  local output
  output="$(run_restic "${cmd[@]}" 2>&1)"
  local rc=$?
  set -e

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" >&2
  fi

  if [[ $rc -eq 0 ]]; then
    local snapshot_id
    snapshot_id="$(extract_snapshot_id "$output")"
    if [[ -z "$snapshot_id" ]]; then
      die "Backup completed but no snapshot_id was reported by restic."
    fi
    log "Backup completed (snapshot: $snapshot_id)."
    printf '%s' "$snapshot_id"
    return 0
  fi

  if [[ $rc -eq 3 ]]; then
    die "Backup returned exit code 3 (incomplete snapshot). Treating as failure."
  fi

  die "Backup failed with exit code ${rc}."
}

verify_snapshot() {
  local snapshot_id="$1"
  if ! is_true "$VERIFY_SNAPSHOT"; then
    warn "Snapshot verification disabled (VERIFY_SNAPSHOT=false)."
    return 0
  fi

  log "Verifying snapshot ${snapshot_id}..."
  run_restic "${GLOBAL_ARGS[@]}" snapshots "$snapshot_id" >/dev/null
  run_restic "${GLOBAL_ARGS[@]}" dump "$snapshot_id" /salvage/meta/meta.json >/dev/null
  log "Snapshot verification successful."
}

run_repository_check_if_enabled() {
  if ! is_true "$VERIFY_REPOSITORY_CHECK"; then
    return 0
  fi

  log "Running repository consistency check..."
  local -a check_cmd=( "${GLOBAL_ARGS[@]}" check )
  if [[ -n "$VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET" ]]; then
    check_cmd+=( --read-data-subset "$VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET" )
  fi
  run_restic "${check_cmd[@]}"
  log "Repository consistency check completed."
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
  # Required by Salvage interface
  require_env SALVAGE_MACHINE_NAME
  require_env SALVAGE_CRANE_NAME
  require_env SALVAGE_VOLUME_NAME
  require_int SALVAGE_TIDE_TIMESTAMP

  # Crane configuration
  REPO_BASE_LOCATION_RESOLVED="$(resolve_repo_base_location)"
  validate_password_inputs

  SINGLE_REPO="${SINGLE_REPO:-true}"
  RETRY_LOCK="${RESTIC_RETRY_LOCK:-1h}"
  FORGET_ARGS="${FORGET_ARGS:-}"
  DO_PRUNE="${DO_PRUNE:-false}"
  RESTIC_GLOBAL_ARGS="${RESTIC_ARGS:-}"
  BACKUP_ARGS="${BACKUP_ARGS:-}"
  VERIFY_SNAPSHOT="${VERIFY_SNAPSHOT:-true}"
  VERIFY_REPOSITORY_CHECK="${VERIFY_REPOSITORY_CHECK:-false}"
  VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET="${VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET:-1/200}"

  require_bool "SINGLE_REPO" "$SINGLE_REPO"
  require_bool "DO_PRUNE" "$DO_PRUNE"
  require_bool "VERIFY_SNAPSHOT" "$VERIFY_SNAPSHOT"
  require_bool "VERIFY_REPOSITORY_CHECK" "$VERIFY_REPOSITORY_CHECK"
  mapfile -d '' GLOBAL_ARGS < <(build_global_args)

  mapfile -d '' REPOS < <(split_repos "$REPO_BASE_LOCATION_RESOLVED")
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

  DEFAULT_HOST="${SALVAGE_MACHINE_NAME}-${SALVAGE_VOLUME_NAME}"
  RESTIC_HOST="${RESTIC_HOST:-$DEFAULT_HOST}"

  TAG_MAIN="salvage"
  TAG_VOL="vol-${SALVAGE_VOLUME_NAME}"
  TAG_MACHINE="machine-${SALVAGE_MACHINE_NAME}"
  TAG_CRANE="crane-${SALVAGE_CRANE_NAME}"

  log "Crane: ${SALVAGE_CRANE_NAME}"
  log "Machine: ${SALVAGE_MACHINE_NAME}"
  log "Volume: ${SALVAGE_VOLUME_NAME}"
  log "Tide timestamp: ${SALVAGE_TIDE_TIMESTAMP}"
  log "Repository: ${RESTIC_REPOSITORY} (${MODE_DESC})"
  log "Host: ${RESTIC_HOST}"
  log "Tags: ${TAG_MAIN}, ${TAG_VOL}, ${TAG_MACHINE}, ${TAG_CRANE}"

  validate_runtime_mounts
  validate_sftp_runtime_inputs

  ensure_repo
  local snapshot_id
  snapshot_id="$(do_backup)"
  verify_snapshot "$snapshot_id"
  do_forget_if_configured
  run_repository_check_if_enabled
  log "Done."
}

main
