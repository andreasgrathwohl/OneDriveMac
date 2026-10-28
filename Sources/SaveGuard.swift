import AppKit

/// Warnt, wenn Office ein Cloud-Dokument offenbar nicht mehr zu OneDrive hochlädt – bevor Arbeit verloren geht.
///
/// Gesunde Cloud-Dokumente zeigen in der Titelleiste immer „Gespeichert“, auch unbearbeitet. Kann Office den
/// Sync-Status nicht ermitteln, fehlt die Anzeige ganz: Änderungen bleiben dann nur im Office-Cache auf dem
/// Mac und gehen beim „Sofort beenden“ oder Neuöffnen verloren – unbemerkt, oft über Tage. Erkannt wird:
/// - `noStatus`: Cloud-Dokument ohne Speicheranzeige in der Titelleiste seit 10 Minuten
/// - `failed`: Office meldet seit 30 s einen Speicherfehler
/// - `stuck`: „Wird gespeichert…“ / „Hochladen ausstehend“ seit 15 Minuten
/// - `unsaved`: Office meldet per AppleScript seit 20 Minuten ungespeicherte Änderungen
///
/// Je Vorfall eine Warnung mit Anleitung („Kopie speichern“), erneut nach 60 Minuten; dazu die Menüleiste
/// (`UserStatus`) und ein Bericht `save_guard` – auch, wenn das Problem verschwindet oder Office beendet wird.
/// Offline und im Ruhezustand läuft keine Uhr (Office kann dann gar nicht hochladen).
@MainActor
final class SaveGuard {
    static let shared = SaveGuard()

    enum Problem: String {
        case noStatus = "keine Speicheranzeige", failed = "Speicherfehler", stuck = "Speichern hängt"
        case unsaved = "ungespeicherte Änderungen"
    }

    /// Titelleiste eines Office-Fensters (von `SaveMonitor`, alle 2 s).
    struct TitleReading {
        let app: OfficeApp
        let document: String
        let state: SaveIndicator.State
        let text: String?
        /// Titelleiste vollständig gelesen (Schalter „AutoSpeichern“ gefunden) – sonst zählt „keine Anzeige“ nicht.
        let readable: Bool
    }

    struct Warning {
        let app: OfficeApp
        let document: String
        let problem: Problem
        let since: Date

        var title: String {
            switch problem {
            case .noStatus: return "\(app.displayName) zeigt nicht „Gespeichert“"
            case .failed: return "\(app.displayName) kann nicht speichern"
            case .stuck: return "\(app.displayName) speichert nicht fertig"
            case .unsaved: return "\(app.displayName) hat Ungespeichertes"
            }
        }

        var subtitle: String {
            "„\(document)“: Datei → Kopie speichern … und \(app.displayName) nicht sofort beenden."
        }
    }

    private enum TitleGroup { case failed, busy, ok, blank }

    private struct Document {
        let app: OfficeApp
        let name: String
        var address: String
        let opened: Date
        var saved: Bool?
        var everSaved = false
        var unsavedSince: Date?
        var title: SaveIndicator.State?
        var titleText: String?
        var titleSince: Date?
        var titleSeen: Date?
        var problem: Problem?
        var problemSince: Date?
        var alertedAt: Date?
    }

