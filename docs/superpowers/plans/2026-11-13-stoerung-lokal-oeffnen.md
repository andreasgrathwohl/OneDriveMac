# Störungsbetrieb und bedienbare Wartefenster – Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bei einer Microsoft-Störung öffnet OneDrive Opener befristet lokal und kehrt selbst zurück; lange
Wartezeiten beim Öffnen lassen sich in unseren Fenstern abbrechen oder lokal öffnen.

**Architecture:** Neue Klasse `Outage` (Zustand + Ablauf) mit einem reinen, zeitinjizierbaren Kern
`OutagePolicy`, der per neuem CLI-Selbsttest (`--selftest`) in CI geprüft wird. `FileOpener` fragt `Outage`
vor dem Online-Öffnen, `WaitingPanel` bekommt Knöpfe, deren Wahl die vorhandenen Warteschleifen abfragen
(Polling, wie der Code es schon tut). `SaveMonitor` und `FileOpener` melden Störungszeichen an `Outage`.

**Tech Stack:** Swift 5 (`-swift-version 5`), AppKit, keine Abhängigkeiten. Bauen nur auf macOS (CI).

**Spec:** `docs/superpowers/specs/2026-11-13-stoerung-lokal-oeffnen-design.md` (Code-Anker dort).

## Global Constraints

- Kein Swift-Compiler unter Windows: Jeder Task endet mit sorgfältiger Durchsicht des Diffs; gebaut und
  getestet wird gesammelt am Ende per manuellem CI-Lauf (`gh workflow run Build --ref feature/outage-local-open`)
  – CI kostet Geld, also nicht pro Task.
- Automatischer Störungsbetrieb: 30 Min.; manuell: 60 Min.; jedes neue Zeichen verlängert auf „jetzt + Dauer“
  (nie verkürzen).
- Saveschwelle: ≥ 2 Episoden gleichzeitig, jede mit `duration ≥ 180 s`, online, nicht im Ruhezustand.
- Fenster „öffnet ungewöhnlich lange“ ab 15 s; Aufgeben weiterhin nach `verifyGiveUpAfter` (60 s).
- Erneute Übergabe nach 20 s nur bei Word.
- Zustand nicht über Neustart speichern.
- Texte (Anwender sieht sie, Deutsch, wörtlich):
  - Status-Titel automatisch: „Störung bei Microsoft“; manuell: „Vorübergehend lokal“
  - Untertitel: „Dateien öffnen bis HH:mm ohne AutoSpeichern.“
  - Aktion: „Wieder online versuchen“
  - Menüpunkt: „Vorübergehend lokal öffnen (1 Std.)“
  - Fenster: „„<Dateiname>“ öffnet ungewöhnlich lange …“, Knöpfe „Lokal öffnen“, „Abbrechen“
  - Upload-Fenster-Knöpfe: „Ohne AutoSpeichern öffnen“, „Abbrechen“; Start-Fenster-Knopf: „Abbrechen“
- Bericht-Art `outage`, Meldungen „Störungsbetrieb an“ / „Störungsbetrieb aus“.

## Review Focus

1. **Störungsbetrieb endet nie** (Timer verloren nach Ruhezustand): Ablauf muss auch per Abfrage greifen –
   `isActive` vergleicht `until` mit jetzt, der Timer ist nur für die Anzeige. Test in Task 1.
2. **Abbrechen bei wartendem Word-Dokument**: Word-Sperre (`wordBusyUntil`) muss sofort frei werden, sonst
   hängen weitere Dokumente bis 70 s. Test-/Durchsicht in Task 4.
3. **Office-Integration macht lokales Öffnen rückgängig**: im Störungsbetrieb darf `OfficeIntegration.tick`
   nichts neu öffnen. Durchsicht in Task 5.
4. **Eine große Datei allein** löst keinen Störungsbetrieb aus (nur 1 Episode ≥ 180 s). Test in Task 1.
5. **Ruhezustand zählt nicht**: Episoden-Dauer ohne Schlafzeit (`duration(_:until:)` zieht `asleep` ab);
   Schwelle nur bei `sleepingSince == nil` und online prüfen. Test in Task 1.

---

