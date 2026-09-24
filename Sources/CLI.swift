import Foundation

/// Kommandozeilen-Modus für Tests und Support:
///   OneDriveOpener --diagnose
///   OneDriveOpener --resolve <Datei>
enum CLI {
    static func run() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--diagnose") {
            print(OneDriveConfig.diagnosticReport())
            return true
        }
        if let i = args.firstIndex(of: "--resolve"), i + 1 < args.count {
            let file = URL(fileURLWithPath: args[i + 1])
            if let result = PathResolver.resolve(file, roots: PathResolver.allRoots()) {
                print("Web-URL:     \(result.url)")
                print("Zuordnung:   \(result.root.localPath) (\(result.root.source))")
                if result.root.isGuess {
                    print("Achtung:     nur geschätzt – wird \(Settings.useGuessedMappings ? "trotzdem online" : "lokal") geöffnet")
                }
                if let app = OfficeApp.forExtension(file.pathExtension) {
                    print("Office-URI:  \(app.scheme):ofe|u|\(result.url)")
                }
            } else {
                print("Nicht in einem erkannten OneDrive-Ordner.")
            }
            print("Sync-Status: \(SyncStatus.current(file).rawValue)")
            return true
        }
        return false
    }
}
