#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse the installer's quoting and validation, without running its main function.
# shellcheck source=install.sh
source "$SCRIPT_DIR/install.sh"

setup_main() {
  [[ $# -ge 1 && $# -le 2 ]] || die "Usage: $0 <u123456-sub1> [relative-repository-path]"
  local setup_user="$1" setup_repo="${2:-salvage}"
  [[ "$setup_user" =~ ^u[0-9]+(-sub[0-9]+)?$ ]] || die "Expected a Hetzner Storage Box username."
  [[ "$setup_repo" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9_./-]*$ && "$setup_repo" != *..* ]] || die "Use a relative repository path without traversal components."
  [[ ! -e "$ENV_FILE" ]] || die "$ENV_FILE already exists. Reapply it with install.sh, or choose a new ENV_FILE for another setup."
  local cmd
  for cmd in ssh ssh-keygen ssh-keyscan docker od tr; do require_cmd "$cmd"; done
  umask 077
  local setup_dir="${HETZNER_SETUP_DIR:-$SCRIPT_DIR/.local/hetzner-$setup_user}"
  mkdir -p "$setup_dir"
  setup_dir="$(cd "$setup_dir" && pwd -P)"
  chmod 700 "$setup_dir"
  local setup_host="$setup_user.your-storagebox.de"
  local candidate
  candidate="$(mktemp "$setup_dir/known-hosts.XXXXXX")"
  # shellcheck disable=SC2064
  trap "$(printf 'rm -f -- %q' "$candidate")" EXIT
  log "Checking the Storage Box host key against Hetzner's published fingerprint..."
  ssh-keyscan -T 10 -p 23 -t ed25519 "$setup_host" > "$candidate"
  [[ -s "$candidate" ]] || die "No SSH host key received. Check SSH support and external reachability."
  # https://docs.hetzner.com/storage/storage-box/general/#ssh-host-keys
  # Verified 2026-09-13. A provider rotation must be independently verified.
  local expected="${HETZNER_HOST_KEY_SHA256:-SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM}"
  local fingerprints _bits fingerprint _rest
  fingerprints="$(ssh-keygen -lf "$candidate")"
  while read -r _bits fingerprint _rest; do
    [[ "$fingerprint" == "$expected" ]] || die "Host fingerprint mismatch. Verify the current fingerprint through Hetzner before continuing."
  done <<< "$fingerprints"
  cp "$candidate" "$setup_dir/known_hosts"
  if [[ ! -e "$setup_dir/id_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "salvage-restic-$setup_user" -f "$setup_dir/id_ed25519"
  fi
  if [[ ! -s "$setup_dir/id_ed25519.pub" ]]; then
    ssh-keygen -y -f "$setup_dir/id_ed25519" > "$setup_dir/id_ed25519.pub"
  fi
  local -a ssh_args=(-F /dev/null -p 23 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=\"$setup_dir/known_hosts\"" -i "$setup_dir/id_ed25519")
  if ! ssh "${ssh_args[@]}" -o BatchMode=yes "$setup_user@$setup_host" pwd >/dev/null 2>&1; then
    log "Installing the public key. Enter the Storage Box subaccount password when SSH asks."
    ssh "${ssh_args[@]}" "$setup_user@$setup_host" install-ssh-key < "$setup_dir/id_ed25519.pub"
  fi
  ssh "${ssh_args[@]}" -o BatchMode=yes "$setup_user@$setup_host" pwd
  if [[ ! -e "$setup_dir/restic_password" ]]; then
    od -An -N48 -tx1 /dev/urandom | tr -d ' \n' > "$setup_dir/restic_password"
    printf '\n' >> "$setup_dir/restic_password"
  fi
  [[ -s "$setup_dir/restic_password" ]] || die "Restic password file is empty."
  chmod 600 "$setup_dir/id_ed25519" "$setup_dir/restic_password" "$setup_dir/known_hosts"
  local setup_build="${BUILD_RESTIC_IMAGE:-true}"
  local setup_image="${RESTIC_CRANE_IMAGE:-salvage-crane-restic:local}"
  local setup_machine="${MACHINE:-$(hostname -s)}"
  # shellcheck source=.env.example
  source "$SCRIPT_DIR/.env.example"
  BUILD_RESTIC_IMAGE="$setup_build"
  RESTIC_CRANE_IMAGE="$setup_image"
  MACHINE="$setup_machine"
  SFTP_HOST="$setup_host" SFTP_USER="$setup_user" SFTP_PATH="$setup_repo"
  SSH_PRIVATE_KEY_SOURCE="$setup_dir/id_ed25519"
  SSH_KNOWN_HOSTS_SOURCE="$setup_dir/known_hosts"
  RESTIC_PASSWORD_FILE_SOURCE="$setup_dir/restic_password"
  RESTIC_SSH_VOLUME="salvage-restic-$setup_user-ssh"
  RESTIC_SECRETS_VOLUME="salvage-restic-$setup_user-secrets"
  RESTIC_CACHE_VOLUME="salvage-restic-$setup_user-cache"
  local setting
  {
    for setting in MACHINE TZ SALVAGE_IMAGE RESTIC_CRANE_IMAGE BUILD_RESTIC_IMAGE \
      TIDE_NAME TIDE_CRON TIDE_GROUPING TIDE_MAX_CONCURRENT REPO_BASE_LOCATION \
      SFTP_HOST SFTP_USER SFTP_PORT SFTP_PATH SINGLE_REPO RESTIC_RETRY_LOCK \
      VERIFY_SNAPSHOT VERIFY_REPOSITORY_CHECK VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET \
      FORGET_ARGS DO_PRUNE SSH_PRIVATE_KEY_SOURCE SSH_KNOWN_HOSTS_SOURCE STRICT_HOST_KEY_CHECKING \
      RESTIC_PASSWORD_FILE_SOURCE RESTIC_SSH_VOLUME RESTIC_SECRETS_VOLUME RESTIC_CACHE_VOLUME RESTIC_PASSWORD_FILENAME; do
      write_env_value "$setting" "${!setting}"
    done
  } > "$ENV_FILE"
  log "Configuration written to $ENV_FILE; adjust MACHINE and the schedule for your host."
  log "Keep $setup_dir/restic_password independently: it is the repository encryption password."
  ENV_FILE="$ENV_FILE" RUNTIME_ENV_FILE="$RUNTIME_ENV_FILE" bash "$SCRIPT_DIR/install.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  setup_main "$@"
fi
