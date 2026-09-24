import Foundation

/// Führt AppleScript über `osascript` aus – außerhalb des Hauptthreads und mit Zeitlimit,
/// damit eine hängende Office-App die Menüleiste nicht blockiert.
enum AppleScriptRunner {
    struct Result {
        let output: String?
        let error: String?

        /// macOS hat das Steuern der App verweigert (errAEEventNotPermitted).
        var permissionDenied: Bool { error?.contains("-1743") == true }
    }

    static func run(_ source: String, timeout: TimeInterval = 10) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(output: nil, error: error.localizedDescription))
                    return
                }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                if process.terminationStatus == 0 {
                    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
                    continuation.resume(returning: Result(output: text, error: nil))
                } else {
                    let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: Result(output: nil, error: message ?? "Status \(process.terminationStatus)"))
                }
            }
        }
    }

    /// Text sicher in ein AppleScript-Zeichenkettenliteral einsetzen.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