    private(set) var warning: Warning?
    private var documents: [String: Document] = [:]
    private var lastEvaluate = Date()
    private var sleeping = false
    private var alertPending = false

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SaveGuard.shared.sleeping = true }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                SaveGuard.shared.sleeping = false
                SaveGuard.shared.resetClocks(Date())
            }
        }
    }

    // MARK: - Eingänge

    /// Alle offenen Cloud-Dokumente einer Office-App (von `OfficeIntegration`, per AppleScript).
    func officeDocuments(_ app: OfficeApp, cloud: [(address: String, saved: Bool?)]) {
        let now = Date()
        var present = Set<String>()
        for entry in cloud {
            let name = Self.documentName(entry.address)
            let key = Self.key(app, name)
            present.insert(key)
            var doc = documents[key] ?? Document(app: app, name: name, address: entry.address, opened: now)
            doc.address = entry.address
            doc.saved = entry.saved
            if entry.saved == true { doc.everSaved = true }
            doc.unsavedSince = entry.saved == false ? (doc.unsavedSince ?? now) : nil
            documents[key] = doc
        }
        for (key, doc) in documents where doc.app == app && !present.contains(key) {
            documents[key] = nil
            if doc.problem != nil { resolved(doc, now: now, outcome: "Dokument geschlossen") }
        }
        evaluate(now)
    }

    func titleBars(_ readings: [TitleReading]) {
        let now = Date()
        var byKey: [String: TitleReading] = [:]
        for reading in readings { byKey[Self.key(reading.app, reading.document)] = reading }
        for key in Array(documents.keys) {
            guard let reading = byKey[key], reading.readable || reading.state != .idle else { continue }
            var doc = documents[key]!
            // Neue Zählung bei Wechsel der Anzeige oder wenn das Fenster eine Weile nicht zu lesen war.
            let stale = doc.titleSeen.map { now.timeIntervalSince($0) >= 30 } ?? true
            if stale || doc.title.map(Self.group) != Self.group(reading.state) { doc.titleSince = now }
            if reading.state == .saved || reading.state == .local { doc.unsavedSince = nil }
            doc.title = reading.state
            doc.titleText = reading.text
            doc.titleSeen = now
            documents[key] = doc
        }
        evaluate(now)
    }

    // MARK: - Auswertung

    private func evaluate(_ now: Date) {
        defer { lastEvaluate = now }
        // Nach einer Pause (Ruhezustand, hängende App) nicht sofort warnen.
        if now.timeIntervalSince(lastEvaluate) > 180 { resetClocks(now) }
        for (key, doc) in documents where !Self.isRunning(doc.app) {
            documents[key] = nil
            if doc.problem != nil { resolved(doc, now: now, outcome: "\(doc.app.displayName) beendet") }
        }
        guard !sleeping, Connectivity.shared.isOnline else {
            resetClocks(now)
            return
        }
        for key in Array(documents.keys) {
            var doc = documents[key]!
            let found = detect(doc, now)
            if found != doc.problem {
                if let found {
                    doc.problem = found
                    doc.problemSince = now
                    doc.alertedAt = nil
                    detected(doc, now: now)
                } else if cleared(doc, now) {
                    // Nur bei echtem „Gespeichert“ entwarnen – ein kurz nicht lesbares Fenster ist keine Entwarnung.
                    resolved(doc, now: now, outcome: "behoben")
                    doc.problem = nil
                    doc.problemSince = nil
                    doc.alertedAt = nil
                }
            }
            documents[key] = doc
        }
        updateWarning()
        alertIfDue(now)
    }

    private func detect(_ doc: Document, _ now: Date) -> Problem? {
        if let state = doc.title, let since = doc.titleSince, let seen = doc.titleSeen, now.timeIntervalSince(seen) < 30 {
            let lasting = now.timeIntervalSince(since)
            switch Self.group(state) {
            case .failed where lasting >= 30: return .failed
            case .busy where lasting >= 900: return .stuck
            case .blank where lasting >= 600: return .noStatus
            case .ok: return nil
            default: break
            }
        }
        // Nur, wenn „saved“ schon einmal true war – sonst ist unklar, was Office damit bei AutoSpeichern meint.
        if doc.everSaved, let since = doc.unsavedSince, now.timeIntervalSince(since) >= 1200 { return .unsaved }
        return nil
    }

    private func cleared(_ doc: Document, _ now: Date) -> Bool {
        if let state = doc.title, let seen = doc.titleSeen, now.timeIntervalSince(seen) < 30, Self.group(state) == .ok { return true }
        return doc.problem == .unsaved && doc.saved == true
    }

    private func resetClocks(_ now: Date) {
        for key in Array(documents.keys) {
            if documents[key]?.unsavedSince != nil { documents[key]?.unsavedSince = now }
            if documents[key]?.titleSince != nil { documents[key]?.titleSince = now }
        }
    }

    private func updateWarning() {
        let first = documents.values.filter { $0.problem != nil }.min { ($0.problemSince ?? .distantFuture) < ($1.problemSince ?? .distantFuture) }
        let next = first.map { Warning(app: $0.app, document: $0.name, problem: $0.problem!, since: $0.problemSince!) }
        if next?.document != warning?.document || next?.problem != warning?.problem || next?.app != warning?.app {
            warning = next
            AppState.changed()
        }
    }

    // MARK: - Melden

    private func detected(_ doc: Document, now: Date) {
        let minutes = Int(now.timeIntervalSince(doc.opened) / 60)
        Log.info("Speicher-Wächter: „\(doc.name)“ (\(doc.app.displayName)) – \(doc.problem!.rawValue)"
            + " (Titelleiste: \(doc.title?.rawValue ?? "nicht gelesen")\(doc.titleText.map { " „\($0)“" } ?? ""), "
            + "AppleScript gespeichert: \(doc.saved.map { $0 ? "ja" : "nein" } ?? "?"), offen seit \(minutes) Min.)")
        report(doc, now: now, message: "„\(doc.name)“ (\(doc.app.displayName)): \(doc.problem!.rawValue)", outcome: "erkannt")
    }

    private func resolved(_ doc: Document, now: Date, outcome: String) {
        let lasted = SaveMonitor.format(now.timeIntervalSince(doc.problemSince ?? now))
        Log.info("Speicher-Wächter: „\(doc.name)“ (\(doc.app.displayName)) – \(doc.problem?.rawValue ?? "?"): \(outcome) nach \(lasted)")
        report(doc, now: now, message: "„\(doc.name)“ (\(doc.app.displayName)): \(doc.problem?.rawValue ?? "?") – \(outcome) nach \(lasted)",
               outcome: outcome)
    }

    private func report(_ doc: Document, now: Date, message: String, outcome: String) {
        let version = Self.isRunning(doc.app)
            ? NSRunningApplication.runningApplications(withBundleIdentifier: doc.app.bundleID).first?.bundleURL
                .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?"
            : "?"
        Reporter.shared.send(kind: "save_guard", message: message, details: [
            "app": doc.app.displayName,
            "office_version": version,
            "document": doc.name,
            "address": doc.address,
            "problem": doc.problem?.rawValue ?? "–",
            "outcome": outcome,
            "title_state": doc.title?.rawValue ?? "nicht gelesen",
            "title_text": doc.titleText ?? "–",
            "saved": doc.saved.map { $0 ? "ja" : "nein" } ?? "?",
            "unsaved_min": doc.unsavedSince.map { Int(now.timeIntervalSince($0) / 60) } ?? 0,
            "open_min": Int(now.timeIntervalSince(doc.opened) / 60),
            "network": Connectivity.shared.networkDescription,
            "log": Log.readTail(40).joined(separator: "\n"),
        ])
    }

    /// Je Vorfall eine Warnung, nach 60 Minuten erneut – nie zwei Dialoge gleichzeitig.
    private func alertIfDue(_ now: Date) {
        guard Settings.saveWarning, !alertPending, NSApp.modalWindow == nil,
              let entry = documents.first(where: { $0.value.problem != nil
                  && now.timeIntervalSince($0.value.alertedAt ?? .distantPast) >= 3600 }) else { return }
        documents[entry.key]?.alertedAt = now
        let doc = entry.value
        alertPending = true
        // Außerhalb der Auswertung zeigen – der Dialog hält die Ereignisschleife an.
        DispatchQueue.main.async {
            Task { @MainActor in
                SaveGuard.shared.showAlert(doc)
                SaveGuard.shared.alertPending = false
            }
        }
    }

    private func showAlert(_ doc: Document) {
        guard let problem = doc.problem else { return }
        let name = doc.app.displayName
        let minutes = Int(Date().timeIntervalSince(doc.titleSince ?? doc.unsavedSince ?? doc.opened) / 60)
        let reason: String
        switch problem {
        case .noStatus:
            reason = "Seit \(minutes) Minuten fehlt in der Titelleiste die Anzeige „Gespeichert“ – bei Dokumenten in OneDrive steht sie dort sonst immer."
        case .failed:
            reason = "\(name) meldet: „\(doc.titleText ?? "Fehler beim Speichern")“."
        case .stuck:
            reason = "\(name) speichert seit \(minutes) Minuten, ohne fertig zu werden."
        case .unsaved:
            reason = "\(name) meldet seit \(minutes) Minuten ungespeicherte Änderungen, obwohl AutoSpeichern sie sofort hochladen sollte."
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "„\(doc.name)“ wird womöglich nicht gespeichert"
        alert.informativeText = """
        \(reason) Änderungen liegen dann evtl. nur auf diesem Mac und gehen beim Beenden verloren.

        Jetzt sichern:
        1. In \(name): Datei → Kopie speichern … → auf dem Schreibtisch ablegen.
        2. \(name) nicht mit „Sofort beenden“ schließen.
        3. Erst danach das Dokument schließen und neu öffnen. Fehlen Änderungen, die Kopie verwenden.
        \(Settings.sendReports ? "\nDer Vorfall wurde automatisch an den Entwickler gemeldet." : "")
        """
        alert.addButton(withTitle: "Zu \(name) wechseln")
        alert.addButton(withTitle: "Später")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        Log.info("Speicher-Wächter: Warnung zu „\(doc.name)“ gezeigt – \(response == .alertFirstButtonReturn ? "zu \(name) gewechselt" : "später")")
        if response == .alertFirstButtonReturn { activate(doc.app) }
    }

    /// Menüleiste: zur betroffenen Office-App wechseln.
    func performAction() {
        if let app = warning?.app { activate(app) }
    }

    private func activate(_ app: OfficeApp) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first?.activate(options: [])
    }

    // MARK: - Hilfen

    private static func group(_ state: SaveIndicator.State) -> TitleGroup {
        switch state {
        case .failed: return .failed
        case .saving, .pending: return .busy
        case .saved, .local: return .ok
        case .idle: return .blank
        }
    }

    private static func isRunning(_ app: OfficeApp) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).contains { !$0.isTerminated }
    }

    /// Dateiname aus der Online-Adresse („…/E_8b_Unit_1.pptx?web=1“ → „E_8b_Unit_1.pptx“).
    private static func documentName(_ address: String) -> String {
        let path = address.components(separatedBy: "?")[0]
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.removingPercentEncoding ?? last
    }

    /// Titelleiste und Online-Adresse zeigen den Namen mal mit, mal ohne Endung – nur Office-Endungen abschneiden
    /// („Klasse 8.1 Test“ bleibt ganz).
    private static let extensions = [".docx", ".docm", ".doc", ".dotx", ".xlsx", ".xlsm", ".xlsb", ".xls",
                                     ".pptx", ".pptm", ".ppt", ".ppsx"]

    private static func key(_ app: OfficeApp, _ name: String) -> String {
        var n = name.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespaces)
        if let ext = extensions.first(where: { n.hasSuffix($0) }) { n = String(n.dropLast(ext.count)) }
        return app.rawValue + "|" + n
    }
}
