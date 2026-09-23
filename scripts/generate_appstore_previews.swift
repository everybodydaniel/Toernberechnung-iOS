import AppKit
import Foundation

struct SlideConfig {
    let screenshotName: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let outputFilename: String
}

let slides: [SlideConfig] = [
    SlideConfig(
        screenshotName: "01_map_tab.png",
        eyebrow: "INTELLIGENTE TÖRNPLANUNG",
        title: "Präzise Navigation",
        subtitle: "Sichere Abfahrtsfenster & WUK im Gezeitenrevier",
        outputFilename: "01_appstore_karte_toernplanung.png"
    ),
    SlideConfig(
        screenshotName: "04_calendar_tab.png",
        eyebrow: "CREWSPACE & PLANUNG",
        title: "Crew- & Terminkalender",
        subtitle: "Törntermine abstimmen, planen & direkt synchronisieren",
        outputFilename: "02_appstore_crew_terminkalender.png"
    ),
    SlideConfig(
        screenshotName: "02_weather_tab.png",
        eyebrow: "REVIER-WETTER & WIND",
        title: "Wind & Wetter im Blick",
        subtitle: "48h-Vorhersage, Grundwind & Böen für dein Revier",
        outputFilename: "03_appstore_wetter_wind.png"
    ),
    SlideConfig(
        screenshotName: "03_tides_tab.png",
        eyebrow: "BSH-ECHTZEIT-GEZEITEN",
        title: "Gezeiten & Pegelstände",
        subtitle: "Astronomische Tidenkurve, HW & NW minutengenau",
        outputFilename: "04_appstore_gezeiten_pegel.png"
    ),
    SlideConfig(
        screenshotName: "06_warnings_tab.png",
        eyebrow: "SICHERHEIT AUF SEE",
        title: "Nordsee-Warnmeldungen",
        subtitle: "Amtliche BSH-Meldungen & ELWIS direkt auf der Seekarte",
        outputFilename: "05_appstore_warnmeldungen.png"
    ),
    SlideConfig(
        screenshotName: "05_crew_tab.png",
        eyebrow: "CREW-ORGANISATION",
        title: "Sicherheit & Crew an Bord",
        subtitle: "Sicherheitsrollen, Notfallkontakte & Notizen offline dabei",
        outputFilename: "06_appstore_crew_management.png"
    ),
    SlideConfig(
        screenshotName: "07_logbook_tab.png",
        eyebrow: "DIGITALES LOGBUCH",
        title: "Lückenloses Logbuch",
        subtitle: "Fahrten aufzeichnen, Seemeilen erfassen & PDF-Export",
        outputFilename: "07_appstore_digitales_logbuch.png"
    )
]

let canvasWidth: CGFloat = 1320
let canvasHeight: CGFloat = 2868
let rawDir = URL(fileURLWithPath: "assets/appstore/raw")
let outputDir = URL(fileURLWithPath: "assets/appstore/previews")

let fileManager = FileManager.default
try? fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

print("Starting generation of \(slides.count) App Store preview images (exact 1320x2868 px)...")

