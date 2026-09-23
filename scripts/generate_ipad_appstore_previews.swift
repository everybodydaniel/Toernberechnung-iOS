import AppKit
import Foundation

struct IPadSlideConfig {
    let rawFilename: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let outputFilename: String
}

let slides: [IPadSlideConfig] = [
    IPadSlideConfig(
        rawFilename: "01_karte_toernplanung.png",
        eyebrow: "INTELLIGENTE TÖRNPLANUNG",
        title: "Präzise Navigation",
        subtitle: "Sichere Abfahrtsfenster & WUK im Gezeitenrevier",
        outputFilename: "01_karte_toernplanung.png"
    ),
    IPadSlideConfig(
        rawFilename: "04_crew_terminkalender.png",
        eyebrow: "CREWSPACE & PLANUNG",
        title: "Crew- & Terminkalender",
        subtitle: "Törntermine abstimmen, planen & direkt synchronisieren",
        outputFilename: "02_crew_terminkalender.png"
    ),
    IPadSlideConfig(
        rawFilename: "02_revierwetter_windkarte.png",
        eyebrow: "REVIER-WETTER & WIND",
        title: "Wind & Wetter im Blick",
        subtitle: "48h-Vorhersage, Grundwind & Böen für dein Revier",
        outputFilename: "03_wetter_wind.png"
    ),
    IPadSlideConfig(
        rawFilename: "03_gezeiten_wasserstand.png",
        eyebrow: "BSH-ECHTZEIT-GEZEITEN",
        title: "Gezeiten & Pegelstände",
        subtitle: "Astronomische Tidenkurve, HW & NW minutengenau",
        outputFilename: "04_gezeiten_pegel.png"
    ),
    IPadSlideConfig(
        rawFilename: "07_warnmeldungen.png",
        eyebrow: "SICHERHEIT AUF SEE",
        title: "Nordsee-Warnmeldungen",
        subtitle: "Amtliche BSH-Meldungen & ELWIS direkt auf der Seekarte",
        outputFilename: "05_warnmeldungen.png"
    ),
    IPadSlideConfig(
        rawFilename: "05_crew_management.png",
        eyebrow: "CREW-ORGANISATION",
        title: "Sicherheit & Crew an Bord",
        subtitle: "Sicherheitsrollen, Notfallkontakte & Notizen offline dabei",
        outputFilename: "06_crew_management.png"
    ),
    IPadSlideConfig(
        rawFilename: "06_digitales_logbuch.png",
        eyebrow: "DIGITALES LOGBUCH",
        title: "Lückenloses Logbuch",
        subtitle: "Fahrten aufzeichnen, Seemeilen erfassen & PDF-Export",
        outputFilename: "07_digitales_logbuch.png"
    )
]

let rawDir = URL(fileURLWithPath: "assets/appstore/raw_ipad_simulator")
let outDir2048 = URL(fileURLWithPath: "assets/appstore/ipad_2048x2732")
let outDir2064 = URL(fileURLWithPath: "assets/appstore/ipad_2064x2752")

let fm = FileManager.default
try? fm.createDirectory(at: outDir2048, withIntermediateDirectories: true)
try? fm.createDirectory(at: outDir2064, withIntermediateDirectories: true)

