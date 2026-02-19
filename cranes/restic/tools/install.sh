#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRANE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
RUNTIME_ENV_FILE="${RUNTIME_ENV_FILE:-${SCRIPT_DIR}/.runtime.env}"

log()  { echo "[install] $*"; }
die()  { echo "[install][ERROR] $*" >&2; exit 1; }

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

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    0|false|no|n|off|"") return 1 ;;
    *) die "Invalid boolean value: '$1'" ;;
  esac
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die ".env not found at: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
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
    printf '%s' "$direct"
    return 0
  fi

  if [[ -z "$sftp_host" || -z "$sftp_user" || -z "$sftp_path" ]]; then
    die "Set REPO_BASE_LOCATION or all of SFTP_HOST/SFTP_USER/SFTP_PATH."
  fi
  if ! [[ "$sftp_port" =~ ^[0-9]+$ ]]; then
    die "SFTP_PORT must be an integer."
  fi

  printf '%s' "$(build_sftp_repo_location "$sftp_host" "$sftp_user" "$sftp_port" "$sftp_path")"
}

is_sftp_repo() {
  local repo="$1"
  [[ "$repo" == sftp://* ]]
}

extract_sftp_host_port() {
  local repo="$1"
  if [[ "$repo" =~ ^sftp://[^@]+@([^:/]+):([0-9]+)/.*$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

prepare_password_file() {
  local tmpdir="$1"
  local password_file_source
  password_file_source="$(trim "${RESTIC_PASSWORD_FILE_SOURCE:-}")"
  local password_value
  password_value="$(trim "${RESTIC_PASSWORD:-}")"
  local target_file="${tmpdir}/${RESTIC_PASSWORD_FILENAME}"

  if [[ -n "$password_file_source" ]]; then
    [[ -f "$password_file_source" ]] || die "RESTIC_PASSWORD_FILE_SOURCE does not exist: $password_file_source"
    [[ -s "$password_file_source" ]] || die "RESTIC_PASSWORD_FILE_SOURCE is empty: $password_file_source"
    cp "$password_file_source" "$target_file"
  elif [[ -n "$password_value" ]]; then
    printf '%s' "$RESTIC_PASSWORD" > "$target_file"
  else
    die "Set RESTIC_PASSWORD or RESTIC_PASSWORD_FILE_SOURCE."
  fi

  [[ -s "$target_file" ]] || die "Generated password file is empty: $target_file"
}

prepare_known_hosts_file() {
  local repo="$1"
  local tmpdir="$2"
  local known_hosts_source
  known_hosts_source="$(trim "${SSH_KNOWN_HOSTS_SOURCE:-}")"

  if [[ -n "$known_hosts_source" ]]; then
    [[ -f "$known_hosts_source" ]] || die "SSH_KNOWN_HOSTS_SOURCE does not exist: $known_hosts_source"
    [[ -s "$known_hosts_source" ]] || die "SSH_KNOWN_HOSTS_SOURCE is empty: $known_hosts_source"
    cp "$known_hosts_source" "${tmpdir}/known_hosts"
    return 0
  fi

  mapfile -t host_port < <(extract_sftp_host_port "$repo")
  [[ "${#host_port[@]}" -eq 2 ]] || die "Could not extract host/port from SFTP repository URL."

  local host="${host_port[0]}"
  local port="${host_port[1]}"
  require_cmd ssh-keyscan
  log "Generating known_hosts via ssh-keyscan for ${host}:${port}"
  ssh-keyscan -p "$port" "$host" > "${tmpdir}/known_hosts"
  [[ -s "${tmpdir}/known_hosts" ]] || die "Generated known_hosts is empty."
}

copy_ssh_material() {
  local repo="$1"
  local tmpdir="$2"

  if ! is_sftp_repo "$repo"; then
    log "Repository is not SFTP; skipping SSH volume content."
    return 0
  fi

  require_non_empty SSH_PRIVATE_KEY_SOURCE
  [[ -f "$SSH_PRIVATE_KEY_SOURCE" ]] || die "SSH_PRIVATE_KEY_SOURCE does not exist: $SSH_PRIVATE_KEY_SOURCE"
  [[ -s "$SSH_PRIVATE_KEY_SOURCE" ]] || die "SSH_PRIVATE_KEY_SOURCE is empty: $SSH_PRIVATE_KEY_SOURCE"

  cp "$SSH_PRIVATE_KEY_SOURCE" "${tmpdir}/id_ed25519"
  prepare_known_hosts_file "$repo" "$tmpdir"

  docker run --rm \
    -v "${RESTIC_SSH_VOLUME}:/dst" \
    -v "${tmpdir}:/src:ro" \
    alpine sh -eu -c '
      mkdir -p /dst
      cp /src/id_ed25519 /dst/id_ed25519
      cp /src/known_hosts /dst/known_hosts
      chmod 600 /dst/id_ed25519
      chmod 644 /dst/known_hosts
    '
}

copy_password_material() {
  local tmpdir="$1"
  docker run --rm \
    -v "${RESTIC_SECRETS_VOLUME}:/dst" \
    -v "${tmpdir}:/src:ro" \
    alpine sh -eu -c "
      mkdir -p /dst
      cp /src/${RESTIC_PASSWORD_FILENAME} /dst/${RESTIC_PASSWORD_FILENAME}
      chmod 600 /dst/${RESTIC_PASSWORD_FILENAME}
    "
}

write_runtime_env_file() {
  local repo="$1"
  {
    printf 'MACHINE=%s\n' "$MACHINE"
    printf 'TZ=%s\n' "${TZ:-UTC}"
    printf 'SALVAGE_IMAGE=%s\n' "${SALVAGE_IMAGE:-ghcr.io/chrisliebaer/salvage:master}"
    printf 'RESTIC_CRANE_IMAGE=%s\n' "${RESTIC_CRANE_IMAGE:-salvage-crane-restic:local}"
    printf 'TIDE_NAME=%s\n' "$TIDE_NAME"
    printf 'TIDE_CRON=%s\n' "$TIDE_CRON"
    printf 'TIDE_GROUPING=%s\n' "$TIDE_GROUPING"
    printf 'TIDE_MAX_CONCURRENT=%s\n' "$TIDE_MAX_CONCURRENT"
    printf 'REPO_BASE_LOCATION=%s\n' "$repo"
    printf 'SINGLE_REPO=%s\n' "${SINGLE_REPO:-true}"
    printf 'RESTIC_RETRY_LOCK=%s\n' "${RESTIC_RETRY_LOCK:-2h}"
    printf 'FORGET_ARGS=%s\n' "${FORGET_ARGS:-}"
    printf 'DO_PRUNE=%s\n' "${DO_PRUNE:-false}"
    printf 'VERIFY_SNAPSHOT=%s\n' "${VERIFY_SNAPSHOT:-true}"
    printf 'VERIFY_REPOSITORY_CHECK=%s\n' "${VERIFY_REPOSITORY_CHECK:-false}"
    printf 'VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET=%s\n' "${VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET:-1/200}"
    printf 'STRICT_HOST_KEY_CHECKING=%s\n' "${STRICT_HOST_KEY_CHECKING:-true}"
    printf 'RESTIC_SSH_VOLUME=%s\n' "$RESTIC_SSH_VOLUME"
    printf 'RESTIC_SECRETS_VOLUME=%s\n' "$RESTIC_SECRETS_VOLUME"
    printf 'RESTIC_CACHE_VOLUME=%s\n' "$RESTIC_CACHE_VOLUME"
    printf 'RESTIC_PASSWORD_FILENAME=%s\n' "$RESTIC_PASSWORD_FILENAME"
  } > "$RUNTIME_ENV_FILE"
}

maybe_build_crane_image() {
  local should_build="${BUILD_RESTIC_IMAGE:-true}"
  require_bool "BUILD_RESTIC_IMAGE" "$should_build"
  if ! is_true "$should_build"; then
    log "Skipping crane image build (BUILD_RESTIC_IMAGE=false)."
    return 0
  fi

  local image="${RESTIC_CRANE_IMAGE:-salvage-crane-restic:local}"
  log "Building restic crane image: ${image}"
  docker build -t "$image" "$CRANE_DIR"
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

  local repo
  repo="$(resolve_repo_location)"

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  prepare_password_file "$tmpdir"

  log "Ensuring Docker volumes exist..."
  docker volume create "$RESTIC_SSH_VOLUME" >/dev/null
  docker volume create "$RESTIC_SECRETS_VOLUME" >/dev/null
  docker volume create "$RESTIC_CACHE_VOLUME" >/dev/null

  copy_ssh_material "$repo" "$tmpdir"
  copy_password_material "$tmpdir"
  write_runtime_env_file "$repo"
  maybe_build_crane_image

  log "Install complete."
  log "Runtime env written to: $RUNTIME_ENV_FILE"
  log "Next step:"
  log "docker compose --env-file cranes/restic/tools/.runtime.env -f cranes/restic/examples/docker-compose.salvage.yml up -d"
}

main "$@"
