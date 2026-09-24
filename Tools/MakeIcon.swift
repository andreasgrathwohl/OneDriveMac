// Tools/MakeIcon.swift
//
// Erzeugt zur Build-Zeit alle PNGs für ein .iconset (App-Icon von "OneDrive Opener").
// Zeichnet vektorbasiert mit AppKit/CoreGraphics – läuft headless (ohne Fenster/Display),
// deshalb ohne Abhängigkeit von NSScreen o. Ä.
//
// Aufruf:
//   xcrun swift Tools/MakeIcon.swift <out.iconset>
//
// Design (macOS-Big-Sur-Iconraster):
//   Abgerundetes Quadrat ("Squircle"), blauer Verlauf, weiße Wolke mit
//   kleinem Dokument-Glyph (umgeknickte Ecke) unten rechts und einem
//   grünen Häkchen-Badge als Sync-Hinweis. Kein Text.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Kommandozeile

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(
        "Verwendung: xcrun swift Tools/MakeIcon.swift <out.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = CommandLine.arguments[1]

let fileManager = FileManager.default
do {
    try fileManager.createDirectory(atPath: outDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(
        "Fehler: Ausgabeordner \"\(outDir)\" konnte nicht angelegt werden: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Hilfsfunktionen

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

/// Alle in einem .iconset erwarteten Dateien (Name, Pixelgröße).
struct IconSlot {
    let fileName: String
    let pixels: Int
}

let slots: [IconSlot] = [
    IconSlot(fileName: "icon_16x16.png", pixels: 16),
    IconSlot(fileName: "icon_16x16@2x.png", pixels: 32),
    IconSlot(fileName: "icon_32x32.png", pixels: 32),
    IconSlot(fileName: "icon_32x32@2x.png", pixels: 64),
    IconSlot(fileName: "icon_128x128.png", pixels: 128),
    IconSlot(fileName: "icon_128x128@2x.png", pixels: 256),
    IconSlot(fileName: "icon_256x256.png", pixels: 256),
    IconSlot(fileName: "icon_256x256@2x.png", pixels: 512),
    IconSlot(fileName: "icon_512x512.png", pixels: 512),
    IconSlot(fileName: "icon_512x512@2x.png", pixels: 1024),
]

// MARK: - Zeichnen

/// Zeichnet das Icon in ein NSBitmapImageRep mit exakter Pixelgröße
/// (kein Bezug auf Bildschirm-Skalierung, funktioniert daher auch headless auf CI).
func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        return rep
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // 1024x1024 ist der Entwurfsraster; alle Koordinaten werden linear auf die
    // tatsächliche Pixelgröße skaliert, damit jede Auflösung von Grund auf neu
    // (scharf) gezeichnet wird statt hochskaliert zu werden.
    let designSize: CGFloat = 1024
    let scale = CGFloat(pixels) / designSize

    cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    cg.saveGState()
    cg.scaleBy(x: scale, y: scale)

    drawIconContent(in: cg)

    cg.restoreGState()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

/// Der eigentliche Icon-Inhalt, gezeichnet im 1024x1024-Entwurfsraster.
func drawIconContent(in cg: CGContext) {
    // MARK: Kachel ("Squircle") nach dem macOS-Icon-Raster (~824/1024, Radius ~185/1024)
    let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)

    // Weicher Schlagschatten unter der Kachel.
    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -14),
        blur: 28,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    NSColor.black.setFill()
    tilePath.fill()
    cg.restoreGState()

    // Blauer Verlauf, geclippt auf die Kachelform.
    cg.saveGState()
    tilePath.addClip()
    let gradient = NSGradient(
        starting: NSColor(hex: 0x3AA0FF),
        ending: NSColor(hex: 0x0A64D8)
    )
    gradient?.draw(
        from: NSPoint(x: tileRect.midX, y: tileRect.maxY),
        to: NSPoint(x: tileRect.midX, y: tileRect.minY),
        options: []
    )

    // Dezenter Glanz oben (typisch für Big-Sur-Icons).
    let glossGradient = NSGradient(
        colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0.0)]
    )
    let glossRect = NSRect(x: tileRect.minX, y: tileRect.midY, width: tileRect.width, height: tileRect.height / 2)
    glossGradient?.draw(
        from: NSPoint(x: glossRect.midX, y: glossRect.maxY),
        to: NSPoint(x: glossRect.midX, y: glossRect.minY),
        options: []
    )
    cg.restoreGState()

    // MARK: Wolke (weiß) – aus überlappenden Kreisen + einer Basis-Pille,
    // alle in einem NSBezierPath gefüllt, sodass sie ohne sichtbare Nähte
    // wie eine einzige Silhouette wirken.
    let cloudPath = NSBezierPath()
    cloudPath.append(NSBezierPath(roundedRect: NSRect(x: 270, y: 420, width: 460, height: 160), xRadius: 80, yRadius: 80))
    cloudPath.append(ovalPath(centerX: 365, centerY: 545, radius: 95))
    cloudPath.append(ovalPath(centerX: 490, centerY: 600, radius: 125))
    cloudPath.append(ovalPath(centerX: 610, centerY: 550, radius: 100))
    cloudPath.append(ovalPath(centerX: 665, centerY: 500, radius: 65))
    NSColor.white.setFill()
    cloudPath.fill()

    // MARK: Dokument-Glyph mit umgeknickter Ecke, überlappt die Wolke unten rechts.
    let docLeft: CGFloat = 560
    let docRight: CGFloat = 740
    let docBottom: CGFloat = 270
    let docTop: CGFloat = 470
    let fold: CGFloat = 42

    let docBody = NSBezierPath()
    docBody.move(to: NSPoint(x: docLeft, y: docBottom))
    docBody.line(to: NSPoint(x: docRight, y: docBottom))
    docBody.line(to: NSPoint(x: docRight, y: docTop - fold))
    docBody.line(to: NSPoint(x: docRight - fold, y: docTop))
    docBody.line(to: NSPoint(x: docLeft, y: docTop))
    docBody.close()

    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -6),
        blur: 12,
        color: NSColor.black.withAlphaComponent(0.22).cgColor
    )
    NSColor.white.setFill()
    docBody.fill()
    cg.restoreGState()

    // Umgeknickte Ecke, etwas dunkler getönt, damit die Faltung erkennbar ist.
    let docFold = NSBezierPath()
    docFold.move(to: NSPoint(x: docRight - fold, y: docTop))
    docFold.line(to: NSPoint(x: docRight, y: docTop - fold))
    docFold.line(to: NSPoint(x: docRight - fold, y: docTop - fold))
    docFold.close()
    NSColor(hex: 0xBFE0FF).setFill()
    docFold.fill()

    // MARK: Kleines grünes Häkchen-Badge (Sync-Hinweis) unten rechts.
    let badgeCenter = NSPoint(x: 770, y: 230)
    let badgeRadius: CGFloat = 90
    let badgePath = ovalPath(centerX: badgeCenter.x, centerY: badgeCenter.y, radius: badgeRadius)

    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -4),
        blur: 10,
        color: NSColor.black.withAlphaComponent(0.25).cgColor
    )
    NSColor(hex: 0x30C24A).setFill()
    badgePath.fill()
    cg.restoreGState()

    let check = NSBezierPath()
    check.move(to: NSPoint(x: badgeCenter.x - 42, y: badgeCenter.y + 2))
    check.line(to: NSPoint(x: badgeCenter.x - 10, y: badgeCenter.y - 30))
    check.line(to: NSPoint(x: badgeCenter.x + 45, y: badgeCenter.y + 38))
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.lineWidth = 22
    NSColor.white.setStroke()
    check.stroke()
}

func ovalPath(centerX: CGFloat, centerY: CGFloat, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2))
}

// MARK: - Export

for slot in slots {
    let rep = renderIcon(pixels: slot.pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(
            "Fehler: PNG-Daten für \(slot.fileName) konnten nicht erzeugt werden.\n".data(using: .utf8)!)
        exit(1)
    }
    let path = (outDir as NSString).appendingPathComponent(slot.fileName)
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(
            "Fehler: \(slot.fileName) konnte nicht geschrieben werden: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

print("→ Icon-Set erzeugt: \(outDir) (\(slots.count) PNGs)")
