import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private lazy var model = SettingsModel()
    private var receivedFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        Log.info("Gestartet: \(Bundle.main.bundlePath)")

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

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "OneDrive Opener")
        let menu = NSMenu()
        menu.addItem(withTitle: "Einstellungen …", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Diagnose in Zwischenablage kopieren", action: #selector(copyDiagnostics), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Protokoll anzeigen", action: #selector(showLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "OneDrive Opener beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "OneDrive Opener"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.setContentSize(NSSize(width: 720, height: 680))
            window.center()
            settingsWindow = window
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func copyDiagnostics() {
        model.copyDiagnostics()
    }

    @objc func showLog() {
        let url = Log.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }
}
