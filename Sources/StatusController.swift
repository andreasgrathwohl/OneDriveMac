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
        updateIcon(UserStatus.kind)
    }

    @objc private func stateChanged() {
        updateIcon(UserStatus.kind)
    }

    private func updateIcon(_ kind: UserStatus.Kind) {
        let image = NSImage(systemSymbolName: UserStatus.symbol(kind), accessibilityDescription: "OneDrive Opener")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "OneDrive Opener – \(UserStatus.title(kind))"
    }

    // MARK: - Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let kind = UserStatus.kind
        updateIcon(kind)

        let header = NSMenuItem(title: UserStatus.title(kind), action: #selector(showSettings), keyEquivalent: "")
        header.target = self
        header.attributedTitle = twoLine(UserStatus.title(kind), UserStatus.subtitle(kind))
        header.image = coloredSymbol(UserStatus.symbol(kind), UserStatus.color(kind), size: 22)
        menu.addItem(header)
        if let title = UserStatus.actionTitle(kind) {
            action(menu, title, #selector(performStatusAction))
        }

        if !AppState.recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Zuletzt geöffnet"))
            for (index, recent) in AppState.recent.enumerated() {
                let entry = NSMenuItem(title: recent.url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = index
                entry.attributedTitle = inline(recent.url.lastPathComponent,
                                               recent.online ? "mit AutoSpeichern" : "ohne AutoSpeichern")
                let icon = NSWorkspace.shared.icon(forFile: recent.url.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
                entry.toolTip = "Erneut öffnen · ⌥ gedrückt halten, um ohne AutoSpeichern zu öffnen"
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        action(menu, Settings.enabled ? "Pausieren" : "Fortsetzen", #selector(toggleEnabled))

        menu.addItem(.separator())
        action(menu, "Einstellungen …", #selector(showSettings), key: ",")
        let trouble = NSMenuItem(title: "Fehlerbehebung", action: nil, keyEquivalent: "")
        trouble.submenu = troubleshootingMenu()
        menu.addItem(trouble)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "OneDrive Opener beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func troubleshootingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        action(menu, "Protokoll anzeigen …", #selector(showLog), key: "l")
        action(menu, "Diagnosebericht kopieren", #selector(copyDiagnostics))
        action(menu, "Standard-App jetzt prüfen", #selector(checkNow))
        menu.addItem(.separator())

        let rows = DefaultHandler.statusRows()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        info(menu, "Version \(version)")
        info(menu, "Doppelklick: \(rows.filter(\.isOurs).count) von \(rows.count) Dateitypen")
        info(menu, HandlerGuard.shared.statusText)
        info(menu, "Erkannte OneDrive-Ordner: \(PathResolver.allRoots().count)")
        return menu
    }

    // MARK: - Darstellung

    private func twoLine(_ title: String, _ subtitle: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold),
        ])
        text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    private func inline(_ title: String, _ detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(string: "  " + detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    private func coloredSymbol(_ name: String, _ color: NSColor, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
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

    // MARK: - Aktionen

    @objc private func performStatusAction() {
        let kind = UserStatus.kind
        Task { await UserStatus.performAction(kind) }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard AppState.recent.indices.contains(sender.tag) else { return }
        let url = AppState.recent[sender.tag].url
        let forceLocal = NSEvent.modifierFlags.contains(.option)
        Task { await FileOpener.open(url, forceLocal: forceLocal) }
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        Log.info(Settings.enabled ? "Fortgesetzt" : "Pausiert")
        AppState.changed()
    }

    @objc private func checkNow() {
        Task { await HandlerGuard.shared.check(reason: "manuell", force: true) }
    }

    @objc private func showLog() { actions.log() }
    @objc private func showSettings() { actions.settings() }
    @objc private func copyDiagnostics() { actions.diagnostics() }
}
