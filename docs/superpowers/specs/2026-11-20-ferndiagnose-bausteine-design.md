# Ferndiagnose über benannte Bausteine – Design

Stand: 2026-11-20

## Anlass und Ziel

Dateien, die OneDrive noch nicht hochgeladen hat, zeigen auf dem Tablet nicht den aktuellen Stand.
Zum Eingrenzen muss derzeit jemand am Mac Terminalbefehle ausführen. Ziel: Diagnosen aus der Ferne
über den vorhandenen Berichts-Server auslösen – **ohne** freie Befehlsausführung und so, dass
künftige Fragen **keine** neue App-Version brauchen.

## Grundsatz

Die App bekommt keine fertigen Einzelprüfungen, sondern eine feste, kleine Menge **lesender
Bausteine**, die auf den OneDrive-Ordner beschränkt sind. Eine künftige Diagnosefrage wird vom
Auslöser (hier: `Tools/reports.py`) aus **zusammengesetzt** – anderer Pfad, andere Kombination –,
nicht durch neuen App-Code. Frei ist nur der Pfad, nie die Operation.

## Ziele

1. Fünf Bausteine, vier lesend, einer mit einer eng begrenzten Schreibaktion.
2. Jeder Pfad wird gegen die erkannten OneDrive-Ordner geprüft; außerhalb → Ablehnung.
3. Ergebnis als Bericht `diag_result` in der Datenbank, mit der Anfrage-ID verknüpft.
4. Auslösen und Abholen über `Tools/reports.py`.

## Nicht-Ziele

- Keine Ausführung beliebiger Befehls- oder Skripttexte. Die Operationen sind fest einprogrammiert.
- Kein Zugriff außerhalb der OneDrive-Ordner.
- Keine Schreibaktion außer der selbst angelegten und wieder gelöschten Testdatei (`synctest`).
- Kein sudo, keine Rechteausweitung.

## Anti-Ziele

- Ein Kanal, über den Schreibzugriff auf die `requests`-Tabelle zu Dateizugriff auf einem fremden
  Gerät wird. Gegenmittel: feste Operationen, Pfadgrenze, nur eigene `install_id`, Protokollpflicht.

## Die Bausteine

| Baustein | Art | Parameter | Liefert |
|---|---|---|---|
| `inspect` | lesend | Pfad (Datei) | Rohwerte: `isUbiquitous`, `isUploaded`, `isUploading`, `hasConflicts`, Größe, Änderungsdatum, abgeleiteter Sync-Status, aufgelöste Online-Adresse |
| `list` | lesend | Pfad (Ordner) | je Eintrag Name + dieselben Sync-Flags; findet Konfliktkopien und nicht hochgeladene Dateien |
| `recent` | lesend | – | zuletzt geöffnete Dateien (`AppState.recent`): Name, online/lokal, Zeitpunkt |
| `office-docs` | lesend | – | aktuell offene Office-Dokumente mit Speicher-/Sync-Stand (aus `OfficeIntegration`) |
| `synctest` | Schreibaktion | optional Ordner | legt eine ~10-MB-Testdatei im OneDrive-Ordner an, beobachtet 60 s den Upload (jede Sekunde die Rohwerte), löscht sie wieder |

## Pfad-Sicherheit

- Eingabe ist ein Pfad (absolut oder relativ zu einem Ordner). Die App löst Symlinks auf,
  normalisiert (`PathResolver.normalize`) und verlangt, dass er innerhalb eines `allRoots()`-Ordners
  liegt (gleiche Präfixprüfung wie `PathResolver.resolve`). Sonst: Ergebnis „abgelehnt: außerhalb des
  OneDrive-Ordners“, keine Ausführung.
- `synctest` schreibt nur in einen erkannten Ordner, mit festem Namenspräfix `ODO-synctest-<zeit>`.

## Übertragungsweg

- Die `requests`-Tabelle bekommt ein Textfeld `arg` (einmaliger Schritt im PocketBase-Admin, im
  Heimnetz). `kind` trägt den Baustein-Namen, `arg` den Pfad, `install_id` das Zielgerät.
- `Reporter.pollRequests` liest die bekannten Bausteine, prüft, führt aus, sendet `diag_result` mit
  `request_id`, `command`, `arg` und dem Ergebnis.
- **Nur mit `install_id` des Zielgeräts** ausführen; eine Anfrage an „alle“ wird für Bausteine
  ignoriert (anders als `diagnostics`/`update`), damit nicht versehentlich fremde Geräte eine
  Testdatei anlegen.
- Jede Ausführung schreibt eine Protokollzeile „Ferndiagnose: <Baustein> <arg> – <Ergebnis kurz>“.

## Erweiterbarkeit – die eigentliche Anforderung

Eine neue Frage in Zukunft (z. B. „ist Datei X hochgeladen, und gibt es im Ordner Konfliktkopien?“)
ist `inspect X` plus `list <Ordner>` – **kein** neuer App-Code. Nur eine Frage, die eine
grundsätzlich neue Fähigkeit braucht (etwa die interne Sync-Datenbank von OneDrive lesen), wäre ein
neuer Baustein und damit eine neue Version. Das ist selten; die fünf Bausteine decken den
Datei-/Sync-Bereich ab, in dem praktisch alle Diagnosen liegen.

## Dem Umsetzer überlassen

- Genaues Ausgabeformat je Baustein (lesbare Schlüssel im `payload`).
- Größe und Inhalt der `synctest`-Datei (Zufallsbytes, ~10 MB, inkompressibel, damit der Upload Zeit
  braucht).
- Wortlaut von Protokoll und Ablehnungsgründen.

## Rahmenbedingungen

- Kein Swift-Compiler unter Windows; Bau nur per CI (macOS) oder auf dem Mac. CI kostet je Lauf Geld.
- Keine echten Personen-, Klassen- oder Dateinamen in Code, Tests oder dieser Doku (Datenhygiene) –
  nur Platzhalter. Reale Namen tauchen nur zur Laufzeit in der Datenbank auf, dem dafür vorgesehenen
  Kanal.
- Swift 5, AppKit, keine Abhängigkeiten.
