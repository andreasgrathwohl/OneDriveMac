import Foundation

/// Ein lokaler OneDrive-/SharePoint-Ordner und die zugehörige Web-Adresse.
struct SyncRoot: Hashable {
    let localPath: String
    let webURL: String
    let source: String
}

/// Liest die Konfiguration des OneDrive-Sync-Clients und leitet daraus ab, welcher lokale Ordner
/// zu welcher Web-URL gehört.
///
/// Das Format ist von Microsoft nicht dokumentiert. Die Logik folgt der erprobten VBA-Implementierung
/// „GetLocalPath“ von Guido Witt-Dörring:
/// https://gist.github.com/guwidoe/038398b6be1b16c458365716a921814d
/// Copyright (c) 2026 Guido Witt-Dörring, MIT-Lizenz – vollständiger Text in THIRD_PARTY_NOTICES.md.
///
/// - `settings/<Konto>/global.ini` → `cid`
/// - `settings/<Konto>/<cid>.ini` → Zeilen `libraryScope`, `libraryFolder`, `AddedScope` (Business)
///   bzw. `library`/`libraryScope` (Personal) mit lokalem Pfad und Sync-ID
/// - `ClientPolicy.ini` / `ClientPolicy_<libID><siteID>[<lnkID>].ini` → `DavUrlNamespace` (Web-URL)
/// - Der in der .ini stehende lokale Pfad stimmt auf dem Mac nicht zuverlässig. Der echte Ordner in
///   ~/Library/CloudStorage wird über die versteckte Datei `.849C9593-…` und deren `guid` (= Sync-ID) gefunden.
///
/// Nicht portiert ist das Lesen der binären `<cid>.dat` (Ordnerbaum). Dadurch werden
/// `libraryFolder`-Einträge und Verknüpfungen („Zu Meine Dateien hinzufügen“) nur dann korrekt erkannt,
/// wenn sie direkt auf oberster Ebene liegen.
enum OneDriveConfig {
    static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    static let syncMarkerName = ".849C9593-D756-4E56-8D6E-42412F2A707B"
    private static let fm = FileManager.default

    static var settingsRoots: [URL] {
        [
            home.appendingPathComponent("Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Application Support/OneDrive/settings"),
            home.appendingPathComponent("Library/Application Support/OneDrive/settings"),
        ].filter { isDirectory($0.path) }
    }

