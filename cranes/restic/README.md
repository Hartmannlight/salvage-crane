# Salvage Restic Crane

This crane backs up both Salvage-provided paths:

- `/salvage/volume` (read-only Docker volume mount)
- `/salvage/meta` (metadata from Salvage)

The implementation is defensive by default:

- strict env validation
- automatic repository init when missing
- backup fails on incomplete snapshots
- post-backup snapshot verification (enabled by default)

## Required inputs

Salvage provides these automatically:

- `SALVAGE_MACHINE_NAME`
- `SALVAGE_CRANE_NAME`
- `SALVAGE_VOLUME_NAME`
- `SALVAGE_TIDE_TIMESTAMP` (epoch seconds)

You must provide authentication:

- `RESTIC_PASSWORD_FILE` (recommended) or `RESTIC_PASSWORD`

You must provide repository configuration by either:

1. `REPO_BASE_LOCATION`
2. or full SFTP tuple: `SFTP_HOST`, `SFTP_USER`, `SFTP_PATH` (optional `SFTP_PORT`, default `23`)

`REPO_BASE_LOCATION` also supports deterministic rotation with `;`, for example:

- `REPO_BASE_LOCATION=/repo/a;/repo/b;/repo/c`

## Defaults and safety controls

- `SINGLE_REPO=true`
- `RESTIC_RETRY_LOCK=1h`
- `VERIFY_SNAPSHOT=true`
- `VERIFY_REPOSITORY_CHECK=false`
- `DO_PRUNE=false`
- `FORGET_ARGS` empty (retention disabled)
- `STRICT_HOST_KEY_CHECKING=true` (for SFTP repositories)

Snapshot identity defaults:

- host: `${SALVAGE_MACHINE_NAME}-${SALVAGE_VOLUME_NAME}`
- tags: `salvage`, `vol-<volume>`, `machine-<machine>`, `crane-<crane>`

This keeps retention scoped to the correct backup unit.

## Optional environment variables

- `RESTIC_ARGS`: additional global restic args (advanced; see restrictions below)
- `BACKUP_ARGS`: additional `restic backup` args (advanced; whitespace-separated, without shell quoting; glob patterns remain literal)
- `RESTIC_HOST`: override snapshot host identity
- `RESTIC_CACHE_DIR`: writable cache mount
- `VERIFY_REPOSITORY_CHECK=true`: run `restic check` after verification and **before retention**
- `VERIFY_REPOSITORY_CHECK_READ_DATA_SUBSET=1/200`: optional subset for `restic check`
- `SSH_KEY_FILE`: SSH key path for SFTP repos (default `/root/.ssh/id_ed25519`)
- `SSH_KNOWN_HOSTS_FILE`: known_hosts path (default `/root/.ssh/known_hosts`)
- `STRICT_HOST_KEY_CHECKING=false`: disables strict host key enforcement (not recommended)

## Repository mode

Single repository mode (default):

- `SINGLE_REPO=true`
- repository target is the selected base location

Per-volume repository mode:

- `SINGLE_REPO=false`
- repository becomes: `<base>/<machine>/<volume>`

## Retention and prune

Retention runs only when `FORGET_ARGS` is set.
Forget is always scoped by host and tags.
Prune is only appended when `DO_PRUNE=true`.

All four identity tags must match together, even when multiple volumes use the
same `RESTIC_HOST`. `FORGET_ARGS` accepts the long `--keep-*` policy options and
`--dry-run`, for example `--keep-last 7 --keep-daily 30`. Counts must be positive
or `unlimited`. Snapshot IDs, additional filters, repository overrides and
`--prune` are rejected before any repository operation. Use `DO_PRUNE` for prune.

`RESTIC_ARGS` accepts compression, bandwidth limits, cache, certificate, key-hint,
HTTP user agent, stuck-request timeout, pack-size, verbosity, JSON and backend
`--option` settings. Repository overrides, `--no-lock`, and SFTP command/argument
overrides are rejected. Use the dedicated repository and `SSH_*` settings.
Argument strings use whitespace separation; embedded shell quoting is not
interpreted. For values containing spaces, use the corresponding Restic
environment variable (for example `RESTIC_CACHE_DIR`).
`BACKUP_ARGS` accepts exclusion options, `--force`, `--ignore-ctime`,
`--ignore-inode`, `--no-scan`, `--one-file-system`, `--with-atime`, and
`--read-concurrency`. Source, time, host and repository overrides are rejected,
including when snapshot verification is disabled.

