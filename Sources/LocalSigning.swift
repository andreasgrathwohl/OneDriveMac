import Foundation
import Security

/// Signiert die App auf dem Mac mit einem dort erzeugten, eigenen Zertifikat („OneDrive Opener (lokal)“).
///
/// Warum: macOS bindet die Freigabe „Bedienungshilfen“ (und Mitteilungen) an die Signatur der App. Eine
/// provisorische (Ad-hoc-)Signatur ist an den genauen Inhalt gebunden – jede neue Version und jedes Neu-Signieren
/// nach dem Übernehmen der Office-Dokumentsymbole (`OfficeIcons`) sieht für macOS wie eine fremde App aus, die
/// Freigabe ist weg (nach jedem Update bis 1.9.5). Mit einem Zertifikat lautet die Kennung „diese Bundle-ID,
/// signiert mit diesem Zertifikat“ – sie übersteht Updates und das Kopieren der Symbole.
///
/// Der private Schlüssel entsteht auf dem Mac und verlässt ihn nie (Schlüsselbund der Anwenderin). Ein Programm,
/// das bereits als dieselbe Person läuft, könnte ihn verwenden – bewusst in Kauf genommen (Entscheidung
/// 2026-11-26), weil ein mitgeliefertes Zertifikat weit schlimmer wäre. Schlägt etwas fehl, wird wie bisher
/// ad-hoc signiert: schlimmstenfalls der alte Zustand.
enum LocalSigning {
    static let commonName = "OneDrive Opener (lokal)"
    private static let lock = NSLock()
    /// Beim ersten Signieren fragt macOS ggf. nach dem Schlüssel – so lange wird höchstens gewartet.
    static let signTimeout: TimeInterval = 120

    // MARK: - Identität

    /// SHA-1 der Identität im Schlüsselbund (`keychain` nil = Standard-Suchliste), sonst nil.
    /// Ohne `-v`: Ein selbst signiertes Zertifikat gilt für macOS als „nicht vertrauenswürdig“, `-v` würde es ausblenden.
    static func identityHash(keychain: String? = nil) -> String? {
        var args = ["find-identity", "-p", "codesigning"]
        if let keychain { args.append(keychain) }
        guard let out = run("/usr/bin/security", args).output else { return nil }
        for line in out.split(separator: "\n") where line.contains("\"\(commonName)\"") {
            if let hash = line.split(separator: " ").first(where: { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }) {
                return String(hash)
            }
        }
        return nil
    }

    /// Vorhandene Identität oder neu angelegte; nil, wenn das nicht gelingt.
    static func ensureIdentity(keychain: String? = nil, keychainPassword: String? = nil) -> String? {
        if let hash = identityHash(keychain: keychain) { return hash }
        guard createIdentity(keychain: keychain, keychainPassword: keychainPassword) else { return nil }
        let hash = identityHash(keychain: keychain)
        if hash != nil { Log.info("Lokales Signatur-Zertifikat „\(commonName)“ angelegt") }
        return hash
    }