    static var accountDirs: [URL] {
        settingsRoots.flatMap { root -> [URL] in
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return items
                .filter { isDirectory($0.path) && isAccountDirName($0.lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    private static func isAccountDirName(_ name: String) -> Bool {
        if name == "Personal" { return true }
        guard name.hasPrefix("Business") else { return false }
        let n = name.dropFirst("Business".count)
        return n.count == 1 && n.allSatisfy(\.isNumber)
    }

    /// OneDrive-Ordner in ~/Library/CloudStorage (File Provider) und alte Ordner direkt im Benutzerordner.
    static var cloudFolders: [URL] {
        var result: [URL] = []
        for dir in [home.appendingPathComponent("Library/CloudStorage"), home] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            result += items.filter { $0.lastPathComponent.hasPrefix("OneDrive") && isDirectory($0.path) }
        }
        return result
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Cache

    private static var cache: (date: Date, roots: [SyncRoot])?

    static func cachedRoots() -> [SyncRoot] {
        if let cache, Date().timeIntervalSince(cache.date) < 30 { return cache.roots }
        let roots = detect().roots
        cache = (Date(), roots)
        return roots
    }

    static func invalidateCache() { cache = nil }

    // MARK: - Dateien lesen

    /// Auf dem Mac sind die Dateien UTF-8; UTF-16 wird zur Sicherheit ebenfalls erkannt.
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.prefix(200).filter({ $0 == 0 }).count > 20 { return String(data: data, encoding: .utf16LittleEndian) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func readLines(_ url: URL) -> [String]? {
        readText(url)?.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    static func value(of key: String, in lines: [String]) -> String? {
        let prefix = key + " = "
        return lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Zerlegt eine Zeile an Leerzeichen; Felder in Anführungszeichen bleiben zusammen (ohne die Zeichen).
    /// Index 0 ist der Schlüssel, Index 1 das „=“. Wie im VBA-Original endet ein Feld am schließenden
    /// Anführungszeichen, auch wenn direkt danach kein Leerzeichen folgt.
    static func fields(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var started = false
        var inQuote = false
        for ch in line {
            if inQuote {
                if ch == "\"" {
                    inQuote = false
                    result.append(current); current = ""; started = false
                } else {
                    current.append(ch)
                }
            } else if ch == " " {
                if started { result.append(current); current = ""; started = false }
            } else if ch == "\"" && !started {
                inQuote = true
                started = true
            } else {
                current.append(ch)
                started = true
            }
        }
        if started { result.append(current) }
        return result
    }

    static func normalizeID(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
    }

    private static func lastComponent(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        return decoded.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Entfernt abschließende „/“ (wie der Aufräum-Schritt im VBA-Original vor dem Sync-ID-Ersetzen).
    private static func trimSlash(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func join(_ base: String, _ rel: String) -> String {
        let r = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !r.isEmpty else { return base }
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        return b + "/" + r
    }

    // MARK: - ClientPolicy

    struct Policy {
        let file: String
        let dav: String
        let siteID: String
        let webID: String
        let libID: String
    }

    static func loadPolicies(in dir: URL) -> [String: Policy] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var result: [String: Policy] = [:]
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix("ClientPolicy"), url.pathExtension.lowercased() == "ini",
                  let lines = readLines(url),
                  let dav = value(of: "DavUrlNamespace", in: lines)?.trimmingCharacters(in: .whitespaces),
                  !dav.isEmpty else { continue }
            result[name.lowercased()] = Policy(
                file: name, dav: dav,
                siteID: normalizeID(value(of: "SiteID", in: lines) ?? ""),
                webID: normalizeID(value(of: "WebID", in: lines) ?? ""),
                libID: normalizeID(value(of: "IrmLibraryId", in: lines) ?? ""))
        }
        return result
    }

    private static func policy(_ file: String, siteID: String, webID: String, libID: String,
                               in policies: [String: Policy]) -> Policy? {
        if let p = policies[file.lowercased()] { return p }
        let s = normalizeID(siteID), w = normalizeID(webID), l = normalizeID(libID)
        guard !s.isEmpty else { return nil }
        return policies.values.first { $0.siteID == s && $0.webID == w && $0.libID == l }
    }

    // MARK: - Sync-IDs der CloudStorage-Ordner

    private static let guidRegex = try! NSRegularExpression(pattern: "\"guid\"\\s*:\\s*\"([^\"]+)\"")

    static func readSyncID(_ dir: URL) -> String? {
        guard let text = readText(dir.appendingPathComponent(syncMarkerName)) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = guidRegex.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Sync-ID → tatsächlicher Ordner. Ordner ohne Markerdatei (z. B. „SharedLibraries“) enthalten
    /// die Bibliotheken eine Ebene tiefer.
    static func syncDirectories() -> [String: String] {
        var result: [String: String] = [:]
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let folders = (try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix("OneDrive") && isDirectory(folder.path) {
            if let id = readSyncID(folder) {
                result[id.lowercased()] = folder.path
                continue
            }
            let subs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for sub in subs where isDirectory(sub.path) {
                let n = sub.lastPathComponent
                guard !n.hasPrefix(".Trash"), n != "Icon" else { continue }
                if let id = readSyncID(sub) { result[id.lowercased()] = sub.path }
            }
        }
        return result
    }

    // MARK: - Erkennung

    /// `locals`: ein oder mehrere mögliche lokale Pfade (laut .ini), der erste existierende gewinnt.
    struct Entry {
        let account: String
        let locals: [String]
        let web: String
        let syncID: String
        let syncFind: String
        let isMain: Bool
        let source: String
    }

    struct Detection {
        var roots: [SyncRoot] = []
        var notes: [String] = []
    }

    private static func parseBusiness(_ dir: URL, cid: String, notes: inout [String]) -> [Entry] {
        let name = dir.lastPathComponent
        guard let lines = readLines(dir.appendingPathComponent("\(cid).ini")) else {
            notes.append("\(name): \(cid).ini nicht lesbar.")
            return []
        }
        let policies = loadPolicies(in: dir)

        // Die Zeilen stehen nicht immer in der richtigen Reihenfolge; spätere hängen von früheren ab.
        var rows: [[String]] = []
        for tag in ["libraryScope", "libraryFolder", "AddedScope"] {
            rows += lines.filter { $0.hasPrefix(tag + " = ") }
                .map(fields)
                .filter { $0.count > 2 }
                .sorted { (Int($0[2]) ?? .max) < (Int($1[2]) ?? .max) }
        }

        var entries: [Entry] = []
        var mainMount: String?
        var mainSyncID = ""
        var libWeb: [String: String] = [:]

        for f in rows {
            switch f[0] {
            case "libraryScope":
                guard f.count > 16 else { notes.append("\(name): libraryScope-Zeile zu kurz."); continue }
                let libNr = f[2], siteID = f[10], webID = f[11], libID = f[12], locRoot = f[14], syncID = f[16]
                let file = libNr == "0" ? "ClientPolicy.ini" : "ClientPolicy_\(libID)\(siteID).ini"
                guard let p = policy(file, siteID: siteID, webID: webID, libID: libID, in: policies) else {
                    notes.append("\(name): keine ClientPolicy für Bibliothek \(libNr) (\(file)).")
                    continue
                }
                if libNr == "0" {
                    mainMount = locRoot
                    mainSyncID = syncID
                }
                libWeb[libNr] = p.dav
                if !locRoot.isEmpty {
                    entries.append(Entry(account: name, locals: [locRoot], web: p.dav, syncID: syncID,
                                         syncFind: locRoot, isMain: libNr == "0",
                                         source: "\(name): libraryScope \(libNr), \(p.file)"))
                }

            case "libraryFolder":
                guard f.count > 9 else { continue }
                let libNr = f[3], locRoot = f[6], syncID = f[9]
                guard let base = libWeb[libNr], !locRoot.isEmpty else { continue }
                entries.append(Entry(account: name, locals: [locRoot], web: join(base, lastComponent(locRoot)),
                                     syncID: syncID, syncFind: locRoot, isMain: false,
                                     source: "\(name): libraryFolder (Annahme: Ordner direkt in der Bibliothek)"))

            case "AddedScope":
                guard f.count > 11, let mainMount else { continue }
                let siteID = f[7], webID = f[8], libID = f[9], lnkID = f[10]
                let relPath = f[11].trimmingCharacters(in: .whitespaces)
                let file = "ClientPolicy_\(libID)\(siteID)\(lnkID).ini"
                guard let p = policy(file, siteID: siteID, webID: webID, libID: libID, in: policies) else {
                    notes.append("\(name): keine ClientPolicy für Verknüpfung \(file).")
                    continue
                }
                let web = join(p.dav, relPath)
                var names: [String] = []
                for candidate in [lastComponent(relPath), lastComponent(p.dav)] where !candidate.isEmpty && !names.contains(candidate) {
                    names.append(candidate)
                }
                guard !names.isEmpty else { continue }
                entries.append(Entry(account: name, locals: names.map { join(mainMount, $0) }, web: web,
                                     syncID: mainSyncID, syncFind: mainMount, isMain: false,
                                     source: "\(name): Verknüpfung in „Meine Dateien“ (Annahme: oberste Ebene)"))

            default:
                break
            }
        }
        return entries
    }

    private static func parsePersonal(_ dir: URL, cid: String, notes: inout [String]) -> [Entry] {
        let name = dir.lastPathComponent
        guard let lines = readLines(dir.appendingPathComponent("\(cid).ini")) else {
            notes.append("\(name): \(cid).ini nicht lesbar.")
            return []
        }
        var locRoot = ""
        var syncID = ""
        for line in lines {
            let parts = line.components(separatedBy: "\"")
            if line.hasPrefix("library = ") {
                if parts.count > 4 {
                    locRoot = parts[3]
                    let s = parts[4].split(separator: " ", omittingEmptySubsequences: false)
                    syncID = s.count > 2 ? String(s[2]) : ""
                }
                break
            } else if line.hasPrefix("libraryScope = ") {
                if parts.count > 9 {
                    locRoot = parts[9]
                    syncID = parts[7]
                }
                break
            }
        }
        guard !locRoot.isEmpty else {
            notes.append("\(name): kein lokaler Ordner in \(cid).ini.")
            return []
        }

        let webRoot = loadPolicies(in: dir)["clientpolicy.ini"]?.dav ?? "https://d.docs.live.net"
        var entries = [Entry(account: name, locals: [locRoot], web: join(webRoot, cid), syncID: syncID,
                             syncFind: locRoot, isMain: true, source: "\(name): \(cid).ini")]

        // Freigegebene Ordner anderer Personen: je eine Zeile „<id>_BaseUri = …/<cid>!…“ und eine mit dem Pfad.
        if let groupLines = readLines(dir.appendingPathComponent("GroupFolders.ini")) {
            var otherCID: String?
            for line in groupLines {
                if otherCID == nil, line.contains("_BaseUri = ") {
                    guard let slash = line.range(of: "/", options: .backwards),
                          let bang = line.range(of: "!", options: .backwards),
                          slash.upperBound <= bang.lowerBound else { continue }
                    otherCID = line[slash.upperBound..<bang.lowerBound].lowercased()
                } else if let other = otherCID {
                    let relPath = line.components(separatedBy: " = ").dropFirst().joined(separator: " = ")
                    let folder = lastComponent(relPath)
                    if !folder.isEmpty {
                        entries.append(Entry(account: name, locals: [join(locRoot, folder)],
                                             web: join(join(webRoot, other), relPath),
                                             syncID: syncID, syncFind: locRoot, isMain: false,
                                             source: "\(name): GroupFolders.ini (Annahme: oberste Ebene)"))
                    }
                    otherCID = nil
                }
            }
        }
        return entries
    }

    static func detect() -> Detection {
        var det = Detection()
        let syncDirs = syncDirectories()
        var entries: [Entry] = []

        let accounts = accountDirs
        if accounts.isEmpty { det.notes.append("Kein angemeldetes OneDrive-Konto in den Einstellungen gefunden.") }

        for dir in accounts {
            let name = dir.lastPathComponent
            guard let global = readLines(dir.appendingPathComponent("global.ini")),
                  let cid = value(of: "cid", in: global)?.trimmingCharacters(in: .whitespaces), !cid.isEmpty else {
                det.notes.append("\(name): global.ini ohne cid – Konto vermutlich abgemeldet.")
                continue
            }
            entries += name == "Personal"
                ? parsePersonal(dir, cid: cid, notes: &det.notes)
                : parseBusiness(dir, cid: cid, notes: &det.notes)
        }

        var used = Set<String>()
        var resolvedMain = Set<String>()
        var unresolvedMain: [Entry] = []

        for entry in entries {
            let real = syncDirs[entry.syncID.lowercased()]
            let find = trimSlash(entry.syncFind)
            let candidates = entry.locals.map { raw -> String in
                let local = trimSlash(raw)
                guard let real, !find.isEmpty, local.hasPrefix(find) else { return local }
                return real + local.dropFirst(find.count)
            }
            guard let local = candidates.first(where: isDirectory) else {
                if entry.isMain {
                    unresolvedMain.append(entry)
                } else {
                    det.notes.append("Lokaler Ordner nicht gefunden (bitte manuell zuordnen): \(candidates.joined(separator: " | ")) → \(entry.web)")
                }
                continue
            }
            guard used.insert(PathResolver.normalize(local)).inserted else { continue }
            if entry.isMain { resolvedMain.insert(entry.account) }
            det.roots.append(SyncRoot(localPath: local, webURL: trimSlash(entry.web), source: entry.source))
        }

        // Fallback für Hauptordner ohne auflösbare Sync-ID: über den Ordnernamen in ~/Library/CloudStorage.
        var free = cloudFolders.filter { folder in
            let s = folderSuffix(folder)
            return !used.contains(PathResolver.normalize(folder.path))
                && !sharedLibraryMarkers.contains { s.contains($0) }
        }
        let pending = unresolvedMain.filter { !resolvedMain.contains($0.account) }
        let pendingBusiness = pending.filter { $0.account != "Personal" }.count
        for entry in pending {
            var pick: URL?
            if entry.account == "Personal" {
                pick = free.first { personalSuffixes.contains(folderSuffix($0)) }
            } else {
                let business = free.filter { !personalSuffixes.contains(folderSuffix($0)) }
                if pendingBusiness == 1, business.count == 1 { pick = business[0] }
            }
            if let pick {
                free.removeAll { $0 == pick }
                used.insert(PathResolver.normalize(pick.path))
                det.roots.append(SyncRoot(localPath: pick.path, webURL: trimSlash(entry.web), source: entry.source + " (Ordner über Namen zugeordnet)"))
            } else {
                det.notes.append("\(entry.account): Hauptordner nicht gefunden (\(entry.locals.joined())) → \(entry.web). Bitte manuell zuordnen.")
            }
        }
        return det
    }

    private static let personalSuffixes: Set<String> = ["", "persönlich", "personal", "personnel", "personale", "persoonlijk", "personlig"]
    private static let sharedLibraryMarkers = ["sharedlibraries", "freigegebenebibliotheken", "shared libraries", "freigegebene bibliotheken"]

    private static func folderSuffix(_ url: URL) -> String {
        var s = url.lastPathComponent.precomposedStringWithCanonicalMapping
        s.removeFirst("OneDrive".count)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—")).lowercased()
    }

    // MARK: - Diagnose

    static func diagnosticReport() -> String {
        var out: [String] = []
        out.append("OneDrive Opener – Diagnose")
        out.append("Datum: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("App: \(Bundle.main.bundlePath)")

        out.append("")
        out.append("== OneDrive-Ordner (Sync-ID) ==")
        let syncDirs = syncDirectories()
        cloudFolders.forEach { out.append("  \($0.path)  [\(readSyncID($0) ?? "–")]") }
        syncDirs.sorted { $0.value < $1.value }.forEach { out.append("  Sync-ID \($0.key) → \($0.value)") }

        out.append("")
        out.append("== OneDrive-Konfiguration ==")
        let tags = ["library = ", "libraryScope = ", "libraryFolder = ", "AddedScope = "]
        for dir in accountDirs {
            out.append("[\(dir.path)]")
            let global = readLines(dir.appendingPathComponent("global.ini")) ?? []
            let cid = value(of: "cid", in: global) ?? ""
            out.append("  cid = \(cid.isEmpty ? "–" : cid)")
            if !cid.isEmpty, let lines = readLines(dir.appendingPathComponent("\(cid).ini")) {
                for line in lines where tags.contains(where: { line.hasPrefix($0) }) {
                    out.append("  \(String(line.prefix(600)))")
                }
            }
            if let groups = readLines(dir.appendingPathComponent("GroupFolders.ini")) {
                groups.forEach { out.append("  GroupFolders: \($0)") }
            }
            for p in loadPolicies(in: dir).values.sorted(by: { $0.file < $1.file }) {
                out.append("  \(p.file): \(p.dav)  (Site \(p.siteID), Web \(p.webID), Lib \(p.libID))")
            }
        }

        let det = detect()
        out.append("")
        out.append("== Hinweise ==")
        det.notes.forEach { out.append("  \($0)") }
        out.append("")
        out.append("== Automatisch erkannte Zuordnungen ==")
        det.roots.forEach { out.append("  \($0.localPath)\n    → \($0.webURL)\n    (\($0.source))") }
        out.append("")
        out.append("== Manuelle Zuordnungen ==")
        Settings.manualMappings.forEach { out.append("  \($0.localPath)\n    → \($0.webURL)") }
        out.append("")
        out.append("== Standard-Apps ==")
        DefaultHandler.statusRows().forEach { out.append("  .\($0.ext): \($0.handler)") }
        return out.joined(separator: "\n")
    }
}
