import AppKit
import ApplicationServices

/// Misst, wie lange Word, Excel und PowerPoint brauchen, bis ein Cloud-Dokument gespeichert ist.
///
/// Mit AutoSpeichern lädt Office jede Änderung selbst zu OneDrive hoch – der OneDrive-Client ist daran
/// nicht beteiligt und zeigt nichts an. Den Fortschritt sieht man nur in der Titelleiste („Wird
/// gespeichert…“ → „Gespeichert“). Diese Anzeige liest die App über die Bedienungshilfen mit
/// (macOS-Freigabe nötig). Die Ergebnisse gehen ohne Zutun an den Berichts-Server:
/// - `slow_save`: ein Speichervorgang ab 2 Minuten (und einmal, wenn er nach 10 Minuten noch läuft)
/// - `save_stats`: alle 3 Stunden eine Übersicht aller gemessenen Vorgänge
/// - `save_probe`: je Office-App, -Version und Zustand einmal die gelesenen Titelleisten-Texte (prüft die Erkennung)
/// - `save_monitor`: Freigabe erteilt, abgelehnt oder fehlt
///
/// Dauert ein Vorgang länger als 45 s, zeigt ein kleines Fenster oben rechts, dass noch gespeichert wird
/// (`SaveNotice`) – damit das Dokument nicht vorher geschlossen oder der Mac zugeklappt wird.
@MainActor
final class SaveMonitor {
    static let shared = SaveMonitor()

    private struct Episode {
        let app: OfficeApp
        let document: String
        let start: Date
        var texts: [String] = []
        var asleep: TimeInterval = 0
        var offline: TimeInterval = 0
        /// Seit wann keine Speicheranzeige mehr zu sehen ist.
        var quietSince: Date?
        var reportedRunning = false
        /// Netzwerk-Momentaufnahme ab 20 s Dauer (Vergleich beim Bericht, siehe `NetworkUsage`).
        var network: NetworkUsage.Snapshot?
        var networkRequested = false
    }

    private struct OpenedFile {
        let file: URL
        let date: Date
        let method: String
    }

    private(set) var status = "aus"
    private(set) var isTrusted = false
    private var timer: Timer?
    private var scanning = false
    private var lastTick = Date()
    private var sleepingSince: Date?
    private var episodes: [String: Episode] = [:]
    private var opened: [String: OpenedFile] = [:]
    private var probed = Set<String>()
    private var officeVersions: [OfficeApp: String] = [:]
    private var measuredCount = 0
    private var lastResult = ""
    private var slowReportsToday = 0
    private var reportDay = Calendar.current.startOfDay(for: Date())
    private var reportedMissing = false
    /// Lokale Datei je Dokumentname, aus den Online-Adressen offener Cloud-Dokumente (`noteCloudDocument`).
    private var cloudFiles: [String: URL] = [:]
    private var lookedUp = Set<String>()
    private let notice = SaveNotice()
    /// Hinweisfenster vom Anwender geschlossen – erst beim nächsten langen Vorgang wieder zeigen.
    private var noticeDismissed = false
    private var noticeShown = false
    /// Wann die Freigabe zuletzt angefragt wurde – ist sie 5 Min. später nicht aktiv, folgt eine Anleitung.
    private var permissionRequestedAt: Date?
    private var followUpShown = false
    /// Ergebnis von `tccutil reset` (entfernt den Eintrag der alten Version) – für Protokoll und Bericht.
    private var resetResult = "nicht versucht"

    /// Anleitung für einen Eintrag, der noch zur alten Version gehört: Der Schalter steht dann auf „an“,
    /// wirkt aber nicht. Hilft nur Entfernen und neu Hinzufügen.
    private static let renewSteps = """
    1. Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen öffnen.
    2. „OneDrive Opener“ auswählen und unten mit „–“ entfernen – auch wenn der Schalter schon an ist.
    3. Mit „+“ wieder hinzufügen (Programme → OneDrive Opener) und einschalten.
    """