`VERIFY_SNAPSHOT=true` checks the stored host/tags, requires both source
directories in the actual snapshot tree, and reads the metadata directory back.
It does **not** read every volume data block. Use repository checks and restore
drills for that. A failed backup or enabled verification prevents retention.
`VERIFY_SNAPSHOT=false` explicitly opts out of these snapshot checks.

The source volume must be an actual mount at `/salvage/volume`; an empty but
correctly mounted volume is valid. Salvage must also supply nonempty metadata.
The old `TESTING=true` runtime mode is rejected; mocks exist only in the tests.

For SFTP URLs, `sftp://user@host:23/relative` is relative to the remote home
directory and `sftp://user@host:23//absolute` is absolute. The SFTP environment
tuple preserves this distinction. Both URL and `sftp:user@host:path` syntax
receive the configured SSH identity and host checking options.
Because Restic 0.18.1 has limited argument quoting, SSH key paths cannot contain
both quote types or end in a backslash; known-hosts paths cannot contain quotes
or backslashes. Spaces are supported. Unsupported paths fail before repository access.
When upgrading an existing `SFTP_PATH=/absolute` configuration, locate the old
repository first: earlier versions incorrectly used the relative path. Move or
explicitly select that existing repository if you need to preserve its history.

## Example Salvage labels

```text
salvage.cranes.restic.image=ghcr.io/<owner>/<repo>-restic:master
salvage.cranes.restic.env.REPO_BASE_LOCATION=sftp://user@host:23/salvage
salvage.cranes.restic.env.RESTIC_PASSWORD_FILE=/run/secrets/restic_password
salvage.cranes.restic.env.RESTIC_CACHE_DIR=/cache
salvage.cranes.restic.mount.salvage-restic-cache=/cache
salvage.cranes.restic.mount.salvage-restic-ssh=/root/.ssh
salvage.cranes.restic.mount.salvage-restic-secrets=/run/secrets
```

## Local validation

Run script-level tests:

```bash
bash cranes/restic/test.sh
```

Requires Bash, jq and Python 3. Real backup/prune/restore regression tests require
Linux, bubblewrap and Restic (use the version pinned in the Dockerfile):

```bash
python3 cranes/restic/tests/integration.py --restic /path/to/restic
```

These tests generate fixtures and run with no network in a disposable filesystem
namespace. If the host disallows unprivileged namespaces, run through an
administrator-approved account. CI runs both test suites and blocks image
publication when Restic quality checks fail.

To exercise the Alpine image itself:

```bash
docker build -t salvage-crane-restic:audit cranes/restic
bash cranes/restic/tests/image-smoke.sh salvage-crane-restic:audit
```

## Setup Helpers (Restic-specific)

Helper files in this repository:

- `cranes/restic/tools/.env.example`
- `cranes/restic/tools/preflight.sh`
- `cranes/restic/tools/install.sh`
- `cranes/restic/tools/run-crane-smoke.sh`
- `cranes/restic/examples/docker-compose.salvage.yml`

Quick start:

```bash
cp cranes/restic/tools/.env.example cranes/restic/tools/.env
bash cranes/restic/tools/preflight.sh
bash cranes/restic/tools/install.sh
docker compose --env-file cranes/restic/tools/.runtime.env -f cranes/restic/examples/docker-compose.salvage.yml up -d
```

Notes:

- `.env` and `.runtime.env` are git-ignored in `cranes/restic/tools/`.
- With strict SSH checking, `SSH_KNOWN_HOSTS_SOURCE` must contain independently
  verified host keys for all SFTP targets, including rotated repositories. Setup
  no longer silently trusts the result of a first-contact `ssh-keyscan`.
