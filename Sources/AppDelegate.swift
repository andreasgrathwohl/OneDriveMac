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

        LoginItem.enableOnFirstLaunch()
        HandlerGuard.shared.start()

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
            settingsWindow = makeWindow(title: "OneDrive Opener", size: NSSize(width: 720, height: 720),
                                        content: NSHostingController(rootView: SettingsView(model: model)))
        }
        model.refresh()
        bringToFront(settingsWindow)
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
