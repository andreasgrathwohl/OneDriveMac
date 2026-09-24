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
            Log.info("Nicht in einem bekannten OneDrive-Ordner → lokal")
            openLocally(file, app)
            return
        }
        let web = resolved.url
        let root = resolved.root
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
                launchCloud(web, app: app, fallback: file)
                return
            case .pending, .conflict:
                switch askWhatToDo(file, conflict: state == .conflict) {
                case .local: openLocally(file, app); return
                case .online: launchCloud(web, app: app, fallback: file); return
                case .wait: continue
                case .cancel: return
                }
            }
        }
    }

    static func launchCloud(_ webURL: String, app: OfficeApp, fallback file: URL) {
        let uri = "\(app.scheme):ofe|u|\(webURL)"
        Log.info("Öffne online: \(uri)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [uri]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                AppState.recordOpen(file, online: true)
                return
            }
            Log.error("open beendet mit Status \(process.terminationStatus)")
        } catch {
            Log.error("open fehlgeschlagen: \(error.localizedDescription)")
        }
        openLocally(file, app)
    }

    static func openLocally(_ file: URL, _ app: OfficeApp) {
        guard let appURL = app.applicationURL else {
            showError("Microsoft \(app.displayName) wurde auf diesem Mac nicht gefunden.")
            return
        }
        Log.info("Öffne lokal mit \(app.displayName): \(file.path)")
        AppState.recordOpen(file, online: false)
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
