# Salvage Crane Repository

This repository contains "cranes" for the Salvage backup system.
A crane is a Docker image that implements the Salvage crane interface and performs the actual backup.
Each crane lives in its own subdirectory under `cranes/` and is built/pushed as a separate image.

## Concepts (Salvage Crane Interface)

Salvage concepts, configuration, and the crane interface are documented in the main Salvage repo.
Please refer to:
`https://github.com/chrisliebaer/salvage/tree/master`


## Cranes

Each crane has its own documentation. Please refer to:

- `cranes/dummy/` (no extra docs; the crane is self-describing)
- `cranes/borgbackup/README.md`
- `cranes/restic/README.md`

## Usage (Salvage labels example)

Attach to the Salvage container:

```
- "salvage.cranes.restic.image=ghcr.io/<owner>/<repo>-restic:master"
- "salvage.cranes.restic.env.REPO_BASE_LOCATION=s3:s3.amazonaws.com/mybucket/prefix"
- "salvage.cranes.restic.env.RESTIC_PASSWORD_FILE=/run/secrets/restic_password"
- "salvage.cranes.restic.env.RESTIC_RETRY_LOCK=2h"
```

Optional cache mount:

```
- "salvage.cranes.restic.mount.salvage-restic-cache=/cache"
- "salvage.cranes.restic.env.RESTIC_CACHE_DIR=/cache"
```

## Disclaimers and Warnings

- Salvage mounts volumes read-only, so the crane should not modify source data.
- Retention/prune can delete snapshots. Always scope retention correctly.
- When using a single repository with concurrent backups, locks can cause wait/retry or failures.
- Do not rely on contents of `/salvage/meta`; it may change over time.

## Development Notes

- Build a crane locally:
  - `docker build -t salvage-crane-restic:local ./cranes/restic`
- Run locally with mounted test data (example only).
