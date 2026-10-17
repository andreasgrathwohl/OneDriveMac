import AppKit

/// Überwacht, ob die OneDrive-App arbeiten kann: läuft sie, ist ein OneDrive-Ordner eingerichtet, ist
/// genug Speicher frei und kommen lokal gespeicherte Dateien wirklich hoch? Ob OneDrive pausiert ist,
/// verrät die App nicht direkt – das zeigt sich daran, dass Uploads hängen bleiben. Probleme erscheinen
/// in der Menüleiste (`UserStatus`) und gehen als Bericht `onedrive_health` an den Server.
@MainActor
final class OneDriveHealth {
    static let shared = OneDriveHealth()

    enum Problem {
        case notRunning
        case noFolder
        case lowDisk(gigabytes: Double)
        case uploadStuck(file: String, minutes: Int)

        /// Gleiches Problem (unabhängig von Minuten/Gigabytes) – nur bei einem Wechsel wird gemeldet.
        var id: String {
            switch self {
            case .notRunning: return "notRunning"
            case .noFolder: return "noFolder"
            case .lowDisk: return "lowDisk"
            case .uploadStuck(let file, _): return "uploadStuck:" + file
            }
        }

        var title: String {
            switch self {
            case .notRunning: return "OneDrive läuft nicht"
            case .noFolder: return "OneDrive ist nicht eingerichtet"
            case .lowDisk: return "Speicher auf dem Mac fast voll"
            case .uploadStuck: return "OneDrive lädt nicht hoch"
            }
        }

        var subtitle: String {
            switch self {
            case .notRunning:
                return "Dateien im OneDrive-Ordner werden nicht abgeglichen – der Finder zeigt evtl. alte Stände."
            case .noFolder:
                return "Kein OneDrive-Ordner gefunden. Bitte in der OneDrive-App anmelden."
            case .lowDisk(let gigabytes):
                return String(format: "Nur noch %.1f GB frei – OneDrive kann keine Dateien mehr herunterladen.", gigabytes)
            case .uploadStuck(let file, let minutes):
                return "„\(file)“ wartet seit \(minutes) Min. auf das Hochladen. Ist OneDrive pausiert? Klicke auf das OneDrive-Symbol in der Menüleiste."
            }
        }

        var actionTitle: String? {
            switch self {
            case .notRunning: return "OneDrive starten"
            case .noFolder, .uploadStuck: return "OneDrive öffnen"
            case .lowDisk: return nil
            }
        }
    }

    nonisolated static let bundleIDs = ["com.microsoft.OneDrive", "com.microsoft.OneDrive-mac"]

    private(set) var problem: Problem?
    private var timer: Timer?
    private var notRunningSince: Date?
    private var noFolderSince: Date?
    /// Lokal geöffnete OneDrive-Dateien → wann zuerst gesehen.
    private var watched: [URL: Date] = [:]
    private var pendingSince: [URL: Date] = [:]

    private init() {}

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in OneDriveHealth.shared.check() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier, OneDriveHealth.bundleIDs.contains(id) else { return }
                Task { @MainActor in OneDriveHealth.shared.check() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            Task { @MainActor in OneDriveHealth.shared.check() }
        }
    }

    /// Lokal geöffnete Datei beobachten: bleibt ihr Upload hängen, stimmt mit OneDrive etwas nicht.
    func watch(_ file: URL) {
        guard watched[file] == nil else { return }
        let key = PathResolver.normalize(file.path)
        guard PathResolver.allRoots().contains(where: { key.hasPrefix(PathResolver.normalize($0.localPath) + "/") }) else { return }
        watched[file] = Date()
        if watched.count > 50, let oldest = watched.min(by: { $0.value < $1.value })?.key {
            watched[oldest] = nil
            pendingSince[oldest] = nil
        }
    }

    var statusText: String {
        guard let problem else { return installedAppURL == nil ? "nicht installiert" : "in Ordnung" }
        return problem.title
    }

    func performAction() {
        guard let url = installedAppURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { Log.info("OneDrive konnte nicht geöffnet werden: \(error.localizedDescription)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            Task { @MainActor in OneDriveHealth.shared.check() }
        }
    }

    private var installedAppURL: URL? {
        Self.bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    private var isRunning: Bool {
        Self.bundleIDs.contains { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
        }
    }

    func check() {
        let now = Date()
        var found: Problem?
        // Ohne installierte OneDrive-App (z. B. nur eigene Zuordnungen) gibt es nichts zu überwachen.
        if installedAppURL != nil {
            let running = isRunning
            if running {
                notRunningSince = nil
            } else {
                // Nach der Anmeldung startet OneDrive oft erst etwas später.
                let since = notRunningSince ?? now
                notRunningSince = since
                if now.timeIntervalSince(since) >= 180 { found = .notRunning }
            }
            if running && OneDriveConfig.cloudFolders.isEmpty {
                let since = noFolderSince ?? now
                noFolderSince = since
                if found == nil, now.timeIntervalSince(since) >= 300 { found = .noFolder }
            } else {
                noFolderSince = nil
            }
        }
        if found == nil, let free = freeGigabytes(), free < 2 { found = .lowDisk(gigabytes: free) }
        if found == nil, let stuck = stuckUpload(now) { found = stuck }
        apply(found)
    }

    private func freeGigabytes() -> Double? {
        let values = try? OneDriveConfig.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(bytes) / 1_000_000_000
    }

    private func stuckUpload(_ now: Date) -> Problem? {
        // Ohne Internet ist Warten normal.
        guard Connectivity.shared.isOnline else {
            pendingSince = [:]
            return nil
        }
        var oldest: (file: URL, since: Date)?
        for (file, added) in watched {
            if SyncStatus.current(file) == .pending {
                let since = pendingSince[file] ?? now
                pendingSince[file] = since
                if now.timeIntervalSince(since) >= 900, oldest.map({ since < $0.since }) ?? true {
                    oldest = (file: file, since: since)
                }
            } else {
                pendingSince[file] = nil
                if now.timeIntervalSince(added) > 86_400 { watched[file] = nil }
            }
        }
        guard let oldest else { return nil }
        return .uploadStuck(file: oldest.file.lastPathComponent, minutes: Int(now.timeIntervalSince(oldest.since) / 60))
    }

    private func apply(_ new: Problem?) {
        let before = problem
        problem = new
        if before?.id != new?.id {
            if let new {
                Log.info("OneDrive: \(new.title) – \(new.subtitle)")
                Reporter.shared.send(kind: "onedrive_health", message: new.title, details: [
                    "detail": new.subtitle,
                    "network": Connectivity.shared.networkDescription,
                    "onedrive_folders": OneDriveConfig.cloudFolders.map(\.lastPathComponent).joined(separator: ", "),
                ])
            } else if let before {
                Log.info("OneDrive: wieder in Ordnung (vorher: \(before.title))")
                Reporter.shared.send(kind: "onedrive_health", message: "wieder in Ordnung", details: ["before": before.title])
            }
        }
        if before?.subtitle != new?.subtitle { AppState.changed() }
    }
}
