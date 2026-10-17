import AppKit

/// Öffnet Word-, Excel- und PowerPoint-Dokumente, die lokal aus einem OneDrive-Ordner geöffnet sind,
/// automatisch mit AutoSpeichern neu – egal ob sie über „Zuletzt verwendet“, das Dock, Spotlight oder
/// „Speichern unter“ in den OneDrive-Ordner dorthin kamen.
///
/// Statt eines Makro-Add-ins fragt die App die Office-App per AppleScript nach den offenen Dokumenten
/// (`full name` ist bei Cloud-Dokumenten eine https-Adresse, sonst ein lokaler Pfad). Dokumente mit
/// ungespeicherten Änderungen werden nie angefasst. Die Online-Adressen der Cloud-Dokumente gehen
/// nebenbei an `SaveMonitor` (Dateigröße bei Speicher-Messungen).
@MainActor
final class OfficeIntegration {
    static let shared = OfficeIntegration()

    private(set) var status = "aus"
    private var timer: Timer?
    private var busy = false
    private var denied = Set<OfficeApp>()
    /// Pfade, die bewusst lokal bleiben sollen (⌥-Öffnen, „Ohne AutoSpeichern öffnen“, Fehlschlag).
    private var localOnly: [String: Date] = [:]
    private var reopenedAt: [String: Date] = [:]
    private var pendingSince: [String: Date] = [:]

