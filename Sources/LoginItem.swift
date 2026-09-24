import Foundation
import ServiceManagement

/// Startet die App bei der Anmeldung, damit Dateien sofort umgeleitet werden
/// und die Standard-App-Überwachung dauerhaft läuft.
enum LoginItem {
    private static var agentURL: URL {
        let id = Bundle.main.bundleIdentifier ?? "OneDriveOpener"
        return OneDriveConfig.home.appendingPathComponent("Library/LaunchAgents/\(id).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func set(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                Log.info("Start bei Anmeldung: \(enabled ? "ein" : "aus") (Status \(SMAppService.mainApp.status.rawValue))")
                if enabled, SMAppService.mainApp.status == .requiresApproval {
                    Log.info("Start bei Anmeldung muss in Systemeinstellungen → Anmeldeobjekte erlaubt werden")
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch {
                Log.error("Start bei Anmeldung konnte nicht geändert werden: \(error.localizedDescription)")
            }
            return
        }

        if enabled {
            guard let exec = Bundle.main.executablePath else { return }
            let plist: NSDictionary = [
                "Label": Bundle.main.bundleIdentifier ?? "OneDriveOpener",
                "ProgramArguments": [exec],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if plist.write(to: agentURL, atomically: true) {
                Log.info("Start bei Anmeldung: ein (\(agentURL.path))")
            } else {
                Log.error("LaunchAgent konnte nicht geschrieben werden: \(agentURL.path)")
            }
        } else {
            try? FileManager.default.removeItem(at: agentURL)
            Log.info("Start bei Anmeldung: aus")
        }
    }

    /// Beim ersten Start aus /Applications automatisch einschalten.
    static func enableOnFirstLaunch() {
        guard !Settings.loginItemInitialized, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        Settings.loginItemInitialized = true
        if !isEnabled { set(true) }
    }
}