- `.env` is sourced as Bash: quote values containing spaces, for example
  `TIDE_CRON='0 3 * * *'`. The generated runtime file quotes values for both Bash
  and Compose; single quotes and line breaks in generated values are rejected.
- Smoke test one volume manually with:
  - `bash cranes/restic/tools/run-crane-smoke.sh <docker-volume-name>`
- Smoke tests require an existing volume and always disable retention/prune.
  They do not stop applications; use a disposable or already quiesced volume
  when testing databases. Normal Salvage runs provide the application coordination.

See [AUDIT.md](AUDIT.md) for the findings, regression evidence and remaining limits.

## Hetzner Storage Box: Einrichtung und Wiederherstellung

### 1. Storage Box und Subaccount vorbereiten

In der Hetzner Console (bei älteren Konten gegebenenfalls Robot) die Storage Box
öffnen und einen Subaccount anlegen:

- Verzeichnis beispielsweise `homeserver`, mit Schreibzugriff.
- SSH-Support und den Zugriff von extern aktivieren; vorhandene Einstellungen
  der Storage Box und des Subaccounts prüfen.
- Den **Subaccount-Benutzernamen und seine eigene Domain** verwenden, zum Beispiel
  `u123456-sub1` und `u123456-sub1.your-storagebox.de`.

