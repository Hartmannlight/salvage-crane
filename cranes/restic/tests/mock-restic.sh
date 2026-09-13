#!/usr/bin/env bash
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

  if [[ "$joined" == *" cat snapshot "* ]]; then
    if is_true "${TESTING_SNAPSHOT_EXISTS:-true}"; then
      jq -n --arg host "$RESTIC_HOST" --arg vol "$TAG_VOL" --arg machine "$TAG_MACHINE" --arg crane "$TAG_CRANE" \
        '{hostname: $host, tags: ["salvage", $vol, $machine, $crane]}'
      return 0
    fi
    return "${TESTING_SNAPSHOTS_RC:-1}"
  fi

  if [[ "$joined" == *" ls "* ]]; then
    printf '%s\n' '{"type":"dir","path":"/salvage/volume"}' '{"type":"dir","path":"/salvage/meta"}'
    return 0
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
