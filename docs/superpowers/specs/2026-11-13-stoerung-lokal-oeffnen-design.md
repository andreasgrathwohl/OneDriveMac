# Störungsbetrieb und bedienbare Wartefenster – Design

Stand: 2026-11-13 · freigegeben

## Anlass und Ziel

Am 2026-11-13 hatte Microsoft eine Störung: Office lud nichts hoch („Upload ausstehend“, Speichern über
10 Minuten), Word öffnete Dokumente online nicht. Der OneDrive-Client synchronisierte dagegen normal. Die
Anwenderin half sich, indem sie OneDrive Opener pausierte – dann öffnet der Finder lokal, und das
funktionierte. Pausieren hat aber zwei Nachteile: Man muss die Störung selbst bemerken, und man muss danach
ans Fortsetzen denken, sonst bleibt AutoSpeichern dauerhaft aus.

Ziel: Bei einer Störung soll die App von sich aus lokal öffnen und danach von selbst wieder online. Und wer
in einem langen Öffnen festhängt, soll in unseren Fenstern abbrechen oder lokal öffnen können.

## Ziele

1. **Störungsbetrieb:** erkennt eine Störung an Zeichen, die die App ohnehin sieht, öffnet für eine
   begrenzte Zeit lokal und kehrt selbst zurück.
2. **Manueller Schalter:** „Vorübergehend lokal öffnen (1 Std.)“ im Menü.
3. **Neues Fenster** „öffnet ungewöhnlich lange“ mit „Lokal öffnen“ / „Abbrechen“.
4. **Vorhandene Wartefenster** bekommen echte Knöpfe.

## Nicht-Ziele

- Kein aktives Abfragen von Microsoft-Servern oder der Statusseite (unzuverlässig: Server antworten bei
  solchen Störungen normal; kostet Zeit bei jedem Öffnen).
- Das eigene „Wird geöffnet“-Fenster von Word wird nicht angefasst.

## Anti-Ziele

- Der Störungsbetrieb darf nicht dauerhaft hängen bleiben – sonst ist AutoSpeichern still aus, genau das
  Problem des Pausierens.
- Eine einzelne große, langsam speichernde Datei darf ihn nicht auslösen.

## Ansätze

| | Ansatz | Abwägung |
|---|---|---|
| **A (gewählt)** | Aus eigenen Beobachtungen lernen (Öffnen schlägt fehl, mehrere Uploads hängen) | Verlässlich, kein Netzaufwand; das erste Dokument einer Störung trifft es noch (gemildert durch das neue Fenster) |
| B | Microsoft aktiv anfragen | Unzuverlässig, langsam – verworfen |
| C (zusätzlich) | Nur Menüschalter | Einfach, aber die Anwenderin muss die Störung selbst bemerken – als Ergänzung zu A übernommen |

## Entwurf

### 1. Störungsbetrieb (`Outage`)

- **Auslöser** (jeder startet bzw. verlängert auf 30 Minuten ab jetzt):
  - Ein online übergebenes Dokument ist nach 60 s nicht offen (Word, PowerPoint, Excel).
  - Im Fenster „öffnet ungewöhnlich lange“ wird „Lokal öffnen“ gewählt.
  - Mindestens 2 Dokumente zeigen gleichzeitig seit mindestens 3 Minuten „Wird gespeichert…“ oder
    „Upload ausstehend“, während der Mac online und wach ist (Messung von `SaveMonitor`).
- **Manuell:** Menüpunkt „Vorübergehend lokal öffnen (1 Std.)“ – 60 Minuten.
- **Wirkung:** `FileOpener` öffnet sofort lokal (mit Protokollzeile). Die Menüleiste zeigt den Zustand
  „Störung bei Microsoft – Dateien öffnen lokal“ (manuell: „Vorübergehend lokal“) mit Aktion „Wieder
  online versuchen“.
