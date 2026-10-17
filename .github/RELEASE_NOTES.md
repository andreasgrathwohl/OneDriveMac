## Neu in 1.6.0

- **Hinweis beim Speichern:** Braucht Word, Excel oder PowerPoint länger als 45 Sekunden zum Speichern, zeigt ein kleines Fenster oben rechts, dass noch gespeichert wird – bitte dann das Dokument nicht schließen und den Mac nicht zuklappen. Danach erscheint kurz „Alles gespeichert“.
- **Excel und PowerPoint wie Word:** Lokal geöffnete Arbeitsmappen und Präsentationen aus OneDrive werden jetzt ebenfalls automatisch mit AutoSpeichern neu geöffnet. macOS fragt dafür einmalig, ob OneDrive Opener Excel bzw. PowerPoint steuern darf – bitte erlauben.
- **OneDrive-App im Blick:** Läuft OneDrive nicht, ist es nicht angemeldet, ist der Speicher fast voll oder bleibt ein Upload hängen (z. B. weil OneDrive pausiert ist), zeigt die Menüleiste eine Warnung mit Knopf zum Öffnen von OneDrive.
- **Genauere Messung bei langem Speichern:** Dateigröße und wie viel OneDrive, Office und andere Programme in der Zeit übers Netz übertragen haben – um zu klären, ob die OneDrive-App Office ausbremst.

## Neu in 1.5.0

- **Speicherdauer messen:** Dauert es in Word oder PowerPoint lange, bis „Gespeichert“ erscheint, misst die App jetzt, wie lange jeder Speichervorgang braucht, und meldet lange Vorgänge automatisch an den Entwickler (nur mit Zustimmung zu Fehlerberichten). Dafür fragt sie einmalig nach der macOS-Freigabe „Bedienungshilfen“ – bitte in den Systemeinstellungen „OneDrive Opener“ einschalten. Gelesen wird nur die Titelleiste, keine Dokumentinhalte. Abschaltbar unter Einstellungen → Fehlerbehebung → Speichern.

## Neu in 1.4.4

- **Ordner mit „/“ im Namen (z. B. „2025/26_7b“) öffnen jetzt wirklich mit AutoSpeichern.** OneDrive speichert den Namen online als „2025&#x3a;26_7b“ und erwartet ihn in einer eigenen Schreibweise in der Adresse – die App verwendet jetzt genau dieselbe Adresse wie „In Desktop-App öffnen“ in OneDrive im Web.
- Update-Prüfung über die normale GitHub-Release-Seite – kein „Status 403“ mehr in Netzen mit vielen Geräten (z. B. Schule).

## Neu in 1.4.3

- **Ordner mit „/“ im Namen (z. B. „2025/26-8c“) öffnen jetzt mit AutoSpeichern.** OneDrive behält das Zeichen online als Doppelpunkt („2025:26-8c“); die App hatte es fälschlich in „_“ umgewandelt. Die Schreibweise wird jetzt aus der Datenbank des OneDrive-Clients bestätigt.

## Neu in 1.4.2

- **Ordner mit „/“ im Namen (z. B. „2025/26-8c“):** Die App liest die echte Online-Schreibweise jetzt aus der Datenbank des OneDrive-Clients, statt sie zu raten. Dokumente aus solchen Ordnern öffnen damit mit AutoSpeichern.
- Mehrere Dokumente nacheinander: Die Wartesperre gilt jetzt bis Word das vorige Dokument wirklich geöffnet hat.
- Kurze Netzwerkunterbrechungen beim Laden eines Updates werden nicht mehr als Fehler gemeldet.

## Neu in 1.4.1

- **Mehrere Dokumente kurz nacheinander öffnen** funktioniert jetzt zuverlässig: Die App wartet, bis Word das vorige Dokument aus der Cloud geladen hat, bevor sie das nächste übergibt (zuvor öffnete sich das zweite Dokument nur lokal).
- Öffnet sich ein Dokument nicht innerhalb von 20 Sekunden, wird es einmal erneut an Word übergeben.
- Fehlende Internetverbindung bei der Update-Prüfung wird nicht mehr als Fehler gemeldet.

## Neu in 1.4

- **Fehlerberichte (nach Zustimmung):** Einmalig fragt die App, ob sie Fehler an den Entwickler melden darf. Gesendet werden Fehlermeldungen, Versionen, betroffene Datei-/Ordnernamen und Protokollzeilen – keine Dokumentinhalte. Abschaltbar unter Einstellungen → Fehlerbehebung.
- **Selbstkontrolle:** Öffnet Word ein Dokument nicht, wird das erkannt, gemeldet und die Datei lokal geöffnet.
- **Lernt Ordnernamen:** Wird ein Dokument einmal als Cloud-Dokument geöffnet (z. B. über „Zuletzt verwendet“), merkt sich die App, wie OneDrive abweichende Ordnernamen online schreibt.
- **Updates schneller:** Prüfung stündlich, nach dem Aufwachen und sobald wieder Internet da ist.

## Neu in 1.3.1

- **Ordner mit „/“ im Namen** (z. B. „2025/26-8c“) öffnen jetzt mit AutoSpeichern – OneDrive speichert sie online als „2025_26-8c“.
- **Ohne Internet** öffnen Office-Dateien lokal statt mit der Meldung „Die Datei kann nicht geöffnet werden“; die Menüleiste zeigt „Offline“. Mit Verbindung wieder wie gewohnt mit AutoSpeichern.
- Dateien mit anderen Zeichen, die OneDrive online nicht erlaubt, werden sicherheitshalber lokal geöffnet.

Wer 1.3.0 installiert hat, bekommt dieses Update automatisch.

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
