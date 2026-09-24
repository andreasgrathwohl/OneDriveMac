## Neu in 1.3

- **Word-Integration:** Word-Dokumente aus OneDrive, die lokal geöffnet wurden – über „Zuletzt verwendet“, das Dock, Spotlight oder nach „Speichern unter“ in den OneDrive-Ordner – werden automatisch mit AutoSpeichern neu geöffnet. Dokumente mit ungespeicherten Änderungen werden nie angefasst. macOS fragt einmalig, ob OneDrive Opener Word steuern darf – bitte erlauben.
- **Automatische Updates:** Die App prüft die Releases auf GitHub und aktualisiert sich selbst (ab dieser Version; auf 1.3 bitte noch einmal manuell aktualisieren).
- **Einrichtung ohne Klick:** Beim ersten Start aus „Programme“ richtet sich die App selbst als Standard-App ein.

Aus 1.2: Dokumente öffnen zuverlässig mit AutoSpeichern, Office-Dateien behalten ihre Original-Symbole.

## Installation / Update

1. `OneDriveOpener-*.zip` unten herunterladen, entpacken, `OneDrive Opener.app` nach **Programme** ziehen (alte Version vorher über das Menüleisten-Symbol beenden und ersetzen).
2. Die App ist nur ad-hoc signiert (nicht notarisiert). Einmalig im Terminal freigeben und starten:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/OneDrive Opener.app" && open "/Applications/OneDrive Opener.app"
   ```
3. Nachfragen von macOS erlauben (Word steuern, ggf. Start bei der Anmeldung). Weitere Schritte sind nicht nötig.

Hinweis: Weil die App nicht mit einem Apple-Entwicklerzertifikat signiert ist, kann macOS nach einem Update die Freigaben erneut abfragen.

Probleme bitte mit Diagnosebericht (Menü → Fehlerbehebung → „Diagnosebericht kopieren“) als Issue melden.
