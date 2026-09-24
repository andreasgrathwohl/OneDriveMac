import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController?
    private var settingsWindow: NSWindow?
    private var logWindow: NSWindow?
    private lazy var model = SettingsModel(openLog: { [weak self] in self?.showLog() })
    private var receivedFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusController(actions: .init(
            settings: { [weak self] in self?.showSettings() },
            log: { [weak self] in self?.showLog() },
            diagnostics: { [weak self] in self?.model.copyDiagnostics() }))
        Log.info("Gestartet: \(Bundle.main.bundlePath)")

        HandlerGuard.shared.start()
        // Das Neu-Signieren beim Übernehmen der Office-Symbole setzt Berechtigungen zurück –
        // deshalb vor dem Anmelden als Startobjekt erledigen.
        Task {
            await Task.detached(priority: .utility) { OfficeIcons.install() }.value
            LoginItem.enableOnFirstLaunch()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.receivedFiles, !Settings.didShowOnboarding else { return }
            Settings.didShowOnboarding = true
            self.showSettings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedFiles = true
        let forceLocal = NSEvent.modifierFlags.contains(.option)
        Task { @MainActor in
            for url in urls {
                await FileOpener.open(url, forceLocal: forceLocal)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        model.refresh()
        bringToFront(settingsWindow)
    }

    /// Einstellungsfenster im macOS-Stil: Reiter als Symbolleiste, Fenstertitel = Reitername.
    private func makeSettingsWindow() -> NSWindow {
        let size = NSSize(width: 620, height: 560)
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
            let controller = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(tab("Allgemein", "gearshape", GeneralTab(model: model)))
        tabs.addTabViewItem(tab("Ordner", "folder", FoldersTab(model: model)))
        tabs.addTabViewItem(tab("Fehlerbehebung", "stethoscope", TroubleshootingTab(model: model)))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        if #available(macOS 11.0, *) { window.toolbarStyle = .preference }
        window.setContentSize(size)
        window.center()
        return window
    }

    func showLog() {
        if logWindow == nil {
            logWindow = makeWindow(title: "OneDrive Opener – Protokoll", size: NSSize(width: 860, height: 520),
                                   content: NSHostingController(rootView: LogView(store: LogStore.shared)))
        }
        bringToFront(logWindow)
    }

    private func makeWindow(title: String, size: NSSize, content: NSViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.setContentSize(size)
        window.center()
        return window
    }

    private func bringToFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
