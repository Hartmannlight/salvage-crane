# AGENTS.md

Diese Datei definiert die verbindlichen Arbeitsregeln fuer Agenten in diesem Repository.

## Ziel des Repositories

- Dieses Repo (`salvage-crane`) enthaelt Crane-Implementierungen fuer `salvage`.
- Die aktive Entwicklungsflaeche ist aktuell der `restic`-Crane.

## Projektkontext

- Das urspruengliche Hauptprojekt liegt extern unter:
  - `https://github.com/chrisliebaer/salvage`
- Lokale Referenzordner wie `context/` sind optional und nicht Teil des Repos.

## Aktueller Arbeitsfokus (verbindlich)

- Die regulaere Entwicklungsflaeche ist `cranes/restic/**`.
- Fuer den beauftragten Backup-Sicherheitsaudit sind gezielte Korrekturen und Regressionstests in `cranes/borgbackup/**` ebenfalls erlaubt.
- Keine fachfremden Borg-Refactorings; bestehende Archive bei Migrationen erhalten.

## Erlaubte Ausnahmen

- Dokumentation darf angepasst werden (z. B. `README.md`, `cranes/restic/README.md`).
- CI-/Automationsdateien duerfen angepasst werden (z. B. `.github/**`), wenn es fuer die Arbeit an `restic` erforderlich ist.

## Arbeitsweise

- Vor Implementierung relevante Schnittstellen bei Bedarf im Hauptprojekt pruefen.
- Aenderungen klein, nachvollziehbar und zielgerichtet halten.
- Keine nicht angefragten Refactorings in anderen Cranes.
- Bestehende, nicht verwandte Aenderungen im Worktree nicht rueckgaengig machen.

## Validierung

- Nach Aenderungen an `restic` mindestens die vorhandenen Tests/Checks fuer `restic` ausfuehren, wenn moeglich:
  - `cranes/restic/test.sh`
- Wenn Tests nicht ausgefuehrt werden koennen, klar dokumentieren warum.

## Prioritaet bei Konflikten

1. Direkte User-Anweisungen
2. Diese `AGENTS.md`
3. Sonstige allgemeine Konventionen
