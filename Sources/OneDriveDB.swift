import Foundation
import SQLite3

/// Schlägt echte Online-Namen in der Datenbank des OneDrive-Clients nach (`SyncEngineDatabase.db` im
/// Einstellungsordner des Kontos, Tabellen `od_ClientFolder_Records.folderName` und
/// `od_ClientFile_Records.fileName`). Gebraucht für Namen, die lokal anders heißen als online –
/// z. B. „2025:26-8c“ (im Finder „2025/26-8c“).
///
/// Gesucht wird ein Eintrag mit gleichem übergeordnetem Ordner, dessen (entschlüsselter) Name gleich ist oder
/// nur an Stellen abweicht, an denen lokal ein online verbotenes Zeichen steht. Nur ein eindeutiger Treffer zählt.
enum OneDriveDB {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static var misses: [String: Date] = [:]

    /// Online verbotene Zeichen – nur an solchen Stellen darf der lokale Name abweichen.
    static let forbiddenOnline = Set(":\"*<>?\\|")

    static func onlineName(local: String, parent: String?) -> String? {
        let local = local.precomposedStringWithCanonicalMapping
        let key = (parent ?? "") + "\u{0}" + local
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        if let miss = misses[key], Date().timeIntervalSince(miss) < 600 { lock.unlock(); return nil }
        lock.unlock()

        var found = Set<String>()
        for db in databases() {
            found.formUnion(withDatabase(db) { candidates($0, local: local, parent: parent) } ?? [])
        }

        lock.lock()
        defer { lock.unlock() }
        guard found.count == 1, let name = found.first else {
            misses[key] = Date()
            Log.info(found.isEmpty
                ? "OneDrive-Datenbank: kein Eintrag für „\(local)“ (Ordner „\(parent ?? "–")“)"
                : "OneDrive-Datenbank: „\(local)“ ist nicht eindeutig (\(found.count) Treffer)")
            return nil
        }
        cache[key] = name
        return name
    }

