#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

log()  { echo "[preflight] $*"; }
warn() { echo "[preflight][WARN] $*" >&2; }
die()  { echo "[preflight][ERROR] $*" >&2; exit 1; }

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
  [[ -n "$value" ]] || die "Missing required variable in .env: $name"
}

require_bool() {
  local name="$1"
  local value="$2"
  case "${value,,}" in
    1|true|yes|y|on|0|false|no|n|off|"") return 0 ;;
    *) die "Variable '$name' must be boolean (true/false)." ;;
  esac
}

is_sftp_repo() {
  local repo
  local -a repos=()
  IFS=';' read -ra repos <<< "$1"
  for repo in "${repos[@]}"; do
    repo="$(trim "$repo")"
    [[ "$repo" == sftp:* ]] && return 0
  done
  return 1
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

resolve_repo_location() {
  local direct
  direct="$(trim "${REPO_BASE_LOCATION:-}")"
  local sftp_host
  sftp_host="$(trim "${SFTP_HOST:-}")"
  local sftp_user
  sftp_user="$(trim "${SFTP_USER:-}")"
  local sftp_path
  sftp_path="$(trim "${SFTP_PATH:-}")"
  local sftp_port
  sftp_port="$(trim "${SFTP_PORT:-23}")"

  if [[ -n "$direct" ]]; then
    if [[ -n "$sftp_host$sftp_user$sftp_path" ]]; then
      warn "REPO_BASE_LOCATION is set; SFTP_* variables are ignored."
    fi
    printf '%s' "$direct"
    return 0
  fi

  if [[ -z "$sftp_host" && -z "$sftp_user" && -z "$sftp_path" ]]; then
    die "Set REPO_BASE_LOCATION or all of SFTP_HOST/SFTP_USER/SFTP_PATH."
  fi
  if [[ -z "$sftp_host" || -z "$sftp_user" || -z "$sftp_path" ]]; then
    die "SFTP_HOST, SFTP_USER, and SFTP_PATH must be set together."
  fi
  if ! [[ "$sftp_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$sftp_port < 1 || 10#$sftp_port > 65535 )); then
    die "SFTP_PORT must be between 1 and 65535."
  fi

  printf '%s' "$(build_sftp_repo_location "$sftp_host" "$sftp_user" "$sftp_port" "$sftp_path")"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die ".env not found at: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

validate_password_input() {
  local password
  password="$(trim "${RESTIC_PASSWORD:-}")"
  local password_file
  password_file="$(trim "${RESTIC_PASSWORD_FILE_SOURCE:-}")"

  if [[ -z "$password" && -z "$password_file" ]]; then
    die "Set RESTIC_PASSWORD or RESTIC_PASSWORD_FILE_SOURCE."
  fi
  if [[ -n "$password" && -n "$password_file" ]]; then
    warn "Both RESTIC_PASSWORD and RESTIC_PASSWORD_FILE_SOURCE set. File source will be used."
  fi
  if [[ -n "$password_file" ]]; then
    [[ -f "$password_file" ]] || die "RESTIC_PASSWORD_FILE_SOURCE does not exist: $password_file"
    [[ -s "$password_file" ]] || die "RESTIC_PASSWORD_FILE_SOURCE is empty: $password_file"
  fi
}

validate_sftp_host_key_input() {
  local repo="$1"
  if ! is_sftp_repo "$repo"; then
    return 0
  fi

  require_non_empty SSH_PRIVATE_KEY_SOURCE
  [[ -f "$SSH_PRIVATE_KEY_SOURCE" ]] || die "SSH_PRIVATE_KEY_SOURCE does not exist: $SSH_PRIVATE_KEY_SOURCE"
  [[ -s "$SSH_PRIVATE_KEY_SOURCE" ]] || die "SSH_PRIVATE_KEY_SOURCE is empty: $SSH_PRIVATE_KEY_SOURCE"

  if [[ -n "$(trim "${SSH_KNOWN_HOSTS_SOURCE:-}")" ]]; then
    [[ -f "$SSH_KNOWN_HOSTS_SOURCE" ]] || die "SSH_KNOWN_HOSTS_SOURCE does not exist: $SSH_KNOWN_HOSTS_SOURCE"
    [[ -s "$SSH_KNOWN_HOSTS_SOURCE" ]] || die "SSH_KNOWN_HOSTS_SOURCE is empty: $SSH_KNOWN_HOSTS_SOURCE"
  else
    local strict="${STRICT_HOST_KEY_CHECKING:-true}"
    case "${strict,,}" in
      0|false|no|n|off) ;;
      *) die "SSH_KNOWN_HOSTS_SOURCE is required with strict host checking; supply independently verified host keys." ;;
    esac
  fi
}

main() {
  load_env

  require_cmd docker
  require_cmd bash

  require_non_empty MACHINE
  require_non_empty TIDE_NAME
  require_non_empty TIDE_CRON
  require_non_empty TIDE_GROUPING
  require_non_empty TIDE_MAX_CONCURRENT
  require_non_empty RESTIC_SSH_VOLUME
  require_non_empty RESTIC_SECRETS_VOLUME
  require_non_empty RESTIC_CACHE_VOLUME
  require_non_empty RESTIC_PASSWORD_FILENAME

  require_bool "SINGLE_REPO" "${SINGLE_REPO:-true}"
  require_bool "DO_PRUNE" "${DO_PRUNE:-false}"
  require_bool "VERIFY_SNAPSHOT" "${VERIFY_SNAPSHOT:-true}"
  require_bool "VERIFY_REPOSITORY_CHECK" "${VERIFY_REPOSITORY_CHECK:-false}"
  require_bool "STRICT_HOST_KEY_CHECKING" "${STRICT_HOST_KEY_CHECKING:-true}"
  require_bool "BUILD_RESTIC_IMAGE" "${BUILD_RESTIC_IMAGE:-true}"

  local repo
  repo="$(resolve_repo_location)"
  validate_password_input
  validate_sftp_host_key_input "$repo"

  log "Preflight checks passed."
  log "Resolved repository: $repo"
  if is_sftp_repo "$repo"; then
    log "SFTP mode detected."
  else
    log "Non-SFTP repository mode detected."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
