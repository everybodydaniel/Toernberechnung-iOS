import AppKit
import Foundation

struct SlideConfig {
    let screenshotName: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let baseFilename: String
}

let slides: [SlideConfig] = [
    SlideConfig(
        screenshotName: "01_map_tab.png",
        eyebrow: "INTELLIGENTE TÖRNPLANUNG",
        title: "Präzise Navigation",
        subtitle: "Sichere Abfahrtsfenster & WUK im Gezeitenrevier",
        baseFilename: "01_karte_toernplanung.png"
    ),
    SlideConfig(
        screenshotName: "04_calendar_tab.png",
        eyebrow: "CREWSPACE & PLANUNG",
        title: "Crew- & Terminkalender",
        subtitle: "Törntermine abstimmen, planen & direkt synchronisieren",
        baseFilename: "02_crew_terminkalender.png"
    ),
    SlideConfig(
        screenshotName: "02_weather_tab.png",
        eyebrow: "REVIER-WETTER & WIND",
        title: "Wind & Wetter im Blick",
        subtitle: "48h-Vorhersage, Grundwind & Böen für dein Revier",
        baseFilename: "03_wetter_wind.png"
    ),
    SlideConfig(
        screenshotName: "03_tides_tab.png",
        eyebrow: "BSH-ECHTZEIT-GEZEITEN",
        title: "Gezeiten & Pegelstände",
        subtitle: "Astronomische Tidenkurve, HW & NW minutengenau",
        baseFilename: "04_gezeiten_pegel.png"
    ),
    SlideConfig(
        screenshotName: "06_warnings_tab.png",
        eyebrow: "SICHERHEIT AUF SEE",
        title: "Nordsee-Warnmeldungen",
        subtitle: "Amtliche BSH-Meldungen & ELWIS direkt auf der Seekarte",
        baseFilename: "05_warnmeldungen.png"
    ),
    SlideConfig(
        screenshotName: "05_crew_tab.png",
        eyebrow: "CREW-ORGANISATION",
        title: "Sicherheit & Crew an Bord",
        subtitle: "Sicherheitsrollen, Notfallkontakte & Notizen offline dabei",
        baseFilename: "06_crew_management.png"
    ),
    SlideConfig(
        screenshotName: "07_logbook_tab.png",
        eyebrow: "DIGITALES LOGBUCH",
        title: "Lückenloses Logbuch",
        subtitle: "Fahrten aufzeichnen, Seemeilen erfassen & PDF-Export",
        baseFilename: "07_digitales_logbuch.png"
    )
]

let rawDir = URL(fileURLWithPath: "assets/appstore/raw")
let baseOutputDir = URL(fileURLWithPath: "assets/appstore")

let fileManager = FileManager.default

// Target directories
let dirIPhone67 = baseOutputDir.appendingPathComponent("iphone_1284x2778")
let dirIPhone65 = baseOutputDir.appendingPathComponent("iphone_1242x2688")
let dirIPad13   = baseOutputDir.appendingPathComponent("ipad_2048x2732")
let dirRawIPhone67 = baseOutputDir.appendingPathComponent("raw_iphone_1284x2778")
let dirRawIPhone65 = baseOutputDir.appendingPathComponent("raw_iphone_1242x2688")
let dirRawIPad13   = baseOutputDir.appendingPathComponent("raw_ipad_2048x2732")

for d in [dirIPhone67, dirIPhone65, dirIPad13, dirRawIPhone67, dirRawIPhone65, dirRawIPad13] {
    try? fileManager.createDirectory(at: d, withIntermediateDirectories: true)
}

