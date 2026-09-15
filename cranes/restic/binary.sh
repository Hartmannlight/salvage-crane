#!/usr/bin/env bash
set -euo pipefail
# Extra-argument strings must never expand filesystem globs.
set -f

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
  if ! [[ "$value" =~ ^[0-9]{1,12}$ ]]; then
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
  local -a out=() parts=()
  local p
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || die "Repository locations must be on one line."
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
  REPOS=("${out[@]}")
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
    printf 'sftp://%s@%s:%s/%s' "$user" "$host" "$port" "$path"
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
  if ! [[ "$sftp_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$sftp_port < 1 || 10#$sftp_port > 65535 )); then
    die "SFTP_PORT must be between 1 and 65535."
  fi

  printf '%s' "$(build_sftp_repo_location "$sftp_host" "$sftp_user" "$sftp_port" "$sftp_path")"
}

is_sftp_repository() {
  local repo="$1"
  [[ "$repo" == sftp:* ]]
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
    unset RESTIC_PASSWORD
  fi

  if [[ -n "$password_file" ]]; then
      [[ -f "$password_file" ]] || die "RESTIC_PASSWORD_FILE does not exist: $password_file"
      [[ -s "$password_file" ]] || die "RESTIC_PASSWORD_FILE is empty: $password_file"
  fi
}

validate_runtime_mounts() {

  [[ -d /salvage/volume ]] || die "/salvage/volume not found (mount missing?)"
  # Dockerfile creates this directory too; its existence does not prove a mount.
  awk '$5 == "/salvage/volume" { found=1 } END { exit !found }' /proc/self/mountinfo ||
    die "/salvage/volume is not mounted; refusing to back up an empty image directory."
  [[ -d /salvage/meta ]] || die "/salvage/meta not found (mount missing?)"
  [[ -n "$(find /salvage/meta -type f -print -quit)" ]] || die "Salvage metadata is missing."
}

validate_sftp_runtime_inputs() {
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

run_restic() {
  "$RESTIC_BIN" "$@"
}

build_global_args() {
  local -a args=()
  args+=(--retry-lock "$RETRY_LOCK")
  if [[ -n "$RESTIC_GLOBAL_ARGS" ]]; then
    local -a extra=()
    read -ra extra <<< "$RESTIC_GLOBAL_ARGS"
    [[ "$RESTIC_GLOBAL_ARGS" != *$'\n'* ]] || die "RESTIC_ARGS must be on one line."
    local index=0 option word value
    while (( index < ${#extra[@]} )); do
      word="${extra[index]}"
      option="${word%%=*}"
      case "$option" in
        --no-cache|--cleanup-cache|--verbose|-v|-vv|--json)
          [[ "$word" == "$option" || "$word" =~ ^--verbose=[12]$ ]] || die "Invalid RESTIC_ARGS option."
          args+=("$word") ;;
        --compression|--limit-upload|--limit-download|--pack-size|--cache-dir|--cacert|--tls-client-cert|--key-hint|--http-user-agent|--stuck-request-timeout|--option|-o)
          if [[ "$word" == *=* ]]; then
            value="${word#*=}"
          else
            index=$((index + 1))
            value="${extra[index]:-}"
          fi
          [[ -n "$value" && "$value" != -* ]] || die "Missing value for $option."
          if [[ "$option" == --option || "$option" == -o ]]; then
            [[ "$value" != sftp.args=* && "$value" != sftp.command=* ]] || die "Use SSH_* settings to configure SFTP."
            # Preserve commas/quotes as part of one backend option, not extra CSV entries.
            value="${value//\"/\"\"}"
            value="\"$value\""
          fi
          args+=("$option" "$value") ;;
        *) die "Unsupported RESTIC_ARGS option: $option." ;;
      esac
      index=$((index + 1))
    done
  fi
  GLOBAL_ARGS=("${args[@]}")
}

# Retention accepts policy options only. Snapshot IDs bypass restic's filters;
# extra --tag/--host flags broaden them. Neither belongs in FORGET_ARGS.
validate_forget_args() {
  FORGET_OPTIONS=()
  local -a words=()
  read -ra words <<< "$FORGET_ARGS"
  [[ "$FORGET_ARGS" != *$'\n'* ]] || die "FORGET_ARGS must be on one line."
  local index=0 option value word
  while (( index < ${#words[@]} )); do
    word="${words[index]}"
    option="${word%%=*}"
    case "$option" in
      --dry-run)
        [[ "$word" == "$option" ]] || die "Invalid FORGET_ARGS option."
        FORGET_OPTIONS+=("$option")
        index=$((index + 1))
        continue ;;
      --keep-last|--keep-hourly|--keep-daily|--keep-weekly|--keep-monthly|--keep-yearly|--keep-within|--keep-within-hourly|--keep-within-daily|--keep-within-weekly|--keep-within-monthly|--keep-within-yearly|--keep-tag) ;;
      *) die "Unsupported FORGET_ARGS option: $option (only --keep-* policies and --dry-run are allowed)." ;;
    esac
    if [[ "$word" == *=* ]]; then
      value="${word#*=}"
    else
      index=$((index + 1))
      value="${words[index]:-}"
    fi
    [[ -n "$value" && "$value" != -* ]] || die "Missing value for $option."
    case "$option" in
      --keep-tag) ;;
      --keep-within*) [[ "$value" =~ ^([0-9]+[ymdh])+$ && "$value" =~ [1-9] ]] || die "Invalid duration for $option." ;;
      *) [[ "$value" == unlimited || ( "$value" =~ ^[0-9]+$ && "$value" =~ [1-9] ) ]] || die "$option must be positive or unlimited." ;;
    esac
    FORGET_OPTIONS+=("$option" "$value")
    index=$((index + 1))
  done
}