    /// Erzeugt Schlüssel und selbst signiertes Code-Signing-Zertifikat mit `openssl` und importiert beides in den
    /// Schlüsselbund – nur `codesign` darf den Schlüssel benutzen. Die Zwischendateien werden sofort gelöscht.
    /// `keychainPassword` nur für den Test mit eigenem Schlüsselbund (erlaubt `codesign` ohne Rückfrage).
    static func createIdentity(keychain: String? = nil, keychainPassword: String? = nil) -> Bool {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("odo-sign-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else {
            return false
        }
        defer { try? fm.removeItem(at: dir) }
        let config = """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = \(commonName)
        [ext]
        basicConstraints = critical, CA:false
        keyUsage = critical, digitalSignature
        extendedKeyUsage = critical, codeSigning
        """
        let cfg = dir.appendingPathComponent("req.cnf")
        let key = dir.appendingPathComponent("key.pem")
        let cert = dir.appendingPathComponent("cert.pem")
        let p12 = dir.appendingPathComponent("id.p12")
        let password = UUID().uuidString
        guard (try? config.write(to: cfg, atomically: true, encoding: .utf8)) != nil,
              run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                                       "-config", cfg.path, "-keyout", key.path, "-out", cert.path]).ok,
              run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
                                       "-name", commonName, "-out", p12.path, "-passout", "pass:\(password)"]).ok else {
            Log.info("Lokales Signatur-Zertifikat: Erzeugen fehlgeschlagen")
            return false
        }
        var importArgs = ["import", p12.path, "-P", password, "-T", "/usr/bin/codesign"]
        if let keychain { importArgs += ["-k", keychain] }
        let imported = run("/usr/bin/security", importArgs)
        guard imported.ok else {
            Log.info("Lokales Signatur-Zertifikat: Import in den Schlüsselbund fehlgeschlagen: \(imported.output ?? "?")")
            return false
        }
        if let keychain, let keychainPassword {
            _ = run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,unsigned:", "-s",
                                          "-k", keychainPassword, keychain])
        }
        return true
    }

    // MARK: - Signieren

    /// Signiert das Bundle mit der lokalen Identität; misslingt das, ad-hoc (wie bis 1.9.5).
    /// Die Anforderungen werden bewusst nicht übernommen – macOS leitet sie aus dem Zertifikat neu ab.
    @discardableResult
    static func sign(_ bundlePath: String, keychain: String? = nil, keychainPassword: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let preserve = "--preserve-metadata=identifier,entitlements,flags,runtime"
        if let identity = ensureIdentity(keychain: keychain, keychainPassword: keychainPassword) {
            var args = ["--force", "--sign", identity, preserve]
            if let keychain { args += ["--keychain", keychain] }
            let result = run("/usr/bin/codesign", args + [bundlePath], timeout: signTimeout)
            if result.ok { return true }
            Log.info("Lokales Signieren fehlgeschlagen – signiere ad-hoc: \(result.output ?? "?")")
        }
        return run("/usr/bin/codesign", ["--force", "--sign", "-", preserve, bundlePath], timeout: signTimeout).ok
    }

    /// Beim Start: Ist die App noch ad-hoc signiert (frisch installiert oder aus einer älteren Version
    /// aktualisiert), einmal lokal signieren. Danach muss die Freigabe einmal neu erteilt werden – zum letzten Mal.
    static func adoptIfNeeded() {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasPrefix("/Applications/"), FileManager.default.isWritableFile(atPath: bundle),
              signer(of: bundle) == .adHoc else { return }
        if sign(bundle), signer(of: bundle) == .local {
            Log.info("App mit lokalem Zertifikat signiert – Freigaben überstehen künftige Updates; "
                + "„Bedienungshilfen“ muss nach dem nächsten Start einmal neu erteilt werden")
            Task { @MainActor in
                Reporter.shared.send(kind: "signing", message: "Lokal signiert", details: [:])
            }
        }
    }

    // MARK: - Prüfen

    enum Signer: Equatable { case adHoc, local, other, unsigned }

    /// Wer das Bundle signiert hat: ad-hoc, unser lokales Zertifikat, jemand anderes (z. B. Developer ID).
    static func signer(of bundlePath: String) -> Signer {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundlePath) as CFURL, [], &code) == errSecSuccess,
              let code else { return .unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 1 << 1), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return .unsigned }
        if let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value, flags & 0x2 != 0 { return .adHoc }
        guard let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else {
            return .unsigned
        }
        return (SecCertificateCopySubjectSummary(leaf) as String?) == commonName ? .local : .other
    }

    // MARK: - Hilfen

    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 30) -> (ok: Bool, output: String?) {
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

    /// `--signing-selftest`: eigener Schlüsselbund, Identität anlegen, eine Kopie der App zweimal signieren
    /// (wie zwei Updates) und prüfen, dass die Kennung beide Male dieselbe ist und auf dem Zertifikat beruht.
    static func selfTest() -> Int32 {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("odo-signtest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let keychain = dir.appendingPathComponent("test.keychain-db").path
        let password = "test"
        defer {
            _ = run("/usr/bin/security", ["delete-keychain", keychain])
            try? fm.removeItem(at: dir)
        }
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "ok    " : "FEHLER") \(name)\(detail.isEmpty ? "" : " – \(detail)")")
            if !ok { failures += 1 }
        }
        check("schluesselbundAngelegt", run("/usr/bin/security", ["create-keychain", "-p", password, keychain]).ok
              && run("/usr/bin/security", ["unlock-keychain", "-p", password, keychain]).ok)
        let identity = ensureIdentity(keychain: keychain, keychainPassword: password)
        check("identitaetAngelegt", identity != nil)
        check("identitaetWiedergefunden", identity != nil && identityHash(keychain: keychain) == identity)

        let copy = dir.appendingPathComponent("Test.app").path
        check("appKopiert", run("/usr/bin/ditto", [Bundle.main.bundlePath, copy]).ok)
        func requirement() -> String {
            let out = run("/usr/bin/codesign", ["-d", "-r-", copy]).output ?? ""
            return out.split(separator: "\n").first { $0.contains("designated =>") }.map(String.init) ?? ""
        }
        // Diagnose: was macOS zur Identität sagt und was codesign mit ihr direkt meldet (ohne Rückfall auf ad-hoc).
        print("--- find-identity -p codesigning:")
        print(run("/usr/bin/security", ["find-identity", "-p", "codesigning", keychain]).output ?? "–")
        if let identity {
            let direct = run("/usr/bin/codesign", ["--force", "--sign", identity, "--keychain", keychain,
                                                   "--preserve-metadata=identifier,entitlements,flags,runtime", copy],
                             timeout: signTimeout)
            print("--- codesign mit Identität: \(direct.ok ? "ok" : "fehlgeschlagen")")
            print(direct.output ?? "–")
        }
        check("ersteSignatur", sign(copy, keychain: keychain, keychainPassword: password) && signer(of: copy) == .local)
        let first = requirement()
        check("kennungAusZertifikat", first.contains("certificate leaf"), first)
        check("signaturGueltig", run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy]).ok)
        // Wie ein Update bzw. das Übernehmen der Office-Symbole: Inhalt ändern, erneut signieren.
        let marker = URL(fileURLWithPath: copy).appendingPathComponent("Contents/Resources/Doc-test.icns")
        try? Data([1, 2, 3]).write(to: marker)
        check("zweiteSignatur", sign(copy, keychain: keychain, keychainPassword: password))
        check("kennungUnveraendert", !first.isEmpty && requirement() == first)
        print(failures == 0 ? "Signatur-Selbsttest bestanden" : "Signatur-Selbsttest: \(failures) Fehlschlag/Fehlschläge")
        return failures
    }
}