// MARK: - Generator Function for iPhone
func generateIPhoneSlide(
    slide: SlideConfig,
    screenshot: NSImage,
    canvasWidth: CGFloat,
    canvasHeight: CGFloat,
    outputURL: URL
) {
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
    ) else { return }
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
    let glowCenter = NSPoint(x: canvasWidth * 0.5, y: canvasHeight - (canvasHeight * 0.38))
    let glowGradient = NSGradient(colors: [
        NSColor(red: 2/255.0, green: 132/255.0, blue: 199/255.0, alpha: 0.28),
        NSColor(red: 3/255.0, green: 105/255.0, blue: 161/255.0, alpha: 0.08),
        NSColor(red: 7/255.0, green: 14/255.0, blue: 27/255.0, alpha: 0.0)
    ], atLocations: [0.0, 0.45, 1.0], colorSpace: .deviceRGB)!
    glowGradient.draw(fromCenter: glowCenter, radius: 40, toCenter: glowCenter, radius: canvasWidth * 0.65, options: [])

    let scaleFactor = canvasWidth / 1320.0

    // 3. Eyebrow badge / pill
    let eyebrowFont = NSFont.systemFont(ofSize: 23 * scaleFactor, weight: .bold)
    let eyebrowAttrs: [NSAttributedString.Key: Any] = [
        .font: eyebrowFont,
        .foregroundColor: NSColor(red: 56/255.0, green: 189/255.0, blue: 248/255.0, alpha: 1.0),
        .kern: 3.2 * scaleFactor
    ]
    let eyebrowString = NSAttributedString(string: slide.eyebrow, attributes: eyebrowAttrs)
    let eyebrowSize = eyebrowString.size()
    let pillPaddingH: CGFloat = 26 * scaleFactor
    let pillPaddingV: CGFloat = 10 * scaleFactor
    let pillWidth = eyebrowSize.width + pillPaddingH * 2
    let pillHeight = eyebrowSize.height + pillPaddingV * 2
    let pillY = canvasHeight - (175 * scaleFactor)
    let pillRect = NSRect(
        x: (canvasWidth - pillWidth) / 2.0,
        y: pillY,
        width: pillWidth,
        height: pillHeight
    )
    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2.0, yRadius: pillHeight / 2.0)
    NSColor(red: 14/255.0, green: 165/255.0, blue: 233/255.0, alpha: 0.15).setFill()
    pillPath.fill()
    NSColor(red: 56/255.0, green: 189/255.0, blue: 248/255.0, alpha: 0.35).setStroke()
    pillPath.lineWidth = 1.4
    pillPath.stroke()

    let eyebrowOrigin = NSPoint(x: (canvasWidth - eyebrowSize.width) / 2.0, y: pillY + pillPaddingV - 1)
    eyebrowString.draw(at: eyebrowOrigin)

    // 4. Headline Title
    let titleY = canvasHeight - (300 * scaleFactor)
    let titleFont = NSFont.systemFont(ofSize: 74 * scaleFactor, weight: .heavy)
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor.white,
        .paragraphStyle: titleStyle,
        .kern: -1.0
    ]
    let titleString = NSAttributedString(string: slide.title, attributes: titleAttrs)
    let titleRect = NSRect(x: 50 * scaleFactor, y: titleY, width: canvasWidth - 100 * scaleFactor, height: 95 * scaleFactor)
    titleString.draw(in: titleRect)

    // 5. Subtitle
    let subtitleY = canvasHeight - (425 * scaleFactor)
    let subtitleFont = NSFont.systemFont(ofSize: 35 * scaleFactor, weight: .medium)
    let subtitleStyle = NSMutableParagraphStyle()
    subtitleStyle.alignment = .center
    subtitleStyle.lineSpacing = 5 * scaleFactor
    let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: subtitleFont,
        .foregroundColor: NSColor(red: 203/255.0, green: 213/255.0, blue: 225/255.0, alpha: 0.94),
        .paragraphStyle: subtitleStyle
    ]
    let subtitleString = NSAttributedString(string: slide.subtitle, attributes: subtitleAttrs)
    let subtitleRect = NSRect(x: 80 * scaleFactor, y: subtitleY, width: canvasWidth - 160 * scaleFactor, height: 105 * scaleFactor)
    subtitleString.draw(in: subtitleRect)

    // 6. Device Mockup (iPhone Pro Frame)
    let deviceScale: CGFloat = 0.835
    let screenWidth: CGFloat = canvasWidth * deviceScale
    let screenHeight: CGFloat = (canvasWidth * (2868.0 / 1320.0)) * deviceScale
    let bezel: CGFloat = 13 * scaleFactor
    let phoneWidth: CGFloat = screenWidth + bezel * 2
    let phoneHeight: CGFloat = screenHeight + bezel * 2
    let phoneX: CGFloat = (canvasWidth - phoneWidth) / 2.0
    let phoneY: CGFloat = canvasHeight - (480 * scaleFactor) - phoneHeight
    let outerCornerRadius: CGFloat = 98 * scaleFactor
    let innerCornerRadius: CGFloat = 86 * scaleFactor

    let phoneRect = NSRect(x: phoneX, y: phoneY, width: phoneWidth, height: phoneHeight)
    let screenRect = NSRect(x: phoneX + bezel, y: phoneY + bezel, width: screenWidth, height: screenHeight)

    // Ambient drop shadow
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -35 * scaleFactor)
    shadow.shadowBlurRadius = 70 * scaleFactor
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.68)
    shadow.set()

    let outerPath = NSBezierPath(roundedRect: phoneRect, xRadius: outerCornerRadius, yRadius: outerCornerRadius)
    NSColor(red: 26/255.0, green: 30/255.0, blue: 38/255.0, alpha: 1.0).setFill()
    outerPath.fill()

    NSShadow().set()

    // Titanium rim
    NSColor(red: 71/255.0, green: 85/255.0, blue: 105/255.0, alpha: 0.65).setStroke()
    outerPath.lineWidth = 2.4 * scaleFactor
    outerPath.stroke()

    // Screenshot clipping
    NSGraphicsContext.saveGraphicsState()
    let innerPath = NSBezierPath(roundedRect: screenRect, xRadius: innerCornerRadius, yRadius: innerCornerRadius)
    innerPath.addClip()

    screenshot.draw(in: screenRect, from: NSRect(origin: .zero, size: screenshot.size), operation: .copy, fraction: 1.0)

    // Dynamic Island
    let islandWidth: CGFloat = 250 * deviceScale * scaleFactor
    let islandHeight: CGFloat = 68 * deviceScale * scaleFactor
    let islandX = screenRect.origin.x + (screenWidth - islandWidth) / 2.0
    let islandY = screenRect.origin.y + screenHeight - (25 + 68) * deviceScale * scaleFactor
    let islandRect = NSRect(x: islandX, y: islandY, width: islandWidth, height: islandHeight)
    let islandPath = NSBezierPath(roundedRect: islandRect, xRadius: islandHeight / 2.0, yRadius: islandHeight / 2.0)
    NSColor.black.setFill()
    islandPath.fill()

    // Inner border
    NSColor(red: 0, green: 0, blue: 0, alpha: 0.3).setStroke()
    innerPath.lineWidth = 1.4 * scaleFactor
    innerPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        try? pngData.write(to: outputURL)
    }
}