func renderIPadPreview(
    slide: IPadSlideConfig,
    screenshot: NSImage,
    canvasWidth: CGFloat,
    canvasHeight: CGFloat,
    outputURL: URL
) {
    let scale = canvasWidth / 2048.0

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasWidth),
        pixelsHigh: Int(canvasHeight),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        print("❌ Failed to create bitmap rep for \(outputURL.lastPathComponent)")
        return
    }
    rep.size = NSSize(width: canvasWidth, height: canvasHeight)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.current = context

    // 1. Midnight Nautical Gradient Background
    let bgGradient = NSGradient(colors: [
        NSColor(red: 15/255.0, green: 34/255.0, blue: 60/255.0, alpha: 1.0),
        NSColor(red: 12/255.0, green: 24/255.0, blue: 44/255.0, alpha: 1.0),
        NSColor(red: 7/255.0, green: 14/255.0, blue: 27/255.0, alpha: 1.0)
    ], atLocations: [0.0, 0.55, 1.0], colorSpace: .deviceRGB)!
    bgGradient.draw(in: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight), angle: 90)

    // 2. Soft Ambient Oceanic Radial Lighting
    let glowCenter = NSPoint(x: canvasWidth * 0.5, y: canvasHeight - (1050 * scale))
    let glowGradient = NSGradient(colors: [
        NSColor(red: 2/255.0, green: 132/255.0, blue: 199/255.0, alpha: 0.30),
        NSColor(red: 3/255.0, green: 105/255.0, blue: 161/255.0, alpha: 0.09),
        NSColor(red: 7/255.0, green: 14/255.0, blue: 27/255.0, alpha: 0.0)
    ], atLocations: [0.0, 0.45, 1.0], colorSpace: .deviceRGB)!
    glowGradient.draw(fromCenter: glowCenter, radius: 50 * scale, toCenter: glowCenter, radius: 1050 * scale, options: [])

    // 3. Eyebrow badge / pill
    let eyebrowFont = NSFont.systemFont(ofSize: 30 * scale, weight: .bold)
    let eyebrowAttrs: [NSAttributedString.Key: Any] = [
        .font: eyebrowFont,
        .foregroundColor: NSColor(red: 56/255.0, green: 189/255.0, blue: 248/255.0, alpha: 1.0),
        .kern: 3.5 * scale
    ]
    let eyebrowString = NSAttributedString(string: slide.eyebrow, attributes: eyebrowAttrs)
    let eyebrowSize = eyebrowString.size()
    let pillPaddingH: CGFloat = 34 * scale
    let pillPaddingV: CGFloat = 12 * scale
    let pillWidth = eyebrowSize.width + pillPaddingH * 2
    let pillHeight = eyebrowSize.height + pillPaddingV * 2
    let pillY = canvasHeight - (165 * scale)
    let pillRect = NSRect(
        x: (canvasWidth - pillWidth) / 2.0,
        y: pillY,
        width: pillWidth,
        height: pillHeight
    )
    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2.0, yRadius: pillHeight / 2.0)
    NSColor(red: 14/255.0, green: 165/255.0, blue: 233/255.0, alpha: 0.16).setFill()
    pillPath.fill()
    NSColor(red: 56/255.0, green: 189/255.0, blue: 248/255.0, alpha: 0.38).setStroke()
    pillPath.lineWidth = 1.8 * scale
    pillPath.stroke()

    let eyebrowOrigin = NSPoint(x: (canvasWidth - eyebrowSize.width) / 2.0, y: pillY + pillPaddingV - (1.5 * scale))
    eyebrowString.draw(at: eyebrowOrigin)

    // 4. Headline Title
    let titleY = canvasHeight - (310 * scale)
    let titleFont = NSFont.systemFont(ofSize: 86 * scale, weight: .heavy)
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor.white,
        .paragraphStyle: titleStyle,
        .kern: -1.2 * scale
    ]
    let titleString = NSAttributedString(string: slide.title, attributes: titleAttrs)
    let titleRect = NSRect(x: 80 * scale, y: titleY, width: canvasWidth - (160 * scale), height: 110 * scale)
    titleString.draw(in: titleRect)

    // 5. Subtitle
    let subtitleY = canvasHeight - (440 * scale)
    let subtitleFont = NSFont.systemFont(ofSize: 42 * scale, weight: .medium)
    let subtitleStyle = NSMutableParagraphStyle()
    subtitleStyle.alignment = .center
    subtitleStyle.lineSpacing = 6 * scale
    let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: subtitleFont,
        .foregroundColor: NSColor(red: 203/255.0, green: 213/255.0, blue: 225/255.0, alpha: 0.94),
        .paragraphStyle: subtitleStyle
    ]
    let subtitleString = NSAttributedString(string: slide.subtitle, attributes: subtitleAttrs)
    let subtitleRect = NSRect(x: 100 * scale, y: subtitleY, width: canvasWidth - (200 * scale), height: 110 * scale)
    subtitleString.draw(in: subtitleRect)

    // 6. Native iPad Pro Mockup Frame
    // iPad aspect ratio 2048:2732
    let padWidth: CGFloat = 1660 * scale
    let bezel: CGFloat = 24 * scale
    let screenWidth: CGFloat = padWidth - bezel * 2
    let screenHeight: CGFloat = screenWidth * (2732.0 / 2048.0)
    let padHeight: CGFloat = screenHeight + bezel * 2

    let padX: CGFloat = (canvasWidth - padWidth) / 2.0
    // Sit snugly towards bottom with a balanced bottom margin:
    let padY: CGFloat = canvasHeight - (490 * scale) - padHeight
    let outerCornerRadius: CGFloat = 46 * scale
    let innerCornerRadius: CGFloat = 32 * scale

    let padRect = NSRect(x: padX, y: padY, width: padWidth, height: padHeight)
    let screenRect = NSRect(x: padX + bezel, y: padY + bezel, width: screenWidth, height: screenHeight)

    // Drop shadow behind iPad
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -35 * scale)
    shadow.shadowBlurRadius = 80 * scale
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
    shadow.set()

    // Outer iPad chassis (Dark Titanium / Space Black)
    let outerPath = NSBezierPath(roundedRect: padRect, xRadius: outerCornerRadius, yRadius: outerCornerRadius)
    NSColor(red: 24/255.0, green: 27/255.0, blue: 34/255.0, alpha: 1.0).setFill()
    outerPath.fill()

    NSShadow().set()

    // Aluminum bevel rim stroke
    NSColor(red: 71/255.0, green: 85/255.0, blue: 105/255.0, alpha: 0.65).setStroke()
    outerPath.lineWidth = 2.6 * scale
    outerPath.stroke()

    // Front Camera & Sensor Dot (Centered on top bezel)
    let camRadius: CGFloat = 5.0 * scale
    let camX = padX + padWidth / 2.0
    let camY = padY + padHeight - (bezel / 2.0)
    let camPath = NSBezierPath(ovalIn: NSRect(x: camX - camRadius, y: camY - camRadius, width: camRadius * 2, height: camRadius * 2))
    NSColor(red: 12/255.0, green: 14/255.0, blue: 18/255.0, alpha: 0.95).setFill()
    camPath.fill()

    // Ambient light sensor dot next to camera
    let sensorRadius: CGFloat = 3.0 * scale
    let sensorX = camX + 24 * scale
    let sensorPath = NSBezierPath(ovalIn: NSRect(x: sensorX - sensorRadius, y: camY - sensorRadius, width: sensorRadius * 2, height: sensorRadius * 2))
    NSColor(red: 16/255.0, green: 18/255.0, blue: 22/255.0, alpha: 0.7).setFill()
    sensorPath.fill()

    // Screen clipping and drawing the real native iPad screenshot
    NSGraphicsContext.saveGraphicsState()
    let innerPath = NSBezierPath(roundedRect: screenRect, xRadius: innerCornerRadius, yRadius: innerCornerRadius)
    innerPath.addClip()

    // Fill screen background dark first
    NSColor(red: 10/255.0, green: 14/255.0, blue: 22/255.0, alpha: 1.0).setFill()
    screenRect.fill()

    screenshot.draw(in: screenRect, from: NSRect(origin: .zero, size: screenshot.size), operation: .copy, fraction: 1.0)

    // Inner subtle screen bezel border
    NSColor(red: 0, green: 0, blue: 0, alpha: 0.35).setStroke()
    innerPath.lineWidth = 1.8 * scale
    innerPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        print("❌ Could not get PNG data for \(outputURL.lastPathComponent)")
        return
    }

    do {
        try pngData.write(to: outputURL)
        print("✅ Created: \(outputURL.lastPathComponent) (\(Int(canvasWidth))x\(Int(canvasHeight)))")
    } catch {
        print("❌ Error writing \(outputURL.lastPathComponent): \(error)")
    }
}

print("Generating iPad App Store Previews on iPad Pro Mockups...")

for slide in slides {
    let rawUrl = rawDir.appendingPathComponent(slide.rawFilename)
    guard let screenshot = NSImage(contentsOf: rawUrl) else {
        print("❌ Could not load raw screenshot: \(rawUrl.path)")
        continue
    }

    // 1. iPad 12.9" Pro Standard (2048 x 2732 px)
    let url2048 = outDir2048.appendingPathComponent(slide.outputFilename)
    renderIPadPreview(
        slide: slide,
        screenshot: screenshot,
        canvasWidth: 2048,
        canvasHeight: 2732,
        outputURL: url2048
    )

    // 2. iPad 13" Pro M4/M5 (2064 x 2752 px)
    let url2064 = outDir2064.appendingPathComponent(slide.outputFilename)
    renderIPadPreview(
        slide: slide,
        screenshot: screenshot,
        canvasWidth: 2064,
        canvasHeight: 2752,
        outputURL: url2064
    )
}

print("Done! All iPad App Store Previews generated.")
