import Foundation
import ImageIO

/// Woraus eine Office-Datei (`.pptx`, `.docx`, `.xlsx` – alles Zip-Archive) besteht: Bilder, Videos, Audio,
/// Schriften, eingebettete Objekte. Für die Ferndiagnose `pptx-analyse` – um zu sehen, warum eine Präsentation
/// 120 MB groß ist und was „Datei → Dateigröße reduzieren“ in PowerPoint daran ändern würde.
///
/// Nur lesend: Das Inhaltsverzeichnis des Archivs wird direkt aus der Datei gelesen; für die Pixelgröße der größten
/// Bilder wird je Bild nur dieser eine Eintrag gelesen. Nicht heruntergeladene OneDrive-Dateien werden abgelehnt –
/// das Lesen würde sonst einen Download der ganzen Datei auslösen.
enum OOXMLAnalysis {
    struct Entry {
        let name: String
        let compressed: Int64
        let size: Int64
    }

    static func analyse(_ file: URL) -> [String: Any] {
        if let status = (try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            return ["error": "Datei liegt nur online – nicht analysiert, um keinen Download auszulösen"]
        }
        guard let entries = centralDirectory(file) else {
            return ["error": "kein lesbares Zip-Archiv (keine Office-Open-XML-Datei?)"]
        }
        let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        var categories: [String: (count: Int, size: Int64, compressed: Int64)] = [:]
        for entry in entries {
            let c = category(entry.name)
            let previous = categories[c] ?? (0, 0, 0)
            categories[c] = (previous.count + 1, previous.size + entry.size, previous.compressed + entry.compressed)
        }
        let largest = entries.sorted { $0.compressed > $1.compressed }.prefix(15).map { e -> [String: Any] in
            ["name": e.name, "kb": e.compressed / 1024, "kb_entpackt": e.size / 1024, "art": category(e.name)]
        }
        let images = entries.filter { category($0.name) == "Bilder" }.sorted { $0.compressed > $1.compressed }.prefix(10)
        let pixels = images.map { e -> [String: Any] in
            var row: [String: Any] = ["name": e.name, "kb": e.compressed / 1024]
            if let size = pixelSize(file, entry: e.name) { row["pixel"] = "\(size.width) × \(size.height)" }
            return row
        }
        return [
            "datei_mb": String(format: "%.1f", Double(fileSize) / 1_000_000),
            "folien": entries.filter { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") }.count,
            "kategorien": categories.sorted { $0.value.compressed > $1.value.compressed }.map { key, v -> [String: Any] in
                ["art": key, "anzahl": v.count, "mb": String(format: "%.1f", Double(v.compressed) / 1_000_000),
                 "mb_entpackt": String(format: "%.1f", Double(v.size) / 1_000_000)]
            },
            "groesste": largest,
            "bilder_pixel": pixels,
        ]
    }

    static func category(_ name: String) -> String {
        let n = name.lowercased()
        let ext = (n as NSString).pathExtension
        if ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "emf", "wmf", "svg", "heic", "webp"].contains(ext) { return "Bilder" }
        if ["mp4", "mov", "m4v", "wmv", "avi", "mpg", "mpeg"].contains(ext) { return "Videos" }
        if ["m4a", "mp3", "wav", "wma", "aac"].contains(ext) { return "Audio" }
        if n.contains("/fonts/") || ext == "fntdata" || ext == "odttf" { return "Schriften" }
        if n.contains("/embeddings/") { return "Eingebettete Objekte" }
        if ext == "xml" || ext == "rels" { return "Struktur (XML)" }
        return "Sonstiges"
    }

    /// Liest das zentrale Verzeichnis des Zip-Archivs (Ende-Datensatz suchen, dann alle Einträge).
    /// Zip64 (über 4 GB) wird nicht unterstützt – Office-Dateien dieser Größe gibt es praktisch nicht.
    static func centralDirectory(_ file: URL) -> [Entry]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 22 else { return nil }
        let tailLength = min(end, 66_000)
        try? handle.seek(toOffset: end - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)), tail.count >= 22 else { return nil }
        let bytes = [UInt8](tail)
        var eocd: Int?
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { return nil }
        let count = Int(le16(bytes, e + 10))
        let dirSize = Int(le32(bytes, e + 12))
        let dirOffset = UInt64(le32(bytes, e + 16))
        guard dirOffset + UInt64(dirSize) <= end else { return nil }
        try? handle.seek(toOffset: dirOffset)
        guard let dirData = try? handle.read(upToCount: dirSize), dirData.count == dirSize else { return nil }
        let dir = [UInt8](dirData)
        var entries: [Entry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= dir.count, dir[p] == 0x50, dir[p + 1] == 0x4B, dir[p + 2] == 0x01, dir[p + 3] == 0x02 else { break }
            let compressed = Int64(le32(dir, p + 20))
            let size = Int64(le32(dir, p + 24))
            let nameLength = Int(le16(dir, p + 28))
            let extraLength = Int(le16(dir, p + 30))
            let commentLength = Int(le16(dir, p + 32))
            guard p + 46 + nameLength <= dir.count else { break }
            let name = String(decoding: dir[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, compressed: compressed, size: size))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries.isEmpty ? nil : entries
    }

    /// Pixelgröße eines Bildes im Archiv – über `unzip -p`, das nur diesen einen Eintrag ausgibt.
    static func pixelSize(_ file: URL, entry: String) -> (width: Int, height: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", file.path, entry]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
