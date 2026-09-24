## Neu in 1.2

- **Dokumente öffnen sich jetzt wirklich in Word, Excel und PowerPoint – mit AutoSpeichern.** Bisher startete Office, das Dokument blieb aber zu: Office für Mac ignoriert die von Microsoft dokumentierte Adressform. Die App übergibt die Datei jetzt genauso wie „In Desktop-App öffnen“ in OneDrive im Web.
- **Office-Dateien behalten ihre Original-Symbole im Finder.** Die App übernimmt die Dokumentsymbole beim ersten Start aus dem installierten Office (sie werden nicht mit der App verteilt).
- Office wird bei Bedarf zuerst gestartet, bevor das Dokument übergeben wird.
- Neu unter Einstellungen → Fehlerbehebung: „Übergabe an Office“ (alternative Übergabewege für Sonderfälle).

Aus 1.1: neue Oberfläche im macOS-Stil (Status in der Menüleiste, Einstellungen mit Reitern), eigenes App-Symbol.

## Installation / Update

1. `OneDriveOpener-*.zip` unten herunterladen, entpacken, `OneDrive Opener.app` nach **Programme** ziehen (alte Version vorher über das Menüleisten-Symbol beenden und ersetzen).
2. Die App ist nur ad-hoc signiert (nicht notarisiert). Einmalig im Terminal freigeben und starten:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/OneDrive Opener.app" && open "/Applications/OneDrive Opener.app"
   ```
3. Menüleisten-Symbol → **„Für Doppelklick aktivieren“** (falls angezeigt). Nach dem Update fragt macOS eventuell einmal erneut nach dem Start bei der Anmeldung.

Alternativ selbst bauen: siehe [README](https://github.com/andreasgrathwohl/OneDriveMac#installation). Voraussetzungen: macOS 12+, Microsoft Office, OneDrive. Universal (Apple Silicon + Intel).

Probleme bitte mit Diagnosebericht (Menü → Fehlerbehebung → „Diagnosebericht kopieren“) als Issue melden.