// MARK: - Generator Function for iPad Pro (2048 x 2732 px)
func generateIPadSlide(
    slide: SlideConfig,
    screenshot: NSImage,
    canvasWidth: CGFloat,
    canvasHeight: CGFloat,
    outputURL: URL
) {
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
    ) else { return }
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
    let glowCenter = NSPoint(x: canvasWidth * 0.5, y: canvasHeight - 1100)
    let glowGradient = NSGradient(colors: [
        NSColor(red: 2/255.0, green: 132/255.0, blue: 199/255.0, alpha: 0.28),
        NSColor(red: 3/255.0, green: 105/255.0, blue: 161/255.0, alpha: 0.08),
        NSColor(red: 7/255.0, green: 14/255.0, blue: 27/255.0, alpha: 0.0)
    ], atLocations: [0.0, 0.45, 1.0], colorSpace: .deviceRGB)!
    glowGradient.draw(fromCenter: glowCenter, radius: 60, toCenter: glowCenter, radius: 1100, options: [])

    // 3. Eyebrow badge / pill
    let eyebrowFont = NSFont.systemFont(ofSize: 34, weight: .bold)
    let eyebrowAttrs: [NSAttributedString.Key: Any] = [
        .font: eyebrowFont,
        .foregroundColor: NSColor(red: 56/255.0, green: 189/255.0, blue: 248/255.0, alpha: 1.0),
        .kern: 4.0
    ]
    let eyebrowString = NSAttributedString(string: slide.eyebrow, attributes: eyebrowAttrs)
    let eyebrowSize = eyebrowString.size()
    let pillPaddingH: CGFloat = 36
    let pillPaddingV: CGFloat = 14
    let pillWidth = eyebrowSize.width + pillPaddingH * 2
    let pillHeight = eyebrowSize.height + pillPaddingV * 2
    let pillY = canvasHeight - 210
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
    pillPath.lineWidth = 2.0
    pillPath.stroke()

    let eyebrowOrigin = NSPoint(x: (canvasWidth - eyebrowSize.width) / 2.0, y: pillY + pillPaddingV - 2)
    eyebrowString.draw(at: eyebrowOrigin)

    // 4. Headline Title
    let titleY = canvasHeight - 370
    let titleFont = NSFont.systemFont(ofSize: 106, weight: .heavy)
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: NSColor.white,
        .paragraphStyle: titleStyle,
        .kern: -1.5
    ]
    let titleString = NSAttributedString(string: slide.title, attributes: titleAttrs)
    let titleRect = NSRect(x: 100, y: titleY, width: canvasWidth - 200, height: 130)
    titleString.draw(in: titleRect)

    // 5. Subtitle
    let subtitleY = canvasHeight - 520
    let subtitleFont = NSFont.systemFont(ofSize: 48, weight: .medium)
    let subtitleStyle = NSMutableParagraphStyle()
    subtitleStyle.alignment = .center
    subtitleStyle.lineSpacing = 8
    let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: subtitleFont,
        .foregroundColor: NSColor(red: 203/255.0, green: 213/255.0, blue: 225/255.0, alpha: 0.94),
        .paragraphStyle: subtitleStyle
    ]
    let subtitleString = NSAttributedString(string: slide.subtitle, attributes: subtitleAttrs)
    let subtitleRect = NSRect(x: 140, y: subtitleY, width: canvasWidth - 280, height: 130)
    subtitleString.draw(in: subtitleRect)

    // 6. Device Mockup (iPad Pro Frame)
    // iPad 13" aspect ratio: 3:4.
    let screenWidth: CGFloat = 1440
    let screenHeight: CGFloat = 1920
    let bezel: CGFloat = 26
    let padWidth: CGFloat = screenWidth + bezel * 2
    let padHeight: CGFloat = screenHeight + bezel * 2
    let padX: CGFloat = (canvasWidth - padWidth) / 2.0
    let padY: CGFloat = canvasHeight - 580 - padHeight
    let outerCornerRadius: CGFloat = 52
    let innerCornerRadius: CGFloat = 36

    let padRect = NSRect(x: padX, y: padY, width: padWidth, height: padHeight)
    let screenRect = NSRect(x: padX + bezel, y: padY + bezel, width: screenWidth, height: screenHeight)

    // Ambient drop shadow
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -45)
    shadow.shadowBlurRadius = 85
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
    shadow.set()

    let outerPath = NSBezierPath(roundedRect: padRect, xRadius: outerCornerRadius, yRadius: outerCornerRadius)
    NSColor(red: 24/255.0, green: 27/255.0, blue: 34/255.0, alpha: 1.0).setFill()
    outerPath.fill()

    NSShadow().set()

    // Aluminum rim
    NSColor(red: 71/255.0, green: 85/255.0, blue: 105/255.0, alpha: 0.65).setStroke()
    outerPath.lineWidth = 3.0
    outerPath.stroke()

    // Camera dot
    let camRadius: CGFloat = 5.5
    let camX = padX + padWidth / 2.0
    let camY = padY + padHeight - bezel / 2.0
    let camPath = NSBezierPath(ovalIn: NSRect(x: camX - camRadius, y: camY - camRadius, width: camRadius * 2, height: camRadius * 2))
    NSColor(red: 10/255.0, green: 12/255.0, blue: 16/255.0, alpha: 0.9).setFill()
    camPath.fill()

    // Screenshot clipping
    NSGraphicsContext.saveGraphicsState()
    let innerPath = NSBezierPath(roundedRect: screenRect, xRadius: innerCornerRadius, yRadius: innerCornerRadius)
    innerPath.addClip()

    // Fill screen background dark first
    NSColor(red: 10/255.0, green: 14/255.0, blue: 22/255.0, alpha: 1.0).setFill()
    screenRect.fill()

    // Center and scale screenshot inside iPad screen
    let sSize = screenshot.size
    let sAspect = sSize.width / sSize.height
    let padAspect = screenWidth / screenHeight

    var drawRect = screenRect
    if sAspect > padAspect {
        // Screenshot is wider than iPad screen
        let h = screenWidth / sAspect
        drawRect = NSRect(x: screenRect.origin.x, y: screenRect.origin.y + (screenHeight - h) / 2.0, width: screenWidth, height: h)
    } else {
        // Screenshot is taller (e.g. iPhone) -> fill cleanly
        let w = screenHeight * sAspect
        drawRect = NSRect(x: screenRect.origin.x + (screenWidth - w) / 2.0, y: screenRect.origin.y, width: w, height: screenHeight)
    }

    screenshot.draw(in: drawRect, from: NSRect(origin: .zero, size: screenshot.size), operation: .copy, fraction: 1.0)

    // Inner border
    NSColor(red: 0, green: 0, blue: 0, alpha: 0.35).setStroke()
    innerPath.lineWidth = 2.0
    innerPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        try? pngData.write(to: outputURL)
    }
}

