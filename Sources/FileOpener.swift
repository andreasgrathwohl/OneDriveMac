import AppKit

/// Entscheidet pro Datei: online über die Office-URI (AutoSpeichern) oder lokal in Office öffnen.
@MainActor
enum FileOpener {
    private static let waitingPanel = WaitingPanel()

    static func open(_ file: URL, forceLocal: Bool) async {
        Log.info("Öffnen angefordert: \(file.path)")
        guard let app = OfficeApp.forExtension(file.pathExtension) else {
            Log.error("Kein Office-Dateityp: \(file.pathExtension)")
            return
        }

        if forceLocal || !Settings.enabled || file.lastPathComponent.hasPrefix("~$") {
            Log.info("Lokal öffnen (erzwungen/deaktiviert)")
            openLocally(file, app)
            return
        }

        guard let resolved = PathResolver.resolve(file, roots: PathResolver.allRoots()) else {
            Log.info("Keine Online-Adresse bekannt (nicht in OneDrive oder Sonderzeichen im Namen) → lokal")
            openLocally(file, app)
            return
        }
        let web = resolved.url
        let root = resolved.root
        if !Connectivity.shared.isOnline {
            Log.info("Offline – „\(file.lastPathComponent)“ wird lokal geöffnet (AutoSpeichern braucht eine Internetverbindung)")
            openLocally(file, app)
            return
        }
        if root.isGuess && !Settings.useGuessedMappings {
            Log.info("Zuordnung für \(root.localPath) ist nur geschätzt (\(root.source)) → lokal. "
                + "Für AutoSpeichern bitte manuell zuordnen. Vermutete Adresse: \(web)")
            openLocally(file, app)
            return
        }

        while true {
            var state = SyncStatus.current(file)
            if state == .pending {
                waitingPanel.show("OneDrive lädt „\(file.lastPathComponent)“ noch hoch …")
                state = await SyncStatus.waitForUpload(file, timeout: Settings.syncWaitSeconds)
                waitingPanel.hide()
            }
            Log.info("Sync-Status: \(state.rawValue)")

            switch state {
            case .synced, .unknown:
                await launchCloud(web, app: app, fallback: file)
                return
            case .pending, .conflict:
                switch askWhatToDo(file, conflict: state == .conflict) {
                case .local: openLocally(file, app); return
                case .online: await launchCloud(web, app: app, fallback: file); return
                case .wait: continue
                case .cancel: return
                }
            }
        }
    }

    /// Solange Word noch ein zuvor übergebenes Cloud-Dokument lädt, verwirft es weitere Adressen.
    /// Bis dahin (höchstens 70 s, länger als die Kontrolle in `verifyOpened`) wird mit der nächsten Übergabe gewartet.
    private static var wordBusyUntil: Date?
    /// Gehört die Sperre noch zu dieser Übergabe? Eine späte Kontrolle darf nicht die Sperre des nächsten Dokuments aufheben.
    private static var wordBusyToken: UUID?

