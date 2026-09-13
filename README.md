# Salvage Crane Repository

This repository contains crane images for the Salvage backup system.
A crane implements the Salvage crane interface and performs the actual backup work.

Each crane is isolated under `cranes/<name>/` and built as an independent image.

## Upstream Salvage Project

Salvage daemon concepts and scheduling are documented in the main project:

- `https://github.com/chrisliebaer/salvage`

## Crane Matrix

- `dummy`: debug/inspection crane, no real backup
- `borgbackup`: borg-based crane
- `restic`: restic-based crane with stricter validation and helper tooling

## Crane Interface (Generic)

Salvage provides these runtime environment variables to every crane:

- `SALVAGE_MACHINE_NAME`
- `SALVAGE_CRANE_NAME`
- `SALVAGE_VOLUME_NAME`
- `SALVAGE_TIDE_TIMESTAMP` (epoch seconds)

Salvage mounts:

- `/salvage/volume` (read-only source volume)
- `/salvage/meta` (metadata directory)

All crane images should contain:

- `/salvage/volume`
- `/salvage/meta`

Contract rules:

- Cranes must treat `/salvage/volume` as immutable input.
- Cranes must back up both `/salvage/volume` and `/salvage/meta`.
- Exit code defines success/failure.
- Cranes must not rely on stable internals of `/salvage/meta`.

Typical crane labels on Salvage:

- `salvage.cranes.<name>.image`
- `salvage.cranes.<name>.pullOnRun`
- `salvage.cranes.<name>.env.<KEY>`
- `salvage.cranes.<name>.mount.<docker-volume>=<target-path>`

## Operating Principles

- Backup success alone is not enough; restore capability must be proven.
- Validate configuration before first production run.
- Keep retention scoped to avoid cross-volume deletions.

Preflight checklist:

- Volume labels resolve to expected volumes.
- Crane image exists (registry or local build).
- Credentials are present/readable in crane runtime.
- Backup destination is writable.

Rollout strategy:

1. Start with one non-critical volume.
2. Validate snapshot and logs.
3. Run restore drill.
4. Expand to critical volumes.

Security baseline:

- Prefer file-based secrets.
- Restrict secret/key file permissions.
- Enforce SSH host key verification for SFTP targets.
- Avoid broad retention deletion rules across unrelated backup sets.

Troubleshooting baseline:

- If backup failure lacks detail, inspect both Salvage and crane logs in the same execution window.
- If volumes are missing, verify `salvage.tide.<name>=...` labels on running containers and recreate affected services.
- If auth/connectivity fails, verify mounted secret/key/known_hosts files and destination reachability.

Crane-specific docs:

- `cranes/dummy/`
- `cranes/borgbackup/README.md`
- `cranes/restic/README.md`

For Hetzner Storage Box subaccounts, see the tested
[setup and restore guide](cranes/restic/README.md#hetzner-storage-box-einrichtung-und-wiederherstellung).

## Development Notes

- Build restic crane locally:
  - `docker build -t salvage-crane-restic:local ./cranes/restic`
- Run restic script tests:
  - `bash cranes/restic/test.sh`
