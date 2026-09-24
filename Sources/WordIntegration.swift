import AppKit

/// Öffnet Word-Dokumente, die lokal aus einem OneDrive-Ordner geöffnet sind, automatisch mit
/// AutoSpeichern neu – egal ob sie über „Zuletzt verwendet“, das Dock, Spotlight oder
/// „Speichern unter“ in den OneDrive-Ordner dorthin kamen.
///
/// Statt eines Makro-Add-ins fragt die App Word per AppleScript nach den offenen Dokumenten
/// (`full name` ist bei Cloud-Dokumenten eine https-Adresse, sonst ein lokaler Pfad). Dokumente mit
/// ungespeicherten Änderungen werden nie angefasst.
@MainActor
final class WordIntegration {
    static let shared = WordIntegration()

    private(set) var status = "aus"
    private var timer: Timer?
    private var busy = false
    private var denied = false
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
                  app.bundleIdentifier == OfficeApp.word.bundleID else { return }
            Task { @MainActor in WordIntegration.shared.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in WordIntegration.shared.tick() }
        }
        status = Settings.wordIntegration ? "bereit" : "aus"
    }

    /// Gerade dabei, ein Dokument zu schließen und neu zu öffnen.
    var isBusy: Bool { busy }

    /// Diese Datei nicht automatisch neu öffnen, solange sie in Word lokal offen ist.
    func keepLocal(_ file: URL) {
        localOnly[PathResolver.normalize(file.path)] = Date()
    }

    /// Nach dem Ändern der Einstellung erneut versuchen (z. B. nachdem die Berechtigung erteilt wurde).
    func settingsChanged() {
        denied = false
        status = Settings.wordIntegration ? "bereit" : "aus"
    }

    private func tick() {
        guard Settings.wordIntegration, Settings.enabled, !busy, !denied,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == OfficeApp.word.bundleID else { return }
        busy = true
        Task {
            await check()
            busy = false
        }
    }

    // „is running“ startet Word nicht – ein gerade beendetes Word würde sonst neu gestartet.
    // Umwandlung außerhalb von „tell“, damit Words Begriffe „tab“/„POSIX path“ nicht überdecken.
    private static let listScript = """
    if application id "com.microsoft.Word" is not running then return ""
    set docInfos to {}
    with timeout of 5 seconds
      tell application id "com.microsoft.Word"
        repeat with d in documents
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

    /// Prüft „saved“ unmittelbar vor dem Schließen erneut – seit der Abfrage könnte getippt worden sein.
    private static func closeScript(_ fullName: String) -> String {
        """
        if application id "com.microsoft.Word" is not running then return "missing"
        with timeout of 10 seconds
          tell application id "com.microsoft.Word"
            repeat with d in documents
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

    private func check() async {
        let result = await AppleScriptRunner.run(Self.listScript)
        if result.permissionDenied {
            denied = true
            status = "keine Berechtigung – Systemeinstellungen → Datenschutz & Sicherheit → Automation → OneDrive Opener → Microsoft Word erlauben"
            Log.error("Word-Integration: macOS erlaubt OneDrive Opener nicht, Word zu steuern")
            AppState.changed()
            return
        }
        guard let output = result.output else { return }
        status = "aktiv"

        var openLocal = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[1].hasPrefix("/") else { continue }
            let fullName = parts[0]
            let file = URL(fileURLWithPath: parts[1])
            let key = PathResolver.normalize(file.path)
            openLocal.insert(key)

            guard OfficeApp.forExtension(file.pathExtension) == .word,
                  localOnly[key] == nil,
                  parts[2] == "true",
                  let resolved = PathResolver.resolve(file, roots: PathResolver.allRoots()),
                  !resolved.root.isGuess || Settings.useGuessedMappings else { continue }

            if let last = reopenedAt[key], Date().timeIntervalSince(last) < 300 {
                // Kurz nach dem Neuöffnen wieder lokal offen: Office hat die Online-Adresse nicht angenommen.
                localOnly[key] = Date()
                Log.info("Word-Integration: „\(file.lastPathComponent)“ ließ sich nicht mit AutoSpeichern öffnen – bleibt lokal")
                continue
            }

            switch SyncStatus.current(file) {
            case .pending:
                let since = pendingSince[key] ?? Date()
                pendingSince[key] = since
                if Date().timeIntervalSince(since) > 120 {
                    localOnly[key] = Date()
                    Log.info("Word-Integration: „\(file.lastPathComponent)“ wird seit 2 Minuten nicht hochgeladen – bleibt lokal")
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

            let closed = await AppleScriptRunner.run(Self.closeScript(fullName), timeout: 15)
            guard closed.output == "closed" else {
                if closed.output == nil {
                    Log.error("Word-Integration: Schließen fehlgeschlagen: \(closed.error ?? "?")")
                    localOnly[key] = Date()
                }
                continue
            }
            Log.info("Word-Integration: „\(file.lastPathComponent)“ ist lokal geöffnet – wird mit AutoSpeichern neu geöffnet")
            reopenedAt[key] = Date()
            await FileOpener.launchCloud(resolved.url, app: .word, fallback: file)
        }

        // Einträge für Dokumente vergessen, die in Word nicht mehr lokal offen sind.
        let now = Date()
        localOnly = localOnly.filter { openLocal.contains($0.key) || now.timeIntervalSince($0.value) < 300 }
        pendingSince = pendingSince.filter { openLocal.contains($0.key) }
        reopenedAt = reopenedAt.filter { now.timeIntervalSince($0.value) < 300 }
    }
}
