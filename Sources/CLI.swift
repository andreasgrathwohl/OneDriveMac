import AppKit
import SwiftUI

/// Kommandozeilen-Modus für Tests und Support:
///   OneDriveOpener --diagnose
///   OneDriveOpener --resolve <Datei>
///   OneDriveOpener --screenshots <Ordner>   (Einstellungen als PNG, hell und dunkel – für CI)
@MainActor
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
        if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
            renderScreenshots(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
            return true
        }
        return false
    }

    private static func renderScreenshots(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = SettingsModel(openLog: {})
        model.refresh()
        let size = NSSize(width: 620, height: 560)
        let tabs: [(String, AnyView)] = [
            ("allgemein", AnyView(GeneralTab(model: model))),
            ("ordner", AnyView(FoldersTab(model: model))),
            ("fehlerbehebung", AnyView(TroubleshootingTab(model: model))),
        ]
        for (name, view) in tabs {
            for (suffix, appearance) in [("hell", NSAppearance.Name.aqua), ("dunkel", NSAppearance.Name.darkAqua)] {
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = dir.appendingPathComponent("\(name)-\(suffix).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("Screenshot: \(url.path)")
            }
        }
    }
}
