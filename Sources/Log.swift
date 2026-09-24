import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OneDriveOpener", category: "app")
    private static let queue = DispatchQueue(label: "OneDriveOpener.log")
    private static let maxFileSize = 2_000_000

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var directoryURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OneDriveOpener", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("OneDriveOpener.log") }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("FEHLER", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        Task { @MainActor in LogStore.shared.append(line) }
        queue.async {
            let url = fileURL
            rotateIfNeeded(url)
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Hält das Protokoll klein: ab 2 MB wird es nach `OneDriveOpener.1.log` verschoben.
    private static func rotateIfNeeded(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > maxFileSize else { return }
        let old = directoryURL.appendingPathComponent("OneDriveOpener.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    static func readTail(_ maxLines: Int) -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").map(String.init).suffix(maxLines))
    }

    static func clearFile() {
        queue.async { try? Data().write(to: fileURL) }
    }
}