- **Office-Integration ruht:** `OfficeIntegration` öffnet lokal offene OneDrive-Dokumente sonst automatisch
  mit AutoSpeichern neu – das würde das lokale Öffnen sofort zunichtemachen. Während des Störungsbetriebs
  läuft dieses Neuöffnen nicht (die Umfrage für `SaveGuard` läuft weiter). Nach dem Ende greift es wieder
  für Dokumente, die nicht als „bleibt lokal“ markiert sind – dafür werden im Störungsbetrieb geöffnete
  Dateien wie heute per `keepLocal` markiert.
- **Ende:** Ablauf der Zeit oder „Wieder online versuchen“. Danach normal online.
- **Bericht:** `outage` bei Beginn (Auslöser) und Ende (Grund, Dauer).
- Der Zustand überlebt keinen Neustart der App (bewusst: Neustart = sauberer Neuversuch).

### 2. Fenster „öffnet ungewöhnlich lange“

- Nach der Übergabe an Office prüft die App alle 2 s, ob das Dokument offen ist (heute nur Word, künftig
  auch PowerPoint und Excel per AppleScript-Namensliste).
- Nach 15 s ohne offenes Dokument: Fenster „„X“ öffnet ungewöhnlich lange …“ mit **Lokal öffnen** und
  **Abbrechen**.
- **Lokal öffnen:** Kontrolle beenden, lokal öffnen, Störungsbetrieb auslösen.
- **Abbrechen:** Kontrolle beenden, nichts öffnen. (Office kann das Dokument danach noch selbst öffnen.)
- Ohne Klick: wie heute nach 60 s Fehler melden und lokal öffnen – jetzt auch für PowerPoint/Excel – und
  Störungsbetrieb auslösen.
- Erneute Übergabe nach 20 s bleibt auf Word beschränkt (nur Word verwirft die erste Adresse manchmal).
- Geht das Dokument auf, schließt sich das Fenster von selbst.

### 3. Vorhandene Wartefenster

- „Word wird gestartet …“: **Abbrechen** (bricht das Öffnen ab).
- „OneDrive lädt „X“ noch hoch …“: **Ohne AutoSpeichern öffnen** und **Abbrechen**.

## Entscheidungen und Gründe

| Entscheidung | Grund |
|---|---|
| Ansatz A + Menüschalter aus C | A erkennt ohne Zutun; der Schalter hilft, bevor A anschlägt. B verworfen (s. o.) |
| 30 Min. automatisch, 60 Min. manuell, verlängert bei neuem Zeichen | Kurz genug, damit AutoSpeichern bald zurückkommt; manuell bewusst länger |
| Saveschwelle: ≥ 2 Dokumente gleichzeitig ≥ 3 Min. | Eine einzelne große Datei (z. B. 110-MB-PowerPoint) speichert legitim lange |
| Fenster nach 15 s, Fallback weiter nach 60 s | 15 s liegt über normalem Öffnen; 60 s ist die bestehende Grenze in `verifyOpened` |
| Erneute Übergabe nur bei Word | Nur für Word belegt; bei PowerPoint/Excel könnte sie ein Dokument doppelt öffnen |
| Zustand nicht über Neustart gespeichert | Neustart = sauberer Neuversuch, kein vergessener Dauer-Lokalbetrieb (Anwender-Wunsch: nicht wie Pausieren hängen bleiben) |
| Eigenes Word-Fenster nicht anfassen | Vom Anwender so gewählt; unsere App kann dessen Knopf nicht reparieren |

## Code-Anker (Basis `98b985f` = v1.8.0, Branch `feature/outage-local-open`)

