import Foundation

/// Lernt, wie OneDrive Namen online schreibt, die sich lokal anders darstellen
/// (z. B. „2025:26-8c“ auf dem Mac – im Finder „2025/26-8c“ – gegenüber der Online-Schreibweise).
///
/// Quelle ist Word selbst: Bei einem als Cloud-Dokument geöffneten Dokument liefert `full name` die echte
/// Online-Adresse. Diese wird Ordner für Ordner mit dem lokalen Sync-Ordner verglichen.
@MainActor
enum PathLearner {
    private static var seen = Set<String>()

    static func learn(fromCloudURL address: String) {
        guard seen.insert(address).inserted else { return }
        let decodedAddress = address.removingPercentEncoding ?? address
        // Längste passende Web-Adresse zuerst (z. B. einzeln synchronisierter Unterordner vor der Bibliothek).
        let roots = PathResolver.allRoots().compactMap { root -> (root: SyncRoot, base: String)? in
            guard let base = PathResolver.encodeBase(root.webURL) else { return nil }
            return (root, base.removingPercentEncoding ?? base)
        }.sorted { $0.base.count > $1.base.count }
        for (root, decodedBase) in roots {
            guard decodedAddress.lowercased().hasPrefix(decodedBase.lowercased() + "/") else { continue }
            let online = decodedAddress.dropFirst(decodedBase.count + 1).split(separator: "/").map(String.init)
            walk(online, from: URL(fileURLWithPath: root.localPath, isDirectory: true))
            return
        }
    }

    private static func walk(_ components: [String], from start: URL) {
        var dir = start
        for component in components {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if let exact = children.first(where: {
                PathResolver.onlineName($0).precomposedStringWithCanonicalMapping
                    .caseInsensitiveCompare(component.precomposedStringWithCanonicalMapping) == .orderedSame
            }) {
                dir.appendPathComponent(exact)
                continue
            }
            let candidates = children.filter { looselyEqual($0, component) }
            guard candidates.count == 1 else { return }
            let local = candidates[0]
            var learned = Settings.learnedOnlineNames
            learned[local.precomposedStringWithCanonicalMapping] = component
            Settings.learnedOnlineNames = learned
            Log.info("Gelernt: „\(local)“ heißt in OneDrive online „\(component)“")
            Reporter.shared.send(kind: "learned", message: "Online-Schreibweise gelernt",
                                 details: ["local": local, "online": component])
            dir.appendPathComponent(local)
        }
    }

    /// Online verbotene Zeichen – nur an solchen Stellen darf der lokale Name abweichen.
    private static let forbiddenOnline = Set(":\"*<>?\\|")

    /// Gleich lang und an jeder Stelle gleich – außer wo lokal ein online verbotenes Zeichen steht und
    /// online kein Buchstabe/keine Ziffer. So wird „Test 1“ nicht fälschlich als „Test-1“ gelernt.
    private static func looselyEqual(_ local: String, _ online: String) -> Bool {
        let a = Array(local.precomposedStringWithCanonicalMapping.lowercased())
        let b = Array(online.precomposedStringWithCanonicalMapping.lowercased())
        guard a.count == b.count, a != b else { return false }
        return zip(a, b).allSatisfy { x, y in
            x == y || (forbiddenOnline.contains(x) && !(y.isLetter || y.isNumber))
        }
    }
}