    private init() {
        notice.onClose = { SaveMonitor.shared.noticeDismissed = true }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SaveMonitor.shared.willSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SaveMonitor.shared.didWake() }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SaveMonitor.shared.officeVersions = [:] }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in SaveMonitor.shared.tick() }
        }
        if Settings.saveStatsSent == nil { Settings.saveStatsSent = Date() }
        updateTrust()
        // Nach der Frage nach den Fehlerberichten (90 s nach dem Start).
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            Task { @MainActor in SaveMonitor.shared.askPermissionIfNeeded() }
        }
        // Fehlt die Freigabe dann immer noch, einmal melden – sonst sieht man nur, dass keine Messwerte kommen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1200) {
            Task { @MainActor in SaveMonitor.shared.reportMissingPermission() }
        }
    }

    func settingsChanged() {
        if !Settings.measureSaving { episodes = [:] }
        updateTrust()
    }

    /// Vom Öffnen über die Office-Adresse: so lässt sich später unterscheiden, ob ein langsames
    /// Dokument über OneDrive Opener oder anders (z. B. „Zuletzt verwendet“) geöffnet wurde.
    func noteOpened(_ file: URL) {
        opened[Self.nameKey(file.lastPathComponent)] = OpenedFile(file: file, date: Date(), method: Settings.openMethod.title)
        if opened.count > 100, let oldest = opened.min(by: { $0.value.date < $1.value.date })?.key {
            opened[oldest] = nil
        }
    }

    /// Online-Adresse eines offenen Cloud-Dokuments (von `OfficeIntegration`) – liefert die lokale Datei
    /// und damit die Dateigröße auch für Dokumente, die nicht über OneDrive Opener geöffnet wurden.
    func noteCloudDocument(_ address: String) {
        guard lookedUp.insert(address).inserted else { return }
        guard let file = PathResolver.localFile(forCloudURL: address) else {
            Log.info("Speicher-Messung: keine lokale Datei zu \(address) – Dateigröße unbekannt")
            return
        }
        cloudFiles[Self.nameKey(file.lastPathComponent)] = file
    }

    // MARK: - Freigabe „Bedienungshilfen“

    /// Fragt einmalig nach der Freigabe – und erneut, wenn ein Update sie ungültig gemacht hat
    /// (ad-hoc signiert: macOS bindet die Freigabe an die Signatur der jeweiligen Version).
    func askPermissionIfNeeded() {
        guard Settings.measureSaving, !AXIsProcessTrusted() else { return }
        let renew = Settings.accessibilityGranted
        guard renew || !Settings.accessibilityAsked else { return }
        guard NSApp.modalWindow == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                Task { @MainActor in SaveMonitor.shared.askPermissionIfNeeded() }
            }
            return
        }
        Settings.accessibilityAsked = true
        let alert = NSAlert()
        if renew {
            alert.messageText = "Freigabe nach dem Update erneuern"
            alert.informativeText = """
            Nach dem Update gilt die macOS-Freigabe „Bedienungshilfen“ für OneDrive Opener nicht mehr – auch wenn der Schalter in den Systemeinstellungen noch an ist.

            \(Self.renewSteps)
            """
            alert.addButton(withTitle: "Erneuern …")
        } else {
            alert.messageText = "Speicherdauer in Word und PowerPoint messen?"
            alert.informativeText = """
            Word und PowerPoint brauchen manchmal sehr lange, bis „Gespeichert“ erscheint. Um die Ursache zu finden, kann OneDrive Opener die Speicheranzeige in der Titelleiste von Word, Excel und PowerPoint mitlesen und lange Speichervorgänge automatisch an den Entwickler melden.

            Dafür braucht die App die macOS-Freigabe „Bedienungshilfen“. Gelesen wird nur die Titelleiste – keine Dokumentinhalte.

            Nach Klick auf „Erlauben …“ öffnet macOS die Systemeinstellungen – dort „OneDrive Opener“ einschalten.
            """
            alert.addButton(withTitle: "Erlauben …")
        }
        alert.addButton(withTitle: "Nicht jetzt")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            requestPermission()
        } else {
            Settings.accessibilityGranted = false
            Log.info("Bedienungshilfen: Freigabe abgelehnt – Speicherdauer wird nicht gemessen")
            Reporter.shared.send(kind: "save_monitor", message: "Freigabe abgelehnt", details: [:])
        }
    }

    /// Alten Eintrag entfernen (passt nach einem Update nicht mehr zur Signatur), dann macOS fragen lassen.
    func requestPermission() {
        if let id = Bundle.main.bundleIdentifier {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", id]
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            if (try? process.run()) != nil {
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                process.waitUntilExit()
                resetResult = process.terminationStatus == 0
                    ? "alter Eintrag entfernt"
                    : "Entfernen fehlgeschlagen (Status \(process.terminationStatus)\(message.isEmpty ? "" : ": " + message))"
            } else {
                resetResult = "tccutil nicht startbar"
            }
            Log.info("Bedienungshilfen: \(resetResult)")
        }
        permissionRequestedAt = Date()
        followUpShown = false
        Log.info("Bedienungshilfen: Freigabe angefragt")
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reportMissingPermission() {
        guard Settings.measureSaving, !AXIsProcessTrusted(), !reportedMissing else { return }
        reportedMissing = true
        Reporter.shared.send(kind: "save_monitor", message: "Freigabe „Bedienungshilfen“ fehlt – keine Messung",
                             details: ["asked": Settings.accessibilityAsked, "reset": resetResult])
    }

    /// Einmal je Anfrage: Ist die Freigabe 5 Minuten danach noch nicht aktiv, steht der Schalter vermutlich
    /// schon auf „an“ (Eintrag der alten Version). Dann die Schritte zum Entfernen und neu Hinzufügen zeigen.
    private func showFollowUp() {
        guard !AXIsProcessTrusted(), Settings.measureSaving, NSApp.modalWindow == nil else { return }
        Log.info("Bedienungshilfen: 5 Min. nach der Anfrage noch nicht aktiv – Anleitung angezeigt (\(resetResult))")
        Reporter.shared.send(kind: "save_monitor", message: "Freigabe 5 Min. nach Anfrage nicht aktiv – Anleitung angezeigt",
                             details: ["reset": resetResult])
        let alert = NSAlert()
        alert.messageText = "Freigabe „Bedienungshilfen“ ist noch nicht aktiv"
        alert.informativeText = """
        OneDrive Opener kann die Speicheranzeige von Word und PowerPoint noch nicht lesen. Steht der Schalter in den Systemeinstellungen schon auf „an“, gehört der Eintrag noch zur alten Version:

        \(Self.renewSteps)
        """
        alert.addButton(withTitle: "Systemeinstellungen öffnen")
        alert.addButton(withTitle: "Später")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateTrust() {
        let now = AXIsProcessTrusted()
        if !now, !followUpShown, let requested = permissionRequestedAt, Date().timeIntervalSince(requested) >= 300 {
            followUpShown = true
            DispatchQueue.main.async {
                Task { @MainActor in SaveMonitor.shared.showFollowUp() }
            }
        }
        if now != isTrusted {
            isTrusted = now
            if now {
                Settings.accessibilityGranted = true
                Log.info("Bedienungshilfen freigegeben – Speicherdauer in Office wird gemessen")
                Reporter.shared.send(kind: "save_monitor", message: "Messung aktiv", details: [:])
            }
        }
        let text: String
        if !Settings.measureSaving {
            text = "aus"
        } else if !isTrusted {
            text = "keine Freigabe – Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → „OneDrive Opener“ einschalten"
        } else if measuredCount == 0 {
            text = "aktiv – noch kein Speichervorgang gemessen"
        } else {
            text = "aktiv – \(measuredCount) Speichervorgänge gemessen, zuletzt \(lastResult)"
        }
        if text != status {
            status = text
            AppState.changed()
        }
    }

    // MARK: - Messung

    private func willSleep() {
        sleepingSince = Date()
        let now = Date()
        for episode in episodes.values where duration(episode, until: now) >= 10 {
            Log.info("Speichern: Mac schläft ein, während „\(episode.document)“ (\(episode.app.displayName)) noch gespeichert wird")
        }
    }

    private func didWake() {
        guard let since = sleepingSince else { return }
        let asleep = Date().timeIntervalSince(since)
        for key in Array(episodes.keys) { episodes[key]?.asleep += asleep }
        sleepingSince = nil
        lastTick = Date()
    }

    private func tick() {
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastTick), 10)
        lastTick = now
        updateTrust()
        sendStatsIfDue(now)
        guard Settings.measureSaving, isTrusted, sleepingSince == nil, !scanning else { return }
        let targets = OfficeApp.allCases.compactMap { app -> TitleBarReader.Target? in
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                .first(where: { !$0.isTerminated }) else { return nil }
            return TitleBarReader.Target(app: app, pid: running.processIdentifier)
        }
        if targets.isEmpty {
            if !episodes.isEmpty { process([], at: now, elapsed: elapsed) }
            return
        }
        scanning = true
        Task {
            let windows: [TitleBarReader.Window] = await withCheckedContinuation { continuation in
                saveMonitorQueue.async { continuation.resume(returning: TitleBarReader.read(targets)) }
            }
            scanning = false
            process(windows, at: Date(), elapsed: elapsed)
        }
    }

    private func process(_ windows: [TitleBarReader.Window], at now: Date, elapsed: TimeInterval) {
        var seen = Set<String>()
        var lines: [String] = []
        for window in windows {
            let reading = SaveIndicator.classify(window.texts, title: window.title)
            let key = window.app.rawValue + "|" + reading.document
            seen.insert(key)
            lines.append("\(window.app.displayName) „\(window.title)“: \(reading.state.rawValue)\(reading.text.map { " („\($0)“)" } ?? "")")
            probe(window, reading)

            switch reading.state {
            case .saving, .pending, .failed:
                var episode = episodes[key] ?? Episode(app: window.app, document: reading.document, start: now)
                if let text = reading.text, !episode.texts.contains(text) {
                    episode.texts.append(text)
                    if reading.state == .failed {
                        Log.info("Speichern: \(window.app.displayName) meldet für „\(reading.document)“: \(text)")
                    }
                }
                episode.quietSince = nil
                if !Connectivity.shared.isOnline { episode.offline += elapsed }
                if !episode.reportedRunning, duration(episode, until: now) >= 600 {
                    episode.reportedRunning = true
                    Log.info("Speichern: „\(episode.document)“ (\(episode.app.displayName)) läuft seit \(Self.format(duration(episode, until: now)))")
                    report(episode, until: now, outcome: "läuft noch")
                }
                if !episode.networkRequested, duration(episode, until: now) >= 20 {
                    episode.networkRequested = true
                    Task {
                        let snapshot = await NetworkUsage.take()
                        self.episodes[key]?.network = snapshot
                    }
                }
                episodes[key] = episode
            case .saved, .local:
                if let episode = episodes.removeValue(forKey: key) {
                    finish(episode, at: now, outcome: reading.state == .saved ? "gespeichert" : "lokal gespeichert")
                }
            case .idle:
                // Office zeigt zwischendurch evtl. gar nichts an – erst nach 6 s als beendet werten.
                guard var episode = episodes[key] else { continue }
                let since = episode.quietSince ?? now
                if now.timeIntervalSince(since) >= 6 {
                    episodes[key] = nil
                    finish(episode, at: since, outcome: "Anzeige verschwunden")
                } else {
                    episode.quietSince = since
                    episodes[key] = episode
                }
            }
        }
        for (key, episode) in episodes where !seen.contains(key) {
            episodes[key] = nil
            finish(episode, at: now, outcome: "Fenster geschlossen, bevor „Gespeichert“ erschien")
            if duration(episode, until: now) >= 10, Settings.saveWarning {
                notice.show("„\(episode.document)“ wurde geschlossen, während \(episode.app.displayName) noch gespeichert hat. "
                    + "Öffne das Dokument erneut und prüfe, ob die letzte Änderung angekommen ist.",
                    symbol: "exclamationmark.triangle.fill", color: .systemOrange, hideAfter: 30)
                noticeShown = false
            }
        }
        SaveMonitorSnapshot.lines = lines
        updateNotice(now)
    }

    /// Hinweis, solange ein Dokument länger als 45 s speichert; danach kurz „Alles gespeichert“.
    private func updateNotice(_ now: Date) {
        let long = episodes.values.filter { duration($0, until: now) >= 45 }
            .sorted { $0.start < $1.start }
        guard Settings.saveWarning, let first = long.first else {
            if noticeShown {
                noticeShown = false
                if !noticeDismissed {
                    notice.show("Alles gespeichert.", symbol: "checkmark.circle.fill", color: .systemGreen, hideAfter: 3)
                }
            }
            noticeDismissed = false
            return
        }
        guard !noticeDismissed else { return }
        noticeShown = true
        let more = long.count > 1 ? " (und \(long.count - 1) weitere)" : ""
        notice.show("\(first.app.displayName) speichert „\(first.document)“\(more) seit \(Self.format(duration(first, until: now))). "
            + "Bitte das Dokument nicht schließen und den Mac nicht zuklappen.",
            symbol: "icloud.and.arrow.up", color: .systemBlue, hideAfter: nil)
    }

    private func duration(_ episode: Episode, until end: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(episode.start) - episode.asleep)
    }

    private func finish(_ episode: Episode, at end: Date, outcome: String) {
        let seconds = duration(episode, until: end)
        let via = openedFile(episode.document) != nil
        SaveStats.record(app: episode.app, document: episode.document, seconds: seconds, outcome: outcome, viaApp: via,
                         sizeKB: localFile(episode.document).flatMap(Self.sizeKB))
        measuredCount += 1
        lastResult = "„\(episode.document)“ \(Self.format(seconds))"
        updateTrust()
        guard seconds >= 10 else { return }
        var extras: [String] = []
        if episode.offline > 0 { extras.append("davon \(Self.format(episode.offline)) offline") }
        if episode.asleep > 0 { extras.append("Ruhezustand \(Self.format(episode.asleep)) nicht mitgezählt") }
        if !episode.texts.isEmpty { extras.append("Anzeige: \(episode.texts.joined(separator: " → "))") }
        Log.info("Speichern: „\(episode.document)“ (\(episode.app.displayName)) – \(outcome) nach \(Self.format(seconds))"
            + (extras.isEmpty ? "" : " (\(extras.joined(separator: "; ")))"))
        if seconds >= 120 { report(episode, until: end, outcome: outcome) }
    }

    private func report(_ episode: Episode, until end: Date, outcome: String) {
        let today = Calendar.current.startOfDay(for: end)
        if today != reportDay {
            reportDay = today
            slowReportsToday = 0
        }
        guard slowReportsToday < 20 else { return }
        slowReportsToday += 1
        let seconds = duration(episode, until: end)
        var details: [String: Any] = [
            "app": episode.app.displayName,
            "office_version": officeVersion(episode.app),
            "document": episode.document,
            "outcome": outcome,
            "duration_s": Int(seconds),
            "started": ISO8601DateFormatter().string(from: episode.start),
            "status_texts": episode.texts.joined(separator: " → "),
            "offline_s": Int(episode.offline),
            "asleep_s": Int(episode.asleep),
            "network": Connectivity.shared.networkDescription,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "documents_saving_now": episodes.count,
            "log": Log.readTail(60).joined(separator: "\n"),
        ]
        if let file = openedFile(episode.document) {
            let minutes = Int(Date().timeIntervalSince(file.date) / 60)
            details["opened_by_app"] = "ja, vor \(minutes) Min. (\(file.method))"
        } else {
            details["opened_by_app"] = "nein (z. B. über „Zuletzt verwendet“ in Office)"
        }
        if let file = localFile(episode.document) {
            details["local_path"] = file.path
            if let size = Self.sizeKB(file) { details["file_size_kb"] = size }
        }
        let message = "„\(episode.document)“ (\(episode.app.displayName)): \(outcome) nach \(Self.format(seconds))"
        let start = episode.network
        let collected = details
        Task {
            var payload = collected
            if let start, let end = await NetworkUsage.take() {
                payload["network_usage"] = NetworkUsage.describe(from: start, to: end)
            } else {
                payload["network_usage"] = "keine Messung (nettop nicht verfügbar)"
            }
            Reporter.shared.send(kind: "slow_save", message: message, details: payload)
        }
    }

    /// Lokale Datei zum Dokumentnamen: über OneDrive Opener geöffnet oder aus der Online-Adresse in Office.
    private func localFile(_ document: String) -> URL? {
        openedFile(document)?.file ?? cloudFiles[Self.nameKey(document)]
    }

    private nonisolated static func sizeKB(_ file: URL) -> Int? {
        (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { $0 / 1024 }
    }

    /// Je Office-App, -Version und erkanntem Zustand einmal die gelesenen Texte melden – so lässt sich
    /// aus der Ferne prüfen, ob die Erkennung die Anzeige wirklich findet.
    private func probe(_ window: TitleBarReader.Window, _ reading: SaveIndicator.Reading) {
        guard Settings.sendReports else { return }
        let key = "\(window.app.rawValue)|\(officeVersion(window.app))|\(reading.state.rawValue)"
        guard probed.insert(key).inserted else { return }
        var stored = Settings.saveProbes
        guard !stored.contains(key) else { return }
        stored.append(key)
        Settings.saveProbes = Array(stored.suffix(200))
        Reporter.shared.send(kind: "save_probe",
                             message: "\(window.app.displayName): Titelleiste „\(reading.state.rawValue)“\(reading.text.map { " („\($0)“)" } ?? "")",
                             details: [
                                "app": window.app.displayName,
                                "office_version": officeVersion(window.app),
                                "window_title": window.title,
                                "state": reading.state.rawValue,
                                "status_text": reading.text ?? "–",
                                "texts": window.texts.joined(separator: "\n"),
                             ])
    }

    private func sendStatsIfDue(_ now: Date) {
        guard Settings.sendReports, now.timeIntervalSince(Settings.saveStatsSent ?? now) >= 3 * 3600 else { return }
        Settings.saveStatsSent = now
        guard let summary = SaveStats.takeSummary() else { return }
        Reporter.shared.send(kind: "save_stats", message: summary.message, details: summary.details)
    }

    private func openedFile(_ document: String) -> OpenedFile? {
        opened[Self.nameKey(document)] ?? opened[document.precomposedStringWithCanonicalMapping.lowercased()]
    }

    private func officeVersion(_ app: OfficeApp) -> String {
        if let known = officeVersions[app] { return known }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first
        let version = (running?.bundleURL ?? app.applicationURL).flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?"
        officeVersions[app] = version
        return version
    }

    private static func nameKey(_ name: String) -> String {
        (name.precomposedStringWithCanonicalMapping.lowercased() as NSString).deletingPathExtension
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s / 60 % 60) min"
    }
}

