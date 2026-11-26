import Foundation
import Security

/// Signiert die App so, dass macOS sie über Updates hinweg als dieselbe App erkennt (Weg B, Entscheidung 2026-11-26).
///
/// macOS bindet die Freigabe „Bedienungshilfen“ (und Mitteilungen) an die „Designated Requirement“ der Signatur.
/// Bei einer provisorischen (Ad-hoc-)Signatur ist das ohne weiteres Zutun der Fingerabdruck des Inhalts
/// (`cdhash`) – jede neue Version und jedes Neu-Signieren nach dem Übernehmen der Office-Dokumentsymbole sah wie
/// eine fremde App aus, die Freigabe war weg (nach jedem Update bis 1.9.5). Deshalb trägt die Signatur jetzt eine
/// feste Kennung ein: „die App mit dieser Bundle-ID“. Sie wird beim Bauen gesetzt (`build.sh`) und bei jedem
/// Neu-Signieren auf dem Mac erhalten.
///
/// Ob macOS die Freigabe für ad-hoc signierte Apps tatsächlich an diese Kennung bindet, ist nicht dokumentiert und
/// zeigt sich erst beim übernächsten Update. Verworfen (vorerst): ein selbst erzeugtes Zertifikat – `codesign`
/// lehnt es als „nicht vertrauenswürdig“ ab, solange es nicht mit Passwortabfrage als vertrauenswürdig markiert
/// wird (CI-Befund 2026-11-26; Umsetzung in der Git-Historie, Commit „Local signing certificate …“).
enum StableSigning {
    /// Die feste Kennung, z. B. `designated => identifier "de.onedriveopener.app"`.
    static func requirement(for identifier: String) -> String {
        "designated => identifier \"\(identifier)\""
    }

    /// Ad-hoc neu signieren, mit fester Kennung (nicht nur übernommen – falls das Bundle noch keine hatte).
    @discardableResult
    static func sign(_ bundlePath: String) -> Bool {
        guard let identifier = Bundle(path: bundlePath)?.bundleIdentifier else { return false }
        return run("/usr/bin/codesign", ["--force", "--sign", "-", "-r", "=" + requirement(for: identifier),
                                         "--preserve-metadata=identifier,entitlements,flags,runtime", bundlePath]).ok
    }

    /// Die Kennung, wie `codesign` sie meldet. Beginnt die Zeile mit „#“, ist sie nur abgeleitet (cdhash).
    static func designatedRequirement(_ bundlePath: String) -> String {
        let out = run("/usr/bin/codesign", ["-d", "-r-", bundlePath]).output ?? ""
        return out.split(separator: "\n").first { $0.contains("designated =>") }.map(String.init) ?? ""
    }

    /// Fest heißt: ausdrücklich eingetragen und an die Bundle-ID gebunden, nicht an den cdhash.
    static func hasStableRequirement(_ bundlePath: String) -> Bool {
        let dr = designatedRequirement(bundlePath)
        return !dr.hasPrefix("#") && dr.contains("identifier \"") && !dr.contains("cdhash")
    }

    /// Ad-hoc signiert? Nur solche Signaturen lassen sich auf dem Mac erneuern (`OfficeIcons`).
    static func isAdHocSigned(_ bundlePath: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundlePath) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 1 << 1), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value else { return false }
        return flags & 0x2 != 0
    }

    /// Beim Start: Fehlt die feste Kennung noch (etwa weil eine ältere Version das Bundle neu signiert hat),
    /// einmal nachtragen.
    static func adoptIfNeeded() {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasPrefix("/Applications/"), FileManager.default.isWritableFile(atPath: bundle),
              isAdHocSigned(bundle), !hasStableRequirement(bundle) else { return }
        if sign(bundle), hasStableRequirement(bundle) {
            Log.info("Signatur: feste Kennung eingetragen – Freigaben sollen künftige Updates überstehen")
        } else {
            Log.info("Signatur: feste Kennung konnte nicht eingetragen werden")
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) -> (ok: Bool, output: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (false, error.localizedDescription) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8))
    }

    // MARK: - Selbsttest (CI)

    /// `--signing-selftest`: Die gebaute App trägt die feste Kennung; sie bleibt erhalten, wenn das Bundle verändert
    /// und neu signiert wird – über `sign` (Symbol-Übernahme) und über das Kommando des Update-Skripts
    /// älterer Versionen (Metadaten übernehmen, „requirements“ eingeschlossen).
    static func selfTest() -> Int32 {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("odo-signtest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "ok    " : "FEHLER") \(name)\(detail.isEmpty ? "" : " – \(detail)")")
            if !ok { failures += 1 }
        }
        let built = designatedRequirement(Bundle.main.bundlePath)
        check("gebauteAppHatFesteKennung", hasStableRequirement(Bundle.main.bundlePath), built)

        let copy = dir.appendingPathComponent("Test.app").path
        check("appKopiert", run("/usr/bin/ditto", [Bundle.main.bundlePath, copy]).ok)
        let resources = URL(fileURLWithPath: copy).appendingPathComponent("Contents/Resources")

        // Wie OfficeIcons: Symbol ins Bundle kopieren, neu signieren.
        try? Data([1, 2, 3]).write(to: resources.appendingPathComponent("Doc-test.icns"))
        check("signierenNachSymbol", sign(copy))
        check("kennungNachSymbol", designatedRequirement(copy) == built, designatedRequirement(copy))
        check("signaturGueltig", run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy]).ok)

        // Wie das Update-Skript bis 1.9.5: ad-hoc mit übernommenen Metadaten.
        try? Data([4, 5, 6]).write(to: resources.appendingPathComponent("Doc-test2.icns"))
        let old = run("/usr/bin/codesign", ["--force", "--sign", "-",
                                            "--preserve-metadata=identifier,entitlements,requirements,flags,runtime", copy])
        check("altesUpdateSkript", old.ok, old.ok ? "" : (old.output ?? ""))
        check("kennungNachAltemSkript", designatedRequirement(copy) == built, designatedRequirement(copy))

        print(failures == 0 ? "Signatur-Selbsttest bestanden" : "Signatur-Selbsttest: \(failures) Fehlschlag/Fehlschläge")
        return failures
    }
}
