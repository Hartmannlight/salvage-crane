# Changes

## Backup safety audit

- Borg archive retention uses a fixed-width SHA-256 identity containing machine, crane and volume.
  Prefix-related volumes and different machines no longer share a pruning selector.
- Existing legacy archives are preserved outside automatic pruning. Review and migrate their retention
  explicitly; the upgrade does not delete them. See `cranes/borgbackup/README.md`.
- Borg custom prefixes support literal identity placeholders without shell evaluation. Additional prune
  arguments are limited to validated retention options and cannot broaden the archive selector.
- Both Restic and Borg images are built and tested natively for amd64 and arm64. Only candidates that
  pass native backup/restore tests and the existing security scan are published; default-branch
  `latest`, `master` and `edge` tags point to the same multi-platform release.
- New installations use the corrected `ghcr.io/hartmannlight/salvage:master` coordinator fork.

Validation: existing Restic shell/integration/image suites and the new real Borg Docker suite
(`python3 cranes/borgbackup/tests/integration.py IMAGE`). The Borg suite checks exact restored bytes,
permissions, symlinks, full repository integrity, identity isolation, legacy preservation and unsafe
retention argument rejection.
