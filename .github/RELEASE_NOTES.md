## Neu in 1.9.5

- **Sehen, ob wirklich hochgeladen wird.** Steht in Word, Excel oder PowerPoint länger „Wird gespeichert…“, zeigt die Menüleiste neben dem Symbol, wie schnell gerade hochgeladen wird (z. B. „↑ 2,4 MB/s“). Im Menü steht je Dokument, wie lange es schon speichert und wie viel bisher hochgeladen wurde. Kommt zwei Minuten lang nichts mehr an, steht dort „steht“ – dann hängt das Speichern vermutlich. Einen Prozentwert gibt es bewusst nicht: Office lädt nur die geänderten Teile hoch, wie viel das insgesamt ist, verrät es nicht.
- **Hinweis nach dem Zuklappen.** War eine Präsentation beim Zuklappen noch nicht fertig hochgeladen, erinnert die App nach dem Aufwachen daran, erst „Gespeichert“ abzuwarten, bevor sie auf dem iPad geöffnet wird. Sonst entstehen zwei Stände – und daraus die Kopien „… 2.pptx“ und „…-MacBook Pro von …“.
- **Vorsichtigeres automatisches Neuöffnen.** Lokal geöffnete Dokumente (z. B. über „Zuletzt verwendet“) werden nur noch direkt nach dem Öffnen mit AutoSpeichern neu geöffnet – nie mehr, wenn schon gespeichert wurde. So kann nie eine ältere Online-Fassung geladen werden. Der Speicher-Wächter arbeitet jetzt unabhängig von diesem Schalter.
- Ferndiagnose: Auf Anfrage lässt sich ermitteln, woraus eine große Präsentation besteht (Bilder, Videos, Schriften), um sie gezielt zu verkleinern.

## Neu in 1.9.4

- **Speicher-Wächter und Office-Integration sehen Word-Dokumente wieder.** Die Abfrage, welche Dokumente in Word offen sind, scheiterte mit einer aktuellen Word-Version an einer Eigenheit von Word. Der Speicher-Wächter („Office speichert nicht – Kopie speichern“) bekam deshalb keine Word-Dokumente zu sehen, und lokal geöffnete Word-Dateien wurden nicht automatisch mit AutoSpeichern neu geöffnet. Die Abfrage holt die Dokumente jetzt auf einem anderen Weg. Scheitert sie trotzdem, steht der Grund im Protokoll.
- Ferndiagnose: zusätzlich lesender Zugriff auf einzelne Tabellen der OneDrive-Datenbank, etwa um zu sehen, wann Microsoft das Hochladen gebremst hat.

## Neu in 1.9.3

- **Genauere Ferndiagnose beim Hochladen.** macOS meldet eine Datei in OneDrive schon nach etwa einer Sekunde als „hochgeladen“ – auch wenn sie noch gar nicht bei Microsoft angekommen sein kann. Die Ferndiagnose kann jetzt zusätzlich den Stand aus der Datenbank der OneDrive-App selbst lesen, um herauszufinden, woran sich der echte Upload erkennen lässt. Weiterhin nur lesend, nur im OneDrive-Ordner und nur auf ausdrückliche Anfrage.

## Neu in 1.9.2

- **Ferndiagnose auf Anfrage.** Auf ausdrückliche Anfrage des Entwicklers (über die Fehlerberichte, wie der bestehende Diagnosebericht) kann die App gezielte Prüfungen zum Sync-Zustand von Dateien im OneDrive-Ordner ausführen und das Ergebnis zurückmelden – um Fälle einzugrenzen, in denen Änderungen nicht hochgeladen werden. Es werden nur fest eingebaute, lesende Prüfungen innerhalb des OneDrive-Ordners ausgeführt; es gibt keine Ausführung beliebiger Befehle. Das lässt sich wie die Fehlerberichte unter Einstellungen → Fehlerbehebung abschalten.

## Neu in 1.9.1