    private init() {}

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  OfficeApp.allCases.contains(where: { $0.bundleID == app.bundleIdentifier }) else { return }
            Task { @MainActor in OfficeIntegration.shared.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in OfficeIntegration.shared.tick() }
        }
        updateStatus()
    }

    /// Gerade dabei, ein Dokument zu schließen und neu zu öffnen.
    var isBusy: Bool { busy }

    /// Diese Datei nicht automatisch neu öffnen, solange sie in Office lokal offen ist.
    func keepLocal(_ file: URL) {
        localOnly[PathResolver.normalize(file.path)] = Date()
    }

    /// Nach dem Ändern der Einstellung erneut versuchen (z. B. nachdem die Berechtigung erteilt wurde).
    func settingsChanged() {
        denied = []
        updateStatus()
    }

    private func updateStatus() {
        let text: String
        if !Settings.wordIntegration {
            text = "aus"
        } else if !denied.isEmpty {
            let names = OfficeApp.allCases.filter { denied.contains($0) }.map { "Microsoft \($0.displayName)" }
            text = "keine Berechtigung – Systemeinstellungen → Datenschutz & Sicherheit → Automation → OneDrive Opener → "
                + names.joined(separator: ", ") + " erlauben"
        } else {
            text = "aktiv"
        }
        if text != status {
            status = text
            AppState.changed()
        }
    }

    private func tick() {
        guard Settings.wordIntegration, Settings.enabled, !busy, Connectivity.shared.isOnline,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let app = OfficeApp.allCases.first(where: { $0.bundleID == front }),
              !denied.contains(app) else { return }
        busy = true
        Task {
            await check(app)
            busy = false
        }
    }

    /// AppleScript-Klasse der Dokumente in der jeweiligen App.
    private static func collection(_ app: OfficeApp) -> String {
        switch app {
        case .word: return "documents"
        case .excel: return "workbooks"
        case .powerpoint: return "presentations"
        }
    }

    // „is running“ startet die App nicht – eine gerade beendete App würde sonst neu gestartet.
    // Umwandlung außerhalb von „tell“, damit Begriffe der App wie „tab“/„POSIX path“ nicht überdecken.
    private static func listScript(_ app: OfficeApp) -> String {
        """
        if application id "\(app.bundleID)" is not running then return ""
        set docInfos to {}
        with timeout of 5 seconds
          tell application id "\(app.bundleID)"
            repeat with d in \(collection(app))
              set end of docInfos to {full name of d, saved of d}
            end repeat
          end tell
        end timeout
        set resultText to ""
        repeat with e in docInfos
          set fn to item 1 of e
          set p to fn
          if fn does not start with "http" and fn does not start with "/" then
            try
              set p to POSIX path of fn
            end try
          end if
          set resultText to resultText & fn & tab & p & tab & ((item 2 of e) as text) & linefeed
        end repeat
        return resultText
        """
    }

    /// Prüft „saved“ unmittelbar vor dem Schließen erneut – seit der Abfrage könnte getippt worden sein.
    private static func closeScript(_ app: OfficeApp, _ fullName: String) -> String {
        """
        if application id "\(app.bundleID)" is not running then return "missing"
        with timeout of 10 seconds
          tell application id "\(app.bundleID)"
            repeat with d in \(collection(app))
              if (full name of d) is \(AppleScriptRunner.quoted(fullName)) then
                if not (saved of d) then return "modified"
                close d saving no
                return "closed"
              end if
            end repeat
          end tell
        end timeout
        return "missing"
        """
    }

    private func check(_ app: OfficeApp) async {
        let result = await AppleScriptRunner.run(Self.listScript(app))
        if result.permissionDenied {
            denied.insert(app)
            Log.error("Office-Integration: macOS erlaubt OneDrive Opener nicht, \(app.displayName) zu steuern")
            updateStatus()
            return
        }
        guard let output = result.output else { return }
        updateStatus()

        var openLocal = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3, parts[0].lowercased().hasPrefix("https://") {
                PathLearner.learn(fromCloudURL: parts[0])
                SaveMonitor.shared.noteCloudDocument(parts[0])
                continue
            }
            guard parts.count == 3, parts[1].hasPrefix("/") else { continue }
            let fullName = parts[0]
            let file = URL(fileURLWithPath: parts[1])
            let key = PathResolver.normalize(file.path)
            openLocal.insert(key)
            OneDriveHealth.shared.watch(file)

            guard OfficeApp.forExtension(file.pathExtension) == app,
                  localOnly[key] == nil,
                  parts[2] == "true",
                  let resolved = PathResolver.resolve(file, roots: PathResolver.allRoots()),
                  !resolved.root.isGuess || Settings.useGuessedMappings else { continue }

            if let last = reopenedAt[key], Date().timeIntervalSince(last) < 300 {
                // Kurz nach dem Neuöffnen wieder lokal offen: Office hat die Online-Adresse nicht angenommen.
                localOnly[key] = Date()
                Log.info("Office-Integration: „\(file.lastPathComponent)“ ließ sich nicht mit AutoSpeichern öffnen – bleibt lokal")
                continue
            }

            switch SyncStatus.current(file) {
            case .pending:
                let since = pendingSince[key] ?? Date()
                pendingSince[key] = since
                if Date().timeIntervalSince(since) > 120 {
                    localOnly[key] = Date()
                    Log.info("Office-Integration: „\(file.lastPathComponent)“ wird seit 2 Minuten nicht hochgeladen – bleibt lokal")
                }
                continue
            case .conflict:
                localOnly[key] = Date()
                continue
            case .unknown:
                // Ohne Sync-Status: frisch gespeicherte Datei ist evtl. noch nicht online.
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if Date().timeIntervalSince(modified ?? .distantPast) < 60 { continue }
            case .synced:
                break
            }
            pendingSince[key] = nil

            let closed = await AppleScriptRunner.run(Self.closeScript(app, fullName), timeout: 15)
            guard closed.output == "closed" else {
                if closed.output == nil {
                    Log.error("Office-Integration: Schließen in \(app.displayName) fehlgeschlagen: \(closed.error ?? "?")")
                    localOnly[key] = Date()
                }
                continue
            }
            Log.info("Office-Integration: „\(file.lastPathComponent)“ ist in \(app.displayName) lokal geöffnet – wird mit AutoSpeichern neu geöffnet")
            reopenedAt[key] = Date()
            await FileOpener.launchCloud(resolved.url, app: app, fallback: file)
        }

        // Einträge für Dokumente vergessen, die nicht mehr lokal offen sind (nur für diese App prüfbar).
        let now = Date()
        let ofThisApp = { (path: String) in OfficeApp.forExtension(URL(fileURLWithPath: path).pathExtension) == app }
        localOnly = localOnly.filter { !ofThisApp($0.key) || openLocal.contains($0.key) || now.timeIntervalSince($0.value) < 300 }
        pendingSince = pendingSince.filter { !ofThisApp($0.key) || openLocal.contains($0.key) }
        reopenedAt = reopenedAt.filter { now.timeIntervalSince($0.value) < 300 }
    }
}