### Task 1: Selbsttest-Gerüst und `Outage`-Kern

**Files:**
- Create: `Sources/Outage.swift`
- Create: `Sources/SelfTest.swift`
- Modify: `Sources/CLI.swift` (`CLI.run()`: neuer Zweig `--selftest`)
- Modify: `.github/workflows/build.yml` (Schritt „Selbsttest“: zusätzlich `--selftest`)

**Interfaces:**
- Produces:
  - `struct OutagePolicy { var until: Date?; var manual: Bool }` mit
    `func isActive(now: Date) -> Bool`,
    `mutating func trigger(now: Date, manual: Bool) -> Bool` (true = neu begonnen; setzt
    `until = max(until, now + (manual ? 3600 : 1800))`, `manual` bleibt true, wenn schon manuell),
    `mutating func end()`.
  - `static func OutagePolicy.savesSignal(durations: [TimeInterval]) -> Bool` – true, wenn ≥ 2 Werte ≥ 180.
  - `@MainActor final class Outage { static let shared; var isActive: Bool; var until: Date?; var manual: Bool;
    func trigger(reason: String); func startManual(); func end(reason: String) }` – ruft `OutagePolicy`,
    protokolliert (`Log.info`), sendet `Reporter.shared.send(kind: "outage", …)` mit `reason`/`duration_min`,
    ruft `AppState.changed()`, plant einen `Timer` zum Ablaufzeitpunkt, der `end(reason: "abgelaufen")` aufruft.
    `isActive` endet zusätzlich selbst, wenn `until` überschritten ist (sendet dann einmal „aus“).
  - `enum SelfTest { static func run() -> Int32 }` – Anzahl Fehlschläge, druckt je Prüfung `ok`/`FEHLER`.

- [ ] **Step 1: Selbsttests schreiben** in `SelfTest.swift` (`check(_ name: String, _ condition: Bool)`):
  - `inaktivOhneAusloeser`: `OutagePolicy().isActive(now: t0) == false`
  - `automatisch30Min`: nach `trigger(now: t0, manual: false)` → aktiv bei `t0+1799`, inaktiv bei `t0+1800`
  - `manuell60Min`: `trigger(now: t0, manual: true)` → aktiv bei `t0+3599`
  - `verlaengert`: trigger t0, trigger t0+1000 → aktiv bei `t0+2700`
  - `verkuerztNie`: manuell bei t0, automatisch bei t0+60 → aktiv bei `t0+3500`, `manual == true`
  - `neuBegonnen`: erstes `trigger` liefert true, zweites (während aktiv) false, nach Ablauf wieder true
  - `ende`: nach `end()` inaktiv
  - `eineGrosseDatei`: `savesSignal(durations: [900]) == false`
  - `zweiHaengend`: `savesSignal(durations: [180, 200]) == true`
  - `zweiKurz`: `savesSignal(durations: [179, 600]) == false`

- [ ] **Step 2: `--selftest` in `CLI.run()`** – `exit(SelfTest.run() == 0 ? 0 : 1)`; CI-Schritt ergänzt um
  `"build/OneDrive Opener.app/Contents/MacOS/OneDriveOpener" --selftest`. (Ohne `OutagePolicy` baut es noch
  nicht – Fehlschlag ist hier der Compiler; erst gemeinsam mit Step 3 lauffähig.)

- [ ] **Step 3: `OutagePolicy` und `Outage` implementieren** (Signaturen oben).

- [ ] **Step 4: Diff durchsehen** – jede Selbsttest-Erwartung gegen die Implementierung von Hand nachrechnen.

- [ ] **Step 5: Commit** – `git add Sources/Outage.swift Sources/SelfTest.swift Sources/CLI.swift .github/workflows/build.yml`;
  Nachricht „Outage mode core with self-test“.

### Task 2: Störungsbetrieb wirkt beim Öffnen und in der Menüleiste

**Files:**
- Modify: `Sources/FileOpener.swift` (`open(_:forceLocal:)`)
- Modify: `Sources/UserStatus.swift` (`Kind`, alle Switches, `kind`)
- Modify: `Sources/StatusController.swift` (`menuNeedsUpdate(_:)`, neue Aktion)