validate_backup_args() {
  BACKUP_OPTIONS=()
  local -a words=()
  read -ra words <<< "$BACKUP_ARGS"
  [[ "$BACKUP_ARGS" != *$'\n'* ]] || die "BACKUP_ARGS must be on one line."
  local index=0 option word value
  while (( index < ${#words[@]} )); do
    word="${words[index]}"
    option="${word%%=*}"
    case "$option" in
      --exclude-caches|--force|-f|--ignore-ctime|--ignore-inode|--no-scan|--one-file-system|-x|--with-atime)
        [[ "$word" == "$option" ]] || die "Invalid BACKUP_ARGS option."
        BACKUP_OPTIONS+=("$word") ;;
      --exclude|-e|--iexclude|--exclude-file|--iexclude-file|--exclude-if-present|--exclude-larger-than|--read-concurrency)
        if [[ "$word" == *=* ]]; then
          value="${word#*=}"
        else
          index=$((index + 1))
          value="${words[index]:-}"
        fi
        [[ -n "$value" && "$value" != -* ]] || die "Missing value for $option."
        BACKUP_OPTIONS+=("$option" "$value") ;;
      *) die "Unsupported BACKUP_ARGS option: $option (source, identity and repository overrides are not allowed)." ;;
    esac
    index=$((index + 1))
  done
}

quote_ssh_arg() {
  # Restic's splitter preserves escapes inside quotes and does not concatenate
  # adjacent quoted strings. Choose a delimiter absent from the entire value.
  [[ "$1" != *\\ ]] || die "SSH arguments cannot end in a backslash."
  if [[ "$1" != *"'"* ]]; then
    printf "'%s'" "$1"
  elif [[ "$1" != *'"'* ]]; then
    printf '"%s"' "$1"
  else
    die "SSH arguments cannot contain both single and double quotes."
  fi
}