// MARK: - Scaled Raw Screenshot Function
func generateRawScaled(
    screenshot: NSImage,
    targetWidth: CGFloat,
    targetHeight: CGFloat,
    outputURL: URL
) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(targetWidth),
        pixelsHigh: Int(targetHeight),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }
    rep.size = NSSize(width: targetWidth, height: targetHeight)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.current = context

    context.imageInterpolation = .high
    screenshot.draw(
        in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
        from: NSRect(origin: .zero, size: screenshot.size),
        operation: .copy,
        fraction: 1.0
    )

    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        try? pngData.write(to: outputURL)
    }
}

// MARK: - Run All Generations
print("🚀 Generating App Store Previews in exact required dimensions...")

for (i, slide) in slides.enumerated() {
    let rawUrl = rawDir.appendingPathComponent(slide.screenshotName)
    guard let screenshot = NSImage(contentsOf: rawUrl) else {
        print("❌ Screenshot missing: \(slide.screenshotName)")
        continue
    }

    // 1. iPhone 6.7" (1284 x 2778)
    let outIPhone67 = dirIPhone67.appendingPathComponent(slide.baseFilename)
    generateIPhoneSlide(slide: slide, screenshot: screenshot, canvasWidth: 1284, canvasHeight: 2778, outputURL: outIPhone67)

    // 2. iPhone 6.5" (1242 x 2688)
    let outIPhone65 = dirIPhone65.appendingPathComponent(slide.baseFilename)
    generateIPhoneSlide(slide: slide, screenshot: screenshot, canvasWidth: 1242, canvasHeight: 2688, outputURL: outIPhone65)

    // 3. iPad Pro 13" (2048 x 2732)
    let outIPad13 = dirIPad13.appendingPathComponent(slide.baseFilename)
    generateIPadSlide(slide: slide, screenshot: screenshot, canvasWidth: 2048, canvasHeight: 2732, outputURL: outIPad13)

    // 4. Raw scaled versions
    let rawOut67 = dirRawIPhone67.appendingPathComponent(slide.baseFilename)
    generateRawScaled(screenshot: screenshot, targetWidth: 1284, targetHeight: 2778, outputURL: rawOut67)

    let rawOut65 = dirRawIPhone65.appendingPathComponent(slide.baseFilename)
    generateRawScaled(screenshot: screenshot, targetWidth: 1242, targetHeight: 2688, outputURL: rawOut65)

    let rawOutPad = dirRawIPad13.appendingPathComponent(slide.baseFilename)
    generateRawScaled(screenshot: screenshot, targetWidth: 2048, targetHeight: 2732, outputURL: rawOutPad)

    print("✅ [\(i+1)/\(slides.count)] Generated iPhone (1284x2778 & 1242x2688) + iPad (2048x2732) for: \(slide.baseFilename)")
}

print("🎉 Finished! All required App Store screenshot formats generated successfully.")
