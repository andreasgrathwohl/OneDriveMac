import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OneDriveOpener", category: "app")
    private static let queue = DispatchQueue(label: "OneDriveOpener.log")

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OneDriveOpener", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("OneDriveOpener.log")
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("FEHLER", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            let url = fileURL
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
