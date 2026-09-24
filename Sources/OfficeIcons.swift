import AppKit
import ImageIO
import Security
import UniformTypeIdentifiers

/// Übernimmt die Dokumentsymbole von Word, Excel und PowerPoint in das eigene App-Bundle.
///
/// Der Finder zeigt für eine Datei das Dokumentsymbol der Standard-App. Ohne eigene Symbole erzeugt
/// macOS eines aus dem App-Logo. Microsofts Symbole dürfen nicht mit der App verteilt werden – sie
/// werden deshalb erst auf dem Mac aus der installierten Office-App kopiert (`Doc-<ext>.icns`, siehe
/// Info.plist) und die App danach ad-hoc neu signiert.
enum OfficeIcons {
    /// Programmstart und Office-Update können gleichzeitig auslösen – nie zweimal parallel signieren.
    private static let lock = NSLock()

    /// Fehlende Symbole übernehmen; `force` überschreibt vorhandene (z. B. nach einem Office-Update).
    static func install(force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.isWritableFile(atPath: resources.path) else {
            Log.info("Office-Dokumentsymbole: App-Ordner nicht beschreibbar – übersprungen")
            return
        }
        guard isAdHocSigned else {
            Log.info("Office-Dokumentsymbole: App ist mit eigenem Zertifikat signiert – übersprungen")
            return
        }

        var copied: [String] = []
        for app in OfficeApp.allCases {
            guard let appURL = app.applicationURL,
                  let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  let office = Bundle(url: appURL) else { continue }
            for ext in app.extensions {
                let target = resources.appendingPathComponent("Doc-\(ext).icns")
                if !force && FileManager.default.fileExists(atPath: target.path) { continue }
                guard let name = iconName(for: ext, in: info),
                      let image = office.image(forResource: name),
                      writeICNS(image, to: target) else {
                    Log.info("Office-Dokumentsymbol für .\(ext) in \(app.displayName) nicht gefunden")
                    continue
                }
                copied.append(ext)
            }
        }
        guard !copied.isEmpty else { return }

        guard resign() else {
            // Ohne neue Signatur wäre das Bundle beschädigt – Symbole wieder entfernen.
            for ext in copied {
                try? FileManager.default.removeItem(at: resources.appendingPathComponent("Doc-\(ext).icns"))
            }
            return
        }
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        Log.info("Office-Dokumentsymbole übernommen: \(copied.map { ".\($0)" }.joined(separator: ", ")). "
            + "Der Finder zeigt sie nach kurzer Zeit (sonst Finder neu starten).")
    }

    /// Symbolname aus den Dokumenttypen bzw. UTI-Deklarationen der Office-App.
    private static func iconName(for ext: String, in info: [String: Any]) -> String? {
        let uti = UTType(filenameExtension: ext)?.identifier.lowercased()
        func matches(extensions: [String], types: [String]) -> Bool {
            extensions.map { $0.lowercased() }.contains(ext)
                || (uti.map { types.map { $0.lowercased() }.contains($0) } ?? false)
        }
        func name(icon: Any?, file: Any?) -> String? {
            if let icon = icon as? String, !icon.isEmpty { return icon }
            if let file = file as? String, !file.isEmpty { return (file as NSString).deletingPathExtension }
            return nil
        }

        for type in info["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            guard matches(extensions: type["CFBundleTypeExtensions"] as? [String] ?? [],
                          types: type["LSItemContentTypes"] as? [String] ?? []) else { continue }
            if let found = name(icon: type["CFBundleTypeIconName"], file: type["CFBundleTypeIconFile"]) { return found }
        }
        let declarations = (info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [])
            + (info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? [])
        for decl in declarations {
            let id = decl["UTTypeIdentifier"] as? String ?? ""
            let tags = (decl["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"]
            let exts = tags as? [String] ?? (tags as? String).map { [$0] } ?? []
            guard matches(extensions: exts, types: [id]) else { continue }
            if let found = name(icon: decl["UTTypeIconName"], file: decl["UTTypeIconFile"]) { return found }
        }
        return nil
    }

    private static func writeICNS(_ image: NSImage, to url: URL) -> Bool {
        // Nur Größen, für die es einen ICNS-Typ gibt (ic04/ic05/ic07/ic08/ic09/ic10).
        let images = [16, 32, 128, 256, 512, 1024].compactMap { render(image, pixels: $0) }
        guard !images.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.apple.icns" as CFString, images.count, nil) else {
            return false
        }
        for cgImage in images {
            CGImageDestinationAddImage(destination, cgImage, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            // Keine halbe Datei liegen lassen – sonst gilt das Symbol beim nächsten Start als vorhanden.
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    private static func render(_ image: NSImage, pixels: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Nur ad-hoc signierte Apps werden verändert – eine Developer-ID-Signatur ließe sich nicht erneuern.
    private static var isAdHocSigned: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 1 << 1), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value else { return false }
        return flags & 0x2 != 0
    }

    private static func resign() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-",
                             "--preserve-metadata=identifier,entitlements,requirements,flags,runtime",
                             Bundle.main.bundlePath]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
            Log.error("Neu signieren nach Übernahme der Office-Symbole fehlgeschlagen (Status \(process.terminationStatus))")
        } catch {
            Log.error("codesign konnte nicht gestartet werden: \(error.localizedDescription)")
        }
        return false
    }
}
