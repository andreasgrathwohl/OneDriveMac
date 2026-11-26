import Foundation

/// Selbsttest über die Kommandozeile (`OneDriveOpener --selftest`, läuft in CI): prüft reine Logik ohne
/// Oberfläche und ohne Netz. Druckt je Prüfung `ok` oder `FEHLER` und liefert die Zahl der Fehlschläge.
enum SelfTest {
    static func run() -> Int32 {
        var failures: Int32 = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "ok    " : "FEHLER") \(name)")
            if !condition { failures += 1 }
        }

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

        // Störungsbetrieb: Dauer, Verlängerung, Ende
        check("inaktivOhneAusloeser", OutagePolicy().isActive(now: t0) == false)

        do {
            var p = OutagePolicy()
            _ = p.trigger(now: t0, manual: false)
            check("automatisch30Min", p.isActive(now: at(1799)) && !p.isActive(now: at(1800)))
        }
        do {
            var p = OutagePolicy()
            _ = p.trigger(now: t0, manual: true)
            check("manuell60Min", p.isActive(now: at(3599)))
        }
        do {
            var p = OutagePolicy()
            _ = p.trigger(now: t0, manual: false)
            _ = p.trigger(now: at(1000), manual: false)
            check("verlaengert", p.isActive(now: at(2700)))
        }
        do {
            var p = OutagePolicy()
            _ = p.trigger(now: t0, manual: true)
            _ = p.trigger(now: at(60), manual: false)
            check("verkuerztNie", p.isActive(now: at(3500)) && p.manual == true)
        }
        do {
            var p = OutagePolicy()
            let first = p.trigger(now: t0, manual: false)
            let second = p.trigger(now: at(10), manual: false)
            let afterExpiry = p.trigger(now: at(4000), manual: false)
            check("neuBegonnen", first && !second && afterExpiry)
        }
        do {
            var p = OutagePolicy()
            _ = p.trigger(now: t0, manual: false)
            p.end()
            check("ende", !p.isActive(now: at(1)))
        }

        // Saveschwelle: erst ab zwei gleichzeitig hängenden Dokumenten
        check("eineGrosseDatei", OutagePolicy.savesSignal(durations: [900]) == false)
        check("zweiHaengend", OutagePolicy.savesSignal(durations: [180, 200]) == true)
        check("zweiKurz", OutagePolicy.savesSignal(durations: [179, 600]) == false)

        // Upload-Anzeige: Stillstand erst nach 120 s ohne nennenswertes Senden, und nicht direkt nach Messbeginn
        do {
            let r = UploadMeter.Reading(app: .powerpoint, sent: 0, rate: 0, since: t0, lastActivity: at(30))
            check("uploadNichtSofortStill", !r.isStalled(at: at(60)))
            check("uploadStillNach120s", r.isStalled(at: at(150)) && !r.isStalled(at: at(149)))
        }
        check("uploadTempoText", UploadMeter.rateText(2_400_000) == "2,4 MB/s" && UploadMeter.rateText(512_000) == "512 KB/s")
        check("uploadMengeText", UploadMeter.sizeText(46_000_000) == "46,0 MB" && UploadMeter.sizeText(800) == "1 KB")

        // pptx-analyse: Arten und das Lesen des Zip-Inhaltsverzeichnisses
        check("artBild", OOXMLAnalysis.category("ppt/media/image3.JPEG") == "Bilder")
        check("artVideo", OOXMLAnalysis.category("ppt/media/media1.mp4") == "Videos")
        check("artSchrift", OOXMLAnalysis.category("ppt/fonts/font1.fntdata") == "Schriften")
        check("artStruktur", OOXMLAnalysis.category("ppt/slides/slide1.xml") == "Struktur (XML)")
        check("zipVerzeichnis", zipDirectoryReadable())

        print(failures == 0 ? "Selbsttest bestanden" : "Selbsttest: \(failures) Fehlschlag/Fehlschläge")
        return failures
    }

    /// Legt mit `/usr/bin/zip` ein kleines Archiv an (zwei Dateien, eine davon komprimierbar) und prüft, dass
    /// `OOXMLAnalysis.centralDirectory` beide Einträge mit Namen und entpackter Größe findet.
    private static func zipDirectoryReadable() -> Bool {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("odo-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        guard (try? fm.createDirectory(at: dir.appendingPathComponent("ppt/media"), withIntermediateDirectories: true)) != nil,
              (try? Data(repeating: 65, count: 5000).write(to: dir.appendingPathComponent("ppt/slide.xml"))) != nil,
              (try? Data((0..<3000).map { UInt8($0 % 251) }).write(to: dir.appendingPathComponent("ppt/media/image1.png"))) != nil
        else { return false }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-r", "test.pptx", "ppt"]
        guard (try? zip.run()) != nil else { return false }
        zip.waitUntilExit()
        guard let entries = OOXMLAnalysis.centralDirectory(dir.appendingPathComponent("test.pptx")) else { return false }
        let files = Dictionary(entries.filter { !$0.name.hasSuffix("/") }.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
        return files["ppt/slide.xml"] == 5000 && files["ppt/media/image1.png"] == 3000
    }
}
