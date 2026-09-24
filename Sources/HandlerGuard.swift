import AppKit
import CoreServices

/// Apps, deren Start/Ende auf ein Office-Update hindeutet und eine Prüfung auslöst.
private let updateTriggerBundleIDs: Set<String> = Set(OfficeApp.allCases.map(\.bundleID)).union([
    "com.microsoft.autoupdate2",
    "com.microsoft.autoupdate.fba",
    "com.apple.installer",
])

/// Überwacht, ob OneDrive Opener Standard-App bleibt. Office-Updates (und Office selbst beim Start)
/// können die Zuordnung zurückholen – dann wird sie wiederhergestellt.
@MainActor
final class HandlerGuard {
    static let shared = HandlerGuard()

    private(set) var lastCheck: Date?
    private(set) var lastResult = "noch nicht geprüft"

    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var running = false
    private var lastFailure: Date?

    private init() {}

    func start() {
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)

        let nc = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.didLaunchApplicationNotification, "gestartet"),
            (NSWorkspace.didTerminateApplicationNotification, "beendet"),
        ]
        for (name, verb) in events {
            nc.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier, updateTriggerBundleIDs.contains(id) else { return }
                let reason = "\(app.localizedName ?? id) \(verb)"
                Task { @MainActor in HandlerGuard.shared.schedule(reason) }
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in HandlerGuard.shared.schedule("Ruhezustand beendet") }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in await HandlerGuard.shared.check(reason: "Intervall", force: false) }
        }
        schedule("Programmstart", delay: 3)
    }

    /// Bündelt mehrere Ereignisse (ein Update beendet/startet mehrere Apps) zu einer Prüfung.
    func schedule(_ reason: String, delay: TimeInterval = 5) {
        pending?.cancel()
        let work = DispatchWorkItem {
            Task { @MainActor in await HandlerGuard.shared.check(reason: reason, force: true) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var statusText: String {
        guard let lastCheck else { return "Überwachung: \(lastResult)" }
        let time = DateFormatter.localizedString(from: lastCheck, dateStyle: .none, timeStyle: .short)
        return "Überwachung: \(lastResult) (geprüft \(time))"
    }

    /// `force: false` (Intervall) versucht nach einem Fehlschlag erst nach 30 Minuten erneut,
    /// damit bei einer verweigerten Änderung nicht ständig Dialoge erscheinen.
    func check(reason: String, force: Bool) async {
        guard !running else { return }
        running = true
        defer {
            running = false
            AppState.changed()
        }

        detectOfficeUpdate()
        lastCheck = Date()

        guard Settings.keepDefault else {
            lastResult = "aus"
            setProblem(nil)
            return
        }

        let lost = DefaultHandler.statusRows().filter { !$0.isOurs }
        guard !lost.isEmpty else {
            lastResult = "OK"
            lastFailure = nil
            setProblem(nil)
            return
        }
        if !force, let lastFailure, Date().timeIntervalSince(lastFailure) < 1800 { return }

        let description = lost.map { ".\($0.ext) → \($0.handler)" }.joined(separator: ", ")
        Log.info("Standard-App-Zuordnung wurde geändert (\(reason)): \(description) – wird wiederhergestellt")
        let errors = await DefaultHandler.setAsDefault(extensions: Set(lost.map(\.ext)))
        // Während des Wartens ausgeschaltet („Zurück auf Office“) – kein Fehler melden.
        guard Settings.keepDefault else {
            lastResult = "aus"
            setProblem(nil)
            return
        }

        let still = DefaultHandler.statusRows().filter { !$0.isOurs }
        if still.isEmpty {
            lastResult = "wiederhergestellt"
            lastFailure = nil
            setProblem(nil)
            Log.info("Standard-App-Zuordnung wiederhergestellt")
        } else {
            let types = still.map { ".\($0.ext)" }.joined(separator: ", ")
            lastResult = "Fehler bei \(types)"
            lastFailure = Date()
            setProblem("Standard-App fehlt für \(types)")
            Log.error("Wiederherstellen fehlgeschlagen für \(types): \(errors.joined(separator: "; "))")
        }
    }

    private func setProblem(_ problem: String?) {
        guard AppState.handlerProblem != problem else { return }
        AppState.handlerProblem = problem
        AppState.changed()
    }

    /// Erkennt Office-Updates anhand der Versionsnummern und meldet die eigene App danach
    /// neu bei Launch Services an.
    private func detectOfficeUpdate() {
        var current: [String: String] = [:]
        for app in OfficeApp.allCases {
            guard let url = app.applicationURL,
                  let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let version = info["CFBundleShortVersionString"] as? String else { continue }
            current[app.displayName] = version
        }
        let old = Settings.officeVersions
        var updated = false
        for name in current.keys.sorted() {
            guard let before = old[name], let now = current[name], before != now else { continue }
            Log.info("Office-Update erkannt: \(name) \(before) → \(now)")
            updated = true
        }
        if current != old { Settings.officeVersions = current }
        if updated { _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true) }
    }
}

/// Gemeinsamer Zustand für das Menüleisten-Symbol.
@MainActor
enum AppState {
    struct RecentFile {
        let url: URL
        let online: Bool
        let date: Date
    }

    static var handlerProblem: String?
    private(set) static var recent: [RecentFile] = []

    static func recordOpen(_ file: URL, online: Bool) {
        recent.removeAll { $0.url == file }
        recent.insert(RecentFile(url: file, online: online, date: Date()), at: 0)
        if recent.count > 5 { recent.removeLast(recent.count - 5) }
        changed()
    }

    static func changed() {
        NotificationCenter.default.post(name: .appStateChanged, object: nil)
    }
}

extension Notification.Name {
    static let appStateChanged = Notification.Name("OneDriveOpener.appStateChanged")
}
