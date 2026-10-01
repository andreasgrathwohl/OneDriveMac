import AppKit
import SwiftUI

/// Status in Anwendersprache – gemeinsam für Menüleiste und Einstellungen.
@MainActor
enum UserStatus {
    enum Kind: Equatable {
        case active, openWithOnly, problem, paused, offline
    }

    static var kind: Kind {
        if !Settings.enabled { return .paused }
        if !Connectivity.shared.isOnline { return .offline }
        if AppState.handlerProblem != nil { return .problem }
        let rows = DefaultHandler.statusRows()
        if rows.isEmpty || !rows.allSatisfy(\.isOurs) { return .openWithOnly }
        return .active
    }

    static func title(_ kind: Kind) -> String {
        switch kind {
        case .active: return "Aktiv"
        case .openWithOnly: return "Bereit"
        case .problem: return "Office hat den Doppelklick übernommen"
        case .paused: return "Pausiert"
        case .offline: return "Offline"
        }
    }

    static func subtitle(_ kind: Kind) -> String {
        switch kind {
        case .active: return "Office-Dateien aus OneDrive öffnen mit AutoSpeichern."
        case .openWithOnly: return "Nur über „Öffnen mit“. Ein Doppelklick öffnet Office noch ohne AutoSpeichern."
        case .problem: return "Dateien öffnen per Doppelklick wieder ohne AutoSpeichern."
        case .paused: return "Office-Dateien werden wie gewohnt ohne AutoSpeichern geöffnet."
        case .offline: return "Ohne Internet öffnen Dateien ohne AutoSpeichern. OneDrive lädt Änderungen später hoch."
        }
    }

    static func actionTitle(_ kind: Kind) -> String? {
        switch kind {
        case .active, .offline: return nil
        case .openWithOnly: return "Für Doppelklick aktivieren"
        case .problem: return "Reparieren"
        case .paused: return "Fortsetzen"
        }
    }

    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .active: return "checkmark.icloud"
        case .openWithOnly: return "icloud"
        case .problem: return "exclamationmark.icloud"
        case .paused: return "icloud.slash"
        case .offline: return "wifi.slash"
        }
    }

    static func color(_ kind: Kind) -> NSColor {
        switch kind {
        case .active: return .systemGreen
        case .openWithOnly: return .systemBlue
        case .problem: return .systemOrange
        case .paused, .offline: return .systemGray
        }
    }

    static func performAction(_ kind: Kind) async {
        switch kind {
        case .active, .offline:
            return
        case .paused:
            Settings.enabled = true
            Log.info("Fortgesetzt")
        case .openWithOnly, .problem:
            Settings.keepDefault = true
            let errors = await DefaultHandler.setAsDefault()
            if !errors.isEmpty { Log.error("Als Standard festlegen teilweise fehlgeschlagen: \(errors.joined(separator: "; "))") }
            await HandlerGuard.shared.check(reason: "vom Anwender ausgelöst", force: true)
        }
        AppState.changed()
    }
}

/// Anzeigename und Beschreibung eines OneDrive-Ordners für Anwender.
enum FolderInfo {
    static func name(_ root: SyncRoot) -> String {
        let last = URL(fileURLWithPath: root.localPath).lastPathComponent
        for prefix in ["OneDrive - ", "OneDrive-"] where last.hasPrefix(prefix) {
            let rest = String(last.dropFirst(prefix.count))
            return rest.isEmpty ? "OneDrive" : "OneDrive (\(rest))"
        }
        return last
    }

    static func detail(_ root: SyncRoot) -> String {
        guard let url = URL(string: PathResolver.encodeBase(root.webURL) ?? ""), let host = url.host?.lowercased() else {
            return "Online-Adresse unbekannt"
        }
        if host == "d.docs.live.net" { return "Privates OneDrive" }
        if host.hasSuffix("-my.sharepoint.com") { return "Eigenes OneDrive (Arbeit oder Schule)" }
        let parts = url.pathComponents.filter { $0 != "/" }.map { $0.removingPercentEncoding ?? $0 }
        if let i = parts.firstIndex(where: { $0 == "sites" || $0 == "teams" }), i + 1 < parts.count {
            let library = parts.count > i + 2 ? " · \(parts[(i + 2)...].joined(separator: " › "))" : ""
            return "SharePoint: \(parts[i + 1])\(library)"
        }
        return "SharePoint"
    }
}