    static func databases() -> [URL] {
        OneDriveConfig.accountDirs
            .map { $0.appendingPathComponent("SyncEngineDatabase.db") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func looselyEqual(_ local: String, _ online: String) -> Bool {
        let a = Array(local.precomposedStringWithCanonicalMapping.lowercased())
        let b = Array(online.precomposedStringWithCanonicalMapping.lowercased())
        guard a.count == b.count, a != b else { return false }
        return zip(a, b).allSatisfy { x, y in
            x == y || (forbiddenOnline.contains(x) && !(y.isLetter || y.isNumber))
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Öffnet eine Kopie der Datenbank (OneDrive hält das Original offen) und führt `body` damit aus.
    /// Ohne „-shm“: Eine nicht gleichzeitig kopierte Index-Datei kann auf fehlende WAL-Einträge zeigen;
    /// ohne sie baut SQLite den Index aus der „-wal“-Datei neu auf (Prüfsummen, nur vollständige Transaktionen).
    private static func withDatabase<T>(_ db: URL, _ body: (OpaquePointer?) -> T) -> T? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("odo-db-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("db.sqlite")
        for suffix in ["", "-wal"] {
            let source = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: source.path) {
                guard (try? fm.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))) != nil else {
                    Log.info("OneDrive-Datenbank nicht lesbar: \(source.lastPathComponent)")
                    return nil
                }
            }
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        return body(handle)
    }

    /// Für den Diagnosebericht: gefundene Datenbanken, Anzahl Ordner/Dateien und Namen mit Sonderzeichen.
    static func summary() -> [String] {
        let dbs = databases()
        guard !dbs.isEmpty else { return ["keine SyncEngineDatabase.db gefunden"] }
        return dbs.map { db in
            let info = withDatabase(db) { handle -> String in
                let folders = query(handle, "SELECT count(*) FROM od_ClientFolder_Records").first ?? "–"
                let files = query(handle, "SELECT count(*) FROM od_ClientFile_Records").first ?? "–"
                // Ziffern, getrennt durch ein Sonderzeichen (z. B. „2025_26“, „2025:26“) – mit Unicode-Codes.
                let odd = query(handle, """
                    SELECT folderName FROM od_ClientFolder_Records
                    WHERE folderName GLOB '*[0-9][^A-Za-z0-9 .-][0-9]*' AND length(folderName) < 200 LIMIT 40
                    """)
                    .map { name in
                        let codes = name.unicodeScalars.filter { !($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == " ") }
                            .map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
                        return "\(name) [\(codes)]"
                    }
                return "Ordner \(folders), Dateien \(files)" + (odd.isEmpty ? "" : "; Ordner mit Sonderzeichen: " + odd.joined(separator: "; "))
            }
            return "\(db.path): \(info ?? "nicht lesbar")"
        }
    }

    /// Online-Namen, die zu `local` passen: zuerst unterhalb des Ordners `parent`, sonst überall (z. B. direkt
    /// unter dem OneDrive-Stammordner). Die Datenbank speichert manche Zeichen als XML-Entität
    /// (z. B. „2025&#x3a;26-8c“ für „2025:26-8c“) – verglichen wird nach dem Entschlüsseln.
    private static func candidates(_ handle: OpaquePointer?, local: String, parent: String?) -> Set<String> {
        let tables = [("od_ClientFolder_Records", "folderName"), ("od_ClientFile_Records", "fileName")]
        func matching(_ rows: [String]) -> Set<String> {
            Set(rows.map(decodeEntities).filter { matches(local, $0) })
        }
        var found = Set<String>()
        if let parent {
            for (table, column) in tables {
                found.formUnion(matching(query(handle, """
                    SELECT c.\(column) FROM \(table) c JOIN od_ClientFolder_Records p ON c.parentResourceID = p.resourceID
                    WHERE p.folderName IN (?1, ?2)
                    """, parent: parent, encodedParent: encodeEntities(parent))))
            }
        }
        if found.isEmpty {
            // SQLite zählt Unicode-Codepunkte – erlaubt ist die Länge in NFC bis NFD; kodierte Namen sind länger.
            let nfc = local.precomposedStringWithCanonicalMapping.unicodeScalars.count
            let lengths = nfc...max(nfc, local.decomposedStringWithCanonicalMapping.unicodeScalars.count)
            for (table, column) in tables {
                found.formUnion(matching(query(handle, """
                    SELECT \(column) FROM \(table) WHERE instr(\(column), '&#') > 0 OR length(\(column)) BETWEEN ?3 AND ?4
                    """, lengths: lengths)))
            }
        }
        return found
    }

    /// Gleich (ohne Groß-/Kleinschreibung) oder nur an online verbotenen Stellen abweichend.
    private static func matches(_ local: String, _ online: String) -> Bool {
        local.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(online.precomposedStringWithCanonicalMapping) == .orderedSame
            || looselyEqual(local, online)
    }

    /// „&#x3a;“, „&#58;“, „&amp;“ … → Zeichen.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: Unicode.Scalar] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
        var result = String.UnicodeScalarView()
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result.append(contentsOf: rest[..<amp].unicodeScalars)
            let afterAmp = rest.index(after: amp)
            if let semi = rest[afterAmp...].prefix(10).firstIndex(of: ";") {
                let entity = String(rest[afterAmp..<semi])
                var scalar: Unicode.Scalar?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst(), radix: 10).flatMap { Unicode.Scalar($0) }
                } else {
                    scalar = named[entity]
                }
                if let scalar {
                    result.append(scalar)
                    rest = rest[rest.index(after: semi)...]
                    continue
                }
            }
            result.append("&")
            rest = rest[afterAmp...]
        }
        result.append(contentsOf: rest.unicodeScalars)
        return String(result)
    }

    /// Gegenstück für die Suche nach einem übergeordneten Ordner („:“ → „&#x3a;“).
    static func encodeEntities(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            forbiddenOnline.contains(Character(scalar)) ? String(format: "&#x%x;", scalar.value) : String(scalar)
        }.joined()
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, parent: String? = nil,
                              encodedParent: String? = nil, lengths: ClosedRange<Int>? = nil) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Log.info("OneDrive-Datenbank: Abfrage fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        if let parent { sqlite3_bind_text(statement, 1, parent, -1, transient) }
        if let encodedParent { sqlite3_bind_text(statement, 2, encodedParent, -1, transient) }
        if let lengths {
            sqlite3_bind_int(statement, 3, Int32(lengths.lowerBound))
            sqlite3_bind_int(statement, 4, Int32(lengths.upperBound))
        }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
        }
        return rows
    }
}