- **Keine Dauer-Meldung „Störung bei Microsoft“ mehr.** Standen zwei Dokumente lange auf „Upload ausstehend“ – etwa große Präsentationen, die OneDrive noch hochlädt –, meldete die App eine Störung und öffnete alles ohne AutoSpeichern. Auch **Wieder online versuchen** half nicht: Die Meldung kam sofort zurück. Jetzt zählen dafür nur noch Dokumente, die gerade eben noch normal gespeichert haben, und jedes Dokument höchstens einmal.
- **Hinweise zum Speichern als Mitteilung statt als Fenster.** „… speichert noch“, „Alles gespeichert“ und „… wurde geschlossen, während noch gespeichert wurde“ kommen jetzt als macOS-Mitteilung: Sie verschwinden von selbst und stehen in der Mitteilungszentrale. Das Fenster oben rechts blieb bisher stehen, solange ein Dokument speicherte. macOS fragt einmal, ob OneDrive Opener Mitteilungen senden darf – bitte erlauben. Ohne Erlaubnis erscheint weiter das kleine Fenster, schließt sich aber nach 15 Sekunden selbst.

## Neu in 1.9.0

- **Störung bei Microsoft? Die App öffnet vorübergehend lokal.** Öffnet Word ein Dokument online nicht oder hängen mehrere Dokumente minutenlang bei „Wird gespeichert…“ bzw. „Upload ausstehend“, öffnet die App Dateien für 30 Minuten ohne AutoSpeichern – OneDrive lädt die Änderungen wie gewohnt hoch. Danach versucht sie es von selbst wieder online. Die Menüleiste zeigt „Störung bei Microsoft“ mit dem Knopf **Wieder online versuchen**. Pausieren ist dafür nicht mehr nötig.
- **Neu im Menü: „Vorübergehend lokal öffnen (1 Std.)“** – für den Fall, dass du eine Störung schon bemerkst, bevor die App sie erkennt. Endet von selbst.
- **Öffnen dauert ungewöhnlich lange?** Nach 15 Sekunden erscheint ein Fenster mit **Lokal öffnen** und **Abbrechen** – jetzt auch für PowerPoint und Excel. Auch die Fenster „Word wird gestartet …“ und „OneDrive lädt … noch hoch“ haben jetzt Knöpfe zum Abbrechen bzw. zum Öffnen ohne AutoSpeichern.

## Neu in 1.8.0

- **Dokumente mit Komma im Namen** (z. B. „Vokabeln, Teil 2.docx“) öffnen jetzt mit AutoSpeichern. Word hatte die Adresse bisher nicht angenommen, und die Datei ging nur lokal auf.
- **Öffnet Word ein Dokument nicht, reagiert die App nach spätestens einer Minute** und öffnet die Datei lokal – auch wenn Word hängt. Bisher konnte das bis zu einer Viertelstunde dauern.
- **Langsames Speichern mit Grund:** Lädt die OneDrive-App gerade große Datenmengen hoch oder herunter (z. B. Videos), sagt der Hinweis das jetzt – etwa „OneDrive lädt gerade ~800 MB hoch – das Speichern dauert deshalb länger.“

## Neu in 1.7.1

- **Kein Fehlalarm „Dokument wurde geschlossen“ mehr:** War PowerPoint oder Word gerade beschäftigt – etwa beim Hochladen einer großen Datei oder direkt nach dem Aufwachen des Macs –, meldete die App manchmal, das Dokument sei während des Speicherns geschlossen worden, obwohl es offen war. Jetzt misst sie in diesem Fall einfach weiter.

## Neu in 1.7.0

- **Speicher-Wächter:** Zeigt Word, Excel oder PowerPoint bei einem Dokument in OneDrive 10 Minuten lang nicht „Gespeichert“ an, meldet einen Speicherfehler oder speichert seit 15 Minuten, warnt die App deutlich: Die Änderungen kommen dann womöglich nicht in OneDrive an und können beim Beenden verloren gehen. Die Warnung erklärt, was zu tun ist – **Datei → Kopie speichern … auf den Schreibtisch, Office nicht „Sofort beenden“** – und wechselt auf Knopfdruck zur Office-App. Der Vorfall wird automatisch an den Entwickler gemeldet.
- **Freigabe „Bedienungshilfen“ nach Updates:** Der Schalter in den Systemeinstellungen kann nach einem Update auf „an“ stehen, ohne zu wirken (er gehört noch zur alten Version). Die App erklärt jetzt die Schritte – Eintrag mit „–“ entfernen, mit „+“ wieder hinzufügen – und erinnert einmal, wenn die Freigabe 5 Minuten nach der Anfrage noch nicht aktiv ist.

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
