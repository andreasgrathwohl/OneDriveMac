## Neu in 1.1

- **Dokument öffnet sich jetzt auch, wenn Word, Excel oder PowerPoint noch nicht läuft.** Bisher startete Office, das Dokument blieb aber zu. Die App startet Office jetzt zuerst und übergibt das Dokument, sobald Office bereit ist.
- **Neue Oberfläche im macOS-Stil:** verständlicher Status in der Menüleiste („Aktiv“, „Bereit“, „Pausiert“) mit Ein-Klick-Lösung, Liste „Zuletzt geöffnet“, Pausieren/Fortsetzen; technische Details im Untermenü „Fehlerbehebung“.
- **Einstellungen mit Reitern** (Allgemein, Ordner, Fehlerbehebung) im Stil der Systemeinstellungen; Ordner mit Kennzeichnung „AutoSpeichern“ / „Ohne AutoSpeichern“; eigene Zuordnungen per „+“.
- **Eigenes App-Symbol.**
- Verständlichere Hinweise, wenn OneDrive eine Datei noch hochlädt.

## Installation / Update

1. `OneDriveOpener-*.zip` unten herunterladen, entpacken, `OneDrive Opener.app` nach **Programme** ziehen (vorhandene Version ersetzen; vorher über das Menüleisten-Symbol beenden).
2. Die App ist nur ad-hoc signiert (nicht notarisiert). Einmalig im Terminal freigeben und starten:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/OneDrive Opener.app" && open "/Applications/OneDrive Opener.app"
   ```
3. Menüleisten-Symbol → **„Für Doppelklick aktivieren“**.

Alternativ selbst bauen: siehe [README](https://github.com/andreasgrathwohl/OneDriveMac#installation). Voraussetzungen: macOS 12+, Microsoft Office, OneDrive. Universal (Apple Silicon + Intel).

Probleme bitte mit Diagnosebericht (Menü → Fehlerbehebung → „Diagnosebericht kopieren“) als Issue melden.
