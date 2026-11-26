# Upload-Anzeige, Hinweis nach dem Aufwachen, Neuöffnen nur direkt nach dem Öffnen – Design (1.9.5)

Stand: 2026-11-26 · Entscheidungen von Andreas im Gespräch

## Befund

- Präsentationen mit Kopien („… 2.pptx“, „…-MacBook Pro von <Name>.pptx“) waren in allen gefundenen Fällen
  am Mac offen, als er mit noch nicht hochgeladenen Änderungen einschlief (Berichte 31.10.–20.11.2026).
  Danach entstehen auf iPad und Mac zwei Stände, die Office nicht zusammenführen kann.
- macOS meldet eine Datei in OneDrive nach ~1 s als „hochgeladen“ (`synctest`) – kein verlässliches Signal.
- „Wird gespeichert…“ sagt nicht, ob etwas passiert: Bei fast allen langsamen Speichervorgängen sendete
  PowerPoint in 10–15 Minuten unter 0,5 MB.
- Seit 1.9.4 kann die Office-Integration Dokumente abfragen; ihr automatisches Neuöffnen war damit erstmals
  aktiv – und hätte bei einer lokal gespeicherten, noch nicht hochgeladenen Datei die ältere Online-Fassung
  geladen.

## Entscheidungen

| Entscheidung | Grund | Verworfen (mit Vorzug) |
|---|---|---|
| Upload-Anzeige in der **Menüleiste**: Tempo neben dem Symbol, je Dokument Dauer, je App gesendete Menge, „steht“ nach 120 s ohne Senden | Kein Fenster, das stehen bleibt; jederzeit sichtbar | Kleines Fenster mit laufenden Werten – fällt mehr auf |
| **Kein Prozentwert** | Office lädt nur geänderte Teile hoch, die Gesamtmenge ist unbekannt; ein Balken „46 von 120 MB“ wäre meist falsch | – |
| Messung je App (`nettop`), erst ab 10 s Speichern, alle 5 s | Die meisten Speichervorgänge sind vorher fertig; kaum Last | – |
| **Variante A:** automatisch neu öffnen nur in den ersten 60 s nach dem ersten Sehen und nur, wenn die Datei seither nicht gespeichert wurde; beim ersten Erfassen nach dem Start Offenes nie | Behält den Nutzen („Zuletzt verwendet“ → sofort AutoSpeichern) und schließt den Konfliktfall | B: ganz aus – keine Überraschungen; C: so lassen – voller Nutzen |
| Beobachten der offenen Dokumente vom Schalter getrennt | Der Speicher-Wächter braucht die Liste auch bei ausgeschaltetem Neuöffnen | – |
| Hinweis nach dem Aufwachen (ab 2 Min. Schlaf), wenn beim Einschlafen noch gespeichert wurde | Der Moment, in dem der Konflikt entsteht, ist bekannt | Einschlafen verhindern – Zuklappen lässt sich nicht verhindern |
| Kein eigenes Speichern/Add-in statt AutoSpeichern | Nur das gemeinsame Bearbeiten von Office führt Änderungen von Mac und iPad zusammen; eigenes Hochladen ganzer Dateien würde Konflikte vermehren | Lokaler Modus mit bestätigtem Upload – verlässlich für Dateien, die nur am Mac bearbeitet werden |
| Ferndiagnose `pptx-analyse` (nur lesend) | Erst messen, woraus 120 MB bestehen, dann entscheiden (PowerPoint „Datei → Dateigröße reduzieren“ oder eigene Verkleinerung) | Add-in zur Verkleinerung – Add-ins können keine Bilder/Videos neu komprimieren |
