import Foundation
import Security

/// Ferndiagnose über benannte, lesende Bausteine (siehe `docs/superpowers/specs/2026-11-20-...`).
///
/// Ausgelöst über die `requests`-Tabelle: `kind` = Baustein, `arg` = Pfad. Es gibt **keine** freie
/// Befehlsausführung – die Operationen sind fest, und jeder Pfad muss innerhalb eines erkannten
/// OneDrive-Ordners liegen. Nur `synctest` schreibt (eine Testdatei, die es selbst wieder löscht).
enum DiagnosticCommand: String, CaseIterable {
    case inspect
    case list
    case recent
    case officeDocs = "office-docs"
    case synctest

    /// Führt den Baustein aus und liefert das Ergebnis als Bericht-Payload. `arg` ist der Pfad
    /// (nur für `inspect`/`list` nötig, bei `synctest` optional der Zielordner).
    @MainActor
    static func run(_ raw: String, arg: String) async -> (message: String, details: [String: Any])? {
        guard let command = DiagnosticCommand(rawValue: raw) else { return nil }
        var details: [String: Any] = ["command": command.rawValue, "arg": arg]
        let message: String
        switch command {
        case .inspect:
            guard let url = resolveInside(arg) else { return rejected(&details, arg) }
            details["file"] = inspect(url)
            message = "inspect \(url.lastPathComponent)"
        case .list:
            guard let dir = resolveInside(arg) else { return rejected(&details, arg) }
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            details["entries"] = entries.map { inspect($0) }
            message = "list \(dir.lastPathComponent) (\(entries.count))"
        case .recent:
            let formatter = ISO8601DateFormatter()
            details["recent"] = AppState.recent.map { r -> [String: Any] in
                ["name": r.url.lastPathComponent, "online": r.online, "opened": formatter.string(from: r.date)]
            }
            message = "recent (\(AppState.recent.count))"
        case .officeDocs:
            details["office_docs"] = await OfficeIntegration.shared.openDocumentsSnapshot()
            message = "office-docs"
        case .synctest:
            let result = await synctest(folderArg: arg)
            details["synctest"] = result.rows
            details["note"] = result.note
            message = "synctest: \(result.note)"
        }
        Log.info("Ferndiagnose: \(message)")
        return (message, details)
    }

    private static func rejected(_ details: inout [String: Any], _ arg: String) -> (String, [String: Any]) {
        details["rejected"] = "Pfad liegt außerhalb eines erkannten OneDrive-Ordners oder existiert nicht"
        Log.info("Ferndiagnose abgelehnt: \(arg) – außerhalb des OneDrive-Ordners")
        return ("abgelehnt: \(arg)", details)
    }

    /// Löst den Pfad auf und gibt ihn nur zurück, wenn er innerhalb eines `allRoots()`-Ordners liegt
    /// und existiert. Symlinks werden aufgelöst, damit kein Verweis aus dem Ordner herausführt.
    private static func resolveInside(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let key = PathResolver.normalize(url.path)
        for root in PathResolver.allRoots() {
            let norm = PathResolver.normalize(root.localPath)
            if key == norm || key.hasPrefix(norm + "/") { return url }
        }
        return nil
    }

    /// Rohwerte, die macOS zum Sync-Zustand liefert – mehr als `SyncStatus.current`, das sie zu einem
    /// Enum zusammenfasst. Genau diese Felder entscheiden, ob die Erkennung greift.
    @MainActor
    private static func inspect(_ url: URL) -> [String: Any] {
        var out: [String: Any] = ["name": url.lastPathComponent]
        var u = url
        u.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey,
        ]
        if let v = try? u.resourceValues(forKeys: keys) {
            // Explizit entpacken – ein direkt zugewiesenes Optional würde als verschachteltes Optional
            // im JSON landen bzw. den Schlüssel entfernen.
            if let b = v.isUbiquitousItem { out["is_ubiquitous"] = b }
            if let b = v.ubiquitousItemIsUploaded { out["is_uploaded"] = b }
            if let b = v.ubiquitousItemIsUploading { out["is_uploading"] = b }
            if let b = v.ubiquitousItemHasUnresolvedConflicts { out["has_conflicts"] = b }
            if let b = v.isDirectory { out["is_dir"] = b }
            if let size = v.fileSize { out["size_kb"] = size / 1024 }
            if let date = v.contentModificationDate { out["modified"] = ISO8601DateFormatter().string(from: date) }
        }
        out["sync_status"] = SyncStatus.current(url).rawValue
        if let resolved = PathResolver.resolve(url, roots: PathResolver.allRoots()) {
            out["online_url"] = FileOpener.cloudAddress(resolved.url)
            out["mapping"] = resolved.root.source + (resolved.root.isGuess ? " (geschätzt)" : "")
        }
        return out
    }

    /// Legt eine inkompressible ~10-MB-Datei im OneDrive-Ordner an, liest 60 s lang jede Sekunde den
    /// Sync-Zustand und löscht sie wieder. Zeigt, was die App unmittelbar nach dem Anlegen sieht –
    /// und ob und wann daraus „synchronisiert“ wird.
    @MainActor
    private static func synctest(folderArg: String) async -> (rows: [[String: Any]], note: String) {
        let folder = resolveInside(folderArg) ?? PathResolver.allRoots().first.map { URL(fileURLWithPath: $0.localPath) }
        guard let folder, (try? folder.checkResourceIsReachable()) == true else {
            return ([], "kein OneDrive-Ordner gefunden")
        }
        let file = folder.appendingPathComponent("ODO-synctest-\(Int(Date().timeIntervalSince1970)).bin")
        guard let data = randomData(10 * 1024 * 1024) else { return ([], "Testdaten nicht erzeugbar") }
        do { try data.write(to: file) } catch {
            return ([], "Testdatei nicht schreibbar: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        var rows: [[String: Any]] = []
        let start = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for _ in 0..<60 {
            rows.append(["t": formatter.string(from: Date()), "sync": inspect(file)])
            if Date().timeIntervalSince(start) >= 60 { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return (rows, "\(rows.count) Messungen, Datei wieder gelöscht")
    }

    private static func randomData(_ count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return ok == errSecSuccess ? data : nil
    }
}