Wir verwenden Port **23**. Dort bietet Hetzner SFTP und den Befehl
`install-ssh-key`. Die eingeschränkte Shell unterstützt keine gewöhnlichen
Shell-Skripte oder Umleitungen; deshalb nicht einfach einen allgemeinen
`ssh-copy-id`-Aufruf mit Remote-Shell-Kommandos übernehmen.
[SSH-Zugang](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/),
[Schlüssel installieren](https://docs.hetzner.com/storage/storage-box/backup-space-ssh-keys/).

Bei einem auf `homeserver` begrenzten Subaccount ist dessen Startverzeichnis auf
Port 23 `/home`. Ein relativer Repository-Pfad `salvage` landet damit im
freigegebenen Verzeichnis, aus Sicht des Hauptaccounts unter
`homeserver/salvage`. **Nicht nochmals `/homeserver/` als `SFTP_PATH` eintragen.**
Der Ordner der Backupsoftware ist relativ zum Startverzeichnis des Subaccounts.
[Hetzner beschreibt diese relativen Pfade hier](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/).

### 2. Ein Befehl für Schlüssel, Zugangsdaten und Crane

Auf dem Docker-Host werden Bash, Docker mit Compose, OpenSSH-Client und `jq`
benötigt. Restic läuft im Crane-Image; eine Installation von Restic auf dem Host
ist für die Helfer nicht nötig. Die Befehle werden im Wurzelverzeichnis dieses
Git-Repositories ausgeführt:

```bash
bash cranes/restic/tools/setup-hetzner.sh u123456-sub1 salvage
```

Der Helfer:

1. Prüft den ED25519-Hostschlüssel gegen den von Hetzner veröffentlichten
   SHA-256-Fingerprint, **bevor** Zugangsdaten übertragen werden.
2. Erzeugt einen eigenen ED25519-Schlüssel, falls noch keiner vorhanden ist.
3. Hinterlegt den öffentlichen Schlüssel über Hetzners `install-ssh-key` und
   prüft anschließend die Anmeldung ohne Passwort. SSH fragt einmal nach dem
   **Passwort des Subaccounts**; der Helfer speichert dieses Passwort nicht.
4. Erzeugt ein **separates zufälliges Restic-Passwort** zur Verschlüsselung.
5. Schreibt `.env`, baut das Crane-Image und kopiert SSH-Schlüssel,
   `known_hosts` und Restic-Passwort in eigene Docker-Volumes.

Der veröffentlichte ED25519-Fingerprint war am 13.09.2026
`SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM`.
Bei einer Abweichung bricht der Helfer ab. Nach einer unabhängig bestätigten
Schlüsselrotation kann `HETZNER_HOST_KEY_SHA256` gesetzt werden.
[Offizielle Fingerprints](https://docs.hetzner.com/storage/storage-box/general/#ssh-host-keys).

Die Dateien liegen standardmäßig unter:

```text
cranes/restic/tools/.env
cranes/restic/tools/.runtime.env
cranes/restic/tools/.local/hetzner-u123456-sub1/id_ed25519
cranes/restic/tools/.local/hetzner-u123456-sub1/id_ed25519.pub
cranes/restic/tools/.local/hetzner-u123456-sub1/known_hosts
cranes/restic/tools/.local/hetzner-u123456-sub1/restic_password
```

Private Dateien sind Git-ignoriert und vom Docker-Build-Kontext ausgeschlossen.
Das **Restic-Passwort zusätzlich unabhängig aufbewahren**: Ein neues
Storage-Box-Passwort oder ein neuer SSH-Schlüssel ersetzt dieses
Verschlüsselungspasswort nicht. Das Restic-Passwort später nicht einfach durch
Überschreiben der Datei wechseln; dafür die Restic-Schlüsselverwaltung verwenden.

Eine vorhandene `.env` wird nicht überschrieben. Für eine zweite Einrichtung
können `ENV_FILE`, `RUNTIME_ENV_FILE` und optional `HETZNER_SETUP_DIR` auf separate
Pfade gesetzt werden. Für bestehende Schlüssel gibt es weiterhin den manuellen
Weg: `.env.example` kopieren, `SSH_PRIVATE_KEY_SOURCE`,
`SSH_KNOWN_HOSTS_SOURCE`, `RESTIC_PASSWORD_FILE_SOURCE` und die SFTP-Daten setzen,
dann `preflight.sh` und `install.sh` ausführen.

### 3. Maschine, Zeitplan und Volumes zuordnen

In `cranes/restic/tools/.env` prüfen:

```bash
MACHINE='homeserver'              # dauerhaft stabil halten
TZ='Europe/Berlin'
TIDE_CRON='0 3 * * *'             # täglich um 03:00, fünf Cron-Felder
TIDE_MAX_CONCURRENT='1'
SINGLE_REPO='true'
FORGET_ARGS=''                    # zunächst keine alten Sicherungen löschen
DO_PRUNE='false'
```

Der Helfer übernimmt zunächst den lokalen Hostnamen als `MACHINE`. Nach einer
Änderung `.runtime.env` und die Docker-Zugangsdaten erneut erzeugen:

```bash
bash cranes/restic/tools/preflight.sh
bash cranes/restic/tools/install.sh
```

Den zu sichernden Anwendungscontainer in seiner Compose-Datei beispielsweise
mit diesen Labels versehen (`data` ist hier der Compose-Volume-Schlüssel):

```yaml
labels:
  - "salvage.tide.nightly=data"
  - "salvage.action=stop"
```

Die Vorbereitung der Anwendung muss zu deren Konsistenzanforderungen passen.
Salvage übernimmt beim regulären Lauf das Stoppen und Wiederstarten; der manuelle
Smoke-Test tut das nicht.
[Schnittstelle und Container-Aktionen](https://github.com/chrisliebaer/salvage#container-configuration).

Nach dem ersten Restore-Test kann Salvage gestartet werden:

```bash
docker compose --env-file cranes/restic/tools/.runtime.env \
  -f cranes/restic/examples/docker-compose.salvage.yml up -d
```

### 4. Backup wirklich wiederherstellen

Für einen ersten manuellen Test ein vorhandenes, entbehrliches oder bereits
ruhendes Volume verwenden. Bei den Helfern ist immer der tatsächliche
**Docker-Volume-Name** gemeint, zum Beispiel `myproject_data`:

```bash
docker volume ls
bash cranes/restic/tools/run-crane-smoke.sh myproject_data
bash cranes/restic/tools/repository.sh snapshots myproject_data
bash cranes/restic/tools/repository.sh restore myproject_data latest ./restore-test
bash cranes/restic/tools/repository.sh check myproject_data
```

`restore-test` muss fehlen oder leer sein. Die Nutzdaten liegen danach unter
`restore-test/salvage/volume`, die Salvage-Metadaten unter
`restore-test/salvage/meta`. Anschließend Dateien und die Anwendung selbst prüfen.
`restore` verwendet Restics `--verify`; `check` liest mit `--read-data` alle
Datenblöcke des ausgewählten Repositorys und kann bei großen Beständen dauern.

Für einen bestimmten Zeitpunkt statt `latest` eine ID aus `snapshots` angeben.
Der Helfer lehnt IDs anderer Volumes/Maschinen/Cranes und nicht leere Zielordner
ab. Er verwendet dasselbe Image, denselben Repository-Modus und dieselbe
SSH-Konfiguration wie der Backup-Crane. Bei wechselnden Repository-Zielen muss
`REPOSITORY_BASE_OVERRIDE` eines der Basisziele ausdrücklich auswählen.

Erst nach einem erfolgreichen Restore zum Beispiel `FORGET_ARGS='--keep-last 7 --keep-daily 30'` als eine Zeile konfigurieren und bei Bedarf
`DO_PRUNE='true'` setzen. Der manuelle Smoke-Test lässt diese Optionen immer aus;
der reguläre Crane wendet die konfigurierte Aufbewahrung an.

### 5. Reproduzierbarer Test gegen eine echte Storage Box

Nach der Einrichtung kann ein vollständiger Test mit generierten Daten laufen:

```bash
python3 cranes/restic/tests/remote.py \
  --output cranes/restic/tools/.local/storagebox-live-test
```

Das Zielverzeichnis muss neu sein. Der Test legt unter dem konfigurierten SFTP-Ziel
ein **neues** Unterrepository und zwei neue Docker-Testvolumes an. Er testet zwei
Datenstände, gelöschte/geänderte Dateien, Wiederherstellung, die Abweisung einer
fremden Snapshot-ID, Retention/Prune und vollständige Repository-Prüfungen.
`report.json`, Logs, SHA-256-Manifeste und wiederhergestellte Daten bleiben im
Ausgabeverzeichnis. Das Testrepository und die Testvolumes bleiben zur Kontrolle
erhalten; sie enthalten ausschließlich erzeugte Testdaten. Dieser Netzwerktest
läuft nicht automatisch in CI und benötigt Python 3.

**Praktisch geprüft am 13.09.2026:** Restic 0.18.1 im Alpine-Crane gegen einen
Hetzner-Subaccount, über dessen externe Domain und Port 23. Je Datenstand wurden
40 Einträge inklusive etwa 2 MiB Binärdaten, Leerdateien, Verzeichnissen,
Umlauten, Leerzeichen und Symlinks geprüft. Vier Wiederherstellungen bestanden:
Version 1, Version 2, das zweite Volume und der aktuelle Stand nach Prune.
Dateiinhalte, Rechte, Namen und Metadaten stimmten; die Sicherung des zweiten
Volumes blieb erhalten. Vollständige Datenprüfungen vor und nach Prune waren
erfolgreich. Geprüft wurden der Crane und die Helfer; eine laufende Datenbank und
die vollständige Salvage-Orchestrierung waren nicht Teil dieses Tests.

## Restore Drill (Restic-specific)

Use this runbook to prove backups are restorable. Backup success without restore tests is not enough.

Frequency:

- run at least monthly
- run after major crane/config changes

Inputs:

- `cranes/restic/tools/.runtime.env` generated by `cranes/restic/tools/install.sh`
- target snapshot ID (or latest for selected host/tags)
- empty restore target directory or volume

Procedure:

1. Select a representative volume.
2. Pick snapshot:
   - `restic snapshots --host <machine-volume-host> --tag salvage,vol-<volume>,machine-<machine>,crane-<crane>`
3. Restore to a temp location:
   - `restic restore <snapshot-id> --target /tmp/restic-restore-test`
4. Validate structure:
   - `/tmp/restic-restore-test/salvage/meta` contains the supplied metadata
   - `/tmp/restic-restore-test/salvage/volume` exists
5. Validate sample data in restored volume subtree.
6. Record date/time, volume, snapshot ID, duration, pass/fail, notes.

Pass criteria:

- restore exits `0`
- metadata and volume paths exist
- restored sample data is usable

Failure handling:

1. Freeze retention/prune changes until root cause is known.
2. Preserve logs and failing snapshot ID.
3. Re-run smoke backup and restore test after remediation.