    static func launchCloud(_ webURL: String, app: OfficeApp, fallback file: URL) async {
        // Beim Kaltstart verwirft Office eine zu früh zugestellte URL: erst starten, dann übergeben.
        await ensureRunning(app)
        if app == .word {
            if let until = wordBusyUntil, until > Date() {
                Log.info("Word lädt noch ein anderes Dokument – „\(file.lastPathComponent)“ wartet")
            }
            while let until = wordBusyUntil, until > Date() {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            wordBusyUntil = Date().addingTimeInterval(70)
            wordBusyToken = UUID()
        }
        guard await handOver(webURL, app: app) else {
            if app == .word { wordBusyUntil = nil }
            openLocally(file, app)
            return
        }
        AppState.recordOpen(file, online: true)
        if app == .word, let token = wordBusyToken { Task { await verifyOpened(file, webURL: webURL, token: token) } }
    }

    /// Übergibt die Online-Adresse auf dem eingestellten Weg an Office.
    private static func handOver(_ webURL: String, app: OfficeApp) async -> Bool {
        let uri = officeURI(app, webURL)
        let method = Settings.openMethod
        Log.info("Öffne online (\(method.title)): \(method == .webURL ? webURL : uri)")
        switch method {
        case .officeURI: return openWithLaunchServices(uri)
        case .appleEvent: return sendGetURL(uri, to: app)
        case .webURL: return await openWebURL(webURL, with: app)
        }
    }

    private static let wordDocumentNamesScript = """
    if application id "com.microsoft.Word" is not running then return ""
    set docNames to {}
    with timeout of 5 seconds
      tell application id "com.microsoft.Word" to set docNames to name of every document
    end timeout
    set AppleScript's text item delimiters to linefeed
    return docNames as text
    """

    /// Prüft, ob Word das Dokument wirklich geöffnet hat. Nach 20 s ohne Dokument wird die Adresse
    /// einmal erneut übergeben; nach 60 s: Fehler melden (mit der erzeugten Adresse) und die Datei
    /// lokal öffnen, damit sie wenigstens ohne AutoSpeichern aufgeht.
    private static func verifyOpened(_ file: URL, webURL: String, token: UUID) async {
        defer {
            if wordBusyToken == token { wordBusyUntil = nil }
        }
        // Word zeigt den Online-Namen, evtl. ohne Endung.
        let online = webURL.split(separator: "/").last.map { String($0).removingPercentEncoding ?? String($0) }
        let names = [file.lastPathComponent, online ?? ""].filter { !$0.isEmpty }.flatMap { n -> [String] in
            let nfc = n.precomposedStringWithCanonicalMapping
            return [nfc, (nfc as NSString).deletingPathExtension]
        }
        for attempt in 1...30 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if attempt == 11 {
                Log.info("„\(file.lastPathComponent)“ ist nach 20 s nicht offen – Adresse wird erneut an Word übergeben")
                _ = await handOver(webURL, app: .word)
            }
            let result = await AppleScriptRunner.run(wordDocumentNamesScript)
            guard !result.permissionDenied, let output = result.output else { return }
            let open = output.split(separator: "\n").map { String($0).precomposedStringWithCanonicalMapping }
            if open.contains(where: { doc in names.contains { doc.caseInsensitiveCompare($0) == .orderedSame } }) {
                return
            }
        }
        Log.error("Word hat „\(file.lastPathComponent)“ nicht geöffnet. Lokaler Pfad: \(file.path) – erzeugte Adresse: \(webURL)")
        openLocally(file, .word)
    }

    /// Office-Adresse wie bei „In Desktop-App öffnen“ in OneDrive im Web. Word für Mac ignoriert die
    /// dokumentierte Kurzform `ms-word:ofe|u|<URL>`; es öffnet das Dokument nur mit `or` (Herkunft),
    /// `ct` (Zeitstempel in ms) und `cid` (Korrelations-ID) und mit `%7C` statt `|` als Trennzeichen –
    /// beides auf einem Mac getestet. Die Werte werden bei jedem Aufruf neu erzeugt.
    static func officeURI(_ app: OfficeApp, _ webURL: String) -> String {
        let fields = [
            "ofe",
            "or", UUID().uuidString.lowercased() + "_0",
            "ct", String(Int64(Date().timeIntervalSince1970 * 1000)),
            "cid", UUID().uuidString.lowercased(),
            "u", webURL,
        ]
        return "\(app.scheme):" + fields.joined(separator: "%7C")
    }

