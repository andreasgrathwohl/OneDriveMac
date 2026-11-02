# Review – OneDrive Opener, 15 s

## Entscheidungen
- Storyline „Vorher → Nachher“ (gewählt). Nicht gebaut: „Der Schalter“ (nur Nahaufnahme), „Unter der Haube“ (Pfad → Web-Adresse).
- Alle Oberflächen sind nachgebaut, nicht abgefilmt: Menütexte und Statussymbol aus `Sources/StatusController.swift` / `UserStatus.swift`,
  Titelleistentext „Auf meinem Mac gespeichert“ aus dem README, App-Icon 1:1 aus `Tools/MakeIcon.swift` übertragen.
  Die Titelleiste im „Nachher“ zeigt bewusst nur „Angebot“ – was Word dort genau anzeigt, ist nicht belegt.
- Inter statt SF Pro (SF Pro ist nicht gebündelt/lizenziert).
- Stumm: keine Musikquelle eingerichtet; 15 s liegt an der Grenze, ab der Ton Pflicht wäre.

## Gemessen / angesehen
- `check`: 0 Fehler. Behalten: `line_unread` auf „OneDrive Opener“ – Fehlalarm, der Check zählt die 14 Buchstaben-Spans als Wörter;
  der Name steht ab 6,0 s ganz und hält 1,3 s.
- Angesehen: QA-Frames aus SPEC.md, Review-Sheets (Beats, 3 Nähte, Telefonbreite).
- Nicht geprüft: Wirkung auf echtem Mac-Bildschirm neben der echten App; Ton (keiner vorhanden).

## Schwächste Stelle
- Szene 2: Bei Telefonbreite ist der Menü-Untertitel nur knapp lesbar. Mit mehr Zeit: Menü 1,3× größer und die Kopfzeile näher heranholen.
- Szene 1 → 2: Die Naht ist ein Blur-Abgang plus Farbflut – funktioniert, ist aber die schwächste der drei Übergänge.
