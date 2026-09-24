Office-Dateien aus OneDrive-/SharePoint-Ordnern per Doppelklick im Finder so öffnen, dass **AutoSpeichern** funktioniert – statt „Auf meinem Mac gespeichert“.

## Installation

1. `OneDriveOpener-*.zip` unten herunterladen, entpacken, `OneDrive Opener.app` nach **Programme** ziehen.
2. Die App ist nur ad-hoc signiert (nicht notarisiert). Einmalig im Terminal freigeben und starten:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/OneDrive Opener.app" && open "/Applications/OneDrive Opener.app"
   ```
3. Menüleisten-Symbol → **Einstellungen** → **„OneDrive Opener als Standard festlegen“**.

Alternativ selbst bauen: siehe [README](https://github.com/andreasgrathwohl/OneDriveMac#installation).

## Funktionen

- Registrierung für .docx/.docm, .xlsx/.xlsm/.xlsb, .pptx/.pptm – per Doppelklick (Standard-App) und unter „Öffnen mit“
- Ermittelt die Web-Adresse aus der Konfiguration des OneDrive-Clients (ohne Anmeldung) und öffnet über `ms-word:ofe|u|…` – AutoSpeichern aktiv
- Wartet auf ausstehende Uploads, fragt bei Konflikten nach
- Schutz vor Office-Updates: stellt die Standard-App-Zuordnung automatisch wieder her
- Menüleisten-Symbol mit Status, Live-Protokoll, Diagnose; Start bei Anmeldung
- Geschätzte Zuordnungen werden sicherheitshalber lokal geöffnet; manuelle Zuordnungen und MDM-Vorgaben möglich

## Hinweise

- Erste Version – bitte bei Problemen die Diagnose (Menü → „Diagnose in Zwischenablage kopieren“) in einem Issue posten.
- Voraussetzungen: macOS 12+, Microsoft Office, OneDrive-Client. Universal (Apple Silicon + Intel).
