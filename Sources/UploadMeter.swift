import Foundation

/// Misst, ob eine Office-App beim Speichern wirklich Daten hochlädt – für die Anzeige in der Menüleiste.
///
/// „Wird gespeichert…“ in der Titelleiste sagt nicht, ob etwas passiert: In den Berichten hat PowerPoint bei fast
/// allen langsamen Speichervorgängen in 10–15 Minuten unter 0,5 MB gesendet – es hing, statt zu laden. Gemessen
/// werden deshalb die Bytes, die die App ins Netz sendet (`nettop`, je Programm), solange gespeichert wird.
///
/// Bewusst **kein Prozentwert**: Office lädt beim AutoSpeichern nur geänderte Teile hoch, und wie viel insgesamt
/// hochzuladen ist, verrät es nicht. Angezeigt werden Tempo, bisher gesendete Menge und Stillstand. Die Messung gilt
/// je App, nicht je Datei – speichern zwei Präsentationen zugleich, ist es die Summe.
@MainActor
final class UploadMeter {
    static let shared = UploadMeter()

    struct Reading {
        let app: OfficeApp
        /// Seit Beginn der Messung gesendet.
        var sent: Int64
        /// Bytes je Sekunde zwischen den letzten beiden Messungen.
        var rate: Double
        let since: Date
        /// Zuletzt nennenswert gesendet (mindestens `activityBytes` zwischen zwei Messungen).
        var lastActivity: Date
        /// Anzahl Messungen; erst ab der zweiten gibt es ein Tempo.
        var samples = 1

        /// Seit `stallAfter` nichts Nennenswertes gesendet – das Speichern hängt vermutlich.
        func isStalled(at now: Date) -> Bool {
            now.timeIntervalSince(since) >= UploadMeter.stallAfter && now.timeIntervalSince(lastActivity) >= UploadMeter.stallAfter
        }
    }

    // Konstanten und Formatierung ohne Bindung an den Hauptthread – der Selbsttest (`--selftest`) prüft sie.
    /// Messabstand, solange gespeichert wird.
    nonisolated static let interval: TimeInterval = 5
    /// Weniger als das zwischen zwei Messungen zählt nicht als Hochladen (Hintergrundverkehr der App).
    nonisolated static let activityBytes: Int64 = 20_000
    /// So lange ohne nennenswertes Senden gilt das Speichern als hängend.
    nonisolated static let stallAfter: TimeInterval = 120

    private(set) var readings: [OfficeApp: Reading] = [:]
    private var baseline: [OfficeApp: Int64] = [:]
    private var previous: [OfficeApp: (bytes: Int64, date: Date)] = [:]
    private var saving = Set<OfficeApp>()
    private var sampling = false
    private var lastSample = Date.distantPast

    private init() {}

    /// Von `SaveMonitor` bei jeder Abfrage: die Apps, die gerade (seit mindestens 10 s) speichern.
    func update(saving apps: Set<OfficeApp>) {
        let changed = apps != saving
        saving = apps
        for app in Set(readings.keys).subtracting(apps) {
            readings[app] = nil
            baseline[app] = nil
            previous[app] = nil
        }
        if changed { notify() }
        guard !apps.isEmpty, !sampling, Date().timeIntervalSince(lastSample) >= Self.interval else { return }
        sampling = true
        lastSample = Date()
        Task {
            let snapshot = await NetworkUsage.take()
            sampling = false
            if let snapshot { record(snapshot) }
        }
    }

    private func record(_ snapshot: NetworkUsage.Snapshot) {
        let now = snapshot.date
        for app in saving {
            let bytes = NetworkUsage.sent(snapshot, app: app)
            guard let base = baseline[app], let last = previous[app], bytes >= last.bytes else {
                // Erste Messung – oder die App wurde neu gestartet (Zähler wieder bei 0).
                baseline[app] = bytes
                previous[app] = (bytes, now)
                readings[app] = Reading(app: app, sent: 0, rate: 0, since: now, lastActivity: now)
                continue
            }
            let delta = bytes - last.bytes
            let seconds = max(now.timeIntervalSince(last.date), 0.5)
            var reading = readings[app] ?? Reading(app: app, sent: 0, rate: 0, since: now, lastActivity: now)
            reading.sent = bytes - base
            reading.rate = Double(delta) / seconds
            reading.samples += 1
            if delta >= Self.activityBytes { reading.lastActivity = now }
            readings[app] = reading
            previous[app] = (bytes, now)
        }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .uploadMeterChanged, object: nil)
    }

    // MARK: - Texte

    /// Kurztext neben dem Symbol in der Menüleiste; nil = nichts anzeigen.
    func statusText(at now: Date = Date()) -> String? {
        let ready = readings.values.filter { $0.samples >= 2 }
        guard !ready.isEmpty else { return nil }
        if ready.allSatisfy({ $0.isStalled(at: now) }) { return "⚠︎ steht" }
        let rate = ready.filter { !$0.isStalled(at: now) }.map(\.rate).max() ?? 0
        return "↑ " + Self.rateText(rate)
    }

    /// Eine Zeile je App für das Menü (nur Apps mit mindestens zwei Messungen).
    func menuLines(at now: Date = Date()) -> [String] {
        readings.values.filter { $0.samples >= 2 }.sorted { $0.app.displayName < $1.app.displayName }.map { r in
            let measured = SaveMonitor.format(now.timeIntervalSince(r.since))
            if r.isStalled(at: now) {
                return "\(r.app.displayName) sendet seit \(SaveMonitor.format(now.timeIntervalSince(r.lastActivity))) nichts – "
                    + "das Speichern hängt vermutlich"
            }
            return "\(r.app.displayName) lädt hoch: \(Self.rateText(r.rate)) · \(Self.sizeText(r.sent)) in \(measured)"
        }
    }

    nonisolated static func rateText(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1_000_000
            ? String(format: "%.1f MB/s", bytesPerSecond / 1_000_000).replacingOccurrences(of: ".", with: ",")
            : "\(Int((bytesPerSecond / 1000).rounded())) KB/s"
    }

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        bytes >= 1_000_000
            ? String(format: "%.1f MB", Double(bytes) / 1_000_000).replacingOccurrences(of: ".", with: ",")
            : "\(Int((Double(bytes) / 1000).rounded())) KB"
    }
}

extension Notification.Name {
    static let uploadMeterChanged = Notification.Name("OneDriveOpener.uploadMeterChanged")
}