Vorhanden:
- `Sources/FileOpener.swift`
  - `FileOpener.open(_:forceLocal:)` – Entscheidung lokal/online; hier greift der Störungsbetrieb (nach der
    Prüfung `!Settings.enabled`, vor `PathResolver.resolve`).
  - `FileOpener.launchCloud(_:app:fallback:)` – Übergabe; setzt `wordBusyUntil`/`wordBusyToken` und startet
    `verifyOpened` heute nur für `.word`.
  - `FileOpener.verifyOpened(_:webURL:token:)` – Kontrolle nach Uhrzeit bis `verifyGiveUpAfter` (60 s),
    erneute Übergabe nach `verifyRetryAfter` (20 s), danach `Log.error` + `openLocally`. Liest Namen über
    `documentNamesScript(_ app: OfficeApp)` (Word, PowerPoint, Excel; ersetzt `wordDocumentNamesScript`). Konstanten `verifyRetryAfter`, `verifyGiveUpAfter`,
    `wordBusyMargin` direkt darüber.
  - `FileOpener.ensureRunning(_:)` – zeigt `waitingPanel.show("… wird gestartet …")`.
  - Warten auf Upload in `open`: `waitingPanel.show("OneDrive lädt … noch hoch …")` +
    `SyncStatus.waitForUpload(file, timeout:)` (`Sources/SyncStatus.swift`).
  - `final class WaitingPanel` (Ende von `FileOpener.swift`) – `NSPanel` mit Drehrad + Text, keine Knöpfe.
  - `FileOpener.openLocally(_:_:)` – ruft bereits `OfficeIntegration.shared.keepLocal(file)`.
- `Sources/OfficeIntegration.swift` – `tick()` (Neuöffnen mit AutoSpeichern, Guard-Zeile mit
  `Settings.enabled`); `collection(_:)` liefert `documents`/`workbooks`/`presentations`.
- `Sources/SaveMonitor.swift` – `Episode` (Felder `start`, `asleep`, `offline`), `episodes`,
  `duration(_:until:)`, `process(_:at:elapsed:)`; `Connectivity.shared.isOnline`; `sleepingSince`.
- `Sources/UserStatus.swift` – `enum Kind` und die Switches `title`, `subtitle`, `actionTitle`, `symbol`,
  `color`, `performAction`; `kind` priorisiert `.paused` vor `.offline`.
- `Sources/StatusController.swift` – `menuNeedsUpdate(_:)` (Menüpunkt „Pausieren“/„Fortsetzen“ über
  `toggleEnabled`).
- `Sources/Reporter.swift` – `Reporter.shared.send(kind:message:details:)`.
- `AppState.changed()` in `Sources/HandlerGuard.swift` – löst Aktualisierung von Menü/Einstellungen aus.

Neu:
- `Sources/Outage.swift` – `@MainActor final class Outage` (Singleton): `isActive`, `until`, `manual`,
  `trigger(reason:)`, `startManual()`, `end(reason:)`, Ablauf per Timer, Berichte `outage`.
- `UserStatus.Kind.outage` (Rang direkt nach `.paused`/`.offline`), Aktion „Wieder online versuchen“.
- Menüpunkt „Vorübergehend lokal öffnen (1 Std.)“ in `StatusController.menuNeedsUpdate` (nur sichtbar,
  wenn aktiviert und nicht schon im Störungsbetrieb).
- `WaitingPanel` mit optionalen Knöpfen (Rückgabe per Closure) – oder ein zweites Panel für „öffnet
  ungewöhnlich lange“.
- Kontrolle „ist offen?“ für alle drei Apps (AppleScript mit `collection(app)`).
- In `SaveMonitor`: Prüfung der Saveschwelle, ruft `Outage.shared.trigger`.

Hinweis zu „Abbrechen“ beim Öffnen: Bricht der Anwender ab, muss die Word-Sperre (`wordBusyUntil`) sofort
frei werden, sonst warten weitere Dokumente bis zu 70 s.

## Dem Umsetzer überlassen

- Aufteilung in Typen/Dateien, Gestaltung des Fensters im Stil des vorhandenen `WaitingPanel`.
- Wortlaut von Protokoll und Berichtsfeldern.
- Wie die Kontrolle für PowerPoint/Excel die Dokumentnamen liest (AppleScript: `presentations` bzw.
  `workbooks`).

## Rahmenbedingungen

- Entwicklung unter Windows ohne Swift-Compiler; gebaut und getestet wird nur per GitHub Actions
  (kostet Geld – nur bei Tag oder manuell) bzw. auf dem Mac der Anwenderin.
- Swift 5 (`-swift-version 5`), AppKit, keine Abhängigkeiten.
