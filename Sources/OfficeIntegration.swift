import AppKit

/// Öffnet Word-, Excel- und PowerPoint-Dokumente, die lokal aus einem OneDrive-Ordner geöffnet sind,
/// automatisch mit AutoSpeichern neu – egal ob sie über „Zuletzt verwendet“, das Dock, Spotlight oder
/// „Speichern unter“ in den OneDrive-Ordner dorthin kamen.
///
/// Statt eines Makro-Add-ins fragt die App die Office-App per AppleScript nach den offenen Dokumenten
/// (`full name` ist bei Cloud-Dokumenten eine https-Adresse, sonst ein lokaler Pfad). Dokumente mit
/// ungespeicherten Änderungen werden nie angefasst. Die Online-Adressen der Cloud-Dokumente gehen
/// nebenbei an `SaveMonitor` (Dateigröße bei Speicher-Messungen) und – samt „saved“ – an `SaveGuard`, auch
/// für Office-Apps im Hintergrund (jede Minute).
@MainActor
final class OfficeIntegration {
    static let shared = OfficeIntegration()

    private(set) var status = "aus"
    private var timer: Timer?
    private var surveyTimer: Timer?
    private var busy = false
    private var surveying = false
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
        surveyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in OfficeIntegration.shared.surveyAll() }
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
              !Outage.shared.isActive,  // Störungsbetrieb: nicht automatisch mit AutoSave neu öffnen
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let app = OfficeApp.allCases.first(where: { $0.bundleID == front }),
              !denied.contains(app) else { return }
        busy = true
        Task {
            await check(app)
            busy = false
        }
    }

    /// Offene Cloud-Dokumente aller laufenden Office-Apps an `SaveGuard` – auch, wenn die App nicht vorn ist.
    private func surveyAll() {
        guard Settings.wordIntegration, !surveying else { return }
        let apps = OfficeApp.allCases.filter { app in
            !denied.contains(app)
                && NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).contains { !$0.isTerminated }
        }
        guard !apps.isEmpty else { return }
        surveying = true
        Task {
            for app in apps {
                let result = await AppleScriptRunner.run(Self.listScript(app))
                noteResult(app, result)
                if let output = result.output { SaveGuard.shared.officeDocuments(app, cloud: Self.cloudDocuments(output)) }
            }
            surveying = false
        }
    }

    /// Momentaufnahme der offenen Office-Dokumente für die Ferndiagnose (`DiagnosticCommand`): je Dokument
    /// Name, ob gespeichert, und für Cloud-Dokumente der Sync-Zustand der lokalen Datei.
    func openDocumentsSnapshot() async -> [[String: Any]] {
        var out: [[String: Any]] = []
        // Leer darf nie zweideutig sein: Jede laufende App erscheint, notfalls mit dem Grund, warum nichts kam.
        for app in OfficeApp.allCases
            where NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).contains(where: { !$0.isTerminated }) {
            let result = await AppleScriptRunner.run(Self.listScript(app))
            guard let output = result.output else {
                out.append(["app": app.displayName, "error": result.permissionDenied
                    ? "keine Berechtigung (Systemeinstellungen → Datenschutz & Sicherheit → Automation)"
                    : (result.error ?? "keine Antwort")])
                continue
            }
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(["app": app.displayName, "documents": 0])
                continue
            }
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                var row: [String: Any] = ["app": app.displayName, "name": URL(fileURLWithPath: parts[1]).lastPathComponent,
                                          "saved": parts[2] == "true"]
                if parts[0].lowercased().hasPrefix("https://") {
                    row["cloud"] = true
                    if let file = PathResolver.localFile(forCloudURL: parts[0]) {
                        row["sync_status"] = SyncStatus.current(file).rawValue
                    }
                } else if parts[1].hasPrefix("/") {
                    row["sync_status"] = SyncStatus.current(URL(fileURLWithPath: parts[1])).rawValue
                }
                out.append(row)
            }
        }
        return out.isEmpty ? [["info": "keine Office-App läuft"]] : out
    }

    /// Online-Adresse und „saved“ der Cloud-Dokumente aus der Ausgabe von `listScript`.
    private static func cloudDocuments(_ output: String) -> [(address: String, saved: Bool?)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0].lowercased().hasPrefix("https://") else { return nil }
            let saved: Bool? = parts[2] == "true" ? true : parts[2] == "false" ? false : nil
            return (address: parts[0], saved: saved)
        }
    }

    /// Letzter protokollierter Fehler der Dokumentabfrage je App – damit ein dauerhafter Fehler einmal im
    /// Protokoll (und damit in den Berichten) steht statt still zu bleiben oder alle 3 s zu erscheinen.
    private var lastListError: [OfficeApp: String] = [:]

    private func noteResult(_ app: OfficeApp, _ result: AppleScriptRunner.Result) {
        let error = result.output == nil && !result.permissionDenied ? (result.error ?? "keine Antwort") : nil
        guard lastListError[app] != error else { return }
        lastListError[app] = error
        if let error {
            Log.info("Office-Integration: Dokumente in \(app.displayName) nicht abfragbar: \(error)")
        } else {
            Log.info("Office-Integration: Dokumente in \(app.displayName) wieder abfragbar")
        }
    }

    /// Einzahl der Klasse für „every …“ und Zugriff per Index („document 2“).
    private static func element(_ app: OfficeApp) -> String {
        switch app {
        case .word: return "document"
        case .excel: return "workbook"
        case .powerpoint: return "presentation"
        }
    }

    // „is running“ startet die App nicht – eine gerade beendete App würde sonst neu gestartet.
    // Umwandlung außerhalb von „tell“, damit Begriffe der App wie „tab“/„POSIX path“ nicht überdecken.
    //
    // Namen und „saved“ werden als ganze Liste geholt („full name of every document“), gezählt wird danach in
    // AppleScript selbst. Das frühere „repeat with d in documents“ schickte „count“ an die Office-App – Word
    // (16.115) beantwortet das mit Fehler −1708 („every document versteht count nicht“). Damit sah die
    // Office-Integration in Word nie ein Dokument, und der Speicher-Wächter bekam keine (Ferndiagnose 2026-11-20).
    private static func listScript(_ app: OfficeApp) -> String {
        """
        if application id "\(app.bundleID)" is not running then return ""
        set docNames to {}
        set docStates to {}
        with timeout of 5 seconds
          tell application id "\(app.bundleID)"
            set docNames to full name of every \(element(app))
            try
              set docStates to saved of every \(element(app))
            end try
          end tell
        end timeout
        set resultText to ""
        repeat with i from 1 to (count of docNames)
          set fn to item i of docNames
          set p to fn
          if fn does not start with "http" and fn does not start with "/" then
            try
              set p to POSIX path of fn
            end try
          end if
          set s to "?"
          if (count of docStates) >= i then set s to ((item i of docStates) as text)
          set resultText to resultText & fn & tab & p & tab & s & linefeed
        end repeat
        return resultText
        """
    }

    /// Prüft „saved“ unmittelbar vor dem Schließen erneut – seit der Abfrage könnte getippt worden sein.
    /// Gesucht wird in der Namensliste; geschlossen wird das Dokument an dieser Stelle, nachdem sein Name
    /// noch einmal verglichen wurde (die Reihenfolge könnte sich dazwischen geändert haben).
    private static func closeScript(_ app: OfficeApp, _ fullName: String) -> String {
        let name = AppleScriptRunner.quoted(fullName)
        return """
        if application id "\(app.bundleID)" is not running then return "missing"
        set docNames to {}
        with timeout of 10 seconds
          tell application id "\(app.bundleID)"
            set docNames to full name of every \(element(app))
          end tell
        end timeout
        set idx to 0
        repeat with i from 1 to (count of docNames)
          if (item i of docNames) is \(name) then set idx to i
        end repeat
        if idx is 0 then return "missing"
        with timeout of 10 seconds
          tell application id "\(app.bundleID)"
            set target to \(element(app)) idx
            if (full name of target) is not \(name) then return "missing"
            if not (saved of target) then return "modified"
            close target saving no
          end tell
        end timeout
        return "closed"
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
        noteResult(app, result)
        guard let output = result.output else { return }
        updateStatus()
        SaveGuard.shared.officeDocuments(app, cloud: Self.cloudDocuments(output))

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
