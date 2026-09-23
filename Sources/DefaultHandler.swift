import AppKit
import UniformTypeIdentifiers

struct HandlerRow: Hashable {
    let ext: String
    let handler: String
    let isOurs: Bool
}

/// Setzt diese App als Standard-App (Doppelklick) für Office-Dateien bzw. stellt Office wieder her.
enum DefaultHandler {
    static var entries: [(ext: String, app: OfficeApp, type: UTType)] {
        OfficeApp.allCases.flatMap { app in
            app.extensions.compactMap { ext in
                UTType(filenameExtension: ext).map { (ext: ext, app: app, type: $0) }
            }
        }
    }

    static func isOurs(_ appURL: URL?) -> Bool {
        guard let appURL, let id = Bundle(url: appURL)?.bundleIdentifier else { return false }
        return id == Bundle.main.bundleIdentifier
    }

    static func statusRows() -> [HandlerRow] {
        entries.map { e in
            let url = NSWorkspace.shared.urlForApplication(toOpen: e.type)
            let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? "–"
            return HandlerRow(ext: e.ext, handler: name, isOurs: isOurs(url))
        }
    }

    static func setAsDefault() async -> [String] {
        var errors: [String] = []
        let me = Bundle.main.bundleURL
        for e in entries {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: me, toOpen: e.type)
            } catch {
                errors.append(".\(e.ext): \(error.localizedDescription)")
            }
        }
        Log.info("Als Standard-App gesetzt, Fehler: \(errors)")
        return errors
    }

    static func restoreOffice() async -> [String] {
        var errors: [String] = []
        for e in entries {
            guard let appURL = e.app.applicationURL else {
                errors.append(".\(e.ext): Microsoft \(e.app.displayName) nicht gefunden")
                continue
            }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: e.type)
            } catch {
                errors.append(".\(e.ext): \(error.localizedDescription)")
            }
        }
        Log.info("Standard-Apps auf Office zurückgesetzt, Fehler: \(errors)")
        return errors
    }
}