private let saveMonitorQueue = DispatchQueue(label: "OneDriveOpener.saveMonitor", qos: .utility)

/// Letzter Stand der Titelleisten für den Diagnosebericht (wird auch außerhalb des Hauptthreads gelesen).
enum SaveMonitorSnapshot {
    private static let lock = NSLock()
    private static var stored: [String] = []

    static var lines: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    static func diagnosticLines() -> [String] {
        var out = ["Messung: \(Settings.measureSaving ? "an" : "aus") · Freigabe Bedienungshilfen: \(AXIsProcessTrusted() ? "ja" : "nein")"]
        let current = lines
        out += current.isEmpty ? ["Keine Office-Fenster gelesen"] : current
        out += SaveStats.recentLines(10)
        return out
    }
}

/// Erkennt den Speicherstatus an den Texten der Titelleiste (deutsch und englisch).
enum SaveIndicator {
    enum State: String {
        case failed = "Fehler", pending = "Hochladen ausstehend", saving = "speichert"
        case local = "auf dem Mac", saved = "gespeichert", idle = "keine Anzeige"
    }

    struct Reading {
        let state: State
        let text: String?
        let document: String
    }

    /// Reihenfolge = Vorrang, wenn mehrere Texte passen.
    private static let order: [State] = [.failed, .pending, .saving, .local, .saved]
    private static let containing: [State: [String]] = [
        .failed: ["speichern nicht möglich", "konnte nicht gespeichert", "fehler beim speichern", "fehler beim hochladen",
                  "upload fehlgeschlagen", "upload failed", "couldn't save", "could not save", "can't save", "unable to save"],
        .pending: ["hochladen ausstehend", "upload ausstehend", "upload pending", "pending upload"],
        .saving: ["wird gespeichert", "wird hochgeladen", "saving", "uploading"],
        .local: ["auf meinem mac", "on my mac"],
        .saved: ["gespeichert", "saved"],
    ]
    /// Kurze Texte nur, wenn sie allein stehen („Kopie speichern…“ ist ein Menüeintrag, kein Status).
    private static let exact: [State: [String]] = [
        .saving: ["speichern…", "speichert…", "hochladen…"],
    ]
    private static let negations = ["ungespeichert", "nicht gespeichert", "unsaved", "not saved"]
    private static let separators = CharacterSet(charactersIn: "—–-•·:|").union(.whitespacesAndNewlines)