**Interfaces:**
- Consumes: `Outage.shared.isActive`, `.until`, `.manual`, `.startManual()`, `.end(reason:)`.
- Produces: `UserStatus.Kind.outage`.

- [ ] **Step 1: `open`** – direkt nach dem Block `forceLocal || !Settings.enabled …`: wenn
  `Outage.shared.isActive`, `Log.info("Störungsbetrieb – „<Name>“ wird lokal geöffnet")`, `openLocally`, return.
- [ ] **Step 2: `UserStatus`** – `.outage` in `kind` nach `.paused` und `.offline`, vor `.saveGuard`.
  Titel/Untertitel/Aktion laut Global Constraints (Uhrzeit aus `until`, `DateFormatter` „HH:mm“), Symbol
  `"exclamationmark.icloud"`, Farbe `.systemOrange`, `performAction` → `Outage.shared.end(reason: "vom Anwender")`.
- [ ] **Step 3: Menü** – nach „Pausieren/Fortsetzen“ Menüpunkt „Vorübergehend lokal öffnen (1 Std.)“, nur wenn
  `Settings.enabled && !Outage.shared.isActive`; Aktion `Outage.shared.startManual()`.
- [ ] **Step 4: Diff durchsehen** – jeder `switch kind` erschöpfend (Swift verlangt es; fehlender Fall = Build-Fehler).
- [ ] **Step 5: Commit** „Outage mode: open locally, menu bar status and manual switch“.

### Task 3: Wartefenster mit Knöpfen

**Files:**
- Modify: `Sources/FileOpener.swift` (`WaitingPanel`, `ensureRunning(_:)`, Upload-Warten in `open`)
- Modify: `Sources/SyncStatus.swift` (`waitForUpload`)

**Interfaces:**
- Produces:
  - `enum PanelButton { case local, cancel }`
  - `WaitingPanel.show(_ text: String, buttons: [PanelButton] = [], localTitle: String = "Lokal öffnen")` –
    setzt `choice = nil`, zeigt die Knöpfe unter dem Text (`.local` mit `localTitle`, `.cancel` = „Abbrechen“).
  - `private(set) var WaitingPanel.choice: PanelButton?` – gesetzt beim Klick, Panel schließt sich.
  - `SyncStatus.waitForUpload(_ file: URL, timeout: Int, stop: () -> Bool = { false }) async -> SyncState`
    – Schleife bricht ab, sobald `stop()` true ist.
  - `ensureRunning(_:) async -> Bool` – false, wenn abgebrochen; `launchCloud` gibt dann ohne Öffnen zurück.

- [ ] **Step 1: `WaitingPanel`** – Knöpfe hinzufügen; Panel-Höhe wächst mit Knöpfen; ohne Knöpfe aussehen wie heute.
- [ ] **Step 2: Upload-Warten in `open`** – `show("OneDrive lädt „X“ noch hoch …", buttons: [.local, .cancel],
  localTitle: "Ohne AutoSpeichern öffnen")`, `waitForUpload(…, stop: { waitingPanel.choice != nil })`;
  danach `.local` → `openLocally`, return; `.cancel` → `Log.info("Öffnen abgebrochen: …")`, return.
- [ ] **Step 3: `ensureRunning`** – `show("<App> wird gestartet …", buttons: [.cancel])`; Warteschleife bricht bei
  `choice == .cancel` ab und liefert false. In `launchCloud`: `guard await ensureRunning(app) else { Log.info(…); return }`
  (vor dem Setzen von `wordBusyUntil`).
- [ ] **Step 4: Diff durchsehen** – alle Aufrufer von `ensureRunning` (`grep ensureRunning Sources`) angepasst.
- [ ] **Step 5: Commit** „Waiting panels: cancel and open-locally buttons“.

### Task 4: Kontrolle für alle Apps und Fenster „öffnet ungewöhnlich lange“

**Files:**
- Modify: `Sources/FileOpener.swift` (`launchCloud`, `verifyOpened`, `wordDocumentNamesScript`)

**Interfaces:**
- Consumes: `WaitingPanel.show(_:buttons:localTitle:)`, `.choice`, `.hide()` (Task 3); `Outage.shared.trigger(reason:)`.
- Produces: `verifyOpened(_ file: URL, app: OfficeApp, webURL: String, token: UUID?) async`.

