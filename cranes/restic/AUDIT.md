# Restic crane audit — 2026-09-13

Audited fork baseline: `56fc07969dc4226bd538cc008e6844f696fd2592`.
Salvage interface reference: `chrisliebaer/salvage` at
`ca32064664969d505cbad47d851337251e221836`.
Functional changes are confined to `cranes/restic/`; CI also runs and gates on the
new tests. Borg and the upstream daemon have not been modified.

## Findings and corrections

| Impact | Finding | Correction |
| --- | --- | --- |
| Critical: deletion of unrelated backups | Four separate `forget --tag` arguments selected any matching tag. Shared/overlapping hosts could lose other volumes, machines or cranes. | Require all identity tags in one comma-separated filter. Reject identity delimiters and traversal components. |
| High: bypass of retention scope | Raw `FORGET_ARGS` accepted snapshot IDs, additional host/tag filters and repository overrides. IDs bypass normal policy filtering. | Accept only long retention policy options and `--dry-run`; validate before repository access. Prune requires `DO_PRUNE`. |
| High: deletion after an unusable backup | A completely excluded volume could still return backup success; verification only read one metadata file. | Verify actual snapshot identity and both source directories, and read the metadata directory back. Reject backup source/identity/repository overrides. |
| High: deletion before a failing integrity check | `check` ran after `forget --prune`, so a failing enabled check could be reported only after old snapshots had been removed. | Run enabled consistency checks before retention. |
| High: fake backup success | `TESTING=true` could report success in the distributed runtime without writing a backup. | Runtime rejects the setting; mock execution is confined to test files excluded from the image. |
| High: missing source silently accepted | Dockerfile-created `/salvage/volume` satisfied the directory-only check even with no source mount. | Require an actual mount and nonempty supplied metadata. Empty mounted volumes remain supported. |
| High: configured SSH policy ineffective | Key and known-hosts paths were validated but never supplied to SSH. Legacy SFTP syntax bypassed validation. | Apply identity, batch mode, strict checking and known-hosts options for both SFTP syntaxes; correctly encode Restic CSV and SSH quoting. |
| High: unverified first-contact host keys | Setup silently trusted `ssh-keyscan` output while presenting strict checking as enabled. | Strict setup requires independently verified `SSH_KNOWN_HOSTS_SOURCE`, covering all rotated targets. |
| Incorrect destination | Absolute SFTP paths used one slash after the authority and therefore became home-relative. Mixed local/SFTP rotation could skip SSH setup. | Preserve absolute paths with the extra slash; detect SFTP anywhere in a rotation list. |
| Broken setup and temporary secret leakage | Unquoted cron/retention/repository values broke Bash loading; EXIT traps referenced expired local variables. | Quote generated Bash/Compose values; fix the example, capture cleanup paths, use a private umask and validate secret filenames. |
| Unsafe smoke run | A typo could create an empty Docker volume. The manual test inherited production retention/prune while bypassing application quiescing. | Require an existing source, disable retention/prune, escape generated metadata and clean up reliably. |
| Fragile argument/rotation handling | Shell globs expanded against container files; process-substitution errors were lost; leading-zero timestamps used octal arithmetic. | Preserve literal patterns, validate restricted options, propagate repository-list failures, bound and parse decimal timestamps/ports. |
| CI publication race | Image publication did not depend on Restic quality checks. | Make build/publication depend on successful Restic tests, including real backups and the Alpine image. |

Restic documents the distinction between AND and OR tag filters in
[Removing backup snapshots](https://restic.readthedocs.io/en/stable/060_forget.html#removing-snapshots-according-to-a-policy),
and the relative/absolute SFTP URL distinction in
[Preparing a new repository](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#sftp).
The behavior was also tested with the image's pinned Restic 0.18.1 binary.

## Evidence

- The 18 existing script cases continue to pass.
- `tests/regression.py` adds 25 tests, with multiple configurations per test,
  covering error propagation, filters, argument handling, setup, SSH, cleanup,
  rotation and smoke behavior. `test.sh` invokes both suites.
- `tests/integration.py` uses genuine Restic 0.18.1 in an isolated filesystem
  namespace with generated data and no network. It covers retention across
  volumes/machines/cranes sharing one host, pruning, byte-exact restore,
  permissions, symlinks, metadata, full data checking, initialization, wrong
  passwords, excluded sources, a failing pre-retention check, and SSH argv.
- Running those same five integration tests against the **unmodified baseline**
  reproduced four failures: unrelated snapshots deleted, old snapshots deleted
  before a failed check, excluded-volume backup accepted, and SSH options absent.
  The corrected implementation passes all five.
- `tests/image-smoke.sh` exercises backup, retention/prune and verified restore
  in the real Alpine image; it also checks rejection of a missing volume mount
  before repository initialization. All its mounts contain generated test data.
- ShellCheck and Bash syntax checks cover all changed shell scripts.

## Upgrade notes and remaining limits

Read `README.md` for the restricted argument options and test commands. Existing
absolute `SFTP_PATH` configurations need attention: old versions may have stored
the repository under a relative path. Locate that history before switching.
Strict SSH setup now requires a verified known-hosts file.

These checks validate the crane, not every deployment of the complete backup
system. The initial isolated suite used no live SFTP server; a subsequent real
Storage Box test is recorded below. Production data, database recovery,
power-loss scenarios and the full Salvage scheduling/container lifecycle
have not been tested. The isolated SSH regression captures arguments at the
SSH executable boundary; the live follow-up also establishes real SSH sessions. Routine verification reads metadata and checks the tree/identity;
it does not replace full-data checks and application-specific restore drills.

The inspected upstream `SalvageVessel.java` explicitly documents an unresolved
race between automatic container removal and waiting for its exit status. That
is outside this repository's allowed functional scope and has not been fixed or
reproduced here. It remains relevant to an end-to-end deployment review.

## Live Hetzner follow-up — 2026-09-13

A user-authorized Storage Box subaccount was tested through its external domain
on port 23. Its ED25519 host key matched Hetzner's independently published
fingerprint. A dedicated client key was generated and added using
`install-ssh-key`; key-only authentication and the `/home` starting directory
were confirmed.

The real Alpine crane created three initial snapshots across two generated
volumes, then an additional snapshot for the retention run. Both versions of the
first volume and the second volume were restored. Content SHA-256, paths,
permissions, symlinks and metadata matched all 40 fixture entries (about 2 MiB
of binary data plus small text files). Retention/prune kept exactly one snapshot
of the first volume and preserved the second volume. The current snapshot
remained restorable after pruning. Full remote `check --read-data` passed before
and after pruning. The restore helper rejected a foreign snapshot and a
nonempty target.

The ignored `tools/.local/hetzner-test/live-run-1/report.json` records snapshot
IDs, repository location, test volumes and results. Adjacent directories hold
logs, manifests and the four restored datasets. No Storage Box login password
is stored there; the independently generated Restic password and client key
are in the private parent directory. Generated remote data and test volumes
are retained for inspection.

The setup exercise also produced these improvements:

- `setup-hetzner.sh` handles host verification, client key generation/upload,
  a separate repository password and Docker setup. It preserves existing keys
  and refuses to overwrite an existing environment file.
- `repository.sh` reuses the crane configuration for scoped snapshot listing,
  verified restore to an empty directory, and full repository data checks.
- The installer reuses the selected crane image instead of pulling an unrelated
  `alpine:latest` helper image. Its next-step command respects custom env paths.
- The Docker build context explicitly excludes setup secrets and local test data.
- The README documents the complete Hetzner workflow and the reproducible,
  explicit opt-in `tests/remote.py` network test.