    static func state(of text: String) -> State {
        let t = text.lowercased().replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: separators)
        guard !t.isEmpty else { return .idle }
        if containing[.failed]!.contains(where: { t.contains($0) }) { return .failed }
        if negations.contains(where: { t.contains($0) }) { return .idle }
        for state in order {
            if exact[state]?.contains(t) == true { return state }
            if containing[state]?.contains(where: { t.contains($0) }) == true { return state }
        }
        return .idle
    }

    /// Dokumentname ohne angehängten Status („Test1 — Gespeichert“ → „Test1“).
    static func documentName(_ title: String) -> String {
        for separator in [" — ", " – ", " - ", " • "] {
            if let range = title.range(of: separator, options: .backwards),
               state(of: String(title[range.upperBound...])) != .idle {
                return String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    static func classify(_ texts: [String], title: String) -> Reading {
        let document = documentName(title)
        var best: (state: State, text: String)?
        for text in texts + [title] {
            // Der Dokumentname selbst zählt nicht („Saving plan.docx“).
            let rest = document.isEmpty ? text : text.replacingOccurrences(of: document, with: " ")
            let found = state(of: rest)
            guard found != .idle else { continue }
            if best == nil || order.firstIndex(of: found)! < order.firstIndex(of: best!.state)! {
                best = (found, text)
            }
        }
        return Reading(state: best?.state ?? .idle, text: best?.text, document: document)
    }
}

/// Liest die Titelleisten der Office-Fenster über die Bedienungshilfen (läuft außerhalb des Hauptthreads).
enum TitleBarReader {
    struct Target {
        let app: OfficeApp
        let pid: pid_t
    }

    struct Window {
        let app: OfficeApp
        let title: String
        let texts: [String]
    }

    /// Bereich unter der Fensteroberkante, in dem Office Dokumentname und Speicherstatus zeigt.
    private static let band: CGFloat = 60
    /// Dokumentinhalt und große Listen nie lesen – nur Bedienelemente der Titelleiste.
    private static let skippedRoles: Set<String> = [
        "AXTextArea", "AXWebArea", "AXScrollArea", "AXLayoutArea", "AXTable", "AXOutline", "AXBrowser", "AXList",
    ]

    static func read(_ targets: [Target]) -> [Window] {
        // Eine hängende Office-App darf die Messung nicht minutenlang aufhalten.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        var result: [Window] = []
        for target in targets {
            let app = AXUIElementCreateApplication(target.pid)
            guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows.prefix(20) {
                guard let title = value(window, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
                if let subrole = value(window, kAXSubroleAttribute) as? String, subrole != kAXStandardWindowSubrole { continue }
                result.append(Window(app: target.app, title: title, texts: texts(in: window)))
            }
        }
        return result
    }

    private static func texts(in window: AXUIElement) -> [String] {
        guard let windowFrame = frame(window) else { return [] }
        let bottom = windowFrame.minY + band
        let deadline = Date().addingTimeInterval(1.5)
        var texts: [String] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, index < 250, Date() < deadline {
            let (element, depth) = queue[index]
            index += 1
            if depth > 0 {
                for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                    guard let text = (value(element, attribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty, text.count <= 150, !texts.contains(text) else { continue }
                    texts.append(text)
                }
            }
            guard depth < 8, let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children {
                if let role = value(child, kAXRoleAttribute) as? String, skippedRoles.contains(role) { continue }
                // Nur Elemente, die in den Titelleistenbereich reichen – Menüband und Dokument sind riesig.
                if let f = frame(child), f.minY >= bottom || f.maxY <= windowFrame.minY { continue }
                queue.append((child, depth + 1))
            }
        }
        return Array(texts.prefix(40))
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

/// Alle gemessenen Speichervorgänge bis zur nächsten Übersicht (`save_stats`), auch über Neustarts hinweg.
enum SaveStats {
    static func record(app: OfficeApp, document: String, seconds: TimeInterval, outcome: String, viaApp: Bool, sizeKB: Int?) {
        var entries = Settings.saveStats
        var entry: [String: Any] = [
            "t": Date().timeIntervalSince1970,
            "a": app.displayName,
            "d": document,
            "s": (seconds * 10).rounded() / 10,
            "o": outcome,
            "v": viaApp,
        ]
        if let sizeKB { entry["k"] = sizeKB }
        entries.append(entry)
        Settings.saveStats = Array(entries.suffix(3000))
    }

    /// Übersicht für den Bericht; leert die Liste. `nil`, wenn nichts gemessen wurde.
    static func takeSummary() -> (message: String, details: [String: Any])? {
        let entries = Settings.saveStats
        guard !entries.isEmpty else { return nil }
        Settings.saveStats = []
        func seconds(_ e: [String: Any]) -> Double { e["s"] as? Double ?? 0 }
        func stats(_ list: [[String: Any]]) -> String {
            let d = list.map(seconds).sorted()
            guard !d.isEmpty else { return "–" }
            return "\(d.count)× · Median \(SaveMonitor.format(d[d.count / 2])) · 90 % \(SaveMonitor.format(d[min(d.count - 1, d.count * 9 / 10)])) · max \(SaveMonitor.format(d.last!))"
        }
        let buckets: [(String, ClosedRange<Double>)] = [
            ("unter 5 s", 0...4.99), ("5–30 s", 5...29.99), ("30 s – 2 min", 30...119.99),
            ("2–10 min", 120...599.99), ("über 10 min", 600...Double.greatestFiniteMagnitude),
        ]
        var details: [String: Any] = [
            "all": stats(entries),
            "via_app": stats(entries.filter { $0["v"] as? Bool == true }),
            "other": stats(entries.filter { $0["v"] as? Bool != true }),
            "buckets": buckets.map { bucket in "\(bucket.0): \(entries.filter { bucket.1.contains(seconds($0)) }.count)" }.joined(separator: "\n"),
            "network": Connectivity.shared.networkDescription,
        ]
        for app in Set(entries.compactMap { $0["a"] as? String }).sorted() {
            details["app_" + app.lowercased()] = stats(entries.filter { $0["a"] as? String == app })
        }
        details["long"] = lines(entries.filter { seconds($0) >= 10 }.suffix(300)).joined(separator: "\n")
        return ("\(entries.count) Speichervorgänge: \(stats(entries))", details)
    }

    static func recentLines(_ count: Int) -> [String] {
        lines(Settings.saveStats.suffix(count))
    }

    private static func lines<S: Sequence>(_ entries: S) -> [String] where S.Element == [String: Any] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { e in
            let date = Date(timeIntervalSince1970: e["t"] as? Double ?? 0)
            let via = e["v"] as? Bool == true ? "über App geöffnet" : "anders geöffnet"
            let size = (e["k"] as? Int).map { kb in kb >= 1024 ? ", \(kb / 1024) MB" : ", \(kb) KB" } ?? ""
            return "\(formatter.string(from: date))  \(e["a"] as? String ?? "?")  „\(e["d"] as? String ?? "?")“  "
                + "\(SaveMonitor.format(e["s"] as? Double ?? 0))  \(e["o"] as? String ?? "")  (\(via)\(size))"
        }
    }
}
