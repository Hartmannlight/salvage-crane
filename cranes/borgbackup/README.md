# Basic Setup

TODO: more than just shell commands
```
docker volume create salvage-borg-data
docker volume create salvage-borg-ssh
docker run -it -v salvage-borg-data:/borg -v salvage-borg-ssh:/root/.ssh --entrypoint bash --rm ghcr.io/hartmannlight/salvage-crane-borgbackup:master

# add host fingerprint to known_hosts by connecting once and checking connection
ssh user@host.tld
```

## Backup safety and upgrade from legacy archives

Archives now use `salvage-v2-<SHA256(machine NUL crane NUL volume NUL)>-<time>-<uuid>`.
Retention selects only that complete identity. A backup of `data` cannot prune
`data-child`, another machine, or another crane in a shared repository.

Existing `v_<volume>-...` and older custom-prefix archives remain restorable and
are **never automatically pruned by the new namespace**. Inventory and restore-test
them before any deliberate manual cleanup. Upgrade does not delete or rename them.
Keep machine, crane and volume identities stable to continue their retention history.

`CUSTOM_PREFIX` is an optional descriptive suffix inside the safe identity prefix.
It accepts a simple name (letters, numbers, `_`, `.`, `-`, up to 80 characters) and
the placeholders `${SALVAGE_MACHINE_NAME}`, `${SALVAGE_CRANE_NAME}` and
`${SALVAGE_VOLUME_NAME}`. It no longer executes shell expressions.

`PRUNE_ARGS` accepts the long `--keep-*` count policies, `--keep-within`, and
`--dry-run`. Counts must be positive or `-1` (keep all); extra archive selectors
are rejected before repository operations. Use `DO_COMPACT` for compaction.

Run native Docker backup/restore and retention regression tests:

```sh
docker build -t salvage-crane-borgbackup:test cranes/borgbackup
python3 cranes/borgbackup/tests/integration.py salvage-crane-borgbackup:test
```
