import Foundation

/// Reiner Kern des Störungsbetriebs: Bis wann gilt er, und wurde er von Hand eingeschaltet?
/// Ohne Uhr und Seiteneffekte – die Zeit wird hineingereicht, damit `--selftest` ihn prüfen kann.
struct OutagePolicy {
    /// Automatisch ausgelöst (Störungszeichen): 30 Minuten ab dem letzten Zeichen.
    static let automaticDuration: TimeInterval = 1800
    /// Von Hand eingeschaltet („Vorübergehend lokal öffnen (1 Std.)“): 60 Minuten.
    static let manualDuration: TimeInterval = 3600
    /// Ab so langem „Wird gespeichert…“/„Upload ausstehend“ zählt ein Dokument als hängend.
    static let saveStuckAfter: TimeInterval = 180
    /// So viele Dokumente müssen gleichzeitig hängen – eine einzelne große Datei speichert legitim lange.
    static let saveStuckCount = 2

    var until: Date?
    var manual: Bool = false

    /// Aktiv, solange `until` in der Zukunft liegt. Bewusst ein Vergleich mit der Uhr statt eines
    /// Timers: Nach dem Ruhezustand kann ein Timer verloren sein, der Vergleich greift trotzdem.
    func isActive(now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// Beginnt oder verlängert den Störungsbetrieb auf „jetzt + Dauer“ – nie kürzer als bisher.
    /// Ein manueller Betrieb bleibt manuell, auch wenn ein automatisches Zeichen ihn verlängert.
    /// Liefert true, wenn der Betrieb damit neu begonnen hat (vorher nicht aktiv war).
    mutating func trigger(now: Date, manual: Bool) -> Bool {
        let newUntil = now.addingTimeInterval(manual ? Self.manualDuration : Self.automaticDuration)
        if isActive(now: now), let current = until {
            until = max(current, newUntil)
            self.manual = self.manual || manual
            return false
        }
        until = newUntil
        self.manual = manual
        return true
    }

    mutating func end() {
        until = nil
        manual = false
    }

    /// Störungszeichen aus `SaveMonitor`: mindestens zwei Dokumente hängen gleichzeitig seit mindestens
    /// drei Minuten beim Speichern bzw. Hochladen.
    static func savesSignal(durations: [TimeInterval]) -> Bool {
        durations.filter { $0 >= saveStuckAfter }.count >= saveStuckCount
    }
}

/// Störungsbetrieb: Bei einer Microsoft-Störung öffnet `FileOpener` befristet lokal (ohne AutoSpeichern)
/// und kehrt nach Ablauf von selbst zu online zurück. Ausgelöst durch Störungszeichen (`trigger`) oder
/// von Hand (`startManual`). Der Zustand überlebt bewusst keinen Neustart – Neustart = sauberer Neuversuch.
/// Beginn und Ende gehen als Bericht `outage` an den Server.
@MainActor
final class Outage {
    static let shared = Outage()

    private var policy = OutagePolicy()
    private var startedAt: Date?
    private var timer: Timer?
    private var endPending = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private init() {}

    /// Ob gerade lokal geöffnet wird. Ist die Zeit abgelaufen, ohne dass der Timer gefeuert hat
    /// (z. B. nach dem Ruhezustand), endet der Betrieb hier – einmal, kurz danach auf dem Main-Actor,
    /// damit eine Abfrage beim Aufbau von Menü oder Einstellungen keine Änderung mitten im Aufbau auslöst.
    var isActive: Bool {
        if policy.isActive(now: Date()) { return true }
        if policy.until != nil, !endPending {
            endPending = true
            Task { @MainActor in Outage.shared.expireIfDue() }
        }
        return false
    }

    /// Ende des Störungsbetriebs (nil, wenn nicht aktiv).
    var until: Date? { isActive ? policy.until : nil }

    /// Ob der Betrieb von Hand eingeschaltet wurde (false, wenn nicht aktiv).
    var manual: Bool { isActive && policy.manual }

    /// Störungszeichen: beginnt den Betrieb oder verlängert ihn auf 30 Minuten ab jetzt.
    func trigger(reason: String) {
        start(reason: reason, manual: false)
    }

    /// Menüpunkt „Vorübergehend lokal öffnen (1 Std.)“.
    func startManual() {
        start(reason: "manuell", manual: true)
    }

    /// Beendet den Betrieb („Wieder online versuchen“ oder Ablauf). Ohne aktiven Betrieb wirkungslos.
    func end(reason: String) {
        guard policy.until != nil else { return }
        let minutes = startedAt.map { Int((Date().timeIntervalSince($0) / 60).rounded()) } ?? 0
        let wasManual = policy.manual
        policy.end()
        startedAt = nil
        endPending = false
        timer?.invalidate()
        timer = nil
        Log.info("Störungsbetrieb aus: \(reason) (nach \(minutes) Min.) – Dateien öffnen wieder online")
        Reporter.shared.send(kind: "outage", message: "Störungsbetrieb aus", details: [
            "reason": reason,
            "duration_min": minutes,
            "manual": wasManual,
        ])
        AppState.changed()
    }

    private func start(reason: String, manual: Bool) {
        let now = Date()
        // Abgelaufen, aber `expireIfDue` lief noch nicht (z. B. direkt nach dem Aufwachen): erst sauber beenden,
        // sonst folgen zwei „an“-Berichte ohne „aus“ dazwischen und die Dauer im „aus“-Bericht stimmt nicht.
        if policy.until != nil && !policy.isActive(now: now) {
            end(reason: "abgelaufen")
        }
        let begun = policy.trigger(now: now, manual: manual)
        guard let until = policy.until else { return }
        endPending = false
        let untilText = Self.timeFormatter.string(from: until)
        if begun {
            startedAt = now
            Log.info("Störungsbetrieb an: \(reason) – Dateien öffnen bis \(untilText) lokal")
            Reporter.shared.send(kind: "outage", message: "Störungsbetrieb an", details: [
                "reason": reason,
                "duration_min": Int((until.timeIntervalSince(now) / 60).rounded()),
                "manual": policy.manual,
            ])
        } else {
            Log.info("Störungsbetrieb verlängert: \(reason) – Dateien öffnen bis \(untilText) lokal")
        }
        scheduleTimer(until)
        AppState.changed()
    }

    /// Der Timer dient nur der rechtzeitigen Anzeige; maßgeblich ist der Vergleich in `isActive`.
    private func scheduleTimer(_ until: Date) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow), repeats: false) { _ in
            Task { @MainActor in Outage.shared.expireIfDue() }
        }
    }

    private func expireIfDue() {
        endPending = false
        guard let until = policy.until else { return }
        if policy.isActive(now: Date()) {
            // Zwischenzeitlich verlängert oder Timer zu früh – neu planen.
            scheduleTimer(until)
        } else {
            end(reason: "abgelaufen")
        }
    }
}
