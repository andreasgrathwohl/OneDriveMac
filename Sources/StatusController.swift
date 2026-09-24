import AppKit

/// Symbol in der Menüleiste (oben rechts) mit Status und Menü.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    struct Actions {
        let settings: () -> Void
        let log: () -> Void
        let diagnostics: () -> Void
    }

    private let item: NSStatusItem
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: .appStateChanged, object: nil)
        updateIcon()
    }

    @objc private func stateChanged() {
        updateIcon()
    }

    private func updateIcon() {
        let symbol: String
        let tip: String
        if !Settings.enabled {
            symbol = "icloud.slash"
            tip = "deaktiviert"
        } else if let problem = AppState.handlerProblem {
            symbol = "exclamationmark.icloud"
            tip = problem
        } else {
            symbol = "icloud.and.arrow.up"
            tip = "aktiv"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OneDrive Opener")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "OneDrive Opener – \(tip)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

        info(menu, "OneDrive Opener \(version) läuft")
        info(menu, Settings.enabled ? "Online-Öffnen: aktiv" : "Online-Öffnen: deaktiviert")
        let rows = DefaultHandler.statusRows()
        let ours = rows.filter(\.isOurs).count
        info(menu, "Standard-App: \(ours) von \(rows.count) Dateitypen" + (Settings.keepDefault ? " · überwacht" : ""))
        if let problem = AppState.handlerProblem { info(menu, "⚠︎ \(problem)") }
        info(menu, HandlerGuard.shared.statusText)
        info(menu, "Erkannte OneDrive-Ordner: \(PathResolver.allRoots().count)")
        if let last = AppState.lastOpen {
            let time = DateFormatter.localizedString(from: last.date, dateStyle: .none, timeStyle: .short)
            info(menu, "Zuletzt: \(last.name) (\(last.mode), \(time))")
        }

        menu.addItem(.separator())
        action(menu, "Online-Öffnen aktiv", #selector(toggleEnabled)).state = Settings.enabled ? .on : .off
        action(menu, "Standard-App jetzt prüfen", #selector(checkNow))
        action(menu, "Bei Anmeldung starten", #selector(toggleLogin)).state = LoginItem.isEnabled ? .on : .off

        menu.addItem(.separator())
        action(menu, "Protokoll anzeigen …", #selector(showLog), key: "l")
        action(menu, "Einstellungen …", #selector(showSettings), key: ",")
        action(menu, "Diagnose in Zwischenablage kopieren", #selector(copyDiagnostics))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "OneDrive Opener beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func info(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func action(_ menu: NSMenu, _ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        Log.info("Online-Öffnen \(Settings.enabled ? "aktiviert" : "deaktiviert")")
        AppState.changed()
    }

    @objc private func checkNow() {
        Task { await HandlerGuard.shared.check(reason: "manuell", force: true) }
    }

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func showLog() { actions.log() }
    @objc private func showSettings() { actions.settings() }
    @objc private func copyDiagnostics() { actions.diagnostics() }
}