configure_sftp() {
  is_sftp_repository "$RESTIC_REPOSITORY" || return 0
  local strict=yes known_hosts="${SSH_KNOWN_HOSTS_FILE:-/root/.ssh/known_hosts}"
  require_bool STRICT_HOST_KEY_CHECKING "${STRICT_HOST_KEY_CHECKING:-true}"
  if ! is_true "${STRICT_HOST_KEY_CHECKING:-true}"; then
    strict=no
    known_hosts=/dev/null
  fi
  local ssh_args
  ssh_args="-oBatchMode=yes -oIdentitiesOnly=yes -oStrictHostKeyChecking=$strict"
  ssh_args+=" -i $(quote_ssh_arg "${SSH_KEY_FILE:-/root/.ssh/id_ed25519}")"
  # OpenSSH parses -o values again as config lines, so quote the path there too.
  [[ "$known_hosts" != *[\"\'\\]* ]] || die "SSH_KNOWN_HOSTS_FILE cannot contain quotes or backslashes."
  ssh_args+=" -o $(quote_ssh_arg "UserKnownHostsFile=\"$known_hosts\"")"
  # Restic's --option flag parses CSV before its SFTP backend parses quoting.
  local option="sftp.args=$ssh_args"
  option="${option//\"/\"\"}"
  GLOBAL_ARGS+=(-o "\"$option\"")
}

extract_snapshot_id() {
  local output="$1"
  printf '%s\n' "$output" | jq -Rr 'fromjson? | select(.message_type == "summary") | .snapshot_id // empty' | tail -n 1
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

  # The pinned restic version has a dedicated missing-repository exit code.
  if [[ $rc -eq 10 ]]; then
    log "Repository not found. Initializing..."
    if ! run_restic "${GLOBAL_ARGS[@]}" init; then
      # Another crane may have initialized the shared repository in the meantime.
      run_restic "${GLOBAL_ARGS[@]}" cat config >/dev/null || die "Repository initialization failed."
    fi
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

  cmd+=( "${BACKUP_OPTIONS[@]}" )

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
    if ! [[ "$snapshot_id" =~ ^[a-f0-9]{8,64}$ ]]; then
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
  # snapshots can return success with no matching snapshots. cat must resolve one.
  run_restic "${GLOBAL_ARGS[@]}" cat snapshot "$snapshot_id" |
    jq -e --arg host "$RESTIC_HOST" --arg vol "$TAG_VOL" --arg machine "$TAG_MACHINE" --arg crane "$TAG_CRANE" '
      .hostname == $host and
      ((["salvage", $vol, $machine, $crane] - .tags) | length == 0)
    ' >/dev/null || die "Snapshot identity verification failed."
  # Check the actual tree, since snapshot.paths also includes excluded sources.
  run_restic "${GLOBAL_ARGS[@]}" ls --json "$snapshot_id" /salvage |
    jq -se 'any(.[]; .type == "dir" and .path == "/salvage/volume") and
            any(.[]; .type == "dir" and .path == "/salvage/meta")' >/dev/null ||
    die "Snapshot is missing a required source directory."
  # Restic >=0.19 retains an explicitly supplied root even if an exclusion
  # removes every child. A directory entry alone no longer proves coverage.
  if [[ -n "$(find /salvage/volume -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    run_restic "${GLOBAL_ARGS[@]}" ls --json "$snapshot_id" /salvage/volume |
      jq -se 'any(.[]; (.path // "") | startswith("/salvage/volume/"))' >/dev/null ||
      die "Snapshot contains no entries from the nonempty source volume; refusing retention."
  fi
  # The metadata layout belongs to Salvage, not to the crane.
  run_restic "${GLOBAL_ARGS[@]}" dump "$snapshot_id" /salvage/meta >/dev/null
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

  # Multiple --tag flags are ORed by restic; one comma-separated list is ANDed.
  local -a tag_args=(--tag "$TAG_MAIN,$TAG_VOL,$TAG_MACHINE,$TAG_CRANE")

  log "Running forget (scoped to this volume via host and tags)..."
  # shellcheck disable=SC2206
  local -a args=( "${GLOBAL_ARGS[@]}" forget
    --host "$RESTIC_HOST"
    "${tag_args[@]}"
    "${FORGET_OPTIONS[@]}"
  )

  if is_true "$DO_PRUNE"; then
    args+=( --prune )
    warn "Prune is enabled (DO_PRUNE=true). This is heavier and needs exclusive locks."
  fi

  run_restic "${args[@]}"
  log "Forget completed."
}

configure_crane() {
  [[ "${TESTING:-false}" == false ]] || die "TESTING is not supported in the runtime crane."
  # Required by Salvage interface
  require_env SALVAGE_MACHINE_NAME
  require_env SALVAGE_CRANE_NAME
  require_env SALVAGE_VOLUME_NAME
  require_int SALVAGE_TIDE_TIMESTAMP
  local identity
  for identity in SALVAGE_MACHINE_NAME SALVAGE_CRANE_NAME SALVAGE_VOLUME_NAME; do
    [[ "${!identity}" != *[,/]* && "${!identity}" != . && "${!identity}" != .. ]] ||
      die "$identity must not contain commas, slashes or traversal components."
  done

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
  build_global_args
  validate_forget_args
  validate_backup_args

  split_repos "$REPO_BASE_LOCATION_RESOLVED"
  DAY_INDEX=$(( 10#$SALVAGE_TIDE_TIMESTAMP / 86400 ))
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
}

main() {
  configure_crane
  validate_runtime_mounts
  validate_sftp_runtime_inputs
  configure_sftp

  ensure_repo
  local snapshot_id
  snapshot_id="$(do_backup)"
  verify_snapshot "$snapshot_id"
  run_repository_check_if_enabled
  do_forget_if_configured
  log "Done."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
