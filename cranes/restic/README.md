# Salvage Restic Crane

This crane backs up the Salvage-provided directories:

- /salvage/volume (read-only mount of the Docker volume)
- /salvage/meta (metadata directory)

## Required environment variables

Salvage provides:

- SALVAGE_MACHINE_NAME
- SALVAGE_CRANE_NAME
- SALVAGE_VOLUME_NAME
- SALVAGE_TIDE_TIMESTAMP

Crane requires:

- REPO_BASE_LOCATION (supports rotation via ';', e.g. /repo/a;/repo/b;/repo/c)
- RESTIC_PASSWORD_FILE (recommended) or RESTIC_PASSWORD

## Safe defaults

- SINGLE_REPO=true
- RESTIC_RETRY_LOCK=1h
- FORGET_ARGS empty (retention disabled)
- DO_PRUNE=false

## Snapshot identity (important)

By default, snapshots use:

- --host "${SALVAGE_MACHINE_NAME}-${SALVAGE_VOLUME_NAME}"
- tags: salvage, vol-..., machine-..., crane-...

This keeps retention scoped to the correct volume.

## Optional settings

- RESTIC_ARGS: extra global args for restic
- BACKUP_ARGS: extra args for restic backup
- RESTIC_HOST: override host value
- RESTIC_CACHE_DIR: mount a writable cache volume for better performance

## Retention and prune

Retention is only enabled when FORGET_ARGS is set. Forget is always scoped by
host and tags to avoid deleting snapshots from other volumes. Prune is only
added when DO_PRUNE=true.

## Multi repo mode (one repository per volume)

Set:

- SINGLE_REPO=false

Repository becomes:

<REPO_BASE_LOCATION>/<machine>/<volume>

## Example Salvage labels (concept)

- salvage.cranes.restic.image=ghcr.io/<owner>/<repo>-restic:master
- salvage.cranes.restic.env.REPO_BASE_LOCATION=s3:s3.amazonaws.com/mybucket/prefix
- salvage.cranes.restic.env.RESTIC_PASSWORD_FILE=/run/secrets/restic_password
- salvage.cranes.restic.env.RESTIC_RETRY_LOCK=2h

Optional cache mount:

- salvage.cranes.restic.mount.salvage-restic-cache=/cache
- salvage.cranes.restic.env.RESTIC_CACHE_DIR=/cache