- [ ] **Step 1: Namensskript je App** – `documentNamesScript(_ app: OfficeApp) -> String` mit Bundle-ID und
  Sammlung `documents`/`workbooks`/`presentations` (gleiche Zuordnung wie `OfficeIntegration.collection`).
- [ ] **Step 2: `launchCloud`** – `verifyOpened` für jede App starten; `token` nur bei Word (Sperre).
- [ ] **Step 3: `verifyOpened`** – eigenes Panel-Objekt (`WaitingPanel()` lokal, damit ein zweites Dokument
  das Fenster des ersten nicht übernimmt). Ab 15 s ohne offenes Dokument einmal
  `show("„X“ öffnet ungewöhnlich lange …", buttons: [.local, .cancel])`. In jeder Runde:
  - Dokument offen → `hide()`, return.
  - `choice == .local` → Sperre freigeben, `openLocally`, `Outage.shared.trigger(reason: "Lokal öffnen gewählt")`, return.
  - `choice == .cancel` → Sperre freigeben, `Log.info("Öffnen abgebrochen: …")`, return.
  - Erneute Übergabe nach `verifyRetryAfter` nur wenn `app == .word`.
  - Fristablauf: `hide()`, `Log.error` wie heute (mit App-Name statt „Word“), `openLocally(file, app)`,
    `Outage.shared.trigger(reason: "<App> öffnet nicht")`.
  - „Sperre freigeben“ = `if wordBusyToken == token { wordBusyUntil = nil }` (vorhandenes `defer` deckt das ab –
    prüfen, dass jeder neue return davor liegt).
- [ ] **Step 4: Diff durchsehen** – bei Berechtigungsfehler (`permissionDenied`) Panel schließen, kein Störungsbetrieb.
- [ ] **Step 5: Commit** „Check that PowerPoint/Excel open too; slow-open panel with local/cancel“.

### Task 5: Störungszeichen aus `SaveMonitor`, Office-Integration ruht

**Files:**
- Modify: `Sources/SaveMonitor.swift` (`process(_:at:elapsed:)`, Ende der Funktion)
- Modify: `Sources/OfficeIntegration.swift` (`tick()`, Guard-Zeile)

**Interfaces:**
- Consumes: `OutagePolicy.savesSignal(durations:)`, `Outage.shared.trigger(reason:)`, `.isActive`.

- [ ] **Step 1: `SaveMonitor.process`** – am Ende: wenn `Connectivity.shared.isOnline`, `sleepingSince == nil`,
  `!Outage.shared.isActive` und `OutagePolicy.savesSignal(durations: episodes.values.map { duration($0, until: now) })`
  → `Outage.shared.trigger(reason: "<n> Dokumente speichern seit über 3 Min.")`.
- [ ] **Step 2: `OfficeIntegration.tick`** – Guard um `!Outage.shared.isActive` ergänzen (nur Neuöffnen;
  `surveyAll` bleibt unverändert).
- [ ] **Step 3: Diff durchsehen.**
- [ ] **Step 4: Commit** „Trigger outage mode from stuck saves; pause auto-reopen during outage“.

### Task 6: Bauen, Release-Notes

**Files:**
- Modify: `.github/RELEASE_NOTES.md` (neuer Abschnitt „Neu in 1.9.0“ oben)

- [ ] **Step 1: Release-Notes** – drei Punkte in Anwendersprache: Störungsbetrieb (automatisch, 30 Min., Knopf
  „Wieder online versuchen“), Menüpunkt „Vorübergehend lokal öffnen (1 Std.)“, Fenster mit „Lokal öffnen“/„Abbrechen“.
- [ ] **Step 2: Push Branch, CI manuell** – `git push -u origin feature/outage-local-open`;
  `gh workflow run Build --ref feature/outage-local-open`; `gh run watch <id> --exit-status`.
  Erwartet: „App bauen“ grün, Selbsttest-Schritt druckt nur `ok`-Zeilen, Exit 0.
- [ ] **Step 3: Commit** „Release notes: 1.9.0“. Merge/Tag nur nach Rückfrage beim Anwender.