for (index, slide) in slides.enumerated() {
    let screenshotUrl = rawDir.appendingPathComponent(slide.screenshotName)
    guard let screenshot = NSImage(contentsOf: screenshotUrl) else {
        print("❌ Could not load screenshot: \(screenshotUrl.path)")
        continue
    }

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
        print("❌ Failed to create bitmap representation")
        continue
    }
    rep.size = NSSize(width: canvasWidth, height: canvasHeight)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        print("❌ Failed to create graphics context")
        continue
    }
    NSGraphicsContext.current = context

    // 1. Deep Midnight Nautical Gradient Background
    let bgGradient = NSGradient(colors: [
        NSColor(red: 15/255.0, green: 34/255.0, blue: 60/255.0, alpha: 1.0),
        NSColor(red: 12/255.0, green: 24/255.0, blue: 44/255.0, alpha: 1.0),
        NSColor(red: 7/255.0, green: 14/255.0, blue: 27/255.0, alpha: 1.0)
    ], atLocations: [0.0, 0.55, 1.0], colorSpace: .deviceRGB)!
    bgGradient.draw(in: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight), angle: 90)

    // 2. Soft Ambient Oceanic Radial Lighting
    let glowCenter = NSPoint(x: canvasWidth * 0.5, y: canvasHeight - 1100)
    let glowGradient = NSGradient(colors: [
        NSColor(red: 2/255.0, green: 132/255.0, blue: 199/255.0, alpha: 0.26),
        NSColor(red: 3/255.0, green: 105/255.0, blue: 161/255.0, alpha: 0.08),
        NSColor(red: 7/255.0, green: 14/255.0, blue: 27/255.0, alpha: 0.0)
    ], atLocations: [0.0, 0.45, 1.0], colorSpace: .deviceRGB)!
    glowGradient.draw(fromCenter: glowCenter, radius: 40, toCenter: glowCenter, radius: 850, options: [])

    // 3. Eyebrow badge / pill
    let eyebrowFont = NSFont.systemFont(ofSize: 24, weight: .bold)
    let eyebrowAttrs: [NSAttributedString.Key: Any] = [
        .font: eyebrowFont,
        .foregroundColor: NSColor(red: 56/255.0, green: 189/255.0, blue: 248/255.0, alpha: 1.0), // Sky-400
        .kern: 3.5
    ]
    let eyebrowString = NSAttributedString(string: slide.eyebrow, attributes: eyebrowAttrs)
    let eyebrowSize = eyebrowString.size()
    let pillPaddingH: CGFloat = 28
    let pillPaddingV: CGFloat = 10
    let pillWidth = eyebrowSize.width + pillPaddingH * 2
    let pillHeight = eyebrowSize.height + pillPaddingV * 2
    let pillY = canvasHeight - 180
    let pillRect = NSRect(
        x: (canvasWidth - pillWidth) / 2.0,
        y: pillY,
        width: pillWidth,
        height: pillHeight
    )
    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2.0, yRadius: pillHeight / 2.0)
    NSColor(red: 14/255.0, green: 165/255.0, blue: 233/255.0, alpha: 0.14).setFill()
    pillPath.fill()
    NSColor(red: 56/255.0, green: 189/255.0, blue: 248/255.0, alpha: 0.32).setStroke()
    pillPath.lineWidth = 1.5
    pillPath.stroke()

    let eyebrowOrigin = NSPoint(x: (canvasWidth - eyebrowSize.width) / 2.0, y: pillY + pillPaddingV - 1)
    eyebrowString.draw(at: eyebrowOrigin)

    // 4. Headline Title
    let titleY = canvasHeight - 310
    let titleFont = NSFont.systemFont(ofSize: 76, weight: .heavy)
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor.white,
        .paragraphStyle: titleStyle,
        .kern: -1.0
    ]
    let titleString = NSAttributedString(string: slide.title, attributes: titleAttrs)
    let titleRect = NSRect(x: 60, y: titleY, width: canvasWidth - 120, height: 100)
    titleString.draw(in: titleRect)

    // 5. Subtitle
    let subtitleY = canvasHeight - 440
    let subtitleFont = NSFont.systemFont(ofSize: 36, weight: .medium)
    let subtitleStyle = NSMutableParagraphStyle()
    subtitleStyle.alignment = .center
    subtitleStyle.lineSpacing = 6
    let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: subtitleFont,
        .foregroundColor: NSColor(red: 203/255.0, green: 213/255.0, blue: 225/255.0, alpha: 0.94), // Slate-300
        .paragraphStyle: subtitleStyle
    ]
    let subtitleString = NSAttributedString(string: slide.subtitle, attributes: subtitleAttrs)
    let subtitleRect = NSRect(x: 100, y: subtitleY, width: canvasWidth - 200, height: 110)
    subtitleString.draw(in: subtitleRect)

    // 6. Device Mockup (iPhone Pro Frame)
    let deviceScale: CGFloat = 0.84
    let screenWidth: CGFloat = 1320 * deviceScale
    let screenHeight: CGFloat = 2868 * deviceScale
    let bezel: CGFloat = 14
    let phoneWidth: CGFloat = screenWidth + bezel * 2
    let phoneHeight: CGFloat = screenHeight + bezel * 2
    let phoneX: CGFloat = (canvasWidth - phoneWidth) / 2.0
    // Top of phone is at canvasHeight - 500:
    let phoneY: CGFloat = canvasHeight - 500 - phoneHeight
    let outerCornerRadius: CGFloat = 104
    let innerCornerRadius: CGFloat = 90

    let phoneRect = NSRect(x: phoneX, y: phoneY, width: phoneWidth, height: phoneHeight)
    let screenRect = NSRect(x: phoneX + bezel, y: phoneY + bezel, width: screenWidth, height: screenHeight)

    // Ambient drop shadow behind phone
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -35)
    shadow.shadowBlurRadius = 75
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.68)
    shadow.set()

    let outerPath = NSBezierPath(roundedRect: phoneRect, xRadius: outerCornerRadius, yRadius: outerCornerRadius)
    NSColor(red: 26/255.0, green: 30/255.0, blue: 38/255.0, alpha: 1.0).setFill()
    outerPath.fill()

    // Reset shadow
    NSShadow().set()

    // Titanium rim stroke
    NSColor(red: 71/255.0, green: 85/255.0, blue: 105/255.0, alpha: 0.65).setStroke()
    outerPath.lineWidth = 2.5
    outerPath.stroke()

    // Screen clipping and drawing the real screenshot
    NSGraphicsContext.saveGraphicsState()
    let innerPath = NSBezierPath(roundedRect: screenRect, xRadius: innerCornerRadius, yRadius: innerCornerRadius)
    innerPath.addClip()

    screenshot.draw(in: screenRect, from: NSRect(origin: .zero, size: screenshot.size), operation: .copy, fraction: 1.0)

    // Dynamic Island
    let islandWidth: CGFloat = 260 * deviceScale
    let islandHeight: CGFloat = 72 * deviceScale
    let islandX = screenRect.origin.x + (screenWidth - islandWidth) / 2.0
    let islandY = screenRect.origin.y + screenHeight - (26 + 72) * deviceScale
    let islandRect = NSRect(x: islandX, y: islandY, width: islandWidth, height: islandHeight)
    let islandPath = NSBezierPath(roundedRect: islandRect, xRadius: islandHeight / 2.0, yRadius: islandHeight / 2.0)
    NSColor.black.setFill()
    islandPath.fill()

    // Subtle inner border stroke
    NSColor(red: 0, green: 0, blue: 0, alpha: 0.3).setStroke()
    innerPath.lineWidth = 1.5
    innerPath.stroke()

    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()

    // Export directly from NSBitmapImageRep
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        print("❌ Could not get PNG data for slide \(index + 1)")
        continue
    }

    let outUrl = outputDir.appendingPathComponent(slide.outputFilename)
    do {
        try pngData.write(to: outUrl)
        print("✅ Generated: \(slide.outputFilename)")
    } catch {
        print("❌ Error writing file \(slide.outputFilename): \(error)")
    }
}

print("Done! All App Store preview images successfully created in \(outputDir.path)")
