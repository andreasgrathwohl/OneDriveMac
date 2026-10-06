import Foundation

/// Übersetzt einen lokalen Dateipfad im OneDrive-Ordner in die Web-URL der Datei.
enum PathResolver {
    static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func allRoots() -> [SyncRoot] {
        let manual = Settings.manualMappings.map {
            SyncRoot(localPath: $0.localPath, webURL: $0.webURL, source: "manuell")
        }
        return manual + OneDriveConfig.cachedRoots()
    }

    /// Längster passender Ordner gewinnt; bei gleicher Länge hat die manuelle Zuordnung Vorrang.
    static func resolve(_ file: URL, roots: [SyncRoot]) -> (url: String, root: SyncRoot)? {
        let real = file.standardizedFileURL.resolvingSymlinksInPath()
        let key = normalize(real.path)

        let ordered = roots.map { (root: $0, norm: normalize($0.localPath)) }
            .enumerated()
            .sorted { a, b in
                a.element.norm.count != b.element.norm.count
                    ? a.element.norm.count > b.element.norm.count
                    : a.offset < b.offset
            }
            .map { $0.element }

        for (root, norm) in ordered {
            guard key == norm || key.hasPrefix(norm + "/") else { continue }
            guard let base = encodeBase(root.webURL) else { continue }
            let depth = URL(fileURLWithPath: norm).pathComponents.count
            let components = Array(real.pathComponents.dropFirst(depth))
            var online: [String] = []
            for component in components {
                // Unbekannte Online-Schreibweise: lieber lokal öffnen als eine falsche Adresse erzeugen.
                guard let name = onlineName(component, parent: online.last) else { return nil }
                online.append(name)
            }
            let tail = online.map(encodeSegment).joined(separator: "/")
            return (tail.isEmpty ? base : base + "/" + tail, root)
        }
        return nil
    }

    private static let unknownOnlineCharacters = CharacterSet(charactersIn: "\"*<>?\\|")

    /// Name in OneDrive online: gelernte Schreibweise, sonst bei Sonderzeichen Nachschlagen in der
    /// OneDrive-Datenbank, sonst der lokale Name („:“ bleibt erhalten). `nil` = unbekannt (Datei lokal öffnen).
    /// Ein „/“ im Finder ist auf dem Mac intern ein „:“; beides ist online verboten.
    static func onlineName(_ localName: String, parent: String?) -> String? {
        let local = localName.precomposedStringWithCanonicalMapping
        if let learned = Settings.learnedOnlineNames[local] { return learned }
        guard local.contains(where: { OneDriveDB.forbiddenOnline.contains($0) }) else { return local }
        if let name = OneDriveDB.onlineName(local: local, parent: parent) {
            var learned = Settings.learnedOnlineNames
            learned[local] = name
            Settings.learnedOnlineNames = learned
            let codes = name.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            Log.info("OneDrive-Datenbank: „\(local)“ heißt online „\(name)“ (\(codes))")
            Task { @MainActor in
                Reporter.shared.send(kind: "learned", message: "Online-Schreibweise aus der OneDrive-Datenbank",
                                     details: ["local": local, "online": name, "online_unicode": codes])
            }
            return name
        }
        if local.rangeOfCharacter(from: unknownOnlineCharacters) != nil { return nil }
        // OneDrive behält den Doppelpunkt online (in seiner Datenbank als „&#x3a;“ gespeichert).
        return local
    }

    /// Ohne Nachschlagen (für den Vergleich mit Words Online-Adressen in `PathLearner`).
    static func onlineName(_ localName: String) -> String {
        if let learned = Settings.learnedOnlineNames[localName.precomposedStringWithCanonicalMapping] { return learned }
        return localName
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encodeSegment(_ segment: String) -> String {
        let s = segment.precomposedStringWithCanonicalMapping
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Kodiert den Pfadteil einer (evtl. schon teilweise kodierten) Basis-URL einheitlich.
    static func encodeBase(_ base: String) -> String? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = b.firstIndex(where: { $0 == "?" || $0 == "#" }) { b = String(b[..<cut]) }
        if let forms = b.range(of: "/Forms/", options: .caseInsensitive) { b = String(b[..<forms.lowerBound]) }
        while b.hasSuffix("/") { b.removeLast() }
        guard let schemeEnd = b.range(of: "://") else { return nil }
        guard let slash = b[schemeEnd.upperBound...].firstIndex(of: "/") else { return b }
        let head = String(b[..<slash])
        var segments = b[slash...].split(separator: "/").map { seg -> String in
            let s = String(seg)
            return encodeSegment(s.removingPercentEncoding ?? s)
        }
        // Privates OneDrive: Konto-ID (cid) in Großbuchstaben – so übergibt sie auch
        // OneDrive im Web bei „In Desktop-App öffnen“ an Word.
        if head.lowercased().hasSuffix("://d.docs.live.net"), !segments.isEmpty {
            segments[0] = segments[0].uppercased()
        }
        return head + "/" + segments.joined(separator: "/")
    }
}