    private static func openWithLaunchServices(_ uri: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [uri]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
            Log.error("open beendet mit Status \(process.terminationStatus)")
        } catch {
            Log.error("open fehlgeschlagen: \(error.localizedDescription)")
        }
        return false
    }

    /// Schickt die Adresse unverändert (ohne URL-Kodierung von „|“) als GetURL-Event an die Office-App.
    private static func sendGetURL(_ uri: String, to app: OfficeApp) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleID)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                                           eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: uri), forKeyword: AEKeyword(keyDirectObject))
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
            return true
        } catch {
            Log.error("Apple Event an \(app.displayName) fehlgeschlagen: \(error.localizedDescription) – "
                + "ggf. unter Systemeinstellungen → Datenschutz & Sicherheit → Automation erlauben")
            return false
        }
    }

    private static func openWebURL(_ webURL: String, with app: OfficeApp) async -> Bool {
        guard let url = URL(string: webURL), let appURL = app.applicationURL else { return false }
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            Log.error("Web-Adresse an \(app.displayName) fehlgeschlagen: \(error.localizedDescription)")
            return false
        }
    }

    private static func runningInstance(_ app: OfficeApp) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first { !$0.isTerminated }
    }

    /// Startet die Office-App, falls nötig, und wartet, bis sie Dokumente annehmen kann.
    private static func ensureRunning(_ app: OfficeApp) async {
        if let running = runningInstance(app), running.isFinishedLaunching { return }
        waitingPanel.show("\(app.displayName) wird gestartet …")
        defer { waitingPanel.hide() }
        if runningInstance(app) == nil {
            guard let appURL = app.applicationURL else { return }
            Log.info("\(app.displayName) läuft noch nicht – wird zuerst gestartet")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 30 {
            if let running = runningInstance(app), running.isFinishedLaunching { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        // Office meldet „fertig“, bevor Anmeldung und Startfenster bereit sind.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        Log.info("\(app.displayName) bereit nach \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
    }

    static func openLocally(_ file: URL, _ app: OfficeApp) {
        guard let appURL = app.applicationURL else {
            showError("Microsoft \(app.displayName) wurde auf diesem Mac nicht gefunden.")
            return
        }
        Log.info("Öffne lokal mit \(app.displayName): \(file.path)")
        AppState.recordOpen(file, online: false)
        WordIntegration.shared.keepLocal(file)
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.error("Lokales Öffnen fehlgeschlagen: \(error.localizedDescription)") }
        }
    }

    private enum Choice { case local, wait, online, cancel }

    private static func askWhatToDo(_ file: URL, conflict: Bool) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if conflict {
            alert.messageText = "„\(file.lastPathComponent)“ hat einen Synchronisierungskonflikt"
            alert.informativeText = "OneDrive konnte zwei Versionen dieser Datei nicht zusammenführen. Klicke auf das OneDrive-Symbol in der Menüleiste, um den Konflikt zu lösen, oder öffne die Datei vorerst ohne AutoSpeichern."
        } else {
            alert.messageText = "„\(file.lastPathComponent)“ wird noch hochgeladen"
            alert.informativeText = "OneDrive hat die letzten Änderungen noch nicht hochgeladen. Wenn du die Datei jetzt mit AutoSpeichern öffnest, fehlen diese Änderungen möglicherweise."
        }
        var choices: [Choice] = [.local]
        alert.addButton(withTitle: "Ohne AutoSpeichern öffnen")
        if !conflict {
            alert.addButton(withTitle: "Weiter warten")
            choices.append(.wait)
        }
        alert.addButton(withTitle: "Trotzdem mit AutoSpeichern öffnen")
        choices.append(.online)
        alert.addButton(withTitle: "Abbrechen")
        choices.append(.cancel)
        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .cancel
    }

    static func showError(_ text: String) {
        Log.error(text)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "OneDrive Opener"
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
final class WaitingPanel {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ text: String) {
        label.stringValue = text
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 70),
                            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
            p.title = "OneDrive Opener"
            p.level = .floating
            p.isReleasedWhenClosed = false
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            label.lineBreakMode = .byTruncatingMiddle
            let stack = NSStackView(views: [spinner, label])
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            stack.spacing = 10
            p.contentView = stack
            panel = p
        }
        panel?.center()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
