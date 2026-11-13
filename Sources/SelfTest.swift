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

        print(failures == 0 ? "Selbsttest bestanden" : "Selbsttest: \(failures) Fehlschlag/Fehlschläge")
        return failures
    }
}
