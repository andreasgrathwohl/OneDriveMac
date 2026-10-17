import Foundation

/// Übertragene Bytes je Programm laut `nettop` (kumuliert seit Programmstart). Zwei Momentaufnahmen
/// ergeben, wer während eines langen Speichervorgangs das Netz belegt hat – z. B. ob die OneDrive-App
/// gleichzeitig große Dateien herunterlädt, während Word hochladen will.
enum NetworkUsage {
    struct Snapshot {
        let date: Date
        /// Programmname → (empfangen, gesendet) in Bytes, über alle Prozesse gleichen Namens summiert.
        let bytes: [String: (received: Int64, sent: Int64)]
    }

    /// Läuft außerhalb des Hauptthreads (nettop braucht etwa eine Sekunde).
    static func take() async -> Snapshot? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: takeBlocking()) }
        }
    }

    private static func takeBlocking() -> Snapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -P je Prozess, -L 1 eine Messung als CSV, -x volle Zahlen, -n ohne Namensauflösung.
        process.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let bytes = parse(text)
        return bytes.isEmpty ? nil : Snapshot(date: Date(), bytes: bytes)
    }

    /// Zeilen wie „12:00:01.123456,Microsoft Word.812,123456,7890,“ – Prozessname mit „.PID“, danach die Zahlen.
    static func parse(_ text: String) -> [String: (received: Int64, sent: Int64)] {
        var result: [String: (received: Int64, sent: Int64)] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let numbers = fields.compactMap { Int64($0) }
            guard numbers.count >= 2,
                  let nameField = fields.first(where: { $0.range(of: #"^.+\.\d+$"#, options: .regularExpression) != nil }),
                  let dot = nameField.lastIndex(of: ".") else { continue }
            let name = String(nameField[..<dot])
            let previous = result[name] ?? (received: 0, sent: 0)
            result[name] = (received: previous.received + numbers[numbers.count - 2], sent: previous.sent + numbers[numbers.count - 1])
        }
        return result
    }

    /// Gruppen, die bei langsamem Speichern interessieren; alles andere wird nach Menge sortiert angehängt.
    private static func group(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("onedrive") { return "OneDrive" }
        if n.hasPrefix("microsoft w") { return "Word" }
        if n.hasPrefix("microsoft p") { return "PowerPoint" }
        if n.hasPrefix("microsoft e") { return "Excel" }
        if n.hasPrefix("microsoft au") || n.hasPrefix("microsoft up") { return "Microsoft-Updates" }
        return name
    }

    /// Z. B. „in 130 s: OneDrive ↓ 85,2 MB ↑ 0,1 MB · Word ↓ 0,3 MB ↑ 2,1 MB · … · gesamt ↓ 90 MB ↑ 3 MB“.
    static func describe(from start: Snapshot, to end: Snapshot) -> String {
        var groups: [String: (received: Int64, sent: Int64)] = [:]
        for (name, now) in end.bytes {
            let before = start.bytes[name] ?? (received: 0, sent: 0)
            // Neu gestartete Prozesse beginnen wieder bei 0.
            let received = now.received >= before.received ? now.received - before.received : now.received
            let sent = now.sent >= before.sent ? now.sent - before.sent : now.sent
            let key = group(name)
            let previous = groups[key] ?? (received: 0, sent: 0)
            groups[key] = (received: previous.received + received, sent: previous.sent + sent)
        }
        let fixed = ["OneDrive", "Word", "PowerPoint", "Excel", "Microsoft-Updates"]
        let others = groups.filter { !fixed.contains($0.key) }
            .sorted { $0.value.received + $0.value.sent > $1.value.received + $1.value.sent }
            .prefix(5)
            .filter { $0.value.received + $0.value.sent >= 1_000_000 }
        var parts = fixed.compactMap { key in groups[key].map { "\(key) ↓ \(mb($0.received)) ↑ \(mb($0.sent))" } }
        parts += others.map { "\($0.key) ↓ \(mb($0.value.received)) ↑ \(mb($0.value.sent))" }
        let total = groups.values.reduce((received: Int64(0), sent: Int64(0))) { (received: $0.received + $1.received, sent: $0.sent + $1.sent) }
        parts.append("gesamt ↓ \(mb(total.received)) ↑ \(mb(total.sent))")
        let seconds = Int(end.date.timeIntervalSince(start.date))
        return "in \(seconds) s: " + parts.joined(separator: " · ")
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}
