import AppKit

@main
enum Main {
    @MainActor
    static func main() {
        if CLI.run() { exit(0) }

        _ = LogStore.shared
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication.delegate ist weak – Delegate bis zum Ende von run() am Leben halten.
        withExtendedLifetime(delegate) { app.run() }
    }
}
