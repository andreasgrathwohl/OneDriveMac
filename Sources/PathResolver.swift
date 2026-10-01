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
            // Online verbotene Zeichen, deren Umsetzung durch OneDrive nicht bekannt ist: lieber lokal öffnen.
            let learned = Settings.learnedOnlineNames
            if components.contains(where: {
                learned[$0.precomposedStringWithCanonicalMapping] == nil && $0.rangeOfCharacter(from: unknownOnlineCharacters) != nil
            }) { return nil }
            let tail = components.map { encodeSegment(onlineName($0)) }.joined(separator: "/")
            return (tail.isEmpty ? base : base + "/" + tail, root)
        }
        return nil
    }

    private static let unknownOnlineCharacters = CharacterSet(charactersIn: "\"*<>?\\|")

    /// Name eines Ordners/einer Datei in OneDrive online. Ein „/“ im Finder ist auf dem Mac intern ein „:“;
    /// beides ist online verboten, OneDrive verwendet dort „_“ (z. B. „2025/26-8c“ → „2025_26-8c“).
    static func onlineName(_ localName: String) -> String {
        if let learned = Settings.learnedOnlineNames[localName.precomposedStringWithCanonicalMapping] { return learned }
        return localName.replacingOccurrences(of: ":", with: "_")
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
